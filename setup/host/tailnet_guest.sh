#!/usr/bin/env hellish
# tailnet_guest.sh -- runs INSIDE the guest, as root, pushed by
# setup/host/tailnet.sh through provision_vm.sh's root-sh path (sudo handled
# there, env quoted). It owns everything on the node that needs root:
#
#   1. tailscaled running, ufw admitting tailscale0 (install_edge.sh did it
#      once; a guest where ufw was reset loses the rule, so again, idempotent)
#   2. logged in -- with ROOTSH_AUTHKEY when the node has none (NeedsLogin),
#      a bare `up` when it was stopped (Stopped keeps the node key)
#   3. the operator (the login runs `tailscale status|serve` without sudo
#      afterwards; verify_platform.sh asks for that), MagicDNS accepted on the
#      node (--accept-dns), the hostname when asked to rename
#   4. `tailscale serve`: https://<node>.<tailnet>.ts.net/ -> the WAF, for
#      tailnet peers only (funnel.sh is the public twin). Two shapes:
#        https   TLS terminated by tailscaled with the tailnet's Let's Encrypt
#                certificate, then https+insecure to the WAF (self-signed for
#                "localhost"). Needs HTTPS Certificates on in the admin
#                console; the host checked CertDomains before sending this.
#        tcp     raw passthrough of :443 to the WAF: no certificate step, the
#                client sees the WAF's self-signed certificate (curl -k). The
#                fallback while the console switch is still off.
#      One handler per port: switching shape removes the other one first,
#      because tailscale refuses to set a web handler on a TCP-forwarded port.
#   5. proves it from the node itself (serve answers the node's own tailnet
#      address): the first HTTPS request triggers certificate issuance, which
#      takes up to a minute, hence the retry loop.
#
# ENV (ROOTSH_* is the prefix provision_vm.sh forwards for root-sh)
#   ROOTSH_SERVE      https (default) | tcp | off
#   ROOTSH_WAF_PORT   the WAF's published port; found with `docker port` when empty
#   ROOTSH_OPERATOR   login allowed to drive tailscale without sudo
#   ROOTSH_HOSTNAME   rename the node (its ts.net name follows); empty keeps it
#   ROOTSH_AUTHKEY    auth key, only read when the node is not logged in
#   ROOTSH_WAIT       seconds to wait for the URL to answer (default 120)
#   ROOTSH_TAILSCALE  the binary (tests point it at a stub)
set -u

SERVE="${ROOTSH_SERVE:-https}"
WAF_PORT="${ROOTSH_WAF_PORT:-}"
OPERATOR="${ROOTSH_OPERATOR:-}"
NEW_HOSTNAME="${ROOTSH_HOSTNAME:-}"
AUTHKEY="${ROOTSH_AUTHKEY:-}"
WAIT="${ROOTSH_WAIT:-120}"
TS="${ROOTSH_TAILSCALE:-tailscale}"

log() { printf '[tailnet] %s\n' "$*"; }
die() {
    printf '[tailnet] ERROR: %s\n' "$*" >&2
    exit 1
}

case "$SERVE" in https | tcp | off) ;; *) die "ROOTSH_SERVE=$SERVE (expected https, tcp or off)" ;; esac
command -v "$TS" >/dev/null 2>&1 || die "tailscale is not installed in this guest (make edge installs it)"

# ts_field PATH: one value out of `tailscale status --json`, by dotted path.
# Strings raw, booleans true/false, lists space-joined, absent -> empty.
JGET=$(mktemp /tmp/.tailnet-jget.XXXXXX)
trap 'rm -f "$JGET"' EXIT
cat >"$JGET" <<'PY'
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
ts_field() { "$TS" status --json 2>/dev/null | python3 "$JGET" "$1" 2>/dev/null; }

# ── 1. daemon and firewall ───────────────────────────────────────────────────
if command -v systemctl >/dev/null 2>&1; then
    systemctl is-active --quiet tailscaled ||
        systemctl enable --now tailscaled >/dev/null 2>&1 ||
        die "tailscaled did not start (systemctl status tailscaled)"
fi
if command -v ufw >/dev/null 2>&1; then
    ufw allow in on tailscale0 comment 'tailnet' >/dev/null 2>&1 || log "ufw: could not add the tailscale0 rule (ufw inactive?)"
fi

# ── 2. login ─────────────────────────────────────────────────────────────────
state=$(ts_field BackendState)
# `tailscale up` wants every non-default pref restated or it refuses with a
# list; --reset makes the call deterministic and step 3 re-applies the prefs
# this script cares about. --ssh=false: sshd on 4242 is the audited door.
up_flags=(--reset --ssh=false --accept-dns=true --timeout=90s)
[ -n "$OPERATOR" ] && up_flags+=(--operator="$OPERATOR")
[ -n "$NEW_HOSTNAME" ] && up_flags+=(--hostname="$NEW_HOSTNAME")
case "$state" in
Running)
    log "node is logged in"
    ;;
NeedsLogin | NoState | '')
    [ -n "$AUTHKEY" ] || die "the node is not logged in (state: ${state:-none}) and no auth key was given"
    log "logging in (state was: ${state:-none})"
    # The key reaches tailscale in this one process and is never echoed.
    if ! "$TS" up --authkey="$AUTHKEY" "${up_flags[@]}" >/dev/null 2>&1; then
        die "tailscale up was refused: the key is spent (not reusable), expired, or for another tailnet"
    fi
    ;;
Stopped)
    log "node was stopped; bringing it up"
    "$TS" up "${up_flags[@]}" >/dev/null 2>&1 || die "tailscale up failed from the Stopped state"
    ;;
*)
    die "unexpected backend state '$state' (tailscale status)"
    ;;
esac
state=$(ts_field BackendState)
[ "$state" = Running ] || die "node is not Running after login (state: $state)"

# ── 3. prefs ─────────────────────────────────────────────────────────────────
"$TS" set --accept-dns=true 2>/dev/null || log "could not set --accept-dns (MagicDNS names may not resolve on the node)"
if [ -n "$OPERATOR" ]; then
    if "$TS" set --operator="$OPERATOR" 2>/dev/null; then
        log "operator: $OPERATOR"
    else
        log "could not set the operator"
    fi
fi
if [ -n "$NEW_HOSTNAME" ]; then
    "$TS" set --hostname="$NEW_HOSTNAME" 2>/dev/null || die "tailscale set --hostname=$NEW_HOSTNAME was refused"
    # The DNS name follows the hostname after the control plane re-issues the
    # netmap; a few seconds, usually.
    i=0
    while [ "$i" -lt 10 ]; do
        case "$(ts_field Self.DNSName)" in "${NEW_HOSTNAME}."*) break ;; esac
        sleep 2
        i=$((i + 1))
    done
fi
name=$(ts_field Self.DNSName)
name=${name%.}
ip4=$("$TS" ip -4 2>/dev/null | head -n1)
[ -n "$name" ] || die "the node has no MagicDNS name yet (MagicDNS off on the tailnet? tailscale status --json)"
log "node: $name ($ip4)"

# ── 4. serve ─────────────────────────────────────────────────────────────────
if [ "$SERVE" = off ]; then
    "$TS" serve --https=443 off >/dev/null 2>&1 || true
    "$TS" serve --tcp=443 off >/dev/null 2>&1 || true
    log "serve: off; https://${name}/ no longer answers"
    printf 'TAILNET_NAME=%s\nTAILNET_IP4=%s\nTAILNET_SERVE=off\n' "$name" "$ip4"
    exit 0
fi

if [ -z "$WAF_PORT" ] && command -v docker >/dev/null 2>&1; then
    WAF_PORT=$(docker port mini-baas-waf 443/tcp 2>/dev/null | head -n1 | sed 's/.*://')
fi
case "$WAF_PORT" in '' | *[!0-9]*) die "the WAF is not publishing 443 (docker port mini-baas-waf) -- is grobase up?" ;; esac

if [ "$SERVE" = https ]; then
    certs=$(ts_field CertDomains)
    [ -n "$certs" ] || die "HTTPS Certificates are off for this tailnet (admin console: DNS -> HTTPS Certificates -> Enable); ROOTSH_SERVE=tcp serves without one"
    "$TS" serve --tcp=443 off >/dev/null 2>&1 || true
    target="https+insecure://127.0.0.1:${WAF_PORT}"
    out=$("$TS" serve --bg --https=443 "$target" 2>&1) || die "tailscale serve refused: $out"
else
    "$TS" serve --https=443 off >/dev/null 2>&1 || true
    target="tcp://127.0.0.1:${WAF_PORT}"
    out=$("$TS" serve --bg --tcp=443 "$target" 2>&1) || die "tailscale serve refused: $out"
fi
log "serve: https://${name}/ -> ${target} (${SERVE})"
case "$("$TS" funnel status 2>/dev/null)" in
*"Funnel on"*) log "NOTE: Funnel is also on for this node (public); make funnel_down closes it" ;;
esac

# ── 5. prove it ──────────────────────────────────────────────────────────────
url="https://${name}/"
curl_opts=(-s -o /dev/null -w '%{http_code}' --max-time 15)
[ "$SERVE" = tcp ] && curl_opts+=(-k)
deadline=$(($(date +%s) + WAIT))
code=000
log "waiting for ${url} to answer (certificate issuance can take a minute)"
while :; do
    code=$(curl "${curl_opts[@]}" "$url" 2>/dev/null) || true
    case "${code:-000}" in '' | 000) ;; *) break ;; esac
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 5
done
case "${code:-000}" in
'' | 000)
    log "WARNING: ${url} did not answer within ${WAIT}s (tailscale serve status; journalctl -u tailscaled)"
    ;;
*)
    if [ "$SERVE" = https ]; then
        log "OK: ${url} answers HTTP ${code} with a trusted certificate (that 404 is Kong: no route for /)"
    else
        log "OK: ${url} answers HTTP ${code} (TCP passthrough: the WAF's self-signed certificate, curl -k)"
    fi
    ;;
esac
"$TS" serve status 2>/dev/null | sed 's/^/    /'
printf 'TAILNET_NAME=%s\nTAILNET_IP4=%s\nTAILNET_SERVE=%s\nTAILNET_WAF_PORT=%s\nTAILNET_HTTP=%s\n' \
    "$name" "$ip4" "$SERVE" "$WAF_PORT" "${code:-000}"
