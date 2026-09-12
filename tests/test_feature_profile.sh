#!/usr/bin/env hellish
# Regression test for generate/feature_profile.sh.
#
# What it guards: the install profile is decided on the host from SIZE_B2B and
# checked against the partition layout BEFORE the ISO is built. The two
# failure modes this replaces are both silent: a guest that comes up without
# something it was supposed to have, and a required install starved by an
# optional one that ran first. So the assertions here are about refusals as
# much as about fits -- a set that does not fit must exit 1 and name the size
# that would, never emit a features.conf.
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
FP=("${SCRIPT_SH:-bash}" generate/feature_profile.sh)
rc_of() { "$@" >/dev/null 2>&1 && echo 0 || echo $?; }
fits_from() { "$@" 2>&1 | grep -o 'fits from SIZE_B2B=[0-9]*' | head -1; }

# ── Profiles from size ──────────────────────────────────────────────────────
check "8 GB → minimal" "$(SIZE_B2B=8 "${FP[@]}" --resolve | sed -n 's/^profile=//p')" minimal
check "13 GB → minimal" "$(SIZE_B2B=13 "${FP[@]}" --resolve | sed -n 's/^profile=//p')" minimal
check "14 GB → minimal (auto picks standard from 15; see STANDARD_FROM_GB)" "$(SIZE_B2B=14 "${FP[@]}" --resolve | sed -n 's/^profile=//p')" minimal
check "15 GB (default) → standard" "$("${FP[@]}" --resolve | sed -n 's/^profile=//p')" standard
check "30 GB → full" "$(SIZE_B2B=30 "${FP[@]}" --resolve | sed -n 's/^profile=//p')" full

# ── Base is always on; standard joins at 15 ─────────────────────────────────
check "minimal has nvim" "$(SIZE_B2B=8 "${FP[@]}" --resolve | grep -c '^feature=nvim$')" 1
check "minimal has hellish" "$(SIZE_B2B=8 "${FP[@]}" --resolve | grep -c '^feature=hellish-upstream$')" 1
check "minimal has no docker" "$(SIZE_B2B=8 "${FP[@]}" --resolve | grep -c '^feature=docker$')" 0
check "minimal has no webstack" "$(SIZE_B2B=8 "${FP[@]}" --resolve | grep -c '^feature=webstack$')" 0
check "standard has docker and webstack" "$(SIZE_B2B=15 "${FP[@]}" --resolve | grep -cE '^feature=(docker|webstack)$')" 2
check "AI never on by itself" "$(SIZE_B2B=500 "${FP[@]}" --resolve | grep -c '^feature=ai-')" 0
check "AI_MODE=client turns ai-client on" "$(SIZE_B2B=50 AI_MODE=client "${FP[@]}" --resolve | grep -c '^feature=ai-client$')" 1

# ── Every default profile fits its own size range ───────────────────────────
for gb in 8 10 13 14 15 20 29 30 50 500; do
    check "$gb GB: default profile fits" "$(rc_of env SIZE_B2B=$gb "${FP[@]}" --check)" 0
done

# ── Refusals name the size that works ───────────────────────────────────────
check "13 GB standard: refused" "$(rc_of env SIZE_B2B=13 PROFILE=standard "${FP[@]}" --check)" 1
check "13 GB standard: names 15" "$(fits_from env SIZE_B2B=13 PROFILE=standard "${FP[@]}" --check)" "fits from SIZE_B2B=15"
# The standard set needed 14 GB until the /home column was corrected from a
# guest whose /home was 100% full (2026-09-12, third pass): .vscode-server,
# Inception's bind-mounted data and npm's cache were all unbudgeted, and
# counting them moved the smallest standard disk from 14 to 15 -- which is the
# size the automatic pick already used, so STANDARD_FROM_GB does not move.
# 14 now refuses, and names 15, instead of fitting by a margin that was not
# really there.
check "14 GB standard, explicit: refused" "$(rc_of env SIZE_B2B=14 PROFILE=standard "${FP[@]}" --check)" 1
check "14 GB standard: names 15" "$(fits_from env SIZE_B2B=14 PROFILE=standard "${FP[@]}" --check)" "fits from SIZE_B2B=15"
check "8 GB full: refused" "$(rc_of env SIZE_B2B=8 PROFILE=full "${FP[@]}" --check)" 1
# ── The `full` tier is real, and claude-code is why ─────────────────────────
# Until Claude Code came back beside opencode, `full` was a profile name with
# no feature behind it, and the tier `case` in the state loop had no arm for
# it -- a manifest row saying `full` would have inherited whatever $on the
# PREVIOUS row left behind. These pin the arm and the arithmetic that put
# claude-code there: 320 MB on / against the 289 MB the standard set leaves at
# SIZE_B2B=15, so the default build must NOT have it, 30 GB must, and asking
# for it at 15 must refuse and name 16 rather than overfill /.
check "15 GB (default): no claude-code" "$(SIZE_B2B=15 "${FP[@]}" --resolve | grep -c '^feature=claude-code$')" 0
check "29 GB: still no claude-code" "$(SIZE_B2B=29 "${FP[@]}" --resolve | grep -c '^feature=claude-code$')" 0
check "30 GB (full): claude-code on" "$(SIZE_B2B=30 "${FP[@]}" --resolve | grep -c '^feature=claude-code$')" 1
check "15 GB +claude-code: refused" "$(rc_of env SIZE_B2B=15 FEATURES=+claude-code "${FP[@]}" --check)" 1
check "15 GB +claude-code: names 16" "$(fits_from env SIZE_B2B=15 FEATURES=+claude-code "${FP[@]}" --check)" "fits from SIZE_B2B=16"
check "15 GB +claude-code: overflows / and only /" "$(env SIZE_B2B=15 FEATURES=+claude-code "${FP[@]}" --check 2>&1 | grep -c '^      / ')" 1
check "16 GB +claude-code: fits" "$(rc_of env SIZE_B2B=16 FEATURES=+claude-code "${FP[@]}" --check)" 0
check "30 GB full: -claude-code drops it" "$(SIZE_B2B=30 FEATURES=-claude-code "${FP[@]}" --resolve | grep -c '^feature=claude-code$')" 0
check "8 GB full: names a size" "$(fits_from env SIZE_B2B=8 PROFILE=full "${FP[@]}" --check | grep -c .)" 1
# Docker's /var cost is the measured one (Inception with bonus: 2.35 GB of
# build cache alone), so even alone it needs a 14 GB /var. The override is
# what is being tested here: minimal plus one standard feature.
check "13 GB +docker alone: refused" "$(rc_of env SIZE_B2B=13 FEATURES=+docker "${FP[@]}" --check)" 1
check "13 GB +docker alone: names 14" "$(fits_from env SIZE_B2B=13 FEATURES=+docker "${FP[@]}" --check)" "fits from SIZE_B2B=14"
check "14 GB minimal +docker: fits" "$(rc_of env SIZE_B2B=14 PROFILE=minimal FEATURES=+docker "${FP[@]}" --check)" 0
check "8 GB +docker: refused" "$(rc_of env SIZE_B2B=8 FEATURES=+docker "${FP[@]}" --check)" 1
check "15 GB AI_MODE=local: refused on /opt" "$(env SIZE_B2B=15 AI_MODE=local "${FP[@]}" --check 2>&1 | grep -c '^      /opt ')" 1
check "refusal writes no conf" "$(env SIZE_B2B=8 PROFILE=full "${FP[@]}" --check 2>/dev/null | grep -c 'B2B_FEATURE')" 0

# ── Overrides and their contradictions ──────────────────────────────────────
check "-pytools removes it" "$(SIZE_B2B=15 FEATURES=-pytools "${FP[@]}" --resolve | grep -c '^feature=pytools$')" 0
check "-nvim (base) is an error" "$(rc_of env SIZE_B2B=15 FEATURES=-nvim "${FP[@]}" --resolve)" 1
check "-nodejs with devtools-extra on is an error" "$(rc_of env SIZE_B2B=15 FEATURES=-nodejs "${FP[@]}" --resolve)" 1
check "-nodejs -devtools-extra is fine" "$(rc_of env SIZE_B2B=15 FEATURES='-nodejs -devtools-extra' "${FP[@]}" --resolve)" 0
check "unknown feature is an error" "$(rc_of env FEATURES=+kubernetes "${FP[@]}" --resolve)" 1
check "bad token is an error" "$(rc_of env FEATURES=docker "${FP[@]}" --resolve)" 1
check "bad PROFILE is an error" "$(rc_of env PROFILE=huge "${FP[@]}" --resolve)" 1
check "bad AI_MODE is an error" "$(rc_of env AI_MODE=yes "${FP[@]}" --resolve)" 1

# ── The hand-picked selection file ──────────────────────────────────────────
# generate/feature_select.sh writes .b2b-features and feature_profile.sh reads
# it when FEATURES is unset, so the picker, `make features`, the preflight
# check and the ISO's features.conf cannot disagree. Three things must hold, and
# each was wrong at some point while it was written: the environment beats the
# file, a file written for another disk is ignored rather than applied to this
# one, and the ticks are a DIFF against the tier set -- an absolute list under
# PROFILE=minimal silently dropped the vscode-remote and inception-data
# reservations and made the fit check more permissive the more deliberate you were.
sel=$(mktemp)
trap 'rm -f "$sel"' EXIT
printf 'B2B_SELECT_SIZE_GB=15\nB2B_SELECT_PROFILE=auto\nB2B_SELECT_FEATURES=-docker -inception-data\n' >"$sel"
check "selection file drops docker" "$(SIZE_B2B=15 B2B_SELECT_FILE=$sel "${FP[@]}" --resolve | grep -c '^feature=docker$')" 0
check "selection file keeps the base set" "$(SIZE_B2B=15 B2B_SELECT_FILE=$sel "${FP[@]}" --resolve | grep -c '^feature=nvim$')" 1
check "selection file keeps the vscode-remote reservation" "$(SIZE_B2B=15 B2B_SELECT_FILE=$sel "${FP[@]}" --resolve | grep -c '^feature=vscode-remote$')" 1
check "explicit FEATURES beats the file" "$(SIZE_B2B=15 FEATURES=+docker B2B_SELECT_FILE=$sel "${FP[@]}" --resolve | grep -c '^feature=docker$')" 1
check "explicit PROFILE beats the file" "$(SIZE_B2B=15 PROFILE=standard B2B_SELECT_FILE=$sel "${FP[@]}" --resolve | grep -c '^feature=docker$')" 1
check "a file for another size is ignored" "$(SIZE_B2B=20 B2B_SELECT_FILE=$sel "${FP[@]}" --resolve | grep -c '^feature=docker$')" 1
check "no file, no change" "$(SIZE_B2B=15 B2B_SELECT_FILE=/nonexistent "${FP[@]}" --resolve | grep -c '^feature=docker$')" 1

# ── The conf the guest reads ────────────────────────────────────────────────
conf=$(SIZE_B2B=10 "${FP[@]}" --conf)
manifest_rows=$(sed -n "/^MANIFEST='/,/^'/p" generate/feature_profile.sh | awk 'NF == 7' | wc -l)
check "conf: one line per manifest feature" "$(printf '%s\n' "$conf" | grep -c '^B2B_FEATURE_')" "$manifest_rows"
check "conf: names the profile" "$(printf '%s\n' "$conf" | sed -n 's/^B2B_PROFILE=//p')" minimal
check "conf: names the size" "$(printf '%s\n' "$conf" | sed -n 's/^B2B_SIZE_GB=//p')" 10
check "conf: hyphens become underscores" "$(printf '%s\n' "$conf" | grep -c '^B2B_FEATURE_hellish_upstream=on$')" 1
check "conf: carries AI_MODE" "$(SIZE_B2B=50 AI_MODE=client "${FP[@]}" --conf | sed -n 's/^B2B_AI_MODE=//p')" client

exit "$fail"
