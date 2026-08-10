#!/usr/bin/env bash

set -Eeuo pipefail

cd "$(dirname "$0")/.."
work="$(mktemp -d /tmp/sb-acceptance-test.XXXXXX)"
cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT

assert_report_hostname_redacted() {
  local report="$1" raw_hostname
  jq -e '.hostname == "[redacted]"' "$report" >/dev/null
  raw_hostname="$(hostname)"
  if [[ "$raw_hostname" != '[redacted]' ]]; then
    jq -e --arg raw "$raw_hostname" 'all(.. | strings; . != $raw)' "$report" >/dev/null
  fi
}

mkdir -p "$work/bin" "$work/reports"

cat > "$work/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  is-active|is-enabled) exit 0 ;;
  *) exit 0 ;;
esac
EOF

cat > "$work/bin/sing-box" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == check && "${2:-}" == -c && -f "${3:-}" ]]
EOF
cat > "$work/bin/flock" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output=""
url=""
next_is_output=false
for arg in "$@"; do
  if [[ "$next_is_output" == true ]]; then output="$arg"; next_is_output=false; continue; fi
  case "$arg" in
    -o) next_is_output=true ;;
    https://*) url="$arg" ;;
  esac
done
case "$url" in
  */releases/tags/v9.9.9) source="$FAKE_ROOT/release.json" ;;
  */releases/download/v9.9.9/sb-user-manager.sh) source="$FAKE_ROOT/release-asset.sh" ;;
  *) exit 22 ;;
esac
if [[ -n "$output" ]]; then cp "$source" "$output"; else cat "$source"; fi
EOF
chmod 700 "$work/bin/systemctl" "$work/bin/sing-box" "$work/bin/flock" "$work/bin/curl"

printf '{}\n' > "$work/config.json"
printf 'SCRIPT_VERSION=9.9.9\n' > "$work/versions"
printf 'fixture=true\n' > "$work/manager.conf"
chmod 600 "$work/manager.conf"

cat > "$work/manager.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_VERSION="9.9.9"
SCRIPT_EDITION_LABEL="公开版"
MANAGER_REPOSITORY="DTB201/sb-user-manager-public"
MANAGER_ASSET="sb-user-manager.sh"
STATE_SCHEMA_VERSION=3
CONF_FILE="$FAKE_ROOT/manager.conf"
SINGBOX_BIN="$FAKE_ROOT/bin/sing-box"
SINGBOX_CONFIG="$FAKE_ROOT/config.json"
NFUSE_SOCKET="$FAKE_ROOT/nfuse.sock"
STATE_FILE="$FAKE_ROOT/state.json"
LOCK_FILE="$FAKE_ROOT/manager.lock"
printf '{"schema_version":3,"users":%s,"splits":[]}\n' "${FAKE_USERS_JSON:-[]}" > "$STATE_FILE"
load_runtime_config() { :; }
nfuse() {
  [[ "${1:-}" == list && "${2:-}" == --json ]] || return 1
  printf '[]\n'
}
prepare_core() { :; }
release_operation_lock() { :; }
audit_consistency() { AUDIT_ISSUES=0; printf 'fixture consistent\n'; }
verify_environment_backup() {
  [[ -d "$1/root" && -f "$1/SNAPSHOT_VERSION" && -f "$1/SYMLINKS.tsv" && -f "$1/MANIFEST.sha256" ]]
}
snapshot_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
verify_environment_backup_permissions() {
  [[ "$(snapshot_mode "$1")" == 700 && "$(snapshot_mode "$1/root")" == 700 &&
     "$(snapshot_mode "$1/SNAPSHOT_VERSION")" == 600 && "$(snapshot_mode "$1/SYMLINKS.tsv")" == 600 &&
     "$(snapshot_mode "$1/MANIFEST.sha256")" == 600 ]]
}
EOF
chmod 700 "$work/manager.sh"
touch "$work/nfuse.sock"

mkdir -p "$work/backups/20260716-120000-1/root"
printf '1\n' > "$work/backups/20260716-120000-1/SNAPSHOT_VERSION"
: > "$work/backups/20260716-120000-1/SYMLINKS.tsv"
: > "$work/backups/20260716-120000-1/MANIFEST.sha256"
chmod 700 "$work/backups" "$work/backups/20260716-120000-1" "$work/backups/20260716-120000-1/root"
chmod 600 "$work/backups/20260716-120000-1/SNAPSHOT_VERSION" \
  "$work/backups/20260716-120000-1/SYMLINKS.tsv" "$work/backups/20260716-120000-1/MANIFEST.sha256"
cp "$work/manager.sh" "$work/release-asset.sh"
release_digest="$(sha256sum "$work/release-asset.sh" | awk '{print $1}')"
jq -n --arg digest "sha256:${release_digest}" '
  {tag_name:"v9.9.9",draft:false,prerelease:false,
   assets:[{name:"sb-user-manager.sh",browser_download_url:"https://github.com/DTB201/sb-user-manager-public/releases/download/v9.9.9/sb-user-manager.sh",digest:$digest}]}
' > "$work/release.json"

if ! PATH="$work/bin:$PATH" \
  FAKE_ROOT="$work" \
  SB_ACCEPTANCE_TEST_MODE=true \
  SB_ACCEPTANCE_MANAGER="$work/manager.sh" \
  SB_ACCEPTANCE_REPORT_DIR="$work/reports" \
  SB_ACCEPTANCE_VERSIONS_FILE="$work/versions" \
  SB_ACCEPTANCE_LAUNCHER_PATH="$work/manager.sh" \
    bash tests/acceptance.sh audit > "$work/output" 2>&1; then
  cat "$work/output" >&2
  exit 1
fi

report="$(find "$work/reports" -type f -name 'acceptance-audit-*.json' -print -quit)"
[[ -n "$report" ]]
assert_report_hostname_redacted "$report"
jq -e '
  .format_version == 1 and .mode == "audit" and .result == "success" and
  .manager_version == "9.9.9" and .failures == 0 and
  (.checks | length) >= 10 and
  ([.checks[].status] | all(. == "PASS"))
' "$report" >/dev/null
grep -Fq '验收结果：success' "$work/output"

rm -f "$work/reports"/*.json
if ! PATH="$work/bin:$PATH" \
  FAKE_ROOT="$work" \
  SB_ACCEPTANCE_TEST_MODE=true \
  SB_ACCEPTANCE_MANAGER="$work/manager.sh" \
  SB_ACCEPTANCE_REPORT_DIR="$work/reports" \
  SB_ACCEPTANCE_VERSIONS_FILE="$work/versions" \
  SB_ACCEPTANCE_LAUNCHER_PATH="$work/manager.sh" \
  SB_ACCEPTANCE_ENVIRONMENT_BACKUP_BASE="$work/backups" \
    bash tests/acceptance.sh release > "$work/release-output" 2>&1; then
  cat "$work/release-output" >&2
  exit 1
fi
release_report="$(find "$work/reports" -type f -name 'acceptance-release-*.json' -print -quit)"
[[ -n "$release_report" ]]
assert_report_hostname_redacted "$release_report"
jq -e '
  .mode == "release" and .result == "success" and .failures == 0 and
  any(.checks[]; .check == "正式 Release 状态" and .status == "PASS") and
  any(.checks[]; .check == "已安装脚本与 Release 一致" and .status == "PASS") and
  any(.checks[]; .check == "最近完整环境快照校验" and .status == "PASS") and
  any(.checks[]; .check == "最近完整环境快照权限" and .status == "PASS")
' "$release_report" >/dev/null

rm -f "$work/reports"/*.json
chmod 755 "$work/backups/20260716-120000-1"
jq '.assets[0].digest = "sha256:0000000000000000000000000000000000000000000000000000000000000000"' \
  "$work/release.json" > "$work/release-invalid.json"
mv "$work/release-invalid.json" "$work/release.json"
set +e
PATH="$work/bin:$PATH" \
FAKE_ROOT="$work" \
SB_ACCEPTANCE_TEST_MODE=true \
SB_ACCEPTANCE_MANAGER="$work/manager.sh" \
SB_ACCEPTANCE_REPORT_DIR="$work/reports" \
SB_ACCEPTANCE_VERSIONS_FILE="$work/versions" \
SB_ACCEPTANCE_LAUNCHER_PATH="$work/manager.sh" \
SB_ACCEPTANCE_ENVIRONMENT_BACKUP_BASE="$work/backups" \
  bash tests/acceptance.sh release > "$work/release-failure-output" 2>&1
release_failure_rc=$?
set -e
[[ "$release_failure_rc" == 1 ]]
release_failure_report="$(find "$work/reports" -type f -name 'acceptance-release-*.json' -print -quit)"
jq -e '
  .result == "failed" and .failures >= 2 and
  any(.checks[]; .check == "已安装脚本与 Release 一致" and .status == "FAIL") and
  any(.checks[]; .check == "最近完整环境快照权限" and .status == "FAIL")
' "$release_failure_report" >/dev/null
chmod 700 "$work/backups/20260716-120000-1"

rm -f "$work/reports"/*.json
set +e
PATH="$work/bin:$PATH" \
FAKE_ROOT="$work" \
FAKE_USERS_JSON='[{}]' \
SB_ACCEPTANCE_TEST_MODE=true \
SB_ACCEPTANCE_CONFIRM=YES \
SB_ACCEPTANCE_RULESET_URL='https://example.com/rules.srs' \
SB_ACCEPTANCE_MANAGER="$work/manager.sh" \
SB_ACCEPTANCE_REPORT_DIR="$work/reports" \
SB_ACCEPTANCE_VERSIONS_FILE="$work/versions" \
SB_ACCEPTANCE_LAUNCHER_PATH="$work/manager.sh" \
  bash tests/acceptance.sh full > "$work/full-output" 2>&1
full_rc=$?
set -e
[[ "$full_rc" == 1 ]]
full_report="$(find "$work/reports" -type f -name 'acceptance-full-*.json' -print -quit)"
if [[ -z "$full_report" ]]; then cat "$work/full-output" >&2; exit 1; fi
assert_report_hostname_redacted "$full_report"
jq -e '
  .result == "failed" and
  any(.checks[]; .status == "FAIL" and .check == "空机迁移保护")
' "$full_report" >/dev/null

find /tmp -maxdepth 1 -type d -name 'sb-acceptance.*' -print | sort > "$work/acceptance-temp-before"
SB_ACCEPTANCE_LIBRARY=true bash -c 'source tests/acceptance.sh; [[ -z "$WORK" && -z "$RESULTS" ]]'
help_output="$(bash tests/acceptance.sh --help)"
grep -Fq 'lifecycle' <<<"$help_output"
grep -Fq 'release' <<<"$help_output"
grep -Fq 'SB_ACCEPTANCE_VERSIONS_FILE' <<<"$help_output"
grep -Fq 'SB_ACCEPTANCE_LAUNCHER_PATH' <<<"$help_output"
if grep -Fq 'SB_ACCEPTANCE_GITHUB_TOKEN' <<<"$help_output"; then
  echo 'public release acceptance must not request a GitHub token' >&2
  exit 1
fi
if grep -Eq 'state_remove_(outbound|rule)_preset "\$\{SPLIT_NAME\}-' tests/acceptance.sh; then
  echo 'acceptance cleanup must not call preset state removers without runtime tags' >&2
  exit 1
fi
grep -Fq "run_mutation '清理测试预置出口' cmd_outbound_preset_remove" tests/acceptance.sh
grep -Fq "run_mutation '清理测试预置规则' cmd_rule_preset_remove" tests/acceptance.sh
set +e
bash tests/acceptance.sh invalid >/dev/null 2>&1
invalid_rc=$?
set -e
[[ "$invalid_rc" == 2 ]]
find /tmp -maxdepth 1 -type d -name 'sb-acceptance.*' -print | sort > "$work/acceptance-temp-after"
cmp -s "$work/acceptance-temp-before" "$work/acceptance-temp-after"

mutation_marker="$work/mutation-continued"
set +e
SB_ACCEPTANCE_LIBRARY=true ACCEPTANCE_TEST_ROOT="$work/mutation-library" MUTATION_MARKER="$mutation_marker" bash -c '
  source tests/acceptance.sh
  WORK="$ACCEPTANCE_TEST_ROOT"
  RESULTS="$WORK/results.jsonl"
  mkdir -p "$WORK"
  : > "$RESULTS"
  failing_mutation() {
    false
    printf "mutated\n" > "$MUTATION_MARKER"
  }
  run_mutation "强制失败" failing_mutation
' >/dev/null 2>&1
mutation_rc=$?
set -e
[[ "$mutation_rc" != 0 ]]
[[ ! -e "$mutation_marker" ]]

finish_probe="$work/finish-probe"
mkdir -p "$finish_probe"
SB_ACCEPTANCE_LIBRARY=true ACCEPTANCE_TEST_ROOT="$finish_probe" bash -c '
  source tests/acceptance.sh
  WORK="$ACCEPTANCE_TEST_ROOT/runtime"
  RESULTS="$WORK/results.jsonl"
  STATE_FILE="$ACCEPTANCE_TEST_ROOT/state.json"
  mkdir -p "$WORK"
  : > "$RESULTS"
  printf '\''{"schema_version":3,"users":[{}],"splits":[]}\n'\'' > "$STATE_FILE"
  LIVE_STARTED=true
  LIVE_CLEANED=false
  BASELINE_USERS=0
  BASELINE_SPLITS=0
  release_operation_lock() { :; }
  prepare_core() { :; }
  cleanup_live_objects() { :; }
  audit_consistency() { AUDIT_ISSUES=0; }
  if finish_live >/dev/null 2>&1; then
    exit 1
  fi
  [[ "$LIVE_CLEANED" == false ]]
'

finish_audit_probe="$work/finish-audit-probe"
mkdir -p "$finish_audit_probe/runtime"
SB_ACCEPTANCE_LIBRARY=true ACCEPTANCE_TEST_ROOT="$finish_audit_probe" bash -c '
  source tests/acceptance.sh
  WORK="$ACCEPTANCE_TEST_ROOT/runtime"
  RESULTS="$WORK/results.jsonl"
  STATE_FILE="$ACCEPTANCE_TEST_ROOT/state.json"
  LIVE_STARTED=true
  LIVE_CLEANED=false
  BASELINE_USERS=0
  BASELINE_SPLITS=0
  : > "$RESULTS"
  printf '\''{"schema_version":3,"users":[],"splits":[]}\n'\'' > "$STATE_FILE"
  release_operation_lock() { :; }
  prepare_core() { :; }
  cleanup_live_objects() { :; }
  audit_consistency() { AUDIT_ISSUES=0; return 77; }
  if finish_live >/dev/null 2>&1; then exit 1; fi
  [[ "$LIVE_CLEANED" == false && "$FAILURES" == 1 ]]
'

diagnostic_probe="$work/diagnostic-probe"
mkdir -p "$diagnostic_probe/runtime"
SB_ACCEPTANCE_LIBRARY=true ACCEPTANCE_TEST_ROOT="$diagnostic_probe" bash -c '
  source tests/acceptance.sh
  WORK="$ACCEPTANCE_TEST_ROOT/runtime"
  printf '\''secret-sentinel\n'\'' > "$WORK/mutation.log"
  print_mutation_failure_context 其他步骤
' > "$diagnostic_probe/output" 2>&1
[[ ! -s "$diagnostic_probe/output" ]]

handler_probe="$work/handler-probe"
mkdir -p "$handler_probe/reports"
set +e
SB_ACCEPTANCE_LIBRARY=true ACCEPTANCE_TEST_ROOT="$handler_probe" bash -c '
  source tests/acceptance.sh
  WORK="$ACCEPTANCE_TEST_ROOT/runtime"
  RESULTS="$WORK/results.jsonl"
  REPORT_DIR="$ACCEPTANCE_TEST_ROOT/reports"
  STATE_FILE="$ACCEPTANCE_TEST_ROOT/state.json"
  MODE=lifecycle
  SCRIPT_VERSION=4.6.8
  LIVE_STARTED=true
  LIVE_CLEANED=false
  SNAPSHOT="$ACCEPTANCE_TEST_ROOT/snapshot"
  CURRENT_MUTATION_LABEL=恢复单文件迁移备份
  SINGBOX_BIN=true
  SINGBOX_CONFIG="$ACCEPTANCE_TEST_ROOT/config.json"
  mkdir -p "$WORK"
  : > "$RESULTS"
  printf '\''diagnostic-sentinel\n'\'' > "$WORK/mutation.log"
  printf '\''{"schema_version":3,"users":[],"splits":[]}\n'\'' > "$STATE_FILE"
  restore_environment_backup() { printf '\''restored\n'\'' > "$ACCEPTANCE_TEST_ROOT/restored"; }
  release_operation_lock() { :; }
  nfuse() { [[ "${1:-}" == list && "${2:-}" == --json ]] && printf '\''[]\n'\''; }
  systemctl() { return 0; }
  audit_consistency() { AUDIT_ISSUES=0; }
  trap '\''handle_write_failure $?'\'' ERR
  false
' > "$work/handler-output" 2>&1
handler_rc=$?
set -e
[[ "$handler_rc" == 1 ]]
grep -Fxq restored "$handler_probe/restored"
handler_report="$(find "$handler_probe/reports" -type f -name 'acceptance-lifecycle-*.json' -print -quit)"
[[ -n "$handler_report" ]]
assert_report_hostname_redacted "$handler_report"
jq -e '
  .result == "failed" and .failures == 1 and
  .final_counts == {users:0,splits:0} and
  any(.checks[]; .status == "FAIL" and .check == "恢复单文件迁移备份") and
  any(.checks[]; .status == "PASS" and .check == "失败后恢复验收前环境并通过复检")
' "$handler_report" >/dev/null
grep -Fq '失败步骤输出（末尾 80 行）' "$work/handler-output"
grep -Fq 'diagnostic-sentinel' "$work/handler-output"

recheck_probe="$work/recheck-probe"
mkdir -p "$recheck_probe/runtime"
SB_ACCEPTANCE_LIBRARY=true ACCEPTANCE_TEST_ROOT="$recheck_probe" bash -c '
  source tests/acceptance.sh
  WORK="$ACCEPTANCE_TEST_ROOT/runtime"
  RESULTS="$WORK/results.jsonl"
  STATE_FILE="$ACCEPTANCE_TEST_ROOT/state.json"
  LIVE_STARTED=true
  LIVE_CLEANED=false
  SNAPSHOT="$ACCEPTANCE_TEST_ROOT/snapshot"
  SINGBOX_BIN=true
  SINGBOX_CONFIG="$ACCEPTANCE_TEST_ROOT/config.json"
  : > "$RESULTS"
  printf '\''{"schema_version":3,"users":[],"splits":[]}\n'\'' > "$STATE_FILE"
  restore_environment_backup() { :; }
  release_operation_lock() { :; }
  nfuse() { [[ "${1:-}" == list && "${2:-}" == --json ]] && printf '\''[]\n'\''; }
  systemctl() { return 0; }
  audit_consistency() { AUDIT_ISSUES=0; return 77; }
  restore_acceptance_snapshot >/dev/null
  [[ "$LIVE_CLEANED" == false && "$FAILURES" == 1 ]]
  jq -s -e '\''any(.[]; .check == "失败后恢复验收前环境并通过复检" and .status == "FAIL")'\'' "$RESULTS" >/dev/null
'

echo 'acceptance harness checks passed'
