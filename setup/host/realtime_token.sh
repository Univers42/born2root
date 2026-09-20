#!/usr/bin/env hellish
# realtime_token.sh -- mint a publish-capable realtime token in the guest and
# keep it in the secrets file (REALTIME_WS_TOKEN). See
# realtime_token_guest.sh for why such a token exists at all.
#
#   make realtime_token                         namespaces "pg lab", 30 days
#   make realtime_token NS="pg lab game" DAYS=7
#
# Prints the namespaces and the expiry, never the token. Apps read it from the
# secrets file (the Laboratory: GROBASE_REALTIME_TOKEN in its .env).
set -u
# shellcheck source=setup/host/dc_lib.sh
. "$(dirname "$0")/dc_lib.sh"
ns="${NS:-pg lab}"
days="${DAYS:-30}"
case "$days" in '' | *[!0-9]*) die "DAYS=$days is not a number of days" ;; esac
for n in $(printf '%s' "$ns"); do
    case "$n" in *'*'*) die "namespace '$n': a wildcard grants every tenant's channels; name the namespaces" ;; esac
done
dc_connect
# shellcheck disable=SC2086 # the namespaces are separate arguments on purpose
token=$(REALTIME_TOKEN_DAYS="$days" vm_ssh "REALTIME_TOKEN_DAYS=$days bash -s -- $ns" <"$(dirname "$0")/realtime_token_guest.sh") || die "the guest could not mint a token"
case "$token" in *.*.*) ;; *) die "the guest returned no token" ;; esac
secret_set REALTIME_WS_TOKEN "$token"
ok "REALTIME_WS_TOKEN minted for namespaces [$ns], $days day(s), saved to $SECRETS_FILE"
