#!/usr/bin/env hellish
#
# test_home_shared.sh — install_home_shared.sh links, never copies.
#
# Accounts invited after first boot (make share_invite) had neither the
# login's Neovim nor hellish's configuration, and the first repair copied
# both into each home: a fix the login made reached nobody else. This pins
# the linking: the login's config, plugins and hellish framework move to one
# shared directory, every account (the login included) links to it, each
# keeps its own hellish.conf and state/, an existing ~/.hellishrc is kept as
# a backup, a second run changes nothing, and a verifier failing as the
# account fails the run. Root, accounts and Neovim are stand-ins.
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
SCRIPT="$REPO_ROOT/setup/install/tools/install_home_shared.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0

check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-52s = %s\n' "$1" "$2"
    else
        printf 'FAIL %-52s = %s (want %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}

own="$TMP/home/own"
bob="$TMP/home/bob"
mkdir -p "$TMP/bin" "$own/.config/nvim/plugin" "$own/.local/share/nvim/site/pack" \
    "$own/.local/share/nvim/mason" "$own/.hellish/lib" "$own/.hellish/rc.d" "$own/.hellish/state" "$bob"
echo 'require("b2b")' >"$own/.config/nvim/init.lua"
echo "local session_dir = vim.fn.expand '$own/.nvim-sessions'" >"$own/.config/nvim/plugin/30-b2b-sessions.lua"
echo 'set -g mouse on' >"$own/.tmux.conf"
echo 'hx_loader=1' >"$own/.hellishrc"
echo 'hx_core=1' >"$own/.hellish/lib/core.hsh"
echo 'prompt=on' >"$own/.hellish/hellish.conf"
echo 'own jumps' >"$own/.hellish/state/jumps"
echo 'echo bob' >"$bob/.hellishrc"
printf 'own:x:1000:1000::%s:/usr/bin/hellish\nbob:x:1001:1001::%s:/usr/bin/hellish\n' "$own" "$bob" >"$TMP/passwd"

printf '#!/bin/sh\necho 0\n' >"$TMP/bin/id"
printf '#!/bin/sh\nexit 0\n' >"$TMP/bin/chown"
printf '#!/bin/sh\nshift 3\nexec "$@"\n' >"$TMP/bin/runuser"
cat >"$TMP/bin/getent" <<'GETENTEOF'
#!/bin/sh
grep "^$2:" "$(dirname "$0")/../passwd"
GETENTEOF
printf '#!/bin/sh\nexit 0\n' >"$TMP/bin/nvim-ok"
printf '#!/bin/sh\nexit 1\n' >"$TMP/bin/nvim-bad"
printf '#!/bin/sh\necho loaded=1 errors=0\n' >"$TMP/bin/hellish-ok"
printf '#!/bin/sh\necho loaded=1 errors=2\n' >"$TMP/bin/hellish-bad"
chmod +x "$TMP/bin/"*

run() {
    env PATH="$TMP/bin:$PATH" B2B_BUILD_CONF=/dev/null SHARE_OWNER=own SHARE_USERS="own bob" \
        B2B_EDITOR_SHARED="$TMP/home/.b2b-editor" B2B_SHELL_SHARED="$TMP/home/.b2b-shell" B2B_NVIM_LOG="$TMP/nvim.log" B2B_HELLISH="$TMP/bin/hellish-ok" \
        "$@" "${SCRIPT_SH:-bash}" "$SCRIPT" >"$TMP/out" 2>&1
}

run B2B_NVIM="$TMP/bin/nvim-ok"
check "both parts set up" "$?" 0
check "the login's config is a link to the shared one" "$(readlink "$own/.config/nvim")" "$TMP/home/.b2b-editor/config"
check "bob's config is the same link" "$(readlink "$bob/.config/nvim")" "$TMP/home/.b2b-editor/config"
check "the sessions dir is each account's own" \
    "$(grep -c "expand '~/.nvim-sessions'" "$TMP/home/.b2b-editor/config/plugin/30-b2b-sessions.lua")" 1
check "bob's plugins are linked" "$(readlink "$bob/.local/share/nvim/site")" "$TMP/home/.b2b-editor/site"
check "bob's tmux.conf is linked" "$(readlink "$bob/.tmux.conf")" "$TMP/home/.b2b-editor/tmux.conf"
check "bob's own state dir is a directory" "$([ -d "$bob/.local/state/nvim" ] && [ ! -L "$bob/.local/state/nvim" ] && echo dir)" dir
check "bob's .hellishrc is linked" "$(readlink "$bob/.hellishrc")" "$TMP/home/.b2b-shell/hellishrc"
check "bob's old .hellishrc is kept" "$(cat "$bob"/.hellishrc.bak.*)" 'echo bob'
check "the framework is linked" "$(readlink "$bob/.hellish/lib")" "$TMP/home/.b2b-shell/lib"
check "bob's hellish.conf is his own file" "$([ -f "$bob/.hellish/hellish.conf" ] && [ ! -L "$bob/.hellish/hellish.conf" ] && cat "$bob/.hellish/hellish.conf")" 'prompt=on'
check "bob's state is private and empty" "$(stat -c %a "$bob/.hellish/state"):$(find "$bob/.hellish/state" -mindepth 1 | wc -l)" 700:0
check "the login keeps its own hellish.conf" "$([ -L "$own/.hellish/hellish.conf" ] || cat "$own/.hellish/hellish.conf")" 'prompt=on'
check "the login keeps its own state" "$(cat "$own/.hellish/state/jumps")" 'own jumps'
check "the login's framework is linked back" "$(readlink "$own/.hellish/lib")" "$TMP/home/.b2b-shell/lib"

run B2B_NVIM="$TMP/bin/nvim-ok"
check "a second run succeeds" "$?" 0
check "and the shared config survives it" "$(cat "$TMP/home/.b2b-editor/config/init.lua")" 'require("b2b")'
check "and the shared framework survives it" "$(cat "$TMP/home/.b2b-shell/lib/core.hsh")" 'hx_core=1'
check "and no second backup of the link is made" "$(find "$bob" -maxdepth 1 -name '.hellishrc.bak.*' | wc -l)" 1

run B2B_NVIM="$TMP/bin/nvim-bad" SHARE_PARTS=editor
check "a verifier failing as bob fails the run" "$?" 1
check "and names him" "$(grep -c 'FAIL: bob: the plugin verifier' "$TMP/out")" 1

run B2B_HELLISH="$TMP/bin/hellish-bad" SHARE_PARTS=shell
check "a configuration hellish cannot load fails the run" "$?" 1

run B2B_NVIM="$TMP/bin/absent" SHARE_PARTS=editor
check "no Neovim on the guest: nothing to share, no failure" "$?" 0

exit "$fail"
