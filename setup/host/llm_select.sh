#!/usr/bin/env hellish
#
# llm_select.sh — choose, on a terminal, what [ai] in born2root.toml serves:
# the folder, the budget, the context, the GPU mode and the models.
#
# WHY A PICKER, WHEN THE FILE IS EDITABLE
# ---------------------------------------
# The models are the one setting nobody can fill in from memory: a repository
# name, a quantization spelled the way that repository spells it, and a size
# that has to fit a per-user sgoinfre quota and this machine's RAM beside the
# VM. So the choices come from Hugging Face's own index, sorted by downloads,
# with every quantization's real size and a verdict -- fits, over the budget,
# too big for the RAM -- computed with the same arithmetic `make all`'s
# preflight refuses with. Nothing is suggested that preflight would reject.
#
# Every answer is the user's: the folder is typed (with $USER kept literal, so
# the tracked file names nobody), and so are the budget, context and GPU mode;
# Enter keeps the value shown. The result is written with b2b_config.py
# --set-ai, one line at a time, each validated before it replaces the file and
# every comment in born2root.toml left where it was. Ctrl-D writes nothing.
#
# USAGE
#   make llm_select            (make all offers it when [ai] is unconfirmed)
#   B2B_LLM_TTY=answers.txt setup/host/llm_select.sh   the tests' input

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$HERE/llm_host.sh"

B2B_LLM_TTY="${B2B_LLM_TTY:-/dev/tty}"
# One descriptor for the whole dialogue: reading the file afresh each time
# would answer every question with its first line.
exec 3<"$B2B_LLM_TTY" 2>/dev/null || die "make llm_select needs a terminal to ask on"

# ask <question> <default>: sets REPLY; Enter keeps the default, end of input
# (Ctrl-D) cancels with nothing written.
ask() {
    printf '  %s [%s] ' "$1" "$2"
    if ! IFS= read -r REPLY <&3; then
        printf '\n'
        die "cancelled: born2root.toml is unchanged"
    fi
    [ -n "$REPLY" ] || REPLY=$2
}

expand_user() {
    local v="$1" login
    login=$(id -un)
    v=${v//\$\{USER\}/$login}
    v=${v//\$USER/$login}
    printf '%s\n' "$v"
}

gb() { awk -v m="$1" 'BEGIN { printf "%.1f", m / 1024 }'; }
json_str() { python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"; }
plain() { sed 's/\x1b\[[0-9;]*m//g; s/^✗ //'; }

printf '\n  \033[1mAI models served from this computer\033[0m  (writes [ai] in %s)\n' "$B2B_CONFIG"
printf '  Enter keeps the value in brackets; Ctrl-D stops without writing.\n\n'

# ── The folder ──────────────────────────────────────────────────────────────
dir_raw=$(ai_conf models_dir)
while :; do
    # shellcheck disable=SC2016 # $USER is shown literally, as it is written
    ask 'Folder for the models ($USER is your login)' "$dir_raw"
    dir=$(expand_user "$REPLY")
    why=$( (check_store "$dir") 2>&1)
    if [ -n "$why" ]; then
        printf '    %s\n' "$(printf '%s' "$why" | plain)"
        continue
    fi
    parent="$dir"
    while [ ! -d "$parent" ] && [ "$parent" != / ]; do
        parent=$(dirname "$parent")
    done
    if [ ! -w "$parent" ]; then
        printf '    %s is not writable by you, so %s cannot be created\n' "$parent" "$dir"
        continue
    fi
    dir_raw=$REPLY
    # Everything llm_host.sh derived from the folder follows the new one.
    B2B_LLM_DIR=$dir
    # shellcheck disable=SC2034 # read by release_present, from llm_host.sh
    BIN_DIR="$B2B_LLM_DIR/bin/$B2B_LLM_RELEASE"
    MODELS_DIR="$B2B_LLM_DIR/models"
    break
done
free_mb=$(store_free_mb)
printf '    free there: %s GB\n' "$(gb "${free_mb:-0}")"

# ── The budget ──────────────────────────────────────────────────────────────
budget=$(ai_conf budget_gb)
while :; do
    ask 'The most that folder may hold, in GB' "$budget"
    case "$REPLY" in
    '' | *[!0-9]*) printf '    a whole number of GB\n' ;;
    *)
        if [ "$REPLY" -lt 1 ] || [ "$REPLY" -gt 1000 ]; then
            printf '    between 1 and 1000\n'
        elif [ -n "$free_mb" ] && [ $((REPLY * 1024)) -gt "$free_mb" ]; then
            printf '    only %s GB are free there\n' "$(gb "$free_mb")"
        else
            budget=$REPLY
            break
        fi
        ;;
    esac
done

# ── The context ─────────────────────────────────────────────────────────────
context=$(ai_conf context)
printf '\n    This computer has %s GB of RAM; the VM takes %s GB of it.\n' "$(gb "$(host_mem_mb)")" "$(gb "$(vm_mem_mb)")"
printf '    opencode needs 16384 tokens at least; its own instructions take ~10k.\n'
while :; do
    ask 'Context, in tokens (8192, 16384, 32768, 65536)' "$context"
    case "$REPLY" in
    '' | *[!0-9]*) printf '    a number of tokens\n' ;;
    *)
        if [ "$REPLY" -lt 4096 ] || [ "$REPLY" -gt 262144 ]; then
            printf '    between 4096 and 262144\n'
        elif [ "$(model_room_mb "$REPLY")" -lt 1024 ]; then
            printf '    that context leaves no room for a model beside the VM\n'
        else
            context=$REPLY
            break
        fi
        ;;
    esac
done
room_mb=$(model_room_mb "$context")
printf '    cache ~%s GB; the largest model that then fits: %s GB\n' "$(gb "$(kv_mem_mb "$context")")" "$(gb "$room_mb")"

# ── The GPU ─────────────────────────────────────────────────────────────────
gpu=$(ai_conf gpu)
seen=$(unbound_gpu)
if [ -n "$seen" ]; then
    printf '\n    This machine has a GPU (PCI %s) but kernel %s has no driver for it:\n' "$seen" "$(uname -r)"
    printf '    "auto" runs on the CPU until an administrator installs a newer kernel.\n'
fi
while :; do
    ask 'GPU: auto (GPU if usable, else CPU), cpu, or vulkan (refuse without GPU)' "$gpu"
    case "$REPLY" in
    auto | cpu | vulkan)
        gpu=$REPLY
        break
        ;;
    *) printf '    auto, cpu or vulkan\n' ;;
    esac
done

# ── The models ──────────────────────────────────────────────────────────────
models=$(ai_conf models)
budget_mb=$((budget * 1024))
printf '\n    Configured now: %s\n' "${models:-none}"
ask 'Keep them (k) or choose from Hugging Face (c)?' "c"
if [ "$REPLY" != k ]; then
    models=""
    # What the folder already holds counts: a model not picked again stays on
    # disk, and preflight measures the folder, not the list.
    spent_mb=$(store_used_mb)
    release_present || spent_mb=$((spent_mb + 100))
    if [ -d "$MODELS_DIR" ] && [ -n "$(ls -A "$MODELS_DIR" 2>/dev/null)" ]; then
        printf '\n    Already in %s (counted against the budget):\n' "$MODELS_DIR"
        du -sm "$MODELS_DIR"/*/ 2>/dev/null | awk '{ n = $2; sub(/\/$/, "", n); sub(/.*\//, "", n); printf "      %-56s %6.1f GB\n", n, $1 / 1024 }'
        printf '    Picking one again costs nothing; rm -rf its directory to free the space.\n'
    fi
    term=coder
    while :; do
        printf '\n    %s GB of the %s GB budget left\n' "$(gb $((budget_mb - spent_mb)))" "$budget"
        ask 'Search Hugging Face GGUF models (a word, or - for the most downloaded)' "$term"
        term=$REPLY
        query=$term
        [ "$query" = - ] && query=
        results=$(hf_search "$query" 15)
        if [ -z "$results" ]; then
            printf '    nothing found for "%s" (or Hugging Face did not answer)\n' "$term"
            continue
        fi
        printf '%s\n' "$results" | awk '{ printf "    %2d) %-64s %9d downloads\n", NR, $1, $2 }'
        ask 'Model number, or s to search again' 1
        case "$REPLY" in
        '' | *[!0-9]*) continue ;;
        esac
        repo=$(printf '%s\n' "$results" | sed -n "${REPLY}p" | cut -d' ' -f1)
        [ -n "$repo" ] || continue
        quants=$(hf_quants "$repo")
        if [ -z "$quants" ]; then
            printf '    %s lists no GGUF quantization\n' "$repo"
            continue
        fi
        left_mb=$((budget_mb - spent_mb))
        # The verdict per quantization, and the best usable one as the default.
        # One already in the folder costs nothing, whatever the budget says.
        table=$(printf '%s\n' "$quants" | while read -r q bytes; do
            mb=$(mb_of_bytes "$bytes")
            if model_present "$repo:$q"; then
                v="already in the folder"
            elif [ "$mb" -gt "$room_mb" ]; then
                v="too big for the RAM"
            elif [ "$mb" -gt "$left_mb" ]; then
                v="over the budget"
            else
                v=fits
            fi
            printf '%s %s %s\n' "$q" "$mb" "$v"
        done)
        printf '%s\n' "$table" | awk '{ v = $3; for (i = 4; i <= NF; i++) v = v " " $i
            printf "    %2d) %-16s %6.1f GB   %s\n", NR, $1, $2 / 1024, v }'
        best=$(printf '%s\n' "$table" | awk '$3 == "fits" || $3 == "already" { n = NR } END { print n + 0 }')
        [ "$best" -gt 0 ] || best=b
        ask 'Quantization number (bigger is better quality), or b to go back' "$best"
        case "$REPLY" in
        '' | *[!0-9]*) continue ;;
        esac
        row=$(printf '%s\n' "$table" | sed -n "${REPLY}p")
        [ -n "$row" ] || continue
        # shellcheck disable=SC2086 # quant, MB and verdict, as three words and more
        set -- $row
        if model_present "$repo:$1"; then
            models="${models:+$models }$repo:$1"
            printf '    %s:%s is already in the folder, nothing to download\n' "$repo" "$1"
            ask 'Add another model?' n
            [ "$REPLY" = y ] || break
            continue
        fi
        if [ "$3" != fits ]; then
            shift 2
            printf '    %s: %s\n' "$repo" "$*"
            continue
        fi
        models="${models:+$models }$repo:$1"
        spent_mb=$((spent_mb + $2))
        printf '    added %s:%s (%s GB)\n' "$repo" "$1" "$(gb "$2")"
        ask 'Add another model?' n
        [ "$REPLY" = y ] || break
    done
fi

# ── Write it ────────────────────────────────────────────────────────────────
printf '\n    folder   %s\n    budget   %s GB\n    context  %s tokens\n    gpu      %s\n' "$dir_raw" "$budget" "$context" "$gpu"
for m in $models; do
    printf '    model    %s\n' "$m"
done
ask 'Write this to born2root.toml and turn host models on?' y
[ "$REPLY" = y ] || die "nothing written"
# shellcheck disable=SC2086 # one argument per model
models_json=$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1:]))' $models)
for pair in "models_dir=$(json_str "$dir_raw")" "budget_gb=$budget" "context=$context" \
    "gpu=$(json_str "$gpu")" "models=$models_json" "host_models=true"; do
    b2b_set_ai "${pair%%=*}" "${pair#*=}" || die "born2root.toml refused ai.${pair%%=*}; the lines before it were written"
done
ok "[ai] written to $B2B_CONFIG; make llm_host serves it now, make all builds with it"
