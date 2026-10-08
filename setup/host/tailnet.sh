#!/usr/bin/env hellish
# tailnet.sh — the private plane, end to end: the guest on the tailnet with
# MagicDNS, a trusted certificate, `tailscale serve` fronting the WAF at
# https://<node>.<tailnet>.ts.net/, and grobase told about that origin. Every
# step is checked before it is done, so a second run is a no-op that prints
# the client configuration.
#
# WHAT NEEDS THE ADMIN CONSOLE, AND HOW THE SCRIPT HANDLES IT
#   Three switches live at https://login.tailscale.com/admin and nowhere else:
#     MagicDNS            DNS -> MagicDNS -> Enable          (has an API)
#     HTTPS Certificates  DNS -> HTTPS Certificates -> Enable (console only)
#     key expiry          Machines -> <node> -> Disable key expiry (has an API)
#   plus the auth key itself (Settings -> Keys), when the node is not yet
#   logged in. With an API credential in the secrets file the script does the
#   two API-able ones itself and mints the auth key; without one, it stops at
#   each switch, prints exactly what to click, waits for Enter, and polls the
#   node until the control plane shows the change. Without a terminal it
#   prints the same instructions and exits 1, so `make datacenter` never
#   hangs on a prompt. Nothing is ever typed into a browser by the script.
#
# CREDENTIALS, ALL IN ~/.config/born2root/b2b-secrets (mode 600, see dc_lib.sh)
#   TS_AUTHKEY               node login; reusable + ephemeral + pre-approved
#   TS_API_TOKEN             an API access token (Settings -> Keys -> Generate
#                            access token; 90 days max) -- optional, unlocks
#                            the automatic path above
#   TS_OAUTH_CLIENT_ID/_SECRET  an OAuth client instead of a token (does not
#                            expire; needs the auth_keys, dns and devices
#                            scopes). Auth keys minted this way must carry a
#                            tag: TS_TAGS=tag:server
#   The API is spoken from the host with curl; the credential travels through
#   a curl config on stdin, never on a command line.
#
# WHAT STAYS ON THE NODE
#   `tailscale serve` is a persisted pref: the URL survives reboots. The CORS
#   origin is pasted into kong.yml by grobase_cors_guest.sh, the same path
#   `make grobase_cors` takes, so Kong restarts only when the origin is new.
#   https://<node>.<tailnet>.ts.net/ is reachable from tailnet peers only;
#   funnel.sh is the public twin and is untouched here.
#
#   make tailnet                   up (idempotent)
#   make tailnet TS_SERVE=tcp      no certificate yet: raw passthrough, self-signed
#   make tailnet TS_HOSTNAME=baas  rename the node; its ts.net name follows
#   make tailnet_status | tailnet_down
#   B2B_CONFIG=profiles/server.toml make tailnet   the guest's sudo password
#                                  comes from the profile, as make edge does;
#                                  VM_SUDO_PASS=... overrides it
set -u

usage() {
    sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
}
case "${1:-}" in -h | --help | help)
    usage
    exit 0
    ;;
esac

# shellcheck source=setup/host/dc_lib.sh
. "$(dirname "${BASH_SOURCE[0]:-$0}")/dc_lib.sh"

MODE="${1:-up}"
SERVE="${TS_SERVE:-https}"
case "$SERVE" in https | tcp) ;; *) die "TS_SERVE=$SERVE (expected https or tcp)" ;; esac
TS_API="${TS_API_URL:-https://api.tailscale.com/api/v2}"
CONSOLE=https://login.tailscale.com/admin
VM_PATH="${VM_PATH:-$DC_ROOT/disk_images}"
export VM_PATH

TMP=$(mktemp -d "${TMPDIR:-/tmp}/tailnet.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

is_tty() { [ -t 0 ] && [ -t 1 ]; }

# ── reading the node ─────────────────────────────────────────────────────────
STATUS_JSON=
ts_refresh() { STATUS_JSON=$(vm_ssh "tailscale status --json 2>/dev/null" 2>/dev/null || true); }
# ts_get PATH: a value out of the last status JSON by dotted path (strings
# raw, booleans true/false, lists space-joined, absent -> empty). The helper
# is a file, not a -c string: bashate reads a Python `for` as a shell one.
cat >"$TMP/jget.py" <<'PY'
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = None
for k in sys.argv[1].split("."):
    d = d.get(k) if isinstance(d, dict) else None
    if d is None:
        break
if d is None:
    print("")
elif isinstance(d, bool):
    print("true" if d else "false")
elif isinstance(d, list):
    print(" ".join(str(x) for x in d))
else:
    print(d)
PY
ts_get() {
    [ -n "$STATUS_JSON" ] || return 0
    printf '%s' "$STATUS_JSON" | python3 "$TMP/jget.py" "$1" 2>/dev/null
}
node_name() {
    local n
    n=$(ts_get Self.DNSName)
    printf '%s' "${n%.}"
}
# poll_until PATH VALUE SECONDS: refresh until the field reads VALUE (or, with
# VALUE "*", until it is non-empty). 0 when it did, 1 on timeout.
poll_until() {
    local path="$1" want="$2" secs="$3" deadline v
    deadline=$(($(date +%s) + secs))
    while :; do
        ts_refresh
        v=$(ts_get "$path")
        if [ "$want" = '*' ]; then
            [ -n "$v" ] && return 0
        else
            [ "$v" = "$want" ] && return 0
        fi
        [ "$(date +%s)" -lt "$deadline" ] || return 1
        sleep 3
    done
}

# ── the console, by hand ─────────────────────────────────────────────────────
# console_step TITLE LINE...: print the instructions. Then either wait for
# Enter (a terminal) or stop (no terminal: make datacenter, CI, a pipe).
console_step() {
    local title="$1"
    shift
    printf '\n  %b%s%b\n' "$C_B" "$title" "$C_R"
    while [ $# -gt 0 ]; do
        printf '    %s\n' "$1"
        shift
    done
}
wait_for_enter() {
    local prompt="${1:-done}" ans
    is_tty || die "no terminal to wait on: do the step above, then rerun make tailnet"
    printf '  press Enter when %s (type skip to go on without it): ' "$prompt"
    read -r ans
    case "$ans" in skip | s) return 1 ;; esac
    return 0
}
# read_secret PROMPT -> REPLY, no echo. 1 when there is no terminal.
read_secret() {
    is_tty || return 1
    printf '%s' "$1"
    stty -echo 2>/dev/null
    read -r REPLY
    stty echo 2>/dev/null
    printf '\n'
}

# ── the API ──────────────────────────────────────────────────────────────────
API_TOKEN=
API_CODE=000
# api_ready: 0 when a credential resolved to a bearer token (asked for once,
# interactively, when none is stored; TS_NO_API=1 skips the whole thing).
api_ready() {
    [ -n "$API_TOKEN" ] && return 0
    [ "${TS_NO_API:-0}" = 1 ] && return 1
    local tok cid csec
    tok="${TS_API_TOKEN:-$(secret_get TS_API_TOKEN)}"
    if [ -z "$tok" ]; then
        cid="${TS_OAUTH_CLIENT_ID:-$(secret_get TS_OAUTH_CLIENT_ID)}"
        csec="${TS_OAUTH_CLIENT_SECRET:-$(secret_get TS_OAUTH_CLIENT_SECRET)}"
        if [ -n "$cid" ] && [ -n "$csec" ]; then
            tok=$(printf 'data-urlencode = "client_id=%s"\ndata-urlencode = "client_secret=%s"\n' "$cid" "$csec" |
                curl -s --max-time 20 -K - "$TS_API/oauth/token" 2>/dev/null | json_get access_token)
            [ -n "$tok" ] || warn "the OAuth client was refused by $TS_API/oauth/token (expired? wrong scopes?)"
        fi
    fi
    if [ -z "$tok" ] && [ "${TS_ASK_API:-1}" = 1 ] && read_secret "  Tailscale API access token (optional, Enter to skip; ${CONSOLE}/settings/keys -> Generate access token): "; then
        tok="$REPLY"
        if [ -n "$tok" ]; then
            secret_set TS_API_TOKEN "$tok"
            ok "saved TS_API_TOKEN to $SECRETS_FILE (mode 600; tokens last 90 days at most)"
        fi
    fi
    TS_ASK_API=0
    [ -n "$tok" ] || return 1
    API_TOKEN="$tok"
}
# json_get KEY: a top-level value out of the JSON on stdin (same helper).
json_get() { python3 "$TMP/jget.py" "$1" 2>/dev/null; }
# ts_api METHOD PATH [BODY]: the response body on stdout, HTTP code in API_CODE.
ts_api() {
    local method="$1" path="$2" body="${3:-}"
    local args=(-s --max-time 30 -K - -X "$method" -H 'Content-Type: application/json'
        -o "$TMP/api.out" -w '%{http_code}' "$TS_API/$path")
    [ -n "$body" ] && args+=(--data "$body")
    : >"$TMP/api.out"
    API_CODE=$(printf 'user = "%s:"\n' "$API_TOKEN" | curl "${args[@]}" 2>/dev/null) || API_CODE=000
    cat "$TMP/api.out"
    case "$API_CODE" in 2??) return 0 ;; esac
    [ "$API_CODE" = 401 ] && warn "the Tailscale API rejected the credential (401): TS_API_TOKEN expired? (${CONSOLE}/settings/keys)"
    return 1
}
# mint_authkey: a reusable + ephemeral + pre-authorized key (90 days) through
# the API; printed, nothing else. TS_TAGS=tag:a,tag:b when the node is to be
# tagged (OAuth clients can mint tagged keys only).
mint_authkey() {
    local tags body
    tags=$(printf '%s' "${TS_TAGS:-}" | python3 -c 'import json,sys; print(json.dumps([t.strip() for t in sys.stdin.read().split(",") if t.strip()]))')
    body=$(printf '{"capabilities":{"devices":{"create":{"reusable":true,"ephemeral":true,"preauthorized":true,"tags":%s}}},"expirySeconds":7776000,"description":"born2root %s"}' "$tags" "$VM_NAME")
    ts_api POST tailnet/-/keys "$body" | json_get key
}

# ── the guest, as root ───────────────────────────────────────────────────────
# run_guest SERVE: tailnet_guest.sh through provision_vm.sh root-sh, which
# handles the sudo password (the profile's, or VM_SUDO_PASS). Its exit code is
# not propagated by run_provisioner, so the caller re-reads the node after.
run_guest() {
    ROOTSH_SERVE="$1" ROOTSH_WAF_PORT="${WAF_PORT:-}" ROOTSH_OPERATOR="$VM_USER" \
        ROOTSH_HOSTNAME="${TS_HOSTNAME:-}" ROOTSH_AUTHKEY="${AUTHKEY:-}" \
        ROOT_SH="$DC_ROOT/setup/host/tailnet_guest.sh" \
        "${SCRIPT_SH:-bash}" "$DC_ROOT/setup/host/provision_vm.sh" "$VM_NAME" root-sh
}
waf_port() { vm_ssh "docker port mini-baas-waf 443/tcp 2>/dev/null | head -n1 | sed 's/.*://'" 2>/dev/null; }

# ── modes ────────────────────────────────────────────────────────────────────
dc_connect
ts_refresh
state=$(ts_get BackendState)

case "$MODE" in
--status | status)
    name=$(node_name)
    printf '  %-22s %s\n' "backend" "${state:-no tailscaled}" \
        "node" "${name:-none} ($(ts_get TailscaleIPs))" \
        "tailnet" "$(ts_get CurrentTailnet.Name) ($(ts_get MagicDNSSuffix))" \
        "MagicDNS" "$(ts_get CurrentTailnet.MagicDNSEnabled)" \
        "HTTPS certificates" "$([ -n "$(ts_get CertDomains)" ] && echo on || echo off)" \
        "key expiry" "$(ts_get Self.KeyExpiry)" \
        "tags" "$(ts_get Self.Tags)"
    out=$(vm_ssh "tailscale serve status 2>&1" || true)
    printf '  %-22s\n' "serve"
    printf '%s\n' "${out:-?}" | sed 's/^/      /'
    if [ -n "$name" ] && vm_ssh "grep -qF -- '- https://${name}' /opt/grobase/infra/docker/services/kong/conf/kong.yml" 2>/dev/null; then
        printf '  %-22s %s\n' "grobase CORS origin" "https://${name} (kong.yml)"
    else
        printf '  %-22s %s\n' "grobase CORS origin" "not in kong.yml"
    fi
    if [ "$state" = Running ] && [ -n "$name" ]; then
        code=$(vm_ssh "curl -sk -o /dev/null -w '%{http_code}' --max-time 10 https://${name}/" 2>/dev/null || true)
        printf '  %-22s %s\n' "https://${name}/" "HTTP ${code:-000} (from the guest)"
    fi
    exit 0
    ;;
--down | down)
    [ "$state" = Running ] || die "the guest is not on the tailnet (state: ${state:-unknown}); nothing to take down"
    name=$(node_name)
    # The operator may manage serve without sudo; a node where no operator
    # was ever set falls back to the root path.
    if vm_ssh "tailscale serve --https=443 off >/dev/null 2>&1; tailscale serve --tcp=443 off >/dev/null 2>&1; tailscale serve status 2>/dev/null | grep -q 'No serve config'" 2>/dev/null; then
        ok "serve is off; https://${name}/ no longer answers (the node stays on the tailnet; the CORS origin stays in kong.yml)"
    else
        run_guest off
        vm_ssh "tailscale serve status 2>/dev/null | grep -q 'No serve config'" 2>/dev/null ||
            die "serve is still configured (tailscale serve status in the guest)"
        ok "serve is off; https://${name}/ no longer answers (the node stays on the tailnet)"
    fi
    exit 0
    ;;
up | '') ;;
*)
    die "unknown mode '$MODE' (up | --status | --down | --help)"
    ;;
esac

# ── up ───────────────────────────────────────────────────────────────────────
# 0. tailscaled at all. An empty state means nothing answered: a guest built
#    without dc-netmesh, or the daemon stopped. install_edge.sh fixes both.
if [ -z "$state" ]; then
    info "tailscaled is not answering in the guest; running install_edge.sh (dc-netmesh)"
    EDGE_NETMESH=1 EDGE_TUNNEL=0 "${SCRIPT_SH:-bash}" "$DC_ROOT/setup/host/provision_vm.sh" "$VM_NAME" edge || true
    ts_refresh
    state=$(ts_get BackendState)
    [ -n "$state" ] || die "tailscaled still does not answer (systemctl status tailscaled, in the guest)"
fi

# 1. grobase, before anything is promised about it.
WAF_PORT=$(waf_port)
case "$WAF_PORT" in '' | *[!0-9]*) die "the WAF is not publishing 443 (docker port mini-baas-waf) -- is grobase up? (make grobase_status)" ;; esac

# 2. an API credential, optional, asked for once.
if api_ready; then
    ok "Tailscale API: credential found (console steps are done for you where the API allows)"
else
    warn "no Tailscale API credential (TS_API_TOKEN in $SECRETS_FILE): console steps are prompted for instead"
fi

# 3. login.
AUTHKEY=
if [ "$state" != Running ]; then
    info "node state: $state -- it needs to log in"
    if [ "$state" != Stopped ]; then
        AUTHKEY="${TS_AUTHKEY:-$(secret_get TS_AUTHKEY)}"
        if [ -z "$AUTHKEY" ] && api_ready; then
            AUTHKEY=$(mint_authkey)
            if [ -n "$AUTHKEY" ]; then
                secret_set TS_AUTHKEY "$AUTHKEY"
                ok "minted a reusable + ephemeral + pre-approved auth key through the API; saved as TS_AUTHKEY in $SECRETS_FILE"
            else
                warn "the API would not mint an auth key (HTTP $API_CODE); an OAuth client needs TS_TAGS=tag:... and the auth_keys scope"
            fi
        fi
        if [ -z "$AUTHKEY" ]; then
            console_step "Tailscale auth key" \
                "${CONSOLE}/settings/keys -> Generate auth key" \
                "tick Reusable, Ephemeral, Pre-approved (a tag is optional); copy the tskey-auth-... value"
            if read_secret "  auth key: " && [ -n "$REPLY" ]; then
                AUTHKEY="$REPLY"
                secret_set TS_AUTHKEY "$AUTHKEY"
                ok "saved TS_AUTHKEY to $SECRETS_FILE (mode 600)"
            else
                die "no auth key: put TS_AUTHKEY=tskey-auth-... in $SECRETS_FILE (or TS_API_TOKEN, and the script mints one), then rerun make tailnet"
            fi
        fi
    fi
    run_guest "$SERVE"
    ts_refresh
    state=$(ts_get BackendState)
    if [ "$state" != Running ]; then
        [ -n "$AUTHKEY" ] && [ -z "${TS_AUTHKEY:-}" ] && warn "the stored TS_AUTHKEY was refused: a one-off key is spent by the first VM, and a key from another tailnet never works. Remove it from $SECRETS_FILE and rerun"
        die "the node did not log in (state: ${state:-unknown}); read the guest output above"
    fi
    ok "logged in as $(node_name) ($(ts_get TailscaleIPs))"
fi
AUTHKEY=
name=$(node_name)
node_id=$(ts_get Self.ID)
tailnet=$(ts_get MagicDNSSuffix)

# 4. MagicDNS, tailnet-wide.
if [ "$(ts_get CurrentTailnet.MagicDNSEnabled)" = true ]; then
    ok "MagicDNS: on ($tailnet)"
else
    done_by_api=0
    if api_ready && ts_api POST tailnet/-/dns/preferences '{"magicDNS":true}' >/dev/null; then
        done_by_api=1
        info "MagicDNS: enabled through the API"
    fi
    if [ "$done_by_api" = 0 ]; then
        console_step "MagicDNS is off for this tailnet" \
            "${CONSOLE}/dns -> MagicDNS -> Enable MagicDNS"
        wait_for_enter "MagicDNS is enabled" || die "MagicDNS is required: the node's name is its address"
    fi
    poll_until CurrentTailnet.MagicDNSEnabled true 60 || die "the node still reports MagicDNS off; wait a moment and rerun make tailnet"
    ok "MagicDNS: on ($(ts_get MagicDNSSuffix))"
    name=$(node_name)
fi
[ -n "$name" ] || die "the node has no MagicDNS name (tailscale status --json in the guest)"

# 5. HTTPS certificates: console only (no API endpoint toggles it). The
#    tcp shape skips the requirement; the prompt offers it.
if [ "$SERVE" = https ]; then
    if [ -n "$(ts_get CertDomains)" ]; then
        ok "HTTPS certificates: on ($(ts_get CertDomains))"
    else
        console_step "HTTPS Certificates are off for this tailnet (needed for a trusted certificate on https://${name}/)" \
            "${CONSOLE}/dns -> HTTPS Certificates -> Enable HTTPS..." \
            "(no API can switch this; the alternative is TS_SERVE=tcp: the WAF's self-signed certificate, no console step)"
        if wait_for_enter "HTTPS Certificates are enabled"; then
            poll_until CertDomains '*' 90 || die "the node still reports no certificate domain; wait a moment and rerun make tailnet"
            ok "HTTPS certificates: on ($(ts_get CertDomains))"
        else
            SERVE=tcp
            warn "serving :443 as raw TCP to the WAF instead (self-signed certificate); rerun make tailnet after enabling HTTPS Certificates"
        fi
    fi
fi

# 6. key expiry: a server that silently drops off the tailnet in 180 days is
#    the failure nobody is around for. API when possible, a note otherwise.
expiry=$(ts_get Self.KeyExpiry)
if [ -z "$expiry" ]; then
    ok "key expiry: disabled"
elif api_ready && ts_api POST "device/${node_id}/key" '{"keyExpiryDisabled":true}' >/dev/null; then
    ok "key expiry: disabled through the API (was $expiry)"
else
    warn "key expiry: $expiry -- disable it once: ${CONSOLE}/machines -> ${name%%.*} -> ... -> Disable key expiry (TS_API_TOKEN would do it here)"
fi

# 7. the node: operator, accept-dns, serve -> WAF, proof. Root, in the guest.
info "configuring the node (operator ${VM_USER}, accept-dns, serve ${SERVE} -> WAF :${WAF_PORT})"
run_guest "$SERVE"
ts_refresh
name=$(node_name)
ip4=$(vm_ssh 'tailscale ip -4 2>/dev/null | head -n1' 2>/dev/null || true)
serve_out=$(vm_ssh "tailscale serve status 2>&1" 2>/dev/null || true)
case "$serve_out" in
*"127.0.0.1:${WAF_PORT}"*) ;;
*)
    printf '%s\n' "$serve_out" | sed 's/^/    /'
    die "tailscale serve is not pointing at the WAF; read the guest output above"
    ;;
esac

# 8. grobase: the tailnet name as an allowed origin (browsers that load an
#    app from it and call the API on another port). Same path as make
#    grobase_cors; Kong restarts only when the origin is new.
origin="https://${name}"
if vm_ssh "grep -qF -- '- ${origin}' /opt/grobase/infra/docker/services/kong/conf/kong.yml" 2>/dev/null; then
    ok "grobase CORS: ${origin} already allowed"
else
    info "grobase CORS: allowing ${origin} (Kong restarts, realtime is recreated)"
    vm_ssh "bash -s -- '${origin}'" <"$DC_ROOT/setup/host/grobase_cors_guest.sh" | sed 's/^/    /' ||
        warn "grobase_cors_guest.sh did not finish; make grobase_cors re-applies the profile's list, then rerun make tailnet"
fi

# 9. the proof from the guest (the host seat is not on the tailnet, and the
#    campus resolver answers NXDOMAIN for *.ts.net anyway).
#    Kong was just restarted when the origin was new: the WAF answers 502
#    until it is back (the first run printed "PRIVATE ... HTTP 502"), so a
#    gateway error is retried for a minute, not reported.
k=
[ "$SERVE" = tcp ] && k=-k
deadline=$(($(date +%s) + 60))
while :; do
    code=$(vm_ssh "curl -s $k -o /dev/null -w '%{http_code}' --max-time 20 https://${name}/" 2>/dev/null || true)
    case "${code:-000}" in '' | 000 | 502 | 503 | 504) ;; *) break ;; esac
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 5
done
case "${code:-000}" in
'' | 000) die "https://${name}/ does not answer from the guest yet (tailscale serve status; journalctl -u tailscaled; certificate issuance can take a minute -- rerun make tailnet)" ;;
502 | 503 | 504) die "https://${name}/ answers HTTP ${code}: serve reaches the WAF but Kong is not back yet (docker ps in the guest) -- rerun make tailnet" ;;
esac

# 10. remember it beside the VM, print the client side.
if [ -d "$VM_PATH/$VM_NAME" ]; then
    printf 'TS_DNSNAME=%s\nTS_IP4=%s\nTS_TAILNET=%s\nTS_SERVE=%s\nGROBASE_URL=https://%s\n' \
        "$name" "$ip4" "$tailnet" "$SERVE" "$name" >"$VM_PATH/$VM_NAME/tailnet.env"
fi
printf '\n'
if [ "$SERVE" = https ]; then
    ok "PRIVATE: https://${name}/ answers HTTP ${code} for tailnet peers, trusted certificate (that 404 is Kong: no route for /)"
else
    ok "PRIVATE: https://${name}/ answers HTTP ${code} for tailnet peers (TCP passthrough: self-signed, clients need -k / a trust exception)"
fi
printf '\n  client side, on any device logged into %s:\n' "$tailnet"
printf '    GROBASE_URL=https://%s\n' "$name"
printf '    BAAS_API_KEY=<BAAS_API_KEY from %s; make tenant_key mints one>\n' "$SECRETS_FILE"
printf '    curl -sI %s https://%s/auth/v1/health\n' "$k" "$name"
printf '  the WAF stays reachable by address too: https://%s:%s/ (self-signed)\n' "${ip4:-<tailnet ip>}" "$WAF_PORT"
printf '  frontends on other origins: [dc] cors_origins in the profile + make grobase_cors\n'
