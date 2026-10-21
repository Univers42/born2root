#!/usr/bin/env hellish
# The WAF's TLS port binds the guest's loopback and NAT address, never 0.0.0.0.
#
# THE FAILURE IT PINS
#   2026-10-21, baas after an OOM kill: tailscaled came up first and listened
#   on <tailnet IP>:8443 for groot's Funnel, dockerd's wildcard bind of the
#   WAF's "${WAF_HTTPS_PORT:-8443}:443" failed with "address already in use",
#   and the WAF stayed up on no network: every API call of the public app
#   failed while every other container was healthy.
#
# HOW
#   The loop is cut out of install_grobase.sh from its exact
#   `for yml in orchestrators/compose/base/gateway.yml ...; do` line to the
#   next `done` and run over fixture compose files in a temp tree, twice.
# shellcheck disable=SC2016 # every ${...} here is compose text, never an expansion
set -e

cd "$(dirname "$0")/.."
SRC=setup/install/dc/install_grobase.sh

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s -- got: %s, expected: %s\n' "$1" "$2" "$3"
        fail=1
    fi
}

LOOP=$(awk '/^for yml in orchestrators\/compose\/base\/gateway\.yml orchestrators\/compose\/docker-compose\.\*\.yml; do$/,/^done$/' "$SRC")
[ -n "$LOOP" ] || {
    echo "FAIL could not extract the WAF bind loop from $SRC"
    exit 1
}

TMP=$(mktemp -d)
trap 'rm -rf "${TMP:?}"' EXIT
mkdir -p "$TMP/orchestrators/compose/base"
cat >"$TMP/orchestrators/compose/base/gateway.yml" <<'YML'
services:
  waf:
    ports:
      - "${WAF_HTTP_PORT:-8880}:80"
      - "${WAF_HTTPS_PORT:-8443}:443"
YML
cat >"$TMP/orchestrators/compose/docker-compose.remote-access.yml" <<'YML'
services:
  waf:
    ports: !override
      - "127.0.0.1:${WAF_HTTP_PORT:-8880}:80"
      - "${WAF_HTTPS_PORT:-8443}:443"
YML
want=$(printf '      - "%s:${WAF_HTTPS_PORT:-8443}:443"\n' 127.0.0.1 10.0.2.15)

# shellcheck disable=SC2317,SC2329 # called by the eval'd loop
die() {
    echo "died: $*"
    return 1
}
run_loop() {
    (cd "$TMP" && eval "$LOOP")
}

for pass in 1 2; do
    check "pass $pass: the loop runs to the end" "$(run_loop && echo finished)" finished
    for f in base/gateway.yml docker-compose.remote-access.yml; do
        got=$(grep ':443"' "$TMP/orchestrators/compose/$f")
        check "pass $pass: $f binds loopback + NAT" "$got" "$want"
    done
done
cat >"$TMP/orchestrators/compose/docker-compose.monolith.yml" <<'YML'
services:
  waf:
    ports:
      - "${WAF_HTTPS_PORT}:443"
YML
check "a port without a default is rewritten too" "$(run_loop >/dev/null && grep -c '^      - "\(127.0.0.1\|10.0.2.15\):${WAF_HTTPS_PORT}:443"$' "$TMP/orchestrators/compose/docker-compose.monolith.yml")" 2
printf '      - "${WAF_HTTPS_PORT:-x}:443"\n' >>"$TMP/orchestrators/compose/docker-compose.monolith.yml"
check "a WAF line the rewrite misses stops the install" "$(run_loop | grep -c 'still publishes')" 1
check "the plaintext port is left alone" "$(grep -c '"${WAF_HTTP_PORT:-8880}:80"' "$TMP/orchestrators/compose/base/gateway.yml")" 1

exit "$fail"
