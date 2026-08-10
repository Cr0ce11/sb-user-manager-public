# ============================================================
# v5 入口发起的落地依赖准备（尚未接入菜单或角色安装）
# ============================================================
# 只产生稳定结果；不会创建入口状态、落地身份或项目运行文件。
# shellcheck disable=SC2034

CONTROLLER_LANDING_DEPENDENCY_SESSION_TIMEOUT=600
CONTROLLER_LANDING_DEPENDENCY_RESPONSE_MAX_BYTES=512
CONTROLLER_LANDING_DEPENDENCY_PACKAGE_MAX_BYTES=65536
CONTROLLER_LANDING_DEPENDENCY_LAST_STATUS=not_checked
CONTROLLER_LANDING_DEPENDENCY_LAST_DETAIL=""
CONTROLLER_LANDING_DEPENDENCY_LAST_FINGERPRINT=""

controller_landing_dependency_reset_result() {
  CONTROLLER_LANDING_DEPENDENCY_LAST_STATUS=not_checked
  CONTROLLER_LANDING_DEPENDENCY_LAST_DETAIL=""
  CONTROLLER_LANDING_DEPENDENCY_LAST_FINGERPRINT=""
}

controller_landing_dependency_set_result() {
  # shellcheck disable=SC2034
  CONTROLLER_LANDING_DEPENDENCY_LAST_STATUS="$1"
  # shellcheck disable=SC2034
  CONTROLLER_LANDING_DEPENDENCY_LAST_DETAIL="${2:-}"
}

controller_landing_dependency_settings_are_safe() {
  [[ "$CONTROLLER_LANDING_DEPENDENCY_SESSION_TIMEOUT" == 600 &&
     "$CONTROLLER_LANDING_DEPENDENCY_RESPONSE_MAX_BYTES" == 512 &&
     "$CONTROLLER_LANDING_DEPENDENCY_PACKAGE_MAX_BYTES" == 65536 ]]
}

controller_landing_build_dependency_package() {
  [[ $# -eq 1 ]] || return 64
  local output="$1" output_parent test_root="" test_system="" test_machine="" size
  controller_landing_dependency_settings_are_safe || return 1
  output_parent="$(dirname -- "$output")" || return 1
  controller_private_directory_is_trusted "$output_parent" || return 1
  [[ ! -e "$output" && ! -L "$output" ]] || return 1
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true &&
        -n "${SB_LANDING_DEPENDENCY_PREP_TEST_ROOT:-}" ]]; then
    test_root="$SB_LANDING_DEPENDENCY_PREP_TEST_ROOT"
    test_system="${SB_LANDING_DEPENDENCY_PREP_TEST_SYSTEM:-Linux}"
    test_machine="${SB_LANDING_DEPENDENCY_PREP_TEST_MACHINE:-x86_64}"
    [[ "$test_root" == /* && "$test_root" != / && "$test_root" != */ &&
       "$test_root" != *$'\n'* && "$test_system" =~ ^[A-Za-z0-9._-]+$ &&
       "$test_machine" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    controller_private_directory_is_trusted "$test_root" || return 1
  fi
  if ! {
    printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail' 'umask 077'
    printf 'test_root=%q\n' "$test_root"
    printf 'test_system=%q\n' "$test_system"
    printf 'test_machine=%q\n' "$test_machine"
    cat <<'EOF'

dependency_path() {
  local logical="$1"
  if [[ -n "$test_root" ]]; then
    printf '%s/dependencies/%s\n' "$test_root" "${logical##*/}"
  else
    printf '%s\n' "$logical"
  fi
}

os_release_path() {
  if [[ -n "$test_root" ]]; then
    printf '%s/os-release\n' "$test_root"
  else
    printf '/usr/lib/os-release\n'
  fi
}

apt_get_path() {
  if [[ -n "$test_root" ]]; then
    printf '%s/bin/apt-get\n' "$test_root"
  else
    printf '/usr/bin/apt-get\n'
  fi
}

env_path() {
  if [[ -n "$test_root" ]]; then
    printf '%s/bin/env\n' "$test_root"
  else
    printf '/usr/bin/env\n'
  fi
}

required_dependency_paths() {
  printf '%s\n' \
    /bin/bash /bin/sh /usr/bin/awk /usr/bin/base64 /usr/bin/cat \
    /usr/bin/chmod /usr/bin/chown /usr/bin/cmp /usr/bin/date /usr/bin/dirname \
    /usr/bin/flock /usr/bin/getent /usr/bin/grep /usr/bin/head /usr/bin/id \
    /usr/bin/install /usr/bin/jq /usr/bin/ln /usr/bin/mktemp /usr/bin/mv /usr/sbin/nft \
    /usr/bin/openssl /usr/bin/ps /usr/bin/python3 /usr/bin/readlink /usr/bin/rm \
    /usr/bin/rmdir /usr/bin/sha256sum /usr/bin/sort /usr/bin/ss /usr/bin/stat \
    /usr/bin/sudo /usr/bin/sync /usr/bin/systemctl /usr/bin/timeout /usr/bin/tr \
    /usr/bin/uname /usr/bin/wc /usr/bin/ssh-keygen /usr/sbin/groupadd \
    /usr/sbin/groupdel /usr/sbin/useradd /usr/sbin/userdel /usr/sbin/visudo
}

fixed_packages() {
  printf '%s\n' \
    bash coreutils gawk grep iproute2 jq nftables openssh-client openssl passwd \
    procps python3 sudo systemd util-linux
}

expected_uid() {
  if [[ -n "$test_root" ]]; then
    printf '%s\n' "$EUID"
  else
    printf '0\n'
  fi
}

executable_is_safe() {
  local logical="$1" path resolved metadata uid mode
  path="$(dependency_path "$logical")" || return 1
  [[ -f "$path" && -x "$path" ]] || return 1
  if [[ -n "$test_root" ]]; then
    [[ ! -L "$path" ]] || return 1
    resolved="$path"
  else
    resolved="$(/usr/bin/readlink -f -- "$path")" || return 1
  fi
  [[ "$resolved" == /* && -f "$resolved" && ! -L "$resolved" && -x "$resolved" ]] ||
    return 1
  metadata="$(/usr/bin/stat -Lc '%u %a' -- "$resolved" 2>/dev/null ||
    /usr/bin/stat -f '%u %Lp' "$resolved" 2>/dev/null)" || return 1
  read -r uid mode <<< "$metadata"
  [[ "$uid" == "$(expected_uid)" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0022) == 0 ))
}

dependency_state() {
  local logical="$1" path
  path="$(dependency_path "$logical")" || return 1
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    printf 'missing\n'
  elif executable_is_safe "$logical"; then
    printf 'ready\n'
  else
    printf 'unsafe\n'
  fi
}

platform_is_supported() {
  local os_release uid mode metadata key value os_id="" version_id=""
  local system machine
  if [[ -n "$test_root" ]]; then
    system="$test_system"
    machine="$test_machine"
  else
    [[ "$EUID" -eq 0 ]] || return 1
    system="$(/usr/bin/uname -s)" || return 1
    machine="$(/usr/bin/uname -m)" || return 1
  fi
  [[ "$system" == Linux && "$machine" == x86_64 ]] || return 1
  os_release="$(os_release_path)" || return 1
  [[ -f "$os_release" && ! -L "$os_release" && -r "$os_release" ]] || return 1
  metadata="$(/usr/bin/stat -Lc '%u %a' -- "$os_release" 2>/dev/null ||
    /usr/bin/stat -f '%u %Lp' "$os_release" 2>/dev/null)" || return 1
  read -r uid mode <<< "$metadata"
  [[ "$uid" == "$(expected_uid)" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0022) == 0 )) || return 1
  while IFS='=' read -r key value; do
    case "$key" in
      ID) [[ -z "$os_id" ]] || return 1; os_id="$value" ;;
      VERSION_ID) [[ -z "$version_id" ]] || return 1; version_id="$value" ;;
    esac
  done < "$os_release"
  [[ "$os_id" == debian && "$version_id" == '"12"' ]]
}

runtime_executable_is_safe() {
  local path="$1" expected="$2" resolved metadata uid mode
  [[ "$path" == "$expected" || -n "$test_root" ]] || return 1
  [[ -f "$path" && -x "$path" ]] || return 1
  if [[ -n "$test_root" ]]; then
    [[ ! -L "$path" ]] || return 1
    resolved="$path"
  else
    resolved="$(/usr/bin/readlink -f -- "$path")" || return 1
  fi
  [[ "$resolved" == /* && -f "$resolved" && ! -L "$resolved" && -x "$resolved" ]] ||
    return 1
  metadata="$(/usr/bin/stat -Lc '%u %a' -- "$resolved" 2>/dev/null ||
    /usr/bin/stat -f '%u %Lp' "$resolved" 2>/dev/null)" || return 1
  read -r uid mode <<< "$metadata"
  [[ "$uid" == "$(expected_uid)" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0022) == 0 ))
}

emit_error() {
  local code="$1" exit_code="$2"
  printf '{"status":"error","code":"%s"}\n' "$code"
  exit "$exit_code"
}

run_fixed_apt() {
  local apt_get env_bin stage="$1" package
  local -a packages=()
  apt_get="$(apt_get_path)" || return 1
  env_bin="$(env_path)" || return 1
  while IFS= read -r package; do packages+=("$package"); done < <(fixed_packages)
  ((${#packages[@]} == 15)) || return 1
  case "$stage" in
    update)
      "$env_bin" -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LANG=C.UTF-8 LC_ALL=C.UTF-8 \
        DEBIAN_FRONTEND=noninteractive "$apt_get" \
        -o DPkg::Lock::Timeout=60 -o Acquire::Retries=3 \
        -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 update \
        >/dev/null 2>&1
      ;;
    install)
      "$env_bin" -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LANG=C.UTF-8 LC_ALL=C.UTF-8 \
        DEBIAN_FRONTEND=noninteractive "$apt_get" \
        -o DPkg::Lock::Timeout=60 -o Acquire::Retries=3 \
        -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 \
        install -y --reinstall --no-install-recommends "${packages[@]}" \
        >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
}

main() {
  local logical state saw_missing=false
  platform_is_supported || emit_error unsupported_platform 20
  while IFS= read -r logical; do
    state="$(dependency_state "$logical")" || emit_error unsafe_dependency 21
    case "$state" in
      ready) ;;
      missing) saw_missing=true ;;
      *) emit_error unsafe_dependency 21 ;;
    esac
  done < <(required_dependency_paths)
  if [[ "$saw_missing" == false ]]; then
    printf '%s\n' '{"status":"ready"}'
    return 0
  fi
  runtime_executable_is_safe "$(apt_get_path)" /usr/bin/apt-get ||
    emit_error unsafe_runtime 22
  runtime_executable_is_safe "$(env_path)" /usr/bin/env || emit_error unsafe_runtime 22
  run_fixed_apt update || emit_error apt_update_failed 30
  run_fixed_apt install || emit_error apt_install_failed 31
  while IFS= read -r logical; do
    [[ "$(dependency_state "$logical")" == ready ]] || emit_error postcheck_failed 32
  done < <(required_dependency_paths)
  printf '%s\n' '{"status":"repaired"}'
}

main "$@"
EOF
  } > "$output"; then
    rm -f -- "$output" || true
    return 1
  fi
  chmod 600 "$output" || { rm -f -- "$output"; return 1; }
  controller_landing_private_file_is_trusted "$output" || {
    rm -f -- "$output"
    return 1
  }
  bash -n "$output" >/dev/null 2>&1 || { rm -f -- "$output"; return 1; }
  size="$(controller_landing_file_size "$output")" || { rm -f -- "$output"; return 1; }
  ((size >= 1 && size <= CONTROLLER_LANDING_DEPENDENCY_PACKAGE_MAX_BYTES)) || {
    rm -f -- "$output"
    return 1
  }
}

controller_landing_dependency_response_is_valid() {
  [[ $# -eq 2 ]] || return 64
  local response="$1" ssh_status="$2" size
  [[ "$ssh_status" =~ ^[0-9]+$ ]] || return 1
  controller_landing_private_file_is_trusted "$response" || return 1
  size="$(controller_landing_file_size "$response")" || return 1
  ((size >= 1 && size <= CONTROLLER_LANDING_DEPENDENCY_RESPONSE_MAX_BYTES)) || return 1
  jq -e -s --argjson ssh_status "$ssh_status" '
    length == 1 and
    if .[0] == {status:"ready"} or .[0] == {status:"repaired"} then
      $ssh_status == 0
    elif .[0] == {status:"error", code:"unsupported_platform"} then
      $ssh_status == 20
    elif .[0] == {status:"error", code:"unsafe_dependency"} then
      $ssh_status == 21
    elif .[0] == {status:"error", code:"unsafe_runtime"} then
      $ssh_status == 22
    elif .[0] == {status:"error", code:"apt_update_failed"} then
      $ssh_status == 30
    elif .[0] == {status:"error", code:"apt_install_failed"} then
      $ssh_status == 31
    elif .[0] == {status:"error", code:"postcheck_failed"} then
      $ssh_status == 32
    else false
    end
  ' "$response" >/dev/null 2>&1
}

controller_landing_prepare_dependencies_in_work() {
  [[ $# -eq 5 ]] || return 64
  local address="$1" ssh_port="$2" landing_id="$3" expected_fingerprint="$4" work="$5"
  local package="$work/dependency-package.sh" response="$work/dependency-response.json"
  local known_hosts ssh_status result
  controller_landing_dependency_settings_are_safe || return 1
  controller_landing_address_is_valid "$address" || return 1
  landing_port_is_valid "$ssh_port" || return 1
  landing_id_is_valid "$landing_id" || return 1
  [[ "$expected_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || return 1
  controller_private_directory_is_trusted "$work" || return 1
  known_hosts="$(controller_landing_prepare_known_hosts "$address" "$ssh_port" \
    "$expected_fingerprint" "sb-landing-$landing_id" "$work")" || {
      controller_landing_dependency_set_result fingerprint_recheck_failed
      return 1
    }
  controller_landing_build_dependency_package "$package" || {
    controller_landing_dependency_set_result package_build_failed
    return 1
  }
  if controller_landing_root_package_exchange "$address" "$ssh_port" "$landing_id" \
      "$known_hosts" "$expected_fingerprint" "$package" "$response" \
      "$CONTROLLER_LANDING_DEPENDENCY_SESSION_TIMEOUT"; then
    ssh_status=0
  else
    ssh_status="$CONTROLLER_LANDING_ROOT_PACKAGE_LAST_SSH_STATUS"
  fi
  if ! controller_landing_dependency_response_is_valid "$response" "$ssh_status"; then
    controller_landing_dependency_set_result ssh_uncertain
    return 1
  fi
  result="$(jq -r 'if .status == "error" then .code else .status end' "$response")" || {
    controller_landing_dependency_set_result ssh_uncertain
    return 1
  }
  case "$result" in
    ready|repaired)
      controller_landing_dependency_set_result "$result"
      return 0
      ;;
    unsupported_platform|unsafe_dependency|unsafe_runtime|apt_update_failed|apt_install_failed|postcheck_failed)
      controller_landing_dependency_set_result "$result"
      return 1
      ;;
    *)
      controller_landing_dependency_set_result ssh_uncertain
      return 1
      ;;
  esac
}

controller_prepare_landing_dependencies() {
  [[ $# -eq 3 ]] || return 64
  local address="$1" ssh_port="$2" landing_id="$3" fingerprint work rc=1 confirm_rc=0
  controller_landing_dependency_reset_result
  controller_landing_dependency_settings_are_safe || {
    controller_landing_dependency_set_result unsafe_local_runtime
    return 1
  }
  controller_landing_transport_runtime_is_safe || {
    controller_landing_dependency_set_result unsafe_local_runtime
    return 1
  }
  controller_landing_address_is_valid "$address" || {
    controller_landing_dependency_set_result invalid_input
    return 1
  }
  landing_port_is_valid "$ssh_port" || {
    controller_landing_dependency_set_result invalid_input
    return 1
  }
  landing_id_is_valid "$landing_id" || {
    controller_landing_dependency_set_result invalid_input
    return 1
  }
  validate_controller_state_file "$CONTROLLER_STATE_FILE" || {
    controller_landing_dependency_set_result invalid_controller_state
    return 1
  }
  fingerprint="$(controller_landing_discover_fingerprint "$address" "$ssh_port")" || {
    controller_landing_dependency_set_result fingerprint_discovery_failed
    return 1
  }
  # 结果由后续交互层与当前定向测试在函数返回后读取。
  # shellcheck disable=SC2034
  CONTROLLER_LANDING_DEPENDENCY_LAST_FINGERPRINT="$fingerprint"
  controller_confirm_landing_fingerprint "$address" "$ssh_port" "$fingerprint" || confirm_rc=$?
  if ((confirm_rc != 0)); then
    if ((confirm_rc == 2)); then
      controller_landing_dependency_set_result fingerprint_rejected
    else
      controller_landing_dependency_set_result fingerprint_confirmation_failed
    fi
    return 1
  fi
  work="$(controller_landing_create_work_directory)" || {
    controller_landing_dependency_set_result unsafe_local_runtime
    return 1
  }
  register_temp_path "$work" || {
    controller_landing_remove_work_directory "$work" || true
    controller_landing_dependency_set_result unsafe_local_runtime
    return 1
  }
  if controller_landing_prepare_dependencies_in_work "$address" "$ssh_port" "$landing_id" \
      "$fingerprint" "$work"; then
    rc=0
  fi
  controller_landing_remove_work_directory "$work" || {
    controller_landing_dependency_set_result local_cleanup_failed
    rc=1
  }
  return "$rc"
}
