#!/bin/bash

# Colors for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}This script must be run as root${NC}"
    exit 1
fi

# Clear the screen
clear

# Display header
echo -e "${BLUE}==============================================${NC}"
echo -e "${BOLD}        BORN2BEROOT SETUP UTILITY           ${NC}"
echo -e "${BLUE}==============================================${NC}"
echo -e "${YELLOW}Current Date and Time (UTC): $(date -u +"%Y-%m-%d %H:%M:%S")${NC}"
echo -e "${YELLOW}Current User: $(whoami)${NC}"
echo ""

# Function to configure hostname
configure_hostname() {
    echo -e "\n${BLUE}=== Hostname Configuration ===${NC}"

    # Get current hostname
    current_hostname=$(hostname)
    echo -e "${YELLOW}Current hostname: $current_hostname${NC}"

    # Ask for login
    read -p "Enter your 42 login (without 42 suffix): " login

    if [ -z "$login" ]; then
        echo -e "${RED}✗ Login cannot be empty${NC}"
        return 1
    fi

    # Create new hostname
    new_hostname="${login}42"
    echo -e "${YELLOW}New hostname will be: $new_hostname${NC}"

    # Update hostname
    echo $new_hostname >/etc/hostname

    # Update /etc/hosts
    sed -i "s/127.0.1.1.*$/127.0.1.1\t$new_hostname/" /etc/hosts

    echo -e "${GREEN}✓ Hostname updated to $new_hostname${NC}"
    echo -e "${YELLOW}! Note: Changes will take effect after reboot${NC}"

    return 0
}

# Function to implement strong password policy
configure_password_policy() {
    echo -e "\n${BLUE}=== Password Policy Configuration ===${NC}"

    # Install required packages
    echo -e "${YELLOW}! Installing required packages...${NC}"
    apt update
    apt install -y libpam-pwquality

    # Backup files before modifications
    cp /etc/login.defs /etc/login.defs.bak
    cp /etc/pam.d/common-password /etc/pam.d/common-password.bak

    # Configure password expiration in /etc/login.defs
    echo -e "${YELLOW}! Configuring password expiration...${NC}"
    sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS 30/' /etc/login.defs
    sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS 2/' /etc/login.defs
    sed -i 's/^PASS_WARN_AGE.*/PASS_WARN_AGE 7/' /etc/login.defs

    # Configure password complexity with PAM
    echo -e "${YELLOW}! Configuring password complexity...${NC}"

    # Check if the line already contains pwquality settings
    if grep -q "pam_pwquality.so" /etc/pam.d/common-password; then
        # Replace existing pwquality line
        sed -i '/pam_pwquality.so/ c\password requisite pam_pwquality.so retry=3 minlen=10 ucredit=-1 lcredit=-1 dcredit=-1 maxrepeat=3 reject_username difok=7 enforce_for_root' /etc/pam.d/common-password
    else
        # Add new pwquality line after pam_unix.so
        sed -i '/pam_unix.so/ i password requisite pam_pwquality.so retry=3 minlen=10 ucredit=-1 lcredit=-1 dcredit=-1 maxrepeat=3 reject_username difok=7 enforce_for_root' /etc/pam.d/common-password
    fi

    echo -e "${GREEN}✓ Password policy has been configured with:${NC}"
    echo -e "  - Password expires every 30 days"
    echo -e "  - Minimum 2 days between password changes"
    echo -e "  - Warning 7 days before password expires"
    echo -e "  - Minimum 10 characters long"
    echo -e "  - Must contain at least one uppercase letter"
    echo -e "  - Must contain at least one lowercase letter"
    echo -e "  - Must contain at least one digit"
    echo -e "  - Cannot have more than 3 consecutive identical characters"
    echo -e "  - Cannot contain the username"
    echo -e "  - Must have at least 7 characters different from previous password"
    echo -e "  - These rules also apply to root"

    return 0
}

# Function to configure sudo with strict rules
configure_sudo() {
    echo -e "\n${BLUE}=== Sudo Configuration ===${NC}"

    # Install sudo if not already installed
    if ! command -v sudo &>/dev/null; then
        echo -e "${YELLOW}! Sudo not found. Installing...${NC}"
        apt update
        apt install -y sudo
    else
        echo -e "${GREEN}✓ Sudo is already installed${NC}"
    fi

    # Create sudoers.d directory if it doesn't exist
    mkdir -p /etc/sudoers.d

    # Backup sudoers file
    cp /etc/sudoers /etc/sudoers.bak

    # Create sudo config file
    echo -e "${YELLOW}! Creating sudo configuration...${NC}"
    cat >/etc/sudoers.d/sudo_config <<EOF
Defaults        passwd_tries=3
Defaults        badpass_message="Incorrect password! Born2beRoot project requires attention to detail."
Defaults        log_input
Defaults        log_output
Defaults        requiretty
Defaults        secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"
Defaults        logfile="/var/log/sudo/sudo.log"
EOF

    # Create log directory for sudo
    mkdir -p /var/log/sudo
    chmod 700 /var/log/sudo

    # Set permissions on sudo config
    chmod 440 /etc/sudoers.d/sudo_config

    echo -e "${GREEN}✓ Sudo has been configured with strict rules:${NC}"
    echo -e "  - 3 attempts for incorrect password"
    echo -e "  - Custom error message"
    echo -e "  - Input and output logging"
    echo -e "  - TTY required"
    echo -e "  - Restricted paths"
    echo -e "  - Log file at /var/log/sudo/sudo.log"

    return 0
}

# Function to create user and groups
configure_user() {
    echo -e "\n${BLUE}=== User and Group Configuration ===${NC}"

    # Ask for login
    read -p "Enter your 42 login: " login

    if [ -z "$login" ]; then
        echo -e "${RED}✗ Login cannot be empty${NC}"
        return 1
    fi

    # Check if user42 group exists, create if not
    if ! getent group user42 >/dev/null; then
        echo -e "${YELLOW}! Creating group user42...${NC}"
        groupadd user42
        echo -e "${GREEN}✓ Group user42 created${NC}"
    else
        echo -e "${GREEN}✓ Group user42 already exists${NC}"
    fi

    # Check if user exists
    if id "$login" &>/dev/null; then
        echo -e "${YELLOW}! User $login already exists${NC}"

        # Add user to groups if not already member
        if ! groups "$login" | grep -q "\buser42\b"; then
            usermod -aG user42 "$login"
            echo -e "${GREEN}✓ User $login added to group user42${NC}"
        else
            echo -e "${GREEN}✓ User $login is already in group user42${NC}"
        fi

        if ! groups "$login" | grep -q "\bsudo\b"; then
            usermod -aG sudo "$login"
            echo -e "${GREEN}✓ User $login added to group sudo${NC}"
        else
            echo -e "${GREEN}✓ User $login is already in group sudo${NC}"
        fi
    else
        # Create new user
        echo -e "${YELLOW}! Creating user $login...${NC}"
        useradd -m -s /bin/bash -c "Born2beRoot User" "$login"

        # Set password for new user
        echo -e "${YELLOW}! Setting password for $login...${NC}"
        passwd "$login"

        # Add user to groups
        usermod -aG user42 "$login"
        usermod -aG sudo "$login"

        echo -e "${GREEN}✓ User $login created and added to groups user42 and sudo${NC}"
    fi

    return 0
}

# Function to install and configure SSH
configure_ssh() {
    echo -e "\n${BLUE}=== SSH Configuration ===${NC}"

    # Install OpenSSH if not already installed
    if ! command -v sshd &>/dev/null; then
        echo -e "${YELLOW}! OpenSSH server not found. Installing...${NC}"
        apt update
        apt install -y openssh-server
    else
        echo -e "${GREEN}✓ OpenSSH server is already installed${NC}"
    fi

    # Backup sshd_config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

    # Configure SSH
    echo -e "${YELLOW}! Configuring SSH...${NC}"
    sed -i 's/^#\?Port .*/Port 4242/' /etc/ssh/sshd_config
    sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config

    # Restart SSH service
    systemctl restart ssh

    echo -e "${GREEN}✓ SSH has been configured:${NC}"
    echo -e "  - SSH port set to 4242"
    echo -e "  - Root login disabled"
    echo -e "${YELLOW}! Remember to allow port 4242 in your firewall${NC}"

    return 0
}

# Function to configure UFW
configure_ufw() {
    echo -e "\n${BLUE}=== UFW Configuration ===${NC}"

    # Install UFW if not already installed
    if ! command -v ufw &>/dev/null; then
        echo -e "${YELLOW}! UFW not found. Installing...${NC}"
        apt update
        apt install -y ufw
    else
        echo -e "${GREEN}✓ UFW is already installed${NC}"
    fi

    # Configure UFW
    echo -e "${YELLOW}! Configuring UFW...${NC}"
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 4242/tcp

    # Enable UFW if not already enabled
    if ! ufw status | grep -q "Status: active"; then
        echo -e "${YELLOW}! Enabling UFW...${NC}"
        echo "y" | ufw enable
    else
        echo -e "${GREEN}✓ UFW is already enabled${NC}"
    fi

    echo -e "${GREEN}✓ UFW has been configured:${NC}"
    echo -e "  - Default: deny incoming, allow outgoing"
    echo -e "  - Port 4242/tcp allowed"

    return 0
}

# Main menu
while true; do
    clear
    echo -e "${BLUE}==============================================${NC}"
    echo -e "${BOLD}        BORN2BEROOT SETUP UTILITY           ${NC}"
    echo -e "${BLUE}==============================================${NC}"
    echo -e "${YELLOW}Current Date and Time (UTC): $(date -u +"%Y-%m-%d %H:%M:%S")${NC}"
    echo -e "${YELLOW}Current User: $(whoami)${NC}"
    echo ""

    echo "1. Configure Hostname (login42)"
    echo "2. Configure Password Policy"
    echo "3. Configure Sudo with Strict Rules"
    echo "4. Configure User and Groups"
    echo "5. Configure SSH (Port 4242)"
    echo "6. Configure UFW Firewall"
    echo "7. Run All Configurations"
    echo "8. Exit"
    echo ""

    read -p "Select an option [1-8]: " option

    case $option in
    1) configure_hostname ;;
    2) configure_password_policy ;;
    3) configure_sudo ;;
    4) configure_user ;;
    5) configure_ssh ;;
    6) configure_ufw ;;
    7)
        configure_hostname
        configure_password_policy
        configure_sudo
        configure_user
        configure_ssh
        configure_ufw
        echo -e "\n${GREEN}✓ All Born2beRoot configurations have been applied!${NC}"
        echo -e "${YELLOW}! Some changes may require a reboot to take effect.${NC}"
        read -p "Press Enter to continue..."
        ;;
    8)
        echo -e "${GREEN}Exiting Born2beRoot Setup Utility${NC}"
        exit 0
        ;;
    *)
        echo -e "${RED}Invalid option. Please try again.${NC}"
        read -p "Press Enter to continue..."
        ;;
    esac

    read -p "Press Enter to return to the main menu..."
done
