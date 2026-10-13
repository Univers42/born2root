#!/usr/bin/env hellish
# grobase_expose_guest.sh -- runs INSIDE the guest, as the login. tailnet.sh
# pipes it over SSH as `bash -s -- <ts.net name> [<tailnet IPv4>]` once the
# node serves: grobase's own `make expose`, told exactly this node's
# addresses. expose.sh writes them to .env.local (GROBASE_PUBLIC_ADDRESSES),
# re-assembles .env, re-issues the server certificate with them as SANs from
# the CA already there, and recreates kong, gotrue and the WAF.
#
#   --no-detect --replace  exactly these two: not the guest's NAT address,
#                          and not the old node's name and address a restored
#                          .env.local still lists (baas had only the two)
#   --no-trust             nothing in the guest browses; trusting the CA
#                          there would want sudo for nothing
#
# A list that is already right is left alone: expose recreates three
# containers every time it runs. A grobase without scripts/ops/expose.sh
# (d180542, install_grobase.sh's default pin) is skipped with a note.
set -eu
[ -n "${1:-}" ] || {
    echo "usage: grobase_expose_guest.sh <ts.net name> [<ipv4>]" >&2
    exit 2
}
cd "${GROBASE_DIR:-/opt/grobase}"
if [ ! -f scripts/ops/expose.sh ]; then
    echo "[grobase] expose: this grobase has no scripts/ops/expose.sh; GROBASE_PUBLIC_ADDRESSES left as it is"
    exit 0
fi
want="$1${2:+,$2}"
have=$(sed -n 's/^GROBASE_PUBLIC_ADDRESSES=//p' .env.local 2>/dev/null | tail -n1)
if [ "$have" = "$want" ]; then
    echo "[grobase] expose: GROBASE_PUBLIC_ADDRESSES=$want already"
    exit 0
fi
make --no-print-directory expose ARGS="--no-detect --replace --no-trust --add $1${2:+ --add $2}"
