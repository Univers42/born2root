#!/usr/bin/env hellish
# Born2beRoot post-installation setup script
# Runs inside in-target (chroot to /target) during d-i late_command
# ─────────────────────────────────────────────────────────────────
# ARCHITECTURE:
#   b2b-setup.sh  → runs in chroot during install (no systemd, limited net)
#                   ONLY installs Debian repo packages + configures B2B
#   first-boot-setup.sh → runs on first real boot with full systemd + network
#                   installs Docker, WordPress, third-party tools (npm, pipx, etc.)
#
# CRITICAL: All Born2beRoot mandatory configuration MUST run before any
# network downloads. A hung `curl|sh` or `npm install` in chroot would
# block the entire script and leave the system un-configured.
# ─────────────────────────────────────────────────────────────────
set +e # Don't exit on errors — best effort
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

LOG=/var/log/b2b-setup.log
exec > >(tee -a "$LOG") 2>&1

echo "=== Born2beRoot setup starting ($(date)) ==="

### ─── 0. Which features this build asked for ───────────────────────────────
# Decided on the host by generate/feature_profile.sh from SIZE_B2B, checked
# there against the partition layout, and shipped as /etc/b2b/features.conf
# (late_command copies it in). An ISO without the file gets the base set only,
# which is what every profile contains: the install still works, it is just
# the smallest one.
mkdir -p /etc/b2b
B2B_PROFILE=minimal
if [ -f /etc/b2b/features.conf ]; then
    # shellcheck disable=SC1091
    . /etc/b2b/features.conf
    echo "[OK] features.conf: profile=$B2B_PROFILE size=${B2B_SIZE_GB:-?}GB"
else
    echo "[WARN] /etc/b2b/features.conf missing — assuming the base profile"
fi
# feature_on <name>: is this feature in the build? Base features are on even
# without the file, so a mandatory install never depends on it.
feature_on() {
    case "$1" in debian-base | b2b-mandatory | devtools-apt | nvim | hellish-upstream) [ ! -f /etc/b2b/features.conf ] && return 0 ;; esac
    grep -qx "B2B_FEATURE_$(printf '%s' "$1" | tr '-' '_')=on" /etc/b2b/features.conf 2>/dev/null
}
# feature_fail <name> <reason>: a BASE feature could not be installed. The
# host is watching the serial port for exactly this line (setup/host/
# di_progress.sh) and fails `make all` on it, so a missing sudo or nvim ends
# the build instead of being a surprise at first login.
feature_fail() {
    echo "[FAIL] $1: $2"
    printf '%s %s\n' "$1" "$2" >>/etc/b2b/PROVISION_FAILED
    echo "B2B-FEATURE-FAILED $1: $2"
}

# ── Disk space safety check ──────────────────────────────────────────────────
# Returns 0 (OK) if the given mount point has at least $2 MB free.
# Usage: check_disk_space / 500  → true if / has >= 500 MB free
check_disk_space() {
    local mount="$1" min_mb="${2:-200}"
    local avail_kb
    avail_kb=$(df -k "$mount" 2>/dev/null | awk 'NR==2 {print $4}')
    [ -z "$avail_kb" ] && return 0 # can't check → assume OK
    local avail_mb
    avail_mb=$((avail_kb / 1024))
    if [ "$avail_mb" -lt "$min_mb" ]; then
        echo "[WARN] LOW DISK: $mount has only ${avail_mb}MB free (need ${min_mb}MB) — skipping further installs"
        return 1
    fi
    return 0
}

### ─── 1. APT sources ────────────────────────────────────────────────────────
# Detect the installed release codename — do NOT blindly switch to a different
# release. Mixing releases (e.g. bookworm base + trixie packages) causes
# dependency conflicts that break dpkg and prevent GRUB from configuring.
RELEASE=$(. /etc/os-release 2>/dev/null && echo "$VERSION_CODENAME" || echo "")
if [ -z "$RELEASE" ]; then
    # Fallback: try lsb_release
    RELEASE=$(lsb_release -cs 2>/dev/null || echo "bookworm")
fi
echo "[INFO] Detected release: $RELEASE"

# Use the detected release for all repos — consistent with base install
cat >/etc/apt/sources.list <<SRCEOF
deb http://deb.debian.org/debian ${RELEASE} main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${RELEASE}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${RELEASE}-security main contrib non-free non-free-firmware
SRCEOF

apt-get clean
apt-get update -qq || true
echo "[OK] APT sources configured for $RELEASE"

### ─── 2. Install packages (all available in base repos) ─────────────────────
APT="apt-get install -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

# Core Born2beRoot mandatory requirements (MUST succeed — small footprint)
$APT sudo ufw openssh-server \
    libpam-pwquality apparmor apparmor-utils \
    cron haveged || true
echo "[OK] Core packages"

# Bonus: Web stack (lighttpd + MariaDB + PHP) — the `webstack` feature,
# standard profile and up. Its fit was checked at ISO-build time; the space
# guard here is a last line against a wrong estimate, not the decision.
if ! feature_on webstack; then
    echo "[OFF] Web stack packages — not in the '$B2B_PROFILE' profile"
elif check_disk_space / 800; then
    $APT lighttpd mariadb-server \
        php-fpm php-mysql php-cgi php-mbstring php-xml php-gd php-curl || true
    echo "[OK] Web stack packages"
else
    echo "[WARN] webstack: insufficient space on / — the build-time estimate was wrong, see generate/feature_profile.sh"
    printf 'webstack no-space\n' >>/etc/b2b/features.status
fi

# Developer essentials (all in base Debian repos)
# libreadline-dev is a build dep, not a runtime one: the custom shell ships as a
# prebuilt binary in 2b, but rebuilding it from source inside the VM needs the
# headers. Without it the build fails on <readline/readline.h> and the only fix
# is a manual apt install on a freshly provisioned machine.
# NOTE: nodejs/npm are installed by first-boot-setup.sh (full systemd + network).
# Installing npm in d-i chroot hangs on dpkg triggers → blocks entire script
# → SSH, sudo, UFW, password policy etc. never get configured.
# `devtools-apt` is a BASE feature: gcc and python3 are what nvim's parsers
# and providers are built with, so running out of room here is a failed build.
if check_disk_space / 500; then
    $APT git build-essential gcc g++ make \
        libreadline-dev \
        python3 python3-venv \
        curl wget net-tools vim nano \
        htop tree tmux bash-completion \
        zip unzip tar gzip bzip2 xz-utils \
        ca-certificates gnupg lsb-release apt-transport-https \
        rsync less file patch diffutils \
        dnsutils iputils-ping \
        jq bc || true
    echo "[OK] Developer tools"
else
    feature_fail devtools-apt "less than 500 MB free on / before the developer packages"
fi

# Clean apt cache after package install to reclaim space on /var
apt-get clean 2>/dev/null || true

### ─── 2b. Optional custom login shell — install + set default ─────────────
# The ISO late_command (if configured) copies:
#   /cdrom/custom_shell.bin  -> /target/tmp/custom_shell.bin
#   /cdrom/custom_shell.dest -> /target/tmp/custom_shell.dest
# Since this script runs via in-target, these paths are under /tmp/.
CUSTOM_SHELL_BIN="/tmp/custom_shell.bin"
CUSTOM_SHELL_DEST_FILE="/tmp/custom_shell.dest"

if [ -f "$CUSTOM_SHELL_BIN" ] && [ -f "$CUSTOM_SHELL_DEST_FILE" ]; then
    CUSTOM_SHELL_DEST=$(head -n1 "$CUSTOM_SHELL_DEST_FILE" 2>/dev/null | tr -d '\r\n')
    if [ -z "$CUSTOM_SHELL_DEST" ]; then
        echo "[WARN] custom_shell.dest is empty — skipping custom shell"
    elif echo "$CUSTOM_SHELL_DEST" | grep -Eq '^/usr/(local/)?bin/[A-Za-z0-9._+-]+$'; then
        install -m 755 "$CUSTOM_SHELL_BIN" "$CUSTOM_SHELL_DEST" 2>/dev/null || cp "$CUSTOM_SHELL_BIN" "$CUSTOM_SHELL_DEST"
        chmod 755 "$CUSTOM_SHELL_DEST" 2>/dev/null || true

        # The login shell is the binary itself. /usr/bin/hellish is a symlink to
        # /usr/bin/hellish.real: the binary can be refreshed (first boot installs
        # the published release over it) without the passwd entry ever naming a
        # file that is mid-replacement, and `command -v hellish.real` keeps
        # naming the ELF for the tools that need one (Inception's Makefile copies
        # it into the containers). Earlier builds put a bash script here that
        # sent every non-interactive ssh command to bash; that made
        # `ssh b2b '<cmd>'`, scp's server side and the whole host-driven pipeline
        # run under bash in a VM whose point is hellish. hellish takes those
        # itself: `hellish -c 'scp -t …'`, and `hellish -c bash` for VS Code's
        # Remote-SSH bootstrap, which names bash explicitly.
        if [ "$(basename "$CUSTOM_SHELL_DEST")" = "hellish" ]; then
            CUSTOM_SHELL_REAL="${CUSTOM_SHELL_DEST}.real"
            if [ ! -L "$CUSTOM_SHELL_DEST" ]; then
                mv -f "$CUSTOM_SHELL_DEST" "$CUSTOM_SHELL_REAL" 2>/dev/null || cp "$CUSTOM_SHELL_DEST" "$CUSTOM_SHELL_REAL"
            fi
            chmod 755 "$CUSTOM_SHELL_REAL" 2>/dev/null || true
            ln -sfn "$CUSTOM_SHELL_REAL" "$CUSTOM_SHELL_DEST"

            # Keep a pristine copy outside /usr/bin so the shell guard in
            # sshd-watchdog can put the binary back. sshd refuses any account
            # whose login shell does not exist — it reports the user as an
            # "invalid user", which rejects key AND password auth AND the
            # console at the same time. A single `rm /usr/bin/hellish.real`
            # therefore locks every door on the machine at once, and the error it
            # produces ("Permission denied") points at credentials rather than
            # the shell.
            mkdir -p /usr/local/lib/b2b
            cp "$CUSTOM_SHELL_REAL" /usr/local/lib/b2b/hellish.real 2>/dev/null || true
            chmod 755 /usr/local/lib/b2b/hellish.real 2>/dev/null || true
            rm -f /usr/local/lib/b2b/shell-wrapper

            echo "[OK] $CUSTOM_SHELL_DEST -> $CUSTOM_SHELL_REAL: interactive logins and ssh commands alike run hellish"
        fi

        # Register the shell so chsh/usermod accepts it
        if [ -f /etc/shells ]; then
            grep -qxF "$CUSTOM_SHELL_DEST" /etc/shells || echo "$CUSTOM_SHELL_DEST" >>/etc/shells
        else
            echo "$CUSTOM_SHELL_DEST" >/etc/shells
        fi

        # Set default shell for the main user created by preseed
        if id dlesieur >/dev/null 2>&1; then
            usermod -s "$CUSTOM_SHELL_DEST" dlesieur 2>/dev/null || chsh -s "$CUSTOM_SHELL_DEST" dlesieur 2>/dev/null || true
            echo "[OK] Custom shell installed and set as default for dlesieur: $CUSTOM_SHELL_DEST"
        else
            echo "[WARN] User dlesieur not found — custom shell installed but not set as default"
        fi

        # Persist desired shell so first-boot can re-apply (if needed)
        printf 'B2B_CUSTOM_USER=%s\nB2B_CUSTOM_SHELL=%s\n' "dlesieur" "$CUSTOM_SHELL_DEST" >/etc/b2b_custom_shell.conf 2>/dev/null || true
        chmod 644 /etc/b2b_custom_shell.conf 2>/dev/null || true

        # Verify and log the result for debugging
        echo "[INFO] /etc/shells contains custom shell? $(grep -qxF "$CUSTOM_SHELL_DEST" /etc/shells 2>/dev/null && echo yes || echo no)"
        echo "[INFO] passwd entry: $(getent passwd dlesieur 2>/dev/null || echo '(missing)')"
    else
        echo "[WARN] custom shell dest looks unsafe ($CUSTOM_SHELL_DEST) — skipping"
    fi
else
    echo "[OK] No custom shell payload provided — keeping default shell (bash)"
fi

# ── The interpreter of everything this guest runs on its own ────────────────
# The monitoring cron job, the two systemd helpers, the first-boot hook and
# the provisioners it launches all run under the baked shell when there is
# one, and under bash otherwise -- decided here, once, and written into the
# scripts' shebangs and the crontab below, so that a guest built with hellish
# runs nothing under bash that it started itself. first-boot-setup.sh reads
# B2B_GUEST_SH from /etc/b2b_custom_shell.conf for the provisioners.
B2B_GUEST_SH=/bin/bash
if [ -n "${CUSTOM_SHELL_REAL:-}" ] && [ -x "$CUSTOM_SHELL_REAL" ]; then
    B2B_GUEST_SH="$CUSTOM_SHELL_REAL"
fi
if [ -f /etc/b2b_custom_shell.conf ]; then
    echo "B2B_GUEST_SH=$B2B_GUEST_SH" >>/etc/b2b_custom_shell.conf
fi
# pin_shebang <script>: make the script's first line name the guest interpreter.
pin_shebang() {
    [ -f "$1" ] || return 0
    sed -i "1s|^#!.*|#!$B2B_GUEST_SH|" "$1" 2>/dev/null || true
}
for f in /root/first-boot-setup.sh /root/install_*.sh; do
    pin_shebang "$f"
done
echo "[OK] Guest-side scripts run under $B2B_GUEST_SH"

# ═══════════════════════════════════════════════════════════════════════════
# BORN2BEROOT MANDATORY CONFIGURATION
# Everything below MUST succeed — no network downloads, no external deps.
# ═══════════════════════════════════════════════════════════════════════════

### ─── 3. Hostname — Born2beRoot requires login+42 ───────────────────────────
echo "dlesieur42" >/etc/hostname
hostname dlesieur42 2>/dev/null || true

# Fix /etc/hosts — replace any old hostname or add the correct one
if grep -q "127\.0\.1\.1" /etc/hosts 2>/dev/null; then
    sed -i 's/127\.0\.1\.1.*/127.0.1.1\tdlesieur42/' /etc/hosts
else
    echo "127.0.1.1	dlesieur42" >>/etc/hosts
fi
# Also ensure localhost line exists
grep -q "127\.0\.0\.1.*localhost" /etc/hosts ||
    sed -i '1i 127.0.0.1\tlocalhost' /etc/hosts
echo "[OK] Hostname set to dlesieur42"

### ─── 4. Groups & user ─────────────────────────────────────────────────────
groupadd user42 2>/dev/null || true
# Pre-create docker group NOW so dlesieur has it from the very first login.
# Docker is installed later by first-boot-setup.sh (needs systemd + network),
# but the GROUP must exist before the first SSH/VS Code session or the VS Code
# server process inherits a stale group list without docker → "permission denied"
# on /var/run/docker.sock. Docker's postinst will reuse this group.
groupadd -f docker 2>/dev/null || true
usermod -aG sudo,user42,docker dlesieur
echo "[OK] User dlesieur in groups: sudo, user42, docker"

### ─── 5. SSH — port 4242, no root login ─────────────────────────────────────
sed -i 's/^#*Port .*/Port 4242/' /etc/ssh/sshd_config
grep -q "^Port 4242" /etc/ssh/sshd_config || echo "Port 4242" >>/etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config

# ── SSH keepalive + VS Code Remote SSH settings ────────────────────────────
# VirtualBox NAT drops idle TCP mappings after ~5-15 min. We need aggressive
# keepalives on BOTH sides to keep the NAT connection tracking alive.
# Server sends keepalive every 30s, client sends every 15s (in ~/.ssh/config).
#
# VS Code Remote SSH opens MANY parallel connections (SOCKS proxy, exec server,
# tunnels, extension host). MaxStartups must be high or VS Code fails to reconnect.
# MaxStartups 50:30:100 = accept 50 unauthenticated, 30% drop until 100.
for setting in \
    "ClientAliveInterval 30" \
    "ClientAliveCountMax 5" \
    "TCPKeepAlive yes" \
    "MaxStartups 50:30:100" \
    "MaxSessions 20" \
    "LoginGraceTime 300"; do
    key=$(echo "$setting" | awk '{print $1}')
    sed -i "/^#*${key} /d" /etc/ssh/sshd_config
    echo "$setting" >>/etc/ssh/sshd_config
done

# Systemd: ensure sshd restarts automatically on failure + watchdog
mkdir -p /etc/systemd/system/ssh.service.d
cat >/etc/systemd/system/ssh.service.d/override.conf <<'EOF'
[Service]
Restart=always
RestartSec=3
StartLimitIntervalSec=60
StartLimitBurst=10
EOF

# Kernel TCP keepalive — aggressive values to keep VirtualBox NAT alive
# tcp_keepalive_time=60 → first probe after 60s idle (not default 7200!)
# tcp_keepalive_intvl=15 → re-probe every 15s
# tcp_keepalive_probes=5 → 5 failed probes = dead
cat >/etc/sysctl.d/99-ssh-keepalive.conf <<'EOF'
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=15
net.ipv4.tcp_keepalive_probes=5
EOF
sysctl --system >/dev/null 2>&1 || true

# ── NAT keepalive service ──────────────────────────────────────────────────
# Periodically ping the gateway to keep VirtualBox NAT engine's connection
# tracking table active. This prevents NAT from silently dropping SSH mappings.
cat >/usr/local/bin/nat-keepalive.sh <<'NKEOF'
#!/bin/bash
# Keep VirtualBox NAT alive by pinging gateway every 30 seconds
GW=$(ip route | awk '/default/ {print $3}' | head -1)
[ -z "$GW" ] && GW="10.0.2.2"
while true; do
    ping -c 1 -W 2 "$GW" >/dev/null 2>&1
    sleep 30
done
NKEOF
chmod +x /usr/local/bin/nat-keepalive.sh
pin_shebang /usr/local/bin/nat-keepalive.sh

cat >/etc/systemd/system/nat-keepalive.service <<'NKSEOF'
[Unit]
Description=Keep VirtualBox NAT connection tracking alive
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/nat-keepalive.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
NKSEOF
systemctl enable nat-keepalive 2>/dev/null || true

# ── SSHD Watchdog — monitors and auto-restarts sshd if it dies ──────────────
# VS Code Remote SSH can cause sshd to become unresponsive. This watchdog
# checks every 15 seconds and auto-restarts if sshd stops listening.
cat >/usr/local/bin/sshd-watchdog.sh <<'WDEOF'
#!/bin/bash
LOG=/var/log/sshd-watchdog.log
echo "$(date): watchdog started (pid=$$)" >> "$LOG"
while true; do
    SSHD_ACTIVE=$(systemctl is-active ssh 2>/dev/null)
    SSHD_COUNT=$(pgrep -c sshd 2>/dev/null || echo 0)
    LISTEN=$(ss -tlnp 2>/dev/null | grep -c 4242)
    ESTAB=$(ss -tnp 2>/dev/null | grep -c 4242)
    MEM_FREE=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null)
    if [ "$SSHD_ACTIVE" != "active" ] || [ "$LISTEN" = "0" ]; then
        echo "$(date): ALERT sshd=$SSHD_ACTIVE procs=$SSHD_COUNT listen=$LISTEN estab=$ESTAB mem_free=${MEM_FREE}kB" >> "$LOG"
        systemctl restart ssh >> "$LOG" 2>&1
        echo "$(date): sshd restart attempted, new_status=$(systemctl is-active ssh)" >> "$LOG"
    fi
    # Login-shell guard. sshd rejects an account whose shell is missing as an
    # "invalid user", which kills key auth, password auth and console login in
    # one stroke -- with no hint that the shell is the cause. Rebuilding a
    # custom shell in place is routine here, so treat a missing one as a fault
    # to repair rather than a state to sit in.
    USER_SHELL=$(getent passwd dlesieur 2>/dev/null | cut -d: -f7)
    if [ -n "$USER_SHELL" ] && [ ! -x "$USER_SHELL" ]; then
        if [ ! -x "${USER_SHELL}.real" ] && [ -x /usr/local/lib/b2b/hellish.real ]; then
            install -m 755 /usr/local/lib/b2b/hellish.real "${USER_SHELL}.real" 2>> "$LOG"
            echo "$(date): ${USER_SHELL}.real was missing -- restored from /usr/local/lib/b2b" >> "$LOG"
        fi
        if [ -x "${USER_SHELL}.real" ]; then
            ln -sfn "${USER_SHELL}.real" "$USER_SHELL" 2>> "$LOG"
            echo "$(date): login shell $USER_SHELL was missing -- link to ${USER_SHELL}.real restored" >> "$LOG"
        else
            # Nothing to restore from: fall back to bash so the box stays
            # reachable. Losing the custom shell beats losing all access.
            usermod -s /bin/bash dlesieur 2>> "$LOG"
            echo "$(date): login shell $USER_SHELL missing and unrecoverable -- fell back to /bin/bash" >> "$LOG"
        fi
    fi

    MIN=$(date +%M); SEC=$(date +%S)
    if [ "$((MIN % 5))" = "0" ] && [ "$SEC" -lt "16" ]; then
        echo "$(date): OK sshd=$SSHD_ACTIVE procs=$SSHD_COUNT listen=$LISTEN estab=$ESTAB mem=${MEM_FREE}kB" >> "$LOG"
    fi
    sleep 15
done
WDEOF
chmod +x /usr/local/bin/sshd-watchdog.sh
pin_shebang /usr/local/bin/sshd-watchdog.sh

cat >/etc/systemd/system/sshd-watchdog.service <<'SWEOF'
[Unit]
Description=SSHD health watchdog with auto-restart
After=ssh.service
Requires=ssh.service

[Service]
Type=simple
ExecStart=/usr/local/bin/sshd-watchdog.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SWEOF
systemctl enable sshd-watchdog 2>/dev/null || true

# ── Silence systemd-ssh-generator AF_VSOCK warning ─────────────────────────
# Debian 13 (systemd >= 256) ships systemd-ssh-generator, which on every boot
# tries to set up SSH-over-AF_VSOCK. VirtualBox guests expose no virtio-vsock
# device, so it logs "failed to query local AF_VSOCK CID" — harmless noise that
# looks like a boot failure. We only use sshd on 4242 over NAT, never vsock SSH,
# so disable the generator the documented way: symlink it to /dev/null.
mkdir -p /etc/systemd/system-generators
ln -sf /dev/null /etc/systemd/system-generators/systemd-ssh-generator
echo "[OK] Disabled systemd-ssh-generator (no AF_VSOCK in VirtualBox)"

systemctl enable ssh || true
systemctl daemon-reload || true
systemctl restart ssh || true
echo "[OK] SSH configured on port 4242 (keepalives + NAT keepalive + sshd watchdog)"

### ─── 5b. SSH key auth — bake host's public key for passwordless login ──────
# This enables VS Code Remote SSH to reconnect instantly without password prompts.
# The key is from the host machine that runs `make all`.
HOST_PUBKEY_DIR="/home/dlesieur/.ssh"
mkdir -p "$HOST_PUBKEY_DIR"
chmod 700 "$HOST_PUBKEY_DIR"
chown dlesieur:dlesieur "$HOST_PUBKEY_DIR"

# The orchestrator will inject the actual key at ISO creation time.
# late_command copies it from /cdrom/host_ssh_pubkey to /target/tmp/host_ssh_pubkey
# Since b2b-setup.sh runs inside in-target (chroot), the file is at /tmp/
if [ -f /tmp/host_ssh_pubkey ]; then
    cat /tmp/host_ssh_pubkey >>"$HOST_PUBKEY_DIR/authorized_keys"
    chmod 600 "$HOST_PUBKEY_DIR/authorized_keys"
    chown dlesieur:dlesieur "$HOST_PUBKEY_DIR/authorized_keys"
    echo "[OK] Host SSH public key installed for dlesieur"
else
    echo "[WARN] No host SSH public key found at /tmp/host_ssh_pubkey — password auth only"
fi

# Ensure PubkeyAuthentication is enabled in sshd_config
sed -i 's/^#*PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
grep -q '^PubkeyAuthentication' /etc/ssh/sshd_config || echo 'PubkeyAuthentication yes' >>/etc/ssh/sshd_config

### ─── 6. UFW — only port 4242 + web ports + dev ports ───────────────────────
ufw default deny incoming
ufw default allow outgoing
ufw allow 4242/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw allow 5173/tcp comment 'Vite Frontend'
ufw allow 3000/tcp comment 'Backend API'
ufw allow 3001/tcp comment 'osionos app'
ufw allow 3002/tcp comment 'osionos Mail'
ufw allow 3003/tcp comment 'osionos Calendar'
ufw allow 4000/tcp comment 'osionos bridge API'
ufw allow 4100/tcp comment 'Mail bridge'
ufw allow 4200/tcp comment 'Calendar bridge'
ufw allow 4322/tcp comment 'Website'
ufw allow 8000/tcp comment 'BaaS gateway'
ufw allow 8001/tcp comment 'BaaS admin'
ufw allow 8025/tcp comment 'Local mail inbox'
ufw allow 8787/tcp comment 'Auth gateway'
ufw allow 18200/tcp comment 'Vault'
echo y | ufw enable
echo "[OK] UFW firewall active"

### ─── 7. Sudo — strict rules per subject ───────────────────────────────────
mkdir -p /var/log/sudo
chmod 700 /var/log/sudo

cat >/etc/sudoers.d/sudo_config <<'SUDOEOF'
Defaults	passwd_tries=3
Defaults	badpass_message="Wrong password. Access denied!"
Defaults	logfile="/var/log/sudo/sudo.log"
Defaults	log_input,log_output
Defaults	iolog_dir="/var/log/sudo"
Defaults	requiretty
Defaults	secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"
SUDOEOF
chmod 440 /etc/sudoers.d/sudo_config
echo "[OK] Sudo configured"

### ─── 8. Password policy ───────────────────────────────────────────────────
# login.defs — password aging
sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS\t30/' /etc/login.defs
sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS\t2/' /etc/login.defs
sed -i 's/^PASS_WARN_AGE.*/PASS_WARN_AGE\t7/' /etc/login.defs

# pwquality.conf — complexity (use robust sed + fallback append)
for setting in \
    "minlen = 10" \
    "dcredit = -1" \
    "ucredit = -1" \
    "lcredit = -1" \
    "maxrepeat = 3" \
    "usercheck = 1" \
    "difok = 7" \
    "enforce_for_root"; do
    key=$(echo "$setting" | cut -d= -f1 | xargs)
    if grep -q "^#* *${key}" /etc/security/pwquality.conf 2>/dev/null; then
        sed -i "s/^#* *${key}.*/${setting}/" /etc/security/pwquality.conf
    else
        echo "$setting" >>/etc/security/pwquality.conf
    fi
done
echo "[OK] Password policy set"

### ─── 9. tmux — persistent sessions (survive SSH drops) ────────────────────
# Already installed in developer tools above; this is a safety net
if ! command -v tmux >/dev/null 2>&1; then
    $APT tmux || true
fi

# tmux config for user dlesieur — sane defaults for dev work
TMUX_CONF="/home/dlesieur/.tmux.conf"
cat >"$TMUX_CONF" <<'TMUXEOF'
# ── Born2beRoot tmux config ──────────────────────────────────
# Reload: tmux source ~/.tmux.conf

# Use C-a as prefix (like screen), keep C-b as well
set -g prefix2 C-a
bind C-a send-prefix -2

# 256-color + true-color support
set -g default-terminal "tmux-256color"
set -ga terminal-overrides ",xterm-256color:Tc"

# Mouse support (scrolling, clicking panes, resizing)
set -g mouse on

# Start windows/panes at 1 (not 0)
set -g base-index 1
setw -g pane-base-index 1

# Renumber windows when one is closed
set -g renumber-windows on

# Longer scrollback buffer (50k lines)
set -g history-limit 50000

# Faster key repetition
set -sg escape-time 0

# Activity monitoring
setw -g monitor-activity on
set -g visual-activity off

# Status bar
set -g status-style "bg=#1a1b26,fg=#a9b1d6"
set -g status-left "#[bold,fg=#7aa2f7] #S "
set -g status-right "#[fg=#565f89] %H:%M │ #h "
set -g status-left-length 30
set -g status-right-length 40

# Pane borders
set -g pane-border-style "fg=#3b4261"
set -g pane-active-border-style "fg=#7aa2f7"

# Easy split bindings (use current path)
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"

# Easy pane navigation (vim-like)
bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R

# Easy window navigation
bind -n M-Left  previous-window
bind -n M-Right next-window

# Reload config
bind r source-file ~/.tmux.conf \; display "Config reloaded!"
TMUXEOF
chown dlesieur:dlesieur "$TMUX_CONF"

# Auto-attach to tmux on interactive SSH login (for user dlesieur)
# This goes in .bashrc — only activates on interactive login, NOT in scripts
BASHRC="/home/dlesieur/.bashrc"
if ! grep -q 'TMUX_AUTO_ATTACH' "$BASHRC" 2>/dev/null; then
    cat >>"$BASHRC" <<'BASHEOF'

# ── tmux auto-attach (SSH sessions survive disconnects) ──────
# Only in interactive SSH sessions, not in scripts or VS Code integrated terminal
TMUX_AUTO_ATTACH=1
if [ -n "$SSH_CONNECTION" ] && [ -z "$TMUX" ] && [ -z "$VSCODE_INJECTION" ] && [ -t 0 ]; then
    # Try to attach to existing 'dev' session, or create one
    tmux has-session -t dev 2>/dev/null && exec tmux attach -t dev || exec tmux new -s dev
fi
BASHEOF
fi
chown dlesieur:dlesieur "$BASHRC"

echo "[OK] tmux configured with auto-attach for dlesieur"

### ─── 10. Git config (fix NAT large-clone stalls) ──────────────────────────
git config --system http.postBuffer 524288000
git config --system http.lowSpeedLimit 1000
git config --system http.lowSpeedTime 60
git config --system core.compression 0
echo "[OK] Git configured"

### ─── 11. Monitoring script ────────────────────────────────────────────────
# Already copied to /usr/local/bin/monitoring.sh by late_command
chmod +x /usr/local/bin/monitoring.sh 2>/dev/null || true
pin_shebang /usr/local/bin/monitoring.sh

# Crontab: every 10 minutes, broadcast to all terminals. cron runs every
# line as `$SHELL -c '<line>'`, and Debian's crontab says SHELL=/bin/sh: that
# is dash, started for each job before the script's own shebang is read. The
# guest shell takes that seat too, so nothing the guest starts itself passes
# through another shell -- first boot's @reboot line included.
sed -i "s|^SHELL=.*|SHELL=$B2B_GUEST_SH|" /etc/crontab
grep -q '^SHELL=' /etc/crontab || sed -i "1i SHELL=$B2B_GUEST_SH" /etc/crontab
echo "*/10 * * * * root /usr/local/bin/monitoring.sh" >>/etc/crontab
echo "[OK] Monitoring cron set (SHELL=$B2B_GUEST_SH)"

### ─── 12. Lighttpd + PHP-FPM + WordPress routing ────────────────────────────
# Detect installed PHP-FPM version and socket path
PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.2")
PHP_SOCK="/run/php/php${PHP_VER}-fpm.sock"

# Enable mod_fastcgi (base module)
lighty-enable-mod fastcgi </dev/null 2>/dev/null || true

# DISABLE the stock fastcgi-php config — it uses php-cgi, NOT php-fpm,
# and creates a conflicting fastcgi.server entry for ".php".
lighty-disable-mod fastcgi-php </dev/null 2>/dev/null || true
rm -f /etc/lighttpd/conf-enabled/15-fastcgi-php.conf

# Also remove the default "unconfigured" placeholder page
rm -f /etc/lighttpd/conf-enabled/99-unconfigured.conf

# Create a single, clean WordPress + PHP-FPM config
# This is the ONLY file that defines how PHP is served.
cat >/etc/lighttpd/conf-available/99-wordpress.conf <<WPLIGHT
# ── WordPress + PHP-FPM on Lighttpd ──────────────────────────
# Load required modules (mod_fastcgi is loaded by 10-fastcgi.conf)
server.modules += ( "mod_rewrite" )

# PHP-FPM via Unix socket (the only PHP handler — no php-cgi)
fastcgi.server += ( ".php" =>
    (( "socket" => "${PHP_SOCK}",
       "broken-scriptfilename" => "enable"
    ))
)

# Root redirect: / → /wordpress/
url.redirect = ( "^/$" => "/wordpress/" )

# WordPress pretty permalinks — protect wp-admin/wp-content/wp-includes
# directories from being rewritten (they are directories, not files, so
# url.rewrite-if-not-file would catch them and break wp-admin).
url.rewrite-if-not-file = (
    "^/wordpress/wp-admin(.*)"    => "/wordpress/wp-admin\$1",
    "^/wordpress/wp-includes(.*)" => "/wordpress/wp-includes\$1",
    "^/wordpress/wp-content(.*)"  => "/wordpress/wp-content\$1",
    "^/wordpress/(.*\\.php.*)"    => "/wordpress/\$1",
    "^/wordpress/(.*)"            => "/wordpress/index.php/\$1"
)

# Default index file
index-file.names += ( "index.php" )

# Allow uploads up to 32 MB
server.max-request-size = 32768
WPLIGHT

# Enable the config (create symlink)
ln -sf /etc/lighttpd/conf-available/99-wordpress.conf \
    /etc/lighttpd/conf-enabled/99-wordpress.conf 2>/dev/null || true

# Ensure lighttpd listens on port 80
if ! grep -q 'server.port' /etc/lighttpd/lighttpd.conf 2>/dev/null; then
    echo 'server.port = 80' >>/etc/lighttpd/lighttpd.conf
fi
echo "[OK] Lighttpd + PHP-FPM + WordPress routing configured"

### ─── 13. AppArmor — mandatory at startup + enforce profiles ────────────────
systemctl enable apparmor || true

# Create enforcement-ready AppArmor profile for PHP-FPM
mkdir -p /etc/apparmor.d
cat >/etc/apparmor.d/local/usr.sbin.php-fpm 2>/dev/null <<'AAEOF' || true
# Allow PHP-FPM to serve WordPress
/var/www/html/wordpress/** r,
/var/www/html/wordpress/wp-content/uploads/** rw,
/var/www/html/wordpress/wp-content/cache/** rw,
/tmp/** rw,
/run/php/** rw,
AAEOF

# Enforce AppArmor profiles if they exist
for profile in usr.sbin.php-fpm${PHP_VER} usr.sbin.lighttpd; do
    if [ -f "/etc/apparmor.d/${profile}" ]; then
        aa-enforce "/etc/apparmor.d/${profile}" 2>/dev/null || true
    fi
done
echo "[OK] AppArmor enabled + WordPress profiles configured"

### ─── 14. Enable all services (NO restart — no systemd in chroot) ──────────
for svc in lighttpd mariadb haveged cron ssh nat-keepalive sshd-watchdog; do
    systemctl enable "$svc" 2>/dev/null || true
done
for f in /lib/systemd/system/php*-fpm.service; do
    if [ -f "$f" ]; then
        systemctl enable "$(basename "$f")" 2>/dev/null || true
    fi
done
# Disable conflict docker services
systemctl disable postgresql 2>/dev/null || true
systemctl disable redis-server 2>/dev/null || true
echo "[OK] Services enabled"

### ─── 15. First-boot script (Docker + WordPress) ───────────────────────────
# Already copied to /root/first-boot-setup.sh by late_command
chmod +x /root/first-boot-setup.sh 2>/dev/null || true
echo "@reboot root $B2B_GUEST_SH /root/first-boot-setup.sh" >>/etc/crontab
echo "[OK] First-boot hook registered"

### ─── 16. MOTD ─────────────────────────────────────────────────────────────
cat >/etc/motd <<'MOTDEOF'

  ╔═══════════════════════════════════════════════════════╗
  ║            BORN2BEROOT SECURE SYSTEM                  ║
  ╠═══════════════════════════════════════════════════════╣
  ║  Hostname:   dlesieur42      SSH Port: 4242           ║
  ║  Firewall:   Active (UFW)    AppArmor: Enforced       ║
  ║  Monitoring: Every 10 min    Sudo log: /var/log/sudo/ ║
  ╠═══════════════════════════════════════════════════════╣
  ║  🔒 tmux auto-attach is ON                            ║
  ║                                                       ║
  ║  Your session runs inside tmux and survives SSH drops.║
  ║  If disconnected, just reconnect — you'll be right    ║
  ║  back where you left off.                             ║
  ║                                                       ║
  ║  Quick reference:                                     ║
  ║    Ctrl+B d    → detach (leave session running)       ║
  ║    Ctrl+B |    → split pane horizontally              ║
  ║    Ctrl+B -    → split pane vertically                ║
  ║    Ctrl+B c    → new window                           ║
  ║    Ctrl+B n/p  → next/previous window                 ║
  ║    tmux ls     → list sessions                        ║
  ╠═══════════════════════════════════════════════════════╣
  ║  WARNING: All actions are logged.                     ║
  ╚═══════════════════════════════════════════════════════╝

MOTDEOF
# Below the box: the layout this guest was built with, so the numbers are one
# login away. Written after the layout file exists (see the block further
# down), which is why this is a hook rather than static text.
cat >/etc/update-motd.d/90-b2b-layout <<'MOTDLAYOUT'
#!/bin/sh
[ -r /etc/b2b/layout ] || exit 0
echo "  Disk layout (from /etc/b2b/layout):"
sed -n '2,$p' /etc/b2b/layout | sed 's/^/    /'
[ -r /etc/b2b/features.conf ] && echo "  Profile: $(sed -n 's/^B2B_PROFILE=//p' /etc/b2b/features.conf)  (features: /etc/b2b/features.conf)"
[ -r /etc/b2b/PROVISION_FAILED ] && echo "  !! PROVISIONING FAILED: see /etc/b2b/PROVISION_FAILED"
echo
MOTDLAYOUT
chmod +x /etc/update-motd.d/90-b2b-layout
echo "[OK] MOTD set"

echo "=== Born2beRoot MANDATORY configuration complete ($(date)) ==="

# ═══════════════════════════════════════════════════════════════════════════
# OPTIONAL third-party tools (mongodb, kubectl, pipx, golangci-lint, helm)
# are NOT installed here. They consumed 1.5+ GB on / and caused the root
# partition to fill up, breaking dpkg and GRUB in a cascading failure loop.
# They are now installed by first-boot-setup.sh with disk space guards.
# ═══════════════════════════════════════════════════════════════════════════

### ─── MAKE DISCARD REACH THE IMAGE ──────────────────────────────────────────
# A qcow2 only stays small while something tells it which blocks are free.
# Nothing did, and the bill was measured: disk_images/debian/debian.qcow2 grew
# to 42.7 GB on the host for a guest holding a small fraction of that, and it
# could never shrink again.
#
# The break was at the encryption layer. QEMU already attaches the disk with
# discard=unmap (see setup/host/qemu_vm.sh), so a TRIM from the guest would be
# honoured -- but dm-crypt DISCARDS the discard unless the mapping was opened
# with allow-discards, and nothing asked for it. Every layer above was equally
# silent: no `discard` in /etc/crypttab, no issue_discards in lvm.conf, no
# fstrim.timer. So the image only ever grew, and because a freed block under
# LUKS is ciphertext rather than zeroes, `qemu-img convert` could not reclaim
# it afterwards either. There was no way back short of rebuilding the VM.
#
# All four links are wired up here. Miss any one and the whole chain is inert
# while looking perfectly configured, which is exactly how this went unnoticed.
#
# The tradeoff is real and worth stating: allow-discards lets someone with raw
# access to the disk image see which blocks are in use, and so infer roughly
# how full the volume is and where the data sits. It does not reveal file
# contents. For a VM on a quota'd school filesystem that is the right trade.
#
# This block detects encryption rather than being told about it, so it is
# correct for both LUKS=ON and LUKS=OFF builds (see utils/luks_mode.sh).
echo "[INFO] Wiring discard through the storage stack"

# ── 1. LUKS: allow-discards on the mapping ──────────────────────────────────
# Only meaningful when there IS a crypt device. On a LUKS=OFF build the file
# is absent or has no device line, and the rest of the chain still applies.
CRYPT_DEV=""
if [ -f /etc/crypttab ]; then
    CRYPT_DEV=$(awk '!/^[[:space:]]*#/ && NF >= 2 { print $1; exit }' /etc/crypttab)
fi

if [ -z "$CRYPT_DEV" ]; then
    echo "[INFO] No LUKS mapping — unencrypted build, skipping crypttab"
else
    if awk -v d="$CRYPT_DEV" '!/^[[:space:]]*#/ && $1 == d && $4 ~ /discard/' /etc/crypttab | grep -q .; then
        echo "[OK] crypttab already passes discard for $CRYPT_DEV"
    else
        cp /etc/crypttab /etc/crypttab.b2b-backup 2>/dev/null || true
        # Field 4 is the options list and may be empty, "none", or a real list.
        # "none" is a placeholder meaning no options, so appending to it would
        # produce the literal "none,discard" — replace it instead of extending.
        awk -v d="$CRYPT_DEV" '
            !/^[[:space:]]*#/ && $1 == d {
                if (NF < 4 || $4 == "" || $4 == "none") { $4 = "discard" }
                else if ($4 !~ /(^|,)discard(,|$)/) { $4 = $4 ",discard" }
                print; next
            }
            { print }
        ' /etc/crypttab.b2b-backup >/etc/crypttab
        echo "[OK] crypttab: discard enabled for $CRYPT_DEV"
    fi

    # ── 2. The initrd is what actually opens the root mapping ───────────────
    # Editing crypttab alone changes nothing for the root device: the initrd
    # carries its own copy and unlocks the volume long before the on-disk file
    # is readable. This is the step that makes the change real -- and the one
    # that can leave the VM unbootable if it half-succeeds, so its result is
    # checked rather than assumed, the same way the GRUB block below checks
    # that grub.cfg came out with menu entries in it.
    INITRD_BEFORE=$(find /boot -maxdepth 1 -name 'initrd.img-*' 2>/dev/null | wc -l)
    if update-initramfs -u -k all 2>&1; then
        INITRD_AFTER=$(find /boot -maxdepth 1 -name 'initrd.img-*' 2>/dev/null | wc -l)
        if [ "$INITRD_AFTER" -ge 1 ] && [ "$INITRD_AFTER" -ge "$INITRD_BEFORE" ]; then
            echo "[OK] initramfs rebuilt ($INITRD_AFTER image(s)) — discard reaches the crypt layer"
        else
            echo "[WARN] initramfs count went $INITRD_BEFORE → $INITRD_AFTER — check /boot before rebooting"
        fi
    else
        # Not fatal on its own: the system still boots from the existing initrd,
        # it just will not pass discards. Say so precisely rather than failing
        # the whole install over a space optimisation.
        echo "[WARN] update-initramfs failed — the VM still boots, but TRIM will not"
        echo "[WARN] reach the image. Re-run: sudo update-initramfs -u -k all"
    fi
fi

# ── 3. LVM: hand freed extents back on lvremove/lvreduce ────────────────────
if [ -f /etc/lvm/lvm.conf ]; then
    if grep -qE '^[[:space:]]*issue_discards[[:space:]]*=[[:space:]]*1' /etc/lvm/lvm.conf; then
        echo "[OK] lvm.conf already sets issue_discards = 1"
    elif grep -qE '^[[:space:]]*#?[[:space:]]*issue_discards[[:space:]]*=' /etc/lvm/lvm.conf; then
        # Debian ships the key only as its commented default, `# issue_discards = 0`,
        # inside the devices { } section. Uncommenting it in place keeps it in
        # that section; the previous pattern skipped the commented form and
        # left every guest with the default (measured on trixie: no-op).
        sed -i -E 's|^([[:space:]]*)#?[[:space:]]*issue_discards[[:space:]]*=.*|\1issue_discards = 1|' /etc/lvm/lvm.conf
        echo "[OK] lvm.conf: issue_discards = 1"
    else
        echo "[WARN] no issue_discards key in lvm.conf — leaving the file alone"
    fi
fi

# ── 4. ext4: periodic TRIM ──────────────────────────────────────────────────
# fstrim.timer (weekly, batched) rather than the `discard` mount option: the
# mount option trims synchronously on every delete, which costs latency on
# every unlink for a benefit that only matters in aggregate.
if systemctl enable fstrim.timer 2>/dev/null; then
    echo "[OK] fstrim.timer enabled — weekly TRIM of every mounted filesystem"
else
    # systemd is not running in the installer chroot, so `enable` can fail here
    # and still be wanted. Link the unit by hand so first boot picks it up.
    for UNITDIR in /lib/systemd/system /usr/lib/systemd/system; do
        if [ -f "$UNITDIR/fstrim.timer" ]; then
            mkdir -p /etc/systemd/system/timers.target.wants
            ln -sf "$UNITDIR/fstrim.timer" \
                /etc/systemd/system/timers.target.wants/fstrim.timer 2>/dev/null || true
            echo "[OK] fstrim.timer linked for first boot (no systemd in chroot)"
            break
        fi
    done
fi

# ── 5. swap: release freed pages ────────────────────────────────────────────
# Swap is written early and never freed back on its own, so without this the
# whole swap volume stays allocated in the image for the life of the VM.
if grep -qE '^[^#].*[[:space:]]swap[[:space:]]' /etc/fstab 2>/dev/null; then
    if grep -qE '^[^#].*[[:space:]]swap[[:space:]]+.*discard' /etc/fstab; then
        echo "[OK] fstab swap already mounts with discard"
    else
        cp /etc/fstab /etc/fstab.b2b-swap-backup 2>/dev/null || true
        awk '
            !/^[[:space:]]*#/ && $3 == "swap" {
                if ($4 == "" || $4 == "defaults") { $4 = "discard" }
                else if ($4 !~ /(^|,)discard(,|$)/) { $4 = $4 ",discard" }
                print; next
            }
            { print }
        ' /etc/fstab.b2b-swap-backup >/etc/fstab
        echo "[OK] fstab: swap mounts with discard"
    fi
fi

# ── 6. Give back the 5% root reserve on the data filesystems ────────────────
# ext4 reserves 5% for root so a full disk cannot lock out the administrator.
# That is worth keeping on / — it is what stops a runaway log wedging the
# system — but on /home, /var, /srv, /opt and /tmp it is several hundred MB
# held back for nothing on a disk this size. 1% keeps the safety margin.
for LV in home var srv opt tmp var-log; do
    DEV="/dev/LVMGroup/$LV"
    [ -b "$DEV" ] || continue
    if tune2fs -m 1 "$DEV" >/dev/null 2>&1; then
        echo "[OK] $LV: root reserve 5% → 1%"
    fi
done

### ─── RECORD THE LAYOUT THE GUEST WAS BUILT WITH ─────────────────────────────
# From what LVM actually created, not from the recipe: partman rounds to
# physical extents, and the honest number is the one on the disk. Read it in
# the guest with `cat /etc/b2b/layout`, or see it on the MOTD.
{
    echo "# /etc/b2b/layout — what this VM was built with (profile: $B2B_PROFILE, SIZE_B2B=${B2B_SIZE_GB:-?})"
    echo "# volume  size  mount    — move space with: lvreduce -r / lvextend -r"
    vgs --noheadings --units m -o vg_name,vg_size,vg_free LVMGroup 2>/dev/null | awk '{ printf "vg      %-6s total, %s free\n", $2, $3 }'
    lvs --noheadings --units m -o lv_name,lv_size LVMGroup 2>/dev/null | while read -r lv sz; do
        mp=$(awk -v d="/dev/mapper/LVMGroup-$(printf '%s' "$lv" | sed 's/-/--/g')" '$1 == d { print $2 }' /etc/fstab 2>/dev/null)
        printf '%-8s %-7s %s\n' "$lv" "$sz" "${mp:-[SWAP]}"
    done
} >/etc/b2b/layout 2>/dev/null && echo "[OK] layout recorded in /etc/b2b/layout" || echo "[WARN] could not record the layout"

### ─── GRUB SAFETY NET ────────────────────────────────────────────────────────
# After all package installs (which may have upgraded kernel/initramfs/grub),
# ensure GRUB is properly installed and grub.cfg is regenerated.
# This prevents the dreaded "grub>" rescue shell on first boot.
echo "--- GRUB safety net: ensuring bootloader is properly configured ---"

# Fix any broken packages first (a broken dpkg = broken grub-install)
dpkg --configure -a 2>/dev/null || true
apt-get install -y -f 2>/dev/null || true

# Detect the boot disk
BOOT_DISK=$(mount | grep ' /boot ' | awk '{print $1}' | sed 's/[0-9]*$//' 2>/dev/null)
if [ -z "$BOOT_DISK" ]; then
    BOOT_DISK="/dev/sda"
fi
echo "[INFO] Reinstalling GRUB to $BOOT_DISK"

# Reinstall GRUB to MBR
grub-install "$BOOT_DISK" 2>&1 || echo "[WARN] grub-install failed (may be OK in chroot)"

### ─── SERIAL CONSOLE ON THE INSTALLED SYSTEM ─────────────────────────────────
# The host never opens a VirtualBox window, so mirror the boot to COM1, which
# VirtualBox spools into disk_images/<vm>/serial.log on the host — that is what
# `make console` tails. It turns "the VM is running but I cannot see anything"
# into a readable boot log.
#
# ORDER IS LOAD-BEARING: the LAST console= on the command line becomes
# /dev/console, and the initramfs reads the LUKS passphrase from /dev/console.
# The host answers that prompt by typing on the VM's *virtual keyboard*
# (VBoxManage controlvm keyboardputstring, see unlock_vm.sh), and those
# keystrokes arrive on tty0, not on the serial line. So tty0 must come last:
# with ttyS0 last the prompt would move to a serial port nothing types into and
# the VM would sit locked forever.
echo "--- Enabling serial console mirror (tty0 stays primary) ---"
if [ -f /etc/default/grub ]; then
    SERIAL_ARGS="console=ttyS0,115200n8 console=tty0"
    if ! grep -q 'console=ttyS0' /etc/default/grub; then
        # Only the kernel command line is touched. GRUB_TERMINAL="console serial"
        # would also put GRUB's own menu on the serial port, but if GRUB's serial
        # init does not come up the bootloader can end up drawing to nothing at
        # all — a black screen and an unbootable VM, diagnosable only by a
        # 40-minute rebuild. The kernel's console= is what produces the boot log
        # `make console` reads, so the menu buys nothing for the risk.
        #
        # Strip "quiet" too: on a headless box the boot messages are the only
        # way to see how far the boot got.
        sed -i \
            -e "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${SERIAL_ARGS}\"|" \
            /etc/default/grub
        echo "[OK] serial console mirror configured"
    else
        echo "[OK] serial console already configured"
    fi
fi

# Regenerate grub.cfg — critical to pick up any kernel changes
update-grub 2>&1 || echo "[WARN] update-grub failed (may be OK in chroot)"

# Verify grub.cfg exists and has menu entries
if [ -f /boot/grub/grub.cfg ]; then
    MENU_COUNT=$(grep -c 'menuentry ' /boot/grub/grub.cfg 2>/dev/null || echo 0)
    echo "[OK] grub.cfg exists with $MENU_COUNT menu entries"
else
    echo "[WARN] /boot/grub/grub.cfg NOT found — GRUB may fail on boot!"
fi

echo "=== Born2beRoot setup FULLY complete ($(date)) ==="
