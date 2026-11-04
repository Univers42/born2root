#!/usr/bin/env hellish
# Pins install_grobase.sh's readiness, with curl and b2b-stack-health stubbed.
#
# The bug it pins down: readiness was grobase's `make health`, whose TCP audit
# reads host:port out of environment text. A Mongo password opening with a digit
# (10 in 62) made MONGO_URI an edge to `mongo:4`, five healthy services
# "UNREACHABLE", and the whole of dc-full failed, while `make all` printed
# "every feature installed". Nothing here may depend on that parser.
set -u
cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." || exit 1
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
mkdir -p "$T/bin"
cat >"$T/bin/curl" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >"$T/curl.args"
cat "$T/code"
STUB
chmod +x "$T/bin/curl"
printf 'ANON_KEY="anon-value"\nOTHER=1\n' >"$T/.env"

awk '/^gateway_answers\(\) \{/{p=1} p{print} p && /^\}/{exit}' setup/install/dc/install_grobase.sh >"$T/fn.sh"
printf '. "%s/fn.sh"\ngateway_answers\n' "$T" >"$T/run.sh"
probe() { # <shell>
    (cd "$T" && env PATH="$T/bin:$PATH" "$1" "$T/run.sh") >/dev/null 2>&1
}
# Both shells, because both run it: first boot under hellish, `make grobase` under
# bash. The first version passed here under bash alone, and hellish never ran curl.
shells="bash"
hellish_bin=$(command -v hellish || true)
if [ -n "$hellish_bin" ]; then
    shells="bash $hellish_bin"
else
    printf 'skip no hellish on this machine: only bash is checked\n'
fi
while read -r shell_bin; do
    name=${shell_bin##*/}
    rm -f "$T/curl.args"
    printf 200 >"$T/code"
    probe "$shell_bin"
    check "$name: 200 through Kong: ready" "$?" 0
    check "$name: ... curl really ran, with the anon key" "$(grep -c 'apikey: anon-value ' "$T/curl.args" 2>/dev/null)" 1
    printf 401 >"$T/code"
    probe "$shell_bin"
    check "$name: 401: Kong is up, the key or gotrue is not" "$?" 1
    printf 000 >"$T/code"
    probe "$shell_bin"
    check "$name: no answer: not ready" "$?" 1
done <<SHELLS
$(printf '%s\n' "$shells" | tr ' ' '\n')
SHELLS

script=setup/install/dc/install_grobase.sh
check "readiness no longer runs grobase's make health" "$(grep -cE '^[^#]*make [^#]*\bhealth\b' "$script")" 0
check "the verdict reads the containers" "$(grep -c '/usr/local/sbin/b2b-stack-health 300' "$script")" 1
check "... and an unhealthy stack clears ready" "$(awk '/b2b-stack-health 300/{p=1} p&&/ready=0/{print "yes"; exit}' "$script")" yes
# shellcheck disable=SC2016 # the literal last line of the script
check "the exit status is still that verdict" "$(tail -n1 "$script")" '[ "$ready" = 1 ]'
exit "$fail"
