#!/bin/bash
# Born2beRoot Port Connectivity Fix
# For both SSH (4242) and Web Server (80)

# Color codes for readability
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

echo -e "${BLUE}${BOLD}=== BORN2BEROOT PORT CONNECTIVITY FIX ===${NC}"

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}This script must be run as root!${NC}"
    echo -e "Please run with: sudo $0"
    exit 1
fi

# 1. Check and fix services
echo -e "\n${YELLOW}${BOLD}CHECKING SERVICE STATUS${NC}"

# Check SSH
echo -e "\n${YELLOW}SSH Service Status:${NC}"
if systemctl is-active --quiet ssh; then
    echo -e "${GREEN}✓ SSH service is running${NC}"
else
    echo -e "${RED}✗ SSH service is not running${NC}"
    echo -e "  Attempting to start SSH service..."
    systemctl start ssh
    if systemctl is-active --quiet ssh; then
        echo -e "${GREEN}✓ SSH service started successfully${NC}"
    else
        echo -e "${RED}✗ Failed to start SSH service${NC}"
        echo -e "  Check logs: systemctl status ssh"
    fi
fi

# Check Web Server (if installed)
echo -e "\n${YELLOW}Web Server Status:${NC}"
if command -v lighttpd &>/dev/null; then
    if systemctl is-active --quiet lighttpd; then
        echo -e "${GREEN}✓ Lighttpd service is running${NC}"
    else
        echo -e "${RED}✗ Lighttpd service is not running${NC}"
        echo -e "  Attempting to start Lighttpd service..."
        systemctl start lighttpd
        if systemctl is-active --quiet lighttpd; then
            echo -e "${GREEN}✓ Lighttpd service started successfully${NC}"
        else
            echo -e "${RED}✗ Failed to start Lighttpd service${NC}"
            echo -e "  Check logs: systemctl status lighttpd"
        fi
    fi
else
    echo -e "${YELLOW}i Lighttpd is not installed (skipping web server checks)${NC}"
fi

# 2. Check and fix SSH configuration
echo -e "\n${YELLOW}${BOLD}CHECKING SSH CONFIGURATION${NC}"
if grep -q "^Port 4242" /etc/ssh/sshd_config; then
    echo -e "${GREEN}✓ SSH configured for port 4242${NC}"
else
    echo -e "${RED}✗ SSH not configured for port 4242${NC}"
    echo -e "  Fixing SSH configuration..."
    sed -i 's/^#*Port .*/Port 4242/' /etc/ssh/sshd_config
    echo -e "${GREEN}✓ SSH configuration fixed${NC}"
    echo -e "  Restarting SSH service..."
    systemctl restart ssh
fi

# 3. Check and fix firewall rules
echo -e "\n${YELLOW}${BOLD}CHECKING FIREWALL CONFIGURATION${NC}"
echo -e "\n${YELLOW}Current UFW status:${NC}"
ufw status

if ! ufw status | grep -q "4242/tcp.*ALLOW"; then
    echo -e "${RED}✗ SSH port 4242 not allowed in firewall${NC}"
    echo -e "  Adding SSH port to firewall..."
    ufw allow 4242/tcp
    echo -e "${GREEN}✓ SSH port 4242 allowed in firewall${NC}"
else
    echo -e "${GREEN}✓ SSH port 4242 allowed in firewall${NC}"
fi

# Check for web server port in firewall
if command -v lighttpd &>/dev/null; then
    if ! ufw status | grep -q "80/tcp.*ALLOW"; then
        echo -e "${RED}✗ Web server port 80 not allowed in firewall${NC}"
        echo -e "  Adding web server port to firewall..."
        ufw allow 80/tcp
        echo -e "${GREEN}✓ Web server port 80 allowed in firewall${NC}"
    else
        echo -e "${GREEN}✓ Web server port 80 allowed in firewall${NC}"
    fi
fi

# Ensure UFW is enabled
if ! ufw status | grep -q "Status: active"; then
    echo -e "${RED}✗ UFW firewall is not active${NC}"
    echo -e "  Enabling UFW firewall..."
    echo "y" | ufw enable
    echo -e "${GREEN}✓ UFW firewall enabled${NC}"
else
    echo -e "${GREEN}✓ UFW firewall is active${NC}"
fi

# 4. Check listening ports
echo -e "\n${YELLOW}${BOLD}CHECKING LISTENING PORTS${NC}"
echo -e "${YELLOW}Ports currently listening:${NC}"
ss -tulpn | grep "LISTEN"

# Test connectivity
echo -e "\n${YELLOW}${BOLD}TESTING LOCAL CONNECTIVITY${NC}"
echo -e "${YELLOW}Testing SSH port 4242:${NC}"
if nc -z -v -w3 localhost 4242 2>&1 | grep -q "succeeded"; then
    echo -e "${GREEN}✓ SSH port 4242 is reachable locally${NC}"
else
    echo -e "${RED}✗ SSH port 4242 is not reachable locally${NC}"
    echo -e "  This may indicate a service or configuration issue"
fi

if command -v lighttpd &>/dev/null; then
    echo -e "${YELLOW}Testing web server port 80:${NC}"
    if nc -z -v -w3 localhost 80 2>&1 | grep -q "succeeded"; then
        echo -e "${GREEN}✓ Web server port 80 is reachable locally${NC}"
    else
        echo -e "${RED}✗ Web server port 80 is not reachable locally${NC}"
        echo -e "  This may indicate a service or configuration issue"
    fi
fi

# 5. VirtualBox port forwarding reminder
echo -e "\n${YELLOW}${BOLD}VIRTUALBOX PORT FORWARDING${NC}"
echo -e "If you're using VirtualBox, check your port forwarding rules:"
echo -e "1. Shut down the VM (if possible)"
echo -e "2. Go to VM Settings → Network → Adapter 1 → Advanced → Port Forwarding"
echo -e "3. Ensure you have these rules:"
echo -e "   - Name: SSH, Protocol: TCP, Host Port: 4242, Guest Port: 4242"
echo -e "   - Name: HTTP, Protocol: TCP, Host Port: 80, Guest Port: 80"

# 6. Restart services as final step
echo -e "\n${YELLOW}${BOLD}RESTARTING SERVICES${NC}"
echo -e "${YELLOW}Restarting SSH...${NC}"
systemctl restart ssh
if command -v lighttpd &>/dev/null; then
    echo -e "${YELLOW}Restarting web server...${NC}"
    systemctl restart lighttpd
fi

echo -e "\n${BLUE}${BOLD}=== PORT CONNECTIVITY FIX COMPLETE ===${NC}"
echo -e "Try connecting again. If issues persist, check VirtualBox port forwarding."
echo -e "You can test SSH connection with: ssh -p 4242 $(whoami)@localhost"
echo -e "You can test web server with: curl -I http://localhost"
