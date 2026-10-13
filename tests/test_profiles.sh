#!/usr/bin/env hellish
# profiles/*.toml are presets selected with B2B_CONFIG=. Two things can rot
# silently: a preset can stop validating (a feature renamed, a key added),
# and a preset's feature set can stop fitting its own disk. Either is found
# here, on the host, in a second -- not 25 minutes into an install.
#
# What each profile promises:
#   school.toml   the Born2beRoot subject at 15 GB: nvim on, docker and the
#                 bonus off, and it fits.
#   server.toml   backend only at 120 GB: no nvim, docker on, every dc-* row
#                 on (the max tier's add-ons included), 14 GiB of RAM, a
#                 40 GB IDE disk, and it fits with /var holding the engines.
set -e

cd "$(dirname "$0")/.."

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s -- got: %s, expected: %s\n' "$1" "$2" "$3"
        fail=1
    fi
}
rc_of() {
    "$@" >/dev/null 2>&1 && echo 0 || echo $?
}
export B2B_NO_SELECT=1 B2B_SELECT_FILE=/nonexistent

# resolve <profile> -> the feature=... lines feature_profile.sh emits for it,
# at the profile's own disk size and with the FEATURES string the Makefile
# would derive from its [features].
resolve() {
    local cfg="profiles/$1.toml" gb feats
    gb=$(sed -n 's/^disk_gb *= *\([0-9]*\).*/\1/p' "$cfg" | head -n1)
    feats=$(env B2B_CONFIG="$cfg" bash utils/b2b_config.sh get B2B_FEATURES)
    env B2B_CONFIG="$cfg" SIZE_B2B="$gb" FEATURES="$feats" bash generate/feature_profile.sh --resolve
}
fits() {
    local cfg="profiles/$1.toml" gb feats
    gb=$(sed -n 's/^disk_gb *= *\([0-9]*\).*/\1/p' "$cfg" | head -n1)
    feats=$(env B2B_CONFIG="$cfg" bash utils/b2b_config.sh get B2B_FEATURES)
    rc_of env B2B_CONFIG="$cfg" SIZE_B2B="$gb" FEATURES="$feats" bash generate/feature_profile.sh --check
}

for p in school server; do
    check "$p.toml validates" "$(rc_of env B2B_CONFIG=profiles/$p.toml bash utils/b2b_config.sh --check)" 0
    check "$p.toml: the layout is computable" "$(rc_of env B2B_CONFIG=profiles/$p.toml bash generate/partition_recipe.sh --sizes)" 0
    check "$p.toml: its feature set fits its disk" "$(fits $p)" 0
done

s=$(resolve school)
check "school: b2b-mandatory on" "$(printf '%s\n' "$s" | grep -c '^feature=b2b-mandatory$')" 1
check "school: nvim on (core)" "$(printf '%s\n' "$s" | grep -c '^feature=nvim$')" 1
check "school: docker off" "$(printf '%s\n' "$s" | grep -c '^feature=docker$')" 0
check "school: webstack (the bonus) off" "$(printf '%s\n' "$s" | grep -c '^feature=webstack$')" 0
check "school: no dc-* row" "$(printf '%s\n' "$s" | grep -c '^feature=dc-')" 0

v=$(resolve server)
check "server: nvim off" "$(printf '%s\n' "$v" | grep -c '^feature=nvim$')" 0
check "server: nvim-extras off" "$(printf '%s\n' "$v" | grep -c '^feature=nvim-extras$')" 0
check "server: docker on" "$(printf '%s\n' "$v" | grep -c '^feature=docker$')" 1
# The max tier's add-ons are on: server.toml runs max (package = "max") on
# the baas host with ram_mb = 14336. On a 7.6 GB seat they stay off, since max
# crash-looped mssql there and grobase puts it at 3128 MiB idle (2026-10-08).
max_addons="dc-db-cockroach dc-db-mssql dc-observability"
dc_rows=$(awk "/^MANIFEST='/,/^'\$/" generate/feature_profile.sh | grep -c '^dc-')
check "server: every dc-* row on, max add-ons included" \
    "$(printf '%s\n' "$v" | grep -c '^feature=dc-')" "$dc_rows"
for f in $max_addons; do
    check "server: $f on" "$(printf '%s\n' "$v" | grep -c "^feature=$f\$")" 1
done
check "server: var-gc on (base, every build)" "$(printf '%s\n' "$v" | grep -c '^feature=var-gc$')" 1
check "server: the VM is not named debian" "$(env B2B_CONFIG=profiles/server.toml bash utils/b2b_config.sh get B2B_VM_NAME)" baas
check "server: ram_mb 14336" "$(env B2B_CONFIG=profiles/server.toml bash utils/b2b_config.sh get B2B_VM_RAM_MB)" 14336
check "server: an IDE disk of 40 GB" "$(env B2B_CONFIG=profiles/server.toml bash utils/b2b_config.sh get B2B_VM_IDE_DISK_GB)" 40

# The reweight is the point of the server profile: /var must be the largest
# volume by a margin, larger than at the shipped shares.
var_of() { # <config> [GB] -> /var's MB
    env B2B_CONFIG="$1" SIZE_B2B="${2:-44}" bash generate/partition_recipe.sh --sizes | awk -F= '$1 == "var" { print $2 }'
}
check "server: /var grew against the shipped table at 44 GB" \
    "$([ "$(var_of profiles/server.toml)" -gt "$(var_of tests/fixtures/default.toml)" ] && echo grew || echo same)" grew

# baas was built at 80 GB and is grown in place (grow-disk + grow-root), which
# hands /var every GB added. A fresh build at the profile's disk_gb must give
# /var about as much, or a baas rebuilt from a clone has less room than the
# VM it replaces.
# Ponytail: within 5% -- slack for / and /var/log growing with the disk; a
# recipe change that takes less than that from /var passes.
server_gb=$(sed -n 's/^disk_gb *= *\([0-9]*\).*/\1/p' profiles/server.toml | head -n1)
grown=$(($(var_of profiles/server.toml 80) + (server_gb - 80) * 1024))
fresh=$(var_of profiles/server.toml "$server_gb")
check "server: a fresh build's /var within 5% of the grown baas's" \
    "$([ $((fresh * 100)) -ge $((grown * 95)) ] && echo yes || echo "no: $fresh MB, grown $grown MB")" yes

# PROFILE is the install tier; a preset goes in B2B_CONFIG. The mix-up is
# refused when make parses, not three minutes in after the netinst download.
parse_refusal() { make --no-print-directory -n all "$@" 2>&1 | grep -m1 '\*\*\*'; }
check "PROFILE=profiles/server.toml refused at parse time, B2B_CONFIG named" \
    "$(parse_refusal PROFILE=profiles/server.toml | grep -c 'B2B_CONFIG=profiles/server.toml')" 1
check "PROFILE=server names the preset file" \
    "$(parse_refusal PROFILE=server | grep -c 'B2B_CONFIG=profiles/server.toml')" 1
check "PROFILE=nonsense refused without a file to name" \
    "$(parse_refusal PROFILE=nonsense | grep -c 'PROFILE=nonsense is not an install tier')" 1
check "PROFILE=standard still parses" "$(parse_refusal PROFILE=standard | grep -c '\*\*\*')" 0

exit "$fail"
