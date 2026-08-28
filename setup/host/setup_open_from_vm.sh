#!/usr/bin/env bash
# ============================================================================ #
#  born2root — `open <file>` inside the VM, displayed on the host's screen     #
# ============================================================================ #
#
# The VM is a headless server install: no X, no desktop, no PDF viewer. So
# `xdg-open en.subject.pdf` in there has nothing to draw on, and the file has to
# reach a machine that has a screen.
#
# Rather than a shared folder (needs Guest Additions) or an SSH server on the
# host (there isn't one, and a 42 machine gives no root to start one), this
# reuses the connection that already exists. `ssh b2b` carries a RemoteForward,
# so a port on the GUEST tunnels back to a small agent on the HOST:
#
#     you, inside the VM:   open en.subject.pdf
#         guest:7654  --[ your existing ssh b2b session ]-->  host:7654
#                                                             └─> xdg-open
#
# Nothing is exposed to the network: both ends are bound to 127.0.0.1 and the
# only path between them is an SSH session the host itself opened.
#
#   make open_from_vm        set it up
#   make open_from_vm_undo   remove it
# ============================================================================ #

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

OPEN_PORT="${INCEPTION_OPEN_PORT:-7654}"
AGENT_DIR="$HOME/.local/share/born2root"
AGENT_BIN="$AGENT_DIR/open_from_vm_agent.py"
AGENT_UNIT="$HOME/.config/systemd/user/inception-open-agent.service"
SSH_ALIAS="${SSH_ALIAS:-b2b}"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'; C_DIM=$'\033[2m'
ok()   { printf "  ${C_GREEN}✓${C_RESET} %s\n" "$*"; }
warn() { printf "  ${C_YELLOW}⚠${C_RESET}  %s\n" "$*"; }

if [ "${1:-}" = "--undo" ]; then
	systemctl --user disable --now inception-open-agent.service > /dev/null 2>&1
	rm -f "$AGENT_UNIT" "$AGENT_BIN"
	systemctl --user daemon-reload > /dev/null 2>&1
	ok "host agent removed (the guest's /usr/local/bin/open is left in place)"
	exit 0
fi

printf "\n${C_BOLD}Open files from the VM on this host${C_RESET}\n"

# ── 1. The host agent ───────────────────────────────────────────────────────
if [ ! -f "$HERE/open_from_vm_agent.py" ]; then
	warn "open_from_vm_agent.py missing"
	exit 1
fi
mkdir -p "$AGENT_DIR"
install -m 0755 "$HERE/open_from_vm_agent.py" "$AGENT_BIN"

mkdir -p "$(dirname "$AGENT_UNIT")"
cat > "$AGENT_UNIT" << UNITEOF
[Unit]
Description=Open files sent from the Inception VM on this host's display
After=graphical-session.target

[Service]
ExecStart=/usr/bin/env python3 ${AGENT_BIN} --port ${OPEN_PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
UNITEOF

systemctl --user daemon-reload > /dev/null 2>&1
systemctl --user enable inception-open-agent.service > /dev/null 2>&1
if systemctl --user restart inception-open-agent.service > /dev/null 2>&1; then
	ok "host agent listening on 127.0.0.1:${OPEN_PORT}"
else
	warn "could not start the host agent"
fi

# ── 2. The tunnel ───────────────────────────────────────────────────────────
# orchestrate.sh writes the canonical block; add the line here too so this works
# immediately, without waiting for the next `make all` to regenerate the config.
SSH_CONFIG="$HOME/.ssh/config"
if [ -f "$SSH_CONFIG" ] && grep -q '^Host b2b' "$SSH_CONFIG"; then
	if grep -q "RemoteForward 127.0.0.1:${OPEN_PORT}" "$SSH_CONFIG"; then
		ok "ssh b2b already carries the reverse tunnel"
	else
		# Insert immediately after the Host line so it lands inside that block.
		sed -i "/^Host b2b/a\\    RemoteForward 127.0.0.1:${OPEN_PORT} 127.0.0.1:${OPEN_PORT}" "$SSH_CONFIG"
		ok "added RemoteForward to the b2b block in ~/.ssh/config"
	fi
else
	warn "no 'Host b2b' block in ~/.ssh/config — run: make all"
fi

# ── 3. The guest-side command ───────────────────────────────────────────────
# Installed into /usr/local/bin so it is on PATH for every shell, including the
# custom login shell, without touching any profile file.
GUEST_CLIENT=$(mktemp)
cat > "$GUEST_CLIENT" << 'CLIENTEOF'
#!/usr/bin/env python3
"""open <file> — show a file from this VM on the host's screen.

This VM has no graphical session. The file is streamed to a small agent on the
host over the reverse tunnel carried by your `ssh b2b` session, and the host
opens it with its own default viewer.
"""
import os
import socket
import sys

PORT = int(os.environ.get("INCEPTION_OPEN_PORT", "7654"))


def main():
    if len(sys.argv) != 2 or sys.argv[1] in ("-h", "--help"):
        print("usage: open <file>", file=sys.stderr)
        return 2
    path = sys.argv[1]
    if not os.path.isfile(path):
        print("open: cannot read '%s'" % path, file=sys.stderr)
        return 1
    try:
        sock = socket.create_connection(("127.0.0.1", PORT), 10)
    except OSError:
        print(
            "open: nothing listening on 127.0.0.1:%d.\n"
            "      This needs the reverse tunnel that `ssh b2b` sets up — open\n"
            "      this VM with `ssh b2b` from the host, not `ssh -p 4242 ...`,\n"
            "      and make sure that session is still running." % PORT,
            file=sys.stderr,
        )
        return 1
    with sock:
        sock.sendall(("OPEN %s\n" % os.path.basename(path)).encode())
        with open(path, "rb") as fh:
            while True:
                chunk = fh.read(65536)
                if not chunk:
                    break
                sock.sendall(chunk)
        # Half-close so the agent sees end-of-file but can still reply.
        sock.shutdown(socket.SHUT_WR)
        reply = sock.recv(4096).decode("utf-8", "replace").strip()
    print(reply or "(no reply)")
    return 0 if reply.startswith("OK") else 1


if __name__ == "__main__":
    sys.exit(main())
CLIENTEOF

resolve_pass() {
	[ -n "${GUEST_PASS:-}" ] && { printf '%s' "$GUEST_PASS"; return 0; }
	awk '$1 == "d-i" && $2 == "passwd/user-password" { print $4; exit }' \
		"$REPO_ROOT/preseeds/preseed.cfg" 2> /dev/null
}

if scp "${SSH_OPTS[@]}" "$GUEST_CLIENT" "${SSH_ALIAS}:/tmp/open-client" > /dev/null 2>&1; then
	pass=$(resolve_pass)
	# requiretty in the guest's sudoers, hence -tt.
	printf '%s\n' "$pass" | ssh "${SSH_OPTS[@]}" -tt "$SSH_ALIAS" \
		"sudo -S -p '' sh -c 'install -m 0755 /tmp/open-client /usr/local/bin/open && ln -sf /usr/local/bin/open /usr/local/bin/hostopen && rm -f /tmp/open-client'" \
		> /dev/null 2>&1
	if ssh "${SSH_OPTS[@]}" "$SSH_ALIAS" 'test -x /usr/local/bin/open' 2> /dev/null; then
		ok "guest command installed: ${C_BOLD}open <file>${C_RESET} (also: hostopen)"
	else
		warn "could not install the guest command — copy it yourself from /tmp/open-client"
	fi
else
	warn "guest unreachable — skipped installing the guest command"
fi
rm -f "$GUEST_CLIENT"

printf "\n  ${C_BOLD}Use it:${C_RESET}\n"
printf "    ${C_DIM}on the host${C_RESET}   ssh b2b            ${C_DIM}(the tunnel rides this session)${C_RESET}\n"
printf "    ${C_DIM}in the VM${C_RESET}     open en.subject.pdf\n"
printf "\n  ${C_DIM}The PDF opens in this host's viewer. Only works while that${C_RESET}\n"
printf "  ${C_DIM}ssh b2b session is open — the tunnel goes with it.${C_RESET}\n\n"
