#!/bin/bash
# Regression test for utils/vm_path.sh.
#
# The bug it guards: VM_PATH=/mnt/storage/qemu, whose parent is root-owned,
# made `make all` build the ISO for minutes and then die on a bare
# "mkdir: cannot create directory: Permission denied" from the disk step --
# not a word about who owns what or what to do. People reached for
# `sudo make all`, which then left a root-owned disk, pidfile and monitor
# socket that no later `make qemu_stop` without sudo could read.
#
# Root-owned directories are simulated with chmod 555 on directories we own,
# and sudo with a script that logs what it was asked, unlocks the parent (what
# root could do) and runs the command as this user.
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
yesno() { if "$@"; then echo yes; else echo no; fi; }
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

TMP=$(mktemp -d)
trap 'chmod -R u+w "$TMP" 2> /dev/null; rm -rf "$TMP"' EXIT

. ./utils/vm_path.sh
who="$(id -un):$(id -gn)"

# No terminal in a test, unless a case says otherwise.
vm_path_can_ask() { return 1; }

# ── Directories the user can write: no sudo, no noise ───────────────────────
mkdir -p "$TMP/own"
out=$(ensure_vm_dir "$TMP/own" debian 2>&1) && rc=0 || rc=$?
check "writable VM_PATH: ok"                      "$rc" 0
check "writable VM_PATH: VM dir created"          "$(yesno test -d "$TMP/own/debian")" yes
check "writable VM_PATH: silent"                  "$out" ""

out=$(ensure_vm_dir "$TMP/new/deeper" debian 2>&1) && rc=0 || rc=$?
check "absent but creatable: ok"                  "$rc" 0
check "absent but creatable: created"             "$(yesno test -d "$TMP/new/deeper/debian")" yes

if [ "$(id -u)" = 0 ]; then
	echo "skip: running as root, no directory is unwritable"
	exit "$fail"
fi

# ── Root-owned parent, no terminal: explain, print the recipe, change nothing
mkdir -p "$TMP/locked"; chmod 555 "$TMP/locked"
out=$(ensure_vm_dir "$TMP/locked/qemu" debian 2>&1) && rc=0 || rc=$?
check "locked parent, no tty: fails"              "$rc" 1
check "names the directory in the way"            "$(has "$out" "$TMP/locked belongs to")" yes
check "says it is a permission problem"           "$(has "$out" "permission problem")" yes
check "exact sudo mkdir"                          "$(has "$out" "sudo mkdir -p \"$TMP/locked/qemu/debian\"")" yes
check "exact sudo chown -R of the VM dir"         "$(has "$out" "sudo chown -R \"$who\" \"$TMP/locked/qemu/debian\"")" yes
check "hands over the VM_PATH it would create"    "$(has "$out" "sudo chown \"$who\" \"$TMP/locked/qemu\"")" yes
check "nothing was created"                       "$(yesno test -e "$TMP/locked/qemu")" no

# ── No sudo on this machine: say so, never try ──────────────────────────────
vm_path_can_ask() { return 0; }
VM_PATH_SUDO=/nonexistent/sudo
out=$(ensure_vm_dir "$TMP/locked/qemu" debian 2>&1) && rc=0 || rc=$?
check "no sudo: fails"                            "$rc" 1
check "no sudo: says ask an administrator"        "$(has "$out" "administrator")" yes
check "no sudo: recipe has no sudo prefix"        "$(has "$out" "sudo mkdir")" no

# ── sudo and a terminal, user declines: nothing runs ───────────────────────
VM_PATH_SUDO="$TMP/fakesudo"
cat > "$VM_PATH_SUDO" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "${FAKESUDO_LOG:?}"
chmod 755 "${FAKESUDO_UNLOCK:?}"
exec "$@"
FAKE
chmod +x "$VM_PATH_SUDO"
export FAKESUDO_LOG="$TMP/sudo.log" FAKESUDO_UNLOCK="$TMP/locked"
vm_path_ask() { return 1; }
out=$(ensure_vm_dir "$TMP/locked/qemu" debian 2>&1) && rc=0 || rc=$?
check "declined: fails"                           "$rc" 1
check "declined: sudo never ran"                  "$(yesno test -e "$FAKESUDO_LOG")" no
check "declined: nothing created"                 "$(yesno test -e "$TMP/locked/qemu")" no

# ── User accepts: what was printed is exactly what runs ────────────────────
vm_path_ask() { return 0; }
out=$(ensure_vm_dir "$TMP/locked/qemu" debian 2>&1) && rc=0 || rc=$?
check "accepted: ok"                              "$rc" 0
check "accepted: VM dir usable"                   "$(yesno _vm_path_writable "$TMP/locked/qemu/debian")" yes
check "accepted: sudo ran mkdir"                  "$(has "$(cat "$FAKESUDO_LOG")" "mkdir -p \"$TMP/locked/qemu/debian\"")" yes
check "accepted: sudo ran chown -R"               "$(has "$(cat "$FAKESUDO_LOG")" "chown -R \"$who\"")" yes
check "accepted: exactly the 3 printed commands"  "$(wc -l < "$FAKESUDO_LOG")" 3
check "accepted: reports success"                 "$(has "$out" "now belongs to")" yes

# ── The `sudo make all` leftover: VM dir exists but belongs to someone else
mkdir -p "$TMP/own/foreign"; chmod 555 "$TMP/own/foreign"
vm_path_can_ask() { return 1; }
out=$(ensure_vm_dir "$TMP/own" foreign 2>&1) && rc=0 || rc=$?
check "foreign VM dir: fails"                     "$rc" 1
check "foreign VM dir: says exists but belongs to" "$(has "$out" "exists but belongs to")" yes
check "foreign VM dir: chown -R offered"          "$(has "$out" "sudo chown -R \"$who\" \"$TMP/own/foreign\"")" yes
check "foreign VM dir: existing VM_PATH untouched" "$(has "$out" "chown \"$who\" \"$TMP/own\"")" no

exit "$fail"
