#!/usr/bin/env bash
# 测试桩由动态 source 的只读角色识别函数间接调用。
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail

cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

export SB_USER_MANAGER_LIBRARY=true
export SB_CONTROLLER_STATE_FILE="$work/initial/root/var/lib/sb-user-manager/controller-state.json"
export SB_CONTROLLER_SECRET_DIR="$work/initial/root/etc/sb-user-manager/controller-secrets"
export SB_CONTROLLER_STATE_LOCK_FILE="$work/initial/root/run/lock/sb-user-manager/controller-state.lock"
export SB_CONTROLLER_ROLE_OS_RELEASE_FILE="$work/os-release"
export SB_CONTROLLER_ROLE_TEST_EUID=0
export SB_SYSTEM_ROOT="$work/initial/root"

# shellcheck source=../sb-user-manager.sh
source ./sb-user-manager.sh

# macOS 本地门禁没有 flock；控制器状态初始化仅写测试目录。
if ! command -v flock >/dev/null 2>&1; then
  flock() { return 0; }
fi

fail() {
  printf 'manager role detection test failed: %s\n' "$1" >&2
  exit 1
}

reset_role_case() {
  local name="$1" root
  root="$work/$name/root"
  CONTROLLER_STATE_FILE="$root/var/lib/sb-user-manager/controller-state.json"
  CONTROLLER_SECRET_DIR="$root/etc/sb-user-manager/controller-secrets"
  CONTROLLER_STATE_LOCK_FILE="$root/run/lock/sb-user-manager/controller-state.lock"
  SB_SYSTEM_ROOT="$root"
  export SB_SYSTEM_ROOT
  SB_CONTROLLER_ROLE_TEST_EUID=0
}

create_path() {
  local path="$SB_SYSTEM_ROOT$1"
  mkdir -p "$(dirname "$path")"
  : > "$path"
}

create_complete_standalone_footprint() {
  local path
  while IFS= read -r path; do create_path "$path"; done <<'EOF'
/etc/sb-user-manager.conf
/etc/sing-box/config.json
/etc/sing-box/managed-users.json
/usr/local/sbin/sb-user-manager
/usr/local/bin/sing-box
/usr/local/bin/nfuse
/etc/systemd/system/sing-box.service
/etc/systemd/system/nfuse.service
/etc/systemd/system/sb-user-expiry.service
/etc/systemd/system/sb-user-expiry.timer
EOF
}

landing_identity_path() {
  landing_channel_path "$LANDING_CHANNEL_IDENTITY_PATH"
}

write_landing_marker() {
  local path
  path="$(landing_identity_path)"
  mkdir -p "$(dirname "$path")"
  printf 'valid-test-identity\n' > "$path"
  chmod 600 "$path"
}

assert_detected_role() {
  local expected="$1"
  detect_manager_role || fail "role was rejected: $expected"
  [[ "$MANAGER_ROLE" == "$expected" &&
     "$MANAGER_ROLE_DETECTION_STATUS" == role_detected &&
     -z "$MANAGER_ROLE_DETECTION_DETAIL" ]] ||
    fail "wrong role result: $MANAGER_ROLE/$MANAGER_ROLE_DETECTION_STATUS/$MANAGER_ROLE_DETECTION_DETAIL"
}

# 全新环境识别为尚未部署，且识别过程不创建任何目录或文件。
reset_role_case undeployed
[[ ! -e "$SB_SYSTEM_ROOT" ]]
assert_detected_role undeployed
[[ ! -e "$SB_SYSTEM_ROOT" ]]

# 完整 standalone 只读识别，不执行其二进制或 systemd。
reset_role_case standalone
create_complete_standalone_footprint
cat > "$SB_SYSTEM_ROOT/usr/local/bin/sing-box" <<EOF
#!/bin/sh
: > "$work/unexpected-runtime-call"
EOF
chmod 700 "$SB_SYSTEM_ROOT/usr/local/bin/sing-box"
systemctl() { : > "$work/unexpected-runtime-call"; return 1; }
standalone_before="$(find "$SB_SYSTEM_ROOT" -print | LC_ALL=C sort)"
assert_detected_role standalone
unset -f systemctl
[[ ! -e "$work/unexpected-runtime-call" ]]
[[ "$(find "$SB_SYSTEM_ROOT" -print | LC_ALL=C sort)" == "$standalone_before" ]]

# 合法控制器状态是 entry-controller 身份，重复识别不改写状态。
reset_role_case entry-controller
init_controller_state || fail 'could not create valid controller fixture'
cp "$CONTROLLER_STATE_FILE" "$work/controller.snapshot"
assert_detected_role entry-controller
cmp -s "$CONTROLLER_STATE_FILE" "$work/controller.snapshot"
assert_detected_role entry-controller
cmp -s "$CONTROLLER_STATE_FILE" "$work/controller.snapshot"

# landing 的完整 identity 校验由落地模块负责；识别层只接受其成功结果。
reset_role_case landing
write_landing_marker
(
  validate_landing_channel_identity_file() {
    [[ "$1" == "$(landing_identity_path)" ]] &&
      grep -Fxq 'valid-test-identity' "$1"
  }
  assert_detected_role landing
)
grep -Fxq 'valid-test-identity' "$(landing_identity_path)"

# 两种角色标记或控制器与落地残留并存时，必须在调用解析器前拒绝。
reset_role_case mixed-markers
init_controller_state || fail 'could not create mixed controller fixture'
write_landing_marker
(
  controller_role_existing_artifacts_are_trusted() {
    : > "$work/unexpected-role-validator"
    return 0
  }
  validate_landing_channel_identity_file() {
    : > "$work/unexpected-role-validator"
    return 0
  }
  if detect_manager_role; then fail 'mixed role markers were accepted'; fi
  [[ "$MANAGER_ROLE" == unknown &&
     "$MANAGER_ROLE_DETECTION_STATUS" == role_conflict &&
     "$MANAGER_ROLE_DETECTION_DETAIL" == mixed_role_markers ]]
)
[[ ! -e "$work/unexpected-role-validator" ]]

reset_role_case controller-with-landing-footprint
init_controller_state || fail 'could not create controller fixture'
create_path "$LANDING_CHANNEL_AGENT_PATH"
if detect_manager_role; then fail 'controller with landing footprint was accepted'; fi
[[ "$MANAGER_ROLE_DETECTION_STATUS" == role_conflict &&
   "$MANAGER_ROLE_DETECTION_DETAIL" == mixed_role_markers ]]

# 非法控制器状态、符号链接和非法 landing identity 均失败关闭。
reset_role_case invalid-controller
mkdir -p "$(dirname "$CONTROLLER_STATE_FILE")" "$CONTROLLER_SECRET_DIR"
chmod 700 "$(dirname "$CONTROLLER_STATE_FILE")" "$CONTROLLER_SECRET_DIR"
printf '{"role":"standalone"}\n' > "$CONTROLLER_STATE_FILE"
chmod 600 "$CONTROLLER_STATE_FILE"
if detect_manager_role; then fail 'invalid controller state was accepted'; fi
[[ "$MANAGER_ROLE_DETECTION_STATUS" == role_invalid &&
   "$MANAGER_ROLE_DETECTION_DETAIL" == controller_state ]]

reset_role_case symlink-controller
mkdir -p "$(dirname "$CONTROLLER_STATE_FILE")"
ln -s "$work/missing-controller-target" "$CONTROLLER_STATE_FILE"
if detect_manager_role; then fail 'controller state symlink was accepted'; fi
[[ "$MANAGER_ROLE_DETECTION_STATUS" == role_invalid &&
   "$MANAGER_ROLE_DETECTION_DETAIL" == controller_state ]]
[[ -L "$CONTROLLER_STATE_FILE" ]]

reset_role_case invalid-landing
write_landing_marker
if detect_manager_role 2>/dev/null; then fail 'invalid landing identity was accepted'; fi
[[ "$MANAGER_ROLE_DETECTION_STATUS" == role_invalid &&
   "$MANAGER_ROLE_DETECTION_DETAIL" == landing_identity ]]
grep -Fxq 'valid-test-identity' "$(landing_identity_path)"

# 没有身份标记的落地残留、standalone 部分部署和外部环境不得冒充 fresh。
reset_role_case partial-landing
create_path "$LANDING_CHANNEL_AGENT_PATH"
if detect_manager_role; then fail 'partial landing footprint was accepted'; fi
[[ "$MANAGER_ROLE_DETECTION_STATUS" == environment_incomplete &&
   "$MANAGER_ROLE_DETECTION_DETAIL" == landing ]]

reset_role_case partial-standalone
create_path /etc/sb-user-manager.conf
if detect_manager_role; then fail 'partial standalone footprint was accepted'; fi
[[ "$MANAGER_ROLE_DETECTION_STATUS" == environment_incomplete &&
   "$MANAGER_ROLE_DETECTION_DETAIL" == standalone ]]

reset_role_case external-environment
create_path /usr/local/bin/sing-box
if detect_manager_role; then fail 'external environment was accepted'; fi
[[ "$MANAGER_ROLE_DETECTION_STATUS" == external_environment &&
   -z "$MANAGER_ROLE_DETECTION_DETAIL" ]]

reset_role_case partial-controller-artifacts
mkdir -p "$CONTROLLER_SECRET_DIR"
chmod 700 "$CONTROLLER_SECRET_DIR"
: > "$CONTROLLER_SECRET_DIR/unexpected"
chmod 600 "$CONTROLLER_SECRET_DIR/unexpected"
if detect_manager_role; then fail 'partial controller artifacts were accepted'; fi
[[ "$MANAGER_ROLE_DETECTION_STATUS" == role_invalid &&
   "$MANAGER_ROLE_DETECTION_DETAIL" == controller_artifacts ]]

# 参数、权限和固定路径在读取角色内容前拒绝。
reset_role_case invalid-input
invalid_input_rc=0
detect_manager_role unexpected || invalid_input_rc=$?
[[ "$invalid_input_rc" == 64 ]] || fail 'unexpected argument returned the wrong status'
[[ ! -e "$SB_SYSTEM_ROOT" ]]

reset_role_case non-root
SB_CONTROLLER_ROLE_TEST_EUID=1000
if detect_manager_role; then fail 'non-root role detection was accepted'; fi
[[ "$MANAGER_ROLE_DETECTION_STATUS" == not_root ]]
[[ ! -e "$SB_SYSTEM_ROOT" ]]

reset_role_case unsafe-runtime-path
valid_controller_state_file="$CONTROLLER_STATE_FILE"
CONTROLLER_STATE_FILE=relative-controller-state.json
if detect_manager_role; then fail 'relative controller path was accepted'; fi
[[ "$MANAGER_ROLE_DETECTION_STATUS" == unsafe_runtime &&
   "$MANAGER_ROLE_DETECTION_DETAIL" == fixed_paths ]]
CONTROLLER_STATE_FILE="$valid_controller_state_file"
[[ ! -e "$SB_SYSTEM_ROOT" ]]

printf 'manager role detection tests passed\n'
