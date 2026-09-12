#!/usr/bin/env hellish
#
# install_claude_code.sh — Claude Code, beside opencode rather than instead of it.
#
# WHY BOTH
#   opencode came in on 2026-09-12 as the one agent, on the argument that it
#   speaks to any provider while `npm i -g @anthropic-ai/claude-code` was tied
#   to one vendor and cost 414 MB on / (see install_devtools.sh). That argument
#   was about the npm package, and it is still true of the npm package. It is
#   not an argument that opencode can BE Claude Code: opencode with an
#   Anthropic key is opencode talking to Anthropic's models, not Claude Code --
#   different agent loop, different tools, no skills, no subagents, no hooks,
#   no /commands, and none of the CLAUDE.md handling this repository is written
#   around. So the two are installed side by side and you pick per task.
#
# WHY NOT THE npm PACKAGE, AND NOT install.sh EITHER
#   Anthropic ships a self-contained binary now: 319 MB installed, against the
#   414 MB the npm tree measured on the 2026-09-12 build, and with no node
#   runtime in the dependency chain.
#
#   Upstream's `curl -fsSL https://claude.ai/install.sh | bash` is not used, for
#   the reason herdr's and opencode's installers are not used -- piping a remote
#   script into a shell inside an unattended first boot is unreviewable and
#   unpinnable -- plus one specific to this one: install.sh installs per user
#   into $HOME/.local, and 319 MB per user lands on the /home volume that
#   generate/partition_recipe.sh sizes for Neovim's plugins and .vscode-server.
#   One copy in /usr/local/bin is on /, where the manifest budgets for it.
#
#   What install.sh does that is worth keeping is the verification, and this
#   script keeps all of it: the release manifest carries a published SHA256 per
#   platform, so unlike herdr and opencode (whose upstreams publish none) the
#   download here is checksummed properly, not just proven to be an ELF file.
#
# ZSTD FAST PATH
#   The plain binary is a 335 MB download; the zstd-compressed one is 74 MB for
#   the identical bytes (measured on 2.1.236). On a campus link inside a 20
#   minute install budget that is the difference worth the extra twenty lines,
#   so zstd is used when the guest has it and the plain URL is the fallback.
#   Both are checksummed -- the .zst against its own manifest, the decompressed
#   result against the real one -- so the fast path cannot install something the
#   slow path would have rejected.
#
# AUTHENTICATION IS NOT DONE HERE, ON PURPOSE
#   No credential is baked into the ISO. The ISO is a file that gets copied to
#   USB sticks and shared with classmates, and an Anthropic OAuth token in it is
#   a leaked token. In the guest, run `claude` and follow /login (it prints a
#   URL to paste into a browser on the host -- no browser is needed in the VM),
#   or export ANTHROPIC_API_KEY. The MOTD line says so.
#
# USAGE
#   sudo ./install_claude_code.sh
#   sudo CLAUDE_CODE_VERSION=2.1.236 ./install_claude_code.sh   # pin
#   sudo CLAUDE_CODE_CHANNEL=latest ./install_claude_code.sh    # not stable
#   sudo INSTALL_CLAUDE_CODE=0 ./install_claude_code.sh         # no-op
#
# Exits non-zero when it was asked to install and `claude` is not runnable
# afterwards, so first boot records claude-code as failed instead of a [WARN]
# scrolling past in a log nobody reads.

set -u

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

CLAUDE_CODE_BASE_URL="${CLAUDE_CODE_BASE_URL:-https://downloads.claude.ai/claude-code-releases}"
CLAUDE_CODE_CHANNEL="${CLAUDE_CODE_CHANNEL:-stable}"
CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-}" # empty = whatever the channel says
CLAUDE_CODE_DEST="${CLAUDE_CODE_DEST:-/usr/local/bin/claude}"
INSTALL_CLAUDE_CODE="${INSTALL_CLAUDE_CODE:-1}"
CLAUDE_CODE_USERS="${CLAUDE_CODE_USERS:-dlesieur}"
# Staging lives on /var, not /tmp: the tarball-free binary alone is 319 MB and
# the /tmp volume this layout makes is 0.4 GB at SIZE_B2B=15.
CLAUDE_CODE_TMPDIR="${CLAUDE_CODE_TMPDIR:-/var/tmp}"

log() { printf '[claude-code] %s\n' "$*"; }
warn() { printf '[claude-code] WARN: %s\n' "$*" >&2; }
die() {
    printf '[claude-code] ERROR: %s\n' "$*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"

if [ "$INSTALL_CLAUDE_CODE" != "1" ]; then
    log "INSTALL_CLAUDE_CODE=0 — nothing to do"
    exit 0
fi
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"

# ── Which build ─────────────────────────────────────────────────────────────
# Same platform naming upstream's installer uses. The musl test matters because
# a musl binary on glibc (or the reverse) dies at exec with a linker error that
# reads like a corrupt download.
detect_platform() {
    local arch
    case "$(uname -m)" in
    x86_64 | amd64) arch="x64" ;;
    aarch64 | arm64) arch="arm64" ;;
    *)
        warn "no Claude Code build for $(uname -m)"
        return 1
        ;;
    esac
    local libc=gnu
    [ -f /lib/libc.musl-x86_64.so.1 ] && libc=musl
    [ -f /lib/libc.musl-aarch64.so.1 ] && libc=musl
    ldd /bin/ls 2>&1 | grep -q musl && libc=musl
    if [ "$libc" = musl ]; then
        printf 'linux-%s-musl' "$arch"
    else
        printf 'linux-%s' "$arch"
    fi
}

# manifest_field <json> <platform> <checksum|size>
#
# jq is not a dependency in this guest, so the field comes out with sed. The
# [^{}] is load-bearing rather than tidiness: the darwin entries in
# manifest.zst.json nest a "bundle" object with its OWN checksum, and a pattern
# that can cross a brace happily returns the wrong one.
manifest_field() {
    printf '%s' "$1" | tr -d '\n\r\t' | sed 's/  */ /g' |
        sed -n "s/.*\"$2\" *: *{\([^{}]*\)}.*/\1/p" |
        sed -n "s/.*\"$3\" *: *\"\{0,1\}\([0-9a-f]\{1,\}\)\"\{0,1\}.*/\1/p" |
        head -n1
}

fetch() { curl -fsSL --max-time 60 --retry 3 --retry-delay 2 "$1" 2>/dev/null; }
sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# Debian ships libzstd1 in a standard install but NOT the zstd command: it is
# priority optional, and nothing in this build pulls it in. That one missing
# ~700 kB package is the difference between a 74 MB download and a 335 MB one,
# so it is worth an apt line. Best effort only -- if apt cannot, the plain
# binary is still a correct install, just a slower one.
ensure_zstd() {
    command -v zstd >/dev/null 2>&1 && return 0
    command -v apt-get >/dev/null 2>&1 || return 0
    log "installing zstd so the download is 74 MB instead of 335"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zstd >/dev/null 2>&1 || true
    command -v zstd >/dev/null 2>&1 || warn "zstd is unavailable — falling back to the full download"
}

# ── Install ─────────────────────────────────────────────────────────────────
install_claude_code() {
    local platform version manifest checksum size have tmp bin url

    platform=$(detect_platform) || return 1

    if [ -n "$CLAUDE_CODE_VERSION" ]; then
        version="$CLAUDE_CODE_VERSION"
    else
        version=$(fetch "${CLAUDE_CODE_BASE_URL}/${CLAUDE_CODE_CHANNEL}")
    fi
    # A download service that is unreachable, or blocked in this region, answers
    # with an HTML page rather than an error, and that page would otherwise go
    # straight into the manifest URL. Reject anything that is not a version.
    case "$version" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *)
        warn "could not resolve a version from ${CLAUDE_CODE_BASE_URL}/${CLAUDE_CODE_CHANNEL}"
        warn "(offline, or the service is not available in this region:"
        warn " https://www.anthropic.com/supported-countries)"
        return 1
        ;;
    esac

    # Already at this version? First boot and a later `make claude_code` must
    # not re-download 74 MB to arrive where they already are.
    if [ -x "$CLAUDE_CODE_DEST" ]; then
        have=$("$CLAUDE_CODE_DEST" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
        if [ -n "$have" ] && [ "$have" = "$version" ]; then
            log "claude ${have} already installed"
            return 0
        fi
    fi

    manifest=$(fetch "${CLAUDE_CODE_BASE_URL}/${version}/manifest.json")
    checksum=$(manifest_field "$manifest" "$platform" checksum)
    size=$(manifest_field "$manifest" "$platform" size)
    case "$checksum" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
    *)
        warn "platform ${platform} is not in the ${version} manifest"
        return 1
        ;;
    esac
    [ "${#checksum}" -eq 64 ] || {
        warn "the checksum for ${platform} is not a SHA256"
        return 1
    }

    # Fail before the download rather than during it: /usr/local/bin is on /,
    # and a 319 MB binary landing on a volume with 100 MB left is how dpkg and
    # GRUB break on this machine.
    local need_mb avail_mb
    need_mb=$((size / 1048576 + 64))
    avail_mb=$(df -k /usr/local/bin 2>/dev/null | awk 'NR==2 {printf "%d", $4 / 1024}')
    if [ -n "$avail_mb" ] && [ "$avail_mb" -lt "$need_mb" ]; then
        warn "claude needs ${need_mb} MB on $(df --output=target /usr/local/bin 2>/dev/null | tail -n1), which has ${avail_mb} MB"
        warn "Build a bigger disk: make re SIZE_B2B=20"
        return 1
    fi

    tmp=$(mktemp -d "${CLAUDE_CODE_TMPDIR}/claude-code.XXXXXX") || die "mktemp failed"
    bin="${tmp}/claude"

    # zstd first (74 MB against 335), plain binary as the fallback. `head -c
    # $size` is upstream's own truncation: the stream can carry trailing bytes
    # the checksum does not cover.
    local zsum=""
    ensure_zstd
    if command -v zstd >/dev/null 2>&1 && [ -n "$size" ]; then
        zsum=$(manifest_field "$(fetch "${CLAUDE_CODE_BASE_URL}/${version}/manifest.zst.json")" "$platform" checksum)
    fi
    if [ "${#zsum}" -eq 64 ]; then
        log "downloading claude ${version} (${platform}, zstd)"
        if curl -fL --retry 3 --retry-delay 2 --max-time 600 -o "${bin}.zst" \
            "${CLAUDE_CODE_BASE_URL}/${version}/${platform}/claude.zst" 2>/dev/null &&
            [ "$(sha_of "${bin}.zst")" = "$zsum" ]; then
            zstd -d -q -c "${bin}.zst" 2>/dev/null | head -c "$size" >"$bin" || true
        else
            warn "the compressed download failed its checksum — falling back to the plain binary"
        fi
        rm -f "${bin}.zst"
    fi
    if [ "$(sha_of "$bin")" != "$checksum" ]; then
        log "downloading claude ${version} (${platform}, ${need_mb} MB)"
        url="${CLAUDE_CODE_BASE_URL}/${version}/${platform}/claude"
        if ! curl -fL --retry 3 --retry-delay 2 --max-time 900 -o "$bin" "$url" 2>/dev/null; then
            warn "download failed: ${url}"
            rm -rf "$tmp"
            return 1
        fi
    fi
    if [ "$(sha_of "$bin")" != "$checksum" ]; then
        warn "checksum mismatch for ${platform} at ${version} — discarding the download"
        rm -rf "$tmp"
        return 1
    fi
    log "checksum verified against the ${version} manifest"

    # RUN it before installing it. Claude Code is a Bun-compiled binary, and
    # Bun's x86_64 build wants AVX2: under QEMU without KVM the guest CPU is
    # -cpu qemu64, which has no AVX2, and the process dies with SIGILL. That is
    # a machine problem, not a download problem, and it has to say so.
    chmod 755 "$bin"
    have=$("$bin" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    if [ -z "$have" ]; then
        warn "the downloaded claude binary does not run on this machine:"
        "$bin" --version 2>&1 | sed 's/^/[claude-code]   /' | head -3
        if ! grep -q avx2 /proc/cpuinfo 2>/dev/null; then
            warn "this CPU reports no AVX2, which Claude Code's build needs."
            warn "Under QEMU that means the guest is on -cpu qemu64: KVM is off"
            warn "(setup/host/qemu_vm.sh passes -cpu host only with KVM)."
        fi
        rm -rf "$tmp"
        return 1
    fi

    if ! mv -f "$bin" "$CLAUDE_CODE_DEST"; then
        warn "could not install into ${CLAUDE_CODE_DEST}"
        rm -rf "$tmp"
        return 1
    fi
    chmod 755 "$CLAUDE_CODE_DEST"
    rm -rf "$tmp"
    log "claude ${have} installed at ${CLAUDE_CODE_DEST}"
}

# ── Keep it from trying to update itself ────────────────────────────────────
# One copy in /usr/local/bin is root-owned, so the auto-updater cannot replace
# it from a user shell -- it can only fail, once per session, in front of the
# person trying to work. The version this machine has is a build decision here;
# `make claude_code` is how it moves.
disable_autoupdate() {
    cat >/etc/profile.d/b2b-claude-code.sh <<'PROFEOF'
# Added by born2root setup/install/ai/install_claude_code.sh
#
# claude lives in /usr/local/bin and is owned by root: a user shell cannot
# replace it, so the auto-updater has nothing to do but fail loudly. Update
# with `make claude_code` from the host (or, in the VM, sudo the installer).
export DISABLE_AUTOUPDATER=1
PROFEOF
    chmod 644 /etc/profile.d/b2b-claude-code.sh
}

# ── Per-user setup ──────────────────────────────────────────────────────────
# Only the directory and its ownership. Nothing is written into it: the
# settings file is the user's, and a token is never put here (see the header).
prepare_users() {
    local user home group
    for user in $CLAUDE_CODE_USERS; do
        home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
        if [ -z "$home" ] || [ ! -d "$home" ]; then
            continue
        fi
        group=$(id -gn "$user" 2>/dev/null || echo "$user")
        mkdir -p "${home}/.claude"
        chown "${user}:${group}" "${home}/.claude" 2>/dev/null || true
        chmod 700 "${home}/.claude" 2>/dev/null || true
    done
}

# The one thing a new user of this VM cannot guess: it is installed but logged
# out, and the login flow works over plain SSH with no browser in the guest.
write_motd_hint() {
    [ -x "$CLAUDE_CODE_DEST" ] || return 0
    cat >/etc/update-motd.d/51-b2b-claude-code <<'MOTDEOF'
#!/bin/sh
# Added by born2root setup/install/ai/install_claude_code.sh
printf '  claude       Claude Code — first time: claude, then /login\n'
printf '               (it prints a URL; open it in a browser on the HOST)\n\n'
MOTDEOF
    chmod 755 /etc/update-motd.d/51-b2b-claude-code 2>/dev/null || true
}

log "=== Claude Code ==="
rc=0
install_claude_code || rc=1
disable_autoupdate
prepare_users
write_motd_hint
if [ ! -x "$CLAUDE_CODE_DEST" ]; then
    warn "claude was requested and is not installed"
    rc=1
fi
log "=== done (claude: $([ -x "$CLAUDE_CODE_DEST" ] && "$CLAUDE_CODE_DEST" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || echo none)) ==="
exit "$rc"
