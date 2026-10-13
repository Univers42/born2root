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
#   autostart.sh writes the VM unit (ExecStart/ExecStop as the live one) and
#   an hourly :15 backup timer, enables both, starts only the timer, rewrites
#   nothing on a second run, PRINTS the linger command when linger is off and
#   never runs sudo, and refuses a value systemd would split. `make -n all`
#   runs it for a profile with [host] autostart = true and only then.
#
# HOW
#   systemctl, loginctl and sudo are stubs on PATH that record their calls;
#   the units land in a temp XDG_CONFIG_HOME.
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
for c in systemctl loginctl sudo; do
    cat >"$TMP/bin/$c" <<EOF
#!/bin/sh
printf '$c %s\n' "\$*" >>"$TMP/calls"
case "$c \$*" in
"loginctl show-user"*) cat "$TMP/linger" 2>/dev/null ;;
"systemctl --user show-environment") [ ! -f "$TMP/no_user_bus" ] || exit 1 ;;
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

echo no >"$TMP/linger"
run >/dev/null
check "linger off: the command is printed" "$(grep -c "sudo loginctl enable-linger $(id -un)" "$TMP/out")" 1
check "... and never run" "$(grep -c '^sudo' "$TMP/calls" || true)" 0

touch "$TMP/no_user_bus"
check "no user systemd: exit 1" "$(run)" 1
check "... naming the commands to run" "$(grep -c 'systemctl --user enable --now b2b-backup-baas.timer' "$TMP/out")" 1
rm -f "$TMP/no_user_bus"

check "a VM_PATH with a space is refused (systemd would split it)" "$(run VM_PATH='/vm/my store')" 1
check "a VM_PATH with % is refused (a systemd specifier)" "$(run VM_PATH='/vm/100%')" 1

# ── make all runs it when the profile says so ───────────────────────────────
all_plan() { env B2B_SECRETS="$TMP/secrets" make -n --no-print-directory all B2B_CONFIG="$1" 2>/dev/null; }
check "make -n all, [host] autostart = true: make autostart is the last step" \
    "$(all_plan profiles/server.toml | tail -n1 | grep -c 'make --no-print-directory autostart' || true)" 1
check "make -n all, no [host]: no autostart" "$(all_plan born2root.toml | grep -c autostart || true)" 0

exit "$fail"
