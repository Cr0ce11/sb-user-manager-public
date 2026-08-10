#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
WORK="$(mktemp -d /tmp/sb-manager-build-test.XXXXXX)"
trap 'rm -rf -- "$WORK"' EXIT

bash "$ROOT/tools/build-manager.sh" --check
bash "$ROOT/tools/build-manager.sh" --output "$WORK/first.sh" >/dev/null
bash "$ROOT/tools/build-manager.sh" --output "$WORK/second.sh" >/dev/null

cmp -s "$WORK/first.sh" "$WORK/second.sh"
cmp -s "$WORK/first.sh" "$ROOT/sb-user-manager.sh"
bash -n "$WORK/first.sh"

manager_hash="$(shasum -a 256 "$ROOT/sb-user-manager.sh" | awk '{print $1}')"
first_hash="$(shasum -a 256 "$WORK/first.sh" | awk '{print $1}')"
second_hash="$(shasum -a 256 "$WORK/second.sh" | awk '{print $1}')"
[[ "$manager_hash" == "$first_hash" && "$first_hash" == "$second_hash" ]]

mode="$(stat -c '%a' "$WORK/first.sh" 2>/dev/null || stat -f '%Lp' "$WORK/first.sh")"
[[ "$mode" == 755 ]]

echo "deterministic manager build checks passed"
