#!/usr/bin/env hellish
# Playwright in the devtools layer: the parts a guest cannot be asked about at
# first boot, lifted out of setup/install/tools/install_devtools.sh and checked
# here with npm/node/curl stubbed. No VM, no network, no 660 MB download.
#
# The bugs this pins, all measured on the 2026-09-27 guest:
#
# 1. The feature is GATED, not free. 700 MB of browser is its own manifest row
#    (`playwright`, `full` tier), so the provisioner has to ask
#    /etc/b2b/features.conf rather than install it because it was asked to. The
#    other direction is the dangerous one: a build that said no must not grow
#    by three quarters of a gigabyte because a hand-run added a default.
#
# 2. The environment the agents get. A GLOBAL npm install is not on the module
#    path, so `require('playwright')` failed with MODULE_NOT_FOUND with the
#    library sitting in /opt/npm-global. And PLAYWRIGHT_BROWSERS_PATH has to
#    travel in the MCP server's own environment: the browsers are in
#    /usr/lib/ms-playwright, and a server that looks in ~/.cache reports
#    "browser not installed" beside 658 MB of browser.
#
# 3. The profile file is written with a VALUE, not an expression. Its heredoc
#    is unquoted (two of the three lines must expand), so a literal
#    ${NODE_PATH:-} in it is expanded by the root installer that writes it --
#    whose NODE_PATH is empty. That shipped `export NODE_PATH=` on the first
#    run and broke the second, with nothing in the log but a working install.
#
# 4. opencode's schema is mcp.servers, not mcp. An entry under the wrong key
#    is valid JSON and completely invisible: `opencode mcp list` answers "No
#    MCP servers configured".
#
# 5. Registering a server must not depend on an agent CLI's own verification.
#    `claude mcp add` launches the server to check it, and through runuser with
#    a pty that wait never ends -- 120 s a call, with the launched server left
#    holding the terminal, so `make devtools` returned nothing and hung after
#    the script had exited. The configs are merged directly, and the check is
#    our own bounded handshake (playwright-mcp-check.js).
set -e

cd "$(dirname "$0")/.."
REPO=$(pwd)
SCRIPT=setup/install/tools/install_devtools.sh

[ -f "$SCRIPT" ] || {
    echo "FAIL $SCRIPT not found"
    exit 1
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-56s = %s\n' "$1" "$3"
    else
        printf 'FAIL %-56s = %s (expected %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}

# ── the functions under test, lifted out ──────────────────────────────────
# write_playwright_profile is the one that can be run for real: it writes a
# file and reads npm. feature_on needs the helpers around it, so the whole
# top-of-file block is eval'd with npm/curl stubbed out of PATH.
log() { :; }
warn() { printf 'WARN %s\n' "$*" >&2; }
die() {
    printf 'DIE %s\n' "$*" >&2
    exit 1
}

mkdir -p "$TMP/bin"
# The stub answers from STUB_PREFIX, and the prefix is a real directory: the
# second half of the function is `[ -d "$prefix/bin" ]`, so a prefix with no bin
# directory answers empty on purpose -- that is how the caller learns npm is
# unusable instead of pointing a browser at a path that is not there.
STUB_PREFIX="$TMP/npm-global"
mkdir -p "$STUB_PREFIX/bin"
# Exported, or the stub is a child process that never sees the name and answers
# with an empty line -- which the case in npm_bin_dir reads as "not a prefix".
export STUB_PREFIX
cat >"$TMP/bin/npm" <<'STUB'
#!/bin/sh
case "$*" in
"config get prefix --global") printf '%s\n' "$STUB_PREFIX" ;;
"root -g") printf '%s\n' "${STUB_PREFIX}/lib/node_modules" ;;
*) exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/npm"
export PATH="$TMP/bin:$PATH"

# The knobs and the feature gate, straight from the file. The first range is
# the Playwright block only (INSTALL_PLAYWRIGHT .. PLAYWRIGHT_VERIFY_JS): it is
# followed by the DEVTOOLS_USERS resolution, which dies on a host that has no
# /etc/b2b/build.conf -- and this test is not a guest.
eval "$(awk '/^INSTALL_PLAYWRIGHT=/,/^PLAYWRIGHT_VERIFY_JS=/' "$SCRIPT")"
eval "$(awk '/^B2B_FEATURES_CONF=/,/^fi$/' "$SCRIPT")"
eval "$(awk '/^npm_bin_dir\(\) \{/,/^}/' "$SCRIPT")"
eval "$(awk '/^write_playwright_profile\(\) \{/,/^}/' "$SCRIPT")"

check "the browsers live on /, not in a home or on /opt" \
    "$PLAYWRIGHT_BROWSERS_PATH" "/usr/lib/ms-playwright"
check "npm's bin directory is found, not hardcoded" \
    "$(npm_bin_dir)" "${STUB_PREFIX}/bin"
# A prefix with no bin/ answers empty rather than a path that is not there.
rmdir "$STUB_PREFIX/bin"
check "an npm prefix with no bin directory answers empty" "$(npm_bin_dir)" ""
mkdir -p "$STUB_PREFIX/bin"
check "the host Chrome is the CDP endpoint" \
    "$PLAYWRIGHT_CDP_ENDPOINT" "http://127.0.0.1:9222"
check "a dead tunnel fails in 15 s, not upstream's 30" \
    "$PLAYWRIGHT_CDP_TIMEOUT" "15000"

# ── 1. the gate ───────────────────────────────────────────────────────────
conf_on="$TMP/on.conf"
conf_off="$TMP/off.conf"
printf 'B2B_FEATURE_nvim=on\nB2B_FEATURE_playwright=on\n' >"$conf_on"
printf 'B2B_FEATURE_nvim=on\nB2B_FEATURE_playwright=off\n' >"$conf_off"
B2B_FEATURES_CONF="$conf_on" feature_on playwright && r=on || r=off
check "features.conf says on -> install" "$r" "on"
B2B_FEATURES_CONF="$conf_off" feature_on playwright && r=on || r=off
check "features.conf says off -> do not" "$r" "off"
# No features.conf at all (a guest built before the row, or a hand-run):
# Playwright is what the operator asked for by running the script, and
# INSTALL_PLAYWRIGHT=0 is right there.
B2B_FEATURES_CONF="$TMP/missing.conf" feature_on playwright && r=on || r=off
check "no features.conf -> install (INSTALL_PLAYWRIGHT=0 overrides)" "$r" "on"
# And the manifest really does have the row, at a tier that keeps 15 GB fitting:
# `full` because 700 MB beside the standard set pushes the smallest build this
# project offers from SIZE_B2B=15 to 17.
check "the manifest row is in the table, in the full tier" \
    "$(awk '$1 == "playwright" { print $1, $2 }' "$REPO/generate/feature_profile.sh")" \
    "playwright full"
# …and feature_packages.sh knows the name too, or --check fails the build.
# …and feature_packages.sh knows the name too, or --check fails the build.
rc=0
bash "$REPO/generate/feature_packages.sh" --check >/dev/null 2>&1 || rc=$?
check "feature_packages.sh agrees with the manifest" "$rc" "0"

# A function out of the file, stopping at the `^}` that really closes it. Both
# functions here embed a heredoc whose body contains a `}` in column 0 (a python
# dict, a JS `if (!bin) {`), so the plain /^name() {/,/^}/ cut ends inside the
# program and hands the shell a half-written function.
lift() { # lift <name> <heredoc marker>
    awk -v f="$1" -v m="$2" '
        index($0, f "() {") == 1 { on = 1 }
        on { print }
        on && $0 == m { seen = 1 }
        on && seen && /^}/ { exit }
    ' "$SCRIPT"
}

# ── 2 + 3. the profile file ───────────────────────────────────────────────
# PLAYWRIGHT_PROFILE_D points the real function at a temp directory, so the
# file it writes is the file this test reads -- and the test is not root.
export PLAYWRIGHT_PROFILE_D="$TMP/profile.d"
write_playwright_profile
prof="${PLAYWRIGHT_PROFILE_D}/b2b-playwright.sh"
if [ -r "$prof" ]; then
    check "PLAYWRIGHT_BROWSERS_PATH is in the profile" \
        "$(grep -c '^export PLAYWRIGHT_BROWSERS_PATH="/usr/lib/ms-playwright"$' "$prof")" "1"
    check "NODE_PATH is a VALUE, not an unexpanded expression" \
        "$(grep -c "^export NODE_PATH=\"${STUB_PREFIX}/lib/node_modules\"$" "$prof")" "1"
    # The bug: 'export NODE_PATH=' with nothing after it.
    check "NODE_PATH is not empty" \
        "$(grep -cE '^export NODE_PATH="?"?$' "$prof")" "0"
    # …and the only line meant to expand when a shell reads it is the PATH one.
    # shellcheck disable=SC2016 # ${PATH} is a literal to match
    check "the PATH line is the only one left to expand" \
        "$(grep -c 'export PATH="\${PATH}:' "$prof")" "1"
    check "the profile is world-readable" "$(stat -c %a "$prof")" "644"
    rm -f "$prof"
else
    check "the profile was written" "absent" "present"
fi

# ── 4 + 5. the merge both agents get ──────────────────────────────────────
# The python body is run for real, on two fixtures: an agent's own config with
# a provider in it, and Claude Code's 45-key state file. Both must come out with
# the two servers under the right key and every other key untouched.
merge=$(lift merge_agent_mcp PYEOF)
[ -n "$merge" ] || {
    echo "FAIL merge_agent_mcp not found"
    exit 1
}

home="$TMP/home"
mkdir -p "$home/.config/opencode"
cat >"$home/.config/opencode/opencode.json" <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "ollama/qwen3:4b",
  "provider": { "ollama": { "name": "Ollama (local, born2root)" } }
}
JSON
cat >"$home/.claude.json" <<'JSON'
{ "numStartups": 7, "theme": "auto", "mcpServers": { "keepme": { "command": "x" } } }
JSON

# eval defines it; the call is a normal call with real arguments (eval with
# trailing words appends them to the string and the closing brace lands in the
# middle of the command line).
eval "$merge"
run_merge() {
    PLAYWRIGHT_BROWSERS_PATH="$fake_browsers" \
        PLAYWRIGHT_CDP_ENDPOINT=http://127.0.0.1:9222 \
        PLAYWRIGHT_CDP_TIMEOUT=15000 \
        merge_agent_mcp dlesieur "$home" "$1" >/dev/null
}

# resolve_chromium is what finds the browser, so a fake tree exercises it: two
# builds on disk (an interrupted upgrade leaves both) and the newer one wins.
fake_browsers="$TMP/browsers"
mkdir -p "$fake_browsers/chromium-999/chrome-linux" "$fake_browsers/chromium-1243/chrome-linux64"
: >"$fake_browsers/chromium-999/chrome-linux/chrome"
: >"$fake_browsers/chromium-1243/chrome-linux64/chrome"
chmod +x "$fake_browsers/chromium-999/chrome-linux/chrome" \
    "$fake_browsers/chromium-1243/chrome-linux64/chrome"
eval "$(lift resolve_chromium '')"
check "the newest chromium build is the one named" \
    "$(PLAYWRIGHT_BROWSERS_PATH="$fake_browsers" resolve_chromium)" \
    "$fake_browsers/chromium-1243/chrome-linux64/chrome"
check "no browser at all is an honest failure" \
    "$(PLAYWRIGHT_BROWSERS_PATH="$TMP/nothing" resolve_chromium || echo none)" "none"
run_merge opencode && r=ok || r=refused
check "the opencode config merges" "$r" "ok"
run_merge claude && r=ok || r=refused
check "the Claude Code state file merges" "$r" "ok"

py() { # py <program> [args...] -- the program reads sys.argv[1:] as its own args
    local prog="$1"
    shift
    python3 -c "$prog" "$@"
}
py '
import json, os, sys
home = sys.argv[1]
oc = json.load(open(os.path.join(home, ".config", "opencode", "opencode.json")))
s = oc.get("mcp", {}).get("servers", {})
print("SERVERS=%d KEYS=%s" % (len(s.get("playwright", {}) and s), ",".join(sorted(s))))
print("PROVIDER_KEPT=%s" % ("Ollama (local, born2root)" in json.dumps(oc)))
print("CMD=%s" % s.get("playwright", {}).get("command", ""))
print("HOST_ARGS=%s" % ",".join(s.get("playwright-host", {}).get("args", [])))
print("ENV=%s" % s.get("playwright", {}).get("env", {}).get("PLAYWRIGHT_BROWSERS_PATH", ""))
print("OWN_ARGS=%s" % ",".join(s.get("playwright", {}).get("args", [])))
' "$home" >"$TMP/oc.txt"
check "opencode: the two servers, under mcp.servers" \
    "$(grep '^SERVERS=' "$TMP/oc.txt")" "SERVERS=2 KEYS=playwright,playwright-host"
check "opencode: the provider install_ai.sh wrote survives" \
    "$(grep '^PROVIDER_KEPT=' "$TMP/oc.txt")" "PROVIDER_KEPT=True"
check "opencode: an absolute command, so PATH cannot lose it" \
    "$(grep '^CMD=' "$TMP/oc.txt")" "CMD=${STUB_PREFIX}/bin/playwright-mcp"
check "opencode: the host one carries the CDP endpoint and a bounded timeout" \
    "$(grep '^HOST_ARGS=' "$TMP/oc.txt")" \
    "HOST_ARGS=--cdp-endpoint,http://127.0.0.1:9222,--cdp-timeout,15000"
check "opencode: PLAYWRIGHT_BROWSERS_PATH in the server environment" \
    "$(grep '^ENV=' "$TMP/oc.txt")" "ENV=${fake_browsers}"
# The one that was broken and cost a whole run: with no browser named, the
# server answers every handshake and then cannot start one -- it looks for a
# system Chrome, or for a build newer than the library installed.
check "opencode: the own-browser server NAMES the installed chromium" \
    "$(grep '^OWN_ARGS=' "$TMP/oc.txt")" \
    "OWN_ARGS=--executable-path,${fake_browsers}/chromium-1243/chrome-linux64/chrome"
check "opencode: the host server does not (CDP names its browser)" \
    "$(grep -c 'HOST_ARGS=--executable-path' "$TMP/oc.txt")" "0"

py '
import json, os, sys
home = sys.argv[1]
cc = json.load(open(os.path.join(home, ".claude.json")))
s = cc.get("mcpServers", {})
print("N=%d KEYS=%s" % (len(s), ",".join(sorted(s))))
print("STARTUPS=%s THEME=%s" % (cc.get("numStartups"), cc.get("theme")))
print("TYPE=%s ENV=%s" % (s.get("playwright", {}).get("type"), s.get("playwright", {}).get("env", {}).get("PLAYWRIGHT_BROWSERS_PATH", "")))
' "$home" >"$TMP/cc.txt"
# 3 servers: the one that was there, plus the two we add. The state file has
# 45 keys and must still have all of them.
check "Claude Code: keepme plus the two new ones" \
    "$(grep '^N=' "$TMP/cc.txt")" "N=3 KEYS=keepme,playwright,playwright-host"
check "Claude Code: the rest of the state file is untouched" \
    "$(grep '^STARTUPS=' "$TMP/cc.txt")" "STARTUPS=7 THEME=auto"
check "Claude Code: stdio with the browser path in env" \
    "$(grep '^TYPE=' "$TMP/cc.txt")" "TYPE=stdio ENV=${fake_browsers}"

# The bounded handshake the installer uses instead of an agent CLI: a file it
# writes, and the two places that run it.
check "the handshake check is written as a file" \
    "$(lift write_playwright_verify JSEOF | grep -c '^JSEOF$')" "1"
# Three call sites: the host server, the own-browser server with the resolved
# executable, and the same without one when no browser was found.
# shellcheck disable=SC2016 # ${PLAYWRIGHT_VERIFY_JS} is a literal to match
check "every server is verified with the same script" \
    "$(grep -c 'node "\${PLAYWRIGHT_VERIFY_JS}"' "$SCRIPT")" "3"
check "run_as_agent closes stdin and writes to a file" \
    "$(awk '/^run_as_agent\(\) \{/,/^}/' "$SCRIPT" | grep -c '</dev/null')" "1"
# shellcheck disable=SC2016 # $out is a literal to match
check "run_as_agent puts its output in a file, not the pty" \
    "$(awk '/^run_as_agent\(\) \{/,/^}/' "$SCRIPT" | grep -c '>"\$out" 2>&1')" "1"
# opencode's own CLI writes the right schema in a second and IS used (mcp.servers
# is not guessable); Claude Code's is not, because its verification launches the
# server and that wait does not end through a pty.
check "no agent CLI is asked to register anything" \
    "$(grep -v '^[[:space:]]*#' "$SCRIPT" | grep -c 'claude mcp')" "0"

# The verification has to RENDER something. A handshake and a tools/list are
# both answered by a server that cannot start a browser at all, and that is
# exactly the state the `playwright` server was in while reporting 25 tools.
# Comment lines are stripped first: these strings are named in the prose too,
# and a count that includes the prose stops meaning anything.
code_only() { lift "$1" "$2" | grep -v '^[[:space:]]*//'; }
check "the check refuses to pass without browser_navigate" \
    "$(code_only write_playwright_verify JSEOF | grep -c "names.includes('browser_navigate')")" "1"
check "the check makes a real browser_navigate call" \
    "$(code_only write_playwright_verify JSEOF | grep -c "name: 'browser_navigate'")" "1"
check "and it only reports ok when the page rendered" \
    "$(code_only write_playwright_verify JSEOF | grep -c 'NAV=ok')" "1"
check "the caller greps for NAV, not for TOOLS" \
    "$(awk '/^verify_playwright_mcp\(\) \{/,/^}/' "$SCRIPT" | grep -v '^[[:space:]]*#' |
        grep -c 'NAV=ok')" "1"

if [ "$fail" = "0" ]; then
    echo "all ok"
else
    echo "FAILED"
    exit 1
fi
