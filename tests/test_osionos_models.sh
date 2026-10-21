#!/usr/bin/env hellish
# setup/host/osionos_models.sh ships groot's models runner into the guest. Its
# refusals come before any SSH: a missing groot checkout (or one without
# models/) and an unknown argument must stop with the fix named, never reach
# the guest with an empty tar stream. ssh is a stub that records a call.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
mkdir -p "$tmp/bin" "$tmp/groot/scripts"
printf '#!/bin/sh\necho called >>"%s/ssh.log"\nexit 1\n' "$tmp" >"$tmp/bin/ssh"
chmod +x "$tmp/bin/ssh"
: >"$tmp/groot/scripts/apply-models-migrations.sh"
run() { PATH="$tmp/bin:$PATH" VM_NAME=none "${SCRIPT_SH:-bash}" "$here/setup/host/osionos_models.sh" "$@" 2>&1; }
check() {
    if [ "$2" = 1 ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s\n' "$1"
        fail=1
    fi
}

out=$(GROOT_DIR="$tmp/nowhere" run) && rc=0 || rc=$?
case "$out" in *"GROOT_DIR=/path/to/groot"*) m=1 ;; *) m=0 ;; esac
check "a missing checkout is refused with the fix named (rc=$rc)" "$([ "$rc" -ne 0 ] && echo "$m")"
out=$(GROOT_DIR="$tmp/groot" run) && rc=0 || rc=$?
check "a checkout without models/ is refused (rc=$rc)" "$([ "$rc" -ne 0 ] && echo 1)"
mkdir "$tmp/groot/models"
out=$(GROOT_DIR="$tmp/groot" run --apply) && rc=0 || rc=$?
case "$out" in *"usage: osionos_models.sh [--check]"*) m=1 ;; *) m=0 ;; esac
check "an unknown argument is refused (rc=$rc)" "$([ "$rc" -ne 0 ] && echo "$m")"
check "no refusal reached ssh" "$([ ! -e "$tmp/ssh.log" ] && echo 1)"
exit "$fail"
