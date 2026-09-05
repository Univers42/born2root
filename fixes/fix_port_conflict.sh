#!/bin/bash
# Fix for web server/SSH port conflict

echo "=== FIXING PORT CONFLICT ==="

# Check what's actually listening on port 4242
echo "Process listening on port 4242:"
sudo lsof -i :4242

# Stop any web server that might be running on the wrong port
echo "Stopping lighttpd (if running)..."
sudo systemctl stop lighttpd

# Fix SSH configuration
echo "Setting SSH to listen on port 4242..."
sudo sed -i 's/^#*Port .*/Port 4242/' /etc/ssh/sshd_config

# Fix lighttpd configuration (if installed)
if [ -f /etc/lighttpd/lighttpd.conf ]; then
    echo "Setting lighttpd to listen ONLY on port 80..."
    sudo sed -i 's/^server.port.*/server.port = 80/' /etc/lighttpd/lighttpd.conf
fi

# Restart SSH
echo "Restarting SSH service..."
sudo systemctl restart ssh

# Start lighttpd on the correct port (if installed)
if systemctl is-enabled lighttpd &>/dev/null; then
    echo "Starting lighttpd on port 80..."
    sudo systemctl start lighttpd
fi

# Verify port assignments
echo "Current port assignments:"
sudo ss -tulpn | grep -E ':(80|4242)'

echo "=== FIX COMPLETE ==="
echo "Try connecting via SSH now."
