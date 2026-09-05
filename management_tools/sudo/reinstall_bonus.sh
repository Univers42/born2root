#!/bin/bash

# Complete WordPress, PHP, MySQL reinstallation script
echo "=========================================================="
echo "WordPress Clean Installation Script"
echo "=========================================================="

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use sudo."
    exit 1
fi

# Step 1: Backup existing WordPress database if it exists
echo "Step 1: Backing up existing WordPress data..."
BACKUP_DIR="/root/wordpress_backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

if mysqladmin ping -s >/dev/null 2>&1; then
    echo "MySQL server is running. Attempting to backup WordPress database..."
    if mysql -e "USE wordpress" >/dev/null 2>&1; then
        mysqldump wordpress >"$BACKUP_DIR/wordpress_db.sql"
        echo "Database backup created at $BACKUP_DIR/wordpress_db.sql"
    else
        echo "WordPress database not found, no database backup needed."
    fi
else
    echo "MySQL server not running, skipping database backup."
fi

# Backup WordPress files if they exist
if [ -d "/var/www/html" ]; then
    echo "Backing up WordPress files..."
    cp -r /var/www/html "$BACKUP_DIR/html_backup"
    echo "Files backed up to $BACKUP_DIR/html_backup"
fi

# Step 2: Remove existing installations
echo "Step 2: Removing existing installations..."

# Stop services first
systemctl stop lighttpd php8.2-fpm mysql

# Remove PHP packages
echo "Removing PHP packages..."
apt-get purge -y php* php-*

# Remove MySQL packages
echo "Removing MySQL packages..."
apt-get purge -y mysql* mariadb*

# Remove Lighttpd
echo "Removing Lighttpd..."
apt-get purge -y lighttpd

# Remove WordPress files
echo "Removing WordPress files..."
rm -rf /var/www/html/*

# Remove configuration directories
echo "Cleaning configuration directories..."
rm -rf /etc/php* /etc/mysql* /etc/lighttpd /var/lib/mysql

# Clean up package system
echo "Cleaning package system..."
apt-get autoremove -y
apt-get clean

# Step 3: Install fresh packages
echo "Step 3: Installing fresh packages..."
apt-get update
apt-get install -y mariadb-server
apt-get install -y lighttpd
apt-get install -y php8.2 php8.2-fpm php8.2-mysql php8.2-curl php8.2-gd php8.2-intl php8.2-mbstring php8.2-xml php8.2-zip php8.2-cli

# Step 4: Configure MySQL
echo "Step 4: Configuring MySQL..."
systemctl start mariadb
systemctl enable mariadb

# Create WordPress database and user
mysql -e "CREATE DATABASE IF NOT EXISTS wordpress DEFAULT CHARACTER SET utf8 COLLATE utf8_unicode_ci;"
mysql -e "CREATE USER IF NOT EXISTS 'wp_user'@'localhost' IDENTIFIED BY 'wp_password';"
mysql -e "GRANT ALL PRIVILEGES ON wordpress.* TO 'wp_user'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

# Step 5: Configure Lighttpd with PHP-FPM
echo "Step 5: Configuring Lighttpd with PHP-FPM..."

# Create proper Lighttpd configuration
cat >"/etc/lighttpd/lighttpd.conf" <<'EOF'
server.modules = (
    "mod_indexfile",
    "mod_access",
    "mod_alias",
    "mod_redirect",
    "mod_fastcgi",
)

server.document-root        = "/var/www/html"
server.upload-dirs          = ( "/var/cache/lighttpd/uploads" )
server.errorlog             = "/var/log/lighttpd/error.log"
server.pid-file             = "/run/lighttpd.pid"
server.username             = "www-data"
server.groupname            = "www-data"
server.port                 = 80

# strict parsing and normalization of URL for consistency and security
server.http-parseopts = (
  "header-strict"           => "enable",
  "host-strict"             => "enable",
  "host-normalize"          => "enable",
  "url-normalize-unreserved"=> "enable",
  "url-normalize-required"  => "enable",
  "url-ctrls-reject"        => "enable",
  "url-path-2f-decode"      => "enable",
  "url-path-dotseg-remove"  => "enable",
)

index-file.names            = ( "index.php", "index.html" )
url.access-deny             = ( "~", ".inc" )
static-file.exclude-extensions = ( ".php", ".pl", ".fcgi" )

# default listening port for IPv6 falls back to the IPv4 port
include_shell "/usr/share/lighttpd/use-ipv6.pl " + server.port
include_shell "/usr/share/lighttpd/create-mime.conf.pl"

# PHP FastCGI configuration
fastcgi.server = ( ".php" => 
    ((
        "socket" => "/run/php/php8.2-fpm.sock",
        "broken-scriptfilename" => "enable"
    ))
)

# Other modules
server.modules += (
    "mod_dirlisting",
    "mod_staticfile",
)
EOF

# Create the uploads directory
mkdir -p /var/cache/lighttpd/uploads
chown -R www-data:www-data /var/cache/lighttpd/uploads

# Step 6: Configure PHP-FPM
echo "Step 6: Configuring PHP-FPM..."

# Ensure mysqli extension is loaded
PHP_FPM_CONF_D="/etc/php/8.2/fpm/conf.d"
mkdir -p "$PHP_FPM_CONF_D"
echo "extension=mysqli.so" >"$PHP_FPM_CONF_D/20-mysqli.ini"

# Make sure mysqli is also enabled for CLI
PHP_CLI_CONF_D="/etc/php/8.2/cli/conf.d"
mkdir -p "$PHP_CLI_CONF_D"
echo "extension=mysqli.so" >"$PHP_CLI_CONF_D/20-mysqli.ini"

# Start PHP-FPM
systemctl restart php8.2-fpm
systemctl enable php8.2-fpm

# Step 7: Download and configure WordPress
echo "Step 7: Downloading and configuring WordPress..."
cd /tmp
wget https://wordpress.org/latest.tar.gz
tar -xf latest.tar.gz
cp -a /tmp/wordpress/. /var/www/html/
chown -R www-data:www-data /var/www/html

# Create wp-config.php
cat >"/var/www/html/wp-config.php" <<'EOF'
<?php
define( 'DB_NAME', 'wordpress' );
define( 'DB_USER', 'wp_user' );
define( 'DB_PASSWORD', 'wp_password' );
define( 'DB_HOST', 'localhost' );
define( 'DB_CHARSET', 'utf8' );
define( 'DB_COLLATE', '' );

define('AUTH_KEY',         '`{+Brk$fd|;H`F``=dj7D9V=5l!d;9+lqR]v^Eg06i-Y|zrc:mzm-;u-PN> p9EY');
define('SECURE_AUTH_KEY',  'o!|^(gcAix=qJn#/A+jx96On]H-TK&W)>+ay)hdw:x0|+SV-D*i+7@vOR6*?yv(l');
define('LOGGED_IN_KEY',    '.r1&dy+gxte+?H^bQmuk-9qLP&H&a7|Z<6G+z6mS.FSRQsKOWY=XokCvP^#!($nA');
define('NONCE_KEY',        '9!dXu%oJ+0|z^nB-|B`/K_G3uH:OMcB0T|v!K}QHAtz:OCs0CT)V<3nE;~KwQMr!');
define('AUTH_SALT',        'Umf&$~IQV>>j!zpj<+:Et$p{JV>`^ZKU(/d|,cqgl%le7DEj+s`n8?v&w)9M)}:-');
define('SECURE_AUTH_SALT', '0YP.<qFp?x1Gf|n&H>6}x)bx>F7k-6)9*6Eg@{LbbKw5s@<M5_%DG.^]@+m5N_uH');
define('LOGGED_IN_SALT',   '+-V?qrI`8TcqcvRwgd=#E-(vT+z3&y|ma3aD@}_tGlL#&HPA+H&kW>,0{IS4VXK9');
define('NONCE_SALT',       'xIc+59V= x|6c|Q2~F|_U%{kK1q]u-]m3`e{$J-I<J+LJd9EuR^WA8|{]dI:P^|U');

$table_prefix = 'wp_';

define( 'WP_DEBUG', false );

if ( ! defined( 'ABSPATH' ) ) {
	define( 'ABSPATH', __DIR__ . '/' );
}

require_once ABSPATH . 'wp-settings.php';
EOF

# Step 8: Create test PHP file to verify mysqli extension
echo "Step 8: Creating test files..."
cat >"/var/www/html/test-mysqli.php" <<'EOF'
<?php
echo "<h1>PHP and mysqli Test</h1>";
echo "<p>PHP Version: " . phpversion() . "</p>";
echo "<p>Server API: " . php_sapi_name() . "</p>";

echo "<h2>Loaded Extensions:</h2>";
echo "<pre>";
$extensions = get_loaded_extensions();
sort($extensions);
print_r($extensions);
echo "</pre>";

if (extension_loaded('mysqli')) {
    echo "<p style='color:green;font-weight:bold;'>mysqli extension is LOADED!</p>";
    
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
?>
EOF

# Set proper permissions
chown www-data:www-data /var/www/html/test-mysqli.php
chmod 644 /var/www/html/test-mysqli.php

# Step 9: Restart all services
echo "Step 9: Restarting all services..."
systemctl restart php8.2-fpm
systemctl restart lighttpd
systemctl restart mariadb

echo "=========================================================="
echo "Installation complete!"
echo "Your WordPress site is ready at: http://YOUR_SERVER_IP/"
echo "First, verify mysqli is working by visiting: http://YOUR_SERVER_IP/test-mysqli.php"
echo "Then, complete the WordPress installation by visiting: http://YOUR_SERVER_IP/"
echo "=========================================================="
echo "Backup of previous installation (if any) is stored at: $BACKUP_DIR"
echo "=========================================================="
