#!/usr/bin/env hellish
# realtime_token_guest.sh -- runs INSIDE the guest (make realtime_token pipes
# it over SSH as `bash -s -- <namespace>... `): mint an HS256 realtime token
# with the publish claim and print it, nothing else, on stdout.
#
# WHY A MINTED TOKEN
#   grobase's realtime plane lets a client TRACK presence and BROADCAST only
#   when its JWT carries `can_publish: true` and a namespace grant; GoTrue's
#   user tokens carry neither, so presence and broadcast are unreachable with
#   a plain session -- the SDK included. grobase's own seed
#   (scripts/seed/red-tetris-tenant.sh) mints a shared WS token with the
#   platform's JWT secret for exactly this; per-user identity rides in the
#   presence meta and database writes keep each user's own token. Same here,
#   with the namespaces narrowed to what the caller names (never "*").
#
# The secret never leaves the guest: only the signed token does, over SSH.
set -eu
[ "$#" -gt 0 ] || {
    echo "usage: bash -s -- <namespace>..." >&2
    exit 2
}
secret=$(sed -n 's/^JWT_SECRET=//p' /opt/grobase/.env.secrets /opt/grobase/.env 2>/dev/null | head -n1 | tr -d '"')
[ -n "$secret" ] || {
    echo "no JWT_SECRET in /opt/grobase/.env(.secrets)" >&2
    exit 1
}
ttl_days=${REALTIME_TOKEN_DAYS:-30}
JWT_SECRET="$secret" JWT_NS="$*" JWT_TTL_DAYS="$ttl_days" python3 - <<'PY'
import base64, hmac, hashlib, json, os, time
b64u = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
head = b64u(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
now = int(time.time())
body = b64u(json.dumps({
    "iss": "supabase", "sub": "laboratory-bench", "role": "authenticated",
    "namespaces": os.environ["JWT_NS"].split(), "can_publish": True, "can_subscribe": True,
    "iat": now, "exp": now + int(os.environ["JWT_TTL_DAYS"]) * 86400,
}, separators=(",", ":")).encode())
sig = b64u(hmac.new(os.environ["JWT_SECRET"].encode(), f"{head}.{body}".encode(), hashlib.sha256).digest())
print(f"{head}.{body}.{sig}")
PY
