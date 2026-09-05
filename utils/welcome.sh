#!/bin/bash

# ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# Get user information
USER_NAME=$(whoami)
LAST_LOGIN=$(last -1 $USER_NAME | head -1 | awk '{print $4, $5, $6, $7}')
CURRENT_DATE=$(date +"%Y-%m-%d %H:%M:%S")
HOSTNAME=$(hostname)
UPTIME=$(uptime -p)
LOAD=$(cat /proc/loadavg | awk '{print $1, $2, $3}')

# Clear the screen for a clean display
clear

# Display header with system info
echo -e "${BLUE}${BOLD}╔════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BLUE}${BOLD}║                  BORN2BEROOT SECURE SYSTEM                 ║${RESET}"
echo -e "${BLUE}${BOLD}╚════════════════════════════════════════════════════════════╝${RESET}"

# Display user-specific ASCII art
case "$USER_NAME" in
"dlesieur")
    echo -e "${CYAN}"
    echo -e "  _____  _      ______  _____ _____ ________  _________ "
    echo -e " |  __ \| |    |  ____|/ ____|_   _|  ____\ \/ /__   __|"
    echo -e " | |  | | |    | |__  | (___   | | | |__   \  /   | |   "
    echo -e " | |  | | |    |  __|  \___ \  | | |  __|  /  \   | |   "
    echo -e " | |__| | |____| |____ ____) |_| |_| |____/ /\ \  | |   "
    echo -e " |_____/|______|______|_____/|_____|______/_/  \_\|_|   "
    echo -e "${RESET}"
    ;;

"root")
    echo -e "${RED}"
    echo -e " ██████╗  ██████╗  ██████╗ ████████╗ █████╗  ██████╗ ██████╗███████╗███████╗███████╗"
    echo -e " ██╔══██╗██╔═══██╗██╔═══██╗╚══██╔══╝██╔══██╗██╔════╝██╔════╝██╔════╝██╔════╝██╔════╝"
    echo -e " ██████╔╝██║   ██║██║   ██║   ██║   ███████║██║     ██║     █████╗  ███████╗███████╗"
    echo -e " ██╔══██╗██║   ██║██║   ██║   ██║   ██╔══██║██║     ██║     ██╔══╝  ╚════██║╚════██║"
    echo -e " ██║  ██║╚██████╔╝╚██████╔╝   ██║   ██║  ██║╚██████╗╚██████╗███████╗███████║███████║"
    echo -e " ╚═╝  ╚═╝ ╚═════╝  ╚═════╝    ╚═╝   ╚═╝  ╚═╝ ╚═════╝ ╚═════╝╚══════╝╚══════╝╚══════╝"
    echo -e "${RESET}"
    ;;

"evaluator")
    echo -e "${GREEN}"
    echo -e " ███████╗██╗   ██╗ █████╗ ██╗     ██╗   ██╗ █████╗ ████████╗ ██████╗ ██████╗ "
    echo -e " ██╔════╝██║   ██║██╔══██╗██║     ██║   ██║██╔══██╗╚══██╔══╝██╔═══██╗██╔══██╗"
    echo -e " █████╗  ██║   ██║███████║██║     ██║   ██║███████║   ██║   ██║   ██║██████╔╝"
    echo -e " ██╔══╝  ╚██╗ ██╔╝██╔══██║██║     ██║   ██║██╔══██║   ██║   ██║   ██║██╔══██╗"
    echo -e " ███████╗ ╚████╔╝ ██║  ██║███████╗╚██████╔╝██║  ██║   ██║   ╚██████╔╝██║  ██║"
    echo -e " ╚══════╝  ╚═══╝  ╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚═╝  ╚═╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝"
    echo -e "${RESET}"
    ;;

*)
    echo -e "${MAGENTA}"
    echo -e " ██╗    ██╗███████╗██╗      ██████╗ ██████╗ ███╗   ███╗███████╗"
    echo -e " ██║    ██║██╔════╝██║     ██╔════╝██╔═══██╗████╗ ████║██╔════╝"
    echo -e " ██║ █╗ ██║█████╗  ██║     ██║     ██║   ██║██╔████╔██║█████╗  "
    echo -e " ██║███╗██║██╔══╝  ██║     ██║     ██║   ██║██║╚██╔╝██║██╔══╝  "
    echo -e " ╚███╔███╔╝███████╗███████╗╚██████╗╚██████╔╝██║ ╚═╝ ██║███████╗"
    echo -e "  ╚══╝╚══╝ ╚══════╝╚══════╝ ╚═════╝ ╚═════╝ ╚═╝     ╚═╝╚══════╝"
    echo -e "${RESET}"
    ;;
esac

# Display information box
echo -e "${YELLOW}╔════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${YELLOW}║                     SESSION INFORMATION                    ║${RESET}"
echo -e "${YELLOW}╠════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${YELLOW}║${RESET} ${BOLD}User:${RESET}        $USER_NAME"
echo -e "${YELLOW}║${RESET} ${BOLD}Hostname:${RESET}    $HOSTNAME"
echo -e "${YELLOW}║${RESET} ${BOLD}Date & Time:${RESET} $CURRENT_DATE"
echo -e "${YELLOW}║${RESET} ${BOLD}Last Login:${RESET}  $LAST_LOGIN"
echo -e "${YELLOW}║${RESET} ${BOLD}Uptime:${RESET}      $UPTIME"
echo -e "${YELLOW}║${RESET} ${BOLD}Load Avg:${RESET}    $LOAD"
echo -e "${YELLOW}╚════════════════════════════════════════════════════════════╝${RESET}"

# Display security reminder
echo -e "\n${CYAN}${BOLD}SECURITY REMINDER:${RESET}"
echo -e "• All actions on this system are logged and monitored"
echo -e "• Unauthorized access is strictly prohibited"
echo -e "• Password must be changed every 30 days\n"

# Get a random tip
tips=(
    "Use 'sudo' to execute commands with superuser privileges"
    "Check system logs with 'journalctl' to troubleshoot issues"
    "Monitor system resources with 'htop' or 'top'"
    "Use 'ctrl+r' to search command history"
    "Remember to logout when you're done for security reasons"
    "Use 'ssh-keygen' to create SSH keys for password-less login"
    "Check disk usage with 'df -h' and directory size with 'du -sh'"
    "Try 'tmux' for managing multiple terminal sessions"
    "Born2beRoot project teaches essential sysadmin skills"
    "Use 'man' command to learn more about any command"
)
random_index=$((RANDOM % ${#tips[@]}))

echo -e "${GREEN}${BOLD}TIP OF THE DAY:${RESET} ${tips[$random_index]}\n"
