#!/usr/bin/env hellish
# dc_lib.sh — what every datacenter host script needs: the guest's SSH port
# and login (the way provision_vm.sh finds them), a way to run a command in
# the guest, and the secrets file. Sourced, never run.
#
# THE SECRETS FILE
#   ~/.config/born2root/b2b-secrets by default, KEY=VALUE lines, mode 600.
#   A .b2b-secrets at the repo root is honoured when it exists (ignored by
#   git, `*secret*`), and B2B_SECRETS= names any other path. It lives under
#   $HOME and not beside the repo because the campus wipes /goinfre: on
#   2026-09-20 a wipe took the VM, the repo clone and the file with the
#   restic password, leaving five snapshots on sgoinfre nobody can open.
#   $HOME survived that wipe. It is read with sed, never sourced: a value
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
if [ -n "${B2B_SECRETS:-}" ]; then
    SECRETS_FILE="$B2B_SECRETS"
elif [ -f "$DC_ROOT/.b2b-secrets" ]; then
    SECRETS_FILE="$DC_ROOT/.b2b-secrets"
else
    SECRETS_FILE="$HOME/.config/born2root/b2b-secrets"
fi

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
    mkdir -p "$(dirname "$SECRETS_FILE")"
    tmp=$(mktemp "$(dirname "$SECRETS_FILE")/.b2b-secrets.XXXXXX")
    if [ -f "$SECRETS_FILE" ]; then
        grep -v "^$1=" "$SECRETS_FILE" >"$tmp" || true
    fi
    printf '%s=%s\n' "$1" "$2" >>"$tmp"
    mv "$tmp" "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"
}

# LOOPBACK TUNNELS
#   NAT reaches the guest's NIC (10.0.2.15), never its loopback, so a service
#   the guest binds to 127.0.0.1 reaches the host through `ssh -L` instead;
#   drawnosaurus_host_access.sh's header has the failure in full. Each
#   tunnel is one `ssh -N` with its pid in a file under $VM_PATH/$VM_NAME.

# http_code URL: the HTTP status, 000 when nothing answers. curl -w prints
# 000 itself on a refused connection and exits non-zero, so the old
# `$(curl -w ... || echo 000)` gave 000000: no `000)` case matched it, and
# a tunnel to a stopped drawnosaurus printed "gateway answers HTTP 000000".
http_code() {
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$1" 2>/dev/null)
    printf '%s' "${code:-000}"
}

# tunnel_pid PIDFILE: the tunnel's pid while it runs; nothing, exit 1, if not.
tunnel_pid() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null && cat "$1"; }

# tunnel_close PIDFILE
tunnel_close() {
    local pid
    if pid=$(tunnel_pid "$1"); then
        kill "$pid" 2>/dev/null
        rm -f "$1"
        ok "tunnel closed (was pid $pid)"
    else
        ok "no tunnel to close"
    fi
}

# tunnel_open PIDFILE HINT HOST_PORT:GUEST_PORT...: one `ssh -N` carrying
# every pair, its pid recorded. A host port already taken dies naming HINT,
# the knobs that move it. Call dc_connect first.
#   -N: no command. -f would fork before the forwards are proven; a plain
#   background job with its pid recorded is simpler to stop. Its stdio is
#   detached: a tunnel that keeps the caller's stdout open keeps
#   `make baas_access` from returning (it hung a 90 s timeout the first
#   time). nohup, not setsid: setsid forks when it is not already a group
#   leader, so $! was the short-lived parent, the script declared the
#   tunnel dead, and an orphan kept serving 18000 with no pidfile.
tunnel_open() {
    local pidfile="$1" hint="$2" pair pid
    local forwards=()
    shift 2
    for pair in "$@"; do
        if ss -ltn 2>/dev/null | awk '{ print $4 }' | grep -q ":${pair%%:*}\$"; then
            die "host port ${pair%%:*} is already in use; $hint"
        fi
        forwards+=(-L "127.0.0.1:${pair%%:*}:127.0.0.1:${pair#*:}")
    done
    nohup ssh -N "${SSH_OPTS[@]}" -o ExitOnForwardFailure=yes "${forwards[@]}" \
        "${VM_USER}@127.0.0.1" </dev/null >/dev/null 2>&1 &
    pid=$!
    disown "$pid" 2>/dev/null || true
    sleep 1
    kill -0 "$pid" 2>/dev/null || die "the tunnel exited at once (a forward failed?)"
    printf '%s\n' "$pid" >"$pidfile"
}

# free_forward PORT: remove whatever squats a host port before a tunnel
# binds it: a leftover VirtualBox natpf rule (any name -- an old
# born2root.toml may still list one), or a QEMU hostfwd (recorded only on
# its monitor socket, see vm_ports.sh). Both are always dead for a
# loopback-bound service, so dropping them loses nothing; qemu_vm.sh
# recreates any legitimate one on the next VM start regardless.
free_forward() {
    local port="$1" rule
    if command -v VBoxManage >/dev/null 2>&1 &&
        VBoxManage showvminfo "$VM_NAME" >/dev/null 2>&1; then
        while IFS= read -r rule; do
            [ -n "$rule" ] || continue
            VBoxManage controlvm "$VM_NAME" natpf1 delete "$rule" >/dev/null 2>&1 || true
        done < <(VBoxManage showvminfo "$VM_NAME" --machinereadable 2>/dev/null |
            awk -F'"' '/^Forwarding/ { print $2 }' |
            awk -F',' -v p="$port" '$4 == p { print $1 }')
        return 0
    fi
    ss -ltnp 2>/dev/null | grep -q "127.0.0.1:${port} .*qemu" || return 0
    local sock="$VM_PATH/$VM_NAME/monitor.sock"
    [ -S "$sock" ] || return 0
    python3 - "$sock" "$port" <<'PYEOF' 2>/dev/null
import socket, sys, time
sock, port = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(5)
s.connect(sock)
time.sleep(0.2)
try: s.recv(65536)
except Exception: pass
s.sendall(f"hostfwd_remove tcp:127.0.0.1:{port}\n".encode())
time.sleep(0.2)
s.close()
PYEOF
}
