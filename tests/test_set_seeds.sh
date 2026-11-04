#!/usr/bin/env hellish
# Pins `make set_seeds` (setup/host/set_seeds.sh, set_seeds_guest.sh) with 42ctl,
# ssh, rsync and provision_vm.sh stubbed.
#
# What it guards: a rebuilt datacenter came back empty unless a restic repository
# was carried in by hand. The seeds come from vault42 now, and four things must
# hold: credentials never reach a command line, a platform with data is never
# overwritten, a backup copy beats a seed, and seeds that fail their checksums
# never reach the guest.
set -u
cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." || exit 1
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
sleeper=""
trap '[ -z "$sleeper" ] || kill "$sleeper" 2>/dev/null; rm -rf "$T"' EXIT

# merge_secrets, the real one.
eval "$(awk '/^merge_secrets\(\) \{/{p=1} p{print} p && /^\}/{exit}' setup/host/set_seeds_guest.sh)"
eval "$(grep '^ENGINE_CREDENTIALS=' setup/host/set_seeds_guest.sh)"
printf 'JWT_SECRET=guest\nMARIADB_PASSWORD=guest\nPOSTGRES_PASSWORD=guest\n# a comment\n' >"$T/g"
printf 'JWT_SECRET=vault\nVAULT_ENC_KEY=vault\nPOSTGRES_PASSWORD=vault\nPGRST_DB_URI=vault\n' >"$T/v"
merge_secrets "$T/g" "$T/v" "$T/m"
check "merge: the vault's value wins" "$(grep -c '^JWT_SECRET=vault$' "$T/m")" 1
check "merge: a key only this stack has stays" "$(grep -c '^MARIADB_PASSWORD=guest$' "$T/m")" 1
check "merge: a key only the vault has arrives" "$(grep -c '^VAULT_ENC_KEY=vault$' "$T/m")" 1
check "merge: an engine keeps the password its volume took" "$(grep -c '^POSTGRES_PASSWORD=guest$' "$T/m")" 1
check "merge: the vault's URLs embedding its passwords stay out" "$(grep -c '^PGRST_DB_URI=' "$T/m")" 0
check "merge: no key twice" "$(cut -d= -f1 "$T/m" | sort | uniq -d | wc -l)" 0

mkdir -p "$T/bin" "$T/vms/vm1" "$T/seed/secrets" "$T/seed/apps/grobase"
printf 'ssh=4242\n' >"$T/vms/vm1/ports.env"
python3 -c 'import time; time.sleep(120)' "$T/vms/vm1/qemu.pid" &
sleeper=$!
echo "$sleeper" >"$T/vms/vm1/qemu.pid"
printf '{\n "created_utc": "2026-09-19T13:19:52Z",\n "captured": ["postgres"]\n}\n' >"$T/seed/secrets/MANIFEST.json"
printf 'K=v\n' >"$T/seed/apps/grobase/.env.secrets"
printf 'OTHER=x\nOSIONOS_BAAS_API_KEY="mbk_app-value"\n' >"$T/seed/.env.local"
(cd "$T/seed/secrets" && sha256sum MANIFEST.json >SHA256SUMS)
printf 'FT_PASSPHRASE=pp-value\nFT_EMAIL=e@x\nFT_PASSWORD=pw-value\nFT_TENANT=t\n' >"$T/cred"
printf 'RESTIC_PASSWORD=x\n' >"$T/s"
chmod 600 "$T/s" "$T/cred"
cat >"$T/bin/42ctl" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >>"$T/ctl.calls"
case "\$*" in
"auth status") cat "$T/session" 2>/dev/null ;;
"auth login"*) echo "login FT_PASSWORD=\${FT_PASSWORD:-}" >>"$T/ctl.env"; rm -f "$T/unbound" "$T/session-expired" ;;
"keys recover"*) echo recover >>"$T/ctl.env" ;;
"env secret get"*) [ -e "$T/env-secret" ] || { echo "not in this environment" >&2; exit 1; }; echo s3-value ;;
"vault get"*)
    if [ -e "$T/unbound" ]; then
        echo "error: contract not bound to this key" >&2
        exit 1
    fi
    [ ! -e "$T/vault-down" ] || { echo "error: the vault said no" >&2; exit 1; }
    echo s3-value
    ;;
"env pull"*)
    [ ! -e "$T/session-expired" ] || { echo "error: /v1/orgs/univers42/projects failed: HTTP 401" >&2; exit 1; }
    [ ! -e "$T/pull-refused" ] || { echo "the vault said no" >&2; exit 1; }; cp -a "$T/seed/." "\$PWD/"; echo "pull passphrase=\${FT_PASSPHRASE:-} s3=\${FT_S3_KEY:-}" >>"$T/ctl.env" ;;
esac
STUB
cat >"$T/bin/ssh" <<STUB
#!/bin/bash
case "\$*" in
*seeds.last*) cat "$T/seeds.last" 2>/dev/null ;;
*"test -f /opt/grobase/.env"*) [ ! -e "$T/no-grobase" ] ;;
*psql*) cat "$T/rows" 2>/dev/null ;;
esac
STUB
cat >"$T/bin/rsync" <<STUB
#!/bin/bash
echo rsync >>"$T/uploaded"
printf '%s\n' "\$*" >>"$T/rsync.args"
for a in "\$@"; do
    [ -f "\${a}app.key" ] || continue
    stat -c %a "\${a}app.key" >"$T/app.key.mode"
    cat "\${a}app.key" >"$T/app.key.sent"
    [ ! -e "\${a}.env.local" ] || echo sent >"$T/env.local.sent"
done
exit 0
STUB
cat >"$T/script_sh" <<STUB
#!/bin/bash
case "\$*" in
*provision_vm.sh*seeds)
    printf 'force=%s project=%s from=%s\n' "\$SEEDS_FORCE" "\$SEEDS_PROJECT" "\$SEEDS_FROM" >"$T/guest.args"
    exit "\${STUB_GUEST_RC:-0}"
    ;;
*provision_vm.sh*grobase)
    echo reinstalled >>"$T/grobase.calls"
    [ -e "$T/grobase-stays-gone" ] || rm -f "$T/no-grobase"
    exit 0
    ;;
esac
exec bash "\$@"
STUB
chmod +x "$T/bin/42ctl" "$T/bin/ssh" "$T/bin/rsync" "$T/script_sh"
echo "profile 'default': logged in — session and contract" >"$T/session"
# A keystore already here, except where a test takes it away: XDG_CONFIG_HOME is
# where 42ctl and the script both look.
mkdir -p "$T/xdg/42ctl"
echo sealed >"$T/xdg/42ctl/keystore.v42"
seeds() {
    env PATH="$T/bin:$PATH" B2B_CONFIG=tests/fixtures/default.toml B2B_SECRETS="$T/s" SCRIPT_SH="$T/script_sh" \
        XDG_CONFIG_HOME="$T/xdg" B2B_SEEDS_ENV="$T/cred" VM_NAME=vm1 VM_PATH="$T/vms" VM_USER=u BACKUP_DEST="$T/dest" TMPDIR="$T" "$@"
}
reset() { rm -f "$T/uploaded" "$T/guest.args" "$T/ctl.calls" "$T/ctl.env" "$T/seeds.last" "$T/rows" "$T/grobase.calls" "$T/no-grobase" "$T/grobase-stays-gone"; }

reset
seeds bash setup/host/set_seeds.sh >"$T/out" 2>&1
check "a clean run succeeds" "$?" 0
check "... the seeds reached the guest" "$(wc -l <"$T/uploaded")" 1
check "... the guest was asked, unforced" "$(sed -n 's/^force=\([0-9]\).*/\1/p' "$T/guest.args")" 0
check "... project groot by default" "$(grep -c 'project=groot' "$T/guest.args")" 1
check "... the passphrase reached 42ctl by environment" "$(grep -c 'pull passphrase=pp-value s3=s3-value' "$T/ctl.env")" 1
check "... and no credential on any command line" "$(grep -c 'pp-value\|pw-value\|s3-value' "$T/ctl.calls")" 0
check "... no credential in the output" "$(grep -c 'pp-value\|pw-value\|s3-value' "$T/out")" 0
check "... the shared environment, by name" "$(grep -c '^env pull --org univers42 --project groot --env prod ' "$T/ctl.calls")" 1
check "... only what this platform loads" "$(grep -c 'inception' "$T/ctl.calls")" 0
check "... with the object store a fresh 42ctl does not know" "$(grep -c '^config endpoint --blobstore ' "$T/ctl.calls")" 1
check "... it says how old the seeds are" "$(grep -c '2026-09-19' "$T/out")" 1
check "... the app key goes up, its quotes gone" "$(cat "$T/app.key.sent")" mbk_app-value
check "... readable by this login alone" "$(cat "$T/app.key.mode")" 600
check "... and on no command line" "$(cat "$T/ctl.calls" "$T/rsync.args" "$T/out" | grep -c 'mbk_app-value')" 0
check "... the rest of .env.local stays on the host" "$([ -e "$T/env.local.sent" ] && echo sent || echo kept)" kept
check "... the decrypted copy is gone" "$(find "$T" -maxdepth 1 -name 'b2b-seeds.*' | wc -l)" 0

reset
touch "$T/env-secret"
seeds bash setup/host/set_seeds.sh >"$T/out" 2>&1
check "the shared environment answers first, as groot reads it" "$(grep -c '^vault get' "$T/ctl.calls")" 0
rm "$T/env-secret"

reset
touch "$T/unbound"
seeds bash setup/host/set_seeds.sh >"$T/out" 2>&1
check "a contract left on another login: one sign-in, then it works" "$?" 0
check "... signed in once" "$(grep -c '^auth login' "$T/ctl.calls")" 1

reset
touch "$T/vault-down"
seeds bash setup/host/set_seeds.sh >"$T/out" 2>&1
check "a vault that refuses fails" "$?" 1
check "... and keeps the reason, unlike the build it stopped" "$(grep -c 'the vault said no' "$T/out")" 1
check "... without signing in for nothing" "$(cat "$T/ctl.calls" | grep -c '^auth login')" 0
rm "$T/vault-down"

reset
touch "$T/pull-refused"
seeds bash setup/host/set_seeds.sh >"$T/out" 2>&1
check "a refused fetch fails" "$?" 1
check "... showing the vault's own reason" "$(grep -c 'the vault said no' "$T/out")" 1
rm "$T/pull-refused"

reset
: >"$T/session"
seeds bash setup/host/set_seeds.sh >"$T/out" 2>&1
check "an expired session is renewed" "$(grep -c '^auth login --password --email e@x --tenant t$' "$T/ctl.calls")" 1
check "... the password by environment only" "$(grep -c '^login FT_PASSWORD=pw-value$' "$T/ctl.env")" 1
echo "profile 'default': logged in — session only; a gated vault server also needs" >"$T/session"
reset
seeds bash setup/host/set_seeds.sh >"$T/out" 2>&1
check "a session with no contract is not a login" "$(grep -c '^auth login' "$T/ctl.calls")" 1
echo "profile 'default': logged in — session and contract" >"$T/session"

reset
printf 'vintage=2026-09-19T13:19:52Z\n' >"$T/seeds.last"
echo 48 >"$T/rows"
seeds bash setup/host/set_seeds.sh >"$T/out" 2>&1
check "already seeded: a no-op" "$?" 0
check "... nothing fetched" "$(cat "$T/ctl.calls" 2>/dev/null | grep -c '^env pull')" 0
seeds env B2B_SEEDS_FORCE=1 bash setup/host/set_seeds.sh >"$T/out" 2>&1
check "FORCE=1 goes on" "$(grep -c 'force=1' "$T/guest.args")" 1
echo 0 >"$T/rows"
rm -f "$T/guest.args"
seeds bash setup/host/set_seeds.sh >"$T/out" 2>&1
check "a seeded marker over an empty platform seeds again" "$(grep -c 'force=0' "$T/guest.args")" 1

reset
touch "$T/no-grobase"
printf 'vintage=2026-09-19T13:19:52Z\n' >"$T/seeds.last"
echo 48 >"$T/rows"
seeds bash setup/host/set_seeds.sh --auto >"$T/out" 2>&1
check "a guest that lost grobase gets it back" "$(cat "$T/grobase.calls" 2>/dev/null | wc -l)" 1
check "... and its seeds, whatever the old marker says" "$([ -e "$T/guest.args" ] && echo seeded)" seeded
reset
touch "$T/no-grobase" "$T/grobase-stays-gone"
seeds bash setup/host/set_seeds.sh --auto >"$T/out" 2>&1
check "... and an install that failed is a failure, even from make all" "$?" 1
check "... before any seed moved" "$([ -e "$T/uploaded" ] && echo sent || echo held)" held

# A machine with no keystore: what `42ctl auth login` stops on, measured.
reset
rm "$T/xdg/42ctl/keystore.v42"
cp "$T/cred" "$T/cred.bare"
seeds bash setup/host/set_seeds.sh --auto </dev/null >"$T/out" 2>&1
check "no keystore, none carried, no terminal: make all carries on" "$?" 0
check "... naming make seeds_bundle" "$(grep -c 'seeds_bundle' "$T/out")" 1
check "... and asked no one for an email code" "$(cat "$T/ctl.env" 2>/dev/null | grep -c recover)" 0
echo sealed >"$T/xdg/42ctl/keystore.v42"
seeds bash setup/host/set_seeds.sh --bundle >"$T/out" 2>&1
check "bundle: the file now carries it" "$(grep -c '^FT_KEYSTORE_B64=c2VhbGVkCg==$' "$T/cred")" 1
check "bundle: mode 600" "$(stat -c %a "$T/cred")" 600
check "bundle: the rest of the file survives" "$(grep -c '^FT_PASSPHRASE=pp-value$' "$T/cred")" 1
seeds bash setup/host/set_seeds.sh --bundle >"$T/out" 2>&1
check "bundle twice: one line" "$(grep -c '^FT_KEYSTORE_B64=' "$T/cred")" 1
reset
rm "$T/xdg/42ctl/keystore.v42"
seeds bash setup/host/set_seeds.sh </dev/null >"$T/out" 2>&1
check "only the credentials file: the whole run succeeds" "$?" 0
check "... the keystore is back, byte for byte" "$(cat "$T/xdg/42ctl/keystore.v42")" sealed
check "... private" "$(stat -c %a "$T/xdg/42ctl/keystore.v42")" 600
check "... and the seeds reached the guest" "$(cat "$T/uploaded" | wc -l)" 1
cp "$T/cred.bare" "$T/cred"

reset
seeds env STUB_GUEST_RC=4 bash setup/host/set_seeds.sh >"$T/out" 2>&1
check "a populated guest: a refusal by hand" "$?" 1
check "... naming FORCE=1" "$(grep -c 'FORCE=1' "$T/out")" 1
seeds env STUB_GUEST_RC=4 bash setup/host/set_seeds.sh --auto >"$T/out" 2>&1
check "... and a note from make all" "$?" 0
seeds env STUB_GUEST_RC=1 bash setup/host/set_seeds.sh --auto >"$T/out" 2>&1
check "a real failure fails even from make all" "$?" 1

reset
mkdir -p "$T/dest/repo" && touch "$T/dest/repo/config"
seeds bash setup/host/set_seeds.sh --auto >"$T/out" 2>&1
check "a backup copy beats a seed in make all" "$?" 0
check "... nothing fetched" "$(cat "$T/ctl.calls" 2>/dev/null | wc -l)" 0
check "... pointing at make restore" "$(grep -c 'make restore' "$T/out")" 1
seeds bash setup/host/set_seeds.sh >"$T/out" 2>&1
check "asked by name, the seeds still load" "$(grep -c '^env pull' "$T/ctl.calls")" 1
rm -rf "$T/dest"

reset
echo tampered >>"$T/seed/secrets/MANIFEST.json"
seeds bash setup/host/set_seeds.sh >"$T/out" 2>&1
check "a seed failing its checksum: refused" "$?" 1
check "... before anything reached the guest" "$([ -e "$T/uploaded" ] && echo sent || echo held)" held
(cd "$T/seed/secrets" && sha256sum MANIFEST.json >SHA256SUMS)

# What `auth status` cannot see: the server expired the session, and local state still
# says "session and contract". Measured on a real reseed, 2026-11-04.
reset
: >"$T/session-expired"
seeds bash setup/host/set_seeds.sh >"$T/out" 2>&1
check "an expired session: one sign-in, then the seeds load" "$?" 0
check "... signed in once" "$(grep -c '^auth login' "$T/ctl.calls")" 1
check "... retried once" "$(grep -c '^env pull' "$T/ctl.calls")" 2
check "... with no password on a command line" "$(grep -c 'pw-value' "$T/ctl.calls")" 0
reset
: >"$T/pull-refused"
seeds bash setup/host/set_seeds.sh >"$T/out" 2>&1
check "any other pull failure is not a session: no sign-in" "$(grep -c '^auth login' "$T/ctl.calls")" 0
rm -f "$T/pull-refused"

reset
sed -i '/OSIONOS_BAAS_API_KEY/d' "$T/seed/.env.local"
seeds bash setup/host/set_seeds.sh >"$T/out" 2>&1
check "no app key: refused, the mounts could not be proved" "$?" 1
check "... before the guest is touched" "$([ -e "$T/guest.args" ] && echo touched || echo untouched)" untouched
check "... by name" "$(grep -c 'OSIONOS_BAAS_API_KEY' "$T/out")" 1
printf 'OSIONOS_BAAS_API_KEY=mbk_app-value\n' >>"$T/seed/.env.local"

reset
rm "$T/seed/apps/grobase/.env.secrets"
seeds bash setup/host/set_seeds.sh >"$T/out" 2>&1
check "seeds without their secrets: refused, they would load unreadable" "$?" 1
printf 'K=v\n' >"$T/seed/apps/grobase/.env.secrets"

reset
env PATH="$T/bin:$PATH" B2B_CONFIG=tests/fixtures/default.toml B2B_SECRETS="$T/s" SCRIPT_SH="$T/script_sh" B2B_SEEDS_ENV="$T/nope" \
    VM_NAME=vm1 VM_PATH="$T/vms" VM_USER=u TMPDIR="$T" bash setup/host/set_seeds.sh --auto >"$T/out" 2>&1
check "no credentials file: make all carries on" "$?" 0
env PATH="$T/bin:$PATH" B2B_CONFIG=tests/fixtures/default.toml B2B_SECRETS="$T/s" SCRIPT_SH="$T/script_sh" B2B_SEEDS_ENV="$T/nope" \
    VM_NAME=vm1 VM_PATH="$T/vms" VM_USER=u TMPDIR="$T" bash setup/host/set_seeds.sh >"$T/out" 2>&1
check "... a direct call says why" "$?" 1
check "a typo in FORCE is refused" "$(
    seeds env B2B_SEEDS_FORCE=yes bash setup/host/set_seeds.sh >/dev/null 2>&1
    echo $?
)" 1
g=setup/host/set_seeds_guest.sh
# shellcheck disable=SC2016 # awk programs and literal shell text, not expansions
check "a half-finished seed is marked before anything changes" \
    "$(awk '/^: >"\$PENDING"/{m=NR} /make --no-print-directory down/{d=NR} END{print (m && d && m<d) ? "yes" : "no"}' "$g")" yes
# shellcheck disable=SC2016 # literal shell text
check "... its rerun is not refused as a populated platform" "$(grep -c '\[ ! -e "\$PENDING" \]' "$g")" 1
# shellcheck disable=SC2016 # an awk program, not an expansion
check "... the old record goes with it" "$(grep -c '^rm -f "\$STATUS"$' "$g")" 1
check "... and only success clears the mark" "$(awk '/^rm -f "\$PENDING"$/{p=NR} /^printf .seeded_at=/{r=NR} END{print (p>r) ? "yes" : "no"}' "$g")" yes
check "make all cannot hand FORCE to the seeds" \
    "$(env B2B_CONFIG=tests/fixtures/default.toml make --no-print-directory -n set_seeds SEEDS_MODE=--auto FORCE=1 2>/dev/null | grep -c 'B2B_SEEDS_FORCE="0"')" 1
check "... asked for by name it still works" \
    "$(env B2B_CONFIG=tests/fixtures/default.toml make --no-print-directory -n set_seeds FORCE=1 2>/dev/null | grep -c 'B2B_SEEDS_FORCE="1"')" 1
check "a failed grobase install fails make grobase" \
    "$(awk '/^grobase\)$/{p=1} p&&/;;/{exit} p' setup/host/provision_vm.sh | grep -c '^    exit \$?$')" 1
# The mounts step, cut out and run with runuser stubbed: under hellish too, because
# first boot and the guest's seeds run there, and an assignment prefix on a command
# has differed between the two shells before.
mkdir -p "$T/mounts"
printf 'mbk_app-value\n' >"$T/mounts/app.key"
cat >"$T/bin/runuser" <<STUB
#!/bin/bash
printf 'key=%s after=%s args=%s\n' "\$BAAS_API_KEY" "\$AFTER_RESTORE" "\$*" >"$T/mounts/ran"
exit "\${STUB_MOUNTS_RC:-0}"
STUB
chmod +x "$T/bin/runuser"
awk '/^\[ -s "\$FROM\/app.key" \]/,/mounts do not all open/' "$g" >"$T/mounts/step.sh"
for shell in bash dist/hellish; do
    [ -x "$(command -v "$shell")" ] || continue
    rm -f "$T/mounts/ran"
    printf 'die() { printf "die: %%s\\n" "$*"; exit 1; }\nlog() { :; }\nFROM=%s owner=u\n. %s\n' \
        "$T/mounts" "$T/mounts/step.sh" >"$T/mounts/run.sh"
    env PATH="$T/bin:$PATH" "$shell" "$T/mounts/run.sh" >/dev/null 2>&1
    check "$shell: the mounts step passes the key by environment" "$?" 0
    check "... and runs grobase's script as the checkout's owner" \
        "$(cat "$T/mounts/ran")" "key=mbk_app-value after=1 args=-u u -- bash scripts/seed/osionos-extra-engines.sh"
    env PATH="$T/bin:$PATH" STUB_MOUNTS_RC=1 "$shell" "$T/mounts/run.sh" >/dev/null 2>&1
    check "... a dead mount fails the seed" "$?" 1
done
# shellcheck disable=SC2016 # an awk program, not an expansion
check "the mounts are proved before the seed is recorded" \
    "$(awk '/AFTER_RESTORE=1/{m=NR} /^printf .seeded_at=/{r=NR} END{print (m && r && m<r) ? "yes" : "no"}' "$g")" yes
check "the guest runs vault-restore without its edition restart" "$(grep -c 'SKIP_STACK_CYCLE=1' setup/host/set_seeds_guest.sh)" 2
exit "$fail"
