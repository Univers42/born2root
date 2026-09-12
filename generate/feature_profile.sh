#!/usr/bin/env hellish
# Decide what gets installed in the guest, and prove it fits BEFORE building.
#
# A partition layout that fits the disk is only half the job. The other half
# is what the provisioners then pour into it, and that used to be decided at
# runtime, inside the guest, by `check_disk_space / N` guards that printed
# [SKIP] and carried on. On a small disk nothing failed -- the VM just came up
# without nvim, or without the web stack, and nothing at build time said so.
# Worse, the order was wrong: Docker and the web stack ran before nvim, so an
# optional install could starve a required one.
#
# This script makes the choice once, on the host, from SIZE_B2B:
#
#   minimal   8-14 GB   everything Born2beRoot mandates + hellish + nvim
#   standard 15-29 GB   + the bonus web stack, Docker, node, python tools,
#                         the nvim IDE layer, Herdr + Claude Code
#   full      30+ GB    every non-explicit feature (today: same as standard;
#                         the name is stable so it can grow)
#
# PROFILE=... overrides the size-based pick, FEATURES="+docker -pytools" adds
# or removes single features, and AI_MODE=client|local turns on the two AI
# features that are never chosen automatically.
#
# Then the chosen set is CHECKED against the layout partition_recipe.sh will
# produce for the same SIZE_B2B, mount by mount, with 20% headroom. A feature
# that does not fit fails the ISO build here, naming the mount and the
# smallest SIZE_B2B that would work -- instead of a [SKIP] twenty minutes
# into an install nobody is watching.
#
# The costs are ESTIMATES, taken from the provisioners' own numbers. First
# boot records the measured df delta of every feature to /etc/b2b/features.status
# so the table can be corrected from a real run. Treat a measured number that
# is off by more than a third as a bug in this table.
#
#   feature_profile.sh --resolve    profile + feature list, one per line
#   feature_profile.sh --check      exit 1 with a reason when it does not fit
#   feature_profile.sh --conf       the /etc/b2b/features.conf body
#   feature_profile.sh --table      for humans (make features)
#
# Env
#   SIZE_B2B (15)  DISK_SIZE_MB  VM_RAM_MB (2048)   -- same as partition_recipe.sh
#   PROFILE (auto)  FEATURES ("")  AI_MODE (off)

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
RECIPE="$HERE/partition_recipe.sh"

# name              tier      /     /opt  /var  /home  requires
#
# The / column was calibrated on the first real build (SIZE_B2B=15, standard,
# 2026-09-11): / held 2.7 GB before nvim ran, which is debian-base +
# b2b-mandatory + devtools-apt + webstack packages + docker packages + node,
# to the MB. The first table had no debian-base row at all, and nvim's space
# guard tripped on a disk the check had passed. /etc/b2b/features.status on a
# built guest is where the next correction comes from.
#
# Corrected from /etc/b2b/features.status of the 2026-09-12 build (b2r,
# SIZE_B2B=15, standard, every feature ok), where a measured delta differed
# from the estimate by more than a third:
#   nvim      /     350 -> 382   the nvim section's delta was 474, of which the
#   nvim-extras /     0 -> 92    extras' apt transaction (fzf, bat, lazygit,
#                                gdb, the shell linter, ...) is 92 MB by
#                                /var/log/apt/history.log; the rest is install_nvim.sh's own
#                                apt line -- 230 MB, 377 packages, Debian's npm
#                                tree -- plus its non-apt installs. Node is paid
#                                here, by the first section that needs it;
#   nodejs    /     250 -> 17    ...which leaves the nodejs section only the
#                                globals (eslint & co.). The trio's total on /
#                                went from 600 estimated to 491 measured.
#   webstack  /var  200 -> 118   MariaDB + WordPress + PHP at install time; the
#                                database grows with use.
#   hellish   /home  40 -> 1     the binary lives on /, ~/.hellish is tiny.
# docker's /var figure stays 3300: it is the build PEAK (2.35 GB of build
# cache measured on the host), not the 178 MB the engine alone costs. nvim's
# 300 on /home and nvim-extras' 400 are still estimates: the plugin bootstrap
# left /home at 3 MB on that build, so the cost lands at first launch.
MANIFEST='
debian-base        base      1100  0     0     0      -
b2b-mandatory      base      100   0     0     0      -
devtools-apt       base      450   0     0     0      -
nvim               base      382   120   0     300    devtools-apt
hellish-upstream   base      0     0     0     1      -
webstack           standard  400   0     118   0      -
nodejs             standard  17    60    0     0      -
pytools            standard  0     80    0     0      -
nvim-extras        standard  92    0     0     400    nvim
devtools-extra     standard  0     110   0     0      nodejs
docker             standard  400   0     3300  0      -
ai-client          explicit  50    0     0     0      -
ai-local           explicit  0     1000  0     0      -
'
# ai-local's /opt cost is Ollama (~1 GB) plus the model install_ai.sh will pick
# for this much RAM. Its thresholds, mirrored here so the fit check agrees:
ai_model_mb() {
    if [ "$1" -lt 4096 ]; then
        echo 1400 # qwen3:1.7b
    elif [ "$1" -lt 8192 ]; then
        echo 2600 # qwen3:4b
    elif [ "$1" -lt 12288 ]; then
        echo 5000      # qwen3:8b
    else echo 9000; fi # qwen3:14b
}

# With the 2026-09-12 costs the model puts the standard set inside 14 GB, but
# by under 5% on every mount (/ 2941 of 3069 usable, /home 701 of 731) and
# with nvim's /home figure still an estimate. The automatic pick therefore
# stays at 15 -- an explicit PROFILE=standard at 14 passes the fit check and
# is allowed -- until a 14 GB build confirms the margin. 15 fits with room.
STANDARD_FROM_GB=15
FULL_FROM_GB=30
# Usable fraction of a volume: ext4 shows ~93% of the partman figure, and 20%
# of that is kept free so apt lists, logs and a busy Docker do not wedge it.
USABLE_PERMILLE=744

# ── Inputs ──────────────────────────────────────────────────────────────────
MODE="${1:---table}"
VM_RAM_MB="${VM_RAM_MB:-2048}"
[ -n "$VM_RAM_MB" ] || VM_RAM_MB=2048
if [ -n "${DISK_SIZE_MB:-}" ]; then
    DISK_MB="$DISK_SIZE_MB"
else
    DISK_MB=$((${SIZE_B2B:-15} * 1024))
fi
SIZE_GB=$((DISK_MB / 1024))
PROFILE="${PROFILE:-auto}"
FEATURES="${FEATURES:-}"
AI_MODE="${AI_MODE:-off}"
case "$AI_MODE" in off | client | local) ;; *)
    echo "feature_profile: AI_MODE must be off, client or local (got '$AI_MODE')" >&2
    exit 1
    ;;
esac

die() {
    printf 'feature_profile: %s\n' "$*" >&2
    exit 1
}

names() { printf '%s\n' "$MANIFEST" | awk 'NF == 7 { print $1 }'; }
field() { printf '%s\n' "$MANIFEST" | awk -v n="$1" -v c="$2" 'NF == 7 && $1 == n { print $c }'; }
known() { names | grep -qx -- "$1"; }
varname() { printf 'B2B_FEATURE_%s' "$(printf '%s' "$1" | tr '-' '_')"; }

# ── 1. Which profile ────────────────────────────────────────────────────────
case "$PROFILE" in
auto)
    if [ "$SIZE_GB" -ge "$FULL_FROM_GB" ]; then
        PROFILE=full
    elif [ "$SIZE_GB" -ge "$STANDARD_FROM_GB" ]; then
        PROFILE=standard
    else PROFILE=minimal; fi
    ;;
minimal | standard | full) ;;
*) die "PROFILE must be auto, minimal, standard or full (got '$PROFILE')" ;;
esac

# A literal newline: $'\n' is not portable to every shell this runs under.
NL='
'
# ── 2. Which features ───────────────────────────────────────────────────────
# State is a space-separated list of "name=on|off", built in manifest order.
STATE=""
for n in $(names); do
    tier=$(field "$n" 2)
    case "$tier" in
    base) on=on ;;
    standard) if [ "$PROFILE" = minimal ]; then on=off; else on=on; fi ;;
    explicit) on=off ;;
    esac
    STATE="${STATE}${STATE:+$NL}$n=$on"
done
set_state() { STATE=$(printf '%s\n' "$STATE" | awk -F= -v n="$1" -v v="$2" '$1 == n { $0 = n "=" v } { print }'); }
is_on() { printf '%s\n' "$STATE" | grep -qx -- "$1=on"; }

case "$AI_MODE" in
client) set_state ai-client on ;;
local) set_state ai-local on ;;
esac

# +name / -name overrides. A base feature cannot be removed: that is the
# definition of base, and a VM without sudo or without nvim is not a smaller
# born2root, it is a different project.
for tok in $FEATURES; do
    case "$tok" in
    +*)
        n=${tok#+}
        known "$n" || die "FEATURES: unknown feature '$n' (see --table)"
        set_state "$n" on
        ;;
    -*)
        n=${tok#-}
        known "$n" || die "FEATURES: unknown feature '$n' (see --table)"
        [ "$(field "$n" 2)" = base ] && die "FEATURES: '$n' is a base feature and cannot be turned off"
        set_state "$n" off
        ;;
    *) die "FEATURES entries look like +docker or -pytools (got '$tok')" ;;
    esac
done

# Dependencies are enforced, not silently satisfied. Turning on Claude Code
# and turning off node is a contradiction the person should see, not a
# surprise install of node they asked not to have.
for n in $(names); do
    is_on "$n" || continue
    req=$(field "$n" 7)
    [ "$req" = - ] && continue
    is_on "$req" || die "'$n' requires '$req', which is off. Add +$req to FEATURES, or drop $n."
done

# ── 3. Does it fit ──────────────────────────────────────────────────────────
# Costs per mount for the chosen set. ai-local's /opt figure depends on RAM.
cost_of() { # $1 feature  $2 column (3=/ 4=/opt 5=/var 6=/home)
    c=$(field "$1" "$2")
    if [ "$1" = ai-local ] && [ "$2" = 4 ]; then
        c=$((c + $(ai_model_mb "$VM_RAM_MB")))
    fi
    printf '%s' "$c"
}
NEED_ROOT=0
NEED_OPT=0
NEED_VAR=0
NEED_HOME=0
for n in $(names); do
    is_on "$n" || continue
    NEED_ROOT=$((NEED_ROOT + $(cost_of "$n" 3)))
    NEED_OPT=$((NEED_OPT + $(cost_of "$n" 4)))
    NEED_VAR=$((NEED_VAR + $(cost_of "$n" 5)))
    NEED_HOME=$((NEED_HOME + $(cost_of "$n" 6)))
done

# The layout for a given disk, from the one place that decides it.
sizes_for() { DISK_SIZE_MB="$1" VM_RAM_MB="$VM_RAM_MB" "${SCRIPT_SH:-bash}" "$RECIPE" --sizes 2>/dev/null; }
usable() { printf '%s' $(($(printf '%s\n' "$1" | awk -F= -v n="$2" '$1 == n { print $2 }') * USABLE_PERMILLE / 1000)); }

# fits <sizes> -> prints the mounts that overflow, one per line ("/opt 370 428"); empty = fits.
fits() {
    s="$1"
    [ "$NEED_ROOT" -gt "$(usable "$s" root)" ] && printf '/ %s %s\n' "$NEED_ROOT" "$(usable "$s" root)"
    [ "$NEED_OPT" -gt "$(usable "$s" opt)" ] && printf '/opt %s %s\n' "$NEED_OPT" "$(usable "$s" opt)"
    [ "$NEED_VAR" -gt "$(usable "$s" var)" ] && printf '/var %s %s\n' "$NEED_VAR" "$(usable "$s" var)"
    [ "$NEED_HOME" -gt "$(usable "$s" home)" ] && printf '/home %s %s\n' "$NEED_HOME" "$(usable "$s" home)"
    return 0
}

SIZES=$(sizes_for "$DISK_MB") || die "partition_recipe.sh refused ${DISK_MB} MB — see its message above"
[ -n "$SIZES" ] || die "partition_recipe.sh produced no layout for ${DISK_MB} MB (too small? see: make partitions)"
OVERFLOW=$(fits "$SIZES")

# The smallest SIZE_B2B at which this exact feature set fits. Linear search is
# fine: each probe is one cheap script run, and it stops at the first fit.
smallest_fit_gb() {
    g=$((SIZE_GB + 1))
    while [ "$g" -le 2048 ]; do
        s=$(sizes_for $((g * 1024))) && [ -n "$s" ] && [ -z "$(fits "$s")" ] && {
            echo "$g"
            return 0
        }
        g=$((g + 1))
    done
    return 1
}

# ── Output ──────────────────────────────────────────────────────────────────
emit_resolve() {
    printf 'profile=%s\n' "$PROFILE"
    for n in $(names); do
        is_on "$n" && printf 'feature=%s\n' "$n"
    done
    # The loop's status is that of its last `is_on`, which is the always-off
    # ai-local: without this, a correct resolution exited 1.
    return 0
}

emit_conf() {
    printf '# /etc/b2b/features.conf — written into the ISO by generate/create_custom_iso.sh\n'
    printf '# Decided on the host from SIZE_B2B; the guest scripts read it and install\n'
    printf '# exactly this set. See generate/feature_profile.sh.\n'
    printf 'B2B_SIZE_GB=%s\n' "$SIZE_GB"
    printf 'B2B_PROFILE=%s\n' "$PROFILE"
    printf 'B2B_AI_MODE=%s\n' "$AI_MODE"
    for n in $(names); do
        if is_on "$n"; then v=on; else v=off; fi
        printf '%s=%s\n' "$(varname "$n")" "$v"
    done
}

emit_table() {
    printf '\n  Install profile for SIZE_B2B=%s (%s MB): %s%s\n\n' "$SIZE_GB" "$DISK_MB" "$PROFILE" \
        "$([ -n "$FEATURES" ] && printf ' + overrides: %s' "$FEATURES")"
    printf '    %-18s %-9s %-4s %6s %6s %6s %6s   %s\n' feature tier "" / /opt /var /home requires
    for n in $(names); do
        if is_on "$n"; then st=on; else st=off; fi
        printf '    %-18s %-9s %-4s %6s %6s %6s %6s   %s\n' "$n" "$(field "$n" 2)" "$st" \
            "$(cost_of "$n" 3)" "$(cost_of "$n" 4)" "$(cost_of "$n" 5)" "$(cost_of "$n" 6)" "$(field "$n" 7)"
    done
    printf '    %-18s %-9s %-4s %6s %6s %6s %6s\n' "needed (on)" "" "" "$NEED_ROOT" "$NEED_OPT" "$NEED_VAR" "$NEED_HOME"
    printf '    %-18s %-9s %-4s %6s %6s %6s %6s   %s\n' "usable at this size" "" "" \
        "$(usable "$SIZES" root)" "$(usable "$SIZES" opt)" "$(usable "$SIZES" var)" "$(usable "$SIZES" home)" \
        "(80% of the mounted volume)"
    printf '\n'
    if [ -z "$OVERFLOW" ]; then
        printf '  ✓ fits\n\n'
    else
        printf '  ✗ does not fit:\n'
        printf '%s\n' "$OVERFLOW" | while read -r m need have; do
            printf '      %-6s needs %s MB, has %s MB\n' "$m" "$need" "$have"
        done
        g=$(smallest_fit_gb) && printf '\n    This set fits from SIZE_B2B=%s   (make all SIZE_B2B=%s)\n' "$g" "$g"
        printf '    Or drop a feature: FEATURES="-docker"   Or a smaller profile: PROFILE=minimal\n\n'
    fi
}

case "$MODE" in
--resolve) emit_resolve ;;
--conf) emit_conf ;;
--table)
    emit_table
    [ -z "$OVERFLOW" ]
    ;;
--check)
    if [ -n "$OVERFLOW" ]; then
        emit_table >&2
        die "the '$PROFILE' feature set does not fit a ${SIZE_GB} GB disk. Nothing was built."
    fi
    printf 'profile=%s fits at SIZE_B2B=%s\n' "$PROFILE" "$SIZE_GB"
    ;;
*)
    echo "usage: $0 --resolve | --check | --conf | --table" >&2
    exit 2
    ;;
esac
