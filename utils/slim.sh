#!/usr/bin/env hellish
# Give back the space this project is no longer using.
#
# Three distinct kinds of waste accumulate here, and they need three different
# tools -- which is why "just delete some stuff" was never a workable answer:
#
#   1. The ISOs. 1.7 GB of installer that has already done its job. They are
#      rebuildable from the network, and the build already knows how.
#   2. Whatever the guest has freed but never handed back: apt archives, old
#      kernels, deleted Docker layers. Only the guest can see these.
#   3. Clusters the qcow2 still holds for blocks nothing references. Only the
#      host can reclaim these, and ONLY if the guest trimmed first.
#
# The order matters and is not interchangeable. Trimming before cleaning trims
# blocks that are about to be freed anyway; compacting before trimming compacts
# an image that still thinks every stale block is live. So: clean, then trim,
# then compact.
#
#   utils/slim.sh              clean + trim the guest, drop used ISOs
#   utils/slim.sh --compact    also compact the image (requires a stopped VM)
#
# Env
#   VM_NAME (debian)  VM_PATH  VM_USER (dlesieur)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
QEMU_VM="$REPO_ROOT/setup/host/qemu_vm.sh"

VM_NAME="${VM_NAME:-debian}"
VM_PATH="${VM_PATH:-$REPO_ROOT/disk_images}"
VM_DIR="$VM_PATH/$VM_NAME"
DISK="$VM_DIR/$VM_NAME.qcow2"
PIDFILE="$VM_DIR/qemu.pid"
COMPACT=0
[ "${1:-}" = "--compact" ] && COMPACT=1

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	GRN=$'\033[32m' YLW=$'\033[33m' BLU=$'\033[34m' BLD=$'\033[1m' DIM=$'\033[2m' OFF=$'\033[0m'
else
	GRN='' YLW='' BLU='' BLD='' DIM='' OFF=''
fi
phase() { printf "\n${BLU}▶${OFF} ${BLD}%s${OFF}\n" "$*"; }
ok()    { printf "  ${GRN}✓${OFF} %s\n" "$*"; }
skip()  { printf "  ${DIM}·${OFF} %s\n" "$*"; }
warn()  { printf "  ${YLW}!${OFF} %s\n" "$*"; }

disk_kb() { [ -f "$DISK" ] && du -sk "$DISK" 2> /dev/null | awk '{print $1}' || printf '0'; }
human()   { awk -v k="$1" 'BEGIN { printf (k >= 1048576) ? "%.1f GB" : "%.0f MB", (k >= 1048576) ? k/1048576 : k/1024 }'; }

vm_running() { [ -f "$PIDFILE" ] && [ -d "/proc/$(head -n1 "$PIDFILE" 2> /dev/null)" ]; }

BEFORE_KB=$(disk_kb)

# ── 1. The ISOs ─────────────────────────────────────────────────────────────
# Only once the VM is actually installed. Deleting the installer out from under
# a half-finished install would cost a full rebuild to save 1.7 GB.
phase "Installer ISOs"
if [ ! -f "$VM_DIR/.installed" ]; then
	skip "VM not installed yet — keeping the ISOs (they are the installer)"
else
	freed=0
	for iso in "$REPO_ROOT"/debian-*.iso; do
		[ -e "$iso" ] || continue
		# Never delete an ISO a running guest still has attached: QEMU holds the
		# open file, so the space would not come back until it exits, and the
		# guest would lose its CD mid-flight.
		if vm_running && grep -qa -- "$(basename "$iso")" "/proc/$(head -n1 "$PIDFILE")/cmdline" 2> /dev/null; then
			skip "$(basename "$iso") — still attached to the running VM"
			continue
		fi
		freed=$((freed + $(du -sk "$iso" | awk '{print $1}')))
		rm -f -- "$iso"
		ok "removed $(basename "$iso")"
	done
	if [ "$freed" -gt 0 ]; then
		ok "$(human "$freed") reclaimed — rebuild with ${BLD}make gen_iso${OFF}"
	else
		skip "no ISOs to remove"
	fi
fi

# ── 2. Inside the guest ─────────────────────────────────────────────────────
phase "Guest cleanup"
if ! vm_running; then
	skip "VM is not running — start it (make qemu_start) to clean and trim inside"
else
	# apt's archive cache and orphaned packages first, so the trim that follows
	# covers the blocks they just released.
	if VM_NAME="$VM_NAME" VM_PATH="$VM_PATH" "${SCRIPT_SH:-bash}" "$QEMU_VM" ssh \
		"sudo apt-get clean && sudo apt-get -y autoremove --purge" 2>&1 | sed 's/^/    /'; then
		ok "apt cache cleaned, orphaned packages purged"
	else
		warn "apt cleanup failed — is the guest reachable? (make qemu_ssh)"
	fi

	# The payoff. If the discard chain is wired (see preseeds/b2b-setup.sh),
	# this is what actually shrinks the file on the host; if it is not, fstrim
	# reports 0 B and the reason is worth saying out loud rather than leaving
	# someone to wonder why a "successful" slim freed nothing.
	trim_out=$(VM_NAME="$VM_NAME" VM_PATH="$VM_PATH" "${SCRIPT_SH:-bash}" "$QEMU_VM" ssh \
		"sudo fstrim -av" 2>&1)
	printf '%s\n' "$trim_out" | sed 's/^/    /'
	if printf '%s' "$trim_out" | grep -qE '[1-9][0-9]* bytes|[0-9.]+ [KMG]i?B'; then
		ok "guest trimmed"
	else
		warn "fstrim reported nothing. If this VM predates the discard fix, its"
		warn "crypttab has no 'discard' — check with: sudo dmsetup table | grep allow_discards"
	fi
fi

# ── 3. Compact the image ────────────────────────────────────────────────────
phase "Image compaction"
if [ "$COMPACT" != 1 ]; then
	skip "skipped — pass ${BLD}--compact${OFF} (needs the VM stopped)"
elif vm_running; then
	warn "VM is running. Compaction rewrites the image and would corrupt it."
	warn "Stop it first:  make qemu_stop"
elif [ ! -f "$DISK" ]; then
	skip "no disk at $DISK"
else
	# A copy, not an in-place rewrite: if this dies halfway the original is
	# still intact. Costs the image's size in scratch space for the duration.
	tmp="$DISK.compact.$$"
	if qemu-img convert -O qcow2 "$DISK" "$tmp" 2>&1 | sed 's/^/    /'; then
		mv -f "$tmp" "$DISK"
		ok "image rewritten without its unreferenced clusters"
	else
		rm -f "$tmp"
		warn "qemu-img convert failed — original left untouched"
	fi
fi

# ── Result ──────────────────────────────────────────────────────────────────
AFTER_KB=$(disk_kb)
if [ "$BEFORE_KB" -gt 0 ] && [ "$AFTER_KB" -lt "$BEFORE_KB" ]; then
	printf "\n  ${GRN}✓${OFF} VM disk %s → %s\n" "$(human "$BEFORE_KB")" "$(human "$AFTER_KB")"
elif [ "$BEFORE_KB" -gt 0 ]; then
	printf "\n  ${DIM}·${OFF} VM disk unchanged at %s\n" "$(human "$AFTER_KB")"
fi

SPACE_BUDGET_GB="${SPACE_BUDGET_GB:-15}" VM_NAME="$VM_NAME" VM_PATH="$VM_PATH" \
	"${SCRIPT_SH:-bash}" "$HERE/space_budget.sh" --report
