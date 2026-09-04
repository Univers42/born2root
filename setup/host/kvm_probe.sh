#!/usr/bin/env bash
# ============================================================================ #
#  kvm_probe.sh — can THIS user create a KVM virtual machine RIGHT NOW?        #
# ============================================================================ #
#
# Being allowed to open /dev/kvm is not the same as being able to use it.
# KVM_CREATE_VM is the first thing QEMU does, and it is the first thing that
# can fail for a reason no permission check will ever see:
#
#   VT-x (Intel) / AMD-V is owned by ONE hypervisor at a time. While a
#   VirtualBox VM is running, vboxdrv has executed VMXON on every CPU. The
#   kernel's kvm_intel then refuses to enable itself -- hardware_enable()
#   sees CR4.VMXE already set and returns -EBUSY -- and QEMU prints:
#
#       ioctl(KVM_CREATE_VM) failed: 16 Device or resource busy
#
#   The reverse is also true: a VirtualBox VM cannot start while a KVM guest
#   runs (VERR_VMX_IN_VMX_ROOT_MODE). Nothing is broken; they cannot overlap.
#
# So this script does what QEMU would do -- open /dev/kvm, ask for a VM, and
# close it again -- and reports the real answer. A VM handle that is closed
# immediately leaves no trace: KVM disables VT-x again when its last user goes.
#
# stdout: one human-readable line.   exit: 0 ready · 2 no access · 3 blocked
#
# Usage:  setup/host/kvm_probe.sh            (prints why, exits accordingly)
#         if why=$(kvm_probe.sh); then ... fi
# ============================================================================ #

set -uo pipefail

# `kvm_probe.sh users` -- who has /dev/kvm open right now? One line per
# process, exit 0 if any. A running KVM guest is what makes VirtualBox fail
# with VERR_VMX_IN_VMX_ROOT_MODE: the mirror image of the EBUSY below. Only
# this user's processes are visible in /proc; another user's guest would
# block VirtualBox just the same but could only be seen through that error.
if [ "${1:-}" = users ]; then
	found=""
	for fd in /proc/[0-9]*/fd/*; do
		[ "$(readlink "$fd" 2> /dev/null)" = /dev/kvm ] || continue
		pid=${fd#/proc/}; pid=${pid%%/*}
		case " $found " in *" $pid "*) continue ;; esac
		found="$found $pid"
		tr '\0' ' ' < "/proc/$pid/cmdline" 2> /dev/null \
			| awk -v pid="$pid" '{ for (i = 1; i <= NF; i++) if ($i == "-name") n = $(i + 1);
				sub(".*/", "", $1); printf "%s%s (pid %s)\n", $1, (n ? " " n : ""), pid }'
	done
	[ -n "$found" ]
	exit $?
fi

if [ ! -c /dev/kvm ]; then
	echo "/dev/kvm does not exist (kvm_intel/kvm_amd not loaded, or no VT-x/AMD-V)"
	exit 2
fi
if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
	echo "/dev/kvm is not readable/writable by you"
	exit 2
fi
if ! command -v python3 > /dev/null 2>&1; then
	echo "python3 is missing, so KVM cannot be probed (make deps)"
	exit 4
fi

# Output is "<stage> <errno>" on failure, nothing on success.
result=$(python3 - <<'PYEOF'
import os, fcntl, sys
KVM_CREATE_VM = 0xAE01          # _IO(KVMIO=0xAE, 0x01), <linux/kvm.h>
try:
    fd = os.open("/dev/kvm", os.O_RDWR | os.O_CLOEXEC)
except OSError as e:
    print("open", e.errno); sys.exit(2)
try:
    vm = fcntl.ioctl(fd, KVM_CREATE_VM, 0)
except OSError as e:
    print("create", e.errno); sys.exit(3)
os.close(vm)
os.close(fd)
PYEOF
)
rc=$?

if [ "$rc" = 0 ]; then
	echo "ready (KVM accelerated)"
	exit 0
fi

stage=${result%% *}
err=${result##* }

if [ "$stage" = create ] && [ "$err" = 16 ]; then
	# EBUSY: VT-x is taken. Name the VirtualBox VM if that is who has it.
	vms=""
	if command -v VBoxManage > /dev/null 2>&1; then
		vms=$(VBoxManage list runningvms 2> /dev/null | sed 's/ {.*//' | paste -sd, -)
	fi
	if [ -n "$vms" ]; then
		echo "blocked: VirtualBox VM ${vms} is running and holds VT-x; one hypervisor at a time"
	else
		echo "blocked: another hypervisor holds VT-x (KVM_CREATE_VM: EBUSY)"
	fi
	exit 3
fi

echo "KVM_CREATE_VM failed (${stage}: errno ${err})"
exit 3
