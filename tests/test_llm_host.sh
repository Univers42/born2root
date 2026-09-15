#!/usr/bin/env hellish
# Regression test for setup/host/llm_host.sh, with no network, no GPU and no
# llama.cpp.
#
# What it pins down, each a way the helper could quietly cost the owner:
#   - the store is refused under $HOME (a 4.7 GB quota) and in disk_images;
#   - a non-loopback bind needs ai.expose;
#   - the quant picker sums split GGUF parts, never counts an mmproj file, and
#     does not let "Q3_K_XL" select unsloth's different "UD-Q3_K_XL" file;
#   - an interrupted download is resumed, and a model is served only once its
#     .complete stamp exists;
#   - llvmpipe is not a GPU: auto falls back to the CPU and says so, and
#     gpu = "vulkan" refuses; a Radeon is used;
#   - opencode's config names only what the router serves, carries the API
#     key, and a config the user wrote is left alone;
#   - `make all`'s preflight is silent when ai.host_models is off, refuses
#     over budget or over RAM before the 20-minute install, and never starts
#     without an answer that matches the current settings;
#   - "$USER" in ai.models_dir is the host login.
#
# curl, df and llama-server are stand-ins; llm_host.sh's BASH_SOURCE guard
# skips its dispatch when sourced, and every refusal runs in a child shell
# because die() exits.
# shellcheck disable=SC2016 # the snippets run by a child shell expand there
set -u

cd "$(dirname "$0")/.." || exit 1

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-50s = %s\n' "$1" "$2"
    else
        printf 'FAIL %-50s = %s (expected %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home"
SH="${SCRIPT_SH:-bash}"

# One entry per line, so the fake curl can look a size up with grep.
cat >"$TMP/tree.json" <<'EOF'
[
{"type":"file","path":"README.md","size":10},
{"type":"file","path":"Model-Q4_K_M-00001-of-00002.gguf","size":600},
{"type":"file","path":"Model-Q4_K_M-00002-of-00002.gguf","size":400},
{"type":"file","path":"mmproj-Model-Q4_K_M.gguf","size":50},
{"type":"file","path":"Model-UD-Q3_K_XL.gguf","size":1000},
{"type":"file","path":"Q8_0/Model-Q8_0.gguf","lfs":{"size":2000},"size":130}
]
EOF

cat >"$TMP/bin/curl" <<'EOF'
#!/bin/sh
head=0 resume=0 out=
url=
while [ $# -gt 0 ]; do
    case "$1" in
    -I | -fsSIL) head=1 ;;
    -C) resume=1; shift ;;
    -o) out=$2; shift ;;
    -H | --max-time | --retry) shift ;;
    http*) url=$1 ;;
    esac
    shift
done
case "$url" in
*/api/models/*/tree/main*) cat "$FAKE_TREE" ;;
*/health) [ "${FAKE_UP:-0}" = 1 ] || exit 7; echo '{"status":"ok"}' ;;
*/v1/models)
    printf '{"data":['
    n=0
    for id in $FAKE_SERVED; do
        [ $n = 0 ] || printf ','
        printf '{"id":"%s"}' "$id"
        n=1
    done
    printf ']}\n'
    ;;
*/releases/download/*)
    if [ "$head" = 1 ]; then printf 'HTTP/2 200\r\ncontent-length: 30188817\r\n'; exit 0; fi
    cp "$FAKE_TARBALL" "$out"
    ;;
*/resolve/main/*)
    path=${url#*/resolve/main/}
    size=$(grep "\"path\":\"$path\"" "$FAKE_TREE" | sed 's/.*"size":\([0-9]*\)}.*/\1/')
    have=0
    [ -f "$out" ] && have=$(stat -c %s "$out")
    [ "$resume" = 1 ] && [ "$have" -gt 0 ] && echo "resume $path" >>"$FAKE_LOG"
    echo "get $path" >>"$FAKE_LOG"
    head -c $((size - have)) /dev/zero >>"$out"
    ;;
*) exit 22 ;;
esac
EOF
cat >"$TMP/bin/df" <<'EOF'
#!/bin/sh
printf 'Filesystem 1048576-blocks Used Available Capacity Mounted\nfake 9999999 0 %s 0%% /\n' "${FAKE_FREE_MB:-999999}"
EOF
chmod +x "$TMP/bin/curl" "$TMP/bin/df"

# The release: a llama-server that prints a version and FAKE_DEVICES.
mkdir -p "$TMP/rel/llama-b10970"
cat >"$TMP/rel/llama-b10970/llama-server" <<'EOF'
#!/bin/sh
case "$1" in
--version) echo "version: 0.4.1 (build 10970)" ;;
--list-devices) printf 'Available devices:\n%b' "${FAKE_DEVICES:-  (none)\n}" ;;
esac
EOF
chmod +x "$TMP/rel/llama-b10970/llama-server"
tar -czf "$TMP/rel.tar.gz" -C "$TMP/rel" llama-b10970

export PATH="$TMP/bin:$PATH" FAKE_TREE="$TMP/tree.json" FAKE_LOG="$TMP/curl.log"
export FAKE_TARBALL="$TMP/rel.tar.gz" FAKE_UP=0 FAKE_SERVED=
export B2B_LLM_DIR="$TMP/store" B2B_LLM_RUN="$TMP/run" B2B_LLM_ACK_FILE="$TMP/ack"
export B2B_LLM_MODELS="org/Model-GGUF:Q4_K_M" B2B_LLM_BUDGET_GB=15 B2B_LLM_RELEASE=b10970
export B2B_LLM_GPU=auto B2B_LLM_CONTEXT=32768 B2B_LLM_HOST=127.0.0.1:8012 B2B_LLM_EXPOSE=0
export B2B_LLM_ENABLE=false VM_RAM_MB=2048

. ./setup/host/llm_host.sh

rc() {
    "$@" >/dev/null 2>&1
    echo $?
}
in_child() {
    env "$@" >/dev/null 2>&1
    echo $?
}
lib() { printf '. ./setup/host/llm_host.sh; %s' "$1"; }

# ── Guards ──────────────────────────────────────────────────────────────────
check "store under \$HOME refused" "$(in_child HOME="$TMP/home" "$SH" -c "$(lib "check_store '$TMP/home/llm'")")" 1
check "store in disk_images refused" "$(in_child "$SH" -c "$(lib 'check_store /goinfre/x/disk_images/llm')")" 1
check "store on sgoinfre accepted" "$(rc check_store /sgoinfre/students/someone/llm)" 0
check "bind 0.0.0.0 refused" "$(in_child "$SH" -c "$(lib 'check_bind 0.0.0.0:8012')")" 1
check "bind 0.0.0.0 with ai.expose" "$(in_child B2B_LLM_EXPOSE=1 "$SH" -c "$(lib 'check_bind 0.0.0.0:8012')")" 0
check "bind loopback accepted" "$(rc check_bind 127.0.0.1:8012)" 0

# ── Picking files ───────────────────────────────────────────────────────────
check "model id drops -GGUF" "$(model_id unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:UD-Q3_K_XL)" "Qwen3-Coder-30B-A3B-Instruct-UD-Q3_K_XL"
check "split parts picked, mmproj not" "$(hf_files org/Model-GGUF:Q4_K_M | awk '{ print $2 }' | tr '\n' ' ')" "Model-Q4_K_M-00001-of-00002.gguf Model-Q4_K_M-00002-of-00002.gguf "
check "quant match ignores case" "$(hf_files org/Model-GGUF:q4_k_m | wc -l | tr -d ' ')" 2
check "Q3_K_XL does not select UD-Q3_K_XL" "$(rc hf_files org/Model-GGUF:Q3_K_XL)" 1
check "  ...and names what exists" "$(hf_files org/Model-GGUF:Q3_K_XL 2>&1 | grep -c 'UD-Q3_K_XL')" 1
check "UD-Q3_K_XL selects it" "$(hf_files org/Model-GGUF:UD-Q3_K_XL | awk '{ print $1 }')" 1000
check "LFS size wins, subfolder kept" "$(hf_files org/Model-GGUF:Q8_0)" "2000 Q8_0/Model-Q8_0.gguf"

# ── Downloading ─────────────────────────────────────────────────────────────
: >"$FAKE_LOG"
D="$TMP/store/models/Model-Q4_K_M"
mkdir -p "$D"
head -c 100 /dev/zero >"$D/Model-Q4_K_M-00001-of-00002.gguf.part"
check "pull succeeds" "$(in_child "$SH" setup/host/llm_host.sh pull)" 0
check "  ...resumes the .part" "$(grep -c 'resume Model-Q4_K_M-00001' "$FAKE_LOG")" 1
check "  ...to the declared size" "$(stat -c %s "$D/Model-Q4_K_M-00001-of-00002.gguf")" 600
check "  ...stamps it complete" "$(rc test -f "$D/.complete")" 0
: >"$FAKE_LOG"
check "pull again succeeds" "$(in_child "$SH" setup/host/llm_host.sh pull)" 0
check "  ...downloading nothing" "$(wc -l <"$FAKE_LOG" | tr -d ' ')" 0
check "no stamp, not present" "$(in_child B2B_LLM_MODELS=org/Model-GGUF:Q8_0 "$SH" -c "$(lib 'model_present org/Model-GGUF:Q8_0')")" 1

# ── The release and the device ──────────────────────────────────────────────
check "install fetches and unpacks the release" "$(in_child "$SH" setup/host/llm_host.sh install)" 0
check "  ...llama-server in bin/<tag>" "$(rc test -x "$TMP/store/bin/b10970/llama-server")" 0
dev() { env "$@" "$SH" -c "$(lib 'choose_device; printf "%s|%s" "$DEVICE" "$DEVICE_SAY"')" 2>&1; }
LLVMPIPE='  Vulkan0: llvmpipe (LLVM 15.0.7, 256 bits) (32000 MiB, 30000 MiB free)\n'
RADEON='  Vulkan0: AMD Radeon 780M Graphics (RADV PHOENIX) (16384 MiB, 15000 MiB free)\n'
# A /sys with one display device and no driver bound: the school seat's 780M.
SYS="$TMP/sys"
mkdir -p "$SYS/bus/pci/devices/0000:04:00.0" "$SYS/bus/pci/devices/0000:00:14.0/driver"
printf '0x030000\n' >"$SYS/bus/pci/devices/0000:04:00.0/class"
printf '0x1002\n' >"$SYS/bus/pci/devices/0000:04:00.0/vendor"
printf '0x15bf\n' >"$SYS/bus/pci/devices/0000:04:00.0/device"
printf '0x0c0330\n' >"$SYS/bus/pci/devices/0000:00:14.0/class"
check "unbound GPU found" "$(env B2B_LLM_SYSFS="$SYS" "$SH" -c "$(lib unbound_gpu)")" "1002:15bf"
check "  ...and named as the reason" "$(dev B2B_LLM_SYSFS="$SYS" FAKE_DEVICES="$LLVMPIPE" | grep -c 'no driver bound')" 1
mkdir -p "$SYS/bus/pci/devices/0000:04:00.0/driver"
check "a bound GPU is not unbound" "$(in_child B2B_LLM_SYSFS="$SYS" "$SH" -c "$(lib unbound_gpu)")" 1
check "llvmpipe only: CPU" "$(dev FAKE_DEVICES="$LLVMPIPE" | cut -d'|' -f1)" none
check "  ...and it says there is no GPU" "$(dev B2B_LLM_SYSFS="$TMP/nosys" FAKE_DEVICES="$LLVMPIPE" | grep -c 'sees no GPU')" 1
check "llvmpipe only, gpu = vulkan: refused" "$(in_child FAKE_DEVICES="$LLVMPIPE" B2B_LLM_GPU=vulkan "$SH" -c "$(lib choose_device)")" 1
check "Radeon: Vulkan0" "$(dev FAKE_DEVICES="$LLVMPIPE$RADEON" | cut -d'|' -f1)" Vulkan0
check "  ...named" "$(dev FAKE_DEVICES="$RADEON" | grep -c 'Radeon 780M')" 1
check "gpu = cpu ignores the Radeon" "$(dev FAKE_DEVICES="$RADEON" B2B_LLM_GPU=cpu | cut -d'|' -f1)" none

# ── opencode's config ───────────────────────────────────────────────────────
mkdir -p "$TMP/store"
echo "sekrit" >"$TMP/store/api-key"
env B2B_LLM_MODELS="org/Model-GGUF:Q4_K_M org/Other-GGUF:Q8_0 org/Gone-GGUF:Q2_K" "$SH" -c \
    "$(lib 'render_opencode_config 10.0.2.2:8012 "$(printf "Other-Q8_0\nModel-Q4_K_M\n")"')" >"$TMP/cfg.json"
check "config is valid JSON" "$(rc python3 -m json.tool "$TMP/cfg.json")" 0
py() { python3 -c "import json,sys; c=json.load(open(sys.argv[1])); print($1)" "$TMP/cfg.json"; }
check "default is the first configured one served" "$(py 'c["model"]')" "llamacpp/Model-Q4_K_M"
check "only served models listed" "$(py '" ".join(c["provider"]["llamacpp"]["models"])')" "Model-Q4_K_M Other-Q8_0"
check "API key carried" "$(py 'c["provider"]["llamacpp"]["options"]["apiKey"]')" sekrit
check "nothing served: no config" "$(rc render_opencode_config 10.0.2.2:8012 "Unrelated")" 1

G="$TMP/guest"
mkdir -p "$G/.config/opencode"
guest_write_script >"$TMP/guest.sh"
echo '{"model":"mine"}' >"$G/.config/opencode/opencode.json"
check "guest: user's own config refused" "$(in_child HOME="$G" sh "$TMP/guest.sh" <"$TMP/cfg.json")" 3
check "  ...and left untouched" "$(cat "$G/.config/opencode/opencode.json")" '{"model":"mine"}'
echo '{"name":"Ollama (born2root baseline)"}' >"$G/.config/opencode/opencode.json"
echo '{"$schema":"x"}' >"$G/.config/opencode/opencode.jsonc"
check "guest: baseline config replaced" "$(in_child HOME="$G" sh "$TMP/guest.sh" <"$TMP/cfg.json")" 0
check "  ...with the rendered one, mode 600" "$(rc cmp -s "$G/.config/opencode/opencode.json" "$TMP/cfg.json") $(stat -c %a "$G/.config/opencode/opencode.json")" "0 600"
check "  ...provider-less .jsonc stub removed" "$(rc test -e "$G/.config/opencode/opencode.jsonc")" 1

# ── preflight, as make all runs it ──────────────────────────────────────────
# setsid: no controlling terminal, so "ask" cannot quietly read an answer.
pre() {
    setsid -w env "$@" "$SH" setup/host/llm_host.sh preflight >"$TMP/pre.out" 2>&1 </dev/null
    echo $?
}
BIG="$TMP/big.json"
sed 's/"size":1000}/"size":17179869184}/' "$TMP/tree.json" >"$BIG"
HUGE="$TMP/huge.json"
sed 's/"size":1000}/"size":858993459200}/' "$TMP/tree.json" >"$HUGE"
check "preflight off: succeeds" "$(pre B2B_LLM_ENABLE=false)" 0
check "  ...and says nothing" "$(wc -c <"$TMP/pre.out" | tr -d ' ')" 0
check "preflight over budget refused" "$(pre B2B_LLM_ENABLE=true FAKE_TREE="$BIG" B2B_LLM_MODELS=org/Model-GGUF:UD-Q3_K_XL)" 1
check "  ...naming ai.models" "$(grep -c 'ai.models need' "$TMP/pre.out")" 1
check "preflight over RAM refused" "$(pre B2B_LLM_ENABLE=true FAKE_TREE="$HUGE" B2B_LLM_BUDGET_GB=1000 B2B_LLM_MODELS=org/Model-GGUF:UD-Q3_K_XL)" 1
check "  ...naming memory" "$(grep -c 'beside the VM' "$TMP/pre.out")" 1
check "preflight unknown quant refused" "$(pre B2B_LLM_ENABLE=true B2B_LLM_MODELS=org/Model-GGUF:Q9_9)" 1
: >"$TMP/ack"
check "no terminal, no answer: refused" "$(pre B2B_LLM_ENABLE=true B2B_LLM_MODELS=org/Model-GGUF:UD-Q3_K_XL)" 1
check "  ...after saying what it would do" "$(grep -c 'no sudo' "$TMP/pre.out")" 1
check "  ...naming B2B_LLM_ACK=1" "$(grep -c 'B2B_LLM_ACK=1' "$TMP/pre.out")" 1
check "  ...listing the download" "$(grep -c 'Model-UD-Q3_K_XL' "$TMP/pre.out")" 1
check "B2B_LLM_ACK=1 accepts" "$(pre B2B_LLM_ENABLE=true B2B_LLM_ACK=1 B2B_LLM_MODELS=org/Model-GGUF:UD-Q3_K_XL)" 0
check "  ...and reports the device" "$(grep -c 'will run on the CPU' "$TMP/pre.out")" 1
check "the answer is remembered" "$(pre B2B_LLM_ENABLE=true B2B_LLM_MODELS=org/Model-GGUF:UD-Q3_K_XL)" 0
check "other models: asked again" "$(pre B2B_LLM_ENABLE=true B2B_LLM_MODELS=org/Model-GGUF:Q8_0)" 1

# shellcheck disable=SC2016 # the literal placeholder, as born2root.toml has it
check "\$USER in models_dir is the login" \
    "$(env B2B_LLM_DIR='/sgoinfre/students/$USER/llm' "$SH" -c '. ./setup/host/llm_host.sh; printf %s "$B2B_LLM_DIR"')" \
    "/sgoinfre/students/$(id -un)/llm"

exit "$fail"
