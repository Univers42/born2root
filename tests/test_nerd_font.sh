#!/usr/bin/env hellish
# Nerd Font icons in the guest's Neovim: decided on the host, applied in the
# guest. No VM: both functions are lifted out of their scripts.
#
# The bug this pins: kickstart ships `vim.g.have_nerd_font = false`, nothing in
# the build ever changed it, and render-markdown -- which draws a heading with
# the icon `## ` and a checkbox as `[ ] ` when the flag is false -- made a
# "rendered" buffer look almost exactly like the raw file. Reported on the
# 2026-09-13 15 GB build from a host that had JetBrainsMono Nerd Font installed
# all along.
#
# 1. create_custom_iso.sh's resolve_nerd_font: auto follows the host's
#    fontconfig, on/off override it, anything else refuses the build.
# 2. install_nvim.sh's set_nerd_font: rewrites only kickstart's assignment, in
#    both directions, idempotently, and leaves the config alone when nothing
#    was recorded (a guest built before the key existed).
set -e

cd "$(dirname "$0")/.."
REPO=$(pwd)

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-50s = %s\n' "$1" "$3"
    else
        printf 'FAIL %-50s = %s (expected %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/with" "$TMP/without" "$TMP/none"

# ── 1. the host's answer ────────────────────────────────────────────────────
cat >"$TMP/with/fc-list" <<'EOF'
#!/bin/sh
printf 'DejaVu Sans Mono\nJetBrainsMono Nerd Font Mono,JetBrainsMono NFM\n'
EOF
cat >"$TMP/without/fc-list" <<'EOF'
#!/bin/sh
printf 'DejaVu Sans Mono\nLiberation Mono\n'
EOF
chmod +x "$TMP/with/fc-list" "$TMP/without/fc-list"

eval "$(awk '/^resolve_nerd_font\(\) \{/,/^}/' "$REPO/generate/create_custom_iso.sh")"
if ! command -v resolve_nerd_font >/dev/null 2>&1; then
    check "resolve_nerd_font found in create_custom_iso.sh" "missing" "present"
else
    OLDPATH=$PATH
    PATH="$TMP/with:$OLDPATH"
    check "auto, host has a Nerd Font" "$(resolve_nerd_font auto)" "on"
    check "off overrides a host that has one" "$(resolve_nerd_font off)" "off"
    PATH="$TMP/without:$OLDPATH"
    check "auto, host has none" "$(resolve_nerd_font auto)" "off"
    check "on overrides a host that has none" "$(resolve_nerd_font on)" "on"
    # No fontconfig at all (CI, a minimal container): off, not an error.
    PATH="$TMP/none:/usr/bin/nonexistent"
    check "auto, no fc-list on the host" "$(resolve_nerd_font auto)" "off"
    PATH=$OLDPATH
    rc=0
    resolve_nerd_font maybe >/dev/null || rc=$?
    check "a value that is not auto/on/off is refused" "$rc" "1"
fi

# ── 2. the guest's config ───────────────────────────────────────────────────
# shellcheck disable=SC2317 # called by the functions eval'd below
log() { :; }
# shellcheck disable=SC2317 # called by the functions eval'd below
warn() { printf 'warn: %s\n' "$*"; }
eval "$(awk '/^resolve_nerd_font_setting\(\) \{/,/^}/' "$REPO/setup/install/nvim/install_nvim.sh")"
eval "$(awk '/^set_nerd_font\(\) \{/,/^}/' "$REPO/setup/install/nvim/install_nvim.sh")"

# The shape of kickstart's init.lua around the flag, including a line that
# READS it and must not be rewritten.
mk_init() {
    mkdir -p "$TMP/cfg"
    cat >"$TMP/cfg/init.lua" <<'EOF'
do
  -- Set to true if you have a Nerd Font installed and selected in the terminal
  vim.g.have_nerd_font = false
end
require('which-key').setup { icons = { mappings = vim.g.have_nerd_font } }
EOF
}
flag() { grep -E '^[[:space:]]*vim\.g\.have_nerd_font = ' "$TMP/cfg/init.lua" | sed 's/.*= //'; }

B2B_FEATURES_CONF="$TMP/features.conf"
mk_init
printf 'B2B_PROFILE=standard\nB2B_NERD_FONT=on\n' >"$B2B_FEATURES_CONF"
NVIM_NERD_FONT=""
set_nerd_font alice "$TMP/cfg"
check "features.conf on -> true" "$(flag)" "true"
check "indentation kept" "$(grep -c '^  vim.g.have_nerd_font = true$' "$TMP/cfg/init.lua")" "1"
check "the line that reads the flag is untouched" \
    "$(grep -c 'icons = { mappings = vim.g.have_nerd_font }' "$TMP/cfg/init.lua")" "1"
set_nerd_font alice "$TMP/cfg"
check "applying it twice changes nothing" "$(flag)" "true"

NVIM_NERD_FONT=off
set_nerd_font alice "$TMP/cfg"
check "NVIM_NERD_FONT=off wins over features.conf" "$(flag)" "false"

# Nothing recorded anywhere: a hand-set true survives.
NVIM_NERD_FONT=""
printf 'B2B_PROFILE=standard\n' >"$B2B_FEATURES_CONF"
sed -i 's/have_nerd_font = false/have_nerd_font = true/' "$TMP/cfg/init.lua"
set_nerd_font alice "$TMP/cfg"
check "no recorded choice leaves a hand edit alone" "$(flag)" "true"
rm -f "$B2B_FEATURES_CONF"
set_nerd_font alice "$TMP/cfg"
check "no features.conf at all leaves it alone too" "$(flag)" "true"

# Upstream renamed the line: warn, change nothing.
printf 'vim.g.nerd_icons = false\n' >"$TMP/cfg/init.lua"
# shellcheck disable=SC2034 # read by the eval'd resolve_nerd_font_setting
NVIM_NERD_FONT=on
check "a missing assignment is reported" \
    "$(set_nerd_font alice "$TMP/cfg" | grep -c 'no longer assigns')" "1"
check "and the file is not touched" "$(cat "$TMP/cfg/init.lua")" "vim.g.nerd_icons = false"

exit "$fail"
