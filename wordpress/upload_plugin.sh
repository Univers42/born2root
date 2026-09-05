#!/bin/bash
# WordPress Plugin FTP Uploader
# Created: 2025-04-04
# Author: LESdylan

# Text colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Plugin information
PLUGIN_NAME="tech-blog-toolkit"
LOCAL_PLUGIN_PATH="$(pwd)/$PLUGIN_NAME"

# Display header
echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}     WordPress Plugin FTP Uploader     ${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""

# Check if plugin directory exists
if [ ! -d "$LOCAL_PLUGIN_PATH" ]; then
    echo -e "${RED}Error: Plugin directory '$PLUGIN_NAME' not found in the current directory.${NC}"
    echo "Make sure your plugin folder is in the current directory."
    exit 1
fi

# Collect FTP credentials
read -p "FTP Server (e.g., ftp.example.com): " FTP_SERVER
read -p "FTP Username: " FTP_USER
read -s -p "FTP Password: " FTP_PASS
echo ""
read -p "FTP Port (default: 21): " FTP_PORT
FTP_PORT=${FTP_PORT:-21}
read -p "WordPress plugins path (e.g., /public_html/wp-content/plugins): " WP_PLUGINS_PATH

# Check if required utilities are installed
if ! command -v lftp &>/dev/null; then
    echo -e "${RED}Error: 'lftp' command not found. Please install it:${NC}"
    echo "  • Debian/Ubuntu: sudo apt-get install lftp"
    echo "  • CentOS/RHEL: sudo yum install lftp"
    echo "  • macOS: brew install lftp"
    exit 1
fi

echo -e "${YELLOW}\nPreparing to upload plugin...${NC}"

# Create a temporary script for lftp to avoid password in command line
TEMP_SCRIPT=$(mktemp)
cat >$TEMP_SCRIPT <<EOF
open -u "$FTP_USER","$FTP_PASS" -p $FTP_PORT $FTP_SERVER
set ssl:verify-certificate no
set ftp:ssl-allow yes
set ftp:ssl-protect-data yes
lcd "$LOCAL_PLUGIN_PATH"
cd "$WP_PLUGINS_PATH"

# Check if the directory already exists
!if (glob -a "$PLUGIN_NAME" || glob -a "$PLUGIN_NAME/")
  echo "Removing existing plugin directory..."
  rm -rf "$PLUGIN_NAME"
!endif

# Create directory and upload
mkdir -p "$PLUGIN_NAME"
cd "$PLUGIN_NAME"
mirror -R --verbose

# Display completion message
echo "Plugin uploaded successfully!"
bye
EOF

# Execute the upload script
echo -e "${YELLOW}Uploading plugin to server...${NC}"
lftp -f $TEMP_SCRIPT

# Check if the upload was successful
if [ $? -ne 0 ]; then
    echo -e "${RED}\nError: Failed to upload plugin. Please check your FTP credentials and paths.${NC}"
    rm $TEMP_SCRIPT
    exit 1
else
    echo -e "${GREEN}\nPlugin '$PLUGIN_NAME' has been successfully uploaded to your server!${NC}"
    echo -e "${YELLOW}Next steps:${NC}"
    echo "1. Log in to your WordPress admin panel"
    echo "2. Navigate to Plugins → Installed Plugins"
    echo "3. Find 'Tech Blog Toolkit' and click 'Activate'"
fi

# Clean up
rm $TEMP_SCRIPT
echo -e "${GREEN}Temporary files cleaned up.${NC}"
