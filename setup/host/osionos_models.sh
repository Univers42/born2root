#!/usr/bin/env hellish
# osionos_models.sh -- run groot's models runner inside the guest, against the
# grobase Postgres there (make osionos_models; CHECK=1 for --check).
#
#   make osionos_models                       apply every models/*.sql
#   make osionos_models CHECK=1               report what is missing, change nothing
#   make osionos_models GROOT_DIR=~/src/groot another checkout (default ../groot)
#
# The osionos bridge and app need tables that only groot's models/ define
# (public.auth_session_cutoffs and the rest). A rebuilt baas has grobase but
# none of them, and the bridge answered 503 to every session until the one
# missing file was piped in by hand (2026-10-21). groot's own runner
# (scripts/apply-models-migrations.sh: its order, its skip list, the realtime
# CDC check) is the one source of truth, so this ships that script and
# models/ to the guest as a tar stream and runs it there, from a temporary
# directory removed afterwards. Nothing of groot is copied into this repo.
#
# Caveat: --check is groot's floor, not a diff (a missing column hides behind
# an existing table), and a groot checkout older than 8c5116e5 matches only
# lower-case CREATE TABLE under the guest's mawk; apply mode runs every file
# either way, so it is the one that repairs.
set -u
# shellcheck source=setup/host/dc_lib.sh
. "$(dirname "$0")/dc_lib.sh"
groot="${GROOT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)/../groot}"
mode=
case "${1:-}" in
'') ;;
--check) mode=--check ;;
*) die "usage: osionos_models.sh [--check]" ;;
esac
if [ ! -f "$groot/scripts/apply-models-migrations.sh" ] || [ ! -d "$groot/models" ]; then
    die "no groot checkout at $groot (scripts/apply-models-migrations.sh + models/): make osionos_models GROOT_DIR=/path/to/groot"
fi
dc_connect
info "groot models from $groot -> $VM_NAME${mode:+ ($mode)}"
# The guest command is expanded there; \$d is the guest's temporary directory.
tar -C "$groot" -cf - scripts/apply-models-migrations.sh models |
    vm_ssh "d=\$(mktemp -d) && tar -xf - -C \"\$d\" && sh \"\$d/scripts/apply-models-migrations.sh\" $mode; rc=\$?; rm -rf \"\$d\"; exit \$rc"
