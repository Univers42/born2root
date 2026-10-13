#!/usr/bin/env hellish
# firewall_guest.sh -- runs INSIDE the guest, as root, pushed by `make
# firewall` through provision_vm.sh's root-sh path. It makes UFW match the
# profile's [network] forwards on a guest that is already running.
#
#   ROOTSH_FIREWALL   "name:port ..." -- B2B_FIREWALL, read from the host's
#                     profile now, not from the build.conf the guest was built with
#
# First boot resets UFW and applies the list (first-boot-setup.sh, 3c), so a
# fresh build is already exact. A live guest kept every port an older profile
# listed: on 2026-10-13 baas still allowed fifteen dead ones. This deletes
# those, adds a listed port that is missing, and leaves everything that is
# not born2root's alone. Port 4242 is always kept, as at first boot: it is
# the only way in.
#
# Ponytail: "born2root's" is recognised by shape -- PORT/tcp, ALLOW IN, from
# Anywhere, with a comment -- because that is how first boot adds every rule.
# A hand-added rule of exactly that shape, comment included, is taken for
# born2root's and deleted when its port is not listed. A born2root rule that
# was edited to another shape (a source address, a range) is not recognised
# and is kept. `ufw status numbered` before and after is printed, so a wrong
# call is visible and can be undone by hand.
set -u
log() { printf '[firewall] %s\n' "$*"; }
die() {
    printf '[firewall] ✗ %s\n' "$*" >&2
    exit 1
}
[ -n "${ROOTSH_FIREWALL:-}" ] || die "no ROOTSH_FIREWALL: with an empty list every forward would go (make firewall passes the profile's)"
command -v ufw >/dev/null 2>&1 || die "ufw is not installed"

keep=" 4242 "
for rule in $ROOTSH_FIREWALL; do
    case "$keep" in *" ${rule##*:} "*) ;; *) keep="$keep${rule##*:} " ;; esac
done

# stale_rules: the numbers of born2root's rules whose port is not kept,
# highest first, so each delete leaves the lower numbers valid.
stale_rules() {
    ufw status numbered | awk -v keep="$keep" '
        match($0, /^\[ *[0-9]+\] [0-9]+\/tcp( \(v6\))? +ALLOW IN +Anywhere( \(v6\))? +# ./) {
            n = $0; sub(/^\[ */, "", n); sub(/\].*/, "", n)
            port = $0; sub(/^\[ *[0-9]+\] /, "", port); sub(/\/tcp.*/, "", port)
            if (index(keep, " " port " ") == 0) print n, port
        }' | sort -rn
}

ufw status | head -n1 | grep -q '^Status: active' || log "ufw is not active: rules are recorded, none is enforced (ufw enable)"
removed=""
stale=$(stale_rules)
while read -r n port; do
    [ -n "$n" ] || continue
    ufw --force delete "$n" >/dev/null || die "ufw delete $n ($port/tcp) failed"
    case " $removed " in *" $port "*) ;; *) removed="$removed $port" ;; esac
done <<EOF
$stale
EOF
for rule in $ROOTSH_FIREWALL; do
    ufw allow "${rule##*:}/tcp" comment "${rule%%:*}" >/dev/null || die "ufw allow ${rule##*:}/tcp failed"
done

status=$(ufw status)
missing=""
for port in $keep; do
    printf '%s\n' "$status" | grep -qE "^ *${port}/tcp +ALLOW" || missing="$missing $port"
done
[ -z "$(stale_rules)" ] || die "stale rules are still there: $(stale_rules | awk '{ print $2 }' | sort -u | tr '\n' ' ')"
[ -z "$missing" ] || die "ufw does not allow${missing} (tcp)"
removed=$(printf '%s' "$removed" | tr ' ' '\n' | grep . | sort -n | tr '\n' ' ')
log "allowed:$(printf '%s' "$keep" | tr -s ' ' | sed 's/ $//')${removed:+; removed ${removed% }}"
