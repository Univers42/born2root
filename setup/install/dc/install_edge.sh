#!/usr/bin/env hellish
#
# install_edge.sh — the guest's edge: Tailscale (dc-netmesh) and cloudflared
# (dc-tunnel). Software and units only; no key is ever in the ISO.
#
# WHY AN OUTBOUND EDGE AT ALL
#   The host is a 42 seat behind a campus NAT: 10.12.0.0/16 out through one
#   public address, no port forwarding, ever. The only way in is a connection
#   the guest opens itself. Tailscale is the private plane (collaborators, by
#   ACL, over WireGuard -- relayed through DERP on TCP/443 when the campus
#   blocks UDP, which it does); cloudflared is the public plane (a hostname on
#   a domain, TLS and WAF at Cloudflare's edge, the guest still opening the
#   connection).
#
# WHY NO `tailscale up` HERE
#   An auth key is a secret. This script runs from the ISO at first boot, and
#   the ISO sits unencrypted on the host's disk, so it carries no secret: the
#   key arrives later over SSH (`make tailscale`, which reads .b2b-secrets on
#   the host), and the same is true of the tunnel token. Installed but idle is
#   the correct state for a fresh guest.
#
# WHY UFW GETS tailscale0
#   The guest's firewall is default-deny incoming with 4242/tcp open. A
#   tailnet peer arrives on tailscale0, not on the NAT NIC, and would be
#   dropped. `allow in on tailscale0` admits the private plane as a whole;
#   what a peer may reach is decided in the tailnet ACL, which is the right
#   place -- per person, not per port.
#
# USAGE
#   sudo ./install_edge.sh                      what features.conf says
#   sudo EDGE_NETMESH=1 EDGE_TUNNEL=0 ./install_edge.sh
#   sudo EDGE_TS_AUTHKEY=tskey-... ./install_edge.sh   also brings tailscale up
set -u

FEAT=/etc/b2b/features.conf
on() { grep -qx "B2B_FEATURE_$(printf '%s' "$1" | tr '-' '_')=on" "$FEAT" 2>/dev/null; }
NETMESH="${EDGE_NETMESH:-$(on dc-netmesh && echo 1 || echo 0)}"
TUNNEL="${EDGE_TUNNEL:-$(on dc-tunnel && echo 1 || echo 0)}"

log() { printf '[edge] %s\n' "$*"; }
die() {
    printf '[edge] ERROR: %s\n' "$*" >&2
    exit 1
}
[ "$(id -u)" = 0 ] || die "run as root"

CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME:-trixie}")
export DEBIAN_FRONTEND=noninteractive
install -m 0755 -d /etc/apt/keyrings

# apt_source <list name> <keyring path> <key url> <deb line>
# Adds one third-party source and refreshes it. A repository that has no
# suite for this Debian yet is retried as bookworm, the way the docker
# section of first-boot-setup.sh does: trixie was new for a while.
apt_source() {
    local list="$1" key="$2" url="$3" line="$4"
    curl -fsSL "$url" -o "$key" || return 1
    chmod a+r "$key"
    printf '%s\n' "$line" >"/etc/apt/sources.list.d/$list.list"
    apt-get update -qq -o Dir::Etc::sourcelist="sources.list.d/$list.list" \
        -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0 2>/dev/null
}

if [ "$NETMESH" = 1 ]; then
    log "Tailscale"
    if ! command -v tailscale >/dev/null 2>&1; then
        apt_source tailscale /etc/apt/keyrings/tailscale-archive-keyring.gpg \
            "https://pkgs.tailscale.com/stable/debian/${CODENAME}.noarmor.gpg" \
            "deb [signed-by=/etc/apt/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/debian ${CODENAME} main" ||
            apt_source tailscale /etc/apt/keyrings/tailscale-archive-keyring.gpg \
                "https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg" \
                "deb [signed-by=/etc/apt/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/debian bookworm main" ||
            die "could not add the Tailscale apt source"
        apt-get install -y -qq tailscale || die "apt could not install tailscale"
    fi
    systemctl enable --now tailscaled >/dev/null 2>&1 || die "tailscaled did not start"
    # A node control has dropped stays dropped: on 2026-10-21 a network blip
    # left baas's DERP link back but its control long-poll stuck ("map
    # response long-poll timed out!" every 2 min), the node `offline` to
    # itself, and Funnel resetting every visitor's TLS for 10 minutes until
    # tailscaled was restarted by hand (back in 2 s). A minute timer does that
    # restart; tests/test_tailscale_watchdog.sh cuts the script out by its
    # marker, so keep the `cat >` line and WDEOF as they are.
    cat >/usr/local/sbin/b2b-tailscale-watchdog <<'WDEOF'
#!/bin/sh
# b2b-tailscale-watchdog -- written by install_edge.sh, run every minute by
# b2b-tailscale-watchdog.timer: restart tailscaled once the node has reported
# itself `offline` for 3 checks in a row while the network is up.
# Caveat: `offline` is the node's own view of control. A Funnel ingress that
# fails while control is healthy is not caught (under-reports); a control
# reconnect slower than 3 minutes gets a restart it did not need (over-reports,
# ~2 s without tailnet). At most one restart per 10 minutes.
state=${B2B_TSWD_STATE:-/run/b2b-tailscale-watchdog}
mkdir -p "$state"
case "$(tailscale status --peers=false 2>/dev/null | head -n 1)" in
*" offline"*) count=$(($(cat "$state/count" 2>/dev/null || echo 0) + 1)) ;;
*)
    echo 0 >"$state/count"
    exit 0
    ;;
esac
echo "$count" >"$state/count"
[ "$count" -ge 3 ] || exit 0
# The network itself down: a restart cannot help, and would only add noise.
curl -s -m 10 -o /dev/null 'https://controlplane.tailscale.com/key?v=1' || exit 0
now=$(date +%s)
[ $((now - $(cat "$state/last" 2>/dev/null || echo 0))) -ge 600 ] || exit 0
echo "$now" >"$state/last"
echo 0 >"$state/count"
logger -t b2b-tailscale-watchdog "offline for $count checks with the network up: restarting tailscaled"
systemctl restart tailscaled
WDEOF
    chmod 0755 /usr/local/sbin/b2b-tailscale-watchdog
    printf '[Unit]\nDescription=Restart tailscaled when control has dropped this node\n[Service]\nType=oneshot\nExecStart=/usr/local/sbin/b2b-tailscale-watchdog\n' \
        >/etc/systemd/system/b2b-tailscale-watchdog.service
    printf '[Unit]\nDescription=b2b-tailscale-watchdog every minute\n[Timer]\nOnBootSec=2min\nOnUnitActiveSec=1min\n[Install]\nWantedBy=timers.target\n' \
        >/etc/systemd/system/b2b-tailscale-watchdog.timer
    systemctl daemon-reload
    systemctl enable --now b2b-tailscale-watchdog.timer >/dev/null 2>&1 ||
        log "the tailscaled watchdog timer did not start"
    ufw allow in on tailscale0 comment 'tailnet' >/dev/null 2>&1 || log "ufw rule for tailscale0 not applied (ufw absent?)"
    if [ -n "${EDGE_TS_AUTHKEY:-}" ]; then
        # The key is passed on the command line to tailscale only, in this
        # process, and never echoed. --ssh off: sshd on 4242 is the audited
        # door, tailscale's own SSH would be a second one.
        # --operator: the login may run `tailscale status` and friends without
        # sudo afterwards, which is what verify_platform.sh asks for.
        if tailscale up --authkey="$EDGE_TS_AUTHKEY" --ssh=false \
            --hostname="${EDGE_TS_HOSTNAME:-$(hostname -s)}" \
            ${EDGE_TS_OPERATOR:+--operator="$EDGE_TS_OPERATOR"} >/dev/null 2>&1; then
            log "tailscale is up as $(tailscale ip -4 2>/dev/null | head -n1)"
        else
            die "tailscale up was refused (key expired, or already used?)"
        fi
    else
        log "tailscaled installed and running; not logged in (make tailscale, from the host)"
    fi
else
    log "dc-netmesh off: Tailscale not installed"
fi

if [ "$TUNNEL" = 1 ]; then
    log "cloudflared"
    if ! command -v cloudflared >/dev/null 2>&1; then
        apt_source cloudflared /etc/apt/keyrings/cloudflare-main.gpg \
            "https://pkg.cloudflare.com/cloudflare-main.gpg" \
            "deb [signed-by=/etc/apt/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" ||
            die "could not add the cloudflared apt source"
        apt-get install -y -qq cloudflared || die "apt could not install cloudflared"
    fi
    # Present, not running: a tunnel needs a token that arrives with
    # `make funnel_up` / a domain later. Masking it keeps a package upgrade
    # from starting an unconfigured service.
    systemctl disable --now cloudflared >/dev/null 2>&1 || true
    log "cloudflared installed; no tunnel configured (that is a later, explicit step)"
else
    log "dc-tunnel off: cloudflared not installed"
fi

log "done"
