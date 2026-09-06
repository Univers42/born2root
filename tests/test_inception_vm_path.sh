#!/bin/bash
# Regression test for the Inception targets' VM_PATH.
#
# The bug it guards: `make all VM_PATH=/some/where` records the location in
# disk_images/.vm_path.<vm> so that no later target needs VM_PATH on the
# command line ("An explicit VM_PATH always wins", Makefile). make resolved
# it fine for `make inception` -- but only as a make variable: a value the
# Makefile computes is not exported to a recipe's environment (only
# command-line and environment variables are), and setup/host/vm_ports.sh
# reads $VM_PATH from the ENVIRONMENT to find <vm>/ports.env, QEMU's record
# of its hostfwd map. So verify_inception_access.sh looked under the default
# disk_images/, found no ports.env, and reported "no 'https' NAT rule" on a
# QEMU guest whose port 8443 answered 200 two checks later. The QEMU targets
# had always prefixed their recipes with VM_PATH="$(VM_PATH)"; the four
# Inception targets predate them and never did.
#
# Nothing here starts a VM or touches the network: make -n renders the
# recipes, and the resolver reads a ports.env this test wrote.
set -e

cd "$(dirname "$0")/.."

fail=0
check() {
	if [ "$2" = "$3" ]; then
		printf 'ok   %-46s = %s\n' "$1" "$2"
	else
		printf 'FAIL %-46s = %s (expected %s)\n' "$1" "$2" "$3"
		fail=1
	fi
}

TMP=$(mktemp -d)
VM="t-$$"
# make reads the recorded location from the real disk_images/: a throwaway
# name keeps this record away from any real VM's, and the trap removes it.
mkdir -p disk_images "$TMP/vm/$VM"
printf '%s\n' "$TMP/vm" > "disk_images/.vm_path.$VM"
trap 'rm -f "disk_images/.vm_path.$VM"; rm -rf "$TMP"' EXIT
printf 'https=8443\ninception-static=8090\n' > "$TMP/vm/$VM/ports.env"

# 1. Every Inception recipe hands the RECORDED VM_PATH to its script, with
#    nothing on the command line. The temp path is replaced by a fixed token
#    so the output is the same run to run and shell to shell.
for t in inception verify_access host_access host_access_undo; do
	got=$(make -n "$t" VM_NAME="$VM" SRC=/x 2>/dev/null | grep -o 'VM_PATH="[^"]*"' | head -1)
	check "make $t exports the recorded VM_PATH" "${got//"$TMP"/TMP}" 'VM_PATH="TMP/vm"'
done

# 2. With that in the environment, the resolver finds QEMU's forwards.
export VM_NAME="$VM" VM_PATH="$TMP/vm"
# shellcheck source=setup/host/vm_ports.sh
. ./setup/host/vm_ports.sh
check "vm_forward_port https" "$(vm_forward_port https)" 8443
check "vm_forward_port inception-static" "$(vm_forward_port inception-static)" 8090
check "vm_backend" "$(vm_backend)" qemu

exit $fail
