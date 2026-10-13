#!/usr/bin/env hellish
# Regression test for `provision_vm.sh <vm> grow-root`, the host half of
# setup/install/dc/grow_root.sh.
#
# What it guards: the LUKS passphrase reaches the guest script through a FIFO
# in the guest's /dev/shm and nowhere else -- not an ssh command line, not the
# output -- and the FIFO is gone afterwards, read or not; the dry run asks for
# no passphrase; the partition table the guest prints lands beside the VM's
# disk; the guest script's failure is this command's failure -- and the same
# for `ide-disk` (install_ide_disk.sh), whose refusals are its answer.
#
# ssh and scp are fakes that run "the guest" here: /tmp/grow_root.sh and
# /dev/shm/ are mapped under $GUEST, sudo is dropped, and scp uploads a stand-in
# for grow_root.sh, so nothing runs as root and no disk is touched.
#
# Modes the tests below switch on: FAKE_MKTEMP_REPLY (the guest lies about
# where it put the key FIFO), FAKE_SCP_FAIL (the upload fails),
# FAKE_SCRIPT_OUTPUT=lines (a provisioner that prints a line, sleeps 2 s,
# prints another -- the live-output test), and FAKE_SUDO_PASSWORD=1 (the
# guest refuses passwordless sudo, so the askpass helper is installed).
set -e

cd "$(dirname "$0")/.."
REPO=$(pwd)

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-56s = %s\n' "$1" "$2"
    else
        printf 'FAIL %-56s = %s (expected %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}

TMP=$(mktemp -d)
GUEST="$TMP/guest"
# Every fake ssh records its pid (it execs, so the pid is whatever it runs).
# One still running something under $GUEST after provision_vm.sh returned is
# a writer left behind; the cmdline check keeps a reused pid out of it.
alive_fakes() { # [--kill] -> how many
    local p n=0
    while read -r p; do
        case "$(awk '{ print $3 }' "/proc/$p/stat" 2>/dev/null)" in '' | Z) continue ;; esac
        case "$(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null)" in *"$GUEST"*) ;; *) continue ;; esac
        n=$((n + 1))
        if [ "${1:-}" = --kill ]; then
            kill "$p" 2>/dev/null || true
        fi
    done <"$GUEST/ssh.pids"
    echo "$n"
}
cleanup() {
    if [ -f "$GUEST/ssh.pids" ]; then
        alive_fakes --kill >/dev/null
    fi
    rm -rf "${TMP:?}"
}
trap cleanup EXIT
mkdir -p "$TMP/bin" "$GUEST/tmp" "$GUEST/shm" "$TMP/vm/t-grow"
printf 'ssh=4242\n' >"$TMP/vm/t-grow/ports.env"

cat >"$TMP/bin/ssh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$GUEST/ssh.argv"
printf '%s\n' "$$" >>"$GUEST/ssh.pids"
while [ $# -gt 0 ]; do
    case "$1" in
    -o | -p) shift 2 ;;
    *@*)
        shift
        break
        ;;
    *) shift ;;
    esac
done
cmd="$*"
# The two shapes worth recognizing, before the rewrites below turn
# /dev/shm/ into $GUEST/shm/ on the way "into the guest".
is_key_fifo_mktemp=0
is_script_run=0
if printf '%s\n' "$cmd" | grep -q 'mktemp -d /dev/shm/b2b-grow-root\.'; then
    is_key_fifo_mktemp=1
fi
if printf '%s\n' "$cmd" | grep -q 'bash /tmp/grow_root.sh'; then
    is_script_run=1
fi
cmd=${cmd//\/tmp\/grow_root.sh/$GUEST\/tmp\/grow_root.sh}
cmd=${cmd//\/tmp\/install_ide_disk.sh/$GUEST\/tmp\/install_ide_disk.sh}
if [ "${FAKE_SUDO_PASSWORD:-0}" = 1 ] && [ "$cmd" = "sudo -n true" ]; then
    exit 1
fi
cmd=${cmd//\/dev\/shm\//$GUEST\/shm\/}
cmd=${cmd//\/tmp\/.b2b-/$GUEST\/tmp\/.b2b-}
cmd=${cmd//sudo -n /}
cmd=${cmd//sudo -A /}
# A guest that lies about where it put the FIFO: echo the lie instead of
# running anything. The code under test builds KEY_DIR from this output.
if [ "$is_key_fifo_mktemp" = 1 ] && [ -n "${FAKE_MKTEMP_REPLY:-}" ]; then
    printf '%s\n' "$FAKE_MKTEMP_REPLY"
    exit 0
fi
# The only rm -rf the provisioner should ever send is the key FIFO's
# directory; anything else (a guest that answered "/") is recorded above
# but must not run on this host.
case "$cmd" in
*"rm -rf"*)
    case "$cmd" in
    *"rm -rf '$GUEST/shm/"*|*"rm -rf '/dev/shm/"*) ;;
    *)
        echo "fake guest: refusing to run: $cmd" >&2
        exit 1
        ;;
    esac
    ;;
esac
if [ "$is_key_fifo_mktemp" = 1 ]; then
    # mktemp ran under $GUEST/shm (above); echo the guest-style
    # path back, so KEY_DIR looks like the real guest's /dev/shm.
    # The exit is the whole point: exec in a pipeline replaces only
    # the segment's subshell, so without it the script would fall
    # through to the final exec and run mktemp a second time --
    # two dirs, and a KEY_DIR of two lines.
    bash -c "$cmd" | sed "s|$GUEST/shm/|/dev/shm/|"
    exit "${PIPESTATUS[0]}"
fi
if [ "$is_script_run" = 1 ] && [ "${FAKE_SCRIPT_OUTPUT:-}" = lines ]; then
    # A provisioner that prints a line, sleeps 2 s, prints another.
    echo "first line"
    sleep 2
    echo "second line"
    exit 0
fi
exec bash -c "$cmd"
EOF
cat >"$TMP/bin/scp" <<'EOF'
#!/bin/bash
[ "${FAKE_SCP_FAIL:-0}" = 1 ] && exit 1
for dest; do :; done
cp "$GUEST_SCRIPT" "$GUEST/tmp/${dest##*/}"
EOF
printf '#!/bin/sh\nexit 1\n' >"$TMP/bin/VBoxManage"
# The stand-in: says which FIFO it was handed, reads the key from it when
# told to, prints the partition table the way grow_root.sh does, exits FAKE_RC.
cat >"$TMP/guest_script.sh" <<'EOF'
. "$REPO/setup/install/dc/grow_root.sh"
printf '%s' "${GROW_ROOT_KEY_FIFO:-none}" >"$GUEST/fifo.given"
if [ "$FAKE_READS_KEY" = 1 ]; then
    timeout 10 cat "$GROW_ROOT_KEY_FIFO" >"$GUEST/key.received"
fi
if [ "$FAKE_PRINTS_DUMP" = 1 ]; then
    printf '%s %s\n%s\n%s\n' "$DUMP_BEGIN" 20261013T120000 "$(cat "$REPO/tests/fixtures/grow_root/sfdisk-80g.dump")" "$DUMP_END"
fi
echo "[grow-root] stand-in done"
exit "$FAKE_RC"
EOF
chmod +x "$TMP/bin/ssh" "$TMP/bin/scp" "$TMP/bin/VBoxManage"

PASS="s3cret-$$-passphrase"
export GUEST REPO GUEST_SCRIPT="$TMP/guest_script.sh" VM_PASS="$PASS"
export B2B_CONFIG=tests/fixtures/default.toml VM_PATH="$TMP/vm"
grow_root() { # <apply> <reads key> <prints dump> <guest rc> -> rc
    rm -f "$GUEST/ssh.argv" "$GUEST/fifo.given" "$GUEST/key.received" "$TMP/vm/t-grow"/sfdisk-*.dump
    env PATH="$TMP/bin:$PATH" GROW_ROOT_APPLY="$1" FAKE_READS_KEY="$2" FAKE_PRINTS_DUMP="$3" FAKE_RC="$4" \
        timeout 60 "${SCRIPT_SH:-bash}" setup/host/provision_vm.sh t-grow grow-root >"$TMP/out" 2>&1 &&
        echo 0 || echo $?
}
leftovers() { find "$GUEST/shm" -mindepth 1 | grep -c . || true; }

check "dry run: 0" "$(grow_root '' 0 0 0)" 0
check "dry run: no FIFO made" "$(grep -c 'mktemp -d /dev/shm/' "$GUEST/ssh.argv" || true)" 0
check "dry run: the guest got no FIFO" "$(cat "$GUEST/fifo.given")" none
check "dry run: no copy of a table" "$(find "$TMP/vm/t-grow" -name 'sfdisk-*' | grep -c . || true)" 0

check "apply: 0" "$(grow_root 1 1 1 0)" 0
check "apply: the FIFO is in the guest's /dev/shm" "$(grep -c 'mktemp -d /dev/shm/b2b-grow-root' "$GUEST/ssh.argv")" 1
check "apply: the guest script got it" "$(case "$(cat "$GUEST/fifo.given")" in "$GUEST"/shm/b2b-grow-root.*/key) echo yes ;; esac)" yes
check "apply: the passphrase came through it" "$(cat "$GUEST/key.received")" "$PASS"
check "apply: on no ssh command line" "$(grep -cF -- "$PASS" "$GUEST/ssh.argv" || true)" 0
check "apply: not in the output" "$(grep -cF -- "$PASS" "$TMP/out" || true)" 0
check "apply: the table's copy beside the disk" "$(cmp -s tests/fixtures/grow_root/sfdisk-80g.dump "$TMP/vm/t-grow/sfdisk-20261013T120000.dump" && echo same)" same
check "apply: the FIFO is gone" "$(leftovers)" 0
check "apply: no writer left" "$(alive_fakes)" 0

check "apply, key never read: 0, no hang" "$(grow_root 1 0 0 0)" 0
check "apply, key never read: the FIFO is gone" "$(leftovers)" 0
check "apply, key never read: no writer left" "$(alive_fakes)" 0

check "apply, the guest script fails: 1" "$(grow_root 1 1 0 4)" 1
check "apply, the guest script fails: says so" "$(grep -c 'grow_root.sh exited 4' "$TMP/out")" 1
check "apply, the guest script fails: the FIFO is gone" "$(leftovers)" 0

ide_disk() { # <guest rc> -> rc
    rm -f "$GUEST/ssh.argv"
    env PATH="$TMP/bin:$PATH" FAKE_READS_KEY=0 FAKE_PRINTS_DUMP=0 FAKE_RC="$1" \
        timeout 60 "${SCRIPT_SH:-bash}" setup/host/provision_vm.sh t-grow ide-disk >"$TMP/out" 2>&1 &&
        echo 0 || echo $?
}
check "ide-disk: 0" "$(ide_disk 0)" 0
check "ide-disk: ran install_ide_disk.sh" "$(grep -c 'bash /tmp/install_ide_disk.sh' "$GUEST/ssh.argv")" 1
check "ide-disk, the guest script refuses: 1" "$(ide_disk 1)" 1
check "ide-disk, the guest script refuses: says so" "$(grep -c 'install_ide_disk.sh exited 1' "$TMP/out")" 1

# ── Live output: tr must be line-buffered ────────────────────────────────────
# A provisioner's output reaches the operator through ssh | tr -d '\r' | tee,
# and tr's stdio holds each line back in a 4 KB block: measured, three lines
# printed a second apart all landed in the same second. The fake ssh (see
# FAKE_SCRIPT_OUTPUT there) prints a line, sleeps 2 s, prints another; the
# first must reach the transcript within 1 s of the run starting.
# Ponytail: the 1 s bound can flake on a very loaded machine.
test_line_buffered() {
    local t0 t1 found="" f prov_pid
    t0=$(date +%s.%N)
    env TMPDIR="$TMP" FAKE_SCRIPT_OUTPUT=lines \
        PATH="$TMP/bin:$PATH" \
        timeout 30 "${SCRIPT_SH:-bash}" setup/host/provision_vm.sh t-grow grow-root \
        >"$TMP/out5" 2>&1 &
    prov_pid=$!
    # The transcript is a fresh mktemp under TMPDIR; find it by glob and
    # watch for the first line. Without stdbuf it appears only when the
    # pipe closes, ~2 s in. The window is 2 s: the bound under test is
    # the 1 s the awk below applies to when the line landed.
    while :; do
        for f in "$TMP"/tmp.*; do
            if [ -f "$f" ] && grep -q 'first line' "$f" 2>/dev/null; then
                found=$f
                break 2
            fi
        done
        t1=$(date +%s.%N)
        awk -v a="$t0" -v b="$t1" 'BEGIN { exit !(b - a > 2) }' && break
        sleep 0.1
    done
    # Let the run finish on its own: killing it would strand the transcript.
    wait "$prov_pid" 2>/dev/null || true
    if [ -n "$found" ] && awk -v a="$t0" -v b="$t1" 'BEGIN { exit !(b - a < 1) }'; then
        echo ok
    else
        echo "first line never landed within 1 s (t0=$t0 t1=$t1)"
    fi
}

check "vm_ssh_tty: the first line reaches the reader within 1 s" "$(test_line_buffered)" ok

# ── The transcript is removed on every way out ───────────────────────────────
# grow_root makes its transcript with mktemp and, before the trap, removed it
# only on the normal path: a guest_script failure (the upload below is made
# to fail) stranded it in TMPDIR. TMPDIR points into $TMP so it is findable.
test_transcript_cleanup() {
    local leaked
    env FAKE_SCP_FAIL=1 TMPDIR="$TMP" GROW_ROOT_APPLY=1 \
        PATH="$TMP/bin:$PATH" \
        timeout 30 "${SCRIPT_SH:-bash}" setup/host/provision_vm.sh t-grow grow-root \
        >"$TMP/out6" 2>&1 || true
    leaked=$(find "$TMP" -maxdepth 1 -name 'tmp.*' -type f | grep -c . || true)
    if [ "$leaked" -eq 0 ]; then
        echo ok
    else
        echo "$leaked transcript(s) left behind"
    fi
}

check "grow_root: the transcript survives no way out (upload failure)" "$(test_transcript_cleanup)" ok

# ── key_fifo_close refuses a KEY_DIR the guest lied about ────────────────────
# KEY_DIR is whatever the guest's mktemp echoed, and the rm -rf is built from
# it; a guest that answers "/" or a banner must be refused, and no rm command
# may be sent at all.
test_key_dir_refusal() { # <what the guest's mktemp echoes>
    local reply="$1" refused named bad_rm
    env FAKE_MKTEMP_REPLY="$reply" GROW_ROOT_APPLY=1 FAKE_RC=0 \
        PATH="$TMP/bin:$PATH" \
        timeout 30 "${SCRIPT_SH:-bash}" setup/host/provision_vm.sh t-grow grow-root \
        >"$TMP/out7" 2>&1 || true
    refused=$(grep -c "refusing to rm -rf invalid KEY_DIR" "$TMP/out7" || true)
    # The refusal must name the value it refused, so an operator can
    # tell a lie from a banner.
    named=$(grep -cF "invalid KEY_DIR='$reply'" "$TMP/out7" || true)
    bad_rm=$(grep -c "rm -rf '$reply'" "$GUEST/ssh.argv" || true)
    if [ "$refused" -ge 1 ] && [ "$named" -ge 1 ] && [ "$bad_rm" -eq 0 ]; then
        echo ok
    else
        echo "refused=$refused named=$named rm_sent=$bad_rm"
    fi
}

check "key_fifo_close: refuses the guest echoing /" "$(test_key_dir_refusal /)" ok
check "key_fifo_close: refuses the guest echoing a banner" "$(test_key_dir_refusal '=== Welcome to the VM ===')" ok

# The refusal dies inside the EXIT trap, and a die there skips what follows it:
# the askpass cleanup must come first, or the sudo password stays on the VM.
test_askpass_after_refusal() {
    local left
    env FAKE_MKTEMP_REPLY=/ FAKE_SUDO_PASSWORD=1 VM_SUDO_PASS=not-a-real-pass GROW_ROOT_APPLY=1 FAKE_RC=0 \
        PATH="$TMP/bin:$PATH" \
        timeout 30 "${SCRIPT_SH:-bash}" setup/host/provision_vm.sh t-grow grow-root \
        >"$TMP/out8" 2>&1 || true
    if ! grep -q "sudo: password accepted" "$TMP/out8"; then
        echo "the askpass path never ran"
        return
    fi
    left=$(find "$GUEST/tmp" -maxdepth 1 -name '.b2b-*' | grep -c . || true)
    if [ "$left" -eq 0 ]; then
        echo ok
    else
        echo "$left password/askpass file(s) left on the guest"
    fi
}

check "key_fifo_close refusal: the sudo password still leaves the guest" "$(test_askpass_after_refusal)" ok

printf '\n'
[ "$fail" = 0 ] && printf 'all ok\n'
cleanup
trap - EXIT
exit "$fail"
