#!/usr/bin/env hellish
# team_vault.sh — the team's copy of the secrets file, in vault42, so a
# teammate's seat gets the same keys with one command instead of a pasted file.
#   make secrets_push [KEYS="A B"]        seal the shared keys into [dc] vault
#   make secrets_pull                     what the vault holds against this file
#   make secrets_pull APPLY=1 [KEYS=...]  write them; KEYS names the ones to replace
#
# WHY A VAULT AND NOT A COPIED FILE
#   The file was passed around by hand, and each copy drifted: a RESTIC_PASSWORD
#   that differs from the one the repository was made with reads no snapshot,
#   and a one-off TS_AUTHKEY pasted twice joins one machine. Here every key is
#   one 42ctl environment secret at born2root/KEY in [dc] vault
#   ("org/project/env"), sealed to that environment's shared key: whoever the
#   org admin granted the environment reads it, the vault42 server never does.
#   born2root/index lists the names (42ctl has no `secret ls`); it is lowercase,
#   so no KEY can collide with it.
#
# WHAT IS NOT SHARED: VAULT42_* -- the pusher's own vault42 login (account
#   password, keystore passphrase, register token). Sharing it hands over a
#   person, not the platform. Pull skips them too.
#
# A PULL NEVER REPLACES A KEY UNASKED. A new key is written; one that differs
#   from the local value is reported and kept until named in KEYS: replacing a
#   RESTIC_PASSWORD loses the repository it opened.
#
# THE VALUES never reach argv, a log or the terminal: secret_get pipes each into
#   `42ctl env secret set` on stdin, `get` writes into a pipe read by
#   secret_set. The keystore passphrase is FT_PASSPHRASE: from the environment,
#   else VAULT42_KEYSTORE_PASSPHRASE in the secrets file, else asked once on the
#   terminal -- exported, never on a command line, so 42ctl does not ask per key.
#
# Caveat: the index is read before a push to keep the names a narrower push
# (KEYS=) did not touch; when that read fails for a reason other than "nothing
# pushed yet" (the network, a revoked grant), the new index holds only the keys
# pushed now and a later pull misses the others -- push without KEYS repairs it.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
# shellcheck source=setup/host/dc_lib.sh
. "$ROOT/setup/host/dc_lib.sh"

V42="${B2B_42CTL:-42ctl}"
PREFIX="born2root"

# v42 SUBCOMMAND PATH: one environment secret, stdin to stdout.
v42() {
    "$V42" env secret "$1" --org "$ORG" --project "$PROJECT" --env "$ENV_NAME" "$PREFIX/$2"
}

passphrase() {
    [ -n "${FT_PASSPHRASE:-}" ] && return 0
    FT_PASSPHRASE=$(secret_get VAULT42_KEYSTORE_PASSPHRASE)
    if [ -z "$FT_PASSPHRASE" ] && [ -t 0 ]; then
        printf 'vault42 keystore passphrase: ' >&2
        IFS= read -rs FT_PASSPHRASE
        printf '\n' >&2
    fi
    [ -n "$FT_PASSPHRASE" ] || die "no keystore passphrase: export FT_PASSPHRASE, or run from a terminal"
    export FT_PASSPHRASE
}

# shared_names [KEY...]: the names given, else every KEY of the secrets file;
# VAULT42_* dropped either way.
shared_names() {
    { if [ $# -gt 0 ]; then printf '%s\n' "$@"; else sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' "$SECRETS_FILE"; fi; } |
        grep -E '^[A-Z][A-Z0-9_]*$' | grep -v '^VAULT42_' | sort -u
}

push() {
    local name names old pushed=0
    [ -f "$SECRETS_FILE" ] || die "no secrets file at $SECRETS_FILE"
    names=$(shared_names "$@")
    [ -n "$names" ] || die "nothing to share in $SECRETS_FILE (VAULT42_* stays personal)"
    for name in $names; do
        [ -n "$(secret_get "$name")" ] || die "$name is not in $SECRETS_FILE"
    done
    old=$(v42 get index 2>/dev/null) || old=""
    for name in $names; do
        printf '%s' "$(secret_get "$name")" | v42 set "$name" >/dev/null ||
            die "42ctl could not seal $name into $VAULT (logged in? 42ctl auth status; enrolled? 42ctl keys enroll --org $ORG)"
        ok "$name"
        pushed=$((pushed + 1))
    done
    printf '%s\n%s\n' "$old" "$names" | grep -v '^$' | sort -u | v42 set index >/dev/null ||
        die "42ctl could not write $PREFIX/index into $VAULT"
    ok "$pushed key(s) sealed into $VAULT; teammates: make secrets_pull"
}

# pull [KEY...]: new keys are written, differing ones only when named.
pull() {
    local index name remote local_value state replace=" $* " written=0 kept=0
    index=$(v42 get index) ||
        die "nothing to read at $VAULT/$PREFIX/index (pushed yet? granted? 42ctl env keys ls --org $ORG --project $PROJECT --env $ENV_NAME)"
    for name in $(printf '%s\n' "$index" | grep -E '^[A-Z][A-Z0-9_]*$' | grep -v '^VAULT42_'); do
        remote=$(v42 get "$name") || die "42ctl could not read $name from $VAULT"
        local_value=$(secret_get "$name")
        if [ -z "$local_value" ]; then
            state=new
        elif [ "$local_value" = "$remote" ]; then
            state=same
        elif [ "${replace#* "$name" }" != "$replace" ]; then
            state=replace
        else
            state=differs
        fi
        case "$state:$B2B_VAULT_APPLY" in
        new:1 | replace:1)
            secret_set "$name" "$remote"
            ok "$name written ($state)"
            written=$((written + 1))
            ;;
        differs:*)
            warn "$name differs from $VAULT: kept (KEYS=$name APPLY=1 replaces it)"
            kept=$((kept + 1))
            ;;
        *) printf '  %-28s %s\n' "$name" "$state" ;;
        esac
    done
    [ "$B2B_VAULT_APPLY" = 1 ] || info "a preview: nothing written (make secrets_pull APPLY=1)"
    [ "$B2B_VAULT_APPLY" != 1 ] || ok "$written key(s) written to $SECRETS_FILE, $kept kept"
}

B2B_VAULT_APPLY="${B2B_VAULT_APPLY:-0}"
VAULT="${B2B_VAULT:-$(b2b_get B2B_DC_VAULT)}"
[ -n "$VAULT" ] || die "no [dc] vault in ${B2B_CONFIG:-born2root.toml}: set vault = \"org/project/env\" (or B2B_VAULT=)"
IFS=/ read -r ORG PROJECT ENV_NAME <<EOF
$VAULT
EOF
[ -n "$ENV_NAME" ] || die "[dc] vault '$VAULT' is not org/project/env"
command -v "$V42" >/dev/null 2>&1 || die "no $V42 on PATH (vault42's CLI: 42ctl help update)"
# The mode check, here and not inside a $( ): there, die ends the subshell only.
secret_get VAULT42_ >/dev/null
action="${1:-}"
[ $# -gt 0 ] && shift
case "$action" in
push)
    passphrase
    push "$@"
    ;;
pull)
    passphrase
    pull "$@"
    ;;
*) die "usage: team_vault.sh push|pull [KEY...]" ;;
esac
