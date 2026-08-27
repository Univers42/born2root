#!/bin/bash
# Start the VM headless and answer the guest's LUKS prompt from the host.
#
# The guest's LVM lives inside a LUKS container (preseeds/preseed.cfg sets
# partman-auto/method=crypto), so the initramfs stops for a passphrase long before
# networking or SSH exist. Typing into the VM's virtual keyboard is the only host
# channel that reaches that prompt, which is what lets the VM run headless.
#
# This previously called `controlvm addencpassword`. That unlocks VirtualBox's own
# VDI encryption -- a different feature, reported "Encryption: disabled" on this
# disk -- so it never answered the guest and the VM sat at the prompt until SSH
# timed out.
#
# Sourcing this file only defines functions; it starts nothing.

VM_NAME="${VM_NAME:-debian}"
VM_PASS_FILE="${VM_PASS_FILE:-vm_pass.txt}"
# Measured on this VM (VBoxManage screenshotpng, boot from disk):
#   t=3-13s   GRUB menu, 5s countdown
#   t=16-26s  kernel + initramfs, blank screen
#   t~30s     "Please unlock disk sda5_crypt:" is up
#   +15s      sshd answers once the passphrase is accepted
# The first send must land after GRUB: any keypress at the menu cancels its
# countdown, which is what made a 12s default waste a whole attempt.
VM_UNLOCK_DELAY="${VM_UNLOCK_DELAY:-30}"    # first send, safely past GRUB
VM_UNLOCK_RESEND="${VM_UNLOCK_RESEND:-15}"  # re-send interval if it did not land
VM_UNLOCK_TIMEOUT="${VM_UNLOCK_TIMEOUT:-240}"

# Prefer an explicit VM_PASS so the passphrase can be kept out of the repo;
# vm_pass.txt is the committed default. First line only, newline stripped: the
# guest would otherwise receive a stray Enter mid-passphrase.
resolve_passphrase() {
	if [ -n "${VM_PASS:-}" ]; then
		printf '%s' "$VM_PASS"
		return 0
	fi
	if [ -r "$VM_PASS_FILE" ]; then
		head -n1 "$VM_PASS_FILE" | tr -d '\r\n'
		return 0
	fi
	echo "No passphrase: set VM_PASS or create $VM_PASS_FILE" >&2
	return 1
}

# Press and release. Sending only the make code leaves the key stuck down.
enter_scancode() { printf '1c 9c'; }

vm_state() {
	VBoxManage showvminfo "$VM_NAME" --machinereadable 2> /dev/null \
		| grep '^VMState=' | cut -d'"' -f2
}

get_vm_ssh_port() {
	VBoxManage showvminfo "$VM_NAME" --machinereadable 2> /dev/null \
		| grep '^Forwarding' | grep '"ssh,tcp,' | head -1 | cut -d, -f4
}

# Readiness = the guest's sshd answers with its banner. Deliberately not `ssh`:
# that needs working credentials, and we only want to know the VM finished booting.
# Uses bash's built-in /dev/tcp so this works without nc installed.
ssh_port_answers() {
	local port="$1" banner=""
	[ -n "$port" ] || return 1
	exec 3<> "/dev/tcp/127.0.0.1/$port" 2> /dev/null || return 1
	read -t 3 -r banner <&3 2> /dev/null
	exec 3<&- 3>&- 2> /dev/null
	case "$banner" in SSH-*) return 0 ;; *) return 1 ;; esac
}

send_passphrase() {
	local pass="$1"
	VBoxManage controlvm "$VM_NAME" keyboardputstring "$pass" > /dev/null 2>&1 || return 1
	# shellcheck disable=SC2046  # scancodes are intentionally split into args
	VBoxManage controlvm "$VM_NAME" keyboardputscancode $(enter_scancode) > /dev/null 2>&1
}

# Indirection so tests can stub the clock and run the loop instantly.
unlock_sleep() { sleep "$1"; }

# Poll for sshd continuously while re-sending the passphrase on a schedule.
# Polling and sending are interleaved deliberately: a send that misses the prompt
# then costs one resend interval instead of a whole boot timeout, so the exact
# moment the prompt appears stops mattering.
unlock_loop() {
	local port="$1" pass="$2"
	local elapsed=0 next_send="$VM_UNLOCK_DELAY" sends=0

	while [ "$elapsed" -lt "$VM_UNLOCK_TIMEOUT" ]; do
		if ssh_port_answers "$port"; then
			UNLOCK_SENDS=$sends
			return 0
		fi
		if [ "$elapsed" -ge "$next_send" ]; then
			send_passphrase "$pass" || return 1
			sends=$((sends + 1))
			next_send=$((elapsed + VM_UNLOCK_RESEND))
		fi
		unlock_sleep 2
		elapsed=$((elapsed + 2))
	done
	UNLOCK_SENDS=$sends
	return 1
}

main() {
	local pass port state

	pass=$(resolve_passphrase) || return 1
	state=$(vm_state)

	if [ "$state" != "running" ]; then
		echo "Starting $VM_NAME headless..."
		VBoxManage startvm "$VM_NAME" --type headless > /dev/null || {
			echo "Failed to start $VM_NAME" >&2
			return 1
		}
	fi

	port=$(get_vm_ssh_port)
	: "${port:=4242}"

	# Already booted past the prompt (e.g. VM was left running) -- nothing to type.
	if ssh_port_answers "$port"; then
		echo "✓ $VM_NAME already unlocked (ssh on :$port)"
		return 0
	fi

	echo "Waiting ${VM_UNLOCK_DELAY}s for the LUKS prompt, then unlocking..."
	if unlock_loop "$port" "$pass"; then
		echo "✓ $VM_NAME unlocked and booted (ssh on :$port, ${UNLOCK_SENDS} send(s))"
		return 0
	fi

	echo "✗ $VM_NAME did not come up within ${VM_UNLOCK_TIMEOUT}s." >&2
	echo "  See the console with: VBoxManage controlvm $VM_NAME screenshotpng /tmp/vm.png" >&2
	return 1
}

# Only run when executed, so tests can source this for the pure helpers.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	set -e
	main "$@"
fi
