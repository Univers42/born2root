#!/usr/bin/env hellish
# backup_pull.sh — give the guest its restic password, take a backup, and
# pull the repository off the guest, because a backup that only lives in the
# thing it backs up is not one.
#
# THE PASSWORD
#   RESTIC_PASSWORD in the secrets file (dc_lib.sh: B2B_SECRETS=, [dc]
#   secrets_file, ...; mode 600). Minted here on first use with openssl --
#   never for a restore, never beside an existing repository -- and printed
#   NOWHERE: the file is the record. It
#   travels to the guest over the SSH channel's stdin into a 600 file under
#   /tmp, and install_backup.sh (through provision_vm.sh, which owns the sudo
#   plumbing) moves it to /etc/b2b/restic.pass. Never on a command line, so
#   never in the guest's process list or a log.
#
#   Lose that file and every snapshot is noise. Keep that one line in a
#   password manager too. That is the price of an encrypted backup.
#
# WHERE THE COPY GOES
#   /sgoinfre/students/<login>/b2b-backups/<vm>/repo by default (BACKUP_DEST=…).
#   rsync when there is one, scp -r otherwise. The repository is plain files,
#   encrypted at rest, so a copy is a full backup wherever it lands.
#   [dc] backup_mirror is a second copy on a different device: on a 42 seat the
#   VM and the first copy share one NFS server, so a mirror on /goinfre is what
#   survives losing it. Further tiers are a USB disk (BACKUP_DEST=/media/…) and
#   B2 -- point restic at them from the copy.
#
# WHAT THE PULL WILL NOT DO
#   Replace the copy with another repository, or let the guest shrink it by
#   more than half: both refused, see pull_refusal below. What rsync would
#   delete or overwrite moves to $DEST/attic/<stamp> for BACKUP_ATTIC_DAYS, so a
#   guest that goes bad cannot take the host's copy with it within the hour.
#
#   make backup            password → backup in the guest → pull the repo
#   make backup_verify     … and `restic check` the pulled copy (needs restic here)
#   make restore           push the copy back into a (rebuilt) guest and load the newest snapshot
#   make restore SNAPSHOT=<id>   ... and load that snapshot instead
#   backup_pull.sh --where print where the copy is (what `make datacenter` checks)
set -u

# shellcheck source=setup/host/dc_lib.sh
. "$(dirname "${BASH_SOURCE[0]:-$0}")/dc_lib.sh"
# shellcheck source=utils/nfs_link.sh
. "$(dirname "${BASH_SOURCE[0]:-$0}")/../../utils/nfs_link.sh"

# rsync's share of the link to an NFS destination, the budget QEMU's disk
# takes too (utils/nfs_link.sh): --bwlimit is in KiB/s. An array, because
# hellish does not split an unquoted expansion into words.
RSYNC_CAP=()
rsync_cap() {
    local bps
    bps=$(nfs_disk_budget "$1")
    RSYNC_CAP=()
    [ -z "$bps" ] || RSYNC_CAP=("--bwlimit=$((bps / 1024))")
}

# pull_refusal <copy id> <guest id> <copy snapshots> <guest snapshots>: why this
# pull must not happen, or nothing. The id is the repository's `config` file,
# which restic writes once at init and never again: a rebuilt guest's fresh
# repository has another one, and that, not a count, is the case this guards.
#
# It used to be `guest count < copy count`, and retention breaks that: under
# keep-hourly 24 / daily 14 / weekly 8 the count wobbles by one or two around
# midnight, so from day 14 the guest was usually one behind the copy's high-water
# mark. Modelled hour by hour over 70 days it refused 1165 of 1680 pulls, and
# 167 of the last 168: the copy froze with nothing but a line in backup.log.
# Half stays as the floor because a bad guest forgets snapshots too.
# Caveat: the id says which repository, not that it is healthy. Same config with
# rewritten packs passes here; the attic and `make backup_verify` cover that.
pull_refusal() {
    if [ -n "$1" ] && [ "$1" != "$2" ]; then
        printf 'the guest holds a different repository than the copy (a rebuilt guest): run make restore first, then backup'
    elif [ "$(($4 * 2))" -lt "$3" ] && [ "${BACKUP_ALLOW_SHRINK:-0}" != 1 ]; then
        printf 'the guest kept %s of the copy'"'"'s %s snapshots, and retention never drops half: BACKUP_ALLOW_SHRINK=1 if that was you' "$4" "$3"
    fi
}

# BACKUP_DEST= beats [dc] backup_dest beats the campus default. The default
# lives here and only here: /sgoinfre/students/<login>, like every other
# sgoinfre path in the repo, and it is only right on a 42 seat: on a personal
# machine /sgoinfre does not exist and / is not writable, so `make datacenter`
# used to complete every step and then die on `mkdir: cannot create directory
# '/sgoinfre'` (2026-09-24). It used to be /sgoinfre/<login> while `make
# datacenter` looked under students/, so the rebuild path never found the copy
# `make backup` had made; a copy at the old path is still the one used when
# there is none at the new one.
# $USER/$HOME expand, and a list resolves, by the one rule the profile's paths
# follow (utils/host_path.py), so BACKUP_DEST='/media/$USER/b' works too.
if [ -n "${BACKUP_DEST:-}" ]; then
    DEST=$(b2b_host_path "$BACKUP_DEST")
else
    DEST=$(b2b_get B2B_DC_BACKUP_DEST)
fi
_login=$(id -un)
if [ -z "$DEST" ]; then
    DEST="/sgoinfre/students/$_login/b2b-backups/$VM_NAME"
    legacy_dest="/sgoinfre/$_login/b2b-backups/$VM_NAME"
    if [ ! -d "$DEST/repo" ] && [ -d "$legacy_dest/repo" ]; then
        DEST=$legacy_dest
    fi
fi
unset _login
VERIFY="${BACKUP_VERIFY:-0}"
RESTORE=0
case "${1:-}" in
--verify) VERIFY=1 ;;
--restore) RESTORE=1 ;;
--where)
    printf '%s\n' "$DEST"
    exit 0
    ;;
esac

# A password is minted only when there is nothing it would have to open: a
# restore, or a repository already at DEST, needs the one it was made with,
# and a new one would lock the next backup out of the repository too.
# Checked before the guest is touched.
pass=$(secret_get RESTIC_PASSWORD)
if [ -z "$pass" ]; then
    if [ "$RESTORE" = 1 ] || [ -e "$DEST/repo/config" ]; then
        die "no RESTIC_PASSWORD in $SECRETS_FILE, and $([ "$RESTORE" = 1 ] && echo 'a restore' || echo "the repository at $DEST/repo") needs the password it was made with: put that RESTIC_PASSWORD line back in $SECRETS_FILE (mode 600), or name the file that has it ([dc] secrets_file, or B2B_SECRETS=)"
    fi
    pass=$(openssl rand -base64 33 | tr -d '\n=/+' | cut -c1-40)
    [ -n "$pass" ] || die "openssl could not mint a password"
    secret_set RESTIC_PASSWORD "$pass"
    ok "minted RESTIC_PASSWORD into $SECRETS_FILE -- copy that line to a password manager"
fi

dc_connect

# Inside the hourly job because it is the one thing that runs every hour the
# guest is up, and it needs the same ssh that an expired password would take
# away. Not fatal: today's backup does not depend on it.
"${SCRIPT_SH:-bash}" "$DC_ROOT/setup/host/rotate_password.sh" --if-due ||
    warn "the password rotation failed (above); this backup goes on, and it must be fixed before the password expires"

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
        rsync_cap "$DEST"
        rsync -a "${RSYNC_CAP[@]}" -e "ssh $SSH_OPTS_STR" "$DEST/repo/" "${VM_USER}@127.0.0.1:$restore_from/" || die "push failed"
    else
        scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -P "$SSH_PORT" \
            "$DEST/repo" "${VM_USER}@127.0.0.1:$restore_from" || die "push failed"
    fi
    info "restoring the newest snapshot into the running engines (the stack restarts)"
else
    info "installing the password and taking a backup in the guest"
fi
run_rc=0
expect_repo=0
[ ! -e "$DEST/repo/config" ] || expect_repo=1
BACKUP_PASS_FILE="$remote_tmp" BACKUP_PULL_USER="$VM_USER" BACKUP_VERIFY="$VERIFY" \
    BACKUP_RESTORE="$RESTORE" BACKUP_RESTORE_FROM="$restore_from" BACKUP_EXPECT_REPO="$expect_repo" \
    VM_PATH="${VM_PATH:-$DC_ROOT/disk_images}" \
    "${SCRIPT_SH:-bash}" "$DC_ROOT/setup/host/provision_vm.sh" "$VM_NAME" backup || run_rc=$?
vm_ssh "rm -f '$remote_tmp'" 2>/dev/null || true
if [ "$RESTORE" = 1 ]; then
    [ "$run_rc" = 0 ] || die "the restore failed (exit $run_rc): read the output above. The copy at $DEST/repo is untouched"
    ok "restored; the guest's repository now carries the pushed snapshots"
    exit 0
fi
# 3: a snapshot exists without one engine's dump (install_backup.sh). The other
# engines are worth having off the guest, so the pull goes on and the job fails
# at the end. Anything else: no snapshot worth pulling.
case "$run_rc" in
0 | 3) ;;
4) die "$VM_NAME was rebuilt and has no repository, and $DEST/repo holds the old one: make restore brings it back. Nothing was changed" ;;
*) die "install_backup.sh exited $run_rc (read the output above)" ;;
esac

if [ -d "$DEST/repo/snapshots" ]; then
    have=$(find "$DEST/repo/snapshots" -type f 2>/dev/null | wc -l)
    got=$(vm_ssh 'ls /var/backups/b2b/repo/snapshots 2>/dev/null | wc -l' 2>/dev/null | tr -d '[:space:]')
    copy_id=$(sha256sum "$DEST/repo/config" 2>/dev/null | cut -d' ' -f1)
    guest_id=$(vm_ssh 'sha256sum /var/backups/b2b/repo/config 2>/dev/null' 2>/dev/null | cut -d' ' -f1)
    refusal=$(pull_refusal "$copy_id" "$guest_id" "$have" "${got:-0}")
    [ -z "$refusal" ] || die "$refusal ($DEST/repo was left as it is)"
fi

info "pulling the repository to $DEST"
mkdir -p "$DEST" || die "cannot create $DEST"
if command -v rsync >/dev/null 2>&1; then
    rsync_cap "$DEST"
    # Restic's packs and snapshots are named by their content, so a file that
    # differs or vanishes on the guest is either a prune or damage. Either way
    # the old one goes to the attic, and a bad guest costs BACKUP_ATTIC_DAYS of grace.
    rsync -a --delete --backup --backup-dir="$DEST/attic/$(date +%Y%m%dT%H%M%S)" "${RSYNC_CAP[@]}" \
        -e "ssh $SSH_OPTS_STR" "${VM_USER}@127.0.0.1:/var/backups/b2b/repo/" "$DEST/repo/" ||
        die "rsync of the repository failed"
    find "$DEST/attic" -mindepth 1 -maxdepth 1 -type d -mtime "+${BACKUP_ATTIC_DAYS:-14}" -exec rm -rf {} + 2>/dev/null
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
# The one fact the guest cannot report: verify_platform reads this, because a
# guest whose hourly snapshots are fine says nothing about a pull that stopped.
date +%s >"$DEST/last-pull"

# A mirror's failure warns: the copy above is the backup, and this is its spare.
MIRROR=$(b2b_get B2B_DC_BACKUP_MIRROR)
if [ -n "$MIRROR" ] && [ "$MIRROR" != "$DEST" ]; then
    if mkdir -p "$MIRROR" && command -v rsync >/dev/null 2>&1; then
        rsync_cap "$DEST"
        if rsync -a --delete "${RSYNC_CAP[@]}" "$DEST/repo/" "$MIRROR/repo/"; then
            ok "mirrored to $MIRROR/repo"
        else
            warn "the mirror at $MIRROR failed; the copy at $DEST is complete"
        fi
    else
        warn "no mirror at $MIRROR: cannot create it, or no rsync here"
    fi
fi

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
[ "$run_rc" = 0 ] || die "copied, but a running engine is NOT in this snapshot (the b2b-backup lines above name it)"
