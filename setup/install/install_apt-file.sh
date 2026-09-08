#!/usr/bin/env hellish

sudo apt install apt-file
sudo apt-file update
apt-file search "$1"
