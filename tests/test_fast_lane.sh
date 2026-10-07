#!/usr/bin/env hellish
# Regression test: a host whose hide (the Tor tool) runs in global mode builds
# on its fast lane, and never opens that lane itself.
#
# The bug it pins down: with GLOBAL=on every connection the host opens goes
# through Tor, QEMU's slirp included, so the 2026-10-06 server build fetched
# the netinst ISO at 390 KB/s and pulled the guest's images the same way; on
# the lane the ISO came at 6 MB/s. utils/fast_lane.sh re-executes the entry
# scripts there, and stays put (on Tor) in every case that is not the user's
# explicit choice: a closed lane, a typo in the opt-out, a lane that refuses.
#
# hide, the hide-fast group and hide's config are all stand-ins: no sudo, no
# network, and the same result on a host without hide.
set -u
cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." || exit 1

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-52s = %s\n' "$1" "$2"
    else
        printf 'FAIL %-52s = %s (expected %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
# The stand-in hide: the probe (`fast run true`) answers $HIDE_PROBE; a real
# launch prints what it was asked to run.
cat >"$TMP/bin/hide" <<'SH'
#!/bin/sh
echo "$*" >>"$HIDE_LOG"
[ "$3" = true ] && exit "${HIDE_PROBE:-0}"
echo "LAUNCHED $*"
SH
chmod +x "$TMP/bin/hide"
export HIDE_LOG="$TMP/hide.log" B2B_HIDE_CONF="$TMP/hide.conf"
export PATH="$TMP/bin:$PATH"

# <hide.conf body> <lane gid: other|mine> [VAR=value...] -> what happened
lane() {
    printf '%s\n' "$1" >"$B2B_HIDE_CONF"
    : >"$HIDE_LOG"
    local lane_gid=4242
    [ "$2" = mine ] && lane_gid=$(id -g)
    (
        unset B2B_FAST_LANE
        [ $# -le 2 ] || export "${@:3}"
        # shellcheck source=utils/fast_lane.sh
        . utils/fast_lane.sh
        # shellcheck disable=SC2317 # called by fast_lane_reexec
        fast_lane_gid() { echo "$lane_gid"; }
        SCRIPT_SH=/bin/sh fast_lane_reexec generate/create_custom_iso.sh --a "b c"
        echo stayed
    ) 2>"$TMP/err" | tail -n1
}
hide_calls() { wc -l <"$HIDE_LOG" | tr -d ' '; }
said() { grep -q -- "$1" "$TMP/err" && echo yes || echo no; }

on='GLOBAL=on
FAST_APPS=on'
check "global mode, lane open: re-executed on it" \
    "$(lane "$on" other)" \
    "LAUNCHED fast run env B2B_FAST_LANE=0 nice -n 0 /bin/sh $PWD/generate/create_custom_iso.sh --a b c"
check "  probed first, then launched" "$(hide_calls)" 2
check "  says it runs direct" "$(said 'runs direct')" yes
check "a GLOBAL line hide cannot read counts as on" \
    "$(lane 'FAST_APPS="on"' other | cut -d' ' -f1)" LAUNCHED

check "B2B_FAST_LANE=0: stays, silently" "$(lane "$on" other B2B_FAST_LANE=0)" stayed
check "  hide never called" "$(hide_calls)" 0
check "  nothing said" "$(wc -c <"$TMP/err" | tr -d ' ')" 0
check "B2B_FAST_LANE=off (a typo): stays on Tor" "$(lane "$on" other B2B_FAST_LANE=off)" stayed
check "  and says why" "$(said 'neither 0 nor 1')" yes
check "  hide never called" "$(hide_calls)" 0

check "GLOBAL=off: nothing to leave, stays" "$(lane 'GLOBAL=off
FAST_APPS=on' other)" stayed
check "  hide never called" "$(hide_calls)" 0
check "already on the lane: stays" "$(lane "$on" mine)" stayed
check "  hide never called" "$(hide_calls)" 0

check "lane closed: stays on Tor" "$(lane 'GLOBAL=on
FAST_APPS=off' other)" stayed
check "  never opens it (no hide fast run, no sudo)" "$(hide_calls)" 0
check "  names the way to open it" "$(said 'hide fast on')" yes
check "lane refuses: stays on Tor" "$(lane "$on" other HIDE_PROBE=1)" stayed
check "  only the probe ran" "$(cat "$HIDE_LOG")" "fast run true"
check "  says so" "$(said 'failed')" yes

rm -f "$B2B_HIDE_CONF"
: >"$HIDE_LOG"
no_conf=$(
    unset B2B_FAST_LANE
    . utils/fast_lane.sh
    fast_lane_reexec generate/create_custom_iso.sh
    echo stayed
)
check "no hide.conf: stays" "$no_conf" stayed
check "  hide never called" "$(hide_calls)" 0

# ── fast_lane_wait: an outside daemon is waited out, within a bound ─────────
cp "$(command -v sleep)" "$TMP/bin/b2bfakesvc"
wait_for() { # <seconds the daemon lives> <bound> -> seconds waited + note?
    # Not this shell's child, like a real VBoxSVC: hellish 3.1.3 does not reap
    # a finished background job while a subshell runs, and pgrep still names
    # the zombie it leaves.
    ("$TMP/bin/b2bfakesvc" "$1" &)
    local start=$SECONDS
    (
        . utils/fast_lane.sh
        # shellcheck disable=SC2317 # called by fast_lane_wait
        fast_lane_gid() { id -g; }
        # shellcheck disable=SC2317 # stands in for the daemon's /proc group
        stat() { echo 4242; }
        fast_lane_wait b2bfakesvc "$2"
    ) 2>"$TMP/err"
    echo "$((SECONDS - start)) $(said 'still runs outside')"
    pkill -x b2bfakesvc 2>/dev/null
}
check "a daemon outside the lane is waited out" "$(wait_for 1 5 | awk '{print ($1 <= 3) " " $2}')" "1 no"
check "one that stays is reported after the bound" "$(wait_for 30 2 | awk '{print ($1 >= 2 && $1 <= 4) " " $2}')" "1 yes"

exit "$fail"
