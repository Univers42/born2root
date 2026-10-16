#!/usr/bin/env hellish
# The seat joins the tailnet at login, and the key never reaches argv.
#
# Until 2026-10-14 the seat's userspace tailscaled was started by hand every
# session, with the key typed or pasted: the campus resolver blocks *.ts.net,
# so a session that forgot it reached no tailnet name. seat_tailnet.sh writes
# the XDG autostart entry and joins; this pins the entry, the daemon's flags
# (userspace, in-memory state), the key travelling on stdin only, a rerun
# that changes nothing, and the refusals. Since 2026-10-16 also: the entry
# waits for the home a seat restores after GNOME reads ~/.config/autostart
# (it fired at 14:15:40, ~/born2root appeared at 14:16:25), and a TS_AUTHKEY
# the API says is gone is replaced by a minted one (curl stubbed as the API).
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
check "... the login entry waits for the checkout, then runs it with --login" \
    "$(sed -n 's/^Exec=//p' "$ENTRY")" \
    "timeout 1200 sh -c 'until [ -e $SH ] && [ -e $ROOT/setup/host/seat_tailnet.sh ]; do sleep 2; done; exec env B2B_CONFIG=$ROOT/profiles/server.toml B2B_SECRETS=$TMP/secrets $SH $ROOT/setup/host/seat_tailnet.sh --login'"
# The Exec line run the way GNOME runs it, against a checkout that is not
# there yet: it must still be waiting, not dead, when the home arrives.
mkdir -p "$TMP/late/setup/host"
late=$(sed -n 's/^Exec=//p' "$ENTRY" | sed "s|$ROOT/setup/host/seat_tailnet.sh|$TMP/late/setup/host/seat_tailnet.sh|g; s|timeout 1200|timeout 4|")
eval "$late" >/dev/null 2>&1
check "... with the home not restored yet it waits (timeout, not 'No such file')" "$?" 124
printf '#!/bin/sh\necho ran "$@" >"%s/late-ran"\n' "$TMP" >"$TMP/late/setup/host/seat_tailnet.sh"
eval "$late" >/dev/null 2>&1
check "... and runs it once it appears" "$(cat "$TMP/late-ran" 2>/dev/null)" "ran --login"
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

# A revoked key with an OAuth client beside it: the API answers 200 with
# "invalid": true (its real answer for the key revoked 2026-10-15), a new key
# is minted, stored (mode 600) and used -- never printed.
cat >"$TMP/bin/curl" <<EOF
#!/bin/bash
cat >/dev/null
out=/dev/stdout method=GET url=
while [ \$# -gt 0 ]; do
    case "\$1" in
    -o) out=\$2; shift ;;
    -X) method=\$2; shift ;;
    http*) url=\$1 ;;
    esac
    shift
done
printf '%s %s\n' "\$method" "\${url#*api/v2/}" >>"$TMP/api"
case "\$method \$url" in
*oauth/token) printf '{"access_token":"tok"}' ;;
"GET "*/keys/kOld) printf '{"id":"kOld","revoked":"2026-10-15T11:22:19Z","invalid":true}' >"\$out"; printf 200 ;;
"GET "*/keys/kGone) printf '{"message":"not found"}' >"\$out"; printf 404 ;;
"GET "*/keys/kLive) printf '{"id":"kLive","invalid":false}' >"\$out"; printf 200 ;;
"POST "*/keys) printf '{"key":"tskey-auth-kNew-fresh0123456789"}' >"\$out"; printf 200 ;;
*) printf 500 ;;
esac
EOF
chmod +x "$TMP/bin/curl"
printf 'TS_AUTHKEY=tskey-auth-kOld-revoked0123\nTS_OAUTH_CLIENT_ID=cid\nTS_OAUTH_CLIENT_SECRET=csec\n' >"$TMP/oauth"
chmod 600 "$TMP/oauth"
rm -f "$TMP/state"
check "a revoked key and an OAuth client: joins" "$(SECRETS="$TMP/oauth" run)" 0
check "... asked the API about the old key, then minted" \
    "$(grep -c -e '^GET tailnet/-/keys/kOld$' -e '^POST tailnet/-/keys$' "$TMP/api")" 2
check "... joined with the minted key" "$(cat "$TMP/stdin")" tskey-auth-kNew-fresh0123456789
check "... stored in the secrets file" "$(sed -n 's/^TS_AUTHKEY=//p' "$TMP/oauth")" tskey-auth-kNew-fresh0123456789
check "... which stays mode 600" "$(stat -c %a "$TMP/oauth")" 600
check "... and the key is not in the output" "$(grep -c fresh0123 "$TMP/out")" 0
for case in "kGone:minted:a deleted key (404)" "kLive:kept:a live key"; do
    id=${case%%:*} rest=${case#*:}
    printf 'TS_AUTHKEY=tskey-auth-%s-0123456789\nTS_OAUTH_CLIENT_ID=cid\nTS_OAUTH_CLIENT_SECRET=csec\n' "$id" >"$TMP/oauth"
    rm -f "$TMP/state"
    SECRETS="$TMP/oauth" run >/dev/null
    got=kept
    [ "$(cat "$TMP/stdin")" = tskey-auth-kNew-fresh0123456789 ] && got=minted
    check "${rest#*:}: ${rest%%:*}" "$got" "${rest%%:*}"
done
rm -f "$TMP/bin/curl"

check "make seat_tailnet_undo: succeeds" "$(run --undo)" 0
check "... the entry removed" "$([ -e "$ENTRY" ] && echo kept || echo gone)" gone
exit "$fail"
