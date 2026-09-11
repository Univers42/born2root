#!/usr/bin/env hellish
# Is this build encrypted, and what does that imply for the rest of the build?
#
# born2root's mandatory part requires encrypted LVM, so LUKS=ON is the default
# and is the only mode that produces a submittable VM. LUKS=OFF exists for one
# reason: measuring disk behaviour with dm-crypt out of the path. Encrypted,
# a freed block is ciphertext, so `qemu-img convert` cannot tell it from live
# data and TRIM is the only way to reclaim anything; unencrypted, a freed block
# is zeroes and the image can be compacted offline. That difference is worth
# being able to test, and worth never shipping by accident.
#
# The mode is decided once, here, because four different places need to agree
# about it and they do not run in the same process:
#
#   generate/create_custom_iso.sh   swaps the crypto region out of the preseed
#   setup/host/qemu_vm.sh           finds the ISO to boot
#   setup/host/qemu_pipeline.sh     decides whether to rebuild the ISO
#   generate/orchestrate.sh         prints the credentials summary
#
# If any of them disagreed, the failure would be silent and expensive: an ISO
# built unencrypted, booted by a run that believes it is encrypted, producing a
# VM that fails the evaluation for a reason nothing on screen mentions. So the
# ISO filename carries the mode (`-nocrypt`), which makes a mismatch impossible
# to cache into and visible in `ls`.
#
#   . utils/luks_mode.sh
#   luks_enabled "$LUKS"            && echo encrypted
#   suffix=$(luks_iso_suffix "$LUKS")
#
#   utils/luks_mode.sh --banner "$LUKS"     (warns, exits 0)
#   utils/luks_mode.sh --suffix "$LUKS"     (prints "" or "-nocrypt")

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    _LM_YLW=$'\033[33m' _LM_RED=$'\033[31m' _LM_BLD=$'\033[1m' _LM_OFF=$'\033[0m'
else
    _LM_YLW='' _LM_RED='' _LM_BLD='' _LM_OFF=''
fi

# Anything that is not recognisably "off" is treated as ON. The asymmetry is
# deliberate: a typo (LUKS=Off1, LUKS=flase) must not quietly hand in an
# unencrypted VM, so the safe mode is the one that catches everything unclear.
luks_enabled() {
    case "$(printf '%s' "${1:-ON}" | tr '[:upper:]' '[:lower:]')" in
    off | 0 | no | false | disable | disabled) return 1 ;;
    *) return 0 ;;
    esac
}

# Appended to the ISO basename so the two modes can never collide in the
# repo root. create_custom_iso.sh skips the build when its output already
# exists, so without this a LUKS=OFF run would happily reuse an encrypted ISO.
luks_iso_suffix() {
    if luks_enabled "${1:-ON}"; then
        printf ''
    else
        printf -- '-nocrypt'
    fi
}

# The glob that finds this mode's ISO in the repo root. Exclusive in both
# directions by construction: "*preseed.iso" cannot match a name ending in
# "-preseed-nocrypt.iso", so neither mode can boot the other's image, and a
# repo holding both stays unambiguous.
luks_iso_glob() {
    printf 'debian-*-amd64-*preseed%s.iso' "$(luks_iso_suffix "${1:-ON}")"
}

# Printed by `make all` before anything is downloaded or written, so there is
# no way to sit through a 40-minute unencrypted build thinking otherwise.
luks_banner() {
    luks_enabled "${1:-ON}" && return 0

    printf '%s\n' "${_LM_YLW}┌──────────────────────────────────────────────────────────────┐${_LM_OFF}" >&2
    printf '%s\n' "${_LM_YLW}│${_LM_OFF} ${_LM_RED}${_LM_BLD}LUKS=OFF — this VM will NOT be encrypted.${_LM_OFF}                    ${_LM_YLW}│${_LM_OFF}" >&2
    printf '%s\n' "${_LM_YLW}│${_LM_OFF}                                                              ${_LM_YLW}│${_LM_OFF}" >&2
    printf '%s\n' "${_LM_YLW}│${_LM_OFF} Encrypted LVM is a born2root MANDATORY requirement. A VM     ${_LM_YLW}│${_LM_OFF}" >&2
    printf '%s\n' "${_LM_YLW}│${_LM_OFF} built this way FAILS the evaluation. Use it to measure disk  ${_LM_YLW}│${_LM_OFF}" >&2
    printf '%s\n' "${_LM_YLW}│${_LM_OFF} usage without dm-crypt in the way, then throw it away.       ${_LM_YLW}│${_LM_OFF}" >&2
    printf '%s\n' "${_LM_YLW}│${_LM_OFF}                                                              ${_LM_YLW}│${_LM_OFF}" >&2
    printf '%s\n' "${_LM_YLW}│${_LM_OFF} The ISO is written as *-nocrypt.iso so it cannot be mistaken ${_LM_YLW}│${_LM_OFF}" >&2
    printf '%s\n' "${_LM_YLW}│${_LM_OFF} for the real one. Build the VM you hand in with LUKS=ON.     ${_LM_YLW}│${_LM_OFF}" >&2
    printf '%s\n' "${_LM_YLW}└──────────────────────────────────────────────────────────────┘${_LM_OFF}" >&2
    return 0
}

# Run as a command (not sourced)? Dispatch. Sourcing must not trigger this.
case "${1:-}" in
--banner) luks_banner "${2:-ON}" ;;
--suffix) luks_iso_suffix "${2:-ON}" ;;
--glob) luks_iso_glob "${2:-ON}" ;;
--enabled) luks_enabled "${2:-ON}" ;;
esac
