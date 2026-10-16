#!/usr/bin/env hellish
# utils/ticket_keeper.sh: the Kerberos ticket a VM disk on /sgoinfre needs,
# kept after the logout.
#
# The bug it pins: baas froze on 2026-10-16 at 04:41, hours after its owner
# logged out of c2r19s5: /sgoinfre is nfs4 sec=krb5, nothing renewed the
# seat's 10 h ticket, and once it expired the guest hung on its own qcow2.
# Pinned here: which login ticket is kept (the one renewing longest, never an
# expired one, never another VM's copy), that it is renewed, that the guest is
# powered off before the renew limit and never on an unknown one, and that
# the keeper ends with its QEMU.
#
# HOW: klist, kinit and socat are stubs on PATH; a fake ccache holds its renew
# limit as text ("expired" for one klist -s refuses). One pass per run
# (B2B_KEEPER_ONCE=1), under /bin/sh as autostart.sh runs it.
set -u

cd "$(dirname "$0")/.." || exit 1
TMP=$(mktemp -d)
trap 'kill "$QEMU" 2>/dev/null; rm -rf "${TMP:?}"' EXIT

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s -- got: %s, expected: %s\n' "$1" "$2" "$3"
        fail=1
    fi
}

mkdir -p "$TMP/bin" "$TMP/cc"
cat >"$TMP/bin/klist" <<'STUB'
#!/bin/sh
s=0
[ "$1" = -s ] && { s=1; shift; }
[ -s "$2" ] || exit 1
read -r when <"$2"
[ "$when" = expired ] && exit 1
[ "$s" = 1 ] && exit 0
printf 'Ticket cache: FILE:%s\n\trenew until %s\n' "$2" "$when"
STUB
cat >"$TMP/bin/kinit" <<STUB
#!/bin/sh
printf 'kinit %s\n' "\$*" >>"$TMP/calls"
STUB
cat >"$TMP/bin/socat" <<STUB
#!/bin/sh
printf 'socat %s %s\n' "\$*" "\$(cat)" >>"$TMP/calls"
STUB
chmod +x "$TMP/bin/klist" "$TMP/bin/kinit" "$TMP/bin/socat"

U=$(id -u)
KEEP="$TMP/cc/krb5cc_${U}_b2b-baas"
in_hours() { date -d "+$1 hours" '+%m/%d/%y %H:%M:%S'; }
sleep 600 &
QEMU=$!
keeper() { # -> the keeper's output in $TMP/out, its calls in $TMP/calls
    : >"$TMP/calls"
    env PATH="$TMP/bin:$PATH" B2B_KEEPER_TMP="$TMP/cc" B2B_KEEPER_ONCE=1 \
        /bin/sh utils/ticket_keeper.sh "$KEEP" "$TMP/monitor.sock" "${1:-$QEMU}" >"$TMP/out" 2>&1
}

in_hours 20 >"$TMP/cc/krb5cc_${U}_login1"
echo expired >"$TMP/cc/krb5cc_${U}_dead"
echo expired >"$TMP/cc/krb5cc_${U}_dead2"
in_hours 30 >"$TMP/cc/krb5cc_${U}_b2b-other"
keeper
check "the valid login ticket is kept (not an expired one, not another VM's)" \
    "$(cat "$KEEP")" "$(cat "$TMP/cc/krb5cc_${U}_login1")"
check "... mode 600" "$(stat -c %a "$KEEP")" 600
check "... and renewed" "$(cat "$TMP/calls")" "kinit -R -c $KEEP"
check "... said once" "$(grep -c "kept the login ticket $TMP/cc/krb5cc_${U}_login1" "$TMP/out")" 1

keeper
check "the same ticket next pass: not copied again" "$(grep -c 'kept the login' "$TMP/out")" 0

in_hours 23 >"$TMP/cc/krb5cc_${U}_login2"
in_hours 5 >"$TMP/cc/krb5cc_${U}_login0"
keeper
check "a later login (renewing longer) is kept; an older one is not" \
    "$(cat "$KEEP")" "$(cat "$TMP/cc/krb5cc_${U}_login2")"

rm -f "$TMP/cc/krb5cc_${U}_login"*
date -d '+25 minutes' '+%m/%d/%y %H:%M:%S' >"$KEEP"
keeper
check "the renew limit within MARGIN + INTERVAL: the power button, on the monitor" \
    "$(grep '^socat' "$TMP/calls")" "socat - UNIX-CONNECT:$TMP/monitor.sock system_powerdown"
check "... said why" "$(grep -c 'cannot be renewed past' "$TMP/out")" 1

date -d '+50 minutes' '+%m/%d/%y %H:%M:%S' >"$KEEP"
keeper
check "the limit past MARGIN + INTERVAL: the guest left running" "$(grep -c '^socat' "$TMP/calls")" 0

: >"$KEEP"
keeper
check "no ticket at all: unknown is not a deadline" "$(grep -c '^socat' "$TMP/calls")" 0

keeper 999999
check "QEMU gone: nothing renewed, nothing pressed" "$(cat "$TMP/calls")" ""
check "... said so" "$(grep -c 'pid 999999 is gone' "$TMP/out")" 1
exit "$fail"
