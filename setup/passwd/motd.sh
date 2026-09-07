#!/usr/bin/env hellish

# ANSI Color codes
BLUE="\033[0;34m"
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
RESET="\033[0m"
BOLD="\033[1m"

echo -e "${BLUE}${BOLD}╔════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BLUE}${BOLD}║                BORN2BEROOT SECURE SYSTEM                   ║${RESET}"
echo -e "${BLUE}${BOLD}╚════════════════════════════════════════════════════════════╝${RESET}"

# System Information Section
echo -e "${YELLOW}${BOLD}SYSTEM INFORMATION:${RESET}"
echo -e "• ${BOLD}Hostname:${RESET}      $(hostname)"
echo -e "• ${BOLD}OS:${RESET}            Debian GNU/Linux 12 (bookworm)"
echo -e "• ${BOLD}Kernel:${RESET}        $(uname -r)"
echo -e "• ${BOLD}Uptime:${RESET}        $(uptime -p)"
echo -e "• ${BOLD}Load Average:${RESET}  $(cat /proc/loadavg | awk '{print $1, $2, $3}')"

# Security Notice Section
echo -e "\n${RED}${BOLD}SECURITY NOTICE:${RESET}"
echo -e "• This system is monitored and all actions are logged"
echo -e "• Password policy requires minimum 10 characters with complexity"
echo -e "• Passwords expire every 30 days as per security policy"
echo -e "• SSH access is restricted to port 4242 with key authentication"
echo -e "• Firewall is enabled and restricting traffic"

# Resource Usage Section
echo -e "\n${GREEN}${BOLD}CURRENT RESOURCE USAGE:${RESET}"
echo -e "• ${BOLD}CPU Usage:${RESET}     $(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}')%"
echo -e "• ${BOLD}Memory Usage:${RESET}  $(free -m | awk 'NR==2{printf "%.2f%%", $3*100/$2}')"
echo -e "• ${BOLD}Disk Usage:${RESET}    $(df -h / | awk 'NR==2{print $5}')"

# System Services Section
echo -e "\n${BLUE}${BOLD}ACTIVE SERVICES:${RESET}"
echo -e "• SSH (Port 4242)"
echo -e "• Web Server (Port 80)"
echo -e "• MariaDB Database"
echo -e "• UFW Firewall"
echo -e "• AppArmor Security"
echo -e "• System Monitoring (10-minute intervals)"

# Compliance Section
echo -e "\n${YELLOW}${BOLD}BORN2BEROOT COMPLIANCE:${RESET}"
echo -e "• LVM Partitioning: ✓"
echo -e "• AppArmor Enabled: ✓"
echo -e "• SSH Configuration: ✓"
echo -e "• UFW Firewall Rules: ✓"
echo -e "• Password Policy: ✓"
echo -e "• User Group Management: ✓"

# Final Information
last_boot=$(who -b | awk '{print $3, $4}')
failed_logins=$(grep -c "Failed password" /var/log/auth.log)

echo -e "\n${BOLD}Last Boot:${RESET} $last_boot"
echo -e "${BOLD}Failed Login Attempts:${RESET} $failed_logins"
echo -e "${BOLD}Monitoring Script:${RESET} Running every 10 minutes\n"

echo -e "${BLUE}${BOLD}╔════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BLUE}${BOLD}║         UNAUTHORIZED ACCESS IS STRICTLY PROHIBITED         ║${RESET}"
echo -e "${BLUE}${BOLD}╚════════════════════════════════════════════════════════════╝${RESET}"
