#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCAN_HISTORY=true
CHECK_PUBLIC_TREE=false
EXTRA_PATTERN_FILE=

usage() {
  cat <<'EOF'
Usage: bash tools/audit-public-readiness.sh [options] [repository]

Options:
  --current-tree              Scan only the current tracked tree.
  --check-public-tree         Also enforce the sanitized public-source policy.
  --extra-pattern-file FILE   Scan for additional exact sensitive values without
                              putting those values in command-line arguments.
  --help                      Show this help.
EOF
}

while (($#)); do
  case "$1" in
    --current-tree)
      SCAN_HISTORY=false
      ;;
    --check-public-tree)
      CHECK_PUBLIC_TREE=true
      ;;
    --extra-pattern-file)
      shift
      (($#)) || { echo 'missing value for --extra-pattern-file' >&2; exit 2; }
      EXTRA_PATTERN_FILE="$1"
      ;;
    --help)
      usage
      exit 0
      ;;
    --*)
      printf 'unknown option: %s\n' "$1" >&2
      exit 2
      ;;
    *)
      ROOT="$1"
      ;;
  esac
  shift
done

ROOT="$(cd "$ROOT" && pwd)"
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  printf 'not a git repository: %s\n' "$ROOT" >&2
  exit 2
}

if [[ -n "$EXTRA_PATTERN_FILE" ]]; then
  [[ -f "$EXTRA_PATTERN_FILE" && ! -L "$EXTRA_PATTERN_FILE" ]] || {
    echo 'extra pattern file must be a regular non-symlink file' >&2
    exit 2
  }
  awk 'NF { found=1 } END { exit found ? 0 : 1 }' "$EXTRA_PATTERN_FILE" || {
    echo 'extra pattern file must contain at least one non-empty value' >&2
    exit 2
  }
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sb-public-audit.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
FAILURES=0

record_failure() {
  local label="$1"
  local result_file="$2"
  FAILURES=$((FAILURES + 1))
  printf 'BLOCKED %s\n' "$label" >&2
  sed 's/^/  /' "$result_file" >&2
}

scan_regex() {
  local label="$1"
  local regex="$2"
  local allowed_path_regex="${3:-}"
  local raw_result_file="$WORK/${label}.raw"
  local result_file="$WORK/${label}.matches"

  if [[ "$SCAN_HISTORY" == true ]]; then
    while IFS= read -r commit; do
      git -C "$ROOT" grep -I -l -E "$regex" "$commit" -- 2>/dev/null || true
    done < <(git -C "$ROOT" rev-list --all)
  else
    git -C "$ROOT" grep -I -l -E "$regex" -- . 2>/dev/null || true
  fi | sed 's/^[^:]*://' | sort -u > "$raw_result_file"

  if [[ -n "$allowed_path_regex" ]]; then
    grep -Ev "$allowed_path_regex" "$raw_result_file" > "$result_file" || true
  else
    cp "$raw_result_file" "$result_file"
  fi

  if [[ -s "$result_file" ]]; then
    record_failure "$label" "$result_file"
  else
    printf 'PASS %s\n' "$label"
  fi
}

scan_fixed_patterns() {
  local label="$1"
  local pattern_file="$2"
  local result_file="$WORK/${label}.matches"

  if [[ "$SCAN_HISTORY" == true ]]; then
    while IFS= read -r commit; do
      git -C "$ROOT" grep -I -l -F -f "$pattern_file" "$commit" -- 2>/dev/null || true
    done < <(git -C "$ROOT" rev-list --all)
  else
    git -C "$ROOT" grep -I -l -F -f "$pattern_file" -- . 2>/dev/null || true
  fi | sed 's/^[^:]*://' | sort -u > "$result_file"

  if [[ -s "$result_file" ]]; then
    record_failure "$label" "$result_file"
  else
    printf 'PASS %s\n' "$label"
  fi
}

private_key_regex='-----BEGIN (RSA |EC |DSA |OPENSSH |PGP )?PRIVATE '"KEY"'-----'
github_token_regex='(github_'"pat"'_|gh[pousr]_)[A-Za-z0-9_]{20,}'
aws_key_regex='AKIA[0-9A-Z]{16}'
google_key_regex='AIza[0-9A-Za-z_-]{35}'
slack_token_regex='xox[baprs]-[0-9A-Za-z-]{10,}'
stripe_key_regex='[rs]k_(live|test)_[0-9A-Za-z]{16,}'
openai_key_regex='sk-[A-Za-z0-9_-]{20,}'
credential_url_regex='https?://[^/@[:space:]]+:[^/@[:space:]]+@'
credential_regex="(${github_token_regex}|${aws_key_regex}|${google_key_regex}|${slack_token_regex}|${stripe_key_regex}|${openai_key_regex}|${credential_url_regex})"

scan_regex private-key "$private_key_regex" '^tests/test-landing-agent\.sh$'
scan_regex credential-signatures "$credential_regex"

path_result="$WORK/sensitive-paths.matches"
if [[ "$SCAN_HISTORY" == true ]]; then
  git -C "$ROOT" log --all --pretty=format: --name-only
else
  git -C "$ROOT" ls-files
fi | sed '/^$/d' | sort -u | grep -E \
  '(^|/)(\.env(\..*)?|id_(rsa|dsa|ecdsa|ed25519)|credentials([^/]*)?|authorized_keys|known_hosts)$|\.(pem|key|p12|pfx|kdbx|sbm)$' \
  > "$path_result" || true
if [[ -s "$path_result" ]]; then
  record_failure sensitive-paths "$path_result"
else
  printf 'PASS sensitive-paths\n'
fi

if [[ -n "$EXTRA_PATTERN_FILE" ]]; then
  scan_fixed_patterns caller-supplied-sensitive-values "$EXTRA_PATTERN_FILE"
fi

if [[ "$CHECK_PUBLIC_TREE" == true ]]; then
  public_result="$WORK/public-source-policy.matches"
  : > "$public_result"
  private_edition_marker='SCRIPT_EDITION_LABEL="私有'"版"'"'
  private_update_heading='## 私有仓库在线'"更新"
  token_name='GITHUB_'"TOKEN"
  token_prompt='prompt_github_'"token"
  auth_header='Authorization: '"Bearer"
  {
    git -C "$ROOT" grep -I -l -F "$private_edition_marker" -- src/00-bootstrap.sh sb-user-manager.sh 2>/dev/null || true
    git -C "$ROOT" grep -I -l -F "$private_update_heading" -- README.md 2>/dev/null || true
    git -C "$ROOT" grep -I -l -F "$token_name" -- src/50-install-update.sh 2>/dev/null || true
    for marker in "$token_prompt" "$auth_header"; do
      git -C "$ROOT" grep -I -l -F "$marker" -- src/50-install-update.sh sb-user-manager.sh 2>/dev/null || true
    done
  } | sort -u >> "$public_result"

  for forbidden_path in \
    sb-user-manager-public.sh \
    tools/build-public.sh \
    tools/public-check-updates.inc; do
    if [[ -e "$ROOT/$forbidden_path" || -L "$ROOT/$forbidden_path" ]]; then
      printf '%s\n' "$forbidden_path" >> "$public_result"
    fi
  done

  [[ -f "$ROOT/LICENSE" && ! -L "$ROOT/LICENSE" ]] || printf '%s\n' LICENSE >> "$public_result"

  workflow_result="$WORK/workflow-policy.matches"
  : > "$workflow_result"
  if [[ -d "$ROOT/.github/workflows" ]]; then
    while IFS= read -r workflow_file; do
      relative_workflow="${workflow_file#"$ROOT/"}"
      grep -Eq '^[[:space:]]*permissions:[[:space:]]*$' "$workflow_file" &&
        grep -Eq '^[[:space:]]*contents:[[:space:]]*read[[:space:]]*$' "$workflow_file" ||
        printf '%s\n' "$relative_workflow" >> "$workflow_result"
      if grep -Eq '\$\{\{[[:space:]]*secrets\.|(^|[[:space:],[])self-hosted([][:space:],]|$)' "$workflow_file"; then
        printf '%s\n' "$relative_workflow" >> "$workflow_result"
      fi
    done < <(find "$ROOT/.github/workflows" -type f \( -name '*.yml' -o -name '*.yaml' \) -print)

    if grep -REl '^[[:space:]]*pull_request_target:' "$ROOT/.github/workflows" > "$WORK/pull-request-target" 2>/dev/null; then
      sed "s#^$ROOT/##" "$WORK/pull-request-target" >> "$workflow_result"
    fi
    while IFS= read -r line; do
      reference="${line#*uses:}"
      reference="${reference#"${reference%%[![:space:]]*}"}"
      [[ "$reference" == ./* ]] && continue
      [[ "$reference" =~ @([0-9a-f]{40})([[:space:]]|$) ]] || printf '%s\n' "$line" >> "$workflow_result"
    done < <(grep -REn '^[[:space:]]*-?[[:space:]]*uses:' "$ROOT/.github/workflows" 2>/dev/null || true)
    while IFS= read -r line; do
      workflow_content="${line#*:}"
      workflow_content="${workflow_content#*:}"
      image_reference="${workflow_content#*:}"
      image_reference="${image_reference#"${image_reference%%[![:space:]]*}"}"
      [[ -z "$image_reference" ]] && continue
      [[ "$image_reference" =~ @sha256:[0-9a-f]{64}([[:space:]]|$) ]] || printf '%s\n' "$line" >> "$workflow_result"
    done < <(grep -REn '^[[:space:]]*(container|image):' "$ROOT/.github/workflows" 2>/dev/null || true)
  fi
  if [[ -s "$workflow_result" ]]; then
    cat "$workflow_result" >> "$public_result"
  fi

  if [[ -s "$public_result" ]]; then
    sort -u "$public_result" -o "$public_result"
    record_failure public-source-policy "$public_result"
  else
    printf 'PASS public-source-policy\n'
  fi
fi

if ((FAILURES)); then
  printf 'public readiness audit failed with %s blocker(s)\n' "$FAILURES" >&2
  exit 1
fi

if [[ "$SCAN_HISTORY" == true ]]; then
  printf 'public readiness history audit passed (%s commits)\n' "$(git -C "$ROOT" rev-list --all --count)"
else
  printf 'public readiness current-tree audit passed\n'
fi
