#!/usr/bin/env hellish
# What a feature pulls in: the apt packages and the container images, so that
# composing a datacenter is a decision taken with the list in front of you
# (`make packages`, `make packages FEATURE=dc-db-postgres`).
#
# This is a second table on purpose. feature_profile.sh's MANIFEST has seven
# columns and everything that reads it -- names(), field(), feature_select.sh,
# utils/b2b_config.py -- filters on NF == 7, so a column of package names can
# never go there. Rows here are keyed by the same feature names; a name that
# is not in the MANIFEST is an error, so the two cannot drift apart silently.
#
#   feature_packages.sh                every feature
#   feature_packages.sh <feature>      one feature
#   feature_packages.sh <bundle>       a bundle, expanded to its members
#
# A row is: name, then "apt:" packages, then "img:" images, any order, "-"
# for none. Images are the ones the guest actually pulls (grobase publishes
# every service to ghcr.io/univers42 as a pull-fallback beside its build
# context, so nothing below is built in the guest).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
FP="$HERE/feature_profile.sh"

PACKAGES='
debian-base       apt: (what debian-installer lays down) img: -
b2b-mandatory     apt: sudo ufw openssh-server libpam-pwquality apparmor cron haveged img: -
devtools-apt      apt: git curl wget tmux htop tree jq ripgrep fd-find unzip build-essential img: -
nvim              apt: neovim nodejs npm img: -
npm-cache         apt: (a reservation: ~/.npm for the editor tooling) img: -
vscode-remote     apt: (a reservation: ~/.vscode-server, written on first remote connect) img: -
nvim-extras       apt: fzf lazygit img: -
webstack          apt: lighttpd mariadb-server php-fpm php-mysql img: -
nodejs            apt: nodejs npm img: -
pytools           apt: pipx img: -
devtools-extra    apt: - img: -
claude-code       apt: - img: -
docker            apt: docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin img: -
inception-data    apt: (a reservation: the Inception volumes under ~/data) img: -
ai-client         apt: - img: -
ai-local          apt: - img: (a GGUF model under /opt, sized from RAM by install_ai.sh)
dc-netmesh        apt: tailscale img: -
dc-tunnel         apt: cloudflared img: -
dc-backup         apt: restic img: -
dc-var-gc         apt: - img: -
dc-gateway        apt: git make img: ghcr.io/univers42/grobase-kong ghcr.io/univers42/grobase-waf ghcr.io/univers42/grobase-tenant-control ghcr.io/univers42/grobase-data-plane-router
dc-identity       apt: - img: ghcr.io/univers42/grobase-gotrue ghcr.io/univers42/grobase-session-service ghcr.io/univers42/grobase-permission-engine
dc-realtime       apt: - img: ghcr.io/univers42/grobase-realtime
dc-secrets        apt: - img: hashicorp/vault
dc-db-postgres    apt: - img: ghcr.io/univers42/grobase-postgres ghcr.io/univers42/grobase-postgrest ghcr.io/univers42/grobase-pg-meta ghcr.io/univers42/grobase-db-bootstrap
dc-db-mysql       apt: - img: mysql
dc-db-mongo       apt: - img: ghcr.io/univers42/grobase-mongo ghcr.io/univers42/grobase-mongo-api ghcr.io/univers42/grobase-mongo-init
dc-db-redis       apt: - img: ghcr.io/univers42/grobase-redis
dc-db-cockroach   apt: - img: ghcr.io/univers42/grobase-cockroach
dc-db-mssql       apt: - img: mcr.microsoft.com/mssql/server
dc-objectstore    apt: - img: ghcr.io/univers42/grobase-minio
dc-storage        apt: - img: ghcr.io/univers42/grobase-storage-router
dc-observability  apt: - img: prom/prometheus ghcr.io/univers42/grobase-grafana grafana/loki
dc-data           apt: - img: (a reservation: the space the engines above will fill)
'

die() {
    printf 'feature_packages: %s\n' "$*" >&2
    exit 1
}

manifest_names() { sed -n "/^MANIFEST='/,/^'/p" "$FP" | awk 'NF == 7 { print $1 }'; }
bundle_row() { sed -n "/^BUNDLES='/,/^'/p" "$FP" | awk -v n="$1" '$1 == n { for (i = 2; i <= NF; i++) print $i }'; }
is_bundle() { [ -n "$(bundle_row "$1")" ]; }
expand() {
    local m
    for m in $(bundle_row "$1"); do
        if is_bundle "$m"; then expand "$m"; else printf '%s\n' "$m"; fi
    done
}

row_of() { printf '%s\n' "$PACKAGES" | awk -v n="$1" '$1 == n'; }

# print_one <feature>
print_one() {
    local n="$1" row apt img
    row=$(row_of "$n")
    [ -n "$row" ] || die "no package row for '$n' -- add one to PACKAGES in $0"
    apt=$(printf '%s\n' "$row" | sed -n 's/^[^ ]* *apt: *\(.*\) img:.*/\1/p')
    img=$(printf '%s\n' "$row" | sed -n 's/.* img: *\(.*\)$/\1/p')
    printf '  %-17s\n' "$n"
    [ "$apt" = - ] || printf '    apt: %s\n' "$apt"
    [ "$img" = - ] || printf '    img: %s\n' "$img"
}

# Every MANIFEST row must have a package row, and vice versa: this is the
# check that keeps the two tables honest, and tests/test_feature_packages.sh
# runs it on every commit.
check_consistency() {
    local n ok=0
    for n in $(manifest_names); do
        [ -n "$(row_of "$n")" ] || {
            echo "feature_packages: MANIFEST row '$n' has no package row" >&2
            ok=1
        }
    done
    for n in $(printf '%s\n' "$PACKAGES" | awk 'NF { print $1 }'); do
        manifest_names | grep -qx -- "$n" || {
            echo "feature_packages: package row '$n' is not in the MANIFEST" >&2
            ok=1
        }
    done
    return "$ok"
}

case "${1:-}" in
--check)
    check_consistency && echo "feature_packages: every feature has a package row, and no row is stale"
    ;;
'')
    check_consistency || exit 1
    printf '\n  What each feature installs (apt) and pulls (images)\n\n'
    for n in $(manifest_names); do
        print_one "$n"
    done
    printf '\n  A bundle expands to its members: make packages FEATURE=dc-standard\n\n'
    ;;
*)
    if is_bundle "$1"; then
        printf '\n  %s expands to:\n\n' "$1"
        for n in $(expand "$1"); do
            print_one "$n"
        done
        printf '\n'
    elif manifest_names | grep -qx -- "$1"; then
        printf '\n'
        print_one "$1"
        printf '\n'
    else
        die "unknown feature or bundle '$1' (see make features, make packages)"
    fi
    ;;
esac
