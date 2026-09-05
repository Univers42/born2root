#!/bin/bash
# Born2beRoot SSH Daemon Fix

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BLUE}${BOLD}=== BORN2BEROOT SSH DAEMON FIX ===${NC}"

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}This script must be run as root!${NC}"
    echo -e "Please run with: sudo $0"
    exit 1
fi

# 1. Display SSH logs for diagnostics
echo -e "\n${YELLOW}${BOLD}CHECKING SSH LOGS FOR ERRORS${NC}"
echo -e "${YELLOW}Last 10 SSH error log entries:${NC}"
grep "sshd" /var/log/auth.log | grep "error\|failed\|invalid" | tail -10

# 2. Check SSH config file for errors
echo -e "\n${YELLOW}${BOLD}VERIFYING SSH CONFIGURATION${NC}"
echo -e "${YELLOW}Running SSH config test...${NC}"
sshd -t
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ SSH configuration syntax is valid${NC}"
else
    echo -e "${RED}✗ SSH configuration has syntax errors${NC}"
    echo -e "  Fixing common configuration issues..."

    # Ensure SSH port is 4242
    if ! grep -q "^Port 4242" /etc/ssh/sshd_config; then
        sed -i 's/^#*Port .*/Port 4242/' /etc/ssh/sshd_config
        echo -e "${GREEN}✓ Fixed: SSH Port set to 4242${NC}"
    fi

    # Check for incorrect ListenAddress settings
    if grep -q "^ListenAddress 127.0.0.1" /etc/ssh/sshd_config; then
        sed -i 's/^ListenAddress 127.0.0.1/#ListenAddress 127.0.0.1/' /etc/ssh/sshd_config
        echo -e "${GREEN}✓ Fixed: Removed restrictive ListenAddress${NC}"
    fi
fi

# 3. Check SSH host keys
echo -e "\n${YELLOW}${BOLD}CHECKING SSH HOST KEYS${NC}"
if [ ! -f /etc/ssh/ssh_host_rsa_key ] || [ ! -f /etc/ssh/ssh_host_ecdsa_key ]; then
    echo -e "${RED}✗ SSH host keys are missing${NC}"
    echo -e "  Regenerating SSH host keys..."

    # Remove old keys
    rm -f /etc/ssh/ssh_host_*_key*

    # Generate new keys
    ssh-keygen -A
    echo -e "${GREEN}✓ SSH host keys regenerated${NC}"
else
    echo -e "${GREEN}✓ SSH host keys exist${NC}"
fi

# 4. Check SSH files permissions
echo -e "\n${YELLOW}${BOLD}CHECKING SSH FILES PERMISSIONS${NC}"
find /etc/ssh -type f -name "ssh_host_*_key" -exec chmod 600 {} \;
find /etc/ssh -type f -name "ssh_host_*_key.pub" -exec chmod 644 {} \;
chmod 644 /etc/ssh/sshd_config
echo -e "${GREEN}✓ SSH file permissions have been fixed${NC}"

# 5. Display SSH service status
echo -e "\n${YELLOW}${BOLD}CHECKING SSH SERVICE STATUS${NC}"
systemctl status ssh | head -10

# 6. Restart SSH service
echo -e "\n${YELLOW}${BOLD}RESTARTING SSH SERVICE${NC}"
systemctl restart ssh
sleep 2

if systemctl is-active --quiet ssh; then
    echo -e "${GREEN}✓ SSH service successfully restarted${NC}"
else
    echo -e "${RED}✗ SSH service failed to restart${NC}"
    echo -e "  Trying to start SSH service..."
    systemctl start ssh

    if systemctl is-active --quiet ssh; then
        echo -e "${GREEN}✓ SSH service started successfully${NC}"
    else
        echo -e "${RED}✗ Failed to start SSH service${NC}"
        echo -e "  Manual intervention required. Check: systemctl status ssh"
    fi
fi

# 7. Check listening ports
echo -e "\n${YELLOW}${BOLD}VERIFYING SSH PORT IS LISTENING${NC}"
if ss -tuln | grep -q ":4242"; then
    echo -e "${GREEN}✓ SSH is listening on port 4242${NC}"
else
    echo -e "${RED}✗ SSH is NOT listening on port 4242${NC}"
    echo -e "  This indicates a serious configuration issue with sshd"
fi

# 8. Test SSH connection
echo -e "\n${YELLOW}${BOLD}TESTING LOCAL SSH CONNECTION${NC}"
echo -e "${YELLOW}Trying to connect to SSH locally...${NC}"
timeout 5 ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 -p 4242 localhost echo success 2>&1 || echo "Connection failed"

# 9. Final summary and suggestions
echo -e "\n${BLUE}${BOLD}=== SSH CONFIGURATION REPAIR COMPLETE ===${NC}"
echo -e "If you're still having connectivity issues:"
echo -e "1. Verify that UFW allows port 4242: ${BOLD}sudo ufw status${NC}"
echo -e "2. Verify sshd_config manually: ${BOLD}cat /etc/ssh/sshd_config | grep -v '^#' | grep -v '^$'${NC}"
echo -e "3. Try a complete SSH reinstall: ${BOLD}sudo apt-get purge --auto-remove openssh-server && sudo apt-get install openssh-server${NC}"
echo -e "4. Check for any error logs: ${BOLD}grep sshd /var/log/auth.log${NC}"
echo -e "\nFor VirtualBox users, verify port forwarding is configured correctly."
