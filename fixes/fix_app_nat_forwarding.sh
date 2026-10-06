#!/usr/bin/env hellish
# Re-apply born2root.toml's [network] forwards to an existing VirtualBox VM,
# each rule at its configured host port, so an edited list reaches the VM
# without a rebuild (the guest's firewall still needs `make re` to follow).
# Run this on the host, not inside the VM.
#
# Rules bind 127.0.0.1 like install_vm_debian.sh's NATPF_BIND: this script
# used to leave the host IP empty, which VirtualBox reads as 0.0.0.0, so every
# repaired port was reachable from the whole LAN.

set -euo pipefail

VM_NAME="${1:-${VM_NAME:-debian}}"
NATPF_BIND="${NATPF_BIND:-127.0.0.1}"
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)/utils/b2b_config.sh"

if ! command -v VBoxManage >/dev/null 2>&1; then
    echo "VBoxManage is not installed or not in PATH. Run this from the VirtualBox host."
    exit 1
fi

if ! VBoxManage showvminfo "$VM_NAME" >/dev/null 2>&1; then
    echo "VM '$VM_NAME' does not exist. Run make setup_vm first."
    exit 1
fi

vm_state=$(VBoxManage showvminfo "$VM_NAME" --machinereadable 2>/dev/null |
    awk -F'"' '$1 == "VMState=" { print $2; exit }')

apply_rule() {
    local name="$1"
    local host_port="$2"
    local guest_port="$3"

    if [ "$vm_state" = "running" ]; then
        VBoxManage controlvm "$VM_NAME" natpf1 delete "$name" >/dev/null 2>&1 || true
        VBoxManage controlvm "$VM_NAME" natpf1 "$name,tcp,${NATPF_BIND},${host_port},,${guest_port}"
    else
        VBoxManage modifyvm "$VM_NAME" --natpf1 delete "$name" >/dev/null 2>&1 || true
        VBoxManage modifyvm "$VM_NAME" --natpf1 "$name,tcp,${NATPF_BIND},${host_port},,${guest_port}"
    fi

    printf '  %-18s host:%-5s -> guest:%s\n' "$name" "$host_port" "$guest_port"
}

echo "Repairing NAT forwarding for VM '$VM_NAME' (${vm_state:-unknown})"
for fwd in $(b2b_get B2B_FORWARDS); do
    rest=${fwd#*:}
    apply_rule "${fwd%%:*}" "${rest%%:*}" "${rest#*:}"
done
echo ""
echo "Current rules:"
VBoxManage showvminfo "$VM_NAME" --machinereadable |
    awk -F'"' '/^Forwarding/ { print "  " $2 }' |
    sort
