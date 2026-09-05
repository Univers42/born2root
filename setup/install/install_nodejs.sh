#!/bin/bash

set -euo pipefail

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

# nvm is per-user and should not be installed as root
if [[ "${EUID}" -eq 0 ]]; then
    error "Run this script as a normal user (not root/sudo)"
fi

# Check if Node.js toolchain is already installed
if command -v node &>/dev/null && command -v npm &>/dev/null && command -v pnpm &>/dev/null; then
    log "Node.js, npm, and pnpm are already installed"
    exit 0
fi

# Install nvm + Node.js
command -v curl &>/dev/null || error "curl is required"

log "Installing nvm..."
curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash

export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1091
source "$NVM_DIR/nvm.sh"

log "Installing Node.js 22..."
nvm install 22
nvm alias default 22
nvm use 22

# Check if Node.js and NPM were installed successfully
if ! command -v node &>/dev/null || ! command -v npm &>/dev/null; then
    error "Node.js or NPM installation failed"
fi

# Installing PNPM via Corepack
log "Installing PNPM..."
corepack enable
corepack prepare pnpm@latest --activate

# Check if PNPM was installed successfully
if ! command -v pnpm &>/dev/null; then
    error "PNPM installation failed"
fi

# Add information about removal
log "To uninstall Node in the future, run:"
echo "  nvm uninstall 22"
echo "  rm -rf ~/.nvm"

log "Installation completed successfully!"
