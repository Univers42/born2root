#!/bin/bash

echo "===================================================="
echo "WordPress AppArmor Configuration Script"
echo "===================================================="

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use sudo."
    exit 1
fi

# Step 1: Install AppArmor if needed
echo "Step 1: Installing AppArmor packages..."
apt-get update
apt-get install -y apparmor apparmor-utils

# Step 2: Enable AppArmor
echo "Step 2: Enabling AppArmor service..."
systemctl enable apparmor
systemctl start apparmor

# Step 3: Repair directory permissions
echo "Step 3: Setting proper directory permissions..."

# Log directories
mkdir -p /var/log/php /var/log/lighttpd
touch /var/log/php8.2-fpm.log
touch /var/log/lighttpd/error.log /var/log/lighttpd/access.log

# PHP Socket directory
mkdir -p /run/php

# Lighttpd upload directory
mkdir -p /var/cache/lighttpd/uploads

# Fix permissions
chown -R www-data:www-data /var/log/php /var/log/lighttpd /var/cache/lighttpd /run/php
chmod 755 /var/log/php /var/log/lighttpd /run/php /var/cache/lighttpd
chmod 644 /var/log/php8.2-fpm.log /var/log/lighttpd/*.log

# Step 4: Create temporary WordPress config test file
echo "Step 4: Creating WordPress AppArmor test file..."
cat >/var/www/html/apparmor-test.php <<'EOF'
<?php
echo "<h1>WordPress AppArmor Test Page</h1>";
echo "<p>This page tests WordPress functionality under AppArmor protection.</p>";

// Test writing to allowed locations
$test1 = file_put_contents('/tmp/wp-test.txt', 'Test file');
echo "<p>Write to /tmp: " . ($test1 ? "✓ Working" : "✗ Failed") . "</p>";

$test2 = file_put_contents('/var/www/html/wp-content/test.txt', 'Test file');
echo "<p>Write to wp-content: " . ($test2 ? "✓ Working" : "✗ Failed") . "</p>";

// Show server info
echo "<p>PHP version: " . phpversion() . "</p>";
echo "<p>Server software: " . $_SERVER['SERVER_SOFTWARE'] . "</p>";
?>
EOF
chown www-data:www-data /var/www/html/apparmor-test.php
chmod 644 /var/www/html/apparmor-test.php

# Step 5: Create PHP-FPM AppArmor profile
echo "Step 5: Creating PHP-FPM AppArmor profile..."
cat >/etc/apparmor.d/usr.sbin.php-fpm8.2 <<'EOF'
#include <tunables/global>

profile php-fpm8.2 /usr/sbin/php-fpm8.2 flags=(attach_disconnected) {
  #include <abstractions/base>
  #include <abstractions/php>
  #include <abstractions/nameservice>
  
  # PHP-FPM binary
  /usr/sbin/php-fpm8.2 rmix,
  
  # Config files
  /etc/php/** r,
  
  # Runtime files
  /run/php/** rwk,
  /run/php/php8.2-fpm.pid rwk,
  /run/php/php8.2-fpm.sock rwk,
  
  # Log files
  /var/log/php8.2-fpm.log rw,
  /var/log/php/** rw,
  
  # Web directories - allow read for all files
  /var/www/html/ r,
  /var/www/html/** r,
  
  # Web directories - allow write only to specific areas
  /var/www/html/wp-content/uploads/** rw,
  /var/www/html/wp-content/upgrade/** rw,
  /var/www/html/wp-content/plugins/** rw,
  /var/www/html/wp-content/themes/** rw,
  /var/www/html/wp-content/*.php rw,
  /var/www/html/wp-content/*.txt rw,
  
  # Temp files
  /tmp/** rwk,
  
  # Libraries
  /usr/lib{,32,64}/** rm,
  /lib{,32,64}/** rm,
  
  # System files - explicitly denied
  deny /etc/shadow r,
  deny /etc/passwd w,
  deny /etc/hosts w,
  deny /root/** rwlkmx,
  deny /home/** rwlkmx,
  
  # Required capabilities
  capability setgid,
  capability setuid,
  capability dac_override,
  
  # Device access
  /dev/urandom r,
  /dev/null rw,
}
EOF

# Step 6: Create Lighttpd AppArmor profile
echo "Step 6: Creating Lighttpd AppArmor profile..."
cat >/etc/apparmor.d/usr.sbin.lighttpd <<'EOF'
#include <tunables/global>

profile lighttpd /usr/sbin/lighttpd flags=(attach_disconnected) {
  #include <abstractions/base>
  #include <abstractions/nameservice>
  
  # Lighttpd binary
  /usr/sbin/lighttpd rmix,
  
  # Config files
  /etc/lighttpd/** r,
  
  # Web content
  /var/www/html/ r,
  /var/www/html/** r,
  
  # Log files
  /var/log/lighttpd/** rw,
  
  # Runtime files
  /run/lighttpd.pid rw,
  /var/run/lighttpd.pid rw,
  
  # Access PHP socket
  /run/php/php8.2-fpm.sock rw,
  
  # Upload directory
  /var/cache/lighttpd/** rwk,
  
  # System files - explicitly denied
  deny /etc/shadow r,
  deny /etc/passwd w,
  deny /etc/hosts w,
  deny /root/** rwlkmx,
  
  # Required capabilities
  capability setgid,
  capability setuid,
  capability net_bind_service,
  capability dac_override,
  
  # Libraries
  /usr/lib{,32,64}/** rm,
  /lib{,32,64}/** rm,
  
  # Device access
  /dev/urandom r,
  /dev/null rw,
}
EOF

# Step 7: Create MariaDB AppArmor profile
echo "Step 7: Creating MariaDB AppArmor profile..."
cat >/etc/apparmor.d/usr.sbin.mysqld <<'EOF'
#include <tunables/global>

profile mysqld /usr/sbin/mysqld flags=(attach_disconnected) {
  #include <abstractions/base>
  #include <abstractions/nameservice>
  #include <abstractions/mysql>
  
  # MySQL binary
  /usr/sbin/mysqld rmix,
  
  # Config files
  /etc/mysql/** r,
  
  # Data directory
  /var/lib/mysql/ r,
  /var/lib/mysql/** rwk,
  
  # Log files
  /var/log/mysql/ r,
  /var/log/mysql/** rw,
  
  # Runtime files
  /run/mysqld/ rw,
  /run/mysqld/** rwk,
  
  # Required capabilities
  capability setgid,
  capability setuid,
  capability dac_override,
  capability sys_resource,
  capability chown,
  
  # System files - explicitly denied
  deny /etc/shadow rwklmx,
  deny /etc/passwd wklmx,
  deny /root/** rwklmx,
  deny /home/** rwklmx,
  
  # Libraries
  /usr/lib{,32,64}/** rm,
  /lib{,32,64}/** rm,
  
  # Device access
  /dev/urandom r,
  /dev/null rw,
}
EOF

# Step 8: Load profiles in complain mode first
echo "Step 8: Loading profiles in complain mode for testing..."
aa-complain /etc/apparmor.d/usr.sbin.php-fpm8.2
aa-complain /etc/apparmor.d/usr.sbin.lighttpd
aa-complain /etc/apparmor.d/usr.sbin.mysqld

# Step 9: Restart services
echo "Step 9: Restarting services..."
systemctl restart php8.2-fpm
systemctl restart lighttpd
systemctl restart mariadb

# Step 10: Test services
echo "Step 10: Testing service status..."
php_status=$(systemctl is-active php8.2-fpm)
lighttpd_status=$(systemctl is-active lighttpd)
mysql_status=$(systemctl is-active mariadb)

if [ "$php_status" = "active" ] && [ "$lighttpd_status" = "active" ] && [ "$mysql_status" = "active" ]; then
    echo -e "\n✅ Initial setup successful! All services are running in complain mode."
    echo -e "Please visit http://YOUR_SERVER_IP/apparmor-test.php to verify functionality."
    echo -e "Then run the effectiveness test script to verify security and switch to enforce mode."
else
    echo -e "\n❌ Setup incomplete. One or more services failed to start."
    echo "PHP-FPM: $php_status"
    echo "Lighttpd: $lighttpd_status"
    echo "MariaDB: $mysql_status"
    echo -e "\nCheck service logs for details:"
    echo "  - sudo journalctl -xeu php8.2-fpm.service"
    echo "  - sudo journalctl -xeu lighttpd.service"
    echo "  - sudo journalctl -xeu mariadb.service"
fi

echo "===================================================="
echo "Configuration complete. AppArmor is now active in complain mode."
echo "Once you verify functionality, run the effectiveness test script."
echo "===================================================="
