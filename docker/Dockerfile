ARG DEBIAN_TAG=trixie
FROM debian:${DEBIAN_TAG}

ENV DEBIAN_FRONTEND=noninteractive
ENV ASAN_OPTIONS=halt_on_error=1:abort_on_error=1:detect_leaks=1
ENV UBSAN_OPTIONS=halt_on_error=1:abort_on_error=1
ENV LSAN_OPTIONS=verbosity=1:log_threads=1
# Baked-in default so the init script always knows where sh42 lives,
# even if docker-compose forgets to pass HELLISH_SRC_DIR.
ENV HELLISH_SRC_DIR=/work/sh42

RUN apt-get update \
	&& apt-get install -y --no-install-recommends \
		bash \
		ca-certificates \
		gcc \
		g++ \
		git \
		libreadline-dev \
		make \
		passwd \
		procps \
		util-linux \
	&& rm -rf /var/lib/apt/lists/* \
	&& useradd -m -s /bin/bash dev \
	&& cat > /usr/local/bin/container-init.sh <<'INITEOF'
#!/usr/bin/env bash
set -e

TARGET_USER="${TARGET_USER:-dev}"
HELLISH_BIN="/usr/local/bin/hellish"
SHELL_MODE="${SHELL_MODE:-hellish}"
# BUILD_DIR is resolved inside build_hellish() so it survives stale image caches.
BUILD_DIR="/work/sh42"

build_hellish() {
	# Resolve BUILD_DIR: honour HELLISH_SRC_DIR when it points at the right
	# project (has src/core/shell.c), otherwise fall back to /work/sh42.
	local resolved="${HELLISH_SRC_DIR:-/work/sh42}"
	if [ ! -f "$resolved/src/core/shell.c" ] && [ -f "/work/sh42/src/core/shell.c" ]; then
		echo "[init] WARNING: HELLISH_SRC_DIR='$resolved' does not look like the sh42 project; using /work/sh42" >&2
		resolved="/work/sh42"
	fi
	BUILD_DIR="$resolved"
	echo "[init] Building hellish from source in $BUILD_DIR ..."
	if [ ! -f "$BUILD_DIR/Makefile" ]; then
		echo "[init] ERROR: No Makefile found in $BUILD_DIR" >&2
		return 1
	fi
	cd "$BUILD_DIR"
	# Initialize vendor submodules (e.g. libft) if they weren't pulled on the host.
	if command -v git > /dev/null 2>&1 && [ -f ".gitmodules" ]; then
		echo "[init] Initializing submodules in $BUILD_DIR ..."
		git submodule update --init --recursive 2>&1 || true
	fi
	# OPT=1: use release flags (-O3) instead of -fsanitize=address,leak which
	# require libasan that is not installed in this container image.
	make OPT=1 -j"$(nproc)" 2>&1 | tail -30
	if [ ! -x "$BUILD_DIR/build/bin/hellish" ]; then
		echo "[init] ERROR: build produced no executable" >&2
		return 1
	fi
	echo "[init] Build OK"
}

install_hellish() {
	cp "$BUILD_DIR/build/bin/hellish" "$HELLISH_BIN"
	chmod 0755 "$HELLISH_BIN"
	grep -qxF "$HELLISH_BIN" /etc/shells 2>/dev/null || echo "$HELLISH_BIN" >> /etc/shells
}

set_shell_hellish() {
	build_hellish || exit 1
	install_hellish
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
		if build_hellish 2>/dev/null; then
			install_hellish
			set_shell_hellish
		else
			echo "[init] Build failed; falling back to /bin/bash"
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