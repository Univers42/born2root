#!/bin/bash

# WordPress Installation Script for Born2beRoot
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
echo -e "${BOLD}        WORDPRESS SETUP UTILITY           ${NC}"
echo -e "${BLUE}==============================================${NC}"
echo -e "${YELLOW}Current Date and Time (UTC): $(date -u +"%Y-%m-%d %H:%M:%S")${NC}"
echo -e "${YELLOW}Current User: $(whoami)${NC}"
echo ""

# Function to install packages
install_packages() {
    echo -e "\n${BLUE}=== Installing Required Packages ===${NC}"

    apt update
    apt install -y lighttpd
    apt install -y mariadb-server
    apt install -y php-cgi php-mysql php-gd php-curl php-xml php-mbstring
    apt install -y wget

    echo -e "${GREEN}✓ Required packages installed${NC}"
    return 0
}

# Function to configure lighttpd
configure_lighttpd() {
    echo -e "\n${BLUE}=== Configuring Lighttpd Web Server ===${NC}"

    # Enable necessary modules
    lighttpd-enable-mod fastcgi
    lighttpd-enable-mod fastcgi-php

    # Restart lighttpd
    systemctl restart lighttpd
    systemctl enable lighttpd

    # Open firewall port
    ufw allow 80/tcp

    echo -e "${GREEN}✓ Lighttpd configured and enabled${NC}"
    return 0
}

# Function to configure MariaDB
configure_mariadb() {
    echo -e "\n${BLUE}=== Configuring MariaDB Database ===${NC}"

    # Start and enable MariaDB
    systemctl start mariadb
    systemctl enable mariadb

    # Secure the MariaDB installation
    echo -e "${YELLOW}! Running MariaDB secure installation...${NC}"
    echo -e "${YELLOW}! Answer the following questions to secure your database:${NC}"

    mysql_secure_installation

    # Create WordPress database
    echo -e "\n${YELLOW}! Creating WordPress database...${NC}"

    # Get database credentials
    read -p "Enter a name for the WordPress database: " db_name
    read -p "Enter a username for the WordPress database: " db_user
    read -p "Enter a password for the WordPress database user: " db_password

    # Create database and user
    mysql -e "CREATE DATABASE $db_name;"
    mysql -e "CREATE USER '$db_user'@'localhost' IDENTIFIED BY '$db_password';"
    mysql -e "GRANT ALL PRIVILEGES ON $db_name.* TO '$db_user'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"

    echo -e "${GREEN}✓ MariaDB configured and WordPress database created${NC}"

    # Save credentials for later
    echo "DB_NAME=$db_name" >/root/wordpress_credentials.txt
    echo "DB_USER=$db_user" >>/root/wordpress_credentials.txt
    echo "DB_PASSWORD=$db_password" >>/root/wordpress_credentials.txt
    chmod 600 /root/wordpress_credentials.txt

    echo -e "${YELLOW}! Database credentials saved to /root/wordpress_credentials.txt${NC}"
    return 0
}

# Function to install WordPress
install_wordpress() {
    echo -e "\n${BLUE}=== Installing WordPress ===${NC}"

    # Create website directory
    mkdir -p /var/www/html

    # Download and extract WordPress
    cd /tmp
    wget https://wordpress.org/latest.tar.gz
    tar -xzvf latest.tar.gz
    cp -r wordpress/* /var/www/html/
    rm -rf wordpress latest.tar.gz

    # Set permissions
    chown -R www-data:www-data /var/www/html/
    chmod -R 755 /var/www/html/

    # Create wp-config.php
    if [ -f /root/wordpress_credentials.txt ]; then
        source /root/wordpress_credentials.txt

        cp /var/www/html/wp-config-sample.php /var/www/html/wp-config.php
        sed -i "s/database_name_here/$DB_NAME/" /var/www/html/wp-config.php
        sed -i "s/username_here/$DB_USER/" /var/www/html/wp-config.php
        sed -i "s/password_here/$DB_PASSWORD/" /var/www/html/wp-config.php

        # Generate secure keys
        for key in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
            sed -i "s/define( '$key', .*/define( '$key', '$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 64 | head -n 1)' );/" /var/www/html/wp-config.php
        done
    else
        echo -e "${YELLOW}! Database credentials not found. You'll need to configure wp-config.php manually${NC}"
    fi

    echo -e "${GREEN}✓ WordPress installed in /var/www/html/${NC}"

    # Get server IP for easy access
    ip=$(hostname -I | awk '{print $1}')
    echo -e "${YELLOW}! You can access your WordPress site at: http://$ip/${NC}"
    echo -e "${YELLOW}! Complete the installation through the web interface${NC}"

    return 0
}

# Function to configure UFW
configure_ufw() {
    echo -e "\n${BLUE}=== Configuring Firewall ===${NC}"

    # Allow HTTP (port 80)
    ufw allow 80/tcp

    echo -e "${GREEN}✓ Firewall configured to allow HTTP traffic${NC}"
    return 0
}

# Main function
main() {
    echo -e "${YELLOW}This script will install and configure WordPress with Lighttpd, MariaDB, and PHP${NC}"
    echo -e "${YELLOW}Press Ctrl+C to cancel or Enter to continue...${NC}"
    read

    install_packages
    configure_lighttpd
    configure_mariadb
    install_wordpress
    configure_ufw

    echo -e "\n${GREEN}============================================${NC}"
    echo -e "${GREEN}WordPress installation completed successfully!${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo -e "${YELLOW}You may need to restart your system for all changes to take effect${NC}"
    echo -e "${YELLOW}Visit http://$(hostname -I | awk '{print $1}')/ to complete WordPress setup${NC}"

    return 0
}

# Run the main function
main
