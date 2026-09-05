#!/bin/bash

# System Monitor & Specs Display Script
# Current Date and Time (UTC): 2025-04-04 16:35:45
# Current User: LESdylan

# Colors and styling
BOLD="\e[1m"
UNDERLINE="\e[4m"
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
MAGENTA="\e[35m"
CYAN="\e[36m"
WHITE="\e[37m"
RESET="\e[0m"

# Install dependencies if not present
check_and_install_deps() {
    local deps=("figlet" "lolcat" "neofetch" "htop" "inxi" "smartmontools" "sysstat" "duf")
    local to_install=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            to_install+=("$dep")
        fi
    done

    if [ ${#to_install[@]} -ne 0 ]; then
        echo -e "${YELLOW}Installing required dependencies: ${to_install[*]}${RESET}"
        sudo apt update
        sudo apt install -y "${to_install[@]}"
    fi
}

# Display header
show_header() {
    clear
    figlet -f slant "System Info" | lolcat
    echo -e "${BOLD}${BLUE}$(date '+%Y-%m-%d %H:%M:%S')${RESET}"
    echo -e "${BOLD}${GREEN}User: $(whoami)@$(hostname)${RESET}"
    echo
}

# Display system summary using neofetch
show_system_summary() {
    echo -e "${BOLD}${MAGENTA}${UNDERLINE}SYSTEM OVERVIEW${RESET}"
    echo
    neofetch --off
    echo
}

# Display detailed CPU information
show_cpu_info() {
    echo -e "${BOLD}${YELLOW}${UNDERLINE}CPU DETAILS${RESET}"
    echo
    echo -e "${CYAN}CPU Model:${RESET} $(lscpu | grep 'Model name' | cut -d':' -f2- | sed 's/^[ \t]*//')"
    echo -e "${CYAN}Architecture:${RESET} $(lscpu | grep 'Architecture' | cut -d':' -f2- | sed 's/^[ \t]*//')"
    echo -e "${CYAN}CPU Cores:${RESET} $(lscpu | grep '^CPU(s)' | cut -d':' -f2- | sed 's/^[ \t]*//')"
    echo -e "${CYAN}Thread(s) per core:${RESET} $(lscpu | grep 'Thread(s) per core' | cut -d':' -f2- | sed 's/^[ \t]*//')"
    echo -e "${CYAN}CPU MHz:${RESET} $(lscpu | grep 'CPU MHz' | cut -d':' -f2- | sed 's/^[ \t]*//')"
    echo -e "${CYAN}CPU Max MHz:${RESET} $(lscpu | grep 'CPU max MHz' | cut -d':' -f2- | sed 's/^[ \t]*//' 2>/dev/null || echo "N/A")"
    echo -e "${CYAN}Virtualization:${RESET} $(lscpu | grep 'Virtualization' | cut -d':' -f2- | sed 's/^[ \t]*//' 2>/dev/null || echo "Not available")"
    echo

    # CPU load
    echo -e "${CYAN}CPU Load:${RESET}"
    mpstat -P ALL 1 1 | grep -v CPU | grep -v Average | awk '{print "Core " $3 ": " $4+$5+$6+$7+$8+$9+$10+$11+$12 "% utilized"}'
    echo
}

# Display memory information
show_memory_info() {
    echo -e "${BOLD}${GREEN}${UNDERLINE}MEMORY INFORMATION${RESET}"
    echo

    # Get memory info using free command
    local total=$(free -m | grep Mem | awk '{print $2}')
    local used=$(free -m | grep Mem | awk '{print $3}')
    local free=$(free -m | grep Mem | awk '{print $4}')
    local shared=$(free -m | grep Mem | awk '{print $5}')
    local cached=$(free -m | grep Mem | awk '{print $6}')
    local available=$(free -m | grep Mem | awk '{print $7}')

    # Calculate usage percentage
    local usage_percent=$(awk "BEGIN {printf \"%.2f\", ($used/$total)*100}")

    echo -e "${CYAN}Total Memory:${RESET} $total MB"
    echo -e "${CYAN}Used Memory:${RESET} $used MB"
    echo -e "${CYAN}Free Memory:${RESET} $free MB"
    echo -e "${CYAN}Shared Memory:${RESET} $shared MB"
    echo -e "${CYAN}Cached Memory:${RESET} $cached MB"
    echo -e "${CYAN}Available Memory:${RESET} $available MB"
    echo -e "${CYAN}Memory Usage:${RESET} $usage_percent%"

    # Make a bar showing memory usage
    local bar_size=50
    local used_bars=$(awk "BEGIN {printf \"%.0f\", $usage_percent*$bar_size/100}")
    local free_bars=$((bar_size - used_bars))

    echo -ne "${CYAN}Memory Usage: [${RED}"
    for ((i = 0; i < used_bars; i++)); do echo -ne "#"; done
    echo -ne "${GREEN}"
    for ((i = 0; i < free_bars; i++)); do echo -ne "#"; done
    echo -e "${CYAN}]${RESET}"
    echo
}

# Display GPU information
show_gpu_info() {
    echo -e "${BOLD}${RED}${UNDERLINE}GPU INFORMATION${RESET}"
    echo

    # Check if inxi is installed for better GPU info
    if command -v inxi &>/dev/null; then
        inxi -G
    else
        echo -e "${CYAN}GPU Information:${RESET}"
        lspci | grep -E 'VGA|3D|Display' | sed 's/^[0-9a-f]*:[0-9a-f]*.[0-9a-f]* //'
    fi
    echo
}

# Display disk information
show_disk_info() {
    echo -e "${BOLD}${BLUE}${UNDERLINE}DISK INFORMATION${RESET}"
    echo

    if command -v duf &>/dev/null; then
        duf
    else
        df -h | grep -v tmpfs | grep -v loop
    fi

    # Show disk health if smartctl is available
    if command -v smartctl &>/dev/null; then
        echo -e "\n${CYAN}Disk Health:${RESET}"
        for disk in $(ls /dev/sd* 2>/dev/null | grep -v [0-9]); do
            echo -e "${YELLOW}$disk:${RESET}"
            sudo smartctl -H $disk 2>/dev/null || echo "Unable to check health"
        done

        for disk in $(ls /dev/nvme* 2>/dev/null | grep -v p[0-9]); do
            echo -e "${YELLOW}$disk:${RESET}"
            sudo smartctl -H $disk 2>/dev/null || echo "Unable to check health"
        done
    fi
    echo
}

# Show network information
show_network_info() {
    echo -e "${BOLD}${CYAN}${UNDERLINE}NETWORK INFORMATION${RESET}"
    echo

    ip -c a | grep -v "lo" | grep -v "host"

    echo -e "\n${CYAN}Network Connections:${RESET}"
    ss -tulpn | grep LISTEN | grep -v "127.0.0.1"
    echo
}

# Show system load
show_system_load() {
    echo -e "${BOLD}${MAGENTA}${UNDERLINE}SYSTEM LOAD${RESET}"
    echo

    uptime
    echo -e "\n${CYAN}Load Average Explanation:${RESET}"
    echo "The three numbers represent load over the last 1, 5, and 15 minutes"
    echo "Values below your CPU core count ($cores) mean your system is not overloaded"
    echo
}

# Show most resource-intensive processes
show_top_processes() {
    echo -e "${BOLD}${WHITE}${UNDERLINE}TOP PROCESSES${RESET}"
    echo

    echo -e "${CYAN}CPU Usage:${RESET}"
    ps aux --sort=-%cpu | head -6

    echo -e "\n${CYAN}Memory Usage:${RESET}"
    ps aux --sort=-%mem | head -6
    echo

    cores=$(grep -c ^processor /proc/cpuinfo)
    echo -e "You have ${BOLD}${cores}${RESET} CPU cores. Processes can use up to ${BOLD}100%${RESET} per core."
    echo
}

# Main function with interactive menu
main() {
    check_and_install_deps

    while true; do
        show_header

        echo -e "${BOLD}${YELLOW}Choose an option:${RESET}"
        echo -e "  ${GREEN}1)${RESET} Show system summary"
        echo -e "  ${GREEN}2)${RESET} Show detailed CPU information"
        echo -e "  ${GREEN}3)${RESET} Show memory information"
        echo -e "  ${GREEN}4)${RESET} Show GPU information"
        echo -e "  ${GREEN}5)${RESET} Show disk information"
        echo -e "  ${GREEN}6)${RESET} Show network information"
        echo -e "  ${GREEN}7)${RESET} Show system load"
        echo -e "  ${GREEN}8)${RESET} Show top processes"
        echo -e "  ${GREEN}9)${RESET} Full system report"
        echo -e "  ${GREEN}m)${RESET} Monitor mode (real-time)"
        echo -e "  ${GREEN}q)${RESET} Quit"
        echo

        read -p "Enter your choice: " choice
        echo

        case $choice in
        1)
            show_system_summary
            read -p "Press Enter to continue..."
            ;;
        2)
            show_cpu_info
            read -p "Press Enter to continue..."
            ;;
        3)
            show_memory_info
            read -p "Press Enter to continue..."
            ;;
        4)
            show_gpu_info
            read -p "Press Enter to continue..."
            ;;
        5)
            show_disk_info
            read -p "Press Enter to continue..."
            ;;
        6)
            show_network_info
            read -p "Press Enter to continue..."
            ;;
        7)
            show_system_load
            read -p "Press Enter to continue..."
            ;;
        8)
            show_top_processes
            read -p "Press Enter to continue..."
            ;;
        9)
            show_system_summary
            show_cpu_info
            show_memory_info
            show_gpu_info
            show_disk_info
            show_network_info
            show_system_load
            show_top_processes
            read -p "Press Enter to continue..."
            ;;
        m | M)
            clear
            echo -e "${BOLD}${YELLOW}Entering monitor mode. Press Ctrl+C to exit.${RESET}"
            if command -v htop &>/dev/null; then
                htop
            else
                top
            fi
            ;;
        q | Q)
            echo -e "${GREEN}Goodbye!${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid option. Press Enter to continue...${RESET}"
            read
            ;;
        esac
    done
}

# Run the main function
main
