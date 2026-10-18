#!/usr/bin/env hellish
# install_claude_debug.sh leaves the guest's Claude unattended in grobase's
# checkout without that edit ever reaching grobase.
#
# THE FAILURES IT PINS
#   - Ask rules prompt even in bypassPermissions mode (measured with Claude
#     Code 2.1.292: `rm -f` was refused because grobase's tracked
#     .claude/settings.json asks on rm). b2b-claude-bypass must empty that
#     list and keep every other key of the file.
#   - The edit is to a tracked file, so a session that commits everything
#     would ship bypass mode to every grobase developer: the local
#     pre-commit hook refuses it, and never replaces a hook it did not write.
#   - install_grobase.sh's `git checkout -f` restores the file at every pin
#     bump, so it must rerun the helper after the last checkout.
#   - The login's settings and ~/.claude.json are merged, never replaced:
#     theme, other env vars and other projects survive, and invalid JSON is
#     left as it was rather than overwritten.
#   - opencode's config is read from Claude's, never a second list: the
#     project's servers minus the disabled ones plus the local scope, in V1
#     shape, a checkout-relative script made absolute (V1 has no cwd).
#
# HOW
#   The helper and the two Python merges are cut out of the installer by
#   their heredoc markers and run against a throwaway git repository and
#   home; git runs with no global or system config, so a host
#   core.hooksPath cannot hide the hook.
set -e

cd "$(dirname "$0")/.."
SRC=setup/install/ai/install_claude_debug.sh

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s -- got: %s, expected: %s\n' "$1" "$2" "$3"
        fail=1
    fi
}
heredoc() { awk -v start="$1" -v end="$2" 'index($0, start) { on = 1; next } on && $0 == end { exit } on' "$SRC"; }
json() { python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"d": d}))' "$@"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
heredoc "<<'BYPASSEOF'" BYPASSEOF >"$TMP/bypass"
heredoc "<<'USERPY'" USERPY >"$TMP/user.py"
heredoc "<<'MCPPY'" MCPPY >"$TMP/mcp.py"
heredoc "<<'OPENCODEPY'" OPENCODEPY >"$TMP/opencode.py"
for f in bypass user.py mcp.py opencode.py; do
    check "heredoc $f extracted" "$([ -s "$TMP/$f" ] && echo yes)" yes
done

# ── b2b-claude-bypass ────────────────────────────────────────────────────────
R="$TMP/repo"
mkdir -p "$R/.claude"
git -C "$R" init -q
cat >"$R/.claude/settings.json" <<'JSON'
{
  "permissions": {"allow": ["Bash(make:*)"], "ask": ["Bash(rm:*)", "Bash(docker:*)"], "deny": ["Read(./.env)"]},
  "enableAllProjectMcpServers": true,
  "enabledPlugins": {"devil@univers42": true}
}
JSON
printf '{"model": "opus"}\n' >"$R/.claude/settings.local.json"
git -C "$R" add -A
git -C "$R" -c user.name=t -c user.email=t@t commit -qm init

out=$(sh "$TMP/bypass" "$R")
check "first run reports the removal" "$out" "b2b-claude-bypass: 2 ask rules removed"
check "ask list emptied" "$(json "$R/.claude/settings.json" 'd["permissions"]["ask"]')" "[]"
check "allow kept" "$(json "$R/.claude/settings.json" 'd["permissions"]["allow"]')" "['Bash(make:*)']"
check "deny kept" "$(json "$R/.claude/settings.json" 'd["permissions"]["deny"]')" "['Read(./.env)']"
check "other keys kept" "$(json "$R/.claude/settings.json" 'd["enableAllProjectMcpServers"], d["enabledPlugins"]')" \
    "(True, {'devil@univers42': True})"
check "local deny on .env.local" "$(json "$R/.claude/settings.local.json" 'd["permissions"]["deny"]')" "['Read(**/.env.local)']"
check "local settings kept" "$(json "$R/.claude/settings.local.json" 'd["model"]')" opus
check "headless-dead and replaced servers off" \
    "$(json "$R/.claude/settings.local.json" 'd["disabledMcpjsonServers"]')" "['supermemory', 'playwright']"

cp "$R/.claude/settings.json" "$TMP/after-first"
out=$(sh "$TMP/bypass" "$R")
check "rerun is a no-op" "$out" "b2b-claude-bypass: no ask rules left"
check "rerun leaves the file" "$(cmp -s "$R/.claude/settings.json" "$TMP/after-first" && echo same)" same
check "rerun adds no second deny" "$(json "$R/.claude/settings.local.json" 'len(d["permissions"]["deny"]), len(d["disabledMcpjsonServers"])')" "(1, 2)"

git -C "$R" add .claude/settings.json
check "commit of settings.json refused" \
    "$(git -C "$R" -c user.name=t -c user.email=t@t commit -qm bypass >/dev/null 2>&1 && echo committed || echo refused)" refused
git -C "$R" restore --staged .claude/settings.json
echo x >"$R/other"
git -C "$R" add other
check "other commits pass" \
    "$(git -C "$R" -c user.name=t -c user.email=t@t commit -qm other >/dev/null 2>&1 && echo committed || echo refused)" committed

printf '#!/bin/sh\nexit 0\n' >"$R/.git/hooks/pre-commit"
sh "$TMP/bypass" "$R" >/dev/null
check "a foreign pre-commit hook is left alone" "$(grep -c b2b-claude-bypass "$R/.git/hooks/pre-commit" || true)" 0

mkdir -p "$TMP/empty"
check "no settings.json: exit 0" "$(sh "$TMP/bypass" "$TMP/empty" && echo 0)" 0
check "no settings.json: nothing created" "$(ls -A "$TMP/empty")" ""

# ── the login's settings ─────────────────────────────────────────────────────
U="$TMP/settings.json"
printf '{"theme": "auto", "env": {"FOO": "1"}, "permissions": {"allow": ["Read"]}}\n' >"$U"
python3 - "$U" <"$TMP/user.py"
check "bypass mode" "$(json "$U" 'd["permissions"]["defaultMode"]')" bypassPermissions
check "warning pre-accepted" "$(json "$U" 'd["skipDangerousModePermissionPrompt"]')" True
check "devil autonomy, exact value" "$(json "$U" 'd["env"]["DEVIL_AUTONOMY"]')" 1
check "theme, env and allow kept" "$(json "$U" 'd["theme"], d["env"]["FOO"], d["permissions"]["allow"]')" "('auto', '1', ['Read'])"
check "mode 600" "$(stat -c %a "$U")" 600
printf '{"theme": ' >"$U"
check "invalid JSON refused" "$(python3 - "$U" <"$TMP/user.py" 2>/dev/null && echo written || echo refused)" refused
check "invalid JSON left as it was" "$(cat "$U")" '{"theme": '

# ── the local-scope MCP servers ──────────────────────────────────────────────
C="$TMP/claude.json"
printf '{"userID": "u", "projects": {"/elsewhere": {"mcpServers": {"x": {}}}}}\n' >"$C"
python3 - "$C" /opt/grobase "mcr.example/pw@sha256:abc" "" <"$TMP/mcp.py"
check "other projects kept" "$(json "$C" 'd["userID"], list(d["projects"]["/elsewhere"]["mcpServers"])')" "('u', ['x'])"
check "playwright pinned" "$(json "$C" 'd["projects"]["/opt/grobase"]["mcpServers"]["playwright-docker"]["args"][-1]')" "mcr.example/pw@sha256:abc"
check "no toolbox, no radare2" "$(json "$C" '"radare2" in d["projects"]["/opt/grobase"]["mcpServers"]')" False
python3 - "$C" /opt/grobase "mcr.example/pw@sha256:abc" "b2b-debug-toolbox:0123" <"$TMP/mcp.py"
check "radare2 with the toolbox" "$(json "$C" 'd["projects"]["/opt/grobase"]["mcpServers"]["radare2"]["args"][-2:]')" "['b2b-debug-toolbox:0123', 'r2mcp']"

# ── opencode's config, read from Claude's ────────────────────────────────────
D="$TMP/grobase"
mkdir -p "$D/.claude" "$D/.opencode" "$D/scripts/ops"
: >"$D/scripts/ops/mcp-server.sh"
cat >"$D/.mcp.json" <<'JSON'
{"mcpServers": {
  "context7": {"command": "npx", "args": ["-y", "@upstash/context7-mcp@latest"]},
  "postgres": {"command": "bash", "args": ["scripts/ops/mcp-server.sh", "postgres"]},
  "supermemory": {"command": "npx", "args": ["-y", "mcp-remote@latest", "https://mcp.supermemory.ai/mcp"]}
}}
JSON
printf '{"disabledMcpjsonServers": ["supermemory"]}\n' >"$D/.claude/settings.local.json"
printf '{"projects": {"%s": {"mcpServers": {"radare2": {"type": "stdio", "command": "docker", "args": ["run", "tb", "r2mcp"]}}}}}\n' \
    "$D" >"$TMP/oc-claude.json"
O="$D/.opencode/opencode.json"
printf '{"model": "x/y", "mcp": {"mine": {"type": "local", "command": ["true"]}}, "instructions": ["AGENTS.md", "%s"]}\n' \
    "$D/.claude/rules/*.md" >"$O"
python3 - "$O" "$D" "$TMP/oc-claude.json" <"$TMP/opencode.py" >/dev/null
check "opencode: project servers minus disabled, plus local scope, own kept" \
    "$(json "$O" 'sorted(d["mcp"])')" "['context7', 'mine', 'postgres', 'radare2']"
check "opencode: V1 local shape" "$(json "$O" 'd["mcp"]["context7"]["type"], d["mcp"]["context7"]["command"]')" \
    "('local', ['npx', '-y', '@upstash/context7-mcp@latest'])"
check "opencode: checkout path made absolute" "$(json "$O" 'd["mcp"]["postgres"]["command"]')" \
    "['bash', '$D/scripts/ops/mcp-server.sh', 'postgres']"
check "opencode: allow all, deny .env.local" \
    "$(json "$O" 'd["permission"]["*"], d["permission"]["external_directory"], d["permission"]["doom_loop"], d["permission"]["read"]["*.env.local"]')" \
    "('allow', 'allow', 'allow', 'deny')"
check "opencode: other keys kept" "$(json "$O" 'd["model"]')" x/y
check "opencode: light servers on, heavy ones off" \
    "$(json "$O" 'd["mcp"]["context7"]["enabled"], d["mcp"]["postgres"]["enabled"], d["mcp"]["radare2"]["enabled"]')" \
    "(True, True, False)"
check "opencode: the old rules glob removed, other instructions kept" "$(json "$O" 'd["instructions"]')" "['AGENTS.md']"
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); d["mcp"]["radare2"]["enabled"] = True; json.dump(d, open(sys.argv[1], "w"))' "$O"
python3 - "$O" "$D" "$TMP/oc-claude.json" <"$TMP/opencode.py" >/dev/null
check "opencode: a server switched on stays on across a rerun" "$(json "$O" 'd["mcp"]["radare2"]["enabled"]')" True
printf '{"model": ' >"$O"
check "opencode: invalid JSON refused" \
    "$(python3 - "$O" "$D" "$TMP/oc-claude.json" <"$TMP/opencode.py" 2>/dev/null && echo written || echo refused)" refused

# ── install_grobase.sh reapplies it after the forced checkout ────────────────
G=setup/install/dc/install_grobase.sh
last_checkout=$(grep -n 'checkout -q -f' "$G" | tail -n1 | cut -d: -f1)
bypass_call=$(grep -n '^    /usr/local/sbin/b2b-claude-bypass ' "$G" | cut -d: -f1)
check "install_grobase reruns the helper after its last checkout" \
    "$([ -n "$bypass_call" ] && [ "$bypass_call" -gt "$last_checkout" ] && echo after)" after

exit "$fail"
