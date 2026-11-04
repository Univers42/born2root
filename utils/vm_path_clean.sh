#!/usr/bin/env hellish
# vm_path_clean.sh — what `make fclean` removes from VM_PATH.
#
# Profiles share one VM_PATH on a seat ([vm] path, /sgoinfre/students/$USER/
# virtual_machines): baas and inception lived side by side there, and fclean's
# `find VM_PATH -mindepth 1 -delete` meant `make re` on one silently deleted the
# other's disk. It removes this VM's directory and the shared ISOs, and keeps the
# .vm_path.* registry and any directory that is another machine.
#
# Caveat: "another machine" is read from its stamps and disk images. A directory
# holding neither, a VM that died before its disk was created, is removed.
#
#   vm_path_clean.sh <VM_PATH> <VM_NAME>
set -u

vm_path="${1:-}"
vm_name="${2:-}"
[ -n "$vm_path" ] && [ -n "$vm_name" ] || {
    printf 'usage: vm_path_clean.sh <VM_PATH> <VM_NAME>\n' >&2
    exit 2
}
[ -d "$vm_path" ] || exit 0

# One test per name, never one `ls` over the lot: a pattern matching nothing fails
# the whole ls, so a QEMU disk with no .vdi beside it read as "no machine here".
is_other_vm() {
    local marker
    [ -d "$1" ] && [ "${1##*/}" != "$vm_name" ] || return 1
    for marker in "$1/.built-on" "$1/.installed" "$1"/*.qcow2 "$1"/*.vdi; do
        [ -e "$marker" ] && return 0
    done
    return 1
}

for entry in "$vm_path"/* "$vm_path"/.[!.]*; do
    [ -e "$entry" ] || continue
    case "${entry##*/}" in .vm_path.*) continue ;; esac
    if is_other_vm "$entry"; then
        printf '  kept %s: it is another VM (make fclean VM_NAME=%s removes that one)\n' "$entry" "${entry##*/}"
        continue
    fi
    rm -rf -- "$entry"
done
