#!/usr/bin/env hellish
# Pick what goes in the guest, by hand, before anything is built.
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
# is not a question. Everything else starts OFF and is a line you tick. The
# automatic size-based set is still one keystroke away (`d`), because it is a
# sensible answer, not because it should happen to you.
#
# WHAT IT WRITES
#   .b2b-features at the repo root, holding the size it was chosen for and the
#   FEATURES string it produced. feature_profile.sh reads it when FEATURES is
#   not set in the environment, so `make features`, the ISO build and the
#   preflight check all agree without anything being passed between them.
#   The size is recorded because a selection is only valid for the disk it was
#   fitted to: change SIZE_B2B and the file is ignored and you are asked again.
#
# WHEN IT DOES NOT RUN
#   Only a terminal gets asked. No tty, FEATURES/PROFILE already set in the
#   environment, or B2B_NO_SELECT=1 -- CI, `make -n`, a scripted rebuild -- and
#   this is skipped entirely and the size-based default stands. A build that
#   blocks on a prompt nobody can see is worse than a build that chose for you.
#
# USAGE
#   generate/feature_select.sh            interactive; writes .b2b-features
#   generate/feature_select.sh --show     print the saved selection, if any
#   generate/feature_select.sh --clear    forget it, back to size-based

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FP="$HERE/feature_profile.sh"
SEL_FILE="${B2B_SELECT_FILE:-$ROOT/.b2b-features}"
SH="${SCRIPT_SH:-bash}"

SIZE_B2B="${SIZE_B2B:-15}"
VM_RAM_MB="${VM_RAM_MB:-2048}"
AI_MODE="${AI_MODE:-off}"

C_R='\033[0m'
C_B='\033[1m'
C_DIM='\033[2m'
C_GRN='\033[32m'
C_YEL='\033[33m'
C_RED='\033[31m'

case "${1:---select}" in
--show)
    [ -f "$SEL_FILE" ] && cat "$SEL_FILE" || echo "no saved selection ($SEL_FILE)"
    exit 0
    ;;
--clear)
    rm -f "$SEL_FILE" && echo "forgot $SEL_FILE — back to the size-based default"
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
# ${VAR+x} is "set, even if empty" -- the right test here. A caller that ran
# `make all FEATURES=` has stated a choice (nothing extra) and must not be
# second-guessed by a prompt.
if [ -n "${FEATURES+x}" ] && [ -n "${FEATURES:-}" ]; then
    exit 0
fi
if [ -n "${PROFILE:-}" ] && [ "${PROFILE}" != "auto" ]; then
    exit 0
fi
if [ ! -t 0 ] || [ ! -t 1 ]; then
    exit 0
fi

# ── The manifest, read from the one place that defines it ───────────────────
# Parsed out of feature_profile.sh rather than duplicated: two lists of
# features that can disagree is exactly the bug this project keeps fixing.
manifest() { sed -n "/^MANIFEST='/,/^'/p" "$FP" | awk 'NF == 7'; }
NOT_INSTALLED=$(sed -n "s/^NOT_INSTALLED='\(.*\)'/\1/p" "$FP")

# A feature the user can decide about: not base (base is the strict minimum,
# and turning it off is not a smaller born2root, it is a different project) and
# not a reservation (nothing installs those; they are space the workflow
# claims). AI is left out too -- AI_MODE is its own switch with its own
# semantics, and offering ai-local as a tickbox would hide a multi-GB download
# behind a checkmark.
optional_names() {
    manifest | while read -r name tier _ _ _ _ _; do
        case "$tier" in base) continue ;; esac
        case "$name" in ai-*) continue ;; esac
        case " $NOT_INSTALLED " in *" $name "*) continue ;; esac
        printf '%s\n' "$name"
    done
}
field() { manifest | awk -v n="$1" -v c="$2" '$1 == n { print $c }'; }
# OPTIONAL is one name per line, because the menu indexes it with sed. So
# membership is grep -qx, NOT `case " $OPTIONAL " in *" $n "*)`: that pattern
# needs space separators and silently never matches a newline-separated list,
# which is what made `d` (size default) a no-op that redrew an unchanged menu.
is_optional() { printf '%s\n' "$OPTIONAL" | grep -qx -- "$1"; }

OPTIONAL=$(optional_names)
[ -n "$OPTIONAL" ] || exit 0

# ── State: the strict minimum, and nothing else ─────────────────────────────
CHOSEN=""
is_chosen() {
    case " $CHOSEN " in *" $1 "*) return 0 ;; esac
    return 1
}
choose() { is_chosen "$1" || CHOSEN="${CHOSEN}${CHOSEN:+ }$1"; }
unchoose() {
    local out="" n
    for n in $CHOSEN; do
        [ "$n" = "$1" ] || out="${out}${out:+ }$n"
    done
    CHOSEN="$out"
}

# The set the tiers would pick on their own, cached: every redraw asks twice.
AUTO_SET=""
auto_set() {
    [ -n "$AUTO_SET" ] || AUTO_SET=$(SIZE_B2B="$SIZE_B2B" VM_RAM_MB="$VM_RAM_MB" \
        AI_MODE=off PROFILE=auto FEATURES='' "$SH" "$FP" --resolve 2>/dev/null |
        sed -n 's/^feature=//p')
    printf '%s\n' "$AUTO_SET"
}
in_auto() { auto_set | grep -qx -- "$1"; }

# The FEATURES string for the current ticks, expressed as a DIFF against the
# automatic set rather than as an absolute list under PROFILE=minimal.
#
# The absolute form was tried first and is wrong. PROFILE=minimal switches off
# the `standard` tier wholesale, and two of its rows are not installs at all --
# vscode-remote and inception-data are RESERVATIONS, space the documented
# workflow claims whether or not first boot writes it. Ticking boxes under
# minimal silently dropped 700 MB of /home reservation and the fit check got
# more permissive the more deliberate you were: /home "needed" fell from 1106
# to 406 MB, which is exactly the accounting that let a 974 MB /home pass and
# then fill up completely.
#
# As a diff, the tier logic and its reservations stay exactly as designed and
# the ticks only say where you differ from them. Unticking a feature a
# reservation depends on takes that reservation with it -- otherwise
# feature_profile.sh's own dependency check refuses the set it was handed.
features_str() {
    local n req out=""
    for n in $OPTIONAL; do
        if is_chosen "$n"; then
            in_auto "$n" || out="${out}${out:+ }+${n}"
        else
            in_auto "$n" && out="${out}${out:+ }-${n}"
        fi
    done
    for n in $NOT_INSTALLED; do
        in_auto "$n" || continue
        req=$(field "$n" 7)
        [ "$req" = "-" ] && continue
        is_optional "$req" || continue
        is_chosen "$req" || out="${out}${out:+ }-${n}"
    done
    printf '%s' "$out"
}

# Dependencies, so ticking a box cannot produce a set feature_profile.sh will
# refuse. Ticking devtools-extra ticks nodejs; unticking nodejs unticks what
# needs it. Doing this silently is right here: the list is being edited live
# and the next redraw shows exactly what happened.
resolve_deps() {
    local changed=1 n req
    while [ "$changed" = 1 ]; do
        changed=0
        for n in $OPTIONAL; do
            is_chosen "$n" || continue
            req=$(field "$n" 7)
            [ "$req" = "-" ] && continue
            case "$(field "$req" 2)" in base) continue ;; esac
            is_chosen "$req" && continue
            choose "$req"
            changed=1
        done
        for n in $OPTIONAL; do
            is_chosen "$n" || continue
            req=$(field "$n" 7)
            [ "$req" = "-" ] && continue
            case "$(field "$req" 2)" in base) continue ;; esac
            is_chosen "$req" && continue
            unchoose "$n"
            changed=1
        done
    done
}

# What the size-based default would have picked, as the `d` shortcut.
apply_default() {
    CHOSEN=""
    local n
    for n in $(SIZE_B2B="$SIZE_B2B" VM_RAM_MB="$VM_RAM_MB" AI_MODE=off \
        "$SH" "$FP" --resolve 2>/dev/null | sed -n 's/^feature=//p'); do
        is_optional "$n" && choose "$n"
    done
    return 0
}

# Does the current selection fit? Returns the overflow lines feature_profile.sh
# produces, or nothing.
fit_report() {
    SIZE_B2B="$SIZE_B2B" VM_RAM_MB="$VM_RAM_MB" AI_MODE="$AI_MODE" \
        PROFILE=auto FEATURES="$(features_str)" \
        "$SH" "$FP" --table 2>&1
}

# ── Draw ────────────────────────────────────────────────────────────────────
draw() {
    local n i=1 tier mark cost report
    report=$(fit_report)
    printf '\n'
    # shellcheck disable=SC2059
    printf "${C_B}  What goes in the VM${C_R}  ${C_DIM}(SIZE_B2B=%s)${C_R}\n\n" "$SIZE_B2B"
    # shellcheck disable=SC2059
    printf "  ${C_GRN}[x]${C_R} %-18s ${C_DIM}%s${C_R}\n" "the strict minimum" \
        "Born2beRoot's requirements, nvim, hellish — always installed"
    printf '\n'
    for n in $OPTIONAL; do
        tier=$(field "$n" 2)
        cost="$(field "$n" 3)/$(field "$n" 4)/$(field "$n" 5)/$(field "$n" 6)"
        if is_chosen "$n"; then mark="${C_GRN}[x]${C_R}"; else mark="${C_DIM}[ ]${C_R}"; fi
        # shellcheck disable=SC2059
        printf "  %2d %b %-16s ${C_DIM}%-8s %14s MB  %s${C_R}\n" \
            "$i" "$mark" "$n" "$tier" "$cost" "$(feature_blurb "$n")"
        i=$((i + 1))
    done
    printf '\n'
    printf '%s\n' "$report" | sed -n '/needed (on)/,/usable at this size/p' | sed 's/^/  /'
    if printf '%s\n' "$report" | grep -q '✓ fits'; then
        # shellcheck disable=SC2059
        printf "  ${C_GRN}✓ fits${C_R}\n"
    else
        # shellcheck disable=SC2059
        printf "  ${C_RED}✗ does not fit:${C_R}\n"
        printf '%s\n' "$report" | sed -n 's/^      \(\/[a-z]*\) needs/      \1 needs/p' | sed 's/^/  /'
    fi
    printf '\n'
    # shellcheck disable=SC2059
    printf "  ${C_DIM}number${C_R} toggle   ${C_DIM}a${C_R} all that fit   ${C_DIM}d${C_R} size default   ${C_DIM}n${C_R} none   ${C_DIM}Enter${C_R} build\n\n"
}

# One line each, for people who have not read feature_profile.sh. Kept here
# rather than in the manifest so the manifest stays a table of numbers.
feature_blurb() {
    case "$1" in
    webstack) echo "lighttpd + MariaDB + PHP + WordPress (the bonus)" ;;
    nodejs) echo "Node + the npm globals" ;;
    pytools) echo "pipx tools (ruff, …)" ;;
    nvim-extras) echo "the nvim IDE layer + Excalidraw + markdown preview" ;;
    devtools-extra) echo "Herdr (persistent panes) + opencode" ;;
    claude-code) echo "Claude Code, beside opencode" ;;
    docker) echo "Docker engine (Inception needs it)" ;;
    *) echo "" ;;
    esac
}

# ── Loop ────────────────────────────────────────────────────────────────────
count=$(printf '%s\n' "$OPTIONAL" | wc -l)
while :; do
    draw
    printf '  > '
    read -r reply || reply=""
    case "$reply" in
    "")
        if printf '%s\n' "$(fit_report)" | grep -q '✓ fits'; then break; fi
        # shellcheck disable=SC2059
        printf "\n  ${C_YEL}That set does not fit. Untick something, or build a bigger disk.${C_R}\n"
        fit_report | sed -n '/This set fits from/p' | sed 's/^/  /'
        ;;
    a)
        # Everything that still fits, added cheapest-first so one expensive
        # feature cannot shut out three small ones.
        CHOSEN=""
        for n in $(for m in $OPTIONAL; do
            printf '%s %s\n' "$(($(field "$m" 3) + $(field "$m" 4) + $(field "$m" 5) + $(field "$m" 6)))" "$m"
        done | sort -n | awk '{print $2}'); do
            choose "$n"
            resolve_deps
            printf '%s\n' "$(fit_report)" | grep -q '✓ fits' || unchoose "$n"
        done
        ;;
    d) apply_default ;;
    n) CHOSEN="" ;;
    q | Q) exit 130 ;;
    *[!0-9]*) ;;
    *)
        if [ "$reply" -ge 1 ] && [ "$reply" -le "$count" ]; then
            name=$(printf '%s\n' "$OPTIONAL" | sed -n "${reply}p")
            if is_chosen "$name"; then unchoose "$name"; else choose "$name"; fi
        fi
        ;;
    esac
    resolve_deps
done

# ── Save ────────────────────────────────────────────────────────────────────
{
    printf '# Written by generate/feature_select.sh — what you ticked, and for\n'
    printf '# which disk. feature_profile.sh reads this when FEATURES is unset;\n'
    printf '# change SIZE_B2B and it is ignored and you are asked again.\n'
    printf '# Forget it with: generate/feature_select.sh --clear\n'
    printf 'B2B_SELECT_SIZE_GB=%s\n' "$SIZE_B2B"
    printf 'B2B_SELECT_PROFILE=auto\n'
    printf 'B2B_SELECT_FEATURES=%s\n' "$(features_str)"
} >"$SEL_FILE"

# shellcheck disable=SC2059
printf "\n  ${C_GRN}saved${C_R} %s\n" "$SEL_FILE"
printf '  %s\n\n' "the strict minimum${CHOSEN:+ + }$(printf '%s' "$CHOSEN" | tr ' ' ',')"
