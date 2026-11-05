#!/usr/bin/env hellish
# Regression test for the VM's host ports on a host that already uses them.
#
# The bug it guards: a colleague's `make all` from groot died on port errors.
# Guest ports are fixed (UFW lives in the guest), so everything that reaches
# the VM depends on which HOST port a boot landed on, and nothing outside the
# VM directory could read that number: it had to be guessed as 4242 and 8443.
#
# Everything runs against a temp HOME and VM_PATH, with `ss` and `nc` stubbed
# from $LISTENERS and a fake QEMU: no real VM, port or ~/.ssh/config is touched.
set -e

cd "$(dirname "$0")/.."
ROOT=$PWD

TMP=$(mktemp -d)
# shellcheck disable=SC2329,SC2317 # run by the trap
cleanup() {
    kill "$(cat "$TMP/vm/debian/qemu.pid" 2>/dev/null)" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/bin" "$TMP/vm/debian"
export LISTENERS_FILE="$TMP/listeners"
: >"$LISTENERS_FILE"

cat >"$TMP/bin/ss" <<'STUB'
#!/bin/sh
awk 'NF { printf "LISTEN 0 4096 %s 0.0.0.0:*\n", $1 }' "$LISTENERS_FILE"
STUB
printf '#!/bin/sh\nexit 1\n' >"$TMP/bin/nc"
# A guest in name only: a bounded shell whose argv is the command line it was
# given, which is what qemu_pid and running_spec read.
cat >"$TMP/bin/fake-guest" <<'STUB'
#!/bin/sh
pidfile=$1
shift
sh -c 'i=0; while [ "$i" -lt 120 ]; do /bin/sleep 1; i=$((i + 1)); done' fake-guest "$@" \
    >/dev/null 2>&1 </dev/null &
printf '%s\n' "$!" >"$pidfile"
STUB
# FAKE_QEMU_ERR stands in for a bind lost after the probe: its text below is
# what qemu-system-x86_64 printed for a port another listener held (exit 1).
cat >"$TMP/bin/qemu-system-x86_64" <<'STUB'
#!/bin/sh
if [ -n "${FAKE_QEMU_ERR:-}" ]; then
    printf '%s\n' "$FAKE_QEMU_ERR" >&2
    exit "${FAKE_QEMU_RC:-1}"
fi
printf '%s\n' "$@" >"$TMP_ARGS"
pidfile=
for arg in "$@"; do
    [ "${prev:-}" = -pidfile ] && pidfile=$arg
    prev=$arg
done
exec fake-guest "$pidfile" "$@"
STUB
chmod +x "$TMP"/bin/*
export TMP_ARGS="$TMP/args"
export PATH="$TMP/bin:$PATH"

export B2B_CONFIG=tests/fixtures/default.toml
export VM_NAME=debian VM_PATH="$TMP/vm" VM_PATH_REGISTRY="$TMP/registry"
export PORTS_SPEC="ssh:4242:4242 https:8443:8443" PORTS_EXPOSED=https

. ./setup/host/qemu_vm.sh
export ACCEL=tcg
ISO="$TMP/fake.iso"
: >"$ISO"
: >"$DISK"
RECORD="$HOME/.config/born2root/b2b-ports.env"

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s\n     got:      %s\n     expected: %s\n' "$1" "$2" "$3"
        fail=1
    fi
}
check_has() {
    case "$2" in
    *"$3"*) printf 'ok   %s\n' "$1" ;;
    *)
        printf 'FAIL %s\n     missing %s in: %s\n' "$1" "$3" "$2"
        fail=1
        ;;
    esac
}

listen() { printf '%s\n' "$@" >"$LISTENERS_FILE"; }
listen_range() { # listen_range <bind address> <first> <last>
    seq "$2" "$3" | sed "s/^/$1:/" >"$LISTENERS_FILE"
}
# Each boot in a subshell: the port resolver reserves in its shell, and a real
# boot is one process.
boot() {
    (launch disk) >"$TMP/out" 2>&1 && rc=0 || rc=$?
    printf '%s' "$rc"
}
down() {
    kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null || true
    rm -f "$PIDFILE" "$VM_DIR/ports.env" "$TMP_ARGS"
}

printf '\n-- a free port is kept --\n'
listen ""
check "boot succeeds" "$(boot)" 0
check "the record is exactly the two keys" "$(cat "$RECORD")" "SSH_HOST_PORT=4242
WAF_HOST_PORT=8443"
check "the record is mode 600" "$(stat -c %a "$RECORD")" 600
check "the temp file does not outlive the rename" "$(find "${RECORD%/*}" -type f | wc -l | tr -d ' ')" 1
check_has "ssh stays on loopback" "$(cat "$TMP_ARGS")" "hostfwd=tcp:127.0.0.1:4242-:4242"
check_has "https stays exposed" "$(cat "$TMP_ARGS")" "hostfwd=tcp:0.0.0.0:8443-:8443"
down

printf '\n-- a busy port moves, the guest port does not --\n'
listen 127.0.0.1:4242 0.0.0.0:8443
chmod 644 "$RECORD"
check "boot succeeds" "$(boot)" 0
check "the record follows" "$(cat "$RECORD")" "SSH_HOST_PORT=4243
WAF_HOST_PORT=8444"
check "a record left at 644 is replaced at 600" "$(stat -c %a "$RECORD")" 600
check_has "ssh lands on 4243, guest 4242" "$(cat "$TMP_ARGS")" "hostfwd=tcp:127.0.0.1:4243-:4242"
check_has "https lands on 8444, guest 8443" "$(cat "$TMP_ARGS")" "hostfwd=tcp:0.0.0.0:8444-:8443"
down

printf '\n-- the window is default+1..default+50 --\n'
listen_range 127.0.0.1 4242 4291
check "boot succeeds" "$(boot)" 0
check "default+50 is still in the window" "$(head -n1 "$RECORD")" "SSH_HOST_PORT=4292"
down

printf '\n-- all 50 busy fails, and says what to do --\n'
printf 'SSH_HOST_PORT=1\nWAF_HOST_PORT=2\n' >"$RECORD"
listen_range 127.0.0.1 4242 4292
check "boot refuses" "$(boot)" 1
out=$(cat "$TMP/out")
check_has "the message names the forward" "$out" "'ssh'"
check_has "the message names the first port" "$out" "4242"
check_has "the message names the last port" "$out" "4292"
check_has "the message says where to change it" "$out" "[network] forwards"
check "QEMU never ran" "$([ -e "$TMP_ARGS" ] && echo ran || echo no)" no
check "the record is left alone" "$(head -n1 "$RECORD")" "SSH_HOST_PORT=1"
down

printf '\n-- a running VM keeps its ports --\n'
listen ""
boot >/dev/null
listen 127.0.0.1:4242 0.0.0.0:8443
rm -f "$VM_DIR/ports.env"
RESOLVED_SPEC=""
RESERVED_HOST_PORTS=""
check "its own listener is no conflict (ssh)" "$(host_port_of ssh)" 4242
check "its own listener is no conflict (https)" "$(host_port_of https)" 8443
rm -f "$RECORD"
(boot_guest) >"$TMP/out" 2>&1
check_has "a start on a running VM says so" "$(cat "$TMP/out")" "already running"
check "... launches nothing" "$(grep -c 'QEMU running' "$TMP/out" || true)" 0
check "... and records the ports it has" "$(cat "$RECORD")" "SSH_HOST_PORT=4242
WAF_HOST_PORT=8443"
down
listen ""
fake-guest "$PIDFILE" -netdev "user,id=net0,ipv6=off,hostfwd=tcp:127.0.0.1:4250-:4242,hostfwd=tcp:0.0.0.0:8460-:8443"
rm -f "$RECORD"
RESOLVED_SPEC=""
RESERVED_HOST_PORTS=""
(boot_guest) >"$TMP/out" 2>&1
check "a VM that moved stays moved, with its defaults free" "$(cat "$RECORD")" "SSH_HOST_PORT=4250
WAF_HOST_PORT=8460"
down

printf '\n-- a port lost at bind time fails loudly --\n'
listen ""
printf 'SSH_HOST_PORT=1\nWAF_HOST_PORT=2\n' >"$RECORD"
export FAKE_QEMU_ERR="qemu-system-x86_64: -netdev user,id=net0,ipv6=off,hostfwd=tcp:127.0.0.1:4242-:4242: Could not set up host forwarding rule 'tcp:127.0.0.1:4242-:4242'"
check "boot refuses" "$(boot)" 1
out=$(cat "$TMP/out")
check_has "the failure names the port" "$out" "host port 4242"
check_has "... and QEMU's own words are shown" "$out" "Could not set up host forwarding rule"
check "the record does not claim a port nothing bound" "$(head -n1 "$RECORD")" "SSH_HOST_PORT=1"
export FAKE_QEMU_ERR="qemu-system-x86_64: some other refusal"
check "another failure still refuses" "$(boot)" 1
check_has "... with QEMU's words" "$(cat "$TMP/out")" "some other refusal"
export FAKE_QEMU_RC=0 FAKE_QEMU_ERR="qemu-system-x86_64: died after daemonizing"
check "a QEMU that exits 0 and is gone refuses too" "$(boot)" 1
check_has "... with QEMU's words" "$(cat "$TMP/out")" "died after daemonizing"
check "... and no record" "$(head -n1 "$RECORD")" "SSH_HOST_PORT=1"
unset FAKE_QEMU_ERR FAKE_QEMU_RC
down

printf '\n-- an unwritable record stops the start --\n'
listen ""
rm -rf "$HOME/.config"
: >"$HOME/.config"
check "boot refuses" "$(boot)" 1
check_has "the failure names the file" "$(cat "$TMP/out")" "b2b-ports.env"
down
rm -f "$HOME/.config"

printf '\n-- write_ports_record alone --\n'
target="$TMP/rec/dir/x-ports.env"
write_ports_record "$target" 4300 8500
check "creates its directory, mode 700" "$(stat -c %a "${target%/*}")" 700
check "writes the two lines" "$(cat "$target")" "SSH_HOST_PORT=4300
WAF_HOST_PORT=8500"
write_ports_record "$target" 4301 ""
check "a profile with no https forward leaves the key empty" "$(cat "$target")" "SSH_HOST_PORT=4301
WAF_HOST_PORT="
if write_ports_record "$target" "" 8500; then got=wrote; else got=refused; fi
check "no ssh port is refused" "$got" refused
check "... and the old record stands" "$(head -n1 "$target")" "SSH_HOST_PORT=4301"

printf '\n-- ssh b2b follows the record --\n'
mkdir -p "$HOME/.ssh"
printf 'Host other\n    Port 22\n\n' >"$HOME/.ssh/config"
printf 'ssh=4243\nhttps=8444\n' >"$VM_DIR/ports.env"
"${SCRIPT_SH:-bash}" setup/host/qemu_vm.sh ssh-config >/dev/null
check "the b2b block uses SSH_HOST_PORT" "$(awk '/^Host b2b/{on=1} on && $1=="Port"{print $2; exit}' "$HOME/.ssh/config")" 4243
check "another host's block is kept" "$(grep -c '^Host other$' "$HOME/.ssh/config")" 1
printf 'ssh=4244\nhttps=8444\n' >"$VM_DIR/ports.env"
"${SCRIPT_SH:-bash}" setup/host/qemu_vm.sh ssh-config >/dev/null
check "a moved port replaces the block, not adds one" "$(grep -c '^Host b2b' "$HOME/.ssh/config")" 1
check "... with the new port" "$(awk '/^Host b2b/{on=1} on && $1=="Port"{print $2; exit}' "$HOME/.ssh/config")" 4244

printf '\n-- every start takes this path, the autostart tick included --\n'
recipe=$(awk '/^qemu_start:/ { on = 1; next } on && /^\t/ { print; next } on { exit }' "$ROOT/Makefile")
check_has "make qemu_start resolves and records" "$recipe" "qemu_vm.sh start"
check_has "make qemu_start writes the ssh block" "$recipe" "qemu_vm.sh ssh-config"

exit "$fail"
