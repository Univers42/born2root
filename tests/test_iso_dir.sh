#!/usr/bin/env hellish
# The installer ISOs live beside the VM disks ($VM_PATH/iso), never in the
# source tree.
#
# THE FAILURE IT PINS
#   The netinst, its extraction and the preseeded image were written to the
#   repo root whatever VM_PATH said: the server VM built on /mnt/storage on
#   2026-10-07 still left 1.8 GB of ISOs in the source tree on the quota'd
#   /home. iso_dir (utils/vm_path.sh) is now the one answer, and every reader
#   asks it; this refuses a repo-root lookup coming back, and checks that an
#   ISO beside the VM is billed as an ISO, not as source.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-52s = %s\n' "$1" "$2"
    else
        printf 'FAIL %-52s = %s (want %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}

# iso_dir in a fresh shell with exactly the given environment.
iso_dir_with() {
    # shellcheck disable=SC2016 # $1 is the child shell's, expanded there
    env -u VM_PATH -u B2B_ISO_DIR "$@" "${SCRIPT_SH:-bash}" -c '. "$1/utils/vm_path.sh"; iso_dir' _ "$REPO_ROOT"
}
check "VM_PATH decides" "$(iso_dir_with VM_PATH=/mnt/x)" /mnt/x/iso
check "B2B_ISO_DIR wins" "$(iso_dir_with VM_PATH=/mnt/x B2B_ISO_DIR=/y)" /y
check "no VM_PATH: the Makefile's default" "$(iso_dir_with)" "$REPO_ROOT/disk_images/iso"

# The scripts a build runs, not the historical root-level ones.
check "no script looks for an ISO in the repo root" "$(grep -nE "find (\"\\\$REPO_ROOT\"|\\.) -maxdepth 1 .*\\.iso" \
    "$REPO_ROOT"/generate/*.sh "$REPO_ROOT"/setup/host/*.sh "$REPO_ROOT"/setup/install/vms/*.sh \
    "$REPO_ROOT"/utils/*.sh | grep -c .)" 0

# space_budget.sh, copied into an empty repo: the real one may hold ISOs
# from builds before iso_dir, which the legacy sweep counts too.
mkdir -p "$TMP/repo/utils" "$TMP/repo/disk_images" "$TMP/vms/iso"
cp "$REPO_ROOT/utils/space_budget.sh" "$REPO_ROOT/utils/vm_path.sh" "$TMP/repo/utils/"
report() { # VM_PATH
    NO_COLOR=1 SPACE_BUDGET_GB=1000 VM_NAME=t VM_PATH="$1" \
        "${SCRIPT_SH:-bash}" "$TMP/repo/utils/space_budget.sh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
}
row() { printf '%s\n' "$1" | awk -v r="$2" 'index($0, "    " r " ") == 1 { print $(NF - 1), $NF; exit }'; }
isos() { printf '%s\n' "$1" | awk '/^    ISOs / { print $2, $3; exit }'; }
src() { row "$1" 'source, git, nested repos'; }

before=$(src "$(report "$TMP/vms")")
fallocate -l 8M "$TMP/vms/iso/debian-13.7.0-amd64-netinst.iso"
out=$(report "$TMP/vms")
check "VM_PATH outside: the ISO is billed as an ISO" "$(isos "$out")" "8 MB"
check "... and not taken off the source tree" "$(src "$out")" "$before"

mkdir -p "$TMP/repo/disk_images/iso"
fallocate -l 8M "$TMP/repo/disk_images/iso/debian-13.7.0-amd64-netinst.iso"
out=$(report "$TMP/repo/disk_images")
check "default VM_PATH: billed as an ISO" "$(isos "$out")" "8 MB"
check "... not as a leftover VM disk" "$(printf '%s\n' "$out" | grep -c 'other VM disks')" 0
check "... and not as source" "$(src "$out")" "$before"

rm -rf "$TMP/repo/disk_images/iso"
fallocate -l 8M "$TMP/repo/debian-13.7.0-amd64-netinst.iso"
out=$(report "$TMP/vms")
check "an ISO left in the repo root by an older build counts" "$(isos "$out")" "16 MB"
check "... and is not billed as source either" "$(src "$out")" "$before"

exit "$fail"
