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
#   make seed N=50000                     rows into public.b2b_seed, server-side
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
    # Rows go straight into Postgres with generate_series, server-side, into
    # public.b2b_seed, readable by PostgREST's anon role: that is the table
    # `make loadtest PATH_UNDER_TEST=/rest/v1/b2b_seed?limit=100` then pages
    # through, which is the "thousands of rows on a screen" question asked
    # of the platform. grobase's own seed-live-demo is not used: it seeds the
    # osionos demo and needs that app's checkout (apps/osionos/app/.env) --
    # an app's fixture, not a platform tool. No pipe on the remote side: a
    # `cmd | tail` returns tail's status and reported "seeded" on a failure.
    N="${N:-50000}"
    case "$N" in '' | *[!0-9]*) die "N must be a number of rows (got '$N')" ;; esac
    info "seeding $N rows into public.b2b_seed in the guest's Postgres (server-side)"
    count=$(vm_ssh "docker exec -i mini-baas-postgres psql -U postgres -d postgres -qtA -v ON_ERROR_STOP=1 <<'SQL'
create table if not exists public.b2b_seed (id bigint primary key, ts timestamptz not null default now(), payload jsonb not null);
truncate public.b2b_seed;
insert into public.b2b_seed (id, payload) select g, jsonb_build_object('n', g, 'label', 'row ' || g, 'v', random()) from generate_series(1, $N) g;
grant usage on schema public to anon; grant select on public.b2b_seed to anon;
select count(*) from public.b2b_seed;
SQL") || die "the seed SQL failed (is mini-baas-postgres up?)"
    count=$(printf '%s' "$count" | tr -d '[:space:]')
    [ "$count" = "$N" ] || die "expected $N rows, Postgres reports '$count'"
    ok "$count rows in public.b2b_seed -- try: make loadtest PATH_UNDER_TEST='/rest/v1/b2b_seed?select=id,payload&limit=100'"
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
