#!/bin/bash

# Colors for better readability
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== BORN2BEROOT COMPLETE VERIFICATION SCRIPT ===${NC}"
echo -e "${YELLOW}Running comprehensive checks...${NC}\n"

# Check AppArmor (multiple methods)
echo -e "${BLUE}=== CHECKING SECURITY MODULE ===${NC}"
if sudo aa-status &>/dev/null || [ "$(sudo systemctl is-active apparmor)" = "active" ]; then
    echo -e "${GREEN}✓ AppArmor is active${NC}"
    # Display enabled profiles
    sudo aa-status 2>/dev/null | grep -q "profiles are in enforce mode" &&
        echo -e "  $(sudo aa-status 2>/dev/null | grep "profiles are in enforce mode")"
else
    echo -e "${RED}✗ AppArmor is not active${NC}"
    echo -e "  Fix: sudo systemctl start apparmor"
fi

# Check UFW (improved with multiple detection methods)
echo -e "\n${BLUE}=== CHECKING FIREWALL CONFIGURATION ===${NC}"
if sudo systemctl is-active ufw &>/dev/null || sudo ufw status 2>/dev/null | grep -q "Status: active"; then
    echo -e "${GREEN}✓ UFW is active${NC}"
    # Show allowed ports
    echo -e "  Allowed ports:"
    sudo ufw status 2>/dev/null | grep "ALLOW" | sed 's/^/  /'

    # Check specific required ports
    if sudo ufw status 2>/dev/null | grep -q "4242/tcp.*ALLOW"; then
        echo -e "${GREEN}✓ SSH port (4242) is allowed${NC}"
    else
        echo -e "${RED}✗ SSH port (4242) is not allowed${NC}"
        echo -e "  Fix: sudo ufw allow 4242/tcp"
    fi

    if sudo ufw status 2>/dev/null | grep -q "80/tcp.*ALLOW"; then
        echo -e "${GREEN}✓ HTTP port (80) is allowed${NC}"
    else
        echo -e "${RED}✗ HTTP port (80) is not allowed${NC}"
        echo -e "  Fix: sudo ufw allow 80/tcp"
    fi
else
    echo -e "${RED}✗ UFW is not active${NC}"
    echo -e "  Fix: sudo ufw enable"
fi

# Check Web Server with enhanced detection
echo -e "\n${BLUE}=== CHECKING WEB SERVER ===${NC}"
WEB_SERVER_FOUND=false

# Check for Lighttpd
if command -v lighttpd &>/dev/null && sudo systemctl is-active lighttpd &>/dev/null; then
    echo -e "${GREEN}✓ Lighttpd is active${NC}"
    WEB_SERVER_FOUND=true
    # Check if it's listening on port 80
    if sudo ss -tulpn | grep -q ":80.*lighttpd"; then
        echo -e "${GREEN}✓ Lighttpd is listening on port 80${NC}"
    else
        echo -e "${RED}✗ Lighttpd is not listening on port 80${NC}"
    fi
fi

# Check for Apache2
if command -v apache2 &>/dev/null && sudo systemctl is-active apache2 &>/dev/null; then
    echo -e "${GREEN}✓ Apache2 is active${NC}"
    WEB_SERVER_FOUND=true
    # Check if it's listening on port 80
    if sudo ss -tulpn | grep -q ":80.*apache2"; then
        echo -e "${GREEN}✓ Apache2 is listening on port 80${NC}"
    else
        echo -e "${RED}✗ Apache2 is not listening on port 80${NC}"
    fi
fi

# Check for Nginx
if command -v nginx &>/dev/null && sudo systemctl is-active nginx &>/dev/null; then
    echo -e "${GREEN}✓ Nginx is active${NC}"
    WEB_SERVER_FOUND=true
    # Check if it's listening on port 80
    if sudo ss -tulpn | grep -q ":80.*nginx"; then
        echo -e "${GREEN}✓ Nginx is listening on port 80${NC}"
    else
        echo -e "${RED}✗ Nginx is not listening on port 80${NC}"
    fi
fi

if [ "$WEB_SERVER_FOUND" = false ]; then
    echo -e "${RED}✗ No web server detected${NC}"
    echo -e "  Fix: sudo apt install lighttpd && sudo systemctl start lighttpd"
fi

# Check Password Policy (comprehensive)
echo -e "\n${BLUE}=== CHECKING PASSWORD POLICY ===${NC}"
PASS_POLICY_OK=true

# Check if required PAM modules are installed
if [ -f "/etc/pam.d/common-password" ]; then
    # Check minimum length
    if sudo grep -q "minlen=10" /etc/pam.d/common-password 2>/dev/null; then
        echo -e "${GREEN}✓ Password minimum length (10) configured${NC}"
    else
        echo -e "${RED}✗ Password minimum length not properly configured${NC}"
        echo -e "  Fix: Add 'minlen=10' to /etc/pam.d/common-password"
        PASS_POLICY_OK=false
    fi

    # Check for uppercase requirement
    if sudo grep -q "ucredit=-1" /etc/pam.d/common-password 2>/dev/null; then
        echo -e "${GREEN}✓ Password requires uppercase characters${NC}"
    else
        echo -e "${RED}✗ Password uppercase requirement not configured${NC}"
        echo -e "  Fix: Add 'ucredit=-1' to /etc/pam.d/common-password"
        PASS_POLICY_OK=false
    fi

    # Check for digit requirement
    if sudo grep -q "dcredit=-1" /etc/pam.d/common-password 2>/dev/null; then
        echo -e "${GREEN}✓ Password requires digits${NC}"
    else
        echo -e "${RED}✗ Password digit requirement not configured${NC}"
        echo -e "  Fix: Add 'dcredit=-1' to /etc/pam.d/common-password"
        PASS_POLICY_OK=false
    fi
else
    echo -e "${RED}✗ Password policy file not found${NC}"
    PASS_POLICY_OK=false
fi

# Check password aging policy
if [ -f "/etc/login.defs" ]; then
    # Get password expiration values
    pass_max_days=$(grep ^PASS_MAX_DAYS /etc/login.defs | awk '{print $2}')
    pass_min_days=$(grep ^PASS_MIN_DAYS /etc/login.defs | awk '{print $2}')
    pass_warn_age=$(grep ^PASS_WARN_AGE /etc/login.defs | awk '{print $2}')

    if [ "$pass_max_days" -le 30 ]; then
        echo -e "${GREEN}✓ Password maximum age (${pass_max_days} days) is configured correctly${NC}"
    else
        echo -e "${RED}✗ Password maximum age (${pass_max_days} days) exceeds 30 days${NC}"
        echo -e "  Fix: Edit PASS_MAX_DAYS in /etc/login.defs"
        PASS_POLICY_OK=false
    fi

    if [ "$pass_min_days" -ge 2 ]; then
        echo -e "${GREEN}✓ Password minimum age (${pass_min_days} days) is configured correctly${NC}"
    else
        echo -e "${RED}✗ Password minimum age (${pass_min_days} days) is less than 2 days${NC}"
        echo -e "  Fix: Edit PASS_MIN_DAYS in /etc/login.defs"
        PASS_POLICY_OK=false
    fi

    if [ "$pass_warn_age" -ge 7 ]; then
        echo -e "${GREEN}✓ Password warning period (${pass_warn_age} days) is configured correctly${NC}"
    else
        echo -e "${RED}✗ Password warning period (${pass_warn_age} days) is less than 7 days${NC}"
        echo -e "  Fix: Edit PASS_WARN_AGE in /etc/login.defs"
        PASS_POLICY_OK=false
    fi
else
    echo -e "${RED}✗ Password aging configuration file not found${NC}"
    PASS_POLICY_OK=false
fi

if [ "$PASS_POLICY_OK" = true ]; then
    echo -e "${GREEN}✓ Overall password policy looks good${NC}"
fi

# Check Sudo Configuration (comprehensive)
echo -e "\n${BLUE}=== CHECKING SUDO CONFIGURATION ===${NC}"
SUDO_CONFIG_OK=true

# Check sudo log file configuration
sudo_log_file=$(sudo grep "logfile=" /etc/sudoers /etc/sudoers.d/* 2>/dev/null | grep -o "/[^ ]*" | head -1)
if [ -n "$sudo_log_file" ]; then
    echo -e "${GREEN}✓ Sudo logging is configured to: $sudo_log_file${NC}"

    # Check if log directory exists
    sudo_log_dir=$(dirname "$sudo_log_file")
    if [ -d "$sudo_log_dir" ]; then
        echo -e "${GREEN}✓ Sudo log directory exists${NC}"
    else
        echo -e "${RED}✗ Sudo log directory does not exist${NC}"
        echo -e "  Fix: sudo mkdir -p $sudo_log_dir"
        SUDO_CONFIG_OK=false
    fi
else
    echo -e "${RED}✗ Sudo logging is not configured${NC}"
    echo -e "  Fix: Add 'Defaults logfile=\"/var/log/sudo/sudo.log\"' to /etc/sudoers.d/sudo_config"
    SUDO_CONFIG_OK=false
fi

# Check sudo security settings
if sudo grep -q "requiretty" /etc/sudoers /etc/sudoers.d/* 2>/dev/null; then
    echo -e "${GREEN}✓ Sudo requiretty is configured${NC}"
else
    echo -e "${RED}✗ Sudo requiretty is not configured${NC}"
    echo -e "  Fix: Add 'Defaults requiretty' to /etc/sudoers.d/sudo_config"
    SUDO_CONFIG_OK=false
fi

if sudo grep -q "passwd_tries" /etc/sudoers /etc/sudoers.d/* 2>/dev/null; then
    echo -e "${GREEN}✓ Sudo password attempts limit is configured${NC}"
else
    echo -e "${RED}✗ Sudo password attempts limit is not configured${NC}"
    echo -e "  Fix: Add 'Defaults passwd_tries=3' to /etc/sudoers.d/sudo_config"
    SUDO_CONFIG_OK=false
fi

if sudo grep -q "badpass_message" /etc/sudoers /etc/sudoers.d/* 2>/dev/null; then
    echo -e "${GREEN}✓ Sudo bad password message is configured${NC}"
else
    echo -e "${RED}✗ Sudo bad password message is not configured${NC}"
    echo -e "  Fix: Add 'Defaults badpass_message=\"Password is wrong, please try again\"' to /etc/sudoers.d/sudo_config"
    SUDO_CONFIG_OK=false
fi

# Check SSH Configuration
echo -e "\n${BLUE}=== CHECKING SSH CONFIGURATION ===${NC}"
if [ -f "/etc/ssh/sshd_config" ]; then
    # Check SSH port
    ssh_port=$(grep "^Port " /etc/ssh/sshd_config | awk '{print $2}')
    if [ "$ssh_port" = "4242" ]; then
        echo -e "${GREEN}✓ SSH is configured to use port 4242${NC}"
    else
        echo -e "${RED}✗ SSH is not using port 4242 (current: $ssh_port)${NC}"
        echo -e "  Fix: Set 'Port 4242' in /etc/ssh/sshd_config"
    fi

    # Check root login setting
    root_login=$(grep "^PermitRootLogin" /etc/ssh/sshd_config | awk '{print $2}')
    if [ "$root_login" = "no" ] || [ "$root_login" = "prohibit-password" ]; then
        echo -e "${GREEN}✓ SSH root login is disabled${NC}"
    else
        echo -e "${RED}✗ SSH root login is not properly disabled${NC}"
        echo -e "  Fix: Set 'PermitRootLogin no' in /etc/ssh/sshd_config"
    fi
else
    echo -e "${RED}✗ SSH configuration file not found${NC}"
fi

# Check WordPress Configuration
echo -e "\n${BLUE}=== CHECKING WORDPRESS (BONUS) ===${NC}"
if [ -f "/var/www/html/wp-config.php" ]; then
    echo -e "${GREEN}✓ WordPress is installed${NC}"

    # Check database configuration
    db_name=$(grep DB_NAME /var/www/html/wp-config.php | cut -d"'" -f4)
    db_user=$(grep DB_USER /var/www/html/wp-config.php | cut -d"'" -f4)
    echo -e "  Database name: $db_name"
    echo -e "  Database user: $db_user"

    # Check database connection
    if command -v mysql &>/dev/null; then
        if sudo mysql -e "SHOW DATABASES" 2>/dev/null | grep -q "$db_name"; then
            echo -e "${GREEN}✓ WordPress database exists${NC}"
        else
            echo -e "${RED}✗ WordPress database ($db_name) not found in MySQL${NC}"
        fi
    fi

    # Check PHP
    if command -v php &>/dev/null; then
        php_version=$(php -v | head -1 | cut -d' ' -f2)
        echo -e "${GREEN}✓ PHP is installed (version $php_version)${NC}"
    else
        echo -e "${RED}✗ PHP is not installed${NC}"
    fi
else
    echo -e "${RED}✗ WordPress is not installed${NC}"
    echo -e "  Note: This is only needed for the bonus part"
fi

# LVM Configuration Check
echo -e "\n${BLUE}=== CHECKING LVM CONFIGURATION ===${NC}"
if command -v lvs &>/dev/null && sudo lvs &>/dev/null; then
    echo -e "${GREEN}✓ LVM is configured${NC}"
    # Show LVM volumes
    echo -e "  LVM Logical Volumes:"
    sudo lvs 2>/dev/null | sed 's/^/  /'

    # Check required partitions
    required_partitions=("root" "home" "var" "srv" "tmp" "var-log" "var--log")
    for part in "${required_partitions[@]}"; do
        if sudo lvs 2>/dev/null | grep -q "$part"; then
            echo -e "${GREEN}✓ Found $part partition${NC}"
        fi
    done
else
    echo -e "${RED}✗ LVM is not configured${NC}"
fi

# Monitoring Script Check
echo -e "\n${BLUE}=== CHECKING MONITORING SCRIPT ===${NC}"
monitoring_script=$(find /root /home -name "monitoring.sh" 2>/dev/null | head -1)
if [ -n "$monitoring_script" ]; then
    echo -e "${GREEN}✓ Monitoring script found: $monitoring_script${NC}"

    # Check if script is executable
    if [ -x "$monitoring_script" ]; then
        echo -e "${GREEN}✓ Monitoring script is executable${NC}"
    else
        echo -e "${RED}✗ Monitoring script is not executable${NC}"
        echo -e "  Fix: chmod +x $monitoring_script"
    fi

    # Check crontab
    if sudo crontab -l 2>/dev/null | grep -q "monitoring.sh"; then
        cron_schedule=$(sudo crontab -l | grep "monitoring.sh" | awk '{print $1,$2,$3,$4,$5}')
        echo -e "${GREEN}✓ Monitoring script is scheduled in crontab: $cron_schedule${NC}"
    else
        echo -e "${RED}✗ Monitoring script is not scheduled in crontab${NC}"
        echo -e "  Fix: Add '*/10 * * * * /path/to/monitoring.sh' to root crontab"
    fi
else
    echo -e "${RED}✗ Monitoring script not found${NC}"
fi

# User Group Check
echo -e "\n${BLUE}=== CHECKING USER CONFIGURATION ===${NC}"
# Check user42 group
if getent group | grep -q "user42"; then
    echo -e "${GREEN}✓ user42 group exists${NC}"
    # Show members
    members=$(getent group user42 | cut -d: -f4)
    if [ -n "$members" ]; then
        echo -e "  Members: $members"
    else
        echo -e "  Warning: No users in user42 group"
    fi
else
    echo -e "${RED}✗ user42 group does not exist${NC}"
    echo -e "  Fix: sudo groupadd user42"
fi

# Check sudo group membership
current_user=$(whoami)
if groups "$current_user" | grep -q "\bsudo\b"; then
    echo -e "${GREEN}✓ Current user ($current_user) is in sudo group${NC}"
else
    echo -e "${RED}✗ Current user ($current_user) is not in sudo group${NC}"
    echo -e "  Fix: sudo usermod -aG sudo $current_user"
fi

echo -e "\n${BLUE}=== VERIFICATION COMPLETE ===${NC}"
echo -e "${YELLOW}Fix any issues marked with a red ✗ before evaluation${NC}"
