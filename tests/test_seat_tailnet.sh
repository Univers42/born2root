#!/usr/bin/env hellish
# The seat joins the tailnet at login, and the key never reaches argv.
#
# Until 2026-10-14 the seat's userspace tailscaled was started by hand every
# session, with the key typed or pasted: the campus resolver blocks *.ts.net,
# so a session that forgot it reached no tailnet name. seat_tailnet.sh writes
# the XDG autostart entry and joins; this pins the entry, the daemon's flags
# (userspace, in-memory state), the key travelling on stdin only, a rerun
# that changes nothing, and the refusals.
#
# HOW: tailscale and tailscaled are stubs on PATH; the daemon "starts" by
# writing NeedsLogin to a state file, `up` turns it into Running. HOME,
# XDG_CONFIG_HOME and XDG_STATE_HOME point into a temp directory.
set -u

cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
TMP=$(mktemp -d)
trap 'rm -rf "${TMP:?}"' EXIT

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s -- got: %s, expected: %s\n' "$1" "$2" "$3"
        fail=1
    fi
}

mkdir -p "$TMP/bin"
cat >"$TMP/bin/tailscaled" <<EOF
#!/bin/sh
printf 'tailscaled %s\n' "\$*" >>"$TMP/calls"
echo NeedsLogin >"$TMP/state"
EOF
cat >"$TMP/bin/tailscale" <<EOF
#!/bin/sh
printf 'tailscale %s\n' "\$*" >>"$TMP/calls"
case "\$*" in
*"status --json"*) [ -f "$TMP/state" ] || exit 1; printf '{\n  "Version": "1.104.1",\n  "BackendState": "%s",\n}\n' "\$(cat "$TMP/state")" ;;
*" up "*) cat >"$TMP/stdin"; [ -f "$TMP/up_fails" ] && exit 1; echo Running >"$TMP/state" ;;
esac
exit 0
EOF
chmod +x "$TMP"/bin/*
KEY="tskey-auth-test-0123456789"
printf 'TS_AUTHKEY=%s\n' "$KEY" >"$TMP/secrets"
chmod 600 "$TMP/secrets"
ENTRY="$TMP/config/autostart/b2b-seat-tailnet.desktop"
SH=$(command -v "${SCRIPT_SH:-bash}")

run() { # [args] -> exit code; output in $TMP/out
    env PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/config" \
        XDG_STATE_HOME="$TMP/state-home" B2B_SECRETS="${SECRETS:-$TMP/secrets}" \
        B2B_CONFIG=profiles/server.toml "$SH" setup/host/seat_tailnet.sh "$@" \
        >"$TMP/out" 2>&1 && echo 0 || echo $?
}

check "make seat_tailnet: joins" "$(run)" 0
check "... the login entry runs this checkout's script with --login" \
    "$(sed -n 's/^Exec=//p' "$ENTRY")" \
    "env B2B_CONFIG=$ROOT/profiles/server.toml B2B_SECRETS=$TMP/secrets $SH $ROOT/setup/host/seat_tailnet.sh --login"
check "... the daemon: userspace, state in memory, proxy on 1055" \
    "$(grep -c '^tailscaled --tun=userspace-networking --state=mem: .*--socks5-server=localhost:1055 --outbound-http-proxy-listen=localhost:1055$' "$TMP/calls")" 1
check "... the key reached tailscale up on stdin" "$(cat "$TMP/stdin")" "$KEY"
check "... and never its argv" "$(grep -c "$KEY" "$TMP/calls")" 0
check "... joined as this seat's short hostname" \
    "$(grep -c "^tailscale .* up --auth-key=file:/dev/stdin --hostname=$(hostname -s) --timeout=60s$" "$TMP/calls")" 1
: >"$TMP/calls"
check "rerun, already Running: succeeds" "$(run --login)" 0
check "... no second daemon, no second join" "$(grep -cE '^tailscaled |^tailscale .* up ' "$TMP/calls")" 0
check "... at login the output goes to the log, not the session" \
    "$(grep -c 'is on the tailnet' "$TMP/state-home/tailscale/seat-tailnet.log")" 1

rm -f "$TMP/state"
printf 'OTHER=1\n' >"$TMP/nokey"
chmod 600 "$TMP/nokey"
check "no TS_AUTHKEY: refused" "$(SECRETS="$TMP/nokey" run)" 1
check "... naming the file" "$(grep -c "no TS_AUTHKEY in $TMP/nokey" "$TMP/out")" 1
chmod 644 "$TMP/secrets"
rm -f "$TMP/state"
check "a world-readable secrets file: refused" "$(run)" 1
chmod 600 "$TMP/secrets"
rm -f "$TMP/state"
touch "$TMP/up_fails"
check "tailscale up failing: an error, not a silent success" "$(run)" 1
rm -f "$TMP/up_fails"

check "make seat_tailnet_undo: succeeds" "$(run --undo)" 0
check "... the entry removed" "$([ -e "$ENTRY" ] && echo kept || echo gone)" gone
exit "$fail"
