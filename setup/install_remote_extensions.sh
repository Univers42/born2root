#!/usr/bin/env hellish
# Force install all VS Code Remote extensions

echo "Installing VS Code Remote Extensions..."

# Remove any broken installations
rm -rf ~/.vscode/extensions/ms-vscode-remote.remote-ssh* 2>/dev/null
rm -rf ~/.vscode-server 2>/dev/null

# Install extensions one by one
echo "1. Installing Remote - SSH..."
code --install-extension ms-vscode-remote.remote-ssh --no-verify-signatures 2>&1 | tail -3

echo "2. Installing Remote - Containers..."
code --install-extension ms-vscode-remote.remote-containers --no-verify-signatures 2>&1 | tail -3

echo "3. Installing Remote - WSL..."
code --install-extension ms-vscode-remote.remote-wsl --no-verify-signatures 2>&1 | tail -3

echo "4. Installing Remote Explorer..."
code --install-extension ms-vscode.remote-explorer --no-verify-signatures 2>&1 | tail -3

echo ""
echo "Installed extensions:"
find ~/.vscode/extensions -maxdepth 1 -name "ms-vscode-remote.*" -printf "%f\n" 2>/dev/null

echo ""
echo "✓ Done! Please restart VS Code completely (close all windows)."
echo "  Then open VS Code and check the Remote Explorer on the left sidebar."
