#!/usr/bin/env hellish
# profiles/*.toml are presets selected with B2B_CONFIG=. Two things can rot
# silently: a preset can stop validating (a feature renamed, a key added),
# and a preset's feature set can stop fitting its own disk. Either is found
# here, on the host, in a second -- not 25 minutes into an install.
#
# What each profile promises:
#   school.toml   the Born2beRoot subject at 15 GB: nvim on, docker and the
#                 bonus off, and it fits.
#   server.toml   backend only at 44 GB: no nvim, docker on, dc-full on, and
#                 it fits with /var holding the engines.
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
check "server: every dc-* row on" "$(printf '%s\n' "$v" | grep -c '^feature=dc-')" 18
check "server: the VM is not named debian" "$(env B2B_CONFIG=profiles/server.toml bash utils/b2b_config.sh get B2B_VM_NAME)" baas

# The reweight is the point of the server profile: /var must be the largest
# volume by a margin, larger than at the shipped shares.
var_of() { env B2B_CONFIG="$1" SIZE_B2B=44 bash generate/partition_recipe.sh --sizes | awk -F= '$1 == "var" { print $2 }'; }
check "server: /var grew against the shipped table at 44 GB" \
    "$([ "$(var_of profiles/server.toml)" -gt "$(var_of tests/fixtures/default.toml)" ] && echo grew || echo same)" grew

exit "$fail"
