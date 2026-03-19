#!/bin/bash
# Born2beRoot — main orchestrator (live TUI dashboard)
# Called by: make all
set -e

VM_NAME="${1:-debian}"
MAKE_CMD="${2:-make}"
LOG_DIR=$(mktemp -d)

# ── Colours ──────────────────────────────────────────────────────────────────
RST='\033[0m'
BLD='\033[1m'
DIM='\033[2m'
GRN='\033[32m'
YLW='\033[33m'
RED='\033[31m'
BLU='\033[34m'
CYN='\033[36m'
WHT='\033[97m'
HIDE_CUR='\033[?25l'
SHOW_CUR='\033[?25h'
CLR='\033[2K'

# Early trap (before functions are defined)
cleanup() {
	local sig="$1"
	stop_spinner 2> /dev/null || true
	printf "${SHOW_CUR}"
	rm -rf "$LOG_DIR"
	if [ "$sig" = "INT" ] || [ "$sig" = "TERM" ]; then
		printf "\n${YLW}${BLD}  ⚠  Interrupted by user${RST}\n\n"
		exit 130
	fi
}
trap 'cleanup EXIT' EXIT
trap 'cleanup INT' INT
trap 'cleanup TERM' TERM

# ── Box drawing (single-line, rounded corners) ───────────────────────────────
W=60 # default inner visible width — recalculated before summary

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
blank() { printf "  ${CYN}│${RST}%${W}s${CYN}│${RST}\n" ""; }

# Print a row: content is padded to exactly W visible chars
# Uses Python for accurate display-width measurement of wide chars (emoji)
_display_width() {
	local text="$1"
	# Strip ANSI escape sequences, then measure display width
	printf '%s' "$text" | python3 -c "
import sys, unicodedata, re
s = re.sub(r'\x1b\[[0-9;]*m', '', sys.stdin.read())
w = 0
for c in s:
    eaw = unicodedata.east_asian_width(c)
    if eaw in ('W', 'F'):
        w += 2
    elif unicodedata.category(c) in ('Mn', 'Me', 'Cf') or c == '\ufe0f':
        w += 0
    else:
        w += 1
print(w)
" 2> /dev/null || {
		printf '%s' "$text" | sed 's/\x1b\[[0-9;]*m//g' | wc -m
	}
}

# Compute W from a list of raw text lines (call before drawing the box)
# Finds the longest visible line and adds 2 chars right padding
_auto_width() {
	local max_w=0
	for line in "$@"; do
		local stripped
		stripped=$(printf '%b' "$line" | sed 's/\x1b\[[0-9;]*m//g')
		local vw
		vw=$(_display_width "$stripped")
		if [ "$vw" -gt "$max_w" ]; then max_w="$vw"; fi
	done
	# Add 2 for right padding, clamp to [60, terminal_cols - 6]
	local term_w
	term_w=$(tput cols 2> /dev/null || echo 100)
	W=$((max_w + 2))
	if [ "$W" -lt 60 ]; then W=60; fi
	local max_allowed=$((term_w - 6))
	if [ "$W" -gt "$max_allowed" ]; then W=$max_allowed; fi
	return 0
}

row() {
	local content="$1"
	local stripped
	stripped=$(printf '%b' "$content" | sed 's/\x1b\[[0-9;]*m//g')
	local vlen
	vlen=$(_display_width "$stripped")
	local pad=$((W - vlen))
	[ "$pad" -lt 0 ] && pad=0
	printf "  ${CYN}│${RST}"
	printf '%b' "$content"
	printf '%*s' "$pad" ""
	printf "${CYN}│${RST}\n"
}

# Centered row
crow() {
	local content="$1"
	local stripped
	stripped=$(printf '%b' "$content" | sed 's/\x1b\[[0-9;]*m//g')
	local vlen
	vlen=$(_display_width "$stripped")
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

# ── Step tracking ────────────────────────────────────────────────────────────
STEPS=("VirtualBox" "Preseeded ISO" "VM Setup" "VM Start")
STEP_STATUS=("pending" "pending" "pending" "pending")
STEP_DETAIL=("" "" "" "")
DASHBOARD_LINES=0

# Braille spinner (static frame per step — no background process)
SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
SPIN_IDX=0
SPIN_LEN=${#SPIN_FRAMES[@]}

draw_dashboard() {
	local first_draw="${1:-false}"
	if [ "$first_draw" != "true" ] && [ "$DASHBOARD_LINES" -gt 0 ]; then
		printf "\033[${DASHBOARD_LINES}A"
	fi
	local lines=0

	printf "${CLR}"
	top
	lines=$((lines + 1))
	printf "${CLR}"
	crow "${BLD}${WHT}Born2beRoot  ─  VM Provisioner${RST}"
	lines=$((lines + 1))
	printf "${CLR}"
	mid
	lines=$((lines + 1))

	for i in "${!STEPS[@]}"; do
		local name="${STEPS[$i]}"
		local st="${STEP_STATUS[$i]}"
		local det="${STEP_DETAIL[$i]}"
		local icon color label

		# Advance spinner index so each redraw shows a new frame
		SPIN_IDX=$(((SPIN_IDX + 1) % SPIN_LEN))

		case "$st" in
			pending)
				icon="·"
				color="${DIM}"
				label="waiting"
				;;
			working)
				icon="${SPIN_FRAMES[$SPIN_IDX]}"
				color="${BLU}"
				label="working..."
				;;
			done)
				icon="✓"
				color="${GRN}"
				label="done"
				;;
			skip)
				icon="✓"
				color="${GRN}"
				label="ready"
				;;
			fail)
				icon="✗"
				color="${RED}"
				label="FAILED"
				;;
		esac

		local det_str=""
		[ -n "$det" ] && det_str=" ${DIM}${det}${RST}"

		local padded_name
		padded_name=$(printf "%-16s" "$name")

		printf "${CLR}"
		row "  ${color}${BLD}${icon}${RST}  ${color}${padded_name}${RST} ${color}${label}${RST}${det_str}"
		lines=$((lines + 1))
	done

	printf "${CLR}"
	bot
	lines=$((lines + 1))
	DASHBOARD_LINES=$lines
}

# ── Spinner: a tiny background subshell that only redraws 1 character ────────
# It writes the braille spinner char at a fixed (row, col) on the terminal.
# The actual command runs in the foreground — this is display-only.
SPINNER_PID=""

start_spinner() {
	local lines_up="$1"
	(
		trap 'exit 0' TERM INT
		local f=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
		local i=0
		while true; do
			# save cursor → move up → go to col 6 → print spinner → restore cursor
			printf "\0337\033[%dA\r\033[5C\033[1;34m%s\033[0m\0338" \
				"$lines_up" "${f[$i]}"
			i=$(((i + 1) % 10))
			sleep 0.1
		done
	) &
	SPINNER_PID=$!
}

stop_spinner() {
	if [ -n "$SPINNER_PID" ]; then
		kill "$SPINNER_PID" 2> /dev/null
		wait "$SPINNER_PID" 2> /dev/null
		SPINNER_PID=""
	fi
}

# Override trap now that stop_spinner is defined (cleanup() already calls stop_spinner)

# ── Run step in FOREGROUND with animated spinner ─────────────────────────────
run_step() {
	local idx="$1"
	shift
	local log="${LOG_DIR}/step_${idx}.log"
	STEP_STATUS[$idx]="working"
	draw_dashboard

	# Spinner targets the row of step $idx
	# After draw_dashboard cursor is below bot border:
	#   1 up = bot, 2 up = last step, ... so step $idx = (num_steps - idx + 1) up
	local lines_up=$((${#STEPS[@]} - idx + 1))
	start_spinner "$lines_up"

	# Run the actual command in FOREGROUND (blocks until done)
	local rc=0
	touch "$log"
	"$@" > "$log" 2>&1 || rc=$?

	# Kill spinner, update state, redraw
	stop_spinner

	if [ "$rc" -eq 0 ]; then
		STEP_STATUS[$idx]="done"
		draw_dashboard
	else
		STEP_STATUS[$idx]="fail"
		draw_dashboard
		printf "\n${RED}${BLD}  ── Error log: ${STEPS[$idx]} ──${RST}\n${DIM}"
		if [ -f "$log" ]; then
			tail -30 "$log" | sed 's/^/    /'
		else
			printf "    (log file was cleaned up)\n"
		fi
		printf "${RST}\n"
		exit 1
	fi
}

# ── Detect host IP (cross-platform) ─────────────────────────────────────────
get_host_ip() {
	if command -v ip > /dev/null 2>&1; then
		ip route get 1.1.1.1 2> /dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1
	elif command -v hostname > /dev/null 2>&1; then
		hostname -I 2> /dev/null | awk '{print $1}'
	else
		echo "127.0.0.1"
	fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  MAIN
# ═════════════════════════════════════════════════════════════════════════════
printf "${HIDE_CUR}\n"
draw_dashboard true

# Step 1 — VirtualBox
if command -v VBoxManage > /dev/null 2>&1; then
	STEP_STATUS[0]="skip"
	STEP_DETAIL[0]="v$(VBoxManage --version 2> /dev/null)"
	draw_dashboard
else
	run_step 0 ${MAKE_CMD} --no-print-directory deps
	STEP_DETAIL[0]="v$(VBoxManage --version 2> /dev/null)"
	draw_dashboard
fi

# Step 2 — Preseeded ISO
FORCE_ISO="${FORCE_ISO:-0}"
PRESEED_ISO=$(ls -1 debian-*-amd64-*preseed.iso 2> /dev/null | head -n1)
if [ "$FORCE_ISO" = "1" ]; then
	run_step 1 ${MAKE_CMD} --no-print-directory gen_iso
	PRESEED_ISO=$(ls -1 debian-*-amd64-*preseed.iso 2> /dev/null | head -n1)
	STEP_DETAIL[1]="$PRESEED_ISO"
	draw_dashboard
elif [ -n "$PRESEED_ISO" ]; then
	STEP_STATUS[1]="skip"
	STEP_DETAIL[1]="$PRESEED_ISO"
	draw_dashboard
else
	run_step 1 ${MAKE_CMD} --no-print-directory gen_iso
	PRESEED_ISO=$(ls -1 debian-*-amd64-*preseed.iso 2> /dev/null | head -n1)
	STEP_DETAIL[1]="$PRESEED_ISO"
	draw_dashboard
fi

# Step 3 — VM creation
# Check VM exists AND its disk is intact (not just registered)
VM_OK=false
if VBoxManage showvminfo "${VM_NAME}" > /dev/null 2>&1; then
	VM_VDI=$(VBoxManage showvminfo "${VM_NAME}" --machinereadable 2> /dev/null \
		| grep '"SATA Controller-0-0"' | cut -d'"' -f4)
	if [ -n "$VM_VDI" ] && [ -f "$VM_VDI" ]; then
		VM_OK=true
	else
		# Stale VM registration — disk is missing, clean it up
		# Must power off first if running, otherwise unregister fails
		_vm_state=$(VBoxManage showvminfo "${VM_NAME}" --machinereadable 2> /dev/null \
			| grep "^VMState=" | cut -d'"' -f2)
		if [ "$_vm_state" = "running" ] || [ "$_vm_state" = "paused" ] || [ "$_vm_state" = "stuck" ]; then
			VBoxManage controlvm "${VM_NAME}" poweroff 2> /dev/null || true
			sleep 3
			# Wait for session lock to release
			for _i in $(seq 1 10); do
				VBoxManage modifyvm "${VM_NAME}" --description "" 2> /dev/null && break
				sleep 1
			done
		fi
		VBoxManage unregistervm "${VM_NAME}" --delete 2> /dev/null || \
			VBoxManage unregistervm "${VM_NAME}" 2> /dev/null || true
	fi
fi

if [ "$VM_OK" = true ]; then
	STEP_STATUS[2]="skip"
	STEP_DETAIL[2]="${VM_NAME}"
	draw_dashboard
else
	run_step 2 ${MAKE_CMD} --no-print-directory setup_vm
	STEP_DETAIL[2]="${VM_NAME}"
	draw_dashboard
fi

# Step 4 — Start VM (install from ISO)
VM_STATE=$(VBoxManage showvminfo "${VM_NAME}" --machinereadable 2> /dev/null \
	| grep "^VMState=" | cut -d'"' -f2)
if [ "$VM_STATE" = "running" ]; then
	STEP_STATUS[3]="skip"
	STEP_DETAIL[3]="already running"
	draw_dashboard
else
	run_step 3 VBoxManage startvm "${VM_NAME}" --type gui
	STEP_DETAIL[3]="installing..."
	draw_dashboard
fi

# ── Wait for VM to fully unlock after poweroff ──────────────────────────────
# VBoxManage controlvm poweroff returns immediately but the session lock
# takes several seconds to release. modifyvm will FAIL if we don't wait.
wait_for_vm_unlock() {
	local max_wait=30
	local i=0
	while [ "$i" -lt "$max_wait" ]; do
		local st
		st=$(VBoxManage showvminfo "${VM_NAME}" --machinereadable 2> /dev/null \
			| grep "^VMState=" | cut -d'"' -f2)
		if [ "$st" = "poweroff" ] || [ "$st" = "aborted" ] || [ "$st" = "saved" ]; then
			# Try a harmless modifyvm to see if the lock is actually released
			if VBoxManage modifyvm "${VM_NAME}" --description "b2b" 2> /dev/null; then
				return 0
			fi
		fi
		sleep 1
		i=$((i + 1))
	done
	return 1 # still locked after 30s
}

# ── Switch boot order from DVD to disk (with retries) ───────────────────────
switch_boot_to_disk() {
	local max_retries=5
	local attempt=0
	while [ "$attempt" -lt "$max_retries" ]; do
		if VBoxManage modifyvm "${VM_NAME}" --boot1 disk --boot2 dvd --boot3 none --boot4 none 2> /dev/null; then
			VBoxManage storageattach "${VM_NAME}" --storagectl "IDE Controller" \
				--port 0 --device 0 --medium emptydrive 2> /dev/null || true
			return 0
		fi
		sleep 3
		attempt=$((attempt + 1))
	done
	# Last-resort: the lock may be truly stuck — kill any leftover VBox processes
	# for this VM and try one more time
	VBoxManage controlvm "${VM_NAME}" poweroff 2> /dev/null || true
	sleep 5
	VBoxManage modifyvm "${VM_NAME}" --boot1 disk --boot2 dvd --boot3 none --boot4 none 2> /dev/null || true
	VBoxManage storageattach "${VM_NAME}" --storagectl "IDE Controller" \
		--port 0 --device 0 --medium emptydrive 2> /dev/null || true
}

# ── Wait for install to finish (VM will power off) then boot from disk ───
# The preseed sets exit/poweroff=true so the VM shuts down after install.
# We wait for that, then switch boot order from DVD→disk to disk→DVD,
# detach the ISO, and start the VM to boot from the installed system.
#
# EDGE CASE: busybox 'halt' in the d-i environment may not trigger a real
# ACPI poweroff, leaving VirtualBox in VMState="running" with 0% CPU
# ("System halted" on screen). We detect this by checking CPU load:
# if the VM's CPU usage drops to 0% for consecutive checks, it's halted.
wait_for_install() {
	local timeout=2400 # 40 minutes max (installs can be slow on shared storage)
	local elapsed=0
	local zero_cpu_count=0 # consecutive checks with ~0% CPU
	local min_elapsed=600  # don't check CPU in first 10 min (install is busy)
	local metrics_available=false

	# Try to enable metrics (not all VBox installations support this)
	if VBoxManage metrics setup --period 5 --samples 3 "${VM_NAME}" 2> /dev/null; then
		VBoxManage metrics enable "${VM_NAME}" CPU/Load/User 2> /dev/null && metrics_available=true
	fi

	while [ $elapsed -lt $timeout ]; do
		sleep 10
		elapsed=$((elapsed + 10))
		local state
		state=$(VBoxManage showvminfo "${VM_NAME}" --machinereadable 2> /dev/null \
			| grep "^VMState=" | cut -d'"' -f2)

		# Clean poweroff detected — the installer finished and ACPI worked
		if [ "$state" = "poweroff" ] || [ "$state" = "aborted" ]; then
			return 0
		fi

		# Only attempt CPU-based halt detection if metrics are ACTUALLY working
		# Without real metrics we CANNOT distinguish "install busy" from "halted"
		# so we just wait for the VM to reach poweroff state on its own.
		if [ "$state" = "running" ] && [ $elapsed -gt $min_elapsed ] && [ "$metrics_available" = true ]; then
			local cpu_pct
			cpu_pct=$(VBoxManage metrics query "${VM_NAME}" CPU/Load/User 2> /dev/null \
				| tail -1 | awk '{print $NF}' | tr -d '%' | cut -d. -f1)
			if [ -n "$cpu_pct" ] && [ "$cpu_pct" -eq 0 ] 2> /dev/null; then
				zero_cpu_count=$((zero_cpu_count + 1))
			elif [ -n "$cpu_pct" ]; then
				zero_cpu_count=0
			fi
			if [ $zero_cpu_count -ge 12 ]; then
				STEP_DETAIL[3]="VM halted (0% CPU for 2min), forcing poweroff..."
				draw_dashboard
				VBoxManage controlvm "${VM_NAME}" poweroff 2> /dev/null || true
				wait_for_vm_unlock
				return 0
			fi
		fi
		local mins=$((elapsed / 60))
		local secs=$((elapsed % 60))
		STEP_DETAIL[3]="installing... ${mins}m${secs}s"
		draw_dashboard
	done
	STEP_DETAIL[3]="timeout reached, forcing poweroff..."
	draw_dashboard
	VBoxManage controlvm "${VM_NAME}" poweroff 2> /dev/null || true
	wait_for_vm_unlock
	return 0
}

# Only wait if the VM was just started for installation (DVD boot)
BOOT1=$(VBoxManage showvminfo "${VM_NAME}" --machinereadable 2> /dev/null \
	| grep "^boot1=" | cut -d'"' -f2)
if [ "$BOOT1" = "dvd" ]; then
	STEP_DETAIL[3]="installing (this takes ~10-20 min)..."
	draw_dashboard
	wait_for_install
	STEP_DETAIL[3]="switching boot to disk..."
	draw_dashboard
	wait_for_vm_unlock
	switch_boot_to_disk
	new_boot=$(VBoxManage showvminfo "${VM_NAME}" --machinereadable 2> /dev/null \
		| grep "^boot1=" | cut -d'"' -f2)
	if [ "$new_boot" != "disk" ]; then
		sleep 5
		switch_boot_to_disk
	fi

	STEP_DETAIL[3]="install done, booting from disk..."
	draw_dashboard
	sleep 2
	VBoxManage startvm "${VM_NAME}" --type gui 2> /dev/null || true
	STEP_STATUS[3]="done"
	STEP_DETAIL[3]="booted from disk ✓"
	draw_dashboard
else
	STEP_DETAIL[3]="booted from disk"
	draw_dashboard
fi

# ── Read actual ports from VM config (no hardcoding) ─────────────────────────
get_vm_port() {
	local name="$1"
	local line
	line=$(VBoxManage showvminfo "${VM_NAME}" --machinereadable 2> /dev/null \
		| grep "^Forwarding" | grep "\"${name}")
	# If searching for "http", exclude "https" matches
	if [ "$name" = "http" ]; then
		line=$(echo "$line" | grep -v "\"https")
	fi
	echo "$line" | head -1 | cut -d',' -f4
}

# Find a free port for the preseed HTTP server (not used by VM or system)
find_free_port() {
	local port="$1"
	local max=100 i=0
	while [ "$i" -lt "$max" ]; do
		if ! (ss -tln 2> /dev/null || netstat -tln 2> /dev/null) | grep -qE "(0\.0\.0\.0|\*|\[::\]):${port}\b"; then
			echo "$port"
			return 0
		fi
		port=$((port + 1))
		i=$((i + 1))
	done
	echo "$1" # fallback
}

P_SSH=$(get_vm_port ssh)
P_HTTP=$(get_vm_port http)
P_HTTPS=$(get_vm_port https)
P_DOCKER=$(get_vm_port docker)
P_MARIADB=$(get_vm_port mariadb)
P_REDIS=$(get_vm_port redis)
P_FRONTEND=$(get_vm_port frontend)
P_BACKEND=$(get_vm_port backend)
P_PRESEED=$(find_free_port 8080)

# ── Host-side SSH config (keepalives + VM shortcut) ──────────────────────────
setup_host_ssh_config() {
	local ssh_dir="$HOME/.ssh"
	local ssh_config="$ssh_dir/config"
	local marker="# Born2beRoot VM (auto-generated)"

	mkdir -p "$ssh_dir"
	chmod 700 "$ssh_dir"
	touch "$ssh_config"
	chmod 600 "$ssh_config"

	# Remove any previous Born2beRoot block
	if grep -q "$marker" "$ssh_config" 2> /dev/null; then
		sed -i "/${marker}/,/^$/d" "$ssh_config"
	fi

	# Ensure global keepalive defaults exist at the top
	# ServerAliveInterval 15 = send keepalive every 15 seconds to keep VirtualBox NAT alive
	if ! grep -q '^Host \*' "$ssh_config" 2> /dev/null; then
		cat >> "$ssh_config" << SSHEOF

Host *
    ServerAliveInterval 15
    ServerAliveCountMax 4
    TCPKeepAlive yes
    ConnectionAttempts 3
    ConnectTimeout 15
SSHEOF
	fi

	# Add VM-specific shortcut
	cat >> "$ssh_config" << SSHEOF

${marker}
Host b2b vm born2beroot
    HostName 127.0.0.1
    Port ${P_SSH}
    User dlesieur
    ServerAliveInterval 15
    ServerAliveCountMax 6
    TCPKeepAlive yes
    ConnectionAttempts 5
    ConnectTimeout 15
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR

SSHEOF
	echo "  ✓ Host SSH config updated (~/.ssh/config)"
	echo "    → 'ssh b2b' connects directly to the VM"
}

# ── VS Code Remote SSH settings (fix stale SOCKS proxy + banner timeout) ────
setup_vscode_remote_ssh() {
	local vscode_settings="$HOME/.config/Code/User/settings.json"
	mkdir -p "$(dirname "$vscode_settings")"
	[ -f "$vscode_settings" ] || printf '{}\n' > "$vscode_settings"

	# Use python3 to safely merge JSON settings
	python3 -c "
import json, sys
try:
    with open('$vscode_settings', 'r') as f:
        s = json.load(f)
except:
    s = {}

# VS Code Remote SSH uses '-D port' (SOCKS dynamic forwarding) by default.
# VirtualBox NAT silently drops the SOCKS proxy state after idle periods,
# causing 'Connection timed out during banner exchange' on reconnect.
# useLocalServer=false → Terminal Mode: each window gets its own SSH connection
# enableDynamicForwarding=false → no SOCKS proxy, direct TCP forwarding only
# useExecServer=false → simpler bootstrap, less state to go stale
s['remote.SSH.useLocalServer'] = False
s['remote.SSH.enableDynamicForwarding'] = False
s['remote.SSH.useExecServer'] = False
s['remote.SSH.connectTimeout'] = 60
s['remote.SSH.showLoginTerminal'] = True

# Suppress TypeScript/ESLint/CSS noise for containerized projects (Alpine Docker).
# Source code lives on the VM, but node_modules & build output live ONLY inside
# Docker containers → VS Code can't resolve imports → floods false-positive errors.
# To re-enable per-workspace: create .vscode/settings.json with the overrides.
s['typescript.validate.enable'] = False
s['javascript.validate.enable'] = False
s['typescript.tsserver.experimental.enableProjectDiagnostics'] = False
s['typescript.disableAutomaticTypeAcquisition'] = True
s['eslint.enable'] = False
s['css.validate'] = False
s['scss.validate'] = False
s['less.validate'] = False

with open('$vscode_settings', 'w') as f:
    json.dump(s, f, indent=4)
" 2> /dev/null && echo "  ✓ VS Code Remote SSH settings configured (Terminal Mode, no SOCKS proxy)" || true

	# Clean stale server data that causes 'Running server is stale' errors
	rm -rf "$HOME/.config/Code/User/globalStorage/ms-vscode-remote.remote-ssh/vscode-ssh-host-"* 2> /dev/null
}

# ── SSH key auth (enables instant reconnection without password prompts) ─────
setup_ssh_key_auth() {
	local ssh_dir="$HOME/.ssh"
	# Generate key if none exists
	if [ ! -f "$ssh_dir/id_rsa.pub" ] && [ ! -f "$ssh_dir/id_ed25519.pub" ]; then
		ssh-keygen -t ed25519 -f "$ssh_dir/id_ed25519" -N "" -q
		echo "  ✓ SSH key pair generated"
	fi
	echo "  ℹ SSH key will be auto-copied to VM after first boot (via orchestrator wait loop)"
}

setup_host_ssh_config 2> /dev/null || true
setup_vscode_remote_ssh 2> /dev/null || true
setup_ssh_key_auth 2> /dev/null || true

# ── Summary ──────────────────────────────────────────────────────────────────
HOST_IP=$(get_host_ip)
printf "${SHOW_CUR}\n"

# Compute responsive box width from the longest content line
_auto_width \
	"  ▸ What happens now" \
	"    The VM boots the preseeded ISO and installs Debian" \
	"    automatically (partitioning, SSH, WordPress, etc)." \
	"    root password      temproot123" \
	"    user (dlesieur)    tempuser123" \
	"    disk encryption    tempencrypt123" \
	"    1. Disk passphrase:  tempencrypt123" \
	"    SSH        ssh b2b   (shortcut — auto-configured)" \
	"    or         ssh -p ${P_SSH} dlesieur@127.0.0.1" \
	"    WordPress  http://127.0.0.1:${P_HTTP}/wordpress" \
	"    VS Code    Host: 127.0.0.1  Port: ${P_SSH}  User: dlesieur" \
	"    lighttpd :80  ·  MariaDB :3306  ·  PHP-FPM" \
	"    AppArmor: enforced  ·  UFW: active" \
	"    Docker :2375  ·  SSH :4242  ·  Monitoring: cron/10m" \
	"    If SSH drops, just reconnect — your session is still there" \
	"    Detach:  Ctrl+B d     Reattach:  ssh b2b  (automatic)" \
	"    Dashboard   http://127.0.0.1:${P_HTTP}/wordpress/wp-admin/" \
	"    Login      http://127.0.0.1:${P_HTTP}/wordpress/wp-login.php" \
	"    Creds      admin / admin123wp!" \
	"    DB         wordpress (wpuser / wppass123)" \
	"    Frontend   http://127.0.0.1:${P_FRONTEND}" \
	"    Backend    http://127.0.0.1:${P_BACKEND}/api" \
	"    API Docs   http://127.0.0.1:${P_BACKEND}/api/docs" \
	"    Host LAN IP:   ${HOST_IP}" \
	"    NAT gateway:   10.0.2.2  (host seen from VM)" \
	"      cd preseeds && python3 -m http.server ${P_PRESEED}" \
	"      http://10.0.2.2:${P_PRESEED}/preseed.cfg" \
	"    SSH      :${P_SSH}    HTTP     :${P_HTTP}    HTTPS    :${P_HTTPS}" \
	"    Frontend :${P_FRONTEND}  Backend  :${P_BACKEND}  Docker   :${P_DOCKER}" \
	"    MariaDB  :${P_MARIADB}  Redis    :${P_REDIS}" \
	"      ssh b2b  then  tail -f /var/log/first-boot.log" \
	"    make status      check current state"

top
crow "${GRN}${BLD}✓  All Steps Completed${RST}"
mid
blank
row "  ${BLD}${WHT}▸ What happens now${RST}"
row "    The VM boots the preseeded ISO and installs Debian"
row "    automatically (partitioning, SSH, WordPress, etc)."
blank
mid
row "  ${BLD}${WHT}▸ Credentials${RST}"
row "    ${DIM}root password${RST}      ${GRN}temproot123${RST}"
row "    ${DIM}user (dlesieur)${RST}    ${GRN}tempuser123${RST}"
row "    ${DIM}disk encryption${RST}    ${GRN}tempencrypt123${RST}"
blank
mid
row "  ${BLD}${WHT}▸ After Reboot${RST}"
row "    ${YLW}1.${RST} Disk passphrase:  ${GRN}tempencrypt123${RST}"
row "    ${YLW}2.${RST} Log in:  ${GRN}dlesieur${RST} / ${GRN}tempuser123${RST}"
blank
mid
row "  ${BLD}${WHT}▸ Connect from Host${RST}"
row "    ${DIM}SSH${RST}        ${BLD}ssh b2b${RST}   ${DIM}(shortcut — auto-configured)${RST}"
row "    ${DIM}or${RST}         ${BLD}ssh -p ${P_SSH} dlesieur@127.0.0.1${RST}"
row "    ${DIM}WordPress${RST}  ${BLD}http://127.0.0.1:${P_HTTP}/wordpress${RST}"
row "    ${DIM}VS Code${RST}    ${BLD}Host: 127.0.0.1  Port: ${P_SSH}  User: dlesieur${RST}"
blank
mid
row "  ${BLD}${WHT}▸ WordPress Dashboard${RST}  ${GRN}(auto-installed + ready)${RST}"
row "    ${DIM}Home${RST}       ${BLD}http://127.0.0.1:${P_HTTP}/wordpress${RST}"
row "    ${DIM}Dashboard${RST}  ${BLD}http://127.0.0.1:${P_HTTP}/wordpress/wp-admin/${RST}"
row "    ${DIM}Login${RST}      ${BLD}http://127.0.0.1:${P_HTTP}/wordpress/wp-login.php${RST}"
blank
row "    ${BLD}${YLW}⚡ Quick Login${RST}"
row "    ${DIM}Username${RST}   ${GRN}${BLD}admin${RST}"
row "    ${DIM}Password${RST}   ${GRN}${BLD}admin123wp!${RST}"
row "    ${DIM}DB name${RST}    wordpress  ${DIM}(user: wpuser / pass: wppass123)${RST}"
row "    ${DIM}Plugin${RST}     ${CYN}Tech Blog Toolkit${RST} ${DIM}(tutorials, syntax highlighting)${RST}"
blank
mid
row "  ${BLD}${WHT}▸ Services Inside VM${RST}"
row "    lighttpd ${DIM}:80${RST}  ·  MariaDB ${DIM}:3306${RST}  ·  PHP-FPM"
row "    AppArmor: ${GRN}enforced${RST}  ·  UFW: ${GRN}active${RST}"
row "    Docker ${DIM}:2375${RST}  ·  SSH ${DIM}:4242${RST}  ·  Monitoring: ${DIM}cron/10m${RST}"
blank
mid
row "  ${BLD}${WHT}▸ tmux — Session Persistence${RST}"
row "    ${GRN}Auto-enabled:${RST} SSH login auto-attaches to tmux"
row "    ${DIM}If SSH drops, just reconnect — your session is still there${RST}"
row "    ${DIM}Detach:${RST}  ${BLD}Ctrl+B d${RST}     ${DIM}Reattach:${RST}  ${BLD}ssh b2b${RST}  ${DIM}(automatic)${RST}"
row "    ${DIM}Split H:${RST} ${BLD}Ctrl+B |${RST}     ${DIM}Split V:${RST}   ${BLD}Ctrl+B -${RST}"
row "    ${DIM}New win:${RST} ${BLD}Ctrl+B c${RST}     ${DIM}List:${RST}      ${BLD}tmux ls${RST}"
blank
mid
row "  ${BLD}${WHT}▸ Vite Gourmand (Dev Servers)${RST}"
row "    ${DIM}Frontend${RST}   ${BLD}http://127.0.0.1:${P_FRONTEND}${RST}"
row "    ${DIM}Backend${RST}    ${BLD}http://127.0.0.1:${P_BACKEND}/api${RST}"
row "    ${DIM}API Docs${RST}   ${BLD}http://127.0.0.1:${P_BACKEND}/api/docs${RST}"
blank
mid
row "  ${BLD}${WHT}▸ Preseed via HTTP (alternative)${RST}"
row "    ${DIM}Host LAN IP:${RST}   ${GRN}${HOST_IP}${RST}"
row "    ${DIM}NAT gateway:${RST}   ${GRN}10.0.2.2${RST}  ${DIM}(host seen from VM)${RST}"
blank
row "    ${DIM}Serve preseed on your host:${RST}"
row "      ${BLD}cd preseeds && python3 -m http.server ${P_PRESEED}${RST}"
blank
row "    ${DIM}Use this URL in the Debian installer:${RST}"
row "      ${BLD}http://10.0.2.2:${P_PRESEED}/preseed.cfg${RST}"
blank
mid
row "  ${BLD}${WHT}▸ Port Forwarding (VM NAT)${RST}"
row "    ${DIM}SSH${RST}      ${WHT}:${P_SSH}${RST}    ${DIM}HTTP${RST}     ${WHT}:${P_HTTP}${RST}    ${DIM}HTTPS${RST}    ${WHT}:${P_HTTPS}${RST}"
row "    ${DIM}Frontend${RST} ${WHT}:${P_FRONTEND}${RST}  ${DIM}Backend${RST}  ${WHT}:${P_BACKEND}${RST}  ${DIM}Docker${RST}   ${WHT}:${P_DOCKER}${RST}"
row "    ${DIM}MariaDB${RST}  ${WHT}:${P_MARIADB}${RST}  ${DIM}Redis${RST}    ${WHT}:${P_REDIS}${RST}"
blank
mid
row "  ${BLD}${WHT}▸ First Boot Progress${RST}"
row "    ${YLW}First boot takes ~2 min${RST} for Docker + WordPress setup"
row "    ${DIM}Check progress:${RST}"
row "      ${BLD}ssh b2b${RST}  then  ${BLD}tail -f /var/log/first-boot.log${RST}"
blank
mid
row "  ${BLD}${WHT}▸ Useful Commands${RST}"
row "    ${BLU}make status${RST}      check current state"
row "    ${BLU}make poweroff${RST}    shut down the VM"
row "    ${BLU}make re${RST}          destroy and rebuild"
blank
bot
printf "\n"
