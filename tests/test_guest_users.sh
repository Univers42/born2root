#!/usr/bin/env hellish
# The accounts b2b-setup.sh creates from born2root.toml, run on the host with
# useradd, usermod, chage and id stubbed. No VM, no root.
#
# What it pins:
#   1. B2B_EXTRA_USERS becomes real accounts: user42 for everyone, sudo only
#      when asked, hellish as the login shell, and the password taken as the
#      SHA-512 hash the host wrote -- never a cleartext one. The hash file is
#      deleted afterwards, and an entry without a hash is a failed build, not
#      an account with no password.
#   2. Password aging reaches EVERY account. login.defs only applies to
#      accounts created after it is edited, and root and the login user are
#      created by d-i before b2b-setup.sh runs, so every build until this one
#      left them all at 99999 days. The subject wants 30/2/7.
#
# The functions are lifted out of preseeds/b2b-setup.sh by name, so renaming
# one, or indenting its closing brace, breaks this test and not the behaviour.
#
# shellcheck disable=SC2016 # crypt hashes and stub bodies: $ is literal here
set -e

cd "$(dirname "$0")/.."

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-58s = %s\n' "$1" "$2"
    else
        printf 'FAIL %-58s = %s (expected %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Stubs on PATH: each records its arguments, one call per line. `id` knows
# only the accounts listed in $TMP/existing.
mkdir -p "$TMP/bin"
for cmd in useradd usermod chage groupadd chown; do
    printf '#!/bin/sh\nprintf "%%s\\n" "%s $*" >>"%s/calls"\n' "$cmd" "$TMP" >"$TMP/bin/$cmd"
done
printf '#!/bin/sh\ngrep -qx "$1" "%s/existing" 2>/dev/null\n' "$TMP" >"$TMP/bin/id"
# getent: `group` knows user42 and sudo only; `passwd` puts every home in $TMP.
printf '#!/bin/sh\ncase "$1" in group) case "$2" in user42|sudo) exit 0;; esac; exit 2;;\npasswd) printf "%%s:x:1000:1000::%s/home/%%s:/usr/bin/hellish\\n" "$2" "$2";; esac\n' "$TMP" >"$TMP/bin/getent"
chmod +x "$TMP/bin/"*
: >"$TMP/existing"

# The script under test, reduced to what these functions need.
{
    printf 'PATH=%s:$PATH\n' "$TMP/bin"
    awk '/^extra_users\(\) \{/' preseeds/b2b-setup.sh
    awk '/^user_fullname\(\) \{/,/^}/' preseeds/b2b-setup.sh
    awk '/^ensure_groups\(\) \{/,/^}/' preseeds/b2b-setup.sh
    awk '/^install_user_keys\(\) \{/,/^}/' preseeds/b2b-setup.sh
    awk '/^create_extra_users\(\) \{/,/^}/' preseeds/b2b-setup.sh
    awk '/^apply_password_aging\(\) \{/,/^}/' preseeds/b2b-setup.sh
    cat <<'EOF'
feature_fail() { printf 'FEATURE-FAILED %s: %s\n' "$1" "$2" >>"$FAILS"; }
create_extra_users
apply_password_aging
printf 'EXTRA_NAMES=%s\n' "$EXTRA_NAMES"
EOF
} >"$TMP/lifted.sh"

run() { # <extra users> -> runs the lifted code; calls in $TMP/calls
    : >"$TMP/calls"
    : >"$TMP/fails"
    env B2B_LOGIN=alice42login B2B_EXTRA_USERS="$1" LOGIN_SHELL=/usr/bin/hellish \
        EXTRA_SHADOW="$TMP/shadow" FAILS="$TMP/fails" \
        B2B_USERS_FILE="$TMP/users" B2B_SSH_KEYS_FILE="$TMP/ssh_keys" \
        "${SCRIPT_SH:-bash}" "$TMP/lifted.sh" >"$TMP/out" 2>&1
}

check "the functions were found in b2b-setup.sh" "$(grep -c '^create_extra_users() {$\|^apply_password_aging() {$\|^extra_users() {' "$TMP/lifted.sh")" 3

# ── Two new accounts ────────────────────────────────────────────────────────
printf 'alice:$6$salta$hashA\nbob:$6$saltb$hash/B.x\n' >"$TMP/shadow"
run "alice:user42 bob:user42,sudo"
check "alice: created in user42 with hellish and her hash" \
    "$(grep '^useradd ' "$TMP/calls" | grep -c -- '-m -G user42 -s /usr/bin/hellish -p $6$salta$hashA -c alice alice$')" 1
check "bob: created in user42 AND sudo" \
    "$(grep '^useradd ' "$TMP/calls" | grep -c -- '-G user42,sudo -s /usr/bin/hellish -p $6$saltb$hash/B.x -c bob bob$')" 1
check "exactly two accounts created" "$(grep -c '^useradd ' "$TMP/calls")" 2
check "the hash file is deleted afterwards" "$([ -e "$TMP/shadow" ] && echo present || echo gone)" gone
check "no failure reported" "$(wc -l <"$TMP/fails")" 0
check "EXTRA_NAMES lists both" "$(sed -n 's/^EXTRA_NAMES=//p' "$TMP/out")" "alice bob"
check "aging: root, the login, alice and bob" \
    "$(grep '^chage ' "$TMP/calls" | awk '{ print $NF }' | tr '\n' ' ')" "root alice42login alice bob "
check "aging: 30 days max, 2 min, warned 7 before" "$(grep -c '^chage -M 30 -m 2 -W 7 ' "$TMP/calls")" 4

# ── No extra users: only the aging ──────────────────────────────────────────
run ""
check "none asked for: no useradd" "$(grep -c '^useradd ' "$TMP/calls")" 0
check "none asked for: aging for root and the login only" \
    "$(grep '^chage ' "$TMP/calls" | awk '{ print $NF }' | tr '\n' ' ')" "root alice42login "

# ── A missing hash is a failure, not a password-less account ────────────────
printf 'alice:$6$salta$hashA\n' >"$TMP/shadow"
run "alice:user42 carol:user42"
check "carol without a hash: not created" "$(grep -c 'carol' "$TMP/calls" | tr -d ' ')" 0
check "carol without a hash: fails the build" "$(grep -c '^FEATURE-FAILED b2b-mandatory: extra user carol' "$TMP/fails")" 1
check "alice is still created" "$(grep -c '^useradd .* alice$' "$TMP/calls")" 1

# ── An account that already exists is updated, not re-created ───────────────
printf 'alice\n' >"$TMP/existing"
printf 'alice:$6$salta$hashA\n' >"$TMP/shadow"
run "alice:user42,sudo"
check "existing alice: no useradd" "$(grep -c '^useradd ' "$TMP/calls")" 0
check "existing alice: groups and shell set" "$(grep -c '^usermod -aG user42,sudo -s /usr/bin/hellish -c alice alice$' "$TMP/calls")" 1
check "existing alice: password set from the hash" "$(grep -c '^usermod -p $6$salta$hashA alice$' "$TMP/calls")" 1

# ── What born2root.toml adds: full names, new groups, keys, a locked account ─
: >"$TMP/existing"
printf 'dave:$6$saltd$hashD\nerin:!\n' >"$TMP/shadow"
printf "alice42login:Alice:user42,sudo\ndave:Dave O'Hara:user42,sudo,docker\nerin:erin:user42\n" >"$TMP/users"
printf 'dave ssh-ed25519 AAAAkeyD dave@laptop\ndave ssh-rsa AAAAkeyD2 dave@work\nerin ssh-ed25519 AAAAkeyE e\n' >"$TMP/ssh_keys"
mkdir -p "$TMP/home/dave" "$TMP/home/erin" # useradd -m, which the stub does not do
run "dave:user42,sudo,docker erin:user42"
check "dave: GECOS from the users file, quote and all" \
    "$(grep -c "^useradd .* -c Dave O'Hara dave$" "$TMP/calls")" 1
check "dave: the missing group docker is created first" \
    "$(grep -n '' "$TMP/calls" | grep -E 'groupadd -f docker$|useradd .* dave$' | cut -d: -f1 | tr '\n' ' ')" "1 2 "
check "only groups that do not exist are created" "$(grep -c '^groupadd ' "$TMP/calls")" 1
check "erin: an empty password is a locked account, created" \
    "$(grep -c '^useradd .* -p ! -c erin erin$' "$TMP/calls")" 1
check "dave: both keys, nobody else's" "$(cat "$TMP/home/dave/.ssh/authorized_keys" 2>/dev/null | tr '\n' '|')" \
    "ssh-ed25519 AAAAkeyD dave@laptop|ssh-rsa AAAAkeyD2 dave@work|"
check "dave: keys are 600 in a 700 directory" \
    "$(stat -c %a "$TMP/home/dave/.ssh" "$TMP/home/dave/.ssh/authorized_keys" 2>/dev/null | tr '\n' ' ')" "700 600 "
check "erin: her key only" "$(cat "$TMP/home/erin/.ssh/authorized_keys" 2>/dev/null)" "ssh-ed25519 AAAAkeyE e"
check "a second run adds no duplicate, removes nothing" \
    "$(printf 'dave\n' >"$TMP/existing" && run "dave:user42,sudo,docker" && wc -l <"$TMP/home/dave/.ssh/authorized_keys" | tr -d ' ')" 2

exit "$fail"
