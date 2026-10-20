#!/usr/bin/env hellish
# The team's secrets in vault42: what is shared, and that a pull never
# replaces a key unasked.
#
# Until 2026-10-14 the secrets file went from seat to seat by hand, and copies
# drifted: a RESTIC_PASSWORD that is not the one the repository was made with
# opens no snapshot. team_vault.sh seals each key into [dc] vault; this pins
# the keys shared (VAULT42_* never), the values never reaching argv or the
# output, the index a narrower push keeps whole, the passphrase handed over as
# FT_PASSPHRASE, and a pull that writes new keys but keeps a differing one
# until it is named. On 2026-10-20 an expired 42ctl session answered HTTP 401
# and the pull said "nothing to read at .../index": the session is now renewed
# once from 42ctl's credential file, the password never in argv.
#
# HOW: 42ctl is a stub on PATH that keeps the vault as files under $TMP/vault
# and refuses any passphrase but the test's; with $TMP/expired present its env
# verbs answer HTTP 401 until `auth login` with the test's password. HOME
# points into a temp directory.
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

mkdir -p "$TMP/bin" "$TMP/home"
cat >"$TMP/bin/42ctl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$TMP/calls"
if [ "\$1" = auth ]; then
    [ "\$2" = login ] && [ "\${FT_PASSWORD:-}" = pw-test ] && rm -f "$TMP/expired" && exit 0
    exit 1
fi
[ "\${FT_PASSPHRASE:-}" = pp-test ] || { echo "error: could not unlock keystore" >&2; exit 1; }
verb=\$3 org=\$5 project=\$7 env=\$9
shift 9
f="$TMP/vault/\$org/\$project/\$env/\$1"
case "\$verb" in
set) mkdir -p "\$(dirname "\$f")" && cat >"\$f" ;;
get)
    [ ! -f "$TMP/expired" ] || { echo "error: /v1/orgs/univers42/projects failed: HTTP 401" >&2; exit 1; }
    [ -f "\$f" ] || { echo "error: no secret at \$1" >&2; exit 1; }; cat "\$f" ;;
esac
EOF
chmod +x "$TMP/bin/42ctl"
VALUES="ts-key-0123 restic-pw-4567 baas-key-89ab"
cat >"$TMP/secrets" <<'EOF'
TS_AUTHKEY=ts-key-0123
RESTIC_PASSWORD=restic-pw-4567
BAAS_API_KEY=baas-key-89ab
VAULT42_KEYSTORE_PASSPHRASE=pp-test
VAULT42_ADMIN_PASSWORD=admin-pw-cdef
EOF
chmod 600 "$TMP/secrets"
SCOPE="$TMP/vault/univers42/born2root/shared/born2root"
SH=$(command -v "${SCRIPT_SH:-bash}")

run() { # <secrets file> [args] -> exit code; output in $TMP/out
    local file="$1"
    shift
    env PATH="$TMP/bin:$PATH" HOME="$TMP/home" B2B_SECRETS="$file" \
        B2B_CONFIG=tests/fixtures/default.toml B2B_VAULT="${VAULT-univers42/born2root/shared}" \
        B2B_VAULT_APPLY="${B2B_VAULT_APPLY:-0}" \
        "$SH" setup/host/team_vault.sh "$@" >"$TMP/out" 2>&1 && echo 0 || echo $?
}
leaks() { # how many values appear in $1
    local value n=0
    for value in $VALUES admin-pw-cdef pp-test; do
        grep -qF -- "$value" "$1" && n=$((n + 1))
    done
    echo "$n"
}

check "pull before any push: refused" "$(run "$TMP/secrets" pull)" 1
check "... naming the index it looked for" "$(grep -c 'nothing to read at .*/born2root/index' "$TMP/out")" 1
check "push: succeeds" "$(run "$TMP/secrets" push)" 0
check "... every key but VAULT42_* is in the vault" "$(find "$SCOPE" -type f -printf '%f\n' | sort | tr '\n' ' ')" \
    "BAAS_API_KEY RESTIC_PASSWORD TS_AUTHKEY index "
check "... byte for byte" "$(cat "$SCOPE/RESTIC_PASSWORD")" restic-pw-4567
check "... the index names them" "$(tr '\n' ' ' <"$SCOPE/index")" "BAAS_API_KEY RESTIC_PASSWORD TS_AUTHKEY "
check "... no value, passphrase or password in 42ctl's argv" "$(leaks "$TMP/calls")" 0
check "... nor in the output" "$(leaks "$TMP/out")" 0

check "push KEYS=TS_AUTHKEY VAULT42_ADMIN_PASSWORD: succeeds" \
    "$(run "$TMP/secrets" push TS_AUTHKEY VAULT42_ADMIN_PASSWORD)" 0
check "... VAULT42_* stays personal even when named" "$([ -e "$SCOPE/VAULT42_ADMIN_PASSWORD" ] && echo shared || echo kept)" kept
check "... the index keeps the keys it did not push" "$(wc -l <"$SCOPE/index" | tr -d ' ')" 3

: >"$TMP/mate"
chmod 600 "$TMP/mate"
check "a teammate's pull without a passphrase: refused" "$(run "$TMP/mate" pull </dev/null)" 1
# 42ctl's own credentials file carries the passphrase: read, never sourced.
mkdir -p "$TMP/home/.config/42ctl/secrets"
printf 'FT_EMAIL=a@b.c\nFT_PASSPHRASE="pp-test"\n' >"$TMP/home/.config/42ctl/secrets/42admin.env"
check "a pull, the passphrase in ~/.config/42ctl/secrets/*.env: found" "$(run "$TMP/mate" pull </dev/null)" 0
rm -rf "$TMP/home/.config/42ctl"
# The datacenter seat keeps one file beside that directory instead.
mkdir -p "$TMP/home/.config/42ctl"
printf 'FT_EMAIL=a@b.c\nFT_TENANT=t1\nFT_PASSWORD=pw-test\nFT_PASSPHRASE=pp-test\n' >"$TMP/home/.config/42ctl/secrets.env"
check "a pull, the passphrase in ~/.config/42ctl/secrets.env: found" "$(run "$TMP/mate" pull </dev/null)" 0
: >"$TMP/expired"
: >"$TMP/calls"
check "an expired session (HTTP 401): renewed, then the pull runs" "$(run "$TMP/mate" pull </dev/null)" 0
check "... one login, from the credential file" "$(grep -c '^auth login --password --email a@b.c --tenant t1$' "$TMP/calls")" 1
check "... the password in no argv" "$(grep -c pw-test "$TMP/calls")" 0
check "... and says so" "$(grep -c 'session expired: renewed' "$TMP/out")" 1
sed -i '/^FT_PASSWORD=/d' "$TMP/home/.config/42ctl/secrets.env"
: >"$TMP/expired"
check "expired, no password to renew it: refused" "$(run "$TMP/mate" pull </dev/null)" 1
check "... naming the login, not a missing index" "$(grep -c '42ctl auth login' "$TMP/out")$(grep -c 'nothing to read' "$TMP/out")" 10
rm -rf "$TMP/home/.config/42ctl" "$TMP/expired"
export FT_PASSPHRASE=pp-test
check "a teammate's pull: a preview" "$(run "$TMP/mate" pull)" 0
check "... lists the three as new" "$(grep -c ' new$' "$TMP/out")" 3
check "... and writes nothing" "$(wc -c <"$TMP/mate" | tr -d ' ')" 0
check "pull APPLY=1: succeeds" "$(B2B_VAULT_APPLY=1 run "$TMP/mate" pull)" 0
check "... the file holds the three" "$(sort "$TMP/mate" | tr '\n' ' ')" \
    "BAAS_API_KEY=baas-key-89ab RESTIC_PASSWORD=restic-pw-4567 TS_AUTHKEY=ts-key-0123 "
check "... mode 600" "$(stat -c %a "$TMP/mate")" 600
check "... no value in the output" "$(leaks "$TMP/out")" 0

sed -i 's/^RESTIC_PASSWORD=.*/RESTIC_PASSWORD=mine-0000/' "$TMP/mate"
check "a differing RESTIC_PASSWORD, APPLY=1: succeeds" "$(B2B_VAULT_APPLY=1 run "$TMP/mate" pull)" 0
check "... kept" "$(sed -n 's/^RESTIC_PASSWORD=//p' "$TMP/mate")" mine-0000
check "... and named as differing" "$(grep -c 'RESTIC_PASSWORD differs' "$TMP/out")" 1
check "KEYS=RESTIC_PASSWORD APPLY=1: replaces it" "$(B2B_VAULT_APPLY=1 run "$TMP/mate" pull RESTIC_PASSWORD)" 0
check "... with the vault's value" "$(sed -n 's/^RESTIC_PASSWORD=//p' "$TMP/mate")" restic-pw-4567
unset FT_PASSPHRASE

chmod 644 "$TMP/secrets"
check "a world-readable secrets file: refused" "$(run "$TMP/secrets" push)" 1
chmod 600 "$TMP/secrets"
check "no [dc] vault: refused" "$(VAULT='' run "$TMP/secrets" push)" 1
check "... naming the key to set" "$(grep -c 'no \[dc\] vault' "$TMP/out")" 1
exit "$fail"
