# How I Fixed VS Code Remote SSH Dropping Connection Every 15 Minutes

**Author:** dlesieur @ 42  
**Date:** February 17, 2026  
**Status:** RESOLVED ✅  
**Time spent debugging:** ~12 hours across multiple sessions

---

## Table of Contents

1. [The Problem](#1-the-problem)
2. [What I Tried First (And Why It Didn't Work)](#2-what-i-tried-first-and-why-it-didnt-work)
3. [The Breakthrough — Finding the Real Cause](#3-the-breakthrough--finding-the-real-cause)
4. [The Actual Root Cause Explained](#4-the-actual-root-cause-explained)
5. [The Fix — 3 Layers](#5-the-fix--3-layers)
6. [VS Code settings.json — Exact Configuration](#6-vs-code-settingsjson--exact-configuration)
7. [SSH Config — Host Side (~/.ssh/config)](#7-ssh-config--host-side-sshconfig)
8. [SSH Config — VM Side (/etc/ssh/sshd_config)](#8-ssh-config--vm-side-etcsshsshd_config)
9. [Diagnostic Commands Cheat Sheet](#9-diagnostic-commands-cheat-sheet)
10. [How It's All Baked Into `make re`](#10-how-its-all-baked-into-make-re)
11. [Sources & References](#11-sources--references)

---

## 1. The Problem

I'm running a **Born2beRoot** Debian VM inside VirtualBox with **NAT
networking** and SSH on port 4242. I connect to it from VS Code using the
**Remote - SSH** extension (`ms-vscode-remote.remote-ssh`).

**The symptoms were always the same:**

- I'd connect fine with VS Code Remote SSH
- Everything works perfectly for ~15 minutes
- Then the connection silently dies
- VS Code shows: **"Connection timed out during banner exchange"**
- The log says: **"Running server is stale. Ignoring"**
- Every reconnect attempt fails with the same banner timeout
- But `ssh -p 4242 dlesieur@127.0.0.1` from a regular terminal **still works
  fine**

The last point was the key clue — SSH itself was fine. The problem was specific
to VS Code.

Here's what the VS Code Remote SSH log looked like every time it died:

```text
[15:12:24] SSH Resolver called for "ssh-remote+...", attempt 1
[15:12:24] Found local server running: {..., "socksPort": 49526, ...}
[15:12:24] Found running server - short-circuiting install
[15:12:24] Starting forwarding server. local port 49534 -> socksPort 49526 -> remotePort 38065
...
[15:27:50] Running server is stale. Ignoring
[15:27:50] ssh: connect to host 127.0.0.1 port 4242: Connection timed out during banner exchange
```

Notice: it found a "running server" from a previous session, tried to reuse its
SOCKS port, and then everything went sideways.

---

## 2. What I Tried First (And Why It Didn't Work)

I assumed it was an SSH problem and threw literally everything at it. Here's the
full list of what I tried — **none of these fixed it by themselves**:

### Layer 1: SSH Keepalives (server side)

```bash
# In /etc/ssh/sshd_config on the VM:
ClientAliveInterval 30    # Server pings client every 30 seconds
ClientAliveCountMax 5     # 5 missed pings = disconnect
TCPKeepAlive yes          # Enable TCP-level keepalives
MaxStartups 50:30:100     # Accept many parallel connections (VS Code needs this)
MaxSessions 20            # Multiple sessions per connection
LoginGraceTime 300        # 5 min to authenticate (VS Code is slow to handshake)
```

### Layer 2: SSH Keepalives (client side, ~/.ssh/config)

```text
Host *
    ServerAliveInterval 15    # Client pings server every 15 seconds
    ServerAliveCountMax 4     # 4 missed = disconnect
    TCPKeepAlive yes
```

### Layer 3: Kernel TCP Keepalives

```bash
# /etc/sysctl.d/99-ssh-keepalive.conf
net.ipv4.tcp_keepalive_time=60    # First probe after 60s (not default 7200!)
net.ipv4.tcp_keepalive_intvl=15   # Re-probe every 15s
net.ipv4.tcp_keepalive_probes=5   # 5 failed = dead
```

### Layer 4: NAT Keepalive Service

A systemd service that pings the VirtualBox NAT gateway every 30s to keep
connection tracking alive:

```bash
#!/bin/bash
GW=$(ip route | awk '/default/ {print $3}' | head -1)
[ -z "$GW" ] && GW="10.0.2.2"
while true; do
    ping -c 1 -W 2 "$GW" >/dev/null 2>&1
    sleep 30
done
```

### Layer 5: SSHD Watchdog Service

A systemd service that checks if sshd is actually listening on port 4242 every
15s and restarts it if not:

```bash
#!/bin/bash
while true; do
    SSHD_ACTIVE=$(systemctl is-active ssh)
    LISTEN=$(ss -tlnp | grep -c 4242)
    if [ "$SSHD_ACTIVE" != "active" ] || [ "$LISTEN" = "0" ]; then
        systemctl restart ssh
    fi
    sleep 15
done
```

### Layer 6: systemd Auto-Restart Override

```ini
# /etc/systemd/system/ssh.service.d/override.conf
[Service]
Restart=always
RestartSec=3
StartLimitIntervalSec=60
StartLimitBurst=10
```

### Layer 7: tmux Auto-Attach

So at least terminal sessions survive the drops.

**Result: NONE OF THIS FIXED IT.** The connection STILL dropped every ~15
minutes. The SSH daemon was healthy, the keepalives were firing, the watchdog
saw sshd as "active"... but VS Code's connection still died.

I was about to give up and rebuild the entire VM without LUKS encryption,
thinking maybe that was causing it. That would have been the wrong move.

---

## 3. The Breakthrough — Finding the Real Cause

I found two critical GitHub issues on the `microsoft/vscode-remote-release`
repo:

### Issue #1721 — `ssh -T timeouts with Remote - SSH`

**URL:** <https://github.com/microsoft/vscode-remote-release/issues/1721>

> **Key comment by a Microsoft engineer:** _"A general workaround for many of
> them is setting `"remote.SSH.useLocalServer": false`."_

Multiple people had the exact same symptoms. The fix that kept coming up:

- Delete `~/.config/Code` (or just the stale server cache)
- Set `remote.SSH.useLocalServer` to `false`

### Issue #10580 — SSH Connection Timeout after moving to a new location

**URL:** <https://github.com/microsoft/vscode-remote-release/issues/10580>

Same symptoms. VS Code SSH times out, but `ssh` from terminal works fine. The
logs show the same pattern: "Found running server - short-circuiting install" →
then it tries to reuse a stale SOCKS tunnel → dies.

### Issue fixing vscode when it keeps dropping ssh connections

**URL:**
<https://earlruby.org/2021/06/fixing-vscode-when-it-keeps-dropping-ssh-connections/comment-page-1/>

### The Official Troubleshooting Wiki

**URL:**
<https://github.com/microsoft/vscode-remote-release/wiki/Remote-SSH-Troubleshooting>

This page describes the two connection modes:

> **`remote.SSH.useLocalServer: true`** (default — "Local Server Mode"):  
> The Remote-SSH extension spawns an SSH process which will then be **reused by
> all VS Code windows** connected to that remote.
>
> **`remote.SSH.useLocalServer: false`** ("Terminal Mode"):  
> Each VS Code window has **its own** connection.

That was the moment I understood everything.

---

## 4. The Actual Root Cause Explained

Here's what's actually happening, step by step:

### VS Code's Default Connection Mode

When `remote.SSH.useLocalServer` is `true` (the default), VS Code does this:

```text
ssh -v -T -D 49963 -o ConnectTimeout=15 dlesieur@127.0.0.1 -p 4242
              ^^
              THIS IS THE PROBLEM
```

That **`-D 49963`** flag creates a **SOCKS5 dynamic port forwarding proxy**. VS
Code routes ALL its traffic (extensions, file access, terminals, debug sessions)
through this single SOCKS tunnel. It's a smart optimization — one SSH connection
serves everything.

### VirtualBox NAT Kills the SOCKS Tunnel

VirtualBox NAT has a **connection tracking table** that maps host ports to guest
ports. This table has an **idle timeout** (somewhere around 5-15 minutes
depending on the VirtualBox version). When there's no traffic on the SOCKS proxy
for a while:

1. VirtualBox NAT silently drops the connection tracking entry
2. The SSH TCP connection stays "alive" (keepalives keep it going)
3. But the **SOCKS proxy DATA channels** inside the tunnel get corrupted/dropped
4. VS Code tries to send data through the SOCKS proxy → no response
5. VS Code marks the server as "stale"
6. VS Code tries to reconnect with a new SSH connection
7. But it still has **cached server data** from the old session (port numbers,
   process IDs, etc.)
8. It tries to reuse this stale data → **banner exchange timeout**

### Why Regular SSH Works Fine

Regular `ssh -p 4242 dlesieur@127.0.0.1` doesn't use `-D` (no SOCKS proxy). It's
a simple TCP connection with keepalives. VirtualBox NAT handles simple TCP
keepalives fine. The connection survives indefinitely.

### Why Keepalives Didn't Fix It

My keepalives were keeping the **SSH connection itself** alive. But the SOCKS
proxy has its own data channels that go through different NAT connection
tracking entries. The keepalives don't cover those.

### The Diagram

```text
┌─────────────┐                    ┌──────────────┐
│  VS Code    │                    │  Debian VM   │
│             │                    │              │
│  ext host ──┼─► SOCKS :49963 ──►│──► sshd:4242 │
│  terminal ──┤    (shared)        │              │
│  files    ──┤                    │              │
│  debug    ──┤                    │              │
└─────────────┘                    └──────────────┘
                    ▲
                    │
            VirtualBox NAT drops
            this after ~15 min idle
            (keepalives don't save it)
```

**With `useLocalServer: false` (Terminal Mode):**

```text
┌─────────────┐                    ┌──────────────┐
│  VS Code    │                    │  Debian VM   │
│             │                    │              │
│  window 1 ──┼─► SSH conn 1 ────►│──► sshd:4242 │
│  window 2 ──┼─► SSH conn 2 ────►│              │
│  terminal ──┼─► SSH conn 3 ────►│              │
└─────────────┘  (each has own)    └──────────────┘
                    ▲
                    │
            Simple TCP connections
            Keepalives work perfectly
            NAT handles these fine
```

---

## 5. The Fix — 3 Layers

### Layer A: VS Code Settings (THE critical fix)

```json
{
  "remote.SSH.useLocalServer": false,
  "remote.SSH.enableDynamicForwarding": false,
  "remote.SSH.useExecServer": false,
  "remote.SSH.connectTimeout": 60,
  "remote.SSH.showLoginTerminal": true
}
```

**What each setting does:**

| Setting                              | Value   | Why                                                                                                                                                                  |
| ------------------------------------ | ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `remote.SSH.useLocalServer`          | `false` | **THE FIX.** Switches from "Local Server Mode" (shared SOCKS proxy) to "Terminal Mode" (each window gets its own SSH connection). No more shared tunnel to go stale. |
| `remote.SSH.enableDynamicForwarding` | `false` | Disables the `-D` SOCKS proxy flag entirely. VS Code uses direct TCP port forwarding instead, which VirtualBox NAT handles properly.                                 |
| `remote.SSH.useExecServer`           | `false` | Disables the exec server bootstrap. Less cached state = less "stale server" issues. Simpler connection lifecycle.                                                    |
| `remote.SSH.connectTimeout`          | `60`    | Give VS Code 60 seconds to connect (default is 15). On a busy VirtualBox host, the first connection can be slow.                                                     |
| `remote.SSH.showLoginTerminal`       | `true`  | Shows the SSH terminal during connection. Useful for debugging — I can see exactly what's happening if something goes wrong.                                         |

### Layer B: Clean Stale Server Cache

```bash
# On the HOST machine — clean VS Code's cached server data
rm -rf ~/.config/Code/User/globalStorage/ms-vscode-remote.remote-ssh/vscode-ssh-host-*
```

This removes the stale "Found running server" data that causes VS Code to try to
reuse dead SOCKS tunnels.

### Layer C: SSH Key Authentication (no more password prompts)

Without key auth, every time VS Code reconnects it needs a password. If the
connection drops and tries to auto-reconnect, it can't type the password →
permanent failure.

With key auth:

- Connection drops
- VS Code automatically reconnects
- No password needed → instant reconnect
- You don't even notice the drop

```bash
# On the HOST — copy your public key to the VM
ssh-copy-id -p 4242 dlesieur@127.0.0.1

# Verify it works (should NOT ask for password)
ssh -o BatchMode=yes -p 4242 dlesieur@127.0.0.1 echo "KEY AUTH WORKS"
```

---

## 6. VS Code settings.json — Exact Configuration

File location: `~/.config/Code/User/settings.json`

Here's my complete settings.json with the Remote SSH fixes:

```json
{
  "inlineChat.hideOnRequest": true,
  "workbench.colorTheme": "GitHub Dark High Contrast",
  "editor.dragAndDrop": false,
  "editor.definitionLinkOpensInPeek": true,
  "editor.insertSpaces": false,
  "files.autoSave": "afterDelay",
  "github.copilot.nextEditSuggestions.enabled": true,
  "github.copilot.enable": {
    "*": true,
    "plaintext": false,
    "markdown": true,
    "scminput": false,
    "c": false
  },
  "explorer.confirmDelete": false,
  "makefile.configureOnOpen": true,
  "explorer.confirmDragAndDrop": false,
  "remote.SSH.useLocalServer": false,
  "remote.SSH.enableDynamicForwarding": false,
  "remote.SSH.useExecServer": false,
  "remote.SSH.connectTimeout": 60,
  "remote.SSH.showLoginTerminal": true,
  "remote.SSH.remotePlatform": {
    "b2b": "linux"
  }
}
```

### How to apply manually

1. Open VS Code
2. Press `Ctrl+Shift+P` → type "Preferences: Open User Settings (JSON)"
3. Add the `remote.SSH.*` lines from above
4. Save
5. Reload VS Code (`Ctrl+Shift+P` → "Developer: Reload Window")

### Or from the terminal

```bash
# Using python3 to safely merge into existing settings
python3 -c "
import json
settings_path = '$HOME/.config/Code/User/settings.json'
with open(settings_path, 'r') as f:
    s = json.load(f)
s['remote.SSH.useLocalServer'] = False
s['remote.SSH.enableDynamicForwarding'] = False
s['remote.SSH.useExecServer'] = False
s['remote.SSH.connectTimeout'] = 60
s['remote.SSH.showLoginTerminal'] = True
with open(settings_path, 'w') as f:
    json.dump(s, f, indent=4)
print('Done')
"
```

---

## 7. SSH Config — Host Side (~/.ssh/config)

File location: `~/.ssh/config`

```text
Host *
    ServerAliveInterval 15
    ServerAliveCountMax 4
    TCPKeepAlive yes
    ConnectionAttempts 3
    ConnectTimeout 15

# Born2beRoot VM (auto-generated by orchestrate.sh)
Host b2b vm born2beroot
    HostName 127.0.0.1
    Port 4242
    User dlesieur
    ServerAliveInterval 15
    ServerAliveCountMax 6
    TCPKeepAlive yes
    ConnectionAttempts 5
    ConnectTimeout 15
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
```

### What each line does

| Line                           | Purpose                                                                                                                  |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------ |
| `ServerAliveInterval 15`       | Client sends a keepalive to the server every 15 seconds. This keeps VirtualBox NAT from thinking the connection is idle. |
| `ServerAliveCountMax 6`        | If 6 keepalives get no response (= 90 seconds), consider the connection dead.                                            |
| `TCPKeepAlive yes`             | Also enable OS-level TCP keepalives (belt AND suspenders).                                                               |
| `ConnectionAttempts 5`         | Try 5 times if the initial TCP connection fails.                                                                         |
| `ConnectTimeout 15`            | Wait up to 15 seconds for the TCP connection to establish.                                                               |
| `StrictHostKeyChecking no`     | Don't ask "are you sure you want to connect?" every time (the VM regenerates its host key on rebuild).                   |
| `UserKnownHostsFile /dev/null` | Don't save the VM's host key (it changes on every `make re`).                                                            |
| `LogLevel ERROR`               | Don't spam warnings about the unknown host key.                                                                          |

### Why `Host b2b vm born2beroot` (space-separated)?

This creates three aliases for the same host. I can use any of these:

```bash
ssh b2b            # shortest
ssh vm             # also works
ssh born2beroot    # full name
```

And in VS Code, I connect to `b2b` as the remote host.

---

## 8. SSH Config — VM Side (/etc/ssh/sshd_config)

These settings are applied by `preseeds/b2b-setup.sh` during VM installation:

```bash
Port 4242                      # Born2beRoot requires non-standard port
PermitRootLogin no             # Born2beRoot security requirement
PasswordAuthentication yes     # Allow password auth (for initial setup)
PubkeyAuthentication yes       # Also allow key auth (for VS Code)
ClientAliveInterval 30         # Server pings client every 30s
ClientAliveCountMax 5          # 5 missed = kill the session
TCPKeepAlive yes               # OS-level keepalives too
MaxStartups 50:30:100          # VS Code opens MANY parallel connections
MaxSessions 20                 # Allow multiple sessions per connection
LoginGraceTime 300             # 5 min to complete auth (VS Code is slow)
```

### Why MaxStartups 50:30:100?

This was a hard-won lesson. VS Code Remote SSH opens **many** parallel SSH
connections simultaneously when it connects:

- 1 for the SOCKS/control channel
- 1 for the exec server
- 1-2 for the extension host
- 1 per terminal
- 1 for file operations
- More for port forwarding

The default `MaxStartups 10:30:100` starts randomly rejecting connections at 10
unauthenticated. VS Code sometimes needs 15+ simultaneous new connections on
reconnect. At 50, it has plenty of room.

### Kernel TCP Keepalives

```bash
# /etc/sysctl.d/99-ssh-keepalive.conf
net.ipv4.tcp_keepalive_time=60     # First probe after 60s idle
net.ipv4.tcp_keepalive_intvl=15    # Re-probe every 15s
net.ipv4.tcp_keepalive_probes=5    # 5 failed probes = dead
```

The Linux default `tcp_keepalive_time` is **7200 seconds (2 hours!)** — way too
long for VirtualBox NAT which drops idle connections in ~5-15 minutes.

---

## 9. Diagnostic Commands Cheat Sheet

### On the HOST (your 42 machine)

```bash
# ── Check if VM is reachable ──────────────────────────────────
ssh -v -o BatchMode=yes -p 4242 dlesieur@127.0.0.1 echo "SSH OK"
# -v = verbose (shows handshake details)
# -o BatchMode=yes = don't ask for password (fail if key auth doesn't work)

# ── Check if SSH banner responds (catches the banner timeout issue) ──
timeout 5 bash -c 'echo | nc -w 3 127.0.0.1 4242'
# Should return something like: SSH-2.0-OpenSSH_10.0p2 Debian-2

# ── Check VirtualBox VM status ────────────────────────────────
VBoxManage showvminfo debian --machinereadable | grep -E "VMState=|natpf"
# Shows if VM is running and what port forwarding rules exist

# ── Check for hung SSH processes on the host ──────────────────
ps aux | grep "[s]sh.*4242"
# If you see zombie/hung ssh processes, kill them:
pkill -f "ssh.*4242"

# ── View VS Code Remote SSH log ──────────────────────────────
# In VS Code: View → Output → select "Remote - SSH" from dropdown
# Or find the log file:
find ~/.config/Code -name "*.log" -newer ~/.config/Code/User/settings.json | head

# ── Check VS Code stale server cache ─────────────────────────
ls -la ~/.config/Code/User/globalStorage/ms-vscode-remote.remote-ssh/vscode-ssh-host-*
# If these exist and you're having connection issues, delete them:
rm -rf ~/.config/Code/User/globalStorage/ms-vscode-remote.remote-ssh/vscode-ssh-host-*

# ── Verify VS Code settings are applied ──────────────────────
grep -A1 "remote.SSH" ~/.config/Code/User/settings.json

# ── Check your SSH config ─────────────────────────────────────
ssh -G b2b    # Shows the effective SSH config for host "b2b"
```

### On the VM (via SSH)

```bash
# ── SSH daemon health ─────────────────────────────────────────
systemctl status ssh                 # Is sshd running?
ss -tlnp | grep 4242                # Is it listening on 4242?
ss -tnp | grep 4242                 # How many established connections?
journalctl -u ssh -n 20 --no-pager  # Recent sshd logs

# ── Check sshd configuration ─────────────────────────────────
sudo sshd -T | grep -iE "clientalive|maxstart|maxsession|logingrace|pubkey|password"
# Shows the EFFECTIVE sshd config (after all includes/overrides)

# ── Keepalive services health ─────────────────────────────────
systemctl status nat-keepalive       # Is NAT keepalive running?
systemctl status sshd-watchdog       # Is the watchdog running?
cat /var/log/sshd-watchdog.log | tail -20  # Watchdog log

# ── Network diagnostics ──────────────────────────────────────
ip route                             # Check default gateway
ping -c 3 10.0.2.2                   # Can we reach VirtualBox NAT gateway?
cat /proc/sys/net/ipv4/tcp_keepalive_time   # Should be 60 (not 7200)

# ── Memory (if sshd is being OOM-killed) ─────────────────────
free -m                              # Available memory
dmesg | grep -i "oom\|kill" | tail   # Any OOM kills?

# ── Check authorized keys (for key auth) ─────────────────────
cat ~/.ssh/authorized_keys           # Your host's public key should be here
ls -la ~/.ssh/                       # Permissions must be correct:
                                     # .ssh/ = 700, authorized_keys = 600

# ── VS Code server on the VM ─────────────────────────────────
ls ~/.vscode-server/cli/servers/     # Installed VS Code servers
ps aux | grep vscode                 # Running VS Code server processes
# Kill stale VS Code servers:
pkill -f vscode-server
```

### Full diagnostic one-liner (run from host)

```bash
ssh -o BatchMode=yes -p 4242 dlesieur@127.0.0.1 '
echo "=== VM DIAGNOSTIC DUMP ==="
echo "--- Uptime ---"; uptime
echo "--- Memory ---"; free -m
echo "--- SSH status ---"; systemctl is-active ssh
echo "--- Listening on 4242 ---"; ss -tlnp | grep 4242
echo "--- Established SSH ---"; ss -tnp | grep 4242 | wc -l
echo "--- Keepalive services ---"
systemctl is-active nat-keepalive sshd-watchdog
echo "--- TCP keepalive ---"; cat /proc/sys/net/ipv4/tcp_keepalive_time
echo "--- SSHD config ---"
grep -E "^(Client|Max|Login|Pubkey|Password)" /etc/ssh/sshd_config
echo "--- Watchdog log (last 5) ---"
tail -5 /var/log/sshd-watchdog.log 2>/dev/null
echo "--- VS Code server ---"
ps aux | grep -c "[v]scode"
echo "--- Auth keys ---"; wc -l ~/.ssh/authorized_keys 2>/dev/null
echo "=== END ==="
'
```

---

## 10. How It's All Baked Into `make re`

All of this is automated so I never have to do it manually again. When I run
`make re`:

### 1. ISO Creation (`generate/create_custom_iso.sh`)

- Copies `b2b-setup.sh`, `monitoring.sh`, `first-boot-setup.sh` into the ISO
- Also copies my host's SSH public key as `host_ssh_pubkey` into the ISO

### 2. VM Installation (preseed + `b2b-setup.sh`)

- Preseed automates the entire Debian installation
- `preseed.cfg` `late_command` copies `host_ssh_pubkey` from `/cdrom/` to
  `/target/tmp/` (because `b2b-setup.sh` runs inside `in-target` chroot where
  `/cdrom/` is NOT accessible)
- `b2b-setup.sh` runs in chroot and configures:
  - SSH on port 4242 with all keepalive settings
  - MaxStartups 50:30:100 for VS Code
  - NAT keepalive systemd service
  - SSHD watchdog systemd service
  - Kernel TCP keepalive sysctl
  - systemd auto-restart override for sshd
  - Installs host SSH public key from `/tmp/host_ssh_pubkey` into
    `~/.ssh/authorized_keys`
  - Enables `PubkeyAuthentication yes`

### 3. Orchestrator (`generate/orchestrate.sh`)

After the ISO is built and VM is created:

- `setup_host_ssh_config()` — writes `~/.ssh/config` with keepalive settings and
  `b2b` alias
- **NEW:** `setup_vscode_remote_ssh()` — auto-configures VS Code `settings.json`
  with the 5 critical Remote SSH settings
- **NEW:** `setup_ssh_key_auth()` — generates SSH key pair if none exists

### The result

After `make re`, I can immediately do:

1. Boot the VM
2. Enter LUKS passphrase (tempencrypt123)
3. Open VS Code → Remote SSH → Connect to `b2b`
4. **No password prompt** (key auth)
5. **Connection never drops** (Terminal Mode, no SOCKS proxy)

---

## 11. Sources & References

### Primary Sources (these solved my problem)

| Source                                                                                                                        | What I learned                                                                                                                                                                                                                |
| ----------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [GitHub Issue #1721 — ssh -T timeouts with Remote - SSH](https://github.com/microsoft/vscode-remote-release/issues/1721)      | Microsoft engineer's comment: _"A general workaround for many of them is setting `remote.SSH.useLocalServer: false`"_. Multiple users confirmed that cleaning `~/.config/Code` + setting this fixed their identical symptoms. |
| [GitHub Issue #10580 — SSH Connection Timeout after moving](https://github.com/microsoft/vscode-remote-release/issues/10580)  | User had the exact same symptoms with a VM. SSH works from terminal, dies in VS Code. The log showed the same "Found running server / stale / banner timeout" pattern I was seeing.                                           |
| [VS Code Remote SSH Troubleshooting Wiki](https://github.com/microsoft/vscode-remote-release/wiki/Remote-SSH-Troubleshooting) | Official documentation explaining Local Server Mode vs Terminal Mode. Describes `useLocalServer`, `useExecServer`, `enableDynamicForwarding` and their effects.                                                               |

### Supporting Knowledge

| Topic                              | Resource                                                                                                                                     |
| ---------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| VirtualBox NAT connection tracking | VirtualBox docs — NAT engine maintains a connection tracking table with idle timeouts. No official documentation of the exact timeout value. |
| SSH SOCKS proxy (`-D` flag)        | `man ssh` — "Specifies a local dynamic application-level port forwarding". Creates a SOCKS5 proxy through the SSH tunnel.                    |
| OpenSSH keepalives                 | `man sshd_config` — `ClientAliveInterval`, `ClientAliveCountMax`. These operate at the SSH protocol level, not TCP.                          |
| TCP keepalives                     | Linux kernel docs — `tcp_keepalive_time`, `tcp_keepalive_intvl`, `tcp_keepalive_probes`. These operate at the TCP level.                     |
| MaxStartups                        | `man sshd_config` — "Specifies the maximum number of concurrent unauthenticated connections to the SSH daemon. start:rate:full format."      |

### What DIDN'T help (but is commonly suggested)

| Suggestion                              | Why it didn't work for me                                                                                               |
| --------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| "Increase keepalive intervals"          | Keepalives protect the SSH connection, not the SOCKS proxy data channels inside it.                                     |
| "Remove LUKS encryption"                | LUKS is transparent after boot — it has zero effect on networking.                                                      |
| "Use bridged networking instead of NAT" | Would work but isn't necessary — the real fix is in VS Code settings. Also, 42 campus networks often block bridged VMs. |
| "Restart sshd"                          | The sshd was never the problem — it was always running and healthy.                                                     |
| "Increase VM RAM"                       | Memory wasn't the issue — the VM had plenty.                                                                            |

---

## TL;DR

**The problem was never SSH. It was VS Code.**

VS Code Remote SSH defaults to `"remote.SSH.useLocalServer": true`, which
creates a **shared SOCKS5 proxy** (`ssh -D port`). VirtualBox NAT silently drops
the SOCKS proxy state after ~15 minutes idle. VS Code then tries to reuse stale
cached server data, and everything dies.

**The fix is 3 settings:**

```json
{
  "remote.SSH.useLocalServer": false,
  "remote.SSH.enableDynamicForwarding": false,
  "remote.SSH.useExecServer": false
}
```

Plus SSH key auth so reconnects are instant and automatic. That's it. 12 hours
of debugging for 3 lines of JSON. 🫠
