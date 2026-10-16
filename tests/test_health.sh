#!/usr/bin/env hellish
# make health's own rules: which host addresses are the LAN and Wi-Fi, which
# forward speaks which scheme, and what counts as an answer.
#
# Why: health.sh proves the WAF answers on every network a machine beside
# this one could come from. On c2r19s6 (2026-10-16) the host had enp2s0f1
# (the campus LAN) beside virbr0, docker0 and vboxnet0; a probe on a bridge
# would "pass" through an address no other machine can reach. A home laptop
# has a wlan0 too, and that one must be probed.
#
# HOW: health.sh is sourced with B2B_HEALTH_LIB=1 (its main does not run);
# ip and curl are stubs on PATH.
set -u

cd "$(dirname "$0")/.." || exit 1
TMP=$(mktemp -d)
trap 'rm -rf "${TMP:?}"' EXIT
export B2B_CONFIG=profiles/server.toml

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
cat >"$TMP/bin/ip" <<'EOF'
#!/bin/sh
cat <<'IP'
2: enp2s0f1    inet 10.12.19.6/16 brd 10.12.255.255 scope global dynamic enp2s0f1
3: wlan0    inet 192.168.1.132/24 brd 192.168.1.255 scope global dynamic wlan0
4: virbr0    inet 192.168.122.1/24 brd 192.168.122.255 scope global virbr0
5: docker0    inet 172.17.0.1/16 brd 172.17.255.255 scope global docker0
6: vboxnet0    inet 192.168.56.1/24 brd 192.168.56.255 scope global vboxnet0
7: br-939b139b51fd    inet 172.19.0.1/16 brd 172.19.255.255 scope global br-939b139b51fd
IP
EOF
cat >"$TMP/bin/curl" <<'EOF'
#!/bin/sh
for a; do url=$a; done
case "$url" in
*:8443/) printf 404 ;;
*) printf 000; exit 7 ;;
esac
EOF
chmod +x "$TMP/bin/ip" "$TMP/bin/curl"
PATH="$TMP/bin:$PATH"
B2B_HEALTH_LIB=1
. setup/host/health.sh

check "LAN and Wi-Fi only: no hypervisor or container bridge" \
    "$(host_lan_addresses | tr '\n' ' ')" "enp2s0f1 10.12.19.6 wlan0 192.168.1.132 "
check "scheme: https, inception-https, http, ssh" \
    "$(scheme_of https) $(scheme_of inception-https) $(scheme_of http) $(scheme_of ssh)" "https https http ssh"
check "404 is an answer (the WAF at /)" "$(answered 404 && echo yes)" yes
check "000 is none (nothing listening)" "$(answered 000 || echo no)" no
check "an empty code is none" "$(answered '' || echo no)" no
out=$(probe_forward https 8443 10.12.19.6)
check "probe: the WAF answering passes, saying where" "$(printf '%s' "$out" | grep -c 'https://10.12.19.6:8443 answers (HTTP 404)')" 1
out=$(
    probe_forward http 8082 10.12.19.6
    echo "fail=$fail"
)
check "probe: nothing on the port flunks" "$(printf '%s' "$out" | grep -c -e 'nothing answers on http://10.12.19.6:8082' -e '^fail=1$')" 2
exit "$fail"
