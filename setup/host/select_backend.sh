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
	if [ -c /dev/vboxdrv ] && lsmod 2> /dev/null | grep -q '^vboxdrv'; then
		vbox_ok=1; vbox_why="ready"
	else
		vbox_why="installed, but the vboxdrv kernel module is not loaded (needs root)"
	fi
fi

qemu_ok=0
qemu_why="qemu-system-x86_64 not installed"
if command -v qemu-system-x86_64 > /dev/null 2>&1; then
	if [ -c /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
		qemu_ok=1; qemu_why="ready (KVM accelerated)"
	else
		# Without KVM QEMU still runs, but a Debian install under pure
		# emulation takes hours. Offering it silently would be a trap.
		qemu_why="installed, but /dev/kvm is not readable/writable by you"
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
