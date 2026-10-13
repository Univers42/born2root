#!/usr/bin/env hellish
# Regression test: the profile names the secrets file, and a backup that
# exists is never given a new password.
#
# THE PROBLEMS IT PINS
#   1. The secrets file was found by B2B_SECRETS=, a .b2b-secrets in the repo,
#      or ~/.config/born2root/b2b-secrets -- and the file that holds baas's
#      keys is ~/.b2b_secrets/.env, which only an exported B2B_SECRETS found.
#      Rebuilt from the profile alone, every datacenter step read an empty
#      file. [dc] secrets_file names it ($HOME/$USER expanded, a list
#      allowed); B2B_SECRETS= still wins, for the Makefile and dc_lib.sh alike.
#   2. backup_pull.sh minted a RESTIC_PASSWORD whenever the file had none --
#      also for `make restore`, and also beside a repository made with another
#      password. The new password opens nothing, and the next `make backup`
#      cannot even add to the repository. It now refuses, naming the key and
#      the file, before it touches the guest.
#
# Every secret here is a fake made in a temp dir; nothing reads the real file:
# B2B_SECRETS from the caller's shell is dropped first, because it would win.
set -u
cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." || exit 1
unset B2B_SECRETS

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-62s = %s\n' "$1" "$2"
    else
        printf 'FAIL %-62s = %s (expected %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}

TMP=$(mktemp -d)
trap 'rm -rf "${TMP:?}"' EXIT
mkdir -p "$TMP/home" "$TMP/bin" "$TMP/vm"
printf '#!/bin/sh\nexit 1\n' >"$TMP/bin/VBoxManage"
printf '#!/bin/sh\necho "fake ssh must not run: $*" >&2\nexit 255\n' >"$TMP/bin/ssh"
chmod +x "$TMP/bin/VBoxManage" "$TMP/bin/ssh"

profile() { # <secrets_file TOML value> -> path, one file per value
    local f
    f="$TMP/p-$(printf '%s' "$1" | md5sum | cut -c1-8).toml"
    awk -v v="$1" '{ print } /^\[dc\]/ { print "secrets_file = " v }' tests/fixtures/default.toml >"$f"
    printf '%s' "$f"
}
# What dc_lib.sh resolves, for a profile and an environment.
dc_secrets() { # <profile> [B2B_SECRETS]
    # shellcheck disable=SC2016 # $SECRETS_FILE is the child shell's, after dc_lib.sh set it
    env -u B2B_SECRETS HOME="$TMP/home" B2B_CONFIG="$1" ${2:+B2B_SECRETS="$2"} \
        "${SCRIPT_SH:-bash}" -c '. setup/host/dc_lib.sh; printf "%s" "$SECRETS_FILE"'
}
# What the Makefile hands its recipes: `make -n datacenter` prints the path
# its TS_AUTHKEY grep reads.
make_secrets() { # <profile> [B2B_SECRETS]
    env -u B2B_SECRETS HOME="$TMP/home" ${2:+B2B_SECRETS="$2"} \
        make -n --no-print-directory datacenter B2B_CONFIG="$1" VM_PATH="$TMP/vm" 2>/dev/null |
        sed -n "s/.*grep -q '^TS_AUTHKEY=.' \"\\([^\"]*\\)\".*/\\1/p" | head -n1
}

# ── where the file is ───────────────────────────────────────────────────────
if [ -e .b2b-secrets ]; then
    echo "skip: a .b2b-secrets in this checkout would answer before the defaults"
else
    D=tests/fixtures/default.toml
    check "no key: the home default (dc_lib.sh)" "$(dc_secrets "$D")" "$TMP/home/.config/born2root/b2b-secrets"
    check "no key: the home default (Makefile)" "$(make_secrets "$D")" "$TMP/home/.config/born2root/b2b-secrets"
fi
# shellcheck disable=SC2016 # the literal $HOME is the profile's text
P=$(profile '"$HOME/.b2b_secrets/.env"')
check "[dc] secrets_file, \$HOME expanded (dc_lib.sh)" "$(dc_secrets "$P")" "$TMP/home/.b2b_secrets/.env"
check "[dc] secrets_file, \$HOME expanded (Makefile)" "$(make_secrets "$P")" "$TMP/home/.b2b_secrets/.env"
check "B2B_SECRETS= still wins (dc_lib.sh)" "$(dc_secrets "$P" "$TMP/other")" "$TMP/other"
check "B2B_SECRETS= still wins (Makefile)" "$(make_secrets "$P" "$TMP/other")" "$TMP/other"
check "a relative secrets_file is refused at --check" \
    "$(env B2B_CONFIG="$(profile '"secrets/.env"')" "${SCRIPT_SH:-bash}" utils/b2b_config.sh --check >/dev/null 2>&1 && echo 0 || echo 1)" 1
check "the server profile names ~/.b2b_secrets/.env" \
    "$(env HOME="$TMP/home" B2B_CONFIG=profiles/server.toml "${SCRIPT_SH:-bash}" utils/b2b_config.sh get B2B_DC_SECRETS_FILE)" \
    "$TMP/home/.b2b_secrets/.env"

# ── backup_pull.sh never mints over an existing backup ──────────────────────
SECRETS="$TMP/home/.b2b_secrets/.env"
mkdir -p "${SECRETS%/*}"
# The cases below write a password: only ever into the temp file.
if [ "$(dc_secrets "$P")" != "$SECRETS" ]; then
    echo "FAIL the secrets file would not be the temp one; not running backup_pull.sh"
    exit 1
fi
pull() { # <BACKUP_DEST> [--restore] -> rc; output in $TMP/out
    env -u B2B_SECRETS PATH="$TMP/bin:$PATH" HOME="$TMP/home" B2B_CONFIG="$P" VM_NAME=t-none VM_PATH="$TMP/vm" \
        BACKUP_DEST="$1" "${SCRIPT_SH:-bash}" setup/host/backup_pull.sh ${2:+"$2"} >"$TMP/out" 2>&1 &&
        echo 0 || echo $?
}
printf 'TS_AUTHKEY=fake-not-a-key\n' >"$SECRETS"
chmod 600 "$SECRETS"
mkdir -p "$TMP/dest/repo"
printf 'fake restic config\n' >"$TMP/dest/repo/config"
check "a repository, no RESTIC_PASSWORD: refused (1)" "$(pull "$TMP/dest")" 1
check "  names the key and the file" "$(grep -c "RESTIC_PASSWORD.*$SECRETS" "$TMP/out")" 1
check "  minted nothing" "$(grep -c '^RESTIC_PASSWORD=' "$SECRETS")" 0
check "  never reached for the guest" "$(grep -c 'fake ssh must not run' "$TMP/out")" 0
check "--restore, no RESTIC_PASSWORD: refused (1)" "$(pull "$TMP/empty" --restore)" 1
check "  names the key and the file" "$(grep -c "RESTIC_PASSWORD.*$SECRETS" "$TMP/out")" 1
check "  minted nothing" "$(grep -c '^RESTIC_PASSWORD=' "$SECRETS")" 0
check "no repository yet: a password is minted (then no VM: 1)" "$(pull "$TMP/empty")" 1
check "  minted one" "$(grep -c '^RESTIC_PASSWORD=.' "$SECRETS")" 1
check "  the other keys kept" "$(grep -c '^TS_AUTHKEY=fake-not-a-key$' "$SECRETS")" 1
check "  the value is not printed" "$(grep -cF -- "$(sed -n 's/^RESTIC_PASSWORD=//p' "$SECRETS")" "$TMP/out")" 0

exit "$fail"
