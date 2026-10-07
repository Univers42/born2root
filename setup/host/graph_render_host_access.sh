#!/usr/bin/env hellish
# graph_render_host_access.sh — reach the guest's graph_render from the host.
#
# graph_render publishes on the guest's loopback only (the server has no
# TLS, see install_graph_render.sh), and NAT never reaches a guest's
# loopback, so the host gets it through an SSH tunnel on the same port
# number. drawnosaurus_host_access.sh's header has the whole story, and why
# a [network] forwards entry for the port would squat it instead.
# /healthz needs no key; everything under /v1 wants the key that
# `make graph_render_key` keeps in the secrets file as GRAPH_RENDER_KEY.
#
#   graph_render_host_access.sh            open the tunnel (idempotent)
#   graph_render_host_access.sh --status   is it up, does /healthz answer
#   graph_render_host_access.sh --undo     close it
#   GRAPH_RENDER_HOST_PORT=                another host port (default: the guest's)
set -u

# shellcheck source=setup/host/dc_lib.sh
. "$(dirname "${BASH_SOURCE[0]:-$0}")/dc_lib.sh"

VM_PATH="${VM_PATH:-$DC_ROOT/disk_images}"
PIDFILE="$VM_PATH/$VM_NAME/graph-render-tunnel.pid"
PORTFILE="$VM_PATH/$VM_NAME/graph-render-tunnel.port"

health() { http_code "http://127.0.0.1:$1/healthz"; }

case "${1:-}" in
--undo)
    tunnel_close "$PIDFILE"
    rm -f "$PORTFILE"
    exit 0
    ;;
--status)
    if pid=$(tunnel_pid "$PIDFILE"); then
        port=$(cat "$PORTFILE" 2>/dev/null)
        ok "tunnel up (pid $pid): host :${port} -> guest graph_render"
        code=$(health "$port")
        case "$code" in
        200) ok "/healthz answers 200 on http://127.0.0.1:${port}/" ;;
        *) warn "/healthz answers ${code} through it (no key yet? make graph_render_key)" ;;
        esac
    else
        warn "no tunnel; open it with: make graph_render"
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
guest=$(vm_ssh 'sed -n "s/^port=//p" /etc/graph-render/service 2>/dev/null' | tr -d '\r\n')
case "$guest" in
'') die "graph_render is not installed in the guest (make graph_render_install)" ;;
*[!0-9]*) die "the guest's /etc/graph-render/service names port '$guest'" ;;
esac
port="${GRAPH_RENDER_HOST_PORT:-$guest}"
if pid=$(tunnel_pid "$PIDFILE"); then
    ok "tunnel already up (pid $pid)"
    port=$(cat "$PORTFILE" 2>/dev/null)
else
    free_forward "$port"
    tunnel_open "$PIDFILE" "GRAPH_RENDER_HOST_PORT= picks another" "$port:$guest"
    printf '%s\n' "$port" >"$PORTFILE"
    ok "tunnel open (pid $(tunnel_pid "$PIDFILE")): host :${port} -> guest graph_render :${guest}"
fi
code=$(health "$port")
case "$code" in
200) ok "graph_render answers: http://127.0.0.1:${port}/healthz (send GRAPH_RENDER_KEY as a Bearer token on /v1)" ;;
*) warn "/healthz answers ${code} -- no key yet? make graph_render_key" ;;
esac
# shellcheck disable=SC2059 # the colour codes are the format, as everywhere in setup/host
printf "  ${C_DIM}close with: make graph_render_undo${C_R}\n"
