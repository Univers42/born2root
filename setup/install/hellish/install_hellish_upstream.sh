#!/usr/bin/env hellish
# ============================================================================ #
#  install_hellish_upstream.sh — install hellish IN THE VM from upstream       #
# ============================================================================ #
#
# Runs on the first real boot, as root, with a working network. It replaces
# the ISO-baked binary as the *source* of the shell:
#
#     curl -fsSL https://raw.githubusercontent.com/Univers42/hellish/main/install.sh | sh
#
# WHY --yes AND NOT A KEYSTROKE SEQUENCE
#   The installer asks up to four questions, and it reads them from /dev/tty so
#   that `curl | sh` can still prompt. Piping "y y <password> y a" at it is
#   fragile: the questions are conditional, so a changed condition silently
#   shifts the answers by one. The installer already solves this itself:
#
#     --yes   sets ASSUME_YES=1, which forces INTERACTIVE=0 — every question
#             is skipped and its DEFAULT is taken. The defaults are the same
#             answers the manual sequence was aiming for:
#               "do you have sudo rights?"        not asked at all: we are root
#               "register hellish as login shell" default yes
#               "install the plugin framework"    default yes
#               "[a]ll / [c]hoose / [n]one"       "all"
#
#   The <password> in that sequence was sudo's. Running as root removes the
#   question, so nothing here ever needs a password on stdin.
#
# WHAT THIS SCRIPT ADDS ON TOP OF THE ONE-LINER
#   1. --no-login-shell. Run as root, upstream's chsh would change ROOT's login
#      shell, not dlesieur's. The login shell is set here, for dlesieur only.
#   2. HOME=/home/dlesieur for the run, so the plugin framework and ~/.hellishrc
#      land in the user's home instead of /root, then ownership is repaired.
#   3. The link. /usr/bin/hellish is dlesieur's login shell and a symlink to
#      /usr/bin/hellish.real, the ELF (what b2b-setup.sh set up for the baked
#      binary). Upstream's installer writes a fresh binary at /usr/bin/hellish;
#      it is moved to .real and the link restored, so `ssh b2b '<command>'`,
#      scp and the whole host-side pipeline (deploy_inception.sh,
#      provision_vm.sh, the CA fetch, every verifier) keep running under
#      hellish -- there is no bash wrapper any more, and an old guest that
#      still has one is converted. Losing the link strands the VM (sshd
#      rejects an account whose shell is missing), so it is also what the
#      sshd-watchdog guard restores.
#   4. Everything the guest starts on its own -- the monitoring cron job, the
#      two systemd helpers, the first-boot hook and the provisioners -- gets
#      hellish.real pinned as its interpreter (normalize_guest_interpreters),
#      the same thing b2b-setup.sh does at install time.
#
# FALLBACK
#   No network, or upstream unreachable, and an ISO-baked binary is already in
#   place: keep it. A first boot must never end with no usable login shell.
#
# Env:
#   HELLISH_USER        user whose login shell is set   (default dlesieur)
#   HELLISH_VERSION     pin a release tag               (default: latest)
#   HELLISH_PLUGINS     all | none | "git jump z"       (default all)
#   HELLISH_INSTALL_URL override the installer URL      (for testing)
# ============================================================================ #

set -u

HELLISH_USER="${HELLISH_USER:-dlesieur}"
HELLISH_VERSION="${HELLISH_VERSION:-}"
HELLISH_PLUGINS="${HELLISH_PLUGINS:-all}"
HELLISH_INSTALL_URL="${HELLISH_INSTALL_URL:-https://raw.githubusercontent.com/Univers42/hellish/main/install.sh}"

DEST="/usr/bin/hellish"
REAL="${DEST}.real"

log() { printf '[hellish-upstream] %s\n' "$*"; }
warn() { printf '[hellish-upstream] WARN: %s\n' "$*" >&2; }

[ "$(id -u)" -eq 0 ] || {
    warn "must run as root"
    exit 1
}

USER_HOME=$(getent passwd "$HELLISH_USER" 2>/dev/null | cut -d: -f6)
[ -n "$USER_HOME" ] || USER_HOME="/home/$HELLISH_USER"

# ── Is an old bash wrapper still sitting at $DEST? ───────────────────────────
# Guests built before the link existed have a small bash script there and the
# ELF at $REAL. Handing the wrapper to the installer as "the previous install"
# would be wrong, so put the binary back first and let upstream overwrite it.
# A link (the current layout) passes through: `install` unlinks it and writes
# a plain file, which install_link() moves to $REAL and re-links.
unwrap() {
	if [ ! -L "$DEST" ] && [ -f "$DEST" ] && head -c2 "$DEST" 2>/dev/null | grep -q '#!'; then
		[ -x "$REAL" ] && mv -f "$REAL" "$DEST"
	fi
}

# The shell that runs upstream's installer (a POSIX sh script): the guest's
# hellish.real when it is already there, sh only on a guest that has none.
# Replacing the binary from inside itself is fine: install(1) unlinks the
# target and writes a new file, and the running process keeps its old inode.
run_sh() {
	if [ -x "$REAL" ]; then printf '%s' "$REAL"; else printf 'sh'; fi
}

# ── 1. Upstream installer ───────────────────────────────────────────────────
run_upstream() {
    command -v curl >/dev/null 2>&1 || {
        warn "curl missing"
        return 1
    }

    local tmp rc
    tmp=$(mktemp -d) || return 1

    log "fetching ${HELLISH_INSTALL_URL}"
    if ! curl -fsSL --retry 3 --retry-delay 2 --max-time 120 \
        "$HELLISH_INSTALL_URL" -o "$tmp/install.sh"; then
        warn "could not download the installer"
        rm -rf "$tmp"
        return 1
    fi
    # A truncated or HTML error page must not be executed.
    if ! head -1 "$tmp/install.sh" | grep -q '^#!/bin/sh'; then
        warn "downloaded installer does not look like a shell script"
        rm -rf "$tmp"
        return 1
    fi

    set -- --yes --no-login-shell --plugins="$HELLISH_PLUGINS"
    [ -n "$HELLISH_VERSION" ] && set -- "$@" --version "$HELLISH_VERSION"

	unwrap
	log "running: $(run_sh) install.sh $* (HOME=$USER_HOME)"
	# HOME is what decides where ~/.hellishrc and ~/.hellish land. Running as
	# root with the user's HOME puts the configuration in the right place; the
	# files come out root-owned and are chown'd back below.
	HOME="$USER_HOME" "$(run_sh)" "$tmp/install.sh" "$@" 2>&1 | sed 's/^/    /'
	rc=${PIPESTATUS[0]}
	rm -rf "$tmp"

    if [ "$rc" -ne 0 ]; then
        warn "installer exited $rc"
        return 1
    fi
    [ -x "$DEST" ] || {
        warn "installer finished but $DEST is missing"
        return 1
    }
    log "installed $DEST ($("$DEST" --version 2>/dev/null | head -1))"
    return 0
}

# ── 2. Ownership of everything the run wrote into the user's home ───────────
fix_ownership() {
    local g p
    g=$(id -gn "$HELLISH_USER" 2>/dev/null) || g="$HELLISH_USER"
    for p in "$USER_HOME/.hellishrc" "$USER_HOME/.hellish" \
        "$USER_HOME/.config/hellish" "$USER_HOME/.local/bin/hellish" \
        "$USER_HOME/.local/share/hellish" "$USER_HOME/.cache/hellish"; do
        [ -e "$p" ] && chown -R "$HELLISH_USER:$g" "$p" 2>/dev/null
    done
    # .config itself may have been created by the run.
    [ -d "$USER_HOME/.config" ] && chown "$HELLISH_USER:$g" "$USER_HOME/.config" 2>/dev/null
    log "ownership of the hellish configuration set to ${HELLISH_USER}:${g}"
}

# ── 3. The link: /usr/bin/hellish -> /usr/bin/hellish.real ──────────────────
# Same layout b2b-setup.sh installs for the baked binary. A fresh binary that
# upstream left at $DEST is moved to $REAL; an old bash wrapper is replaced.
install_link() {
	if [ ! -L "$DEST" ] && [ -f "$DEST" ]; then
		if head -c2 "$DEST" 2>/dev/null | grep -q '#!'; then
			[ -x "$REAL" ] || { warn "a wrapper at $DEST but no $REAL to link to"; return 1; }
			log "replacing the bash wrapper at $DEST with a link"
		else
			mv -f "$DEST" "$REAL" || { warn "could not move the binary aside"; return 1; }
		fi
	fi
	[ -x "$REAL" ] || { warn "no $REAL to link to"; return 1; }
	chmod 755 "$REAL"
	ln -sfn "$REAL" "$DEST"
	# The pristine copy the sshd-watchdog guard restores from.
	mkdir -p /usr/local/lib/b2b
	cp -f "$REAL" /usr/local/lib/b2b/hellish.real 2>/dev/null && chmod 755 /usr/local/lib/b2b/hellish.real
	rm -f /usr/local/lib/b2b/shell-wrapper
	log "$DEST -> $REAL (interactive logins and ssh commands alike run hellish)"
}

# ── 3b. Pin hellish.real as the interpreter of what the guest runs itself ────
# b2b-setup.sh does this at install time from the ISO; doing it here as well
# converts a guest that was built before, and survives a refresh. The two
# systemd helpers are restarted so their running process is hellish.real too.
normalize_guest_interpreters() {
	local f pid changed=0
	for f in /usr/local/bin/monitoring.sh /usr/local/bin/nat-keepalive.sh \
		/usr/local/bin/sshd-watchdog.sh /root/first-boot-setup.sh /root/install_*.sh; do
		[ -f "$f" ] || continue
		if [ "$(head -1 "$f")" != "#!$REAL" ]; then
			sed -i "1s|^#!.*|#!$REAL|" "$f" && changed=$((changed + 1))
		fi
	done
	if grep -q '^@reboot root /bin/bash /root/first-boot-setup.sh' /etc/crontab 2>/dev/null; then
		sed -i "s|^@reboot root /bin/bash /root/first-boot-setup.sh|@reboot root $REAL /root/first-boot-setup.sh|" /etc/crontab
		changed=$((changed + 1))
	fi
	# cron starts every job as `$SHELL -c`; Debian's SHELL=/bin/sh is dash.
	if [ -f /etc/crontab ] && [ "$(sed -n 's/^SHELL=//p' /etc/crontab | head -1)" != "$REAL" ]; then
		if grep -q '^SHELL=' /etc/crontab; then sed -i "s|^SHELL=.*|SHELL=$REAL|" /etc/crontab
		else sed -i "1i SHELL=$REAL" /etc/crontab; fi
		changed=$((changed + 1))
	fi
	if [ -f /etc/b2b_custom_shell.conf ]; then
		grep -q '^B2B_GUEST_SH=' /etc/b2b_custom_shell.conf \
			&& sed -i "s|^B2B_GUEST_SH=.*|B2B_GUEST_SH=$REAL|" /etc/b2b_custom_shell.conf \
			|| echo "B2B_GUEST_SH=$REAL" >> /etc/b2b_custom_shell.conf
	fi
	# A script's process is named after the script, so ask /proc for argv[0].
	for f in nat-keepalive sshd-watchdog; do
		pid=$(systemctl show -p MainPID --value "$f" 2>/dev/null)
		if systemctl is-enabled "$f" > /dev/null 2>&1 \
			&& [ "$(tr '\0' ' ' < "/proc/${pid:-0}/cmdline" 2>/dev/null | cut -d' ' -f1)" != "$REAL" ]; then
			systemctl restart "$f" 2> /dev/null && changed=$((changed + 1))
		fi
	done
	log "guest-side scripts run under $REAL ($changed change(s))"
}

# ── 4. Register it and make it the user's login shell ───────────────────────
set_login_shell() {
	if [ -f /etc/shells ]; then
		grep -qxF "$DEST" /etc/shells || echo "$DEST" >> /etc/shells
	else
		echo "$DEST" > /etc/shells
	fi
	if id "$HELLISH_USER" > /dev/null 2>&1; then
		usermod -s "$DEST" "$HELLISH_USER" 2> /dev/null \
			|| chsh -s "$DEST" "$HELLISH_USER" 2> /dev/null \
			|| { warn "could not set the login shell for $HELLISH_USER"; return 1; }
		log "login shell for $HELLISH_USER -> $(getent passwd "$HELLISH_USER" | cut -d: -f7)"
	else
		warn "user $HELLISH_USER does not exist"
		return 1
	fi
	# first-boot-setup.sh re-applies this on later boots, and runs the
	# provisioners under B2B_GUEST_SH.
	printf 'B2B_CUSTOM_USER=%s\nB2B_CUSTOM_SHELL=%s\nB2B_GUEST_SH=%s\n' "$HELLISH_USER" "$DEST" "$REAL" \
		> /etc/b2b_custom_shell.conf 2> /dev/null || true
	chmod 644 /etc/b2b_custom_shell.conf 2> /dev/null || true
}

# ── Main ────────────────────────────────────────────────────────────────────
log "starting (user=$HELLISH_USER, plugins=$HELLISH_PLUGINS)"

if run_upstream; then
    fix_ownership
else
    if [ -x "$REAL" ] || [ -x "$DEST" ]; then
        warn "upstream install failed — keeping the shell already installed from the ISO"
    else
        warn "upstream install failed and no shell is present — the VM keeps bash"
        exit 1
    fi
fi

install_link || exit 1
set_login_shell
normalize_guest_interpreters

# ── Report ──────────────────────────────────────────────────────────────────
log "--- result ---"
log "binary : $("$REAL" --version 2>/dev/null | head -1 || echo 'MISSING')"
log "link   : $DEST -> $(readlink "$DEST" 2>/dev/null || echo 'NOT A LINK')"
log "shell  : $(getent passwd "$HELLISH_USER" | cut -d: -f7)"
if [ -f "$USER_HOME/.hellishrc" ]; then
    log "config : $USER_HOME/.hellishrc ($(stat -c '%U:%G' "$USER_HOME/.hellishrc"))"
    log "plugins: $(ls "$USER_HOME/.hellish/plugins" 2>/dev/null | tr '\n' ' ')"
else
    warn "config : $USER_HOME/.hellishrc is missing — the plugin framework did not install"
    exit 2
fi
log "done"
