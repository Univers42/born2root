#!/usr/bin/env hellish
# Is the VM storage directory usable by the calling user -- and if not, WHY,
# and what exactly fixes it?
#
# Everything both backends write lives under $VM_PATH/$VM_NAME: the disk image,
# the pidfile, the monitor socket, serial.log, the stamps. When VM_PATH points
# at an external disk (VM_PATH=/mnt/storage/qemu) its parent is usually owned
# by root, and `make all` used to spend minutes building the ISO and then die
# on a bare "mkdir: cannot create directory: Permission denied" from deep
# inside the disk step -- no word about who owns what, or what to do. The way
# out people found was `sudo make all`, which works once and then leaves a
# root-owned disk, pidfile and monitor socket behind that no later
# `make qemu_stop` without sudo can read.
#
# This checks up front and, when the directory is not usable, names the
# directory that is in the way and who owns it. Then -- only when it IS a
# permission problem, only when sudo exists, only when a terminal is attached --
# it offers to run the exact commands it has just printed. Non-interactive
# callers and machines without sudo get those commands to run themselves.
# sudo is never used by default: on many machines the user does not have it.
#
# Sourced by setup/host/qemu_vm.sh and setup/install/vms/install_vm_debian.sh
# (the two places a VM directory is created), and run as a command by the
# Makefile before either pipeline starts, so the answer arrives before the ISO
# build rather than after it:
#
#   . utils/vm_path.sh; ensure_vm_dir "$VM_PATH" "$VM_NAME"
#   utils/vm_path.sh "$VM_PATH" "$VM_NAME"
#   utils/vm_path.sh --no-root "make all VM_PATH=..."   (refuse_sudo_build)

# Overridable so tests/test_vm_path.sh can stand in a fake sudo; production
# callers never set it.
VM_PATH_SUDO="${VM_PATH_SUDO:-sudo}"

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    _VP_RED=$'\033[31m' _VP_GRN=$'\033[32m' _VP_OFF=$'\033[0m'
else
    _VP_RED='' _VP_GRN='' _VP_OFF=''
fi

# Can we ask the user anything? /dev/tty always exists as a file, but OPENING
# it fails without a controlling terminal (cron, CI, a detached make) -- and
# that is the case this guards. Overridden by the tests.
vm_path_can_ask() { { : </dev/tty; } 2>/dev/null; }

# Yes/no on the terminal; 0 = yes. Enter means yes: the user has just read
# the exact commands and is sitting there. Overridden by the tests.
vm_path_ask() {
    local ans
    printf '    %s [Y/n]: ' "$1" >/dev/tty
    IFS= read -r ans </dev/tty || ans=""
    case "$ans" in '' | [Yy]*) return 0 ;; *) return 1 ;; esac
}

_vm_path_writable() { [ -d "$1" ] && [ -w "$1" ] && [ -x "$1" ]; }

# The nearest ancestor of $1 that exists: the directory whose permissions
# actually decide whether $1 can be created.
_vm_path_blocker() {
    local p=$1
    while [ ! -e "$p" ] && [ "$p" != / ]; do
        p=$(dirname "$p")
    done
    printf '%s' "$p"
}

# The commands that make $2 usable, one per line, without any sudo prefix.
# ONE source of truth: what is shown to the user is what gets run.
#
# You own what this creates: the VM directory (recursively -- everything in it
# is this VM's), and VM_PATH itself only if it does not exist yet. A VM_PATH
# that already exists and belongs to someone else (/mnt/storage) is left as it
# is; a second VM_NAME under it simply asks again.
_vm_path_recipe() {
    local vm_path=$1 vm_dir=$2 who
    who="$(id -un):$(id -gn)"
    printf 'mkdir -p "%s"\n' "$vm_dir"
    [ -d "$vm_path" ] || printf 'chown "%s" "%s"\n' "$who" "$vm_path"
    printf 'chown -R "%s" "%s"\n' "$who" "$vm_dir"
}

_vm_path_alternative() {
    printf '    Or build somewhere you already own:   VM_PATH=%s make all\n' "$HOME/vms"
}

# ensure_vm_dir VM_PATH VM_NAME
# 0 when $VM_PATH/$VM_NAME exists and the calling user can write in it,
# creating it when the filesystem allows. Otherwise the situation is explained
# on stderr and the return is 1: "not usable, and here is what to do".
# On success the location is remembered (remember_vm_dir, below).
ensure_vm_dir() {
    _ensure_vm_dir "$1" "$2" || return 1
    remember_vm_dir "$(cd "$1" && pwd)" "$2"
}

_ensure_vm_dir() {
    local vm_path=$1 vm_dir=$1/$2 blocker me line lines

    if _vm_path_writable "$vm_dir"; then
        return 0
    elif [ ! -e "$vm_dir" ] && mkdir -p "$vm_dir" 2>/dev/null; then
        return 0
    fi

    me=$(id -un)
    {
        printf '  %s✗%s VM storage %s is not usable by %s\n' "$_VP_RED" "$_VP_OFF" "$vm_dir" "$me"
        if [ -d "$vm_dir" ]; then
            printf '    it exists but belongs to %s (%s)\n' \
                "$(stat -c %U:%G "$vm_dir")" "$(stat -c %A "$vm_dir")"
            printf '    (built with "sudo make all"? then its disk, pidfile and monitor socket are root-owned too)\n'
        else
            blocker=$(_vm_path_blocker "$vm_dir")
            printf '    it cannot be created: %s belongs to %s (%s)\n' \
                "$blocker" "$(stat -c %U:%G "$blocker")" "$(stat -c %A "$blocker")"
        fi
        printf '    This is a permission problem, not a build failure: fixing it needs root.\n'
    } >&2

    if ! command -v "$VM_PATH_SUDO" >/dev/null 2>&1; then
        {
            printf '    sudo is not available here. Ask an administrator to run, as root:\n'
            _vm_path_recipe "$vm_path" "$vm_dir" | sed 's/^/        /'
            _vm_path_alternative
        } >&2
        return 1
    fi

    if ! vm_path_can_ask; then
        {
            printf '    No terminal to ask on. Run these once, then retry:\n'
            _vm_path_recipe "$vm_path" "$vm_dir" | sed 's/^/        sudo /'
            _vm_path_alternative
        } >&2
        return 1
    fi

    {
        printf '    With your permission this will run:\n'
        _vm_path_recipe "$vm_path" "$vm_dir" | sed 's/^/        sudo /'
    } >&2
    if ! vm_path_ask "Run these with sudo now?"; then
        {
            printf '    Nothing changed. Run them yourself when you want to, or:\n'
            _vm_path_alternative
        } >&2
        return 1
    fi

    # Fill the array WITHOUT process substitution: a non-bash shell (hellish)
    # does not make shell functions visible inside <(...), so
    # `mapfile -t lines < <(_vm_path_recipe ...)` read -r an empty list there. A
    # command substitution DOES see functions, and filling the array in the
    # current shell keeps the sudo loop's stdin on the terminal for the
    # password prompt. (Univers42/hellish: process substitution drops functions.)
    lines=()
    while IFS= read -r line; do
        lines+=("$line")
    done <<<"$(_vm_path_recipe "$vm_path" "$vm_dir")"
    # The privileged lines run under the shell running this script -- what
    # make picked (SCRIPT_SH), else the interpreter of this very process --
    # not a hard-coded sh.
    local runsh="${SCRIPT_SH:-$(readlink /proc/$$/exe 2>/dev/null || echo sh)}"
    for line in "${lines[@]}"; do
        "$VM_PATH_SUDO" "$runsh" -c "$line" || {
            printf '  %s✗%s failed: sudo %s\n' "$_VP_RED" "$_VP_OFF" "$line" >&2
            return 1
        }
    done
    if ! _vm_path_writable "$vm_dir"; then
        printf '  %s✗%s %s is still not writable by %s\n' "$_VP_RED" "$_VP_OFF" "$vm_dir" "$me" >&2
        return 1
    fi
    printf '  %s✓%s %s now belongs to %s\n' "$_VP_GRN" "$_VP_OFF" "$vm_dir" "$me" >&2
}

# ── Where does this VM live? ────────────────────────────────────────────────
# VirtualBox remembers a VM's disk itself; QEMU has nothing, so after a
# `make all VM_PATH=/mnt/storage/qemu` every later `make qemu_*` had to be
# told VM_PATH again -- and forgetting it read -r as "nothing installed" or "not
# running". The location is recorded per VM_NAME, and the Makefile reads it
# back as the default VM_PATH. Repo-local (disk_images/ is gitignored); the
# tests point it elsewhere.
VM_PATH_REGISTRY="${VM_PATH_REGISTRY:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)/disk_images}"

remember_vm_dir() {
    mkdir -p "$VM_PATH_REGISTRY" 2>/dev/null || return 0
    printf '%s\n' "$1" >"$VM_PATH_REGISTRY/.vm_path.$2" 2>/dev/null || true
}

# ── Running as root through sudo ────────────────────────────────────────────
# `sudo make all` (or sudo make qemu_start) "works" and builds the wrong VM:
# the ISO gets ROOT's ~/.ssh key, so `ssh b2b` asks for a password; the b2b
# block lands in /root/.ssh/config; and the disk, pidfile, monitor socket and
# serial log come out root-owned, so every later command without sudo fails
# on them -- which invites more sudo. Nothing here needs root: when VM_PATH
# does, ensure_vm_dir asks for sudo for exactly that step. Only root reached
# through sudo is refused; a real root login (SUDO_USER unset or root) is not.
# $1 = the command to run instead.
refuse_sudo_build() {
    [ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] || return 0
    {
        printf '  %s✗%s not as root: the VM would get root'"'"'s SSH key and root-owned files.\n' "$_VP_RED" "$_VP_OFF"
        printf '    Run it as %s:   %s\n' "$SUDO_USER" "$1"
        printf '    If the VM files already belong to root, that command offers to hand them over with sudo.\n'
    } >&2
    return 1
}

# Run as a command (the Makefile does, before either pipeline starts).
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
    case "${1:-}" in
    --no-root)
        refuse_sudo_build "${2:-make all}"
        exit
        ;;
    esac
    [ $# -eq 2 ] || {
        printf 'usage: %s VM_PATH VM_NAME\n' "$0" >&2
        exit 2
    }
    ensure_vm_dir "$1" "$2"
fi
