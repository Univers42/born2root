#!/usr/bin/env hellish
# seat_tailnet.sh — this seat on the tailnet at every login, without root:
# the user's own tailscaled in userspace networking, joined with TS_AUTHKEY.
#   make seat_tailnet        write the login (XDG autostart) entry, join now
#   make seat_tailnet_undo   remove the entry; the seat leaves at logout
#
# WHY USERSPACE, AND AT LOGIN
#   The campus resolver (10.51.1.253) answers nothing for *.ts.net, and a seat
#   gives no root for a TUN device or a system unit. A userspace tailscaled
#   resolves tailnet names itself (MagicDNS) and is reached through its SOCKS5
#   and HTTP proxy on localhost:1055: curl -x socks5h://localhost:1055 ...
#   Its state lives in memory (--state=mem:), so the node is ephemeral: it
#   leaves the tailnet when the daemon ends with the session, and a seat
#   leaves no device behind. The entry brings it back at the next login; it is
#   started by the desktop session (GNOME runs ~/.config/autostart), so an ssh
#   login does not start it.
#
# THE KEY never reaches argv or a log: secret_get (dc_lib.sh) reads it and it
# is piped to `tailscale up --auth-key=file:/dev/stdin`. TS_AUTHKEY must be
# reusable, since every login spends it again. Binaries: tailscale and
# tailscaled on PATH, else ~/.local/bin (GNOME's PATH may lack it).
#
# Caveat: the daemon gets 15 s to answer on its socket and `tailscale up` 60 s
# to join; a slower seat is reported as a failure in the log below though it
# may join later -- rerun make seat_tailnet. A second daemon on the same seat
# (another user's) holds localhost:1055 and this one starts without a proxy.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
# shellcheck source=setup/host/dc_lib.sh
. "$ROOT/setup/host/dc_lib.sh"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/tailscale"
SOCK="$STATE_DIR/tailscaled.sock"
LOG="$STATE_DIR/seat-tailnet.log"
ENTRY="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/b2b-seat-tailnet.desktop"
PROXY="localhost:1055"

ts_bin() {
    command -v "$1" 2>/dev/null && return 0
    [ -x "$HOME/.local/bin/$1" ] && printf '%s\n' "$HOME/.local/bin/$1"
}

backend_state() {
    "$TS" --socket="$SOCK" status --json 2>/dev/null |
        sed -n 's/^ *"BackendState": *"\([A-Za-z]*\)".*/\1/p' | head -n1
}

join() {
    local waited=0 key
    mkdir -p "$STATE_DIR" || die "cannot create $STATE_DIR"
    if [ -z "$(backend_state)" ]; then
        setsid -f "$TSD" --tun=userspace-networking --state=mem: --socket="$SOCK" \
            --socks5-server="$PROXY" --outbound-http-proxy-listen="$PROXY" \
            </dev/null >>"$STATE_DIR/tailscaled.log" 2>&1
        while [ -z "$(backend_state)" ]; do
            [ "$waited" -lt 15 ] || die "tailscaled did not answer on $SOCK within 15 s ($STATE_DIR/tailscaled.log)"
            sleep 1
            waited=$((waited + 1))
        done
    fi
    if [ "$(backend_state)" = Running ]; then
        ok "$(hostname -s) is on the tailnet (proxy $PROXY)"
        return 0
    fi
    key=$(secret_get TS_AUTHKEY)
    [ -n "$key" ] || die "no TS_AUTHKEY in $SECRETS_FILE (a reusable key: .b2b-secrets.example)"
    printf '%s\n' "$key" | "$TS" --socket="$SOCK" up --auth-key=file:/dev/stdin \
        --hostname="$(hostname -s)" --timeout=60s ||
        die "tailscale up failed (an expired or one-off TS_AUTHKEY? $STATE_DIR/tailscaled.log)"
    ok "$(hostname -s) joined the tailnet (proxy $PROXY)"
}

# The entry carries what this run resolved -- the shell, the checkout, the
# profile and the secrets file -- so a login runs exactly this.
write_entry() {
    local value
    for value in "$SH" "$ROOT" "$CONFIG" "$SECRETS_FILE"; do
        case "$value" in
        *[[:space:]%]*) die "'$value' holds a space or a %: a desktop entry's Exec cannot carry it as written; move it or rename it" ;;
        esac
    done
    mkdir -p "$(dirname "$ENTRY")" || die "cannot create $(dirname "$ENTRY")"
    cat >"$ENTRY" <<EOF
[Desktop Entry]
Type=Application
Name=born2root seat tailnet
Comment=This seat's userspace tailscaled, joined at login. Written by $ROOT/setup/host/seat_tailnet.sh (make seat_tailnet)
Exec=env B2B_CONFIG=$CONFIG B2B_SECRETS=$SECRETS_FILE $SH $ROOT/setup/host/seat_tailnet.sh --login
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
    ok "login entry written: $ENTRY"
}

SH=$(command -v "${SCRIPT_SH:-bash}") || die "no ${SCRIPT_SH:-bash} on PATH"
CONFIG="${B2B_CONFIG:-born2root.toml}"
case "$CONFIG" in /*) ;; *) CONFIG="$ROOT/$CONFIG" ;; esac
case "${1:-}" in
--undo)
    rm -f "$ENTRY"
    ok "login entry removed; the seat leaves the tailnet when this session ends"
    printf '  to leave now: tailscale --socket=%s logout\n' "$SOCK"
    exit 0
    ;;
--login)
    mkdir -p "$STATE_DIR" && exec >>"$LOG" 2>&1
    printf '== %s\n' "$(date '+%F %T')"
    ;;
'') ;;
*) die "usage: seat_tailnet.sh [--login | --undo]" ;;
esac
TS=$(ts_bin tailscale) || die "no tailscale on PATH or in ~/.local/bin (the static build from pkgs.tailscale.com)"
TSD=$(ts_bin tailscaled) || die "no tailscaled on PATH or in ~/.local/bin"
[ -n "${1:-}" ] || write_entry
join
