#!/bin/bash
# Born2beRoot — status dashboard
# Called by: make status
set -e

VM_NAME="${1:-debian}"
PRESEED_FILE="${2:-preseeds/preseed.cfg}"

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

# Print a row: content is padded to exactly W visible chars
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

# Centered row
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

# ── Status line helper ───────────────────────────────────────────────────────
status_row() {
	local icon="$1" label="$2" value="$3"
	# Truncate value if total would exceed box width
	local vis_val
	vis_val=$(printf '%b' "$value" | sed 's/\x1b\[[0-9;]*m//g')
	local vis_label="   X  ${label} "
	local avail=$((W - ${#vis_label} - 1))
	if [ "${#vis_val}" -gt "$avail" ]; then
		# Truncate the raw value and re-wrap in color
		local trunc="${vis_val:0:$((avail - 2))}.."
		value="${GRN}${trunc}${RST}"
	fi
	row "   ${icon}  ${label} ${value}"
}

# ═════════════════════════════════════════════════════════════════════════════
printf "\n"
top
crow "${BLD}${WHT}Environment Status Dashboard${RST}"
mid

# ── VirtualBox ──
if command -v VBoxManage > /dev/null 2>&1; then
	VBOX_RAW=$(VBoxManage --version 2> /dev/null || true)
	VBOX_VER=$(printf '%s\n' "$VBOX_RAW" | grep -E '^[0-9]+\.[0-9]+' | tail -1)
	[ -z "$VBOX_VER" ] && VBOX_VER="unknown"
	if [ -c /dev/vboxdrv ]; then
		status_row "${GRN}${BLD}✓${RST}" "VirtualBox ......" "${GRN}v${VBOX_VER}${RST}"
	else
		status_row "${YLW}${BLD}⚠${RST}" "VirtualBox ......" "${YLW}v${VBOX_VER} driver missing${RST}"
	fi
else
	status_row "${RED}${BLD}✗${RST}" "VirtualBox ......" "${RED}not installed${RST}"
fi

# ── xorriso ──
if command -v xorriso > /dev/null 2>&1; then
	status_row "${GRN}${BLD}✓${RST}" "xorriso ........." "${GRN}installed${RST}"
else
	status_row "${RED}${BLD}✗${RST}" "xorriso ........." "${RED}not installed${RST}"
fi

# ── curl ──
if command -v curl > /dev/null 2>&1; then
	status_row "${GRN}${BLD}✓${RST}" "curl ............" "${GRN}installed${RST}"
else
	status_row "${RED}${BLD}✗${RST}" "curl ............" "${RED}not installed${RST}"
fi

# ── Preseed file ──
if [ -f "$PRESEED_FILE" ]; then
	status_row "${GRN}${BLD}✓${RST}" "Preseed ........." "${GRN}${PRESEED_FILE}${RST}"
else
	status_row "${RED}${BLD}✗${RST}" "Preseed ........." "${RED}missing${RST}"
fi

mid

# ── Debian base ISO ──
BASE=$(ls -1 debian-*-amd64-netinst.iso 2> /dev/null | head -n1)
if [ -n "$BASE" ]; then
	status_row "${GRN}${BLD}✓${RST}" "Base ISO ........" "${GRN}${BASE}${RST}"
else
	status_row "${YLW}${BLD}⚠${RST}" "Base ISO ........" "${YLW}not downloaded yet${RST}"
fi

# ── Preseeded ISO ──
PISO=$(ls -1 debian-*-amd64-*preseed.iso 2> /dev/null | head -n1)
if [ -n "$PISO" ]; then
	status_row "${GRN}${BLD}✓${RST}" "Preseed ISO ....." "${GRN}${PISO}${RST}"
else
	status_row "${YLW}${BLD}⚠${RST}" "Preseed ISO ....." "${YLW}not built yet${RST}"
fi

mid

# ── VM ──
if VBoxManage showvminfo "$VM_NAME" > /dev/null 2>&1; then
	STATE=$(VBoxManage showvminfo "$VM_NAME" --machinereadable 2> /dev/null \
		| grep "^VMState=" | cut -d'"' -f2)
	if [ "$STATE" = "running" ]; then
		status_row "${GRN}${BLD}✓${RST}" "VM \"${VM_NAME}\" ........" "${GRN}${BLD}running${RST}"
	elif [ "$STATE" = "poweroff" ]; then
		status_row "${YLW}${BLD}⚠${RST}" "VM \"${VM_NAME}\" ........" "${YLW}powered off${RST}"
	else
		status_row "${YLW}${BLD}⚠${RST}" "VM \"${VM_NAME}\" ........" "${YLW}${STATE}${RST}"
	fi
else
	status_row "${YLW}${BLD}⚠${RST}" "VM \"${VM_NAME}\" ........" "${YLW}not created${RST}"
fi

bot
printf "\n"
