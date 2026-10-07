#!/usr/bin/env hellish
#
# install_claude_debug.sh — the guest's Claude Code debugs grobase
# unattended, with reverse-engineering and tracing tools to do it
# (make claude_debug). Run as root; it configures the login's account.
#
# WHAT "UNATTENDED" TAKES (measured 2026-10-07, Claude Code 2.1.292)
#   Three things prompt, and each has its own switch:
#   - The permission mode. bypassPermissions is honoured only from the
#     user's ~/.claude/settings.json; a project's settings files are ignored
#     for it (code.claude.com/docs/en/permission-modes).
#     skipDangerousModePermissionPrompt pre-accepts its one-time warning.
#   - Ask rules, which prompt in every mode: with bypass on, `date` ran and
#     `rm -f` was refused, because grobase's tracked .claude/settings.json
#     asks on rm (and on docker, npm, npx, curl, kill: 42 rules). The
#     b2b-claude-bypass helper empties that list in this guest's checkout,
#     and install_grobase.sh reruns it after each `git checkout -f`, which
#     restores the file.
#   - The devil plugin's hook asks. DEVIL_AUTONOMY=1 turns them into no
#     decision (its hooks/HOOKS-README.md); its refusals stay.
#   Deny rules still hold in bypass mode, so one is added: Read of any
#   .env.local, which in /opt/grobase holds GitHub and Docker Hub tokens.
#   Caveat: it stops the Read tool only; `cat` through Bash still reads the
#   file. The real fix is the tokens not living in that checkout.
#
# WHY THE EDIT CANNOT BE COMMITTED
#   The checkout's settings.json now differs from grobase's, and a session
#   that commits everything would ship bypass mode to every grobase
#   developer. A local pre-commit hook (.git/hooks, never pushed) refuses a
#   commit that includes the file. git's skip-worktree would hide the edit,
#   but then `checkout -f` fails on any ref that changes the file ("not
#   uptodate. Cannot merge", tested), which is every pin bump.
#
# THE TOOLS, AND WHERE THEY LIVE
#   On / (1842 MB free on the 50 GB server layout): gdb, strace, ltrace,
#   binutils, elfutils, patchelf, xxd, tcpdump, nmap, socat, sysstat,
#   hexyl, binwalk, linux-perf and the postgres/redis/sqlite clients
#   (105 MB), and nodejs + npm (210 MB): grobase's .mcp.json starts four of
#   its six MCP servers with npx, and with no node none of them could start.
#   In a Docker image on /var, b2b-debug: the same tools plus tshark,
#   bpftrace, radare2 and r2mcp. bpftrace (268 MB) and tshark (144 MB) do
#   not fit beside the rest on /, and radare2 has no trixie package. It runs
#   privileged in a container's pid and network namespaces, because the
#   login has no passwordless sudo (the subject's sudo policy) and its
#   docker group already grants what root-level tracing needs.
#
# USAGE
#   make claude_debug                          everything, idempotent
#   make claude_debug CLAUDE_DEBUG_TOOLBOX=0   skip building the image
set -u

BUILD=/etc/b2b/build.conf
GROBASE_DIR="${CLAUDE_DEBUG_GROBASE_DIR:-/opt/grobase}"
TOOLBOX="${CLAUDE_DEBUG_TOOLBOX:-1}"
TOOLBOX_DIR=/var/lib/b2b/debug-toolbox
PLAYWRIGHT_MCP_IMAGE="mcr.microsoft.com/playwright/mcp:v0.0.82@sha256:77dccc5ce9e94cb8ae7ebea87ddbb6cd54b05760c4d63c54e16accf2726b8734"
APT_TOOLS=(gdb strace ltrace binutils elfutils patchelf xxd tcpdump nmap socat
    postgresql-client redis-tools sqlite3 sysstat hexyl binwalk linux-perf nodejs npm)

log() { printf '[claude-debug] %s\n' "$*"; }
die() {
    log "FAIL: $*"
    exit 1
}

[ "$(id -u)" = 0 ] || die "run as root (make claude_debug does)"
LOGIN="${CLAUDE_DEBUG_USER:-}"
if [ -z "$LOGIN" ] && [ -f "$BUILD" ]; then
    LOGIN=$(sed -n 's/^B2B_LOGIN=//p' "$BUILD" | head -n1 | tr -d '"')
fi
[ -n "$LOGIN" ] || die "no login: set CLAUDE_DEBUG_USER or provide $BUILD"
HOME_DIR=$(getent passwd "$LOGIN" | cut -d: -f6)
[ -d "$HOME_DIR" ] || die "no home directory for $LOGIN"
GROUP=$(id -gn "$LOGIN")
case "$TOOLBOX" in 0 | 1) ;; *) die "CLAUDE_DEBUG_TOOLBOX=$TOOLBOX is not 0 or 1" ;; esac

# ── 1. the host's tools ──────────────────────────────────────────────────────
missing=()
for pkg in "${APT_TOOLS[@]}"; do
    dpkg-query -W -f '${Status}' "$pkg" 2>/dev/null | grep -q 'ok installed' || missing+=("$pkg")
done
if [ "${#missing[@]}" -gt 0 ]; then
    free_mb=$(df -Pm / | awk 'NR == 2 { print $4 }')
    if [ "${free_mb:-0}" -lt 700 ]; then
        die "/ has ${free_mb} MB free; the tools take 315 MB and / keeps 400 MB of headroom"
    fi
    apt-get update -qq || die "apt-get update failed"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${missing[@]}" >/dev/null ||
        die "apt-get install ${missing[*]} failed"
fi
log "host tools: ${APT_TOOLS[*]}"

# ── 2. the toolbox image and its wrapper ─────────────────────────────────────
if [ "$TOOLBOX" = 1 ]; then
    install -d -m 0755 "$TOOLBOX_DIR"
    cat >"$TOOLBOX_DIR/Dockerfile" <<'DOCKERFILE'
FROM debian:trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        gdb strace ltrace binutils elfutils patchelf xxd file procps psmisc lsof \
        iproute2 iputils-ping tcpdump tshark nmap socat netcat-openbsd bind9-dnsutils \
        bpftrace linux-perf sysstat binwalk hexyl python3 jq less curl ca-certificates \
    && cd /tmp \
    && curl -fsSLO https://github.com/radareorg/radare2/releases/download/6.2.4/radare2_6.2.4_amd64.deb \
    && curl -fsSLO https://github.com/radareorg/radare2-mcp/releases/download/1.8.8/r2mcp_1.8.8_amd64.deb \
    && printf '%s  %s\n' \
        7019eedc0e0e87d1f53d6b8f5fc62b898567679c5efdce7fbfc557c9e7655e90 radare2_6.2.4_amd64.deb \
        1de404fd88881fd2a543c6c4e552a688f2120966c809da4bbfec9594ec669000 r2mcp_1.8.8_amd64.deb \
        | sha256sum -c - \
    && apt-get install -y --no-install-recommends ./radare2_6.2.4_amd64.deb ./r2mcp_1.8.8_amd64.deb \
    && rm -rf /var/lib/apt/lists/* /tmp/*.deb
WORKDIR /host
DOCKERFILE
    tag="b2b-debug-toolbox:$(sha256sum "$TOOLBOX_DIR/Dockerfile" | cut -c1-12)"
    if ! docker image inspect "$tag" >/dev/null 2>&1; then
        log "building $tag (one time, ~1 GB on /var)"
        timeout 1800 docker build -q -t "$tag" "$TOOLBOX_DIR" >/dev/null || die "docker build $tag failed"
    fi
    printf '%s\n' "$tag" >/etc/b2b/debug-toolbox.image
    cat >/usr/local/bin/b2b-debug <<'DEBUGEOF'
#!/bin/sh
# b2b-debug [CONTAINER] [CMD...] — a shell, or CMD, in the debug toolbox
# (gdb, strace, ltrace, tcpdump, tshark, bpftrace, perf, radare2, r2mcp),
# in CONTAINER's pid and network namespaces, or the host's without one.
# Privileged on purpose: attaching, capturing and tracing need it. The
# host's filesystem is /host, read-only; a container's own files are
# /host$(docker inspect -f '{{.GraphDriver.Data.MergedDir}}' CONTAINER).
img=$(cat /etc/b2b/debug-toolbox.image 2>/dev/null)
[ -n "$img" ] || { echo "b2b-debug: no toolbox image (make claude_debug)" >&2; exit 2; }
ns="--pid=host --net=host"
if [ $# -gt 0 ] && docker container inspect "$1" >/dev/null 2>&1; then
    ns="--pid=container:$1 --net=container:$1"
    shift
fi
tty=""
if [ -t 0 ] && [ -t 1 ]; then tty="-t"; fi
[ $# -gt 0 ] || set -- bash
# shellcheck disable=SC2086 # $ns and $tty are option lists, split on purpose
exec docker run --rm -i $tty --privileged $ns -v /:/host:ro \
    -v /sys/kernel/debug:/sys/kernel/debug -v /lib/modules:/lib/modules:ro "$img" "$@"
DEBUGEOF
    chmod 0755 /usr/local/bin/b2b-debug
    log "toolbox: $tag, run with b2b-debug [container] [cmd]"
fi

# ── 3. the checkout's ask rules, now and after every redeploy ────────────────
cat >/usr/local/sbin/b2b-claude-bypass <<'BYPASSEOF'
#!/bin/sh
# b2b-claude-bypass [GROBASE_DIR] — this guest's Claude runs grobase's
# checkout in bypass mode, and ask rules prompt even then: empty the tracked
# .claude/settings.json's ask list, keep the deny rule in settings.local.json,
# and install the pre-commit hook that keeps the edit out of every commit.
# install_grobase.sh reruns this after its `git checkout -f`.
dir=${1:-/opt/grobase}
[ -f "$dir/.claude/settings.json" ] || exit 0
python3 - "$dir" <<'PY' || exit 1
import json, os, sys
d = sys.argv[1]
p = os.path.join(d, ".claude", "settings.json")
st = os.stat(p)
def save(path, data):
    tmp = path + ".b2b"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    if os.geteuid() == 0:
        os.chown(tmp, st.st_uid, st.st_gid)
    os.replace(tmp, path)
s = json.load(open(p))
n = len(s.get("permissions", {}).get("ask", []))
if n:
    s["permissions"]["ask"] = []
    save(p, s)
lp = os.path.join(d, ".claude", "settings.local.json")
local = json.load(open(lp)) if os.path.exists(lp) else {}
before = json.dumps(local, sort_keys=True)
deny = local.setdefault("permissions", {}).setdefault("deny", [])
if "Read(**/.env.local)" not in deny:
    deny.append("Read(**/.env.local)")
# supermemory's OAuth needs a browser this guest has not got: 30 s timeout
# per session. playwright is replaced by the local-scope Docker entry.
off = local.setdefault("disabledMcpjsonServers", [])
off += [n for n in ("supermemory", "playwright") if n not in off]
if json.dumps(local, sort_keys=True) != before:
    save(lp, local)
print(f"b2b-claude-bypass: {n} ask rules removed" if n else "b2b-claude-bypass: no ask rules left")
PY
hook="$dir/.git/hooks/pre-commit"
if [ -d "$dir/.git/hooks" ] && { [ ! -e "$hook" ] || grep -q b2b-claude-bypass "$hook"; }; then
    cat >"$hook" <<'HOOK'
#!/bin/sh
# Installed by b2b-claude-bypass: this guest's .claude/settings.json has its
# ask rules removed for an unattended Claude, and must never be committed.
if git diff --cached --name-only | grep -qx .claude/settings.json; then
    echo "pre-commit: .claude/settings.json carries this VM's bypass edit; unstage it (git restore --staged .claude/settings.json)" >&2
    exit 1
fi
HOOK
    chmod 0755 "$hook"
    chown --reference="$dir/.claude/settings.json" "$hook" 2>/dev/null || true
fi
BYPASSEOF
chmod 0755 /usr/local/sbin/b2b-claude-bypass
/usr/local/sbin/b2b-claude-bypass "$GROBASE_DIR" || die "b2b-claude-bypass failed on $GROBASE_DIR"

# ── 4. the login's own settings: bypass, no warning, no devil asks ───────────
install -d -m 0700 -o "$LOGIN" -g "$GROUP" "$HOME_DIR/.claude"
python3 - "$HOME_DIR/.claude/settings.json" <<'USERPY' || die "$HOME_DIR/.claude/settings.json is not valid JSON; left as it was"
import json, os, sys
p = sys.argv[1]
s = json.load(open(p)) if os.path.exists(p) and os.path.getsize(p) else {}
s.setdefault("permissions", {})["defaultMode"] = "bypassPermissions"
s["skipDangerousModePermissionPrompt"] = True
s.setdefault("env", {})["DEVIL_AUTONOMY"] = "1"
tmp = p + ".b2b"
with open(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
    json.dump(s, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, p)
USERPY
chown "$LOGIN:$GROUP" "$HOME_DIR/.claude/settings.json"

# ── 5. MCP servers for the checkout, local scope ─────────────────────────────
# Merged into ~/.claude.json directly: `claude mcp add` launches the server
# to verify it, which hung under runuser before (install_devtools.sh).
# playwright-docker: grobase's .mcp.json runs @playwright/mcp with no
# browser here; the official image carries headless chromium, on /var, on
# the host network so it reaches the stack's loopback ports. A different
# name, because the same one in two scopes is flagged as a conflict even
# with the project's disabled. radare2: r2mcp in the toolbox.
python3 - "$HOME_DIR/.claude.json" "$GROBASE_DIR" "$PLAYWRIGHT_MCP_IMAGE" "$(cat /etc/b2b/debug-toolbox.image 2>/dev/null)" <<'MCPPY' || die "$HOME_DIR/.claude.json is not valid JSON; left as it was"
import json, os, sys
p, d, pw, tb = sys.argv[1:5]
s = json.load(open(p)) if os.path.exists(p) and os.path.getsize(p) else {}
proj = s.setdefault("projects", {}).setdefault(d, {})
proj["hasTrustDialogAccepted"] = True
mcp = proj.setdefault("mcpServers", {})
mcp["playwright-docker"] = {"type": "stdio", "command": "docker",
                            "args": ["run", "-i", "--rm", "--init", "--network", "host", pw]}
if tb:
    mcp["radare2"] = {"type": "stdio", "command": "docker",
                      "args": ["run", "-i", "--rm", "-v", "/:/host:ro", tb, "r2mcp"]}
tmp = p + ".b2b"
with open(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
    json.dump(s, f, indent=2, ensure_ascii=False)
os.replace(tmp, p)
MCPPY
chown "$LOGIN:$GROUP" "$HOME_DIR/.claude.json"
docker pull -q "$PLAYWRIGHT_MCP_IMAGE" >/dev/null || log "could not pull the Playwright MCP image; it pulls on first use"

# ── 6. the skill that tells the session where everything is ──────────────────
install -d -m 0755 -o "$LOGIN" -g "$GROUP" "$HOME_DIR/.claude/skills" "$HOME_DIR/.claude/skills/b2b-debug"
cat >"$HOME_DIR/.claude/skills/b2b-debug/SKILL.md" <<'SKILLEOF'
---
name: b2b-debug
description: Debug grobase in this born2root VM - health verdicts, logs, the privileged toolbox (gdb, strace, ltrace, tcpdump, tshark, bpftrace, perf, radare2) and this machine's limits. Use when a grobase service crashes, hangs, restarts, answers wrongly, or needs reverse engineering.
---

# Debugging grobase in this VM

## First, the verdict

- `b2b-stack-health 60` — read-only: names every container unhealthy,
  crash-looping or exited non-zero. `b2b-autoheal` restarts unhealthy ones.
- `docker ps --format '{{.Names}}\t{{.Status}}'`, then
  `docker logs --tail 200 <container>`.
- The code is `/opt/grobase`, at the ref born2root pins. `make up`,
  `make down`, `make health` run there without sudo.

## The toolbox: `b2b-debug [container] [cmd...]`

Privileged, in the container's pid and network namespaces (the host's
without a container). The host's files are at `/host`, read-only.

- `b2b-debug mini-baas-kong ps aux` — its processes
- `b2b-debug mini-baas-realtime strace -f -p 1 -e trace=network`
- `b2b-debug mini-baas-kong tcpdump -i any -nn -c 50 port 8000`
- `b2b-debug mini-baas-kong tshark -i any -Y http -c 20`
- `b2b-debug gdb -p <host pid>` / `b2b-debug perf top` /
  `b2b-debug bpftrace -e 'tracepoint:syscalls:sys_enter_openat { @[comm] = count(); }'`
- A container's binary for radare2:
  `m=$(docker inspect -f '{{.GraphDriver.Data.MergedDir}}' <container>)`,
  then `b2b-debug r2 -A "/host$m/<path>"`.

On the host itself: gdb, strace, ltrace, objdump, readelf, eu-stack,
patchelf, xxd, hexyl, binwalk, nmap, socat, iostat, psql, redis-cli,
sqlite3, node. Engines: `docker exec -it mini-baas-postgres psql -U postgres`.

## MCP servers

postgres (read-only) and grafana (Prometheus + Loki) through
`scripts/ops/mcp-server.sh`; playwright-docker (headless chromium in Docker, host
network); radare2 (r2mcp in the toolbox: paths under `/host`); context7
and deepwiki for library docs.

## Limits of this machine

- No passwordless sudo (the Born2beRoot sudo policy): root-level work goes
  through `b2b-debug` or `docker`.
- `/` is small (3.7 GB): install nothing there. `/var` has the room.
- `.claude/settings.json` is edited locally (ask rules removed for this
  unattended session). Never commit it; the pre-commit hook refuses.
- `/opt/grobase/.env.local` holds GitHub and Docker Hub tokens: never print
  them, never push or publish from this VM.
SKILLEOF
chown "$LOGIN:$GROUP" "$HOME_DIR/.claude/skills/b2b-debug/SKILL.md"
log "done: restart any running claude session to pick it up"
