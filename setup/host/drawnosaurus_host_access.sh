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
#   clones this repo, so free_forward (dc_lib.sh) removes any stale
#   NAT/natpf rule first and the tunnel claims the same numbers.
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

probe() { http_code "http://127.0.0.1:${WEB_PORT}/"; }

case "${1:-}" in
--undo)
    tunnel_close "$PIDFILE"
    exit 0
    ;;
--status)
    if pid=$(tunnel_pid "$PIDFILE"); then
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
if pid=$(tunnel_pid "$PIDFILE"); then
    ok "tunnel already up (pid $pid)"
else
    free_forward "$WEB_PORT"
    free_forward "$API_PORT"
    tunnel_open "$PIDFILE" "DRAWNOSAURUS_WEB_PORT= / DRAWNOSAURUS_API_PORT= pick others" \
        "$WEB_PORT:$WEB_PORT" "$API_PORT:$API_PORT"
    pid=$(tunnel_pid "$PIDFILE")
    ok "tunnel open (pid $pid): host :${WEB_PORT} -> guest gateway, host :${API_PORT} -> guest API"
fi
code=$(probe)
case "$code" in
000) warn "gateway not answering yet on http://127.0.0.1:${WEB_PORT}/ -- is drawnosaurus started (make up) in the guest?" ;;
*) ok "gateway answers HTTP $code: http://127.0.0.1:${WEB_PORT}/" ;;
esac
# shellcheck disable=SC2059 # the colour codes are the format, as everywhere in setup/host
printf "  ${C_DIM}close with: make drawnosaurus_undo${C_R}\n"
