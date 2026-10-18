#!/usr/bin/env hellish
# Pins the clone step of setup/host/deploy_inception.sh. A guest directory
# holding only runtime state -- secrets/ put back from the running containers
# after the tree was deleted (2026-10-18) -- made `git clone` refuse with
# "destination path already exists", so `make inception` could not rebuild
# around the very secrets that keep MariaDB's data readable.
# Caveat: runs the block cut out by awk (from its `step "Cloning` line to its
# `ok "repository present` line) with vm_ssh as a local sh and REPO_URL a
# throwaway repository; ssh quoting is exercised only as far as sh -c is.
# shellcheck disable=SC2034,SC2317,SC2329 # read and invoked by the sourced block
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s -- got: %s, expected: %s\n' "$1" "$2" "$3"
        fail=1
    fi
}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
awk '/step "Cloning/{p=1} p{print} p && /ok "repository present/{exit}' \
    setup/host/deploy_inception.sh >"$T/block"
check "block extracted" "$(head -n1 "$T/block" | grep -c 'step "Cloning'):$(tail -n1 "$T/block" | grep -c 'repository present')" 1:1

git init -q -b main "$T/upstream"
mkdir -p "$T/upstream/srcs"
printf 'all:\n' >"$T/upstream/Makefile"
printf 'secrets/\nsrcs/.env\n' >"$T/upstream/.gitignore"
git -C "$T/upstream" add -A
git -C "$T/upstream" -c user.name=t -c user.email=t@t commit -qm init

# One deploy: the block with the script's helpers stubbed, in a subshell.
deploy() {
    (
        step() { :; }
        ok() { :; }
        die() {
            printf 'died: %s\n' "$*"
            exit 1
        }
        vm_ssh() { sh -c "$1"; }
        REPO_URL="$T/upstream" BRANCH=main GUEST_DIR="$1"
        # shellcheck disable=SC1091 # generated above
        . "$T/block"
    )
}

G="$T/rescue/inception"
mkdir -p "$G/secrets" "$G/srcs"
printf 'old-db-pass\n' >"$G/secrets/db_password.txt"
printf 'DOMAIN_NAME=x.42.fr\n' >"$G/srcs/.env"
check "a directory holding only secrets/ is cloned into" "$(deploy "$G")" ""
check "  ...the tracked files are there" "$([ -f "$G/Makefile" ] && git -C "$G" rev-parse --abbrev-ref HEAD)" main
check "  ...the secret is kept, byte for byte" "$(cat "$G/secrets/db_password.txt")" old-db-pass
check "  ...srcs/.env is kept" "$(cat "$G/srcs/.env")" DOMAIN_NAME=x.42.fr
check "  ...no clone directory left beside it" "$(find "$T/rescue" -maxdepth 1 -name 'inception.clone.*' | wc -l | tr -d ' ')" 0
check "  ...the tree is clean apart from ignored state" "$(git -C "$G" status --porcelain)" ""

check "a missing directory is cloned" "$(deploy "$T/fresh/inception")" ""
check "  ...with its files" "$([ -f "$T/fresh/inception/Makefile" ] && echo yes)" yes

printf 'all: up\n' >"$T/upstream/Makefile"
git -C "$T/upstream" -c user.name=t -c user.email=t@t commit -qam next
check "an existing repository is pulled" "$(deploy "$G")" ""
check "  ...to the new commit" "$(cat "$G/Makefile")" "all: up"
check "  ...the secret still kept" "$(cat "$G/secrets/db_password.txt")" old-db-pass

exit "$fail"
