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
# USAGE
#   sudo ./install_devtools.sh
#   sudo HERDR_VERSION=v0.8.2 ./install_devtools.sh       # pin instead of latest
#   sudo OPENCODE_VERSION=v1.18.30 ./install_devtools.sh  # same for opencode
#   sudo INSTALL_HERDR=0 ./install_devtools.sh             # skip one of them
#   sudo INSTALL_OPENCODE=0 ./install_devtools.sh
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
DEVTOOLS_USERS="${DEVTOOLS_USERS:-dlesieur}"

log() { printf '[devtools] %s\n' "$*"; }
warn() { printf '[devtools] WARN: %s\n' "$*" >&2; }
die() {
    printf '[devtools] ERROR: %s\n' "$*" >&2
    exit 1
}

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
# to exist: this is the one edit away from working, and the MOTD hint says
# which edit. Serve a model on the host and it works as it stands:
#
#     OLLAMA_HOST=0.0.0.0 ollama serve        # the default binds 127.0.0.1,
#                                             # which the VM cannot reach
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
command -v opencode >/dev/null 2>&1 && printf '  opencode     AI coding agent — first time: opencode auth login\n'
printf '\n'
MOTDEOF
    chmod 755 /etc/update-motd.d/50-b2b-devtools 2>/dev/null || true
}

log "=== devtools: herdr + opencode ==="
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
configure_opencode_baseline
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
log "=== done (herdr: $(command -v herdr >/dev/null 2>&1 && herdr --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || echo none), opencode: $([ -x "$OPENCODE_DEST" ] && "$OPENCODE_DEST" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || echo none)) ==="
exit "$rc"
