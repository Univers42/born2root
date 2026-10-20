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
#   2026-10-20, `make datacenter` after a rebuild: the newest snapshot
#   (85fcb9b4, 11:46) also held the DynamoDB volume and an SQL Server dump, so
#   its path set differed from the 11:35 one. `restic snapshots --latest 1`
#   keeps one snapshot per host+paths group, `head -n1` took the first group,
#   and the restore loaded 239b50e2: eleven minutes, DynamoDB and SQL Server
#   lost while the output said "the newest snapshot".
#
# WHAT IS CHECKED
#   b2b-restore loads the newest snapshot of all (or the id it is given, and
#   refuses one that is not hex), gives the .env it re-assembles as root back
#   to /opt/grobase's owner, keeps the guest's value for the engine keys whose volume it
#   does not reload, takes everything else from the snapshot, and exits 1
#   when b2b-stack-health fails or is missing; b2b-backup exits 1 naming an
#   engine that runs and was not dumped, and leaves that verdict in a
#   world-readable file for verify_platform.
#   The rebuild set: b2b-backup snapshots the TLS certs (the CA clients
#   trust), vault42's admin env, the 42ctl project and the login's 42ctl
#   identity, and the MinIO and DynamoDB volumes, and dumps SQL Server
#   through grobase's engine-backup.sh. b2b-restore puts them back in an
#   order that is asserted: the certs before `make certs` (so the CA is
#   reused), MySQL into a fresh volume like Postgres, the volumes while the
#   stack is down, Mongo and SQL Server once it is up.
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
            -e "s#/var/lib/b2b#$TMP/lib#g" -e "s#/var/lib/docker#$TMP/docker#g" >"$TMP/$1"
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
printf 'B2B_LOGIN="tester"\n' >"$TMP/etc/b2b/build.conf"
# Every docker, make and engine-backup call lands in order.log, in order.
cat >"$TMP/bin/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$STUB_DIR/docker.log"
printf 'docker %s\n' "$*" >>"$STUB_DIR/order.log"
case "$*" in
"volume ls -q") printf 'mini-baas_postgres-data\nmini-baas_mysql-data\nmini-baas_minio-data\nmini-baas_dynamodb-data\n' ;;
"ps --format {{.Names}}") cat "$STUB_DIR/running" ;;
inspect*) echo healthy ;;
*"command -v mongodump"* | *"command -v mongorestore"*) exit 0 ;;
*mongodump*) [ -f "$STUB_DIR/mongo_fails" ] && exit 1 ;;
*mongorestore*)
    cat >"$STUB_DIR/mongo.restored"
    [ ! -f "$STUB_DIR/mongorestore_fails" ] || exit 1
    ;;
*pg_dumpall*) echo "-- dump" ;;
*"psql -U postgres -tA"*) echo 3 ;;
esac
exit 0
EOF
cat >"$TMP/bin/restic" <<'EOF'
#!/bin/sh
# Two snapshots in two host+paths groups, oldest first, as restic lists them.
case "$1" in
snapshots) echo '[{"time":"2026-10-20T11:35:36","paths":["/d"],"short_id":"239b50e2"},{"time":"2026-10-20T11:46:02","paths":["/d","/v"],"short_id":"85fcb9b4"}]' ;;
restore)
    printf '%s\n' "$2" >"$STUB_DIR/restored.id"
    cp -a "$STUB_DIR"/snap/. "$4"/
    ;;
backup) printf '%s\n' "$@" >"$STUB_DIR/backup.args" ;;
esac
exit 0
EOF
cat >"$TMP/bin/getent" <<'EOF'
#!/bin/sh
echo "tester:x:1000:1000::$STUB_DIR/home/tester:/bin/sh"
EOF
# grobase's engine-backup.sh, as the guest has it at /opt/grobase.
mkdir -p "$TMP/opt/grobase/scripts/ops"
cat >"$TMP/opt/grobase/scripts/ops/engine-backup.sh" <<'EOF'
printf 'engine-backup %s\n' "$*" >>"$STUB_DIR/order.log"
if [ "$1" = dump ]; then
    [ ! -f "$STUB_DIR/mssql_empty" ] || { echo "engine-backup: mssql has no user database to back up" >&2; exit 1; }
    [ ! -f "$STUB_DIR/mssql_fails" ] || { echo "engine-backup: dump of mssql failed" >&2; exit 1; }
    echo mssql-archive >"$3"
fi
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
# make in /opt/grobase: logged; `make certs` notes which CA it found.
cat >"$TMP/bin/make" <<'EOF'
#!/bin/sh
printf 'make %s\n' "$*" >>"$STUB_DIR/order.log"
case " $* " in *" certs "*) cat certs/ca.key >"$STUB_DIR/ca.at.certs" 2>/dev/null ;; esac
case " $* " in *" env "*) : >>.env ;; esac
exit 0
EOF
# chown logged, then done for real: no root here, so the owner cannot be
# read back, only the call that sets it.
cat >"$TMP/bin/chown" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$STUB_DIR/chown.log"
exec /bin/chown "$@"
EOF
printf '#!/bin/sh\nexit 0\n' >"$TMP/bin/sleep"
# install_grobase.sh's helper: the profile's [dc.grobase_env] into .env.local.
cat >"$TMP/bin/b2b-grobase-env" <<'EOF'
#!/bin/sh
printf 'b2b-grobase-env %s\n' "$*" >>"$STUB_DIR/order.log"
EOF
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
MYSQL_ROOT_PASSWORD=snap-mysql
MSSQL_SA_PASSWORD=snap-mssql
MARIADB_ROOT_PASSWORD=snap-mariadb
MARIADB_PASSWORD=snap-mariadb-app
LOG_STREAM_TOKEN=snap-log
EOF
guest_secrets() {
    cat >"$TMP/opt/grobase/.env.secrets" <<'EOF'
POSTGRES_PASSWORD=guest-pg
JWT_SECRET=guest-jwt
MONGO_INITDB_ROOT_PASSWORD=guest-mongo
MYSQL_ROOT_PASSWORD=guest-mysql
MSSQL_SA_PASSWORD=guest-mssql
MARIADB_ROOT_PASSWORD=guest-mariadb
MARIADB_PASSWORD=guest-mariadb-app
EOF
}
value() { sed -n "s/^$1=//p" "$TMP/opt/grobase/.env.secrets"; }
restore() {
    rc=0
    out=$("$TMP/b2b-restore" "$@" 2>&1) || rc=$?
}

# --- the merge -----------------------------------------------------------------
guest_secrets
echo 0 >"$TMP/health"
restore
check "restore, healthy stack: exit 0" "$rc" 0
check "the newest snapshot of all is loaded, not the first group's" "$(cat "$TMP/restored.id")" 85fcb9b4
check "the .env make env rewrote goes back to /opt/grobase's owner" \
    "$(grep -c "^--reference=$TMP/opt/grobase $TMP/opt/grobase/.env\$" "$TMP/chown.log")" 1
check "Mongo keeps this guest's password (its volume is not reloaded)" "$(value MONGO_INITDB_ROOT_PASSWORD)" guest-mongo
check "Postgres takes the snapshot's (its cluster is rebuilt from the dump)" "$(value POSTGRES_PASSWORD)" snap-pg
check "MySQL takes the snapshot's (its volume is rebuilt from the dump too)" "$(value MYSQL_ROOT_PASSWORD)" snap-mysql
check "SQL Server keeps this guest's (only its user databases are replaced)" "$(value MSSQL_SA_PASSWORD)" guest-mssql
check "MariaDB keeps this guest's (its volume is not reloaded)" "$(value MARIADB_ROOT_PASSWORD) $(value MARIADB_PASSWORD)" "guest-mariadb guest-mariadb-app"
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

# --- which snapshot ----------------------------------------------------------------
guest_secrets
restore 239b50e2
check "an id given on the command line wins over the newest" "$rc $(cat "$TMP/restored.id")" "0 239b50e2"
rm -f "$TMP/restored.id"
restore '85fcb9b4;x'
check "an id that is not hex: exit 1, nothing restored" "$rc $([ -e "$TMP/restored.id" ] && echo restored || echo none)" "1 none"

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

# --- the rebuild set: what b2b-backup snapshots ------------------------------------
G="$TMP/opt/grobase"
H="$TMP/home/tester"
DDB="$TMP/docker/volumes/mini-baas_dynamodb-data/_data"
MINIO="$TMP/docker/volumes/mini-baas_minio-data/_data"
mkdir -p "$G/certs" "$G/secrets" "$G/.42ctl" "$H/.config/42ctl" "$DDB" "$MINIO/bucket"
echo guest-ca >"$G/certs/ca.key"
echo guest-admin >"$G/secrets/vault42-admin.env"
echo '{"guest":1}' >"$G/.42ctl/project.json"
echo guest-token >"$H/.config/42ctl/session-default.tok"
echo guest-ddb >"$DDB/stale.db"
echo guest-obj >"$MINIO/bucket/guest-obj"
rm -f "$TMP/mongo_fails"
printf 'mini-baas-postgres\nmini-baas-mssql\n' >"$TMP/running"
in_backup() { grep -cxF -- "$1" "$TMP/backup.args" || true; }
backup
check "backup with SQL Server running: exit 0" "$rc" 0
check "... the TLS certs (the CA every client trusts)" "$(in_backup "$G/certs")" 1
check "... vault42's admin env" "$(in_backup "$G/secrets/vault42-admin.env")" 1
check "... the 42ctl project" "$(in_backup "$G/.42ctl/project.json")" 1
check "... the login's 42ctl identity" "$(in_backup "$H/.config/42ctl")" 1
check "... the DynamoDB volume" "$(in_backup "$DDB")" 1
check "... the MinIO volume, as before" "$(in_backup "$MINIO")" 1
check "... SQL Server dumped through grobase's engine-backup.sh" \
    "$(grep -c "^engine-backup dump mssql $TMP/backups/b2b/dumps/mssql-[0-9T]*\.tar\$" "$TMP/order.log")" 1
check "... and no longer 'not dumped here'" "$(printf '%s\n' "$out" | grep -c 'mini-baas-mssql is running and not dumped')" 0
rm "$G/.42ctl/project.json"
backup
check "a path this guest does not have is not handed to restic" "$(in_backup "$G/.42ctl/project.json") $rc" "0 0"
echo '{"guest":1}' >"$G/.42ctl/project.json"
touch "$TMP/mssql_empty"
backup
check "SQL Server without a user database: not a failure (0)" "$rc" 0
check "... says so" "$(printf '%s\n' "$out" | grep -c 'mssql: no user database')" 1
rm "$TMP/mssql_empty"
touch "$TMP/mssql_fails"
backup
check "SQL Server's dump failing: exit 1 naming mssql" "$rc $(printf '%s\n' "$out" | grep -c 'FAILED: mssql')" "1 1"
rm "$TMP/mssql_fails"

# --- the rebuild set: what b2b-restore puts back, and in which order ---------------
S="$TMP/snap$TMP"
mkdir -p "$S/opt/grobase/certs" "$S/opt/grobase/.42ctl" "$S/home/tester/.config" \
    "$S/docker/volumes/mini-baas_dynamodb-data/_data" "$S/docker/volumes/mini-baas_minio-data/_data/bucket"
mkdir -p "$S/opt/grobase/secrets" "$S/home/tester/.config/42ctl"
chmod 700 "$S/opt/grobase/secrets" "$S/home/tester/.config/42ctl"
echo snap-ca >"$S/opt/grobase/certs/ca.key"
echo snap-admin >"$S/opt/grobase/secrets/vault42-admin.env"
chmod 600 "$S/opt/grobase/secrets/vault42-admin.env"
echo '{"snap":1}' >"$S/opt/grobase/.42ctl/project.json"
echo snap-token >"$S/home/tester/.config/42ctl/session-default.tok"
chmod 600 "$S/home/tester/.config/42ctl/session-default.tok"
echo snap-ddb >"$S/docker/volumes/mini-baas_dynamodb-data/_data/shared-local-instance.db"
echo snap-obj >"$S/docker/volumes/mini-baas_minio-data/_data/bucket/snap-obj"
echo "-- my" >"$TMP/snap/mysql-20261007T012610.sql"
echo mongo-archive >"$TMP/snap/mongo-20261007T012610.archive"
echo mssql-archive >"$TMP/snap/mssql-20261007T012610.tar"
# A guest whose secrets/ and ~/.config never existed: made with the snapshot's modes.
rm -rf "${G:?}/secrets" "${H:?}/.config"
guest_secrets
echo 0 >"$TMP/health"
: >"$TMP/order.log"
restore
check "restore of the whole set: exit 0" "$rc" 0
check "the certs were back BEFORE make certs (the CA is reused)" "$(cat "$TMP/ca.at.certs" 2>/dev/null)" snap-ca
check "vault42's admin env: the snapshot's, 600" "$(cat "$G/secrets/vault42-admin.env") $(stat -c %a "$G/secrets/vault42-admin.env")" "snap-admin 600"
check "... in a 700 secrets/" "$(stat -c %a "$G/secrets")" 700
check "the 42ctl project: the snapshot's" "$(cat "$G/.42ctl/project.json")" '{"snap":1}'
check "the login's 42ctl identity: the snapshot's, 700/600" \
    "$(cat "$H/.config/42ctl/session-default.tok") $(stat -c %a "$H/.config/42ctl") $(stat -c %a "$H/.config/42ctl/session-default.tok")" "snap-token 700 600"
check "DynamoDB's volume: the snapshot's files, this guest's gone" \
    "$(cat "$DDB/shared-local-instance.db") $([ -e "$DDB/stale.db" ] && echo kept || echo gone)" "snap-ddb gone"
check "MinIO's volume: the snapshot's files, this guest's gone" \
    "$(cat "$MINIO/bucket/snap-obj") $(find "$MINIO" -name guest-obj | grep -c .)" "snap-obj 0"
check "Mongo: the archive went to mongorestore" "$(cat "$TMP/mongo.restored")" mongo-archive
check "... dropping each collection first, never touching admin (its users)" \
    "$(grep 'mongorestore' "$TMP/order.log" | grep -c -e '--drop.*--nsExclude "admin\.\*"')" 1
check "SQL Server: through engine-backup.sh restore" \
    "$(grep -c "^engine-backup restore mssql .*/mssql-20261007T012610\.tar\$" "$TMP/order.log")" 1
# The order: first match of each step, ascending.
at() { grep -n -m1 -e "$1" "$TMP/order.log" | cut -d: -f1; }
order=$(for step in '^b2b-grobase-env' '^make .*env' '^make .*certs' '^make .*down' \
    '^docker volume rm mini-baas_mysql-data' '^docker compose up -d mysql' '^make .* up ' 'mongorestore' \
    '^engine-backup restore mssql'; do at "$step"; done)
check "the order: profile env, env, certs, down, mysql's volume, mysql alone, up, mongo, mssql" \
    "$(printf '%s\n' "$order" | grep -c .) $(printf '%s\n' "$order" | sort -n -c && echo ascending)" "9 ascending"
check "MySQL's volume goes after the stack is down, before it starts alone" \
    "$([ "$(at '^make .*down')" -lt "$(at '^docker volume rm mini-baas_mysql-data')" ] && echo yes)" yes
touch "$TMP/mongorestore_fails"
restore
check "Mongo's load failing: exit 1 naming mongo" "$rc $(printf '%s\n' "$out" | grep -c 'not loaded:.*mongo')" "1 1"
rm "$TMP/mongorestore_fails"

exit "$fail"
