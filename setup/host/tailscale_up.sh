#!/usr/bin/env hellish
# tailscale_up.sh — log the guest into the tailnet, with a key that never
# touched the ISO.
#
# install_edge.sh (first boot) installed tailscaled and left it logged out,
# on purpose: the ISO is on the host's disk in the clear. This is the other
# half. The auth key comes from .b2b-secrets (TS_AUTHKEY=...), or is asked
# for once when a terminal is attached and then saved there, mode 600.
#
# The key goes to the guest through provision_vm.sh's provisioner path
# (sudo handled, env quoted) as EDGE_TS_AUTHKEY, and install_edge.sh passes
# it to `tailscale up` in that one process. Make the key EPHEMERAL and
# PRE-AUTHORIZED in the admin console: the node vanishes from the tailnet
# when the guest is rebuilt, and nothing has to be approved by hand.
#
#   make tailscale                  log in (idempotent: an up node stays up)
#   make tailscale TS_AUTHKEY=...   one-shot key, not saved
set -u

# shellcheck source=setup/host/dc_lib.sh
. "$(dirname "${BASH_SOURCE[0]:-$0}")/dc_lib.sh"

dc_connect

state=$(vm_ssh "tailscale status --json 2>/dev/null | sed -n 's/.*\"BackendState\": *\"\\([A-Za-z]*\\)\".*/\\1/p' | head -n1" 2>/dev/null || true)
case "$state" in
Running)
    ok "already up: $(vm_ssh 'tailscale ip -4 2>/dev/null | head -n1')  ($(vm_ssh 'tailscale status --json 2>/dev/null | sed -n "s/.*\"DNSName\": *\"\([^\"]*\)\".*/\1/p" | head -n1'))"
    exit 0
    ;;
'')
    die "tailscaled is not answering in the guest -- was the guest built with dc-netmesh on? (make edge installs it)"
    ;;
esac

key="${TS_AUTHKEY:-$(secret_get TS_AUTHKEY)}"
if [ -z "$key" ]; then
    if [ -t 0 ] && [ -t 1 ]; then
        printf "\n  Tailscale auth key (ephemeral, pre-authorized; from https://login.tailscale.com/admin/settings/keys)\n  key: "
        stty -echo 2>/dev/null
        read -r key
        stty echo 2>/dev/null
        printf '\n'
        [ -n "$key" ] || die "no key given"
        secret_set TS_AUTHKEY "$key"
        ok "saved to $SECRETS_FILE (mode 600)"
    else
        die "no TS_AUTHKEY in $SECRETS_FILE and no terminal to ask on"
    fi
fi

info "logging the guest in (state was: ${state:-unknown})"
EDGE_TS_AUTHKEY="$key" EDGE_NETMESH=1 EDGE_TUNNEL=0 EDGE_TS_OPERATOR="$VM_USER" \
    VM_PATH="${VM_PATH:-$DC_ROOT/disk_images}" \
    "${SCRIPT_SH:-bash}" "$DC_ROOT/setup/host/provision_vm.sh" "$VM_NAME" edge ||
    die "install_edge.sh did not bring tailscale up. A key generated without REUSABLE is spent by the first VM that used it -- after a rebuild, generate a new one (Reusable + Ephemeral + Pre-approved) and put it in $SECRETS_FILE (see .b2b-secrets.example)"

ip=$(vm_ssh 'tailscale ip -4 2>/dev/null | head -n1' || true)
if [ -n "$ip" ]; then
    ok "guest is on the tailnet as $ip"
else
    warn "logged in, but no IPv4 yet -- tailscale status in the guest"
fi
