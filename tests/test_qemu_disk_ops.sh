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
# This test deletes VM_DIR: it must be the scratch one, never disk_images/.
case "$VM_DIR" in "$TMP"/?*) ;; *) exit 1 ;; esac
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

# ── ide-disk-create ─────────────────────────────────────────────────────────
# Refused with no size configured, while the guest runs, and over an existing
# file: once install_ide_disk.sh has run, that file is an encrypted docker
# data-root, and qemu-img create would replace it with an empty one.
IDE="$VM_DIR/$VM_NAME-ide.qcow2"
exists() { if [ -e "$1" ]; then echo yes; else echo no; fi; }
check "the IDE disk sits next to the root disk" "$IDE_DISK" "$IDE"
export B2B_VM_IDE_DISK_GB=0
check "key 0: refused" "$(rc_of ide_disk_create)" 1
check "key 0: nothing created" "$(exists "$IDE")" no
B2B_VM_IDE_DISK_GB=3
# shellcheck disable=SC2329,SC2317 # called by ide_disk_create
is_running() { return 0; }
check "running: refused" "$(rc_of ide_disk_create)" 1
check "running: nothing created" "$(exists "$IDE")" no
check "create step, running: not an error (0)" "$(rc_of ensure_ide_disk)" 0
check "create step, running: says how to add it" "$(grep -c 'ide-disk-create' "$TMP/out")" 1
check "create step, running: nothing created" "$(exists "$IDE")" no
# shellcheck disable=SC2329,SC2317 # called by ide_disk_create
is_running() { return 1; }
check "stopped, key 3: created (0)" "$(rc_of ide_disk_create)" 0
check "stopped, key 3: 3 GiB virtual" "$(virtual_gib "$IDE")" 3
B2B_VM_IDE_DISK_GB=5
check "exists: refused" "$(rc_of ide_disk_create)" 1
check "exists: left at 3 GiB" "$(virtual_gib "$IDE")" 3
check "create step, exists: kept (0)" "$(rc_of ensure_ide_disk)" 0
check "create step, exists: left at 3 GiB" "$(virtual_gib "$IDE")" 3

# ── create: a fresh build makes both disks, a re-run touches neither ────────
# The real action, as qemu_pipeline.sh runs it (step 2 of make all).
run_create() { # <ide_disk_gb>
    env B2B_VM_IDE_DISK_GB="$1" DISK_SIZE_MB=1024 \
        "${SCRIPT_SH:-bash}" ./setup/host/qemu_vm.sh create >"$TMP/out" 2>&1 && echo 0 || echo $?
}
rm -rf "${VM_DIR:?}"
check "fresh, key 0: created (0)" "$(run_create 0)" 0
check "fresh, key 0: root disk" "$(virtual_gib "$DISK")" 1
check "fresh, key 0: no IDE disk" "$(exists "$IDE")" no
rm -rf "${VM_DIR:?}"
check "fresh, key 2: created (0)" "$(run_create 2)" 0
check "fresh, key 2: root disk" "$(virtual_gib "$DISK")" 1
check "fresh, key 2: IDE disk of 2 GiB" "$(virtual_gib "$IDE")" 2
check "re-run, key 4: still 0" "$(run_create 4)" 0
check "re-run, key 4: IDE disk kept at 2 GiB" "$(virtual_gib "$IDE")" 2
check "a key that is not a number: refused" "$(run_create 4G)" 1

# ── make: vm.ide_disk_gb reaches qemu_vm.sh and the space preflight ─────────
# make -n renders the recipes and runs none of them. The variable is unset for
# it: exported above, it would override the config, as the environment should.
sed 's/^ide_disk_gb = 0$/ide_disk_gb = 40/' tests/fixtures/default.toml >"$TMP/ide.toml"
rendered() { env -u B2B_VM_IDE_DISK_GB make -n "$1" B2B_CONFIG="$2" VM_PATH="$TMP/make" 2>/dev/null; }
check "make qemu_create hands qemu_vm.sh the key" \
    "$(rendered qemu_create "$TMP/ide.toml" | grep -c 'B2B_VM_IDE_DISK_GB="40"')" 1
check "make qemu_create, the default: 0" \
    "$(rendered qemu_create tests/fixtures/default.toml | grep -c 'B2B_VM_IDE_DISK_GB="0"')" 1
check "make _build's pipeline gets the key" \
    "$(rendered _build "$TMP/ide.toml" | grep 'qemu_pipeline.sh' -B3 | grep -c 'B2B_VM_IDE_DISK_GB="40"')" 1
check "make _build's preflight counts the IDE disk" \
    "$(rendered _build "$TMP/ide.toml" | grep -cF -- "--preflight \"\$(( 15360 + 40 * 1024 ))\"")" 1

printf '\n'
[ "$fail" = 0 ] && printf 'all ok\n'
exit "$fail"
