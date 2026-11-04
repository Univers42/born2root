#!/usr/bin/env hellish
# Pins setup/host/rotate_password.sh with ssh and provision_vm.sh stubbed.
#
# The bug it pins down: an expired password refuses a key login that has no
# terminal, measured on trixie 2026-11-04 ("Password change required but no TTY
# available", exit 1), so 30 days after a build the hourly backup and every make
# target stopped. The runbook said nobody had tested it. What matters is the
# order: at no point may the secrets file disagree with the guest for good.
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
sed -e 's/^root_password *=.*/root_password = "secret:T_ROOT"/' \
    -e 's/^luks_passphrase *=.*/luks_passphrase = "secret:T_LUKS"/' \
    -e '0,/^password *=.*/s//password = "secret:T_LOGIN"/' \
    tests/fixtures/default.toml >"$T/p.toml"
mkdir -p "$T/bin" "$T/vms/vm1"
printf 'ssh=4242\n' >"$T/vms/vm1/ports.env"
python3 -c 'import time; time.sleep(120)' "$T/vms/vm1/qemu.pid" &
sleeper=$!
echo "$sleeper" >"$T/vms/vm1/qemu.pid"
# The stub guest: chage reads $T/expires, the upload lands in $T/uploaded.
cat >"$T/bin/ssh" <<STUB
#!/bin/bash
case "\$*" in
*"chage -l"*) printf 'Password expires\t\t\t\t\t: %s\n' "\$(cat "$T/expires")" ;;
*"cat > "*) cat >"$T/uploaded" ;;
esac
exit 0
STUB
# The stub sudo: answers to $T/guest_pass. root-sh "applies" by taking the _NEXT
# value, which only a test double may read back.
cat >"$T/script_sh" <<STUB
#!/bin/bash
case "\$*" in
*provision_vm.sh*sudo-check)
    [ "\$VM_SUDO_PASS" = "\$(cat "$T/guest_pass")" ]
    exit \$?
    ;;
*provision_vm.sh*root-sh)
    [ -e "$T/refuse" ] && exit 0
    sed -n 's/^T_LOGIN_NEXT=//p' "$T/s" >"$T/guest_pass"
    exit 0
    ;;
esac
exec bash "\$@"
STUB
chmod +x "$T/bin/ssh" "$T/script_sh"
reset() {
    printf 'T_LUKS=0123456789abcdef0123456789abcdef\nT_ROOT=Bb7rootrootroot123\nT_LOGIN=Bb7loginlogin12345\n' >"$T/s"
    chmod 600 "$T/s"
    printf 'Bb7loginlogin12345' >"$T/guest_pass"
    rm -f "$T/uploaded" "$T/refuse"
}
rot() {
    env PATH="$T/bin:$PATH" B2B_CONFIG="$T/p.toml" B2B_SECRETS="$T/s" SCRIPT_SH="$T/script_sh" \
        VM_NAME=vm1 VM_PATH="$T/vms" VM_USER=u bash setup/host/rotate_password.sh "$@"
}
secret() { sed -n "s/^$1=//p" "$T/s"; }

reset
date -d '+25 days' '+%b %d, %Y' >"$T/expires"
check "--days reads the guest" "$(rot --days)" 24
rot --if-due >/dev/null 2>&1
check "25 days left: --if-due does nothing" "$(secret T_LOGIN)" Bb7loginlogin12345

date -d '+5 days' '+%b %d, %Y' >"$T/expires"
rot --if-due >"$T/out" 2>&1
check "5 days left: --if-due rotates" "$?" 0
new=$(secret T_LOGIN)
check "... the file holds a new value" "$([ "$new" != Bb7loginlogin12345 ] && [ -n "$new" ] && echo changed)" changed
check "... the guest answers to it" "$(cat "$T/guest_pass")" "$new"
check "... nothing is left half-way" "$(secret T_LOGIN_NEXT)$(secret T_ROOT_NEXT)" ""
check "... root rotated too" "$([ "$(secret T_ROOT)" != Bb7rootrootroot123 ] && echo changed)" changed
check "... only hashes left the host" "$(grep -c "$new" "$T/uploaded")" 0
# shellcheck disable=SC2016 # a literal $6$, the crypt prefix
check "... both accounts, as hashes" "$(grep -cE '^(u|root):\$6\$' "$T/uploaded")" 2
check "... no value on the terminal" "$(grep -c "$new" "$T/out")" 0

reset
date -d '+5 days' '+%b %d, %Y' >"$T/expires"
touch "$T/refuse"
rot >"$T/out" 2>&1
check "the guest does not take it: fails" "$?" 1
check "... the file keeps what the guest answers to" "$(secret T_LOGIN)" Bb7loginlogin12345
check "... and nothing half-way" "$(secret T_LOGIN_NEXT)" ""

# A run killed between the guest's change and the file's.
reset
printf 'Bb7interrupted12345' >"$T/guest_pass"
printf 'T_LOGIN_NEXT=Bb7interrupted12345\nT_ROOT_NEXT=Bb7interruptedroot1\n' >>"$T/s"
rot --if-due >"$T/out" 2>&1
check "an interrupted rotation is finished, not repeated" "$(secret T_LOGIN)" Bb7interrupted12345
check "... root with it" "$(secret T_ROOT)" Bb7interruptedroot1
check "... and the draft is cleared" "$(secret T_LOGIN_NEXT)" ""

env PATH="$T/bin:$PATH" B2B_CONFIG=tests/fixtures/default.toml B2B_SECRETS="$T/s" SCRIPT_SH="$T/script_sh" \
    VM_NAME=vm1 VM_PATH="$T/vms" VM_USER=u bash setup/host/rotate_password.sh --if-due >"$T/out" 2>&1
check "a literal password: --if-due stays out of the way" "$?" 0
env PATH="$T/bin:$PATH" B2B_CONFIG=tests/fixtures/default.toml B2B_SECRETS="$T/s" SCRIPT_SH="$T/script_sh" \
    VM_NAME=vm1 VM_PATH="$T/vms" VM_USER=u bash setup/host/rotate_password.sh >"$T/out" 2>&1
check "... and asked outright it says why not" "$(grep -c 'literal' "$T/out")" 1
exit "$fail"
