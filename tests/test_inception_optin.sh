#!/usr/bin/env hellish
# Host-side Inception setup is opt-in: `make all` configures the user's
# browsers, desktop proxy and ~/.local/bin only for a profile that includes
# Inception.
#
# The bug this pins: the 2026-10-04 build of a project VM (PROFILE=minimal,
# FEATURES naming docker, claude-code, playwright... and no Inception) still
# ran setup/host/inception_host_access.sh at the end of `make all`, because
# the Makefile called it unconditionally. The user's laptop got a local proxy
# on 127.0.0.1:8118 (systemd --user), a managed block in every Firefox
# profile, the GNOME proxy pointed at a PAC, a Chromium launcher and an
# inception-curl wrapper, for a machine with no site to reach.
#
# Two layers, no VM and no network:
#   - `feature_profile.sh --has` answers per profile (the decision);
#   - the real recipe text of `make -n _build` is cut out and run against a
#     stub inception_host_access.sh (the wiring: the call sits behind it).
set -u

cd "$(dirname "$0")/.." || exit 1
REPO=$(pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export B2B_CONFIG="$REPO/tests/fixtures/default.toml"
export B2B_SELECT_FILE="$TMP/none"

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-58s = %s\n' "$1" "$2"
    else
        printf 'FAIL %-58s = %s (expected %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}
FP=("${SCRIPT_SH:-bash}" generate/feature_profile.sh)

# ── the decision ────────────────────────────────────────────────────────────
has() { env "$@" "${FP[@]}" --has inception-data >/dev/null 2>&1 && echo yes || echo no; }
check "standard (the default) has Inception" "$(has PROFILE=standard)" yes
check "full has Inception" "$(has SIZE_B2B=30 PROFILE=full)" yes
check "minimal has none" "$(has PROFILE=minimal)" no
check "minimal + the groot-style feature set has none" \
    "$(has PROFILE=minimal FEATURES='+docker +claude-code +nodejs +devtools-extra +nvim-extras')" no
check "minimal +inception-data asks for it by name" \
    "$(has PROFILE=minimal FEATURES='+docker +inception-data')" yes
check "standard -inception-data opts out" "$(has PROFILE=standard FEATURES='-inception-data')" no
check "an unknown feature name is refused, not 'off'" \
    "$("${FP[@]}" --has inception-dta 2>&1 | grep -c "unknown feature")" 1

# ── the wiring ──────────────────────────────────────────────────────────────
# The `if ...; fi` block `make -n _build` would run, with the Makefile's own
# variables already substituted, executed in a tree whose
# inception_host_access.sh is a stub that leaves a file behind.
mkdir -p "$TMP/tree/setup/host"
ln -s "$REPO/generate" "$TMP/tree/generate"
ln -s "$REPO/utils" "$TMP/tree/utils"
cat >"$TMP/tree/setup/host/inception_host_access.sh" <<'STUB'
#!/bin/sh
echo ran >"$STUB_OUT"
STUB
recipe() {
    make -n _build "$@" 2>/dev/null | awk '
        /^[[:space:]]*if SIZE_B2B=/ { on = 1; buf = "" }
        on { buf = buf $0 "\n" }
        on && /^[[:space:]]*fi[[:space:]]*$/ {
            if (buf ~ /--has inception-data/) { printf "%s", buf; exit }
            on = 0
        }'
}
ran() {
    local block
    block=$(recipe "$@")
    [ -n "$block" ] || {
        echo "no-recipe"
        return
    }
    rm -f "$TMP/out"
    (cd "$TMP/tree" && STUB_OUT="$TMP/out" bash -c "$block" >/dev/null 2>&1)
    [ -f "$TMP/out" ] && echo ran || echo skipped
}
check "make all, standard: host access runs" "$(ran SIZE_B2B=15 PROFILE=standard)" ran
check "make all, minimal groot set: host access is skipped" \
    "$(ran SIZE_B2B=15 PROFILE=minimal FEATURES='+docker +claude-code')" skipped

# And nothing else in a build path calls it unconditionally: the only
# remaining callers are the explicit targets and `make inception`.
check "inception_host_access.sh is called from the Makefile at" \
    "$(grep -n 'inception_host_access.sh' Makefile | grep -vc '^[0-9]*:#')" 3

exit "$fail"
