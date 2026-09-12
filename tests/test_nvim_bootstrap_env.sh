#!/usr/bin/env hellish
# The environment the guest provisioners give their unprivileged runs, and the
# verdict a successful re-run leaves behind. Both are host-testable: the
# functions are lifted out of the scripts, with runuser and getent stubbed.
#
# 1. run_as_user runs from the user's HOME. The bug this pins: at first boot
#    install_nvim.sh runs from cron's /root (mode 700), runuser kept that
#    directory, and vim.pack -- which spawns git with nvim's working directory
#    as `cwd` -- hit EACCES inside its async task and dropped the error. On the
#    2026-09-12 QEMU build that was 0 of 58 plugins on disk with every run
#    saying "100% Installing plugins" and exiting 0. The cwd here is a mode-000
#    directory, so the old function prints it and the fixed one prints $HOME.
#
# 2. mark_feature_ok flips only its own feature's failed lines. The bug: a
#    `make nvim` that fixed the guest cleared PROVISION_FAILED, but the "nvim
#    failed" lines in features.status stayed, and qemu_pipeline.sh fails
#    `make all` on those alone. "nvim" must not touch "nvim-extras".
set -e

cd "$(dirname "$0")/.."
REPO=$(pwd)

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-52s = %s\n' "$1" "$3"
    else
        printf 'FAIL %-52s = %s (expected %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}

TMP=$(mktemp -d)
trap 'cd /; chmod 755 "$TMP/locked" 2>/dev/null; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home/alice" "$TMP/home/root" "$TMP/locked"

cat >"$TMP/bin/runuser" <<'EOF'
#!/bin/sh
# runuser -u <user> -- cmd...: the switch itself is not what is under test.
[ "$1" = -u ] && shift 2
[ "$1" = -- ] && shift
exec "$@"
EOF
cat >"$TMP/bin/getent" <<EOF
#!/bin/sh
[ "\$1" = passwd ] || exit 2
printf '%s:x:1000:1000::%s/home/%s:/bin/sh\n' "\$2" "$TMP" "\$2"
EOF
chmod +x "$TMP/bin/runuser" "$TMP/bin/getent"
PATH="$TMP/bin:$PATH"
export PATH
# shellcheck disable=SC2034 # read by the run_as_user bodies eval'd below
NVIM_BOOTSTRAP_TIMEOUT=20
unset NVIM_TERM

for script in setup/install/nvim/install_nvim.sh setup/install/nvim/install_nvim_extras.sh; do
    name=$(basename "$script")
    body=$(awk '/^run_as_user\(\) \{/,/^}/' "$REPO/$script")
    if [ -z "$body" ]; then
        check "$name: run_as_user found" "missing" "present"
        continue
    fi
    eval "$body"

    cd "$TMP/locked"
    chmod 000 "$TMP/locked"
    check "$name: a user's run starts in their home" \
        "$(run_as_user alice pwd)" "$TMP/home/alice"
    check "$name: root's run starts in its home" \
        "$(run_as_user root pwd)" "$TMP/home/root"
    # shellcheck disable=SC2016 # $TERM is meant for the inner sh
    check "$name: TERM still reaches the command" \
        "$(run_as_user alice sh -c 'printf %s "$TERM"')" "xterm-256color"
    chmod 755 "$TMP/locked"
    cd "$REPO"
done

# shellcheck disable=SC2317 # called by the mark_feature_ok bodies eval'd below
log() { :; }
B2B_FEATURES_STATUS="$TMP/features.status"
for script in setup/install/nvim/install_nvim.sh setup/install/nvim/install_nvim_extras.sh \
    setup/install/ai/install_claude_code.sh; do
    name=$(basename "$script")
    body=$(awk '/^mark_feature_ok\(\) \{/,/^}/' "$REPO/$script")
    if [ -z "$body" ]; then
        check "$name: mark_feature_ok found" "missing" "present"
        continue
    fi
    eval "$body"

    cat >"$B2B_FEATURES_STATUS" <<'EOF'
nvim failed / 352
nvim failed /home 1
nvim-extras failed /opt 43
hellish-upstream ok /home 1
claude-code failed - 0
docker no-space /var 0
EOF
    chmod 644 "$B2B_FEATURES_STATUS"

    mark_feature_ok nvim
    check "$name: nvim's lines flipped, MB unmeasured" \
        "$(grep -c '^nvim ok [^ ]* -$' "$B2B_FEATURES_STATUS")" "2"
    check "$name: nvim-extras left alone by 'nvim'" \
        "$(grep '^nvim-extras ' "$B2B_FEATURES_STATUS")" "nvim-extras failed /opt 43"
    mark_feature_ok claude-code
    check "$name: a '-' mount flips too" \
        "$(grep '^claude-code ' "$B2B_FEATURES_STATUS")" "claude-code ok - -"
    mark_feature_ok docker
    check "$name: no-space counts as failed" \
        "$(grep '^docker ' "$B2B_FEATURES_STATUS")" "docker ok /var -"
    mark_feature_ok hellish-upstream
    check "$name: an ok line is untouched" \
        "$(grep '^hellish-upstream ' "$B2B_FEATURES_STATUS")" "hellish-upstream ok /home 1"
    check "$name: line count unchanged" "$(wc -l <"$B2B_FEATURES_STATUS" | tr -d ' ')" "6"
    check "$name: mode kept (0644, pipelines read it)" "$(stat -c %a "$B2B_FEATURES_STATUS")" "644"
    rm -f "$B2B_FEATURES_STATUS"
    mark_feature_ok nvim
    check "$name: no status file is not an error" "$?" "0"
done

exit "$fail"
