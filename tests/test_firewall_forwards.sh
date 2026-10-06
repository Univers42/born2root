#!/usr/bin/env hellish
# Regression test: the NAT forwards and the guest's firewall come from one
# list, born2root.toml's [network] forwards, and a firewall that did not come
# up fails the build instead of passing in silence.
#
# The bugs it pins down:
#   * Five literal port lists had drifted apart (qemu_vm.sh's PORTS_SPEC,
#     install_vm_debian.sh's add_natpf calls, orchestrate.sh's
#     ensure_vm_nat_forward calls, fix_app_nat_forwarding.sh and the guest's
#     `ufw allow` lines): QEMU forwarded no FTP passive range, VirtualBox's
#     installer no inception-* rule, and the school profile opened 17 ports in
#     the guest where the subject allows 4242.
#   * Every ufw call in first-boot-setup.sh ended in `>/dev/null 2>&1 || true`:
#     a ufw that failed to enable left a VM with no firewall and a `make all`
#     that reported success.
#   * A VirtualBox NAT rule written with an empty host IP listens on 0.0.0.0,
#     so orchestrate.sh and fix_app_nat_forwarding.sh put the guest on the LAN.
#
# apply_firewall is cut out of first-boot-setup.sh (from `^apply_firewall() {`
# to the next `^}`) and run against a stub ufw, so no VM is needed.
set -u
cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." || exit 1

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-58s = %s\n' "$1" "$2"
    else
        printf 'FAIL %-58s = %s (expected %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ── apply_firewall against a stub ufw ───────────────────────────────────────
eval "$(awk '/^apply_firewall\(\) \{/,/^}/' preseeds/first-boot-setup.sh)"
# shellcheck disable=SC2317 # the stubs are called by the eval'd apply_firewall
ufw() {
    printf '%s\n' "$*" >>"$TMP/ufw.log"
    case "$1" in
    status) cat "$TMP/status" ;;
    esac
}
# shellcheck disable=SC2317 # called by the eval'd apply_firewall
systemctl() { :; }
# shellcheck disable=SC2317 # called by the eval'd apply_firewall
feature_fail() { printf '%s %s\n' "$1" "$2" >>"$TMP/failed"; }

# <B2B_FIREWALL> <what `ufw status` prints> -> apply_firewall's exit code
run() {
    : >"$TMP/ufw.log"
    : >"$TMP/failed"
    printf '%s\n' "$2" >"$TMP/status"
    # shellcheck disable=SC2034 # read by the eval'd apply_firewall
    B2B_FIREWALL="$1"
    if apply_firewall >"$TMP/out" 2>&1; then echo 0; else echo 1; fi
}
status_of() { # <port:name>... -> an active `ufw status` allowing them
    printf 'Status: active\n\nTo                         Action      From\n'
    printf -- '--                         ------      ----\n'
    for r in "$@"; do
        printf '%-26s ALLOW       Anywhere                   # %s\n' "${r%%:*}/tcp" "${r#*:}"
    done
}
logged() { grep -qxF -- "$1" "$TMP/ufw.log" && echo yes || echo no; }

check "all ports open: success" \
    "$(run "ssh:4242 http:80" "$(status_of 4242:ssh 80:http)")" 0
check "  nothing recorded as failed" "$(wc -l <"$TMP/failed" | tr -d ' ')" 0
check "  default deny incoming" "$(logged 'default deny incoming')" yes
check "  each rule is named after its forward" "$(logged 'allow 80/tcp comment http')" yes
check "  ufw is enabled" "$(logged '--force enable')" yes

check "ufw inactive after enable: failure" \
    "$(run "ssh:4242" "Status: inactive")" 1
check "  recorded as the firewall failing" \
    "$(cut -d' ' -f1-5 "$TMP/failed")" "firewall ufw is not active"

check "a configured port missing from ufw: failure" \
    "$(run "ssh:4242 http:80 vault:18200" "$(status_of 4242:ssh)")" 1
check "  names the missing ports" \
    "$(cut -d' ' -f2- "$TMP/failed")" "ufw does not allow 80 18200 (tcp) from [network] forwards"

check "a list without 4242 still opens SSH" \
    "$(run "http:80" "$(status_of 4242:ssh 80:http)")" 0
check "  4242 allowed" "$(logged 'allow 4242/tcp comment ssh')" yes

mkdir -p "$TMP/empty"
nofw=$(
    unset -f ufw
    # shellcheck disable=SC2123 # on purpose: a PATH with no ufw on it
    PATH="$TMP/empty"
    run "ssh:4242" ""
)
check "no ufw binary: failure" "$nofw" 1
check "  says so" "$(cut -d' ' -f2-4 "$TMP/failed")" "ufw is not"

# ── One list: the firewall opens exactly what the host forwards ─────────────
cfg() { env B2B_CONFIG="$1" python3 utils/b2b_config.py "${@:2}"; }
same() { [ "$1" = "$2" ] && echo same || printf '%s\n  vs %s' "$1" "$2"; }
forwarded=$(cfg tests/fixtures/default.toml get B2B_FORWARDS)
check "B2B_FIREWALL is B2B_FORWARDS' name:guest" "$(same \
    "$(cfg tests/fixtures/default.toml get B2B_FIREWALL)" \
    "$(printf '%s\n' "$forwarded" | tr ' ' '\n' | awk -F: '{print $1 ":" $3}' | paste -sd' ')")" same
check "the shipped list has SSH and the FTP passive range" \
    "$(printf '%s\n' "$forwarded" | tr ' ' '\n' | grep -cE '^(ssh:4242:4242|inception-ftp-pasv-)')" 12
check "the school profile opens SSH and nothing else" \
    "$(cfg profiles/school.toml get B2B_FIREWALL)" "ssh:4242"
check "born2root.toml forwards what the fixture forwards" \
    "$(same "$(cfg born2root.toml get B2B_FORWARDS)" "$forwarded")" same

# ── No literal list may come back ───────────────────────────────────────────
# Each pattern is the shape one of the old lists had.
literal() { # <label> <ERE> <file>...
    local hits
    hits=$(grep -nE "$2" "${@:3}" | grep -vE '^[^:]+:[0-9]+:\s*#' || true)
    check "$1" "${hits:-none}" none
}
literal "no literal ensure_vm_nat_forward rule" \
    '^\s*ensure_vm_nat_forward [a-z][a-z0-9-]* [0-9]' generate/orchestrate.sh
literal "no literal add_natpf rule" \
    '^\s*add_natpf [a-z]' setup/install/vms/install_vm_debian.sh
literal "no literal PORTS_SPEC default" \
    'PORTS_SPEC="\$\{PORTS_SPEC:-[a-z]' setup/host/qemu_vm.sh
literal "no literal apply_rule in the NAT repair" \
    '^\s*apply_rule [a-z]' fixes/fix_app_nat_forwarding.sh
literal "no literal ufw port in the guest scripts" \
    'ufw allow [0-9]' preseeds/*.sh setup/install/nvim/*.sh setup/install/hellish/*.sh \
    setup/install/tools/*.sh setup/install/ai/*.sh setup/install/dc/*.sh
literal "no NAT rule on every interface (empty host IP)" \
    'natpf1 "[^"]*,tcp,,' generate/orchestrate.sh setup/host/*.sh \
    setup/install/vms/install_vm_debian.sh fixes/fix_app_nat_forwarding.sh

exit "$fail"
