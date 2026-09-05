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
DIM='\033[2m'
GRN='\033[32m'
YLW='\033[33m'
RED='\033[31m'
BLU='\033[34m'

ok() { printf "${GRN}✓${RST} %s\n" "$*"; }
warn() { printf "${YLW}⚠${RST}  %s\n" "$*"; }
fail() { printf "${RED}✗${RST} %s\n" "$*"; }
info() { printf "${BLU}▶${RST} %s\n" "$*"; }

# ── Helpers ───────────────────────────────────────────────────────────────────

detect_pkg_mgr() {
    if command -v apt >/dev/null 2>&1; then
        PKG_MGR="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MGR="dnf"
    else
        PKG_MGR="unknown"
    fi
}
detect_pkg_mgr

pkg_installed() {
    if [ "$PKG_MGR" = "apt" ]; then
        dpkg -s "$1" 2>/dev/null | grep -q "^Status:.*installed"
    elif [ "$PKG_MGR" = "dnf" ]; then
        rpm -q "$1" >/dev/null 2>&1
    else
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  VirtualBox — Oracle apt repository + extension pack
# ─────────────────────────────────────────────────────────────────────────────

VBOX_KEYRING=/usr/share/keyrings/oracle-virtualbox-2016.gpg
VBOX_SOURCES=/etc/apt/sources.list.d/virtualbox.list

# Returns the distro codename (e.g. bookworm, noble)
_distro_codename() {
    lsb_release -cs 2>/dev/null ||
        grep -oP '(?<=VERSION_CODENAME=).+' /etc/os-release 2>/dev/null ||
        echo "bookworm"
}

# Oracle's repo doesn't always have entries for the very latest Debian/Ubuntu
# codenames; map them to the nearest supported one.
_map_vbox_codename() {
    case "$1" in
    trixie | sid | forky) echo "bookworm" ;;
    oracular | plucky | questing) echo "noble" ;;
    *) echo "$1" ;;
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
    curl -fsSL https://www.virtualbox.org/download/oracle_vbox_2016.asc |
        sudo gpg --yes --output "$VBOX_KEYRING" --dearmor

    # Write the source entry
    printf 'deb [arch=amd64 signed-by=%s] https://download.virtualbox.org/virtualbox/debian %s contrib\n' \
        "$VBOX_KEYRING" "$mapped" |
        sudo tee "$VBOX_SOURCES" >/dev/null

    # Refresh index so the new repo is visible to apt
    sudo apt-get update -qq 2>/dev/null || true

    ok "Oracle VirtualBox repository added"
}

# Version compare: is <ver> >= <major>.<minor>?  ("7.0.18" 7 1 -> false)
_vbox_ver_ge() {
    local ver="$1" want_major="$2" want_minor="$3"
    local major minor
    major=${ver%%.*}
    minor=${ver#*.}
    minor=${minor%%.*}
    [ -n "$major" ] && [ -n "$minor" ] || return 1
    case "$major$minor" in *[!0-9]*) return 1 ;; esac
    [ "$major" -gt "$want_major" ] && return 0
    [ "$major" -eq "$want_major" ] && [ "$minor" -ge "$want_minor" ]
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
    if VBoxManage list extpacks 2>/dev/null |
        grep -qiE "oracle (vm )?virtualbox extension pack"; then
        ok "VirtualBox Extension Pack already installed"
        return 0
    fi

    info "Downloading VirtualBox Extension Pack ${vbox_ver}..."

    # Oracle renamed the asset at 7.1: everything up to 7.0.x is published as
    # Oracle_VM_VirtualBox_Extension_Pack-<ver>.vbox-extpack, 7.1+ dropped the
    # "VM_". Guessing wrong is a plain 404, so derive the likely name from the
    # version and keep the other spelling as a fallback rather than giving up.
    local base_url="https://download.virtualbox.org/virtualbox/${vbox_ver}"
    local name_old="Oracle_VM_VirtualBox_Extension_Pack-${vbox_ver}.vbox-extpack"
    local name_new="Oracle_VirtualBox_Extension_Pack-${vbox_ver}.vbox-extpack"
    local -a candidates
    if _vbox_ver_ge "$vbox_ver" 7 1; then
        candidates=("$name_new" "$name_old")
    else
        candidates=("$name_old" "$name_new")
    fi

    # The local filename MUST match the pack name expected by VBoxManage, so
    # each candidate is downloaded under its own name.
    local downloaded=""
    local cand
    for cand in "${candidates[@]}"; do
        ext_url="${base_url}/${cand}"
        ext_tmp="/tmp/${cand}"
        if curl -fL --progress-bar -o "$ext_tmp" "$ext_url"; then
            downloaded="$ext_tmp"
            break
        fi
        rm -f "$ext_tmp"
    done

    if [ -z "$downloaded" ]; then
        warn "Could not download Extension Pack from ${base_url}/"
        warn "Tried: ${candidates[*]}"
        warn "Install it manually after setup:"
        warn "  sudo VBoxManage extpack install --replace <path-to.vbox-extpack>"
        return 0
    fi
    ext_tmp="$downloaded"

    # ── The license hash ────────────────────────────────────────────────────
    # `extpack install` refuses to run unattended without
    # --accept-license=<sha256 of the license text inside the pack>. The pack is
    # a gzipped tar, so the hash is computed straight out of it.
    local lic_path lic_hash
    lic_path=$(tar -tzf "$ext_tmp" 2>/dev/null | grep -m1 'ExtPack-license\.txt$')
    if [ -z "$lic_path" ]; then
        warn "No license file inside the pack — cannot accept it unattended."
        warn "Install it by hand:  sudo VBoxManage extpack install --replace ${ext_tmp}"
        return 0
    fi
    lic_hash=$(tar -Oxzf "$ext_tmp" "$lic_path" 2>/dev/null | sha256sum | awk '{print $1}')

    # ── Get root ONCE ───────────────────────────────────────────────────────
    # This used to run two separate `sudo VBoxManage ...` commands with their
    # output sent to /dev/null. That was bad in three ways: the password prompt
    # came back a second time after the first attempt failed, the reason for the
    # failure was thrown away, and nothing said whose password was being asked
    # for. The account name in sudo's prompt is the same "dlesieur" that owns
    # the VM, so typing the VM's password here is the obvious mistake to make.
    printf "\n"
    printf "${BLD}The Extension Pack installs into /usr/lib/virtualbox — that needs root.${RST}\n"
    printf "${DIM}sudo is about to ask for YOUR password on THIS machine (%s@%s).${RST}\n" \
        "$(id -un)" "$(hostname -s 2>/dev/null || echo host)"
    printf "${DIM}It is not the VM's password, and not the disk passphrase.${RST}\n"
    printf "${DIM}Press Ctrl+C to skip — nothing in this project needs the pack.${RST}\n\n"

    if ! sudo -v; then
        printf "\n"
        warn "No sudo — skipping the Extension Pack (the build does not need it)."
        warn "To install it later:  make extpack"
        return 0
    fi

    info "Installing VirtualBox Extension Pack ${vbox_ver}..."

    # Errors are captured, not discarded, so a failure can actually be read.
    local out rc=0
    out=$(sudo VBoxManage extpack install --replace \
        --accept-license="$lic_hash" "$ext_tmp" 2>&1) || rc=$?

    if [ "$rc" -eq 0 ]; then
        ok "VirtualBox Extension Pack ${vbox_ver} installed"
        rm -f "$ext_tmp"
        return 0
    fi

    warn "Extension Pack install failed:"
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    printf "\n"
    warn "Nothing in this project uses the pack — the build works without it."
    warn "To retry by hand:"
    warn "  sudo VBoxManage extpack install --replace --accept-license=${lic_hash} \\"
    warn "       ${ext_tmp}"
    # Keep the download so the command above works without re-fetching 18 MB.
    return 0
}

# Set to 1 (by `make extpack`) to actually install the Extension Pack. Left at 0
# the script only reports whether it is present, so `make all` never blocks on a
# sudo prompt for an optional component.
INSTALL_EXTPACK="${INSTALL_EXTPACK:-0}"

# Check VirtualBox. Sets VBOX_OK / VBOX_NEED_EXTPACK.
VBOX_OK=true
VBOX_NEED_EXTPACK=false

check_vbox() {
    if command -v VBoxManage >/dev/null 2>&1; then
        local ver
        ver=$(VBoxManage --version 2>/dev/null | sed 's/r.*//')
        ok "VBoxManage ${ver} ($(command -v VBoxManage))"

        if ! VBoxManage list extpacks 2>/dev/null |
            grep -qiE "oracle (vm )?virtualbox extension pack"; then
            # Optional, and this project never touches it: the pack adds USB
            # 2.0/3.0 passthrough, VRDP, NVMe, PXE and VDI encryption, while the
            # VM here runs on NAT + SATA + guest-side LUKS + a serial console.
            printf "${DIM}·${RST} VirtualBox Extension Pack not installed ${DIM}(optional — make extpack)${RST}\n"
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

# Format: "binary:package[:package ...]"
# Special binary "__pkg" checks via package manager instead of command -v.
if [ "$PKG_MGR" = "apt" ]; then
    declare -a CHECKS=(
        "xorriso:xorriso"
        "curl:curl"
        "cc:gcc"
        "__pkg:libreadline-dev"
        "python3:python3"
        "git:git"
        "ssh:openssh-client"
        "make:make"
    )
    VBOX_PKG="virtualbox-7.1"
elif [ "$PKG_MGR" = "dnf" ]; then
    declare -a CHECKS=(
        "xorriso:xorriso"
        "curl:curl"
        "cc:gcc"
        "__pkg:readline-devel"
        "python3:python3"
        "git:git"
        "ssh:openssh-clients"
        "make:make"
    )
    VBOX_PKG="VirtualBox"
else
    # Fallback for unknown
    declare -a CHECKS=(
        "xorriso:xorriso"
        "curl:curl"
        "cc:gcc"
        "__pkg:readline-devel"
        "python3:python3"
        "git:git"
        "ssh:openssh-client"
        "make:make"
    )
    VBOX_PKG="VirtualBox"
fi

MISSING_PKGS=""
ALL_OK=true

check_entry() {
    local entry binary rest
    entry="$1"
    binary="${entry%%:*}"
    rest="${entry#*:}"

    IFS=':' read -r -a pkg_arr <<<"$rest"

    if [ "$binary" = "__pkg" ]; then
        local p="${pkg_arr[0]}"
        if pkg_installed "$p"; then
            ok "${p} (dev headers)"
        else
            warn "${p} not installed"
            MISSING_PKGS="${MISSING_PKGS} ${p}"
            ALL_OK=false
        fi
        return 0
    fi

    if command -v "$binary" >/dev/null 2>&1; then
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
    MISSING_PKGS=$(printf '%s\n' $MISSING_PKGS |
        awk '!seen[$0]++' | tr '\n' ' ' | sed 's/ $//')
fi

# ── If everything is already present ─────────────────────────────────────────
if [ "$VBOX_OK" = true ] && [ -z "$MISSING_PKGS" ]; then
    # The ext-pack is deliberately NOT installed here. `make all` would stop on
    # a sudo prompt for something the build never uses, and a mistyped password
    # there reads like the build itself failed. `make extpack` asks for it.
    if [ "$VBOX_NEED_EXTPACK" = true ] && [ "$INSTALL_EXTPACK" = "1" ]; then
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
    if [ "$PKG_MGR" = "apt" ]; then
        info "VirtualBox is not installed. Setting up Oracle apt repository first..."
        setup_vbox_apt_repo
    fi

    printf "\n"
    printf "${YLW}⚠${RST}  VirtualBox is missing.\n"
    if [ "$PKG_MGR" = "apt" ]; then
        printf "${BLU}▶${RST} Running: ${BLD}sudo apt install %s${RST}\n" "$VBOX_PKG"
        printf "${BLU}▶${RST} apt will show the install plan — press Y to confirm.\n\n"
        sudo apt install ${CI:+-y} "$VBOX_PKG"
    elif [ "$PKG_MGR" = "dnf" ]; then
        printf "${BLU}▶${RST} Running: ${BLD}sudo dnf install %s${RST}\n" "$VBOX_PKG"
        printf "${BLU}▶${RST} dnf will show the install plan — press Y to confirm.\n\n"
        sudo dnf install ${CI:+-y} "$VBOX_PKG"
    else
        fail "Package manager unknown. Please manually install VirtualBox."
        exit 1
    fi

    if [ "$INSTALL_EXTPACK" = "1" ]; then
        printf "\n"
        install_vbox_extpack
    fi
    printf "\n"
fi

# ── Install remaining missing tools ──────────────────────────────────────────
if [ -n "$MISSING_PKGS" ]; then
    printf "${YLW}⚠${RST}  Missing packages: ${BLD}%s${RST}\n" "$MISSING_PKGS"
    if [ "$PKG_MGR" = "apt" ]; then
        printf "${BLU}▶${RST} Running: ${BLD}sudo apt install %s${RST}\n" "$MISSING_PKGS"
        printf "${BLU}▶${RST} apt will show the install plan — press Y to confirm.\n\n"
        sudo apt-get update -qq 2>/dev/null || true
        sudo apt install ${CI:+-y} $MISSING_PKGS
    elif [ "$PKG_MGR" = "dnf" ]; then
        printf "${BLU}▶${RST} Running: ${BLD}sudo dnf install %s${RST}\n" "$MISSING_PKGS"
        printf "${BLU}▶${RST} dnf will show the install plan — press Y to confirm.\n\n"
        sudo dnf install ${CI:+-y} $MISSING_PKGS
    else
        fail "Package manager unknown. Please manually install the missing packages."
        exit 1
    fi
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
