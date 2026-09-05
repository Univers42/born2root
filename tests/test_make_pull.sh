#!/usr/bin/env bash
# Regression test for the Makefile's `pull` target.
#
# THE BUG THIS PINS DOWN
#   `pull` used to wrap the pull in a hand-rolled `git stash` / `git stash pop`
#   pair. The two are not symmetric: `git stash` on a CLEAN tree saves nothing
#   and creates no stash entry, while the pop ran unconditionally and therefore
#   popped whatever unrelated entry was on top of the stack. A stash left over
#   from an earlier session was applied on top of an up-to-date checkout, and
#   `make all` then died on conflict markers in work that was already committed
#   -- twice, on this machine, before the cause was found.
#
#   The whole point is that this only reproduces when the tree is CLEAN, which
#   is the case nobody tests by hand.
#
# Runs the REAL `pull` recipe out of the project Makefile against a throwaway
# origin, so it cannot drift from what `make all` actually executes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAKEFILE="${MAKEFILE:-$REPO_ROOT/Makefile}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
check() {
	local what="$1" got="$2" want="$3"
	if [ "$got" = "$want" ]; then
		printf 'ok   %-46s = %s\n' "$what" "$got"
	else
		printf 'FAIL %-46s = %s (want %s)\n' "$what" "$got" "$want"
		fail=1
	fi
}

git_q() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }

# ── A throwaway origin with one commit on main ──────────────────────────────
git_q init -q --bare "$TMP/origin.git"
git_q clone -q "$TMP/origin.git" "$TMP/seed" 2> /dev/null
printf 'committed content\n' > "$TMP/seed/tracked.txt"
git_q -C "$TMP/seed" add -A
git_q -C "$TMP/seed" commit -qm init
git_q -C "$TMP/seed" push -q origin main

# ── A working clone that carries a STALE stash and a clean tree ─────────────
git_q clone -q "$TMP/origin.git" "$TMP/work"
cp "$MAKEFILE" "$TMP/work/Makefile"

printf 'STALE WIP FROM DAYS AGO\n' > "$TMP/work/tracked.txt"
git_q -C "$TMP/work" stash -q
check "stale stash is on the stack" "$(git_q -C "$TMP/work" stash list | wc -l)" 1
check "tree is clean before the pull" "$(git_q -C "$TMP/work" status --porcelain --untracked-files=no | wc -l)" 0

# ── The real recipe ─────────────────────────────────────────────────────────
( cd "$TMP/work" && make --no-print-directory pull ) > "$TMP/pull.log" 2>&1
pull_rc=$?

check "pull succeeded" "$pull_rc" 0
check "stale WIP was NOT applied" "$(cat "$TMP/work/tracked.txt")" "committed content"
check "tree still clean after the pull" "$(git_q -C "$TMP/work" status --porcelain --untracked-files=no | wc -l)" 0
check "stale stash left untouched" "$(git_q -C "$TMP/work" stash list | wc -l)" 1
check "no conflict markers" "$(grep -rc '^<<<<<<<' "$TMP/work/tracked.txt")" 0

# ── The case autostash DOES have to handle: real local edits survive ────────
printf 'my real local edit\n' > "$TMP/work/tracked.txt"
printf 'new upstream line\n' >> "$TMP/seed/other.txt"
git_q -C "$TMP/seed" add -A
git_q -C "$TMP/seed" commit -qm "upstream moves"
git_q -C "$TMP/seed" push -q origin main

( cd "$TMP/work" && make --no-print-directory pull ) > "$TMP/pull2.log" 2>&1
check "pull with real local edits succeeded" "$?" 0
check "local edit survived the pull" "$(cat "$TMP/work/tracked.txt")" "my real local edit"
check "upstream commit arrived" "$([ -f "$TMP/work/other.txt" ] && echo yes || echo no)" yes

exit "$fail"
