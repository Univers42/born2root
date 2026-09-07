#!/usr/bin/env hellish
# Full System Backup Script
# Current Date and Time (UTC): 2025-04-04 16:52:53
# Current User: LESdylan

# Install required tools
sudo apt update
sudo apt install -y clonezilla pv gddrescue

# Create backup directory on external drive
# Replace /media/external with your external drive mount point
BACKUP_DIR="/media/external/ubuntu_backup_$(date +%Y%m%d)"
sudo mkdir -p "$BACKUP_DIR"

echo "=== Creating full system backup ==="
echo "This will create a complete image of your system disk"
echo "Please connect an external drive with at least 150GB free space"
read -r -p "Press Enter when ready..."

# Option 1: Using dd (raw disk image)
echo "Creating disk image using dd (this may take 1-2 hours)..."
sudo dd if=/dev/nvme1n1 of="$BACKUP_DIR/ubuntu_full_disk.img" bs=4M status=progress conv=sync,noerror

# Alternative Option: Using Clonezilla GUI
echo "Alternatively, you can use Clonezilla for a GUI-based backup:"
echo "sudo clonezilla"

echo "Backup complete! Your system image is saved at: $BACKUP_DIR/ubuntu_full_disk.img"
echo "To restore: sudo dd if=$BACKUP_DIR/ubuntu_full_disk.img of=/dev/nvme1n1 bs=4M status=progress"
