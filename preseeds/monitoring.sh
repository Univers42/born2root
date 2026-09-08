#!/usr/bin/env hellish
ARCH=$(uname -a)
PCPU=$(grep "physical id" /proc/cpuinfo | sort -u | wc -l)
VCPU=$(grep -c processor /proc/cpuinfo)
RAM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
RAM_USED=$(free -m | awk '/Mem:/ {print $3}')
RAM_PERC=$(free | awk '/Mem:/ {printf("%.2f"), $3/$2*100}')
DISK_TOTAL=$(df -h --total | awk '/total/ {print $2}')
DISK_USED=$(df -h --total | awk '/total/ {print $3}')
DISK_PERC=$(df -k --total | awk '/total/ {print $5}')
CPU_LOAD=$(top -bn1 | grep "Cpu(s)" | sed 's/.*, *\([0-9.]*\)%* id.*/\1/' | awk '{print 100 - $1"%"}')
LAST_BOOT=$(who -b | awk '{print $3, $4}')
LVM_USE=$(lsblk | grep -q lvm && echo yes || echo no)
TCP_CONN=$(ss -t | grep -c ESTAB)
USERS=$(who | wc -l)
IP=$(hostname -I | awk '{print $1}')
MAC=$(ip link show | awk '/ether/ {print $2}')
SUDO_CMDS=$(journalctl _COMM=sudo | grep -c COMMAND)

wall "
#Architecture: $ARCH
#CPU physical: $PCPU
#vCPU: $VCPU
#Memory Usage: ${RAM_USED}/${RAM_TOTAL}MB (${RAM_PERC}%)
#Disk Usage: $DISK_USED/$DISK_TOTAL ($DISK_PERC)
#CPU load: $CPU_LOAD
#Last boot: $LAST_BOOT
#LVM use: $LVM_USE
#Connections TCP: $TCP_CONN ESTABLISHED
#User log: $USERS
#Network: IP $IP ($MAC)
#Sudo: $SUDO_CMDS cmd
"
