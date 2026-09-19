#!/usr/bin/env hellish
# The /var garbage collector must never touch a named volume.
#
# THE FAILURE IT PINS
#   `docker system prune -a --volumes` and `docker volume prune` delete
#   every volume no running container uses -- and a stopped stack's volumes
#   are exactly that. A nightly timer running either would find the engines'
#   data "unused" the first night the stack was down, and delete it. So the
#   cleaner refuses those flags outright (exit 2, a message naming the safe
#   command), and the pruning it does run never carries them.
#
# HOW
#   The cleaner is a heredoc in setup/install/dc/install_var_gc.sh; it is cut
#   out by its exact `cat >/usr/local/sbin/b2b-var-gc <<'GCEOF'` line and
#   run against a fake docker that only records its arguments. Renaming the
#   marker breaks this extraction, not the behaviour: rerun this test.
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

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

awk "/^cat >\/usr\/local\/sbin\/b2b-var-gc <<'GCEOF'\$/ { on = 1; next } /^GCEOF\$/ { on = 0 } on" \
    setup/install/dc/install_var_gc.sh >"$TMP/b2b-var-gc"
[ -s "$TMP/b2b-var-gc" ] || {
    echo "FAIL could not extract the cleaner from install_var_gc.sh"
    exit 1
}
chmod +x "$TMP/b2b-var-gc"

# A docker that writes every invocation down and succeeds.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/docker" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$TMP/docker.log"
exit 0
EOF
chmod +x "$TMP/bin/docker"
# The other tools the cleaner calls, as no-ops: it must not need root here.
for t in journalctl apt-get fstrim; do
    printf '#!/bin/sh\nexit 0\n' >"$TMP/bin/$t"
    chmod +x "$TMP/bin/$t"
done
export PATH="$TMP/bin:$PATH"

# --- refusals ----------------------------------------------------------------
for flag in --volumes --all -a volume; do
    rc=0
    out=$("$TMP/b2b-var-gc" "$flag" 2>&1) || rc=$?
    check "refuses $flag" "$rc" 2
    case "$out" in
    *refusing*) printf 'ok   ... and says so\n' ;;
    *)
        printf 'FAIL ... without saying why: %s\n' "$out"
        fail=1
        ;;
    esac
done
check "a refusal calls docker zero times" "$([ -f "$TMP/docker.log" ] && wc -l <"$TMP/docker.log" || echo 0)" 0

# --- what a normal run does ----------------------------------------------------
: >"$TMP/docker.log"
"$TMP/b2b-var-gc" >/dev/null 2>&1 || true
log=$(cat "$TMP/docker.log")
check "prunes the build cache" "$(printf '%s\n' "$log" | grep -c '^builder prune')" 1
check "prunes dangling images" "$(printf '%s\n' "$log" | grep -c '^image prune')" 1
check "prunes exited containers" "$(printf '%s\n' "$log" | grep -c '^container prune')" 1
check "never passes -a to image prune" "$(printf '%s\n' "$log" | grep '^image prune' | grep -c -- ' -a\b')" 0
check "never runs volume prune" "$(printf '%s\n' "$log" | grep -c 'volume')" 0
check "never runs system prune" "$(printf '%s\n' "$log" | grep -c '^system prune')" 0

exit "$fail"
