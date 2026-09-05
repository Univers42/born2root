#!/bin/bash

# Paths to original ISO and output ISO
ORIGINAL_ISO="/path/to/debian-11.x.0-amd64-netinst.iso"
MODIFIED_ISO="debian-11-auto.iso"

# Create a temporary working directory
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"

# Extract the original ISO
mkdir -p iso
sudo mount -o loop "$ORIGINAL_ISO" iso
mkdir -p new_iso
cp -rT iso new_iso
sudo umount iso
rmdir iso

# Copy preseed file
mkdir -p new_iso/preseed
cp /path/to/debian-preseed.cfg new_iso/preseed/

# Modify isolinux configuration
sed -i 's/timeout 0/timeout 1/' new_iso/isolinux/isolinux.cfg
sed -i '/^label install$/,/^label/{s/\(append .*\)/\1 auto=true priority=critical file=\/preseed\/debian-preseed.cfg/}' new_iso/isolinux/txt.cfg

# Create the new ISO
xorriso -as mkisofs -o "$MODIFIED_ISO" \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -c isolinux/boot.cat -b isolinux/isolinux.bin -no-emul-boot \
    -boot-load-size 4 -boot-info-table \
    new_iso/

echo "Modified ISO created at: $MODIFIED_ISO"

# Clean up
rm -rf "$TEMP_DIR"
