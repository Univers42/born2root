#!/usr/bin/env hellish
# utils/nfs_link.sh: the VM disk's share of the link its NFS server is on.
#
# The bug it pins: on c2r19s6 (2026-10-17) baas's boot and backup filled the
# 100 Mb/s link that /sgoinfre (the qcow2) and the iSCSI home share; the home
# disk averaged 57.6 ms a request and the desktop crawled. QEMU and the
# backup's rsync now take half of that link: 100 Mb/s -> 6250000 bytes/s.
# Pinned here: the arithmetic, the route to the server, no cap off NFS or
# without a speed, and B2B_DISK_MBPS beating all of it.
#
# HOW: findmnt, getent and ip are stubs on PATH; the speed file is a fixture.
set -u

cd "$(dirname "$0")/.." || exit 1
TMP=$(mktemp -d)
trap 'rm -rf "${TMP:?}"' EXIT
. utils/nfs_link.sh

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s -- got: %s, expected: %s\n' "$1" "$2" "$3"
        fail=1
    fi
}

mkdir -p "$TMP/bin" "$TMP/net/enp2s0f1" "$TMP/net/wlan0"
cat >"$TMP/bin/findmnt" <<STUB
#!/bin/sh
case "\$2" in
FSTYPE) cat "$TMP/fstype" ;;
SOURCE) echo sgoinfre.42madrid.com:/srv/nfs4/sgoinfre ;;
esac
STUB
cat >"$TMP/bin/getent" <<'STUB'
#!/bin/sh
[ "$2" = sgoinfre.42madrid.com ] && echo '10.51.1.2       STREAM sgoinfre.42madrid.com'
STUB
cat >"$TMP/bin/ip" <<STUB
#!/bin/sh
echo "10.51.1.2 via 10.12.254.254 dev \$(cat "$TMP/dev") src 10.12.19.6 uid 1000"
STUB
chmod +x "$TMP/bin/findmnt" "$TMP/bin/getent" "$TMP/bin/ip"
PATH="$TMP/bin:$PATH"
export B2B_NFS_LINK_SYSFS="$TMP/net"
unset B2B_DISK_MBPS
echo nfs4 >"$TMP/fstype"
echo enp2s0f1 >"$TMP/dev"

echo 100 >"$TMP/net/enp2s0f1/speed"
check "NFS over a 100 Mb/s link: half of it, in bytes/s" "$(nfs_disk_budget /vm)" 6250000
echo 1000 >"$TMP/net/enp2s0f1/speed"
check "... over 1 Gb/s" "$(nfs_disk_budget /vm)" 62500000
echo wlan0 >"$TMP/dev"
check "an interface without a speed (Wi-Fi): no cap" "$(nfs_disk_budget /vm)" ""
echo enp2s0f1 >"$TMP/dev"
echo ext4 >"$TMP/fstype"
check "a local disk: no cap" "$(nfs_disk_budget /vm)" ""
check "B2B_DISK_MBPS=4: 4 MB/s, measured or not" "$(B2B_DISK_MBPS=4 nfs_disk_budget /vm)" 4000000
echo nfs4 >"$TMP/fstype"
check "B2B_DISK_MBPS=0: no cap even on NFS" "$(B2B_DISK_MBPS=0 nfs_disk_budget /vm)" ""
# The callers: every qemu_vm.sh drive takes the cap, and both rsyncs.
# shellcheck disable=SC2016 # the literal ${...} is what the grep looks for
check "qemu_vm.sh: hd0 (both paths) and hd1 carry the throttle" \
    "$(grep -c 'id=hd[01],format=qcow2,.*${throttle}"' setup/host/qemu_vm.sh)" 3
# shellcheck disable=SC2016
check "backup_pull.sh: the pull and the restore rsync carry the cap" \
    "$(grep -c 'rsync -a .*"${RSYNC_CAP\[@\]}"' setup/host/backup_pull.sh)" 2
exit "$fail"
