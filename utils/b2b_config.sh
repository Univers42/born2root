#!/usr/bin/env hellish
# born2root.toml, as the shell sees it.
#
# The reading, the defaults and the validation all live in b2b_config.py next
# to this file (the config is TOML, and a shell cannot parse nested tables and
# arrays of tables without becoming a parser). This file is the face the rest
# of the repo already calls: b2b_get, b2b_volumes, b2b_luks_passphrase,
# b2b_render and friends keep their names and their contracts, so no host
# script, guest script or test had to learn Python.
#
# Two rules every function below obeys:
#
#   * the environment is handed over with `env`, never with a bare assignment.
#     `VAR=x some_function` sets a shell variable for the call but does NOT
#     export VAR to what the function runs, under hellish -- measured; the
#     tests rely on `B2B_CONFIG=... ; . b2b_config.sh ; VM_PASS=... b2b_...`
#     working, so the value has to be passed explicitly at the python call.
#   * b2b_get never fails and never writes to stderr. The Makefile calls it at
#     parse time for every target, `make help` included.
#
#   . utils/b2b_config.sh                  library: b2b_get KEY, b2b_volumes,
#                                          b2b_luks_passphrase, b2b_render, ...
#   utils/b2b_config.sh get KEY            one resolved value; always exit 0.
#                                          KEY is a B2B_* name or a dotted
#                                          path (vm.name, users.bob.sudo)
#   utils/b2b_config.sh --check            validate; exit 1 naming every fix
#   utils/b2b_config.sh --parses           exit 1 if the TOML is unreadable
#   utils/b2b_config.sh --show             resolved values, for humans
#   utils/b2b_config.sh --dump             resolved values as JSON
#   utils/b2b_config.sh --volumes          "name mount floor share cap" lines,
#                                          `/` first, the `rest` volume last
#   utils/b2b_config.sh --guest            /etc/b2b/build.conf body: what the
#                                          guest may know (no password)
#   utils/b2b_config.sh --shadow           "name:$6$..." per extra account
#   utils/b2b_config.sh --ssh-keys         "name key..." lines
#   utils/b2b_config.sh --render FILE      FILE with every @B2B_KEY@ filled in
#
# Env: B2B_CONFIG (born2root.toml at the repo root) -- the tests point it at
# fixtures; VM_PASS (beats system.luks_passphrase, for the preseed and for the
# host's unlock alike, so the two cannot disagree).

B2B_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)
B2B_CONFIG="${B2B_CONFIG:-$B2B_ROOT/born2root.toml}"
B2B_PY="$B2B_ROOT/utils/b2b_config.py"

# Every call goes through here, so B2B_CONFIG and VM_PASS are exported exactly
# once and in one way. ${VM_PASS-} keeps an unset VM_PASS unset rather than
# turning it into an empty override.
_b2b_py() {
    if [ -n "${VM_PASS-}" ]; then
        env B2B_CONFIG="$B2B_CONFIG" VM_PASS="$VM_PASS" python3 "$B2B_PY" "$@"
    else
        env B2B_CONFIG="$B2B_CONFIG" python3 "$B2B_PY" "$@"
    fi
}

# ── Reading ─────────────────────────────────────────────────────────────────
# One resolved value. Silent and always successful, whatever the file holds:
# an invalid file still answers `make status`, and `--check` is what judges it.
b2b_get() { _b2b_py get "$1" 2>/dev/null || true; }

# The passphrase this machine types at every boot: VM_PASS first.
b2b_luks_passphrase() { b2b_get B2B_LUKS_PASSPHRASE; }
b2b_user_password() { b2b_get B2B_USER_PASSWORD; }
b2b_root_password() { b2b_get B2B_ROOT_PASSWORD; }

# en_US.UTF-8 -> en / US, for d-i's kernel command line.
b2b_locale_language() { b2b_get B2B_LOCALE_LANGUAGE; }
b2b_locale_country() { b2b_get B2B_LOCALE_COUNTRY; }

# The volume table, normalised: the `/` volume first, the `rest` volume last,
# the others in file order -- the order the recipe is emitted in. Refuses an
# invalid table the way --check would, so partition_recipe.sh never sizes a
# layout the installer could not create.
b2b_volumes() { _b2b_py --volumes; }

# Extra accounts as the guest sees them: "name:groups" per line.
b2b_extra_users() { b2b_get B2B_EXTRA_USERS | tr ' ' '\n' | grep -v '^$' || true; }

# Does the file parse at all? A TOML typo makes every value unreadable, and
# `get` then answers empty -- fine for a banner, not for `make destroy`, which
# would fall back to the literal VM name and target the wrong machine.
b2b_parses() { _b2b_py --parses; }

# ── Validation and output ───────────────────────────────────────────────────
b2b_check() { _b2b_py --check; }
b2b_show() { _b2b_py --show; }
b2b_dump() { _b2b_py --dump; }
b2b_guest() { _b2b_py --guest; }
b2b_shadow() { _b2b_py --shadow; }
b2b_ssh_keys() { _b2b_py --ssh-keys; }
b2b_render() { _b2b_py --render "$1"; }

_b2b_usage() {
    cat >&2 <<EOF
usage: $0 get KEY | --check | --parses | --show | --dump | --volumes
       | --guest | --shadow | --ssh-keys | --render FILE
       (env: B2B_CONFIG=path/to/born2root.toml, VM_PASS)
EOF
}

# Run as a command? Dispatch. When sourced, \$1 is the CALLER's first argument
# (hellish and bash agree on that), so the guard is the file name, not \$1.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    case "${1:-}" in
    get)
        b2b_get "${2:-}"
        exit 0
        ;;
    --check) b2b_check ;;
    --parses) b2b_parses ;;
    --show) b2b_show ;;
    --dump) b2b_dump ;;
    --volumes) b2b_volumes ;;
    --guest) b2b_guest ;;
    --shadow) b2b_shadow ;;
    --ssh-keys) b2b_ssh_keys ;;
    --render) b2b_render "${2:-}" ;;
    *)
        _b2b_usage
        exit 2
        ;;
    esac
fi
