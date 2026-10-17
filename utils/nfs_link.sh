#!/usr/bin/env hellish
# nfs_link.sh -- how many bytes a second the VM may take from the network link
# its disk travels on, so the seat's own home keeps the rest.
#
# The bug: on c2r19s6 (2026-10-17) the desktop crawled while baas booted and
# backed up. Its 27 GB qcow2 lives on /sgoinfre (NFS), the 42 home is an iSCSI
# disk, and both ride enp2s0f1 -- negotiated at 100 Mb/s on that seat. The home
# disk averaged 57.6 ms a request over the session (2.0 ms once the guest had
# settled) and the host spent 4.3% of five minutes fully stalled on I/O, with
# 90% of its CPU idle. QEMU caps its own disk at half of that link
# (throttling.bps-total, shared by its drives), and backup_pull.sh's rsync
# takes the same budget.
#
#   . utils/nfs_link.sh; nfs_disk_budget PATH   bytes/s, empty for no cap
#   env: B2B_DISK_MBPS  MB/s by hand (0 = no cap), beats the measurement
#        B2B_NFS_LINK_SYSFS  /sys/class/net, for the tests
#
# Caveat: the link is the interface routing to the NFS server, and its speed is
# what the driver negotiated; the switch, other seats and the iSCSI target can
# be slower than that, and then half of the link is still too much (lower it
# with B2B_DISK_MBPS). A path not on NFS, a server that does not resolve or an
# interface without a speed (Wi-Fi reports none) gets no cap.

nfs_disk_budget() {
    local src server ip dev speed
    if [ -n "${B2B_DISK_MBPS:-}" ]; then
        [ "$B2B_DISK_MBPS" = 0 ] || printf '%s\n' $((B2B_DISK_MBPS * 1000000))
        return 0
    fi
    case "$(findmnt -no FSTYPE -T "$1" 2>/dev/null)" in
    nfs*) ;;
    *) return 0 ;;
    esac
    src=$(findmnt -no SOURCE -T "$1" 2>/dev/null)
    server=${src%%:*}
    ip=$(getent ahostsv4 "$server" 2>/dev/null | awk 'NR == 1 { print $1 }')
    [ -n "$ip" ] || return 0
    dev=$(ip route get "$ip" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n1)
    [ -n "$dev" ] || return 0
    speed=$(cat "${B2B_NFS_LINK_SYSFS:-/sys/class/net}/$dev/speed" 2>/dev/null)
    case "$speed" in
    '' | *[!0-9]* | 0) return 0 ;;
    esac
    # Mb/s to bytes/s, halved.
    printf '%s\n' $((speed * 1000000 / 16))
}
