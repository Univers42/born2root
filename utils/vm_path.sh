#!/bin/bash
# Is the VM storage directory usable by the calling user -- and if not, WHY,
# and what exactly fixes it?
#
# Everything both backends write lives under $VM_PATH/$VM_NAME: the disk image,
# the pidfile, the monitor socket, serial.log, the stamps. When VM_PATH points
# at an external disk (VM_PATH=/mnt/storage/qemu) its parent is usually owned
# by root, and `make all` used to spend minutes building the ISO and then die
# on a bare "mkdir: cannot create directory: Permission denied" from deep
# inside the disk step -- no word about who owns what, or what to do. The way
# out people found was `sudo make all`, which works once and then leaves a
# root-owned disk, pidfile and monitor socket behind that no later
# `make qemu_stop` without sudo can read.
#
# This checks up front and, when the directory is not usable, names the
# directory that is in the way and who owns it. Then -- only when it IS a
# permission problem, only when sudo exists, only when a terminal is attached --
# it offers to run the exact commands it has just printed. Non-interactive
# callers and machines without sudo get those commands to run themselves.
# sudo is never used by default: on many machines the user does not have it.
#
# Sourced by setup/host/qemu_vm.sh and setup/install/vms/install_vm_debian.sh
# (the two places a VM directory is created), and run as a command by the
# Makefile before either pipeline starts, so the answer arrives before the ISO
# build rather than after it:
#
#   . utils/vm_path.sh; ensure_vm_dir "$VM_PATH" "$VM_NAME"
#   bash utils/vm_path.sh "$VM_PATH" "$VM_NAME"

# Overridable so tests/test_vm_path.sh can stand in a fake sudo; production
# callers never set it.
VM_PATH_SUDO="${VM_PATH_SUDO:-sudo}"

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
	_VP_RED=$'\033[31m' _VP_GRN=$'\033[32m' _VP_OFF=$'\033[0m'
else
	_VP_RED='' _VP_GRN='' _VP_OFF=''
fi

# Can we ask the user anything? /dev/tty always exists as a file, but OPENING
# it fails without a controlling terminal (cron, CI, a detached make) -- and
# that is the case this guards. Overridden by the tests.
vm_path_can_ask() { { : < /dev/tty; } 2> /dev/null; }

# Yes/no on the terminal; 0 = yes. Enter means yes: the user has just read
# the exact commands and is sitting there. Overridden by the tests.
vm_path_ask() {
	local ans
	printf '    %s [Y/n]: ' "$1" > /dev/tty
	IFS= read -r ans < /dev/tty || ans=""
	case "$ans" in '' | [Yy]*) return 0 ;; *) return 1 ;; esac
}

_vm_path_writable() { [ -d "$1" ] && [ -w "$1" ] && [ -x "$1" ]; }

# The nearest ancestor of $1 that exists: the directory whose permissions
# actually decide whether $1 can be created.
_vm_path_blocker() {
	local p=$1
	while [ ! -e "$p" ] && [ "$p" != / ]; do p=$(dirname "$p"); done
	printf '%s' "$p"
}

# The commands that make $2 usable, one per line, without any sudo prefix.
# ONE source of truth: what is shown to the user is what gets run.
#
# You own what this creates: the VM directory (recursively -- everything in it
# is this VM's), and VM_PATH itself only if it does not exist yet. A VM_PATH
# that already exists and belongs to someone else (/mnt/storage) is left as it
# is; a second VM_NAME under it simply asks again.
_vm_path_recipe() {
	local vm_path=$1 vm_dir=$2 who
	who="$(id -un):$(id -gn)"
	printf 'mkdir -p "%s"\n' "$vm_dir"
	[ -d "$vm_path" ] || printf 'chown "%s" "%s"\n' "$who" "$vm_path"
	printf 'chown -R "%s" "%s"\n' "$who" "$vm_dir"
}

_vm_path_alternative() {
	printf '    Or build somewhere you already own:   VM_PATH=%s make all\n' "$HOME/vms"
}

# ensure_vm_dir VM_PATH VM_NAME
# 0 when $VM_PATH/$VM_NAME exists and the calling user can write in it,
# creating it when the filesystem allows. Otherwise the situation is explained
# on stderr and the return is 1: "not usable, and here is what to do".
ensure_vm_dir() {
	local vm_path=$1 vm_dir=$1/$2 blocker me line lines

	if _vm_path_writable "$vm_dir"; then
		return 0
	elif [ ! -e "$vm_dir" ] && mkdir -p "$vm_dir" 2> /dev/null; then
		return 0
	fi

	me=$(id -un)
	{
		printf '  %s✗%s VM storage %s is not usable by %s\n' "$_VP_RED" "$_VP_OFF" "$vm_dir" "$me"
		if [ -d "$vm_dir" ]; then
			printf '    it exists but belongs to %s (%s)\n' \
				"$(stat -c %U:%G "$vm_dir")" "$(stat -c %A "$vm_dir")"
			printf '    (built with "sudo make all"? then its disk, pidfile and monitor socket are root-owned too)\n'
		else
			blocker=$(_vm_path_blocker "$vm_dir")
			printf '    it cannot be created: %s belongs to %s (%s)\n' \
				"$blocker" "$(stat -c %U:%G "$blocker")" "$(stat -c %A "$blocker")"
		fi
		printf '    This is a permission problem, not a build failure: fixing it needs root.\n'
	} >&2

	if ! command -v "$VM_PATH_SUDO" > /dev/null 2>&1; then
		{
			printf '    sudo is not available here. Ask an administrator to run, as root:\n'
			_vm_path_recipe "$vm_path" "$vm_dir" | sed 's/^/        /'
			_vm_path_alternative
		} >&2
		return 1
	fi

	if ! vm_path_can_ask; then
		{
			printf '    No terminal to ask on. Run these once, then retry:\n'
			_vm_path_recipe "$vm_path" "$vm_dir" | sed 's/^/        sudo /'
			_vm_path_alternative
		} >&2
		return 1
	fi

	{
		printf '    With your permission this will run:\n'
		_vm_path_recipe "$vm_path" "$vm_dir" | sed 's/^/        sudo /'
	} >&2
	if ! vm_path_ask "Run these with sudo now?"; then
		{
			printf '    Nothing changed. Run them yourself when you want to, or:\n'
			_vm_path_alternative
		} >&2
		return 1
	fi

	mapfile -t lines < <(_vm_path_recipe "$vm_path" "$vm_dir")
	for line in "${lines[@]}"; do
		"$VM_PATH_SUDO" sh -c "$line" || {
			printf '  %s✗%s failed: sudo %s\n' "$_VP_RED" "$_VP_OFF" "$line" >&2
			return 1
		}
	done
	if ! _vm_path_writable "$vm_dir"; then
		printf '  %s✗%s %s is still not writable by %s\n' "$_VP_RED" "$_VP_OFF" "$vm_dir" "$me" >&2
		return 1
	fi
	printf '  %s✓%s %s now belongs to %s\n' "$_VP_GRN" "$_VP_OFF" "$vm_dir" "$me" >&2
}

# Run as a command (the Makefile does, before either pipeline starts).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	[ $# -eq 2 ] || {
		printf 'usage: %s VM_PATH VM_NAME\n' "$0" >&2
		exit 2
	}
	ensure_vm_dir "$1" "$2"
fi
