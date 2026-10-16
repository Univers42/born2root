#!/usr/bin/env hellish
# utils/login_entry.sh: a desktop login entry that waits for the files it
# names, then runs one command.
#
# The bug it pins: on 2026-10-16 the seat-tailnet entry fired at 14:15:40 and
# died on "No such file or directory", while the restored home brought
# ~/born2root at 14:16:25. seat_tailnet.sh and autostart.sh both write their
# entries through this helper; their own tests pin those Exec lines, this one
# the helper's rules: what it waits for, what it refuses, and that a rerun
# with the same command leaves the file alone.
set -u

cd "$(dirname "$0")/.." || exit 1
TMP=$(mktemp -d)
trap 'rm -rf "${TMP:?}"' EXIT
. utils/login_entry.sh

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s -- got: %s, expected: %s\n' "$1" "$2" "$3"
        fail=1
    fi
}

check "waits for every absolute path, not for NAME=/path" \
    "$(login_entry_exec env A=/x/conf /bin/sh /x/run.sh --flag)" \
    "timeout 1200 sh -c 'until [ -e /bin/sh ] && [ -e /x/run.sh ]; do sleep 2; done; exec env A=/x/conf /bin/sh /x/run.sh --flag'"
check "no path among the words: nothing to wait for" \
    "$(login_entry_exec echo hi)" "timeout 1200 sh -c 'until true; do sleep 2; done; exec echo hi'"

E="$TMP/autostart/x.desktop"
login_entry_write "$E" "x" "a comment" /bin/echo hi
check "writes the entry" "$(sed -n 's/^Name=//p; s/^X-GNOME-Autostart-enabled=//p' "$E" | tr '\n' ' ')" "x true "
touch -d '2000-01-01' "$E"
login_entry_write "$E" "x" "a comment" /bin/echo hi
check "the same command again: not rewritten" "$(date -r "$E" +%Y)" 2000
login_entry_write "$E" "x" "a comment" /bin/echo bye
check "another command: rewritten" "$(grep -c 'exec /bin/echo bye' "$E")" 1

for bad in "/a b/run.sh" "it's" '100%'; do
    rc=0
    login_entry_write "$TMP/autostart/bad.desktop" "x" "c" /bin/echo "$bad" 2>"$TMP/err" || rc=$?
    check "refused: '$bad'" "$rc/$([ -e "$TMP/autostart/bad.desktop" ] && echo written || echo none)" 1/none
done
check "... naming the word" "$(grep -c "'100%' holds" "$TMP/err")" 1

# The Exec line run the way GNOME runs it: still waiting while the file is
# missing, running it once it appears.
mkdir -p "$TMP/late"
late=$(login_entry_exec /bin/sh "$TMP/late/run.sh" | sed 's/^timeout 1200/timeout 3/')
eval "$late" >/dev/null 2>&1
check "the file missing: still waiting at the timeout" "$?" 124
printf 'echo ran >"%s/ran"\n' "$TMP" >"$TMP/late/run.sh"
eval "$late" >/dev/null 2>&1
check "the file there: it runs" "$(cat "$TMP/ran" 2>/dev/null)" ran
exit "$fail"
