#!/bin/bash
#
# install_global_scope.sh — put machine-wide tooling on /opt, not on / or /home.
#
# WHY
# ---
# Three kinds of data get conflated on a default Debian box:
#
#   user data           /home    — projects, dotfiles, per-user editor state
#   the OS              /        — apt's packages, managed by dpkg
#   machine-wide extras /opt     — things every user shares that dpkg does NOT
#                                  manage: language runtimes installed by hand,
#                                  npm globals, AI models
#
# By default the third kind lands in the second: npm globals go to
# /usr/lib/node_modules and Ollama keeps models in /usr/share/ollama, both on
# a root filesystem sized for apt. One 5 GB model fills it, and a full / breaks
# dpkg, GRUB and the whole machine — which is exactly the cascading failure the
# preseed comments in this repo already warn about.
#
# The VM's partition recipe gives /opt its own logical volume for this. This
# script points the machine-wide things at it.
#
# ORDERING MATTERS: this must run BEFORE install_nvim.sh, which does
# `npm install -g`. Change the prefix afterwards and the earlier packages are
# stranded at the old location — installed, on no PATH, invisible.
#
# USAGE
#   sudo ./install_global_scope.sh
#   sudo GLOBAL_PREFIX=/srv/shared ./install_global_scope.sh

set -u

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

GLOBAL_PREFIX="${GLOBAL_PREFIX:-/opt}"
NPM_PREFIX="${NPM_PREFIX:-${GLOBAL_PREFIX}/npm-global}"
AI_ROOT="${AI_ROOT:-${GLOBAL_PREFIX}/ai}"
# Everyone in this group may write to the shared trees without sudo.
GLOBAL_GROUP="${GLOBAL_GROUP:-staff}"

log()  { printf '[global] %s\n' "$*"; }
warn() { printf '[global] WARN: %s\n' "$*" >&2; }
die()  { printf '[global] ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"

# ── Is /opt actually its own filesystem? ────────────────────────────────────
# Not fatal — this script is still correct on a machine with a single root
# filesystem — but worth saying out loud, because the whole point of moving
# these paths is to stop them filling /.
report_mount() {
	local dev size
	if mountpoint -q "$GLOBAL_PREFIX" 2>/dev/null; then
		dev=$(findmnt -no SOURCE "$GLOBAL_PREFIX" 2>/dev/null)
		size=$(df -h --output=size "$GLOBAL_PREFIX" 2>/dev/null | tail -n1 | tr -d ' ')
		log "${GLOBAL_PREFIX} is its own filesystem (${dev}, ${size})"
	else
		warn "${GLOBAL_PREFIX} is NOT a separate filesystem — it shares $(findmnt -no TARGET -T "$GLOBAL_PREFIX" 2>/dev/null || echo /)."
		warn "Everything below still works, but it will consume that filesystem's space."
	fi
}

# ── Shared directories ──────────────────────────────────────────────────────
# 2775: setgid, so anything created inside inherits the group. Without the
# setgid bit a second user's files land in their own primary group and the
# next person cannot write them — the classic shared-directory failure.
make_shared() {
	local d="$1"
	mkdir -p "$d"
	if getent group "$GLOBAL_GROUP" >/dev/null 2>&1; then
		chgrp -R "$GLOBAL_GROUP" "$d" 2>/dev/null || true
		chmod 2775 "$d" 2>/dev/null || true
	else
		chmod 755 "$d" 2>/dev/null || true
	fi
}

setup_dirs() {
	log "creating the shared trees under ${GLOBAL_PREFIX}"
	make_shared "$NPM_PREFIX"
	make_shared "${NPM_PREFIX}/bin"
	make_shared "${NPM_PREFIX}/lib"
	make_shared "$AI_ROOT"
	make_shared "${AI_ROOT}/models"
}

# ── npm ─────────────────────────────────────────────────────────────────────
setup_npm() {
	command -v npm >/dev/null 2>&1 || { warn "npm not installed yet — skipping the prefix"; return 0; }

	local current
	current=$(npm config get prefix --global 2>/dev/null || echo '')
	if [ "$current" = "$NPM_PREFIX" ]; then
		log "npm prefix already ${NPM_PREFIX}"
	else
		# Write the system-wide npmrc rather than root's ~/.npmrc: the value has
		# to apply to every user and to systemd units, not just to root's
		# interactive shell.
		npm config set prefix "$NPM_PREFIX" --global >/dev/null 2>&1 \
			|| warn "npm config set prefix failed"
		log "npm prefix: ${current:-(default)} -> ${NPM_PREFIX}"

		# Anything installed at the OLD prefix is now off PATH: still on disk,
		# still working, and invisible. Look under the prefix npm ACTUALLY had
		# (usually /usr/local on Debian), not the /usr/lib/node_modules where
		# the npm package itself lives -- that directory is empty on a normal
		# box and the check would silently never fire.
		#
		# Reinstalling is left to the caller. Doing it automatically here would
		# mean this script pulls from the network, which is the one thing the
		# provisioning order is designed to keep out of the early steps.
		if [ -n "$current" ] && [ -d "${current}/lib/node_modules" ]; then
			local stale
			stale=$(ls "${current}/lib/node_modules" 2>/dev/null \
				| grep -vE '^(npm|corepack)$' | tr '\n' ' ')
			if [ -n "$stale" ]; then
				warn "these were installed at the old prefix (${current}) and are now off PATH:"
				warn "    ${stale}"
				warn "reinstall them so they land in ${NPM_PREFIX}:  npm install -g ${stale}"
			fi
		fi
	fi
}

# ── PATH + environment for every login shell ────────────────────────────────
setup_profile() {
	cat > /etc/profile.d/b2b-global.sh <<PROFEOF
# Added by born2root setup/install/tools/install_global_scope.sh
#
# Machine-wide tooling lives on ${GLOBAL_PREFIX} (its own LVM volume) instead of
# / or /home. See that script's header for why.

# npm globals: claude, tree-sitter, the neovim provider.
case ":\$PATH:" in
	*":${NPM_PREFIX}/bin:"*) ;;
	*) PATH="${NPM_PREFIX}/bin:\$PATH" ;;
esac
export PATH

# Where Ollama keeps models. Exported for the CLI; the systemd unit gets its
# own copy via a drop-in, because units do not read /etc/profile.d.
export OLLAMA_MODELS="${AI_ROOT}/models"
PROFEOF
	chmod 644 /etc/profile.d/b2b-global.sh
	log "wrote /etc/profile.d/b2b-global.sh"

	# sudo resets PATH to secure_path, so a root shell would not see the npm
	# bin dir at all without this — `sudo claude` would be "command not found"
	# while `claude` worked.
	if [ -f /etc/sudoers ] && grep -q '^Defaults.*secure_path' /etc/sudoers; then
		if ! grep -q "secure_path.*${NPM_PREFIX}/bin" /etc/sudoers; then
			cp /etc/sudoers /etc/sudoers.b2b-bak
			sed -i "s|\(^Defaults.*secure_path=\"\)|\1${NPM_PREFIX}/bin:|" /etc/sudoers
			# A malformed sudoers file locks everyone out of root, so validate
			# and roll back rather than trusting the edit.
			if visudo -c -f /etc/sudoers >/dev/null 2>&1; then
				rm -f /etc/sudoers.b2b-bak
				log "added ${NPM_PREFIX}/bin to sudo's secure_path"
			else
				mv /etc/sudoers.b2b-bak /etc/sudoers
				warn "sudoers edit was invalid — rolled back"
			fi
		fi
	fi
}

log "=== machine-wide scope -> ${GLOBAL_PREFIX} ==="
report_mount
setup_dirs
setup_npm
setup_profile
log "=== done: npm globals in ${NPM_PREFIX}, AI models in ${AI_ROOT}/models ==="
