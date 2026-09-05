#!/usr/bin/env bash
# ============================================================================ #
#  qemu_pipeline.sh — `make all`, on the QEMU/KVM backend                      #
# ============================================================================ #
#
# The same five phases orchestrate.sh drives for VirtualBox, in the same order
# and with the same meaning, but executed by QEMU:
#
#   1. ISO        build the preseeded ISO            (identical: make gen_iso)
#   2. Disk       create the qcow2                   (VirtualBox: a VDI)
#   3. Install    boot the ISO, unattended install   (identical guest, ~20 min)
#   4. First boot boot from disk and unlock LUKS     (monitor sendkey)
#   5. Host       ~/.ssh/config, then wait for sshd
#
# Nothing about the GUEST differs. The ISO is byte-for-byte the one the
# VirtualBox path uses, so the preseed, the LUKS+LVM recipe, b2b-setup.sh,
# first-boot-setup.sh and the upstream hellish install all run exactly as they
# would there.
# ============================================================================ #

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
QEMU_VM="$HERE/qemu_vm.sh"

VM_NAME="${VM_NAME:-debian}"
MAKE_BIN="${MAKE_BIN:-make}"

C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_GREEN=$'\033[32m'
C_BLUE=$'\033[34m'
C_RED=$'\033[31m'
C_DIM=$'\033[2m'
if [ ! -t 1 ] || [ -n "${NO_COLOR:-}" ]; then
    C_RESET=''
    C_BOLD=''
    C_GREEN=''
    C_BLUE=''
    C_RED=''
    C_DIM=''
fi
phase() { printf "\n${C_BLUE}▶${C_RESET} ${C_BOLD}%s${C_RESET}\n" "$*"; }
ok() { printf "  ${C_GREEN}✓${C_RESET} %s\n" "$*"; }
die() {
    printf "\n  ${C_RED}✗${C_RESET} %s\n\n" "$*" >&2
    exit 1
}

cd "$REPO_ROOT" || die "cannot enter $REPO_ROOT"

printf "\n${C_BOLD}Born2beRoot — QEMU/KVM build${C_RESET} ${C_DIM}(guest identical to the VirtualBox path)${C_RESET}\n"

# ── 1. ISO ──────────────────────────────────────────────────────────────────
phase "Preseeded ISO"
if ls -1t debian-*-amd64-*preseed.iso >/dev/null 2>&1 && [ "${FORCE_ISO:-0}" != "1" ]; then
    ok "reusing $(ls -1t debian-*-amd64-*preseed.iso | head -1)"
else
    CUSTOM_SHELL_PATH="${CUSTOM_SHELL_PATH:-}" AI_MODE="${AI_MODE:-off}" FORCE_ISO=1 \
        $MAKE_BIN --no-print-directory gen_iso || die "ISO build failed"
    ok "ISO built"
fi

# ── 2. Disk ─────────────────────────────────────────────────────────────────
phase "Virtual disk"
bash "$QEMU_VM" create || die "disk creation failed"

# ── 3. Install ──────────────────────────────────────────────────────────────
# Whether the disk holds a system is RECORDED by qemu_vm.sh, not guessed:
#   .installed   B2B-INSTALL-COMPLETE arrived and the VM powered off
#   .phase       "installing" from the moment d-i is booted until then
# Size alone lied here once: a qcow2 passes 1 GB minutes into an install, and
# this step then called a half-installed disk "installed" and went on to type
# a LUKS passphrase at the still-running installer. Disks from before the
# stamp existed have only their size as evidence, and that is said out loud.
phase "Debian install (unattended)"
VM_DIR="${VM_PATH:-$REPO_ROOT/disk_images}/$VM_NAME"
DISK="$VM_DIR/$VM_NAME.qcow2"
disk_bytes=$(stat -c %s "$DISK" 2>/dev/null || echo 0)
phase_now=$(cat "$VM_DIR/.phase" 2>/dev/null || true)
qemu_pid=$(head -n1 "$VM_DIR/qemu.pid" 2>/dev/null || true)
[ -n "$qemu_pid" ] && kill -0 "$qemu_pid" 2>/dev/null || qemu_pid=""
if [ -n "$qemu_pid" ] && [ "$phase_now" = installing ]; then
    printf "  ${C_RED}✗${C_RESET} an install is already running in this VM (pid %s)\n" "$qemu_pid"
    printf "    ${C_DIM}re-attach to it:  make qemu_watch        stop it:  make qemu_stop${C_RESET}\n"
    exit 1
elif [ -f "$VM_DIR/.installed" ] && [ "${FORCE_INSTALL:-0}" != "1" ]; then
    ok "disk already holds an installed system (finished $(cat "$VM_DIR/.installed")) — skipping"
    ok "force a reinstall with: FORCE_INSTALL=1, or delete $DISK"
elif [ "$disk_bytes" -gt 1073741824 ] && [ -z "$phase_now" ] && [ "${FORCE_INSTALL:-0}" != "1" ]; then
    ok "disk holds $(du -h "$DISK" | cut -f1) but no .installed stamp (built before stamps existed) — treating it as installed"
    ok "force a reinstall with: FORCE_INSTALL=1, or delete $DISK"
else
    [ "$phase_now" = installing ] &&
        printf "  ${C_DIM}a previous install was interrupted — starting over (the installer reformats the disk)${C_RESET}\n"
    printf "  ${C_DIM}~20 minutes. The tracker below reads the installer's own log; Ctrl+C\n"
    printf "  detaches, make qemu_watch re-attaches, make qemu_console shows every line.${C_RESET}\n"
    bash "$QEMU_VM" install || die "the install phase failed"
fi

# ── 4. First boot + LUKS ────────────────────────────────────────────────────
phase "First boot"
bash "$QEMU_VM" start || die "the VM did not come up"

# ── 5. Host wiring ──────────────────────────────────────────────────────────
phase "Host configuration"
bash "$QEMU_VM" ssh-config || die "could not write ~/.ssh/config"

if timeout 20 ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 \
    b2b 'echo ok' >/dev/null 2>&1; then
    ok "ssh b2b works: $(ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR b2b 'hostname' 2>/dev/null)"
else
    printf "  ${C_DIM}ssh b2b is not answering yet — first boot installs Docker and\n"
    printf "  WordPress, which takes a few minutes. Watch: make qemu_console${C_RESET}\n"
fi

printf "\n${C_GREEN}${C_BOLD}  QEMU build finished.${C_RESET}\n\n"
printf "    ssh b2b                 log in\n"
printf "    make qemu_console       the serial console\n"
printf "    make qemu_status        pid, ports, disk\n"
printf "    make qemu_stop          shut it down\n"
printf "    make inception          deploy the site inside it\n\n"
