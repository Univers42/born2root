#!/usr/bin/env hellish
#
# install_backup.sh — restic and the dump job (dc-backup). Tools and timer at
# build time; the repository password arrives later, from the host.
#
# WHAT IS BACKED UP
#   Logical dumps of every engine that is running, taken through the
#   container so no port needs opening: pg_dumpall, mysqldump, mariadb-dump,
#   mongodump, Redis's RDB after a SAVE, and SQL Server and CockroachDB through
#   grobase's own scripts/ops/engine-backup.sh. The volumes that have no dump:
#   MinIO, DynamoDB-local, the functions, the SQLite data plane and Vault. And
#   what a rebuilt guest cannot mint again: grobase's secrets and .env.local,
#   its TLS certs (the CA every client trusts), vault42's admin env, the 42ctl
#   project and the login's 42ctl identity.
#
#   server.toml has run MariaDB, CockroachDB and those three volumes since the
#   max tier, with none of them in a snapshot: a restore came back without
#   them and said so nowhere but a wiki table.
#
# EXIT STATUS (b2b-backup, and this script when it runs one)
#   0   every running engine is in the snapshot
#   3   a snapshot exists, one engine's dump is missing from it. The rest are
#       still worth keeping off the guest, so backup_pull.sh pulls, then fails.
#   1   no snapshot was taken: restic failed, or the platform is not running
#   4   (this script) refused: the host holds this VM's repository and the guest
#       has none, so a run here would start a second one the copy can never take.
#
# WHAT IS NOT
#   The VM disk, the ISO, the images: all derived, all rebuilt by `make re`.
#   Only the dumps are precious, and only they are in the repository.
#
# WHY THE PASSWORD IS NOT HERE
#   /etc/b2b/restic.pass unlocks the repository. This script runs from the
#   ISO, which sits unencrypted on the host's disk, so it must not carry that
#   file. The service unit has ConditionPathExists on it: installed, timer
#   armed, and every run is a clean no-op until `make backup` from the host
#   writes the password over SSH (from .b2b-secrets, which git ignores).
#   A backup whose key is stored beside it is not encrypted.
#
# WHERE
#   The repository is /var/backups/b2b/repo, on the /var volume. The host
#   pulls it (`make backup_pull`) to /sgoinfre and offsite; a copy that only
#   lives in the guest is lost with the guest.
#
# USAGE
#   sudo ./install_backup.sh          restic, the dump job, an hourly timer
#   sudo b2b-backup                   dump and snapshot now (needs the password)
set -u

log() { printf '[backup] %s\n' "$*"; }
die() {
    printf '[backup] ERROR: %s\n' "$*" >&2
    exit 1
}
[ "$(id -u)" = 0 ] || die "run as root"

export DEBIAN_FRONTEND=noninteractive
command -v restic >/dev/null 2>&1 || apt-get install -y -qq restic || die "apt could not install restic"
install -d -m 0700 /var/backups/b2b /var/backups/b2b/dumps

cat >/usr/local/sbin/b2b-backup <<'BKEOF'
#!/bin/sh
# b2b-backup — dump every running engine, snapshot the dumps with restic.
# Installed by setup/install/dc/install_backup.sh (born2root).
set -u
PASS=/etc/b2b/restic.pass
REPO=/var/backups/b2b/repo
DUMPS=/var/backups/b2b/dumps
[ -s "$PASS" ] || { echo "b2b-backup: no $PASS yet (make backup, from the host)"; exit 0; }
export RESTIC_PASSWORD_FILE="$PASS" RESTIC_REPOSITORY="$REPO"
umask 077
# One at a time: each run starts by emptying $DUMPS, so a `make backup` landing on the
# timer's run deleted its dumps mid-write, and that snapshot went in short with exit 0.
# Caveat: a run stuck past 10 minutes makes the next one exit 1 rather than wait on.
exec 9>/run/lock/b2b-backup.lock
flock -w 600 9 || { echo "b2b-backup: another run has held the lock for 10 minutes: no snapshot"; exit 1; }
mkdir -p "$DUMPS"
rm -f "$DUMPS"/*
have() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }
stamp=$(date +%Y%m%dT%H%M%S)
n=0
# A running engine whose dump fails fails the run: the snapshot still takes
# what was dumped, then the exit is 1 and the unit is "failed". It used to
# say "5 dump(s) snapshotted" with Mongo locked out (2026-10-07). The
# verdict also lands world-readable in $STATUS ("ok <epoch>" or "failed
# <epoch> <what>"): verify_platform reads it as the login user, who cannot
# list the 0700 repository -- its snapshot-age check never passed on its own.
STATUS=/var/lib/b2b/backup.last
verdict() {
    install -d -m 0755 "${STATUS%/*}"
    printf '%s %s%s\n' "$1" "$(date +%s)" "${2:-}" >"$STATUS"
    chmod 644 "$STATUS"
}
failed=""
# A stopped platform is not an empty backup. Every `have` below is false, so this
# used to snapshot two env files and record "ok": on 2026-11-04 the 16:01 run
# stored 13.5 KiB as the newest snapshot over a wiped stack. b2b-restore refuses a
# snapshot with no Postgres dump, and an outage's worth of them would fill the
# hourly, daily and weekly slots of the forget below and push the real ones out.
# Caveat: this sees a stopped platform, not an emptied one. A running stack with
# no rows still snapshots, and that one becomes the newest.
if ! have mini-baas-postgres; then
    echo "b2b-backup: mini-baas-postgres is not running: no snapshot, the last good one stays the newest"
    verdict failed " platform-down"
    exit 1
fi
# The timer is Persistent=true, so a run right after every boot: containers up,
# engines still starting. pg_dumpall failed and the snapshot had no Postgres, with
# the same dump fine a minute later (26 MB, 2026-11-04). `have` only says running.
# Caveat: gives each engine 2 min, so an engine that never turns healthy costs that
# much and then fails its own dump below, by name; one with no healthcheck is not
# waited for.
for c in mini-baas-postgres mini-baas-mysql mini-baas-mariadb mini-baas-mongo mini-baas-redis mini-baas-mssql mini-baas-cockroach; do
    have "$c" || continue
    for _ in $(seq 1 60); do
        case "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}healthy{{end}}' "$c" 2>/dev/null)" in
        healthy) break ;;
        esac
        sleep 2
    done
done
if have mini-baas-postgres; then
    docker exec mini-baas-postgres pg_dumpall -U postgres --clean >"$DUMPS/postgres-$stamp.sql" && n=$((n + 1)) ||
        { echo "b2b-backup: postgres dump failed"; failed="$failed postgres"; }
fi
if have mini-baas-mysql; then
    docker exec mini-baas-mysql sh -c 'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --all-databases --single-transaction' >"$DUMPS/mysql-$stamp.sql" && n=$((n + 1)) ||
        { echo "b2b-backup: mysql dump failed"; failed="$failed mysql"; }
fi
if have mini-baas-mongo; then
    # grobase's mongo image ships the database tools since its Dockerfile
    # added mongodb-database-tools; d74aa97's had mongosh alone. An image
    # without them leaves a running engine out of the snapshot, which is what
    # "failed" means here, so it counts as one (it used to print a note and
    # exit 0).
    if docker exec mini-baas-mongo sh -c 'command -v mongodump' >/dev/null 2>&1; then
        docker exec mini-baas-mongo sh -c 'mongodump --archive -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin' >"$DUMPS/mongo-$stamp.archive" && n=$((n + 1)) ||
            { echo "b2b-backup: mongo dump failed"; failed="$failed mongo"; }
    else
        echo "b2b-backup: mongo not dumped: no mongodump in the mini-baas-mongo image"
        failed="$failed mongo"
    fi
fi
if have mini-baas-redis; then
    docker exec mini-baas-redis redis-cli SAVE >/dev/null 2>&1
    docker cp mini-baas-redis:/data/dump.rdb "$DUMPS/redis-$stamp.rdb" 2>/dev/null && n=$((n + 1)) ||
        { echo "b2b-backup: redis dump failed"; failed="$failed redis"; }
fi
if have mini-baas-mariadb; then
    # Named databases, never --all-databases: that dump carries mysql.user, and
    # b2b-restore keeps this guest's MARIADB_* (the volume is not replaced), so
    # the load would swap the root password under the running engine.
    md_dbs=$(docker exec mini-baas-mariadb sh -c 'mariadb -N -uroot -p"$MARIADB_ROOT_PASSWORD" -e "SHOW DATABASES"' 2>/dev/null |
        grep -vxE 'information_schema|performance_schema|mysql|sys' | tr '\n' ' ')
    if [ -z "$md_dbs" ]; then
        echo "b2b-backup: mariadb: no user database to back up"
    elif docker exec mini-baas-mariadb sh -c "mariadb-dump -uroot -p\"\$MARIADB_ROOT_PASSWORD\" --single-transaction --databases $md_dbs" >"$DUMPS/mariadb-$stamp.sql"; then
        n=$((n + 1))
    else
        echo "b2b-backup: mariadb dump failed"
        failed="$failed mariadb"
    fi
fi
# grobase's dumper, the format its restore reads back (b2b-restore): for SQL
# Server native .bak files WITH COPY_ONLY, for CockroachDB a BACKUP directory,
# each tarred.
# Caveat: "has no user database" is engine-backup.sh's wording (grobase
# d180542..dca1de9); reworded, an empty engine reads as a failed dump.
engine_dump() {
    if eb_err=$(bash /opt/grobase/scripts/ops/engine-backup.sh dump "$1" "$DUMPS/$1-$stamp.tar" 2>&1 >/dev/null); then
        n=$((n + 1))
    else
        case "$eb_err" in
        *"has no user database"*) echo "b2b-backup: $1: no user database to back up" ;;
        *)
            echo "b2b-backup: $1 dump failed: $eb_err"
            failed="$failed $1"
            ;;
        esac
    fi
}
have mini-baas-mssql && engine_dump mssql
have mini-baas-cockroach && engine_dump cockroach
# Beside the dumps, as files: what a rebuilt guest cannot mint again, and the
# volumes that have no dump. Only paths that exist: restic fails a run on one
# it cannot find.
# Caveat: the volumes are copied live. MinIO, the functions and Vault's file
# backend are quiescent most of the hour; DynamoDB-local and the data plane's
# SQLite are one file each, and a write during the copy leaves that snapshot's
# copy torn -- the next hour's is the clean one.
login=$(sed -n 's/^B2B_LOGIN=//p' /etc/b2b/build.conf 2>/dev/null | tr -d '"' | head -n1)
home=""
[ -n "$login" ] && home=$(getent passwd "$login" 2>/dev/null | cut -d: -f6)
extra=""
for p in /opt/grobase/certs /opt/grobase/secrets/vault42-admin.env /opt/grobase/.42ctl/project.json \
    ${home:+"$home/.config/42ctl"}; do
    [ -e "$p" ] && extra="$extra $p"
done
for v in minio-data dynamodb-data functions-data sqlite-data vault-data; do
    vol=$(docker volume ls -q 2>/dev/null | grep -m1 -- "$v\$" || true)
    [ -n "$vol" ] && [ -d "/var/lib/docker/volumes/$vol/_data" ] && extra="$extra /var/lib/docker/volumes/$vol/_data"
done
# grobase's own secrets travel with the data: JWT secret, the engines' role
# passwords, service tokens, the anon/service API keys. A dump restored into
# a stack that re-minted those is unusable (db-bootstrap fails on the old
# role passwords -- the 2026-09-20 rebuild). Encrypted in the repository
# like everything else.
for f in /opt/grobase/.env.secrets /opt/grobase/.env.local; do
    [ -s "$f" ] && cp -p "$f" "$DUMPS/grobase$(basename "$f")" && n=$((n + 1))
done
# Init only when the repository is absent. Any other snapshots failure (a wrong
# password, a permission, a damaged repo) is reported as itself: masking it with
# `restic init` made a wrong password read as "config file already exists".
# Caveat: matches restic's "does not exist" wording; a restic that words the
# missing-repo error differently fails here instead of initialising.
if ! snap_err=$(restic snapshots 2>&1 >/dev/null); then
    case "$snap_err" in
        *"does not exist"*) restic init >/dev/null || {
            echo "b2b-backup: restic init failed"
            verdict failed " restic-init"
            exit 1
        } ;;
        *)
            echo "b2b-backup: restic snapshots failed: $snap_err"
            verdict failed " restic-snapshots"
            exit 1
            ;;
    esac
fi
# shellcheck disable=SC2086 # $extra is a list of fixed paths without spaces, split on purpose
restic backup --quiet --tag b2b "$DUMPS" $extra || {
    echo "b2b-backup: restic backup failed"
    verdict failed " restic-backup"
    exit 1
}
# The dumps are plaintext (every row, and .env.secrets) and as large as the data:
# in the repository now, so neither should wait an hour on /var.
rm -f "$DUMPS"/*
restic forget --quiet --keep-hourly 24 --keep-daily 14 --keep-weekly 8 --prune >/dev/null 2>&1 ||
    echo "b2b-backup: WARN restic forget failed: this snapshot is safe, the repository will not shrink"
echo "b2b-backup: $n dump(s) snapshotted into $REPO ($(restic snapshots --json 2>/dev/null | grep -o '"short_id"' | wc -l) snapshots kept)"
if [ -n "$failed" ]; then
    echo "b2b-backup: FAILED:$failed -- running but not dumped, so not in this snapshot"
    verdict failed "$failed"
    exit 3
fi
verdict ok
BKEOF
chmod 755 /usr/local/sbin/b2b-backup

# The restore drill: a backup nobody has restored is a hypothesis. This
# takes the NEWEST snapshot, restores it to a scratch directory, loads the
# Postgres dump into a throwaway container of the same image the stack
# runs, counts what came back, and exits non-zero if any step fails. It
# touches nothing that is running. `make restore_drill` from the host.
cat >/usr/local/sbin/b2b-restore-drill <<'DRILLEOF'
#!/bin/sh
# b2b-restore-drill — prove the newest backup restores. Installed by
# setup/install/dc/install_backup.sh (born2root).
set -u
PASS=/etc/b2b/restic.pass
REPO=/var/backups/b2b/repo
[ -s "$PASS" ] || { echo "restore-drill: no $PASS (make backup first)"; exit 1; }
export RESTIC_PASSWORD_FILE="$PASS" RESTIC_REPOSITORY="$REPO"
umask 077
work=$(mktemp -d /var/tmp/b2b-drill.XXXXXX) || exit 1
trap 'rm -rf "$work"; docker rm -f b2b-drill-pg >/dev/null 2>&1' EXIT
# The newest of all, as b2b-restore picks it (not `--latest 1`: one per group).
snap=$(restic snapshots --json 2>/dev/null | grep -o '"short_id":"[a-f0-9]*"' | tail -n1 | cut -d'"' -f4)
[ -n "$snap" ] || { echo "restore-drill: no snapshot in $REPO"; exit 1; }
restic restore "$snap" --target "$work" >/dev/null 2>&1 || { echo "restore-drill: restic restore of $snap FAILED"; exit 1; }
dump=$(find "$work" -name 'postgres-*.sql' | head -n1)
n_files=$(find "$work" -type f | wc -l)
echo "restore-drill: snapshot $snap restored: $n_files file(s)"
[ -n "$dump" ] || { echo "restore-drill: no postgres dump in the snapshot (nothing to load; $n_files files restored)"; exit 0; }
image=$(docker inspect --format '{{.Config.Image}}' mini-baas-postgres 2>/dev/null || echo postgres:16)
docker run -d --name b2b-drill-pg -e POSTGRES_PASSWORD=drill -e POSTGRES_HOST_AUTH_METHOD=trust "$image" >/dev/null 2>&1 ||
    { echo "restore-drill: could not start a scratch postgres ($image)"; exit 1; }
for _ in $(seq 1 30); do
    docker exec b2b-drill-pg pg_isready -U postgres >/dev/null 2>&1 && break
    sleep 2
done
docker exec -i b2b-drill-pg psql -U postgres -q -v ON_ERROR_STOP=0 <"$dump" >/dev/null 2>"$work/psql.err" ||
    { echo "restore-drill: psql reported errors loading the dump:"; head -n5 "$work/psql.err"; }
dbs=$(docker exec b2b-drill-pg psql -U postgres -tA -c "select count(*) from pg_database where not datistemplate" 2>/dev/null)
tables=$(docker exec b2b-drill-pg psql -U postgres -tA -c "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema')" 2>/dev/null)
[ "${tables:-0}" -gt 0 ] || { echo "restore-drill: the restored dump produced NO tables -- the backup is not usable"; exit 1; }
echo "restore-drill: OK -- $dbs database(s), $tables table(s) came back from snapshot $snap (dump: $(basename "$dump"), $(du -h "$dump" | cut -f1))"
DRILLEOF
chmod 755 /usr/local/sbin/b2b-restore-drill

# The drill above proves a backup once, when someone remembers. This runs it
# weekly with a read of 5% of the pack files, the two things that notice a
# repository going bad while every hourly run still says ok, and leaves the
# verdict world-readable for verify_platform, as backup.last does.
# Caveat: 5% a week reads most packs only over months, and the drill loads
# Postgres alone: a damaged pack of another engine's dump can go unseen until a
# restore. Raise the percentage, or run `make backup_verify`, before relying on one.
cat >/usr/local/sbin/b2b-weekly-proof <<'PROOFEOF'
#!/bin/sh
# b2b-weekly-proof — check the repository, then prove a restore. Installed by
# setup/install/dc/install_backup.sh (born2root).
set -u
STATUS=/var/lib/b2b/proof.last
verdict() {
    install -d -m 0755 "${STATUS%/*}"
    printf '%s %s%s\n' "$1" "$(date +%s)" "${2:-}" >"$STATUS"
    chmod 644 "$STATUS"
}
if ! RESTIC_PASSWORD_FILE=/etc/b2b/restic.pass RESTIC_REPOSITORY=/var/backups/b2b/repo \
    restic check --read-data-subset=5%; then
    verdict failed " restic-check"
    exit 1
fi
/usr/local/sbin/b2b-restore-drill || {
    verdict failed " restore-drill"
    exit 1
}
verdict ok
PROOFEOF
chmod 755 /usr/local/sbin/b2b-weekly-proof

# The restore itself: the newest snapshot loaded back, which is what brings
# tenants, their keys and every row home on a rebuilt VM. Postgres and MySQL
# into EMPTY volumes, never over populated ones -- the comment inside the
# script says why, with the errors that taught it; the platform secrets are
# put back first so both initialise with the dumps' own passwords. The certs,
# vault42's admin env and the 42ctl files go back before `make certs`, the
# volumes with no dump (MinIO, DynamoDB, functions, SQLite, Vault) while the
# stack is down, Mongo (mongorestore --drop, admin left alone), MariaDB (its
# user databases only), SQL Server and CockroachDB (grobase's
# engine-backup.sh) once it is up. Redis is a cache and is not restored.
#
# Except the secrets of an engine whose volume the restore does NOT replace:
# it was initialised at first boot with THIS guest's value and still holds
# it, so the snapshot's value locks every client out. Mongo did that on
# 2026-10-07 (mongo-init exit 1; mongo-api, analytics-service, ai-service
# crash-looping; the next backup's mongo dump "AuthenticationFailed"), and
# the restore said nothing. Those keys keep the guest's value: Mongo's and
# SQL Server's (their user databases are replaced, their system databases
# and logins are not) and MariaDB's. MinIO reads its own from the
# environment at every start. The restore then ends on b2b-stack-health
# (install_var_gc.sh): any container left unhealthy, crash-looping or exited
# non-zero fails it, whatever the cause.
cat >/usr/local/sbin/b2b-restore <<'RESTOREEOF'
#!/bin/sh
# b2b-restore [ID] — load the newest snapshot (or ID) into the running engines. Installed
# by setup/install/dc/install_backup.sh (born2root). Read its header first.
set -u
ENGINE_KEYS_KEPT="MONGO_INITDB_ROOT_PASSWORD MSSQL_SA_PASSWORD MARIADB_ROOT_PASSWORD MARIADB_PASSWORD"
# keep_guest_engine_keys <guest secrets> <snapshot secrets> <out>: the
# snapshot's file, each key of ENGINE_KEYS_KEPT carrying the guest's value.
keep_guest_engine_keys() {
    if [ ! -s "$1" ]; then
        cp "$2" "$3"
        return
    fi
    awk -v keep=" $ENGINE_KEYS_KEPT " '
        { k = $0; sub(/=.*/, "", k) }
        NR == FNR { if (index(keep, " " k " ")) guest[k] = $0; next }
        k in guest { print guest[k]; seen[k] = 1; next }
        { print }
        END { for (k in guest) if (!(k in seen)) print guest[k] }
    ' "$1" "$2" >"$3"
}
# put_back PATH: PATH as the snapshot has it, a file or a directory with its
# mode and owner, in place of what this guest made. A missing parent takes
# the snapshot's parent's mode and owner (only that one level).
put_back() {
    src="$work$1"
    [ -e "$src" ] || return 0
    dir=${1%/*}
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir" && chmod --reference="${src%/*}" "$dir" && chown --reference="${src%/*}" "$dir" || return 1
    fi
    rm -rf "${1:?}" && cp -a "$src" "$1" && echo "restore: $1 put back"
}
# put_volume NAME: the snapshot's copy of the docker volume whose name ends
# in NAME, over this guest's. Only while the stack is down.
put_volume() {
    src=$(find "$work/var/lib/docker/volumes" -mindepth 1 -maxdepth 1 -name "*$1" 2>/dev/null | head -n1)
    [ -n "$src" ] && [ -d "$src/_data" ] || return 0
    vol=$(docker volume ls -q | grep -m1 -- "$1\$")
    if [ -z "$vol" ]; then
        echo "restore: WARN the snapshot has a $1 volume and this guest has none: not restored"
        return 0
    fi
    dst="/var/lib/docker/volumes/$vol/_data"
    if find "$dst" -mindepth 1 -delete && cp -a "$src/_data/." "$dst/"; then
        echo "restore: volume $vol restored"
    else
        echo "restore: volume $vol NOT restored"
        load_failed="$load_failed $1"
    fi
}
# ready CONTAINER: healthy, or running when it has no healthcheck.
# Ponytail: 90 tries 2 s apart. An engine slower than 3 min to come up reads
# as not loaded, and the restore names it.
ready() {
    for _ in $(seq 1 90); do
        case "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1" 2>/dev/null)" in
        healthy | running) return 0 ;;
        esac
        sleep 2
    done
    return 1
}
# crdb_drop_user_databases: what `RESTORE DATABASE` would otherwise refuse. The
# login is grobase's own (crdb_auth), the list of system databases its crdb_dump's.
crdb_drop_user_databases() {
    . /opt/grobase/scripts/lib/lib-crdb-client.sh || return 1
    auth=$(crdb_auth mini-baas-cockroach)
    crdb_names=$(docker exec mini-baas-cockroach cockroach sql "$auth" --format=tsv -e \
        "SELECT database_name FROM [SHOW DATABASES] WHERE database_name NOT IN ('system','defaultdb','postgres')") || return 1
    printf '%s\n' "$crdb_names" | tail -n +2 | while IFS= read -r db; do
        [ -n "$db" ] || continue
        docker exec mini-baas-cockroach cockroach sql "$auth" -e "DROP DATABASE \"$db\" CASCADE" || exit 1
    done
}
load_failed=""
PASS=/etc/b2b/restic.pass
REPO=/var/backups/b2b/repo
[ -s "$PASS" ] || { echo "restore: no $PASS (make backup first)"; exit 1; }
export RESTIC_PASSWORD_FILE="$PASS" RESTIC_REPOSITORY="$REPO"
umask 077
work=$(mktemp -d /var/tmp/b2b-restore.XXXXXX) || exit 1
trap 'rm -rf "$work"' EXIT
# The snapshot: $1 when given (make restore SNAPSHOT=<id>), else the newest
# of all. Not `--latest 1`: restic keeps one snapshot per host+paths group
# there, and on 2026-10-20 the newest (85fcb9b4) carried the DynamoDB volume
# the 11:35 one lacked, so `head -n1` took the older group and the rebuild
# lost DynamoDB, SQL Server and eleven minutes. The list is oldest first.
snap=${1:-$(restic snapshots --json 2>/dev/null | grep -o '"short_id":"[a-f0-9]*"' | tail -n1 | cut -d'"' -f4)}
case "$snap" in
'' | *[!0-9a-f]*) echo "restore: '${snap}' is not a snapshot id, or $REPO holds none"; exit 1 ;;
esac
restic restore "$snap" --target "$work" >/dev/null 2>&1 || { echo "restore: restic restore of $snap FAILED"; exit 1; }
reconcile=0
pg=$(find "$work" -name 'postgres-*.sql' | head -n1)
my=$(find "$work" -name 'mysql-*.sql' | head -n1)
[ -n "$pg" ] || { echo "restore: snapshot $snap holds no postgres dump"; exit 1; }
echo "restore: snapshot $snap ($(basename "$pg")$( [ -n "$my" ] && printf ', %s' "$(basename "$my")"))"
# The platform secrets first: the dump's role passwords are the ones in the
# snapshot's .env.secrets, not the ones this guest minted at first boot.
# `make env` re-assembles .env; the `make up` below recreates every
# container with them, and grobase's db-bootstrap then finds roles whose
# passwords match.
sec=$(find "$work" -name 'grobase.env.secrets' | head -n1)
if [ -n "$sec" ] && [ -d /opt/grobase ]; then
    owner=$(stat -c %U /opt/grobase/.env.secrets 2>/dev/null || stat -c %U /opt/grobase)
    keep_guest_engine_keys /opt/grobase/.env.secrets "$sec" "$work/env.secrets.merged"
    install -m 0600 -o "$owner" -g "$owner" "$work/env.secrets.merged" /opt/grobase/.env.secrets
    echo "restore: kept this guest's value for $ENGINE_KEYS_KEPT (that engine's volume is not reloaded)"
    loc=$(find "$work" -name 'grobase.env.local' | head -n1)
    [ -n "$loc" ] && install -m 0600 -o "$owner" -g "$owner" "$loc" /opt/grobase/.env.local
    echo "restore: grobase .env.secrets restored"
else
    echo "restore: snapshot carries no grobase.env.secrets (taken before 2026-09-20): keeping this guest's secrets and reconciling the postgres role after the load"
    reconcile=1
fi
# What a rebuilt guest cannot mint again, BEFORE `make certs`: it reuses a CA
# it finds, so every client that trusted the old one still does.
login=$(sed -n 's/^B2B_LOGIN=//p' /etc/b2b/build.conf 2>/dev/null | tr -d '"' | head -n1)
home=""
[ -n "$login" ] && home=$(getent passwd "$login" 2>/dev/null | cut -d: -f6)
for p in /opt/grobase/certs /opt/grobase/secrets/vault42-admin.env /opt/grobase/.42ctl/project.json \
    ${home:+"$home/.config/42ctl"}; do
    put_back "$p" || echo "restore: WARN could not put back $p"
done
if [ -d /opt/grobase ]; then
    # The profile's [dc.grobase_env] over the snapshot's .env.local: a key the
    # profile gained since that snapshot is not lost (install_grobase.sh).
    if ! command -v b2b-grobase-env >/dev/null 2>&1; then
        echo "restore: WARN no b2b-grobase-env in this guest (make grobase installs it): the profile's grobase keys are not re-applied"
    elif genv=$(b2b-grobase-env); then
        [ -z "$genv" ] || echo "restore: $genv"
    else
        echo "restore: WARN b2b-grobase-env failed: the profile's grobase keys are not re-applied"
    fi
    # ENV_ORPHANS=carry: a grobase whose `make env` refuses to drop a key only
    # the old .env held (scripts/env/assemble-env.sh, after 5ba7795d) puts it
    # into .env.local instead of stopping an unattended restore with a stale
    # .env. Its stderr names keys, never values, so it is shown.
    if (cd /opt/grobase && ENV_ORPHANS=carry make --no-print-directory env >/dev/null 2>"$work/make-env.err"); then
        echo "restore: .env re-assembled"
    else
        echo "restore: WARN make env failed"
    fi
    # make env ran as root and left .env root:root 600, while install_grobase.sh
    # gives the tree to the login, whose tools read it: on 2026-10-20 groot's
    # `make link` failed "cat: /opt/grobase/.env: Permission denied" after a restore.
    for f in /opt/grobase/.env /opt/grobase/.env.prev; do
        [ ! -e "$f" ] || chown --reference=/opt/grobase "$f" || echo "restore: WARN $f stays root's: the login cannot read it"
    done
    sed 's/^/restore:   /' "$work/make-env.err"
    (cd /opt/grobase && make --no-print-directory certs >/dev/null 2>&1) && echo "restore: certs re-issued from the restored CA" || echo "restore: WARN make certs failed"
fi
# Into an EMPTY cluster, never over a populated one. A fresh guest's first
# boot already created grobase's schema; loading a pg_dumpall --clean over
# it fails on dependencies ("relation already exists"), keeps the existing
# tables WITH their foreign keys, and then rejects the dump's rows in the
# order a dump writes them (tenant_api_keys before tenants -- constraints
# are added last, which is fine on an empty cluster and fatal here). The
# third rebuild lost every API key that way, with the tenant row intact.
# So: stack down (volumes stay), only the Postgres data volume removed,
# Postgres started alone with the restored .env (initdb takes the dump's
# own password), the dump loaded into that empty cluster, then make up.
conf=/etc/b2b/grobase.conf
pkg=$(sed -n 's/^GROBASE_PACKAGE=//p' "$conf" 2>/dev/null); add=$(sed -n 's/^GROBASE_ADDONS=//p' "$conf" 2>/dev/null)
pgvol=$(docker volume ls -q | grep -m1 'postgres-data')
[ -n "$pgvol" ] || { echo "restore: no postgres data volume found"; exit 1; }
(cd /opt/grobase && make --no-print-directory down PACKAGE="${pkg:-pro}" ADDONS="$add" >/dev/null 2>&1) || echo "restore: WARN make down reported a problem"
docker volume rm "$pgvol" >/dev/null 2>&1 || { echo "restore: could not remove $pgvol (a container still uses it?)"; exit 1; }
echo "restore: stack down, $pgvol removed -- Postgres will start empty"
# MySQL the same way, for the same reason: with grobase minting
# MYSQL_ROOT_PASSWORD into .env.secrets (dab5f43), the volume this guest made
# rejects the snapshot's password, and the load below was refused.
if [ -n "$my" ]; then
    myvol=$(docker volume ls -q | grep -m1 'mysql-data')
    if [ -n "$myvol" ]; then
        docker volume rm "$myvol" >/dev/null 2>&1 || { echo "restore: could not remove $myvol (a container still uses it?)"; exit 1; }
        echo "restore: $myvol removed -- MySQL will start empty"
    fi
fi
for v in minio-data dynamodb-data functions-data sqlite-data vault-data; do
    put_volume "$v"
done
(cd /opt/grobase && docker compose up -d postgres >/dev/null 2>&1) || { echo "restore: could not start postgres alone"; exit 1; }
for _ in $(seq 1 45); do
    docker exec mini-baas-postgres pg_isready -U postgres >/dev/null 2>&1 && break
    sleep 2
done
docker exec mini-baas-postgres pg_isready -U postgres >/dev/null 2>&1 || { echo "restore: postgres did not come up"; exit 1; }
if docker exec -i mini-baas-postgres psql -U postgres -q -v ON_ERROR_STOP=0 <"$pg" >"$work/pg.log" 2>&1; then :; fi
pg_err=$(grep -c '^ERROR' "$work/pg.log" 2>/dev/null || echo 0)
cp -f "$work/pg.log" /var/log/b2b-restore-pg.log 2>/dev/null || true
tables=$(docker exec mini-baas-postgres psql -U postgres -tA -c "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema')" 2>/dev/null)
echo "restore: postgres loaded into an empty cluster ($pg_err error line(s), $tables table(s) in the default database)"
keys_after_load=$(docker exec mini-baas-postgres psql -U postgres -tA -c "select count(*) from public.tenant_api_keys" 2>/dev/null)
grep -iE 'ERROR.*tenant_api_keys' "$work/pg.log" | head -n3 | sed 's/^/restore:   psql: /'
echo "restore: tenant_api_keys rows after the load: ${keys_after_load:-?}"
if [ "${reconcile:-0}" = 1 ]; then
    pw=$(sed -n 's/^POSTGRES_PASSWORD=//p' /opt/grobase/.env 2>/dev/null | head -n1 | tr -d '"')
    [ -n "$pw" ] && printf "ALTER USER postgres WITH PASSWORD :'p';\n" | docker exec -i mini-baas-postgres psql -U postgres -q -v p="$pw" >/dev/null 2>&1 && echo "restore: postgres role password reconciled with this guest's .env"
fi
# MySQL needs its container: bring it up alone the same way.
(cd /opt/grobase && docker compose up -d mysql >/dev/null 2>&1) || true
for _ in $(seq 1 30); do
    docker exec mini-baas-mysql sh -c 'mysqladmin ping -uroot -p"$MYSQL_ROOT_PASSWORD"' >/dev/null 2>&1 && break
    sleep 2
done
if [ -n "$my" ]; then
    if docker exec -i mini-baas-mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' <"$my" >"$work/my.log" 2>&1; then
        echo "restore: mysql loaded"
    else
        echo "restore: mysql load reported errors:"; head -n3 "$work/my.log"
        load_failed="$load_failed mysql"
    fi
fi
if [ -d /opt/grobase ]; then
    (cd /opt/grobase && make --no-print-directory up PACKAGE="${pkg:-pro}" ADDONS="$add" >/dev/null 2>&1) && echo "restore: stack back up (make up PACKAGE=${pkg:-pro})" || echo "restore: make up reported a problem -- check docker ps"
    sleep 20
    echo "restore: tenant_api_keys rows after grobase's bootstrap: $(docker exec mini-baas-postgres psql -U postgres -tA -c "select count(*) from public.tenant_api_keys" 2>/dev/null)"
fi
# Mongo's volume is this guest's (its root user and password with it), so
# only the data comes back: each collection dropped and reloaded, admin --
# the users -- left out.
mg=$(find "$work" -name 'mongo-*.archive' | head -n1)
if [ -n "$mg" ]; then
    if ready mini-baas-mongo && docker exec -i mini-baas-mongo sh -c 'mongorestore --quiet --archive --drop --nsExclude "admin.*" --nsExclude "config.*" -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin' <"$mg" >"$work/mongo.log" 2>&1; then
        echo "restore: mongo loaded"
    else
        echo "restore: mongo load failed:"; tail -n3 "$work/mongo.log"
        load_failed="$load_failed mongo"
    fi
fi
# SQL Server through the script that dumped it (b2b-backup): RESTORE ... WITH
# REPLACE of each user database in the archive.
ms=$(find "$work" -name 'mssql-*.tar' | head -n1)
if [ -n "$ms" ]; then
    if ready mini-baas-mssql && bash /opt/grobase/scripts/ops/engine-backup.sh restore mssql "$ms" >"$work/mssql.log" 2>&1; then
        echo "restore: mssql loaded"
    else
        echo "restore: mssql restore failed:"; tail -n3 "$work/mssql.log"
        load_failed="$load_failed mssql"
    fi
fi
# MariaDB's volume is this guest's as well (ENGINE_KEYS_KEPT): the dump names
# its databases, and its DROP TABLEs replace them over the running engine.
md=$(find "$work" -name 'mariadb-*.sql' | head -n1)
if [ -n "$md" ]; then
    if ready mini-baas-mariadb && docker exec -i mini-baas-mariadb sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD"' <"$md" >"$work/mariadb.log" 2>&1; then
        echo "restore: mariadb loaded"
    else
        echo "restore: mariadb load failed:"; tail -n3 "$work/mariadb.log"
        load_failed="$load_failed mariadb"
    fi
fi
# CockroachDB's RESTORE refuses a database that exists, and the stack's first
# boot may have made the same ones: dropped first, by name, with the certs the
# container uses. A failure here leaves the engine empty and the snapshot
# intact, and is named below.
ck=$(find "$work" -name 'cockroach-*.tar' | head -n1)
if [ -n "$ck" ]; then
    if ready mini-baas-cockroach && crdb_drop_user_databases >"$work/cockroach.log" 2>&1 &&
        bash /opt/grobase/scripts/ops/engine-backup.sh restore cockroach "$ck" >>"$work/cockroach.log" 2>&1; then
        echo "restore: cockroach loaded"
    else
        echo "restore: cockroach restore failed:"; tail -n3 "$work/cockroach.log"
        load_failed="$load_failed cockroach"
    fi
fi
[ -z "$load_failed" ] || echo "restore: ✗ not loaded:$load_failed (lines above)"
[ "${tables:-0}" -gt 0 ] || exit 1
if ! command -v b2b-stack-health >/dev/null 2>&1; then
    echo "restore: ✗ cannot judge the stack: no b2b-stack-health in this guest (make var_gc installs it)"
    exit 1
fi
b2b-stack-health 300 || {
    echo "restore: ✗ data loaded, but the stack is not healthy (lines above): a secret, a volume or a service no longer agree"
    exit 1
}
[ -z "$load_failed" ] || exit 1
RESTOREEOF
chmod 755 /usr/local/sbin/b2b-restore

cat >/etc/systemd/system/b2b-backup.service <<'UNITEOF'
[Unit]
Description=born2root: dump the engines and snapshot them with restic
After=docker.service
ConditionPathExists=/etc/b2b/restic.pass

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/b2b-backup
UNITEOF
cat >/etc/systemd/system/b2b-backup.timer <<'UNITEOF'
[Unit]
Description=born2root: hourly backup while the guest is up

[Timer]
OnCalendar=hourly
RandomizedDelaySec=5m
Persistent=true

[Install]
WantedBy=timers.target
UNITEOF
cat >/etc/systemd/system/b2b-weekly-proof.service <<'UNITEOF'
[Unit]
Description=born2root: restic check and a restore drill
After=docker.service
ConditionPathExists=/etc/b2b/restic.pass

[Service]
Type=oneshot
Nice=15
IOSchedulingClass=idle
ExecStart=/usr/local/sbin/b2b-weekly-proof
UNITEOF
cat >/etc/systemd/system/b2b-weekly-proof.timer <<'UNITEOF'
[Unit]
Description=born2root: weekly proof that the backups restore

[Timer]
OnCalendar=weekly
RandomizedDelaySec=6h
Persistent=true

[Install]
WantedBy=timers.target
UNITEOF
systemctl daemon-reload
systemctl enable --now b2b-backup.timer >/dev/null 2>&1 || die "could not enable b2b-backup.timer"
systemctl enable --now b2b-weekly-proof.timer >/dev/null 2>&1 || die "could not enable b2b-weekly-proof.timer"

# The password, when the host sends one: BACKUP_PASS_FILE names a 600 file
# the host uploaded over SSH's stdin (backup_pull.sh). Moved, not copied, so
# nothing is left in /tmp.
if [ -n "${BACKUP_PASS_FILE:-}" ] && [ -s "$BACKUP_PASS_FILE" ]; then
    install -m 0600 -o root -g root "$BACKUP_PASS_FILE" /etc/b2b/restic.pass && rm -f "$BACKUP_PASS_FILE"
    log "restic password installed"
fi

# A repository the host pushed back (backup_pull.sh --restore): adopted only
# when the guest has none, so a rebuilt VM starts from yesterday's snapshots
# rather than an empty repo, and a guest that already has snapshots is never
# overwritten from outside.
if [ -n "${BACKUP_RESTORE_FROM:-}" ] && [ -d "$BACKUP_RESTORE_FROM/snapshots" ]; then
    if [ -d /var/backups/b2b/repo/snapshots ] && [ -n "$(ls -A /var/backups/b2b/repo/snapshots 2>/dev/null)" ]; then
        log "guest already has snapshots; the pushed repository was not adopted"
    else
        rm -rf /var/backups/b2b/repo
        cp -a "$BACKUP_RESTORE_FROM" /var/backups/b2b/repo
        chown -R root:root /var/backups/b2b/repo
        log "adopted the pushed repository ($(find /var/backups/b2b/repo/snapshots -type f | wc -l) snapshot(s))"
    fi
    rm -rf "$BACKUP_RESTORE_FROM"
fi
if [ "${BACKUP_RESTORE:-0}" = 1 ]; then
    [ -s /etc/b2b/restic.pass ] || die "cannot restore without /etc/b2b/restic.pass"
    /usr/local/sbin/b2b-restore "${BACKUP_RESTORE_SNAPSHOT:-}" || die "the restore failed"
fi

# A rebuilt guest, before anyone ran `make restore`: the hourly pull reaches it
# first, and a run here makes a fresh repository. The pull then refuses it for
# being another repository, and `make restore` keeps it for having snapshots, so
# the old copy could never come back. Asked as root: the login cannot read
# /var/backups/b2b until the first run has opened it.
if [ "${BACKUP_EXPECT_REPO:-0}" = 1 ] && [ "${BACKUP_RESTORE:-0}" != 1 ] && [ ! -e /var/backups/b2b/repo/config ]; then
    log "the host holds this VM's repository and this guest has none: a rebuild. make restore first"
    exit 4
fi

if [ -s /etc/b2b/restic.pass ] && [ "${BACKUP_RESTORE:-0}" != 1 ]; then
    log "password present; timer armed and a run follows"
    # The verdict waits until the permissions below are set. The install -d
    # at the top re-locks /var/backups/b2b to 0700 on every upload, and a run
    # that failed one dump still snapshotted the rest: left locked, the pull
    # counted 0 snapshots and refused the off-site copy, telling the user to
    # restore (mongo's dump, 2026-10-18 14:15).
    run_rc=0
    /usr/local/sbin/b2b-backup || run_rc=$?
    # The login pulls the repository off the guest (backup_pull.sh): group-
    # readable is enough, and the files are encrypted at rest.
    if [ -n "${BACKUP_PULL_USER:-}" ] && id "$BACKUP_PULL_USER" >/dev/null 2>&1; then
        chgrp -R "$BACKUP_PULL_USER" /var/backups/b2b/repo 2>/dev/null || true
        chmod -R g+rX /var/backups/b2b/repo 2>/dev/null || true
        # The parent must be traversable by that group too (710: enter, not
        # list) -- the first pull failed on "change_dir failed: Permission
        # denied" with the repository itself readable. dumps/ beside it stays
        # 700 root: those are plaintext.
        chgrp "$BACKUP_PULL_USER" /var/backups/b2b 2>/dev/null || true
        chmod 710 /var/backups/b2b 2>/dev/null || true
    fi
    case "$run_rc" in
    0) ;;
    3) exit 3 ;;
    *) die "the backup run failed" ;;
    esac
    if [ "${BACKUP_VERIFY:-0}" = 1 ]; then
        if RESTIC_PASSWORD_FILE=/etc/b2b/restic.pass RESTIC_REPOSITORY=/var/backups/b2b/repo \
            restic check --read-data-subset=10% >/dev/null 2>&1; then
            log "restic check: repository sound"
        else
            die "restic check FAILED on the guest's repository"
        fi
    fi
elif [ -s /etc/b2b/restic.pass ]; then
    log "restore done; timer armed"
else
    log "restic $(restic version 2>/dev/null | awk '{ print $2 }') installed; timer armed, idle until /etc/b2b/restic.pass exists (make backup)"
fi
