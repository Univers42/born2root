#!/bin/bash
# WordPress Plugin Manager
# Created: 2025-04-05
# Author: LESdylan

# Text colors for better readability
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Get current date and user
CURRENT_DATE=$(date +"%Y-%m-%d %H:%M:%S")
CURRENT_USER=$(whoami)

echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}    WordPress Plugin Manager    ${NC}"
echo -e "${BLUE}================================================${NC}"
echo -e "Date: $CURRENT_DATE"
echo -e "User: $CURRENT_USER"
echo ""

echo -e "${YELLOW}This script will help you manage plugins in your WordPress installation.${NC}"
echo ""

# Function to check if a directory exists and contains WordPress
is_wordpress_dir() {
    if [ -d "$1/wp-content" ] && [ -d "$1/wp-includes" ] && [ -f "$1/wp-config.php" ]; then
        return 0
    else
        return 1
    fi
}

# Locate WordPress installation
echo -e "${BLUE}Step 1: Locating your WordPress installation${NC}"
echo -e "Searching for WordPress on your system..."
echo ""

# Common local WordPress installation locations
POSSIBLE_LOCATIONS=(
    "/var/www/html"
    "/opt/lampp/htdocs"
    "/xampp/htdocs"
    "$HOME/Sites"
    "$HOME/public_html"
    "/srv/www"
    "/usr/local/var/www"
    "$HOME/Local Sites"
)

WORDPRESS_FOUND=false
WORDPRESS_PATH=""

# Check each possible location
echo -e "Checking common WordPress locations..."
for location in "${POSSIBLE_LOCATIONS[@]}"; do
    if [ -d "$location" ]; then
        echo -e "  Checking $location..."

        # If directory has WordPress directly
        if is_wordpress_dir "$location"; then
            WORDPRESS_PATH="$location"
            WORDPRESS_FOUND=true
            echo -e "  ${GREEN}✓ WordPress found at: $location${NC}"
            break
        fi

        # Check if WordPress is in a subdirectory
        for subdir in "$location"/*; do
            if [ -d "$subdir" ] && is_wordpress_dir "$subdir"; then
                WORDPRESS_PATH="$subdir"
                WORDPRESS_FOUND=true
                echo -e "  ${GREEN}✓ WordPress found at: $subdir${NC}"
                break 2
            fi
        done
    fi
done

# If WordPress not found automatically, ask user
if [ "$WORDPRESS_FOUND" = false ]; then
    echo -e "${YELLOW}WordPress installation not found automatically.${NC}"
    echo -e "Please enter the full path to your WordPress installation:"
    echo -e "(This is the folder that contains wp-content, wp-includes, etc.)"
    read -p "> " CUSTOM_PATH

    if [ -d "$CUSTOM_PATH" ] && is_wordpress_dir "$CUSTOM_PATH"; then
        WORDPRESS_PATH="$CUSTOM_PATH"
        WORDPRESS_FOUND=true
        echo -e "${GREEN}✓ WordPress verified at: $WORDPRESS_PATH${NC}"
    else
        echo -e "${RED}Error: This directory doesn't appear to contain WordPress.${NC}"
        echo -e "Please check your server configuration and try again."
        exit 1
    fi
fi

# Set plugins directory
PLUGINS_DIR="$WORDPRESS_PATH/wp-content/plugins"

if [ ! -d "$PLUGINS_DIR" ]; then
    echo -e "${RED}Error: WordPress plugins directory not found at $PLUGINS_DIR${NC}"
    exit 1
fi

# List all plugins
echo ""
echo -e "${BLUE}Step 2: Listing installed plugins${NC}"
echo ""

# Get all plugin directories
PLUGINS=()
PLUGIN_NAMES=()
PLUGIN_VERSIONS=()
PLUGIN_STATUSES=()

# Check for activated plugins
ACTIVE_PLUGINS=()
if [ -f "$WORDPRESS_PATH/wp-config.php" ]; then
    # Try to get the table prefix from wp-config.php
    DB_PREFIX=$(grep "table_prefix" "$WORDPRESS_PATH/wp-config.php" | cut -d "'" -f 2 | cut -d '"' -f 2)
    if [ -z "$DB_PREFIX" ]; then
        DB_PREFIX="wp_"
    fi

    # Get the active plugins option from wp_options table if we can
    # This is a best-effort approach - it won't work without direct DB access
    # For simplicity, we'll just mark all plugins as "Unknown" status
    echo -e "${YELLOW}Note: Plugin activation status cannot be determined without database access.${NC}"
    echo -e "${YELLOW}      All plugins will be shown regardless of status.${NC}"
    echo ""
fi

index=0
for plugin_dir in "$PLUGINS_DIR"/*; do
    if [ -d "$plugin_dir" ]; then
        plugin_name=$(basename "$plugin_dir")

        # Skip default WordPress plugins if user wants
        if [[ "$plugin_name" == "akismet" || "$plugin_name" == "hello.php" ]]; then
            continue
        fi

        PLUGINS[$index]="$plugin_dir"
        PLUGIN_NAMES[$index]="$plugin_name"

        # Try to get plugin version from main plugin file
        version="Unknown"
        for php_file in "$plugin_dir"/*.php; do
            if [ -f "$php_file" ]; then
                # Check if this is the main plugin file by looking for "Plugin Name:" header
                if grep -q "Plugin Name:" "$php_file"; then
                    # Extract version from "Version:" line
                    v=$(grep "Version:" "$php_file" | head -1 | cut -d ":" -f 2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                    if [ ! -z "$v" ]; then
                        version="$v"
                        break
                    fi
                fi
            fi
        done
        PLUGIN_VERSIONS[$index]="$version"

        # Set status (since we can't easily check active status without DB access)
        PLUGIN_STATUSES[$index]="Unknown"

        ((index++))
    fi
done

# Display plugins
if [ ${#PLUGINS[@]} -eq 0 ]; then
    echo -e "${YELLOW}No plugins found in $PLUGINS_DIR${NC}"
    exit 0
fi

echo -e "Found ${#PLUGINS[@]} plugins installed in WordPress:"
echo ""
echo -e "ID | ${BLUE}Plugin Name${NC} | ${GREEN}Version${NC} | Status"
echo -e "---------------------------------------------------"
for i in "${!PLUGINS[@]}"; do
    echo -e "$i | ${BLUE}${PLUGIN_NAMES[$i]}${NC} | ${GREEN}${PLUGIN_VERSIONS[$i]}${NC} | ${PLUGIN_STATUSES[$i]}"
done

# Let user select plugins to delete
echo ""
echo -e "${BLUE}Step 3: Select plugins to delete${NC}"
echo -e "${YELLOW}Enter the IDs of plugins you want to delete (separated by spaces).${NC}"
echo -e "${YELLOW}For example: 0 3 5${NC}"
echo -e "${RED}WARNING: This action cannot be undone!${NC}"
echo -e "Enter 'all' to delete all plugins or 'q' to quit."
read -p "> " SELECTION

if [[ "$SELECTION" == "q" || "$SELECTION" == "Q" ]]; then
    echo -e "${YELLOW}Operation cancelled. No changes were made.${NC}"
    exit 0
fi

SELECTED_PLUGINS=()

if [[ "$SELECTION" == "all" ]]; then
    for i in "${!PLUGINS[@]}"; do
        SELECTED_PLUGINS+=($i)
    done
else
    for id in $SELECTION; do
        if [[ "$id" =~ ^[0-9]+$ && $id -lt ${#PLUGINS[@]} ]]; then
            SELECTED_PLUGINS+=($id)
        else
            echo -e "${RED}Invalid selection: $id. Skipping.${NC}"
        fi
    done
fi

if [ ${#SELECTED_PLUGINS[@]} -eq 0 ]; then
    echo -e "${YELLOW}No valid plugins selected. Exiting.${NC}"
    exit 0
fi

# Confirm deletion
echo ""
echo -e "${RED}You are about to delete the following plugins:${NC}"
for id in "${SELECTED_PLUGINS[@]}"; do
    echo -e "- ${YELLOW}${PLUGIN_NAMES[$id]}${NC} (${GREEN}${PLUGIN_VERSIONS[$id]}${NC})"
done
echo ""
echo -e "${RED}Are you sure you want to delete these plugins? This cannot be undone!${NC}"
read -p "Type 'yes' to confirm: " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
    echo -e "${YELLOW}Deletion cancelled. No changes were made.${NC}"
    exit 0
fi

# Delete selected plugins
echo ""
echo -e "${BLUE}Step 4: Deleting selected plugins...${NC}"
echo ""

SUCCESS=0
FAILURE=0

for id in "${SELECTED_PLUGINS[@]}"; do
    plugin_dir="${PLUGINS[$id]}"
    plugin_name="${PLUGIN_NAMES[$id]}"

    echo -e "Deleting ${YELLOW}$plugin_name${NC}..."

    # Try to delete
    if rm -rf "$plugin_dir"; then
        echo -e "  ${GREEN}✓ Successfully deleted $plugin_name${NC}"
        ((SUCCESS++))
    else
        echo -e "  ${RED}✗ Failed to delete $plugin_name. Permission issue?${NC}"
        echo -e "  Try running the script with sudo privileges."
        ((FAILURE++))
    fi
done

# Summary
echo ""
echo -e "${BLUE}Deletion Summary:${NC}"
echo -e "${GREEN}Successfully deleted: $SUCCESS plugins${NC}"
if [ $FAILURE -gt 0 ]; then
    echo -e "${RED}Failed to delete: $FAILURE plugins${NC}"
    echo -e "You may need to run this script with elevated privileges (sudo) to delete some plugins."
fi

echo ""
echo -e "${GREEN}Operation completed!${NC}"
