#!/bin/bash
# Show the VM's serial console — the only view of a headless VM.
#
# `make all` never opens a VirtualBox window: the installer runs headless and
# the first boot off disk is unlocked by typing into the virtual keyboard from
# the host. That leaves no screen to look at, so COM1 is wired to a file
# (setup/install/vms/install_vm_debian.sh) and both the installer
# (generate/create_custom_iso.sh) and the installed system (preseeds/b2b-setup.sh)
# are booted with console=ttyS0. This script is the reader for that file.
#
#   generate/serial_console.sh <vm> follow   tail -f it (default)
#   generate/serial_console.sh <vm> dump     print it and exit

set -u

VM_NAME="${1:-debian}"
MODE="${2:-follow}"

RST='\033[0m'
YLW='\033[33m'
RED='\033[31m'
DIM='\033[2m'
CYN='\033[36m'

# Ask VirtualBox where the serial file is rather than reconstructing the path:
# the VM's own config is the only thing that is always right.
serial_path=$(VBoxManage showvminfo "$VM_NAME" --machinereadable 2>/dev/null |
    awk -F'"' '/^uartmode1=/ {print $2}' |
    awk -F, '$1 == "file" { sub(/^file,/, "", $0); print }')

if [ -z "$serial_path" ]; then
    printf "${RED}✗${RST} VM \"%s\" has no serial console attached.\n" "$VM_NAME"
    printf "${DIM}  A VM created before this was added has no COM1 file. Attach one with:\n"
    printf "    VBoxManage modifyvm %s --uart1 0x3F8 4 --uartmode1 file <path>\n" "$VM_NAME"
    printf "  (the VM must be powered off), or rebuild it with: make fclean all${RST}\n"
    exit 1
fi

if [ ! -f "$serial_path" ]; then
    printf "${YLW}⚠${RST}  Serial log not created yet: %s\n" "$serial_path"
    printf "${DIM}  VirtualBox creates it when the VM starts. Try: make all${RST}\n"
    exit 1
fi

# The guest sends CR line endings and ANSI positioning; strip both so the log
# reads as plain text in a normal terminal.
clean() {
    # The guest ends lines with CRLF, so turning every CR into a newline
    # double-spaces the entire log. Drop the CR that belongs to a CRLF pair
    # first, then treat any remaining bare CR — progress redraws — as a newline.
    sed -e 's/\r$//' |
        tr '\r' '\n' |
        sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' -e 's/\x1b[()][B0]//g'
}

case "$MODE" in
dump)
    clean <"$serial_path"
    ;;
*)
    printf "${CYN}▶${RST} %s serial console — ${DIM}%s${RST}\n" "$VM_NAME" "$serial_path"
    printf "${DIM}  Ctrl+C stops watching; it does not stop the VM.${RST}\n\n"
    tail -n 200 -f "$serial_path" | clean
    ;;
esac
