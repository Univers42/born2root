#!/usr/bin/env hellish

# Install required packages
sudo apt update
sudo apt install -y virtualbox virtualbox-ext-pack

# Create VM directory
VM_DIR="$HOME/VirtualBox VMs/Affinity-Windows11"
mkdir -p "$VM_DIR"

# Create Windows 11 VM
VBoxManage createvm --name "Affinity-Windows11" --ostype Windows11_64 --register

# Configure system
VBoxManage modifyvm "Affinity-Windows11" --memory 16384 --cpus 10 --vram 256
VBoxManage modifyvm "Affinity-Windows11" --graphicscontroller vmsvga --accelerate3d on
VBoxManage modifyvm "Affinity-Windows11" --boot1 dvd --boot2 disk --boot3 none --boot4 none
VBoxManage modifyvm "Affinity-Windows11" --firmware efi

# Enable TPM for Windows 11
VBoxManage modifyvm "Affinity-Windows11" --tpm-type 2.0

# Enable nested virtualization and PAE
VBoxManage modifyvm "Affinity-Windows11" --nested-hw-virt on --pae on
VBoxManage modifyvm "Affinity-Windows11" --cpu-profile host

# Enable large memory pages for performance
VBoxManage modifyvm "Affinity-Windows11" --largepages on

# Create and attach virtual disk (120GB)
VBoxManage createmedium disk --filename "$VM_DIR/Affinity-Windows11.vdi" --size 122880 --variant Fixed

# Create SATA controller and attach disk
VBoxManage storagectl "Affinity-Windows11" --name "SATA Controller" --add sata --controller IntelAHCI
VBoxManage storageattach "Affinity-Windows11" --storagectl "SATA Controller" --port 0 --device 0 --type hdd --medium "$VM_DIR/Affinity-Windows11.vdi"

# Create IDE controller for Windows 11 installation media
VBoxManage storagectl "Affinity-Windows11" --name "IDE Controller" --add ide
VBoxManage storageattach "Affinity-Windows11" --storagectl "IDE Controller" --port 0 --device 0 --type dvddrive --medium emptydrive

# Enable clipboard and file sharing
VBoxManage modifyvm "Affinity-Windows11" --clipboard bidirectional --draganddrop bidirectional

# Enable USB 3.0 controller for peripherals
VBoxManage modifyvm "Affinity-Windows11" --usbxhci on

# Set VM description
VBoxManage modifyvm "Affinity-Windows11" --description "Windows 11 VM optimized for Affinity Designer with 16GB RAM, 10 CPU cores, and 120GB storage."

echo "====================================================="
echo "Windows 11 VM Created Successfully!"
echo "Next steps:"
echo "1. Download Windows 11 ISO from Microsoft's website"
echo "2. Attach the ISO to the VM's IDE controller:"
echo "   VBoxManage storageattach \"Affinity-Windows11\" --storagectl \"IDE Controller\" --port 0 --device 0 --type dvddrive --medium /path/to/windows11.iso"
echo "3. Start the VM and install Windows 11"
echo "4. Once Windows is installed, install VirtualBox Guest Additions"
echo "5. Install Affinity Designer and activate with your license"
echo "====================================================="
