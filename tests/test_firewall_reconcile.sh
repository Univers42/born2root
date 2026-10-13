#!/usr/bin/env hellish
# `make firewall` makes a live guest's UFW match the profile's forwards:
# what the profile lists is allowed, what born2root once added and the
# profile no longer lists is deleted, everything else is left alone.
#
# THE FAILURE IT PINS
#   2026-10-13 audit of baas: UFW still allowed 8090, 8080, 21,
#   21000-21010, 5000, 3306, 6379, 5173, 3000 and 18200 -- forwards the
#   profile had carried once. First boot resets UFW and applies the list,
#   but nothing ever took a port back from a running guest.
#
# WHAT IS CHECKED
#   Against a stateful stub ufw seeded with baas's rule list (numbered, v4
#   and v6), firewall_guest.sh deletes every stale born2root rule, highest
#   number first. It keeps 4242 (even when the list omits it), the
#   tailscale0 rule, a hand-added rule without a comment, and one limited
#   to a source address. It adds a listed port that is missing, and a
#   second run changes nothing.
#
# HOW
#   The stub keeps its rules in a file, one `ufw status` line each, and
#   implements the three calls the script makes: status [numbered],
#   allow PORT/tcp comment NAME, --force delete NUMBER.
set -e

cd "$(dirname "$0")/.."

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s -- got: %s, expected: %s\n' "$1" "$2" "$3"
        fail=1
    fi
}

TMP=$(mktemp -d)
trap 'rm -rf "${TMP:?}"' EXIT
mkdir -p "$TMP/bin"
cat >"$TMP/bin/ufw" <<'EOF'
#!/bin/sh
rules="$STUB_DIR/rules"
printf '%s\n' "$*" >>"$STUB_DIR/calls"
[ "$1" = --force ] && shift
case "$1 ${2:-}" in
"status numbered" | "status ")
    echo "Status: active"
    echo
    echo "     To                         Action      From"
    echo "     --                         ------      ----"
    if [ "${2:-}" = numbered ]; then
        awk '{ printf "[%2d] %s\n", NR, $0 }' "$rules"
    else
        sed 's/^/     /' "$rules"
    fi
    ;;
"delete "*)
    awk -v n="$2" 'NR != n' "$rules" >"$rules.new" && mv "$rules.new" "$rules"
    ;;
"allow "*)
    port=${2%/tcp}
    grep -q "^$port/tcp " "$rules" && { echo "Skipping adding existing rule"; exit 0; }
    printf '%-26s ALLOW IN    Anywhere                   # %s\n' "$2" "$4" >>"$rules"
    ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/ufw"
export STUB_DIR="$TMP"

# baas's list on 2026-10-13 (audit 09.out), cut to one of each kind, plus a
# hand-added rule without a comment and one limited to a source address.
seed() {
    cat >"$TMP/rules" <<'EOF'
4242/tcp                   ALLOW IN    Anywhere                   # ssh
8880/tcp                   ALLOW IN    Anywhere                   # http
8443/tcp                   ALLOW IN    Anywhere                   # https
8090/tcp                   ALLOW IN    Anywhere                   # inception-static
21000/tcp                  ALLOW IN    Anywhere                   # inception-ftp-pasv-21000
5000/tcp                   ALLOW IN    Anywhere                   # docker
9999/tcp                   ALLOW IN    Anywhere
7000/tcp                   ALLOW IN    10.0.0.5                   # lab
Anywhere on tailscale0     ALLOW IN    Anywhere                   # tailnet
4242/tcp (v6)              ALLOW IN    Anywhere (v6)              # ssh
8880/tcp (v6)              ALLOW IN    Anywhere (v6)              # http
8443/tcp (v6)              ALLOW IN    Anywhere (v6)              # https
8090/tcp (v6)              ALLOW IN    Anywhere (v6)              # inception-static
21000/tcp (v6)             ALLOW IN    Anywhere (v6)              # inception-ftp-pasv-21000
5000/tcp (v6)              ALLOW IN    Anywhere (v6)              # docker
Anywhere (v6) on tailscale0 ALLOW IN   Anywhere (v6)              # tailnet
EOF
}
run() { # <firewall list> -> exit code
    : >"$TMP/calls"
    env PATH="$TMP/bin:$PATH" ROOTSH_FIREWALL="$1" "${SCRIPT_SH:-bash}" setup/host/firewall_guest.sh >"$TMP/out" 2>&1 &&
        echo 0 || echo $?
}

seed
check "baas's profile list: exit 0" "$(run 'ssh:4242 http:8880 https:8443')" 0
check "every stale born2root rule gone, v4 and v6" \
    "$(grep -cE '^(8090|21000|5000)/tcp' "$TMP/rules" || true)" 0
check "... deleted highest number first (numbers stay valid)" \
    "$(sed -n 's/^--force delete //p' "$TMP/calls" | tr '\n' ' ')" "15 14 13 6 5 4 "
check "the listed ports stay" "$(grep -cE '^(4242|8880|8443)/tcp' "$TMP/rules")" 6
check "tailscale0 stays (v4 and v6)" "$(grep -c 'on tailscale0' "$TMP/rules")" 2
check "a rule without a comment is not born2root's: kept" "$(grep -c '^9999/tcp' "$TMP/rules")" 1
check "a rule limited to a source is not born2root's: kept" "$(grep -c '^7000/tcp' "$TMP/rules")" 1
check "the result is named" "$(grep -c 'allowed: 4242 8880 8443; removed 5000 8090 21000$' "$TMP/out")" 1

cp "$TMP/rules" "$TMP/rules.after"
check "a second run: exit 0" "$(run 'ssh:4242 http:8880 https:8443')" 0
check "... deletes nothing" "$(grep -c 'delete' "$TMP/calls" || true)" 0
check "... and the rules are as they were" "$(cmp -s "$TMP/rules.after" "$TMP/rules" && echo same)" same

seed
check "a list without ssh: exit 0" "$(run 'http:8880')" 0
check "... 4242 is kept anyway (the only way in)" "$(grep -c '^4242/tcp' "$TMP/rules")" 2
check "... and 8443 is gone" "$(grep -c '^8443/tcp' "$TMP/rules" || true)" 0

seed
check "a listed port that is missing: exit 0" "$(run 'ssh:4242 http:8880 https:8443 api:9443')" 0
check "... is added, named after its forward" "$(grep -c '^9443/tcp .*# api$' "$TMP/rules")" 1

check "no list at all: refused (it would delete every forward)" "$(run '')" 1

# ── make firewall: the host's profile, now, through root-sh ─────────────────
want=$(env B2B_CONFIG=tests/fixtures/default.toml bash utils/b2b_config.sh get B2B_FIREWALL)
plan=$(env B2B_SECRETS="$TMP/secrets" make -n --no-print-directory firewall B2B_CONFIG=tests/fixtures/default.toml 2>/dev/null || true)
check "make firewall hands the profile's list to the guest script as root" \
    "$(printf '%s\n' "$plan" | grep -cF "ROOTSH_FIREWALL=\"$want\" ROOT_SH=setup/host/firewall_guest.sh")" 1
check "... through provision_vm.sh root-sh" "$(printf '%s\n' "$plan" | grep -c 'provision_vm.sh "[^"]*" root-sh$')" 1

exit "$fail"
