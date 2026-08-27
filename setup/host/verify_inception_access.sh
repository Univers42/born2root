#!/usr/bin/env bash
# ============================================================================ #
#  born2root — prove the Inception domain really works FROM THE HOST           #
# ============================================================================ #
#
# This checks the whole chain end to end, not just that a port is open:
#
#   1. the NAT forwards exist
#   2. the host can reach the guest on them
#   3. nginx serves the real domain (SNI + certificate CN both match)
#   4. WordPress does NOT redirect a host:port Host header away to the bare
#      domain — the failure that made every previous attempt look broken
#   5. Firefox's profiles carry the resolver pref
#   6. Chromium actually loads the bare https://<domain> URL, driven headless
#      here so the result is evidence rather than an instruction to go and click
#
# Exit status is non-zero if any REQUIRED check fails, so `make verify_access`
# is usable as a gate.
# ============================================================================ #

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_NAME="${VM_NAME:-debian}"
DOMAIN="${INCEPTION_DOMAIN:-dlesieur.42.fr}"
SSH_ALIAS="${SSH_ALIAS:-b2b}"

C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'

FAILED=0
pass() { printf "  ${C_GREEN}✓${C_RESET} %s\n" "$*"; }
fail() { printf "  ${C_RED}✗${C_RESET} %s\n" "$*"; FAILED=$((FAILED + 1)); }
warn() { printf "  ${C_YELLOW}⚠${C_RESET}  %s\n" "$*"; }
head_() { printf "\n${C_BOLD}%s${C_RESET}\n" "$*"; }

get_forward_port() {
	VBoxManage showvminfo "$VM_NAME" --machinereadable 2> /dev/null \
		| awk -F'"' -v rule="$1" '$1 ~ /^Forwarding/ && $2 ~ "^" rule "," { print $2; exit }' \
		| cut -d',' -f4
}

# ── 1. NAT forwards ─────────────────────────────────────────────────────────
head_ "NAT port forwarding"
P_HTTPS=$(get_forward_port https)
P_STATIC=$(get_forward_port inception-static)
[ -n "$P_HTTPS" ]  && pass "https  host:${P_HTTPS} → guest:443"  || fail "no 'https' NAT rule"
[ -n "$P_STATIC" ] && pass "static host:${P_STATIC} → guest:8090" || fail "no 'inception-static' NAT rule"
: "${P_HTTPS:=8443}"; : "${P_STATIC:=8090}"

# ── 2/3. The domain over HTTPS, as the browser will ask for it ──────────────
head_ "Serving the real domain to the host"
code=$(curl -ks -o /dev/null -w '%{http_code}' --max-time 15 \
	--resolve "${DOMAIN}:${P_HTTPS}:127.0.0.1" "https://${DOMAIN}:${P_HTTPS}/")
[ "$code" = "200" ] && pass "https://${DOMAIN}:${P_HTTPS}/ → 200" \
	|| fail "https://${DOMAIN}:${P_HTTPS}/ → ${code:-no response}"

cn=$(curl -ks -o /dev/null --max-time 15 --resolve "${DOMAIN}:${P_HTTPS}:127.0.0.1" \
	-w '%{ssl_verify_result}' "https://${DOMAIN}:${P_HTTPS}/" > /dev/null 2>&1; \
	echo | openssl s_client -connect "127.0.0.1:${P_HTTPS}" -servername "$DOMAIN" 2> /dev/null \
	| openssl x509 -noout -subject 2> /dev/null)
case "$cn" in
	*"CN = ${DOMAIN}"* | *"CN=${DOMAIN}"*) pass "certificate presented for SNI ${DOMAIN} (${cn#subject=})" ;;
	*) warn "certificate subject unexpected: ${cn:-unreadable}" ;;
esac

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
	--resolve "${DOMAIN}:${P_STATIC}:127.0.0.1" "http://${DOMAIN}:${P_STATIC}/")
[ "$code" = "200" ] && pass "http://${DOMAIN}:${P_STATIC}/ → 200 (bonus static site)" \
	|| fail "http://${DOMAIN}:${P_STATIC}/ → ${code:-no response}"

# ── 4. The redirect trap ────────────────────────────────────────────────────
# WordPress 301s any request whose Host differs from its stored siteurl. With a
# port in the Host header that sends the browser to https://<domain>/ on port
# 443, where nothing is listening on the host — the exact dead end that made
# this look unfixable before. wp-config.php has to echo the requested host back.
head_ "WordPress host handling (the redirect trap)"
hdrs=$(curl -ks -D - -o /dev/null --max-time 15 \
	--resolve "${DOMAIN}:${P_HTTPS}:127.0.0.1" "https://${DOMAIN}:${P_HTTPS}/")
status=$(printf '%s' "$hdrs" | awk 'NR==1{print $2}')
location=$(printf '%s' "$hdrs" | awk 'BEGIN{IGNORECASE=1}/^location:/{print $2}' | tr -d '\r')
if [ "$status" = "200" ]; then
	pass "no redirect away from ${DOMAIN}:${P_HTTPS} (status 200)"
else
	fail "got ${status} → ${location:-?} — wp-config.php is not honouring the request Host"
fi

body=$(curl -ks --max-time 15 --resolve "${DOMAIN}:${P_HTTPS}:127.0.0.1" "https://${DOMAIN}:${P_HTTPS}/")
if printf '%s' "$body" | grep -q "https://${DOMAIN}:${P_HTTPS}/"; then
	pass "page assets are scoped to ${DOMAIN}:${P_HTTPS} (CSS/JS will load)"
elif printf '%s' "$body" | grep -q "https://${DOMAIN}/"; then
	fail "page assets point at https://${DOMAIN}/ with no port — they will not load"
else
	warn "could not find absolute asset URLs to check"
fi

# ── 4b. The bare, portless URL ──────────────────────────────────────────────
# Nothing may bind host port 443 here, so https://<domain> can only work if a
# local proxy rewrites the port. Check the proxy is up and that the bare URL
# resolves, connects and validates through it.
head_ "Bare https://${DOMAIN} (no port)"
PROXY_PORT=$(sed -n 's/.*--port \([0-9]\+\).*/\1/p' \
	"$HOME/.config/systemd/user/inception-proxy.service" 2> /dev/null | head -1)
: "${PROXY_PORT:=8118}"

if systemctl --user is-active inception-proxy.service > /dev/null 2>&1; then
	pass "proxy service active on 127.0.0.1:${PROXY_PORT}"
else
	fail "inception-proxy.service is not running — run: make host_access"
fi

# Fetch the CA so the check can demand a genuinely valid chain rather than -k.
ca_tmp=$(mktemp)
ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	-o LogLevel=ERROR -o ConnectTimeout=8 "$SSH_ALIAS" \
	'cat ~/Documents/inception/secrets/ca.crt' > "$ca_tmp" 2> /dev/null
if [ -s "$ca_tmp" ]; then
	res=$(curl -s --proxy "127.0.0.1:${PROXY_PORT}" --cacert "$ca_tmp" --max-time 20 \
		-o /dev/null -w '%{http_code}:%{ssl_verify_result}' "https://${DOMAIN}/")
	case "$res" in
		200:0) pass "https://${DOMAIN}/ → 200 with a fully valid certificate (no -k)" ;;
		200:*) warn "https://${DOMAIN}/ → 200 but TLS verify result ${res#*:}" ;;
		*)     fail "https://${DOMAIN}/ → ${res%%:*} through the proxy" ;;
	esac
else
	res=$(curl -ks --proxy "127.0.0.1:${PROXY_PORT}" --max-time 20 \
		-o /dev/null -w '%{http_code}' "https://${DOMAIN}/")
	[ "$res" = "200" ] && pass "https://${DOMAIN}/ → 200 through the proxy" \
		|| fail "https://${DOMAIN}/ → ${res:-no response} through the proxy"
fi
rm -f "$ca_tmp"

# Chrome takes its PAC from the desktop proxy setting and refuses a file:// URL
# there, so the proxy serves the PAC itself over http. If this endpoint is not
# answering, Chrome silently falls back to no proxy and the domain fails with
# NXDOMAIN while every other check here still passes.
pac=$(curl -s --max-time 10 "http://127.0.0.1:${PROXY_PORT}/inception.pac" 2> /dev/null)
if printf '%s' "$pac" | grep -q "FindProxyForURL" \
	&& printf '%s' "$pac" | grep -q "$DOMAIN"; then
	pass "PAC served over http for Chrome and the desktop"
else
	fail "PAC endpoint http://127.0.0.1:${PROXY_PORT}/inception.pac is not answering"
fi

if command -v gsettings > /dev/null 2>&1; then
	gs_mode=$(gsettings get org.gnome.system.proxy mode 2> /dev/null | tr -d "'")
	gs_url=$(gsettings get org.gnome.system.proxy autoconfig-url 2> /dev/null | tr -d "'")
	if [ "$gs_mode" = "auto" ] && [ "$gs_url" = "http://127.0.0.1:${PROXY_PORT}/inception.pac" ]; then
		pass "desktop proxy points at that PAC (plain Chrome picks it up)"
	else
		warn "desktop proxy is '${gs_mode}' — plain Chrome needs it, or use inception-browser"
	fi
fi

# The proxy must serve this domain and nothing else.
other=$(curl -s --proxy "127.0.0.1:${PROXY_PORT}" --max-time 10 \
	-o /dev/null -w '%{http_code}' "http://example.com/" 2> /dev/null)
[ "$other" = "403" ] && pass "proxy refuses every other host (example.com → 403)" \
	|| warn "proxy returned ${other:-nothing} for example.com — expected 403"

# ── 5. Firefox ──────────────────────────────────────────────────────────────
head_ "Firefox"
found=0; configured=0
for root in "$HOME/.mozilla/firefox" "$HOME/snap/firefox/common/.mozilla/firefox" \
	"$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox"; do
	[ -d "$root" ] || continue
	for d in "$root"/*/; do
		[ -f "${d}prefs.js" ] || [ -f "${d}times.json" ] || continue
		found=$((found + 1))
		if grep -q "network.dns.localDomains.*${DOMAIN}" "${d}user.js" 2> /dev/null \
			&& grep -q 'network.proxy.autoconfig_url' "${d}user.js" 2> /dev/null \
			&& [ -f "${d}inception.pac" ]; then
			configured=$((configured + 1))
		fi
	done
done
if [ "$found" -eq 0 ]; then
	warn "no Firefox profile found on this host"
elif [ "$configured" -eq "$found" ]; then
	pass "${configured}/${found} profile(s) resolve ${DOMAIN} → 127.0.0.1"
else
	fail "only ${configured}/${found} profile(s) configured — run: make host_access"
fi

# Firefox keeps its own certificate store and ignores the system one, so the
# local CA has to be in cert9.db or every visit opens on a full-page security
# warning — which reads as "the certificate is wrong" rather than "this CA is
# unknown here", and is what the warning actually means.
certutil_bin=""
for c in certutil "$HOME/.cache/born2root/nss/usr/bin/certutil"; do
	command -v "$c" > /dev/null 2>&1 && { certutil_bin=$(command -v "$c"); break; }
	[ -x "$c" ] && { certutil_bin="$c"; break; }
done
if [ -n "$certutil_bin" ] && [ "$found" -gt 0 ]; then
	ca_ok=0
	for root in "$HOME/.mozilla/firefox" "$HOME/snap/firefox/common/.mozilla/firefox" \
		"$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox"; do
		[ -d "$root" ] || continue
		for d in "$root"/*/; do
			[ -f "${d}prefs.js" ] || [ -f "${d}times.json" ] || continue
			"$certutil_bin" -L -d "sql:${d%/}" 2> /dev/null \
				| grep -q "Inception Local CA" && ca_ok=$((ca_ok + 1))
		done
	done
	if [ "$ca_ok" -eq "$found" ]; then
		pass "local CA trusted in ${ca_ok}/${found} profile(s) — no security warning"
	else
		fail "local CA missing from $((found - ca_ok))/${found} profile(s) — Firefox will warn"
	fi
fi

# A scratch profile always starts fresh and therefore always loads the pref —
# which means the check below proves the MECHANISM, not the browser the user is
# actually looking at. A Firefox that was already running when user.js was
# written never read it and shows "Server Not Found". That combination once
# reported "all checks passed" over a genuinely broken browser, so check it
# explicitly and fail.
ff_pid=$(pgrep -f '/firefox/firefox' 2> /dev/null | head -1)
if [ -n "$ff_pid" ] && [ "$configured" -gt 0 ]; then
	ff_elapsed=$(ps -o etimes= -p "$ff_pid" 2> /dev/null | tr -d ' ')
	if [ -n "$ff_elapsed" ]; then
		ff_started=$(( $(date +%s) - ff_elapsed ))
		newest_userjs=0
		for root in "$HOME/.mozilla/firefox" "$HOME/snap/firefox/common/.mozilla/firefox" \
			"$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox"; do
			[ -d "$root" ] || continue
			for f in "$root"/*/user.js; do
				[ -f "$f" ] || continue
				m=$(stat -c %Y "$f" 2> /dev/null) || continue
				[ "$m" -gt "$newest_userjs" ] && newest_userjs=$m
			done
		done
		if [ "$ff_started" -lt "$newest_userjs" ]; then
			fail "the running Firefox started before the pref was written — it has not read it"
			printf "      ${C_DIM}quit Firefox completely — every window — and reopen it${C_RESET}\n"
		else
			pass "the running Firefox started after the pref was written"
		fi
	fi
fi

# End-to-end proof rather than a claim. Firefox is pointed at the REAL domain on
# a throwaway port served by a listener started here on the host: if the request
# arrives, Firefox genuinely resolved that exact name by itself. Testing against
# a host-local listener rather than the guest keeps the check independent of
# whether the containers happen to log their accesses.
if command -v firefox > /dev/null 2>&1 && command -v python3 > /dev/null 2>&1 && [ "$found" -gt 0 ]; then
	# NOT a dot-directory: snap confinement blocks hidden paths in $HOME,
	# and snap Firefox silently fails to load a profile placed in one.
	tmpdir=$(mktemp -d "$HOME/b2b-ffverify.XXXXXX")
	mkdir -p "$tmpdir/profile"
	# network.proxy.type 0 = no proxy at all. Without it the scratch profile
	# inherits the desktop's PAC, the request goes to the Inception proxy, and
	# the proxy correctly refuses the probe's random port — which would look
	# like the resolver pref failing when it is working fine. This check must
	# isolate resolution, so it opts out of the proxy entirely.
	{
		printf 'user_pref("network.dns.localDomains", "%s");\n' "$DOMAIN"
		printf 'user_pref("network.proxy.type", 0);\n'
	} > "$tmpdir/profile/user.js"

	# Port 0 lets the kernel pick a free one, so a busy port cannot fail the run.
	python3 - "$tmpdir" << 'PYEOF' &
import http.server, socketserver, sys, os
d = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        open(os.path.join(d, "HIT"), "a").write(self.headers.get("Host", "?") + "\n")
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers()
        self.wfile.write(b"<html><head><title>ok</title></head><body>ok</body></html>")
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
srv = socketserver.TCPServer(("127.0.0.1", 0), H)
open(os.path.join(d, "PORT"), "w").write(str(srv.server_address[1]))
srv.serve_forever()
PYEOF
	probe_pid=$!

	for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$tmpdir/PORT" ] && break; sleep 0.5; done
	probe_port=$(cat "$tmpdir/PORT" 2> /dev/null)

	if [ -n "$probe_port" ]; then
		timeout 120 firefox --headless --profile "$tmpdir/profile" \
			--screenshot "$tmpdir/shot.png" "http://${DOMAIN}:${probe_port}/" \
			> /dev/null 2>&1
		if [ -s "$tmpdir/HIT" ]; then
			pass "headless Firefox resolved ${DOMAIN} on its own (Host: $(head -1 "$tmpdir/HIT"))"
		else
			fail "Firefox did not resolve ${DOMAIN} — the user.js pref is not taking effect"
		fi
	else
		warn "could not start the resolver probe — skipped the live Firefox check"
	fi
	kill "$probe_pid" 2> /dev/null
	wait "$probe_pid" 2> /dev/null
	rm -rf "$tmpdir"
fi

# ── 6. Chromium: the bare, portless subject URL ─────────────────────────────
head_ "Chromium / Chrome — bare https://${DOMAIN}"
launcher="$HOME/.local/bin/inception-browser"
if [ ! -x "$launcher" ]; then
	warn "launcher missing — run: make host_access"
else
	pass "launcher present: $launcher"
	browser=""
	# Same order as inception_host_access.sh's CHROMIUM_CANDIDATES, so this
	# tests the browser the launcher will actually run.
	for c in chromium chromium-browser google-chrome google-chrome-stable brave-browser; do
		command -v "$c" > /dev/null 2>&1 && { browser=$(command -v "$c"); break; }
	done
	if [ -n "$browser" ]; then
		rules="MAP ${DOMAIN}:443 127.0.0.1:${P_HTTPS},MAP ${DOMAIN}:${P_STATIC} 127.0.0.1:${P_STATIC}"
		tmpdir=$(mktemp -d)
		dom=$(timeout 90 "$browser" --headless --no-sandbox --disable-gpu \
			--disable-dev-shm-usage --no-first-run \
			--user-data-dir="$tmpdir" \
			--host-resolver-rules="$rules" \
			--ignore-certificate-errors \
			--dump-dom "https://${DOMAIN}/" 2> /dev/null)
		rm -rf "$tmpdir"
		if printf '%s' "$dom" | grep -qi '<title'; then
			title=$(printf '%s' "$dom" | grep -oiE '<title[^>]*>[^<]*' | head -1 | sed 's/.*>//')
			pass "loaded https://${DOMAIN}/ with no port — title: ${title:-(untitled)}"
		else
			fail "Chromium could not load https://${DOMAIN}/"
		fi
	else
		warn "no Chromium/Chrome binary found to test with"
	fi
fi

# ── Verdict ─────────────────────────────────────────────────────────────────
printf "\n"
if [ "$FAILED" -eq 0 ]; then
	printf "${C_GREEN}${C_BOLD}  All required checks passed.${C_RESET}\n\n"
	printf "    Chromium   ${C_BOLD}inception-browser${C_RESET}  ${C_DIM}→ https://%s${C_RESET}\n" "$DOMAIN"
	printf "    Firefox    ${C_BOLD}https://%s:%s${C_RESET}\n" "$DOMAIN" "$P_HTTPS"
	printf "    Bonus      ${C_BOLD}http://%s:%s${C_RESET}\n\n" "$DOMAIN" "$P_STATIC"
	exit 0
fi
printf "${C_RED}${C_BOLD}  %d check(s) failed.${C_RESET}\n\n" "$FAILED"
exit 1
