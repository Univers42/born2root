#!/usr/bin/env hellish
# ============================================================================ #
#  stop_kvm_guests.sh — free VT-x/AMD-V so VirtualBox can start a VM           #
# ============================================================================ #
#
# The CPU's virtualization extension belongs to ONE hypervisor at a time. While
# any KVM guest runs, VirtualBox cannot start one: it reaches the hardware and
# fails with VERR_VMX_IN_VMX_ROOT_MODE (Intel) or VERR_SVM_IN_USE (AMD). The
# reverse is the EBUSY from KVM_CREATE_VM that kvm_probe.sh catches.
#
# So when someone answers "virtualbox" to select_backend.sh's question, the
# honest thing is to offer to clear the way, not to print instructions and
# exit: being asked which hypervisor to use, answering, and then being told to
# go and run two commands by hand is a question that was not worth asking.
#
# It never stops anything unasked. With a terminal it names every guest and
# waits for a y; with --yes (what a caller passes once the user has already
# chosen) it proceeds; with neither it refuses and exits 1 so the caller can
# print the manual route.
#
# Stopping goes through qemu_vm.sh when the guest is one of this project's --
# the monitor `quit` exits QEMU at once AND flushes the qcow2, which a kill
# would not -- and falls back to SIGTERM (QEMU's own clean-exit path) then
# SIGKILL for anything else, e.g. a guest whose VM directory has already been
# removed and whose pidfile is gone with it.
#
# All human text goes to stderr, so a caller can capture stdout unaffected.
#
# Usage:  stop_kvm_guests.sh [--yes]
# exit:   0 nothing holds the extension any more · 1 something still does
# ============================================================================ #

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

KVM_PROBE="${KVM_PROBE:-$HERE/kvm_probe.sh}"
QEMU_VM="${QEMU_VM:-$HERE/qemu_vm.sh}"
ASSUME_YES=0
[ "${1:-}" = "--yes" ] && ASSUME_YES=1
[ "${STOP_KVM_YES:-0}" = "1" ] && ASSUME_YES=1

C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_DIM=$'\033[2m'
if [ ! -t 2 ] || [ -n "${NO_COLOR:-}" ]; then
    C_RESET='' C_BOLD='' C_GREEN='' C_YELLOW='' C_DIM=''
fi
say() { printf "%b\n" "$*" >&2; }

# Is there a terminal to ask a question on? `[ -r /dev/tty ]` is not the test:
# the node exists with permissive modes even when the process has no
# controlling terminal, and the open then fails with ENXIO ("No such device or
# address") halfway through the prompt. Opening it in a subshell is the only
# answer that matches what `read </dev/tty` will do, and a subshell keeps a
# failed redirection from taking the script down with it.
tty_available() { (: </dev/tty) 2>/dev/null; }

holders() { "${SCRIPT_SH:-bash}" "$KVM_PROBE" users; }

# The VM directory of one of this project's guests. VM_PATH wins when set (the
# Makefile exports it); otherwise the registry disk_images/.vm_path.<name> is
# where a relocated VM is remembered, and disk_images/ is the default.
vm_dir_for() {
    local name="$1" base
    if [ -n "${VM_PATH:-}" ]; then
        printf '%s/%s' "$VM_PATH" "$name"
        return 0
    fi
    base=$(cat "$REPO_ROOT/disk_images/.vm_path.$name" 2>/dev/null) || base=""
    [ -n "$base" ] || base="$REPO_ROOT/disk_images"
    printf '%s/%s' "$base" "$name"
}

# One guest. $1 pid, $2 its -name or empty.
stop_one() {
    local pid="$1" name="${2:-}" dir="" i
    if [ -n "$name" ]; then
        dir=$(vm_dir_for "$name")
        # Only hand it to qemu_vm.sh when the pidfile really is this process:
        # a stale pidfile from an earlier attempt would otherwise make it
        # report "not running" and leave the guest alone.
        if [ "$(cat "$dir/qemu.pid" 2>/dev/null)" = "$pid" ]; then
            say "    ${C_DIM}${name} (pid ${pid}): qemu_vm.sh stop${C_RESET}"
            VM_NAME="$name" VM_PATH="$(dirname "$dir")" \
                "${SCRIPT_SH:-bash}" "$QEMU_VM" stop >/dev/null 2>&1 || true
        fi
    fi
    kill -0 "$pid" 2>/dev/null || return 0
    say "    ${C_DIM}pid ${pid}: SIGTERM${C_RESET}"
    kill -TERM "$pid" 2>/dev/null || true
    i=0
    while [ "$i" -lt 20 ]; do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.5
        i=$((i + 1))
    done
    say "    ${C_YELLOW}pid ${pid}: still there after 10s — SIGKILL${C_RESET}"
    kill -9 "$pid" 2>/dev/null || true
    sleep 1
}

list=$(holders) || {
    say "  ${C_GREEN}✓${C_RESET} nothing holds VT-x/AMD-V"
    exit 0
}

say ""
say "  ${C_BOLD}These hold the CPU's virtualization extension:${C_RESET}"
printf '%s\n' "$list" | sed '/^$/d; s|^|    |' >&2
say ""

if [ "$ASSUME_YES" != 1 ]; then
    if ! tty_available; then
        say "  ${C_YELLOW}⚠${C_RESET}  no terminal to confirm on — nothing stopped"
        exit 1
    fi
    printf "  Stop them now? [y/N]: " >&2
    IFS= read -r ans </dev/tty || ans=""
    case "$ans" in
    y* | Y*) : ;;
    *)
        say "  nothing stopped"
        exit 1
        ;;
    esac
fi

# Names come from kvm_probe's "<comm> <-name> (pid N)" lines; a guest started
# without -name has no second field and is signalled by pid alone.
printf '%s\n' "$list" |
    awk '{ pid = $NF; gsub(/[()]/, "", pid); name = ($3 == "(pid" ? $2 : ""); print pid, name }' |
    while read -r pid name; do
        [ -n "$pid" ] || continue
        stop_one "$pid" "$name"
    done

# Confirm from the hardware's side rather than from what was killed: the point
# was never "the processes are gone", it is "the extension is free".
i=0
while [ "$i" -lt 20 ]; do
    if ! holders >/dev/null 2>&1; then
        say "  ${C_GREEN}✓${C_RESET} VT-x/AMD-V is free"
        exit 0
    fi
    sleep 1
    i=$((i + 1))
done

say "  ${C_YELLOW}⚠${C_RESET}  still held:"
holders | sed '/^$/d; s|^|    |' >&2
exit 1
