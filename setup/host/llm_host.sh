#!/usr/bin/env hellish
#
# llm_host.sh — serve local models from the HOST to opencode in the VM, with
# llama.cpp, on the host's GPU when this session can see one.
#
# WHY THE HOST, NOT THE VM, NOT A CLOUD TIER
# ------------------------------------------
# opencode's free cloud models are rate-limited per public address, and a
# campus puts every seat behind one NAT address: the allowance is shared with
# the whole school before anyone types. A model on this machine has no quota.
# It runs here rather than in the guest because the guest has a few GB of RAM
# and no GPU, while the seat this was measured on (2026-09-15) has a Ryzen 7
# PRO 8700GE, 30 GB and a Radeon 780M. The guest reaches the host as 10.0.2.2
# under both backends' NAT.
#
# WHY LLAMA.CPP, AND WHY THE PREBUILT VULKAN RELEASE
# --------------------------------------------------
# Ollama runs the same ggml engine but only offers the iGPU experimentally;
# llama.cpp's Vulkan backend drives the 780M directly. Upstream's
# llama-<tag>-bin-ubuntu-vulkan-x64.tar.gz (30 MB, built with GCC 11.4) runs
# on the school's Ubuntu 22.04 as it is -- nothing to compile, no glslc, no
# sudo -- and carries the CPU backends too, so one download serves both. The
# tag is pinned in born2root.toml (ai.llama_cpp): a server build that changes
# under a working setup is not an upgrade anyone asked for.
#
# The GPU is DETECTED, never assumed: `llama-server --list-devices` names the
# Vulkan devices this session can open. A session without /dev/dri (a remote
# shell, a sandbox) sees none, and llvmpipe, Mesa's software Vulkan, is slower
# than the CPU backend it would replace -- so neither is used, and the build
# says so in words rather than quietly running at CPU speed. ai.gpu = "vulkan"
# turns that into a refusal.
#
# Measured on that seat: the 780M (PCI 1002:15bf) is in the machine, but the
# school's kernel, 5.15.0-187, ships an amdgpu that knows AMD APUs only up to
# 15e7 -- no driver binds to it, /sys/class/drm is empty, and even the desktop
# session's vulkaninfo lists llvmpipe alone. No user-space step changes that;
# a newer kernel (Ubuntu's linux-generic-hwe-22.04) does, and only an
# administrator can install one. So the fallback names that cause when it is
# the cause: a display device on the PCI bus with no driver bound.
#
# ONE SERVER, SEVERAL MODELS
# --------------------------
# llama-server's router mode (--models-dir) lists every model under one
# directory and loads the one a request names, so opencode's /models switches
# between them. Probed with placeholder files: a subdirectory is one model
# named after the directory (split GGUF parts live together in it), and a
# loose .gguf is one named after the file. So each model gets a directory
# named <repo without -GGUF>-<quant>, and the ids opencode is given are read
# back from the router's /v1/models, not assumed from that rule.
#
# WHY SGOINFRE, A BUDGET, AND AN API KEY
# --------------------------------------
# /home is a 4.7 GB quota and /goinfre is wiped; sgoinfre survives and follows
# the login to any seat. It is shared storage, so ai.budget_gb caps it, checked
# against Hugging Face's declared file sizes BEFORE a byte is downloaded. The
# cost of NFS is the first load of a model; after that it lives in RAM/VRAM.
# 127.0.0.1 is enough for the VM, but it is shared by every user logged into
# the same workstation, so the server also wants a key. It is read from a
# mode-600 file (--api-key-file), never passed as an argument `ps` would show.
#
# WHERE THE SETTINGS COME FROM, AND WHY IT ASKS
# ---------------------------------------------
# born2root.toml's [ai] table, validated by utils/b2b_config.py --check; a
# B2B_LLM_* variable wins for one run; "$USER" in models_dir is the host login.
# With ai.host_models = true, `make all` runs `preflight` before anything
# else: it prices the models and the release, refuses what the budget, the
# free space or the RAM cannot hold, prints what will happen on this
# workstation and asks. The answer is kept in .b2b-llm-ack for exactly those
# settings; with no terminal and no record it refuses (B2B_LLM_ACK=1 accepts).
# Settings never confirmed are first offered to llm_select.sh, the picker.
# `build`, at the end of the build, then does what was accepted.
#
# USAGE
#   setup/host/llm_host.sh up         release + models + server + opencode in the VM
#   setup/host/llm_host.sh preflight  price, check, explain, ask (when enabled)
#   setup/host/llm_host.sh build      `up`, only when ai.host_models = true
#   setup/host/llm_host.sh install|pull|serve|vm|status|stop

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

. "$REPO_ROOT/utils/b2b_config.sh"

# One [ai] value, as `get` answers it ("" when the file does not parse).
ai_conf() { b2b_get "ai.$1"; }

B2B_LLM_ENABLE="${B2B_LLM_ENABLE:-$(ai_conf host_models)}"
B2B_LLM_MODELS="${B2B_LLM_MODELS:-$(ai_conf models)}"
B2B_LLM_DIR="${B2B_LLM_DIR:-$(ai_conf models_dir)}"
B2B_LLM_BUDGET_GB="${B2B_LLM_BUDGET_GB:-$(ai_conf budget_gb)}"
B2B_LLM_RELEASE="${B2B_LLM_RELEASE:-$(ai_conf llama_cpp)}"
B2B_LLM_GPU="${B2B_LLM_GPU:-$(ai_conf gpu)}"
B2B_LLM_CONTEXT="${B2B_LLM_CONTEXT:-$(ai_conf context)}"
B2B_LLM_HOST="${B2B_LLM_HOST:-$(ai_conf bind)}"
if [ -z "${B2B_LLM_EXPOSE:-}" ]; then
    B2B_LLM_EXPOSE=0
    [ "$(ai_conf expose)" = "true" ] && B2B_LLM_EXPOSE=1
fi
# $USER and ${USER} are the host login; a literal path is left as written.
_login=$(id -un)
B2B_LLM_DIR=${B2B_LLM_DIR//\$\{USER\}/$_login}
B2B_LLM_DIR=${B2B_LLM_DIR//\$USER/$_login}
unset _login
B2B_LLM_HF="${B2B_LLM_HF:-https://huggingface.co}"
B2B_LLM_GITHUB="${B2B_LLM_GITHUB:-https://github.com/ggml-org/llama.cpp}"
# The pidfile and log are per seat: sgoinfre is shared between machines, and a
# pidfile there would name a process on some other workstation.
B2B_LLM_RUN="${B2B_LLM_RUN:-${XDG_RUNTIME_DIR:-/tmp}/b2b-llm-$(id -u)}"
B2B_LLM_ACK_FILE="${B2B_LLM_ACK_FILE:-$REPO_ROOT/.b2b-llm-ack}"
VM_NAME="${VM_NAME:-debian}"

BIN_DIR="$B2B_LLM_DIR/bin/$B2B_LLM_RELEASE"
MODELS_DIR="$B2B_LLM_DIR/models"
KEY_FILE="$B2B_LLM_DIR/api-key"

C_R='\033[0m'
info() { printf '\033[34m▶\033[0m %s\n' "$*"; }
ok() { printf "\033[32m✓${C_R} %s\n" "$*"; }
warn() { printf "\033[33m!${C_R} %s\n" "$*"; }
die() {
    printf "\033[31m✗${C_R} %s\n" "$*" >&2
    exit 1
}

# ── Guards ──────────────────────────────────────────────────────────────────
# Every setting present. An empty one means born2root.toml does not parse, and
# a default guessed here would be a second copy of utils/b2b_config.py's.
check_settings() {
    [ -n "$B2B_LLM_MODELS" ] && [ -n "$B2B_LLM_DIR" ] && [ -n "$B2B_LLM_BUDGET_GB" ] &&
        [ -n "$B2B_LLM_RELEASE" ] && [ -n "$B2B_LLM_GPU" ] && [ -n "$B2B_LLM_CONTEXT" ] &&
        [ -n "$B2B_LLM_HOST" ] && return 0
    die "the [ai] settings are incomplete; run make config to see what born2root.toml says"
}

# The store must not be the home quota or a VM directory: the first is the
# very thing this script exists to avoid filling, and the second is emptied
# wholesale by `make fclean`.
check_store() {
    local dir="$1" home
    home=$(cd "$HOME" 2>/dev/null && pwd -P)
    case "$dir" in
    /*) ;;
    *) die "ai.models_dir must be absolute: $dir" ;;
    esac
    case "$dir/" in
    "$HOME"/* | "$home"/*)
        die "ai.models_dir=$dir is inside \$HOME, the quota it would fill; use /sgoinfre/students/\$USER/llm"
        ;;
    */disk_images/*)
        die "ai.models_dir=$dir is inside a disk_images directory; give the models their own directory"
        ;;
    esac
}

# The bind address, refused when it is not loopback unless ai.expose says so.
check_bind() {
    local addr="${1%:*}"
    case "$addr" in
    127.* | localhost | "[::1]") return 0 ;;
    esac
    if [ "$B2B_LLM_EXPOSE" = "1" ]; then
        warn "ai.expose = true: the model server listens on $1, reachable from the network (the API key still applies)"
        return 0
    fi
    die "ai.bind=$1 would put the model server on the LAN; the VM needs only 127.0.0.1 (ai.expose = true if you mean it)"
}

bind_addr() { printf '%s\n' "${B2B_LLM_HOST%:*}"; }
bind_port() { printf '%s\n' "${B2B_LLM_HOST##*:}"; }

server_up() {
    curl -fsS --max-time 3 "http://${B2B_LLM_HOST}/health" >/dev/null 2>&1
}

enabled() {
    case "$B2B_LLM_ENABLE" in
    true | 1) return 0 ;;
    esac
    return 1
}

# ── Models ──────────────────────────────────────────────────────────────────
# A model is "owner/repo:QUANT", the spelling llama.cpp's own -hf takes.
model_repo() { printf '%s\n' "${1%%:*}"; }
model_quant() { printf '%s\n' "${1##*:}"; }
# Its directory under models/, which is also the id the router gives it.
model_id() {
    local name="${1%%:*}"
    name="${name##*/}"
    name="${name%-GGUF}"
    name="${name%-gguf}"
    printf '%s-%s\n' "$name" "$(model_quant "$1")"
}
# Complete only once every file of it landed: pull writes the stamp last, so
# an interrupted download is never served as a model.
model_present() { [ -f "$MODELS_DIR/$(model_id "$1")/.complete" ]; }

# The picker, fed Hugging Face's recursive tree listing on stdin. A quant
# matches a file whose name, less .gguf and any -0000N-of-0000M shard suffix,
# ENDS in it after a separator -- and "Q3_K_XL" must not quietly select
# unsloth's "UD-Q3_K_XL", a different file. mmproj (vision) files are never
# model weights. Nothing found: name the quants the repo does have.
hf_pick_py() {
    cat <<'PYEOF'
import json, re, sys

quant = sys.argv[1]
try:
    entries = json.load(sys.stdin)
except ValueError:
    sys.stderr.write("the listing is not JSON\n")
    sys.exit(2)
files = [
    f for f in entries
    if f.get("type") == "file" and f.get("path", "").endswith(".gguf")
    and "mmproj" not in f["path"].lower()
]

def stem(path):
    base = path.rsplit("/", 1)[-1][:-5]
    return re.sub(r"-\d{5}-of-\d{5}$", "", base)

def matches(path):
    s, q = stem(path).lower(), quant.lower()
    if not re.search(r"(^|[-._])" + re.escape(q) + r"$", s):
        return False
    rest = s[: len(s) - len(q)].rstrip("-._")
    return q.startswith("ud") or not rest.endswith("ud")

picked = [f for f in files if matches(f["path"])]
if not picked:
    have = set()
    for f in files:
        m = re.search(r"[-._]((?:ud-)?(?:i?q\d\w*|f16|bf16|f32))$", stem(f["path"]), re.I)
        if m:
            have.add(m.group(1))
    sys.stderr.write("no %s file; this repo has: %s\n" % (quant, " ".join(sorted(have)) or "no GGUF"))
    sys.exit(1)
if len({stem(f["path"]) for f in picked}) > 1:
    sys.stderr.write("%s is ambiguous: %s\n" % (quant, " ".join(sorted({stem(f["path"]) for f in picked}))))
    sys.exit(1)
for f in sorted(picked, key=lambda f: f["path"]):
    print((f.get("lfs") or {}).get("size") or f.get("size") or 0, f["path"])
PYEOF
}

# "<bytes> <path>" per file of a model, or a message on stderr and status 1.
hf_files() {
    local repo quant json
    repo=$(model_repo "$1")
    quant=$(model_quant "$1")
    json=$(curl -fsS --max-time 30 "$B2B_LLM_HF/api/models/$repo/tree/main?recursive=true" 2>/dev/null)
    if [ -z "$json" ]; then
        printf 'huggingface.co does not know %s (or did not answer)\n' "$repo" >&2
        return 1
    fi
    printf '%s' "$json" | python3 -c "$(hf_pick_py)" "$quant"
}

mb_of_bytes() { awk -v b="$1" 'BEGIN { printf "%d\n", (b + 1048575) / 1048576 }'; }

# ── Memory ──────────────────────────────────────────────────────────────────
host_mem_mb() { awk '/^MemTotal:/ { printf "%d\n", $2 / 1024 }' "${B2B_LLM_MEMINFO:-/proc/meminfo}" 2>/dev/null; }

# The VM's share: vm.ram_mb = "auto" reaches here empty, which is a quarter of
# the host clamped to 2048-8192 MB, as install_vm_debian.sh sizes it.
vm_mem_mb() {
    case "${VM_RAM_MB:-}" in
    '' | auto) awk -v m="$(host_mem_mb)" 'BEGIN { v = int(m / 4); if (v < 2048) v = 2048; if (v > 8192) v = 8192; print v }' ;;
    *[!0-9]*) echo 0 ;;
    *) echo "$VM_RAM_MB" ;;
    esac
}

# The f16 KV cache: ~100 MB per 1k tokens of context for the models this is
# sized for. The iGPU shares system memory, so it counts against RAM either way.
kv_mem_mb() { echo $(($1 * 100 / 1024)); }

# The largest model (MB on disk) that still runs beside the VM with this much
# context: weights plus ~20% for compute buffers.
model_room_mb() {
    echo $((($(host_mem_mb) - $(vm_mem_mb) - $(kv_mem_mb "$1")) * 5 / 6))
}

# "<QUANT> <bytes>" per quantization a Hugging Face GGUF repository offers,
# split parts summed, mmproj left out -- the same reading hf_pick_py makes, so
# anything listed here is something ai.models can name. Tree listing on stdin.
hf_quants_py() {
    cat <<'PYEOF'
import json, re, sys

sizes = {}
for f in json.load(sys.stdin):
    path = f.get("path", "")
    if f.get("type") != "file" or not path.endswith(".gguf") or "mmproj" in path.lower():
        continue
    stem = re.sub(r"-\d{5}-of-\d{5}$", "", path.rsplit("/", 1)[-1][:-5])
    m = re.search(r"[-._]((?:ud-)?(?:i?q\d\w*|f16|bf16|f32))$", stem, re.I)
    if m:
        quant = m.group(1)
        sizes[quant] = sizes.get(quant, 0) + ((f.get("lfs") or {}).get("size") or f.get("size") or 0)
for quant, size in sorted(sizes.items(), key=lambda kv: kv[1]):
    print(quant, size)
PYEOF
}

hf_quants() {
    local json
    json=$(curl -fsS --max-time 30 "$B2B_LLM_HF/api/models/$1/tree/main?recursive=true" 2>/dev/null)
    [ -n "$json" ] || return 1
    printf '%s' "$json" | python3 -c "$(hf_quants_py)"
}

# "<repo> <downloads>" for GGUF repositories matching $1, most downloaded
# first: Hugging Face's own index, so the list is what exists today.
hf_search() {
    curl -fsS --max-time 30 -G "$B2B_LLM_HF/api/models" --data-urlencode "search=$1" \
        --data-urlencode filter=gguf --data-urlencode sort=downloads \
        --data-urlencode direction=-1 --data-urlencode "limit=${2:-15}" 2>/dev/null |
        python3 -c 'import json, sys; [print(m["id"], m.get("downloads", 0)) for m in json.load(sys.stdin)]' 2>/dev/null
}

# ── The release ─────────────────────────────────────────────────────────────
release_asset() {
    case "$(uname -m)" in
    x86_64) printf 'llama-%s-bin-ubuntu-vulkan-x64.tar.gz\n' "$B2B_LLM_RELEASE" ;;
    aarch64) printf 'llama-%s-bin-ubuntu-vulkan-arm64.tar.gz\n' "$B2B_LLM_RELEASE" ;;
    *) return 1 ;;
    esac
}
release_url() { printf '%s/releases/download/%s/%s\n' "$B2B_LLM_GITHUB" "$B2B_LLM_RELEASE" "$(release_asset)"; }
release_present() { [ -x "$BIN_DIR/llama-server" ]; }

# Its size from the download's own headers, not GitHub's API: the API allows
# 60 anonymous calls an hour per address, and the address is the campus's.
release_size_mb() {
    local bytes
    release_present && {
        echo 0
        return
    }
    bytes=$(curl -fsSIL --max-time 30 "$(release_url)" 2>/dev/null | tr -d '\r' |
        sed -n 's/^[Cc]ontent-[Ll]ength:[[:space:]]*\([0-9][0-9]*\)$/\1/p' | tail -n1)
    [ -n "$bytes" ] || return 1
    # Extracted, the archive is about three times its download.
    echo $(($(mb_of_bytes "$bytes") * 3))
}

server_run() { env LD_LIBRARY_PATH="$BIN_DIR" "$BIN_DIR/llama-server" "$@"; }

do_install() {
    local tmp asset
    check_settings
    check_store "$B2B_LLM_DIR"
    if release_present; then
        ok "llama.cpp $B2B_LLM_RELEASE already in $BIN_DIR"
    else
        asset=$(release_asset) || die "llama.cpp publishes no Vulkan build for $(uname -m)"
        mkdir -p "$B2B_LLM_DIR/bin" || die "cannot create $B2B_LLM_DIR/bin"
        chmod 700 "$B2B_LLM_DIR" 2>/dev/null || true
        tmp="$B2B_LLM_DIR/bin/.$B2B_LLM_RELEASE.tmp"
        rm -rf "$tmp" "$tmp.tar.gz"
        info "downloading llama.cpp $B2B_LLM_RELEASE ($asset)"
        curl -fL -# --retry 3 --max-time 600 -o "$tmp.tar.gz" "$(release_url)" ||
            die "could not download $(release_url)"
        mkdir -p "$tmp" || die "cannot create $tmp"
        tar -xzf "$tmp.tar.gz" -C "$tmp" --strip-components=1 || die "could not extract $asset"
        rm -f "$tmp.tar.gz"
        [ -x "$tmp/llama-server" ] || die "$asset has no llama-server in it"
        rm -rf "$BIN_DIR"
        mv "$tmp" "$BIN_DIR" || die "cannot move the release into $BIN_DIR"
        ok "llama.cpp $B2B_LLM_RELEASE in $BIN_DIR"
    fi
    server_run --version >/dev/null 2>&1 ||
        die "$BIN_DIR/llama-server does not run on this host: $(server_run --version 2>&1 | tail -n1)"
}

# ── The device ──────────────────────────────────────────────────────────────
# "<dev>|<name>|<MiB>" for the first real GPU this session can open, or
# nothing. llama-server prints them as "  Vulkan0: <name> (<MiB> MiB, <MiB>
# MiB free)"; llvmpipe is software rendering and does not count.
gpu_device() {
    server_run --list-devices 2>/dev/null |
        sed -n 's/^[[:space:]]*\(Vulkan[0-9][0-9]*\): \(.*\) (\([0-9][0-9]*\) MiB, [0-9][0-9]* MiB free)$/\1|\2|\3/p' |
        grep -vi 'llvmpipe' | head -n1
}

# "<vendor>:<device>" of a display-class PCI device no driver is bound to, the
# signature of a GPU the running kernel does not support. B2B_LLM_SYSFS is the
# tests' stand-in for /sys.
unbound_gpu() {
    local d
    for d in "${B2B_LLM_SYSFS:-/sys}"/bus/pci/devices/*; do
        case "$(cat "$d/class" 2>/dev/null)" in
        0x03*) ;;
        *) continue ;;
        esac
        [ -e "$d/driver" ] && continue
        printf '%s:%s\n' "$(sed 's/^0x//' "$d/vendor")" "$(sed 's/^0x//' "$d/device")"
        return 0
    done
    return 1
}

# Sets DEVICE (the --device value) and DEVICE_SAY (what it means, in words).
choose_device() {
    local gpu why
    DEVICE=none
    if [ "$B2B_LLM_GPU" = "cpu" ]; then
        DEVICE_SAY="CPU (ai.gpu = \"cpu\")"
        return 0
    fi
    gpu=$(gpu_device)
    if [ -n "$gpu" ]; then
        DEVICE="${gpu%%|*}"
        gpu="${gpu#*|}"
        DEVICE_SAY="GPU: ${gpu%|*}, ${gpu##*|} MiB ($DEVICE)"
        return 0
    fi
    gpu=$(unbound_gpu)
    if [ -n "$gpu" ]; then
        why="this machine has a GPU (PCI $gpu) but kernel $(uname -r) has no driver bound to it, so no program can use it; only an administrator can fix that, with a newer kernel (Ubuntu: linux-generic-hwe-22.04)"
    else
        why="this session sees no GPU (ls -l /dev/dri lists no renderD128)"
    fi
    if [ "$B2B_LLM_GPU" = "vulkan" ]; then
        die "ai.gpu = \"vulkan\" but $why. Set ai.gpu = \"auto\" to run on the CPU"
    fi
    DEVICE_SAY="CPU, at CPU speed: $why"
}

# ── Space ───────────────────────────────────────────────────────────────────
store_used_mb() {
    [ -d "$B2B_LLM_DIR" ] || {
        echo 0
        return
    }
    du -sm "$B2B_LLM_DIR" 2>/dev/null | awk '{ print $1 + 0 }'
}

# Free space where the store is, or will be: before the first run the
# directory does not exist, and df of a missing path answers nothing.
store_free_mb() {
    local d="$B2B_LLM_DIR"
    while [ ! -d "$d" ] && [ "$d" != / ]; do
        d=$(dirname "$d")
    done
    df -Pm "$d" 2>/dev/null | awk 'NR == 2 { print $4 + 0 }'
}

# Sets MISSING ("id:MB" words still to download), MISSING_MB, LARGEST (MB of
# the biggest model, present or not: memory is needed either way) and
# RELEASE_MB.
price_models() {
    local m files size
    MISSING=""
    MISSING_MB=0
    LARGEST=0
    for m in $B2B_LLM_MODELS; do
        files=$(hf_files "$m" 2>"$B2B_LLM_RUN.err") ||
            die "ai.models: $m: $(cat "$B2B_LLM_RUN.err" 2>/dev/null)"
        size=$(mb_of_bytes "$(printf '%s\n' "$files" | awk '{ s += $1 } END { printf "%.0f", s }')")
        [ "$size" -gt "$LARGEST" ] && LARGEST=$size
        model_present "$m" && continue
        MISSING="$MISSING $(model_id "$m"):$size"
        MISSING_MB=$((MISSING_MB + size))
    done
    rm -f "$B2B_LLM_RUN.err"
    RELEASE_MB=$(release_size_mb) || die "cannot reach $(release_url)"
}

# ── What this does to the workstation, said before it is done ──────────────
print_notice() {
    local item
    printf '\n  \033[1mAI models on this computer\033[0m  ([ai] in born2root.toml)\n\n'
    if [ "$RELEASE_MB" -gt 0 ]; then
        printf '  Downloads        llama.cpp %s from github.com (~%s MB unpacked)\n' "$B2B_LLM_RELEASE" "$RELEASE_MB"
    fi
    if [ -n "$MISSING" ]; then
        printf '  Downloads        from huggingface.co, %s GB in total:\n' "$(awk -v m="$MISSING_MB" 'BEGIN { printf "%.1f", m / 1024 }')"
        for item in $MISSING; do
            printf '                     %-44s %6s MB\n' "${item%:*}" "${item##*:}"
        done
    else
        printf '  Downloads        no model: every one is already in the store\n'
    fi
    printf '  Stores them in   %s (capped at %s GB; kept after the build)\n' "$B2B_LLM_DIR" "$B2B_LLM_BUDGET_GB"
    printf '  Runs             llama-server as %s, no sudo, on %s\n' "$(id -un)" "$B2B_LLM_HOST"
    printf '                   until make llm_stop, logout or reboot; API key in %s\n' "$KEY_FILE"
    if [ "$B2B_LLM_EXPOSE" = 1 ]; then
        printf '  \033[33mReachable from   the campus network (ai.expose = true)\033[0m\n'
    else
        printf '  Reachable from   this machine and its VM only (loopback)\n'
    fi
    printf '  Uses             this seat'"'"'s GPU when this session can see one, else its CPU,\n'
    printf '                   and its memory while a model is loaded\n'
    printf '  Changes in VM    ~/.config/opencode/opencode.json of the login\n'
    printf '  Removes it all   make llm_stop; rm -rf %s\n\n' "$B2B_LLM_DIR"
}

# The settings an answer applies to: change a model, the store, the bind or
# the release and the question is asked again.
ack_key() {
    printf '%s|%s|%s|%s|%s|%s' "$B2B_LLM_MODELS" "$B2B_LLM_DIR" "$B2B_LLM_BUDGET_GB" \
        "$B2B_LLM_HOST" "$B2B_LLM_EXPOSE" "$B2B_LLM_RELEASE" | cksum | cut -d' ' -f1
}

# ── Actions ─────────────────────────────────────────────────────────────────
# Everything that can refuse, refused before the 20-minute install rather than
# after it: prices, budget, free space, memory, and whether the release runs.
do_preflight() {
    local used free mem_mb vm_mb kv_mb need key answer
    enabled || return 0
    # Settings nobody has confirmed yet are a choice still to make, and the
    # picker is where it is made: offered here, before anything is priced,
    # whenever there is a terminal to make it on.
    local offer=1
    [ -z "${B2B_LLM_NO_SELECT:-}" ] || offer=0
    grep -qx "$(ack_key)" "$B2B_LLM_ACK_FILE" 2>/dev/null && offer=0
    (: </dev/tty) 2>/dev/null || offer=0
    if [ "$offer" = 1 ]; then
        printf '\n  AI models from this computer are on. Models: %s\n  Stored in %s\n' "$B2B_LLM_MODELS" "$B2B_LLM_DIR"
        printf '  Choose the models and the folder now? [y/N] '
        read -r answer </dev/tty || answer=
        case "$answer" in
        y | Y | yes | YES)
            "${SCRIPT_SH:-bash}" "$HERE/llm_select.sh" || die "nothing was changed; make llm_select to try again"
            exec env B2B_LLM_NO_SELECT=1 "${SCRIPT_SH:-bash}" "$HERE/llm_host.sh" preflight
            ;;
        esac
    fi
    check_settings
    check_store "$B2B_LLM_DIR"
    check_bind "$B2B_LLM_HOST"
    command -v python3 >/dev/null 2>&1 || die "ai.host_models needs python3 on this host"
    mkdir -p "$B2B_LLM_RUN" 2>/dev/null
    price_models
    used=$(store_used_mb)
    if [ $((used + MISSING_MB + RELEASE_MB)) -gt $((B2B_LLM_BUDGET_GB * 1024)) ]; then
        die "ai.models need $((MISSING_MB + RELEASE_MB)) MB more; $B2B_LLM_DIR holds ${used} MB of its ${B2B_LLM_BUDGET_GB} GB budget. Drop a model from ai.models, pick a smaller quant, or raise ai.budget_gb"
    fi
    free=$(store_free_mb)
    if [ -n "$free" ] && [ $((MISSING_MB + RELEASE_MB)) -ge "$free" ]; then
        die "ai.models need $((MISSING_MB + RELEASE_MB)) MB and $B2B_LLM_DIR has ${free} MB free"
    fi
    mem_mb=$(host_mem_mb)
    vm_mb=$(vm_mem_mb)
    kv_mb=$(kv_mem_mb "$B2B_LLM_CONTEXT")
    need=$((LARGEST * 6 / 5 + kv_mb + vm_mb))
    if [ -n "$mem_mb" ] && [ "$need" -gt "$mem_mb" ]; then
        die "the largest of ai.models needs ~$((LARGEST * 6 / 5 + kv_mb)) MB with a ${B2B_LLM_CONTEXT}-token context, beside the VM's ${vm_mb} MB, and this host has ${mem_mb} MB. Pick a smaller quant or lower ai.context"
    fi

    print_notice
    key=$(ack_key)
    if grep -qx "$key" "$B2B_LLM_ACK_FILE" 2>/dev/null; then
        ok "accepted earlier for these settings (.b2b-llm-ack)"
    elif [ "${B2B_LLM_ACK:-}" = 1 ]; then
        echo "$key" >>"$B2B_LLM_ACK_FILE"
        ok "accepted (B2B_LLM_ACK=1)"
    elif ! (: </dev/tty) 2>/dev/null; then
        # [ -r /dev/tty ] is true with no controlling terminal; opening it is the test.
        die "no terminal to ask on: accept with B2B_LLM_ACK=1 make all, or set ai.host_models = false"
    else
        printf '  Go ahead? [y/N] '
        read -r answer </dev/tty || answer=
        case "$answer" in
        y | Y | yes | YES)
            echo "$key" >>"$B2B_LLM_ACK_FILE"
            ok "accepted; not asked again for the same settings"
            ;;
        *) die "not accepted: set ai.host_models = false in born2root.toml to build without it" ;;
        esac
    fi
    # The release is small, and whether it runs and what it can see are
    # worth knowing now rather than after the install.
    do_install
    choose_device
    info "llama.cpp will run on the $DEVICE_SAY"
}

do_pull() {
    local m id dir files size path file dest have budget_mb
    check_settings
    check_store "$B2B_LLM_DIR"
    budget_mb=$((B2B_LLM_BUDGET_GB * 1024))
    for m in $B2B_LLM_MODELS; do
        id=$(model_id "$m")
        if model_present "$m"; then
            ok "$id already in $MODELS_DIR"
            continue
        fi
        files=$(hf_files "$m") || die "ai.models: cannot list $m"
        dir="$MODELS_DIR/$id"
        mkdir -p "$dir" || die "cannot create $dir"
        chmod 700 "$B2B_LLM_DIR" 2>/dev/null || true
        while read -r size path; do
            [ -n "$path" ] || continue
            file="${path##*/}"
            dest="$dir/$file"
            have=0
            [ -f "$dest" ] && have=$(stat -c %s "$dest" 2>/dev/null || echo 0)
            if [ "$have" = "$size" ]; then
                continue
            fi
            [ -f "$dest.part" ] && have=$(stat -c %s "$dest.part" 2>/dev/null || echo 0)
            if [ $(($(store_used_mb) + $(mb_of_bytes "$((size - have))"))) -gt "$budget_mb" ]; then
                die "$file needs $(mb_of_bytes "$((size - have))") MB more and $B2B_LLM_DIR is at $(store_used_mb) MB of ${B2B_LLM_BUDGET_GB} GB"
            fi
            info "downloading $id: $file ($(mb_of_bytes "$size") MB)"
            # -C - continues a .part a previous run left behind.
            curl -fL -# --retry 5 -C - -o "$dest.part" "$B2B_LLM_HF/$(model_repo "$m")/resolve/main/$path" ||
                die "download of $file interrupted; run the same command again to resume it"
            have=$(stat -c %s "$dest.part" 2>/dev/null || echo 0)
            [ "$have" = "$size" ] || die "$file is $have bytes, Hugging Face declared $size; delete $dest.part and retry"
            mv "$dest.part" "$dest" || die "cannot move $dest.part into place"
        done <<EOF
$files
EOF
        : >"$dir/.complete"
        ok "$id ready"
    done
}

do_serve() {
    local pid i fa
    check_settings
    check_store "$B2B_LLM_DIR"
    check_bind "$B2B_LLM_HOST"
    if server_up; then
        pid=$(cat "$B2B_LLM_RUN/llama-server.pid" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            ok "llama-server already serving on $B2B_LLM_HOST (pid $pid)"
            return 0
        fi
        die "another server already answers on $B2B_LLM_HOST; stop it, or pick another port in ai.bind"
    fi
    release_present || do_install
    mkdir -p "$MODELS_DIR" "$B2B_LLM_RUN" || die "cannot create $MODELS_DIR"
    chmod 700 "$B2B_LLM_RUN" 2>/dev/null || true
    if [ ! -s "$KEY_FILE" ]; then
        (umask 077 && od -An -N24 -tx1 /dev/urandom | tr -d ' \n' >"$KEY_FILE")
    fi
    chmod 600 "$KEY_FILE"
    choose_device
    # Measured with llama-bench on the seat (CPU, Qwen3-Coder-30B-A3B, 8
    # threads, 2026-09-15): a q8_0 KV cache cost 25% of prompt speed (61 vs
    # 83 tok/s) for no gain in generation, so the cache stays f16. And one
    # slot: opencode fires a title request beside the real one, and with four
    # slots they split the CPU -- its first 7208-token prompt took 347 s at
    # 20.8 tok/s and generation fell from 31 to 8 tok/s -- and a request in
    # another slot re-reads opencode's ~7k-token system prompt instead of
    # reusing the cached prefix. Queued on one slot, every turn after the
    # first reuses it.
    # Flash attention is right on a GPU and wrong on this CPU: generating at
    # 8k tokens of context, where opencode lives, it ran at 8.2 tok/s with it
    # and 12.0 without (31 either way on an empty context).
    fa=auto
    [ "$DEVICE" = none ] && fa=off
    info "starting llama-server on $B2B_LLM_HOST, $DEVICE_SAY"
    env LD_LIBRARY_PATH="$BIN_DIR" nohup "$BIN_DIR/llama-server" \
        --models-dir "$MODELS_DIR" --models-max 1 \
        --host "$(bind_addr)" --port "$(bind_port)" --api-key-file "$KEY_FILE" \
        --device "$DEVICE" -fa "$fa" -c "$B2B_LLM_CONTEXT" -np 1 --jinja \
        >"$B2B_LLM_RUN/llama-server.log" 2>&1 &
    echo $! >"$B2B_LLM_RUN/llama-server.pid"
    i=0
    while [ "$i" -lt 30 ]; do
        if server_up; then
            ok "llama-server serving (pid $(cat "$B2B_LLM_RUN/llama-server.pid"), log $B2B_LLM_RUN/llama-server.log)"
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    die "llama-server did not answer on $B2B_LLM_HOST within 30 s; see $B2B_LLM_RUN/llama-server.log"
}

# The ids the router serves, one per line, asked of the router itself.
router_models() {
    curl -fsS --max-time 10 -H "Authorization: Bearer $(cat "$KEY_FILE" 2>/dev/null)" \
        "http://${B2B_LLM_HOST}/v1/models" 2>/dev/null |
        python3 -c 'import json, sys; [print(m["id"]) for m in json.load(sys.stdin).get("data", [])]' 2>/dev/null
}

# opencode's config: every configured model the router lists, the first as
# the default. The provider name is this file's marker; install_devtools.sh and
# install_ai.sh do not recognise it, so neither overwrites it later. It holds
# the API key, so it is written 600.
render_opencode_config() {
    local endpoint="$1" served="$2" m id models="" default=""
    for m in $B2B_LLM_MODELS; do
        id=$(model_id "$m")
        printf '%s\n' "$served" | grep -qx "$id" || continue
        [ -n "$default" ] || default="$id"
        models="$models$id
"
    done
    [ -n "$default" ] || return 1
    printf '{\n'
    # shellcheck disable=SC2016  # "$schema" is a literal JSON key
    printf '  "$schema": "https://opencode.ai/config.json",\n'
    printf '  "model": "llamacpp/%s",\n' "$default"
    printf '  "provider": {\n    "llamacpp": {\n'
    printf '      "npm": "@ai-sdk/openai-compatible",\n'
    printf '      "name": "llama.cpp (local, born2root)",\n'
    printf '      "options": { "baseURL": "http://%s/v1", "apiKey": "%s" },\n' "$endpoint" "$(cat "$KEY_FILE")"
    printf '      "models": {\n'
    printf '%s' "$models" | awk 'NF {
        printf "%s        \"%s\": { \"name\": \"%s\", \"tool_call\": true }", (n++ ? ",\n" : ""), $1, $1
    } END { if (n) printf "\n" }'
    printf '      }\n    }\n  }\n}\n'
}

# What runs in the guest, config on stdin. A file without a born2root marker
# is the user's and is left alone (exit 3). opencode's provider-less .jsonc
# stub goes, or which file wins would be a coin toss (see install_devtools.sh).
guest_write_script() {
    cat <<'GUESTEOF'
d="$HOME/.config/opencode"; f="$d/opencode.json"
if [ -f "$f" ] && ! grep -q born2root "$f"; then cat >/dev/null; exit 3; fi
mkdir -p "$d" && (umask 077 && cat >"$f.new") && mv "$f.new" "$f" && chmod 600 "$f" || exit 1
if [ -f "$d/opencode.jsonc" ] && ! grep -q '"provider"' "$d/opencode.jsonc"; then rm -f "$d/opencode.jsonc"; fi
exit 0
GUESTEOF
}

# The guest's forwarded SSH port, empty when it is not running. Both backends
# record it where vm_ports.sh looks, under VM_PATH as the Makefile exports it.
vm_ssh_port() {
    VM_PATH="${VM_PATH:-$REPO_ROOT/disk_images}"
    export VM_NAME VM_PATH
    [ -n "${VM_PORTS_SH_LOADED:-}" ] || . "$REPO_ROOT/setup/host/vm_ports.sh"
    vm_forward_port ssh 2>/dev/null
}

do_vm() {
    local port user cfg rc served
    check_settings
    server_up || die "llama-server is not running; make llm_host"
    served=$(router_models)
    [ -n "$served" ] || die "the router lists no model (is the API key in $KEY_FILE the one it started with?)"
    port=$(vm_ssh_port)
    [ -n "$port" ] || die "VM \"$VM_NAME\" has no ssh forward under $VM_PATH; start it (make qemu_start) and run make llm_host again"
    user="${VM_USER:-$(b2b_get B2B_LOGIN)}"
    [ -n "$user" ] || user=$(id -un)
    cfg=$(render_opencode_config "10.0.2.2:$(bind_port)" "$served") ||
        die "none of ai.models is served yet (the router has: $(printf '%s' "$served" | tr '\n' ' ')); run make llm_host"
    local ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
        -o LogLevel=ERROR -o ConnectTimeout=15 -o BatchMode=yes -p "$port")
    # shellcheck disable=SC2029 # the script is meant to be sent as it is
    printf '%s\n' "$cfg" | ssh "${ssh_opts[@]}" "$user@127.0.0.1" "$(guest_write_script)"
    rc=$?
    case "$rc" in
    0) ok "$user@$VM_NAME: opencode -> llama.cpp at 10.0.2.2:$(bind_port) ($(printf '%s' "$cfg" | sed -n 's/.*"model": "\(.*\)".*/\1/p'))" ;;
    3) die "$user@$VM_NAME: ~/.config/opencode/opencode.json is not a born2root config; add the llamacpp provider to it yourself" ;;
    *) die "could not reach $user@127.0.0.1:$port with key auth (ssh exit $rc)" ;;
    esac
    # The one network assumption this depends on, checked from where it matters.
    # shellcheck disable=SC2029 # the port is the host's, expanded here on purpose
    if ssh "${ssh_opts[@]}" "$user@127.0.0.1" "curl -fsS --max-time 5 http://10.0.2.2:$(bind_port)/health" >/dev/null 2>&1; then
        ok "the guest reaches llama-server at 10.0.2.2:$(bind_port)"
    else
        die "the guest cannot reach 10.0.2.2:$(bind_port); is the server up (make llm_status)?"
    fi
}

do_up() {
    check_settings
    check_store "$B2B_LLM_DIR"
    check_bind "$B2B_LLM_HOST"
    mkdir -p "$B2B_LLM_RUN" 2>/dev/null
    price_models
    print_notice
    do_install
    do_pull
    do_serve
    if [ -n "$(vm_ssh_port)" ]; then
        do_vm
    else
        warn "VM \"$VM_NAME\" is not running: the server is up, run make llm_host again once it is"
    fi
}

do_status() {
    local m
    printf 'store    %s  %s MB of %s GB budget\n' "$B2B_LLM_DIR" "$(store_used_mb)" "$B2B_LLM_BUDGET_GB"
    if release_present; then
        choose_device
        printf 'release  llama.cpp %s, would run on the %s\n' "$B2B_LLM_RELEASE" "$DEVICE_SAY"
    else
        printf 'release  llama.cpp %s not downloaded\n' "$B2B_LLM_RELEASE"
    fi
    if server_up; then
        printf 'server   up on %s\n' "$B2B_LLM_HOST"
    else
        printf 'server   down (make llm_host)\n'
    fi
    for m in $B2B_LLM_MODELS; do
        if model_present "$m"; then
            printf 'model    %-48s present\n' "$(model_id "$m")"
        else
            printf 'model    %-48s missing\n' "$(model_id "$m")"
        fi
    done
}

do_stop() {
    local pid
    pid=$(cat "$B2B_LLM_RUN/llama-server.pid" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" && ok "llama-server (pid $pid) stopped"
    else
        ok "no llama-server started by this script is running"
    fi
    rm -f "$B2B_LLM_RUN/llama-server.pid"
}

if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
    case "${1:-up}" in
    up) do_up ;;
    preflight) do_preflight ;;
    build)
        if enabled; then
            info "ai.host_models = true: serving the models and pointing opencode at them"
            do_install
            do_pull
            do_serve
            do_vm
        fi
        ;;
    install) do_install ;;
    pull) do_pull ;;
    serve) do_serve ;;
    vm) do_vm ;;
    status) do_status ;;
    stop) do_stop ;;
    *) die "usage: $0 up|preflight|build|install|pull|serve|vm|status|stop" ;;
    esac
fi
