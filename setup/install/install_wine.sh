#!/usr/bin/env hellish

# Stop any running wine processes
wineserver -k

# Remove existing Wine installations and configurations
sudo apt purge wine wine64 wine32 wine-stable libwine* fonts-wine* -y
rm -rf ~/.wine ~/.wine-affinity
rm -rf ~/.config/wine
rm -f ~/.config/menus/applications-merged/wine*

# Add the WineHQ repository for the latest version
sudo dpkg --add-architecture i386
sudo mkdir -pm755 /etc/apt/keyrings
sudo wget -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key
sudo wget -NP /etc/apt/sources.list.d/ https://dl.winehq.org/wine-builds/ubuntu/dists/jammy/winehq-jammy.sources

# Update and install WineHQ stable
sudo apt update
sudo apt install --install-recommends winehq-stable -y

# Install supporting packages
sudo apt install winetricks zenity -y

# Create a fresh prefix for Affinity
export WINEPREFIX=~/.wine-affinity
export WINEARCH=win64

# Initialize the prefix
winecfg

# Install necessary components
winetricks -q corefonts
winetricks -q vcrun2013 vcrun2015 vcrun2017 vcrun2019
winetricks -q dotnet48
winetricks -q win10

echo "====================================================="
echo "Wine has been completely reinstalled."
echo "Now try installing Affinity with:"
echo "WINEPREFIX=~/.wine-affinity wine ~/Downloads/affinity-designer-msi-2.6.2.exe"
echo "====================================================="
