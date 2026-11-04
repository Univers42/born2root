#!/usr/bin/env hellish
# Pins what backup_pull.sh does with a pull, end to end, with ssh, rsync's far
# side and provision_vm.sh stubbed.
#
# Three real bugs:
#   * `guest snapshots < copy snapshots` refused the pull. Retention wobbles by
#     one or two, so from day 14 of a guest's life the copy froze: 1165 of 1680
#     hourly pulls refused, modelled over 70 days, and 167 of the last 168.
#   * provision_vm.sh's `backup` went through run_provisioner, whose warn returns
#     0: `make restore` printed "restored" over a failed restore.
#   * ports.env outlives the VM, so a stopped guest's `make backup` reached
#     whichever guest held the port now.
set -u
cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." || exit 1
fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s -- got: %s, expected: %s\n' "$1" "$2" "$3"
        fail=1
    fi
}
T=$(mktemp -d)
sleeper=""
trap '[ -z "$sleeper" ] || kill "$sleeper" 2>/dev/null; rm -rf "$T"' EXIT

eval "$(awk '/^pull_refusal\(\) \{/{p=1} p{print} p && /^\}/{exit}' setup/host/backup_pull.sh)"
check "same repository, one snapshot fewer: pulled" "$(pull_refusal aa aa 42 41)" ""
check "same repository, the plateau's worst dip: pulled" "$(pull_refusal aa aa 43 41)" ""
check "a first pull, no copy yet: pulled" "$(pull_refusal "" aa 0 1)" ""
check "another repository, MORE snapshots: refused all the same" \
    "$(pull_refusal aa bb 2 90 | grep -c 'different repository')" 1
check "a guest that forgot most of them: refused" "$(pull_refusal aa aa 42 3 | grep -c 'kept 3')" 1
check "... unless it was you" "$(BACKUP_ALLOW_SHRINK=1 pull_refusal aa aa 42 3)" ""

# The hermetic run: a guest repository on disk, ssh and rsync's remote faked.
GUEST="$T/guest"
mkdir -p "$GUEST/snapshots" "$T/bin" "$T/vms/vm1" "$T/dest/repo/snapshots"
echo id-1 >"$GUEST/config"
echo id-1 >"$T/dest/repo/config"
echo pack >"$GUEST/snapshots/s1"
echo pack >"$T/dest/repo/snapshots/s1"
echo old >"$T/dest/repo/snapshots/forgotten"
printf 'ssh=4242\n' >"$T/vms/vm1/ports.env"
python3 -c 'import time; time.sleep(120)' "$T/vms/vm1/qemu.pid" &
sleeper=$!
echo "$sleeper" >"$T/vms/vm1/qemu.pid"
cat >"$T/bin/ssh" <<STUB
#!/bin/bash
case "\$*" in
*"ls /var/backups/b2b/repo/snapshots"*) ls "$GUEST/snapshots" ;;
*"sha256sum /var/backups/b2b/repo/config"*) sha256sum "$GUEST/config" ;;
esac
exit 0
STUB
real_rsync=$(command -v rsync)
cat >"$T/bin/rsync" <<STUB
#!/bin/bash
args=()
for a in "\$@"; do
    case "\$a" in
    *127.0.0.1:/var/backups/b2b/repo/) args+=("$GUEST/") ;;
    *127.0.0.1:/tmp/*) args+=("$T/pushed/") ;;
    -e | "ssh "*) ;;
    *) args+=("\$a") ;;
    esac
done
exec "$real_rsync" "\${args[@]}"
STUB
cat >"$T/script_sh" <<STUB
#!/bin/bash
case "\$1" in
*provision_vm.sh)
    echo provisioned >>"$T/provisioned"
    exit "\${STUB_GUEST_RC:-0}"
    ;;
*rotate_password.sh) exit 0 ;;
esac
exec bash "\$@"
STUB
chmod +x "$T/bin/ssh" "$T/bin/rsync" "$T/script_sh"
printf 'RESTIC_PASSWORD=x\n' >"$T/s"
chmod 600 "$T/s"
pull() {
    env PATH="$T/bin:$PATH" B2B_CONFIG=tests/fixtures/default.toml B2B_SECRETS="$T/s" SCRIPT_SH="$T/script_sh" \
        VM_NAME=vm1 VM_PATH="$T/vms" VM_USER=u BACKUP_DEST="$T/dest" "$@"
}
pull bash setup/host/backup_pull.sh >"$T/out" 2>&1
check "a clean run succeeds" "$?" 0
check "... and leaves the stamp verify_platform reads" "$([ -s "$T/dest/last-pull" ] && echo yes)" yes
check "... the copy follows the guest" "$([ -e "$T/dest/repo/snapshots/forgotten" ] && echo there || echo gone)" gone
check "... what it dropped waits in the attic" "$(find "$T/dest/attic" -name forgotten | wc -l)" 1

echo new >"$GUEST/snapshots/s2"
rm "$T/dest/last-pull"
STUB_GUEST_RC=3 pull bash setup/host/backup_pull.sh >"$T/out" 2>&1
check "one engine's dump failed: the job fails" "$?" 1
check "... but the rest still left the guest" "$([ -e "$T/dest/repo/snapshots/s2" ] && echo pulled)" pulled
check "... and it says what happened" "$(grep -c 'NOT in this snapshot' "$T/out")" 1

echo newer >"$GUEST/snapshots/s3"
STUB_GUEST_RC=1 pull bash setup/host/backup_pull.sh >"$T/out" 2>&1
check "no snapshot at all: fails" "$?" 1
check "... without touching the copy" "$([ -e "$T/dest/repo/snapshots/s3" ] && echo pulled || echo left)" left

STUB_GUEST_RC=1 pull bash setup/host/backup_pull.sh --restore >"$T/out" 2>&1
check "a failed restore is a failure" "$?" 1
check "... reported as the guest's, not as a failed push" "$(grep -c 'the restore failed (exit 1)' "$T/out")" 1
check "... and never says restored" "$(grep -c 'restored; ' "$T/out")" 0
pull bash setup/host/backup_pull.sh --restore >"$T/out" 2>&1
check "a good restore says so" "$(grep -c 'restored; ' "$T/out")" 1

echo id-2 >"$GUEST/config"
pull bash setup/host/backup_pull.sh >"$T/out" 2>&1
check "a rebuilt guest's fresh repository: refused" "$?" 1
check "... naming make restore" "$(grep -c 'make restore' "$T/out")" 1
echo id-1 >"$GUEST/config"

kill "$sleeper" 2>/dev/null
wait "$sleeper" 2>/dev/null
sleeper=""
: >"$T/provisioned"
pull bash setup/host/backup_pull.sh >"$T/out" 2>&1
check "a stopped VM's ports.env: refused" "$?" 1
check "... before anything reached whichever guest has that port" "$(wc -l <"$T/provisioned")" 0
check "... saying why" "$(grep -c 'not running' "$T/out")" 1
exit "$fail"
