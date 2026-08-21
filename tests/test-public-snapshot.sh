#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=./require-strict-errexit.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/require-strict-errexit.sh"

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sb-public-snapshot-test.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

bash "$ROOT/tools/export-public-snapshot.sh" --output "$WORK/first" >/dev/null
bash "$ROOT/tools/export-public-snapshot.sh" --check "$WORK/first" >/dev/null
bash "$ROOT/tools/export-public-snapshot.sh" --output "$WORK/second" >/dev/null

diff -qr "$WORK/first" "$WORK/second" >/dev/null
[[ -f "$WORK/first/LICENSE" && ! -L "$WORK/first/LICENSE" ]]
[[ -f "$WORK/first/sb-user-manager.sh" && -d "$WORK/first/src" ]]
[[ ! -e "$WORK/first/.git" ]]
[[ ! -e "$WORK/first/sb-user-manager-public.sh" ]]
[[ ! -e "$WORK/first/tools/build-public.sh" ]]
grep -Fxq 'SCRIPT_EDITION_LABEL="公开版"' "$WORK/first/sb-user-manager.sh"

printf 'public source snapshot checks passed\n'
