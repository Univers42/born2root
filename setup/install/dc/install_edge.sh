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
    ufw allow in on tailscale0 comment 'tailnet' >/dev/null 2>&1 || log "ufw rule for tailscale0 not applied (ufw absent?)"
    if [ -n "${EDGE_TS_AUTHKEY:-}" ]; then
        # The key is passed on the command line to tailscale only, in this
        # process, and never echoed. --ssh off: sshd on 4242 is the audited
        # door, tailscale's own SSH would be a second one.
        if tailscale up --authkey="$EDGE_TS_AUTHKEY" --ssh=false \
            --hostname="${EDGE_TS_HOSTNAME:-$(hostname -s)}" >/dev/null 2>&1; then
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
