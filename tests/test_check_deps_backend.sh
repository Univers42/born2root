#!/usr/bin/env hellish
# Regression test for setup/install/check_deps.sh: `make deps` installs what
# the chosen backend needs, and nothing else.
#
# The failure it guards, from hellish's weekly VM job, both legs red:
#
#     make all BACKEND=qemu
#       ▶ VirtualBox is not installed. Setting up Oracle apt repository...
#       ▶ Running: sudo apt install virtualbox-7.1
#       ▶ apt will show the install plan — press Y to confirm.
#       make: *** [Makefile:198: all] Error 2
#
# in a container that had been given /dev/kvm and nothing else, with no
# terminal to press Y at. `make deps` checked for BOTH hypervisors and
# treated either one missing as a missing dependency, though `make all` runs
# on exactly one of them and says which. A hypervisor this build has chosen
# not to use is not missing; it is simply not installed.
#
# Everything here runs against a fabricated PATH: the tools check_deps.sh
# looks for are stubs in a temp directory, VirtualBox is absent because no
# stub is named VBoxManage, and `sudo` records that it was called instead of
# doing anything. So "did it try to install a hypervisor" is a file on disk,
# which is what the container saw.
set -e

cd "$(dirname "$0")/.."

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-44s = %s\n' "$1" "$3"
    else
        printf 'FAIL %-44s = %s (expected %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN"

# The tools the check looks for, present and pointless. dpkg answers for the
# one package it asks about by name; apt and sudo write down that they were
# reached, which is the whole question this test asks.
for t in xorriso curl cc python3 openssl git ssh make \
    qemu-system-x86_64 qemu-img; do
    printf '#!/bin/sh\nexit 0\n' >"$BIN/$t"
    chmod +x "$BIN/$t"
done
printf '#!/bin/sh\necho "Status: install ok installed"\n' >"$BIN/dpkg"
printf '#!/bin/sh\nexit 0\n' >"$BIN/apt"
printf '#!/bin/sh\necho "$*" >> "%s/sudo.log"\nexit 1\n' "$TMP" >"$BIN/sudo"
chmod +x "$BIN/dpkg" "$BIN/apt" "$BIN/sudo"
# Real ones the script's plumbing uses -- symlinked, so their own mode is
# what runs and nothing here has to chmod a file it does not own. getent is
# deliberately NOT provided: check_group_membership returns early without
# it, so no run of this test can offer to change a group on this machine.
for t in grep sed awk tr id; do
    real=$(command -v "$t" 2>/dev/null) && ln -sf "$real" "$BIN/$t"
done

# A KVM device this test owns, so "can this machine run QEMU" is a fact of
# the fixture and not of the machine the test happens to run on.
KVM_YES="$TMP/kvm"
: >"$KVM_YES"
KVM_NO="$TMP/no-kvm"

# check_deps.sh is run by whatever shell is running this test -- read off
# /proc rather than guessed -- so the corpus gate checks the dependency rule
# under hellish and under bash, not bash twice.
SHELL_UNDER_TEST="${SHELL_UNDER_TEST:-$(readlink /proc/$$/exe)}"
[ -x "$SHELL_UNDER_TEST" ] || SHELL_UNDER_TEST=$(command -v bash)

deps() {
    # usage: deps <BACKEND> <kvm-device>   -> prints the exit status
    rm -f "$TMP/sudo.log"
    set +e
    env -i PATH="$BIN" HOME="$TMP" BACKEND="$1" KVM_DEV="$2" \
        "$SHELL_UNDER_TEST" setup/install/check_deps.sh >"$TMP/out" 2>&1
    printf '%s' "$?"
    set -e
}

tried_install() {
    if [ -s "$TMP/sudo.log" ]; then
        echo yes
    else
        echo no
    fi
}

# ── BACKEND=qemu: VirtualBox is not a dependency, and not a failure ────────
check "qemu, no VirtualBox: status" "$(deps qemu "$KVM_YES")" 0
check "qemu, no VirtualBox: installed nothing" "$(tried_install)" no
check "qemu: says why VirtualBox is absent" \
    "$(grep -c 'not needed' "$TMP/out")" 1

# ── BACKEND=auto with a usable KVM: same answer, without being told ───────
check "auto with KVM: status" "$(deps auto "$KVM_YES")" 0
check "auto with KVM: installed nothing" "$(tried_install)" no

# ── BACKEND=auto with no KVM: VirtualBox is the only way to run a VM here,
#    so it IS a dependency, and the install path is entered as it always was
check "auto without KVM: tries to install VirtualBox" \
    "$(
        deps auto "$KVM_NO" >/dev/null
        tried_install
    )" yes

# ── BACKEND=virtualbox: asked for by name, required even where KVM works ──
check "virtualbox: tries to install it even with KVM" \
    "$(
        deps virtualbox "$KVM_YES" >/dev/null
        tried_install
    )" yes

exit "$fail"
