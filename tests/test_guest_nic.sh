#!/usr/bin/env hellish
# The guest's NIC is `auto`, so network-online.target waits for its lease.
#
# The bug: the installer writes `allow-hotplug ens4`, which networking.service
# does not wait for. After baas restarted on 2026-10-22, dockerd (which waits
# for network-online.target) restored Inception's nginx and adminer before
# 10.0.2.15 existed; their binds failed with "cannot assign requested address"
# and docker never retried them.
#
# The sed line is lifted out of preseeds/b2b-setup.sh by its pattern and run on
# the installer's own interfaces file, so the test reads the line that ships.
set -e

cd "$(dirname "$0")/.."

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-58s = %s\n' "$1" "$2"
    else
        printf 'FAIL %-58s = %s (expected %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

line=$(grep -E "^sed -i -E 's/\^allow-hotplug" preseeds/b2b-setup.sh)
check "b2b-setup.sh rewrites allow-hotplug once" "$(printf '%s\n' "$line" | grep -c .)" 1

printf '%s\n' 'source /etc/network/interfaces.d/*' 'auto lo' 'iface lo inet loopback' \
    'allow-hotplug ens4' 'iface ens4 inet dhcp' >"$TMP/interfaces"
eval "${line/\/etc\/network\/interfaces/$TMP/interfaces}"
check "the NIC becomes auto" "$(grep -cx 'auto ens4' "$TMP/interfaces")" 1
check "no allow-hotplug is left" "$(grep -c '^allow-hotplug' "$TMP/interfaces" || true)" 0
check "loopback and the dhcp stanza are untouched" \
    "$(grep -cx 'auto lo\|iface ens4 inet dhcp' "$TMP/interfaces")" 2

exit "$fail"
