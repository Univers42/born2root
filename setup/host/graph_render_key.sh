#!/usr/bin/env hellish
# graph_render_key.sh — give the guest's graph_render a key, and keep it.
#
# WHERE THE KEY LIVES
#   The server stores hashes only: one `<name> <sha256>` line per key in
#   the guest's /etc/graph-render/keys. The key itself lives in the secrets
#   file as GRAPH_RENDER_KEY, beside the line it hashes to as
#   GRAPH_RENDER_KEY_LINE, and is printed nowhere. That pair is what
#   survives a rebuild: a new guest gets the stored line back and every
#   client keeps its key, the reason tenant_key.sh keeps a key that still
#   authenticates.
#
# WHY THE GUEST'S IMAGE MINTS IT
#   The key format and its hash exist once, in the server (`graph-server
#   keygen`, graph_render docs/contract/service-api.md), so the key is made
#   by the image the guest runs, with no network, and never re-derived here.
#
# HOW IT GETS IN
#   The line goes to install_graph_render.sh as GRAPH_RENDER_KEY_LINE
#   through provision_vm.sh (sudo handled, env quoted), which appends it and
#   starts the container or has it re-read the file (SIGHUP). Then the
#   proof: 200 on /v1/meta with the key, 401 without.
#
#   make graph_render_key                             keep, restore, or mint ("ops")
#   make graph_render_key GRAPH_RENDER_KEY_NAME=ci    the name a minted key gets
set -u

# shellcheck source=setup/host/dc_lib.sh
. "$(dirname "${BASH_SOURCE[0]:-$0}")/dc_lib.sh"

KEY_NAME="${GRAPH_RENDER_KEY_NAME:-ops}"
case "$KEY_NAME" in '' | *[!A-Za-z0-9._-]*) die "GRAPH_RENDER_KEY_NAME must be letters, digits, . _ - (got '$KEY_NAME')" ;; esac

dc_connect
service=$(vm_ssh 'cat /etc/graph-render/service 2>/dev/null' | tr -d '\r')
image=$(printf '%s\n' "$service" | sed -n 's/^image=//p')
port=$(printf '%s\n' "$service" | sed -n 's/^port=//p')
if [ -z "$image" ] || [ -z "$port" ]; then
    if vm_ssh 'grep -qx B2B_FEATURE_dc_graph_render=on /etc/b2b/features.conf' 2>/dev/null; then
        die "dc-graph-render is on but not installed in the guest (first boot failed? make graph_render_install)"
    fi
    ok "dc-graph-render is off in this guest: no key to keep (make graph_render_install adds it)"
    exit 0
fi

# The HTTP code of GET /v1/meta, with the key (read on the guest side, from
# stdin, so it is on no command line) or without one.
# shellcheck disable=SC2016 # $k is expanded by the guest's shell, on purpose
meta_with() {
    printf '%s\n' "$1" | vm_ssh 'read -r k; curl -s -o /dev/null -w "%{http_code}" --max-time 8 -H "Authorization: Bearer $k" http://127.0.0.1:'"$port"'/v1/meta' 2>/dev/null | tr -d '[:space:]'
}
meta_without() {
    vm_ssh "curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:$port/v1/meta" 2>/dev/null | tr -d '[:space:]'
}

key=$(secret_get GRAPH_RENDER_KEY)
line=$(secret_get GRAPH_RENDER_KEY_LINE)
if [ -n "$key" ] && [ "$(meta_with "$key")" = 200 ]; then
    ok "the stored key authenticates (HTTP 200); nothing minted"
    exit 0
fi
if [ -n "$key" ] && [ -n "$line" ]; then
    info "giving the guest the stored key's line ('${line%% *}')"
else
    info "minting key '$KEY_NAME' with the guest's image"
    out=$(vm_ssh "docker run --rm --network none '$image' keygen '$KEY_NAME' 2>&1") || die "keygen failed in the guest"
    key=$(printf '%s\n' "$out" | grep -E '^gm_[A-Za-z0-9_-]{43}$' | head -n1)
    line=$(printf '%s\n' "$out" | grep -E "^$KEY_NAME [0-9a-f]{64}\$" | head -n1)
    if [ -z "$key" ] || [ -z "$line" ]; then
        die "keygen printed no key and file line (has the format changed? graph_render docs/contract/service-api.md)"
    fi
    secret_set GRAPH_RENDER_KEY "$key"
    secret_set GRAPH_RENDER_KEY_LINE "$line"
    ok "key '$KEY_NAME' minted; saved to $SECRETS_FILE as GRAPH_RENDER_KEY"
fi
GRAPH_RENDER_KEY_LINE="$line" "${SCRIPT_SH:-bash}" "$DC_ROOT/setup/host/provision_vm.sh" "$VM_NAME" graph-render ||
    die "the guest did not take the key line (output above)"
with=$(meta_with "$key")
without=$(meta_without)
if [ "$with" != 200 ] || [ "$without" != 401 ]; then
    die "/v1/meta answered ${with:-000} with the key and ${without:-000} without (want 200 and 401); to mint a fresh key, delete GRAPH_RENDER_KEY from $SECRETS_FILE and rerun"
fi
ok "graph_render: 200 with the key, 401 without; the key is GRAPH_RENDER_KEY in $SECRETS_FILE"
