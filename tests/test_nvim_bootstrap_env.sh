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
#
# 3. clear_provision_failed, the other half of that verdict (see below).
#
# 4. wait_nvim_jobs, which run_as_user calls after every run (see below).
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
unset NVIM_TERM NVIM_CFLAGS

# shellcheck disable=SC2317 # called by the function bodies eval'd below
log() { :; }
# shellcheck disable=SC2317 # called by the function bodies eval'd below
warn() { :; }

for script in setup/install/nvim/install_nvim.sh setup/install/nvim/install_nvim_extras.sh; do
    name=$(basename "$script")
    eval "$(awk '/^nvim_jobs_left\(\) \{/,/^}/' "$REPO/$script")"
    eval "$(awk '/^wait_nvim_jobs\(\) \{/,/^}/' "$REPO/$script")"
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
    # shellcheck disable=SC2016 # $CFLAGS is meant for the inner sh
    check "$name: parser compiles skip -Wuninitialized" \
        "$(run_as_user alice sh -c 'printf %s "$CFLAGS"')" "-Wno-uninitialized"
    chmod 755 "$TMP/locked"
    cd "$REPO"
done

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

# 3. clear_provision_failed removes the marker when this feature was its only
#    line. The bug: it filtered with `grep -v`, which exits 1 when nothing is
#    left, took that for an error, and kept the marker -- so after a clean
#    `make nvim` the guest still read as failed and `make all` still stopped.
B2B_PROVISION_FAILED="$TMP/PROVISION_FAILED"
for script in setup/install/nvim/install_nvim.sh setup/install/nvim/install_nvim_extras.sh; do
    name=$(basename "$script")
    body=$(awk '/^clear_provision_failed\(\) \{/,/^}/' "$REPO/$script")
    if [ -z "$body" ]; then
        check "$name: clear_provision_failed found" "missing" "present"
        continue
    fi
    eval "$body"

    printf 'nvim install_nvim.sh failed (plugins missing)\n' >"$B2B_PROVISION_FAILED"
    clear_provision_failed nvim
    check "$name: the only failing feature removes the marker" \
        "$([ -e "$B2B_PROVISION_FAILED" ] && echo present || echo removed)" "removed"

    printf 'nvim why\nnvim-extras why\ndocker why\n' >"$B2B_PROVISION_FAILED"
    clear_provision_failed nvim
    check "$name: other features' lines stay" \
        "$(tr '\n' '|' <"$B2B_PROVISION_FAILED")" "nvim-extras why|docker why|"
    clear_provision_failed webstack
    check "$name: a feature with no line changes nothing" \
        "$(tr '\n' '|' <"$B2B_PROVISION_FAILED")" "nvim-extras why|docker why|"
    rm -f "$B2B_PROVISION_FAILED"
done

# 4. wait_nvim_jobs outlasts what an exited Neovim left running. The bug: a
#    headless start exits under kickstart's async parser install, its curl
#    keeps fetching into ~/.cache/nvim with PPID 1, and the next process's
#    install of the same parser failed with ENOTEMPTY at first boot. Real
#    processes here, found the two ways the guest's are: by cwd (tar, tree-sitter
#    build) and by an argument (curl's --output).
me=$(id -un)
mkdir -p "$TMP/home/alice/.cache/nvim/tree-sitter-c" "$TMP/home/alice/.local/share/nvim"
for script in setup/install/nvim/install_nvim.sh setup/install/nvim/install_nvim_extras.sh; do
    name=$(basename "$script")
    eval "$(awk '/^nvim_jobs_left\(\) \{/,/^}/' "$REPO/$script")"
    eval "$(awk '/^wait_nvim_jobs\(\) \{/,/^}/' "$REPO/$script")"

    check "$name: nothing left is reported as nothing" "$(nvim_jobs_left "$me" "$TMP/home/alice")" ""
    t0=$(date +%s)
    rc=0
    wait_nvim_jobs "$me" "$TMP/home/alice" || rc=$?
    check "$name: nothing left, no wait" "$rc $([ $(($(date +%s) - t0)) -le 1 ] && echo prompt)" "0 prompt"

    (cd "$TMP/home/alice/.cache/nvim/tree-sitter-c" && exec sleep 3) &
    sleep 0.3
    t0=$(date +%s)
    wait_nvim_jobs "$me" "$TMP/home/alice"
    check "$name: waits out a job by its cwd" "$([ $(($(date +%s) - t0)) -ge 2 ] && echo waited)" "waited"

    # curl's shape: no cwd of its own, an --output path in ~/.cache/nvim.
    sh -c 'sleep 3' --output "$TMP/home/alice/.cache/nvim/tree-sitter-c.tar.gz" &
    sleep 0.3
    t0=$(date +%s)
    wait_nvim_jobs "$me" "$TMP/home/alice"
    check "$name: waits out a job by its argument" "$([ $(($(date +%s) - t0)) -ge 2 ] && echo waited)" "waited"

    # A language server an open Neovim is running is not left-behind work.
    sh -c 'sleep 4' "$TMP/home/alice/.local/share/nvim/mason/packages/lua-language-server/bin" &
    lsp=$!
    sleep 0.3
    t0=$(date +%s)
    wait_nvim_jobs "$me" "$TMP/home/alice"
    check "$name: a running language server is not waited for" "$([ $(($(date +%s) - t0)) -le 1 ] && echo prompt)" "prompt"
    kill "$lsp" 2>/dev/null || true
    wait "$lsp" 2>/dev/null || true

    (cd "$TMP/home/alice/.cache/nvim" && exec sleep 6) &
    job=$!
    sleep 0.3
    # shellcheck disable=SC2034 # read by the wait_nvim_jobs body eval'd above
    NVIM_JOBS_WAIT=1
    rc=0
    wait_nvim_jobs "$me" "$TMP/home/alice" || rc=$?
    unset NVIM_JOBS_WAIT
    check "$name: gives up after NVIM_JOBS_WAIT, non-zero" "$rc" "1"
    kill "$job" 2>/dev/null || true
    wait "$job" 2>/dev/null || true
done

exit "$fail"
