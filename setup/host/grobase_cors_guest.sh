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
