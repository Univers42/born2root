#!/usr/bin/env hellish
# Regression test for utils/b2b_config.sh and born2root.conf.
#
# What it guards: born2root.conf is the only place the VM's identity, users,
# locale and disk layout are written down, and every consumer reads it
# through this one script. Two things must hold. A value must come out
# exactly as typed (trimmed, one pair of quotes stripped, a `#` kept: a
# passphrase may contain one), and a wrong value must be refused BEFORE the
# ISO download, naming the key -- the alternative is a 20-minute install that
# stops at a d-i question nobody sees, or a guest whose sudo user is "".
# `get` is special: the Makefile calls it at parse time for every `make`,
# `make help` included, so it must never fail and never write to stderr.
#
# Every refusal below is a fixture derived from the shipped defaults
# (tests/fixtures/default.conf, NOT born2root.conf: that one is meant to be
# personalised, and a colleague's login must not fail this test) by one sed
# edit, so the defaults themselves are proven valid first. born2root.conf is
# only required to be valid, whatever it holds.
#
# shellcheck disable=SC2016 # sed programs and crypt hashes: $ is literal here
set -e

cd "$(dirname "$0")/.."

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-58s = %s\n' "$1" "$2"
    else
        printf 'FAIL %-58s = %s (expected %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}
CFG=("${SCRIPT_SH:-bash}" utils/b2b_config.sh)
DEFAULTS=tests/fixtures/default.conf
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# A fixture: the defaults with sed edits applied, each its own -e. Prints its
# path.
variant() {
    local out="$TMP/$1.conf" e
    local -a args=()
    shift
    for e in "$@"; do
        args+=(-e "$e")
    done
    sed "${args[@]}" "$DEFAULTS" >"$out"
    printf '%s' "$out"
}
# The exit status of --check on a fixture, and the keys its complaints name.
# Variables reach the script through `env` on the COMMAND: hellish does not
# export `VAR=x helper` to what the helper runs, so a test written that way
# would pass under bash and exercise nothing under hellish.
rc_check() { env B2B_CONFIG="$1" "${CFG[@]}" --check >/dev/null 2>&1 && echo 0 || echo $?; }
names_in() { env B2B_CONFIG="$1" "${CFG[@]}" --check 2>&1 >/dev/null | grep -oE "$2" | head -1; }
get_of() { env B2B_CONFIG="$1" "${CFG[@]}" get "$2"; }

# ── The shipped file is valid, and get reads it back ───────────────────────
check "born2root.conf (whatever it holds) passes --check" "$(rc_check born2root.conf)" 0
check "the defaults fixture passes --check" "$(rc_check "$DEFAULTS")" 0
# The fixture is the shipped file minus its comments: same keys, same rows.
check "the fixture sets every key born2root.conf sets" \
    "$(grep -oE '^[A-Z0-9_]+=' "$DEFAULTS" | sort | tr -d '\n')" \
    "$(grep -oE '^[A-Z0-9_]+=' born2root.conf | sort | tr -d '\n')"
check "get B2B_LOGIN" "$(get_of "$DEFAULTS" B2B_LOGIN)" dlesieur
check "get B2B_HOSTNAME derives <login>42" "$(get_of "$DEFAULTS" B2B_HOSTNAME)" dlesieur42
f=$(variant hostname 's/^B2B_HOSTNAME=.*/B2B_HOSTNAME=srv42/')
check "an explicit B2B_HOSTNAME wins" "$(get_of "$f" B2B_HOSTNAME)" srv42
check "a hostname that is not <login>42 warns but passes" "$(rc_check "$f")" 0
check "...and says so" "$(env B2B_CONFIG="$f" "${CFG[@]}" --check 2>&1 >/dev/null | grep -c '^warning: B2B_HOSTNAME')" 1
f=$(variant quotes 's/^B2B_FEATURES=.*/B2B_FEATURES="+docker -pytools"/')
check "one pair of quotes is stripped" "$(get_of "$f" B2B_FEATURES)" "+docker -pytools"
f=$(variant spaces 's/^B2B_LOGIN=.*/  B2B_LOGIN =   bob   /')
check "whitespace around key and value is trimmed" "$(get_of "$f" B2B_LOGIN)" bob
f=$(variant hash 's|^B2B_LUKS_PASSPHRASE=.*|B2B_LUKS_PASSPHRASE=ab#cd.efgh|')
check "a # inside a value is part of it (no inline comments)" "$(get_of "$f" B2B_LUKS_PASSPHRASE)" 'ab#cd.efgh'
check "...and such a passphrase is accepted" "$(rc_check "$f")" 0
printf 'B2B_LOGIN=crlf\r\n' >"$TMP/crlf.conf"
check "CRLF endings are stripped" "$(get_of "$TMP/crlf.conf" B2B_LOGIN)" crlf
check "get of an unknown key is empty, exit 0" "$(
    get_of "$DEFAULTS" B2B_NOPE
    echo "rc=$?"
)" "rc=0"
check "get with no file is empty, exit 0, silent" "$(
    get_of /nonexistent B2B_LOGIN 2>&1
    echo "rc=$?"
)" "rc=0"
check "--check with no file fails" "$(rc_check /nonexistent)" 1

# ── Refusals name the key ───────────────────────────────────────────────────
refuse() { # <label> <expected key in the message> <sed expr>...
    local label="$1" key="$2" f
    shift 2
    f=$(variant "$(printf '%s' "$label" | tr -c 'A-Za-z0-9' _)" "$@")
    check "$label: refused" "$(rc_check "$f")" 1
    check "$label: names $key" "$(names_in "$f" "$key")" "$key"
}
refuse "login with a capital" B2B_LOGIN 's/^B2B_LOGIN=.*/B2B_LOGIN=Root/'
refuse "login root" B2B_LOGIN 's/^B2B_LOGIN=.*/B2B_LOGIN=root/'
refuse "hostname with an underscore" B2B_HOSTNAME 's/^B2B_HOSTNAME=.*/B2B_HOSTNAME=my_vm/'
refuse "empty user password" B2B_USER_PASSWORD 's/^B2B_USER_PASSWORD=.*/B2B_USER_PASSWORD=/'
refuse "empty root password" B2B_ROOT_PASSWORD 's/^B2B_ROOT_PASSWORD=.*/B2B_ROOT_PASSWORD=/'
refuse "passphrase too short" B2B_LUKS_PASSPHRASE 's/^B2B_LUKS_PASSPHRASE=.*/B2B_LUKS_PASSPHRASE=abc1234/'
refuse "passphrase with a space" B2B_LUKS_PASSPHRASE 's/^B2B_LUKS_PASSPHRASE=.*/B2B_LUKS_PASSPHRASE=abc def ghi/'
refuse "passphrase with a quote" B2B_LUKS_PASSPHRASE "s/^B2B_LUKS_PASSPHRASE=.*/B2B_LUKS_PASSPHRASE=abcdefg'h/"
refuse "passphrase with a backslash" B2B_LUKS_PASSPHRASE 's/^B2B_LUKS_PASSPHRASE=.*/B2B_LUKS_PASSPHRASE=abcdefg\\h/'
refuse "extra user without a password" B2B_EXTRA_USERS 's/^B2B_EXTRA_USERS=.*/B2B_EXTRA_USERS=alice/'
refuse "extra user with an empty password" B2B_EXTRA_USERS 's/^B2B_EXTRA_USERS=.*/B2B_EXTRA_USERS=alice:/'
refuse "extra user with a bad flag" B2B_EXTRA_USERS 's/^B2B_EXTRA_USERS=.*/B2B_EXTRA_USERS=alice:pw:admin/'
refuse "extra user listed twice" B2B_EXTRA_USERS 's/^B2B_EXTRA_USERS=.*/B2B_EXTRA_USERS=alice:pw alice:pw2/'
refuse "extra user named root" B2B_EXTRA_USERS 's/^B2B_EXTRA_USERS=.*/B2B_EXTRA_USERS=root:pw/'
refuse "extra user named like the login" B2B_EXTRA_USERS 's/^B2B_EXTRA_USERS=.*/B2B_EXTRA_USERS=dlesieur:pw/'
refuse "locale without a territory" B2B_LOCALE 's/^B2B_LOCALE=.*/B2B_LOCALE=en/'
refuse "keymap in capitals" B2B_KEYMAP 's/^B2B_KEYMAP=.*/B2B_KEYMAP=ES/'
refuse "unknown timezone" B2B_TIMEZONE 's|^B2B_TIMEZONE=.*|B2B_TIMEZONE=Mars/Olympus|'
refuse "mirror given as a URL" B2B_MIRROR 's|^B2B_MIRROR=.*|B2B_MIRROR=http://deb.debian.org|'
refuse "swap below 256" B2B_SWAP_MB 's/^B2B_SWAP_MB=.*/B2B_SWAP_MB=100/'
refuse "disk below 8 GB" B2B_SIZE_GB 's/^B2B_SIZE_GB=.*/B2B_SIZE_GB=7/'
refuse "RAM below 512" B2B_VM_RAM_MB 's/^B2B_VM_RAM_MB=.*/B2B_VM_RAM_MB=256/'
refuse "VM name with a space" B2B_VM_NAME 's/^B2B_VM_NAME=.*/B2B_VM_NAME=my vm/'
refuse "unknown backend" B2B_BACKEND 's/^B2B_BACKEND=.*/B2B_BACKEND=kvm/'
refuse "unknown profile" B2B_PROFILE 's/^B2B_PROFILE=.*/B2B_PROFILE=huge/'
refuse "feature without + or -" B2B_FEATURES 's/^B2B_FEATURES=.*/B2B_FEATURES=docker/'
refuse "unknown AI mode" B2B_AI_MODE 's/^B2B_AI_MODE=.*/B2B_AI_MODE=yes/'
refuse "unknown key" 'unknown key B2B_LOGN' 's/^B2B_LOGIN=/B2B_LOGN=/'
refuse "key set twice" 'B2B_LOGIN is set twice' '$a\
B2B_LOGIN=again'
refuse "a line that is neither" 'not a KEY=value' '$a\
this is not a setting'
refuse "a missing key" 'B2B_MIRROR is missing' '/^B2B_MIRROR=/d'
# The volume table.
refuse "no / volume" 'B2B_VOLUME: exactly one volume must be mounted on /' 's|^B2B_VOLUME  root     /  |B2B_VOLUME  root     /root |'
refuse "two rest volumes" "share 'rest'" 's|^B2B_VOLUME  home .*|B2B_VOLUME  home /home 512 rest -|'
refuse "no rest volume" "share 'rest'" 's|^B2B_VOLUME  var .*|B2B_VOLUME  var /var 2048 0 -|'
refuse "a /boot volume" 'B2B_VOLUME boot' '$a\
B2B_VOLUME boot /boot 500 0 -'
refuse "a volume named swap" 'B2B_VOLUME swap' '$a\
B2B_VOLUME swap /swap 512 0 -'
refuse "two volumes with one name" 'this name is used twice' '$a\
B2B_VOLUME opt /opt2 256 0 -'
refuse "two volumes on one mount" 'is used twice' '$a\
B2B_VOLUME opt2 /opt 256 0 -'
refuse "floor below 128" 'floor' 's|^B2B_VOLUME  srv .*|B2B_VOLUME  srv /srv 64 0 -|'
refuse "share above 100" 'share' 's|^B2B_VOLUME  srv .*|B2B_VOLUME  srv /srv 256 150 -|'
refuse "shares adding up past 100" 'add up' 's|^B2B_VOLUME  srv .*|B2B_VOLUME  srv /srv 256 60 -|'
refuse "cap below the floor" 'cap' 's|^B2B_VOLUME  srv .*|B2B_VOLUME  srv /srv 256 0 100|'
refuse "a row with four fields" 'exactly 5 fields' 's|^B2B_VOLUME  srv .*|B2B_VOLUME  srv /srv 256 0|'
refuse "a mount with a capital" 'mount' 's|^B2B_VOLUME  srv .*|B2B_VOLUME  srv /Srv 256 0 -|'

# ── VM_PASS overrides the passphrase, and is validated the same way ─────────
check "VM_PASS with a space is refused" "$(env B2B_CONFIG="$DEFAULTS" VM_PASS='bad pass' "${CFG[@]}" --check >/dev/null 2>&1 && echo 0 || echo $?)" 1
check "...naming VM_PASS" "$(env B2B_CONFIG="$DEFAULTS" VM_PASS='bad pass' "${CFG[@]}" --check 2>&1 >/dev/null | grep -o '^[^ ]*: VM_PASS' | sed 's/.*: //')" VM_PASS
check "a valid VM_PASS passes" "$(env B2B_CONFIG="$DEFAULTS" VM_PASS='Other-pass.42' "${CFG[@]}" --check >/dev/null 2>&1 && echo 0 || echo $?)" 0
# The library, sourced: the passphrase helper prefers VM_PASS.
(
    B2B_CONFIG=$DEFAULTS
    # shellcheck disable=SC1091
    . utils/b2b_config.sh
    # The helper reads VM_PASS itself, in this shell, so a plain assignment
    # is what is being tested here.
    VM_PASS=''
    check "b2b_luks_passphrase reads the file" "$(b2b_luks_passphrase)" tempencrypt123
    VM_PASS=Other-pass.42
    check "b2b_luks_passphrase prefers VM_PASS" "$(b2b_luks_passphrase)" Other-pass.42
    VM_PASS=
    check "b2b_locale_language" "$(b2b_locale_language)" en
    check "b2b_locale_country" "$(b2b_locale_country)" US
    check "sourcing runs no command" "$(sed -n '/^if \[ "\${BASH_SOURCE\[0\]:-\$0}" = "\$0" \]; then$/p' utils/b2b_config.sh | wc -l)" 1
    exit "$fail"
) || fail=1

# ── Volumes come out normalised: / first, rest last ─────────────────────────
f=$(variant reorder '/^B2B_VOLUME  root /{h;d;}' '/^B2B_VOLUME  var  /{H;d;}' '$G')
check "reordered file: / first" "$(env B2B_CONFIG="$f" "${CFG[@]}" --volumes | head -1 | awk '{print $2}')" /
check "reordered file: rest last" "$(env B2B_CONFIG="$f" "${CFG[@]}" --volumes | tail -1 | awk '{print $4}')" rest
check "--volumes: seven rows" "$(env B2B_CONFIG="$DEFAULTS" "${CFG[@]}" --volumes | wc -l)" 7
check "--volumes refuses a bad table" "$(env B2B_CONFIG="$(variant badvol 's|^B2B_VOLUME  var .*|B2B_VOLUME  var /var 2048 0 -|')" "${CFG[@]}" --volumes >/dev/null 2>&1 && echo 0 || echo $?)" 1

# ── What the guest gets ─────────────────────────────────────────────────────
f=$(variant users 's/^B2B_EXTRA_USERS=.*/B2B_EXTRA_USERS="alice:Alice1234 bob:Bob12345:sudo"/')
check "users fixture is valid" "$(rc_check "$f")" 0
guest=$(env B2B_CONFIG="$f" "${CFG[@]}" --guest)
check "--guest: extra users with their groups" "$(printf '%s\n' "$guest" | sed -n 's/^B2B_EXTRA_USERS=//p')" '"alice:user42 bob:user42,sudo"'
check "--guest: the volumes as name:mount" "$(printf '%s\n' "$guest" | sed -n 's/^B2B_VOLUMES=//p')" '"root:/ home:/home opt:/opt srv:/srv tmp:/tmp var-log:/var/log var:/var"'
check "--guest: no password, no passphrase" "$(printf '%s\n' "$guest" | grep -v '^#' | grep -ciE 'password|passphrase|Alice1234|Bob12345|tempuser|temproot|tempencrypt')" 0
check "--guest: source-able" "$(
    printf '%s\n' "$guest" >"$TMP/build.conf"
    "${SCRIPT_SH:-bash}" -c ". $TMP/build.conf && echo \"\$B2B_LOGIN \$B2B_HOSTNAME\""
)" "dlesieur dlesieur42"
shadow=$(env B2B_CONFIG="$f" "${CFG[@]}" --shadow)
check "--shadow: one SHA-512 line per extra user" "$(printf '%s\n' "$shadow" | grep -cE '^(alice|bob):\$6\$')" 2
salt=$(printf '%s\n' "$shadow" | sed -n 's/^alice:\$6\$\([^$]*\)\$.*/\1/p')
check "--shadow: alice's hash verifies" "$(printf '%s\n' "$shadow" | sed -n 's/^alice://p')" "$(openssl passwd -6 -salt "$salt" Alice1234)"
check "--shadow: nothing for no extra users" "$(env B2B_CONFIG="$DEFAULTS" "${CFG[@]}" --shadow | wc -l)" 0

# ── The render ──────────────────────────────────────────────────────────────
# Values pass through untouched whatever they contain, the template's own
# text is never rewritten, and a placeholder nothing answers stops the build.
cat >"$TMP/tpl" <<'EOF'
d-i passwd/username string @B2B_LOGIN@
d-i partman-crypto/passphrase password @B2B_LUKS_PASSPHRASE@
d-i passwd/root-password-crypted password @B2B_ROOT_PASSWORD_HASH@
	debconf-set partman-auto/disk "$(list-devices disk | head -n1)" $lvmok{ } & \ /
@B2B_LOGIN@@B2B_LOGIN@ user@B2B_HOSTNAME@.local @not_a_placeholder@ @B2B_
EOF
# In a sed replacement & is "the match" and \\ is one backslash, hence \& and \\.
f=$(variant render 's|^B2B_LUKS_PASSPHRASE=.*|B2B_LUKS_PASSPHRASE=A$\&/b.42=x|' 's|^B2B_ROOT_PASSWORD=.*|B2B_ROOT_PASSWORD=p$\&\\w"x|')
check "render fixture holds the password as typed" "$(sed -n 's/^B2B_ROOT_PASSWORD=//p' "$f")" 'p$&\w"x'
out=$(env B2B_CONFIG="$f" "${CFG[@]}" --render "$TMP/tpl")
check "render: username" "$(printf '%s\n' "$out" | sed -n '1p')" "d-i passwd/username string dlesieur"
check "render: \$ & / in a value survive" "$(printf '%s\n' "$out" | sed -n '2p')" 'd-i partman-crypto/passphrase password A$&/b.42=x'
rsalt=$(printf '%s\n' "$out" | sed -n '3s/.*password \$6\$\([^$]*\)\$.*/\1/p')
check "render: the root hash verifies against the password" "$(printf '%s\n' "$out" | sed -n '3s/.*password //p')" "$(printf '%s\n' 'p$&\w"x' | openssl passwd -6 -stdin -salt "$rsalt")"
check "render: the template's own \$(...) and \$lvmok{ } untouched" "$(printf '%s\n' "$out" | sed -n '4p')" "$(sed -n '4p' "$TMP/tpl")"
check "render: adjacent placeholders, text after, unknown @...@ kept" "$(printf '%s\n' "$out" | sed -n '5p')" 'dlesieurdlesieur userdlesieur42.local @not_a_placeholder@ @B2B_'
printf 'x @B2B_NOPE@ y\n' >"$TMP/tpl2"
check "render: a placeholder without a value fails" "$(env B2B_CONFIG="$DEFAULTS" "${CFG[@]}" --render "$TMP/tpl2" >/dev/null 2>&1 && echo 0 || echo $?)" 1
check "render: ...naming it" "$(env B2B_CONFIG="$DEFAULTS" "${CFG[@]}" --render "$TMP/tpl2" 2>&1 >/dev/null | grep -c '@B2B_NOPE@')" 1
check "render: nothing on stdout then" "$(env B2B_CONFIG="$DEFAULTS" "${CFG[@]}" --render "$TMP/tpl2" 2>/dev/null | wc -c)" 0
check "render: VM_PASS reaches the preseed" "$(env B2B_CONFIG="$DEFAULTS" VM_PASS=Other-pass.42 "${CFG[@]}" --render "$TMP/tpl" | sed -n '2p')" 'd-i partman-crypto/passphrase password Other-pass.42'

# ── The real template, rendered with the shipped defaults ───────────────────
# Every value the preseed used to spell out by hand must come out as it was,
# except the two passwords, which must now be hashes and nowhere in clear.
pre=$(env B2B_CONFIG="$DEFAULTS" "${CFG[@]}" --render preseeds/preseed.cfg.in)
check "preseed: no placeholder left" "$(printf '%s\n' "$pre" | grep -cE '@B2B_[A-Z0-9_]+@')" 0
check "preseed: username" "$(printf '%s\n' "$pre" | grep -c '^d-i passwd/username string dlesieur$')" 1
check "preseed: hostname, both keys" "$(printf '%s\n' "$pre" | grep -cE '^d-i netcfg/(get_)?hostname string dlesieur42$')" 2
check "preseed: locale, both keys" "$(printf '%s\n' "$pre" | grep -c ' en_US.UTF-8$')" 2
check "preseed: keymap" "$(printf '%s\n' "$pre" | grep -c '^d-i keyboard-configuration/xkb-keymap select es$')" 1
check "preseed: timezone" "$(printf '%s\n' "$pre" | grep -c '^d-i time/zone string Europe/Madrid$')" 1
check "preseed: mirror" "$(printf '%s\n' "$pre" | grep -c '^d-i mirror/http/hostname string deb.debian.org$')" 1
check "preseed: two crypted password keys" "$(printf '%s\n' "$pre" | grep -cE '^d-i passwd/(root|user)-password-crypted password \$6\$')" 2
check "preseed: no cleartext password key" "$(printf '%s\n' "$pre" | grep -cE '^d-i passwd/(root|user)-password(-again)? ')" 0
check "preseed: no password in clear anywhere" "$(printf '%s\n' "$pre" | grep -cE 'tempuser123|temproot123')" 0
check "preseed: user hash verifies" "$(printf '%s\n' "$pre" | sed -n 's/^d-i passwd\/user-password-crypted password //p')" \
    "$(printf '%s\n' "$pre" | sed -n 's/^d-i passwd\/user-password-crypted password \$6\$\([^$]*\)\$.*/\1/p' | xargs -I{} openssl passwd -6 -salt {} tempuser123)"
check "preseed: LUKS passphrase, both keys" "$(printf '%s\n' "$pre" | grep -cE '^d-i partman-crypto/passphrase(-again)? password tempencrypt123$')" 2
check "preseed: the partman early_command is untouched" "$(printf '%s\n' "$pre" | grep -c 'debconf-set partman-auto/disk "\$(list-devices disk | head -n1)"')" 1
check "preseed: RECIPE markers once" "$(printf '%s\n' "$pre" | grep -c '^# ── RECIPE-BEGIN')" 1
check "preseed: late_command copies build.conf" "$(printf '%s\n' "$pre" | grep -c 'cp /cdrom/build.conf /target/etc/b2b/build.conf')" 1
check "preseed: late_command copies the extra users' hashes" "$(printf '%s\n' "$pre" | grep -c 'cp /cdrom/extra_users.shadow /target/tmp/extra_users.shadow')" 1
check "preseed: no login spelt out in late_command" "$(printf '%s\n' "$pre" | sed -n '/^d-i preseed\/late_command/,/^$/p' | grep -c dlesieur)" 0
f=$(variant who 's/^B2B_LOGIN=.*/B2B_LOGIN=b2rtest/' 's|^B2B_TIMEZONE=.*|B2B_TIMEZONE=Europe/Paris|' 's/^B2B_KEYMAP=.*/B2B_KEYMAP=fr/')
pre=$(env B2B_CONFIG="$f" "${CFG[@]}" --render preseeds/preseed.cfg.in)
check "preseed, personalised: username" "$(printf '%s\n' "$pre" | grep -c '^d-i passwd/username string b2rtest$')" 1
check "preseed, personalised: hostname follows the login" "$(printf '%s\n' "$pre" | grep -c '^d-i netcfg/hostname string b2rtest42$')" 1
check "preseed, personalised: timezone and keymap" "$(printf '%s\n' "$pre" | grep -cE '^d-i (time/zone string Europe/Paris|keyboard-configuration/xkb-keymap select fr)$')" 2
check "preseed, personalised: dlesieur appears nowhere" "$(printf '%s\n' "$pre" | grep -v '^#' | grep -c dlesieur)" 0

# ── No identity is spelt out in code any more ───────────────────────────────
# Every consumer asks born2root.conf. A literal in a non-comment line is a
# place a personalised VM would silently keep the owner's values. The two
# welcome scripts are unreferenced art keyed by login name.
lits=$(grep -rnE 'dlesieur|temp(user|root|encrypt)123|vm_pass\.txt' \
    preseeds generate setup/host setup/install/nvim setup/install/hellish setup/install/tools setup/install/ai \
    utils unlock_vm.sh Makefile 2>/dev/null |
    grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' |
    grep -vE '^(utils/welcome\.sh|utils/ascii_welcome\.sh|preseeds/deb_preseed\.bak):' || true)
check "no login, password or vm_pass.txt literal in code" "$(printf '%s' "$lits" | grep -c .)" 0
[ -z "$lits" ] || printf '%s\n' "$lits" | sed 's/^/     /'

exit "$fail"
