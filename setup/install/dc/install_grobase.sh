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

# ── one local patch: observability binds loopback like everything else ──────
# At d74aa97 prometheus (9090), grafana (3030) and loki (3100) publish on
# 0.0.0.0 while every other service in grobase publishes on 127.0.0.1 (its
# own commit: "engine ports bind to loopback, like every other service").
# Behind QEMU's NAT that is invisible; on the tailnet it is Grafana for
# every peer. Docker's published ports also bypass UFW. So the three lines
# are rewritten after checkout, idempotently (a line already starting with
# 127.0.0.1 does not match), until upstream carries the fix and the ref
# moves. verify_platform.sh's "no container publishes a port off loopback"
# is what would catch a regression.
# Two spellings: a literal "9090:9090" and a defaulted "${LOKI_PORT:-3100}:3100".
sed -i -E 's/^(\s+- ")([0-9]+:[0-9]+")/\1127.0.0.1:\2/; s/^(\s+- ")(\$\{[A-Za-z_]+:-[0-9]+\}:[0-9]+")/\1127.0.0.1:\2/' \
    orchestrators/compose/base/observability.yml
n_open=$(grep -cE '^\s+- "([0-9]+|\$\{[A-Za-z_]+:-[0-9]+\}):[0-9]+"' orchestrators/compose/base/observability.yml || true)
[ "${n_open:-0}" = 0 ] || die "observability.yml still publishes $n_open port(s) off loopback after the patch"

# ── second local patch: the WAF must let REST verbs and uploads through ─────
# grobase ships infra/docker/services/waf/conf/crs-setup.conf widening the
# CRS allowed methods to PUT/PATCH/DELETE, and the image installs it as
# crs-setup-override.conf -- which setup.conf never includes. So the running
# WAF enforces the CRS default (GET HEAD POST OPTIONS) and refuses image/png
# bodies: every PostgREST update and every storage upload through 8443 got
# an HTML 403 with no CORS headers (a browser sees "status 0"). Found by the
# Laboratory bench on 2026-09-20. The CRS image honours these two variables
# (its 95-configure-rules.sh rewrites crs-setup.conf from them), so they go
# on the waf service, idempotently, until upstream includes its override.
GATEWAY_YML=orchestrators/compose/base/gateway.yml
if ! grep -q 'ALLOWED_METHODS' "$GATEWAY_YML"; then
    sed -i '/^    container_name: mini-baas-waf$/a\    environment:\n      ALLOWED_METHODS: "GET HEAD POST OPTIONS PUT PATCH DELETE"\n      ALLOWED_REQUEST_CONTENT_TYPE: "|application/x-www-form-urlencoded| |multipart/form-data| |multipart/related| |text/xml| |application/xml| |application/soap+xml| |application/json| |application/cloudevents+json| |application/cloudevents-batch+json| |application/grpc| |application/octet-stream| |image/png| |image/jpeg| |image/gif| |image/webp| |image/svg+xml| |text/plain| |text/csv| |application/pdf|"' "$GATEWAY_YML"
    log "waf: allowed methods widened to PUT/PATCH/DELETE, upload content types added"
fi
grep -q 'ALLOWED_METHODS: "GET HEAD POST OPTIONS PUT PATCH DELETE"' "$GATEWAY_YML" || die "gateway.yml: the WAF method patch did not land"

# ── extra CORS origins, from [dc] cors_origins in the profile ───────────────
# kong.yml renders one FRONTEND origin from .env at container start. A test
# lab or a teammate's frontend on another port needs its own list item, and
# the file comes back from the clone at every rebuild, so the list travels
# in build.conf (B2B_DC_CORS_ORIGINS, validated as bare origins) and is
# pasted after the FRONTEND placeholder here, one line each, idempotently.
# `make grobase_cors` on the host runs the same loop on a live VM.
KONG_YML=infra/docker/services/kong/conf/kong.yml
for origin in $(printf '%s' "$(sed -n 's/^B2B_DC_CORS_ORIGINS=//p' "$BUILD" | head -n1 | tr -d '"')"); do
    if ! grep -qF -- "- ${origin}" "$KONG_YML"; then
        # single-quoted program, origin spliced in: hellish drops `\(` in double quotes
        sed -i 's|^\(\s*\)- __KONG_CORS_ORIGIN_FRONTEND__$|&\n\1- '"${origin}"'|' "$KONG_YML"
        log "cors: allowed origin ${origin}"
    fi
done

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

# ── the realtime image that matches the clone ─────────────────────────────
# `make pull` gives the realtime service its versioned image
# (dlesieur/realtime-agnostic:0.2.1 in data-plane.yml), which predates
# presence and broadcast; ghcr also publishes one image per commit
# (grobase-realtime:sha-<commit>). The one tagged with GROBASE_REF is what
# the clone's source describes, so it replaces the versioned tag locally.
# Found by the Laboratory bench on 2026-09-20 (TRACK answered nothing).
rt_name=$(grep -m1 -E '^\s+image:\s+\S*realtime\S*' orchestrators/compose/base/data-plane.yml | awk '{print $2}')
rt_sha="ghcr.io/univers42/grobase-realtime:sha-$(git rev-parse HEAD)"
if [ -n "$rt_name" ] && docker pull -q "$rt_sha" >/dev/null 2>&1; then
    docker tag "$rt_sha" "$rt_name" && log "realtime: $rt_name is now the image built from $GROBASE_REF"
else
    log "realtime: no per-commit image for $GROBASE_REF on ghcr; keeping ${rt_name:-the pulled image}"
fi

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
    # `make certs` gave the server key to the WAF's group (chgrp
    # MINI_BAAS_WAF_TLS_GID, mode 640) so nginx, not root in that image, can
    # open it as a compose secret. The chown above took that away, and the
    # first server build's WAF restart-looped on "Permission denied" for
    # /run/secrets/localhost_key. Put the group back and restart it.
    waf_gid="${MINI_BAAS_WAF_TLS_GID:-101}"
    if [ -f "$GROBASE_DIR/certs/localhost-key.pem" ]; then
        chown "root:$waf_gid" "$GROBASE_DIR/certs/localhost-key.pem"
        chmod 640 "$GROBASE_DIR/certs/localhost-key.pem"
        docker restart mini-baas-waf >/dev/null 2>&1 || true
    fi
fi

log "grobase $GROBASE_PACKAGE is up: gateway on 127.0.0.1:8000 in the guest ($(docker ps --format '{{.Names}}' | grep -c '^mini-baas') containers)"
[ "$ready" = 1 ]
