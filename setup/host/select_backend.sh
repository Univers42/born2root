#!/usr/bin/env bash
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

WANT="${1:-${BACKEND:-auto}}"

C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'
if [ ! -t 2 ] || [ -n "${NO_COLOR:-}" ]; then
	C_RESET=''; C_BOLD=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_DIM=''
fi
say() { printf "%b\n" "$*" >&2; }

# ── What can this machine actually do, right now? ───────────────────────────
vbox_ok=0
vbox_why="VBoxManage not installed"
if command -v VBoxManage > /dev/null 2>&1; then
	# /sys/module/<name> exists exactly when the module is loaded. Do NOT use
	# `lsmod | grep -q` here: with pipefail, grep -q exits on the first match,
	# lsmod gets SIGPIPE on its next write (its output is >4 KB), and the whole
	# pipeline reports failure -- a loaded driver shows up as "not loaded".
	if [ -c /dev/vboxdrv ] && [ -d /sys/module/vboxdrv ]; then
		vbox_ok=1; vbox_why="ready"
		# A loaded driver is not the whole story. VT-x belongs to one
		# hypervisor at a time, and a running KVM guest holds it: VirtualBox
		# would fail with VERR_VMX_IN_VMX_ROOT_MODE -- the mirror image of
		# the EBUSY that kvm_probe.sh catches in the other direction.
		if kvm_users=$(bash "$(dirname "${BASH_SOURCE[0]}")/kvm_probe.sh" users); then
			vbox_ok=0
			vbox_why="blocked: a KVM guest is running ($(printf '%s' "$kvm_users" | paste -sd, -)) and holds VT-x; one hypervisor at a time"
		fi
	else
		vbox_why="installed, but the vboxdrv kernel module is not loaded (needs root)"
	fi
fi

qemu_ok=0
qemu_why="qemu-system-x86_64 not installed"
if command -v qemu-system-x86_64 > /dev/null 2>&1; then
	# Ask KVM for a VM the way QEMU will, instead of trusting the permission
	# bits on /dev/kvm. The difference matters: while a VirtualBox VM runs it
	# owns VT-x, and KVM_CREATE_VM fails with EBUSY even though /dev/kvm is
	# perfectly readable. See kvm_probe.sh for the mechanism.
	# Without KVM QEMU still runs, but a Debian install under pure emulation
	# takes hours. Offering it silently would be a trap.
	if qemu_why=$(bash "$(dirname "${BASH_SOURCE[0]}")/kvm_probe.sh"); then
		qemu_ok=1
	else
		qemu_why="installed, but ${qemu_why}"
	fi
fi

# ── An explicit choice is honoured, with a warning if it looks broken ───────
case "$WANT" in
	virtualbox | vbox)
		[ "$vbox_ok" = 1 ] || say "  ${C_YELLOW}⚠${C_RESET}  BACKEND=virtualbox but: ${vbox_why}"
		printf 'virtualbox'; exit 0 ;;
	qemu | kvm)
		[ "$qemu_ok" = 1 ] || say "  ${C_YELLOW}⚠${C_RESET}  BACKEND=qemu but: ${qemu_why}"
		printf 'qemu'; exit 0 ;;
	auto) : ;;
	*) say "  ${C_RED}✗${C_RESET} unknown BACKEND '$WANT' (use: auto | virtualbox | qemu)"; exit 1 ;;
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
if [ "$vbox_ok" = 1 ] && [ "$qemu_ok" = 0 ]; then
	say "  ${C_GREEN}✓${C_RESET} backend: ${C_BOLD}virtualbox${C_RESET} ${C_DIM}(qemu: ${qemu_why})${C_RESET}"
	printf 'virtualbox'; exit 0
fi
if [ "$qemu_ok" = 1 ] && [ "$vbox_ok" = 0 ]; then
	say "  ${C_GREEN}✓${C_RESET} backend: ${C_BOLD}qemu${C_RESET} ${C_DIM}(KVM accelerated)${C_RESET}"
	say "    ${C_DIM}VirtualBox is unavailable here: ${vbox_why}${C_RESET}"
	say "    ${C_DIM}The guest is identical -- same ISO, same preseed, same setup.${C_RESET}"
	printf 'qemu'; exit 0
fi

# ── Both work: this is the only case worth asking about ────────────────────
if [ ! -t 0 ] || [ "${ASSUME_DEFAULT:-0}" = "1" ]; then
	say "  ${C_GREEN}✓${C_RESET} backend: ${C_BOLD}virtualbox${C_RESET} ${C_DIM}(both available; no terminal to ask on)${C_RESET}"
	printf 'virtualbox'; exit 0
fi

say ""
say "  ${C_BOLD}Both hypervisors work on this machine. Which should build the VM?${C_RESET}"
say ""
say "    ${C_BOLD}1) virtualbox${C_RESET}  the project's original path; VBoxManage NAT rules,"
say "                    ${C_DIM}snapshots, and the tooling most of the docs describe${C_RESET}"
say "    ${C_BOLD}2) qemu${C_RESET}        KVM accelerated, no kernel module to install;"
say "                    ${C_DIM}works as an ordinary user wherever /dev/kvm is readable${C_RESET}"
say ""
say "  ${C_DIM}The guest is identical either way. Skip this next time with:${C_RESET}"
say "  ${C_DIM}  make all BACKEND=virtualbox   |   make all BACKEND=qemu${C_RESET}"
say ""
printf "  Choice [1]: " >&2
IFS= read -r ans < /dev/tty || ans=""
case "$ans" in
	2 | q* | Q*) say "  ${C_GREEN}✓${C_RESET} backend: ${C_BOLD}qemu${C_RESET}"; printf 'qemu' ;;
	*)           say "  ${C_GREEN}✓${C_RESET} backend: ${C_BOLD}virtualbox${C_RESET}"; printf 'virtualbox' ;;
esac
