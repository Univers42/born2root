#!/bin/bash
# Tests for utils/vm_disk.sh — the "does this disk hold a finished install?"
# question that Step 4 of the orchestrator asks before deciding to skip.
#
# This exists because of a real failure: a run force-powered-off the VM during
# pkgsel, leaving a 4.6 GB disk with no bootloader on it. The size check alone
# called that "already installed", the orchestrator skipped the reinstall, and
# the unbootable disk surfaced two steps later as "LUKS unlock timed out".
#
# VBoxManage is stubbed, so no VM is touched.
set -e

cd "$(dirname "$0")/.."

fail=0
check() {
	if [ "$2" = "$3" ]; then
		printf 'ok   %-42s = %s\n' "$1" "$3"
	else
		printf 'FAIL %-42s = %s (expected %s)\n' "$1" "$2" "$3"
		fail=1
	fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

VDI="$TMP/debian.vdi"
STAMP="$TMP/debian.installed"
UUID="51b8c990-3255-4eb3-950b-a80c62b0156b"

# Stub VBoxManage: showvminfo reports the disk, showmediuminfo its UUID.
# $STUB_UUID lets a test pretend the VDI was rebuilt underneath the stamp.
STUB_UUID="$UUID"
VBoxManage() {
	case "$1 $2" in
		"showvminfo --machinereadable" | "showvminfo ${VM_NAME}")
			printf '"SATA Controller-0-0"="%s"\n' "$VDI" ;;
		"showmediuminfo disk")
			printf 'UUID:           %s\n' "$STUB_UUID" ;;
	esac
}
VM_NAME=debian
export VM_NAME

. ./utils/vm_disk.sh

yesno() { if "$@"; then echo yes; else echo no; fi; }

# A dynamic VDI that has barely been touched is not an install.
truncate -s 1M "$VDI"
check "empty disk: wrote data" "$(yesno install_wrote_data)" "no"
check "empty disk: finished" "$(yesno install_finished)" "no"

# The exact shape of the failure: a big disk, but the install was killed partway
# so nothing ever stamped it. Size says yes; the question we actually ask says no.
truncate -s 5G "$VDI"
check "killed mid-install: wrote data" "$(yesno install_wrote_data)" "yes"
check "killed mid-install: finished" "$(yesno install_finished)" "no"

# A verified install stamps the disk, and only then is it safe to skip.
mark_install_finished
check "stamp lands next to the vdi" "$([ -f "$STAMP" ] && echo yes || echo no)" "yes"
check "stamp records the vdi uuid" "$(cat "$STAMP")" "$UUID"
check "verified install: finished" "$(yesno install_finished)" "yes"

# A rebuilt VDI gets a new UUID. VirtualBox leaves the VM directory behind when
# it holds files of its own, so a stale stamp must not vouch for the new disk.
STUB_UUID="00000000-1111-2222-3333-444444444444"
check "stale stamp, rebuilt disk: finished" "$(yesno install_finished)" "no"

# ...and re-stamping after the rebuild makes it trustworthy again.
mark_install_finished
check "restamped after rebuild: finished" "$(yesno install_finished)" "yes"

# A stamp on a disk that is somehow empty is still not an install.
truncate -s 1M "$VDI"
check "stamped but empty disk: finished" "$(yesno install_finished)" "no"

exit $fail
