#!/usr/bin/env hellish
# b2b-backup on a stopped platform takes no snapshot.
#
# The bug it pins: on 2026-11-04 the guest's hourly timer fired over a wiped stack.
# Every engine was skipped, nothing counted as failed, and restic stored 13.5 KiB
# of env files as the newest snapshot with the verdict "ok". verify_platform read
# an outage as a good backup, b2b-restore refuses such a snapshot, and enough of
# them push the real ones out of the retention slots.
#
# HOW: the real job is cut out of install_backup.sh by its BKEOF heredoc, its
# paths moved under a temporary directory, with docker and restic stubbed on PATH.
# Caveat: the stubs speak only the calls this job makes with Postgres the single
# engine running; a new docker or restic call needs a line here.
set -u

cd "$(dirname "$0")/.." || exit 1
TMP=$(mktemp -d)
trap 'rm -rf "${TMP:?}"' EXIT

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s -- got: %s, expected: %s\n' "$1" "$2" "$3"
        fail=1
    fi
}

mkdir -p "$TMP/bin"
printf 'secret\n' >"$TMP/pass"
awk "/b2b-backup <<'BKEOF'\$/ { on = 1; next } /^BKEOF\$/ { on = 0 } on" \
    setup/install/dc/install_backup.sh |
    sed -e "s#^PASS=.*#PASS=$TMP/pass#" -e "s#^REPO=.*#REPO=$TMP/repo#" \
        -e "s#^DUMPS=.*#DUMPS=$TMP/dumps#" -e "s#^STATUS=.*#STATUS=$TMP/status/backup.last#" \
        >"$TMP/b2b-backup"
check "the job was cut out of the installer" "$(grep -c '^verdict ok$' "$TMP/b2b-backup")" 1

cat >"$TMP/bin/docker" <<'STUB'
#!/bin/sh
case "$1" in
ps) [ "${STACK:-down}" = up ] && echo mini-baas-postgres ;;
inspect) echo healthy ;;
exec) echo '-- a dump' ;;
esac
exit 0
STUB
cat >"$TMP/bin/restic" <<STUB
#!/bin/sh
printf '%s\n' "\$1" >>"$TMP/restic.calls"
exit 0
STUB
chmod +x "$TMP/bin/docker" "$TMP/bin/restic"

run_job() { # <down|up> -> the job's exit status
    : >"$TMP/restic.calls"
    PATH="$TMP/bin:$PATH" STACK="$1" sh "$TMP/b2b-backup" >"$TMP/out" 2>&1
    printf '%s' "$?"
}

check "platform down: no snapshot, exit 1" "$(run_job down)" 1
check "... restic is never asked to back up" "$(grep -c '^backup$' "$TMP/restic.calls")" 0
check "... nor to forget, so no good snapshot ages out" "$(grep -c '^forget$' "$TMP/restic.calls")" 0
check "... the verdict names the outage" "$(sed -E 's/ [0-9]+ / /' "$TMP/status/backup.last")" "failed platform-down"
check "... and the output says why" "$(grep -c 'mini-baas-postgres is not running' "$TMP/out")" 1

check "platform up: the snapshot is taken" "$(run_job up)" 0
check "... once" "$(grep -c '^backup$' "$TMP/restic.calls")" 1
check "... and the verdict is ok" "$(cut -d' ' -f1 "$TMP/status/backup.last")" ok

exit "$fail"
