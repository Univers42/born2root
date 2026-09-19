#!/usr/bin/env hellish
# Regression test for how `make qemu_ssh CMD=...` reaches the guest.
#
# THE BUG IT GUARDS
#
#   The recipe used to be:
#
#       @$(QEMU_ENV) $(SCRIPT_SH) setup/host/qemu_vm.sh ssh $(CMD)
#
#   make expands a recipe into a shell, so that shell re-parsed $(CMD) and
#   every metacharacter in it acted on the HOST, not the guest:
#
#       make qemu_ssh CMD="hostname; grep PRETTY /etc/os-release"
#         hostname                     -> guest  (dlesieur42)
#         grep PRETTY /etc/os-release  -> HOST   (Ubuntu 22.04)
#
#   The damage was not the confusion -- although half a session's "guest"
#   facts turned out to be host output -- it was that `CMD="cd /srv && rm -rf
#   ."` deleted files on the seat while reading like a command sent to a
#   disposable VM.
#
#   Quoting the expansion ("$(CMD)") only moves the problem: any CMD holding a
#   double quote then breaks, and `psql -c "select 1"` is ordinary in this
#   project. So CMD travels in the environment as B2B_SSH_CMD, which execve
#   hands over as one string that no shell ever parses.
#
# WHAT THIS COVERS, AND WHAT IT DOES NOT
#
#   It asserts the Makefile contract -- that nothing from CMD reaches the
#   command line -- which is where the bug lived. It does not drive a real ssh:
#   the `ssh` action calls need_running_or_die first, and faking a live QEMU
#   pid well enough to get past it costs more than it proves. The consuming
#   side is pinned structurally instead.
set -e

cd "$(dirname "$0")/.."

fail=0
check_lacks() {
    if printf '%s' "$2" | grep -qF -- "$3"; then
        printf 'FAIL %s -- should NOT contain: %s\n' "$1" "$3"
        fail=1
    else
        printf 'ok   %s\n' "$1"
    fi
}
check_has() {
    if printf '%s' "$2" | grep -qF -- "$3"; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s -- expected to find: %s\n' "$1" "$3"
        fail=1
    fi
}

# --- the Makefile must not put CMD on the command line ----------------------
# A semicolon is the cheap case; && and | split a recipe just as well, and the
# payload here is the shape that actually destroys something.
recipe=$(make -n qemu_ssh CMD='hostname; rm -rf /tmp/pwned' 2>&1)

check_lacks "a ; in CMD does not reach the recipe" "$recipe" "rm -rf /tmp/pwned"
check_lacks "nor does the metacharacter itself" "$recipe" ";"
check_has "the recipe still dispatches ssh" "$recipe" "qemu_vm.sh ssh"

recipe_and=$(make -n qemu_ssh CMD='true && rm -rf /tmp/pwned' 2>&1)
check_lacks "an && in CMD does not reach the recipe" "$recipe_and" "rm -rf /tmp/pwned"

recipe_pipe=$(make -n qemu_ssh CMD='cat /etc/passwd | tee /tmp/pwned' 2>&1)
check_lacks "a | in CMD does not reach the recipe" "$recipe_pipe" "/tmp/pwned"

# A CMD carrying double quotes is why the export exists rather than "$(CMD)".
recipe_q=$(make -n qemu_ssh CMD='psql -c "select 1"' 2>&1)
check_lacks "a quoted CMD does not reach the recipe" "$recipe_q" "select 1"

# --- the consuming side ------------------------------------------------------
# Structural, for the reason given in the header. Both lines matter: reading
# B2B_SSH_CMD is what makes the Makefile work at all, and passing "$@" rather
# than "${@:2}" is what keeps a direct `qemu_vm.sh ssh uname -a` working.
branch=$(awk '/^    ssh\)/, /^        ;;/' setup/host/qemu_vm.sh)

check_has "the ssh action reads B2B_SSH_CMD" "$branch" 'B2B_SSH_CMD'
# shellcheck disable=SC2016 # the literal source line is what is being matched
check_has "it re-anchors the positional args" "$branch" 'set -- "${@:2}"'
# shellcheck disable=SC2016 # ditto
check_has "and execs ssh with them" "$branch" '"$@"'

# An empty CMD must stay empty: `ssh host ""` is a command, not a login shell,
# and it returns instantly instead of giving you a prompt.
# shellcheck disable=SC2016 # ditto
check_has "an empty B2B_SSH_CMD is not passed as an argument" "$branch" '[ -n "${B2B_SSH_CMD:-}" ]'

exit "$fail"
