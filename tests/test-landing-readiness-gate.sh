#!/usr/bin/env bash
# 测试桩由生产编排函数按名称动态调用。
# shellcheck disable=SC2034,SC2317
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME="${SB_LANDING_READINESS_RUNTIME:-$ROOT/sb-user-manager.sh}"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

fail() {
  printf 'landing readiness gate test failed: %s\n' "$1" >&2
  exit 1
}

export SB_USER_MANAGER_LIBRARY=true
export SB_CONTROLLER_STATE_FILE="$work/controller-state/controller-state.json"
export SB_CONTROLLER_SECRET_DIR="$work/controller-secrets"
export SB_CONTROLLER_STATE_LOCK_FILE="$work/controller-lock/controller-state.lock"
export SB_CONTROLLER_LANDING_WORK_ROOT="$work/controller-work"
export SB_CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE="$work/controller-state/controller-onboarding.json"
export SB_CONTROLLER_LANDING_ONBOARDING_LOCK_FILE="$work/controller-lock/controller-onboarding.lock"
# shellcheck source=../sb-user-manager.sh
source "$RUNTIME"

for function_name in controller_landing_readiness_reset_result \
  controller_landing_readiness_create_phase_directories \
  controller_landing_readiness_pending_recovery_exists \
  controller_prepare_landing_readiness; do
  declare -F "$function_name" >/dev/null 2>&1 || fail "missing function: $function_name"
done

fingerprint="SHA256:$(printf 'A%.0s' {1..43})"
singbox_sha="$(printf 'b%.0s' {1..64})"
call_log="$work/calls"
: > "$call_log"

record_call() {
  printf '%s\n' "$1" >> "$call_log"
}

reset_controller_state() {
  mkdir -p "$(dirname "$SB_CONTROLLER_STATE_FILE")"
  chmod 700 "$(dirname "$SB_CONTROLLER_STATE_FILE")"
  printf '%s\n' \
    '{"schema_version":1,"role":"entry-controller","revision":0,"landings":[]}' \
    > "$SB_CONTROLLER_STATE_FILE"
  chmod 600 "$SB_CONTROLLER_STATE_FILE"
  validate_controller_state_file "$SB_CONTROLLER_STATE_FILE" ||
    fail 'could not reset controller state'
}

reset_case() {
  : > "$call_log"
  TEST_TRANSPORT_RC=0
  TEST_DISCOVER_RC=0
  TEST_DISCOVER_VALUE="$fingerprint"
  TEST_CONFIRM_RC=0
  TEST_DEPENDENCY_RC=0
  TEST_DEPENDENCY_STATUS=ready
  TEST_DEPENDENCY_DETAIL=""
  TEST_SINGBOX_RC=0
  TEST_SINGBOX_STATUS=installed
  TEST_SINGBOX_DETAIL=""
  TEST_SINGBOX_VERSION=1.12.3
  TEST_SINGBOX_SHA256="$singbox_sha"
  TEST_CLEANUP_RC=0
  TEST_GATE_WORK=""
  TEST_DEPENDENCY_WORK=""
  TEST_SINGBOX_WORK=""
  rm -rf -- "$SB_CONTROLLER_LANDING_WORK_ROOT" "$SB_CONTROLLER_SECRET_DIR"
  rm -f -- "$SB_CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE" \
    "${SB_CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE}.next"
  reset_controller_state
}

run_gate() {
  if controller_prepare_landing_readiness "${1:-1.1.1.1}" "${2:-22}" \
      "${3:-landing-a}"; then
    GATE_RC=0
  else
    GATE_RC=$?
  fi
}

expect_stage() {
  [[ "$CONTROLLER_LANDING_READINESS_LAST_STAGE" == "$1" ]] ||
    fail "expected stage $1, got $CONTROLLER_LANDING_READINESS_LAST_STAGE"
}

expect_calls() {
  local actual
  actual="$(<"$call_log")"
  [[ "$actual" == "$1" ]] || fail "unexpected calls: expected [$1], got [$actual]"
}

expect_work_removed() {
  [[ -n "$TEST_GATE_WORK" && ! -e "$TEST_GATE_WORK" && ! -L "$TEST_GATE_WORK" ]] ||
    fail 'readiness work directory was not removed'
}

controller_landing_dependency_settings_are_safe() { return 0; }
controller_landing_singbox_settings_are_safe() { return 0; }
controller_landing_transport_runtime_is_safe() { return "$TEST_TRANSPORT_RC"; }

controller_landing_discover_fingerprint() {
  record_call discover
  ((TEST_DISCOVER_RC == 0)) || return "$TEST_DISCOVER_RC"
  printf '%s\n' "$TEST_DISCOVER_VALUE"
}

controller_confirm_landing_fingerprint() {
  record_call confirm
  return "$TEST_CONFIRM_RC"
}

controller_landing_prepare_dependencies_in_work() {
  record_call dependency
  [[ $# -eq 5 && "$1" == 1.1.1.1 && "$2" == 22 && "$3" == landing-a &&
     "$4" == "$fingerprint" ]] || return 90
  TEST_DEPENDENCY_WORK="$5"
  TEST_GATE_WORK="$(dirname -- "$5")"
  [[ "${5##*/}" == dependency ]] || return 91
  controller_private_directory_is_trusted "$5" || return 92
  : > "$5/dependency-proof"
  controller_landing_dependency_set_result \
    "$TEST_DEPENDENCY_STATUS" "$TEST_DEPENDENCY_DETAIL"
  return "$TEST_DEPENDENCY_RC"
}

controller_landing_prepare_singbox_runtime_in_work() {
  record_call singbox
  [[ $# -eq 5 && "$1" == 1.1.1.1 && "$2" == 22 && "$3" == landing-a &&
     "$4" == "$fingerprint" ]] || return 90
  TEST_SINGBOX_WORK="$5"
  [[ "${5##*/}" == singbox && "$(dirname -- "$5")" == "$TEST_GATE_WORK" &&
     "$5" != "$TEST_DEPENDENCY_WORK" ]] || return 91
  controller_private_directory_is_trusted "$5" || return 92
  : > "$5/singbox-proof"
  controller_landing_singbox_set_result "$TEST_SINGBOX_STATUS" "$TEST_SINGBOX_DETAIL"
  CONTROLLER_LANDING_SINGBOX_LAST_VERSION="$TEST_SINGBOX_VERSION"
  CONTROLLER_LANDING_SINGBOX_LAST_SHA256="$TEST_SINGBOX_SHA256"
  return "$TEST_SINGBOX_RC"
}

controller_landing_remove_work_directory() {
  record_call cleanup
  TEST_GATE_WORK="$1"
  ((TEST_CLEANUP_RC == 0)) || return "$TEST_CLEANUP_RC"
  [[ "$1" == "$SB_CONTROLLER_LANDING_WORK_ROOT"/.controller-landing.* ]] || return 1
  rm -rf -- "$1"
}

# 正常路径只确认一次，严格先准备依赖，再准备 sing-box，并汇总稳定结果。
reset_case
state_before="$(sha256sum "$SB_CONTROLLER_STATE_FILE" | awk '{print $1}')"
run_gate
[[ "$GATE_RC" == 0 ]] || fail "ready gate returned $GATE_RC"
expect_stage ready
expect_calls $'discover\nconfirm\ndependency\nsingbox\ncleanup'
[[ "$CONTROLLER_LANDING_READINESS_LAST_FINGERPRINT" == "$fingerprint" &&
   "$CONTROLLER_LANDING_READINESS_LAST_DEPENDENCY_STATUS" == ready &&
   "$CONTROLLER_LANDING_READINESS_LAST_DEPENDENCY_DETAIL" == "" &&
   "$CONTROLLER_LANDING_READINESS_LAST_SINGBOX_STATUS" == installed &&
   "$CONTROLLER_LANDING_READINESS_LAST_SINGBOX_VERSION" == 1.12.3 &&
   "$CONTROLLER_LANDING_READINESS_LAST_SINGBOX_SHA256" == "$singbox_sha" ]] ||
  fail 'ready aggregate result drifted'
[[ "$(sha256sum "$SB_CONTROLLER_STATE_FILE" | awk '{print $1}')" == "$state_before" ]] ||
  fail 'readiness gate changed controller state'
[[ ! -e "$SB_CONTROLLER_SECRET_DIR" &&
   ! -e "$SB_CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE" &&
   ! -e "${SB_CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE}.next" ]] ||
  fail 'readiness gate created secret or onboarding state'
expect_work_removed

# repaired 依赖也是成功结果，必须继续进入运行时准备。
reset_case
TEST_DEPENDENCY_STATUS=repaired
TEST_SINGBOX_STATUS=ready
run_gate
[[ "$GATE_RC" == 0 ]] || fail 'repaired dependency did not permit sing-box preparation'
expect_stage ready
expect_calls $'discover\nconfirm\ndependency\nsingbox\ncleanup'
[[ "$CONTROLLER_LANDING_READINESS_LAST_DEPENDENCY_STATUS" == repaired &&
   "$CONTROLLER_LANDING_READINESS_LAST_SINGBOX_STATUS" == ready ]] ||
  fail 'idempotent aggregate statuses drifted'
expect_work_removed

# 依赖失败必须短路，保留精确子状态和详情，不得调用 sing-box。
reset_case
TEST_DEPENDENCY_RC=1
TEST_DEPENDENCY_STATUS=apt_install_failed
TEST_DEPENDENCY_DETAIL=exit-31
run_gate
[[ "$GATE_RC" == 1 ]] || fail 'dependency failure returned the wrong status'
expect_stage dependency_failed
expect_calls $'discover\nconfirm\ndependency\ncleanup'
[[ "$CONTROLLER_LANDING_READINESS_LAST_DEPENDENCY_STATUS" == apt_install_failed &&
   "$CONTROLLER_LANDING_READINESS_LAST_DEPENDENCY_DETAIL" == exit-31 &&
   "$CONTROLLER_LANDING_READINESS_LAST_SINGBOX_STATUS" == not_checked ]] ||
  fail 'dependency failure result was not preserved'
expect_work_removed

# sing-box 失败必须保留依赖成功事实和运行时候选元数据。
reset_case
TEST_SINGBOX_RC=1
TEST_SINGBOX_STATUS=existing_conflict
TEST_SINGBOX_DETAIL=target-differs
run_gate
[[ "$GATE_RC" == 1 ]] || fail 'sing-box failure returned the wrong status'
expect_stage singbox_failed
expect_calls $'discover\nconfirm\ndependency\nsingbox\ncleanup'
[[ "$CONTROLLER_LANDING_READINESS_LAST_DEPENDENCY_STATUS" == ready &&
   "$CONTROLLER_LANDING_READINESS_LAST_SINGBOX_STATUS" == existing_conflict &&
   "$CONTROLLER_LANDING_READINESS_LAST_SINGBOX_DETAIL" == target-differs &&
   "$CONTROLLER_LANDING_READINESS_LAST_SINGBOX_VERSION" == 1.12.3 &&
   "$CONTROLLER_LANDING_READINESS_LAST_SINGBOX_SHA256" == "$singbox_sha" ]] ||
  fail 'sing-box failure aggregate result drifted'
expect_work_removed

# 子模块若返回成功却没有提供约定成功状态，顶层不得误报 ready。
reset_case
TEST_DEPENDENCY_STATUS=not_checked
run_gate
[[ "$GATE_RC" == 1 ]] || fail 'inconsistent dependency success returned the wrong status'
expect_stage dependency_failed
expect_calls $'discover\nconfirm\ndependency\ncleanup'
expect_work_removed

reset_case
TEST_SINGBOX_STATUS=not_checked
run_gate
[[ "$GATE_RC" == 1 ]] || fail 'inconsistent sing-box success returned the wrong status'
expect_stage singbox_failed
expect_calls $'discover\nconfirm\ndependency\nsingbox\ncleanup'
expect_work_removed

# 用户拒绝保留已发现指纹并返回 2，不能创建工作目录或连接 root。
reset_case
TEST_CONFIRM_RC=2
run_gate
[[ "$GATE_RC" == 2 ]] || fail 'fingerprint rejection returned the wrong status'
expect_stage fingerprint_rejected
expect_calls $'discover\nconfirm'
[[ "$CONTROLLER_LANDING_READINESS_LAST_FINGERPRINT" == "$fingerprint" ]] ||
  fail 'rejected fingerprint was not retained for the caller'
[[ -z "$TEST_GATE_WORK" && ! -e "$SB_CONTROLLER_LANDING_WORK_ROOT" ]] ||
  fail 'fingerprint rejection created a preparation workspace'

reset_case
TEST_CONFIRM_RC=1
run_gate
[[ "$GATE_RC" == 1 ]] || fail 'fingerprint confirmation failure returned the wrong status'
expect_stage fingerprint_confirmation_failed
expect_calls $'discover\nconfirm'

reset_case
TEST_DISCOVER_RC=1
run_gate
[[ "$GATE_RC" == 1 ]] || fail 'fingerprint discovery failure returned the wrong status'
expect_stage fingerprint_discovery_failed
expect_calls discover

reset_case
TEST_DISCOVER_VALUE=invalid
run_gate
[[ "$GATE_RC" == 1 ]] || fail 'invalid discovered fingerprint returned the wrong status'
expect_stage fingerprint_discovery_failed
expect_calls discover

# 本地输入、状态和恢复门禁都必须在主机发现之前失败关闭。
reset_case
run_gate 1.1.1.1 bad landing-a
[[ "$GATE_RC" == 1 ]] || fail 'invalid input returned the wrong status'
expect_stage invalid_input
expect_calls ""

reset_case
printf '%s\n' '{}' > "$SB_CONTROLLER_STATE_FILE"
run_gate
[[ "$GATE_RC" == 1 ]] || fail 'invalid controller state returned the wrong status'
expect_stage invalid_controller_state
expect_calls ""

reset_case
printf '%s\n' '{"stage":"credentials_pending"}' \
  > "$SB_CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE"
chmod 600 "$SB_CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE"
run_gate
[[ "$GATE_RC" == 1 ]] || fail 'pending journal returned the wrong status'
expect_stage pending_recovery
expect_calls ""

reset_case
printf '%s\n' '{}' > "${SB_CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE}.next"
chmod 600 "${SB_CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE}.next"
run_gate
[[ "$GATE_RC" == 1 ]] || fail 'pending journal next file returned the wrong status'
expect_stage pending_recovery
expect_calls ""

reset_case
TEST_TRANSPORT_RC=1
run_gate
[[ "$GATE_RC" == 1 ]] || fail 'unsafe local runtime returned the wrong status'
expect_stage unsafe_local_runtime
expect_calls ""

# 清理失败覆盖顶层阶段，但仍保留可诊断的两个子阶段结果。
reset_case
TEST_CLEANUP_RC=1
run_gate
[[ "$GATE_RC" == 1 ]] || fail 'cleanup failure returned the wrong status'
expect_stage local_cleanup_failed
expect_calls $'discover\nconfirm\ndependency\nsingbox\ncleanup'
[[ "$CONTROLLER_LANDING_READINESS_LAST_DEPENDENCY_STATUS" == ready &&
   "$CONTROLLER_LANDING_READINESS_LAST_SINGBOX_STATUS" == installed ]] ||
  fail 'cleanup failure erased sub-stage facts'

printf 'landing readiness gate checks passed\n'
