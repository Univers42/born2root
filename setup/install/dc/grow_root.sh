#!/usr/bin/env hellish
#
# grow_root.sh — hand a grown root disk's new space to /var: the extended and
# logical partitions, LUKS, the LVM PV, then the LV and its filesystem. Each
# step is skipped when already done and asserted when run, so a re-run after
# success, or after a failure part way, does only what is left.
#
# For an EXISTING VM whose qcow2 was grown offline (qemu_vm.sh grow-disk). A
# fresh build is partitioned at vm.disk_gb by the installer and needs neither.
#
# THE WINDOW, in order (the guest is down from 1 to 5):
#   1. make qemu_stop GRACEFUL=1 STOP_ON_TIMEOUT=abort STOP_GRACE=180
#      a guest that is still up is make's exit 2 here, not the script's exit 3
#      ("Error 3" from qemu_vm.sh, which make reports as its own failure) --
#      either way, stop here: the disk must not be grown under a live guest
#   2. cold copy: cp --sparse=always <vm>.qcow2 <copy>; qemu-img check <copy>;
#      qemu-img compare <vm>.qcow2 <copy>
#   3. make qemu_grow_disk SIZE_GB=<new size> COLD_COPY=<the copy from step 2>
#      COLD_COPY is not optional: grow-disk refuses without it and compares
#      the new size against that copy before touching the disk
#   4. make qemu_ide_disk_create             (the profile sets vm.ide_disk_gb)
#   5. make qemu_start
#   6. make grow_root (the plan; nothing changes), then make grow_root APPLY=1
#   7. make ide_disk
#   8. reboot twice, each one spelled out:
#        make qemu_stop GRACEFUL=1 STOP_ON_TIMEOUT=abort STOP_GRACE=180 && make qemu_start
#        make qemu_stop GRACEFUL=1 STOP_ON_TIMEOUT=abort STOP_GRACE=180 && make qemu_start B2B_VM_IDE_DISK_GB=0
#      the second one starts without the IDE disk (the guest must come up
#      without it too). Never make qemu_restart here: without GRACEFUL=1 it
#      cuts the power, and this is a disk holding real data.
#
# WHAT IT REFUSES
#   A LUKS device that is not a logical partition inside an extended one, or
#   not the last partition on the disk. That is the layout d-i's crypto recipe
#   makes, and the one where reaching the disk's end is two resizeparts.
#
# THE PASSPHRASE
#   With "key location: keyring", cryptsetup resize needs it. It arrives through
#   a FIFO the host feeds over a second ssh (GROW_ROOT_KEY_FIFO, provision_vm.sh
#   grow-root), not on stdin: sudo here logs every sudo'd command's input to
#   /var/log/sudo. It is read before anything changes, tested against the LUKS
#   header, and only ever held in memory.
#
# USAGE (as root; from the host: make grow_root [APPLY=1])
#   grow_root.sh [--apply]       GROW_ROOT_APPLY=1 means --apply
#   GROW_ROOT_LV (var)  GROW_ROOT_CRYPT (sda5_crypt)  GROW_ROOT_KEY_FIFO
set -u

CRYPT="${GROW_ROOT_CRYPT:-sda5_crypt}"
LV="${GROW_ROOT_LV:-var}"
DUMP_DIR=/var/backups/b2b
DUMP_BEGIN=B2B-SFDISK-DUMP-BEGIN
DUMP_END=B2B-SFDISK-DUMP-END
# Ponytail: within 1 MiB of its target counts as reached (parted alignment,
# 4K LUKS sectors). A disk grown by less than 1 MiB reads as nothing to do.
SLACK=2048
KEY=""

log() { printf '[grow-root] %s\n' "$*"; }
die() { # <message> [exit status]
    printf '[grow-root] ERROR: %s\n' "$1" >&2
    exit "${2:-1}"
}
human() { numfmt --to=iec-i --suffix=B "$(($1 * 512))" 2>/dev/null || printf '%s sectors' "$1"; }

# ── Pure: what `cryptsetup status` and `sfdisk -d` say ──────────────────────
crypt_field() { # <field> <status text> -> its first word
    printf '%s\n' "$2" | sed -n "s/^ *$1: *\([^ ]*\).*/\1/p" | head -n1
}
partition_number() { # /dev/sda5 -> 5
    local n="${1##*[!0-9]}"
    [ -n "$n" ] && [ "$n" != "$1" ] && printf '%s\n' "$n"
}
partition_disk() { # /dev/sda5 -> /dev/sda, /dev/nvme0n1p5 -> /dev/nvme0n1
    local n disk
    n=$(partition_number "$1") || return 1
    disk="${1%"$n"}"
    case "$disk" in *[0-9]p) disk="${disk%p}" ;; esac
    printf '%s\n' "$disk"
}
dump_header() { printf '%s\n' "$1" | sed -n "s/^$2: *//p"; }
dump_field() { # <dump> <partition> <start|size|type>
    printf '%s\n' "$1" | awk -v dev="$2" -v key="$3" '
        $1 == dev && $2 == ":" {
            sub(/^[^:]*: */, ""); gsub(/ /, "")
            n = split($0, kv, ",")
            for (i = 1; i <= n; i++)
                if (index(kv[i], key "=") == 1) { print substr(kv[i], length(key) + 2); exit }
        }'
}
# The extended partition holding <dev> when <dev> is a logical partition in
# it and the last partition of a dos table; otherwise the reason, on stderr.
extended_of() { # <dump> <dev>
    printf '%s\n' "$1" | awk -v dev="$2" '
        function why(m) { print m > "/dev/stderr"; bad = 1; exit 1 }
        /^label:/ { label = $2 }
        $2 == ":" {
            line = $0; sub(/^[^:]*: */, "", line); gsub(/ /, "", line)
            n = split(line, kv, ","); s = ""; z = ""; t = ""
            for (i = 1; i <= n; i++) {
                if (kv[i] ~ /^start=/) s = substr(kv[i], 7) + 0
                if (kv[i] ~ /^size=/) z = substr(kv[i], 6) + 0
                if (kv[i] ~ /^type=/) t = substr(kv[i], 6)
            }
            if (s > last_start) { last_start = s; last = $1 }
            if (t == "5" || t == "f" || t == "85") { exts++; ext = $1; ext_s = s; ext_e = s + z }
            if ($1 == dev) { found = 1; dev_s = s; dev_e = s + z }
        }
        END {
            if (bad) exit 1
            if (label != "dos") why("the partition table is " label ", not dos (msdos)")
            if (!found) why(dev " is not in the partition table")
            if (exts != 1) why("expected one extended partition, found " exts + 0)
            match(dev, /[0-9]+$/)
            if (substr(dev, RSTART) + 0 < 5 || dev_s < ext_s || dev_e > ext_e)
                why(dev " is not a logical partition inside " ext)
            if (last != dev) why(dev " is not the last partition (" last " starts after it)")
            print ext
        }'
}
same_start() { # <dump before> <dump after> <dev>
    local before
    before=$(dump_field "$1" "$3" start)
    [ -n "$before" ] && [ "$before" = "$(dump_field "$2" "$3" start)" ]
}

# ── The host's half: the dump between the markers of a transcript ───────────
save_sfdisk_dump() { # <transcript> <dir> -> the file written; 1 = no dump in it, 2 = not written
    local stamp
    stamp=$(sed -n "s/^$DUMP_BEGIN \([0-9T]*\)\$/\1/p" "$1" | tail -n1)
    [ -n "$stamp" ] || return 1
    awk -v b="$DUMP_BEGIN $stamp" -v e="$DUMP_END" '$0 == e { on = 0 } on { print } $0 == b { on = 1 }' \
        "$1" 2>/dev/null >"$2/sfdisk-$stamp.dump" || return 2
    printf '%s\n' "$2/sfdisk-$stamp.dump"
}

# ── The guest as it is now, and what is left to grow ────────────────────────
pv_field() { # <column> of pe_count pe_start dev_size extent_size vg
    pvs --noheadings --nosuffix --units s -o pv_pe_count,pe_start,dev_size,vg_extent_size,vg_name \
        "/dev/mapper/$CRYPT" 2>/dev/null | awk -v c="$1" '{ print (c < 5) ? int($c) : $c }'
}
lv_sectors() { # the LV's own size, in 512-byte sectors; lvs prints "<" when the
    # value is rounded down to the unit, so the bracket is not part of it.
    local s
    s=$(lvs --noheadings --nosuffix --units s -o lv_size "$VG/$LV" 2>/dev/null | head -n1 | tr -d ' <')
    case "$s" in '' | *[!0-9]*) return 1 ;; esac
    printf '%s\n' "$s"
}
# The filesystem's own size, from its superblock: block count x block size.
# Not findmnt/df: statfs leaves out ext4's metadata, so that size is always a
# few percent under the LV and would never stop asking for a resize.
# Ponytail: ext2/3/4 only (the installer's /var); any other filesystem, or a
# superblock tune2fs cannot read, prints nothing and is left alone, unrepaired.
fs_bytes() {
    tune2fs -l "/dev/$VG/$LV" 2>/dev/null |
        awk -F: '/^Block count:/ { c = $2 } /^Block size:/ { b = $2 }
            END { c += 0; b += 0; if (c > 0 && b > 0) printf "%d\n", c * b; else exit 1 }'
}
survey() {
    local status n
    status=$(cryptsetup status "$CRYPT" 2>/dev/null) || die "cryptsetup status $CRYPT: no such active mapping"
    DEV=$(crypt_field device "$status")
    CRYPT_OFF=$(crypt_field offset "$status")
    CRYPT_S=$(crypt_field size "$status")
    KEYLOC=$(crypt_field "key location" "$status")
    DISK=$(partition_disk "$DEV") || die "cannot tell the disk of $CRYPT's device '$DEV'"
    NUM=$(partition_number "$DEV")
    command -v sfdisk >/dev/null 2>&1 || die "sfdisk is missing (apt-get install fdisk)"
    DUMP=$(sfdisk -d "$DISK" 2>/dev/null) || die "sfdisk -d $DISK failed"
    [ "$(dump_header "$DUMP" device)" = "$DISK" ] || die "sfdisk does not call the disk $DISK"
    EXT=$(extended_of "$DUMP" "$DEV") || die "refusing: the layout is not the installer's"
    DISK_S=$(blockdev --getsz "$DISK")
    PART_S=$(blockdev --getsz "$DEV")
    LOG_START=$(dump_field "$DUMP" "$DEV" start)
    LOG_SIZE=$(dump_field "$DUMP" "$DEV" size)
    VG=$(pv_field 5)
    [ -n "$VG" ] || die "/dev/mapper/$CRYPT is not an LVM physical volume"
    PV_GROW=0
    [ $((($(pv_field 3) - $(pv_field 2)) / $(pv_field 4))) -gt "$(pv_field 1)" ] && PV_GROW=1
    VG_FREE=$(vgs --noheadings -o vg_free_count "$VG" | tr -d ' ')
    LV_S=$(lv_sectors) || LV_S=""
    FS_B=$(fs_bytes) || FS_B=""
    for n in "$DISK_S" "$PART_S" "$CRYPT_OFF" "$CRYPT_S" "$LOG_START" "$LOG_SIZE" "$VG_FREE"; do
        case "$n" in '' | *[!0-9]*) die "could not read the sizes (got '$n'); nothing was changed" ;; esac
    done
    PART_GROW=0
    [ $((LOG_START + LOG_SIZE + SLACK)) -lt "$DISK_S" ] && PART_GROW=1
    # parted wrote the table but partx -u never reached the kernel: the sizes
    # disagree, so partx has to run again even though the table is at the end.
    PARTX_GROW=0
    [ "$PART_S" != "$LOG_SIZE" ] && PARTX_GROW=1
    CRYPT_GROW=$PART_GROW
    [ $((CRYPT_OFF + CRYPT_S + SLACK)) -lt "$PART_S" ] && CRYPT_GROW=1
    # resize2fs can fail online after lvextend -r already grew the LV: the VG
    # has nothing free again while the filesystem is still the old size, and
    # that step has no other way to notice.
    # An LV or filesystem that cannot be sized is not grown on a guess.
    FS_GROW=0
    case "$LV_S$FS_B" in '' | *[!0-9]*) return 0 ;; esac
    [ "$FS_B" -lt "$((LV_S * 512))" ] && FS_GROW=1
    return 0
}
show_sizes() {
    log "disk $DISK: $(human "$DISK_S")"
    log "$DEV (logical in $EXT, start $LOG_START): $(human "$LOG_SIZE") in the table, $(human "$PART_S") in the kernel"
    log "LUKS $CRYPT: $(human "$CRYPT_S") (key location ${KEYLOC:-unknown})"
    log "VG $VG: $VG_FREE free extents; $VG/$LV: $(lvs --noheadings -o lv_size "$VG/$LV" | tr -d ' ')," \
        "$(findmnt -no TARGET,SIZE,AVAIL --source "/dev/$VG/$LV" 2>/dev/null || echo 'not mounted')"
}
nothing_to_do() { [ "$PART_GROW$PARTX_GROW$CRYPT_GROW$PV_GROW$FS_GROW" = 00000 ] && [ "$VG_FREE" = 0 ]; }

# ── The steps ───────────────────────────────────────────────────────────────
read_key() {
    if [ -z "${GROW_ROOT_KEY_FIFO:-}" ] || [ ! -p "$GROW_ROOT_KEY_FIFO" ]; then
        die "cryptsetup resize needs the passphrase (key location ${KEYLOC:-unknown}) and no key FIFO was given: run make grow_root APPLY=1 on the host"
    fi
    # Ponytail: the host is already feeding when this runs; a feeder slower
    # than 60 s reads as no passphrase -- and nothing has changed yet.
    KEY=$(timeout 60 cat "$GROW_ROOT_KEY_FIFO")
    [ -n "$KEY" ] || die "no passphrase arrived within 60 s; nothing was changed"
    printf '%s' "$KEY" | cryptsetup open --test-passphrase --key-file=- "$DEV" ||
        die "that passphrase does not open $DEV; nothing was changed"
}
# parted -s refuses a partition in use (here: all of them) without asking;
# with a pretend tty it asks, and the answer is yes. Any other question gets
# "yes" too, which is not a valid answer to it, so parted fails instead.
# Ponytail: 120 s bounded because a prompt nobody reads is the only hang this
# has ever seen; that prompt was only tested on an image, not on a guest's
# disk in use.
resize_to_end() { printf 'yes\n' | LC_ALL=C timeout 120 parted ---pretend-input-tty "$1" unit s resizepart "$2" 100%; }
grow_partitions() {
    local stamp restore part end after
    command -v parted >/dev/null 2>&1 ||
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq parted || die "apt could not install parted"
    stamp=$(date +%Y%m%dT%H%M%S)
    install -d -m 0700 "$DUMP_DIR"
    printf '%s\n' "$DUMP" >"$DUMP_DIR/sfdisk-$stamp.dump" || die "could not save the partition table"
    printf '%s %s\n%s\n%s\n' "$DUMP_BEGIN" "$stamp" "$DUMP" "$DUMP_END"
    restore="sfdisk --force --no-reread $DISK < $DUMP_DIR/sfdisk-$stamp.dump, then reboot"
    for part in "$EXT" "$DEV"; do
        end=$(($(dump_field "$DUMP" "$part" start) + $(dump_field "$DUMP" "$part" size)))
        [ $((end + SLACK)) -lt "$DISK_S" ] || continue
        resize_to_end "$DISK" "$(partition_number "$part")" || log "parted resizepart on $part failed; checking the table"
        after=$(sfdisk -d "$DISK")
        same_start "$DUMP" "$after" "$DEV" ||
            die "$DEV no longer starts at $LOG_START. Restore the saved table: $restore" 4
        [ "$(dump_field "$after" "$part" size)" -gt "$(dump_field "$DUMP" "$part" size)" ] ||
            die "parted did not grow $part (the table still says $(dump_field "$after" "$part" size) sectors)"
    done
    grow_partx
}
# partx is its own step: parted writes the table, and only partx -u makes the
# kernel agree with it. A run that died before it (or in it) leaves the table
# grown and the kernel behind, which is PART_S != LOG_SIZE, so a re-run comes
# back here without touching parted again.
grow_partx() {
    partx -u "$DISK" || die "partx -u $DISK failed: reboot to make the kernel re-read the table, then run this again"
    survey
    [ "$PART_S" = "$LOG_SIZE" ] || die "the kernel still sees $DEV at $PART_S sectors, the table says $LOG_SIZE: reboot to make the kernel re-read the table"
}
grow_crypt() {
    if [ -n "$KEY" ]; then
        printf '%s' "$KEY" | cryptsetup resize --key-file=- "$CRYPT"
    else
        cryptsetup resize "$CRYPT" </dev/null
    fi || die "cryptsetup resize $CRYPT failed"
    survey
    [ "$CRYPT_GROW" = 0 ] || die "$CRYPT is still $CRYPT_S sectors after cryptsetup resize"
}
grow_pv() {
    pvresize "/dev/mapper/$CRYPT" || die "pvresize failed"
    survey
    [ "$PV_GROW" = 0 ] || die "the PV did not take the new space"
}
grow_lv() {
    lvextend -r -l +100%FREE "$VG/$LV" || die "lvextend -r $VG/$LV failed"
    survey
    [ "$VG_FREE" = 0 ] || die "$VG still has $VG_FREE free extents"
}
# -r on lvextend already resizes the filesystem, except when resize2fs failed
# online and lvextend died with the LV grown. fsadm is that step on its own,
# and it is a no-op when the filesystem already fills the LV.
grow_fs() {
    fsadm resize "/dev/$VG/$LV" || die "fsadm resize /dev/$VG/$LV failed"
    survey
    [ "$FS_GROW" = 0 ] || die "the filesystem on /dev/$VG/$LV is still smaller than the LV"
}

main() {
    local apply="${GROW_ROOT_APPLY:-0}"
    case "${1:-}" in --apply) apply=1 ;; '') ;; *) die "usage: $0 [--apply]" ;; esac
    [ "$(id -u)" = 0 ] || die "run as root"
    survey
    show_sizes
    if nothing_to_do; then
        log "nothing to grow"
        return 0
    fi
    log "plan:"
    [ "$PART_GROW" = 1 ] && log "  save sfdisk -d $DISK to $DUMP_DIR (and the host), parted resizepart ${EXT##*[!0-9]} then $NUM to 100%, each time asserting $DEV still starts at $LOG_START; partx -u"
    [ "$PARTX_GROW" = 1 ] && log "  partx -u $DISK (parted wrote the table, the kernel still has the old size)"
    [ "$CRYPT_GROW" = 1 ] && log "  cryptsetup resize $CRYPT$([ "$KEYLOC" = dm-crypt ] || echo ' (the passphrase, from the host)')"
    [ "$PV_GROW$VG_FREE" != 00 ] && log "  pvresize /dev/mapper/$CRYPT; lvextend -r -l +100%FREE $VG/$LV"
    [ "$FS_GROW" = 1 ] && log "  fsadm resize /dev/$VG/$LV (the filesystem is smaller than its LV)"
    if [ "$apply" != 1 ]; then
        log "dry run: nothing changed. Apply it: make grow_root APPLY=1"
        return 0
    fi
    [ "$CRYPT_GROW$PARTX_GROW" != 00 ] && [ "$KEYLOC" != dm-crypt ] && read_key
    if [ "$PART_GROW" = 1 ]; then
        grow_partitions
    elif [ "$PARTX_GROW" = 1 ]; then
        grow_partx
    fi
    [ "$CRYPT_GROW" = 1 ] && grow_crypt
    [ "$PV_GROW" = 1 ] && grow_pv
    [ "$VG_FREE" = 0 ] || grow_lv
    [ "$FS_GROW" = 1 ] && grow_fs
    show_sizes
    log "done"
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    main "$@"
fi
