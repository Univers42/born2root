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
		# Ctrl+C stops this dashboard, not the VM: VirtualBox runs it in its own
		# process. Saying so avoids the obvious wrong conclusion — that the
		# install was cancelled and has to be started over from scratch.
		printf "\n${YLW}${BLD}  ⚠  Dashboard stopped — the VM keeps running${RST}\n"
		if VBoxManage list runningvms 2> /dev/null | grep -q "\"${VM_NAME}\""; then
			printf "${DIM}     watch it     make console\n"
			printf "     reattach     make all\n"
			printf "     stop the VM  make poweroff${RST}\n"
		fi
		printf "\n"
		exit 130
	fi
}
trap 'cleanup EXIT' EXIT
trap 'cleanup INT' INT
trap 'cleanup TERM' TERM

# ── Box drawing (single-line, rounded corners) ───────────────────────────────
W=60 # default inner visible width — recalculated below and before the summary

# Widen the dashboard to the terminal. The step rows carry live detail now (the
# preseed ISO's filename, the installer's current stage and percentage), and at
# a fixed 60 columns all of that gets cut off right where it stops being useful.
_dashboard_width() {
	local term_w
	term_w=$(tput cols 2> /dev/null || echo 100)
	W=$((term_w - 6))
	[ "$W" -lt 60 ] && W=60
	# Past ~92 the box is wider than anything it has to say.
	[ "$W" -gt 92 ] && W=92
	return 0
}

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
# "OS Install" and "First Boot" are separate steps on purpose. They used to be
# one "VM Start" row, and because starting a headless VM returns the moment the
# VM is up, that row went green the second the installer began booting — the
# dashboard read "VM Start done" for the next 20 minutes while Debian was still
# partitioning. A step is only allowed to say "done" once the thing it names has
# actually finished.
STEPS=("VirtualBox" "Preseeded ISO" "VM Setup" "OS Install" "First Boot")
STEP_STATUS=("pending" "pending" "pending" "pending" "pending")
STEP_DETAIL=("" "" "" "" "")
DASHBOARD_LINES=0
S_INSTALL=3
S_BOOT=4

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
			warn)
				icon="⚠"
				color="${YLW}"
				label="attention"
				;;
			fail)
				icon="✗"
				color="${RED}"
				label="FAILED"
				;;
		esac

		local padded_name
		padded_name=$(printf "%-16s" "$name")

		# Fit the detail to whatever space is left on the row. Without this a
		# long detail (the preseed ISO filename, a serial-console install stage)
		# runs straight through the box's right border.
		local det_str=""
		if [ -n "$det" ]; then
			# 2 lead + icon + 2 gap + 16 name + 1 gap + label + 1 gap
			local avail=$((W - 5 - 16 - 1 - ${#label} - 1))
			[ "$avail" -lt 8 ] && avail=8
			if [ "${#det}" -gt "$avail" ]; then
				det="${det:0:$((avail - 1))}…"
			fi
			det_str=" ${DIM}${det}${RST}"
		fi

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

# ── Run a step's command in the FOREGROUND with an animated spinner ─────────
# On failure both helpers print the command's log and abort the run; they differ
# only in what success means for the step, so run_step defers the work here.
run_phase() {
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

	if [ "$rc" -ne 0 ]; then
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
	# Deliberately still "working": the caller decides when the step is over.
	draw_dashboard
}

# The command IS the whole step, so a clean exit means the step is finished.
run_step() {
	local idx="$1"
	run_phase "$@"
	STEP_STATUS[$idx]="done"
	draw_dashboard
}

# Set a step's status and detail in one call, then redraw.
set_step() {
	STEP_STATUS[$1]="$2"
	STEP_DETAIL[$1]="$3"
	draw_dashboard
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

# Host port allocation (detects local listeners, including loopback-only ones
# such as the 42 ftpkg service on 127.0.0.1:4242). Shared with the VM installer
# so both agree on which host ports are free and never hand out one twice.
. "$(dirname "${BASH_SOURCE[0]}")/../utils/host_ports.sh"
# Reads the installer's own progress off serial.log (shared with qemu_vm.sh).
. "$(dirname "${BASH_SOURCE[0]}")/../setup/host/di_progress.sh"

# LUKS unlock helpers (resolve_passphrase / send_passphrase / wait_for_ssh).
# Sourcing defines functions only, so this starts nothing.
. "$(dirname "${BASH_SOURCE[0]}")/../unlock_vm.sh"

# Answer the guest's LUKS prompt without printing: draw_dashboard owns the
# terminal here, so progress goes through STEP_DETAIL instead of stdout.
#
# unlock_loop can spend up to VM_UNLOCK_TIMEOUT (240s) waiting for sshd. It only
# sleeps through unlock_sleep, which exists as an override point — hooking it is
# what keeps the dashboard alive during that wait instead of leaving a frozen
# spinner that looks like a hang.
UNLOCK_T0=0
unlock_sleep() {
	sleep "$1"
	local e=$(( $(date +%s) - UNLOCK_T0 ))
	STEP_DETAIL[$S_BOOT]="unlocking LUKS, waiting for sshd... ${e}s"
	draw_dashboard
}

unlock_booted_vm() {
	local pass port
	pass=$(resolve_passphrase 2> /dev/null) || return 1
	port=$(get_vm_ssh_port)
	: "${port:=4242}"
	UNLOCK_T0=$(date +%s)
	unlock_loop "$port" "$pass"
}

get_vm_port() {
	local name="$1"
	local line
	line=$(VBoxManage showvminfo "${VM_NAME}" --machinereadable 2> /dev/null \
		| awk -F'"' -v rule="$name" '$1 ~ /^Forwarding/ && $2 ~ "^" rule ",tcp," { print $2; exit }')
	echo "$line" | cut -d',' -f4
}

set_vm_nat_forward() {
	local name="$1"
	local host_port="$2"
	local guest_port="$3"
	local state
	state=$(VBoxManage showvminfo "${VM_NAME}" --machinereadable 2> /dev/null \
		| grep "^VMState=" | cut -d'"' -f2)

	if [ "$state" = "running" ]; then
		VBoxManage controlvm "${VM_NAME}" natpf1 delete "$name" > /dev/null 2>&1 || true
		VBoxManage controlvm "${VM_NAME}" natpf1 "$name,tcp,,${host_port},,${guest_port}" > /dev/null
	else
		VBoxManage modifyvm "${VM_NAME}" --natpf1 delete "$name" > /dev/null 2>&1 || true
		VBoxManage modifyvm "${VM_NAME}" --natpf1 "$name,tcp,,${host_port},,${guest_port}" > /dev/null
	fi
}

host_port_answers_ssh() {
	local port="$1"
	local banner
	command -v nc > /dev/null 2>&1 || return 1
	banner=$(printf '\r\n' | nc -w 2 127.0.0.1 "$port" 2> /dev/null | head -1 | tr -d '\r')
	[ "${banner#SSH-}" != "$banner" ]
}

host_port_answers_http() {
	local port="$1"
	command -v curl > /dev/null 2>&1 || return 1
	curl -fsSI --max-time 2 "http://127.0.0.1:${port}/" 2> /dev/null | grep -qi '^HTTP/'
}

ensure_vm_nat_forward() {
	local name="$1"
	local guest_port="$2"
	local preferred_port="$3"
	local current_port desired_port state

	current_port=$(get_vm_port "$name")
	state=$(VBoxManage showvminfo "${VM_NAME}" --machinereadable 2> /dev/null \
		| grep "^VMState=" | cut -d'"' -f2)

	if [ -n "$current_port" ]; then
		if [ "$state" = "running" ] || is_host_port_free "$current_port"; then
			reserve_host_port "$current_port"
			return 0
		fi
	fi

	resolve_host_port desired_port "$preferred_port"

	if [ -z "$current_port" ] || [ "$desired_port" != "$current_port" ]; then
		set_vm_nat_forward "$name" "$desired_port" "$guest_port"
		STEP_DETAIL[2]="${VM_NAME} ${name}:${desired_port}"
		draw_dashboard
	fi
}

ensure_vm_nat_forwarding() {
	local state
	state=$(VBoxManage showvminfo "${VM_NAME}" --machinereadable 2> /dev/null \
		| grep "^VMState=" | cut -d'"' -f2)
	if [ "$state" = "running" ]; then
		local ssh_port new_ssh_port
		ssh_port=$(get_vm_port ssh)
		if [ -z "$ssh_port" ] || { ! host_port_answers_ssh "$ssh_port" && host_port_answers_http "$ssh_port"; }; then
			resolve_host_port new_ssh_port 4242
			set_vm_nat_forward ssh "$new_ssh_port" 4242
			STEP_DETAIL[2]="${VM_NAME} ssh:${new_ssh_port}"
			draw_dashboard
		fi
	fi

	# When the VM is stopped, VirtualBox NAT is not listening yet, so any occupied
	# configured host port belongs to another process and must be moved.

	ensure_vm_nat_forward ssh 4242 4242
	ensure_vm_nat_forward http 80 8082
	ensure_vm_nat_forward https 443 8443
	# Inception's bonus static site. 'https' above already covers the
	# WordPress/NGINX container (guest 443), which is why there is no
	# separate inception-https rule.
	ensure_vm_nat_forward inception-static 8090 8090
	# Bonus services. Adminer lands on host 8081 rather than 8080, which this
	# script already reserves for the preseed server (resolve_host_port P_PRESEED).
	ensure_vm_nat_forward inception-adminer 8080 8081
	# FTP: the control port plus the whole passive range, or a directory listing
	# connects and then hangs — the data channel has nowhere to land. Host port 21
	# is privileged and unbindable as this user, hence 2121.
	ensure_vm_nat_forward inception-ftp 21 2121
	for _p in 21000 21001 21002 21003 21004 21005 21006 21007 21008 21009 21010; do
		ensure_vm_nat_forward "inception-ftp-pasv-${_p}" "$_p" "$_p"
	done
	ensure_vm_nat_forward docker 5000 5000
	ensure_vm_nat_forward mariadb 3306 3306
	ensure_vm_nat_forward redis 6379 6379
	ensure_vm_nat_forward frontend 5173 5173
	ensure_vm_nat_forward backend 3000 3000
	ensure_vm_nat_forward website 4322 4322
	ensure_vm_nat_forward osionos-app 3001 3001
	ensure_vm_nat_forward osionos-mail 3002 3002
	ensure_vm_nat_forward osionos-calendar 3003 3003
	ensure_vm_nat_forward osionos-bridge 4000 4000
	ensure_vm_nat_forward mail-bridge 4100 4100
	ensure_vm_nat_forward calendar-bridge 4200 4200
	ensure_vm_nat_forward baas-gateway 8000 8000
	ensure_vm_nat_forward baas-admin 8001 8001
	ensure_vm_nat_forward mailpit 8025 8025
	ensure_vm_nat_forward auth-gateway 8787 8787
	ensure_vm_nat_forward vault 18200 18200
}

# ═════════════════════════════════════════════════════════════════════════════
#  MAIN
# ═════════════════════════════════════════════════════════════════════════════
printf "${HIDE_CUR}\n"
_dashboard_width
draw_dashboard true

# Step 1 — VirtualBox
# `VBoxManage --version` prints its "vboxdrv kernel module is not loaded"
# warning on STDOUT, so "v$(VBoxManage --version 2>/dev/null)" used to paste
# that whole warning into this row -- a green "ready vWARNING: ..." on a
# machine that could not start a VM, which then failed 46 seconds later at
# startvm with no statement of the cause. Take the version only.
vbox_version() {
	VBoxManage --version 2> /dev/null \
		| grep -oE '^[0-9]+\.[0-9]+\.[0-9]+r?[0-9]*' | tail -1
}

if ! command -v VBoxManage > /dev/null 2>&1; then
	run_step 0 ${MAKE_CMD} --no-print-directory deps
fi

# The kernel driver is PER-MACHINE state: a 42 home is on NFS and follows you
# between workstations, but vboxdrv does not. So this repo can build on one
# machine and be unable to start a VM on the next with nothing changed. Gate
# here, before an ISO is downloaded or a VM is touched, and let the check's
# own diagnosis be the error log.
run_step 0 env NO_COLOR=1 VM_NAME="${VM_NAME}" \
	bash "$(dirname "$0")/../setup/host/check_vbox_driver.sh"
STEP_DETAIL[0]="v$(vbox_version)"
draw_dashboard

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

ensure_vm_nat_forwarding

# ── Serial console: the headless install's progress feed ────────────────────
# The VM writes COM1 to a file (setup/install/vms/install_vm_debian.sh) and the
# installer is booted with console=ttyS0 (generate/create_custom_iso.sh), so
# that file carries the installer's own text — "Installing the base system
# ... 70%" and so on. Reading it is what lets a headless run report the real
# stage instead of "it has been running for N minutes, probably fine".
# An older VM created before the serial port existed simply has no log; every
# caller below degrades to elapsed time rather than failing.
get_serial_log() {
	VBoxManage showvminfo "${VM_NAME}" --machinereadable 2> /dev/null \
		| awk -F'"' '/^uartmode1=/ {print $2}' \
		| awk -F, '$1 == "file" { sub(/^file,/, "", $0); print }'
}
SERIAL_LOG=$(get_serial_log)

# Latest installer step, condensed to one short line — or nothing.
#
# What the serial line carries depends on how d-i decided to present itself:
#
#   * On a serial console the installer wraps itself in GNU screen. Its UI is
#     then a full-screen newt/dialog app — cursor positioning, not text — so
#     stripping the ANSI leaves nothing readable, and screen repaints a status
#     bar ("[ 0 start (1*installer) 2 shell … ][ Aug 27 16:17 ]") every minute,
#     which is therefore always the newest line in the log. Reporting *that* as
#     the install stage is worse than reporting nothing.
#   * Kernel messages arrive on the same line and are line-oriented, but a
#     driver probe from three minutes ago is not "the current stage" either.
#
# So only a genuine d-i progress line counts. Anything else returns non-zero and
# the caller falls back to elapsed time, which is at least true.
install_stage() {
	[ -n "$SERIAL_LOG" ] && [ -r "$SERIAL_LOG" ] || return 1
	# First choice: the installer's own stage, which preseed.cfg's early_command
	# streams off d-i's syslog (setup/host/di_progress.sh). That works on the
	# VGA path that ships; the percentage lines below only exist with
	# SERIAL_CONSOLE=1.
	if di_current_stage "$SERIAL_LOG"; then return 0; fi
	local line label pct
	line=$(tail -c 8000 "$SERIAL_LOG" 2> /dev/null \
		| tr '\r' '\n' \
		| sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' -e 's/\x1b[()][B0]//g' -e 's/[^[:print:]]//g' \
		| grep -vE '\]\[ *[A-Z][a-z]{2} +[0-9]+ +[0-9]{2}:[0-9]{2} *\]' \
		| grep -vE '\([0-9]+\*(installer|shell|log|start)\)' \
		| grep -vE '^\[ *[0-9]+\.[0-9]+\]' \
		| grep -E '\.\.\..*[0-9]+%' \
		| tail -n1)
	[ -n "$line" ] || return 1

	label=${line%%...*}
	label=$(printf '%s' "$label" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
	[ -n "$label" ] || return 1
	pct=$(printf '%s' "$line" | grep -oE '[0-9]+%' | tail -n1)
	printf '%s %s' "$label" "$pct"
}

# Attach COM1 to a file on a VM that does not have one yet. VMs created before
# the serial console existed are otherwise permanently blind: no console, and
# `make console` has nothing to read. Requires the VM to be powered off, so this
# is called at the one point in the run where that is guaranteed.
ensure_serial_console() {
	[ -z "$(get_serial_log)" ] || return 0
	local cfg dir
	cfg=$(VBoxManage showvminfo "${VM_NAME}" --machinereadable 2> /dev/null \
		| grep "^CfgFile=" | cut -d'"' -f2)
	[ -n "$cfg" ] || return 1
	dir=$(dirname "$cfg")
	VBoxManage modifyvm "${VM_NAME}" --uart1 0x3F8 4 \
		--uartmode1 file "${dir}/serial.log" 2> /dev/null || return 1
	SERIAL_LOG=$(get_serial_log)
}

# Seconds this VM has been in its current state (i.e. how long it has actually
# been running), from VirtualBox's own clock. Ctrl+C kills the dashboard but not
# the VM, so on a reattach "how long has this script been watching" and "how far
# along is the install" are two very different numbers — the checks below want
# the second one.
vm_running_seconds() {
	local since epoch
	since=$(VBoxManage showvminfo "${VM_NAME}" --machinereadable 2> /dev/null \
		| grep "^VMStateChangeTime=" | cut -d'"' -f2)
	[ -n "$since" ] || return 1
	# VirtualBox reports UTC with nanoseconds; date wants neither.
	since=${since%.*}
	epoch=$(date -u -d "${since/T/ }" +%s 2> /dev/null) || return 1
	echo $(($(date +%s) - epoch))
}

# Has the installer finished, even though VirtualBox still says "running"?
#
# The preseed ends with exit/halt + exit/poweroff, but busybox's halt in the d-i
# environment does not always raise a real ACPI power button, so the VM can sit
# in VMState="running" at 0% CPU forever with "reboot: System halted" on a screen
# nobody is watching. The fallback for that is "CPU has been idle for two solid
# minutes", which cannot fire before the 10-minute mark and cannot tell a halted
# VM from a stalled one. The serial console says it outright, so ask it first.
# The preseed's finish-install hook writes this to the serial port once the
# install is genuinely finished (see preseeds/preseed.cfg). Unlike the kernel
# messages install_halted() looks for, it arrives even though d-i is NOT booted
# with console=ttyS0 — which stays off because it makes d-i wrap itself in GNU
# screen and stall (generate/create_custom_iso.sh explains at length).
install_complete_signalled() {
	[ -n "$SERIAL_LOG" ] && [ -r "$SERIAL_LOG" ] || return 1
	# Anchored: the syslog feed would otherwise match d-i logging the
	# late_command's text, which contains this string, as that command STARTS.
	grep -q '^B2B-INSTALL-COMPLETE' "$SERIAL_LOG" 2> /dev/null
}

install_halted() {
	[ -n "$SERIAL_LOG" ] && [ -r "$SERIAL_LOG" ] || return 1
	tail -c 4000 "$SERIAL_LOG" 2> /dev/null \
		| grep -qE 'reboot: (System halted|Power down)|System halted|Requesting system halt'
}

# What the OS Install row should say right now: the installer's own words when
# the serial console is available, elapsed time when it is not.
install_detail() {
	local elapsed="$1"
	local stage mins secs
	mins=$((elapsed / 60))
	secs=$((elapsed % 60))
	if stage=$(install_stage); then
		printf '%s  [%dm%02ds]' "$stage" "$mins" "$secs"
	else
		printf 'installing... %dm%02ds' "$mins" "$secs"
	fi
}

# Step 4 — Install Debian from the preseeded ISO (headless)
# Boot off DVD means the installer is still the thing that has to run; boot off
# disk means a previous run already finished it and only the first boot is left.
BOOT1=$(VBoxManage showvminfo "${VM_NAME}" --machinereadable 2> /dev/null \
	| grep "^boot1=" | cut -d'"' -f2)
VM_STATE=$(VBoxManage showvminfo "${VM_NAME}" --machinereadable 2> /dev/null \
	| grep "^VMState=" | cut -d'"' -f2)

if [ "$BOOT1" != "dvd" ] && install_wrote_data; then
	set_step $S_INSTALL skip "already installed"
elif [ "$BOOT1" != "dvd" ]; then
	# Boot order says "installed" but the disk is empty. That combination is what
	# a previous run leaves behind when the installer failed after the boot order
	# had already been switched — and trusting it means skipping the install,
	# booting an empty disk, and then blaming the LUKS unlock for timing out.
	# Put the ISO back and install properly.
	set_step $S_INSTALL working "disk is empty — reinstalling..."
	VBoxManage storageattach "${VM_NAME}" --storagectl "IDE Controller" \
		--port 0 --device 0 --type dvddrive --medium "$PRESEED_ISO" 2> /dev/null || true
	VBoxManage modifyvm "${VM_NAME}" --boot1 dvd --boot2 disk --boot3 none --boot4 none 2> /dev/null || true
	BOOT1=dvd
	[ -n "$SERIAL_LOG" ] && [ -w "$SERIAL_LOG" ] && : > "$SERIAL_LOG"
	VBoxManage startvm "${VM_NAME}" --type headless > /dev/null 2>&1 || true
elif [ "$VM_STATE" = "running" ]; then
	# A previous run was interrupted (Ctrl+C kills this script, not the VM) —
	# reattach to the install already in flight instead of restarting it.
	set_step $S_INSTALL working "reattaching to running VM..."
else
	# Truncate first: the serial log is the completion signal (install_halted
	# greps it for "System halted"), and a "System halted" left over from the
	# previous install would otherwise declare this one finished before it has
	# even begun.
	[ -n "$SERIAL_LOG" ] && [ -w "$SERIAL_LOG" ] && : > "$SERIAL_LOG"
	run_phase $S_INSTALL VBoxManage startvm "${VM_NAME}" --type headless
	set_step $S_INSTALL working "installer booting..."
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
	local zero_cpu_count=0 # consecutive VM polls with ~0% CPU
	local complete_at=""   # elapsed time when the install signalled completion
	# d-i still has to unmount and halt after the finish-install hooks run, so
	# do not yank the power the instant the marker appears. Twenty seconds is
	# far longer than that takes and still ~2 minutes faster than the CPU
	# heuristic it replaces.
	local complete_grace=20
	local min_elapsed=600  # don't check CPU in first 10 min (install is busy)
	local metrics_available=false

	# The dashboard ticks every 2s so the spinner actually spins and the serial
	# console's stage line stays current; VBoxManage is only asked for VM state
	# every VM_POLL seconds, since spawning it is far from free.
	local tick=2
	local vm_poll=10
	local since_poll=$vm_poll # poll immediately on the first pass

	# Time already spent installing before this dashboard attached. Without it a
	# reattach after Ctrl+C would restart the clock at zero and re-serve the full
	# 10-minute grace period before the halt heuristic is even allowed to look.
	local prior=0
	prior=$(vm_running_seconds 2> /dev/null) || prior=0

	# Try to enable metrics (not all VBox installations support this)
	if VBoxManage metrics setup --period 5 --samples 3 "${VM_NAME}" 2> /dev/null; then
		VBoxManage metrics enable "${VM_NAME}" CPU/Load/User 2> /dev/null && metrics_available=true
	fi

	while [ $elapsed -lt $timeout ]; do
		sleep $tick
		elapsed=$((elapsed + tick))
		since_poll=$((since_poll + tick))

		# Checked every tick: it is a local file read, and reacting within
		# seconds is the whole point of having the marker.
		if [ -z "$complete_at" ] && install_complete_signalled; then
			complete_at=$elapsed
			STEP_DETAIL[$S_INSTALL]="install finished, letting d-i unmount..."
			draw_dashboard
		fi
		if [ -n "$complete_at" ] && [ $((elapsed - complete_at)) -ge $complete_grace ]; then
			set_step $S_INSTALL working "install complete, powering off..."
			VBoxManage controlvm "${VM_NAME}" poweroff 2> /dev/null || true
			wait_for_vm_unlock
			return 0
		fi

		if install_halted; then
			set_step $S_INSTALL working "installer halted, powering off..."
			VBoxManage controlvm "${VM_NAME}" poweroff 2> /dev/null || true
			wait_for_vm_unlock
			return 0
		fi

		if [ $since_poll -ge $vm_poll ]; then
			since_poll=0
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
			if [ "$state" = "running" ] && [ $((elapsed + prior)) -gt $min_elapsed ] && [ "$metrics_available" = true ]; then
				local cpu_pct
				cpu_pct=$(VBoxManage metrics query "${VM_NAME}" CPU/Load/User 2> /dev/null \
					| tail -1 | awk '{print $NF}' | tr -d '%' | cut -d. -f1)
				if [ -n "$cpu_pct" ] && [ "$cpu_pct" -eq 0 ] 2> /dev/null; then
					zero_cpu_count=$((zero_cpu_count + 1))
				elif [ -n "$cpu_pct" ]; then
					zero_cpu_count=0
				fi
				if [ $zero_cpu_count -ge 12 ]; then
					set_step $S_INSTALL working "installer halted, forcing poweroff..."
					VBoxManage controlvm "${VM_NAME}" poweroff 2> /dev/null || true
					wait_for_vm_unlock
					return 0
				fi
			fi
		fi

		STEP_DETAIL[$S_INSTALL]=$(install_detail $((elapsed + prior)))
		draw_dashboard
	done
	# Timed out. Returning 0 here made the caller stamp the step "Debian
	# installed in ~43m" over an install that had written 4 MB to a 64 GB disk —
	# the exact "says done when it isn't" failure this dashboard exists to stop.
	set_step $S_INSTALL warn "timeout after $((timeout / 60))m, forcing poweroff..."
	VBoxManage controlvm "${VM_NAME}" poweroff 2> /dev/null || true
	wait_for_vm_unlock
	return 1
}

# Sanity check: did the installer actually write a system to the disk? A Debian
# base install is gigabytes; a VDI still near its empty size means the installer
# booted and then did nothing, which is otherwise invisible from the outside.
install_wrote_data() {
	local vdi bytes
	vdi=$(VBoxManage showvminfo "${VM_NAME}" --machinereadable 2> /dev/null \
		| grep '"SATA Controller-0-0"' | cut -d'"' -f4)
	[ -n "$vdi" ] && [ -f "$vdi" ] || return 1
	bytes=$(stat -c %s "$vdi" 2> /dev/null) || return 1
	# 512 MB: far below any real install, far above an empty dynamic VDI.
	[ "$bytes" -gt 536870912 ]
}

if [ "$BOOT1" = "dvd" ]; then
	# Back-date to when the VM actually started, not to when this dashboard
	# attached — otherwise a run that reattached after Ctrl+C reports a 20-minute
	# install as having taken two.
	INSTALL_PRIOR=$(vm_running_seconds 2> /dev/null) || INSTALL_PRIOR=0
	INSTALL_START=$(($(date +%s) - INSTALL_PRIOR))
	set_step $S_INSTALL working "installing (this takes ~10-20 min)..."
	INSTALL_OK=true
	wait_for_install || INSTALL_OK=false

	set_step $S_INSTALL working "switching boot to disk..."
	wait_for_vm_unlock
	ensure_serial_console
	switch_boot_to_disk
	new_boot=$(VBoxManage showvminfo "${VM_NAME}" --machinereadable 2> /dev/null \
		| grep "^boot1=" | cut -d'"' -f2)
	if [ "$new_boot" != "disk" ]; then
		sleep 5
		switch_boot_to_disk
	fi

	# Only now has the thing this step is named after actually happened — and
	# only if it really did. Both the clock and the disk have to agree.
	INSTALL_MINS=$((($(date +%s) - INSTALL_START) / 60))
	if [ "$INSTALL_OK" != true ]; then
		set_step $S_INSTALL fail "install timed out after ~${INSTALL_MINS}m"
		printf "\n${RED}${BLD}  ── The installer never finished ──${RST}\n"
		printf "${DIM}    Look at what it was doing:  make console\n"
		printf "    Or at its screen:           VBoxManage controlvm %s screenshotpng /tmp/vm.png${RST}\n\n" "${VM_NAME}"
		exit 1
	fi
	if ! install_wrote_data; then
		set_step $S_INSTALL fail "installer wrote nothing to the disk"
		printf "\n${RED}${BLD}  ── The disk is still empty ──${RST}\n"
		printf "${DIM}    The installer booted but never installed. Usually this means it\n"
		printf "    stopped on a prompt nothing answered. Check with: make console${RST}\n\n"
		exit 1
	fi
	set_step $S_INSTALL done "Debian installed in ~${INSTALL_MINS}m"
fi

# Step 5 — First boot off the disk, unlocked from the host
# Booting from disk stops at the guest's LUKS prompt long before networking
# exists, so the passphrase is typed into the VM's virtual keyboard from here
# (unlock_vm.sh). That keypress is what keeps the whole run headless: no
# VirtualBox window is ever opened, not even to unlock the disk.
BOOT_STATE=$(VBoxManage showvminfo "${VM_NAME}" --machinereadable 2> /dev/null \
	| grep "^VMState=" | cut -d'"' -f2)
if [ "$BOOT_STATE" != "running" ]; then
	set_step $S_BOOT working "booting from disk..."
	sleep 2
	VBoxManage startvm "${VM_NAME}" --type headless > /dev/null 2>&1 || true
fi

set_step $S_BOOT working "unlocking LUKS, waiting for sshd..."
if unlock_booted_vm; then
	set_step $S_BOOT done "booted and unlocked ✓"
else
	set_step $S_BOOT warn "LUKS unlock timed out — see: make console"
fi

# ── Read actual ports from VM config (no hardcoding) ─────────────────────────
# get_vm_port/resolve_host_port are defined near the top so they can also repair
# stale NAT rules before the VM starts.

P_SSH=$(get_vm_port ssh)
P_HTTP=$(get_vm_port http)
P_HTTPS=$(get_vm_port https)
P_DOCKER=$(get_vm_port docker)
P_MARIADB=$(get_vm_port mariadb)
P_REDIS=$(get_vm_port redis)
P_FRONTEND=$(get_vm_port frontend)
P_BACKEND=$(get_vm_port backend)
P_WEBSITE=$(get_vm_port website)
P_OSIONOS_APP=$(get_vm_port osionos-app)
P_OSIONOS_MAIL=$(get_vm_port osionos-mail)
P_OSIONOS_CALENDAR=$(get_vm_port osionos-calendar)
P_OSIONOS_BRIDGE=$(get_vm_port osionos-bridge)
P_MAIL_BRIDGE=$(get_vm_port mail-bridge)
P_CALENDAR_BRIDGE=$(get_vm_port calendar-bridge)
P_BAAS_GATEWAY=$(get_vm_port baas-gateway)
P_BAAS_ADMIN=$(get_vm_port baas-admin)
P_MAILPIT=$(get_vm_port mailpit)
P_AUTH_GATEWAY=$(get_vm_port auth-gateway)
P_VAULT=$(get_vm_port vault)
resolve_host_port P_PRESEED 8080

# ── Host-side SSH config (keepalives + VM shortcut) ──────────────────────────
setup_host_ssh_config() {
	local ssh_dir="$HOME/.ssh"
	local ssh_config="$ssh_dir/config"
	# The marker and the alias are scoped to VM_NAME so a second machine built
	# beside an existing one gets its own block instead of overwriting it. The
	# canonical "debian" VM keeps the historic marker and the bare `b2b` alias,
	# so existing configs, docs and habits are untouched.
	local marker alias_line
	if [ "${VM_NAME}" = "debian" ]; then
		marker="# Born2beRoot VM (auto-generated)"
		alias_line="Host b2b vm born2beroot"
	else
		marker="# Born2beRoot VM (auto-generated) [${VM_NAME}]"
		alias_line="Host b2b-${VM_NAME} ${VM_NAME}"
	fi

	mkdir -p "$ssh_dir"
	chmod 700 "$ssh_dir"
	touch "$ssh_config"
	chmod 600 "$ssh_config"

	# Remove any previous Born2beRoot block
	if grep -qxF "$marker" "$ssh_config" 2> /dev/null; then
		# Two escaping concerns here:
		#  - the scoped marker contains [ ] and . , which sed would read as a
		#    bracket expression / any-char instead of literals;
		#  - the plain "debian" marker is a PREFIX of every scoped marker, so an
		#    unanchored address would make a rebuild of "debian" also delete the
		#    block belonging to "debian-nvim". Hence the ^...$ anchors.
		local marker_re
		marker_re=$(printf '%s' "$marker" | sed 's/[][\.*^$\/]/\\&/g')
		sed -i "/^${marker_re}$/,/^$/d" "$ssh_config"
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

	# Every rebuild gives the VM a new host key on the same 127.0.0.1:<port>,
	# so ssh refuses to connect with REMOTE HOST IDENTIFICATION HAS CHANGED.
	# The `b2b` alias below dodges it via UserKnownHostsFile=/dev/null, but a
	# direct `ssh -p <port> dlesieur@127.0.0.1` — and scp, and VS Code — still
	# trip over the stale entry. Drop it here instead of making the user run
	# ssh-keygen -R by hand after every `make re`.
	if [ -f "$ssh_dir/known_hosts" ]; then
		ssh-keygen -q -f "$ssh_dir/known_hosts" -R "[127.0.0.1]:${P_SSH}" > /dev/null 2>&1 || true
		rm -f "$ssh_dir/known_hosts.old"
	fi
	# Dropping the stale key removes the scary warning, but leaves no key at all:
	# ssh then either prompts to confirm the fingerprint or, under BatchMode
	# (scp, VS Code, any script), fails outright with "Host key verification
	# failed". Record the new key now so direct connections just work. sshd is up
	# by this point — this runs after the LUKS unlock — and scanning a VM on
	# loopback is the same trust assumption the b2b alias already makes.
	if command -v ssh-keyscan > /dev/null 2>&1; then
		local scanned
		scanned=$(ssh-keyscan -T 10 -p "${P_SSH}" 127.0.0.1 2> /dev/null)
		if [ -n "$scanned" ]; then
			printf '%s\n' "$scanned" >> "$ssh_dir/known_hosts"
			chmod 600 "$ssh_dir/known_hosts"
		fi
	fi

	# Add VM-specific shortcut
	cat >> "$ssh_config" << SSHEOF

${marker}
${alias_line}
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
	echo "    → 'ssh ${alias_line#Host }' connects directly to the VM (first alias listed)"
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
	"  ▸ Where things stand" \
	"    Debian is installed and the VM is booted from disk with" \
	"    the encrypted volume already unlocked — no window needed." \
	"    Watch it any time with  make console" \
	"    The run did not finish cleanly — see the step marked above." \
	"    The details below are reference, not a report of what happened." \
	"    Look at the VM with  make console  ·  state: make status" \
	"    root password      temproot123" \
	"    user (dlesieur)    tempuser123" \
	"    disk encryption    tempencrypt123" \
	"    1. make start_vm  — headless, types the passphrase for you" \
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
	"    Plugin     Tech Blog Toolkit (tutorials, syntax highlighting)" \
	"    Frontend   http://127.0.0.1:${P_FRONTEND}" \
	"    Backend    http://127.0.0.1:${P_BACKEND}/api" \
	"    API Docs   http://127.0.0.1:${P_BACKEND}/api/docs" \
	"    Website             https://127.0.0.1:${P_WEBSITE}" \
	"    osionos app         https://127.0.0.1:${P_OSIONOS_APP}" \
	"    osionos bridge API  https://127.0.0.1:${P_OSIONOS_BRIDGE}" \
	"    Auth gateway        https://127.0.0.1:${P_AUTH_GATEWAY}/api/auth" \
	"    BaaS gateway        https://127.0.0.1:${P_BAAS_GATEWAY}" \
	"    Vault               https://127.0.0.1:${P_VAULT}" \
	"    Local mail inbox    http://127.0.0.1:${P_MAILPIT}" \
	"    osionos Mail        https://127.0.0.1:${P_OSIONOS_MAIL}" \
	"    Mail bridge         https://127.0.0.1:${P_MAIL_BRIDGE}" \
	"    osionos Calendar    https://127.0.0.1:${P_OSIONOS_CALENDAR}" \
	"    Calendar bridge     https://127.0.0.1:${P_CALENDAR_BRIDGE}" \
	"    Host LAN IP:   ${HOST_IP}" \
	"    NAT gateway:   10.0.2.2  (host seen from VM)" \
	"      cd preseeds && python3 -m http.server ${P_PRESEED}" \
	"      http://10.0.2.2:${P_PRESEED}/preseed.cfg" \
	"    SSH      :${P_SSH}    HTTP     :${P_HTTP}    HTTPS    :${P_HTTPS}" \
	"    Frontend :${P_FRONTEND}  Backend  :${P_BACKEND}  Docker   :${P_DOCKER}" \
	"    Website  :${P_WEBSITE}  App      :${P_OSIONOS_APP}  Auth     :${P_AUTH_GATEWAY}" \
	"    BaaS     :${P_BAAS_GATEWAY}  Mailpit  :${P_MAILPIT}  Vault    :${P_VAULT}" \
	"    MariaDB  :${P_MARIADB}  Redis    :${P_REDIS}" \
	"      ssh b2b  then  tail -f /var/log/first-boot.log" \
	"    make status      check current state"

top
# The banner reports what the steps actually say. It used to be hard-coded to
# "✓ All Steps Completed", so a run whose First Boot row read "⚠ LUKS unlock
# timed out" still ended by announcing success and telling the reader the volume
# was "already unlocked" — contradicting a warning printed four lines above it.
B2B_FAILED=0
B2B_WARNED=0
for _st in "${STEP_STATUS[@]}"; do
	case "$_st" in
		fail) B2B_FAILED=1 ;;
		warn) B2B_WARNED=1 ;;
	esac
done

if [ "$B2B_FAILED" = 1 ]; then
	crow "${RED}${BLD}✗  Finished with errors${RST}"
elif [ "$B2B_WARNED" = 1 ]; then
	crow "${YLW}${BLD}⚠  Finished — needs attention${RST}"
else
	crow "${GRN}${BLD}✓  All Steps Completed${RST}"
fi
mid
blank
row "  ${BLD}${WHT}▸ Where things stand${RST}"
if [ "$B2B_FAILED" = 1 ] || [ "$B2B_WARNED" = 1 ]; then
	row "    ${YLW}The run did not finish cleanly — see the step marked above.${RST}"
	row "    The details below are reference, not a report of what happened."
	row "    ${DIM}Look at the VM with${RST}  ${BLD}make console${RST}${DIM}  ·  state:${RST} ${BLD}make status${RST}"
else
	row "    Debian is installed and the VM is booted from disk with"
	row "    the encrypted volume already unlocked — no window needed."
	row "    ${DIM}Watch it any time with${RST}  ${BLD}make console${RST}"
fi
blank
mid
row "  ${BLD}${WHT}▸ Credentials${RST}"
row "    ${DIM}root password${RST}      ${GRN}temproot123${RST}"
row "    ${DIM}user (dlesieur)${RST}    ${GRN}tempuser123${RST}"
row "    ${DIM}disk encryption${RST}    ${GRN}tempencrypt123${RST}"
blank
mid
row "  ${BLD}${WHT}▸ After a reboot${RST}"
row "    ${YLW}1.${RST} ${BLD}make start_vm${RST}  ${DIM}— headless, types the passphrase for you${RST}"
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
row "  ${BLD}${WHT}▸ osionos / ft_transcendence Stack${RST}"
row "    ${DIM}Website${RST}             ${BLD}https://127.0.0.1:${P_WEBSITE}${RST}"
row "    ${DIM}osionos app${RST}         ${BLD}https://127.0.0.1:${P_OSIONOS_APP}${RST}"
row "    ${DIM}osionos bridge API${RST}  ${BLD}https://127.0.0.1:${P_OSIONOS_BRIDGE}${RST}"
row "    ${DIM}Auth gateway${RST}        ${BLD}https://127.0.0.1:${P_AUTH_GATEWAY}/api/auth${RST}"
row "    ${DIM}BaaS gateway${RST}        ${BLD}https://127.0.0.1:${P_BAAS_GATEWAY}${RST}"
row "    ${DIM}Vault${RST}               ${BLD}https://127.0.0.1:${P_VAULT}${RST}"
row "    ${DIM}Local mail inbox${RST}    ${BLD}http://127.0.0.1:${P_MAILPIT}${RST}"
row "    ${DIM}osionos Mail${RST}        ${BLD}https://127.0.0.1:${P_OSIONOS_MAIL}${RST}"
row "    ${DIM}Mail bridge${RST}         ${BLD}https://127.0.0.1:${P_MAIL_BRIDGE}${RST}"
row "    ${DIM}osionos Calendar${RST}    ${BLD}https://127.0.0.1:${P_OSIONOS_CALENDAR}${RST}"
row "    ${DIM}Calendar bridge${RST}     ${BLD}https://127.0.0.1:${P_CALENDAR_BRIDGE}${RST}"
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
row "    ${DIM}Website${RST}  ${WHT}:${P_WEBSITE}${RST}  ${DIM}App${RST}      ${WHT}:${P_OSIONOS_APP}${RST}  ${DIM}Auth${RST}     ${WHT}:${P_AUTH_GATEWAY}${RST}"
row "    ${DIM}BaaS${RST}     ${WHT}:${P_BAAS_GATEWAY}${RST}  ${DIM}Mailpit${RST}  ${WHT}:${P_MAILPIT}${RST}  ${DIM}Vault${RST}    ${WHT}:${P_VAULT}${RST}"
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

# Exit non-zero when a step failed, so `make all` reports failure to the shell
# instead of returning 0 after printing a red banner.
[ "$B2B_FAILED" = 1 ] && exit 1
exit 0
