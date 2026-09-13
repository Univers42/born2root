#!/usr/bin/env hellish
# Regression test for generate/partition_recipe.sh.
#
# What it guards: the partition layout is COMPUTED from SIZE_B2B, and the copy
# checked into preseeds/preseed.cfg.in is that computation's output for the
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

# The volume table comes from born2root.conf, which people personalise. Every
# number below is about the SHIPPED table, so pin it; the fixture runs at the
# end point B2B_CONFIG at variants of it per command.
DEFAULTS=tests/fixtures/default.conf
export B2B_CONFIG="$DEFAULTS"
# A variant of the defaults: sed expressions, each its own -e. Prints its path.
variant() {
    local out="$TMP/$1.conf" e
    local -a args=()
    shift
    for e in "$@"; do
        args+=(-e "$e")
    done
    sed "${args[@]}" "$DEFAULTS" >"$out"
    printf '%s' "$out"
}
lv_names() { grep -o 'lv_name{ [^ }]* }' | sed 's/lv_name{ \(.*\) }/\1/' | tr '\n' ' '; }

# ── The checked-in recipe IS the generator's default output ─────────────────
awk '/^# ── RECIPE-BEGIN/,/^# ── RECIPE-END/' preseeds/preseed.cfg.in >"$TMP/checked-in"
$GEN --recipe >"$TMP/generated"
check "preseed.cfg.in recipe matches generator (15 GB)" "$(cmp -s "$TMP/checked-in" "$TMP/generated" && echo same || echo DIFFERENT)" same

# ── Shape at every size: eight volumes, var last, everything accounted for ──
for gb in 8 10 15 50 500; do
    SIZE_B2B=$gb $GEN --recipe >"$TMP/r$gb"
    check "$gb GB: eight logical volumes" "$(grep -c 'lv_name{' "$TMP/r$gb")" 8
    check "$gb GB: var is the last volume" "$(grep 'lv_name{' "$TMP/r$gb" | tail -1 | sed 's/.*lv_name{ *\([^ }]*\).*/\1/')" var
    check "$gb GB: var absorbs the remainder (-1)" "$(grep -B2 'lv_name{ var }' "$TMP/r$gb" | head -1 | awk '{print $3}')" -1
    # Σ(pinned) + var == the group: nothing lost, nothing double-counted.
    SIZE_B2B=$gb $GEN --sizes >"$TMP/s$gb"
    sum=$(awk -F= '$1 != "boot" && $1 !~ /^holder:/ { s += $2 } END { print s }' "$TMP/s$gb")
    check "$gb GB: volumes sum to the group size" "$sum" "$((gb * 1024 - 521))"
done

# ── Floors and caps ─────────────────────────────────────────────────────────
check "8 GB: root at its floor" "$(awk -F= '$1=="root"{print $2}' "$TMP/s8")" "$(${SCRIPT_SH:-bash} utils/b2b_config.sh --volumes | awk '$1=="root"{print $3}')"
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

# ── The table decides which volumes exist ───────────────────────────────────
# Nothing in the generator names a volume any more. These pin what used to
# break: a dropped row printed a stanza with empty sizes that the ISO guard
# still counted as fine, and an added row changed --sizes without ever
# reaching the recipe, so the fit check and the installed disk disagreed.
check "defaults: the recipe's volumes, in order" "$($GEN --recipe | lv_names)" "root swap home opt srv tmp var-log var "
check "defaults: every priced mount has its own volume" "$($GEN --sizes | grep '^holder:' | tr '\n' ' ')" "holder:/=root holder:/opt=opt holder:/var=var holder:/home=home "

f=$(variant no-opt '/^B2B_VOLUME  opt /d' 's|^\(B2B_VOLUME  root  *\S*  *\S*\)  *25 |\1   30 |')
check "no /opt: seven volumes, no opt" "$(B2B_CONFIG=$f $GEN --recipe | lv_names)" "root swap home srv tmp var-log var "
check "no /opt: no empty stanza anywhere" "$(B2B_CONFIG=$f $GEN --recipe | grep -cE '^\s+(ext4|linux-swap) \\$|^\s+[0-9]* +[0-9]* +ext4')" 0
check "no /opt: /opt is held by root" "$(B2B_CONFIG=$f $GEN --sizes | sed -n 's|^holder:/opt=||p')" root
check "no /opt: root got the share" "$(B2B_CONFIG=$f $GEN --sizes | awk -F= '$1=="root"{print ($2 > 4381) ? "grew" : "same"}')" grew
for gb in 8 15 50; do
    B2B_CONFIG=$f SIZE_B2B=$gb $GEN --sizes >"$TMP/no-opt$gb"
    check "no /opt, $gb GB: volumes sum to the group size" "$(awk -F= '$1 != "boot" && $1 !~ /^holder:/ { s += $2 } END { print s }' "$TMP/no-opt$gb")" "$((gb * 1024 - 521))"
done

f=$(variant www '/^B2B_VOLUME  var  /i\
B2B_VOLUME  www  /var/www  256  2  10240')
check "added /var/www: nine volumes, www before var" "$(B2B_CONFIG=$f $GEN --recipe | lv_names)" "root swap home opt srv tmp var-log www var "
check "added /var/www: mounted there" "$(B2B_CONFIG=$f $GEN --recipe | grep -A4 'lv_name{ www }' | grep -o 'mountpoint{ [^ ]* }')" "mountpoint{ /var/www }"
check "added /var/www: /var is still held by var" "$(B2B_CONFIG=$f $GEN --sizes | sed -n 's|^holder:/var=||p')" var
check "added /var/www: volumes sum to the group" "$(B2B_CONFIG=$f $GEN --sizes | awk -F= '$1 != "boot" && $1 !~ /^holder:/ { s += $2 } END { print s }')" "$((15 * 1024 - 521))"

f=$(variant rest-home 's|^B2B_VOLUME  home .*|B2B_VOLUME  home  /home  512  rest  -|' 's|^B2B_VOLUME  var  .*|B2B_VOLUME  var  /var  2048  18  -|')
check "rest on /home: home is the last volume" "$(B2B_CONFIG=$f $GEN --recipe | lv_names | awk '{print $NF}')" home
check "rest on /home: home takes the remainder (-1)" "$(B2B_CONFIG=$f $GEN --recipe | grep -B2 'lv_name{ home }' | head -1 | awk '{print $3}')" -1
check "rest on /home: the header names /home" "$(B2B_CONFIG=$f $GEN --recipe | grep -c '^# /home is last with -1')" 1

f=$(variant swap3g 's/^B2B_SWAP_MB=.*/B2B_SWAP_MB=3000/')
check "B2B_SWAP_MB=3000 at 15 GB: swap is 3000" "$(B2B_CONFIG=$f $GEN --sizes | awk -F= '$1=="swap"{print $2}')" 3000
out=$(B2B_CONFIG=$f SIZE_B2B=8 $GEN --recipe 2>&1) && rc=0 || rc=$?
check "B2B_SWAP_MB=3000 at 8 GB: refused, not shrunk" "$rc" 1
check "B2B_SWAP_MB=3000 at 8 GB: names the size that fits" "$(printf '%s' "$out" | grep -o 'SIZE_B2B must be at least [0-9]*')" "SIZE_B2B must be at least 10"

f=$(variant two-rest 's|^B2B_VOLUME  home .*|B2B_VOLUME  home  /home  512  rest  -|')
out=$(B2B_CONFIG=$f $GEN --recipe 2>&1) && rc=0 || rc=$?
check "two rest volumes: refused" "$rc" 1
check "two rest volumes: names B2B_VOLUME" "$(printf '%s' "$out" | grep -c "share 'rest'")" 1
check "two rest volumes: emits no recipe" "$(printf '%s' "$out" | grep -c expert_recipe)" 0

exit "$fail"
