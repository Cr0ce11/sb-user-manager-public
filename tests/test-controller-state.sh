#!/usr/bin/env bash
# 测试桩由动态 source 的控制器函数间接调用。
# shellcheck disable=SC2016,SC2317
set -Eeuo pipefail

cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

export SB_USER_MANAGER_LIBRARY=true
export SB_CONTROLLER_STATE_FILE="$work/state/controller-state.json"
export SB_CONTROLLER_SECRET_DIR="$work/secrets"
export SB_CONTROLLER_STATE_LOCK_FILE="$work/lock/controller-state.lock"
# shellcheck source=../sb-user-manager.sh
source ./sb-user-manager.sh

# macOS 本地门禁没有 flock；生产支持范围 Debian 12 由真实 flock 覆盖。
if ! command -v flock >/dev/null 2>&1; then
  flock() { return 0; }
fi

fail() {
  printf 'controller state test failed: %s\n' "$1" >&2
  exit 1
}

file_mode() {
  manager_file_mode "$1"
}

write_valid_state() {
  local path="$1"
  jq -n --arg secret_dir "$CONTROLLER_SECRET_DIR" '
    {
      schema_version: 1,
      role: "entry-controller",
      revision: 7,
      landings: [
        {
          id: "landing-a",
          display_name: "测试落地 A",
          address: "192.0.2.10",
          ssh_port: 22,
          ssh_host_fingerprint: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
          gateway_port: 24443,
          status: "active",
          desired_revision: 2,
          applied_revision: 2,
          config_sha256: ("a" * 64),
          credential_ref: ($secret_dir + "/landing-landing-a.json")
        },
        {
          id: "landing-b",
          display_name: "测试落地 B",
          address: "landing-b.example.com",
          ssh_port: 2222,
          ssh_host_fingerprint: "SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
          gateway_port: 24444,
          status: "pending",
          desired_revision: 3,
          applied_revision: 0,
          config_sha256: null,
          credential_ref: ($secret_dir + "/landing-landing-b.json")
        }
      ]
    }
  ' > "$path"
  chmod 600 "$path"
}

expect_invalid_json() {
  local label="$1" filter="$2" path="$work/invalid-${1}.json"
  shift 2
  jq "$@" "$filter" "$valid_state" > "$path"
  chmod 600 "$path"
  if validate_controller_state_file "$path"; then
    fail "invalid sample accepted: $label"
  fi
}

# 仅加载脚本不能创建 v5 状态，确保当前 v4 服务器行为不变。
[[ ! -e "$CONTROLLER_STATE_FILE" && ! -L "$CONTROLLER_STATE_FILE" ]]
[[ "$STATE_SCHEMA_VERSION" == 7 ]]
[[ "$MIGRATION_FORMAT_VERSION" == 1 && "$MIGRATION_BUNDLE_VERSION" == 1 ]]
if grep -Fq 'init_controller_state' <<<"$(declare -f main)"; then
  fail 'main must not initialize the controller state'
fi
if grep -Fq 'init_controller_state' <<<"$(declare -f interactive_main)"; then
  fail 'the v4 menu must not initialize the controller state'
fi

# 空状态首次初始化安全且幂等。
init_controller_state
validate_controller_state_file
[[ "$(file_mode "$CONTROLLER_STATE_FILE")" == 600 ]]
[[ "$(file_mode "$(dirname "$CONTROLLER_STATE_FILE")")" == 700 ]]
[[ "$(file_mode "$CONTROLLER_SECRET_DIR")" == 700 ]]
jq -e '. == {schema_version:1,role:"entry-controller",revision:0,landings:[]}' \
  "$CONTROLLER_STATE_FILE" >/dev/null
cp "$CONTROLLER_STATE_FILE" "$work/initialized.snapshot"
init_controller_state
cmp -s "$CONTROLLER_STATE_FILE" "$work/initialized.snapshot"

# 单落地和多落地合法样本均可验证；原子写入只在 revision 提升后生效。
valid_state="$work/valid-state.json"
write_valid_state "$valid_state"
validate_controller_state_file "$valid_state"
single_state="$work/valid-single-state.json"
jq '.revision = 3 | .landings = [.landings[0]]' "$valid_state" > "$single_state"
chmod 600 "$single_state"
validate_controller_state_file "$single_state"

atomic_controller_state_update '.revision = 7 | .landings = $candidate[0].landings' \
  --slurpfile candidate "$valid_state"
cmp -s "$CONTROLLER_STATE_FILE" "$valid_state"

# schema、角色、字段、身份、网络、revision 和秘密边界使用严格拒绝策略。
expect_invalid_json schema '.schema_version = 2'
expect_invalid_json role '.role = "standalone"'
expect_invalid_json root-field '.unexpected = true'
expect_invalid_json landing-field '.landings[0].password = "must-not-be-inline"'
expect_invalid_json duplicate-id '.landings[1].id = .landings[0].id | .landings[1].credential_ref = .landings[0].credential_ref'
expect_invalid_json invalid-id '.landings[0].id = "Landing_A"'
expect_invalid_json empty-name '.landings[0].display_name = ""'
expect_invalid_json control-name '.landings[0].display_name = "bad\nname"'
expect_invalid_json invalid-ip '.landings[0].address = "999.1.1.1"'
expect_invalid_json invalid-host '.landings[0].address = "bad host.example"'
expect_invalid_json ssh-port '.landings[0].ssh_port = 0'
expect_invalid_json gateway-port '.landings[0].gateway_port = 65536'
expect_invalid_json fingerprint '.landings[0].ssh_host_fingerprint = "SHA256:short"'
expect_invalid_json status '.landings[0].status = "unknown"'
expect_invalid_json desired-revision '.landings[0].desired_revision = -1'
expect_invalid_json applied-revision '.landings[0].applied_revision = 3'
expect_invalid_json unsafe-revision '.revision = 9007199254740992'
expect_invalid_json config-digest '.landings[0].config_sha256 = "ABC"'
expect_invalid_json relative-secret '.landings[0].credential_ref = "landing-a.json"'
expect_invalid_json outside-secret '.landings[0].credential_ref = "/tmp/landing-landing-a.json"'
expect_invalid_json mismatched-secret '.landings[0].credential_ref = ($ref + "/landing-other.json")' \
  --arg ref "$CONTROLLER_SECRET_DIR"

# 文件自身必须拒绝宽权限与符号链接。
wide_state="$work/wide-state.json"
cp "$valid_state" "$wide_state"
chmod 644 "$wide_state"
if validate_controller_state_file "$wide_state"; then
  fail 'wide state permissions accepted'
fi
linked_state="$work/linked-state.json"
ln -s "$valid_state" "$linked_state"
if validate_controller_state_file "$linked_state"; then
  fail 'symbolic-link state accepted'
fi
multiple_state="$work/multiple-state.json"
printf '%s\n%s\n' "$(cat "$valid_state")" "$(cat "$valid_state")" > "$multiple_state"
chmod 600 "$multiple_state"
if validate_controller_state_file "$multiple_state"; then
  fail 'multiple JSON documents accepted as one state'
fi

# 更新失败必须保留原状态并清理同目录临时文件。
cp "$CONTROLLER_STATE_FILE" "$work/before-failure.snapshot"
if atomic_controller_state_update 'error("forced jq failure")' >/dev/null 2>&1; then
  fail 'jq failure unexpectedly committed'
fi
cmp -s "$CONTROLLER_STATE_FILE" "$work/before-failure.snapshot"

if atomic_controller_state_update '.revision = 8 | .role = "standalone"'; then
  fail 'invalid candidate unexpectedly committed'
fi
cmp -s "$CONTROLLER_STATE_FILE" "$work/before-failure.snapshot"

if atomic_controller_state_update '.revision = 6'; then
  fail 'global revision rollback unexpectedly committed'
fi
cmp -s "$CONTROLLER_STATE_FILE" "$work/before-failure.snapshot"

if atomic_controller_state_update '.landings[0].status = "disabled"'; then
  fail 'landing change without global revision unexpectedly committed'
fi
cmp -s "$CONTROLLER_STATE_FILE" "$work/before-failure.snapshot"

if atomic_controller_state_update '.revision = 8 | .landings[0].desired_revision = 1 | .landings[0].applied_revision = 1'; then
  fail 'landing revision rollback unexpectedly committed'
fi
cmp -s "$CONTROLLER_STATE_FILE" "$work/before-failure.snapshot"

(
  chmod() { return 77; }
  if atomic_controller_state_update '.revision = 8'; then
    fail 'chmod failure unexpectedly committed'
  fi
)
cmp -s "$CONTROLLER_STATE_FILE" "$work/before-failure.snapshot"

(
  mv() { return 78; }
  if atomic_controller_state_update '.revision = 8'; then
    fail 'mv failure unexpectedly committed'
  fi
)
cmp -s "$CONTROLLER_STATE_FILE" "$work/before-failure.snapshot"
[[ "$(find "$(dirname "$CONTROLLER_STATE_FILE")" -maxdepth 1 -type f -name '.controller-state.*' | wc -l | tr -d ' ')" == 0 ]]

# 锁文件使用符号链接时，初始化必须在写入前停止。
symlink_case="$work/symlink-case"
mkdir -m 700 "$symlink_case"
CONTROLLER_STATE_FILE="$symlink_case/state/controller-state.json"
CONTROLLER_SECRET_DIR="$symlink_case/secrets"
CONTROLLER_STATE_LOCK_FILE="$symlink_case/controller-state.lock"
ln -s "$work/real-lock-target" "$CONTROLLER_STATE_LOCK_FILE"
if init_controller_state; then
  fail 'symbolic-link lock accepted'
fi
[[ ! -e "$CONTROLLER_STATE_FILE" ]]

printf 'controller state tests passed\n'
