#!/usr/bin/env hellish
# Regression test for write_autosave_plugin in setup/install/nvim/install_nvim.sh.
#
# THE BUG THIS PINS DOWN
#   The guest is edited from Neovim inside it and from the host over SSH at
#   the same time. A file rewritten outside while its buffer was open prompted
#   W11, and what was typed in Neovim stayed unsaved until a :w, so the host
#   read stale files. The drop-in has to reload a clean buffer when the file
#   changes and write a dirty one without being asked -- and leave scratch
#   buffers alone.
#
# The function is cut out of the installer by name (its `^name() {` line to
# the next `^}`) and run here, so the file under test is the one a build
# writes. The Lua runs in a headless Neovim with every XDG dir pointed at a
# scratch tree, so no plugin of the host's own config is loaded. Focus and
# idle events never fire headless, so each one is raised with
# nvim_exec_autocmds, which is what the terminal would do.
# Prints `skip` when Neovim 0.10+ is missing (vim.uv, nvim_exec_autocmds).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
INSTALLER="$REPO_ROOT/setup/install/nvim/install_nvim.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
check() {
    local what="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        printf 'ok   %-52s = %s\n' "$what" "$got"
    else
        printf 'FAIL %-52s = %s (want %s)\n' "$what" "$got" "$want"
        fail=1
    fi
}

AUTOSAVE_PLUGIN_REL=$(sed -n 's/^AUTOSAVE_PLUGIN_REL="\(.*\)"$/\1/p' "$INSTALLER")
check "the installer names the drop-in" "$AUTOSAVE_PLUGIN_REL" "plugin/02-b2b-autosave.lua"
check "setup_user_config writes it" "$(grep -cF "    write_autosave_plugin \"\$cfg\"" "$INSTALLER")" 1

eval "$(awk '/^write_autosave_plugin\(\) \{/,/^}/' "$INSTALLER")"
CFG="$TMP/xdg/nvim"
mkdir -p "$CFG"
write_autosave_plugin "$CFG"
check "the drop-in is written" "$([ -s "$CFG/$AUTOSAVE_PLUGIN_REL" ] && echo yes || echo no)" yes
check "no line of the Lua starts a brace at column 0" "$(grep -c '^}' "$CFG/$AUTOSAVE_PLUGIN_REL")" 0

if ! command -v nvim >/dev/null 2>&1 ||
    ! nvim --headless -c 'lua assert(vim.uv and vim.api.nvim_exec_autocmds)' -c qa >/dev/null 2>&1; then
    echo "skip test_nvim_autosave.sh: nvim 0.10+ is not installed"
    exit "$fail"
fi

cat >"$TMP/probe.lua" <<'LUAEOF'
local out, path = {}, os.getenv('T_FILE')
local function rec(k, v) out[#out + 1] = k .. '=' .. tostring(v) end
local function settle(ms) vim.wait(ms, function() return false end, 50) end
rec('autoread', vim.o.autoread)
rec('autowriteall', vim.o.autowriteall)
rec('command', vim.fn.exists ':B2BAutosave' == 2)

vim.cmd('edit ' .. vim.fn.fnameescape(path))
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'typed' })
vim.api.nvim_exec_autocmds('TextChanged', { buffer = 0 })
rec('saved_after_change', vim.wait(5000, function() return not vim.bo.modified end, 50))
rec('on_disk', table.concat(vim.fn.readfile(path), '|'))

vim.cmd 'enew'
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'scratch' })
vim.api.nvim_exec_autocmds('TextChanged', { buffer = 0 })
settle(1500)
rec('nameless_left_modified', vim.bo.modified)
vim.bo.modified = false

vim.cmd('edit ' .. vim.fn.fnameescape(path))
vim.fn.writefile({ 'changed', 'on', 'disk' }, path)
vim.api.nvim_exec_autocmds('FocusGained', {})
rec('reloaded', vim.wait(3000, function() return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == 'changed' end, 50))

vim.cmd 'B2BAutosave off'
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'kept in the buffer' })
vim.api.nvim_exec_autocmds('TextChanged', { buffer = 0 })
settle(1500)
rec('off_keeps_modified', vim.bo.modified)
vim.cmd 'B2BAutosave on'
vim.api.nvim_exec_autocmds('InsertLeave', { buffer = 0 })
rec('insertleave_saves', vim.wait(2000, function() return not vim.bo.modified end, 50))
vim.fn.writefile(out, os.getenv('T_OUT'))
LUAEOF

printf 'before\n' >"$TMP/edited.txt"
env -i HOME="$TMP" PATH="$PATH" TERM=dumb T_FILE="$TMP/edited.txt" T_OUT="$TMP/probe.out" \
    XDG_CONFIG_HOME="$TMP/xdg" XDG_DATA_HOME="$TMP/data" XDG_STATE_HOME="$TMP/state" XDG_CACHE_HOME="$TMP/cache" \
    timeout 60 nvim --headless -u NORC -i NONE -c "luafile $TMP/probe.lua" -c 'qa!' >"$TMP/nvim.log" 2>&1
probe_ran=no
[ -s "$TMP/probe.out" ] && probe_ran=yes
check "headless probe ran" "$probe_ran" yes
[ "$probe_ran" = yes ] || head -5 "$TMP/nvim.log"
got() { sed -n "s/^$1=//p" "$TMP/probe.out"; }
check "autoread on" "$(got autoread)" true
check "autowriteall on" "$(got autowriteall)" true
check ":B2BAutosave exists" "$(got command)" true
check "a change is written without :w" "$(got saved_after_change)" true
check "the file holds the typed text" "$(got on_disk)" typed
check "a nameless buffer is left alone" "$(got nameless_left_modified)" true
check "a clean buffer follows the file on disk" "$(got reloaded)" true
check ":B2BAutosave off stops saving" "$(got off_keeps_modified)" true
check "InsertLeave saves at once" "$(got insertleave_saves)" true

exit "$fail"
