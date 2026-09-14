#!/usr/bin/env hellish
#
# spinner.sh — the live spinner of the QEMU build, sourced by
# setup/host/qemu_vm.sh and setup/host/qemu_pipeline.sh.
#
# The install watcher used to advance its spinner once per poll, and a poll is
# two seconds: a braille wheel at 0.5 frames per second reads as frozen. The
# polls are right to be slow (each one reads the serial log, the qcow2 size
# and /proc), so the animation is separated from them: between two polls the
# spinner is redrawn every SPIN_MS milliseconds, and a frame forks nothing but
# its `sleep` -- the glyph, its colour and the sweep are prepared once, here,
# and a frame only indexes arrays.
#
# Only a terminal gets the animation. Without one (CI, `make all | tee`) every
# function below degrades to a plain sleep, so a captured log holds no escape
# sequences and no thousand redraws.
#
#   spin_tty                    true when stdout is a terminal worth animating
#   spin_frame                  sets SPIN_GLYPH and SPIN_SWEEP for the next frame
#   spin_sleep SECS [LABEL]     sleep, animating one line; the line is cleared after
#   spin_block_sleep SECS UP    sleep, redrawing $SPIN_LINE -- the first line of a
#                               live block drawn UP lines above the cursor

# Milliseconds per frame. Waits count frames, not $SECONDS (whole seconds, so
# a 2 s wait could end after 1): a frame's sleep plus its fork only ever makes
# a wait slightly longer than asked, never shorter.
SPIN_MS="${SPIN_MS:-80}"
printf -v SPIN_SLEEP '%d.%03d' $((SPIN_MS / 1000)) $((SPIN_MS % 1000))
SPIN_I=0
SPIN_GLYPH=""
SPIN_SWEEP=""
SPIN_WHEEL=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
SPIN_COLORS=()
SPIN_SWEEPS=()

spin_tty() {
    [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]
}

# A cyan-to-violet ramp there and back (256-colour codes), and a short bright
# segment sliding along a dim track, one precomputed string per frame.
spin_prepare() {
    local c w=14 seg=4 pos i s
    SPIN_COLORS=()
    for c in 51 45 39 33 63 99 135 171 135 99 63 33 39 45; do
        SPIN_COLORS+=($'\033[38;5;'"${c}m")
    done
    SPIN_SWEEPS=()
    for ((pos = -seg; pos < w; pos++)); do
        s=""
        for ((i = 0; i < w; i++)); do
            if [ "$i" -ge "$pos" ] && [ "$i" -lt $((pos + seg)) ]; then
                s="${s}"$'\033[38;5;45m━'
            else
                s="${s}"$'\033[38;5;238m━'
            fi
        done
        SPIN_SWEEPS+=("${s}"$'\033[0m')
    done
}
spin_prepare

# The lengths are read into variables first: hellish 2.10.2 cannot parse a
# ${#arr[@]} nested in an arithmetic subscript (${a[$((i % ${#a[@]}))]}).
spin_frame() {
    local nc=${#SPIN_COLORS[@]} nw=${#SPIN_WHEEL[@]} ns=${#SPIN_SWEEPS[@]}
    SPIN_GLYPH="${SPIN_COLORS[$((SPIN_I % nc))]}${SPIN_WHEEL[$((SPIN_I % nw))]}"$'\033[0m'
    SPIN_SWEEP="${SPIN_SWEEPS[$((SPIN_I % ns))]}"
    SPIN_I=$((SPIN_I + 1))
}

spin_sleep() { # SECS [LABEL]
    local secs="$1" label="${2:-}" n k
    if ! spin_tty; then
        sleep "$secs"
        return 0
    fi
    n=$((secs * 1000 / SPIN_MS))
    for ((k = 0; k < n; k++)); do
        spin_frame
        printf '\r\033[K  %s %s  %s  \033[2m%ds\033[0m' "$SPIN_GLYPH" "$label" "$SPIN_SWEEP" $(((n - k) * SPIN_MS / 1000))
        sleep "$SPIN_SLEEP"
    done
    printf '\r\033[K'
}

# SPIN_LINE is the block's first line with the two placeholders @G@ (glyph)
# and @S@ (sweep) in it; the caller rebuilds it whenever its content changes.
spin_block_sleep() { # SECS LINES_UP
    local secs="$1" up="$2" n k line
    n=$((secs * 1000 / SPIN_MS))
    for ((k = 0; k < n; k++)); do
        spin_frame
        line="${SPIN_LINE//@G@/$SPIN_GLYPH}"
        line="${line//@S@/$SPIN_SWEEP}"
        printf '\0337\033[%dA\r\033[K%s\0338' "$up" "$line"
        sleep "$SPIN_SLEEP"
    done
}
