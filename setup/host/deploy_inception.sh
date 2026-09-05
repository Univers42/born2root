#!/usr/bin/env bash
# ============================================================================ #
#  born2root — put the Inception project into the VM and bring it up           #
# ============================================================================ #
#
# Everything here runs from the HOST and drives the guest over `ssh b2b`, the
# alias orchestrate.sh already generates. Nothing has to be typed inside the VM.
#
#   make inception                     clone from GitHub, build, verify
#   make inception SRC=/path/to/repo   push a local copy up instead
#
# Why a source override exists: work done inside the VM that was never committed
# is invisible to `git clone`. Pointing SRC at a host-side copy (a backup, or a
# working tree pulled off the old VM) reproduces the stack exactly as it ran,
# uncommitted changes included.
#
# The one sudo the guest needs — inception's `make setup` appends the domain to
# the guest's /etc/hosts — is done here first with the VM passphrase, because a
# non-interactive ssh session has no tty for sudo to prompt on. After that the
# grep guard in inception's Makefile makes its own sudo line a no-op.
# ============================================================================ #

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

VM_NAME="${VM_NAME:-debian}"
DOMAIN="${INCEPTION_DOMAIN:-dlesieur.42.fr}"
GUEST_USER="${GUEST_USER:-dlesieur}"
GUEST_DIR="${INCEPTION_DIR:-/home/${GUEST_USER}/Documents/inception}"
REPO_URL="${INCEPTION_REPO:-https://github.com/Univers42/Inception.git}"
BRANCH="${INCEPTION_BRANCH:-main}"
SRC="${INCEPTION_SRC:-${SRC:-}}"

SSH_ALIAS="${SSH_ALIAS:-b2b}"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_BLUE=$'\033[34m'
C_RED=$'\033[31m'
C_DIM=$'\033[2m'

step() { printf "\n${C_BLUE}▶${C_RESET} ${C_BOLD}%s${C_RESET}\n" "$*"; }
ok() { printf "  ${C_GREEN}✓${C_RESET} %s\n" "$*"; }
warn() { printf "  ${C_YELLOW}⚠${C_RESET}  %s\n" "$*"; }
die() {
    printf "  ${C_RED}✗${C_RESET} %s\n" "$*" >&2
    exit 1
}

vm_ssh() { ssh "${SSH_OPTS[@]}" "$SSH_ALIAS" "$@"; }

# ── The guest sudo password ─────────────────────────────────────────────────
# NOT the same secret as vm_pass.txt: that one is the LUKS passphrase typed at
# boot, while sudo wants the dlesieur account password the installer set from
# preseeds/preseed.cfg. Reading it back out of the preseed keeps the two in
# step if either is ever changed.
PRESEED_FILE="${PRESEED_FILE:-$REPO_ROOT/preseeds/preseed.cfg}"
resolve_pass() {
    local p
    if [ -n "${GUEST_PASS:-}" ]; then
        printf '%s' "$GUEST_PASS"
        return 0
    fi
    if [ -r "$PRESEED_FILE" ]; then
        p=$(awk '$1 == "d-i" && $2 == "passwd/user-password" { print $4; exit }' "$PRESEED_FILE")
        [ -n "$p" ] && {
            printf '%s' "$p"
            return 0
        }
    fi
    if [ -r "$REPO_ROOT/vm_pass.txt" ]; then
        head -n1 "$REPO_ROOT/vm_pass.txt" | tr -d '\r\n'
        return 0
    fi
    return 1
}

# ── 1. Wait until the guest answers ─────────────────────────────────────────
step "Waiting for the VM to accept SSH (${SSH_ALIAS})"
deadline=$(($(date +%s) + 300))
until vm_ssh true 2>/dev/null; do
    [ "$(date +%s)" -lt "$deadline" ] || die "VM never became reachable over ssh ${SSH_ALIAS}. Try: make start_vm"
    sleep 5
done
ok "guest reachable: $(vm_ssh 'hostname' 2>/dev/null)"

# ── 2. Toolchain the build needs ────────────────────────────────────────────
# sshd comes up well before the guest is actually provisioned: first-boot
# installs Docker, adds the user to the docker group and fetches wp-cli, which
# takes a couple of minutes. Connecting the moment ssh answers and then failing
# because docker is not there yet is a race, not a real error — so wait for it.
step "Waiting for guest provisioning (docker, git, openssl, make, rsync)"
provision_deadline=$(($(date +%s) + ${PROVISION_TIMEOUT:-900}))
reported=""
while :; do
    missing=$(vm_ssh 'for c in git docker openssl make rsync; do command -v $c >/dev/null 2>&1 || echo $c; done' 2>/dev/null)
    if [ -z "$missing" ] && vm_ssh 'docker info >/dev/null 2>&1'; then
        break
    fi
    if [ "$(date +%s)" -ge "$provision_deadline" ]; then
        die "guest still not provisioned (missing: ${missing:-docker daemon}). Check: ssh ${SSH_ALIAS} sudo tail /var/log/first-boot.log"
    fi
    # Report what is still missing, but only when it changes, so the wait reads
    # as progress instead of a wall of identical lines.
    state="${missing:-docker daemon not ready}"
    if [ "$state" != "$reported" ]; then
        printf "  ${C_YELLOW}…${C_RESET} still waiting on: %s\n" "$(printf '%s' "$state" | tr '\n' ' ')"
        reported="$state"
    fi
    sleep 10
done
ok "git, docker, openssl, make, rsync all present and docker is usable"

# ── 3. Get the sources into the guest ───────────────────────────────────────
if [ -n "$SRC" ]; then
    [ -d "$SRC" ] || die "SRC='$SRC' is not a directory"
    step "Uploading local sources from $SRC"
    vm_ssh "mkdir -p '$GUEST_DIR'" || die "could not create $GUEST_DIR"
    # --delete so the guest ends up an exact mirror; excluding runtime state
    # that must not travel between machines.
    rsync -az --delete \
        --exclude '.git/index.lock' \
        -e "ssh ${SSH_OPTS[*]}" \
        "${SRC%/}/" "${SSH_ALIAS}:${GUEST_DIR}/" ||
        die "rsync of sources failed"
    ok "sources uploaded to ${GUEST_DIR}"
else
    step "Cloning ${REPO_URL} (branch ${BRANCH}) into the guest"
    vm_ssh "set -e
        if [ -d '$GUEST_DIR/.git' ]; then
            cd '$GUEST_DIR' && git fetch --all -q && git checkout -q '$BRANCH' && git pull -q --ff-only
        else
            mkdir -p \"\$(dirname '$GUEST_DIR')\"
            git clone -q --branch '$BRANCH' '$REPO_URL' '$GUEST_DIR'
        fi" || die "clone/pull failed"
    ok "repository present at ${GUEST_DIR}"
fi

# ── 4. Guest-side domain resolution (the subject's own requirement) ─────────
step "Ensuring ${DOMAIN} resolves inside the guest"
if vm_ssh "grep -q '$DOMAIN' /etc/hosts" 2>/dev/null; then
    ok "/etc/hosts already maps ${DOMAIN}"
else
    pass=$(resolve_pass) || die "no guest password (set GUEST_PASS, or check $PRESEED_FILE)"
    # The guest's sudoers sets requiretty: without -tt sudo refuses outright with
    # "you must have a tty to run sudo", whatever is piped at it. -tt allocates
    # one, and -S then reads the passphrase from that tty.
    printf '%s\n' "$pass" |
        ssh "${SSH_OPTS[@]}" -tt "$SSH_ALIAS" \
            "sudo -S -p '' sh -c 'grep -q \"$DOMAIN\" /etc/hosts || echo \"127.0.0.1 ${DOMAIN}\" >> /etc/hosts'" \
            >/dev/null 2>&1
    if vm_ssh "grep -q '$DOMAIN' /etc/hosts" 2>/dev/null; then
        ok "added 127.0.0.1 ${DOMAIN} to the guest's /etc/hosts"
    else
        warn "could not write /etc/hosts non-interactively — inception's own sudo line will handle it"
    fi
fi

# ── 5. Build ────────────────────────────────────────────────────────────────
if [ "${NO_BUILD:-0}" = "1" ]; then
    warn "NO_BUILD=1 — skipping the build"
else
    step "Building the Inception stack (this takes a few minutes)"
    # -tt so docker's build output streams live rather than arriving in one lump
    # at the end; without a tty the whole build looks like a hang.
    ssh "${SSH_OPTS[@]}" -tt "$SSH_ALIAS" "cd '$GUEST_DIR' && make" 2>&1 |
        sed 's/^/    /'
    # PIPESTATUS[0] is ssh's own status; the pipe through sed would otherwise
    # always report success.
    [ "${PIPESTATUS[0]}" -eq 0 ] || die "inception build failed inside the guest"
    ok "stack built"
fi

# ── 6. Verify from inside the guest ─────────────────────────────────────────
step "Verifying from inside the guest"
vm_ssh "docker ps --format '{{.Names}}\t{{.Status}}'" 2>/dev/null | sed 's/^/    /'
guest_https=$(vm_ssh "curl -ks -o /dev/null -w '%{http_code}' --max-time 10 https://${DOMAIN}/" 2>/dev/null)
guest_static=$(vm_ssh "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://${DOMAIN}:8090/" 2>/dev/null)
[ "$guest_https" = "200" ] && ok "guest https://${DOMAIN}/ → 200" ||
    warn "guest https://${DOMAIN}/ → ${guest_https:-no response}"
[ "$guest_static" = "200" ] && ok "guest http://${DOMAIN}:8090/ → 200" ||
    warn "guest http://${DOMAIN}:8090/ → ${guest_static:-no response}"

# ── 7. Wire up the host and verify from there too ───────────────────────────
step "Configuring host access"
VM_NAME="$VM_NAME" INCEPTION_DOMAIN="$DOMAIN" bash "$HERE/inception_host_access.sh"

step "Verifying from the host"
bash "$HERE/verify_inception_access.sh"
