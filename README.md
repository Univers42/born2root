# Born2beRoot — Fully Automated VM Builder

> One command to build a complete Born2beRoot Debian VM with SSH, WordPress, Docker, and VS Code Remote SSH that actually works.

```
make
```

That's it. Go grab a coffee. Come back to a fully configured VM.

---

## Table of Contents

- [What Is This](#what-is-this)
- [Quick Start](#quick-start)
- [What `make` Does (Step by Step)](#what-make-does)
- [Makefile Commands](#makefile-commands)
- [Connecting with VS Code Remote SSH](#connecting-with-vs-code-remote-ssh)
- [⚠️ Known Issue: VS Code SSH Drops After 15 Minutes](#known-issue-vscode-ssh-drops)
- [⚠️ Known Issue: Docker Permission Denied](#known-issue-docker-permission-denied)
- [Credentials](#credentials)
- [What's Inside the VM](#whats-inside-the-vm)
- [Project Structure](#project-structure)
- [Troubleshooting](#troubleshooting)

---

<a name="what-is-this"></a>
## What Is This

I built this because I was tired of manually installing Debian, configuring SSH, setting up WordPress, and then having VS Code Remote SSH die on me every 15 minutes.

This project automates the **entire Born2beRoot setup** from zero to a working VM:

- Downloads the latest Debian netinst ISO
- Injects a preseed file for fully unattended installation
- Creates a VirtualBox VM with the right specs
- Installs Debian with LUKS encryption + LVM partitions (bonus part)
- Configures SSH on port 4242, UFW, sudo, password policy, AppArmor
- Installs Docker, WordPress, lighttpd, MariaDB, PHP-FPM
- Sets up the monitoring script with cron
- Configures your host's `~/.ssh/config` so `ssh b2b` just works
- Injects your SSH public key so you never type a password
- Configures VS Code Remote SSH settings to fix the timeout bug

Everything is scripted. `make re` destroys everything and rebuilds from scratch.

---

<a name="quick-start"></a>
## Quick Start

### Prerequisites

- **VirtualBox** installed (or run `make deps` to install it)
- **xorriso** and **curl** (also installed by `make deps`)
- ~4GB free disk space

### Build the VM

```bash
git clone https://github.com/LESdylan/setup_arch_linux.git
cd setup_arch_linux
make
```

The orchestrator will:
1. Install dependencies if needed
2. Download the Debian ISO
3. Inject the preseed + setup scripts into the ISO
4. Create the VirtualBox VM (2GB RAM, 3 CPUs, 32GB disk)
5. Boot and install Debian automatically (~15-25 min depending on your machine)
6. Power off when done

### First Boot

After installation finishes:

1. Start the VM: `make start_vm` (GUI) or `make bstart_vm` (headless)
2. Enter the LUKS passphrase: `tempencrypt123`
3. Wait ~30 seconds for SSH to be ready
4. Connect: `ssh b2b`

### Connect with VS Code

1. `Ctrl+Shift+P` → "Remote-SSH: Connect to Host..."
2. Select `b2b`
3. No password needed (SSH key was injected during install)

---

<a name="what-make-does"></a>
## What `make` Does (Step by Step)

```
make
  │
  ├─ 1. Check/install dependencies (VirtualBox, xorriso, curl)
  │
  ├─ 2. Download latest Debian netinst ISO
  │     └─ Automatically detects the latest version from cdimage.debian.org
  │
  ├─ 3. Build custom ISO
  │     ├─ Inject preseed.cfg into initrd (fully automated install)
  │     ├─ Copy b2b-setup.sh (SSH, UFW, sudo, password policy, AppArmor, etc.)
  │     ├─ Copy monitoring.sh (Born2beRoot monitoring script)
  │     ├─ Copy first-boot-setup.sh (Docker + WordPress on first real boot)
  │     ├─ Copy host SSH public key (for passwordless auth)
  │     └─ Rebuild ISO with modified boot menu (auto-selects automated install)
  │
  ├─ 4. Create VirtualBox VM
  │     ├─ 2048 MB RAM, 3 CPUs, 64 GB dynamic disk
  │     ├─ NAT networking with port forwarding:
  │     │   SSH:4242  HTTP:80  HTTPS:443  Frontend:5173
  │     │   Backend:3000  Docker:5000  MariaDB:3306  Redis:6379
  │     └─ Attach the custom ISO
  │
  ├─ 5. Boot and install (unattended)
  │     ├─ Debian installer runs preseed.cfg
  │     ├─ LUKS + LVM partitions created automatically
  │     ├─ b2b-setup.sh runs in chroot (16 configuration sections)
  │     └─ VM powers off when done
  │
  └─ 6. Configure host
        ├─ Write ~/.ssh/config (b2b alias, keepalives)
        ├─ Configure VS Code settings.json (fix SSH timeout bug)
        └─ Display summary with credentials and URLs
```

---

<a name="makefile-commands"></a>
## Makefile Commands

| Command | Description |
|---------|-------------|
| `make` | **Full pipeline** — build everything from zero |
| `make re` | **Destroy and rebuild** — clean slate |
| `make status` | Show environment status dashboard |
| `make start_vm` | Start the VM (GUI mode) |
| `make bstart_vm` | Start headless + auto-unlock encryption |
| `make poweroff` | Shut down the VM |
| `make deps` | Install VirtualBox + tools |
| `make gen_iso` | Download Debian ISO + inject preseed |
| `make setup_vm` | Create the VirtualBox VM |
| `make clean` | Remove downloaded ISOs |
| `make fclean` | Remove ISOs + disk images |
| `make rm_disk_image` | Delete the VM completely |
| `make prune_vms` | Delete ALL VirtualBox VMs |
| `make list_vms` | List all VirtualBox VMs |
| `make help` | Show this help in the terminal |

---

<a name="connecting-with-vs-code-remote-ssh"></a>
## Connecting with VS Code Remote SSH

After `make` completes, your host is already configured. Just:

```
Ctrl+Shift+P → Remote-SSH: Connect to Host → b2b
```

The orchestrator automatically:
- Wrote `~/.ssh/config` with a `b2b` alias pointing to `127.0.0.1:4242`
- Injected your SSH public key into the VM (no password needed)
- Configured VS Code settings to prevent the SOCKS proxy timeout bug

### SSH Aliases

You can connect from the terminal with any of these:
```bash
ssh b2b            # shortest
ssh vm             # also works
ssh born2beroot    # full name
```

---

<a name="known-issue-vscode-ssh-drops"></a>
## ⚠️ Known Issue: VS Code SSH Connection Drops After ~15 Minutes

### The Problem

If you use VS Code Remote SSH with the **default settings** to connect to a VirtualBox VM with NAT networking, the connection will die after ~15 minutes of idle time with:

```
Connection timed out during banner exchange
```

The VS Code log shows:
```
Running server is stale. Ignoring
```

SSH from the terminal works fine. Only VS Code breaks.

### Why This Happens

VS Code Remote SSH defaults to **"Local Server Mode"** (`remote.SSH.useLocalServer: true`). In this mode, it runs:

```
ssh -T -D 49963 -o ConnectTimeout=15 user@host
```

That `-D` flag creates a **SOCKS5 proxy**. All VS Code traffic goes through this single shared tunnel. VirtualBox NAT has a connection tracking table with an idle timeout (~5-15 min). When the SOCKS proxy data channels go idle, VirtualBox NAT silently drops them. The SSH keepalives keep the TCP connection alive, but the SOCKS data inside the tunnel is dead.

This is a **VS Code + VirtualBox NAT** issue, not an SSH issue. Documented in:
- [microsoft/vscode-remote-release#1721](https://github.com/microsoft/vscode-remote-release/issues/1721)
- [microsoft/vscode-remote-release#10580](https://github.com/microsoft/vscode-remote-release/issues/10580)

### The Fix

Add these to your VS Code `settings.json` (`Ctrl+Shift+P` → "Preferences: Open User Settings (JSON)"):

```json
{
    "remote.SSH.useLocalServer": false,
    "remote.SSH.enableDynamicForwarding": false,
    "remote.SSH.useExecServer": false,
    "remote.SSH.connectTimeout": 60,
    "remote.SSH.showLoginTerminal": true
}
```

**What this does:**
- `useLocalServer: false` → **Terminal Mode**: each window gets its own direct SSH connection (no shared SOCKS proxy)
- `enableDynamicForwarding: false` → removes the `-D` flag entirely, uses direct TCP forwarding
- `useExecServer: false` → simpler connection, less cached state to go stale

Then clean stale server cache:

```bash
rm -rf ~/.config/Code/User/globalStorage/ms-vscode-remote.remote-ssh/vscode-ssh-host-*
```

Or run this one-liner to fix everything automatically:

```bash
python3 -c "
import json, os, glob

# Fix VS Code settings
p = os.path.expanduser('~/.config/Code/User/settings.json')
try:
    s = json.load(open(p))
except:
    s = {}
s['remote.SSH.useLocalServer'] = False
s['remote.SSH.enableDynamicForwarding'] = False
s['remote.SSH.useExecServer'] = False
s['remote.SSH.connectTimeout'] = 60
s['remote.SSH.showLoginTerminal'] = True
json.dump(s, open(p, 'w'), indent=4)

# Clean stale cache
for d in glob.glob(os.path.expanduser('~/.config/Code/User/globalStorage/ms-vscode-remote.remote-ssh/vscode-ssh-host-*')):
    import shutil; shutil.rmtree(d, ignore_errors=True)

print('Done! Reload VS Code (Ctrl+Shift+P → Developer: Reload Window)')
"
```

> **Note:** `make` already does this automatically. This section is for people who configured their VS Code manually or are hitting this issue on an existing setup.

For the full deep dive (12 hours of debugging distilled into one doc), see [`doc/SSH_VSCODE_FIX.md`](doc/SSH_VSCODE_FIX.md).

---

<a name="known-issue-docker-permission-denied"></a>
## ⚠️ Known Issue: Docker "Permission Denied" After First Boot

### The Problem

After `make re` and connecting to the VM, Docker commands fail:

```
permission denied while trying to connect to the Docker daemon socket
at unix:///var/run/docker.sock
```

### Why This Happens

Docker is installed by `first-boot-setup.sh` during the **first real boot** (it needs systemd + network, so it can't run during preseed). When Docker installs, it adds `dlesieur` to the `docker` group. But if VS Code's Remote SSH server was **already running** before Docker finished installing, the server process has a stale group list — it doesn't know about the `docker` group.

Linux group changes only take effect on **new login sessions**. The VS Code server is a persistent process (`--enable-remote-auto-shutdown`), so even reconnecting from VS Code reuses the same stale server.

> **This is now auto-fixed:** `first-boot-setup.sh` kills any running VS Code server after adding the docker group, and `b2b-setup.sh` pre-creates the `docker` group during preseed so it's present from the very first login. If you still hit this on an older build, use the manual fix below.

### The Fix

**Kill the VS Code server on the VM and reconnect:**

```bash
# From the host — kill stale VS Code server
ssh b2b 'pkill -f vscode-server'

# Then reconnect from VS Code:
# Ctrl+Shift+P → Remote-SSH: Connect to Host → b2b
```

Or from VS Code:
```
Ctrl+Shift+P → Remote-SSH: Kill VS Code Server on Host → select b2b
Then reconnect.
```

Or from a terminal inside the VM:
```bash
# Start a new shell with the docker group
newgrp docker

# Verify it works
docker ps
```

This is a one-time issue that only happens on the very first connection after `make re`. Every subsequent connection will have the `docker` group loaded.

### Verify Docker is Working

```bash
# From the host
ssh b2b 'docker ps && echo "Docker OK"'

# From inside the VM
docker run --rm hello-world
```

---

<a name="credentials"></a>
## Credentials

| What | Value |
|------|-------|
| Root password | `temproot123` |
| User (dlesieur) | `tempuser123` |
| LUKS disk encryption | `tempencrypt123` |
| SSH port | `4242` |

> ⚠️ Change these passwords after setup if you're doing the real Born2beRoot evaluation.

---

<a name="whats-inside-the-vm"></a>
## What's Inside the VM

### Born2beRoot Mandatory Part
- ✅ Debian Trixie (latest stable)
- ✅ LUKS encrypted disk + LVM partitions (root, swap, home, var, srv, tmp, var-log)
- ✅ SSH on port 4242 (no root login)
- ✅ UFW firewall (only 4242, 80, 443 open)
- ✅ sudo with strict rules (3 tries, TTY required, full logging)
- ✅ Password policy (min 10 chars, uppercase, lowercase, digit, max 3 repeats)
- ✅ AppArmor enabled at boot
- ✅ Monitoring script via cron (every 10 minutes, wall broadcast)
- ✅ Hostname: `dlesieur42`

### Born2beRoot Bonus Part
- ✅ WordPress with lighttpd + MariaDB + PHP-FPM
- ✅ Docker + Docker Compose
- ✅ Custom LVM partition layout per subject requirements

### Extra (Quality of Life)
- ✅ tmux with auto-attach (SSH sessions survive disconnects)
- ✅ Git configured for NAT (large clone fix)
- ✅ Developer tools (build-essential, python3, curl, vim, htop, etc.)
- ✅ SSH key auth (no passwords for VS Code)
- ✅ NAT keepalive service (prevents VirtualBox NAT timeout)
- ✅ SSHD watchdog service (auto-restarts if sshd dies)
- ✅ Aggressive keepalives (both client and server side)

### Partition Layout

```
sda
├── sda1          500 MB   /boot        (ext2, unencrypted)
└── sda5          ~31 GB   LUKS encrypted
    └── LVM
        ├── root      5.0 GB   /
        ├── swap      1.0 GB   [SWAP]
        ├── home      5.0 GB   /home
        ├── var      12.0 GB   /var
        ├── srv       1.0 GB   /srv
        ├── tmp       1.5 GB   /tmp
        └── var-log   ~5 GB    /var/log   (fills remaining space)
```

### Port Forwarding (NAT)

| Service | Host Port | VM Port |
|---------|-----------|---------|
| SSH | 4242 | 4242 |
| HTTP | 80 | 80 |
| HTTPS | 443 | 443 |
| Vite Frontend | 5173 | 5173 |
| Backend API | 3000 | 3000 |
| Docker Registry | 5000 | 5000 |
| MariaDB | 3306 | 3306 |
| Redis | 6379 | 6379 |

---

<a name="project-structure"></a>
## Project Structure

```
.
├── Makefile                    # Entry point — all commands start here
├── README.md                   # This file
│
├── preseeds/
│   ├── preseed.cfg             # Debian preseed — fully automated install
│   ├── b2b-setup.sh            # Main post-install script (SSH, UFW, sudo, etc.)
│   ├── first-boot-setup.sh     # Docker + WordPress install (runs on first boot)
│   └── monitoring.sh           # Born2beRoot monitoring script
│
├── generate/
│   ├── orchestrate.sh          # TUI dashboard — orchestrates `make all`
│   ├── create_custom_iso.sh    # Downloads Debian ISO + injects preseed
│   ├── status.sh               # Environment status dashboard
│   └── help.sh                 # Makefile help display
│
├── setup/
│   └── install/vms/
│       └── install_vm_debian.sh # VirtualBox VM creation script
│
├── monitore/
│   ├── monitoring.sh           # Main monitoring script
│   └── classes/                # Modular monitoring components
│       ├── cpu-load-module.sh
│       ├── memory-module.sh
│       ├── disk-module.sh
│       └── ...
│
├── diagnostic/                 # Diagnostic scripts (run inside VM)
│   ├── b2b_verifier.sh
│   ├── check_internet.sh
│   ├── disk_details.sh
│   ├── LVM_CHECK.sh
│   └── ...
│
├── fixes/                      # Fix scripts for common issues
│   ├── fix_ssh_stability.sh
│   ├── fix_lighttpd_php_mysql.sh
│   └── ...
│
├── doc/
│   ├── SSH_VSCODE_FIX.md       # Deep dive: VS Code SSH timeout fix
│   └── en.subject.pdf          # Born2beRoot subject PDF
│
├── wordpress/                  # WordPress themes + plugins
├── management_tools/           # sudo/user management scripts
├── utils/                      # Color schemes, welcome screen
└── tests/                      # Security tests (AppArmor, WordPress)
```

---

<a name="troubleshooting"></a>
## Troubleshooting

### "Connection refused" when trying `ssh b2b`

The VM isn't running or SSH isn't ready yet.

```bash
# Check VM status
make status

# Start the VM
make start_vm

# Wait for SSH (check every 2 seconds)
while ! ssh -o ConnectTimeout=2 -o BatchMode=yes b2b exit 2>/dev/null; do
    echo "Waiting..."; sleep 2
done && echo "Ready!"
```

### "Connection timed out during banner exchange"

This is the VS Code SOCKS proxy bug. Run the fix:

```bash
python3 -c "
import json, os, glob, shutil
p = os.path.expanduser('~/.config/Code/User/settings.json')
try: s = json.load(open(p))
except: s = {}
s.update({'remote.SSH.useLocalServer':False,'remote.SSH.enableDynamicForwarding':False,'remote.SSH.useExecServer':False,'remote.SSH.connectTimeout':60,'remote.SSH.showLoginTerminal':True})
json.dump(s, open(p,'w'), indent=4)
[shutil.rmtree(d, True) for d in glob.glob(os.path.expanduser('~/.config/Code/User/globalStorage/ms-vscode-remote.remote-ssh/vscode-ssh-host-*'))]
print('Fixed! Reload VS Code.')
"
```

See [`doc/SSH_VSCODE_FIX.md`](doc/SSH_VSCODE_FIX.md) for the full explanation.

### Docker "permission denied"

Close and reopen your VS Code window. The `docker` group wasn't loaded in your current session. See [Known Issue: Docker Permission Denied](#known-issue-docker-permission-denied).

### VM asks for password despite SSH key setup

Your SSH key wasn't injected during install (ISO build issue). Fix it manually:

```bash
# Copy your key to the VM (will ask for password ONE time)
ssh-copy-id -p 4242 dlesieur@127.0.0.1
# Password: tempuser123

# Verify — should NOT ask for password
ssh b2b echo "Key auth works"
```

### VM hangs at "System halted" and doesn't power off

```bash
# Force power off from host
VBoxManage controlvm debian poweroff
```

### "Host key verification failed" after `make re`

Normal — the VM was rebuilt with a new host key. The `~/.ssh/config` already has `StrictHostKeyChecking no` and `UserKnownHostsFile /dev/null` for the `b2b` host, so this shouldn't happen. If it does:

```bash
ssh-keygen -R "[127.0.0.1]:4242"
```

### Full diagnostic dump (run from host)

```bash
ssh -o BatchMode=yes -p 4242 dlesieur@127.0.0.1 '
echo "=== UPTIME ===" && uptime
echo "=== MEMORY ===" && free -m
echo "=== SSH ===" && systemctl is-active ssh && ss -tlnp | grep 4242
echo "=== DOCKER ===" && docker ps 2>&1 | head -3
echo "=== SERVICES ===" && systemctl is-active nat-keepalive sshd-watchdog docker
echo "=== GROUPS ===" && groups
echo "=== AUTH KEYS ===" && wc -l ~/.ssh/authorized_keys
'
```

---

## License

This is a 42 school project. Use it, learn from it, make it your own. Don't copy it blindly for your evaluation — understand what each script does.

---

*Built with frustration, caffeine, and 12 hours of debugging VS Code SSH timeouts.* 🫠