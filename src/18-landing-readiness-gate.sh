# ============================================================
# v5 入口侧落地秘密生成前准备门禁（尚未接入菜单或 onboarding）
# ============================================================
# 只编排依赖与 sing-box 准备并汇总稳定结果；不创建项目状态或秘密。
# shellcheck disable=SC2034

CONTROLLER_LANDING_READINESS_LAST_STAGE=not_started
CONTROLLER_LANDING_READINESS_LAST_FINGERPRINT=""
CONTROLLER_LANDING_READINESS_LAST_DEPENDENCY_STATUS=not_checked
CONTROLLER_LANDING_READINESS_LAST_DEPENDENCY_DETAIL=""
CONTROLLER_LANDING_READINESS_LAST_SINGBOX_STATUS=not_checked
CONTROLLER_LANDING_READINESS_LAST_SINGBOX_DETAIL=""
CONTROLLER_LANDING_READINESS_LAST_SINGBOX_VERSION=""
CONTROLLER_LANDING_READINESS_LAST_SINGBOX_SHA256=""

controller_landing_readiness_reset_result() {
  CONTROLLER_LANDING_READINESS_LAST_STAGE=not_started
  CONTROLLER_LANDING_READINESS_LAST_FINGERPRINT=""
  CONTROLLER_LANDING_READINESS_LAST_DEPENDENCY_STATUS=not_checked
  CONTROLLER_LANDING_READINESS_LAST_DEPENDENCY_DETAIL=""
  CONTROLLER_LANDING_READINESS_LAST_SINGBOX_STATUS=not_checked
  CONTROLLER_LANDING_READINESS_LAST_SINGBOX_DETAIL=""
  CONTROLLER_LANDING_READINESS_LAST_SINGBOX_VERSION=""
  CONTROLLER_LANDING_READINESS_LAST_SINGBOX_SHA256=""
}

controller_landing_readiness_capture_dependency_result() {
  CONTROLLER_LANDING_READINESS_LAST_DEPENDENCY_STATUS="$CONTROLLER_LANDING_DEPENDENCY_LAST_STATUS"
  # 详情由后续交互层与定向测试在函数返回后读取。
  # shellcheck disable=SC2034
  CONTROLLER_LANDING_READINESS_LAST_DEPENDENCY_DETAIL="$CONTROLLER_LANDING_DEPENDENCY_LAST_DETAIL"
}

controller_landing_readiness_capture_singbox_result() {
  CONTROLLER_LANDING_READINESS_LAST_SINGBOX_STATUS="$CONTROLLER_LANDING_SINGBOX_LAST_STATUS"
  # 详情由后续交互层与定向测试在函数返回后读取。
  # shellcheck disable=SC2034
  CONTROLLER_LANDING_READINESS_LAST_SINGBOX_DETAIL="$CONTROLLER_LANDING_SINGBOX_LAST_DETAIL"
  CONTROLLER_LANDING_READINESS_LAST_SINGBOX_VERSION="$CONTROLLER_LANDING_SINGBOX_LAST_VERSION"
  CONTROLLER_LANDING_READINESS_LAST_SINGBOX_SHA256="$CONTROLLER_LANDING_SINGBOX_LAST_SHA256"
}

controller_landing_readiness_dependency_success_is_valid() {
  [[ "$CONTROLLER_LANDING_READINESS_LAST_DEPENDENCY_STATUS" == ready ||
     "$CONTROLLER_LANDING_READINESS_LAST_DEPENDENCY_STATUS" == repaired ]]
}

controller_landing_readiness_singbox_success_is_valid() {
  [[ "$CONTROLLER_LANDING_READINESS_LAST_SINGBOX_STATUS" == ready ||
     "$CONTROLLER_LANDING_READINESS_LAST_SINGBOX_STATUS" == installed ]] || return 1
  [[ "$CONTROLLER_LANDING_READINESS_LAST_SINGBOX_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ &&
     "$CONTROLLER_LANDING_READINESS_LAST_SINGBOX_SHA256" =~ ^[0-9a-f]{64}$ ]]
}

controller_landing_readiness_create_phase_directories() {
  [[ $# -eq 1 ]] || return 64
  local work="$1" dependency_work="$1/dependency" singbox_work="$1/singbox"
  controller_private_directory_is_trusted "$work" || return 1
  [[ ! -e "$dependency_work" && ! -L "$dependency_work" &&
     ! -e "$singbox_work" && ! -L "$singbox_work" ]] || return 1
  ensure_controller_private_directory "$dependency_work" || return 1
  ensure_controller_private_directory "$singbox_work" || return 1
  controller_private_directory_is_trusted "$dependency_work" || return 1
  controller_private_directory_is_trusted "$singbox_work"
}

controller_landing_readiness_pending_recovery_exists() {
  controller_landing_onboarding_paths_are_safe || return 2
  [[ -e "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE" ||
     -L "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE" ||
     -e "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_NEXT" ||
     -L "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_NEXT" ]]
}

controller_prepare_landing_readiness() {
  [[ $# -eq 3 ]] || return 64
  local address="$1" ssh_port="$2" landing_id="$3"
  local fingerprint work dependency_work singbox_work confirm_rc=0 pending_rc=0 rc=1
  controller_landing_readiness_reset_result
  controller_landing_dependency_reset_result
  controller_landing_singbox_reset_result

  if ! controller_landing_dependency_settings_are_safe ||
     ! controller_landing_singbox_settings_are_safe ||
     ! controller_landing_transport_runtime_is_safe; then
    CONTROLLER_LANDING_READINESS_LAST_STAGE=unsafe_local_runtime
    return 1
  fi
  if ! controller_landing_address_is_valid "$address" ||
     ! landing_port_is_valid "$ssh_port" ||
     ! landing_id_is_valid "$landing_id"; then
    CONTROLLER_LANDING_READINESS_LAST_STAGE=invalid_input
    return 1
  fi
  if ! validate_controller_state_file "$CONTROLLER_STATE_FILE"; then
    CONTROLLER_LANDING_READINESS_LAST_STAGE=invalid_controller_state
    return 1
  fi
  if controller_landing_readiness_pending_recovery_exists; then
    pending_rc=0
  else
    pending_rc=$?
  fi
  case "$pending_rc" in
    0)
      CONTROLLER_LANDING_READINESS_LAST_STAGE=pending_recovery
      return 1
      ;;
    1) ;;
    *)
      CONTROLLER_LANDING_READINESS_LAST_STAGE=unsafe_local_runtime
      return 1
      ;;
  esac

  fingerprint="$(controller_landing_discover_fingerprint "$address" "$ssh_port")" || {
    CONTROLLER_LANDING_READINESS_LAST_STAGE=fingerprint_discovery_failed
    return 1
  }
  if [[ ! "$fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]]; then
    CONTROLLER_LANDING_READINESS_LAST_STAGE=fingerprint_discovery_failed
    return 1
  fi
  # 指纹由后续交互层与定向测试在函数返回后读取。
  # shellcheck disable=SC2034
  CONTROLLER_LANDING_READINESS_LAST_FINGERPRINT="$fingerprint"
  if controller_confirm_landing_fingerprint "$address" "$ssh_port" "$fingerprint"; then
    confirm_rc=0
  else
    confirm_rc=$?
  fi
  if ((confirm_rc != 0)); then
    if ((confirm_rc == 2)); then
      CONTROLLER_LANDING_READINESS_LAST_STAGE=fingerprint_rejected
      return 2
    fi
    CONTROLLER_LANDING_READINESS_LAST_STAGE=fingerprint_confirmation_failed
    return 1
  fi

  work="$(controller_landing_create_work_directory)" || {
    CONTROLLER_LANDING_READINESS_LAST_STAGE=unsafe_local_runtime
    return 1
  }
  register_temp_path "$work" || {
    controller_landing_remove_work_directory "$work" || true
    CONTROLLER_LANDING_READINESS_LAST_STAGE=unsafe_local_runtime
    return 1
  }
  if ! controller_landing_readiness_create_phase_directories "$work"; then
    CONTROLLER_LANDING_READINESS_LAST_STAGE=unsafe_local_runtime
    controller_landing_remove_work_directory "$work" ||
      CONTROLLER_LANDING_READINESS_LAST_STAGE=local_cleanup_failed
    return 1
  fi
  dependency_work="$work/dependency"
  singbox_work="$work/singbox"

  if controller_landing_prepare_dependencies_in_work "$address" "$ssh_port" "$landing_id" \
      "$fingerprint" "$dependency_work"; then
    controller_landing_readiness_capture_dependency_result
    if ! controller_landing_readiness_dependency_success_is_valid; then
      CONTROLLER_LANDING_READINESS_LAST_STAGE=dependency_failed
      controller_landing_remove_work_directory "$work" ||
        CONTROLLER_LANDING_READINESS_LAST_STAGE=local_cleanup_failed
      return 1
    fi
  else
    controller_landing_readiness_capture_dependency_result
    CONTROLLER_LANDING_READINESS_LAST_STAGE=dependency_failed
    controller_landing_remove_work_directory "$work" ||
      CONTROLLER_LANDING_READINESS_LAST_STAGE=local_cleanup_failed
    return 1
  fi

  if controller_landing_prepare_singbox_runtime_in_work "$address" "$ssh_port" "$landing_id" \
      "$fingerprint" "$singbox_work"; then
    controller_landing_readiness_capture_singbox_result
    if controller_landing_readiness_singbox_success_is_valid; then
      CONTROLLER_LANDING_READINESS_LAST_STAGE=ready
      rc=0
    else
      CONTROLLER_LANDING_READINESS_LAST_STAGE=singbox_failed
    fi
  else
    controller_landing_readiness_capture_singbox_result
    CONTROLLER_LANDING_READINESS_LAST_STAGE=singbox_failed
  fi
  if ! controller_landing_remove_work_directory "$work"; then
    # 最终失败阶段由后续交互层与定向测试在函数返回后读取。
    # shellcheck disable=SC2034
    CONTROLLER_LANDING_READINESS_LAST_STAGE=local_cleanup_failed
    rc=1
  fi
  return "$rc"
}
