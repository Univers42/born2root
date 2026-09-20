#!/usr/bin/env hellish
# tenant_key.sh — provision a grobase tenant and keep its API key.
#
# WHAT A TENANT KEY IS
#   grobase is multi-tenant: every client application is a tenant with its
#   own `mbk_...` API key, and everything that writes on its behalf -- the
#   seeder included -- refuses without one. There is no key until a tenant is
#   provisioned, and provisioning is an operator call to tenant-control:
#   POST /v1/provision, from inside the guest (Kong's /admin/v1/provision is
#   ip-restricted to private ranges and tenant-control's own port is
#   loopback-bound).
#
# WHY THE REQUEST IS SIGNED
#   The stack runs with SERVICE_TOKEN_MODE=hmac: the shared service token
#   never transits the wire, and a plain X-Service-Token is REJECTED. Each
#   call carries `X-Service-Auth: v1.<ts>.<hmac-sha256>` over the method,
#   path, body hash and timestamp. grobase ships the signer for shell,
#   scripts/lib/service-auth.sh (`svc_auth`), and the token is read from
#   the running tenant-control container the way its own seeder does
#   (docker inspect, not printenv: the image is distroless). Reproducing
#   that by hand cost an hour on 2026-09-20; this script is that hour.
#
# WHERE THE KEY GOES
#   .b2b-secrets on the host as BAAS_API_KEY (600, gitignored), which
#   `make seed` reads; and ~/.b2b-tenant-key in the guest (600). It is
#   printed nowhere. Provisioning is idempotent on the tenant; a second run
#   for the same tenant reuses it and mints a new key (key_reuse tells).
#
#   make tenant_key                        tenant "transcendence"
#   make tenant_key TENANT=groot NAME="groot workspace"
set -u

# shellcheck source=setup/host/dc_lib.sh
. "$(dirname "${BASH_SOURCE[0]:-$0}")/dc_lib.sh"

TENANT="${TENANT:-transcendence}"
NAME="${NAME:-ft_$TENANT}"
KEY_NAME="${KEY_NAME:-seed}"
case "$TENANT" in *[!a-z0-9-]*) die "TENANT must be a slug: lowercase letters, digits, dashes (got $TENANT)" ;; esac

dc_connect

info "provisioning tenant '$TENANT' ($NAME) in the guest, signed with the service token"
out=$(
    vm_ssh 'bash -s' <<GUESTEOF
set -u
cd /opt/grobase || { echo "no /opt/grobase"; exit 1; }
SERVICE_TOKEN=\$(docker inspect mini-baas-tenant-control --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | sed -n 's/^INTERNAL_SERVICE_TOKEN=//p' | head -n1)
[ -n "\$SERVICE_TOKEN" ] || { echo "no INTERNAL_SERVICE_TOKEN on mini-baas-tenant-control (is grobase up?)"; exit 1; }
export SERVICE_TOKEN
. scripts/lib/service-auth.sh
body='{"tenant":"$TENANT","name":"$NAME","default_key_name":"$KEY_NAME","default_role_name":"app","seed_roles":true}'
svc_auth POST /v1/provision "\$body"
r=\$(curl -s -w '\n%{http_code}' -X POST http://127.0.0.1:3022/v1/provision "\${SVC_AUTH[@]}" -H 'Content-Type: application/json' -d "\$body")
code=\$(printf '%s' "\$r" | tail -n1); res=\$(printf '%s' "\$r" | sed '\$d')
k=\$(printf '%s' "\$res" | grep -oE 'mbk_[A-Za-z0-9_-]+' | head -n1)
if [ -n "\$k" ]; then umask 077; printf '%s\n' "\$k" >"\$HOME/.b2b-tenant-key"; fi
echo "HTTP \$code"
printf '%s' "\$res" | sed -E 's/mbk_[A-Za-z0-9_-]+/mbk_<redacted>/g' | grep -oE '"(id|status|plan|key_prefix|scopes|outcome|key_reuse|error|message)":[^,}]*' | tr '\n' ' '
echo
GUESTEOF
) || die "the provisioning call failed: $out"
printf '%s\n' "$out" | tail -n 2
case "$out" in *"HTTP 201"* | *"HTTP 200"*) ;; *) die "tenant-control did not accept the request (read the line above)" ;; esac

key=$(vm_ssh 'cat ~/.b2b-tenant-key 2>/dev/null' | tr -d '\r\n' | grep -oE '^mbk_[A-Za-z0-9_-]+' || true)
[ -n "$key" ] || die "no key came back for '$TENANT'"
slug_var="BAAS_API_KEY_$(printf "%s" "$TENANT" | tr "a-z-" "A-Z_")"
secret_set "$slug_var" "$key"
# BAAS_API_KEY is the one `make seed` reads: the last tenant provisioned.
secret_set BAAS_API_KEY "$key"
ok "tenant '$TENANT' provisioned; key saved to $SECRETS_FILE as $slug_var and BAAS_API_KEY (make seed uses the latter)"
