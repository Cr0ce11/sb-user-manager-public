#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AUDITOR="$ROOT/tools/audit-public-readiness.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sb-public-audit-test.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

repo="$WORK/repo"
mkdir -p "$repo/.github/workflows" "$repo/src"
git -C "$repo" init -q
git -C "$repo" config user.name public-audit-test
git -C "$repo" config user.email public-audit-test@users.noreply.github.com

cat > "$repo/LICENSE" <<'EOF'
test license
EOF
cat > "$repo/README.md" <<'EOF'
clean public fixture
EOF
cat > "$repo/src/00-bootstrap.sh" <<'EOF'
SCRIPT_EDITION_LABEL="公开版"
EOF
cat > "$repo/sb-user-manager.sh" <<'EOF'
#!/usr/bin/env bash
printf 'fixture\n'
EOF
cat > "$repo/.github/workflows/ci.yml" <<'EOF'
name: CI
on: [push]
permissions:
  contents: read
jobs:
  test:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@1111111111111111111111111111111111111111
      - name: Read immutable release setting
        env:
          GH_TOKEN: ${{ secrets.IMMUTABLE_RELEASES_READ_TOKEN }}
        run: test -n "$GH_TOKEN"
EOF
git -C "$repo" add .
git -C "$repo" commit -qm 'clean fixture'

bash "$AUDITOR" --check-public-tree "$repo" > "$WORK/clean-output"
grep -Fq 'public readiness history audit passed' "$WORK/clean-output"

fake_token='gh'"p_"'abcdefghijklmnopqrstuvwxyz1234567890'
printf '%s\n' "$fake_token" > "$repo/deleted-secret.txt"
git -C "$repo" add deleted-secret.txt
git -C "$repo" commit -qm 'add secret fixture'
git -C "$repo" rm -q deleted-secret.txt
git -C "$repo" commit -qm 'remove secret fixture'

if bash "$AUDITOR" "$repo" > "$WORK/history-output" 2>&1; then
  echo 'history audit must reject a credential signature removed from the current tree' >&2
  exit 1
fi
grep -Fq 'BLOCKED credential-signatures' "$WORK/history-output"
grep -Fq 'deleted-secret.txt' "$WORK/history-output"

bash "$AUDITOR" --current-tree --check-public-tree "$repo" > "$WORK/current-output"
grep -Fq 'public readiness current-tree audit passed' "$WORK/current-output"

printf '%s\n' 'private-known-value-for-audit' > "$WORK/extra-patterns"
printf '%s\n' 'private-known-value-for-audit' > "$repo/known-value.txt"
git -C "$repo" add known-value.txt
if bash "$AUDITOR" --current-tree --extra-pattern-file "$WORK/extra-patterns" "$repo" > "$WORK/extra-output" 2>&1; then
  echo 'caller-supplied sensitive values must be detected' >&2
  exit 1
fi
grep -Fq 'BLOCKED caller-supplied-sensitive-values' "$WORK/extra-output"

git -C "$repo" rm -q --cached known-value.txt
rm -f "$repo/known-value.txt" "$repo/LICENSE"
printf '%s\n' 'SCRIPT_EDITION_LABEL="私有版"' > "$repo/src/00-bootstrap.sh"
mkdir -p "$repo/tools"
printf '%s\n' '# obsolete dual-version builder' > "$repo/tools/build-public.sh"
git -C "$repo" add tools/build-public.sh
cat > "$repo/.github/workflows/ci.yml" <<'EOF'
name: CI
on: [push]
permissions:
  contents: read
jobs:
  test:
    runs-on: ubuntu-24.04
    env:
      UNSAFE_TOKEN: ${{ secrets.ANOTHER_REPOSITORY_TOKEN }}
    steps:
      - uses: actions/checkout@v7
EOF
if bash "$AUDITOR" --current-tree --check-public-tree "$repo" > "$WORK/policy-output" 2>&1; then
  echo 'public source policy must reject private edition markers and a missing license' >&2
  exit 1
fi
grep -Fq 'BLOCKED public-source-policy' "$WORK/policy-output"
grep -Fq 'src/00-bootstrap.sh' "$WORK/policy-output"
grep -Fq 'LICENSE' "$WORK/policy-output"
grep -Fq 'tools/build-public.sh' "$WORK/policy-output"
grep -Fq '.github/workflows/ci.yml' "$WORK/policy-output"

echo 'public readiness audit checks passed'
