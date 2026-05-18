#!/bin/bash
# check_deps.sh — verify and install host developer dependencies for born2root
# Called by: make deps
#
# VirtualBox strategy (separate from the rest):
#   1. If VBoxManage is missing, add the Oracle VirtualBox apt repository first
#      (Oracle's repo is the only reliable source for a current VirtualBox on
#      Debian/Ubuntu; the distro's own package is often outdated or missing).
#   2. Install virtualbox-7.1 via `sudo apt install` WITHOUT -y so the user
#      reviews and confirms the apt plan.
#   3. After apt install, download and install the matching Extension Pack via
#      VBoxManage (Oracle doesn't ship it as an apt package).
#
# All other tools (xorriso, curl, gcc, libreadline-dev, …):
#   Missing packages are collected into one list and installed in a single
#   `sudo apt install` call (no -y — user confirms).

set -e

# ── Colours ───────────────────────────────────────────────────────────────────
RST='\033[0m'
BLD='\033[1m'
GRN='\033[32m'
YLW='\033[33m'
RED='\033[31m'
BLU='\033[34m'

ok()   { printf "${GRN}✓${RST} %s\n" "$*"; }
warn() { printf "${YLW}⚠${RST}  %s\n" "$*"; }
fail() { printf "${RED}✗${RST} %s\n" "$*"; }
info() { printf "${BLU}▶${RST} %s\n" "$*"; }

# ── Helpers ───────────────────────────────────────────────────────────────────

dpkg_installed() {
	dpkg -s "$1" 2>/dev/null | grep -q "^Status:.*installed"
}

# ─────────────────────────────────────────────────────────────────────────────
#  VirtualBox — Oracle apt repository + extension pack
# ─────────────────────────────────────────────────────────────────────────────

VBOX_KEYRING=/usr/share/keyrings/oracle-virtualbox-2016.gpg
VBOX_SOURCES=/etc/apt/sources.list.d/virtualbox.list

# Returns the distro codename (e.g. bookworm, noble)
_distro_codename() {
	lsb_release -cs 2>/dev/null \
		|| grep -oP '(?<=VERSION_CODENAME=).+' /etc/os-release 2>/dev/null \
		|| echo "bookworm"
}

# Oracle's repo doesn't always have entries for the very latest Debian/Ubuntu
# codenames; map them to the nearest supported one.
_map_vbox_codename() {
	case "$1" in
		trixie|sid|forky)         echo "bookworm" ;;
		oracular|plucky|questing) echo "noble"    ;;
		*)                         echo "$1"       ;;
	esac
}

# Add the Oracle VirtualBox apt repository if not already present.
# This is done automatically (no user confirmation — just configuring a source).
setup_vbox_apt_repo() {
	if [ -f "$VBOX_SOURCES" ]; then
		ok "Oracle VirtualBox apt repo already configured"
		return 0
	fi

	local raw mapped
	raw=$(_distro_codename)
	mapped=$(_map_vbox_codename "$raw")

	info "Adding Oracle VirtualBox apt repository (${mapped})..."

	# Import the Oracle signing key
	curl -fsSL https://www.virtualbox.org/download/oracle_vbox_2016.asc \
		| sudo gpg --yes --output "$VBOX_KEYRING" --dearmor

	# Write the source entry
	printf 'deb [arch=amd64 signed-by=%s] https://download.virtualbox.org/virtualbox/debian %s contrib\n' \
		"$VBOX_KEYRING" "$mapped" \
		| sudo tee "$VBOX_SOURCES" > /dev/null

	# Refresh index so the new repo is visible to apt
	sudo apt-get update -qq 2>/dev/null || true

	ok "Oracle VirtualBox repository added"
}

# Download and install the VirtualBox Extension Pack matching the installed version.
# The ext-pack is not distributed as an apt package; fetched directly from Oracle.
install_vbox_extpack() {
	local vbox_ver ext_url ext_tmp
	vbox_ver=$(VBoxManage --version 2>/dev/null | sed 's/r.*//')

	if [ -z "$vbox_ver" ]; then
		warn "Cannot determine VirtualBox version — skipping Extension Pack install"
		return 0
	fi

	# Already installed?
	if VBoxManage list extpacks 2>/dev/null \
			| grep -qi "oracle vm virtualbox extension pack"; then
		ok "VirtualBox Extension Pack already installed"
		return 0
	fi

	info "Downloading VirtualBox Extension Pack ${vbox_ver}..."
	ext_url="https://download.virtualbox.org/virtualbox/${vbox_ver}/Oracle_VirtualBox_Extension_Pack-${vbox_ver}.vbox-extpack"
	# The filename MUST match the pack name expected by VBoxManage.
	ext_tmp="/tmp/Oracle_VirtualBox_Extension_Pack-${vbox_ver}.vbox-extpack"

	if ! curl -fL --progress-bar -o "$ext_tmp" "$ext_url"; then
		warn "Could not download Extension Pack from ${ext_url}"
		warn "Install it manually after setup:"
		warn "  sudo VBoxManage extpack install --replace <path-to.vbox-extpack>"
		rm -f "$ext_tmp"
		return 0
	fi

	info "Installing VirtualBox Extension Pack (accepting Oracle license)..."
	# VBoxManage extpack install requires --accept-license=<SHA256> to skip
	# the interactive prompt.  Compute the hash from the license file inside
	# the ext-pack tarball (which is just a gzipped tar archive).
	local lic_hash
	lic_hash=$(tar -Oxzf "$ext_tmp" ./ExtPack-license.txt 2>/dev/null | sha256sum 2>/dev/null | awk '{print $1}')

	local install_ok=false
	if [ -n "$lic_hash" ]; then
		if sudo VBoxManage extpack install --replace \
				--accept-license="$lic_hash" "$ext_tmp" > /dev/null 2>&1; then
			install_ok=true
		fi
	fi

	# Fallback: try without --accept-license (may work if already accepted)
	if [ "$install_ok" = false ]; then
		if sudo VBoxManage extpack install --replace "$ext_tmp" > /dev/null 2>&1; then
			install_ok=true
		fi
	fi

	if [ "$install_ok" = true ]; then
		ok "VirtualBox Extension Pack ${vbox_ver} installed"
		rm -f "$ext_tmp"
	else
		warn "Extension Pack auto-install failed. Install it manually:"
		warn "  sudo VBoxManage extpack install --replace ${ext_tmp}"
		# Keep the file so the user can run the command above.
	fi
}

# Check VirtualBox. Sets VBOX_OK / VBOX_NEED_EXTPACK.
VBOX_OK=true
VBOX_NEED_EXTPACK=false

check_vbox() {
	if command -v VBoxManage > /dev/null 2>&1; then
		local ver
		ver=$(VBoxManage --version 2>/dev/null | sed 's/r.*//')
		ok "VBoxManage ${ver} ($(command -v VBoxManage))"

		if ! VBoxManage list extpacks 2>/dev/null \
				| grep -qi "oracle vm virtualbox extension pack"; then
			warn "VirtualBox Extension Pack not installed"
			VBOX_NEED_EXTPACK=true
		fi
	else
		warn "VBoxManage not found"
		VBOX_OK=false
	fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  All other required tools
# ─────────────────────────────────────────────────────────────────────────────

# Format: "binary:apt-package[:apt-package ...]"
# Special binary "__dpkg" checks via dpkg instead of command -v.
declare -a CHECKS=(
	"xorriso:xorriso"
	"curl:curl"
	"cc:gcc"
	"__dpkg:libreadline-dev"
	"python3:python3"
	"git:git"
	"ssh:openssh-client"
	"make:make"
)

MISSING_PKGS=""
ALL_OK=true

check_entry() {
	local entry binary rest
	entry="$1"
	binary="${entry%%:*}"
	rest="${entry#*:}"

	IFS=':' read -r -a pkg_arr <<< "$rest"

	if [ "$binary" = "__dpkg" ]; then
		local p="${pkg_arr[0]}"
		if dpkg_installed "$p"; then
			ok "${p} (dev headers)"
		else
			warn "${p} not installed"
			MISSING_PKGS="${MISSING_PKGS} ${p}"
			ALL_OK=false
		fi
		return 0
	fi

	if command -v "$binary" > /dev/null 2>&1; then
		ok "${binary} ($(command -v "$binary"))"
	else
		warn "${binary} not found"
		for p in "${pkg_arr[@]}"; do
			MISSING_PKGS="${MISSING_PKGS} ${p}"
		done
		ALL_OK=false
	fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  MAIN
# ─────────────────────────────────────────────────────────────────────────────

printf "\n"
info "Checking developer host dependencies..."
printf "\n"

# 1. VirtualBox check
check_vbox

# 2. Check remaining tools
for entry in "${CHECKS[@]}"; do
	check_entry "$entry"
done

# Deduplicate missing packages
if [ -n "$MISSING_PKGS" ]; then
	MISSING_PKGS=$(printf '%s\n' $MISSING_PKGS \
		| awk '!seen[$0]++' | tr '\n' ' ' | sed 's/ $//')
fi

# ── If everything is already present ─────────────────────────────────────────
if [ "$VBOX_OK" = true ] && [ -z "$MISSING_PKGS" ]; then
	# Only the ext-pack might be missing
	if [ "$VBOX_NEED_EXTPACK" = true ]; then
		printf "\n"
		install_vbox_extpack
	fi
	printf "\n"
	ok "All dependencies are present. Ready to build."
	exit 0
fi

# ── Install VirtualBox if missing ─────────────────────────────────────────────
if [ "$VBOX_OK" = false ]; then
	printf "\n"
	info "VirtualBox is not installed. Setting up Oracle apt repository first..."
	setup_vbox_apt_repo

	printf "\n"
	printf "${YLW}⚠${RST}  VirtualBox is missing.\n"
	printf "${BLU}▶${RST} Running: ${BLD}sudo apt install virtualbox-7.1${RST}\n"
	printf "${BLU}▶${RST} apt will show the install plan — press Y to confirm.\n\n"

	sudo apt install virtualbox-7.1

	printf "\n"
	install_vbox_extpack
	printf "\n"
fi

# ── Install remaining missing tools ──────────────────────────────────────────
if [ -n "$MISSING_PKGS" ]; then
	printf "${YLW}⚠${RST}  Missing packages: ${BLD}%s${RST}\n" "$MISSING_PKGS"
	printf "${BLU}▶${RST} Running: ${BLD}sudo apt install %s${RST}\n" "$MISSING_PKGS"
	printf "${BLU}▶${RST} apt will show the install plan — press Y to confirm.\n\n"

	sudo apt-get update -qq 2>/dev/null || true
	sudo apt install $MISSING_PKGS
	printf "\n"
fi

# ── Re-verify ─────────────────────────────────────────────────────────────────
info "Re-checking dependencies after install..."
printf "\n"

VBOX_OK=true
VBOX_NEED_EXTPACK=false
check_vbox

MISSING_PKGS=""
ALL_OK=true
for entry in "${CHECKS[@]}"; do
	check_entry "$entry"
done

printf "\n"
if [ "$VBOX_OK" = false ] || [ "$ALL_OK" = false ]; then
	fail "Some dependencies are still missing. Resolve the issues above and run: make deps"
	exit 1
fi

ok "All dependencies satisfied. You can now run: make all"
exit 0
