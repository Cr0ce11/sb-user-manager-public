# ============================================================
# 角色感知启动分发与首次入口安装
# ============================================================

MANAGER_ROLE_REDISPATCH=10

manager_role_detection_failure_message() {
  case "${MANAGER_ROLE_DETECTION_STATUS:-unknown}/${MANAGER_ROLE_DETECTION_DETAIL:-}" in
    role_conflict/mixed_role_markers)
      echo '检测到互相冲突的管理角色标记。为保护现有配置，脚本不会进入任何管理界面。'
      ;;
    role_conflict/legacy_environment_recovery)
      echo '存在不属于当前角色的旧版恢复标记。请保留现场并先完成诊断，脚本不会自动处理。'
      ;;
    role_conflict/controller_artifacts)
      echo '检测到入口控制器残留与当前角色冲突。请保留现场并先完成诊断。'
      ;;
    environment_incomplete/landing)
      echo '检测到未完成的落地机环境。请保留现场并使用同版本恢复流程处理。'
      ;;
    environment_incomplete/standalone)
      echo '检测到未完成的单机环境，但没有可安全执行的恢复记录。请先检查安装现场。'
      ;;
    external_environment/)
      echo '检测到不由本项目管理的现有运行环境。脚本不会自动接管或覆盖。'
      ;;
    role_invalid/controller_state|role_invalid/controller_artifacts)
      echo '入口控制器状态无效或不完整。请保留现场并先完成诊断。'
      ;;
    role_invalid/landing_identity)
      echo '落地机身份状态无效或不完整。请保留现场并先完成诊断。'
      ;;
    unsafe_runtime/*)
      echo '管理器运行环境不安全，已停止角色分发。'
      ;;
    not_root/)
      echo '必须使用 root 运行管理器。'
      ;;
    *)
      echo '无法安全识别当前管理角色。请保留现场并先完成诊断。'
      ;;
  esac
}

controller_role_provision_failure_message() {
  case "${CONTROLLER_ROLE_LAST_STATUS:-unknown}/${CONTROLLER_ROLE_LAST_DETAIL:-}" in
    unsupported_platform/)
      echo '入口控制器仅支持 Debian 12 x86_64。当前系统未通过平台检查。'
      ;;
    dependency_repair_failed/apt_update)
      echo '系统依赖修复失败：软件源更新未成功。没有创建入口角色，请检查网络和软件源后重试。'
      ;;
    dependency_repair_failed/apt_install)
      echo '系统依赖修复失败：固定依赖安装未成功。没有创建入口角色，请修复包管理器后重试。'
      ;;
    missing_dependency/*|unsafe_dependency/*)
      echo '入口控制器依赖缺失或不可信，自动修复未能安全完成。'
      ;;
    role_conflict/*)
      echo '当前服务器已有其他运行环境，不能直接安装为入口控制器。'
      ;;
    state_invalid/*)
      echo '检测到不完整或不可信的入口状态。脚本不会覆盖现有文件。'
      ;;
    *)
      echo '入口控制器安装未完成。没有开放入口管理功能，请保留现场后重试或诊断。'
      ;;
  esac
}

manager_role_legacy_recovery_marker_is_trusted() {
  local marker="$ENVIRONMENT_TRANSACTION_JOURNAL" owner mode expected_owner
  [[ -f "$marker" && ! -L "$marker" ]] || return 1
  owner="$(manager_file_uid "$marker")" || return 1
  mode="$(manager_file_mode "$marker")" || return 1
  expected_owner="$(runtime_config_expected_uid)" || return 1
  [[ "$owner" == "$expected_owner" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0077) == 0 ))
}

manager_role_may_recover_legacy_environment() {
  case "${MANAGER_ROLE:-unknown}" in
    undeployed|standalone) return 0 ;;
  esac
  [[ "${MANAGER_ROLE:-unknown}" == unknown ]] || return 1
  case "${MANAGER_ROLE_DETECTION_STATUS:-unknown}" in
    environment_incomplete|external_environment) return 0 ;;
    *) return 1 ;;
  esac
}

detect_manager_role_with_legacy_recovery() {
  [[ $# -eq 0 ]] || return 64
  local detected=false recovery_attempts=2
  while ((recovery_attempts > 0)); do
    recovery_attempts=$((recovery_attempts - 1))
    if detect_manager_role "$@"; then detected=true; else detected=false; fi
    if [[ -e "$ENVIRONMENT_TRANSACTION_JOURNAL" ||
          -L "$ENVIRONMENT_TRANSACTION_JOURNAL" ]]; then
      if ! manager_role_may_recover_legacy_environment ||
         ! manager_role_legacy_recovery_marker_is_trusted; then
        manager_role_set_result unknown role_conflict legacy_environment_recovery
        return 1
      fi
      recover_environment_transaction || return 1
      if [[ -e "$ENVIRONMENT_TRANSACTION_JOURNAL" ||
            -L "$ENVIRONMENT_TRANSACTION_JOURNAL" ]]; then
        manager_role_set_result unknown role_conflict legacy_environment_recovery
        return 1
      fi
      continue
    fi
    [[ "$detected" == true ]]
    return
  done
  manager_role_set_result unknown role_invalid recovery_did_not_converge
  return 1
}

confirm_and_provision_entry_controller() {
  [[ $# -eq 0 ]] || return 64
  local answer
  cat <<'EOF'

安装为入口控制器将：
  - 检查 Debian 12 x86_64 与固定系统依赖；
  - 必要时通过系统包管理器安装或修复固定依赖；
  - 创建独立的入口控制器状态，不安装入口数据面或连接落地机。

现有单机部署、外部 sing-box 环境或可疑残留都会在修改前被拒绝。
EOF
  read -r -p '确认安装为入口控制器？[y/N]：' answer || {
    echo '已取消入口控制器安装。'
    return 1
  }
  if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    echo '已取消入口控制器安装。'
    return 1
  fi
  if ! provision_entry_controller_role "$@"; then
    controller_role_provision_failure_message
    return 1
  fi
  case "$CONTROLLER_ROLE_LAST_STATUS" in
    entry_role_initialized)
      ui_success '入口控制器角色已建立。'
      ;;
    entry_role_repaired)
      ui_success '入口控制器依赖已修复，原有状态保持不变。'
      ;;
    entry_role_ready)
      ui_success '入口控制器已经就绪。'
      ;;
    *)
      echo '入口控制器返回了无法识别的完成状态，已停止进入管理界面。'
      return 1
      ;;
  esac
}

undeployed_role_selection_menu() {
  [[ $# -eq 0 ]] || return 64
  while true; do
    prepare_menu_screen
    ui_menu_begin
    ui_header "sb-user-manager ${SCRIPT_VERSION}（${SCRIPT_EDITION_LABEL}）" '首次部署'
    echo '这台服务器尚未部署。选择角色前不会修改系统。'
    ui_section '选择部署方式'
    ui_menu_items \
      standalone '安装为单机节点' \
      entry-controller '安装为入口控制器'
    ui_back_item '退出'
    ui_menu_select || return 0
    case "$UI_MENU_ACTION" in
      standalone)
        if install_environment; then return "$MANAGER_ROLE_REDISPATCH"; fi
        ui_error '单机环境安装未完成，请根据上方提示处理后重试。'
        ;;
      entry-controller)
        if confirm_and_provision_entry_controller "$@"; then
          return "$MANAGER_ROLE_REDISPATCH"
        fi
        ;;
      back) return 0 ;;
    esac
  done
}

entry_controller_status_summary() {
  local state=未知 total=未知 healthy=未知 pending=未知
  if validate_controller_state_file "$CONTROLLER_STATE_FILE"; then
    state=就绪
    total="$(jq -r '.landings | length' "$CONTROLLER_STATE_FILE" 2>/dev/null || printf '未知')"
    healthy="$(jq -r '[.landings[] | select(.status == "active" and .desired_revision == .applied_revision)] | length' \
      "$CONTROLLER_STATE_FILE" 2>/dev/null || printf '未知')"
    pending="$(jq -r '[.landings[] | select(.desired_revision != .applied_revision)] | length' \
      "$CONTROLLER_STATE_FILE" 2>/dev/null || printf '未知')"
  fi
  printf '入口状态：%s  用户数：未知  正常落地：%s/%s  待同步：%s  配额异常：未知\n' \
    "$state" "$healthy" "$total" "$pending"
}

manager_role_pending_feature() {
  echo
  echo '此功能的底层安全能力已准备，但交互操作尚未开放。'
  echo '当前版本不会执行替代操作，也不会回落到单机管理流程。'
}

entry_controller_main() {
  while true; do
    prepare_menu_screen
    ui_menu_begin
    ui_header "sb-user-manager ${SCRIPT_VERSION}（入口控制器）"
    entry_controller_status_summary
    ui_section '集中管理'
    ui_menu_items \
      entry '入口机管理' landing '落地机管理' \
      backup '数据备份与恢复' system '系统管理'
    ui_back_item '退出'
    ui_menu_select || return 0
    case "$UI_MENU_ACTION" in
      entry|landing|backup|system)
        manager_role_pending_feature
        pause_menu
        ;;
      back) return 0 ;;
    esac
  done
}

landing_status_summary() {
  local state=未知 revision=未知 identity_path
  identity_path="$(landing_channel_path "$LANDING_CHANNEL_IDENTITY_PATH")" || {
    printf '管理状态：未知  当前配置版本：未知\n'
    return 0
  }
  if validate_landing_channel_identity_file "$identity_path"; then
    state='受入口管理'
  fi
  if [[ -e "$LANDING_RECEIPT_FILE" || -L "$LANDING_RECEIPT_FILE" ]] &&
     validate_landing_receipt_file "$LANDING_RECEIPT_FILE"; then
    revision="$(jq -r '.applied_revision' "$LANDING_RECEIPT_FILE" 2>/dev/null || printf '未知')"
  fi
  printf '管理状态：%s  当前配置版本：%s\n' "$state" "$revision"
}

landing_managed_main() {
  while true; do
    prepare_menu_screen
    ui_menu_begin
    ui_header '本机由入口控制器管理'
    landing_status_summary
    ui_section '本机操作'
    ui_menu_items \
      status '查看只读状态' revision '查看当前配置版本' \
      check '检查服务（尚未开放）' rollback '紧急恢复上一个版本（尚未开放）' \
      detach '撤销入口管理（尚未开放）'
    ui_back_item '退出'
    ui_menu_select || return 0
    case "$UI_MENU_ACTION" in
      status|revision|check|rollback|detach)
        manager_role_pending_feature
        pause_menu
        ;;
      back) return 0 ;;
    esac
  done
}

run_standalone_interactive_startup() {
  [[ $# -eq 0 ]] || return 64
  recover_environment_transaction
  if ! detect_manager_role "$@" || [[ "$MANAGER_ROLE" != standalone ]]; then
    manager_role_detection_failure_message
    return 1
  fi
  if ! harden_existing_environment_backups; then
    log '警告：部分历史环境快照权限未能自动收紧，请在「检查与故障报告」中查看环境状态'
  fi
  ensure_manager_launch_copies_for_interactive_startup
  ensure_manager_shortcut_for_interactive_startup
  recover_transaction_before_menu
  if ! migrate_backup_retention_once; then
    log '警告：旧的完整备份暂未能自动整理，不影响当前服务和数据；下次运行时会再次尝试'
  fi
  if ! migrate_legacy_ss2022_udp_inbounds; then
    log '警告：旧版 SS2022 + ShadowTLS 用户的 UDP 支持暂未完成迁移，请稍后重新运行脚本或使用「服务与配置检查」'
  fi
  if ! migrate_shared_preset_runtime_configs; then
    log '警告：共享预置配置暂未完成整理，请稍后重新运行脚本或使用「服务与配置检查」'
  fi
  interactive_main
}

dispatch_interactive_startup() {
  [[ $# -eq 0 ]] || return 64
  local rc handoff_checked=false
  while true; do
    if ! detect_manager_role_with_legacy_recovery "$@"; then
      manager_role_detection_failure_message
      return 1
    fi
    if [[ "$MANAGER_ROLE" != undeployed && "$handoff_checked" == false ]]; then
      handoff_to_newer_installed_manager
      handoff_checked=true
    fi
    case "$MANAGER_ROLE" in
      undeployed)
        if undeployed_role_selection_menu "$@"; then rc=0; else rc=$?; fi
        if [[ "$rc" == "$MANAGER_ROLE_REDISPATCH" ]]; then continue; fi
        return "$rc"
        ;;
      standalone) run_standalone_interactive_startup "$@"; return ;;
      entry-controller) entry_controller_main; return ;;
      landing) landing_managed_main; return ;;
      *)
        manager_role_set_result unknown role_invalid dispatch_result
        manager_role_detection_failure_message
        return 1
        ;;
    esac
  done
}

run_standalone_internal_expire() {
  [[ $# -eq 0 ]] || return 64
  if ! detect_manager_role_with_legacy_recovery "$@" || [[ "$MANAGER_ROLE" != standalone ]]; then
    echo '当前角色不执行单机到期任务。'
    return 1
  fi
  handoff_to_newer_installed_manager --internal-expire
  recover_environment_transaction
  if ! detect_manager_role "$@" || [[ "$MANAGER_ROLE" != standalone ]]; then
    manager_role_detection_failure_message
    return 1
  fi
  prepare_core
  cmd_expire
}
