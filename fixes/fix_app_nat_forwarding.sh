#!/bin/bash
# Repair VirtualBox NAT forwarding for the osionos / ft_transcendence app stack.
# Run this on the host, not inside the VM.

set -euo pipefail

VM_NAME="${1:-${VM_NAME:-debian}}"

if ! command -v VBoxManage > /dev/null 2>&1; then
	echo "VBoxManage is not installed or not in PATH. Run this from the VirtualBox host."
	exit 1
fi

if ! VBoxManage showvminfo "$VM_NAME" > /dev/null 2>&1; then
	echo "VM '$VM_NAME' does not exist. Run make setup_vm first."
	exit 1
fi

vm_state=$(VBoxManage showvminfo "$VM_NAME" --machinereadable 2> /dev/null \
	| awk -F'"' '$1 == "VMState=" { print $2; exit }')

apply_rule() {
	local name="$1"
	local host_port="$2"
	local guest_port="$3"

	if [ "$vm_state" = "running" ]; then
		VBoxManage controlvm "$VM_NAME" natpf1 delete "$name" > /dev/null 2>&1 || true
		VBoxManage controlvm "$VM_NAME" natpf1 "$name,tcp,,${host_port},,${guest_port}"
	else
		VBoxManage modifyvm "$VM_NAME" --natpf1 delete "$name" > /dev/null 2>&1 || true
		VBoxManage modifyvm "$VM_NAME" --natpf1 "$name,tcp,,${host_port},,${guest_port}"
	fi

	printf '  %-18s host:%-5s -> guest:%s\n' "$name" "$host_port" "$guest_port"
}

echo "Repairing NAT forwarding for VM '$VM_NAME' (${vm_state:-unknown})"
apply_rule website 4322 4322
apply_rule osionos-app 3001 3001
apply_rule osionos-mail 3002 3002
apply_rule osionos-calendar 3003 3003
apply_rule osionos-bridge 4000 4000
apply_rule mail-bridge 4100 4100
apply_rule calendar-bridge 4200 4200
apply_rule baas-gateway 8000 8000
apply_rule baas-admin 8001 8001
apply_rule mailpit 8025 8025
apply_rule auth-gateway 8787 8787
apply_rule vault 18200 18200

echo ""
echo "Current rules:"
VBoxManage showvminfo "$VM_NAME" --machinereadable \
	| awk -F'"' '/^Forwarding/ { print "  " $2 }' \
	| sort

echo ""
echo "Open from the host: https://localhost:4322"
