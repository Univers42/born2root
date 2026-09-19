#!/usr/bin/env hellish
# loadtest.sh — numbers for the gateway, from inside the guest, with k6.
#
# WHY INSIDE THE GUEST
#   The question is "what can this backend do", so the measurement goes to
#   127.0.0.1:8000 where Kong listens, with nothing in between: no SSH
#   tunnel, no QEMU NAT, no relay. k6 runs as a container on the guest's
#   Docker with --network host, so the guest needs no k6 package and the
#   image is pulled once. Percentiles are what k6 prints; the run's summary
#   is also kept as JSON under /var/tmp on the guest for a later diff.
#
# WHY IT REFUSES A PUBLIC ORIGIN
#   A Funnel or Cloudflare hostname is a shared relay meant for demos, and
#   hammering it measures the relay, not the backend -- and is rude to it.
#   LOADTEST_URL may only point at loopback or a tailnet address.
#
# SEEDING
#   Rows come from grobase's own seeders (`make seed-live-demo` in the clone
#   on the guest), server-side, never through the API: ingesting and
#   serving are two different questions.
#
#   make loadtest                         30 s, 20 VUs, against /
#   make loadtest VUS=50 DURATION=2m PATH=/rest/v1/
#   make seed                             grobase's live-demo seed
set -u

# shellcheck source=setup/host/dc_lib.sh
. "$(dirname "${BASH_SOURCE[0]:-$0}")/dc_lib.sh"

URL="${LOADTEST_URL:-http://127.0.0.1:8000}"
VUS="${VUS:-20}"
DURATION="${DURATION:-30s}"
# /auth/v1/health, not /: Kong answers 404 for / and 401 for any route
# without an apikey, and k6 files every 4xx as a failed request -- the first
# smoke run reported http_req_failed 100% against a gateway that was fine.
# With the anon key the health route is a 200 through Kong into GoTrue,
# which is the path a real client takes. The key is read in the guest from
# grobase's .env and handed to k6 there; it never leaves the guest.
REQ_PATH="${PATH_UNDER_TEST:-/auth/v1/health}"

case "$URL" in
http://127.0.0.1* | http://localhost* | https://127.0.0.1* | https://localhost* | http://100.* | https://100.*) ;;
*.ts.net* | *cloudflare* | *.42.fr*)
    die "refusing to load-test a public or relayed origin ($URL): measure the backend on loopback or the tailnet"
    ;;
*) die "LOADTEST_URL must be loopback or a tailnet address (got $URL)" ;;
esac

dc_connect

if [ "${1:-}" = "--seed" ]; then
    # grobase's seeder writes the demo rows under a TENANT key (mbk_...),
    # the one a registered client app owns, and refuses without it: the
    # seed is scoped to an app, not to the platform. Issue one for the app
    # (or read VITE_BAAS_API_KEY from its env) and pass BAAS_API_KEY=.
    info "seeding through grobase's own seeder in the guest (server-side)"
    if ! vm_ssh "cd /opt/grobase && BAAS_API_KEY='${BAAS_API_KEY:-}' make --no-print-directory seed-live-demo 2>&1 | tail -n 6"; then
        die "seed failed -- grobase's seeder needs a tenant API key: make seed BAAS_API_KEY=mbk_..."
    fi
    ok "seeded"
    exit 0
fi

info "k6: $VUS VUs for $DURATION against ${URL}${REQ_PATH} (in the guest)"
# The k6 scenario, one statement per line (bashate reads the indentation of
# a quoted string as shell indentation, so none inside it).
script='import http from "k6/http"; import { check } from "k6";
export const options = { vus: __ENV.VUS | 0, duration: __ENV.DURATION, thresholds: { http_req_failed: ["rate<0.05"], http_req_duration: ["p(95)<1500"] } };
const headers = __ENV.APIKEY ? { apikey: __ENV.APIKEY } : {};
export default function () { const r = http.get(__ENV.URL + __ENV.REQ_PATH, { headers }); check(r, { "2xx": (x) => x.status >= 200 && x.status < 300 }); }'
out="/var/tmp/b2b-loadtest-$(date +%Y%m%dT%H%M%S).json"
# The apikey is resolved on the guest side of the ssh, in that shell, and
# passed to the k6 container's environment: it is never on this host.
printf '%s\n' "$script" | vm_ssh "k=\$(sed -n 's/^ANON_KEY=//p' /opt/grobase/.env 2>/dev/null | head -n1); \
    docker run --rm -i --network host \
    -e VUS='$VUS' -e DURATION='$DURATION' -e URL='$URL' -e REQ_PATH='$REQ_PATH' -e APIKEY=\"\$k\" \
    grafana/k6 run --summary-export='$out' --quiet - 2>&1 | tail -n 40; \
    echo; echo 'summary json in the guest: $out'" || warn "k6 reported threshold failures or an error (read above)"
