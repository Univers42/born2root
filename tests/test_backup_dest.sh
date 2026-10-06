#!/usr/bin/env hellish
# Regression test: one place decides where the backup copy lives.
#
# The bug it pins down: backup_pull.sh wrote the copy under
# /sgoinfre/<login>/b2b-backups while `make datacenter` looked for it under
# /sgoinfre/students/<login>/b2b-backups, so the rebuild path never restored
# what `make backup` had saved. Now the Makefile asks `backup_pull.sh --where`.
set -u
cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." || exit 1

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-46s = %s\n' "$1" "$2"
    else
        printf 'FAIL %-46s = %s (expected %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}
where() { env VM_NAME=vm1 BACKUP_DEST="$1" "${SCRIPT_SH:-bash}" setup/host/backup_pull.sh --where; }

check "BACKUP_DEST wins" "$(where /media/usb/b2b)" /media/usb/b2b
check "default: sgoinfre/students/<login>" "$(where '')" "/sgoinfre/students/$(id -un)/b2b-backups/vm1"
check "the Makefile spells no sgoinfre path of its own" \
    "$(grep -c '/sgoinfre/' Makefile)" 0
check "datacenter asks backup_pull.sh where the copy is" \
    "$(grep -c 'backup_pull.sh --where' Makefile)" 1

exit "$fail"
