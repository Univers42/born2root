#!/bin/bash

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=== COMPREHENSIVE WEB SERVER CHECK ==="

# Method 1: Check processes
echo -e "${YELLOW}Method 1: Process detection${NC}"
if ps aux | grep -v grep | grep -q "lighttpd"; then
    echo -e "${GREEN}✓ Lighttpd process is running${NC}"
    ps aux | grep -v grep | grep "lighttpd" | sed 's/^/  /'
else
    echo -e "${RED}✗ No Lighttpd process found${NC}"
fi

# Method 2: Check port 80
echo -e "\n${YELLOW}Method 2: Port 80 listener${NC}"
if sudo ss -tulpn | grep -q ":80"; then
    echo -e "${GREEN}✓ Something is listening on port 80${NC}"
    sudo ss -tulpn | grep ":80" | sed 's/^/  /'
else
    echo -e "${RED}✗ Nothing listening on port 80${NC}"
fi

# Method 3: Check service status directly
echo -e "\n${YELLOW}Method 3: Service status${NC}"
if sudo systemctl status lighttpd >/dev/null 2>&1; then
    status=$(sudo systemctl is-active lighttpd)
    echo -e "${GREEN}✓ Lighttpd service status: $status${NC}"
    echo -e "  $(sudo systemctl status lighttpd | grep "Active:" | sed 's/^ *//')"
else
    echo -e "${RED}✗ Lighttpd service not found${NC}"
fi

# Method 4: Check web server directories
echo -e "\n${YELLOW}Method 4: Configuration files${NC}"
if [ -d "/etc/lighttpd" ]; then
    echo -e "${GREEN}✓ Lighttpd configuration directory exists${NC}"
else
    echo -e "${RED}✗ Lighttpd configuration directory not found${NC}"
fi

# Method 5: Check WordPress access
echo -e "\n${YELLOW}Method 5: WordPress detection${NC}"
if [ -f "/var/www/html/wp-config.php" ]; then
    echo -e "${GREEN}✓ WordPress installation found${NC}"
else
    echo -e "${RED}✗ WordPress installation not found at /var/www/html${NC}"
fi

echo -e "\n=== TEST WITH CURL ==="
echo -e "Attempting to connect to localhost:"
if command -v curl >/dev/null; then
    curl -I http://localhost -m 2 2>/dev/null || echo -e "${RED}Connection failed${NC}"
else
    echo -e "${YELLOW}curl not installed${NC}"
fi

echo -e "\n=== CHECK COMPLETE ==="
