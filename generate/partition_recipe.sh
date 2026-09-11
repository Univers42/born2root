#!/usr/bin/env hellish
# Derive the guest's partition layout from one number.
#
# The recipe in preseeds/preseed.cfg used to be eight hand-typed sizes. That
# was fine for exactly one disk. Asking for a 10 GB or a 50 GB VM meant
# redoing the arithmetic by hand, and getting it slightly wrong was not
# reported until partman refused the recipe twenty minutes into an install.
# Naive scaling is no better: multiply the 15 GB layout by 33 and a 500 GB
# disk ends up with a 100 GB /tmp and a 30 GB /var/log.
#
# So the layout is COMPUTED, from SIZE_B2B (GB), by a rule that behaves at
# both ends of the range:
#
#     every volume gets a FLOOR      -- a working Debian fits on 8 GB
#     plus a WEIGHTED SHARE          -- of whatever is left over the floors
#     clamped to a CAP               -- nothing is gained past 30 GB of /
#     and /var takes the remainder   -- Docker is the thing that actually grows
#
# /var is declared LAST with -1, which turns partman's habit of inflating the
# last volume to fill the group (measured; see preseed.cfg) into the mechanism
# that puts the leftover where it is wanted. Nothing is formatted to be thrown
# away, and the group ends up fully allocated by design.
#
# swap follows RAM, not disk: clamp(VM_RAM_MB, 1 GB, 4 GB), and never more than
# a quarter of the group, so a tiny disk is not half swap.
#
# Below the minimum this exits 1 and names the size that would work. It never
# emits a recipe the installer would reject.
#
#   generate/partition_recipe.sh --recipe     the d-i expert_recipe block, with markers
#   generate/partition_recipe.sh --table      the layout, for humans (make partitions)
#   generate/partition_recipe.sh --sizes      "name=MB" per volume, for feature_profile.sh
#
# Env
#   SIZE_B2B (15)         whole-disk size in GB
#   DISK_SIZE_MB          same thing in MB; wins over SIZE_B2B when both are set,
#                         because the Makefile derives it and forwards it
#   VM_RAM_MB (2048)      what the guest boots with; sizes swap

set -u

# ── The model ───────────────────────────────────────────────────────────────
BIOS_MB=1      # bios_boot, for GRUB on a GPT/MBR hybrid
BOOT_MB=500    # /boot, unencrypted, a few kernels
OVERHEAD_MB=20 # LUKS2 header (16 MB) plus LVM physical-extent rounding

# name  floor  weight%  cap      (var has no weight and no cap: it takes the rest)
# home's floor and weight were raised after checking the install against the
# layout (generate/feature_profile.sh): at 8 GB kickstart.nvim's plugins and
# tree-sitter parsers (~300 MB) did not fit a 256 MB /home, and at 15 GB the
# IDE layer was within 100 MB of full. tmp gave up 128 MB so the 8 GB minimum
# still holds.
# Calibrated on the first real build (2026-09-11): / held 2.7 GB before nvim
# on a 3.3 GB root, so root's floor and share went up and home/opt/tmp gave
# some back. See generate/feature_profile.sh for the per-feature numbers.
LAYOUT='
root    2816  25   30720
swap       0   0    4096
home     512   9  102400
opt      256   5   20480
srv      256   2   10240
tmp      256   3   10240
var-log  384   3   20480
var     2048   0       0
'
SWAP_MIN_MB=1024
SWAP_MAX_MB=4096

# ── Inputs ──────────────────────────────────────────────────────────────────
MODE="${1:---table}"
VM_RAM_MB="${VM_RAM_MB:-2048}"
[ -n "${VM_RAM_MB}" ] || VM_RAM_MB=2048
if [ -n "${DISK_SIZE_MB:-}" ]; then
    DISK_MB="$DISK_SIZE_MB"
else
    DISK_MB=$((${SIZE_B2B:-15} * 1024))
fi
case "$DISK_MB$VM_RAM_MB" in
*[!0-9]*)
    echo "partition_recipe: SIZE_B2B/DISK_SIZE_MB/VM_RAM_MB must be whole numbers (got disk=${DISK_MB} ram=${VM_RAM_MB})" >&2
    exit 1
    ;;
esac

# ── Arithmetic ──────────────────────────────────────────────────────────────
RESERVED=$((BIOS_MB + BOOT_MB + OVERHEAD_MB))
AVAIL=$((DISK_MB - RESERVED))

FLOORS=0
for f in $(printf '%s\n' "$LAYOUT" | awk 'NF == 4 && $1 != "swap" { print $2 }'); do
    FLOORS=$((FLOORS + f))
done

# swap: RAM-derived, clamped, then bounded by what the disk can spare. The
# last bound is what lets an 8 GB disk work at all: with 2 GB of RAM the RAM
# rule alone would ask for more than the floors leave.
SWAP=$VM_RAM_MB
[ "$SWAP" -lt "$SWAP_MIN_MB" ] && SWAP=$SWAP_MIN_MB
[ "$SWAP" -gt "$SWAP_MAX_MB" ] && SWAP=$SWAP_MAX_MB
[ "$SWAP" -gt $((AVAIL / 4)) ] && SWAP=$((AVAIL / 4))
[ "$SWAP" -gt $((AVAIL - FLOORS)) ] && SWAP=$((AVAIL - FLOORS))

MIN_DISK=$((FLOORS + SWAP_MIN_MB + RESERVED))
if [ "$SWAP" -lt "$SWAP_MIN_MB" ]; then
    min_gb=$(((MIN_DISK + 1023) / 1024))
    echo "partition_recipe: ${DISK_MB} MB is too small for this layout." >&2
    echo "  floors ${FLOORS} MB + swap ${SWAP_MIN_MB} MB + boot/overhead ${RESERVED} MB = ${MIN_DISK} MB minimum" >&2
    echo "  SIZE_B2B must be at least ${min_gb}   (make all SIZE_B2B=${min_gb})" >&2
    exit 1
fi

SURPLUS=$((AVAIL - FLOORS - SWAP))

# A literal newline: $'\n' is not portable to every shell this runs under.
NL='
'
# Size every pinned volume, then hand /var whatever is left.
SIZES=""
OTHERS=0
while read -r name floor weight cap; do
    [ -n "$name" ] || continue
    case "$name" in
    swap) size=$SWAP ;;
    var) continue ;;
    *)
        size=$((floor + SURPLUS * weight / 100))
        [ "$size" -gt "$cap" ] && size=$cap
        ;;
    esac
    OTHERS=$((OTHERS + size))
    SIZES="${SIZES}${SIZES:+$NL}$name=$size"
done <<EOF
$LAYOUT
EOF
VAR=$((AVAIL - OTHERS))
VAR_FLOOR=$(printf '%s\n' "$LAYOUT" | awk '$1 == "var" { print $2 }')
SIZES="${SIZES}${NL}var=$VAR"

size_of() { printf '%s\n' "$SIZES" | awk -F= -v n="$1" '$1 == n { print $2 }'; }

# ext4 keeps 5% in reserve on / and 1% elsewhere (b2b-setup.sh sets that), and
# MB→GiB is /1024. Roughly 93% of the partman figure is what df will show.
mounted() { awk -v mb="$1" 'BEGIN { printf "%.1f GiB", mb * 0.93 / 1024 }'; }

# ── Output ──────────────────────────────────────────────────────────────────
recipe_stanza() {
    # $1 name  $2 min  $3 priority  $4 max  $5 fstype  $6 mountpoint ('' for swap)
    printf '\t%s %s %s %s \\\n' "$2" "$3" "$4" "$5"
    # shellcheck disable=SC2016  # partman syntax, not shell
    printf '\t$lvmok{ } \\\n'
    printf '\tlv_name{ %s } \\\n' "$1"
    if [ "$5" = linux-swap ]; then
        printf '\tmethod{ swap } format{ } \\\n'
    else
        printf '\tmethod{ format } format{ } \\\n'
        printf '\tuse_filesystem{ } filesystem{ ext4 } \\\n'
        printf '\tmountpoint{ %s } \\\n' "$6"
    fi
}

emit_table() {
    printf '\n  Partition layout for a %s MB disk  (SIZE_B2B=%s, VM_RAM_MB=%s)\n\n' \
        "$DISK_MB" "$((DISK_MB / 1024))" "$VM_RAM_MB"
    printf '    %-10s %10s   %-9s  %s\n' "" "partman MB" "≈ mounted" "mount"
    printf '    %-10s %10s   %-9s  %s\n' "bios_boot" "$BIOS_MB" "" "(GRUB)"
    printf '    %-10s %10s   %-9s  %s\n' "/boot" "$BOOT_MB" "$(mounted $BOOT_MB)" "/boot  (unencrypted)"
    for spec in root:/ swap:"[SWAP]" home:/home opt:/opt srv:/srv tmp:/tmp var-log:/var/log var:/var; do
        n=${spec%%:*}
        m=${spec#*:}
        s=$(size_of "$n")
        printf '    %-10s %10s   %-9s  %s\n' "$n" "$s" "$(mounted "$s")" "$m"
    done
    printf '    %-10s %10s\n' "" "──────────"
    printf '    %-10s %10s   %s\n\n' "LVM total" "$AVAIL" "(+ ${RESERVED} MB boot/overhead = ${DISK_MB})"
    if [ "$SURPLUS" -eq 0 ]; then
        printf '  %s\n\n' "Every volume is at its floor: this is the smallest layout that works."
    fi
}

emit_recipe() {
    printf '# ── RECIPE-BEGIN ─────────────────────────────────────────────────────────────\n'
    printf '# Generated by generate/partition_recipe.sh — do not edit by hand.\n'
    printf '#   SIZE_B2B=%s (%s MB)   VM_RAM_MB=%s\n' "$((DISK_MB / 1024))" "$DISK_MB" "$VM_RAM_MB"
    printf '#   %-9s %8s   %s\n' "volume" "MB" "≈ mounted"
    for n in root swap home opt srv tmp var-log var; do
        s=$(size_of "$n")
        printf '#   %-9s %8s   %s\n' "$n" "$s" "$(mounted "$s")"
    done
    printf '# /var is last with -1 so partman hands it the remainder. See the script.\n'
    printf 'd-i partman-auto/expert_recipe string \\\n'
    printf '\tboot-root :: \\\n'
    printf '\t%s %s %s free \\\n' "$BIOS_MB" "$BIOS_MB" "$BIOS_MB"
    # shellcheck disable=SC2016  # partman syntax, not shell
    printf '\t$primary{ } \\\n'
    # shellcheck disable=SC2016  # partman syntax, not shell
    printf '\t$bios_boot{ } \\\n'
    printf '\tmethod{ biosgrub } \\\n'
    printf '\t. \\\n'
    printf '\t%s %s %s ext4 \\\n' "$BOOT_MB" "$BOOT_MB" "$BOOT_MB"
    # shellcheck disable=SC2016  # partman syntax, not shell
    printf '\t$primary{ } $bootable{ } \\\n'
    printf '\tmethod{ format } format{ } \\\n'
    printf '\tuse_filesystem{ } filesystem{ ext4 } \\\n'
    printf '\tmountpoint{ /boot } \\\n'
    printf '\t. \\\n'
    s=$(size_of root)
    recipe_stanza root "$s" "$s" "$s" ext4 /
    printf '\t. \\\n'
    s=$(size_of swap)
    recipe_stanza swap "$s" "$s" "$s" linux-swap ''
    printf '\t. \\\n'
    s=$(size_of home)
    recipe_stanza home "$s" "$s" "$s" ext4 /home
    printf '\t. \\\n'
    s=$(size_of opt)
    recipe_stanza opt "$s" "$s" "$s" ext4 /opt
    printf '\t. \\\n'
    s=$(size_of srv)
    recipe_stanza srv "$s" "$s" "$s" ext4 /srv
    printf '\t. \\\n'
    s=$(size_of tmp)
    recipe_stanza tmp "$s" "$s" "$s" ext4 /tmp
    printf '\t. \\\n'
    s=$(size_of var-log)
    recipe_stanza var-log "$s" "$s" "$s" ext4 /var/log
    printf '\t. \\\n'
    # min = floor so partman rounding can never make the recipe unsatisfiable;
    # priority = what the model computed; max = -1 = the remainder.
    recipe_stanza var "$VAR_FLOOR" "$VAR" -1 ext4 /var
    printf '\t.\n'
    printf '# ── RECIPE-END ───────────────────────────────────────────────────────────────\n'
}

case "$MODE" in
--recipe) emit_recipe ;;
--table) emit_table ;;
# One "name=MB" per line, the same numbers the recipe uses. This is what the
# feature fit check reads, so the two can never disagree about a size.
--sizes)
    printf '%s\n' "$SIZES"
    printf 'boot=%s\n' "$BOOT_MB"
    ;;
*)
    echo "usage: $0 --recipe | --table | --sizes   (env: SIZE_B2B, DISK_SIZE_MB, VM_RAM_MB)" >&2
    exit 2
    ;;
esac
