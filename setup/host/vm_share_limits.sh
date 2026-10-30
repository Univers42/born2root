#!/usr/bin/env hellish
# vm_share_limits.sh — what a colleague's account may consume in the guest, as
# root, through provision_vm.sh root-sh (vm_share.sh sends it after every
# invite and on make share). Every account carrying the "b2b guest" comment
# (vm_share_guest.sh add) gets the same three fences; the owner and grobase
# get none.
#
#   1. A cgroup cap on the account's user slice, where pam_systemd puts every
#      SSH session and everything it starts: 1.5 GiB, no swap, half a CPU,
#      and a low CPU and IO weight, so grobase wins any contention. 1.5 GiB
#      because VS Code Remote-SSH with Copilot measured 736 MiB anonymous for
#      one colleague (baas, 2026-10-26), which 768 MiB would have killed. Each
#      account is capped on its own, so five of them can take 2.5 CPUs and
#      7.5 GiB of the VM's 4 and 10 GiB at most.
#   2. No traffic from those accounts to the host (10.0.2.2 for QEMU's slirp,
#      fec0::2 for its IPv6): the host serves local models (make llm_host) and
#      the IDE plane there, and neither is a colleague's to load. An nft table
#      of its own, beside ufw's and docker's, reloaded at boot by a unit.
#   3. claude and opencode run for the owner only: root:<the owner's primary
#      group>, 750. Not a group of its own, which the owner's open sessions
#      would only see after a new login.
#
# The aim is to stop heavy work run by accident, not a colleague set on it.
# Caveat: a guest is in the docker group, and a container runs outside the
# user slice and outside the owner match, so `docker run` passes all three;
# a copy of claude installed in a guest's home passes the third (the cap then
# holds it). An update that rewrites claude or opencode resets their mode:
# make share sets it again.
set -u
B2B_BUILD_CONF="${B2B_BUILD_CONF:-/etc/b2b/build.conf}"
SLICE_DIR="${B2B_SLICE_DIR:-/etc/systemd/system}"
LIMITS_NFT="${B2B_LIMITS_NFT:-/etc/b2b/guest-limits.nft}"
LIMITS_UNIT="${B2B_LIMITS_UNIT:-/etc/systemd/system/b2b-guest-limits.service}"
AI_TOOLS="${B2B_AI_TOOLS:-/usr/local/bin/claude /usr/local/bin/opencode}"
DROPIN=50-b2b-guest.conf
SLICE_LIMITS='MemoryHigh=1280M
MemoryMax=1536M
MemorySwapMax=0
CPUQuota=50%
CPUWeight=20
IOWeight=20
TasksMax=512'

owner=$(sed -n 's/^B2B_LOGIN=//p' "$B2B_BUILD_CONF" 2>/dev/null | head -n1)
[ -n "$owner" ] || {
    echo "$B2B_BUILD_CONF names no B2B_LOGIN" >&2
    exit 1
}
uids=$(getent passwd | awk -F: '$5 == "b2b guest" {print $3}' | sort -n | tr '\n' ' ')

# 1. Every guest's slice capped, and a drop-in left by an account that is no
# longer a guest removed. --runtime applies it to sessions already open,
# which a daemon-reload alone leaves at their old limits.
for dir in "$SLICE_DIR"/user-*.slice.d; do
    [ -f "$dir/$DROPIN" ] || continue
    uid=${dir##*/user-}
    uid=${uid%.slice.d}
    case " $uids " in *" $uid "*) ;; *) rm -f "$dir/$DROPIN" ;; esac
done
for uid in $uids; do
    mkdir -p "$SLICE_DIR/user-$uid.slice.d"
    printf '# vm_share_limits.sh: a colleague account, capped.\n[Slice]\n%s\n' "$SLICE_LIMITS" \
        >"$SLICE_DIR/user-$uid.slice.d/$DROPIN"
done
systemctl daemon-reload
for uid in $uids; do
    if systemctl is-active --quiet "user-$uid.slice"; then
        # shellcheck disable=SC2086 # one property per word
        systemctl set-property --runtime "user-$uid.slice" $SLICE_LIMITS
    fi
done

# 2. The host walled off from the guests' own processes. The table is
# replaced whole, so a revoked account's uid leaves with the next run.
mkdir -p "$(dirname "$LIMITS_NFT")"
{
    echo '# vm_share_limits.sh: no colleague process reaches the host.'
    echo 'table inet b2b_guest'
    echo 'delete table inet b2b_guest'
    echo 'table inet b2b_guest {'
    echo '    chain output {'
    echo '        type filter hook output priority filter; policy accept;'
    if [ -n "$uids" ]; then
        set_uids=$(printf '%s' "$uids" | sed 's/ *$//; s/ /, /g')
        echo "        meta skuid { $set_uids } ip daddr 10.0.2.2 reject"
        echo "        meta skuid { $set_uids } ip6 daddr fec0::2 reject"
    fi
    echo '    }'
    echo '}'
} >"$LIMITS_NFT"
cat >"$LIMITS_UNIT" <<UNITEOF
# vm_share_limits.sh: the guests' host wall, loaded again at every boot.
[Unit]
Description=b2b: colleague accounts cannot reach the host
After=network-pre.target
Before=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f $LIMITS_NFT

[Install]
WantedBy=multi-user.target
UNITEOF
systemctl daemon-reload
systemctl enable --quiet "$(basename "$LIMITS_UNIT")"
nft -f "$LIMITS_NFT" || {
    echo "nft refused $LIMITS_NFT" >&2
    exit 1
}

# 3. The AI tools, the owner's. A guest in the owner's primary group would
# keep them, so that is refused rather than reported as fenced.
group=$(id -gn "$owner") || exit 1
for uid in $uids; do
    user=$(getent passwd "$uid" | cut -d: -f1)
    if id -nG "$user" | tr ' ' '\n' | grep -qx "$group"; then
        echo "$user is in $group, $owner's primary group: claude and opencode stay open to it" >&2
        exit 1
    fi
done
fenced=''
for tool in $AI_TOOLS; do
    real=$(readlink -f "$tool" 2>/dev/null)
    [ -f "$real" ] || continue
    chown "root:$group" "$real" || exit 1
    chmod 750 "$real" || exit 1
    fenced="$fenced ${tool##*/}"
done

echo "limits: $(printf '%s' "$uids" | wc -w) guest(s) capped (1536M, 50% CPU), host blocked, owner-only:${fenced:- none}"
