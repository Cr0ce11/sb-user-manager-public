#!/usr/bin/env bash
# 测试桩由恢复函数按名称动态调用。
# shellcheck disable=SC2016,SC2317
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

fail() {
  printf 'controller landing onboarding journal test failed: %s\n' "$1" >&2
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

for function_name in controller_landing_onboarding_write_journal \
  controller_landing_onboarding_journal_is_trusted \
  controller_landing_onboarding_clear_journal \
  controller_recover_landing_onboarding; do
  declare -F "$function_name" >/dev/null 2>&1 || fail "missing function: $function_name"
done

test_operation_id="$(printf 'a%.0s' {1..64})"
test_bootstrap_id="$(printf 'b%.0s' {1..64})"
test_fingerprint="SHA256:$(printf 'A%.0s' {1..43})"
call_log="$work/calls"
: > "$call_log"

record_call() {
  printf '%s\n' "$*" >> "$call_log"
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

register_exact_landing() {
  jq --arg credential "$SB_CONTROLLER_SECRET_DIR/landing-landing-a.json" '
    .revision = 1 |
    .landings = [{
      id:"landing-a", display_name:"Landing A", address:"1.1.1.1",
      ssh_port:22,
      ssh_host_fingerprint:"SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
      gateway_port:8443, status:"pending", desired_revision:1,
      applied_revision:0, config_sha256:null, credential_ref:$credential
    }]
  ' "$SB_CONTROLLER_STATE_FILE" > "$work/registered-state"
  mv -- "$work/registered-state" "$SB_CONTROLLER_STATE_FILE"
  chmod 600 "$SB_CONTROLLER_STATE_FILE"
  validate_controller_state_file || fail 'exact registered fixture is invalid'
}

register_mismatched_landing() {
  jq --arg credential "$SB_CONTROLLER_SECRET_DIR/landing-landing-a.json" '
    .revision = 1 |
    .landings = [{
      id:"landing-a", display_name:"Landing A", address:"9.9.9.9",
      ssh_port:22,
      ssh_host_fingerprint:"SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
      gateway_port:8443, status:"pending", desired_revision:1,
      applied_revision:0, config_sha256:null, credential_ref:$credential
    }]
  ' "$SB_CONTROLLER_STATE_FILE" > "$work/registered-state"
  mv -- "$work/registered-state" "$SB_CONTROLLER_STATE_FILE"
  chmod 600 "$SB_CONTROLLER_STATE_FILE"
  validate_controller_state_file || fail 'mismatched registered fixture is invalid'
}

reset_case() {
  : > "$call_log"
  TEST_ROLLBACK_RC=0
  TEST_APPLY_RC=0
  TEST_CLEANUP_RC=0
  rm -f -- "$SB_CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE" \
    "${SB_CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE}.next"
  rm -rf -- "$SB_CONTROLLER_SECRET_DIR"
  reset_controller_state
  controller_landing_onboarding_reset_result
}

create_new_credentials_artifact() {
  mkdir -p "$SB_CONTROLLER_SECRET_DIR/landing-landing-a"
  chmod 700 "$SB_CONTROLLER_SECRET_DIR/landing-landing-a"
}

write_journal_stage() {
  local requested_stage="$1" credentials_preexisting="${2:-false}"
  controller_landing_onboarding_write_journal credentials_pending \
    "$test_operation_id" "$test_bootstrap_id" landing-a 'Landing A' 1.1.1.1 \
    22 8443 gw-a.internal.example 8.8.8.8 "$test_fingerprint" \
    "$credentials_preexisting" || fail 'could not write credentials_pending fixture'
  case "$requested_stage" in
    credentials_pending) return 0 ;;
    local_aborted)
      controller_landing_onboarding_write_journal local_aborted \
        "$test_operation_id" "$test_bootstrap_id" landing-a 'Landing A' 1.1.1.1 \
        22 8443 gw-a.internal.example 8.8.8.8 "$test_fingerprint" \
        "$credentials_preexisting"
      return
      ;;
  esac
  controller_landing_onboarding_write_journal bootstrap_pending \
    "$test_operation_id" "$test_bootstrap_id" landing-a 'Landing A' 1.1.1.1 \
    22 8443 gw-a.internal.example 8.8.8.8 "$test_fingerprint" \
    "$credentials_preexisting" || fail 'could not write bootstrap_pending fixture'
  case "$requested_stage" in
    bootstrap_pending) return 0 ;;
    remote_rolled_back)
      controller_landing_onboarding_write_journal remote_rolled_back \
        "$test_operation_id" "$test_bootstrap_id" landing-a 'Landing A' 1.1.1.1 \
        22 8443 gw-a.internal.example 8.8.8.8 "$test_fingerprint" \
        "$credentials_preexisting"
      return
      ;;
  esac
  controller_landing_onboarding_write_journal registration_pending \
    "$test_operation_id" "$test_bootstrap_id" landing-a 'Landing A' 1.1.1.1 \
    22 8443 gw-a.internal.example 8.8.8.8 "$test_fingerprint" \
    "$credentials_preexisting" || fail 'could not write registration_pending fixture'
  [[ "$requested_stage" != registration_pending ]] || return 0
  controller_landing_onboarding_write_journal apply_pending \
    "$test_operation_id" "$test_bootstrap_id" landing-a 'Landing A' 1.1.1.1 \
    22 8443 gw-a.internal.example 8.8.8.8 "$test_fingerprint" \
    "$credentials_preexisting" || fail 'could not write apply_pending fixture'
  [[ "$requested_stage" != apply_pending ]] || return 0
  controller_landing_onboarding_write_journal completed \
    "$test_operation_id" "$test_bootstrap_id" landing-a 'Landing A' 1.1.1.1 \
    22 8443 gw-a.internal.example 8.8.8.8 "$test_fingerprint" \
    "$credentials_preexisting" || fail 'could not write completed fixture'
}

expect_journal_stage() {
  local expected="$1"
  controller_landing_onboarding_journal_is_trusted || fail 'journal is not trusted'
  [[ "$(jq -r '.stage' "$SB_CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE")" == "$expected" ]] ||
    fail "journal did not remain at $expected"
}

expect_no_journal() {
  [[ ! -e "$SB_CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE" &&
     ! -L "$SB_CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE" ]] ||
    fail 'completed recovery retained the journal'
}

expect_calls() {
  local expected="$1" actual
  actual="$(<"$call_log")"
  [[ "$actual" == "$expected" ]] ||
    fail "unexpected calls: expected [$expected], got [$actual]"
}

controller_rollback_landing_bootstrap() {
  record_call "rollback:$1:$2:$3:$4:$5:$6"
  return "$TEST_ROLLBACK_RC"
}

controller_apply_landing() {
  record_call "apply:$1:$2"
  return "$TEST_APPLY_RC"
}

controller_remove_unregistered_landing_credentials() {
  record_call "cleanup:$1:$2"
  return "$TEST_CLEANUP_RC"
}

# 持久文件严格为 0600，完整 SNI 只经 jq 环境变量进入 root-only journal。
reset_case
write_journal_stage credentials_pending
[[ "$(manager_file_mode "$SB_CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE")" == 600 ]] ||
  fail 'journal mode is not 0600'
[[ "$(jq -r '.server_name' "$SB_CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE")" == \
   gw-a.internal.example ]] || fail 'journal lost the exact SNI'
journal_writer_body="$(sed -n '/^controller_landing_onboarding_write_journal() {$/,/^}$/p' \
  "$ROOT/sb-user-manager.sh")"
if grep -Fq -- '--arg server_name' <<<"$journal_writer_body"; then
  fail 'journal writer placed the full SNI in jq argv'
fi
grep -Fq '$ENV.SB_CONTROLLER_ONBOARDING_SERVER_NAME' <<<"$journal_writer_body" ||
  fail 'journal writer does not read the SNI from the environment'

# 阶段只能沿固定图前进，目标字段漂移不能覆盖既有恢复事实。
if controller_landing_onboarding_write_journal registration_pending \
    "$test_operation_id" "$test_bootstrap_id" landing-a 'Landing A' 1.1.1.1 \
    22 8443 gw-a.internal.example 8.8.8.8 "$test_fingerprint" false; then
  fail 'journal accepted a skipped stage'
fi
expect_journal_stage credentials_pending
if controller_landing_onboarding_write_journal bootstrap_pending \
    "$test_operation_id" "$test_bootstrap_id" landing-a 'Landing A' 9.9.9.9 \
    22 8443 gw-a.internal.example 8.8.8.8 "$test_fingerprint" false; then
  fail 'journal accepted target drift'
fi
expect_journal_stage credentials_pending

# 未提交的固定 .next 可安全收敛；符号链接绝不能被删除或跟随。
printf 'partial' > "${SB_CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE}.next"
chmod 600 "${SB_CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE}.next"
controller_landing_onboarding_remove_next_file || fail 'trusted stale next was not removed'
victim="$work/victim"
printf 'keep\n' > "$victim"
ln -s "$victim" "${SB_CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE}.next"
if controller_landing_onboarding_remove_next_file; then
  fail 'journal cleanup followed a next-file symlink'
fi
[[ "$(<"$victim")" == keep ]] || fail 'next-file symlink target was modified'
rm -f -- "${SB_CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE}.next"

# 没有恢复记录时是只读成功；损坏记录则失败关闭并保留证据。
reset_case
controller_recover_landing_onboarding || fail 'empty recovery did not succeed'
[[ "$CONTROLLER_LANDING_ONBOARDING_LAST_STAGE" == recovery_no_pending ]] ||
  fail 'empty recovery returned the wrong stage'
expect_calls ''
printf '{}\n' > "$SB_CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE"
chmod 600 "$SB_CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE"
if controller_recover_landing_onboarding; then fail 'corrupt journal was accepted'; fi
[[ "$CONTROLLER_LANDING_ONBOARDING_LAST_STAGE" == journal_invalid ]] ||
  fail 'corrupt journal returned the wrong stage'
[[ -f "$SB_CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE" ]] ||
  fail 'corrupt journal evidence was removed'
expect_calls ''

# credentials_pending/local_aborted 从未授权远端动作，只清理本次新凭据。
reset_case
write_journal_stage credentials_pending
create_new_credentials_artifact
controller_recover_landing_onboarding || fail 'credentials recovery failed'
[[ "$CONTROLLER_LANDING_ONBOARDING_LAST_STAGE" == recovery_local_cleaned ]] ||
  fail 'credentials recovery returned the wrong stage'
expect_calls 'cleanup:landing-a:gw-a.internal.example'
expect_no_journal

reset_case
write_journal_stage local_aborted true
create_new_credentials_artifact
controller_recover_landing_onboarding || fail 'preexisting credential recovery failed'
[[ "$CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS" == retained_preexisting ]] ||
  fail 'preexisting credentials were not retained'
expect_calls ''
expect_no_journal

# 实际 SIGKILL 后，bootstrap_pending 仍保留同一 ID，恢复只做精确回退。
reset_case
create_new_credentials_artifact
if (
  write_journal_stage bootstrap_pending
  current_subshell_pid="$(python3 -c 'import os; print(os.getppid())')"
  kill -KILL "$current_subshell_pid"
); then
  fail 'SIGKILL fixture unexpectedly survived'
else
  kill_rc=$?
fi
[[ "$kill_rc" == 137 ]] || fail "SIGKILL fixture returned $kill_rc"
controller_recover_landing_onboarding || fail 'bootstrap SIGKILL recovery failed'
expect_calls "rollback:landing-a:1.1.1.1:22:$test_fingerprint:8.8.8.8:$test_bootstrap_id
cleanup:landing-a:gw-a.internal.example"
[[ "$CONTROLLER_LANDING_ONBOARDING_LAST_STAGE" == recovery_remote_rolled_back ]] ||
  fail 'bootstrap recovery returned the wrong stage'
expect_no_journal

reset_case
write_journal_stage bootstrap_pending
create_new_credentials_artifact
TEST_ROLLBACK_RC=1
if controller_recover_landing_onboarding; then fail 'failed remote rollback was ignored'; fi
[[ "$CONTROLLER_LANDING_ONBOARDING_LAST_STAGE" == bootstrap_failed_recovery_required ]] ||
  fail 'failed bootstrap rollback returned the wrong stage'
expect_journal_stage bootstrap_pending
expect_calls "rollback:landing-a:1.1.1.1:22:$test_fingerprint:8.8.8.8:$test_bootstrap_id"

reset_case
write_journal_stage bootstrap_pending
register_exact_landing
if controller_recover_landing_onboarding; then
  fail 'bootstrap_pending with a registered target guessed a direction'
fi
[[ "$CONTROLLER_LANDING_ONBOARDING_LAST_STAGE" == registration_state_unknown ]] ||
  fail 'ambiguous bootstrap state returned the wrong stage'
expect_calls ''
expect_journal_stage bootstrap_pending

# registration_pending 根据完整登记事实选择 apply 或精确回退。
reset_case
write_journal_stage registration_pending
register_exact_landing
controller_recover_landing_onboarding || fail 'registered recovery did not apply'
expect_calls 'apply:landing-a:8.8.8.8'
[[ "$CONTROLLER_LANDING_ONBOARDING_LAST_STAGE" == completed ]] ||
  fail 'registered recovery did not complete'
expect_no_journal

reset_case
write_journal_stage registration_pending
register_exact_landing
TEST_APPLY_RC=1
if controller_recover_landing_onboarding; then fail 'failed recovery apply was ignored'; fi
[[ "$CONTROLLER_LANDING_ONBOARDING_LAST_STAGE" == registered_sync_pending ]] ||
  fail 'failed recovery apply returned the wrong stage'
expect_calls 'apply:landing-a:8.8.8.8'
expect_journal_stage apply_pending

reset_case
write_journal_stage registration_pending
create_new_credentials_artifact
controller_recover_landing_onboarding || fail 'unregistered recovery rollback failed'
expect_calls "rollback:landing-a:1.1.1.1:22:$test_fingerprint:8.8.8.8:$test_bootstrap_id
cleanup:landing-a:gw-a.internal.example"
[[ "$CONTROLLER_LANDING_ONBOARDING_LAST_STAGE" == recovery_remote_rolled_back ]] ||
  fail 'unregistered recovery returned the wrong stage'
expect_no_journal

reset_case
write_journal_stage registration_pending
register_mismatched_landing
if controller_recover_landing_onboarding; then fail 'mismatched registration was accepted'; fi
[[ "$CONTROLLER_LANDING_ONBOARDING_LAST_STAGE" == registration_state_unknown ]] ||
  fail 'mismatched registration returned the wrong stage'
expect_calls ''
expect_journal_stage registration_pending

# apply_pending 只允许精确登记继续；remote_rolled_back 只继续本地清理。
reset_case
write_journal_stage apply_pending
if controller_recover_landing_onboarding; then fail 'apply_pending without registration ran'; fi
[[ "$CONTROLLER_LANDING_ONBOARDING_LAST_STAGE" == registration_state_unknown ]] ||
  fail 'missing apply registration returned the wrong stage'
expect_calls ''
expect_journal_stage apply_pending

reset_case
write_journal_stage remote_rolled_back
create_new_credentials_artifact
controller_recover_landing_onboarding || fail 'terminal rollback cleanup failed'
expect_calls 'cleanup:landing-a:gw-a.internal.example'
[[ "$CONTROLLER_LANDING_ONBOARDING_LAST_STAGE" == recovery_remote_rolled_back ]] ||
  fail 'terminal rollback cleanup returned the wrong stage'
expect_no_journal

# completed 只核对完整登记并清除终态，不重复 apply。
reset_case
write_journal_stage completed
register_exact_landing
controller_recover_landing_onboarding || fail 'completed journal cleanup failed'
expect_calls ''
[[ "$CONTROLLER_LANDING_ONBOARDING_LAST_STAGE" == completed ]] ||
  fail 'completed journal returned the wrong stage'
expect_no_journal

printf 'controller landing onboarding journal tests passed\n'
