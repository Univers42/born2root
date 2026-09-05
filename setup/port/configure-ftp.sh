#!/bin/bash

# Text colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}      FTP Configuration Tool (Fixed)    ${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "Current Date/Time: 2025-04-04 22:30:32"
echo -e "User: LESdylan"
echo ""

# Function to install packages on different distributions
install_package() {
    local package=$1

    echo -e "${YELLOW}Installing $package...${NC}"

    if command -v apt &>/dev/null; then
        # Debian/Ubuntu
        sudo apt update
        sudo apt install -y $package
    elif command -v dnf &>/dev/null; then
        # Fedora
        sudo dnf install -y $package
    elif command -v yum &>/dev/null; then
        # CentOS/RHEL
        sudo yum install -y $package
    elif command -v pacman &>/dev/null; then
        # Arch Linux
        sudo pacman -S --noconfirm $package
    elif command -v zypper &>/dev/null; then
        # openSUSE
        sudo zypper install -y $package
    elif command -v brew &>/dev/null; then
        # macOS with Homebrew
        brew install $package
    else
        echo -e "${RED}Could not determine package manager. Please install $package manually.${NC}"
        return 1
    fi

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ $package installed successfully${NC}"
        return 0
    else
        echo -e "${RED}✗ Failed to install $package${NC}"
        return 1
    fi
}

# Function to check if a package is already installed
is_installed() {
    if command -v $1 &>/dev/null; then
        return 0
    else
        return 1
    fi
}

echo -e "${YELLOW}Checking for FTP clients...${NC}"

# Check for lftp
if is_installed lftp; then
    echo -e "${GREEN}✓ lftp is already installed${NC}"
else
    echo -e "${YELLOW}lftp is not installed. Attempting to install...${NC}"
    install_package lftp

    if ! is_installed lftp; then
        echo -e "${YELLOW}Trying alternative FTP clients...${NC}"

        # Try installing curl with FTP support if lftp fails
        if ! is_installed curl; then
            install_package curl
        fi

        # Try installing basic ftp client if needed
        if ! is_installed ftp; then
            install_package ftp
        fi
    fi
fi

# Check if we have any FTP client available
if ! is_installed lftp && ! is_installed curl && ! is_installed ftp; then
    echo -e "${RED}Failed to install any FTP client. You may need to install manually.${NC}"
    echo -e "${YELLOW}For Debian/Ubuntu:${NC} sudo apt update && sudo apt install lftp"
    echo -e "${YELLOW}For Fedora:${NC} sudo dnf install lftp"
    echo -e "${YELLOW}For CentOS/RHEL:${NC} sudo yum install lftp"
    echo -e "${YELLOW}For macOS:${NC} brew install lftp"

    read -p "Would you like to continue with configuration anyway? (y/n): " CONTINUE
    if [[ "$CONTINUE" != "y" && "$CONTINUE" != "Y" ]]; then
        echo -e "${RED}Exiting. Please install an FTP client and run this script again.${NC}"
        exit 1
    fi
fi

echo ""
echo -e "${YELLOW}Setting up FTP configuration...${NC}"

# Create a directory to store FTP configuration
CONFIG_DIR="$HOME/.ftp-config"
mkdir -p "$CONFIG_DIR"

# Create FTP credentials file
CREDENTIALS_FILE="$CONFIG_DIR/wordpress-credentials.txt"
echo -e "Let's set up your WordPress hosting FTP credentials"
echo -e "${RED}Note: This information will be stored in plain text at: $CREDENTIALS_FILE${NC}"
echo -e "${YELLOW}You can delete this file after using it if you prefer not to store credentials.${NC}"
echo ""

# Getting information about hosting
echo -e "${BLUE}First, let's check what FTP information you have from your hosting provider:${NC}"
echo -e "1. Shared hosting (like Bluehost, HostGator, SiteGround)"
echo -e "2. Managed WordPress hosting (like WP Engine, Kinsta)"
echo -e "3. VPS or dedicated server"
echo -e "4. Local development (XAMPP, Local, etc.)"
read -p "What type of hosting are you using? (1-4): " HOSTING_TYPE

case $HOSTING_TYPE in
1)
    echo -e "${YELLOW}For shared hosting, you typically need to use the FTP credentials provided by your host.${NC}"
    echo -e "Check your hosting account control panel or welcome email for FTP details."
    ;;
2)
    echo -e "${YELLOW}Many managed WordPress hosts use SFTP instead of FTP and may have git workflows.${NC}"
    echo -e "Check your hosting provider's documentation for the recommended file upload method."
    ;;
3)
    echo -e "${YELLOW}For VPS/dedicated servers, you might need to set up FTP yourself or use SFTP/SCP.${NC}"
    echo -e "You can typically use your server's SSH credentials for SFTP access."
    ;;
4)
    echo -e "${YELLOW}For local development, you typically don't need FTP.${NC}"
    echo -e "You can directly access the plugins folder at: wp-content/plugins/"
    echo -e "Simply copy your plugin folder there and activate it in WordPress admin."
    read -p "Do you still want to configure FTP? (y/n): " CONFIGURE_LOCAL
    if [[ "$CONFIGURE_LOCAL" != "y" && "$CONFIGURE_LOCAL" != "Y" ]]; then
        echo -e "${GREEN}For local installations, just copy your 'tech-blog-toolkit' folder to your WordPress plugins directory.${NC}"
        exit 0
    fi
    ;;
*)
    echo -e "${YELLOW}Proceeding with general FTP configuration...${NC}"
    ;;
esac

# Get FTP credentials
read -p "FTP Server (e.g., ftp.yourdomain.com): " FTP_SERVER
read -p "FTP Username: " FTP_USER
read -s -p "FTP Password: " FTP_PASS
echo ""
read -p "FTP Port (default: 21): " FTP_PORT
FTP_PORT=${FTP_PORT:-21}

# Ask about WordPress path
echo -e "\n${BLUE}Now, let's determine your WordPress plugins path:${NC}"
echo -e "1. Standard path (public_html/wp-content/plugins)"
echo -e "2. Custom installation path"
echo -e "3. I don't know (try to auto-detect)"
read -p "Select option (1-3): " WP_PATH_OPTION

case $WP_PATH_OPTION in
1)
    echo -e "${YELLOW}Using standard WordPress path structure...${NC}"
    read -p "Enter your web root folder (default: public_html): " WEB_ROOT
    WEB_ROOT=${WEB_ROOT:-public_html}
    WP_PLUGINS_PATH="/$WEB_ROOT/wp-content/plugins"
    ;;
2)
    echo -e "${YELLOW}Enter custom WordPress plugins path:${NC}"
    read -p "Full path to plugins directory (e.g., /public_html/blog/wp-content/plugins): " WP_PLUGINS_PATH
    ;;
3)
    echo -e "${YELLOW}Will try to auto-detect WordPress path when connecting...${NC}"
    WP_PLUGINS_PATH="auto-detect"
    ;;
*)
    echo -e "${YELLOW}Using default WordPress path...${NC}"
    WP_PLUGINS_PATH="/public_html/wp-content/plugins"
    ;;
esac

# Save to configuration file
cat >"$CREDENTIALS_FILE" <<EOF
# WordPress FTP Configuration
# Created: 2025-04-04
# DO NOT SHARE THIS FILE

FTP_SERVER="$FTP_SERVER"
FTP_USER="$FTP_USER"
FTP_PASS="$FTP_PASS"
FTP_PORT="$FTP_PORT"
WP_PLUGINS_PATH="$WP_PLUGINS_PATH"
EOF

# Set proper permissions
chmod 600 "$CREDENTIALS_FILE"

echo -e "\n${GREEN}FTP configuration saved!${NC}"

# Create a test script to verify connection
TEST_SCRIPT="$CONFIG_DIR/test-connection.sh"
cat >"$TEST_SCRIPT" <<EOF
#!/bin/bash
# Test FTP Connection
# Created: 2025-04-04
# Author: LESdylan

source "$CREDENTIALS_FILE"

echo "Testing connection to \$FTP_SERVER..."

if command -v lftp &> /dev/null; then
    # Use lftp if available
    if [ "\$WP_PLUGINS_PATH" = "auto-detect" ]; then
        echo "Attempting to auto-detect WordPress paths..."
        lftp -u "\$FTP_USER","\$FTP_PASS" -p \$FTP_PORT \$FTP_SERVER << EOF_LFTP
set ssl:verify-certificate no
find -name wp-content
quit
EOF_LFTP
    else
        lftp -u "\$FTP_USER","\$FTP_PASS" -p \$FTP_PORT \$FTP_SERVER << EOF_LFTP
set ssl:verify-certificate no
ls
quit
EOF_LFTP
    fi
elif command -v curl &> /dev/null; then
    # Use curl as fallback
    curl --list-only "ftp://\$FTP_USER:\$FTP_PASS@\$FTP_SERVER:\$FTP_PORT/"
elif command -v ftp &> /dev/null; then
    # Use basic ftp client as last resort
    ftp -n << EOF_FTP
open \$FTP_SERVER \$FTP_PORT
user \$FTP_USER \$FTP_PASS
ls
quit
EOF_FTP
else
    echo "No FTP client available. Please install lftp, curl, or ftp."
    exit 1
fi

if [ \$? -eq 0 ]; then
    echo "Connection successful!"
else
    echo "Connection failed. Please check your credentials."
fi
EOF

chmod +x "$TEST_SCRIPT"

# Create a simplified upload script
UPLOAD_SCRIPT="$CONFIG_DIR/upload-plugin.sh"
cat >"$UPLOAD_SCRIPT" <<EOF
#!/bin/bash
# WordPress Plugin Uploader
# Created: 2025-04-04
# Author: LESdylan

source "$CREDENTIALS_FILE"

# Check for plugin name argument
if [ -z "\$1" ]; then
    echo "Usage: \$0 <plugin-folder-name>"
    echo "Example: \$0 tech-blog-toolkit"
    exit 1
fi

PLUGIN_NAME="\$1"
PLUGIN_PATH="\$(pwd)/\$PLUGIN_NAME"

# Check if plugin directory exists
if [ ! -d "\$PLUGIN_PATH" ]; then
    echo "Error: Plugin directory '\$PLUGIN_NAME' not found in the current directory."
    exit 1
fi

echo "Uploading \$PLUGIN_NAME to WordPress..."

# Auto-detect WordPress path if needed
if [ "\$WP_PLUGINS_PATH" = "auto-detect" ]; then
    echo "Auto-detecting WordPress path..."
    if command -v lftp &> /dev/null; then
        WP_CONTENT_PATH=\$(lftp -u "\$FTP_USER","\$FTP_PASS" -p \$FTP_PORT \$FTP_SERVER -e "find -name wp-content; quit" 2>/dev/null | head -n 1)
        if [ -n "\$WP_CONTENT_PATH" ]; then
            WP_PLUGINS_PATH="\${WP_CONTENT_PATH}/plugins"
            echo "Found WordPress at: \$WP_PLUGINS_PATH"
        else
            echo "Could not auto-detect WordPress. Using default path."
            WP_PLUGINS_PATH="/public_html/wp-content/plugins"
        fi
    else
        echo "Auto-detection requires lftp. Using default path."
        WP_PLUGINS_PATH="/public_html/wp-content/plugins"
    fi
fi

# Determine which FTP client to use
if command -v lftp &> /dev/null; then
    echo "Using lftp to upload..."
    lftp -u "\$FTP_USER","\$FTP_PASS" -p \$FTP_PORT \$FTP_SERVER << EOF_LFTP
set ssl:verify-certificate no
cd "\$WP_PLUGINS_PATH"
mirror -R --verbose "\$PLUGIN_PATH" "\$PLUGIN_NAME"
bye
EOF_LFTP
elif command -v curl &> /dev/null; then
    echo "Using curl to upload..."
    # This is simplified - curl needs more work for recursive uploads
    echo "Warning: Curl upload is not fully implemented for directories."
    echo "Please install lftp for better uploads."
    exit 1
else
    echo "No suitable FTP client found. Please install lftp."
    exit 1
fi

if [ \$? -eq 0 ]; then
    echo "Plugin uploaded successfully!"
    echo "Now activate it in your WordPress admin panel: Plugins → Installed Plugins → find 'Tech Blog Toolkit' → Activate"
else
    echo "Upload failed. Please check your FTP credentials and paths."
fi
EOF

chmod +x "$UPLOAD_SCRIPT"

echo -e "\n${GREEN}Created scripts:${NC}"
echo -e "1. ${YELLOW}Test FTP connection:${NC} $TEST_SCRIPT"
echo -e "2. ${YELLOW}Upload plugin:${NC} $UPLOAD_SCRIPT <plugin-folder-name>"

echo -e "\n${BLUE}Next steps:${NC}"
echo -e "1. Test your FTP connection: $TEST_SCRIPT"
echo -e "2. Upload your plugin: $UPLOAD_SCRIPT tech-blog-toolkit"
echo -e "3. Activate the plugin in WordPress admin panel"

echo -e "\n${GREEN}FTP configuration complete!${NC}"
