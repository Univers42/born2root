# ============================================================================

#

## FILE HEADER

## ----------------------------------------------------------------------------

## File: README.md

## Author: dlesieur

## Email: <dlesieur@student.42.fr>

## Created: 2025/11/09 19:07:56

## Updated: 2025/11/09 19:07:56

#

## ============================================================================

## Basic System Management and Information

```bash
uname -a        # Display system information
hostname        # Display system hostname
honstname -I    # Display system IP addresses
lsblk           # List block devices (check partitions)
df -h           # Check disk space usage
free -m         # Monitor system processes
top             # Enhanced memory usage
htop            # Enhanced version of top (if installed)
who             # Show who is logged in
last            # Show last logins
uptime          # Show system uptime
```

## User & Group Management

```bash
## User Management
sudo adduser <username>             # Create a new user
sudo userdel -r <username>          # Delete user and home directory
sudo usermod -aG <group> <username> # Add user to a group
sudo passwd <username>              # Change user password
getent passwd                       # List all users
id <username>                       # Show user's UID, GID and groups

## Group management
sudo groupadd <groupname>           # Create a new group
sudo groupdel <groupname>           # Delete a group
getent group                        # List all groups
```

## LVM (Logical Volume Management)

```bash
## LVM commands
pvs                                  # Display physical volumes
pvdisplay                           # Detailed info about physical volumes
vgs                                  # Display volume groups
vgdisplay                           # Detailed info about volume groups
lvs                                  # Display logical volumes
lvdisplay                           # Detailed info about logical volumes

## Create/extend logical volumes
sudo pvcreate /dev/sda1              # Create physical volume
sudo vgcreate volume_group /dev/sda1 # Create volume group
sudo lvcreate -L 1G -n logical_vol volume_group  # Create logical volume
sudo lvextend -L +1G /dev/volume_group/logical_vol  # Extend logical volume
sudo resize2fs /dev/volume_group/logical_vol  # Resize filesystem after extending
```

## Sudo Configuration

```bash
sudo visudo                        # Edit sudoers file safely
sudo grep -E 'auth|log' /etc/sudoers  # Check sudo log settings

## View sudo logs
sudo cat /var/log/sudo/sudo.log    # View sudo logs (location may vary)
```

## Firewall Management (UFW)

```bash
## UFW management
sudo apt install ufw                # Install UFW if needed
sudo ufw status                     # Check UFW status
sudo ufw status verbose             # Detailed UFW status
sudo ufw enable                     # Enable UFW
sudo ufw disable                    # Disable UFW
sudo ufw allow <port>               # Allow port
sudo ufw deny <port>                # Deny port
sudo ufw delete <rule number>       # Delete rule by number
sudo ufw reset                      # Reset all UFW rules

## Examples for the project
sudo ufw allow 4242                 # Allow SSH on port 4242
sudo ufw allow 80                   # Allow HTTP for bonus
sudo ufw allow 443                  # Allow HTTPS for bonus
```

## SSH Configuration

```bash
## SSH management
sudo apt install openssh-server     # Install SSH if needed
sudo systemctl status ssh           # Check SSH service status
sudo systemctl start ssh            # Start SSH service
sudo systemctl stop ssh             # Stop SSH service
sudo systemctl enable ssh           # Enable SSH at boot
sudo systemctl disable ssh          # Disable SSH at boot

## Configure SSH
sudo vim /etc/ssh/sshd_config       # Edit SSH config file
## Change these settings in the file:
## Port 4242
## PermitRootLogin no
## PasswordAuthentication yes (or no for key-based auth)

sudo systemctl restart ssh          # Apply SSH configuration changes

## Connect to SSH
ssh username@ip_address -p 4242     # Connect to SSH on port 4242
```

## Password Policy Configuration

```bash
sudo apt install libpam-pwquality   # Install password quality tools
sudo vim /etc/login.defs            # Configure password expiration
## Set these values:
## PASS_MAX_DAYS 30
## PASS_MIN_DAYS 2
## PASS_WARN_AGE 7

sudo vim /etc/pam.d/common-password  # Configure password complexity
## Add to the pwquality line:
## minlen=10 ucredit=-1 lcredit=-1 dcredit=-1 maxrepeat=3 reject_username difok=7 enforce_for_root
```

## Managin Cron Jobs (for monitoring script)

```bash
sudo crontab -e                     # Edit crontab for root
## Add this line for monitoring script every 10 minutes:
## */10 * * * * /path/to/monitoring.sh

sudo crontab -l                     # List crontab for root
```

## System Services Management

```bash
systemctl list-units --type=service         # List all services
sudo systemctl status <service>             # Check service status
sudo systemctl start <service>              # Start a service
sudo systemctl stop <service>               # Stop a service
sudo systemctl enable <service>             # Enable service at boot
sudo systemctl disable <service>            # Disable service at boot
sudo systemctl restart <service>            # Restart a service
```

## Network Management

```bash
ip a                                # Show network interfaces
ip route                            # Show routing table
netstat -tuln                       # Show active connections and ports
ss -tuln                            # Modern alternative to netstat
ping <hostname/IP>                  # Check connectivity to a host
traceroute <hostname/IP>            # Trace route to a host
```

## Package Management ( for Debian/Ubuntu )

```bash
sudo apt update                     # Update package list
sudo apt upgrade                    # Upgrade packages
sudo apt install <package>          # Install a package
sudo apt remove <package>           # Remove a package
sudo apt autoremove                 # Remove unused dependencies
apt list --installed                # List installed packages
dpkg -l | grep <package>            # Search for installed package
```

## For bonus: Wordpress with lighttpd, MariaDB, PHP

```bash
## Install LAMP stack for WordPress
sudo apt install lighttpd mariadb-server php php-cli php-fpm php-mysql php-json php-curl php-gd php-mbstring php-xml php-xmlrpc php-zip

## Configure lighttpd
sudo systemctl start lighttpd
sudo systemctl enable lighttpd
sudo ufw allow 80/tcp
sudo lighttpd-enable-mod fastcgi
sudo lighttpd-enable-mod fastcgi-php
sudo systemctl restart lighttpd

## Configure MariaDB
sudo mysql_secure_installation
sudo mysql -u root -p
CREATE DATABASE wordpress;
CREATE USER 'wpuser'@'localhost' IDENTIFIED BY 'password';
GRANT ALL PRIVILEGES ON wordpress.* TO 'wpuser'@'localhost';
FLUSH PRIVILEGES;
EXIT;

## Install WordPress
cd /var/www/html
sudo wget https://wordpress.org/latest.tar.gz
sudo tar -xvzf latest.tar.gz
sudo rm latest.tar.gz
sudo chown -R www-data:www-data /var/www/html/wordpress
sudo chmod -R 755 /var/www/html/wordpress
```

## For Bonus: Additional Service (FTP)

```bash
## Install and configure FTP
sudo apt install vsftpd
sudo vim /etc/vsftpd.conf
## Configure with:
## anonymous_enable=NO
## local_enable=YES
## write_enable=YES
## chroot_local_user=YES

sudo systemctl restart vsftpd
sudo systemctl enable vsftpd
sudo ufw allow 21/tcp
```

## Monitoring Scripts Components

```bash
#!/bin/bash

## Architecture and kernel info
arch=$(uname -a)

## CPU physical cores
cpu_physical=$(grep "physical id" /proc/cpuinfo | sort | uniq | wc -l)

## CPU virtual cores
cpu_virtual=$(grep "processor" /proc/cpuinfo | wc -l)

## RAM usage
ram_total=$(free -m | awk '$1 == "Mem:" {print $2}')
ram_used=$(free -m | awk '$1 == "Mem:" {print $3}')
ram_percent=$(free | awk '$1 == "Mem:" {printf("%.2f"), $3/$2*100}')

## Disk usage
disk_total=$(df -BG | grep '^/dev/' | grep -v '/boot$' | awk '{total += $2} END {print total}')
disk_used=$(df -BG | grep '^/dev/' | grep -v '/boot$' | awk '{used += $3} END {print used}')
disk_percent=$(df -BG | grep '^/dev/' | grep -v '/boot$' | awk '{used += $3} {total += $2} END {printf("%.2f"), used/total*100}')

## CPU load
cpu_load=$(top -bn1 | grep "Cpu(s)" | awk '{printf("%.1f%%"), $2 + $4}')

## Last boot
last_boot=$(who -b | awk '{print $3 " " $4}')

## LVM check
lvm_check=$(if [ $(lsblk | grep "lvm" | wc -l) -gt 0 ]; then echo "yes"; else echo "no"; fi)

## Active connections
tcp_connections=$(netstat -ant | grep ESTABLISHED | wc -l)

## User log count
user_log=$(who | wc -l)

## Network info
ip_addr=$(hostname -I | awk '{print $1}')
mac_addr=$(ip link show | grep "link/ether" | awk '{print $2}')

## Sudo command count
sudo_count=$(journalctl _COMM=sudo | grep COMMAND | wc -l)

## Display all information
wall "    #Architecture: $arch
    #CPU physical: $cpu_physical
    #vCPU: $cpu_virtual
    #Memory Usage: $ram_used/${ram_total}MB ($ram_percent%)
    #Disk Usage: $disk_used/${disk_total}GB ($disk_percent%)
    #CPU load: $cpu_load
    #Last boot: $last_boot
    #LVM use: $lvm_check
    #Connections TCP: $tcp_connections ESTABLISHED
    #User log: $user_log
    #Network: IP $ip_addr ($mac_addr)
    #Sudo: $sudo_count cmd"
```

---

## Riguorous and solid assesment type of question

Part 1: Foundation Questions

    VM Fundamentals
        What's the difference between a Type 1 and Type 2 hypervisor? Which one are you using for Born2beroot?
        Explain why virtualization is important in modern IT infrastructure.

    Debian vs CentOS
        Why did you choose your specific OS? Give 3 technical advantages and disadvantages compared to the alternative.
        What is the package management system used in your OS and how does it differ from the alternative OS?

    Partitioning Concepts
        Explain in detail what LVM is and how it works at a technical level.
        Walk me through your partition scheme and explain WHY you created each partition with its specific size.
        What are the security advantages of separating /home, /var, and /tmp into different partitions?

Part 2: Deep Configuration Analysis

    AppArmor/SELinux
        What is the difference between Discretionary Access Control and Mandatory Access Control?
        Explain how AppArmor profiles work and how you would modify one.
        Command to check if AppArmor is running and in what mode?

    Advanced UFW
        Explain UFW's relation to iptables. Is UFW a replacement for iptables?
        You need to allow traffic only from a specific IP (192.168.1.5) to your SSH port. Write the exact UFW command.
        What would happen if you had two conflicting UFW rules? How does UFW determine precedence?

    SSH Security
        What encryption algorithms does SSH use and for what purposes?
        What's the difference between password authentication and key-based authentication in SSH?
        If I wanted to completely disable root login via SSH while maintaining the ability to gain root privileges after logging in, what configurations would I need?

Part 3: Advanced System Administration

    User/Group Management
        Explain the structure of /etc/passwd and /etc/shadow files. Why are they separated?
        What is the purpose of the user42 group in your setup? What special permissions does it have?
        A new user 'auditor' needs read-only access to all log files but no other permissions. Set this up with the proper commands.

    Password Policy
        Explain in detail how PAM (Pluggable Authentication Modules) works with libpam-pwquality.
        What do each of these settings mean: minlen=10, ucredit=-1, dcredit=-1, maxrepeat=3, difok=7?
        How would you configure a policy where users cannot reuse their last 5 passwords?

    Sudo Configuration
        What is the TTY ticket system in sudo and why is it important for security?
        Explain each component of this sudo command: sudo -l and what information it provides.
        Create a sudo rule that allows user 'webmaster' to restart only the lighttpd service without a password.

Part 4: Troubleshooting and Advanced Scenarios

    Monitoring Script Analysis
        Explain the architecture of your monitoring script. How does it gather each piece of system information?
        Why was cron chosen for scheduling rather than systemd timers?
        How would you modify your script to alert you if disk usage goes above 90%?

    Network Troubleshooting
        SSH to your server isn't working. Walk through your step-by-step troubleshooting process.
        How would you identify if someone is trying to brute force your SSH service?
        Examine these UFW logs and tell me if there's a security concern: [MOCK LOGS]

    Advanced LVM Operations
        Your /var partition is running out of space. Walk me through the exact commands to expand it by 1GB.
        What is LVM snapshotting and how would you implement it to backup your system?
        Explain the concept of LVM striping and when you would use it.

Part 5: Bonus Services and Security Hardening

    WordPress Stack (if implemented)
        Explain your complete WordPress stack architecture.
        How did you secure the communication between PHP-FPM and Lighttpd?
        What security measures would you implement to protect WordPress from common attacks?

    Additional Service (if implemented)
        Explain why you chose your additional service and how it works within your system.
        What ports does your service use and what security measures did you implement?
        How did you configure it to start automatically when the system boots?

    Ultimate Security Hardening
        What is defense in depth and how does your Born2beroot implementation demonstrate it?
        How would you implement file integrity monitoring on your system?
        What's your approach to keeping the system updated securely while minimizing downtime?

Sample Technical Questions You Should Be Ready For:

    "Show me the exact content of your /etc/sudoers file and explain each non-comment line."

    "Your monitoring script shows the CPU is at 95% utilization. Walk me through how you would identify what process is causing this."

    "I've just deleted your UFW configuration. Recreate it from scratch with all rules."

    "Explain what would happen in your system if I executed this command: sudo chattr +i /etc/passwd"

    "A user reports they can't log in despite using the correct password. Show me the commands to troubleshoot and fix this issue."

Preparation Tips:

    Know your logs: Be familiar with where to find SSH logs, authentication logs, and sudo logs.

    Understand the why: Don't just memorize commands - understand why each configuration choice was made.

    Practice troubleshooting: Have a friend intentionally break something on your VM and practice fixing it.

    Be ready to draw: Practice drawing diagrams of your partition scheme and system architecture.

    Master the monitoring script: Be able to explain every line of your monitoring script.

Remember that evaluators often focus more on your understanding than your
ability to memorize commands. They want to see that you grasp the concepts
behind the configurations.

Would you like me to provide sample answers for any of these questions or focus
on a specific area in more detail?

---

## RESPONSES

## Born2beroot Assessment: Sample Answers

## Part 1: Foundation Questions

### 1. VM Fundamentals

**Q: What's the difference between a Type 1 and Type 2 hypervisor? Which one are
you using for Born2beroot?**

**A:** Type 1 hypervisors (bare-metal) run directly on the host's hardware
without an underlying operating system. Examples include VMware ESXi, Microsoft
Hyper-V, and Xen.

Type 2 hypervisors run as applications within a host operating system. Examples
include VirtualBox, VMware Workstation, and QEMU.

For Born2beroot, I'm using VirtualBox which is a Type 2 hypervisor. It runs on
top of my host OS, creating an abstraction layer that allows multiple guest
operating systems to share the same physical hardware resources.

**Q: Explain why virtualization is important in modern IT infrastructure.**

**A:** Virtualization is critical in modern IT for several reasons:

1. **Resource Efficiency**: It allows multiple virtual machines to share
   physical hardware, increasing utilization rates.
2. **Isolation**: Each VM operates independently, so failures in one environment
   don't affect others.
3. **Flexibility and Scalability**: VMs can be easily provisioned, cloned, or
   migrated between hosts.
4. **Testing and Development**: Provides safe environments for testing without
   affecting production systems.
5. **Disaster Recovery**: VMs can be quickly backed up and restored.
6. **Cost Reduction**: Reduces hardware costs, power consumption, and physical
   space requirements.
7. **Security**: Creates isolation boundaries between different applications or
   environments.

### 2. Debian vs CentOS

**Q: Why did you choose your specific OS? Give 3 technical advantages and
disadvantages compared to the alternative.**

**A:** I chose Debian for my implementation.

**Advantages of Debian over CentOS:**

1. **Package Freshness**: Debian typically has more up-to-date packages in its
   repositories, allowing access to newer features and security patches.
2. **Simpler Upgrade Path**: Debian's upgrade process between major versions is
   generally smoother and more automated.
3. **Universal Package Management**: The APT package management system offers
   powerful dependency resolution and intuitive commands.

**Disadvantages of Debian compared to CentOS:**

1. **Enterprise Support**: CentOS (based on RHEL) has longer support cycles
   designed for enterprise stability (up to 10 years vs Debian's 5 years for
   LTS).
2. **Industry Standard**: The RHEL/CentOS ecosystem is more common in enterprise
   environments, making certain skills more transferable.
3. **SELinux Integration**: CentOS has better native integration with SELinux,
   providing more granular security controls than Debian's AppArmor.

**Q: What is the package management system used in your OS and how does it
differ from the alternative OS?**

**A:** Debian uses the Advanced Package Tool (APT) system with `.deb` packages.

Key differences between APT (Debian) and YUM/DNF (CentOS):

1. **Command Structure**:
   - APT: `apt update`, `apt install`, `apt remove`
   - YUM/DNF: `yum update`, `yum install`, `yum remove`

2. **Dependency Handling**: Both handle dependencies, but APT has historically
   had more sophisticated dependency resolution.

3. **Repository Structure**:
   - Debian separates repos into main, contrib, non-free, and has distinct
     stable/testing/unstable branches
   - CentOS repositories are structured around base, updates, extras, and EPEL

4. **Package Format**:
   - Debian uses `.deb` packages installed with `dpkg` at the low level
   - CentOS uses `.rpm` packages installed with `rpm` at the low level

5. **Configuration Management**:
   - Debian often uses debconf for package configuration
   - CentOS relies more on individual package configuration files

### 3. Partitioning Concepts

**Q: Explain in detail what LVM is and how it works at a technical level.**

**A:** Logical Volume Management (LVM) is an abstraction layer that manages disk
drives and similar mass-storage devices. It works through three key components:

1. **Physical Volumes (PVs)**: These are the physical storage devices or
   partitions (like `/dev/sda1`) that LVM will use. They're initialized with
   `pvcreate` which places a label at the start of the device to identify it as
   a PV.

2. **Volume Groups (VGs)**: A collection of Physical Volumes. You can think of a
   VG as a virtual disk that combines the storage from multiple PVs. Created
   with `vgcreate`.

3. **Logical Volumes (LVs)**: These are created from the available space in
   Volume Groups and are similar to partitions but with more flexibility. LVs
   are what get formatted with a filesystem and mounted in the directory tree.
   Created with `lvcreate`.

At a technical level, LVM works by:

- Dividing PVs into fixed-size Physical Extents (PEs)
- Mapping Logical Extents (LEs) in the LV to Physical Extents
- Using this mapping to provide features like resizing, snapshots, and striping
- Maintaining metadata about the mapping in a special area at the beginning of
  each PV

This abstraction allows for dynamic resizing, spanning volumes across multiple
disks, and taking snapshots without disrupting the running system.

**Q: Walk me through your partition scheme and explain WHY you created each
partition with its specific size.**

**A:** My partition scheme follows the required structure with these
considerations:

1. **Boot Partition (500MB, non-LVM)**:
   - Separated because the bootloader needs to access it before LVM is activated
   - 500MB is sufficient for several kernel versions and initramfs images

2. **Root Partition (10GB)**:
   - Contains the OS and most software
   - 10GB balances space efficiency with room for system updates and
     applications

3. **Swap Partition (2GB)**:
   - Size based on the VM's RAM (typically 1-2× RAM for systems with limited
     memory)
   - Provides space for memory paging and hibernation

4. **Home Partition (5GB)**:
   - Separated to preserve user data during OS reinstalls
   - 5GB is adequate for user files in this controlled environment

5. **Var Partition (3GB)**:
   - Contains variable data like logs and caches
   - Separated to prevent log files from filling the root partition
   - 3GB accommodates growing logs without excessive allocation

6. **Srv Partition (2GB)**:
   - For service data (like web servers)
   - Isolated to improve security and prevent service data from affecting system
     functionality

7. **Tmp Partition (2GB)**:
   - For temporary files
   - Isolated for security (can be mounted with noexec)
   - 2GB prevents temporary file operations from impacting system performance

8. **Var/log Partition (2GB)**:
   - For system logs
   - Separated to protect against log file exploitation and to preserve logs
     even if other partitions are compromised

**Q: What are the security advantages of separating /home, /var, and /tmp into
different partitions?**

**A:** Separating these directories into different partitions provides several
security benefits:

1. **/home separation**:
   - Prevents user quota exhaustion from affecting system operations
   - Allows implementation of special mount options like `noexec` to prevent
     execution of malicious scripts
   - Preserves user data during system reinstalls or recoveries
   - Limits the impact of user-level compromises

2. **/var separation**:
   - Prevents log files from filling the root partition in case of
     denial-of-service attacks
   - Contains services like mail queues that can grow unexpectedly
   - Can limit the impact of compromised web applications (often in /var/www)
   - Isolates system-critical logs from other system components

3. **/tmp separation**:
   - Can be mounted with `noexec`, `nosuid`, and `nodev` to prevent execution of
     temporary files, which are common attack vectors
   - Limits the damage from temporary file exploits
   - Can be cleared on reboot without affecting other system files
   - Prevents attackers from using /tmp to fill up the root filesystem

These separations implement the principle of least privilege and
compartmentalization, limiting the impact of security breaches to specific areas
of the filesystem.

## Part 2: Deep Configuration Analysis

### 4. AppArmor/SELinux

**Q: What is the difference between Discretionary Access Control and Mandatory
Access Control?**

**A:**

**Discretionary Access Control (DAC)**:

- The owner of a resource determines who can access it
- Based on user identity and ownership (standard Unix permissions)
- Users can change permissions of resources they own
- Example: chmod, chown commands
- Limited security since privileged users (root) can bypass all restrictions
- Default in most traditional Unix/Linux systems

**Mandatory Access Control (MAC)**:

- System-enforced access controls that cannot be overridden by users
- Based on security labels/contexts assigned to every resource and process
- Even root users are constrained by MAC policies
- Administrator defines system-wide security policies
- Examples: AppArmor, SELinux, TOMOYO
- Provides more granular and robust security controls
- Requires additional configuration but significantly improves system security

The key difference is that with DAC, access is at the discretion of the resource
owner, while with MAC, access is controlled by a system-wide policy that even
privileged users must adhere to.

**Q: Explain how AppArmor profiles work and how you would modify one.**

**A:** AppArmor profiles define the resources (files, capabilities, network)
that applications can access:

1. **Profile Structure**: Each profile contains rules specifying:
   - File access permissions (read, write, execute)
   - Network access capabilities
   - Linux capabilities
   - Which other profiles it can transition to

2. **Modes**:
   - **Enforcement Mode**: Restricts application access according to profile
     rules
   - **Complain Mode**: Allows all access but logs violations for profile
     development

3. **Path-Based**: AppArmor uses file paths (unlike SELinux which uses labels)

To modify an AppArmor profile:

1. Switch to complain mode to observe needed access:

   ```bash
   sudo aa-complain /path/to/profile
   ```

2. Use the logs to identify required access:

   ```bash
   sudo aa-logprof
   ```

3. Edit the profile manually:

   ```bash
   sudo nano /etc/apparmor.d/usr.sbin.application
   ```

4. Add necessary rules, for example:

   ```text
   /path/to/file rw,
   /path/to/directory/* r,
   capability net_bind_service,
   ```

5. Test the profile:

   ```bash
   sudo apparmor_parser -r /etc/apparmor.d/usr.sbin.application
   ```

6. Switch back to enforcement mode:

   ```bash
   sudo aa-enforce /path/to/profile
   ```

**Q: Command to check if AppArmor is running and in what mode?**

**A:** To check AppArmor status:

```bash
sudo aa-status
```

Alternatively:

```bash
sudo apparmor_status
```

This shows:

- Whether AppArmor is enabled
- Number of loaded profiles
- Profiles in enforce mode
- Profiles in complain mode
- Processes with profiles in enforce mode
- Processes with profiles in complain mode

To check the mode of a specific profile:

```bash
sudo aa-status | grep profile_name
```

### 5. Advanced UFW

**Q: Explain UFW's relation to iptables. Is UFW a replacement for iptables?**

**A:** UFW (Uncomplicated Firewall) is not a replacement for iptables but rather
a frontend that simplifies iptables configuration:

1. **Relationship**:
   - UFW operates on top of iptables, generating iptables rules
   - iptables is the actual packet filtering framework within the Linux kernel
     (netfilter)
   - UFW provides a simplified interface for common firewall operations

2. **Technical architecture**:
   - iptables directly manipulates the netfilter packet filtering hooks in the
     kernel
   - UFW uses Python and shell scripts to create appropriate iptables rule
     chains
   - UFW stores configurations in `/etc/ufw/` that get translated to iptables
     rules

3. **Functionality**:
   - UFW covers common use cases with simple commands
   - iptables provides more granular control with more complex syntax
   - Complex scenarios may require direct iptables rules alongside UFW

4. **When to use each**:
   - UFW: Standard server protection, basic port management
   - iptables directly: Complex rule sets, advanced packet manipulation, NAT,
     custom chains

UFW is designed to make firewall management accessible while leveraging
iptables' underlying power. You can view the iptables rules generated by UFW
using `sudo iptables -L`.

**Q: You need to allow traffic only from a specific IP (192.168.1.5) to your SSH
port. Write the exact UFW command.**

**A:**

```bash
sudo ufw allow from 192.168.1.5 to any port 4242 proto tcp
```

This command:

- Allows incoming connections
- Only from IP address 192.168.1.5
- To port 4242 (the SSH port in Born2beroot)
- Using TCP protocol (which SSH uses)
- On any interface (could be specified with "to any" or a specific interface)

**Q: What would happen if you had two conflicting UFW rules? How does UFW
determine precedence?**

**A:** When UFW has conflicting rules, it follows the "first match" principle:

1. **Processing Order**:
   - Rules are processed from top to bottom (as shown in
     `sudo ufw status numbered`)
   - The first rule that matches a packet determines the action taken
   - Once a match is found, no further rules are evaluated for that packet

2. **Default Policy**:
   - If no rules match, the default policy is applied (typically "deny")
   - The default policy acts as a catch-all at the end of the rule list

3. **Example Conflict Resolution**:
   - If you have `allow from 192.168.1.0/24 to any port 4242` followed by
     `deny from 192.168.1.5 to any port 4242`, then:
   - Traffic from 192.168.1.5 to port 4242 will be allowed because the first
     rule matches and processing stops

4. **Rule Manipulation**:
   - To change precedence, you can delete and recreate rules, or
   - Use `sudo ufw insert <position> <rule>` to place a rule at a specific
     position

This means that more specific deny rules must come before broader allow rules to
be effective. This is different from some other firewalls that might use a "most
specific match" principle.

### 6. SSH Security

**Q: What encryption algorithms does SSH use and for what purposes?**

**A:** SSH employs multiple encryption algorithms for different security
aspects:

1. **Key Exchange Algorithms**:
   - Purpose: Establish a shared secret between client and server securely
   - Common algorithms: Diffie-Hellman (DH), Elliptic Curve Diffie-Hellman
     (ECDH)
   - Example: `diffie-hellman-group14-sha256`, `curve25519-sha256`

2. **Host Key Algorithms**:
   - Purpose: Verify server identity to prevent man-in-the-middle attacks
   - Common algorithms: RSA, DSA, ECDSA, Ed25519
   - Example: `ssh-rsa`, `ssh-ed25519`

3. **Symmetric Encryption (Ciphers)**:
   - Purpose: Encrypt the actual data transmission after connection is
     established
   - Common algorithms: AES, ChaCha20
   - Example: `aes256-ctr`, `chacha20-poly1305@openssh.com`

4. **Message Authentication Codes (MACs)**:
   - Purpose: Ensure integrity of transmitted data
   - Common algorithms: HMAC-SHA2, UMAC
   - Example: `hmac-sha2-256`, `umac-64@openssh.com`

5. **Public Key Authentication**:
   - Purpose: Authenticate users without passwords
   - Uses asymmetric encryption (RSA, Ed25519)

These algorithms work together to provide a secure channel with server
verification, user authentication, and encrypted data transfer.

**Q: What's the difference between password authentication and key-based
authentication in SSH?**

**A:**

**Password Authentication**:

- User provides a password that is checked against `/etc/shadow`
- Password is transmitted through the encrypted SSH channel
- Configured with `PasswordAuthentication yes` in sshd_config
- Susceptible to brute-force attacks and password theft
- Simpler to set up but less secure
- No client-side configuration required

**Key-Based Authentication**:

- Uses asymmetric cryptography (public/private key pairs)
- Private key remains on client, public key stored on server in
  `~/.ssh/authorized_keys`
- Authentication process:
  1. Server sends a challenge encrypted with public key
  2. Client decrypts with private key and sends response
  3. Server verifies the response proves private key possession
- Configured with `PubkeyAuthentication yes` in sshd_config
- Highly resistant to brute-force attacks
- Private key can be further protected with a passphrase
- Requires key generation and distribution
- Can be automated for scripts without interactive prompts

Key-based authentication is significantly more secure than password
authentication because the private key never leaves the client machine, and the
server only needs to store public keys which cannot be used to gain unauthorized
access.

**Q: If I wanted to completely disable root login via SSH while maintaining the
ability to gain root privileges after logging in, what configurations would I
need?**

**A:** You would need the following configurations:

1. **Edit the SSH daemon configuration**:

   ```bash
   sudo vim /etc/ssh/sshd_config
   ```

   Add or modify these lines:

   ```text
   # Disable direct root login
   PermitRootLogin no

   # Ensure password authentication is controlled as desired
   PasswordAuthentication yes  # or no if using key-based only

   # Allow only specific users if desired
   AllowUsers user42 LESdylan
   ```

2. **Configure sudo access** for regular users:

   ```bash
   sudo visudo
   ```

   Add appropriate sudo permissions:

   ```text
   # Allow user42 to execute any command with sudo
   user42  ALL=(ALL:ALL) ALL

   # Or for specific commands only
   LESdylan ALL=(ALL) /usr/bin/apt, /usr/sbin/ufw
   ```

3. **Restart the SSH service**:

   ```bash
   sudo systemctl restart ssh
   ```

4. **Test the configuration**:
   - Attempt direct root login (should fail)
   - Login as regular user and run `sudo su -` to gain root access

This approach follows the principle of least privilege by:

- Preventing direct root login, reducing the attack surface
- Requiring attackers to compromise a regular user first
- Providing accountability through sudo logging
- Still allowing legitimate administrators to gain root privileges when needed

## Part 3: Advanced System Administration

### 7. User/Group Management

**Q: Explain the structure of /etc/passwd and /etc/shadow files. Why are they
separated?**

**A:**

**/etc/passwd structure**: Each line contains 7 fields separated by colons:

1. **Username**: The user's login name
2. **Password placeholder**: Historical field, now contains 'x' indicating
   password is in /etc/shadow
3. **UID**: User ID number
4. **GID**: Primary group ID number
5. **GECOS/Comment**: Full name or other user information
6. **Home directory**: Full path to the user's home directory
7. **Login shell**: Path to the user's default shell

Example: `user42:x:1001:1001:User 42:/home/user42:/bin/bash`

**/etc/shadow structure**: Each line contains 9 fields separated by colons:

1. **Username**: Matches the username in /etc/passwd
2. **Encrypted password**: Hashed password with algorithm identifier
3. **Last change**: Days since Jan 1, 1970 that password was last changed
4. **Minimum**: Minimum days between password changes
5. **Maximum**: Maximum days until password change required
6. **Warning**: Days before password expires that user is warned
7. **Inactive**: Days after password expires until account is disabled
8. **Expire**: Days since Jan 1, 1970 that account will be disabled
9. **Reserved**: Reserved for future use

Example: `user42:$6$xyz123$hashedpassword:19051:2:30:7:40:19360:`

**Why separated?**:

1. **Security**: /etc/passwd must be world-readable for many programs to
   function, but password hashes should be protected
2. **Access Control**: /etc/shadow is only readable by root and users with
   specific privileges
3. **Enhanced Features**: /etc/shadow allows for password aging controls not
   available in the original /etc/passwd design
4. **Historical Evolution**: Originally all data was in /etc/passwd until
   security needs drove the separation

This separation is a prime example of the principle of least privilege in system
design.

**Q: What is the purpose of the user42 group in your setup? What special
permissions does it have?**

**A:** The user42 group in my Born2beroot setup serves several purposes:

1. **Organization**: It groups together users that are part of the 42 school
   project evaluation
2. **Access Control**: Members of this group share common access privileges
3. **Project Requirement**: Creating and using this group follows the project
   specifications

The special permissions configured for the user42 group include:

1. **Sudo Access**: Members of user42 can execute commands with sudo (configured
   in /etc/sudoers.d/user42)
2. **Monitoring Script Access**: Can read and potentially modify the monitoring
   script
3. **Specific Directory Access**: May have read or write permissions to
   project-specific directories

To view the specific permissions granted to the user42 group:

```bash
grep user42 /etc/group
grep user42 /etc/sudoers /etc/sudoers.d/*
find / -group user42 -ls 2>/dev/null
```

The user42 group is primarily used for logical organization and to demonstrate
group-based access control principles rather than having extensive special
permissions beyond what's required for the project.

**Q: A new user 'auditor' needs read-only access to all log files but no other
permissions. Set this up with the proper commands.**

**A:** To create a user 'auditor' with read-only access to log files:

```bash
## Step 1: Create a new group for log access
sudo groupadd logaccess

## Step 2: Create the auditor user with /sbin/nologin shell (no interactive login)
sudo useradd -m -s /sbin/nologin -c "Log Auditor" auditor

## Step 3: Add auditor to the logaccess group
sudo usermod -aG logaccess auditor

## Step 4: Set appropriate permissions on log directories
sudo chmod -R 750 /var/log
sudo chgrp -R logaccess /var/log

## Step 5: Ensure new log files maintain correct permissions using ACLs
sudo apt install acl
sudo setfacl -Rm d:g:logaccess:r,g:logaccess:r /var/log

## Step 6: Add a specific sudoers entry to only allow viewing logs
echo "auditor ALL=(ALL) NOPASSWD:/usr/bin/grep, /usr/bin/less, /usr/bin/cat, /usr/bin/tail, /usr/bin/head" | sudo tee /etc/sudoers.d/auditor

## Step 7: Make the sudoers file secure
sudo chmod 440 /etc/sudoers.d/auditor

## Step 8: Create an SSH key for the auditor if remote access is needed
sudo -u auditor mkdir -p /home/auditor/.ssh
sudo cat > /home/auditor/.ssh/authorized_keys << 'EOF'
ssh-rsa AAAAB...your_public_key_here...
EOF
sudo chown -R auditor:auditor /home/auditor/.ssh
sudo chmod 700 /home/auditor/.ssh
sudo chmod 600 /home/auditor/.ssh/authorized_keys
```

This setup:

- Creates a dedicated user with no shell access
- Provides read-only access to log files via group membership
- Uses ACLs to ensure new log files maintain correct permissions
- Allows only specific commands with sudo (all related to viewing files)
- Optionally sets up SSH key-based authentication for remote access
- Follows the principle of least privilege

### 8. Password Policy

**Q: Explain in detail how PAM (Pluggable Authentication Modules) works with
libpam-pwquality.**

**A:** PAM (Pluggable Authentication Modules) with libpam-pwquality creates a
modular framework for password quality enforcement:

1. **PAM Architecture**:
   - PAM provides a flexible mechanism for authentication in Linux
   - It uses a stack of modules for different authentication tasks
   - Each PAM-aware application calls the PAM library
   - PAM consults configuration files in /etc/pam.d/ to determine which modules
     to use

2. **libpam-pwquality's Role**:
   - It's a specific PAM module focusing on password quality enforcement
   - Replaces the older pam_cracklib module with enhanced features
   - Checks passwords against various complexity rules
   - Prevents common, easily-guessable passwords

3. **Integration Process**:
   - When a user changes their password with `passwd` or during login
   - PAM processes the /etc/pam.d/common-password file
   - It encounters the pam_pwquality.so module entry
   - The module checks the proposed password against defined quality criteria
   - Password change fails if criteria aren't met

4. **Configuration in Born2beroot**:
   - Located in /etc/pam.d/common-password
   - Key line:
     `password requisite pam_pwquality.so retry=3 minlen=10 ucredit=-1 lcredit=-1 dcredit=-1 maxrepeat=3 reject_username difok=7 enforce_for_root`
   - "requisite" means failure of this module immediately returns failure to the
     application

5. **Additional Configuration**:
   - Global settings can be defined in /etc/security/pwquality.conf
   - This allows for system-wide defaults that individual PAM configurations can
     override

The primary advantage of this architecture is its modularity—you can adjust
password policies without modifying applications, and applications don't need to
implement their own password checking code.

**Q: What do each of these settings mean: minlen=10, ucredit=-1, dcredit=-1,
maxrepeat=3, difok=7?**

**A:** Each of these settings enforces a specific aspect of password complexity:

**minlen=10**:

- Requires passwords to be at least 10 characters long
- This is the base length requirement before other credits are applied
- Longer passwords generally increase entropy and resistance to brute force
  attacks

**ucredit=-1**:

- Controls uppercase character requirements
- The negative value (-1) means at least 1 uppercase letter is required
- Positive values would represent maximum credit given for uppercase characters
- Ensures password contains characters from different character sets

**lcredit=-1**:

- Controls lowercase character requirements
- The negative value (-1) means at least 1 lowercase letter is required
- Enforces multi-case usage in passwords

**dcredit=-1**:

- Controls digit (number) requirements
- The negative value (-1) means at least 1 digit is required
- Adds another character set to increase entropy

**maxrepeat=3**:

- Limits consecutive repeated characters to 3
- Prevents passwords like "aaaa1234" or "1111aaaa"
- Reduces vulnerability to modification of common passwords

**difok=7**:

- Requires at least 7 characters in the new password that weren't in the old one
- Ensures substantial change when updating passwords
- Prevents minor variations of the same password (e.g., changing just one
  character)

**reject_username**:

- Prevents using the username as part of the password
- Blocks an obvious password choice
- Reduces vulnerability to simple social engineering attacks

**enforce_for_root**:

- Applies all these requirements to the root user as well
- Ensures administrative accounts follow the same security standards
- Without this, root could set simple passwords that might be compromised

Together, these settings create a comprehensive password policy that enforces
complexity, variety, and regular significant changes.

**Q: How would you configure a policy where users cannot reuse their last 5
passwords?**

**A:** To prevent users from reusing their last 5 passwords, I would use the
`pam_pwhistory.so` module in PAM configuration:

1. **Install necessary PAM modules** (if not already installed):

   ```bash
   sudo apt update
   sudo apt install libpam-modules
   ```

2. **Edit the PAM configuration file**:

   ```bash
   sudo vim /etc/pam.d/common-password
   ```

3. **Add or modify the pam_pwhistory line** to include:

   ```text
   password required pam_pwhistory.so remember=5 use_authtok enforce_for_root
   ```

   This line should appear BEFORE the pam_unix.so line.

4. **Explanation of parameters**:
   - `required`: This module must succeed for authentication to proceed
   - `remember=5`: Store and check against the last 5 passwords
   - `use_authtok`: Use the password provided by previous modules
   - `enforce_for_root`: Apply this policy to the root user too

5. **Check where password history is stored**:

   ```bash
   ls -la /etc/security/opasswd
   ```

   This file should have restricted permissions (typically 600).

6. **Test the configuration**:

   ```bash
   sudo passwd test_user  # Change password
   sudo passwd test_user  # Try to change again using a previous password
   ```

This configuration ensures that users must cycle through at least 5 different
passwords before they can reuse an old one, enhancing security by preventing
predictable password cycling patterns.

### 9. Sudo Configuration

**Q: What is the TTY ticket system in sudo and why is it important for
security?**

**A:** The TTY ticket system in sudo is a security mechanism that ties sudo
privileges to specific terminal sessions:

1. **Function**:
   - Creates a unique ticket (timestamp) for each terminal (TTY)
   - Allows sudo to maintain separate authentication timeouts for each terminal
   - Default configuration is controlled by the `tty_tickets` option in sudoers

2. **Security Benefits**:
   - **Session Isolation**: If a user authenticates with sudo in one terminal,
     other terminals still require authentication
   - **Attack Surface Reduction**: Prevents privilege escalation across terminal
     sessions
   - **Timeout Control**: Each terminal has its own authentication timeout
   - **Improved Accountability**: Creates more precise logs of sudo usage

3. **How It Works**:
   - When a user runs sudo with correct password, a ticket is created for that
     specific TTY
   - The ticket is stored in `/var/run/sudo/ts/username` or similar location
   - Subsequent sudo commands in the same terminal use this ticket within the
     timeout period
   - Other terminals don't have access to this ticket and require separate
     authentication

4. **Born2beroot Configuration**: In our sudoers file, we have:
   `Defaults        tty_tickets`

Without TTY tickets, a single sudo authentication would apply to all terminals,
potentially allowing an attacker who gained access to any terminal to execute
privileged commands without re-authenticating. The TTY ticket system implements
the principle of least privilege in a multi-session environment.

**Q: Explain each component of this sudo command: `sudo -l` and what information
it provides.**

**A:** The `sudo -l` command lists the sudo privileges for the current user:

1. **Command Structure**:
   - `sudo`: The sudo program itself
   - `-l`: Short for `--list`, instructs sudo to list privileges

2. **Authentication**:
   - Requires authentication by default (password entry)
   - Uses cached credentials if within the timeout period
   - Can be run with `-n` to prevent password prompt

3. **Output Components**:
   - **User Specification**: Shows as "User USERNAME may run the following
     commands on HOSTNAME"
   - **RunAs Specification**: Displays as "(ALL : ALL)" indicating which
     users/groups the commands can be run as
   - **Command Restrictions**: Lists the specific commands allowed
   - **Sudoers Options**: Shows any options that apply to this user's sudo
     privileges

4. **Security Context**:
   - Allows users to verify their privileges before attempting actions
   - Helps administrators audit sudo configurations
   - Provides transparency about security permissions

5. **Example Output**:

   ```text
   User LESdylan may run the following commands on debian:
       (ALL : ALL) ALL
       (root) NOPASSWD: /usr/sbin/ufw
   ```

   This shows:
   - User "LESdylan" has sudo privileges on host "debian"
   - Can run ALL commands as ANY user (first line)
   - Can run the ufw command as root WITHOUT password (second line)

This command is vital for security auditing and helps users understand their
system privileges without having to interpret the sometimes complex sudoers file
directly.

**Q: Create a sudo rule that allows user 'webmaster' to restart only the
lighttpd service without a password.**

**A:** I'll create a sudo rule that allows 'webmaster' to restart the lighttpd
service without a password:

```bash
## Edit the sudoers file safely
sudo visudo -f /etc/sudoers.d/webmaster
```

Then add this line to the file:

```text
webmaster ALL=(root) NOPASSWD: /usr/bin/systemctl restart lighttpd, /usr/bin/systemctl status lighttpd
```

Save and exit the editor.

Now secure the file with correct permissions:

```bash
sudo chmod 440 /etc/sudoers.d/webmaster
```

Let's break down this rule:

- `webmaster`: The username this rule applies to
- `ALL`: This rule applies on all hosts
- `(root)`: The commands will be executed as the root user
- `NOPASSWD`: No password will be required
- The specific commands that are allowed:
  - `/usr/bin/systemctl restart lighttpd`: To restart the web server
  - `/usr/bin/systemctl status lighttpd`: To check the status (added for
    convenience)

This rule follows the principle of least privilege by:

1. Limiting the user to only the specific commands needed
2. Using the full paths to prevent command substitution attacks
3. Only allowing actions on the lighttpd service, not other services
4. Placing the rule in a separate file for easier management

The user can now run:

```bash
sudo systemctl restart lighttpd
```

Without being prompted for a password.

## Part 4: Troubleshooting and Advanced Scenarios

### 10. Monitoring Script Analysis

**Q: Explain the architecture of your monitoring script. How does it gather each
piece of system information?**

**A:** The monitoring script is structured to gather and display system
information using native Linux commands:

1. **Architecture & Kernel** (`uname -a`):
   - Uses the `uname` system call to retrieve kernel information
   - Displays kernel name, hostname, kernel release, version, and architecture

2. **CPU Information**:
   - **Physical cores**
     (`grep "physical id" /proc/cpuinfo | sort | uniq | wc -l`):
     - Reads from the virtual filesystem `/proc/cpuinfo`
     - Extracts unique physical CPU IDs
     - Counts them with `wc -l`
   - **Virtual cores** (`grep "processor" /proc/cpuinfo | wc -l`):
     - Counts processor entries in `/proc/cpuinfo`

3. **Memory Usage** (`free`):
   - Interfaces with the kernel's memory management subsystem
   - Parses the output with `awk` to calculate:
     - Total RAM (`$2` in the "Mem:" line)
     - Used RAM (`$3` in the "Mem:" line)
     - Usage percentage (`$3/$2*100`)

4. **Disk Usage** (`df`):
   - Calls the statfs system call for each mounted filesystem
   - Filters to only include real devices (`grep '^/dev/'`)
   - Uses `awk` to calculate total, used, and percentage

5. **CPU Load** (`top -bn1`):
   - Takes a snapshot of process data from the kernel
   - Extracts the CPU line with `grep`
   - Calculates load percentage with `awk`

6. **Last Boot** (`who -b`):
   - Reads from the utmp database file
   - Extracts the system boot record

7. **LVM Status** (`lsblk`):
   - Queries the kernel's block device subsystem
   - Uses `grep` to check for "lvm" strings
   - Returns "yes" if found, "no" otherwise

8. **TCP Connections** (`ss` or `netstat`):
   - Interfaces with the kernel's network stack
   - Filters for ESTABLISHED connections
   - Counts them with `wc -l`

9. **User Sessions** (`who | wc -l`):
   - Reads from the utmp database
   - Counts current user sessions

10. **Network Information**:
    - **IP Address** (`hostname -I`):
      - Uses the gethostname and getaddrinfo system calls
    - **MAC Address** (`ip link show`):
      - Interfaces with the netlink socket API
      - Extracts the MAC with `awk`

11. **Sudo Commands** (`journalctl` or log file):
    - Either reads from systemd's journal
    - Or parses `/var/log/sudo/sudo.log`
    - Counts COMMAND entries

The script follows UNIX philosophy by:

- Using specialized tools for each task
- Composing them with pipes and filters
- Processing text output with tools like grep, awk, and wc

**Q: Why was cron chosen for scheduling rather than systemd timers?**

**A:** Cron was chosen over systemd timers for several strategic reasons:

1. **Compatibility & Universality**:
   - Cron has been a standard in Unix-like systems for decades
   - Works across virtually all Linux distributions
   - The Born2beroot project emphasizes learning foundational concepts

2. **Simplicity & Learning Curve**:
   - Cron syntax is straightforward (minute hour dom month dow command)
   - Easy to read and understand for beginners
   - Minimal configuration required for basic scheduling

3. **Resource Efficiency**:
   - Cron is lightweight with minimal dependencies
   - Ideal for server environments where resource usage should be minimized
   - Doesn't require the systemd infrastructure to function

4. **Specific Project Requirements**:
   - The Born2beroot subject explicitly mentions configuring cron
   - Using cron follows the project specifications directly
   - Demonstrates understanding of traditional system administration tools

5. **Technical Considerations**:
   - For simple periodic tasks, cron provides all needed functionality
   - No need for the advanced features of systemd timers (like dependency
     handling)
   - More straightforward logging and troubleshooting

While systemd timers offer advantages like:

- Better synchronization with system events
- Logs integrated with journald
- More precise timing options
- Dependency management

These weren't necessary for the straightforward monitoring task in Born2beroot,
where the goal is to run a script every 10 minutes consistently.

The choice of cron also demonstrates understanding of both traditional and
modern Linux system administration approaches.

**Q: How would you modify your script to alert you if disk usage goes above
90%?**

**A:** Here's how I would modify the monitoring script to include disk usage
alerts:

```bash
#!/bin/bash

## Original disk usage calculation
disk_total=$(df -BG | grep '^/dev/' | grep -v '/boot$' | awk '{total += $2} END {print total}')
disk_used=$(df -BG | grep '^/dev/' | grep -v '/boot$' | awk '{used += $3} END {print used}')
disk_percent=$(df -BG | grep '^/dev/' | grep -v '/boot$' | awk '{used += $3} {total += $2} END {printf("%.2f"), used/total*100}')

## Alert threshold
THRESHOLD=90

## Check individual filesystems for high usage
high_usage_filesystems=$(df -h | grep '^/dev/' | awk '{print $5 " " $6}' | grep -E '^([9][0-9]|100)%')

## Add to the monitoring message
monitoring_message="
    #Architecture: $arch
    #CPU physical: $cpu_physical
    #vCPU: $cpu_virtual
    #Memory Usage: $ram_used/${ram_total}MB ($ram_percent%)
    #Disk Usage: $disk_used/${disk_total}GB ($disk_percent%)"

## Add alert if overall disk percentage is above threshold
if (( $(echo "$disk_percent > $THRESHOLD" | bc -l) )); then
    monitoring_message+="
    #!!! WARNING: Overall disk usage is above ${THRESHOLD}% !!!"

    # Send email alert if mail command is available
    if command -v mail > /dev/null; then
        echo "ALERT: Disk usage is at ${disk_percent}%" | mail -s "High Disk Usage on $(hostname)" root
    fi

    # Log to system log
    logger -p user.warning "Monitoring script: Disk usage at ${disk_percent}%"
fi

## Add individual filesystem warnings if any are high
if [ ! -z "$high_usage_filesystems" ]; then
    monitoring_message+="
    #!!! WARNING: The following filesystems are above ${THRESHOLD}%:
    $(echo "$high_usage_filesystems" | sed 's/^/#    /')"
fi

## Continue with the rest of the monitoring message
monitoring_message+="
    #CPU load: $cpu_load
    #Last boot: $last_boot
    #LVM use: $lvm_check
    #Connections TCP: $tcp_connections ESTABLISHED
    #User log: $user_log
    #Network: IP $ip_addr ($mac_addr)
    #Sudo: $sudo_count cmd"

## Display the message
wall "$monitoring_message"

## Save alert to a log file for historical tracking
if (( $(echo "$disk_percent > $THRESHOLD" | bc -l) )) || [ ! -z "$high_usage_filesystems" ]; then
    echo "$(date): Disk usage alert - Overall: ${disk_percent}%" >> /var/log/disk_alerts.log
    if [ ! -z "$high_usage_filesystems" ]; then
        echo "High usage filesystems:" >> /var/log/disk_alerts.log
        echo "$high_usage_filesystems" >> /var/log/disk_alerts.log
    fi
    echo "----------------------------------------" >> /var/log/disk_alerts.log
fi
```

This modification:

1. **Adds a threshold variable** (90%) that can be easily adjusted
2. **Checks both overall disk usage and individual filesystems**
3. **Provides visual warnings** in the monitoring output with !!! markings
4. **Sends an email alert** to the root user if mail is configured
5. **Logs warnings to the system log** using logger
6. **Maintains a historical log** of disk alerts in /var/log/disk_alerts.log
7. **Uses bc for precise floating-point comparison** of percentages

The script remains compatible with the original requirements while adding the
alerting functionality. The alerts appear both in the wall message and through
additional notification channels for better visibility.

### 11. Network Troubleshooting

**Q: SSH to your server isn't working. Walk through your step-by-step
troubleshooting process.**

**A:** When SSH isn't working, I follow this systematic troubleshooting process:

1. **Verify Local Connectivity**:

   ```bash
   ping <server_ip>
   ```

   - If ping fails: Check network connection, physical connectivity, and routing

2. **Check SSH Service Status on Server**:

   ```bash
   sudo systemctl status ssh
   ```

   - If not running: `sudo systemctl start ssh`
   - If fails to start: Check logs with `sudo journalctl -u ssh -n 50`

3. **Verify SSH Port is Open and Listening**:

   ```bash
   ss -tuln | grep 4242  # Or whatever your SSH port is
   ```

   - If not listening: SSH daemon may be misconfigured or not running

4. **Check Firewall Status**:

   ```bash
   sudo ufw status
   ```

   - Look for allowed SSH port (4242)
   - If blocked: `sudo ufw allow 4242/tcp`

5. **Examine SSH Configuration**:

   ```bash
   sudo cat /etc/ssh/sshd_config | grep -v "^#" | grep -v "^$"
   ```

   - Check these key settings:
     - Port 4242
     - PasswordAuthentication yes
     - PermitRootLogin no

6. **Review Authentication Logs**:

   ```bash
   sudo tail -n 50 /var/log/auth.log
   ```

   - Look for failed login attempts or configuration errors

7. **Test SSH Configuration**:

   ```bash
   sudo sshd -t
   ```

   - This tests configuration syntax without restarting

8. **Try Connecting with Verbose Output**:

   ```bash
   ssh -v username@server_ip -p 4242
   ```

   - From client side to see detailed connection process

9. **Check File Permissions**:

   ```bash
   ls -la /etc/ssh/
   ```

   - Configuration files should be owned by root with appropriate permissions

10. **Restart SSH Service**:

    ```bash
    sudo systemctl restart ssh
    ```

    - Apply any configuration changes

11. **Check DNS and Hostname Resolution**:

    ```bash
    getent hosts <hostname>
    hostname -f
    ```

    - If using hostnames instead of IP addresses

12. **Test with Minimal Configuration**:

    ```bash
    sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
    sudo vi /etc/ssh/sshd_config  # Create minimal config
    sudo systemctl restart ssh
    ```

13. **Check for Resource Issues**:

    ```bash
    free -m
    df -h
    top
    ```

    - Ensure system has adequate resources

This methodical approach follows the OSI model—starting with network
connectivity, then working up to application-level issues—and maintains system
integrity throughout the troubleshooting process.

**Q: How would you identify if someone is trying to brute force your SSH
service?**

**A:** To identify SSH brute force attempts, I would use these methods:

1. **Check Authentication Logs**:

   ```bash
   sudo grep "Failed password" /var/log/auth.log | tail -n 20
   ```

   Look for patterns like:
   - Multiple failed attempts from the same IP
   - Repeated attempts for different usernames
   - High frequency of attempts in short time periods

2. **Count Failed Attempts by IP**:

   ```bash
   sudo grep "Failed password" /var/log/auth.log | awk '{print $(NF-3)}' | sort | uniq -c | sort -nr
   ```

   This shows IPs with the most failed attempts.

3. **Count Failed Attempts by Username**:

   ```bash
   sudo grep "Failed password" /var/log/auth.log | grep -oP 'for \K\w+' | sort | uniq -c | sort -nr
   ```

   Shows which usernames are being targeted most.

4. **Monitor Connection Attempts in Real Time**:

   ```bash
   sudo tail -f /var/log/auth.log | grep sshd
   ```

   Provides live monitoring of SSH activity.

5. **Check for Rapid Connection Attempts**:

   ```bash
   sudo lastb | head -n 20
   ```

   Shows recent failed login attempts.

6. **Use Specialized Tools**: If installed:

   ```bash
   sudo fail2ban-client status sshd
   ```

   Shows banned IPs and attempt statistics.

7. **Check for Unusual Login Times or Sources**:

   ```bash
   sudo grep "Accepted" /var/log/auth.log | awk '{print $1,$2,$3,$11}'
   ```

   Review successful logins for suspicious patterns.

8. **Visual Pattern Recognition**:

   ```bash
   sudo grep "Failed password" /var/log/auth.log | awk '{print $1,$2,$3}' | uniq -c
   ```

   Shows temporal patterns of attacks (time clustering).

**Indicators of a Brute Force Attack**:

- More than 10 failed attempts from a single IP
- Sequential username attempts (user1, user2, etc.)
- Common username targets (admin, root, user, test)
- Failed attempts occurring at regular intervals (automated tools)
- Attempts originating from countries where you have no legitimate users
- Multiple connection attempts that don't complete authentication

This multi-layered approach helps distinguish between legitimate login failures
and coordinated attacks.

**Q: Examine these UFW logs and tell me if there's a security concern: [MOCK
LOGS]**

**A:** Let's analyze these UFW logs for security concerns:

```text
Aug 5 14:22:18 debian kernel: [UFW BLOCK] IN=eth0 OUT= MAC=00:15:5d:01:51:12:00:15:5d:63:21:16:08:00 SRC=185.234.218.25 DST=10.0.2.15 LEN=40 TOS=0x00 PREC=0x00 TTL=247 ID=29976 PROTO=TCP SPT=42018 DPT=22 WINDOW=1024 RES=0x00 SYN URGP=0
Aug 5 14:23:19 debian kernel: [UFW BLOCK] IN=eth0 OUT= MAC=00:15:5d:01:51:12:00:15:5d:63:21:16:08:00 SRC=185.234.218.25 DST=10.0.2.15 LEN=40 TOS=0x00 PREC=0x00 TTL=247 ID=45312 PROTO=TCP SPT=42018 DPT=22 WINDOW=1024 RES=0x00 SYN URGP=0
Aug 5 14:24:20 debian kernel: [UFW BLOCK] IN=eth0 OUT= MAC=00:15:5d:01:51:12:00:15:5d:63:21:16:08:00 SRC=185.234.218.25 DST=10.0.2.15 LEN=40 TOS=0x00 PREC=0x00 TTL=247 ID=60648 PROTO=TCP SPT=42018 DPT=22 WINDOW=1024 RES=0x00 SYN URGP=0
Aug 5 14:25:21 debian kernel: [UFW BLOCK] IN=eth0 OUT= MAC=00:15:5d:01:51:12:00:15:5d:63:21:16:08:00 SRC=185.234.218.25 DST=10.0.2.15 LEN=40 TOS=0x00 PREC=0x00 TTL=247 ID=29976 PROTO=TCP SPT=42018 DPT=22 WINDOW=1024 RES=0x00 SYN URGP=0
Aug 5 14:26:25 debian kernel: [UFW BLOCK] IN=eth0 OUT= MAC=00:15:5d:01:51:12:00:15:5d:63:21:16:08:00 SRC=193.118.53.210 DST=10.0.2.15 LEN=40 TOS=0x00 PREC=0x00 TTL=246 ID=54321 PROTO=TCP SPT=53124 DPT=22 WINDOW=1024 RES=0x00 SYN URGP=0
Aug 5 14:26:42 debian kernel: [UFW BLOCK] IN=eth0 OUT= MAC=00:15:5d:01:51:12:00:15:5d:63:21:16:08:00 SRC=45.227.254.8 DST=10.0.2.15 LEN=40 TOS=0x00 PREC=0x00 TTL=247 ID=12543 PROTO=TCP SPT=48213 DPT=22 WINDOW=1024 RES=0x00 SYN URGP=0
Aug 5 14:28:13 debian kernel: [UFW BLOCK] IN=eth0 OUT= MAC=00:15:5d:01:51:12:00:15:5d:63:21:16:08:00 SRC=10.0.2.15 DST=8.8.8.8 LEN=60 TOS=0x00 PREC=0x00 TTL=64 ID=57326 DF PROTO=TCP SPT=33960 DPT=443 WINDOW=64240 RES=0x00 SYN URGP=0
Aug 5 14:29:34 debian kernel: [UFW BLOCK] IN=eth0 OUT= MAC=00:15:5d:01:51:12:00:15:5d:63:21:16:08:00 SRC=45.227.254.8 DST=10.0.2.15 LEN=40 TOS=0x00 PREC=0x00 TTL=247 ID=12544 PROTO=TCP SPT=48213 DPT=4242 WINDOW=1024 RES=0x00 SYN URGP=0
Aug 5 14:30:05 debian kernel: [UFW BLOCK] IN=eth0 OUT= MAC=00:15:5d:01:51:12:00:15:5d:63:21:16:08:00 SRC=172.17.0.1 DST=10.0.2.15 LEN=60 TOS=0x00 PREC=0x00 TTL=64 ID=35477 DF PROTO=TCP SPT=43526 DPT=3306 WINDOW=64240 RES=0x00 SYN URGP=0
```

**Analysis of Security Concerns**:

1. **SSH Brute Force Attempt** (High Concern):
   - Multiple blocked connection attempts to port 22 (SSH) from IP
     185.234.218.25
   - Regular timing pattern (approximately every minute) indicates automated
     scanning
   - Window size of 1024 is typical of scanning tools
   - This appears to be a systematic attempt to access SSH

2. **Multiple Source IPs Targeting SSH** (High Concern):
   - Three different IPs (185.234.218.25, 193.118.53.210, 45.227.254.8) all
     trying to access SSH
   - Suggests a coordinated attack or multiple attackers
   - Different source ports but similar packet characteristics

3. **Probing for Alternative SSH Port** (High Concern):
   - IP 45.227.254.8 tried port 22, then later tried port 4242
   - Shows attacker is aware of common SSH alternative ports
   - Indicates targeted scanning rather than random probing

4. **Outbound Connection Attempt Blocked** (Medium Concern):
   - Connection from 10.0.2.15 (your server) to 8.8.8.8 (Google DNS) on port 443
   - This is unusual - your server should be able to make outbound connections
   - Could indicate misconfigured firewall or possible DNS exfiltration attempt

5. **Database Probe** (Medium Concern):
   - Attempt to connect to port 3306 (MySQL) from 172.17.0.1
   - This is likely a Docker or internal network IP
   - Could indicate container escape attempt or internal network scanning

**Recommendations**:

1. Implement Fail2ban to automatically ban IPs making repeated connection
   attempts
2. Consider changing SSH to a non-standard port (though you already seem to
   use 4242)
3. Investigate the outbound connection block to Google DNS - this may indicate a
   misconfiguration
4. Check Docker configuration if you're running containers
5. Consider implementing IP geolocation blocking if these IPs are from regions
   you don't do business with
6. Ensure MySQL is properly secured and not exposed unnecessarily

The most significant concern is the coordinated SSH probing from multiple IPs,
which strongly suggests your server is under active reconnaissance or attack.

### 12. Advanced LVM Operations

**Q: Your /var partition is running out of space. Walk me through the exact
commands to expand it by 1GB.**

**A:** I'll walk through the complete process of expanding the /var LVM
partition by 1GB:

1. **Check current disk usage and LVM setup**:

   ```bash
   df -h /var
   sudo lvdisplay | grep /var
   sudo vgdisplay | grep "Free"
   ```

2. **Determine if the volume group has enough free space**:
   - If VG has 1GB+ space available, proceed to step 4
   - If not, continue with step 3

3. **Add a new disk and extend the volume group** (if needed):

   ```bash
   # Identify the new disk
   lsblk

   # Create a new physical volume on the new disk
   sudo pvcreate /dev/sdb

   # Extend the volume group with the new physical volume
   sudo vgextend vg_born2beroot /dev/sdb

   # Verify the volume group now has enough space
   sudo vgdisplay | grep "Free"
   ```

4. **Extend the logical volume by 1GB**:

   ```bash
   # Identify the exact logical volume path
   sudo lvdisplay | grep "LV Path" | grep var

   # Extend the logical volume
   sudo lvextend -L +1G /dev/vg_born2beroot/lv_var
   ```

5. **Resize the filesystem to use the new space**:

   ```bash
   # Determine filesystem type
   df -T /var

   # For ext4 filesystem (most common)
   sudo resize2fs /dev/vg_born2beroot/lv_var

   # For XFS filesystem
   # sudo xfs_growfs /var
   ```

6. **Verify the new size**:

   ```bash
   df -h /var
   ```

7. **Check filesystem integrity** (optional but recommended):

   ```bash
   sudo e2fsck -f /dev/vg_born2beroot/lv_var
   ```

This process expands the logical volume and filesystem without any downtime or
service interruption. The commands follow a safe sequence:

1. Verify current status
2. Ensure sufficient space in the volume group
3. Extend the logical volume
4. Resize the filesystem to match
5. Verify successful operation

Each step includes checks to confirm successful completion before proceeding to
the next step.

**Q: What is LVM snapshotting and how would you implement it to backup your
system?**

**A:** LVM snapshotting is a technique that creates a point-in-time copy of a
logical volume while allowing the original volume to remain in use. It works by
tracking changes rather than copying all data, making it space-efficient and
fast.

**How LVM Snapshots Work**:

1. A snapshot reserves space in the volume group
2. Initially, the snapshot contains only metadata pointing to the original
   volume
3. When data changes in the original volume, the original blocks are copied to
   the snapshot before being modified (copy-on-write)
4. The snapshot maintains a consistent view of the volume as it existed at
   creation time

**Implementing LVM Snapshots for System Backup**:

1. **Create snapshots of critical logical volumes**:

   ```bash
   # Create a snapshot of the root volume (allocating 2GB for changes)
   sudo lvcreate -L 2G -s -n root_snapshot /dev/vg_born2beroot/lv_root

   # Create snapshots of other important volumes
   sudo lvcreate -L 1G -s -n var_snapshot /dev/vg_born2beroot/lv_var
   sudo lvcreate -L 1G -s -n home_snapshot /dev/vg_born2beroot/lv_home
   ```

2. **Mount the snapshots to access their contents**:

   ```bash
   # Create mount points
   sudo mkdir -p /mnt/snapshot/root
   sudo mkdir -p /mnt/snapshot/var
   sudo mkdir -p /mnt/snapshot/home

   # Mount the snapshots
   sudo mount /dev/vg_born2beroot/root_snapshot /mnt/snapshot/root
   sudo mount /dev/vg_born2beroot/var_snapshot /mnt/snapshot/var
   sudo mount /dev/vg_born2beroot/home_snapshot /mnt/snapshot/home
   ```

3. **Backup the mounted snapshots**:

   ```bash
   # Using tar to create compressed backups
   sudo tar -czf /backup/root-$(date +%Y%m%d).tar.gz -C /mnt/snapshot/root .
   sudo tar -czf /backup/var-$(date +%Y%m%d).tar.gz -C /mnt/snapshot/var .
   sudo tar -czf /backup/home-$(date +%Y%m%d).tar.gz -C /mnt/snapshot/home .

   # Or using rsync to a backup destination
   sudo rsync -av /mnt/snapshot/root/ /backup/root/
   sudo rsync -av /mnt/snapshot/var/ /backup/var/
   sudo rsync -av /mnt/snapshot/home/ /backup/home/
   ```

4. **Clean up after backup completion**:

   ```bash
   # Unmount snapshots
   sudo umount /mnt/snapshot/root
   sudo umount /mnt/snapshot/var
   sudo umount /mnt/snapshot/home

   # Remove the snapshots
   sudo lvremove -f /dev/vg_born2beroot/root_snapshot
   sudo lvremove -f /dev/vg_born2beroot/var_snapshot
   sudo lvremove -f /dev/vg_born2beroot/home_snapshot
   ```

5. **Automating the process with a script**: Create a backup script that:
   - Creates snapshots
   - Mounts them
   - Performs the backup
   - Unmounts and removes snapshots
   - Logs the process
   - Schedule with cron for regular backups

**Advantages of this approach**:

1. **Consistency**: Snapshots capture a consistent point-in-time image
2. **No downtime**: The system remains fully operational during backup
3. **Data integrity**: Avoids backing up partially-written files
4. **Efficiency**: Only changed blocks consume space in the snapshot
5. **Quick creation/deletion**: Operations take seconds regardless of volume
   size

This method provides reliable backups with minimal impact on system performance.

**Q: Explain the concept of LVM striping and when you would use it.**

**A:** LVM striping is a technique that distributes data across multiple
physical volumes in parallel, similar to RAID 0, to improve I/O performance.

**How LVM Striping Works**:

1. **Data Distribution**: When writing data to a striped logical volume, LVM
   breaks the data into chunks (stripes)
2. **Parallel Storage**: These chunks are written in parallel across multiple
   physical volumes (disks)
3. **Read/Write Optimization**: Multiple disk heads can simultaneously
   read/write different parts of a file

**Technical Implementation**:

- Stripes are specified during logical volume creation
- The stripe size (chunk size) can be configured (typically 64KB to 256KB)
- Performance depends on the number of physical volumes and their individual
  speeds

**Creating a Striped Logical Volume**:

```bash
## Create a striped LV across 3 PVs with 256KB stripe size
sudo lvcreate --type striped -i 3 -I 256 -L 10G -n lv_striped vg_born2beroot
```

Parameters explained:

- `-i 3`: Use 3 stripes (physical volumes)
- `-I 256`: Use a stripe size of 256KB
- `-L 10G`: Create a 10GB volume
- `-n lv_striped`: Name the volume "lv_striped"

**When to Use LVM Striping**:

1. **High-Performance Database Servers**:
   - Databases with heavy random read/write operations
   - When query performance is bottlenecked by I/O
   - Particularly useful for PostgreSQL, MySQL, Oracle databases

2. **Video Editing and Rendering**:
   - When working with large media files
   - For applications that need to read/write large files quickly
   - Streaming media servers

3. **Scientific Computing and Data Analysis**:
   - Processing large datasets
   - Applications requiring high throughput
   - When computational tasks are I/O-bound

4. **Virtual Machine Storage**:
   - Hosting multiple VMs on a single physical server
   - When concurrent VM I/O causes disk bottlenecks

**When NOT to Use LVM Striping**:

1. **Critical Data without Backup**:
   - Like RAID 0, if one disk fails, all data is lost
   - No redundancy or fault tolerance

2. **Single Disk Systems**:
   - No performance benefit with only one physical volume
   - Adds unnecessary complexity

3. **When Reliability is More Important Than Speed**:
   - Consider LVM mirroring (RAID 1 equivalent) instead
   - Or combine with hardware RAID for both performance and reliability

4. **Small Read Operations**:
   - For workloads with many small, random reads
   - The overhead of striping may outweigh benefits
   - SSDs might be a better solution for this use case

**Balancing Performance and Risk**:

In Born2beroot or production environments, LVM striping is often combined with
other RAID technologies to balance performance and data protection:

- RAID 10 (striping + mirroring) for both speed and redundancy
- Using LVM on top of hardware RAID for flexibility
- Creating backup strategies specifically designed for striped volumes

LVM striping exemplifies the performance vs. reliability tradeoff common in
system administration. While it significantly improves I/O performance, it
increases the risk of data loss, making proper backup strategies essential when
implementing it.

## Part 5: Bonus Services and Security Hardening

### 13. WordPress Stack (if implemented)

**Q: Explain your complete WordPress stack architecture.**

**A:** My Born2beroot WordPress stack follows the LLMP architecture (Linux,
Lighttpd, MariaDB, PHP):

1. **System Foundation**:
   - Debian as the Linux distribution
   - Services isolated in their own LVM partitions (/var)
   - UFW firewall controlling access to web ports

2. **Web Server Layer (Lighttpd)**:
   - Lightweight alternative to Apache/Nginx
   - Configuration in `/etc/lighttpd/lighttpd.conf`
   - ModRewrite for URL handling
   - SSL/TLS for HTTPS on port 443
   - Static content served directly
   - Key modules: mod_access, mod_fastcgi, mod_rewrite, mod_auth

3. **PHP Processing Layer**:
   - PHP-FPM (FastCGI Process Manager) for PHP execution
   - Separate process pool for WordPress
   - Socket-based communication with Lighttpd
   - Configuration in `/etc/php/7.4/fpm/pool.d/www.conf`
   - Memory limits and resource controls configured

4. **Database Layer (MariaDB)**:
   - WordPress database with prefix-based tables
   - Dedicated database user for WordPress
   - Limited permissions (no GRANT options)
   - InnoDB storage engine for transactions
   - Optimized my.cnf for VM environment

5. **WordPress Core**:
   - Installed in `/var/www/html/wordpress`
   - WordPress config in `wp-config.php`
   - WP-CLI for command-line management
   - Permissions: files owned by www-data
   - Regular update mechanism

6. **Security Implementations**:
   - AppArmor profiles for PHP, MariaDB, and Lighttpd
   - File permissions hardened on WordPress directories
   - Database password stored with salts
   - WP security keys generated with appropriate entropy
   - wp-config.php protected from direct access

7. **Connection Flow**:

   ```text
   Client Request → UFW → Lighttpd → PHP-FPM → MariaDB → PHP-FPM → Lighttpd → Client
   ```

8. **Performance Optimizations**:
   - PHP opcode caching enabled
   - Lighttpd configured for static file caching
   - MariaDB query cache tuned for WordPress workload
   - Expires headers set for browser caching

This architecture provides a balance of performance, security, and simplicity
appropriate for a virtual machine environment, while following the principle of
least privilege throughout the stack.

**Q: How did you secure the communication between PHP-FPM and Lighttpd?**

**A:** I secured the communication between PHP-FPM and Lighttpd through several
measures:

1. **Unix Socket Communication**:
   - Used Unix domain sockets instead of TCP/IP
   - Configuration in `/etc/php/7.4/fpm/pool.d/www.conf`:

     ```text
     listen = /run/php/php7.4-fpm.sock
     ```

   - Lighttpd configuration in `/etc/lighttpd/conf-enabled/15-fastcgi-php.conf`:

     ```text
     fastcgi.server += ( ".php" =>
        ((
            "socket" => "/run/php/php7.4-fpm.sock",
            "broken-scriptfilename" => "enable"
        ))
     )
     ```

   - Unix sockets prevent remote access to the PHP-FPM process

2. **Strict Permissions on Socket File**:
   - Set socket owner and group to match Lighttpd's user
   - In PHP-FPM pool configuration:

     ```text
     listen.owner = www-data
     listen.group = www-data
     listen.mode = 0660
     ```

   - This prevents unauthorized processes from accessing the socket

3. **Process Isolation**:
   - PHP-FPM runs as a dedicated user (www-data)
   - Configured in `/etc/php/7.4/fpm/pool.d/www.conf`:

     ```text
     user = www-data
     group = www-data
     ```

   - Separate process pool for WordPress with limited permissions

4. **Input Validation**:
   - Configured Lighttpd to validate PHP file existence before passing to FPM
   - Added security checks in Lighttpd configuration:

     ```text
     fastcgi.check-local = "enable"
     ```

   - Prevents passing requests for non-existent files to PHP-FPM

5. **Restricted File Access**:
   - Implemented a deny-by-default approach
   - Only specific directories are allowed to execute PHP
   - Lighttpd configuration:

     ```text
     $HTTP["url"] =~ "^/(?!wp-admin|wp-includes).*/\.php$" {
         url.access-deny = ("")
     }
     ```

6. **Resource Limits and Timeouts**:
   - Prevented DoS attacks by setting resource limits
   - PHP-FPM configuration:

     ```text
     pm = dynamic
     pm.max_children = 5
     pm.start_servers = 2
     pm.min_spare_servers = 1
     pm.max_spare_servers = 3
     request_terminate_timeout = 30s
     ```

7. **Logging and Monitoring**:
   - Enabled detailed error logging
   - PHP-FPM configuration:

     ```text
     catch_workers_output = yes
     php_admin_flag[log_errors] = on
     php_admin_value[error_log] = /var/log/fpm-php.www.log
     ```

   - Regular log analysis for suspicious activity

These measures ensure that the communication channel between Lighttpd and
PHP-FPM is secure, properly authenticated, and resistant to common attack
vectors.

**Q: What security measures would you implement to protect WordPress from common
attacks?**

**A:** To protect WordPress from common attacks, I've implemented a
comprehensive security strategy:

1. **Core Security Configuration**:
   - Disabled file editing in the admin area:

     ```php
     define('DISALLOW_FILE_EDIT', true);
     ```

   - Limited login attempts with a custom plugin or fail2ban
   - Implemented strong password policy for all users
   - Removed WordPress version information from HTML output
   - Used security keys in wp-config.php generated via WordPress API

2. **Plugin and Theme Management**:
   - Installed only necessary, well-maintained plugins
   - Implemented automatic updates for security patches
   - Regular audits of installed plugins for vulnerabilities
   - Removed inactive themes completely

3. **Database Security**:
   - Used non-default table prefix (not `wp_`)
   - Limited database user permissions to only needed operations
   - Implemented prepared statements for custom queries
   - Regular database backups with secure off-site storage

4. **Web Server Hardening**:
   - Implemented HTTP security headers:

     ```text
     add_header X-Content-Type-Options "nosniff";
     add_header X-Frame-Options "SAMEORIGIN";
     add_header X-XSS-Protection "1; mode=block";
     ```

   - Blocked access to sensitive files:

     ```text
     location ~ /\.ht {
         deny all;
     }
     location ~ wp-config.php {
         deny all;
     }
     ```

   - Protected wp-includes directory from direct access
   - Enabled HTTPS with properly configured SSL/TLS

5. **WordPress-Specific Protections**:
   - Protected the admin area with additional authentication
   - Implemented CAPTCHA for comments and login forms
   - Disabled XML-RPC if not needed:

     ```php
     add_filter('xmlrpc_enabled', '__return_false');
     ```

   - Limited REST API access to authenticated users when appropriate

6. **Content Security Measures**:
   - Implemented Content Security Policy (CSP)
   - Used Sanitization functions for user input
   - Validated all form submissions with nonces
   - Escaped output with WordPress functions like `esc_html()`

7. **Monitoring and Response**:
   - Activity logging for admin actions
   - File integrity monitoring for core WordPress files
   - Regular malware scanning
   - Notification system for suspicious activities
   - Comprehensive backup strategy for quick recovery

8. **Authentication Hardening**:
   - Implemented two-factor authentication for admin accounts
   - Used strong password requirements
   - Enforced regular password rotation
   - Changed the default login URL with a security plugin

9. **Infrastructure Protection**:
   - Web Application Firewall (ModSecurity rules)
   - Rate limiting for login and form submission attempts
   - IP-based access restrictions for admin area
   - Geolocation blocking for countries with high attack rates

These layered security measures create a defense-in-depth strategy that
addresses WordPress's common vulnerabilities while maintaining functionality for
legitimate users.

### 14. Additional Service (if implemented)

**Q: Explain why you chose your additional service and how it works within your
system.**

**A:** I chose to implement a secure FTP server (vsftpd) as my additional
service for several reasons:

1. **Purpose and Rationale**:
   - Provides secure file transfer capabilities for the system
   - Complements the web server functionality for content management
   - Demonstrates another common server role in enterprise environments
   - Relatively straightforward to configure securely
   - Shows understanding of different authentication mechanisms

2. **Integration with System Architecture**:
   - FTP service works alongside the web server to manage content
   - Uses system users for authentication, leveraging existing user management
   - Integrates with the UFW firewall configuration
   - Utilizes the same security principles as other services

3. **Technical Implementation**:
   - **Package**: vsftpd (Very Secure FTP Daemon)
   - **Configuration**: `/etc/vsftpd.conf`
   - **Process Management**: Controlled via systemd
   - **Authentication**: PAM integration with system users
   - **Storage**: Chrooted environments in user home directories

4. **Core Functionality**:
   - Secure file uploads and downloads
   - User isolation via chroot environments
   - Bandwidth control for fair resource usage
   - Logging of all transfers for accountability

5. **User Experience**:
   - Users connect with standard FTP clients
   - Authentication with system credentials
   - Access restricted to their home directories
   - Intuitive interface for file management

6. **Learning Value**:
   - Understanding network service configuration
   - Exposure to different security models for file access
   - Practice with PAM integration for authentication
   - Experience with service hardening techniques

By implementing vsftpd, I've added practical file transfer capabilities to the
system while demonstrating understanding of proper service configuration,
security hardening, and system integration—all key skills for system
administration.

**Q: What ports does your service use and what security measures did you
implement?**

**A:** My vsftpd service uses the following ports with these security measures:

**Port Configuration**:

- **Port 21**: Standard FTP command channel
- **Ports 40000-40100**: Passive mode data channel range (configured with
  `pasv_min_port` and `pasv_max_port`)

**Security Measures Implemented**:

1. **Authentication Security**:
   - Disabled anonymous access:

     ```text
     anonymous_enable=NO
     ```

   - Limited users to a whitelist:

     ```text
     userlist_enable=YES
     userlist_deny=NO
     userlist_file=/etc/vsftpd.user_list
     ```

   - Implemented account lockout via PAM
   - Enforced strong password requirements (via system password policy)

2. **Filesystem Security**:
   - Enabled chroot jail for all users:

     ```text
     chroot_local_user=YES
     allow_writeable_chroot=NO
     ```

   - Created separate, secure directories for chroot:

     ```bash
     mkdir -p /home/ftpusers
     chmod 555 /home/ftpusers
     ```

   - Prevented writing to root of chroot
   - Disabled dangerous FTP commands:

     ```text
     cmds_denied=SITE_CHMOD,DELE,RMD
     ```

3. **Encryption**:
   - Enabled TLS/SSL encryption:

     ```text
     ssl_enable=YES
     force_local_data_ssl=YES
     force_local_logins_ssl=YES
     ssl_tlsv1=YES
     ssl_sslv2=NO
     ssl_sslv3=NO
     ```

   - Generated strong certificates:

     ```bash
     openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/ssl/private/vsftpd.key -out /etc/ssl/certs/vsftpd.crt
     ```

   - Required secure cipher suites:

     ```text
     ssl_ciphers=HIGH
     ```

4. **Connection Security**:
   - Limited login attempts:

     ```text
     max_login_fails=3
     ```

   - Implemented connection timeouts:

     ```text
     idle_session_timeout=300
     data_connection_timeout=120
     ```

   - Restricted passive port range (as mentioned above):

     ```text
     pasv_min_port=40000
     pasv_max_port=40100
     ```

   - Limited connections per IP:

     ```text
     max_per_ip=2
     ```

5. **Firewall Configuration**:
   - Configured UFW to only allow necessary ports:

     ```bash
     sudo ufw allow 21/tcp
     sudo ufw allow 40000:40100/tcp
     ```

   - Implemented rate limiting for connection attempts

6. **Logging and Monitoring**:
   - Enabled verbose logging:

     ```text
     xferlog_enable=YES
     xferlog_std_format=YES
     log_ftp_protocol=YES
     ```

   - Set up log rotation for FTP logs
   - Created custom monitoring script for suspicious activity
   - Integrated with system monitoring

7. **System Integration**:
   - Configured AppArmor profile for vsftpd
   - Ran service with minimal privileges
   - Isolated FTP users from regular system users

These comprehensive security measures ensure the FTP service remains secure
while providing necessary functionality, following defense-in-depth principles.

**Q: How did you configure it to start automatically when the system boots?**

**A:** I configured the FTP service (vsftpd) to start automatically at boot
using systemd, which is the init system in Debian. Here's the complete process:

1. **Verify systemd service file exists**:

   ```bash
   cat /lib/systemd/system/vsftpd.service
   ```

   This file should contain:

   ```ini
   [Unit]
   Description=vsftpd FTP server
   After=network.target

   [Service]
   Type=simple
   ExecStart=/usr/sbin/vsftpd /etc/vsftpd.conf
   ExecReload=/bin/kill -HUP $MAINPID
   ExecStartPre=-/bin/mkdir -p /var/run/vsftpd/empty

   [Install]
   WantedBy=multi-user.target
   ```

2. **Enable the service** to start at boot:

   ```bash
   sudo systemctl enable vsftpd
   ```

   This creates a symbolic link from the system's copy of the service file to
   `/etc/systemd/system/multi-user.target.wants/`

3. **Verify the service is enabled**:

   ```bash
   sudo systemctl is-enabled vsftpd
   ```

   Should output: `enabled`

4. **Start the service manually** to test:

   ```bash
   sudo systemctl start vsftpd
   ```

5. **Check the service status**:

   ```bash
   sudo systemctl status vsftpd
   ```

   Should show: `Active: active (running)`

6. **Test automatic startup** by rebooting:

   ```bash
   sudo reboot
   ```

   After reboot, verify it's running:

   ```bash
   sudo systemctl status vsftpd
   ```

7. **Additional boot-time configuration**:
   - Created a systemd override file for custom options:

     ```bash
     sudo systemctl edit vsftpd
     ```

     Added:

     ```ini
     [Service]
     # Ensure service restarts on failure
     Restart=on-failure
     RestartSec=10

     # Security hardening
     PrivateTmp=true
     ProtectHome=false  # Needed for FTP access to home directories
     ProtectSystem=full
     ReadOnlyDirectories=/etc
     NoNewPrivileges=true
     ```

8. **Configure dependency ordering**: Ensured the service starts after the
   network and firewall:

   ```bash
   sudo systemctl edit vsftpd
   ```

   Added:

   ```ini
   [Unit]
   After=network-online.target ufw.service
   Wants=network-online.target
   ```

9. **Set up failure notification** (optional): Created a simple service
   monitoring script in cron:

   ```bash
   echo "*/10 * * * * root systemctl is-active --quiet vsftpd || systemctl restart vsftpd" | sudo tee /etc/cron.d/check-vsftpd
   ```

This configuration ensures that:

- The FTP service starts automatically at boot
- It starts in the correct order (after network and firewall)
- It has appropriate security restrictions
- It attempts to restart if it fails
- The system can recover from service failures

The use of systemd for service management follows modern best practices for
Linux system administration and provides reliable, consistent service behavior
across reboots.

### 15. Ultimate Security Hardening

**Q: What is defense in depth and how does your Born2beroot implementation
demonstrate it?**

**A:** Defense in depth is a comprehensive security strategy that uses multiple
layers of protection, so if one layer fails, others remain to protect the
system. My Born2beroot implementation demonstrates this principle through
several strategic layers:

1. **Physical/Virtualization Layer**:
   - Virtual machine isolation from host system
   - Encrypted virtual disk (if implemented)
   - Secure boot configuration
   - Limited hardware exposure

2. **System Access Layer**:
   - SSH configured on non-standard port (4242)
   - Key-based authentication or strong password policy
   - Limited failed login attempts
   - Restricted root login

3. **User Security Layer**:
   - Principle of least privilege with sudo configuration
   - Strong password policy (length, complexity, expiration)
   - Limited sudo access with specific command restrictions
   - User account separation (regular users vs. service accounts)

4. **Network Security Layer**:
   - UFW firewall with default deny policy
   - Only necessary ports exposed (SSH, web services if applicable)
   - Rate limiting for connection attempts
   - Network traffic monitoring

5. **Filesystem Security Layer**:
   - LVM partitioning for isolation between system components
   - Separate partitions for /home, /var, /tmp with appropriate mount options
   - Strict file permissions, especially for sensitive files
   - noexec, nosuid, nodev mount options where appropriate

6. **Application Security Layer**:
   - AppArmor mandatory access control
   - Service-specific security configurations
   - Regular updates and patch management
   - Minimal installed packages

7. **Monitoring and Detection Layer**:
   - Custom monitoring script for system status
   - Detailed logging of all security-relevant events
   - Log rotation and preservation
   - Sudo logging for accountability

8. **Policy Layer**:
   - Documented security policies
   - Regular security practices (like updating)
   - Clear administrative procedures
   - Controlled system modification

Each layer in my implementation provides different types of protection:

- **Prevention**: Strong authentication, firewall, permissions
- **Detection**: Logging, monitoring script, system auditing
- **Response**: Clear logs for investigation, safe recovery paths
- **Deterrence**: Limited attack surface, evident security measures

What makes this truly "defense in depth" is that these layers are complementary
but independent. For example, even if an attacker bypassed SSH security, they
would still face AppArmor restrictions, limited sudo access, and filesystem
protections.

**Q: How would you implement file integrity monitoring on your system?**

**A:** To implement comprehensive file integrity monitoring on my Born2beroot
system, I would:

1. **Install AIDE (Advanced Intrusion Detection Environment)**:

   ```bash
   sudo apt update
   sudo apt install aide
   ```

2. **Configure AIDE Database** in `/etc/aide/aide.conf`:

   ```bash
   # Define what changes we want to monitor
   # R = Regular file permissions
   # sha256 = SHA256 checksum
   # p = Permissions
   # i = Inode
   # n = Number of links
   # u = User
   # g = Group
   # s = Size
   # m = Modification time
   # a = Access time
   # c = Creation time

   # Rules for critical system files
   /etc/$ PERMS
   /etc p+i+u+g
   /bin NORMAL
   /sbin NORMAL
   /usr/bin NORMAL
   /usr/sbin NORMAL

   # Critical configuration files
   /etc/ssh/sshd_config CONTENT_EX
   /etc/passwd CONTENT_EX
   /etc/shadow CONTENT_EX
   /etc/sudoers CONTENT_EX
   /etc/sudoers.d/ CONTENT_EX

   # Monitor but allow logs to change
   /var/log$ p+u+g

   # Exclude temporary and frequently changing files
   !/var/log/.*
   !/var/spool/.*
   !/var/adm/utmp$
   !/var/run/.*pid$
   !/tmp/.*
   !/var/tmp/.*
   ```

3. **Initialize the AIDE Database**:

   ```bash
   sudo aideinit
   ```

   This creates the initial database at `/var/lib/aide/aide.db.new`

   ```bash
   # Copy the new database to the reference location
   sudo cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db
   ```

4. **Create Verification Script** at `/usr/local/bin/check-integrity.sh`:

   ```bash
   #!/bin/bash

   # Run AIDE check
   REPORT=$(sudo aide --check 2>&1)

   # Extract just the summary
   SUMMARY=$(echo "$REPORT" | grep -A 10 "Summary")

   # Check if there were changes
   if echo "$REPORT" | grep -q "found differences"; then
       # Send alert email with full report
       echo "$REPORT" | mail -s "INTEGRITY ALERT: $(hostname) file changes detected" root

       # Log to syslog
       logger -p auth.alert -t aide "File integrity violations detected"

       # Save detailed report
       echo "$REPORT" > /var/log/aide/$(date +%Y%m%d-%H%M%S)-violations.log
   fi

   # Log summary to a rotation-friendly log
   echo "$(date): $SUMMARY" >> /var/log/aide/daily-summary.log
   ```

   Make it executable:

   ```bash
   sudo chmod +x /usr/local/bin/check-integrity.sh
   ```

5. **Setup Automated Monitoring** via cron:

   ```bash
   sudo mkdir -p /var/log/aide
   echo "0 3 * * * root /usr/local/bin/check-integrity.sh" | sudo tee /etc/cron.d/aide-check
   ```

6. **Implement Database Updates** for legitimate changes:

   ```bash
   sudo cp /usr/local/bin/check-integrity.sh /usr/local/bin/update-integrity.sh
   ```

   Edit `/usr/local/bin/update-integrity.sh` to add:

   ```bash
   # Update the database after system updates
   sudo aide --update

   # Replace the reference database with the new one
   sudo cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db

   # Log the update
   logger -p auth.notice -t aide "File integrity database updated"
   ```

7. **Configure Log Rotation** for AIDE logs:

   ```bash
   sudo nano /etc/logrotate.d/aide
   ```

   Add:

   ```text
   /var/log/aide/*.log {
       weekly
       rotate 12
       compress
       delaycompress
       missingok
       notifempty
       create 0640 root adm
   }
   ```

8. **Add Integrity Verification to Critical System Events**: Create
   `/etc/apt/apt.conf.d/99aide-update`:

   ```text
   DPkg::Post-Invoke {"/usr/local/bin/update-integrity.sh";};
   ```

9. **Setup Alert Notifications** (if email is configured):

   ```bash
   sudo apt install mailutils
   ```

   Configure `/etc/aliases` to forward root mail to admin.

10. **Document Baseline and Recovery Procedures**: Create
    `/root/integrity-recovery.md` with procedures for:
    - Verifying alerts
    - Distinguishing legitimate from malicious changes
    - Rolling back unauthorized changes
    - Rebuilding compromised systems

This implementation provides:

- Automated daily integrity checking
- Immediate alerting for unauthorized changes
- Proper handling of legitimate changes
- Historical logging of all integrity events
- Integration with system update process

It demonstrates a comprehensive approach to file integrity monitoring that goes
beyond just installing a tool, encompassing configuration, automation, alerting,
and recovery planning.

**Q: What's your approach to keeping the system updated securely while
minimizing downtime?**

**A:** My approach to secure system updates with minimal downtime combines
automation, testing, and operational discipline:

1. **Update Strategy Implementation**:
   - **Create update policy document** outlining:
     - Classification of updates (security, bug fix, feature)
     - Timeline requirements for each type
     - Testing requirements
     - Rollback procedures

2. **Automated Update Notification**:
   - Install apt-listchanges for update review:

     ```bash
     sudo apt install apt-listchanges
     ```

   - Configure security notices:

     ```bash
     echo 'Unattended-Upgrade::Mail "root";' | sudo tee -a /etc/apt/apt.conf.d/50unattended-upgrades
     ```

   - Create daily update check script:

     ```bash
     #!/bin/bash
     # /usr/local/bin/update-check.sh
     updates=$(apt list --upgradable 2>/dev/null | grep -v "Listing..." | wc -l)
     security=$(apt list --upgradable 2>/dev/null | grep -i security | wc -l)
     if [ $security -gt 0 ]; then
         echo "SECURITY UPDATES: $security of $updates packages require updating" | mail -s "SECURITY: Updates needed on $(hostname)" root
     elif [ $updates -gt 0 ]; then
         echo "System updates available: $updates packages" | mail -s "Updates available on $(hostname)" root
     fi
     ```

3. **Staged Update Process**:
   - **Security Updates**: Apply immediately after minimal testing

     ```bash
     sudo apt update
     sudo apt upgrade -s # Simulation first
     sudo grep -i security /var/lib/apt/lists/*_InRelease | grep -i urgency=high
     sudo apt -y install $(apt list --upgradable | grep -i security | awk -F/ '{print $1}')
     ```

   - **Regular Updates**: Schedule during maintenance windows

     ```bash
     # Create snapshot before updates (if using LVM)
     sudo lvcreate -L 1G -s -n root_snap /dev/vg_born2beroot/lv_root

     # Apply updates
     sudo apt update && sudo apt upgrade -y

     # Test system functionality
     /usr/local/bin/system-test.sh
     ```

4. **Automation with Controlled Security Updates**:
   - Configure unattended-upgrades for security only:

     ```bash
     sudo apt install unattended-upgrades
     ```

   - Configure in `/etc/apt/apt.conf.d/50unattended-upgrades`:

     ```text
     Unattended-Upgrade::Allowed-Origins {
         "${distro_id}:${distro_codename}-security";
     };
     Unattended-Upgrade::Package-Blacklist {
         "mysql-server";
         "apache2";
     };
     Unattended-Upgrade::Automatic-Reboot "false";
     ```

5. **Pre-update Checklist**:
   - Create system snapshot if possible
   - Verify system health (disk space, services running)
   - Ensure backup is current
   - Notify users if service disruption possible
   - Review package changelogs

6. **Testing Procedure**:
   - Create `/usr/local/bin/system-test.sh` with:

     ```bash
     #!/bin/bash
     # Test core services
     services=("ssh" "ufw" "cron")
     for service in "${services[@]}"; do
         systemctl is-active --quiet $service
         if [ $? -ne 0 ]; then
             echo "CRITICAL: $service is not running after update" | mail -s "Update Failure: $(hostname)" root
             exit 1
         fi
     done

     # Test network connectivity
     ping -c 1 8.8.8.8 >/dev/null
     if [ $? -ne 0 ]; then
         echo "CRITICAL: Network connectivity issue after update" | mail -s "Update Failure: $(hostname)" root
         exit 1
     fi

     # Check for specific files that must exist
     for file in "/etc/ssh/sshd_config" "/etc/passwd" "/etc/shadow"; do
         if [ ! -f "$file" ]; then
             echo "CRITICAL: $file missing after update" | mail -s "Update Failure: $(hostname)" root
             exit 1
         fi
     done

     echo "System verification passed after update"
     exit 0
     ```

7. **Rollback Capability**:
   - For major updates, use LVM snapshots:

     ```bash
     # Restore from snapshot if needed
     sudo lvconvert --merge /dev/vg_born2beroot/root_snap
     ```

   - Keep apt history for package-level rollback:

     ```bash
     # View history
     cat /var/log/apt/history.log

     # Rollback specific package
     sudo apt install package-name=previous-version
     ```

8. **Kernel Update Handling**:
   - Keep at least one previous kernel
   - Test boot with new kernel before removing old
   - Configure GRUB with fallback options

9. **Documentation and Logging**:
   - Log all updates with:

     ```bash
     echo "$(date) - Update performed: $(apt list --upgradable | wc -l) packages" >> /var/log/system-updates.log
     ```

   - Maintain changelog awareness:

     ```bash
     apt-listchanges --show=changelogs -a apt upgrade
     ```

This approach balances security needs with system stability by:

- Prioritizing security updates
- Implementing proper testing
- Maintaining rollback capabilities
- Documenting all changes
- Automating where safe, but keeping critical updates under admin control

The result is a system that stays current with security patches while minimizing
the risk of disruption.
