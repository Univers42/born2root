#!/bin/bash

# SSH Configuration Script for Born2beRoot
# Author: LESdylan
# Date: 2025-04-01

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
echo -e "${BOLD}           SSH CONFIGURATION UTILITY         ${NC}"
echo -e "${BLUE}==============================================${NC}"
echo -e "${YELLOW}Current Date and Time (UTC): $(date -u +"%Y-%m-%d %H:%M:%S")${NC}"
echo -e "${YELLOW}Current User: $(whoami)${NC}"
echo ""

# Function to check if a package is installed
check_package() {
    if ! dpkg -l | grep -q "^ii  $1"; then
        return 1
    else
        return 0
    fi
}

# Function to install SSH server if not already installed
install_ssh() {
    echo -e "\n${BLUE}=== Checking SSH Server Installation ===${NC}"

    if check_package "openssh-server"; then
        echo -e "${GREEN}✓ OpenSSH Server is already installed${NC}"
    else
        echo -e "${YELLOW}! OpenSSH Server is not installed. Installing...${NC}"
        apt update
        apt install -y openssh-server
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ OpenSSH Server installed successfully${NC}"
        else
            echo -e "${RED}✗ Failed to install OpenSSH Server${NC}"
            return 1
        fi
    fi

    # Check if SSH service is running
    if systemctl is-active --quiet ssh; then
        echo -e "${GREEN}✓ SSH service is running${NC}"
    else
        echo -e "${YELLOW}! SSH service is not running. Starting...${NC}"
        systemctl start ssh
        systemctl enable ssh
        echo -e "${GREEN}✓ SSH service started and enabled${NC}"
    fi

    return 0
}

# Function to change SSH port
change_port() {
    echo -e "\n${BLUE}=== Change SSH Port ===${NC}"

    # Get current port
    current_port=$(grep "^Port " /etc/ssh/sshd_config | awk '{print $2}')
    if [ -z "$current_port" ]; then
        current_port="22 (default)"
    fi

    echo -e "${YELLOW}Current SSH port: ${current_port}${NC}"
    read -p "Enter new SSH port (1024-65535, recommended: 4242): " new_port

    # Validate port number
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1024 ] || [ "$new_port" -gt 65535 ]; then
        echo -e "${RED}✗ Invalid port number. Please enter a number between 1024 and 65535${NC}"
        return 1
    fi

    # Check if port is already in use
    if ss -tuln | grep ":$new_port " >/dev/null; then
        echo -e "${RED}✗ Port $new_port is already in use by another service${NC}"
        return 1
    fi

    # Backup sshd_config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)

    # Update port in sshd_config
    sed -i "s/^#*Port .*/Port $new_port/" /etc/ssh/sshd_config
    if ! grep -q "^Port " /etc/ssh/sshd_config; then
        echo "Port $new_port" >>/etc/ssh/sshd_config
    fi

    echo -e "${GREEN}✓ SSH port changed to $new_port${NC}"
    echo -e "${YELLOW}! Remember to update firewall rules and port forwarding${NC}"

    # Update UFW rules if installed
    if command -v ufw >/dev/null; then
        echo -e "${YELLOW}! UFW detected. Updating firewall rules...${NC}"
        ufw allow $new_port/tcp
        if [ "$current_port" != "22 (default)" ]; then
            read -p "Do you want to remove the old port $current_port from firewall? (y/n): " remove_old
            if [[ "$remove_old" == "y" || "$remove_old" == "Y" ]]; then
                ufw delete allow $current_port/tcp
                echo -e "${GREEN}✓ Old port rule removed from firewall${NC}"
            fi
        fi
        echo -e "${GREEN}✓ Firewall rules updated${NC}"
    fi

    return 0
}

# Function to configure SSH key authentication
configure_key_auth() {
    echo -e "\n${BLUE}=== Configure SSH Key Authentication ===${NC}"

    # Check if key authentication is already enabled
    if grep -q "^PubkeyAuthentication yes" /etc/ssh/sshd_config; then
        echo -e "${GREEN}✓ SSH key authentication is already enabled${NC}"
    else
        # Backup sshd_config
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)

        # Update sshd_config to enable key auth
        sed -i "s/^#*PubkeyAuthentication .*/PubkeyAuthentication yes/" /etc/ssh/sshd_config
        if ! grep -q "^PubkeyAuthentication " /etc/ssh/sshd_config; then
            echo "PubkeyAuthentication yes" >>/etc/ssh/sshd_config
        fi

        echo -e "${GREEN}✓ SSH key authentication enabled${NC}"
    fi

    echo -e "\n${YELLOW}Do you want to:${NC}"
    echo "1. Generate a new SSH key pair"
    echo "2. Add an existing public key"
    echo "3. Skip key setup"
    read -p "Select an option [1-3]: " key_option

    case $key_option in
    1)
        # Generate new key pair
        echo -e "\n${BLUE}=== Generate New SSH Key Pair ===${NC}"
        read -p "Enter username to create key for: " key_user

        # Check if user exists
        if ! id "$key_user" &>/dev/null; then
            echo -e "${RED}✗ User $key_user does not exist${NC}"
            return 1
        fi

        # Get user's home directory
        user_home=$(eval echo ~$key_user)

        # Create .ssh directory if it doesn't exist
        if [ ! -d "$user_home/.ssh" ]; then
            mkdir -p "$user_home/.ssh"
            chmod 700 "$user_home/.ssh"
            chown $key_user:$key_user "$user_home/.ssh"
        fi

        # Generate key
        ssh_dir="$user_home/.ssh"
        key_file="$ssh_dir/id_rsa"

        # Check if key already exists
        if [ -f "$key_file" ]; then
            read -p "SSH key already exists. Overwrite? (y/n): " overwrite
            if [[ "$overwrite" != "y" && "$overwrite" != "Y" ]]; then
                echo -e "${YELLOW}! Key generation skipped${NC}"
                return 0
            fi
        fi

        # Generate key as the user
        echo -e "${YELLOW}! Generating SSH key pair...${NC}"
        sudo -u $key_user ssh-keygen -t rsa -b 4096 -f "$key_file" -N ""

        # Setup authorized_keys
        if [ -f "$key_file.pub" ]; then
            cat "$key_file.pub" >>"$ssh_dir/authorized_keys"
            chmod 600 "$ssh_dir/authorized_keys"
            chown $key_user:$key_user "$ssh_dir/authorized_keys"
            echo -e "${GREEN}✓ SSH key pair generated and added to authorized_keys${NC}"
            echo -e "${YELLOW}! Private key location: $key_file${NC}"
            echo -e "${YELLOW}! Public key location: $key_file.pub${NC}"
        else
            echo -e "${RED}✗ Failed to generate SSH key pair${NC}"
            return 1
        fi
        ;;

    2)
        # Add existing public key
        echo -e "\n${BLUE}=== Add Existing Public Key ===${NC}"
        read -p "Enter username to add key for: " key_user

        # Check if user exists
        if ! id "$key_user" &>/dev/null; then
            echo -e "${RED}✗ User $key_user does not exist${NC}"
            return 1
        fi

        # Get user's home directory
        user_home=$(eval echo ~$key_user)

        # Create .ssh directory if it doesn't exist
        if [ ! -d "$user_home/.ssh" ]; then
            mkdir -p "$user_home/.ssh"
            chmod 700 "$user_home/.ssh"
            chown $key_user:$key_user "$user_home/.ssh"
        fi

        # Setup authorized_keys file
        auth_keys="$user_home/.ssh/authorized_keys"

        echo -e "${YELLOW}! Paste the public key (ssh-rsa ...)${NC}"
        echo -e "${YELLOW}! Press Ctrl+D when finished${NC}"

        # Read public key
        pub_key=$(cat)

        # Validate public key format
        if ! echo "$pub_key" | grep -q "^ssh-rsa "; then
            echo -e "${RED}✗ Invalid public key format${NC}"
            return 1
        fi

        # Add to authorized_keys
        echo "$pub_key" >>"$auth_keys"
        chmod 600 "$auth_keys"
        chown $key_user:$key_user "$auth_keys"

        echo -e "${GREEN}✓ Public key added to $auth_keys${NC}"
        ;;

    3)
        echo -e "${YELLOW}! Key setup skipped${NC}"
        ;;

    *)
        echo -e "${RED}✗ Invalid option${NC}"
        return 1
        ;;
    esac

    return 0
}

# Function to disable password authentication
disable_password_auth() {
    echo -e "\n${BLUE}=== Configure Password Authentication ===${NC}"

    echo -e "${YELLOW}! WARNING: Disabling password authentication requires SSH key setup${NC}"
    echo -e "${YELLOW}! Make sure you have added SSH keys before proceeding${NC}"
    read -p "Do you want to disable password authentication? (y/n): " disable

    if [[ "$disable" == "y" || "$disable" == "Y" ]]; then
        # Backup sshd_config
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)

        # Update sshd_config to disable password auth
        sed -i "s/^#*PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
        if ! grep -q "^PasswordAuthentication " /etc/ssh/sshd_config; then
            echo "PasswordAuthentication no" >>/etc/ssh/sshd_config
        fi

        echo -e "${GREEN}✓ Password authentication disabled${NC}"
    else
        # Backup sshd_config
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)

        # Update sshd_config to enable password auth
        sed -i "s/^#*PasswordAuthentication .*/PasswordAuthentication yes/" /etc/ssh/sshd_config
        if ! grep -q "^PasswordAuthentication " /etc/ssh/sshd_config; then
            echo "PasswordAuthentication yes" >>/etc/ssh/sshd_config
        fi

        echo -e "${GREEN}✓ Password authentication enabled${NC}"
    fi

    return 0
}

# Function to disable root login
disable_root_login() {
    echo -e "\n${BLUE}=== Configure Root Login ===${NC}"

    echo -e "${YELLOW}! Current setting:${NC}"
    grep "^PermitRootLogin " /etc/ssh/sshd_config || echo "Using default (PermitRootLogin yes)"

    read -p "Do you want to disable root login? (y/n): " disable_root

    if [[ "$disable_root" == "y" || "$disable_root" == "Y" ]]; then
        # Backup sshd_config
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)

        # Update sshd_config to disable root login
        sed -i "s/^#*PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
        if ! grep -q "^PermitRootLogin " /etc/ssh/sshd_config; then
            echo "PermitRootLogin no" >>/etc/ssh/sshd_config
        fi

        echo -e "${GREEN}✓ Root login disabled${NC}"
    else
        # Backup sshd_config
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)

        # Update sshd_config to enable root login
        sed -i "s/^#*PermitRootLogin .*/PermitRootLogin yes/" /etc/ssh/sshd_config
        if ! grep -q "^PermitRootLogin " /etc/ssh/sshd_config; then
            echo "PermitRootLogin yes" >>/etc/ssh/sshd_config
        fi

        echo -e "${GREEN}✓ Root login enabled${NC}"
    fi

    return 0
}

# Function to configure login grace time
configure_login_grace() {
    echo -e "\n${BLUE}=== Configure Login Grace Time ===${NC}"

    # Get current setting
    current_time=$(grep "^LoginGraceTime " /etc/ssh/sshd_config | awk '{print $2}')
    if [ -z "$current_time" ]; then
        current_time="2m (default)"
    fi

    echo -e "${YELLOW}Current login grace time: ${current_time}${NC}"
    read -p "Enter new login grace time (e.g., 30s, 2m, recommended: 1m): " new_time

    # Validate time format
    if ! [[ "$new_time" =~ ^[0-9]+[smh]?$ ]]; then
        echo -e "${RED}✗ Invalid time format. Please use format like 30s, 2m, or 1h${NC}"
        return 1
    fi

    # Backup sshd_config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)

    # Update login grace time in sshd_config
    sed -i "s/^#*LoginGraceTime .*/LoginGraceTime $new_time/" /etc/ssh/sshd_config
    if ! grep -q "^LoginGraceTime " /etc/ssh/sshd_config; then
        echo "LoginGraceTime $new_time" >>/etc/ssh/sshd_config
    fi

    echo -e "${GREEN}✓ Login grace time set to $new_time${NC}"

    return 0
}

# Function to configure max authentication attempts
configure_max_auth() {
    echo -e "\n${BLUE}=== Configure Maximum Authentication Attempts ===${NC}"

    # Get current setting
    current_max=$(grep "^MaxAuthTries " /etc/ssh/sshd_config | awk '{print $2}')
    if [ -z "$current_max" ]; then
        current_max="6 (default)"
    fi

    echo -e "${YELLOW}Current maximum authentication attempts: ${current_max}${NC}"
    read -p "Enter new maximum attempts (recommended: 3): " new_max

    # Validate input
    if ! [[ "$new_max" =~ ^[0-9]+$ ]] || [ "$new_max" -lt 1 ]; then
        echo -e "${RED}✗ Invalid value. Please enter a positive number${NC}"
        return 1
    fi

    # Backup sshd_config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)

    # Update max auth tries in sshd_config
    sed -i "s/^#*MaxAuthTries .*/MaxAuthTries $new_max/" /etc/ssh/sshd_config
    if ! grep -q "^MaxAuthTries " /etc/ssh/sshd_config; then
        echo "MaxAuthTries $new_max" >>/etc/ssh/sshd_config
    fi

    echo -e "${GREEN}✓ Maximum authentication attempts set to $new_max${NC}"

    return 0
}

# Function to configure SSH protocol version
configure_protocol() {
    echo -e "\n${BLUE}=== Configure SSH Protocol Version ===${NC}"

    echo -e "${YELLOW}! Note: Modern SSH servers use Protocol 2 by default${NC}"
    echo -e "${YELLOW}! Protocol 1 is insecure and should not be used${NC}"

    # Check if Protocol is explicitly set in config
    if grep -q "^Protocol " /etc/ssh/sshd_config; then
        current_protocol=$(grep "^Protocol " /etc/ssh/sshd_config | awk '{print $2}')
        echo -e "${YELLOW}Current protocol version: ${current_protocol}${NC}"

        if [ "$current_protocol" != "2" ]; then
            # Backup sshd_config
            cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)

            # Force Protocol 2
            sed -i "s/^Protocol .*/Protocol 2/" /etc/ssh/sshd_config
            echo -e "${GREEN}✓ Protocol version set to 2${NC}"
        else
            echo -e "${GREEN}✓ Protocol version is already set to 2${NC}"
        fi
    else
        echo -e "${GREEN}✓ Protocol version not explicitly set (defaults to 2 in modern SSH)${NC}"
        read -p "Do you want to explicitly set Protocol 2? (y/n): " set_protocol

        if [[ "$set_protocol" == "y" || "$set_protocol" == "Y" ]]; then
            # Backup sshd_config
            cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)

            # Add Protocol 2
            echo "Protocol 2" >>/etc/ssh/sshd_config
            echo -e "${GREEN}✓ Protocol 2 explicitly set in configuration${NC}"
        fi
    fi

    return 0
}

# Function to configure idle timeout
configure_idle_timeout() {
    echo -e "\n${BLUE}=== Configure SSH Idle Timeout ===${NC}"

    # Get current settings
    client_alive_interval=$(grep "^ClientAliveInterval " /etc/ssh/sshd_config | awk '{print $2}')
    if [ -z "$client_alive_interval" ]; then
        client_alive_interval="0 (default)"
    fi

    client_alive_count_max=$(grep "^ClientAliveCountMax " /etc/ssh/sshd_config | awk '{print $2}')
    if [ -z "$client_alive_count_max" ]; then
        client_alive_count_max="3 (default)"
    fi

    echo -e "${YELLOW}Current client alive interval: ${client_alive_interval} seconds${NC}"
    echo -e "${YELLOW}Current client alive count max: ${client_alive_count_max}${NC}"
    echo -e "${YELLOW}! Total timeout = interval × count${NC}"

    # Get new settings
    read -p "Enter new client alive interval in seconds (recommended: 300): " new_interval
    read -p "Enter new client alive count max (recommended: 2): " new_count

    # Validate inputs
    if ! [[ "$new_interval" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}✗ Invalid interval. Please enter a positive number${NC}"
        return 1
    fi

    if ! [[ "$new_count" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}✗ Invalid count. Please enter a positive number${NC}"
        return 1
    fi

    # Calculate total timeout
    total_timeout=$((new_interval * new_count))
    echo -e "${YELLOW}! Total idle timeout will be $total_timeout seconds ($((total_timeout / 60)) minutes)${NC}"

    # Backup sshd_config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)

    # Update client alive settings in sshd_config
    sed -i "s/^#*ClientAliveInterval .*/ClientAliveInterval $new_interval/" /etc/ssh/sshd_config
    if ! grep -q "^ClientAliveInterval " /etc/ssh/sshd_config; then
        echo "ClientAliveInterval $new_interval" >>/etc/ssh/sshd_config
    fi

    sed -i "s/^#*ClientAliveCountMax .*/ClientAliveCountMax $new_count/" /etc/ssh/sshd_config
    if ! grep -q "^ClientAliveCountMax " /etc/ssh/sshd_config; then
        echo "ClientAliveCountMax $new_count" >>/etc/ssh/sshd_config
    fi

    echo -e "${GREEN}✓ Idle timeout settings updated${NC}"

    return 0
}

# Function to set up port forwarding on VirtualBox VM
setup_port_forwarding() {
    echo -e "\n${BLUE}=== Setup Port Forwarding for VM ===${NC}"

    echo -e "${YELLOW}! Note: This applies to VirtualBox VMs and assumes VBoxManage is available on the host${NC}"
    echo -e "${YELLOW}! If you're running directly on hardware, you can skip this${NC}"
    read -p "Do you want to display port forwarding setup instructions? (y/n): " show_instructions

    if [[ "$show_instructions" == "y" || "$show_instructions" == "Y" ]]; then
        # Get SSH port from config
        ssh_port=$(grep "^Port " /etc/ssh/sshd_config | awk '{print $2}')
        if [ -z "$ssh_port" ]; then
            ssh_port="22"
        fi

        echo -e "\n${YELLOW}=== VirtualBox Port Forwarding Setup Instructions ===${NC}"
        echo -e "${YELLOW}These commands should be run on your host machine, not the VM:${NC}"
        echo ""
        echo -e "${BLUE}1. Stop the VM if it's running${NC}"
        echo "VBoxManage controlvm \"YourVMName\" poweroff"
        echo ""
        echo -e "${BLUE}2. Add port forwarding rule${NC}"
        echo "VBoxManage modifyvm \"YourVMName\" --natpf1 \"ssh,tcp,127.0.0.1,2222,,${ssh_port}\""
        echo ""
        echo -e "${BLUE}3. Start the VM${NC}"
        echo "VBoxManage startvm \"YourVMName\" --type headless"
        echo ""
        echo -e "${BLUE}4. Connect using SSH from host${NC}"
        echo "ssh -p 2222 username@127.0.0.1"
        echo ""
        echo -e "${YELLOW}Replace 'YourVMName' with your VM's name and 'username' with your username${NC}"
        echo -e "${YELLOW}The above setup forwards host port 2222 to VM port ${ssh_port}${NC}"
    fi

    return 0
}

# Function to restart SSH service
restart_ssh() {
    echo -e "\n${BLUE}=== Restart SSH Service ===${NC}"

    echo -e "${YELLOW}! Applying all changes by restarting SSH service...${NC}"

    # Check config syntax
    echo -e "${YELLOW}! Checking configuration syntax...${NC}"
    if ! sshd -t; then
        echo -e "${RED}✗ SSH configuration has errors! Please fix before restarting${NC}"
        return 1
    fi

    # Restart service
    if systemctl restart ssh; then
        echo -e "${GREEN}✓ SSH service restarted successfully${NC}"
    else
        echo -e "${RED}✗ Failed to restart SSH service${NC}"
        return 1
    fi

    return 0
}

# Function to show firewall status and rules
show_firewall_status() {
    echo -e "\n${BLUE}=== Firewall Status ===${NC}"

    # Check if UFW is installed
    if command -v ufw >/dev/null; then
        echo -e "${GREEN}✓ UFW (Uncomplicated Firewall) is installed${NC}"

        # Check status
        echo -e "\n${YELLOW}UFW Status:${NC}"
        ufw status verbose

        # Get SSH port from config
        ssh_port=$(grep "^Port " /etc/ssh/sshd_config | awk '{print $2}')
        if [ -z "$ssh_port" ]; then
            ssh_port="22"
        fi

        # Check if SSH port is allowed
        if ufw status | grep -q "$ssh_port/tcp"; then
            echo -e "\n${GREEN}✓ SSH port $ssh_port is allowed through firewall${NC}"
        else
            echo -e "\n${RED}✗ SSH port $ssh_port is not explicitly allowed through firewall${NC}"
            read -p "Do you want to allow SSH port $ssh_port through firewall? (y/n): " allow_ssh
            if [[ "$allow_ssh" == "y" || "$allow_ssh" == "Y" ]]; then
                ufw allow $ssh_port/tcp
                echo -e "${GREEN}✓ SSH port $ssh_port allowed through firewall${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}! UFW is not installed${NC}"
        read -p "Do you want to install UFW? (y/n): " install_ufw
        if [[ "$install_ufw" == "y" || "$install_ufw" == "Y" ]]; then
            apt update
            apt install -y ufw
            ufw default deny incoming
            ufw default allow outgoing

            # Get SSH port from config
            ssh_port=$(grep "^Port " /etc/ssh/sshd_config | awk '{print $2}')
            if [ -z "$ssh_port" ]; then
                ssh_port="22"
            fi

            ufw allow $ssh_port/tcp
            ufw enable
            echo -e "${GREEN}✓ UFW installed and configured to allow SSH${NC}"
        fi
    fi

    return 0
}

# Main menu
while true; do
    clear
    echo -e "${BLUE}==============================================${NC}"
    echo -e "${BOLD}           SSH CONFIGURATION UTILITY         ${NC}"
    echo -e "${BLUE}==============================================${NC}"
    echo -e "${YELLOW}Current Date and Time (UTC): $(date -u +"%Y-%m-%d %H:%M:%S")${NC}"
    echo -e "${YELLOW}Current User: $(whoami)${NC}"
    echo ""

    echo "1. Install/Check SSH Server"
    echo "2. Change SSH Port"
    echo "3. Configure SSH Key Authentication"
    echo "4. Configure Password Authentication"
    echo "5. Configure Root Login"
    echo "6. Configure Login Grace Time"
    echo "7. Configure Maximum Authentication Attempts"
    echo "8. Configure Protocol Version"
    echo "9. Configure Idle Timeout"
    echo "10. Show Firewall Status & Rules"
    echo "11. Setup Port Forwarding on VM"
    echo "12. Restart SSH Service"
    echo "13. Exit"
    echo ""

    read -p "Select an option [1-13]: " option

    case $option in
    1) install_ssh ;;
    2) change_port ;;
    3) configure_key_auth ;;
    4) disable_password_auth ;;
    5) disable_root_login ;;
    6) configure_login_grace ;;
    7) configure_max_auth ;;
    8) configure_protocol ;;
    9) configure_idle_timeout ;;
    10) show_firewall_status ;;
    11) setup_port_forwarding ;;
    12) restart_ssh ;;
    13)
        echo -e "${GREEN}Exiting SSH Configuration Utility${NC}"
        exit 0
        ;;
    *)
        echo -e "${RED}Invalid option. Please try again.${NC}"
        read -p "Press Enter to continue..."
        ;;
    esac

    read -p "Press Enter to return to the main menu..."
done
