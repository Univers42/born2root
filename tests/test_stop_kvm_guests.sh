#!/usr/bin/env hellish
# Regression test for setup/host/stop_kvm_guests.sh.
#
# What it guards: answering "virtualbox" to select_backend.sh's question used
# to print two `make qemu_stop` lines and exit 1, which is a question not
# worth asking. This script is what makes the answer stick, so the two things
# that must hold are (1) it never stops anything without being told to, and
# (2) when told to, it actually frees the extension -- including for a guest
# whose VM directory has already been removed, where qemu_vm.sh has no pidfile
# left to work from and only a signal will do. Both were live on this machine
# on 2026-09-12: three qemu processes holding deleted images and VT-x with
# them, after a make fclean.
#
# Real processes stand in for the guests (sleep, not qemu) and a stub probe
# reports them as holders for exactly as long as they live, so "the extension
# is free" is observed rather than assumed.
set -e

cd "$(dirname "$0")/.."
REPO=$(pwd)

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-46s = %s\n' "$1" "$3"
    else
        printf 'FAIL %-46s = %s (expected %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}

TMP=$(mktemp -d)
# shellcheck disable=SC2317  # every line below runs from the EXIT trap
cleanup() {
    # Never leave a stand-in behind, whatever the test did.
    if [ -s "$TMP/pids" ]; then
        while read -r p; do
            kill -9 "$p" 2>/dev/null || true
        done <"$TMP/pids"
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT

# A probe that reports the stand-ins as holders while they are alive, and
# nothing once they are gone -- the shape kvm_probe.sh users has.
cat >"$TMP/kvm_probe" <<'PROBE'
#!/bin/sh
if [ "${1:-}" = users ]; then
    alive=0
    while read -r p; do
        [ -n "$p" ] || continue
        if kill -0 "$p" 2>/dev/null; then
            alive=1
            echo "qemu-system-x86_64 fixture (pid $p)"
        fi
    done <"$HOLDER_PIDS"
    [ "$alive" = 1 ] || exit 1
    exit 0
fi
echo "ready (KVM accelerated)"
PROBE
chmod 755 "$TMP/kvm_probe"

# qemu_vm.sh must not be reached: these stand-ins have no VM directory, which
# is exactly the deleted-image case. If it ever is, the test says so.
# shellcheck disable=SC2016  # $QEMU_VM_CALLED expands inside the stub, later
printf '#!/bin/sh\ntouch "$QEMU_VM_CALLED"\nexit 0\n' >"$TMP/qemu_vm"
chmod 755 "$TMP/qemu_vm"

spawn() {
    : >"$TMP/pids"
    i=0
    while [ "$i" -lt "$1" ]; do
        # Orphaned on purpose: a stand-in that is this shell's own job gets a
        # "Killed" notification printed over the test's output when it dies.
        sh -c 'sleep 300 >/dev/null 2>&1 & echo $!' >>"$TMP/pids"
        i=$((i + 1))
    done
}
alive_count() {
    n=0
    while read -r p; do
        if kill -0 "$p" 2>/dev/null; then n=$((n + 1)); fi
    done <"$TMP/pids"
    echo "$n"
}
# Every variable the script reads is passed explicitly. Under hellish an
# assignment prefix on a FUNCTION call (`STOP_KVM_YES=1 run`) sets a shell
# variable for the call but does not export it to the commands the function
# then runs, so relying on inheritance passes under bash and silently tests
# nothing under the shell this project actually uses.
run() {
    KVM_PROBE="$TMP/kvm_probe" \
        STOP_KVM_YES="${STOP_KVM_YES:-0}" \
        QEMU_VM="$TMP/qemu_vm" \
        QEMU_VM_CALLED="$TMP/qemu_vm_called" \
        HOLDER_PIDS="$TMP/pids" \
        "${SCRIPT_SH:-bash}" "$REPO/setup/host/stop_kvm_guests.sh" "$@" \
        >"$TMP/out" 2>"$TMP/err" </dev/null && rc=0 || rc=$?
    err=$(cat "$TMP/err")
}

# ── Told to: the guests go and the extension comes free ────────────────────
spawn 2
run --yes
check "--yes: exit" "$rc" 0
check "--yes: guests stopped" "$(alive_count)" 0
case "$err" in
*"free"*) printf 'ok   %-46s\n' "--yes: reports the extension free" ;;
*)
    printf 'FAIL %-46s : %s\n' "--yes: reports the extension free" "$err"
    fail=1
    ;;
esac
check "--yes: no pidfile, so no qemu_vm.sh" \
    "$([ -f "$TMP/qemu_vm_called" ] && echo yes || echo no)" no

# ── Not told to, and no terminal: nothing is touched ───────────────────────
spawn 2
run
check "declined: exit" "$rc" 1
check "declined: guests untouched" "$(alive_count)" 2
case "$err" in
*"no terminal"*) printf 'ok   %-46s\n' "declined: says why" ;;
*)
    printf 'FAIL %-46s : %s\n' "declined: says why" "$err"
    fail=1
    ;;
esac
while read -r p; do
    kill -9 "$p" 2>/dev/null || true
done <"$TMP/pids"

# ── Nothing holds it: says so, exits 0, asks nobody ────────────────────────
: >"$TMP/pids"
run
check "nothing held: exit" "$rc" 0
case "$err" in
*"nothing holds"*) printf 'ok   %-46s\n' "nothing held: says so" ;;
*)
    printf 'FAIL %-46s : %s\n' "nothing held: says so" "$err"
    fail=1
    ;;
esac

# ── STOP_KVM_YES=1 is the same as --yes ────────────────────────────────────
spawn 1
STOP_KVM_YES=1 run
check "STOP_KVM_YES=1: exit" "$rc" 0
check "STOP_KVM_YES=1: guest stopped" "$(alive_count)" 0

exit "$fail"
