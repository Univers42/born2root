#!/usr/bin/env hellish
# Regression test for the size `make all` builds at.
#
# THE BUGS THIS PINS DOWN
#   1. `make all VM_SIZE=50` and `VM_SIZE=50 make all` built a 15 GB VM without
#      a word: the Makefile had no VM_SIZE, and make accepts any variable.
#   2. `make all SIZE_B2B=50` built 15 GB too, on a machine whose .b2b-features
#      had been saved at 15. The recipe let the saved size win whenever it
#      differed from the one asked for, but the picker only ever GROWS the
#      disk, so a smaller saved size is a selection for another disk.
#
# Runs the REAL `all` recipe, printed by `make -n`, with the sub-make replaced
# by an echo, so it cannot drift from what `make all` executes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
check() {
    local what="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        printf 'ok   %-50s = %s\n' "$what" "$got"
    else
        printf 'FAIL %-50s = %s (want %s)\n' "$what" "$got" "$want"
        fail=1
    fi
}

# The size the sub-make is handed: the recipe from `sel=` to the `_build`
# line, run in $TMP beside a .b2b-features saved at $1 GB (none when empty).
built_size() {
    local saved="$1" recipe
    shift
    rm -f "$TMP/.b2b-features"
    [ -z "$saved" ] || printf 'B2B_SELECT_SIZE_GB=%s\n' "$saved" >"$TMP/.b2b-features"
    recipe=$(make --no-print-directory -n -C "$REPO_ROOT" all \
        B2B_CONFIG="$REPO_ROOT/tests/fixtures/default.toml" "$@" 2>&1 |
        awk '/^sel=/ { on = 1 } on { print } on && /_build/ { exit }')
    [ -n "$recipe" ] || {
        make --no-print-directory -n -C "$REPO_ROOT" all "$@" 2>&1 | grep -m1 '\*\*\*'
        return 0
    }
    (cd "$TMP" && "${SCRIPT_SH:-bash}" -c "$(printf '%s\n' "$recipe" |
        sed 's/^[^ ]*make --no-print-directory _build/echo/')" 2>/dev/null) |
        grep -oE 'SIZE_B2B=[0-9]+' | tail -n1
}

check "SIZE_B2B=50, nothing saved" "$(built_size '' SIZE_B2B=50)" "SIZE_B2B=50"
check "SIZE_B2B=50, saved at 15 (bug 2)" "$(built_size 15 SIZE_B2B=50)" "SIZE_B2B=50"
check "SIZE_B2B=15, picker grew it to 20" "$(built_size 20 SIZE_B2B=15)" "SIZE_B2B=20"
check "VM_SIZE=50 (bug 1)" "$(built_size '' VM_SIZE=50)" "SIZE_B2B=50"
check "VM_SIZE=47G" "$(built_size '' VM_SIZE=47G)" "SIZE_B2B=47"
check "VM_SIZE=47Go" "$(built_size 15 VM_SIZE=47Go)" "SIZE_B2B=47"
check "VM_SIZE=47GB" "$(built_size '' VM_SIZE=47GB)" "SIZE_B2B=47"

# The prefix form, `VM_SIZE=50 make all`, arrives as the environment.
env_size() { VM_SIZE="$1" built_size "$2"; }
check "VM_SIZE=50 in the environment, saved at 15" "$(env_size 50 15)" "SIZE_B2B=50"

refusal() { make --no-print-directory -n -C "$REPO_ROOT" all "$@" 2>&1 | grep -c '\*\*\* VM_SIZE'; }
check "VM_SIZE=big is refused" "$(refusal VM_SIZE=big)" 1
check "VM_SIZE=50 SIZE_B2B=30 is refused" "$(refusal VM_SIZE=50 SIZE_B2B=30)" 1
check "VM_SIZE=50 in env, SIZE_B2B=30 refused" "$(VM_SIZE=50 refusal SIZE_B2B=30)" 1

# The sub-make must not re-apply VM_SIZE over the size the picker settled on.
check "sub-make gets VM_SIZE= (picker grew 47 to 52)" \
    "$(make --no-print-directory -n -C "$REPO_ROOT" _build SIZE_B2B=52 VM_SIZE= B2B_NO_SELECT=1 \
        B2B_CONFIG="$REPO_ROOT/tests/fixtures/default.toml" 2>&1 |
        grep -oE 'DISK_SIZE_MB="[0-9]+"' | sort -u)" 'DISK_SIZE_MB="53248"'

exit "$fail"
