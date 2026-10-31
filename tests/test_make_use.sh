#!/usr/bin/env hellish
# Regression test for `make use` and the .b2b-config it records.
#
# The bug it guards: every target of a profile's VM needed B2B_CONFIG= on its
# command line, and the one call that forgot it read born2root.toml instead --
# the `debian` VM, its ports, its users -- with nothing saying so (2026-10-31,
# the inception profile). `make use B2B_CONFIG=<profile>` now records the
# choice once. What has to hold:
#   - make reads .b2b-config when neither the command line nor the
#     environment names a profile, and EXPORTS it, because the scripts read
#     B2B_CONFIG from their environment, where a value make read from a file
#     does not go on its own;
#   - an explicit B2B_CONFIG still wins;
#   - a recorded profile that no longer exists stops make at parse time
#     rather than falling back to born2root.toml;
#   - `make use B2B_CONFIG=` removes the record.
#
# Nothing here builds anything: make -n renders recipes, and a one-line
# --eval target reads the recipe environment. A .b2b-config already there is
# put back on exit.
set -e

cd "$(dirname "$0")/.."

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-50s = %s\n' "$1" "$2"
    else
        printf 'FAIL %-50s = %s (expected %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}

TMP=$(mktemp -d)
[ ! -e .b2b-config ] || cp .b2b-config "$TMP/saved"
trap 'rm -f .b2b-config; [ ! -e "$TMP/saved" ] || cp "$TMP/saved" .b2b-config; rm -rf "$TMP"' EXIT
rm -f .b2b-config
unset B2B_CONFIG

vm_name() {
    make -n inception SRC=/x "$@" 2>/dev/null | grep -o 'VM_NAME="[^"]*"' | head -1
}
recipe_env() {
    make -s --no-print-directory --eval 'b2b_env_probe: ; @printenv B2B_CONFIG || true' b2b_env_probe 2>/dev/null
}

check "no record: born2root.toml's VM" "$(vm_name)" "VM_NAME=\"$(bash utils/b2b_config.sh get B2B_VM_NAME)\""

make -s use B2B_CONFIG=profiles/server.toml >/dev/null
check "make use writes .b2b-config" "$(cat .b2b-config)" profiles/server.toml
check "recorded profile picks its VM" "$(vm_name)" 'VM_NAME="baas"'
check "recorded profile reaches the scripts' env" "$(recipe_env)" profiles/server.toml
check "an explicit B2B_CONFIG wins" "$(vm_name B2B_CONFIG=profiles/school.toml)" 'VM_NAME="debian"'

printf 'profiles/gone.toml\n' >.b2b-config
rc=0
out=$(make -n inception SRC=/x 2>&1) || rc=$?
check "a vanished profile stops make" "$rc" 2
check "  and names the fix" "$(printf '%s' "$out" | grep -c 'make use B2B_CONFIG=')" 1

make -s use B2B_CONFIG=profiles/server.toml >/dev/null
make -s use B2B_CONFIG= >/dev/null
check "make use B2B_CONFIG= removes the record" "$([ -e .b2b-config ] && echo present || echo absent)" absent

exit $fail
