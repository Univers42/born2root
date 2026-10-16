#!/usr/bin/env hellish
# Inception is published on the guest's loopback and NAT address, never on
# every address.
#
# The bug this pins: on baas (2026-10-14) `tailscale serve` held the tailnet
# address's 443, and upstream's "443:443" asks docker for 0.0.0.0:443, so
# nginx never started ("failed to bind host port 0.0.0.0:443/tcp: address
# already in use"). deploy_inception.sh now writes
# srcs/docker-compose.local.yml, which upstream's Makefile adds to every
# compose call, putting each port on 127.0.0.1, and on the NAT address only
# when [network] forwards declares it: the FTP set (21, 21000-21010) has no
# forward, sat on 10.0.2.15 reachable by nothing, and failed verify_platform's
# "nothing else off loopback" check (2026-10-16).
#
# local_compose() is cut out of the script and fed a compose file shaped like
# upstream's; no VM, no docker.
set -u

cd "$(dirname "$0")/.." || exit 1
DEPLOY="setup/host/deploy_inception.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-58s = %s\n' "$1" "$2"
    else
        printf 'FAIL %-58s = %s (expected %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}

eval "$(awk '/^COMPOSE_MARK=/{print; exit}' "$DEPLOY")"
eval "$(awk '/^local_compose\(\) \{/,/^}/' "$DEPLOY")"
check "local_compose() found in $DEPLOY" "$(type local_compose >/dev/null 2>&1 && echo yes)" yes

cat >"$TMP/compose.yml" <<'YAML'
services:
  nginx:
    build:
      context: ./requirements/nginx
    container_name: nginx
    ports:
      - "443:443"
    volumes:
      - wp_data:/var/www/html:ro
  mariadb:
    image: mariadb:inception
  staticsite:
    ports:
      - "8090:8090"   # the bonus site
  adminer:
    ports:
      - 127.0.0.1:9000:9000
      - "8080:8080"
  ftp:
    ports:
      - "21:21"
      - "21000-21010:21000-21010"
    restart: always

volumes:
  wp_data:
    driver: local
YAML

# The guest ports server.toml declares: ssh, the WAF, Inception's three.
local_compose 10.0.2.15 "4242 8880 8443 443 8090 8080" <"$TMP/compose.yml" >"$TMP/local.yml"
out=$(cat "$TMP/local.yml")
entries() { awk -v s="  $1:" '$0 == s { on = 1; next } on && /^  [^ ]/ { on = 0 } on && /^ *- "/' "$TMP/local.yml" | tr -d ' ' | tr '\n' ' '; }

check "first line is the mark (it is how a rerun knows the file)" \
    "$(head -n1 "$TMP/local.yml")" "$COMPOSE_MARK"
check "nginx: 443 on loopback and the NAT address" \
    "$(entries nginx)" '-"127.0.0.1:443:443" -"10.0.2.15:443:443" '
check "a trailing comment is not part of the port" \
    "$(entries staticsite)" '-"127.0.0.1:8090:8090" -"10.0.2.15:8090:8090" '
check "an entry already on an address is kept as it is" \
    "$(entries adminer)" '-"127.0.0.1:9000:9000" -"127.0.0.1:8080:8080" -"10.0.2.15:8080:8080" '
check "ftp: undeclared, so loopback only, range and all" \
    "$(entries ftp)" '-"127.0.0.1:21:21" -"127.0.0.1:21000-21010:21000-21010" '
check "every service with ports replaces them (!override)" \
    "$(grep -c '^    ports: !override$' "$TMP/local.yml")" 4
check "a service without ports is left out" "$(printf '%s\n' "$out" | grep -c '^  mariadb:')" 0
check "nothing left on every address" \
    "$(grep -E '^ +- "' "$TMP/local.yml" | grep -vcE '^ +- "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:')" 1

# Upstream's Makefile: HTTPS_PORT from the first `- "N:443"` line, with sed.
# The one line above that is not pinned is that hint, and it must say 443.
check "upstream's HTTPS_PORT sed reads 443" \
    "$(sed -n 's/^[[:space:]]*- *"\([0-9]*\):443".*/\1/p' "$TMP/local.yml" | head -1)" 443

# The file must be YAML that compose reads; PyYAML where it is installed.
if python3 -c 'import yaml' 2>/dev/null; then
    cat >"$TMP/parse.py" <<'PY'
import sys, yaml
yaml.SafeLoader.add_constructor('!override', lambda l, n: l.construct_sequence(n))
d = yaml.safe_load(open(sys.argv[1]))
print(d['services']['nginx']['ports'][1])
PY
    check "parses as YAML, !override and all" \
        "$(python3 -I "$TMP/parse.py" "$TMP/local.yml")" 10.0.2.15:443:443
else
    echo "skip YAML parse: python3 has no yaml module"
fi

exit "$fail"
