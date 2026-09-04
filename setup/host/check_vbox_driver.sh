#!/usr/bin/env bash
# ============================================================================ #
#  check_vbox_driver.sh — can THIS machine actually run a VM right now?        #
# ============================================================================ #
#
# WHY THIS EXISTS
#   `VBoxManage --version` prints its "vboxdrv kernel module is not loaded"
#   warning on STDOUT, not stderr. So the usual probe
#
#       v$(VBoxManage --version 2>/dev/null)
#
#   captured the whole warning as if it were a version string, and the build
#   dashboard reported  "✓ VirtualBox  ready vWARNING: The vboxdrv kernel …"
#   — a green tick on a machine that cannot start a VM at all. The build then
#   ran for another minute, downloaded an ISO, created the VM and only failed
#   at `startvm`, with a wall of VBoxManage errors and no statement of the
#   actual cause.
#
#   This script is the honest answer to one question, asked before any of that
#   work starts: is the kernel driver usable by this user, on this machine, on
#   this kernel?
#
# THE TWO-MACHINE EDGE CASE (measured on 42 Madrid, 2026-09-03)
#   Two different filesystems, and only one of them follows you:
#
#     /sgoinfre   NFS, shared   the repo -- so the ISO and disk_images/*.vdi
#                               ARE the same files on every workstation
#     $HOME       local xfs     VirtualBox's registry (~/.config/VirtualBox),
#                               your browser profiles and their CA trust,
#                               ~/.ssh/config, ~/.cache -- all per machine
#
#   The VirtualBox kernel driver follows you least of all: it is loaded by
#   vboxdrv.service at each machine's own boot. So this repo can build
#   perfectly on one workstation and be unable to start a VM on the next, with
#   nothing in the repo having changed. That is what this script reports.
#
#   Because the VM's DISK is on the shared NFS path while the registration is
#   not, deleting the disk here really does destroy the VM another machine
#   boots -- which is why the Makefile's guard_host target exists.
#
#   Nothing here is destructive and nothing is "repaired" behind your back:
#   loading a kernel module needs root, and on a campus machine you do not
#   have it. The script's job is to say precisely that, and to name the
#   machine where the VM was last built so you know where to go back to.
#
# Exit codes
#   0  the driver is usable — the build may proceed
#   1  the driver is missing or unusable — the build must not start a VM
#   2  VBoxManage is not installed at all (a different problem: `make deps`)
#
# Env
#   VM_NAME              VM whose build-host stamp is reported (default debian)
#   VM_PATH              where the stamp lives                 (default ./disk_images)
#   SKIP_DRIVER_CHECK=1  print the diagnosis but always exit 0
# ============================================================================ #

set -uo pipefail

VM_NAME="${VM_NAME:-debian}"
# VM_PATH is the Makefile's name for it; DISK_DIR is accepted for older callers.
VM_PATH="${VM_PATH:-${DISK_DIR:-disk_images}}"

C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'
if [ ! -t 1 ] || [ -n "${NO_COLOR:-}" ]; then
	C_RESET=''; C_BOLD=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_DIM=''
fi

ok()   { printf "  ${C_GREEN}✓${C_RESET} %s\n" "$*"; }
bad()  { printf "  ${C_RED}✗${C_RESET} %s\n" "$*"; }
warn() { printf "  ${C_YELLOW}⚠${C_RESET}  %s\n" "$*"; }
note() { printf "    ${C_DIM}%s${C_RESET}\n" "$*"; }

# The version, without the warning that shares its stdout.
vbox_version() {
	VBoxManage --version 2> /dev/null \
		| grep -oE '^[0-9]+\.[0-9]+\.[0-9]+r?[0-9]*' | tail -1
}

command -v VBoxManage > /dev/null 2>&1 || {
	bad "VBoxManage is not installed on $(hostname -s)"
	note "run: make deps"
	exit 2
}

VER=$(vbox_version)

# ── The actual test: is the driver there? ───────────────────────────────────
# /dev/vboxdrv is what VBoxManage opens. A loaded module without the device
# node, or a node with no module, are both unusable — so check both.
# /sys/module/vboxdrv exists exactly when the module is loaded. Not
# `lsmod | grep -q`: under pipefail, grep -q's early exit gives lsmod SIGPIPE
# and the pipeline fails even though the driver is loaded.
DRIVER_OK=0
if [ -c /dev/vboxdrv ] && [ -d /sys/module/vboxdrv ]; then
	DRIVER_OK=1
fi

if [ "$DRIVER_OK" = "1" ]; then
	# The driver is there, but VT-x belongs to one hypervisor at a time. With
	# a KVM guest running, `VBoxManage startvm` fails with
	# VERR_VMX_IN_VMX_ROOT_MODE -- so say it here, in words, first.
	if kvm_users=$(bash "$(dirname "${BASH_SOURCE[0]}")/kvm_probe.sh" users); then
		bad "VirtualBox cannot start a VM right now: a KVM guest holds VT-x"
		printf '%s\n' "$kvm_users" | sed 's/^/     running: /'
		printf "  One hypervisor at a time. Stop it first:  ${C_BOLD}make qemu_stop${C_RESET}\n"
		printf "  or build with it instead:                ${C_BOLD}make all BACKEND=qemu${C_RESET}\n"
		exit 1
	fi
	ok "VirtualBox ${VER:-unknown} — kernel driver loaded on $(hostname -s)"
	exit 0
fi

# ── Not usable. Explain exactly why, in the order that matters. ─────────────
printf "\n${C_RED}${C_BOLD}  This machine cannot start a VM.${C_RESET}\n"
printf "  ${C_DIM}Nothing in this project is broken: this is %s's kernel driver.${C_RESET}\n\n" "$(hostname -s)"
bad "VirtualBox ${VER:-unknown} is installed, but its kernel driver is not usable"
printf "     %-22s %s\n" "machine:" "$(hostname -f 2> /dev/null || hostname)"
printf "     %-22s %s\n" "kernel:" "$(uname -r)"
[ -c /dev/vboxdrv ] \
	&& printf "     %-22s %s\n" "/dev/vboxdrv:" "present" \
	|| printf "     %-22s %s\n" "/dev/vboxdrv:" "MISSING"
printf "     %-22s %s\n" "vboxdrv module:" \
	"$([ -d /sys/module/vboxdrv ] && echo loaded || echo 'not loaded')"

# Is the module even built for the running kernel? This separates "needs a
# rebuild" from "built fine, just never loaded" — completely different fixes.
if modinfo vboxdrv > /dev/null 2>&1; then
	printf "     %-22s %s\n" "module built for it:" \
		"yes ($(modinfo -F filename vboxdrv 2> /dev/null))"
	BUILT=1
else
	printf "     %-22s %s\n" "module built for it:" "NO — needs a rebuild"
	BUILT=0
fi

# The usual culprit on a machine that has never been able to load it.
SVC=$(systemctl is-active vboxdrv 2> /dev/null || true)
SVC_SUB=$(systemctl show -p Result --value vboxdrv 2> /dev/null || true)
[ -n "$SVC" ] && printf "     %-22s %s\n" "vboxdrv.service:" "${SVC}${SVC_SUB:+ (result: $SVC_SUB)}"
if [ "$(mokutil --sb-state 2> /dev/null | head -1)" = "SecureBoot enabled" ]; then
	printf "     %-22s %s\n" "Secure Boot:" "enabled"
	SECUREBOOT=1
else
	SECUREBOOT=0
fi

# Can the person reading this actually fix it? Only if they can run sudo.
CAN_SUDO=0
if command -v sudo > /dev/null 2>&1 && [ -x /usr/bin/sudo ] && id -nG 2> /dev/null | tr ' ' '\n' | grep -qx sudo; then
	CAN_SUDO=1
fi

printf "\n${C_BOLD}  Why${C_RESET}\n"
if [ "$BUILT" = "1" ] && [ "$SECUREBOOT" = "1" ]; then
	note "The module is compiled for this kernel but was never loaded. With Secure"
	note "Boot on, an unsigned module is refused until its key is enrolled, which"
	note "is what vboxdrv.service tries to do at boot — and what it hangs on when"
	note "nobody answers the enrollment prompt."
elif [ "$BUILT" = "1" ]; then
	note "The module is compiled for this kernel but is not loaded — the boot-time"
	note "service that loads it did not succeed."
else
	note "There is no vboxdrv module for the running kernel ($(uname -r)), so it"
	note "has to be rebuilt against this kernel's headers."
fi

printf "\n${C_BOLD}  What fixes it${C_RESET}\n"
if [ "$CAN_SUDO" = "1" ]; then
	note "You are in the sudo group, so you can do it here:"
	if [ "$BUILT" = "1" ]; then
		printf "      ${C_BOLD}sudo modprobe vboxdrv vboxnetflt vboxnetadp${C_RESET}\n"
		note "or, if that is refused: sudo /sbin/vboxconfig"
	else
		printf "      ${C_BOLD}sudo /sbin/vboxconfig${C_RESET}   ${C_DIM}(rebuilds the module)${C_RESET}\n"
		note "this repo also has: make fix_hwe"
	fi
	[ "$SECUREBOOT" = "1" ] && note "Secure Boot is on, so it will ask you to enroll a key — answer the prompt."
else
	note "Loading a kernel module needs root, and this account is not in the sudo"
	note "group — so it cannot be fixed from here. Two ways forward:"
	printf "      ${C_BOLD}1.${C_RESET} Build on a machine whose VirtualBox driver works.\n"
	note "   The repo is on /sgoinfre (shared), so the ISO and the VM's disk are"
	note "   already there. \$HOME is LOCAL to each machine, so the VM"
	note "   registration and your browser trust are not -- on that machine run:"
	note "     make all      (registers the VM and installs)"
	note "     make host_access   (browser trust for https://<login>.42.fr)"
	printf "      ${C_BOLD}2.${C_RESET} Ask 42 staff to fix vboxdrv on $(hostname -s) (it has been failing\n"
	note "   since that machine booted, so every user of it is affected)."
fi

# Where did the VM last get built? That is the machine to go back to.
STAMP="${VM_PATH}/${VM_NAME}/.built-on"
if [ -r "$STAMP" ]; then
	printf "\n${C_BOLD}  This VM was last built on${C_RESET}\n"
	note "$(head -1 "$STAMP")"
fi

printf "\n${C_BOLD}  What still works on this machine${C_RESET}\n"
note "make gen_iso      build the preseeded ISO (no VM needed)"
note "make status       show where everything stands"
note "Nothing has been created or deleted by this check."
printf "\n"

# One line that survives any log truncation.
printf "  ${C_RED}BLOCKED${C_RESET}: vboxdrv unusable on %s (kernel %s) — build on another machine.\n\n" \
	"$(hostname -s)" "$(uname -r)"

if [ "${SKIP_DRIVER_CHECK:-0}" = "1" ]; then
	warn "SKIP_DRIVER_CHECK=1 — continuing anyway (the VM start will fail)"
	exit 0
fi
exit 1
