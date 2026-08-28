#!/usr/bin/env bash
# ============================================================================ #
#  born2root — restart the browsers so they pick up the Inception config       #
# ============================================================================ #
#
# Firefox reads user.js only when a profile starts, and Chrome reads its proxy
# settings and certificate store only at launch. A browser that was already open
# while `make host_access` ran therefore sees none of it, and reports the domain
# as "Server Not Found" or ERR_CERT_AUTHORITY_INVALID exactly as if nothing had
# been configured. This closes that gap so the build really does finish with a
# working site.
#
# Sessions are preserved rather than discarded:
#   Firefox  a clean SIGTERM makes it write its session out; the restart then
#            sets browser.sessionstore.resume_session_once in prefs.js, which is
#            the same one-shot flag Firefox itself uses when it restarts for an
#            update, so the tabs come back and the flag clears itself.
#   Chrome   relaunched with --restore-last-session.
#
# Only ever run when there is a complete configuration to pick up, and skipped
# entirely with INCEPTION_NO_BROWSER_RESTART=1.
# ============================================================================ #

set -uo pipefail

C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'; C_DIM=$'\033[2m'

ok()   { printf "  ${C_GREEN}✓${C_RESET} %s\n" "$*"; }
warn() { printf "  ${C_YELLOW}⚠${C_RESET}  %s\n" "$*"; }

[ "${INCEPTION_NO_BROWSER_RESTART:-0}" = "1" ] && exit 0

# Relaunching needs somewhere to draw. Over a bare SSH session there is no
# display, and killing the user's browser without being able to bring it back
# would be strictly worse than leaving it alone.
if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
	warn "no display — leaving the browsers alone (restart them yourself)"
	exit 0
fi

# The main browser process, as opposed to its renderer children: those carry
# -contentproc (Firefox) or --type= (Chrome) and die with the parent anyway.
main_pids() {
	local pattern="$1" pid cmdline
	for pid in $(pgrep -f "$pattern" 2> /dev/null); do
		[ -r "/proc/$pid/cmdline" ] || continue
		cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline")
		case "$cmdline" in
			*-contentproc* | *--type=* | *crashpad* | *crashhelper* | *forkserver*) continue ;;
		esac
		printf '%s\n' "$pid"
	done
}

# SIGTERM, then wait: a clean exit is what makes the browser save its session.
stop_gracefully() {
	local pids="$1" name="$2" pid i alive
	[ -n "$pids" ] || return 1
	kill -TERM $pids 2> /dev/null
	for i in $(seq 1 40); do
		alive=""
		for pid in $pids; do
			[ -d "/proc/$pid" ] && alive="yes"
		done
		[ -z "$alive" ] && return 0
		sleep 0.5
	done
	warn "$name did not exit in 20s — leaving it running"
	return 1
}

# ── Firefox ─────────────────────────────────────────────────────────────────
restart_firefox() {
	local pids profile prefs
	pids=$(main_pids '/firefox/firefox')
	[ -n "$pids" ] || return 0

	command -v firefox > /dev/null 2>&1 || { warn "firefox not in PATH"; return 0; }
	stop_gracefully "$pids" "Firefox" || return 0

	# prefs.js is rewritten by Firefox as it exits, so this has to happen after
	# it is gone or the change is thrown away.
	for profile in "$HOME"/.mozilla/firefox/*/ \
		"$HOME"/snap/firefox/common/.mozilla/firefox/*/ \
		"$HOME"/.var/app/org.mozilla.firefox/.mozilla/firefox/*/; do
		prefs="${profile}prefs.js"
		[ -f "$prefs" ] || continue
		grep -v 'browser.sessionstore.resume_session_once' "$prefs" > "$prefs.b2b" 2> /dev/null \
			&& mv "$prefs.b2b" "$prefs"
		printf 'user_pref("browser.sessionstore.resume_session_once", true);\n' >> "$prefs"
	done

	setsid nohup firefox > /dev/null 2>&1 < /dev/null &
	ok "Firefox restarted (previous session restored)"
}

# ── Chrome / Chromium ───────────────────────────────────────────────────────
restart_chrome() {
	local pids bin name
	for name in google-chrome google-chrome-stable chromium chromium-browser; do
		command -v "$name" > /dev/null 2>&1 || continue
		case "$name" in
			google-chrome*) pids=$(main_pids '/opt/google/chrome/chrome') ;;
			*)              pids=$(main_pids '/chromium') ;;
		esac
		[ -n "$pids" ] || continue
		bin=$(command -v "$name")
		stop_gracefully "$pids" "$name" || continue
		setsid nohup "$bin" --restore-last-session > /dev/null 2>&1 < /dev/null &
		ok "$name restarted (previous tabs restored)"
	done
}

printf "\n  ${C_BOLD}Applying the configuration to the running browsers${C_RESET}\n"
printf "  ${C_DIM}They only read it at startup, so they are restarted here.${C_RESET}\n"
printf "  ${C_DIM}Skip with INCEPTION_NO_BROWSER_RESTART=1.${C_RESET}\n"
restart_firefox
restart_chrome
