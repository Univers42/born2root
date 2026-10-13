#!/usr/bin/env hellish
# Regression test: the private plane is one target, and its guest half does
# what the host promised -- without a VM.
#
# tailnet_guest.sh runs against a stub `tailscale` (and stub docker/curl/
# systemctl/ufw on PATH) that records every call, so the test can pin the
# exact serve shape, the operator, --accept-dns, the TCP fallback and the
# refusal to serve https on a tailnet whose certificates are off. The host
# half is pinned statically: it must name the console pages it asks the
# operator to open, refuse to run a console step without a terminal, and
# never carry a credential on a command line.
#
# grobase_expose_guest.sh (grobase's `make expose` for exactly this node) runs
# against a stub make in a temp grobase tree. `make -n datacenter` pins the
# order a rebuild runs in: the restore, then the tailnet (whose address list
# a restore's .env.local would otherwise overwrite), then the realtime token,
# then the funnel when the profile asks for it.
set -u
cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." || exit 1

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-52s = %s\n' "$1" "$2"
    else
        printf 'FAIL %-52s = %s (expected %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}
SH="${SCRIPT_SH:-bash}"

# ── parse and lint-shape ────────────────────────────────────────────────────
for f in setup/host/tailnet.sh setup/host/tailnet_guest.sh setup/host/grobase_expose_guest.sh; do
    check "$f parses ($SH -n)" "$($SH -n "$f" 2>&1 && echo yes)" yes
done
check "tailnet.sh --help needs no VM" "$($SH setup/host/tailnet.sh --help >/dev/null 2>&1 && echo yes)" yes
check "the Makefile has tailnet, tailnet_status, tailnet_down" \
    "$(grep -cE '^tailnet(_status|_down)?:' Makefile)" 3
check "and they are .PHONY" "$(grep -c 'tailscale tailnet tailnet_status tailnet_down' Makefile)" 1
check "make datacenter runs tailnet" "$(grep -c 'no-print-directory tailnet ' Makefile)" 1

# ── the console steps are named, and never silently skipped ────────────────
h=setup/host/tailnet.sh
check "names the DNS page (MagicDNS, HTTPS Certificates)" "$(grep -c 'CONSOLE}/dns' $h)" 2
check "names the keys page (auth key, API token, 401 hint)" "$(grep -c 'CONSOLE}/settings/keys' $h)" 3
check "names the machine page (key expiry, an old node holding the name)" "$(grep -c 'CONSOLE}/machines' $h)" 2
# shellcheck disable=SC2016 # the pattern is the literal source line, not an expansion
check "TS_HOSTNAME falls back to the profile's [dc] tailnet_hostname" \
    "$(grep -c 'TS_HOSTNAME="${TS_HOSTNAME:-$(b2b_get B2B_DC_TAILNET_HOSTNAME)}"' $h)" 1
# shellcheck disable=SC2016 # the pattern is the literal source line, not an expansion
check "the first login takes that name too (make tailscale)" \
    "$(grep -c 'EDGE_TS_HOSTNAME="$(b2b_get B2B_DC_TAILNET_HOSTNAME)"' setup/host/tailscale_up.sh)" 1
written=$(grep -n 'tailnet.env"$' $h | head -n1 | cut -d: -f1)
exposed=$(grep -n 'grobase_expose_guest.sh"' $h | head -n1 | cut -d: -f1)
check "make expose runs after tailnet.env is written" \
    "$([ -n "$written" ] && [ -n "$exposed" ] && [ "$exposed" -gt "$written" ] && echo after)" after
check "without a terminal a console step dies" "$(grep -c 'is_tty || die' $h)" 1
check "the API credential travels on curl stdin (-K -)" "$(grep -c -- '-K - ' $h)" 2
check "no credential on an ssh command line" "$(grep -c 'vm_ssh.*TS_API_TOKEN\|vm_ssh.*AUTHKEY' $h)" 0
check "the secrets example documents TS_API_TOKEN" "$(grep -c '^TS_API_TOKEN=' .b2b-secrets.example)" 1
check "no literal key in the tree" "$(grep -rlE 'tskey-(auth|api)-[A-Za-z0-9]{6,}' setup tests Makefile .b2b-secrets.example 2>/dev/null | wc -l)" 0

# ── the guest half against a stub tailscale ────────────────────────────────
stub=$(mktemp -d)
trap 'rm -rf "$stub"' EXIT
mkdir -p "$stub/bin"
# The stub answers `status --json` from STUB_STATE / STUB_CERTS, records
# everything else in $stub/calls, and succeeds.
cat >"$stub/bin/tailscale" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$STUB_LOG"
case "$1 $2" in
"status --json")
    printf '{"BackendState":"%s","Self":{"DNSName":"vm.tailf00.ts.net.","ID":"nX"},"CertDomains":%s,"CurrentTailnet":{"MagicDNSEnabled":true}}\n' \
        "${STUB_STATE:-Running}" "${STUB_CERTS:-null}"
    ;;
"ip -4") echo 100.64.0.9 ;;
"serve status") echo "https://vm.tailf00.ts.net (tailnet only)" ;;
"funnel status") echo "No serve config" ;;
esac
exit 0
EOF
for c in systemctl ufw docker curl; do
    # shellcheck disable=SC2016 # the $ are for the stub, not for us
    printf '#!/bin/bash\nprintf "%s %%s\\n" "$*" >>"$STUB_LOG"\ncase "$1" in port) echo 0.0.0.0:8443 ;; -s) printf 404 ;; esac\nexit 0\n' "$c" >"$stub/bin/$c"
done
chmod +x "$stub/bin/"*
# PATH keeps the real python3/sed/mktemp/date; the stubs shadow the rest.
run_guest() {
    : >"$stub/calls"
    env PATH="$stub/bin:$PATH" STUB_LOG="$stub/calls" ROOTSH_WAIT=0 ROOTSH_TAILSCALE="$stub/bin/tailscale" "$@" \
        bash setup/host/tailnet_guest.sh >"$stub/out" 2>&1
    echo $?
}
calls() { grep -c -- "$1" "$stub/calls"; }

rc=$(run_guest env STUB_CERTS='["vm.tailf00.ts.net"]' ROOTSH_OPERATOR=alice ROOTSH_WAF_PORT=8443)
check "https: exits 0" "$rc" 0
check "https: serve --bg --https=443 https+insecure://127.0.0.1:8443" \
    "$(calls '^serve --bg --https=443 https+insecure://127.0.0.1:8443$')" 1
check "https: the tcp handler is removed first" "$(calls '^serve --tcp=443 off$')" 1
check "https: operator set" "$(calls '^set --operator=alice$')" 1
check "https: --accept-dns=true" "$(calls '^set --accept-dns=true$')" 1
check "https: a Running node is not logged in again" "$(calls '^up ')" 0
check "https: ufw admits tailscale0" "$(calls '^ufw allow in on tailscale0')" 1
check "https: proves the URL with a trusted certificate (no -k)" "$(grep -c -- '^curl .*-k' "$stub/calls")" 0
check "https: reports the name and the code" "$(grep -c '^TAILNET_NAME=vm.tailf00.ts.net$\|^TAILNET_HTTP=404$' "$stub/out")" 2

rc=$(run_guest env STUB_CERTS=null ROOTSH_SERVE=https)
check "https without certificates: refuses" "$rc" 1
check "https without certificates: names the switch" "$(grep -c 'HTTPS Certificates' "$stub/out")" 1
check "https without certificates: nothing served" "$(calls '^serve --bg')" 0

rc=$(run_guest env STUB_CERTS=null ROOTSH_SERVE=tcp)
check "tcp: exits 0 without certificates" "$rc" 0
check "tcp: serve --bg --tcp=443 tcp://127.0.0.1:8443 (port from docker)" \
    "$(calls '^serve --bg --tcp=443 tcp://127.0.0.1:8443$')" 1
check "tcp: the https handler is removed first" "$(calls '^serve --https=443 off$')" 1
check "tcp: proves the URL with -k (self-signed)" "$(grep -c -- '^curl .*-k' "$stub/calls")" 1

rc=$(run_guest env STUB_STATE=NeedsLogin ROOTSH_SERVE=tcp)
check "NeedsLogin without a key: refuses" "$rc" 1
check "NeedsLogin without a key: never calls up" "$(calls '^up ')" 0

rc=$(run_guest env ROOTSH_SERVE=off)
check "off: exits 0" "$rc" 0
check "off: both handlers removed, nothing served" "$(calls '^serve --https=443 off$')$(calls '^serve --tcp=443 off$')$(calls '^serve --bg')" 110

rc=$(run_guest env ROOTSH_SERVE=bogus)
check "ROOTSH_SERVE=bogus: refused" "$rc" 1

# ── grobase_expose_guest.sh against a stub make ────────────────────────────
g="$stub/grobase"
mkdir -p "$g/scripts/ops"
: >"$g/scripts/ops/expose.sh"
cat >"$stub/bin/make" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$STUB_LOG"
exit "$(cat "${STUB_LOG%/*}/make_rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$stub/bin/make"
expose() { # <args...> -> exit code; make's command lines in $stub/calls
    : >"$stub/calls"
    env PATH="$stub/bin:$PATH" STUB_LOG="$stub/calls" GROBASE_DIR="$g" \
        bash setup/host/grobase_expose_guest.sh "$@" >"$stub/out" 2>&1
    echo $?
}
printf 'GROBASE_PUBLIC_ADDRESSES=old-1.tailf00.ts.net,100.64.0.1\n' >"$g/.env.local"
check "expose: a new node's name and address: exit 0" "$(expose vm.tailf00.ts.net 100.64.0.9)" 0
check "expose: exactly this node, detection off, no trust store touched" \
    "$(cat "$stub/calls")" "--no-print-directory expose ARGS=--no-detect --replace --no-trust --add vm.tailf00.ts.net --add 100.64.0.9"
printf 'X=1\nGROBASE_PUBLIC_ADDRESSES=vm.tailf00.ts.net,100.64.0.9\n' >"$g/.env.local"
check "expose: the list already right: exit 0" "$(expose vm.tailf00.ts.net 100.64.0.9)" 0
check "expose: ... and make is not run (kong, gotrue, waf keep running)" "$(grep -c . "$stub/calls")" 0
check "expose: no IPv4 yet: the name alone" "$(expose vm.tailf00.ts.net)$(grep -c -- '--add vm.tailf00.ts.net$' "$stub/calls")" 01
echo 2 >"$stub/make_rc"
check "expose: make expose failing is reported" "$(expose other.tailf00.ts.net 100.64.0.9)" 2
rm -f "$stub/make_rc"
rm -f "$g/scripts/ops/expose.sh"
check "expose: a grobase without expose.sh (d180542): skipped, exit 0" \
    "$(expose other.tailf00.ts.net 100.64.0.9)$(grep -c . "$stub/calls")" 00
check "expose: ... and says so" "$(grep -c 'no scripts/ops/expose.sh' "$stub/out")" 1
check "expose: no name: refused" "$(expose)" 2

# ── make datacenter, in order ──────────────────────────────────────────────
dc_plan() { # <profile> -> make -n datacenter's lines
    env B2B_SECRETS="$stub/secrets" make -n --no-print-directory datacenter B2B_CONFIG="$1" 2>/dev/null
}
line_of() { printf '%s\n' "$1" | grep -n -m1 -- "$2" | cut -d: -f1; }
plan=$(dc_plan profiles/server.toml)
order=$(for step in 'no-print-directory restore ' 'no-print-directory tailnet ' 'no-print-directory realtime_token ' \
    'no-print-directory funnel_up ' 'no-print-directory backup '; do line_of "$plan" "$step"; done)
check "datacenter: restore, tailnet, realtime_token, funnel_up, backup" \
    "$(printf '%s\n' "$order" | grep -c .) $(printf '%s\n' "$order" | sort -n -c && echo ascending)" "5 ascending"
check "datacenter: no funnel unless the profile asks" \
    "$(dc_plan tests/fixtures/default.toml | grep -c 'funnel_up' || true)" 0

exit "$fail"
