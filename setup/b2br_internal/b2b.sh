#!/bin/bash

# Source color and header library
source ./color_scheme.sh # Adjust path as needed

# Clear screen for clean presentation
clear

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
last_boot=$(who -b | awk '$1 == "system" {print $3 " " $4}')
lvm_use=$(if [ $(lsblk | grep "lvm" | wc -l) -gt 0 ]; then echo yes; else echo no; fi)
tcp_count=$(ss -ta | grep ESTAB | wc -l)
user_count=$(who | wc -l)
ip=$(hostname -I | awk '{print $1}')
mac=$(ip link show | grep "link/ether" | awk '{print $2}' | head -1)
sudo_count=$(grep "COMMAND" /var/log/sudo/sudo.log 2>/dev/null | wc -l)

# Get terminal width for centered text
TERM_WIDTH=$(tput cols)

# Function to print centered text with color
print_centered() {
    local text="$1"
    local color="${2:-$WHITE}"
    local padding
    padding=$(((TERM_WIDTH - ${#text}) / 2))
    printf "%${padding}s" ""
    echo -e "${color}${text}${NC}"
}

# Function to print a divider
print_divider() {
    local char="${1:-─}"
    local color="${2:-$BLUE}"
    echo -e "${color}$(printf '%*s' "$TERM_WIDTH" '' | tr ' ' "$char")${NC}"
}

# Function to print labeled data
print_info() {
    local label="$1"
    local value="$2"
    local label_color="${3:-$BOLD_CYAN}"
    local value_color="${4:-$WHITE}"

    printf "${label_color}%-20s${NC} : ${value_color}%s${NC}\n" "$label" "$value"
}

# --- START OUTPUT ---

# Header section
print_divider "═" "$BOLD_BLUE"
print_centered "SYSTEM MONITORING REPORT" "$BOLD_YELLOW"
print_centered "$(hostname)" "$BOLD_GREEN"
print_divider "═" "$BOLD_BLUE"
echo

# Date and user section
print_centered "[$date_time UTC]" "$CYAN"
print_centered "Session: $(whoami)" "$CYAN"
echo

# Broadcast message header
print_divider "─" "$YELLOW"
echo -e "${YELLOW}Broadcast message from ${BOLD_YELLOW}root@$(hostname)${NC} ${YELLOW}(tty1) ($(date '+%a %b %d %H:%M:%S %Y')):${NC}"
print_divider "─" "$YELLOW"
echo

# System info section
echo -e "${BOLD_WHITE}█ SYSTEM INFORMATION${NC}"
print_info "Architecture" "$architecture" "$BOLD_BLUE" "$GREEN"
print_info "Last Boot" "$last_boot" "$BOLD_BLUE" "$GREEN"
print_info "LVM Use" "$lvm_use" "$BOLD_BLUE" "$GREEN"
echo

# CPU section
echo -e "${BOLD_WHITE}█ CPU STATISTICS${NC}"
print_info "Physical CPUs" "$cpu_physical" "$BOLD_BLUE" "$GREEN"
print_info "Virtual CPUs" "$vcpu" "$BOLD_BLUE" "$GREEN"
print_info "CPU Load" "$cpu_load%" "$BOLD_BLUE" "$GREEN"
echo

# Memory section
echo -e "${BOLD_WHITE}█ MEMORY USAGE${NC}"
# Create a visual memory bar
mem_bar_length=40
mem_filled=$((mem_bar_length * mem_used / mem_total))
mem_bar="["
for ((i = 0; i < mem_bar_length; i++)); do
    if [ $i -lt $mem_filled ]; then
        mem_bar+="█"
    else
        mem_bar+="░"
    fi
done
mem_bar+="]"
print_info "Memory" "$mem_used/$mem_total MB ($mem_percent%)" "$BOLD_BLUE" "$GREEN"
echo -e "${BOLD_WHITE}  ${mem_bar} ${NC}"
echo

# Disk section
echo -e "${BOLD_WHITE}█ DISK USAGE${NC}"
# Create a visual disk bar
disk_bar_length=40
disk_filled=$((disk_bar_length * disk_percent / 100))
disk_bar="["
for ((i = 0; i < disk_bar_length; i++)); do
    if [ $i -lt $disk_filled ]; then
        disk_bar+="█"
    else
        disk_bar+="░"
    fi
done
disk_bar+="]"
print_info "Disk" "$disk_used/$disk_total GB ($disk_percent%)" "$BOLD_BLUE" "$GREEN"
echo -e "${BOLD_WHITE}  ${disk_bar} ${NC}"
echo

# Network section
echo -e "${BOLD_WHITE}█ NETWORK INFORMATION${NC}"
print_info "IP Address" "$ip" "$BOLD_BLUE" "$GREEN"
print_info "MAC Address" "$mac" "$BOLD_BLUE" "$GREEN"
print_info "TCP Connections" "$tcp_count ESTABLISHED" "$BOLD_BLUE" "$GREEN"
echo

# User section
echo -e "${BOLD_WHITE}█ USER ACTIVITY${NC}"
print_info "Users Logged In" "$user_count" "$BOLD_BLUE" "$GREEN"
print_info "Sudo Commands" "$sudo_count cmd" "$BOLD_BLUE" "$GREEN"
echo

# Footer
print_divider "═" "$BOLD_BLUE"
print_centered "MONITORING COMPLETE" "$BOLD_YELLOW"
print_centered "Press CTRL+C to exit" "$CYAN"
print_divider "═" "$BOLD_BLUE"
