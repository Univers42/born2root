#!/usr/bin/env hellish
# The [policy.*] tables of born2root.toml, as preseeds/b2b-setup.sh applies
# them, run on the host with no VM.
#
# What it guards:
#   1. With the shipped values, the sudoers file is byte-identical to the
#      literal heredoc every build before the policies became configurable
#      wrote -- the defaults must not change a guest.
#   2. A configured policy reaches the file, and what b2b-setup.sh writes
#      passes `visudo -c` (when the host has visudo). A sudoers.d file that
#      does not parse locks sudo for every account.
#   3. build.conf carries every policy value, and a message with a character
#      that could break the file is refused on the host, before any download.
#
# write_sudo_policy is lifted out of b2b-setup.sh by name, so renaming it or
# indenting its closing brace breaks the extraction, not the behaviour.
set -e

cd "$(dirname "$0")/.."

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-58s = %s\n' "$1" "$2"
    else
        printf 'FAIL %-58s = %s (expected %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CFG=("${SCRIPT_SH:-bash}" utils/b2b_config.sh)
DEFAULTS=tests/fixtures/default.toml

awk '/^write_sudo_policy\(\) \{/,/^}/' preseeds/b2b-setup.sh >"$TMP/lifted.sh"
check "write_sudo_policy was found in b2b-setup.sh" "$(grep -c '^write_sudo_policy() {' "$TMP/lifted.sh")" 1
sudo_file() { "${SCRIPT_SH:-bash}" -c ". '$TMP/lifted.sh'; write_sudo_policy \"\$@\"" _ "$@"; }

# ── 1. The shipped defaults write what every earlier build wrote ────────────
printf 'Defaults\tpasswd_tries=3
Defaults\tbadpass_message="Wrong password. Access denied!"
Defaults\tlogfile="/var/log/sudo/sudo.log"
Defaults\tlog_input,log_output
Defaults\tiolog_dir="/var/log/sudo"
Defaults\trequiretty
Defaults\tsecure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"
' >"$TMP/before"
sudo_file 3 "Wrong password. Access denied!" /var/log/sudo >"$TMP/default"
check "defaults: byte-identical to the old literal file" \
    "$(cmp -s "$TMP/before" "$TMP/default" && echo same || echo differs)" same

# ── 2. A configured policy reaches the file, and parses ─────────────────────
sudo_file 2 "Nope! Try again, 42 & co." /var/log/sudo-io >"$TMP/custom"
check "tries" "$(grep -c '^Defaults	passwd_tries=2$' "$TMP/custom")" 1
check "message, with ! & , . kept" "$(grep -c '^Defaults	badpass_message="Nope! Try again, 42 & co."$' "$TMP/custom")" 1
check "log dir for the log and the io log" "$(grep -c '"/var/log/sudo-io' "$TMP/custom")" 2
if [ -x /usr/sbin/visudo ]; then
    check "the default file passes visudo" "$(/usr/sbin/visudo -cf "$TMP/default" >/dev/null 2>&1 && echo ok || echo refused)" ok
    check "the custom file passes visudo" "$(/usr/sbin/visudo -cf "$TMP/custom" >/dev/null 2>&1 && echo ok || echo refused)" ok
else
    printf 'skip visudo is not installed on this host\n'
fi

# ── 3. build.conf carries the policy; unsafe values never get that far ──────
sed -e 's/^min_length  = 10/min_length  = 12/' -e 's/^interval_min = 10/interval_min = 5/' \
    -e 's/^tries           = 3/tries           = 2/' -e 's/^password_login = true/password_login = true/' \
    "$DEFAULTS" >"$TMP/strict.toml"
GUEST=$(env B2B_CONFIG="$TMP/strict.toml" "${CFG[@]}" --guest)
printf '%s\n' "$GUEST" >"$TMP/build.conf"
check "build.conf is sourceable and carries the policy" \
    "$("${SCRIPT_SH:-bash}" -c ". '$TMP/build.conf'; printf '%s/%s/%s/%s' \"\$B2B_PASS_MIN_LENGTH\" \"\$B2B_MONITOR_INTERVAL\" \"\$B2B_SUDO_TRIES\" \"\$B2B_SUDO_BADPASS\"")" \
    "12/5/2/Wrong password. Access denied!"
check "a stricter policy is accepted" "$(env B2B_CONFIG="$TMP/strict.toml" "${CFG[@]}" --check >/dev/null 2>&1 && echo ok || echo refused)" ok
# shellcheck disable=SC2016 # the $ and backticks are the unsafe characters under test
for bad in 'Say \"no\"' "It's wrong" 'Costs $5' 'back`tick`'; do
    sed "s|^badpass_message = .*|badpass_message = '$bad'|" "$DEFAULTS" >"$TMP/bad.toml"
    # a TOML literal string cannot hold ', so that one is written as a basic string
    case "$bad" in *"'"*) sed -i "s|^badpass_message = .*|badpass_message = \"$bad\"|" "$TMP/bad.toml" ;; esac
    check "a sudo message holding: $bad -> refused" \
        "$(env B2B_CONFIG="$TMP/bad.toml" "${CFG[@]}" --check 2>&1 | grep -c 'policy.sudo.badpass_message')" 1
done
sed 's/^max_days    = 30/max_days    = 60/' "$DEFAULTS" >"$TMP/weak.toml"
check "a weaker ageing is refused naming the rule" \
    "$(env B2B_CONFIG="$TMP/weak.toml" "${CFG[@]}" --check 2>&1 | grep -c 'every 30 days at most')" 1

exit "$fail"
