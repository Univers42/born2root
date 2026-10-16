#!/usr/bin/env hellish
# ticket_keeper.sh -- the Kerberos ticket a VM disk on a sec=krb5 NFS mount
# (the 42 /sgoinfre) needs, kept after the user logs out.
#
# The bug: baas froze on 2026-10-16 at 04:41, hours after its owner logged
# out of c2r19s5. The guest journal just stops (nothing could be written any
# more), QEMU stayed alive, its slirp sockets kept the tailnet node "online".
# /sgoinfre is nfs4 sec=krb5 and a seat's ticket lasts 10 h, renewable up to
# 24 h after the password was typed; nothing renews it once the session is
# gone, and when the kernel's NFS context expires every read and write of the
# qcow2 fails (a soft mount) and the guest hangs on its own disk.
#
# Every INTERVAL seconds, while QEMU_PID lives:
#   * adopt the login ticket that renews longest into KEEP, a ccache of its
#     own (/tmp/krb5cc_<uid>_b2b-<vm>): rpc.gssd finds the uid's krb5cc_*
#     files in /tmp and takes the newest valid one, so the disk keeps working
#     once the login's own ccache is gone. A later login or screen unlock
#     carries a later renew limit and is adopted on the next pass;
#   * kinit -R it;
#   * when the renew limit is less than MARGIN + INTERVAL away, press the
#     guest's ACPI power button over the QEMU monitor, so the guest shuts down
#     while its disk still answers, and exit. The next login starts it again
#     (autostart.sh's tick).
#
# autostart.sh starts it from its own text with /bin/sh -c, from /: the repo
# and hellish both live in the home, which the logout unmounts.
#
#   ticket_keeper.sh KEEP MONITOR QEMU_PID [MARGIN_S] [INTERVAL_S]
#   env: B2B_KEEPER_TMP (/tmp, where the login ccaches are), B2B_KEEPER_ONCE=1
#        (one pass, for the tests)
#
# Caveat: no password, no renewal past the limit: a guest whose owner never
# logs in again is powered off ~24 h after the last password typed on that
# seat. Not yet seen across a real logout: that rpc.gssd picks KEEP once the
# login's ccache is gone (nfs-utils 2.6.1, the rule above), and that the
# campus logout leaves /tmp alone. If either is wrong the guest still hangs at
# the ticket's expiry, and this log is silent past it. A ticket that never
# reached KEEP (nothing valid in /tmp) powers nothing off: unknown is not
# a deadline.
set -u
umask 077

KEEP=$1
MONITOR=$2
QEMU_PID=$3
MARGIN=${4:-1800}
INTERVAL=${5:-300}
TMPDIR_CC=${B2B_KEEPER_TMP:-/tmp}
uid=$(id -u)

log() { printf '== %s: %s\n' "$(date '+%F %T')" "$*"; }

# The ccache's renew limit as epoch seconds, empty when it has none. klist in
# the C locale prints 10/17/26 14:14:43, which date -d reads.
renew_until() {
    when=$(LC_ALL=C klist -c "$1" 2>/dev/null | sed -n 's/^[[:space:]]*renew until //p' | head -n1)
    [ -n "$when" ] && date -d "$when" +%s 2>/dev/null
}

adopt() {
    best=$KEEP
    best_end=$(renew_until "$KEEP")
    best_end=${best_end:-0}
    for cc in "$TMPDIR_CC/krb5cc_$uid" "$TMPDIR_CC/krb5cc_${uid}"_*; do
        case "$cc" in
        "$KEEP" | *_b2b-* | *.new) continue ;;
        esac
        if ! { [ -f "$cc" ] && [ -O "$cc" ] && klist -s -c "$cc" 2>/dev/null; }; then
            continue
        fi
        end=$(renew_until "$cc")
        [ "${end:-0}" -gt "$best_end" ] || continue
        best=$cc
        best_end=$end
    done
    [ "$best" = "$KEEP" ] && return 0
    cp "$best" "$KEEP.new" && mv -f "$KEEP.new" "$KEEP" &&
        log "kept the login ticket $best, renewable until $(date -d "@$best_end" '+%F %T')"
}

powerdown() {
    printf 'system_powerdown\n' | socat - "UNIX-CONNECT:$MONITOR" >/dev/null 2>&1
}

log "keeping the disk's Kerberos ticket for QEMU pid $QEMU_PID in $KEEP"
while kill -0 "$QEMU_PID" 2>/dev/null; do
    adopt
    kinit -R -c "$KEEP" >/dev/null 2>&1 || log "kinit -R failed (the KDC unreachable, or past the renew limit)"
    end=$(renew_until "$KEEP")
    if [ -n "$end" ] && [ $((end - $(date +%s))) -lt $((MARGIN + INTERVAL)) ]; then
        log "the ticket cannot be renewed past $(date -d "@$end" '+%F %T'): powering the guest off while its disk still answers"
        powerdown || log "the monitor at $MONITOR did not take system_powerdown"
        exit 0
    fi
    [ "${B2B_KEEPER_ONCE:-0}" = 1 ] && exit 0
    sleep "$INTERVAL"
done
log "QEMU pid $QEMU_PID is gone"
