#!/bin/bash
# Regression test for `qemu_vm.sh stop` when the VM was started from another
# VM_PATH.
#
# The bug it guards: every path in qemu_vm.sh is keyed on VM_PATH, so
# `make qemu_stop` run WITHOUT the VM_PATH the build used looked at the wrong
# pidfile, found nothing, and printed "✓ not running" while the VM kept
# running -- and kept holding VT-x, so the next `make all` reported VirtualBox
# "blocked" with the culprit invisible. other_guests() recovers the running
# guests and the VM_PATH each belongs to from QEMU's own -name / -pidfile
# arguments, and stop/kill refuse to claim success while any exist.
#
# qemu-system-x86_64 need not be installed to run this: qemu_vm.sh's own
# BASH_SOURCE guard skips both that check and the action dispatch when sourced.
set -e

cd "$(dirname "$0")/.."

fail=0
check() {
	if [ "$2" = "$3" ]; then
		printf 'ok   %-40s = %s\n' "$1" "$2"
	else
		printf 'FAIL %-40s = %s (expected %s)\n' "$1" "$2" "$3"
		fail=1
	fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

VM_NAME=debian
VM_PATH="$TMP/here"
export VM_NAME VM_PATH

. ./setup/host/qemu_vm.sh

# Three guests, as /proc would show them: ours, one of the same VM started
# from another VM_PATH (the reproduced case), and an unrelated VM that must be
# left alone. Trailing space is what `tr '\0' ' '` leaves on a real cmdline.
qemu_cmdlines() {
	printf '%s\n' \
		"1001 /usr/bin/qemu-system-x86_64 -name debian -machine pc,accel=kvm -pidfile $TMP/here/debian/qemu.pid " \
		"1002 /usr/bin/qemu-system-x86_64 -name debian -machine pc,accel=kvm -pidfile /mnt/storage/virtualbox/other_machine/debian/qemu.pid " \
		"1003 /usr/bin/qemu-system-x86_64 -name debian-lab -machine pc -pidfile /srv/vms/debian-lab/qemu.pid "
}

check "our own guest is not 'other'"      "$(other_guests | grep -c '^1001 ' || true)" 0
check "same VM from another VM_PATH found" "$(other_guests | grep '^1002 ' | cut -d' ' -f2)" /mnt/storage/virtualbox/other_machine
check "differently named VM ignored"       "$(other_guests | grep -c '^1003 ' || true)" 0
check "exactly one other guest"            "$(other_guests | wc -l)" 1

out=$(report_other_guests 2>&1) && rc=0 || rc=$?
check "report returns 0 when others exist" "$rc" 0
case "$out" in
	*"VM_PATH=/mnt/storage/virtualbox/other_machine make qemu_stop"*)
		printf 'ok   %-40s\n' "report names the exact stop command" ;;
	*)
		printf 'FAIL %-40s = %s\n' "report names the exact stop command" "$out"; fail=1 ;;
esac

# Nothing running anywhere: stop/kill may say "not running" and mean it.
qemu_cmdlines() { :; }
check "no guests: none listed"             "$(other_guests | wc -l)" 0
if report_other_guests > /dev/null 2>&1; then
	printf 'FAIL %-40s\n' "report returns 1 when none"; fail=1
else
	printf 'ok   %-40s\n' "report returns 1 when none"
fi

exit "$fail"
