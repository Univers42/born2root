#!/bin/bash

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
echo -e "${BLUE}    Dynamic WordPress Plugin Installer    ${NC}"
echo -e "${BLUE}================================================${NC}"
echo -e "Date: $CURRENT_DATE"
echo -e "User: $CURRENT_USER"
echo ""

echo -e "${YELLOW}This script will install any WordPress plugin to your local WordPress installation.${NC}"
echo ""

# Function to check if a directory exists and contains WordPress
is_wordpress_dir() {
    if [ -d "$1/wp-content" ] && [ -d "$1/wp-includes" ] && [ -f "$1/wp-config.php" ]; then
        return 0
    else
        return 1
    fi
}

# Function to check if a directory looks like a WordPress plugin
is_plugin_dir() {
    # Check if any PHP file contains Plugin Name: in the directory
    if grep -r "Plugin Name:" "$1"/*.php >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# First, try to locate WordPress installation
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
        echo -e "${RED}This directory doesn't appear to contain WordPress.${NC}"
        echo -e "Please check your server configuration and try again."
        exit 1
    fi
fi

echo ""
echo -e "${BLUE}Step 2: Locate your plugin folder${NC}"
echo -e "Enter the full path to your plugin folder:"
read -p "> " PLUGIN_PATH

if [ ! -d "$PLUGIN_PATH" ]; then
    echo -e "${RED}Error: The specified directory doesn't exist.${NC}"
    exit 1
fi

# Get plugin name from directory name
PLUGIN_NAME=$(basename "$PLUGIN_PATH")
echo -e "Plugin name detected as: ${YELLOW}$PLUGIN_NAME${NC}"

# Verify it's a WordPress plugin (basic check)
if ! is_plugin_dir "$PLUGIN_PATH"; then
    echo -e "${YELLOW}Warning: This doesn't look like a standard WordPress plugin.${NC}"
    echo -e "The folder should contain PHP files with a 'Plugin Name:' header."
    echo -e "Do you want to continue anyway? (y/n)"
    read -p "> " CONTINUE

    if [[ "$CONTINUE" != "y" && "$CONTINUE" != "Y" ]]; then
        echo -e "${YELLOW}Installation cancelled.${NC}"
        exit 0
    fi
fi

echo ""
echo -e "${BLUE}Step 3: Installing the plugin${NC}"

# Destination for the plugin
WP_PLUGINS_DIR="$WORDPRESS_PATH/wp-content/plugins"

if [ ! -d "$WP_PLUGINS_DIR" ]; then
    echo -e "${RED}Error: WordPress plugins directory not found at $WP_PLUGINS_DIR${NC}"
    exit 1
fi

# Check if plugin already exists at destination and remove if necessary
if [ -d "$WP_PLUGINS_DIR/$PLUGIN_NAME" ]; then
    echo -e "${YELLOW}Plugin '$PLUGIN_NAME' already exists in WordPress plugins directory.${NC}"
    read -p "Do you want to replace it? (y/n): " REPLACE

    if [[ "$REPLACE" == "y" || "$REPLACE" == "Y" ]]; then
        echo -e "Removing existing plugin..."
        rm -rf "$WP_PLUGINS_DIR/$PLUGIN_NAME"
    else
        echo -e "${YELLOW}Installation cancelled.${NC}"
        exit 0
    fi
fi

# Copy plugin to WordPress plugins directory
echo -e "Copying plugin to WordPress plugins directory..."
cp -r "$PLUGIN_PATH" "$WP_PLUGINS_DIR/"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Plugin '$PLUGIN_NAME' installed successfully to: $WP_PLUGINS_DIR/$PLUGIN_NAME${NC}"

    # Set proper permissions
    echo -e "Setting proper permissions..."
    chmod -R 755 "$WP_PLUGINS_DIR/$PLUGIN_NAME"

    # Find the URL to access WordPress admin
    SITE_URL=""
    if [ -f "$WORDPRESS_PATH/wp-config.php" ]; then
        # Try to extract site URL from wp-config.php
        SITE_URL=$(grep "WP_HOME\|WP_SITEURL" "$WORDPRESS_PATH/wp-config.php" | grep -o "http[s]*://[^'\"]*" | head -1)
    fi

    echo ""
    echo -e "${BLUE}Next steps:${NC}"
    if [ -n "$SITE_URL" ]; then
        echo -e "1. Access your WordPress admin at: ${GREEN}$SITE_URL/wp-admin${NC}"
    else
        echo -e "1. Access your WordPress admin (usually http://localhost/wp-admin or similar)"
    fi
    echo -e "2. Go to Plugins → Installed Plugins"
    echo -e "3. Find '$PLUGIN_NAME' and click 'Activate'"
    echo -e "4. Start using your plugin!"
else
    echo -e "${RED}Failed to copy plugin to WordPress plugins directory.${NC}"
    echo -e "Please check permissions and try again. You might need to run with sudo:"
    echo -e "sudo $0"
    exit 1
fi

echo ""
echo -e "${GREEN}Installation complete!${NC}"
