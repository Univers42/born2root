#!/usr/bin/env hellish
# Regression test: one host path, many machines.
#
# THE PROBLEM IT PINS
#   profiles/server.toml named /mnt/storage/virtual_machines and
#   /mnt/storage/b2b-backups/baas: right on the seat that built baas, absent
#   on a 42 seat, where the same profile has to rebuild it from nothing.
#   vm.path and [dc] backup_dest now take a list, and the first entry that
#   exists and is writable is the one used; when none exists yet, the first
#   one that can be created. $USER and $HOME are the host login and home,
#   expanded in ONE place (utils/host_path.py) for vm.path, backup_dest,
#   [dc] secrets_file and a BACKUP_DEST= given by hand.
set -u
cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." || exit 1

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-60s = %s\n' "$1" "$2"
    else
        printf 'FAIL %-60s = %s (expected %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}

TMP=$(mktemp -d)
trap 'chmod -R u+w "${TMP:?}" 2>/dev/null; rm -rf "${TMP:?}"' EXIT
CFG=("${SCRIPT_SH:-bash}" utils/b2b_config.sh)
login=$(id -un)
resolve() { env HOME="$TMP/home" "${CFG[@]}" --host-path "$@"; }

# ── the primitive ───────────────────────────────────────────────────────────
mkdir -p "$TMP/home" "$TMP/exists" "$TMP/later-exists" "$TMP/ro"
# shellcheck disable=SC2016 # the literal placeholders are the input
check "\$USER is the host login" "$(resolve '/x/$USER/vms')" "/x/$login/vms"
# shellcheck disable=SC2016
check "\${USER} too" "$(resolve '/x/${USER}/vms')" "/x/$login/vms"
# shellcheck disable=SC2016
check "\$HOME is the host home" "$(resolve '$HOME/vms')" "$TMP/home/vms"
# shellcheck disable=SC2016
check "\${HOME} too" "$(resolve '${HOME}/vms')" "$TMP/home/vms"
check "a plain path is itself, existing or not" "$(resolve /nowhere/at/all)" /nowhere/at/all
check "empty stays empty (the caller's default applies)" "$(resolve '')" ""
check "a list: the first entry that exists and is writable" \
    "$(resolve "$TMP/absent/a" "$TMP/exists" "$TMP/later-exists")" "$TMP/exists"
check "a list: an existing entry beats a creatable one before it" \
    "$(resolve "$TMP/home/new" "$TMP/later-exists")" "$TMP/later-exists"
check "a list, none exists: the first one that can be created" \
    "$(resolve /proc/nope/a "$TMP/home/new/deeper" "$TMP/other")" "$TMP/home/new/deeper"
check "a list, nothing usable: the first entry, so the error names it" \
    "$(resolve /proc/nope/a /proc/nope/b)" /proc/nope/a
if [ "$(id -u)" != 0 ]; then
    chmod 555 "$TMP/ro"
    check "a list: an existing but read-only entry is skipped" \
        "$(resolve "$TMP/ro" "$TMP/exists")" "$TMP/exists"
    check "a list: nothing creatable under a read-only parent" \
        "$(resolve "$TMP/ro/sub" "$TMP/home/made")" "$TMP/home/made"
else
    echo "skip: running as root, no directory is read-only"
fi

# ── through the profile ─────────────────────────────────────────────────────
profile() { # <vm.path value> <backup_dest value> -> path
    sed -e "s|^path    = \"\"|path    = $1|" -e "s|^backup_dest = \"\"|backup_dest = $2|" \
        tests/fixtures/default.toml >"$TMP/p.toml"
    printf '%s' "$TMP/p.toml"
}
P=$(profile "[\"/proc/nope/vms\", \"$TMP/exists\"]" "[\"/proc/nope/b\", \"$TMP/later-exists\"]")
get() { env HOME="$TMP/home" B2B_CONFIG="$P" "${CFG[@]}" get "$1"; }
check "get B2B_VM_PATH resolves the list" "$(get B2B_VM_PATH)" "$TMP/exists"
check "get B2B_DC_BACKUP_DEST resolves the list" "$(get B2B_DC_BACKUP_DEST)" "$TMP/later-exists"
check "a profile with lists validates" \
    "$(env B2B_CONFIG="$P" "${CFG[@]}" --check >/dev/null 2>&1 && echo 0 || echo 1)" 0
# shellcheck disable=SC2016
P=$(profile '"$HOME/vms"' '"/sgoinfre/$USER/b"')
check "get B2B_VM_PATH expands \$HOME in a single string" "$(get B2B_VM_PATH)" "$TMP/home/vms"
check "get B2B_DC_BACKUP_DEST expands \$USER in a single string" "$(get B2B_DC_BACKUP_DEST)" "/sgoinfre/$login/b"
check "\$HOME/... validates as absolute" \
    "$(env B2B_CONFIG="$P" "${CFG[@]}" --check >/dev/null 2>&1 && echo 0 || echo 1)" 0
P=$(profile '["/a", "relative/b"]' '""')
rc=0
out=$(env B2B_CONFIG="$P" "${CFG[@]}" --check 2>&1) || rc=$?
check "a relative entry in the list is refused" "$rc" 1
case "$out" in
*"vm.path[1]"*) printf 'ok   %-60s\n' "... naming vm.path[1]" ;;
*)
    printf 'FAIL ... the refusal does not name vm.path[1]: %s\n' "$out"
    fail=1
    ;;
esac
P=$(profile '["/a", 3]' '""')
check "a non-text entry is refused" \
    "$(env B2B_CONFIG="$P" "${CFG[@]}" --check >/dev/null 2>&1 && echo 0 || echo 1)" 1

# ── backup_pull.sh asks the same helper ─────────────────────────────────────
where() { env HOME="$TMP/home" B2B_CONFIG="$P" VM_NAME=vm1 BACKUP_DEST="$1" "${SCRIPT_SH:-bash}" setup/host/backup_pull.sh --where; }
P=$(profile '""' "[\"/proc/nope/b\", \"$TMP/later-exists\"]")
check "backup_pull.sh --where: the profile's list, resolved" "$(where '')" "$TMP/later-exists"
# shellcheck disable=SC2016
check "backup_pull.sh --where: BACKUP_DEST with a literal \$USER" "$(where '/media/$USER/b')" "/media/$login/b"
check "the expansion lives in one place, not in backup_pull.sh" \
    "$(grep -c 'DEST//' setup/host/backup_pull.sh)" 0

exit "$fail"
