#!/bin/bash

# Colors for better readability (inlined instead of sourcing)
BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Current date and time in UTC
date_time=$(date -u +"%Y-%m-%d %H:%M:%S")

# System information gathering
architecture=$(uname -a)
cpu_physical=$(grep "physical id" /proc/cpuinfo | sort -u | wc -l)
vcpu=$(grep "processor" /proc/cpuinfo | wc -l)

# Memory information
mem_used=$(free -m | awk '$1 == "Mem:" {print $3}')
mem_total=$(free -m | awk '$1 == "Mem:" {print $2}')
mem_percent=$(free | awk '$1 == "Mem:" {printf("%.2f"), $3/$2*100}')

# Disk information
disk_used=$(df -Bm | grep '^/dev/' | grep -v '/boot$' | awk '{ut += $3} END {print ut/1024}')
disk_total=$(df -Bg | grep '^/dev/' | grep -v '/boot$' | awk '{ft += $2} END {print ft}')
disk_percent=$(df -Bm | grep '^/dev/' | grep -v '/boot$' | awk '{ut += $3} {ft+= $2} END {printf("%d"), ut*100/ft}')

# CPU load and other system info
cpu_load=$(top -bn1 | grep "Cpu" | awk '{printf "%.1f", $2 + $4}')
last_boot=$(who -b | awk '{print $3 " " $4}')
lvm_use=$(if [ $(lsblk | grep "lvm" | wc -l) -gt 0 ]; then echo yes; else echo no; fi)
tcp_count=$(ss -ta | grep ESTAB | wc -l)
user_count=$(who | wc -l)
ip=$(hostname -I | awk '{print $1}')
mac=$(ip link show | grep "link/ether" | awk '{print $2}' | head -1)
sudo_count=$(grep "COMMAND" /var/log/sudo/sudo.log 2>/dev/null | wc -l)

# Create a simple banner with a box around it
print_banner() {
    local text="$1"
    local length=${#text}
    local line=$(printf "%${length}s" | tr " " "#")

    echo "#$line#"
    echo "# $text #"
    echo "#$line#"
}

# Build monitoring message
monitoring_message="
$(print_banner "SYSTEM MONITORING - $(hostname)")

#Architecture: $architecture
#CPU physical: $cpu_physical
#vCPU: $vcpu
#Memory Usage: $mem_used/${mem_total}MB ($mem_percent%)
#Disk Usage: $disk_used/${disk_total}GB ($disk_percent%)
#CPU load: $cpu_load%
#Last boot: $last_boot
#LVM use: $lvm_use
#Connections TCP: $tcp_count ESTABLISHED
#User log: $user_count
#Network: IP $ip ($mac)
#Sudo: $sudo_count cmd

#Current Date and Time (UTC): $date_time
#Current User's Login: $(whoami)
"

# Display message in the current terminal
echo -e "$monitoring_message"

# Also broadcast to all users with wall
echo -e "$monitoring_message" | wall
