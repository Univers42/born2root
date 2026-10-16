#!/usr/bin/env hellish
# `make autostart` turns the VM into a service of the host login, the way baas
# had it set up by hand, from the profile alone.
#
# THE FAILURE IT PINS
#   2026-10-13 audit: baas came up at boot and stopped gracefully at shutdown
#   only because of ~/.config/systemd/user/b2b-vm-baas.service, written by
#   hand, and nothing pulled its backups off the guest on a schedule. A
#   rebuild at school would have had neither.
#
# WHAT IS CHECKED
#   With linger on, autostart.sh writes the VM unit (ExecStart/ExecStop as the
#   live one) and an hourly :15 backup timer, enables both, starts only the
#   timer, rewrites nothing on a second run, and refuses a value systemd would
#   split. With linger off (the 42 seats, where nobody has root) it prints no
#   sudo at all: it disables the units and writes a crontab block (a tick
#   every minute, make backup at :15) beside the user's own lines, once. The
#   tick starts the VM only when it is not running, not held for this boot by
#   qemu_vm.sh stop/kill/install, and /dev/kvm is writable. `make -n all`
#   runs autostart for a profile with [host] autostart = true and only then.
#
# HOW
#   systemctl, loginctl, sudo and crontab are stubs on PATH that record their
#   calls (the real crontab is never touched); the units land in a temp
#   XDG_CONFIG_HOME; the tick gets a stub make, a stand-in /dev/kvm and boot
#   id, and a fake QEMU whose command line carries the pidfile.
set -e

cd "$(dirname "$0")/.."
ROOT=$PWD

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
trap 'rm -rf "${TMP:?}"' EXIT
mkdir -p "$TMP/bin"
for c in systemctl loginctl sudo crontab; do
    cat >"$TMP/bin/$c" <<EOF
#!/bin/sh
printf '$c %s\n' "\$*" >>"$TMP/calls"
case "$c \$*" in
"loginctl show-user"*) cat "$TMP/linger" 2>/dev/null ;;
"systemctl --user show-environment") [ ! -f "$TMP/no_user_bus" ] || exit 1 ;;
"systemctl --user is-active"*) [ -f "$TMP/vm_active" ] || exit 3 ;;
"crontab -l") cat "$TMP/crontab" 2>/dev/null || { echo "no crontab for you" >&2; exit 1; } ;;
"crontab -") cat >"$TMP/crontab" ;;
esac
exit 0
EOF
done
chmod +x "$TMP"/bin/*
UNITS="$TMP/config/systemd/user"
run() { # [env...] -> exit code; output in $TMP/out
    : >"$TMP/calls"
    env PATH="$TMP/bin:$PATH" XDG_CONFIG_HOME="$TMP/config" \
        B2B_CONFIG=profiles/server.toml VM_PATH=/vm/store VM_NAME=baas "$@" \
        "${SCRIPT_SH:-bash}" setup/host/autostart.sh >"$TMP/out" 2>&1 && echo 0 || echo $?
}
MAKE_PATH=$(command -v make)
ARGS="B2B_CONFIG=profiles/server.toml VM_PATH=/vm/store VM_NAME=baas"

echo yes >"$TMP/linger"
check "first run: exit 0" "$(run)" 0
VM_UNIT="$UNITS/b2b-vm-baas.service"
check "the VM unit starts the VM as the live one did" \
    "$(sed -n 's/^ExecStart=//p' "$VM_UNIT")" "$MAKE_PATH qemu_start $ARGS"
check "... and stops it gracefully (GRACEFUL=1 STOP_GRACE=120)" \
    "$(sed -n 's/^ExecStop=//p' "$VM_UNIT")" "$MAKE_PATH qemu_stop GRACEFUL=1 STOP_GRACE=120 $ARGS"
check "... from this checkout" "$(sed -n 's/^WorkingDirectory=//p' "$VM_UNIT")" "$ROOT"
check "... oneshot, kept active, wanted at login/boot" \
    "$(grep -cx 'Type=oneshot\|RemainAfterExit=yes\|WantedBy=default.target' "$VM_UNIT")" 3
check "the backup timer fires hourly at :15 (the guest's own runs at :03)" \
    "$(sed -n 's/^OnCalendar=//p' "$UNITS/b2b-backup-baas.timer")" "*-*-* *:15:00"
check "... running make backup for this VM" \
    "$(sed -n 's/^ExecStart=//p' "$UNITS/b2b-backup-baas.service")" "$MAKE_PATH backup $ARGS"
check "systemd reloaded, the VM unit enabled, the timer enabled and started" \
    "$(grep -c '^systemctl --user daemon-reload$\|^systemctl --user enable b2b-vm-baas.service$\|^systemctl --user enable --now b2b-backup-baas.timer$' "$TMP/calls")" 3
check "the VM unit is not started (that would boot a stopped VM now)" \
    "$(grep -c 'start b2b-vm-baas\|--now b2b-vm-baas' "$TMP/calls" || true)" 0
check "linger on: nothing to print about it" "$(grep -c 'enable-linger' "$TMP/out" || true)" 0

cp "$VM_UNIT" "$TMP/unit.first"
check "second run: exit 0" "$(run)" 0
check "... nothing rewritten" "$(cmp -s "$TMP/unit.first" "$VM_UNIT" && echo same)" same
check "... no daemon-reload" "$(grep -c 'daemon-reload' "$TMP/calls" || true)" 0
check "... and says so" "$(grep -c 'unchanged' "$TMP/out")" 3

# ── linger off: cron, and no root anywhere ─────────────────────────────────
echo no >"$TMP/linger"
printf '0 4 * * * echo mine\n' >"$TMP/crontab"
check "linger off: exit 0" "$(run)" 0
check "... no sudo printed, none run" "$(cat "$TMP/out" "$TMP/calls" | grep -c sudo || true)" 0
check "... the timer disabled and stopped, the VM unit only disabled" \
    "$(grep -c '^systemctl --user disable --now b2b-backup-baas.timer$\|^systemctl --user disable b2b-vm-baas.service$' "$TMP/calls")" 2
check "... the tick every minute, under a lock, logged beside the VM" \
    "$(grep -c "^\* \* \* \* \* cd $ROOT && flock -n -o /vm/store/baas/.autostart.lock env PATH=[^ ]* $ARGS [^ ]* setup/host/autostart.sh --tick >>/vm/store/baas/autostart.log 2>&1\$" "$TMP/crontab")" 1
check "... make backup hourly at :15, under its own lock and a timeout" \
    "$(grep -c "^15 \* \* \* \* cd $ROOT && flock -n -o /vm/store/baas/.backup.lock timeout 3000 env PATH=[^ ]* [^ ]*/make backup $ARGS >" "$TMP/crontab")" 1
check "... the user's own line kept" "$(grep -cx '0 4 \* \* \* echo mine' "$TMP/crontab")" 1
cp "$TMP/crontab" "$TMP/crontab.first"
# The crontab is the seat's, the home is the user's: on 2026-10-16 c2r19s6
# had no block (it was written on c2r19s5). The login entry reruns this at
# every desktop login, on whichever seat, once the home is restored.
LOGIN="$TMP/config/autostart/b2b-autostart-baas.desktop"
SHP=$(command -v "${SCRIPT_SH:-bash}")
check "... a login entry reruns autostart.sh, waiting for the home" \
    "$(sed -n 's/^Exec=//p' "$LOGIN")" \
    "timeout 1200 sh -c 'until [ -e $SHP ] && [ -e $ROOT/setup/host/autostart.sh ]; do sleep 2; done; exec env B2B_CONFIG=$ROOT/profiles/server.toml VM_PATH=/vm/store VM_NAME=baas $SHP $ROOT/setup/host/autostart.sh'"
cp "$LOGIN" "$TMP/login.first"
check "second run: exit 0" "$(run)" 0
check "... the crontab not rewritten" "$(grep -c '^crontab -$' "$TMP/calls" || true)" 0
check "... and says so" "$(grep -c 'crontab unchanged' "$TMP/out")" 1
check "... the login entry left as it was" "$(cmp -s "$LOGIN" "$TMP/login.first" && echo same)" same
touch "$TMP/vm_active"
run >/dev/null
check "VM unit active (its ExecStop would stop the VM): the handover is named" \
    "$(grep -c 'make autostart_handover' "$TMP/out")" 1
rm -f "$TMP/vm_active"
echo yes >"$TMP/linger"
run >/dev/null
check "linger on again: the block removed, the user's line kept" "$(cat "$TMP/crontab")" "0 4 * * * echo mine"
check "... and the login entry with it (units do that job)" "$([ -e "$LOGIN" ] && echo kept || echo gone)" gone

touch "$TMP/no_user_bus"
check "linger on, no user systemd: exit 1" "$(run)" 1
check "... naming the commands to run" "$(grep -c 'systemctl --user enable --now b2b-backup-baas.timer' "$TMP/out")" 1
rm -f "$TMP/no_user_bus"

check "a VM_PATH with a space is refused (systemd would split it)" "$(run VM_PATH='/vm/my store')" 1
check "a VM_PATH with % is refused (a systemd specifier)" "$(run VM_PATH='/vm/100%')" 1

# ── the tick: one cron minute ───────────────────────────────────────────────
mkdir -p "$TMP/tickbin" "$TMP/vms/baas"
cat >"$TMP/tickbin/make" <<EOF
#!/bin/sh
printf 'make %s\n' "\$*" >>"$TMP/calls"
EOF
printf '#!/bin/sh\nwhile :; do sleep 1; done\n' >"$TMP/fakeqemu"
chmod +x "$TMP/tickbin/make" "$TMP/fakeqemu"
echo boot-1 >"$TMP/boot_id"
: >"$TMP/kvm"
PIDFILE="$TMP/vms/baas/qemu.pid"
HOLD="$TMP/vms/baas/.autostart-hold"
tick() { # [--handover] -> how many times make ran; output in $TMP/out
    : >"$TMP/calls"
    env PATH="$TMP/tickbin:$TMP/bin:$PATH" B2B_CONFIG=profiles/server.toml VM_PATH="$TMP/vms" VM_NAME=baas \
        B2B_KVM_DEV="${KVM:-$TMP/kvm}" B2B_BOOT_ID_FILE="$TMP/boot_id" \
        "${SCRIPT_SH:-bash}" setup/host/autostart.sh "${1:---tick}" >"$TMP/out" 2>&1
    grep -c '^make ' "$TMP/calls" || true
}
check "tick, VM down: make qemu_start" "$(tick)" 1
check "... from this checkout, for this VM" "$(cat "$TMP/calls")" \
    "make -C $ROOT --no-print-directory qemu_start B2B_CONFIG=profiles/server.toml VM_PATH=$TMP/vms VM_NAME=baas"
check "... its exit status logged" "$(tail -n1 "$TMP/out")" "== exit 0"
echo boot-1 >"$HOLD"
check "tick, held this boot (make qemu_stop): nothing" "$(tick)" 0
echo boot-0 >"$HOLD"
check "tick, held at an earlier boot: make qemu_start" "$(tick)" 1
rm -f "$HOLD"
check "tick, /dev/kvm not ours (no seat session): nothing, never TCG" "$(KVM="$TMP/no-kvm" tick)" 0
echo $$ >"$PIDFILE"
check "tick, a pidfile naming some other process: make qemu_start" "$(tick)" 1
# The guard's system bus: gdbus prints $TMP/signals and ends, and
# systemd-inhibit refuses (as polkit does on the 42 seats) unless
# $TMP/inhibit_ok exists, then runs its command like the real one.
cat >"$TMP/tickbin/gdbus" <<EOF
#!/bin/sh
printf 'gdbus %s\n' "\$*" >>"$TMP/calls"
cat "$TMP/signals" 2>/dev/null
EOF
cat >"$TMP/tickbin/systemd-inhibit" <<EOF
#!/bin/sh
[ -f "$TMP/inhibit_ok" ] || { echo 'Failed to inhibit: Interactive authentication required.' >&2; exit 1; }
printf 'systemd-inhibit %s\n' "\$*" >>"$TMP/calls"
while case "\$1" in --*) true ;; *) false ;; esac; do shift; done
exec "\$@"
EOF
chmod +x "$TMP/tickbin/gdbus" "$TMP/tickbin/systemd-inhibit"
GUARD_LOG="$TMP/vms/baas/shutdown-guard.log"
"$TMP/fakeqemu" -pidfile "$PIDFILE" &
echo $! >"$PIDFILE"
check "tick, VM running: nothing" "$(tick)" 0
# The tick detaches the guard; with no signal on the stub bus it ends at once.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    grep -q 'monitor ended' "$GUARD_LOG" 2>/dev/null && break
    sleep 0.5
done
check "... and it keeps a shutdown guard running" "$(grep -c '^== .*guarding baas' "$GUARD_LOG" 2>/dev/null)" 1
# The line gdbus 2.72 prints for the signal (captured from an emitted one on
# the session bus, 2026-10-14).
SHUTDOWN='/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForShutdown (true,)'
echo "$SHUTDOWN" >"$TMP/signals"
check "guard, host shutting down: make qemu_stop" "$(tick --guard)" 1
check "... gracefully, with the unit's own grace" "$(grep '^make ' "$TMP/calls")" \
    "make -C $ROOT --no-print-directory qemu_stop GRACEFUL=1 STOP_GRACE=120 B2B_CONFIG=profiles/server.toml VM_PATH=$TMP/vms VM_NAME=baas"
check "... polkit refused the delay lock: watched anyway, and said so" \
    "$(grep -c 'no delay lock' "$TMP/out")" 1
touch "$TMP/inhibit_ok"
check "guard, delay lock granted: make qemu_stop" "$(tick --guard)" 1
check "... the monitor runs under a shutdown delay lock" \
    "$(grep -c '^systemd-inhibit --what=shutdown --mode=delay .*gdbus monitor --system --dest org.freedesktop.login1' "$TMP/calls")" 1
rm -f "$TMP/inhibit_ok"
echo "${SHUTDOWN%(true,)}(false,)" >"$TMP/signals"
check "guard, PrepareForShutdown(false) (a resume, a cancel): nothing" "$(tick --guard)" 0
kill "$(cat "$PIDFILE")"
rm -f "$PIDFILE"
echo "$SHUTDOWN" >"$TMP/signals"
check "guard, host shutting down, VM not running: nothing" "$(tick --guard)" 0
rm -f "$TMP/signals"
echo boot-1 >"$HOLD"
check "handover, VM down: the hold released, make not run" "$(tick --handover)" 0
check "... nothing held" "$([ -e "$HOLD" ] && echo held || echo free)" free

# qemu_vm.sh leaves the hold wherever the guest stops on purpose and clears it
# where one starts. case_holds ACTION: hold lines in that case of its dispatcher.
case_holds() {
    awk -v c="    $1)" '$0 == c { on = 1 } on && /hold_autostart|rm -f "\$HOLD"/ { n++ }
        on && /^        ;;$/ { exit } END { print n + 0 }' setup/host/qemu_vm.sh
}
check "qemu_vm.sh stop, kill and install hold; start releases" \
    "$(case_holds stop) $(case_holds kill) $(case_holds install) $(case_holds start)" "1 1 1 1"

# ── make all runs it when the profile says so ───────────────────────────────
all_plan() { env B2B_SECRETS="$TMP/secrets" make -n --no-print-directory all B2B_CONFIG="$1" 2>/dev/null; }
check "make -n all, [host] autostart = true: make autostart is the last step" \
    "$(all_plan profiles/server.toml | tail -n1 | grep -c 'make --no-print-directory autostart' || true)" 1
check "make -n all, no [host]: no autostart" "$(all_plan born2root.toml | grep -c autostart || true)" 0

exit "$fail"
