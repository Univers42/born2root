#!/usr/bin/env hellish
# rotate_password_guest.sh — apply the hashes rotate_password.sh uploaded, as
# root in the guest. chpasswd -e writes the shadow lines in one go, restarts the
# aging clock and skips pam_pwquality, which judges a typed password: these are
# hashes, and the host already built them to the policy. Nothing here names a
# value: the file is `name:$6$...` lines, 600, and it is gone when this returns.
set -eu
f="${ROOTSH_HASH_FILE:?the host sets this}"
trap 'rm -f "$f"' EXIT
[ -s "$f" ] || {
    echo "rotate: $f is empty"
    exit 1
}
chpasswd -e <"$f"
cut -d: -f1 "$f" | while read -r user; do
    echo "rotate: $user set, expires: $(LC_ALL=C chage -l "$user" | sed -n 's/^Password expires[[:space:]]*: *//p')"
done
