#!/usr/bin/env hellish
# Pins `secret:NAME` credentials (utils/b2b_config.py, setup/host/mint_secrets.sh).
#
# The bug it pins down: profiles/server.toml held tempencrypt123 and temproot123
# in a public repository (curl says 200 for github.com/Univers42/born2root), and
# that passphrase is all that stands between a copied qcow2 and restic's
# password. The value moved to the secrets file; every reader must follow the
# reference, none may print it, and a built disk must never get a new one.
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
trap 'rm -rf "$T"' EXIT
LUKS=0123456789abcdef0123456789abcdef
LOGIN=Bb7loginlogin12345
ROOTPW=Bb7rootrootroot123

sed -e 's/^root_password *=.*/root_password = "secret:T_ROOT"/' \
    -e 's/^luks_passphrase *=.*/luks_passphrase = "secret:T_LUKS"/' \
    -e '0,/^password *=.*/s//password = "secret:T_LOGIN"/' \
    tests/fixtures/default.toml >"$T/p.toml"
printf 'T_LUKS=%s\nT_ROOT=%s\nT_LOGIN=%s\n' "$LUKS" "$ROOTPW" "$LOGIN" >"$T/s"
chmod 600 "$T/s"
cfg() { env B2B_CONFIG="$T/p.toml" B2B_SECRETS="$T/s" bash utils/b2b_config.sh "$@"; }
rc_of() {
    "$@" >/dev/null 2>&1
    printf '%s' "$?"
}

check "the LUKS reference resolves" "$(cfg get B2B_LUKS_PASSPHRASE)" "$LUKS"
check "the login reference resolves" "$(cfg get B2B_USER_PASSWORD)" "$LOGIN"
check "the root reference resolves" "$(cfg get B2B_ROOT_PASSWORD)" "$ROOTPW"
check "--secret-refs names all three, values nowhere" \
    "$(cfg --secret-refs | tr '\n' ',')" "T_LUKS luks,T_ROOT root,T_LOGIN login,"
check "VM_PASS still beats the file" "$(env VM_PASS=override-pass B2B_CONFIG="$T/p.toml" B2B_SECRETS="$T/s" bash utils/b2b_config.sh get B2B_LUKS_PASSPHRASE)" override-pass
check "it validates" "$(rc_of cfg --check)" 0
check "--dump shows the reference, not the value" "$(cfg --dump | grep -c "$LUKS\|$LOGIN\|$ROOTPW")" 0
check "--show shows the reference, not the value" "$(cfg --show | grep -c "$LUKS\|$LOGIN\|$ROOTPW")" 0
check "build.conf carries none of them" "$(cfg --guest | grep -c "$LUKS\|$LOGIN\|$ROOTPW\|secret:")" 0
printf 'pw=@B2B_LUKS_PASSPHRASE@\n' >"$T/tpl"
check "--render fills the real value" "$(cfg --render "$T/tpl")" "pw=$LUKS"
printf 'hash=@B2B_ROOT_PASSWORD_HASH@\n' >"$T/tpl"
# shellcheck disable=SC2016 # a literal $6$, the crypt prefix
check "the root hash is of the value, not of the reference" \
    "$(cfg --render "$T/tpl" | grep -c '^hash=\$6\$')" 1

sed -i '/^T_LOGIN=/d' "$T/s"
out=$(cfg --check 2>&1)
check "a missing value fails --check" "$(rc_of cfg --check)" 1
check "... naming the fix" "$(printf '%s' "$out" | grep -c 'make secrets_mint')" 1
check "get still answers empty, and silently" "$(cfg get B2B_USER_PASSWORD 2>&1)" ""
printf 'T_LOGIN=%s\n' "$LOGIN" >>"$T/s"
chmod 640 "$T/s"
check "a group-readable file fails --check" "$(rc_of cfg --check)" 1
chmod 600 "$T/s"
mv "$T/s" "$T/gone"
check "no file at all: get answers empty" "$(cfg get B2B_LUKS_PASSPHRASE 2>&1)" ""
mv "$T/gone" "$T/s"

mint() { env B2B_CONFIG="$T/p.toml" B2B_SECRETS="$T/m" VM_NAME=vm1 VM_PATH="$T/vms" bash setup/host/mint_secrets.sh; }
mkdir -p "$T/vms/vm1"
mint >/dev/null 2>&1
check "mint: three keys" "$(grep -c '^T_' "$T/m")" 3
check "mint: mode 600" "$(stat -c %a "$T/m")" 600
luks=$(sed -n 's/^T_LUKS=//p' "$T/m")
login=$(sed -n 's/^T_LOGIN=//p' "$T/m")
check "mint: the passphrase needs no shift, in any keymap" "$(printf '%s' "$luks" | grep -cE '^[0-9a-f]{32}$')" 1
check "mint: the password has every class the policy wants" \
    "$(printf '%s' "$login" | grep -E '[A-Z]' | grep -E '[a-z]' | grep -cE '^[A-Za-z0-9]{24}$')" 1
check "mint: the result validates" "$(rc_of env B2B_CONFIG="$T/p.toml" B2B_SECRETS="$T/m" bash utils/b2b_config.sh --check)" 0
before=$(cat "$T/m")
mint >/dev/null 2>&1
check "mint: a second run changes nothing" "$(cat "$T/m")" "$before"
touch "$T/vms/vm1/.installed"
sed -i '/^T_LUKS=/d' "$T/m"
out=$(mint 2>&1)
check "mint: a built VM with a lost key is refused" "$?" 1
check "... and nothing was minted over it" "$(grep -c '^T_LUKS=' "$T/m")" 0
check "... naming the way back" "$(printf '%s' "$out" | grep -c 'secrets_pull')" 1

# A keys-only guest on a machine with no key of its own.
sed -e 's/^password_login *=.*/password_login = false/' -e '/^ssh_keys *=/s/.*/ssh_keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG+mTmZXgfPrUtf20VA x@y"]/' \
    "$T/p.toml" >"$T/keys.toml"
mkdir -p "$T/home"
env HOME="$T/home" B2B_CONFIG="$T/keys.toml" B2B_SECRETS="$T/k" VM_NAME=vm3 VM_PATH="$T/vms" bash setup/host/mint_secrets.sh >/dev/null 2>&1
check "keys only, no key here: this machine gets one" "$([ -s "$T/home/.ssh/id_ed25519.pub" ] && echo made)" made
check "... private" "$(stat -c %a "$T/home/.ssh/id_ed25519")" 600
key_before=$(cat "$T/home/.ssh/id_ed25519.pub")
env HOME="$T/home" B2B_CONFIG="$T/keys.toml" B2B_SECRETS="$T/k" VM_NAME=vm3 VM_PATH="$T/vms" bash setup/host/mint_secrets.sh >/dev/null 2>&1
check "... and it is never replaced" "$(cat "$T/home/.ssh/id_ed25519.pub")" "$key_before"
mkdir -p "$T/home2"
env HOME="$T/home2" B2B_CONFIG="$T/p.toml" B2B_SECRETS="$T/k2" VM_NAME=vm4 VM_PATH="$T/vms" bash setup/host/mint_secrets.sh >/dev/null 2>&1
check "password login on: no key is made" "$([ -e "$T/home2/.ssh" ] && echo made || echo none)" none

check "mint: a config with no reference is a no-op" \
    "$(
        env B2B_CONFIG=tests/fixtures/default.toml B2B_SECRETS="$T/none" VM_NAME=vm2 VM_PATH="$T/vms" bash setup/host/mint_secrets.sh 2>&1
        [ -e "$T/none" ] && echo wrote
    )" ""
# .gitignore's *secret* hid mint_secrets.sh and this very test (2026-11-04): the
# build worked here and a fresh clone had neither. Ignoring is decided from the
# name, so ask git about every source file rather than about those two.
ignored=$(
    for source_file in setup/host/* setup/install/*/* utils/*.sh utils/*.py generate/* tests/*.sh; do
        [ -f "$source_file" ] && git check-ignore -q --no-index "$source_file" && printf '%s ' "$source_file"
    done
)
check "no source file hides behind .gitignore" "$ignored" ""

exit "$fail"
