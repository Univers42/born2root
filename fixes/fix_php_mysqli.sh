#!/bin/bash

# Script to fix PHP mysqli extension loading in Lighttpd
echo "===================================================="
echo "Fix PHP-mysqli Extension for WordPress with Lighttpd"
echo "===================================================="

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use sudo."
    exit 1
fi

# Determine PHP version
PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
echo "Detected PHP version: $PHP_VERSION"

# Find PHP configuration directories
PHP_CONF_DIRS=("/etc/php/$PHP_VERSION/cgi" "/etc/php/$PHP_VERSION/cli" "/etc/php/$PHP_VERSION/mods-available")

# First approach: Enable extension in mods-available
echo "Creating/updating mysqli.ini in mods-available..."
if [ -d "/etc/php/$PHP_VERSION/mods-available" ]; then
    echo "extension=mysqli.so" >"/etc/php/$PHP_VERSION/mods-available/mysqli.ini"
    echo "Created mysqli.ini"

    # Check for multiple PHP versions and enable for all
    for version_dir in /etc/php/*; do
        if [ -d "$version_dir/cgi" ] || [ -d "$version_dir/cli" ]; then
            version=$(basename "$version_dir")
            echo "Enabling mysqli for PHP $version..."

            # Enable for CGI
            if [ -d "$version_dir/cgi/conf.d" ]; then
                ln -sf "/etc/php/$PHP_VERSION/mods-available/mysqli.ini" "$version_dir/cgi/conf.d/20-mysqli.ini" 2>/dev/null
                echo "Enabled for PHP $version CGI"
            fi

            # Enable for CLI
            if [ -d "$version_dir/cli/conf.d" ]; then
                ln -sf "/etc/php/$PHP_VERSION/mods-available/mysqli.ini" "$version_dir/cli/conf.d/20-mysqli.ini" 2>/dev/null
                echo "Enabled for PHP $version CLI"
            fi
        fi
    done
else
    echo "PHP mods-available directory not found, trying direct configuration"
fi

# Second approach: Directly edit php.ini files
for CONF_DIR in "${PHP_CONF_DIRS[@]}"; do
    if [ -d "$CONF_DIR" ]; then
        PHP_INI="$CONF_DIR/php.ini"
        if [ -f "$PHP_INI" ]; then
            echo "Checking $PHP_INI for mysqli extension..."

            # Check if mysqli is already enabled
            if grep -q "^extension=mysqli.so" "$PHP_INI"; then
                echo "mysqli extension already enabled in $PHP_INI"
            elif grep -q "^;extension=mysqli.so" "$PHP_INI"; then
                # Uncomment existing line
                echo "Uncommenting mysqli extension in $PHP_INI"
                sed -i 's/^;extension=mysqli.so/extension=mysqli.so/' "$PHP_INI"
            else
                # Add extension directive
                echo "Adding mysqli extension to $PHP_INI"
                echo "extension=mysqli.so" >>"$PHP_INI"
            fi
        fi
    fi
done

# Third approach: Install php-cgi package explicitly
echo "Making sure php-cgi is installed..."
apt-get install -y php-cgi

# Fourth approach: Special directive for Lighttpd configuration
echo "Updating Lighttpd PHP FastCGI configuration..."
if [ -f "/etc/lighttpd/conf-enabled/15-fastcgi-php.conf" ]; then
    # Back up the original file
    cp "/etc/lighttpd/conf-enabled/15-fastcgi-php.conf" "/etc/lighttpd/conf-enabled/15-fastcgi-php.conf.bak"

    # Check if PHP_FCGI_CHILDREN is correctly configured
    if grep -q "PHP_FCGI_CHILDREN" "/etc/lighttpd/conf-enabled/15-fastcgi-php.conf"; then
        # Add mysqli.so to the environment variables
        sed -i '/PHP_FCGI_CHILDREN/a \            "PHP_ADMIN_VALUE" => "extension=mysqli.so",' "/etc/lighttpd/conf-enabled/15-fastcgi-php.conf"
        echo "Added mysqli.so extension directive to Lighttpd FastCGI configuration"
    else
        echo "Warning: Could not find PHP_FCGI_CHILDREN in Lighttpd configuration, manual edit may be required"
    fi
fi

# Create a test PHP file in web root to verify mysqli
echo "Creating PHP test file..."
cat >"/var/www/html/mysqli-test.php" <<'EOF'
<?php
echo "<h1>PHP mysqli Extension Test</h1>";
echo "<p>PHP Version: " . phpversion() . "</p>";

if (extension_loaded('mysqli')) {
    echo "<p style='color:green;'>SUCCESS: mysqli extension is loaded!</p>";
    
    try {
        $mysqli = new mysqli('localhost', 'wp_user', 'wp_password', 'wordpress');
        
        if ($mysqli->connect_error) {
            echo "<p>Database connection failed: " . $mysqli->connect_error . "</p>";
        } else {
            echo "<p>Successfully connected to MySQL database!</p>";
            $mysqli->close();
        }
    } catch (Exception $e) {
        echo "<p>Exception: " . $e->getMessage() . "</p>";
    }
} else {
    echo "<p style='color:red;'>ERROR: mysqli extension is NOT loaded!</p>";
    echo "<p>Loaded extensions:</p><ul>";
    foreach (get_loaded_extensions() as $ext) {
        echo "<li>$ext</li>";
    }
    echo "</ul>";
}
?>
EOF

# Restart services
echo "Restarting Lighttpd..."
systemctl restart lighttpd

echo "===================================================="
echo "Fix attempted! Please check if it worked by visiting:"
echo "http://YOUR_SERVER_IP/mysqli-test.php"
echo ""
echo "If it still doesn't work, try these additional steps:"
echo "1. Install php-mysql explicitly: sudo apt install php-mysql"
echo "2. Enable the mysqli module: sudo phpenmod mysqli"
echo "3. Check for extension loading issues: sudo php -m | grep mysqli"
echo "===================================================="
