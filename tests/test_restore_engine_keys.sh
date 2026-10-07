#!/usr/bin/env hellish
# A restore must not lock an engine out of its own volume, and must say so
# when anything is left broken.
#
# THE FAILURE IT PINS
#   2026-10-07, `make datacenter` onto a fresh VM: b2b-restore replaced
#   /opt/grobase/.env.secrets with the snapshot's copy, reloaded Postgres and
#   MySQL, and kept every other volume. Mongo's had been initialised at first
#   boot with this guest's MONGO_INITDB_ROOT_PASSWORD, so mongo-init exited 1,
#   mongo-api, analytics-service and ai-service crash-looped, the next
#   b2b-backup printed "mongo dump failed" and still "5 dump(s) snapshotted",
#   and verify_platform said "platform verified".
#
# WHAT IS CHECKED
#   b2b-restore keeps the guest's value for the engine keys whose volume it
#   does not reload, takes everything else from the snapshot, and exits 1
#   when b2b-stack-health fails or is missing; b2b-backup exits 1 naming an
#   engine that runs and was not dumped, and leaves that verdict in a
#   world-readable file for verify_platform.
#
# HOW
#   Both scripts are heredocs in setup/install/dc/install_backup.sh, cut out
#   by their exact `cat >/usr/local/sbin/b2b-… <<'…EOF'` lines, with
#   /opt/grobase, /etc/b2b, /var/tmp, /var/log, /var/backups and /var/lib/b2b
#   moved under a temp dir, and run against stubs for docker, restic, make,
#   install and sleep. Renaming a marker breaks this extraction, not the
#   behaviour.
set -e

cd "$(dirname "$0")/.."

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s -- got: %s, expected: %s\n' "$1" "$2" "$3"
        fail=1
    fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export STUB_DIR="$TMP"

# extract <marker> <out>: one heredoc of install_backup.sh, paths moved.
extract() {
    awk "/^cat >\/usr\/local\/sbin\/$1 <<'$2'\$/ { on = 1; next } /^$2\$/ { on = 0 } on" \
        setup/install/dc/install_backup.sh |
        sed -e "s#/opt/grobase#$TMP/opt/grobase#g" -e "s#/etc/b2b#$TMP/etc/b2b#g" \
            -e "s#/var/tmp#$TMP#g" -e "s#/var/log#$TMP#g" -e "s#/var/backups#$TMP/backups#g" \
            -e "s#/var/lib/b2b#$TMP/lib#g" >"$TMP/$1"
    [ -s "$TMP/$1" ] || {
        echo "FAIL could not extract $1 from install_backup.sh"
        exit 1
    }
    chmod +x "$TMP/$1"
}
extract b2b-restore RESTOREEOF
extract b2b-backup BKEOF

mkdir -p "$TMP/bin" "$TMP/etc/b2b" "$TMP/opt/grobase" "$TMP/snap"
echo pass >"$TMP/etc/b2b/restic.pass"
cat >"$TMP/bin/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$STUB_DIR/docker.log"
case "$*" in
"volume ls -q") echo mini-baas_postgres-data ;;
"ps --format {{.Names}}") cat "$STUB_DIR/running" ;;
*"command -v mongodump"*) exit 0 ;;
*mongodump*) [ -f "$STUB_DIR/mongo_fails" ] && exit 1 ;;
*pg_dumpall*) echo "-- dump" ;;
*"psql -U postgres -tA"*) echo 3 ;;
esac
exit 0
EOF
cat >"$TMP/bin/restic" <<'EOF'
#!/bin/sh
case "$1" in
snapshots) echo '[{"short_id":"abcd1234"}]' ;;
restore) cp "$STUB_DIR"/snap/* "$4"/ ;;
esac
exit 0
EOF
# install -m MODE -o U -g G SRC DST as a copy, install -d -m MODE DIR as
# mkdir + chmod: no root here.
cat >"$TMP/bin/install" <<'EOF'
#!/bin/sh
if [ "$1" = -d ]; then
    mkdir -p "$4" && chmod "$3" "$4"
    exit
fi
for a in "$@"; do src=$dst; dst=$a; done
cp "$src" "$dst"
EOF
printf '#!/bin/sh\nexit 0\n' >"$TMP/bin/make"
printf '#!/bin/sh\nexit 0\n' >"$TMP/bin/sleep"
cat >"$TMP/bin/b2b-stack-health" <<'EOF'
#!/bin/sh
exit "$(cat "$STUB_DIR/health")"
EOF
chmod +x "$TMP"/bin/*
export PATH="$TMP/bin:$PATH"

# The snapshot: a Postgres dump and the platform secrets of ANOTHER guest.
echo "-- pg" >"$TMP/snap/postgres-20261007T012610.sql"
cat >"$TMP/snap/grobase.env.secrets" <<'EOF'
# Regenerate with: FORCE
POSTGRES_PASSWORD=snap-pg
JWT_SECRET=snap=jwt=with=equals
MONGO_INITDB_ROOT_PASSWORD=snap-mongo
LOG_STREAM_TOKEN=snap-log
EOF
guest_secrets() {
    cat >"$TMP/opt/grobase/.env.secrets" <<'EOF'
POSTGRES_PASSWORD=guest-pg
JWT_SECRET=guest-jwt
MONGO_INITDB_ROOT_PASSWORD=guest-mongo
EOF
}
value() { sed -n "s/^$1=//p" "$TMP/opt/grobase/.env.secrets"; }
restore() {
    rc=0
    out=$("$TMP/b2b-restore" 2>&1) || rc=$?
}

# --- the merge -----------------------------------------------------------------
guest_secrets
echo 0 >"$TMP/health"
restore
check "restore, healthy stack: exit 0" "$rc" 0
check "Mongo keeps this guest's password (its volume is not reloaded)" "$(value MONGO_INITDB_ROOT_PASSWORD)" guest-mongo
check "Postgres takes the snapshot's (its cluster is rebuilt from the dump)" "$(value POSTGRES_PASSWORD)" snap-pg
check "a value holding '=' comes through whole" "$(value JWT_SECRET)" snap=jwt=with=equals
check "a key only the snapshot has is kept" "$(value LOG_STREAM_TOKEN)" snap-log
check "each key appears once" "$(grep -c '^MONGO_INITDB_ROOT_PASSWORD=' "$TMP/opt/grobase/.env.secrets")" 1
check "the snapshot's comment line survives" "$(grep -c '^# Regenerate' "$TMP/opt/grobase/.env.secrets")" 1

sed -i '/^MONGO_INITDB_ROOT_PASSWORD=/d' "$TMP/snap/grobase.env.secrets"
guest_secrets
restore
check "a kept key the snapshot lacks still comes from the guest" "$(value MONGO_INITDB_ROOT_PASSWORD)" guest-mongo
echo "MONGO_INITDB_ROOT_PASSWORD=snap-mongo" >>"$TMP/snap/grobase.env.secrets"

: >"$TMP/opt/grobase/.env.secrets"
restore
check "a guest with no secrets yet takes the snapshot's whole" "$(value MONGO_INITDB_ROOT_PASSWORD)" snap-mongo

# --- the verdict -----------------------------------------------------------------
guest_secrets
echo 1 >"$TMP/health"
restore
check "restore, stack left unhealthy: exit 1" "$rc" 1
case "$out" in
*"not healthy"*) printf 'ok   ... and says the stack is not healthy\n' ;;
*)
    printf 'FAIL ... silently: %s\n' "$out"
    fail=1
    ;;
esac

mv "$TMP/bin/b2b-stack-health" "$TMP/health.bin"
restore
check "restore, no b2b-stack-health to judge with: exit 1 (unknown is a failure)" "$rc" 1
mv "$TMP/health.bin" "$TMP/bin/b2b-stack-health"

# --- the backup job ----------------------------------------------------------------
printf 'mini-baas-postgres\nmini-baas-mongo\n' >"$TMP/running"
backup() {
    rc=0
    out=$("$TMP/b2b-backup" 2>&1) || rc=$?
}
backup
check "backup, every running engine dumped: exit 0" "$rc" 0
check "... verdict file says ok" "$(cut -d' ' -f1 "$TMP/lib/backup.last")" ok
check "... readable by the login user (verify_platform reads it)" "$(stat -c %a "$TMP/lib/backup.last")" 644
check "... in a directory the login user can enter, despite umask 077" "$(stat -c %a "$TMP/lib")" 755
touch "$TMP/mongo_fails"
backup
check "backup, Mongo running and its dump refused: exit 1" "$rc" 1
check "... naming mongo" "$(printf '%s\n' "$out" | grep -c 'FAILED: mongo')" 1
check "... after snapshotting what it has" "$(printf '%s\n' "$out" | grep -c 'dump(s) snapshotted')" 1
check "... and the verdict file names it" "$(cut -d' ' -f1,3 "$TMP/lib/backup.last")" "failed mongo"

exit "$fail"
