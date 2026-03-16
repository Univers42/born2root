#!/bin/bash

set -e # Exit on any error

# Always run relative to repo root (so paths like preseeds/... and sh42/... work
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

# Create extraction directory
echo "Extracting ISO to $ISO_DIR..."
chmod -R u+w "$ISO_DIR" 2> /dev/null || true
rm -rf "$ISO_DIR"
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

# Optional: bake a custom login shell into the ISO.
# Usage:
#   CUSTOM_SHELL_PATH=sh42/build/bin/hellish make gen_iso
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
	# Optional: include the register script for parity with your Makefile
	REGISTER_SCRIPT="sh42/vendor/scripts/register_shell.sh"
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

# 2. txt.cfg — our automated install entry (marked as menu default)
# Preseed is inside the initrd (auto-detected by d-i). No preseed/file= needed.
# locale/country/keymap on cmdline as belt-and-suspenders for pre-preseed Qs.
ISOLINUX_TXT="$ISO_DIR/isolinux/txt.cfg"
if [ -f "$ISOLINUX_TXT" ]; then
	cat > "$ISOLINUX_TXT" << 'EOF'
default install
label install
    menu label ^Automated Install
    menu default
    kernel /install.amd/vmlinuz
    append auto=true priority=critical DEBIAN_FRONTEND=noninteractive locale=en_US.UTF-8 language=en country=ES keymap=es hostname=dlesieur domain= vga=788 initrd=/install.amd/initrd.gz --- quiet
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
	cat > "$GRUB_CFG" << 'GRUBEOF'
set default=0
set timeout=1

menuentry 'Automated Install' {
    set background_color=black
    linux    /install.amd/vmlinuz auto=true priority=critical DEBIAN_FRONTEND=noninteractive locale=en_US.UTF-8 language=en country=ES keymap=es hostname=dlesieur domain= vga=788 --- quiet
    initrd   /install.amd/initrd.gz
}

menuentry 'Install' {
    set background_color=black
    linux    /install.amd/vmlinuz vga=788 --- quiet
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
