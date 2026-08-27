#!/usr/bin/env bash
# ============================================================================ #
#  born2root — reach the Inception domain from the HOST, without root          #
# ============================================================================ #
#
# THE PROBLEM
#   The Inception subject requires the site to answer on <login>.42.fr. That
#   name is not a registered domain: it only exists because something is told
#   to map it to an IP. Inside the VM that "something" is the guest's own
#   /etc/hosts (written by inception's `make setup`). The host has never been
#   told anything, so a browser on the host cannot resolve it — and on a 42
#   campus machine there is no root to add a host-side /etc/hosts entry.
#
# THE FIX (no root, no proxy, no SSH tunnel)
#   Name resolution does not have to happen in the OS. Both browsers shipped on
#   these machines can be told to resolve one specific name themselves:
#
#     Firefox   pref  network.dns.localDomains   → resolves the name to
#               127.0.0.1. Written here into every Firefox profile's user.js,
#               so it survives restarts and needs no clicking.
#
#     Chromium  flag  --host-resolver-rules      → resolves the name AND
#     /Chrome   remaps the port, so the URL needs no :port suffix at all.
#               Written here into a small launcher script.
#
#   The traffic itself then rides the VirtualBox NAT port-forward, which is the
#   same mechanism `ssh b2b` already uses — nothing to keep alive, nothing to
#   go stale. This is deliberately NOT the `ssh -D` SOCKS approach that
#   doc/SSH_VSCODE_FIX.md documents going silently dead after ~15 min idle.
#
# RESULT
#   Chromium/Chrome   https://<domain>              (exact subject URL)
#   Firefox           https://<domain>:<https-port> (port needed: binding host
#                     port 443 requires root, and we have none — see below)
#
#   Why Firefox keeps a port: network.dns.localDomains can only map a name to
#   127.0.0.1, it cannot remap the port, so the browser asks for 127.0.0.1:443.
#   Nothing may listen there — net.ipv4.ip_unprivileged_port_start is 1024 on
#   these machines, so no unprivileged process (VirtualBox NAT included) can
#   bind 443. Chromium's flag remaps the port inside the browser, which is why
#   it alone gets the bare URL.
#
# Run:   make host_access            (also runs automatically from `make all`)
# Undo:  make host_access_undo       (or: this script --undo)
# ============================================================================ #

set -uo pipefail

VM_NAME="${VM_NAME:-debian}"
DOMAIN="${INCEPTION_DOMAIN:-${USER:-dlesieur}.42.fr}"

# Preferred host ports. Only used when the VM has no rule yet; an existing rule
# always wins, so a port moved to dodge a clash is respected.
PREF_HTTPS_PORT="${INCEPTION_HTTPS_PORT:-8443}"
PREF_STATIC_PORT="${INCEPTION_STATIC_PORT:-8090}"
PREF_HTTP_PORT="${INCEPTION_HTTP_PORT:-8082}"

# Guest-side ports the Inception stack listens on.
GUEST_HTTPS=443
GUEST_STATIC=8090
GUEST_HTTP=80

BEGIN_MARK="// >>> born2root: Inception host access — auto-generated, do not edit >>>"
END_MARK="// <<< born2root: Inception host access <<<"

LAUNCHER="$HOME/.local/bin/inception-browser"
CURL_WRAPPER="$HOME/.local/bin/inception-curl"
DESKTOP_FILE="$HOME/.local/share/applications/inception-browser.desktop"
CHROME_PROFILE=""   # decided in configure_chromium(): depends on snap vs .deb

C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_DIM=$'\033[2m'

ok()   { printf "  ${C_GREEN}✓${C_RESET} %s\n" "$*"; }
warn() { printf "  ${C_YELLOW}⚠${C_RESET}  %s\n" "$*"; }
info() { printf "  ${C_BLUE}▶${C_RESET} %s\n" "$*"; }

ACTION=configure
[ "${1:-}" = "--undo" ] && ACTION=undo

# ── VirtualBox NAT forwarding ───────────────────────────────────────────────
have_vm() {
	command -v VBoxManage > /dev/null 2>&1 \
		&& VBoxManage showvminfo "$VM_NAME" > /dev/null 2>&1
}

vm_state() {
	VBoxManage showvminfo "$VM_NAME" --machinereadable 2> /dev/null \
		| awk -F'"' '$1 == "VMState=" { print $2; exit }'
}

# Host port currently bound to a named NAT rule ("" when the rule is absent).
get_forward_port() {
	VBoxManage showvminfo "$VM_NAME" --machinereadable 2> /dev/null \
		| awk -F'"' -v rule="$1" '$1 ~ /^Forwarding/ && $2 ~ "^" rule "," { print $2; exit }' \
		| cut -d',' -f4
}

# Create a NAT rule only if that name has none yet. Never rewrites an existing
# rule: orchestrate.sh may have moved the port to avoid a clash on this host,
# and stomping that would break a working setup.
ensure_forward() {
	local name="$1" pref="$2" guest="$3" existing
	existing=$(get_forward_port "$name")
	if [ -n "$existing" ]; then
		printf '%s' "$existing"
		return 0
	fi
	if [ "$(vm_state)" = "running" ]; then
		VBoxManage controlvm "$VM_NAME" natpf1 "$name,tcp,,${pref},,${guest}" > /dev/null 2>&1
	else
		VBoxManage modifyvm "$VM_NAME" --natpf1 "$name,tcp,,${pref},,${guest}" > /dev/null 2>&1
	fi
	existing=$(get_forward_port "$name")
	printf '%s' "${existing:-$pref}"
}

# ── Firefox ─────────────────────────────────────────────────────────────────
# Every packaging puts profiles somewhere different; check them all rather than
# assuming. On Ubuntu the default is the snap, whose profiles live under ~/snap.
firefox_roots() {
	printf '%s\n' \
		"$HOME/.mozilla/firefox" \
		"$HOME/snap/firefox/common/.mozilla/firefox" \
		"$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox"
}

# A profile directory is one that Firefox has actually initialised. Matching on
# prefs.js/times.json avoids picking up "Crash Reports" and friends, which sit
# in the same parent directory and are not profiles.
firefox_profiles() {
	local root d
	while read -r root; do
		[ -d "$root" ] || continue
		for d in "$root"/*/; do
			[ -d "$d" ] || continue
			if [ -f "${d}prefs.js" ] || [ -f "${d}times.json" ]; then
				printf '%s\n' "${d%/}"
			fi
		done
	done < <(firefox_roots)
}

# Rewrite user.js keeping every line the user put there themselves: the managed
# block is delimited, so it is removed wholesale and re-appended.
strip_managed_block() {
	local file="$1"
	[ -f "$file" ] || return 0
	awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
		$0 == b { skip = 1; next }
		$0 == e { skip = 0; next }
		!skip   { print }
	' "$file" > "${file}.b2b-tmp" && mv "${file}.b2b-tmp" "$file"
}

configure_firefox() {
	local n=0 profile userjs
	while read -r profile; do
		[ -n "$profile" ] || continue
		userjs="$profile/user.js"
		# Keep one backup of whatever was there before we ever touched it.
		if [ -f "$userjs" ] && [ ! -f "$userjs.b2b-backup" ] \
			&& ! grep -qF "$BEGIN_MARK" "$userjs" 2> /dev/null; then
			cp "$userjs" "$userjs.b2b-backup"
		fi
		strip_managed_block "$userjs"
		{
			printf '%s\n' "$BEGIN_MARK"
			printf '// Resolves %s to 127.0.0.1 inside Firefox only.\n' "$DOMAIN"
			printf '// No DNS server, no /etc/hosts, no proxy, no root involved.\n'
			printf 'user_pref("network.dns.localDomains", "%s");\n' "$DOMAIN"
			# The site is HTTPS on a self-signed local CA. Leaving HTTPS-only
			# mode to auto-upgrade the plain-HTTP bonus site would break it.
			printf 'user_pref("dom.security.https_only_mode", false);\n'
			printf '%s\n' "$END_MARK"
		} >> "$userjs"
		n=$((n + 1))
	done < <(firefox_profiles)

	if [ "$n" -gt 0 ]; then
		ok "Firefox: $n profile(s) now resolve ${C_BOLD}${DOMAIN}${C_RESET} locally"
	else
		warn "Firefox: no initialised profile found — launch Firefox once, then re-run"
	fi
}

undo_firefox() {
	local n=0 profile userjs
	while read -r profile; do
		userjs="$profile/user.js"
		[ -f "$userjs" ] || continue
		grep -qF "$BEGIN_MARK" "$userjs" || continue
		strip_managed_block "$userjs"
		# An empty user.js is indistinguishable from none; remove it so the
		# profile is left exactly as it was found.
		[ -s "$userjs" ] || rm -f "$userjs"
		n=$((n + 1))
	done < <(firefox_profiles)
	ok "Firefox: managed block removed from $n profile(s)"
}

# ── Chromium / Chrome ───────────────────────────────────────────────────────
# Preference order is deliberate: the Chromium snap is what these campus images
# ship and what was verified working here. Keep this list identical to the one
# in verify_inception_access.sh, or the verifier will test a different browser
# from the one the launcher actually runs.
CHROMIUM_CANDIDATES="chromium chromium-browser google-chrome google-chrome-stable brave-browser"

find_chromium() {
	local c
	for c in $CHROMIUM_CANDIDATES; do
		if command -v "$c" > /dev/null 2>&1; then
			command -v "$c"
			return 0
		fi
	done
	return 1
}

# Snap confinement's `home` interface only grants access to NON-hidden paths in
# $HOME, so a snap browser cannot use ~/.local/share for its profile — it fails
# to start with a permissions error. Snaps get their own ~/snap/<name>/common
# instead. Unconfined .deb browsers keep the tidy XDG location.
chromium_profile_dir() {
	local bin="$1" snap_name
	if [ "$(readlink -f "$bin" 2> /dev/null)" = "/usr/bin/snap" ] \
		|| case "$bin" in /snap/*) true ;; *) false ;; esac; then
		snap_name=$(basename "$bin")
		printf '%s' "$HOME/snap/${snap_name}/common/inception-browser"
		return 0
	fi
	printf '%s' "$HOME/.local/share/inception-browser"
}

# Pin the exact CA instead of blanket --ignore-certificate-errors when the CA is
# reachable: the launcher then trusts this one local CA and nothing else.
ca_spki_pin() {
	local ca_tmp pin
	command -v openssl > /dev/null 2>&1 || return 1
	ca_tmp=$(mktemp) || return 1
	if ! timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=8 b2b \
		'cat ~/Documents/inception/secrets/ca.crt' > "$ca_tmp" 2> /dev/null \
		|| [ ! -s "$ca_tmp" ]; then
		rm -f "$ca_tmp"
		return 1
	fi
	pin=$(openssl x509 -in "$ca_tmp" -pubkey -noout 2> /dev/null \
		| openssl pkey -pubin -outform der 2> /dev/null \
		| openssl dgst -sha256 -binary 2> /dev/null \
		| base64) || { rm -f "$ca_tmp"; return 1; }
	rm -f "$ca_tmp"
	[ -n "$pin" ] || return 1
	printf '%s' "$pin"
}

configure_chromium() {
	local browser https_port static_port http_port rules pin cert_flag
	browser=$(find_chromium) || {
		warn "Chromium/Chrome not found — skipping the bare-URL launcher"
		return 0
	}
	https_port="$1"; static_port="$2"; http_port="$3"
	CHROME_PROFILE=$(chromium_profile_dir "$browser")

	# MAP accepts host:port on both sides, which is what buys the portless URL:
	# the browser believes it is talking to :443 and the connection lands on the
	# forwarded host port instead.
	rules="MAP ${DOMAIN}:443 127.0.0.1:${https_port}"
	rules="${rules},MAP ${DOMAIN}:80 127.0.0.1:${http_port}"
	rules="${rules},MAP ${DOMAIN}:${static_port} 127.0.0.1:${static_port}"

	if pin=$(ca_spki_pin); then
		cert_flag="--ignore-certificate-errors-spki-list=${pin}"
	else
		# No CA yet (Inception not deployed): fall back to skipping cert checks.
		# Scoped to the dedicated profile below, never the user's main browser.
		cert_flag="--ignore-certificate-errors"
	fi

	mkdir -p "$(dirname "$LAUNCHER")" "$CHROME_PROFILE"
	cat > "$LAUNCHER" << LAUNCHEOF
#!/usr/bin/env bash
# Auto-generated by born2root (setup/host/inception_host_access.sh).
# Opens the Inception site at its real domain, with no host DNS entry and no
# root: --host-resolver-rules resolves and port-maps the name in-browser.
#
# A dedicated --user-data-dir keeps every flag here — including the certificate
# exception — away from your normal browsing profile.
exec "${browser}" \\
    --user-data-dir="${CHROME_PROFILE}" \\
    --host-resolver-rules="${rules}" \\
    ${cert_flag} \\
    --no-first-run --no-default-browser-check \\
    "\${@:-https://${DOMAIN}/}"
LAUNCHEOF
	chmod +x "$LAUNCHER"

	mkdir -p "$(dirname "$DESKTOP_FILE")"
	cat > "$DESKTOP_FILE" << DESKTOPEOF
[Desktop Entry]
Type=Application
Name=Inception (${DOMAIN})
Comment=Open the Inception site at its real domain — no root, no DNS entry
Exec=${LAUNCHER} %U
Terminal=false
Categories=Network;WebBrowser;
DESKTOPEOF

	if [ -n "${pin:-}" ]; then
		ok "Chromium launcher written (local CA pinned, no warning)"
	else
		ok "Chromium launcher written (CA not published yet — cert check skipped)"
	fi
}

undo_chromium() {
	rm -f "$LAUNCHER" "$DESKTOP_FILE"
	# CHROME_PROFILE is only resolved during configure, so clear both candidates.
	rm -rf "$HOME/.local/share/inception-browser"
	rm -rf "$HOME"/snap/*/common/inception-browser
	ok "Chromium launcher, desktop entry and its profile removed"
}

# ── curl / shell convenience ────────────────────────────────────────────────
configure_curl_wrapper() {
	local https_port="$1" static_port="$2" http_port="$3"
	mkdir -p "$(dirname "$CURL_WRAPPER")"
	cat > "$CURL_WRAPPER" << CURLEOF
#!/usr/bin/env bash
# Auto-generated by born2root. curl, with ${DOMAIN} resolved for this call only
# (--resolve is curl's own equivalent of the browser tricks above).
exec curl \\
    --resolve "${DOMAIN}:443:127.0.0.1" \\
    --resolve "${DOMAIN}:${https_port}:127.0.0.1" \\
    --resolve "${DOMAIN}:${static_port}:127.0.0.1" \\
    --resolve "${DOMAIN}:80:127.0.0.1" \\
    --connect-to "${DOMAIN}:443:127.0.0.1:${https_port}" \\
    --connect-to "${DOMAIN}:80:127.0.0.1:${http_port}" \\
    "\$@"
CURLEOF
	chmod +x "$CURL_WRAPPER"
	ok "inception-curl wrapper written"
}

# ── Main ────────────────────────────────────────────────────────────────────
printf "\n${C_BOLD}Inception host access${C_RESET} ${C_DIM}(domain: %s)${C_RESET}\n" "$DOMAIN"

if [ "$ACTION" = "undo" ]; then
	undo_firefox
	undo_chromium
	rm -f "$CURL_WRAPPER"
	printf "\n  Host is back to its original state. NAT rules were left alone\n"
	printf "  (delete them with: VBoxManage controlvm %s natpf1 delete <name>).\n\n" "$VM_NAME"
	exit 0
fi

if have_vm; then
	P_HTTPS=$(ensure_forward https "$PREF_HTTPS_PORT" "$GUEST_HTTPS")
	P_STATIC=$(ensure_forward inception-static "$PREF_STATIC_PORT" "$GUEST_STATIC")
	P_HTTP=$(ensure_forward http "$PREF_HTTP_PORT" "$GUEST_HTTP")
	ok "NAT forwards: https→${P_HTTPS}  static→${P_STATIC}  http→${P_HTTP}"
else
	P_HTTPS="$PREF_HTTPS_PORT"; P_STATIC="$PREF_STATIC_PORT"; P_HTTP="$PREF_HTTP_PORT"
	warn "VM '$VM_NAME' not registered yet — assuming default ports"
fi

configure_firefox
configure_chromium "$P_HTTPS" "$P_STATIC" "$P_HTTP"
configure_curl_wrapper "$P_HTTPS" "$P_STATIC" "$P_HTTP"

printf "\n  ${C_BOLD}Open from this host:${C_RESET}\n"
printf "    Chromium   ${C_BOLD}inception-browser${C_RESET}   ${C_DIM}→ https://%s${C_RESET}\n" "$DOMAIN"
printf "    Firefox    ${C_BOLD}https://%s:%s${C_RESET}\n" "$DOMAIN" "$P_HTTPS"
printf "    Bonus site ${C_BOLD}http://%s:%s${C_RESET}\n" "$DOMAIN" "$P_STATIC"
printf "    Terminal   ${C_BOLD}inception-curl -k https://%s/${C_RESET}\n" "$DOMAIN"
printf "\n  ${C_DIM}Firefox must be fully restarted to pick up the new pref.${C_RESET}\n"
printf "  ${C_DIM}Its certificate warning is expected — the CA is local and self-signed.${C_RESET}\n\n"
