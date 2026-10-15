#!/usr/bin/env hellish
# The profile's grobase settings reach the guest and survive `make env`.
#
# THE FAILURE IT PINS
#   2026-10-13 audit of baas: seven grobase keys (the DynamoDB data plane,
#   the realtime origins) had been set by hand in /opt/grobase/.env, the file
#   `make env` regenerates, so any re-assembly -- a restore runs one -- lost
#   them, and nothing in the profile could put them back. The grobase commit
#   baas ran was not in the profile either.
#
# WHAT IS CHECKED
#   b2b-grobase-env (installed by install_grobase.sh) upserts build.conf's
#   [dc.grobase_env] into .env.local: a key already there is replaced where
#   it stands, every other line is kept, nothing changes on a second run, a
#   new file is mode 600, an old build.conf gets the two keys born2root always
#   wrote, an empty table touches nothing. install_grobase.sh checks out
#   build.conf's B2B_DC_GROBASE_REF (GROBASE_REF= still wins), runs the helper
#   before `make env`, and writes no grobase key into .env any more. The
#   restore passes ENV_ORPHANS=carry to its `make env`, so a newer grobase
#   never stops an unattended restore on a key only the old .env held.
#
# HOW
#   The helper is cut out of install_grobase.sh by its exact
#   `cat >/usr/local/sbin/b2b-grobase-env <<'GENVEOF'` line, /etc/b2b and
#   /opt/grobase moved under a temp dir. install_grobase.sh itself runs as far
#   as its "tier ... ref" line and stops at a stub docker without compose.
#   The order of its steps is read from the file (line numbers), which pins
#   the order, not that each step works.
set -e

cd "$(dirname "$0")/.."
SRC=setup/install/dc/install_grobase.sh

fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s -- got: %s, expected: %s\n' "$1" "$2" "$3"
        fail=1
    fi
}

TMP=$(mktemp -d)
trap 'rm -rf "${TMP:?}"' EXIT
mkdir -p "$TMP/etc/b2b" "$TMP/opt/grobase" "$TMP/bin"
awk "/^cat >\/usr\/local\/sbin\/b2b-grobase-env <<'GENVEOF'\$/ { on = 1; next } /^GENVEOF\$/ { on = 0 } on" "$SRC" |
    sed -e "s#/opt/grobase#$TMP/opt/grobase#g" -e "s#/etc/b2b#$TMP/etc/b2b#g" >"$TMP/b2b-grobase-env"
[ -s "$TMP/b2b-grobase-env" ] || {
    echo "FAIL could not extract b2b-grobase-env from $SRC"
    exit 1
}
chmod +x "$TMP/b2b-grobase-env"
GENV="$TMP/b2b-grobase-env"
LOCAL="$TMP/opt/grobase/.env.local"
BUILD="$TMP/etc/b2b/build.conf"

# ── the helper ──────────────────────────────────────────────────────────────
cat >"$BUILD" <<'EOF'
B2B_LOGIN="tester"
B2B_DC_GROBASE_ENV="DATA_PLANE_FEATURES DYNAMODB_ENGINE_ENABLED ORG_MODEL_ENABLED"
B2B_DC_GROBASE_ENV_DATA_PLANE_FEATURES="--features dynamodb"
B2B_DC_GROBASE_ENV_DYNAMODB_ENGINE_ENABLED="1"
B2B_DC_GROBASE_ENV_ORG_MODEL_ENABLED="true"
EOF
"$GENV" >/dev/null
check "no .env.local yet: created with the table's lines" \
    "$(cat "$LOCAL")" "DATA_PLANE_FEATURES=--features dynamodb
DYNAMODB_ENGINE_ENABLED=1
ORG_MODEL_ENABLED=true"
check "  mode 600 (grobase's own .env.local is)" "$(stat -c %a "$LOCAL")" 600

cat >"$LOCAL" <<'EOF'
# .env.local -- yours
FLY_TOKEN=fake-not-a-token
ORG_MODEL_ENABLED=false
GROBASE_PUBLIC_ADDRESSES=node.example.ts.net
ORG_MODEL_ENABLED=stale-duplicate
EOF
chmod 640 "$LOCAL"
"$GENV" >/dev/null
check "an existing file: a key is replaced where it stands, the rest kept" \
    "$(cat "$LOCAL")" "# .env.local -- yours
FLY_TOKEN=fake-not-a-token
ORG_MODEL_ENABLED=true
GROBASE_PUBLIC_ADDRESSES=node.example.ts.net
DATA_PLANE_FEATURES=--features dynamodb
DYNAMODB_ENGINE_ENABLED=1"
check "  its mode is left alone" "$(stat -c %a "$LOCAL")" 640
cp "$LOCAL" "$TMP/first"
"$GENV" >/dev/null
check "a second run changes nothing" "$(cmp -s "$TMP/first" "$LOCAL" && echo same)" same

"$GENV" "REALTIME_ALLOWED_ORIGINS=https://a.example,http://localhost:5173" >/dev/null
check "KEY=VALUE arguments: those, upserted the same way" \
    "$(grep -c '^REALTIME_ALLOWED_ORIGINS=https://a.example,http://localhost:5173$' "$LOCAL") $(grep -c . "$LOCAL")" "1 7"

printf 'B2B_LOGIN="tester"\n' >"$BUILD"
rm -f "$LOCAL"
"$GENV" >/dev/null
check "a build.conf from before the key: the two born2root always wrote" \
    "$(cat "$LOCAL")" "CATALOG_MANAGEMENT=static
REMOTE_ACCESS=1"

printf 'B2B_LOGIN="tester"\nB2B_DC_GROBASE_ENV=""\n' >"$BUILD"
printf 'KEEP=1\n' >"$LOCAL"
cp "$LOCAL" "$TMP/before"
"$GENV" >/dev/null
check "an empty table touches nothing" "$(cmp -s "$TMP/before" "$LOCAL" && echo same)" same
rm -f "$LOCAL"
"$GENV" >/dev/null
check "  and creates nothing" "$([ -e "$LOCAL" ] && echo created || echo absent)" absent

# ── install_grobase.sh: the ref ─────────────────────────────────────────────
# Runs until `docker compose version` fails: everything before it only reads.
printf '#!/bin/sh\necho 0\n' >"$TMP/bin/id"
printf '#!/bin/sh\nexit 1\n' >"$TMP/bin/docker"
chmod +x "$TMP/bin/id" "$TMP/bin/docker"
sed -e "s#/etc/b2b#$TMP/etc/b2b#g" "$SRC" >"$TMP/install_grobase.sh"
ref_of() { # <build.conf line> [GROBASE_REF] -> the ref the tier line names
    printf 'B2B_DC_PACKAGE=pro\n%s\n' "$1" >"$BUILD"
    env -u GROBASE_REF ${2:+GROBASE_REF="$2"} PATH="$TMP/bin:$PATH" \
        "${SCRIPT_SH:-bash}" "$TMP/install_grobase.sh" 2>/dev/null | sed -n 's/.*  ref: //p'
}
# shellcheck disable=SC2016 # literal ${GROBASE_REF:-…} in the matched text, not an expansion
PIN=$(sed -n 's/^GROBASE_REF="${GROBASE_REF:-\([0-9a-f]*\)}"$/\1/p' "$SRC")
check "the script still carries its own pin" "${#PIN}" 40
check "no B2B_DC_GROBASE_REF: that pin" "$(ref_of '')" "$PIN"
check "an empty one: that pin" "$(ref_of 'B2B_DC_GROBASE_REF=')" "$PIN"
check "the profile's ref" "$(ref_of 'B2B_DC_GROBASE_REF=dab5f43060aab2914183173c91dc7a39a7aab9f6')" \
    dab5f43060aab2914183173c91dc7a39a7aab9f6
check "GROBASE_REF= beats the profile" \
    "$(ref_of 'B2B_DC_GROBASE_REF=dab5f43060aab2914183173c91dc7a39a7aab9f6' 0123456789abcdef0123456789abcdef01234567)" \
    0123456789abcdef0123456789abcdef01234567
check "a branch reaches the script as the branch" "$(ref_of 'B2B_DC_GROBASE_REF=main')" main

# ── install_grobase.sh: a branch is followed ────────────────────────────────
# The block that turns a branch into its newest SHA, cut out by its
# `case "$GROBASE_REF" in` .. `esac` lines and run against a local remote that
# moves after the clone, as grobase's main does between two `make grobase`.
FOLLOW=$(awk '/^case "\$GROBASE_REF" in$/,/^esac$/' "$SRC")
check "the branch block is extractable" "$([ -n "$FOLLOW" ] && echo found)" found
G() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }
G init -q --bare "$TMP/remote.git"
G clone -q "$TMP/remote.git" "$TMP/work" 2>/dev/null
G -C "$TMP/work" commit -q --allow-empty -m one
G -C "$TMP/work" push -q origin HEAD:main HEAD:develop
G clone -q --depth 100 "file://$TMP/remote.git" "$TMP/clone" 2>/dev/null
G -C "$TMP/work" commit -q --allow-empty -m two
G -C "$TMP/work" push -q origin HEAD:main
NEWEST=$(G -C "$TMP/work" rev-parse HEAD)
DEVELOP=$(G -C "$TMP/remote.git" rev-parse refs/heads/develop)
follow() { # <GROBASE_REF> -> the ref after the block, or "died: …"
    # shellcheck disable=SC2317,SC2329,SC2034 # log, die and the two dirs are read by the eval'd block
    (
        log() { :; }
        die() {
            echo "died: $*"
            exit 1
        }
        GROBASE_DIR="$TMP/clone" GROBASE_REPO=test GROBASE_REF="$1"
        eval "$FOLLOW"
        echo "$GROBASE_REF"
    )
}
check "main: the commit pushed after the clone" "$(follow main)" "$NEWEST"
check "a branch the single-branch clone never tracked" "$(follow develop)" "$DEVELOP"
check "a full SHA is left alone" "$(follow 0123456789abcdef0123456789abcdef01234567)" \
    0123456789abcdef0123456789abcdef01234567
check "a missing branch stops the install, naming it" "$(follow nope 2>/dev/null)" \
    "died: branch nope not found in test"

# ── install_grobase.sh: the order ───────────────────────────────────────────
first_env=$(grep -n '^make --no-print-directory env' "$SRC" | head -n1 | cut -d: -f1)
helper=$(grep -n '^genv_out=.(/usr/local/sbin/b2b-grobase-env)' "$SRC" | head -n1 | cut -d: -f1)
check "the profile's keys are in .env.local before the first make env" \
    "$([ -n "$helper" ] && [ -n "$first_env" ] && [ "$helper" -lt "$first_env" ] && echo before)" before
check "nothing but the helper writes .env or .env.local (make env would drop it)" \
    "$(grep -vE '^[[:space:]]*#' "$SRC" | grep -cE '(>>?|sed -i.*)[[:space:]]*\.env(\.local)?$' || true)" 0

# ── the restore: an unattended `make env` carries orphans, never stops ──────
RESTORE=setup/install/dc/install_backup.sh
check "every make env in the restore passes ENV_ORPHANS=carry" \
    "$(grep -vE '^[[:space:]]*#' "$RESTORE" | grep -E 'make --no-print-directory env' | grep -cv 'ENV_ORPHANS=carry' || true)" 0
check "the restore runs make env at all" \
    "$(grep -cE 'ENV_ORPHANS=carry make --no-print-directory env' "$RESTORE")" 1

exit "$fail"
