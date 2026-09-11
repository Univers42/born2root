#!/usr/bin/env hellish
# Regression test for generate/partition_recipe.sh.
#
# What it guards: the partition layout is COMPUTED from SIZE_B2B, and the copy
# checked into preseeds/preseed.cfg is that computation's output for the
# default. If someone edits the recipe by hand, or changes the model without
# regenerating, the ISO built for the default would differ from what the file
# says -- silently. The first check here is that diff. The rest pin the shape
# of the model at both ends of the range, and the refusal below the minimum.
set -e

cd "$(dirname "$0")/.."

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-52s = %s\n' "$1" "$2"
    else
        printf 'FAIL %-52s = %s (expected %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}
GEN="${SCRIPT_SH:-bash} generate/partition_recipe.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ── The checked-in recipe IS the generator's default output ─────────────────
awk '/^# ── RECIPE-BEGIN/,/^# ── RECIPE-END/' preseeds/preseed.cfg >"$TMP/checked-in"
$GEN --recipe >"$TMP/generated"
check "preseed.cfg recipe matches generator (15 GB)" "$(cmp -s "$TMP/checked-in" "$TMP/generated" && echo same || echo DIFFERENT)" same

# ── Shape at every size: eight volumes, var last, everything accounted for ──
for gb in 8 10 15 50 500; do
    SIZE_B2B=$gb $GEN --recipe >"$TMP/r$gb"
    check "$gb GB: eight logical volumes" "$(grep -c 'lv_name{' "$TMP/r$gb")" 8
    check "$gb GB: var is the last volume" "$(grep 'lv_name{' "$TMP/r$gb" | tail -1 | sed 's/.*lv_name{ *\([^ }]*\).*/\1/')" var
    check "$gb GB: var absorbs the remainder (-1)" "$(grep -B2 'lv_name{ var }' "$TMP/r$gb" | head -1 | awk '{print $3}')" -1
    # Σ(pinned) + var == the group: nothing lost, nothing double-counted.
    SIZE_B2B=$gb $GEN --sizes >"$TMP/s$gb"
    sum=$(awk -F= '$1 != "boot" { s += $2 } END { print s }' "$TMP/s$gb")
    check "$gb GB: volumes sum to the group size" "$sum" "$((gb * 1024 - 521))"
done

# ── Floors and caps ─────────────────────────────────────────────────────────
check "8 GB: root at its floor" "$(awk -F= '$1=="root"{print $2}' "$TMP/s8")" "$(sed -n "/^LAYOUT='/,/^'/p" generate/partition_recipe.sh | awk '$1=="root"{print $2}')"
check "8 GB: every volume at floor (surplus is 0)" "$(SIZE_B2B=8 $GEN --table | grep -c 'smallest layout that works')" 1
check "500 GB: root capped at 30 GB" "$(awk -F= '$1=="root"{print $2}' "$TMP/s500")" 30720
check "500 GB: tmp capped at 10 GB" "$(awk -F= '$1=="tmp"{print $2}' "$TMP/s500")" 10240
check "500 GB: var takes the bulk (>300 GB)" "$(awk -F= '$1=="var"{print ($2 > 307200) ? "yes" : "no"}' "$TMP/s500")" yes

# ── swap follows RAM, bounded by the disk ───────────────────────────────────
check "15 GB, 2 GB RAM: swap 2048" "$(awk -F= '$1=="swap"{print $2}' "$TMP/s15")" 2048
# At 15 GB a quarter of the group (3709) binds before the 4 GB cap does, so the
# cap is only observable on a disk with room for it.
check "15 GB, 8 GB RAM: swap is a quarter of the group" "$(SIZE_B2B=15 VM_RAM_MB=8192 $GEN --sizes | awk -F= '$1=="swap"{print $2}')" "$(((15360 - 521) / 4))"
check "30 GB, 8 GB RAM: swap clamped to 4096" "$(SIZE_B2B=30 VM_RAM_MB=8192 $GEN --sizes | awk -F= '$1=="swap"{print $2}')" 4096
check "10 GB, 8 GB RAM: swap ≤ 25% of the group" "$(SIZE_B2B=10 VM_RAM_MB=8192 $GEN --sizes | awk -F= '$1=="swap"{print ($2 <= (10240-521)/4) ? "yes" : "no"}')" yes
check "1 GB RAM: swap never below 1024" "$(SIZE_B2B=15 VM_RAM_MB=512 $GEN --sizes | awk -F= '$1=="swap"{print $2}')" 1024

# ── Below the minimum: refuse, and name the size that works ─────────────────
out=$(SIZE_B2B=7 $GEN --recipe 2>&1) && rc=0 || rc=$?
check "7 GB: refused" "$rc" 1
check "7 GB: names the minimum" "$(printf '%s' "$out" | grep -o 'SIZE_B2B must be at least [0-9]*')" "SIZE_B2B must be at least 8"
check "7 GB: emits no recipe" "$(printf '%s' "$out" | grep -c expert_recipe)" 0
out=$(SIZE_B2B=abc $GEN --recipe 2>&1) && rc=0 || rc=$?
check "non-numeric SIZE_B2B: refused" "$rc" 1

# ── DISK_SIZE_MB wins over SIZE_B2B (the Makefile forwards both) ────────────
check "DISK_SIZE_MB=20480 beats SIZE_B2B=15" "$(SIZE_B2B=15 DISK_SIZE_MB=20480 $GEN --recipe | grep -o 'SIZE_B2B=[0-9]*' | head -1)" "SIZE_B2B=20"

exit "$fail"
