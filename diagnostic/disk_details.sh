#!/usr/bin/env hellish
# Disk Identification Script
# Current Date and Time (UTC): 2025-04-04 16:45:42
# Current User: LESdylan

# Show all physical disks with their sizes and model names
echo "===== PHYSICAL DISKS ====="
lsblk -d -o NAME,SIZE,MODEL,SERIAL

# Show detailed partition information
echo -e "\n===== PARTITION LAYOUT ====="
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS,LABEL,MODEL

# Show LVM setup
echo -e "\n===== LVM VOLUMES ====="
sudo vgs
sudo lvs

# Show full disk usage information
echo -e "\n===== DISK USAGE ====="
df -h

# Show detailed partition table
echo -e "\n===== PARTITION TABLES ====="
sudo fdisk -l | grep -A20 "Disk /dev/"
