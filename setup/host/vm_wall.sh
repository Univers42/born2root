#!/usr/bin/env hellish
# vm_wall.sh — the wall between a QEMU guest and the host it runs on. Runs as
# root, installed once as /usr/local/sbin/b2b-vm-wall:
#   sudo bash setup/host/vm_wall.sh install     the copy + a sudoers line for it
#   b2b-vm-wall apply <vm> [port...]       (re)load the wall for <vm>
#   b2b-vm-wall drop <vm> | status <vm>
# qemu_vm.sh calls `apply` through `sudo -n` before every launch of a walled
# VM; vm_share.sh (make share_wall) decides which VM is walled.
#
# WHY ON THE HOST AND NOT IN THE GUEST
#   QEMU's user-mode network is the qemu process opening sockets on the host
#   for the guest: 10.0.2.2 is the host's 127.0.0.1, and every other address
#   of the host (LAN, docker bridges, tailscale0) is reached the same way. On
#   2026-10-25 that was microk8s's API, Discord's RPC, opencode and some forty
#   other loopback listeners, open to anyone with a shell in baas. A colleague
#   invited to work on grobase is in the guest's docker group, which is root
#   there, so a firewall inside the guest is one they could take down.
#
# WHAT IT MATCHES
#   New connections, TCP and UDP, opened by a process in the VM unit's cgroup
#   (b2b-vm-<vm>.service, written by make autostart) towards any address of
#   this host, which are refused. Port 53 stays open (slirp's 10.0.2.3 is the
#   host's resolver), and so do the ports given (osionos's Funnel in baas
#   serves the host's groot through 10.0.2.2:3001, :8787 and :4000; qemu_vm.sh
#   adds the VM's own ssh forward, which the unit's start script probes).
#   Connections the host opens towards the guest -- ssh b2b, the hostfwd
#   ports, tunnels -- are accepted sockets on QEMU's side, never new, so they
#   pass. The chain sits at priority -150, before NAT: hide's Tor redirect
#   rewrites destinations to 127.0.0.1 at -100, which would make every
#   connection look local.
#
# Caveat: nft resolves the cgroup path to an id when the table is loaded, so
# one load walls one life of the unit; that is why qemu_vm.sh reloads it at
# each start, from inside the new cgroup, and refuses to launch a walled VM
# anywhere else. Other machines on the LAN are not walled: only this host.
set -u
WALL_BIN=/usr/local/sbin/b2b-vm-wall
die() {
    echo "b2b-vm-wall: $*" >&2
    exit 1
}

# wall_table VM: nft identifiers take no hyphen.
wall_table() { printf 'b2b_wall_%s' "$1" | tr '-' '_'; }

# wall_cgroup VM UID: the unit's cgroup, relative to /sys/fs/cgroup.
wall_cgroup() {
    local base="${B2B_CGROUP_ROOT:-/sys/fs/cgroup}" d
    for d in "$base"/user.slice/user-"$2".slice/user@"$2".service/*/b2b-vm-"$1".service; do
        [ -d "$d" ] || continue
        printf '%s\n' "${d#"$base"/}"
        return 0
    done
    return 1
}

# wall_rules VM CGROUP [PORT...]: the nft script, atomic (delete + create).
wall_rules() {
    local table cg="$2" level ports
    table=$(wall_table "$1")
    shift 2
    level=$(printf '%s' "$cg" | awk -F/ '{print NF}')
    printf 'table inet %s\ndelete table inet %s\ntable inet %s {\n' "$table" "$table" "$table"
    printf '    chain out {\n        type filter hook output priority -150; policy accept;\n'
    printf '        socket cgroupv2 level %s "%s" ct state new jump wall\n    }\n' "$level" "$cg"
    printf '    chain wall {\n        meta l4proto { tcp, udp } th dport 53 fib daddr type local accept\n'
    if [ "$#" -gt 0 ]; then
        ports=$(printf '%s, ' "$@")
        printf '        tcp dport { %s } fib daddr type local accept\n' "${ports%, }"
    fi
    printf '        fib daddr type local counter reject\n    }\n}\n'
}

check_vm() {
    case "$1" in '' | *[!A-Za-z0-9_-]*) die "bad VM name '$1'" ;; esac
}
check_port() {
    case "$1" in '' | *[!0-9]*) die "bad port '$1'" ;; esac
    if [ "${#1}" -gt 5 ] || [ "$1" -lt 1 ] || [ "$1" -gt 65535 ]; then
        die "bad port '$1'"
    fi
}

wall_main() {
    local action="${1:-}" vm="${2:-}" uid cg p user tmp
    case "$action" in
    install)
        [ "$(id -u)" = 0 ] || die "run it with sudo"
        user="${SUDO_USER:-}"
        case "$user" in '' | root) die "run it with sudo from your own account" ;; esac
        install -m 0755 -o root -g root "$0" "$WALL_BIN" || die "cannot install $WALL_BIN"
        # The unit starts QEMU with no terminal, so the line has to need no password.
        tmp=$(mktemp)
        printf '%s ALL=(root) NOPASSWD: %s\n' "$user" "$WALL_BIN" >"$tmp"
        visudo -cf "$tmp" >/dev/null || {
            rm -f "$tmp"
            die "visudo refused the sudoers line"
        }
        install -m 0440 -o root -g root "$tmp" /etc/sudoers.d/b2b-vm-wall
        rm -f "$tmp"
        echo "installed $WALL_BIN and /etc/sudoers.d/b2b-vm-wall for $user"
        ;;
    apply)
        check_vm "$vm"
        shift 2
        for p in "$@"; do
            check_port "$p"
        done
        uid="${SUDO_UID:-}"
        [ -n "$uid" ] || die "run it through sudo: the unit's cgroup is found from your uid"
        cg=$(wall_cgroup "$vm" "$uid") ||
            die "b2b-vm-$vm.service has no cgroup: the wall is loaded from inside the running unit"
        wall_rules "$vm" "$cg" "$@" | nft -f - || die "nft refused the wall for $vm"
        echo "wall up for $vm (host ports open to it: ${*:-none but DNS})"
        ;;
    drop)
        check_vm "$vm"
        nft delete table inet "$(wall_table "$vm")" 2>/dev/null || true
        ;;
    status)
        check_vm "$vm"
        nft list table inet "$(wall_table "$vm")" >/dev/null 2>&1
        ;;
    *) die "usage: $0 install | apply <vm> [port...] | drop <vm> | status <vm>" ;;
    esac
}

[ "${B2B_WALL_LIB:-0}" = 1 ] || wall_main "$@"
