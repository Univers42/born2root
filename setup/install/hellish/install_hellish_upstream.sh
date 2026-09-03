#!/bin/bash
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
#   3. The SSH-compatibility wrapper. This is not optional: /usr/bin/hellish is
#      dlesieur's login shell, so `ssh b2b '<command>'` runs it non-interactively
#      — and the entire host-side pipeline (deploy_inception.sh, provision_vm.sh,
#      the CA fetch in inception_host_access.sh, every verifier) is exactly that.
#      The wrapper keeps hellish for interactive logins and routes non-interactive
#      invocations to bash, which is what b2b-setup.sh already did for the baked
#      binary. Losing it strands the VM: the host can no longer drive it.
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

log()  { printf '[hellish-upstream] %s\n' "$*"; }
warn() { printf '[hellish-upstream] WARN: %s\n' "$*" >&2; }

[ "$(id -u)" -eq 0 ] || { warn "must run as root"; exit 1; }

USER_HOME=$(getent passwd "$HELLISH_USER" 2>/dev/null | cut -d: -f6)
[ -n "$USER_HOME" ] || USER_HOME="/home/$HELLISH_USER"

# ── Is a wrapper already sitting at $DEST from a previous run? ───────────────
# The wrapper is a small bash script; the real shell is an ELF binary. Handing
# the wrapper back to the installer as "the previous install" would be wrong,
# so unwrap first and let upstream overwrite the real binary.
unwrap() {
	if [ -f "$DEST" ] && head -c2 "$DEST" 2>/dev/null | grep -q '#!'; then
		[ -x "$REAL" ] && mv -f "$REAL" "$DEST"
	fi
}

# ── 1. Upstream installer ───────────────────────────────────────────────────
run_upstream() {
	command -v curl > /dev/null 2>&1 || { warn "curl missing"; return 1; }

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
	log "running: sh install.sh $* (HOME=$USER_HOME)"
	# HOME is what decides where ~/.hellishrc and ~/.hellish land. Running as
	# root with the user's HOME puts the configuration in the right place; the
	# files come out root-owned and are chown'd back below.
	HOME="$USER_HOME" sh "$tmp/install.sh" "$@" 2>&1 | sed 's/^/    /'
	rc=${PIPESTATUS[0]}
	rm -rf "$tmp"

	if [ "$rc" -ne 0 ]; then
		warn "installer exited $rc"
		return 1
	fi
	[ -x "$DEST" ] || { warn "installer finished but $DEST is missing"; return 1; }
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
		[ -e "$p" ] && chown -R "$HELLISH_USER:$g" "$p" 2> /dev/null
	done
	# .config itself may have been created by the run.
	[ -d "$USER_HOME/.config" ] && chown "$HELLISH_USER:$g" "$USER_HOME/.config" 2> /dev/null
	log "ownership of the hellish configuration set to ${HELLISH_USER}:${g}"
}

# ── 3. The SSH-compatibility wrapper ────────────────────────────────────────
# Identical in behaviour to the one b2b-setup.sh installs for the baked binary:
# interactive login -> hellish, everything else -> bash. Without it, every
# `ssh b2b '<command>'` from the host runs inside hellish.
install_wrapper() {
	if [ ! -x "$DEST" ]; then
		warn "no $DEST to wrap"
		return 1
	fi
	# Already wrapped (re-run): leave it alone.
	if head -c2 "$DEST" 2>/dev/null | grep -q '#!' && [ -x "$REAL" ]; then
		log "wrapper already in place"
		return 0
	fi
	mv -f "$DEST" "$REAL" || { warn "could not move the binary aside"; return 1; }
	chmod 755 "$REAL"
	cat > "$DEST" << 'WRAPEOF'
#!/bin/bash
# Installed by born2root (setup/install/hellish/install_hellish_upstream.sh).
#
# hellish is the interactive login shell. Non-interactive invocations -- which
# is what `ssh <host> '<command>'`, scp, rsync and VS Code Remote-SSH all use --
# are handed to bash, so host-side automation keeps working.
REAL_SHELL="${0}.real"

if [ -n "$SSH_ORIGINAL_COMMAND" ] || [ ! -t 0 ] || [ ! -t 1 ]; then
	if [ -n "$SSH_ORIGINAL_COMMAND" ]; then
		exec /bin/bash -lc "$SSH_ORIGINAL_COMMAND"
	elif [ "$#" -gt 0 ]; then
		exec /bin/bash "$@"
	else
		exec /bin/bash -l
	fi
fi

exec "$REAL_SHELL" "$@"
WRAPEOF
	chmod 755 "$DEST"
	log "SSH-compatibility wrapper installed (interactive=hellish, non-interactive=bash)"
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
	# first-boot-setup.sh re-applies this on later boots.
	printf 'B2B_CUSTOM_USER=%s\nB2B_CUSTOM_SHELL=%s\n' "$HELLISH_USER" "$DEST" \
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

install_wrapper
set_login_shell

# ── Report ──────────────────────────────────────────────────────────────────
log "--- result ---"
log "binary : $("$REAL" --version 2>/dev/null | head -1 || echo 'MISSING')"
log "wrapper: $([ -f "$DEST" ] && head -1 "$DEST" || echo 'MISSING')"
log "shell  : $(getent passwd "$HELLISH_USER" | cut -d: -f7)"
if [ -f "$USER_HOME/.hellishrc" ]; then
	log "config : $USER_HOME/.hellishrc ($(stat -c '%U:%G' "$USER_HOME/.hellishrc"))"
	log "plugins: $(ls "$USER_HOME/.hellish/plugins" 2>/dev/null | tr '\n' ' ')"
else
	warn "config : $USER_HOME/.hellishrc is missing — the plugin framework did not install"
	exit 2
fi
log "done"
