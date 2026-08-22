# ============================================================
# standalone 启动编排
# ============================================================

run_standalone_interactive_startup() {
  [[ $# -eq 0 ]] || return 64
  recover_environment_transaction || return 1
  handoff_to_newer_installed_manager || return 1
  if ! harden_existing_environment_backups; then
    log '警告：部分历史环境快照权限未能自动收紧，请在「检查与故障报告」中查看环境状态'
  fi
  ensure_manager_launch_copies_for_interactive_startup || return 1
  ensure_manager_shortcut_for_interactive_startup || return 1
  recover_transaction_before_menu || return 1
  if ! migrate_backup_retention_once; then
    log '警告：旧的完整备份暂未能自动整理，不影响当前服务和数据；下次运行时会再次尝试'
  fi
  if ! migrate_legacy_ss2022_udp_inbounds; then
    log '警告：旧版 SS2022 + ShadowTLS 用户的 UDP 支持暂未完成迁移，请稍后重新运行脚本或使用「服务与配置检查」'
  fi
  if ! migrate_empty_split_preset_fields; then
    log '警告：分流的预置来源记录暂未完成整理，请稍后重新运行脚本或使用「服务与配置检查」'
  fi
  if ! migrate_shared_preset_runtime_configs; then
    log '警告：共享预置配置暂未完成整理，请稍后重新运行脚本或使用「服务与配置检查」'
  fi
  interactive_main || return 1
}

standalone_environment_is_complete() {
  local logical rooted
  # 内核相关的三项由适配层按当前内核给出：一台 mihomo 机器上没有 sing-box
  # 是正常状态，写死 sing-box 会让到期任务在这类机器上永远拒绝运行。
  while IFS= read -r logical; do
    rooted="$(system_path "$logical")" || return 1
    [[ -e "$rooted" || -L "$rooted" ]] || return 1
  done < <(
    kernel_core_paths
    cat <<EOF
/etc/sb-user-manager.conf
$MANAGER_DATA_DIR/managed-users.json
/usr/local/sbin/sb-user-manager
/usr/local/bin/nfuse
/etc/systemd/system/nfuse.service
/etc/systemd/system/sb-user-expiry.service
/etc/systemd/system/sb-user-expiry.timer
EOF
  )
}

run_standalone_internal_expire() {
  [[ $# -eq 0 ]] || return 64
  # **必须先确定内核，再检查环境完不完整。** 下面那条检查里内核相关的三项由适配层
  # 按 PROXY_KERNEL 给出，而这一刻管理配置还没有载入（它在 prepare_core 里），
  # PROXY_KERNEL 仍是文件级默认值 sing-box——于是一台 mihomo 机器会被判成
  # 「没装好」，到期任务每 15 分钟失败一次，**到期用户永远不会被自动停用**
  # （公开 Issue #251）。失败的是一个 oneshot 服务，不产生任何界面提示，
  # 所以它可以坏很久而没人发现。
  # 与 resolve_deployment_kernel 注释里记的那次事故同类：必须显式确定内核，
  # 不能依赖文件级默认值。
  resolve_deployment_kernel || return 1
  recover_environment_transaction || return 1
  if ! standalone_environment_is_complete; then
    echo '当前环境尚未完成单机部署，不执行到期任务。'
    return 1
  fi
  handoff_to_newer_installed_manager --internal-expire || return 1
  prepare_core || return 1
  cmd_expire || return 1
}
