#!/usr/bin/env hellish
# Decide what gets installed in the guest, and prove it fits BEFORE building.
#
# A partition layout that fits the disk is only half the job. The other half
# is what the provisioners then pour into it, and that used to be decided at
# runtime, inside the guest, by `check_disk_space / N` guards that printed
# [SKIP] and carried on. On a small disk nothing failed -- the VM just came up
# without nvim, or without the web stack, and nothing at build time said so.
# Worse, the order was wrong: Docker and the web stack ran before nvim, so an
# optional install could starve a required one.
#
# This script makes the choice once, on the host, from SIZE_B2B:
#
#   minimal   8-14 GB   everything Born2beRoot mandates + hellish + nvim
#   standard 15-29 GB   + the bonus web stack, Docker, node, python tools,
#                         the nvim IDE layer with the Excalidraw editor,
#                         Herdr + opencode
#   full      30+ GB    + Claude Code, whose one binary is 319 MB on /. It fits
#                         the 15 GB school quota beside everything else, with
#                         the / margin nearly spent, so below 30 GB it is
#                         asked for (FEATURES="+claude-code"), never assumed
#
# PROFILE=... overrides the size-based pick, FEATURES="+docker -pytools" adds
# or removes single features, and AI_MODE=client|local turns on the two AI
# features that are never chosen automatically.
#
# Then the chosen set is CHECKED against the layout partition_recipe.sh will
# produce for the same SIZE_B2B, mount by mount, with 20% headroom. A feature
# that does not fit fails the ISO build here, naming the mount and the
# smallest SIZE_B2B that would work -- instead of a [SKIP] twenty minutes
# into an install nobody is watching.
#
# The costs are ESTIMATES, taken from the provisioners' own numbers. First
# boot records the measured df delta of every feature to /etc/b2b/features.status
# so the table can be corrected from a real run. Treat a measured number that
# is off by more than a third as a bug in this table.
#
#   feature_profile.sh --resolve    profile + feature list, one per line
#   feature_profile.sh --check      exit 1 with a reason when it does not fit
#   feature_profile.sh --conf       the /etc/b2b/features.conf body
#   feature_profile.sh --table      for humans (make features)
#
# Env
#   SIZE_B2B (15)  DISK_SIZE_MB  VM_RAM_MB (2048)   -- same as partition_recipe.sh
#   PROFILE (auto)  FEATURES ("")  AI_MODE (off)

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
RECIPE="$HERE/partition_recipe.sh"

# name              tier      /     /opt  /var  /home  requires
#
# The / column was calibrated on the first real build (SIZE_B2B=15, standard,
# 2026-09-11): / held 2.7 GB before nvim ran, which is debian-base +
# b2b-mandatory + devtools-apt + webstack packages + docker packages + node,
# to the MB. The first table had no debian-base row at all, and nvim's space
# guard tripped on a disk the check had passed. /etc/b2b/features.status on a
# built guest is where the next correction comes from.
#
# Corrected from /etc/b2b/features.status of the 2026-09-12 build (b2r,
# SIZE_B2B=15, standard, every feature ok), where a measured delta differed
# from the estimate by more than a third:
#   nvim      /     350 -> 382   the nvim section's delta was 474, of which the
#   nvim-extras /     0 -> 92    extras' apt transaction (fzf, bat, lazygit,
#                                gdb, the shell linter, ...) is 92 MB by
#                                /var/log/apt/history.log; the rest is install_nvim.sh's own
#                                apt line -- 230 MB, 377 packages, Debian's npm
#                                tree -- plus its non-apt installs. Node is paid
#                                here, by the first section that needs it;
#   nodejs    /     250 -> 17    ...which leaves the nodejs section only the
#                                globals (eslint & co.). The trio's total on /
#                                went from 600 estimated to 491 measured.
#   webstack  /var  200 -> 118   MariaDB + WordPress + PHP at install time; the
#                                database grows with use.
#   hellish   /home  40 -> 1     the binary lives on /, ~/.hellish is tiny.
# docker's /var figure stays 3300: it is the build PEAK (2.35 GB of build
# cache measured on the host), not the 178 MB the engine alone costs.
#
# 2026-09-12, second pass (opencode replaces Claude Code, Excalidraw joins the
# extras, plugins installed at build time):
#   devtools-apt  /   450 -> 279   the apt transaction, by history.log
#   devtools-extra /    0 -> 200   herdr 24 MB + opencode 176 MB, both in
#                 /opt 110 -> 0    /usr/local/bin (install_devtools.sh). Claude
#                                  Code's 414 MB were on / too, uncounted: the
#                                  npm prefix never moved to /opt.
#   nvim-extras   /opt  0 -> 30    the bundled Excalidraw editor
#   nvim, nvim-extras /home 300, 400: the plugin sets, 57 plugins + parsers +
#                                  Mason, measured 321 MB in all on the
#                                  2026-09-12 guest once installed by hand;
#                                  the build now installs them, and its
#                                  features.status is where these get
#                                  corrected next.
#
# 2026-09-12, third pass -- the /home column, from a guest whose /home was
# 100% FULL (974 MB, 0 available) with every feature reporting ok. `du` on the
# real thing says the editor was never the problem; what the column was
# missing was everything ELSE that lives in the user's home:
#   nvim        /home  300 -> 200   .local/share/nvim with 57 plugins, its
#   nvim-extras /home  400 -> 150   parsers and Mason: 201 MB measured, not
#                                   the 700 estimated. The estimate was the
#                                   only /home entry, and it was too big.
#   npm-cache   /home    0 -> 55    ~/.npm survives the global prefix moving
#                                   to /opt (install_global_scope.sh): npm
#                                   caches per USER, and the provider install
#                                   runs as the user.
#   vscode-remote /home  0 -> 500   .vscode-server, 483 MB measured. Not
#                                   installed by the build -- it arrives the
#                                   first time anyone connects the way the
#                                   README tells them to, so the space is
#                                   claimed whether or not the ISO put it
#                                   there. A model that ignores it says "fits"
#                                   about a disk that does not. Tier
#                                   `standard`, not base: 483 MB cannot be
#                                   reserved inside a minimal build's 512 MB
#                                   /home, and raising that floor would push
#                                   MIN_DISK past 8192 and lose the 8 GB
#                                   minimum. A minimal guest is edited over
#                                   plain ssh; from 15 GB up the VS Code
#                                   workflow is budgeted for.
#   inception-data /home 0 -> 200   MariaDB + WordPress, 197 MB measured.
#                                   Inception's compose file bind-mounts
#                                   /home/<login>/data, so `make inception`
#                                   (and `make fresh`) spend /home, not /var.
# Total /home cost 911 -> checked against a volume that went 1075 -> 1639 MB
# in the same pass (generate/partition_recipe.sh, home's weight 9 -> 18).
#
# 2026-09-12, fourth pass -- kulala-core, which was in no column at all.
#   nvim-extras   /opt   30 -> 135   kulala.nvim downloads a 103 MB executable
#                                    (kulala-core 0.37.0, measured) the first
#                                    time you use it, into ~/.local/share/nvim.
#                                    Per user, on /home, unbudgeted -- on the
#                                    build whose /home came up 100% full. It is
#                                    now fetched once into /opt/kulala/bin by
#                                    install_nvim_extras.sh and pointed at by
#                                    kulala_core.path, so it is one copy on the
#                                    volume that exists for exactly this, and
#                                    the /home column is honest again.
#
# 2026-09-12, fifth pass -- Claude Code returns, beside opencode rather than
# instead of it (setup/install/ai/install_claude_code.sh explains why both).
#   claude-code   /     320   the self-contained binary, 334645552 bytes in the
#                             2.1.236 release manifest, in /usr/local/bin. Not
#                             the 414 MB the npm package cost on the
#                             2026-09-12 build, and no node under it.
# It went into the `full` tier because at SIZE_B2B=15 the standard set left
# 289 MB on / by these costs, and 320 does not go into 289. The sixth pass
# below showed two of those costs were 220 MB too high: it fits at 15 now, by
# 144 MB since the seventh pass. It stays in `full` anyway, since those 144 MB
# are all the margin the model has left on /, and a default build keeps them.
#
# 2026-09-13, sixth pass -- the / column against a guest with EVERY standard
# feature plus claude-code installed and verified (debian, SIZE_B2B=16). df
# said / held 2670 MB; the table said 3290, and refused that same set at
# 15 GB for want of 31 MB. Rows first boot does not measure on / were summed
# from /var/log/apt/history.log, each transaction's packages priced at their
# dpkg Installed-Size. (history.log writes `name:amd64` even for
# Architecture: all packages; strip the suffix or npm's 350-package
# transaction prices at 19 MB instead of 111.) The method reproduces
# devtools-apt's 279 exactly. Rows off by more than a third:
#   b2b-mandatory  /  100 -> 8     sudo ufw openssh-server libpam-pwquality
#                                  apparmor cron haveged: 16 packages, most
#                                  already pulled in by d-i's pkgsel.
#   webstack       /  400 -> 272   lighttpd + MariaDB + PHP, 70 packages,
#                                  266 MB; plus wp-cli, 6 MB in /usr/local/bin.
# Within a third, left alone: docker / 400 (339 measured), nvim / 382 (352),
# debian-base 1100 (~870: 676 MB of packages from d-i, 483 of them in
# history.log and ~190 from debootstrap, which history.log never sees, plus
# ~190 of generated files). The table now says 3070 for that set against the
# 2670 measured, and 3259 usable at 15 GB.
#
# 2026-09-13, seventh pass -- nvim-extras draws mermaid in the buffer:
#   nvim-extras    /   92 -> 137   123 MB measured by the 15 GB rebuild's
#                                  features.status (more than a third over
#                                  92), plus the 13.5 MB mermaid-ascii binary
#                                  in /usr/local/bin. That set now needs 3115 of
#                                  the 3259 usable at 15 GB: 144 MB to spare.
MANIFEST='
debian-base        base      1100  0     0     0      -
b2b-mandatory      base      8     0     0     0      -
devtools-apt       base      279   0     0     0      -
nvim               base      382   120   0     200    devtools-apt
npm-cache          base      0     0     0     55     nvim
vscode-remote      standard  0     0     0     500    -
hellish-upstream   base      0     0     0     1      -
webstack           standard  272   0     118   0      -
nodejs             standard  17    60    0     0      -
pytools            standard  0     80    0     0      -
nvim-extras        standard  137   135   0     150    nvim
devtools-extra     standard  200   0     0     0      nodejs
claude-code        full      320   0     0     0      -
docker             standard  400   0     3300  0      -
inception-data     standard  0     0     0     200    docker
ai-client          explicit  50    0     0     0      -
ai-local           explicit  0     1000  0     0      -
'
# vscode-remote and inception-data are SPACE, not steps: nothing installs them
# at first boot, and first-boot-setup.sh has no section for either. They are in
# the manifest because the fit check is a model of the disk, and a disk the
# documented workflow fills is not a disk that fits. Keeping them out is what
# let a 974 MB /home pass the check and then fill up completely.
NOT_INSTALLED='vscode-remote inception-data npm-cache'
# ai-local's /opt cost is Ollama (~1 GB) plus the model install_ai.sh will pick
# for this much RAM. Its thresholds, mirrored here so the fit check agrees:
ai_model_mb() {
    if [ "$1" -lt 4096 ]; then
        echo 1400 # qwen3:1.7b
    elif [ "$1" -lt 8192 ]; then
        echo 2600 # qwen3:4b
    elif [ "$1" -lt 12288 ]; then
        echo 5000      # qwen3:8b
    else echo 9000; fi # qwen3:14b
}

# The standard set fitted 14 GB under the 2026-09-12 costs, by under 5% on
# every mount and with nvim's /home figure still an estimate. The third pass
# that day settled it the other way: with .vscode-server, Inception's data and
# npm's cache counted, 14 GB refuses and names 15. The automatic threshold was
# already 15, so nothing moves here -- the model just stopped claiming a
# margin it did not have.
STANDARD_FROM_GB=15
FULL_FROM_GB=30
# Usable fraction of a volume: ext4 shows ~93% of the partman figure, and 20%
# of that is kept free so apt lists, logs and a busy Docker do not wedge it.
USABLE_PERMILLE=744

# ── Inputs ──────────────────────────────────────────────────────────────────
MODE="${1:---table}"
VM_RAM_MB="${VM_RAM_MB:-2048}"
[ -n "$VM_RAM_MB" ] || VM_RAM_MB=2048
if [ -n "${DISK_SIZE_MB:-}" ]; then
    DISK_MB="$DISK_SIZE_MB"
else
    DISK_MB=$((${SIZE_B2B:-15} * 1024))
fi
SIZE_GB=$((DISK_MB / 1024))
PROFILE="${PROFILE:-auto}"
FEATURES="${FEATURES:-}"
AI_MODE="${AI_MODE:-off}"

# A hand-picked set beats the size-based guess. generate/feature_select.sh
# writes .b2b-features when someone ticks boxes before a build; reading it here
# rather than passing it through the Makefile is what makes `make features`,
# the preflight check and the ISO's features.conf agree without anything being
# threaded between them.
#
# Two guards. The environment always wins -- a caller who said FEATURES= or
# PROFILE= has stated a choice and must not be overridden by a stale file. And
# the selection is only valid for the disk it was fitted to: 12 features that
# fit 30 GB are not a set for 15, so a size change ignores the file instead of
# quietly refusing with a list the person never chose for this disk.
SEL_FILE="${B2B_SELECT_FILE:-$HERE/../.b2b-features}"
if [ -z "$FEATURES" ] && [ "$PROFILE" = auto ] && [ -f "$SEL_FILE" ]; then
    sel_size=$(sed -n 's/^B2B_SELECT_SIZE_GB=//p' "$SEL_FILE" | head -n1)
    if [ "${sel_size:-}" = "$SIZE_GB" ]; then
        PROFILE=$(sed -n 's/^B2B_SELECT_PROFILE=//p' "$SEL_FILE" | head -n1)
        FEATURES=$(sed -n 's/^B2B_SELECT_FEATURES=//p' "$SEL_FILE" | head -n1)
        PROFILE="${PROFILE:-auto}"
    fi
fi
case "$AI_MODE" in off | client | local) ;; *)
    echo "feature_profile: AI_MODE must be off, client or local (got '$AI_MODE')" >&2
    exit 1
    ;;
esac

die() {
    printf 'feature_profile: %s\n' "$*" >&2
    exit 1
}

names() { printf '%s\n' "$MANIFEST" | awk 'NF == 7 { print $1 }'; }
field() { printf '%s\n' "$MANIFEST" | awk -v n="$1" -v c="$2" 'NF == 7 && $1 == n { print $c }'; }
known() { names | grep -qx -- "$1"; }
varname() { printf 'B2B_FEATURE_%s' "$(printf '%s' "$1" | tr '-' '_')"; }

# ── 1. Which profile ────────────────────────────────────────────────────────
case "$PROFILE" in
auto)
    if [ "$SIZE_GB" -ge "$FULL_FROM_GB" ]; then
        PROFILE=full
    elif [ "$SIZE_GB" -ge "$STANDARD_FROM_GB" ]; then
        PROFILE=standard
    else PROFILE=minimal; fi
    ;;
minimal | standard | full) ;;
*) die "PROFILE must be auto, minimal, standard or full (got '$PROFILE')" ;;
esac

# A literal newline: $'\n' is not portable to every shell this runs under.
NL='
'
# ── 2. Which features ───────────────────────────────────────────────────────
# State is a space-separated list of "name=on|off", built in manifest order.
STATE=""
for n in $(names); do
    tier=$(field "$n" 2)
    case "$tier" in
    base) on=on ;;
    standard) if [ "$PROFILE" = minimal ]; then on=off; else on=on; fi ;;
    # `full` is a real tier now, not a synonym for standard: a feature here is
    # chosen automatically only on a 30 GB+ disk, and asked for by name below
    # that. Without this arm $on would keep the PREVIOUS feature's value and
    # the row would silently inherit it.
    full) if [ "$PROFILE" = full ]; then on=on; else on=off; fi ;;
    explicit) on=off ;;
    *) die "manifest: '$n' has unknown tier '$tier'" ;;
    esac
    STATE="${STATE}${STATE:+$NL}$n=$on"
done
set_state() { STATE=$(printf '%s\n' "$STATE" | awk -F= -v n="$1" -v v="$2" '$1 == n { $0 = n "=" v } { print }'); }
is_on() { printf '%s\n' "$STATE" | grep -qx -- "$1=on"; }

case "$AI_MODE" in
client) set_state ai-client on ;;
local) set_state ai-local on ;;
esac

# +name / -name overrides. A base feature cannot be removed: that is the
# definition of base, and a VM without sudo or without nvim is not a smaller
# born2root, it is a different project.
for tok in $FEATURES; do
    case "$tok" in
    +*)
        n=${tok#+}
        known "$n" || die "FEATURES: unknown feature '$n' (see --table)"
        set_state "$n" on
        ;;
    -*)
        n=${tok#-}
        known "$n" || die "FEATURES: unknown feature '$n' (see --table)"
        [ "$(field "$n" 2)" = base ] && die "FEATURES: '$n' is a base feature and cannot be turned off"
        set_state "$n" off
        ;;
    *) die "FEATURES entries look like +docker or -pytools (got '$tok')" ;;
    esac
done

# Dependencies are enforced, not silently satisfied. Asking for devtools-extra
# with -nodejs is a contradiction the person should see, not a surprise install
# of node they said they did not want.
for n in $(names); do
    is_on "$n" || continue
    req=$(field "$n" 7)
    [ "$req" = - ] && continue
    is_on "$req" || die "'$n' requires '$req', which is off. Add +$req to FEATURES, or drop $n."
done

# ── 3. Does it fit ──────────────────────────────────────────────────────────
# Costs per mount for the chosen set. ai-local's /opt figure depends on RAM.
cost_of() { # $1 feature  $2 column (3=/ 4=/opt 5=/var 6=/home)
    c=$(field "$1" "$2")
    if [ "$1" = ai-local ] && [ "$2" = 4 ]; then
        c=$((c + $(ai_model_mb "$VM_RAM_MB")))
    fi
    printf '%s' "$c"
}
NEED_ROOT=0
NEED_OPT=0
NEED_VAR=0
NEED_HOME=0
for n in $(names); do
    is_on "$n" || continue
    NEED_ROOT=$((NEED_ROOT + $(cost_of "$n" 3)))
    NEED_OPT=$((NEED_OPT + $(cost_of "$n" 4)))
    NEED_VAR=$((NEED_VAR + $(cost_of "$n" 5)))
    NEED_HOME=$((NEED_HOME + $(cost_of "$n" 6)))
done

# The layout for a given disk, from the one place that decides it.
sizes_for() { DISK_SIZE_MB="$1" VM_RAM_MB="$VM_RAM_MB" "${SCRIPT_SH:-bash}" "$RECIPE" --sizes 2>/dev/null; }
usable() { printf '%s' $(($(printf '%s\n' "$1" | awk -F= -v n="$2" '$1 == n { print $2 }') * USABLE_PERMILLE / 1000)); }

# fits <sizes> -> prints the mounts that overflow, one per line ("/opt 370 428"); empty = fits.
fits() {
    s="$1"
    [ "$NEED_ROOT" -gt "$(usable "$s" root)" ] && printf '/ %s %s\n' "$NEED_ROOT" "$(usable "$s" root)"
    [ "$NEED_OPT" -gt "$(usable "$s" opt)" ] && printf '/opt %s %s\n' "$NEED_OPT" "$(usable "$s" opt)"
    [ "$NEED_VAR" -gt "$(usable "$s" var)" ] && printf '/var %s %s\n' "$NEED_VAR" "$(usable "$s" var)"
    [ "$NEED_HOME" -gt "$(usable "$s" home)" ] && printf '/home %s %s\n' "$NEED_HOME" "$(usable "$s" home)"
    return 0
}

SIZES=$(sizes_for "$DISK_MB") || die "partition_recipe.sh refused ${DISK_MB} MB — see its message above"
[ -n "$SIZES" ] || die "partition_recipe.sh produced no layout for ${DISK_MB} MB (too small? see: make partitions)"
OVERFLOW=$(fits "$SIZES")

# The smallest SIZE_B2B at which this exact feature set fits. Linear search is
# fine: each probe is one cheap script run, and it stops at the first fit.
smallest_fit_gb() {
    g=$((SIZE_GB + 1))
    while [ "$g" -le 2048 ]; do
        s=$(sizes_for $((g * 1024))) && [ -n "$s" ] && [ -z "$(fits "$s")" ] && {
            echo "$g"
            return 0
        }
        g=$((g + 1))
    done
    return 1
}

# ── Output ──────────────────────────────────────────────────────────────────
emit_resolve() {
    printf 'profile=%s\n' "$PROFILE"
    for n in $(names); do
        is_on "$n" && printf 'feature=%s\n' "$n"
    done
    # The loop's status is that of its last `is_on`, which is the always-off
    # ai-local: without this, a correct resolution exited 1.
    return 0
}

emit_conf() {
    printf '# /etc/b2b/features.conf — written into the ISO by generate/create_custom_iso.sh\n'
    printf '# Decided on the host from SIZE_B2B; the guest scripts read it and install\n'
    printf '# exactly this set. See generate/feature_profile.sh.\n'
    printf 'B2B_SIZE_GB=%s\n' "$SIZE_GB"
    printf 'B2B_PROFILE=%s\n' "$PROFILE"
    printf 'B2B_AI_MODE=%s\n' "$AI_MODE"
    for n in $(names); do
        if is_on "$n"; then v=on; else v=off; fi
        printf '%s=%s\n' "$(varname "$n")" "$v"
    done
}

emit_table() {
    printf '\n  Install profile for SIZE_B2B=%s (%s MB): %s%s\n\n' "$SIZE_GB" "$DISK_MB" "$PROFILE" \
        "$([ -n "$FEATURES" ] && printf ' + overrides: %s' "$FEATURES")"
    printf '    %-18s %-9s %-4s %6s %6s %6s %6s   %s\n' feature tier "" / /opt /var /home requires
    for n in $(names); do
        if is_on "$n"; then st=on; else st=off; fi
        # A reservation reads as "on" like everything else, which invites the
        # wrong conclusion that first boot installs it. Mark it instead.
        case " $NOT_INSTALLED " in
        *" $n "*) [ "$st" = on ] && st=rsvd ;;
        esac
        printf '    %-18s %-9s %-4s %6s %6s %6s %6s   %s\n' "$n" "$(field "$n" 2)" "$st" \
            "$(cost_of "$n" 3)" "$(cost_of "$n" 4)" "$(cost_of "$n" 5)" "$(cost_of "$n" 6)" "$(field "$n" 7)"
    done
    printf '    %-18s %-9s %-4s %6s %6s %6s %6s\n' "needed (on)" "" "" "$NEED_ROOT" "$NEED_OPT" "$NEED_VAR" "$NEED_HOME"
    printf '    %-18s %-9s %-4s %6s %6s %6s %6s   %s\n' "usable at this size" "" "" \
        "$(usable "$SIZES" root)" "$(usable "$SIZES" opt)" "$(usable "$SIZES" var)" "$(usable "$SIZES" home)" \
        "(80% of the mounted volume)"
    printf '\n'
    printf '    %s\n\n' "rsvd = space the workflow claims, not a step first boot runs"
    if [ -z "$OVERFLOW" ]; then
        printf '  ✓ fits\n\n'
    else
        printf '  ✗ does not fit:\n'
        printf '%s\n' "$OVERFLOW" | while read -r m need have; do
            printf '      %-6s needs %s MB, has %s MB\n' "$m" "$need" "$have"
        done
        g=$(smallest_fit_gb) && printf '\n    This set fits from SIZE_B2B=%s   (make all SIZE_B2B=%s)\n' "$g" "$g"
        printf '    Or drop a feature: FEATURES="-docker"   Or a smaller profile: PROFILE=minimal\n\n'
    fi
}

case "$MODE" in
--resolve) emit_resolve ;;
--conf) emit_conf ;;
--table)
    emit_table
    [ -z "$OVERFLOW" ]
    ;;
--check)
    if [ -n "$OVERFLOW" ]; then
        emit_table >&2
        die "the '$PROFILE' feature set does not fit a ${SIZE_GB} GB disk. Nothing was built."
    fi
    printf 'profile=%s fits at SIZE_B2B=%s\n' "$PROFILE" "$SIZE_GB"
    ;;
*)
    echo "usage: $0 --resolve | --check | --conf | --table" >&2
    exit 2
    ;;
esac
