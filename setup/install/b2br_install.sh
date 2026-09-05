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

# Function to install a package with status check
install_package() {
    echo -e "${YELLOW}Installing $1...${NC}"
    apt-get install -y $1 >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ $1 installed successfully${NC}"
    else
        echo -e "${RED}✗ Failed to install $1${NC}"
    fi
}

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}This script must be run as root!${NC}"
    echo -e "Please run with: sudo $0"
    exit 1
fi

print_header "UPDATING SYSTEM PACKAGES"
apt-get update
apt-get upgrade -y

print_header "INSTALLING CORE PACKAGES"
# Base security packages
install_package "sudo"
install_package "ufw"
install_package "apparmor"
install_package "apparmor-utils"
install_package "libpam-pwquality"
install_package "openssh-server"

# Utilities
install_package "vim"
install_package "wget"
install_package "net-tools"
install_package "curl"

print_header "INSTALLING MONITORING TOOLS"
install_package "sysstat"
install_package "iotop"
install_package "htop"

# Optional: Install bonus part packages if requested
print_header "WOULD YOU LIKE TO INSTALL BONUS PACKAGES?"
echo -e "${YELLOW}The bonus part requires a web server with WordPress${NC}"
read -p "Install bonus packages? (y/n): " install_bonus

if [[ "$install_bonus" =~ ^[Yy]$ ]]; then
    print_header "INSTALLING BONUS PACKAGES"

    # Web server
    install_package "lighttpd"

    # Database
    install_package "mariadb-server"

    # PHP for WordPress
    install_package "php-cgi"
    install_package "php-fpm"
    install_package "php-mysql"
    install_package "php-cli"
    install_package "php-curl"
    install_package "php-gd"
    install_package "php-mbstring"
    install_package "php-xml"
    install_package "php-xmlrpc"
    install_package "php-soap"
    install_package "php-intl"
    install_package "php-zip"
fi

print_header "INSTALLATION COMPLETE"
echo -e "${GREEN}✓ All required packages have been installed${NC}"
echo -e "${YELLOW}Run the configuration script next to set up your Born2beRoot environment${NC}"
echo
echo -e "${BOLD}Next step:${NC} sudo ./b2br_configure.sh"
