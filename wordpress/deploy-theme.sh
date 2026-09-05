#!/bin/bash
# WordPress Theme Deployment Script
# Created: 2025-04-04 23:33:33
# Author: LESdylan

# Text colors for better readability
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}===============================================${NC}"
echo -e "${BLUE}    Local WordPress Theme Deployer    ${NC}"
echo -e "${BLUE}===============================================${NC}"
echo -e "Date: 2025-04-04 23:33:33"
echo -e "User: LESdylan"
echo ""

# Get user input for source theme path
echo -e "${YELLOW}Enter the full path to your theme directory:${NC}"
echo -e "(This is where your theme files are located in VS)"
read -p "> " SOURCE_THEME_PATH

# Check if source directory exists
if [ ! -d "$SOURCE_THEME_PATH" ]; then
    echo -e "${RED}Error: Source theme directory not found!${NC}"
    exit 1
fi

# Get theme name from directory name
THEME_NAME=$(basename "$SOURCE_THEME_PATH")
echo -e "Theme name detected as: ${GREEN}$THEME_NAME${NC}"

# Get WordPress install path
echo -e "\n${YELLOW}Enter the path to your WordPress installation:${NC}"
echo -e "(Usually /var/www/html or similar)"
read -p "> " WP_PATH

# Default to /var/www/html if empty
if [ -z "$WP_PATH" ]; then
    WP_PATH="/var/www/html"
    echo "Using default path: $WP_PATH"
fi

# Check if WordPress directory exists
if [ ! -d "$WP_PATH" ]; then
    echo -e "${RED}Error: WordPress directory not found!${NC}"
    exit 1
fi

# Verify WordPress installation
if [ ! -f "$WP_PATH/wp-config.php" ] || [ ! -d "$WP_PATH/wp-content" ]; then
    echo -e "${RED}Error: WordPress installation not found at the specified path.${NC}"
    echo -e "Make sure the path contains wp-config.php and wp-content directory."
    exit 1
fi

# Set themes directory
THEMES_DIR="$WP_PATH/wp-content/themes"
DEST_THEME_DIR="$THEMES_DIR/$THEME_NAME"

# Check if destination already exists
if [ -d "$DEST_THEME_DIR" ]; then
    echo -e "${YELLOW}Theme directory already exists at: $DEST_THEME_DIR${NC}"
    read -p "Do you want to replace it? (y/n): " REPLACE

    if [ "$REPLACE" != "y" ] && [ "$REPLACE" != "Y" ]; then
        echo -e "${RED}Deployment cancelled.${NC}"
        exit 1
    fi

    echo -e "Removing existing theme directory..."
    sudo rm -rf "$DEST_THEME_DIR"
fi

# Create destination directory
echo -e "\n${YELLOW}Copying theme files to WordPress...${NC}"
sudo mkdir -p "$DEST_THEME_DIR"

# Copy all theme files to WordPress themes directory
sudo cp -R "$SOURCE_THEME_PATH"/* "$DEST_THEME_DIR"

# Set appropriate permissions
echo -e "Setting correct file permissions..."
sudo chown -R www-data:www-data "$DEST_THEME_DIR"
sudo find "$DEST_THEME_DIR" -type d -exec chmod 755 {} \;
sudo find "$DEST_THEME_DIR" -type f -exec chmod 644 {} \;

# Check if style.css exists (required for WordPress themes)
if [ ! -f "$DEST_THEME_DIR/style.css" ]; then
    echo -e "${RED}Warning: style.css not found in your theme!${NC}"
    echo -e "WordPress requires a style.css file with theme information in the header."
    echo -e "Make sure to create this file before activating the theme."
fi

# Success message
echo -e "\n${GREEN}Theme deployed successfully!${NC}"
echo -e "\n${BLUE}Next steps:${NC}"
echo -e "1. Go to WordPress admin: ${YELLOW}http://localhost/wp-admin${NC}"
echo -e "2. Navigate to ${YELLOW}Appearance → Themes${NC}"
echo -e "3. Find ${YELLOW}$THEME_NAME${NC} and click ${YELLOW}Activate${NC}"
echo -e "\n${BLUE}If your theme doesn't appear:${NC}"
echo -e "- Make sure it has a valid style.css file with proper WordPress theme headers"
echo -e "- Check the WordPress error log for issues"
echo -e "- Verify file permissions (755 for directories, 644 for files)"

# Print theme directory for reference
echo -e "\n${YELLOW}Your theme is now installed at:${NC}"
echo -e "${GREEN}$DEST_THEME_DIR${NC}"
