#!/bin/bash

# Fix mysqli extension for PHP-FPM with Lighttpd
echo "===================================================="
echo "PHP-FPM mysqli Extension Fix for WordPress"
echo "===================================================="

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use sudo."
    exit 1
fi

# We now know the PHP configuration is at /etc/php/8.2/fpm
PHP_FPM_DIR="/etc/php/8.2/fpm"
echo "Using PHP-FPM configuration directory: $PHP_FPM_DIR"

# Step 1: Check for mysqli extension in PHP-FPM configuration
if [ -f "$PHP_FPM_DIR/php.ini" ]; then
    echo "Found PHP-FPM php.ini, checking for mysqli extension..."

    # Check if mysqli is enabled
    if grep -q "^extension=mysqli" "$PHP_FPM_DIR/php.ini"; then
        echo "mysqli extension already enabled in php.ini"
    elif grep -q "^;extension=mysqli" "$PHP_FPM_DIR/php.ini"; then
        echo "Uncommenting mysqli extension in php.ini"
        sed -i 's/^;extension=mysqli/extension=mysqli/' "$PHP_FPM_DIR/php.ini"
    else
        echo "Adding mysqli extension to php.ini"
        echo "extension=mysqli.so" >>"$PHP_FPM_DIR/php.ini"
    fi
else
    echo "PHP-FPM php.ini not found at $PHP_FPM_DIR/php.ini"
fi

# Step 2: Create conf.d directory if it doesn't exist
if [ ! -d "$PHP_FPM_DIR/conf.d" ]; then
    echo "Creating conf.d directory in $PHP_FPM_DIR"
    mkdir -p "$PHP_FPM_DIR/conf.d"
fi

# Step 3: Create mysqli.ini in conf.d
echo "Creating mysqli.ini in FPM conf.d directory"
echo "extension=mysqli.so" >"$PHP_FPM_DIR/conf.d/20-mysqli.ini"

# Step 4: Check lighttpd configuration for PHP-FPM
echo "Checking Lighttpd configuration for PHP-FPM..."
LIGHTTPD_PHP_FPM_CONF="/etc/lighttpd/conf-available/15-fastcgi-php-fpm.conf"

if [ -f "$LIGHTTPD_PHP_FPM_CONF" ]; then
    echo "Found PHP-FPM configuration for Lighttpd"

    # Enable the PHP-FPM configuration
    if [ ! -f "/etc/lighttpd/conf-enabled/15-fastcgi-php-fpm.conf" ]; then
        echo "Enabling PHP-FPM for Lighttpd"
        ln -sf "$LIGHTTPD_PHP_FPM_CONF" "/etc/lighttpd/conf-enabled/15-fastcgi-php-fpm.conf"

        # Disable PHP-CGI if enabled
        if [ -f "/etc/lighttpd/conf-enabled/15-fastcgi-php.conf" ]; then
            echo "Disabling PHP-CGI configuration"
            rm -f "/etc/lighttpd/conf-enabled/15-fastcgi-php.conf"
        fi
    fi
else
    echo "Creating PHP-FPM configuration for Lighttpd"
    # Create PHP-FPM configuration for Lighttpd
    cat >"$LIGHTTPD_PHP_FPM_CONF" <<'EOF'
# -*- depends: fastcgi -*-
# -*- conflicts: fastcgi-php -*-

# /usr/share/doc/lighttpd/fastcgi.txt.gz
# http://redmine.lighttpd.net/projects/lighttpd/wiki/Docs:ConfigurationOptions#mod_fastcgi-fastcgi

## Start an FastCGI server for php (needs the php-fpm package)
fastcgi.server += ( ".php" => 
    ((
        "socket" => "/run/php/php8.2-fpm.sock",
        "broken-scriptfilename" => "enable"
    ))
)
EOF

    # Enable the configuration
    ln -sf "$LIGHTTPD_PHP_FPM_CONF" "/etc/lighttpd/conf-enabled/15-fastcgi-php-fpm.conf"

    # Disable PHP-CGI if enabled
    if [ -f "/etc/lighttpd/conf-enabled/15-fastcgi-php.conf" ]; then
        rm -f "/etc/lighttpd/conf-enabled/15-fastcgi-php.conf"
    fi
fi

# Step 5: Ensure PHP-FPM service is running
echo "Checking PHP-FPM service status..."
systemctl status php8.2-fpm
if [ $? -ne 0 ]; then
    echo "Starting PHP-FPM service"
    systemctl enable php8.2-fpm
    systemctl start php8.2-fpm
else
    echo "Restarting PHP-FPM to apply changes"
    systemctl restart php8.2-fpm
fi

# Step 6: Create a test file
echo "Creating a PHP test file..."
cat >"/var/www/html/mysqli-test.php" <<'EOF'
<?php
echo "<h1>PHP mysqli Extension Test</h1>";
echo "<p>PHP Version: " . phpversion() . "</p>";
echo "<p>SAPI: " . php_sapi_name() . "</p>";

echo "<h2>Loaded Extensions:</h2>";
echo "<pre>";
print_r(get_loaded_extensions());
echo "</pre>";

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
}
?>
EOF

# Step 7: Restart Lighttpd
echo "Restarting Lighttpd..."
systemctl restart lighttpd

echo "===================================================="
echo "Fix complete! Please check if it worked by visiting:"
echo "http://YOUR_SERVER_IP/mysqli-test.php"
echo ""
echo "If WordPress still shows the error, try reinstalling the PHP MySQL package:"
echo "sudo apt-get purge php-mysql php8.2-mysql"
echo "sudo apt-get install php-mysql php8.2-mysql"
echo "sudo systemctl restart php8.2-fpm lighttpd"
echo "===================================================="
