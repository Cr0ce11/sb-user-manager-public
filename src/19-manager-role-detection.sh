# ============================================================
# v5 管理器角色只读识别（尚未接入启动或菜单）
# ============================================================
# shellcheck disable=SC2034

MANAGER_ROLE=unknown
MANAGER_ROLE_DETECTION_STATUS=not_checked
MANAGER_ROLE_DETECTION_DETAIL=""

manager_role_reset_result() {
  MANAGER_ROLE=unknown
  MANAGER_ROLE_DETECTION_STATUS=not_checked
  MANAGER_ROLE_DETECTION_DETAIL=""
}

manager_role_set_result() {
  # 结果由未来启动分发层与当前定向测试在函数返回后读取。
  # shellcheck disable=SC2034
  MANAGER_ROLE="$1"
  # shellcheck disable=SC2034
  MANAGER_ROLE_DETECTION_STATUS="$2"
  # shellcheck disable=SC2034
  MANAGER_ROLE_DETECTION_DETAIL="${3:-}"
}

manager_role_landing_footprint_exists() {
  local logical rooted
  for logical in \
    "$LANDING_CHANNEL_HOME" "$LANDING_CHANNEL_GENERATION_PATH" \
    "$LANDING_CHANNEL_SSH_DIRECTORY" "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH" \
    "$LANDING_CHANNEL_AGENT_PATH" "$LANDING_CHANNEL_RUNTIME_DIRECTORY" \
    "$LANDING_CHANNEL_RUNTIME_PATH" "$LANDING_AGENT_HELPER_PATH" \
    "$LANDING_CHANNEL_SUDOERS_PATH" "$LANDING_CHANNEL_LOCK_PATH" \
    "$LANDING_CHANNEL_INPUT_LOCK_PATH" "$LANDING_CHANNEL_TRANSACTION_DIRECTORY" \
    "$LANDING_CHANNEL_TRANSACTION_JOURNAL" "$LANDING_STARTUP_RECOVERY_UNIT_PATH" \
    "$LANDING_STARTUP_RECOVERY_DROPIN_DIRECTORY" "$LANDING_STARTUP_RECOVERY_DROPIN_PATH"; do
    rooted="$(landing_channel_path "$logical")" || return 2
    if [[ -e "$rooted" || -L "$rooted" ]]; then return 0; fi
  done
  return 1
}

detect_manager_role() {
  [[ $# -eq 0 ]] || return 64
  local landing_identity controller_marker=false landing_marker=false
  local landing_footprint=false landing_footprint_rc
  local PATH="${PATH:-}" LC_ALL="${LC_ALL:-}"
  local BASH_ENV="${BASH_ENV:-}" ENV="${ENV:-}" CDPATH="${CDPATH:-}"
  local GLOBIGNORE="${GLOBIGNORE:-}" PYTHONHOME="${PYTHONHOME:-}"
  local PYTHONPATH="${PYTHONPATH:-}" OPENSSL_CONF="${OPENSSL_CONF:-}"
  manager_role_reset_result

  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    PATH=/usr/sbin:/usr/bin:/sbin:/bin
    LC_ALL=C
    BASH_ENV='' ENV='' CDPATH='' GLOBIGNORE='' PYTHONHOME='' PYTHONPATH='' OPENSSL_CONF=''
    export PATH LC_ALL BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH OPENSSL_CONF
  fi

  if [[ "$(controller_role_effective_uid)" != 0 ]]; then
    manager_role_set_result unknown not_root
    return 1
  fi
  if ! controller_role_runtime_paths_are_safe ||
     ! landing_channel_runtime_paths_are_safe; then
    manager_role_set_result unknown unsafe_runtime fixed_paths
    return 1
  fi

  landing_identity="$(landing_channel_path "$LANDING_CHANNEL_IDENTITY_PATH")" || {
    manager_role_set_result unknown unsafe_runtime fixed_paths
    return 1
  }
  if [[ -e "$CONTROLLER_STATE_FILE" || -L "$CONTROLLER_STATE_FILE" ]]; then
    controller_marker=true
  fi
  if [[ -e "$landing_identity" || -L "$landing_identity" ]]; then
    landing_marker=true
  fi
  if manager_role_landing_footprint_exists; then
    landing_footprint=true
  else
    landing_footprint_rc=$?
    if [[ "$landing_footprint_rc" != 1 ]]; then
      manager_role_set_result unknown unsafe_runtime fixed_paths
      return 1
    fi
  fi

  if [[ "$controller_marker" == true &&
        ( "$landing_marker" == true || "$landing_footprint" == true ) ]]; then
    manager_role_set_result unknown role_conflict mixed_role_markers
    return 1
  fi
  if [[ "$controller_marker" == true ]]; then
    if ! controller_role_existing_artifacts_are_trusted; then
      manager_role_set_result unknown role_invalid controller_state
      return 1
    fi
    manager_role_set_result entry-controller role_detected
    return 0
  fi
  if [[ "$landing_marker" == true ]]; then
    if ! controller_role_fresh_artifacts_are_safe; then
      manager_role_set_result unknown role_conflict controller_artifacts
      return 1
    fi
    if ! validate_landing_channel_identity_file "$landing_identity"; then
      manager_role_set_result unknown role_invalid landing_identity
      return 1
    fi
    manager_role_set_result landing role_detected
    return 0
  fi
  if [[ "$landing_footprint" == true ]]; then
    manager_role_set_result unknown environment_incomplete landing
    return 1
  fi
  if ! controller_role_fresh_artifacts_are_safe; then
    manager_role_set_result unknown role_invalid controller_artifacts
    return 1
  fi

  controller_role_classify_environment_footprint
  case "$CONTROLLER_ROLE_ENVIRONMENT_CLASS" in
    fresh)
      manager_role_set_result undeployed role_detected
      ;;
    managed_complete)
      manager_role_set_result standalone role_detected
      ;;
    managed_partial)
      manager_role_set_result unknown environment_incomplete standalone
      return 1
      ;;
    external)
      manager_role_set_result unknown external_environment
      return 1
      ;;
    *)
      manager_role_set_result unknown role_invalid footprint_classification
      return 1
      ;;
  esac
}
