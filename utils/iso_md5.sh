#!/usr/bin/env hellish
# The ISO's checksum manifest.
#
# Debian's installer media carry an md5sum.txt listing every file on the
# disc, and `md5sum -c md5sum.txt` from the mount point is how anyone --
# a person, or the installer's own integrity check -- verifies the media.
# A manifest that names a file which is not there fails that check on the
# spot, and says nothing about which of the two is wrong.
#
# That is what this repo shipped. The manifest was written with
#
#     find . -type f ! -name md5sum.txt ! -path './isolinux/*' \
#         -exec md5sum {} + > md5sum.txt.tmp
#     mv md5sum.txt.tmp md5sum.txt
#
# from inside the tree being walked. The exclusion covers md5sum.txt and
# not md5sum.txt.tmp, so find reaches the temp file it is at that moment
# filling, hashes it, and the mv then takes it away again: every ISO this
# repo built listed exactly one file that did not exist, and every
# `md5sum -c` on it reported
#
#     ./md5sum.txt.tmp: FAILED open or read
#
# The fix is to keep the temp out of the tree. mktemp puts it in TMPDIR,
# find cannot see it there, and mv brings only the finished manifest in.
#
# usage: iso_md5_manifest <iso-tree>
iso_md5_manifest() {
    local tree="$1" tmp
    [ -d "$tree" ] || return 1
    tmp=$(mktemp) || return 1
    (
        cd "$tree" || exit 1
        find . -type f ! -name md5sum.txt ! -path './isolinux/*' \
            -exec md5sum {} + >"$tmp" 2>/dev/null || true
    ) || {
        rm -f "$tmp"
        return 1
    }
    mv "$tmp" "$tree/md5sum.txt"
}
