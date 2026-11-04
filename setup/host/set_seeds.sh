#!/usr/bin/env hellish
# set_seeds.sh — turn a freshly built, empty datacenter into a working one, from
# the team's seeds in vault42. One machine, no carried disk: the data's only
# requirement is the 42ctl credentials file.
#
# WHAT IT REPLACES
#   A rebuild used to come back empty unless someone carried a restic repository
#   from /mnt/storage on another machine. The seeds live in vault42 (project
#   [dc] seeds_project), written by grobase's `make vault-seed`, sealed to the
#   team, so any seat holding the credentials reproduces the same platform.
#
# THE ORDER OF THE SOURCES
#   A restic copy at backup_dest is newer than any seed, so it wins: with one
#   present `make all` leaves the guest for `make restore`, and only asking for
#   this by name goes on. A platform that already holds data is never touched
#   without B2B_SEEDS_FORCE=1 (`make set_seeds FORCE=1`), so re-running is safe,
#   and `make all` on a built machine stays a no-op.
#
# CREDENTIALS: THAT ONE FILE IS ENOUGH
#   [dc] seeds_env names the KEY=VALUE file (FT_PASSPHRASE, FT_EMAIL, FT_PASSWORD,
#   FT_TENANT, FT_KEYSTORE_B64), read with sed and never sourced. The values stay
#   in this process's environment: never a command line, never the guest, never a
#   log. The seeds reach the guest over ssh and sit decrypted only in a 0700
#   directory here, removed on every way out, then in /mnt/storage/seeds inside the
#   LUKS disk.
#
#   Vault42 is zero-knowledge, so a login is not a way in: on a machine with no
#   keystore 42ctl signs in and then stops at "no keystore" (measured 2026-11-04),
#   and `keys recover` wants a code from your mailbox. FT_KEYSTORE_B64 is that
#   keystore, sealed by FT_PASSPHRASE, so carrying it beside the passphrase costs
#   nothing the file did not already hold. `make seeds_bundle` writes it, once, on
#   a machine that has the keystore; with it a machine holding only this file
#   rebuilds everything, and without it a terminal is needed for the code.
#   A missing 42ctl is fetched into ~/.local/bin by its own installer.
#
# A GUEST THAT LOST GROBASE
#   `make all` on a built machine boots it and stops, so grobase removed from a
#   guest stayed removed. It is reinstalled here first. seeds.last alone proves
#   nothing either: "already seeded" also takes rows in the platform.
#
# Caveat: the seeds are as old as the last `make vault-seed` (their MANIFEST says
# when, and this prints it), so a reseed brings back that day, not yesterday.
#
#   make seeds_bundle         put the sealed keystore into the credentials file
#   make set_seeds            fetch, keep them in the guest, load them
#   make set_seeds FORCE=1    the same over a populated platform (snapshot first)
#   set_seeds.sh --auto       what `make all` and `make datacenter` run: anything
#                             missing is a note, and a backup copy takes precedence
set -u

# shellcheck source=setup/host/dc_lib.sh
. "$(dirname "${BASH_SOURCE[0]:-$0}")/dc_lib.sh"

MODE="${1:-}"
FORCE="${B2B_SEEDS_FORCE:-0}"
case "$FORCE" in 0 | 1) ;; *) die "B2B_SEEDS_FORCE must be 0 or 1, got '$FORCE'" ;; esac
CRED=${B2B_SEEDS_ENV:-$(b2b_get B2B_DC_SEEDS_ENV)}
PROJECT=${B2B_SEEDS_PROJECT:-$(b2b_get B2B_DC_SEEDS_PROJECT)}
PROJECT=${PROJECT:-groot}
CTL="${B2B_CTL:-}"
KEYSTORE="${XDG_CONFIG_HOME:-$HOME/.config}/42ctl/keystore.v42"

# not_now <why>: a stop for a direct call, a note for `make all`.
not_now() {
    [ "$MODE" = --auto ] || die "$1"
    warn "no seeds loaded: $1"
    exit 0
}

# cred KEY: one value from the credentials file.
cred() { sed -n "s/^$1=//p" "$CRED" | head -n1; }

[ -n "$CRED" ] || not_now "[dc] seeds_env names no credentials file in this profile"
[ -r "$CRED" ] || not_now "cannot read $CRED ([dc] seeds_env)"

if [ "$MODE" = --bundle ]; then
    [ -s "$KEYSTORE" ] || die "no keystore at $KEYSTORE to carry: run this on a machine that has one"
    tmp=$(mktemp "$CRED.XXXXXX") || die "cannot write beside $CRED"
    grep -v '^FT_KEYSTORE_B64=' "$CRED" >"$tmp"
    printf 'FT_KEYSTORE_B64=%s\n' "$(base64 -w0 "$KEYSTORE")" >>"$tmp"
    chmod 600 "$tmp" || die "could not protect $tmp"
    mv "$tmp" "$CRED" || die "could not update $CRED"
    ok "$CRED now carries the sealed keystore, mode 600: that file alone rebuilds this datacenter"
    exit 0
fi

# ensure_ctl: 42ctl from PATH or ~/.local/bin, else its own installer, which
# puts it in ~/.local/bin. Read to a file first, so a dropped connection cannot
# run half a script.
# Caveat: this takes 42ctl's latest release, so two rebuilds can differ in
# 42ctl's version; the vault's format is what ties them together.
ensure_ctl() {
    local installer
    [ -n "$CTL" ] || CTL=$(command -v 42ctl 2>/dev/null) || CTL="$HOME/.local/bin/42ctl"
    [ -x "$CTL" ] && return 0
    info "no 42ctl here: installing it"
    installer=$(mktemp) || return 1
    curl --proto '=https' --tlsv1.2 -fsSL --max-time 30 https://raw.githubusercontent.com/Univers42/42ctl/main/install.sh -o "$installer" &&
        env FT_BIN_DIR="$HOME/.local/bin" FT_NO_MODIFY_PATH=1 sh "$installer" >/dev/null 2>&1
    rm -f "$installer"
    CTL="$HOME/.local/bin/42ctl"
    [ -x "$CTL" ]
}
ensure_ctl || not_now "no 42ctl on this host, and its installer failed"
FT_PASSPHRASE=$(cred FT_PASSPHRASE)
[ -n "$FT_PASSPHRASE" ] || not_now "$CRED holds no FT_PASSPHRASE"
export FT_PASSPHRASE
if [ "$MODE" = --auto ]; then
    dest=$("${SCRIPT_SH:-bash}" "$DC_ROOT/setup/host/backup_pull.sh" --where 2>/dev/null)
    [ ! -e "$dest/repo/config" ] || not_now "a backup copy at $dest is newer than any seed: make restore"
fi

dc_connect

# ensure_grobase: put it back in a guest that lost it. provision_vm.sh's grobase
# action reports a failure and exits 0, so the result is what is read.
reinstalled=0
ensure_grobase() {
    vm_ssh 'test -f /opt/grobase/.env' 2>/dev/null && return 0
    info "no grobase in $VM_NAME: installing it (images included, this takes a while)"
    VM_PATH="${VM_PATH:-$DC_ROOT/disk_images}" "${SCRIPT_SH:-bash}" "$DC_ROOT/setup/host/provision_vm.sh" "$VM_NAME" grobase
    vm_ssh 'test -f /opt/grobase/.env' 2>/dev/null || die "grobase did not install in $VM_NAME (the [grobase] lines above)"
    reinstalled=1
}
ensure_grobase

# Rows through the login, which is in the docker group. Unknown reads as none:
# the guest repeats this as root, and that one refuses on unknown.
rows=$(vm_ssh "docker exec mini-baas-postgres psql -U postgres -tA -c 'select count(*) from public.tenants' 2>/dev/null" 2>/dev/null | tail -n1)
case "$rows" in '' | *[!0-9]*) rows=0 ;; esac
last=$(vm_ssh 'cat /etc/b2b/seeds.last 2>/dev/null' 2>/dev/null)
if [ -n "$last" ] && [ "$rows" -gt 0 ] && [ "$reinstalled" = 0 ] && [ "$FORCE" != 1 ]; then
    ok "already seeded ($(printf '%s\n' "$last" | sed -n 's/^vintage=//p' | head -n1)); make set_seeds FORCE=1 reloads"
    exit 0
fi

# ensure_identity: the keystore, from the credentials file, or by the emailed code
# when someone is here to read it.
ensure_identity() {
    local sealed
    [ -s "$KEYSTORE" ] && return 0
    sealed=$(cred FT_KEYSTORE_B64)
    if [ -n "$sealed" ]; then
        (umask 077 && mkdir -p "${KEYSTORE%/*}" && printf '%s' "$sealed" | base64 -d >"$KEYSTORE") ||
            die "could not restore the keystore from $CRED"
        ok "keystore restored from $CRED"
        return 0
    fi
    [ -t 0 ] || not_now "no keystore at $KEYSTORE, and $CRED carries none: make seeds_bundle on a machine that has it, or run make set_seeds from a terminal for the emailed code"
    "$CTL" keys recover --email "$(cred FT_EMAIL)" || die "42ctl keys recover failed"
}
ensure_identity

# sign_in: both credentials of a login, from the same file.
sign_in() {
    FT_PASSWORD=$(cred FT_PASSWORD) || return 1
    export FT_PASSWORD
    "$CTL" auth login --password --email "$(cred FT_EMAIL)" --tenant "$(cred FT_TENANT)" </dev/null >/dev/null 2>&1 ||
        die "the 42ctl login was refused: check FT_EMAIL, FT_PASSWORD and FT_TENANT in $CRED"
    unset FT_PASSWORD
    info "42ctl session renewed"
}
# "session only" is not enough: a contract binds the keystore, and vault and pull read through it.
case "$("$CTL" auth status 2>&1)" in
*"session and contract"*) ;;
*) sign_in ;;
esac

umask 077
work=$(mktemp -d "${TMPDIR:-/tmp}/b2b-seeds.XXXXXX") || die "no temporary directory"
trap 'rm -rf "$work"' EXIT
# A fresh 42ctl knows the vault but not where its large blobs live, and anything above the
# transport ceiling (minio.tar.gz, 7 MB) then stops with "this profile names no object store".
# Public configuration; infra/S3_* below is what opens the bucket.
"$CTL" config endpoint --blobstore https://fly.storage.tigris.dev --bucket vault42-seeds --region auto >/dev/null ||
    die "42ctl could not record the object store"
info "fetching univers42/$PROJECT/prod from the vault"
# groot's order (scripts/vault42-pull-everything.sh): the shared environment, then the personal
# vault, errors kept. A contract left on another login reads as logged in here and still refuses
# with "contract not bound to this key", so one sign-in and one retry. That read as a failed
# build once, on a bare `vault get` with its error thrown away (2026-11-04).
vault_secret() {
    "$CTL" env secret get "$1" --org univers42 --project "$PROJECT" --env prod 2>>"$work/secret.err" ||
        "$CTL" vault get "$1" 2>>"$work/secret.err"
}
load_object_store_key() {
    FT_S3_KEY=$(vault_secret infra/S3_KEY) && FT_S3_SECRET=$(vault_secret infra/S3_SECRET)
}
# `auth status` above reads local state, so a session the server has expired still says
# "session and contract": env pull came back HTTP 401 on a seat idle for an afternoon, and
# stopped a reseed (2026-11-04). The same one sign-in and one retry as a stray contract.
session_refused() { grep -qE 'contract not bound to this key|HTTP 401' "$1"; }
if ! load_object_store_key; then
    session_refused "$work/secret.err" && sign_in
    load_object_store_key || die "cannot read infra/S3_KEY and infra/S3_SECRET: $(tail -n2 "$work/secret.err" | tr '\n' ' ')"
fi
export FT_S3_KEY FT_S3_SECRET
# The shared environment, by name, and only what this platform loads: the same tree holds other
# projects' archives, and `42ctl pull` is a personal tree a fresh identity may not have.
only=(--only apps/grobase/.env.secrets --only .env.local)
for f in MANIFEST.json SHA256SUMS postgres-all.sql.gz mysql-all.sql.gz mongo.archive.gz minio.tar.gz \
    redis.rdb mssql-all.tar.gz dynamodb-all.tar.gz grobase-certs.tar.gz; do
    only+=(--only "secrets/$f")
done
pull_seeds() { (cd "$work" && "$CTL" env pull --org univers42 --project "$PROJECT" --env prod "${only[@]}" --apply) >"$work/pull.log" 2>&1; }
if ! pull_seeds; then
    session_refused "$work/pull.log" && sign_in
    if ! pull_seeds; then
        tail -n3 "$work/pull.log" >&2
        die "42ctl could not fetch the seeds"
    fi
fi
unset FT_S3_KEY FT_S3_SECRET

[ -f "$work/secrets/MANIFEST.json" ] || die "project $PROJECT has no seed set (secrets/MANIFEST.json): grobase's make vault-seed writes one"
[ -f "$work/apps/grobase/.env.secrets" ] || die "project $PROJECT has no apps/grobase/.env.secrets: the seeds would load unreadable"
(cd "$work/secrets" && sha256sum -c --quiet --ignore-missing SHA256SUMS) || die "the seeds fail their checksums: nothing reached the guest"
vintage=$(sed -n 's/.*"created_utc"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$work/secrets/MANIFEST.json" | head -n1)
ok "seeds verified, captured ${vintage:-at an unknown date}"

stage="$work/stage"
mkdir -p "$stage" || die "could not stage the seeds"
cp -a "$work/secrets" "$stage/secrets" || die "could not stage the seeds"
cp -a "$work/apps/grobase/.env.secrets" "$stage/env.secrets" || die "could not stage the secrets"
# Only the app key can reach a mount, so it is what proves the mounts open once the seed is
# in, and the seed's sqlite file holds no tables for any restore to bring back. A tenant's
# credential, not part of the seed: the guest uses it once and the upload goes with it.
app_key=$(sed -n 's/^OSIONOS_BAAS_API_KEY=//p' "$work/.env.local" 2>/dev/null | head -n1 | tr -d "\"'\r")
[ -n "$app_key" ] || not_now "project $PROJECT has no OSIONOS_BAAS_API_KEY in .env.local: its mounts could not be opened"
printf '%s\n' "$app_key" >"$stage/app.key" || die "could not stage the app key"
unset app_key
remote="/tmp/.b2b-seeds.$$"
info "uploading the seeds to the guest"
rsync -a -e "ssh $SSH_OPTS_STR" "$stage/" "${VM_USER}@127.0.0.1:$remote/" || die "the upload failed"

rc=0
SEEDS_FROM="$remote" SEEDS_FORCE="$FORCE" SEEDS_PROJECT="$PROJECT" VM_PATH="${VM_PATH:-$DC_ROOT/disk_images}" \
    "${SCRIPT_SH:-bash}" "$DC_ROOT/setup/host/provision_vm.sh" "$VM_NAME" seeds || rc=$?
vm_ssh "rm -rf '$remote'" 2>/dev/null || true
case "$rc" in
0) ok "$VM_NAME is seeded" ;;
4) not_now "$VM_NAME already holds data, and nothing was changed: make set_seeds FORCE=1 replaces it" ;;
*) die "seeding failed (exit $rc): read the [seeds] lines above. It is safe to rerun: make set_seeds FORCE=1" ;;
esac
