#!/usr/bin/env hellish
# Pick what goes in the guest, with the disk resizing under you as you pick.
#
# WHY THIS EXISTS
# ---------------
# generate/feature_profile.sh decides the feature set from SIZE_B2B alone:
# 8-14 GB is minimal, 15-29 standard, 30+ full. That is a good default and a
# bad policy. Giving the disk more room silently installed more software --
# ask for 30 GB because you want space for containers and you also got Claude
# Code, Docker, a web stack and a Python toolchain you never asked about. Size
# is a statement about the disk, not consent to fill it.
#
# So this inverts it. The strict minimum -- the `base` tier, everything
# Born2beRoot mandates plus the editor and the shell -- is not negotiable and
# is not a question. Everything else starts OFF and is a line you tick.
#
# AND THE DISK FOLLOWS THE CHOICE, not the other way round. Refusing a set
# because it is 30 MB over is the tail wagging the dog: the volumes are LVM
# logical volumes carved from one number by partition_recipe.sh, so if the set
# does not fit, the honest answer is to grow the disk and say by how much.
# Every tick re-derives the smallest SIZE_B2B at or above your floor that holds
# the set, and every bar redraws at that size. Untick and it shrinks back --
# that is the half people forget, and a picker that only grows punishes you for
# exploring. `g` pins the disk instead, for when the floor is a hard quota (the
# 15 GB one at school) and overflowing has to be a refusal.
#
# HOW THE NUMBERS ARE GOT
#   The manifest, its NOT_INSTALLED reservations, USABLE_PERMILLE and the tier
#   thresholds are all read out of feature_profile.sh, and the volume sizes
#   come from partition_recipe.sh --sizes. Nothing here is a second copy of
#   either; only the summation is local.
#
# WHY THE HOT PATH FORKS NOTHING
#   The first version of this screen looked right and hung. Growing the disk
#   probes up to ~190 sizes, each summing ~17 manifest rows over 4 mounts, and
#   every one of those lookups was an awk, a tr or a $( ) -- tens of thousands
#   of processes for ONE keypress. So the manifest is parsed once into shell
#   variables, keys are underscored with ${v//-/_} rather than tr, values are
#   read with eval-assign rather than command substitution, and each disk
#   size's layout is parsed once and memoised. After that a keystroke is
#   arithmetic.
#
# WHAT IT WRITES
#   .b2b-features at the repo root: the size it settled on and the FEATURES
#   string. feature_profile.sh reads it when FEATURES is unset, so `make
#   features`, the preflight check and the ISO's features.conf all agree
#   without anything being threaded between them.
#
# WHEN IT DOES NOT RUN
#   Only a terminal gets asked. No tty, FEATURES/PROFILE already set, or
#   B2B_NO_SELECT=1 -- CI, `make -n`, a scripted rebuild -- and this is skipped
#   and the size-based default stands. A build that blocks on a prompt nobody
#   can see is worse than a build that chose for you.
#
# USAGE
#   generate/feature_select.sh            interactive; writes .b2b-features
#   generate/feature_select.sh --show     print the saved selection, if any
#   generate/feature_select.sh --clear    forget it, back to size-based

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FP="$HERE/feature_profile.sh"
RECIPE="$HERE/partition_recipe.sh"
SEL_FILE="${B2B_SELECT_FILE:-$ROOT/.b2b-features}"
SH="${SCRIPT_SH:-bash}"

SIZE_FLOOR="${SIZE_B2B:-15}"
VM_RAM_MB="${VM_RAM_MB:-2048}"
AUTOGROW=1
MAX_GROW_GB="${MAX_GROW_GB:-120}"
MIN_FLOOR_GB=8

# ── What the host can actually give, measured once ──────────────────────────
# Growing the guest's volumes is only half the question: the disk they are
# carved from is a file on the host, and a picker that offers 120 GB on a
# filesystem with 40 free is offering a failed build. So the host's free space
# is read here and shown on every frame beside the guest's bars -- the number
# that moves when you tick something, next to the ceiling it is moving toward.
#
# df, not du: this runs on every keystroke's worth of arithmetic budget, and
# the free-space figure is the one that matters. The precise accounting of
# what the project already costs is space_budget.sh's job, and it runs on the
# way into the build with the size this picker chose.
#
# ~4 GB is reserved for the ISOs and the extraction tree, which exist at the
# same time as the disk during a build -- the same allowance space_budget.sh
# makes, so the picker cannot green-light a size the pre-flight then refuses.
HOST_DIR="${VM_PATH:-$ROOT/disk_images}"
[ -d "$HOST_DIR" ] || HOST_DIR="$ROOT"
HOST_FREE_GB=$(df -Pk "$HOST_DIR" 2>/dev/null |
    awk 'NR == 2 { printf "%d", ($4 / 1048576) - 4; exit }')
case "$HOST_FREE_GB" in
'' | -*) HOST_FREE_GB=0 ;;
esac
# An existing disk for this VM is space the build reuses rather than needs.
HOST_HAVE_GB=$(du -sk "$HOST_DIR/${VM_NAME:-debian}" 2>/dev/null |
    awk '{ printf "%d", $1 / 1048576; exit }')
[ -n "$HOST_HAVE_GB" ] || HOST_HAVE_GB=0
HOST_CAP_GB=$((HOST_FREE_GB + HOST_HAVE_GB))
if [ "$HOST_CAP_GB" -gt 0 ] && [ "$MAX_GROW_GB" -gt "$HOST_CAP_GB" ]; then
    MAX_GROW_GB="$HOST_CAP_GB"
fi

C_R=$(printf '\033[0m')
C_B=$(printf '\033[1m')
C_DIM=$(printf '\033[2m')
C_GRN=$(printf '\033[32m')
C_YEL=$(printf '\033[33m')
C_RED=$(printf '\033[31m')
C_CYA=$(printf '\033[36m')

case "${1:---select}" in
--show)
    if [ -f "$SEL_FILE" ]; then
        cat "$SEL_FILE"
    else
        echo "no saved selection ($SEL_FILE)"
    fi
    exit 0
    ;;
--clear)
    rm -f "$SEL_FILE"
    echo "forgot $SEL_FILE — back to the size-based default"
    exit 0
    ;;
--select) ;;
*)
    echo "usage: $0 [--select | --show | --clear]" >&2
    exit 2
    ;;
esac

# ── Should we ask at all? ───────────────────────────────────────────────────
if [ "${B2B_NO_SELECT:-0}" = "1" ]; then
    exit 0
fi
# A caller that ran `make all FEATURES=...` has stated a choice and must not be
# second-guessed by a prompt.
if [ -n "${FEATURES:-}" ]; then
    exit 0
fi
if [ -n "${PROFILE:-}" ] && [ "$PROFILE" != "auto" ]; then
    exit 0
fi
if [ ! -t 0 ] || [ ! -t 1 ]; then
    exit 0
fi

# ── Everything below comes out of feature_profile.sh ────────────────────────
NOT_INSTALLED=$(sed -n "s/^NOT_INSTALLED='\(.*\)'/\1/p" "$FP")
PERMILLE=$(sed -n 's/^USABLE_PERMILLE=\([0-9]*\).*/\1/p' "$FP" | head -n1)
STANDARD_FROM=$(sed -n 's/^STANDARD_FROM_GB=\([0-9]*\).*/\1/p' "$FP" | head -n1)
FULL_FROM=$(sed -n 's/^FULL_FROM_GB=\([0-9]*\).*/\1/p' "$FP" | head -n1)
[ -n "$PERMILLE" ] || PERMILLE=744
[ -n "$STANDARD_FROM" ] || STANDARD_FROM=15
[ -n "$FULL_FROM" ] || FULL_FROM=30

# Parsed ONCE into variables. Keys are the names with hyphens underscored,
# because a hyphen is not legal in a variable name.
ALL_KEYS=""
OPT_KEYS=""
# shellcheck disable=SC2034  # c1..c4 and req are consumed by the eval below
while read -r n tier c1 c2 c3 c4 req; do
    case "$n" in '' | ai-*) continue ;; esac
    k=${n//-/_}
    eval "NAME_${k}=\$n TIER_${k}=\$tier REQ_${k}=\$req COST_${k}=\"\$c1 \$c2 \$c3 \$c4\""
    ALL_KEYS="${ALL_KEYS}${ALL_KEYS:+ }$k"
    case "$tier" in base) continue ;; esac
    case " $NOT_INSTALLED " in *" $n "*) continue ;; esac
    eval "OPT_${k}=1"
    OPT_KEYS="${OPT_KEYS}${OPT_KEYS:+ }$k"
done <<MANIEOF
$(sed -n "/^MANIFEST='/,/^'/p" "$FP" | awk 'NF == 7')
MANIEOF
[ -n "$OPT_KEYS" ] || exit 0

COUNT=0
for k in $OPT_KEYS; do
    COUNT=$((COUNT + 1))
done

# ── Selection state, keyed the same way ─────────────────────────────────────
CHOSEN=""
is_chosen() {
    case " $CHOSEN " in *" $1 "*) return 0 ;; esac
    return 1
}
choose() {
    is_chosen "$1" || CHOSEN="${CHOSEN}${CHOSEN:+ }$1"
}
unchoose() {
    local out="" x
    for x in $CHOSEN; do
        [ "$x" = "$1" ] || out="${out}${out:+ }$x"
    done
    CHOSEN="$out"
}
is_opt_key() {
    local v
    eval "v=\${OPT_$1-}"
    [ -n "$v" ]
}
tier_on_at() { # <tier> <gb>
    case "$1" in
    base) return 0 ;;
    standard) [ "$2" -ge "$STANDARD_FROM" ] && return 0 ;;
    full) [ "$2" -ge "$FULL_FROM" ] && return 0 ;;
    esac
    return 1
}

# ── The layout for a size, parsed once per size ─────────────────────────────
S_ROOT=0
S_OPT=0
S_VAR=0
S_HOME=0
S_SWAP=0
S_BOOT=0
load_sizes() { # <gb>
    local gb="$1" cached raw name val
    eval "cached=\${SZC_$gb-}"
    if [ -z "$cached" ]; then
        raw=$(SIZE_B2B="$gb" DISK_SIZE_MB=$((gb * 1024)) VM_RAM_MB="$VM_RAM_MB" \
            "$SH" "$RECIPE" --sizes 2>/dev/null)
        while read -r line; do
            case "$line" in *=*) ;; *) continue ;; esac
            name=${line%%=*}
            # shellcheck disable=SC2034  # read back through eval, per size
            val=${line#*=}
            case "$name" in
            root | opt | var | home | swap | boot)
                eval "SZ_${name}_${gb}=\$val"
                ;;
            esac
        done <<SZEOF
$raw
SZEOF
        eval "SZC_$gb=1"
    fi
    eval "S_ROOT=\${SZ_root_$gb:-0} S_OPT=\${SZ_opt_$gb:-0}"
    eval "S_VAR=\${SZ_var_$gb:-0} S_HOME=\${SZ_home_$gb:-0}"
    eval "S_SWAP=\${SZ_swap_$gb:-0} S_BOOT=\${SZ_boot_$gb:-0}"
    S_ROOT=$((S_ROOT * PERMILLE / 1000))
    S_OPT=$((S_OPT * PERMILLE / 1000))
    S_VAR=$((S_VAR * PERMILLE / 1000))
    S_HOME=$((S_HOME * PERMILLE / 1000))
}

# ── What the set costs at a size ────────────────────────────────────────────
NEED_ROOT=0
NEED_OPT=0
NEED_VAR=0
NEED_HOME=0
compute_need() { # <gb>
    local gb="$1" k tier req rk
    NEED_ROOT=0
    NEED_OPT=0
    NEED_VAR=0
    NEED_HOME=0
    for k in $ALL_KEYS; do
        eval "tier=\$TIER_$k"
        if [ "$tier" != base ]; then
            if is_opt_key "$k"; then
                is_chosen "$k" || continue
            else
                # a reservation: gated by its tier AND by its dependency
                tier_on_at "$tier" "$gb" || continue
                eval "req=\$REQ_$k"
                if [ "$req" != "-" ]; then
                    rk=${req//-/_}
                    if is_opt_key "$rk" && ! is_chosen "$rk"; then
                        continue
                    fi
                fi
            fi
        fi
        # shellcheck disable=SC2086  # exactly four numeric fields, split on purpose
        eval "set -- \$COST_$k"
        NEED_ROOT=$((NEED_ROOT + $1))
        NEED_OPT=$((NEED_OPT + $2))
        NEED_VAR=$((NEED_VAR + $3))
        NEED_HOME=$((NEED_HOME + $4))
    done
}

fits_at() { # <gb>
    compute_need "$1"
    load_sizes "$1"
    [ "$NEED_ROOT" -le "$S_ROOT" ] || return 1
    [ "$NEED_OPT" -le "$S_OPT" ] || return 1
    [ "$NEED_VAR" -le "$S_VAR" ] || return 1
    [ "$NEED_HOME" -le "$S_HOME" ] || return 1
    return 0
}

SIZE_GB="$SIZE_FLOOR"
FITS=1
resize() {
    local g
    if [ "$AUTOGROW" != 1 ]; then
        SIZE_GB="$SIZE_FLOOR"
        if fits_at "$SIZE_GB"; then FITS=1; else FITS=0; fi
        compute_need "$SIZE_GB"
        load_sizes "$SIZE_GB"
        return 0
    fi
    g="$SIZE_FLOOR"
    while [ "$g" -le "$MAX_GROW_GB" ]; do
        if fits_at "$g"; then
            SIZE_GB="$g"
            FITS=1
            return 0
        fi
        g=$((g + 1))
    done
    SIZE_GB="$SIZE_FLOOR"
    FITS=0
    compute_need "$SIZE_GB"
    load_sizes "$SIZE_GB"
}

# ── Dependencies, so a tick can never build a set the checker refuses ───────
resolve_deps() {
    local changed=1 k req rk
    while [ "$changed" = 1 ]; do
        changed=0
        for k in $OPT_KEYS; do
            is_chosen "$k" || continue
            eval "req=\$REQ_$k"
            [ "$req" = "-" ] && continue
            rk=${req//-/_}
            is_opt_key "$rk" || continue
            is_chosen "$rk" && continue
            choose "$rk"
            changed=1
        done
    done
}
cascade_off() {
    local changed=1 k req rk
    while [ "$changed" = 1 ]; do
        changed=0
        for k in $OPT_KEYS; do
            is_chosen "$k" || continue
            eval "req=\$REQ_$k"
            [ "$req" = "-" ] && continue
            rk=${req//-/_}
            is_opt_key "$rk" || continue
            is_chosen "$rk" && continue
            unchoose "$k"
            changed=1
        done
    done
}
apply_default() {
    local k tier
    CHOSEN=""
    for k in $OPT_KEYS; do
        eval "tier=\$TIER_$k"
        tier_on_at "$tier" "$SIZE_FLOOR" && choose "$k"
    done
    resolve_deps
}
apply_all() {
    local k
    CHOSEN=""
    for k in $OPT_KEYS; do
        choose "$k"
    done
    resolve_deps
}

# ── Drawing ─────────────────────────────────────────────────────────────────
BAR_W=22
bar() { # <used> <cap>
    local used="$1" cap="$2" filled i out="" col
    [ "$cap" -gt 0 ] || cap=1
    filled=$((used * BAR_W / cap))
    [ "$filled" -gt "$BAR_W" ] && filled=$BAR_W
    [ "$filled" -lt 0 ] && filled=0
    if [ "$used" -gt "$cap" ]; then
        col="$C_RED"
    elif [ $((used * 100 / cap)) -ge 90 ]; then
        col="$C_YEL"
    else
        col="$C_GRN"
    fi
    i=0
    while [ "$i" -lt "$filled" ]; do
        out="${out}#"
        i=$((i + 1))
    done
    while [ "$i" -lt "$BAR_W" ]; do
        out="${out}."
        i=$((i + 1))
    done
    printf '%s%s%s' "$col" "$out" "$C_R"
}
blurb() {
    case "$1" in
    webstack) echo "lighttpd + MariaDB + PHP + WordPress (the bonus)" ;;
    nodejs) echo "Node and the npm globals" ;;
    pytools) echo "pipx tools (ruff, ...)" ;;
    nvim-extras) echo "nvim IDE layer + Excalidraw + markdown/mermaid preview" ;;
    devtools-extra) echo "Herdr persistent panes + opencode" ;;
    claude-code) echo "Claude Code, beside opencode" ;;
    docker) echo "Docker engine (Inception needs it)" ;;
    *) echo "" ;;
    esac
}

CURSOR=1
# shellcheck disable=SC2120  # the `set --` inside is eval'd cost fields, not args
draw() {
    local k i name tier disk
    printf '\033[H\033[2J'
    if [ "$SIZE_GB" -ne "$SIZE_FLOOR" ]; then
        disk="${C_CYA}${SIZE_FLOOR} -> ${SIZE_GB} GB${C_R} ${C_DIM}(grown to fit)${C_R}"
    elif [ "$AUTOGROW" != 1 ]; then
        disk="${C_B}${SIZE_GB} GB${C_R} ${C_DIM}(pinned, g to unpin)${C_R}"
    else
        disk="${C_B}${SIZE_GB} GB${C_R}"
    fi
    printf '\n  %sWhat goes in the VM%s                            disk %b\n\n' "$C_B" "$C_R" "$disk"
    printf '      %s[x]%s %-15s %s%s%s\n\n' "$C_GRN" "$C_R" "the strict minimum" \
        "$C_DIM" "Born2beRoot, nvim, hellish - always installed" "$C_R"
    printf '      %s%-15s     /  /opt  /var /home MB%s\n' "$C_DIM" "" "$C_R"

    i=1
    for k in $OPT_KEYS; do
        eval "name=\$NAME_$k tier=\$TIER_$k"
        if [ "$i" = "$CURSOR" ]; then
            printf '  %s>%s ' "$C_CYA" "$C_R"
        else
            printf '    '
        fi
        if is_chosen "$k"; then
            printf '%s[x]%s ' "$C_GRN" "$C_R"
        else
            printf '%s[ ]%s ' "$C_DIM" "$C_R"
        fi
        # shellcheck disable=SC2086
        eval "set -- \$COST_$k"
        printf '%-15s %5s %5s %5s %5s  %s%s%s\n' "$name" "$1" "$2" "$3" "$4" \
            "$C_DIM" "$(blurb "$name")" "$C_R"
        i=$((i + 1))
    done

    printf '\n'
    printf '    %-6s %b %5s / %-5s\n' "/" "$(bar "$NEED_ROOT" "$S_ROOT")" "$NEED_ROOT" "$S_ROOT"
    printf '    %-6s %b %5s / %-5s\n' "/opt" "$(bar "$NEED_OPT" "$S_OPT")" "$NEED_OPT" "$S_OPT"
    printf '    %-6s %b %5s / %-5s\n' "/var" "$(bar "$NEED_VAR" "$S_VAR")" "$NEED_VAR" "$S_VAR"
    printf '    %-6s %b %5s / %-5s\n' "/home" "$(bar "$NEED_HOME" "$S_HOME")" "$NEED_HOME" "$S_HOME"
    printf '\n'
    if [ "$FITS" = 1 ]; then
        printf '    %s* fits%s  %sswap %s MB, /boot %s MB, 20%% of each volume kept free%s\n' \
            "$C_GRN" "$C_R" "$C_DIM" "$S_SWAP" "$S_BOOT" "$C_R"
    else
        printf '    %s* does not fit at %s GB (pinned) - untick something, or press g%s\n' \
            "$C_RED" "$SIZE_GB" "$C_R"
    fi
    # The guest's volumes above, the host's disk below, on the same screen.
    # Growing to hold a ticked feature spends host space, and finding that out
    # from the pre-flight after the picker said "fits" is the confusing order
    # to learn it in.
    if [ "$HOST_CAP_GB" -gt 0 ]; then
        if [ "$SIZE_GB" -gt "$HOST_CAP_GB" ]; then
            printf '    %s* %s has room for %s GB, and this asks for %s%s\n' \
                "$C_RED" "$HOST_DIR" "$HOST_CAP_GB" "$SIZE_GB" "$C_R"
        else
            printf '    %shost%s   %b %2s / %-3s GB %sfree on %s%s\n' \
                "$C_DIM" "$C_R" "$(bar "$SIZE_GB" "$HOST_CAP_GB")" \
                "$SIZE_GB" "$HOST_CAP_GB" "$C_DIM" "$HOST_DIR" "$C_R"
        fi
    fi
    printf '\n    %sarrows%s move  %sspace%s tick  %sa%s all  %sd%s default  %sn%s none  %sg%s grow=%s  %s+/-%s floor  %sEnter%s build  %sq%s quit\n' \
        "$C_DIM" "$C_R" "$C_DIM" "$C_R" "$C_DIM" "$C_R" "$C_DIM" "$C_R" "$C_DIM" "$C_R" "$C_DIM" "$C_R" \
        "$(if [ "$AUTOGROW" = 1 ]; then echo on; else echo off; fi)" \
        "$C_DIM" "$C_R" "$C_DIM" "$C_R" "$C_DIM" "$C_R"
}

# ── Raw-mode key reading ────────────────────────────────────────────────────
STTY_SAVE=$(stty -g 2>/dev/null || echo "")
restore() {
    [ -n "$STTY_SAVE" ] && stty "$STTY_SAVE" 2>/dev/null
    printf '\033[?25h'
}
trap 'restore; exit 130' INT TERM
trap restore EXIT
stty -echo -icanon min 1 time 0 2>/dev/null
printf '\033[?25l'

ESC=$(printf '\033')
read_key() {
    local k rest
    k=$(dd bs=1 count=1 2>/dev/null)
    if [ -z "$k" ]; then
        printf 'ENTER'
        return 0
    fi
    if [ "$k" = "$ESC" ]; then
        rest=$(dd bs=1 count=2 2>/dev/null)
        case "$rest" in
        '[A') printf 'UP' ;;
        '[B') printf 'DOWN' ;;
        *) printf 'ESC' ;;
        esac
        return 0
    fi
    printf '%s' "$k"
}

# ── Loop ────────────────────────────────────────────────────────────────────
resize
while :; do
    draw
    key=$(read_key)
    case "$key" in
    UP | k)
        [ "$CURSOR" -gt 1 ] && CURSOR=$((CURSOR - 1))
        ;;
    DOWN | j)
        [ "$CURSOR" -lt "$COUNT" ] && CURSOR=$((CURSOR + 1))
        ;;
    ' ' | x)
        i=1
        for k in $OPT_KEYS; do
            if [ "$i" = "$CURSOR" ]; then
                if is_chosen "$k"; then
                    unchoose "$k"
                    cascade_off
                else
                    choose "$k"
                    resolve_deps
                fi
                break
            fi
            i=$((i + 1))
        done
        resize
        ;;
    a)
        apply_all
        resize
        ;;
    d)
        apply_default
        resize
        ;;
    n)
        CHOSEN=""
        resize
        ;;
    g)
        if [ "$AUTOGROW" = 1 ]; then
            AUTOGROW=0
        else
            AUTOGROW=1
        fi
        resize
        ;;
    '+' | '=')
        SIZE_FLOOR=$((SIZE_FLOOR + 1))
        resize
        ;;
    '-')
        [ "$SIZE_FLOOR" -gt "$MIN_FLOOR_GB" ] && SIZE_FLOOR=$((SIZE_FLOOR - 1))
        resize
        ;;
    ENTER)
        [ "$FITS" = 1 ] && break
        ;;
    q | Q)
        exit 130
        ;;
    *) ;;
    esac
done
restore
printf '\033[H\033[2J'

# ── Save ────────────────────────────────────────────────────────────────────
# The ticks as a diff against what the tiers would pick AT THE SIZE WE SETTLED
# ON, not at the floor: growing the disk can switch a tier on by itself, and a
# diff computed against the old size would re-add what was never ticked.
features_str() {
    local k out="" name tier req rk
    for k in $OPT_KEYS; do
        eval "name=\$NAME_$k tier=\$TIER_$k"
        if is_chosen "$k"; then
            tier_on_at "$tier" "$SIZE_GB" || out="${out}${out:+ }+${name}"
        else
            tier_on_at "$tier" "$SIZE_GB" && out="${out}${out:+ }-${name}"
        fi
    done
    for name in $NOT_INSTALLED; do
        k=${name//-/_}
        eval "tier=\${TIER_$k-}"
        [ -n "$tier" ] || continue
        tier_on_at "$tier" "$SIZE_GB" || continue
        eval "req=\$REQ_$k"
        [ "$req" = "-" ] && continue
        rk=${req//-/_}
        is_opt_key "$rk" || continue
        is_chosen "$rk" || out="${out}${out:+ }-${name}"
    done
    printf '%s' "$out"
}

{
    printf '# Written by generate/feature_select.sh - what you ticked, and the\n'
    printf '# disk it was fitted to. feature_profile.sh reads this when FEATURES\n'
    printf '# is unset; a different SIZE_B2B ignores it and you are asked again.\n'
    printf '# Forget it with: generate/feature_select.sh --clear\n'
    printf 'B2B_SELECT_SIZE_GB=%s\n' "$SIZE_GB"
    printf 'B2B_SELECT_PROFILE=auto\n'
    printf 'B2B_SELECT_FEATURES=%s\n' "$(features_str)"
} >"$SEL_FILE"

names=""
for k in $CHOSEN; do
    eval "n=\$NAME_$k"
    names="${names}${names:+,}$n"
done
printf '  %ssaved%s %s\n' "$C_GRN" "$C_R" "$SEL_FILE"
printf '  disk %s GB — the strict minimum%s\n' "$SIZE_GB" "${names:+ + $names}"
if [ "$SIZE_GB" -ne "${SIZE_B2B:-15}" ]; then
    printf '  %sthe disk grew to hold this set. Build it with:%s make all SIZE_B2B=%s\n' \
        "$C_YEL" "$C_R" "$SIZE_GB"
fi
printf '\n'
