#!/usr/bin/env hellish
# A kulala-core that upstream no longer serves is a NOTE, not a failed feature.
#
# The bug this pins: on the 2026-10-04 build the kulala-core 1.3.1 asset
# answered HTTP 404 (it moved behind a license token at core.kulala.app).
# install_kulala_core() skipped it on purpose and said why, but
# nvim-verify.lua counted the missing binary as a PROBLEM, exited 1, and first
# boot filed nvim-extras as failed -- a warning for a feature that had
# installed everything that could be installed. A deliberate skip leaves
# /opt/kulala/kulala-core.skipped with the reason, verify prints it as a NOTE,
# and a download that failed any other way (no network, a 5xx) leaves nothing,
# so it is still a PROBLEM and `make nvim` still retries.
#
# Two halves, no VM and no network: install_kulala_core() run against a stub
# curl (bash only), and the real nvim-verify.lua run in a headless Neovim
# (skipped, not failed, where there is none).
set -u

cd "$(dirname "$0")/.." || exit 1
REPO=$(pwd)
EXTRAS="setup/install/nvim/install_nvim_extras.sh"
INSTALL="setup/install/nvim/install_nvim.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-58s = %s\n' "$1" "$2"
    else
        printf 'FAIL %-58s = %s (expected %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}

# ── half 1: the installer ───────────────────────────────────────────────────
# curl's -o and -w are what the function reads; FAKE_MODE picks the answer.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/curl" <<'STUB'
#!/bin/sh
out=""
while [ $# -gt 0 ]; do
    [ "$1" = "-o" ] && out="$2"
    shift
done
case "$FAKE_MODE" in
404) printf '404'; exit 22 ;;
net) printf '000'; echo "curl: (6) Could not resolve host" >&2; exit 6 ;;
elf) printf '\177ELF fake' >"$out"; printf '200'; exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"

# shellcheck disable=SC2317,SC2329 # called by install_kulala_core, eval'd below
log() { :; }
# shellcheck disable=SC2317,SC2329
warn() { :; }
KULALA_CORE_DIR="$TMP/opt/kulala/bin"
eval "$(awk '/^KULALA_SKIP_MARK=/{print; exit}' "$REPO/$EXTRAS")"
eval "$(awk '/^install_kulala_core\(\) \{/,/^}/' "$REPO/$EXTRAS")"
MARK="$TMP/opt/kulala/kulala-core.skipped"
check "the mark sits beside bin/, where verify looks" "$KULALA_SKIP_MARK" "$MARK"

# FAKE_MODE is exported, not given as `FAKE_MODE=x func`: hellish does not pass
# a command-prefix assignment on to what a shell function runs.
run_core() {
    export FAKE_MODE="$1"
    install_kulala_core "$plugin"
}

plugin="$TMP/kulala.nvim"
mkdir -p "$plugin/lua/kulala/globals/versions"
echo 'return "1.3.1"' >"$plugin/lua/kulala/globals/versions/backend.lua"

run_core 404
check "404: returns 0 (the feature goes on)" "$?" 0
check "404: the mark is written" "$([ -s "$MARK" ] && echo yes || echo no)" yes
check "404: it names the version and the cause" \
    "$(grep -c 'v1.3.1: HTTP 404.*license token' "$MARK")" 1
check "404: no binary" "$([ -e "$KULALA_CORE_DIR/kulala-core" ] && echo yes || echo no)" no

run_core net
check "no network: returns 0" "$?" 0
check "no network: the old mark is cleared, none written" \
    "$([ -e "$MARK" ] && echo yes || echo no)" no

run_core 404
run_core elf
check "a good download installs the binary" \
    "$([ -x "$KULALA_CORE_DIR/kulala-core" ] && echo yes || echo no)" yes
check "a good download clears the mark" "$([ -e "$MARK" ] && echo yes || echo no)" no

# ── half 2: the verdict ─────────────────────────────────────────────────────
if ! command -v nvim >/dev/null 2>&1; then
    echo "skip nvim-verify half of test_kulala_core_skip.sh: nvim is not installed"
    exit "$fail"
fi
# The heredoc that writes nvim-verify.lua, cut out by its exact markers.
cat >"$TMP/cut.awk" <<'AWKEOF'
/^    cat >"\$\{B2B_LIB_DIR\}\/nvim-verify.lua" <<.LUAEOF.$/ { on = 1; next }
on && /^LUAEOF$/ { exit }
on { print }
AWKEOF
awk -f "$TMP/cut.awk" "$REPO/$INSTALL" >"$TMP/nvim-verify.lua"
[ -s "$TMP/nvim-verify.lua" ] || {
    echo "FAIL nvim-verify.lua heredoc not found in $INSTALL"
    exit 1
}
export XDG_CONFIG_HOME="$TMP/xdg/config" XDG_DATA_HOME="$TMP/xdg/data" \
    XDG_STATE_HOME="$TMP/xdg/state" XDG_CACHE_HOME="$TMP/xdg/cache"
# A vim.pack plugin is a git checkout, and the fixture has to be one: Nvim
# 0.12.6's vim.pack.get() repairs its lockfile with `git rev-parse HEAD` and
# `git remote get-url origin` in every plugin directory, and a bare directory
# made it raise, so the verify never reached its `qa` and this test hung
# (2026-10-14). The user's git config is kept out (a commit.gpgsign = true
# would prompt).
kulala="$XDG_DATA_HOME/nvim/site/pack/core/opt/kulala.nvim"
mkdir -p "$kulala/lua"
fixture_git() { env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$kulala" "$@"; }
fixture_git init -q
fixture_git remote add origin https://github.com/mistweaverco/kulala.nvim
fixture_git -c user.name=fixture -c user.email=fixture@invalid commit -q --allow-empty -m fixture
export B2B_KULALA_SKIP_MARK="$TMP/verify.skipped"
# Bounded: a verify that cannot reach its `qa` is a failed check, not a hang.
verify() { timeout 60 nvim --headless -u NONE -c "luafile $TMP/nvim-verify.lua" 2>&1 | tr -d '\r'; }

rm -f "$B2B_KULALA_SKIP_MARK"
check "no mark: kulala-core missing is a PROBLEM" "$(verify | grep -c 'PROBLEM kulala-core missing')" 1
echo 'v1.3.1: HTTP 404, license token' >"$B2B_KULALA_SKIP_MARK"
out=$(verify)
check "mark: not a PROBLEM" "$(printf '%s\n' "$out" | grep -c 'PROBLEM kulala-core')" 0
check "mark: said as a NOTE, with the reason" \
    "$(printf '%s\n' "$out" | grep -c 'NOTE kulala-core skipped on purpose (v1.3.1: HTTP 404, license token)')" 1

# vim.pack.get() raising (stubbed, so any Nvim version raises) is a named
# PROBLEM in the verdict, never a verify left open until the caller's timeout.
out=$(timeout 60 nvim --headless -u NONE \
    -c 'lua vim.pack = { get = function() error("lock repair failed") end }' \
    -c "luafile $TMP/nvim-verify.lua" 2>&1 | tr -d '\r')
check "vim.pack.get() raising: a PROBLEM with its reason" \
    "$(printf '%s\n' "$out" | grep -c 'PROBLEM vim.pack: .*lock repair failed')" 1

exit "$fail"
