#!/bin/bash

# Script to install required PHP extensions for WordPress
# Specifically addresses the missing mysqli extension

echo "===================================================="
echo "WordPress PHP Extensions Installation Script"
echo "===================================================="

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use sudo."
    exit 1
fi

# Identify PHP version
PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "")

if [ -z "$PHP_VERSION" ]; then
    echo "Could not determine PHP version. Installing default PHP packages..."
    PHP_PKG_PREFIX="php"
else
    echo "Detected PHP version: $PHP_VERSION"
    PHP_PKG_PREFIX="php$PHP_VERSION"
fi

echo "Using package prefix: $PHP_PKG_PREFIX"

# Install essential PHP extensions for WordPress
echo "Installing required PHP extensions for WordPress..."
apt-get update
apt-get install -y ${PHP_PKG_PREFIX}-mysql ${PHP_PKG_PREFIX}-mysqli ${PHP_PKG_PREFIX}-gd ${PHP_PKG_PREFIX}-curl ${PHP_PKG_PREFIX}-mbstring ${PHP_PKG_PREFIX}-xml ${PHP_PKG_PREFIX}-intl ${PHP_PKG_PREFIX}-zip

# Install php-mysql (alternative naming in some distributions)
apt-get install -y ${PHP_PKG_PREFIX}-mysql || true

# Verify mysqli extension is installed
echo "Verifying mysqli extension..."
php -m | grep -i mysqli
if [ $? -eq 0 ]; then
    echo "mysqli extension is now installed!"
else
    echo "Warning: mysqli extension installation may have failed. Checking alternatives..."
    # Try to install with legacy naming pattern
    apt-get install -y php-mysqli
    php -m | grep -i mysqli
    if [ $? -eq 0 ]; then
        echo "mysqli extension is now installed (using alternate package)!"
    else
        echo "Error: Could not install mysqli extension. Please check your PHP configuration."
    fi
fi

# Restart web server
echo "Restarting lighttpd..."
systemctl restart lighttpd

# Verify all WordPress-required PHP extensions
echo "Verifying all required PHP extensions for WordPress..."
echo "✓ MySQL/MariaDB support (mysqli)"
php -m | grep -i mysqli && echo "  - INSTALLED" || echo "  - MISSING"
echo "✓ GD Graphics Library"
php -m | grep -i gd && echo "  - INSTALLED" || echo "  - MISSING"
echo "✓ cURL"
php -m | grep -i curl && echo "  - INSTALLED" || echo "  - MISSING"
echo "✓ mbstring"
php -m | grep -i mbstring && echo "  - INSTALLED" || echo "  - MISSING"
echo "✓ XML Processing"
php -m | grep -i xml && echo "  - INSTALLED" || echo "  - MISSING"
echo "✓ ZIP Compression"
php -m | grep -i zip && echo "  - INSTALLED" || echo "  - MISSING"

# Check PHP configuration file paths
echo "PHP configuration file paths:"
php -i | grep "Configuration File" || echo "Could not determine PHP configuration file locations."

echo "===================================================="
echo "PHP extension installation complete!"
echo "Please try accessing WordPress again."
echo "If you still see the error, you may need to restart your web server:"
echo "sudo systemctl restart lighttpd"
echo "===================================================="
