#!/bin/bash

# diagnostic_guest.sh for Debian 12 VM
# Run with sudo for complete results

echo "============================================"
echo "WordPress Connectivity Diagnostic Tool (VM)"
echo "============================================"
echo "Date: $(date)"
echo "Hostname: $(hostname)"
echo "Running as: $(whoami)"
echo

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "WARNING: This script should be run as root for full diagnostics"
    echo "Re-run with sudo for complete results"
    echo
fi

# Check Lighttpd status
echo "=== Lighttpd Service Status ==="
systemctl status lighttpd --no-pager
echo

# Check if lighttpd is listening on ports
echo "=== Lighttpd Listening Ports ==="
netstat -tulpn | grep lighttpd || ss -tulpn | grep lighttpd || echo "Could not detect lighttpd listening ports"
echo

# Check Lighttpd configuration
echo "=== Lighttpd Configuration ==="
if [ -f /etc/lighttpd/lighttpd.conf ]; then
    echo "Main config exists: /etc/lighttpd/lighttpd.conf"
    echo "Checking server.bind and server.port settings:"
    grep -E "server\.port|server\.bind" /etc/lighttpd/lighttpd.conf

    # Critical: Check if server is bound only to localhost (common issue)
    if grep -q "server.bind" /etc/lighttpd/lighttpd.conf; then
        if grep -q "server.bind.*=.*\"127.0.0.1\"" /etc/lighttpd/lighttpd.conf; then
            echo "WARNING: Lighttpd is bound only to localhost (127.0.0.1)!"
            echo "This prevents external connections. Edit /etc/lighttpd/lighttpd.conf"
            echo "Comment out or change server.bind to \"0.0.0.0\" to listen on all interfaces"
        fi
    fi
else
    echo "WARNING: Lighttpd main config file not found"
fi
echo

# Check if WordPress directories exist
echo "=== WordPress Files Check ==="
if [ -d /var/www/html ]; then
    echo "Web root directory exists: /var/www/html"
    ls -la /var/www/html/ | head -n 20

    # Check for wp-config.php
    WP_CONFIG=$(find /var/www/html -name wp-config.php -type f | head -n 1)
    if [ -n "$WP_CONFIG" ]; then
        echo "WordPress config found at: $WP_CONFIG"
        echo "Database settings:"
        grep -E "DB_HOST|DB_NAME|DB_USER" "$WP_CONFIG" | grep -v "password"
    else
        echo "WARNING: WordPress config (wp-config.php) not found"
    fi
else
    echo "WARNING: Web root directory /var/www/html not found"
fi
echo

# Check file permissions
echo "=== File Permissions ==="
echo "Web root directory permissions:"
ls -ld /var/www /var/www/html 2>/dev/null
echo "WordPress files ownership:"
find /var/www/html -type f -name "*.php" -exec ls -l {} \; | head -n 5
echo

# Check MariaDB status
echo "=== MariaDB Service Status ==="
systemctl status mariadb --no-pager
echo

# Check WordPress database existence
echo "=== WordPress Database ==="
if [ -n "$WP_CONFIG" ] && command -v mysql >/dev/null 2>&1; then
    DB_NAME=$(grep DB_NAME "$WP_CONFIG" 2>/dev/null | cut -d \' -f 4)
    if [ -n "$DB_NAME" ]; then
        echo "WordPress database name: $DB_NAME"
        mysql -e "SHOW DATABASES LIKE '$DB_NAME';" 2>/dev/null && echo "Database $DB_NAME exists" || echo "Database $DB_NAME not found or access denied"
    else
        echo "Could not determine WordPress database name"
    fi
else
    echo "MySQL client not installed or wp-config.php not found"
fi
echo

# Check network configuration
echo "=== Network Configuration ==="
echo "IP Addresses:"
ip addr | grep inet
echo
echo "Default Gateway:"
ip route | grep default
echo

# Check firewall status
echo "=== Firewall Status ==="
if command -v ufw >/dev/null 2>&1; then
    echo "UFW Status:"
    ufw status
elif command -v iptables >/dev/null 2>&1; then
    echo "iptables Rules:"
    iptables -L -n
else
    echo "No firewall tool detected (ufw/iptables)"
fi
echo

# Check if HTTP/HTTPS ports are open
echo "=== Port Status ==="
echo "Open ports (80, 443):"
netstat -tulpn | grep -E ':80|:443' || ss -tulpn | grep -E ':80|:443' || echo "No processes listening on ports 80 or 443"
echo

# WordPress URL configuration
echo "=== WordPress URL Settings ==="
if [ -n "$WP_CONFIG" ] && [ -n "$DB_NAME" ] && command -v mysql >/dev/null 2>&1; then
    echo "WordPress URL configuration from database (if accessible):"
    mysql -e "SELECT option_name, option_value FROM ${DB_NAME}.wp_options WHERE option_name IN ('siteurl', 'home');" 2>/dev/null || echo "Could not retrieve WordPress URL settings from database"
    echo "NOTE: If siteurl or home are set to specific IPs/domains instead of localhost, this can cause redirect issues"
else
    echo "Could not check WordPress URL settings (missing DB name or MySQL client)"
fi
echo

# Test internal connectivity
echo "=== Internal Connectivity Test ==="
echo "Testing connection to local web server:"
curl -I http://localhost 2>/dev/null || wget -qO- http://localhost --spider 2>/dev/null || echo "Failed to connect to local web server"
echo

echo "============================================"
echo "Diagnostic complete"
echo "Check the output above for potential issues"
echo "============================================"
