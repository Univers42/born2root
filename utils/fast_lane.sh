#!/usr/bin/env hellish
# Moves a host script onto hide's fast lane when the host sends everything
# through Tor, so what it downloads arrives at the line's speed.
#
# hide (/usr/local/bin/hide, a Tor tool some hosts run) with GLOBAL=on
# redirects every TCP connection the host opens to Tor: the user's, root's,
# Docker's, and QEMU's, since slirp NAT is the qemu process opening host
# sockets for the guest. Measured 2026-10-06: the netinst ISO came at 390 KB/s
# through Tor and at 6 MB/s on the lane, and a first boot (apt, the grobase
# images, vim.pack) is the same traffic again. A process whose primary group
# is hide-fast goes direct, and `hide fast run` starts one there without a
# password once `hide fast on` has opened the lane for apps (FAST_APPS=on).
#
# fast_lane_reexec <script> [args...] re-executes the script on the lane and
# returns only when it stays where it is: no hide, hide not in global mode,
# already on the lane, B2B_FAST_LANE=0 (the opt-out, which the re-executed
# copy also carries), or a lane that is closed or refuses. Opening the lane is
# the user's privacy decision, so a closed one gets a note, never a sudo.
# B2B_HIDE_CONF points at another hide.conf (the tests use it).
#
# Caveat: the lane covers this process and what it starts. A daemon that was
# already running keeps its own group: the host's dockerd (its pulls stay on
# Tor), and VirtualBox's VBoxSVC, which starts every VM process. fast_lane_wait
# waits out a VBoxSVC left by an earlier VBoxManage call, but an open
# VirtualBox window keeps it alive. Name lookups still go through Tor's DNS:
# latency per name, not throughput.

# <KEY> -> its value in hide's config, read the way hide itself reads it.
fast_lane_conf() {
    sed -n "s/^$1=//p" "${B2B_HIDE_CONF:-/etc/hide/hide.conf}" 2>/dev/null | tail -n1 | tr -d '"'
}

fast_lane_gid() { getent group hide-fast | cut -d: -f3; }

fast_lane_reexec() {
    local gid script
    case "${B2B_FAST_LANE:-1}" in
    0) return 0 ;;
    1) ;;
    *)
        # A typo must not take traffic off Tor.
        echo "fast lane: B2B_FAST_LANE=$B2B_FAST_LANE is neither 0 nor 1, so this stays on Tor" >&2
        return 0
        ;;
    esac
    command -v hide >/dev/null 2>&1 || return 0
    [ -r "${B2B_HIDE_CONF:-/etc/hide/hide.conf}" ] || return 0
    # hide's own rule: anything but an explicit "off" is global mode.
    [ "$(fast_lane_conf GLOBAL)" != off ] || return 0
    gid=$(fast_lane_gid)
    [ -n "$gid" ] || return 0
    [ "$(id -g)" != "$gid" ] || return 0
    if [ "$(fast_lane_conf FAST_APPS)" != on ]; then
        echo "fast lane: closed, so this goes through Tor (open it: hide fast on; or B2B_FAST_LANE=0)" >&2
        return 0
    fi
    if ! hide fast run true </dev/null >/dev/null 2>&1; then
        echo "fast lane: 'hide fast run' failed, so this goes through Tor (B2B_FAST_LANE=0 skips the attempt)" >&2
        return 0
    fi
    script=$(readlink -f "$1")
    shift
    echo "fast lane: $(basename "$script") runs direct, not through Tor (B2B_FAST_LANE=0 keeps it on Tor)" >&2
    # `nice -n 0` changes nothing but the launch's name: hide names it after
    # the first word that is neither env nor VAR=value and warns when a process
    # of that name runs outside the lane, which the interpreter always does.
    exec hide fast run env B2B_FAST_LANE=0 nice -n 0 "${SCRIPT_SH:-bash}" "$script" "$@"
}

# <name> <seconds>: on the lane, wait until no process of this user called
# <name> runs outside it. A VBoxSVC spawned by any VBoxManage call lives 5-10 s
# past its last client (measured 2026-10-06), and make's own checks make one
# seconds before the VM starts; the next VBoxManage call after it exits spawns
# one on the lane, and the VM inherits that one's group.
fast_lane_wait() {
    local gid p pid waited=0
    gid=$(fast_lane_gid)
    [ -n "$gid" ] || return 0
    [ "$(id -g)" = "$gid" ] || return 0
    while :; do
        pid=""
        for p in $(pgrep -u "$(id -u)" -x "$1" 2>/dev/null); do
            [ "$(stat -c %g "/proc/$p" 2>/dev/null)" = "$gid" ] || pid=$p
        done
        [ -n "$pid" ] || return 0
        if [ "$waited" -ge "$2" ]; then
            echo "fast lane: $1 (pid $pid) still runs outside the lane after ${2}s, so what it starts goes through Tor (quit it and run again)" >&2
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
}
