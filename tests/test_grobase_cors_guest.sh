#!/usr/bin/env hellish
# grobase_cors_guest.sh adds to the realtime origin list; it never rebuilds it.
#
# THE FAILURE IT PINS
#   The script recomputed REALTIME_ALLOWED_ORIGINS from Kong's
#   KONG_CORS_ORIGIN_* lines plus its own arguments, so every call dropped what
#   the profile ([dc.grobase_env]) and `make tailnet` had put there. On
#   2026-10-21 groot's public osionos app (https://baas.<tailnet>:8443) was not
#   in the list and every browser handshake got 403 while curl, which sends no
#   Origin, got 101. This runs the real script against a fake grobase
#   directory with docker stubbed, and checks the list only grows, in both
#   .env and .env.local, without duplicates.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-44s = %s\n' "$1" "$2"
    else
        printf 'FAIL %-44s = %s (want %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}

G=$TMP/grobase
mkdir -p "$G/infra/docker/services/kong/conf" "$TMP/bin"
printf '      origins:\n        - __KONG_CORS_ORIGIN_FRONTEND__\n' >"$G/infra/docker/services/kong/conf/kong.yml"
printf 'KONG_CORS_ORIGIN_APP=https://localhost:3000\nREALTIME_ALLOWED_ORIGINS=https://localhost:3000,https://node.ts.net\n' >"$G/.env"
printf 'REALTIME_ALLOWED_ORIGINS=https://localhost:3000,https://node.ts.net,https://node.ts.net:8443\n' >"$G/.env.local"
# docker: `restart` succeeds, `inspect` finds no realtime container.
# shellcheck disable=SC2016 # $1 is the stub's argument, expanded when it runs
printf '#!/bin/sh\n[ "$1" = inspect ] && exit 1\nexit 0\n' >"$TMP/bin/docker"
chmod +x "$TMP/bin/docker"

PATH="$TMP/bin:$PATH" GROBASE_DIR="$G" "${SCRIPT_SH:-bash}" "$REPO_ROOT/setup/host/grobase_cors_guest.sh" \
    https://app.example https://localhost:3000 >"$TMP/out" 2>&1 || {
    echo "FAIL the script exited non-zero:"
    cat "$TMP/out"
    exit 1
}

want=https://localhost:3000,https://node.ts.net,https://node.ts.net:8443,https://app.example
check '.env keeps every earlier origin, adds new' "$(sed -n 's/^REALTIME_ALLOWED_ORIGINS=//p' "$G/.env")" "$want"
check '.env.local follows' "$(sed -n 's/^REALTIME_ALLOWED_ORIGINS=//p' "$G/.env.local")" "$want"
check 'kong.yml gained the new origin once' "$(grep -c -- '- https://app.example' "$G/infra/docker/services/kong/conf/kong.yml")" 1

PATH="$TMP/bin:$PATH" GROBASE_DIR="$G" "${SCRIPT_SH:-bash}" "$REPO_ROOT/setup/host/grobase_cors_guest.sh" \
    https://app.example >/dev/null 2>&1
check 'a second call changes nothing' "$(sed -n 's/^REALTIME_ALLOWED_ORIGINS=//p' "$G/.env")" "$want"

exit "$fail"
