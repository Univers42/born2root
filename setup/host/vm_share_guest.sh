#!/usr/bin/env hellish
# vm_share_guest.sh — a colleague's account in the guest, as root, through
# provision_vm.sh root-sh (vm_share.sh sends it). ROOTSH_ACTION=add|lock|
# workspace|home, ROOTSH_LOGIN, ROOTSH_KEY (one public key line, or empty for an
# account whose key comes later: its authorized_keys is left as it is),
# ROOTSH_DOCKER=1|0.
#
# The account is theirs alone and logs in by key only. Its password field is
# '*', not '!': sshd under PAM reads '!' as a locked account and refuses the
# key too. Password ageing is off for it, since the subject's 30-day maximum
# would expire a password nobody has, and PAM would then demand a change at
# every key login. The docker group (ROOTSH_DOCKER=1, the default)
# is what working on grobase takes, and it is root in this guest -- which is
# why the wall that keeps them off the host lives on the host (vm_wall.sh).
# hellish is the shell, as for every account here.
# An account that exists without the "b2b guest" comment useradd gives it
# here is someone else's (the owner's, a service's): refused, never taken over.
# lock keeps the home (their work), removes the key, expires the account and
# ends its sessions.
#
# THE TEAM: every guest and the owner are in group dev, which owns grobase's
# live tree (/opt/grobase) with write on everything, secrets included, and
# may run the few root commands its upkeep needs through sudo -- no password
# (a guest has none), never ALL. add sets it up; workspace sets it up again
# after a rebuild, which returns the tree to the owner alone. Any member may
# bring an account of this guest into dev (sudo b2b-dev-invite LOGIN), which
# passes the same right on; an account the owner locked stays out. add
# itself joins dev through that command, so there is one way in.
#
# GITHUB: a guest pushes over ssh with the key their connect kit forwards
# (vm_share_connect.sh). add and workspace put GitHub's host keys in the
# system known_hosts, so the first push -- or one from VS Code, which has no
# prompt to answer -- is not "Host key verification failed".
# Caveat: the keys are GitHub's as published at api.github.com/meta on
# 2026-10-26; a rotation on their side (the RSA key was replaced in 2023)
# fails every push with a changed-key warning until these lines are updated.
set -u
login="${ROOTSH_LOGIN:-}"
WORKSPACE="${B2B_WORKSPACE:-/opt/grobase}"
SUDOERS="${B2B_DEV_SUDOERS:-/etc/sudoers.d/b2b-dev}"
DEV="${B2B_DEV_GROUP:-dev}"
DEV_INVITE="${B2B_DEV_INVITE:-/usr/local/sbin/b2b-dev-invite}"
KNOWN_HOSTS="${B2B_SSH_KNOWN_HOSTS:-/etc/ssh/ssh_known_hosts}"
GITHUB_HOST_KEYS='github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk='

check_login() {
    case "$login" in '' | [!a-z]* | *[!a-z0-9_-]*)
        echo "bad login '$login'" >&2
        exit 1
        ;;
    esac
}

own_guest() {
    [ "$(getent passwd "$login" | cut -d: -f5)" = "b2b guest" ] && return 0
    echo "$login is an account this script did not create: left alone" >&2
    return 1
}

# dev_sudoers: the root half of grobase's upkeep. The b2b-* helpers the dc
# provisioners install and a docker restart; no cp, install or apt, whose
# arguments sudo cannot pin (a wildcard path matches ../ too).
dev_sudoers() {
    cat <<'EOF'
# born2root vm_share_guest.sh: what group dev runs as root, no password.
Cmnd_Alias B2B_DEV = /usr/local/sbin/b2b-grobase-env, \
    /usr/local/sbin/b2b-dev-invite, \
    /usr/local/sbin/b2b-stack-health, /usr/local/sbin/b2b-autoheal "", \
    /usr/local/sbin/b2b-backup "", /usr/sbin/update-ca-certificates "", \
    /usr/bin/systemctl restart docker, /usr/bin/systemctl restart docker.service
EOF
    printf '%%%s ALL=(root) NOPASSWD: B2B_DEV\n' "$DEV"
}

# dev_invite_script: b2b-dev-invite, which members run through sudo. It adds
# a human account (uid 1000-59999) to the group and nothing else: no account
# is made here, and docker stays the owner's to give (make share_invite).
# lock expires an account (usermod -e 1), so an expiry in the past is the
# owner's revocation and is refused rather than undone by a member.
dev_invite_script() {
    printf '#!/bin/sh\nDEV=%s\n' "$DEV"
    cat <<'EOF'
# b2b-dev-invite LOGIN -- written by born2root's vm_share_guest.sh.
set -u
login="${1:-}"
case "$login" in
'' | [!a-z]* | *[!a-z0-9_-]*)
    echo "usage: sudo b2b-dev-invite LOGIN" >&2
    exit 2
    ;;
esac
uid=$(getent passwd "$login" | cut -d: -f3)
if [ -z "$uid" ]; then
    echo "no account $login in this guest" >&2
    exit 1
fi
if [ "$uid" -lt 1000 ] || [ "$uid" -ge 60000 ]; then
    echo "$login is a system account: not invited" >&2
    exit 1
fi
expire=$(getent shadow "$login" | cut -d: -f8)
if [ -n "$expire" ] && [ "$expire" -le $(($(date +%s) / 86400)) ]; then
    echo "$login was locked by the owner: only the owner gives it back" >&2
    exit 1
fi
if id -nG "$login" | tr ' ' '\n' | grep -qxF "$DEV"; then
    echo "$login is already in $DEV"
    exit 0
fi
usermod -aG "$DEV" "$login" || exit 1
echo "$login is in $DEV from their next login (sudo b2b-dev-invite is theirs too)"
EOF
}

# team_workspace: every file of the owner's tree read-write for group dev,
# and staying so. Only files with the owner's own group change group:
# grobase gives the WAF's TLS key group 101 (generate-localhost-cert.sh) so
# the WAF can read it, and dev there locks the WAF out at its next start; a
# file like that gets dev through a named ACL entry instead. Directories get
# setgid and default ACLs, so what anyone creates later is dev's and
# group-writable whatever their umask.
# Caveat: a later chmod narrows the ACL mask (the WAF key's 640 after a
# regeneration leaves dev read-only on it); make share widens it again. A
# daemon that refuses a group-writable path (a postgres data directory)
# would be refused here: /opt/grobase bind-mounts config files only. git refuses a repository another user
# owns unless it is a safe.directory, and sharedRepository keeps the objects
# it writes group-writable.
team_workspace() {
    local owner tmp
    owner=$(sed -n 's/^B2B_LOGIN=//p' "${B2B_BUILD_CONF:-/etc/b2b/build.conf}")
    [ -n "$owner" ] || {
        echo "no B2B_LOGIN in build.conf" >&2
        return 1
    }
    groupadd -f "$DEV" && usermod -aG "$DEV" "$owner" || return 1
    tmp=$(mktemp)
    dev_invite_script >"$tmp"
    install -m 0755 -o root -g root "$tmp" "$DEV_INVITE" || {
        rm -f "$tmp"
        return 1
    }
    dev_sudoers >"$tmp"
    visudo -cf "$tmp" >/dev/null || {
        rm -f "$tmp"
        echo "visudo refused the dev sudoers" >&2
        return 1
    }
    install -m 0440 -o root -g root "$tmp" "$SUDOERS"
    rm -f "$tmp"
    [ -d "$WORKSPACE" ] || {
        echo "no $WORKSPACE: group $DEV made, nothing to share yet"
        return 0
    }
    command -v setfacl >/dev/null ||
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q acl >/dev/null || return 1
    find "$WORKSPACE" -user "$owner" -group "$owner" -exec chgrp -h "$DEV" {} + || return 1
    find "$WORKSPACE" -group "$DEV" ! -type l -exec chmod g+rwX {} + || return 1
    find "$WORKSPACE" ! -group "$DEV" ! -type l -exec setfacl -m "g:$DEV:rwX,m::rwX" {} + || return 1
    find "$WORKSPACE" -type d -group "$DEV" -exec chmod g+s {} + || return 1
    find "$WORKSPACE" -type d -exec setfacl -m "d:g::rwX,d:g:$DEV:rwX,d:m::rwX" {} + || return 1
    git config --system --get-all safe.directory 2>/dev/null | grep -qxF "$WORKSPACE" ||
        git config --system --add safe.directory "$WORKSPACE"
    # As the owner: git config rewrites .git/config by rename, so a root run
    # would leave the owner a config they can no longer change.
    [ ! -d "$WORKSPACE/.git" ] ||
        runuser -u "$owner" -- git -C "$WORKSPACE" config core.sharedRepository group
    echo "workspace $WORKSPACE: group $DEV ($(getent group "$DEV" | cut -d: -f4))"
}

trust_github() {
    local line
    touch "$KNOWN_HOSTS" && chmod 644 "$KNOWN_HOSTS" || return 1
    while IFS= read -r line; do
        grep -qxF "$line" "$KNOWN_HOSTS" || printf '%s\n' "$line" >>"$KNOWN_HOSTS" || return 1
    done <<KHEOF
$GITHUB_HOST_KEYS
KHEOF
}

case "${ROOTSH_ACTION:-}" in
add)
    check_login
    key="${ROOTSH_KEY:-}"
    [ -z "$key" ] || printf '%s\n' "$key" | ssh-keygen -l -f - >/dev/null 2>&1 || {
        echo "ROOTSH_KEY is not one public key line" >&2
        exit 1
    }
    shell=$(command -v hellish) || {
        echo "no hellish in this guest" >&2
        exit 1
    }
    id "$login" >/dev/null 2>&1 || useradd -m -s "$shell" -c "b2b guest" "$login" || exit 1
    own_guest || exit 1
    usermod -s "$shell" -p '*' -e '' "$login" || exit 1
    chage -d "$(date +%F)" -M -1 "$login"
    if [ "${ROOTSH_DOCKER:-1}" = 1 ] && getent group docker >/dev/null; then
        usermod -aG docker "$login"
    else
        gpasswd -d "$login" docker >/dev/null 2>&1 || true
    fi
    home=$(getent passwd "$login" | cut -d: -f6)
    install -d -m 700 -o "$login" -g "$login" "$home/.ssh"
    if [ -n "$key" ]; then
        printf '%s\n' "$key" >"$home/.ssh/authorized_keys"
        chown "$login:$login" "$home/.ssh/authorized_keys"
        chmod 600 "$home/.ssh/authorized_keys"
    fi
    team_workspace || exit 1
    trust_github || exit 1
    "$DEV_INVITE" "$login" >/dev/null || exit 1
    [ -s "$home/.ssh/authorized_keys" ] || note=", no key yet"
    echo "account $login ready ($(id -nG "$login")${note:-})"
    ;;
lock)
    check_login
    id "$login" >/dev/null 2>&1 || exit 0
    own_guest || exit 1
    home=$(getent passwd "$login" | cut -d: -f6)
    rm -f "$home/.ssh/authorized_keys"
    usermod -L -e 1 "$login"
    gpasswd -d "$login" docker >/dev/null 2>&1 || true
    gpasswd -d "$login" "$DEV" >/dev/null 2>&1 || true
    pkill -KILL -u "$login" 2>/dev/null || true
    echo "account $login locked, $home kept"
    ;;
workspace) team_workspace && trust_github ;;
home)
    # The read-back of vm_share.sh's guest_home, here because the home is
    # 0700 and the owner's sudo wants a terminal: one verdict line it greps.
    check_login
    home=$(getent passwd "$login" | cut -d: -f6)
    missing=''
    [ -L "$home/.hellishrc" ] && [ -L "$home/.hellish/lib" ] || missing="$missing hellish"
    [ ! -x /usr/local/bin/nvim ] || { [ -L "$home/.config/nvim" ] && [ -L "$home/.local/share/nvim/site" ]; } ||
        missing="$missing nvim"
    echo "home $login: ${missing:+missing$missing}${missing:-ok}"
    ;;
*)
    echo "ROOTSH_ACTION must be add, lock, workspace or home" >&2
    exit 1
    ;;
esac
