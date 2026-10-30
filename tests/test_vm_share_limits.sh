#!/usr/bin/env hellish
#
# test_vm_share_limits.sh — what vm_share_limits.sh does to a guest.
#
# A colleague who ran claude or a local model in the shared VM used the
# owner's RAM and CPU with nothing to stop it. This pins the three fences:
# every "b2b guest" account and no other gets the slice cap (and an open
# session gets it now, not after a new login), a drop-in left by an account
# that is no longer a guest goes, the nft table names exactly the guests'
# uids, the AI tools become the owner's, and a guest in the owner's primary
# group is refused rather than reported as fenced. systemd, nft, chown and
# the accounts are stand-ins.
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
TMP=$(mktemp -d)
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

mkdir -p "$TMP/bin" "$TMP/sd/user-1009.slice.d" "$TMP/tools"
echo 'B2B_LOGIN=own' >"$TMP/build.conf"
printf 'own:x:1000:1000::/h/own:/bin/sh\nana:x:1001:1001:b2b guest:/h/ana:/bin/sh\nsvc:x:1002:1002::/h/svc:/bin/sh\nbob:x:1003:1003:b2b guest:/h/bob:/bin/sh\n' >"$TMP/passwd"
echo stale >"$TMP/sd/user-1009.slice.d/50-b2b-guest.conf"
echo stays >"$TMP/sd/user-1009.slice.d/10-other.conf"
printf '#!/bin/sh\n' >"$TMP/tools/claude"
chmod 755 "$TMP/tools/claude"
ln -s claude "$TMP/tools/opencode-link"

cat >"$TMP/bin/getent" <<'STUBEOF'
#!/bin/sh
p="$(dirname "$0")/../passwd"
if [ $# -eq 1 ]; then cat "$p"; else awk -F: -v k="$2" '$1 == k || $3 == k' "$p"; fi
STUBEOF
cat >"$TMP/bin/id" <<'STUBEOF'
#!/bin/sh
case "$1" in
-gn) echo own ;;
-nG) [ "$2" = bob ] && echo "bob docker ${BOB_GROUPS:-}" || echo "$2" ;;
esac
STUBEOF
cat >"$TMP/bin/systemctl" <<'STUBEOF'
#!/bin/sh
echo "systemctl $*" >>"$(dirname "$0")/../calls"
[ "$1 $3" != "is-active user-1001.slice" ]
STUBEOF
printf '#!/bin/sh\necho "nft $*" >>"%s/calls"\n' "$TMP" >"$TMP/bin/nft"
printf '#!/bin/sh\necho "chown $*" >>"%s/calls"\n' "$TMP" >"$TMP/bin/chown"
chmod +x "$TMP/bin/"*

run() {
    rm -f "$TMP/calls"
    env PATH="$TMP/bin:$PATH" B2B_BUILD_CONF="$TMP/build.conf" B2B_SLICE_DIR="$TMP/sd" \
        B2B_LIMITS_NFT="$TMP/etc/guest-limits.nft" B2B_LIMITS_UNIT="$TMP/sd/b2b-guest-limits.service" \
        B2B_AI_TOOLS="$TMP/tools/opencode-link $TMP/tools/absent" "$@" \
        "${SCRIPT_SH:-bash}" "$REPO_ROOT/setup/host/vm_share_limits.sh" >"$TMP/out" 2>&1
}

run
check "applied" "$?" 0
check "the verdict line" "$(cat "$TMP/out")" "limits: 2 guest(s) capped (1536M, 50% CPU), host blocked, owner-only: opencode-link"
check "ana is capped" "$(grep -c '^MemoryMax=1536M$' "$TMP/sd/user-1001.slice.d/50-b2b-guest.conf")" 1
check "bob is capped" "$(grep -c '^CPUQuota=50%$' "$TMP/sd/user-1003.slice.d/50-b2b-guest.conf")" 1
check "the owner is not" "$([ -e "$TMP/sd/user-1000.slice.d" ] && echo capped || echo free)" free
check "a service account is not" "$([ -e "$TMP/sd/user-1002.slice.d" ] && echo capped || echo free)" free
check "a former guest's drop-in goes" "$([ -e "$TMP/sd/user-1009.slice.d/50-b2b-guest.conf" ] && echo kept || echo gone)" gone
check "another drop-in beside it stays" "$(cat "$TMP/sd/user-1009.slice.d/10-other.conf")" stays
check "only the open session is changed now" "$(grep -c 'set-property --runtime' "$TMP/calls")" 1
check "and it is bob's" "$(grep -c 'set-property --runtime user-1003.slice MemoryHigh=1280M MemoryMax=1536M' "$TMP/calls")" 1
check "the host is walled for both, v4" "$(grep -c 'meta skuid { 1001, 1003 } ip daddr 10.0.2.2 reject' "$TMP/etc/guest-limits.nft")" 1
check "and v6" "$(grep -c 'meta skuid { 1001, 1003 } ip6 daddr fec0::2 reject' "$TMP/etc/guest-limits.nft")" 1
check "the wall is loaded" "$(grep -c "^nft -f $TMP/etc/guest-limits.nft" "$TMP/calls")" 1
check "and enabled for the next boot" "$(grep -c '^systemctl enable --quiet b2b-guest-limits.service' "$TMP/calls")" 1
check "the tool's target is the owner's" "$(grep -c "^chown root:own $TMP/tools/claude" "$TMP/calls")" 1
check "and closed to the others" "$(stat -c %a "$TMP/tools/claude")" 750

run BOB_GROUPS=own
check "a guest in the owner's group is refused" "$?" 1
check "and named" "$(grep -c '^bob is in own' "$TMP/out")" 1

printf 'own:x:1000:1000::/h/own:/bin/sh\n' >"$TMP/passwd"
run
check "no guest left: still applied" "$?" 0
check "and the wall names nobody" "$(grep -c skuid "$TMP/etc/guest-limits.nft")" 0
check "and every cap is gone" "$(find "$TMP/sd" -name 50-b2b-guest.conf | wc -l)" 0

exit "$fail"
