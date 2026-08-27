#!/bin/bash
# Tests for the passphrase resolution in unlock_vm.sh.
#
# Only the pure part is covered here: picking the passphrase and the Enter
# keystroke. Starting a VM and typing into it needs a real VM, and is covered by
# actually running `make start_vm`.
set -e

cd "$(dirname "$0")/.."

fail=0
check() {
	if [ "$2" = "$3" ]; then
		printf 'ok   %-34s = %s\n' "$1" "$3"
	else
		printf 'FAIL %-34s = %s (expected %s)\n' "$1" "$2" "$3"
		fail=1
	fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Sourcing must only define functions, never start a VM.
VM_PASS="" VM_PASS_FILE="$TMP/none" . ./unlock_vm.sh

# Explicit override wins over the file.
printf 'from-file\n' > "$TMP/pass"
check "VM_PASS overrides file" \
	"$(VM_PASS=from-env VM_PASS_FILE=$TMP/pass resolve_passphrase)" "from-env"

# Falls back to the file, and the trailing newline must not be typed into the prompt.
check "falls back to file" \
	"$(VM_PASS='' VM_PASS_FILE=$TMP/pass resolve_passphrase)" "from-file"

printf 'crlf-pass\r\n' > "$TMP/crlf"
check "strips CR and LF" \
	"$(VM_PASS='' VM_PASS_FILE=$TMP/crlf resolve_passphrase)" "crlf-pass"

# Only the first line: a stray second line must not leak into the passphrase.
printf 'first\nsecond\n' > "$TMP/multi"
check "uses first line only" \
	"$(VM_PASS='' VM_PASS_FILE=$TMP/multi resolve_passphrase)" "first"

# No passphrase anywhere is an error, not an empty string typed at the prompt.
if VM_PASS='' VM_PASS_FILE="$TMP/missing" resolve_passphrase > /dev/null 2>&1; then
	printf 'FAIL %-34s = succeeded (expected failure)\n' "errors when no passphrase"
	fail=1
else
	printf 'ok   %-34s\n' "errors when no passphrase"
fi

# Enter must be press *and* release, or the guest sees a stuck key.
check "enter scancode is make+break" "$(enter_scancode)" "1c 9c"

# --- unlock_loop scheduling -------------------------------------------------
# Stub the clock, the port probe and the send so the loop runs instantly and
# records exactly when it would have typed the passphrase.
unlock_sleep() { :; }
SENT_AT=""
NOW=0
send_passphrase() { SENT_AT="$SENT_AT $NOW"; }
# ssh answers only at/after $SSH_UP_AT; NOW advances with the loop.
ssh_port_answers() { NOW=$((NOW + 0)); [ "$NOW" -ge "$SSH_UP_AT" ]; }

run_loop() {
	SENT_AT=""; NOW=0; UNLOCK_SENDS=0
	SSH_UP_AT="$1"
	VM_UNLOCK_DELAY="$2" VM_UNLOCK_RESEND="$3" VM_UNLOCK_TIMEOUT="$4"
	# Drive the clock: wrap sleep so each tick advances NOW like the real loop.
	unlock_sleep() { NOW=$((NOW + 2)); }
	unlock_loop 4242 "pw"
}

# Nothing is typed before VM_UNLOCK_DELAY -- typing early lands in GRUB and
# cancels its countdown, which is the bug this default exists to avoid.
run_loop 999 30 15 60 || true
first_send=$(echo "$SENT_AT" | awk '{print $1}')
check "first send waits past GRUB" "$first_send" "30"

# A missed send is retried one interval later, not one boot-timeout later.
run_loop 999 30 15 80 || true
second_send=$(echo "$SENT_AT" | awk '{print $2}')
check "re-sends after resend interval" "$second_send" "46"

# Already-up SSH means the passphrase is never typed at all.
run_loop 0 30 15 60 && ok=yes || ok=no
check "no send when ssh already up" "${SENT_AT:-<none>}" "<none>"
check "returns success when ssh up" "$ok" "yes"

# Gives up rather than looping forever.
if run_loop 999 30 15 40; then
	printf 'FAIL %-34s = succeeded (expected timeout)\n' "times out cleanly"
	fail=1
else
	printf 'ok   %-34s\n' "times out cleanly"
fi

exit "$fail"
