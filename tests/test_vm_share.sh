#!/usr/bin/env hellish
# make share_*: a colleague in the VM, the VM walled off the host.
#
# THE FAILURES IT PINS
#   QEMU's user network is the host's own sockets: on 2026-10-25 a shell in
#   baas reached some forty host loopback listeners through 10.0.2.2. The
#   wall (vm_wall.sh) must stay keyed to the unit's cgroup, refuse every
#   local address but DNS and the listed ports, and take no name or port
#   that could smuggle nft syntax. The tailnet policy edit
#   (ts_share_policy.py) must replace the allow-all grant once, leave a
#   hand-written policy alone, and never call a policy that still allows all
#   "done". ssh b2b must stop forwarding the host's Chrome into a shared VM.
#   And neither a missing GUEST= (the Makefile's LOGIN is the owner's login)
#   nor the guest script may ever take over an account it did not create.
#   The team workspace must leave grobase's WAF key its group 101 (dev
#   there locks the WAF out) and give group dev a sudo list, never ALL.
#   Revoking one login keeps an invite another login of the same person
#   uses, and the connect kit writes its ssh block once however often run.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
TMP=$(mktemp -d)
# A path, not a name: the guest tests put a stand-in hellish first on PATH.
SCRIPT_SH=$(command -v "${SCRIPT_SH:-bash}")
trap 'rm -rf "$TMP"' EXIT
fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-52s = %s\n' "$1" "$2"
    else
        printf 'FAIL %-52s = %s (want %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}

# ── the wall ────────────────────────────────────────────────────────────────
export B2B_WALL_LIB=1
# shellcheck source=setup/host/vm_wall.sh
. "$REPO_ROOT/setup/host/vm_wall.sh"
cg_rel="user.slice/user-1000.slice/user@1000.service/app.slice/b2b-vm-baas.service"
mkdir -p "$TMP/cg/$cg_rel"
check "wall_table maps - to _" "$(wall_table my-vm)" "b2b_wall_my_vm"
check "wall_cgroup finds the unit" "$(B2B_CGROUP_ROOT="$TMP/cg" wall_cgroup baas 1000)" "$cg_rel"
B2B_CGROUP_ROOT="$TMP/cg" wall_cgroup other 1000 >/dev/null
check "wall_cgroup: no unit, no cgroup" "$?" 1
rules=$(wall_rules baas "$cg_rel" 3001 8787)
check "rules match the unit at its depth" \
    "$(printf '%s\n' "$rules" | grep -c "socket cgroupv2 level 5 \"$cg_rel\" ct state new")" 1
check "rules run before hide's NAT (-100)" "$(printf '%s\n' "$rules" | grep -c 'priority -150')" 1
check "rules open the listed ports only" "$(printf '%s\n' "$rules" | grep -c 'tcp dport { 3001, 8787 } fib daddr type local accept')" 1
check "rules keep DNS" "$(printf '%s\n' "$rules" | grep -c 'th dport 53 fib daddr type local accept')" 1
check "rules end on a reject" "$(printf '%s\n' "$rules" | grep -c 'fib daddr type local counter reject')" 1
check "no ports, no port line" "$(wall_rules baas "$cg_rel" | grep -c 'tcp dport')" 0
check "no udp: port, no udp line" "$(printf '%s\n' "$rules" | grep -c 'udp dport')" 0
rules=$(wall_rules baas "$cg_rel" 3001 udp:41641 8787)
check "udp: ports get their own line" "$(printf '%s\n' "$rules" | grep -c 'udp dport { 41641 } fib daddr type local accept')" 1
check "udp: ports stay off the tcp line" "$(printf '%s\n' "$rules" | grep -c 'tcp dport { 3001, 8787 } fib daddr type local accept')" 1
check "udp: alone gives no tcp line" "$(wall_rules baas "$cg_rel" udp:41641 | grep -c 'tcp dport')" 0
# wall_ts_ports reads the unit's main pid, then only that pid's sockets: osionos-apps runs
# a second, userspace tailscaled whose ports must stay walled.
systemctl() { echo 3680; }
ss() {
    printf '%s\n' 'UNCONN 0 0 0.0.0.0:36853 0.0.0.0:* users:(("tailscaled",pid=74142,fd=12))' \
        'UNCONN 0 0 0.0.0.0:41641 0.0.0.0:* users:(("tailscaled",pid=3680,fd=19))' \
        'UNCONN 0 0 [::]:41641 [::]:* users:(("tailscaled",pid=3680,fd=18))' \
        'UNCONN 0 0 100.94.109.44:40001 0.0.0.0:* users:(("tailscaled",pid=3680,fd=21))' \
        'UNCONN 0 0 *:51820 *:* users:(("tailscaled",pid=3680,fd=22))' \
        'UNCONN 0 0 0.0.0.0:5353 0.0.0.0:* users:(("avahi",pid=36801,fd=12))'
}
export B2B_PROC_ROOT="$TMP/proc"
mkdir -p "$B2B_PROC_ROOT/3680"
check "wall_ts_ports: unpinned, the pid's wildcard ports once" "$(wall_ts_ports | tr '\n' ' ')" "41641 51820 "
printf '%s\0' /usr/sbin/tailscaled --state=x --port=41641 >"$B2B_PROC_ROOT/3680/cmdline"
check "wall_ts_ports: --port=N gives exactly N" "$(wall_ts_ports | tr '\n' ' ')" "41641 "
printf '%s\0' /usr/sbin/tailscaled --port 41641 >"$B2B_PROC_ROOT/3680/cmdline"
check "wall_ts_ports: --port N gives exactly N" "$(wall_ts_ports | tr '\n' ' ')" "41641 "
printf '%s\0' /usr/sbin/tailscaled --port=41700 >"$B2B_PROC_ROOT/3680/cmdline"
check "wall_ts_ports: a pin it does not hold, no port" "$(wall_ts_ports | wc -l)" 0
systemctl() { echo 0; }
check "wall_ts_ports: no tailscaled, no port" "$(wall_ts_ports | wc -l)" 0
unset -f systemctl ss
unset B2B_PROC_ROOT
(check_port 'udp:41641') 2>/dev/null
check "a udp:PORT is accepted" "$?" 0
(check_port 'udp:1,2') 2>/dev/null
check "a udp: list in one word is refused" "$?" 1
(check_vm 'baas;drop') 2>/dev/null
check "a VM name with nft syntax is refused" "$?" 1
(check_port '22,80') 2>/dev/null
check "a port list in one word is refused" "$?" 1
(check_port 70000) 2>/dev/null
check "a port past 65535 is refused" "$?" 1

# ── the tailnet policy ──────────────────────────────────────────────────────
policy() { python3 "$REPO_ROOT/setup/host/ts_share_policy.py" "$1" >"$1.out" 2>/dev/null; }
cat >"$TMP/default.hujson" <<'EOF'
{
	"grants": [
		// Allow all connections.
		// Comment this section out if you want to define specific restrictions.
		{"src": ["*"], "dst": ["*"], "ip": ["*"]},
	],
}
EOF
policy "$TMP/default.hujson"
check "the default policy is edited" "$?" 0
check "the allow-all grant is gone" "$(grep -c '"src": \["\*"\]' "$TMP/default.hujson.out")" 0
check "its comment is gone with it" "$(grep -c 'Allow all connections' "$TMP/default.hujson.out")" 0
check "members keep everything" "$(grep -c '"src": \["autogroup:member"\]' "$TMP/default.hujson.out")" 1
check "shared reaches sshd only" "$(grep -A2 'autogroup:shared' "$TMP/default.hujson.out" | grep -c '"tcp:4242"')" 1
cp "$TMP/default.hujson.out" "$TMP/again.hujson"
policy "$TMP/again.hujson"
check "an edited policy is left as it is" "$?" 3
cat >"$TMP/hand.hujson" <<'EOF'
{"grants": [{"src": ["group:dev"], "dst": ["tag:b2b"], "ip": ["*"]}]}
EOF
policy "$TMP/hand.hujson"
check "a hand-written policy is refused" "$?" 2
cat >"$TMP/both.hujson" <<'EOF'
{"grants": [{"src": ["*"], "dst": ["*"], "ip": ["*"]},
	{"src": ["autogroup:shared"], "dst": ["tag:b2b"], "ip": ["tcp:4242"]}]}
EOF
policy "$TMP/both.hujson"
check "shared beside allow-all is not done" "$?" 2

# ── ssh b2b ─────────────────────────────────────────────────────────────────
mkdir -p "$TMP/vm/t" "$TMP/home"
echo ssh=4243 >"$TMP/vm/t/ports.env"
ssh_config() {
    env VM_NAME=t VM_PATH="$TMP/vm" HOME="$TMP/home" VM_USER=bob \
        "${SCRIPT_SH:-bash}" "$REPO_ROOT/setup/host/qemu_vm.sh" ssh-config >/dev/null 2>&1
    grep -c 'RemoteForward 9222' "$TMP/home/.ssh/config"
}
check "ssh b2b forwards Chrome when not shared" "$(ssh_config)" 1
mkdir -p "$TMP/vm/t/guests"
echo ana@example.org >"$TMP/vm/t/guests/ana.email"
check "ssh b2b drops Chrome once shared" "$(ssh_config)" 0

# ── accounts that are not a guest's ─────────────────────────────────────────
ssh-keygen -q -t ed25519 -N '' -f "$TMP/key" >/dev/null
env VM_NAME=t VM_PATH="$TMP/vm" VM_USER=bob GUEST=bob EMAIL=a@example.org KEY="$TMP/key.pub" \
    "${SCRIPT_SH:-bash}" "$REPO_ROOT/setup/host/vm_share.sh" invite >/dev/null 2>&1
check "GUEST= the owner's login is refused" "$?" 1
mkdir -p "$TMP/bin"
for cmd in usermod useradd chage gpasswd pkill install chown; do
    printf '#!/bin/sh\necho %s >>"%s/calls"\n' "$cmd" "$TMP" >"$TMP/bin/$cmd"
done
printf '#!/bin/sh\nexit 0\n' >"$TMP/bin/id"
printf '#!/bin/sh\necho "bob:x:1000:1000:Bob,,,:%s/bob:/bin/sh"\n' "$TMP" >"$TMP/bin/getent"
printf '#!/bin/sh\necho /bin/sh\n' >"$TMP/bin/hellish"
chmod +x "$TMP/bin/"*
guest() {
    env PATH="$TMP/bin:$PATH" ROOTSH_ACTION="$1" ROOTSH_LOGIN=bob ROOTSH_KEY="$(cat "$TMP/key.pub")" \
        "${SCRIPT_SH:-bash}" "$REPO_ROOT/setup/host/vm_share_guest.sh" >/dev/null 2>&1
}
guest add
check "add refuses an account it did not create" "$?" 1
guest lock
check "lock refuses an account it did not create" "$?" 1
check "and changes nothing in it" "$(cat "$TMP/calls" 2>/dev/null)" ""

# ── the team workspace ──────────────────────────────────────────────────────
me=$(id -un)
other_gid=$(id -G | tr ' ' '\n' | grep -vx "$(id -g)" | head -n1)
mkdir -p "$TMP/ws/sub" "$TMP/ws/.git"
touch "$TMP/ws/a.txt" "$TMP/ws/sub/b.txt" "$TMP/ws/key.pem"
[ -z "$other_gid" ] || chgrp "$other_gid" "$TMP/ws/key.pem"
echo "B2B_LOGIN=$me" >"$TMP/build.conf"
rm -f "$TMP/calls"
for cmd in groupadd chgrp chmod setfacl git runuser; do
    printf '#!/bin/sh\necho "%s $*" >>"%s/calls"\n' "$cmd" "$TMP" >"$TMP/bin/$cmd"
done
printf '#!/bin/sh\n%s\n' "cp \"\$2\" \"$TMP/sudoers\"" >"$TMP/bin/visudo"
# install -o root needs root: the stub copies its last two arguments.
printf '#!/bin/sh\n%s\n' "for a; do s=\${d:-}; d=\$a; done; cp \"\$s\" \"\$d\"" >"$TMP/bin/install"
chmod +x "$TMP/bin/"*
# The group is the test user's own: find -group refuses a group this host lacks.
workspace() {
    env PATH="$TMP/bin:$PATH" ROOTSH_ACTION=workspace B2B_WORKSPACE="$TMP/ws" B2B_DEV_GROUP="$(id -gn)" \
        B2B_BUILD_CONF="$TMP/build.conf" B2B_DEV_SUDOERS="$TMP/sudoers.installed" \
        B2B_DEV_INVITE="$TMP/b2b-dev-invite" B2B_SSH_KNOWN_HOSTS="$TMP/ssh_known_hosts" \
        "${SCRIPT_SH:-bash}" "$REPO_ROOT/setup/host/vm_share_guest.sh" >/dev/null 2>&1
}
echo 'other.host ssh-ed25519 AAAAother' >"$TMP/ssh_known_hosts"
workspace
check "workspace runs" "$?" 0
if [ "$(id -gn)" = "$me" ]; then
    check "the owner's files go to dev" "$(grep '^chgrp' "$TMP/calls" | grep -c "$TMP/ws/sub/b.txt")" 1
    if [ -n "$other_gid" ]; then
        check "a file with another group keeps it" "$(grep '^chgrp' "$TMP/calls" | grep -c key.pem)" 0
        check "and dev gets it through an ACL" "$(grep '^setfacl -m g:' "$TMP/calls" | grep -c key.pem)" 1
    else
        echo "skip a file with another group keeps it (one group only)"
    fi
else
    echo "skip workspace group checks (no user private group here)"
fi
check "git config is run as the owner" \
    "$(grep -c "^runuser -u $me -- git -C $TMP/ws config core.sharedRepository group" "$TMP/calls")" 1
check "dev sudo is a list" "$(grep -c "^%$(id -gn) ALL=(root) NOPASSWD: B2B_DEV\$" "$TMP/sudoers")" 1
check "and never ALL as a command" "$(grep -v '^%' "$TMP/sudoers" | grep -c 'ALL')" 0
# A push from the VM with no known GitHub key stops at a prompt VS Code
# cannot answer: the keys go in once, beside what the file already holds.
workspace
check "GitHub's three host keys are trusted once" "$(grep -c '^github.com ' "$TMP/ssh_known_hosts")" 3
check "and the file's other lines stay" "$(grep -c '^other.host ' "$TMP/ssh_known_hosts")" 1
if [ -x /usr/sbin/visudo ]; then
    /usr/sbin/visudo -cf "$TMP/sudoers" >/dev/null 2>&1
    check "visudo parses the dev sudoers" "$?" 0
else
    echo "skip visudo parses the dev sudoers (no visudo)"
fi
check "members may run b2b-dev-invite" \
    "$(grep -cF '    /usr/local/sbin/b2b-dev-invite, ' "$TMP/sudoers")" 1

# ── a member brings an account into dev ─────────────────────────────────────
# Accounts: ana (1001, outside dev), bob (already in), old (locked by the
# owner: expired on day 1), root and a missing one.
dev=$(id -gn)
cat >"$TMP/bin/getent" <<'EOF'
#!/bin/sh
case "$1 $2" in
'passwd ana') echo 'ana:x:1001:1001:b2b guest:/home/ana:/bin/sh' ;;
'passwd bob') echo 'bob:x:1003:1003:b2b guest:/home/bob:/bin/sh' ;;
'passwd old') echo 'old:x:1002:1002:b2b guest:/home/old:/bin/sh' ;;
'passwd root') echo 'root:x:0:0:root:/root:/bin/sh' ;;
'shadow old') echo 'old:!*:20000:0:99999:7::1:' ;;
'shadow '*) echo "$2:*:20000::::::" ;;
*) exit 2 ;;
esac
EOF
printf '#!/bin/sh\n%s\n' "case \"\$2\" in bob) echo \"bob $dev\" ;; *) echo \"\$2\" ;; esac" >"$TMP/bin/id"
printf '#!/bin/sh\necho "usermod $*" >>"%s/calls"\n' "$TMP" >"$TMP/bin/usermod"
chmod +x "$TMP/bin/"*
invite() { env PATH="$TMP/bin:$PATH" sh "$TMP/b2b-dev-invite" "$@" >/dev/null 2>&1; }
rm -f "$TMP/calls"
invite ana
check "a member invites an account" "$?" 0
check "which joins the group" "$(grep -c "^usermod -aG $dev ana\$" "$TMP/calls" 2>/dev/null)" 1
invite bob
check "a member already in is left as is" "$?" 0
invite old
check "an account the owner locked is refused" "$?" 1
invite root
check "a system account is refused" "$?" 1
invite gone
check "a missing account is refused" "$?" 1
invite '-G root'
check "an option for a login is refused" "$?" 2
check "and nothing else was changed" "$(grep -c '^usermod' "$TMP/calls")" 1

# ── revoking a login of someone with two ────────────────────────────────────
eval "$(awk '/^other_guest_uses\(\) \{/,/^}/' "$REPO_ROOT/setup/host/vm_share.sh")"
GUESTS="$TMP/g"
mkdir -p "$GUESTS"
echo ana@example.org >"$GUESTS/ana.email"
other_guest_uses ana@example.org ana
check "a lone login takes its invite along" "$?" 1
echo ana@example.org >"$GUESTS/ana2.email"
other_guest_uses ana@example.org ana
check "a second login keeps the invite" "$?" 0

# ── the connect kit ─────────────────────────────────────────────────────────
mkdir -p "$TMP/vm/t/guests" "$TMP/kh/.ssh" "$TMP/sshbin"
echo TS_IP4=100.64.1.2 >"$TMP/vm/t/tailnet.env"
cp "$TMP/key.pub" "$TMP/vm/t/guests/ana.pub"
env VM_NAME=t VM_PATH="$TMP/vm" GUEST=ana \
    "${SCRIPT_SH:-bash}" "$REPO_ROOT/setup/host/vm_share.sh" kit >/dev/null 2>&1
check "share_kit writes both scripts" "$(find "$TMP/vm/t/guests" -name 'ana-connect.sh' -o -name 'ana-connect.ps1' | wc -l)" 2
check "no field left unfilled" "$(cat "$TMP/vm/t/guests/ana-connect."* | grep -c '@[A-Z]*@')" 0
cp "$TMP/key" "$TMP/key.pub" "$TMP/kh/.ssh/"
printf '#!/bin/sh\ncase "$*" in *PreferredAuthentications=none*) echo "Permission denied (publickey)." >&2; exit 255 ;; esac\necho "ssh $*" >>"%s/sessions"\n' "$TMP" >"$TMP/sshbin/ssh"
printf '#!/bin/sh\nexit 1\n' >"$TMP/sshbin/ssh-add"
chmod +x "$TMP/sshbin/ssh" "$TMP/sshbin/ssh-add"
printf 'Host *\n    User nobody\n' >"$TMP/kh/.ssh/config"
for _ in 1 2; do
    env HOME="$TMP/kh" PATH="$TMP/sshbin:$PATH" sh "$TMP/vm/t/guests/ana-connect.sh" >/dev/null 2>&1
done
check "the kit connects with ssh t" "$(grep -cx 'ssh t' "$TMP/sessions")" 2
check "its ssh block is written once" "$(grep -c '^Host t$' "$TMP/kh/.ssh/config")" 1
check "above the user's Host *" "$(grep -n '^Host ' "$TMP/kh/.ssh/config" | head -n1 | cut -d: -f2)" "Host t"
check "with the key that was registered" "$(grep -c "IdentityFile \"$TMP/kh/.ssh/key\"" "$TMP/kh/.ssh/config")" 1
# Without it a git push from the VM has no key: GitHub answers "Permission
# denied (publickey)" though the account knows this very key.
check "and the agent forwarded, for git push" "$(grep -c '^    ForwardAgent yes$' "$TMP/kh/.ssh/config")" 1

# Invited without a key: the kit makes one, prints it, and connects with
# it on a later run once the owner has registered it (make share_key).
: >"$TMP/vm/t/guests/cyd.pub"
env VM_NAME=t VM_PATH="$TMP/vm" GUEST=cyd \
    "${SCRIPT_SH:-bash}" "$REPO_ROOT/setup/host/vm_share.sh" kit >/dev/null 2>&1
check "a kit without a key is written" "$?" 0
mkdir -p "$TMP/kc/.ssh" "$TMP/kcbin"
cat >"$TMP/kcbin/ssh" <<EOF
#!/bin/sh
case "\$*" in
*PreferredAuthentications=none*) echo "Permission denied (publickey)." >&2; exit 255 ;;
*PreferredAuthentications=publickey*) [ -f "$TMP/accepted" ] || exit 255 ;;
*) echo "ssh \$*" >>"$TMP/kc-sessions" ;;
esac
EOF
printf '#!/bin/sh\n%s\n' "while [ \$# -gt 1 ]; do [ \"\$1\" = -f ] && f=\$2; shift; done; echo 'ssh-ed25519 AAAAnew cyd@t' >\"\$f.pub\"; : >\"\$f\"" >"$TMP/kcbin/ssh-keygen"
printf '#!/bin/sh\nexit 1\n' >"$TMP/kcbin/ssh-add"
chmod +x "$TMP/kcbin/"*
kc() { env HOME="$TMP/kc" PATH="$TMP/kcbin:$PATH" sh "$TMP/vm/t/guests/cyd-connect.sh" 2>&1; }
check "it prints the key it made" "$(kc | grep -c '^ssh-ed25519 AAAAnew')" 1
check "and does not connect yet" "$(grep -c "" "$TMP/kc-sessions" 2>/dev/null || echo 0)" 0
touch "$TMP/accepted"
kc >/dev/null
check "once registered the same kit connects" "$(grep -cx 'ssh t' "$TMP/kc-sessions")" 1
eval "$(awk '/^public_key\(\) \{/,/^}/' "$REPO_ROOT/setup/host/vm_share.sh")"
check "KEY= may be empty" "$(public_key '')" ""
public_key 'not a key' >/dev/null
check "but not anything else" "$?" 1
check "a key file gives its line" "$(public_key "$TMP/key.pub")" "$(cat "$TMP/key.pub")"

if command -v pwsh >/dev/null 2>&1; then
    # -Command appends trailing words to the code, so the path goes by env.
    B2B_PS1="$TMP/vm/t/guests/ana-connect.ps1" timeout 60 pwsh -NoProfile -Command \
        "\$e = \$null; [void][System.Management.Automation.Language.Parser]::ParseFile(\$env:B2B_PS1, [ref]\$null, [ref]\$e); exit \$e.Count" >/dev/null 2>&1
    check "the PowerShell kit parses" "$?" 0
else
    echo "skip the PowerShell kit parses (no pwsh)"
fi

exit "$fail"
