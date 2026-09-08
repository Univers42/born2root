ARG DEBIAN_TAG=trixie
FROM debian:${DEBIAN_TAG}

ENV DEBIAN_FRONTEND=noninteractive

# The hellish binary to install, as seen from inside the container. The repo
# root is bind-mounted at /work, so this is the same artifact `make shell`
# downloads on the host and bakes into the ISO.
#
# This container used to COMPILE hellish from the sh42 submodule. That
# submodule is gone: born2root now downloads the published release binary
# instead of building it. Compiling here would have tested something we no
# longer ship. What is worth testing is whether the binary that DOES ship runs
# on Debian trixie — the exact distro the VM installs — so that is what this
# image now does.
ENV HELLISH_BIN_SRC=/work/dist/hellish

# Runtime only. gcc/g++/make/git and libreadline-dev were here to build hellish
# from source; nothing is compiled any more. libreadline8t64 is the trixie
# package that provides libreadline.so.8, which the release binary links
# against (alongside libtinfo.so.6, pulled in as a dependency).
RUN apt-get update &&
	apt-get install -y --no-install-recommends \
		bash \
		ca-certificates \
		libreadline8t64 \
		passwd \
		procps \
		util-linux &&
	rm -rf /var/lib/apt/lists/* &&
	useradd -m -s /bin/bash dev &&
	cat >/usr/local/bin/container-init.sh <<'INITEOF'
#!/usr/bin/env bash
set -e

TARGET_USER="${TARGET_USER:-dev}"
HELLISH_BIN="/usr/local/bin/hellish"
SHELL_MODE="${SHELL_MODE:-hellish}"
BIN_SRC="${HELLISH_BIN_SRC:-/work/dist/hellish}"

# Copy the shipped binary in and register it as a valid login shell.
#
# It is COPIED, not symlinked to the bind mount: chsh/usermod want a real path
# under the container's own root, and a copy also means the container keeps
# working if the host rebuilds dist/ underneath it mid-session.
install_hellish() {
	if [ ! -f "$BIN_SRC" ]; then
		echo "[init] ERROR: no hellish binary at $BIN_SRC" >&2
		echo "[init]        Run 'make shell' in the repo root first — it" >&2
		echo "[init]        downloads the release binary to dist/hellish." >&2
		return 1
	fi
	echo "[init] Installing hellish from $BIN_SRC ..."
	cp "$BIN_SRC" "$HELLISH_BIN"
	chmod 0755 "$HELLISH_BIN"

	# Fail loudly on an ABI mismatch rather than handing the user a login shell
	# that dies on open. The release binary is glibc-linked, so it runs on
	# Debian/Ubuntu but NOT on a musl distro like Alpine; catching that here
	# beats discovering it when `su - dev` drops you nowhere.
	if ! "$HELLISH_BIN" -c 'exit 0' > /dev/null 2>&1; then
		echo "[init] ERROR: $HELLISH_BIN will not run in this container." >&2
		ldd "$HELLISH_BIN" 2>&1 | sed 's/^/[init]        /' >&2
		return 1
	fi

	grep -qxF "$HELLISH_BIN" /etc/shells 2>/dev/null || echo "$HELLISH_BIN" >> /etc/shells
	echo "[init] hellish OK: $("$HELLISH_BIN" --version 2>/dev/null | head -1)"
}

set_shell_hellish() {
	install_hellish || exit 1
	if command -v chsh > /dev/null 2>&1; then
		chsh -s "$HELLISH_BIN" "$TARGET_USER" || true
	fi
	usermod -s "$HELLISH_BIN" "$TARGET_USER" || true
	echo "[init] Using custom shell: $HELLISH_BIN"
}

set_shell_bash() {
	if command -v chsh > /dev/null 2>&1; then
		chsh -s /bin/bash "$TARGET_USER" || true
	fi
	usermod -s /bin/bash "$TARGET_USER" || true
	echo "[init] Using shell: /bin/bash"
}

case "$SHELL_MODE" in
	hellish)
		set_shell_hellish
		;;
	bash)
		set_shell_bash
		;;
	auto)
		if install_hellish 2>/dev/null; then
			set_shell_hellish
		else
			echo "[init] hellish unavailable; falling back to /bin/bash"
			set_shell_bash
		fi
		;;
	*)
		echo "[init] ERROR: Invalid SHELL_MODE '$SHELL_MODE' (expected: hellish|bash|auto)" >&2
		exit 2
		;;
esac

if [ "$#" -gt 0 ]; then
	exec "$@"
fi

exec su - "$TARGET_USER"
INITEOF

RUN chmod +x /usr/local/bin/container-init.sh

WORKDIR /work

ENTRYPOINT ["/usr/local/bin/container-init.sh"]
