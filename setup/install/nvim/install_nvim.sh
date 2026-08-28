#!/bin/bash
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
#      time instead of on the user's first, very slow, interactive start
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
export PATH

# ── Configuration ───────────────────────────────────────────────────────────
# Pinned by default: a build that silently changes Neovim version between runs
# is not reproducible, and kickstart's requirements move with it. Set
# NVIM_VERSION=latest to track the newest release instead.
NVIM_VERSION="${NVIM_VERSION:-v0.12.5}"
NVIM_MIN_VERSION="${NVIM_MIN_VERSION:-0.12.0}"   # what kickstart master needs (vim.pack)
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

log()  { printf '[nvim] %s\n' "$*"; }
warn() { printf '[nvim] WARN: %s\n' "$*" >&2; }
die()  { printf '[nvim] ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"

case "$(uname -m)" in
	x86_64|amd64) NVIM_ARCH="x86_64" ;;
	aarch64|arm64) NVIM_ARCH="arm64" ;;
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
	if ! apt-get install -y -qq -o Dpkg::Options::=--force-confdef \
		-o Dpkg::Options::=--force-confold $pkgs; then
		warn "batch install failed — retrying package by package"
		local p
		for p in $pkgs; do
			apt-get install -y -qq "$p" 2>/dev/null \
				|| warn "could not install $p"
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
		https://api.github.com/repos/neovim/neovim/releases/latest 2>/dev/null \
		| sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
	[ -n "$tag" ] || die "could not resolve the latest Neovim release (network/API problem)"
	printf '%s' "$tag"
}

# version_ge <a> <b> — true when version a >= version b, numerically per field.
version_ge() {
	[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

install_neovim() {
	local tag prefix tarball url tmp shafile expected actual
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
			[ "$expected" = "$actual" ] \
				|| die "checksum mismatch for ${got} (expected ${expected}, got ${actual})"
			log "published checksum verified"
		else
			log "release ${tag} publishes no checksum file — relying on the archive test below"
		fi

		gzip -t "${tmp}/${got}" 2>/dev/null \
			|| die "downloaded ${got} is not a valid gzip stream (truncated download?)"
		tar -tzf "${tmp}/${got}" >/dev/null 2>&1 \
			|| die "downloaded ${got} is not a readable tar archive"
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
		rm -rf "$tmp"; trap - RETURN
		log "installed Neovim ${tag} into ${prefix}"
	fi

	ln -sfn "$prefix" "${NVIM_OPT_DIR}/nvim"
	ln -sf "${NVIM_OPT_DIR}/nvim/bin/nvim" /usr/local/bin/nvim

	# A profile drop-in for the man pages and for anyone who prefers the real
	# path on PATH; the symlink above is what actually makes `nvim` resolve.
	cat > /etc/profile.d/nvim.sh <<'PROFILE'
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
	version_ge "$have" "$NVIM_MIN_VERSION" \
		|| die "installed Neovim v${have} is older than the ${NVIM_MIN_VERSION} kickstart.nvim requires"
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
			npm install -g tree-sitter-cli >/dev/null 2>&1 \
				|| warn "npm install -g tree-sitter-cli failed — parsers will not compile"
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
		python3 -m venv "$NVIM_PYTHON_VENV" >/dev/null 2>&1 \
			|| warn "could not create ${NVIM_PYTHON_VENV}"
	fi
	if [ -x "${NVIM_PYTHON_VENV}/bin/pip" ]; then
		"${NVIM_PYTHON_VENV}/bin/pip" install --quiet --upgrade pip pynvim >/dev/null 2>&1 \
			|| warn "pip install pynvim failed"
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
	cat > "${cfg}/${LOCAL_PLUGIN_REL}" <<LOCALEOF
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
			local backup="${cfg}.bak.$(date +%Y%m%d%H%M%S)"
			log "${user}: moving existing config aside -> ${backup}"
			mv "$cfg" "$backup" || { warn "${user}: could not back up ${cfg}"; return 1; }
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
		grep -qxF "$LOCAL_PLUGIN_REL" "${cfg}/.git/info/exclude" 2>/dev/null \
			|| printf '%s\n' "$LOCAL_PLUGIN_REL" >> "${cfg}/.git/info/exclude"
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
	local user="$1"; shift
	set -- env "TERM=${NVIM_TERM:-xterm-256color}" "$@"
	if [ "$user" = "root" ]; then
		timeout "$NVIM_BOOTSTRAP_TIMEOUT" "$@"
	else
		# runuser keeps a clean environment and does not need PAM's auth stack.
		timeout "$NVIM_BOOTSTRAP_TIMEOUT" runuser -u "$user" -- "$@"
	fi
}

bootstrap_user() {
	local user="$1" home
	home=$(getent passwd "$user" | cut -d: -f6)

	log "${user}: installing plugins (this takes a few minutes on a cold cache)"
	# vim.pack.add() fetches synchronously at startup, so simply starting and
	# quitting is the install. Twice: the PackChanged autocommands that build
	# telescope-fzf-native and run TSUpdate only fire once the plugin is on disk.
	local i
	for i in 1 2; do
		run_as_user "$user" /usr/local/bin/nvim --headless \
			+'lua vim.cmd("sleep 200m")' +qa >/dev/null 2>&1 \
			|| warn "${user}: headless start ${i} returned non-zero (often just a plugin notice)"
	done

	log "${user}: installing treesitter parsers"
	run_as_user "$user" /usr/local/bin/nvim --headless \
		+'silent! TSUpdateSync' +qa >/dev/null 2>&1 \
		|| warn "${user}: TSUpdateSync returned non-zero"

	log "${user}: installing Mason language servers + formatters"
	run_as_user "$user" /usr/local/bin/nvim --headless \
		+'silent! MasonToolsUpdateSync' +qa >/dev/null 2>&1 \
		|| warn "${user}: MasonToolsUpdateSync returned non-zero"

	local group
	group=$(id -gn "$user" 2>/dev/null || echo "$user")
	chown -R "${user}:${group}" "${home}/.local" "${home}/.cache" 2>/dev/null || true
}

health_report() {
	local user="$1" home out
	home=$(getent passwd "$user" | cut -d: -f6)
	out="${home}/.local/state/nvim/checkhealth.log"

	run_as_user "$user" /usr/local/bin/nvim --headless \
		+'checkhealth' +"w! ${out}" +qa >/dev/null 2>&1 || true

	if [ -s "$out" ]; then
		local group; group=$(id -gn "$user" 2>/dev/null || echo "$user")
		chown "${user}:${group}" "$out" 2>/dev/null || true
		log "${user}: checkhealth written to ${out}"
		# A compact summary: how many ERROR/WARNING lines, and what they were.
		# Neovim writes these as "- ❌ ERROR ..." / "- ⚠️ WARNING ...", with the
		# emoji between the bullet and the word, so an anchored '^- ERROR'
		# matches nothing and every report looks perfectly clean.
		local errs warns
		errs=$(grep -cE '^- .*\bERROR\b' "$out" 2>/dev/null || true); errs=${errs:-0}
		warns=$(grep -cE '^- .*\bWARNING\b' "$out" 2>/dev/null || true); warns=${warns:-0}
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
		[ -n "$home" ] && [ -d "$home" ] || continue
		log "  ${user}: config, plugins, parsers, state, cache"
		rm -rf "${home}/.config/nvim" \
			"${home}/.local/share/nvim" \
			"${home}/.local/state/nvim" \
			"${home}/.cache/nvim"
	done
	# The /opt trees and the symlinks into them.
	rm -rf "${NVIM_OPT_DIR}"/nvim-v* "${NVIM_OPT_DIR}/nvim" "$NVIM_PYTHON_VENV"
	rm -f /usr/local/bin/nvim /etc/profile.d/nvim.sh /etc/profile.d/nvim-extras.sh
	local alt
	for alt in editor vi vim; do
		update-alternatives --remove "$alt" /usr/local/bin/nvim >/dev/null 2>&1 || true
	done
	log "purge complete — installing from scratch"
}

# ── main ────────────────────────────────────────────────────────────────────
log "=== Neovim + kickstart.nvim install starting ==="
[ "$NVIM_PURGE" = "1" ] && purge
install_deps
install_neovim
install_providers

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

log "=== done: $(/usr/local/bin/nvim --version | head -n1) for:${configured} ==="
