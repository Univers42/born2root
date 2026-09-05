#!/bin/bash
# Is VirtualBox's kernel driver actually USABLE by the CALLING user, right now?
#
# Existence of /dev/vboxdrv and the module being loaded is not enough: the
# device can be there with the wrong owner. The packaged udev rule sets
# root:vboxusers 0660; a module inserted without udev catching up leaves the
# kernel default, root:root 0600, which no non-root user can open at all --
# module loaded, device present, and every VM start still fails with a
# permission error a minute into the build. Confirmed live: `[ -c /dev/vboxdrv ]
# && lsmod | grep vboxdrv` reported "ready" on a machine where the device was
# crw------- root root, so nobody but root could actually start a VM.
#
# Sourced by setup/host/select_backend.sh (choosing a hypervisor) and
# setup/host/check_vbox_driver.sh (explaining a chosen one that turned out
# unusable) so the two can never disagree about what "usable" means.

# Overridable so tests/test_vbox_driver.sh can point this at a fixture instead
# of the real kernel state; production callers never set it.
VBOXDRV_PROC_MODULES="${VBOXDRV_PROC_MODULES:-/proc/modules}"

vboxdrv_device_exists() { [ -c /dev/vboxdrv ]; }

# Read /proc/modules directly rather than piping `lsmod` through `grep -q`:
# under `set -o pipefail`, grep -q closes its end of the pipe the instant it
# matches, and if lsmod is still writing the rest of its ~150-line listing at
# that moment it dies of SIGPIPE (exit 141) -- which pipefail then reports as
# the PIPELINE's exit status even though grep found exactly what it was
# looking for. Reproduced deterministically on this machine: 100% of runs of
# `lsmod | grep -q '^vboxdrv'` returned 141 while the module was genuinely
# loaded, so this check reported "not loaded" on a machine where it wasn't.
vboxdrv_loaded() { grep -q '^vboxdrv ' "$VBOXDRV_PROC_MODULES" 2> /dev/null; }

# Where the VM binaries live. /usr/lib/virtualbox for both Debian's package and
# Oracle's own Linux installer. Overridable for the same reason as above.
VBOX_LIB_DIR="${VBOX_LIB_DIR:-/usr/lib/virtualbox}"

# HARDENED vs DEVELOPER build -- the distinction that decides whether the
# calling user needs access to /dev/vboxdrv at all.
#
# /usr/lib/virtualbox/vboxdrv.sh picks one at install time:
#
#   VirtualBoxVM is set-uid root  ->  hardened: GROUP=root,       MODE=0600
#   VirtualBoxVM is not           ->  developer: GROUP=vboxusers, MODE=0660
#
# In a hardened install root:root 0600 is CORRECT, not broken: VirtualBoxVM and
# VBoxHeadless are set-uid root and open the driver as root, so an ordinary user
# never opens it and never needs to be in vboxusers. Measured here: a hardened
# 7.1.18 with crw------- root root /dev/vboxdrv starts VMs perfectly, while
# `VBoxManage --version` prints a clean version with no driver warning at all.
#
# Requiring user r/w unconditionally therefore reports a working VirtualBox as
# unusable, silently drops the build to the other hypervisor without asking, and
# advises joining a group that changes nothing. That was a real regression here.
vboxdrv_hardened() {
	[ -u "$VBOX_LIB_DIR/VirtualBoxVM" ] || [ -u "$VBOX_LIB_DIR/VBoxHeadless" ]
}

vboxdrv_accessible() {
	vboxdrv_hardened && return 0
	[ -r /dev/vboxdrv ] && [ -w /dev/vboxdrv ]
}

vboxdrv_ok() {
	vboxdrv_device_exists || return 1
	vboxdrv_loaded || return 1
	vboxdrv_accessible
}

# Why vboxdrv_ok failed (or "ready"), one line, in the order that matters to
# whoever is reading it. Assumes VBoxManage is already known to be installed.
vboxdrv_why() {
	if ! vboxdrv_device_exists; then
		printf '%s' "installed, but /dev/vboxdrv does not exist -- vboxdrv kernel module not loaded (needs root)"
	elif ! vboxdrv_loaded; then
		printf '%s' "installed, but the vboxdrv kernel module is not loaded (needs root)"
	elif ! vboxdrv_accessible; then
		# Only reachable on a DEVELOPER build -- a hardened one is accessible
		# by definition -- so vboxusers really is the fix here.
		printf '%s' "kernel driver ready, but /dev/vboxdrv is not readable/writable by $(id -un) -- join the vboxusers group"
	else
		printf '%s' "ready"
	fi
}
