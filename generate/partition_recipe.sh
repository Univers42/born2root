#!/usr/bin/env hellish
# Derive the guest's partition layout from one number.
#
# The recipe in preseeds/preseed.cfg.in used to be eight hand-typed sizes. That
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
# The volume with share `rest` (/var by default) is declared LAST with -1,
# which turns partman's habit of inflating the last volume to fill the group
# (measured; see preseed.cfg.in) into the mechanism that puts the leftover
# where it is wanted. Nothing is formatted to be thrown away, and the group
# ends up fully allocated by design.
#
# swap follows RAM, not disk: clamp(VM_RAM_MB, 1 GB, 4 GB), and never more than
# a quarter of the group, so a tiny disk is not half swap. B2B_SWAP_MB=<MB> in
# born2root.toml pins it instead.
#
# WHICH volumes exist, and their floors, shares and caps, is born2root.toml's
# [disk] volumes table (read through utils/b2b_config.sh). Nothing below names a
# volume: a table without /opt gets a recipe without /opt, and `holder:` in
# --sizes tells the fit check that /opt's costs now land on /.
#
# Below the minimum this exits 1 and names the size that would work. It never
# emits a recipe the installer would reject.
#
#   generate/partition_recipe.sh --recipe     the d-i expert_recipe block, with markers
#   generate/partition_recipe.sh --table      the layout, for humans (make partitions)
#   generate/partition_recipe.sh --sizes      "name=MB" per volume, then boot= and
#                                             "holder:<mount>=<volume>" for the four
#                                             mounts feature_profile.sh prices
#
# Env
#   SIZE_B2B (15)         whole-disk size in GB
#   DISK_SIZE_MB          same thing in MB; wins over SIZE_B2B when both are set,
#                         because the Makefile derives it and forwards it
#   VM_RAM_MB (2048)      what the guest boots with; sizes swap
#   B2B_CONFIG            the born2root.toml to read (tests point it at fixtures)

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../utils/b2b_config.sh
. "$HERE/../utils/b2b_config.sh"

# ── The model ───────────────────────────────────────────────────────────────
BIOS_MB=1      # bios_boot, for GRUB on a GPT/MBR hybrid
BOOT_MB=500    # /boot, unencrypted, a few kernels
OVERHEAD_MB=20 # LUKS2 header (16 MB) plus LVM physical-extent rounding

# The default table in born2root.toml, and why its numbers are what they are:
#
# name  floor  share%  cap      (var has no share and no cap: it takes the rest)
# home's floor and weight were raised after checking the install against the
# layout (generate/feature_profile.sh): at 8 GB kickstart.nvim's plugins and
# tree-sitter parsers (~300 MB) did not fit a 256 MB /home, and at 15 GB the
# IDE layer was within 100 MB of full. tmp gave up 128 MB so the 8 GB minimum
# still holds.
# Calibrated on the first real build (2026-09-11): / held 2.7 GB before nvim
# on a 3.3 GB root, so root's floor and share went up and home/opt/tmp gave
# some back. See generate/feature_profile.sh for the per-feature numbers.
#
# home's weight went 9 -> 18 on 2026-09-12, from a built guest with /home
# 100% FULL (974 MB, 0 available). The model only ever charged /home for
# Neovim's plugins; `du` on the real thing found three consumers nobody had
# budgeted, all of them part of this VM's documented workflow:
#
#   .vscode-server   483 MB   VS Code Remote SSH, the way the README says to
#                             connect. Downloaded on first connect.
#   data/            197 MB   Inception's MariaDB + WordPress volumes: its
#                             compose file bind-mounts /home/<login>/data.
#                             deploy_inception.sh's pre-flight checked /var,
#                             where the images go, not /home, where the data
#                             does.
#   .npm              55 MB   npm's cache stays in the user's home even with
#                             the global prefix moved to /opt.
#
# A full /home is not a clean failure: git could not write a ref lock, `ssh`
# could not update known_hosts, Mason's downloads died as curl(23), and the
# Neovim bootstrap logged 132 "Installing plugins" lines and left ZERO plugins
# on disk -- vim.pack reports a failed clone as a notification, so the only
# symptom was a missing plugin. The floor stays 512: raising it would push
# MIN_DISK past 8192 and take the 8 GB minimum with it. Only the surplus share
# moves, so 8 GB is byte-identical and /var (the remainder) gives up 564 MB at
# 15 GB while keeping room for docker's 3300 MB build peak.
#
# srv's weight went 2 -> 0 in the same pass, to give some of that back. It
# keeps its floor -- the subject's bonus layout has it -- but no feature in
# the manifest charges /srv anything, and on the built guest it held 104 KB
# of a 328 MB volume. Its surplus share was the cheapest 125 MB on the disk
# to hand to /var.
#
#   root    2816  25   30720
#   home     512  18  102400
#   opt      256   5   20480
#   srv      256   0   10240
#   tmp      256   3   10240
#   var-log  384   3   20480
#   var     2048  rest     -
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

# "name mount floor share cap" per volume: the `/` volume first, the `rest`
# volume last. b2b_volumes has already refused a table partman could not
# satisfy (no /, two rests, shares past 100 %), with the line to fix.
if ! VOLUMES=$(b2b_volumes); then
    echo "partition_recipe: the [disk] volumes table in ${B2B_CONFIG} is invalid (see above; make config)" >&2
    exit 1
fi
SWAP_CFG=$(b2b_get B2B_SWAP_MB)
[ -n "$SWAP_CFG" ] || SWAP_CFG=auto
case "$SWAP_CFG" in
auto) ;;
*[!0-9]*)
    echo "partition_recipe: B2B_SWAP_MB must be auto or a number of MB (got '${SWAP_CFG}')" >&2
    exit 1
    ;;
esac

# ── Arithmetic ──────────────────────────────────────────────────────────────
RESERVED=$((BIOS_MB + BOOT_MB + OVERHEAD_MB))
AVAIL=$((DISK_MB - RESERVED))

FLOORS=$(printf '%s\n' "$VOLUMES" | awk '{ s += $3 } END { print s + 0 }')

# swap: RAM-derived, clamped, then bounded by what the disk can spare. The
# last bound is what lets an 8 GB disk work at all: with 2 GB of RAM the RAM
# rule alone would ask for more than the floors leave. A pinned B2B_SWAP_MB
# skips the RAM rule and the quarter-of-the-group cap -- it was asked for --
# and is refused rather than shrunk when the disk cannot give it.
if [ "$SWAP_CFG" = auto ]; then
    SWAP=$VM_RAM_MB
    [ "$SWAP" -lt "$SWAP_MIN_MB" ] && SWAP=$SWAP_MIN_MB
    [ "$SWAP" -gt "$SWAP_MAX_MB" ] && SWAP=$SWAP_MAX_MB
    [ "$SWAP" -gt $((AVAIL / 4)) ] && SWAP=$((AVAIL / 4))
else
    SWAP=$SWAP_CFG
    SWAP_MIN_MB=$SWAP_CFG
fi
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
# Size every pinned volume, then hand the `rest` volume whatever is left.
# swap goes right after the `/` volume, which is the order the recipe has
# always had, so the default table reproduces it byte for byte.
SIZES=""
OTHERS=$SWAP
REST_NAME=""
REST_MOUNT=""
REST_FLOOR=0
while read -r name mount floor share cap; do
    [ -n "$name" ] || continue
    if [ "$share" = rest ]; then
        REST_NAME=$name
        REST_MOUNT=$mount
        REST_FLOOR=$floor
        continue
    fi
    size=$((floor + SURPLUS * share / 100))
    if [ "$cap" != - ] && [ "$size" -gt "$cap" ]; then
        size=$cap
    fi
    OTHERS=$((OTHERS + size))
    SIZES="${SIZES}${SIZES:+$NL}$name=$size"
    [ "$mount" = / ] && SIZES="${SIZES}${NL}swap=$SWAP"
done <<EOF
$VOLUMES
EOF
REST=$((AVAIL - OTHERS))
SIZES="${SIZES}${NL}$REST_NAME=$REST"

# The emit order, with swap in its place: "name mount" per line.
ORDER=$(printf '%s\n' "$VOLUMES" | awk '{ print $1, $2 } $2 == "/" { print "swap [SWAP]" }')

size_of() { printf '%s\n' "$SIZES" | awk -F= -v n="$1" '$1 == n { print $2 }'; }

# The volume a path lives on: the longest configured mount that is the path
# or a directory above it. /opt with no opt volume lives on /.
holder_of() {
    printf '%s\n' "$VOLUMES" | awk -v m="$1" '
        $2 == m || $2 == "/" || index(m, $2 "/") == 1 {
            if (length($2) > best) { best = length($2); name = $1 }
        }
        END { print name }'
}

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
    while read -r n m; do
        s=$(size_of "$n")
        printf '    %-10s %10s   %-9s  %s\n' "$n" "$s" "$(mounted "$s")" "$m"
    done <<EOF
$ORDER
EOF
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
    while read -r n _; do
        s=$(size_of "$n")
        printf '#   %-9s %8s   %s\n' "$n" "$s" "$(mounted "$s")"
    done <<EOF
$ORDER
EOF
    printf '# %s is last with -1 so partman hands it the remainder. See the script.\n' "$REST_MOUNT"
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
    while read -r n m; do
        [ "$n" = "$REST_NAME" ] && continue
        s=$(size_of "$n")
        if [ "$n" = swap ]; then
            recipe_stanza swap "$s" "$s" "$s" linux-swap ''
        else
            recipe_stanza "$n" "$s" "$s" "$s" ext4 "$m"
        fi
        printf '\t. \\\n'
    done <<EOF
$ORDER
EOF
    # min = floor so partman rounding can never make the recipe unsatisfiable;
    # priority = what the model computed; max = -1 = the remainder.
    recipe_stanza "$REST_NAME" "$REST_FLOOR" "$REST" -1 ext4 "$REST_MOUNT"
    printf '\t.\n'
    printf '# ── RECIPE-END ───────────────────────────────────────────────────────────────\n'
}

case "$MODE" in
--recipe) emit_recipe ;;
--table) emit_table ;;
# One "name=MB" per line, the same numbers the recipe uses. This is what the
# feature fit check reads, so the two can never disagree about a size. The
# holder lines say which volume each priced mount lives on: its own, or the
# `/` volume's when the table has no volume for it.
--sizes)
    printf '%s\n' "$SIZES"
    printf 'boot=%s\n' "$BOOT_MB"
    for m in / /opt /var /home; do
        printf 'holder:%s=%s\n' "$m" "$(holder_of "$m")"
    done
    ;;
*)
    echo "usage: $0 --recipe | --table | --sizes   (env: SIZE_B2B, DISK_SIZE_MB, VM_RAM_MB)" >&2
    exit 2
    ;;
esac
