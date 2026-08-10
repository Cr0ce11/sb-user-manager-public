#!/usr/bin/env bash
# 测试桩由动态 source 的入口依赖修复函数间接调用。
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
chmod 700 "$env_stub"
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
if [[ "$stage" == install && "${SB_CONTROLLER_ROLE_TEST_RESTORE_DEPENDENCY:-true}" == true ]]; then
  cp "$SB_CONTROLLER_ROLE_TEST_TRUE_BIN" "$SB_CONTROLLER_ROLE_TEST_MISSING_PATH"
  chmod 755 "$SB_CONTROLLER_ROLE_TEST_MISSING_PATH"
fi
EOF
chmod 700 "$apt_stub"

export SB_USER_MANAGER_LIBRARY=true
export SB_CONTROLLER_STATE_FILE="$work/role/state/controller-state.json"
export SB_CONTROLLER_SECRET_DIR="$work/role/secrets"
export SB_CONTROLLER_STATE_LOCK_FILE="$work/role/lock/controller-state.lock"
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

# shellcheck source=../sb-user-manager.sh
source ./sb-user-manager.sh

fail() {
  printf 'controller role repair test failed: %s\n' "$1" >&2
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

reset_repair_case() {
  prepare_dependencies
  rm -f "$SB_CONTROLLER_ROLE_TEST_APT_LOG"
  unset SB_CONTROLLER_ROLE_TEST_APT_FAIL_STAGE
  SB_CONTROLLER_ROLE_TEST_RESTORE_DEPENDENCY=true
  export SB_CONTROLLER_ROLE_TEST_RESTORE_DEPENDENCY
  CONTROLLER_ROLE_APT_GET_BIN="$apt_stub"
  CONTROLLER_ROLE_ENV_BIN="$env_stub"
  chmod 700 "$apt_stub"
  chmod 700 "$env_stub"
  SB_CONTROLLER_ROLE_TEST_EUID=0
  SB_CONTROLLER_ROLE_TEST_UNAME_MACHINE=x86_64
}

assert_no_role_state() {
  [[ ! -e "$CONTROLLER_STATE_FILE" && ! -L "$CONTROLLER_STATE_FILE" &&
     ! -e "$CONTROLLER_SECRET_DIR" && ! -L "$CONTROLLER_SECRET_DIR" ]] ||
    fail 'dependency repair changed controller role state'
}

prepare_platform
prepare_dependencies

# 已就绪时完全不调用 APT。
chmod 777 "$apt_stub"
repair_entry_controller_dependencies || fail 'ready dependencies rejected'
[[ "$CONTROLLER_ROLE_LAST_STATUS" == dependencies_ready &&
   -z "$CONTROLLER_ROLE_LAST_DETAIL" ]]
[[ ! -e "$SB_CONTROLLER_ROLE_TEST_APT_LOG" ]]
assert_no_role_state
chmod 700 "$apt_stub"

# 只在缺失依赖时执行固定的 update + reinstall，并在复检后报告成功。
reset_repair_case
rm "$SB_CONTROLLER_ROLE_TEST_MISSING_PATH"
APT_CONFIG="$work/untrusted-apt.conf"
export APT_CONFIG
repair_entry_controller_dependencies || fail 'missing dependency was not repaired'
unset APT_CONFIG
[[ "$CONTROLLER_ROLE_LAST_STATUS" == dependencies_repaired &&
   -z "$CONTROLLER_ROLE_LAST_DETAIL" ]]
controller_role_dependency_is_safe ssh "$SB_CONTROLLER_ROLE_TEST_MISSING_PATH"
[[ "$(wc -l < "$SB_CONTROLLER_ROLE_TEST_APT_LOG" | tr -d ' ')" == 2 ]]
expected_update='-o DPkg::Lock::Timeout=60 -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 update'
expected_install='-o DPkg::Lock::Timeout=60 -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 install -y --reinstall --no-install-recommends coreutils gawk grep jq openssh-client openssl python3 util-linux'
[[ "$(sed -n '1p' "$SB_CONTROLLER_ROLE_TEST_APT_LOG")" == "$expected_update" ]]
[[ "$(sed -n '2p' "$SB_CONTROLLER_ROLE_TEST_APT_LOG")" == "$expected_install" ]]
assert_no_role_state

# update、install 与安装后复检失败分别保留稳定原因，且可以安全重试。
reset_repair_case
rm "$SB_CONTROLLER_ROLE_TEST_MISSING_PATH"
SB_CONTROLLER_ROLE_TEST_APT_FAIL_STAGE=update
export SB_CONTROLLER_ROLE_TEST_APT_FAIL_STAGE
if repair_entry_controller_dependencies; then fail 'apt update failure accepted'; fi
[[ "$CONTROLLER_ROLE_LAST_STATUS" == dependency_repair_failed &&
   "$CONTROLLER_ROLE_LAST_DETAIL" == apt_update ]]
[[ "$(wc -l < "$SB_CONTROLLER_ROLE_TEST_APT_LOG" | tr -d ' ')" == 1 ]]
assert_no_role_state

reset_repair_case
rm "$SB_CONTROLLER_ROLE_TEST_MISSING_PATH"
SB_CONTROLLER_ROLE_TEST_APT_FAIL_STAGE=install
export SB_CONTROLLER_ROLE_TEST_APT_FAIL_STAGE
if repair_entry_controller_dependencies; then fail 'apt install failure accepted'; fi
[[ "$CONTROLLER_ROLE_LAST_STATUS" == dependency_repair_failed &&
   "$CONTROLLER_ROLE_LAST_DETAIL" == apt_install ]]
[[ "$(wc -l < "$SB_CONTROLLER_ROLE_TEST_APT_LOG" | tr -d ' ')" == 2 ]]
assert_no_role_state

reset_repair_case
rm "$SB_CONTROLLER_ROLE_TEST_MISSING_PATH"
SB_CONTROLLER_ROLE_TEST_RESTORE_DEPENDENCY=false
export SB_CONTROLLER_ROLE_TEST_RESTORE_DEPENDENCY
if repair_entry_controller_dependencies; then fail 'failed postcheck accepted'; fi
[[ "$CONTROLLER_ROLE_LAST_STATUS" == dependency_repair_failed &&
   "$CONTROLLER_ROLE_LAST_DETAIL" == 'missing_dependency::ssh' ]]
assert_no_role_state

# 可疑依赖和不可信 APT 不能通过自动重装覆盖。
reset_repair_case
chmod 777 "$SB_CONTROLLER_ROLE_DEPENDENCY_DIR/openssl"
if repair_entry_controller_dependencies; then fail 'unsafe dependency was overwritten'; fi
[[ "$CONTROLLER_ROLE_LAST_STATUS" == unsafe_dependency &&
   "$CONTROLLER_ROLE_LAST_DETAIL" == openssl ]]
[[ ! -e "$SB_CONTROLLER_ROLE_TEST_APT_LOG" ]]
assert_no_role_state

reset_repair_case
rm "$SB_CONTROLLER_ROLE_TEST_MISSING_PATH"
chmod 777 "$apt_stub"
if repair_entry_controller_dependencies; then fail 'unsafe apt-get accepted'; fi
[[ "$CONTROLLER_ROLE_LAST_STATUS" == unsafe_runtime &&
   "$CONTROLLER_ROLE_LAST_DETAIL" == apt_get ]]
[[ ! -e "$SB_CONTROLLER_ROLE_TEST_APT_LOG" ]]
assert_no_role_state

# 非 root 与不支持平台在包管理前停止。
reset_repair_case
rm "$SB_CONTROLLER_ROLE_TEST_MISSING_PATH"
SB_CONTROLLER_ROLE_TEST_EUID=1000
if repair_entry_controller_dependencies; then fail 'non-root repair accepted'; fi
[[ "$CONTROLLER_ROLE_LAST_STATUS" == not_root ]]
[[ ! -e "$SB_CONTROLLER_ROLE_TEST_APT_LOG" ]]
assert_no_role_state

reset_repair_case
rm "$SB_CONTROLLER_ROLE_TEST_MISSING_PATH"
SB_CONTROLLER_ROLE_TEST_UNAME_MACHINE=aarch64
if repair_entry_controller_dependencies; then fail 'unsupported platform repair accepted'; fi
[[ "$CONTROLLER_ROLE_LAST_STATUS" == unsupported_platform ]]
[[ ! -e "$SB_CONTROLLER_ROLE_TEST_APT_LOG" ]]
assert_no_role_state

# Debian 12 root CI 只读验证真实固定 apt-get，不执行包管理操作。
if [[ "$EUID" -eq 0 && "$(uname -s)" == Linux && "$(uname -m)" == x86_64 &&
      -f /usr/lib/os-release ]]; then
  (
    SB_USER_MANAGER_LIBRARY=false
    unset SB_CONTROLLER_ROLE_TEST_EUID SB_CONTROLLER_ROLE_TEST_UNAME_SYSTEM
    unset SB_CONTROLLER_ROLE_TEST_UNAME_MACHINE
    CONTROLLER_STATE_FILE=/var/lib/sb-user-manager/controller-state.json
    CONTROLLER_SECRET_DIR=/etc/sb-user-manager/controller-secrets
    CONTROLLER_STATE_LOCK_FILE=/run/lock/sb-user-manager/controller-state.lock
    CONTROLLER_ROLE_OS_RELEASE_FILE=/usr/lib/os-release
    CONTROLLER_ROLE_APT_GET_BIN=/usr/bin/apt-get
    CONTROLLER_ROLE_ENV_BIN=/usr/bin/env
    controller_role_dependency_repair_preflight ||
      fail "production repair preflight rejected: $CONTROLLER_ROLE_LAST_STATUS/$CONTROLLER_ROLE_LAST_DETAIL"
    [[ "$CONTROLLER_ROLE_LAST_STATUS" == repair_ready ]]
  )
fi

printf 'controller role dependency repair tests passed\n'
