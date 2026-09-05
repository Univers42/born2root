#!/bin/bash

set -eo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Log function
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root or with sudo"
fi

# Check if snapd is installed
if ! command -v snap &>/dev/null; then
    log "Installing snapd..."
    apt-get update || error "Failed to update package lists"
    apt-get install -y snapd || error "Failed to install snapd"

    # Ensure snap paths are properly set up
    ln -sf /var/lib/snapd/snap /snap 2>/dev/null || true

    # Restart snapd to ensure it's fully functional
    systemctl enable snapd
    systemctl restart snapd

    log "Waiting for snapd to initialize..."
    sleep 10
else
    log "Snapd is already installed"
fi

# Install Notion via Snap
log "Installing Notion via Snap (this may take a minute)..."
snap install notion-snap || error "Failed to install Notion via Snap"

# Create a more convenient command alias
log "Creating command-line alias..."
cat >/usr/local/bin/notion <<'EOF'
#!/bin/bash

# Check if X server is available
if [[ -z "$DISPLAY" ]]; then
    echo "Error: No display server available. Notion requires a graphical environment."
    echo "If you're connecting remotely, try using SSH with X forwarding: ssh -X user@server"
    exit 1
fi

# Launch Notion
/snap/bin/notion-snap "$@"
EOF

chmod +x /usr/local/bin/notion || error "Failed to make command alias executable"

# Verify installation
if [ -f "/snap/bin/notion-snap" ]; then
    log "Notion has been successfully installed!"
    log "You can run Notion by typing either 'notion-snap' or 'notion' in the terminal."

    # Server-specific notes
    warn "NOTE: Notion is primarily a desktop application and requires a graphical environment."
    warn "If you're running this on a headless server, you'll need X forwarding to use it."
    warn "Connect with: ssh -X user@server and then run the 'notion' command."
else
    error "Installation appears to have failed. Notion executable not found."
fi

# Add information about removal
log "To uninstall Notion in the future, run:"
echo "  sudo snap remove notion-snap"
echo "  sudo rm /usr/local/bin/notion"

log "Installation completed successfully!"
