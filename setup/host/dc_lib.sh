#!/usr/bin/env hellish
# dc_lib.sh — what every datacenter host script needs: the guest's SSH port
# and login (the way provision_vm.sh finds them), a way to run a command in
# the guest, and the secrets file. Sourced, never run.
#
# THE SECRETS FILE
#   .b2b-secrets at the repo root, KEY=VALUE lines, mode 600, ignored by git
#   (`*secret*` in .gitignore). It is read with sed, never sourced: a value
#   is data, not shell. born2root.toml is tracked and tests fail on a literal
#   credential in it, which is why the Tailscale key, the restic password
#   and the tunnel token live here and only here. Keys:
#     TS_AUTHKEY        Tailscale auth key (ephemeral, pre-authorized, tagged)
#     RESTIC_PASSWORD   the restic repository password (backup_pull mints one)
#     CF_TUNNEL_TOKEN   cloudflared tunnel token, when a domain exists
#
# WHY NOT RE-USE provision_vm.sh WHOLESALE
#   It is an entry point, not a library: it resolves the VM, probes sudo and
#   dispatches on $2 at load. What is shared is small and copied here on
#   purpose, with the same names, so the two read alike.
set -u

DC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
SECRETS_FILE="${B2B_SECRETS:-$DC_ROOT/.b2b-secrets}"

C_R='\033[0m'
# shellcheck disable=SC2034 # for the scripts that source this
C_B='\033[1m'
C_GRN='\033[32m'
C_YEL='\033[33m'
C_RED='\033[31m'
C_BLU='\033[34m'
# shellcheck disable=SC2034 # for the scripts that source this
C_DIM='\033[2m'
info() { printf "${C_BLU}▶${C_R} %s\n" "$*"; }
ok() { printf "${C_GRN}✓${C_R} %s\n" "$*"; }
warn() { printf "${C_YEL}!${C_R} %s\n" "$*"; }
die() {
    printf "${C_RED}✗${C_R} %s\n" "$*" >&2
    exit 1
}

# shellcheck source=utils/b2b_config.sh
. "$DC_ROOT/utils/b2b_config.sh"
# shellcheck source=setup/host/vm_ports.sh
. "$DC_ROOT/setup/host/vm_ports.sh"

VM_NAME="${VM_NAME:-$(b2b_get B2B_VM_NAME)}"
[ -n "$VM_NAME" ] || VM_NAME=debian
VM_USER="${VM_USER:-$(b2b_get B2B_LOGIN)}"
[ -n "$VM_USER" ] || VM_USER=$(id -un)

# dc_connect: resolve the SSH port and prove the guest answers. Called by the
# scripts, not at source time, so a script can print usage without a VM.
dc_connect() {
    SSH_PORT=$(vm_forward_port ssh 2>/dev/null) || SSH_PORT=
    [ -n "$SSH_PORT" ] || die "VM \"$VM_NAME\" has no 'ssh' forward -- is it running? (make qemu_status)"
    # An array, as provision_vm.sh does: hellish does not word-split an
    # unquoted string, and a quoted one would be a single bogus argument.
    SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
        -o LogLevel=ERROR -o ConnectTimeout=15 -p "$SSH_PORT")
    # The same options as one string, for rsync -e, which takes a command line.
    # shellcheck disable=SC2034 # backup_pull.sh reads it
    SSH_OPTS_STR="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=15 -p $SSH_PORT"
    if ! ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${VM_USER}@127.0.0.1" true 2>/dev/null; then
        die "cannot reach ${VM_USER}@127.0.0.1:${SSH_PORT} with key auth"
    fi
}
# vm_ssh <cmd...>: run in the guest as the login. No pty: output stays clean.
# The command string is composed here and expanded there, on purpose.
# shellcheck disable=SC2029
vm_ssh() { ssh "${SSH_OPTS[@]}" "${VM_USER}@127.0.0.1" "$@"; }
# vm_ssh_tty: for sudo, which the subject's `Defaults requiretty` demands.
# shellcheck disable=SC2029
vm_ssh_tty() { ssh -tt "${SSH_OPTS[@]}" "${VM_USER}@127.0.0.1" "$@" | tr -d '\r'; }

# secret_get KEY: the value, or empty. Refuses a world-readable file.
secret_get() {
    [ -f "$SECRETS_FILE" ] || return 0
    local mode
    mode=$(stat -c %a "$SECRETS_FILE" 2>/dev/null)
    case "$mode" in 600 | 400) ;; *) die "$SECRETS_FILE is mode $mode; make it 600 (chmod 600 $SECRETS_FILE)" ;; esac
    sed -n "s/^$1=//p" "$SECRETS_FILE" | head -n1
}
# secret_set KEY VALUE: replace or append one line, keeping the rest.
secret_set() {
    local tmp
    umask 077
    tmp=$(mktemp "$DC_ROOT/.b2b-secrets.XXXXXX")
    if [ -f "$SECRETS_FILE" ]; then
        grep -v "^$1=" "$SECRETS_FILE" >"$tmp" || true
    fi
    printf '%s=%s\n' "$1" "$2" >>"$tmp"
    mv "$tmp" "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"
}
