#!/usr/bin/env hellish
# Pins the pull permissions in setup/install/dc/install_backup.sh. They used
# to be set only after a successful run: `b2b-backup || die` left
# /var/backups/b2b at the 0700 the top of the installer re-applies, so a run
# that failed one dump (mongo, 2026-10-18 14:15) still took its snapshot but
# the login could not list it, and backup_pull.sh refused the off-site copy
# with "the guest has 0 snapshot(s) ... run 'make restore' first".
# Caveat: runs the block by awk extraction from its `if [ -s
# /etc/b2b/restic.pass ]` line to the first column-0 `fi`, with the guest's
# absolute paths rewritten into a temporary directory and b2b-backup stubbed.
# shellcheck disable=SC2034,SC2317,SC2329 # read and invoked by the sourced block
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s -- got: %s, expected: %s\n' "$1" "$2" "$3"
        fail=1
    fi
}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
awk '/^if \[ -s \/etc\/b2b\/restic.pass \]/{p=1} p{print} p && /^fi$/{exit}' \
    setup/install/dc/install_backup.sh |
    sed -e "s#/usr/local/sbin/b2b-backup#$T/b2b-backup#g" \
        -e "s#/etc/b2b/restic.pass#$T/restic.pass#g" \
        -e "s#/var/backups/b2b#$T/b2b#g" >"$T/block"
check "block extracted" "$(grep -c 'run_rc' "$T/block")" 3

# Each case: a fresh 0700 tree, a stub run exiting $1, the block in a subshell.
run_block() {
    rm -rf "$T/b2b"
    mkdir -p "$T/b2b/repo/snapshots"
    : >"$T/b2b/repo/snapshots/s1"
    chmod 700 "$T/b2b"
    printf 'pw\n' >"$T/restic.pass"
    printf '#!/bin/sh\nexit %s\n' "$1" >"$T/b2b-backup"
    chmod +x "$T/b2b-backup"
    (
        log() { :; }
        die() {
            printf 'died: %s\n' "$*"
            exit 1
        }
        BACKUP_PULL_USER=$(id -un)
        BACKUP_RESTORE=0
        BACKUP_VERIFY=0
        # shellcheck disable=SC1091 # generated above
        . "$T/block"
    )
}

out=$(run_block 1)
check "a failed run still fails the install" "$out" "died: the backup run failed"
check "a failed run still opens the directory to the puller" "$(stat -c %a "$T/b2b")" 710
check "a failed run's snapshot is group-readable" "$(stat -c %A "$T/b2b/repo/snapshots/s1" | cut -c5)" r

out=$(run_block 0)
check "a good run passes" "$out" ""
check "a good run opens the directory" "$(stat -c %a "$T/b2b")" 710

exit "$fail"
