#!/bin/bash
# Born2beRoot Learning Laboratory
# Created: 2025-04-04 18:21:00
# Author: GitHub Copilot for LESdylan
# Purpose: Educational tool for learning Linux server administration concepts from Born2beRoot

# Colors for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# Backup directory
BACKUP_DIR="$HOME/.b2br_backups"
mkdir -p "$BACKUP_DIR"

# Check if script is run as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}This script must be run as root or with sudo privileges.${NC}"
        exit 1
    fi
}

# Function to create configuration backups
backup_config() {
    local component=$1
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_path="$BACKUP_DIR/${component}_${timestamp}"

    echo -e "${YELLOW}Creating backup of ${component} configuration...${NC}"
    mkdir -p "$backup_path"

    case $component in
    "ssh")
        cp -r /etc/ssh "$backup_path/"
        ;;
    "ufw")
        cp -r /etc/ufw "$backup_path/"
        cp /etc/default/ufw "$backup_path/"
        ufw status numbered >"$backup_path/ufw_status.txt"
        ;;
    "sudo")
        cp -r /etc/sudoers "$backup_path/"
        cp -r /etc/sudoers.d "$backup_path/"
        ;;
    "password-policy")
        cp /etc/pam.d/common-password "$backup_path/"
        cp /etc/login.defs "$backup_path/"
        ;;
    "hostname")
        cp /etc/hostname "$backup_path/"
        cp /etc/hosts "$backup_path/"
        ;;
    "user-groups")
        getent passwd >"$backup_path/passwd"
        getent group >"$backup_path/groups"
        getent shadow >"$backup_path/shadow"
        ;;
    *)
        echo -e "${RED}Unknown component: $component${NC}"
        return 1
        ;;
    esac

    echo -e "${GREEN}Backup created at: $backup_path${NC}"
    return 0
}

# Function to restore configuration backups
restore_config() {
    local component=$1

    echo -e "${BLUE}=== Configuration Restore Tool for $component ===${NC}"

    # List available backups for the component
    local backups=($(ls -1 "$BACKUP_DIR" | grep "^${component}_"))

    if [ ${#backups[@]} -eq 0 ]; then
        echo -e "${RED}No backups found for $component${NC}"
        return 1
    fi

    echo -e "${YELLOW}Available backups:${NC}"
    local i=1
    for backup in "${backups[@]}"; do
        local backup_date
        backup_date=$(echo "$backup" | sed "s/${component}_\([0-9]\{8\}_[0-9]\{6\}\).*/\1/")
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

    echo -e "${RED}WARNING: Restoring will overwrite current $component configuration!${NC}"
    read -p "Are you sure you want to proceed? (yes/no): " confirm

    if [[ "$confirm" != "yes" ]]; then
        echo -e "${YELLOW}Restore operation cancelled.${NC}"
        return 0
    fi

    # Perform the restore
    case $component in
    "ssh")
        systemctl stop sshd
        cp -r "$backup_path/ssh/"* /etc/ssh/
        systemctl start sshd
        ;;
    "ufw")
        cp -r "$backup_path/ufw/"* /etc/ufw/
        cp "$backup_path/ufw" /etc/default/
        ufw reload
        ;;
    "sudo")
        cp "$backup_path/sudoers" /etc/
        cp -r "$backup_path/sudoers.d/"* /etc/sudoers.d/
        ;;
    "password-policy")
        cp "$backup_path/common-password" /etc/pam.d/
        cp "$backup_path/login.defs" /etc/
        ;;
    "hostname")
        cp "$backup_path/hostname" /etc/
        cp "$backup_path/hosts" /etc/
        ;;
    "user-groups")
        echo -e "${RED}WARNING: Restoring users and groups can be dangerous.${NC}"
        echo -e "${YELLOW}Instead, view the backup and make changes manually:${NC}"
        echo -e "${CYAN}cat \"$backup_path/passwd\"${NC}"
        echo -e "${CYAN}cat \"$backup_path/groups\"${NC}"
        ;;
    *)
        echo -e "${RED}Unknown component: $component${NC}"
        return 1
        ;;
    esac

    echo -e "${GREEN}$component configuration restored successfully!${NC}"
    return 0
}

# SSH Configuration Learning Module
configure_ssh() {
    clear
    echo -e "${BLUE}==============================================${NC}"
    echo -e "${WHITE}         SSH SERVER CONFIGURATION            ${NC}"
    echo -e "${BLUE}==============================================${NC}"
    echo -e "${YELLOW}About:${NC} SSH (Secure Shell) allows secure remote access to your server."
    echo -e "${YELLOW}Born2beroot requirement:${NC} SSH service must run on port 4242 only."
    echo -e "${YELLOW}Security best practice:${NC} Disable root login and use key authentication."
    echo -e "\n${CYAN}Current SSH Status:${NC}"

    if systemctl is-active sshd >/dev/null 2>&1; then
        echo -e "${GREEN}● SSH service is running${NC}"
    else
        echo -e "${RED}● SSH service is not running${NC}"
    fi

    echo -e "\n${CYAN}Current SSH Configuration:${NC}"
    if [ -f /etc/ssh/sshd_config ]; then
        echo -e "SSH Port: $(grep -E "^Port " /etc/ssh/sshd_config | awk '{print $2}')"
        echo -e "Root Login: $(grep -E "^PermitRootLogin " /etc/ssh/sshd_config | awk '{print $2}')"
        echo -e "Password Authentication: $(grep -E "^PasswordAuthentication " /etc/ssh/sshd_config | awk '{print $2}')"
    else
        echo -e "${RED}SSH configuration file not found.${NC}"
    fi

    echo -e "\n${CYAN}Learning Options:${NC}"
    echo -e "${YELLOW}1.${NC} Change SSH Port to 4242 (Born2beroot requirement)"
    echo -e "${YELLOW}2.${NC} Disable root login (Security best practice)"
    echo -e "${YELLOW}3.${NC} Configure key-based authentication"
    echo -e "${YELLOW}4.${NC} Restart SSH service"
    echo -e "${YELLOW}5.${NC} Backup SSH configuration"
    echo -e "${YELLOW}6.${NC} Restore SSH configuration"
    echo -e "${YELLOW}7.${NC} Show SSH educational notes"
    echo -e "${YELLOW}8.${NC} Return to main menu"

    read -p "Select an option (1-8): " ssh_choice

    case $ssh_choice in
    1)
        echo -e "\n${CYAN}=== Changing SSH Port ===${NC}"
        echo -e "${YELLOW}This will change the SSH port to 4242.${NC}"
        echo -e "${PURPLE}Educational note: The default SSH port is 22. Changing it to a non-standard port${NC}"
        echo -e "${PURPLE}adds a layer of security through obscurity, making automated scanning harder.${NC}"

        backup_config "ssh"

        # Change the port
        if [ -f /etc/ssh/sshd_config ]; then
            # Check if Port is already set
            if grep -qE "^Port " /etc/ssh/sshd_config; then
                # Replace existing Port line
                sed -i 's/^Port .*/Port 4242/' /etc/ssh/sshd_config
            else
                # Add Port line if it doesn't exist or is commented
                sed -i 's/#Port 22/Port 4242/' /etc/ssh/sshd_config
                # If still not there, add it
                if ! grep -qE "^Port " /etc/ssh/sshd_config; then
                    echo "Port 4242" >>/etc/ssh/sshd_config
                fi
            fi

            echo -e "${GREEN}SSH port changed to 4242.${NC}"
            echo -e "${YELLOW}You need to restart the SSH service for changes to take effect.${NC}"
            echo -e "${PURPLE}Command to connect after change: ssh username@hostname -p 4242${NC}"
        else
            echo -e "${RED}SSH configuration file not found.${NC}"
        fi
        ;;

    2)
        echo -e "\n${CYAN}=== Disabling Root Login ===${NC}"
        echo -e "${YELLOW}This will disable direct root login via SSH.${NC}"
        echo -e "${PURPLE}Educational note: Disabling root login prevents attackers from targeting${NC}"
        echo -e "${PURPLE}the most privileged account. Instead, login as a regular user and use${NC}"
        echo -e "${PURPLE}sudo for administrative tasks, which provides better logging and control.${NC}"

        backup_config "ssh"

        # Disable root login
        if [ -f /etc/ssh/sshd_config ]; then
            # Check if PermitRootLogin is already set
            if grep -qE "^PermitRootLogin " /etc/ssh/sshd_config; then
                # Replace existing PermitRootLogin line
                sed -i 's/^PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
            else
                # Add PermitRootLogin line if it doesn't exist or is commented
                sed -i 's/#PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
                # If still not there, add it
                if ! grep -qE "^PermitRootLogin " /etc/ssh/sshd_config; then
                    echo "PermitRootLogin no" >>/etc/ssh/sshd_config
                fi
            fi

            echo -e "${GREEN}Root login via SSH disabled.${NC}"
            echo -e "${YELLOW}You need to restart the SSH service for changes to take effect.${NC}"
        else
            echo -e "${RED}SSH configuration file not found.${NC}"
        fi
        ;;

    3)
        echo -e "\n${CYAN}=== Configure Key-based Authentication ===${NC}"
        echo -e "${YELLOW}This will walk you through setting up SSH key authentication.${NC}"
        echo -e "${PURPLE}Educational note: Key-based authentication is more secure than passwords${NC}"
        echo -e "${PURPLE}as it uses cryptographic keys that cannot be brute-forced like passwords.${NC}"

        echo -e "\n${CYAN}Steps to set up key-based authentication:${NC}"
        echo -e "${WHITE}1. On your client machine (not this server), generate a key pair:${NC}"
        echo -e "   ${CYAN}ssh-keygen -t ed25519 -f ~/.ssh/b2br_key${NC}"
        echo -e ""
        echo -e "${WHITE}2. Copy the public key to this server:${NC}"
        echo -e "   ${CYAN}ssh-copy-id -i ~/.ssh/b2br_key.pub user@host -p <port>${NC}"
        echo -e ""
        echo -e "${WHITE}3. Once you've confirmed key login works, you can disable password auth:${NC}"

        read -p "Do you want to disable password authentication? (yes/no): " disable_pass

        if [[ "$disable_pass" == "yes" ]]; then
            backup_config "ssh"

            # Disable password authentication
            if [ -f /etc/ssh/sshd_config ]; then
                # Check if PasswordAuthentication is already set
                if grep -qE "^PasswordAuthentication " /etc/ssh/sshd_config; then
                    # Replace existing PasswordAuthentication line
                    sed -i 's/^PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
                else
                    # Add PasswordAuthentication line if it doesn't exist or is commented
                    sed -i 's/#PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
                    # If still not there, add it
                    if ! grep -qE "^PasswordAuthentication " /etc/ssh/sshd_config; then
                        echo "PasswordAuthentication no" >>/etc/ssh/sshd_config
                    fi
                fi

                echo -e "${GREEN}Password authentication disabled.${NC}"
                echo -e "${YELLOW}You need to restart the SSH service for changes to take effect.${NC}"
                echo -e "${RED}WARNING: Ensure your key authentication is working before disconnecting!${NC}"
            else
                echo -e "${RED}SSH configuration file not found.${NC}"
            fi
        else
            echo -e "${YELLOW}Password authentication not changed.${NC}"
        fi
        ;;

    4)
        echo -e "\n${CYAN}=== Restarting SSH Service ===${NC}"
        echo -e "${YELLOW}This will restart the SSH service to apply configuration changes.${NC}"
        echo -e "${PURPLE}Educational note: Most configuration changes in Linux services require${NC}"
        echo -e "${PURPLE}restarting or reloading the service to take effect.${NC}"

        read -p "Are you sure you want to restart the SSH service? (yes/no): " restart_ssh

        if [[ "$restart_ssh" == "yes" ]]; then
            systemctl restart sshd
            echo -e "${GREEN}SSH service restarted successfully.${NC}"
        else
            echo -e "${YELLOW}SSH service restart cancelled.${NC}"
        fi
        ;;

    5)
        echo -e "\n${CYAN}=== Backup SSH Configuration ===${NC}"
        backup_config "ssh"
        ;;

    6)
        echo -e "\n${CYAN}=== Restore SSH Configuration ===${NC}"
        restore_config "ssh"
        ;;

    7)
        echo -e "\n${CYAN}=== SSH Educational Notes ===${NC}"
        echo -e "${WHITE}What is SSH?${NC}"
        echo -e "${PURPLE}SSH (Secure Shell) is a cryptographic network protocol for operating network services${NC}"
        echo -e "${PURPLE}securely over an unsecured network. It provides a secure channel over an unsecured${NC}"
        echo -e "${PURPLE}network by using strong encryption.${NC}"
        echo -e ""
        echo -e "${WHITE}Key SSH Security Practices:${NC}"
        echo -e "${PURPLE}1. Use a non-standard port (e.g., 4242 instead of 22)${NC}"
        echo -e "${PURPLE}2. Disable root login - prevents direct access to the most powerful account${NC}"
        echo -e "${PURPLE}3. Use key-based authentication instead of passwords${NC}"
        echo -e "${PURPLE}4. Limit users who can access via SSH using AllowUsers directive${NC}"
        echo -e "${PURPLE}5. Implement fail2ban to protect against brute force attacks${NC}"
        echo -e ""
        echo -e "${WHITE}Important SSH Configuration Files:${NC}"
        echo -e "${PURPLE}/etc/ssh/sshd_config - Server configuration${NC}"
        echo -e "${PURPLE}/etc/ssh/ssh_config - Client configuration${NC}"
        echo -e "${PURPLE}~/.ssh/authorized_keys - Contains public keys that can access your account${NC}"
        echo -e ""
        echo -e "${WHITE}Common SSH Commands:${NC}"
        echo -e "${PURPLE}ssh user@hostname -p port - Connect to a remote server${NC}"
        echo -e "${PURPLE}scp -P port file user@hostname:/path - Copy file to remote server${NC}"
        echo -e "${PURPLE}ssh-keygen - Generate new SSH key pair${NC}"
        echo -e "${PURPLE}ssh-copy-id -i key.pub user@hostname - Copy public key to server${NC}"
        echo -e ""
        read -p "Press Enter to continue..."
        ;;

    8)
        return
        ;;

    *)
        echo -e "${RED}Invalid option. Please try again.${NC}"
        ;;
    esac

    read -p "Press Enter to continue..."
    configure_ssh
}

# UFW Firewall Configuration Learning Module
configure_ufw() {
    clear
    echo -e "${BLUE}==============================================${NC}"
    echo -e "${WHITE}         UFW FIREWALL CONFIGURATION          ${NC}"
    echo -e "${BLUE}==============================================${NC}"
    echo -e "${YELLOW}About:${NC} UFW (Uncomplicated Firewall) provides a user-friendly way to manage iptables."
    echo -e "${YELLOW}Born2beroot requirement:${NC} Only port 4242 should be open."
    echo -e "${YELLOW}Security best practice:${NC} Block all incoming connections except what's needed."
    echo -e "\n${CYAN}Current UFW Status:${NC}"

    if command -v ufw >/dev/null 2>&1; then
        if ufw status | grep -q "Status: active"; then
            echo -e "${GREEN}● UFW firewall is active${NC}"
        else
            echo -e "${RED}● UFW firewall is inactive${NC}"
        fi

        echo -e "\n${CYAN}Current UFW Rules:${NC}"
        ufw status
    else
        echo -e "${RED}UFW is not installed. Installing it is recommended for Born2beroot.${NC}"
    fi

    echo -e "\n${CYAN}Learning Options:${NC}"
    echo -e "${YELLOW}1.${NC} Install UFW (if not installed)"
    echo -e "${YELLOW}2.${NC} Enable UFW"
    echo -e "${YELLOW}3.${NC} Configure Born2beroot firewall rules (SSH on port 4242 only)"
    echo -e "${YELLOW}4.${NC} Add a custom rule"
    echo -e "${YELLOW}5.${NC} Delete a rule"
    echo -e "${YELLOW}6.${NC} Backup UFW configuration"
    echo -e "${YELLOW}7.${NC} Restore UFW configuration"
    echo -e "${YELLOW}8.${NC} Show UFW educational notes"
    echo -e "${YELLOW}9.${NC} Return to main menu"

    read -p "Select an option (1-9): " ufw_choice

    case $ufw_choice in
    1)
        echo -e "\n${CYAN}=== Installing UFW ===${NC}"
        echo -e "${YELLOW}This will install the UFW firewall package.${NC}"
        echo -e "${PURPLE}Educational note: UFW (Uncomplicated Firewall) is a frontend for iptables,${NC}"
        echo -e "${PURPLE}making it easier to configure a firewall without the complexity of direct${NC}"
        echo -e "${PURPLE}iptables commands. It's ideal for basic firewall needs.${NC}"

        read -p "Proceed with UFW installation? (yes/no): " install_ufw

        if [[ "$install_ufw" == "yes" ]]; then
            if command -v apt-get >/dev/null 2>&1; then
                apt-get update
                apt-get install -y ufw
            elif command -v dnf >/dev/null 2>&1; then
                dnf install -y ufw
            elif command -v yum >/dev/null 2>&1; then
                yum install -y ufw
            else
                echo -e "${RED}Package manager not found. Please install UFW manually.${NC}"
                read -p "Press Enter to continue..."
                configure_ufw
                return
            fi

            echo -e "${GREEN}UFW installed successfully.${NC}"
        else
            echo -e "${YELLOW}UFW installation cancelled.${NC}"
        fi
        ;;

    2)
        echo -e "\n${CYAN}=== Enabling UFW ===${NC}"
        echo -e "${YELLOW}This will enable the UFW firewall.${NC}"
        echo -e "${PURPLE}Educational note: Enabling UFW will activate the firewall and apply all${NC}"
        echo -e "${PURPLE}configured rules. By default, UFW blocks all incoming connections and allows${NC}"
        echo -e "${PURPLE}all outgoing connections for safety.${NC}"

        if ! command -v ufw >/dev/null 2>&1; then
            echo -e "${RED}UFW is not installed. Please install it first.${NC}"
            read -p "Press Enter to continue..."
            configure_ufw
            return
        fi

        # Check if we have any allow rules for SSH before enabling
        if ! ufw status | grep -qE "(SSH|4242)/tcp"; then
            echo -e "${RED}WARNING: No SSH rules detected. Enabling UFW might lock you out!${NC}"
            echo -e "${YELLOW}It's recommended to add an SSH rule first (Option 3 or 4).${NC}"
            read -p "Still proceed with enabling UFW? (yes/no): " force_enable
            if [[ "$force_enable" != "yes" ]]; then
                echo -e "${YELLOW}UFW enabling cancelled.${NC}"
                read -p "Press Enter to continue..."
                configure_ufw
                return
            fi
        fi

        echo -e "${YELLOW}Enabling UFW with default policies:${NC}"
        echo -e "${YELLOW}- Block all incoming connections${NC}"
        echo -e "${YELLOW}- Allow all outgoing connections${NC}"
        read -p "Proceed? (yes/no): " enable_ufw

        if [[ "$enable_ufw" == "yes" ]]; then
            backup_config "ufw"

            # Set default policies and enable
            ufw default deny incoming
            ufw default allow outgoing
            echo "y" | ufw enable

            echo -e "${GREEN}UFW enabled successfully.${NC}"
        else
            echo -e "${YELLOW}UFW enabling cancelled.${NC}"
        fi
        ;;

    3)
        echo -e "\n${CYAN}=== Configure Born2beroot Firewall Rules ===${NC}"
        echo -e "${YELLOW}This will set up UFW according to Born2beroot requirements:${NC}"
        echo -e "${YELLOW}- Allow SSH on port 4242 only${NC}"
        echo -e "${YELLOW}- Block all other incoming connections${NC}"
        echo -e "${PURPLE}Educational note: This creates a minimal firewall configuration that only${NC}"
        echo -e "${PURPLE}allows the essential service (SSH) needed for remote administration.${NC}"

        if ! command -v ufw >/dev/null 2>&1; then
            echo -e "${RED}UFW is not installed. Please install it first.${NC}"
            read -p "Press Enter to continue..."
            configure_ufw
            return
        fi

        read -p "Apply Born2beroot firewall rules? (yes/no): " apply_rules

        if [[ "$apply_rules" == "yes" ]]; then
            backup_config "ufw"

            # Reset existing rules
            echo -e "${YELLOW}Resetting UFW rules...${NC}"
            ufw --force reset

            # Configure for Born2beroot
            ufw default deny incoming
            ufw default allow outgoing
            ufw allow 4242/tcp comment "SSH on port 4242"

            # Enable UFW if it's not enabled
            if ! ufw status | grep -q "Status: active"; then
                echo "y" | ufw enable
            fi

            echo -e "${GREEN}Born2beroot firewall rules applied successfully.${NC}"
            echo -e "${GREEN}Only port 4242 (SSH) is now open.${NC}"
        else
            echo -e "${YELLOW}Operation cancelled.${NC}"
        fi
        ;;

    4)
        echo -e "\n${CYAN}=== Add a Custom UFW Rule ===${NC}"
        echo -e "${YELLOW}This will allow you to add a custom firewall rule.${NC}"
        echo -e "${PURPLE}Educational note: Custom rules let you control access to specific services${NC}"
        echo -e "${PURPLE}on your server. Each rule specifies a port, protocol, and action (allow/deny).${NC}"

        if ! command -v ufw >/dev/null 2>&1; then
            echo -e "${RED}UFW is not installed. Please install it first.${NC}"
            read -p "Press Enter to continue..."
            configure_ufw
            return
        fi

        echo -e "\n${CYAN}Common service ports:${NC}"
        echo -e "${WHITE}SSH:${NC} 22/tcp (standard) or 4242/tcp (Born2beroot)"
        echo -e "${WHITE}HTTP:${NC} 80/tcp"
        echo -e "${WHITE}HTTPS:${NC} 443/tcp"
        echo -e "${WHITE}FTP:${NC} 21/tcp"
        echo -e "${WHITE}MySQL/MariaDB:${NC} 3306/tcp"

        read -p "Enter port number: " port
        read -p "Enter protocol (tcp/udp): " protocol
        read -p "Enter rule comment (optional): " comment

        if [[ -z "$port" || -z "$protocol" ]]; then
            echo -e "${RED}Port and protocol are required.${NC}"
            read -p "Press Enter to continue..."
            configure_ufw
            return
        fi

        backup_config "ufw"

        if [[ -z "$comment" ]]; then
            ufw allow $port/$protocol
        else
            ufw allow $port/$protocol comment "$comment"
        fi

        echo -e "${GREEN}Rule added: Allow $port/$protocol${NC}"
        ;;

    5)
        echo -e "\n${CYAN}=== Delete a UFW Rule ===${NC}"
        echo -e "${YELLOW}This will show you numbered rules and allow you to delete one.${NC}"
        echo -e "${PURPLE}Educational note: It's often easier to delete rules by number than by${NC}"
        echo -e "${PURPLE}trying to match the exact rule specification.${NC}"

        if ! command -v ufw >/dev/null 2>&1; then
            echo -e "${RED}UFW is not installed. Please install it first.${NC}"
            read -p "Press Enter to continue..."
            configure_ufw
            return
        fi

        echo -e "\n${CYAN}Current numbered rules:${NC}"
        ufw status numbered

        read -p "Enter rule number to delete (or c to cancel): " rule_num

        if [[ "$rule_num" == "c" || "$rule_num" == "C" ]]; then
            echo -e "${YELLOW}Operation cancelled.${NC}"
        else
            if [[ "$rule_num" =~ ^[0-9]+$ ]]; then
                backup_config "ufw"
                echo "y" | ufw delete $rule_num
                echo -e "${GREEN}Rule $rule_num deleted.${NC}"
            else
                echo -e "${RED}Invalid rule number.${NC}"
            fi
        fi
        ;;

    6)
        echo -e "\n${CYAN}=== Backup UFW Configuration ===${NC}"
        backup_config "ufw"
        ;;

    7)
        echo -e "\n${CYAN}=== Restore UFW Configuration ===${NC}"
        restore_config "ufw"
        ;;

    8)
        echo -e "\n${CYAN}=== UFW Educational Notes ===${NC}"
        echo -e "${WHITE}What is UFW?${NC}"
        echo -e "${PURPLE}UFW (Uncomplicated Firewall) is a simplified firewall management interface${NC}"
        echo -e "${PURPLE}that hides the complexity of lower-level packet filtering technologies${NC}"
        echo -e "${PURPLE}such as iptables and nftables. It's designed to be easy to use for beginners.${NC}"
        echo -e ""
        echo -e "${WHITE}Key UFW Concepts:${NC}"
        echo -e "${PURPLE}1. Default Policies - Set the default action for incoming/outgoing traffic${NC}"
        echo -e "${PURPLE}2. Rules - Specific instructions for handling particular types of traffic${NC}"
        echo -e "${PURPLE}3. Services vs. Ports - You can specify services by name or port number${NC}"
        echo -e ""
        echo -e "${WHITE}Common UFW Commands:${NC}"
        echo -e "${PURPLE}ufw status - Show current status and rules${NC}"
        echo -e "${PURPLE}ufw allow <port>/<protocol> - Allow traffic on specific port/protocol${NC}"
        echo -e "${PURPLE}ufw deny <port>/<protocol> - Block traffic on specific port/protocol${NC}"
        echo -e "${PURPLE}ufw delete <rule> - Remove a rule${NC}"
        echo -e "${PURPLE}ufw enable/disable - Turn the firewall on/off${NC}"
        echo -e "${PURPLE}ufw reset - Reset to default configuration${NC}"
        echo -e ""
        echo -e "${WHITE}Born2beroot Firewall Best Practices:${NC}"
        echo -e "${PURPLE}1. Block all incoming by default (ufw default deny incoming)${NC}"
        echo -e "${PURPLE}2. Allow all outgoing by default (ufw default allow outgoing)${NC}"
        echo -e "${PURPLE}3. Only open ports that are absolutely necessary (SSH on 4242)${NC}"
        echo -e "${PURPLE}4. Use specific IPs when possible (ufw allow from 192.168.1.100 to any port 4242)${NC}"
        echo -e ""
        read -p "Press Enter to continue..."
        ;;

    9)
        return
        ;;

    *)
        echo -e "${RED}Invalid option. Please try again.${NC}"
        ;;
    esac

    read -p "Press Enter to continue..."
    configure_ufw
}

# Sudo Configuration Learning Module
configure_sudo() {
    clear
    echo -e "${BLUE}==============================================${NC}"
    echo -e "${WHITE}         SUDO CONFIGURATION                  ${NC}"
    echo -e "${BLUE}==============================================${NC}"
    echo -e "${YELLOW}About:${NC} Sudo allows regular users to execute commands with superuser privileges."
    echo -e "${YELLOW}Born2beroot requirement:${NC} Configure strict sudo policies."
    echo -e "${YELLOW}Security best practice:${NC} Limit sudo access and implement logging."
    echo -e "\n${CYAN}Current Sudo Status:${NC}"

    if command -v sudo >/dev/null 2>&1; then
        echo -e "${GREEN}● Sudo is installed${NC}"

        # Check sudo version
        sudo_version=$(sudo --version | head -n1)
        echo -e "Version: $sudo_version"

        # Check if password is required
        if sudo -l | grep -q "NOPASSWD"; then
            echo -e "${RED}WARNING: Some commands can be executed without password${NC}"
        else
            echo -e "${GREEN}Password is required for sudo${NC}"
        fi

        # Check sudo log settings
        if grep -q "Defaults.*logfile" /etc/sudoers 2>/dev/null; then
            logfile=$(grep "Defaults.*logfile" /etc/sudoers | sed 's/.*logfile="\([^"]*\)".*/\1/')
            echo -e "Sudo logs to: $logfile"
        else
            echo -e "${YELLOW}No custom sudo log file configured${NC}"
        fi
    else
        echo -e "${RED}Sudo is not installed. Installing it is required for Born2beroot.${NC}"
    fi

    echo -e "\n${CYAN}Learning Options:${NC}"
    echo -e "${YELLOW}1.${NC} Install sudo (if not installed)"
    echo -e "${YELLOW}2.${NC} Configure Born2beroot sudo policies"
    echo -e "${YELLOW}3.${NC} Add user to sudo group"
    echo -e "${YELLOW}4.${NC} View sudo logs"
    echo -e "${YELLOW}5.${NC} Backup sudo configuration"
    echo -e "${YELLOW}6.${NC} Restore sudo configuration"
    echo -e "${YELLOW}7.${NC} Show sudo educational notes"
    echo -e "${YELLOW}8.${NC} Return to main menu"

    read -p "Select an option (1-8): " sudo_choice

    case $sudo_choice in
    1)
        echo -e "\n${CYAN}=== Installing Sudo ===${NC}"
        echo -e "${YELLOW}This will install the sudo package.${NC}"
        echo -e "${PURPLE}Educational note: sudo (superuser do) allows a user to execute${NC}"
        echo -e "${PURPLE}commands with the security privileges of another user, typically root.${NC}"

        read -p "Proceed with sudo installation? (yes/no): " install_sudo

        if [[ "$install_sudo" == "yes" ]]; then
            if command -v apt-get >/dev/null 2>&1; then
                apt-get update
                apt-get install -y sudo
            elif command -v dnf >/dev/null 2>&1; then
                dnf install -y sudo
            elif command -v yum >/dev/null 2>&1; then
                yum install -y sudo
            else
                echo -e "${RED}Package manager not found. Please install sudo manually.${NC}"
                read -p "Press Enter to continue..."
                configure_sudo
                return
            fi

            echo -e "${GREEN}Sudo installed successfully.${NC}"
        else
            echo -e "${YELLOW}Sudo installation cancelled.${NC}"
        fi
        ;;

    2)
        echo -e "\n${CYAN}=== Configure Born2beroot Sudo Policies ===${NC}"
        echo -e "${YELLOW}This will set up strict sudo policies according to Born2beroot requirements:${NC}"
        echo -e "${YELLOW}- Authentication required${NC}"
        echo -e "${YELLOW}- Limited attempts (3)${NC}"
        echo -e "${YELLOW}- Custom error message${NC}"
        echo -e "${YELLOW}- Session timeout (5 minutes)${NC}"
        echo -e "${YELLOW}- Command logging${NC}"
        echo -e "${PURPLE}Educational note: These policies enhance security by controlling how sudo${NC}"
        echo -e "${PURPLE}is used and creating a detailed audit trail of all privileged commands.${NC}"

        if ! command -v sudo >/dev/null 2>&1; then
            echo -e "${RED}Sudo is not installed. Please install it first.${NC}"
            read -p "Press Enter to continue..."
            configure_sudo
            return
        fi

        read -p "Apply Born2beroot sudo policies? (yes/no): " apply_policies

        if [[ "$apply_policies" == "yes" ]]; then
            backup_config "sudo"

            # Create a new sudoers file for Born2beroot policies
            cat >/etc/sudoers.d/born2beroot <<EOF
# Born2beroot sudo configuration
Defaults        passwd_tries=3
Defaults        badpass_message="Wrong password! Access denied. This incident will be reported."
Defaults        secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"
Defaults        logfile="/var/log/sudo/sudo.log"
Defaults        log_input,log_output
Defaults        requiretty
Defaults        timestamp_timeout=5
EOF

            # Create log directory if it doesn't exist
            mkdir -p /var/log/sudo
            chmod 700 /var/log/sudo

            echo -e "${GREEN}Born2beroot sudo policies applied successfully.${NC}"
            echo -e "${YELLOW}Check configuration with: cat /etc/sudoers.d/born2beroot${NC}"
        else
            echo -e "${YELLOW}Operation cancelled.${NC}"
        fi
        ;;

    3)
        echo -e "\n${CYAN}=== Add User to Sudo Group ===${NC}"
        echo -e "${YELLOW}This will grant a user sudo privileges by adding them to the sudo group.${NC}"
        echo -e "${PURPLE}Educational note: In most Linux distributions, members of the 'sudo' group${NC}"
        echo -e "${PURPLE}automatically have permission to use the sudo command.${NC}"

        if ! command -v sudo >/dev/null 2>&1; then
            echo -e "${RED}Sudo is not installed. Please install it first.${NC}"
            read -p "Press Enter to continue..."
            configure_sudo
            return
        fi

        read -p "Enter username to add to sudo group: " username

        if [[ -z "$username" ]]; then
            echo -e "${RED}Username cannot be empty.${NC}"
        else
            # Check if user exists
            if id "$username" >/dev/null 2>&1; then
                backup_config "user-groups"

                usermod -aG sudo "$username"
                echo -e "${GREEN}User $username added to sudo group successfully.${NC}"
                echo -e "${YELLOW}The user will need to log out and log back in for changes to take effect.${NC}"
            else
                echo -e "${RED}User $username does not exist.${NC}"
            fi
        fi
        ;;

    4)
        echo -e "\n${CYAN}=== View Sudo Logs ===${NC}"
        echo -e "${YELLOW}This will display recent sudo command logs.${NC}"
        echo -e "${PURPLE}Educational note: Sudo logs are crucial for security auditing and${NC}"
        echo -e "${PURPLE}tracking potential unauthorized privileged access attempts.${NC}"

        # Try to locate sudo logs
        log_file=""
        if [ -f "/var/log/sudo/sudo.log" ]; then
            log_file="/var/log/sudo/sudo.log"
        elif [ -f "/var/log/auth.log" ]; then
            log_file="/var/log/auth.log"
        fi

        if [ -n "$log_file" ]; then
            echo -e "${CYAN}Showing last 20 sudo log entries from $log_file:${NC}"
            if [ "$log_file" = "/var/log/sudo/sudo.log" ]; then
                tail -n 20 "$log_file"
            else
                grep "sudo" "$log_file" | tail -n 20
            fi
        else
            echo -e "${RED}Sudo log file not found.${NC}"
            echo -e "${YELLOW}Common locations: /var/log/sudo/sudo.log, /var/log/auth.log${NC}"
        fi
        ;;

    5)
        echo -e "\n${CYAN}=== Backup Sudo Configuration ===${NC}"
        backup_config "sudo"
        ;;

    6)
        echo -e "\n${CYAN}=== Restore Sudo Configuration ===${NC}"
        restore_config "sudo"
        ;;

    7)
        echo -e "\n${CYAN}=== Sudo Educational Notes ===${NC}"
        echo -e "${WHITE}What is sudo?${NC}"
        echo -e "${PURPLE}sudo (superuser do) is a program that allows users to run programs with the${NC}"
        echo -e "${PURPLE}security privileges of another user, by default the superuser (root).${NC}"
        echo -e "${PURPLE}It provides fine-grained control over who can execute what commands as which users.${NC}"
        echo -e ""
        echo -e "${WHITE}Key Sudo Concepts:${NC}"
        echo -e "${PURPLE}1. Principle of Least Privilege - Users should only have the minimum${NC}"
        echo -e "${PURPLE}   privileges necessary to perform their tasks${NC}"
        echo -e "${PURPLE}2. Accountability - Sudo logs all commands, creating an audit trail${NC}"
        echo -e "${PURPLE}3. Authentication - Sudo requires password verification before execution${NC}"
        echo -e ""
        echo -e "${WHITE}Important Sudo Files:${NC}"
        echo -e "${PURPLE}/etc/sudoers - Main configuration file for sudo policies${NC}"
        echo -e "${PURPLE}/etc/sudoers.d/ - Directory for additional sudo configuration files${NC}"
        echo -e "${PURPLE}/var/log/sudo/ - Default directory for sudo logs in many configurations${NC}"
        echo -e ""
        echo -e "${WHITE}Born2beroot Sudo Requirements:${NC}"
        echo -e "${PURPLE}1. Authentication limited to 3 attempts in the event of an incorrect password${NC}"
        echo -e "${PURPLE}2. Custom message in case of wrong password${NC}"
        echo -e "${PURPLE}3. Each sudo command's input and output must be archived${NC}"
        echo -e "${PURPLE}4. TTY mode must be enabled for security${NC}"
        echo -e "${PURPLE}5. Sudo paths must be restricted${NC}"
        echo -e ""
        echo -e "${WHITE}Common Sudo Commands and Options:${NC}"
        echo -e "${PURPLE}sudo command - Execute command as superuser${NC}"
        echo -e "${PURPLE}sudo -l - List available commands for the current user${NC}"
        echo -e "${PURPLE}sudo -u username command - Execute as specified user instead of root${NC}"
        echo -e "${PURPLE}sudo -i - Start a login shell as the target user (usually root)${NC}"
        echo -e ""
        read -p "Press Enter to continue..."
        ;;

    8)
        return
        ;;

    *)
        echo -e "${RED}Invalid option. Please try again.${NC}"
        ;;
    esac

    read -p "Press Enter to continue..."
    configure_sudo
}

# Password Policy Configuration Learning Module
configure_password_policy() {
    clear
    echo -e "${BLUE}==============================================${NC}"
    echo -e "${WHITE}         PASSWORD POLICY CONFIGURATION        ${NC}"
    echo -e "${BLUE}==============================================${NC}"
    echo -e "${YELLOW}About:${NC} Strong password policies help protect against brute force attacks."
    echo -e "${YELLOW}Born2beroot requirement:${NC} Configure strict password expiration and complexity rules."
    echo -e "${YELLOW}Security best practice:${NC} Balance security with usability."
    echo -e "\n${CYAN}Current Password Policy:${NC}"

    # Password complexity
    if grep -q "pam_pwquality.so" /etc/pam.d/common-password 2>/dev/null; then
        echo -e "${GREEN}● Password complexity requirements are enforced${NC}"
        complexity=$(grep "pam_pwquality.so" /etc/pam.d/common-password)

        # Extract and display specific parameters
        min_len=$(echo "$complexity" | grep -o "minlen=[0-9]*" | cut -d= -f2)
        min_class=$(echo "$complexity" | grep -o "minclass=[0-9]*" | cut -d= -f2)
        ucredit=$(echo "$complexity" | grep -o "ucredit=[^ ]*" | cut -d= -f2)
        dcredit=$(echo "$complexity" | grep -o "dcredit=[^ ]*" | cut -d= -f2)

        [[ -n "$min_len" ]] && echo -e "  Minimum length: $min_len characters"
        [[ -n "$min_class" ]] && echo -e "  Minimum character classes: $min_class"
        [[ -n "$ucredit" ]] && echo -e "  Uppercase requirements: $ucredit"
        [[ -n "$dcredit" ]] && echo -e "  Digit requirements: $dcredit"
    else
        echo -e "${RED}● Password complexity not configured${NC}"
    fi

    # Password expiration
    if [ -f /etc/login.defs ]; then
        echo -e "\n${CYAN}Password expiration policy:${NC}"
        pass_max_days=$(grep "^PASS_MAX_DAYS" /etc/login.defs | awk '{print $2}')
        pass_min_days=$(grep "^PASS_MIN_DAYS" /etc/login.defs | awk '{print $2}')
        pass_warn_age=$(grep "^PASS_WARN_AGE" /etc/login.defs | awk '{print $2}')

        echo -e "  Password expires after: $pass_max_days days"
        echo -e "  Minimum days between changes: $pass_min_days days"
        echo -e "  Warning days before expiry: $pass_warn_age days"
    fi

    echo -e "\n${CYAN}Learning Options:${NC}"
    echo -e "${YELLOW}1.${NC} Configure Born2beroot password complexity policy"
    echo -e "${YELLOW}2.${NC} Configure Born2beroot password expiration policy"
    echo -e "${YELLOW}3.${NC} Check a password against the policy"
    echo -e "${YELLOW}4.${NC} Force password change for a user"
    echo -e "${YELLOW}5.${NC} Backup password policy configuration"
    echo -e "${YELLOW}6.${NC} Restore password policy configuration"
    echo -e "${YELLOW}7.${NC} Show password policy educational notes"
    echo -e "${YELLOW}8.${NC} Return to main menu"

    read -p "Select an option (1-8): " pw_choice

    case $pw_choice in
    1)
        echo -e "\n${CYAN}=== Configure Born2beroot Password Complexity Policy ===${NC}"
        echo -e "${YELLOW}This will set up strict password complexity requirements:${NC}"
        echo -e "${YELLOW}- Minimum length: 10 characters${NC}"
        echo -e "${YELLOW}- Must contain at least one uppercase letter${NC}"
        echo -e "${YELLOW}- Must contain at least one digit${NC}"
        echo -e "${YELLOW}- Maximum of 3 consecutive identical characters${NC}"
        echo -e "${YELLOW}- Must not include the username${NC}"
        echo -e "${PURPLE}Educational note: Password complexity ensures users don't choose easily${NC}"
        echo -e "${PURPLE}guessable passwords, which are vulnerable to brute force or dictionary attacks.${NC}"

        read -p "Apply Born2beroot password complexity policy? (yes/no): " apply_complexity

        if [[ "$apply_complexity" == "yes" ]]; then
            backup_config "password-policy"

            # Check if pam_pwquality is installed
            if ! dpkg -l | grep -q libpam-pwquality; then
                echo -e "${YELLOW}Installing libpam-pwquality...${NC}"
                if command -v apt-get >/dev/null 2>&1; then
                    apt-get update
                    apt-get install -y libpam-pwquality
                elif command -v dnf >/dev/null 2>&1; then
                    dnf install -y libpam-pwquality
                elif command -v yum >/dev/null 2>&1; then
                    yum install -y libpam-pwquality
                else
                    echo -e "${RED}Package manager not found. Please install libpam-pwquality manually.${NC}"
                    read -p "Press Enter to continue..."
                    configure_password_policy
                    return
                fi
            fi

            # Configure PAM for password complexity
            if [ -f /etc/pam.d/common-password ]; then
                # Backup the current file
                cp /etc/pam.d/common-password /etc/pam.d/common-password.backup

                # Check if pam_pwquality line exists
                if grep -q "pam_pwquality.so" /etc/pam.d/common-password; then
                    # Replace existing line
                    sed -i 's/password\s*requisite\s*pam_pwquality.so.*/password requisite pam_pwquality.so retry=3 minlen=10 ucredit=-1 dcredit=-1 maxrepeat=3 reject_username enforce_for_root/' /etc/pam.d/common-password
                else
                    # Add new line after pam_unix.so
                    sed -i '/pam_unix.so/i password requisite pam_pwquality.so retry=3 minlen=10 ucredit=-1 dcredit=-1 maxrepeat=3 reject_username enforce_for_root' /etc/pam.d/common-password
                fi

                echo -e "${GREEN}Password complexity policy applied successfully.${NC}"
                echo -e "${YELLOW}New passwords must:${NC}"
                echo -e "${YELLOW}- Be at least 10 characters long${NC}"
                echo -e "${YELLOW}- Contain at least 1 uppercase letter and 1 digit${NC}"
                echo -e "${YELLOW}- Not have more than 3 consecutive identical characters${NC}"
                echo -e "${YELLOW}- Not include the username${NC}"
            else
                echo -e "${RED}PAM configuration file not found.${NC}"
            fi
        else
            echo -e "${YELLOW}Operation cancelled.${NC}"
        fi
        ;;

    2)
        echo -e "\n${CYAN}=== Configure Born2beroot Password Expiration Policy ===${NC}"
        echo -e "${YELLOW}This will set up strict password expiration requirements:${NC}"
        echo -e "${YELLOW}- Passwords expire every 30 days${NC}"
        echo -e "${YELLOW}- Minimum 2 days between password changes${NC}"
        echo -e "${YELLOW}- Warning 7 days before password expires${NC}"
        echo -e "${PURPLE}Educational note: Password expiration forces users to change passwords${NC}"
        echo -e "${PURPLE}regularly, reducing the window of opportunity if a password is compromised.${NC}"

        read -p "Apply Born2beroot password expiration policy? (yes/no): " apply_expiration

        if [[ "$apply_expiration" == "yes" ]]; then
            backup_config "password-policy"

            # Configure password expiration in login.defs
            if [ -f /etc/login.defs ]; then
                # Backup the current file
                cp /etc/login.defs /etc/login.defs.backup

                # Update expiration settings
                sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   30/' /etc/login.defs
                sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS   2/' /etc/login.defs
                sed -i 's/^PASS_WARN_AGE.*/PASS_WARN_AGE   7/' /etc/login.defs

                echo -e "${GREEN}Password expiration policy applied successfully.${NC}"
                echo -e "${YELLOW}Note: This affects new users and password changes,${NC}"
                echo -e "${YELLOW}not existing passwords. Use option 4 to force changes.${NC}"
            else
                echo -e "${RED}login.defs file not found.${NC}"
            fi
        else
            echo -e "${YELLOW}Operation cancelled.${NC}"
        fi
        ;;

    3)
        echo -e "\n${CYAN}=== Check Password Against Policy ===${NC}"
        echo -e "${YELLOW}This will check if a password meets the complexity requirements.${NC}"
        echo -e "${PURPLE}Educational note: Testing passwords against policy helps users understand${NC}"
        echo -e "${PURPLE}what makes a strong password without trial and error during actual changes.${NC}"

        # Check if pwscore is installed (part of libpwquality)
        if ! command -v pwscore >/dev/null 2>&1; then
            echo -e "${RED}pwscore utility not found. Installing libpwquality-tools...${NC}"
            if command -v apt-get >/dev/null 2>&1; then
                apt-get update
                apt-get install -y libpwquality-tools
            elif command -v dnf >/dev/null 2>&1; then
                dnf install -y libpwquality-tools
            elif command -v yum >/dev/null 2>&1; then
                yum install -y libpwquality-tools
            else
                echo -e "${RED}Package manager not found. Cannot install pwscore.${NC}"
                read -p "Press Enter to continue..."
                configure_password_policy
                return
            fi
        fi

        read -p "Enter username (or leave blank to skip user check): " check_user
        echo -e "${YELLOW}Enter password to check (not stored):${NC}"

        if [[ -z "$check_user" ]]; then
            pwscore
        else
            echo "Password check for user $check_user:"
            pwscore "$check_user"
        fi

        echo -e "\n${CYAN}Password score explanation:${NC}"
        echo -e "${YELLOW}- Score < 50: Very weak password${NC}"
        echo -e "${YELLOW}- Score 50-60: Weak password${NC}"
        echo -e "${YELLOW}- Score 60-80: Fair password${NC}"
        echo -e "${YELLOW}- Score 80-90: Good password${NC}"
        echo -e "${YELLOW}- Score 90-100: Strong password${NC}"
        echo -e "${YELLOW}- Error/failure means the password doesn't meet policy requirements${NC}"
        ;;

    4)
        echo -e "\n${CYAN}=== Force Password Change for User ===${NC}"
        echo -e "${YELLOW}This will force a user to change their password at next login.${NC}"
        echo -e "${PURPLE}Educational note: This is useful when implementing a new password policy,${NC}"
        echo -e "${PURPLE}as it ensures all users will soon have passwords that comply with it.${NC}"

        read -p "Enter username to force password change: " force_user

        if [[ -z "$force_user" ]]; then
            echo -e "${RED}Username cannot be empty.${NC}"
        else
            # Check if user exists
            if id "$force_user" >/dev/null 2>&1; then
                passwd --expire "$force_user"
                echo -e "${GREEN}User $force_user will be required to change password at next login.${NC}"
            else
                echo -e "${RED}User $force_user does not exist.${NC}"
            fi
        fi
        ;;

    5)
        echo -e "\n${CYAN}=== Backup Password Policy Configuration ===${NC}"
        backup_config "password-policy"
        ;;

    6)
        echo -e "\n${CYAN}=== Restore Password Policy Configuration ===${NC}"
        restore_config "password-policy"
        ;;

    7)
        echo -e "\n${CYAN}=== Password Policy Educational Notes ===${NC}"
        echo -e "${WHITE}What is a Password Policy?${NC}"
        echo -e "${PURPLE}A password policy is a set of rules designed to enhance computer security${NC}"
        echo -e "${PURPLE}by encouraging users to employ strong passwords and use them properly.${NC}"
        echo -e "${PURPLE}It's a crucial component of an organization's overall security posture.${NC}"
        echo -e ""
        echo -e "${WHITE}Key Password Policy Components:${NC}"
        echo -e "${PURPLE}1. Complexity Requirements${NC}"
        echo -e "${PURPLE}   - Minimum length (longer passwords are typically stronger)${NC}"
        echo -e "${PURPLE}   - Character diversity (uppercase, lowercase, numbers, special characters)${NC}"
        echo -e "${PURPLE}   - Restrictions on patterns and dictionary words${NC}"
        echo -e "${PURPLE}2. Aging and History${NC}"
        echo -e "${PURPLE}   - Maximum password age (how often passwords must be changed)${NC}"
        echo -e "${PURPLE}   - Minimum password age (how long before a password can be changed again)${NC}"
        echo -e "${PURPLE}   - Password history (preventing reuse of recent passwords)${NC}"
        echo -e "${PURPLE}3. Account Lockout${NC}"
        echo -e "${PURPLE}   - Failed attempts before lockout${NC}"
        echo -e "${PURPLE}   - Lockout duration${NC}"
        echo -e ""
        echo -e "${WHITE}Born2beroot Password Requirements:${NC}"
        echo -e "${PURPLE}1. Password must expire every 30 days${NC}"
        echo -e "${PURPLE}2. Minimum 2 days between password changes${NC}"
        echo -e "${PURPLE}3. User receives a warning 7 days before password expires${NC}"
        echo -e "${PURPLE}4. Minimum 10 characters with at least one uppercase and one digit${NC}"
        echo -e "${PURPLE}5. No more than 3 consecutive identical characters${NC}"
        echo -e "${PURPLE}6. Must not include the username${NC}"
        echo -e "${PURPLE}7. Root password must comply with the policy${NC}"
        echo -e ""
        echo -e "${WHITE}Implementation Mechanisms:${NC}"
        echo -e "${PURPLE}/etc/login.defs - Controls password aging policies${NC}"
        echo -e "${PURPLE}/etc/pam.d/common-password - Controls password complexity via PAM modules${NC}"
        echo -e "${PURPLE}/etc/security/pwquality.conf - Detailed password quality settings${NC}"
        echo -e ""
        read -p "Press Enter to continue..."
        ;;

    8)
        return
        ;;

    *)
        echo -e "${RED}Invalid option. Please try again.${NC}"
        ;;
    esac

    read -p "Press Enter to continue..."
    configure_password_policy
}

# Hostname and User Configuration Learning Module
configure_hostname_users() {
    clear
    echo -e "${BLUE}==============================================${NC}"
    echo -e "${WHITE}    HOSTNAME AND USER CONFIGURATION          ${NC}"
    echo -e "${BLUE}==============================================${NC}"
    echo -e "${YELLOW}About:${NC} Manage system identity and user accounts."
    echo -e "${YELLOW}Born2beroot requirement:${NC} Specific hostname format and user group setup."

    echo -e "\n${CYAN}Current Hostname:${NC}"
    current_hostname=$(hostname)
    echo -e "$current_hostname"

    echo -e "\n${CYAN}Current User Groups:${NC}"
    echo -e "User groups on the system:"
    getent group | grep -E "sudo|user42" | sort

    echo -e "\n${CYAN}Learning Options:${NC}"
    echo -e "${YELLOW}1.${NC} Change hostname (Born2beroot format: login42)"
    echo -e "${YELLOW}2.${NC} Create a new user"
    echo -e "${YELLOW}3.${NC} Create user42 group (Born2beroot requirement)"
    echo -e "${YELLOW}4.${NC} Add user to group"
    echo -e "${YELLOW}5.${NC} List all users on the system"
    echo -e "${YELLOW}6.${NC} Backup user/hostname configuration"
    echo -e "${YELLOW}7.${NC} Restore hostname configuration"
    echo -e "${YELLOW}8.${NC} Show hostname/user educational notes"
    echo -e "${YELLOW}9.${NC} Return to main menu"

    read -p "Select an option (1-9): " user_choice

    case $user_choice in
    1)
        echo -e "\n${CYAN}=== Change Hostname ===${NC}"
        echo -e "${YELLOW}Born2beroot requires a hostname in the format 'login42'${NC}"
        echo -e "${PURPLE}Educational note: The hostname identifies your system on a network${NC}"
        echo -e "${PURPLE}and is used in various network communications.${NC}"

        read -p "Enter your 42 login: " login

        if [[ -z "$login" ]]; then
            echo -e "${RED}Login cannot be empty.${NC}"
        else
            new_hostname="${login}42"

            read -p "Change hostname to $new_hostname? (yes/no): " confirm

            if [[ "$confirm" == "yes" ]]; then
                backup_config "hostname"

                # Update hostname
                hostnamectl set-hostname "$new_hostname"

                # Update /etc/hosts
                sed -i "s/127.0.1.1.*/127.0.1.1\t$new_hostname/" /etc/hosts

                echo -e "${GREEN}Hostname changed to $new_hostname successfully.${NC}"
                echo -e "${YELLOW}The change will be fully effective after a reboot.${NC}"
            else
                echo -e "${YELLOW}Operation cancelled.${NC}"
            fi
        fi
        ;;

    2)
        echo -e "\n${CYAN}=== Create a New User ===${NC}"
        echo -e "${YELLOW}This will create a new user account on the system.${NC}"
        echo -e "${PURPLE}Educational note: Each user should have their own account${NC}"
        echo -e "${PURPLE}for accountability and proper permission management.${NC}"

        read -p "Enter username for the new user: " new_username
        # TODO: rest of user creation logic was truncated
        ;;
    esac
}
