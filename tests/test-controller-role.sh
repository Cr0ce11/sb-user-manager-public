#!/usr/bin/env bash
# 测试桩由动态 source 的入口角色函数间接调用。
# shellcheck disable=SC2016,SC2317,SC2329
set -Eeuo pipefail

cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

export SB_USER_MANAGER_LIBRARY=true
export SB_CONTROLLER_STATE_FILE="$work/role/state/controller-state.json"
export SB_CONTROLLER_SECRET_DIR="$work/role/secrets"
export SB_CONTROLLER_STATE_LOCK_FILE="$work/role/lock/controller-state.lock"
export SB_CONTROLLER_ROLE_OS_RELEASE_FILE="$work/os-release"
export SB_CONTROLLER_ROLE_DEPENDENCY_DIR="$work/dependencies"
export SB_CONTROLLER_ROLE_TEST_EUID=0
export SB_CONTROLLER_ROLE_TEST_UNAME_SYSTEM=Linux
export SB_CONTROLLER_ROLE_TEST_UNAME_MACHINE=x86_64
export SB_SYSTEM_ROOT="$work/system-root"

# shellcheck source=../sb-user-manager.sh
source ./sb-user-manager.sh

fail() {
  printf 'controller role test failed: %s\n' "$1" >&2
  exit 1
}

# macOS 本地门禁没有 flock；生产支持范围 Debian 12 由真实 flock 覆盖。
if ! command -v flock >/dev/null 2>&1; then
  flock() { return 0; }
fi

prepare_platform() {
  printf 'ID=debian\nVERSION_ID="12"\n' > "$CONTROLLER_ROLE_OS_RELEASE_FILE"
  chmod 644 "$CONTROLLER_ROLE_OS_RELEASE_FILE"
}

prepare_dependencies() {
  local name true_bin
  if [[ -x /usr/bin/true ]]; then true_bin=/usr/bin/true
  else true_bin=/bin/true
  fi
  mkdir -p "$SB_CONTROLLER_ROLE_DEPENDENCY_DIR"
  chmod 700 "$SB_CONTROLLER_ROLE_DEPENDENCY_DIR"
  while IFS= read -r name; do
    cp "$true_bin" "$SB_CONTROLLER_ROLE_DEPENDENCY_DIR/$name"
    chmod 755 "$SB_CONTROLLER_ROLE_DEPENDENCY_DIR/$name"
  done < <(controller_role_required_dependencies)
}

set_role_case() {
  local name="$1"
  CONTROLLER_STATE_FILE="$work/$name/state/controller-state.json"
  CONTROLLER_SECRET_DIR="$work/$name/secrets"
  CONTROLLER_STATE_LOCK_FILE="$work/$name/lock/controller-state.lock"
  SB_SYSTEM_ROOT="$work/$name/system-root"
  export SB_SYSTEM_ROOT
}

prepare_platform
prepare_dependencies

# 预检只读，成功时不创建任何角色文件或目录。
controller_role_preflight || fail 'ready preflight rejected'
[[ "$CONTROLLER_ROLE_LAST_STATUS" == ready && -z "$CONTROLLER_ROLE_LAST_DETAIL" ]]
[[ ! -e "$CONTROLLER_STATE_FILE" && ! -e "$CONTROLLER_SECRET_DIR" ]]

# 全新环境可以初始化；重复执行不重置合法状态。
initialize_entry_controller_role || fail 'fresh role initialization rejected'
[[ "$CONTROLLER_ROLE_LAST_STATUS" == initialized ]]
validate_controller_state_file "$CONTROLLER_STATE_FILE"
jq -e '. == {schema_version:1,role:"entry-controller",revision:0,landings:[]}' \
  "$CONTROLLER_STATE_FILE" >/dev/null
cp "$CONTROLLER_STATE_FILE" "$work/initialized.snapshot"
initialize_entry_controller_role || fail 'idempotent role initialization rejected'
[[ "$CONTROLLER_ROLE_LAST_STATUS" == already_initialized ]]
cmp -s "$CONTROLLER_STATE_FILE" "$work/initialized.snapshot"

# /run 下的锁目录重启后可能消失；合法角色仍应只读识别，不能因此报损坏或重建锁。
rm -rf "$(dirname "$CONTROLLER_STATE_LOCK_FILE")"
initialize_entry_controller_role || fail 'valid role rejected after ephemeral lock cleanup'
[[ "$CONTROLLER_ROLE_LAST_STATUS" == already_initialized ]]
[[ ! -e "$CONTROLLER_STATE_LOCK_FILE" && ! -e "$(dirname "$CONTROLLER_STATE_LOCK_FILE")" ]]
cmp -s "$CONTROLLER_STATE_FILE" "$work/initialized.snapshot"

# 缺失和不安全依赖都必须在任何持久修改前给出稳定原因。
set_role_case missing-dependency
rm "$SB_CONTROLLER_ROLE_DEPENDENCY_DIR/ssh"
if initialize_entry_controller_role; then fail 'missing dependency accepted'; fi
[[ "$CONTROLLER_ROLE_LAST_STATUS" == missing_dependency &&
   "$CONTROLLER_ROLE_LAST_DETAIL" == ssh ]]
[[ ! -e "$CONTROLLER_STATE_FILE" && ! -e "$CONTROLLER_SECRET_DIR" ]]
if [[ -x /usr/bin/true ]]; then cp /usr/bin/true "$SB_CONTROLLER_ROLE_DEPENDENCY_DIR/ssh"
else cp /bin/true "$SB_CONTROLLER_ROLE_DEPENDENCY_DIR/ssh"
fi
chmod 755 "$SB_CONTROLLER_ROLE_DEPENDENCY_DIR/ssh"

set_role_case invalid-dependency-root
valid_dependency_root="$SB_CONTROLLER_ROLE_DEPENDENCY_DIR"
SB_CONTROLLER_ROLE_DEPENDENCY_DIR=relative-dependencies
if initialize_entry_controller_role; then fail 'relative dependency root accepted'; fi
[[ "$CONTROLLER_ROLE_LAST_STATUS" == unsafe_runtime &&
   "$CONTROLLER_ROLE_LAST_DETAIL" == dependency_root ]]
[[ ! -e "$CONTROLLER_STATE_FILE" && ! -e "$CONTROLLER_SECRET_DIR" ]]
SB_CONTROLLER_ROLE_DEPENDENCY_DIR="$valid_dependency_root"

set_role_case unsafe-dependency
chmod 777 "$SB_CONTROLLER_ROLE_DEPENDENCY_DIR/openssl"
if initialize_entry_controller_role; then fail 'unsafe dependency accepted'; fi
[[ "$CONTROLLER_ROLE_LAST_STATUS" == unsafe_dependency &&
   "$CONTROLLER_ROLE_LAST_DETAIL" == openssl ]]
[[ ! -e "$CONTROLLER_STATE_FILE" && ! -e "$CONTROLLER_SECRET_DIR" ]]
chmod 755 "$SB_CONTROLLER_ROLE_DEPENDENCY_DIR/openssl"

# 同名 shell 函数或其他 PATH 命令不能冒充生产固定依赖。
(
  unset SB_CONTROLLER_ROLE_DEPENDENCY_DIR
  ssh() { return 0; }
  unsafe_path="$(controller_role_dependency_path ssh)"
  [[ "$unsafe_path" == ssh ]]
  if controller_role_dependency_is_safe ssh "$unsafe_path"; then
    fail 'PATH function accepted as a fixed production dependency'
  fi
)

# 非 root 或不支持的平台均拒绝，且不创建角色状态。
set_role_case non-root
SB_CONTROLLER_ROLE_TEST_EUID=1000
if initialize_entry_controller_role; then fail 'non-root initialization accepted'; fi
[[ "$CONTROLLER_ROLE_LAST_STATUS" == not_root ]]
[[ ! -e "$CONTROLLER_STATE_FILE" ]]
SB_CONTROLLER_ROLE_TEST_EUID=0

set_role_case wrong-architecture
SB_CONTROLLER_ROLE_TEST_UNAME_MACHINE=aarch64
if initialize_entry_controller_role; then fail 'unsupported architecture accepted'; fi
[[ "$CONTROLLER_ROLE_LAST_STATUS" == unsupported_platform ]]
[[ ! -e "$CONTROLLER_STATE_FILE" ]]
SB_CONTROLLER_ROLE_TEST_UNAME_MACHINE=x86_64

set_role_case wrong-release
printf 'ID=debian\nVERSION_ID="13"\n' > "$CONTROLLER_ROLE_OS_RELEASE_FILE"
chmod 644 "$CONTROLLER_ROLE_OS_RELEASE_FILE"
if initialize_entry_controller_role; then fail 'unsupported release accepted'; fi
[[ "$CONTROLLER_ROLE_LAST_STATUS" == unsupported_platform ]]
[[ ! -e "$CONTROLLER_STATE_FILE" ]]
prepare_platform

# 首次初始化不能把现有 standalone/部分部署静默转换成入口角色。
set_role_case role-conflict
mkdir -p "$SB_SYSTEM_ROOT/etc"
: > "$SB_SYSTEM_ROOT/etc/sb-user-manager.conf"
if initialize_entry_controller_role; then fail 'existing deployment accepted'; fi
[[ "$CONTROLLER_ROLE_LAST_STATUS" == role_conflict &&
   "$CONTROLLER_ROLE_LAST_DETAIL" == managed_partial ]]
[[ ! -e "$CONTROLLER_STATE_FILE" && ! -e "$CONTROLLER_SECRET_DIR" ]]

# 完整旧环境的冲突判断也只能读文件足迹，不能执行旧二进制或 systemctl。
set_role_case complete-role-conflict
while IFS= read -r existing_path; do
  mkdir -p "$(dirname "$SB_SYSTEM_ROOT$existing_path")"
  : > "$SB_SYSTEM_ROOT$existing_path"
done <<'EOF'
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
systemctl() { : > "$work/unexpected-environment-command"; return 1; }
if initialize_entry_controller_role; then fail 'complete existing deployment accepted'; fi
unset -f systemctl
[[ "$CONTROLLER_ROLE_LAST_STATUS" == role_conflict &&
   "$CONTROLLER_ROLE_LAST_DETAIL" == managed_complete ]]
[[ ! -e "$work/unexpected-environment-command" && ! -e "$CONTROLLER_STATE_FILE" ]]

# 非法既有状态、符号链接与含未知内容的局部残留都失败关闭且不被覆盖。
set_role_case invalid-state
mkdir -p "$(dirname "$CONTROLLER_STATE_FILE")" "$CONTROLLER_SECRET_DIR"
chmod 700 "$(dirname "$CONTROLLER_STATE_FILE")" "$CONTROLLER_SECRET_DIR"
printf '{"role":"standalone"}\n' > "$CONTROLLER_STATE_FILE"
chmod 600 "$CONTROLLER_STATE_FILE"
cp "$CONTROLLER_STATE_FILE" "$work/invalid-state.snapshot"
if initialize_entry_controller_role; then fail 'invalid existing state accepted'; fi
[[ "$CONTROLLER_ROLE_LAST_STATUS" == state_invalid &&
   "$CONTROLLER_ROLE_LAST_DETAIL" == existing_artifacts ]]
cmp -s "$CONTROLLER_STATE_FILE" "$work/invalid-state.snapshot"

set_role_case symlink-state
mkdir -p "$(dirname "$CONTROLLER_STATE_FILE")"
chmod 700 "$(dirname "$CONTROLLER_STATE_FILE")"
ln -s "$work/missing-target" "$CONTROLLER_STATE_FILE"
if initialize_entry_controller_role; then fail 'state symlink accepted'; fi
[[ "$CONTROLLER_ROLE_LAST_STATUS" == state_invalid ]]
[[ -L "$CONTROLLER_STATE_FILE" ]]

set_role_case partial-artifacts
mkdir -p "$CONTROLLER_SECRET_DIR"
chmod 700 "$CONTROLLER_SECRET_DIR"
: > "$CONTROLLER_SECRET_DIR/unexpected"
chmod 600 "$CONTROLLER_SECRET_DIR/unexpected"
if initialize_entry_controller_role; then fail 'unknown partial artifact accepted'; fi
[[ "$CONTROLLER_ROLE_LAST_STATUS" == state_invalid &&
   "$CONTROLLER_ROLE_LAST_DETAIL" == partial_artifacts ]]
[[ ! -e "$CONTROLLER_STATE_FILE" ]]

# Debian 12 的 root CI 额外验证真实固定路径与发行版依赖，不创建控制器状态。
if [[ "$EUID" -eq 0 && "$(uname -s)" == Linux && "$(uname -m)" == x86_64 &&
      -f /usr/lib/os-release ]]; then
  (
    SB_USER_MANAGER_LIBRARY=false
    unset SB_CONTROLLER_ROLE_DEPENDENCY_DIR SB_CONTROLLER_ROLE_TEST_EUID
    unset SB_CONTROLLER_ROLE_TEST_UNAME_SYSTEM SB_CONTROLLER_ROLE_TEST_UNAME_MACHINE
    CONTROLLER_STATE_FILE=/var/lib/sb-user-manager/controller-state.json
    CONTROLLER_SECRET_DIR=/etc/sb-user-manager/controller-secrets
    CONTROLLER_STATE_LOCK_FILE=/run/lock/sb-user-manager/controller-state.lock
    CONTROLLER_ROLE_OS_RELEASE_FILE=/usr/lib/os-release
    controller_role_preflight ||
      fail "production preflight rejected: $CONTROLLER_ROLE_LAST_STATUS/$CONTROLLER_ROLE_LAST_DETAIL"
    [[ "$CONTROLLER_ROLE_LAST_STATUS" == ready ]]
  )
fi

printf 'controller role tests passed\n'
