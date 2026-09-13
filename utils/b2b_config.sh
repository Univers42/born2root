#!/usr/bin/env hellish
# born2root.conf, read here and nowhere else.
#
# The VM's identity used to be typed by hand into ~40 places: the preseed,
# both guest scripts, eight provisioners, seven host scripts. Three of those
# read the sudo password back OUT of the preseed with awk, one fed the LUKS
# passphrase to sshpass as the account password, and nothing checked that
# vm_pass.txt and the preseed's partman-crypto/passphrase agreed. Now every
# consumer asks this file, and the preseed is a template this file fills in
# (b2b_render) when the ISO is built. Personalising the VM is editing
# born2root.conf; `make config` says whether it is valid before a download.
#
# The file is never sourced: values come out through sed/awk, are trimmed,
# lose one pair of surrounding quotes, and are validated against explicit
# rules that name the fix. A key nobody knows is an error, so a misspelt
# line cannot silently leave a default in place.
#
# Precedence, the same everywhere: VM_PASS in the environment beats
# B2B_LUKS_PASSPHRASE -- for the preseed AND for the host's unlock, so the
# two cannot disagree. The Makefile knobs (SIZE_B2B and friends) read their
# defaults from here, and the command line/environment still win over them.
#
#   . utils/b2b_config.sh                  library: b2b_get KEY, b2b_volumes,
#                                          b2b_luks_passphrase, b2b_render, ...
#   utils/b2b_config.sh get KEY            one resolved value; always exit 0,
#                                          never a word on stderr (the Makefile
#                                          calls it at parse time, `make help`
#                                          included)
#   utils/b2b_config.sh --check            validate; exit 1 naming key and fix
#   utils/b2b_config.sh --show             resolved values, for humans
#   utils/b2b_config.sh --volumes          "name mount floor share cap" lines,
#                                          `/` first, the `rest` volume last
#   utils/b2b_config.sh --guest            /etc/b2b/build.conf body: what the
#                                          guest may know (no password)
#   utils/b2b_config.sh --shadow           "name:$6$..." per extra user
#   utils/b2b_config.sh --render FILE      FILE with every @B2B_KEY@ filled in
#
# Env: B2B_CONFIG (born2root.conf at the repo root) -- the tests point it at
# fixtures; VM_PASS (see above).

B2B_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)
B2B_CONFIG="${B2B_CONFIG:-$B2B_ROOT/born2root.conf}"

# Every scalar key, in the order --show prints them. Missing or unknown is an
# error in --check; `get` of an unknown key is simply empty.
B2B_KEYS="B2B_LOGIN B2B_HOSTNAME B2B_USER_PASSWORD B2B_ROOT_PASSWORD
B2B_LUKS_PASSPHRASE B2B_EXTRA_USERS B2B_LOCALE B2B_KEYMAP B2B_TIMEZONE
B2B_MIRROR B2B_SWAP_MB B2B_SIZE_GB B2B_VM_RAM_MB B2B_VM_NAME B2B_BACKEND
B2B_PROFILE B2B_FEATURES B2B_AI_MODE"

# A literal newline: $'\n' is not portable to every shell this runs under.
_B2B_NL='
'

# ── Reading ─────────────────────────────────────────────────────────────────
# The raw value of KEY: first matching line, CR dropped, whitespace trimmed at
# both ends, one pair of surrounding double quotes removed. Nothing else is
# interpreted: a `#` after the value is part of the value, which is why the
# file keeps comments on their own lines (a passphrase may contain `#`).
b2b_raw() {
    local v
    [ -r "$B2B_CONFIG" ] || return 1
    v=$(sed -n "s/^[[:space:]]*$1[[:space:]]*=//p" "$B2B_CONFIG" | head -n1 | tr -d '\r')
    v=${v#"${v%%[![:space:]]*}"}
    v=${v%"${v##*[![:space:]]}"}
    # Two statements, not `v=${v#\"} v=${v%\"}`: bash assigns those left to
    # right, hellish expands both words first, and the closing quote stayed.
    case "$v" in
    \"*\")
        v=${v#\"}
        v=${v%\"}
        ;;
    esac
    printf '%s' "$v"
}

# The resolved value: raw, plus the defaults that derive from other keys.
b2b_get() {
    local v
    v=$(b2b_raw "$1") || return 1
    case "$1" in
    B2B_HOSTNAME) [ -n "$v" ] || v="$(b2b_raw B2B_LOGIN)42" ;;
    esac
    printf '%s' "$v"
}

# The LUKS passphrase the host types and the preseed sets: VM_PASS wins.
b2b_luks_passphrase() {
    if [ -n "${VM_PASS:-}" ]; then
        printf '%s' "$VM_PASS"
        return 0
    fi
    b2b_get B2B_LUKS_PASSPHRASE
}

b2b_user_password() { b2b_get B2B_USER_PASSWORD; }

# en_US.UTF-8 -> en / US, for d-i's kernel command line.
b2b_locale_language() {
    local l
    l=$(b2b_get B2B_LOCALE)
    printf '%s' "${l%%_*}"
}
b2b_locale_country() {
    local l
    l=$(b2b_get B2B_LOCALE)
    l=${l#*_}
    printf '%s' "${l%%.*}"
}

# The volume table, normalised: the `/` volume first, the `rest` volume
# last, the others in file order -- the order the recipe is emitted in.
# Refuses an invalid table the way --check would, so partition_recipe.sh
# never sizes a layout the installer could not create.
b2b_volumes() {
    (
        B2B_ERRORS=""
        _b2b_check_volumes
        if [ -n "$B2B_ERRORS" ]; then
            printf '%s\n' "$B2B_ERRORS" >&2
            exit 1
        fi
        awk '$1 == "B2B_VOLUME" && NF == 6 {
            row = $2 " " $3 " " $4 " " $5 " " $6
            if ($3 == "/") root = row
            else if ($5 == "rest") rest = row
            else others = others row "\n"
        }
        END { print root; printf "%s", others; print rest }' "$B2B_CONFIG" | tr -d '\r'
    )
}

# Extra users as the guest sees them: "name:groups" per line, groups being
# user42 or user42,sudo. Passwords never leave the host in clear (b2b_shadow).
b2b_extra_users() {
    local e name rest flag groups
    for e in $(b2b_get B2B_EXTRA_USERS); do
        name=${e%%:*}
        rest=${e#*:}
        flag=${rest#*:}
        [ "$flag" = "$rest" ] && flag=""
        groups=user42
        [ "$flag" = sudo ] && groups=user42,sudo
        printf '%s:%s\n' "$name" "$groups"
    done
}

# ── Validation ──────────────────────────────────────────────────────────────
B2B_ERRORS=""
_b2b_err() { B2B_ERRORS="${B2B_ERRORS}${B2B_ERRORS:+$_B2B_NL}$1"; }
_b2b_warn() { printf 'warning: %s\n' "$1" >&2; }
# _b2b_is VALUE ERE: does the whole value match? grep rather than [[ =~ ]],
# the repo's convention (see b2b-setup.sh's shell-dest check).
_b2b_is() { printf '%s' "$1" | grep -Eq -- "$2"; }
_b2b_int() { _b2b_is "$1" '^[0-9]+$'; }

_b2b_check_volumes() {
    local n=0 rest=0 roots=0 sum=0 names=" " mounts=" "
    local nf name mount floor share cap
    while read -r nf name mount floor share cap; do
        [ -n "$nf" ] || continue
        n=$((n + 1))
        if [ "$nf" != 6 ]; then
            _b2b_err "B2B_VOLUME line $n: exactly 5 fields (name mount floor share cap), got $((nf - 1))"
            continue
        fi
        if ! _b2b_is "$name" '^[a-z][a-z0-9-]*$' || [ "$name" = swap ]; then
            _b2b_err "B2B_VOLUME $name: a volume name is lowercase letters, digits and -, and not 'swap'"
        fi
        case "$names" in
        *" $name "*) _b2b_err "B2B_VOLUME $name: this name is used twice" ;;
        esac
        names="$names$name "
        if [ "$mount" != / ] && ! _b2b_is "$mount" '^(/[a-z0-9_.-]+)+$'; then
            _b2b_err "B2B_VOLUME $name: mount '$mount' is not an absolute path of lowercase letters, digits, _ . -"
        fi
        [ "$mount" = /boot ] && _b2b_err "B2B_VOLUME $name: /boot is a fixed primary partition, not a volume"
        case "$mounts" in
        *" $mount "*) _b2b_err "B2B_VOLUME $name: mount '$mount' is used twice" ;;
        esac
        mounts="$mounts$mount "
        [ "$mount" = / ] && roots=$((roots + 1))
        if ! _b2b_int "$floor" || [ "$floor" -lt 128 ]; then
            _b2b_err "B2B_VOLUME $name: floor '$floor' must be a whole number of MB, 128 or more"
        fi
        if [ "$share" = rest ]; then
            rest=$((rest + 1))
        elif _b2b_int "$share" && [ "$share" -le 100 ]; then
            sum=$((sum + share))
        else
            _b2b_err "B2B_VOLUME $name: share '$share' must be 0-100 (a percent) or 'rest'"
        fi
        if [ "$cap" != - ]; then
            if ! _b2b_int "$cap" || { _b2b_int "$floor" && [ "$cap" -lt "$floor" ]; }; then
                _b2b_err "B2B_VOLUME $name: cap '$cap' must be '-' or a whole number of MB not below the floor"
            fi
        fi
    done <<EOF
$(awk '$1 == "B2B_VOLUME" { print NF, $2, $3, $4, $5, $6 }' "$B2B_CONFIG" 2>/dev/null | tr -d '\r')
EOF
    [ "$n" -gt 0 ] || _b2b_err "no B2B_VOLUME lines: the disk needs at least a / volume"
    [ "$roots" = 1 ] || [ "$n" = 0 ] || _b2b_err "B2B_VOLUME: exactly one volume must be mounted on / (found $roots)"
    [ "$rest" = 1 ] || [ "$n" = 0 ] || _b2b_err "B2B_VOLUME: exactly one volume takes the remainder (share 'rest'); found $rest"
    [ "$sum" -le 100 ] || _b2b_err "B2B_VOLUME: the shares add up to $sum %, more than 100"
}

# Which line is which: unknown keys, keys set twice, lines that are neither
# KEY=value nor a B2B_VOLUME row, and keys that are missing altogether.
_b2b_check_syntax() {
    local k out
    out=$(awk -v keys=" $(printf '%s' "$B2B_KEYS" | tr '\n' ' ') " '
        /^[[:space:]]*(#|$)/ { next }
        $1 == "B2B_VOLUME" { next }
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (match(line, /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/)) {
                k = substr(line, 1, RLENGTH - 1)
                sub(/[[:space:]]+$/, "", k)
                if (index(keys, " " k " ") == 0) printf "line %d: unknown key %s\n", NR, k
                else if (seen[k]++) printf "line %d: %s is set twice (the first one wins)\n", NR, k
                next
            }
            printf "line %d: not a KEY=value line or a B2B_VOLUME row: %s\n", NR, $0
        }' "$B2B_CONFIG" | tr -d '\r')
    [ -z "$out" ] || _b2b_err "$out"
    for k in $B2B_KEYS; do
        grep -Eq "^[[:space:]]*${k}[[:space:]]*=" "$B2B_CONFIG" ||
            _b2b_err "$k is missing: add a '$k=' line (an empty value is fine where the comment says so)"
    done
}

# The whole file. Every complaint names the key and what would satisfy it;
# they are all printed, not just the first, so one round of edits fixes all.
b2b_check() {
    local v login pass e name rest flag pw seen=" " tok
    B2B_ERRORS=""
    if [ ! -r "$B2B_CONFIG" ]; then
        printf '%s is missing or unreadable. Restore it: git checkout born2root.conf\n' "$B2B_CONFIG" >&2
        return 1
    fi
    _b2b_check_syntax

    login=$(b2b_get B2B_LOGIN)
    if [ "$login" = root ] || ! _b2b_is "$login" '^[a-z_][a-z0-9_-]{0,31}$'; then
        _b2b_err "B2B_LOGIN='$login': a login is lowercase letters, digits, _ and - (32 at most), and not root"
    fi
    v=$(b2b_get B2B_HOSTNAME)
    if ! _b2b_is "$v" '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'; then
        _b2b_err "B2B_HOSTNAME='$v': a host name is lowercase letters, digits and - (63 at most)"
    elif [ "$v" != "${login}42" ]; then
        _b2b_warn "B2B_HOSTNAME=$v -- the subject wants ${login}42 (leave B2B_HOSTNAME empty for that)"
    fi
    for v in B2B_USER_PASSWORD B2B_ROOT_PASSWORD; do
        [ -n "$(b2b_get "$v")" ] || _b2b_err "$v is empty"
    done
    pass=$(b2b_luks_passphrase)
    if ! _b2b_is "$pass" '^[A-Za-z0-9._,/=+!@#$%&*?:;-]{8,}$'; then
        _b2b_err "$([ -n "${VM_PASS:-}" ] && echo VM_PASS || echo B2B_LUKS_PASSPHRASE): 8+ characters from letters, digits and - _ . , / = + ! @ # \$ % & * ? : ; -- it is typed key by key into the guest"
    fi
    for e in $(b2b_get B2B_EXTRA_USERS); do
        name=${e%%:*}
        rest=${e#*:}
        if [ "$rest" = "$e" ]; then
            _b2b_err "B2B_EXTRA_USERS '$e': entries look like name:password or name:password:sudo"
            continue
        fi
        pw=${rest%%:*}
        flag=${rest#*:}
        [ "$flag" = "$rest" ] && flag=""
        if [ "$name" = root ] || [ "$name" = "$login" ] || ! _b2b_is "$name" '^[a-z_][a-z0-9_-]{0,31}$'; then
            _b2b_err "B2B_EXTRA_USERS '$name': a login is lowercase letters, digits, _ and -, and neither root nor B2B_LOGIN"
        fi
        case "$seen" in
        *" $name "*) _b2b_err "B2B_EXTRA_USERS '$name' is listed twice" ;;
        esac
        seen="$seen$name "
        [ -n "$pw" ] || _b2b_err "B2B_EXTRA_USERS '$name': the password is empty"
        case "$flag" in
        '' | sudo) ;;
        *) _b2b_err "B2B_EXTRA_USERS '$e': after the password only ':sudo' is understood (got ':$flag')" ;;
        esac
    done

    v=$(b2b_get B2B_LOCALE)
    _b2b_is "$v" '^[a-z]{2,3}_[A-Z]{2}(\.[A-Za-z0-9-]+)?$' ||
        _b2b_err "B2B_LOCALE='$v': something like en_US.UTF-8"
    v=$(b2b_get B2B_KEYMAP)
    _b2b_is "$v" '^[a-z][a-z0-9-]*$' || _b2b_err "B2B_KEYMAP='$v': a d-i keymap name such as es, us, fr, de"
    v=$(b2b_get B2B_TIMEZONE)
    if [ -d /usr/share/zoneinfo ]; then
        if [ ! -f "/usr/share/zoneinfo/$v" ] || ! _b2b_is "$v" '^[A-Za-z]'; then
            _b2b_err "B2B_TIMEZONE='$v': not in /usr/share/zoneinfo (Area/City, e.g. Europe/Madrid)"
        fi
    else
        _b2b_is "$v" '^[A-Za-z_]+(/[A-Za-z0-9_+-]+)*$' || _b2b_err "B2B_TIMEZONE='$v': Area/City, e.g. Europe/Madrid"
    fi
    v=$(b2b_get B2B_MIRROR)
    _b2b_is "$v" '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$' || _b2b_err "B2B_MIRROR='$v': a host name only, such as deb.debian.org"

    _b2b_check_volumes
    v=$(b2b_get B2B_SWAP_MB)
    if [ "$v" != auto ] && { ! _b2b_int "$v" || [ "$v" -lt 256 ]; }; then
        _b2b_err "B2B_SWAP_MB='$v': auto, or a whole number of MB (256 or more)"
    fi

    v=$(b2b_get B2B_SIZE_GB)
    if ! _b2b_int "$v" || [ "$v" -lt 8 ]; then
        _b2b_err "B2B_SIZE_GB='$v': a whole number of GB, 8 or more (15 is the school quota)"
    fi
    v=$(b2b_get B2B_VM_RAM_MB)
    if [ -n "$v" ] && { ! _b2b_int "$v" || [ "$v" -lt 512 ]; }; then
        _b2b_err "B2B_VM_RAM_MB='$v': empty (auto) or a whole number of MB, 512 or more"
    fi
    v=$(b2b_get B2B_VM_NAME)
    _b2b_is "$v" '^[A-Za-z0-9][A-Za-z0-9_.-]*$' || _b2b_err "B2B_VM_NAME='$v': letters, digits, _ . -"
    v=$(b2b_get B2B_BACKEND)
    case "$v" in
    auto | virtualbox | qemu) ;;
    *) _b2b_err "B2B_BACKEND='$v': auto, virtualbox or qemu" ;;
    esac
    v=$(b2b_get B2B_PROFILE)
    case "$v" in
    auto | minimal | standard | full) ;;
    *) _b2b_err "B2B_PROFILE='$v': auto, minimal, standard or full" ;;
    esac
    for tok in $(b2b_get B2B_FEATURES); do
        _b2b_is "$tok" '^[+-][a-z][a-z0-9-]*$' ||
            _b2b_err "B2B_FEATURES '$tok': entries look like +docker or -pytools"
    done
    v=$(b2b_get B2B_AI_MODE)
    case "$v" in
    off | client | local) ;;
    *) _b2b_err "B2B_AI_MODE='$v': off, client or local" ;;
    esac

    if [ -n "$B2B_ERRORS" ]; then
        printf '%s\n' "$B2B_ERRORS" | sed "s|^|$B2B_CONFIG: |" >&2
        printf '%s problem(s) in born2root.conf -- fix them, then: make config\n' \
            "$(printf '%s\n' "$B2B_ERRORS" | wc -l)" >&2
        return 1
    fi
    printf '✓ %s is valid\n' "$B2B_CONFIG"
}

# ── Output ──────────────────────────────────────────────────────────────────
b2b_show() {
    local k v
    printf '\n  %s\n\n' "$B2B_CONFIG"
    for k in $B2B_KEYS; do
        v=$(b2b_get "$k")
        case "$k" in
        B2B_HOSTNAME) [ -n "$(b2b_raw "$k")" ] || v="$v   (from B2B_LOGIN)" ;;
        B2B_LUKS_PASSPHRASE) [ -z "${VM_PASS:-}" ] || v="$(b2b_luks_passphrase)   (VM_PASS, overriding the file)" ;;
        esac
        printf '    %-22s %s\n' "$k" "$v"
    done
    printf '\n    %-9s %-10s %6s %5s %7s\n' volume mount floor share cap
    b2b_volumes 2>/dev/null | while read -r name mount floor share cap; do
        printf '    %-9s %-10s %6s %5s %7s\n' "$name" "$mount" "$floor" "$share" "$cap"
    done
    printf '\n'
}

# What the guest is told about itself. KEY=value only, source-able like
# /etc/b2b/features.conf; lists quoted, single tokens bare. No password.
b2b_guest() {
    local users vols
    users=$(b2b_extra_users | tr '\n' ' ')
    vols=$(b2b_volumes | awk '{ printf "%s%s:%s", (NR > 1 ? " " : ""), $1, $2 }') || return 1
    printf '# /etc/b2b/build.conf -- what this VM was built with, from born2root.conf\n'
    printf '# on the host (utils/b2b_config.sh --guest). No password is recorded here.\n'
    printf 'B2B_LOGIN=%s\n' "$(b2b_get B2B_LOGIN)"
    printf 'B2B_HOSTNAME=%s\n' "$(b2b_get B2B_HOSTNAME)"
    printf 'B2B_MIRROR=%s\n' "$(b2b_get B2B_MIRROR)"
    printf 'B2B_TIMEZONE=%s\n' "$(b2b_get B2B_TIMEZONE)"
    printf 'B2B_LOCALE=%s\n' "$(b2b_get B2B_LOCALE)"
    printf 'B2B_KEYMAP=%s\n' "$(b2b_get B2B_KEYMAP)"
    printf 'B2B_EXTRA_USERS="%s"\n' "${users% }"
    printf 'B2B_VOLUMES="%s"\n' "$vols"
}

# SHA-512 crypt, the form /etc/shadow and d-i's passwd/*-password-crypted
# take. Through stdin, so the password is not on any process's command line.
b2b_hash() {
    command -v openssl >/dev/null 2>&1 || {
        echo "b2b_config: openssl is needed to hash the passwords (make deps installs it)" >&2
        return 1
    }
    printf '%s\n' "$1" | openssl passwd -6 -stdin
}

# "name:hash" per extra user, for b2b-setup.sh's useradd -p.
b2b_shadow() {
    local e name rest pw
    for e in $(b2b_get B2B_EXTRA_USERS); do
        name=${e%%:*}
        rest=${e#*:}
        pw=${rest%%:*}
        printf '%s:%s\n' "$name" "$(b2b_hash "$pw")" || return 1
    done
}

# Fill @B2B_KEY@ placeholders in a template. Values travel to awk through the
# environment, not -v (gawk rewrites backslash escapes in -v strings, and a
# crypt hash or a password may hold any of $ & \ /), and are spliced with
# index()/substr(): no regex, no gsub, so nothing in a value is special and
# the template's own `$(list-devices …)` and `$lvmok{ }` are never touched.
# One left-to-right pass, so a value containing "@B2B_" is not re-scanned.
# A placeholder no key answers is an error: the alternative is d-i asking a
# question on a screen nobody watches.
b2b_render() {
    local tpl="$1" out rc
    [ -r "$tpl" ] || {
        echo "b2b_config: template not found: $tpl" >&2
        return 1
    }
    command -v openssl >/dev/null 2>&1 || {
        echo "b2b_config: openssl is needed to hash the passwords (make deps installs it)" >&2
        return 1
    }
    out=$(mktemp)
    # A subshell: the exports carry the passwords and must not outlive this.
    (
        for k in $B2B_KEYS; do
            v=$(b2b_get "$k")
            export "B2B_R_${k#B2B_}=$v"
        done
        v=$(b2b_luks_passphrase)
        case "$v" in
        *"$_B2B_NL"*)
            echo "b2b_config: VM_PASS contains a newline" >&2
            exit 1
            ;;
        esac
        export "B2B_R_LUKS_PASSPHRASE=$v"
        v=$(b2b_hash "$(b2b_get B2B_ROOT_PASSWORD)") || exit 1
        export "B2B_R_ROOT_PASSWORD_HASH=$v"
        v=$(b2b_hash "$(b2b_get B2B_USER_PASSWORD)") || exit 1
        export "B2B_R_USER_PASSWORD_HASH=$v"
        awk '
        BEGIN {
            for (e in ENVIRON)
                if (substr(e, 1, 6) == "B2B_R_") key["@B2B_" substr(e, 7) "@"] = ENVIRON[e]
        }
        {
            line = $0
            # `out = ""; while` on one line: bashate does not see the quotes
            # around this program and reads a bare awk `while` as shell (E010).
            out = ""; while ((i = index(line, "@B2B_")) > 0) {
                j = index(substr(line, i + 1), "@")
                if (j == 0) break
                tok = substr(line, i, j + 1)
                if (tok in key) {
                    out = out substr(line, 1, i - 1) key[tok]
                    line = substr(line, i + j + 1)
                } else {
                    out = out substr(line, 1, i)
                    line = substr(line, i + 1)
                }
            }
            print out line
        }' "$tpl"
    ) >"$out"
    rc=$?
    if [ "$rc" != 0 ]; then
        rm -f "$out"
        return "$rc"
    fi
    if grep -nE '@B2B_[A-Z0-9_]+@' "$out" >&2; then
        echo "b2b_config: the placeholder(s) above have no value in born2root.conf -- nothing rendered" >&2
        rm -f "$out"
        return 1
    fi
    cat "$out"
    rm -f "$out"
}

_b2b_usage() {
    cat >&2 <<EOF
usage: $0 get KEY | --check | --show | --volumes | --guest | --shadow | --render FILE
       (env: B2B_CONFIG=path/to/born2root.conf, VM_PASS)
EOF
}

# Run as a command? Dispatch. When sourced, \$1 is the CALLER's first argument
# (hellish and bash agree on that), so the guard is the file name, not \$1.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    case "${1:-}" in
    get)
        b2b_get "${2:-}" 2>/dev/null || true
        exit 0
        ;;
    --check) b2b_check ;;
    --show) b2b_show ;;
    --volumes) b2b_volumes ;;
    --guest) b2b_guest ;;
    --shadow) b2b_shadow ;;
    --render) b2b_render "${2:-}" ;;
    *)
        _b2b_usage
        exit 2
        ;;
    esac
fi
