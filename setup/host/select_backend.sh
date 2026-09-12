#!/usr/bin/env hellish
# ============================================================================ #
#  select_backend.sh — VirtualBox or QEMU/KVM? Decide, and say why.            #
# ============================================================================ #
#
# This project can run the same VM on two hypervisors. The guest is identical
# either way -- the same preseeded ISO, the same LUKS+LVM layout, the same
# b2b-setup.sh, the same first boot -- because the choice is only about what
# executes the machine, not about what is installed inside it.
#
#   virtualbox   the original path. Needs the out-of-tree vboxdrv kernel
#                module, and loading a kernel module needs root.
#   qemu         KVM is in the mainline kernel, so nothing has to be inserted;
#                it only has to be REACHABLE, which is a permission on
#                /dev/kvm. That is why it can work for an ordinary user on a
#                machine where VirtualBox cannot.
#
# It writes the resolved backend to stdout ("virtualbox" or "qemu") and all
# human-facing text to stderr, so a caller can do:  B=$(select_backend.sh)
#
# Usage:  select_backend.sh [auto|virtualbox|qemu]
#         BACKEND=qemu make all        (non-interactive override)
# ============================================================================ #

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$HERE/../../utils/vbox_driver.sh"

WANT="${1:-${BACKEND:-auto}}"

# The KVM probe, overridable so tests/test_select_backend.sh can describe a
# machine (guests running or not, KVM reachable or not) while running on one
# that is none of those. Production callers never set it.
KVM_PROBE="${KVM_PROBE:-$HERE/kvm_probe.sh}"

C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_RED=$'\033[31m'
C_DIM=$'\033[2m'
if [ ! -t 2 ] || [ -n "${NO_COLOR:-}" ]; then
    C_RESET=''
    C_BOLD=''
    C_GREEN=''
    C_YELLOW=''
    C_RED=''
    C_DIM=''
fi
say() { printf "%b\n" "$*" >&2; }

# ── What can this machine actually do, right now? ───────────────────────────
# Three answers, not two: a VirtualBox that is installed and whose driver is
# fine, but that cannot start a VM *this second* because a KVM guest holds the
# CPU's virtualization extension, is not the same thing as a VirtualBox that
# cannot work here at all. The first is transient and almost always
# self-inflicted -- it is this project's own qemu VM -- and the cure is one
# `make qemu_stop`. Folding it into "unavailable" is what made `make all` stop
# asking which hypervisor to use: with one backend left standing there was
# nothing to ask, so a machine where VirtualBox works perfectly built on qemu
# and never said the choice existed. Measured here 2026-09-12: VBoxManage
# startvm reached the hardware and failed VERR_SVM_IN_USE with two qemu guests
# up, and select_backend.sh reported "VirtualBox is unavailable here".
#
#   0  no -- not installed, or the driver cannot be used
#   1  yes
#   2  yes, once whatever holds VT-x/AMD-V lets go
vbox_ok=0
vbox_why="VBoxManage not installed"
vbox_holders=""
if command -v VBoxManage >/dev/null 2>&1; then
    vboxdrv_ok && vbox_ok=1
    vbox_why=$(vboxdrv_why)
    # The extension belongs to one hypervisor at a time: VirtualBox fails with
    # VERR_VMX_IN_VMX_ROOT_MODE (Intel) or VERR_SVM_IN_USE (AMD) while a KVM
    # guest runs -- the mirror image of the EBUSY kvm_probe.sh catches in the
    # other direction.
    if [ "$vbox_ok" = 1 ] && vbox_holders=$("${SCRIPT_SH:-bash}" "$KVM_PROBE" users); then
        vbox_ok=2
        vbox_why="ready, but a KVM guest holds the CPU's virtualization extension (VT-x/AMD-V); one hypervisor at a time"
    fi
fi

# What has to stop before VirtualBox can start, and how. Never stops anything
# itself: this script is also `make backend`, a question, and a question must
# not power off a VM. So it names the command instead -- and it does so BEFORE
# the ISO build and the 20-minute install, not a minute into VM startup, which
# is where a warning here used to surface.
vbox_blocked_report() {
    local names
    say ""
    say "  ${C_RED}${C_BOLD}VirtualBox cannot start a VM while a KVM guest is running.${C_RESET}"
    say ""
    printf '%s\n' "$vbox_holders" | sed '/^$/d; s|^|    holding VT-x/AMD-V : |' >&2
    # One line per VM, not per process. A qemu left over from an earlier
    # attempt and the live one share a -name (measured here: two processes
    # named `debian`, only one holding the qcow2), and printing the same
    # command twice reads as two different things needing to stop.
    names=$(printf '%s\n' "$vbox_holders" |
        awk '$1 ~ /^qemu-system/ && $3 == "(pid" { print $2 }' | sort -u)
    if [ -n "$names" ]; then
        say ""
        say "  Stop it, then run this again:"
        printf '%s\n' "$names" | sed 's|^|    make qemu_stop VM_NAME=|' >&2
    fi
    say ""
    say "  ${C_DIM}Or build on qemu instead:  make all BACKEND=qemu${C_RESET}"
    say "  ${C_DIM}Or, if you know better:    FORCE_BACKEND=1 make all BACKEND=virtualbox${C_RESET}"
    say ""
}

qemu_ok=0
qemu_why="qemu-system-x86_64 not installed"
if command -v qemu-system-x86_64 >/dev/null 2>&1; then
    # Ask KVM for a VM the way QEMU will, instead of trusting the permission
    # bits on /dev/kvm. The difference matters: while a VirtualBox VM runs it
    # owns VT-x, and KVM_CREATE_VM fails with EBUSY even though /dev/kvm is
    # perfectly readable. See kvm_probe.sh for the mechanism.
    # Without KVM QEMU still runs, but a Debian install under pure emulation
    # takes hours. Offering it silently would be a trap.
    if qemu_why=$("${SCRIPT_SH:-bash}" "$KVM_PROBE"); then
        qemu_ok=1
    else
        qemu_why="installed, but ${qemu_why}"
    fi
fi

# ── An explicit choice is honoured, with a warning if it looks broken ───────
case "$WANT" in
virtualbox | vbox)
    # A warning here scrolls past and the build fails minutes later inside
    # VBoxManage startvm, where the reason is a VERR_ code. Refuse now, unless
    # the caller says they mean it.
    if [ "$vbox_ok" = 2 ]; then
        if [ "${FORCE_BACKEND:-0}" != "1" ]; then
            vbox_blocked_report
            exit 1
        fi
        say "  ${C_YELLOW}⚠${C_RESET}  backend: ${C_BOLD}virtualbox${C_RESET} — FORCE_BACKEND=1 (${vbox_why})"
    fi
    [ "$vbox_ok" = 0 ] && say "  ${C_YELLOW}⚠${C_RESET}  BACKEND=virtualbox but: ${vbox_why}"
    [ "$vbox_ok" = 1 ] && say "  ${C_GREEN}✓${C_RESET} backend: ${C_BOLD}virtualbox${C_RESET} ${C_DIM}(${vbox_why})${C_RESET}"
    printf 'virtualbox'
    exit 0
    ;;
qemu | kvm)
    [ "$qemu_ok" = 1 ] || say "  ${C_YELLOW}⚠${C_RESET}  BACKEND=qemu but: ${qemu_why}"
    printf 'qemu'
    exit 0
    ;;
auto) : ;;
*)
    say "  ${C_RED}✗${C_RESET} unknown BACKEND '$WANT' (use: auto | virtualbox | qemu)"
    exit 1
    ;;
esac

# ── Neither works: say so once, clearly, and stop ───────────────────────────
if [ "$vbox_ok" = 0 ] && [ "$qemu_ok" = 0 ]; then
    say ""
    say "  ${C_RED}${C_BOLD}This machine cannot run a VM with either backend.${C_RESET}"
    say ""
    say "    VirtualBox : ${vbox_why}"
    say "    QEMU/KVM   : ${qemu_why}"
    say ""
    say "  Both need something only an administrator can grant: VirtualBox needs"
    say "  its kernel module inserted, KVM needs access to /dev/kvm."
    say "  ${C_DIM}Details: make check_driver${C_RESET}"
    say ""
    exit 1
fi

# ── Exactly one works: take it, and explain the switch ──────────────────────
if [ "$vbox_ok" != 0 ] && [ "$qemu_ok" = 0 ]; then
    [ "$vbox_ok" = 2 ] && {
        vbox_blocked_report
        exit 1
    }
    say "  ${C_GREEN}✓${C_RESET} backend: ${C_BOLD}virtualbox${C_RESET} ${C_DIM}(qemu: ${qemu_why})${C_RESET}"
    printf 'virtualbox'
    exit 0
fi
if [ "$qemu_ok" = 1 ] && [ "$vbox_ok" = 0 ]; then
    say "  ${C_GREEN}✓${C_RESET} backend: ${C_BOLD}qemu${C_RESET} ${C_DIM}(KVM accelerated)${C_RESET}"
    say "    ${C_DIM}VirtualBox is unavailable here: ${vbox_why}${C_RESET}"
    say "    ${C_DIM}The guest is identical -- same ISO, same preseed, same setup.${C_RESET}"
    printf 'qemu'
    exit 0
fi

# ── Both are real options: ask ─────────────────────────────────────────────
# "Real option" includes a VirtualBox that only needs the running KVM guest
# stopped, because that is the user's call to make and a one-line command to
# act on. Without a terminal the answer has to be assumed: prefer whatever can
# start a VM right now, because the no-terminal case is the automated one
# (CI, a background build) where nothing can stop a guest on request.
if [ ! -t 0 ] || [ "${ASSUME_DEFAULT:-0}" = "1" ]; then
    if [ "$vbox_ok" = 2 ]; then
        say "  ${C_GREEN}✓${C_RESET} backend: ${C_BOLD}qemu${C_RESET} ${C_DIM}(no terminal to ask on; VirtualBox needs the running KVM guest stopped)${C_RESET}"
        printf 'qemu'
        exit 0
    fi
    say "  ${C_GREEN}✓${C_RESET} backend: ${C_BOLD}virtualbox${C_RESET} ${C_DIM}(both available; no terminal to ask on)${C_RESET}"
    printf 'virtualbox'
    exit 0
fi

say ""
say "  ${C_BOLD}Both hypervisors work on this machine. Which should build the VM?${C_RESET}"
say ""
say "    ${C_BOLD}1) virtualbox${C_RESET}  the project's original path; VBoxManage NAT rules,"
say "                    ${C_DIM}snapshots, and the tooling most of the docs describe${C_RESET}"
[ "$vbox_ok" = 2 ] && {
    say "                    ${C_YELLOW}needs the running KVM guest stopped first${C_RESET}"
}
say "    ${C_BOLD}2) qemu${C_RESET}        KVM accelerated, no kernel module to install;"
say "                    ${C_DIM}works as an ordinary user wherever /dev/kvm is readable${C_RESET}"
say ""
say "  ${C_DIM}The guest is identical either way. Skip this next time with:${C_RESET}"
say "  ${C_DIM}  make all BACKEND=virtualbox   |   make all BACKEND=qemu${C_RESET}"
say ""
printf "  Choice [1]: " >&2
IFS= read -r ans </dev/tty || ans=""
case "$ans" in
2 | q* | Q*)
    say "  ${C_GREEN}✓${C_RESET} backend: ${C_BOLD}qemu${C_RESET}"
    printf 'qemu'
    ;;
*)
    if [ "$vbox_ok" = 2 ]; then
        vbox_blocked_report
        exit 1
    fi
    say "  ${C_GREEN}✓${C_RESET} backend: ${C_BOLD}virtualbox${C_RESET}"
    printf 'virtualbox'
    ;;
esac
