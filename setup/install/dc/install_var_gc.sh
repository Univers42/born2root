#!/usr/bin/env hellish
#
# install_var_gc.sh — keeps /var and /var/log below 90% on every build
# (var-gc), and the one command it will never run; and, the other half of
# keeping a container host alive, restarts any container left unhealthy.
#
# WHY
#   Docker lives on /var, the `rest` volume, and /var is what fills: the 44 GB
#   guest of 2026-09-19 stood at 91% with 6.3 GB of images nothing ran any
#   more and 1.7 GB of build cache. A daily pass alone does not hold the line:
#   one `make grobase` pulls 3 GB in minutes, and a full /var stops postgres
#   writing its WAL long before a nightly timer fires. So this is base tier,
#   installed by first boot BEFORE docker (every container the guest ever
#   creates then gets the log caps below), with two timers:
#     b2b-var-gc.timer        daily, the regular pass
#     b2b-var-gc-watch.timer  every 10 min, `b2b-var-gc --if-full`: nothing
#                             below 90%; at 90% on /var or /var/log, the
#                             regular pass, then a deeper one if still needed
#   Caveat: it polls. A pull that takes /var from 89% to 100% inside one
#   10-minute interval is cleaned after it has already failed; rerun the pull.
#
# WHAT IS RECLAIMED, AND WHY IT IS SAFE
#   Only what is regenerable from somewhere else:
#     docker builder prune        build cache > 7 days   (all of it at 90%)
#     docker image prune          DANGLING layers only   (untagged; `-a` never)
#     docker container prune      exited > 24 h          (> 1 h at 90%)
#     journalctl --vacuum         7 days, 200 MB         (100 MB at 90%)
#     apt-get clean               package cache          (re-downloaded)
#     rotated logs                *.gz *.1 *.old, at 90% only, never /var/log/sudo
#     fstrim                      freed blocks           (returns them to the host)
#   plus a daemon.json that caps EVERY container's json-file log at
#   3 x 10 MB, the one setting that stops a chatty service from eating /var
#   between two runs of the timer. Still at 90% after all of it, the cleaner
#   exits 1 (`systemctl --failed`) and writes what holds the space to the
#   journal: what is left is data, and deleting data is a person's decision.
#
# WHAT IS NEVER RECLAIMED
#   `docker system prune -a --volumes` and `docker volume prune`. Named
#   volumes are the engines' data -- the seven databases, MinIO -- and a
#   volume looks "unused" the moment its stack is stopped, which is exactly
#   when a nightly cron would find it. That is how people delete their
#   databases with a timer. The cleaner refuses both flags outright, with a
#   message, and tests/test_var_gc_guard.sh pins the refusal. Tagged images
#   stay too: re-pulling grobase's 35 of them is the slowest step of a build.
#
# USAGE
#   sudo ./install_var_gc.sh          install the cleaner, its timers, the log caps, run once
#   sudo b2b-var-gc                   run it now
#   sudo b2b-var-gc --if-full         what the watch timer runs
#   sudo b2b-autoheal                 restart every unhealthy container now
#   b2b-stack-health [seconds]        the verdict: exit 1 naming each failing container
set -u

log() { printf '[var-gc] %s\n' "$*"; }
die() {
    printf '[var-gc] ERROR: %s\n' "$*" >&2
    exit 1
}
[ "$(id -u)" = 0 ] || die "run as root"

# ── log caps at the daemon ──────────────────────────────────────────────────
# Written only when there is no daemon.json yet: merging into someone's
# hand-edited file blindly is how a working daemon stops starting.
DJ=/etc/docker/daemon.json
if [ ! -s "$DJ" ]; then
    install -d -m 0755 /etc/docker
    cat >"$DJ" <<'JSONEOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
JSONEOF
    log "daemon.json: json-file logs capped at 3 x 10 MB per container"
    if systemctl is-active --quiet docker 2>/dev/null; then
        systemctl restart docker || log "docker did not restart cleanly; the caps apply from the next start"
    fi
elif grep -q '"log-opts"' "$DJ"; then
    log "daemon.json already has log-opts; left alone"
else
    log "WARN: $DJ exists without log-opts -- add max-size/max-file yourself; not merging into a hand-edited file"
fi

# ── the cleaner ─────────────────────────────────────────────────────────────
cat >/usr/local/sbin/b2b-var-gc <<'GCEOF'
#!/bin/sh
# b2b-var-gc [--if-full] — reclaim what is regenerable on /var. Installed by
# setup/install/dc/install_var_gc.sh (born2root); read its header for what
# is and is not touched here, and why.
set -u
THRESHOLD=90
if_full=0
for a in "$@"; do
    case "$a" in
    --volumes | --all | -a | volume*)
        printf 'b2b-var-gc: refusing %s -- named volumes are the databases.\n' "$a" >&2
        printf 'b2b-var-gc: a stopped stack'"'"'s volumes look unused; delete one by name, by hand:\n' >&2
        printf 'b2b-var-gc:   docker volume rm <name>\n' >&2
        exit 2
        ;;
    --if-full) if_full=1 ;;
    *)
        printf 'b2b-var-gc: unknown option %s (usage: b2b-var-gc [--if-full])\n' "$a" >&2
        exit 2
        ;;
    esac
done
# The fuller of /var and /var/log, in percent: a full /var/log stops sudo's
# logging as surely as a full /var stops postgres.
fullest() { df -P /var /var/log 2>/dev/null | awk 'NR > 1 { p = $5 + 0; if (p > m) m = p } END { print m + 0 }'; }
used_mb() { df -Pm /var 2>/dev/null | awk 'NR == 2 { print $3 + 0 }'; }
if [ "$if_full" = 1 ] && [ "$(fullest)" -lt "$THRESHOLD" ]; then
    exit 0
fi
before=$(used_mb)
docker_up=0
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker_up=1
    docker builder prune -f --filter until=168h >/dev/null 2>&1 || true
    docker image prune -f >/dev/null 2>&1 || true
    docker container prune -f --filter until=24h >/dev/null 2>&1 || true
fi
journalctl --vacuum-time=7d --vacuum-size=200M >/dev/null 2>&1 || true
apt-get clean >/dev/null 2>&1 || true
deep=""
if [ "$(fullest)" -ge "$THRESHOLD" ]; then
    deep=", deep pass at ${THRESHOLD}%"
    if [ "$docker_up" = 1 ]; then
        docker builder prune -af >/dev/null 2>&1 || true
        docker container prune -f --filter until=1h >/dev/null 2>&1 || true
    fi
    journalctl --vacuum-size=100M >/dev/null 2>&1 || true
    # -exec, not -delete: -delete implies -depth, and -depth voids -prune.
    find /var/log -xdev -path /var/log/sudo -prune -o -type f \
        \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' \) -exec rm -f {} + 2>/dev/null || true
fi
fstrim -a >/dev/null 2>&1 || true
after=$(used_mb)
printf 'b2b-var-gc: /var %s MB used -> %s MB (reclaimed %s MB%s); volumes untouched\n' \
    "$before" "$after" "$((before - after))" "$deep"
use=$(fullest)
if [ "$use" -ge "$THRESHOLD" ]; then
    printf 'b2b-var-gc: still %s%% full with every regenerable byte gone; what holds it is data:\n' "$use" >&2
    if [ "$docker_up" = 1 ]; then
        docker system df >&2 2>/dev/null
    fi
    du -xh -d 2 /var /var/log 2>/dev/null | sort -h | tail -n 10 >&2
    exit 1
fi
GCEOF
chmod 755 /usr/local/sbin/b2b-var-gc

cat >/etc/systemd/system/b2b-var-gc.service <<'UNITEOF'
[Unit]
Description=born2root: reclaim regenerable space on /var (never volumes)
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/b2b-var-gc
UNITEOF
cat >/etc/systemd/system/b2b-var-gc.timer <<'UNITEOF'
[Unit]
Description=born2root: daily /var garbage collection

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
UNITEOF
cat >/etc/systemd/system/b2b-var-gc-watch.service <<'UNITEOF'
[Unit]
Description=born2root: clean /var now if it or /var/log reached 90%
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/b2b-var-gc --if-full
UNITEOF
cat >/etc/systemd/system/b2b-var-gc-watch.timer <<'UNITEOF'
[Unit]
Description=born2root: check /var and /var/log every 10 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=10min

[Install]
WantedBy=timers.target
UNITEOF

# ── containers that lose a boot race ────────────────────────────────────────
# At boot dockerd starts every `restart: unless-stopped` container at once,
# with no regard for compose's depends_on, and it never acts on a healthcheck
# by itself. A service that connects a second too early and does not retry
# stays unhealthy for good: grobase's realtime (47e34af) logs "Failed to
# start producer: PostgreSQL connect failed" (cold boot of 2026-10-07: 33/34
# healthy, realtime unhealthy at +144 s, restarts=0). So once a minute every
# container docker reports unhealthy is restarted. The real fix is a retry
# in the service; this keeps the next such race from needing a person.
#
# Only a container this timer has once seen healthy, though. A container
# that never was is still in its first start, and that start may be an
# entrypoint initialising a datadir: on the 2026-10-08 max-tier first boot
# (4 GB guest, disk at 40-60% iowait) mysql's mariadb-install-db took
# minutes, the healthcheck called it unhealthy after ~70 s, autoheal
# restarted it at 13:32:09, and the restart found a half-written datadir
# (`ibdata1` page 0 all zeros) that it never re-initialises. `make up`
# failed on "mysql is unhealthy" and took all thirteen dc-* rows with it;
# mariadb's volume went the same way. Containers keep their id across a
# reboot, so the boot race this is for still qualifies. And a container is
# left alone for B2B_AUTOHEAL_GRACE seconds (300) after any start: the same
# guest had mssql, cockroach and grafana restarted every minute, each a cold
# start the healthcheck could not wait out under that load.
# Caveat: a container recreated by compose (a new id) that loses the boot
# race on its very first start is never restarted, and one unhealthy for a
# reason a restart cannot cure is restarted once per grace period; both
# show in b2b-stack-health, the loop also in journalctl -u b2b-autoheal.
cat >/usr/local/sbin/b2b-autoheal <<'HEALEOF'
#!/bin/sh
# b2b-autoheal — restart each container docker reports unhealthy that was
# healthy before and has run past its grace period. Installed by
# setup/install/dc/install_var_gc.sh (born2root); its header says why.
set -u
command -v docker >/dev/null 2>&1 || exit 0
docker info >/dev/null 2>&1 || exit 0
seen=${B2B_AUTOHEAL_STATE:-/var/lib/b2b/autoheal}
grace=${B2B_AUTOHEAL_GRACE:-300}
mkdir -p "$seen" || exit 1
for id in $(docker ps -q --filter health=healthy); do
    : >"$seen/$id"
done
all=$(docker ps -aq)
for f in "$seen"/*; do
    [ -e "$f" ] || continue
    printf '%s\n' "$all" | grep -qx "${f##*/}" || rm -f "$f"
done
now=$(date +%s)
rc=0
for id in $(docker ps -q --filter health=unhealthy); do
    [ -e "$seen/$id" ] || continue
    read -r name started_at <<EOF
$(docker inspect -f '{{.Name}} {{.State.StartedAt}}' "$id" 2>/dev/null)
EOF
    started=$(date -d "${started_at:-}" +%s 2>/dev/null) || started=0
    [ $((now - started)) -ge "$grace" ] || continue
    if docker restart "$id" >/dev/null 2>&1; then
        printf 'b2b-autoheal: restarted %s (unhealthy)\n' "${name#/}"
    else
        printf 'b2b-autoheal: could not restart %s\n' "${name#/}" >&2
        rc=1
    fi
done
exit "$rc"
HEALEOF
chmod 755 /usr/local/sbin/b2b-autoheal

# The verdict autoheal does not give: read-only, exit 1 naming every
# container that is unhealthy, crash-looping or exited non-zero. A restart
# cannot cure a service its database locks out, and a crash loop is never
# "unhealthy" to docker -- after the 2026-10-07 restore, mongo-api,
# analytics-service and ai-service restarted for good on a Mongo password
# mismatch, mongo-init had exited 1, and verify_platform still printed
# "platform verified". b2b-restore ends on this, verify_platform runs it.
# Caveat: it waits at most the seconds it is given for health checks still
# "starting", then reports those as not settled -- a service whose start
# period is longer fails a short wait it would pass later.
cat >/usr/local/sbin/b2b-stack-health <<'HEALTHEOF'
#!/bin/sh
# b2b-stack-health [seconds] — exit 1 naming each container that is
# unhealthy, restarting or exited non-zero. Installed by
# setup/install/dc/install_var_gc.sh (born2root); its comment says why.
set -u
wait_s=${1:-0}
case "$wait_s" in
'' | *[!0-9]*)
    echo "usage: b2b-stack-health [seconds to wait for health checks]" >&2
    exit 2
    ;;
esac
command -v docker >/dev/null 2>&1 || {
    echo "stack-health: no docker"
    exit 0
}
while [ "$wait_s" -gt 0 ] && [ -n "$(docker ps -q --filter health=starting)" ]; do
    sleep 5
    wait_s=$((wait_s - 5))
done
bad=$({
    docker ps --filter health=unhealthy --format '{{.Names}} unhealthy'
    docker ps --filter health=starting --format '{{.Names}} still starting (not settled)'
    docker ps -a --filter status=restarting --format '{{.Names}} restarting (crash loop)'
    docker ps -a --filter status=exited --format '{{.Names}} {{.Status}}' |
        grep -v ' Exited (0)' | sed 's/^\([^ ]*\) \(Exited ([0-9]*)\).*/\1 \2/'
} 2>/dev/null)
if [ -n "$bad" ]; then
    printf '%s\n' "$bad" | sed 's/^/stack-health: /'
    exit 1
fi
echo "stack-health: $(docker ps -q | wc -l) running, none unhealthy, restarting or exited non-zero"
HEALTHEOF
chmod 755 /usr/local/sbin/b2b-stack-health
cat >/etc/systemd/system/b2b-autoheal.service <<'UNITEOF'
[Unit]
Description=born2root: restart containers docker reports unhealthy
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/b2b-autoheal
UNITEOF
cat >/etc/systemd/system/b2b-autoheal.timer <<'UNITEOF'
[Unit]
Description=born2root: look for unhealthy containers every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
UNITEOF

systemctl daemon-reload
for t in b2b-var-gc.timer b2b-var-gc-watch.timer b2b-autoheal.timer; do
    systemctl enable --now "$t" >/dev/null 2>&1 || die "could not enable $t"
done

/usr/local/sbin/b2b-var-gc || log "WARN: /var or /var/log is still at 90% or more; see the lines above"
log "timers active: systemctl list-timers 'b2b-var-gc*' b2b-autoheal.timer"
