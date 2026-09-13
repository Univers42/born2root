#!/usr/bin/env hellish
# Regression test for utils/b2b_apt.py: [packages] apt in born2root.toml,
# resolved against a hand-written Debian index -- no network.
#
# What it guards: a package list is checked on the host before the ISO is
# downloaded, because the alternative is a first boot failing 25 minutes into
# `make all`. So a typo names its close match, a virtual package with several
# providers lists them, one with a single provider becomes that provider, and
# the size charged to the fit check is the dependency closure (Depends and
# Pre-Depends, first satisfiable alternative) minus what the guest has anyway,
# with Installed-Size read as KiB -- the unit mistake that would make every
# estimate 1024 times too big. It also pins that feature_profile.sh charges
# that size as a base row a set cannot drop.
set -e

cd "$(dirname "$0")/.."

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-60s = %s\n' "$1" "$2"
    else
        printf 'FAIL %-60s = %s (expected %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# The mirror is a name that cannot resolve: any attempt to fetch would fail.
export B2B_APT_INDEX=tests/fixtures/apt/Packages B2B_APT_MIRROR=nowhere.invalid B2B_APT_CACHE="$TMP/cache"
apt_py() { python3 utils/b2b_apt.py "$@"; }
field_of() { apt_py resolve "${@:2}" 2>/dev/null | awk -v k="$1" '$1 == k { print $2 }' | tr '\n' ' ' | sed 's/ $//'; }

# ── Sizes: closure minus the base, KiB and bytes to MB, rounded up ──────────
check "postgresql: four packages with its dependencies" "$(field_of closure postgresql)" 4
check "postgresql: 61770 KiB installed -> 61 MB on /" "$(field_of root_mb postgresql)" 61
check "postgresql: 19305000 bytes downloaded -> 19 MB on /var" "$(field_of var_mb postgresql)" 19
check "cowsay: perl is in the base, the first alternative is taken" "$(field_of closure cowsay)" 2
check "cowsay: 130 KiB still costs 1 MB" "$(field_of root_mb cowsay)" 1
check "htop is installed by b2b-setup.sh already: nothing to add" "$(field_of closure htop)" 0
check "htop is still listed as a target" "$(field_of package htop)" htop
check "a virtual name with one provider installs that provider" "$(field_of package pinentry)" pinentry-curses
check "two lists add up without counting a shared dependency twice" \
    "$(field_of closure postgresql cowsay)" 6

# ── Refusals name the fix ───────────────────────────────────────────────────
out=$(apt_py resolve htpo 2>&1) && rc=0 || rc=$?
check "a typo: refused" "$rc" 1
check "a typo: names the close match" "$(printf '%s' "$out" | grep -c "did you mean htop")" 1
out=$(apt_py resolve mail-transport-agent 2>&1) && rc=0 || rc=$?
check "a virtual name with two providers: refused" "$rc" 1
check "a virtual name with two providers: lists both" \
    "$(printf '%s' "$out" | grep -c 'name one: exim4-daemon-light, postfix')" 1
out=$(apt_py resolve 'Foo_Bar' cowsay 2>&1) && rc=0 || rc=$?
check "not a package name: refused" "$(printf '%s' "$out" | grep -c "'Foo_Bar' is not a Debian package name")" 1
out=$(apt_py resolve htpo awk 2>&1) && rc=0 || rc=$?
check "every problem is reported, not only the first" "$(printf '%s\n' "$out" | grep -c '^packages.apt:')" 2

# ── The last answer is reused without the network ───────────────────────────
apt_py resolve postgresql cowsay >/dev/null
check "cached: same list, another order" "$(apt_py cached cowsay postgresql | tr '\n' ' ')" "root_mb 61 var_mb 19 "
check "cached: another list answers nothing" "$(apt_py cached cowsay | grep -c . || true)" 0

# ── feature_profile.sh charges it, as a base row ────────────────────────────
FP=("${SCRIPT_SH:-bash}" generate/feature_profile.sh)
export B2B_CONFIG=tests/fixtures/default.toml B2B_SELECT_FILE=/nonexistent
row=$(env B2B_APT_PACKAGES=postgresql B2B_APT_ROOT_MB=61 B2B_APT_VAR_MB=19 SIZE_B2B=15 "${FP[@]}" --table 2>/dev/null |
    awk '$1 == "apt-packages" { print $2, $3, $4, $6 }')
check "the table has an apt-packages base row, / and /var" "$row" "base on 61 19"
check "no list, no row" "$(SIZE_B2B=15 "${FP[@]}" --table 2>/dev/null | grep -c '^ *apt-packages' || true)" 0
check "a list too big for / refuses the build" \
    "$(env B2B_APT_PACKAGES=big B2B_APT_ROOT_MB=900 SIZE_B2B=15 "${FP[@]}" --check >/dev/null 2>&1 && echo fits || echo refused)" refused
check "it cannot be turned off with FEATURES" \
    "$(env B2B_APT_PACKAGES=x B2B_APT_ROOT_MB=1 FEATURES=-apt-packages "${FP[@]}" --resolve 2>&1 | grep -c 'base feature')" 1

exit "$fail"
