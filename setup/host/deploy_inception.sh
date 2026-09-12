#!/usr/bin/env hellish
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

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

VM_NAME="${VM_NAME:-debian}"
DOMAIN="${INCEPTION_DOMAIN:-dlesieur.42.fr}"
GUEST_USER="${GUEST_USER:-dlesieur}"
GUEST_DIR="${INCEPTION_DIR:-/home/${GUEST_USER}/Documents/inception}"
REPO_URL="${INCEPTION_REPO:-https://github.com/Univers42/Inception.git}"
BRANCH="${INCEPTION_BRANCH:-main}"
SRC="${INCEPTION_SRC:-${SRC:-}}"

SSH_ALIAS="${SSH_ALIAS:-b2b}"
# ClearAllForwardings because the `Host b2b` block orchestrate.sh writes carries
# LocalForward 8420/8421 (Neovim's markdown preview and Excalidraw, for
# interactive sessions). Every short-lived ssh here re-binds them, and once one
# session or an `ssh -f -N b2b` holds them the rest print five lines of
# "Address already in use / Could not request local forwarding" each -- 25 lines
# of what reads as failure in one `make inception`, over forwards none of these
# command connections use.
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR -o ClearAllForwardings=yes)

C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_BLUE=$'\033[34m'
C_RED=$'\033[31m'
# shellcheck disable=SC2034
C_DIM=$'\033[2m'

step() { printf "\n${C_BLUE}▶${C_RESET} ${C_BOLD}%s${C_RESET}\n" "$*"; }
ok() { printf "  ${C_GREEN}✓${C_RESET} %s\n" "$*"; }
warn() { printf "  ${C_YELLOW}⚠${C_RESET}  %s\n" "$*"; }
die() {
    printf "  ${C_RED}✗${C_RESET} %s\n" "$*" >&2
    exit 1
}

# shellcheck disable=SC2029
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
    # shellcheck disable=SC2016
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

# ── 2b. Is there room for the stack? ────────────────────────────────────────
# Inception with bonus is nine alpine images, a Rust build stage, three volumes
# and docker's build cache, all on /var. Measured on the host that built it:
# 2.35 GB of build cache alone. The VM's /var was sized for this at ISO-build
# time (generate/feature_profile.sh, feature `docker`), but a VM built before
# that, or one that has been used for a while, may not have it -- and docker
# does not fail cleanly when /var fills mid-build, it corrupts layers and the
# error arrives from a different container minutes later. So: check first,
# and refuse with the numbers rather than let the build discover it.
INCEPTION_VAR_NEED_MB="${INCEPTION_VAR_NEED_MB:-3300}"
step "Checking /var has room for the stack (${INCEPTION_VAR_NEED_MB} MB)"
var_free_mb=$(vm_ssh "df -Pm /var 2>/dev/null | awk 'NR==2 {print \$4}'" 2>/dev/null | tr -d '\r')
var_size_mb=$(vm_ssh "df -Pm /var 2>/dev/null | awk 'NR==2 {print \$2}'" 2>/dev/null | tr -d '\r')
docker_used=$(vm_ssh "docker system df --format '{{.Type}} {{.Size}}' 2>/dev/null | tr '\n' ' '" 2>/dev/null | tr -d '\r')
case "$var_free_mb" in
'' | *[!0-9]*) warn "could not read /var free space in the guest — continuing without the check" ;;
*)
    if [ "$var_free_mb" -lt "$INCEPTION_VAR_NEED_MB" ]; then
        printf "    /var: %s MB free of %s MB   docker: %s\n" "$var_free_mb" "$var_size_mb" "${docker_used:-nothing yet}"
        printf "\n    Free some:  ssh %s 'docker system prune -af && docker builder prune -af'\n" "$SSH_ALIAS"
        printf "    Or trim:    make slim      Or rebuild bigger:  make all SIZE_B2B=20\n"
        printf "    Or, if you know better:  INCEPTION_VAR_NEED_MB=%s make inception\n\n" "$var_free_mb"
        die "/var has ${var_free_mb} MB free; the stack needs about ${INCEPTION_VAR_NEED_MB} MB"
    fi
    ok "/var: ${var_free_mb} MB free of ${var_size_mb} MB${docker_used:+  (docker now: $docker_used)}"
    ;;
esac

# ── 3. Get the sources into the guest ───────────────────────────────────────
if [ -n "$SRC" ]; then
    [ -d "$SRC" ] || die "SRC='$SRC' is not a directory"
    step "Uploading local sources from $SRC"
    vm_ssh "mkdir -p '$GUEST_DIR'" || die "could not create $GUEST_DIR"
    # A submodule or a linked worktree keeps its repository elsewhere and
    # leaves a one-line .git FILE pointing at it: a dangling pointer once
    # copied, after which every `git` in the compliance suite fails. Such a
    # tree travels without it and the guest gets a repository of its own
    # below -- the host's origin, one commit holding what was uploaded.
    synth_repo=0
    origin_url=""
    rsync_extra=()
    if [ ! -d "$SRC/.git" ]; then
        synth_repo=1
        rsync_extra=(--exclude=/.git)
        origin_url=$(git -C "$SRC" remote get-url origin 2>/dev/null || true)
    fi
    # --delete so the guest ends up an exact mirror of the sources; but
    # secrets/ and srcs/.env are RUNTIME state the guest generated (random
    # passwords, the TLS material), not sources -- deleting and letting
    # `make setup` mint new ones on every upload rotates the credentials out
    # from under a MariaDB that is still running on the old ones, and the stack
    # desyncs. Exclude keeps them, so a redeploy re-uses what is already there;
    # a first deploy has neither and setup makes them once. An excluded path is
    # also left alone on the guest, which likewise keeps the repository made
    # below across uploads. vendor/ is a submodule of dev tooling: a real
    # `make inception` clones non-recursively, so it is an empty gitlink there
    # and never scanned -- inlining its files would only feed the compliance
    # suite's credential scan third-party Python, so it does not travel.
    rsync -az --delete \
        --exclude '.git/index.lock' \
        --exclude '/secrets/' --exclude '/srcs/.env' \
        --exclude '/vendor/' \
        ${rsync_extra[@]+"${rsync_extra[@]}"} \
        -e "ssh ${SSH_OPTS[*]}" \
        "${SRC%/}/" "${SSH_ALIAS}:${GUEST_DIR}/" ||
        die "rsync of sources failed"
    ok "sources uploaded to ${GUEST_DIR}"
    if [ "$synth_repo" = 1 ]; then
        if vm_ssh "cd '$GUEST_DIR' && { [ -d .git ] || { rm -f .git && git init -q -b main; }; } \
            && { [ -z '$origin_url' ] || git remote get-url origin > /dev/null 2>&1 || git remote add origin '$origin_url'; } \
            && git add -A && { git diff --cached --quiet \
                || git -c user.name=born2root -c user.email=born2root@localhost commit -q -m 'working tree uploaded from $(hostname)'; }" 2>/dev/null; then
            ok "the uploaded tree is a repository of its own (origin: ${origin_url:-none})"
        else
            warn "could not make a repository of the uploaded tree"
        fi
    fi
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

# ── 3b. Dockerfiles the parser cannot read ──────────────────────────────────
# Docker ends a line continuation AT the backslash: whatever follows it on the
# same line is not a comment, it is the end of the instruction. Upstream's
# nginx Dockerfile carries five such inline notes plus two editor artifacts
# (a stray `+`, a literal `<F6>`), so its RUN block is cut in two and the
# second half is read as an instruction of its own:
#
#     ERROR: dockerfile parse error on line 16: unknown instruction: :
#
# nginx is the first image compose builds, so the stack dies there and nothing
# below this point ever runs. Measured 2026-09-12 from a pristine clone of
# Univers42/Inception main (2e2962b) inside the b2r guest; 9e74aaa has the same
# defect. It breaks `make inception` for every build that does not happen to
# carry a local fix in the uploaded tree -- which is exactly what was lost the
# last time /goinfre was wiped.
#
# So: find the broken continuations before the build, and repair the guest's
# working copy from fixes/inception-nginx-dockerfile.patch while that patch
# still applies. The real home for the fix is a commit in Univers42/Inception,
# which is why the patch says so about itself. INCEPTION_NO_PATCH=1 refuses
# instead of repairing.
step "Checking the Dockerfiles parse"
DOCKERFILE_PATCH="${INCEPTION_PATCH:-$REPO_ROOT/fixes/inception-nginx-dockerfile.patch}"
# A bracket expression holds the backslash, so nothing here has to survive two
# rounds of shell quoting on the way to the guest's grep.
scan_continuations() {
    vm_ssh "grep -rnE '[\\][[:space:]]+[^[:space:]]' '$GUEST_DIR/srcs' --include=Dockerfile" 2>/dev/null
}
broken=$(scan_continuations)
if [ -z "$broken" ]; then
    ok "every Dockerfile ends its continuations at the backslash"
else
    printf '%s\n' "$broken" | sed "s|^${GUEST_DIR}/|    |"
    warn "$(printf '%s\n' "$broken" | grep -c .) line(s) continue past the backslash — docker cannot parse that"
    [ "${INCEPTION_NO_PATCH:-0}" = "1" ] &&
        die "INCEPTION_NO_PATCH=1 — nothing was repaired. Fix the lines above in the Inception repo."
    [ -r "$DOCKERFILE_PATCH" ] ||
        die "no patch at $DOCKERFILE_PATCH — fix the lines above in the Inception repo"
    if vm_ssh "cd '$GUEST_DIR' && git apply --check -" <"$DOCKERFILE_PATCH" 2>/dev/null &&
        vm_ssh "cd '$GUEST_DIR' && git apply -" <"$DOCKERFILE_PATCH" 2>/dev/null; then
        ok "applied $(basename "$DOCKERFILE_PATCH") to the guest's working copy"
    else
        die "$(basename "$DOCKERFILE_PATCH") no longer applies — upstream moved; fix the lines above in the Inception repo"
    fi
    broken=$(scan_continuations)
    if [ -n "$broken" ]; then
        printf '%s\n' "$broken" | sed "s|^${GUEST_DIR}/|    |"
        die "still unparseable after the patch — the lines above need fixing in the Inception repo"
    fi
    ok "the Dockerfiles parse now (commit the patch in Inception to make it stick)"
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
            "sudo -S -p '' \"\$(command -v hellish.real 2>/dev/null || echo sh)\" -c 'grep -q \"$DOMAIN\" /etc/hosts || echo \"127.0.0.1 ${DOMAIN}\" >> /etc/hosts'" \
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
    # The guest's login shell is /usr/bin/hellish, a link to hellish.real
    # (see preseeds/b2b-setup.sh). Inception's Makefile runs its recipes and
    # its test suite with the shell make was launched from, and also copies
    # that shell into the containers as /bin/sh when it is static -- so name
    # the ELF explicitly rather than trusting the probe behind a pty. A guest
    # without hellish.real is unchanged.
    real=$(vm_ssh 'command -v hellish.real 2>/dev/null' 2>/dev/null | tr -d '\r')
    [ -z "$real" ] || ok "the stack builds under ${real}"
    # -tt so docker's build output streams live rather than arriving in one lump
    # at the end; without a tty the whole build looks like a hang.
    ssh "${SSH_OPTS[@]}" -tt "$SSH_ALIAS" "cd '$GUEST_DIR' && make ${real:+SCRIPT_SH=$real}" 2>&1 |
        sed 's/^/    /'
    # PIPESTATUS[0] is ssh's own status; the pipe through sed would otherwise
    # always report success.
    [ "${PIPESTATUS[0]}" -eq 0 ] || die "inception build failed inside the guest"
    ok "stack built"

    # The build cache is the single biggest thing on /var after a build (2.35
    # GB measured) and it is only useful for the NEXT build. On a disk sized
    # to the quota it is what tips a full /var, so it goes now that the images
    # exist; a rebuild simply pays the cache back. Then say what is left, in
    # the same units feature_profile.sh estimates in, so a wrong estimate is
    # visible here rather than in a failed deploy later.
    vm_ssh "docker builder prune -af >/dev/null 2>&1 || true"
    printf "    after the build:\n"
    vm_ssh "docker system df 2>/dev/null" | sed 's/^/      /'
    vm_ssh "df -h /var | tail -1 | awk '{print \"      /var: \" \$3 \" used, \" \$4 \" free (\" \$5 \")\"}'" 2>/dev/null
fi

# ── 6. Verify from inside the guest ─────────────────────────────────────────
step "Verifying from inside the guest"
vm_ssh "docker ps --format '{{.Names}}\t{{.Status}}'" 2>/dev/null | sed 's/^/    /'
guest_https=$(vm_ssh "curl -ks -o /dev/null -w '%{http_code}' --max-time 10 https://${DOMAIN}/" 2>/dev/null)
guest_static=$(vm_ssh "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://${DOMAIN}:8090/" 2>/dev/null)
if [ "$guest_https" = "200" ]; then
    ok "guest https://${DOMAIN}/ → 200"
else
    warn "guest https://${DOMAIN}/ → ${guest_https:-no response}"
fi
if [ "$guest_static" = "200" ]; then
    ok "guest http://${DOMAIN}:8090/ → 200"
else
    warn "guest http://${DOMAIN}:8090/ → ${guest_static:-no response}"
fi

# ── 7. Wire up the host and verify from there too ───────────────────────────
step "Configuring host access"
VM_NAME="$VM_NAME" INCEPTION_DOMAIN="$DOMAIN" "${SCRIPT_SH:-bash}" "$HERE/inception_host_access.sh"

step "Verifying from the host"
"${SCRIPT_SH:-bash}" "$HERE/verify_inception_access.sh"
