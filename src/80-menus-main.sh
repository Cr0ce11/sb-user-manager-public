
show_global_sni_settings() {
  local ss_total ss_mismatch anytls_total anytls_mismatch
  prepare_core
  ss_total="$(jq '[.users[] | . as $user |
    (if (.endpoints | type) == "array" then .endpoints[]
     else {protocol:(.protocol // "ss2022"),transport:(.transport // "shadowtls")} end) |
    select(.protocol == "ss2022" and .transport == "shadowtls")] | length' "$STATE_FILE")"
  ss_mismatch="$(jq --arg sni "$SS2022_SHADOWTLS_SNI" '[.users[] | . as $user |
    (if (.endpoints | type) == "array" then .endpoints[]
     else {protocol:(.protocol // "ss2022"),transport:(.transport // "shadowtls"),shadowtls_sni:.shadowtls_sni} end) |
    select(.protocol == "ss2022" and .transport == "shadowtls" and .shadowtls_sni != $sni)] | length' "$STATE_FILE")"
  anytls_total="$(jq '[.users[] | . as $user |
    (if (.endpoints | type) == "array" then .endpoints[] else {protocol:(.protocol // "ss2022")} end) |
    select(.protocol == "anytls")] | length' "$STATE_FILE")"
  anytls_mismatch="$(jq --arg sni "$ANYTLS_SNI" '[.users[] | . as $user |
    (if (.endpoints | type) == "array" then .endpoints[] else {protocol:(.protocol // "ss2022"),tls_sni:.tls_sni} end) |
    select(.protocol == "anytls" and .tls_sni != $sni)] | length' "$STATE_FILE")"
  printf '\n旧版 SS2022 + ShadowTLS 默认连接域名：%s\n' "$SS2022_SHADOWTLS_SNI"
  printf '  旧版用户数：%s，仍在使用其他域名：%s\n' "$ss_total" "$ss_mismatch"
  printf 'AnyTLS 默认连接域名：%s\n' "$ANYTLS_SNI"
  printf '  用户数：%s，仍在使用其他域名：%s\n' "$anytls_total" "$anytls_mismatch"
}

prompt_global_sni_change() {
  local protocol="$1" label="$2" current total answer new_sni
  prepare_core
  if [[ "$protocol" == ss2022 ]]; then current="$SS2022_SHADOWTLS_SNI"
  else current="$ANYTLS_SNI"
  fi
  total="$(count_protocol_sni_users "$protocol")" || return 1
  printf '\n%s 当前默认连接域名（SNI）：%s\n' "$label" "$current"
  while true; do
    read -r -p '请输入新的连接域名（留空取消）：' new_sni
    [[ -n "$new_sni" ]] || { echo '已取消修改。'; return 0; }
    if validate_without_exit validate_shadowtls_sni "$new_sni"; then break; fi
    printf '输入无效：%s，请重新输入。\n' "$VALIDATION_ERROR"
  done
  printf '将更新默认值，并把该协议已有的 %s 个用户同步为新域名。\n' "$total"
  if [[ "$protocol" == ss2022 ]] && ((total > 0)); then
    echo '保存时会短暂重启连接服务，现有连接可能中断几秒。'
  fi
  read -r -p '确认修改？[y/N]：' answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo '已取消修改。'; return 0; }
  cmd_set_global_sni "$protocol" "$new_sni"
}

global_sni_menu() {
  ensure_management_environment_ready || return 0
  local choice
  while true; do
    prepare_menu_screen
    ui_menu_begin
    ui_header '默认连接域名（SNI）' '连接参数'
    ui_section '查看与修改'
    ui_menu_items \
      show '查看当前默认域名' \
      ss2022 '修改旧版 ShadowTLS 默认域名' \
      anytls '修改 AnyTLS 默认域名'
    ui_back_item '返回上一级'
    ui_menu_select || return 0
    case "$UI_MENU_ACTION" in
      show) show_global_sni_settings; pause_menu;;
      ss2022) prompt_global_sni_change ss2022 '旧版 SS2022 + ShadowTLS'; pause_menu;;
      anytls) prompt_global_sni_change anytls AnyTLS; pause_menu;;
      back) return 0;;
    esac
  done
}

# 「geo 数据源」（公开 Issue #219）。留空表示用 mihomo 自带的源；这里如实显示
# 「默认（mihomo 自带）」而不是把 mihomo 的默认地址抄一份出来——抄一份就等于
# 替上游承诺那个地址永远不变，而抄错了没有任何地方会说。
show_geo_source_settings() {
  local geo_splits
  prepare_core
  geo_splits="$(jq '[.splits[]? | select(((.rule_geo // []) | length) > 0)] | length' "$STATE_FILE")" || return 1
  printf '\nGeoSite 数据源：%s\n' "${GEOSITE_URL:-默认（mihomo 自带）}"
  printf 'GeoIP 数据源：%s\n' "${GEOIP_URL:-默认（mihomo 自带）}"
  printf '\n用到 GeoSite／GeoIP 类别的分流：%s 条\n' "$geo_splits"
  if ((geo_splits == 0)); then
    echo '这台机器目前不下载任何 geo 数据库；添加第一条 geo 分流时才会下载。'
  else
    printf '数据库放在 %s，由 mihomo 每 %s 小时自己检查更新。\n' \
      "$MIHOMO_WORK_DIR" "$GEO_UPDATE_INTERVAL_HOURS"
  fi
}

prompt_geo_source_change() {
  local kind="$1" label="$2" current new_url answer
  prepare_core
  if [[ "$kind" == geosite ]]; then current="$GEOSITE_URL"; else current="$GEOIP_URL"; fi
  printf '\n%s当前：%s\n' "$label" "${current:-默认（mihomo 自带）}"
  echo '输入新的下载地址（HTTPS）；直接回车改回 mihomo 自带的源；输入 0 取消。'
  read -r -p '新地址：' new_url || return 0
  [[ "$new_url" != 0 ]] || { echo '已取消修改。'; return 0; }
  if [[ -z "$new_url" ]]; then
    if [[ -z "$current" ]]; then echo '当前就是默认源，没有变化。'; return 0; fi
    printf '将改回 mihomo 自带的源。\n'
  else
    printf '将改为：%s\n' "$new_url"
    echo '保存前会先连一次这个地址确认它取得到东西；取不到就当场拒绝，原值保持不变。'
  fi
  echo '这台机器上若已经有 geo 分流，保存时会重启内核让新源生效，现有连接中断几秒。'
  read -r -p '确认修改？[y/N]：' answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo '已取消修改。'; return 0; }
  cmd_set_geo_source "$kind" "$new_url" || return 0
}

geo_source_menu() {
  ensure_management_environment_ready || return 0
  while true; do
    prepare_menu_screen
    ui_menu_begin
    ui_header 'geo 数据源' 'GeoSite／GeoIP 数据库的下载地址'
    ui_section '查看与修改'
    ui_menu_items \
      show '查看当前数据源' \
      geosite '修改 GeoSite 数据源' \
      geoip '修改 GeoIP 数据源'
    ui_back_item '返回上一级'
    ui_menu_select || return 0
    case "$UI_MENU_ACTION" in
      show) show_geo_source_settings; pause_menu;;
      geosite) prompt_geo_source_change geosite 'GeoSite 数据源'; pause_menu;;
      geoip) prompt_geo_source_change geoip 'GeoIP 数据源'; pause_menu;;
      back) return 0;;
    esac
  done
}

ensure_management_environment_ready() {
  if [[ -e "$CONF_FILE" || -L "$CONF_FILE" ]]; then return 0; fi
  echo
  echo '尚未部署管理环境。请先进入「系统管理 → 部署与卸载 → 安装或修复环境」。'
  pause_menu
  return 1
}

user_management_menu() {
  ensure_management_environment_ready || return 0
  while true; do
    prepare_menu_screen
    ui_menu_begin
    ui_header '用户管理' '账号、状态与流量'
    ui_section '常用操作'
    ui_menu_items \
      add '添加用户' list '查看用户' \
      edit '编辑用户' export '导出用户配置' \
      protocols '管理用户协议'
    printf '\n'
    ui_section '状态与计费'
    ui_menu_items \
      disable '停用用户' enable '启用用户' \
      renew '调整用户有效期' traffic '调整用户流量'
    printf '\n'
    ui_section '危险操作'
    printf '%s' "$UI_RED"
    ui_menu_items remove '删除用户'
    printf '%s' "$UI_RESET"
    ui_back_item '返回主菜单'
    ui_menu_select || return 0
    case "$UI_MENU_ACTION" in
      add) MENU_RETURNED=false; prompt_add_node; [[ "$MENU_RETURNED" == true ]] || pause_menu;;
      remove) MENU_RETURNED=false; prompt_remove_user; [[ "$MENU_RETURNED" == true ]] || pause_menu;;
      list) prepare_core; cmd_list; pause_menu;;
      edit) MENU_RETURNED=false; prompt_edit_user; [[ "$MENU_RETURNED" == true ]] || pause_menu;;
      protocols) MENU_RETURNED=false; prompt_manage_user_protocols; [[ "$MENU_RETURNED" == true ]] || pause_menu;;
      disable) MENU_RETURNED=false; prompt_user_status_action cmd_disable active 停用; [[ "$MENU_RETURNED" == true ]] || pause_menu;;
      enable) MENU_RETURNED=false; prompt_user_status_action cmd_enable disabled 启用; [[ "$MENU_RETURNED" == true ]] || pause_menu;;
      renew) MENU_RETURNED=false; prompt_renew_user; [[ "$MENU_RETURNED" == true ]] || pause_menu;;
      traffic) MENU_RETURNED=false; prompt_adjust_traffic; [[ "$MENU_RETURNED" == true ]] || pause_menu;;
      export) MENU_RETURNED=false; prompt_export; [[ "$MENU_RETURNED" == true ]] || pause_menu;;
      back) return 0;;
    esac
  done
}

migration_backup_menu() {
  while true; do
    prepare_menu_screen
    ui_menu_begin
    ui_header '数据备份与恢复' '迁移与回滚'
    ui_section '备份'
    ui_menu_items \
      create '创建迁移备份（用于更换服务器）' import '添加外部备份文件' \
      list '查看已有备份' details '查看备份内容'
    printf '\n'
    ui_section '验证与恢复'
    ui_menu_items \
      check '检查备份（不会修改服务器）' check_all '批量体检全部备份（只读）' \
      restore '从备份恢复' reports '查看恢复记录'
    printf '\n'
    ui_section '清理'
    ui_menu_items remove '删除备份' cleanup '清理旧备份'
    ui_back_item '返回上一级'
    ui_menu_select || return 0
    case "$UI_MENU_ACTION" in
      create) ensure_management_environment_ready || continue; MENU_RETURNED=false; create_migration_backup; [[ "$MENU_RETURNED" == true ]] || pause_menu;;
      import) ensure_management_environment_ready || continue; import_migration_backup; pause_menu;;
      list) ensure_management_environment_ready || continue; echo; show_backup_storage_overview; echo; print_migration_backups || true; pause_menu;;
      details) show_migration_backup_details; pause_menu;;
      check) ensure_management_environment_ready || continue; MENU_RETURNED=false; preview_migration_backup; [[ "$MENU_RETURNED" == true ]] || pause_menu;;
      check_all) MENU_RETURNED=false; check_all_migration_backups; [[ "$MENU_RETURNED" == true ]] || pause_menu;;
      restore) ensure_management_environment_ready || continue; MENU_RETURNED=false; restore_migration_backup; [[ "$MENU_RETURNED" == true ]] || pause_menu;;
      remove) delete_migration_backup; pause_menu;;
      cleanup) ensure_management_environment_ready || continue; cleanup_backup_retention; pause_menu;;
      reports) migration_report_menu;;
      back) return 0;;
    esac
  done
}

system_management_menu() {
  while true; do
    prepare_menu_screen
    ui_menu_begin
    ui_header '系统管理' '运行、维护与基础配置'
    # 「sing-box 版本管理」只在 sing-box 机器上出现。mihomo 没有正式版／测试版
    # 通道这回事，留一个永远点不动的菜单项比少一项更让人困惑（公开 Issue #157 的 2f）。
    # 底层的守卫不撤：菜单是给人看的，守卫防的是别的调用点。
    ui_menu_items \
      deploy '部署与卸载' update '检测更新' \
      status '查看服务状态' diagnostics '检查与故障报告' \
      backup '数据备份与恢复' sni '默认连接域名（SNI）'
    # 「geo 数据源」只在 mihomo 上出现：sing-box 部署里没有 GeoSite／GeoIP
    # 这回事，留一个永远点不动的菜单项比少一项更让人困惑（公开 Issue #219）。
    [[ "$PROXY_KERNEL" != mihomo ]] || ui_menu_items geo 'geo 数据源'
    [[ "$PROXY_KERNEL" != singbox ]] || ui_menu_items channel 'sing-box 版本管理'
    ui_back_item '返回主菜单'
    ui_menu_select || return 0
    case "$UI_MENU_ACTION" in
      deploy) deployment_management_menu;;
      update) check_updates; pause_menu;;
      status) show_service_status; pause_menu;;
      diagnostics) diagnostic_report_menu;;
      backup) migration_backup_menu;;
      sni) global_sni_menu;;
      geo) geo_source_menu;;
      channel) singbox_channel_menu;;
      back) return 0;;
    esac
  done
}

deployment_management_menu() {
  while true; do
    prepare_menu_screen
    ui_menu_begin
    ui_header '部署与卸载' '安装、修复或移除运行环境'
    ui_menu_items \
      install '安装或修复环境' \
      switch '切换到 mihomo 内核' \
      cleanup '清理 sing-box 残留'
    printf '\n'
    ui_section '危险操作'
    printf '%s' "$UI_RED"
    ui_menu_items uninstall '完整卸载'
    printf '%s' "$UI_RESET"
    ui_back_item '返回上一级'
    ui_menu_select || return 0
    case "$UI_MENU_ACTION" in
      install) install_environment; pause_menu;;
      switch) switch_kernel_to_mihomo; pause_menu;;
      cleanup) cleanup_singbox_leftovers; pause_menu;;
      uninstall)
        MENU_RETURNED=false
        uninstall_environment
        [[ "$MENU_RETURNED" == true ]] || pause_menu
        ;;
      back) return 0;;
    esac
  done
}

interactive_main() {
  MENU_RETURNED=false
  while true; do
    MENU_RETURNED=false
    prepare_menu_screen
    ui_menu_begin
    ui_header "sb-user-manager ${SCRIPT_VERSION}（${SCRIPT_EDITION_LABEL}）"
    ui_section '功能板块'
    ui_menu_items \
      users '用户管理' splits '分流管理' \
      system '系统管理'
    ui_back_item '退出'
    ui_menu_select || return 0
    case "$UI_MENU_ACTION" in
      users) user_management_menu;;
      splits) split_management_menu;;
      system) system_management_menu;;
      back) exit 0;;
    esac
  done
}

main() {
  local recovered_installed
  # 只读子命令必须在 root 检查与接管恢复之前分发：recover_manager_handoff 会取锁并还原
  # 文件，只读查询不得触发它；权限与依赖由 readonly_prepare 自行检查并归为退出码 3。
  # 这里只匹配精确的子命令名，未知参数仍然落到下方 case 的 *) 分支被拒绝。
  case "${1:-}" in
    status|users) run_readonly_command "$@"; return $?;;
  esac
  [[ $EUID -eq 0 ]] || die "必须使用 root 运行"
  recover_manager_handoff || die "未完成的管理脚本接管尚未安全恢复"
  if [[ "$MANAGER_HANDOFF_RECOVERED" == true ]]; then
    recovered_installed="$(manager_handoff_installed_path)" || die "无法确认恢复后的管理脚本路径"
    recovered_installed="$(readlink -f -- "$recovered_installed" 2>/dev/null || printf '%s' "$recovered_installed")"
    if [[ "$SELF_PATH" == "$recovered_installed" ]]; then
      [[ "${1:-}" != --take-over-installed-manager ]] ||
        die "上次接管已恢复旧脚本；请重新运行单独下载并校验过的目标脚本完成接管"
      exec "$recovered_installed" "$@"
    fi
  fi
  case "${1:-}" in
    "") run_standalone_interactive_startup "${@:2}" ;;
    --internal-expire) run_standalone_internal_expire "${@:2}" ;;
    --take-over-installed-manager) take_over_installed_manager "${@:2}" ;;
    *) die "本脚本采用交互方式，请直接运行且不要添加参数" ;;
  esac
}

if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
  case "${0##*/}" in
    sb-user-manager-landing-agent|sb-user-manager-landing-apply)
      die 'v5 入口与落地能力已经退役，拒绝运行遗留 helper 入口'
      ;;
    *)
      install_runtime_traps
      main "$@"
      ;;
  esac
fi
