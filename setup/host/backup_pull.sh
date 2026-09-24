#!/usr/bin/env hellish
# backup_pull.sh — give the guest its restic password, take a backup, and
# pull the repository off the guest, because a backup that only lives in the
# thing it backs up is not one.
#
# THE PASSWORD
#   RESTIC_PASSWORD in .b2b-secrets (mode 600, gitignored). Minted here on
#   first use with openssl, and printed NOWHERE: the file is the record. It
#   travels to the guest over the SSH channel's stdin into a 600 file under
#   /tmp, and install_backup.sh (through provision_vm.sh, which owns the sudo
#   plumbing) moves it to /etc/b2b/restic.pass. Never on a command line, so
#   never in the guest's process list or a log.
#
#   Lose .b2b-secrets and every snapshot is noise. Keep that one line in a
#   password manager too. That is the price of an encrypted backup.
#
# WHERE THE COPY GOES
#   /sgoinfre/dlesieur/b2b-backups/<vm>/repo by default (BACKUP_DEST=…):
#   sgoinfre is off-limits for the VM DISK, by standing rule; a restic
#   repository of a few hundred MB is what it is for. rsync when there is
#   one, scp -r otherwise. The repository is plain files, encrypted at rest,
#   so a copy is a full backup wherever it lands. Next tiers are a USB disk
#   (BACKUP_DEST=/media/…) and B2 -- point restic at them from the copy.
#
#   make backup            password → backup in the guest → pull the repo
#   make backup_verify     … and `restic check` the pulled copy (needs restic here)
#   make restore           push the copy back into a (rebuilt) guest and load the newest snapshot
set -u

# shellcheck source=setup/host/dc_lib.sh
. "$(dirname "${BASH_SOURCE[0]:-$0}")/dc_lib.sh"

# BACKUP_DEST= beats [dc] backup_dest beats the campus default. The default is
# only right on a 42 seat: on a personal machine /sgoinfre does not exist and /
# is not writable, so `make datacenter` used to complete every step and then
# die on `mkdir: cannot create directory '/sgoinfre'` (2026-09-24).
DEST="${BACKUP_DEST:-$(b2b_get B2B_DC_BACKUP_DEST)}"
[ -n "$DEST" ] || DEST="/sgoinfre/$(id -un)/b2b-backups/$VM_NAME"
# $USER and ${USER} are the host login, the same rule ai.models_dir follows, so
# a tracked profile can point at a home directory without naming anybody.
_login=$(id -un)
DEST=${DEST//\$\{USER\}/$_login}
DEST=${DEST//\$USER/$_login}
unset _login
VERIFY="${BACKUP_VERIFY:-0}"
RESTORE=0
case "${1:-}" in --verify) VERIFY=1 ;; --restore) RESTORE=1 ;; esac

dc_connect

pass=$(secret_get RESTIC_PASSWORD)
if [ -z "$pass" ]; then
    pass=$(openssl rand -base64 33 | tr -d '\n=/+' | cut -c1-40)
    [ -n "$pass" ] || die "openssl could not mint a password"
    secret_set RESTIC_PASSWORD "$pass"
    ok "minted RESTIC_PASSWORD into $SECRETS_FILE -- copy that line to a password manager"
fi

# The password reaches the guest by stdin, into a 600 file in /tmp, and
# install_backup.sh moves it into place as root.
remote_tmp="/tmp/.b2b-restic.$$"
printf '%s\n' "$pass" | vm_ssh "umask 077; cat > '$remote_tmp'" || die "could not upload the password"

# --restore: the copy on the host goes BACK into the guest (adopted only if
# the guest has no snapshots of its own), and the newest snapshot is loaded
# into the live engines. This is the rebuild path: `make re`, then this,
# and tenants, keys and rows are where they were.
restore_from=""
if [ "$RESTORE" = 1 ]; then
    [ -d "$DEST/repo/snapshots" ] || die "nothing to restore: no repository at $DEST/repo (BACKUP_DEST=...)"
    restore_from="/tmp/.b2b-repo.$$"
    info "pushing $DEST/repo ($(find "$DEST/repo/snapshots" -type f | wc -l) snapshot(s)) into the guest"
    if command -v rsync >/dev/null 2>&1; then
        rsync -a -e "ssh $SSH_OPTS_STR" "$DEST/repo/" "${VM_USER}@127.0.0.1:$restore_from/" || die "push failed"
    else
        scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -P "$SSH_PORT" \
            "$DEST/repo" "${VM_USER}@127.0.0.1:$restore_from" || die "push failed"
    fi
    info "restoring the newest snapshot into the running engines (the stack restarts)"
else
    info "installing the password and taking a backup in the guest"
fi
BACKUP_PASS_FILE="$remote_tmp" BACKUP_PULL_USER="$VM_USER" BACKUP_VERIFY="$VERIFY" \
    BACKUP_RESTORE="$RESTORE" BACKUP_RESTORE_FROM="$restore_from" \
    VM_PATH="${VM_PATH:-$DC_ROOT/disk_images}" \
    "${SCRIPT_SH:-bash}" "$DC_ROOT/setup/host/provision_vm.sh" "$VM_NAME" backup ||
    die "install_backup.sh reported a problem (read the output above)"
vm_ssh "rm -f '$remote_tmp'" 2>/dev/null || true
if [ "$RESTORE" = 1 ]; then
    ok "restored; the guest's repository now carries the pushed snapshots"
    exit 0
fi

# Never let a young repository replace an older copy: a rebuilt guest's
# repo has ONE snapshot, and rsync --delete would have erased every other
# one on sgoinfre. The copy may only grow.
if [ -d "$DEST/repo/snapshots" ]; then
    have=$(find "$DEST/repo/snapshots" -type f 2>/dev/null | wc -l)
    got=$(vm_ssh 'ls /var/backups/b2b/repo/snapshots 2>/dev/null | wc -l' 2>/dev/null | tr -d '[:space:]')
    if [ "${got:-0}" -lt "$have" ]; then
        die "the guest has ${got:-0} snapshot(s), the copy at $DEST/repo has $have: refusing to overwrite the larger copy. After a rebuild run 'make restore' first, then backup."
    fi
fi

info "pulling the repository to $DEST"
mkdir -p "$DEST" || die "cannot create $DEST"
if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete -e "ssh $SSH_OPTS_STR" "${VM_USER}@127.0.0.1:/var/backups/b2b/repo/" "$DEST/repo/" ||
        die "rsync of the repository failed"
else
    rm -rf "$DEST/repo.new"
    scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -P "$SSH_PORT" \
        "${VM_USER}@127.0.0.1:/var/backups/b2b/repo" "$DEST/repo.new" ||
        die "scp of the repository failed"
    rm -rf "$DEST/repo"
    mv "$DEST/repo.new" "$DEST/repo"
fi
size=$(du -sh "$DEST/repo" 2>/dev/null | cut -f1)
ok "repository copied: $DEST/repo ($size)"

if [ "$VERIFY" = 1 ]; then
    if command -v restic >/dev/null 2>&1; then
        info "restic check on the pulled copy"
        RESTIC_PASSWORD="$pass" restic -r "$DEST/repo" check --read-data-subset=10% ||
            die "the pulled repository FAILED restic check"
        ok "pulled copy verified (10% of data read)"
        RESTIC_PASSWORD="$pass" restic -r "$DEST/repo" snapshots --latest 3 2>/dev/null | tail -n +2
    else
        warn "no restic on the host: the guest ran its own check; to check the copy here, put a restic binary in ~/.local/bin"
    fi
fi
# shellcheck disable=SC2059 # the colour codes are the format, as everywhere in setup/host
printf "  ${C_DIM}restore drill: make restore_drill${C_R}\n"
