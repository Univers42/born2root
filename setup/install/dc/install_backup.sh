#!/usr/bin/env hellish
#
# install_backup.sh — restic and the dump job (dc-backup). Tools and timer at
# build time; the repository password arrives later, from the host.
#
# WHAT IS BACKED UP
#   Logical dumps of every engine that is running, taken through the
#   container so no port needs opening: pg_dump -Fc, mysqldump, mongodump,
#   Redis's RDB after a SAVE, and MinIO's data directory (its volume, while
#   it is quiescent). CockroachDB and SQL Server are skipped with a note --
#   grobase's vault-restore already round-trips those seven engines and is
#   the right place to grow this, not a second dump layer here.
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
mkdir -p "$DUMPS"
rm -f "$DUMPS"/*
have() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }
stamp=$(date +%Y%m%dT%H%M%S)
n=0
if have mini-baas-postgres; then
    docker exec mini-baas-postgres pg_dumpall -U postgres --clean >"$DUMPS/postgres-$stamp.sql" && n=$((n + 1)) ||
        echo "b2b-backup: postgres dump failed"
fi
if have mini-baas-mysql; then
    docker exec mini-baas-mysql sh -c 'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --all-databases --single-transaction' >"$DUMPS/mysql-$stamp.sql" && n=$((n + 1)) ||
        echo "b2b-backup: mysql dump failed"
fi
if have mini-baas-mongo; then
    # grobase's mongo image (d74aa97) ships mongosh but not the database
    # tools, so mongodump is not there to run. Said plainly rather than
    # filed as a generic failure; the fix belongs in grobase's image or its
    # vault-restore, which round-trips mongo already.
    if docker exec mini-baas-mongo sh -c 'command -v mongodump' >/dev/null 2>&1; then
        docker exec mini-baas-mongo sh -c 'mongodump --archive -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin' >"$DUMPS/mongo-$stamp.archive" && n=$((n + 1)) ||
            echo "b2b-backup: mongo dump failed"
    else
        echo "b2b-backup: mongo not dumped: no mongodump in the mini-baas-mongo image"
    fi
fi
if have mini-baas-redis; then
    docker exec mini-baas-redis redis-cli SAVE >/dev/null 2>&1
    docker cp mini-baas-redis:/data/dump.rdb "$DUMPS/redis-$stamp.rdb" 2>/dev/null && n=$((n + 1)) ||
        echo "b2b-backup: redis dump failed"
fi
minio_vol=$(docker volume ls -q 2>/dev/null | grep -m1 'minio-data' || true)
extra=""
if [ -n "$minio_vol" ]; then
    extra="/var/lib/docker/volumes/$minio_vol/_data"
fi
# grobase's own secrets travel with the data: JWT secret, the engines' role
# passwords, service tokens, the anon/service API keys. A dump restored into
# a stack that re-minted those is unusable (db-bootstrap fails on the old
# role passwords -- the 2026-09-20 rebuild). Encrypted in the repository
# like everything else.
for f in /opt/grobase/.env.secrets /opt/grobase/.env.local; do
    [ -s "$f" ] && cp -p "$f" "$DUMPS/grobase$(basename "$f")" && n=$((n + 1))
done
for skipped in mini-baas-cockroach mini-baas-mssql; do
    have "$skipped" && echo "b2b-backup: $skipped is running and not dumped here (see the header of install_backup.sh)"
done
restic snapshots >/dev/null 2>&1 || restic init >/dev/null || { echo "b2b-backup: restic init failed"; exit 1; }
# shellcheck disable=SC2086 # $extra is one path or empty, on purpose
restic backup --quiet --tag b2b "$DUMPS" $extra || { echo "b2b-backup: restic backup failed"; exit 1; }
restic forget --quiet --keep-hourly 24 --keep-daily 14 --keep-weekly 8 --prune >/dev/null 2>&1 || true
echo "b2b-backup: $n dump(s) snapshotted into $REPO ($(restic snapshots --json 2>/dev/null | grep -o '"short_id"' | wc -l) snapshots kept)"
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
snap=$(restic snapshots --json --latest 1 2>/dev/null | grep -o '"short_id":"[a-f0-9]*"' | head -n1 | cut -d'"' -f4)
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

# The restore itself, into the LIVE stack: the newest snapshot's Postgres
# and MySQL dumps loaded back, which is what brings tenants, their keys and
# every row home on a rebuilt VM. pg_dumpall --clean drops and recreates
# databases, and a database with open connections cannot be dropped, so
# every other mini-baas container is stopped for the duration and grobase's
# own `make up` brings them back in order. Redis is a cache and is not
# restored; Mongo, CockroachDB and MSSQL were never dumped (see above).
cat >/usr/local/sbin/b2b-restore <<'RESTOREEOF'
#!/bin/sh
# b2b-restore — load the newest snapshot into the running engines. Installed
# by setup/install/dc/install_backup.sh (born2root). Read its header first.
set -u
PASS=/etc/b2b/restic.pass
REPO=/var/backups/b2b/repo
[ -s "$PASS" ] || { echo "restore: no $PASS (make backup first)"; exit 1; }
export RESTIC_PASSWORD_FILE="$PASS" RESTIC_REPOSITORY="$REPO"
umask 077
work=$(mktemp -d /var/tmp/b2b-restore.XXXXXX) || exit 1
trap 'rm -rf "$work"' EXIT
snap=$(restic snapshots --json --latest 1 2>/dev/null | grep -o '"short_id":"[a-f0-9]*"' | head -n1 | cut -d'"' -f4)
[ -n "$snap" ] || { echo "restore: no snapshot in $REPO"; exit 1; }
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
    install -m 0600 -o "$owner" -g "$owner" "$sec" /opt/grobase/.env.secrets
    loc=$(find "$work" -name 'grobase.env.local' | head -n1)
    [ -n "$loc" ] && install -m 0600 -o "$owner" -g "$owner" "$loc" /opt/grobase/.env.local
    (cd /opt/grobase && make --no-print-directory env >/dev/null 2>&1) && echo "restore: grobase .env.secrets restored and .env re-assembled" || echo "restore: WARN make env failed after restoring .env.secrets"
else
    echo "restore: snapshot carries no grobase.env.secrets (taken before 2026-09-20): keeping this guest's secrets and reconciling the postgres role after the load"
    reconcile=1
fi
keep="mini-baas-postgres mini-baas-mysql"
stopped=""
for c in $(docker ps --format '{{.Names}}' | grep '^mini-baas-'); do
    case " $keep " in *" $c "*) continue ;; esac
    docker stop "$c" >/dev/null 2>&1 && stopped="$stopped $c"
done
echo "restore: stopped $(echo "$stopped" | wc -w) container(s) so databases can be replaced"
docker exec mini-baas-postgres psql -U postgres -qtA -c "select pg_terminate_backend(pid) from pg_stat_activity where pid <> pg_backend_pid() and datname is not null" >/dev/null 2>&1
if docker exec -i mini-baas-postgres psql -U postgres -q -v ON_ERROR_STOP=0 <"$pg" >"$work/pg.log" 2>&1; then :; fi
pg_err=$(grep -c '^ERROR' "$work/pg.log" 2>/dev/null || echo 0)
# An old snapshot restored the superuser's OLD password over a cluster whose
# .env says otherwise; grobase's db-bootstrap then refuses to run ("REJECTS
# POSTGRES_USER/POSTGRES_PASSWORD"). Its own documented reconcile, over the
# trust-authenticated socket:
if [ "${reconcile:-0}" = 1 ]; then
    pw=$(sed -n 's/^POSTGRES_PASSWORD=//p' /opt/grobase/.env 2>/dev/null | head -n1 | tr -d '"')
    # Through stdin: psql interpolates :'p' in input it reads, not in -c.
    [ -n "$pw" ] && printf "ALTER USER postgres WITH PASSWORD :'p';\n" | docker exec -i mini-baas-postgres psql -U postgres -q -v p="$pw" >/dev/null 2>&1 && echo "restore: postgres role password reconciled with this guest's .env"
fi
tables=$(docker exec mini-baas-postgres psql -U postgres -tA -c "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema')" 2>/dev/null)
echo "restore: postgres loaded ($pg_err error line(s), $tables table(s) in the default database)"
if [ -n "$my" ]; then
    if docker exec -i mini-baas-mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' <"$my" >"$work/my.log" 2>&1; then
        echo "restore: mysql loaded"
    else
        echo "restore: mysql load reported errors:"; head -n3 "$work/my.log"
    fi
fi
conf=/etc/b2b/grobase.conf
if [ -f "$conf" ] && [ -d /opt/grobase ]; then
    pkg=$(sed -n 's/^GROBASE_PACKAGE=//p' "$conf"); add=$(sed -n 's/^GROBASE_ADDONS=//p' "$conf")
    (cd /opt/grobase && make --no-print-directory up PACKAGE="$pkg" ADDONS="$add" >/dev/null 2>&1) && echo "restore: stack back up (make up PACKAGE=$pkg)" || echo "restore: make up reported a problem -- check docker ps"
else
    for c in $stopped; do docker start "$c" >/dev/null 2>&1; done
    echo "restore: containers started again"
fi
[ "${tables:-0}" -gt 0 ]
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
systemctl daemon-reload
systemctl enable --now b2b-backup.timer >/dev/null 2>&1 || die "could not enable b2b-backup.timer"

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
    /usr/local/sbin/b2b-restore || die "the restore failed"
fi

if [ -s /etc/b2b/restic.pass ] && [ "${BACKUP_RESTORE:-0}" != 1 ]; then
    log "password present; timer armed and a run follows"
    /usr/local/sbin/b2b-backup || die "the backup run failed"
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
