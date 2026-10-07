#!/usr/bin/env hellish
#
# install_graph_render.sh — graph_render's motor (graph-server and its embed
# bundle, image dlesieur/graph_render) as one container on the guest's
# loopback (dc-graph-render). Image, group and key file; never a key.
#
# WHY IT CAN BE IDLE
#   The server refuses to start without a key line (exit 2, graph_render
#   docs/contract/service-api.md), and a key is a secret the ISO never
#   carries. First boot pulls the image and leaves an empty key file; `make
#   graph_render_key` on the host mints a key with this same image, keeps it
#   in the secrets file and sends its `<name> <sha256>` line back here as
#   GRAPH_RENDER_KEY_LINE, which is when the container starts. Installed but
#   idle is a fresh guest's correct state, as for install_edge.sh.
#
# WHY THE DIRECTORY IS MOUNTED, NOT THE FILE
#   A key is added by rewriting the file and sending SIGHUP (the server
#   re-reads it and swaps the whole set). A single-file bind mount pins the
#   inode it started with, so a rewrite that replaces the file -- an editor,
#   sed -i, install -- would never reach the running server. A directory
#   mount follows the name. The server refuses a key file that is not 0640
#   or stricter, and reads it as uid 10001 through the file's group, hence
#   the graph-render group and --group-add.
#
# WHY 8g, AND THE MEMORY CHECK
#   The server sizes its worker slots from the container's memory cap, and
#   one slot is 4.32 GiB (PER_SLOT_BYTES in graph-server's slots.rs): 4g
#   holds none and the server refuses to start, 8g holds one. The cap is a
#   ceiling, not a reservation, so a guest without a slot's worth to give
#   would start it anyway and lose the first large render to the OOM killer.
#   On 2026-10-07 the datacenter guest had 2238 MB left beside grobase, which
#   is why profiles/server.toml sets vm.ram_mb = 14336; below one slot of
#   MemAvailable the start is refused and says so.
#   Caveat: MemAvailable is read once, before the start. A stack that grows
#   afterwards can still take the slot's memory back; the container is then
#   killed mid-render and restarted, which b2b-stack-health reports.
#
# USAGE
#   sudo ./install_graph_render.sh            pull; start or reload if a key exists
#   sudo GRAPH_RENDER_KEY_LINE='ops <sha256>' ./install_graph_render.sh
#   GRAPH_RENDER_IMAGE= GRAPH_RENDER_PORT= (8095) GRAPH_RENDER_MEM= (8g)
#   GRAPH_RENDER_DIR= and GRAPH_RENDER_MEMINFO= exist for tests/test_graph_render.sh
set -u

IMAGE="${GRAPH_RENDER_IMAGE:-dlesieur/graph_render:d7d1fe80b40d0e38@sha256:965f1fa276aff3434bcdaa766f71efeb19d4f5d74b36b1ccd01e1e5304a93a07}"
PORT="${GRAPH_RENDER_PORT:-8095}"
MEM="${GRAPH_RENDER_MEM:-8g}"
DIR="${GRAPH_RENDER_DIR:-/etc/graph-render}"
MEMINFO="${GRAPH_RENDER_MEMINFO:-/proc/meminfo}"
LINE="${GRAPH_RENDER_KEY_LINE:-}"
NAME=graph-render
# PER_SLOT_BYTES + BASE_BYTES from graph-server's src/config/slots.rs, in kB.
SLOT_KB=$(((4635677069 + 11534336) / 1024))
KEY_RE='^[A-Za-z0-9._-]+ [0-9a-f]{64}$'

log() { printf '[graph-render] %s\n' "$*"; }
die() {
    log "FAIL: $*"
    exit 1
}

case "$PORT" in '' | *[!0-9]*) die "GRAPH_RENDER_PORT=$PORT is not a port" ;; esac
case "$MEM" in '' | *[!0-9kmg]*) die "GRAPH_RENDER_MEM=$MEM is not a docker memory size (8g)" ;; esac
if [ -n "$LINE" ] && ! printf '%s\n' "$LINE" | grep -qE "$KEY_RE"; then
    die "GRAPH_RENDER_KEY_LINE is not '<name> <sha256-hex>'"
fi
command -v docker >/dev/null 2>&1 || die "no docker in the guest (dc-graph-render needs the docker feature)"

getent group graph-render >/dev/null || groupadd --system graph-render || die "cannot create the graph-render group"
GID=$(getent group graph-render | cut -d: -f3)
install -d -m 0755 -o root -g graph-render "$DIR" || die "cannot create $DIR"
[ -e "$DIR/keys" ] || install -m 0640 -o root -g graph-render /dev/null "$DIR/keys" || die "cannot create $DIR/keys"
if ! chown root:graph-render "$DIR/keys" || ! chmod 0640 "$DIR/keys"; then
    die "cannot set $DIR/keys to 0640 root:graph-render"
fi
# What the host's graph_render_key.sh and graph_render_host_access.sh read
# back, so the image and the port are named once, here.
printf 'image=%s\nport=%s\n' "$IMAGE" "$PORT" >"$DIR/service" || die "cannot write $DIR/service"
chmod 0644 "$DIR/service"

n=1
until docker pull -q "$IMAGE" >/dev/null; do
    [ "$n" -lt 3 ] || die "docker pull $IMAGE failed 3 times"
    n=$((n + 1))
    sleep 10
done
log "image $IMAGE"

if [ -n "$LINE" ] && ! grep -qxF "$LINE" "$DIR/keys"; then
    printf '%s\n' "$LINE" >>"$DIR/keys"
    log "added the key line for '${LINE%% *}'"
fi
if ! grep -qE "$KEY_RE" "$DIR/keys"; then
    log "installed, idle: no key yet -- on the host: make graph_render_key"
    exit 0
fi

# A label records what the container was started with: the same spec and
# running means a reload is enough, anything else is a new container.
spec="$IMAGE $PORT $MEM"
have=$(docker inspect -f '{{index .Config.Labels "b2b.spec"}} {{.State.Running}}' "$NAME" 2>/dev/null || true)
if [ "$have" = "$spec true" ]; then
    docker kill -s HUP "$NAME" >/dev/null || die "cannot signal $NAME"
    log "running; key file re-read (SIGHUP)"
else
    avail=$(awk '/^MemAvailable:/ { print $2 }' "$MEMINFO")
    if [ "${avail:-0}" -lt "$SLOT_KB" ]; then
        die "$((${avail:-0} / 1024)) MiB available, one render slot needs $((SLOT_KB / 1024)) MiB: raise vm.ram_mb in the build's profile, then make qemu_restart"
    fi
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker run -d --name "$NAME" --restart unless-stopped --label "b2b.spec=$spec" \
        --memory "$MEM" --memory-swap "$MEM" --read-only --cap-drop ALL \
        --security-opt no-new-privileges --group-add "$GID" \
        -v "$DIR:/run/graph:ro" -e GRAPH_API_KEYS_FILE=/run/graph/keys \
        -p "127.0.0.1:$PORT:8080" "$IMAGE" >/dev/null || die "docker run $IMAGE failed"
    log "started on 127.0.0.1:$PORT (cap $MEM)"
fi

# The image's own HEALTHCHECK: a 200 from /healthz, every 10 s after a 10 s
# start period.
i=0
while [ "$i" -lt 30 ]; do
    state=$(docker inspect -f '{{.State.Health.Status}}' "$NAME" 2>/dev/null || true)
    if [ "$state" = healthy ]; then
        log "healthy on 127.0.0.1:$PORT"
        exit 0
    fi
    i=$((i + 1))
    sleep 2
done
docker logs --tail 20 "$NAME" 2>&1 | sed 's/^/  /'
die "not healthy after 60 s (health: ${state:-none})"
