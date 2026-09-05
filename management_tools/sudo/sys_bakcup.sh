#!/bin/bash

# Create backup destination
BACKUP_DIR="/media/dlesieur/UBUNTU_INST/ubuntu_backup_$(date +%Y%m%d)"
mkdir -p "$BACKUP_DIR"

echo "===== Creating complete system backup ====="
echo "System size: 34GB"
echo "Available space: 112GB"
echo "Backup location: $BACKUP_DIR"

# Option 1: Compressed disk image (recommended - saves space but preserves everything)
echo "Creating compressed disk image backup (this will take 30-60 minutes)..."
sudo dd if=/dev/nvme1n1 bs=4M status=progress | gzip -c >"$BACKUP_DIR/complete_system.img.gz"

# Create backup info file
echo "Creating backup information file..."
{
    echo "Backup created on: $(date)"
    echo "Source device: /dev/nvme1n1 ($(lsblk -dno MODEL /dev/nvme1n1))"
    echo "Original size: $(lsblk -dno SIZE /dev/nvme1n1)"
    echo "Actual data: 34GB"
    echo ""
    echo "To restore this backup:"
    echo "gunzip -c $BACKUP_DIR/complete_system.img.gz | sudo dd of=/dev/nvme1n1 bs=4M status=progress"
} >"$BACKUP_DIR/backup_info.txt"

# Also backup your package list and repositories
echo "Backing up package list and repositories..."
dpkg --get-selections >"$BACKUP_DIR/installed_packages.txt"
sudo cp -r /etc/apt/sources.list* "$BACKUP_DIR/apt_sources/"

echo "Backup complete!"
echo "Your system is backed up to: $BACKUP_DIR/complete_system.img.gz"
