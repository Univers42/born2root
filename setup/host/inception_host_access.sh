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

PROXY_PORT="${INCEPTION_PROXY_PORT:-8118}"
PROXY_DIR="$HOME/.local/share/born2root"
PROXY_BIN="$PROXY_DIR/inception_proxy.py"
PROXY_UNIT="$HOME/.config/systemd/user/inception-proxy.service"
PAC_NAME="inception.pac"
DESKTOP_PAC="$HOME/.config/born2root/$PAC_NAME"
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

trap '[ -n "$CA_FILE" ] && rm -f "$CA_FILE"' EXIT

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

# ── The local port-rewriting proxy ──────────────────────────────────────────
# Firefox can be told to resolve a name (network.dns.localDomains) but not to
# change the port, so the bare https://<domain> ends up at 127.0.0.1:443 —
# which nothing may bind here, because ip_unprivileged_port_start is 1024.
# A proxied request carries the intended host AND port inside the request, so a
# proxy can send it to the forwarded high port while the URL, the SNI name and
# the Host header all still say the real domain on 443.
port_is_free() {
	python3 - "$1" 2> /dev/null << 'PYEOF'
import socket, sys
s = socket.socket()
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    s.close()
PYEOF
}

# Reuse the port already in the unit if there is one, so a re-run does not move
# the proxy out from under a browser that is configured for it.
pick_proxy_port() {
	local existing candidate
	if [ -f "$PROXY_UNIT" ]; then
		existing=$(sed -n 's/.*--port \([0-9]\+\).*/\1/p' "$PROXY_UNIT" | head -1)
		if [ -n "$existing" ]; then
			printf '%s' "$existing"
			return 0
		fi
	fi
	for candidate in "$PROXY_PORT" 8119 3128 8888 18118; do
		if port_is_free "$candidate"; then
			printf '%s' "$candidate"
			return 0
		fi
	done
	printf '%s' "$PROXY_PORT"
}

install_proxy_service() {
	local https_port="$1" static_port="$2" http_port="$3"
	local src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/inception_proxy.py"
	if [ ! -f "$src" ]; then
		warn "inception_proxy.py missing — the bare URL will not work"
		return 1
	fi
	command -v python3 > /dev/null 2>&1 || { warn "no python3 — skipping the proxy"; return 1; }

	# Copied out of the repo so the service keeps working if the checkout moves.
	mkdir -p "$PROXY_DIR"
	install -m 0755 "$src" "$PROXY_BIN"

	mkdir -p "$(dirname "$PROXY_UNIT")"
	cat > "$PROXY_UNIT" << UNITEOF
[Unit]
Description=Inception local proxy (bare https://${DOMAIN} on an unprivileged host)
After=network.target

[Service]
ExecStart=/usr/bin/env python3 ${PROXY_BIN} --port ${PROXY_PORT} --domain ${DOMAIN} \
    --map 443:${https_port} --map 80:${http_port} \
    --map ${static_port}:${static_port} --map ${https_port}:${https_port}
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
UNITEOF

	systemctl --user daemon-reload > /dev/null 2>&1
	systemctl --user reset-failed inception-proxy.service > /dev/null 2>&1 || true
	# enable --now is a no-op on an already-running unit, so it would keep an
	# older copy of the proxy alive after an upgrade. Always restart.
	systemctl --user enable inception-proxy.service > /dev/null 2>&1
	if systemctl --user restart inception-proxy.service > /dev/null 2>&1; then
		local i
		for i in 1 2 3 4 5 6 7 8 9 10; do
			port_is_free "$PROXY_PORT" || break   # bound = it is up
			sleep 0.5
		done
		if port_is_free "$PROXY_PORT"; then
			warn "proxy service did not come up on ${PROXY_PORT}"
			return 1
		fi
		ok "local proxy running on 127.0.0.1:${PROXY_PORT} (systemd --user, restarts on login)"
		return 0
	fi
	warn "could not start the proxy service"
	return 1
}

# Only this domain is proxied; everything else stays DIRECT. The trailing
# DIRECT is a fallback, so a stopped proxy degrades to a normal connection
# rather than breaking the browser.
pac_body() {
	cat << PACEOF
function FindProxyForURL(url, host) {
    if (host === "${DOMAIN}" || dnsDomainIs(host, ".${DOMAIN}"))
        return "PROXY 127.0.0.1:${PROXY_PORT}; DIRECT";
    return "DIRECT";
}
PACEOF
}

# Chrome and the rest of the desktop read GNOME's proxy setting. Only touched
# when nothing else has configured it, so an existing proxy is never clobbered.
configure_desktop_proxy() {
	command -v gsettings > /dev/null 2>&1 || return 0
	local mode current
	mode=$(gsettings get org.gnome.system.proxy mode 2> /dev/null | tr -d "'")
	current=$(gsettings get org.gnome.system.proxy autoconfig-url 2> /dev/null | tr -d "'")
	if [ "$mode" != "none" ] \
		&& [ "$current" != "http://127.0.0.1:${PROXY_PORT}/inception.pac" ] \
		&& [ "$current" != "file://$DESKTOP_PAC" ]; then
		warn "desktop proxy already set to '$mode' — left alone; use inception-browser for Chrome"
		return 0
	fi
	# Chrome refuses a file:// PAC URL that comes from the desktop proxy
	# settings — it silently falls back to no proxy, which is why the domain
	# still failed there with NXDOMAIN. The proxy serves the same PAC over
	# http, which Chrome accepts.
	gsettings set org.gnome.system.proxy autoconfig-url \
		"http://127.0.0.1:${PROXY_PORT}/inception.pac" 2> /dev/null
	gsettings set org.gnome.system.proxy mode 'auto' 2> /dev/null
	rm -f "$DESKTOP_PAC" 2> /dev/null
	ok "desktop proxy points at the PAC over http — plain Chrome gets the bare URL"
}

undo_desktop_proxy() {
	command -v gsettings > /dev/null 2>&1 || return 0
	local current
	current=$(gsettings get org.gnome.system.proxy autoconfig-url 2> /dev/null | tr -d "'")
	case "$current" in
		"file://$DESKTOP_PAC" | http://127.0.0.1:*/inception.pac)
		gsettings set org.gnome.system.proxy mode 'none' 2> /dev/null
			gsettings set org.gnome.system.proxy autoconfig-url '' 2> /dev/null
			;;
	esac
	rm -f "$DESKTOP_PAC"
}

undo_proxy_service() {
	systemctl --user disable --now inception-proxy.service > /dev/null 2>&1
	rm -f "$PROXY_UNIT" "$PROXY_BIN"
	systemctl --user daemon-reload > /dev/null 2>&1
	ok "local proxy service stopped and removed"
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
			# The PAC lives inside the profile because snap confinement blocks
			# a snap Firefox from reading hidden paths elsewhere in $HOME.
			pac_body > "$profile/$PAC_NAME"
			printf 'user_pref("network.proxy.type", 2);\n'
			printf 'user_pref("network.proxy.autoconfig_url", "file://%s/%s");\n' \
				"$profile" "$PAC_NAME"
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
	local n=0 profile userjs certutil_bin
	certutil_bin=$(find_certutil 2> /dev/null) || certutil_bin=""
	while read -r profile; do
		userjs="$profile/user.js"
		[ -f "$userjs" ] || continue
		grep -qF "$BEGIN_MARK" "$userjs" || continue
		strip_managed_block "$userjs"
		# An empty user.js is indistinguishable from none; remove it so the
		# profile is left exactly as it was found.
		[ -s "$userjs" ] || rm -f "$userjs"
		rm -f "$profile/$PAC_NAME"
		[ -n "$certutil_bin" ] && "$certutil_bin" -D -n "$CA_NICKNAME" \
			-d "sql:$profile" > /dev/null 2>&1
		n=$((n + 1))
	done < <(firefox_profiles)
	ok "Firefox: managed block removed from $n profile(s)"
}

# Firefox reads user.js once, at profile startup. A Firefox that was already
# running when we wrote the pref will never see it, and reports the domain as
# "Server Not Found" exactly as if nothing had been configured — so say so
# instead of leaving a silent trap.
firefox_main_pid() {
	pgrep -f '/firefox/firefox' 2> /dev/null | head -1
}

warn_if_firefox_running() {
	local pid
	pid=$(firefox_main_pid)
	[ -n "$pid" ] || return 0
	printf "\n  ${C_YELLOW}${C_BOLD}Firefox is running and will NOT pick this up yet.${C_RESET}\n"
	printf "  ${C_DIM}user.js is only read when a profile starts, so the pref is inert${C_RESET}\n"
	printf "  ${C_DIM}until it restarts, and that now covers the proxy settings too,${C_RESET}\n"
	printf "  ${C_DIM}so about:config is no longer a shortcut worth taking.${C_RESET}\n\n"
	printf "    ${C_BOLD}Quit Firefox completely${C_RESET} — every window, the process must exit —\n"
	printf "    then reopen it. Everything is already written to disk.\n"
}

# Chrome and Chromium do not read Firefox's certificate store; they use NSS's
# shared database instead. Without the CA there, plain Chrome reaches the site
# and then refuses it with ERR_CERT_AUTHORITY_INVALID. The snap build cannot see
# ~/.pki (snap confinement hides dot-directories in $HOME) and keeps its own
# copy under ~/snap/chromium, so both are populated when present.
chrome_nss_dirs() {
	printf '%s\n' "$HOME/.pki/nssdb"
	local d
	for d in "$HOME"/snap/chromium/current/.pki/nssdb \
		"$HOME"/snap/chromium/common/.pki/nssdb; do
		[ -d "$(dirname "$(dirname "$d")")" ] && printf '%s\n' "$d"
	done
}

install_ca_into_chrome() {
	local certutil_bin n=0 dir
	fetch_ca_cert || return 0
	certutil_bin=$(find_certutil) || return 0
	while read -r dir; do
		[ -n "$dir" ] || continue
		mkdir -p "$dir" 2> /dev/null || continue
		# A profile that has never stored a certificate has no database yet.
		"$certutil_bin" -L -d "sql:$dir" > /dev/null 2>&1 \
			|| "$certutil_bin" -N --empty-password -d "sql:$dir" > /dev/null 2>&1
		"$certutil_bin" -D -n "$CA_NICKNAME" -d "sql:$dir" > /dev/null 2>&1
		if "$certutil_bin" -A -n "$CA_NICKNAME" -t "C,," -d "sql:$dir" \
			-i "$CA_FILE" > /dev/null 2>&1; then
			n=$((n + 1))
		fi
	done < <(chrome_nss_dirs)
	if [ "$n" -gt 0 ]; then
		ok "Chrome: local CA trusted in $n NSS store(s) — no certificate warning"
	else
		warn "Chrome: could not add the CA — it will warn about the certificate"
	fi
}

undo_ca_from_chrome() {
	local certutil_bin dir
	certutil_bin=$(find_certutil 2> /dev/null) || return 0
	while read -r dir; do
		[ -d "$dir" ] || continue
		"$certutil_bin" -D -n "$CA_NICKNAME" -d "sql:$dir" > /dev/null 2>&1
	done < <(chrome_nss_dirs)
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

# The local CA lives in the guest, where inception's `make certs` issued it.
# Fetched once and reused: the SPKI pin for Chromium, and the DER/PEM for
# Firefox's certificate store.
CA_FILE=""
# The clone location is not fixed: Inception may sit in ~/Documents/inception,
# in ~/inception, or wherever INCEPTION_DIR points. Hardcoding one path meant
# the CA silently could not be found and the browsers kept warning.
CA_FIND_CMD='for p in "$INCEPTION_DIR/secrets/ca.crt" "$HOME/Documents/inception/secrets/ca.crt" "$HOME/inception/secrets/ca.crt"; do [ -r "$p" ] && { cat "$p"; exit 0; }; done; p=$(find "$HOME" -maxdepth 4 -name ca.crt -path "*secrets*" 2>/dev/null | head -1); [ -n "$p" ] && cat "$p"'
fetch_ca_cert() {
	[ -n "$CA_FILE" ] && [ -s "$CA_FILE" ] && return 0
	local tmp
	tmp=$(mktemp) || return 1
	if timeout 25 ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8 b2b \
		"$CA_FIND_CMD" > "$tmp" 2> /dev/null \
		&& [ -s "$tmp" ]; then
		CA_FILE="$tmp"
		return 0
	fi
	rm -f "$tmp"
	return 1
}

# Pin the exact CA instead of blanket --ignore-certificate-errors when the CA is
# reachable: the launcher then trusts this one local CA and nothing else.
ca_spki_pin() {
	command -v openssl > /dev/null 2>&1 || return 1
	fetch_ca_cert || return 1
	local pin
	pin=$(openssl x509 -in "$CA_FILE" -pubkey -noout 2> /dev/null \
		| openssl pkey -pubin -outform der 2> /dev/null \
		| openssl dgst -sha256 -binary 2> /dev/null \
		| base64) || return 1
	[ -n "$pin" ] || return 1
	printf '%s' "$pin"
}

# Firefox keeps its own certificate store (cert9.db) and ignores the system one,
# so the CA has to be added with NSS's certutil. That lives in libnss3-tools,
# which is not installed here and needs root to install — but the package can be
# downloaded and unpacked as an ordinary user, and the binary then links against
# the system libnss3 that Firefox itself already provides.
CERTUTIL_CACHE="$HOME/.cache/born2root/nss"
find_certutil() {
	if command -v certutil > /dev/null 2>&1; then
		command -v certutil
		return 0
	fi
	if [ -x "$CERTUTIL_CACHE/usr/bin/certutil" ]; then
		printf '%s' "$CERTUTIL_CACHE/usr/bin/certutil"
		return 0
	fi
	command -v apt-get > /dev/null 2>&1 && command -v dpkg-deb > /dev/null 2>&1 || return 1
	local dl
	dl=$(mktemp -d) || return 1
	if ( cd "$dl" && timeout 120 apt-get download libnss3-tools > /dev/null 2>&1 ) \
		&& ls "$dl"/libnss3-tools_*.deb > /dev/null 2>&1; then
		mkdir -p "$CERTUTIL_CACHE"
		dpkg-deb -x "$dl"/libnss3-tools_*.deb "$CERTUTIL_CACHE" > /dev/null 2>&1
	fi
	rm -rf "$dl"
	[ -x "$CERTUTIL_CACHE/usr/bin/certutil" ] || return 1
	printf '%s' "$CERTUTIL_CACHE/usr/bin/certutil"
}

CA_NICKNAME="Inception Local CA"
CA_TRUSTED=0
install_ca_into_firefox() {
	local certutil_bin n=0 profile
	if ! fetch_ca_cert; then
		warn "Firefox: CA not published yet — the certificate warning will still appear"
		return 0
	fi
	if ! certutil_bin=$(find_certutil); then
		warn "Firefox: no certutil — accept the certificate warning once per profile"
		return 0
	fi
	while read -r profile; do
		[ -n "$profile" ] || continue
		# Delete first so a reissued CA replaces the old one instead of leaving
		# two entries with the same nickname behind.
		"$certutil_bin" -D -n "$CA_NICKNAME" -d "sql:$profile" > /dev/null 2>&1
		if "$certutil_bin" -A -n "$CA_NICKNAME" -t "C,," -d "sql:$profile" \
			-i "$CA_FILE" > /dev/null 2>&1; then
			n=$((n + 1))
		fi
	done < <(firefox_profiles)
	if [ "$n" -gt 0 ]; then
		CA_TRUSTED=1
		ok "Firefox: local CA trusted in $n profile(s) — no certificate warning"
	else
		warn "Firefox: could not add the CA — accept the warning once per profile"
	fi
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
	undo_ca_from_chrome
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
	undo_desktop_proxy
	undo_proxy_service
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

PROXY_PORT=$(pick_proxy_port)
install_proxy_service "$P_HTTPS" "$P_STATIC" "$P_HTTP" && PROXY_OK=1 || PROXY_OK=0

configure_firefox
install_ca_into_firefox
install_ca_into_chrome
configure_chromium "$P_HTTPS" "$P_STATIC" "$P_HTTP"
configure_curl_wrapper "$P_HTTPS" "$P_STATIC" "$P_HTTP"
[ "$PROXY_OK" = "1" ] && configure_desktop_proxy

printf "\n  ${C_BOLD}Open from this host:${C_RESET}\n"
if [ "$PROXY_OK" = "1" ]; then
	printf "    Any browser  ${C_BOLD}https://%s${C_RESET}   ${C_DIM}(no port)${C_RESET}\n" "$DOMAIN"
	printf "    Bonus site   ${C_BOLD}http://%s:%s${C_RESET}\n" "$DOMAIN" "$P_STATIC"
else
	printf "    Chromium     ${C_BOLD}inception-browser${C_RESET}   ${C_DIM}→ https://%s${C_RESET}\n" "$DOMAIN"
	printf "    Firefox      ${C_BOLD}https://%s:%s${C_RESET}\n" "$DOMAIN" "$P_HTTPS"
	printf "    Bonus site   ${C_BOLD}http://%s:%s${C_RESET}\n" "$DOMAIN" "$P_STATIC"
fi
printf "    Terminal     ${C_BOLD}inception-curl https://%s/${C_RESET}\n" "$DOMAIN"
if [ "$CA_TRUSTED" = "1" ]; then
	printf "\n  ${C_DIM}The local CA is trusted in both browsers — no certificate warning.${C_RESET}\n"
else
	printf "\n  ${C_DIM}Firefox will warn about the certificate: the CA is local and${C_RESET}\n"
	printf "  ${C_DIM}self-signed, and could not be added to its store. Accept it once.${C_RESET}\n"
fi
# Only restart once there is a complete configuration to pick up. During
# `make all` the VM has no Inception yet, so no CA could be fetched and a
# restart then would just force a second one after `make inception`.
if [ "$CA_TRUSTED" = "1" ]; then
	bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/restart_browsers.sh"
else
	warn_if_firefox_running
fi
printf "\n"
