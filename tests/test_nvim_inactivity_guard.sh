#!/usr/bin/env hellish
# Regression test for install_nvim.sh / install_nvim_extras.sh's
# run_with_inactivity_guard, lifted out of install_nvim.sh with awk (they are
# byte-identical in both scripts; see the extras copy's own comment).
#
# What it guards: the 2026-09-30 incident. `nvim --headless` sat at ~0% CPU,
# no children, no sockets, and the plain `timeout $NVIM_BOOTSTRAP_TIMEOUT`
# that wrapped it waited out the FULL budget before the next retry started --
# up to 1200 s, three times. A real inactivity guard has to notice a stalled
# command and kill it long before its hard cap, while still letting a command
# that is genuinely busy (CPU or a growing process tree) run to completion.
# `sleep` stands in for "stalled": it holds a pid open and burns no CPU ticks
# at all, which is exactly what the incident's nvim process looked like from
# outside.
set -e

cd "$(dirname "$0")/.."
REPO=$(pwd)

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-50s = %s\n' "$1" "$2"
    else
        printf 'FAIL %-50s = %s (expected %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}

warn() { printf '[test] WARN: %s\n' "$*" >&2; }

eval "$(awk '/^_nvim_guard_pid_tree\(\) \{/,/^}/' "$REPO/setup/install/nvim/install_nvim.sh")"
eval "$(awk '/^_nvim_guard_cpu_ticks\(\) \{/,/^}/' "$REPO/setup/install/nvim/install_nvim.sh")"
eval "$(awk '/^run_with_inactivity_guard\(\) \{/,/^}/' "$REPO/setup/install/nvim/install_nvim.sh")"

# Fast polling so the test does not sit through production's 10 s cadence.
export NVIM_GUARD_POLL=1

# ── 1. A stalled command (sleep, 0% CPU) is killed well before its hard cap ──
start=$(date +%s)
rc=0
run_with_inactivity_guard 2 300 sleep 999 || rc=$?
elapsed=$(($(date +%s) - start))
check "stalled command: killed (rc=124)" "$rc" 124
if [ "$elapsed" -le 15 ]; then
    printf 'ok   %-50s = %ss (<= 15s, not the 300s hard cap)\n' "stalled command: killed promptly" "$elapsed"
else
    printf 'FAIL %-50s = %ss (expected <= 15s)\n' "stalled command: killed promptly" "$elapsed"
    fail=1
fi

# The pid must actually be dead, not just reaped by `wait`.
sleep 1
if pgrep -f "sleep 999" >/dev/null 2>&1; then
    printf 'FAIL %-50s = still running\n' "stalled command: process reaped"
    fail=1
else
    printf 'ok   %-50s = not running\n' "stalled command: process reaped"
fi

# ── 2. A command that finishes on its own is not killed early ───────────────
rc=0
run_with_inactivity_guard 2 300 true || rc=$?
check "quick command: exit code passed through" "$rc" 0

rc=0
run_with_inactivity_guard 2 300 sh -c 'exit 7' || rc=$?
check "quick command: non-zero exit code passed through" "$rc" 7

# ── 3. A command that stays busy is not mistaken for idle ───────────────────
# A tight loop burns CPU every poll tick, so idle_elapsed must never reach
# idle_secs; only the hard cap can end it.
start=$(date +%s)
rc=0
run_with_inactivity_guard 2 3 sh -c 'i=0; while [ $i -lt 100000000 ]; do i=$((i + 1)); done' || rc=$?
elapsed=$(($(date +%s) - start))
check "busy command: killed by the hard cap (rc=124)" "$rc" 124
if [ "$elapsed" -ge 2 ]; then
    printf 'ok   %-50s = %ss (>= hard cap, not the idle cap)\n' "busy command: ran past idle_secs" "$elapsed"
else
    printf 'FAIL %-50s = %ss (expected >= 2s)\n' "busy command: ran past idle_secs" "$elapsed"
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "All inactivity guard tests passed"
else
    echo "Some inactivity guard tests FAILED"
fi
exit "$fail"
