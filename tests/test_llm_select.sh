#!/usr/bin/env hellish
# Regression test for setup/host/llm_select.sh, the [ai] model picker, with
# no network and no terminal: the dialogue is a file (B2B_LLM_TTY) and
# Hugging Face is a stand-in curl.
#
# What it pins down:
#   - a folder in the home quota, or a relative one, is refused and asked
#     again, and the accepted one is written with $USER still literal;
#   - a quantization over the budget is refused and not added;
#   - the choices land in born2root.toml's [ai] lines, validated, with every
#     comment kept and host_models turned on;
#   - input that ends (Ctrl-D) writes nothing;
#   - b2b_config.py --set-ai refuses a value --check would, file untouched.
# shellcheck disable=SC2016 # $USER is written literally on purpose
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
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/sg"
SH="${SCRIPT_SH:-bash}"

cat >"$TMP/search.json" <<'EOF'
[{"id":"org/Small-GGUF","downloads":900},{"id":"org/Big-GGUF","downloads":500}]
EOF
# Big-GGUF: Q2_K at 2 GiB (over a 1 GB budget) and Q4_0 at 300 MiB.
cat >"$TMP/tree.json" <<'EOF'
[{"type":"file","path":"Big-Q2_K.gguf","size":2147483648},
{"type":"file","path":"Big-Q4_0-00001-of-00002.gguf","size":157286400},
{"type":"file","path":"Big-Q4_0-00002-of-00002.gguf","size":157286400},
{"type":"file","path":"mmproj-Big-Q4_0.gguf","size":1000}]
EOF
cat >"$TMP/bin/curl" <<'EOF'
#!/bin/sh
for a in "$@"; do
    case "$a" in
    */api/models/*/tree/main*) cat "$FAKE_TREE"; exit 0 ;;
    */api/models) cat "$FAKE_SEARCH"; exit 0 ;;
    esac
done
exit 22
EOF
cat >"$TMP/meminfo" <<'EOF'
MemTotal:       32000000 kB
EOF
chmod +x "$TMP/bin/curl"

# A config with a comment in [ai], to see it survive.
CFG="$TMP/born2root.toml"
sed 's/^\[ai\]$/[ai]\n# keep me/' tests/fixtures/default.toml >"$CFG"
export PATH="$TMP/bin:$PATH" FAKE_TREE="$TMP/tree.json" FAKE_SEARCH="$TMP/search.json"
export B2B_CONFIG="$CFG" B2B_LLM_MEMINFO="$TMP/meminfo" VM_RAM_MB=2048 B2B_LLM_SYSFS="$TMP/nosys"
export B2B_LLM_RUN="$TMP/run" HOME="$TMP/home"

# folder: relative, then in $HOME, then accepted; budget 1; context 16384;
# gpu cpu; choose; search "big"; model 2; quantization 2 (Q2_K, listed after
# the smaller Q4_0, over budget) refused; search again, model 2, quantization
# 1; no more; write.
cat >"$TMP/answers" <<EOF
llm
$TMP/home/llm
$TMP/sg/\$USER/llm
1
16384
cpu
c
big
2
2
big
2
1
n
y
EOF
env B2B_LLM_TTY="$TMP/answers" "$SH" setup/host/llm_select.sh >"$TMP/out" 2>&1
rc=$?
check "the dialogue completes" "$rc" 0
[ "$rc" = 0 ] || tail -n 15 "$TMP/out" | sed 's/^/     | /'
check "relative folder refused" "$(grep -c 'must be absolute' "$TMP/out")" 1
check "home folder refused" "$(grep -c 'inside \$HOME' "$TMP/out")" 1
check "over-budget quantization listed as such" "$(grep -c 'Q2_K .*over the budget' "$TMP/out")" 2
check "  ...and refused when picked" "$(grep -c 'org/Big-GGUF: over the budget' "$TMP/out")" 1
get() { env B2B_CONFIG="$CFG" python3 utils/b2b_config.py get "$1"; }
cfg_rc() {
    env B2B_CONFIG="$CFG" python3 utils/b2b_config.py "$@" >/dev/null 2>&1
    echo $?
}
check "models written" "$(get ai.models)" "org/Big-GGUF:Q4_0"
check "folder written with \$USER literal" "$(get ai.models_dir)" "$TMP/sg/\$USER/llm"
check "budget written" "$(get ai.budget_gb)" 1
check "context written" "$(get ai.context)" 16384
check "gpu written" "$(get ai.gpu)" cpu
check "host models turned on" "$(get ai.host_models)" true
check "the comment survives" "$(grep -c '^# keep me$' "$CFG")" 1
check "the file still validates" "$(cfg_rc --check)" 0

# A model already in the folder is picked without being counted twice, even
# when the budget left could not hold it again.
mkdir -p "$TMP/sg/$(id -un)/llm/models/Big-Q2_K"
: >"$TMP/sg/$(id -un)/llm/models/Big-Q2_K/.complete"
cat >"$TMP/again" <<EOF
$TMP/sg/\$USER/llm
1


c
big
2
2
n
y
EOF
env B2B_LLM_TTY="$TMP/again" "$SH" setup/host/llm_select.sh >"$TMP/out3" 2>&1
check "an already downloaded model is accepted" "$(get ai.models)" "org/Big-GGUF:Q2_K"
check "  ...listed as already there" "$(grep -c 'already in the folder, nothing to download' "$TMP/out3")" 1
check "  ...and the folder's content shown" "$(grep -cE '^ +Big-Q2_K +[0-9.]+ GB$' "$TMP/out3")" 1

# Input that stops half way writes nothing.
cp "$CFG" "$TMP/before.toml"
printf '%s\n' "$TMP/sg/\$USER/other" 3 >"$TMP/short"
env B2B_LLM_TTY="$TMP/short" "$SH" setup/host/llm_select.sh >"$TMP/out2" 2>&1
check "ended input fails" "$?" 1
check "  ...and changes nothing" "$(cmp -s "$CFG" "$TMP/before.toml" && echo same)" same

# --set-ai refuses a value --check would.
check "--set-ai refuses 0.0.0.0" "$(cfg_rc --set-ai bind '"0.0.0.0:8012"')" 1
check "--set-ai refuses an unknown key" "$(cfg_rc --set-ai modles '[]')" 1
check "  ...file untouched" "$(cmp -s "$CFG" "$TMP/before.toml" && echo same)" same

exit "$fail"
