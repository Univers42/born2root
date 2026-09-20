#!/usr/bin/env hellish
# funnel.sh — the public plane: the WAF on the open Internet through Tailscale
# Funnel, at https://<node>.<tailnet>.ts.net/, with a real certificate.
#
# HOW IT REACHES THE INTERNET WITHOUT AN INBOUND PORT
#   The guest opens an outbound connection to Tailscale's relays; the public
#   hostname resolves to those relays, which hand each TLS connection to the
#   guest. Nothing at the campus edge changes. Funnel terminates TLS with a
#   Let's Encrypt certificate for the ts.net name and forwards to a local
#   target -- here the WAF (https+insecure://127.0.0.1:<port>, its own cert
#   being self-signed for "localhost"), so the WAF's rules still front Kong.
#   Only ports 443, 8443 and 10000 may be funneled; 443 is used.
#
# TWO CONSOLE SWITCHES, ONCE, BY THE TAILNET OWNER
#   1. DNS -> HTTPS Certificates -> Enable      (the certificate)
#   2. the Funnel node attribute in the ACL      (`tailscale funnel` prints
#      the exact enable-URL the first time; one click)
#   Until both are on, `make funnel_up` prints what to click and exits 1.
#
# DOWN BY DEFAULT
#   Exposure is an explicit act tied to a session: nothing here persists a
#   funnel across a rebuild, and `make funnel_down` closes it. Check the
#   campus acceptable-use policy before the first `funnel_up`; phases 0-5 of
#   the plan are private, this is the one that is not.
#
#   make funnel_up | funnel_status | funnel_down
set -u

# shellcheck source=setup/host/dc_lib.sh
. "$(dirname "${BASH_SOURCE[0]:-$0}")/dc_lib.sh"

dc_connect
state=$(vm_ssh "tailscale status --json 2>/dev/null | sed -n 's/.*\"BackendState\": *\"\\([A-Za-z]*\\)\".*/\\1/p' | head -n1" 2>/dev/null || true)
[ "$state" = Running ] || die "the guest is not on the tailnet (state: ${state:-unknown}) -- make tailscale first"
name=$(vm_ssh "tailscale status --json 2>/dev/null | sed -n 's/.*\"DNSName\": *\"\\([^\"]*\\)\".*/\\1/p' | head -n1 | sed 's/\\.\$//'" 2>/dev/null || true)

case "${1:-}" in
--down)
    vm_ssh "tailscale funnel --https=443 off" >/dev/null 2>&1 || true
    ok "funnel closed; https://${name}/ no longer answers"
    ;;
--status)
    out=$(vm_ssh "tailscale funnel status 2>&1" || true)
    case "$out" in
    *"Funnel on"* | *https://*)
        ok "funnel is up:"
        printf '%s\n' "$out" | sed 's/^/    /'
        ;;
    *)
        warn "no funnel (make funnel_up)"
        printf '%s\n' "$out" | head -n3 | sed 's/^/    /'
        ;;
    esac
    ;;
*)
    waf=$(vm_ssh "docker port mini-baas-waf 443/tcp 2>/dev/null | head -n1 | sed 's/.*://'" 2>/dev/null)
    case "$waf" in '' | *[!0-9]*) die "the WAF is not publishing 443 (docker port mini-baas-waf) -- is grobase up?" ;; esac
    info "funneling https://${name}/ -> WAF on 127.0.0.1:${waf} (which fronts Kong)"
    out=$(vm_ssh "tailscale funnel --bg --https=443 https+insecure://127.0.0.1:${waf} 2>&1" || true)
    case "$out" in
    *"not enabled"* | *"login.tailscale.com"*)
        printf '%s\n' "$out" | sed 's/^/    /'
        die "Funnel is not enabled on the tailnet yet: open the URL above once (and DNS -> HTTPS Certificates -> Enable), then rerun make funnel_up"
        ;;
    esac
    printf '%s\n' "$out" | sed 's/^/    /'
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "https://${name}/" 2>/dev/null || echo 000)
    case "$code" in
    000) warn "https://${name}/ not answering from this host yet (certificate issuance can take a minute; make funnel_status)" ;;
    *) ok "PUBLIC: https://${name}/ answers HTTP $code from the open Internet (that 404 is Kong: no route for /)" ;;
    esac
    ;;
esac
