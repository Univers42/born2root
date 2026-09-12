#!/usr/bin/env hellish
# Regression test for setup/host/select_backend.sh.
#
# The bug it guards, live on this machine on 2026-09-12: `make all` stopped
# asking which hypervisor to use and silently built on qemu, on a machine
# where VirtualBox works. The cause was not the driver check (a hardened
# install had already been fixed for) but the one after it: VT-x/AMD-V belongs
# to one hypervisor at a time, and the project's OWN running qemu VM holds it,
# so VirtualBox was recorded as "unavailable". With one backend left standing
# there was nothing to ask about, the question never appeared, and the reason
# printed ("VirtualBox is unavailable here") pointed at the wrong thing --
# VBoxManage startvm proved otherwise by reaching the hardware and failing
# VERR_SVM_IN_USE.
#
# A guest holding the extension is transient and the user's own to stop, so it
# is a third state, not unavailability: the question is still asked, and an
# explicit BACKEND=virtualbox refuses BEFORE the ISO build with the exact
# `make qemu_stop` line instead of warning and dying minutes later inside
# VBoxManage startvm.
#
# Every probe is stubbed (VBoxManage, qemu-system-x86_64, the KVM probe, the
# driver fixtures), so this describes machines this host is not and needs
# neither VirtualBox nor /dev/kvm to run.
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
contains() {
    case "$2" in
    *"$3"*) printf 'ok   %-46s\n' "$1" ;;
    *)
        printf 'FAIL %-46s : no %s in output\n' "$1" "$3"
        fail=1
        ;;
    esac
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ── A machine with VirtualBox installed and its driver fine ─────────────────
mkdir -p "$TMP/bin" "$TMP/lib"
printf '#!/bin/sh\nexit 0\n' >"$TMP/bin/VBoxManage"
printf '#!/bin/sh\nexit 0\n' >"$TMP/bin/qemu-system-x86_64"
chmod 755 "$TMP/bin/VBoxManage" "$TMP/bin/qemu-system-x86_64"
# Hardened build: set-uid VirtualBoxVM, so root:root 0600 on the device is
# correct and the calling user never opens it.
printf '#!/bin/sh\n' >"$TMP/lib/VirtualBoxVM"
chmod 4711 "$TMP/lib/VirtualBoxVM"
printf 'vboxdrv 712704 2 vboxnetadp,vboxnetflt Live 0x0000000000000000\n' >"$TMP/modules"
: >"$TMP/vboxdrv"

# ── The KVM probe, stubbed: HOLDERS lists what owns the extension ───────────
cat >"$TMP/bin/kvm_probe" <<'PROBE'
#!/bin/sh
if [ "${1:-}" = users ]; then
    [ -s "$HOLDERS" ] || exit 1
    cat "$HOLDERS"
    exit 0
fi
if [ "${KVM_READY:-1}" = 1 ]; then
    echo "ready (KVM accelerated)"
    exit 0
fi
echo "/dev/kvm is not readable/writable by you"
exit 2
PROBE
chmod 755 "$TMP/bin/kvm_probe"

# Two stand-ins for stop_kvm_guests.sh: one that clears the way (the user said
# yes) and one that does not (declined, or no terminal to ask on).
# shellcheck disable=SC2016  # $FREED expands inside the stub, later
printf '#!/bin/sh\necho "  stopped" >&2\n: >"$FREED"\nexit 0\n' >"$TMP/bin/stop_free"
printf '#!/bin/sh\necho "  nothing stopped" >&2\nexit 1\n' >"$TMP/bin/stop_refuse"
chmod 755 "$TMP/bin/stop_free" "$TMP/bin/stop_refuse"

: >"$TMP/none"
printf 'qemu-system-x86_64 b2r (pid 1111)\n' >"$TMP/one"
# Two processes, one VM: a qemu left over from an earlier attempt and the live
# one share a -name. Measured here -- two named `debian`, one holding the
# qcow2 -- and printing `make qemu_stop VM_NAME=debian` twice reads as two
# different things needing to stop.
printf 'qemu-system-x86_64 debian (pid 2222)\nqemu-system-x86_64 debian (pid 3333)\n' >"$TMP/twins"

# Runs the real script with everything stubbed. stdout is the decision, stderr
# the human text; both are captured. Never a terminal, so the prompt is not
# reached: the no-terminal branch is what CI and a background build get.
run() {
    want="$1"
    holders="$2"
    # The decision goes to a FILE, not straight into `out=$(...)`. Under
    # hellish a multi-line command substitution reports exit status 0 whatever
    # the command did (single-line reports it correctly; bash reports it in
    # both), so an exit-code check written the obvious way passes no matter
    # what happened. A plain command's $? is reliable in both shells.
    set +e
    PATH="$TMP/bin:$PATH" \
        VBOXDRV_PROC_MODULES="$TMP/modules" \
        VBOX_LIB_DIR="$TMP/lib" \
        VBOXDRV_DEV="$TMP/vboxdrv" \
        KVM_PROBE="$TMP/bin/kvm_probe" \
        STOP_KVM_GUESTS="${STOP_STUB:-$TMP/bin/stop_refuse}" \
        HOLDERS="$holders" \
        FREED="$TMP/freed" \
        KVM_READY="${KVM_READY:-1}" \
        FORCE_BACKEND="${FORCE_BACKEND:-0}" \
        "${SCRIPT_SH:-bash}" "$REPO/setup/host/select_backend.sh" "$want" \
        >"$TMP/out" 2>"$TMP/err" </dev/null
    rc=$?
    set -e
    out=$(cat "$TMP/out")
    err=$(cat "$TMP/err")
}

# ── Nothing holds the extension: unchanged behaviour ────────────────────────
run auto "$TMP/none"
check "auto, both free, no tty" "$out" virtualbox
check "auto, both free: exit" "$rc" 0

run virtualbox "$TMP/none"
check "BACKEND=virtualbox, free" "$out" virtualbox
check "BACKEND=virtualbox, free: exit" "$rc" 0

# ── A running KVM guest: the regression ────────────────────────────────────
run auto "$TMP/one"
check "auto, guest holds it: picks qemu" "$out" qemu
check "auto, guest holds it: exit" "$rc" 0
contains "auto: says VirtualBox needs it stopped" "$err" "needs the running KVM guest stopped"
case "$err" in
*"unavailable"*)
    printf 'FAIL %-46s : still calls VirtualBox unavailable\n' "auto: no false 'unavailable'"
    fail=1
    ;;
*) printf 'ok   %-46s\n' "auto: no false 'unavailable'" ;;
esac

# ── An explicit choice refuses early and names the fix ─────────────────────
run virtualbox "$TMP/one"
check "BACKEND=virtualbox, blocked: exit" "$rc" 1
check "BACKEND=virtualbox, blocked: no decision" "$out" ""
contains "blocked: names the holder" "$err" "b2r (pid 1111)"
contains "blocked: names the fix" "$err" "make qemu_stop VM_NAME=b2r"
contains "blocked: offers qemu instead" "$err" "BACKEND=qemu"

# One line per VM, not per process.
run virtualbox "$TMP/twins"
stops=$(printf '%s\n' "$err" | grep -c "make qemu_stop VM_NAME=debian" || true)
check "two processes, one VM: one stop line" "$stops" 1

# ── The offer: picking virtualbox clears the way instead of printing
#    homework. Being asked which hypervisor to use, answering, and then being
#    told to run two commands by hand is a question that was not worth asking.
rm -f "$TMP/freed"
STOP_STUB="$TMP/bin/stop_free" run virtualbox "$TMP/one"
check "offer accepted: decision" "$out" virtualbox
check "offer accepted: exit" "$rc" 0
check "offer accepted: it really ran" "$([ -f "$TMP/freed" ] && echo yes || echo no)" yes
unset STOP_STUB

# Same through the question rather than BACKEND=, which is the route a person
# actually takes. No terminal here, so feed the answer on stdin: the prompt
# reads /dev/tty, so this exercises the decision, not the tty handling.
rm -f "$TMP/freed"
STOP_STUB="$TMP/bin/stop_free" run auto "$TMP/one"
check "no tty still prefers qemu" "$out" qemu
unset STOP_STUB

# ── FORCE_BACKEND=1 means "I know, do it anyway" ───────────────────────────
FORCE_BACKEND=1 run virtualbox "$TMP/one"
check "FORCE_BACKEND: honours the choice" "$out" virtualbox
check "FORCE_BACKEND: exit" "$rc" 0
unset FORCE_BACKEND

# ── Only one backend can work at all ───────────────────────────────────────
KVM_READY=0 run auto "$TMP/none"
check "no KVM: picks virtualbox" "$out" virtualbox
unset KVM_READY

VBOXDRV_DEV_SAVE="$TMP/vboxdrv"
mv "$TMP/vboxdrv" "$TMP/vboxdrv.away"
run auto "$TMP/none"
check "no vbox driver: picks qemu" "$out" qemu
contains "no vbox driver: says why" "$err" "VirtualBox is unavailable here"
mv "$TMP/vboxdrv.away" "$VBOXDRV_DEV_SAVE"

exit "$fail"
