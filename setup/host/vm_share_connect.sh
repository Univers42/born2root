#!/bin/sh
# vm_share_connect.sh — the colleague's side of make share_invite, for Linux
# and macOS: `sh connect-@ALIAS@.sh`. vm_share.sh fills the @...@ fields in
# per guest (make share_kit); the template itself is never run.
#
# It needs OpenSSH and Tailscale with the invite accepted, and checks the
# second with an ssh that offers no key (PreferredAuthentications=none): the
# VM's sshd answers "Permission denied" when the path is there, so no
# passphrase is asked twice and a timeout means the tailnet, not the key. It
# then uses the private key whose public half is the one the owner
# registered, or makes one and prints it for the owner when none is here
# (an invite without a key leaves PUBKEY empty: a later run finds that key
# accepted once the owner has run make share_key, and connects);
# writes a "Host @ALIAS@" block at the top of ~/.ssh/config, where ssh's
# first-match rule cannot let a "Host *" above it win; and connects.
#
# The block forwards the agent and puts the key in it on first use: a git
# push to GitHub from the VM is signed by this machine's key, the one the
# colleague's GitHub account already knows, and the private half never
# leaves here. Without forwarding the VM has no key, and the push is
# "Permission denied (publickey)" (baas, 2026-10-26). A shell with no agent
# gets one for this session.
#
# Caveat: the address is the VM's tailnet IP when the kit was made. A rebuild
# gives the VM a new node and a new IP, so the owner sends a new kit
# (make share_kit) after one; the old one then times out.
set -u
ALIAS='@ALIAS@'
HOST='@HOST@'
PORT='@PORT@'
LOGIN='@LOGIN@'
PUBKEY='@PUBKEY@'

say() { printf '%s\n' "$*"; }

command -v ssh >/dev/null 2>&1 || {
    say "no ssh here: install OpenSSH (Debian/Ubuntu: sudo apt install openssh-client)"
    exit 1
}
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"

if ! out=$(ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
    -o PreferredAuthentications=none -p "$PORT" "$LOGIN@$HOST" true 2>&1); then
    case "$out" in
    *"Permission denied"*) ;;
    *)
        say "$ALIAS ($HOST:$PORT) does not answer: $(printf '%s\n' "$out" | tail -n1)"
        say "Is Tailscale running and logged in, with the invite mail accepted?"
        say "The machine $ALIAS has to be listed by: tailscale status"
        exit 1
        ;;
    esac
fi

want=$(printf '%s\n' "$PUBKEY" | cut -d' ' -f2)
key=''
for pub in "$HOME"/.ssh/*.pub; do
    [ -f "$pub" ] || continue
    if [ -n "$want" ] && [ "$(head -n1 "$pub" | cut -d' ' -f2)" = "$want" ] && [ -f "${pub%.pub}" ]; then
        key="${pub%.pub}"
        break
    fi
done
new_key=0
if [ -z "$key" ]; then
    key="$HOME/.ssh/id_ed25519_$ALIAS"
    if [ ! -f "$key" ]; then
        say "No key here that $ALIAS knows: making $key (a passphrase is up to you)."
        ssh-keygen -q -t ed25519 -f "$key" -C "$LOGIN@$ALIAS" || exit 1
    fi
    new_key=1
fi

cfg="$HOME/.ssh/config"
begin="# >>> b2b $ALIAS"
end="# <<< b2b $ALIAS"
{
    printf '%s\nHost %s\n    HostName %s\n    Port %s\n    User %s\n' "$begin" "$ALIAS" "$HOST" "$PORT" "$LOGIN"
    printf '    IdentityFile "%s"\n    IdentitiesOnly yes\n' "$key"
    printf '    ForwardAgent yes\n    AddKeysToAgent yes\n%s\n' "$end"
    [ ! -f "$cfg" ] || awk -v b="$begin" -v e="$end" '$0 == b {skip = 1} !skip {print} $0 == e {skip = 0}' "$cfg"
} >"$cfg.b2b-new" && mv "$cfg.b2b-new" "$cfg" && chmod 600 "$cfg"
say "$cfg: Host $ALIAS -> $LOGIN@$HOST:$PORT"

if [ "$new_key" = 1 ] && ssh -o BatchMode=yes -o PreferredAuthentications=publickey "$ALIAS" true 2>/dev/null; then
    new_key=0
fi
if [ "$new_key" = 1 ]; then
    say "Send this line to the owner of $ALIAS, then run this script again:"
    cat "$key.pub"
    exit 0
fi
ssh-add -l >/dev/null 2>&1
if [ "$?" = 2 ]; then
    say "No ssh-agent in this shell, so git push from $ALIAS would have no key: one is started for this session."
    say "Most desktops start one at login; without it, run: eval \"\$(ssh-agent -s)\" before ssh $ALIAS."
    eval "$(ssh-agent -s)" >/dev/null
fi
say "From now on: ssh $ALIAS"
exec ssh "$ALIAS"
