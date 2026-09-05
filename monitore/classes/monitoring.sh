#!/bin/bash

# Set error handling
set -e

# Color codes
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo "Starting system monitoring script..."

# Architecture and kernel info
arch=$(uname -a)
echo "- Got architecture info"

# CPU physical cores
cpu_physical=$(grep "physical id" /proc/cpuinfo | sort | uniq | wc -l)
if [ "$cpu_physical" -eq 0 ]; then cpu_physical=1; fi
echo "- Got CPU physical info"

# CPU virtual cores
cpu_virtual=$(grep "processor" /proc/cpuinfo | wc -l)
echo "- Got CPU virtual info"

# RAM usage
ram_total=$(free -m | awk '$1 == "Mem:" {print $2}')
ram_used=$(free -m | awk '$1 == "Mem:" {print $3}')
ram_percent=$(free | awk '$1 == "Mem:" {printf("%.2f"), $3/$2*100}')
echo "- Got RAM usage info"

# Disk usage
disk_total=$(df -BG | grep '^/dev/' | grep -v '/boot$' | awk '{total += $2} END {print total}')
disk_used=$(df -BG | grep '^/dev/' | grep -v '/boot$' | awk '{used += $3} END {print used}')
disk_percent=$(df -BG | grep '^/dev/' | grep -v '/boot$' | awk '{used += $3} {total += $2} END {printf("%.2f"), used/total*100}')
echo "- Got disk usage info"

# CPU load
cpu_load=$(top -bn1 | grep "Cpu(s)" | awk '{printf("%.1f%%"), $2 + $4}')
echo "- Got CPU load info"

# Last boot
last_boot=$(who -b | awk '{print $3 " " $4}')
echo "- Got last boot info"

# LVM check
lvm_check=$(if [ $(lsblk | grep "lvm" | wc -l) -gt 0 ]; then echo "yes"; else echo "no"; fi)
echo "- Got LVM status"

# Active connections - using ss instead of netstat
if command -v netstat >/dev/null 2>&1; then
    tcp_connections=$(netstat -ant | grep ESTABLISHED | wc -l)
else
    # Use ss if netstat is not available
    tcp_connections=$(ss -t state established | wc -l)
fi
echo "- Got TCP connection info"

# User log count
user_log=$(who | wc -l)
echo "- Got user log info"

# Network info
ip_addr=$(hostname -I | awk '{print $1}')
if command -v ip >/dev/null 2>&1; then
    mac_addr=$(ip link show | grep "link/ether" | head -n1 | awk '{print $2}')
else
    mac_addr="N/A (ip command not found)"
fi
echo "- Got network info"

# Sudo command count - adjust based on your system's sudo log location
if [ -f "/var/log/sudo/sudo.log" ]; then
    sudo_count=$(grep COMMAND /var/log/sudo/sudo.log | wc -l)
elif [ -f "/var/log/auth.log" ]; then
    sudo_count=$(grep "sudo:" /var/log/auth.log | grep COMMAND | wc -l)
else
    sudo_count=$(journalctl _COMM=sudo 2>/dev/null | grep COMMAND | wc -l)
fi
echo "- Got sudo command count"

# Prepare the message
monitoring_message="
    #Architecture: $arch
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

# Show directly on console (in green)
echo -e "${GREEN}$monitoring_message${NC}"

# Also try to send via wall if available
if command -v wall >/dev/null 2>&1; then
    echo "- Broadcasting via wall command..."
    echo "$monitoring_message" | wall
else
    echo "Warning: 'wall' command not found, message only displayed locally"
fi

echo "Monitoring script completed."
