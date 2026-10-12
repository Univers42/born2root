#!/usr/bin/env bash
# Pins the restic init guard in setup/install/dc/install_backup.sh. The old line
# `restic snapshots || restic init` ran init on ANY snapshots failure, so a wrong
# password printed "config file already exists" and hid the real error (2026-10-12).
# Caveat: runs the block by awk extraction from its `if ! snap_err` line to the
# first `fi`; the stub restic only mimics the two error wordings it matches.
set -u
cd "$(dirname "$0")/.." || exit 1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
block="$work/block.sh"
awk '/^if ! snap_err=/{p=1} p{print} p && /^fi$/{exit}' setup/install/dc/install_backup.sh >"$block"
fail=0
verdict() { # stands in for the guest installer's verdict helper
    printf 'verdict %s%s\n' "$1" "${2:-}"
}
export -f verdict
run_case() { # run_case <name> <stub-mode> -> prints the block's output
    local mode=$2 bin="$work/bin-$1"
    mkdir -p "$bin"
    cat >"$bin/restic" <<STUB
#!/bin/sh
case "\$1" in
    snapshots)
        case "$mode" in
            missing) echo "Fatal: unable to open config file: Stat: stat /r/config: no such file or directory: does not exist" >&2; exit 1 ;;
            badpw)   echo "Fatal: wrong password or no key found" >&2; exit 1 ;;
            ok)      exit 0 ;;
        esac ;;
    init) touch "$bin/inited" ;;
esac
STUB
    chmod +x "$bin/restic"
    PATH="$bin:$PATH" bash -c "source '$block'; echo rc=\$?" 2>&1
}
check() {
    if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else
        printf 'FAIL %s -- got: %s, expected: %s\n' "$1" "$2" "$3"
        fail=1
    fi
}
out=$(run_case missing missing)
check "missing repo: init runs and succeeds" "$([ -e "$work/bin-missing/inited" ] && echo 1 || echo 0)" 1
out=$(run_case badpw badpw)
check "wrong password: init never runs" "$([ -e "$work/bin-badpw/inited" ] && echo 1 || echo 0)" 0
check "wrong password: the real error is printed" "$(printf '%s' "$out" | grep -c 'wrong password or no key found')" 1
check "wrong password: fails the job" "$(printf '%s' "$out" | grep -c 'verdict failed restic-snapshots')" 1
out=$(run_case ok ok)
check "healthy repo: no init, no failure" "$([ -e "$work/bin-ok/inited" ] && echo 1 || echo 0)" 0
exit "$fail"
