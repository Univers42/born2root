#!/usr/bin/env bash
# ============================================================================ #
#  vm_ports.sh — "which host port reaches guest service X?", either backend    #
# ============================================================================ #
#
# Both hypervisors forward host ports into the guest, but they record it in
# completely different places:
#
#   VirtualBox   a named NAT rule in the VM's configuration, readable with
#                `VBoxManage showvminfo --machinereadable` as
#                Forwarding(8)="https,tcp,,8443,,443"
#   QEMU         a -netdev hostfwd= argument on the command line, which is not
#                stored anywhere queryable once the process is running
#
# So qemu_vm.sh writes the same information to <vm-dir>/ports.env when it
# launches, and this resolver reads whichever source exists. Callers ask by
# RULE NAME ("https", "inception-static", ...) and never care which backend is
# underneath -- which is the point, because verify_inception_access.sh was
# reporting "no 'https' NAT rule" on a QEMU VM whose port 8443 was working
# perfectly two checks later.
#
# Source it, then call:  vm_forward_port https   ->  8443   (empty if unknown)
# ============================================================================ #

# shellcheck disable=SC2034
VM_PORTS_SH_LOADED=1

# Resolved ONCE, here, while BASH_SOURCE still points at this file. Computing
# it inside the function instead gave the wrong answer, because BASH_SOURCE is
# re-evaluated in the caller's context and walked up from the wrong directory.
_VM_PORTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2> /dev/null && pwd)"

_vm_ports_file() {
	local vm="${VM_NAME:-debian}"
	local base="${VM_PATH:-${_VM_PORTS_REPO_ROOT}/disk_images}"
	printf '%s' "${base}/${vm}/ports.env"
}

# The VirtualBox NAT rule, if this is a registered VirtualBox VM.
_vm_forward_port_vbox() {
	command -v VBoxManage > /dev/null 2>&1 || return 1
	VBoxManage showvminfo "${VM_NAME:-debian}" --machinereadable 2> /dev/null \
		| awk -F'"' -v rule="$1" '$1 ~ /^Forwarding/ && $2 ~ "^" rule "," { print $2; exit }' \
		| cut -d',' -f4
}

# The QEMU hostfwd map, recorded at launch.
_vm_forward_port_qemu() {
	local f; f=$(_vm_ports_file)
	[ -r "$f" ] || return 1
	awk -F= -v rule="$1" '$1 == rule { print $2; exit }' "$f"
}

# VirtualBox first (it is authoritative when the VM is registered there), then
# QEMU. Prints nothing when neither knows the rule, which callers treat as
# "not forwarded".
vm_forward_port() {
	local p
	p=$(_vm_forward_port_vbox "$1" 2> /dev/null)
	[ -n "$p" ] && { printf '%s' "$p"; return 0; }
	p=$(_vm_forward_port_qemu "$1" 2> /dev/null)
	[ -n "$p" ] && { printf '%s' "$p"; return 0; }
	return 1
}

# Which backend is actually providing the forwards right now.
vm_backend() {
	if command -v VBoxManage > /dev/null 2>&1 \
		&& VBoxManage showvminfo "${VM_NAME:-debian}" > /dev/null 2>&1; then
		printf 'virtualbox'; return 0
	fi
	[ -r "$(_vm_ports_file)" ] && { printf 'qemu'; return 0; }
	printf 'none'; return 1
}
