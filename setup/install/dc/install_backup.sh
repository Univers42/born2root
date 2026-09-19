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
    docker exec mini-baas-mongo sh -c 'mongodump --archive -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin' >"$DUMPS/mongo-$stamp.archive" && n=$((n + 1)) ||
        echo "b2b-backup: mongo dump failed"
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

if [ -s /etc/b2b/restic.pass ]; then
    log "password present; timer armed and first run follows"
    /usr/local/sbin/b2b-backup || true
else
    log "restic $(restic version 2>/dev/null | awk '{ print $2 }') installed; timer armed, idle until /etc/b2b/restic.pass exists (make backup)"
fi
