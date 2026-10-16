#!/usr/bin/env hellish
# health.sh — one verdict for a running VM: the platform, the guest's reach,
# and every network that should reach the WAF. `make health`; exit 1 on any ✗.
#
#   platform     verify_platform.sh: the stack (b2b-stack-health), the timers,
#                the backup, the wall (nothing off loopback but the doors)
#   guest out    DNS and HTTPS to the internet, from the guest and from inside
#                a container; the host's own LAN address, through the NAT
#   host in      every forward answers on the host; an exposed one ([network]
#                forwards, expose = true) also on each LAN / Wi-Fi address
#   tailnet      the guest's node is Running, and this seat reaches the WAF
#                and sshd through its userspace tailscaled (make seat_tailnet)
#
# WHY ONE COMMAND: on 2026-10-16 "is it all working" took a stack check, a
# platform check, a seat check and a dozen curls by hand, and the seat being
# off the tailnet (a revoked key) was found only on the last of them.
#
# Caveat: a LAN address answering on this host proves the bind, not the
# campus or home network between another machine and this one: a firewall on
# the way is invisible from here. "Answers" is any HTTP status (the WAF says
# 404 at /), so a WAF that answers with an error page still passes.
set -u

. "$(dirname "${BASH_SOURCE[0]:-$0}")/dc_lib.sh"

SOCKS="${B2B_SEAT_SOCKS:-localhost:1055}"
fail=0
pass() { ok "$1"; }
flunk() {
    printf "${C_RED}✗${C_R} %s\n" "$1"
    [ -z "${2:-}" ] || printf '    %s\n' "$2"
    fail=1
}
# answered CODE: an HTTP status came back (curl prints 000 when none did).
answered() {
    case "$1" in
    [1-5][0-9][0-9]) return 0 ;;
    *) return 1 ;;
    esac
}

# The host's LAN and Wi-Fi addresses: global IPv4 on every interface but the
# loopback and the bridges of local hypervisors and containers.
host_lan_addresses() {
    ip -4 -o addr show scope global 2>/dev/null | awk '
        $2 ~ /^(docker|br-|veth|virbr|vboxnet|tailscale|lxc|lxd|cni|flannel|podman|vnet)/ { next }
        { sub(/\/.*/, "", $4); print $2, $4 }'
}

# The scheme a forward speaks, from its name: https, inception-https -> https.
scheme_of() {
    case "$1" in
    ssh) printf 'ssh' ;;
    *https*) printf 'https' ;;
    *) printf 'http' ;;
    esac
}

probe_forward() { # NAME HOST_PORT ADDRESS -> pass or flunk
    local name="$1" port="$2" addr="$3" scheme code
    scheme=$(scheme_of "$name")
    if [ "$scheme" = ssh ]; then
        if timeout 6 bash -c "head -c 7 </dev/tcp/$addr/$port" 2>/dev/null | grep -q '^SSH-2.0'; then
            pass "$name: sshd answers on $addr:$port"
        else
            flunk "$name: no SSH banner on $addr:$port"
        fi
        return
    fi
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 "$scheme://$addr:$port/" 2>/dev/null)
    if answered "${code:-000}"; then
        pass "$name: $scheme://$addr:$port answers (HTTP $code)"
    else
        flunk "$name: nothing answers on $scheme://$addr:$port" "make qemu_restart picks up a forward added since the VM booted"
    fi
}

section() { printf "\n  ${C_B}%s${C_R}\n" "$1"; }

main() {
    local name port lan exposed iface addr state dns code
    section "platform (make verify_platform)"
    if "${SCRIPT_SH:-bash}" "$DC_ROOT/setup/host/verify_platform.sh"; then
        :
    else
        fail=1
    fi
    dc_connect

    section "the guest reaches out"
    for name in https://deb.debian.org/ https://github.com/ https://registry-1.docker.io/v2/; do
        code=$(vm_ssh "curl -s -o /dev/null -w '%{http_code}' --max-time 10 $name" 2>/dev/null)
        if answered "${code:-000}"; then pass "guest -> $name (HTTP $code)"; else flunk "guest -> $name: no answer" "DNS or the host's uplink: ssh into the guest, getent hosts deb.debian.org"; fi
    done
    # Whichever client the image ships: storage-router has wget, not curl.
    code=$(vm_ssh "docker exec mini-baas-storage-router sh -c 'if command -v curl >/dev/null; then curl -s -o /dev/null -w %{http_code} --max-time 8 https://deb.debian.org/; elif wget -q -O /dev/null -T 8 https://deb.debian.org/; then echo 200; else echo 000; fi'" 2>/dev/null)
    if answered "${code:-000}"; then pass "a container -> the internet (HTTP $code)"; else flunk "a container (mini-baas-storage-router) cannot reach the internet" "docker's DNS or its bridge: docker exec mini-baas-storage-router getent hosts deb.debian.org"; fi

    section "the host reaches in"
    exposed=" $(b2b_get B2B_EXPOSED) "
    lan=$(host_lan_addresses)
    for name in $(b2b_get B2B_FORWARDS | tr ' ' '\n' | cut -d: -f1); do
        port=$(vm_forward_port "$name" 2>/dev/null) || port=
        [ -n "$port" ] || {
            flunk "$name: no host port forwarded" "make qemu_restart (a forward added to the profile since the VM booted)"
            continue
        }
        probe_forward "$name" "$port" 127.0.0.1
        case "$exposed" in *" $name "*) ;; *) continue ;; esac
        [ -n "$lan" ] || flunk "$name: exposed, but this host has no LAN or Wi-Fi address"
        while read -r iface addr; do
            [ -n "$addr" ] || continue
            printf '    %s\n' "on $iface:"
            probe_forward "$name" "$port" "$addr"
        done <<EOF
$lan
EOF
        # The guest goes out through the NAT and back in on the host's own LAN
        # address: the same path a machine beside this one takes.
        addr=$(printf '%s\n' "$lan" | awk 'NR == 1 { print $2 }')
        if [ -n "$addr" ]; then
            code=$(vm_ssh "curl -sk -o /dev/null -w '%{http_code}' --max-time 8 $(scheme_of "$name")://$addr:$port/" 2>/dev/null)
            if answered "${code:-000}"; then pass "$name: the guest reaches it back on the host's LAN address $addr:$port"; else flunk "$name: not reachable on $addr:$port from the guest's side of the NAT"; fi
        fi
    done

    section "the tailnet"
    state=$(vm_ssh "tailscale status --json 2>/dev/null" 2>/dev/null | python3 -c 'import json, sys
try:
    j = json.load(sys.stdin)
    print(j.get("BackendState", ""), (j.get("Self") or {}).get("DNSName", "").rstrip("."))
except Exception:
    print("")' 2>/dev/null)
    dns=${state#* }
    state=${state%% *}
    if [ "$state" = Running ] && [ -n "$dns" ]; then
        pass "the guest is on the tailnet as $dns"
        code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 20 -x "socks5h://$SOCKS" "https://$dns/" 2>/dev/null)
        if answered "${code:-000}"; then
            pass "this seat -> https://$dns/ (the WAF, through tailscale serve; HTTP $code)"
        else
            flunk "this seat cannot reach https://$dns/ through $SOCKS" "make seat_tailnet (this seat's userspace tailscaled; it mints a new key when the old one is revoked)"
        fi
        if timeout 20 curl -s --max-time 15 -x "socks5h://$SOCKS" "telnet://$dns:4242" </dev/null 2>/dev/null | head -c 7 | grep -q '^SSH-2.0'; then
            pass "this seat -> $dns:4242 (sshd over the tailnet)"
        else
            flunk "this seat gets no SSH banner from $dns:4242 over the tailnet" "make seat_tailnet"
        fi
    else
        flunk "the guest is not on the tailnet (${state:-no answer})" "make tailnet"
    fi

    printf '\n'
    if [ "$fail" = 0 ]; then
        ok "healthy: the platform, the guest's reach and every network to the WAF"
    else
        printf "${C_RED}✗${C_R} %s\n" "NOT healthy -- see the ✗ lines above"
    fi
    return "$fail"
}

[ "${B2B_HEALTH_LIB:-0}" = 1 ] || main
