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
#   [dc] package in born2root.toml pins it (B2B_DC_PACKAGE in build.conf);
#   max is reachable only that way. With "auto", the dc-* rows that are on
#   in /etc/b2b/features.conf pick the tier:
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
# 67279b7d = head of branch fix/laboratory-findings (what the Laboratory bench
# found, repaired in grobase itself: WAF methods + GraphQL exclusion, pg_graphql
# in the server image, migration 087, PostgREST graphql_public, SDK topic, the
# ghcr realtime image, and REALTIME_ALLOWED_ORIGINS at the WebSocket upgrade).
# It was 98eb2b74, four commits earlier, which predates the origin check
# grobase_cors_guest.sh writes -- the socket then took REALTIME_ALLOWED_ORIGINS
# and ignored it. Move to the merge commit once it lands on main.
GROBASE_REF="${GROBASE_REF:-67279b7d}"
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

# [dc] package in born2root.toml, through build.conf; "auto" (or an older
# build.conf without it) falls through to the feature mapping below.
if [ -z "${GROBASE_PACKAGE:-}" ] && [ -f "$BUILD" ]; then
    GROBASE_PACKAGE=$(sed -n 's/^B2B_DC_PACKAGE=//p' "$BUILD" | head -n1 | tr -d '"')
    [ "$GROBASE_PACKAGE" != auto ] || GROBASE_PACKAGE=""
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
# A pin that lives on a side branch is not in the clone at all: `git clone
# --depth` implies --single-branch, so the refspec only ever names the default
# branch and --unshallow just deepens that one. The 2026-09-21 build died here
# ("ref 98eb2b74 not found") although the commit was on the remote the whole
# time. Widen the refspec first, then deepen; the ref-name fetch is the last
# resort for a commit no branch reaches any more.
if ! git -C "$GROBASE_DIR" checkout -q "$GROBASE_REF" 2>/dev/null; then
    git -C "$GROBASE_DIR" remote set-branches origin '*' 2>/dev/null || true
    git -C "$GROBASE_DIR" fetch -q --unshallow origin 2>/dev/null ||
        git -C "$GROBASE_DIR" fetch -q origin 2>/dev/null || true
    git -C "$GROBASE_DIR" checkout -q "$GROBASE_REF" 2>/dev/null ||
        git -C "$GROBASE_DIR" fetch -q origin "$GROBASE_REF" 2>/dev/null || true
    git -C "$GROBASE_DIR" checkout -q "$GROBASE_REF" ||
        die "ref $GROBASE_REF not found in $GROBASE_REPO"
fi
cd "$GROBASE_DIR" || die "cannot enter $GROBASE_DIR"

# ── one local patch: every service but the door binds loopback ──────────────
# At d74aa97 prometheus (9090), grafana (3030) and loki (3100) publish on
# 0.0.0.0 while every other service in grobase publishes on 127.0.0.1 (its
# own commit: "engine ports bind to loopback, like every other service").
# Behind QEMU's NAT that is invisible; on the tailnet it is Grafana for
# every peer. Docker's published ports also bypass UFW. So those lines are
# rewritten after checkout, idempotently (a line already starting with
# 127.0.0.1 does not match), until upstream carries the fix and the ref
# moves. verify_platform.sh's "no container publishes a port off loopback"
# is what catches a regression -- and on 2026-09-21 it caught one this patch
# did not cover: lakehouse.yml gives iceberg-rest 0.0.0.0:8181. Patching the
# whole base/ directory instead of the one file is why the next such service
# needs no edit here; gateway.yml is the single exception, since the WAF
# (8880/8443) is deliberately the one door open off loopback.
# Two spellings: a literal "9090:9090" and a defaulted "${LOKI_PORT:-3100}:3100".
for yml in orchestrators/compose/base/*.yml; do
    [ "$(basename "$yml")" = gateway.yml ] && continue
    sed -i -E 's/^(\s+- ")([0-9]+:[0-9]+")/\1127.0.0.1:\2/; s/^(\s+- ")(\$\{[A-Za-z_]+:-[0-9]+\}:[0-9]+")/\1127.0.0.1:\2/' \
        "$yml"
    n_open=$(grep -cE '^\s+- "([0-9]+|\$\{[A-Za-z_]+:-[0-9]+\}):[0-9]+"' "$yml" || true)
    [ "${n_open:-0}" = 0 ] || die "$yml still publishes $n_open port(s) off loopback after the patch"
done

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
# One origin per line. Fed to `while read` through a heredoc rather than
# `for o in $(printf '%s' "$(sed ...)")`: hellish v3.1.3 splits that nested
# substitution as literal words, and `$(printf`, `'%s'` and `")` went into
# kong.yml as origins, so Kong refused its config and dc-gateway failed
# (2026-09-23). An empty list yields one empty line, hence the skip.
cors_origins() {
    sed -n 's/^B2B_DC_CORS_ORIGINS=//p' "$BUILD" | head -n1 | tr -d '"' | tr -s '[:blank:]' '\n' | grep .
}
KONG_YML=infra/docker/services/kong/conf/kong.yml
while IFS= read -r origin; do
    [ -n "$origin" ] || continue
    if ! grep -qF -- "- ${origin}" "$KONG_YML"; then
        # single-quoted program, origin spliced in: hellish drops `\(` in double quotes
        sed -i 's|^\(\s*\)- __KONG_CORS_ORIGIN_FRONTEND__$|&\n\1- '"${origin}"'|' "$KONG_YML"
        log "cors: allowed origin ${origin}"
    fi
done <<ORIGINS
$(cors_origins)
ORIGINS

# ── env, certs, images, up ──────────────────────────────────────────────────
# grobase's own steps. `make env` mints .env.secrets (mode 600) on first run
# and keeps it afterwards; `make certs` is idempotent.
make --no-print-directory env >/dev/null || die "make env failed"
make --no-print-directory certs >/dev/null || die "make certs failed"

# ── the same origins again, for the realtime socket ────────────────────────
# A WebSocket handshake is not a CORS request: no preflight, no
# Access-Control-Allow-Origin, nothing for Kong's list to act on. The socket
# therefore opened for any website that asked, with the public anon key, while
# every REST door refused it -- found by the Laboratory bench serving itself
# from an origin the gateway does not allow (2026-09-20). grobase's realtime
# reads REALTIME_ALLOWED_ORIGINS from .env and checks the Origin header only
# when it is non-empty; a handshake without an Origin (a server-side client)
# is always allowed. Written after `make env` because that is what creates
# .env, and before `up` so the first container already has it.
rt_origins=$(sed -n 's/^KONG_CORS_ORIGIN_[A-Z]*=//p' .env | grep . | tr '\n' ',')
while IFS= read -r origin; do
    [ -n "$origin" ] || continue
    case ",${rt_origins}" in
    *",${origin},"*) ;;
    *) rt_origins="${rt_origins}${origin}," ;;
    esac
done <<ORIGINS
$(cors_origins)
ORIGINS
rt_origins=${rt_origins%,}
if grep -q '^REALTIME_ALLOWED_ORIGINS=' .env; then
    sed -i 's|^REALTIME_ALLOWED_ORIGINS=.*|REALTIME_ALLOWED_ORIGINS='"${rt_origins}"'|' .env
else
    printf 'REALTIME_ALLOWED_ORIGINS=%s\n' "$rt_origins" >>.env
fi
log "realtime: sockets allowed from ${rt_origins}"

# ── trino's catalog.management, which nothing else sets ────────────────────
# grobase's infra/docker/services/trino/conf/config.properties has
# `catalog.management=${ENV:CATALOG_MANAGEMENT}`, but the trino service in
# orchestrators/compose/base/lakehouse.yml sets only MYSQL_* and MINIO_*, and
# `make env` never writes CATALOG_MANAGEMENT. Trino refuses to boot on a
# config placeholder it cannot resolve -- "Configuration is invalid ...
# Environment variable is not set: CATALOG_MANAGEMENT" -- so on the first max
# build (2026-09-24) mini-baas-trino was Restarting (100) while every other
# engine was healthy. The tier only ever mounts static catalog files
# (postgresql, mongodb, mysql, iceberg), so `static` is the value that matches
# what is on disk; `dynamic` would expose a catalog REST API nothing calls.
# Written here, beside REALTIME_ALLOWED_ORIGINS, for the same reason: after
# `make env` creates .env, before `up` reads it.
if grep -q '^CATALOG_MANAGEMENT=' .env; then
    sed -i 's|^CATALOG_MANAGEMENT=.*|CATALOG_MANAGEMENT=static|' .env
else
    printf 'CATALOG_MANAGEMENT=%s\n' static >>.env
fi
log "trino: catalog.management=static"

# ── healthchecks that cannot run: CMD-SHELL in a shell-less image ───────────
# grobase gives prometheus and loki `test: ["CMD-SHELL", "wget -qO- …"]`.
# CMD-SHELL means `/bin/sh -c`, and both images are distroless: the probe died
# with `exec: "/bin/sh": stat /bin/sh: no such file or directory` on every
# interval, so the two were permanently (unhealthy) while answering 200 on the
# very URLs the probe names (measured 2026-09-24, first max build).
#
# Both ship /bin/busybox. Going through `busybox sh -c` fixes the shell but not
# the command: busybox only answers to an applet name when it is argv[0] (a
# symlink) or the first argument, so that intermediate form still failed with
# `sh: wget: not found`. The exec form below names the applet directly, which
# needs no shell at all, and -O /dev/null keeps the body out of the health log
# while wget's exit status still carries the verdict.
#
# Matched by the endpoint rather than the service name because these two
# healthchecks appear in several compose files (base/observability.yml and the
# monolith); the other CMD-SHELL probes in the tree are in images that do have
# a shell and are deliberately left alone. Idempotent by the busybox+wget
# guard, which also upgrades a half-patched tree left by an earlier run.
#
# The same pass gives promtail and dynamodb-local the healthcheck grobase never
# wrote for them. Without one `docker ps` reports no health at all, so "every
# container healthy" could not be asserted for the tier: 33 of 35 was the
# ceiling. Both images do carry a probe tool (promtail wget, dynamodb-local
# curl, checked in the guest). dynamodb-local answers a bare GET with 400 --
# it wants a signed POST -- so curl runs WITHOUT -f: connecting is the health
# signal, the status code is not, and a dead port still exits 7.
python3 - "$@" <<'HEALTHEOF' || log "healthcheck patch skipped (python3 refused it)"
import glob
import re

URL = re.compile(r'https?://localhost:(?:9090/-/healthy|3100/ready)[^"\s]*')
DONE = '"/bin/busybox", "wget"'
NAME = re.compile(r"^(\s*)container_name:\s*(\S+)\s*$")
PROBES = {
    "mini-baas-promtail": '"CMD", "/usr/bin/wget", "-q", "-O", "/dev/null", "http://localhost:9080/ready"',
    "mini-baas-dynamodb-local": '"CMD", "/usr/bin/curl", "-s", "-o", "/dev/null", "http://localhost:8000/"',
}


def block_start(lines, i, indent):
    """First line of the service block holding line i."""
    for j in range(i, -1, -1):
        ln = lines[j]
        if ln.strip() and (len(ln) - len(ln.lstrip())) < len(indent):
            return j + 1
    return 0


def has_hc(lines, i, indent):
    """A healthcheck: key already in this service block, wherever in it.

    Scanned over the whole block, not just the next line: grobase writes the
    healthcheck BEFORE container_name as often as after, and a second
    healthcheck: key would not error -- YAML keeps the last one silently.
    """
    for j in range(i, len(lines)):
        ln = lines[j]
        if not ln.strip():
            continue
        cur = len(ln) - len(ln.lstrip())
        if j != i and cur < len(indent):
            return False
        if ln.strip() == "healthcheck:" and cur == len(indent):
            return True
    return False


fixed = added = 0
for path in glob.glob("orchestrators/compose/**/*.yml", recursive=True):
    with open(path) as fh:
        lines = fh.read().split("\n")
    out, n, skip = [], 0, False
    for i, line in enumerate(lines):
        if skip:
            skip = False
            continue
        nxt = lines[i + 1] if i + 1 < len(lines) else ""
        found = URL.search(nxt)
        if found and '"CMD' in line and DONE not in line:
            indent = line[: len(line) - len(line.lstrip())]
            out.append('%s"CMD", "/bin/busybox", "wget", "-q", "-O", "/dev/null",' % indent)
            out.append('%s"%s",' % (indent, found.group(0)))
            n, skip = n + 1, True
            fixed += 1
            continue
        out.append(line)
        named = NAME.match(line)
        if not named:
            continue
        indent, name = named.group(1), named.group(2)
        probe = PROBES.get(name)
        if probe is None or has_hc(lines, block_start(lines, i, indent), indent):
            continue
        out += [
            "%shealthcheck:" % indent,
            "%s  test: [%s]" % (indent, probe),
            "%s  interval: 15s" % indent,
            "%s  timeout: 5s" % indent,
            "%s  start_period: 20s" % indent,
            "%s  retries: 5" % indent,
        ]
        n += 1
        added += 1
    if n:
        with open(path, "w") as fh:
            fh.write("\n".join(out))
print(
    "healthcheck: %d shell-less probe(s) rewritten, %d missing probe(s) added"
    % (fixed, added)
)
HEALTHEOF

# ── the gateway port that would not sit still ───────────────────────────────
# grobase's `up` recipe (orchestrators/makes/20-stack.mk) runs
#   eval "$(bash scripts/ops/resolve-ports.sh)"; docker compose up -d
# and that resolver calls a port busy when anything at all is LISTENING on it
# (ss -tlnH), with no exception for the stack's own containers. So the second
# `up` finds kong holding 8000, declares 8000 taken, exports
# KONG_HTTP_PORT=8001 -- which is KONG_ADMIN_PORT's own default -- and compose
# recreates kong there; the next `up` finds 8001 taken and moves it back.
# Measured 2026-09-24: up #1 -> 8000, up #2 -> 8001, and verify_platform's
# "the gateway answers on 127.0.0.1:8000" failed on exactly the even runs,
# while `make grobase` reruns silently moved the door the WAF proxies to.
#
# The fix is one exception: a host port already published by a mini-baas
# container is not a conflict, it is this stack's port being rebound to the
# same container. Patched rather than worked around because every consumer --
# the WAF, the host forwards, verify_platform -- assumes a stable 8000.
python3 - "$@" <<'PORTEOF' || log "port-resolver patch skipped (python3 refused it)"
path = "scripts/ops/resolve-ports.sh"
try:
    with open(path) as fh:
        src = fh.read()
except OSError:
    raise SystemExit(0)
if "_own_ports" in src:
    print("port resolver: already patched")
    raise SystemExit(0)
anchor = '_used_ports="" # track ports we\'ve already claimed in this run'
probe = "port_in_use() {\n  local p=$1"
if anchor not in src or probe not in src:
    print("port resolver: shape changed upstream, left alone")
    raise SystemExit(0)
src = src.replace(
    anchor,
    anchor
    + "\n# Host ports THIS stack already publishes are not a conflict: they are the\n"
    + "# ports the imminent `up` is about to rebind to the same containers.\n"
    + "_own_ports=$(docker ps --filter name=mini-baas --format '{{.Ports}}' 2>/dev/null \\\n"
    + "  | grep -oE '(127\\.0\\.0\\.1|0\\.0\\.0\\.0):[0-9]+' | cut -d: -f2 | sort -u | tr '\\n' ' ')",
    1,
)
src = src.replace(
    probe,
    probe
    + "\n  # Ours already: rebinding our own published port is not a conflict.\n"
    + '  if [[ " $_own_ports " == *" $p "* ]]; then\n    return 1\n  fi',
    1,
)
with open(path, "w") as fh:
    fh.write(src)
print("port resolver: own published ports no longer count as conflicts")
PORTEOF

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

# ── images the tree changed but ghcr has not built yet ──────────────────────
# `make pull` brings CI's images for main; until the fix branch merges (and
# CI builds it) the postgres image lacks pg_graphql and the waf image lacks
# the GraphQL exclusion, so each is built here FROM THE TREE, in Docker,
# only when the pulled one lacks the artefact. Nothing is installed on the
# VM. The postgres build compiles pg_graphql with pgrx: ~15 min on 8 vCPU.
pg_img=$(grep -m1 -E '^\s+image:\s+\S*grobase-postgres' orchestrators/compose/base/data-engines.yml | awk '{print $2}')
if [ -n "$pg_img" ] && ! docker run --rm --entrypoint sh "$pg_img" -c 'test -f /usr/local/share/postgresql/extension/pg_graphql.control' >/dev/null 2>&1; then
    log "postgres: building $pg_img from the tree (pg_graphql)"
    docker build -q -t "$pg_img" infra/docker/services/postgres >/dev/null || die "postgres image build failed"
fi
waf_img=$(grep -m1 -E '^\s+image:\s+\S*grobase-waf' orchestrators/compose/base/gateway.yml | awk '{print $2}')
if [ -n "$waf_img" ] && ! docker run --rm --entrypoint sh "$waf_img" -c 'test -s /etc/modsecurity.d/owasp-crs/rules/REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf' >/dev/null 2>&1; then
    log "waf: building $waf_img from the tree (GraphQL exclusion, allowed methods)"
    docker build -q -t "$waf_img" infra/docker/services/waf >/dev/null || die "waf image build failed"
fi
# The same, for realtime, when ghcr has no per-commit image (the tag step
# above says so). :latest is built from grobase's default branch and predates
# both socket fixes on this ref: it ignores the REALTIME_ALLOWED_ORIGINS this
# script writes, and it drops a closing socket instead of answering its Close
# frame. The Laboratory bench fails exactly two probes on that image
# (stranger.socket opens from the hostile origin, realtime.goodbye sees 1006)
# -- which is how this was found on 2026-09-21. The runtime stage is
# distroless, so the check copies the binary out instead of running a shell
# in it. A Rust workspace release build: ~15 min on 8 vCPU.
rt_img=${rt_name:-}
if [ -n "$rt_img" ]; then
    rt_cid=$(docker create "$rt_img" 2>/dev/null || true)
    rt_knows=1
    if [ -n "$rt_cid" ]; then
        docker cp "$rt_cid:/app/realtime-server" - 2>/dev/null |
            grep -qa REALTIME_ALLOWED_ORIGINS || rt_knows=0
        docker rm -f "$rt_cid" >/dev/null 2>&1 || true
    fi
    if [ "$rt_knows" = 0 ]; then
        log "realtime: building $rt_img from the tree (origin check, clean close)"
        docker build -q -t "$rt_img" \
            infra/docker/services/realtime/realtime-agnostic >/dev/null ||
            die "realtime image build failed"
    fi
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

# ── the settle pass: what asked for a dependency once and never asked again ──
# Several grobase services resolve a dependency exactly at startup and keep the
# failure for the life of the process, so bringing 35 containers up at once
# leaves casualties that nothing retries. Measured on the first max build
# (2026-09-24), all three with healthy dependencies by the time anyone looked:
#
#   mongo-init   exited 1 on ECONNREFUSED -- mongo's healthcheck went green
#                before it accepted connections. restart: "no", so rs0 was
#                never initiated and ai-service, analytics-service and
#                mongo-api restart-looped on MongoServerSelectionError.
#   realtime     "PostgreSQL connect failed" 32 ms after listening, then
#                "producer stream ended" when mongo stepped down under it.
#                /v1/health then answers 503 degraded with both producers
#                detached, for ever, while psql and a replication connection
#                on its OWN url both succeed.
#
# Re-running the one-shot and restarting what is still unhealthy is the whole
# fix: the dependencies are up by now, and these services are correct on a
# second attempt. Ordered -- the init first, since the restarts depend on it.
# Idempotent and cheap on a guest that does not need it: an initiated replica
# set makes mongo-init exit 0, and a healthy container is never restarted.
if docker ps -a --format '{{.Names}}' | grep -qx mini-baas-mongo-init; then
    if [ "$(docker inspect -f '{{.State.ExitCode}}' mini-baas-mongo-init 2>/dev/null)" != 0 ]; then
        log "settle: re-running mongo-init (it lost the race with mongo)"
        docker start -a mini-baas-mongo-init 2>&1 | sed 's/^/  [mongo-init] /' || true
    fi
fi
settled=0
for _ in 1 2 3; do
    sick=$(docker ps --filter name=mini-baas --filter health=unhealthy --format '{{.Names}}')
    [ -n "$sick" ] || {
        settled=1
        break
    }
    log "settle: restarting $(printf '%s' "$sick" | tr '\n' ' ')"
    # shellcheck disable=SC2086 # one name per line, none of them can contain a space
    docker restart $sick >/dev/null 2>&1 || true
    sleep 45
done
[ "$settled" = 1 ] || log "still unhealthy after the settle pass: $(docker ps --filter name=mini-baas --filter health=unhealthy --format '{{.Names}}' | tr '\n' ' ')(make grobase_status)"

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

# A first boot that filed dc-gateway as failed leaves that line in
# /etc/b2b/features.status, and verify_platform (hard check) reads it, so a
# later `make grobase` that succeeds has to retract it -- and the twelve rows
# first-boot-setup.sh copies dc-gateway's verdict onto with it, or the guest
# claims grobase is up and its databases are not. Same helper as
# install_claude_code.sh's mark_feature_ok; the reasoning is there. It flips
# nothing at first boot, where feature_end writes the line after this returns.
mark_feature_ok() {
    local feature="$1" status="${B2B_FEATURES_STATUS:-/etc/b2b/features.status}" tmp
    [ -f "$status" ] || return 0
    grep -qE "^${feature} (failed|no-space) " "$status" 2>/dev/null || return 0
    tmp="${status}.$$"
    if awk -v f="$feature" '$1 == f && ($2 == "failed" || $2 == "no-space") { $2 = "ok" } { print }' \
        "$status" >"$tmp" 2>/dev/null; then
        cat "$tmp" >"$status" && rm -f "$tmp"
        log "marked '${feature}' ok in ${status} (first boot had filed it as failed)"
    else
        rm -f "$tmp"
    fi
}

if [ "$ready" = 1 ]; then
    for f in dc-gateway dc-identity dc-realtime dc-secrets dc-db-postgres dc-db-mysql \
        dc-db-mongo dc-db-redis dc-db-cockroach dc-db-mssql dc-objectstore \
        dc-storage dc-observability; do
        mark_feature_ok "$f"
    done
fi
[ "$ready" = 1 ]
