#!/bin/bash
#
# install_ai.sh — optional local/remote AI, sized to the hardware that exists.
#
# AI_MODE
#   off      (default) nothing is installed, nothing is downloaded, no space
#            used. Born2beRoot evaluation is completely unaffected.
#   client   the Ollama CLI only, pointed at an endpoint somewhere else
#            (default 10.0.2.2 — under VirtualBox NAT that is the HOST). No
#            model data in the VM at all.
#   local    Ollama server + a model stored on the shared /opt volume.
#
# WHY MODEL CHOICE IS COMPUTED, NOT CONFIGURED
# --------------------------------------------
# An LLM that does not fit in RAM does not run slowly, it thrashes: llama.cpp
# mmaps the weights, the kernel evicts pages as fast as it faults them in, and
# the box spends its time in swap while answering at a few seconds per token.
# On a VM that is also running Docker and MariaDB that is not a degraded
# experience, it is an unusable machine.
#
# So the model is picked from measured RAM and the script REFUSES rather than
# picking something that cannot work. For reference, a 27B model at Q4 needs
# roughly 17 GB; that is not a tuning problem on a 2 GB VM, it is arithmetic.
# Raise VM_RAM_MB (see setup/install/vms/install_vm_debian.sh) and re-run.
#
# USAGE
#   sudo AI_MODE=local ./install_ai.sh
#   sudo AI_MODE=client AI_ENDPOINT=10.0.2.2:11434 ./install_ai.sh
#   sudo AI_MODE=local AI_MODEL=qwen3:4b ./install_ai.sh   # override the choice

set -u

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# The npm prefix is moved to /opt by install_global_scope.sh, and npm's own
# bin directory is NOT on the default PATH. Without this line a package this
# script installs itself (tree-sitter, claude) is invisible to the very next
# `command -v` that checks for it -- installed, working, and reported missing.
# Ask npm where it actually is rather than hardcoding the location.
if command -v npm >/dev/null 2>&1; then
	_npm_prefix=$(npm config get prefix --global 2>/dev/null)
	case "$_npm_prefix" in
		/*) [ -d "${_npm_prefix}/bin" ] && PATH="${_npm_prefix}/bin:$PATH" ;;
	esac
	unset _npm_prefix
fi
export PATH

AI_MODE="${AI_MODE:-off}"
AI_ROOT="${AI_ROOT:-/opt/ai}"
AI_MODELS_DIR="${AI_MODELS_DIR:-${AI_ROOT}/models}"
AI_ENDPOINT="${AI_ENDPOINT:-10.0.2.2:11434}"
AI_MODEL="${AI_MODEL:-}"          # empty = choose from RAM
AI_USERS="${AI_USERS:-dlesieur}"
# Headroom left for the OS, Docker, MariaDB and an editor. Subtracted from
# total RAM before choosing, because "free right now" is not what matters --
# the model has to coexist with the services, not with an idle box.
AI_RESERVE_MB="${AI_RESERVE_MB:-1536}"

log()  { printf '[ai] %s\n' "$*"; }
warn() { printf '[ai] WARN: %s\n' "$*" >&2; }
die()  { printf '[ai] ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"

if [ "$AI_MODE" = "off" ]; then
	log "AI_MODE=off — nothing to install"
	exit 0
fi
case "$AI_MODE" in
	client|local) ;;
	*) die "AI_MODE must be off, client or local (got '${AI_MODE}')" ;;
esac

# ── How much memory is there really? ────────────────────────────────────────
total_ram_mb() { awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo; }

# choose_model <usable_mb> — echo a model name, or nothing when none fits.
#
# Sizes are the Q4 on-disk/in-memory footprint plus a working margin for the
# KV cache at a normal context length.
choose_model() {
	local mb="$1"
	if   [ "$mb" -ge 20480 ]; then echo "qwen3:14b"      # ~9 GB
	elif [ "$mb" -ge 8192 ];  then echo "qwen3:8b"       # ~5 GB
	elif [ "$mb" -ge 5120 ];  then echo "qwen3:4b"       # ~2.6 GB
	elif [ "$mb" -ge 3072 ];  then echo "qwen3:1.7b"     # ~1.4 GB
	else echo ""
	fi
}

# ── Ollama ──────────────────────────────────────────────────────────────────
install_ollama() {
	if command -v ollama >/dev/null 2>&1; then
		# `ollama --version` prints "Warning: could not connect to a running
		# Ollama instance" on stdout when the daemon is down, so taking the
		# first line reports the warning as if it were the version. Pull out
		# the version number itself instead.
		local ver
		ver=$(ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
		log "ollama already installed${ver:+ (${ver})}"
		return 0
	fi
	command -v curl >/dev/null 2>&1 || die "curl is required"
	log "installing Ollama (this pulls ~1 GB of runtime)"
	# Upstream ships only an install script; there is no Debian package. It is
	# fetched to a file and run, rather than piped straight into sh, so a
	# truncated download fails as a broken file instead of executing half a
	# script as root.
	local tmp; tmp=$(mktemp -d) || die "mktemp failed"
	if ! curl -fsSL --max-time 120 --retry 2 -o "${tmp}/ollama.sh" https://ollama.com/install.sh; then
		rm -rf "$tmp"; warn "could not download the Ollama installer"; return 1
	fi
	if ! head -n1 "${tmp}/ollama.sh" | grep -q '^#!'; then
		rm -rf "$tmp"; warn "the downloaded Ollama installer is not a script"; return 1
	fi
	sh "${tmp}/ollama.sh" >/dev/null 2>&1 || { rm -rf "$tmp"; warn "the Ollama installer failed"; return 1; }
	rm -rf "$tmp"
	command -v ollama >/dev/null 2>&1 || { warn "ollama is still not on PATH"; return 1; }
	log "ollama installed"
}

# Models must live on the shared volume. Ollama's default is
# /usr/share/ollama/.ollama/models, which is on / -- one model fills a root
# filesystem sized for apt, and a full / is how this project's own preseed
# notes describe breaking dpkg and GRUB.
point_models_at_opt() {
	mkdir -p "$AI_MODELS_DIR"
	if id ollama >/dev/null 2>&1; then
		chown -R ollama:ollama "$AI_ROOT" 2>/dev/null || true
	fi
	chmod 755 "$AI_ROOT" "$AI_MODELS_DIR" 2>/dev/null || true

	if [ -d /etc/systemd/system ] && systemctl list-unit-files 2>/dev/null | grep -q '^ollama.service'; then
		mkdir -p /etc/systemd/system/ollama.service.d
		cat > /etc/systemd/system/ollama.service.d/10-b2b-models.conf <<UNITEOF
# Added by born2root setup/install/ai/install_ai.sh
#
# systemd units do not read /etc/profile.d, so the OLLAMA_MODELS exported for
# login shells never reaches the daemon -- it needs its own copy here, or the
# server keeps writing to /usr/share/ollama on the root filesystem.
[Service]
Environment="OLLAMA_MODELS=${AI_MODELS_DIR}"
UNITEOF
		systemctl daemon-reload 2>/dev/null || true
		systemctl restart ollama 2>/dev/null || true
		log "ollama.service now stores models in ${AI_MODELS_DIR}"
	fi
}

# ── client mode ─────────────────────────────────────────────────────────────
setup_client() {
	install_ollama || return 1
	# Do not run a server we are not using.
	systemctl disable --now ollama 2>/dev/null || true

	cat > /etc/profile.d/b2b-ai.sh <<PROFEOF
# Added by born2root setup/install/ai/install_ai.sh (AI_MODE=client)
#
# The model runs elsewhere; this box is only a client. Under VirtualBox NAT,
# 10.0.2.2 is the HOST, so an Ollama server on your laptop is reachable from
# inside the VM with no port forward and no tunnel.
export OLLAMA_HOST="${AI_ENDPOINT}"
PROFEOF
	chmod 644 /etc/profile.d/b2b-ai.sh
	log "client mode: OLLAMA_HOST=${AI_ENDPOINT}"

	if curl -fsS --max-time 5 "http://${AI_ENDPOINT}/api/tags" >/dev/null 2>&1; then
		log "endpoint answers at ${AI_ENDPOINT}"
	else
		warn "nothing answering at ${AI_ENDPOINT} yet."
		warn "On the host run:  OLLAMA_HOST=0.0.0.0 ollama serve"
		warn "(the default binds 127.0.0.1, which the VM cannot reach)"
	fi
}

# ── local mode ──────────────────────────────────────────────────────────────
setup_local() {
	local total usable model
	total=$(total_ram_mb)
	usable=$((total - AI_RESERVE_MB))
	[ "$usable" -lt 0 ] && usable=0

	log "RAM: ${total} MB total, ${usable} MB usable after ${AI_RESERVE_MB} MB reserved"

	if [ -n "$AI_MODEL" ]; then
		model="$AI_MODEL"
		log "AI_MODEL is set — using ${model} without checking whether it fits"
	else
		model=$(choose_model "$usable")
	fi

	if [ -z "$model" ]; then
		warn "no model fits in ${usable} MB."
		warn "The smallest tier here (qwen3:1.7b) wants ~3 GB usable; a 27B model wants ~17 GB."
		warn "Give the VM more memory and re-run, e.g.:"
		warn "    make re VM_RAM_MB=6144 AI_MODE=local"
		warn "Installing Ollama anyway so the machine is ready, but pulling nothing."
		install_ollama || return 1
		point_models_at_opt
		return 0
	fi

	install_ollama || return 1
	point_models_at_opt

	systemctl enable --now ollama 2>/dev/null || true
	# The daemon needs a moment before it will accept a pull.
	local i
	for i in 1 2 3 4 5 6 7 8 9 10; do
		curl -fsS --max-time 3 http://127.0.0.1:11434/api/tags >/dev/null 2>&1 && break
		sleep 2
	done

	log "pulling ${model} into ${AI_MODELS_DIR} (this is a large download)"
	if ollama pull "$model" 2>&1 | tail -n 3 | sed 's/^/[ai]   /'; then
		log "model ready: ${model}"
	else
		warn "pull of ${model} failed — the server is installed, retry with: ollama pull ${model}"
	fi

	cat > /etc/profile.d/b2b-ai.sh <<PROFEOF
# Added by born2root setup/install/ai/install_ai.sh (AI_MODE=local)
export OLLAMA_MODELS="${AI_MODELS_DIR}"
# The model chosen for this machine's memory. Override per-shell if you pull
# another one, but check it fits first: a model that does not fit swaps.
export B2B_AI_MODEL="${model}"
PROFEOF
	chmod 644 /etc/profile.d/b2b-ai.sh

	# Where the space actually went, so a full /opt is never a surprise.
	local used
	used=$(du -sh "$AI_MODELS_DIR" 2>/dev/null | awk '{print $1}')
	log "models occupy ${used:-?} of $(df -h --output=size "$AI_ROOT" 2>/dev/null | tail -n1 | tr -d ' ') on $(findmnt -no SOURCE -T "$AI_ROOT" 2>/dev/null)"
}

log "=== AI setup (AI_MODE=${AI_MODE}) ==="
case "$AI_MODE" in
	client) setup_client ;;
	local)  setup_local ;;
esac
log "=== done ==="
