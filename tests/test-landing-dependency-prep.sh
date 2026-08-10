#!/usr/bin/env bash
# 生成包中的生产固定路径与测试隔离路径由同一函数分支选择。
# shellcheck disable=SC2016,SC2034,SC2317,SC2329
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME="${SB_LANDING_DEPENDENCY_PREP_RUNTIME:-$ROOT/sb-user-manager.sh}"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

fail() {
  printf 'landing dependency preparation test failed: %s\n' "$1" >&2
  exit 1
}

export SB_USER_MANAGER_LIBRARY=true
export SB_CONTROLLER_STATE_FILE="$work/controller-state/state.json"
export SB_CONTROLLER_SECRET_DIR="$work/controller-secrets"
export SB_CONTROLLER_STATE_LOCK_FILE="$work/controller-lock/state.lock"
export SB_CONTROLLER_LANDING_WORK_ROOT="$work/controller-work"
export SB_LANDING_DEPENDENCY_PREP_TEST_ROOT="$work/remote"
export SB_LANDING_DEPENDENCY_PREP_TEST_SYSTEM=Linux
export SB_LANDING_DEPENDENCY_PREP_TEST_MACHINE=x86_64
# shellcheck source=../sb-user-manager.sh
source "$RUNTIME"

for function_name in controller_landing_build_dependency_package \
  controller_landing_dependency_response_is_valid \
  controller_landing_prepare_dependencies_in_work \
  controller_prepare_landing_dependencies controller_landing_root_package_exchange; do
  declare -F "$function_name" >/dev/null 2>&1 || fail "missing function: $function_name"
done

mkdir -m 700 "$SB_CONTROLLER_SECRET_DIR" "$SB_CONTROLLER_LANDING_WORK_ROOT" \
  "$SB_LANDING_DEPENDENCY_PREP_TEST_ROOT"
mkdir -m 700 "$SB_LANDING_DEPENDENCY_PREP_TEST_ROOT/bin" \
  "$SB_LANDING_DEPENDENCY_PREP_TEST_ROOT/dependencies"

remote_root="$SB_LANDING_DEPENDENCY_PREP_TEST_ROOT"
apt_log="$remote_root/apt.log"
apt_control="$remote_root/apt-control"
true_bin=/usr/bin/true
[[ -x "$true_bin" ]] || true_bin=/bin/true

cat > "$remote_root/bin/env" <<'EOF'
#!/bin/sh
exec /usr/bin/env "$@"
EOF
chmod 700 "$remote_root/bin/env"
cat > "$remote_root/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
set -eu
base="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
printf '%s\n' "$*" >> "$base/apt.log"
stage=unknown
for argument in "$@"; do
  case "$argument" in update|install) stage="$argument";; esac
done
if [[ -f "$base/apt-control" && "$(<"$base/apt-control")" == "fail-$stage" ]]; then
  exit 42
fi
if [[ "$stage" == install && ! -f "$base/apt-control" ]]; then
  cp /usr/bin/true "$base/dependencies/jq" 2>/dev/null ||
    cp /bin/true "$base/dependencies/jq"
  chmod 755 "$base/dependencies/jq"
fi
EOF
chmod 700 "$remote_root/bin/apt-get"

required_names=(
  bash sh awk base64 cat chmod chown cmp date dirname flock getent grep head id install
  jq ln mktemp mv nft openssl ps python3 readlink rm rmdir sha256sum sort ss stat sudo
  sync systemctl timeout tr uname wc ssh-keygen groupadd groupdel useradd userdel visudo
)

prepare_remote_dependencies() {
  local name
  for name in "${required_names[@]}"; do
    cp "$true_bin" "$remote_root/dependencies/$name"
    chmod 755 "$remote_root/dependencies/$name"
  done
}

reset_remote_case() {
  prepare_remote_dependencies
  printf 'ID=debian\nVERSION_ID="12"\n' > "$remote_root/os-release"
  chmod 644 "$remote_root/os-release"
  chmod 700 "$remote_root/bin/apt-get" "$remote_root/bin/env"
  rm -f -- "$apt_log" "$apt_control"
}

run_package() {
  PACKAGE_OUTPUT=""
  PACKAGE_RC=0
  if PACKAGE_OUTPUT="$(/bin/bash "$package")"; then
    PACKAGE_RC=0
  else
    PACKAGE_RC=$?
  fi
}

reset_remote_case
package="$work/dependency-package.sh"
controller_landing_build_dependency_package "$package" || fail 'package build failed'
controller_landing_private_file_is_trusted "$package" || fail 'package is not private'
grep -Fq 'DPkg::Lock::Timeout=60' "$package" || fail 'apt lock timeout is missing'
grep -Fq 'Acquire::Retries=3' "$package" || fail 'apt retries are missing'
grep -Fq 'install -y --reinstall --no-install-recommends "${packages[@]}"' "$package" ||
  fail 'fixed reinstall command is missing'
grep -Fq 'bash coreutils gawk grep iproute2 jq nftables openssh-client openssl passwd' \
  "$package" || fail 'fixed package manifest is missing'
if grep -Eq '/etc/sb-user-manager|/var/lib/sb-user-manager|landing-channel.json' "$package"; then
  fail 'dependency package writes or references project state paths'
fi
if controller_landing_build_dependency_package "$package"; then
  fail 'package builder overwrote an existing output'
fi

# 已就绪不碰 APT，即使 APT 本身不可信也只返回 ready。
chmod 777 "$remote_root/bin/apt-get"
run_package
[[ "$PACKAGE_RC" == 0 && "$PACKAGE_OUTPUT" == '{"status":"ready"}' ]] ||
  fail 'ready dependency set was rejected'
[[ ! -e "$apt_log" ]] || fail 'ready dependency set invoked apt'

# 缺失依赖只触发固定 update + install，复检后返回 repaired。
reset_remote_case
rm -f -- "$remote_root/dependencies/jq"
run_package
[[ "$PACKAGE_RC" == 0 && "$PACKAGE_OUTPUT" == '{"status":"repaired"}' ]] ||
  fail 'missing dependency was not repaired'
[[ "$(wc -l < "$apt_log" | tr -d ' ')" == 2 ]] || fail 'unexpected apt invocation count'
expected_update='-o DPkg::Lock::Timeout=60 -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 update'
expected_install='-o DPkg::Lock::Timeout=60 -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 install -y --reinstall --no-install-recommends bash coreutils gawk grep iproute2 jq nftables openssh-client openssl passwd procps python3 sudo systemd util-linux'
[[ "$(sed -n '1p' "$apt_log")" == "$expected_update" ]] || fail 'apt update arguments drifted'
[[ "$(sed -n '2p' "$apt_log")" == "$expected_install" ]] || fail 'apt install arguments drifted'

# update、install 与安装后复检失败必须可区分且不能被吞掉。
reset_remote_case
rm -f -- "$remote_root/dependencies/jq"
printf 'fail-update\n' > "$apt_control"
run_package
[[ "$PACKAGE_RC" == 30 && "$PACKAGE_OUTPUT" == '{"status":"error","code":"apt_update_failed"}' ]] ||
  fail 'apt update failure was not stable'
[[ "$(wc -l < "$apt_log" | tr -d ' ')" == 1 ]] || fail 'install ran after update failure'

reset_remote_case
rm -f -- "$remote_root/dependencies/jq"
printf 'fail-install\n' > "$apt_control"
run_package
[[ "$PACKAGE_RC" == 31 && "$PACKAGE_OUTPUT" == '{"status":"error","code":"apt_install_failed"}' ]] ||
  fail 'apt install failure was not stable'

reset_remote_case
rm -f -- "$remote_root/dependencies/jq"
printf 'no-restore\n' > "$apt_control"
run_package
[[ "$PACKAGE_RC" == 32 && "$PACKAGE_OUTPUT" == '{"status":"error","code":"postcheck_failed"}' ]] ||
  fail 'postcheck failure was not stable'

# 可疑现有依赖、可疑 APT 和不支持平台都在包管理前停止。
reset_remote_case
chmod 777 "$remote_root/dependencies/openssl"
run_package
[[ "$PACKAGE_RC" == 21 && "$PACKAGE_OUTPUT" == '{"status":"error","code":"unsafe_dependency"}' ]] ||
  fail 'unsafe dependency was accepted'
[[ ! -e "$apt_log" ]] || fail 'unsafe dependency invoked apt'

reset_remote_case
rm -f -- "$remote_root/dependencies/jq"
chmod 777 "$remote_root/bin/apt-get"
run_package
[[ "$PACKAGE_RC" == 22 && "$PACKAGE_OUTPUT" == '{"status":"error","code":"unsafe_runtime"}' ]] ||
  fail 'unsafe apt runtime was accepted'
[[ ! -e "$apt_log" ]] || fail 'unsafe apt runtime was executed'

reset_remote_case
rm -f -- "$remote_root/dependencies/jq"
printf 'ID=ubuntu\nVERSION_ID="24.04"\n' > "$remote_root/os-release"
run_package
[[ "$PACKAGE_RC" == 20 && "$PACKAGE_OUTPUT" == '{"status":"error","code":"unsupported_platform"}' ]] ||
  fail 'unsupported platform was accepted'
[[ ! -e "$apt_log" ]] || fail 'unsupported platform invoked apt'

# 响应必须同时绑定严格 JSON 与远端退出码，并拒绝额外字段和截断/超长数据。
response="$work/response.json"
printf '%s\n' '{"status":"ready"}' > "$response"
chmod 600 "$response"
controller_landing_dependency_response_is_valid "$response" 0 || fail 'ready response rejected'
if controller_landing_dependency_response_is_valid "$response" 30; then
  fail 'success response accepted a failure exit code'
fi
printf '%s\n' '{"status":"error","code":"apt_update_failed"}' > "$response"
controller_landing_dependency_response_is_valid "$response" 30 || fail 'error response rejected'
printf '%s\n' '{"status":"ready","extra":true}' > "$response"
if controller_landing_dependency_response_is_valid "$response" 0; then
  fail 'response accepted an extra field'
fi
head -c 513 /dev/zero | tr '\0' x > "$response"
if controller_landing_dependency_response_is_valid "$response" 0; then
  fail 'oversized response was accepted'
fi

# 通用 root 交换保留旧引导入口，并固定 SSH 的主机、身份与转发边界。
declare -F controller_landing_bootstrap_remote_command >/dev/null ||
  fail 'legacy bootstrap receiver wrapper is missing'
controller_landing_root_package_settings_are_safe || fail 'root package settings were rejected'
(
  CONTROLLER_LANDING_BOOTSTRAP_ROOT_ACCOUNT='admin'
  if controller_landing_root_package_settings_are_safe; then
    fail 'mutable non-root package account was accepted'
  fi
)
root_exchange="$(declare -f controller_landing_root_package_exchange)"
for required_option in '-F /dev/null -T' '-o BatchMode=no' '-o ClearAllForwardings=yes' \
  '-o ForwardAgent=no' '-o GlobalKnownHostsFile=/dev/null' \
  '-o HostKeyAlgorithms=ssh-ed25519' '-o IdentitiesOnly=yes' \
  '-o ProxyCommand=none' '-o ProxyJump=none' '-o StrictHostKeyChecking=yes' \
  '-o UpdateHostKeys=no' '-o "User=$CONTROLLER_LANDING_BOOTSTRAP_ROOT_ACCOUNT"'; do
  grep -Fq -- "$required_option" <<< "$root_exchange" ||
    fail "root exchange option is missing: $required_option"
done
remote_command="$(controller_landing_root_package_remote_command "$(printf 'a%.0s' {1..64})")"
grep -Fq '/usr/bin/sha256sum "$work/package"' <<< "$remote_command" ||
  fail 'remote package hash check is missing'
if controller_landing_root_package_remote_command bad-digest >/dev/null; then
  fail 'remote receiver accepted a malformed digest'
fi

# 顶层编排顺序必须是发现 -> 人工确认 -> 再扫描/远端动作；拒绝后不得连接。
fixture_fingerprint="SHA256:$(printf 'A%.0s' {1..43})"
(
  actions="$work/actions-success"
  : > "$actions"
  orchestration_work="$SB_CONTROLLER_LANDING_WORK_ROOT/orchestration"
  controller_landing_transport_runtime_is_safe() { return 0; }
  validate_controller_state_file() { return 0; }
  controller_landing_discover_fingerprint() { printf '%s\n' "$fixture_fingerprint"; }
  controller_confirm_landing_fingerprint() { printf 'confirmed\n' >> "$actions"; }
  controller_landing_create_work_directory() { mkdir -m 700 "$orchestration_work"; printf '%s\n' "$orchestration_work"; }
  register_temp_path() { return 0; }
  controller_landing_prepare_dependencies_in_work() {
    [[ "$(tail -n 1 "$actions")" == confirmed ]] || return 1
    printf 'remote\n' >> "$actions"
    controller_landing_dependency_set_result ready
  }
  controller_landing_remove_work_directory() { rmdir "$1"; }
  controller_prepare_landing_dependencies 1.1.1.1 22 landing-a ||
    fail 'successful orchestration failed'
  [[ "$(tr '\n' ' ' < "$actions")" == 'confirmed remote ' ]] ||
    fail 'orchestration order drifted'
  [[ "$CONTROLLER_LANDING_DEPENDENCY_LAST_STATUS" == ready &&
     "$CONTROLLER_LANDING_DEPENDENCY_LAST_FINGERPRINT" == "$fixture_fingerprint" ]] ||
    fail 'successful orchestration result drifted'
)
(
  controller_landing_transport_runtime_is_safe() { return 0; }
  validate_controller_state_file() { return 0; }
  controller_landing_discover_fingerprint() { printf '%s\n' "$fixture_fingerprint"; }
  controller_confirm_landing_fingerprint() { return 2; }
  controller_landing_create_work_directory() { fail 'rejected fingerprint reached root setup'; }
  if controller_prepare_landing_dependencies 1.1.1.1 22 landing-a; then
    fail 'rejected fingerprint was accepted'
  fi
  [[ "$CONTROLLER_LANDING_DEPENDENCY_LAST_STATUS" == fingerprint_rejected ]] ||
    fail 'rejected fingerprint result drifted'
)
(
  controller_landing_transport_runtime_is_safe() { return 0; }
  validate_controller_state_file() { return 1; }
  controller_landing_discover_fingerprint() { fail 'invalid controller state reached fingerprint scan'; }
  if controller_prepare_landing_dependencies 1.1.1.1 22 landing-a; then
    fail 'invalid controller state was accepted'
  fi
  [[ "$CONTROLLER_LANDING_DEPENDENCY_LAST_STATUS" == invalid_controller_state ]] ||
    fail 'invalid controller state result drifted'
)
(
  recheck_work="$SB_CONTROLLER_LANDING_WORK_ROOT/recheck"
  mkdir -m 700 "$recheck_work"
  controller_landing_prepare_known_hosts() { return 1; }
  if controller_landing_prepare_dependencies_in_work 1.1.1.1 22 landing-a \
      "$fixture_fingerprint" "$recheck_work"; then
    fail 'fingerprint recheck failure was accepted'
  fi
  [[ "$CONTROLLER_LANDING_DEPENDENCY_LAST_STATUS" == fingerprint_recheck_failed ]] ||
    fail 'fingerprint recheck result drifted'
)

# 固定 Debian 12 CI 容器可额外执行真实路径的只读 ready 分支；不会运行 APT。
if [[ "${SB_REQUIRE_LANDING_DEPENDENCY_PREP_PRODUCTION:-false}" == true ]]; then
  [[ "$EUID" -eq 0 && "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] ||
    fail 'production dependency verification requires Debian 12 x86_64 root'
  unset SB_LANDING_DEPENDENCY_PREP_TEST_ROOT SB_LANDING_DEPENDENCY_PREP_TEST_SYSTEM
  unset SB_LANDING_DEPENDENCY_PREP_TEST_MACHINE
  production_package="$work/production-dependency-package.sh"
  controller_landing_build_dependency_package "$production_package" ||
    fail 'production dependency package build failed'
  if production_output="$(/bin/bash "$production_package")"; then
    production_rc=0
  else
    production_rc=$?
  fi
  [[ "$production_rc" == 0 && "$production_output" == '{"status":"ready"}' ]] ||
    fail "production dependency verification failed: $production_rc/$production_output"
  production_sha="$(sha256sum "$production_package" | awk '{print $1}')"
  production_receiver="$(controller_landing_root_package_remote_command "$production_sha")" ||
    fail 'production receiver build failed'
  if receiver_output="$(/bin/bash -c "$production_receiver" < "$production_package")"; then
    receiver_rc=0
  else
    receiver_rc=$?
  fi
  [[ "$receiver_rc" == 0 && "$receiver_output" == '{"status":"ready"}' ]] ||
    fail "verified production receiver failed: $receiver_rc/$receiver_output"
  production_size="$(controller_landing_file_size "$production_package")"
  ((production_size > 1)) || fail 'production package is unexpectedly empty'
  truncated_package="$work/truncated-production-package.sh"
  head -c "$((production_size - 1))" "$production_package" > "$truncated_package"
  if /bin/bash -c "$production_receiver" < "$truncated_package" > "$work/truncated-output"; then
    fail 'remote receiver executed a truncated package'
  fi
  [[ ! -s "$work/truncated-output" ]] || fail 'truncated package produced a response'
fi

printf 'landing dependency preparation tests passed\n'
