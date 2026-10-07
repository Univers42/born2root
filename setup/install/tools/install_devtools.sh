#!/usr/bin/env hellish
#
# install_devtools.sh — Herdr and opencode.
#
# HERDR (https://herdr.dev, github.com/herdrdev/herdr)
#   A single ~10 MB Rust binary that splits into a persistent background server
#   and a TUI client: panes, splits and workspaces that keep running when the
#   client detaches. That is the same shape as the tmux workflow this VM
#   already uses -- SSH in, attach, close the laptop, reattach -- with a
#   sidebar that tracks what each pane is doing.
#
#   It is also the answer to "tiling" here. A tiling WINDOW manager (Krohnkite
#   and friends) needs KWin, so X.org or Wayland, and the Born2beRoot subject
#   is explicit that installing a graphics server scores 0. Herdr gives the
#   tiled-pane workflow entirely inside the terminal, with nothing to install
#   that could put the grade at risk.
#
#   Upstream offers `curl -fsSL https://herdr.dev/install.sh | sh`. This script
#   does NOT use it: piping a remote script into a shell inside an unattended
#   first-boot is unreviewable and unpinnable. It fetches the release asset
#   directly instead, the same way setup/fetch_hellish.sh fetches hellish --
#   which is also how the version ends up pinnable and cacheable.
#
# OPENCODE (https://opencode.ai, github.com/anomalyco/opencode)
#   The AI coding agent in this VM, in place of Claude Code since 2026-09-12:
#   one static binary that works with any provider -- Anthropic, OpenAI,
#   GitHub Copilot, or the local Ollama that install_ai.sh sets up and wires
#   in -- where `npm i -g @anthropic-ai/claude-code` was tied to one vendor
#   and weighed 414 MB on / (measured: /usr/local/lib/node_modules/@anthropic-ai
#   on the 2026-09-12 build; the npm prefix never actually moved to /opt).
#
#   Fetched as the release tarball, like Herdr, and for the same reasons plus
#   one: upstream's `curl https://opencode.ai/install | bash` installs into
#   ~/.opencode/bin, per user, on the /home volume this layout sizes for
#   Neovim's plugins. The tarball holds exactly one file, 176 MB unpacked
#   (v1.18.30), so it goes beside herdr in /usr/local/bin, and the manifest
#   in generate/feature_profile.sh carries it under devtools-extra on /.
#
#   First use: `opencode auth login` (or `opencode` then /connect) stores a
#   provider key under ~/.local/share/opencode; with AI_MODE=local nothing is
#   needed, install_ai.sh points it at the model on this box.
#
# PLAYWRIGHT (playwright + @playwright/mcp)
#   The browser the AI agents in this VM use. An agent that cannot see a page
#   cannot check its own work, and this VM has no display: the Born2beRoot
#   subject scores 0 for a graphics server, so the browser has to be headless
#   and the screenshot has to be taken from inside the guest.
#
#   Two things are installed, and the second is the one an agent talks to:
#   `playwright` is the library plus its CLI, and `@playwright/mcp` is the MCP
#   server -- the process opencode and Claude Code launch, which hands the
#   model 25 browser tools (browser_navigate, browser_click, browser_snapshot,
#   browser_take_screenshot ...).
#
#   Browsers live in /usr/lib/ms-playwright, not ~/.cache/ms-playwright: 658 MB
#   measured, and one copy for every account beats one per user (npm globals,
#   kulala-core and the Ollama models are machine-wide for the same reason).
#   Not on /opt either: that is a 569 MB volume at the school quota, and the
#   browsers would not fit next to what is already claimed there.
#
#   Two MCP servers are registered per agent, on purpose:
#     playwright        its own headless browser. No tunnel, no host browser,
#                       nothing to keep alive -- the default for an agent.
#     playwright-host   the HOST's Chrome over CDP. The build writes
#                       `RemoteForward 9222 localhost:9222` into the b2b block
#                       of ~/.ssh/config (setup/host/qemu_vm.sh), so the
#                       guest's localhost:9222 is the host's Chrome with the
#                       host's profile and logins. It is the one to reach for
#                       when a page needs a real signed-in session.
#   Absolute paths, and PLAYWRIGHT_BROWSERS_PATH passed in the server's own
#   environment: the npm prefix is /opt/npm-global, which is on the PATH of a
#   login shell and of nothing else, and an MCP server's process is not a login
#   shell. Without the variable a spawned browser looks in ~/.cache and says
#   "browser not installed" while 658 MB of browser sits in /opt.
#
# USAGE
#   sudo ./install_devtools.sh
#   sudo HERDR_VERSION=v0.8.2 ./install_devtools.sh       # pin instead of latest
#   sudo OPENCODE_VERSION=v1.18.30 ./install_devtools.sh  # same for opencode
#   sudo PLAYWRIGHT_VERSION=1.63.0 ./install_devtools.sh # pin playwright
#   sudo INSTALL_HERDR=0 ./install_devtools.sh             # skip one of them
#   sudo INSTALL_OPENCODE=0 ./install_devtools.sh
#   sudo INSTALL_PLAYWRIGHT=0 ./install_devtools.sh
#   sudo PLAYWRIGHT_BROWSERS="chromium firefox" ./install_devtools.sh
#
# Exits non-zero when a tool it was asked to install is not on PATH at the
# end, so first boot records devtools-extra as failed instead of a [WARN]
# scrolling past in a log nobody reads.

set -u

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

HERDR_REPO="${HERDR_REPO:-herdrdev/herdr}"
HERDR_VERSION="${HERDR_VERSION:-}" # empty = resolve the latest release
HERDR_DEST="${HERDR_DEST:-/usr/local/bin/herdr}"
INSTALL_HERDR="${INSTALL_HERDR:-1}"
OPENCODE_REPO="${OPENCODE_REPO:-anomalyco/opencode}"
OPENCODE_VERSION="${OPENCODE_VERSION:-}" # empty = latest release, e.g. v1.18.30
OPENCODE_DEST="${OPENCODE_DEST:-/usr/local/bin/opencode}"
INSTALL_OPENCODE="${INSTALL_OPENCODE:-1}"
INSTALL_PLAYWRIGHT="${INSTALL_PLAYWRIGHT:-}"
# Both pins are npm versions, not tags: PLAYWRIGHT_VERSION=1.63.0 is what
# `playwright --version` prints, and an empty one means whatever the registry
# has (which is how a rebuild picks up a fix without an edit here).
PLAYWRIGHT_VERSION="${PLAYWRIGHT_VERSION:-}"
PLAYWRIGHT_MCP_VERSION="${PLAYWRIGHT_MCP_VERSION:-}"
# Browsers on / (not /opt, and not ~/.cache). Two reasons, both measured:
# ~/.cache would put 658 MB in a per-user home, and /opt is a 569 MB volume at
# the school quota -- 423 MB usable, with the standard set already asking
# 1095 MB of it -- so browsers there push the smallest build this project can
# offer from SIZE_B2B=15 to 33, which is not a trade anyone asked for. / is
# where nvim, Docker and Claude Code already are. Override only for a test.
PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/usr/lib/ms-playwright}"
# chromium is the one an agent needs; firefox and webkit are ~450 MB more each,
# so they are named here rather than downloaded unasked.
PLAYWRIGHT_BROWSERS="${PLAYWRIGHT_BROWSERS:-chromium}"
# The host's Chrome, reached through the RemoteForward the build writes.
PLAYWRIGHT_CDP_ENDPOINT="${PLAYWRIGHT_CDP_ENDPOINT:-http://127.0.0.1:9222}"
# 15 s, not upstream's 30: with the reverse tunnel down (it lives and dies with
# the ssh session, and at build time there is no session at all) a tool call
# that waits 30 s for a browser that will never answer is the agent staring at
# a spinner. Overridable for a slow host.
PLAYWRIGHT_CDP_TIMEOUT="${PLAYWRIGHT_CDP_TIMEOUT:-15000}"
# The bounded handshake verify_playwright_mcp runs. Written next to the other
# generated helpers rather than inlined into a `node -e`.
PLAYWRIGHT_VERIFY_JS="${PLAYWRIGHT_VERIFY_JS:-/usr/local/lib/b2b/playwright-mcp-check.js}"
# Where the three exported lines go. A knob only so the host test can run the
# real function without being root (tests/test_devtools_playwright.sh); a guest
# always gets /etc/profile.d.
PLAYWRIGHT_PROFILE_D="${PLAYWRIGHT_PROFILE_D:-/etc/profile.d}"
# The login born2root.toml named, as the guest records it (/etc/b2b/build.conf,
# written by utils/b2b_config.sh --guest). Unset DEVTOOLS_USERS defaults to it.
B2B_BUILD_CONF="${B2B_BUILD_CONF:-/etc/b2b/build.conf}"
DEVTOOLS_USERS="${DEVTOOLS_USERS:-$(sed -n 's/^B2B_LOGIN=//p' "$B2B_BUILD_CONF" 2>/dev/null | head -n1)}"
if [ -z "${DEVTOOLS_USERS}" ]; then
    printf '[devtools] ERROR: DEVTOOLS_USERS is empty and %s names no B2B_LOGIN\n' "$B2B_BUILD_CONF" >&2
    exit 1
fi

log() { printf '[devtools] %s\n' "$*"; }
warn() { printf '[devtools] WARN: %s\n' "$*" >&2; }
die() {
    printf '[devtools] ERROR: %s\n' "$*" >&2
    exit 1
}

# ── Is this build's `playwright` feature on? ───────────────────────────────
# Empty by default, like NVIM_NERD_FONT above, so the answer is the one
# features.conf recorded -- the file create_custom_iso.sh ships from the same
# MANIFEST row the size check reads. A guest with no features.conf (built
# before the row existed, or a hand-run of this script) gets Playwright: it is
# 700 MB, so an operator who ran this by hand almost certainly wants it, and
# `INSTALL_PLAYWRIGHT=0` is right there. What must NOT happen is the reverse --
# a build that said no quietly growing by three quarters of a gigabyte.
B2B_FEATURES_CONF="${B2B_FEATURES_CONF:-/etc/b2b/features.conf}"
feature_on() {
    if [ ! -f "$B2B_FEATURES_CONF" ]; then
        return 0
    fi
    grep -qx "B2B_FEATURE_$(printf '%s' "$1" | tr '-' '_')=on" "$B2B_FEATURES_CONF" 2>/dev/null
}
if [ -z "$INSTALL_PLAYWRIGHT" ]; then
    if feature_on playwright; then
        INSTALL_PLAYWRIGHT=1
    else
        INSTALL_PLAYWRIGHT=0
    fi
fi

[ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"

case "$(uname -m)" in
x86_64 | amd64) ARCH="x86_64" ;;
aarch64 | arm64) ARCH="aarch64" ;;
*)
    warn "unsupported architecture $(uname -m) — skipping Herdr"
    INSTALL_HERDR=0
    ARCH=""
    ;;
esac

# ── Herdr ───────────────────────────────────────────────────────────────────
install_herdr() {
    local tag asset url tmp

    if [ -n "$HERDR_VERSION" ]; then
        tag="$HERDR_VERSION"
    else
        tag=$(curl -fsSL --max-time 30 --retry 2 \
            -H 'Accept: application/vnd.github+json' \
            "https://api.github.com/repos/${HERDR_REPO}/releases/latest" 2>/dev/null |
            sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
    fi
    if [ -z "$tag" ]; then
        warn "could not resolve a Herdr release (offline? rate-limited?) — skipping"
        return 0
    fi

    # Already at this version? Nothing to do — keeps first boot and a later
    # re-run from re-downloading the same binary.
    if [ -x "$HERDR_DEST" ]; then
        local have
        have=$("$HERDR_DEST" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
        if [ -n "$have" ] && [ "v${have}" = "$tag" ]; then
            log "herdr ${tag} already installed"
            return 0
        fi
    fi

    asset="herdr-linux-${ARCH}"
    url="https://github.com/${HERDR_REPO}/releases/download/${tag}/${asset}"
    tmp=$(mktemp -d) || die "mktemp failed"

    log "downloading herdr ${tag} (${asset})"
    if ! curl -fL --retry 3 --retry-delay 2 --max-time 300 -o "${tmp}/herdr" "$url" 2>/dev/null; then
        warn "download failed: ${url} — skipping Herdr"
        rm -rf "$tmp"
        return 0
    fi

    # Upstream does not publish a .sha256 beside the binary today. Verify it if
    # one appears; otherwise at least prove the file is a Linux executable and
    # not an HTML error page saved under the right name, which is what a
    # redirected or rate-limited download actually gives you.
    if curl -fsSL --max-time 60 -o "${tmp}/herdr.sha256" "${url}.sha256" 2>/dev/null; then
        local want got
        want=$(awk '{print $1; exit}' "${tmp}/herdr.sha256")
        got=$(sha256sum "${tmp}/herdr" | awk '{print $1}')
        if [ -n "$want" ] && [ "$want" != "$got" ]; then
            warn "herdr checksum mismatch — discarding"
            rm -rf "$tmp"
            return 0
        fi
        log "checksum verified"
    else
        if ! head -c4 "${tmp}/herdr" | grep -q $'\x7fELF'; then
            warn "downloaded herdr is not an ELF binary — discarding"
            rm -rf "$tmp"
            return 0
        fi
        log "no published checksum; verified the file is an ELF binary"
    fi

    install -m 755 "${tmp}/herdr" "$HERDR_DEST" || {
        warn "install failed"
        rm -rf "$tmp"
        return 0
    }
    rm -rf "$tmp"

    if "$HERDR_DEST" --version >/dev/null 2>&1; then
        log "herdr installed: $("$HERDR_DEST" --version 2>/dev/null | head -n1)"
    else
        warn "herdr installed but does not run (missing shared library?)"
        "$HERDR_DEST" --version 2>&1 | sed 's/^/[devtools]   /' | head -3
    fi
}

# ── opencode's baseline configuration ───────────────────────────────────────
# Installing the binary is not the same as making it usable. Out of the box
# opencode writes itself a config holding nothing but a $schema line and then
# has no provider at all, so it cannot talk to any model -- and install_ai.sh,
# which DOES write a real provider, only runs when the ai-client or ai-local
# feature is on. With the default AI_MODE=off (as on the 2026-09-12 build)
# nobody ever configured it, and `opencode` was a 100 MB binary that could not
# answer a question.
#
# So point it at the host by default. In both backends the guest reaches the
# host at the NAT gateway 10.0.2.2, and Ollama speaks the OpenAI API on /v1,
# which is exactly what opencode's openai-compatible provider wants
# (opencode.ai/docs/providers). Nothing is downloaded and no model is assumed
# to exist: this is the one step away from working, and the MOTD hint names
# it. `make llm_host` on the host (setup/host/llm_host.sh) serves models with
# llama.cpp and replaces this file with its own provider. A loopback bind is
# enough for either server: both backends' NAT hands the guest's 10.0.2.2 to
# the host's 127.0.0.1, and 0.0.0.0 would put the server on the campus LAN.
#
# install_ai.sh overwrites this with the real endpoint and the real model list
# when AI_MODE is set, and both recognise the same marker, so a file the user
# has edited themselves is left alone by both.
OPENCODE_MARKER='born2root baseline'
OPENCODE_HOST_ENDPOINT="${OPENCODE_HOST_ENDPOINT:-10.0.2.2:11434}"
OPENCODE_DEFAULT_MODEL="${OPENCODE_DEFAULT_MODEL:-qwen3:4b}"

# Ours, opencode's own stub, or something the user wrote? Only the first two
# may be replaced. install_ai.sh's marker counts as ours as well: that is the
# better config, and this one must never downgrade it.
opencode_cfg_is_ours() {
    [ -f "$1" ] || return 0
    grep -q "$OPENCODE_MARKER" "$1" 2>/dev/null && return 0
    grep -q 'Ollama (local, born2root)' "$1" 2>/dev/null && return 0
    return 1
}

configure_opencode_baseline() {
    local user home group dir cfg
    [ -x "$OPENCODE_DEST" ] || return 0
    for user in $DEVTOOLS_USERS; do
        home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
        if [ -z "$home" ] || [ ! -d "$home" ]; then
            continue
        fi
        dir="${home}/.config/opencode"
        cfg="${dir}/opencode.json"

        if ! opencode_cfg_is_ours "$cfg"; then
            log "${user}: ${cfg} is not ours — leaving it alone"
            continue
        fi
        if [ -f "$cfg" ] && grep -q 'Ollama (local, born2root)' "$cfg" 2>/dev/null; then
            log "${user}: install_ai.sh already configured opencode — leaving it"
            continue
        fi

        mkdir -p "$dir"
        cat >"$cfg" <<CFGEOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "ollama/${OPENCODE_DEFAULT_MODEL}",
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama (${OPENCODE_MARKER})",
      "options": { "baseURL": "http://${OPENCODE_HOST_ENDPOINT}/v1" },
      "models": { "${OPENCODE_DEFAULT_MODEL}": { "name": "${OPENCODE_DEFAULT_MODEL}" } }
    }
  }
}
CFGEOF
        # opencode reads opencode.jsonc as well as opencode.json. Its own stub
        # is the .jsonc one, and leaving both would make which config wins a
        # coin toss -- so a stub with no provider in it goes.
        if [ -f "${dir}/opencode.jsonc" ] && ! grep -q '"provider"' "${dir}/opencode.jsonc" 2>/dev/null; then
            rm -f "${dir}/opencode.jsonc"
            log "${user}: removed opencode's provider-less opencode.jsonc stub"
        fi
        group=$(id -gn "$user" 2>/dev/null || echo "$user")
        chown -R "${user}:${group}" "$dir" 2>/dev/null || true
        chmod 644 "$cfg"
        log "${user}: opencode -> ollama/${OPENCODE_DEFAULT_MODEL} at ${OPENCODE_HOST_ENDPOINT} (${cfg})"
    done
}

# ── opencode ────────────────────────────────────────────────────────────────
# No GitHub API call here, unlike Herdr above: the API allows 60 anonymous
# requests an hour per address, and a NAT'd VM shares its address with the
# whole campus. GitHub's /releases/latest/download/<asset> redirect resolves
# the newest release without it, and a HEAD on /releases/latest names the tag,
# so a re-run can tell it already has this version and skip a 60 MB download.
#
# Upstream ships a "-baseline" x86_64 build for CPUs without AVX2. A QEMU
# guest started with -cpu qemu64 is one, so the test is done here the same way
# upstream's installer does it, rather than assuming the host's CPU shows.
install_opencode() {
    local asset tag url tmp have

    case "$ARCH" in
    x86_64) asset="opencode-linux-x64" ;;
    aarch64) asset="opencode-linux-arm64" ;;
    *)
        warn "no opencode build for $(uname -m) — skipping"
        return 0
        ;;
    esac
    if [ "$ARCH" = "x86_64" ] && ! grep -q avx2 /proc/cpuinfo 2>/dev/null; then
        asset="${asset}-baseline"
    fi

    if [ -n "$OPENCODE_VERSION" ]; then
        tag="$OPENCODE_VERSION"
        url="https://github.com/${OPENCODE_REPO}/releases/download/${tag}/${asset}.tar.gz"
    else
        # The redirect target ends in /releases/tag/<tag>.
        tag=$(curl -fsSIL --max-time 30 "https://github.com/${OPENCODE_REPO}/releases/latest" 2>/dev/null |
            sed -n 's#^[Ll]ocation: .*/releases/tag/\([^[:space:]]*\).*#\1#p' | tail -n1)
        url="https://github.com/${OPENCODE_REPO}/releases/latest/download/${asset}.tar.gz"
    fi

    if [ -x "$OPENCODE_DEST" ]; then
        have=$("$OPENCODE_DEST" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
        if [ -n "$have" ] && [ -z "$tag" ]; then
            log "opencode ${have} already installed (could not ask GitHub what the latest is — keeping it)"
            return 0
        fi
        if [ -n "$have" ] && [ "v${have}" = "$tag" ]; then
            log "opencode ${have} already installed"
            return 0
        fi
    fi

    # /var/tmp, not /tmp: the tarball plus the unpacked binary is ~240 MB and
    # the /tmp volume this layout makes is 0.4 GB at SIZE_B2B=15.
    tmp=$(mktemp -d /var/tmp/opencode.XXXXXX) || die "mktemp failed"
    log "downloading opencode ${tag:-latest} (${asset})"
    if ! curl -fL --retry 3 --retry-delay 2 --max-time 600 -o "${tmp}/opencode.tar.gz" "$url" 2>/dev/null; then
        warn "download failed: ${url}"
        rm -rf "$tmp"
        return 1
    fi
    # Upstream publishes no checksum beside the tarball. What a truncated or
    # rate-limited download really looks like is a broken archive or an HTML
    # page, so the archive is tested end to end and the binary is RUN before
    # anything is installed.
    if ! gzip -t "${tmp}/opencode.tar.gz" 2>/dev/null || ! tar -tzf "${tmp}/opencode.tar.gz" >/dev/null 2>&1; then
        warn "the opencode download is not a valid tar.gz (truncated?)"
        rm -rf "$tmp"
        return 1
    fi
    if ! tar -xzf "${tmp}/opencode.tar.gz" -C "$tmp" opencode 2>/dev/null; then
        warn "the opencode tarball does not contain the expected 'opencode' file"
        rm -rf "$tmp"
        return 1
    fi
    chmod 755 "${tmp}/opencode"
    have=$("${tmp}/opencode" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    if [ -z "$have" ]; then
        warn "the downloaded opencode binary does not run here"
        rm -rf "$tmp"
        return 1
    fi
    if ! mv -f "${tmp}/opencode" "$OPENCODE_DEST"; then
        warn "could not install into ${OPENCODE_DEST}"
        rm -rf "$tmp"
        return 1
    fi
    rm -rf "$tmp"
    log "opencode ${have} installed at ${OPENCODE_DEST}"
}

# ── Make sessions actually persistent ───────────────────────────────────────
# Installing the binary is NOT enough for the workflow this exists for.
# Verified on the VM: launched the normal way (`herdr`), the server is a child
# of the client, so when the SSH connection drops the server goes with it and
# `herdr status server` reports "not running" -- the panes are gone. Run
# `herdr server` headless first and it survives the client disconnecting.
#
# So the server is a systemd USER service, plus lingering. Lingering is the
# part people miss: without `loginctl enable-linger`, systemd tears the user's
# whole session down at logout, which is exactly the moment persistence is
# supposed to matter. With it, the server starts at boot and survives every
# disconnect -- SSH in, `herdr`, close the laptop, reattach, still there.
setup_herdr_service() {
    command -v herdr >/dev/null 2>&1 || return 0
    command -v systemctl >/dev/null 2>&1 || {
        warn "no systemd — skipping the herdr service"
        return 0
    }

    local user home group
    for user in $DEVTOOLS_USERS; do
        home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
        if [ -z "$home" ] || [ ! -d "$home" ]; then
            warn "user '${user}' has no home — skipping"
            continue
        fi
        group=$(id -gn "$user" 2>/dev/null || echo "$user")

        mkdir -p "${home}/.config/systemd/user"
        cat >"${home}/.config/systemd/user/herdr.service" <<UNITEOF
# Added by born2root setup/install/tools/install_devtools.sh
[Unit]
Description=Herdr persistent terminal server
Documentation=https://herdr.dev/docs/persistence-remote/
After=default.target

[Service]
Type=simple
ExecStart=$(command -v herdr) server
ExecStop=$(command -v herdr) server stop
Restart=on-failure
RestartSec=3
# The panes are the point; do not let a crash loop kill them silently.
StartLimitIntervalSec=0

[Install]
WantedBy=default.target
UNITEOF
        chown -R "${user}:${group}" "${home}/.config/systemd" 2>/dev/null || true

        loginctl enable-linger "$user" 2>/dev/null ||
            warn "${user}: could not enable lingering — sessions will die at logout"

        # Enabling a user unit is just a symlink into default.target.wants, so
        # create it directly. `systemctl --user enable` cannot do it here: it
        # needs the user's session bus, and at FIRST BOOT nobody has logged in,
        # so /run/user/<uid> does not exist yet. Verified on a fresh build --
        # the unit file was written, the command failed, and the service was
        # left `disabled` forever, because nothing ever retried it.
        local wants="${home}/.config/systemd/user/default.target.wants"
        mkdir -p "$wants"
        ln -sf ../herdr.service "${wants}/herdr.service"
        chown -R "${user}:${group}" "${home}/.config/systemd" 2>/dev/null || true
        log "${user}: herdr service enabled (starts at boot, survives SSH drops)"

        # If the user DOES happen to have a live session, start it now too so
        # it works without waiting for a reboot.
        local uid
        uid=$(id -u "$user")
        if [ -d "/run/user/${uid}" ]; then
            runuser -u "$user" -- env XDG_RUNTIME_DIR="/run/user/${uid}" \
                systemctl --user daemon-reload >/dev/null 2>&1 || true
            if runuser -u "$user" -- env XDG_RUNTIME_DIR="/run/user/${uid}" \
                systemctl --user start herdr.service >/dev/null 2>&1; then
                log "${user}: herdr server started"
            fi
        fi
    done
}

# ── Playwright, and the MCP servers the agents get from it ─────────────────
# npm's prefix is /opt by install_global_scope.sh and its own bin directory is
# NOT on the default PATH, so a package installed here is invisible to the very
# next `command -v` that looks for it -- installed, working, and reported
# missing. Ask npm where it is rather than hardcoding the location (the same
# reasoning as the block at the top of this file).
npm_bin_dir() {
    local prefix
    prefix=$(npm config get prefix --global 2>/dev/null)
    case "$prefix" in
    /*) [ -d "${prefix}/bin" ] && printf '%s\n' "${prefix}/bin" ;;
    esac
}

# The bundled chromium's own path, resolved after `playwright install`.
#
# Needed because @playwright/mcp does not launch the browser the `playwright`
# library installed: it carries its own playwright-core, and its `latest` is
# currently an alpha whose expected browser build is NEWER than the stable
# library's. The server then answers every handshake -- so tools/list looks
# perfect -- and fails on the first real tool call with
#
#     Chromium distribution 'chrome' is not found at /opt/google/chrome/chrome
#
# or, with --browser chromium, "expected executable at
# /usr/lib/ms-playwright/chromium-1246/…" while 1243 is what is on disk. Both
# measured on the 2026-09-27 guest. An explicit --executable-path to the
# browser that is actually installed sidesteps the server's idea of what it
# should be running, and a real browser_navigate then renders.
#
# chrome-linux64/ is the current layout and chrome-linux/ the one before it, so
# both are tried; the newest chromium-* build wins.
resolve_chromium() {
    local builds sub dir
    # Newest build first, so the FIRST hit is the right one: sorted ascending
    # and returning on the first match handed back chromium-999 while 1243 sat
    # beside it (which is what the test that checks this found). `sort -Vr`
    # rather than `ls` (shellcheck SC2012), and rather than reversing by hand.
    builds=$(printf '%s\n' "${PLAYWRIGHT_BROWSERS_PATH}"/chromium-*/ 2>/dev/null |
        sed 's:/$::' | sort -Vr)
    [ -n "$builds" ] || return 1
    for dir in $builds; do
        [ -d "$dir" ] || continue
        for sub in chrome-linux64/chrome chrome-linux/chrome chrome; do
            if [ -x "${dir}/${sub}" ]; then
                printf '%s\n' "${dir}/${sub}"
                return 0
            fi
        done
    done
    return 1
}

# The environment an agent's MCP server process needs. Written to
# /etc/profile.d as well, so an interactive shell and `node -e "require(
# 'playwright')"` both find the library: a GLOBAL npm install is not on
# NODE_PATH, and that is the whole of why a script in any directory used to
# fail with MODULE_NOT_FOUND while playwright sat in /opt.
write_playwright_profile() {
    local npm_bin npm_root
    npm_bin=$(npm_bin_dir)
    # NODE_PATH as a value, not as an expression: this heredoc is unquoted (the
    # other two lines need it), so a literal ${NODE_PATH:-} in it would be
    # expanded HERE, by root's empty environment, and the file would ship
    # `export NODE_PATH=` -- which is how `require('playwright')` went back to
    # MODULE_NOT_FOUND with playwright sitting in /opt/npm-global. Measured, on
    # the run right after the first one.
    npm_root=$(npm root -g 2>/dev/null)
    mkdir -p "$PLAYWRIGHT_PROFILE_D"
    cat >"${PLAYWRIGHT_PROFILE_D}/b2b-playwright.sh" <<PROFILEOF
# Written by setup/install/tools/install_devtools.sh. Playwright, machine-wide.
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH}"
export NODE_PATH="${npm_root}"
# npm's own bin directory: playwright, playwright-mcp.
[ -d "${npm_bin}" ] && export PATH="\${PATH}:${npm_bin}"
PROFILEOF
    # The PATH line above is the only one meant to expand when a shell reads
    # it, so it is the only one with its dollar escaped. This one is for the
    # rest of THIS run: a package installed here has to be on the PATH of the
    # checks below, which are not a login shell.
    if [ -n "$npm_bin" ]; then
        PATH="${PATH}:${npm_bin}"
        export PATH
    fi
    NODE_PATH="$npm_root"
    export PLAYWRIGHT_BROWSERS_PATH NODE_PATH
    chmod 644 "${PLAYWRIGHT_PROFILE_D}/b2b-playwright.sh"
}

install_playwright() {
    local npm_bin want_mcp want_lib

    command -v npm >/dev/null 2>&1 || {
        warn "npm is not installed — the nodejs feature is off, so no Playwright"
        return 1
    }
    npm_bin=$(npm_bin_dir)
    [ -n "$npm_bin" ] || {
        warn "npm has no global bin directory — cannot install Playwright"
        return 1
    }
    PATH="${PATH}:${npm_bin}"
    export PATH
    mkdir -p "$PLAYWRIGHT_BROWSERS_PATH"

    want_lib="playwright"
    want_mcp="@playwright/mcp"
    [ -n "$PLAYWRIGHT_VERSION" ] && want_lib="playwright@${PLAYWRIGHT_VERSION}"
    [ -n "$PLAYWRIGHT_MCP_VERSION" ] && want_mcp="@playwright/mcp@${PLAYWRIGHT_MCP_VERSION}"

    # Idempotence, like the two binaries above: a re-run of first boot, or of
    # `make devtools`, must not re-download 660 MB it already has. The version
    # npm reports is the pin, so a pinned build that is already there is done.
    if [ -x "${npm_bin}/playwright" ] && [ -x "${npm_bin}/playwright-mcp" ]; then
        local have
        have=$("${npm_bin}/playwright" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
        if [ -z "$PLAYWRIGHT_VERSION" ] || [ "$have" = "$PLAYWRIGHT_VERSION" ]; then
            if [ -d "$PLAYWRIGHT_BROWSERS_PATH" ] && [ -n "$(ls -A "$PLAYWRIGHT_BROWSERS_PATH" 2>/dev/null)" ]; then
                log "playwright ${have} already installed, browsers in ${PLAYWRIGHT_BROWSERS_PATH}"
                write_playwright_profile
                return 0
            fi
            log "playwright ${have} is installed but ${PLAYWRIGHT_BROWSERS_PATH} is empty — fetching the browsers"
        else
            log "playwright ${have} installed, ${PLAYWRIGHT_VERSION} asked for — updating"
        fi
    fi

    log "installing ${want_lib} and ${want_mcp} (npm prefix $(npm config get prefix --global 2>/dev/null))"
    if ! npm install -g --no-fund --no-audit "$want_lib" "$want_mcp" >/tmp/pw-npm.$$ 2>&1; then
        warn "npm install failed:"
        tail -5 /tmp/pw-npm.$$ | sed 's/^/[devtools]   /'
        rm -f /tmp/pw-npm.$$
        return 1
    fi
    rm -f /tmp/pw-npm.$$

    # --with-deps pulls the shared libraries chromium needs (libnss3, libgbm,
    # the fonts, the codecs) through apt, which is why this needs root and why
    # a browser installed by hand so often cannot start. $PLAYWRIGHT_BROWSERS
    # is a name, never a flag: an empty value would install every engine.
    log "fetching ${PLAYWRIGHT_BROWSERS} into ${PLAYWRIGHT_BROWSERS_PATH} (with its system libraries)"
    # shellcheck disable=SC2086 # a LIST: PLAYWRIGHT_BROWSERS="chromium firefox"
    # must reach the CLI as two words, and quoting it would pass one name.
    if ! PLAYWRIGHT_BROWSERS_PATH="$PLAYWRIGHT_BROWSERS_PATH" \
        "${npm_bin}/playwright" install --with-deps $PLAYWRIGHT_BROWSERS >/tmp/pw-browsers.$$ 2>&1; then
        warn "playwright install failed:"
        tail -8 /tmp/pw-browsers.$$ | sed 's/^/[devtools]   /'
        rm -f /tmp/pw-browsers.$$
        return 1
    fi
    rm -f /tmp/pw-browsers.$$
    write_playwright_profile
    log "playwright $("${npm_bin}/playwright" --version 2>/dev/null | head -n1), browsers in ${PLAYWRIGHT_BROWSERS_PATH} ($(du -sm "$PLAYWRIGHT_BROWSERS_PATH" 2>/dev/null | awk '{print $1}') MB)"
}

# Register the two MCP servers with every agent this guest has. Adding a key
# the project owns is not the same as overwriting a user's file: opencode's
# config is merged key by key, and nothing else in either agent's state file is
# touched.
#
# Both configs are written directly rather than through the agents' own CLIs.
# `claude mcp add` verifies by launching the server and waiting on it, and
# through runuser with a pty that wait does not end: measured 120 s per call
# (the `timeout` firing) with the launched server left holding the terminal, so
# the whole feature took twelve minutes and never returned the terminal. The
# shape it writes is small and documented, and the verification below is ours
# and bounded.
register_playwright_mcp() {
    local user home group npm_bin chromium
    npm_bin=$(npm_bin_dir)
    [ -x "${npm_bin}/playwright-mcp" ] || {
        warn "${npm_bin}/playwright-mcp is not there — no MCP server to register"
        return 1
    }
    # The browser that is actually installed, named explicitly: see
    # resolve_chromium. Empty if the browsers somehow are not there, and then
    # the registration is written without the flag rather than with a path that
    # does not exist.
    chromium=$(resolve_chromium || true)
    [ -n "$chromium" ] ||
        warn "no chromium under ${PLAYWRIGHT_BROWSERS_PATH} — the MCP server will look for a browser itself"
    # run_as_agent hands its PATH on, and the agents' own CLIs live there.
    case ":${PATH}:" in
    *":${npm_bin}:"*) ;;
    *)
        PATH="${PATH}:${npm_bin}"
        export PATH
        ;;
    esac

    for user in $DEVTOOLS_USERS; do
        home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
        if [ -z "$home" ] || [ ! -d "$home" ]; then
            continue
        fi
        group=$(id -gn "$user" 2>/dev/null || echo "$user")

        # ── opencode ──────────────────────────────────────────────────────
        # `mcp.servers`, not `mcp`: an entry under the wrong key is accepted by
        # the JSON and then invisible, which `opencode mcp list` reports as "No
        # MCP servers configured". Its own CLI writes the right shape and
        # answers in a second, so it goes first; the merge is the fallback.
        local oc="${home}/.opencode/bin/opencode"
        if [ -x "$oc" ] && [ -n "$chromium" ]; then
            if run_as_agent "$user" "$oc" mcp add --global playwright \
                --env "PLAYWRIGHT_BROWSERS_PATH=${PLAYWRIGHT_BROWSERS_PATH}" -- \
                "${npm_bin}/playwright-mcp" --executable-path "$chromium" >/dev/null 2>&1 &&
                run_as_agent "$user" "$oc" mcp add --global playwright-host \
                    --env "PLAYWRIGHT_BROWSERS_PATH=${PLAYWRIGHT_BROWSERS_PATH}" -- \
                    "${npm_bin}/playwright-mcp" --cdp-endpoint "$PLAYWRIGHT_CDP_ENDPOINT" \
                    --cdp-timeout "$PLAYWRIGHT_CDP_TIMEOUT" >/dev/null 2>&1; then
                log "${user}: opencode MCP servers registered (playwright, playwright-host)"
            else
                warn "${user}: opencode's CLI refused — writing its config directly"
                merge_agent_mcp "$user" "$home" "opencode"
            fi
        else
            [ -x "$oc" ] || warn "${user}: no opencode binary — skipping its MCP servers"
            merge_agent_mcp "$user" "$home" "opencode"
        fi

        # ── Claude Code ───────────────────────────────────────────────────
        # ~/.claude.json is a 45-key state file (projects, history, tips).
        # Merged, not rewritten: a hand edit that dropped a key would look
        # like a fresh install to the agent.
        if [ -x /usr/local/bin/claude ]; then
            merge_agent_mcp "$user" "$home" "claude"
        fi

        chown -R "${user}:${group}" "${home}/.config/opencode" 2>/dev/null || true
    done
}

# Merge the two servers into an agent's own config, leaving every other key
# exactly as it was. opencode: ~/.config/opencode/opencode.json under
# mcp.servers. Claude Code: ~/.claude.json under mcpServers, as
# {"type":"stdio","command":…,"args":[…],"env":{…}}.
merge_agent_mcp() {
    local user="$1" home="$2" which="$3" mcp_bin chromium
    # Plain assignments, not a `VAR=x cmd` prefix: the shell expands that
    # command's arguments BEFORE the prefix applies, so the python would have
    # been handed the previous values (shellcheck SC2097/SC2098 — and it was,
    # until this was read properly).
    mcp_bin="$(npm_bin_dir)/playwright-mcp"
    chromium="$(resolve_chromium || true)"
    python3 - "$home" "$which" "$PLAYWRIGHT_BROWSERS_PATH" "$PLAYWRIGHT_CDP_ENDPOINT" \
        "$PLAYWRIGHT_CDP_TIMEOUT" "$mcp_bin" "$chromium" <<'PYEOF' || return 1
import json, os, sys
home, which, browsers, cdp, cdp_timeout, mcp_bin, chromium = sys.argv[1:8]
mcp_bin = mcp_bin or "/opt/npm-global/bin/playwright-mcp"

def server(extra=()):
    args = list(extra)
    # The bundled browser, named explicitly -- but only for the server that
    # launches one. The host's Chrome is named by --cdp-endpoint, and pointing
    # that one at a local executable would be asking for the wrong browser.
    if chromium and not any(a == "--cdp-endpoint" for a in args):
        args = ["--executable-path", chromium] + args
    return {"type": "stdio", "command": mcp_bin, "args": args,
            "env": {"PLAYWRIGHT_BROWSERS_PATH": browsers}}

servers = {
    "playwright": server(),
    # --cdp-timeout keeps a missing reverse tunnel from stalling a tool call
    # for the upstream default of 30 s.
    "playwright-host": server(("--cdp-endpoint", cdp, "--cdp-timeout", cdp_timeout)),
}

if which == "opencode":
    path = os.path.join(home, ".config", "opencode", "opencode.json")
    cfg = {}
    if os.path.exists(path):
        try:
            with open(path) as fh:
                cfg = json.load(fh)
        except Exception:
            os.rename(path, path + ".broken")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    cfg.setdefault("mcp", {}).setdefault("servers", {}).update(servers)
else:
    path = os.path.join(home, ".claude.json")
    cfg = {}
    if os.path.exists(path):
        try:
            with open(path) as fh:
                cfg = json.load(fh)
        except Exception:
            os.rename(path, path + ".broken")
    cfg.setdefault("mcpServers", {}).update(servers)

tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(cfg, fh, indent=2, sort_keys=True)
    fh.write("\n")
os.replace(tmp, path)
os.chmod(path, 0o644)
print(path)
PYEOF
    log "${user}: wrote $([ "$which" = opencode ] && echo "${home}/.config/opencode/opencode.json" || echo "${home}/.claude.json") (playwright, playwright-host)"
}

# Prove the registration works, without an agent and without an API key: spawn
# each server as that user, do the MCP handshake, count the tools, and give up
# on a clock. This is the check that says "the agent can use Playwright", and
# it is ours precisely because the CLIs' own verification is not bounded.
write_playwright_verify() {
    mkdir -p "$(dirname "$PLAYWRIGHT_VERIFY_JS")"
    cat >"$PLAYWRIGHT_VERIFY_JS" <<'JSEOF'
// playwright-mcp-check.js — written by setup/install/tools/install_devtools.sh
//   node playwright-mcp-check.js <label> <playwright-mcp> [args...]
// Speaks just enough MCP to prove a server is USABLE, not merely present:
// initialize, the initialized notification, tools/list, and then a real
// browser_navigate at a data: URL with a marker in it.
//
// That last step is the whole point. A handshake and tools/list are answered by
// a server that cannot start a browser at all: on 2026-09-27 the `playwright`
// server reported 25 tools and then answered every tool call with "Chromium
// distribution 'chrome' is not found at /opt/google/chrome/chrome", because
// @playwright/mcp carries its own playwright-core and looks for a browser the
// `playwright` library never installed. Only a call that renders a page can
// tell the difference.
//
// Prints "TOOLS=<n> NAV=ok <first three tool names>" on success, which is what
// the caller greps for. No timeout of its own -- the caller runs it under
// `timeout`, and a timer inside a child that also has to answer four round
// trips is one more thing to get wrong.
const { spawn } = require('node:child_process');
const [, , label, bin, ...args] = process.argv;
if (!bin) {
    console.error('usage: playwright-mcp-check.js <label> <server> [args...]');
    process.exit(2);
}
const MARK = 'b2b-playwright-mcp-check';
const child = spawn(bin, args, { stdio: ['pipe', 'pipe', 'pipe'] });
let out = '';
let err = '';
child.stdout.on('data', (c) => { out += c.toString(); });
child.stderr.on('data', (c) => { err += c.toString(); });
const pending = new Map();
const send = (method, params) => {
    const id = pending.size + 1;
    return new Promise((resolve) => {
        pending.set(id, resolve);
        child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
    });
};
child.stdout.on('data', () => {
    for (const line of out.split('\n')) {
        if (!line.trim()) continue;
        let msg;
        try { msg = JSON.parse(line); } catch { continue; }
        if (msg.id !== undefined && pending.has(msg.id)) {
            pending.get(msg.id)(msg);
            pending.delete(msg.id);
        }
    }
    out = '';
});
child.on('error', (e) => {
    console.error(`could not start ${bin}: ${e.message}`);
    process.exit(2);
});
(async () => {
    const init = await send('initialize', {
        protocolVersion: '2024-11-05',
        capabilities: {},
        clientInfo: { name: 'b2b-check', version: '1' },
    });
    if (!init.result) {
        console.error('no initialize result: ' + JSON.stringify(init.error || init).slice(0, 200));
        process.exit(1);
    }
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized', params: {} }) + '\n');
    const tools = await send('tools/list', {});
    const names = ((tools.result && tools.result.tools) || []).map((t) => t.name);
    if (!names.length) {
        console.error('no tools: ' + JSON.stringify(tools.error || tools).slice(0, 200));
        process.exit(1);
    }
    if (!names.includes('browser_navigate')) {
        console.error('browser_navigate is not among the ' + names.length + ' tools');
        process.exit(1);
    }
    // The real one. data: needs no server, no DNS and no network, so a failure
    // here is the browser, never the page.
    const url = 'data:text/html,<h1>' + MARK + '</h1>';
    const nav = await send('tools/call', { name: 'browser_navigate', arguments: { url } });
    if (nav.timeout) {
        console.error('browser_navigate timed out');
        process.exit(1);
    }
    if (nav.error) {
        console.error('browser_navigate error: ' + JSON.stringify(nav.error).slice(0, 200));
        process.exit(1);
    }
    const text = JSON.stringify((nav.result && nav.result.content) || '');
    if (!text.includes(MARK)) {
        console.error('browser_navigate did not render: ' + text.slice(0, 300));
        if (err.trim()) console.error('server said: ' + err.trim().slice(0, 200));
        process.exit(1);
    }
    console.log(`TOOLS=${names.length} NAV=ok ${names.slice(0, 3).join(' ')} (${label})`);
    child.kill('SIGTERM');
    process.exit(0);
})();
JSEOF
    chmod 644 "$PLAYWRIGHT_VERIFY_JS"
}

verify_playwright_mcp() {
    local user home npm_bin chromium
    npm_bin=$(npm_bin_dir)
    [ -x "${npm_bin}/playwright-mcp" ] || return 1
    write_playwright_verify
    chromium=$(resolve_chromium || true)
    for user in $DEVTOOLS_USERS; do
        home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
        [ -n "$home" ] || continue
        local label out
        for label in playwright playwright-host; do
            if [ "$label" = "playwright-host" ]; then
                out=$(run_as_agent "$user" node "${PLAYWRIGHT_VERIFY_JS}" "$label" \
                    "${npm_bin}/playwright-mcp" --cdp-endpoint "$PLAYWRIGHT_CDP_ENDPOINT" \
                    --cdp-timeout "$PLAYWRIGHT_CDP_TIMEOUT" 2>&1)
            elif [ -n "$chromium" ]; then
                out=$(run_as_agent "$user" node "${PLAYWRIGHT_VERIFY_JS}" "$label" \
                    "${npm_bin}/playwright-mcp" --executable-path "$chromium" 2>&1)
            else
                out=$(run_as_agent "$user" node "${PLAYWRIGHT_VERIFY_JS}" "$label" \
                    "${npm_bin}/playwright-mcp" 2>&1)
            fi
            # NAV=ok is the part that matters: a tools/list answer on its own
            # comes from a server that cannot start a browser at all.
            case "$out" in
            *"NAV=ok"*) log "${user}: ${label} MCP server navigates — ${out##*TOOLS=}" ;;
            *)
                warn "${user}: the ${label} MCP server did not render a page: ${out:0:300}"
                return 1
                ;;
            esac
        done
    done
    return 0
}

# An agent's MCP server is a process of that user's, not root's: HOME, the
# agent's own config and its state all have to be theirs. `su` with a pty
# allocated starts a login shell and ignores the -c (measured), so runuser
# with an explicit environment is the reliable way.
#
# The output goes to a file and stdin comes from /dev/null, for the same
# reason the nvim bootstrap does it: a server this command launches inherits
# the pty otherwise, and the session then never sees EOF -- the 2026-09-27
# `make devtools` returned nothing and hung after the script had exited.
run_as_agent() {
    local user="$1"
    shift
    local home out rc
    home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
    [ -n "$home" ] || return 1
    out=$(mktemp /var/tmp/b2b-agent.XXXXXX 2>/dev/null) || out="/var/tmp/b2b-agent.$$"
    timeout 120 runuser -u "$user" -- env -C "$home" \
        "HOME=${home}" "USER=${user}" "LOGNAME=${user}" \
        "PATH=${PATH}" "PLAYWRIGHT_BROWSERS_PATH=${PLAYWRIGHT_BROWSERS_PATH}" \
        "$@" >"$out" 2>&1 </dev/null
    rc=$?
    [ -s "$out" ] && sed 's/^/[devtools]   /' "$out" | tail -6
    rm -f "$out"
    return "$rc"
}

# ── Shell convenience ───────────────────────────────────────────────────────
# Herdr's whole value here is that a session outlives the SSH connection, so
# point at it from the MOTD rather than leaving it as something you have to
# remember was installed.
write_motd_hint() {
    command -v herdr >/dev/null 2>&1 || return 0
    cat >/etc/update-motd.d/50-b2b-devtools <<'MOTDEOF'
#!/bin/sh
# Added by born2root setup/install/tools/install_devtools.sh
printf '\n  herdr        persistent terminal panes (survives an SSH drop)\n'
printf '  vw           open a saved Neovim session\n'
printf '  opencode     AI coding agent — free local models: make llm_host on the host\n'
command -v playwright >/dev/null 2>&1 && printf '  playwright   browser for the agents (MCP); playwright-host = your host Chrome\n'
printf '\n'
MOTDEOF
    chmod 755 /etc/update-motd.d/50-b2b-devtools 2>/dev/null || true
}

log "=== devtools: herdr + opencode + playwright ==="
# if/else, not `cond && fn || log`: that idiom runs the log branch whenever the
# FUNCTION returns non-zero too, so a failed install would report itself as
# "skipped by configuration" — the wrong message for the wrong reason.
if [ "$INSTALL_HERDR" = "1" ]; then
    install_herdr
else
    log "INSTALL_HERDR=0 — skipping Herdr"
fi
if [ "$INSTALL_OPENCODE" = "1" ]; then
    install_opencode
else
    log "INSTALL_OPENCODE=0 — skipping opencode"
fi
# The baseline config first: it writes opencode.json from scratch, and the MCP
# registration below merges into that file rather than racing it.
configure_opencode_baseline
if [ "$INSTALL_PLAYWRIGHT" = "1" ]; then
    # The verification is a separate step because it needs the browsers, which
    # only exist if the install above worked.
    if install_playwright; then
        register_playwright_mcp
        verify_playwright_mcp || warn "the Playwright MCP servers did not answer a handshake — see above"
    fi
else
    log "INSTALL_PLAYWRIGHT=0 — skipping Playwright (features.conf does not list it, or it was turned off)"
fi
setup_herdr_service
write_motd_hint

# The verdict: what was asked for and is not on PATH is a failed feature.
rc=0
if [ "$INSTALL_HERDR" = "1" ] && ! command -v herdr >/dev/null 2>&1; then
    warn "herdr was requested and is not installed"
    rc=1
fi
if [ "$INSTALL_OPENCODE" = "1" ] && [ ! -x "$OPENCODE_DEST" ]; then
    warn "opencode was requested and is not installed"
    rc=1
fi
if [ "$INSTALL_PLAYWRIGHT" = "1" ]; then
    _npm_bin=$(npm_bin_dir)
    if [ ! -x "${_npm_bin}/playwright" ] || [ ! -x "${_npm_bin}/playwright-mcp" ]; then
        warn "playwright was requested and is not installed"
        rc=1
    fi
    # The browser is the part that is easy to get wrong: the library installs
    # fine and every spawn then fails, so its absence is what the feature is
    # really about.
    if [ -z "$(ls -A "$PLAYWRIGHT_BROWSERS_PATH" 2>/dev/null)" ]; then
        warn "playwright installed but ${PLAYWRIGHT_BROWSERS_PATH} holds no browser"
        rc=1
    fi
    unset _npm_bin
fi
log "=== done (herdr: $(command -v herdr >/dev/null 2>&1 && herdr --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || echo none), opencode: $([ -x "$OPENCODE_DEST" ] && "$OPENCODE_DEST" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || echo none), playwright: $(command -v playwright >/dev/null 2>&1 && playwright --version 2>/dev/null | head -n1 || echo none)) ==="
exit "$rc"
