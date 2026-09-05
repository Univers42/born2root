#!/bin/bash
# VS Code Remote SSH Configuration Script
# Automatically configures VS Code to work with Born2beRoot VM
# Run this to fix SSH b2b connection issues in VS Code

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m' # No Color

echo -e "${BLUE}${BOLD}================================================${NC}"
echo -e "${BLUE}${BOLD} VS Code Remote SSH Configuration${NC}"
echo -e "${BLUE}${BOLD}================================================${NC}\n"

# 1. Check if VS Code is installed
echo -e "${YELLOW}[1/5] Checking VS Code installation...${NC}"
if ! command -v code &>/dev/null; then
    echo -e "${RED}✗ VS Code not found in PATH${NC}"
    echo "  Please install VS Code first"
    exit 1
fi
VSCODE_VERSION=$(code --version | head -1)
echo -e "${GREEN}✓ VS Code found: $VSCODE_VERSION${NC}\n"

# 2. Verify SSH config exists and has b2b entry
echo -e "${YELLOW}[2/5] Verifying SSH configuration...${NC}"
if [ ! -f ~/.ssh/config ]; then
    echo -e "${RED}✗ SSH config not found at ~/.ssh/config${NC}"
    exit 1
fi

if ! grep -q "Host.*b2b" ~/.ssh/config; then
    echo -e "${RED}✗ No 'b2b' host found in SSH config${NC}"
    exit 1
fi

SSH_HOST=$(grep -A 5 "^Host.*b2b" ~/.ssh/config | head -1)
echo -e "${GREEN}✓ SSH config verified: $SSH_HOST${NC}\n"

# 3. Ensure VS Code extensions directory exists
echo -e "${YELLOW}[3/5] Checking VS Code extensions...${NC}"
VSCODE_EXTENSIONS="${HOME}/.vscode/extensions"
if [ ! -d "$VSCODE_EXTENSIONS" ]; then
    mkdir -p "$VSCODE_EXTENSIONS"
    echo -e "${GREEN}✓ Created extensions directory${NC}"
fi

# Check if Remote SSH extension is installed
if ls "$VSCODE_EXTENSIONS"/ms-vscode-remote.remote-ssh* 1>/dev/null 2>&1; then
    REMOTE_SSH_VERSION=$(ls -d "$VSCODE_EXTENSIONS"/ms-vscode-remote.remote-ssh* | head -1 | xargs basename)
    echo -e "${GREEN}✓ Remote SSH extension found: $REMOTE_SSH_VERSION${NC}\n"
else
    echo -e "${YELLOW}⚠ Remote SSH extension not installed${NC}"
    echo -e "  Installing: Remote - SSH extension...${NC}"
    code --install-extension ms-vscode-remote.remote-ssh --force 2>/dev/null || true
    echo -e "${GREEN}✓ Extension install command sent${NC}\n"
fi

# 4. Create/update VS Code settings.json with SSH fix
echo -e "${YELLOW}[4/5] Configuring VS Code settings for SSH stability...${NC}"
VSCODE_SETTINGS="${HOME}/.config/Code/User/settings.json"

# Create directory if it doesn't exist
mkdir -p "$(dirname "$VSCODE_SETTINGS")"

# Read existing settings or start with empty object
if [ -f "$VSCODE_SETTINGS" ]; then
    SETTINGS=$(cat "$VSCODE_SETTINGS")
else
    SETTINGS='{}'
fi

# Use Python to safely merge JSON settings (handles existing settings gracefully)
python3 <<PYTHON_EOF
import json
import sys

settings_file = "$VSCODE_SETTINGS"
try:
    with open(settings_file, 'r') as f:
        settings = json.load(f)
except:
    settings = {}

# Add/update Remote SSH settings
ssh_settings = {
    "remote.SSH.configFile": "$HOME/.ssh/config",
    "remote.SSH.useLocalServer": False,
    "remote.SSH.enableDynamicForwarding": False,
    "remote.SSH.lockfilesInTmp": True,
    "remote.SSH.useFsMonitor": "auto",
    "remote.SSH.showLoginTerminal": False,
}

# Merge settings
settings.update(ssh_settings)

# Write back
with open(settings_file, 'w') as f:
    json.dump(settings, f, indent=2)

print("✓ VS Code settings updated")
PYTHON_EOF

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ VS Code Remote SSH settings configured${NC}\n"
else
    echo -e "${YELLOW}⚠ Could not auto-configure settings${NC}"
    echo -e "  Manually add these to ~/.config/Code/User/settings.json:${NC}"
    echo -e "  ${BOLD}{${NC}"
    echo -e "    ${BOLD}\"remote.SSH.configFile\": \"${HOME}/.ssh/config\",${NC}"
    echo -e "    ${BOLD}\"remote.SSH.useLocalServer\": false,${NC}"
    echo -e "    ${BOLD}\"remote.SSH.enableDynamicForwarding\": false,${NC}"
    echo -e "    ${BOLD}\"remote.SSH.lockfilesInTmp\": true${NC}"
    echo -e "  ${BOLD}}${NC}\n"
fi

# 5. Clear VS Code cache
echo -e "${YELLOW}[5/5] Clearing VS Code remote server cache...${NC}"
rm -rf ~/.vscode-server ~/.vscode-server-insiders 2>/dev/null || true
echo -e "${GREEN}✓ Cache cleared${NC}\n"

# Final steps
echo -e "${BLUE}${BOLD}================================================${NC}"
echo -e "${GREEN}${BOLD}✓ Configuration Complete!${NC}"
echo -e "${BLUE}${BOLD}================================================${NC}\n"

echo -e "${BOLD}Next steps:${NC}"
echo -e "  1. ${YELLOW}Close VS Code completely${NC}"
echo -e "  2. ${YELLOW}Reopen VS Code${NC}"
echo -e "  3. ${YELLOW}Press Ctrl+Shift+P${NC}"
echo -e "  4. ${YELLOW}Type: Remote-SSH: Connect to Host...${NC}"
echo -e "  5. ${YELLOW}Select: ${BOLD}b2b${NC}\n"

echo -e "${BOLD}Or connect from terminal:${NC}"
echo -e "  ${YELLOW}ssh b2b${NC}\n"

echo -e "${BOLD}Troubleshooting:${NC}"
echo -e "  • If '${BOLD}b2b${NC}' doesn't appear in the host list:"
echo -e "    → Press ${YELLOW}Ctrl+Shift+P${NC} → type ${YELLOW}Remote-SSH: Reload SSH Hosts${NC}"
echo -e "  • If connection still fails:"
echo -e "    → Check: ${YELLOW}ssh -v b2b${NC} from terminal${NC}"
echo -e "  • VS Code logs: ${YELLOW}~/.config/Code/logs/${NC}\n"
