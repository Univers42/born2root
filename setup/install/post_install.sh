#!/bin/bash

# Must be run as root after Debian installation

# Configure SSH
sed -i 's/#Port 22/Port 4242/' /etc/ssh/sshd_config
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl restart ssh

# Update packages
apt update && apt upgrade -y
apt install -y sudo ufw vim libpam-pwquality

# Set up sudo
usermod -aG sudo dlesieur
mkdir -p /var/log/sudo
echo "Defaults        logfile=\"/var/log/sudo/sudo.log\"" >/etc/sudoers.d/sudo_config
echo "Defaults        log_input,log_output" >>/etc/sudoers.d/sudo_config
echo "Defaults        requiretty" >>/etc/sudoers.d/sudo_config
chmod 440 /etc/sudoers.d/sudo_config

# Set up password policies
sed -i 's/PASS_MAX_DAYS\t99999/PASS_MAX_DAYS\t30/' /etc/login.defs
sed -i 's/PASS_MIN_DAYS\t0/PASS_MIN_DAYS\t2/' /etc/login.defs
sed -i 's/PASS_WARN_AGE\t7/PASS_WARN_AGE\t7/' /etc/login.defs
sed -i 's/# minlen = 8/minlen = 10/' /etc/security/pwquality.conf
sed -i 's/# dcredit = 0/dcredit = -1/' /etc/security/pwquality.conf
sed -i 's/# ucredit = 0/ucredit = -1/' /etc/security/pwquality.conf
sed -i 's/# maxrepeat = 0/maxrepeat = 3/' /etc/security/pwquality.conf
sed -i 's/# usercheck = 1/usercheck = 1/' /etc/security/pwquality.conf

# Set up UFW
ufw enable
ufw allow 4242/tcp

# Create monitoring script
cat >/root/monitoring.sh <<'EOF'
#!/bin/bash

# Architecture and kernel version
arch=$(uname -a)

# Physical processors
pcpu=$(grep "physical id" /proc/cpuinfo | sort | uniq | wc -l)

# Virtual processors
vcpu=$(grep "processor" /proc/cpuinfo | wc -l)

# RAM usage
total_ram=$(free -m | grep Mem | awk '{print $2}')
used_ram=$(free -m | grep Mem | awk '{print $3}')
ram_percentage=$(free | grep Mem | awk '{printf("%.2f"), $3/$2*100}')

# Disk usage
total_disk=$(df -h --total | grep total | awk '{print $2}')
used_disk=$(df -h --total | grep total | awk '{print $3}')
disk_percentage=$(df --total | grep total | awk '{print $5}')

# CPU load
cpu_load=$(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}')

# Last boot
last_boot=$(who -b | awk '{print $3 " " $4}')

# LVM check
lvm_status=$(if [ $(lsblk | grep "lvm" | wc -l) -gt 0 ]; then echo "yes"; else echo "no"; fi)

# TCP connections
tcp_conn=$(ss -ta | grep ESTAB | wc -l)

# User log
user_log=$(who | wc -l)

# IP and MAC
ip=$(hostname -I)
mac=$(ip link | grep "link/ether" | awk '{print $2}')

# Sudo commands
sudo_cmd=$(grep "COMMAND" /var/log/sudo/sudo.log 2>/dev/null | wc -l)

# Display all information
wall "
       #Architecture: $arch
       #CPU physical: $pcpu
       #vCPU: $vcpu
       #Memory Usage: $used_ram/${total_ram}MB ($ram_percentage%)
       #Disk Usage: $used_disk/${total_disk} ($disk_percentage)
       #CPU load: $cpu_load%
       #Last boot: $last_boot
       #LVM use: $lvm_status
       #Connections TCP: $tcp_conn ESTABLISHED
       #User log: $user_log
       #Network: IP $ip ($mac)
       #Sudo: $sudo_cmd cmd"
EOF

chmod +x /root/monitoring.sh
echo "*/10 * * * * root bash /root/monitoring.sh" >/etc/cron.d/monitoring

echo "Born2beRoot post-installation configuration complete!"
