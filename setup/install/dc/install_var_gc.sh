#!/usr/bin/env hellish
#
# install_var_gc.sh — circular cleaning of /var (dc-var-gc), and the one
# command it will never run.
#
# WHY
#   Docker lives on /var, the `rest` volume, and /var is what fills: the 44 GB
#   guest of 2026-09-19 stood at 91% with 6.3 GB of images nothing ran any
#   more and 1.7 GB of build cache. Logs are on their own capped volume
#   (/var/log) by the partition table, so they cannot take /var down; images,
#   stopped containers and build cache can, and did.
#
# WHAT IS RECLAIMED, AND WHY IT IS SAFE
#   Only what is regenerable from somewhere else:
#     docker builder prune        build cache            (rebuilt on demand)
#     docker image prune          DANGLING layers only   (untagged; `-a` never)
#     docker container prune      exited > 24 h          (state is in volumes)
#     journalctl --vacuum         the journal            (capped anyway)
#     apt-get clean               package cache          (re-downloaded)
#     fstrim                      freed blocks           (returns them to the host)
#   plus a daemon.json that caps EVERY container's json-file log at
#   3 x 10 MB, the one setting that stops a chatty service from eating /var
#   between two runs of the timer.
#
# WHAT IS NEVER RECLAIMED
#   `docker system prune -a --volumes` and `docker volume prune`. Named
#   volumes are the engines' data -- the seven databases, MinIO -- and a
#   volume looks "unused" the moment its stack is stopped, which is exactly
#   when a nightly cron would find it. That is how people delete their
#   databases with a timer. The cleaner refuses both flags outright, with a
#   message, and tests/test_var_gc_guard.sh pins the refusal.
#
# USAGE
#   sudo ./install_var_gc.sh          install the cleaner, its timer, the log caps, run once
#   sudo b2b-var-gc                   run it now
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
# b2b-var-gc — reclaim what is regenerable on /var. Installed by
# setup/install/dc/install_var_gc.sh (born2root); read its header for what
# is and is not touched here, and why.
set -u
for a in "$@"; do
    case "$a" in
    --volumes | --all | -a | volume*)
        printf 'b2b-var-gc: refusing %s -- named volumes are the databases.\n' "$a" >&2
        printf 'b2b-var-gc: a stopped stack'"'"'s volumes look unused; delete one by name, by hand:\n' >&2
        printf 'b2b-var-gc:   docker volume rm <name>\n' >&2
        exit 2
        ;;
    esac
done
before=$(df -km /var | awk 'NR == 2 { print $3 }')
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker builder prune -f --filter until=168h >/dev/null 2>&1 || true
    docker image prune -f >/dev/null 2>&1 || true
    docker container prune -f --filter until=24h >/dev/null 2>&1 || true
fi
journalctl --vacuum-time=7d --vacuum-size=200M >/dev/null 2>&1 || true
apt-get clean >/dev/null 2>&1 || true
fstrim -a >/dev/null 2>&1 || true
after=$(df -km /var | awk 'NR == 2 { print $3 }')
printf 'b2b-var-gc: /var %s MB used -> %s MB (reclaimed %s MB); volumes untouched\n' \
    "$before" "$after" "$((before - after))"
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
systemctl daemon-reload
systemctl enable --now b2b-var-gc.timer >/dev/null 2>&1 || die "could not enable b2b-var-gc.timer"

/usr/local/sbin/b2b-var-gc
log "timer active: systemctl list-timers b2b-var-gc.timer"
