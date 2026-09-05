#!/bin/bash

# UFW Configuration Script for Born2beRoot
# Author: LESdylan
# Date: 2025-04-01

# Colors for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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
echo -e "${BOLD}           UFW CONFIGURATION UTILITY         ${NC}"
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

# Function to install UFW if not already installed
install_ufw() {
    echo -e "\n${BLUE}=== Checking UFW Installation ===${NC}"

    if check_package "ufw"; then
        echo -e "${GREEN}✓ UFW is already installed${NC}"
    else
        echo -e "${YELLOW}! UFW is not installed. Installing...${NC}"
        apt update
        apt install -y ufw
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ UFW installed successfully${NC}"
        else
            echo -e "${RED}✗ Failed to install UFW${NC}"
            return 1
        fi
    fi

    # Check if UFW service is running
    if systemctl is-active --quiet ufw; then
        echo -e "${GREEN}✓ UFW service is running${NC}"
    else
        echo -e "${YELLOW}! UFW service is not running.${NC}"
    fi

    return 0
}

# Function to set default policies
set_default_policies() {
    echo -e "\n${BLUE}=== Set Default UFW Policies ===${NC}"

    echo -e "${YELLOW}Current default policies:${NC}"
    ufw status verbose | grep Default

    echo -e "\n${YELLOW}Recommended default policies for Born2beRoot:${NC}"
    echo -e "1. Deny incoming traffic (${BOLD}deny${NC})"
    echo -e "2. Allow outgoing traffic (${BOLD}allow${NC})"
    echo ""

    read -p "Do you want to set recommended default policies? (y/n): " set_defaults

    if [[ "$set_defaults" == "y" || "$set_defaults" == "Y" ]]; then
        echo -e "${YELLOW}! Setting default policies...${NC}"
        ufw default deny incoming
        ufw default allow outgoing
        echo -e "${GREEN}✓ Default policies set${NC}"
    else
        echo "1. Allow all incoming traffic"
        echo "2. Deny all incoming traffic"
        echo "3. Reject all incoming traffic"
        read -p "Select incoming policy [1-3]: " incoming_policy

        case $incoming_policy in
        1) ufw default allow incoming ;;
        2) ufw default deny incoming ;;
        3) ufw default reject incoming ;;
        *)
            echo -e "${RED}✗ Invalid option. Using deny as default${NC}"
            ufw default deny incoming
            ;;
        esac

        echo "1. Allow all outgoing traffic"
        echo "2. Deny all outgoing traffic"
        echo "3. Reject all outgoing traffic"
        read -p "Select outgoing policy [1-3]: " outgoing_policy

        case $outgoing_policy in
        1) ufw default allow outgoing ;;
        2) ufw default deny outgoing ;;
        3) ufw default reject outgoing ;;
        *)
            echo -e "${RED}✗ Invalid option. Using allow as default${NC}"
            ufw default allow outgoing
            ;;
        esac

        echo -e "${GREEN}✓ Custom default policies set${NC}"
    fi

    return 0
}

# Function to add a rule
add_rule() {
    echo -e "\n${BLUE}=== Add UFW Rule ===${NC}"

    echo "1. Allow a port"
    echo "2. Deny a port"
    echo "3. Allow a specific IP address"
    echo "4. Deny a specific IP address"
    echo "5. Allow a service (by name)"
    echo "6. Advanced rule"
    read -p "Select rule type [1-6]: " rule_type

    case $rule_type in
    1) # Allow a port
        read -p "Enter port number to allow: " port
        read -p "Protocol (tcp/udp/both): " protocol

        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            echo -e "${RED}✗ Invalid port number. Must be between 1-65535${NC}"
            return 1
        fi

        if [[ "$protocol" == "both" ]]; then
            ufw allow $port
            echo -e "${GREEN}✓ Port $port allowed (tcp & udp)${NC}"
        elif [[ "$protocol" == "tcp" || "$protocol" == "udp" ]]; then
            ufw allow $port/$protocol
            echo -e "${GREEN}✓ Port $port/$protocol allowed${NC}"
        else
            echo -e "${RED}✗ Invalid protocol. Using tcp as default${NC}"
            ufw allow $port/tcp
            echo -e "${GREEN}✓ Port $port/tcp allowed${NC}"
        fi
        ;;

    2) # Deny a port
        read -p "Enter port number to deny: " port
        read -p "Protocol (tcp/udp/both): " protocol

        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            echo -e "${RED}✗ Invalid port number. Must be between 1-65535${NC}"
            return 1
        fi

        if [[ "$protocol" == "both" ]]; then
            ufw deny $port
            echo -e "${GREEN}✓ Port $port denied (tcp & udp)${NC}"
        elif [[ "$protocol" == "tcp" || "$protocol" == "udp" ]]; then
            ufw deny $port/$protocol
            echo -e "${GREEN}✓ Port $port/$protocol denied${NC}"
        else
            echo -e "${RED}✗ Invalid protocol. Using tcp as default${NC}"
            ufw deny $port/tcp
            echo -e "${GREEN}✓ Port $port/tcp denied${NC}"
        fi
        ;;

    3) # Allow an IP address
        read -p "Enter IP address to allow: " ip

        # Simple IP validation (not perfect but catches obvious errors)
        if ! [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo -e "${RED}✗ Invalid IP address format${NC}"
            return 1
        fi

        ufw allow from $ip
        echo -e "${GREEN}✓ Traffic from $ip allowed${NC}"
        ;;

    4) # Deny an IP address
        read -p "Enter IP address to deny: " ip

        # Simple IP validation
        if ! [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo -e "${RED}✗ Invalid IP address format${NC}"
            return 1
        fi

        ufw deny from $ip
        echo -e "${GREEN}✓ Traffic from $ip denied${NC}"
        ;;

    5) # Allow a service by name
        echo -e "${YELLOW}Common services:${NC}"
        echo "ssh, http, https, ftp, smtp, pop3, imap, dns, ntp"
        read -p "Enter service name to allow: " service

        ufw allow $service
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ Service $service allowed${NC}"
        else
            echo -e "${RED}✗ Failed to add rule. Check if service name is valid${NC}"
            return 1
        fi
        ;;

    6) # Advanced rule
        echo -e "${YELLOW}Enter the full UFW command (without 'ufw' prefix):${NC}"
        echo -e "${YELLOW}Example: allow 22/tcp comment 'SSH'${NC}"
        read -p "Command: " command

        ufw $command
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ Rule added successfully${NC}"
        else
            echo -e "${RED}✗ Failed to add rule. Check syntax${NC}"
            return 1
        fi
        ;;

    *)
        echo -e "${RED}✗ Invalid option${NC}"
        return 1
        ;;
    esac

    # Add project-specific recommendations for Born2beRoot
    echo -e "\n${YELLOW}! Born2beRoot Tip: Remember to allow your SSH port (4242)${NC}"

    return 0
}

# Function to delete a rule
delete_rule() {
    echo -e "\n${BLUE}=== Delete UFW Rule ===${NC}"

    # Show numbered list of rules
    echo -e "${YELLOW}Current UFW Rules:${NC}"
    ufw status numbered

    read -p "Enter rule number to delete (or 0 to cancel): " rule_num

    if [ "$rule_num" == "0" ]; then
        echo -e "${YELLOW}! Operation canceled${NC}"
        return 0
    fi

    if ! [[ "$rule_num" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}✗ Invalid input. Please enter a number${NC}"
        return 1
    fi

    echo -e "${YELLOW}! Deleting rule number $rule_num...${NC}"
    ufw delete $rule_num

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Rule deleted successfully${NC}"
    else
        echo -e "${RED}✗ Failed to delete rule. Check rule number${NC}"
        return 1
    fi

    return 0
}

# Function to reset all rules
reset_rules() {
    echo -e "\n${BLUE}=== Reset UFW Rules ===${NC}"

    echo -e "${RED}! WARNING: This will delete all existing firewall rules!${NC}"
    read -p "Are you sure you want to continue? (y/n): " confirm

    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        echo -e "${YELLOW}! Resetting all UFW rules...${NC}"
        ufw --force reset
        echo -e "${GREEN}✓ All rules have been reset${NC}"
    else
        echo -e "${YELLOW}! Operation canceled${NC}"
    fi

    return 0
}

# Function to enable/disable UFW
toggle_ufw() {
    echo -e "\n${BLUE}=== Enable/Disable UFW ===${NC}"

    ufw_status=$(ufw status | grep "Status: " | cut -d ' ' -f 2)

    if [ "$ufw_status" == "active" ]; then
        echo -e "${YELLOW}! UFW is currently ENABLED${NC}"
        read -p "Do you want to disable UFW? (y/n): " disable

        if [[ "$disable" == "y" || "$disable" == "Y" ]]; then
            echo -e "${YELLOW}! Disabling UFW...${NC}"
            ufw --force disable
            echo -e "${GREEN}✓ UFW disabled${NC}"
        fi
    else
        echo -e "${YELLOW}! UFW is currently DISABLED${NC}"
        read -p "Do you want to enable UFW? (y/n): " enable

        if [[ "$enable" == "y" || "$enable" == "Y" ]]; then
            # Check for SSH rule to avoid lockout
            ssh_port=$(grep "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
            if [ -z "$ssh_port" ]; then
                ssh_port="22"
            fi

            if ! ufw status | grep -q "$ssh_port"; then
                echo -e "${YELLOW}! No rule found for SSH port $ssh_port. Adding it to prevent lockout...${NC}"
                read -p "Would you like to add a rule for SSH port $ssh_port first? (y/n): " add_ssh

                if [[ "$add_ssh" == "y" || "$add_ssh" == "Y" ]]; then
                    ufw allow $ssh_port/tcp
                    echo -e "${GREEN}✓ SSH port $ssh_port/tcp allowed${NC}"
                else
                    echo -e "${RED}! WARNING: Enabling UFW without SSH access rule may lock you out!${NC}"
                    read -p "Are you ABSOLUTELY sure you want to continue? (yes/no): " really_sure

                    if [ "$really_sure" != "yes" ]; then
                        echo -e "${YELLOW}! Operation canceled${NC}"
                        return 1
                    fi
                fi
            fi

            echo -e "${YELLOW}! Enabling UFW...${NC}"
            ufw --force enable
            echo -e "${GREEN}✓ UFW enabled${NC}"
        fi
    fi

    return 0
}

# Function to configure UFW logging
configure_logging() {
    echo -e "\n${BLUE}=== Configure UFW Logging ===${NC}"

    echo -e "${YELLOW}Current logging level:${NC}"
    ufw status verbose | grep "Logging: "

    echo -e "\n${YELLOW}Available logging levels:${NC}"
    echo "1. off       - Disable logging"
    echo "2. low       - Basic logging (recommended)"
    echo "3. medium    - More detailed logging"
    echo "4. high      - Very detailed logging"
    echo "5. full      - Full logging (very verbose)"

    read -p "Select logging level [1-5]: " log_level

    case $log_level in
    1) ufw logging off ;;
    2) ufw logging low ;;
    3) ufw logging medium ;;
    4) ufw logging high ;;
    5) ufw logging full ;;
    *)
        echo -e "${RED}✗ Invalid option. Using low as default${NC}"
        ufw logging low
        ;;
    esac

    echo -e "${GREEN}✓ Logging level updated${NC}"
    return 0
}

# Function to show UFW status
show_status() {
    echo -e "\n${BLUE}=== UFW Status ===${NC}"

    echo -e "${YELLOW}Basic Status:${NC}"
    ufw status

    echo -e "\n${YELLOW}Verbose Status:${NC}"
    ufw status verbose

    echo -e "\n${YELLOW}Numbered Rules:${NC}"
    ufw status numbered

    # Show log file location
    echo -e "\n${YELLOW}UFW Log Location:${NC}"
    echo "/var/log/ufw.log"

    # Display typical Born2beRoot requirements reminder
    echo -e "\n${CYAN}=== Born2beRoot Requirements Reminder ===${NC}"
    echo -e "${CYAN}• SSH service should run on port 4242${NC}"
    echo -e "${CYAN}• UFW should be active with only necessary rules${NC}"
    echo -e "${CYAN}• Default policy should be to deny incoming connections${NC}"

    # Check for SSH rule
    ssh_port=$(grep "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    if [ -z "$ssh_port" ]; then
        ssh_port="22"
    fi

    if ufw status | grep -q "$ssh_port"; then
        echo -e "${GREEN}✓ SSH port $ssh_port rule is present${NC}"
    else
        echo -e "${RED}✗ No rule found for SSH port $ssh_port! This may cause lockout.${NC}"
    fi

    return 0
}

# Function to setup Born2beRoot recommended configuration
setup_born2beroot() {
    echo -e "\n${BLUE}=== Born2beRoot Recommended Setup ===${NC}"

    echo -e "${YELLOW}This will configure UFW according to Born2beRoot project requirements:${NC}"
    echo -e "1. Set default policies (deny incoming, allow outgoing)"
    echo -e "2. Allow SSH on port 4242/tcp"
    echo -e "3. Enable UFW"
    echo -e "4. Set logging to low"

    read -p "Do you want to apply this configuration? (y/n): " apply_config

    if [[ "$apply_config" == "y" || "$apply_config" == "Y" ]]; then
        # Get SSH port from sshd_config
        ssh_port=$(grep "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
        if [ -z "$ssh_port" ]; then
            ssh_port="22"
            echo -e "${YELLOW}! SSH port not found in config. Using default port 22${NC}"
            read -p "Is this correct? If not, enter the correct SSH port: " new_port
            if [[ "$new_port" =~ ^[0-9]+$ ]]; then
                ssh_port=$new_port
            fi
        fi

        echo -e "${YELLOW}! Setting default policies...${NC}"
        ufw default deny incoming
        ufw default allow outgoing

        echo -e "${YELLOW}! Adding rule for SSH on port $ssh_port...${NC}"
        ufw allow $ssh_port/tcp

        echo -e "${YELLOW}! Setting logging level to low...${NC}"
        ufw logging low

        echo -e "${YELLOW}! Enabling UFW...${NC}"
        ufw --force enable

        echo -e "${GREEN}✓ Born2beRoot UFW configuration complete!${NC}"
    else
        echo -e "${YELLOW}! Operation canceled${NC}"
    fi

    return 0
}

# Function to show Linux distribution info
show_distro_info() {
    echo -e "\n${BLUE}=== Linux Distribution Information ===${NC}"

    if [ -f /etc/os-release ]; then
        source /etc/os-release
        echo -e "${YELLOW}OS: ${PRETTY_NAME}${NC}"
    fi

    echo -e "${YELLOW}Kernel: $(uname -r)${NC}"

    # Check for virtualization
    if [ -f /proc/cpuinfo ]; then
        if grep -q "hypervisor" /proc/cpuinfo; then
            echo -e "${YELLOW}Environment: Virtual Machine${NC}"
        else
            echo -e "${YELLOW}Environment: Physical or Container${NC}"
        fi
    fi

    return 0
}

# Main menu
while true; do
    clear
    echo -e "${BLUE}==============================================${NC}"
    echo -e "${BOLD}           UFW CONFIGURATION UTILITY         ${NC}"
    echo -e "${BLUE}==============================================${NC}"
    echo -e "${YELLOW}Current Date and Time (UTC): $(date -u +"%Y-%m-%d %H:%M:%S")${NC}"
    echo -e "${YELLOW}Current User: $(whoami)${NC}"
    echo ""

    # Show quick status
    ufw_status=$(ufw status | grep "Status: " | cut -d ' ' -f 2 2>/dev/null)
    if [ "$ufw_status" == "active" ]; then
        echo -e "UFW Status: ${GREEN}ACTIVE${NC}"
    else
        echo -e "UFW Status: ${RED}INACTIVE${NC}"
    fi
    echo ""

    echo "1. Install/Check UFW"
    echo "2. Show UFW Status and Rules"
    echo "3. Set Default Policies"
    echo "4. Add New Rule"
    echo "5. Delete Rule"
    echo "6. Reset All Rules"
    echo "7. Enable/Disable UFW"
    echo "8. Configure Logging"
    echo "9. Show System Information"
    echo "10. Born2beRoot Recommended Setup"
    echo "11. Exit"
    echo ""

    read -p "Select an option [1-11]: " option

    case $option in
    1) install_ufw ;;
    2) show_status ;;
    3) set_default_policies ;;
    4) add_rule ;;
    5) delete_rule ;;
    6) reset_rules ;;
    7) toggle_ufw ;;
    8) configure_logging ;;
    9) show_distro_info ;;
    10) setup_born2beroot ;;
    11)
        echo -e "${GREEN}Exiting UFW Configuration Utility${NC}"
        exit 0
        ;;
    *)
        echo -e "${RED}Invalid option. Please try again.${NC}"
        read -p "Press Enter to continue..."
        ;;
    esac

    read -p "Press Enter to return to the main menu..."
done
