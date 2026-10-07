#!/usr/bin/env hellish
# install_graph_render.sh starts graph_render only when it has a key and a
# render slot's worth of memory, always confined, and never twice.
#
# THE FAILURES IT PINS
#   - The server refuses to start without a key (exit 2), so a first boot
#     that started it anyway would leave a container restarting forever:
#     without a key line the installer must pull, report idle and run nothing.
#   - One slot is 4.32 GiB; a guest without it would start the server and
#     lose the first large render to the OOM killer (2238 MB were left on the
#     datacenter guest on 2026-10-07). Below a slot: refuse, name vm.ram_mb.
#   - The key file is bind-mounted; a single-file mount pins the inode, so a
#     rewritten file never reaches SIGHUP. The directory is what is mounted.
#   - A rerun with the same key appends nothing and, the container being up
#     with the same spec, reloads instead of recreating it.
#
# HOW
#   The installer runs as is against stubs on PATH that record their
#   arguments: docker (inspect answers from $STUB_DIR/running and
#   $STUB_DIR/health), getent, groupadd, install, chown, and sleep. The key
#   directory and /proc/meminfo come from GRAPH_RENDER_DIR and
#   GRAPH_RENDER_MEMINFO.
set -e

cd "$(dirname "$0")/.."

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s -- got: %s, expected: %s\n' "$1" "$2" "$3"
        fail=1
    fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export STUB_DIR="$TMP"
export GRAPH_RENDER_DIR="$TMP/etc"
export GRAPH_RENDER_MEMINFO="$TMP/meminfo"
mkdir -p "$TMP/bin"

cat >"$TMP/bin/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$STUB_DIR/docker.log"
case "$1" in
inspect)
    case "$*" in
    *Health*) cat "$STUB_DIR/health" 2>/dev/null ;;
    *) [ -f "$STUB_DIR/running" ] && cat "$STUB_DIR/running" || exit 1 ;;
    esac
    ;;
logs) echo "graph-server: some log line" ;;
esac
exit 0
EOF
cat >"$TMP/bin/getent" <<'EOF'
#!/bin/sh
echo 'graph-render:x:997:'
EOF
cat >"$TMP/bin/install" <<'EOF'
#!/bin/sh
mode=""
dir=0
while [ $# -gt 0 ]; do
    case "$1" in
    -d) dir=1 ;;
    -m) mode=$2; shift ;;
    -o | -g) shift ;;
    *) last=$1 ;;
    esac
    shift
done
if [ "$dir" = 1 ]; then mkdir -p "$last"; else : >"$last"; fi
[ -z "$mode" ] || chmod "$mode" "$last"
EOF
for t in groupadd chown sleep; do
    printf '#!/bin/sh\nexit 0\n' >"$TMP/bin/$t"
done
chmod +x "$TMP"/bin/*
export PATH="$TMP/bin:$PATH"

SHA=$(printf '%064d' 0 | tr 0 a)
mem() { printf 'MemTotal: 14318000 kB\nMemAvailable: %s kB\n' "$1" >"$TMP/meminfo"; }
run() {
    : >"$TMP/docker.log"
    rc=0
    out=$(env "$@" bash setup/install/dc/install_graph_render.sh 2>&1) || rc=$?
    log=$(cat "$TMP/docker.log")
}
count() { printf '%s\n' "$log" | grep -c -- "$1" || true; }

mem 9000000
echo healthy >"$TMP/health"

# --- no key: pull, idle, run nothing -------------------------------------------
run
check "no key: exit 0" "$rc" 0
check "no key: pulls the pinned image" "$(count '^pull -q dlesieur/graph_render:.*@sha256:')" 1
check "no key: starts nothing" "$(count '^run ')" 0
check "no key: says it is idle and what to run" "$(printf '%s\n' "$out" | grep -c 'idle: no key yet -- on the host: make graph_render_key' || true)" 1
check "no key: empty key file, 0640" "$(stat -c '%a %s' "$TMP/etc/keys")" "640 0"
check "no key: records image and port for the host" "$(sed -n 's/^port=//p' "$TMP/etc/service")" 8095

# --- a malformed line is refused before anything ------------------------------
run GRAPH_RENDER_KEY_LINE="ops not-a-hash"
check "malformed key line: exit 1" "$rc" 1
check "... and touches neither docker nor the file" "$(count .)$(stat -c %s "$TMP/etc/keys")" 00

# --- not enough memory for one slot ---------------------------------------------
mem 2291712
run GRAPH_RENDER_KEY_LINE="ops $SHA"
check "2238 MiB available: exit 1" "$rc" 1
check "... names the fix" "$(printf '%s\n' "$out" | grep -c 'raise vm.ram_mb' || true)" 1
check "... and starts nothing" "$(count '^run ')" 0
mem 9000000

# --- a key and a slot: started, confined ---------------------------------------
run GRAPH_RENDER_KEY_LINE="ops $SHA"
check "with a key: exit 0" "$rc" 0
check "the key line is in the file once" "$(grep -cx "ops $SHA" "$TMP/etc/keys")" 1
runline=$(printf '%s\n' "$log" | grep '^run ')
wants=('--read-only' '--cap-drop ALL' '--security-opt no-new-privileges'
    '--memory 8g --memory-swap 8g' '-p 127.0.0.1:8095:8080' '--group-add 997'
    '--restart unless-stopped' "-v $TMP/etc:/run/graph:ro" '-e GRAPH_API_KEYS_FILE=/run/graph/keys')
for want in "${wants[@]}"; do
    case "$runline" in
    *"$want"*) check "run carries $want" 1 1 ;;
    *) check "run carries $want" "$runline" "$want" ;;
    esac
done
check "never publishes off the loopback" "$(printf '%s\n' "$runline" | grep -cE -- '-p [0-9]+:' || true)" 0

# --- the same key again, container up with the same spec: reload --------------
spec=$(printf '%s\n' "$runline" | sed -n 's/.*--label b2b.spec=\(.* [0-9]* [0-9a-z]*\) --memory.*/\1/p')
echo "$spec true" >"$TMP/running"
run GRAPH_RENDER_KEY_LINE="ops $SHA"
check "rerun: exit 0" "$rc" 0
check "rerun: the line is still there once" "$(grep -cx "ops $SHA" "$TMP/etc/keys")" 1
check "rerun: SIGHUP, not a new container" "$(count '^kill -s HUP graph-render$')$(count '^run ')" 10

# --- a different port is a new container, not a reload ------------------------
run GRAPH_RENDER_PORT=8096
check "new port: recreated" "$(count '^rm -f graph-render$')$(count '^run ')" 11

# --- never healthy: fail with the logs ------------------------------------------
rm -f "$TMP/running"
echo unhealthy >"$TMP/health"
run
check "unhealthy: exit 1" "$rc" 1
check "... shows the container's log" "$(printf '%s\n' "$out" | grep -c 'graph-server: some log line' || true)" 1

exit "$fail"
