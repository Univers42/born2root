#!/bin/bash
# Born2beRoot — Makefile help
# Called by: make help (the default goal — plain `make` lands here)
set -e

# ── Colours ──────────────────────────────────────────────────────────────────
RST='\033[0m'
BLD='\033[1m'
DIM='\033[2m'
GRN='\033[32m'
YLW='\033[33m'
RED='\033[31m'
CYN='\033[36m'
WHT='\033[97m'

# ── Box drawing (single-line, rounded corners) ───────────────────────────────
# Adaptive width: the descriptions here are full sentences, and at a hard 60
# columns several of them used to run straight through the right border.
W=$(($(tput cols 2>/dev/null || echo 100) - 6))
[ "$W" -lt 64 ] && W=64
[ "$W" -gt 78 ] && W=78

top() {
    printf "  ${CYN}╭"
    printf '─%.0s' $(seq 1 $W)
    printf "╮${RST}\n"
}
mid() {
    printf "  ${CYN}├"
    printf '─%.0s' $(seq 1 $W)
    printf "┤${RST}\n"
}
bot() {
    printf "  ${CYN}╰"
    printf '─%.0s' $(seq 1 $W)
    printf "╯${RST}\n"
}

# Visible length, ignoring colour escapes. Everything drawn here is width-1,
# so counting characters is the right measure.
_vlen() {
    printf '%b' "$1" | sed 's/\x1b\[[0-9;]*m//g' | wc -m
}

row() {
    local content="$1" pad
    pad=$((W - $(_vlen "$content")))
    [ "$pad" -lt 0 ] && pad=0
    printf "  ${CYN}│${RST}"
    printf '%b' "$content"
    printf '%*s' "$pad" ""
    printf "${CYN}│${RST}\n"
}

crow() {
    local content="$1" total lpad rpad
    total=$((W - $(_vlen "$content")))
    [ "$total" -lt 0 ] && total=0
    lpad=$((total / 2))
    rpad=$((total - lpad))
    printf "  ${CYN}│${RST}"
    printf '%*s' "$lpad" ""
    printf '%b' "$content"
    printf '%*s' "$rpad" ""
    printf "${CYN}│${RST}\n"
}

blank() { printf "  ${CYN}│${RST}%${W}s${CYN}│${RST}\n" ""; }

# Pad to a visible width. bash's printf '%-18s' pads by BYTES, so a name
# holding a multibyte character (VM_NAME=…) came out three columns short and
# the description column went ragged.
NAMEW=18
_pad() {
    local s="$1" n
    n=$(printf '%s' "$s" | wc -m)
    printf '%s' "$s"
    [ "$n" -lt "$NAMEW" ] && printf '%*s' $((NAMEW - n)) ""
    return 0
}

# Section heading. Closes the previous section with a blank line first, so the
# last command of a group never sits flush against the divider.
sec() {
    blank
    mid
    blank
    row "  ${BLD}${WHT}▸ $1${RST}"
    blank
}

# One command + what it does. The description gets whatever the name column
# leaves, and is trimmed rather than allowed to break the border.
cmd() {
    local name="$1" desc="$2" color="${3:-${BLD}}"
    local avail=$((W - 2 - NAMEW - 1))
    [ "$(printf '%s' "$desc" | wc -m)" -gt "$avail" ] && desc="${desc:0:$((avail - 1))}…"
    row "  ${color}$(_pad "$name")${RST} ${desc}"
}

# An indented continuation line under a command.
note() { row "  $(_pad '')  ${DIM}$1${RST}"; }

# ═════════════════════════════════════════════════════════════════════════════
printf "\n"
top
crow "${BLD}${WHT}Born2beRoot  ─  Makefile Help${RST}"
mid
blank
row "  A headless Debian VM: preseeded install, LUKS-encrypted LVM,"
row "  unlocked and driven entirely from this terminal."
row "  ${DIM}No VirtualBox window is ever opened.${RST}"

sec "Build it"
cmd "make all" "Build everything from zero (~20 min)" "${BLD}${GRN}"
note "deps → ISO → VM → install → boot → unlock"
note "picks VirtualBox or QEMU/KVM automatically; asks only if both work"
cmd "make re" "Destroy the VM and build it again" "${BLD}${YLW}"
cmd "make backend" "Which hypervisor would be used here, and why"
cmd "make check_driver" "Can this machine run a VM at all?"

sec "Hypervisor backend (the guest is identical either way)"
cmd "make all BACKEND=qemu" "Force QEMU/KVM — no kernel module, no root"
cmd "make all BACKEND=virtualbox" "Force VirtualBox — needs vboxdrv (root)"
cmd "make qemu_start" "Boot the QEMU VM and unlock its disk"
cmd "make qemu_stop" "Shut the QEMU VM down"
cmd "make qemu_status" "QEMU pid, ports, disk, last console line"
cmd "make qemu_console" "Follow the QEMU VM's serial console"
cmd "make qemu_watch" "Re-attach the install progress tracker"
cmd "make verify_guest" "Prove the guest matches the spec (partitions, LUKS…)"

sec "Use it"
cmd "ssh b2b" "Log in (shortcut added to ~/.ssh/config)" "${BLD}${GRN}"
cmd "make start_vm" "Boot headless and unlock the LUKS disk"
cmd "make poweroff" "Shut the VM down"
cmd "make status" "Where everything stands right now"

sec "See what the headless VM is doing"
cmd "make console" "Follow the VM's serial console live"
note "Ctrl+C stops watching, not the VM"
cmd "make serial_log" "Print the serial console log and exit"
cmd "make gui_vm" "Escape hatch: open the VirtualBox window"

sec "Inception (the project that runs inside the VM)"
cmd "make inception" "Clone it into the VM, build it, verify" "${BLD}${GRN}"
note "SRC=<dir> uploads a local copy instead"
cmd "make host_access" "Let this host reach the .42.fr domain"
cmd "make verify_access" "Prove the domain works from the host"
cmd "make host_access_undo" "Undo the host-side browser wiring"
note "Chromium gets the bare URL; Firefox adds :8443"

sec "Editor + shell inside the VM"
cmd "make provision" "Neovim + kickstart + extras + hellishrc" "${BLD}${GRN}"
note "Already done at first boot; this re-runs it"
cmd "make nvim" "Neovim (latest upstream) + all plugins"
note "Debian ships 0.10; kickstart needs 0.12"
cmd "make hellish_plugins" "The hellishrc plugin framework"
cmd "make shell_vm" "Reinstall hellish from upstream (binary + plugins)"
cmd "make nvim_health" "Print :checkhealth from inside the VM"
cmd "make devtools" "Herdr (persistent panes) + Claude Code"
cmd "make ai AI_MODE=local" "Ollama + a model sized to the VM's RAM"
note "AI_MODE=off by default; nothing is downloaded"
cmd "make global_scope" "Put npm globals + AI models on /opt"

sec "Rebuild one piece"
cmd "make deps" "Install VirtualBox + host tools"
cmd "make gen_iso" "Download Debian ISO + inject the preseed"
cmd "make setup_vm" "Create the VirtualBox VM"
cmd "make shell" "Download the latest hellish release"
cmd "make fix_app_ports" "Repair the VM's NAT port forwards"
cmd "make extpack" "VirtualBox Extension Pack (optional)"
note "not used here; needs your host sudo password"

sec "When something is wrong"
cmd "make check_system" "Pre-flight: vboxdrv, kernel, VS Code"
cmd "make fix_hwe" "Rebuild VirtualBox against your kernel"
note "for: /dev/vboxdrv missing, DKMS failures"
cmd "make console" "Read the VM's console — usually says why"

sec "Tear down"
cmd "make clean" "Remove downloaded ISOs"
cmd "make fclean" "Remove ISOs + disk images + the VM"
cmd "make list_vms" "List all VirtualBox VMs"
cmd "make rm_disk_image" "Delete this VM completely" "${BLD}${RED}"
cmd "make prune_vms" "Delete EVERY VM on this host" "${BLD}${RED}"

sec "Settings (append to any target)"
cmd "VM_NAME=…" "Which VM to act on (default: debian)" "${DIM}"
cmd "VM_PASS=…" "LUKS passphrase (default: vm_pass.txt)" "${DIM}"
cmd "HELLISH_VERSION=…" "Pin a hellish release (default: latest)" "${DIM}"
cmd "CUSTOM_SHELL_PATH=" "Empty = keep bash as the login shell" "${DIM}"
cmd "FORCE_ISO=1" "Rebuild the ISO even if one exists" "${DIM}"
cmd "NVIM_VERSION=…" "Pin Neovim (default: a tested release)" "${DIM}"
cmd "NVIM_USERS=…" "Which VM users get the config" "${DIM}"
cmd "DISK_SIZE_MB=…" "New VM disk in MB (default 122880)" "${DIM}"
cmd "VM_RAM_MB=…" "Override VM RAM (default 25% of host)" "${DIM}"
cmd "AI_MODE=…" "off (default) | client | local" "${DIM}"
blank
row "    ${DIM}e.g.${RST}  ${BLD}make all VM_NAME=test VM_PASS=hunter2${RST}"
blank
bot
printf "\n"
