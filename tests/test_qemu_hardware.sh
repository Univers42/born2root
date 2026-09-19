#!/usr/bin/env hellish
# Regression test for the guest's virtual hardware in setup/host/qemu_vm.sh.
#
# The bugs it guards, in order of how much they cost when they regress:
#
#   1. The guest's NIC is named `ens4` -- /etc/network/interfaces says so --
#      because the e1000 happened to land on PCI slot 4. Predictable interface
#      names are derived from the slot, so a virtio-net-pci emitted WITHOUT
#      addr=0x4 boots a guest whose interface has a different name and whose
#      DHCP stanza therefore never runs: a VM that is up, unreachable, and
#      gives no clue why. Nothing else in the tree pins that slot.
#
#   2. partman's recipe in preseed.cfg.in addresses the disk as /dev/sda. That
#      is why the controller was an emulated ich9-ahci for so long. virtio-scsi
#      keeps the name (it goes through the SCSI subsystem) where virtio-blk
#      would silently produce /dev/vda and fail the install 20 minutes in, so
#      a well-meaning switch to virtio-blk-pci must not pass.
#
#   3. discard=unmap and detect-zeroes=unmap are what make `make slim` and the
#      guest's fstrim.timer actually return space. They were easy to drop while
#      rewriting the -drive line.
#
#   4. In legacy mode one ich9-ahci serves both the hard disk (ahci.0) and the
#      installer CD (ahci.1). Declaring the controller in both places is a
#      duplicate id and QEMU refuses to start -- which would break the one
#      escape hatch that exists for a guest that will not boot on virtio.
#
# qemu-system-x86_64 need not be installed: qemu_vm.sh's BASH_SOURCE guard
# skips its checks and action dispatch when sourced, and QEMU itself is
# replaced below by a recorder that only writes its arguments down.
set -e

cd "$(dirname "$0")/.."

fail=0
check_has() {
    if printf '%s' "$2" | grep -qF -- "$3"; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s -- expected to find: %s\n' "$1" "$3"
        fail=1
    fi
}
check_lacks() {
    if printf '%s' "$2" | grep -qF -- "$3"; then
        printf 'FAIL %s -- should NOT contain: %s\n' "$1" "$3"
        fail=1
    else
        printf 'ok   %s\n' "$1"
    fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export B2B_CONFIG=tests/fixtures/default.toml
VM_NAME=debian
VM_PATH="$TMP"
PORTS_SPEC="ssh:4242:4242"
export VM_NAME VM_PATH PORTS_SPEC

# launch() calls ensure_vm_dir, which records the VM's location in
# disk_images/.vm_path.<name> -- and VM_NAME here is the real "debian". Without
# this the test repointed the developer's own registry at $TMP, so the next
# `make qemu_start` reported "nothing is installed at /tmp/tmp.XXXXXX/debian"
# with the 31 GB qcow2 sitting untouched in disk_images/. See utils/vm_path.sh.
export VM_PATH_REGISTRY="$TMP/registry"

. ./setup/host/qemu_vm.sh

# TCG, so launch() skips the KVM availability check and emits no -cpu host.
ACCEL=tcg

mkdir -p "$VM_DIR"
: >"$DISK"

# A QEMU that starts nothing and records everything.
QEMU="$TMP/fake-qemu"
cat >"$QEMU" <<'RECEOF'
#!/bin/sh
printf '%s\n' "$@" >"$(dirname "$0")/cmdline"
RECEOF
chmod +x "$QEMU"

# shellcheck disable=SC2329,SC2317
is_host_port_free() { return 0; }
# shellcheck disable=SC2329,SC2317
is_running() { return 0; }
# shellcheck disable=SC2329,SC2317
find_iso() { printf '%s' "$TMP/fake.iso"; }
: >"$TMP/fake.iso"
# shellcheck disable=SC2329,SC2317
info() { :; }
# shellcheck disable=SC2329,SC2317
ok() { :; }

run_launch() {
    rm -f "$TMP/cmdline"
    launch "$1" >/dev/null 2>&1 || true
    tr '\n' ' ' <"$TMP/cmdline"
}

printf '\n-- default hardware, booting from disk --\n'
line=$(run_launch disk)
check_has "disk is on virtio-scsi" "$line" "virtio-scsi-pci"
check_has "disk attaches as a SCSI disk" "$line" "scsi-hd,drive=hd0"
check_lacks "no emulated IDE disk" "$line" "ide-hd"
check_lacks "no virtio-blk (/dev/vda breaks partman)" "$line" "virtio-blk"
check_has "NIC is virtio-net pinned to slot 4" "$line" "virtio-net-pci,netdev=net0,addr=0x4"
check_lacks "no e1000" "$line" "e1000"
check_has "discard=unmap survives" "$line" "discard=unmap"
check_has "detect-zeroes=unmap survives" "$line" "detect-zeroes=unmap"
check_has "balloon reports free pages back" "$line" "free-page-reporting=on"
check_has "block I/O has its own iothread" "$line" "iothread=iothread0"
check_has "SMP topology is one socket" "$line" "sockets=1"
check_lacks "no SATA controller without a CD" "$line" "ich9-ahci"

printf '\n-- default hardware, booting the installer --\n'
line=$(run_launch cdrom)
check_has "disk stays on virtio-scsi" "$line" "virtio-scsi-pci"
check_has "CD still gets a SATA controller" "$line" "ich9-ahci"
check_has "that controller avoids the pinned slots" "$line" "ich9-ahci,id=ahci,addr=0x5"
check_has "CD hangs off it" "$line" "ide-cd,drive=cd0,bus=ahci.1"
check_has "NIC pin holds during install too" "$line" "virtio-net-pci,netdev=net0,addr=0x4"

printf '\n-- B2B_QEMU_LEGACY_HW=1, the rollback path --\n'
B2B_QEMU_LEGACY_HW=1
line=$(run_launch disk)
check_has "AHCI controller is back" "$line" "ich9-ahci,id=ahci"
check_has "disk is an IDE disk again" "$line" "ide-hd,drive=hd0,bus=ahci.0"
check_has "e1000 is back" "$line" "e1000,netdev=net0"
check_lacks "no virtio-scsi" "$line" "virtio-scsi"
check_lacks "no virtio-net" "$line" "virtio-net"
check_lacks "no io_uring on the legacy drive" "$line" "aio=io_uring"

printf '\n-- legacy mode with the installer: one controller, not two --\n'
line=$(run_launch cdrom)
n=$(printf '%s' "$line" | grep -o "ich9-ahci" | grep -c .)
if [ "$n" = "1" ]; then
    printf 'ok   exactly one ich9-ahci is declared\n'
else
    printf 'FAIL %s ich9-ahci declarations (expected 1 -- a duplicate id refuses to start)\n' "$n"
    fail=1
fi
check_has "CD and disk share it" "$line" "ide-cd,drive=cd0,bus=ahci.1"

printf '\n'
[ "$fail" = 0 ] && printf 'all ok\n'
exit "$fail"
