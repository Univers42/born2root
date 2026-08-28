#!/bin/bash

set -e # Exit on any error

# Always run relative to repo root (so paths like preseeds/... and dist/... work
# regardless of the caller's current directory).
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)
cd "$REPO_ROOT"

# ── Portable downloader (curl preferred, wget fallback) ──────────────────────
download() {
	local url="$1" dest="$2"
	if command -v curl > /dev/null 2>&1; then
		curl -fL --progress-bar -o "$dest" "$url"
	elif command -v wget > /dev/null 2>&1; then
		wget -O "$dest" "$url"
	else
		echo "Error: neither curl nor wget found. Install one of them." >&2
		exit 1
	fi
}

# ── Dynamically discover the latest Debian netinst ISO ───────────────────────
BASE_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/"

echo "===== Creating Custom Debian ISO with Preseed ====="
echo "Querying $BASE_URL for the latest ISO filename..."

ISO_FILENAME=$(curl -fsSL "$BASE_URL" 2> /dev/null \
	| grep -oE 'debian-[0-9.]+-amd64-netinst\.iso' \
	| head -n1)

if [ -z "$ISO_FILENAME" ]; then
	echo "Error: Could not determine the latest Debian ISO filename from $BASE_URL"
	echo "The Debian mirrors may be temporarily unavailable."
	exit 1
fi

URL_IMAGE_ISO="${BASE_URL}${ISO_FILENAME}"
ISO_DIR="debian_iso_extract"
PRESEED_FILE="preseeds/preseed.cfg"
# Derive the output name from the discovered filename
OUTPUT_ISO="${ISO_FILENAME%.iso}-preseed.iso"
FORCE_ISO="${FORCE_ISO:-0}"

# ── Serial console for the headless install ─────────────────────────────────
# `make all` never opens a VirtualBox window, so without this the installer
# talks to a VGA screen nobody is looking at and the only progress signal the
# host has is "the VM is still running". Booting d-i with console=ttyS0 sends
# the whole install — every step, every percentage — down COM1, which the VM
# is configured to spool into disk_images/<vm>/serial.log (see
# setup/install/vms/install_vm_debian.sh). That file is the terminal-side
# window into the install: `make console` tails it, and the orchestrator reads
# it to report the actual stage.
#
# Order matters: the LAST console= wins as /dev/console, so ttyS0 must come
# after tty0 for d-i's UI to land on the serial port. tty0 is kept first so
# kernel messages still reach the VGA buffer, which keeps `VBoxManage controlvm
# <vm> screenshotpng` useful as a fallback when something goes wrong early.
# DEFAULT OFF, and that default is load-bearing. Booting d-i with console=ttyS0
# makes it wrap itself in GNU screen and drive a full-screen newt UI down the
# serial line. Measured consequences, on a real run:
#   * no readable progress — screen's status bar is the only plain text, so the
#     dashboard reported the status bar as the install stage;
#   * and worse, the automated install stopped dead. It sat for 40 minutes and
#     wrote 4 MB to a 64 GB disk, i.e. it never installed at all.
# The VGA console path is the one that completes in ~10-20 minutes unattended,
# so that is what ships. SERIAL_CONSOLE=1 is kept for debugging an install
# interactively over serial, where the screen wrapper is a feature.
#
# This only affects the INSTALLER. The installed system still mirrors its
# console to COM1 (see preseeds/b2b-setup.sh), which is what `make console`
# reads and which works — that path was verified end to end.
SERIAL_CONSOLE="${SERIAL_CONSOLE:-0}"
if [ "$SERIAL_CONSOLE" = "1" ]; then
	CONSOLE_ARGS="console=tty0 console=ttyS0,115200n8"
else
	CONSOLE_ARGS=""
fi

# Shared by the BIOS (isolinux) and EFI (grub) entries so the two can never
# drift apart — a mismatch here means the install behaves differently depending
# on which firmware path booted it, which is painful to diagnose.
# Preseed is inside the initrd (auto-detected by d-i), so no preseed/file= here.
# locale/country/keymap are belt-and-suspenders for questions asked before the
# preseed is read.
DI_CMDLINE="auto=true priority=critical DEBIAN_FRONTEND=noninteractive locale=en_US.UTF-8 language=en country=ES keymap=es hostname=dlesieur domain= vga=788 ${CONSOLE_ARGS}"

# Trailing args after the "---" separator. `quiet` is dropped on the serial path
# so the boot can be followed; on the VGA path it matches the cmdline that has
# actually completed an unattended install here.
if [ "$SERIAL_CONSOLE" = "1" ]; then
	DI_TAIL="---"
else
	DI_TAIL="--- quiet"
fi

echo "  Latest ISO: $ISO_FILENAME"
echo "  URL:        $URL_IMAGE_ISO"
echo "  Output:     $OUTPUT_ISO"
echo ""

# ── Check for already-built preseed ISO ──────────────────────────────────────
if [ -f "$OUTPUT_ISO" ]; then
	if [ "$FORCE_ISO" = "1" ]; then
		echo "↻ FORCE_ISO=1 — rebuilding: $OUTPUT_ISO"
		rm -f "$OUTPUT_ISO"
	else
		echo "✓ Preseeded ISO already exists: $OUTPUT_ISO"
		exit 0
	fi
fi

# ── Download the base ISO if needed ──────────────────────────────────────────
if [ -f "$ISO_FILENAME" ]; then
	echo "✓ ISO file found locally: $ISO_FILENAME"
else
	echo "Downloading ISO from $URL_IMAGE_ISO ..."
	download "$URL_IMAGE_ISO" "$ISO_FILENAME" || {
		echo "Error: Failed to download ISO"
		exit 1
	}
fi

# Check if preseed file exists
if [ ! -f "$PRESEED_FILE" ]; then
	echo "Error: $PRESEED_FILE not found!"
	exit 1
fi

# Remove a previous extraction. xorriso reproduces the ISO's read-only modes, so
# the tree has to be made writable before it can be deleted — and on the NFS
# home this repo lives on, a large recursive delete can still come back EACCES
# on the first pass while the server catches up. One retry clears it; without
# this the whole build died on a wall of "rm: Permission denied" lines.
purge_dir() {
	local dir="$1" attempt
	[ -e "$dir" ] || return 0
	for attempt in 1 2 3; do
		chmod -R u+w "$dir" 2> /dev/null || true
		rm -rf "$dir" 2> /dev/null
		[ -e "$dir" ] || return 0
		sleep 2
	done
	echo "Error: could not remove $dir (files still held open, or a stale NFS handle)." >&2
	echo "       Remove it by hand and re-run:  rm -rf $dir" >&2
	return 1
}

# Create extraction directory
echo "Extracting ISO to $ISO_DIR..."
purge_dir "$ISO_DIR"
mkdir -p "$ISO_DIR"

# Use xorriso (most portable for ISO manipulation), fallback to bsdtar, then 7z
if command -v xorriso > /dev/null 2>&1; then
	xorriso -osirrox on -indev "$ISO_FILENAME" -extract / "$ISO_DIR" 2> /dev/null
elif command -v bsdtar > /dev/null 2>&1; then
	bsdtar -C "$ISO_DIR" -xf "$ISO_FILENAME"
elif command -v 7z > /dev/null 2>&1; then
	7z x -o"$ISO_DIR" "$ISO_FILENAME" > /dev/null
else
	echo "Error: No ISO extraction tool found. Install xorriso, bsdtar, or p7zip."
	exit 1
fi

# Make extracted files writable
chmod -R u+w "$ISO_DIR"

# Copy preseed file to ISO root (fallback)
echo "Copying preseed file to ISO root..."
cp "$PRESEED_FILE" "$ISO_DIR/preseed.cfg"

# Copy late_command helper scripts to ISO root (accessible as /cdrom/ during install)
echo "Copying setup scripts to ISO root..."
for SCRIPT in b2b-setup.sh monitoring.sh first-boot-setup.sh; do
	if [ -f "preseeds/$SCRIPT" ]; then
		cp "preseeds/$SCRIPT" "$ISO_DIR/$SCRIPT"
		echo "  ✓ $SCRIPT"
	else
		echo "  ✗ WARNING: preseeds/$SCRIPT not found"
	fi
done

# AI_MODE has to travel INSIDE the ISO: first-boot-setup.sh runs from @reboot
# cron, which inherits nothing from this build. So the chosen mode is stamped
# into the copy of the script that ships, rather than passed as an environment
# variable that would silently be empty at boot.
AI_MODE="${AI_MODE:-off}"
case "$AI_MODE" in
	off | client | local) ;;
	*)
		echo "Error: AI_MODE must be off, client or local (got '$AI_MODE')" >&2
		exit 1
		;;
esac
if [ -f "$ISO_DIR/first-boot-setup.sh" ]; then
	sed -i "s|^B2B_AI_MODE=\"\${B2B_AI_MODE:-off}\"|B2B_AI_MODE=\"\${B2B_AI_MODE:-${AI_MODE}}\"|" \
		"$ISO_DIR/first-boot-setup.sh"
	echo "  ✓ AI_MODE=${AI_MODE} baked into first-boot-setup.sh"
fi

# Post-install provisioners. These are NOT run from the d-i chroot: both need a
# real network and working dpkg triggers (npm, pip, git clone), which is exactly
# what hangs in-target. late_command drops them in /root and first-boot-setup.sh
# runs them on the first real boot.
echo "Copying post-install provisioners to ISO root..."
for PROVISIONER in \
	setup/install/tools/install_global_scope.sh \
	setup/install/tools/install_devtools.sh \
	setup/install/ai/install_ai.sh \
	setup/install/nvim/install_nvim.sh \
	setup/install/nvim/install_nvim_extras.sh \
	setup/install/hellish/install_hellish_plugins.sh; do
	if [ -f "$PROVISIONER" ]; then
		cp "$PROVISIONER" "$ISO_DIR/$(basename "$PROVISIONER")"
		chmod 755 "$ISO_DIR/$(basename "$PROVISIONER")" || true
		echo "  ✓ $(basename "$PROVISIONER")"
	else
		echo "  ✗ WARNING: $PROVISIONER not found"
	fi
done

# Optional: bake a custom login shell into the ISO.
# Usage:
#   CUSTOM_SHELL_PATH=dist/hellish make gen_iso   (the default; see make shell)
# If not provided, the VM keeps the default /bin/bash.
CUSTOM_SHELL_PATH="${CUSTOM_SHELL_PATH:-}"
if [ -n "$CUSTOM_SHELL_PATH" ]; then
	echo "Copying custom shell to ISO root..."
	# If relative, resolve against repo root
	case "$CUSTOM_SHELL_PATH" in
		/*) : ;;
		*) CUSTOM_SHELL_PATH="${REPO_ROOT}/${CUSTOM_SHELL_PATH}" ;;
	esac
	if [ ! -f "$CUSTOM_SHELL_PATH" ]; then
		echo "Error: CUSTOM_SHELL_PATH points to a missing file: $CUSTOM_SHELL_PATH" >&2
		exit 1
	fi
	CUSTOM_SHELL_NAME="${CUSTOM_SHELL_NAME:-$(basename "$CUSTOM_SHELL_PATH")}"
	CUSTOM_SHELL_DEST="${CUSTOM_SHELL_DEST:-/usr/bin/$CUSTOM_SHELL_NAME}"

	cp "$CUSTOM_SHELL_PATH" "$ISO_DIR/custom_shell.bin"
	chmod 755 "$ISO_DIR/custom_shell.bin" || true
	printf '%s\n' "$CUSTOM_SHELL_DEST" > "$ISO_DIR/custom_shell.dest"
	printf '%s\n' "$CUSTOM_SHELL_NAME" > "$ISO_DIR/custom_shell.name"
	echo "  ✓ custom shell baked: $CUSTOM_SHELL_PATH"
	echo "    dest: $CUSTOM_SHELL_DEST"
	# Optional extra: upstream's own shell-registration helper, if a hellish
	# source tree happens to be checked out beside us. Not required — b2b-setup.sh
	# appends to /etc/shells and runs usermod itself — so its absence is normal
	# now that the sh42 submodule is gone.
	REGISTER_SCRIPT="hellish/vendor/scripts/register_shell.sh"
	if [ -f "$REGISTER_SCRIPT" ]; then
		cp "$REGISTER_SCRIPT" "$ISO_DIR/register_shell.sh"
		chmod 755 "$ISO_DIR/register_shell.sh" || true
		echo "  ✓ register_shell.sh"
	fi
else
	echo "ℹ CUSTOM_SHELL_PATH not set — keeping default shell (bash)"
fi

# Copy host's SSH public key into the ISO so b2b-setup.sh can install it
# This enables passwordless SSH from the host right after first boot
echo "Injecting host SSH public key..."
HOST_PUBKEY=""
for kf in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
	if [ -f "$kf" ]; then
		HOST_PUBKEY="$kf"
		break
	fi
done
if [ -n "$HOST_PUBKEY" ]; then
	cp "$HOST_PUBKEY" "$ISO_DIR/host_ssh_pubkey"
	echo "  ✓ Host SSH public key baked into ISO ($(basename "$HOST_PUBKEY"))"
else
	echo "  ℹ No host SSH key found — VM will use password auth only"
fi

# ── CRITICAL: Inject preseed.cfg into the initrd ────────────────────────────
# The Debian installer auto-loads preseed.cfg from the initrd root BEFORE
# the CD-ROM is mounted. This is the ONLY reliable way to preseed with
# preseed/file — the /cdrom path fails because the CD isn't mounted yet.
# Method: create a small cpio archive with preseed.cfg, gzip it, and
# append it to initrd.gz. The kernel processes concatenated cpio archives.
echo "Injecting preseed.cfg into initrd..."
INITRD="$ISO_DIR/install.amd/initrd.gz"
if [ -f "$INITRD" ]; then
	INITRD_ABS="$(cd "$(dirname "$INITRD")" && pwd)/$(basename "$INITRD")"
	INJECT_DIR=$(mktemp -d)
	cp "$PRESEED_FILE" "$INJECT_DIR/preseed.cfg"
	(cd "$INJECT_DIR" && echo preseed.cfg | cpio -o -H newc 2> /dev/null | gzip >> "$INITRD_ABS")
	rm -rf "$INJECT_DIR"
	echo "  ✓ preseed.cfg injected into install.amd/initrd.gz"
else
	echo "  ✗ WARNING: $INITRD not found — preseed injection skipped"
fi

# Also inject into GTK initrd if it exists
INITRD_GTK="$ISO_DIR/install.amd/gtk/initrd.gz"
if [ -f "$INITRD_GTK" ]; then
	INITRD_GTK_ABS="$(cd "$(dirname "$INITRD_GTK")" && pwd)/$(basename "$INITRD_GTK")"
	INJECT_DIR=$(mktemp -d)
	cp "$PRESEED_FILE" "$INJECT_DIR/preseed.cfg"
	(cd "$INJECT_DIR" && echo preseed.cfg | cpio -o -H newc 2> /dev/null | gzip >> "$INITRD_GTK_ABS")
	rm -rf "$INJECT_DIR"
	echo "  ✓ preseed.cfg injected into install.amd/gtk/initrd.gz"
fi

# Edit boot menu for BIOS (ISOLINUX)
# The default Debian ISO has: isolinux.cfg → menu.cfg → gtk.cfg + txt.cfg
# gtk.cfg sets "menu default" on Graphical Install, stealing the default.
# isolinux.cfg has "timeout 0" (wait forever). We must fix ALL of them.
echo "Updating BIOS boot menu (isolinux)..."

# 1. isolinux.cfg — set a 1-second timeout so it auto-boots
ISOLINUX_MAIN="$ISO_DIR/isolinux/isolinux.cfg"
if [ -f "$ISOLINUX_MAIN" ]; then
	# vesamenu.c32 draws nothing on a serial line, so the serial build bypasses
	# it and boots the txt.cfg entry directly. The VGA build keeps the menu
	# module, which is what the ISO that installs successfully here uses —
	# untested variations on the boot path are expensive to debug (a failure
	# costs a 20-minute install to notice).
	if [ "$SERIAL_CONSOLE" = "1" ]; then
		cat > "$ISOLINUX_MAIN" << 'EOF'
# D-I config version 2.0
path 
serial 0 115200
include menu.cfg
default install
prompt 0
timeout 10
EOF
		echo "  ✓ isolinux.cfg  → serial console, boots 'install' directly"
	else
		cat > "$ISOLINUX_MAIN" << 'EOF'
# D-I config version 2.0
path 
include menu.cfg
default vesamenu.c32
prompt 0
timeout 10
EOF
		echo "  ✓ isolinux.cfg  → timeout 10 (1s)"
	fi
fi

# 2. txt.cfg — our automated install entry (marked as menu default)
# Preseed is inside the initrd (auto-detected by d-i). No preseed/file= needed.
# locale/country/keymap on cmdline as belt-and-suspenders for pre-preseed Qs.
ISOLINUX_TXT="$ISO_DIR/isolinux/txt.cfg"
if [ -f "$ISOLINUX_TXT" ]; then
	cat > "$ISOLINUX_TXT" << EOF
default install
label install
    menu label ^Automated Install
    menu default
    kernel /install.amd/vmlinuz
    append ${DI_CMDLINE} initrd=/install.amd/initrd.gz ${DI_TAIL}
EOF
	echo "  ✓ txt.cfg       → Automated Install (default)"
fi

# 3. gtk.cfg — remove "menu default" from Graphical Install
ISOLINUX_GTK="$ISO_DIR/isolinux/gtk.cfg"
if [ -f "$ISOLINUX_GTK" ]; then
	cat > "$ISOLINUX_GTK" << 'EOF'
label installgui
    menu label ^Graphical install
    kernel /install.amd/vmlinuz
    append vga=788 initrd=/install.amd/gtk/initrd.gz --- quiet
EOF
	echo "  ✓ gtk.cfg       → removed menu default"
fi

echo "✓ BIOS boot menu updated"

# Edit boot menu for EFI (GRUB)
echo "Updating EFI boot menu (GRUB)..."
GRUB_CFG="$ISO_DIR/boot/grub/grub.cfg"
if [ -f "$GRUB_CFG" ]; then
	# Backup original
	cp "$GRUB_CFG" "$GRUB_CFG.bak"

	# Create new GRUB config with auto-install as default
	GRUB_SERIAL=""
	if [ "$SERIAL_CONSOLE" = "1" ]; then
		GRUB_SERIAL="serial --unit=0 --speed=115200
terminal_input serial console
terminal_output serial console"
	fi
	cat > "$GRUB_CFG" << GRUBEOF
${GRUB_SERIAL}
set default=0
set timeout=1

menuentry 'Automated Install' {
    set background_color=black
    linux    /install.amd/vmlinuz ${DI_CMDLINE} ${DI_TAIL}
    initrd   /install.amd/initrd.gz
}

menuentry 'Install' {
    set background_color=black
    linux    /install.amd/vmlinuz ${CONSOLE_ARGS} ---
    initrd   /install.amd/initrd.gz
}
GRUBEOF

	echo "✓ EFI boot menu updated"
else
	echo "Warning: $GRUB_CFG not found"
fi

# Update MD5 sums
echo "Updating MD5 checksums..."
cd "$ISO_DIR"
find . -type f ! -name md5sum.txt ! -path './isolinux/*' -exec md5sum {} + > md5sum.txt 2> /dev/null || true
cd ..

# Rebuild ISO
echo "Rebuilding ISO with xorriso..."
if ! command -v xorriso > /dev/null 2>&1; then
	echo "Error: xorriso is required to rebuild the ISO."
	echo "Install it with:"
	echo "  Debian/Ubuntu: sudo apt-get install -y xorriso"
	echo "  Fedora:        sudo dnf install -y xorriso"
	echo "  Arch:          sudo pacman -Sy xorriso"
	exit 1
fi
cd "$ISO_DIR"
xorriso -as mkisofs \
	-o "../$OUTPUT_ISO" \
	-c isolinux/boot.cat \
	-b isolinux/isolinux.bin \
	-no-emul-boot -boot-load-size 4 -boot-info-table \
	-eltorito-alt-boot \
	-e boot/grub/efi.img \
	-no-emul-boot \
	-isohybrid-gpt-basdat \
	-r -J \
	. || {
	echo "Error: Failed to create ISO"
	exit 1
}
cd ..

echo "===== Success ====="
echo "✓ Custom ISO created: $OUTPUT_ISO"
echo "Use this ISO with your VirtualBox VM for automated Debian installation"

# Cleanup
rm -rf "$ISO_DIR"
echo "✓ Temporary files cleaned up"
