#!/usr/bin/env hellish
# rotate_password.sh — change the guest's account passwords before they expire,
# and keep the secrets file in step.
#
# WHY THIS EXISTS
#   [policy.password] max_days = 30 is the subject's floor, and it does not stay
#   in the login prompt. Measured on trixie (2026-11-04, a throwaway account
#   with its password expired, key login, no terminal):
#       WARNING: Your password has expired.
#       Password change required but no TTY available.        exit 1
#   Every make target reaches the guest that way, so 30 days after a build the
#   hourly backup pull, verify_platform and every provisioner stop at once, and
#   with -tt the same login hangs on the prompt. A server outlives 30 days.
#   Rotating honours the policy; turning it off would not.
#
# WHEN
#   `make backup` runs this with --if-due every hour: it does nothing until
#   B2B_ROTATE_MARGIN_DAYS (10) are left, so a guest that is up one hour in ten
#   days still rotates. Only for an account whose profile says `secret:NAME`:
#   a literal password in a tracked file cannot be rotated from here.
#
# ORDER, SO THAT NO CRASH LOSES THE PASSWORD
#   1. the new value goes to the secrets file as NAME_NEXT;
#   2. the guest takes its hash, through sudo with the current password;
#   3. a fresh sudo with the NEW value proves the guest has it;
#   4. NAME takes the value, NAME_NEXT empties.
#   A run that dies between 2 and 4 finds NAME_NEXT next time, tries it, and
#   finishes the job. A plain-text value never reaches a command line or the
#   guest: the hash travels over ssh's stdin into a 600 file.
#
# Caveat: a guest powered off across the whole margin wakes up expired, every
# key login refused, and this cannot reach it. dc_connect names the way out
# (ssh -t, which asks for the old password and a new one).
#
#   make rotate_password          now
#   rotate_password.sh --if-due   only when the margin is reached
#   rotate_password.sh --days     days left, or `never`
set -u

# shellcheck source=setup/host/dc_lib.sh
. "$(dirname "${BASH_SOURCE[0]:-$0}")/dc_lib.sh"

MODE="${1:-}"
MARGIN="${B2B_ROTATE_MARGIN_DAYS:-10}"
GUEST_SCRIPT="$DC_ROOT/setup/host/rotate_password_guest.sh"

login_key=""
root_key=""
refs=$(b2b_secret_refs 2>/dev/null) || refs=""
while read -r name kind; do
    case "$kind" in
    login) login_key=$name ;;
    root) root_key=$name ;;
    esac
done <<REFS
$refs
REFS
if [ -z "$login_key" ]; then
    [ "$MODE" = --if-due ] && exit 0
    die "$VM_NAME's login password is a literal in the profile: only a secret:NAME can be rotated (see profiles/server.toml)"
fi

# days_left: whole days until the login's password expires, or `never`.
days_left() {
    local when
    when=$(vm_ssh "LC_ALL=C chage -l '$VM_USER'" 2>/dev/null | sed -n 's/^Password expires[[:space:]]*: *//p')
    case "$when" in
    "" | never)
        printf 'never'
        return 0
        ;;
    esac
    printf '%s' "$((($(date -d "$when" +%s) - $(date +%s)) / 86400))"
}

# sudo_answers VALUE: does sudo in the guest take VALUE? Through provision_vm.sh's
# own check, exported rather than `env VAR=`, which ps would show on the seat.
# Caveat: proves nothing on a guest whose sudo needs no password (it says yes to
# any value); the policy this project ships always asks.
sudo_answers() (
    export VM_SUDO_PASS="$1"
    VM_PATH="${VM_PATH:-$DC_ROOT/disk_images}" \
        "${SCRIPT_SH:-bash}" "$DC_ROOT/setup/host/provision_vm.sh" "$VM_NAME" sudo-check >/dev/null 2>&1
)

# promote KEY VALUE: VALUE is what the guest answers to.
promote() {
    secret_set "$1" "$2"
    secret_set "${1}_NEXT" ""
}

dc_connect
left=$(days_left)
case "$MODE" in
--days)
    printf '%s\n' "$left"
    exit 0
    ;;
--if-due)
    [ "$left" != never ] || exit 0
    [ "$left" -le "$MARGIN" ] || exit 0
    info "the login's password expires in $left day(s): rotating"
    ;;
esac

# An interrupted run: the guest may already hold NAME_NEXT.
pending=$(secret_get "${login_key}_NEXT")
if [ -n "$pending" ]; then
    if sudo_answers "$pending"; then
        promote "$login_key" "$pending"
        root_next=$(secret_get "${root_key}_NEXT")
        [ -z "$root_key" ] || [ -z "$root_next" ] || promote "$root_key" "$root_next"
        ok "finished an interrupted rotation"
        [ "$MODE" = --if-due ] && exit 0
    else
        secret_set "${login_key}_NEXT" ""
    fi
fi

new_login=$(mint_login_password)
secret_set "${login_key}_NEXT" "$new_login"
hashes=$(printf '%s:%s' "$VM_USER" "$(printf '%s' "$new_login" | openssl passwd -6 -stdin)")
new_root=""
if [ -n "$root_key" ]; then
    new_root=$(mint_login_password)
    secret_set "${root_key}_NEXT" "$new_root"
    hashes=$(printf '%s\nroot:%s' "$hashes" "$(printf '%s' "$new_root" | openssl passwd -6 -stdin)")
fi

remote="/tmp/.b2b-rotate.$$"
printf '%s\n' "$hashes" | vm_ssh "umask 077; cat > '$remote'" || die "could not upload the hashes"
ROOT_SH="$GUEST_SCRIPT" ROOTSH_HASH_FILE="$remote" VM_PATH="${VM_PATH:-$DC_ROOT/disk_images}" \
    "${SCRIPT_SH:-bash}" "$DC_ROOT/setup/host/provision_vm.sh" "$VM_NAME" root-sh ||
    warn "the guest step reported a problem; the proof below decides"
vm_ssh "rm -f '$remote'" 2>/dev/null || true

if ! sudo_answers "$new_login"; then
    secret_set "${login_key}_NEXT" ""
    [ -z "$root_key" ] || secret_set "${root_key}_NEXT" ""
    die "the guest did not take the new password: the secrets file keeps the old one (read the output above)"
fi
promote "$login_key" "$new_login"
[ -z "$root_key" ] || promote "$root_key" "$new_root"
ok "$VM_NAME's passwords rotated; $(days_left) day(s) until the next expiry, values in $SECRETS_FILE"
