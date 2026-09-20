#!/usr/bin/env hellish
# verify_platform.sh — the session self-test for the server image.
#
# The guest is off whenever nobody is at this seat, so alerting at 3 a.m. is
# meaningless; what matters is a proof, at the start of every session, that
# the platform is the platform. One run, one screen, non-zero on any hard
# failure. It asks the guest, never the host: the whole point of the qemu_ssh
# fix was that "guest facts" had been host output.
#
# HARD (exit 1)                              SOFT (warn)
#   the SSH target is the guest              tailscale logged in
#   dc-gateway provisioned ok                backup password present, last
#   Kong container running                     snapshot younger than 2 h
#   gateway answers on 127.0.0.1:8000        cloudflared present (dc-tunnel)
#   NO engine port published off loopback
#   var-gc timer active, refuses --volumes
#   backup timer active
#
#   make verify_platform
set -u

# shellcheck source=setup/host/dc_lib.sh
. "$(dirname "${BASH_SOURCE[0]:-$0}")/dc_lib.sh"

fail=0
hard() { # <label> <cmd in guest> [<expected substring>]
    local out
    out=$(vm_ssh "$2" 2>/dev/null) || out=""
    if [ -n "$out" ] && { [ -z "${3:-}" ] || printf '%s' "$out" | grep -q -- "$3"; }; then
        ok "$1"
    else
        printf "${C_RED}✗${C_R} %s\n" "$1"
        [ -n "$out" ] && printf "    ${C_DIM}%s${C_R}\n" "$(printf '%s' "$out" | head -n3)"
        fail=1
    fi
}
soft() {
    local out
    out=$(vm_ssh "$2" 2>/dev/null) || out=""
    if [ -n "$out" ] && { [ -z "${3:-}" ] || printf '%s' "$out" | grep -q -- "$3"; }; then
        ok "$1"
    else
        warn "$1 -- ${4:-not yet}"
    fi
}

dc_connect
printf "\n  ${C_B}%s${C_R}  ssh 127.0.0.1:%s as %s\n\n" "$VM_NAME" "$SSH_PORT" "$VM_USER"

# ── identity ────────────────────────────────────────────────────────────────
hard "the SSH target is the guest (Debian, /etc/b2b/build.conf present)" \
    "grep -q '^ID=debian' /etc/os-release && test -f /etc/b2b/build.conf && echo guest" guest
on() { vm_ssh "grep -qx 'B2B_FEATURE_$(printf '%s' "$1" | tr '-' '_')=on' /etc/b2b/features.conf" 2>/dev/null; }

# ── grobase ─────────────────────────────────────────────────────────────────
if on dc-gateway; then
    hard "dc-gateway provisioned ok at first boot (features.status)" \
        "grep '^dc-gateway ' /etc/b2b/features.status" "dc-gateway ok"
    hard "Kong is running" "docker ps --format '{{.Names}}' | grep -x mini-baas-kong" mini-baas-kong
    hard "the gateway answers on 127.0.0.1:8000 (HTTP status, any)" \
        "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8000/ | grep -E '^[1-5][0-9][0-9]\$'"
    # The security property of the whole design: nothing but loopback, with
    # ONE named exception. grobase's WAF is the door -- TLS, rules, then
    # Kong -- and publishes 8880/8443 on every interface by design; that is
    # what a tailnet peer is meant to reach. Kong itself, every engine and
    # the observability stack stay on 127.0.0.1. A published 0.0.0.0:PORT
    # on any other container is a hole in the wall.
    hard "no container but the WAF publishes a port off loopback" \
        "docker ps --format '{{.Names}} {{.Ports}}' | grep -v '^mini-baas-waf ' | grep -E '0\\.0\\.0\\.0:|\\[::\\]:' | wc -l | grep -x 0" 0
    hard "the WAF is up (the door: https on $(vm_ssh 'docker port mini-baas-waf 443/tcp 2>/dev/null | head -n1 | sed "s/.*://"' 2>/dev/null || echo '?'))" \
        "docker ps --format '{{.Names}} {{.Status}}' | grep '^mini-baas-waf .*Up'" Up
    soft "grobase tier recorded" "sed -n 's/^GROBASE_PACKAGE=//p' /etc/b2b/grobase.conf" "" "no /etc/b2b/grobase.conf"
else
    warn "dc-gateway is off in this build: grobase checks skipped"
fi

# ── the two timers ──────────────────────────────────────────────────────────
if on dc-var-gc; then
    hard "var-gc timer active" "systemctl is-active b2b-var-gc.timer" active
    hard "var-gc refuses --volumes (exit 2)" "/usr/local/sbin/b2b-var-gc --volumes >/dev/null 2>&1; echo rc=\$?" rc=2
fi
if on dc-backup; then
    hard "backup timer active" "systemctl is-active b2b-backup.timer" active
    soft "backup password installed" "test -s /etc/b2b/restic.pass && echo yes" yes "make backup"
    soft "last snapshot younger than 2 h" \
        "f=\$(ls -t /var/backups/b2b/repo/snapshots 2>/dev/null | head -n1); [ -n \"\$f\" ] && [ \$(( \$(date +%s) - \$(stat -c %Y /var/backups/b2b/repo/snapshots/\$f) )) -lt 7200 ] && echo fresh" fresh "no fresh snapshot (make backup)"
fi

# ── the edge ────────────────────────────────────────────────────────────────
if on dc-netmesh; then
    soft "tailscale logged in" \
        "tailscale status --json 2>/dev/null | grep -o '\"BackendState\": *\"Running\"'" Running "make tailscale"
fi
if on dc-tunnel; then
    soft "cloudflared installed (tunnel is configured later, explicitly)" "command -v cloudflared" cloudflared
fi

# ── the wall ────────────────────────────────────────────────────────────────
# The WAF's host ports are read back from Docker, never assumed: grobase's
# resolve-ports.sh bumps a port that is busy when `make up` runs, and a
# rerun found its own previous container holding 8443, so the new one took
# 8444. A check that hardcoded 8443 would flag the door as an intruder.
waf_ports=$(vm_ssh "docker port mini-baas-waf 2>/dev/null | sed 's/.*://' | sort -u | tr '\n' '|' | sed 's/|\$//'" 2>/dev/null)
hard "only sshd and the WAF (${waf_ports:-none}) listen off loopback (ss -ltn)" \
    "ss -ltn 2>/dev/null | awk 'NR > 1 { print \$4 }' | grep -vE '^(127\\.|\\[::1\\]|100\\.|\\[fd7a:)' | grep -vE ':(4242${waf_ports:+|$waf_ports})\$' | wc -l | grep -x 0" 0

printf '\n'
if [ "$fail" = 0 ]; then
    ok "platform verified"
else
    die "platform NOT verified -- see the ✗ lines above"
fi
