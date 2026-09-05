#!/bin/bash

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== IMPROVED LVM DETECTION ===${NC}"

# Method 1: Check with lsblk
if lsblk | grep -q "lvm"; then
    echo -e "${GREEN}✓ LVM detected using lsblk${NC}"
    echo -e "  LVM partitions:"
    lsblk | grep "lvm" | sed 's/^/  /'
else
    echo -e "${RED}✗ No LVM detected with lsblk${NC}"
fi

# Method 2: Check with mount
if mount | grep -q "mapper"; then
    echo -e "${GREEN}✓ LVM detected in mount points${NC}"
    echo -e "  LVM mounts:"
    mount | grep "mapper" | sed 's/^/  /'
else
    echo -e "${RED}✗ No LVM mount points detected${NC}"
fi

# Method 3: Check with vgs and lvs - but handle permission issues
echo -e "\nAttempting privileged LVM checks (might require sudo):"
if command -v vgs >/dev/null 2>&1; then
    if vgs 2>/dev/null | grep -q "VG"; then
        echo -e "${GREEN}✓ LVM volume groups found${NC}"
        vgs 2>/dev/null | sed 's/^/  /'
    elif sudo vgs 2>/dev/null | grep -q "VG"; then
        echo -e "${GREEN}✓ LVM volume groups found (sudo required)${NC}"
        sudo vgs 2>/dev/null | sed 's/^/  /'
    else
        echo -e "${RED}✗ No LVM volume groups detected${NC}"
    fi
else
    echo -e "${RED}✗ LVM tools not installed${NC}"
fi
