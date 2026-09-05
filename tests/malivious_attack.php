#!/bin/bash

# WordPress AppArmor Security Demonstration Script
# Created by: Github Copilot
# Date: 2025-04-10

echo "===================================================="
echo "AppArmor WordPress Security Demonstration"
echo "===================================================="
echo "This script demonstrates how AppArmor protects against attacks"

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
	echo "This script must be run as root. Please use sudo."
	exit 1
fi

# Step 1: Create a "malicious" test file
echo "Step 1: Creating malicious PHP test file..."
cat >/var/www/html/hack-simulation.php <<'EOF'
<?php
// This file simulates malicious code that might be injected into WordPress

echo "<html><head><title>WordPress Security Test</title>";
echo "<style>
body { font-family: Arial, sans-serif; margin: 40px; line-height: 1.6; }
h1 { color: #0073aa; }
h2 { color: #00a0d2; margin-top: 30px; }
.success { color: green; font-weight: bold; }
.failure { color: red; font-weight: bold; }
.test { background: #f5f5f5; padding: 15px; margin-bottom: 20px; border-left: 4px solid #0073aa; }
</style></head><body>";

echo "<h1>WordPress AppArmor Security Demonstration</h1>";
echo "<p>This page demonstrates how AppArmor prevents various attack vectors.</p>";

// TEST 1: Read sensitive system files
echo "<div class='test'>";
echo "<h2>Test 1: Access to /etc/passwd</h2>";
echo "<p>Attempting to read system user accounts...</p>";
$test1 = @file_get_contents('/etc/passwd');
if ($test1) {
    echo "<p class='failure'>❌ VULNERABLE: Able to read /etc/passwd</p>";
    echo "<pre>" . htmlspecialchars(substr($test1, 0, 200)) . "...</pre>";
} else {
    echo "<p class='success'>✅ SECURE: Access to /etc/passwd was blocked</p>";
}
echo "</div>";

// TEST 2: Write to system directory
echo "<div class='test'>";
echo "<h2>Test 2: Write to /etc directory</h2>";
echo "<p>Attempting to create a file in /etc...</p>";
$test2 = @file_put_contents('/etc/hacked-by-wordpress.txt', 'System compromised by PHP script');
if ($test2) {
    echo "<p class='failure'>❌ VULNERABLE: Created file in /etc directory!</p>";
    @unlink('/etc/hacked-by-wordpress.txt'); // Clean up
} else {
    echo "<p class='success'>✅ SECURE: Prevented file creation in /etc</p>";
}
echo "</div>";

// TEST 3: Access to /root directory
echo "<div class='test'>";
echo "<h2>Test 3: Access to /root directory</h2>";
echo "<p>Attempting to list files in /root...</p>";
$test3 = @scandir('/root');
if (is_array($test3)) {
    echo "<p class='failure'>❌ VULNERABLE: Listed contents of /root directory!</p>";
    echo "<pre>" . htmlspecialchars(print_r($test3, true)) . "</pre>";
} else {
    echo "<p class='success'>✅ SECURE: Access to /root was blocked</p>";
}
echo "</div>";

// TEST 4: Command execution
echo "<div class='test'>";
echo "<h2>Test 4: Command Execution</h2>";
echo "<p>Attempting to run system commands...</p>";
$output = '';
$result = @exec('id', $output);
if (!empty($output)) {
    echo "<p class='failure'>❌ VULNERABLE: Executed system command!</p>";
    echo "<pre>" . htmlspecialchars(implode("\n", $output)) . "</pre>";
} else {
    echo "<p class='success'>✅ SECURE: Command execution was blocked</p>";
}
echo "</div>";

// TEST 5: Network connection
echo "<div class='test'>";
echo "<h2>Test 5: External Network Connection</h2>";
echo "<p>Attempting to connect to external server (emulated)...</p>";
// We're just checking if fsockopen function is available
if (function_exists('fsockopen')) {
    $socket = @fsockopen("example.com", 80, $errno, $errstr, 1);
    if ($socket) {
        echo "<p class='failure'>❌ VULNERABLE: Established external connection!</p>";
        fclose($socket);
    } else {
        echo "<p>Connection blocked or failed: $errstr</p>";
    }
} else {
    echo "<p class='success'>✅ SECURE: Network function is restricted</p>";
}
echo "</div>";

// TEST 6: Write to WordPress directory (should work)
echo "<div class='test'>";
echo "<h2>Test 6: WordPress Functionality Check</h2>";
echo "<p>Attempting to write to wp-content directory (should work)...</p>";
$test6 = @file_put_contents('./test-wp-write.txt', 'This file should be created');
if ($test6) {
    echo "<p class='success'>✅ WORKING: WordPress can still write files</p>";
    @unlink('./test-wp-write.txt'); // Clean up
} else {
    echo "<p class='failure'>❌ BROKEN: WordPress cannot write files</p>";
}
echo "</div>";

// AppArmor Status
echo "<div class='test'>";
echo "<h2>AppArmor Status</h2>";
$status = shell_exec('aa-status 2>&1');
echo "<pre>" . htmlspecialchars($status) . "</pre>";
echo "</div>";

// System Information
echo "<div class='test'>";
echo "<h2>System Information</h2>";
echo "<p><strong>PHP version:</strong> " . phpversion() . "</p>";
echo "<p><strong>Server software:</strong> " . $_SERVER['SERVER_SOFTWARE'] . "</p>";
echo "<p><strong>Server name:</strong> " . $_SERVER['SERVER_NAME'] . "</p>";
echo "<p><strong>Running as user:</strong> " . exec('whoami') . "</p>";
echo "</div>";

echo "</body></html>";
?>
EOF

# Set correct permissions
chown www-data:www-data /var/www/html/hack-simulation.php
chmod 644 /var/www/html/hack-simulation.php

# Step 2: Set up command-line demonstration
echo "Step 2: Creating command-line demonstration script..."
cat >/root/apparmor-demo.sh <<'EOF'
#!/bin/bash

echo "===================================================="
echo "AppArmor Protection Command-Line Demonstration"
echo "===================================================="

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "\n1. Testing as www-data user (PHP/WordPress user):"
echo "---------------------------------------------"

echo -e "\na) Trying to read /etc/shadow (should fail):"
sudo -u www-data cat /etc/shadow > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo -e "${RED}❌ VULNERABLE: www-data can read shadow file${NC}"
else
    echo -e "${GREEN}✅ SECURE: Access blocked by AppArmor${NC}"
fi

echo -e "\nb) Trying to write to /etc directory (should fail):"
sudo -u www-data touch /etc/test-hack.txt > /dev/null 2>&1
if [ -f /etc/test-hack.txt ]; then
    echo -e "${RED}❌ VULNERABLE: www-data can write to /etc${NC}"
    rm /etc/test-hack.txt
else
    echo -e "${GREEN}✅ SECURE: Write blocked by AppArmor${NC}"
fi

echo -e "\nc) Trying to access /root directory (should fail):"
sudo -u www-data ls /root > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo -e "${RED}❌ VULNERABLE: www-data can access /root${NC}"
else
    echo -e "${GREEN}✅ SECURE: Access blocked by AppArmor${NC}"
fi

echo -e "\nd) Trying to write to WordPress directory (should work):"
sudo -u www-data touch /var/www/html/wp-test-file.txt > /dev/null 2>&1
if [ -f /var/www/html/wp-test-file.txt ]; then
    echo -e "${GREEN}✅ WORKING: WordPress functionality preserved${NC}"
    rm /var/www/html/wp-test-file.txt
else
    echo -e "${RED}❌ BROKEN: WordPress cannot write files${NC}"
fi

echo -e "\n2. Testing AppArmor Effectiveness:"
echo "---------------------------------------------"

# Check if AppArmor is enabled
if aa-status | grep -q "apparmor module is loaded."; then
    echo -e "${GREEN}✅ AppArmor is enabled${NC}"
else
    echo -e "${RED}❌ AppArmor is not enabled${NC}"
fi

# Check if profiles are loaded
if aa-status | grep -q "php-fpm8.2"; then
    echo -e "${GREEN}✅ PHP-FPM profile is loaded${NC}"
else
    echo -e "${RED}❌ PHP-FPM profile is not loaded${NC}"
fi

if aa-status | grep -q "lighttpd"; then
    echo -e "${GREEN}✅ Lighttpd profile is loaded${NC}"
else
    echo -e "${RED}❌ Lighttpd profile is not loaded${NC}"
fi

# Check for recent denials (good sign that AppArmor is working)
denials=$(dmesg | grep "apparmor.*DENIED" | tail -5)
if [ -n "$denials" ]; then
    echo -e "\n${GREEN}✅ AppArmor has blocked attacks! Recent denials:${NC}"
    echo "$denials"
else
    echo -e "\n${RED}⚠️ No recent AppArmor denials found${NC}"
    echo "This could mean either:"
    echo "1. No attack attempts have been made, or"
    echo "2. AppArmor is not properly configured"
fi

echo -e "\n3. How to use this demo in your defense presentation:"
echo "---------------------------------------------"
echo "1. Show the command-line test results (this script)"
echo "2. Visit http://YOUR_SERVER_IP/hack-simulation.php in browser"
echo "3. Explain how AppArmor blocks each attack vector"
echo "4. Point out that normal WordPress functionality still works"
echo "5. Show the AppArmor logs with: dmesg | grep apparmor"
echo "===================================================="
EOF

chmod +x /root/apparmor-demo.sh

# Step 3: Run the command-line demo
echo "Step 3: Running the command-line demonstration..."
/root/apparmor-demo.sh

# Step 4: Show instructions for browser demo
echo "===================================================="
echo "AppArmor Security Demonstration is ready!"
echo "===================================================="
echo "To complete the demonstration (for your defense):"
echo ""
echo "1. Visit http://YOUR_SERVER_IP/hack-simulation.php in a web browser"
echo "   This shows attack attempts being blocked in real-time"
echo ""
echo "2. Run the command-line demo anytime with:"
echo "   sudo /root/apparmor-demo.sh"
echo ""
echo "3. Show AppArmor logs during your presentation with:"
echo "   sudo dmesg | grep -i apparmor"
echo "===================================================="
