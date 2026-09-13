#!/usr/bin/env hellish
# Regression test for utils/b2b_config.{sh,py} and born2root.toml.
#
# What it pins:
#   1. `get` answers every key the rest of the repo asks for, from a file the
#      validator would refuse as well, and stays silent: the Makefile calls it
#      at parse time for every target, `make help` included.
#   2. Every rule --check enforces, one fixture each, each naming its key. A
#      build that would fail 20 minutes in has to fail here in milliseconds.
#   3. VM_PASS beats the file everywhere, including as a bare prefix on a
#      sourced function -- hellish does not export those to children, which is
#      how a preseed and an unlock once disagreed.
#   4. --render splices values, never patterns: a crypt hash full of $ and /,
#      a passphrase with & \ and /, and the template's own $(list-devices ...)
#      all come out verbatim, and a placeholder nothing answers is an error.
#   5. Nothing in the code carries the owner's login or a temporary password:
#      those live in born2root.toml and nowhere else.
#   6. The vendored TOML parser is exercised even where Python has tomllib.
#
# shellcheck disable=SC2016 # crypt hashes, $ in messages: literal here
set -e

cd "$(dirname "$0")/.."

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-62s = %s\n' "$1" "$2"
    else
        printf 'FAIL %-62s = %s (expected %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}
contains() { # <label> <haystack> <needle>
    case "$2" in
    *"$3"*) printf 'ok   %-62s\n' "$1" ;;
    *)
        printf 'FAIL %-62s: %s does not hold %s\n' "$1" "$2" "$3"
        fail=1
        ;;
    esac
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
DEFAULTS=tests/fixtures/default.toml
CFG=("${SCRIPT_SH:-bash}" utils/b2b_config.sh)

# A copy of the shipped defaults with sed edits applied. The volume table is
# one inline table per line, so a volume is edited or dropped by its name.
variant() { # <name> <sed expression>... -> path
    local name="$1" out args
    shift
    out="$TMP/$name.toml"
    args=()
    for expr in "$@"; do
        args+=(-e "$expr")
    done
    sed "${args[@]}" "$DEFAULTS" >"$out"
    printf '%s' "$out"
}
append() { # <name> <text> -> path  (a section the defaults do not have)
    local out="$TMP/$1.toml"
    cp "$DEFAULTS" "$out"
    printf '%s\n' "$2" >>"$out"
    printf '%s' "$out"
}
get_of() { env B2B_CONFIG="$1" "${CFG[@]}" get "$2"; }
rc_of() { # <config> <mode...> -> exit code, output in $TMP/out
    local cfg="$1"
    shift
    env B2B_CONFIG="$cfg" "${CFG[@]}" "$@" >"$TMP/out" 2>&1 && echo 0 || echo 1
}
# The message a refusal prints, for asserting it names the right key.
refuse() { # <label> <key it must name> <sed expression>...
    local label="$1" key="$2" cfg
    shift 2
    cfg=$(variant "refuse$$" "$@")
    if [ "$(rc_of "$cfg" --check)" != 1 ]; then
        printf 'FAIL %-62s: accepted\n' "$label"
        fail=1
        return
    fi
    contains "$label" "$(cat "$TMP/out")" "$key"
}
refuse_add() { # <label> <key it must name> <appended text>
    local cfg
    cfg=$(append "add$$" "$3")
    if [ "$(rc_of "$cfg" --check)" != 1 ]; then
        printf 'FAIL %-62s: accepted\n' "$1"
        fail=1
        return
    fi
    contains "$1" "$(cat "$TMP/out")" "$2"
}

# ── The shipped file and the fixture ────────────────────────────────────────
check "born2root.toml is valid" "$(rc_of born2root.toml --check)" 0
check "the fixture is valid" "$(rc_of "$DEFAULTS" --check)" 0
check "the fixture resolves exactly like the shipped file" \
    "$(diff <(env B2B_CONFIG=born2root.toml "${CFG[@]}" --dump | grep -v '"path"') \
        <(env B2B_CONFIG="$DEFAULTS" "${CFG[@]}" --dump | grep -v '"path"') >/dev/null && echo same || echo differs)" same

# ── get: every key the repo asks for ────────────────────────────────────────
check "get B2B_LOGIN" "$(get_of "$DEFAULTS" B2B_LOGIN)" dlesieur
check "get B2B_HOSTNAME defaults to <login>42" "$(get_of "$DEFAULTS" B2B_HOSTNAME)" dlesieur42
check "get B2B_FULLNAME defaults to the login" "$(get_of "$DEFAULTS" B2B_FULLNAME)" dlesieur
check "get B2B_USER_PASSWORD" "$(get_of "$DEFAULTS" B2B_USER_PASSWORD)" tempuser123
check "get B2B_ROOT_PASSWORD" "$(get_of "$DEFAULTS" B2B_ROOT_PASSWORD)" temproot123
check "get B2B_LUKS_PASSPHRASE" "$(get_of "$DEFAULTS" B2B_LUKS_PASSPHRASE)" tempencrypt123
check "get B2B_LOCALE_LANGUAGE" "$(get_of "$DEFAULTS" B2B_LOCALE_LANGUAGE)" en
check "get B2B_LOCALE_COUNTRY" "$(get_of "$DEFAULTS" B2B_LOCALE_COUNTRY)" US
check "get B2B_KEYMAP" "$(get_of "$DEFAULTS" B2B_KEYMAP)" es
check "get B2B_TIMEZONE" "$(get_of "$DEFAULTS" B2B_TIMEZONE)" Europe/Madrid
check "get B2B_MIRROR" "$(get_of "$DEFAULTS" B2B_MIRROR)" deb.debian.org
check "get B2B_SIZE_GB" "$(get_of "$DEFAULTS" B2B_SIZE_GB)" 15
check "get B2B_VM_NAME" "$(get_of "$DEFAULTS" B2B_VM_NAME)" debian
check "get B2B_BACKEND" "$(get_of "$DEFAULTS" B2B_BACKEND)" auto
check "get B2B_PROFILE" "$(get_of "$DEFAULTS" B2B_PROFILE)" auto
check "get B2B_AI_MODE" "$(get_of "$DEFAULTS" B2B_AI_MODE)" off
check "get B2B_SWAP_MB" "$(get_of "$DEFAULTS" B2B_SWAP_MB)" auto
check 'get B2B_VM_RAM_MB: "auto" is empty, as the Makefile expects' \
    "$(get_of "$DEFAULTS" B2B_VM_RAM_MB)" ""
check "get B2B_FEATURES: all auto means empty, so the picker still runs" \
    "$(get_of "$DEFAULTS" B2B_FEATURES)" ""
check "get B2B_NVIM_USERS" "$(get_of "$DEFAULTS" B2B_NVIM_USERS)" dlesieur
check "get B2B_USERS" "$(get_of "$DEFAULTS" B2B_USERS)" dlesieur
check "get B2B_EXTRA_USERS is empty with one account" "$(get_of "$DEFAULTS" B2B_EXTRA_USERS)" ""
check "get B2B_PASS_MAX_DAYS" "$(get_of "$DEFAULTS" B2B_PASS_MAX_DAYS)" 30
check "get B2B_SUDO_TRIES" "$(get_of "$DEFAULTS" B2B_SUDO_TRIES)" 3
check "get B2B_SUDO_BADPASS" "$(get_of "$DEFAULTS" B2B_SUDO_BADPASS)" "Wrong password. Access denied!"
check "get B2B_SSH_PASSWORD_LOGIN" "$(get_of "$DEFAULTS" B2B_SSH_PASSWORD_LOGIN)" yes
check "get B2B_MONITOR_INTERVAL" "$(get_of "$DEFAULTS" B2B_MONITOR_INTERVAL)" 10
check "get a dotted path" "$(get_of "$DEFAULTS" vm.name)" debian
check "get a dotted path into a policy" "$(get_of "$DEFAULTS" policy.sudo.tries)" 3
check "get a dotted path into an account" "$(get_of "$DEFAULTS" users.dlesieur.nvim)" true
check "get an unknown key is empty, not an error" "$(get_of "$DEFAULTS" B2B_NOT_A_KEY)" ""

# get must answer from a file --check refuses, and say nothing on stderr:
# `make status` on a half-edited file still has to print a banner.
BROKEN=$(printf '%s\n' 'this is not toml = = =' >"$TMP/broken.toml" && printf '%s' "$TMP/broken.toml")
check "a broken file: get is silent" \
    "$(env B2B_CONFIG="$BROKEN" "${CFG[@]}" get B2B_VM_NAME 2>&1)" ""
check "a broken file: get exits 0" \
    "$(env B2B_CONFIG="$BROKEN" "${CFG[@]}" get B2B_VM_NAME >/dev/null 2>&1 && echo 0 || echo 1)" 0
check "a broken file: --parses refuses, so the destructive targets can stop" \
    "$(rc_of "$BROKEN" --parses)" 1
contains "--parses names TOML" "$(cat "$TMP/out")" "not valid TOML"
check "the shipped file parses" "$(rc_of born2root.toml --parses)" 0
check "an invalid value still answers get" \
    "$(get_of "$(variant badsize 's/^disk_gb  *=.*/disk_gb = 2/')" B2B_SIZE_GB)" 2

# ── Refusals: [vm] and [system] ─────────────────────────────────────────────
refuse "vm.name with a space" vm.name 's/^name    = "debian"/name    = "my vm"/'
refuse "vm.backend nonsense" vm.backend 's/^backend = "auto"/backend = "hyperv"/'
refuse "vm.disk_gb below 8" vm.disk_gb 's/^disk_gb = 15/disk_gb = 4/'
refuse "vm.disk_gb quoted" vm.disk_gb 's/^disk_gb = 15/disk_gb = "15"/'
refuse "vm.ram_mb below 512" vm.ram_mb 's/^ram_mb  = "auto"/ram_mb  = 128/'
refuse "vm.profile nonsense" vm.profile 's/^profile = "auto"/profile = "enormous"/'
refuse "vm.ai_mode nonsense" vm.ai_mode 's/^ai_mode = "off"/ai_mode = "maybe"/'
refuse "an unknown key in [vm]" "vm.nmae" 's/^name    = "debian"/nmae = "debian"/'
refuse "an unknown section" "wat" 's/^\[packages\]/[wat]/'
refuse "system.hostname with an underscore" system.hostname \
    's/^hostname        = ""/hostname        = "my_host"/'
refuse "system.locale nonsense" system.locale \
    's/^locale          = "en_US.UTF-8"/locale          = "english"/'
refuse "system.keymap nonsense" system.keymap \
    's/^keymap          = "es"/keymap          = "ES2"/'
refuse "system.timezone nonsense" system.timezone \
    's|^timezone        = "Europe/Madrid"|timezone        = "Mars/Olympus"|'
refuse "system.mirror with a path" system.mirror \
    's|^mirror          = "deb.debian.org"|mirror          = "deb.debian.org/debian"|'
refuse "system.root_password empty" system.root_password \
    's/^root_password   = "temproot123"/root_password   = ""/'
refuse "system.root_password missing altogether" system.root_password \
    '/^root_password/d'
refuse "system.luks_passphrase too short" system.luks_passphrase \
    's/^luks_passphrase = "tempencrypt123"/luks_passphrase = "short"/'
refuse "system.luks_passphrase with a space the keyboard cannot type" \
    system.luks_passphrase \
    's/^luks_passphrase = "tempencrypt123"/luks_passphrase = "pass phrase"/'

# ── Refusals: accounts ──────────────────────────────────────────────────────
refuse "no account at all" users '/^\[users.dlesieur\]/,/^nvim     = true/d'
refuse "your own account without a password" users.dlesieur.password \
    's/^password = "tempuser123"/password = ""/'
refuse "your own account with sudo = false" users.dlesieur.sudo \
    's/^sudo     = true/sudo     = false/'
refuse "your own account with nvim = false" users.dlesieur.nvim \
    's/^nvim     = true/nvim     = false/'
refuse "a login with a capital letter" users.Bob \
    's/^\[users.dlesieur\]/[users.Bob]/'
refuse "root as an account" users.root 's/^\[users.dlesieur\]/[users.root]/'
refuse "a shell set per account" users.dlesieur.shell \
    's/^nvim     = true/nvim     = true\nshell = "\/bin\/bash"/'
refuse "an unknown key in an account" users.dlesieur.passwrd \
    's/^password = "tempuser123"/passwrd = "tempuser123"/'
refuse "fullname with a comma" users.dlesieur.fullname \
    's/^fullname = ""/fullname = "Ann, PhD"/'
refuse "sudo in groups" users.dlesieur.groups \
    's/^groups   = \[\]/groups   = ["sudo"]/'
refuse "user42 in groups" users.dlesieur.groups \
    's/^groups   = \[\]/groups   = ["user42"]/'
refuse "a group name with a capital" users.dlesieur.groups \
    's/^groups   = \[\]/groups   = ["Docker"]/'
refuse "an ssh key that is not a key or a path" users.dlesieur.ssh_keys \
    's/^ssh_keys = \[\]/ssh_keys = ["hello"]/'
refuse "an ssh key whose base64 is broken" users.dlesieur.ssh_keys \
    's/^ssh_keys = \[\]/ssh_keys = ["ssh-ed25519 not!base64 c"]/'
refuse "an ssh key wrapped over two lines (half a blob)" users.dlesieur.ssh_keys \
    's/^ssh_keys = \[\]/ssh_keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 c"]/'
refuse "an ssh key path that does not exist" users.dlesieur.ssh_keys \
    's|^ssh_keys = \[\]|ssh_keys = ["~/.ssh/nothing-here.pub"]|'
refuse_add "the same account twice" "users" '[users.dlesieur]
password = "x"'
# An array of tables collides with the [users.x] tables above it, so TOML
# itself refuses it -- with the line, which is what a reader needs.
refuse_add "an account written as [[users]]" "not valid TOML" '[[users]]
name = "bob"'
refuse_add "an extra account with no password key" "users.bob.password" '[users.bob]
sudo = true'

# ── Refusals: features, packages, policies, network ─────────────────────────
refuse "a feature that is neither auto nor a boolean" features.docker \
    's/^docker         = "auto"/docker         = "yes"/'
refuse "turning a base feature off" features.nvim \
    's/^docker         = "auto"/nvim = false/'
refuse "turning hellish off" features.hellish \
    's/^docker         = "auto"/hellish = false/'
refuse "an unknown feature" features.dcoker \
    's/^docker         = "auto"/dcoker = true/'
refuse "an ai feature instead of vm.ai_mode" features.ai-local \
    's/^docker         = "auto"/ai-local = true/'
refuse "a space reservation as a feature" features.vscode-remote \
    's/^docker         = "auto"/vscode-remote = false/'
refuse "a package name with a capital" packages.apt \
    's/^apt = \[\]/apt = ["Htop"]/'
refuse "the same package twice" packages.apt \
    's/^apt = \[\]/apt = ["htop", "htop"]/'
refuse "a password policy weaker than the subject" policy.password.min_length \
    's/^min_length  = 10/min_length  = 8/'
refuse "a password that never expires" policy.password.max_days \
    's/^max_days    = 30/max_days    = 99999/'
refuse "min_days at or above max_days" policy.password.min_days \
    's/^min_days    = 2/min_days    = 30/'
refuse "sudo tries above 3" policy.sudo.tries 's/^tries           = 3/tries           = 5/'
refuse "a sudo message with a quote in it" policy.sudo.badpass_message \
    's/^badpass_message = "Wrong password. Access denied!"/badpass_message = "Nope, said the \\"guard\\""/'
refuse "a relative sudo log dir" policy.sudo.log_dir \
    's|^log_dir         = "/var/log/sudo"|log_dir         = "sudo"|'
refuse "a monitoring interval cron cannot repeat" policy.monitoring.interval_min \
    's/^interval_min = 10/interval_min = 7/'
refuse "a forward on the SSH port" network.forwards \
    's/^forwards = \[\]/forwards = [ { name = "x", guest = 4242, host = 4243 } ]/'
refuse "a forward on a port the build already uses" network.forwards \
    's/^forwards = \[\]/forwards = [ { name = "x", guest = 443, host = 9443 } ]/'
refuse "a forward below 1024 on this machine" network.forwards \
    's/^forwards = \[\]/forwards = [ { name = "x", guest = 9100, host = 80 } ]/'
refuse "two forwards with the same name" network.forwards \
    's/^forwards = \[\]/forwards = [ { name = "x", guest = 9100, host = 9100 }, { name = "x", guest = 9101, host = 9101 } ]/'
refuse "an unknown key in a forward" network.forwards \
    's/^forwards = \[\]/forwards = [ { name = "x", guest = 9100, host = 9100, proto = "udp" } ]/'

# ── Refusals: the volume table ──────────────────────────────────────────────
refuse "no volume on /" disk.volumes 's|{ name = "root",    mount = "/",|{ name = "root",    mount = "/roo",|'
refuse "two volumes taking the remainder" disk.volumes \
    's/{ name = "srv",     mount = "\/srv",     floor_mb = 256,  share = 0,/{ name = "srv",     mount = "\/srv",     floor_mb = 256,  share = "rest",/'
refuse "no volume taking the remainder" disk.volumes \
    's/share = "rest"                  }/share = 9 }/'
refuse "a volume called swap" disk.volumes.swap 's/{ name = "tmp",/{ name = "swap",/'
refuse "two volumes with the same mount" disk.volumes \
    's|{ name = "srv",     mount = "/srv",|{ name = "srv",     mount = "/tmp",|'
refuse "a volume on /boot" disk.volumes 's|{ name = "srv",     mount = "/srv",|{ name = "srv",     mount = "/boot",|'
refuse "a floor below 128 MB" disk.volumes.srv 's/{ name = "srv",     mount = "\/srv",     floor_mb = 256,/{ name = "srv",     mount = "\/srv",     floor_mb = 64,/'
refuse "a cap below the floor" disk.volumes.srv \
    's/{ name = "srv",     mount = "\/srv",     floor_mb = 256,  share = 0,      cap_mb = 10240  }/{ name = "srv",     mount = "\/srv",     floor_mb = 256,  share = 0,      cap_mb = 100 }/'
refuse "shares above 100 in total" disk.volumes 's/share = 25,/share = 95,/'
refuse "an unknown key in a volume" disk.volumes.srv 's/floor_mb = 256,  share = 0,      cap_mb = 10240/floor_mb = 256,  share = 0,      ceiling = 10240/'
refuse "swap_mb below 256" disk.swap_mb 's/^swap_mb = "auto"/swap_mb = 64/'

# ── VM_PASS beats the file, even as a bare prefix under hellish ─────────────
check "VM_PASS wins over the file" \
    "$(env B2B_CONFIG="$DEFAULTS" VM_PASS=Other-pass.42 "${CFG[@]}" get B2B_LUKS_PASSPHRASE)" Other-pass.42
sourced() { # run a snippet with the library sourced, under the shell being tested
    "${SCRIPT_SH:-bash}" -c "cd '$PWD'; export B2B_CONFIG='$DEFAULTS'; . utils/b2b_config.sh; $1"
}
check "sourced: the passphrase comes from the file" \
    "$(sourced 'b2b_luks_passphrase')" tempencrypt123
check "sourced: a plain VM_PASS assignment still wins" \
    "$(sourced 'VM_PASS=Assigned-pass.42; b2b_luks_passphrase')" Assigned-pass.42
check "sourced: VM_PASS as a prefix on the function wins (hellish exports none)" \
    "$(sourced 'VM_PASS=Prefixed-pass.42 b2b_luks_passphrase')" Prefixed-pass.42
check "sourced: b2b_user_password" "$(sourced 'b2b_user_password')" tempuser123
check "sourced: b2b_locale_country" "$(sourced 'b2b_locale_country')" US
check "sourced: b2b_extra_users is empty here" "$(sourced 'b2b_extra_users')" ""
check "sourced: nothing runs when the library is sourced" \
    "$(sourced 'echo quiet')" quiet

# ── --volumes, --guest, --shadow, --ssh-keys ────────────────────────────────
check "--volumes puts / first" \
    "$(env B2B_CONFIG="$DEFAULTS" "${CFG[@]}" --volumes | head -1)" "root / 2816 25 30720"
check "--volumes puts the remainder volume last" \
    "$(env B2B_CONFIG="$DEFAULTS" "${CFG[@]}" --volumes | tail -1)" "var /var 2048 rest -"
check "--volumes lists every volume" \
    "$(env B2B_CONFIG="$DEFAULTS" "${CFG[@]}" --volumes | wc -l)" 7
check "--volumes refuses a table the installer could not create" \
    "$(rc_of "$(variant novol 's|{ name = "root",    mount = "/",|{ name = "root",    mount = "/roo",|')" --volumes)" 1

GUEST=$(env B2B_CONFIG="$DEFAULTS" "${CFG[@]}" --guest)
check "--guest records no password" \
    "$(printf '%s\n' "$GUEST" | grep -v '^#' |
        grep -ciE 'password|passphrase|tempuser|temproot|tempencrypt')" 0
contains "--guest names the login" "$GUEST" "B2B_LOGIN=dlesieur"
contains "--guest names the hostname" "$GUEST" "B2B_HOSTNAME=dlesieur42"
contains "--guest quotes the volume list" "$GUEST" 'B2B_VOLUMES="root:/ home:/home'
check "--guest is sourceable" \
    "$(printf '%s\n' "$GUEST" >"$TMP/build.conf" && "${SCRIPT_SH:-bash}" -c ". '$TMP/build.conf'; printf '%s' \"\$B2B_KEYMAP\"")" es

# --users: the one place a full name travels, never build.conf.
USERS3=$(append users3 '[users.bob]
password = "Bob-secret-1"
fullname = "Bob O'"'"'Hara"
groups = ["docker"]

[users.saint]
password = ""
nvim = true')
check "--users: one record per account, in file order" \
    "$(env B2B_CONFIG="$USERS3" "${CFG[@]}" --users | tr '\n' '|')" \
    "dlesieur:dlesieur:user42,sudo|bob:Bob O'Hara:user42,docker|saint:saint:user42|"
GUEST3=$(env B2B_CONFIG="$USERS3" "${CFG[@]}" --guest)
contains "--guest lists every account" "$GUEST3" 'B2B_USERS="dlesieur bob saint"'
contains "--guest lists the editor users (first account always)" "$GUEST3" 'B2B_NVIM_USERS="dlesieur saint"'
check "--guest never carries a full name" "$(printf '%s\n' "$GUEST3" | grep -c "O'Hara")" 0

THREE=$(append users '[users.bob]
password = "Bob-secret-1"
sudo = true
groups = ["docker"]
nvim = false

[users.saint]
password = ""
fullname = "Saint of cluster 3"')
check "three accounts: B2B_USERS lists them in file order" \
    "$(get_of "$THREE" B2B_USERS)" "dlesieur bob saint"
check "three accounts: the extras carry their groups" \
    "$(get_of "$THREE" B2B_EXTRA_USERS)" "bob:user42,sudo,docker saint:user42"
check "three accounts: only those who asked get nvim" \
    "$(get_of "$THREE" B2B_NVIM_USERS)" dlesieur
check "an empty password is reported as locked" \
    "$(env B2B_CONFIG="$THREE" "${CFG[@]}" --show | grep -c 'saint.*locked')" 1
check "an account with sudo but no password warns" \
    "$(env B2B_CONFIG="$(append sudonopass '[users.bob]
password = ""
sudo = true')" "${CFG[@]}" --check 2>&1 | grep -c 'warning:.*sudo')" 1

SHADOW=$(env B2B_CONFIG="$THREE" "${CFG[@]}" --shadow)
check "--shadow has one line per extra account" "$(printf '%s\n' "$SHADOW" | wc -l)" 2
check "--shadow hashes with SHA-512" \
    "$(printf '%s\n' "$SHADOW" | grep -c '^bob:\$6\$')" 1
check "--shadow locks an account with no password" \
    "$(printf '%s\n' "$SHADOW" | grep -c '^saint:!$')" 1
BOBHASH=$(printf '%s\n' "$SHADOW" | sed -n 's/^bob://p')
BOBSALT=$(printf '%s' "$BOBHASH" | cut -d'$' -f3)
check "--shadow: the hash is really that password" \
    "$(printf '%s\n' Bob-secret-1 | openssl passwd -6 -salt "$BOBSALT" -stdin)" "$BOBHASH"
check "--shadow never holds the login's own password" \
    "$(printf '%s\n' "$SHADOW" | grep -c dlesieur)" 0

KEYS=$(append keys '[users.bob]
password = "Bob-secret-1"
ssh_keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJJ0l7ZHSFAPmNEMzE0YSFXjPtHFMH0Aa3nOEWaVSFvB bob@laptop"]')
check "--ssh-keys names the account and keeps the key whole" \
    "$(env B2B_CONFIG="$KEYS" "${CFG[@]}" --ssh-keys)" \
    "bob ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJJ0l7ZHSFAPmNEMzE0YSFXjPtHFMH0Aa3nOEWaVSFvB bob@laptop"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJJ0l7ZHSFAPmNEMzE0YSFXjPtHFMH0Aa3nOEWaVSFvB from@file\n' >"$TMP/id.pub"
check "--ssh-keys reads a path on this machine" \
    "$(env B2B_CONFIG="$(append keypath "[users.bob]
password = \"Bob-secret-1\"
ssh_keys = [\"$TMP/id.pub\"]")" "${CFG[@]}" --ssh-keys)" \
    "bob ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJJ0l7ZHSFAPmNEMzE0YSFXjPtHFMH0Aa3nOEWaVSFvB from@file"

# ── Features, packages and forwards as the rest of the repo reads them ──────
FEAT=$(variant feat 's/^docker         = "auto"/docker         = true/' \
    's/^pytools        = "auto"/pytools        = false/')
check "[features] becomes the +docker -pytools string FEATURES takes" \
    "$(get_of "$FEAT" B2B_FEATURES)" "+docker -pytools"
check "packages become a space-separated list for the guest" \
    "$(get_of "$(variant pkgs 's/^apt = \[\]/apt = ["htop", "tree"]/')" B2B_APT_PACKAGES)" "htop tree"
FWD=$(variant fwd 's/^forwards = \[\]/forwards = [ { name = "grafana", guest = 3100, host = 3100 }, { name = "api", guest = 9000, host = 19000 } ]/')
check "forwards come out as name:host:guest, what PORTS_SPEC takes" \
    "$(get_of "$FWD" B2B_FORWARDS)" "grafana:3100:3100 api:19000:9000"
check "the guest ports alone, for the firewall" \
    "$(get_of "$FWD" B2B_FORWARD_PORTS)" "3100 9000"

# ── --render ────────────────────────────────────────────────────────────────
render_of() { # <config> <template text> -> rendered text, or the error
    printf '%s\n' "$2" >"$TMP/tpl"
    env B2B_CONFIG="$1" "${CFG[@]}" --render "$TMP/tpl" 2>&1
}
check "render fills a placeholder" \
    "$(render_of "$DEFAULTS" 'login=@B2B_LOGIN@')" "login=dlesieur"
check "render fills two placeholders side by side" \
    "$(render_of "$DEFAULTS" '@B2B_LOGIN@@B2B_KEYMAP@')" "dlesieures"
check "render leaves the preseed's own \$(...) alone" \
    "$(render_of "$DEFAULTS" 'd-i x string $(list-devices disk | head -n1)')" \
    'd-i x string $(list-devices disk | head -n1)'
check "render leaves \$lvmok{ } alone" \
    "$(render_of "$DEFAULTS" '$lvmok{ } method{ lvm }')" '$lvmok{ } method{ lvm }'
ODD=$(variant odd 's/^luks_passphrase = "tempencrypt123"/luks_passphrase = "A$\&\/b.42"/')
check "render splices a value holding \$ & / verbatim" \
    "$(render_of "$ODD" 'p=@B2B_LUKS_PASSPHRASE@')" 'p=A$&/b.42'
check "render refuses a placeholder nothing answers" \
    "$(render_of "$DEFAULTS" 'x=@B2B_NO_SUCH_KEY@' >/dev/null 2>&1 && echo 0 || echo 1)" 1
contains "render names the placeholder it cannot fill" \
    "$(render_of "$DEFAULTS" 'x=@B2B_NO_SUCH_KEY@')" "@B2B_NO_SUCH_KEY@"
check "render refuses a placeholder whose value would be empty" \
    "$(render_of "$DEFAULTS" 'x=@B2B_APT_PACKAGES@' >/dev/null 2>&1 && echo 0 || echo 1)" 1
check "render hashes the passwords" \
    "$(render_of "$DEFAULTS" 'root=@B2B_ROOT_PASSWORD_HASH@' | grep -c '^root=\$6\$')" 1
check "the two hashes differ (each password is salted on its own)" \
    "$(render_of "$DEFAULTS" '@B2B_ROOT_PASSWORD_HASH@ @B2B_USER_PASSWORD_HASH@' | awk '{ print ($1 == $2) ? "same" : "different" }')" different

# The real template, with the defaults.
PRESEED=$(env B2B_CONFIG="$DEFAULTS" "${CFG[@]}" --render preseeds/preseed.cfg.in)
check "the real template renders" "$?" 0
check "no placeholder survives" "$(printf '%s\n' "$PRESEED" | grep -c '@B2B_[A-Z0-9_]*@')" 0
contains "the rendered preseed names the login" "$PRESEED" "passwd/username string dlesieur"
contains "the rendered preseed names the hostname" "$PRESEED" "netcfg/get_hostname string dlesieur42"
contains "the rendered preseed carries the keymap" "$PRESEED" "xkb-keymap select es"
contains "the rendered preseed carries the passphrase" "$PRESEED" \
    "partman-crypto/passphrase password tempencrypt123"
check "the rendered preseed hashes root's password" \
    "$(printf '%s\n' "$PRESEED" | grep -c 'passwd/root-password-crypted password \$6\$')" 1
check "the rendered preseed hashes the login's password" \
    "$(printf '%s\n' "$PRESEED" | grep -c 'passwd/user-password-crypted password \$6\$')" 1
check "no cleartext password reaches the preseed" \
    "$(printf '%s\n' "$PRESEED" | grep -cE 'tempuser123|temproot123')" 0
check "the RECIPE markers survive, once each" \
    "$(printf '%s\n' "$PRESEED" | grep -cE '^# ─+ RECIPE-(BEGIN|END)')" 2

# ── The vendored parser, and both parsers agreeing ──────────────────────────
check "the vendored tomli is shipped" "$([ -f utils/vendor/tomli/_parser.py ] && echo yes)" yes
check "its licence is kept next to it" "$([ -f utils/vendor/tomli/LICENSE ] && echo yes)" yes
check "no markdown in the vendored copy (CI lints every .md)" \
    "$(find utils/vendor -name '*.md' | wc -l)" 0
check "forced onto the vendored parser, the answer is the same" \
    "$(env B2B_CONFIG="$DEFAULTS" B2B_TOML_VENDORED=1 "${CFG[@]}" get B2B_LOGIN)" dlesieur
check "forced onto the vendored parser, the file still validates" \
    "$(env B2B_CONFIG="$DEFAULTS" B2B_TOML_VENDORED=1 "${CFG[@]}" --check >/dev/null 2>&1 && echo 0 || echo 1)" 0
check "the reader compiles under this python" \
    "$(python3 -m py_compile utils/b2b_config.py && echo ok)" ok

# ── No identity literal anywhere but the config ─────────────────────────────
# The whole point of the file: a colleague changes one line and the build is
# theirs. A hardcoded login or temp password would quietly ignore them.
LITERALS=$(grep -rnE 'dlesieur|temp(user|root|encrypt)123|vm_pass\.txt|born2root\.conf' \
    preseeds generate setup/host setup/install/nvim setup/install/hellish \
    setup/install/tools setup/install/ai utils unlock_vm.sh Makefile 2>/dev/null |
    grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' |
    grep -vE 'utils/(welcome|ascii_welcome)\.sh|utils/vendor/|preseeds/deb_preseed\.bak' || true)
check "no login, password or old file name in code" "$(printf '%s' "$LITERALS" | grep -c . || true)" 0
[ -z "$LITERALS" ] || printf '%s\n' "$LITERALS" | head -20

exit "$fail"
