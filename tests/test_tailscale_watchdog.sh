#!/usr/bin/env hellish
# The tailscaled watchdog restarts a node control has dropped, and only that.
#
# THE FAILURE IT PINS
#   2026-10-21: after a network blip baas's control long-poll stayed stuck,
#   the node reported itself `offline`, and Tailscale Funnel reset every
#   visitor's TLS for 10 minutes while the tailnet itself looked fine. A
#   tailscaled restart fixed it in 2 s. This cuts the watchdog out of
#   install_edge.sh by its heredoc marker and runs it with tailscale, curl,
#   systemctl and logger stubbed: 3 offline checks restart once, a 4th does
#   not restart again, an online check resets the count, and a dead network
#   never restarts anything.
#
#   2026-10-22: after a re-login the node was online with Funnel on, but
#   control never heard that ingress was on, so the public name was NXDOMAIN
#   for over an hour. The same restart cured it. Pinned here: 3 checks with
#   no public A record (an NXDOMAIN answer whose SOA must not pass for an
#   address) restart once; a relay that answers any status is healthy; a
#   relay that does not answer counts; a DoH query that fails does not; and
#   the probe goes to the relay's address with the Funnel's own port.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-48s = %s\n' "$1" "$2"
    else
        printf 'FAIL %-48s = %s (want %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}

awk '/^    cat >\/usr\/local\/sbin\/b2b-tailscale-watchdog <<.WDEOF.$/ {on=1; next} /^WDEOF$/ {on=0} on' \
    "$REPO_ROOT/setup/install/dc/install_edge.sh" >"$TMP/watchdog"
[ -s "$TMP/watchdog" ] || {
    echo 'FAIL the watchdog heredoc was not found in install_edge.sh'
    exit 1
}

mkdir -p "$TMP/bin"
# shellcheck disable=SC2016 # expanded by the stubs, not here
{
    printf '#!/bin/sh\n[ "$1" != funnel ] || exec cat %s/funnel\nprintf "100.1.2.3  node  node.ts.net  linux  %%s\\n" "$(cat %s/self)"\n' "$TMP" "$TMP" >"$TMP/bin/tailscale"
    printf '#!/bin/sh\necho "$*" >>%s/curl.log\ncase "$*" in\n*dns-query*) cat %s/doh; exit "$(cat %s/dohrc)" ;;\n*--resolve*) exec cat %s/code ;;\nesac\nexit "$(cat %s/net)"\n' \
        "$TMP" "$TMP" "$TMP" "$TMP" "$TMP" >"$TMP/bin/curl"
    printf '#!/bin/sh\necho "$*" >>%s/systemctl.log\n' "$TMP" >"$TMP/bin/systemctl"
    printf '#!/bin/sh\necho "$*" >>%s/logger.log\n' "$TMP" >"$TMP/bin/logger"
}
chmod +x "$TMP/bin/"*
run() { PATH="$TMP/bin:$PATH" B2B_TSWD_STATE="$TMP/state" sh "$TMP/watchdog"; }
restarts() { grep -c 'restart tailscaled' "$TMP/systemctl.log" 2>/dev/null || echo 0; }

: >"$TMP/funnel"
echo 0 >"$TMP/net"
echo offline >"$TMP/self"
run
run
check 'two offline checks: no restart yet' "$(restarts)" 0
run
check 'the third offline check restarts tailscaled' "$(restarts)" 1
run
run
run
check 'three more within 10 minutes: no second restart' "$(restarts)" 1
echo - >"$TMP/self"
run
check 'an online check resets the count' "$(cat "$TMP/state/count")" 0

rm -rf "$TMP/state" "$TMP/systemctl.log"
echo offline >"$TMP/self"
echo 7 >"$TMP/net"
run
run
run
run
check 'network down: never a restart' "$(restarts)" 0

reset() { rm -rf "$TMP/state" "$TMP/systemctl.log" "$TMP/curl.log" "$TMP/logger.log"; }
reset
echo 0 >"$TMP/net"
echo - >"$TMP/self"
printf '%s\n' '# Funnel on:' '#     - https://node.ts.net:8443' '' \
    'https://node.ts.net:8443 (Funnel on)' '|-- / proxy http://127.0.0.1:3001' >"$TMP/funnel"
echo 0 >"$TMP/dohrc"
printf '%s' '{"Status":3,"Authority":[{"name":"ts.net","type":6,"TTL":300,"data":"ns1.dnsimple.com. admin.dnsimple.com. 1629538997 86400 7200 604800 300"}]}' >"$TMP/doh"
run
run
check 'online, Funnel name NXDOMAIN twice: no restart yet' "$(restarts)" 0
run
check 'the third NXDOMAIN check restarts tailscaled' "$(restarts)" 1
check '...and says why' "$(grep -c 'Funnel dead from the public side' "$TMP/logger.log")" 1
check 'an NXDOMAIN never reaches the relay probe' "$(grep -c -- '--resolve' "$TMP/curl.log")" 0

reset
printf '%s\n' 'https://node.ts.net (Funnel on)' 'https://node.ts.net:8443 (Funnel on)' >"$TMP/funnel"
printf '%s' '{"Status":0,"Answer":[{"name":"node.ts.net","type":1,"TTL":300,"data":"176.58.90.46"}]}' >"$TMP/doh"
echo 404 >"$TMP/code"
run
run
run
check 'a relay answering 404 is healthy' "$(restarts)" 0
check 'the probe resolves to the relay on port 443' \
    "$(grep -c -- '--resolve node.ts.net:443:176.58.90.46 https://node.ts.net/$' "$TMP/curl.log")" 3
echo 000 >"$TMP/code"
run
run
run
check 'a relay that does not answer: one restart' "$(restarts)" 1

reset
: >"$TMP/doh"
echo 6 >"$TMP/dohrc"
run
run
run
run
check 'DoH unreachable: no strike, no restart' "$(restarts):$(cat "$TMP/state/funnel")" 0:0

exit "$fail"
