#!/bin/bash

# Fix Lighttpd PHP Configuration and mysqli Extension
echo "==============================================="
echo "Lighttpd PHP and mysqli Configuration Fix"
echo "==============================================="

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use sudo."
    exit 1
fi

# Step 1: Fix Lighttpd main configuration
echo "Step 1: Adding required modules to Lighttpd main configuration..."
CONFIG_FILE="/etc/lighttpd/lighttpd.conf"

# Back up original config
cp "$CONFIG_FILE" "$CONFIG_FILE.bak"

# Check if mod_fastcgi is in the modules list
if ! grep -q "mod_fastcgi" "$CONFIG_FILE"; then
    echo "Adding mod_fastcgi to server.modules..."
    # Find the last server.modules line and add mod_fastcgi
    LINE_NUM=$(grep -n "server.modules" "$CONFIG_FILE" | tail -1 | cut -d: -f1)
    if [ -n "$LINE_NUM" ]; then
        sed -i "${LINE_NUM}s/)$/,\n\t\"mod_fastcgi\")/" "$CONFIG_FILE"
    else
        # If no server.modules line is found, add it before the include line
        sed -i "/include \"\/etc\/lighttpd\/conf-enabled\/\*.conf\"/i server.modules += (\n\t\"mod_fastcgi\"\n)" "$CONFIG_FILE"
    fi
else
    echo "mod_fastcgi is already in server.modules"
fi

# Step 2: Install required packages
echo "Step 2: Installing required packages..."
apt-get update
apt-get install -y php-mysql php8.2-mysql php8.2-fpm lighttpd-mod-fastcgi

# Step 3: Configure PHP-FPM
echo "Step 3: Configuring PHP-FPM..."

# Check for FPM directory
if [ -d "/etc/php/8.2/fpm" ]; then
    echo "Found PHP-FPM configuration directory"

    # Create mysqli.ini in the conf.d directory
    mkdir -p "/etc/php/8.2/fpm/conf.d"
    echo "extension=mysqli.so" >"/etc/php/8.2/fpm/conf.d/20-mysqli.ini"

    # Make sure PHP-FPM is running
    systemctl enable php8.2-fpm
    systemctl restart php8.2-fpm
else
    echo "PHP-FPM configuration directory not found at /etc/php/8.2/fpm"
    echo "This is unusual. Searching for PHP configuration directories..."

    # Try to find PHP directories
    PHP_DIRS=$(find /etc -name "php*.ini" 2>/dev/null | xargs dirname 2>/dev/null)

    if [ -n "$PHP_DIRS" ]; then
        echo "Found PHP configuration in: $PHP_DIRS"
        for dir in $PHP_DIRS; do
            echo "Adding mysqli extension to $dir/conf.d/20-mysqli.ini"
            mkdir -p "$dir/conf.d"
            echo "extension=mysqli.so" >"$dir/conf.d/20-mysqli.ini"
        done
    fi
fi

# Step 4: Configure Lighttpd with PHP-FPM
echo "Step 4: Setting up Lighttpd FastCGI configuration for PHP-FPM..."

# Create fastcgi.conf if it doesn't exist
FASTCGI_CONF="/etc/lighttpd/conf-available/10-fastcgi.conf"
if [ ! -f "$FASTCGI_CONF" ]; then
    echo "Creating $FASTCGI_CONF..."
    cat >"$FASTCGI_CONF" <<'EOF'
# /usr/share/doc/lighttpd/fastcgi.txt.gz
# http://redmine.lighttpd.net/projects/lighttpd/wiki/Docs:ConfigurationOptions#mod_fastcgi-fastcgi

server.modules += ( "mod_fastcgi" )
EOF
fi

# Create PHP-FPM configuration
PHP_FPM_CONF="/etc/lighttpd/conf-available/15-fastcgi-php-fpm.conf"
cat >"$PHP_FPM_CONF" <<'EOF'
# -*- depends: fastcgi -*-

# Enable PHP-FPM support for .php files
fastcgi.server += ( ".php" => 
    ((
        "socket" => "/run/php/php8.2-fpm.sock",
        "broken-scriptfilename" => "enable"
    ))
)
EOF

# Enable the configurations
ln -sf "$FASTCGI_CONF" "/etc/lighttpd/conf-enabled/10-fastcgi.conf"
ln -sf "$PHP_FPM_CONF" "/etc/lighttpd/conf-enabled/15-fastcgi-php-fpm.conf"

# Step 5: Create additional mysqli configuration for PHP-FPM pool
if [ -d "/etc/php/8.2/fpm/pool.d" ]; then
    echo "Step 5: Adding mysqli to PHP-FPM pool configuration..."

    POOL_CONF="/etc/php/8.2/fpm/pool.d/www.conf"
    if [ -f "$POOL_CONF" ]; then
        # Check if mysqli is already in the php_admin_value
        if ! grep -q "php_admin_value\[extension\] = mysqli.so" "$POOL_CONF"; then
            echo "Adding mysqli to PHP-FPM pool configuration..."
            echo "" >>"$POOL_CONF"
            echo "; Force load mysqli extension" >>"$POOL_CONF"
            echo "php_admin_value[extension] = mysqli.so" >>"$POOL_CONF"
        fi
    fi
fi

# Step 6: Create test file
echo "Step 6: Creating PHP test file..."
cat >"/var/www/html/test-mysqli.php" <<'EOF'
<?php
echo "<h1>PHP and mysqli Test</h1>";
echo "<p>PHP Version: " . phpversion() . "</p>";
echo "<p>Server API: " . php_sapi_name() . "</p>";

echo "<h2>Loaded Extensions:</h2>";
echo "<ul>";
$extensions = get_loaded_extensions();
sort($extensions);
foreach ($extensions as $ext) {
    if ($ext === "mysqli") {
        echo "<li style='color:green;font-weight:bold;'>$ext (FOUND!)</li>";
    } else if (strpos($ext, "mysql") !== false) {
        echo "<li style='color:blue;'>$ext</li>";
    } else {
        echo "<li>$ext</li>";
    }
}
echo "</ul>";

echo "<h2>mysqli Status:</h2>";
if (extension_loaded('mysqli')) {
    echo "<p style='color:green;font-weight:bold;'>mysqli extension is LOADED!</p>";
    
    echo "<h3>Testing Database Connection:</h3>";
    try {
        $mysqli = new mysqli('localhost', 'wp_user', 'wp_password', 'wordpress');
        
        if ($mysqli->connect_error) {
            echo "<p>Connection failed: " . $mysqli->connect_error . "</p>";
        } else {
            echo "<p style='color:green;'>Database connection SUCCESSFUL!</p>";
            $mysqli->close();
        }
    } catch (Exception $e) {
        echo "<p>Exception: " . $e->getMessage() . "</p>";
    }
} else {
    echo "<p style='color:red;font-weight:bold;'>mysqli extension is NOT LOADED!</p>";
}

echo "<h2>PHP Information:</h2>";
phpinfo();
?>
EOF

# Ensure correct permissions
chown www-data:www-data "/var/www/html/test-mysqli.php"
chmod 644 "/var/www/html/test-mysqli.php"

# Step 7: Restart all services
echo "Step 7: Restarting services..."
systemctl restart php8.2-fpm
systemctl restart lighttpd

echo "==============================================="
echo "Configuration complete! Please check if it worked by visiting:"
echo "http://YOUR_SERVER_IP/test-mysqli.php"
echo ""
echo "If you still have issues, please inspect the PHP information page"
echo "and verify that the mysqli extension is listed in the loaded modules."
echo "==============================================="
