#!/bin/bash

# ANSI color codes for a more vibrant display
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
RESET='\033[0m'

# Get current user
CURRENT_USER=$(whoami)

# Display personalized ASCII art based on username
display_ascii_art() {
    case "$CURRENT_USER" in
    "dlesieur")
        echo -e "${CYAN}"
        echo -e "     _____  _      ______  _____ _____ ________  _________ "
        echo -e "    |  __ \| |    |  ____|/ ____|_   _|  ____\ \/ /__   __|"
        echo -e "    | |  | | |    | |__  | (___   | | | |__   \  /   | |   "
        echo -e "    | |  | | |    |  __|  \___ \  | | |  __|  /  \   | |   "
        echo -e "    | |__| | |____| |____ ____) |_| |_| |____/ /\ \  | |   "
        echo -e "    |_____/|______|______|_____/|_____|______/_/  \_\|_|   "
        echo -e "${YELLOW}    ========== BORN2BEROOT MASTER ADMIN ============${RESET}"
        ;;

    "root")
        echo -e "${RED}"
        echo -e "    ██████╗  ██████╗  ██████╗ ████████╗"
        echo -e "    ██╔══██╗██╔═══██╗██╔═══██╗╚══██╔══╝"
        echo -e "    ██████╔╝██║   ██║██║   ██║   ██║   "
        echo -e "    ██╔══██╗██║   ██║██║   ██║   ██║   "
        echo -e "    ██║  ██║╚██████╔╝╚██████╔╝   ██║   "
        echo -e "    ╚═╝  ╚═╝ ╚═════╝  ╚═════╝    ╚═╝   "
        echo -e "${YELLOW}    === WARNING: SYSTEM ADMINISTRATOR MODE ===${RESET}"
        ;;

    "evaluator")
        echo -e "${GREEN}"
        echo -e "    ███████╗██╗   ██╗ █████╗ ██╗     "
        echo -e "    ██╔════╝██║   ██║██╔══██╗██║     "
        echo -e "    █████╗  ██║   ██║███████║██║     "
        echo -e "    ██╔══╝  ╚██╗ ██╔╝██╔══██║██║     "
        echo -e "    ███████╗ ╚████╔╝ ██║  ██║███████╗"
        echo -e "    ╚══════╝  ╚═══╝  ╚═╝  ╚═╝╚══════╝"
        echo -e "${YELLOW}    === WELCOME 42 EVALUATOR! ENJOY YOUR STAY ===${RESET}"
        ;;

    *)
        echo -e "${MAGENTA}"
        echo -e "    ██╗    ██╗███████╗██╗      ██████╗ ██████╗ ███╗   ███╗███████╗"
        echo -e "    ██║    ██║██╔════╝██║     ██╔════╝██╔═══██╗████╗ ████║██╔════╝"
        echo -e "    ██║ █╗ ██║█████╗  ██║     ██║     ██║   ██║██╔████╔██║█████╗  "
        echo -e "    ██║███╗██║██╔══╝  ██║     ██║     ██║   ██║██║╚██╔╝██║██╔══╝  "
        echo -e "    ╚███╔███╔╝███████╗███████╗╚██████╗╚██████╔╝██║ ╚═╝ ██║███████╗"
        echo -e "     ╚══╝╚══╝ ╚══════╝╚══════╝ ╚═════╝ ╚═════╝ ╚═╝     ╚═╝╚══════╝"
        echo -e "${YELLOW}    === BORN2BEROOT SYSTEM: USER ${CURRENT_USER} LOGGED IN ===${RESET}"
        ;;
    esac

    # Add a fun fact about Linux/Unix every time
    display_fun_fact
}

# Display a random fun fact
display_fun_fact() {
    echo -e "\n${BLUE}Did you know?${RESET}"

    # Array of fun facts
    facts=(
        "The mascot of Linux is a penguin named Tux."
        "UNIX was created in the 1970s at AT&T Bell Labs."
        "The first version of Debian was released in 1993."
        "The Linux kernel has over 27.8 million lines of code."
        "Over 97% of the world's supercomputers run on Linux."
        "The term 'bug' originated when a moth was found in a relay of Harvard's Mark II computer."
        "Linus Torvalds created Linux as a free alternative to MINIX."
        "SSH was created by Tatu Ylonen in 1995 after a password-sniffing attack."
        "The 'sudo' command stands for 'superuser do'."
        "The 'grep' command is short for 'global regular expression print'."
    )

    # Get a random fact
    random_index=$((RANDOM % ${#facts[@]}))
    echo -e "${CYAN}${facts[$random_index]}${RESET}"

    echo -e ""
}

# Call the main function
display_ascii_art
