#!/bin/bash
# The VM's disk image, and whether it holds a *finished* install.
#
# Sourced by generate/orchestrate.sh. It lives in its own file for two reasons:
# sourcing happens near the top, so these can never again be called from a line
# the script has not reached yet (a function referenced before its definition
# has run is not defined — the call exits 127, and "is it already installed?"
# then silently answers "no"); and the stamp logic below is testable on its own
# (tests/test_vm_disk.sh) without a real VM.
#
# Every function reads $VM_NAME at call time, so the caller sets it.

vdi_path() {
	VBoxManage showvminfo "${VM_NAME}" --machinereadable 2> /dev/null \
		| grep '"SATA Controller-0-0"' | cut -d'"' -f4
}

vdi_bytes() {
	local vdi
	vdi=$(vdi_path)
	[ -n "$vdi" ] && [ -f "$vdi" ] || return 1
	stat -c %s "$vdi" 2> /dev/null
}

vdi_uuid() {
	local vdi
	vdi=$(vdi_path)
	[ -n "$vdi" ] || return 1
	VBoxManage showmediuminfo disk "$vdi" 2> /dev/null \
		| awk '/^UUID:/ { print $2; exit }'
}

install_wrote_data() {
	local bytes
	bytes=$(vdi_bytes) || return 1
	# 512 MB: far below any real install, far above an empty dynamic VDI.
	[ "$bytes" -gt 536870912 ]
}

# Written only once the install has been verified, and holding the UUID of the
# disk it vouches for, so a rebuilt VDI cannot inherit an older disk's stamp
# (VirtualBox leaves the VM directory behind if anything in it is not its own).
install_stamp() {
	local vdi
	vdi=$(vdi_path)
	[ -n "$vdi" ] || return 1
	printf '%s.installed' "${vdi%.vdi}"
}

# Size alone cannot tell a finished install from one that was killed partway.
# A run that force-powered-off during pkgsel still left a 4.6 GB disk carrying
# no bootloader, and "already installed" would skip straight past it — booting
# an unbootable disk that then got reported as a LUKS timeout two steps later.
install_finished() {
	local stamp
	stamp=$(install_stamp) || return 1
	[ -f "$stamp" ] || return 1
	[ "$(cat "$stamp" 2> /dev/null)" = "$(vdi_uuid)" ] || return 1
	install_wrote_data
}

mark_install_finished() {
	local stamp
	stamp=$(install_stamp) || return 0
	vdi_uuid > "$stamp" 2> /dev/null || true
}
