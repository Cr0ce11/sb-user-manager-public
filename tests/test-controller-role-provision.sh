#!/usr/bin/env bash
# 测试桩由动态 source 的入口角色编排函数间接调用。
# shellcheck disable=SC2016,SC2034,SC2317,SC2329
set -Eeuo pipefail

cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

if [[ -x /usr/bin/true ]]; then true_bin=/usr/bin/true
else true_bin=/bin/true
fi

mkdir -p "$work/bin"
apt_stub="$work/bin/apt-get"
env_stub="$work/bin/env"
cat > "$env_stub" <<'EOF'
#!/bin/sh
exec /usr/bin/env "$@"
EOF
cat > "$apt_stub" <<'EOF'
#!/usr/bin/env bash
set -eu
[[ -z "${APT_CONFIG:-}" ]] || exit 43
printf '%s\n' "$*" >> "$SB_CONTROLLER_ROLE_TEST_APT_LOG"
stage=unknown
for argument in "$@"; do
  case "$argument" in
    update) stage=update ;;
    install) stage=install ;;
  esac
done
if [[ "${SB_CONTROLLER_ROLE_TEST_APT_FAIL_STAGE:-}" == "$stage" ]]; then
  exit 42
fi
if [[ "$stage" == install ]]; then
  cp "$SB_CONTROLLER_ROLE_TEST_TRUE_BIN" "$SB_CONTROLLER_ROLE_TEST_MISSING_PATH"
  chmod 755 "$SB_CONTROLLER_ROLE_TEST_MISSING_PATH"
fi
EOF
chmod 700 "$env_stub" "$apt_stub"

export SB_USER_MANAGER_LIBRARY=true
export SB_CONTROLLER_STATE_FILE="$work/initial/state/controller-state.json"
export SB_CONTROLLER_SECRET_DIR="$work/initial/secrets"
export SB_CONTROLLER_STATE_LOCK_FILE="$work/initial/lock/controller-state.lock"
export SB_CONTROLLER_ROLE_OS_RELEASE_FILE="$work/os-release"
export SB_CONTROLLER_ROLE_DEPENDENCY_DIR="$work/dependencies"
export SB_CONTROLLER_ROLE_APT_GET_BIN="$apt_stub"
export SB_CONTROLLER_ROLE_ENV_BIN="$env_stub"
export SB_CONTROLLER_ROLE_TEST_EUID=0
export SB_CONTROLLER_ROLE_TEST_UNAME_SYSTEM=Linux
export SB_CONTROLLER_ROLE_TEST_UNAME_MACHINE=x86_64
export SB_CONTROLLER_ROLE_TEST_APT_LOG="$work/apt.log"
export SB_CONTROLLER_ROLE_TEST_TRUE_BIN="$true_bin"
export SB_CONTROLLER_ROLE_TEST_MISSING_PATH="$SB_CONTROLLER_ROLE_DEPENDENCY_DIR/ssh"
export SB_SYSTEM_ROOT="$work/initial/system-root"

# shellcheck source=../sb-user-manager.sh
source ./sb-user-manager.sh

# macOS 本地门禁没有 flock；生产支持范围 Debian 12 由真实 flock 覆盖。
if ! command -v flock >/dev/null 2>&1; then
  flock() { return 0; }
fi

fail() {
  printf 'controller role provision test failed: %s\n' "$1" >&2
  exit 1
}

prepare_platform() {
  printf 'ID=debian\nVERSION_ID="12"\n' > "$CONTROLLER_ROLE_OS_RELEASE_FILE"
  chmod 644 "$CONTROLLER_ROLE_OS_RELEASE_FILE"
}

prepare_dependencies() {
  local name
  mkdir -p "$SB_CONTROLLER_ROLE_DEPENDENCY_DIR"
  chmod 700 "$SB_CONTROLLER_ROLE_DEPENDENCY_DIR"
  while IFS= read -r name; do
    cp "$true_bin" "$SB_CONTROLLER_ROLE_DEPENDENCY_DIR/$name"
    chmod 755 "$SB_CONTROLLER_ROLE_DEPENDENCY_DIR/$name"
  done < <(controller_role_required_dependencies)
}

reset_provision_case() {
  local name="$1"
  mkdir -p "$work/$name"
  CONTROLLER_STATE_FILE="$work/$name/state/controller-state.json"
  CONTROLLER_SECRET_DIR="$work/$name/secrets"
  CONTROLLER_STATE_LOCK_FILE="$work/$name/lock/controller-state.lock"
  SB_SYSTEM_ROOT="$work/$name/system-root"
  export SB_SYSTEM_ROOT
  SB_CONTROLLER_ROLE_TEST_APT_LOG="$work/$name/apt.log"
  SB_CONTROLLER_ROLE_TEST_MISSING_PATH="$SB_CONTROLLER_ROLE_DEPENDENCY_DIR/ssh"
  export SB_CONTROLLER_ROLE_TEST_APT_LOG SB_CONTROLLER_ROLE_TEST_MISSING_PATH
  unset SB_CONTROLLER_ROLE_TEST_APT_FAIL_STAGE
  SB_CONTROLLER_ROLE_TEST_EUID=0
  SB_CONTROLLER_ROLE_TEST_UNAME_MACHINE=x86_64
  CONTROLLER_ROLE_APT_GET_BIN="$apt_stub"
  CONTROLLER_ROLE_ENV_BIN="$env_stub"
  chmod 700 "$apt_stub" "$env_stub"
  prepare_dependencies
}

write_valid_existing_state() {
  mkdir -p "$(dirname "$CONTROLLER_STATE_FILE")" "$CONTROLLER_SECRET_DIR"
  chmod 700 "$(dirname "$CONTROLLER_STATE_FILE")" "$CONTROLLER_SECRET_DIR"
  jq -n --arg secret_dir "$CONTROLLER_SECRET_DIR" '
    {
      schema_version: 1,
      role: "entry-controller",
      revision: 7,
      landings: [{
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
      }]
    }
  ' > "$CONTROLLER_STATE_FILE"
  chmod 600 "$CONTROLLER_STATE_FILE"
  validate_controller_state_file "$CONTROLLER_STATE_FILE"
}

assert_no_apt() {
  [[ ! -e "$SB_CONTROLLER_ROLE_TEST_APT_LOG" ]] || fail 'unexpected APT invocation'
}

assert_no_role_state() {
  [[ ! -e "$CONTROLLER_STATE_FILE" && ! -L "$CONTROLLER_STATE_FILE" ]] ||
    fail 'unexpected controller state'
}

prepare_platform
prepare_dependencies

# 全新且依赖齐全时只初始化一次；再次编排保持状态逐字节不变。
reset_provision_case fresh-ready
provision_entry_controller_role || fail 'fresh ready target was rejected'
[[ "$CONTROLLER_ROLE_LAST_STATUS" == entry_role_initialized ]]
validate_controller_state_file "$CONTROLLER_STATE_FILE"
cp "$CONTROLLER_STATE_FILE" "$work/fresh-ready.snapshot"
assert_no_apt
provision_entry_controller_role || fail 'existing ready role was rejected'
[[ "$CONTROLLER_ROLE_LAST_STATUS" == entry_role_ready ]]
cmp -s "$CONTROLLER_STATE_FILE" "$work/fresh-ready.snapshot"
assert_no_apt

# 全新缺依赖时先完成固定修复再初始化；成功后可以幂等重试。
reset_provision_case fresh-repair
rm "$SB_CONTROLLER_ROLE_TEST_MISSING_PATH"
APT_CONFIG="$work/untrusted-apt.conf"
export APT_CONFIG
provision_entry_controller_role || fail 'fresh missing dependency was not repaired'
unset APT_CONFIG
[[ "$CONTROLLER_ROLE_LAST_STATUS" == entry_role_initialized ]]
validate_controller_state_file "$CONTROLLER_STATE_FILE"
[[ "$(wc -l < "$SB_CONTROLLER_ROLE_TEST_APT_LOG" | tr -d ' ')" == 2 ]]
cp "$CONTROLLER_STATE_FILE" "$work/fresh-repair.snapshot"
provision_entry_controller_role || fail 'repaired fresh role was not idempotent'
[[ "$CONTROLLER_ROLE_LAST_STATUS" == entry_role_ready ]]
cmp -s "$CONTROLLER_STATE_FILE" "$work/fresh-repair.snapshot"

# 合法既有入口只补依赖，不重写 revision、landings 或状态文件。
reset_provision_case existing-repair
write_valid_existing_state
cp "$CONTROLLER_STATE_FILE" "$work/existing.snapshot"
rm "$SB_CONTROLLER_ROLE_TEST_MISSING_PATH"
provision_entry_controller_role || fail 'existing role dependency repair failed'
[[ "$CONTROLLER_ROLE_LAST_STATUS" == entry_role_repaired ]]
cmp -s "$CONTROLLER_STATE_FILE" "$work/existing.snapshot"
[[ "$(wc -l < "$SB_CONTROLLER_ROLE_TEST_APT_LOG" | tr -d ' ')" == 2 ]]
provision_entry_controller_role || fail 'existing repaired role was rejected'
[[ "$CONTROLLER_ROLE_LAST_STATUS" == entry_role_ready ]]
cmp -s "$CONTROLLER_STATE_FILE" "$work/existing.snapshot"

# APT 失败不创建角色状态，清除故障后重试可以收敛。
reset_provision_case apt-retry
rm "$SB_CONTROLLER_ROLE_TEST_MISSING_PATH"
SB_CONTROLLER_ROLE_TEST_APT_FAIL_STAGE=update
export SB_CONTROLLER_ROLE_TEST_APT_FAIL_STAGE
if provision_entry_controller_role; then fail 'APT update failure was accepted'; fi
[[ "$CONTROLLER_ROLE_LAST_STATUS" == dependency_repair_failed &&
   "$CONTROLLER_ROLE_LAST_DETAIL" == apt_update ]]
assert_no_role_state
unset SB_CONTROLLER_ROLE_TEST_APT_FAIL_STAGE
provision_entry_controller_role || fail 'retry after APT failure did not converge'
[[ "$CONTROLLER_ROLE_LAST_STATUS" == entry_role_initialized ]]
validate_controller_state_file "$CONTROLLER_STATE_FILE"

# standalone、外部环境和非法角色残留都在 APT 之前失败关闭。
reset_provision_case standalone-conflict
rm "$SB_CONTROLLER_ROLE_TEST_MISSING_PATH"
mkdir -p "$SB_SYSTEM_ROOT/etc"
: > "$SB_SYSTEM_ROOT/etc/sb-user-manager.conf"
if provision_entry_controller_role; then fail 'standalone footprint was accepted'; fi
[[ "$CONTROLLER_ROLE_LAST_STATUS" == role_conflict &&
   "$CONTROLLER_ROLE_LAST_DETAIL" == managed_partial ]]
assert_no_apt
assert_no_role_state

reset_provision_case external-conflict
rm "$SB_CONTROLLER_ROLE_TEST_MISSING_PATH"
mkdir -p "$SB_SYSTEM_ROOT/usr/local/bin"
: > "$SB_SYSTEM_ROOT/usr/local/bin/sing-box"
if provision_entry_controller_role; then fail 'external footprint was accepted'; fi
[[ "$CONTROLLER_ROLE_LAST_STATUS" == role_conflict &&
   "$CONTROLLER_ROLE_LAST_DETAIL" == external ]]
assert_no_apt
assert_no_role_state

reset_provision_case invalid-state
rm "$SB_CONTROLLER_ROLE_TEST_MISSING_PATH"
mkdir -p "$(dirname "$CONTROLLER_STATE_FILE")" "$CONTROLLER_SECRET_DIR"
chmod 700 "$(dirname "$CONTROLLER_STATE_FILE")" "$CONTROLLER_SECRET_DIR"
printf '{"role":"standalone"}\n' > "$CONTROLLER_STATE_FILE"
chmod 600 "$CONTROLLER_STATE_FILE"
cp "$CONTROLLER_STATE_FILE" "$work/invalid-state.snapshot"
if provision_entry_controller_role; then fail 'invalid existing role was accepted'; fi
[[ "$CONTROLLER_ROLE_LAST_STATUS" == state_invalid &&
   "$CONTROLLER_ROLE_LAST_DETAIL" == existing_artifacts ]]
assert_no_apt
cmp -s "$CONTROLLER_STATE_FILE" "$work/invalid-state.snapshot"

reset_provision_case partial-artifacts
rm "$SB_CONTROLLER_ROLE_TEST_MISSING_PATH"
mkdir -p "$CONTROLLER_SECRET_DIR"
chmod 700 "$CONTROLLER_SECRET_DIR"
: > "$CONTROLLER_SECRET_DIR/unexpected"
chmod 600 "$CONTROLLER_SECRET_DIR/unexpected"
if provision_entry_controller_role; then fail 'partial role artifacts were accepted'; fi
[[ "$CONTROLLER_ROLE_LAST_STATUS" == state_invalid &&
   "$CONTROLLER_ROLE_LAST_DETAIL" == partial_artifacts ]]
assert_no_apt
assert_no_role_state

# 不可信依赖不能被自动覆盖。
reset_provision_case unsafe-dependency
chmod 777 "$SB_CONTROLLER_ROLE_DEPENDENCY_DIR/openssl"
if provision_entry_controller_role; then fail 'unsafe dependency was overwritten'; fi
[[ "$CONTROLLER_ROLE_LAST_STATUS" == unsafe_dependency &&
   "$CONTROLLER_ROLE_LAST_DETAIL" == openssl ]]
assert_no_apt
assert_no_role_state

# 依赖修复与最终初始化之间若出现新 v4 足迹，最终门禁必须重新拒绝。
reset_provision_case post-repair-conflict
rm "$SB_CONTROLLER_ROLE_TEST_MISSING_PATH"
(
  repair_entry_controller_dependencies() {
    cp "$true_bin" "$SB_CONTROLLER_ROLE_TEST_MISSING_PATH"
    chmod 755 "$SB_CONTROLLER_ROLE_TEST_MISSING_PATH"
    mkdir -p "$SB_SYSTEM_ROOT/etc"
    : > "$SB_SYSTEM_ROOT/etc/sb-user-manager.conf"
    controller_role_set_result dependencies_repaired
  }
  if provision_entry_controller_role; then fail 'post-repair role conflict was accepted'; fi
  [[ "$CONTROLLER_ROLE_LAST_STATUS" == role_conflict &&
     "$CONTROLLER_ROLE_LAST_DETAIL" == managed_partial ]]
  assert_no_role_state
)

# 参数和权限边界在任何外部动作前拒绝。
reset_provision_case invalid-input
invalid_input_rc=0
provision_entry_controller_role unexpected || invalid_input_rc=$?
[[ "$invalid_input_rc" == 64 ]] || fail 'unexpected argument returned the wrong status'
assert_no_apt
assert_no_role_state

reset_provision_case non-root
rm "$SB_CONTROLLER_ROLE_TEST_MISSING_PATH"
SB_CONTROLLER_ROLE_TEST_EUID=1000
if provision_entry_controller_role; then fail 'non-root provision was accepted'; fi
[[ "$CONTROLLER_ROLE_LAST_STATUS" == not_root ]]
assert_no_apt
assert_no_role_state

printf 'controller role provision tests passed\n'
