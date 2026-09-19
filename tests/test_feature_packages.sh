#!/usr/bin/env hellish
# generate/feature_packages.sh is a second table keyed by the MANIFEST's
# feature names, because the MANIFEST cannot grow a column (NF == 7 is a
# contract four readers rely on). Two tables drift unless something holds
# them together; this does, on every commit, with no VM.
#
# What it pins:
#   1. --check fails when a MANIFEST row has no package row, or a package row
#      names a feature that is not in the MANIFEST (both directions).
#   2. A bundle argument expands to its members; an unknown name is refused.
set -e

cd "$(dirname "$0")/.."

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s -- got: %s, expected: %s\n' "$1" "$2" "$3"
        fail=1
    fi
}
rc_of() {
    "$@" >/dev/null 2>&1 && echo 0 || echo $?
}

FPK=generate/feature_packages.sh

check "--check passes on the shipped tables" "$(rc_of bash "$FPK" --check)" 0

# Every MANIFEST name is printed by the full listing.
missing=0
listing=$(bash "$FPK")
while read -r n; do
    [ -n "$n" ] || continue
    printf '%s\n' "$listing" | grep -q "^  $n\b" || {
        echo "     missing from the listing: $n"
        missing=$((missing + 1))
    }
done <<EOF
$(sed -n "/^MANIFEST='/,/^'/p" generate/feature_profile.sh | awk 'NF == 7 { print $1 }')
EOF
check "the full listing names every MANIFEST row" "$missing" 0

check "a bundle expands to its members" "$(bash "$FPK" dc-standard | grep -c '^  dc-tunnel')" 1
check "a member of a nested bundle is listed too" "$(bash "$FPK" dc-full | grep -c '^  dc-gateway')" 1
check "one feature prints its images" "$(bash "$FPK" dc-db-postgres | grep -c 'img: .*grobase-postgres')" 1
check "an unknown name is refused" "$(rc_of bash "$FPK" dc-nonsense)" 1

# The drift check, both ways, on a copy of the script with a row removed and
# a row invented.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/generate"
cp generate/feature_profile.sh "$TMP/generate/"
sed '/^dc-db-redis /d' "$FPK" >"$TMP/generate/feature_packages.sh"
check "a MANIFEST row without a package row fails --check" "$(rc_of bash "$TMP/generate/feature_packages.sh" --check)" 1
sed 's/^dc-db-redis /dc-db-oracle /' "$FPK" >"$TMP/generate/feature_packages.sh"
check "a package row not in the MANIFEST fails --check" "$(rc_of bash "$TMP/generate/feature_packages.sh" --check)" 1

exit "$fail"
