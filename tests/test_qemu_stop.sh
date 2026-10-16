#!/usr/bin/env hellish
# Regression test for `qemu_vm.sh stop` when the VM was started from another
# VM_PATH.
#
# The bug it guards: every path in qemu_vm.sh is keyed on VM_PATH, so
# `make qemu_stop` run WITHOUT the VM_PATH the build used looked at the wrong
# pidfile, found nothing, and printed "✓ not running" while the VM kept
# running -- and kept holding VT-x, so the next `make all` reported VirtualBox
# "blocked" with the culprit invisible. other_guests() recovers the running
# guests and the VM_PATH each belongs to from QEMU's own -name / -pidfile
# arguments, and stop/kill refuse to claim success while any exist.
#
# qemu-system-x86_64 need not be installed to run this: qemu_vm.sh's own
# BASH_SOURCE guard skips both that check and the action dispatch when sourced.
set -e

cd "$(dirname "$0")/.."

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-40s = %s\n' "$1" "$2"
    else
        printf 'FAIL %-40s = %s (expected %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

VM_NAME=debian
VM_PATH="$TMP/here"
export VM_NAME VM_PATH

# VM_NAME is the real "debian": anything that reaches ensure_vm_dir would
# rewrite the developer's own disk_images/.vm_path.debian to point at $TMP.
export VM_PATH_REGISTRY="$TMP/registry"

. ./setup/host/qemu_vm.sh

# Three guests, as /proc would show them: ours, one of the same VM started
# from another VM_PATH (the reproduced case), and an unrelated VM that must be
# left alone. Trailing space is what `tr '\0' ' '` leaves on a real cmdline.
# shellcheck disable=SC2329,SC2317 # stub: qemu_vm.sh calls it through the source, which shellcheck cannot follow
qemu_cmdlines() {
    printf '%s\n' \
        "1001 /usr/bin/qemu-system-x86_64 -name debian -machine pc,accel=kvm -pidfile $TMP/here/debian/qemu.pid " \
        "1002 /usr/bin/qemu-system-x86_64 -name debian -machine pc,accel=kvm -pidfile /mnt/storage/virtualbox/other_machine/debian/qemu.pid " \
        "1003 /usr/bin/qemu-system-x86_64 -name debian-lab -machine pc -pidfile /srv/vms/debian-lab/qemu.pid "
}

check "our own guest is not 'other'" "$(other_guests | grep -c '^1001 ' || true)" 0
check "same VM from another VM_PATH found" "$(other_guests | grep '^1002 ' | cut -d' ' -f2)" /mnt/storage/virtualbox/other_machine
check "differently named VM ignored" "$(other_guests | grep -c '^1003 ' || true)" 0
check "exactly one other guest" "$(other_guests | wc -l)" 1

out=$(report_other_guests 2>&1) && rc=0 || rc=$?
check "report returns 0 when others exist" "$rc" 0
case "$out" in
*"VM_PATH=/mnt/storage/virtualbox/other_machine make qemu_stop"*)
    printf 'ok   %-40s\n' "report names the exact stop command"
    ;;
*)
    printf 'FAIL %-40s = %s\n' "report names the exact stop command" "$out"
    fail=1
    ;;
esac

# Nothing running anywhere: stop/kill may say "not running" and mean it.
# shellcheck disable=SC2329,SC2317 # stub: qemu_vm.sh calls it through the source, which shellcheck cannot follow
qemu_cmdlines() { :; }
check "no guests: none listed" "$(other_guests | wc -l)" 0
if report_other_guests >/dev/null 2>&1; then
    printf 'FAIL %-40s\n' "report returns 1 when none"
    fail=1
else
    printf 'ok   %-40s\n' "report returns 1 when none"
fi

# ── qemu_pid: a pidfile that exists but cannot be read -r is not "not running" ──
# (root-owned, from `sudo make all`). Fixture pids are not processes, so
# liveness is the seam.
# shellcheck disable=SC2329,SC2317 # stub: qemu_vm.sh calls it through the source, which shellcheck cannot follow
pid_alive() {
    case "$1" in 1001 | 1002) return 0 ;; esac
    return 1
}
# shellcheck disable=SC2329,SC2317 # stub: qemu_vm.sh calls it through the source, which shellcheck cannot follow
qemu_cmdlines() {
    printf '%s\n' \
        "1001 /usr/bin/qemu-system-x86_64 -name debian -machine pc,accel=kvm -pidfile $TMP/here/debian/qemu.pid " \
        "1002 /usr/bin/qemu-system-x86_64 -name debian -machine pc,accel=kvm -pidfile $TMP/elsewhere/debian/qemu.pid "
}
mkdir -p "$TMP/here/debian" "$TMP/elsewhere/debian"
printf '1002\n' >"$TMP/elsewhere/debian/qemu.pid"
: >"$PIDFILE"
chmod 000 "$PIDFILE"
check "unreadable pidfile: pid recovered" "$(qemu_pid)" 1001
check "unreadable pidfile: is_running" "$(if is_running; then echo yes; else echo no; fi)" yes
chmod 600 "$PIDFILE"
rm -f "$PIDFILE"
check "no pidfile at all: not running" "$(if is_running; then echo yes; else echo no; fi)" no

# ── adopt_other_guest: one candidate is taken, two are ambiguous ────────────
VM_PATH="$TMP/nowhere"
vm_paths
out=$(adopt_other_guest 2>&1) && rc=0 || rc=$?
check "two candidates: ambiguous (2)" "$rc" 2
case "$out" in
*"VM_PATH=$TMP/elsewhere make qemu_stop"*) printf 'ok   %-40s\n' "ambiguous: candidates listed" ;;
*)
    printf 'FAIL %-40s = %s\n' "ambiguous: candidates listed" "$out"
    fail=1
    ;;
esac
check "ambiguous: VM_PATH unchanged" "$VM_PATH" "$TMP/nowhere"

# shellcheck disable=SC2329,SC2317 # stub: qemu_vm.sh calls it through the source, which shellcheck cannot follow
qemu_cmdlines() {
    printf '%s\n' \
        "1002 /usr/bin/qemu-system-x86_64 -name debian -machine pc,accel=kvm -pidfile $TMP/elsewhere/debian/qemu.pid "
}
adopt_other_guest >/dev/null 2>&1 && rc=0 || rc=$?
check "one candidate: adopted (0)" "$rc" 0
check "adopted: VM_PATH re-keyed" "$VM_PATH" "$TMP/elsewhere"
check "adopted: PIDFILE follows" "$PIDFILE" "$TMP/elsewhere/debian/qemu.pid"
check "adopted: now running" "$(if is_running; then echo yes; else echo no; fi)" yes

# shellcheck disable=SC2329,SC2317 # stub: qemu_vm.sh calls it through the source, which shellcheck cannot follow
qemu_cmdlines() { :; }
VM_PATH="$TMP/nowhere"
vm_paths
adopt_other_guest >/dev/null 2>&1 && rc=0 || rc=$?
check "no candidate: none (1)" "$rc" 1

# ── await_shutdown: returns when the guest is gone, times out otherwise ─────
# is_running is the seam; sleep is stubbed so the test is instant. No progress
# line (STOP_PROGRESS=0) so stdout stays clean.
export STOP_PROGRESS=0
# shellcheck disable=SC2329,SC2317 # stub: qemu_vm.sh calls it through the source, which shellcheck cannot follow
sleep() { :; }   # never actually wait in the test
SERIAL=$(mktemp) # await_shutdown tails it on a TTY; empty is fine

# Goes down on the 3rd poll: await_shutdown must return 0.
_polls=0
# shellcheck disable=SC2329,SC2317 # stub: qemu_vm.sh calls it through the source, which shellcheck cannot follow
is_running() {
    _polls=$((_polls + 1))
    [ "$_polls" -lt 3 ]
}
await_shutdown 100 && rc=0 || rc=$?
check "await_shutdown: 0 once the guest is gone" "$rc" 0

# Never goes down within the grace: must time out with 1, not spin forever.
# shellcheck disable=SC2329,SC2317 # stub: qemu_vm.sh calls it through the source, which shellcheck cannot follow
is_running() { return 0; }
await_shutdown 2 && rc=0 || rc=$?
check "await_shutdown: times out with 1" "$rc" 1

unset -f sleep is_running
rm -f "$SERIAL"

# ── stop_guest: STOP_ON_TIMEOUT=abort never forces a guest that is still up ──
# A maintenance window stops the guest to resize its disk; a plug pulled after
# STOP_GRACE hands qemu-img a filesystem nobody unmounted. With abort the guest
# stays up, exit 3, and neither `quit` nor a signal is sent. Without it the
# path is the one the systemd unit's ExecStop has always relied on. The monitor
# and kill are recorders; the guest never goes down unless a case says so.
# shellcheck disable=SC2329,SC2317 # stub: stop_guest calls it, which shellcheck cannot see
mon() { printf '%s\n' "$1" >>"$TMP/mon.log"; }
# shellcheck disable=SC2329,SC2317 # stub: stop_guest calls it, which shellcheck cannot see
kill() { printf '%s\n' "$*" >>"$TMP/kill.log"; }
# shellcheck disable=SC2329,SC2317 # stub: stop_guest calls it, which shellcheck cannot see
sleep() { :; }
# shellcheck disable=SC2329,SC2317 # stub: stop_guest calls it, which shellcheck cannot see
is_running() { [ ! -f "$TMP/gone" ]; }
# shellcheck disable=SC2329,SC2317 # stub: stop_guest calls it, which shellcheck cannot see
await_shutdown() {
    [ -f "$TMP/goes-down" ] && : >"$TMP/gone"
    ! is_running
}
stop_case() { # <GRACEFUL> <STOP_ON_TIMEOUT> -> rc; mon.log, kill.log, out
    rm -f "$TMP/mon.log" "$TMP/kill.log" "$TMP/gone"
    : >"$TMP/mon.log"
    : >"$TMP/kill.log"
    (
        export GRACEFUL="$1" STOP_ON_TIMEOUT="$2" STOP_GRACE=5
        stop_guest 4242
    ) >"$TMP/out" 2>&1 && echo 0 || echo $?
}

check "abort, still up: exit 3" "$(stop_case 1 abort)" 3
check "abort, still up: only system_powerdown sent" "$(tr '\n' ' ' <"$TMP/mon.log")" "system_powerdown "
check "abort, still up: no signal sent" "$(wc -l <"$TMP/kill.log")" 0
check "abort, still up: says it was left running" "$(grep -c 'left running (pid 4242)' "$TMP/out")" 1

check "default, still up: plug pulled, then 'could not stop' (1)" "$(stop_case 1 '')" 1
check "default, still up: system_powerdown, no quit" "$(tr '\n' ' ' <"$TMP/mon.log")" "system_powerdown "
check "default, still up: SIGTERM then SIGKILL, as before" "$(tr '\n' ' ' <"$TMP/kill.log")" "4242 -9 4242 "
check "default, still up: warns it pulls the plug" "$(grep -c 'pulling the plug' "$TMP/out")" 1

: >"$TMP/goes-down"
check "abort, goes down in time: stopped (0)" "$(stop_case 1 abort)" 0
check "abort, goes down in time: no signal sent" "$(wc -l <"$TMP/kill.log")" 0
rm -f "$TMP/goes-down"

check "not graceful: quit at once (rc of the escalation)" "$(stop_case '' '')" 1
check "not graceful: the monitor gets quit" "$(tr '\n' ' ' <"$TMP/mon.log")" "quit "
check "abort without GRACEFUL=1: refused (1)" "$(stop_case '' abort)" 1
check "abort without GRACEFUL=1: nothing sent" "$(cat "$TMP/mon.log" "$TMP/kill.log" | wc -l)" 0
check "a misspelt mode: refused (1)" "$(stop_case 1 abrot)" 1
check "a misspelt mode: nothing sent" "$(cat "$TMP/mon.log" "$TMP/kill.log" | wc -l)" 0
unset -f mon kill sleep is_running await_shutdown

# `make qemu_restart` stops gracefully unless GRACEFUL is set: its bare stop
# used to be `quit`, a plug-pull of every engine in the guest (2026-10-16).
# The dispatch does not run when this file is sourced, so the line is read.
# shellcheck disable=SC2016 # the pattern is the literal source line
check "restart: a graceful stop by default, GRACEFUL= for the instant one" \
    "$(awk '/^    restart\)$/ { on = 1 } on && /^        ;;$/ { exit } on' setup/host/qemu_vm.sh | grep -c 'GRACEFUL="${GRACEFUL-1}" "$0" stop')" 1

exit "$fail"
