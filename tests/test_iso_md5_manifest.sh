#!/usr/bin/env hellish
# Regression test for utils/iso_md5.sh.
#
# The bug it guards, reproducible on any build of this repo before the fix:
# the ISO's md5sum.txt listed ./md5sum.txt.tmp, a file the very next line
# renamed away, so `md5sum -c md5sum.txt` on the finished media reported
#
#     ./md5sum.txt.tmp: FAILED open or read
#
# every single time. The manifest was written from inside the tree being
# walked, and the `! -name md5sum.txt` exclusion did not cover the temp.
# Debian's installer media are verified with exactly that command, so the
# check people are told to run could never pass.
#
# Here the tree is a fabrication: a handful of files, one of them under
# isolinux/ (which the manifest deliberately skips, because the bootloader
# rewrites it), and TMPDIR pointed inside the tree as well -- so a temp
# file placed by the old idiom would still be found, and the test would
# still catch a regression that moved it somewhere else in the tree.
set -e

cd "$(dirname "$0")/.."

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-46s = %s\n' "$1" "$3"
    else
        printf 'FAIL %-46s = %s (expected %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}

. ./utils/iso_md5.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TREE="$TMP/iso"
mkdir -p "$TREE/dists/stable" "$TREE/isolinux"
printf 'one\n' >"$TREE/README.txt"
printf 'two\n' >"$TREE/dists/stable/Release"
printf 'boot\n' >"$TREE/isolinux/isolinux.cfg"

iso_md5_manifest "$TREE"

check "the manifest was written" \
    "$([ -f "$TREE/md5sum.txt" ] && echo yes || echo no)" yes
check "every file it names exists and matches" \
    "$(cd "$TREE" && md5sum -c --quiet md5sum.txt >/dev/null 2>&1 && echo yes || echo no)" yes
check "no temp file left in the tree" \
    "$(find "$TREE" -name 'md5sum.txt.tmp' -o -name 'tmp.*' | wc -l)" 0
check "it lists the files, itself excepted" \
    "$(wc -l <"$TREE/md5sum.txt")" 2
check "isolinux is left out, as the bootloader rewrites it" \
    "$(grep -c isolinux "$TREE/md5sum.txt" || true)" 0
check "the manifest does not name itself" \
    "$(grep -c 'md5sum\.txt' "$TREE/md5sum.txt" || true)" 0

# A second pass over a tree that already has a manifest must replace it,
# not hash the old one into the new.
iso_md5_manifest "$TREE"
check "a rebuild still verifies" \
    "$(cd "$TREE" && md5sum -c --quiet md5sum.txt >/dev/null 2>&1 && echo yes || echo no)" yes
check "a rebuild does not grow the manifest" \
    "$(wc -l <"$TREE/md5sum.txt")" 2

exit "$fail"
