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
# that is genuinely busy (CPU, I/O, or a growing process tree) run to
# completion. A `sleep` TREE (a parent shell with a `sleep` child) stands in
# for "stalled": it holds pids open and burns no CPU ticks at all, which is
# exactly what the incident's nvim process looked like from outside. A
# process blocked in read() on a slow pipe stands in for "slow but alive" --
# also ~0% CPU, but its rchar in /proc/pid/io keeps moving, which CPU time
# alone cannot see and I/O tracking exists specifically to catch.
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

# shellcheck disable=SC2329 # called by run_with_inactivity_guard, eval'd below
warn() { printf '[test] WARN: %s\n' "$*" >&2; }

eval "$(awk '/^_nvim_guard_pid_tree\(\) \{/,/^}/' "$REPO/setup/install/nvim/install_nvim.sh")"
eval "$(awk '/^_nvim_guard_activity\(\) \{/,/^}/' "$REPO/setup/install/nvim/install_nvim.sh")"
eval "$(awk '/^_nvim_guard_kill_tree\(\) \{/,/^}/' "$REPO/setup/install/nvim/install_nvim.sh")"
eval "$(awk '/^run_with_inactivity_guard\(\) \{/,/^}/' "$REPO/setup/install/nvim/install_nvim.sh")"

# Fast polling so the test does not sit through production's 10 s cadence.
export NVIM_GUARD_POLL=1

# ── 1. A stalled TREE (0% CPU, 0 I/O) is killed well before its hard cap ────
# sh -c '... & wait' makes this a parent + child, not one pid, so it also
# exercises _nvim_guard_pid_tree's traversal, not just a single kill -0.
start=$(date +%s)
rc=0
run_with_inactivity_guard 2 300 sh -c 'sleep 999 & wait' || rc=$?
elapsed=$(($(date +%s) - start))
check "stalled tree: killed (rc=124)" "$rc" 124
if [ "$elapsed" -le 15 ]; then
    printf 'ok   %-50s = %ss (<= 15s, not the 300s hard cap)\n' "stalled tree: killed promptly" "$elapsed"
else
    printf 'FAIL %-50s = %ss (expected <= 15s)\n' "stalled tree: killed promptly" "$elapsed"
    fail=1
fi

# Both the parent shell and the sleep child must actually be dead, not just
# reaped by `wait`.
sleep 1
if pgrep -f '^sleep 999$' >/dev/null 2>&1; then
    printf 'FAIL %-50s = still running\n' "stalled tree: process reaped"
    fail=1
else
    printf 'ok   %-50s = not running\n' "stalled tree: process reaped"
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
# shellcheck disable=SC2016 # $i is meant for the inner sh, not this one
run_with_inactivity_guard 2 3 sh -c 'i=0; while [ $i -lt 100000000 ]; do i=$((i + 1)); done' || rc=$?
elapsed=$(($(date +%s) - start))
check "busy command: killed by the hard cap (rc=124)" "$rc" 124
if [ "$elapsed" -ge 2 ]; then
    printf 'ok   %-50s = %ss (>= hard cap, not the idle cap)\n' "busy command: ran past idle_secs" "$elapsed"
else
    printf 'FAIL %-50s = %ss (expected >= 2s)\n' "busy command: ran past idle_secs" "$elapsed"
    fail=1
fi

# ── 4. A slow-but-alive reader (near-0% CPU, real I/O) is NOT killed ────────
# A writer trickles one byte into a fifo every second, well inside idle_secs;
# a reader blocked on that fifo's read() burns almost no CPU between bytes,
# so CPU alone would call this "stalled" exactly like case 1. rchar moving
# each time a byte lands is what has to keep resetting the idle clock.
FIFO_DIR=$(mktemp -d)
trap 'rm -rf "$FIFO_DIR"' EXIT
mkfifo "$FIFO_DIR/pipe"
(
    for _ in 1 2 3 4 5 6; do
        sleep 1
        printf x
    done >"$FIFO_DIR/pipe"
) &
writer=$!
start=$(date +%s)
rc=0
run_with_inactivity_guard 3 60 sh -c "cat '$FIFO_DIR/pipe' >/dev/null" || rc=$?
elapsed=$(($(date +%s) - start))
wait "$writer" 2>/dev/null || true
check "slow reader: not killed, exits with the writer's EOF (rc=0)" "$rc" 0
if [ "$elapsed" -ge 5 ]; then
    printf 'ok   %-50s = %ss (ran the writer'"'"'s full ~6s, not stopped at idle_secs=3)\n' \
        "slow reader: survived past idle_secs" "$elapsed"
else
    printf 'FAIL %-50s = %ss (expected >= 5s)\n' "slow reader: survived past idle_secs" "$elapsed"
    fail=1
fi
rm -rf "$FIFO_DIR"
trap - EXIT

if [ "$fail" -eq 0 ]; then
    echo "All inactivity guard tests passed"
else
    echo "Some inactivity guard tests FAILED"
fi
exit "$fail"
