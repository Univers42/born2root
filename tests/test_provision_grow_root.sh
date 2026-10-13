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
    rm -rf "$TMP"
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
cmd=${cmd//\/tmp\/grow_root.sh/$GUEST\/tmp\/grow_root.sh}
cmd=${cmd//\/tmp\/install_ide_disk.sh/$GUEST\/tmp\/install_ide_disk.sh}
cmd=${cmd//\/dev\/shm\//$GUEST\/shm\/}
cmd=${cmd//sudo -n /}
exec bash -c "$cmd"
EOF
cat >"$TMP/bin/scp" <<'EOF'
#!/bin/bash
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

printf '\n'
[ "$fail" = 0 ] && printf 'all ok\n'
cleanup
trap - EXIT
exit "$fail"
