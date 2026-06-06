#!/bin/bash

# Exit on errors
set -e

# Born2beRoot Configuration Variables for 42 School
VM_NAME="Born2beRoot"
VM_OS_TYPE="Debian_64"
VM_MEMORY="2048"     # 2GB RAM as requested
VM_CPUS="1"          # Single CPU is sufficient for the project
VM_DISK_SIZE="32768" # 32GB as requested
VM_NETWORK_TYPE="nat"
VM_BASE_PATH="/sgoinfre/students/dlesieur/dlesieur42/m_virtual_machine"
ISO_PATH="$VM_BASE_PATH/debian-12.10.0-amd64-netinst.iso"
VM_DISK_PATH="$VM_BASE_PATH/$VM_NAME/$VM_NAME.vdi"
SSH_PORT="4242" # 42 project requires SSH on port 4242
HTTP__HOST_PORT="8080"
HTTP_GUEST_PORT="80"
HOSTNAME="dlesieur" # Your login as hostname (set during OS installation)

echo "Creating Born2beRoot VM for 42 School project..."

# Create VM directory if it doesn't exist
mkdir -p "$VM_BASE_PATH/$VM_NAME"

# Check if VM already exists
if VBoxManage showvminfo "$VM_NAME" &> /dev/null; then
	read -p "VM '$VM_NAME' already exists. Delete and recreate? (y/n): " confirm
	if [[ $confirm == [yY] ]]; then
		echo "Removing existing VM..."
		VBoxManage unregistervm "$VM_NAME" --delete
	else
		echo "Exiting without changes."
		exit 0
	fi
fi

# Create the VM
echo "Creating new VM: $VM_NAME"
VBoxManage createvm --name "$VM_NAME" --ostype "$VM_OS_TYPE" --register --basefolder "$VM_BASE_PATH"

# Set VM hardware configurations
echo "Configuring VM hardware..."
VBoxManage modifyvm "$VM_NAME" --memory "$VM_MEMORY" --cpus "$VM_CPUS" --vram 32
VBoxManage modifyvm "$VM_NAME" --nic1 "$VM_NETWORK_TYPE"

# Create and attach the storage
echo "Setting up storage..."
VBoxManage createhd --filename "$VM_DISK_PATH" --size "$VM_DISK_SIZE"
VBoxManage storagectl "$VM_NAME" --name "SATA Controller" --add sata --controller IntelAhci
VBoxManage storageattach "$VM_NAME" --storagectl "SATA Controller" --port 0 --device 0 --type hdd --medium "$VM_DISK_PATH"
VBoxManage storagectl "$VM_NAME" --name "IDE Controller" --add ide
VBoxManage storageattach "$VM_NAME" --storagectl "IDE Controller" --port 0 --device 0 --type dvddrive --medium "$ISO_PATH"

# Disable unused features to optimize performance
echo "Optimizing VM performance..."
VBoxManage modifyvm "$VM_NAME" --audio none --usb off --clipboard disabled --draganddrop disabled

# Configure port forwarding for SSH (delete any same-named rule first so a
# re-run never aborts under `set -e` with "A NAT rule of this name already exists")
echo "Setting up port forwarding for SSH ($SSH_PORT)..."
VBoxManage modifyvm "$VM_NAME" --natpf1 delete "guestssh" >/dev/null 2>&1 || true
VBoxManage modifyvm "$VM_NAME" --natpf1 "guestssh,tcp,,$SSH_PORT,,$SSH_PORT"
VBoxManage modifyvm "$VM_NAME" --natpf1 delete "HTTP" >/dev/null 2>&1 || true
VBoxManage modifyvm "$VM_NAME" --natpf1 "HTTP,tcp,,$HTTP_HOST_PORT,,$HTTP_GUEST_PORT"
# Set boot order to start from CD/DVD
VBoxManage modifyvm "$VM_NAME" --boot1 dvd --boot2 disk --boot3 none --boot4 none

# Start VM installation
echo "VM setup complete! Starting VM for installation..."
VBoxManage startvm "$VM_NAME" --type gui

# Print installation instructions
cat << EOF

====== BORN2BEROOT INSTALLATION GUIDE ======

Your VM '$VM_NAME' is now created and running with:
- 2GB RAM
- 32GB Hard Disk
- NAT Network with SSH port forwarding ($SSH_PORT)
- VM stored in: $VM_BASE_PATH/$VM_NAME

INSTALLATION INSTRUCTIONS:
1. During installation, set:
   - Keyboard layout: Spanish
   - System language: English
   - Hostname: $HOSTNAME (important!)
   - No domain name

2. For partition setup (Born2beRoot requirements):
   - Select "Manual" partitioning
   - Create an encrypted volume
   - Set up LVM with the following partitions:
     
     Bonus part (mandatory for evaluation):
     * Create primary partition (~500MB) for /boot
     * Create encrypted partition for the remaining space
     * Set up LVM inside the encrypted partition with:
       - root (/) partition: at least 10GB
       - swap partition: at least 2.3GB
       - home (/home) partition: at least 5GB 
       - var (/var) partition: at least 3GB
       - srv (/srv) partition: at least 3GB
       - tmp (/tmp) partition: at least 3GB
       - var-log (/var/log) partition: remaining space

EOF
