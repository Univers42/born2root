#!/usr/bin/env hellish
# Regression test for what `make all`'s pre-flight says about the filesystem.
#
# THE BUG THIS PINS DOWN
#   The pre-flight printed "has 51.9 GB free" and nothing else about the
#   filesystem: not its size, not what was already on it, not what a 47 GB
#   build would leave (under 1 GB). It now prints the whole filesystem, and
#   used + reserved + free has to add up to the size it names.
#
# A stand-in `df` first in PATH gives a fixed 70 GB filesystem, so the rows
# are checked against known numbers rather than this machine's. The budget is
# pinned to 1000 GB for the same reason: at `auto` it counts this checkout's
# real disk_images/, so an 8 GB VM built here turned "47 GB passes" red.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
check() {
    local what="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        printf 'ok   %-40s = %s\n' "$what" "$got"
    else
        printf 'FAIL %-40s = %s (want %s)\n' "$what" "$got" "$want"
        fail=1
    fi
}

# 70 GB, 15 GB used, 52 GB free: 3 GB reserved.
mkdir -p "$TMP/bin" "$TMP/vms"
cat >"$TMP/bin/df" <<'DF'
#!/bin/sh
echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'
echo '/dev/fake 73408512 15728640 54525952 23% /fakefs'
DF
chmod +x "$TMP/bin/df"

preflight() { # GB
    PATH="$TMP/bin:$PATH" NO_COLOR=1 SPACE_BUDGET_GB=1000 VM_NAME=t VM_PATH="$TMP/vms" \
        "${SCRIPT_SH:-bash}" "$REPO_ROOT/utils/space_budget.sh" --preflight $(($1 * 1024)) 2>&1 |
        sed 's/\x1b\[[0-9;]*m//g'
}
row() { printf '%s\n' "$1" | awk -v r="$2" 'index($0, "    " r " ") == 1 { print $(NF - 1), $NF; exit }'; }

out=$(preflight 47)
check "names the mount point" "$(printf '%s\n' "$out" | grep -c '^    on /fakefs ')" 1
check "size" "$(row "$out" size)" "70.0 GB"
check "already used" "$(printf '%s\n' "$out" | awk '/^    already used / { print $3, $4; exit }')" "15.0 GB"
check "reserved by the filesystem" "$(row "$out" 'reserved by the filesystem')" "3.0 GB"
check "free now" "$(row "$out" 'free now')" "52.0 GB"
check "this build, at most (47 + 4)" "$(printf '%s\n' "$out" | awk '/^    this build, at most / { print $5, $6; exit }')" "51.0 GB"
check "free after, at worst" "$(row "$out" 'free after, at worst')" "1.0 GB"
check "47 GB passes" "$(printf '%s\n' "$out" | grep -c '✓ fits the budget')" 1

out=$(preflight 50)
check "50 GB: short by" "$(row "$out" 'short by')" "2.0 GB"
check "50 GB: refused" "$(printf '%s\n' "$out" | grep -c '✗ .* needs about 54.0 GB')" 1

exit "$fail"
