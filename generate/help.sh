#!/bin/bash
# Born2beRoot — Makefile help
# Called by: make help
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
BLU='\033[34m'

# ── Box drawing (single-line, rounded corners) ───────────────────────────────
W=60 # inner visible width between │ chars

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

row() {
	local content="$1"
	local stripped
	stripped=$(printf '%b' "$content" | sed 's/\x1b\[[0-9;]*m//g')
	local vlen
	vlen=$(printf '%s' "$stripped" | wc -m)
	local pad=$((W - vlen))
	[ "$pad" -lt 0 ] && pad=0
	printf "  ${CYN}│${RST}"
	printf '%b' "$content"
	printf '%*s' "$pad" ""
	printf "${CYN}│${RST}\n"
}

crow() {
	local content="$1"
	local stripped
	stripped=$(printf '%b' "$content" | sed 's/\x1b\[[0-9;]*m//g')
	local vlen
	vlen=$(printf '%s' "$stripped" | wc -m)
	local total_pad=$((W - vlen))
	local lpad=$((total_pad / 2))
	local rpad=$((total_pad - lpad))
	[ "$lpad" -lt 0 ] && lpad=0
	[ "$rpad" -lt 0 ] && rpad=0
	printf "  ${CYN}│${RST}"
	printf '%*s' "$lpad" ""
	printf '%b' "$content"
	printf '%*s' "$rpad" ""
	printf "${CYN}│${RST}\n"
}

blank() { printf "  ${CYN}│${RST}%${W}s${CYN}│${RST}\n" ""; }

# Helper: command + description
cmd() {
	local name="$1" desc="$2" color="${3:-${BLD}}"
	local padded_name
	padded_name=$(printf "%-18s" "$name")
	row "  ${color}${padded_name}${RST} ${desc}"
}

# ═════════════════════════════════════════════════════════════════════════════
printf "\n"
top
crow "${BLD}${WHT}Born2beRoot  ─  Makefile Help${RST}"
mid
blank
cmd "make" "Full pipeline: deps > ISO > VM > start" "${BLD}${GRN}"
cmd "make status" "Show environment status dashboard"
cmd "make deps" "Install VirtualBox + tools"
cmd "make gen_iso" "Download Debian ISO + inject preseed"
cmd "CUSTOM_SHELL_PATH=…" "Optional: override default shell (empty keeps bash)" "${DIM}"
cmd "make setup_vm" "Create the VirtualBox VM"
cmd "make start_vm" "Start the VM (GUI mode)"
cmd "make bstart_vm" "Start headless + unlock encryption"
blank
mid
blank
cmd "make poweroff" "Shut down the VM"
cmd "make list_vms" "List all VirtualBox VMs"
cmd "make rm_disk_image" "Delete the VM completely" "${BLD}${RED}"
cmd "make prune_vms" "Delete ALL VMs" "${BLD}${RED}"
blank
mid
blank
cmd "make clean" "Remove downloaded ISOs"
cmd "make fclean" "Remove ISOs + disk images"
cmd "make re" "Full clean rebuild"
blank
bot
printf "\n"
