#!/usr/bin/env hellish
# Every provisioner first boot runs must reach /root: staged on the ISO by
# generate/create_custom_iso.sh AND copied off it by preseed.cfg's late_command.
#
# The bug this pins: on the 2026-09-12 QEMU build install_claude_code.sh was
# staged ("✓ install_claude_code.sh" in the ISO log), but late_command had no
# `cp` for it. Its copies all end in `2>/dev/null || true`, so nothing noticed
# until first boot filed "claude-code failed - 0" ("not in the ISO", which it
# was) and `make all` stopped 25 minutes in. Three lists name the same files
# and nothing held them together; this test does, with no VM.
set -e

cd "$(dirname "$0")/.."

fail=0
pass() { printf 'ok   %s\n' "$1"; }
flunk() {
    printf 'FAIL %s\n' "$1"
    fail=1
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# What first boot runs: every /root/install_*.sh it names.
grep -oE '/root/install_[a-z_]+\.sh' preseeds/first-boot-setup.sh |
    sed 's|^/root/||' | sort -u >"$TMP/needed"
# What the ISO carries: the provisioner loop's list, as basenames.
awk '/^for PROVISIONER in/,/; do$/' generate/create_custom_iso.sh |
    grep -oE 'setup/install/[^ ]+\.sh' | sed 's|.*/||' | sort -u >"$TMP/staged"
# What late_command copies into /root, only where source and target agree.
grep -oE 'cp /cdrom/install_[a-z_]+\.sh /target/root/install_[a-z_]+\.sh' preseeds/preseed.cfg |
    awk '{ s = $2; t = $3; sub(".*/", "", s); sub(".*/", "", t); if (s == t) print s }' |
    sort -u >"$TMP/copied"

if [ -s "$TMP/needed" ] && [ -s "$TMP/staged" ] && [ -s "$TMP/copied" ]; then
    pass "found $(wc -l <"$TMP/needed") needed, $(wc -l <"$TMP/staged") staged, $(wc -l <"$TMP/copied") copied"
else
    flunk "a list came back empty (needed/staged/copied) -- the parsing no longer matches the files"
fi

while read -r f; do
    [ -n "$f" ] || continue
    if grep -qxF "$f" "$TMP/staged"; then
        pass "$f is staged on the ISO"
    else
        flunk "$f is run at first boot but create_custom_iso.sh does not stage it"
    fi
    if grep -qxF "$f" "$TMP/copied"; then
        pass "$f is copied into /root by late_command"
    else
        flunk "$f is run at first boot but preseed.cfg's late_command never copies it"
    fi
done <"$TMP/needed"

# Staged but not copied is dead weight on the ISO at best, and the same bug the
# day first boot starts running it.
while read -r f; do
    [ -n "$f" ] || continue
    grep -qxF "$f" "$TMP/copied" ||
        flunk "$f is staged on the ISO but late_command never copies it"
done <"$TMP/staged"

exit "$fail"
