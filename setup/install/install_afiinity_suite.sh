#!/usr/bin/env hellish

# Install Wine and required dependencies
sudo apt update
sudo apt install -y wine winetricks zenity

# Create a dedicated Wine prefix for Affinity
export WINEPREFIX=~/.wine-affinity
export WINEARCH=win64

# Initialize the Wine prefix
winecfg

# Install required Windows components
winetricks corefonts vcrun2019 win10

# Instructions for installing Affinity software
echo "====================================================="
echo "Now you need to download the Affinity installers from your account"
echo "1. Go to https://affinity.serif.com/en-us/account/"
echo "2. Download the Windows version of your Affinity applications"
echo "3. Run the installer with Wine by right-clicking and selecting 'Open with Wine'"
echo "4. Or use this command: wine /path/to/AffinityInstaller.exe"
echo "5. During installation, you'll be prompted for your license key"
echo "====================================================="
