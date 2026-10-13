#!/usr/bin/env hellish
# Regression test for the offline disk verbs of setup/host/qemu_vm.sh.
#
# grow-disk resizes the root qcow2 of a STOPPED guest. What it must never do:
#   - touch an image QEMU is running from (a live resize hands the kernel a
#     disk larger than its partition table without the guest asking);
#   - "grow" to a size that is not larger, which qemu-img would turn into a
#     shrink (with --shrink) or an error after the check already ran;
#   - resize an image qemu-img check does not call clean.
#
# Real qemu-img on a scratch image when it is installed, `skip` otherwise.
# is_running is the seam for "the guest is up"; a qemu-img wrapper on PATH
# fakes a failing check while every other subcommand runs for real.
set -e

cd "$(dirname "$0")/.."

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-52s = %s\n' "$1" "$2"
    else
        printf 'FAIL %-52s = %s (expected %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export B2B_CONFIG=tests/fixtures/default.toml
VM_NAME=debian
VM_PATH="$TMP"
PORTS_SPEC="ssh:4242:4242"
# VM_NAME is the real "debian": nothing here may repoint the developer's
# disk_images/.vm_path.debian at $TMP (see tests/test_qemu_hardware.sh).
export VM_NAME VM_PATH PORTS_SPEC VM_PATH_REGISTRY="$TMP/registry"

. ./setup/host/qemu_vm.sh
mkdir -p "$VM_DIR"

REAL_QEMU_IMG=$(command -v qemu-img || true)
if [ -z "$REAL_QEMU_IMG" ]; then
    printf 'skip qemu-img is not installed\n'
    exit 0
fi
virtual_gib() { qcow2_virtual_bytes "$1" | awk '{ print $1 / 1073741824 }'; }
rc_of() { ("$@") >"$TMP/out" 2>&1 && echo 0 || echo $?; }

# ── grow-disk ───────────────────────────────────────────────────────────────
qemu-img create -q -f qcow2 "$DISK" 1G

# shellcheck disable=SC2329,SC2317 # called by grow_disk
is_running() { return 0; }
check "running: refused" "$(rc_of grow_disk 2)" 1
check "running: the message says stop it first" "$(grep -c 'stop it first' "$TMP/out")" 1
check "running: image untouched" "$(virtual_gib "$DISK")" 1

# shellcheck disable=SC2329,SC2317
is_running() { return 1; }
check "not a number: refused" "$(rc_of grow_disk 2G)" 1
check "the same size: refused" "$(rc_of grow_disk 1)" 1
check "the same size: names the current size" "$(grep -c 'not larger than the current 1 GiB' "$TMP/out")" 1
check "the same size: image untouched" "$(virtual_gib "$DISK")" 1

mkdir -p "$TMP/bin"
cat >"$TMP/bin/qemu-img" <<EOF
#!/bin/sh
case "\$1" in
check) echo "fake: 1 errors were found on the image"; exit 2 ;;
esac
exec "$REAL_QEMU_IMG" "\$@"
EOF
chmod +x "$TMP/bin/qemu-img"
check "a dirty check: refused" "$(PATH="$TMP/bin:$PATH" rc_of grow_disk 2)" 1
check "a dirty check: image untouched" "$(virtual_gib "$DISK")" 1

check "stopped, larger, clean: resized (0)" "$(rc_of grow_disk 2)" 0
check "stopped, larger, clean: 2 GiB virtual" "$(virtual_gib "$DISK")" 2

printf '\n'
[ "$fail" = 0 ] && printf 'all ok\n'
exit "$fail"
