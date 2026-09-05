#!/bin/bash

# Install Flatpak if not already installed
sudo apt install flatpak

# Add Flathub repository
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# Install Obsidian
flatpak install flathub md.obsidian.Obsidian

# Run Obsidian
flatpak run md.obsidian.Obsidian

# Remove the problematic symlink
sudo rm /usr/local/bin/obsidian

# Create a new script that uses flatpak run
sudo tee /usr/local/bin/obsidian >/dev/null <<'EOF'
#!/bin/bash
flatpak run md.obsidian.Obsidian "$@"
EOF

# Make it executable
sudo chmod +x /usr/local/bin/obsidian
