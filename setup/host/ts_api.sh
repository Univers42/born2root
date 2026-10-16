#!/usr/bin/env hellish
# ts_api.sh — the Tailscale API from the host, and the auth key a node joins
# with. Sourced after dc_lib.sh (secret_get, secret_set, warn); never run.
#
# THE CREDENTIAL, from the secrets file and never from argv: TS_API_TOKEN (an
# access token, tskey-api-, 90 days at most) or TS_OAUTH_CLIENT_ID +
# TS_OAUTH_CLIENT_SECRET (an OAuth client, which does not expire). Either
# travels to curl as a config on stdin.
#
# WHY THE KEY IS CHECKED BEFORE IT IS USED
#   On 2026-10-16 TS_AUTHKEY had been revoked: the seat's login entry and
#   `make seat_tailnet` both died on "invalid key", and so would the next
#   `make tailnet` of a rebuilt guest, each one asking for a new key by hand.
#   ts_live_authkey asks the API whether the stored key still exists and, when
#   it is gone, mints a reusable + ephemeral + pre-approved one and stores it.
#
# AN OAUTH CLIENT MINTS TAGGED KEYS ONLY, and only tags its own tag owns. The
# tag is TS_TAGS (comma list), else tag:b2b; since 2026-10-16 the tailnet
# policy has "tag:b2b": ["autogroup:owner", "tag:osionos"] (tag:osionos is the
# OAuth client's own tag; without it the API answered 400 "requested tags
# [tag:b2b] are invalid or not permitted") and Funnel for tag:b2b. A node
# joined with it is owned by the tag, not a person.
#
# "Gone" is a 404 for the key's id, or a 200 that says "invalid": true -- what
# the API answers for a revoked or expired key (measured 2026-10-16 on the key
# revoked at 2026-10-15T11:22:19Z, which a 404-only check took for alive).
# Caveat: with no credential, or an API that does not answer, the stored key
# is used unchecked, as before, and `tailscale up` is the one to refuse it.
set -u

TS_API="${TS_API_URL:-https://api.tailscale.com/api/v2}"
API_TOKEN="${API_TOKEN:-}"
API_CODE=000

# ts_json KEY: a top-level string out of the JSON on stdin, empty if absent.
ts_json() {
    python3 -c 'import json, sys
try:
    print(json.load(sys.stdin).get(sys.argv[1]) or "")
except Exception:
    print("")' "$1" 2>/dev/null
}

# ts_api_token: 0 when a credential resolved to a bearer token in API_TOKEN.
# An auth key or an OAuth secret pasted into TS_API_TOKEN answers 401 on every
# call (2026-10-14), so anything but tskey-api- there is set aside, unprinted.
ts_api_token() {
    [ -n "$API_TOKEN" ] && return 0
    local tok cid csec
    tok="${TS_API_TOKEN:-$(secret_get TS_API_TOKEN)}"
    case "$tok" in
    tskey-api-*) ;;
    '') ;;
    *)
        warn "TS_API_TOKEN in $SECRETS_FILE is not an API access token (tskey-api-): ignored" >&2
        tok=
        ;;
    esac
    if [ -z "$tok" ]; then
        cid="${TS_OAUTH_CLIENT_ID:-$(secret_get TS_OAUTH_CLIENT_ID)}"
        csec="${TS_OAUTH_CLIENT_SECRET:-$(secret_get TS_OAUTH_CLIENT_SECRET)}"
        [ -n "$cid" ] && [ -n "$csec" ] || return 1
        tok=$(printf 'data-urlencode = "client_id=%s"\ndata-urlencode = "client_secret=%s"\n' "$cid" "$csec" |
            curl -s --max-time 20 -K - "$TS_API/oauth/token" 2>/dev/null | ts_json access_token)
        [ -n "$tok" ] || {
            warn "the OAuth client was refused by $TS_API/oauth/token (revoked? wrong scopes?)" >&2
            return 1
        }
    fi
    API_TOKEN="$tok"
}

# ts_api METHOD PATH [BODY]: the response body on stdout, the code in API_CODE.
ts_api() {
    local method="$1" path="$2" body="${3:-}" out
    out=$(mktemp "${TMPDIR:-/tmp}/ts_api.XXXXXX")
    local args=(-s --max-time 30 -K - -X "$method" -H 'Content-Type: application/json'
        -o "$out" -w '%{http_code}' "$TS_API/$path")
    [ -n "$body" ] && args+=(--data "$body")
    API_CODE=$(printf 'user = "%s:"\n' "$API_TOKEN" | curl "${args[@]}" 2>/dev/null) || API_CODE=000
    cat "$out"
    rm -f "$out"
    case "$API_CODE" in 2??) return 0 ;; esac
    [ "$API_CODE" = 401 ] && warn "the Tailscale API rejected the credential (401)" >&2
    return 1
}

# ts_mint_authkey DESCRIPTION: a new reusable + ephemeral + pre-approved key,
# 90 days, tagged; printed, nothing else. Empty when the API refuses.
ts_mint_authkey() {
    local tags body
    tags=$(printf '%s' "${TS_TAGS:-tag:b2b}" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep . |
        sed 's/.*/"&"/' | paste -sd, -)
    body=$(printf '{"capabilities":{"devices":{"create":{"reusable":true,"ephemeral":true,"preauthorized":true,"tags":[%s]}}},"expirySeconds":7776000,"description":"%s"}' \
        "$tags" "$(printf '%s' "$1" | tr -cd 'A-Za-z0-9 ._-' | cut -c1-50)")
    # Through a file, not a pipe: the pipe's subshell kept API_CODE, and the
    # refusal was reported as "HTTP 200" -- the code of the previous call.
    local out
    out=$(mktemp "${TMPDIR:-/tmp}/ts_mint.XXXXXX")
    ts_api POST tailnet/-/keys "$body" >"$out"
    ts_json key <"$out"
    rm -f "$out"
}

# ts_key_alive KEY: 0 when the key can still join, 1 when it is gone (404,
# or revoked/expired: "invalid": true), 2 when it cannot tell (no id, no API).
ts_key_alive() {
    local id body rc=2
    id=$(printf '%s' "$1" | sed -n 's/^tskey-auth-\([A-Za-z0-9]*\)-.*/\1/p')
    [ -n "$id" ] && ts_api_token || return 2
    # Not body=$(ts_api ...): the subshell would keep API_CODE to itself.
    body=$(mktemp "${TMPDIR:-/tmp}/ts_key.XXXXXX")
    if ts_api GET "tailnet/-/keys/$id" >"$body"; then
        rc=0
        grep -q '"invalid": *true' "$body" && rc=1
    elif [ "$API_CODE" = 404 ]; then
        rc=1
    fi
    rm -f "$body"
    return "$rc"
}

# ts_live_authkey DESCRIPTION: the auth key to join with, on stdout. The
# stored TS_AUTHKEY while the API does not say it is gone; otherwise a minted
# one, saved as TS_AUTHKEY first. Empty when there is neither.
ts_live_authkey() {
    local key fresh rc=0
    key=$(secret_get TS_AUTHKEY)
    if [ -n "$key" ]; then
        ts_key_alive "$key" || rc=$?
        [ "$rc" = 1 ] || {
            printf '%s\n' "$key"
            return 0
        }
        warn "TS_AUTHKEY in $SECRETS_FILE no longer exists on the tailnet (revoked?): minting a new one" >&2
    fi
    ts_api_token || return 0
    fresh=$(ts_mint_authkey "$1")
    if [ -z "$fresh" ]; then
        warn "the API would not mint a ${TS_TAGS:-tag:b2b} auth key: the policy's tagOwners must give that tag to the OAuth client's own tag (ts_api.sh header)" >&2
        return 0
    fi
    secret_set TS_AUTHKEY "$fresh"
    warn "minted a new TS_AUTHKEY into $SECRETS_FILE -- share it with: make secrets_push KEYS=TS_AUTHKEY" >&2
    printf '%s\n' "$fresh"
}
