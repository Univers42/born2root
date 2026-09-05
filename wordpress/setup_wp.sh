#!/bin/bash

echo "WordPress Database Setup Script"
echo "==============================="

# Configuration from wp-config.php
DB_NAME="wordpress"
DB_USER="wp_user"
DB_PASSWORD="wp_password"
DB_HOST="localhost"

# First, check if we can access the database with these credentials
echo "Testing database connection..."
if mysql -u"$DB_USER" -p"$DB_PASSWORD" -h"$DB_HOST" -e "USE $DB_NAME;" 2>/dev/null; then
    echo "Database connection successful!"
else
    echo "Failed to connect to database. Checking if user exists..."

    # Try to connect as root to check/create user
    read -sp "Enter MySQL root password: " ROOT_PASSWORD
    echo

    # Check if wp_user exists
    USER_EXISTS=$(mysql -uroot -p"$ROOT_PASSWORD" -e "SELECT User FROM mysql.user WHERE User='$DB_USER';" 2>/dev/null | grep -c "$DB_USER")

    if [ "$USER_EXISTS" -eq 0 ]; then
        echo "Creating database user $DB_USER..."
        mysql -uroot -p"$ROOT_PASSWORD" -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';" 2>/dev/null
        mysql -uroot -p"$ROOT_PASSWORD" -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';" 2>/dev/null
        mysql -uroot -p"$ROOT_PASSWORD" -e "FLUSH PRIVILEGES;" 2>/dev/null
        echo "User created and granted permissions."
    else
        echo "User $DB_USER exists. Checking permissions..."
        mysql -uroot -p"$ROOT_PASSWORD" -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';" 2>/dev/null
        mysql -uroot -p"$ROOT_PASSWORD" -e "FLUSH PRIVILEGES;" 2>/dev/null
        echo "Permissions granted."
    fi
fi

# Check if WordPress tables already exist
TABLES_COUNT=$(mysql -u"$DB_USER" -p"$DB_PASSWORD" -h"$DB_HOST" -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME' AND table_name LIKE 'wp_%';" 2>/dev/null | grep -v "COUNT" | tr -d ' ')

if [ -z "$TABLES_COUNT" ] || [ "$TABLES_COUNT" -eq 0 ]; then
    echo "WordPress tables don't exist. Creating them now..."

    # Get WordPress admin configuration
    echo "Setting up WordPress initial configuration"
    read -p "Site Title: " SITE_TITLE
    read -p "Admin Username: " ADMIN_USER
    read -p "Admin Password: " ADMIN_PASSWORD
    read -p "Admin Email: " ADMIN_EMAIL

    # Find WordPress installation directory
    WP_DIR="/var/www/html"
    if [ ! -f "$WP_DIR/wp-load.php" ]; then
        # Try to find WordPress directory
        WP_DIR=$(find /var -name wp-config.php 2>/dev/null | head -n1 | xargs dirname 2>/dev/null)
        if [ -z "$WP_DIR" ]; then
            echo "WordPress installation not found!"
            exit 1
        fi
    fi

    echo "WordPress found at: $WP_DIR"

    # Create PHP script to run WordPress installation
    INSTALL_SCRIPT="$WP_DIR/wp-install.php"

    cat >"$INSTALL_SCRIPT" <<EOF
<?php
// Load WordPress with no output
define('WP_INSTALLING', true);
require_once('wp-load.php');
require_once('wp-admin/includes/upgrade.php');
require_once('wp-admin/includes/install.php');

// Create tables
wp_install("$SITE_TITLE", "$ADMIN_USER", "$ADMIN_EMAIL", 1, "", "$ADMIN_PASSWORD");

echo "WordPress database tables created successfully!\n";
echo "Admin user '$ADMIN_USER' created with provided password.\n";
EOF

    # Run the installation script
    cd "$WP_DIR" && php wp-install.php

    # Clean up
    rm -f "$INSTALL_SCRIPT"

    # Update WordPress URLs
    echo "Updating WordPress URLs..."
    mysql -u"$DB_USER" -p"$DB_PASSWORD" -h"$DB_HOST" -e "UPDATE ${DB_NAME}.wp_options SET option_value = 'http://localhost:8080' WHERE option_name IN ('siteurl', 'home');" 2>/dev/null

    echo "WordPress installation complete!"
    echo "You can now access your site at: http://localhost:8080"
else
    echo "WordPress tables already exist ($TABLES_COUNT tables found)."

    # Just update the URLs
    echo "Updating WordPress URLs..."
    mysql -u"$DB_USER" -p"$DB_PASSWORD" -h"$DB_HOST" -e "UPDATE ${DB_NAME}.wp_options SET option_value = 'http://localhost:8080' WHERE option_name IN ('siteurl', 'home');" 2>/dev/null

    echo "URLs updated. You can now access your site at: http://localhost:8080"
fi

# Verify port forwarding setup
echo "Checking host port forwarding configuration..."
netstat -tulpn | grep -E ":80|:8080" || echo "No process detected listening on port 80 or 8080"

# Verify web server configuration
echo "Checking web server..."
systemctl status lighttpd --no-pager | grep Active

echo "Done!"
