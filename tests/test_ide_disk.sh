#!/usr/bin/env hellish
# Regression test for setup/install/dc/install_ide_disk.sh, the guest half of
# vm.ide_disk_gb: the disk with serial b2bide0001 becomes ide_crypt (LUKS2, a
# keyfile on the encrypted root), XFS mounted with prjquota at
# /var/lib/docker-ide.
#
# What it guards, worst first:
#   - a disk that holds anything (a partition table, a filesystem, LUKS) is
#     never formatted, unless crypttab already names it ide_crypt, and then
#     it is only verified;
#   - two disks with the serial are refused, not guessed between;
#   - an existing key is never overwritten;
#   - crypttab gets ide_crypt AFTER the root's entry (b2b-setup.sh reads the
#     first line as the root), and the exact options the contract names;
#   - the mount is asserted to carry prjquota, the reason the disk exists;
#   - first boot runs it with --if-attached, before docker, and a guest with
#     no such disk is left alone.
#
# Every command that would touch a device is a stub; the files it writes
# (key, crypttab, fstab) live under $TMP.
set -e

cd "$(dirname "$0")/.."

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-58s = %s\n' "$1" "$2"
    else
        printf 'FAIL %-58s = %s (expected %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

. ./setup/install/dc/install_ide_disk.sh

check "the key's home" "$KEY" /etc/b2b/ide-disk.key
check "the mount point" "$MOUNTPOINT" /var/lib/docker-ide
check "the serial qemu_vm.sh gives hd1" "$SERIAL" "$(grep -o 'serial=[a-z0-9]*' setup/host/qemu_vm.sh | cut -d= -f2)"

S="$TMP/state"
BY_ID="$TMP/by-id"
KEY="$TMP/etc/b2b/ide-disk.key"
CRYPTTAB="$TMP/etc/crypttab"
FSTAB="$TMP/etc/fstab"
MOUNTPOINT="$TMP/var/lib/docker-ide"
LUKS_UUID=11111111-2222-3333-4444-555555555555
XFS_UUID=66666666-7777-8888-9999-000000000000
ROOT_CRYPT='sda5_crypt UUID=aaaa none luks,discard'
DISK="$TMP/dev/sdb"

reset_guest() {
    rm -rf "${S:?}" "${BY_ID:?}" "${TMP:?}/etc" "${TMP:?}/var" "${TMP:?}/dev" "${TMP:?}/calls"
    mkdir -p "$S" "$BY_ID" "$TMP/etc" "$TMP/dev"
    : >"$DISK"
    : >"$TMP/calls"
    ln -s "$DISK" "$BY_ID/scsi-0QEMU_QEMU_HARDDISK_b2bide0001"
    printf '%s\n' "$ROOT_CRYPT" >"$CRYPTTAB"
    printf '/dev/mapper/vg-root / ext4 errors=remount-ro 0 1\n' >"$FSTAB"
}
calls() { cat "$TMP/calls"; }
# shellcheck disable=SC2329,SC2317 # stubs: install_ide_disk.sh's functions call them
{
    id() { echo "${FAKE_UID:-0}"; }
    udevadm() { :; }
    lsblk() { echo "sda  QM00001 80G"; }
    chown() { printf '%s\n' "chown $*" >>"$TMP/calls"; }
    systemctl() { printf '%s\n' "systemctl $*" >>"$TMP/calls"; }
    apt-get() { printf '%s\n' "apt-get $*" >>"$TMP/calls"; }
    mkfs.xfs() {
        printf '%s\n' "mkfs.xfs $*" >>"$TMP/calls"
        printf '%s\n' "$XFS_UUID" >"$S/xfs"
    }
    cryptsetup() {
        printf '%s\n' "cryptsetup $*" >>"$TMP/calls"
        case "$1" in
        luksFormat) printf '%s\n' "$LUKS_UUID" >"$S/luks" ;;
        open) : >"$S/open" ;;
        status) [ -f "$S/open" ] ;;
        luksUUID) cat "$S/luks" 2>/dev/null ;;
        esac
    }
    # No real block device exists here; B2B_IS_BLOCK is the seam for [ -b ].
    # FAKE_BLOCK=0 models blkid -p's other rc=2 case: a path that is not a
    # block device (missing, EACCES) -- which is never "blank".
    B2B_IS_BLOCK() { [ "${FAKE_BLOCK:-1}" = 1 ]; }
    blkid() {
        case "$1" in
        -p)
            if [ -f "$S/luks" ]; then
                printf '%s: UUID="%s" TYPE="crypto_LUKS"\n' "$2" "$(cat "$S/luks")"
            elif [ -f "$S/signature" ]; then
                printf '%s: %s\n' "$2" "$(cat "$S/signature")"
            else
                return 2
            fi
            ;;
        -s) cat "$S/xfs" 2>/dev/null ;;
        esac
    }
    # What the kernel would report: the options fstab gave the mount point.
    mount() {
        printf '%s\n' "mount $*" >>"$TMP/calls"
        awk -v m="$1" '$2 == m { print "rw,relatime," $4 }' "$FSTAB" >"$S/options"
        : >"$S/mounted"
    }
    findmnt() {
        [ -f "$S/mounted" ] || return 1
        [ "$1" != -no ] || cat "$S/options"
    }
}
run() { (main "$@") >"$TMP/out" 2>&1 && echo 0 || echo $?; }
# The same, for a function main's argument handling would not reach.
run_refuse() { (refuse_unless_blank "$1") >"$TMP/out" 2>&1 && echo 0 || echo $?; }
said() { grep -c -- "$1" "$TMP/out" || true; }

# ── which disk ──────────────────────────────────────────────────────────────
reset_guest
check "one link: the disk it points at" "$(ide_disks)" "$DISK"
ln -s "$DISK" "$BY_ID/wwn-0x5000000000b2bide0001"
ln -s "$DISK-part1" "$BY_ID/scsi-0QEMU_QEMU_HARDDISK_b2bide0001-part1"
check "two links to one disk, a partition: still one" "$(ide_disks)" "$DISK"
: >"$TMP/dev/sdc"
ln -s "$TMP/dev/sdc" "$BY_ID/scsi-0QEMU_QEMU_HARDDISK_x-b2bide0001"
check "two disks with the serial: refused" "$(run)" 1
check "two disks with the serial: says so" "$(said '2 disks carry serial b2bide0001')" 1
check "two disks with the serial: nothing done" "$(calls)" ""

reset_guest
rm -f "$BY_ID"/*
check "no disk: refused" "$(run)" 1
check "no disk: says how to attach one" "$(said 'make qemu_ide_disk_create')" 1
check "no disk, --if-attached: 0" "$(run --if-attached)" 0
check "no disk, --if-attached: lists the disks it saw" "$(said 'QM00001')" 1
check "no disk, --if-attached: nothing done" "$(calls)" ""
check "no disk, --if-attached: no key" "$([ -e "$KEY" ] && echo made || echo none)" none
rmdir "$BY_ID"
check "no by-id directory, --if-attached: 0" "$(run --if-attached)" 0
check "an unknown flag: refused" "$(run --force)" 1
check "not root: refused" "$(FAKE_UID=1000 run)" 1

# ── a blank disk: set up ────────────────────────────────────────────────────
reset_guest
printf '%s' "$ROOT_CRYPT" >"$CRYPTTAB"
check "blank: 0" "$(run)" 0
check "the key: 4096 bytes, 0400" "$(stat -c '%s %a' "$KEY")" "4096 400"
check "the key is made root's" "$(grep -c "^chown root:root $KEY\$" "$TMP/calls")" 1
check "LUKS2, no prompt, the keyfile" \
    "$(grep '^cryptsetup luksFormat' "$TMP/calls")" "cryptsetup luksFormat --type luks2 --batch-mode --key-file $KEY $DISK"
check "opened as ide_crypt" "$(grep '^cryptsetup open' "$TMP/calls")" "cryptsetup open --key-file $KEY $DISK ide_crypt"
check "XFS on the mapping" "$(grep '^mkfs.xfs' "$TMP/calls")" "mkfs.xfs -q /dev/mapper/ide_crypt"
check "xfsprogs present: no apt" "$(grep -c '^apt-get' "$TMP/calls" || true)" 0
check "the root's crypttab line stays first" "$(head -n1 "$CRYPTTAB")" "$ROOT_CRYPT"
check "crypttab: ide_crypt on its own line" "$(sed -n 2p "$CRYPTTAB")" \
    "ide_crypt UUID=$LUKS_UUID $KEY luks,nofail,x-systemd.device-timeout=10s"
check "fstab: by the filesystem's UUID, prjquota, nofail" "$(sed -n 2p "$FSTAB")" \
    "UUID=$XFS_UUID $MOUNTPOINT xfs defaults,prjquota,nofail,x-systemd.device-timeout=10s 0 2"
check "in order: format, open, mkfs, reload, mount" \
    "$(sed -n 's/^\(cryptsetup [a-zA-Z]*\|mkfs.xfs\|systemctl daemon-reload\|mount\).*/\1/p' "$TMP/calls" | grep -v -e status -e luksUUID | tr '\n' ,)" \
    "cryptsetup luksFormat,cryptsetup open,mkfs.xfs,systemctl daemon-reload,mount,"
check "the mount point exists" "$([ -d "$MOUNTPOINT" ] && echo yes)" yes
check "mounted from fstab" "$(grep -c "^mount $MOUNTPOINT\$" "$TMP/calls")" 1

# ── run again: verified, not formatted ──────────────────────────────────────
cp "$KEY" "$TMP/key.first"
rm -f "$S/mounted" "$S/open"
: >"$TMP/calls"
check "again: 0" "$(run)" 0
check "again: says it verified" "$(said 'verified')" 1
check "again: no format, no mkfs" "$(grep -c -e luksFormat -e mkfs "$TMP/calls" || true)" 0
check "again: the key is the same key" "$(cmp -s "$KEY" "$TMP/key.first" && echo same)" same
check "again: crypttab, fstab not doubled" "$(grep -c ide_crypt "$CRYPTTAB") $(grep -c docker-ide "$FSTAB")" "1 1"
check "again: the mapping opened" "$(grep -c '^cryptsetup open' "$TMP/calls")" 1
check "again: mounted" "$(grep -c '^mount ' "$TMP/calls")" 1
check "again, already open and mounted: 0" "$(run)" 0
check "again, already open and mounted: nothing else opened" "$(grep -c '^cryptsetup open' "$TMP/calls")" 1
sed -i "s/$LUKS_UUID/99999999-2222-3333-4444-555555555555/" "$CRYPTTAB"
check "crypttab's ide_crypt is another disk: refused" "$(run)" 1
check "crypttab's ide_crypt is another disk: says so" "$(said 'not this disk')" 1
sed -i "s/99999999-2222-3333-4444-555555555555/$LUKS_UUID/" "$CRYPTTAB"
sed -i '/docker-ide/d' "$FSTAB"
check "crypttab, no fstab line: refused" "$(run)" 1
check "crypttab, no fstab line: says so" "$(said "no fstab line for $MOUNTPOINT")" 1
reset_guest
printf 'ide_crypt UUID=%s %s luks,nofail\n' "$LUKS_UUID" "$KEY" >>"$CRYPTTAB"
check "crypttab, the disk missing, --if-attached: 0" "$(rm -f "$BY_ID"/* && run --if-attached)" 0

# ── a disk that holds something ─────────────────────────────────────────────
reset_guest
printf 'PTUUID="abcd" PTTYPE="gpt"\n' >"$S/signature"
check "a partition table: refused" "$(run)" 1
check "a partition table: names it" "$(said 'PTTYPE="gpt"')" 1
check "a partition table: wipefs names the by-id path, does not wipe" \
    "$(said "wipefs -a $BY_ID/scsi-0QEMU_QEMU_HARDDISK_b2bide0001")" 1
check "a partition table: no /dev/sd kernel name in the refusal" \
    "$(grep -c '/dev/sd' "$TMP/out" || true)" 0
check "a partition table: nothing formatted" "$(grep -c -e luksFormat -e mkfs "$TMP/calls" || true)" 0
check "a partition table: no key made" "$([ -e "$KEY" ] && echo made || echo none)" none
rm -f "$S/signature"
printf '%s\n' "$LUKS_UUID" >"$S/luks"
check "LUKS, crypttab without ide_crypt: refused" "$(run)" 1
check "LUKS, crypttab without ide_crypt: nothing formatted" "$(grep -c luksFormat "$TMP/calls" || true)" 0

# ── blkid's rc 2 is not proof of blank ──────────────────────────────────────
# blkid -p exits 2 both for "no signature found" (blank -- what we want) and
# for "cannot open the device" (a missing path, EACCES): measured on
# util-linux 2.39.3, both give rc 2, so rc 2 alone used to mean "blank" and
# luksFormat ran on a disk blkid could not even read. A disk blkid cannot open
# must never be formatted.
reset_guest
FAKE_BLOCK=0
check "rc 2 but not a block device: refused" "$(run)" 1
check "rc 2 but not a block device: says it is not blank" "$(said 'not blank')" 1
check "rc 2 but not a block device: no luksFormat" "$(grep -c luksFormat "$TMP/calls" || true)" 0
check "rc 2 but not a block device: names it by its by-id path" \
    "$(said "$BY_ID/scsi-0QEMU_QEMU_HARDDISK_b2bide0001 is not blank")" 1
check "rc 2 but not a block device: no /dev/sd kernel name in the refusal" \
    "$(grep -c '/dev/sd' "$TMP/out" || true)" 0
FAKE_BLOCK=1

# ── the refusable by-id name, never the kernel's ─────────────────────────────
# The by-id link can vanish between ide_disks() and the refusal (udev still
# settling, the disk detached mid-run). There is then no stable name to give
# the operator, and the kernel's letter this boot is the one thing a refusal
# must not print: that disk is refused, not named.
: >"$TMP/out"
rm -f "$BY_ID"/*
check "no by-id name left: refused" "$(run_refuse "$DISK")" 1
check "no by-id name left: says it cannot name the disk" "$(said 'cannot name stably')" 1
check "no by-id name left: no /dev/sd kernel name anywhere" \
    "$(grep -c '/dev/sd' "$TMP/out" || true)" 0
check "no by-id name left: no luksFormat" "$(grep -c luksFormat "$TMP/calls" || true)" 0
rm -f "$S/luks"

# ── the key, fstab, the mount ───────────────────────────────────────────────
reset_guest
mkdir -p "${KEY%/*}"
printf 'short' >"$KEY"
check "a key of the wrong size: refused" "$(run)" 1
check "a key of the wrong size: left as it was" "$(cat "$KEY")" short
check "a key of the wrong size: nothing formatted" "$(grep -c luksFormat "$TMP/calls" || true)" 0
reset_guest
mkdir -p "${KEY%/*}"
head -c 4096 /dev/urandom >"$TMP/key.kept"
cp "$TMP/key.kept" "$KEY"
chmod 0644 "$KEY"
check "a key from an earlier run: 0" "$(run)" 0
check "a key from an earlier run: reused" "$(cmp -s "$KEY" "$TMP/key.kept" && echo same)" same
check "a key from an earlier run: made 0400" "$(stat -c %a "$KEY")" 400
reset_guest
printf 'UUID=bbbb %s xfs defaults 0 2\n' "$MOUNTPOINT" >>"$FSTAB"
check "fstab already mounts it: refused" "$(run)" 1
check "fstab already mounts it: nothing formatted" "$(grep -c luksFormat "$TMP/calls" || true)" 0
reset_guest
# shellcheck disable=SC2329,SC2317 # stub: mount_it calls it
mount() {
    printf 'rw,relatime,attr2,noquota\n' >"$S/options"
    : >"$S/mounted"
}
check "mounted without prjquota: 1" "$(run)" 1
check "mounted without prjquota: says so" "$(said 'prjquota')" 1
unset -f mount
reset_guest
check "xfsprogs missing: 1 when apt cannot" "$(unset -f mkfs.xfs && PATH=/usr/bin:/bin run)" 1
check "xfsprogs missing: asked apt for it" "$(grep -c 'apt-get install -y -qq xfsprogs' "$TMP/calls")" 1
check "xfsprogs missing: nothing formatted" "$(grep -c luksFormat "$TMP/calls" || true)" 0

# ── first boot and the host ─────────────────────────────────────────────────
FB=preseeds/first-boot-setup.sh
check "first boot runs it with --if-attached" \
    "$(grep -c '/root/install_ide_disk.sh --if-attached' "$FB")" 1
check "first boot runs it after var-gc, before docker" "$(awk '
    $1 == "feature_begin" && $2 == "var-gc" { v = NR }
    /install_ide_disk.sh --if-attached/ { i = NR }
    $1 == "feature_begin" && $2 == "docker" { d = NR }
    END { print (v && i && d && v < i && i < d) ? "yes" : "no" }' "$FB")" yes
check "a failed first boot names the retry" \
    "$(grep -c 'ide-disk) echo "make ide_disk"' "$FB")" 1
check "make ide_disk runs the provision action" \
    "$(make -n ide_disk B2B_CONFIG=tests/fixtures/default.toml 2>/dev/null | grep -c 'provision_vm.sh "debian" ide-disk')" 1

printf '\n'
[ "$fail" = 0 ] && printf 'all ok\n'
exit "$fail"
