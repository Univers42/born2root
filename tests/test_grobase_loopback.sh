#!/usr/bin/env hellish
# Every grobase port but the WAF's binds the guest's loopback.
#
# THE FAILURE IT PINS
#   2026-10-14, grobase main 8b9321a6: vault42.yml publishes
#   "${VAULT42_PORT:-18443}:8443". install_grobase.sh's rewrite matched a
#   defaulted port only when the variable name was letters and underscores,
#   so the digits in VAULT42 left it on 0.0.0.0, and the check after the
#   rewrite, written with the same class, counted zero open ports. Docker's
#   published ports bypass UFW: on the tailnet that is every peer.
#
# HOW
#   The loop is cut out of install_grobase.sh from its exact
#   `for yml in orchestrators/compose/base/*.yml; do` line to the next `done`
#   and run over fixture compose files in a temp tree, twice.
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

LOOP=$(awk '/^for yml in orchestrators\/compose\/base\/\*\.yml; do$/,/^done$/' "$SRC")
[ -n "$LOOP" ] || {
    echo "FAIL could not extract the loopback loop from $SRC"
    exit 1
}

TMP=$(mktemp -d)
trap 'rm -rf "${TMP:?}"' EXIT
BASE="$TMP/orchestrators/compose/base"
mkdir -p "$BASE"
cat >"$BASE/services.yml" <<'YML'
services:
  prometheus:
    ports:
      - "9090:9090"
  loki:
    ports:
      - "${LOKI_PORT:-3100}:3100"
  vault42:
    ports:
      # a comment between ports: and the item
      - "${VAULT42_PORT:-18443}:8443"
  kong:
    ports:
      - "127.0.0.1:${KONG_HTTP_PORT:-8000}:8000"
  postgres:
    ports:
      - "${ENGINE_BIND_ADDR:-127.0.0.1}:${PG_PORT:-5432}:5432"
YML
cat >"$BASE/gateway.yml" <<'YML'
services:
  waf:
    ports:
      - "${WAF_HTTP_PORT:-8880}:80"
      - "${WAF_HTTPS_PORT:-8443}:443"
YML

# shellcheck disable=SC2329 # called by the eval'd loop
die() {
    echo "died: $*"
    return 1
}
run_loop() {
    (cd "$TMP" && eval "$LOOP")
}

check "the loop runs to the end" "$(run_loop && echo finished)" finished
item() { grep -F -- "$1" "$BASE/services.yml" | sed 's/^ *- //'; }
check "a literal port goes to loopback" "$(item ':9090"')" '"127.0.0.1:9090:9090"'
check "a defaulted port goes to loopback" "$(item 'LOKI_PORT')" '"127.0.0.1:${LOKI_PORT:-3100}:3100"'
check "a variable name with digits goes to loopback" "$(item 'VAULT42_PORT')" \
    '"127.0.0.1:${VAULT42_PORT:-18443}:8443"'
check "a port already on loopback is left alone" "$(item 'KONG_HTTP_PORT')" \
    '"127.0.0.1:${KONG_HTTP_PORT:-8000}:8000"'
check "ENGINE_BIND_ADDR keeps its own loopback default" "$(item 'ENGINE_BIND_ADDR')" \
    '"${ENGINE_BIND_ADDR:-127.0.0.1}:${PG_PORT:-5432}:5432"'
check "the WAF stays the one door off loopback" "$(grep -c '127.0.0.1' "$BASE/gateway.yml" || true)" 0

before=$(cat "$BASE/services.yml")
run_loop >/dev/null
check "a second run changes nothing" "$(cat "$BASE/services.yml")" "$before"

# The check after the rewrite is what stops the install: a port the rewrite
# cannot reach must be counted, digits in its name or not. A read-only
# directory is what makes sed -i fail (it replaces the file, so the file's
# own mode does not stop it); as root nothing does, hence the skip.
sed -i 's/"127.0.0.1:${VAULT42_PORT/"${VAULT42_PORT/' "$BASE/services.yml"
if [ "$(id -u)" = 0 ]; then
    printf 'skip an open port the rewrite missed stops the install (root)\n'
else
    chmod a-w "$BASE"
    check "an open port the rewrite missed stops the install" \
        "$(run_loop 2>/dev/null | grep -c 'still publishes 1 port' || true)" 1
    chmod u+w "$BASE"
fi

exit "$fail"
