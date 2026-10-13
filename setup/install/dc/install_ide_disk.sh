#!/usr/bin/env hellish
#
# install_ide_disk.sh — the IDE sandbox's disk: the second disk QEMU attaches
# when vm.ide_disk_gb > 0 (serial b2bide0001), as LUKS2 `ide_crypt` holding an
# XFS filesystem mounted with project quotas at /var/lib/docker-ide.
#
# WHY
#   The osionos IDE sandbox runs a second dockerd with its data-root there.
#   Capping each sandbox's writable layer (overlay2 `size=`) needs XFS mounted
#   with prjquota underneath, which the installer's LVM volumes are not; a disk
#   of its own also keeps a runaway sandbox from filling /var and the databases
#   with it.
#   The key is a 4096-byte file on the root, which is itself LUKS: the disk is
#   as protected at rest as the root, and unlocks at boot without a second
#   passphrase prompt nobody is there to answer.
#   nofail on both lines: a boot with the disk detached (ide_disk_gb = 0, the
#   qcow2 missing) goes on without it instead of stopping in emergency mode.
#   Ponytail: x-systemd.device-timeout=10s -- a disk slower than that to show
#   up is skipped for this boot: /var/lib/docker-ide is then an empty
#   directory on /. `systemctl start var-lib-docker\x2dide.mount` brings it in.
#
# WHAT IT REFUSES
#   - no disk with the serial (unless --if-attached), or more than one;
#   - a disk where `blkid -p` finds anything -- a partition table, a
#     filesystem, LUKS -- unless /etc/crypttab already has ide_crypt for that
#     very disk: then it only verifies (key, fstab, mapping, prjquota mount);
#   - a disk blkid -p could not open: rc 2 says "no signature" and "cannot open
#     the device" alike (util-linux 2.39.3), so only a block device that really
#     is there counts as blank;
#   - a disk whose /dev/disk/by-id name cannot be resolved: a refusal names
#     that by-id path, never the /dev/sdX the kernel picked this boot;
#   - an existing key that is not 4096 bytes: a key is never overwritten;
#   - an fstab line for /var/lib/docker-ide that crypttab knows nothing of.
#   It never wipes anything; when a disk is not blank it prints the command.
#
# USAGE
#   sudo ./install_ide_disk.sh                 set the disk up, or verify it
#   sudo ./install_ide_disk.sh --if-attached   the same; no such disk is not
#                                              an error (what first boot runs)
#   make ide_disk                              from the host (provision_vm.sh ide-disk)
set -u

BY_ID=/dev/disk/by-id
SERIAL=b2bide0001
MAPPER=ide_crypt
MAPPED="/dev/mapper/$MAPPER"
KEY=/etc/b2b/ide-disk.key
CRYPTTAB=/etc/crypttab
FSTAB=/etc/fstab
MOUNTPOINT=/var/lib/docker-ide

log() { printf '[ide-disk] %s\n' "$*"; }
die() {
    printf '[ide-disk] ERROR: %s\n' "$*" >&2
    exit 1
}

# Ponytail: QEMU's scsi-hd with serial=b2bide0001 is assumed to show up as a
# by-id name ending in the serial (scsi-0QEMU_QEMU_HARDDISK_b2bide0001) -- not
# yet seen on the guest. A name that carries it elsewhere reads as no disk:
# --if-attached then skips it, which is why the 0 case lists what lsblk sees.
# Several names for one disk are one disk: they are counted after resolving.
ide_disks() { find "$BY_ID" -maxdepth 1 -name "*$SERIAL" -exec readlink -f {} + 2>/dev/null | sort -u; }
crypttab_source() { awk -v name="$MAPPER" '$1 == name { print $2; exit }' "$CRYPTTAB" 2>/dev/null; }
fstab_has_mount() { awk -v m="$MOUNTPOINT" '$2 == m { found = 1 } END { exit !found }' "$FSTAB" 2>/dev/null; }
key_ok() { [ "$(stat -c '%s %a' "$KEY" 2>/dev/null)" = "4096 400" ]; }
# A file without a final newline would glue the new line onto its last one.
append_line() { # <file> <line>
    if [ -s "$1" ] && [ -n "$(tail -c1 "$1")" ]; then
        printf '\n' >>"$1" || return 1
    fi
    printf '%s\n' "$2" >>"$1"
}

# The name an operator can safely copy across reboots. by-id names are stable;
# the /dev/sdX the kernel happened to pick this boot is not -- after a reboot
# the same disk may be sdc while the root disk is sdb, so a `wipefs -a /dev/sdX`
# copied from an earlier run would wipe whichever table that letter now names.
# Given the resolved disk, print the by-id link that resolves to it, or
# nothing when no such link is left.
# Ponytail: prints the first match in glob order, so a disk carrying the serial
# under several by-id names is named by one of them, with no way to tell which
# the operator meant. A link that vanished between ide_disks() and here prints
# nothing, which refuses the disk rather than fall back to the kernel's letter.
by_id_path() { # <resolved-disk>
    local link
    for link in "$BY_ID"/*"$SERIAL"; do
        [ -e "$link" ] || continue
        [ "$(readlink -f "$link" 2>/dev/null)" = "$1" ] || continue
        printf '%s\n' "$link"
        return 0
    done
    return 1
}

# B2B_IS_BLOCK is the seam the tests override for [ -b ]; no block device
# exists where they run. blkid -p cannot tell a blank device from one it could
# not open, which is why refuse_unless_blank needs this check as well.
B2B_IS_BLOCK() { [ -b "$1" ]; }

refuse_unless_blank() { # <disk>
    local dev by_id found rc
    dev=$1
    # Refusing names a disk too: a kernel name here is copied verbatim onto a
    # wipefs command line, so nothing is said until a by-id name is in hand.
    by_id=$(by_id_path "$dev") ||
        die "no $BY_ID name resolves to the disk carrying serial $SERIAL -- not formatting a disk I cannot name stably; udevadm settle, then run this again"
    found=$(blkid -p "$dev" 2>&1)
    rc=$?
    # blkid -p exits 2 both for "no signature found" -- blank, what we want --
    # and for "cannot open the device" (a missing path, EACCES). Measured on
    # util-linux 2.39.3: both give rc 2, so rc 2 alone used to mean "blank" and
    # luksFormat ran on a disk blkid could not even read. Blank only when rc is
    # 2, there is no signature output, and the disk is a block device to open.
    if [ "$rc" != 2 ] || [ -n "$found" ]; then
        # blkid's output leads with the path it was given, that is the kernel
        # name: the by-id name stands in for it so the line stays safe to
        # copy into a command.
        found=${found//"$dev"/"$by_id"}
        die "$by_id is not blank (${found:-blkid -p rc $rc}); it may hold data, so it is not formatted. If it is the IDE disk and nothing on it is needed: cryptsetup close $MAPPER; wipefs -a $by_id -- then run this again"
    fi
    # Ponytail: [ -b ] proves a block node, not that blkid read it -- a probe
    # failing with only rc 2 and nothing on stderr would read as blank here.
    # Root on a udev-settled disk avoids it; the stderr merge above is the
    # second guard, so the cheap test is enough.
    B2B_IS_BLOCK "$dev" ||
        die "$by_id is not blank: blkid -p found no signature but it is not a block device that can be read (rc 2); it may hold data, so it is not formatted -- reattach the disk and run this again"
    return 0
}

ensure_xfsprogs() {
    command -v mkfs.xfs >/dev/null 2>&1 && return 0
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq xfsprogs
    command -v mkfs.xfs >/dev/null 2>&1 || die "apt could not install xfsprogs"
}

# A key left by an earlier run that stopped before formatting is reused.
make_key() {
    if [ ! -e "$KEY" ]; then
        mkdir -p "${KEY%/*}" || die "cannot create ${KEY%/*}"
        if ! (umask 0377 && dd if=/dev/urandom of="$KEY.new" bs=4096 count=1 iflag=fullblock status=none) ||
            ! mv -f "$KEY.new" "$KEY"; then
            die "could not write $KEY"
        fi
    fi
    if ! chown root:root "$KEY" || ! chmod 0400 "$KEY"; then
        die "could not make $KEY root's, 0400"
    fi
    key_ok || die "$KEY exists but is not 4096 bytes -- not overwriting a key; move it away first"
}

format_disk() { # <disk>
    cryptsetup luksFormat --type luks2 --batch-mode --key-file "$KEY" "$1" || die "luksFormat $1 failed"
    cryptsetup open --key-file "$KEY" "$1" "$MAPPER" || die "could not open $1 as $MAPPER"
    mkfs.xfs -q "$MAPPED" || die "mkfs.xfs $MAPPED failed"
}

write_entries() { # <disk>
    local luks xfs
    luks=$(cryptsetup luksUUID "$1")
    xfs=$(blkid -s UUID -o value "$MAPPED")
    if [ -z "$luks" ] || [ -z "$xfs" ]; then
        die "could not read the UUIDs (LUKS '$luks', XFS '$xfs')"
    fi
    append_line "$CRYPTTAB" "$MAPPER UUID=$luks $KEY luks,nofail,x-systemd.device-timeout=10s" ||
        die "could not write $CRYPTTAB"
    append_line "$FSTAB" "UUID=$xfs $MOUNTPOINT xfs defaults,prjquota,nofail,x-systemd.device-timeout=10s 0 2" ||
        die "could not write $FSTAB"
    systemctl daemon-reload || log "WARN: systemctl daemon-reload failed; the next boot reads both files anyway"
}

# Mounted through fstab, so the line just written is the one being tested.
mount_it() {
    mkdir -p "$MOUNTPOINT" || die "cannot create $MOUNTPOINT"
    if ! findmnt -n "$MOUNTPOINT" >/dev/null 2>&1; then
        mount "$MOUNTPOINT" || die "mount $MOUNTPOINT failed"
    fi
    case ",$(findmnt -no OPTIONS "$MOUNTPOINT")," in
    *,prjquota,*) ;;
    *) die "$MOUNTPOINT is mounted without prjquota: $(findmnt -no OPTIONS "$MOUNTPOINT")" ;;
    esac
}

verify() { # <disk>
    local want have
    want=$(crypttab_source)
    have="UUID=$(cryptsetup luksUUID "$1" 2>/dev/null)"
    [ "$want" = "$have" ] || die "$CRYPTTAB's $MAPPER is $want, not this disk ($1 is ${have#UUID=}) -- fix it by hand"
    key_ok || die "$KEY is not a 4096-byte 0400 file"
    fstab_has_mount || die "$CRYPTTAB has $MAPPER but there is no fstab line for $MOUNTPOINT"
    if ! cryptsetup status "$MAPPER" >/dev/null 2>&1; then
        cryptsetup open --key-file "$KEY" "$1" "$MAPPER" || die "could not open $1 as $MAPPER"
    fi
    mount_it
}

main() {
    local if_attached=0 disks n dev
    case "${1:-}" in --if-attached) if_attached=1 ;; '') ;; *) die "usage: $0 [--if-attached]" ;; esac
    [ "$(id -u)" = 0 ] || die "run as root"
    # Ponytail: udev gets 30 s to finish naming disks; one named later reads
    # as absent, and --if-attached then skips it (rerun: make ide_disk).
    udevadm settle --timeout=30 >/dev/null 2>&1
    disks=$(ide_disks)
    n=$(printf '%s' "$disks" | grep -c .)
    case "$n" in
    0)
        if [ "$if_attached" = 1 ]; then
            log "no disk with serial $SERIAL (vm.ide_disk_gb = 0?): nothing to do. The disks here:"
            lsblk -dno NAME,SERIAL,SIZE 2>/dev/null | sed 's/^/[ide-disk]   /'
            return 0
        fi
        die "no disk with serial $SERIAL under $BY_ID -- set vm.ide_disk_gb, stop the VM, make qemu_ide_disk_create, start it"
        ;;
    1) dev=$disks ;;
    *) die "$n disks carry serial $SERIAL ($(printf '%s' "$disks" | tr '\n' ' ')) -- refusing to guess" ;;
    esac
    if [ -n "$(crypttab_source)" ]; then
        verify "$dev"
        log "verified: $dev is $MAPPER, mounted at $MOUNTPOINT with prjquota"
        return 0
    fi
    refuse_unless_blank "$dev"
    fstab_has_mount && die "$FSTAB already mounts $MOUNTPOINT but $CRYPTTAB has no $MAPPER -- fix it by hand"
    ensure_xfsprogs
    make_key
    log "formatting $dev as LUKS2 $MAPPER, XFS inside"
    format_disk "$dev"
    write_entries "$dev"
    mount_it
    log "done: $dev is $MAPPER, mounted at $MOUNTPOINT with prjquota"
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    main "$@"
fi
