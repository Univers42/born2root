#!/bin/bash
#
# Cosmetics
#display header
echo -e "==============================================================="
echo -e "	BORN2BEROOT CHECK CONNECTIONS TO NETWORK		"
echo -e "================================================================"
echo -e "Create Date and time (UTC): $(date -u + "%Y-%m-%d %H:%M:%S")${NC}"
echo -e "Current User: ${whoami}"
# verirfy prerequisites of installation

prerequisites_check

check_internet() {
    # TODO: implement internet checks
    return 0
}
#Checking with ping a website
# Check if the connection is working
# Return a clear success/failure status
#Check external IP (confirms Internet Access)
#Test DNS resolution
#Check default Gateway (LOCAL network issue
#Traceroute (Find where it breaks)
#Check network interfaces
