#!/usr/bin/env hellish
# The /var garbage collector must never touch a named volume, and must clean
# harder, not wider, once /var or /var/log reaches 90%.
#
# THE FAILURE IT PINS
#   `docker system prune -a --volumes` and `docker volume prune` delete
#   every volume no running container uses -- and a stopped stack's volumes
#   are exactly that. A nightly timer running either would find the engines'
#   data "unused" the first night the stack was down, and delete it. So the
#   cleaner refuses those flags outright (exit 2, a message naming the safe
#   command), and the pruning it does run never carries them -- not even in
#   the deep pass the 10-minute watch timer (`--if-full`) runs at 90%.
#
# HOW
#   The cleaner is a heredoc in setup/install/dc/install_var_gc.sh; it is cut
#   out by its exact `cat >/usr/local/sbin/b2b-var-gc <<'GCEOF'` line and
#   run against stubs that record their arguments: a docker, a df reporting
#   the percentage in $STUB_DIR/use (a prune drops it to 50% when
#   $STUB_DIR/drop exists), and a find, so the host's /var/log is never
#   walked. Renaming the marker breaks this extraction, not the behaviour:
#   rerun this test.
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
export STUB_DIR="$TMP"

awk "/^cat >\/usr\/local\/sbin\/b2b-var-gc <<'GCEOF'\$/ { on = 1; next } /^GCEOF\$/ { on = 0 } on" \
    setup/install/dc/install_var_gc.sh >"$TMP/b2b-var-gc"
[ -s "$TMP/b2b-var-gc" ] || {
    echo "FAIL could not extract the cleaner from install_var_gc.sh"
    exit 1
}
chmod +x "$TMP/b2b-var-gc"

mkdir -p "$TMP/bin"
cat >"$TMP/bin/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$STUB_DIR/docker.log"
case "$2" in prune) if [ -f "$STUB_DIR/drop" ]; then echo 50 >"$STUB_DIR/use"; fi ;; esac
exit 0
EOF
cat >"$TMP/bin/df" <<'EOF'
#!/bin/sh
u=$(cat "$STUB_DIR/use")
echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'
for a in "$@"; do
    case "$a" in -*) ;; *) echo "/dev/fake 1000 $((u * 10)) $((1000 - u * 10)) $u% $a" ;; esac
done
EOF
for t in find journalctl; do
    cat >"$TMP/bin/$t" <<EOF
#!/bin/sh
printf '%s\\n' "\$*" >>"\$STUB_DIR/$t.log"
EOF
done
# The other tools the cleaner calls, as no-ops: it must not need root here.
for t in apt-get fstrim du; do
    printf '#!/bin/sh\nexit 0\n' >"$TMP/bin/$t"
done
chmod +x "$TMP"/bin/*
export PATH="$TMP/bin:$PATH"

# run <percent> [args...]: a fresh run at that fill; sets rc, out and the logs.
run() {
    echo "$1" >"$TMP/use"
    shift
    : >"$TMP/docker.log"
    : >"$TMP/find.log"
    : >"$TMP/journalctl.log"
    rc=0
    out=$("$TMP/b2b-var-gc" "$@" 2>&1) || rc=$?
    log=$(cat "$TMP/docker.log")
}
count() { printf '%s\n' "$log" | grep -c -- "$1" || true; }
never_unsafe() {
    check "$1: never passes -a to image prune" "$(printf '%s\n' "$log" | grep '^image prune' | grep -c -- ' -a' || true)" 0
    check "$1: never runs volume prune" "$(count volume)" 0
    check "$1: never runs system prune" "$(count '^system prune')" 0
}

# --- refusals ----------------------------------------------------------------
for flag in --volumes --all -a volume; do
    run 50 "$flag"
    check "refuses $flag" "$rc" 2
    case "$out" in
    *refusing*) printf 'ok   ... and says so\n' ;;
    *)
        printf 'FAIL ... without saying why: %s\n' "$out"
        fail=1
        ;;
    esac
    check "... and calls docker zero times" "$(printf '%s' "$log" | wc -l)" 0
done
run 50 --verbose
check "an unknown option is an error, not ignored" "$rc" 2

# --- the daily pass, below the threshold ---------------------------------------
run 50
check "daily: exit 0" "$rc" 0
check "daily: prunes the build cache older than a week" "$(count '^builder prune -f --filter until=168h$')" 1
check "daily: prunes dangling images" "$(count '^image prune')" 1
check "daily: prunes exited containers" "$(count '^container prune')" 1
check "daily: no deep pass below 90%" "$(count '^builder prune -af')" 0
check "daily: leaves rotated logs alone below 90%" "$(wc -l <"$TMP/find.log")" 0
never_unsafe daily

# --- the watch timer: --if-full ------------------------------------------------
run 89 --if-full
check "watch at 89%: exit 0" "$rc" 0
check "watch at 89%: does nothing" "$(printf '%s' "$log" | wc -l)" 0

touch "$TMP/drop"
run 95 --if-full
rm -f "$TMP/drop"
check "watch at 95%, the regular pass enough: exit 0" "$rc" 0
check "... and no deep pass" "$(count '^builder prune -af')" 0

run 95 --if-full
check "watch at 95% and staying: exit 1" "$rc" 1
check "deep: all build cache" "$(count '^builder prune -af$')" 1
check "deep: exited containers older than an hour" "$(count '^container prune -f --filter until=1h$')" 1
check "deep: journal down to 100 MB" "$(grep -c -- '--vacuum-size=100M' "$TMP/journalctl.log" || true)" 1
check "deep: rotated logs, /var/log/sudo pruned out" "$(grep -c -- '/var/log -xdev -path /var/log/sudo -prune' "$TMP/find.log" || true)" 1
check "deep: reports what is left" "$(printf '%s\n' "$out" | grep -c 'still 95% full' || true)" 1
check "deep: shows docker's own accounting" "$(count '^system df$')" 1
never_unsafe deep

exit "$fail"
