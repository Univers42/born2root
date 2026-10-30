#!/usr/bin/env hellish
#
# install_home_shared.sh — the login's editor and shell for the other
# accounts, linked from one copy, never duplicated.
#
# install_nvim.sh, install_nvim_extras.sh and hellish's installers build the
# editor and the shell configuration for the login alone. This gives every
# other account the same, by moving the login's copy beside the homes and
# linking each account to it. First boot runs it for the accounts
# born2root.toml names; provision_vm.sh's home-shared action runs it for an
# account made later (vm_share.sh), which first boot never saw.
#
# WHY LINKS
#   A full Neovim per account measured 404 MB of /home each (2026-09-13): 226
#   MB of plugins and parsers, 103 MB of kulala's binaries, 32 MB of mason's
#   language servers -- identical bytes in every home. A copy of the config
#   and of hellish's framework is small but drifts: a fix the login makes
#   reaches nobody else. So the login's copy moves to /home/.b2b-editor and
#   /home/.b2b-shell (same volume as the homes: a rename, no copy), owned by
#   the login so its :lua vim.pack.update(), :Mason and edits keep working,
#   readable by everyone, and a symlink stands where it was, in the login's
#   home and in every other one. The login's own home stays 0700. Another
#   account cannot change what is shared; that is the price, and it is the
#   login's machine.
#
# WHAT STAYS PERSONAL
#   Neovim's state, cache and ~/.nvim-sessions; hellish's hellish.conf (its
#   on/off toggles, `conf` rewrites it: seeded from the login's) and state/
#   (jump history). The extras write the sessions directory as '~/...', so
#   the shared config gives each account its own; an older config carrying
#   the login's home as a literal is rewritten to '~/' once, when it moves.
#
# USAGE
#   sudo SHARE_USERS="bob ana" ./install_home_shared.sh
#   sudo SHARE_OWNER=<login> SHARE_PARTS=shell SHARE_USERS=bob ./install_home_shared.sh
#
# SHARE_PARTS is "editor shell" by default. The editor part is skipped on a
# guest built without Neovim, so the share flow works on every profile. Each
# account is then proven as that account: Neovim's plugin verifier for the
# editor, the shell's loader sourced by hellish with no error for the shell.
# Exits 1 when an account could not be set up.
set -u
B2B_BUILD_CONF="${B2B_BUILD_CONF:-/etc/b2b/build.conf}"
SHARE_OWNER="${SHARE_OWNER:-$(sed -n 's/^B2B_LOGIN=//p' "$B2B_BUILD_CONF" 2>/dev/null | head -n1)}"
SHARE_USERS="${SHARE_USERS:-}"
SHARE_PARTS="${SHARE_PARTS:-editor shell}"
B2B_EDITOR_SHARED="${B2B_EDITOR_SHARED:-/home/.b2b-editor}"
B2B_SHELL_SHARED="${B2B_SHELL_SHARED:-/home/.b2b-shell}"
B2B_NVIM="${B2B_NVIM:-/usr/local/bin/nvim}"
B2B_NVIM_LOG="${B2B_NVIM_LOG:-/var/log/b2b-nvim-install.log}"
# The real shell: the guest's hellish is a wrapper that hands non-interactive
# work to bash (preseeds/b2b-setup.sh), which would load the configuration
# without proving hellish can.
B2B_HELLISH="${B2B_HELLISH:-$(command -v hellish.real || command -v hellish)}"

fail() { printf '[home-shared] FAIL: %s\n' "$*" >&2; }
die() {
    fail "$@"
    exit 1
}

# adopt OWNER PATH SHARED: PATH (a file or a directory in OWNER's home) moves
# to SHARED and a link to it takes its place. A PATH that is already a link,
# or absent, leaves SHARED as it is.
adopt() {
    local owner="$1" path="$2" shared="$3"
    [ -e "$path" ] && [ ! -L "$path" ] || return 0
    rm -rf "${shared:?}"
    mv "$path" "$shared"
    ln -s "$shared" "$path"
    chown -h "$owner:$owner" "$path"
}

# link_to USER PATH SHARED: PATH in USER's home becomes a link to SHARED.
link_to() {
    [ -e "$3" ] || return 0
    rm -rf "${2:?}"
    ln -s "$3" "$2"
    chown -h "$1:$1" "$2"
}

# share_root OWNER DIR: the shared directory, the login's, readable by all.
share_root() {
    mkdir -p "$2"
    chown "$1:$1" "$2"
    chmod 755 "$2"
}

share_editor() {
    local owner="$1" user="$2" owner_home="$3" home="$4" dir
    [ -e "$owner_home/.config/nvim/init.lua" ] || {
        fail "$user: $owner has no Neovim config to share"
        return 1
    }
    share_root "$owner" "$B2B_EDITOR_SHARED"
    [ -L "$owner_home/.config/nvim" ] ||
        sed -i "s#'$owner_home/#'~/#" "$owner_home/.config/nvim/plugin/30-b2b-sessions.lua" 2>/dev/null
    adopt "$owner" "$owner_home/.config/nvim" "$B2B_EDITOR_SHARED/config"
    for dir in site mason kulala.nvim; do
        adopt "$owner" "$owner_home/.local/share/nvim/$dir" "$B2B_EDITOR_SHARED/$dir"
    done
    adopt "$owner" "$owner_home/.tmux.conf" "$B2B_EDITOR_SHARED/tmux.conf"
    chmod -R a+rX "$B2B_EDITOR_SHARED"

    mkdir -p "$home/.config" "$home/.local/share/nvim" "$home/.local/state/nvim" "$home/.cache" "$home/.nvim-sessions"
    chown "$user:$user" "$home/.config" "$home/.local" "$home/.local/share" "$home/.local/share/nvim" \
        "$home/.local/state" "$home/.local/state/nvim" "$home/.cache" "$home/.nvim-sessions"
    link_to "$user" "$home/.config/nvim" "$B2B_EDITOR_SHARED/config"
    for dir in site mason kulala.nvim; do
        link_to "$user" "$home/.local/share/nvim/$dir" "$B2B_EDITOR_SHARED/$dir"
    done
    link_to "$user" "$home/.tmux.conf" "$B2B_EDITOR_SHARED/tmux.conf"
    if timeout 300 runuser -u "$user" -- env HOME="$home" USER="$user" LOGNAME="$user" \
        "$B2B_NVIM" --headless -c 'lua vim.g.b2b_verify_mode = "plugins"' \
        -c "luafile /usr/local/lib/b2b/nvim-verify.lua" >>"$B2B_NVIM_LOG" 2>&1; then
        echo "[OK] $user: Neovim linked to $owner's ($B2B_EDITOR_SHARED)"
    else
        fail "$user: the plugin verifier failed as $user — see $B2B_NVIM_LOG"
        return 1
    fi
}

share_shell() {
    local owner="$1" user="$2" owner_home="$3" home="$4" part out
    if [ ! -f "$owner_home/.hellishrc" ] || [ ! -d "$owner_home/.hellish/lib" ]; then
        fail "$user: $owner has no hellish configuration to share"
        return 1
    fi
    share_root "$owner" "$B2B_SHELL_SHARED"
    adopt "$owner" "$owner_home/.hellishrc" "$B2B_SHELL_SHARED/hellishrc"
    for part in "$owner_home"/.hellish/* "$B2B_SHELL_SHARED"/*; do
        part=$(basename "$part")
        case "$part" in hellishrc | hellish.conf | state | '*') continue ;; esac
        adopt "$owner" "$owner_home/.hellish/$part" "$B2B_SHELL_SHARED/$part"
    done
    chmod -R a+rX "$B2B_SHELL_SHARED"

    if [ -f "$home/.hellishrc" ] && [ ! -L "$home/.hellishrc" ]; then
        mv "$home/.hellishrc" "$home/.hellishrc.bak.$(date +%Y%m%d%H%M%S)"
    fi
    link_to "$user" "$home/.hellishrc" "$B2B_SHELL_SHARED/hellishrc"
    mkdir -p "$home/.hellish/state"
    for part in "$B2B_SHELL_SHARED"/*; do
        part=$(basename "$part")
        [ "$part" != hellishrc ] || continue
        link_to "$user" "$home/.hellish/$part" "$B2B_SHELL_SHARED/$part"
    done
    [ -f "$home/.hellish/hellish.conf" ] || cp "$owner_home/.hellish/hellish.conf" "$home/.hellish/hellish.conf" 2>/dev/null
    [ -f "$home/.hellish/state/original-hellishrc.snapshot" ] ||
        cp "$owner_home/.hellish/state/original-hellishrc.snapshot" "$home/.hellish/state/" 2>/dev/null
    chown "$user:$user" "$home/.hellish"
    chown -R "$user:$user" "$home/.hellish/state"
    [ ! -f "$home/.hellish/hellish.conf" ] || chown "$user:$user" "$home/.hellish/hellish.conf"
    chmod 700 "$home/.hellish/state"
    # shellcheck disable=SC2016 # expanded by the account's shell, not this one
    out=$(cd "$home" && runuser -u "$user" -- env HOME="$home" "$B2B_HELLISH" -c \
        '. "$HOME/.hellishrc"; printf "loaded=%s errors=%s\n" "${#HX_LOADED[@]}" "${#HX_ERRORS[@]}"' </dev/null 2>&1)
    case "$out" in
    *errors=0*) echo "[OK] $user: hellish configuration linked to $owner's ($B2B_SHELL_SHARED), ${out##*$'\n'}" ;;
    *)
        fail "$user: the shared hellish configuration does not load as $user: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
        return 1
        ;;
    esac
}

[ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"
[ -n "$SHARE_OWNER" ] || die "SHARE_OWNER is empty and $B2B_BUILD_CONF names no B2B_LOGIN"
[ -n "$SHARE_USERS" ] || die "SHARE_USERS names no account"
owner_home=$(getent passwd "$SHARE_OWNER" | cut -d: -f6)
[ -d "$owner_home" ] || die "$SHARE_OWNER has no home directory"
status=0
for u in $SHARE_USERS; do
    [ "$u" != "$SHARE_OWNER" ] || continue
    home=$(getent passwd "$u" | cut -d: -f6)
    if [ -z "$home" ] || [ ! -d "$home" ]; then
        fail "$u: no home directory"
        status=1
        continue
    fi
    for part in $SHARE_PARTS; do
        case "$part" in
        editor)
            if [ -x "$B2B_NVIM" ]; then
                share_editor "$SHARE_OWNER" "$u" "$owner_home" "$home" || status=1
            else
                echo "[home-shared] no Neovim on this guest: no editor to share with $u"
            fi
            ;;
        shell) share_shell "$SHARE_OWNER" "$u" "$owner_home" "$home" || status=1 ;;
        *) die "SHARE_PARTS: '$part' is neither editor nor shell" ;;
        esac
    done
done
exit "$status"
