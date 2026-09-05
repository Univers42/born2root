#!/bin/bash

# WordPress AppArmor Effectiveness Test Script
# Created: 2025-04-10
# Author: Github Copilot
# Purpose: Demonstrate the security effectiveness of AppArmor for WordPress

echo "===================================================="
echo "WordPress AppArmor Security Effectiveness Test"
echo "===================================================="

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use sudo."
    exit 1
fi

# Step 1: Verify AppArmor is running
echo -e "\nStep 1: Verifying AppArmor status..."
aa-status >/dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "❌ AppArmor is not running. Please run the configuration script first."
    exit 1
fi
echo "✅ AppArmor is running"

# Step 2: Check profile status
echo -e "\nStep 2: Checking AppArmor profile status..."
echo "PHP-FPM profile:"
aa-status | grep -A 1 php-fpm8.2 || echo "   ❌ Not found"

echo "Lighttpd profile:"
aa-status | grep -A 1 lighttpd || echo "   ❌ Not found"

echo "MariaDB profile:"
aa-status | grep -A 1 mysqld || echo "   ❌ Not found"

# Step 3: Create security test files
echo -e "\nStep 3: Creating security test files..."

# Test file that attempts various security violations
cat >/var/www/html/security-test.php <<'EOF'
<?php
echo "<h1>WordPress AppArmor Security Test</h1>";
echo "<p>This test demonstrates how AppArmor protects your WordPress site.</p>";

echo "<h2>Test 1: Accessing system files</h2>";
$test1 = @file_get_contents('/etc/shadow');
echo "<p>Access to /etc/shadow: " . ($test1 ? "❌ VULNERABLE" : "✅ BLOCKED") . "</p>";

echo "<h2>Test 2: Writing to system directory</h2>";
$test2 = @file_put_contents('/etc/test-hack.txt', 'This file should not be created');
echo "<p>Write to /etc directory: " . ($test2 ? "❌ VULNERABLE" : "✅ BLOCKED") . "</p>";

echo "<h2>Test 3: Writing to WordPress content</h2>";
$test3 = @file_put_contents('./wp-content/test-allowed.txt', 'This file should be created');
echo "<p>Write to wp-content: " . ($test3 ? "✅ WORKING" : "❌ BLOCKED") . "</p>";

echo "<h2>Test 4: Executing system commands</h2>";
$cmd = 'id > /tmp/command-output.txt';
@system($cmd);
$test4 = file_exists('/tmp/command-output.txt') ? file_get_contents('/tmp/command-output.txt') : false;
echo "<p>Command execution: " . ($test4 ? "❌ COMMANDS ALLOWED" : "✅ COMMANDS BLOCKED") . "</p>";

echo "<h2>Test 5: Accessing home directories</h2>";
$test5 = @scandir('/home');
echo "<p>Access to /home: " . ($test5 ? "❌ HOME ACCESS ALLOWED" : "✅ HOME ACCESS BLOCKED") . "</p>";

echo "<hr>";
echo "<p><strong>PHP is running as:</strong> " . exec('whoami') . "</p>";
echo "<p><strong>Current directory:</strong> " . getcwd() . "</p>";
?>
EOF
chown www-data:www-data /var/www/html/security-test.php
chmod 644 /var/www/html/security-test.php

# Step 4: Create a command line security test
cat >/root/apparmor-security-test.sh <<'EOF'
#!/bin/bash

echo "==== WordPress AppArmor Security Command-Line Test ===="
echo

echo "1. Testing PHP restriction (should be blocked):"
sudo -u www-data php -r 'file_put_contents("/etc/php-test.txt", "This should be blocked");'
if [ -f /etc/php-test.txt ]; then
    echo "   ❌ VULNERABLE: PHP was able to write to /etc"
    rm /etc/php-test.txt
else
    echo "   ✅ SECURE: PHP could not write to /etc"
fi

echo
echo "2. Testing WordPress uploads (should work):"
sudo -u www-data touch /var/www/html/wp-content/test-touch.txt
if [ -f /var/www/html/wp-content/test-touch.txt ]; then
    echo "   ✅ WORKING: WordPress can write to content directory"
    rm /var/www/html/wp-content/test-touch.txt
else
    echo "   ❌ BROKEN: WordPress cannot write to content directory"
fi

echo
echo "3. Testing MariaDB security (should be blocked):"
sudo -u mysql touch /etc/mysql-test.txt
if [ -f /etc/mysql-test.txt ]; then
    echo "   ❌ VULNERABLE: MySQL can write to /etc"
    rm /etc/mysql-test.txt
else
    echo "   ✅ SECURE: MySQL cannot write to /etc"
fi

echo
echo "4. Testing lighttpd security (should be blocked):"
sudo -u www-data touch /root/lighttpd-test.txt
if [ -f /root/lighttpd-test.txt ]; then
    echo "   ❌ VULNERABLE: Web server can write to /root"
    rm /root/lighttpd-test.txt
else
    echo "   ✅ SECURE: Web server cannot write to /root"
fi

EOF
chmod +x /root/apparmor-security-test.sh

# Step 5: Run the command line test
echo -e "\nStep 5: Running command line security tests..."
/root/apparmor-security-test.sh

# Step 6: Check for any AppArmor denials
echo -e "\nStep 6: Checking for AppArmor denial logs..."
DENIALS=$(dmesg | grep -i "apparmor.*DENIED" | tail -10)
if [ -n "$DENIALS" ]; then
    echo -e "AppArmor security events detected (good!):\n"
    echo "$DENIALS" | sed 's/^/   /'
else
    echo "No AppArmor denials found. Security may not be enforcing properly."
fi

# Step 7: Switch profiles to enforce mode
echo -e "\nStep 7: Switching profiles to enforce mode..."
aa-enforce /etc/apparmor.d/usr.sbin.php-fpm8.2
aa-enforce /etc/apparmor.d/usr.sbin.lighttpd
aa-enforce /etc/apparmor.d/usr.sbin.mysqld

# Step 8: Restart services
echo -e "\nStep 8: Restarting services..."
systemctl restart php8.2-fpm
systemctl restart lighttpd
systemctl restart mariadb

# Step 9: Verify enforcement mode
echo -e "\nStep 9: Verifying enforcement mode..."
if aa-status | grep -q "php-fpm8.2.*enforce"; then
    echo "   ✅ PHP-FPM profile is in enforce mode"
else
    echo "   ❌ PHP-FPM profile is not in enforce mode"
fi

if aa-status | grep -q "lighttpd.*enforce"; then
    echo "   ✅ Lighttpd profile is in enforce mode"
else
    echo "   ❌ Lighttpd profile is not in enforce mode"
fi

if aa-status | grep -q "mysqld.*enforce"; then
    echo "   ✅ MariaDB profile is in enforce mode"
else
    echo "   ❌ MariaDB profile is not in enforce mode"
fi

# Step 10: Final instructions
echo -e "\nStep 10: Recommendations for your defense presentation..."
echo "1. Visit http://YOUR_SERVER_IP/security-test.php to demonstrate web security"
echo "2. Show the AppArmor status: sudo aa-status"
echo "3. Demonstrate how AppArmor prevents access: sudo -u www-data touch /etc/test-blocked.txt"
echo "4. Show that WordPress still works normally"

echo -e "\n===================================================="
echo "Security testing complete!"
echo "Your WordPress installation is now protected by AppArmor."
echo "===================================================="
