#!/usr/bin/env hellish
# Regression test: a build ends only when first boot ended, and the verdict it
# reads off the guest is the right one -- for both backends, which share
# utils/first_boot.sh.
#
# The bugs it pins down:
#   * The VirtualBox orchestrator never waited for first boot: a guest whose
#     provisioning failed still ended its run with "All Steps Completed".
#   * When grobase failed at first boot (2026-10-06), dc-gateway was filed as an
#     optional warning but its eleven folded dc-* siblings as bare failures, so
#     the host called them essential and failed the build.
#   * A warning whose feature a later `make <name>` repaired stayed in
#     FEATURE_WARNINGS and was reported on every later run.
#
# fb_ssh is stubbed to run each command against a fake guest under $TMP, and
# dc_fold is cut out of first-boot-setup.sh with its /etc/b2b moved there.
set -u
cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." || exit 1

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-56s = %s\n' "$1" "$2"
    else
        printf 'FAIL %-56s = %s (expected %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
G="$TMP/guest"

# shellcheck source=utils/first_boot.sh
. utils/first_boot.sh
# shellcheck disable=SC2317 # called by the library
fb_ssh() {
    local cmd="$*"
    cmd=${cmd//\/etc\//$G\/etc\/}
    cmd=${cmd//\/var\/log\//$G\/var\/log\/}
    bash -c "$cmd" 2>/dev/null
}
# shellcheck disable=SC2317
fb_wait_tick() { :; }
# shellcheck disable=SC2317
fb_progress() { :; }
# shellcheck disable=SC2317 # called by the eval'd dc_fold
feature_retry() { echo "make grobase"; }
eval "$(awk '/^dc_fold\(\) \{/,/^}/' preseeds/first-boot-setup.sh | sed "s|/etc/b2b|$G/etc/b2b|g")"

guest() { # <features.status> [FEATURE_WARNINGS] [PROVISION_FAILED]
    rm -rf "$G"
    mkdir -p "$G/etc/b2b" "$G/var/log"
    printf '%s\n' "$1" >"$G/etc/b2b/features.status"
    [ -z "${2:-}" ] || printf '%s\n' "$2" >"$G/etc/b2b/FEATURE_WARNINGS"
    [ -z "${3:-}" ] || printf '%s\n' "$3" >"$G/etc/b2b/PROVISION_FAILED"
    : >"$G/etc/crontab"
}
verdict() {
    first_boot_verdict 2>"$TMP/err"
    echo $?
}

guest "nvim ok / 300
webstack off - 0"
check "clean guest: passes" "$(verdict)" 0
first_boot_verdict 2>/dev/null
check "  and says what it counted" "$FB_SUMMARY" "every feature installed: 1 ok, 1 off by profile"

guest "hellish failed / 0" "" "hellish: the login shell did not install"
check "PROVISION_FAILED: fails" "$(verdict)" 1

guest "docker failed /var 0"
check "an essential feature failed, no warning: fails" "$(verdict)" 1
check "  names it" "$(grep -c '^      docker failed' "$TMP/err")" 1

guest "nvim-extras failed /home 0" "nvim-extras failed (retry: make nvim)"
check "an optional feature failed and warned: passes" "$(verdict)" 0
check "  and is reported" "$(grep -c 'nvim-extras failed (retry' "$TMP/err")" 1

guest "nvim-extras ok /home 120" "nvim-extras failed (retry: make nvim)"
check "a warning a later make repaired: passes" "$(verdict)" 0
check "  and is not reported again" "$(wc -c <"$TMP/err" | tr -d ' ')" 0

guest "dc-gateway failed /var 0" "dc-gateway failed (retry: make grobase)"
for f in dc-identity dc-realtime dc-db-postgres; do
    dc_fold "$f" dc-gateway /var
done
check "grobase failed: its folded rows are warnings too" "$(verdict)" 0
check "  each folded row is filed failed" "$(grep -c '^dc-.* failed /var 0' "$G/etc/b2b/features.status")" 4
check "  and warned with the row it follows" "$(grep -c 'failed with dc-gateway' "$G/etc/b2b/FEATURE_WARNINGS")" 3

guest "dc-gateway ok /var 9000"
dc_fold dc-identity dc-gateway /var
check "grobase up: a folded row is ok, no warning" \
    "$(tail -n1 "$G/etc/b2b/features.status")/$([ -f "$G/etc/b2b/FEATURE_WARNINGS" ] && echo warned || echo none)" \
    "dc-identity ok /var 0/none"

# ── first_boot_wait: finished, still moving, stuck ──────────────────────────
# shellcheck disable=SC2034 # first_boot_reachable carries FB_WAITED over
wait_rc() {
    FB_WAITED=0
    first_boot_wait "$1"
    echo $?
}
guest "nvim ok / 300"
check "crontab has no first-boot line: finished" "$(wait_rc 60)" 0
echo '@reboot root /root/first-boot-setup.sh' >"$G/etc/crontab"
# shellcheck disable=SC2317
fb_wait_tick() { echo "step$1 ok / 0" >>"$G/etc/b2b/features.status"; }
check "past the timeout, features.status moving: 75" "$(wait_rc 30)" 75
# shellcheck disable=SC2317
fb_wait_tick() { :; }
check "past the timeout, nothing moved for 5 min: 1" "$(wait_rc 330)" 1

exit "$fail"
