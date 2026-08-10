#!/usr/bin/env bash
# 测试桩由生产编排函数按名称动态调用。
# shellcheck disable=SC2016,SC2317
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

fail() {
  printf 'controller landing onboarding test failed: %s\n' "$1" >&2
  exit 1
}

export SB_USER_MANAGER_LIBRARY=true
export SB_CONTROLLER_STATE_FILE="$work/controller-state/controller-state.json"
export SB_CONTROLLER_SECRET_DIR="$work/controller-secrets"
export SB_CONTROLLER_STATE_LOCK_FILE="$work/controller-lock/controller-state.lock"
export SB_CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE="$work/controller-state/controller-onboarding.json"
export SB_CONTROLLER_LANDING_ONBOARDING_LOCK_FILE="$work/controller-lock/controller-onboarding.lock"
# shellcheck source=../sb-user-manager.sh
source "$ROOT/sb-user-manager.sh"

if ! command -v flock >/dev/null 2>&1; then
  flock() { return 0; }
fi

for function_name in controller_onboard_landing \
  controller_prepare_and_onboard_landing \
  controller_recover_landing_onboarding \
  controller_landing_onboarding_preflight \
  controller_confirm_landing_fingerprint; do
  declare -F "$function_name" >/dev/null 2>&1 || fail "missing function: $function_name"
done

fingerprint="SHA256:$(printf 'A%.0s' {1..43})"
test_operation_id="$(printf 'a%.0s' {1..64})"
test_bootstrap_id="$(printf 'b%.0s' {1..64})"
call_log="$work/calls"
: > "$call_log"

record_call() {
  printf '%s\n' "$1" >> "$call_log"
}

reset_controller_state() {
  mkdir -p "$(dirname "$SB_CONTROLLER_STATE_FILE")" "$SB_CONTROLLER_SECRET_DIR"
  chmod 700 "$(dirname "$SB_CONTROLLER_STATE_FILE")" "$SB_CONTROLLER_SECRET_DIR"
  printf '{"schema_version":1,"role":"entry-controller","revision":0,"landings":[]}\n' \
    > "$SB_CONTROLLER_STATE_FILE"
  chmod 600 "$SB_CONTROLLER_STATE_FILE"
  validate_controller_state_file "$SB_CONTROLLER_STATE_FILE" ||
    fail 'could not reset controller state'
}

reset_case() {
  : > "$call_log"
  TEST_DISCOVER_RC=0
  TEST_DISCOVER_VALUE="$fingerprint"
  TEST_CONFIRM_RC=0
  TEST_CREDENTIAL_RC=0
  TEST_CREDENTIAL_CREATE_ARTIFACT=false
  TEST_CREDENTIAL_CREATE_STAGING=false
  TEST_CLEANUP_RC=0
  TEST_BOOTSTRAP_RC=0
  TEST_BOOTSTRAP_ROLLBACK=not_needed
  TEST_BOOTSTRAP_ID="$test_bootstrap_id"
  TEST_BOOTSTRAP_SET_RESULT=true
  TEST_REGISTER_RC=0
  TEST_REGISTER_CORRUPT_STATE=false
  TEST_REGISTER_WRITE_STATE=false
  TEST_REGISTER_STATE_ADDRESS=""
  TEST_ROLLBACK_RC=0
  TEST_APPLY_RC=0
  TEST_READINESS_RC=0
  TEST_READINESS_STAGE=ready
  TEST_READINESS_FINGERPRINT="$fingerprint"
  TEST_READINESS_DEPENDENCY_STATUS=ready
  TEST_READINESS_SINGBOX_STATUS=ready
  rm -f -- "$SB_CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE" \
    "${SB_CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE}.next"
  rm -rf -- "$SB_CONTROLLER_SECRET_DIR"
  reset_controller_state
}

expect_stage() {
  local calls
  calls="$(<"$call_log")"
  [[ "$CONTROLLER_LANDING_ONBOARDING_LAST_STAGE" == "$1" ]] ||
    fail "expected stage $1, got $CONTROLLER_LANDING_ONBOARDING_LAST_STAGE; calls=[$calls]"
}

expect_calls() {
  local expected="$1" actual
  actual="$(<"$call_log")"
  [[ "$actual" == "$expected" ]] ||
    fail "unexpected calls: expected [$expected], got [$actual]"
}

expect_journal_stage() {
  local expected="$1"
  controller_landing_onboarding_journal_is_trusted ||
    fail 'expected recovery journal is not trusted'
  [[ "$(jq -r '.stage' "$SB_CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE")" == "$expected" ]] ||
    fail "expected journal stage $expected"
}

expect_no_journal() {
  [[ ! -e "$SB_CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE" &&
     ! -L "$SB_CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE" ]] ||
    fail 'completed or safely rolled-back onboarding retained a journal'
}

call_onboarding() {
  controller_onboard_landing landing-a 'Landing A' 1.1.1.1 22 8443 \
    gw-a.internal.example 8.8.8.8
}

call_prepared_onboarding() {
  controller_prepare_and_onboard_landing landing-a 'Landing A' 1.1.1.1 22 8443 \
    gw-a.internal.example 8.8.8.8
}

# 默认确认器只接受明确的 y；回车和 n 都是取消，不产生隐式同意。
if controller_confirm_landing_fingerprint 1.1.1.1 22 "$fingerprint" \
    <<< n >/dev/null; then
  fail 'default fingerprint confirmation accepted n'
else
  rc=$?
fi
[[ "$rc" == 2 ]] || fail 'default fingerprint rejection returned the wrong status'
controller_confirm_landing_fingerprint 1.1.1.1 22 "$fingerprint" \
  <<< y >/dev/null || fail 'default fingerprint confirmation rejected y'

controller_landing_discover_fingerprint() {
  record_call discover
  ((TEST_DISCOVER_RC == 0)) || return "$TEST_DISCOVER_RC"
  printf '%s\n' "$TEST_DISCOVER_VALUE"
}

controller_landing_onboarding_generate_id() {
  case "$1" in
    operation) printf '%s\n' "$test_operation_id" ;;
    bootstrap) printf '%s\n' "$test_bootstrap_id" ;;
    *) return 64 ;;
  esac
}

controller_confirm_landing_fingerprint() {
  record_call confirm
  return "$TEST_CONFIRM_RC"
}

controller_initialize_landing_credentials() {
  record_call credentials
  expect_journal_stage credentials_pending
  if ((TEST_CREDENTIAL_RC == 0)) || [[ "$TEST_CREDENTIAL_CREATE_ARTIFACT" == true ]]; then
    mkdir -p "$SB_CONTROLLER_SECRET_DIR/landing-landing-a"
    chmod 700 "$SB_CONTROLLER_SECRET_DIR/landing-landing-a"
  fi
  if [[ "$TEST_CREDENTIAL_CREATE_STAGING" == true ]]; then
    mkdir "$SB_CONTROLLER_SECRET_DIR/.landing-credentials.landing-a.AAAAAAAAAA"
    chmod 700 "$SB_CONTROLLER_SECRET_DIR/.landing-credentials.landing-a.AAAAAAAAAA"
  fi
  return "$TEST_CREDENTIAL_RC"
}

controller_remove_unregistered_landing_credentials() {
  local cleanup_stage
  record_call cleanup
  cleanup_stage="$(jq -r '.stage' "$SB_CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE")"
  [[ "$cleanup_stage" == local_aborted || "$cleanup_stage" == remote_rolled_back ]] ||
    fail "credential cleanup ran before a terminal journal stage: $cleanup_stage"
  return "$TEST_CLEANUP_RC"
}

controller_bootstrap_landing_channel() {
  record_call bootstrap
  expect_journal_stage bootstrap_pending
  [[ $# -eq 6 && "$4" == "$fingerprint" && "$6" == "$test_bootstrap_id" ]] || return 64
  if [[ "$TEST_BOOTSTRAP_SET_RESULT" == true ]]; then
    CONTROLLER_LANDING_BOOTSTRAP_LAST_ID="$TEST_BOOTSTRAP_ID"
    CONTROLLER_LANDING_BOOTSTRAP_LAST_ROLLBACK="$TEST_BOOTSTRAP_ROLLBACK"
  fi
  return "$TEST_BOOTSTRAP_RC"
}

controller_register_landing() {
  record_call register
  expect_journal_stage registration_pending
  if ((TEST_REGISTER_RC == 0)) || [[ "$TEST_REGISTER_WRITE_STATE" == true ]]; then
    local state_address="$3"
    [[ -z "$TEST_REGISTER_STATE_ADDRESS" ]] || state_address="$TEST_REGISTER_STATE_ADDRESS"
    jq --arg landing_id "$1" --arg display_name "$2" --arg address "$state_address" \
      --argjson ssh_port "$4" --arg fingerprint "$5" --argjson gateway_port "$6" \
      --arg credential "$SB_CONTROLLER_SECRET_DIR/landing-$1.json" '
        .revision += 1 |
        .landings += [{
          id:$landing_id, display_name:$display_name, address:$address,
          ssh_port:$ssh_port, ssh_host_fingerprint:$fingerprint,
          gateway_port:$gateway_port, status:"pending", desired_revision:1,
          applied_revision:0, config_sha256:null, credential_ref:$credential
        }]
      ' "$SB_CONTROLLER_STATE_FILE" > "$work/registered-state"
    mv "$work/registered-state" "$SB_CONTROLLER_STATE_FILE"
    chmod 600 "$SB_CONTROLLER_STATE_FILE"
  fi
  if [[ "$TEST_REGISTER_CORRUPT_STATE" == true ]]; then
    printf '{}\n' > "$SB_CONTROLLER_STATE_FILE"
  fi
  return "$TEST_REGISTER_RC"
}

controller_rollback_landing_bootstrap() {
  record_call rollback
  expect_journal_stage registration_pending
  return "$TEST_ROLLBACK_RC"
}

controller_apply_landing() {
  record_call apply
  expect_journal_stage apply_pending
  return "$TEST_APPLY_RC"
}

# 尚未建立入口角色时，编排在任何网络或持久修改前停止。
if call_onboarding >/dev/null 2>&1; then
  fail 'onboarding succeeded without controller state'
fi
expect_stage preflight_failed
expect_calls ''

reset_case
if controller_onboard_landing landing-a 'Landing A' 1.1.1.1 22 8443 \
    'bad sni' 8.8.8.8 >/dev/null 2>&1; then
  fail 'onboarding accepted an invalid SNI'
fi
expect_stage preflight_failed
expect_calls ''

reset_case
jq --arg credential "$SB_CONTROLLER_SECRET_DIR/landing-landing-a.json" '
  .revision = 1 |
  .landings = [{
    id:"landing-a", display_name:"Existing", address:"1.1.1.1",
    ssh_port:22, ssh_host_fingerprint:"SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    gateway_port:8443, status:"pending", desired_revision:1,
    applied_revision:0, config_sha256:null, credential_ref:$credential
  }]
' "$SB_CONTROLLER_STATE_FILE" > "$work/duplicate-state"
mv "$work/duplicate-state" "$SB_CONTROLLER_STATE_FILE"
chmod 600 "$SB_CONTROLLER_STATE_FILE"
validate_controller_state_file || fail 'duplicate preflight fixture is invalid'
if call_onboarding >/dev/null 2>&1; then
  fail 'onboarding accepted a duplicate landing'
fi
expect_stage preflight_failed
expect_calls ''

reset_case
jq --arg credential "$SB_CONTROLLER_SECRET_DIR/landing-existing.json" '
  .revision = 1 |
  .landings = [{
    id:"existing", display_name:"Existing", address:"1.1.1.1",
    ssh_port:22, ssh_host_fingerprint:"SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    gateway_port:8443, status:"pending", desired_revision:1,
    applied_revision:0, config_sha256:null, credential_ref:$credential
  }]
' "$SB_CONTROLLER_STATE_FILE" > "$work/duplicate-address-state"
mv "$work/duplicate-address-state" "$SB_CONTROLLER_STATE_FILE"
chmod 600 "$SB_CONTROLLER_STATE_FILE"
validate_controller_state_file || fail 'duplicate address fixture is invalid'
if call_onboarding >/dev/null 2>&1; then
  fail 'onboarding accepted a duplicate address and SSH port'
fi
expect_stage preflight_failed
expect_calls ''

reset_case
TEST_DISCOVER_RC=1
if call_onboarding >/dev/null 2>&1; then
  fail 'fingerprint discovery failure was ignored'
fi
expect_stage fingerprint_discovery_failed
expect_calls discover

reset_case
TEST_DISCOVER_VALUE=invalid
if call_onboarding >/dev/null 2>&1; then
  fail 'invalid discovered fingerprint was accepted'
fi
expect_stage fingerprint_discovery_failed
expect_calls discover

reset_case
TEST_CONFIRM_RC=2
if call_onboarding >/dev/null 2>&1; then
  fail 'fingerprint rejection unexpectedly succeeded'
else
  rc=$?
fi
[[ "$rc" == 2 ]] || fail 'fingerprint rejection did not return cancellation status'
expect_stage cancelled
expect_calls $'discover\nconfirm'

reset_case
TEST_CONFIRM_RC=1
if call_onboarding >/dev/null 2>&1; then
  fail 'fingerprint confirmation input failure was ignored'
fi
expect_stage fingerprint_confirmation_failed
expect_calls $'discover\nconfirm'

reset_case
TEST_CREDENTIAL_RC=1
if call_onboarding >/dev/null 2>&1; then
  fail 'credential failure was ignored'
fi
expect_stage credentials_failed
[[ "$CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS" == not_created ]] ||
  fail 'empty credential failure was reported as retained material'
expect_calls $'discover\nconfirm\ncredentials'

reset_case
TEST_CREDENTIAL_RC=1
TEST_CREDENTIAL_CREATE_STAGING=true
if call_onboarding >/dev/null 2>&1; then
  fail 'staged credential failure was ignored'
fi
expect_stage credentials_failed
[[ "$CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS" == removed ]] ||
  fail 'new staged credentials were not cleaned'
expect_calls $'discover\nconfirm\ncredentials\ncleanup'

reset_case
TEST_CREDENTIAL_RC=1
TEST_CREDENTIAL_CREATE_ARTIFACT=true
if call_onboarding >/dev/null 2>&1; then
  fail 'partial credential failure was ignored'
fi
expect_stage credentials_failed
[[ "$CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS" == removed ]] ||
  fail 'new partial credentials were not cleaned'
expect_calls $'discover\nconfirm\ncredentials\ncleanup'

reset_case
TEST_CREDENTIAL_RC=1
TEST_CREDENTIAL_CREATE_ARTIFACT=true
TEST_CLEANUP_RC=1
if call_onboarding >/dev/null 2>&1; then
  fail 'credential cleanup failure was ignored'
fi
expect_stage credentials_failed_recovery_required
[[ "$CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS" == cleanup_failed ]] ||
  fail 'credential cleanup failure result was lost'
expect_journal_stage local_aborted

reset_case
mkdir "$SB_CONTROLLER_SECRET_DIR/landing-landing-a"
chmod 700 "$SB_CONTROLLER_SECRET_DIR/landing-landing-a"
TEST_CREDENTIAL_RC=1
if call_onboarding >/dev/null 2>&1; then
  fail 'preexisting credential failure was ignored'
fi
expect_stage credentials_failed
[[ "$CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS" == retained_preexisting ]] ||
  fail 'preexisting credentials were not retained'
expect_calls $'discover\nconfirm\ncredentials'

reset_case
TEST_BOOTSTRAP_RC=1
TEST_BOOTSTRAP_ROLLBACK=completed
if call_onboarding >/dev/null 2>&1; then
  fail 'bootstrap failure was ignored'
fi
expect_stage bootstrap_failed_rolled_back
[[ "$CONTROLLER_LANDING_ONBOARDING_LAST_REMOTE_ROLLBACK" == completed ]] ||
  fail 'bootstrap rollback result was lost'
expect_calls $'discover\nconfirm\ncredentials\nbootstrap\ncleanup'
expect_no_journal

reset_case
TEST_BOOTSTRAP_RC=1
TEST_BOOTSTRAP_ROLLBACK=failed
if call_onboarding >/dev/null 2>&1; then
  fail 'failed bootstrap rollback was ignored'
fi
expect_stage bootstrap_failed_recovery_required
[[ "$CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS" == retained_for_recovery ]] ||
  fail 'bootstrap recovery credentials were not retained'
expect_calls $'discover\nconfirm\ncredentials\nbootstrap'
expect_journal_stage bootstrap_pending

reset_case
# 故意设置上一次操作的残留值，确认本次调用不会复用旧结果。
# shellcheck disable=SC2034
CONTROLLER_LANDING_BOOTSTRAP_LAST_ID="$test_bootstrap_id"
# shellcheck disable=SC2034
CONTROLLER_LANDING_BOOTSTRAP_LAST_ROLLBACK=completed
TEST_BOOTSTRAP_RC=1
TEST_BOOTSTRAP_SET_RESULT=false
if call_onboarding >/dev/null 2>&1; then
  fail 'bootstrap failure without a current result was ignored'
fi
expect_stage bootstrap_state_unknown
[[ "$CONTROLLER_LANDING_ONBOARDING_LAST_REMOTE_ROLLBACK" == not_attempted ]] ||
  fail 'stale bootstrap rollback result was reused'
expect_calls $'discover\nconfirm\ncredentials\nbootstrap'
expect_journal_stage bootstrap_pending

reset_case
TEST_BOOTSTRAP_ID=invalid
if call_onboarding >/dev/null 2>&1; then
  fail 'invalid bootstrap result was accepted'
fi
expect_stage bootstrap_state_unknown
expect_calls $'discover\nconfirm\ncredentials\nbootstrap'
expect_journal_stage bootstrap_pending

reset_case
TEST_REGISTER_RC=1
if call_onboarding >/dev/null 2>&1; then
  fail 'registration failure was ignored'
fi
expect_stage registration_failed_rolled_back
[[ "$CONTROLLER_LANDING_ONBOARDING_LAST_REMOTE_ROLLBACK" == completed ]] ||
  fail 'registration rollback result was lost'
expect_calls $'discover\nconfirm\ncredentials\nbootstrap\nregister\nrollback\ncleanup'
expect_no_journal

reset_case
TEST_REGISTER_RC=1
TEST_ROLLBACK_RC=1
if call_onboarding >/dev/null 2>&1; then
  fail 'registration rollback failure was ignored'
fi
expect_stage registration_failed_recovery_required
[[ "$CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS" == retained_for_recovery ]] ||
  fail 'registration recovery credentials were not retained'
expect_calls $'discover\nconfirm\ncredentials\nbootstrap\nregister\nrollback'
expect_journal_stage registration_pending

reset_case
TEST_REGISTER_RC=1
TEST_REGISTER_WRITE_STATE=true
call_onboarding >/dev/null ||
  fail 'committed registration was rolled back after an ambiguous return status'
expect_stage completed
expect_calls $'discover\nconfirm\ncredentials\nbootstrap\nregister\napply'

reset_case
TEST_REGISTER_RC=1
TEST_REGISTER_WRITE_STATE=true
TEST_REGISTER_STATE_ADDRESS=9.9.9.9
if call_onboarding >/dev/null 2>&1; then
  fail 'mismatched committed registration was accepted as the current target'
fi
expect_stage registration_state_unknown
[[ "$CONTROLLER_LANDING_ONBOARDING_LAST_REMOTE_ROLLBACK" == not_attempted ]] ||
  fail 'mismatched registration attempted unsafe rollback'
expect_calls $'discover\nconfirm\ncredentials\nbootstrap\nregister'
expect_journal_stage registration_pending

reset_case
TEST_REGISTER_RC=1
TEST_REGISTER_CORRUPT_STATE=true
if call_onboarding >/dev/null 2>&1; then
  fail 'unknown registration state was ignored'
fi
expect_stage registration_state_unknown
[[ "$CONTROLLER_LANDING_ONBOARDING_LAST_REMOTE_ROLLBACK" == not_attempted ]] ||
  fail 'unknown registration state attempted unsafe rollback'
expect_calls $'discover\nconfirm\ncredentials\nbootstrap\nregister'
expect_journal_stage registration_pending

reset_case
TEST_APPLY_RC=1
if call_onboarding >/dev/null 2>&1; then
  fail 'first apply failure unexpectedly succeeded'
fi
expect_stage registered_sync_pending
[[ "$CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS" == registered ]] ||
  fail 'registered credentials were not retained after apply failure'
expect_calls $'discover\nconfirm\ncredentials\nbootstrap\nregister\napply'
expect_journal_stage apply_pending

reset_case
mkdir "$SB_CONTROLLER_SECRET_DIR/landing-landing-a"
chmod 700 "$SB_CONTROLLER_SECRET_DIR/landing-landing-a"
TEST_REGISTER_RC=1
if call_onboarding >/dev/null 2>&1; then
  fail 'preexisting registration failure unexpectedly succeeded'
fi
expect_stage registration_failed_rolled_back
[[ "$CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS" == retained_preexisting ]] ||
  fail 'preexisting credentials were removed after registration rollback'
expect_calls $'discover\nconfirm\ncredentials\nbootstrap\nregister\nrollback'

reset_case
output="$work/onboarding-output"
if ! call_onboarding > "$output"; then
  fail 'happy onboarding path failed'
fi
[[ ! -s "$output" ]] || fail 'onboarding core wrote unexpected ordinary output'
expect_stage completed
[[ "$CONTROLLER_LANDING_ONBOARDING_LAST_FINGERPRINT" == "$fingerprint" ]] ||
  fail 'confirmed fingerprint result was lost'
expect_calls $'discover\nconfirm\ncredentials\nbootstrap\nregister\napply'
expect_no_journal

controller_prepare_landing_readiness() {
  record_call readiness
  # 模拟统一门禁的脱敏结果和仅供当前调用栈消费的已确认指纹。
  # shellcheck disable=SC2034
  CONTROLLER_LANDING_READINESS_LAST_STAGE="$TEST_READINESS_STAGE"
  CONTROLLER_LANDING_READINESS_LAST_FINGERPRINT="$TEST_READINESS_FINGERPRINT"
  # shellcheck disable=SC2034
  CONTROLLER_LANDING_READINESS_LAST_DEPENDENCY_STATUS="$TEST_READINESS_DEPENDENCY_STATUS"
  # shellcheck disable=SC2034
  CONTROLLER_LANDING_READINESS_LAST_SINGBOX_STATUS="$TEST_READINESS_SINGBOX_STATUS"
  return "$TEST_READINESS_RC"
}

# 统一入口不允许调用者注入一个未经 readiness 确认的指纹。
reset_case
# shellcheck disable=SC2034
CONTROLLER_LANDING_READINESS_LAST_FINGERPRINT="$fingerprint"
# shellcheck disable=SC2034
CONTROLLER_LANDING_ONBOARDING_LAST_FINGERPRINT="$fingerprint"
if controller_prepare_and_onboard_landing landing-a 'Landing A' 1.1.1.1 22 8443 \
    gw-a.internal.example 8.8.8.8 "$fingerprint" >/dev/null 2>&1; then
  fail 'prepared onboarding accepted a caller-supplied fingerprint'
else
  rc=$?
fi
[[ "$rc" == 64 ]] || fail 'prepared onboarding returned the wrong arity status'
expect_calls ''
[[ -z "$CONTROLLER_LANDING_ONBOARDING_LAST_FINGERPRINT" &&
   -z "$CONTROLLER_LANDING_READINESS_LAST_FINGERPRINT" ]] ||
  fail 'invalid prepared onboarding call retained a full fingerprint result'

# 全部本地输入和重复目标检查必须发生在远程 readiness 之前。
reset_case
if controller_prepare_and_onboard_landing landing-a 'Landing A' 1.1.1.1 22 8443 \
    'bad sni' 8.8.8.8 >/dev/null 2>&1; then
  fail 'prepared onboarding accepted invalid local input'
fi
expect_stage preflight_failed
expect_calls ''
expect_no_journal

# readiness 失败或取消不得进入日志、秘密或远端 bootstrap 阶段。
reset_case
TEST_READINESS_RC=1
TEST_READINESS_STAGE=dependency_failed
TEST_READINESS_DEPENDENCY_STATUS=apt_install_failed
if call_prepared_onboarding >/dev/null 2>&1; then
  fail 'prepared onboarding ignored readiness failure'
fi
expect_stage readiness_failed
[[ "$CONTROLLER_LANDING_ONBOARDING_LAST_READINESS_STAGE" == dependency_failed ]] ||
  fail 'readiness failure stage was lost'
[[ "$CONTROLLER_LANDING_ONBOARDING_LAST_DEPENDENCY_STATUS" == apt_install_failed ]] ||
  fail 'dependency failure status was lost'
expect_calls readiness
expect_no_journal
[[ ! -e "$SB_CONTROLLER_SECRET_DIR/landing-landing-a" ]] ||
  fail 'readiness failure created landing credentials'
[[ -z "$CONTROLLER_LANDING_ONBOARDING_LAST_FINGERPRINT" &&
   -z "$CONTROLLER_LANDING_READINESS_LAST_FINGERPRINT" ]] ||
  fail 'readiness failure retained a full fingerprint result'

reset_case
TEST_READINESS_RC=2
TEST_READINESS_STAGE=fingerprint_rejected
if call_prepared_onboarding >/dev/null 2>&1; then
  fail 'prepared onboarding ignored readiness cancellation'
else
  rc=$?
fi
[[ "$rc" == 2 ]] || fail 'prepared onboarding returned the wrong cancellation status'
expect_stage readiness_cancelled
expect_calls readiness
expect_no_journal

# readiness 只有返回完整、可信的成功结果才能进入持久 onboarding。
reset_case
TEST_READINESS_FINGERPRINT=invalid
if call_prepared_onboarding >/dev/null 2>&1; then
  fail 'prepared onboarding accepted an invalid readiness fingerprint'
fi
expect_stage readiness_result_invalid
expect_calls readiness
expect_no_journal

reset_case
TEST_READINESS_STAGE=singbox_failed
if call_prepared_onboarding >/dev/null 2>&1; then
  fail 'prepared onboarding accepted inconsistent readiness success'
fi
expect_stage readiness_result_invalid
expect_calls readiness
expect_no_journal

reset_case
TEST_READINESS_SINGBOX_STATUS=not_checked
if call_prepared_onboarding >/dev/null 2>&1; then
  fail 'prepared onboarding accepted an incomplete readiness result'
fi
expect_stage readiness_result_invalid
expect_calls readiness
expect_no_journal

# readiness 成功后复用同一指纹，不再次发现或提示；原失败恢复语义保持不变。
reset_case
TEST_CREDENTIAL_RC=1
if call_prepared_onboarding >/dev/null 2>&1; then
  fail 'prepared onboarding ignored credential failure'
fi
expect_stage credentials_failed
[[ "$CONTROLLER_LANDING_ONBOARDING_LAST_READINESS_STAGE" == ready ]] ||
  fail 'successful readiness result was lost after onboarding failure'
expect_calls $'readiness\ncredentials'
expect_no_journal

reset_case
output="$work/prepared-onboarding-output"
if ! call_prepared_onboarding > "$output"; then
  fail 'prepared onboarding happy path failed'
fi
[[ ! -s "$output" ]] || fail 'prepared onboarding core wrote unexpected ordinary output'
expect_stage completed
[[ "$CONTROLLER_LANDING_ONBOARDING_LAST_READINESS_STAGE" == ready &&
   "$CONTROLLER_LANDING_ONBOARDING_LAST_DEPENDENCY_STATUS" == ready &&
   "$CONTROLLER_LANDING_ONBOARDING_LAST_SINGBOX_STATUS" == ready ]] ||
  fail 'prepared onboarding did not preserve sanitized readiness results'
[[ -z "$CONTROLLER_LANDING_ONBOARDING_LAST_FINGERPRINT" &&
   -z "$CONTROLLER_LANDING_READINESS_LAST_FINGERPRINT" ]] ||
  fail 'prepared onboarding retained a full fingerprint result'
expect_calls $'readiness\ncredentials\nbootstrap\nregister\napply'
expect_no_journal

printf 'controller landing onboarding tests passed\n'
