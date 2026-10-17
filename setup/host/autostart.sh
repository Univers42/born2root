#!/usr/bin/env hellish
# autostart.sh — this VM kept up as a service of the host login, its backup
# pulled off the guest every hour, without root. `make autostart`; `make all`
# runs it when the profile says [host] autostart = true.
#
# TWO MODES, CHOSEN BY LINGER (loginctl show-user $USER -p Linger)
#   Linger on: systemd user units, in ~/.config/systemd/user (or
#   $XDG_CONFIG_HOME/systemd/user):
#     b2b-vm-<vm>.service      make qemu_start / make qemu_stop GRACEFUL=1, with
#                              this checkout's B2B_CONFIG, VM_PATH and VM_NAME.
#                              The unit baas ran by hand until 2026-10-13. It
#                              never creates a VM, and a running VM is left
#                              alone (qemu_vm.sh start says "already running").
#     b2b-backup-<vm>.service  make backup, the same three values
#     b2b-backup-<vm>.timer    hourly at :15; the guest's own snapshot runs at :03
#   The VM unit is enabled, not started: starting it now would boot a stopped
#   VM. The timer is enabled and started.
#
#   Linger off: a block in the user's crontab, between
#   "# b2b-autostart <vm> begin" and "# b2b-autostart <vm> end":
#     every minute   autostart.sh --tick: make qemu_start when the VM is not
#                    running, not held (below) and /dev/kvm is writable; when
#                    it runs, the shutdown guard (--guard, at guard()) is kept
#                    running, its log in $VM_PATH/$VM_NAME/shutdown-guard.log,
#                    and, for a disk on a sec=krb5 NFS mount, the ticket
#                    keeper (utils/ticket_keeper.sh, ticket-keeper.log)
#     hourly at :15  make backup, under flock and a 50-minute timeout
#   A crontab lives in the seat's /var/spool/cron while the home follows the
#   user from seat to seat: on 2026-10-16 c2r19s6 had no crontab at all, the
#   block having been written on c2r19s5, so nothing started baas there. Cron
#   mode therefore also writes a login entry,
#   ~/.config/autostart/b2b-autostart-<vm>.desktop, that reruns this script
#   (it changes nothing where the block is already in place) at every
#   desktop login, on whichever seat (utils/login_entry.sh).
#   Turning linger on needs root, and the 42 seats give none. Without linger
#   the user's systemd manager, and every process under it, stops at logout:
#   a VM started from a terminal there dies with the session. cron runs its
#   jobs in cron.service's cgroup, so a VM started by the tick outlives the
#   logout. The units are disabled in this mode, so they cannot fight it.
#
# A FILE OR A CRONTAB THAT WOULD NOT CHANGE IS NOT REWRITTEN, so a second run
# changes nothing. The rest of the user's crontab is kept as it was.
#
# THE HOLD
#   qemu_vm.sh stop, kill and install leave this boot's id in
#   $VM_PATH/$VM_NAME/.autostart-hold and start clears it, so `make qemu_stop`
#   keeps the VM down until the host boots again. The tick's own output goes to
#   $VM_PATH/$VM_NAME/autostart.log, written only when it starts the VM.
#
# --handover moves a VM running inside the login session (a user@ cgroup)
# under cron: a graceful stop, then the tick starts it again. `make
# autostart_handover`. Expect a minute or two of downtime.
#
# Caveat: in cron mode a host shutdown gives the guest a head start, not a
# graceful stop: the guard powers it off when logind announces the shutdown,
# and whatever is still running at systemd-shutdown's final SIGTERM loses
# power (a real shutdown hook needs root; guard() says what it covers).
# /dev/kvm is the user's only while they have the seat's active session (a
# uaccess ACL), so after a host reboot the VM starts within a minute of that
# login, not at boot; the tick never starts it under TCG instead. A campus
# logout script that kills every process of the user kills the VM too; the
# next login starts it again. The tick also restarts a guest that powered
# itself off: stop it with `make qemu_stop` to keep it down.
#
# Rollback: systemctl --user disable --now b2b-backup-<vm>.timer
#           systemctl --user disable b2b-vm-<vm>.service
#           crontab -e, then delete the b2b-autostart <vm> block
#           rm ~/.config/autostart/b2b-autostart-<vm>.desktop
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
ok() { printf '✓ %s\n' "$*"; }
warn() { printf '! %s\n' "$*"; }
die() {
    printf '✗ %s\n' "$*" >&2
    exit 1
}

VM_NAME="${VM_NAME:-}"
VM_PATH="${VM_PATH:-}"
CONFIG="${B2B_CONFIG:-born2root.toml}"
if [ -z "$VM_NAME" ] || [ -z "$VM_PATH" ]; then
    die "VM_NAME and VM_PATH are required (make autostart sets both)"
fi
MAKE_PATH=$(command -v make) || die "no make on PATH"
SH=$(command -v "${SCRIPT_SH:-bash}") || die "no ${SCRIPT_SH:-bash} on PATH"
# systemd splits a command line at whitespace and expands %, and cron turns a
# % into a newline, so a value that carries either would start some other
# command than the one written here.
for value in "$ROOT" "$CONFIG" "$VM_PATH" "$VM_NAME" "$MAKE_PATH" "$SH"; do
    case "$value" in
    *[[:space:]%]*) die "'$value' holds a space or a %: a systemd unit or a crontab line cannot carry it as written; move it or rename it" ;;
    esac
done
MAKE_ARGS=("B2B_CONFIG=$CONFIG" "VM_PATH=$VM_PATH" "VM_NAME=$VM_NAME")
ARGS="${MAKE_ARGS[*]}"
UNITS="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
VM_UNIT="b2b-vm-$VM_NAME.service"
BACKUP="b2b-backup-$VM_NAME"
VM_DIR="$VM_PATH/$VM_NAME"
HOLD="$VM_DIR/.autostart-hold"
LOCK="$VM_DIR/.autostart.lock"
LOG="$VM_DIR/autostart.log"
GUARD_LOCK="$VM_DIR/.shutdown-guard.lock"
GUARD_LOG="$VM_DIR/shutdown-guard.log"
KEEPER_LOG="$VM_DIR/ticket-keeper.log"
CRON_BEGIN="# b2b-autostart $VM_NAME begin (make autostart writes this block)"
CRON_END="# b2b-autostart $VM_NAME end"
LOGIN_ENTRY="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/b2b-autostart-$VM_NAME.desktop"
# shellcheck source=utils/login_entry.sh
. "$ROOT/utils/login_entry.sh"

# The pid of this VM's QEMU, the way qemu_vm.sh finds it: the pidfile, and a
# live process that was given that very pidfile -- a pid the kernel reused
# for something else after a crash is not the VM.
vm_pid() {
    local p
    p=$(head -n1 "$VM_DIR/qemu.pid" 2>/dev/null) || return 1
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null || return 1
    tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null | grep -qF -- "$VM_DIR/qemu.pid" || return 1
    printf '%s' "$p"
}

# One cron minute. Silent unless it starts the VM: cron appends this to $LOG.
tick() {
    local hold
    hold=$(cat "$HOLD" 2>/dev/null)
    if [ -n "$hold" ] && [ "$hold" = "$(cat "${B2B_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}" 2>/dev/null)" ]; then
        return 0
    fi
    local pid
    if pid=$(vm_pid); then
        start_guard
        start_ticket_keeper "$pid"
        return 0
    fi
    # Without the seat's session /dev/kvm is not ours, and qemu_vm.sh would
    # fall back to TCG: a guest some ten times slower. Wait for the login.
    [ -r "${B2B_KVM_DEV:-/dev/kvm}" ] && [ -w "${B2B_KVM_DEV:-/dev/kvm}" ] || return 0
    printf '== %s: %s is not running: make qemu_start\n' "$(date '+%F %T')" "$VM_NAME"
    "$MAKE_PATH" -C "$ROOT" --no-print-directory qemu_start "${MAKE_ARGS[@]}"
    printf '== exit %s\n' "$?"
}

# A VM inside the login session dies at logout: stop it gracefully, release
# the hold and let the tick start it again, under cron.
handover() {
    local pid
    if ! pid=$(vm_pid); then
        rm -f "$HOLD"
        ok "$VM_NAME is not running: the cron tick starts it within a minute (log: $LOG)"
        return 0
    fi
    case "$(cat "/proc/$pid/cgroup" 2>/dev/null)" in
    */user@*) ;;
    *)
        ok "$VM_NAME (pid $pid) already runs outside the login session"
        return 0
        ;;
    esac
    crontab -l 2>/dev/null | grep -qxF "$CRON_BEGIN" ||
        die "no cron block for $VM_NAME: run make autostart first"
    printf '  %s (pid %s) runs inside the login session: a graceful stop, then cron starts it\n' "$VM_NAME" "$pid"
    if systemctl --user is-active --quiet "$VM_UNIT" 2>/dev/null; then
        systemctl --user stop "$VM_UNIT" || die "systemctl --user stop $VM_UNIT failed"
    else
        "$MAKE_PATH" -C "$ROOT" --no-print-directory qemu_stop GRACEFUL=1 STOP_GRACE=120 "${MAKE_ARGS[@]}" ||
            die "the VM did not stop; nothing was handed over"
    fi
    rm -f "$HOLD"
    local waited=0
    until pid=$(vm_pid); do
        [ "$waited" -lt 180 ] || die "cron did not start $VM_NAME within 3 minutes (crontab -l; $LOG); start it by hand: make qemu_start $ARGS"
        sleep 5
        waited=$((waited + 5))
    done
    # The tick holds the lock until its qemu_start, LUKS unlock included, returns.
    flock -w 900 "$LOCK" true
    case "$(tail -n1 "$LOG" 2>/dev/null)" in
    "== exit 0") ok "$VM_NAME runs under cron now (pid $pid)" ;;
    *) die "cron started $VM_NAME (pid $pid) but qemu_start did not finish cleanly: $LOG" ;;
    esac
}

# A host shutdown, in cron mode. logind broadcasts PrepareForShutdown(true)
# on the system bus before it stops anything, and any user may listen: the
# guard asks the guest for an ACPI power-off then, while the host still stops
# its own units. Without it QEMU lives on in cron's cgroup until
# systemd-shutdown's final SIGTERM, which ends it without the guest knowing.
# A delay lock would hold the shutdown up to logind's InhibitDelayMaxSec (5 s)
# for that; the guard takes one wherever polkit grants it, but the 42 seats
# want authentication for inhibit-delay-shutdown (a root-only .pkla, measured
# 2026-10-14). A user unit's ExecStop would not do better there either:
# user@.service gets TimeoutStopSec=5s on these seats.
#
# Caveat: the guest's head start is however long the host takes to stop its
# units after the signal -- unmeasured (the system journal needs adm) -- and a
# guest that needs longer still loses power mid-shutdown. reboot -f, a held
# power button or a power cut sends no signal at all. The stop leaves the hold,
# so a shutdown announced and then aborted keeps the guest down until the next
# boot: make qemu_start.
login1_signals() {
    local who="born2root $VM_NAME"
    local monitor=(gdbus monitor --system --dest org.freedesktop.login1 --object-path /org/freedesktop/login1)
    if systemd-inhibit --what=shutdown --mode=delay --who="$who" --why=probe true 2>/dev/null; then
        printf '   with a delay lock\n' >&2
        exec systemd-inhibit --what=shutdown --mode=delay --who="$who" \
            --why="powering the guest off before the host" "${monitor[@]}"
    fi
    printf '   no delay lock (polkit refused inhibit-delay-shutdown)\n' >&2
    exec "${monitor[@]}"
}

guard() {
    local line
    printf '== %s: guarding %s against a host shutdown\n' "$(date '+%F %T')" "$VM_NAME"
    login1_signals | while IFS= read -r line; do
        case "$line" in
        *"PrepareForShutdown (true"*)
            vm_pid >/dev/null || continue
            printf '== %s: the host is shutting down: make qemu_stop GRACEFUL=1\n' "$(date '+%F %T')"
            # After a logout the home, and the repo in it, is gone: the
            # monitor's power button is all that is left to press.
            if [ -f "$ROOT/Makefile" ]; then
                "$MAKE_PATH" -C "$ROOT" --no-print-directory qemu_stop GRACEFUL=1 STOP_GRACE=120 "${MAKE_ARGS[@]}"
            else
                printf 'system_powerdown\n' | socat - "UNIX-CONNECT:$VM_DIR/monitor.sock"
            fi
            printf '== exit %s\n' "$?"
            ;;
        esac
    done
    printf '== %s: the system bus monitor ended; the next tick starts a guard\n' "$(date '+%F %T')"
}

# One guard per VM: the tick starts it, flock -n makes every later start a
# no-op, and a guard whose monitor died is replaced within a minute. Started
# from /, like the keeper: cron runs the tick inside the repo, and a helper
# left there holds the home that the logout unmounts.
start_guard() {
    command -v gdbus >/dev/null 2>&1 || return 0
    (cd / && setsid -f flock -n -o "$GUARD_LOCK" "$SH" "$ROOT/setup/host/autostart.sh" --guard \
        </dev/null >>"$GUARD_LOG" 2>&1)
}

# A disk on a sec=krb5 NFS mount needs the login's ticket, which nothing
# renews after the logout: utils/ticket_keeper.sh says why and what it does.
# It runs from its text, under /bin/sh, so it needs nothing from the home;
# its lock lives beside the VM, as the logout deletes the user's /tmp files.
start_ticket_keeper() {
    local keep
    case "$(findmnt -no FSTYPE,OPTIONS -T "$VM_DIR" 2>/dev/null)" in
    nfs*sec=krb5*) ;;
    *) return 0 ;;
    esac
    command -v kinit >/dev/null 2>&1 && command -v klist >/dev/null 2>&1 || return 0
    keep="${B2B_KEEPER_TMP:-/tmp}/krb5cc_$(id -u)_b2b-$VM_NAME"
    (cd / && setsid -f flock -n -o "$VM_DIR/.ticket-keeper.lock" /bin/sh -c "$(cat "$ROOT/utils/ticket_keeper.sh")" \
        ticket_keeper "$keep" "$VM_DIR/monitor.sock" "$1" </dev/null >>"$KEEPER_LOG" 2>&1)
}

case "${1:-}" in
--tick)
    tick
    exit 0
    ;;
--guard)
    guard
    exit 0
    ;;
--handover)
    handover
    exit
    ;;
'') ;;
*) die "usage: autostart.sh [--tick | --guard | --handover]" ;;
esac

changed=0
# put_unit NAME: stdin as $UNITS/NAME, unless it already says exactly that.
put_unit() {
    local tmp
    tmp=$(mktemp "$UNITS/.$1.XXXXXX") || die "cannot write in $UNITS"
    cat >"$tmp"
    if cmp -s "$tmp" "$UNITS/$1"; then
        rm -f "$tmp"
        printf '  %s unchanged\n' "$1"
    else
        mv "$tmp" "$UNITS/$1" || die "cannot write $UNITS/$1"
        changed=1
        printf '  %s written\n' "$1"
    fi
}

# put_crontab BLOCK: the user's crontab with this VM's block replaced by
# BLOCK, or removed when BLOCK is empty; every other line kept.
put_crontab() {
    local current others new
    command -v crontab >/dev/null 2>&1 || {
        warn "no crontab command on this host: cron mode cannot be installed"
        return 1
    }
    current=$(crontab -l 2>/dev/null) || current=
    others=$(printf '%s\n' "$current" |
        awk -v b="$CRON_BEGIN" -v e="$CRON_END" '$0 == b { skip = 1; next } $0 == e { skip = 0; next } !skip')
    new=$(printf '%s\n%s\n' "$others" "$1" | sed '/./,$!d')
    if [ "$new" = "$current" ]; then
        [ -z "$1" ] || printf '  crontab unchanged\n'
        return 0
    fi
    printf '%s\n' "$new" | crontab - || {
        warn "crontab refused the new table (is cron allowed for $(id -un)? /etc/cron.allow, /etc/cron.deny)"
        return 1
    }
    if [ -n "$1" ]; then
        printf '  crontab written (b2b-autostart %s)\n' "$VM_NAME"
    else
        printf '  crontab: the b2b-autostart %s block removed (linger does its job now)\n' "$VM_NAME"
    fi
}

install_units() {
    mkdir -p "$UNITS" || die "cannot create $UNITS"
    # Caveat: TimeoutStartSec=900 is a first boot's LUKS unlock and disk check
    # with room to spare, and TimeoutStopSec=200 is STOP_GRACE=120 plus
    # qemu_vm.sh's own wait. A guest slower than that is killed by systemd: at
    # start the VM is left half-booted, at stop the engines lose power. Raise
    # both here, together with STOP_GRACE, for a slower guest.
    put_unit "$VM_UNIT" <<EOF
# $VM_UNIT -- the born2root VM "$VM_NAME", started when this host boots and
# stopped gracefully when it shuts down. Written by setup/host/autostart.sh
# (make autostart); edit the profile and rerun it rather than this file.
[Unit]
Description=born2root VM $VM_NAME

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$ROOT
ExecStart=$MAKE_PATH qemu_start $ARGS
ExecStop=$MAKE_PATH qemu_stop GRACEFUL=1 STOP_GRACE=120 $ARGS
TimeoutStartSec=900
TimeoutStopSec=200

[Install]
WantedBy=default.target
EOF

    # Caveat: TimeoutStartSec=3000 lets an hour's rsync finish before the
    # next :15; a pull slower than 50 min is killed and the next one resumes it.
    put_unit "$BACKUP.service" <<EOF
# $BACKUP.service -- pull the VM "$VM_NAME"'s restic repository to the host
# (make backup). Run by $BACKUP.timer. Written by setup/host/autostart.sh.
[Unit]
Description=born2root VM $VM_NAME: pull its backup to the host

[Service]
Type=oneshot
WorkingDirectory=$ROOT
ExecStart=$MAKE_PATH backup $ARGS
TimeoutStartSec=3000
EOF

    put_unit "$BACKUP.timer" <<EOF
# $BACKUP.timer -- hourly at :15, twelve minutes after the guest's own
# snapshot at :03. Not Persistent: a pull missed while the host was off
# would fire at boot, while the VM is still starting. Written by
# setup/host/autostart.sh.
[Unit]
Description=born2root VM $VM_NAME: hourly backup pull

[Timer]
OnCalendar=*-*-* *:15:00

[Install]
WantedBy=timers.target
EOF

    if ! systemctl --user show-environment >/dev/null 2>&1; then
        warn "no systemd user manager answers here; the units are written. Run, in a login session:"
        printf '    systemctl --user daemon-reload && systemctl --user enable %s && systemctl --user enable --now %s.timer\n' "$VM_UNIT" "$BACKUP"
        return 1
    fi
    local rc=0
    if [ "$changed" = 1 ]; then
        systemctl --user daemon-reload || rc=1
    fi
    systemctl --user enable "$VM_UNIT" >/dev/null 2>&1 || rc=1
    systemctl --user enable --now "$BACKUP.timer" >/dev/null 2>&1 || rc=1
    if [ "$rc" = 0 ]; then
        ok "$VM_UNIT enabled (starts at boot), $BACKUP.timer running"
    else
        warn "systemctl --user refused to enable the units (systemctl --user status $VM_UNIT)"
    fi
    return "$rc"
}

# Units left enabled from a linger-on run (or written by hand) would race the
# cron block, and the VM unit's ExecStop would stop a VM cron started.
retire_units() {
    systemctl --user show-environment >/dev/null 2>&1 || return 0
    if systemctl --user is-enabled --quiet "$BACKUP.timer" 2>/dev/null; then
        systemctl --user disable --now "$BACKUP.timer" >/dev/null 2>&1 &&
            printf '  %s.timer disabled (cron pulls the backup now)\n' "$BACKUP"
    fi
    if systemctl --user is-enabled --quiet "$VM_UNIT" 2>/dev/null; then
        systemctl --user disable "$VM_UNIT" >/dev/null 2>&1 &&
            printf '  %s disabled (cron starts the VM now)\n' "$VM_UNIT"
    fi
    if systemctl --user is-active --quiet "$VM_UNIT" 2>/dev/null; then
        warn "$VM_UNIT is active: at logout its ExecStop stops the VM. Hand the VM over to cron:"
        printf '    make autostart_handover %s\n' "$ARGS"
    fi
}

# flock -o: the lock fd is closed in what flock runs, while flock itself holds
# the lock until that returns. Without it QEMU, or an ssh master `make backup`
# leaves behind, inherits the fd and holds the lock for good, and every later
# tick or pull is skipped without a word.
cron_block() {
    local cron_path
    cron_path="$(dirname "$SH"):$(dirname "$MAKE_PATH"):/usr/local/bin:/usr/bin:/bin"
    printf '%s\n' "$CRON_BEGIN" \
        "* * * * * cd $ROOT && flock -n -o $LOCK env PATH=$cron_path $ARGS $SH setup/host/autostart.sh --tick >>$LOG 2>&1" \
        "15 * * * * cd $ROOT && flock -n -o $VM_DIR/.backup.lock timeout 3000 env PATH=$cron_path $MAKE_PATH backup $ARGS >$VM_DIR/backup.log 2>&1" \
        "$CRON_END"
}

status=0
user=$(id -un)
if [ "$(loginctl show-user "$user" -p Linger --value 2>/dev/null)" = yes ]; then
    install_units || status=1
    put_crontab "" || status=1
    rm -f "$LOGIN_ENTRY"
    case " $(id -nG) " in
    *" kvm "*) ;;
    *)
        warn "$user is not in the kvm group: at boot, with no seat session, QEMU cannot open /dev/kvm. Ask for it (needs root; not run here):"
        printf '    sudo usermod -aG kvm %s\n' "$user"
        ;;
    esac
    printf '  a VM running now is adopted (qemu_start says "already running"), so this shutdown stops it gracefully too:\n'
    printf '    systemctl --user start %s\n' "$VM_UNIT"
    exit "$status"
fi

retire_units
put_crontab "$(cron_block)" || exit 1
# A login runs from $HOME, not the checkout: the profile path goes absolute.
case "$CONFIG" in /*) entry_config=$CONFIG ;; *) entry_config=$ROOT/$CONFIG ;; esac
login_entry_write "$LOGIN_ENTRY" "born2root autostart $VM_NAME" \
    "Puts the b2b-autostart $VM_NAME crontab block on this seat at login. Written by $ROOT/setup/host/autostart.sh (make autostart)" \
    env "B2B_CONFIG=$entry_config" "VM_PATH=$VM_PATH" "VM_NAME=$VM_NAME" "$SH" "$ROOT/setup/host/autostart.sh" ||
    die "cannot write the login entry $LOGIN_ENTRY"
printf '  login entry: %s (every seat you log into gets the block)\n' "$LOGIN_ENTRY"
ok "cron keeps $VM_NAME up (linger is off, and turning it on needs root): it starts within a minute of your login at this seat, outlives the logout, and make backup runs hourly at :15"
printf '  a host shutdown asks the guest to power off first (a head start, not a full graceful stop, without root); make qemu_stop keeps it down until the next boot\n'
pid=$(vm_pid) || pid=
case "$(cat "/proc/$pid/cgroup" 2>/dev/null)" in
*/user@*)
    warn "$VM_NAME (pid $pid) runs inside this login session and dies at logout. Hand it over to cron (a graceful restart):"
    printf '    make autostart_handover %s\n' "$ARGS"
    ;;
esac
exit 0
