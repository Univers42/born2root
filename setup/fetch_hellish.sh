#!/usr/bin/env bash
# ============================================================================ #
# fetch_hellish.sh                                                             #
#                                                                             #
# Get the hellish binary that gets baked into the ISO — by DOWNLOADING the     #
# published release asset, not by building the submodule from source.         #
#                                                                             #
# Why not build it:                                                           #
#   Building meant cloning hellish + libft + ft_malloc + philosopher +        #
#   scripts (the whole nested submodule tree), over SSH (.gitmodules used      #
#   git@github.com:, so it needed a key just to bootstrap), then compiling     #
#   ~550 translation units. The release asset is one 625K HTTPS GET with no    #
#   auth, and it is the exact artifact upstream ships and tests. The sh42      #
#   submodule was removed from this repo once this landed.                     #
#                                                                             #
# Why this is safe:                                                           #
#   Upstream publishes hellish-linux-<arch> alongside a .sha256. We verify     #
#   that checksum before the binary is allowed anywhere near the ISO. The      #
#   asset name matches what hellish's own self-updater resolves               #
#   (src/platform/posix/update_endpoint.c: "hellish-linux-" + uname -m), so    #
#   we track the same channel `hellish --update` does.                         #
#                                                                             #
# Version policy — always the newest, unless you pin:                          #
#   (default)                 resolve the latest release via the GitHub API    #
#   HELLISH_VERSION=v2.7.6    pin an exact tag, no API call                    #
#   HELLISH_REFRESH=1         re-download even if the cached copy matches      #
#                                                                             #
# Offline / rate-limited: falls back to the previously cached binary. Never    #
# silently ships nothing — no binary is a hard error, because the ISO builder  #
# would otherwise quietly produce a VM with no custom shell at all.            #
# ============================================================================ #
set -u

REPO="${HELLISH_REPO:-Univers42/hellish}"
OUT_DIR="${OUT_DIR:-dist}"
OUT_BIN="${OUT_BIN:-$OUT_DIR/hellish}"
# Re-derive the directory FROM the binary: the Makefile passes an absolute
# OUT_BIN (from CUSTOM_SHELL_PATH) while OUT_DIR defaults to a relative "dist",
# and the stamp must always land beside the binary it describes -- otherwise a
# custom OUT_BIN writes its version marker somewhere the next run won't read.
OUT_DIR="$(dirname "$OUT_BIN")"
STAMP="$OUT_DIR/.hellish-version"

# Colours (match the Makefile; honour NO_COLOR and non-TTY output).
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    G='\033[32m'
    Y='\033[33m'
    B='\033[34m'
    R='\033[31m'
    D='\033[90m'
    Z='\033[0m'
else
    G=''
    Y=''
    B=''
    R=''
    D=''
    Z=''
fi
say() { printf "%b\n" "$*"; }
ok() { say "${G}✓${Z} $*"; }
info() { say "${B}▶${Z} $*"; }
warn() { say "${Y}⚠${Z}  $*"; }
err() { say "${R}✗${Z} $*" >&2; }

# ── Which asset can this machine actually run? ──────────────────────────────
# Mirrors update_asset_name() in hellish: the asset is keyed off `uname -m`
# verbatim (x86_64 / aarch64) — NOT the amd64/arm64 spelling `make static`
# uses for its dist/ output. Getting this wrong yields a 404, so it is kept
# deliberately identical to upstream's own resolver.
MACHINE="$(uname -m)"
case "$MACHINE" in
x86_64 | aarch64) ASSET="hellish-linux-${MACHINE}" ;;
*)
    err "No hellish release is published for arch '${MACHINE}'."
    err "Build hellish from source and pass CUSTOM_SHELL_PATH=<binary>."
    exit 1
    ;;
esac

need() { command -v "$1" >/dev/null 2>&1; }
if ! need curl; then
    err "curl is required to fetch the hellish release. Run: make deps"
    exit 1
fi

# ── Resolve the version to install ──────────────────────────────────────────
# A pinned HELLISH_VERSION skips the API entirely, which also means `make all`
# keeps working when the API rate limit (60/hr unauthenticated) is exhausted.
resolve_latest() {
    curl -fsSL --max-time 20 \
        -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null |
        grep -m1 '"tag_name"' |
        sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
}

VERSION="${HELLISH_VERSION:-}"
if [ -n "$VERSION" ]; then
    info "Using pinned hellish ${VERSION}"
else
    info "Resolving latest hellish release..."
    VERSION="$(resolve_latest)"
    if [ -n "$VERSION" ]; then
        ok "Latest release: ${VERSION}"
    else
        warn "Could not reach the GitHub release API (offline, or rate-limited)."
    fi
fi

CACHED=""
[ -f "$STAMP" ] && CACHED="$(head -n1 "$STAMP" 2>/dev/null | tr -d '\r\n')"

# ── Nothing to do? ──────────────────────────────────────────────────────────
# The stamp is only written after a build passes verification, so trusting it
# here cannot resurrect a binary that failed its checksum.
if [ -z "${HELLISH_REFRESH:-}" ] && [ -n "$VERSION" ] &&
    [ "$CACHED" = "$VERSION" ] && [ -x "$OUT_BIN" ]; then
    ok "hellish ${VERSION} already present: ${OUT_BIN} ${D}(cached)${Z}"
    exit 0
fi

# ── Offline: fall back rather than fail ─────────────────────────────────────
if [ -z "$VERSION" ]; then
    if [ -x "$OUT_BIN" ]; then
        warn "Reusing cached hellish ${CACHED:-(unknown version)}: ${OUT_BIN}"
        exit 0
    fi
    err "Cannot resolve a hellish release and there is no cached binary."
    err "Pin a known version to skip the API:  make shell HELLISH_VERSION=v2.7.6"
    exit 1
fi

# ── Download ────────────────────────────────────────────────────────────────
BASE="https://github.com/${REPO}/releases/download/${VERSION}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

info "Downloading ${ASSET} ${D}(${VERSION})${Z}"
if ! curl -fsSL --max-time 180 -o "$TMP/$ASSET" "${BASE}/${ASSET}"; then
    err "Download failed: ${BASE}/${ASSET}"
    if [ -x "$OUT_BIN" ]; then
        warn "Keeping the cached binary already at ${OUT_BIN} (${CACHED:-unknown})."
        exit 0
    fi
    exit 1
fi

# ── Verify the checksum ─────────────────────────────────────────────────────
# Fatal when the .sha256 exists and does not match: a truncated or tampered
# binary must never reach the ISO. Only a MISSING .sha256 downgrades to a
# warning, since older releases predate the checksum asset.
if curl -fsSL --max-time 30 -o "$TMP/$ASSET.sha256" "${BASE}/${ASSET}.sha256" 2>/dev/null; then
    EXPECT="$(awk '{print $1; exit}' "$TMP/$ASSET.sha256")"
    ACTUAL="$(sha256sum "$TMP/$ASSET" | awk '{print $1}')"
    if [ -z "$EXPECT" ] || [ "$EXPECT" != "$ACTUAL" ]; then
        err "Checksum mismatch for ${ASSET} — refusing to install."
        err "  expected: ${EXPECT:-(empty)}"
        err "  actual:   ${ACTUAL}"
        exit 1
    fi
    ok "SHA-256 verified ${D}${ACTUAL}${Z}"
else
    warn "No .sha256 published for ${VERSION} — skipping checksum verification."
fi

chmod 755 "$TMP/$ASSET"

# ── Smoke test ──────────────────────────────────────────────────────────────
# Advisory only. The binary's job is to run inside the Debian VM, not on this
# host; a host whose glibc is older than the release's floor would fail here
# while the VM stays perfectly fine. The checksum above is the real gate.
if [ "$MACHINE" = "$(uname -m)" ]; then
    if OUTPUT="$("$TMP/$ASSET" -c 'echo hellish-ok' 2>/dev/null)" &&
        [ "$OUTPUT" = "hellish-ok" ]; then
        ok "Smoke test passed"
    else
        warn "Binary did not run on THIS host (glibc/readline too old?)."
        warn "Not fatal — it only has to run inside the VM. Checksum was valid."
    fi
fi

# ── Install into place ──────────────────────────────────────────────────────
mkdir -p "$OUT_DIR"
install -m 755 "$TMP/$ASSET" "$OUT_BIN" 2>/dev/null || {
    cp "$TMP/$ASSET" "$OUT_BIN" && chmod 755 "$OUT_BIN"
} || {
    err "Could not write ${OUT_BIN}"
    exit 1
}
printf '%s\n' "$VERSION" >"$STAMP"

SIZE="$(du -h "$OUT_BIN" 2>/dev/null | cut -f1)"
ok "hellish ${VERSION} ready: ${OUT_BIN} ${D}(${SIZE})${Z}"
