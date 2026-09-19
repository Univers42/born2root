#!/usr/bin/env hellish
#
# install_grobase.sh — grobase, the BaaS this guest exists to serve.
#
# THE BOUNDARY
#   born2root builds a capable machine; grobase says what runs on it. This
#   script installs MACHINE concerns (a clone at a pinned ref, the env and
#   certs grobase mints for itself, ownership) and then hands over to
#   grobase's own Makefile: `make pull`, `make up PACKAGE=…`, `make health`.
#   It never names an engine version. Bumping Postgres is a grobase commit;
#   nothing here changes and no ISO is rebuilt.
#
# WHICH TIER
#   grobase ships product tiers (basic, essential, pro, max -- measured RAM
#   shapes, see its orchestrators/makes/00-config.mk) and add-on planes.
#   The dc-* rows that are on in /etc/b2b/features.conf pick the tier:
#     any of dc-db-{mysql,mongo,redis,cockroach} / dc-realtime / dc-storage
#     / dc-objectstore              → pro
#     dc-identity or dc-db-postgres → essential
#     dc-gateway alone              → basic
#   and add-ons: dc-observability → observability, dc-db-mssql → engines.
#   The mapping is coarse on purpose: grobase's unit is the tier, not the
#   engine, and a fake per-engine switch here would only diverge from it.
#
# WHAT IS NEVER STARTED
#   studio and playground are compose PROFILES in grobase (studio.yml,
#   playground.yml), off unless asked for by name; so are the tenant apps
#   (gourmand, hypertube, surfind, vault42 …). A tier never enables them.
#   That is the backend-only split: the frontends live on the host or on a
#   collaborator's laptop and talk to the gateway.
#
# WHERE IT LANDS
#   The clone in /opt/grobase (~170 MB); every image in /var/lib/docker,
#   which is what the dc-* rows in generate/feature_profile.sh price, and
#   the reservation dc-data is for what the engines will hold.
#
# WHY PULL, NOT BUILD
#   Every service in grobase's compose carries both a build context and an
#   `image: ghcr.io/univers42/grobase-<svc>:latest # pull-fallback`, and the
#   packages are public. `make pull` fetches them; building a Rust data plane
#   and thirty other images inside a first boot would take an hour and fill
#   /var with a build cache the fit check never priced.
#
# FAILURE
#   dc-* features are opt-in, not base: a failed pull (network) files the
#   feature as failed in features.status and returns non-zero, but does not
#   raise B2B-FEATURE-FAILED -- the machine is still a good machine, and
#   `make grobase` from the host retries this script over SSH.
#
# USAGE
#   sudo ./install_grobase.sh
#   sudo GROBASE_PACKAGE=essential ./install_grobase.sh
#   sudo GROBASE_REF=<sha> GROBASE_REPO=<url> ./install_grobase.sh
set -u

FEAT=/etc/b2b/features.conf
BUILD=/etc/b2b/build.conf
GROBASE_REPO="${GROBASE_REPO:-https://github.com/Univers42/grobase.git}"
GROBASE_REF="${GROBASE_REF:-d74aa97}"
GROBASE_DIR="${GROBASE_DIR:-/opt/grobase}"
CONF=/etc/b2b/grobase.conf

log() { printf '[grobase] %s\n' "$*"; }
die() {
    printf '[grobase] ERROR: %s\n' "$*" >&2
    exit 1
}
[ "$(id -u)" = 0 ] || die "run as root"
on() { grep -qx "B2B_FEATURE_$(printf '%s' "$1" | tr '-' '_')=on" "$FEAT" 2>/dev/null; }

# The login, for ownership of the clone: `make up` / `make down` from that
# account afterwards, without sudo, because it is in the docker group.
LOGIN="${GROBASE_USER:-}"
if [ -z "$LOGIN" ] && [ -f "$BUILD" ]; then
    LOGIN=$(sed -n 's/^B2B_LOGIN=//p' "$BUILD" | head -n1 | tr -d '"')
fi

if [ -z "${GROBASE_PACKAGE:-}" ]; then
    if on dc-db-mysql || on dc-db-mongo || on dc-db-redis || on dc-db-cockroach ||
        on dc-realtime || on dc-storage || on dc-objectstore; then
        GROBASE_PACKAGE=pro
    elif on dc-identity || on dc-db-postgres; then
        GROBASE_PACKAGE=essential
    else
        GROBASE_PACKAGE=basic
    fi
fi
if [ -z "${GROBASE_ADDONS+x}" ]; then
    GROBASE_ADDONS=""
    on dc-observability && GROBASE_ADDONS="${GROBASE_ADDONS}${GROBASE_ADDONS:+ }observability"
    on dc-db-mssql && GROBASE_ADDONS="${GROBASE_ADDONS}${GROBASE_ADDONS:+ }engines"
fi
log "tier: $GROBASE_PACKAGE${GROBASE_ADDONS:+ + $GROBASE_ADDONS}  ref: $GROBASE_REF"

command -v docker >/dev/null 2>&1 || die "docker is not installed (the docker feature is required)"
docker compose version >/dev/null 2>&1 || die "docker compose v2 is not available"
export DEBIAN_FRONTEND=noninteractive
for t in git make openssl curl; do
    command -v "$t" >/dev/null 2>&1 || apt-get install -y -qq "$t" || die "apt could not install $t"
done

# Room for the images. Rough floors per tier; the fit check on the host
# already modelled this from the dc-* rows, so tripping here means the
# model was wrong, and the message says how much was there.
need_mb=3000
case "$GROBASE_PACKAGE" in pro) need_mb=6000 ;; max) need_mb=9000 ;; esac
avail=$(df -k /var 2>/dev/null | awk 'NR == 2 { printf "%d", $4 / 1024 }')
[ "${avail:-0}" -ge "$need_mb" ] || die "/var has ${avail:-?} MB free, the $GROBASE_PACKAGE tier wants $need_mb MB before pulling"

# ── the clone, at the pinned ref ────────────────────────────────────────────
if [ -d "$GROBASE_DIR/.git" ]; then
    log "fetching $GROBASE_DIR"
    git -C "$GROBASE_DIR" fetch -q --depth 100 origin || log "fetch failed, using what is there"
else
    log "cloning $GROBASE_REPO"
    git clone -q --depth 100 "$GROBASE_REPO" "$GROBASE_DIR" || die "clone failed"
fi
if ! git -C "$GROBASE_DIR" checkout -q "$GROBASE_REF" 2>/dev/null; then
    git -C "$GROBASE_DIR" fetch -q --unshallow origin 2>/dev/null || true
    git -C "$GROBASE_DIR" checkout -q "$GROBASE_REF" || die "ref $GROBASE_REF not found in $GROBASE_REPO"
fi
cd "$GROBASE_DIR" || die "cannot enter $GROBASE_DIR"

# ── env, certs, images, up ──────────────────────────────────────────────────
# grobase's own steps. `make env` mints .env.secrets (mode 600) on first run
# and keeps it afterwards; `make certs` is idempotent.
make --no-print-directory env >/dev/null || die "make env failed"
make --no-print-directory certs >/dev/null || die "make certs failed"

pull_ok=0
for attempt in 1 2 3; do
    if make --no-print-directory pull PACKAGE="$GROBASE_PACKAGE" ADDONS="$GROBASE_ADDONS"; then
        pull_ok=1
        break
    fi
    log "pull attempt $attempt failed; retrying in 20 s"
    sleep 20
done
[ "$pull_ok" = 1 ] || die "images could not be pulled from ghcr.io (network?) -- make grobase, from the host, retries"

make --no-print-directory up PACKAGE="$GROBASE_PACKAGE" ADDONS="$GROBASE_ADDONS" || die "make up failed"

# Readiness is the gateway answering, not `up` returning: Kong starts before
# the services behind it. The health target probes 127.0.0.1:8000.
ready=0
for _ in $(seq 1 60); do
    if make --no-print-directory health >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 5
done
[ "$ready" = 1 ] || log "gateway not healthy after 5 minutes; services may still be starting (make grobase_status)"

# What this guest runs, for verify_platform and for `make grobase` reruns.
{
    printf 'GROBASE_DIR=%s\n' "$GROBASE_DIR"
    printf 'GROBASE_REF=%s\n' "$GROBASE_REF"
    printf 'GROBASE_PACKAGE=%s\n' "$GROBASE_PACKAGE"
    printf 'GROBASE_ADDONS=%s\n' "$GROBASE_ADDONS"
} >"$CONF"
chmod 644 "$CONF"

if [ -n "$LOGIN" ] && id "$LOGIN" >/dev/null 2>&1; then
    chown -R "$LOGIN:$LOGIN" "$GROBASE_DIR"
    chmod 600 "$GROBASE_DIR/.env" "$GROBASE_DIR/.env.secrets" 2>/dev/null || true
fi

log "grobase $GROBASE_PACKAGE is up: gateway on 127.0.0.1:8000 in the guest ($(docker ps --format '{{.Names}}' | grep -c '^mini-baas') containers)"
[ "$ready" = 1 ]
