#!/bin/bash

# Colors for better readability
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Function to print section headers
print_header() {
    echo -e "\n${BLUE}${BOLD}=== $1 ===${NC}"
}

# Function to check service status
check_service() {
    if systemctl is-active --quiet $1; then
        echo -e "${GREEN}✓ $1 is active${NC}"
    else
        echo -e "${RED}✗ $1 is not active${NC}"
        echo -e "  Fix: sudo systemctl start $1"
    fi
}

# Check if script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}This script must be run as root!${NC}"
    echo -e "Please run with: sudo $0"
    exit 1
fi

print_header "SYSTEM INFORMATION"
echo -e "${BOLD}Hostname:${NC} $(hostname)"
echo -e "${BOLD}Operating System:${NC} $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
echo -e "${BOLD}Kernel Version:${NC} $(uname -r)"
echo -e "${BOLD}CPU:${NC} $(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | sed 's/^[ \t]*//')"
echo -e "${BOLD}Memory:${NC} $(free -h | awk '/^Mem:/ {print $2}')"
echo -e "${BOLD}Disk:${NC} $(df -h / | awk 'NR==2 {print $2}')"

print_header "CHECKING APPARMOR"
check_service "apparmor"
echo -e "${BOLD}AppArmor Status:${NC}"
aa-status | head -2 | sed 's/^/  /'

print_header "CHECKING UFW"
check_service "ufw"
echo -e "${BOLD}UFW Status:${NC}"
ufw status | sed 's/^/  /'

if ! ufw status | grep -q "4242/tcp"; then
    echo -e "${RED}✗ SSH port (4242) is not allowed in UFW${NC}"
    echo -e "  Fix: sudo ufw allow 4242/tcp"
fi

print_header "CHECKING SSH"
check_service "ssh"
echo -e "${BOLD}SSH Configuration:${NC}"
grep "Port " /etc/ssh/sshd_config | grep -v "#" | sed 's/^/  /'
grep "PermitRootLogin " /etc/ssh/sshd_config | grep -v "#" | sed 's/^/  /'

# Verify SSH port
if ! grep "Port 4242" /etc/ssh/sshd_config >/dev/null; then
    echo -e "${RED}✗ SSH not configured for port 4242${NC}"
    echo -e "  Fix: Edit /etc/ssh/sshd_config and set 'Port 4242'"
fi

# Verify root login
if ! grep "PermitRootLogin no" /etc/ssh/sshd_config >/dev/null; then
    echo -e "${RED}✗ SSH root login not properly disabled${NC}"
    echo -e "  Fix: Edit /etc/ssh/sshd_config and set 'PermitRootLogin no'"
fi

print_header "CHECKING PASSWORD POLICY"
echo -e "${BOLD}Password Aging:${NC}"
grep "^PASS_MAX_DAYS\|^PASS_MIN_DAYS\|^PASS_WARN_AGE" /etc/login.defs | sed 's/^/  /'

echo -e "${BOLD}Password Complexity:${NC}"
if grep "pam_pwquality.so" /etc/pam.d/common-password >/dev/null; then
    echo -e "${GREEN}✓ Password quality requirements configured${NC}"
    grep "pam_pwquality.so" /etc/pam.d/common-password | sed 's/^/  /'
else
    echo -e "${RED}✗ Password quality requirements not configured${NC}"
    echo -e "  Fix: Install libpam-pwquality and configure /etc/pam.d/common-password"
fi

print_header "CHECKING SUDO CONFIGURATION"
echo -e "${BOLD}Sudo Log File:${NC}"
if grep "logfile=" /etc/sudoers.d/* 2>/dev/null | grep -q "/var/log/sudo"; then
    echo -e "${GREEN}✓ Sudo log file configured${NC}"
    grep "logfile=" /etc/sudoers.d/* 2>/dev/null | sed 's/^/  /'
else
    echo -e "${RED}✗ Sudo log file not configured${NC}"
    echo -e "  Fix: Add 'Defaults logfile=\"/var/log/sudo/sudo.log\"' to /etc/sudoers.d/sudo_config"
fi

echo -e "${BOLD}Sudo Security Settings:${NC}"
if grep "passwd_tries=" /etc/sudoers.d/* 2>/dev/null; then
    echo -e "${GREEN}✓ Sudo password attempts limit is configured${NC}"
    grep "passwd_tries=" /etc/sudoers.d/* 2>/dev/null | sed 's/^/  /'
else
    echo -e "${RED}✗ Sudo password attempts limit is not configured${NC}"
    echo -e "  Fix: Add 'Defaults passwd_tries=3' to /etc/sudoers.d/sudo_config"
fi

if grep "requiretty" /etc/sudoers.d/* 2>/dev/null; then
    echo -e "${GREEN}✓ Sudo requiretty is configured${NC}"
    grep "requiretty" /etc/sudoers.d/* 2>/dev/null | sed 's/^/  /'
else
    echo -e "${RED}✗ Sudo requiretty is not configured${NC}"
    echo -e "  Fix: Add 'Defaults requiretty' to /etc/sudoers.d/sudo_config"
fi

print_header "CHECKING USER GROUPS"
if getent group user42 >/dev/null; then
    echo -e "${GREEN}✓ user42 group exists${NC}"
    echo -e "${BOLD}Members:${NC} $(getent group user42 | cut -d: -f4)"
else
    echo -e "${RED}✗ user42 group does not exist${NC}"
    echo -e "  Fix: sudo groupadd user42"
fi

print_header "CHECKING MONITORING SCRIPT"
if [ -f "/root/monitoring.sh" ]; then
    echo -e "${GREEN}✓ Monitoring script exists${NC}"
    if [ -x "/root/monitoring.sh" ]; then
        echo -e "${GREEN}✓ Monitoring script is executable${NC}"
    else
        echo -e "${RED}✗ Monitoring script is not executable${NC}"
        echo -e "  Fix: sudo chmod +x /root/monitoring.sh"
    fi
else
    echo -e "${RED}✗ Monitoring script not found${NC}"
    echo -e "  Fix: Create monitoring script at /root/monitoring.sh"
fi

# Check crontab
if crontab -l -u root 2>/dev/null | grep -q "monitoring.sh"; then
    echo -e "${GREEN}✓ Monitoring script is scheduled in crontab${NC}"
    crontab -l -u root 2>/dev/null | grep "monitoring.sh" | sed 's/^/  /'
else
    echo -e "${RED}✗ Monitoring script is not scheduled in crontab${NC}"
    echo -e "  Fix: Add '*/10 * * * * /root/monitoring.sh | wall' to root's crontab"
fi

print_header "CHECKING LVM CONFIGURATION"
if lsblk | grep -q "lvm"; then
    echo -e "${GREEN}✓ LVM is configured${NC}"
    echo -e "${BOLD}LVM Partitions:${NC}"
    lsblk | grep "lvm" | sed 's/^/  /'
else
    echo -e "${RED}✗ LVM is not configured${NC}"
    echo -e "  Note: LVM must be configured during system installation"
fi

# Check for BONUS part
if dpkg -l | grep -q lighttpd; then
    print_header "CHECKING WEB SERVER (BONUS)"
    check_service "lighttpd"

    if netstat -tulpn | grep -q ":80.*lighttpd"; then
        echo -e "${GREEN}✓ Lighttpd is listening on port 80${NC}"
    else
        echo -e "${RED}✗ Lighttpd is not listening on port 80${NC}"
        echo -e "  Fix: Check lighttpd configuration and restart"
    fi

    check_service "mariadb"

    if [ -d "/var/www/html/wordpress" ]; then
        echo -e "${GREEN}✓ WordPress is installed${NC}"
        if [ -f "/var/www/html/wordpress/wp-config.php" ]; then
            echo -e "${GREEN}✓ WordPress is configured${NC}"
        else
            echo -e "${RED}✗ WordPress configuration is missing${NC}"
        fi
    else
        echo -e "${RED}✗ WordPress is not installed${NC}"
    fi
fi

print_header "CONNECTIVITY TEST"
echo -e "${YELLOW}Testing SSH connectivity on port 4242...${NC}"
if nc -z -v localhost 4242 2>&1 | grep -q "succeeded"; then
    echo -e "${GREEN}✓ SSH is reachable on port 4242${NC}"
else
    echo -e "${RED}✗ SSH is not reachable on port 4242${NC}"
    echo -e "  Check SSH configuration and firewall rules"
fi

# Check web server if installed
if dpkg -l | grep -q lighttpd; then
    echo -e "${YELLOW}Testing web server connectivity on port 80...${NC}"
    if nc -z -v localhost 80 2>&1 | grep -q "succeeded"; then
        echo -e "${GREEN}✓ Web server is reachable on port 80${NC}"
    else
        echo -e "${RED}✗ Web server is not reachable on port 80${NC}"
        echo -e "  Check lighttpd configuration and firewall rules"
    fi
fi

print_header "VERIFICATION COMPLETE"
echo -e "${GREEN}All Born2beRoot requirements have been verified${NC}"
echo -e "${YELLOW}Please fix any items marked with a red ✗ before evaluation${NC}"
echo
echo -e "${BOLD}BORN2BEROOT PROJECT IS READY FOR EVALUATION${NC}"
