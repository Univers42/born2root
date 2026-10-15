#!/usr/bin/env hellish
# utils/first_boot.sh's guest probes survive a key typed into the build's
# terminal.
#
# THE FAILURE IT PINS
#   2026-10-14: a QEMU build sat at "first boot is provisioning the guest
#   0m15s" for good, while the guest went on and finished first boot unseen.
#   Someone had typed into the build's terminal. timeout(1) runs ssh as a
#   background job there; ssh read the pending keys and SIGTTIN stopped it,
#   and timeout's SIGTERM never ended it (ssh catches TERM and its restarted
#   read stops it again; timeout without -k then waits forever).
#
# HOW
#   first_boot_wait runs under a pseudo-terminal (python3's pty: the build
#   needs python3 anyway) with a line already typed on it, against a stand-in
#   ssh that does what ssh does with its stdin and with TERM. The fixed wait
#   returns in about a second; the bound is 20 s. Before the fix it never
#   returned, and with -k alone each probe cost 30 s.
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

if ! command -v python3 >/dev/null 2>&1; then
    printf 'skip python3 missing\n'
    exit 0
fi

TMP=$(mktemp -d)
trap 'pkill -KILL -f "$TMP/" 2>/dev/null || true; rm -rf "${TMP:?}"' EXIT
export FAKE_LOG="$TMP/probes.log"

# ssh as far as stdin and TERM go: whatever is readable on stdin is read (ssh
# forwards it to the remote command), TERM is caught. The guest answers "not
# finished" to the first two crontab probes, then "finished".
cat >"$TMP/ssh" <<'PY'
#!/usr/bin/env python3
import os, select, signal, sys
signal.signal(signal.SIGTERM, lambda *_: None)
log = os.environ["FAKE_LOG"]
with open(log, "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
cmd = sys.argv[-1]
if cmd == "stdin":
    sys.stdout.write(sys.stdin.read())
    sys.exit(0)
if select.select([0], [], [], 0.2)[0]:
    os.read(0, 1024)
if "grep -c" in cmd:
    with open(log) as f:
        print(0 if sum("grep -c" in line for line in f) >= 3 else 1)
elif "tail" in cmd:
    print("nvim ok / 120")
else:
    print("ok")
PY
chmod +x "$TMP/ssh"

cat >"$TMP/drive.sh" <<'SH'
cd "$1" || exit 1
. utils/first_boot.sh
FB_SSH=("$2" b2b)
fb_wait_tick() { sleep 0.1; }
fb_progress() { :; }
rc=0
first_boot_wait 600 || rc=$?
echo "wait-rc=$rc"
SH

# <bound s> <command...>: runs the command on a fresh pty with a line typed
# on it before it starts; prints what the terminal showed, or timed-out.
on_typed_tty() {
    python3 -I - "$@" <<'PY'
import os, pty, select, signal, sys, time
bound, argv = float(sys.argv[1]), sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)
os.write(fd, b"ssh b2b\r")
out, end = b"", time.time() + bound
while time.time() < end:
    if select.select([fd], [], [], 0.2)[0]:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
else:
    os.killpg(pid, signal.SIGKILL)
    out += b"\ntimed-out\n"
sys.stdout.write(out.decode(errors="replace"))
PY
}

shown=$(on_typed_tty 20 "${SCRIPT_SH:-bash}" "$TMP/drive.sh" "$PWD" "$TMP/ssh")
check "first_boot_wait ends with a key typed into its terminal" \
    "$(printf '%s\n' "$shown" | tr -d '\r' | grep -o -m1 'wait-rc=[0-9]*\|timed-out')" wait-rc=0
check "every probe takes none of the b2b block's forwards" \
    "$(grep -vc 'ClearAllForwardings=yes' "$FAKE_LOG" || true)" 0

# The verdict hands awk its program on stdin: a stdin that is not a terminal
# must still reach the guest command.
# shellcheck disable=SC2016 # $1 is the inner shell's
check "a piped stdin still reaches the guest command" \
    "$(printf 'BEGIN { }\n' | env FAKE_LOG="$FAKE_LOG" "${SCRIPT_SH:-bash}" -c \
        '. utils/first_boot.sh; FB_SSH=("$1" b2b); fb_ssh stdin' _ "$TMP/ssh")" 'BEGIN { }'

exit "$fail"
