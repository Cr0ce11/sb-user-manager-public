# ============================================================
# v5 入口控制器角色门禁（尚未接入菜单或运行流程）
# ============================================================
# 后续交互层只读取这些稳定结果；详情只包含固定状态或依赖名称。
# shellcheck disable=SC2034

CONTROLLER_ROLE_LAST_STATUS=not_checked
CONTROLLER_ROLE_LAST_DETAIL=""
CONTROLLER_ROLE_APT_LOCK_TIMEOUT=60
CONTROLLER_ROLE_APT_ACQUIRE_TIMEOUT=30
CONTROLLER_ROLE_APT_RETRIES=3
if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]]; then
  CONTROLLER_ROLE_OS_RELEASE_FILE="${SB_CONTROLLER_ROLE_OS_RELEASE_FILE:-/usr/lib/os-release}"
  CONTROLLER_ROLE_APT_GET_BIN="${SB_CONTROLLER_ROLE_APT_GET_BIN:-/usr/bin/apt-get}"
  CONTROLLER_ROLE_ENV_BIN="${SB_CONTROLLER_ROLE_ENV_BIN:-/usr/bin/env}"
else
  CONTROLLER_ROLE_OS_RELEASE_FILE=/usr/lib/os-release
  CONTROLLER_ROLE_APT_GET_BIN=/usr/bin/apt-get
  CONTROLLER_ROLE_ENV_BIN=/usr/bin/env
fi

controller_role_reset_result() {
  CONTROLLER_ROLE_LAST_STATUS=not_checked
  CONTROLLER_ROLE_LAST_DETAIL=""
}

controller_role_set_result() {
  # 结果由后续交互层与当前定向测试在函数返回后读取。
  # shellcheck disable=SC2034
  CONTROLLER_ROLE_LAST_STATUS="$1"
  # shellcheck disable=SC2034
  CONTROLLER_ROLE_LAST_DETAIL="${2:-}"
}

controller_role_effective_uid() {
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]]; then
    printf '%s\n' "${SB_CONTROLLER_ROLE_TEST_EUID:-0}"
  else
    printf '%s\n' "$EUID"
  fi
}

controller_role_platform_is_supported() {
  local os_release="$CONTROLLER_ROLE_OS_RELEASE_FILE" owner mode expected_owner key value
  local system machine os_id="" version_id=""
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]]; then
    if [[ -n "${SB_CONTROLLER_ROLE_TEST_UNAME_SYSTEM:-}" ]]; then
      system="$SB_CONTROLLER_ROLE_TEST_UNAME_SYSTEM"
    else
      system="$(uname -s)" || return 1
    fi
    if [[ -n "${SB_CONTROLLER_ROLE_TEST_UNAME_MACHINE:-}" ]]; then
      machine="$SB_CONTROLLER_ROLE_TEST_UNAME_MACHINE"
    else
      machine="$(uname -m)" || return 1
    fi
  else
    system="$(/usr/bin/uname -s)" || return 1
    machine="$(/usr/bin/uname -m)" || return 1
  fi
  [[ "$system" == Linux && "$machine" == x86_64 ]] || return 1
  [[ "$os_release" == /* && -f "$os_release" && ! -L "$os_release" && -r "$os_release" ]] ||
    return 1
  owner="$(manager_file_uid "$os_release")" || return 1
  mode="$(manager_file_mode "$os_release")" || return 1
  expected_owner="$(controller_state_expected_uid)" || return 1
  [[ "$owner" == "$expected_owner" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0022) == 0 )) || return 1
  while IFS='=' read -r key value; do
    case "$key" in
      ID)
        [[ -z "$os_id" ]] || return 1
        os_id="$value"
        ;;
      VERSION_ID)
        [[ -z "$version_id" ]] || return 1
        version_id="$value"
        ;;
    esac
  done < "$os_release"
  [[ "$os_id" == debian && "$version_id" == '"12"' ]]
}

controller_role_runtime_paths_are_safe() {
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    [[ "$CONTROLLER_STATE_FILE" == /var/lib/sb-user-manager/controller-state.json &&
       "$CONTROLLER_SECRET_DIR" == /etc/sb-user-manager/controller-secrets &&
       "$CONTROLLER_STATE_LOCK_FILE" == /run/lock/sb-user-manager/controller-state.lock &&
       "$CONTROLLER_ROLE_OS_RELEASE_FILE" == /usr/lib/os-release ]]
  else
    [[ "$CONTROLLER_STATE_FILE" == /* && "$CONTROLLER_SECRET_DIR" == /* &&
       "$CONTROLLER_STATE_LOCK_FILE" == /* && "$CONTROLLER_ROLE_OS_RELEASE_FILE" == /* ]]
  fi
}

controller_role_required_dependencies() {
  printf '%s\n' \
    readlink stat uname awk base64 cat chmod chown date dirname flock grep install jq \
    mktemp mv openssl python3 rm rmdir sha256sum sort ssh ssh-keygen ssh-keyscan \
    sync timeout tr wc
}

controller_role_dependency_expected_path() {
  local name="$1" dependency_root="${SB_CONTROLLER_ROLE_DEPENDENCY_DIR:-}"
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true && -n "$dependency_root" ]]; then
    [[ "$dependency_root" == /* && "$dependency_root" != / && "$dependency_root" != */ ]] ||
      return 1
    printf '%s/%s\n' "$dependency_root" "$name"
  else
    printf '/usr/bin/%s\n' "$name"
  fi
}

controller_role_dependency_path() {
  local name="$1"
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true &&
        -n "${SB_CONTROLLER_ROLE_DEPENDENCY_DIR:-}" ]]; then
    controller_role_dependency_expected_path "$name"
  else
    command -v "$name"
  fi
}

controller_role_dependency_is_safe() {
  local name="$1" path="$2" expected resolved owner mode expected_owner
  expected="$(controller_role_dependency_expected_path "$name")" || return 1
  [[ "$path" == "$expected" && -f "$path" && -x "$path" ]] || return 1
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true &&
        -n "${SB_CONTROLLER_ROLE_DEPENDENCY_DIR:-}" ]]; then
    [[ ! -L "$path" ]] || return 1
    resolved="$path"
  else
    resolved="$(/usr/bin/readlink -f -- "$path")" || return 1
    [[ "$resolved" == /* && -f "$resolved" && ! -L "$resolved" && -x "$resolved" ]] ||
      return 1
  fi
  owner="$(manager_file_uid "$resolved")" || return 1
  mode="$(manager_file_mode "$resolved")" || return 1
  expected_owner="$(controller_state_expected_uid)" || return 1
  [[ "$owner" == "$expected_owner" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0022) == 0 ))
}

controller_role_dependencies_are_ready() {
  local name path
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true &&
        -n "${SB_CONTROLLER_ROLE_DEPENDENCY_DIR:-}" ]] &&
     [[ "$SB_CONTROLLER_ROLE_DEPENDENCY_DIR" != /* ||
        "$SB_CONTROLLER_ROLE_DEPENDENCY_DIR" == / ||
        "$SB_CONTROLLER_ROLE_DEPENDENCY_DIR" == */ ]]; then
    controller_role_set_result unsafe_runtime dependency_root
    return 1
  fi
  while IFS= read -r name; do
    path="$(controller_role_dependency_path "$name")" || {
      controller_role_set_result missing_dependency "$name"
      return 1
    }
    if [[ ! -e "$path" && ! -L "$path" ]]; then
      controller_role_set_result missing_dependency "$name"
      return 1
    fi
    if ! controller_role_dependency_is_safe "$name" "$path"; then
      controller_role_set_result unsafe_dependency "$name"
      return 1
    fi
  done < <(controller_role_required_dependencies)
}

controller_role_dependency_packages() {
  printf '%s\n' coreutils gawk grep jq openssh-client openssl python3 util-linux
}

controller_role_repair_executable_is_safe() {
  local path="$1" expected="$2" resolved owner mode expected_owner
  [[ "$path" == /* && -f "$path" && -x "$path" ]] || return 1
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]]; then
    [[ ! -L "$path" ]] || return 1
    resolved="$path"
  else
    [[ "$path" == "$expected" ]] || return 1
    resolved="$(/usr/bin/readlink -f -- "$path")" || return 1
    [[ "$resolved" == /* && -f "$resolved" && ! -L "$resolved" && -x "$resolved" ]] ||
      return 1
  fi
  owner="$(manager_file_uid "$resolved")" || return 1
  mode="$(manager_file_mode "$resolved")" || return 1
  expected_owner="$(controller_state_expected_uid)" || return 1
  [[ "$owner" == "$expected_owner" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0022) == 0 ))
}

controller_role_dependency_repair_base_preflight() {
  controller_role_reset_result
  if [[ "$(controller_role_effective_uid)" != 0 ]]; then
    controller_role_set_result not_root
    return 1
  fi
  if ! controller_role_runtime_paths_are_safe; then
    controller_role_set_result unsafe_runtime fixed_paths
    return 1
  fi
  if ! controller_role_platform_is_supported; then
    controller_role_set_result unsupported_platform
    return 1
  fi
  controller_role_set_result repair_base_ready
}

controller_role_apt_get_is_safe() {
  controller_role_repair_executable_is_safe \
    "$CONTROLLER_ROLE_APT_GET_BIN" /usr/bin/apt-get || return 1
  controller_role_repair_executable_is_safe "$CONTROLLER_ROLE_ENV_BIN" /usr/bin/env
}

controller_role_dependency_repair_preflight() {
  controller_role_dependency_repair_base_preflight || return 1
  if [[ "$CONTROLLER_ROLE_APT_LOCK_TIMEOUT" != 60 ||
        "$CONTROLLER_ROLE_APT_ACQUIRE_TIMEOUT" != 30 ||
        "$CONTROLLER_ROLE_APT_RETRIES" != 3 ]] ||
     ! controller_role_apt_get_is_safe; then
    controller_role_set_result unsafe_runtime apt_get
    return 1
  fi
  controller_role_set_result repair_ready
}

controller_role_run_apt_get() {
  local -a clean_environment=(
    -i
    'PATH=/usr/sbin:/usr/bin:/sbin:/bin'
    'LANG=C.UTF-8'
    'LC_ALL=C.UTF-8'
    'DEBIAN_FRONTEND=noninteractive'
  )
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]]; then
    clean_environment+=(
      "SB_CONTROLLER_ROLE_TEST_APT_LOG=${SB_CONTROLLER_ROLE_TEST_APT_LOG:-}"
      "SB_CONTROLLER_ROLE_TEST_APT_FAIL_STAGE=${SB_CONTROLLER_ROLE_TEST_APT_FAIL_STAGE:-}"
      "SB_CONTROLLER_ROLE_TEST_RESTORE_DEPENDENCY=${SB_CONTROLLER_ROLE_TEST_RESTORE_DEPENDENCY:-true}"
      "SB_CONTROLLER_ROLE_TEST_TRUE_BIN=${SB_CONTROLLER_ROLE_TEST_TRUE_BIN:-}"
      "SB_CONTROLLER_ROLE_TEST_MISSING_PATH=${SB_CONTROLLER_ROLE_TEST_MISSING_PATH:-}"
    )
  fi
  "$CONTROLLER_ROLE_ENV_BIN" "${clean_environment[@]}" \
    "$CONTROLLER_ROLE_APT_GET_BIN" "$@"
}

repair_entry_controller_dependencies() {
  [[ $# -eq 0 ]] || return 64
  local package post_status post_detail
  local -a packages=()
  controller_role_dependency_repair_base_preflight || return 1
  if controller_role_dependencies_are_ready; then
    controller_role_set_result dependencies_ready
    return 0
  fi
  [[ "$CONTROLLER_ROLE_LAST_STATUS" == missing_dependency ]] || return 1
  controller_role_dependency_repair_preflight || return 1

  while IFS= read -r package; do packages+=("$package"); done < <(
    controller_role_dependency_packages
  )
  if ((${#packages[@]} != 8)); then
    controller_role_set_result unsafe_runtime package_manifest
    return 1
  fi

  if ! controller_role_run_apt_get \
      -o "DPkg::Lock::Timeout=$CONTROLLER_ROLE_APT_LOCK_TIMEOUT" \
      -o "Acquire::Retries=$CONTROLLER_ROLE_APT_RETRIES" \
      -o "Acquire::http::Timeout=$CONTROLLER_ROLE_APT_ACQUIRE_TIMEOUT" \
      -o "Acquire::https::Timeout=$CONTROLLER_ROLE_APT_ACQUIRE_TIMEOUT" \
      update; then
    controller_role_set_result dependency_repair_failed apt_update
    return 1
  fi
  if ! controller_role_run_apt_get \
      -o "DPkg::Lock::Timeout=$CONTROLLER_ROLE_APT_LOCK_TIMEOUT" \
      -o "Acquire::Retries=$CONTROLLER_ROLE_APT_RETRIES" \
      -o "Acquire::http::Timeout=$CONTROLLER_ROLE_APT_ACQUIRE_TIMEOUT" \
      -o "Acquire::https::Timeout=$CONTROLLER_ROLE_APT_ACQUIRE_TIMEOUT" \
      install -y --reinstall --no-install-recommends "${packages[@]}"; then
    controller_role_set_result dependency_repair_failed apt_install
    return 1
  fi
  if ! controller_role_dependencies_are_ready; then
    post_status="$CONTROLLER_ROLE_LAST_STATUS"
    post_detail="$CONTROLLER_ROLE_LAST_DETAIL"
    [[ -n "$post_status" ]] || post_status=unknown
    if [[ -n "$post_detail" ]]; then post_status+="::$post_detail"; fi
    controller_role_set_result dependency_repair_failed "$post_status"
    return 1
  fi
  controller_role_set_result dependencies_repaired
}

controller_role_provision_target_preflight() {
  controller_role_dependency_repair_base_preflight || return 1

  if [[ -e "$CONTROLLER_STATE_FILE" || -L "$CONTROLLER_STATE_FILE" ]]; then
    if ! controller_role_existing_artifacts_are_trusted; then
      controller_role_set_result state_invalid existing_artifacts
      return 1
    fi
    controller_role_set_result provision_target_existing
    return 0
  fi

  if ! controller_role_fresh_artifacts_are_safe; then
    controller_role_set_result state_invalid partial_artifacts
    return 1
  fi
  controller_role_classify_environment_footprint
  if [[ "$CONTROLLER_ROLE_ENVIRONMENT_CLASS" != fresh ]]; then
    controller_role_set_result role_conflict "$CONTROLLER_ROLE_ENVIRONMENT_CLASS"
    return 1
  fi
  controller_role_set_result provision_target_fresh
}

provision_entry_controller_role() {
  [[ $# -eq 0 ]] || return 64
  local target_status repair_status initialization_status
  local PATH="${PATH:-}" LC_ALL="${LC_ALL:-}"
  local BASH_ENV="${BASH_ENV:-}" ENV="${ENV:-}" CDPATH="${CDPATH:-}"
  local GLOBIGNORE="${GLOBIGNORE:-}" PYTHONHOME="${PYTHONHOME:-}"
  local PYTHONPATH="${PYTHONPATH:-}" OPENSSL_CONF="${OPENSSL_CONF:-}"
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    PATH=/usr/sbin:/usr/bin:/sbin:/bin
    LC_ALL=C
    BASH_ENV='' ENV='' CDPATH='' GLOBIGNORE='' PYTHONHOME='' PYTHONPATH='' OPENSSL_CONF=''
    export PATH LC_ALL BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH OPENSSL_CONF
  fi

  controller_role_provision_target_preflight || return 1
  target_status="$CONTROLLER_ROLE_LAST_STATUS"
  case "$target_status" in
    provision_target_fresh|provision_target_existing) ;;
    *)
      controller_role_set_result provision_failed unexpected_target
      return 1
      ;;
  esac

  repair_entry_controller_dependencies "$@" || return 1
  repair_status="$CONTROLLER_ROLE_LAST_STATUS"
  case "$repair_status" in
    dependencies_ready|dependencies_repaired) ;;
    *)
      controller_role_set_result provision_failed unexpected_repair_result
      return 1
      ;;
  esac

  initialize_entry_controller_role || return 1
  initialization_status="$CONTROLLER_ROLE_LAST_STATUS"
  case "$initialization_status" in
    initialized)
      controller_role_set_result entry_role_initialized
      ;;
    already_initialized)
      if [[ "$repair_status" == dependencies_repaired ]]; then
        controller_role_set_result entry_role_repaired
      else
        controller_role_set_result entry_role_ready
      fi
      ;;
    *)
      controller_role_set_result provision_failed unexpected_initialization_result
      return 1
      ;;
  esac
}

controller_role_private_file_is_trusted() {
  local path="$1" owner mode expected_owner
  [[ -f "$path" && ! -L "$path" ]] || return 1
  owner="$(manager_file_uid "$path")" || return 1
  mode="$(manager_file_mode "$path")" || return 1
  expected_owner="$(controller_state_expected_uid)" || return 1
  [[ "$owner" == "$expected_owner" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0777) == 0600 ))
}

controller_role_directory_is_empty() (
  local directory="$1"
  local -a entries=()
  shopt -s nullglob dotglob
  entries=("$directory"/*)
  ((${#entries[@]} == 0))
)

controller_role_existing_artifacts_are_trusted() {
  local state_parent lock_parent
  state_parent="$(dirname -- "$CONTROLLER_STATE_FILE")" || return 1
  lock_parent="$(dirname -- "$CONTROLLER_STATE_LOCK_FILE")" || return 1
  validate_controller_state_file "$CONTROLLER_STATE_FILE" || return 1
  controller_private_directory_is_trusted "$state_parent" || return 1
  controller_private_directory_is_trusted "$CONTROLLER_SECRET_DIR" || return 1
  if [[ -e "$lock_parent" || -L "$lock_parent" ]]; then
    controller_private_directory_is_trusted "$lock_parent" || return 1
  fi
  if [[ -e "$CONTROLLER_STATE_LOCK_FILE" || -L "$CONTROLLER_STATE_LOCK_FILE" ]]; then
    controller_role_private_file_is_trusted "$CONTROLLER_STATE_LOCK_FILE" || return 1
  fi
}

controller_role_fresh_artifacts_are_safe() {
  local state_parent lock_parent
  state_parent="$(dirname -- "$CONTROLLER_STATE_FILE")" || return 1
  lock_parent="$(dirname -- "$CONTROLLER_STATE_LOCK_FILE")" || return 1
  [[ ! -e "$CONTROLLER_STATE_FILE" && ! -L "$CONTROLLER_STATE_FILE" ]] || return 1
  if [[ -e "$state_parent" || -L "$state_parent" ]]; then
    controller_private_directory_is_trusted "$state_parent" || return 1
  fi
  if [[ -e "$CONTROLLER_SECRET_DIR" || -L "$CONTROLLER_SECRET_DIR" ]]; then
    controller_private_directory_is_trusted "$CONTROLLER_SECRET_DIR" || return 1
    controller_role_directory_is_empty "$CONTROLLER_SECRET_DIR" || return 1
  fi
  if [[ -e "$lock_parent" || -L "$lock_parent" ]]; then
    controller_private_directory_is_trusted "$lock_parent" || return 1
  fi
  if [[ -e "$CONTROLLER_STATE_LOCK_FILE" || -L "$CONTROLLER_STATE_LOCK_FILE" ]]; then
    controller_role_private_file_is_trusted "$CONTROLLER_STATE_LOCK_FILE" || return 1
  fi
}

controller_role_classify_environment_footprint() {
  local managed=0 core=0 complete=true path rooted
  for path in /etc/sb-user-manager.conf /etc/sing-box/managed-users.json \
    /usr/local/sbin/sb-user-manager /etc/systemd/system/sb-user-expiry.timer; do
    rooted="${SB_SYSTEM_ROOT:-}$path"
    [[ -e "$rooted" || -L "$rooted" ]] && ((managed+=1))
  done
  for path in /etc/sing-box/config.json /usr/local/bin/sing-box \
    /etc/systemd/system/sing-box.service /usr/local/bin/nfuse \
    /etc/systemd/system/nfuse.service /var/lib/nfuse/nfuse.db; do
    rooted="${SB_SYSTEM_ROOT:-}$path"
    [[ -e "$rooted" || -L "$rooted" ]] && ((core+=1))
  done
  for path in /etc/sb-user-manager.conf /etc/sing-box/config.json \
    /etc/sing-box/managed-users.json /usr/local/sbin/sb-user-manager \
    /usr/local/bin/sing-box /usr/local/bin/nfuse \
    /etc/systemd/system/sing-box.service /etc/systemd/system/nfuse.service \
    /etc/systemd/system/sb-user-expiry.service /etc/systemd/system/sb-user-expiry.timer; do
    rooted="${SB_SYSTEM_ROOT:-}$path"
    [[ -e "$rooted" || -L "$rooted" ]] || complete=false
  done

  if ((managed == 0 && core == 0)); then
    CONTROLLER_ROLE_ENVIRONMENT_CLASS=fresh
  elif [[ "$complete" == true ]]; then
    CONTROLLER_ROLE_ENVIRONMENT_CLASS=managed_complete
  elif ((managed > 0)); then
    CONTROLLER_ROLE_ENVIRONMENT_CLASS=managed_partial
  else
    CONTROLLER_ROLE_ENVIRONMENT_CLASS=external
  fi
}

controller_role_preflight() {
  controller_role_reset_result
  if [[ "$(controller_role_effective_uid)" != 0 ]]; then
    controller_role_set_result not_root
    return 1
  fi
  if ! controller_role_runtime_paths_are_safe; then
    controller_role_set_result unsafe_runtime fixed_paths
    return 1
  fi
  if ! controller_role_platform_is_supported; then
    controller_role_set_result unsupported_platform
    return 1
  fi
  controller_role_dependencies_are_ready || return 1
  controller_role_set_result ready
}

initialize_entry_controller_role() {
  controller_role_preflight || return 1

  if [[ -e "$CONTROLLER_STATE_FILE" || -L "$CONTROLLER_STATE_FILE" ]]; then
    if ! controller_role_existing_artifacts_are_trusted; then
      controller_role_set_result state_invalid existing_artifacts
      return 1
    fi
    controller_role_set_result already_initialized
    return 0
  fi

  if ! controller_role_fresh_artifacts_are_safe; then
    controller_role_set_result state_invalid partial_artifacts
    return 1
  fi
  controller_role_classify_environment_footprint
  if [[ "$CONTROLLER_ROLE_ENVIRONMENT_CLASS" != fresh ]]; then
    controller_role_set_result role_conflict "$CONTROLLER_ROLE_ENVIRONMENT_CLASS"
    return 1
  fi
  if ! init_controller_state || ! controller_role_existing_artifacts_are_trusted; then
    controller_role_set_result initialization_failed
    return 1
  fi
  controller_role_set_result initialized
}
