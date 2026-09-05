#!/bin/bash

# Colors for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Backup directory - stores LVM configuration backups
BACKUP_DIR="$HOME/.lvm_backups"
mkdir -p "$BACKUP_DIR"

# Function to create a complete backup of LVM configuration
backup_lvm_config() {
    local backup_id=$(date +%Y%m%d_%H%M%S)
    local backup_path="$BACKUP_DIR/lvm_backup_$backup_id"
    mkdir -p "$backup_path"

    echo -e "${YELLOW}Creating comprehensive LVM configuration backup...${NC}"

    # Backup Volume Groups configuration
    echo -e "${CYAN}Backing up VG configuration...${NC}"
    sudo vgcfgbackup -f "$backup_path/vg_%s.conf"

    # Backup current state using various commands
    echo -e "${CYAN}Saving current LVM state details...${NC}"
    sudo pvs -v >"$backup_path/pvs.txt"
    sudo vgs -v >"$backup_path/vgs.txt"
    sudo lvs -v >"$backup_path/lvs.txt"
    sudo pvdisplay >"$backup_path/pvdisplay.txt"
    sudo vgdisplay >"$backup_path/vgdisplay.txt"
    sudo lvdisplay >"$backup_path/lvdisplay.txt"

    # Backup critical system files
    echo -e "${CYAN}Backing up system configuration files...${NC}"
    sudo cp /etc/fstab "$backup_path/fstab.backup"
    sudo cp /etc/lvm/lvm.conf "$backup_path/lvm.conf.backup"
    if [ -f /etc/crypttab ]; then
        sudo cp /etc/crypttab "$backup_path/crypttab.backup"
    fi

    # Create a restore script specifically for this backup
    echo -e "${CYAN}Creating restoration script...${NC}"
    cat >"$backup_path/restore.sh" <<EOF
#!/bin/bash
# LVM Configuration Restore Script - Created on $(date)
# This will restore the LVM configuration to how it was when this backup was made

echo "Restoring LVM configuration from backup on $(date)..."

# First, restore Volume Groups configurations
echo "Restoring Volume Groups configurations..."
EOF

    # Generate VG restore commands for each VG
    for vg_conf in "$backup_path"/vg_*.conf; do
        vg_name=$(basename "$vg_conf" | sed 's/vg_\(.*\)\.conf/\1/')
        echo "sudo vgcfgrestore -f \"$vg_conf\" $vg_name" >>"$backup_path/restore.sh"
    done

    # Add fstab restore
    cat >>"$backup_path/restore.sh" <<EOF

# Restore system configuration files
echo "Restoring system configuration files..."
sudo cp "$backup_path/fstab.backup" /etc/fstab
sudo cp "$backup_path/lvm.conf.backup" /etc/lvm/lvm.conf
EOF

    # Add crypttab restore if it exists
    if [ -f /etc/crypttab ]; then
        echo "sudo cp \"$backup_path/crypttab.backup\" /etc/crypttab" >>"$backup_path/restore.sh"
    fi

    # Add final steps
    cat >>"$backup_path/restore.sh" <<EOF

# Update initramfs and grub
echo "Updating initramfs and bootloader..."
sudo update-initramfs -u -k all
sudo update-grub

echo "LVM configuration restored successfully!"
EOF

    chmod +x "$backup_path/restore.sh"

    echo -e "${GREEN}Backup successfully created at: $backup_path${NC}"
    echo -e "${GREEN}Created restore script: $backup_path/restore.sh${NC}"

    # Return the backup ID for future reference
    echo "$backup_id"
}

# Function to restore LVM configuration from a backup
restore_lvm_config() {
    echo -e "${BLUE}=== LVM Configuration Restore Tool ===${NC}"

    # List available backups
    local backups=($(ls -1 "$BACKUP_DIR" | grep lvm_backup_))

    if [ ${#backups[@]} -eq 0 ]; then
        echo -e "${RED}No backups found in $BACKUP_DIR${NC}"
        return 1
    fi

    echo -e "${YELLOW}Available backups:${NC}"
    local i=1
    for backup in "${backups[@]}"; do
        local backup_date=$(echo "$backup" | sed 's/lvm_backup_\([0-9]\{8\}_[0-9]\{6\}\).*/\1/')
        backup_date=$(date -d "${backup_date:0:8} ${backup_date:9:2}:${backup_date:11:2}:${backup_date:13:2}" "+%Y-%m-%d %H:%M:%S")
        echo -e "  ${YELLOW}$i)${NC} $backup_date"
        i=$((i + 1))
    done

    read -p "Select a backup to restore (1-${#backups[@]}, or 'c' to cancel): " choice

    if [[ "$choice" == "c" || "$choice" == "C" ]]; then
        echo -e "${YELLOW}Restore operation cancelled.${NC}"
        return 0
    fi

    # Validate input
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#backups[@]} ]; then
        echo -e "${RED}Invalid selection!${NC}"
        return 1
    fi

    local selected_backup="${backups[$choice - 1]}"
    local backup_path="$BACKUP_DIR/$selected_backup"

    echo -e "${RED}WARNING: Restoring will revert all LVM changes made since backup!${NC}"
    echo -e "${RED}This can potentially make your system unbootable if not done correctly.${NC}"
    read -p "Are you absolutely sure you want to proceed? (yes/no): " confirm

    if [[ "$confirm" != "yes" ]]; then
        echo -e "${YELLOW}Restore operation cancelled.${NC}"
        return 0
    fi

    echo -e "${YELLOW}Executing restore script from backup...${NC}"
    sudo "$backup_path/restore.sh"

    echo -e "${GREEN}Restore operation completed.${NC}"
    echo -e "${YELLOW}IMPORTANT: It's recommended to reboot your system now.${NC}"
}

# Function to display LVM status with detailed explanations
show_lvm_status() {
    echo -e "${BLUE}=== Current Disk Usage ===${NC}"
    echo -e "${CYAN}(This shows mounted filesystems and their space usage)${NC}"
    df -h | grep -E '/$|/home'

    echo -e "\n${BLUE}=== Volume Groups (VGs) ===${NC}"
    echo -e "${CYAN}(These are groups of physical disks/partitions that LVM manages together)${NC}"
    sudo vgs

    echo -e "\n${BLUE}=== Logical Volumes (LVs) ===${NC}"
    echo -e "${CYAN}(These are the 'virtual partitions' created from volume groups)${NC}"
    sudo lvs

    echo -e "\n${BLUE}=== Physical Volumes (PVs) ===${NC}"
    echo -e "${CYAN}(These are the actual physical disks/partitions added to LVM)${NC}"
    sudo pvs

    echo -e "\n${BLUE}=== Detailed Volume Group Info ===${NC}"
    echo -e "${CYAN}(Showing available space for extending volumes)${NC}"
    sudo vgdisplay | grep -E "VG Name|Free|PE Size"
}

# Function to extend logical volume and filesystem with detailed explanations
extend_logical_volume() {
    local vg_name=$1
    local lv_name=$2
    local extension=$3

    echo -e "${YELLOW}Preparing to extend ${vg_name}/${lv_name} by ${extension}${NC}"
    echo -e "${CYAN}(This will increase the size of your logical volume and filesystem)${NC}"

    # Create backup before proceeding
    echo -e "${YELLOW}Creating LVM configuration backup before making changes...${NC}"
    local backup_id=$(backup_lvm_config)
    echo -e "${GREEN}You can restore to this point using Backup ID: $backup_id${NC}"

    # Check if the VG has enough free space
    local free_space=$(sudo vgdisplay ${vg_name} | grep "Free" | awk '{print $7}')
    local free_unit=$(sudo vgdisplay ${vg_name} | grep "Free" | awk '{print $8}')

    echo -e "Available space: ${free_space}${free_unit}"

    # Basic validation
    echo -e "${YELLOW}Performing pre-flight checks...${NC}"
    if ! sudo lvdisplay /dev/${vg_name}/${lv_name} >/dev/null 2>&1; then
        echo -e "${RED}ERROR: Logical volume /dev/${vg_name}/${lv_name} not found!${NC}"
        echo -e "${CYAN}Learning note: Verify your LV name with 'sudo lvs' command${NC}"
        return 1
    fi

    # Confirm action
    echo -e "${YELLOW}About to extend /dev/${vg_name}/${lv_name} by ${extension}${NC}"
    read -p "Proceed? (y/n): " confirm
    if [[ "$confirm" != "y" ]]; then
        echo -e "${YELLOW}Operation cancelled by user${NC}"
        return 0
    fi

    # Perform the extension
    echo -e "${YELLOW}Extending logical volume...${NC}"
    echo -e "${CYAN}(This command increases the size of the LV container)${NC}"
    if sudo lvextend -L +${extension} /dev/${vg_name}/${lv_name}; then
        echo -e "${GREEN}Logical volume extended successfully!${NC}"

        # Get filesystem type
        local fs_type=$(sudo blkid -o value -s TYPE /dev/${vg_name}/${lv_name})
        echo -e "Detected filesystem: ${fs_type}"

        echo -e "${YELLOW}Resizing filesystem to use new space...${NC}"
        echo -e "${CYAN}(This command makes the filesystem aware of the new available space)${NC}"
        case $fs_type in
        ext4 | ext3 | ext2)
            echo -e "${CYAN}Learning note: ext4/3/2 filesystems use resize2fs command${NC}"
            sudo resize2fs /dev/${vg_name}/${lv_name}
            ;;
        xfs)
            echo -e "${CYAN}Learning note: XFS filesystems use xfs_growfs command${NC}"
            sudo xfs_growfs /dev/${vg_name}/${lv_name}
            ;;
        *)
            echo -e "${RED}Unsupported filesystem type. Manual resize required.${NC}"
            echo -e "${CYAN}Learning note: Each filesystem type uses its own resize command${NC}"
            return 1
            ;;
        esac

        echo -e "${GREEN}Filesystem resized successfully!${NC}"
        echo -e "${CYAN}You can verify the new size with 'df -h' command${NC}"
    else
        echo -e "${RED}Failed to extend logical volume!${NC}"
        echo -e "${CYAN}Learning note: Check if you have enough free space in the VG${NC}"
        return 1
    fi
}

# Function to rename volume group with safety checks
rename_volume_group() {
    local old_vg_name=$1
    local new_vg_name=$2

    echo -e "${YELLOW}Preparing to rename volume group ${old_vg_name} to ${new_vg_name}${NC}"
    echo -e "${CYAN}(This operation changes the name of a volume group and updates all references)${NC}"
    echo -e "${RED}WARNING: This operation can break your bootloader if not done properly!${NC}"

    # Create backup before proceeding
    echo -e "${YELLOW}Creating LVM configuration backup before making changes...${NC}"
    local backup_id=$(backup_lvm_config)
    echo -e "${GREEN}You can restore to this point using Backup ID: $backup_id${NC}"

    # Check if this is likely a system VG
    if mount | grep -q "/dev/${old_vg_name}" && mount | grep -q "on / "; then
        echo -e "${RED}CRITICAL WARNING: This appears to be your system volume group!${NC}"
        echo -e "${RED}Renaming while the system is running is DANGEROUS!${NC}"
        echo -e "${CYAN}Learning note: System VGs are used by the running system and bootloader${NC}"
        echo -e "${YELLOW}Recommended approach: Boot from Live USB and rename from there.${NC}"
        read -p "I understand the risks and want to proceed anyway (yes/no): " force_confirm
        if [[ "$force_confirm" != "yes" ]]; then
            echo -e "${YELLOW}Operation cancelled for safety reasons.${NC}"
            return 0
        fi
    fi

    # Final confirmation
    read -p "Proceed with renaming $old_vg_name to $new_vg_name? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo -e "${YELLOW}Operation cancelled by user${NC}"
        return 0
    fi

    # Create a recovery point
    echo -e "${YELLOW}Creating a quick recovery script in case of problems...${NC}"
    cat >~/vg_rename_recovery.sh <<EOF
#!/bin/bash
# Recovery script for renaming VG back to original name
sudo vgrename ${new_vg_name} ${old_vg_name}
sudo sed -i 's|/dev/${new_vg_name}|/dev/${old_vg_name}|g' /etc/fstab
sudo sed -i 's|/dev/mapper/${new_vg_name}-|/dev/mapper/${old_vg_name}-|g' /etc/fstab
sudo update-initramfs -u -k all
sudo update-grub
EOF
    chmod +x ~/vg_rename_recovery.sh

    # Perform the rename
    echo -e "${YELLOW}Renaming volume group...${NC}"
    echo -e "${CYAN}Learning note: vgrename changes the VG name in LVM metadata${NC}"
    if sudo vgrename ${old_vg_name} ${new_vg_name}; then
        echo -e "${GREEN}Volume group renamed successfully!${NC}"

        echo -e "${YELLOW}Updating system configuration files...${NC}"
        # Update /etc/fstab
        echo -e "${CYAN}Learning note: fstab contains mount points that reference the VG${NC}"
        sudo cp /etc/fstab /etc/fstab.backup.$(date +%Y%m%d)
        sudo sed -i "s|/dev/${old_vg_name}|/dev/${new_vg_name}|g" /etc/fstab
        sudo sed -i "s|/dev/mapper/${old_vg_name}-|/dev/mapper/${new_vg_name}-|g" /etc/fstab

        # Update initramfs
        echo -e "${YELLOW}Updating initial ramdisk...${NC}"
        echo -e "${CYAN}Learning note: initramfs needs to know the new VG name to boot properly${NC}"
        sudo update-initramfs -u -k all

        # Update GRUB
        echo -e "${YELLOW}Updating bootloader configuration...${NC}"
        echo -e "${CYAN}Learning note: GRUB references the VG in its boot configuration${NC}"
        sudo update-grub

        echo -e "${GREEN}Volume group rename completed successfully!${NC}"
        echo -e "${YELLOW}A recovery script has been created at ~/vg_rename_recovery.sh${NC}"
        echo -e "${YELLOW}IMPORTANT: Reboot your system to verify everything works correctly.${NC}"
    else
        echo -e "${RED}Failed to rename volume group!${NC}"
        echo -e "${CYAN}Try using the backup we created earlier to restore the configuration${NC}"
        return 1
    fi
}

# Function to create a new logical volume with educational comments
create_logical_volume() {
    local vg_name=$1
    local lv_name=$2
    local size=$3
    local mount_point=$4

    echo -e "${YELLOW}Preparing to create new logical volume ${lv_name} (${size}) in ${vg_name}${NC}"
    echo -e "${CYAN}(This will create a new 'virtual partition' within your volume group)${NC}"

    # Create backup before proceeding
    echo -e "${YELLOW}Creating LVM configuration backup before making changes...${NC}"
    local backup_id=$(backup_lvm_config)
    echo -e "${GREEN}You can restore to this point using Backup ID: $backup_id${NC}"

    # Check if VG exists
    if ! sudo vgdisplay ${vg_name} >/dev/null 2>&1; then
        echo -e "${RED}ERROR: Volume group ${vg_name} not found!${NC}"
        echo -e "${CYAN}Learning note: Check available VGs using 'sudo vgs' command${NC}"
        return 1
    fi

    # Check if LV already exists
    if sudo lvdisplay /dev/${vg_name}/${lv_name} >/dev/null 2>&1; then
        echo -e "${RED}ERROR: Logical volume ${lv_name} already exists!${NC}"
        echo -e "${CYAN}Learning note: LV names must be unique within a VG${NC}"
        return 1
    fi

    # Check free space
    local free_space=$(sudo vgdisplay ${vg_name} | grep "Free" | awk '{print $7}')
    local free_unit=$(sudo vgdisplay ${vg_name} | grep "Free" | awk '{print $8}')
    echo -e "Available space: ${free_space}${free_unit}"

    # Confirm action
    read -p "Proceed with creating ${lv_name} (${size})? (y/n): " confirm
    if [[ "$confirm" != "y" ]]; then
        echo -e "${YELLOW}Operation cancelled by user${NC}"
        return 0
    fi

    # Create the LV
    echo -e "${YELLOW}Creating logical volume...${NC}"
    echo -e "${CYAN}Learning note: lvcreate allocates space from the VG to a new LV${NC}"
    if sudo lvcreate -L ${size} -n ${lv_name} ${vg_name}; then
        echo -e "${GREEN}Logical volume created successfully!${NC}"

        # Format the volume
        echo -e "${YELLOW}Formatting the volume with ext4...${NC}"
        echo -e "${CYAN}Learning note: A new LV needs a filesystem before it can store files${NC}"
        sudo mkfs.ext4 /dev/${vg_name}/${lv_name}

        # Mount if requested
        if [[ -n "$mount_point" ]]; then
            echo -e "${YELLOW}Creating mount point at ${mount_point}...${NC}"
            sudo mkdir -p ${mount_point}

            echo -e "${YELLOW}Mounting volume...${NC}"
            echo -e "${CYAN}Learning note: Mounting makes the filesystem accessible at a directory${NC}"
            sudo mount /dev/${vg_name}/${lv_name} ${mount_point}

            echo -e "${YELLOW}Adding to /etc/fstab for persistent mounting...${NC}"
            echo -e "${CYAN}Learning note: fstab entries make mounts persistent across reboots${NC}"
            echo "/dev/${vg_name}/${lv_name} ${mount_point} ext4 defaults 0 2" | sudo tee -a /etc/fstab
        fi

        echo -e "${GREEN}Logical volume setup complete!${NC}"
        echo -e "${CYAN}You can now use this volume like any other partition${NC}"
    else
        echo -e "${RED}Failed to create logical volume!${NC}"
        echo -e "${CYAN}Learning note: Verify you have enough free space in the VG${NC}"
        return 1
    fi
}

# Function to provide an educational overview of LVM concepts
show_lvm_tutorial() {
    clear
    echo -e "${BLUE}==============================================${NC}"
    echo -e "${BLUE}       LVM Concepts Tutorial                  ${NC}"
    echo -e "${BLUE}==============================================${NC}"
    echo ""
    echo -e "${GREEN}LVM (Logical Volume Manager) Structure:${NC}"
    echo -e "${YELLOW}1. Physical Volumes (PV):${NC} Actual disk partitions or entire disks"
    echo -e "   ${CYAN}Example:${NC} /dev/sda2, /dev/nvme0n1p3"
    echo -e "   ${CYAN}Commands:${NC} pvcreate, pvdisplay, pvs"
    echo ""
    echo -e "${YELLOW}2. Volume Groups (VG):${NC} Pool of storage made from one or more PVs"
    echo -e "   ${CYAN}Example:${NC} ubuntu-vg, data-vg"
    echo -e "   ${CYAN}Commands:${NC} vgcreate, vgextend, vgdisplay, vgs"
    echo ""
    echo -e "${YELLOW}3. Logical Volumes (LV):${NC} 'Virtual partitions' created from VGs"
    echo -e "   ${CYAN}Example:${NC} root-lv, home-lv, swap-lv"
    echo -e "   ${CYAN}Commands:${NC} lvcreate, lvextend, lvdisplay, lvs"
    echo ""
    echo -e "${GREEN}Key Advantages of LVM:${NC}"
    echo -e "• ${YELLOW}Resize volumes while in use${NC} (live resizing)"
    echo -e "• ${YELLOW}Add new disks${NC} to existing volume groups"
    echo -e "• ${YELLOW}Move data${NC} between physical disks without downtime"
    echo -e "• ${YELLOW}Create snapshots${NC} for backups"
    echo -e "• ${YELLOW}Stripe data${NC} across multiple disks for performance"
    echo ""
    echo -e "${GREEN}Common LVM Operations:${NC}"
    echo -e "1. ${YELLOW}Extend a logical volume:${NC}"
    echo -e "   ${CYAN}sudo lvextend -L +10G /dev/vg-name/lv-name${NC}"
    echo -e "   ${CYAN}sudo resize2fs /dev/vg-name/lv-name${NC}"
    echo ""
    echo -e "2. ${YELLOW}Add a new disk to LVM:${NC}"
    echo -e "   ${CYAN}sudo pvcreate /dev/sdX${NC}"
    echo -e "   ${CYAN}sudo vgextend vg-name /dev/sdX${NC}"
    echo ""
    echo -e "3. ${YELLOW}Create a new logical volume:${NC}"
    echo -e "   ${CYAN}sudo lvcreate -L 20G -n new-lv vg-name${NC}"
    echo -e "   ${CYAN}sudo mkfs.ext4 /dev/vg-name/new-lv${NC}"
    echo ""
    echo -e "${GREEN}Safety Tips:${NC}"
    echo -e "• ${YELLOW}Always back up data${NC} before modifying volume structure"
    echo -e "• ${YELLOW}Be extremely careful${NC} with system volumes (root, boot)"
    echo -e "• ${YELLOW}Test changes${NC} in a non-production environment first"
    echo -e "• ${YELLOW}Keep recovery media${NC} handy in case of boot problems"
    echo ""
    read -p "Press Enter to return to main menu..."
}

# Main menu function
show_menu() {
    clear
    echo -e "${BLUE}==============================================${NC}"
    echo -e "${BLUE}       LVM Personalization Tool v1.1         ${NC}"
    echo -e "${BLUE}            User: ${GREEN}LESdylan${BLUE}             ${NC}"
    echo -e "${BLUE}            Date: ${GREEN}2025-04-04 18:15:42${BLUE}  ${NC}"
    echo -e "${BLUE}==============================================${NC}"
    echo ""
    echo -e "${YELLOW}1.${NC} Show current LVM status"
    echo -e "${YELLOW}2.${NC} Extend existing logical volume"
    echo -e "${YELLOW}3.${NC} Rename volume group (use with caution!)"
    echo -e "${YELLOW}4.${NC} Create new logical volume"
    echo -e "${YELLOW}5.${NC} Backup LVM configuration"
    echo -e "${YELLOW}6.${NC} Restore LVM configuration"
    echo -e "${YELLOW}7.${NC} LVM concepts tutorial (educational)"
    echo -e "${YELLOW}8.${NC} Exit"
    echo ""
    read -p "Select an option (1-8): " choice

    case $choice in
    1)
        show_lvm_status
        ;;
    2)
        echo ""
        read -p "Enter volume group name (e.g., ubuntu-vg): " vg_name
        read -p "Enter logical volume name (e.g., ubuntu-lv): " lv_name
        read -p "Enter size to extend (e.g., 10G, 200G): " extension
        extend_logical_volume "$vg_name" "$lv_name" "$extension"
        ;;
    3)
        echo ""
        echo -e "${RED}WARNING: Renaming system volume groups can break your system!${NC}"
        read -p "Enter current volume group name: " old_vg
        read -p "Enter new volume group name: " new_vg
        rename_volume_group "$old_vg" "$new_vg"
        ;;
    4)
        echo ""
        read -p "Enter volume group name: " vg_name
        read -p "Enter new logical volume name: " lv_name
        read -p "Enter size (e.g., 10G, 200G): " size
        read -p "Enter mount point (leave empty to skip mounting): " mount_point
        create_logical_volume "$vg_name" "$lv_name" "$size" "$mount_point"
        ;;
    5)
        echo ""
        echo -e "${YELLOW}Creating full LVM configuration backup...${NC}"
        backup_lvm_config
        ;;
    6)
        echo ""
        restore_lvm_config
        ;;
    7)
        show_lvm_tutorial
        ;;
    8)
        echo -e "${GREEN}Exiting. Have a great day!${NC}"
        exit 0
        ;;
    *)
        echo -e "${RED}Invalid option. Please try again.${NC}"
        ;;
    esac

    echo ""
    read -p "Press Enter to continue..."
    show_menu
}

# Verify we have sudo access before starting
if sudo -v; then
    show_menu
else
    echo -e "${RED}This script requires sudo privileges to function properly.${NC}"
    exit 1
fi
