#!/bin/bash
# Regression test for utils/vbox_driver.sh.
#
# The bug it guards, reproduced deterministically on a real machine:
# `lsmod | grep -q '^vboxdrv'` under `set -o pipefail` returned exit 141
# (SIGPIPE) 100% of the time, even though the module WAS loaded -- grep -q
# closes its end of the pipe the instant it matches, and if lsmod is still
# writing the rest of its listing at that moment pipefail reports lsmod's
# SIGPIPE death instead of grep's success. select_backend.sh and
# check_vbox_driver.sh both silently switched to "not loaded" because of it.
#
# It also guards the second, independent bug found on the same machine: a
# device that exists with its module loaded can still be unusable because
# /dev/vboxdrv is root:root instead of root:vboxusers -- "exists + loaded"
# alone is not "usable".
set -e

cd "$(dirname "$0")/.."

fail=0
check() {
	if [ "$2" = "$3" ]; then
		printf 'ok   %-38s = %s\n' "$1" "$3"
	else
		printf 'FAIL %-38s = %s (expected %s)\n' "$1" "$2" "$3"
		fail=1
	fi
}

# `if <fn>; then` is exempt from `set -e`, unlike a bare statement -- so an
# intentionally-failing probe below never aborts the test itself.
yesno() { if "$@"; then echo yes; else echo no; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

. ./utils/vbox_driver.sh

# ── The SIGPIPE regression: a big /proc/modules-shaped file, vboxdrv near
# the end, read under pipefail. The old `lsmod | grep -q` pattern died here.
big_modules="$TMP/modules"
{
	i=0
	while [ "$i" -lt 300 ]; do
		printf 'decoy_module_%d 16384 0 - Live 0x0000000000000000\n' "$i"
		i=$((i + 1))
	done
	printf 'vboxdrv 712704 2 vboxnetadp,vboxnetflt Live 0x0000000000000000\n'
} > "$big_modules"

VBOXDRV_PROC_MODULES="$big_modules"
set -o pipefail
check "vboxdrv_loaded survives pipefail (present)" "$(yesno vboxdrv_loaded)" yes
set +o pipefail

empty_modules="$TMP/modules_empty"
: > "$empty_modules"
VBOXDRV_PROC_MODULES="$empty_modules"
check "vboxdrv_loaded (absent)" "$(yesno vboxdrv_loaded)" no

# ── vboxdrv_ok / vboxdrv_why branch coverage, via function overrides (same
# technique tests/test_host_ports.sh uses for is_host_port_free).
vboxdrv_device_exists() { return 1; }
check "no device: ok"  "$(yesno vboxdrv_ok)" no
check "no device: why" "$(vboxdrv_why)" "installed, but /dev/vboxdrv does not exist -- vboxdrv kernel module not loaded (needs root)"

vboxdrv_device_exists() { return 0; }
vboxdrv_loaded() { return 1; }
check "not loaded: ok"  "$(yesno vboxdrv_ok)" no
check "not loaded: why" "$(vboxdrv_why)" "installed, but the vboxdrv kernel module is not loaded (needs root)"

vboxdrv_loaded() { return 0; }
vboxdrv_accessible() { return 1; }
check "permission denied: ok" "$(yesno vboxdrv_ok)" no
case "$(vboxdrv_why)" in
	*"not readable/writable"*) printf 'ok   %-38s\n' "permission denied: why mentions it" ;;
	*) printf 'FAIL %-38s = %s\n' "permission denied: why" "$(vboxdrv_why)"; fail=1 ;;
esac

vboxdrv_accessible() { return 0; }
check "fully usable: ok"  "$(yesno vboxdrv_ok)" yes
check "fully usable: why" "$(vboxdrv_why)" "ready"

# ── Hardened vs developer build, against the REAL vboxdrv_accessible ────────
# The regression this pins down: a hardened install leaves /dev/vboxdrv
# root:root 0600 on purpose, because VirtualBoxVM is set-uid root and opens the
# driver itself. Demanding user r/w there declared a perfectly working
# VirtualBox unusable, so `make all` stopped offering it and silently built on
# the other hypervisor instead. Fixture dirs stand in for /usr/lib/virtualbox.
unset -f vboxdrv_accessible vboxdrv_hardened
eval "$(sed -n '/^vboxdrv_hardened()/,/^}/p;/^vboxdrv_accessible()/,/^}/p' ./utils/vbox_driver.sh)"

hardened="$TMP/lib-hardened"; mkdir -p "$hardened"
printf '#!/bin/sh\n' > "$hardened/VirtualBoxVM"; chmod 4711 "$hardened/VirtualBoxVM"

developer="$TMP/lib-developer"; mkdir -p "$developer"
printf '#!/bin/sh\n' > "$developer/VirtualBoxVM"; chmod 0755 "$developer/VirtualBoxVM"

VBOX_LIB_DIR="$hardened"
check "hardened: detected"                "$(yesno vboxdrv_hardened)"  yes
check "hardened: accessible without r/w"  "$(yesno vboxdrv_accessible)" yes
check "hardened: ok"                      "$(yesno vboxdrv_ok)"         yes
check "hardened: why"                     "$(vboxdrv_why)"              "ready"

# Developer build with an unreadable device must still report the real problem:
# there, vboxusers membership genuinely is the fix.
VBOX_LIB_DIR="$developer"
check "developer: not hardened" "$(yesno vboxdrv_hardened)" no
unreadable="$TMP/no-such-device"
vboxdrv_accessible() { vboxdrv_hardened && return 0; [ -r "$unreadable" ] && [ -w "$unreadable" ]; }
check "developer: unreadable device is NOT ok" "$(yesno vboxdrv_ok)" no
case "$(vboxdrv_why)" in
	*"vboxusers"*) printf 'ok   %-46s\n' "developer: why still says join vboxusers" ;;
	*) printf 'FAIL %-46s = %s\n' "developer: why" "$(vboxdrv_why)"; fail=1 ;;
esac

exit "$fail"
