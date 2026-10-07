#!/usr/bin/env hellish
# The end of a build: first boot has to have FINISHED, and finished clean.
# Shared by both backends (setup/host/qemu_pipeline.sh, generate/orchestrate.sh).
#
# The install watcher fails the build on B2B-FEATURE-FAILED, but only while
# d-i runs. Most of the provisioning happens later, at first boot, from an
# @reboot crontab entry with no watcher on it: a base feature failing there
# wrote /etc/b2b/PROVISION_FAILED and flagged the MOTD, and `make all` still
# exited 0 with "QEMU build finished". The VirtualBox orchestrator never even
# waited: its run ended at the LUKS unlock, so the same failure went unseen
# there until someone read the MOTD. A build is not finished until first boot
# is, so this waits for it and then reads the verdict off the guest.
#
# "Finished" is the marker first-boot-setup.sh leaves itself: its last step
# removes its own @reboot line from /etc/crontab (world-readable, no sudo).
# /etc/b2b/{PROVISION_FAILED,features.status} are 0644 for the same reason.
#
# The guest is reached with FB_SSH (an array: the command up to the target,
# default `ssh b2b`, the alias both backends write). Two hooks, redefined by a
# caller after sourcing: fb_wait_tick <seconds waited> sleeps about 15 s while
# showing progress, fb_progress <line> reports a new features.status line.

FB_SSH=(ssh b2b)

fb_ssh() {
    timeout 25 "${FB_SSH[0]}" -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 \
        "${FB_SSH[@]:1}" "$@" 2>/dev/null
}

fb_wait_tick() { sleep 15; }
fb_progress() { printf '    %s\n' "$1"; }

# first_boot_reachable: 0 once the guest answers over SSH, 1 after 5 min.
# FB_WAITED (seconds spent, carried into first_boot_wait) starts here.
first_boot_reachable() {
    FB_WAITED=${FB_WAITED:-0}
    until fb_ssh 'echo ok' >/dev/null; do
        [ "$FB_WAITED" -lt 300 ] || return 1
        sleep 10
        FB_WAITED=$((FB_WAITED + 10))
    done
}

# first_boot_wait [timeout s]: 0 when first boot finished; 75 (sysexits'
# EX_TEMPFAIL) when the timeout passed while features.status still moved in the
# last 5 min; 1 when the guest never answered or nothing moved for 5 min.
# FB_WAITED holds the seconds spent.
#
# A build that outlives the timeout is not necessarily a stuck one:
# first-boot-setup.sh runs a dozen features end to end (nvim, nvim-extras,
# docker, the dc-* provisioners...), and a slow network or a big profile can
# legitimately spend longer. The 2026-09-30 incident is the failure mode this
# replaces: the host called this a build failure while the guest was still
# inside a bounded retry and finished on its own a few minutes later
# (verify_guest: 41/41).
# Caveat: "features.status unchanged for 5 min" is the closest this can come to
# "actually stuck" without a process-tree view into the guest; one feature
# that legitimately runs longer than 5 min after the timeout reads as stuck.
first_boot_wait() {
    local timeout=${1:-1800} last="" last_changed_at=0 cur
    first_boot_reachable || return 1
    until [ "$(fb_ssh 'grep -c first-boot-setup /etc/crontab 2>/dev/null || true')" = 0 ]; do
        if [ "$FB_WAITED" -ge "$timeout" ]; then
            [ "$((FB_WAITED - last_changed_at))" -lt 300 ] && return 75
            return 1
        fi
        fb_wait_tick "$FB_WAITED"
        FB_WAITED=$((FB_WAITED + 15))
        cur=$(fb_ssh 'tail -n1 /etc/b2b/features.status 2>/dev/null')
        if [ -n "$cur" ] && [ "$cur" != "$last" ]; then
            fb_progress "$cur"
            last=$cur
            last_changed_at=$FB_WAITED
        fi
    done
    return 0
}

# first_boot_verdict: 0 when nothing essential failed (optional failures are
# listed on stderr as warnings); 1 with the details on stderr otherwise.
# FB_SUMMARY is a one-line account for the caller to print.
#
# Failures are split in two by the guest, not guessed here: an optional feature
# (nvim-extras, devtools-extra, dc-*...) lists itself in
# /etc/b2b/FEATURE_WARNINGS with the command that retries it. Anything else
# recorded as failed is essential (see ESSENTIAL_FEATURES in
# first-boot-setup.sh) and stops the build. One nvim-extras failure on
# 2026-10-04 used to fail a build whose first boot had otherwise finished in
# six minutes.
# shellcheck disable=SC2034 # FB_SUMMARY is the caller's to print
first_boot_verdict() {
    local failed warned bad fatal name status
    FB_SUMMARY=""
    if failed=$(fb_ssh 'cat /etc/b2b/PROVISION_FAILED 2>/dev/null') && [ -n "$failed" ]; then
        printf '\n  ✗ provisioning failed inside the guest (/etc/b2b/PROVISION_FAILED):\n' >&2
        printf '%s\n' "$failed" | sed 's/^/      /' >&2
        printf '\n    per feature (/etc/b2b/features.status):\n' >&2
        fb_ssh 'cat /etc/b2b/features.status 2>/dev/null' | sed 's/^/      /' >&2
        FB_SUMMARY="a required feature did not install at first boot (guest log: /var/log/b2b-provision.log)"
        return 1
    fi
    warned=$(fb_ssh 'cat /etc/b2b/FEATURE_WARNINGS 2>/dev/null' || true)
    bad=$(fb_ssh 'grep -E " (failed|no-space) " /etc/b2b/features.status 2>/dev/null' || true)
    # A warning whose feature a later `make <name>` repaired is stale: the
    # provisioners flip features.status back to ok (mark_feature_ok) and leave
    # the warning line, so only warnings still failed in features.status count.
    warned=$(printf '%s\n' "$warned" | while read -r line; do
        [ -n "$line" ] || continue
        printf '%s\n' "$bad" | grep -q "^${line%% *} " && printf '%s\n' "$line"
    done)
    fatal=$(printf '%s\n' "$bad" | while read -r line; do
        [ -n "$line" ] || continue
        printf '%s\n' "$warned" | grep -q "^${line%% *} " || printf '%s\n' "$line"
    done)
    if [ -n "$warned" ]; then
        printf '\n  ! optional features that did not install (the build still succeeded):\n' >&2
        printf '%s\n' "$warned" | sed 's/^/      /' >&2
        printf '    details: /var/log/first-boot.log and /var/log/b2b-provision.log in the guest\n' >&2
    fi
    if [ -n "$fatal" ]; then
        printf '%s\n' "$fatal" | sed 's/^/      /' >&2
        # The why is in the guest, and a CI guest is gone once this returns: a
        # hellish CI run reported "devtools-extra failed / 23" and nothing else.
        # first-boot.log (0644) holds each feature between its "--- [name] ---"
        # and "--- [name] <status>" lines; print the last 60 of that section.
        for name in $(printf '%s\n' "$fatal" | awk '{ print $1 }' | sort -u); do
            printf '\n    %s, from /var/log/first-boot.log:\n' "$name" >&2
            fb_ssh awk -v n="$name" -f - /var/log/first-boot.log <<'AWK' | sed 's/^/      /' >&2
index($0, "--- [" n "] ---") == 1 { on = 1 }
on { buf[++k] = $0 }
on && k > 1 && index($0, "--- [" n "] ") == 1 { exit }
END { for (i = (k > 60 ? k - 59 : 1); i <= k; i++) print buf[i] }
AWK
        done
        FB_SUMMARY="features.status records a failure of an essential feature (guest log: /var/log/b2b-provision.log)"
        return 1
    fi
    status=$(fb_ssh 'cat /etc/b2b/features.status 2>/dev/null' || true)
    if [ -n "$status" ]; then
        FB_SUMMARY="every feature installed: $(printf '%s\n' "$status" | grep -c ' ok ') ok, $(printf '%s\n' "$status" | grep -c ' off ') off by profile"
    else
        FB_SUMMARY="no /etc/b2b/features.status on this guest (built before feature accounting), nothing to verify"
    fi
    return 0
}
