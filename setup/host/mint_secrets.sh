#!/usr/bin/env hellish
# mint_secrets.sh — give every `secret:NAME` of the profile a value, before the
# ISO is rendered with it.
#
# A profile says `luks_passphrase = "secret:BAAS_LUKS_PASSPHRASE"` because this
# repository is public: tempencrypt123 and temproot123 are one search away, and
# the disk they guard holds restic's password and every tenant's data. The
# value lives in the secrets file (dc_lib.sh, mode 600, read and never sourced).
#
# It mints only what is absent, and never for a VM that is already installed: a
# new passphrase would not open the disk built with the old one, so a lost line
# on a built machine stops here and names the fix instead of locking the disk.
#
# It also makes this machine an ssh key when the guest will take nothing else.
#
#   make secrets_mint        what `make gen_iso` runs first; a no-op without refs
set -u

# shellcheck source=setup/host/dc_lib.sh
. "$(dirname "${BASH_SOURCE[0]:-$0}")/dc_lib.sh"

# A keys-only guest bakes this machine's public key at ISO time and nothing else
# reaches it, so a new machine with no key would build a VM that it cannot enter.
ensure_host_key() {
    [ "$(b2b_get B2B_SSH_PASSWORD_LOGIN)" = no ] || return 0
    if [ -e "$HOME/.ssh/id_ed25519.pub" ] || [ -e "$HOME/.ssh/id_rsa.pub" ]; then
        return 0
    fi
    (umask 077 && mkdir -p "$HOME/.ssh") || die "cannot create $HOME/.ssh"
    ssh-keygen -q -t ed25519 -N '' -C "$(id -un)@$(hostname)" -f "$HOME/.ssh/id_ed25519" </dev/null ||
        die "ssh-keygen could not make $HOME/.ssh/id_ed25519"
    ok "made $HOME/.ssh/id_ed25519: this guest takes keys only, and this machine had none"
}
ensure_host_key

refs=$(b2b_secret_refs) || die "cannot read the profile: fix what --check names"
[ -n "$refs" ] || exit 0

installed="${VM_PATH:-$DC_ROOT/disk_images}/$VM_NAME/.installed"
minted=0
while read -r name kind; do
    [ -n "$name" ] || continue
    [ -z "$(secret_get "$name")" ] || continue
    [ ! -e "$installed" ] || die "$name is not in $SECRETS_FILE, and $VM_NAME is built: the disk answers to the value it was built with, so a new one would lock it. Put that line back (make secrets_pull APPLY=1 KEYS=$name, or your password manager)"
    case "$kind" in
    luks) value=$(mint_luks_passphrase) ;;
    *) value=$(mint_login_password) ;;
    esac
    [ -n "$value" ] || die "openssl could not mint $name"
    secret_set "$name" "$value"
    minted=$((minted + 1))
    ok "minted $name ($kind) into $SECRETS_FILE"
done <<REFS
$refs
REFS
if [ "$minted" -gt 0 ]; then
    warn "copy those lines to a password manager, or make secrets_push: without $SECRETS_FILE this disk cannot be opened"
fi
exit 0
