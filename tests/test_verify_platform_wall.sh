#!/usr/bin/env hellish
# verify_platform's wall: nothing listens off loopback but sshd, the WAF and
# the guest ports [network] forwards declares.
#
# The bug it pins: on baas (2026-10-16) the check allowed only 4242 and the
# WAF, and failed on Inception's nginx (443), static site (8090) and Adminer
# (8080) -- forwards profiles/server.toml declares, published on the NAT
# address because that is the only place a forward lands. The FTP set beside
# them (21, 21000-21010) was declared nowhere and must still fail it.
#
# HOW: the block from "# ── the wall" to the next blank printf is cut out of
# verify_platform.sh with the real hard(); vm_ssh runs its command here, with
# ss and docker stubbed on PATH. The listener list is that guest's ss -ltn.
set -u

cd "$(dirname "$0")/.." || exit 1
TMP=$(mktemp -d)
trap 'rm -rf "${TMP:?}"' EXIT
SCRIPT=setup/host/verify_platform.sh
export B2B_CONFIG=profiles/server.toml
. utils/b2b_config.sh

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s -- got: %s, expected: %s\n' "$1" "$2" "$3"
        fail=1
    fi
}

mkdir -p "$TMP/bin"
cat >"$TMP/bin/ss" <<'EOF'
#!/bin/sh
echo 'State  Recv-Q Send-Q Local-Address:Port Peer-Address:Port'
printf '%s\n' $LISTENERS | awk 'NF { print "LISTEN 0 4096 " $1 " 0.0.0.0:*" }'
EOF
cat >"$TMP/bin/docker" <<'EOF'
#!/bin/sh
printf '443/tcp -> 0.0.0.0:8443\n80/tcp -> 0.0.0.0:8880\n'
EOF
chmod +x "$TMP/bin/ss" "$TMP/bin/docker"

# Read by hard() and the wall block, both run through eval below.
# shellcheck disable=SC2034
C_R='' C_RED='' C_DIM=''
# shellcheck disable=SC2329,SC2317
ok() { printf 'PASS %s\n' "$*"; }
# shellcheck disable=SC2329,SC2317
vm_ssh() { PATH="$TMP/bin:$PATH" bash -c "$1"; }
eval "$(awk '/^hard\(\) \{/,/^}/' "$SCRIPT")"
WALL=$(awk '/^# ── the wall/ { on = 1 } on && /^printf .\\n.$/ { exit } on' "$SCRIPT")
check "the wall block was found" "$(printf '%s\n' "$WALL" | grep -c '^hard ')" 1

wall() { # LISTENERS... -> PASS or FAIL; the subshell keeps this file's $fail
    # shellcheck disable=SC2030 # that subshell is the point
    (
        LISTENERS="$*"
        export LISTENERS
        fail=0
        eval "$WALL"
        [ "$fail" = 0 ]
    ) >"$TMP/out" 2>&1 && printf PASS || printf FAIL
}

BAAS=(0.0.0.0:4242 0.0.0.0:8443 0.0.0.0:8880 "[::]:4242" "[::]:8443" "[::]:8880"
    10.0.2.15:443 10.0.2.15:8080 10.0.2.15:8090 127.0.0.1:8000 127.0.0.1:5432
    100.119.10.117%tailscale0:443 100.119.10.117%tailscale0:51966
    "[fd7a:115c:a1e0::b937:a76]%tailscale0:443" "[::1]:631")
check "baas: sshd, the WAF, Inception's declared three, the tailnet" "$(wall "${BAAS[@]}")" PASS
check "... the label names Inception's doors" "$(grep -c '|8080|8090|' "$TMP/out")" 1
check "FTP on the NAT address, declared nowhere: refused" \
    "$(wall "${BAAS[@]}" 10.0.2.15:21 10.0.2.15:21000)" FAIL
check "a database on every address: refused" "$(wall "${BAAS[@]}" 0.0.0.0:5432)" FAIL
# shellcheck disable=SC2031 # this file's $fail, never the subshell's
exit "$fail"
