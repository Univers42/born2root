#!/usr/bin/env hellish
# set_seeds_guest.sh — load the vault's seeds into grobase, as root in the guest.
# set_seeds.sh uploads them and says why this exists. The order is the whole job:
#
#   1. Refuse a populated platform, exit 4, nothing touched (groot's
#      restore-if-empty rule). Unknown counts as populated. SEEDS_FORCE=1 overrides.
#      A run that died half way is not populated: it left /etc/b2b/seeds.pending,
#      so the rerun finishes the job. Without that its partial rows read as a
#      platform with data, exit 4, and `make all` went green over half a restore.
#   2. Keep the seeds at /mnt/storage/seeds, so a reload needs no network. That is
#      a bind mount of /var: `/` is 5.5 GiB, and the disk's room is in /var.
#   3. Stack down. Merge the vault's secrets, put its CA back, re-assemble .env.
#      Only what the data was written under: VAULT_ENC_KEY, JWT_SECRET and the API
#      keys, which the apps' env files in the same vault carry too. A guest that
#      kept its own could load the rows and read none of them. Never the engines'
#      passwords: "the target's .env is the authority on credentials, the seeds on
#      data" (vault-restore.sh), so no volume is wiped, and no superuser password
#      has to be rewritten by reconcile-credentials, which grobase keeps explicit.
#      Doing the opposite failed: an emptied Postgres has no roles for the dump's
#      DROP ROLE lines, and the replay stopped (2026-11-04). The one place those
#      passwords sit inside the rows is each mount's sealed DSN, and step 5
#      rewrites those to this guest's logins.
#   4. Engines alone. Their volumes hold a bootstrapped cluster, which is what the
#      replay expects to clear.
#   5. grobase's vault-restore with SKIP_STACK_CYCLE=1. Without that it ends on
#      `make up EDITION=devlean`, whose _rm-stale drops containers a PACKAGE=max
#      stack never gets back (vault-restore.sh's own warning).
#   6. Full stack, then b2b-stack-health and row counts: the run fails if the
#      platform is unhealthy or came back empty.
#   7. Open the mounts, with the app key the host sent. A healthy stack says nothing
#      about them: on 2026-11-04 all of the above passed with every mount on a platform
#      engine answering 502. This also loads the sqlite demo, whose tables are in no
#      seed. The vault's sqlite-data.tar.gz is a 4 KiB file with none, so it is not
#      unpacked: laid over a live database it left the old -wal and -shm behind, sqlite
#      replayed them onto a different file, and every insert answered "database disk
#      image is malformed" (2026-11-04). grobase's own restore never touched that volume.
#
# On success /etc/b2b/seeds.last, world-readable, holds seeded_at, vintage, project and rows:
# the record that this platform's rows came from a seed.
#
# Exit: 0 seeded · 4 populated, refused, nothing changed · 1 failed (see above it)
set -u

log() { printf '[seeds] %s\n' "$*"; }
die() {
    printf '[seeds] ERROR: %s\n' "$*" >&2
    exit 1
}
[ "$(id -u)" = 0 ] || die "run as root"

FROM="${SEEDS_FROM:?the host sets this}"
FORCE="${SEEDS_FORCE:-0}"
PROJECT="${SEEDS_PROJECT:-groot}"
GROBASE=/opt/grobase
BACKING=/var/lib/b2b-storage
STORE=/mnt/storage
SEEDS="$STORE/seeds"
STATUS=/etc/b2b/seeds.last
PENDING=/etc/b2b/seeds.pending
ENGINES_RUN="postgres mysql mongo redis minio mssql dynamodb-local"
trap 'rm -rf "$FROM"' EXIT

# Engine credentials and the URLs that embed them: this guest's, see step 3.
ENGINE_CREDENTIALS="POSTGRES_PASSWORD AUTHENTICATOR_PASSWORD DATABASE_URL PGRST_DB_URI ADAPTER_REGISTRY_DATABASE_URL MINIO_ROOT_PASSWORD MONGO_INITDB_ROOT_PASSWORD"

# merge_secrets <guest file> <vault file> <out>: the guest's file with each key the
# vault also holds taking the vault's value, ENGINE_CREDENTIALS excepted. Not a
# replace: the vault's copy predates MARIADB_*, MSSQL_SA_PASSWORD and the
# DATA_PLANE_KEY_* this stack minted.
merge_secrets() {
    awk -v keep=" $ENGINE_CREDENTIALS " '
        { k = $0; sub(/=.*/, "", k) }
        NR == FNR { if (k != $0 && !index(keep, " " k " ")) vault[k] = $0; next }
        k in vault { print vault[k]; seen[k] = 1; next }
        { print }
        END { for (k in vault) if (!(k in seen)) print vault[k] }
    ' "$2" "$1" >"$3"
}

# platform_rows: accounts, tenants and keys together, or nothing when Postgres
# cannot say. Caveat: an engine holding rows while these three tables are empty
# reads as empty; a tenant-less platform with data has no tenant to own it.
platform_rows() {
    docker exec mini-baas-postgres psql -U postgres -tA -c \
        "select (select count(*) from auth.users) + (select count(*) from public.tenants) + (select count(*) from public.tenant_api_keys)" 2>/dev/null | tail -n1
}

storage_ready() {
    install -d -m 0700 "$BACKING"
    install -d -m 0755 "$STORE"
    grep -qs "^$BACKING $STORE " /etc/fstab || printf '%s %s none bind,nofail 0 0\n' "$BACKING" "$STORE" >>/etc/fstab
    mountpoint -q "$STORE" || mount "$STORE" || die "could not mount $STORE"
}

[ -f "$GROBASE/.env" ] || die "no grobase in this guest: make grobase"
[ -f "$FROM/secrets/MANIFEST.json" ] || die "$FROM holds no seed set"
rows=$(platform_rows)
case "$rows" in
'' | *[!0-9]*) populated="cannot tell" ;;
0) populated="" ;;
*) populated="$rows row(s)" ;;
esac
if [ -n "$populated" ] && [ "$FORCE" != 1 ] && [ ! -e "$PENDING" ]; then
    log "this platform already holds data ($populated): nothing changed"
    exit 4
fi

storage_ready
rm -rf "$SEEDS.new"
mkdir -p "$SEEDS.new" || die "could not create $SEEDS.new"
cp -a "$FROM/." "$SEEDS.new/" || die "could not copy the seeds into $STORE"
(cd "$SEEDS.new/secrets" && sha256sum -c --quiet --ignore-missing SHA256SUMS) || die "the seeds fail their checksums"
chown -R root:root "$SEEDS.new" && chmod -R go-rwx "$SEEDS.new"
rm -rf "$SEEDS" && mv "$SEEDS.new" "$SEEDS"
vintage=$(sed -n 's/.*"created_utc"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$SEEDS/secrets/MANIFEST.json" | head -n1)
log "seeds kept in $SEEDS (captured ${vintage:-at an unknown date})"

# A last way back, for a forced reload over real data.
if [ -s /etc/b2b/restic.pass ]; then
    /usr/local/sbin/b2b-backup || log "WARN the snapshot before seeding exited $?"
fi

# From here the platform is neither what it was nor what it will be.
rm -f "$STATUS"
: >"$PENDING"

conf=/etc/b2b/grobase.conf
pkg=$(sed -n 's/^GROBASE_PACKAGE=//p' "$conf" 2>/dev/null)
add=$(sed -n 's/^GROBASE_ADDONS=//p' "$conf" 2>/dev/null)
up() { make --no-print-directory up PACKAGE="${pkg:-pro}" ADDONS="$add" "$@" >/dev/null; }
cd "$GROBASE" || die "no $GROBASE"
make --no-print-directory down PACKAGE="${pkg:-pro}" ADDONS="$add" >/dev/null 2>&1 || log "WARN make down reported a problem"

owner=$(stat -c %U "$GROBASE")
merged=$(mktemp /var/tmp/b2b-seeds.XXXXXX)
merge_secrets "$GROBASE/.env.secrets" "$SEEDS/env.secrets" "$merged" || die "could not merge the secrets"
install -m 0600 -o "$owner" -g "$owner" "$merged" "$GROBASE/.env.secrets" || die "could not install the secrets"
rm -f "$merged"
if [ -f "$SEEDS/secrets/grobase-certs.tar.gz" ]; then
    tar -xzf "$SEEDS/secrets/grobase-certs.tar.gz" --strip-components=2 -C "$GROBASE" apps/grobase/certs ||
        die "could not unpack the CA"
    chown -R "$owner:$owner" "$GROBASE/certs" || die "could not give the CA to $owner"
fi
[ ! -x /usr/local/sbin/b2b-grobase-env ] || /usr/local/sbin/b2b-grobase-env >/dev/null || die "b2b-grobase-env failed"
ENV_ORPHANS=carry make --no-print-directory env >/dev/null || die "make env failed"
for f in .env .env.prev; do
    [ ! -e "$f" ] || chown "$owner:$owner" "$f"
done
make --no-print-directory certs >/dev/null || die "make certs failed"

up SERVICE="$ENGINES_RUN" || die "the engines did not start"
log "engines up; loading the seeds"
if ! SKIP_STACK_CYCLE=1 SEED_DIR="$SEEDS/secrets" STATE_DIR="$STORE/restore-state" bash scripts/ops/vault-restore.sh; then
    # A running platform short of some data beats a dead one, and a rerun with
    # FORCE=1 finds it as it would any other. pre-restore-*.sql.gz is the way back.
    up || log "WARN the stack did not come back either"
    die "vault-restore failed (its lines are above); $STORE/restore-state holds the dump taken before it"
fi

up || die "the full stack did not start"
/usr/local/sbin/b2b-stack-health 300 || die "the data loaded, but the stack is not healthy (lines above)"
rows=$(platform_rows)
case "$rows" in
'' | 0 | *[!0-9]*) die "the stack is healthy but the platform came back empty ($rows)" ;;
esac
[ -s "$FROM/app.key" ] || die "the host sent no app key"
log "opening the seed's mounts"
BAAS_API_KEY=$(cat "$FROM/app.key") AFTER_RESTORE=1 runuser -u "$owner" -- bash scripts/seed/osionos-extra-engines.sh ||
    die "the seed loaded, but its mounts do not all open (lines above)"
printf 'seeded_at=%s\nvintage=%s\nproject=%s\nrows=%s\n' "$(date -u +%FT%TZ)" "$vintage" "$PROJECT" "$rows" >"$STATUS"
chmod 644 "$STATUS"
rm -f "$PENDING"
log "seeded: $rows platform row(s), captured $vintage"
