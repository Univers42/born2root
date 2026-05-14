#!/bin/bash
# =============================================================================
# fix_hwe_kernel.sh — Fix VirtualBox vs HWE kernel incompatibility
#
# Strategy (in order, least invasive first):
#
#   1. If VirtualBox 7.1.x is installed or available from Oracle's official
#      APT repo, use it — 7.1.x supports kernel ≥ 6.13. Then install the
#      matching running-kernel headers and rebuild/load the host driver.
#
#   2. Otherwise, ensure a safe GA kernel (6.8.x) is INSTALLED ALONGSIDE the
#      current one, set GRUB to boot into it next time, and ask for a reboot.
#      On the second run (after reboot into 6.8.x) the HWE kernel is no longer
#      running, so it can be removed safely.
#
# Safety rules:
#   • The running kernel is NEVER removed — dpkg will refuse and it risks
#     an unbootable system.
#   • We only remove a kernel that is NOT currently running.
# =============================================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
R='\033[0;31m'
Y='\033[1;33m'
G='\033[0;32m'
B='\033[0;34m'
C='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info() { printf "${B}▶${NC} %s\n" "$*"; }
success() { printf "${G}✓${NC} %s\n" "$*"; }
warn() { printf "${Y}⚠${NC}  %s\n" "$*"; }
error() { printf "${R}✗${NC} %s\n" "$*" >&2; }
die() {
	error "$*"
	exit 1
}
hr() { printf '%s\n' "────────────────────────────────────────────────────"; }

# ── Root check ────────────────────────────────────────────────────────────────
if [[ "$(id -u)" -ne 0 ]]; then
	warn "Re-running with sudo..."
	exec sudo bash "$0" "$@"
fi

hr
printf "${BOLD}  VirtualBox / HWE Kernel Compatibility Fix${NC}\n"
hr

RUNNING_KERNEL="$(uname -r)"

vbox_version() {
	local raw version
	raw="$(VBoxManage --version 2> /dev/null || true)"
	version="$(printf '%s\n' "$raw" | grep -E '^[0-9]+\.[0-9]+' | tail -1 || true)"
	if [[ -n "$version" ]]; then
		printf '%s\n' "${version%%r*}"
	else
		printf 'unknown\n'
	fi
}

VBOX_VER="$(vbox_version)"
info "Running kernel : ${RUNNING_KERNEL}"
info "VirtualBox ver : ${VBOX_VER}"

# ── Helper: major version number of installed VirtualBox ─────────────────────
vbox_major() {
	local version
	version="$(vbox_version)"
	if [[ "$version" =~ ^([0-9]+)\.([0-9]+) ]]; then
		printf '%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
	else
		printf '0\n'
	fi
}

# ── Helper: install headers and rebuild/load the VirtualBox host driver ──────
ensure_vbox_driver_ready() {
	hr
	info "Checking VirtualBox kernel driver..."

	if test -c /dev/vboxdrv; then
		success "/dev/vboxdrv is ready. 'make start_vm' should work."
		return 0
	fi

	if ! command -v VBoxManage &> /dev/null; then
		die "VBoxManage is not installed. Run 'make deps' or install VirtualBox first."
	fi

	info "Installing build tools and headers for ${RUNNING_KERNEL}..."
	apt-get update -qq
	apt-get install -y "linux-headers-${RUNNING_KERNEL}" build-essential dkms perl
	dpkg --configure -a

	if [[ -x /sbin/vboxconfig ]]; then
		info "Rebuilding VirtualBox host modules with /sbin/vboxconfig..."
		/sbin/vboxconfig
	elif dpkg -s virtualbox-dkms &> /dev/null; then
		info "Reinstalling virtualbox-dkms..."
		apt-get install --reinstall -y virtualbox-dkms
	else
		warn "No /sbin/vboxconfig or virtualbox-dkms package found; trying modprobe only."
	fi

	modprobe vboxdrv 2> /dev/null || true
	modprobe vboxnetflt 2> /dev/null || true
	modprobe vboxnetadp 2> /dev/null || true

	if test -c /dev/vboxdrv; then
		success "VirtualBox kernel driver rebuilt and loaded."
	else
		if command -v mokutil &> /dev/null && mokutil --sb-state 2> /dev/null | grep -qi enabled; then
			warn "Secure Boot is enabled; unsigned VirtualBox modules may be blocked."
		fi
		die "VirtualBox driver is still missing. Check /var/log/vbox-setup.log or rerun: sudo /sbin/vboxconfig"
	fi
}

# ── STEP 1: Try upgrading VirtualBox to 7.1.x (Oracle repo) ──────────────────
# VirtualBox 7.1+ supports kernel ≥ 6.13, eliminating the need to touch kernels.
try_upgrade_virtualbox() {
	hr
	info "Step 1 — Trying to upgrade VirtualBox to 7.1.x from Oracle repo..."

	if ! command -v curl &> /dev/null; then
		apt-get install -y curl
	fi

	# Add Oracle APT key + repo if not already present
	if [[ ! -f /etc/apt/sources.list.d/virtualbox.list ]]; then
		info "Adding Oracle VirtualBox APT repository..."
		curl -fsSL https://www.virtualbox.org/download/oracle_vbox_2016.asc \
			| gpg --dearmor -o /usr/share/keyrings/oracle-virtualbox-2016.gpg
		echo "deb [arch=amd64 signed-by=/usr/share/keyrings/oracle-virtualbox-2016.gpg] \
https://download.virtualbox.org/virtualbox/debian $(lsb_release -cs) contrib" \
			> /etc/apt/sources.list.d/virtualbox.list
	fi
	apt-get update -qq

	if apt-cache show virtualbox-7.1 &> /dev/null; then
		info "Found virtualbox-7.1 — installing..."
		apt-get remove -y virtualbox virtualbox-7.0 2> /dev/null || true
		apt-get install -y virtualbox-7.1
		VBOX_VER="$(vbox_version)"
		ensure_vbox_driver_ready
		return 0
	else
		warn "virtualbox-7.1 not found in APT cache. Falling back to kernel install."
		return 1
	fi
}

# ── STEP 2: Install GA kernel alongside current, set GRUB, prompt reboot ──────
# Never touches the running kernel — only adds a new one.
install_safe_kernel_and_set_grub() {
	hr
	info "Step 2 — Installing a compatible GA kernel alongside ${RUNNING_KERNEL}..."
	info "  The running kernel will NOT be touched."

	apt-get update -qq
	apt-get install -y linux-image-generic linux-headers-generic

	# Re-scan for safe kernels
	mapfile -t SAFE_IMGS < <(
		dpkg -l 2> /dev/null \
			| awk '/^ii.*linux-image-[0-9]/{print $2}' \
			| grep -vE 'linux-image-(6\.(1[3-9]|[2-9][0-9])\.|[7-9]\.)' \
			|| true
	)

	if [[ "${#SAFE_IMGS[@]}" -eq 0 ]]; then
		die "linux-image-generic installed but no safe kernel detected. Check apt output above."
	fi

	SAFE_PKG="$(printf '%s\n' "${SAFE_IMGS[@]}" | sort -V | tail -1)"
	SAFE_VER="${SAFE_PKG#linux-image-}"
	success "Safe kernel available: ${SAFE_VER}"

	# Run update-grub so the new kernel appears in grub.cfg
	update-grub 2> /dev/null || true

	GRUB_CFG="/boot/grub/grub.cfg"
	[[ -f "$GRUB_CFG" ]] || {
		warn "grub.cfg not found — skipping grub-set-default"
		return
	}

	GRUB_ENTRY="$(grep -oP "(?<=menuentry ')[^']*${SAFE_VER}[^']*(?=')" "$GRUB_CFG" 2> /dev/null \
		| grep -iv recovery | head -1 || true)"
	[[ -z "$GRUB_ENTRY" ]] && GRUB_ENTRY="$(grep -oP "(?<=menuentry \")[^\"]*${SAFE_VER}[^\"]*(?=\")" \
		"$GRUB_CFG" 2> /dev/null | grep -iv recovery | head -1 || true)"

	if [[ -n "$GRUB_ENTRY" ]]; then
		if ! grep -q '^GRUB_DEFAULT=saved' /etc/default/grub 2> /dev/null; then
			cp /etc/default/grub /etc/default/grub.bak
			sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
			info "Set GRUB_DEFAULT=saved (backup: /etc/default/grub.bak)"
		fi
		grub-set-default "$GRUB_ENTRY"
		update-grub 2> /dev/null || true
		success "GRUB next boot: '${GRUB_ENTRY}'"
	else
		warn "Could not find GRUB entry for ${SAFE_VER} automatically."
		warn "At boot, select '${SAFE_VER}' from the GRUB menu manually."
	fi

	hr
	printf "${Y}${BOLD}  ACTION REQUIRED — reboot needed${NC}\n"
	hr
	printf "  ✔  GA kernel ${G}${SAFE_VER}${NC} installed and set as next boot target.\n"
	printf "  ✘  HWE kernel ${R}${RUNNING_KERNEL}${NC} is still running — cannot remove it yet.\n\n"
	printf "  After rebooting into ${G}${SAFE_VER}${NC}, run:\n"
	printf "    ${G}make fix_hwe${NC}\n"
	printf "  …to finish removing linux-image-${RUNNING_KERNEL}.\n"
	hr

	read -r -p "$(printf "${C}Reboot now?${NC} [y/N] ")" REPLY || REPLY="n"
	if [[ "${REPLY,,}" == "y" ]]; then
		info "Rebooting in 5 seconds... (Ctrl-C to cancel)"
		sleep 5
		reboot
	else
		warn "Reboot skipped. VirtualBox will not work until you reboot into ${SAFE_VER}."
	fi
}

# ── STEP 3: Remove stale HWE kernels that are NOT running ────────────────────
remove_non_running_hwe_kernels() {
	mapfile -t BAD_PKGS < <(
		dpkg -l 2> /dev/null \
			| awk '/^ii.*linux-image-[0-9]/{print $2}' \
			| grep -E 'linux-image-(6\.(1[3-9]|[2-9][0-9])\.|[7-9]\.)' \
			|| true
	)
	[[ "${#BAD_PKGS[@]}" -eq 0 ]] && return 0

	REMOVABLE=()
	for pkg in "${BAD_PKGS[@]}"; do
		ver="${pkg#linux-image-}"
		if [[ "$ver" == "$RUNNING_KERNEL" ]]; then
			warn "Skipping linux-image-${ver} — it is the running kernel."
		else
			REMOVABLE+=("$pkg")
			for extra in "linux-headers-${ver}" "linux-modules-${ver}" "linux-modules-extra-${ver}"; do
				dpkg -l "$extra" &> /dev/null && REMOVABLE+=("$extra") || true
			done
		fi
	done

	[[ "${#REMOVABLE[@]}" -eq 0 ]] && return 0

	info "Removing stale HWE package(s): ${REMOVABLE[*]}"
	apt-get remove -y "${REMOVABLE[@]}" || warn "Some packages could not be removed (non-fatal)"
	apt-get autoremove -y || warn "apt autoremove had issues (non-fatal)"
	dpkg --configure -a || warn "dpkg --configure -a reported issues"

	info "Reloading VirtualBox kernel driver..."
	modprobe vboxdrv 2> /dev/null && success "vboxdrv loaded" \
		|| warn "modprobe vboxdrv failed — try: sudo apt install --reinstall virtualbox-dkms"

	success "Stale HWE kernels removed."
}

# ── Main ──────────────────────────────────────────────────────────────────────

mapfile -t ALL_BAD < <(
	dpkg -l 2> /dev/null \
		| awk '/^ii.*linux-image-[0-9]/{print $2}' \
		| grep -E 'linux-image-(6\.(1[3-9]|[2-9][0-9])\.|[7-9]\.)' \
		|| true
)

if [[ "${#ALL_BAD[@]}" -eq 0 ]]; then
	success "No incompatible HWE kernels found."
	ensure_vbox_driver_ready
	exit 0
fi

info "New/HWE kernel package(s) detected:"
for pkg in "${ALL_BAD[@]}"; do
	ver="${pkg#linux-image-}"
	if [[ "$ver" == "$RUNNING_KERNEL" ]]; then
		printf "   ${Y}•${NC} %s  ${Y}← running${NC}\n" "$pkg"
	else
		printf "   ${Y}•${NC} %s\n" "$pkg"
	fi
done
hr

# Is the running kernel among the bad ones?
RUNNING_IS_BAD=false
for pkg in "${ALL_BAD[@]}"; do

	[[ "${pkg#linux-image-}" == "$RUNNING_KERNEL" ]] && RUNNING_IS_BAD=true && break
done

if $RUNNING_IS_BAD; then
	# Check if already on VBox 7.1+ (reported incompatible may be false alarm)
	MAJOR="$(vbox_major)"
	if [[ "$MAJOR" -ge 71 ]]; then
		success "VirtualBox ${VBOX_VER} already supports kernel ${RUNNING_KERNEL}."
		ensure_vbox_driver_ready
		exit 0
	fi

	warn "VirtualBox ${VBOX_VER} is incompatible with running kernel ${RUNNING_KERNEL}."
	printf "  Trying best fix first: upgrade VirtualBox → then install GA kernel if needed.\n"
	hr

	if try_upgrade_virtualbox; then
		success "VirtualBox upgraded and host driver is ready."
	else
		install_safe_kernel_and_set_grub
	fi
else
	info "Running kernel is safe. Removing non-running incompatible kernel(s)..."
	remove_non_running_hwe_kernels
	hr
	success "Done."
	ensure_vbox_driver_ready
fi
