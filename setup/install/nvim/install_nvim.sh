#!/usr/bin/env hellish
#
# install_nvim.sh — install a CURRENT Neovim plus kickstart.nvim on Debian.
#
# WHY THIS EXISTS
# ---------------
# Debian 13 (trixie) ships neovim 0.10.4. kickstart.nvim's master branch is
# built on `vim.pack`, Neovim's built-in plugin manager, which did not exist
# before 0.12. So `apt install neovim` produces a config that errors out on the
# first line of the plugin section. There is no backport and no official Debian
# package for 0.12 — the upstream release tarball is the supported route, so
# that is what this installs, under /opt, leaving dpkg's world untouched.
#
# WHAT IT DOES (all steps are idempotent — re-running is safe)
#   1. apt: the tools kickstart shells out to (ripgrep, fd, gcc, unzip, …)
#   2. Neovim ${NVIM_VERSION} tarball -> /opt/nvim-<ver>, symlinked to /usr/local/bin/nvim
#   3. update-alternatives so `vi`, `vim` and $EDITOR point at it
#   4. the node + python3 providers, so `:checkhealth` comes back clean
#   5. kickstart.nvim cloned into each target user's ~/.config/nvim
#   6. a headless first run, so plugins/LSPs/parsers are installed at build
#      time instead of on the user's first, very slow, interactive start --
#      retried, then VERIFIED: the script exits 1 when a plugin, parser or
#      language server the config declares is not on disk afterwards
#   7. `:checkhealth` written to ~/.local/state/nvim/checkhealth.log
#
# USAGE
#   sudo ./install_nvim.sh                       # default: user dlesieur
#   sudo NVIM_USERS="dlesieur root" ./install_nvim.sh
#   sudo NVIM_VERSION=latest ./install_nvim.sh    # newest release, unpinned
#   sudo NVIM_BOOTSTRAP=0 ./install_nvim.sh       # skip the slow plugin install
#   sudo NVIM_FORCE_CONFIG=1 ./install_nvim.sh    # re-clone kickstart over an existing config

set -u

# Runs from a login shell over SSH, from `sudo env ... bash`, and from @reboot
# cron on first boot. Only the first is guaranteed to carry /usr/local/bin,
# which is where this script puts nvim and where npm puts its globals.
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# The npm prefix is moved to /opt by install_global_scope.sh, and npm's own
# bin directory is NOT on the default PATH. Without this line a package this
# script installs itself (tree-sitter, the neovim provider) is invisible to the very next
# `command -v` that checks for it -- installed, working, and reported missing.
# Ask npm where it actually is rather than hardcoding the location.
if command -v npm >/dev/null 2>&1; then
    _npm_prefix=$(npm config get prefix --global 2>/dev/null)
    case "$_npm_prefix" in
    /*) [ -d "${_npm_prefix}/bin" ] && PATH="${_npm_prefix}/bin:$PATH" ;;
    esac
    unset _npm_prefix
fi
export PATH

# ── Configuration ───────────────────────────────────────────────────────────
# Pinned by default: a build that silently changes Neovim version between runs
# is not reproducible, and kickstart's requirements move with it. Set
# NVIM_VERSION=latest to track the newest release instead.
NVIM_VERSION="${NVIM_VERSION:-v0.12.5}"
NVIM_MIN_VERSION="${NVIM_MIN_VERSION:-0.12.0}" # what kickstart master needs (vim.pack)
NVIM_OPT_DIR="${NVIM_OPT_DIR:-/opt}"
NVIM_USERS="${NVIM_USERS:-dlesieur}"
KICKSTART_REPO="${KICKSTART_REPO:-https://github.com/nvim-lua/kickstart.nvim.git}"
NVIM_BOOTSTRAP="${NVIM_BOOTSTRAP:-1}"
NVIM_FORCE_CONFIG="${NVIM_FORCE_CONFIG:-0}"
NVIM_PYTHON_VENV="${NVIM_PYTHON_VENV:-/opt/nvim-venv}"
# NVIM_PURGE=1 removes every trace of a previous install first -- the config,
# the downloaded plugins, the compiled parsers, the state and cache dirs, and
# the /opt tree. Two reasons it exists:
#
#   * recovery: a half-finished plugin download or a config edited by hand
#     leaves a machine that no amount of re-running will repair, because every
#     step here is deliberately idempotent and skips what already exists;
#   * reproducibility: it is the only way to prove that a from-scratch run
#     really does produce a working editor. Fixing a VM by hand until it works
#     says nothing about what the next `make all` will build.
NVIM_PURGE="${NVIM_PURGE:-0}"
# The headless bootstrap clones ~30 plugins and compiles treesitter parsers.
# On a NAT'd VM with a cold cache that is minutes, not seconds — but it must
# not hang the whole build either, hence a hard cap per phase.
NVIM_BOOTSTRAP_TIMEOUT="${NVIM_BOOTSTRAP_TIMEOUT:-900}"
# Where the two Lua helpers the bootstrap runs inside Neovim are installed.
# install_nvim_extras.sh runs the same two after its own plugin layer.
B2B_LIB_DIR="${B2B_LIB_DIR:-/usr/local/lib/b2b}"

log() { printf '[nvim] %s\n' "$*"; }
warn() { printf '[nvim] WARN: %s\n' "$*" >&2; }
die() {
    printf '[nvim] ERROR: %s\n' "$*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"

case "$(uname -m)" in
x86_64 | amd64) NVIM_ARCH="x86_64" ;;
aarch64 | arm64) NVIM_ARCH="arm64" ;;
*) die "unsupported architecture: $(uname -m)" ;;
esac

# ── 1. Dependencies ─────────────────────────────────────────────────────────
# Everything kickstart or its plugins actually execute:
#   git/curl/tar/unzip/gzip  fetching plugins and Mason packages
#   gcc g++ make             treesitter parsers, telescope-fzf-native, LuaSnip's jsregexp
#   ripgrep fd-find          telescope's live_grep and file finder
#   xclip                    the `unnamedplus` clipboard kickstart turns on
#   nodejs npm               the node provider AND most Mason-installed language servers
#   python3-venv             the python3 provider (PEP 668 forbids a bare pip install)
install_deps() {
    log "installing build + runtime dependencies via apt"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || warn "apt-get update failed — continuing with the current index"

    local pkgs="git curl wget tar gzip unzip xz-utils ca-certificates \
        build-essential gcc g++ make pkg-config \
        ripgrep fd-find xclip \
        python3 python3-venv python3-pip \
        nodejs npm"

    # One package at a time would be slower but a single missing name aborts the
    # whole batch, so fall back to per-package installs only if the batch fails.
    # shellcheck disable=SC2086
    if ! apt-get install -y -qq -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold $pkgs; then
        warn "batch install failed — retrying package by package"
        local p
        for p in $pkgs; do
            apt-get install -y -qq "$p" 2>/dev/null ||
                warn "could not install $p"
        done
    fi

    # Debian ships fd as `fdfind` to avoid a name clash with fdclone. Telescope
    # looks for `fd` first, so give it one — /usr/local/bin is dpkg-free space.
    if command -v fdfind >/dev/null 2>&1 && ! command -v fd >/dev/null 2>&1; then
        ln -sf "$(command -v fdfind)" /usr/local/bin/fd
        log "linked fdfind -> /usr/local/bin/fd"
    fi

    apt-get clean 2>/dev/null || true
    log "dependencies installed"
}

# ── 2. Neovim itself ────────────────────────────────────────────────────────
resolve_version() {
    if [ "$NVIM_VERSION" != "latest" ]; then
        printf '%s' "$NVIM_VERSION"
        return 0
    fi
    local tag
    tag=$(curl -fsSL --retry 3 --max-time 30 \
        https://api.github.com/repos/neovim/neovim/releases/latest 2>/dev/null |
        sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
    [ -n "$tag" ] || die "could not resolve the latest Neovim release (network/API problem)"
    printf '%s' "$tag"
}

# version_ge <a> <b> — true when version a >= version b, numerically per field.
version_ge() {
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

install_neovim() {
    local tag prefix tarball url tmp expected actual
    tag=$(resolve_version) || exit 1
    prefix="${NVIM_OPT_DIR}/nvim-${tag}"

    if [ -x "${prefix}/bin/nvim" ]; then
        log "Neovim ${tag} already present at ${prefix} — skipping download"
    else
        # Asset naming changed at 0.10.4: nvim-linux64 -> nvim-linux-x86_64.
        # Try the modern name first and fall back, so an older pin still works.
        tmp=$(mktemp -d) || die "mktemp failed"
        trap 'rm -rf "$tmp"' RETURN

        local candidates="nvim-linux-${NVIM_ARCH}.tar.gz"
        [ "$NVIM_ARCH" = "x86_64" ] && candidates="$candidates nvim-linux64.tar.gz"

        local got=""
        for tarball in $candidates; do
            url="https://github.com/neovim/neovim/releases/download/${tag}/${tarball}"
            log "downloading ${url}"
            if curl -fL --retry 3 --retry-delay 2 --max-time 600 \
                -o "${tmp}/${tarball}" "$url" 2>/dev/null; then
                got="$tarball"
                break
            fi
            warn "asset ${tarball} not available for ${tag}"
        done
        [ -n "$got" ] || die "no Neovim tarball found for ${tag} (${NVIM_ARCH})"

        # Integrity. Two layers, because Neovim's release assets changed:
        #
        #  1. A published checksum, when there is one. Releases up to ~0.10
        #     shipped shasum.txt; some ship <asset>.sha256sum. Current releases
        #     (0.12.x) publish NEITHER — they use GitHub build attestations
        #     instead — so a missing checksum file is normal, not suspicious,
        #     and must not be treated as a failure.
        #  2. Always: decompress the archive and check it end to end. That is
        #     what actually catches the realistic failure here — a download
        #     truncated by the VM's NAT dropping the connection mid-transfer,
        #     which would otherwise unpack as a half-populated /opt tree.
        expected=""
        if curl -fsSL --max-time 60 -o "${tmp}/shasum.txt" \
            "https://github.com/neovim/neovim/releases/download/${tag}/shasum.txt" 2>/dev/null; then
            expected=$(awk -v f="$got" '$2 == f || $2 == "*"f {print $1}' "${tmp}/shasum.txt" | head -n1)
        elif curl -fsSL --max-time 60 -o "${tmp}/asset.sha256" \
            "https://github.com/neovim/neovim/releases/download/${tag}/${got}.sha256sum" 2>/dev/null; then
            expected=$(awk '{print $1; exit}' "${tmp}/asset.sha256")
        fi
        if [ -n "$expected" ]; then
            actual=$(sha256sum "${tmp}/${got}" | awk '{print $1}')
            [ "$expected" = "$actual" ] ||
                die "checksum mismatch for ${got} (expected ${expected}, got ${actual})"
            log "published checksum verified"
        else
            log "release ${tag} publishes no checksum file — relying on the archive test below"
        fi

        gzip -t "${tmp}/${got}" 2>/dev/null ||
            die "downloaded ${got} is not a valid gzip stream (truncated download?)"
        tar -tzf "${tmp}/${got}" >/dev/null 2>&1 ||
            die "downloaded ${got} is not a readable tar archive"
        log "archive integrity verified"

        # Unpack into a staging dir, then move into place, so a failure part-way
        # through never leaves a half-populated ${prefix} that looks installed.
        mkdir -p "${tmp}/x"
        tar -xzf "${tmp}/${got}" -C "${tmp}/x" || die "tar extraction failed"
        local top
        top=$(find "${tmp}/x" -mindepth 1 -maxdepth 1 -type d | head -n1)
        [ -n "$top" ] || die "unexpected tarball layout"
        rm -rf "${prefix}.new"
        mv "$top" "${prefix}.new" || die "could not stage ${prefix}.new"
        rm -rf "$prefix"
        mv "${prefix}.new" "$prefix" || die "could not install into ${prefix}"
        rm -rf "$tmp"
        trap - RETURN
        log "installed Neovim ${tag} into ${prefix}"
    fi

    ln -sfn "$prefix" "${NVIM_OPT_DIR}/nvim"
    ln -sf "${NVIM_OPT_DIR}/nvim/bin/nvim" /usr/local/bin/nvim

    # A profile drop-in for the man pages and for anyone who prefers the real
    # path on PATH; the symlink above is what actually makes `nvim` resolve.
    cat >/etc/profile.d/nvim.sh <<'PROFILE'
# Added by born2root setup/install/nvim/install_nvim.sh
export PATH="/opt/nvim/bin:$PATH"
export MANPATH="/opt/nvim/share/man:${MANPATH:-}"
PROFILE
    chmod 644 /etc/profile.d/nvim.sh

    # Make it the system editor. Priority 60 beats Debian's vim (30) and nano (40).
    local alt
    for alt in editor vi vim; do
        update-alternatives --install "/usr/bin/$alt" "$alt" /usr/local/bin/nvim 60 >/dev/null 2>&1 || true
        update-alternatives --set "$alt" /usr/local/bin/nvim >/dev/null 2>&1 || true
    done

    local have
    have=$(/usr/local/bin/nvim --version 2>/dev/null | head -n1 | sed 's/^NVIM v//')
    [ -n "$have" ] || die "nvim did not run after install"
    log "nvim reports: v${have}"
    version_ge "$have" "$NVIM_MIN_VERSION" ||
        die "installed Neovim v${have} is older than the ${NVIM_MIN_VERSION} kickstart.nvim requires"
}

# ── 3. Providers ────────────────────────────────────────────────────────────
# `:checkhealth` reports a warning for each missing provider. Node and Python
# are cheap and genuinely useful (several Mason packages are npm modules), so
# install them; perl and ruby are switched off explicitly in the Lua drop-in
# rather than left to warn forever about tooling nobody here wants.
install_providers() {
    if command -v npm >/dev/null 2>&1; then
        log "installing the node provider (npm i -g neovim)"
        npm install -g neovim >/dev/null 2>&1 || warn "npm install -g neovim failed"

        # The tree-sitter CLI is NOT optional here, despite reading like a
        # developer tool. kickstart tracks nvim-treesitter's `main` branch, and
        # on main every :TSInstall shells out to `tree-sitter build`. Without
        # the CLI on PATH each parser fails with
        #     Error during "tree-sitter build": ENOENT (cmd): 'tree-sitter'
        # and you end up with no syntax highlighting at all -- which then also
        # takes out rainbow-delimiters and treesitter-context, since both read
        # the parse tree.
        #
        # Debian does package it, but trixie is on 0.22.6 and nvim-treesitter
        # main expects a 0.25+ CLI, so npm's build is the one that works.
        if ! command -v tree-sitter >/dev/null 2>&1; then
            log "installing the tree-sitter CLI (required by nvim-treesitter main)"
            npm install -g tree-sitter-cli >/dev/null 2>&1 ||
                warn "npm install -g tree-sitter-cli failed — parsers will not compile"
        fi
        if command -v tree-sitter >/dev/null 2>&1; then
            log "tree-sitter CLI: $(tree-sitter --version 2>/dev/null || echo '?')"
        else
            warn "no tree-sitter CLI on PATH — treesitter parsers will not build"
        fi
    else
        warn "npm not available — skipping the node provider and the tree-sitter CLI"
    fi

    # Debian marks the system python3 as externally managed (PEP 668), so pynvim
    # goes in its own venv and nvim is pointed at that interpreter.
    log "installing the python3 provider into ${NVIM_PYTHON_VENV}"
    if [ ! -x "${NVIM_PYTHON_VENV}/bin/python" ]; then
        python3 -m venv "$NVIM_PYTHON_VENV" >/dev/null 2>&1 ||
            warn "could not create ${NVIM_PYTHON_VENV}"
    fi
    if [ -x "${NVIM_PYTHON_VENV}/bin/pip" ]; then
        "${NVIM_PYTHON_VENV}/bin/pip" install --quiet --upgrade pip pynvim >/dev/null 2>&1 ||
            warn "pip install pynvim failed"
        chmod -R a+rX "$NVIM_PYTHON_VENV" 2>/dev/null || true
    fi
}

# ── 4. Per-user kickstart config ────────────────────────────────────────────
# The clone is left as a pristine checkout of upstream master so `git pull` in
# ~/.config/nvim keeps working. Local settings live in plugin/00-b2b-local.lua
# — Neovim sources plugin/*.lua from the config dir automatically, after
# init.lua — and that file is git-ignored via .git/info/exclude so the checkout
# stays clean.
LOCAL_PLUGIN_REL="plugin/00-b2b-local.lua"

write_local_plugin() {
    local cfg="$1"
    mkdir -p "${cfg}/plugin"
    cat >"${cfg}/${LOCAL_PLUGIN_REL}" <<LOCALEOF
-- 00-b2b-local.lua — machine-local Neovim settings for the Born2beRoot VM.
--
-- Written by setup/install/nvim/install_nvim.sh. Sourced automatically after
-- init.lua because Neovim reads plugin/*.lua from the config directory, which
-- keeps the kickstart.nvim checkout beside it pristine and pullable.
--
-- Edit freely: the installer only rewrites this file when it runs again.

-- Point the python3 provider at the venv the installer built. Debian's system
-- python3 is PEP 668 externally-managed, so pynvim cannot live there.
local venv_python = '${NVIM_PYTHON_VENV}/bin/python3'
if vim.fn.executable(venv_python) == 1 then vim.g.python3_host_prog = venv_python end

-- Perl and Ruby providers are off on purpose. Nothing in this config uses them
-- and leaving them unset makes :checkhealth warn on every run forever.
vim.g.loaded_perl_provider = 0
vim.g.loaded_ruby_provider = 0

-- This VM is reached over SSH with no X display, so the OS clipboard kickstart
-- asks for ('unnamedplus') has nothing to talk to and every yank would stall on
-- a failing xclip. Fall back to Neovim's own registers when there is no display.
if vim.env.DISPLAY == nil and vim.env.WAYLAND_DISPLAY == nil then
  vim.schedule(function() vim.o.clipboard = '' end)
end
LOCALEOF
    chmod 644 "${cfg}/${LOCAL_PLUGIN_REL}"
}

setup_user_config() {
    local user="$1" home cfg
    home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
    if [ -z "$home" ] || [ ! -d "$home" ]; then
        warn "user '${user}' has no home directory — skipping"
        return 1
    fi
    cfg="${home}/.config/nvim"

    if [ -d "${cfg}/.git" ] && [ "$NVIM_FORCE_CONFIG" != "1" ]; then
        log "${user}: ${cfg} already exists — leaving it alone (NVIM_FORCE_CONFIG=1 to replace)"
    else
        if [ -e "$cfg" ]; then
            local backup
            backup="${cfg}.bak.$(date +%Y%m%d%H%M%S)"
            log "${user}: moving existing config aside -> ${backup}"
            mv "$cfg" "$backup" || {
                warn "${user}: could not back up ${cfg}"
                return 1
            }
        fi
        log "${user}: cloning kickstart.nvim into ${cfg}"
        mkdir -p "${home}/.config"
        if ! git clone --depth 1 "$KICKSTART_REPO" "$cfg" >/dev/null 2>&1; then
            warn "${user}: git clone of ${KICKSTART_REPO} failed"
            return 1
        fi
    fi

    write_local_plugin "$cfg"

    # Keep the drop-in out of `git status` without touching .gitignore, which
    # belongs to upstream.
    if [ -d "${cfg}/.git" ]; then
        mkdir -p "${cfg}/.git/info"
        grep -qxF "$LOCAL_PLUGIN_REL" "${cfg}/.git/info/exclude" 2>/dev/null ||
            printf '%s\n' "$LOCAL_PLUGIN_REL" >>"${cfg}/.git/info/exclude"
    fi

    # Everything under the user's home must belong to the user, not to root —
    # this whole script runs as root, and nvim refuses to write state it cannot own.
    local group
    group=$(id -gn "$user" 2>/dev/null || echo "$user")
    mkdir -p "${home}/.local/share/nvim" "${home}/.local/state/nvim" "${home}/.cache/nvim"
    chown -R "${user}:${group}" \
        "${home}/.config" "${home}/.local/share/nvim" \
        "${home}/.local/state/nvim" "${home}/.cache/nvim" 2>/dev/null || true
    return 0
}

# ── 5. Headless bootstrap + health report ───────────────────────────────────
# Without this, the user's first `nvim` sits for several minutes cloning
# plugins and compiling parsers behind a blank screen. Doing it at build time
# also means a broken plugin set fails the build instead of the user.
#
# Run a command as <user>, with a terminal type Neovim can work with.
#
# TERM matters more than it looks. A non-interactive SSH session -- which is
# exactly how the host provisioner and @reboot cron both get here -- leaves
# TERM=dumb, and several of Neovim's own health checks shell out to terminfo:
# `:checkhealth` then reports
#     ERROR command failed: { "infocmp", "-L" }
# and a couple of plugin checks come back empty, so the saved report is full of
# failures that do not exist in the terminal the user actually opens. Verified:
# the same report run with TERM=xterm-256color has zero errors.
run_as_user() {
    local user="$1"
    shift
    set -- env "TERM=${NVIM_TERM:-xterm-256color}" "$@"
    if [ "$user" = "root" ]; then
        timeout "$NVIM_BOOTSTRAP_TIMEOUT" "$@"
    else
        # runuser keeps a clean environment and does not need PAM's auth stack.
        timeout "$NVIM_BOOTSTRAP_TIMEOUT" runuser -u "$user" -- "$@"
    fi
}

# `vim.pack.add` asks "These plugins will be installed: ... Proceed?" before
# its first install (its `confirm` option defaults to true). A headless Neovim
# takes the dialog's default answer, which happens to be Yes -- an accident of
# do_dialog(), not a contract. This --cmd runs before init.lua and replaces
# vim.pack.add, for this process only, with one that never asks.
NVIM_NO_CONFIRM='lua local add = vim.pack.add; vim.pack.add = function(specs, opts) opts = opts or {}; if opts.confirm == nil then opts.confirm = false end; return add(specs, opts) end'

# ── A full disk, named ──────────────────────────────────────────────────────
# vim.pack reports a failed clone as a NOTIFICATION, not an error, and Mason's
# downloads surface as curl(23) "Failure writing output" -- so on a full /home
# the bootstrap exits 0, installs nothing, and the retry loop tries twice more
# for nothing. Measured on the 2026-09-12 VirtualBox build: 132 "Installing
# plugins" lines, zero plugins on disk, and not one line saying "no space".
#
# So: refuse before spending the time, and if a run still hits ENOSPC, say so
# in the words the log actually contains. HOME_MIN_MB is nvim + nvim-extras
# from generate/feature_profile.sh's manifest, with room over.
NVIM_HOME_MIN_MB="${NVIM_HOME_MIN_MB:-400}"
free_mb() { df -Pm "$1" 2>/dev/null | awk 'NR == 2 { print $4 }'; }
enospc_in() { grep -qiE 'ENOSPC|no space left on device|Failure writing output' "$1" 2>/dev/null; }

# Fails the bootstrap rather than warning: every later step depends on the
# plugins being on disk, and each one costs minutes before failing on its own.
check_home_space() {
    local user="$1" home avail
    home=$(getent passwd "$user" | cut -d: -f6)
    avail=$(free_mb "$home")
    case "$avail" in
    '' | *[!0-9]*)
        warn "${user}: could not read free space on ${home} — continuing"
        return 0
        ;;
    esac
    if [ "$avail" -lt "$NVIM_HOME_MIN_MB" ]; then
        warn "${user}: ${home} has only ${avail} MB free (needs ${NVIM_HOME_MIN_MB})"
        warn "  the plugins, their parsers, Mason's servers and npm's cache all live there."
        warn "  Biggest things in it:"
        du -sm "${home}"/.[!.]* "${home}"/* 2>/dev/null | sort -rn | head -5 |
            awk '{ printf "[nvim]       %6s MB  %s\n", $1, $2 }'
        warn "  Free some, or rebuild with more: make all SIZE_B2B=20"
        return 1
    fi
    log "${user}: ${avail} MB free on ${home}"
    return 0
}

# nvim_headless <user> <nvim args...>: a headless Neovim run as <user>, its
# output KEPT. Every run is appended to ~/.local/state/nvim/bootstrap.log, and
# everything but vim.pack's progress counter is echoed here. The 2026-09-12
# build sent this output to /dev/null: its first boot left 38 plugins missing
# in under a second and not one line saying why. Returns Neovim's own status.
nvim_headless() {
    local user="$1" home out rc
    shift
    home=$(getent passwd "$user" | cut -d: -f6)
    out=$(mktemp /var/tmp/b2b-nvim.XXXXXX 2>/dev/null) || out="/var/tmp/b2b-nvim.$$"
    run_as_user "$user" /usr/local/bin/nvim --headless --cmd "$NVIM_NO_CONFIRM" "$@" >"$out" 2>&1
    rc=$?
    mkdir -p "${home}/.local/state/nvim"
    tr '\r' '\n' <"$out" | grep -v '^$' >>"${home}/.local/state/nvim/bootstrap.log"
    tr '\r' '\n' <"$out" | grep -v '^$' |
        grep -vE '^vim\.pack: ([0-9]+% )?Installing plugins \([0-9]+/[0-9]+\)' |
        sed 's/^/[nvim]     /'
    if enospc_in "$out"; then
        warn "the disk filled up during that run (ENOSPC) — everything after it is unreliable"
        NVIM_ENOSPC=1
    fi
    rm -f "$out"
    return "$rc"
}

# The two Lua helpers, written once to ${B2B_LIB_DIR} so install_nvim_extras.sh
# runs the same code after its layer. Both read the config that is actually
# installed rather than carrying their own copy of its lists:
#
#   nvim-parsers.lua   installs the tree-sitter parsers kickstart names
#                      (`local parsers = { ... }` in init.lua) plus the extras'
#                      B2B.parsers when that layer is present, and WAITS for
#                      them. nvim-treesitter's `main` branch installs
#                      asynchronously; a plain headless start exits under it.
#   nvim-verify.lua    the verdict: every plugin vim.pack knows about is on
#                      disk with code in it, every wanted parser is installed,
#                      Mason's tools are executable, and the prebuilt binaries
#                      the extras fetch are there. Exits 1 with one PROBLEM
#                      line per finding, which is what fails the build.
write_lua_helpers() {
    mkdir -p "$B2B_LIB_DIR"
    cat >"${B2B_LIB_DIR}/nvim-parsers.lua" <<'LUAEOF'
-- nvim-parsers.lua — written by setup/install/nvim/install_nvim.sh.
-- Run inside a headless Neovim with the user's config loaded:
--   nvim --headless -c 'luafile /usr/local/lib/b2b/nvim-parsers.lua' -c qa
local ok, ts = pcall(require, 'nvim-treesitter')
if not ok then
  print 'parsers: nvim-treesitter is not installed'
  return
end

local want = {}
local init = vim.fn.stdpath 'config' .. '/init.lua'
if vim.fn.filereadable(init) == 1 then
  local src = table.concat(vim.fn.readfile(init), '\n')
  local list = src:match 'local parsers = {(.-)}'
  if list then
    for name in list:gmatch "'([%w_]+)'" do want[#want + 1] = name end
  end
end
if _G.B2B and _G.B2B.parsers then vim.list_extend(want, _G.B2B.parsers) end
if #want == 0 then
  print 'parsers: no parser list found (init.lua has no `local parsers = {...}`)'
  return
end

local function missing()
  local installed = ts.get_installed 'parsers'
  return vim.tbl_filter(function(l) return not vim.tbl_contains(installed, l) end, want)
end

-- 10 minutes, deliberately under the `timeout $NVIM_BOOTSTRAP_TIMEOUT` the
-- shell wraps this in (900 s here, 1200 s in install_nvim_extras.sh): a wait
-- that outlives its own timeout is killed mid-compile with no message.
local WAIT_MS = vim.g.b2b_parser_wait_ms or 600000
local todo = missing()
if #todo > 0 then
  print('parsers: installing ' .. table.concat(todo, ' '))
  local task = ts.install(todo)
  if task and task.wait then task:wait(WAIT_MS) end
end
local still = missing()
print(('parsers: %d wanted, %d installed, %d missing%s'):format(
  #want, #want - #still, #still, #still > 0 and (': ' .. table.concat(still, ' ')) or ''))
LUAEOF

    cat >"${B2B_LIB_DIR}/nvim-verify.lua" <<'LUAEOF'
-- nvim-verify.lua — written by setup/install/nvim/install_nvim.sh.
-- Run inside a headless Neovim with the user's config loaded; exits 1 when
-- anything the config declares is not actually installed:
--   nvim --headless -c 'luafile /usr/local/lib/b2b/nvim-verify.lua'
-- `vim.g.b2b_verify_mode` scopes it to the layer being installed:
--   'plugins'  plugin checks only (used between install attempts, before
--              parsers and Mason have had their turn)
--   'base'     plugins, parsers, Mason and blink.cmp's fuzzy library -- what
--              install_nvim.sh installs itself
--   'all'      the above plus artifacts only install_nvim_extras.sh provides
--              (default, and what the extras layer verifies with)
-- The split is not cosmetic: install_nvim.sh runs BEFORE the extras layer, and
-- verifying markdown-preview's downloaded server binary there made it fail on
-- every machine that already had the extras config -- the plugin is declared
-- by that config, so it installs, while the binary arrives one script later.
-- The build then wrote PROVISION_FAILED for an artifact that was about to
-- appear, and `make all` stopped on it.
local mode = vim.g.b2b_verify_mode or 'all'
local problems = {}
local function problem(fmt, ...) problems[#problems + 1] = fmt:format(...) end

-- 1. Plugins: everything vim.pack knows about is on disk with code in it. A
-- directory is not enough -- a repository whose default branch was emptied
-- upstream clones perfectly and installs nothing (leap.nvim on GitHub).
local plugins = (vim.pack and vim.pack.get) and vim.pack.get() or {}
local code_dirs = { 'lua', 'plugin', 'autoload', 'after', 'colors', 'ftplugin', 'syntax' }
for _, p in ipairs(plugins) do
  if vim.fn.isdirectory(p.path) == 0 then
    problem('plugin missing: %s', p.spec.name)
  else
    local has_code = false
    for _, d in ipairs(code_dirs) do
      if vim.fn.isdirectory(p.path .. '/' .. d) == 1 then has_code = true end
    end
    if not has_code then problem('plugin empty: %s (%s)', p.spec.name, p.spec.src) end
  end
end
-- The born2root layer keeps its own status per spec, plus setup errors.
if _G.B2B then
  for _, spec in ipairs(_G.B2B.specs or {}) do
    local name = _G.B2B.spec_name(spec)
    local st = _G.B2B.status(name)
    if st ~= 'ok' then problem('extras %s: %s', st, name) end
  end
  for _, err in ipairs(_G.B2B.problems or {}) do
    problem('extras setup: %s', (err:gsub('\n.*', '')))
  end
end

local parsers_installed = 0
if mode ~= 'plugins' then
  -- 2. Parsers: the same want-list nvim-parsers.lua installs.
  local ok, ts = pcall(require, 'nvim-treesitter')
  if ok then
    local want = {}
    local init = vim.fn.stdpath 'config' .. '/init.lua'
    if vim.fn.filereadable(init) == 1 then
      local list = table.concat(vim.fn.readfile(init), '\n'):match 'local parsers = {(.-)}'
      if list then
        for name in list:gmatch "'([%w_]+)'" do want[#want + 1] = name end
      end
    end
    if _G.B2B and _G.B2B.parsers then vim.list_extend(want, _G.B2B.parsers) end
    local installed = ts.get_installed 'parsers'
    parsers_installed = #installed
    for _, l in ipairs(want) do
      if not vim.tbl_contains(installed, l) then problem('parser missing: %s', l) end
    end
  else
    problem 'nvim-treesitter is not installed'
  end

  -- 3. Mason: kickstart asks mason-tool-installer for lua_ls and stylua
  -- (init.lua, `servers` + `ensure_installed`); these are the names Mason
  -- installs them under. Executable, not just present.
  local mason_bin = vim.fn.stdpath 'data' .. '/mason/bin/'
  for _, tool in ipairs { 'lua-language-server', 'stylua' } do
    if vim.fn.executable(mason_bin .. tool) ~= 1 then problem('mason tool missing: %s', tool) end
  end

  -- 4. Prebuilt binaries the plugins do not ship in their git checkout.
  local opt = vim.fn.stdpath 'data' .. '/site/pack/core/opt/'
  if vim.fn.isdirectory(opt .. 'blink.cmp') == 1
    and vim.fn.filereadable(opt .. 'blink.cmp/target/release/libblink_cmp_fuzzy.so') ~= 1 then
    problem 'blink.cmp fuzzy library missing (target/release/libblink_cmp_fuzzy.so)'
  end
end

-- markdown-preview's server binary is downloaded by install_nvim_extras.sh,
-- which runs after this script, so only the extras layer's own verification
-- can hold it against the build.
if mode == 'all' then
  local opt_all = vim.fn.stdpath 'data' .. '/site/pack/core/opt/'
  if vim.fn.isdirectory(opt_all .. 'markdown-preview.nvim') == 1
    and vim.fn.executable(opt_all .. 'markdown-preview.nvim/app/bin/markdown-preview-linux') ~= 1 then
    problem 'markdown-preview server binary missing (app/bin/markdown-preview-linux)'
  end

  -- kulala-core, the executable that actually performs .http requests. This
  -- check is the whole reason the 2026-09-12 build shipped without it and said
  -- nothing: the download was a warning inside a headless callback, and no
  -- later step asked whether it had worked. You found out at your first
  -- interactive nvim, as "Backend not found. Downloading 0.37.0...".
  --
  -- install_nvim_extras.sh puts it on /opt and points kulala's kulala_core.path
  -- there, so /opt is where this looks; a per-user copy under stdpath('data')
  -- counts too, for a machine provisioned before that move.
  if vim.fn.isdirectory(opt_all .. 'kulala.nvim') == 1
    and vim.fn.executable '/opt/kulala/bin/kulala-core' ~= 1
    and vim.fn.executable(vim.fn.stdpath 'data' .. '/kulala.nvim/bin/kulala-core') ~= 1 then
    problem 'kulala-core missing (/opt/kulala/bin/kulala-core) — .http requests cannot run'
  end

  -- Its treesitter grammar is the other half, and the other message you would
  -- otherwise meet interactively ("Setting up tree-sitter ..."). Only checked
  -- when the tree-sitter CLI exists, because without the CLI the config
  -- deliberately turns kulala's own parser handling off rather than letting it
  -- throw from a scheduled callback.
  if vim.fn.isdirectory(opt_all .. 'kulala.nvim') == 1 and vim.fn.executable 'tree-sitter' == 1 then
    local grammar = vim.api.nvim_get_runtime_file('parser/kulala_http.so', false)
    if #grammar == 0 then
      problem 'kulala_http treesitter grammar missing — .http files will not parse'
    end
  end
end

print(('verify (%s): %d plugins, %d parsers, %d problem(s)'):format(mode, #plugins, parsers_installed, #problems))
for _, p in ipairs(problems) do print('  PROBLEM ' .. p) end
if #problems > 0 then vim.cmd 'cquit 1' else vim.cmd 'qa' end
LUAEOF
    # nvim-preinstall.lua -- install every plugin the config DECLARES without
    # running the config. Insurance against the way the 2026-09-12 VirtualBox
    # build failed: kickstart's own pattern is
    #
    #     vim.pack.add { gh 'NMAC427/guess-indent.nvim' }
    #     require('guess-indent').setup {}
    #
    # and when that require fails, init.lua aborts THERE -- so every plugin
    # declared after it is never even asked for. That first boot logged 132
    # "Installing plugins" lines and left ZERO plugins on disk, with no error
    # naming a cause, and three retries each got no further than the same line.
    # Run with --clean, so no user config is loaded and nothing can abort the
    # pass; installation still goes to stdpath('data'), which --clean does not
    # move. Whatever this leaves on disk, the normal startups below then find.
    cat >"${B2B_LIB_DIR}/nvim-preinstall.lua" <<'LUAEOF'
-- nvim-preinstall.lua — written by setup/install/nvim/install_nvim.sh.
-- Installs every plugin the config declares, without loading the config:
--   nvim --clean --headless -c 'luafile /usr/local/lib/b2b/nvim-preinstall.lua' -c qa
if vim.pack == nil then
  print 'preinstall: vim.pack is missing — Neovim 0.12+ is required'
  vim.cmd 'cquit 1'
end

-- Only declarations are read, never comments: the configs are full of
-- documentation links, and https://docs.docker.com/... is not a plugin.
local hosts = { ['github.com'] = true, ['codeberg.org'] = true, ['gitlab.com'] = true }
local cfg = vim.fn.stdpath 'config'
local seen, specs = {}, {}
local function want(url)
  if not seen[url] then
    seen[url] = true
    specs[#specs + 1] = url
  end
end
for _, file in ipairs(vim.fn.globpath(cfg, '**/*.lua', false, true)) do
  for _, line in ipairs(vim.fn.readfile(file)) do
    if not line:match '^%s*%-%-' then
      -- `gh 'owner/repo'`: the helper both kickstart and the b2b layer use,
      -- and it is only ever used for a plugin.
      for repo in line:gmatch "gh%s*'([%w%.%_%-]+/[%w%.%_%-]+)'" do
        want('https://github.com/' .. repo)
      end
      -- A bare URL counts only with exactly owner/repo on a known git host.
      for host, owner, repo in line:gmatch "'https://([%w%.%-]+)/([%w%.%_%-]+)/([%w%.%_%-]+)'" do
        if hosts[host] and not repo:match '%.%a%a%a?%a?$' then
          want(('https://%s/%s/%s'):format(host, owner, repo))
        end
      end
    end
  end
end

if #specs == 0 then
  print 'preinstall: no plugin declarations found in the config'
  vim.cmd 'qa'
end

-- load = false: this pass only has to put the code on disk. Loading is what
-- the normal startups after it are for, and a plugin that fails to load must
-- not stop the rest from being installed.
local ok, err = pcall(vim.pack.add, specs, { confirm = false, load = false })
local root = vim.fn.stdpath 'data' .. '/site/pack/core/opt/'
local missing = {}
for _, url in ipairs(specs) do
  local name = url:gsub('%.git$', ''):match '[^/]+$'
  if vim.fn.isdirectory(root .. name) == 0 then missing[#missing + 1] = name end
end
print(('preinstall: %d declared, %d on disk, %d missing%s'):format(
  #specs, #specs - #missing, #missing, ok and '' or ' (vim.pack.add errored)'))
if not ok then print('  ' .. tostring(err):gsub('\n.*', '')) end
for _, name in ipairs(missing) do print('  MISSING ' .. name) end
-- Never fails the build on its own: the verification after the normal
-- startups is the verdict, and a plugin missing here may still arrive there.
vim.cmd 'qa'
LUAEOF

    chmod 644 "${B2B_LIB_DIR}/nvim-parsers.lua" "${B2B_LIB_DIR}/nvim-verify.lua" \
        "${B2B_LIB_DIR}/nvim-preinstall.lua"
    log "wrote ${B2B_LIB_DIR}/nvim-parsers.lua, nvim-verify.lua and nvim-preinstall.lua"
}

# blink.cmp (kickstart's completion engine) does its matching in a small Rust
# library, shipped as a prebuilt binary per release. Without it blink silently
# falls back to a slower Lua matcher and :checkhealth warns
#     blink_cmp_fuzzy lib is not downloaded/built
#
# blink can fetch this itself, but only asynchronously: its download returns a
# task driven by the event loop, and a headless Neovim exits before the task
# resolves -- verified, the callback never fires and no file appears. Rather
# than try to pump the loop from a script, the same two files are fetched here
# with curl, into the exact paths blink's own health check looks at
# (<plugin>/target/release/). Deterministic, and it fails loudly.
install_blink_fuzzy() {
    local user="$1" home plugin tag triple lib_dir base
    home=$(getent passwd "$user" | cut -d: -f6)
    plugin="${home}/.local/share/nvim/site/pack/core/opt/blink.cmp"
    [ -d "$plugin" ] || {
        log "${user}: blink.cmp not installed — skipping its fuzzy lib"
        return 0
    }

    lib_dir="${plugin}/target/release"
    if [ -f "${lib_dir}/libblink_cmp_fuzzy.so" ]; then
        log "${user}: blink.cmp fuzzy lib already present"
        return 0
    fi

    # The binary must match the checked-out tag, so read it from the checkout
    # rather than assuming the newest release.
    #
    # Read it AS THE OWNING USER. This function runs as root while the plugin
    # tree belongs to $user, and git >= 2.35 refuses to operate on a repository
    # owned by somebody else ("detected dubious ownership") -- it exits non-zero
    # and prints nothing, so as root every one of these commands came back empty
    # and the lib was silently skipped with "cannot determine the tag". Verified:
    # the identical command run as the user returns v1.10.2.
    local git_as="runuser -u ${user} --"
    [ "$user" = "root" ] && git_as=""
    tag=$($git_as git -C "$plugin" describe --tags --exact-match 2>/dev/null) ||
        tag=$($git_as git -C "$plugin" tag --points-at HEAD 2>/dev/null | head -n1)
    [ -n "$tag" ] || tag=$($git_as git -C "$plugin" describe --tags 2>/dev/null |
        sed 's/-[0-9]*-g[0-9a-f]*$//')
    if [ -z "$tag" ]; then
        warn "${user}: cannot determine the blink.cmp tag — skipping its fuzzy lib"
        return 0
    fi

    case "$(uname -m)" in
    x86_64 | amd64) triple="x86_64-unknown-linux-gnu" ;;
    aarch64 | arm64) triple="aarch64-unknown-linux-gnu" ;;
    *)
        log "${user}: no prebuilt blink.cmp lib for $(uname -m) — Lua fallback stays"
        return 0
        ;;
    esac

    log "${user}: fetching the blink.cmp fuzzy library (${tag}, ${triple})"
    base="https://github.com/saghen/blink.cmp/releases/download/${tag}"
    mkdir -p "$lib_dir"

    if ! curl -fsSL --retry 3 --max-time 180 \
        -o "${lib_dir}/libblink_cmp_fuzzy.so.tmp" "${base}/${triple}.so"; then
        warn "${user}: could not download the blink.cmp fuzzy lib — the Lua fallback still works"
        rm -f "${lib_dir}/libblink_cmp_fuzzy.so.tmp"
        return 0
    fi
    # blink writes the checksum beside the library and reads it back later, so
    # fetch it too; verify while we have both.
    if curl -fsSL --retry 3 --max-time 60 \
        -o "${lib_dir}/libblink_cmp_fuzzy.so.sha256" "${base}/${triple}.so.sha256"; then
        local want got
        want=$(awk '{print $1; exit}' "${lib_dir}/libblink_cmp_fuzzy.so.sha256")
        got=$(sha256sum "${lib_dir}/libblink_cmp_fuzzy.so.tmp" | awk '{print $1}')
        if [ -n "$want" ] && [ "$want" != "$got" ]; then
            warn "${user}: blink.cmp fuzzy lib checksum mismatch — discarding it"
            rm -f "${lib_dir}/libblink_cmp_fuzzy.so.tmp" "${lib_dir}/libblink_cmp_fuzzy.so.sha256"
            return 0
        fi
    fi
    mv "${lib_dir}/libblink_cmp_fuzzy.so.tmp" "${lib_dir}/libblink_cmp_fuzzy.so"
    printf '%s\n' "$tag" >"${lib_dir}/version"

    local group
    group=$(id -gn "$user" 2>/dev/null || echo "$user")
    chown -R "${user}:${group}" "${plugin}/target" 2>/dev/null || true
    log "${user}: blink.cmp fuzzy lib installed"
}

# The bootstrap proper. Sets BOOTSTRAP_FAILED=1 when the verification at the
# end finds anything missing; main turns that into exit 1.
BOOTSTRAP_FAILED=0
# Set by nvim_headless the moment a run reports ENOSPC; the retry loops read it
# so they stop instead of spending minutes re-cloning onto a full volume.
NVIM_ENOSPC=0
bootstrap_user() {
    local user="$1" home group attempt
    home=$(getent passwd "$user" | cut -d: -f6)
    group=$(id -gn "$user" 2>/dev/null || echo "$user")
    mkdir -p "${home}/.local/state/nvim"
    : >"${home}/.local/state/nvim/bootstrap.log"

    log "${user}: installing plugins (this takes a few minutes on a cold cache)"
    # The pass that cannot be aborted by the config (see nvim-preinstall.lua):
    # --clean, so init.lua is not loaded at all, and every declared plugin is
    # asked for in one batch. `|| true` because its own report is the point;
    # the verification below is what decides whether the build is good.
    if [ -r "${B2B_LIB_DIR}/nvim-preinstall.lua" ]; then
        run_as_user "$user" /usr/local/bin/nvim --clean --headless \
            -c "luafile ${B2B_LIB_DIR}/nvim-preinstall.lua" -c qa 2>&1 |
            tr '\r' '\n' | grep -E '^preinstall:|^  MISSING|^  ' |
            sed 's/^/[nvim]     /' || true
    fi
    # vim.pack.add() fetches synchronously at startup, so starting and quitting
    # IS the install. Twice per attempt: the PackChanged autocommands that build
    # telescope-fzf-native and run TSUpdate only fire once the plugin is on
    # disk. Up to three attempts, ten seconds apart: vim.pack reports a failed
    # clone as a notification, not an error, so nothing but counting the
    # directories afterwards notices -- and on a NAT'd VM in its first minute
    # of network a failed clone is the ordinary case, not the rare one.
    if ! check_home_space "$user"; then
        BOOTSTRAP_FAILED=1
        return 1
    fi

    for attempt in 1 2 3; do
        nvim_headless "$user" +'lua vim.cmd("sleep 200m")' +qa ||
            warn "${user}: headless start returned non-zero (attempt ${attempt})"
        nvim_headless "$user" +'lua vim.cmd("sleep 200m")' +qa >/dev/null || true
        if nvim_headless "$user" -c 'lua vim.g.b2b_verify_mode = "plugins"' \
            -c "luafile ${B2B_LIB_DIR}/nvim-verify.lua" >/dev/null; then
            break
        fi
        if [ "$NVIM_ENOSPC" = "1" ]; then
            warn "${user}: stopping after attempt ${attempt} — the volume is full, retrying cannot help"
            check_home_space "$user" || true
            BOOTSTRAP_FAILED=1
            return 1
        fi
        if [ "$attempt" -lt 3 ]; then
            warn "${user}: plugins still missing after attempt ${attempt} — retrying in 10 s"
            sleep 10
        fi
    done

    install_blink_fuzzy "$user"

    log "${user}: installing Mason language servers + formatters"
    # Nothing else triggers this: the plain headless starts above load
    # mason-tool-installer but its install runs asynchronously and the process
    # exits first, so without the explicit *Sync* command you end up with LSP
    # wired up and no language server behind it.
    nvim_headless "$user" +'silent! MasonToolsUpdateSync' +qa >/dev/null ||
        warn "${user}: MasonToolsUpdateSync returned non-zero"

    log "${user}: installing treesitter parsers"
    nvim_headless "$user" -c "luafile ${B2B_LIB_DIR}/nvim-parsers.lua" -c qa ||
        warn "${user}: the parser step returned non-zero"

    chown -R "${user}:${group}" "${home}/.local" "${home}/.cache" 2>/dev/null || true

    log "${user}: verifying plugins, parsers, language servers"
    # 'base', not the default 'all': see the mode note in nvim-verify.lua --
    # the extras layer's downloaded binaries are not this script's to produce.
    if nvim_headless "$user" -c 'lua vim.g.b2b_verify_mode = "base"' \
        -c "luafile ${B2B_LIB_DIR}/nvim-verify.lua"; then
        log "${user}: everything the config declares is installed"
    else
        warn "${user}: the bootstrap left things missing (see above, and ~/.local/state/nvim/bootstrap.log)"
        BOOTSTRAP_FAILED=1
    fi
}

health_report() {
    local user="$1" home out
    home=$(getent passwd "$user" | cut -d: -f6)
    out="${home}/.local/state/nvim/checkhealth.log"

    run_as_user "$user" /usr/local/bin/nvim --headless \
        +'checkhealth' +"w! ${out}" +qa >/dev/null 2>&1 || true

    if [ -s "$out" ]; then
        local group
        group=$(id -gn "$user" 2>/dev/null || echo "$user")
        chown "${user}:${group}" "$out" 2>/dev/null || true
        log "${user}: checkhealth written to ${out}"
        # A compact summary: how many ERROR/WARNING lines, and what they were.
        # Neovim writes these as "- ❌ ERROR ..." / "- ⚠️ WARNING ...", with the
        # emoji between the bullet and the word, so an anchored '^- ERROR'
        # matches nothing and every report looks perfectly clean.
        local errs warns
        errs=$(grep -cE '^- .*\bERROR\b' "$out" 2>/dev/null || true)
        errs=${errs:-0}
        warns=$(grep -cE '^- .*\bWARNING\b' "$out" 2>/dev/null || true)
        warns=${warns:-0}
        log "${user}: checkhealth summary — ${errs} error(s), ${warns} warning(s)"
        if [ "$errs" -gt 0 ]; then
            grep -E '^- .*\bERROR\b' "$out" | sed 's/^/[nvim]   /' | head -n 20
        fi
    else
        warn "${user}: checkhealth produced no output"
    fi
}

# ── Purge (NVIM_PURGE=1) ────────────────────────────────────────────────────
# Deliberately explicit about every path rather than globbing: this runs as
# root, and a stray glob here would delete somebody's home directory.
purge() {
    log "NVIM_PURGE=1 — removing every trace of a previous install"
    local user home
    for user in $NVIM_USERS; do
        home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
        if [ -z "$home" ] || [ ! -d "$home" ]; then
            continue
        fi
        log "  ${user}: config, plugins, parsers, state, cache"
        rm -rf "${home}/.config/nvim" \
            "${home}/.local/share/nvim" \
            "${home}/.local/state/nvim" \
            "${home}/.cache/nvim"
    done
    # The /opt trees and the symlinks into them.
    rm -rf "${NVIM_OPT_DIR}"/nvim-v* "${NVIM_OPT_DIR}/nvim" "$NVIM_PYTHON_VENV"
    rm -f /usr/local/bin/nvim /etc/profile.d/nvim.sh /etc/profile.d/nvim-extras.sh
    rm -f "${B2B_LIB_DIR}/nvim-parsers.lua" "${B2B_LIB_DIR}/nvim-verify.lua" \
        "${B2B_LIB_DIR}/nvim-preinstall.lua"
    local alt
    for alt in editor vi vim; do
        update-alternatives --remove "$alt" /usr/local/bin/nvim >/dev/null 2>&1 || true
    done
    log "purge complete — installing from scratch"
}

# ── Retract a failed first boot's verdict ───────────────────────────────────
# first-boot-setup.sh's feature_fail() appends "<feature> <why>" to
# /etc/b2b/PROVISION_FAILED, the file the pipelines read to fail `make all`,
# and nothing ever removed it again. So one bad first boot marked the guest
# failed permanently: `make nvim` could fix the actual problem and every later
# `make all` would still stop on the stale line. Clearing it is only honest
# when THIS feature really did just succeed, so it runs on the success path
# and drops only its own lines -- another feature's failure still stands.
clear_provision_failed() {
    local feature="$1" marker=/etc/b2b/PROVISION_FAILED tmp
    [ -f "$marker" ] || return 0
    grep -q "^${feature} " "$marker" 2>/dev/null || return 0
    tmp="${marker}.$$"
    if grep -v "^${feature} " "$marker" >"$tmp" 2>/dev/null; then
        if [ -s "$tmp" ]; then
            cat "$tmp" >"$marker" && rm -f "$tmp"
            log "cleared the '${feature}' line from ${marker} (other features still listed)"
        else
            rm -f "$tmp" "$marker"
            log "removed ${marker} — nothing is failing any more"
        fi
    else
        rm -f "$tmp"
    fi
}

# ── main ────────────────────────────────────────────────────────────────────
log "=== Neovim + kickstart.nvim install starting ==="
[ "$NVIM_PURGE" = "1" ] && purge
install_deps
install_neovim
install_providers
write_lua_helpers

configured=""
for u in $NVIM_USERS; do
    if setup_user_config "$u"; then
        configured="${configured} ${u}"
    fi
done

if [ -z "${configured// /}" ]; then
    die "no user configs were set up — nothing to bootstrap"
fi

if [ "$NVIM_BOOTSTRAP" = "1" ]; then
    for u in $configured; do
        bootstrap_user "$u"
        health_report "$u"
    done
else
    log "NVIM_BOOTSTRAP=0 — skipping plugin install and health report"
fi

if [ "$BOOTSTRAP_FAILED" = "1" ]; then
    die "the plugin bootstrap is incomplete for:${configured} — the PROBLEM lines above say what is missing"
fi
clear_provision_failed nvim
log "=== done: $(/usr/local/bin/nvim --version | head -n1) for:${configured} ==="
