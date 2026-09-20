#!/usr/bin/env hellish
# grobase_cors_guest.sh -- runs INSIDE the guest. `make grobase_cors` pipes it
# over SSH as `bash -s -- <origin>...`: paste each origin after Kong's
# FRONTEND placeholder in kong.yml (once), restart Kong so its entrypoint
# re-renders the file, print the resulting origin list. The same loop
# install_grobase.sh runs at first boot, for a VM that is already up.
#
# A file rather than an inline CMD because the guest's login shell is
# hellish, which does not keep `\(` inside double quotes the way sed needs
# it ("unterminated `s' command" was the whole error). The sed program is
# single-quoted here for the same reason, the origin spliced in between.
set -eu
cd /opt/grobase
f=infra/docker/services/kong/conf/kong.yml
for origin in "$@"; do
    if ! grep -qF -- "- ${origin}" "$f"; then
        sed -i 's|^\(\s*\)- __KONG_CORS_ORIGIN_FRONTEND__$|&\n\1- '"${origin}"'|' "$f"
        printf '[grobase] cors: allowed origin %s\n' "$origin"
    fi
done
docker restart mini-baas-kong >/dev/null
grep -nE '^\s+- (http|__KONG)' "$f"

# The realtime plane needs the same list, separately: a WebSocket handshake is
# not a CORS request, so Kong's origin list never reaches it and the socket
# opened for any website that asked (found by the Laboratory bench's stranger
# origin, 2026-09-20). grobase reads REALTIME_ALLOWED_ORIGINS from .env;
# EMPTY there means "check nothing", which is the old behaviour.
origins=$(sed -n 's/^KONG_CORS_ORIGIN_[A-Z]*=//p' .env | grep . | tr '\n' ',')
for origin in "$@"; do
    case ",${origins}" in
    *",${origin},"*) ;;
    *) origins="${origins}${origin}," ;;
    esac
done
origins=${origins%,}
if grep -q '^REALTIME_ALLOWED_ORIGINS=' .env; then
    sed -i 's|^REALTIME_ALLOWED_ORIGINS=.*|REALTIME_ALLOWED_ORIGINS='"${origins}"'|' .env
else
    printf 'REALTIME_ALLOWED_ORIGINS=%s\n' "$origins" >>.env
fi
printf '[grobase] realtime: sockets allowed from %s\n' "$origins"

# Recreate that one service with the exact compose invocation it was created
# with -- read back from its own labels rather than guessed, and passed through
# COMPOSE_FILE so no shell has to split a comma-separated list. grobase's own
# `make up` re-resolves every published port and moves the WAF; this touches
# one container that publishes nothing.
project=$(docker inspect mini-baas-realtime -f '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null || true)
files=$(docker inspect mini-baas-realtime -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' 2>/dev/null || true)
workdir=$(docker inspect mini-baas-realtime -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null || true)
if [ -n "$project" ] && [ -n "$files" ]; then
    COMPOSE_FILE="$files" COMPOSE_PATH_SEPARATOR=, \
        docker compose -p "$project" --project-directory "${workdir:-/opt/grobase}" up -d --no-deps realtime >/dev/null 2>&1 ||
        printf '[grobase] realtime: could not recreate the container; restart it by hand to pick the origins up\n'
    printf '[grobase] realtime: %s\n' "$(docker inspect mini-baas-realtime -f '{{.State.Status}}' 2>/dev/null || echo absent)"
else
    printf '[grobase] realtime: not running; the origins take effect at the next up\n'
fi
