#!/bin/bash
#===================================================
# shell Color and Header Library
# Author: Lesieur Dylan
# Description: Reusable color and formatting functions
#====================================================

# ======== COLOR DEFINITIONS ========
# Text colors
BLACK='\033[0;30m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'

# Bold text colors
BOLD_BLACK='\033[1;30m'
BOLD_RED='\033[1;31m'
BOLD_GREEN='\033[1;32m'
BOLD_YELLOW='\033[1;33m'
BOLD_BLUE='\033[1;34m'
BOLD_PURPLE='\033[1;35m'
BOLD_CYAN='\033[1;36m'
BOLD_WHITE='\033[1;37m'

# Background colors
BG_BLACK='\033[40m'
BG_RED='\033[41m'
BG_GREEN='\033[42m'
BG_YELLOW='\033[43m'
BG_BLUE='\033[44m'
BG_PURPLE='\033[45m'
BG_CYAN='\033[46m'
BG_WHITE='\033[47m'

# Text formats
BOLD='\033[1m'
UNDERLINE='\033[4m'
BLINK='\033[5m'
REVERSE='\033[7m'
HIDDEN='\033[8m'

# RESET
NC='\033[0m'

# Simple header with text
simple_header() {
    local text="$1"
    local width padding
    width=$(tput cols)
    padding=$(((width - ${#text}) / 2))

    echo ""
    printf "%${padding}s" ""
    echo -e "${BOLD_BLUE}${text}${NC}"
    printf "%${padding}s" ""
    printf "%${width}s\n" "" | tr " " "-"
    echo ""
}

# Box header
box_header() {
    local text="$1"
    local width text_width box_width padding
    width=$(tput cols)
    text_width=${#text}
    box_width=$((text_width + 4))
    padding=$(((width - box_width) / 2))

    echo ""
    printf "%${padding}s" ""
    printf "%${box_width}s\n" "" | tr " " "="

    printf "%${padding}s" ""
    echo -e "| ${BOLD_CYAN}${text}${NC} |"

    printf "%${padding}s" ""
    printf "%${box_width}s\n" "" | tr " " "="
    echo ""
}

# Double-line header
double_header() {
    local text="$1"
    local width padding
    width=$(tput cols)
    padding=$(((width - ${#text}) / 2))

    echo ""
    printf "%${width}s\n" "" | tr " " "="
    printf "%${padding}s" ""
    echo -e "${BOLD_GREEN}${text}${NC}"
    printf "%${width}s\n" "" | tr " " "="
    echo ""
}

# Full-width banner header
banner_header() {
    local text="$1"
    local width padding
    width=$(tput cols)
    padding=$(((width - ${#text}) / 2))

    echo ""
    echo -e "${BG_BLUE}${BOLD_WHITE}$(printf "%${width}s" "")${NC}"
    echo -e "${BG_BLUE}${BOLD_WHITE}$(printf "%${padding}s${text}%$(($width - $padding - ${#text}))s" "")${NC}"
    echo -e "${BG_BLUE}${BOLD_WHITE}$(printf "%${width}s" "")${NC}"
    echo ""
}

# System info header (like in your monitoring script)
system_header() {
    local hostname username date_time
    hostname=$(hostname)
    username=$(whoami)
    date_time=$(date '+%a %b %d %H:%M:%S %Y')

    echo -e "${YELLOW}Broadcast message from ${BOLD_YELLOW}root@${hostname}${NC} ${YELLOW}(tty1) (${date_time}):${NC}"
}

# Status message functions
success_msg() {
    echo -e "${GREEN}[✓] $1${NC}"
}

error_msg() {
    echo -e "${RED}[✗] $1${NC}"
}

warning_msg() {
    echo -e "${YELLOW}[!] $1${NC}"
}

info_msg() {
    echo -e "${BLUE}[i] $1${NC}"
}

# Progress bar function
progress_bar() {
    local percent=$1
    local width=50
    local completed remaining
    completed=$((percent * width / 100))
    remaining=$((width - completed))

    printf "${BOLD_BLUE}[${BOLD_GREEN}"
    printf "%0.s█" $(seq 1 $completed)
    printf "${BOLD_RED}"
    printf "%0.s▒" $(seq 1 $remaining)
    printf "${BOLD_BLUE}] ${percent}%%${NC}\r"
}

# Display the current date and time in the monitoring format
show_datetime() {
    local format="${1:-%Y-%m-%d %H:%M:%S}"
    echo -e "Current Date and Time (UTC - YYYY-MM-DD HH:MM:SS formatted): $(date -u +"$format")"
    echo -e "Current User's Login: $(whoami)"
    echo ""
}

# Check if this script is being sourced or executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Script is being executed directly - show demo
    clear
    show_datetime
    simple_header "SIMPLE HEADER EXAMPLE"
    box_header "BOX HEADER EXAMPLE"
    double_header "DOUBLE LINE HEADER EXAMPLE"
    banner_header "BANNER HEADER EXAMPLE"
    system_header
    echo ""
    success_msg "This is a success message!"
    error_msg "This is an error message!"
    warning_msg "This is a warning message!"
    info_msg "This is an information message!"
    echo ""
    echo "Progress bar example:"
    for i in {0..100..10}; do
        progress_bar $i
        sleep 0.1
    done
    echo -e "\n\n${BOLD_YELLOW}To use this library, source it in your scripts:${NC}"
    echo -e "${CYAN}source colorlib.sh${NC} or ${CYAN}. colorlib.sh${NC}"
    echo ""
fi
