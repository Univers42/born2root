#!/bin/bash

VM_NAME="${VM_NAME:-debian}"
VM_PASS_FILE="${VM_PASS_FILE:-vm_pass.txt}"

get_vm_ssh_port() {
	VBoxManage showvminfo "$VM_NAME" --machinereadable 2> /dev/null \
		| grep "^Forwarding" \
		| grep '"ssh,tcp,' \
		| head -1 \
		| cut -d, -f4
}

SSH_HOST_PORT=$(get_vm_ssh_port)
: "${SSH_HOST_PORT:=4242}"

echo "[$(date)] Starting VM in headless mode..."
VBoxManage startvm "$VM_NAME" --type headless
sleep 1

echo "[$(date)] Providing encryption password from $VM_PASS_FILE..."
VBoxManage controlvm "$VM_NAME" addencpassword "tempencrypt123" "$VM_PASS_FILE"
PASS_RESULT=$?

if [ $PASS_RESULT -eq 0 ]; then
	echo "[$(date)] ✓ Password provided successfully!"
else
	echo "[$(date)] ✗ ERROR: Failed to provide password (exit code: $PASS_RESULT)"
	exit 1
fi

echo "[$(date)] Waiting for VM to fully boot (30 seconds)..."
sleep 30

echo "[$(date)] Checking VM state..."
VBoxManage showvminfo "$VM_NAME" | grep "State:"

echo "[$(date)] Testing SSH connectivity..."
ssh -p "$SSH_HOST_PORT" dlesieur@127.0.0.1 "echo SSH working" || echo "SSH not yet available"

echo "[$(date)] VM boot sequence complete"
