#!/usr/bin/env hellish
# Pins utils/vm_path_clean.sh, what `make fclean` removes from VM_PATH.
#
# The bug it pins down: fclean emptied VM_PATH, and on a seat every profile shares
# one. With baas and inception side by side in /sgoinfre/students/$USER/
# virtual_machines (2026-11-04), `make re` on either deleted the other's disk.
set -u
cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." || exit 1
fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s -- got: %s, expected: %s\n' "$1" "$2" "$3"
        fail=1
    fi
}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
V="$T/vms"
mkdir -p "$V/baas" "$V/inception" "$V/iso" "$V/stamped" "$V/half"
touch "$V/baas/baas.qcow2" "$V/baas/.built-on" "$V/inception/inception.qcow2" "$V/iso/x.iso" \
    "$V/stamped/.installed" "$V/.vm_path.baas" "$V/.stray" "$V/loose.log"

out=$("${SCRIPT_SH:-bash}" utils/vm_path_clean.sh "$V" baas)
check "exit 0" "$?" 0
check "this VM goes" "$([ -e "$V/baas" ] && echo there || echo gone)" gone
check "another VM's disk stays" "$([ -e "$V/inception/inception.qcow2" ] && echo kept)" kept
check "a VM with stamps and no disk yet stays" "$([ -e "$V/stamped/.installed" ] && echo kept)" kept
check "... and it says so" "$(printf '%s\n' "$out" | grep -c 'it is another VM')" 2
check "the shared ISOs go" "$([ -e "$V/iso" ] && echo there || echo gone)" gone
check "a directory that is no machine goes" "$([ -e "$V/half" ] && echo there || echo gone)" gone
check "loose and hidden files go" "$([ -e "$V/loose.log" ] || [ -e "$V/.stray" ] && echo there || echo gone)" gone
check "the registry stays" "$([ -e "$V/.vm_path.baas" ] && echo kept)" kept
check "no path: refused" "$(
    "${SCRIPT_SH:-bash}" utils/vm_path_clean.sh "" baas 2>/dev/null
    echo $?
)" 2
check "no name: refused, nothing removed" "$(
    "${SCRIPT_SH:-bash}" utils/vm_path_clean.sh "$V" "" 2>/dev/null
    echo "$? $(find "$V" -mindepth 1 -maxdepth 1 ! -name '.*' | wc -l)"
)" "2 2"
check "fclean goes through it" "$(grep -c 'utils/vm_path_clean.sh' Makefile)" 1
# shellcheck disable=SC2016 # the Makefile's own text, $(VM_PATH) included
check "and nothing else in the Makefile empties VM_PATH" "$(grep -c 'find "$(VM_PATH)"' Makefile)" 0
exit "$fail"
