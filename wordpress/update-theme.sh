#!/bin/bash
# WordPress Theme Update Script
# Created: 2025-04-04 23:40:17
# Author: LESdylan

# Text colors for better readability
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}===============================================${NC}"
echo -e "${BLUE}    WordPress Theme Updater    ${NC}"
echo -e "${BLUE}===============================================${NC}"
echo -e "Current Date/Time: 2025-04-04 23:40:17"
echo -e "Current User: LESdylan"
echo ""

# Choose operation mode
echo -e "${YELLOW}Select operation mode:${NC}"
echo -e "1. Deploy theme for the first time"
echo -e "2. Update existing theme with changes"
read -p "Enter your choice (1 or 2): " MODE

if [ "$MODE" != "1" ] && [ "$MODE" != "2" ]; then
    echo -e "${RED}Invalid choice. Please run the script again.${NC}"
    exit 1
fi

# Get user input for source theme path
echo -e "\n${YELLOW}Enter the full path to your theme directory:${NC}"
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

# Different behavior based on mode
if [ "$MODE" == "1" ]; then
    # Deploying for the first time
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

    # Success message
    echo -e "\n${GREEN}Theme deployed successfully!${NC}"
    echo -e "\n${BLUE}Next steps:${NC}"
    echo -e "1. Go to WordPress admin: ${YELLOW}http://localhost/wp-admin${NC}"
    echo -e "2. Navigate to ${YELLOW}Appearance → Themes${NC}"
    echo -e "3. Find ${YELLOW}$THEME_NAME${NC} and click ${YELLOW}Activate${NC}"

else
    # Update mode
    if [ ! -d "$DEST_THEME_DIR" ]; then
        echo -e "${RED}Error: Theme directory not found in WordPress.${NC}"
        echo -e "Please deploy the theme first using mode 1."
        exit 1
    fi

    # Create a backup
    BACKUP_DIR="$THEMES_DIR/${THEME_NAME}_backup_$(date +%Y%m%d_%H%M%S)"
    echo -e "${YELLOW}Creating backup of current theme...${NC}"
    sudo cp -R "$DEST_THEME_DIR" "$BACKUP_DIR"

    # Get list of changed files for reporting
    echo -e "${YELLOW}Finding changed files...${NC}"
    CHANGED_FILES=()

    for file in $(find "$SOURCE_THEME_PATH" -type f -name "*.*"); do
        REL_PATH=${file#$SOURCE_THEME_PATH/}
        DEST_FILE="$DEST_THEME_DIR/$REL_PATH"

        if [ ! -f "$DEST_FILE" ]; then
            CHANGED_FILES+=("New: $REL_PATH")
        elif ! cmp -s "$file" "$DEST_FILE"; then
            CHANGED_FILES+=("Modified: $REL_PATH")
        fi
    done

    # Find deleted files
    for file in $(find "$DEST_THEME_DIR" -type f -name "*.*"); do
        REL_PATH=${file#$DEST_THEME_DIR/}
        SOURCE_FILE="$SOURCE_THEME_PATH/$REL_PATH"

        if [ ! -f "$SOURCE_FILE" ]; then
            CHANGED_FILES+=("Deleted: $REL_PATH")
        fi
    done

    # Replace theme files
    echo -e "${YELLOW}Updating theme files...${NC}"
    sudo rm -rf "$DEST_THEME_DIR"
    sudo mkdir -p "$DEST_THEME_DIR"
    sudo cp -R "$SOURCE_THEME_PATH"/* "$DEST_THEME_DIR"

    # Show the changed files
    echo -e "\n${YELLOW}Changed files:${NC}"
    if [ ${#CHANGED_FILES[@]} -eq 0 ]; then
        echo "No changes detected."
    else
        for file in "${CHANGED_FILES[@]}"; do
            echo "- $file"
        done
    fi

    # Success message
    echo -e "\n${GREEN}Theme updated successfully!${NC}"
    echo -e "Backup created at: ${YELLOW}$BACKUP_DIR${NC}"
    echo -e "${BLUE}Your WordPress theme has been refreshed with the latest changes.${NC}"
    echo -e "You may need to refresh your browser or clear cache to see the changes."
fi

# Set appropriate permissions
echo -e "\n${YELLOW}Setting correct file permissions...${NC}"
sudo chown -R www-data:www-data "$DEST_THEME_DIR"
sudo find "$DEST_THEME_DIR" -type d -exec chmod 755 {} \;
sudo find "$DEST_THEME_DIR" -type f -exec chmod 644 {} \;

# Check if style.css exists (required for WordPress themes)
if [ ! -f "$DEST_THEME_DIR/style.css" ]; then
    echo -e "${RED}Warning: style.css not found in your theme!${NC}"
    echo -e "WordPress requires a style.css file with theme information in the header."
    echo -e "Make sure to create this file before activating the theme."
fi

# Print theme directory for reference
echo -e "\n${YELLOW}Your theme is now installed at:${NC}"
echo -e "${GREEN}$DEST_THEME_DIR${NC}"

echo -e "\n${BLUE}Theme Development Workflow:${NC}"
echo -e "1. Make changes to your theme files in VS Code or your editor"
echo -e "2. Run this script with option 2 to update your WordPress installation"
echo -e "3. View your changes in the browser"
echo -e "4. Repeat steps 1-3 until your theme is perfect!"
