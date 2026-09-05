#!/bin/bash

# WordPress AppArmor Repair Script
echo "===================================================="
echo "WordPress AppArmor Repair Script"
echo "===================================================="

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use sudo."
    exit 1
fi

# Step 1: Disable AppArmor profiles temporarily
echo "Step 1: Disabling problematic AppArmor profiles..."
aa-disable /etc/apparmor.d/usr.sbin.php-fpm8.2 2>/dev/null || true
aa-disable /etc/apparmor.d/usr.sbin.lighttpd 2>/dev/null || true

# Step 2: Fix log permissions
echo "Step 2: Fixing log permissions..."
mkdir -p /var/log/php
touch /var/log/php8.2-fpm.log
chown -R www-data:www-data /var/log/php /var/log/php8.2-fpm.log
chmod 755 /var/log/php
chmod 644 /var/log/php8.2-fpm.log

mkdir -p /var/log/lighttpd
touch /var/log/lighttpd/error.log /var/log/lighttpd/access.log
chown -R www-data:www-data /var/log/lighttpd
chmod 755 /var/log/lighttpd
chmod 644 /var/log/lighttpd/*.log

# Step 3: Create proper AppArmor profiles
echo "Step 3: Creating fixed AppArmor profiles..."

cat >/etc/apparmor.d/usr.sbin.php-fpm8.2 <<'EOF'
#include <tunables/global>

profile php-fpm8.2 /usr/sbin/php-fpm8.2 flags=(attach_disconnected, complain) {
  #include <abstractions/base>
  #include <abstractions/php>
  #include <abstractions/nameservice>
  
  capability,
  network,
  
  # PHP-FPM binary
  /usr/sbin/php-fpm8.2 rmix,
  
  # Config files
  /etc/php/** r,
  
  # Runtime files
  /run/php/** rwk,
  /run/php/php8.2-fpm.pid rwk,
  /run/php/php8.2-fpm.sock rwk,
  
  # Log files - critical fix
  /var/log/php8.2-fpm.log rw,
  /var/log/php/** rw,
  
  # Web directories
  /var/www/** rw,
  
  # Temp files
  /tmp/** rwk,
  
  # Libraries
  /usr/lib{,32,64}/** rm,
  /lib{,32,64}/** rm,
  
  # Device access
  /dev/tty rw,
  /dev/pts/* rw,
  /dev/urandom r,
  /dev/null rw,
}
EOF

cat >/etc/apparmor.d/usr.sbin.lighttpd <<'EOF'
#include <tunables/global>

profile lighttpd /usr/sbin/lighttpd flags=(attach_disconnected, complain) {
  #include <abstractions/base>
  #include <abstractions/nameservice>
  
  capability,
  network,
  
  # Lighttpd binary
  /usr/sbin/lighttpd rmix,
  
  # Config files
  /etc/lighttpd/** r,
  
  # Web content
  /var/www/** r,
  
  # Log files - critical fix
  /var/log/lighttpd/** rw,
  
  # Runtime files
  /run/lighttpd.pid rw,
  /run/** rw,
  
  # Access PHP socket
  /run/php/php8.2-fpm.sock rw,
  
  # Upload directory
  /var/cache/lighttpd/** rwk,
  
  # Libraries
  /usr/lib{,32,64}/** rm,
  /lib{,32,64}/** rm,
  
  # Device access
  /dev/tty rw,
  /dev/pts/* rw,
  /dev/urandom r,
  /dev/null rw,
}
EOF

# Step 4: Fix socket directory permissions
echo "Step 4: Fixing PHP-FPM socket directory permissions..."
mkdir -p /run/php
chown www-data:www-data /run/php
chmod 755 /run/php

# Step 5: Fix Lighttpd upload directory
echo "Step 5: Fixing Lighttpd upload directory permissions..."
mkdir -p /var/cache/lighttpd/uploads
chown -R www-data:www-data /var/cache/lighttpd
chmod -R 755 /var/cache/lighttpd

# Step 6: Load fixed AppArmor profiles in complain mode
echo "Step 6: Loading fixed AppArmor profiles in complain mode..."
apparmor_parser -r /etc/apparmor.d/usr.sbin.php-fpm8.2
apparmor_parser -r /etc/apparmor.d/usr.sbin.lighttpd

# Step 7: Restart services
echo "Step 7: Restarting PHP-FPM and Lighttpd services..."
systemctl restart php8.2-fpm
systemctl restart lighttpd

# Step 8: Check service status
echo "Step 8: Checking service status..."
php_status=$(systemctl is-active php8.2-fpm)
lighttpd_status=$(systemctl is-active lighttpd)

echo "PHP-FPM service status: $php_status"
echo "Lighttpd service status: $lighttpd_status"

if [ "$php_status" = "active" ] && [ "$lighttpd_status" = "active" ]; then
    echo -e "\n✅ REPAIR SUCCESSFUL: Both services are running!"

    # Create a test file to verify PHP is working
    cat >/var/www/html/repair-test.php <<'EOF'
<?php
echo "<h1>WordPress AppArmor Repair Test</h1>";
echo "<p>If you can see this, PHP is working correctly!</p>";
echo "<p>Current time: " . date('Y-m-d H:i:s') . "</p>";
echo "<p>PHP version: " . phpversion() . "</p>";
echo "<p>Server software: " . $_SERVER['SERVER_SOFTWARE'] . "</p>";

echo "<h2>AppArmor Status</h2>";
echo "<pre>";
$output = shell_exec('aa-status 2>&1');
echo htmlspecialchars($output);
echo "</pre>";
?>
EOF
    chown www-data:www-data /var/www/html/repair-test.php

    echo -e "\nPlease visit http://YOUR_SERVER_IP/repair-test.php to verify PHP is working."
    echo "You can then complete your WordPress installation."
else
    echo -e "\n❌ REPAIR INCOMPLETE: One or both services are still not running."
    echo "Please check the logs for more information:"
    echo "  - sudo journalctl -xeu php8.2-fpm.service"
    echo "  - sudo journalctl -xeu lighttpd.service"
fi

echo "===================================================="
