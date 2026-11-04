#!/usr/bin/env hellish
# Pins which row first boot measures install_edge.sh under.
#
# The bug it pins down: the script always ran as dc-netmesh and dc-tunnel was folded
# onto that row. A profile off Tailscale (server.toml, 2026-11-04) has no such row,
# so cloudflared was never installed and filed "failed with dc-netmesh".
# Caveat: runs the block by awk extraction, with dc_run and dc_fold stubbed.
# shellcheck disable=SC2317,SC2329 # called by the eval'd block
set -u
cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." || exit 1
fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s -- got: %s, expected: %s\n' "$1" "$2" "$3"
        fail=1
    fi
}
block=$(awk '/^if feature_on dc-netmesh \|\| feature_on dc-tunnel; then/{p=1} p{print} p && /^fi$/{exit}' preseeds/first-boot-setup.sh)
calls=""
dc_run() { calls="$calls run:$1"; }
dc_fold() { calls="$calls fold:$1"; }
feature_on() {
    case " $ON " in *" $1 "*) return 0 ;; esac
    return 1
}
plan() {
    ON="$1"
    calls=""
    eval "$block"
    printf '%s' "$calls"
}
check "both on: one install, measured under netmesh" "$(plan 'dc-netmesh dc-tunnel')" " run:dc-netmesh fold:dc-tunnel"
check "netmesh alone" "$(plan 'dc-netmesh')" " run:dc-netmesh"
check "tunnel alone: it gets its own install, and its own verdict" "$(plan 'dc-tunnel')" " run:dc-netmesh run:dc-tunnel"
check "neither: nothing" "$(plan '')" ""
exit "$fail"
