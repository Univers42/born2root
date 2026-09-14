#!/usr/bin/env hellish
# ============================================================================ #
#  verify_guest_parity.sh — is the guest the SAME on QEMU as on VirtualBox?    #
# ============================================================================ #
#
# The backend decides what executes the machine. It must not decide anything
# about what is inside it: the partition layout, the encryption, the firewall,
# the password policy and the login shell all come from the preseeded ISO, and
# the ISO is the same file either way.
#
# This prints those facts as a table so the two backends can be compared
# side by side -- run it against each and diff the output. Anything that
# differs is a real portability bug; everything here should be identical.
#
# It is deliberately non-interactive: the few root-only facts (luksDump, ufw)
# are fetched with `sudo -S` over `ssh -tt`, using the account password from
# born2root.toml the way deploy_inception.sh does. The expected login, host
# name and owner come from the same file. Nothing is changed in the guest.
#
# Usage:  verify_guest_parity.sh [ssh-alias]        (default: b2b)
#         BACKEND_LABEL=qemu verify_guest_parity.sh > qemu.txt
# ============================================================================ #

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
ALIAS="${1:-b2b}"
. "$REPO_ROOT/utils/b2b_config.sh"
B2B_LOGIN=$(b2b_get B2B_LOGIN)
B2B_HOSTNAME=$(b2b_get B2B_HOSTNAME)

C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_RED=$'\033[31m'
C_DIM=$'\033[2m'
if [ ! -t 1 ] || [ -n "${NO_COLOR:-}" ]; then
    C_RESET=''
    C_BOLD=''
    C_GREEN=''
    C_YELLOW=''
    C_RED=''
    C_DIM=''
fi

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)
# shellcheck disable=SC2029
# -n: ssh must not read stdin. A row inside a `while read` loop would otherwise
# hand the rest of the loop's input to the guest -- the account rows checked
# the first account and silently skipped every other one.
g() { ssh -n "${SSH_OPTS[@]}" "$ALIAS" "$@" 2>/dev/null; }

guest_pass() {
    [ -n "${GUEST_PASS:-}" ] && {
        printf '%s' "$GUEST_PASS"
        return 0
    }
    b2b_user_password 2>/dev/null
}

# sudo in this guest requires a tty (requiretty in the sudoers policy), so -tt
# is not optional; -S then reads the password from that tty.
groot() {
    local p
    p=$(guest_pass)
    [ -n "$p" ] || return 1
    printf '%s\n' "$p" | ssh "${SSH_OPTS[@]}" -tt "$ALIAS" \
        "sudo -S -p '' $1" 2>/dev/null | tr -d '\r' |
        grep -vxF "$p" | grep -v '^\[sudo\]'
}

pass=0
fail=0
row() { # row <label> <actual> <expected-substring|-->
    local label="$1" actual="$2" want="${3:-}"
    actual=$(printf '%s' "$actual" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')
    if [ -z "$want" ] || [ "$want" = "--" ]; then
        printf "  %-22s ${C_DIM}%s${C_RESET}\n" "$label" "${actual:-(none)}"
    elif printf '%s' "$actual" | grep -qF -- "$want"; then
        printf "  ${C_GREEN}✓${C_RESET} %-20s %s\n" "$label" "$actual"
        pass=$((pass + 1))
    else
        printf "  ${C_RED}✗${C_RESET} %-20s %s ${C_DIM}(expected: %s)${C_RESET}\n" \
            "$label" "${actual:-(none)}" "$want"
        fail=$((fail + 1))
    fi
}

g true || {
    printf "  ${C_RED}✗${C_RESET} cannot ssh to '%s'\n" "$ALIAS"
    exit 1
}

# shellcheck disable=SC2059
printf "\n${C_BOLD}Guest parity report${C_RESET}"
[ -n "${BACKEND_LABEL:-}" ] && printf " ${C_DIM}(backend: %s)${C_RESET}" "$BACKEND_LABEL"
# shellcheck disable=SC2059
printf "\n${C_DIM}  Everything below comes from the preseeded ISO, not from the hypervisor.${C_RESET}\n"

# shellcheck disable=SC2059
printf "\n${C_BOLD}System${C_RESET}\n"
row "hostname" "$(g hostname)" "$B2B_HOSTNAME"
row "debian" "$(g 'cat /etc/debian_version')" "13"
row "kernel" "$(g 'uname -r')" "--"
# shellcheck disable=SC2016
row "cpus / ram" "$(g 'nproc; free -m | awk "/Mem:/{print \$2\"MB\"}"')" "--"

# shellcheck disable=SC2059
printf "\n${C_BOLD}Disk: the partition layout (the subject's core requirement)${C_RESET}\n"
printf "${C_DIM}%s${C_RESET}\n" "$(g 'lsblk -o NAME,TYPE,FSTYPE,SIZE,MOUNTPOINT' | sed 's/^/    /')"
row "/boot" "$(g 'lsblk -no FSTYPE,SIZE,MOUNTPOINT /dev/sda2 | head -1')" "/boot"
row "biosgrub (sda1)" "$(g 'lsblk -no SIZE /dev/sda1 | head -1')" "--"
row "LUKS container" "$(g 'lsblk -no FSTYPE /dev/sda5 | head -1')" "crypto_LUKS"
row "LVM on LUKS" "$(g 'lsblk -no TYPE /dev/mapper/sda5_crypt | head -1')" "crypt"

# shellcheck disable=SC2059
printf "\n${C_BOLD}Encryption${C_RESET}\n"
row "cipher" "$(groot 'cryptsetup luksDump /dev/sda5' | awk -F': *' '/cipher:/{print $2; exit}')" "aes-xts-plain64"
row "kdf" "$(groot 'cryptsetup luksDump /dev/sda5' | awk -F': *' '/PBKDF:/{print $2; exit}')" "argon2"

# shellcheck disable=SC2059
printf "\n${C_BOLD}Logical volumes${C_RESET}\n"
printf "${C_DIM}%s${C_RESET}\n" "$(g 'lsblk -no NAME,SIZE,MOUNTPOINT /dev/mapper/sda5_crypt | tail -n +2' | sed 's/^/    /')"
row "free extents in VG" "$(groot 'vgs --noheadings -o vg_free' | tr -d ' ')" "--"

# shellcheck disable=SC2059
printf "\n${C_BOLD}Born2beRoot policy${C_RESET}\n"
# shellcheck disable=SC2016
row "sshd port" "$(g 'ss -tlnH | awk "{print \$4}" | grep -o ":4242$" | head -1')" ":4242"
row "root ssh" "$(g 'grep -iE "^permitrootlogin" /etc/ssh/sshd_config* 2>/dev/null | head -1' | awk '{print $NF}')" "no"
row "ufw" "$(groot '/usr/sbin/ufw status' | grep -m1 'Status:')" "active"
row "ufw 4242" "$(groot '/usr/sbin/ufw status' | grep -c '4242' | awk '{print ($1>0)?"allowed":"MISSING"}')" "allowed"
row "apparmor" "$(g 'systemctl is-active apparmor')" "active"
# The policy rows expect what born2root.toml asked for, not the subject's
# literals: a stricter minlen = 12 is a pass, and must not read as a failure.
row "sudo tries" "$(groot 'grep -rh passwd_tries /etc/sudoers /etc/sudoers.d/ 2>/dev/null' | head -1 | tr -d ' \t' | sed 's/^Defaults//')" "passwd_tries=$(b2b_get B2B_SUDO_TRIES)"
row "sudo io log" "$(groot 'grep -rh iolog_dir /etc/sudoers.d/ 2>/dev/null' | head -1 | tr -d ' \t"' | sed 's/^Defaults//')" "iolog_dir=$(b2b_get B2B_SUDO_LOG_DIR)"
row "pwd minlen" "$(g 'grep -h "^minlen" /etc/security/pwquality.conf 2>/dev/null | head -1' | tr -d ' ')" "minlen=$(b2b_get B2B_PASS_MIN_LENGTH)"
row "pwd max days" "$(groot "chage -l $B2B_LOGIN" | sed -n 's/^Maximum number of days.*: *//p')" "$(b2b_get B2B_PASS_MAX_DAYS)"
row "ssh passwords" "$(g 'grep -h "^PasswordAuthentication" /etc/ssh/sshd_config 2>/dev/null | head -1' | awk '{print $NF}')" "$(b2b_get B2B_SSH_PASSWORD_LOGIN)"
row "monitoring" "$(g 'ls /usr/local/bin/monitoring.sh 2>/dev/null')" "monitoring.sh"
row "cron entry" "$(groot 'grep -h monitoring.sh /etc/crontab 2>/dev/null' | awk '{print $1}' | head -1)" "*/$(b2b_get B2B_MONITOR_INTERVAL)"

# shellcheck disable=SC2059
printf "\n${C_BOLD}Accounts (born2root.toml)${C_RESET}\n"
# The groups born2root.toml manages: user42, sudo, docker and every group any
# account names. An account in one of them that it did not ask for is a
# mismatch too -- checking only for missing groups let a login with
# `groups = []` sit in docker for every build (d-i's own default groups for
# the first user, cdrom, audio and the rest, are not ours and not checked).
b2b_users_list=$(b2b_users 2>/dev/null)
managed=" user42 sudo docker $(printf '%s\n' "$b2b_users_list" | cut -d: -f3 | tr ',\n' '  ') "
while IFS=: read -r name fullname groups; do
    [ -n "$name" ] || continue
    entry=$(g "getent passwd $name")
    row "$name exists" "${entry%%:*}" "$name"
    row "$name full name" "$(printf '%s' "$entry" | cut -d: -f5 | cut -d, -f1)" "$fullname"
    row "$name shell" "$(printf '%s' "$entry" | cut -d: -f7)" "/usr/bin/hellish"
    have=" $(g "id -nG $name") "
    missing=""
    extra=""
    for group in $(printf '%s' "$groups" | tr ',' ' '); do
        case "$have" in *" $group "*) ;; *) missing="$missing $group" ;; esac
    done
    for group in $have; do
        case " $(printf '%s' "$groups" | tr ',' ' ') $name " in *" $group "*) continue ;; esac
        case "$managed" in *" $group "*) extra="$extra $group" ;; esac
    done
    got="exactly $groups"
    [ -z "$missing$extra" ] || got="${missing:+missing:$missing}${missing:+${extra:+ }}${extra:+not asked for:$extra}"
    row "$name groups" "$got" "exactly $groups"
done <<USERSEOF
$b2b_users_list
USERSEOF
# Every other `nvim = true` account runs the editor from the login's shared
# plugins (first-boot-setup.sh, share_editor_setup): its plugin directory is a
# link to /home/.b2b-editor, not a second 400 MB copy.
for name in $(b2b_get B2B_NVIM_USERS); do
    [ "$name" != "$B2B_LOGIN" ] || continue
    row "$name editor" "$(groot "readlink /home/$name/.local/share/nvim/site")" "/home/.b2b-editor/site"
done
# An account born2root.toml gave no password is locked (passwd -S says L)
# until someone sets one in the guest. Asked per name, so no password is
# hashed or printed just to find the empty ones.
for name in $(b2b_get B2B_USERS); do
    [ "$name" != "$B2B_LOGIN" ] || continue
    [ -z "$(b2b_get "users.$name.password")" ] || continue
    row "$name locked" "$(groot "passwd -S $name" | awk '{print $2}')" "L"
done

# shellcheck disable=SC2059
printf "\n${C_BOLD}Login shell (installed from upstream on first boot)${C_RESET}\n"
if g 'pgrep -f "first[-]boot-setup" >/dev/null'; then
    # shellcheck disable=SC2059
    printf "  ${C_YELLOW}⚠${C_RESET}  first-boot-setup.sh is STILL RUNNING — the hellish plugin\n"
    printf "     framework installs near the end of it. Re-run this when it finishes:\n"
    printf "     ${C_DIM}ssh %s 'pgrep -f first-boot-setup.sh || echo done'${C_RESET}\n" "$ALIAS"
fi
row "login shell" "$(g "getent passwd $B2B_LOGIN | cut -d: -f7")" "/usr/bin/hellish"
row "root shell" "$(g 'getent passwd root | cut -d: -f7')" "/bin/bash"
row "hellish" "$(g '/usr/bin/hellish.real --version 2>/dev/null | head -1')" "hellish"
row "shell link" "$(g 'readlink /usr/bin/hellish')" "/usr/bin/hellish.real"
# shellcheck disable=SC2016
row "ssh command" "$(g 'x=$(readlink /proc/$$/exe); echo "$x"')" "/usr/bin/hellish.real"
# shellcheck disable=SC2016
row "ssh \$0" "$(g 'echo $0')" "hellish"
row "plugins" "$(g 'ls ~/.hellish/plugins 2>/dev/null | wc -l')" "--"
row "hellishrc" "$(g 'stat -c %U ~/.hellishrc 2>/dev/null')" "$B2B_LOGIN"

# (`ssh b2b 'readlink /proc/$$/exe'` would be answered by readlink itself: a
# shell execs a lone command in place of itself; the substitution keeps $$
# the shell sshd started.)
# What the guest starts on its own runs under the same shell: the cron job,
# the two systemd helpers (checked live, by the process name of their main
# pid), the first-boot hook and the provisioners it ran.
# shellcheck disable=SC2059
printf "\n${C_BOLD}Interpreters (nothing the guest starts itself is bash)${C_RESET}\n"
row "cron SHELL" "$(g 'sed -n "s/^SHELL=//p" /etc/crontab | head -1')" "/usr/bin/hellish.real"
row "monitoring.sh" "$(g 'head -1 /usr/local/bin/monitoring.sh')" "#!/usr/bin/hellish.real"
row "nat-keepalive" "$(g 'head -1 /usr/local/bin/nat-keepalive.sh')" "#!/usr/bin/hellish.real"
row "sshd-watchdog" "$(g 'head -1 /usr/local/bin/sshd-watchdog.sh')" "#!/usr/bin/hellish.real"
# A script's process is named after the script (comm), so the interpreter is
# argv[0] of the unit's main pid, readable by anyone in /proc/<pid>/cmdline.
# Both units are Restart=always with RestartSec=5, and sshd-watchdog
# Requires=ssh.service, so first boot's (and shell_vm's) `systemctl restart
# ssh` restarts it: for a few seconds the unit has no main pid at all, and a
# table drawn in that window said "(none)" of a unit that was fine. Wait it
# out; a unit that never comes back still reads (none).
unit_interp() { # unit_interp <unit>  -> argv[0] of its main process
    # shellcheck disable=SC2016
    g 'p=0; for _ in 1 2 3 4 5 6 7 8; do p=$(systemctl show -p MainPID --value '"$1"'); [ "$p" != 0 ] && break; sleep 3; done; tr "\\0" " " < /proc/$p/cmdline | cut -d" " -f1'
}
row "keepalive pid" "$(unit_interp nat-keepalive)" "/usr/bin/hellish.real"
row "watchdog pid" "$(unit_interp sshd-watchdog)" "/usr/bin/hellish.real"
row "guest sh conf" "$(g 'sed -n "s/^B2B_GUEST_SH=//p" /etc/b2b_custom_shell.conf')" "/usr/bin/hellish.real"
# The provisioners live in /root, so the glob must expand as root, under the
# guest's own shell; first-boot's log keeps what interpreted them when it ran.
row "provisioners" "$(groot "/usr/bin/hellish.real -c 'head -qn1 /root/install_*.sh 2>/dev/null | sort -u'" | tr '\n' ' ')" "#!/usr/bin/hellish.real"
# A guest converted by `make shell_vm` after its first boot has no such line:
# then the row is informational (the rows above already say what runs now).
fb="$(groot 'grep -m1 -o "provisioners run under .*" /var/log/first-boot.log 2>/dev/null')"
if [ -n "$fb" ]; then
    row "first-boot ran" "$fb" "/usr/bin/hellish.real"
else
    row "first-boot ran" "(before the interpreter pin; converted since)" "--"
fi
row "first-boot cron" "$(groot 'grep -h first-boot-setup /etc/crontab 2>/dev/null; echo "(line removed after it ran)"' | head -1)" "--"

# shellcheck disable=SC2059
printf "\n${C_BOLD}Services${C_RESET}\n"
row "docker" "$(g 'systemctl is-active docker')" "active"
row "ssh" "$(g 'systemctl is-active ssh')" "active"

printf "\n"
if [ "$fail" -eq 0 ]; then
    printf "${C_GREEN}${C_BOLD}  %d/%d checks passed — the guest matches the specification.${C_RESET}\n\n" "$pass" "$((pass + fail))"
    exit 0
fi
printf "${C_YELLOW}${C_BOLD}  %d passed, %d failed.${C_RESET}\n\n" "$pass" "$fail"
exit 1
