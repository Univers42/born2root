#!/bin/bash
# FTP Verification Script
# Created: 2025-04-04
# Author: LESdylan

# Text colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}          FTP Verification Tool         ${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "Current Date/Time: 2025-04-04 22:26:59"
echo -e "User: LESdylan"
echo ""

# Check for common FTP client tools
echo -e "${YELLOW}Checking for FTP client tools...${NC}"
FTP_TOOLS_FOUND=false

# Check for lftp
if command -v lftp &>/dev/null; then
    echo -e "${GREEN}✓ lftp is installed${NC} (Version: $(lftp --version | head -n 1))"
    FTP_TOOLS_FOUND=true
else
    echo -e "${RED}✗ lftp is not installed${NC}"
fi

# Check for ftp command
if command -v ftp &>/dev/null; then
    echo -e "${GREEN}✓ ftp command is available${NC}"
    FTP_TOOLS_FOUND=true
else
    echo -e "${RED}✗ ftp command is not available${NC}"
fi

# Check for curl with FTP support
if command -v curl &>/dev/null && curl -V | grep -q "ftp"; then
    echo -e "${GREEN}✓ curl with FTP support is installed${NC} (Version: $(curl --version | head -n 1))"
    FTP_TOOLS_FOUND=true
else
    echo -e "${RED}✗ curl with FTP support is not available${NC}"
fi

# Check for FileZilla
if command -v filezilla &>/dev/null || [ -d "/Applications/FileZilla.app" ] || [ -f "/c/Program Files/FileZilla FTP Client/filezilla.exe" ]; then
    echo -e "${GREEN}✓ FileZilla appears to be installed${NC}"
    FTP_TOOLS_FOUND=true
else
    echo -e "${RED}✗ FileZilla is not detected${NC}"
fi

echo ""
if [ "$FTP_TOOLS_FOUND" = false ]; then
    echo -e "${RED}No FTP tools were found on your system.${NC}"
    echo -e "Run the configure-ftp.sh script to install necessary FTP tools."
    exit 1
fi

# Ask user if they want to test a connection to their hosting provider
echo -e "${YELLOW}Would you like to test connection to your web hosting provider?${NC} (y/n)"
read -p "> " TEST_CONNECTION

if [ "$TEST_CONNECTION" = "y" ] || [ "$TEST_CONNECTION" = "Y" ]; then
    # Collect hosting provider information
    echo -e "\n${BLUE}Enter your web hosting FTP details:${NC}"
    read -p "FTP Server (e.g., ftp.yourdomain.com): " FTP_SERVER
    read -p "FTP Username: " FTP_USER
    read -s -p "FTP Password: " FTP_PASS
    echo ""
    read -p "FTP Port (default: 21): " FTP_PORT
    FTP_PORT=${FTP_PORT:-21}

    echo -e "\n${YELLOW}Testing connection to $FTP_SERVER...${NC}"

    # Use lftp if available, otherwise fallback to ftp
    if command -v lftp &>/dev/null; then
        RESULT=$(lftp -u "$FTP_USER","$FTP_PASS" -p "$FTP_PORT" "$FTP_SERVER" -e "ls; quit" 2>&1)
        if echo "$RESULT" | grep -q "Access failed\|Login failed\|Unknown host\|Connection refused"; then
            echo -e "${RED}Connection failed: $(echo "$RESULT" | grep -m 1 "Access failed\|Login failed\|Unknown host\|Connection refused")${NC}"
            echo "Please check your credentials and run the configure-ftp.sh script."
            exit 1
        else
            echo -e "${GREEN}Connection successful!${NC}"
            echo -e "You can now upload your WordPress plugin using the upload-plugin.sh script."

            # Try to determine WordPress path
            echo -e "\n${YELLOW}Checking for WordPress installation...${NC}"
            WP_PATH=$(lftp -u "$FTP_USER","$FTP_PASS" -p "$FTP_PORT" "$FTP_SERVER" -e "find -name wp-content; quit" 2>/dev/null)

            if [ -n "$WP_PATH" ]; then
                echo -e "${GREEN}WordPress installation found!${NC}"
                echo -e "Possible WordPress paths:"
                echo "$WP_PATH" | sed 's/^/  - /'

                PLUGINS_PATH="${WP_PATH%/*}/plugins"
                echo -e "\n${BLUE}Your WordPress plugins path is likely:${NC}"
                echo -e "  $PLUGINS_PATH"
                echo -e "\nUse this path when running the upload-plugin.sh script."
            else
                echo -e "${YELLOW}Could not automatically detect WordPress installation.${NC}"
                echo -e "You may need to ask your hosting provider for the correct path."
            fi
        fi
    else
        echo -e "${RED}lftp is not installed. Cannot test connection.${NC}"
        echo "Please run the configure-ftp.sh script to install FTP tools."
        exit 1
    fi
else
    echo -e "\n${YELLOW}To configure FTP with your hosting provider, run:${NC}"
    echo -e "  ./configure-ftp.sh"
fi

echo -e "\n${BLUE}Verification complete.${NC}"
