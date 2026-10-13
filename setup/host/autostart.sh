#!/usr/bin/env hellish
# autostart.sh — this VM as a service of the host login: started when the host
# boots, stopped gracefully when it shuts down, and its backup pulled off the
# guest every hour. `make autostart`; `make all` runs it when the profile says
# [host] autostart = true.
#
# WHAT IT WRITES (in ~/.config/systemd/user, or $XDG_CONFIG_HOME/systemd/user)
#   b2b-vm-<vm>.service      make qemu_start / make qemu_stop GRACEFUL=1, with
#                            this checkout's B2B_CONFIG, VM_PATH and VM_NAME.
#                            The unit baas ran by hand until 2026-10-13. It
#                            never creates a VM, and a running VM is left alone
#                            (qemu_vm.sh start says "already running").
#   b2b-backup-<vm>.service  make backup, the same three values
#   b2b-backup-<vm>.timer    hourly at :15; the guest's own snapshot runs at :03
# The VM unit is enabled, not started: starting it now would boot a stopped VM.
# The timer is enabled and started. A file that would not change is not
# rewritten, so a second run changes nothing.
#
# WHAT IT ONLY PRINTS
#   Linger: without it the user's units stop at logout and never start at
#   boot. Turning it on needs root, so the command is printed, never run.
#   The kvm group, likewise: a unit started without a seat session has no
#   ACL on /dev/kvm.
#
# Rollback: systemctl --user disable --now b2b-backup-<vm>.timer
#           systemctl --user disable b2b-vm-<vm>.service
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
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
# systemd splits a command line at whitespace and expands %, so a value that
# carries either would start some other command than the one written here.
for value in "$ROOT" "$CONFIG" "$VM_PATH" "$VM_NAME"; do
    case "$value" in
    *[[:space:]%]*) die "'$value' holds a space or a %: a systemd unit cannot carry it as written; move it or rename it" ;;
    esac
done
MAKE_PATH=$(command -v make) || die "no make on PATH"
ARGS="B2B_CONFIG=$CONFIG VM_PATH=$VM_PATH VM_NAME=$VM_NAME"
UNITS="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
VM_UNIT="b2b-vm-$VM_NAME.service"
BACKUP="b2b-backup-$VM_NAME"
mkdir -p "$UNITS" || die "cannot create $UNITS"

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

# Ponytail: TimeoutStartSec=900 is a first boot's LUKS unlock and disk check
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

# Ponytail: TimeoutStartSec=3000 lets an hour's rsync finish before the
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

status=0
if systemctl --user show-environment >/dev/null 2>&1; then
    if [ "$changed" = 1 ]; then
        systemctl --user daemon-reload || status=1
    fi
    systemctl --user enable "$VM_UNIT" >/dev/null 2>&1 || status=1
    systemctl --user enable --now "$BACKUP.timer" >/dev/null 2>&1 || status=1
    if [ "$status" = 0 ]; then
        printf '✓ %s enabled (starts at boot), %s.timer running\n' "$VM_UNIT" "$BACKUP"
    else
        warn "systemctl --user refused to enable the units (systemctl --user status $VM_UNIT)"
    fi
else
    warn "no systemd user manager answers here; the units are written. Run, in a login session:"
    printf '    systemctl --user daemon-reload && systemctl --user enable %s && systemctl --user enable --now %s.timer\n' "$VM_UNIT" "$BACKUP"
    status=1
fi

user=$(id -un)
if [ "$(loginctl show-user "$user" -p Linger --value 2>/dev/null)" != yes ]; then
    warn "linger is off: these units stop at logout and do not start at boot. Turn it on (it needs root; not run here):"
    printf '    sudo loginctl enable-linger %s\n' "$user"
fi
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
