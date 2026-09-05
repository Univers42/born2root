#!/bin/bash

# Colors for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Clear screen
clear

# Display header
echo -e "${BLUE}==============================================${NC}"
echo -e "${BOLD}        MONITORING CRONTAB MANAGER          ${NC}"
echo -e "${BLUE}==============================================${NC}"
echo -e "${YELLOW}Current Date and Time (UTC): $(date -u +"%Y-%m-%d %H:%M:%S")${NC}"
echo -e "${YELLOW}Current User: $(whoami)${NC}"
echo ""

# Path to the monitoring script - CHANGE THIS to your actual path
MONITORING_SCRIPT="/home/LESdylan/monitoring.sh"

# Check if monitoring script exists
if [ ! -f "$MONITORING_SCRIPT" ]; then
    echo -e "${RED}Error: Monitoring script not found at $MONITORING_SCRIPT${NC}"
    read -p "Enter the correct path to monitoring.sh: " MONITORING_SCRIPT

    if [ ! -f "$MONITORING_SCRIPT" ]; then
        echo -e "${RED}Error: Script still not found. Exiting.${NC}"
        exit 1
    fi
fi

# Make sure the script is executable
chmod +x "$MONITORING_SCRIPT"

# Function to check if monitoring entry exists in crontab
check_crontab() {
    if sudo crontab -l 2>/dev/null | grep -q "$MONITORING_SCRIPT"; then
        echo -e "${GREEN}✓ Monitoring script is in crontab${NC}"
        sudo crontab -l | grep --color=auto "$MONITORING_SCRIPT"
        return 0 # Entry exists
    else
        echo -e "${YELLOW}! Monitoring script is not in crontab${NC}"
        return 1 # Entry doesn't exist
    fi
}

# Function to add monitoring script to crontab
add_to_crontab() {
    echo -e "\n${BLUE}=== Adding Monitoring Script to Crontab ===${NC}"

    # Check if it's already in crontab
    if check_crontab; then
        echo -e "${YELLOW}! Entry already exists. No changes made.${NC}"
        return 0
    fi

    # Get existing crontab content
    crontab_content=$(sudo crontab -l 2>/dev/null)

    # Add new cron job for monitoring script
    echo -e "${YELLOW}Adding entry to run every 10 minutes...${NC}"

    # We use a here-document to create the new crontab content
    {
        if [ -n "$crontab_content" ]; then
            echo "$crontab_content"
        fi
        echo "*/10 * * * * $MONITORING_SCRIPT"
    } | sudo crontab -

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Monitoring script added to crontab successfully${NC}"
        echo -e "${GREEN}✓ Script will run every 10 minutes${NC}"
    else
        echo -e "${RED}✗ Failed to update crontab${NC}"
        return 1
    fi

    return 0
}

# Function to remove monitoring script from crontab
remove_from_crontab() {
    echo -e "\n${BLUE}=== Removing Monitoring Script from Crontab ===${NC}"

    # Check if it's in crontab
    if ! check_crontab; then
        echo -e "${YELLOW}! Entry doesn't exist. No changes needed.${NC}"
        return 0
    fi

    # Get existing crontab content and remove our script
    sudo crontab -l 2>/dev/null | grep -v "$MONITORING_SCRIPT" | sudo crontab -

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Monitoring script removed from crontab successfully${NC}"
    else
        echo -e "${RED}✗ Failed to update crontab${NC}"
        return 1
    fi

    return 0
}

# Function to modify the cron schedule
modify_schedule() {
    echo -e "\n${BLUE}=== Modify Cron Schedule ===${NC}"

    echo -e "${YELLOW}Current schedule: ${NC}"
    sudo crontab -l 2>/dev/null | grep "$MONITORING_SCRIPT" | awk '{print $1, $2, $3, $4, $5}'

    echo -e "\n${YELLOW}Common cron schedules:${NC}"
    echo "1. Every 10 minutes: */10 * * * *"
    echo "2. Every 5 minutes: */5 * * * *"
    echo "3. Every 30 minutes: */30 * * * *"
    echo "4. Once an hour: 0 * * * *"
    echo "5. Once a day at midnight: 0 0 * * *"
    echo "6. Custom schedule"

    read -p "Select schedule [1-6]: " schedule_option

    case $schedule_option in
    1) new_schedule="*/10 * * * *" ;;
    2) new_schedule="*/5 * * * *" ;;
    3) new_schedule="*/30 * * * *" ;;
    4) new_schedule="0 * * * *" ;;
    5) new_schedule="0 0 * * *" ;;
    6)
        echo -e "${YELLOW}Enter custom cron schedule (5 fields: minute hour day month weekday):${NC}"
        read -p "> " new_schedule
        ;;
    *)
        echo -e "${RED}Invalid option. Using default (every 10 minutes).${NC}"
        new_schedule="*/10 * * * *"
        ;;
    esac

    # Update crontab with new schedule
    sudo crontab -l 2>/dev/null | grep -v "$MONITORING_SCRIPT" | sudo crontab -

    {
        sudo crontab -l 2>/dev/null
        echo "$new_schedule $MONITORING_SCRIPT"
    } | sudo crontab -

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Cron schedule updated successfully${NC}"
        echo -e "${GREEN}✓ New schedule: $new_schedule${NC}"
    else
        echo -e "${RED}✗ Failed to update crontab${NC}"
        return 1
    fi

    return 0
}

# Main menu
while true; do
    echo -e "\n${BLUE}=== Monitoring Crontab Manager ===${NC}"
    echo "1. Check if monitoring script is in crontab"
    echo "2. Add monitoring script to crontab (run every 10 minutes)"
    echo "3. Remove monitoring script from crontab"
    echo "4. Modify monitoring schedule"
    echo "5. Exit"

    read -p "Select an option [1-5]: " option

    case $option in
    1) check_crontab ;;
    2) add_to_crontab ;;
    3) remove_from_crontab ;;
    4) modify_schedule ;;
    5)
        echo -e "${GREEN}Exiting Crontab Manager${NC}"
        exit 0
        ;;
    *)
        echo -e "${RED}Invalid option. Please try again.${NC}"
        ;;
    esac

    echo ""
    read -p "Press Enter to continue..."
done
