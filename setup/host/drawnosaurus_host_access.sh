#!/usr/bin/env hellish
# drawnosaurus_host_access.sh — reach drawnosaurus's gateway/API from the HOST.
#
# THE OBSTACLE, THE SAME ONE groot_host_access.sh AND baas_host_access.sh
# DOCUMENT
#   drawnosaurus's docker compose publishes the gateway and API for "this
#   computer" as 127.0.0.1:5273 and 127.0.0.1:4300 -- loopback-bound, on
#   purpose (the gateway decides identity by which port a connection arrived
#   on, and 5273 is the ONLY entrance with full access, so it must not be
#   reachable from outside the guest). QEMU/VirtualBox NAT forwards a host
#   port to the guest's real NIC (10.0.2.15), never to its loopback, so a
#   [network] forwards entry for 5273/4300 in born2root.toml opens a NAT rule
#   that can never carry traffic -- the browser hangs, because slirp accepts
#   the TCP handshake and only then finds nothing behind it (see
#   groot_host_access.sh's header for the identical failure on a different
#   app). Worse, that dead rule squats the host port, so nothing else can
#   bind 5273/4300 either. An SSH LocalForward works because sshd is IN the
#   guest and dials 127.0.0.1 from there.
#
#   born2root.toml's [network] forwards is for a port the guest binds to
#   0.0.0.0 (drawnosaurus's own LAN entrance, 5274, and its WS transport,
#   4402, both already reachable that way). A loopback-bound port needs a
#   script like this one instead -- never add 5273/4300 back to [network]
#   forwards.
#
# WHY THE SAME HOST PORT NUMBERS
#   Unlike baas_host_access.sh (which moves 8000/8443 up to 18000/18443
#   because a dead NAT rule already squats the low numbers), drawnosaurus is
#   meant to open at exactly http://localhost:5273/ for every colleague who
#   clones this repo, so free_forward below removes any stale NAT/natpf rule
#   first and the tunnel claims the same numbers.
#
#   drawnosaurus_host_access.sh            open the tunnel (idempotent)
#   drawnosaurus_host_access.sh --status   is it up, does the gateway answer
#   drawnosaurus_host_access.sh --undo     close it
set -u

# shellcheck source=setup/host/dc_lib.sh
. "$(dirname "${BASH_SOURCE[0]:-$0}")/dc_lib.sh"

WEB_PORT="${DRAWNOSAURUS_WEB_PORT:-5273}"
API_PORT="${DRAWNOSAURUS_API_PORT:-4300}"
VM_PATH="${VM_PATH:-$DC_ROOT/disk_images}"
PIDFILE="$VM_PATH/$VM_NAME/drawnosaurus-tunnel.pid"

tunnel_pid() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null && cat "$PIDFILE"; }

probe() {
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "http://127.0.0.1:${WEB_PORT}/" 2>/dev/null || echo 000)
    printf '%s' "$code"
}

# Remove whatever is squatting a host port before the tunnel tries to bind
# it: a leftover VirtualBox natpf rule (any name -- an old born2root.toml may
# still list one), or a QEMU hostfwd (recorded only on its monitor socket,
# see vm_ports.sh). Both are always dead for a loopback-bound service, so
# dropping them loses nothing; qemu_vm.sh recreates any legitimate one on the
# next VM start regardless.
free_forward() {
    local port="$1" rule
    if command -v VBoxManage >/dev/null 2>&1 &&
        VBoxManage showvminfo "$VM_NAME" >/dev/null 2>&1; then
        while IFS= read -r rule; do
            [ -n "$rule" ] || continue
            VBoxManage controlvm "$VM_NAME" natpf1 delete "$rule" >/dev/null 2>&1 || true
        done < <(VBoxManage showvminfo "$VM_NAME" --machinereadable 2>/dev/null |
            awk -F'"' '/^Forwarding/ { print $2 }' |
            awk -F',' -v p="$port" '$4 == p { print $1 }')
        return 0
    fi
    ss -ltnp 2>/dev/null | grep -q "127.0.0.1:${port} .*qemu" || return 0
    local sock="$VM_PATH/$VM_NAME/monitor.sock"
    [ -S "$sock" ] || return 0
    python3 - "$sock" "$port" <<'PYEOF' 2>/dev/null
import socket, sys, time
sock, port = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(5)
s.connect(sock)
time.sleep(0.2)
try: s.recv(65536)
except Exception: pass
s.sendall(f"hostfwd_remove tcp:127.0.0.1:{port}\n".encode())
time.sleep(0.2)
s.close()
PYEOF
}

case "${1:-}" in
--undo)
    if pid=$(tunnel_pid); then
        kill "$pid" 2>/dev/null
        rm -f "$PIDFILE"
        ok "tunnel closed (was pid $pid)"
    else
        ok "no tunnel to close"
    fi
    exit 0
    ;;
--status)
    if pid=$(tunnel_pid); then
        ok "tunnel up (pid $pid): host :${WEB_PORT} -> guest gateway, host :${API_PORT} -> guest API"
        code=$(probe)
        case "$code" in
        000) warn "gateway does not answer through it (is drawnosaurus running? make qemu_ssh CMD='docker compose -f ~/drawnosaurus/docker-compose.yml ps')" ;;
        *) ok "gateway answers HTTP $code on http://127.0.0.1:${WEB_PORT}/" ;;
        esac
    else
        warn "no tunnel; open it with: make drawnosaurus"
    fi
    exit 0
    ;;
'') ;;
*)
    echo "usage: $0 [--status | --undo]" >&2
    exit 2
    ;;
esac

dc_connect
if pid=$(tunnel_pid); then
    ok "tunnel already up (pid $pid)"
else
    free_forward "$WEB_PORT"
    free_forward "$API_PORT"
    for p in "$WEB_PORT" "$API_PORT"; do
        if ss -ltn 2>/dev/null | awk '{ print $4 }' | grep -q ":${p}\$"; then
            die "host port $p is still in use; DRAWNOSAURUS_WEB_PORT= / DRAWNOSAURUS_API_PORT= pick others"
        fi
    done
    # -N, backgrounded with nohup and its pid recorded rather than -f: see
    # baas_host_access.sh for why -f's early fork lost the pidfile once.
    nohup ssh -N "${SSH_OPTS[@]}" -o ExitOnForwardFailure=yes \
        -L "127.0.0.1:${WEB_PORT}:127.0.0.1:${WEB_PORT}" \
        -L "127.0.0.1:${API_PORT}:127.0.0.1:${API_PORT}" \
        "${VM_USER}@127.0.0.1" </dev/null >/dev/null 2>&1 &
    pid=$!
    disown "$pid" 2>/dev/null || true
    sleep 1
    kill -0 "$pid" 2>/dev/null || die "the tunnel exited at once (is drawnosaurus's gateway actually listening on 127.0.0.1:${WEB_PORT} in the guest?)"
    printf '%s\n' "$pid" >"$PIDFILE"
    ok "tunnel open (pid $pid): host :${WEB_PORT} -> guest gateway, host :${API_PORT} -> guest API"
fi
code=$(probe)
case "$code" in
000) warn "gateway not answering yet on http://127.0.0.1:${WEB_PORT}/ -- is drawnosaurus started (make up) in the guest?" ;;
*) ok "gateway answers HTTP $code: http://127.0.0.1:${WEB_PORT}/" ;;
esac
# shellcheck disable=SC2059 # the colour codes are the format, as everywhere in setup/host
printf "  ${C_DIM}close with: make drawnosaurus_undo${C_R}\n"
