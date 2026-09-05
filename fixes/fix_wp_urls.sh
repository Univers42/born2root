#!/bin/bash
# Run on your Debian guest VM

# Get host port from user
read -p "Enter the port number WordPress should be accessible at on the host (e.g. 8080): " HOST_PORT

# Get host IP (optional)
read -p "Enter host machine IP address (leave blank for auto-detect): " HOST_IP

# Auto-detect host IP if not provided
if [ -z "$HOST_IP" ]; then
    HOST_IP=$(ip route | grep default | awk '{print $3}')
    echo "Using detected host IP: $HOST_IP"
fi

# Construct URL
WP_URL="http://${HOST_IP}:${HOST_PORT}"
echo "Setting WordPress URLs to: $WP_URL"

# Update WordPress database
sudo mysql -e "UPDATE wordpress.wp_options SET option_value = '${WP_URL}' WHERE option_name = 'siteurl' OR option_name = 'home';"

# Check if update was successful
sudo mysql -e "SELECT option_name, option_value FROM wordpress.wp_options WHERE option_name IN ('siteurl', 'home');"

echo "WordPress URLs have been updated. Try accessing from your host at $WP_URL"
