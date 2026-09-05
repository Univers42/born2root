#!/bin/bash
# Fix hostname resolution error in Born2beRoot

# Colors for better output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

echo -e "${BLUE}${BOLD}=== HOSTNAME RESOLUTION FIX ===${NC}"

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}This script must be run as root!${NC}"
    echo -e "Please run with: sudo $0"
    exit 1
fi

# Get current hostname
CURRENT_HOSTNAME=$(hostname)
echo -e "${YELLOW}Current hostname is:${NC} ${BOLD}$CURRENT_HOSTNAME${NC}"

# Check /etc/hosts file
echo -e "\n${YELLOW}Current /etc/hosts file:${NC}"
cat /etc/hosts

# Backup original hosts file
cp /etc/hosts /etc/hosts.backup
echo -e "${GREEN}✓ Created backup at /etc/hosts.backup${NC}"

# Fix the hosts file
echo -e "\n${YELLOW}Updating /etc/hosts file...${NC}"
if grep -q "127.0.1.1.*$CURRENT_HOSTNAME" /etc/hosts; then
    echo -e "${GREEN}✓ Hostname entry exists, ensuring it's correct...${NC}"
    sed -i "s/127.0.1.1.*/127.0.1.1\t$CURRENT_HOSTNAME/" /etc/hosts
else
    echo -e "${YELLOW}Adding hostname entry to /etc/hosts...${NC}"
    echo -e "127.0.1.1\t$CURRENT_HOSTNAME" >>/etc/hosts
fi

# Verify the fix
echo -e "\n${YELLOW}Updated /etc/hosts file:${NC}"
cat /etc/hosts

# Test hostname resolution
echo -e "\n${YELLOW}Testing hostname resolution...${NC}"
if ping -c 1 $CURRENT_HOSTNAME &>/dev/null; then
    echo -e "${GREEN}✓ Hostname resolution is working!${NC}"
else
    echo -e "${RED}✗ Hostname resolution still not working.${NC}"
    echo -e "  This might require a system reboot to take effect."
fi

# Check DNS settings
echo -e "\n${YELLOW}Checking DNS configuration...${NC}"
if [ -f /etc/resolv.conf ]; then
    cat /etc/resolv.conf
    echo -e "${GREEN}✓ DNS configuration exists${NC}"
else
    echo -e "${RED}✗ No resolv.conf file found${NC}"
    echo -e "  Creating basic resolv.conf..."
    echo "nameserver 8.8.8.8" >/etc/resolv.conf
    echo "nameserver 8.8.4.4" >>/etc/resolv.conf
    echo -e "${GREEN}✓ Created basic DNS configuration${NC}"
fi

echo -e "\n${BLUE}${BOLD}=== HOSTNAME RESOLUTION FIX COMPLETE ===${NC}"
echo -e "Changes have been applied. If issues persist, please reboot your system."
echo -e "You can test with: hostname -f"
