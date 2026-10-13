#!/usr/bin/env hellish
# Regression test for setup/install/dc/grow_root.sh, which grows a live
# guest's partitions, LUKS, PV and /var LV into a disk grown offline.
#
# What must never happen: a partition whose START moves (the LUKS header is
# there; the data behind it becomes unreadable), a change made on a layout
# that is not the installer's, a passphrase on a command line or in the
# output, and a dry run that changes anything.
#
# No real disk is touched. The fixtures are shaped after the baas guest as
# measured on 2026-10-13 (sda3 extended, sda5 logical at sector 983040, LUKS2
# sda5_crypt with its key in the kernel keyring, an 80 GiB disk); the dump came
# from sfdisk 2.39 on a sparse image laid out that way, so /boot's size and the
# label-id are stand-ins. The guest's commands are stubs over a small state
# directory that the "mutating" ones change, and log to $TMP/mutations. The
# one real-tool case runs parted on a sparse image file, which is not in use.
set -e

cd "$(dirname "$0")/.."

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-56s = %s\n' "$1" "$2"
    else
        printf 'FAIL %-56s = %s (expected %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FIX=tests/fixtures/grow_root
STATUS=$(cat "$FIX/cryptsetup-status.txt")
DUMP80=$(cat "$FIX/sfdisk-80g.dump")

. ./setup/install/dc/grow_root.sh

# ── pure: reading cryptsetup status and sfdisk -d ───────────────────────────
check "crypt device" "$(crypt_field device "$STATUS")" /dev/sda5
check "crypt key location" "$(crypt_field "key location" "$STATUS")" keyring
check "crypt offset" "$(crypt_field offset "$STATUS")" 32768
check "crypt size (not 'sector size')" "$(crypt_field size "$STATUS")" 166756352
check "disk of /dev/sda5" "$(partition_disk /dev/sda5)" /dev/sda
check "number of /dev/sda5" "$(partition_number /dev/sda5)" 5
check "a second disk moves names: /dev/sdb5" "$(partition_disk /dev/sdb5)" /dev/sdb
check "nvme: /dev/nvme0n1p5" "$(partition_disk /dev/nvme0n1p5) $(partition_number /dev/nvme0n1p5)" "/dev/nvme0n1 5"
check "a whole disk is no partition" "$(partition_disk /dev/sda || echo refused)" refused
check "dump: sda5 start" "$(dump_field "$DUMP80" /dev/sda5 start)" 983040
check "dump: sda3 size" "$(dump_field "$DUMP80" /dev/sda3 size)" 166791168
check "dump: sda3 type" "$(dump_field "$DUMP80" /dev/sda3 type)" 5
check "dump: device" "$(dump_header "$DUMP80" device)" /dev/sda
check "the installer's layout: extended of sda5" "$(extended_of "$DUMP80" /dev/sda5 2>/dev/null)" /dev/sda3
refused() { if extended_of "$1" "$2" >/dev/null 2>"$TMP/why"; then echo accepted; else cat "$TMP/why"; fi; }
check "a primary partition: refused" "$(refused "$DUMP80" /dev/sda1)" "/dev/sda1 is not a logical partition inside /dev/sda3"
check "the extended itself: refused" "$(refused "$DUMP80" /dev/sda3)" "/dev/sda3 is not a logical partition inside /dev/sda3"
check "a gpt table: refused" "$(refused "${DUMP80/label: dos/label: gpt}" /dev/sda5)" "the partition table is gpt, not dos (msdos)"
check "no extended: refused" "$(refused "${DUMP80/type=5/type=83}" /dev/sda5)" "expected one extended partition, found 0"
check "not in the table: refused" "$(refused "$DUMP80" /dev/sda6)" "/dev/sda6 is not in the partition table"
NOT_LAST=$(printf '%s\n%s\n' "${DUMP80/size=   166789120/size=   100000000}" \
    "/dev/sda6 : start=   101000000, size=    10000000, type=83")
check "a logical after it: refused" "$(refused "$NOT_LAST" /dev/sda5)" "/dev/sda5 is not the last partition (/dev/sda6 starts after it)"
check "same start: yes" "$(same_start "$DUMP80" "${DUMP80/size=   166789120/size=   250675200}" /dev/sda5 && echo yes)" yes
check "moved start: no" "$(same_start "$DUMP80" "${DUMP80/start=      983040/start=      985088}" /dev/sda5 || echo no)" no

# ── the host's copy of the dump ─────────────────────────────────────────────
printf 'noise\n%s 20261013T120000\n%s\n%s\nmore noise\n' "$DUMP_BEGIN" "$DUMP80" "$DUMP_END" >"$TMP/transcript"
mkdir "$TMP/vmdir"
check "save_sfdisk_dump names the file by stamp" "$(save_sfdisk_dump "$TMP/transcript" "$TMP/vmdir")" "$TMP/vmdir/sfdisk-20261013T120000.dump"
check "the host copy is the dump, byte for byte" "$(cmp -s "$FIX/sfdisk-80g.dump" "$TMP/vmdir/sfdisk-20261013T120000.dump" && echo same)" same
check "an unwritable directory: 2" "$(save_sfdisk_dump "$TMP/transcript" "$TMP/no/such/dir" 2>/dev/null && echo 0 || echo $?)" 2
printf 'no markers\n' >"$TMP/transcript"
check "no dump in the transcript: 1" "$(save_sfdisk_dump "$TMP/transcript" "$TMP/vmdir" >/dev/null && echo 0 || echo $?)" 1

# ── the guest, stubbed ──────────────────────────────────────────────────────
S="$TMP/state"
DUMP_DIR="$TMP/backups"
reset_guest() { # <disk GiB> <device> <key location>
    rm -rf "$S" "$DUMP_DIR" "$TMP/mutations"
    mkdir -p "$S"
    : >"$TMP/mutations"
    disk=${2%[0-9]}
    printf '%s\n' "$DUMP80" | sed "s#/dev/sda#$disk#" >"$S/dump"
    printf '%s\n' $(($1 * 2097152)) >"$S/disk_s"
    printf '166789120\n' >"$S/part_s"
    printf '166756352\n' >"$S/crypt_s"
    printf '%s\n' "$STATUS" | sed "s#/dev/sda5#$2#; s#keyring#$3#" >"$S/status"
    # floor((166756352 - 2048) / 8192): every extent of the PV is in use.
    printf '20355\n' >"$S/pe_count"
    printf '20355\n' >"$S/pe_used"
    printf 'tempencrypt123' >"$S/key"
}
# shellcheck disable=SC2329,SC2317 # stubs: grow_root.sh's functions call them
{
    id() { echo 0; }
    blockdev() {
        case "$2" in
        *[0-9]) cat "$S/part_s" ;;
        *) cat "$S/disk_s" ;;
        esac
    }
    sfdisk() { cat "$S/dump"; }
    cryptsetup() {
        case "$1" in
        status) sed "s/^\(  size: *\)[0-9]*/\1$(cat "$S/crypt_s")/" "$S/status" ;;
        open) [ "$(cat)" = "$(cat "$S/key")" ] ;;
        resize)
            printf '%s\n' "cryptsetup $*" >>"$TMP/mutations"
            if [ "$2" = --key-file=- ] && [ "$(cat)" != "$(cat "$S/key")" ]; then
                return 2
            fi
            echo $(($(cat "$S/part_s") - 32768)) >"$S/crypt_s"
            ;;
        esac
    }
    parted() { # ---pretend-input-tty <disk> unit s resizepart <n> 100%
        printf '%s\n' "parted $* <<$(cat)" >>"$TMP/mutations"
        local disk_s
        disk_s=$(cat "$S/disk_s")
        awk -v dev="$2$6" -v end="$disk_s" -v shift_by="$(cat "$S/shift" 2>/dev/null || echo 0)" '
            $1 == dev || ($1 ~ /5$/ && shift_by) {
                match($0, /start= *[0-9]+/); s = substr($0, RSTART + 6) + 0
                match($0, /size= *[0-9]+/); z = substr($0, RSTART + 5) + 0
                if ($1 == dev) z = end - s
                if ($1 ~ /5$/) s += shift_by
                sub(/start= *[0-9]+, size= *[0-9]+/, sprintf("start=%12d, size=%12d", s, z))
            } { print }' "$S/dump" >"$S/dump.new"
        mv "$S/dump.new" "$S/dump"
    }
    partx() {
        printf '%s\n' "partx $*" >>"$TMP/mutations"
        dump_field "$(cat "$S/dump")" "$(partition_disk "$(crypt_field device "$(cat "$S/status")")")5" size >"$S/part_s"
    }
    pvs() {
        local dev_s
        dev_s=$(cat "$S/crypt_s")
        printf '  %s 2048 %s 8192 LVMGroup\n' "$(cat "$S/pe_count")" "$dev_s"
    }
    pvresize() {
        printf '%s\n' "pvresize $*" >>"$TMP/mutations"
        echo $((($(cat "$S/crypt_s") - 2048) / 8192)) >"$S/pe_count"
    }
    vgs() { echo "  $(($(cat "$S/pe_count") - $(cat "$S/pe_used")))"; }
    lvs() { echo "  <64.63g"; }
    lvextend() {
        printf '%s\n' "lvextend $*" >>"$TMP/mutations"
        cp "$S/pe_count" "$S/pe_used"
    }
    findmnt() { echo "/var 63.5G 50.1G"; }
    apt-get() { printf '%s\n' "apt-get $*" >>"$TMP/mutations"; }
}
run() { (main "$@") >"$TMP/out" 2>&1 && echo 0 || echo $?; }
said() { grep -cF -- "$1" "$TMP/out" || true; }
n_mutations() { grep -c . "$TMP/mutations" || true; }

# The dry run: a plan, and not one change.
reset_guest 120 /dev/sda5 keyring
check "dry run: 0" "$(run)" 0
check "dry run: plans both resizeparts" "$(said 'parted resizepart 3 then 5 to 100%')" 1
check "dry run: plans the LUKS resize with the passphrase" "$(said 'cryptsetup resize sda5_crypt (the passphrase, from the host)')" 1
check "dry run: says nothing changed" "$(said 'dry run: nothing changed')" 1
check "dry run: no mutation" "$(n_mutations)" 0
check "dry run: no dump saved" "$(find "$TMP/backups" -type f 2>/dev/null | grep -c . || true)" 0

# --apply when the passphrase is needed and no FIFO came with it: refused first.
check "apply, no key FIFO: refused (1)" "$(run --apply)" 1
check "apply, no key FIFO: says why" "$(said 'needs the passphrase')" 1
check "apply, no key FIFO: no mutation" "$(n_mutations)" 0

# Fed the way provision_vm.sh feeds it. Bounded and detached from stdout: a
# script that never opens the FIFO must fail a check, not hang the test.
feed() { # <passphrase> -> GROW_ROOT_KEY_FIFO, fed in the background
    rm -f "$TMP/key.fifo"
    mkfifo "$TMP/key.fifo"
    printf '%s' "$1" | timeout 20 dd of="$TMP/key.fifo" conv=nocreat,notrunc status=none >/dev/null 2>&1 &
    export GROW_ROOT_KEY_FIFO="$TMP/key.fifo"
}
feed wrong-passphrase
check "apply, wrong passphrase: refused (1)" "$(run --apply)" 1
check "apply, wrong passphrase: no mutation" "$(n_mutations)" 0

# The whole thing, then the re-run.
feed tempencrypt123
check "apply: 0" "$(run --apply)" 0
cat >"$TMP/expected" <<EOF
parted ---pretend-input-tty /dev/sda unit s resizepart 3 100% <<yes
parted ---pretend-input-tty /dev/sda unit s resizepart 5 100% <<yes
partx -u /dev/sda
cryptsetup resize --key-file=- sda5_crypt
pvresize /dev/mapper/sda5_crypt
lvextend -r -l +100%FREE LVMGroup/var
EOF
check "apply: the steps, in order" "$(if diff "$TMP/expected" "$TMP/mutations" >/dev/null; then echo as-planned; else cat "$TMP/mutations"; fi)" as-planned
check "apply: sda5 kept its start" "$(dump_field "$(cat "$S/dump")" /dev/sda5 start)" 983040
check "apply: sda5 ends at the disk's end" "$(($(dump_field "$(cat "$S/dump")" /dev/sda5 start) + $(dump_field "$(cat "$S/dump")" /dev/sda5 size)))" 251658240
check "apply: the passphrase is not in the output" "$(said tempencrypt123)" 0
check "apply: the dump is saved in the guest" "$(cmp -s "$FIX/sfdisk-80g.dump" "$DUMP_DIR"/sfdisk-*.dump && echo same)" same
check "apply: and printed for the host" "$(save_sfdisk_dump "$TMP/out" "$TMP/vmdir" | xargs cmp -s "$FIX/sfdisk-80g.dump" && echo same)" same
unset GROW_ROOT_KEY_FIFO
: >"$TMP/mutations"
check "re-run: 0" "$(run --apply)" 0
check "re-run: nothing to grow" "$(said 'nothing to grow')" 1
check "re-run: no mutation" "$(n_mutations)" 0

# A start that moves (here on the first resizepart, the extended's) stops
# everything at once and says how to put the table back.
reset_guest 120 /dev/sda5 keyring
echo 2048 >"$S/shift"
feed tempencrypt123
check "moved start: exit 4" "$(run --apply)" 4
check "moved start: prints the restore command" "$(said 'sfdisk --force --no-reread /dev/sda < ')" 1
check "moved start: nothing after the first parted" "$(n_mutations)" 1
unset GROW_ROOT_KEY_FIFO

# A run that died between the two resizeparts: only the logical is left.
reset_guest 120 /dev/sda5 keyring
sed -i 's#^\(/dev/sda3 : start=      980992, size=\) *[0-9]*#\1   250677248#' "$S/dump"
feed tempencrypt123
check "extended already grown: 0" "$(run --apply)" 0
check "  resizepart 5 only" "$(grep -c '^parted' "$TMP/mutations") $(grep -c 'resizepart 5 ' "$TMP/mutations")" "1 1"
unset GROW_ROOT_KEY_FIFO

# Refused layouts and moved names.
reset_guest 120 /dev/sda1 keyring
check "LUKS on a primary partition: refused (1)" "$(run --apply)" 1
check "  and nothing changed" "$(n_mutations)" 0
reset_guest 120 /dev/sdb5 keyring
check "LUKS on /dev/sdb5 (a second disk came first): plan" "$(run)" 0
check "  the disk is derived, not assumed" "$(said 'disk /dev/sdb:')" 1
reset_guest 120 /dev/sda5 dm-crypt
check "key location dm-crypt: no passphrase needed (0)" "$(run --apply)" 0
check "  cryptsetup resize without a key file" "$(grep -c '^cryptsetup resize sda5_crypt$' "$TMP/mutations")" 1
reset_guest 80 /dev/sda5 keyring
check "a disk that did not grow: 0" "$(run --apply)" 0
check "  nothing to grow" "$(said 'nothing to grow')" 1

# ── the real parted, on an image laid out like the guest ────────────────────
# GRUB's code is in the MBR; parted regenerates the label-id of a table whose
# boot code starts with a zero byte (libparted dos.c), so the image gets one.
unset -f parted sfdisk
if command -v parted >/dev/null 2>&1 && command -v sfdisk >/dev/null 2>&1; then
    img="$TMP/sda.img"
    truncate -s 80G "$img"
    sed 's#/dev/sda#'"$img"'#; /^device:/d' "$FIX/sfdisk-80g.dump" | sfdisk -q "$img"
    printf '\353' | dd of="$img" bs=1 count=1 conv=notrunc status=none
    truncate -s 120G "$img"
    resize_to_end "$img" 3 >/dev/null 2>&1
    resize_to_end "$img" 5 >/dev/null 2>&1
    after=$(sfdisk -d "$img" | sed "s#$img#/dev/sda#g")
    check "parted: sda5 kept its start" "$(same_start "$DUMP80" "$after" /dev/sda5 && echo yes)" yes
    check "parted: sda3 ends at the disk's end" "$(($(dump_field "$after" /dev/sda3 start) + $(dump_field "$after" /dev/sda3 size)))" 251658240
    check "parted: sda5 ends at the disk's end" "$(($(dump_field "$after" /dev/sda5 start) + $(dump_field "$after" /dev/sda5 size)))" 251658240
    check "parted: label-id unchanged" "$(dump_header "$after" label-id)" 0x5c0f2b1e
else
    printf 'skip parted or sfdisk is not installed: the real-tool case did not run\n'
fi

printf '\n'
[ "$fail" = 0 ] && printf 'all ok\n'
exit "$fail"
