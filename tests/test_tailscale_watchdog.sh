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
    printf '#!/bin/sh\nprintf "100.1.2.3  node  node.ts.net  linux  %%s\\n" "$(cat %s/self)"\n' "$TMP" >"$TMP/bin/tailscale"
    printf '#!/bin/sh\nexit "$(cat %s/net)"\n' "$TMP" >"$TMP/bin/curl"
    printf '#!/bin/sh\necho "$*" >>%s/systemctl.log\n' "$TMP" >"$TMP/bin/systemctl"
    printf '#!/bin/sh\nexit 0\n' >"$TMP/bin/logger"
}
chmod +x "$TMP/bin/"*
run() { PATH="$TMP/bin:$PATH" B2B_TSWD_STATE="$TMP/state" sh "$TMP/watchdog"; }
restarts() { grep -c 'restart tailscaled' "$TMP/systemctl.log" 2>/dev/null || echo 0; }

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

exit "$fail"
