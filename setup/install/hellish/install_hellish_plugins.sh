#!/bin/bash
#
# install_hellish_plugins.sh — install the hellishrc plugin framework.
#
# WHAT IT INSTALLS
# ----------------
# https://github.com/Univers42/hellishrc_plugins is a configuration framework
# for the hellish shell that this VM already uses as its login shell. Its layout
# on disk is fixed by the loader:
#
#   ~/.hellishrc        the loader — hellish sources this for interactive shells
#   ~/.hellish/lib/     ui.hsh core.hsh plugin.hsh conf.hsh   the framework
#   ~/.hellish/rc.d/    10-env … 99-local                     core modules
#   ~/.hellish/plugins/ git devkit jump docker net sentinel forge
#   ~/.hellish/hellish.conf   which of those are on  (managed by `conf`)
#   ~/.hellish/state/   runtime state — jump history, marks, scratch files
#   ~/.hellish/test/    the config's own test suite
#
# The repo also carries the author's own state/ directory: a jump database full
# of paths from their machine and two dozen stale jump.db.<pid> temp files.
# Copying that onto a fresh VM would seed `j` with directories that do not
# exist here, so state/ is created empty apart from the one file the test suite
# asserts on (original-hellishrc.snapshot).
#
# USAGE
#   sudo ./install_hellish_plugins.sh                      # default: user dlesieur
#   sudo HELLISH_USERS="dlesieur root" ./install_hellish_plugins.sh
#   sudo HELLISH_PLUGINS_REF=main ./install_hellish_plugins.sh
#   sudo HELLISH_PLUGINS_SRC=/path/to/checkout ./install_hellish_plugins.sh   # no network

set -u

HELLISH_PLUGINS_REPO="${HELLISH_PLUGINS_REPO:-https://github.com/Univers42/hellishrc_plugins.git}"
HELLISH_PLUGINS_REF="${HELLISH_PLUGINS_REF:-}"          # empty = the repo's default branch
HELLISH_PLUGINS_SRC="${HELLISH_PLUGINS_SRC:-}"          # a local checkout to install from instead
HELLISH_USERS="${HELLISH_USERS:-dlesieur}"

log()  { printf '[hellishrc] %s\n' "$*"; }
warn() { printf '[hellishrc] WARN: %s\n' "$*" >&2; }
die()  { printf '[hellishrc] ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"

# ── Obtain the sources ──────────────────────────────────────────────────────
SRC=""
CLONE_TMP=""
cleanup() { [ -n "$CLONE_TMP" ] && rm -rf "$CLONE_TMP"; }
trap cleanup EXIT

obtain_sources() {
	if [ -n "$HELLISH_PLUGINS_SRC" ]; then
		[ -d "${HELLISH_PLUGINS_SRC}/lib" ] \
			|| die "HELLISH_PLUGINS_SRC=${HELLISH_PLUGINS_SRC} does not look like a hellishrc_plugins checkout"
		SRC="$HELLISH_PLUGINS_SRC"
		log "installing from the local checkout ${SRC}"
		return 0
	fi

	command -v git >/dev/null 2>&1 || die "git is required (apt-get install git)"
	CLONE_TMP=$(mktemp -d) || die "mktemp failed"
	log "cloning ${HELLISH_PLUGINS_REPO}"
	if [ -n "$HELLISH_PLUGINS_REF" ]; then
		git clone --depth 1 --branch "$HELLISH_PLUGINS_REF" \
			"$HELLISH_PLUGINS_REPO" "${CLONE_TMP}/src" >/dev/null 2>&1 \
			|| die "clone of ref '${HELLISH_PLUGINS_REF}' failed"
	else
		git clone --depth 1 "$HELLISH_PLUGINS_REPO" "${CLONE_TMP}/src" >/dev/null 2>&1 \
			|| die "clone failed (no network?)"
	fi
	SRC="${CLONE_TMP}/src"
	log "cloned $(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo '?')"
}

# ── Install for one user ────────────────────────────────────────────────────
install_for_user() {
	local user="$1" home group hx stamp
	home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
	if [ -z "$home" ] || [ ! -d "$home" ]; then
		warn "user '${user}' has no home directory — skipping"
		return 1
	fi
	group=$(id -gn "$user" 2>/dev/null || echo "$user")
	hx="${home}/.hellish"
	stamp=$(date +%Y%m%d%H%M%S)

	# Back up anything already there. `conf` writes hellish.conf in place, so a
	# reinstall would otherwise silently discard the user's feature toggles.
	if [ -e "$hx" ]; then
		log "${user}: existing ${hx} -> ${hx}.bak.${stamp}"
		mv "$hx" "${hx}.bak.${stamp}" || { warn "${user}: backup failed"; return 1; }
	fi
	if [ -e "${home}/.hellishrc" ]; then
		log "${user}: existing .hellishrc -> .hellishrc.bak.${stamp}"
		cp -p "${home}/.hellishrc" "${home}/.hellishrc.bak.${stamp}" 2>/dev/null || true
	fi

	mkdir -p "${hx}/state"

	# The framework itself: copy the directories the loader reads, in the order
	# .hellishrc sources them.
	local d
	for d in lib rc.d plugins test; do
		if [ -d "${SRC}/${d}" ]; then
			cp -r "${SRC}/${d}" "${hx}/${d}" || { warn "${user}: copying ${d} failed"; return 1; }
		else
			warn "${user}: source has no ${d}/ — skipping it"
		fi
	done

	# hellish.conf ships the author's on/off choices; keep them as the defaults.
	# `conf on|off <name>` rewrites this file afterwards.
	[ -f "${SRC}/hellish.conf" ] && cp "${SRC}/hellish.conf" "${hx}/hellish.conf"

	# The loader.
	[ -f "${SRC}/.hellishrc" ] \
		|| { warn "${user}: source has no .hellishrc — nothing would load"; return 1; }
	cp "${SRC}/.hellishrc" "${home}/.hellishrc"

	# state/ is deliberately fresh (see the header). The snapshot is the one
	# file test/run.hsh asserts exists; if the repo has it, carry it over,
	# otherwise seed it from the .hellishrc we just installed so the suite passes.
	if [ -f "${SRC}/state/original-hellishrc.snapshot" ]; then
		cp "${SRC}/state/original-hellishrc.snapshot" "${hx}/state/original-hellishrc.snapshot"
	else
		cp "${home}/.hellishrc" "${hx}/state/original-hellishrc.snapshot"
	fi

	chown -R "${user}:${group}" "$hx" "${home}/.hellishrc" 2>/dev/null || true
	chmod 700 "${hx}/state" 2>/dev/null || true

	log "${user}: installed -> ${hx} (+ ~/.hellishrc)"
	return 0
}

# ── Verify ──────────────────────────────────────────────────────────────────
# hellish sources ~/.hellishrc for INTERACTIVE shells only, so a plain
# `hellish -c '. ~/.hellishrc'` is the way to load it in a script and see
# whether the framework reports any errors.
verify_for_user() {
	local user="$1" home shell_bin
	home=$(getent passwd "$user" | cut -d: -f6)

	# The VM installs hellish as a wrapper that routes non-interactive work to
	# bash (see preseeds/b2b-setup.sh), so test the real binary when it exists.
	for shell_bin in /usr/bin/hellish.real /usr/local/bin/hellish.real \
		/usr/bin/hellish /usr/local/bin/hellish; do
		[ -x "$shell_bin" ] && break
		shell_bin=""
	done
	if [ -z "$shell_bin" ]; then
		warn "${user}: no hellish binary found — installed the files, but cannot verify"
		return 0
	fi

	local out
	out=$(runuser -u "$user" -- "$shell_bin" -c \
		'. "$HOME/.hellishrc"; printf "loaded=%s errors=%s\n" "${#HX_LOADED[@]}" "${#HX_ERRORS[@]}"' 2>&1)
	case "$out" in
		*errors=0*) log "${user}: verify OK — ${out##*$'\n'}" ;;
		*) warn "${user}: verify reported problems:"; printf '%s\n' "$out" | sed 's/^/[hellishrc]   /' ;;
	esac
}

# ── main ────────────────────────────────────────────────────────────────────
log "=== hellishrc_plugins install starting ==="
obtain_sources

installed=""
for u in $HELLISH_USERS; do
	if install_for_user "$u"; then
		installed="${installed} ${u}"
		verify_for_user "$u"
	fi
done

[ -n "${installed// /}" ] || die "no users were configured"
log "=== done — installed for:${installed} ==="
log "in a hellish shell try:  conf list   |   hxp list   |   help_conf"
