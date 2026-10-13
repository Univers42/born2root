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

refuse_unless_blank() { # <disk>
    local found
    found=$(blkid -p "$1" 2>&1)
    [ $? = 2 ] && return 0
    die "$1 is not blank (${found:-blkid -p failed}); it may hold data, so it is not formatted. If it is the IDE disk and nothing on it is needed: cryptsetup close $MAPPER; wipefs -a $1 -- then run this again"
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
