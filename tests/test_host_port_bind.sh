#!/usr/bin/env hellish
# Regression test for HOST_PORT_BIND in utils/host_ports.sh.
#
# The bug it guards: after a host reboot the LAN edge (socat on 192.168.1.132:8443) started
# before the VM, is_host_port_free saw "something on :8443" and moved QEMU's
# hostfwd 127.0.0.1:8443 to 8445 -- two binds that never collide. The LAN edge kept
# forwarding to 127.0.0.1:8443, so every wifi client lost the data center (2026-10-12).
set -e

cd "$(dirname "$0")/.."
. utils/host_ports.sh

# Fake ss/nc first on PATH, so the test does not depend on this machine's listeners.
stubs=$(mktemp -d)
trap 'rm -rf "$stubs"' EXIT
cat >"$stubs/ss" <<'STUB'
#!/bin/sh
printf '%s\n' "$LISTENERS" | awk 'NF { print "LISTEN 0 4096 " $1 " 0.0.0.0:*" }'
STUB
printf '#!/bin/sh\nexit 1\n' >"$stubs/nc"
chmod +x "$stubs/ss" "$stubs/nc"
PATH="$stubs:$PATH"
export LISTENERS=""

fail=0
expect() { # expect <free|busy> <label> <port> [bind address]
    local got=busy
    HOST_PORT_BIND="${4:-}" is_host_port_free "$3" && got=free
    if [ "$got" = "$1" ]; then
        printf 'ok   %-46s %s\n' "$2" "$got"
    else
        printf 'FAIL %-46s %s (expected %s)\n' "$2" "$got" "$1"
        fail=1
    fi
}

LISTENERS="192.168.1.132:8443"
expect busy "unset bind: any address conflicts" 8443
expect free "127.0.0.1 vs a LAN-address listener" 8443 127.0.0.1

LISTENERS="127.0.0.1:8443"
expect busy "127.0.0.1 vs the same address" 8443 127.0.0.1
LISTENERS="0.0.0.0:8443"
expect busy "127.0.0.1 vs 0.0.0.0" 8443 127.0.0.1
LISTENERS="*:8443"
expect busy "127.0.0.1 vs *" 8443 127.0.0.1
LISTENERS="[::]:8443"
expect busy "127.0.0.1 vs [::] (dual-stack takes v4 too)" 8443 127.0.0.1
LISTENERS="192.168.1.132:18443"
expect free "127.0.0.1 vs another port with the same suffix" 8443 127.0.0.1

# expose = true ([network] forwards): qemu_vm.sh binds that hostfwd on
# 0.0.0.0, so the LAN and Wi-Fi reach the WAF, and every other forward stays
# on 127.0.0.1. The functions are cut out of qemu_vm.sh, not copied.
same() { # same <label> <got> <expected>
    if [ "$2" = "$3" ]; then
        printf 'ok   %-46s\n' "$1"
    else
        printf 'FAIL %-46s got: %s\n' "$1" "$2"
        fail=1
    fi
}
die() { echo "die: $*"; }
warn() { :; }
for fn in fwd_bind build_hostfwd resolve_ports; do
    eval "$(awk -v f="$fn" '$0 ~ "^" f "\\(\\) \\{" { on = 1 } on { print } on && /^}/ { exit }' setup/host/qemu_vm.sh)"
done
PORTS_EXPOSED="http https"
RESOLVED_SPEC="ssh:4242:4242 http:8082:8880 https:8443:8443"
same "exposed forwards bind 0.0.0.0, ssh stays on loopback" "$(build_hostfwd)" \
    ",hostfwd=tcp:127.0.0.1:4242-:4242,hostfwd=tcp:0.0.0.0:8082-:8880,hostfwd=tcp:0.0.0.0:8443-:8443"
PORTS_SPEC="ssh:4242:4242 https:8443:8443"
LISTENERS="192.168.1.132:8443"
RESERVED_HOST_PORTS=""
resolve_ports
same "exposed: a LAN-address listener is a conflict" "$RESOLVED_SPEC" "ssh:4242:4242 https:8444:8443"
PORTS_EXPOSED=""
RESERVED_HOST_PORTS=""
resolve_ports
same "loopback: the same listener is no conflict" "$RESOLVED_SPEC" "ssh:4242:4242 https:8443:8443"

exit "$fail"
