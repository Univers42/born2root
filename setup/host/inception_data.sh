#!/usr/bin/env hellish
# ============================================================================ #
#  born2root — keep Inception's data outside Git, and bring it back             #
# ============================================================================ #
#
#   make inception_save      stop the stack, archive it on the host, restart it
#   make inception_restore   clone the project, put the secrets back, start it
#                            INCEPTION_REPO=git@host:path names the clone. Data
#                            already in the guest is kept and reconnected; the
#                            archive's volumes replace it only with FORCE=1.
#
# Git cannot hold this. The volumes carry password hashes, every MariaDB account
# and wp-config.php (8 lines of keys), and the subject fails a project with a
# credential in its repository, history included. So the archive is raw, lives
# on the host in a mode 700 folder, and is the only copy the guest needs.
#
# The stack is stopped while the volumes are read: a tar of a running MariaDB
# can restore to a database that does not start. Restoring the same secrets is
# what makes the volumes usable, since MariaDB accepts only the passwords it was
# initialised with. The image that packs and unpacks is the project's own, so
# the archive needs nothing the project does not already build.
#
# The osionos tools and their password live in ~/data/.keep/ops, so the volumes
# carry them; the crontab that starts them is the one thing kept beside secrets.
#
# Caveat: this is a point-in-time copy. Whatever is written after a save is lost
# by a restore, and showcase grows about 1 MB a day under its simulator.
# ============================================================================ #
set -u

DEST="${INCEPTION_BACKUP_DIR:-/sgoinfre/students/${USER}/b2b-backups/inception}"
SSH_ALIAS="${SSH_ALIAS:-b2b}"
GUEST_DIR="${INCEPTION_DIR:-Documents/inception}"
REPO="${INCEPTION_REPO:-}"
COMPOSE="docker compose -f srcs/docker-compose.yml"
SSH_OPTS=(-T -o BatchMode=yes -o ClearAllForwardings=yes)

step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
die() {
    printf '  \033[31m✗\033[0m %s\n' "$1" >&2
    exit 1
}

# The command string is composed here and expanded there, on purpose.
# shellcheck disable=SC2029
vm() { ssh "${SSH_OPTS[@]}" "$SSH_ALIAS" "$@"; }

save() {
    vm "test -f '$GUEST_DIR/srcs/.env'" || die "no project at ~/$GUEST_DIR in the guest"
    mkdir -p "$DEST" || die "cannot write $DEST"
    chmod 700 "$DEST" || die "cannot write $DEST"
    local fresh="$DEST/.new"
    rm -rf "$fresh"
    mkdir -p "$fresh" || die "cannot write $fresh"
    chmod 700 "$fresh" || die "cannot write $fresh"

    step "Stopping the stack, so MariaDB is at rest"
    vm "cd '$GUEST_DIR' && $COMPOSE stop" >/dev/null 2>&1 || die "the stack did not stop"
    ok "stopped"

    step "Archiving"
    vm "docker run --rm --entrypoint sh -v \"\$HOME/data:/d:ro\" mariadb:inception -c 'tar -czf - -C /d .'" \
        >"$fresh/volumes.tgz"
    local volumes_rc=$?
    vm "crontab -l > .inception-crontab 2>/dev/null; tar -czf - -C '$GUEST_DIR' secrets srcs/.env \
        -C \"\$HOME\" .inception-crontab; rc=\$?; \
        rm -f .inception-crontab; exit \$rc" >"$fresh/config.tgz"
    local config_rc=$?

    step "Starting the stack again"
    vm "cd '$GUEST_DIR' && $COMPOSE start" >/dev/null 2>&1 || die "the stack did not restart: ssh b2b, then make"
    ok "started"

    [ "$volumes_rc" -eq 0 ] || die "the archive failed; the previous one is untouched"
    [ "$config_rc" -eq 0 ] || die "the archive failed; the previous one is untouched"
    gzip -t "$fresh/volumes.tgz" || die "the archive is corrupt; the previous one is untouched"
    gzip -t "$fresh/config.tgz" || die "the archive is corrupt; the previous one is untouched"
    tar -tzf "$fresh/volumes.tgz" | grep -q 'wordpress/wp-config.php' || die "the archive has no WordPress volume"
    tar -tzf "$fresh/config.tgz" | grep -q 'secrets/db_root_password.txt' || die "the archive has no secrets"

    # The last save survives this one, and neither can be overwritten by accident.
    if [ -d "$DEST/latest" ]; then
        [ -d "$DEST/previous" ] && chmod -R u+w "$DEST/previous" && rm -rf "$DEST/previous"
        chmod -R u+w "$DEST/latest"
        mv "$DEST/latest" "$DEST/previous"
        chmod -R a-w "$DEST/previous"
    fi
    mv "$fresh" "$DEST/latest"
    ok "saved $(du -sh "$DEST/latest" | cut -f1) in $DEST/latest"
    chmod -R a-w "$DEST/latest"
}

restore() {
    [ -s "$DEST/latest/volumes.tgz" ] || die "no archive in $DEST/latest: make inception_save"
    [ -s "$DEST/latest/config.tgz" ] || die "no archive in $DEST/latest: make inception_save"
    gzip -t "$DEST/latest/volumes.tgz" || die "the archive is corrupt"
    gzip -t "$DEST/latest/config.tgz" || die "the archive is corrupt"

    local keep_data=0
    if vm "test -e \"\$HOME/data/wordpress/wp-config.php\"" && [ "${FORCE:-0}" != 1 ]; then
        keep_data=1
    fi

    step "Getting the project"
    if vm "test -d '$GUEST_DIR/.git'"; then
        ok "already at ~/$GUEST_DIR"
    else
        [ -n "$REPO" ] || die "no project in the guest: name it with INCEPTION_REPO=git@host:path"
        ssh -A -T -o ClearAllForwardings=yes "$SSH_ALIAS" \
            "export GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes'; mkdir -p '$GUEST_DIR' && git clone -q '$REPO' '$GUEST_DIR'" ||
            die "the clone failed"
        ok "cloned into ~/$GUEST_DIR"
    fi

    step "Putting the secrets back"
    vm "mkdir -p '$GUEST_DIR/srcs' && tar -xzf - -C /tmp/ --no-same-owner --one-top-level=.idata &&
        cd /tmp/.idata && cp -a secrets srcs \"\$HOME/$GUEST_DIR/\" &&
        crontab .inception-crontab && cd /tmp && rm -rf .idata" <"$DEST/latest/config.tgz" ||
        die "the secrets did not go back"
    ok "secrets, .env and crontab restored"

    step "Building the images"
    vm "cd '$GUEST_DIR' && make build" >/dev/null 2>&1 || die "the build failed: ssh b2b, then make build"
    ok "built"

    if [ "$keep_data" = 1 ]; then
        step "Reconnecting"
        ok "the data already in the guest is kept (FORCE=1 replaces it with the archive)"
        vm "cd '$GUEST_DIR' && make install" || die "make install refused, see above"
        return 0
    fi

    step "Putting the volumes back"
    vm "docker run --rm -i --entrypoint sh -v \"\$HOME/data:/d\" mariadb:inception \
        -c 'rm -rf /d/mariadb /d/wordpress /d/backups; tar -xzf - -C /d'" <"$DEST/latest/volumes.tgz" ||
        die "the volumes did not go back"
    ok "volumes restored"

    step "Starting and proving it"
    vm "cd '$GUEST_DIR' && make install" || die "make install refused, see above"
}

case "${1:-}" in
save) save ;;
restore) restore ;;
*) die "usage: inception_data.sh save|restore" ;;
esac
