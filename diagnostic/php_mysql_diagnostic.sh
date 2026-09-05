#!/bin/bash

# PHP MySQL Extension Comprehensive Diagnostic Script
# For troubleshooting WordPress PHP-MySQL connectivity issues
# Run with sudo for complete results

# Terminal colors for better readability
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print section headers
section() {
    echo -e "\n${BLUE}========== $1 ==========${NC}\n"
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check if a PHP extension is loaded
php_ext_loaded() {
    php -m | grep -i "$1" >/dev/null 2>&1
}

# Start diagnostic
section "PHP MYSQL EXTENSION DIAGNOSTIC TOOL"
echo "Date: $(date)"
echo "User: $(whoami)"

# Check if root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${YELLOW}Warning: Not running as root. Some tests may fail due to insufficient permissions.${NC}"
    echo "Consider re-running with sudo for complete results."
fi

# System Information
section "SYSTEM INFORMATION"
echo "Operating System: $(cat /etc/*release | grep "PRETTY_NAME" | cut -d= -f2- | tr -d '"')"
echo "Kernel: $(uname -r)"

# PHP Version Check
section "PHP VERSION"
if command_exists php; then
    php -v
    echo -e "\nPHP CLI Version: $(php -r 'echo phpversion();')"
    echo "PHP SAPI: $(php -r 'echo php_sapi_name();')"
else
    echo -e "${RED}PHP not found in path${NC}"
fi

# PHP Configuration Files
section "PHP CONFIGURATION FILES"
echo -e "${YELLOW}PHP Configuration File (php.ini):${NC}"
php -i | grep "Loaded Configuration File" || echo -e "${RED}Could not determine loaded php.ini${NC}"

echo -e "\n${YELLOW}PHP Additional .ini files:${NC}"
php -i | grep "Additional .ini files" || echo "No additional .ini files loaded"

echo -e "\n${YELLOW}PHP Extension Directory:${NC}"
php -i | grep "extension_dir" | head -1 || echo -e "${RED}Could not determine PHP extension directory${NC}"

# PHP MySQL Related Extensions
section "PHP MYSQL EXTENSIONS"
echo -e "${YELLOW}Checking for MySQL/MariaDB extensions:${NC}\n"

echo -n "mysqli extension: "
if php_ext_loaded mysqli; then
    echo -e "${GREEN}INSTALLED${NC}"
    php -r 'var_dump(extension_loaded("mysqli"));'
else
    echo -e "${RED}NOT INSTALLED${NC}"
fi

echo -n "mysql extension (legacy): "
if php_ext_loaded mysql; then
    echo -e "${GREEN}INSTALLED${NC}"
else
    echo -e "${YELLOW}NOT INSTALLED${NC} (Normal for PHP 7+)"
fi

echo -n "mysqlnd extension: "
if php_ext_loaded mysqlnd; then
    echo -e "${GREEN}INSTALLED${NC}"
else
    echo -e "${YELLOW}NOT INSTALLED${NC}"
fi

echo -n "PDO_MySQL extension: "
if php_ext_loaded pdo_mysql; then
    echo -e "${GREEN}INSTALLED${NC}"
else
    echo -e "${YELLOW}NOT INSTALLED${NC}"
fi

# PHP Extension Listing
section "ALL PHP EXTENSIONS"
echo "Installed PHP extensions:"
php -m

# PHP Info For MySQL Config
section "PHP MYSQL CONFIGURATION"
echo "PHP MySQL Configuration Details:"
php -i | grep -i mysql

# Installed PHP Packages
section "INSTALLED PHP PACKAGES"
echo "Debian/Ubuntu PHP packages:"
dpkg -l | grep -i php | grep -i mysql

# Lighttpd Configuration
section "LIGHTTPD CONFIGURATION"
echo -e "${YELLOW}Checking Lighttpd PHP Configuration:${NC}"
if [ -d /etc/lighttpd ]; then
    echo "Lighttpd configuration directory found"

    if [ -f /etc/lighttpd/lighttpd.conf ]; then
        echo -e "\n${YELLOW}Main Lighttpd config file:${NC}"
        grep -i "mod_fastcgi\|php" /etc/lighttpd/lighttpd.conf
    else
        echo -e "${RED}Main Lighttpd config file not found${NC}"
    fi

    echo -e "\n${YELLOW}Checking for PHP configurations in conf-enabled:${NC}"
    if [ -d /etc/lighttpd/conf-enabled ]; then
        grep -i "php\|fastcgi" /etc/lighttpd/conf-enabled/* 2>/dev/null
    fi

    echo -e "\n${YELLOW}Looking for PHP-specific config files:${NC}"
    find /etc/lighttpd -name "*php*" -type f 2>/dev/null
else
    echo -e "${RED}Lighttpd configuration directory not found${NC}"
fi

# Check WordPress Configuration
section "WORDPRESS CONFIGURATION"
echo -e "${YELLOW}Looking for WordPress installations:${NC}"
for dir in /var/www/html /var/www; do
    if [ -f "$dir/wp-config.php" ]; then
        echo "WordPress found at: $dir"
        echo "WordPress database settings:"
        grep -E "DB_HOST|DB_NAME|DB_USER" "$dir/wp-config.php" | grep -v PASSWORD
    fi
done

# Check PHP error logs
section "PHP ERROR LOGS"
echo -e "${YELLOW}Recent PHP errors:${NC}"
ERROR_LOGS="/var/log/lighttpd/error.log /var/log/apache2/error.log /var/log/php*"
for log in $ERROR_LOGS; do
    if [ -f "$log" ]; then
        echo -e "\nErrors from $log:"
        tail -n 50 "$log" | grep -i "php\|mysql\|mysqli" | tail -n 10
    fi
done

# Test PHP-MySQL Connection
section "PHP-MYSQL CONNECTION TEST"
echo -e "${YELLOW}Creating a test PHP script to verify MySQL connectivity:${NC}"
TEST_SCRIPT="/tmp/mysql_test_$$.php"

cat >"$TEST_SCRIPT" <<'EOF'
<?php
echo "PHP Version: " . phpversion() . "\n";

echo "\nTesting mysqli extension:\n";
if (extension_loaded('mysqli')) {
    echo "mysqli extension is loaded.\n";
    
    echo "Attempting connection to database with mysqli...\n";
    try {
        $mysqli = new mysqli('localhost', 'wp_user', 'wp_password', 'wordpress');
        
        if ($mysqli->connect_error) {
            echo "Failed to connect: " . $mysqli->connect_error . "\n";
        } else {
            echo "Successfully connected to database 'wordpress' with mysqli!\n";
            echo "MySQL Server Info: " . $mysqli->server_info . "\n";
            $mysqli->close();
        }
    } catch (Exception $e) {
        echo "Exception: " . $e->getMessage() . "\n";
    }
} else {
    echo "ERROR: mysqli extension is NOT loaded!\n";
}

echo "\nChecking PHP MySQL Configuration:\n";
$configs = [
    'mysqli.default_socket',
    'mysqli.default_host',
    'mysqli.default_user',
    'mysqli.default_port',
];

foreach ($configs as $config) {
    echo "$config: " . ini_get($config) . "\n";
}

echo "\nPHP Extension Directory: " . ini_get('extension_dir') . "\n";

echo "\nLooking for mysqli files:\n";
$extDir = ini_get('extension_dir');
if (is_dir($extDir)) {
    $files = scandir($extDir);
    foreach ($files as $file) {
        if (strpos($file, 'mysql') !== false || strpos($file, 'mysqli') !== false) {
            echo "Found: $extDir/$file\n";
        }
    }
} else {
    echo "Extension directory not found: $extDir\n";
}
?>
EOF

echo "Running PHP MySQL test script..."
php "$TEST_SCRIPT"
rm "$TEST_SCRIPT"

# Provide recommendations
section "RECOMMENDATIONS"
echo "Based on diagnostic results, try the following:"
echo "1. Install mysqli extension: sudo apt install php-mysqli"
echo "   Or version-specific: sudo apt install php8.2-mysqli (replace with your PHP version)"
echo ""
echo "2. Verify lighttpd is configured for PHP:"
echo "   sudo lighty-enable-mod fastcgi"
echo "   sudo lighty-enable-mod fastcgi-php"
echo ""
echo "3. Restart services:"
echo "   sudo systemctl restart lighttpd"
echo ""
echo "4. Check PHP configuration file permissions:"
echo "   sudo ls -la /etc/php*"
echo ""
echo "5. If mysqli shows as installed but WordPress doesn't see it:"
echo "   This may indicate a different PHP version is used by CLI vs web server"
echo "   Check if multiple PHP versions are installed"

section "DIAGNOSTIC COMPLETE"
echo "Copy all of this output and share it to help diagnose the issue."
