#!/usr/bin/env bash
# 测试桩由生产函数按名称动态调用；单引号断言需要匹配远端字面量。
# shellcheck disable=SC2016,SC2120,SC2317
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
test_runtime="$work/controller-runtime-source"
install -m 600 -- "$ROOT/sb-user-manager.sh" "$test_runtime"

fail() {
  printf 'landing bootstrap test failed: %s\n' "$1" >&2
  exit 1
}

export SB_USER_MANAGER_LIBRARY=true
export SB_SYSTEM_ROOT="$work/system-root"
export SB_CONTROLLER_STATE_FILE="$work/controller-state/state.json"
export SB_CONTROLLER_SECRET_DIR="$work/controller-secrets"
export SB_CONTROLLER_STATE_LOCK_FILE="$work/controller-lock/state.lock"
export SB_CONTROLLER_LANDING_WORK_ROOT="$work/controller-work"
export SB_CONTROLLER_LANDING_BOOTSTRAP_RUNTIME_SOURCE="$test_runtime"
# shellcheck source=../sb-user-manager.sh
source "$ROOT/sb-user-manager.sh"

for function_name in landing_bootstrap_platform_is_supported \
  landing_bootstrap_write_receipt landing_bootstrap_execute \
  controller_landing_build_bootstrap_package controller_bootstrap_landing_channel \
  controller_bootstrap_landing_channel_in_work \
  controller_rollback_landing_bootstrap; do
  declare -F "$function_name" >/dev/null 2>&1 ||
    fail "missing function: $function_name"
done

# 依赖、平台和固定系统路径必须在公钥改写、收据或锁文件创建前完成检查。
execute_preflight="$(declare -f landing_bootstrap_execute)"
execute_preflight="${execute_preflight%%landing_channel_normalize_public_key*}"
for preflight_call in landing_channel_runtime_paths_are_safe \
  landing_channel_dependencies_are_ready landing_bootstrap_platform_is_supported \
  landing_channel_install_system_paths_are_safe landing_channel_runtime_source; do
  grep -Fq "$preflight_call" <<< "$execute_preflight" ||
    fail "bootstrap preflight is missing: $preflight_call"
done

mkdir -m 700 "$SB_SYSTEM_ROOT" "$SB_CONTROLLER_SECRET_DIR" \
  "$SB_CONTROLLER_LANDING_WORK_ROOT"

bootstrap_id="$(printf 'a%.0s' {1..64})"
other_bootstrap_id="$(printf 'b%.0s' {1..64})"
runtime_sha="$(sha256sum "$test_runtime" | awk '{print $1}')"
public_key="$work/public-key"
ssh-keygen -q -t ed25519 -N '' -f "$work/ssh-ed25519"
ssh-keygen -y -P '' -f "$work/ssh-ed25519" > "$public_key"
chmod 600 "$public_key"
public_key_fingerprint="$(landing_channel_public_key_fingerprint "$public_key")"
fixture_public_key="$public_key"

# 收据必须原子写入、严格绑定本次初始化，并拒绝错误 bootstrap_id。
landing_channel_ensure_system_directory /var
landing_channel_ensure_system_directory /var/lib
root_uid="$(landing_channel_expected_root_uid)"
root_gid="$(landing_channel_expected_root_gid)"
landing_channel_ensure_owned_directory /var/lib/sb-user-manager 700 "$root_uid" "$root_gid"
landing_bootstrap_write_receipt "$bootstrap_id" e2e-local 8.8.8.8 \
  "$public_key_fingerprint" "$runtime_sha" installing
receipt="$(landing_bootstrap_receipt_file)"
landing_bootstrap_receipt_is_trusted "$receipt" || fail 'trusted receipt was rejected'
[[ "$(manager_file_mode "$receipt")" == 600 ]] || fail 'receipt mode is not 600'
if landing_bootstrap_receipt_matches "$receipt" "$other_bootstrap_id" e2e-local \
    8.8.8.8 "$public_key_fingerprint"; then
  fail 'receipt accepted the wrong bootstrap id'
fi
if landing_bootstrap_remove_receipt "$other_bootstrap_id" e2e-local 8.8.8.8 \
    "$public_key_fingerprint"; then
  fail 'wrong bootstrap id removed the receipt'
fi
landing_bootstrap_remove_receipt "$bootstrap_id" e2e-local 8.8.8.8 \
  "$public_key_fingerprint"
[[ ! -e "$receipt" && ! -L "$receipt" ]] || fail 'receipt was not removed'

# 安装成功将 installing 收据推进为 installed；失败且没有系统残留时清除收据。
(
  install_landing_restricted_channel() { return 0; }
  landing_restricted_channel_is_valid() { return 0; }
  landing_channel_fresh_preflight() { return 0; }
  output="$(landing_bootstrap_install_unlocked "$bootstrap_id" e2e-local 8.8.8.8 \
    "$public_key" "$public_key_fingerprint" "$runtime_sha")" ||
    fail 'stubbed bootstrap install failed'
  [[ "$output" == '{"status":"installed"}' ]] || fail 'install response is not strict JSON'
  [[ "$(jq -r '.status' "$receipt")" == installed ]] || fail 'receipt was not committed'
)
landing_bootstrap_remove_receipt "$bootstrap_id" e2e-local 8.8.8.8 \
  "$public_key_fingerprint"
(
  install_landing_restricted_channel() { return 1; }
  landing_restricted_channel_is_valid() { return 1; }
  landing_channel_fresh_preflight() { return 0; }
  if landing_bootstrap_install_unlocked "$bootstrap_id" e2e-local 8.8.8.8 \
      "$public_key" "$public_key_fingerprint" "$runtime_sha" >/dev/null; then
    fail 'injected install failure was ignored'
  fi
  [[ ! -e "$receipt" && ! -L "$receipt" ]] || fail 'clean install failure kept a receipt'
)

# 回退只接受精确收据；卸载失败时保留恢复上下文，成功后才删除收据。
landing_bootstrap_write_receipt "$bootstrap_id" e2e-local 8.8.8.8 \
  "$public_key_fingerprint" "$runtime_sha" installed
(
  uninstall_landing_restricted_channel() { return 1; }
  if landing_bootstrap_rollback_unlocked "$bootstrap_id" e2e-local 8.8.8.8 \
      "$public_key_fingerprint" >/dev/null; then
    fail 'injected uninstall failure was ignored'
  fi
  landing_bootstrap_receipt_is_trusted "$receipt" || fail 'failed rollback lost its receipt'
)
if landing_bootstrap_rollback_unlocked "$other_bootstrap_id" e2e-local 8.8.8.8 \
    "$public_key_fingerprint" >/dev/null; then
  fail 'wrong bootstrap id was allowed to roll back'
fi
(
  uninstall_landing_restricted_channel() { return 0; }
  output="$(landing_bootstrap_rollback_unlocked "$bootstrap_id" e2e-local 8.8.8.8 \
    "$public_key_fingerprint")" || fail 'stubbed rollback failed'
  [[ "$output" == '{"status":"rolled_back"}' ]] || fail 'rollback response is not strict JSON'
)
[[ ! -e "$receipt" && ! -L "$receipt" ]] || fail 'successful rollback kept its receipt'

# 引导包只携带公开材料与完整运行时，权限、大小和嵌入摘要必须受限。
package_work="$SB_CONTROLLER_LANDING_WORK_ROOT/package"
mkdir -m 700 "$package_work"
package="$package_work/bootstrap.sh"
controller_landing_build_bootstrap_package install "$bootstrap_id" e2e-local \
  8.8.8.8 "$public_key" "$package"
controller_landing_private_file_is_trusted "$package" || fail 'generated package is not private'
grep -Fxq "runtime_sha256=$runtime_sha" "$package" || fail 'runtime digest is missing'
grep -Fxq 'bootstrap_action=install' "$package" || fail 'package action is missing'
grep -Fq '__SB_USER_MANAGER_RUNTIME__' "$package" || fail 'runtime payload marker is missing'
if grep -Fq 'PRIVATE KEY' "$package"; then fail 'bootstrap package contains a private key'; fi
if grep -Fq 'gateway-password-fixture' "$package"; then fail 'bootstrap package contains a gateway secret'; fi
package_size="$(controller_landing_file_size "$package")"
((package_size > 0 && package_size <= LANDING_BOOTSTRAP_PACKAGE_MAX_BYTES)) ||
  fail 'bootstrap package size is outside the limit'
if controller_landing_build_bootstrap_package install "$other_bootstrap_id" e2e-local \
    8.8.8.8 "$public_key" "$package"; then
  fail 'package builder overwrote an existing output'
fi

# 远端接收命令只接受 64 位摘要，并在执行前进行整包校验。
package_sha="$(sha256sum "$package" | awk '{print $1}')"
remote_command="$(controller_landing_bootstrap_remote_command "$package_sha")"
grep -Fq "expected=$package_sha" <<<"$remote_command" || fail 'remote digest pin is missing'
grep -Fq '/usr/bin/sha256sum "$work/package"' <<<"$remote_command" ||
  fail 'remote package verification is missing'
if controller_landing_bootstrap_remote_command bad-digest >/dev/null; then
  fail 'remote command accepted a malformed digest'
fi

# 调用方可在任何远端动作前固定 bootstrap ID，供持久恢复日志精确引用。
(
  requested_id_seen=""
  requested_work="$SB_CONTROLLER_LANDING_WORK_ROOT/requested-id"
  controller_landing_transport_runtime_is_safe() { return 0; }
  controller_landing_registration_manifest() { return 0; }
  controller_landing_create_work_directory() {
    mkdir -m 700 "$requested_work" || return 1
    printf '%s\n' "$requested_work"
  }
  register_temp_path() { return 0; }
  controller_bootstrap_landing_channel_in_work() {
    requested_id_seen="$6"
    return 0
  }
  controller_landing_remove_work_directory() {
    rmdir "$1"
  }
  controller_bootstrap_landing_channel e2e-local 8.8.8.8 22 \
    "SHA256:$(printf 'A%.0s' {1..43})" 8.8.8.8 "$bootstrap_id" ||
    fail 'caller-supplied bootstrap id was rejected'
  [[ "$requested_id_seen" == "$bootstrap_id" &&
     "$CONTROLLER_LANDING_BOOTSTRAP_LAST_ID" == "$bootstrap_id" ]] ||
    fail 'caller-supplied bootstrap id was replaced'
)

valid_response="$package_work/response.json"
printf '%s\n' '{"status":"installed"}' > "$valid_response"
chmod 600 "$valid_response"
controller_landing_bootstrap_response_is_valid "$valid_response" ||
  fail 'valid bootstrap response was rejected'
printf '%s\n' '{"status":"installed","extra":true}' > "$valid_response"
if controller_landing_bootstrap_response_is_valid "$valid_response"; then
  fail 'bootstrap response accepted an extra field'
fi

# 入口编排：正常路径只安装和探测；安装不确定或探测失败都尝试精确回退。
orchestration_work="$SB_CONTROLLER_LANDING_WORK_ROOT/orchestration"
mkdir -m 700 "$orchestration_work"
(
  actions="$work/actions-success"
  : > "$actions"
  controller_landing_bootstrap_public_key() { cp "$fixture_public_key" "$2"; chmod 600 "$2"; }
  controller_landing_send_bootstrap_action_in_work() { printf '%s\n' "$1" >> "$actions"; return 0; }
  controller_landing_remove_bootstrap_action_files() { return 0; }
  controller_test_landing_registration_channel() { return 0; }
  controller_bootstrap_landing_channel_in_work e2e-local 8.8.8.8 22 \
    "SHA256:$(printf 'A%.0s' {1..43})" 8.8.8.8 "$bootstrap_id" "$orchestration_work" ||
    fail 'successful orchestration failed'
  [[ "$(tr '\n' ' ' < "$actions")" == 'install ' ]] ||
    fail 'successful orchestration unexpectedly rolled back'
  [[ "$CONTROLLER_LANDING_BOOTSTRAP_LAST_ROLLBACK" == not_needed ]] ||
    fail 'successful orchestration reported rollback'
)
rm -f -- "$orchestration_work/public-key"
(
  actions="$work/actions-probe-failure"
  : > "$actions"
  controller_landing_bootstrap_public_key() { cp "$fixture_public_key" "$2"; chmod 600 "$2"; }
  controller_landing_send_bootstrap_action_in_work() { printf '%s\n' "$1" >> "$actions"; return 0; }
  controller_landing_remove_bootstrap_action_files() { return 0; }
  controller_test_landing_registration_channel() { return 1; }
  if controller_bootstrap_landing_channel_in_work e2e-local 8.8.8.8 22 \
      "SHA256:$(printf 'A%.0s' {1..43})" 8.8.8.8 "$bootstrap_id" "$orchestration_work"; then
    fail 'probe failure was reported as success'
  fi
  [[ "$(tr '\n' ' ' < "$actions")" == 'install rollback ' ]] ||
    fail 'probe failure did not trigger rollback'
  [[ "$CONTROLLER_LANDING_BOOTSTRAP_LAST_ROLLBACK" == completed ]] ||
    fail 'completed rollback was not recorded'
)
rm -f -- "$orchestration_work/public-key"
(
  actions="$work/actions-install-uncertain"
  : > "$actions"
  controller_landing_bootstrap_public_key() { cp "$fixture_public_key" "$2"; chmod 600 "$2"; }
  controller_landing_send_bootstrap_action_in_work() {
    printf '%s\n' "$1" >> "$actions"
    [[ "$1" == rollback ]]
  }
  controller_landing_remove_bootstrap_action_files() { return 0; }
  controller_test_landing_registration_channel() { fail 'probe ran without confirmed install'; }
  if controller_bootstrap_landing_channel_in_work e2e-local 8.8.8.8 22 \
      "SHA256:$(printf 'A%.0s' {1..43})" 8.8.8.8 "$bootstrap_id" "$orchestration_work"; then
    fail 'uncertain install was reported as success'
  fi
  [[ "$(tr '\n' ' ' < "$actions")" == 'install rollback ' ]] ||
    fail 'uncertain install did not trigger rollback'
)

printf 'landing bootstrap tests passed\n'
