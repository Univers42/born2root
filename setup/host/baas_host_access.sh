#!/usr/bin/env hellish
# baas_host_access.sh — reach grobase's gateway from the HOST.
#
# THE OBSTACLE, THE SAME ONE groot_host_access.sh DOCUMENTS
#   Kong publishes 127.0.0.1:8000 inside the guest (gateway.yml), the WAF
#   127.0.0.1:8443. QEMU's user-mode NAT forwards a host port to the guest
#   NIC (10.0.2.15), never to the guest's loopback, so the `baas-gateway`
#   hostfwd in PORTS_SPEC connects and then dies: slirp accepts the TCP
#   handshake and only then finds nothing behind it. An SSH LocalForward
#   works because sshd is in the guest and dials 127.0.0.1:8000 from there.
#
# WHY NOT EXTEND groot_host_access.sh
#   That script reads groot's nginx.conf for its port map and, correctly,
#   refuses to tunnel Kong's :8000 as https -- it is plain HTTP. The gateway
#   is a different thing with a different protocol per port; a separate,
#   smaller script is clearer than a special case in the other one.
#
# WHAT YOU GET
#   host 127.0.0.1:18000 -> guest Kong,  plain HTTP   (the API clients use)
#   host 127.0.0.1:18443 -> guest WAF,   HTTPS        (self-signed by `make certs`)
#   in the background, with a pidfile beside the VM's own, until --undo.
#   A frontend on the host points its API base at http://localhost:18000.
#
# WHY NOT 8000 ON THE HOST
#   QEMU already listens there: PORTS_SPEC forwards baas-gateway:8000:8000,
#   and that listener is the dead end above -- it holds the host port and
#   delivers nothing. The first `make baas_access` found 8000 "already in
#   use" for that reason. 18000/18443 are the same numbers, one digit up,
#   so a client config reads as what it is; BAAS_GATEWAY_PORT= picks
#   another.
#
#   baas_host_access.sh            open the tunnel (idempotent)
#   baas_host_access.sh --status   is it up, does the gateway answer
#   baas_host_access.sh --undo     close it
set -u

# shellcheck source=setup/host/dc_lib.sh
. "$(dirname "${BASH_SOURCE[0]:-$0}")/dc_lib.sh"

GATEWAY_PORT="${BAAS_GATEWAY_PORT:-18000}"
WAF_PORT="${BAAS_WAF_PORT:-18443}"
VM_PATH="${VM_PATH:-$DC_ROOT/disk_images}"
PIDFILE="$VM_PATH/$VM_NAME/baas-tunnel.pid"

tunnel_pid() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null && cat "$PIDFILE"; }

probe() {
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "http://127.0.0.1:${GATEWAY_PORT}/" 2>/dev/null || echo 000)
    printf '%s' "$code"
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
        ok "tunnel up (pid $pid): host :${GATEWAY_PORT} -> guest Kong, host :${WAF_PORT} -> guest WAF"
        code=$(probe)
        case "$code" in
        000) warn "gateway does not answer through it (guest still starting? make grobase_status)" ;;
        *) ok "gateway answers HTTP $code on http://127.0.0.1:${GATEWAY_PORT}/" ;;
        esac
    else
        warn "no tunnel; open it with: make baas_access"
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
# Where Kong and the WAF actually listen in the guest, read from Docker:
# grobase's resolve-ports.sh bumps a busy port at `make up`, and a rerun
# found its own previous WAF holding 8443, so the new one took 8444. A
# forward to an assumed 8443 then connects to nothing.
guest_port() { # <container> <container port> <fallback>
    local p
    p=$(vm_ssh "docker port '$1' '$2/tcp' 2>/dev/null | head -n1 | sed 's/.*://'" 2>/dev/null)
    case "$p" in '' | *[!0-9]*) p="$3" ;; esac
    printf '%s' "$p"
}
KONG_IN_GUEST=$(guest_port mini-baas-kong 8000 8000)
WAF_IN_GUEST=$(guest_port mini-baas-waf 443 8443)
if pid=$(tunnel_pid); then
    ok "tunnel already up (pid $pid)"
else
    for p in "$GATEWAY_PORT" "$WAF_PORT"; do
        if ss -ltn 2>/dev/null | awk '{ print $4 }' | grep -q ":${p}\$"; then
            die "host port $p is already in use; BAAS_GATEWAY_PORT= / BAAS_WAF_PORT= pick others"
        fi
    done
    # -N: no command. -f would fork before the forwards are proven; a plain
    # background job with its pid recorded is simpler to stop. Its stdio is
    # detached: a tunnel that keeps the caller's stdout open keeps
    # `make baas_access` from returning (it hung a 90 s timeout the first
    # time). nohup, not setsid: setsid forks when it is not already a group
    # leader, so $! was the short-lived parent, the script declared the
    # tunnel dead, and an orphan kept serving 18000 with no pidfile.
    nohup ssh -N "${SSH_OPTS[@]}" -o ExitOnForwardFailure=yes \
        -L "127.0.0.1:${GATEWAY_PORT}:127.0.0.1:${KONG_IN_GUEST}" \
        -L "127.0.0.1:${WAF_PORT}:127.0.0.1:${WAF_IN_GUEST}" \
        "${VM_USER}@127.0.0.1" </dev/null >/dev/null 2>&1 &
    pid=$!
    disown "$pid" 2>/dev/null || true
    sleep 1
    kill -0 "$pid" 2>/dev/null || die "the tunnel exited at once (a forward failed?)"
    printf '%s\n' "$pid" >"$PIDFILE"
    ok "tunnel open (pid $pid): host :${GATEWAY_PORT} -> guest Kong :${KONG_IN_GUEST}, host :${WAF_PORT} -> guest WAF :${WAF_IN_GUEST}"
fi
code=$(probe)
case "$code" in
000) warn "gateway not answering yet on http://127.0.0.1:${GATEWAY_PORT}/ -- grobase may still be starting" ;;
*) ok "gateway answers HTTP $code: http://127.0.0.1:${GATEWAY_PORT}/  (https://127.0.0.1:${WAF_PORT}/ for the WAF)" ;;
esac
# shellcheck disable=SC2059 # the colour codes are the format, as everywhere in setup/host
printf "  ${C_DIM}close with: make baas_access_undo${C_R}\n"
