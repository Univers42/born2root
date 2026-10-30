#!/usr/bin/env hellish
# vm_share.sh — lets a colleague work in this VM over the tailnet, invited by
# email, while the VM cannot reach the host. The make share_* targets:
#   share_wall [PORTS="3001 8787 4000"]   wall the VM off the host (once)
#   share_policy                          the tailnet grants sharing needs (once)
#   share_invite GUEST= EMAIL= [KEY=]     account + Tailscale invite [DOCKER=0]
#   share_key GUEST= KEY=                 the key of a guest invited without one
#   share_kit GUEST=                      their connect script, sh and PowerShell
#   share_revoke GUEST=                   lock the account, delete the invite
#   share_list                            who is invited, who accepted
#   share                                 re-apply everyone (after a rebuild,
#                                         or to give older guests their home)
#
# THE WAY IN: Tailscale device sharing. The invite mails EMAIL a link;
#   whoever accepts sees this one machine in their own tailnet and nothing
#   else of yours, and a shared machine cannot open a connection back to
#   them. What they may open on it is the tailnet policy's call:
#   ts_share_policy.py gives autogroup:shared tcp:4242 (sshd) on tag:b2b, and
#   tagged machines -- the VMs -- no grant as a source at all, the half that
#   keeps a VM from reaching the host over the tailnet. In the guest each
#   colleague has an account of their own, key only, in the docker group
#   unless DOCKER=0, and in group dev: grobase's tree is the team's and a
#   short sudo list its upkeep (vm_share_guest.sh). share_kit writes
#   $VM_DIR/guests/<login>-connect.sh and .ps1 (vm_share_connect.*), which
#   set up `ssh <vm>` on their machine; anything else (grobase's ports) they
#   carry over that ssh session. Each account also gets what first boot
#   gives the login: its Neovim and hellish's configuration (guest_home);
#   and a cap on what it may consume, no reach to the host, and no claude or
#   opencode (guest_limits, vm_share_limits.sh). Invited without KEY=, the
#   account has no key and the kit makes one on their machine and prints its
#   public half: share_key registers it, and the same kit then connects.
#
# THE WALL (vm_wall.sh, root, through sudo): QEMU's network is the host's own
#   sockets, so the VM reaches every host listener unless the host refuses.
#   share_wall writes $VM_DIR/wall (the host ports the VM may still open) and
#   qemu_vm.sh reloads the wall before every launch, refusing to boot a walled
#   VM it cannot wall. An invite refuses a VM whose wall is not up. Nothing
#   changes for the host's connections into the VM (ssh b2b, forwards).
#   ssh b2b's RemoteForward of the host's Chrome (9222) is dropped while
#   anyone is invited: a guest root could otherwise drive that browser.
#
# THE LIST: $VM_DIR/guests/<login>.email and <login>.pub (empty until the
#   key is known), beside the VM
#   (a rebuild through fclean empties it, together with the VM).
#
# Caveat: an ephemeral node comes back as a new device after a rebuild or a
# long outage, and shares belong to the device; `make share` invites everyone
# again (a new mail each). Deleting an invite already accepted may leave the
# share listed in the recipient's tailnet; the locked account is what ends the
# access. The tailnet auth key travels to the guest when it logs in again
# (make tailscale), where a guest root can read it: rotate TS_AUTHKEY after
# revoking someone you no longer trust.
set -u
# shellcheck source=setup/host/dc_lib.sh
. "$(dirname "${BASH_SOURCE[0]:-$0}")/dc_lib.sh"
# shellcheck source=setup/host/ts_api.sh
. "$DC_ROOT/setup/host/ts_api.sh"
VM_DIR="${VM_PATH:?VM_PATH is set by the Makefile}/$VM_NAME"
GUESTS="$VM_DIR/guests"
WALL_FILE="$VM_DIR/wall"
WALL_BIN="${B2B_WALL_BIN:-/usr/local/sbin/b2b-vm-wall}"
UNIT="b2b-vm-$VM_NAME.service"

wall_up() { sudo -n "$WALL_BIN" status "$VM_NAME" 2>/dev/null; }
qemu_pid() { kill -0 "$(cat "$VM_DIR/qemu.pid" 2>/dev/null)" 2>/dev/null && cat "$VM_DIR/qemu.pid"; }
guest_logins() { for f in "$GUESTS"/*.email; do [ -f "$f" ] && basename "$f" .email; done; }

share_wall() {
    local pid p
    [ -x "$WALL_BIN" ] || die "install the wall once: sudo bash $DC_ROOT/setup/host/vm_wall.sh install"
    for p in $1; do
        case "$p" in *[!0-9]*) die "PORTS: '$p' is not a port" ;; esac
    done
    [ -n "$1" ] || [ ! -f "$WALL_FILE" ] || set -- "$(cat "$WALL_FILE")"
    printf '%s\n' "$1" >"$WALL_FILE"
    if ! pid=$(qemu_pid); then
        ok "$VM_NAME walled from its next start (host ports open to it: ${1:-none})"
        return 0
    fi
    grep -q "/$UNIT\$" "/proc/$pid/cgroup" ||
        die "$VM_NAME runs outside $UNIT, where it cannot be walled: make qemu_stop GRACEFUL=1, then systemctl --user start $UNIT (make autostart writes the unit)"
    xargs sudo -n "$WALL_BIN" apply "$VM_NAME" <"$WALL_FILE" || die "the wall did not load"
}

share_wall_off() {
    [ -z "$(guest_logins)" ] || die "revoke the guests first (make share_list)"
    rm -f "$WALL_FILE"
    sudo -n "$WALL_BIN" drop "$VM_NAME"
    ok "$VM_NAME no longer walled"
}

# acl_call GET|POST BASE: the policy as HuJSON, comments kept. GET writes
# BASE and its headers BASE.hdr; POST sends BASE.new with If-Match on that
# ETag, so an edit made meanwhile in the admin console is refused, not lost.
acl_call() {
    local args=(-s --max-time 30 -K - -X "$1" -H 'Accept: application/hujson' -w '%{http_code}')
    if [ "$1" = POST ]; then
        args+=(-o "$2.out" -H 'Content-Type: application/hujson' --data-binary "@$2.new"
            -H "If-Match: $(sed -n 's/^[Ee][Tt]ag: *//p' "$2.hdr" | tr -d '\r')")
    else
        args+=(-o "$2" -D "$2.hdr")
    fi
    API_CODE=$(printf 'user = "%s:"\n' "$API_TOKEN" | curl "${args[@]}" "$TS_API/tailnet/-/acl" 2>/dev/null) || API_CODE=000
    case "$API_CODE" in 2??) return 0 ;; esac
    return 1
}

# policy_state BASE: 3 when the grants are in place, 0 when they can be put
# in (the edit in BASE.new), 2 when the policy was written by hand.
policy_state() {
    ts_api_token || die "no Tailscale API credential (TS_API_TOKEN or TS_OAUTH_*) in $SECRETS_FILE"
    acl_call GET "$1" || die "cannot read the tailnet policy: $(ts_api_refusal "$API_CODE")"
    python3 "$DC_ROOT/setup/host/ts_share_policy.py" "$1" >"$1.new"
}

share_policy() {
    local tmp rc
    tmp=$(mktemp)
    policy_state "$tmp"
    rc=$?
    case "$rc" in
    3) ok "the tailnet policy already has the sharing grants" ;;
    0)
        cp "$tmp" "$VM_DIR/acl.before-share.hujson"
        diff "$tmp" "$tmp.new"
        acl_call POST "$tmp" ||
            die "the tailnet refused the policy ($API_CODE): $(head -c 300 "$tmp.out")"
        ok "tailnet policy updated (the old one: $VM_DIR/acl.before-share.hujson)"
        ;;
    *) die "the tailnet policy was not changed" ;;
    esac
    rm -f "$tmp" "$tmp".*
}

# api_get PATH: the body on stdout, or the script ends naming the code. Not
# in a pipe: API_CODE would stay in the pipe's subshell.
api_get() {
    local out
    out=$(mktemp)
    ts_api GET "$1" >"$out" || {
        rm -f "$out"
        die "the Tailscale API answered $API_CODE to GET $1"
    }
    cat "$out"
    rm -f "$out"
}

# device_id: the VM's node, found by the address make tailnet recorded.
device_id() {
    local ip devices
    ip=$(sed -n 's/^TS_IP4=//p' "$VM_DIR/tailnet.env" 2>/dev/null)
    [ -n "$ip" ] || die "$VM_NAME has no tailnet.env: run make tailnet first"
    devices=$(api_get "tailnet/-/devices") || exit 1
    printf '%s' "$devices" | python3 -c 'import json, sys
ids = [d["id"] for d in json.load(sys.stdin).get("devices", []) if sys.argv[1] in d.get("addresses", [])]
print(ids[0] if ids else "")' "$ip"
}

# invites DEVICE: one "id email accepted-by" line per invite.
invites() {
    local list
    list=$(api_get "device/$1/device-invites") || exit 1
    printf '%s' "$list" | python3 -c 'import json, sys
print("\n".join("%s %s %s" % (i["id"], i.get("email") or "-",
    (i.get("acceptedBy") or {}).get("loginName") or "pending") for i in json.load(sys.stdin) or []))'
}

ensure_invite() {
    local dev="$1" email="$2" list body out url reason
    list=$(invites "$dev") || exit 1
    if printf '%s\n' "$list" | awk -v e="$email" '$2 == e {found=1} END {exit !found}'; then
        ok "$email already invited"
        return 0
    fi
    body=$(python3 -c 'import json, sys
print(json.dumps([{"email": sys.argv[1], "multiUse": False, "allowExitNode": False}]))' "$email")
    out=$(mktemp)
    # Measured 2026-10-25: the OAuth client is refused here (400, "API access
    # token must be user-owned"), where every other call takes it.
    ts_api POST "device/$dev/device-invites" "$body" >"$out" || {
        reason=$(ts_json message <"$out")
        rm -f "$out"
        case "$reason" in
        *user-owned*) die "Tailscale invites only with a user's API access token, not the OAuth client: generate one at https://login.tailscale.com/admin/settings/keys, add TS_API_TOKEN=tskey-api-... to $SECRETS_FILE and run make share (or share $VM_NAME by hand: admin/machines, its ... menu, Share)" ;;
        esac
        die "Tailscale refused the invite for $email ($API_CODE: ${reason:-no reason given})"
    }
    url=$(python3 -c 'import json, sys
print((json.load(sys.stdin) or [{}])[0].get("inviteUrl", ""))' <"$out")
    rm -f "$out"
    ok "invite mailed to $email (link: ${url:-in the mail})"
}

guest_account() {
    ROOTSH_ACTION="$1" ROOTSH_LOGIN="$2" ROOTSH_KEY="${3:-}" ROOTSH_DOCKER="${DOCKER:-1}" \
        ROOT_SH="$DC_ROOT/setup/host/vm_share_guest.sh" \
        "${SCRIPT_SH:-bash}" "$DC_ROOT/setup/host/provision_vm.sh" "$VM_NAME" root-sh
}

# guest_ready LOGIN KEY: the account, read back -- root-sh does not hand
# back the script's status.
guest_ready() {
    guest_account add "$1" "$2"
    [ "$(vm_ssh "getent passwd $1 | cut -d: -f5" 2>/dev/null)" = "b2b guest" ] ||
        die "no guest account $1 in $VM_NAME (output above)"
}

# guest_home LOGIN: what first boot gives every account born2root.toml names
# and an account made later never got -- the login's Neovim and hellish
# configuration, linked to the login's one copy (install_home_shared.sh) --
# read back as root (vm_share_guest.sh home), for the same reason as
# guest_ready. A guest built without the editor skips the first half.
guest_home() {
    local login="$1" verdict
    SHARE_USERS="$login" "${SCRIPT_SH:-bash}" "$DC_ROOT/setup/host/provision_vm.sh" "$VM_NAME" home-shared
    verdict=$(guest_account home "$login" | tr -d '\r' | grep "^home $login: ")
    [ "$verdict" = "home $login: ok" ] || die "${verdict:-no home verdict for $login} in $VM_NAME (output above)"
    ok "$login has the login's Neovim and hellish configuration"
}

# guest_limits: what every colleague account may consume in the guest -- a
# cgroup cap, no reach to the host, claude and opencode the owner's
# (vm_share_limits.sh says why and what passes it) -- set again for all of
# them, so a new account is covered and a revoked one dropped.
guest_limits() {
    local verdict
    verdict=$(ROOT_SH="$DC_ROOT/setup/host/vm_share_limits.sh" \
        "${SCRIPT_SH:-bash}" "$DC_ROOT/setup/host/provision_vm.sh" "$VM_NAME" root-sh | tr -d '\r' | grep '^limits: ')
    [ -n "$verdict" ] || die "the guest limits were not applied in $VM_NAME (output above)"
    ok "${verdict#limits: }"
}

# share_kit LOGIN: the two connect scripts, the @...@ fields filled. Every
# value is checked before it reaches sed: login and VM name by pattern, the
# key reduced to its type and base64 (a comment could hold the delimiter).
share_kit() {
    local login="$1" ip key ext
    [ -f "$GUESTS/$login.pub" ] || die "no guest '$login' (make share_list)"
    ip=$(sed -n 's/^TS_IP4=//p' "$VM_DIR/tailnet.env" 2>/dev/null)
    case "$ip" in '' | *[!0-9.]*) die "$VM_NAME has no tailnet address: run make tailnet first" ;; esac
    key=$(awk 'NR == 1 {print $1, $2}' "$GUESTS/$login.pub")
    case "$key" in *[!A-Za-z0-9+/=\ -]*) die "$GUESTS/$login.pub is not a public key line" ;; esac
    for ext in sh ps1; do
        sed -e "s|@ALIAS@|$VM_NAME|g" -e "s|@HOST@|$ip|g" -e "s|@PORT@|4242|g" \
            -e "s|@LOGIN@|$login|g" -e "s|@PUBKEY@|$key|g" \
            "$DC_ROOT/setup/host/vm_share_connect.$ext" >"$GUESTS/$login-connect.$ext" ||
            die "cannot write $GUESTS/$login-connect.$ext"
    done
    ok "send $login: $GUESTS/$login-connect.sh (Linux, macOS) and $GUESTS/$login-connect.ps1 (Windows)"
}

# other_guest_uses EMAIL LOGIN: another listed guest shares the email.
other_guest_uses() {
    grep -lxF "$1" "$GUESTS"/*.email 2>/dev/null | grep -qv "/$2\.email\$"
}

invite_email() {
    local dev
    dev=$(device_id) || exit 1
    [ -n "$dev" ] || die "the tailnet does not list $VM_NAME's node: make tailscale"
    ensure_invite "$dev" "$1"
}

share_invite() {
    local login="$1" email="$2" key="$3" tmp
    case "$login" in '' | [!a-z]* | *[!a-z0-9_-]*) die "GUEST= a lowercase account name" ;; esac
    [ "$login" != "$VM_USER" ] || die "GUEST=$login is your own account in the guest"
    case "$email" in *@*.*) ;; *) die "EMAIL= the address their Tailscale login uses" ;; esac
    case "$email" in *[[:space:]]*) die "EMAIL= holds a space" ;; esac
    key=$(public_key "$key") || die "KEY= their public key, as a file or the line itself (or nothing)"
    wall_up || die "$VM_NAME is not walled off the host: make share_wall first"
    tmp=$(mktemp)
    policy_state "$tmp"
    [ "$?" = 3 ] || die "the tailnet still lets the VM reach your devices: make share_policy first"
    rm -f "$tmp" "$tmp".*
    dc_connect
    guest_ready "$login" "$key"
    guest_home "$login"
    guest_limits
    # Listed as soon as the account exists, so a refused invite still leaves
    # it where make share retries and make share_revoke finds it.
    mkdir -p "$GUESTS"
    printf '%s\n' "$email" >"$GUESTS/$login.email"
    # Empty, not a lone newline, when the key comes later: share_list tells
    # them apart by size.
    printf '%s' "${key:+$key
}" >"$GUESTS/$login.pub"
    invite_email "$email"
    share_kit "$login"
}

# public_key KEY: the key line from a file or the line itself; empty stays
# empty, anything else that is not one public key fails.
public_key() {
    local key="$1"
    [ ! -f "$key" ] || key=$(head -n1 "$key")
    [ -z "$key" ] || printf '%s\n' "$key" | ssh-keygen -l -f - >/dev/null 2>&1 || return 1
    printf '%s\n' "$key"
}

share_key() {
    local login="$1" key
    [ -f "$GUESTS/$login.email" ] || die "no guest '$login' (make share_list)"
    key=$(public_key "$2") || key=''
    [ -n "$key" ] || die "KEY= their public key, as a file or the line itself"
    dc_connect
    guest_ready "$login" "$key"
    printf '%s\n' "$key" >"$GUESTS/$login.pub"
    share_kit "$login"
}

share_revoke() {
    local login="$1" email dev id
    [ -f "$GUESTS/$login.email" ] || die "no guest '$login' (make share_list)"
    email=$(cat "$GUESTS/$login.email")
    dc_connect
    guest_account lock "$login"
    ts_api_token || die "no Tailscale API credential in $SECRETS_FILE"
    dev=$(device_id) || exit 1
    # The invite is the email's, not the login's: another guest of the same
    # person keeps it, or revoking a test login would unshare their real one.
    if other_guest_uses "$email" "$login"; then
        ok "invite for $email kept: another guest uses it"
    elif [ -n "$dev" ]; then
        for id in $(invites "$dev" | awk -v e="$email" '$2 == e {print $1}'); do
            ts_api DELETE "device-invites/$id" >/dev/null && ok "invite for $email deleted"
        done
    fi
    rm -f "$GUESTS/$login.email" "$GUESTS/$login.pub" "$GUESTS/$login-connect".*
    ok "$login revoked (home kept in the guest)"
}

share_list() {
    local login dev=''
    [ -n "$(guest_logins)" ] || {
        info "nobody invited to $VM_NAME"
        return 0
    }
    ts_api_token && dev=$(device_id)
    for login in $(guest_logins); do
        printf '  %-16s %s%s\n' "$login" "$(cat "$GUESTS/$login.email")" \
            "$([ -s "$GUESTS/$login.pub" ] || echo "  (no key yet: make share_key GUEST=$login KEY=)")"
    done
    [ -z "$dev" ] || invites "$dev" | awk 'NF {printf "  invite %-30s %s\n", $2, $3}'
    printf '  wall: %s\n' "$(wall_up && echo up || echo DOWN)"
}

share_apply() {
    local login
    wall_up || die "$VM_NAME is not walled off the host: make share_wall first"
    ts_api_token || die "no Tailscale API credential in $SECRETS_FILE"
    dc_connect
    guest_account workspace "$VM_USER"
    for login in $(guest_logins); do
        guest_ready "$login" "$(cat "$GUESTS/$login.pub")"
        guest_home "$login"
        invite_email "$(cat "$GUESTS/$login.email")"
        share_kit "$login"
    done
    guest_limits
}

case "${1:-}" in
wall) share_wall "${PORTS:-}" ;;
wall-off) share_wall_off ;;
policy) share_policy ;;
invite) share_invite "${GUEST:-}" "${EMAIL:-}" "${KEY:-}" ;;
kit) share_kit "${GUEST:-}" ;;
key) share_key "${GUEST:-}" "${KEY:-}" ;;
revoke) share_revoke "${GUEST:-}" ;;
list) share_list ;;
apply) share_apply ;;
*) die "usage: $0 wall|wall-off|policy|invite|key|kit|revoke|list|apply" ;;
esac
