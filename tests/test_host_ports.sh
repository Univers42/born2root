#!/bin/bash
# Regression test for utils/host_ports.sh.
#
# The bug it guards: resolve_host_port used to echo its result, so every caller
# ran it as $(...) — in a subshell — and the reservation it made was discarded.
# With 3001/3002/3003 busy on the host, osionos app/mail/calendar all resolved to
# 3004 and VBoxManage refused the second NAT rule claiming that host port.
set -e

cd "$(dirname "$0")/.."
. utils/host_ports.sh

# Stub the host probe so the test does not depend on this machine's listeners.
is_host_port_free() {
    case "$1" in
    3001 | 3002 | 3003 | 8000 | 8787) return 1 ;;
    *) return 0 ;;
    esac
}

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-22s = %s\n' "$1" "$3"
    else
        printf 'FAIL %-22s = %s (expected %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}

resolve_host_port APP 3001
resolve_host_port MAIL 3002
resolve_host_port CALENDAR 3003
resolve_host_port GATEWAY 8000
resolve_host_port ADMIN 8001

check osionos-app "$APP" 3004
check osionos-mail "$MAIL" 3005
check osionos-calendar "$CALENDAR" 3006
check baas-gateway "$GATEWAY" 8001
check baas-admin "$ADMIN" 8002

# The invariant that actually matters to VirtualBox.
dupes=$(printf '%s\n' "$APP" "$MAIL" "$CALENDAR" "$GATEWAY" "$ADMIN" | sort | uniq -d)
if [ -n "$dupes" ]; then
    printf 'FAIL duplicate host ports: %s\n' "$dupes"
    fail=1
else
    printf 'ok   %-22s\n' "no duplicate host ports"
fi

exit "$fail"
