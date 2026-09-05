#!/bin/bash
# Regression test for the QEMU host-port collision bug in setup/host/qemu_vm.sh.
#
# The bug it guards: PORTS_SPEC's host ports were used as-is, and QEMU's
# -netdev takes every hostfwd= as ONE argument -- so a single already-busy
# host port (a Docker container already had 3306 in the wild) failed the
# whole netdev and `make all` never booted the VM at all, instead of picking
# another port the way the VirtualBox NAT rules already do.
#
# qemu-system-x86_64 need not be installed to run this: qemu_vm.sh's own
# BASH_SOURCE guard skips both that check and the action dispatch when sourced.
set -e

cd "$(dirname "$0")/.."

fail=0
check() {
	if [ "$2" = "$3" ]; then
		printf 'ok   %-32s = %s\n' "$1" "$3"
	else
		printf 'FAIL %-32s = %s (expected %s)\n' "$1" "$2" "$3"
		fail=1
	fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

VM_NAME=debian
VM_PATH="$TMP"
PORTS_SPEC="ssh:4242:4242 mariadb:3306:3306 frontend:5173:5173"
export VM_NAME VM_PATH PORTS_SPEC

. ./setup/host/qemu_vm.sh

# Stub the host probe: pretend 3306 is already taken (the reproduced bug),
# everything else free -- same technique as tests/test_host_ports.sh.
is_host_port_free() {
	case "$1" in
		3306) return 1 ;;
		*) return 0 ;;
	esac
}

resolve_ports

ssh_host=$(printf '%s\n' "$RESOLVED_SPEC" | tr ' ' '\n' | awk -F: '$1=="ssh"{print $2}')
mariadb_host=$(printf '%s\n' "$RESOLVED_SPEC" | tr ' ' '\n' | awk -F: '$1=="mariadb"{print $2}')
frontend_host=$(printf '%s\n' "$RESOLVED_SPEC" | tr ' ' '\n' | awk -F: '$1=="frontend"{print $2}')

check "ssh keeps its preferred port"      "$ssh_host"      4242
check "mariadb bumps off the busy 3306"   "$mariadb_host"  3307
check "frontend keeps its preferred port" "$frontend_host" 5173

# The actual reproduction: the busy port must never reach QEMU's command line.
hostfwd=$(build_hostfwd)
case "$hostfwd" in
	*"127.0.0.1:3306-"*)
		printf 'FAIL %-32s hostfwd still offers the busy port: %s\n' "build_hostfwd" "$hostfwd"
		fail=1
		;;
	*"127.0.0.1:3307-:3306"*)
		printf 'ok   %-32s = bumped port present\n' "build_hostfwd"
		;;
	*)
		printf 'FAIL %-32s missing bumped port: %s\n' "build_hostfwd" "$hostfwd"
		fail=1
		;;
esac

# Once a VM is up, ports.env is authoritative: host_port_of must read it
# instead of re-probing (which would see the running QEMU's own listener).
mkdir -p "$VM_DIR"
printf 'ssh=4242\nmariadb=3307\nfrontend=5173\n' > "$VM_DIR/ports.env"
check "host_port_of reads ports.env (ssh)"     "$(host_port_of ssh)"     4242
check "host_port_of reads ports.env (mariadb)" "$(host_port_of mariadb)" 3307

exit "$fail"
