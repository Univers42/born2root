#!/usr/bin/env hellish
# Guest RAM and cores larger than the host fall back to "auto" on both
# backends instead of stopping the build.
#
# THE FAILURE IT PINS
#   born2root.toml is tracked and carries the 30.5 GB, 16-core seat's
#   ram_mb = 20480 and cpus = 12. On a 7119 MB, 8-thread laptop
#   (2026-10-28) qemu_vm.sh's vm_sizing exited with "VM_RAM_MB=20480 exceeds
#   the host's 7119 MB" after the ISO had been built, and VirtualBox's
#   auto_size_vm only warned and handed the guest 20 GB anyway. Both now give
#   that machine the automatic share; a number the host can hold is still
#   taken as is, and a non-number is still refused by QEMU.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-52s = %s\n' "$1" "$2"
    else
        printf 'FAIL %-52s = %s (want %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}

# A function from its "name() {" line to the first "}" in column 0.
cut_fn() {
    awk -v start="^$2\\\\(\\\\) \\\\{" '$0 ~ start {on=1} on {print} on && /^}/ {exit}' "$1"
}
QEMU_FN=$(cut_fn "$REPO_ROOT/setup/host/qemu_vm.sh" vm_sizing)
VBOX_FN=$(cut_fn "$REPO_ROOT/setup/install/vms/install_vm_debian.sh" auto_size_vm)
[ -n "$QEMU_FN" ] || check "vm_sizing cut out of qemu_vm.sh" missing found
[ -n "$VBOX_FN" ] || check "auto_size_vm cut out of install_vm_debian.sh" missing found

# This host's RAM (both functions read /proc/meminfo) and the share "auto"
# gives it; nproc is stubbed to 8, so "auto" cores are 4.
HOST_MB=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
AUTO_MB=$((HOST_MB / 4))
[ "$AUTO_MB" -lt 2048 ] && AUTO_MB=2048
[ "$AUTO_MB" -gt 8192 ] && AUTO_MB=8192

# qemu RAM CPUS -> "VM_RAM_MB VM_CPUS", or "exit N" when vm_sizing exits.
# nproc is a stub the eval'd function calls, and the two variables are its
# inputs: shellcheck cannot see through the eval.
# shellcheck disable=SC2317,SC2034
qemu() {
    (
        nproc() { echo 8; }
        eval "$QEMU_FN"
        VM_RAM_MB=$1 B2B_VM_CPUS=$2
        vm_sizing 2>/dev/null
        echo "$VM_RAM_MB $VM_CPUS"
    ) || echo "exit $?"
}
# shellcheck disable=SC2317,SC2034
vbox() {
    (
        nproc() { echo 8; }
        eval "$VBOX_FN"
        VM_RAM_MB=$1 B2B_VM_CPUS=$2
        auto_size_vm >/dev/null 2>&1
        echo "$VM_MEMORY $VM_CPUS"
    )
}

check "qemu: more RAM and cores than the host" "$(qemu $((HOST_MB + 1024)) 12)" "$AUTO_MB 4"
check "qemu: a size the host holds is kept" "$(qemu 1024 6)" "1024 6"
check "qemu: empty is auto" "$(qemu '' '')" "$AUTO_MB 4"
check "qemu: a non-number is still refused" "$(qemu lots '')" "exit 1"
check "vbox: more RAM and cores than the host" "$(vbox $((HOST_MB + 1024)) 12)" "$AUTO_MB 4"
check "vbox: a size the host holds is kept" "$(vbox 1024 6)" "1024 6"

exit "$fail"
