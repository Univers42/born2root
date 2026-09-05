#!/bin/bash
#
# install_devtools.sh — Herdr and Claude Code.
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
# CLAUDE CODE
#   npm install -g @anthropic-ai/claude-code. Lands in the npm prefix set by
#   install_global_scope.sh (/opt/npm-global), so it does not consume /.
#
# USAGE
#   sudo ./install_devtools.sh
#   sudo HERDR_VERSION=v0.8.2 ./install_devtools.sh    # pin instead of latest
#   sudo INSTALL_HERDR=0 ./install_devtools.sh          # skip one of them
#   sudo INSTALL_CLAUDE_CODE=0 ./install_devtools.sh

set -u

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# The npm prefix is moved to /opt by install_global_scope.sh, and npm's own
# bin directory is NOT on the default PATH. Without this line a package this
# script installs itself (tree-sitter, claude) is invisible to the very next
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
INSTALL_CLAUDE_CODE="${INSTALL_CLAUDE_CODE:-1}"
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

# ── Claude Code ─────────────────────────────────────────────────────────────
install_claude_code() {
    command -v npm >/dev/null 2>&1 || {
        warn "npm not installed — skipping Claude Code"
        return 0
    }

    # Node 18+ is required. Debian 13 ships 20+, but say so plainly rather than
    # failing later with a syntax error from a modern bundle on an old runtime.
    local major
    major=$(node -v 2>/dev/null | sed 's/^v\([0-9]*\).*/\1/')
    if [ -n "$major" ] && [ "$major" -lt 18 ]; then
        warn "node ${major} is too old for Claude Code (needs 18+) — skipping"
        return 0
    fi

    if command -v claude >/dev/null 2>&1; then
        log "claude already installed: $(claude --version 2>/dev/null | head -n1)"
        return 0
    fi

    log "installing Claude Code (npm i -g @anthropic-ai/claude-code)"
    if npm install -g @anthropic-ai/claude-code >/dev/null 2>&1; then
        hash -r 2>/dev/null || true
        local prefix
        prefix=$(npm config get prefix --global 2>/dev/null)
        if [ -x "${prefix}/bin/claude" ] || command -v claude >/dev/null 2>&1; then
            log "claude installed into ${prefix}/bin"
        else
            warn "npm reported success but no claude binary was found"
        fi
    else
        warn "npm install of Claude Code failed (network? registry?)"
    fi
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
        [ -n "$home" ] && [ -d "$home" ] || {
            warn "user '${user}' has no home — skipping"
            continue
        }
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
            runuser -u "$user" -- env XDG_RUNTIME_DIR="/run/user/${uid}" \
                systemctl --user start herdr.service >/dev/null 2>&1 &&
                log "${user}: herdr server started" || true
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
command -v claude >/dev/null 2>&1 && printf '  claude       Claude Code\n'
printf '\n'
MOTDEOF
    chmod 755 /etc/update-motd.d/50-b2b-devtools 2>/dev/null || true
}

log "=== devtools: herdr + claude code ==="
# if/else, not `cond && fn || log`: that idiom runs the log branch whenever the
# FUNCTION returns non-zero too, so a failed install would report itself as
# "skipped by configuration" — the wrong message for the wrong reason.
if [ "$INSTALL_HERDR" = "1" ]; then install_herdr; else log "INSTALL_HERDR=0 — skipping Herdr"; fi
if [ "$INSTALL_CLAUDE_CODE" = "1" ]; then install_claude_code; else log "INSTALL_CLAUDE_CODE=0 — skipping Claude Code"; fi
setup_herdr_service
write_motd_hint
log "=== done ==="
