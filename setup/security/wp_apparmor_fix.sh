#!/bin/bash

# WordPress AppArmor Troubleshooting Script
echo "===================================================="
echo "WordPress Services Troubleshooting Script"
echo "===================================================="

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use sudo."
    exit 1
fi

# Step 1: Disable AppArmor profiles
echo "Step 1: Removing AppArmor profiles temporarily..."
aa-disable usr.sbin.php-fpm8.2 2>/dev/null || true
aa-disable usr.sbin.lighttpd 2>/dev/null || true
aa-disable usr.sbin.mysqld 2>/dev/null || true

# Alternative method to remove profiles
apparmor_parser -R /etc/apparmor.d/usr.sbin.php-fpm8.2 2>/dev/null || true
apparmor_parser -R /etc/apparmor.d/usr.sbin.lighttpd 2>/dev/null || true
apparmor_parser -R /etc/apparmor.d/usr.sbin.mysqld 2>/dev/null || true

# Step 2: Check for configuration errors
echo "Step 2: Checking for configuration errors..."

# PHP-FPM configuration test
echo "Testing PHP-FPM configuration..."
php-fpm8.2 -t
if [ $? -ne 0 ]; then
    echo "❌ PHP-FPM configuration has errors"
else
    echo "✅ PHP-FPM configuration is valid"
fi

# Lighttpd configuration test
echo "Testing Lighttpd configuration..."
lighttpd -t -f /etc/lighttpd/lighttpd.conf
if [ $? -ne 0 ]; then
    echo "❌ Lighttpd configuration has errors"
else
    echo "✅ Lighttpd configuration is valid"
fi

# Step 3: Fix permissions thoroughly
echo "Step 3: Fixing permissions thoroughly..."

# Fix PHP-FPM permissions
echo "Fixing PHP-FPM directories and files..."
mkdir -p /var/log/php
touch /var/log/php8.2-fpm.log
mkdir -p /run/php
chown -R www-data:www-data /var/log/php /var/log/php8.2-fpm.log /run/php
chmod 755 /var/log/php /run/php
chmod 644 /var/log/php8.2-fpm.log

# Fix Lighttpd permissions
echo "Fixing Lighttpd directories and files..."
mkdir -p /var/log/lighttpd
touch /var/log/lighttpd/error.log /var/log/lighttpd/access.log
mkdir -p /var/cache/lighttpd/uploads
chown -R www-data:www-data /var/log/lighttpd /var/cache/lighttpd
chmod 755 /var/log/lighttpd /var/cache/lighttpd
chmod 644 /var/log/lighttpd/*.log

# Fix WordPress directories
echo "Fixing WordPress directories..."
mkdir -p /var/www/html/wp-content
chown -R www-data:www-data /var/www/html
chmod -R 755 /var/www/html

# Step 4: Clean up any stale socket files
echo "Step 4: Cleaning up stale socket files..."
rm -f /run/php/php8.2-fpm.sock 2>/dev/null || true
rm -f /run/lighttpd.pid 2>/dev/null || true

# Step 5: Restart services one by one
echo "Step 5: Restarting services one by one..."

echo "Starting PHP-FPM..."
systemctl restart php8.2-fpm
if [ $? -ne 0 ]; then
    echo "❌ PHP-FPM failed to start"
    echo "--- PHP-FPM service status ---"
    systemctl status php8.2-fpm --no-pager
    echo "--- PHP-FPM logs ---"
    journalctl -xeu php8.2-fpm.service --no-pager | tail -20
else
    echo "✅ PHP-FPM started successfully"
fi

echo "Starting Lighttpd..."
systemctl restart lighttpd
if [ $? -ne 0 ]; then
    echo "❌ Lighttpd failed to start"
    echo "--- Lighttpd service status ---"
    systemctl status lighttpd --no-pager
    echo "--- Lighttpd logs ---"
    journalctl -xeu lighttpd.service --no-pager | tail -20
else
    echo "✅ Lighttpd started successfully"
fi

echo "Starting MariaDB..."
systemctl restart mariadb
if [ $? -ne 0 ]; then
    echo "❌ MariaDB failed to start"
else
    echo "✅ MariaDB started successfully"
fi

# Step 6: Create a basic PHP test file
echo "Step 6: Creating basic PHP test file..."
cat >/var/www/html/phpinfo.php <<'EOF'
<?php
phpinfo();
EOF
chown www-data:www-data /var/www/html/phpinfo.php
chmod 644 /var/www/html/phpinfo.php

# Step 7: Verify services are running
echo "Step 7: Verifying services..."
echo "PHP-FPM status: $(systemctl is-active php8.2-fpm)"
echo "Lighttpd status: $(systemctl is-active lighttpd)"
echo "MariaDB status: $(systemctl is-active mariadb)"

# Step 8: Create simpler AppArmor profiles
echo "Step 8: Creating simpler AppArmor profiles in complain mode..."

cat >/etc/apparmor.d/usr.sbin.php-fpm8.2 <<'EOF'
#include <tunables/global>

profile php-fpm8.2 /usr/sbin/php-fpm8.2 flags=(attach_disconnected) {
  #include <abstractions/base>
  #include <abstractions/nameservice>
  
  capability,
  
  /usr/sbin/php-fpm8.2 r,
  /usr/sbin/php-fpm8.2 ix,
  
  /etc/** r,
  /proc/** r,
  /var/** rw,
  /tmp/** rw,
  /run/** rw,
  
  /usr/lib{,32,64}/** rm,
  /lib{,32,64}/** rm,
  
  /dev/urandom r,
  /dev/null rw,
}
EOF

cat >/etc/apparmor.d/usr.sbin.lighttpd <<'EOF'
#include <tunables/global>

profile lighttpd /usr/sbin/lighttpd flags=(attach_disconnected) {
  #include <abstractions/base>
  #include <abstractions/nameservice>
  
  capability,
  
  /usr/sbin/lighttpd r,
  /usr/sbin/lighttpd ix,
  
  /etc/** r,
  /var/** rw,
  /run/** rw,
  
  /usr/lib{,32,64}/** rm,
  /lib{,32,64}/** rm,
  
  /dev/urandom r,
  /dev/null rw,
}
EOF

echo "Step 9: Only if services are running, try loading simplified AppArmor profiles..."
if [ "$(systemctl is-active php8.2-fpm)" = "active" ] && [ "$(systemctl is-active lighttpd)" = "active" ]; then
    echo "Loading profiles in complain mode..."
    aa-complain /etc/apparmor.d/usr.sbin.php-fpm8.2
    aa-complain /etc/apparmor.d/usr.sbin.lighttpd

    echo "Restarting services again..."
    systemctl restart php8.2-fpm
    systemctl restart lighttpd

    echo "Final status check:"
    echo "PHP-FPM status: $(systemctl is-active php8.2-fpm)"
    echo "Lighttpd status: $(systemctl is-active lighttpd)"

    echo -e "\n✅ Next step: visit http://YOUR_SERVER_IP/phpinfo.php to verify PHP is working"
    echo "If everything works, you can gradually tighten the AppArmor profiles"
else
    echo -e "\n❌ Services are not running. Skip loading AppArmor profiles for now."
    echo "Fix the basic service configuration first, then reintroduce AppArmor."
fi

echo "===================================================="
