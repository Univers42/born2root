#!/usr/bin/env hellish
# Does this project still fit in the space it is allowed?
#
# 42 caps a student's shared storage, and this project is the kind that eats it
# without ever saying so: a thin-provisioned disk image that only grows, two
# ISOs that are never deleted after they have been used, and a handful of
# nested clones. It reached 45 GB against a 15 GB quota before anyone looked,
# and nothing in the build had an opinion about that.
#
# So the build has one now. This measures the three things that actually cost
# anything and compares the total against SPACE_BUDGET_GB.
#
# It EXITS 1 when the budget is blown, rather than printing a warning and
# carrying on. A warning during a 40-minute build scrolls past and is never
# seen; the whole point is to stop before writing the thing that overflows the
# quota, not to narrate the overflow afterwards.
#
#   utils/space_budget.sh                     report, and fail if over budget
#   utils/space_budget.sh --report            report only, always exit 0
#   utils/space_budget.sh --preflight <MB>    will a new <MB> disk still fit?
#
# --preflight runs BEFORE the build, because both answers it gives are only
# useful in advance: whether the finished VM would exceed the quota, and
# whether the filesystem VM_PATH points at physically has room for it. Finding
# either out afterwards costs a 40-minute install and leaves the mess behind.
#
# Env
#   SPACE_BUDGET_GB (15)  VM_PATH  VM_NAME (debian)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(readlink -f "$HERE/..")"

SPACE_BUDGET_GB="${SPACE_BUDGET_GB:-15}"
VM_NAME="${VM_NAME:-debian}"
VM_PATH="${VM_PATH:-$REPO_ROOT/disk_images}"
# Compare physical paths: REPO_ROOT is resolved through `pwd`, while VM_PATH
# arrives however the user typed it. ~/goinfre is a symlink to /goinfre/<login>
# on this campus, and the two spellings of the same directory made the VM
# count once as itself and once as "another disk in the repo".
# readlink -f rather than a subshell `cd && pwd -P`: under hellish the latter
# came back logical, and the check silently disagreed with itself.
VM_PATH_REAL=$(readlink -f "$VM_PATH" 2>/dev/null || printf '%s' "$VM_PATH")
REPORT_ONLY=0
PREFLIGHT_MB=0
case "${1:-}" in
--report) REPORT_ONLY=1 ;;
--preflight) PREFLIGHT_MB="${2:-0}" ;;
esac

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED=$'\033[31m' GRN=$'\033[32m' BLD=$'\033[1m' DIM=$'\033[2m' OFF=$'\033[0m'
else
    RED='' GRN='' BLD='' DIM='' OFF=''
fi

# Apparent size would lie in both directions here: a sparse qcow2 reports its
# virtual size (120 GB for a file costing 2 MB), and a quota counts blocks on
# disk. `du` without -b is what the quota sees, so it is what this counts.
kb_of() {
    [ -e "$1" ] || {
        printf '0'
        return 0
    }
    du -sk -- "$1" 2>/dev/null | awk '{print $1; exit}'
}

human() { awk -v k="$1" 'BEGIN { printf (k >= 1048576) ? "%.1f GB" : "%.0f MB", (k >= 1048576) ? k/1048576 : k/1024 }'; }

# ── The three things that cost anything ─────────────────────────────────────
# The VM disk is counted wherever VM_PATH actually points, which is the whole
# reason relocating it works: moved off the quota'd filesystem, it stops
# counting here too. It is listed separately when it lives outside the repo so
# the report never implies the repo is holding something it is not.
VM_KB=$(kb_of "$VM_PATH/$VM_NAME")

ISO_KB=0
for iso in "$REPO_ROOT"/debian-*.iso; do
    [ -e "$iso" ] || continue
    ISO_KB=$((ISO_KB + $(kb_of "$iso")))
done

# Disk images sitting in the repo that are NOT the VM being asked about. After
# relocating with VM_PATH, the old images stay exactly where they were and are
# the single biggest thing anyone forgets. Counting them silently into "source"
# made a 43 GB leftover look like source code, so they get their own line.
OTHER_VM_KB=0
REPO_DISKS="$REPO_ROOT/disk_images"
case "$VM_PATH_REAL" in
"$REPO_DISKS") ;;
*) OTHER_VM_KB=$(kb_of "$REPO_DISKS") ;;
esac

# The repo minus everything already counted, so nothing is double-billed.
REPO_KB=$(kb_of "$REPO_ROOT")
case "$VM_PATH_REAL/" in
"$REPO_ROOT"/*) REPO_KB=$((REPO_KB - VM_KB)) ;;
esac
REPO_KB=$((REPO_KB - ISO_KB - OTHER_VM_KB))
[ "$REPO_KB" -lt 0 ] && REPO_KB=0

TOTAL_KB=$((REPO_KB + ISO_KB + OTHER_VM_KB + VM_KB))
BUDGET_KB=$((SPACE_BUDGET_GB * 1048576))

# ── Pre-flight: would the VM about to be built still fit, and is there room ──
if [ "$PREFLIGHT_MB" -gt 0 ]; then
    WANT_KB=$((PREFLIGHT_MB * 1024))
    # The virtual size is the worst case the image can ever reach, which is
    # exactly the number a budget should be checked against: a disk that fits
    # only while it stays thin is a quota overrun waiting for a busy week.
    # An existing disk is replaced, not added to, so take the larger of the two.
    [ "$VM_KB" -gt "$WANT_KB" ] && WANT_KB="$VM_KB"
    # The ISOs are build INPUTS, not part of the finished project: `make slim`
    # removes them once the VM is installed. Counting them here made every
    # rebuild fail its own budget (source + 1.7 GB of ISOs + the disk), while
    # the steady state it is meant to protect was fine. They still count in
    # the free-space check below, because the build does need room for them.
    PROJECTED_KB=$((REPO_KB + OTHER_VM_KB + WANT_KB))

    printf '\n  %sPre-flight%s  %s(budget: %s GB · new disk: %s)%s\n\n' \
        "$BLD" "$OFF" "$DIM" "$SPACE_BUDGET_GB" "$(human $((PREFLIGHT_MB * 1024)))" "$OFF"
    printf '    %-34s %10s\n' "source, git, nested repos" "$(human "$REPO_KB")"
    printf '    %-34s %10s   %s\n' "ISOs" "$(human "$ISO_KB")" "(build input; not counted — make slim removes them)"
    [ "$OTHER_VM_KB" -gt 0 ] &&
        printf '    %-34s %10s\n' "other VM disks still in the repo" "$(human "$OTHER_VM_KB")"
    printf '    %-34s %10s\n' "VM disk, at its maximum" "$(human "$WANT_KB")"
    printf '    %-34s %10s\n\n' "projected total, once slimmed" "$(human "$PROJECTED_KB")"

    FAIL=0
    if [ "$PROJECTED_KB" -gt "$BUDGET_KB" ]; then
        printf '  %s✗%s A %s VM would put this project %s over the %s GB budget.\n\n' \
            "$RED" "$OFF" "$(human "$WANT_KB")" \
            "$(human $((PROJECTED_KB - BUDGET_KB)))" "$SPACE_BUDGET_GB"
        # Only offer a smaller disk when a smaller disk is actually the answer.
        # When the fixed costs already exceed the budget on their own, no disk
        # size fits and suggesting one (a negative number, at that) sends
        # someone off tuning the wrong knob.
        ROOM_MB=$(((BUDGET_KB - REPO_KB - OTHER_VM_KB) / 1024))
        if [ "$ROOM_MB" -gt 1024 ]; then
            printf '    %sDISK_SIZE_MB=%s%s   the largest disk that still fits\n' \
                "$BLD" "$ROOM_MB" "$OFF"
        fi
        if [ "$OTHER_VM_KB" -gt 0 ]; then
            printf '    %srm -rf %s%s\n' "$BLD" "$REPO_DISKS" "$OFF"
            printf '                          %s— %s of old VM disks, and nothing here uses them%s\n' \
                "$DIM" "$(human "$OTHER_VM_KB")" "$OFF"
        fi
        printf '    %sVM_PATH=...%s          build somewhere that is not quota%sd\n' \
            "$BLD" "$OFF" "'"
        printf '    %sSPACE_BUDGET_GB=%s%s  raise the cap, if you are allowed to\n\n' \
            "$BLD" "$(((PROJECTED_KB + 1048575) / 1048576))" "$OFF"
        FAIL=1
    fi

    # Fitting the budget and fitting the disk are different questions: goinfre
    # is not quota'd but it is finite, and an install that runs the filesystem
    # out of space corrupts the image it is halfway through writing.
    AVAIL_KB=$(df -Pk "$VM_PATH" 2>/dev/null | awk 'NR==2 {print $4; exit}')
    if [ -z "$AVAIL_KB" ]; then
        AVAIL_KB=$(df -Pk "$(dirname "$VM_PATH")" 2>/dev/null | awk 'NR==2 {print $4; exit}')
    fi
    # The ISO build needs its own room alongside the disk: the netinst, the
    # preseeded copy and the extraction tree, live at the same time.
    NEED_KB=$((PREFLIGHT_MB * 1024 + 4 * 1048576))
    if [ -n "$AVAIL_KB" ] && [ "$AVAIL_KB" -lt "$NEED_KB" ]; then
        printf '  %s✗%s %s has %s free; the build needs about %s\n' \
            "$RED" "$OFF" "$VM_PATH" "$(human "$AVAIL_KB")" "$(human "$NEED_KB")"
        printf '    %s(the disk at full size, plus ~4 GB for the ISOs and the%s\n' "$DIM" "$OFF"
        printf '    %sextraction tree, which exist at the same time during a build)%s\n\n' "$DIM" "$OFF"
        FAIL=1
    fi

    if [ "$FAIL" = 0 ]; then
        printf '  %s✓%s fits the budget, and %s has %s free\n' "$GRN" "$OFF" \
            "$VM_PATH" "$(human "${AVAIL_KB:-0}")"
        # The ISOs are counted at their current size, which is zero before the
        # first build. They are ~1.7 GB once built and stay until something
        # removes them, so say where that lands rather than letting the next
        # `make space` be a surprise.
        printf '    %sthe ISOs (~1.7 GB) are not counted; %smake slim%s%s drops them once installed%s\n' \
            "$DIM" "$BLD" "$OFF" "$DIM" "$OFF"
        printf '\n'
    fi
    exit "$FAIL"
fi

# ── Report ──────────────────────────────────────────────────────────────────
printf '\n  %sProject footprint%s  %s(budget: %s GB)%s\n\n' "$BLD" "$OFF" "$DIM" "$SPACE_BUDGET_GB" "$OFF"
printf '    %-34s %10s\n' "source, git, nested repos" "$(human "$REPO_KB")"
printf '    %-34s %10s' "ISOs" "$(human "$ISO_KB")"
[ "$ISO_KB" -gt 0 ] && printf '  %sdeletable once installed: make slim%s' "$DIM" "$OFF"
printf '\n'
printf '    %-34s %10s' "VM disk ($VM_NAME)" "$(human "$VM_KB")"
case "$VM_PATH_REAL/" in
"$REPO_ROOT"/*) ;;
*) printf '  %sat %s%s' "$DIM" "$VM_PATH" "$OFF" ;;
esac
printf '\n'
[ "$OTHER_VM_KB" -gt 0 ] &&
    printf '    %-34s %10s  %sleftover — nothing here uses it%s\n' \
        "other VM disks in the repo" "$(human "$OTHER_VM_KB")" "$DIM" "$OFF"
printf '    %-34s %10s\n\n' "" "─────────"
printf '    %-34s %10s\n\n' "total" "$(human "$TOTAL_KB")"

if [ "$TOTAL_KB" -le "$BUDGET_KB" ]; then
    printf '  %s✓%s %s under budget, %s to spare\n\n' "$GRN" "$OFF" \
        "$(human "$TOTAL_KB")" "$(human $((BUDGET_KB - TOTAL_KB)))"
    exit 0
fi

OVER_KB=$((TOTAL_KB - BUDGET_KB))
printf '  %s✗%s %sOver budget by %s%s\n\n' "$RED" "$OFF" "$BLD" "$(human "$OVER_KB")" "$OFF"

# Naming the specific lever that fits, rather than "free up some space".
if [ "$ISO_KB" -gt 0 ] && [ "$ISO_KB" -ge "$OVER_KB" ]; then
    printf '    %smake slim%s            deletes the ISOs (%s) — they are rebuildable\n' \
        "$BLD" "$OFF" "$(human "$ISO_KB")"
fi
case "$VM_PATH_REAL/" in
"$REPO_ROOT"/*)
    printf '    %sVM_PATH=...%s          move the %s VM disk off this filesystem:\n' \
        "$BLD" "$OFF" "$(human "$VM_KB")"
    # shellcheck disable=SC2016  # literal for the user to type
    printf '                          %smake all VM_PATH=$HOME/goinfre/b2r VM_NAME=%s%s\n' \
        "$DIM" "$VM_NAME" "$OFF"
    ;;
esac
printf '    %smake slim%s            in-guest apt clean + fstrim, if the VM is running\n' "$BLD" "$OFF"
printf '\n    %sOverride the cap for one run: SPACE_BUDGET_GB=25 make ...%s\n\n' "$DIM" "$OFF"

[ "$REPORT_ONLY" = 1 ] && exit 0
exit 1
