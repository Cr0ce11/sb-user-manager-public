
OPERATION_LOCK_ERROR=""

acquire_operation_lock() {
  local lock_file lock_directory
  OPERATION_LOCK_ERROR=""
  if [[ -n "${LOCK_FILE:-}" ]]; then
    lock_file="$LOCK_FILE"
  else
    lock_file="$(system_path /run/lock/sb-user-manager.lock)" || {
      OPERATION_LOCK_ERROR="无法确定管理操作锁位置"
      return 1
    }
  fi
  lock_directory="$(dirname "$lock_file")" || {
    OPERATION_LOCK_ERROR="无法确定管理操作锁目录"
    return 1
  }
  if [[ -e "$lock_directory" || -L "$lock_directory" ]]; then
    if [[ ! -d "$lock_directory" || -L "$lock_directory" ]]; then
      OPERATION_LOCK_ERROR="管理操作锁目录类型不安全：$lock_directory"
      return 1
    fi
  elif ! install -d -m 755 -- "$lock_directory"; then
    OPERATION_LOCK_ERROR="无法创建管理操作锁目录：$lock_directory"
    return 1
  fi
  if [[ ( -e "$lock_file" || -L "$lock_file" ) && ( ! -f "$lock_file" || -L "$lock_file" ) ]]; then
    OPERATION_LOCK_ERROR="管理操作锁文件类型不安全：$lock_file"
    return 1
  fi
  if ! { exec 9>"$lock_file"; }; then
    OPERATION_LOCK_ERROR="无法打开管理操作锁：$lock_file"
    return 1
  fi
  if ! flock -n 9; then
    release_operation_lock
    OPERATION_LOCK_ERROR="另一个管理操作正在进行，请等待完成后再试"
    return 1
  fi
}

prepare_core() {
  load_runtime_config
  need_cmd jq
  need_cmd flock
  need_cmd systemctl
  need_cmd column
  need_cmd ss
  need_cmd awk
  need_cmd ip
  check_config_vars
  acquire_operation_lock || die "$OPERATION_LOCK_ERROR"
  recover_pending_transaction
  init_state
}

recover_transaction_before_menu() {
  [[ -r "$CONF_FILE" ]] || return 0
  load_runtime_config
  [[ -e "$TRANSACTION_JOURNAL" ]] || return 0
  prepare_core
  release_operation_lock
}

release_operation_lock() {
  flock -u 9 2>/dev/null || true
  { exec 9>&-; } 2>/dev/null || true
}

prepare_menu_screen() {
  # 任何操作返回菜单后都先恢复空闲状态，避免直接返回路径遗留管理锁。
  release_operation_lock
  clear 2>/dev/null || true
  init_terminal_ui
}

pause_menu() {
  release_operation_lock
  printf '\n按回车返回菜单…'
  IFS= read -r _ || true
  printf '\n'
}

PROMPT_VALUE=""
VALIDATION_ERROR=""

read_menu_choice() {
  local prompt="$1" allowed="$2" default_value="${3:-}" help="$4" choice
  while true; do
    if ! read -r -p "$prompt" choice; then return 1; fi
    [[ -n "$choice" ]] || choice="$default_value"
    if [[ "$choice" =~ ^[A-Za-z0-9]+$ ]] && [[ ",${allowed}," == *",${choice},"* ]]; then
      PROMPT_VALUE="$choice"
      return 0
    fi
    printf '输入无效：%s，请重新输入。\n' "$help"
  done
}

validate_without_exit() {
  local output rc=0 tracing=false
  if [[ "$-" == *x* ]]; then
    tracing=true
    set +x
  fi
  output="$("$@" 2>&1)" || rc=$?
  [[ "$tracing" == true ]] && set -x
  if ((rc == 0)); then
    VALIDATION_ERROR=""
    return 0
  fi
  VALIDATION_ERROR="${output#错误：}"
  return 1
}

read_validated_value() {
  local prompt="$1" default_value="$2" cancel_value="$3" validator="$4" input value
  while true; do
    if ! read -r -p "$prompt" input; then return 1; fi
    if [[ -n "$cancel_value" && "$input" == "$cancel_value" ]]; then return 2; fi
    value="${input:-$default_value}"
    if validate_without_exit "$validator" "$value"; then
      PROMPT_VALUE="$value"
      return 0
    fi
    printf '输入无效：%s，请重新输入。\n' "$VALIDATION_ERROR"
  done
}

prompt_managed() {
  local protocol="$1" method="${2:-}" protocol_sni="${3:-}" name port limit anchor months
  prepare_core
  echo '输入 0 可取消添加并返回用户管理。'
  while true; do
    read -r -p '用户名：' name
    [[ "$name" != 0 ]] || { MENU_RETURNED=true; return 0; }
    if ! validate_without_exit validate_name "$name"; then printf '输入无效：%s，请重新输入。\n' "$VALIDATION_ERROR"; continue; fi
    if user_exists "$name"; then echo '用户名已经存在，请换一个名称。'; continue; fi
    if nfuse_account_exists "$name"; then echo '同名流量记录已经存在，请先运行「服务与配置检查」。'; continue; fi
    break
  done
  while true; do
    read -r -p '公网端口（20001-30000，留空随机生成）：' port
    [[ "$port" != 0 ]] || { MENU_RETURNED=true; return 0; }
    if [[ -z "$port" ]]; then port="$(find_available_user_port)"; echo "已随机选择端口：$port"; break; fi
    if ! validate_without_exit validate_port "$port"; then printf '输入无效：%s，请重新输入。\n' "$VALIDATION_ERROR"; continue; fi
    if port_in_state "$port" || port_is_listening "$port" || nfuse_port_exists "$port"; then echo '该端口已经被占用，请重新输入或直接回车随机选择。'; continue; fi
    break
  done
  if ! read_validated_value '每月可用流量（GiB）：' '' 0 validate_limit; then MENU_RETURNED=true; return 0; fi
  limit="$PROMPT_VALUE"
  if ! read_validated_value '每月流量重置日（1-28）：' '' 0 validate_anchor; then MENU_RETURNED=true; return 0; fi
  anchor="$PROMPT_VALUE"
  while true; do
    read -r -p '有效期（月数）：' months
    [[ "$months" != 0 ]] || { MENU_RETURNED=true; return 0; }
    [[ "$months" =~ ^[1-9][0-9]*$ ]] && break
    echo '输入无效：有效期月数必须是正整数，请重新输入。'
  done
  if [[ "$protocol" == anytls ]]; then cmd_add_anytls managed "$name" "$port" "$limit" "$anchor" "$months" "$protocol_sni"; else cmd_add managed "$name" "$port" "$limit" "$anchor" "$months" "$method"; fi
}

prompt_self() {
  local protocol="$1" method="${2:-}" protocol_sni="${3:-}" name port
  prepare_core
  echo '输入 0 可取消添加并返回用户管理。'
  while true; do
    read -r -p '用户名：' name
    [[ "$name" != 0 ]] || { MENU_RETURNED=true; return 0; }
    if ! validate_without_exit validate_name "$name"; then printf '输入无效：%s，请重新输入。\n' "$VALIDATION_ERROR"; continue; fi
    if user_exists "$name"; then echo '用户名已经存在，请换一个名称。'; continue; fi
    if nfuse_account_exists "$name"; then echo '同名流量记录已经存在，请先运行「服务与配置检查」。'; continue; fi
    break
  done
  while true; do
    read -r -p '公网端口（20001-30000，留空随机生成）：' port
    [[ "$port" != 0 ]] || { MENU_RETURNED=true; return 0; }
    if [[ -z "$port" ]]; then port="$(find_available_user_port)"; echo "已随机选择端口：$port"; break; fi
    if ! validate_without_exit validate_port "$port"; then printf '输入无效：%s，请重新输入。\n' "$VALIDATION_ERROR"; continue; fi
    if port_in_state "$port" || port_is_listening "$port" || nfuse_port_exists "$port"; then echo '该端口已经被占用，请重新输入或直接回车随机选择。'; continue; fi
    break
  done
  if [[ "$protocol" == anytls ]]; then cmd_add_anytls self "$name" "$port" "$protocol_sni"; else cmd_add self "$name" "$port" "$method"; fi
}

prompt_available_user_port() {
  local label="$1" excluded="${2:-}" port
  while true; do
    read -r -p "${label}（20001-30000，留空随机生成）：" port
    [[ "$port" != 0 ]] || return 1
    if [[ -z "$port" ]]; then
      while true; do
        port="$(find_available_user_port)" || return 1
        [[ "$port" != "$excluded" ]] && break
      done
      echo "已随机选择端口：$port"
    elif ! validate_without_exit validate_port "$port"; then
      printf '输入无效：%s，请重新输入。\n' "$VALIDATION_ERROR"
      continue
    fi
    if [[ "$port" == "$excluded" ]]; then
      echo '两个协议必须使用不同端口，请重新输入。'
      continue
    fi
    if port_in_state "$port" || port_is_listening "$port" || nfuse_port_exists "$port"; then
      echo '该端口已经被占用，请重新输入或直接回车随机选择。'
      continue
    fi
    PROMPT_VALUE="$port"
    return 0
  done
}

prompt_multi_account() {
  local mode="$1" method="$2" tls_sni="$3"
  local name ss_port anytls_port limit="" anchor="" months=""
  prepare_core
  echo '输入 0 可取消添加并返回用户管理。'
  while true; do
    read -r -p '用户名：' name
    [[ "$name" != 0 ]] || { MENU_RETURNED=true; return 0; }
    if ! validate_without_exit validate_name "$name"; then printf '输入无效：%s，请重新输入。\n' "$VALIDATION_ERROR"; continue; fi
    if user_exists "$name"; then echo '用户名已经存在，请换一个名称。'; continue; fi
    if nfuse_account_exists "$name"; then echo '同名流量记录已经存在，请先运行「服务与配置检查」。'; continue; fi
    break
  done
  if ! prompt_available_user_port 'SS2022 公网端口'; then MENU_RETURNED=true; return 0; fi
  ss_port="$PROMPT_VALUE"
  if ! prompt_available_user_port 'AnyTLS 公网端口' "$ss_port"; then MENU_RETURNED=true; return 0; fi
  anytls_port="$PROMPT_VALUE"
  if [[ "$mode" == managed ]]; then
    if ! read_validated_value '两个协议共享的每月流量（GiB）：' '' 0 validate_limit; then MENU_RETURNED=true; return 0; fi
    limit="$PROMPT_VALUE"
    if ! read_validated_value '每月流量重置日（1-28）：' '' 0 validate_anchor; then MENU_RETURNED=true; return 0; fi
    anchor="$PROMPT_VALUE"
    while true; do
      read -r -p '两个协议共享的有效期（月数）：' months
      [[ "$months" != 0 ]] || { MENU_RETURNED=true; return 0; }
      [[ "$months" =~ ^[1-9][0-9]*$ ]] && break
      echo '输入无效：有效期月数必须是正整数，请重新输入。'
    done
    cmd_add_multi managed "$name" "$ss_port" "$anytls_port" "$limit" "$anchor" "$months" "$method" "$tls_sni"
  else
    cmd_add_multi self "$name" "$ss_port" "$anytls_port" "$method" "$tls_sni"
  fi
}

prompt_add_node() {
  local protocol_choice account_choice protocol method="" protocol_sni="" tls_sni=""
  ensure_safe_ssh_for_singbox_restart || return 0
  load_runtime_config
  while true; do
    echo
    cat <<'EOF'
选择连接协议：
  1. SS2022
  2. AnyTLS
  3. 同时启用两种协议（共享流量、有效期和状态）
  0. 返回用户管理
EOF
    read_menu_choice '请选择协议：' '0,1,2,3' '' '请输入 1、2、3 或 0' || return 1
    protocol_choice="$PROMPT_VALUE"
    case "$protocol_choice" in
      1) protocol=ss2022;;
      2) protocol=anytls;;
      3) protocol=multi;;
      0) MENU_RETURNED=true; return 0;;
    esac

    if [[ "$protocol" == ss2022 || "$protocol" == multi ]]; then
      echo
      cat <<'EOF'
选择 SS2022 加密方式：
  1. 2022-blake3-aes-128-gcm（默认）
  2. 2022-blake3-aes-256-gcm
  0. 返回协议选择
EOF
      read_menu_choice '请选择加密方式 [1]：' '0,1,2' 1 '请输入 1、2 或 0' || return 1
      method="$PROMPT_VALUE"
      [[ "$method" != 0 ]] || continue
      case "$method" in 1) method=2022-blake3-aes-128-gcm;; 2) method=2022-blake3-aes-256-gcm;; esac
    fi
    if [[ "$protocol" == anytls || "$protocol" == multi ]]; then
      if ! read_validated_value "AnyTLS SNI（留空使用全局默认 ${ANYTLS_SNI}；输入 0 返回协议选择）：" "$ANYTLS_SNI" 0 validate_shadowtls_sni; then continue; fi
      tls_sni="$PROMPT_VALUE"
      protocol_sni="$tls_sni"
    fi

    echo
    cat <<'EOF'
选择使用方式：
  1. 流量计费用户（默认；统计流量，可设置月流量和有效期）
  2. 自用用户（不限流量和有效期，仅统计累计用量）
  0. 返回协议选择
EOF
    read_menu_choice '请选择使用方式 [1]：' '0,1,2' 1 '请输入 1、2 或 0' || return 1
    account_choice="$PROMPT_VALUE"
    case "$account_choice" in
      1) if [[ "$protocol" == multi ]]; then prompt_multi_account managed "$method" "$tls_sni"; else prompt_managed "$protocol" "$method" "$protocol_sni"; fi; return 0;;
      2) if [[ "$protocol" == multi ]]; then prompt_multi_account self "$method" "$tls_sni"; else prompt_self "$protocol" "$method" "$protocol_sni"; fi; return 0;;
      0) continue;;
    esac
  done
}
load_standard_user_rows() {
  local desired="${1:-all}" line
  USER_ROWS=()
  while IFS= read -r line; do USER_ROWS[${#USER_ROWS[@]}]="$line"; done < <(jq -r --arg desired "$desired" '
    .users[] | select($desired == "all" or .status == $desired) |
    [.name,
     ([if (.endpoints | type) == "array" then .endpoints[].port else .port end | tostring] | join(" / ")),
     ([if (.endpoints | type) == "array" then .endpoints[]
       else {protocol:(.protocol // "ss2022"),transport:(.transport // "shadowtls")} end |
       if .protocol == "anytls" then "AnyTLS"
       elif .transport == "shadowtls" then "SS2022 + ShadowTLS（旧版）"
       else "SS2022" end] | join(" + ")),
     (if .status == "active" then "启用" elif .status == "disabled" then "停用" else .status end)] |
    @tsv
  ' "$STATE_FILE" | sort -V)
}

print_standard_user_rows() {
  local i name port protocol status
  for i in "${!USER_ROWS[@]}"; do
    IFS=$'\t' read -r name port protocol status <<<"${USER_ROWS[$i]}"
    printf '  %d. %s｜%s｜端口 %s｜%s\n' "$((i + 1))" "$name" "$protocol" "$port" "$status"
  done
}

prompt_manage_user_protocols() {
  local row name ports protocol_label status user count port method="" sni answer selected action kind label
  local -a action_types=() action_kinds=() action_labels=()
  prepare_core
  load_standard_user_rows
  if ((${#USER_ROWS[@]} == 0)); then echo '暂无可管理用户。'; return 0; fi
  echo
  echo '已有用户（按用户名排序）：'
  print_standard_user_rows
  echo '  0. 返回用户管理'
  if ! read_numbered_index '请选择要管理协议的用户编号：' "${#USER_ROWS[@]}"; then MENU_RETURNED=true; return 0; fi
  row="${USER_ROWS[$SELECTED_INDEX]}"
  IFS=$'\t' read -r name ports protocol_label status <<<"$row"
  : "$ports"
  user="$(get_user_json "$name")" || return 1
  user="$(normalize_user_endpoints_json "$user")" || return 1
  count="$(jq '.endpoints | length' <<<"$user")" || return 1
  if ! jq -e 'any(.endpoints[]; .protocol == "ss2022" and .transport == "direct")' <<<"$user" >/dev/null; then
    action_types+=(add); action_kinds+=(ss2022-direct); action_labels+=('添加原生 SS2022')
  fi
  if ! jq -e 'any(.endpoints[]; .protocol == "anytls")' <<<"$user" >/dev/null; then
    action_types+=(add); action_kinds+=(anytls); action_labels+=('添加 AnyTLS')
  fi
  if ((count > 1)); then
    while IFS=$'\t' read -r kind label; do
      [[ -n "$kind" ]] || continue
      action_types+=(remove); action_kinds+=("$kind"); action_labels+=("移除 ${label}")
    done < <(jq -r '.endpoints[] |
      if .protocol == "anytls" then ["anytls","AnyTLS"]
      elif .transport == "direct" then ["ss2022-direct","原生 SS2022"]
      else ["ss2022-shadowtls","SS2022 + ShadowTLS（旧版）"] end | @tsv' <<<"$user")
  fi

  printf '\n用户 %s 当前连接入口：\n' "$name"
  jq -r '.endpoints[] |
    "  - " + (if .protocol == "anytls" then "AnyTLS"
      elif .transport == "direct" then "原生 SS2022"
      else "SS2022 + ShadowTLS（旧版）" end) + "｜端口 " + (.port | tostring)' <<<"$user"
  echo
  for selected in "${!action_labels[@]}"; do
    printf '  %d. %s\n' "$((selected + 1))" "${action_labels[$selected]}"
  done
  echo '  0. 返回用户管理'
  if ! read_numbered_index '请选择操作：' "${#action_labels[@]}"; then MENU_RETURNED=true; return 0; fi
  selected="$SELECTED_INDEX"
  action="${action_types[$selected]}"
  kind="${action_kinds[$selected]}"
  label="$(endpoint_kind_label "$kind")" || return 1

  if [[ "$action" == add ]]; then
    read -r -p "确认添加 ${label}，并共享现有流量、有效期和启停状态？[y/N]：" answer
    [[ "$answer" =~ ^[Yy]$ ]] || { echo '已取消。'; return 0; }
    if ! prompt_available_user_port '新协议公网端口'; then MENU_RETURNED=true; return 0; fi
    port="$PROMPT_VALUE"
    if [[ "$kind" == ss2022-direct ]]; then
      cat <<'EOF'
选择 SS2022 加密方式：
  1. 2022-blake3-aes-128-gcm（默认）
  2. 2022-blake3-aes-256-gcm
  0. 取消
EOF
      read_menu_choice '请选择加密方式 [1]：' '0,1,2' 1 '请输入 1、2 或 0' || return 1
      [[ "$PROMPT_VALUE" != 0 ]] || { MENU_RETURNED=true; return 0; }
      [[ "$PROMPT_VALUE" == 1 ]] && method=2022-blake3-aes-128-gcm || method=2022-blake3-aes-256-gcm
      sni=""
    else
      if ! read_validated_value "AnyTLS SNI（留空使用 ${ANYTLS_SNI}；输入 0 取消）：" "$ANYTLS_SNI" 0 validate_shadowtls_sni; then MENU_RETURNED=true; return 0; fi
      sni="$PROMPT_VALUE"
    fi
    cmd_add_user_endpoint "$name" "$kind" "$port" "$method" "$sni"
    return 0
  fi

  read -r -p "确认移除 ${label}？客户端中的对应连接将立即失效，但共享账户与用量保持不变。[y/N]：" answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo '已取消。'; return 0; }
  cmd_remove_user_endpoint "$name" "$kind"
}

read_numbered_index() {
  local prompt="$1" maximum="$2" choice
  while true; do
    if ! read -r -p "$prompt" choice; then return 1; fi
    if [[ ! "$choice" =~ ^[0-9]+$ ]]; then echo '输入无效：请输入列表前面的数字编号。'; continue; fi
    if ((choice == 0)); then return 1; fi
    if ((choice < 1 || choice > maximum)); then echo '输入无效：该编号不在当前列表中，请重新选择。'; continue; fi
    SELECTED_INDEX=$((choice - 1))
    return 0
  done
}

prompt_user_status_action() {
  local action="$1" desired="$2" title="$3" row name port protocol status
  prepare_core
  load_standard_user_rows "$desired"
  if ((${#USER_ROWS[@]} == 0)); then
    printf '没有可%s的用户。\n' "$title"
    return 0
  fi

  printf '\n%s用户（按用户名排序）：\n' "$title"
  print_standard_user_rows
  echo "  0. 返回用户管理"
  if ! read_numbered_index "请选择要${title}的用户编号：" "${#USER_ROWS[@]}"; then
    MENU_RETURNED=true
    return 0
  fi

  row="${USER_ROWS[$SELECTED_INDEX]}"
  IFS=$'\t' read -r name port protocol status <<<"$row"
  "$action" "$name"
}

prompt_remove_user() {
  local row name port protocol status answer split_count
  prepare_core
  load_standard_user_rows
  if ((${#USER_ROWS[@]} == 0)); then
    echo "暂无可删除用户。"
    return 0
  fi

  echo
  echo "已有用户（按用户名排序）："
  print_standard_user_rows
  echo "  0. 返回用户管理"
  if ! read_numbered_index '请选择要删除的用户编号：' "${#USER_ROWS[@]}"; then MENU_RETURNED=true; return 0; fi

  row="${USER_ROWS[$SELECTED_INDEX]}"
  IFS=$'\t' read -r name port protocol status <<<"$row"
  printf '即将删除：%s（%s，端口 %s，当前%s）\n' "$name" "$protocol" "$port" "$status"
  split_count="$(jq --arg name "$name" '[.splits[]? | select(.scope == "user" and .user == $name)] | length' "$STATE_FILE")"
  if ((split_count>0)); then printf '该用户关联的 %d 条专属分流将一并删除。\n' "$split_count"; fi
  read -r -p '删除后只能通过备份找回，确认删除？[y/N]：' answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo "已取消删除。"; return 0; }
  cmd_remove "$name"
}

prompt_edit_user() {
  local row name port protocol_label status user endpoint endpoint_count protocol kind transport="" metered old_sni old_method old_anchor old_expiry endpoint_row
  local new_port new_sni new_method new_anchor new_expiry input choice answer changed=false
  local -a endpoint_rows=()
  prepare_core
  load_standard_user_rows
  if ((${#USER_ROWS[@]} == 0)); then
    echo "暂无可编辑用户。"
    return 0
  fi

  echo
  echo "已有用户（按用户名排序）："
  print_standard_user_rows
  echo "  0. 返回用户管理"
  if ! read_numbered_index '请选择要编辑的用户编号：' "${#USER_ROWS[@]}"; then
    MENU_RETURNED=true
    return 0
  fi
  row="${USER_ROWS[$SELECTED_INDEX]}"
  IFS=$'\t' read -r name port protocol_label status <<<"$row"
  user="$(get_user_json "$name")" || return 1
  user="$(normalize_user_endpoints_json "$user")" || return 1
  endpoint_count="$(jq 'if (.endpoints | type) == "array" then .endpoints | length else 1 end' <<<"$user")" || return 1
  while IFS= read -r endpoint_row; do endpoint_rows+=("$endpoint_row"); done < <(jq -r '.endpoints[] |
    if .protocol == "anytls" then ["anytls","AnyTLS"]
    elif .transport == "direct" then ["ss2022-direct","原生 SS2022"]
    else ["ss2022-shadowtls","SS2022 + ShadowTLS（旧版）"] end | @tsv' <<<"$user")
  if ((endpoint_count > 1)); then
    echo
    echo '请选择要编辑的连接入口：'
    for choice in "${!endpoint_rows[@]}"; do
      IFS=$'\t' read -r kind protocol_label <<<"${endpoint_rows[$choice]}"
      printf '  %d. %s\n' "$((choice + 1))" "$protocol_label"
    done
    echo '  0. 取消编辑'
    if ! read_numbered_index '请选择：' "${#endpoint_rows[@]}"; then MENU_RETURNED=true; return 0; fi
    IFS=$'\t' read -r kind protocol_label <<<"${endpoint_rows[$SELECTED_INDEX]}"
  else
    IFS=$'\t' read -r kind protocol_label <<<"${endpoint_rows[0]}"
  fi
  endpoint="$(jq -ec --arg kind "$kind" '
    def endpoint_kind:
      if .protocol == "anytls" then "anytls"
      elif .protocol == "ss2022" and .transport == "direct" then "ss2022-direct"
      elif .protocol == "ss2022" and .transport == "shadowtls" then "ss2022-shadowtls"
      else null end;
    .endpoints[] | select(endpoint_kind == $kind)
  ' <<<"$user")" || return 1
  protocol="$(jq -er '.protocol' <<<"$endpoint")" || return 1
  port="$(jq -r '.port' <<<"$endpoint")" || return 1
  metered="$(jq -r '.metered // (.limit_gib != null)' <<<"$user")"
  new_port="$port"

  printf '\n编辑用户：%s（%s，当前%s）\n' "$name" "$protocol_label" "$status"
  printf '输入 0 可随时取消本次编辑。\n'
  while true; do
    read -r -p "公网端口（当前 ${port}；留空保持，r 随机生成）：" input
    case "$input" in
      0) MENU_RETURNED=true; return 0;;
      "") new_port="$port"; break;;
      r|R) new_port="$(find_available_user_port)"; printf '已随机选择端口：%s\n' "$new_port"; break;;
      *)
        if ! validate_without_exit validate_port "$input"; then printf '输入无效：%s，请重新输入。\n' "$VALIDATION_ERROR"; continue; fi
        if [[ "$input" != "$port" ]] && { port_in_state "$input" || port_is_listening "$input" || nfuse_port_exists "$input"; }; then
          echo '该端口已经被占用，请重新输入。'
          continue
        fi
        new_port="$input"; break;;
    esac
  done

  if [[ "$protocol" == anytls ]]; then
    old_sni="$(jq -r '.tls_sni' <<<"$endpoint")"
    new_method=""
    if ! read_validated_value "AnyTLS SNI（当前 ${old_sni}；留空保持；输入 0 取消）：" "$old_sni" 0 validate_shadowtls_sni; then MENU_RETURNED=true; return 0; fi
    new_sni="$PROMPT_VALUE"
    old_method=""
  else
    transport="$(jq -r '.transport // "shadowtls"' <<<"$endpoint")"
    if [[ "$transport" == shadowtls ]]; then
      protocol_label='SS2022 + ShadowTLS（旧版）'
      old_sni="$(jq -r '.shadowtls_sni' <<<"$endpoint")"
    else
      protocol_label=SS2022
      old_sni=""
    fi
    old_method="$(jq -r '.method' <<<"$endpoint")"
    cat <<EOF
SS2022 加密方式（当前 ${old_method}）：
  1. 2022-blake3-aes-128-gcm
  2. 2022-blake3-aes-256-gcm
  直接回车保持当前方式
  0. 取消编辑
EOF
    read_menu_choice '请选择加密方式：' '0,1,2,keep' keep '请输入 1、2、0 或直接回车' || return 1
    choice="$PROMPT_VALUE"
    case "$choice" in
      keep) new_method="$old_method";;
      1) new_method=2022-blake3-aes-128-gcm;;
      2) new_method=2022-blake3-aes-256-gcm;;
      0) MENU_RETURNED=true; return 0;;
    esac
    if [[ "$transport" == shadowtls ]]; then
      if ! read_validated_value "ShadowTLS SNI（当前 ${old_sni}；留空保持；输入 0 取消）：" "$old_sni" 0 validate_shadowtls_sni; then MENU_RETURNED=true; return 0; fi
      new_sni="$PROMPT_VALUE"
    else
      new_sni=""
    fi
  fi

  if [[ "$metered" == true ]]; then
    old_anchor="$(jq -r '.billing_anchor' <<<"$user")"
    old_expiry="$(jq -r '.expires_at' <<<"$user")"
    if ! read_validated_value "账单日（当前 ${old_anchor}；留空保持；输入 0 取消）：" "$old_anchor" 0 validate_anchor; then MENU_RETURNED=true; return 0; fi
    new_anchor="$PROMPT_VALUE"
    while true; do
      read -r -p "重新设置有效期（月，当前到期 ${old_expiry/T/ }；留空保持；输入 0 取消）：" input
      [[ "$input" != 0 ]] || { MENU_RETURNED=true; return 0; }
      if [[ -z "$input" ]]; then new_expiry="$old_expiry"; break; fi
      if [[ "$input" =~ ^[1-9][0-9]*$ ]]; then new_expiry="$(date -d "+${input} month" '+%Y-%m-%dT%H:%M:%S%z')"; break; fi
      echo '输入无效：有效期月数必须是正整数，请重新输入。'
    done
  else
    old_anchor=""; new_anchor=""
    old_expiry=""; new_expiry=""
  fi

  echo
  echo "变更预览："
  if [[ "$new_port" != "$port" ]]; then printf '  端口：%s → %s\n' "$port" "$new_port"; changed=true; fi
  if [[ "$new_sni" != "$old_sni" ]]; then printf '  SNI：%s → %s\n' "$old_sni" "$new_sni"; changed=true; fi
  if [[ "$protocol" == ss2022 && "$new_method" != "$old_method" ]]; then
    printf '  加密方式：%s → %s\n' "$old_method" "$new_method"
    echo '  连接密码：将重新生成；用户需要重新导入配置才能连接'
    changed=true
  fi
  if [[ "$metered" == true && "$new_anchor" != "$old_anchor" ]]; then printf '  账单日：%s → %s\n' "$old_anchor" "$new_anchor"; changed=true; fi
  if [[ "$metered" == true && "$new_expiry" != "$old_expiry" ]]; then printf '  到期时间：%s → %s\n' "${old_expiry/T/ }" "${new_expiry/T/ }"; changed=true; fi
  if [[ "$changed" != true ]]; then
    echo '  没有变化。'
    return 0
  fi
  if [[ "$status" == 停用 ]]; then echo '  用户保持停用；本次编辑不会自动启用。'; fi
  read -r -p '确认保存以上修改？[y/N]：' answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo '已取消编辑。'; return 0; }
  cmd_edit_user "$name" "$new_port" "$new_sni" "$new_method" "$new_anchor" "$new_expiry" "$kind"
}

prompt_renew_user() {
  local -a rows
  local line i name expires status choice months expires_epoch new_expiry answer
  prepare_core
  rows=()
  while IFS= read -r line; do rows[${#rows[@]}]="$line"; done < <(jq -r '
    .users[] | select(.expires_at != null) |
    [.name,
     .expires_at,
     (if .status == "active" then "启用" elif .status == "disabled" then "停用" else .status end)] |
    @tsv
  ' "$STATE_FILE" | sort -V)
  if ((${#rows[@]} == 0)); then echo "暂无可调整有效期的用户。"; return 0; fi
  echo
  echo "有有效期的用户（按用户名排序）："
  for i in "${!rows[@]}"; do
    IFS=$'\t' read -r name expires status <<<"${rows[$i]}"
    printf '  %d. %s｜到期 %s｜%s\n' "$((i + 1))" "$name" "${expires/T/ }" "$status"
  done
  echo "  0. 返回用户管理"
  if ! read_numbered_index '请选择要调整有效期的用户编号：' "${#rows[@]}"; then MENU_RETURNED=true; return 0; fi
  IFS=$'\t' read -r name expires status <<<"${rows[$SELECTED_INDEX]}"
  while true; do
    read -r -p '请输入调整月数（正数延长，负数提前，输入 0 返回）：' months
    [[ "$months" != 0 ]] || { MENU_RETURNED=true; return 0; }
    [[ "$months" =~ ^-?[1-9][0-9]*$ ]] && break
    echo '输入无效：调整月数必须是非零整数，请重新输入。'
  done
  if [[ "$months" == -* ]]; then
    expires_epoch="$(date -d "$expires" +%s)" || {
      echo "错误：用户有效期格式无效，不能调整：$name" >&2
      return 1
    }
    new_expiry="$(calculate_renewal_expiry "$expires_epoch" "$months")" || {
      echo "错误：无法按 ${months} 个月计算用户的新到期时间，有效期调整未执行：$name" >&2
      return 1
    }
    echo
    echo '提前到期预览：'
    printf '  用户：%s｜当前状态：%s\n' "$name" "$status"
    printf '  当前到期：%s\n' "${expires/T/ }"
    printf '  调整后：%s\n' "${new_expiry/T/ }"
    read -r -p '确认提前该用户的到期时间？[y/N]：' answer
    [[ "$answer" =~ ^[Yy]$ ]] || { echo '已取消有效期调整。'; return 0; }
  fi
  cmd_renew "$name" "$months"
}
prompt_adjust_traffic() {
  local -a rows
  local usage_json line i name port status remaining choice delta mode_choice mode
  prepare_core
  usage_json="$(nfuse list --json)"
  rows=()
  while IFS= read -r line; do rows[${#rows[@]}]="$line"; done < <(jq -r --argjson nfuse "$usage_json" '
    .users[] | select(.metered // (.limit_gib != null)) as $user |
    ($nfuse | map(select(.name == $user.name)) | first) as $meter |
    [$user.name,
     ([$user.endpoints[].port | tostring] | join(" / ")),
     (if $user.status == "active" then "启用" elif $user.status == "disabled" then "停用" else $user.status end),
     (if $meter == null then "流量记录缺失" else ((((([$meter.limit_bytes - $meter.used_bytes, 0] | max) / 1073741824) * 100 | round) / 100 | tostring) + " GiB") end)] |
    @tsv
  ' "$STATE_FILE" | sort -V)
  if ((${#rows[@]} == 0)); then echo "暂无可调整流量的用户。"; return 0; fi
  while true; do
    cat <<'EOF'
流量调整方式：
  1. 只增加本期流量（月流量不变）
  2. 修改每月流量（以后每月生效）
  0. 返回用户管理
EOF
    read_menu_choice '请选择调整方式：' '0,1,2' '' '请输入 1、2 或 0' || return 1
    mode_choice="$PROMPT_VALUE"
    case "$mode_choice" in 1) mode=temporary;; 2) mode=permanent;; 0) MENU_RETURNED=true; return 0;; esac
    echo
    echo "可调整流量的用户（按用户名排序）："
    for i in "${!rows[@]}"; do
      IFS=$'\t' read -r name port status remaining <<<"${rows[$i]}"
      printf '  %d. %s｜端口 %s｜%s｜剩余 %s\n' "$((i + 1))" "$name" "$port" "$status" "$remaining"
    done
    echo "  0. 返回调整方式"
    if ! read_numbered_index '请选择要调整流量的用户编号：' "${#rows[@]}"; then continue; fi
    IFS=$'\t' read -r name port status remaining <<<"${rows[$SELECTED_INDEX]}"
    if [[ "$mode" == temporary ]]; then echo "临时增加：只增加本期剩余流量，下个月仍恢复原来的月流量。"
    else echo "永久调整：正数增加、负数减少；以后每个月都使用新的流量上限。"
    fi
    while true; do
      read -r -p '请输入调整值（GiB，输入 0 返回用户列表）：' delta
      [[ "$delta" != 0 ]] || break
      if [[ ! "$delta" =~ ^-?([0-9]+)(\.[0-9]+)?$ ]]; then echo '输入无效：请输入有效的 GiB 数值。'; continue; fi
      if [[ "$mode" == temporary ]] && ! awk -v value="$delta" 'BEGIN { exit !(value > 0) }'; then echo '输入无效：临时调整只能输入正数。'; continue; fi
      if [[ "$mode" == permanent ]] && ! awk -v value="$delta" 'BEGIN { exit !(value != 0) }'; then echo '输入无效：永久调整不能输入 0。'; continue; fi
      break
    done
    [[ "$delta" != 0 ]] || continue
    cmd_adjust_traffic "$name" "$delta" "$mode"
    return 0
  done
}
prompt_export() {
  local name format_choice format=all port protocol status
  prepare_core
  load_standard_user_rows
  if ((${#USER_ROWS[@]} == 0)); then echo "暂无可导出用户。"; return 0; fi

  while true; do
    cat <<'EOF'
导出格式：
  1. 全部
  2. Surge
  3. Shadowrocket
  0. 返回用户管理
EOF
    read_menu_choice '请选择格式 [1]：' '0,1,2,3' 1 '请输入 1、2、3 或 0' || return 1
    format_choice="$PROMPT_VALUE"
    case "$format_choice" in 1) format=all;; 2) format=surge;; 3) format=shadowrocket;; 0) MENU_RETURNED=true; return 0;; esac
    echo
    echo "已有用户（按用户名排序）："
    print_standard_user_rows
    echo "  0. 返回格式选择"
    if ! read_numbered_index '请选择要导出的用户编号：' "${#USER_ROWS[@]}"; then continue; fi
    IFS=$'\t' read -r name port protocol status <<<"${USER_ROWS[$SELECTED_INDEX]}"
    if [[ "$format" == all || "$format" == shadowrocket ]]; then
      ensure_shadowrocket_qr_support || true
    fi
    cmd_export "$name" "$format"
    return 0
  done
}

show_service_status() {
  local service state description
  printf '\n%-24s %-12s %s\n' '项目' '状态' '说明'
  printf '%-24s %-12s %s\n' '------------------------' '------------' '------------------------------'
  while IFS='|' read -r service description; do
    state="$(systemctl is-active "$service" 2>/dev/null || true)"
    case "$state" in
      active) state='运行中';;
      inactive) state='未运行';;
      failed) state='启动失败';;
      activating) state='启动中';;
      deactivating) state='停止中';;
      *) state="未知（${state:-unknown}）";;
    esac
    printf '%-24s %-12s %s\n' "$service" "$state" "$description"
  done <<'EOF'
sing-box.service|负责用户连接和分流
nfuse.service|负责流量统计和用量限制
sb-user-expiry.timer|负责自动停用到期用户
EOF
  printf '\n流量统计通信：%s\n' "$([[ -S /run/nfuse.sock ]] && echo '正常' || echo '未就绪，请检查 Nfuse 服务')"
  printf '管理脚本：%s\n' "$([[ -x /usr/local/sbin/sb-user-manager ]] && echo '已安装' || echo '未安装')"
}

audit_consistency() {
  local config_json nfuse_json user_rows expiry_rows split_rows split name status protocol transport port metered has_legacy expected expected_tier tag split_status rule_tag out_tag scope scope_user scope_tags expires
  local preset_link_rows preset_kind preset_reason managed_tags legacy_cleanup legacy_count
  AUDIT_ISSUES=0
  AUDIT_REPAIRABLE=0
  config_json="$("$SINGBOX_BIN" format -c "$SINGBOX_CONFIG")" || return 1
  nfuse_json="$(nfuse list --json)" || return 1
  jq -e 'type == "object"' <<<"$config_json" >/dev/null || return 1
  jq -e 'type == "array"' <<<"$nfuse_json" >/dev/null || return 1
  user_rows="$(jq -r '
    .users[] | . as $user |
    (if ($user.endpoints | type) == "array" then $user.endpoints[]
     else {protocol:($user.protocol // "ss2022"),transport:($user.transport // "shadowtls"),port:$user.port} end) |
    [$user.name,$user.status,.protocol,(.transport // "-"),(.port|tostring),
     (($user.metered // ($user.limit_gib != null))|tostring),
     (any($user.endpoints[]?; .protocol == "ss2022" and .transport == "shadowtls") | tostring)] | @tsv
  ' "$STATE_FILE")" || return 1
  expiry_rows="$(jq -r '.users[] | select(.expires_at != null) | [.name, (.expires_at | tostring)] | @tsv' "$STATE_FILE")" || return 1
  split_rows="$(jq -c '.splits[]?' "$STATE_FILE")" || return 1
  printf '\n服务与配置检查结果\n\n'
  while IFS=$'\t' read -r name expires; do
    [[ -n "$name" ]] || continue
    if ! parse_expiry_epoch "$expires" >/dev/null; then
      printf '  [需要处理] 用户 %s 的有效期格式无效（%s）\n' "$name" "$expires"
      ((AUDIT_ISSUES+=1))
    fi
  done <<<"$expiry_rows"
  while IFS=$'\t' read -r name status protocol transport port metered has_legacy; do
    [[ -n "$name" ]] || continue
    if [[ "$protocol" == anytls ]]; then expected="anytls-$name"
    elif [[ "$transport" == shadowtls ]]; then expected="st-$name ss-$name ss-udp-$name"
    elif [[ "$has_legacy" == true ]]; then expected="ss-direct-$name"
    else expected="ss-$name"
    fi
    for tag in $expected; do
      if [[ "$status" == active ]] && ! jq -e --arg tag "$tag" '.inbounds[]? | select(.tag == $tag)' <<<"$config_json" >/dev/null; then
        printf '  [可自动修复] 用户 %s 缺少连接配置（%s）\n' "$name" "$tag"
        ((AUDIT_ISSUES+=1)); ((AUDIT_REPAIRABLE+=1))
      elif [[ "$status" == disabled ]] && jq -e --arg tag "$tag" '.inbounds[]? | select(.tag == $tag)' <<<"$config_json" >/dev/null; then
        printf '  [可自动修复] 已停用用户 %s 仍保留连接配置（%s）\n' "$name" "$tag"
        ((AUDIT_ISSUES+=1)); ((AUDIT_REPAIRABLE+=1))
      fi
    done
    if [[ "$protocol" == ss2022 && "$transport" == shadowtls && "$status" == active ]] &&
       jq -e --arg tag "ss-udp-$name" '.inbounds[]? | select(.tag == $tag)' <<<"$config_json" >/dev/null &&
       ! jq -e --arg tag "ss-udp-$name" --argjson port "$port" '
         .inbounds[]? | select(.tag == $tag and .type == "shadowsocks" and .network == "udp" and .listen_port == $port)
       ' <<<"$config_json" >/dev/null; then
      printf '  [可自动修复] 用户 %s 的 UDP 连接配置不正确\n' "$name"
      ((AUDIT_ISSUES+=1)); ((AUDIT_REPAIRABLE+=1))
    fi
    if [[ "$protocol" == ss2022 && "$transport" == direct && "$status" == active ]] &&
       ! jq -e --arg tag "$expected" --argjson port "$port" '
         .inbounds[]? | select(.tag == $tag and .type == "shadowsocks" and .listen_port == $port and ((.network // "") == ""))
       ' <<<"$config_json" >/dev/null; then
      printf '  [可自动修复] 用户 %s 的原生 SS2022 连接配置不正确\n' "$name"
      ((AUDIT_ISSUES+=1)); ((AUDIT_REPAIRABLE+=1))
    fi
    if [[ "$protocol" == ss2022 && "$transport" == direct && "$has_legacy" != true ]] &&
       jq -e --arg st "st-$name" --arg udp "ss-udp-$name" '
         any(.inbounds[]?; .tag == $st or .tag == $udp)
       ' <<<"$config_json" >/dev/null; then
      printf '  [可自动修复] 用户 %s 的原生 SS2022 仍有旧版 ShadowTLS 连接残留\n' "$name"
      ((AUDIT_ISSUES+=1)); ((AUDIT_REPAIRABLE+=1))
    fi
    expected_tier="$([[ "$metered" == true ]] && echo a || echo c)"
    if ! jq -e --arg name "$name" '.[] | select(.name == $name)' <<<"$nfuse_json" >/dev/null; then
      printf '  [可自动修复] 用户 %s 缺少流量统计记录\n' "$name"
      ((AUDIT_ISSUES+=1)); ((AUDIT_REPAIRABLE+=1))
    elif ! jq -e --arg name "$name" --arg tier "$expected_tier" '.[] | select(.name == $name and .tier == $tier)' <<<"$nfuse_json" >/dev/null; then
      printf '  [需要处理] 用户 %s 的流量记录类型不正确（应为 %s）\n' "$name" "$([[ "$metered" == true ]] && echo 计量 || echo 不限额统计)"
      ((AUDIT_ISSUES+=1))
    elif ! jq -e --arg name "$name" --argjson port "$port" '.[] | select(.name == $name) | .ports[]? | select(.start <= $port and .end >= $port)' <<<"$nfuse_json" >/dev/null; then
      printf '  [可自动修复] 用户 %s 的端口 %s 尚未接入流量统计\n' "$name" "$port"
      ((AUDIT_ISSUES+=1)); ((AUDIT_REPAIRABLE+=1))
    fi
  done <<<"$user_rows"

  preset_link_rows="$(jq -r '
    .outbound_presets as $outbounds | .rule_presets as $rules |
    .splits[] as $split |
    (if (($split.outbound_preset // "") != "") then
       (first($outbounds[] | select(.name == $split.outbound_preset)) // null) as $preset |
       if $preset == null then [$split.name,"出口","预置已不存在"]
       elif $split.upstream != $preset.upstream then [$split.name,"出口","保存内容未同步"] else empty end
     else empty end),
    (if (($split.rule_preset // "") != "") then
       (first($rules[] | select(.name == $split.rule_preset)) // null) as $preset |
       if $preset == null then [$split.name,"规则","预置已不存在"]
       elif $split.url != $preset.url then [$split.name,"规则","保存内容未同步"] else empty end
     else empty end) | @tsv
  ' "$STATE_FILE")" || return 1
  while IFS=$'\t' read -r name preset_kind preset_reason; do
    [[ -n "$name" ]] || continue
    printf '  [可自动修复] 分流 %s 的预置%s关联异常（%s）\n' "$name" "$preset_kind" "$preset_reason"
    ((AUDIT_ISSUES+=1)); ((AUDIT_REPAIRABLE+=1))
  done <<<"$preset_link_rows"

  while IFS= read -r split; do
    [[ -n "$split" ]] || continue
    name="$(jq -r '.name' <<<"$split")" || return 1
    split_status="$(jq -r '.status' <<<"$split")" || return 1
    scope="$(jq -r '.scope' <<<"$split")" || return 1
    scope_user="$(jq -r 'if .scope == "user" then (.user // "") else "" end' <<<"$split")" || return 1
    rule_tag="$(split_runtime_rule_tag_from_json "$split")" || return 1
    out_tag="$(split_runtime_out_tag_from_json "$split")" || return 1
    if [[ "$split_status" == active ]]; then
      if ! jq -e --arg tag "$rule_tag" '.route.rule_set[]? | select(.tag == $tag)' <<<"$config_json" >/dev/null ||
         ! jq -e --arg out "$out_tag" '.outbounds[]? | select(.tag == $out)' <<<"$config_json" >/dev/null ||
         ! jq -e --arg rule "$rule_tag" --arg out "$out_tag" '.route.rules[]? | select(.rule_set == $rule and .outbound == $out)' <<<"$config_json" >/dev/null; then
        printf '  [可自动修复] 分流 %s 的规则或出口配置不完整\n' "$name"
        ((AUDIT_ISSUES+=1)); ((AUDIT_REPAIRABLE+=1))
      fi
      if [[ -n "$scope_user" ]] && ! user_exists "$scope_user"; then
        printf '  [需要处理] 分流 %s 指定的用户 %s 已不存在\n' "$name" "$scope_user"
        ((AUDIT_ISSUES+=1))
      elif [[ -n "$scope_user" ]]; then
        scope_tags="$(split_user_inbound_tags "$scope_user")" || return 1
        if ! jq -e --arg rule "$rule_tag" --arg out "$out_tag" --argjson expected "$scope_tags" '
          .route.rules[]? | select(.rule_set == $rule and .outbound == $out and
            ($expected - (.inbound // []) | length) == 0)
        ' <<<"$config_json" >/dev/null; then
          printf '  [可自动修复] 分流 %s 尚未覆盖用户 %s 的全部连接\n' "$name" "$scope_user"
          ((AUDIT_ISSUES+=1)); ((AUDIT_REPAIRABLE+=1))
        fi
      fi
    else
      if [[ "$scope" == all ]]; then
        if jq -e --arg rule "$rule_tag" --arg out "$out_tag" '.route.rules[]? | select(.rule_set == $rule and .outbound == $out and ((.inbound // []) | length == 0))' <<<"$config_json" >/dev/null; then
          printf '  [可自动修复] 已停用分流 %s 仍有连接规则生效\n' "$name"
          ((AUDIT_ISSUES+=1)); ((AUDIT_REPAIRABLE+=1))
        fi
      elif [[ -n "$scope_user" ]]; then
        scope_tags="$(split_user_inbound_tags "$scope_user")" || return 1
        if jq -e --arg rule "$rule_tag" --arg out "$out_tag" --argjson expected "$scope_tags" '
          .route.rules[]? | select(.rule_set == $rule and .outbound == $out and
            ([.inbound[]? as $tag | select($expected | index($tag) != null)] | length) > 0)
        ' <<<"$config_json" >/dev/null; then
          printf '  [可自动修复] 已停用分流 %s 仍有连接规则生效\n' "$name"
          ((AUDIT_ISSUES+=1)); ((AUDIT_REPAIRABLE+=1))
        fi
      fi
    fi
  done <<<"$split_rows"

  managed_tags="$(collect_managed_split_tags)" || return 1
  legacy_cleanup="$(collect_legacy_split_cleanup_plan_from_config "$config_json" "$managed_tags")" || return 1
  legacy_count="$(jq '.rule_tags | length' <<<"$legacy_cleanup")" || return 1
  if ((legacy_count > 0)); then
    printf '  [可自动修复] 检测到 %s 条与当前预置重复的旧版分流规则\n' "$legacy_count"
    ((AUDIT_ISSUES+=1)); ((AUDIT_REPAIRABLE+=1))
  fi

  if ((AUDIT_ISSUES==0)); then echo '  一切正常：用户、分流、连接配置和流量统计相互一致。'
  else printf '\n共发现 %d 个问题，其中 %d 个可以自动修复。\n' "$AUDIT_ISSUES" "$AUDIT_REPAIRABLE"
  fi
}

repair_consistency() {
  local environment_backup nfuse_json user_rows split_rows parsed user name status port metered fragment limit anchor expected_tier
  local split split_status scope scope_user url upstream out_tag rule_tag
  nfuse_json="$(nfuse list --json)" || return 1
  jq -e 'type == "array"' <<<"$nfuse_json" >/dev/null || return 1
  user_rows="$(jq -c '.users[]' "$STATE_FILE")" || return 1
  split_rows="$(jq -c '.splits[]?' "$STATE_FILE")" || return 1
  ensure_safe_ssh_for_singbox_restart || return 0
  create_environment_backup || return 1
  environment_backup="$ENV_BACKUP"
  start_managed_operation "repair-consistency" || return 1
  run_managed_step state_sync_linked_split_snapshots || return 1
  split_rows="$(jq -c '.splits[]?' "$STATE_FILE")" || return 1
  while IFS= read -r user; do
    [[ -n "$user" ]] || continue
    if ! parsed="$(jq -er '
      (.metered // (.limit_gib != null)) as $metered |
      select((.name|type)=="string" and (.name|length)>0) |
      select(.status=="active" or .status=="disabled") |
      select(if (.endpoints|type)=="array" then
        (.endpoints|length)>=1 and all(.endpoints[]; (.port|type)=="number" and .port==(.port|floor) and .port>=1 and .port<=65535)
        else (.port|type)=="number" and .port==(.port|floor) and .port>=1 and .port<=65535 end) |
      select(($metered|type)=="boolean") |
      select(($metered|not) or
        ((.limit_gib|type)=="number" and .limit_gib>0 and
         (.billing_anchor|type)=="number" and .billing_anchor==(.billing_anchor|floor))) |
      [.name,.status,($metered|tostring),
       (if $metered then (.limit_gib|tostring) else "" end),
       (if $metered then (.billing_anchor|tostring) else "" end)] | @tsv
    ' <<<"$user")"; then
      rollback_active_operation 1 || true
      return 1
    fi
    IFS=$'\t' read -r name status metered limit anchor <<<"$parsed"
    run_managed_step remove_user_inbounds "$name" || return 1
    if [[ "$status" == active ]]; then
      if ! fragment="$(make_user_inbounds_from_state "$user")"; then rollback_active_operation 1 || true; return 1; fi
      run_managed_step append_inbounds "$fragment" || return 1
    fi
    expected_tier="$([[ "$metered" == true ]] && echo a || echo c)"
    if ! jq -e --arg name "$name" '.[] | select(.name == $name)' <<<"$nfuse_json" >/dev/null; then
      if [[ "$metered" == true ]]; then
        run_managed_step nfuse add "$name" --tier a --limit "$limit" --anchor "$anchor" || return 1
      else
        run_managed_step nfuse add "$name" --tier c --limit 0 --anchor 1 || return 1
      fi
      nfuse_json="$(nfuse list --json)" || return 1
    elif ! jq -e --arg name "$name" --arg tier "$expected_tier" '.[] | select(.name == $name and .tier == $tier)' <<<"$nfuse_json" >/dev/null; then
      log "无法自动修改用户 ${name} 的流量记录类型，请先确认该同名记录是否可以删除"
      continue
    fi
    while IFS= read -r port; do
      [[ -n "$port" ]] || continue
      if ! jq -e --arg name "$name" --argjson port "$port" '.[] | select(.name == $name) | .ports[]? | select(.start <= $port and .end >= $port)' <<<"$nfuse_json" >/dev/null; then
        run_managed_step nfuse port add "$name" "$port" || return 1
        nfuse_json="$(nfuse list --json)" || return 1
      fi
    done < <(jq -r 'if (.endpoints | type) == "array" then .endpoints[].port else .port end' <<<"$user")
  done <<<"$user_rows"
  while IFS= read -r split; do
    [[ -n "$split" ]] || continue
    if ! jq -e '
      select((.name|type)=="string" and (.name|length)>0) |
      select(.status=="active" or .status=="disabled") |
      select(.scope=="all" or .scope=="user") |
      select((.url|type)=="string" and (.url|length)>0) |
      select((.upstream|type)=="object")
    ' <<<"$split" >/dev/null; then
      rollback_active_operation 1 || true
      return 1
    fi
    scope="$(jq -er '.scope' <<<"$split")" || { rollback_active_operation 1 || true; return 1; }
    scope_user="$(jq -er '.user // ""' <<<"$split")" || { rollback_active_operation 1 || true; return 1; }
    if [[ "$scope" == user ]] && ! user_exists "$scope_user"; then
      rollback_active_operation 1 || true
      return 1
    fi
  done <<<"$split_rows"
  run_managed_step rebuild_all_split_configs || return 1
  run_managed_step nfuse persist || return 1
  run_managed_step check_singbox_and_restart || return 1
  finish_managed_operation || return 1
  log "服务与配置已自动修复；修复前完整备份：$environment_backup"
}

prompt_consistency() {
  local answer
  prepare_core
  audit_consistency
  ((AUDIT_REPAIRABLE>0)) || return 0
  read -r -p '是否自动修复上方标记为「可自动修复」的问题？[y/N]：' answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo '已取消修复。'; return 0; }
  repair_consistency
  audit_consistency
}

load_diagnostic_runtime_config() {
  if [[ -r "$CONF_FILE" ]]; then
    load_runtime_config
    DIAGNOSTIC_CONFIG_READABLE=true
    return 0
  fi
  DIAGNOSTIC_CONFIG_READABLE=false
  SINGBOX_BIN=/usr/local/bin/sing-box
  SINGBOX_CONFIG=/etc/sing-box/config.json
  SINGBOX_SERVICE=sing-box
  NFUSE_BIN=/usr/local/bin/nfuse
  NFUSE_SOCKET=/run/nfuse.sock
  STATE_FILE=/etc/sing-box/managed-users.json
  LOCK_FILE=/run/lock/sb-user-manager.lock
  TRANSACTION_DIR=/var/lib/sb-user-manager/transactions
  TRANSACTION_JOURNAL="$TRANSACTION_DIR/active.json"
  PUBLIC_SERVER_OVERRIDE=""
}

declare -a DIAGNOSTIC_REDACT_VALUES=()
declare -a DIAGNOSTIC_REDACT_LABELS=()
declare -a DIAGNOSTIC_REDACT_TOKEN_ONLY=()
DIAGNOSTIC_REDACT_COUNT=0

add_diagnostic_redaction() {
  local value="$1" label="$2" token_only="${3:-false}"
  [[ -n "$value" && "$value" != null ]] || return 0
  DIAGNOSTIC_REDACT_VALUES[DIAGNOSTIC_REDACT_COUNT]="$value"
  DIAGNOSTIC_REDACT_LABELS[DIAGNOSTIC_REDACT_COUNT]="$label"
  DIAGNOSTIC_REDACT_TOKEN_ONLY[DIAGNOSTIC_REDACT_COUNT]="$token_only"
  ((DIAGNOSTIC_REDACT_COUNT+=1))
}

sort_diagnostic_redactions() {
  local i j longest value label token_only
  for ((i=0; i<DIAGNOSTIC_REDACT_COUNT; i++)); do
    longest=$i
    for ((j=i+1; j<DIAGNOSTIC_REDACT_COUNT; j++)); do
      ((${#DIAGNOSTIC_REDACT_VALUES[j]} > ${#DIAGNOSTIC_REDACT_VALUES[longest]})) && longest=$j
    done
    ((longest==i)) && continue
    value="${DIAGNOSTIC_REDACT_VALUES[i]}"; label="${DIAGNOSTIC_REDACT_LABELS[i]}"
    token_only="${DIAGNOSTIC_REDACT_TOKEN_ONLY[i]}"
    DIAGNOSTIC_REDACT_VALUES[i]="${DIAGNOSTIC_REDACT_VALUES[longest]}"
    DIAGNOSTIC_REDACT_LABELS[i]="${DIAGNOSTIC_REDACT_LABELS[longest]}"
    DIAGNOSTIC_REDACT_TOKEN_ONLY[i]="${DIAGNOSTIC_REDACT_TOKEN_ONLY[longest]}"
    DIAGNOSTIC_REDACT_VALUES[longest]="$value"
    DIAGNOSTIC_REDACT_LABELS[longest]="$label"
    DIAGNOSTIC_REDACT_TOKEN_ONLY[longest]="$token_only"
  done
}

build_diagnostic_redactions() {
  local value label rows split runtime stored
  DIAGNOSTIC_REDACT_VALUES=()
  DIAGNOSTIC_REDACT_LABELS=()
  DIAGNOSTIC_REDACT_TOKEN_ONLY=()
  DIAGNOSTIC_REDACT_COUNT=0
  add_diagnostic_redaction "$(hostname 2>/dev/null || true)" '[已隐藏主机名]'
  add_diagnostic_redaction "${PUBLIC_SERVER_OVERRIDE:-}" '[已隐藏IP]'
  [[ -r "$STATE_FILE" ]] || return 0
  while IFS=$'\t' read -r value label; do
    if [[ "$label" == \[用户* && ${#value} -lt 4 ]]; then
      add_diagnostic_redaction "$value" "$label" true
      continue
    fi
    add_diagnostic_redaction "$value" "$label"
  done < <(jq -r '
    ([.users[]? | .name] | sort | to_entries[] | [.value, ("[用户" + ((.key + 1)|tostring) + "]")]),
    ([.splits[]? | .name] | sort | to_entries[] | [.value, ("[分流" + ((.key + 1)|tostring) + "]")]),
    ([.splits[]? | (.outbound_tag // "")] | map(select(. != "")) | sort | unique | to_entries[] | [.value, ("[出口" + ((.key + 1)|tostring) + "]")]),
    ([.outbound_presets[]? | .name] | sort | to_entries[] | [.value, ("[预置出口" + ((.key + 1)|tostring) + "]")]),
    ([.rule_presets[]? | .name] | sort | to_entries[] | [.value, ("[预置规则" + ((.key + 1)|tostring) + "]")]),
    (.users[]? | [(.ss2022_password // ""),"[已隐藏密码]"]),
    (.users[]? | [(.shadowtls_password // ""),"[已隐藏密码]"]),
    (.users[]? | [(.anytls_password // ""),"[已隐藏密码]"]),
    (.users[]? | [(.shadowtls_sni // ""),"[已隐藏域名]"]),
    (.users[]? | [(.tls_sni // ""),"[已隐藏域名]"]),
    (.users[]?.endpoints[]? | [(.ss2022_password // ""),"[已隐藏密码]"]),
    (.users[]?.endpoints[]? | [(.shadowtls_password // ""),"[已隐藏密码]"]),
    (.users[]?.endpoints[]? | [(.anytls_password // ""),"[已隐藏密码]"]),
    (.users[]?.endpoints[]? | [(.shadowtls_sni // ""),"[已隐藏域名]"]),
    (.users[]?.endpoints[]? | [(.tls_sni // ""),"[已隐藏域名]"]),
    (.splits[]? | [(.url // ""),"[已隐藏地址]"]),
    (.splits[]? | [(.upstream.server // ""),"[已隐藏服务器]"]),
    (.splits[]? | [(.upstream.password // ""),"[已隐藏密码]"]),
    (.splits[]? | [(.upstream.ss_password // ""),"[已隐藏密码]"]),
    (.splits[]? | [(.upstream.shadowtls_password // ""),"[已隐藏密码]"]),
    (.splits[]? | [(.upstream.sni // ""),"[已隐藏域名]"])
    ,(.outbound_presets[]? | [(.upstream.server // ""),"[已隐藏服务器]"])
    ,(.outbound_presets[]? | [(.upstream.password // ""),"[已隐藏密码]"])
    ,(.outbound_presets[]? | [(.upstream.ss_password // ""),"[已隐藏密码]"])
    ,(.outbound_presets[]? | [(.upstream.shadowtls_password // ""),"[已隐藏密码]"])
    ,(.outbound_presets[]? | [(.upstream.sni // ""),"[已隐藏域名]"])
    ,(.rule_presets[]? | [(.url // ""),"[已隐藏地址]"])
    | select(.[0] != "") | @tsv
  ' "$STATE_FILE" 2>/dev/null || true)
  rows="$(jq -c '.splits[]?' "$STATE_FILE" 2>/dev/null || true)"
  while IFS= read -r split; do
    [[ -n "$split" ]] || continue
    runtime="$(split_runtime_rule_tag_from_json "$split" 2>/dev/null || true)"
    stored="$(jq -r '.rule_set_tag // ("managed-split-" + .name)' <<<"$split" 2>/dev/null || true)"
    [[ "$runtime" == "$stored" ]] || add_diagnostic_redaction "$runtime" '[已隐藏规则名称]'
    runtime="$(split_runtime_out_tag_from_json "$split" 2>/dev/null || true)"
    stored="$(jq -r '.outbound_tag // ("managed-out-" + .name)' <<<"$split" 2>/dev/null || true)"
    [[ "$runtime" == "$stored" ]] || add_diagnostic_redaction "$runtime" '[已隐藏出口名称]'
    runtime="$(split_runtime_transport_tag_from_json "$split" 2>/dev/null || true)"
    stored="$(jq -r '"managed-transport-" + .name' <<<"$split" 2>/dev/null || true)"
    [[ "$runtime" == "$stored" ]] || add_diagnostic_redaction "$runtime" '[已隐藏连接名称]'
  done <<<"$rows"
  sort_diagnostic_redactions
}

redact_diagnostic_token_in_line() {
  local line="$1" token="$2" replacement="$3" result="" match prefix suffix left right
  local regex="(^|[^[:alnum:]_-])(${token})([^[:alnum:]_-]|$)"
  while [[ "$line" =~ $regex ]]; do
    match="${BASH_REMATCH[0]}"
    left="${BASH_REMATCH[1]}"
    right="${BASH_REMATCH[3]}"
    prefix="${line%%"$match"*}"
    suffix="${line#*"$match"}"
    result+="$prefix$left$replacement"
    line="$right$suffix"
  done
  printf '%s' "$result$line"
}

redact_diagnostic_file() {
  local source="$1" target="$2" line i pattern replacement
  {
    while IFS= read -r line || [[ -n "$line" ]]; do
      for ((i=0; i<DIAGNOSTIC_REDACT_COUNT; i++)); do
        pattern="${DIAGNOSTIC_REDACT_VALUES[$i]}"
        replacement="${DIAGNOSTIC_REDACT_LABELS[$i]}"
        if [[ "${DIAGNOSTIC_REDACT_TOKEN_ONLY[$i]:-false}" == true ]]; then
          line="$(redact_diagnostic_token_in_line "$line" "$pattern" "$replacement")"
          continue
        fi
        pattern="${pattern//\\/\\\\}"
        pattern="${pattern//\*/\\*}"
        pattern="${pattern//\?/\\?}"
        pattern="${pattern//\[/\\[}"
        line="${line//$pattern/$replacement}"
      done
      printf '%s\n' "$line"
    done < "$source"
  } | redact_diagnostic_networks > "$target"
}

redact_diagnostic_networks() {
  sed -E \
    -e 's/([[:alnum:]@_-]+)\.(service|timer|socket|target|json|conf|db|log)/\1__SB_SAFE_DOT__\2/g' \
    -e 's#https?://[^[:space:]]+#[已隐藏地址]#g' \
    -e 's/([0-9]{1,3}\.){3}[0-9]{1,3}/[已隐藏IP]/g' \
    -e 's/\[[0-9A-Fa-f:]{3,}\]/[已隐藏IP]/g' \
    -e 's/([0-9A-Fa-f]{0,4}:){3,}[0-9A-Fa-f:]{0,4}/[已隐藏IP]/g' \
    -e 's/(^|[[:space:](])::[0-9A-Fa-f:]+/\1[已隐藏IP]/g' \
    -e 's/([[:alnum:]_-]+\.)+[[:alpha:]]{2,63}/[已隐藏域名]/g' \
    -e 's/([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt])([=:][[:space:]]*|[[:space:]]+)[^[:space:],;]+/\1\2[已隐藏]/g' \
    -e 's/__SB_SAFE_DOT__/./g'
}

redact_diagnostic_log_networks() {
  redact_diagnostic_networks
}

diagnostic_service_state() {
  local state
  command -v systemctl >/dev/null 2>&1 || { printf '无法检查'; return 0; }
  state="$(systemctl is-active "$1" 2>/dev/null || true)"
  case "$state" in
    active) printf '运行中';;
    inactive) printf '未运行';;
    failed) printf '启动失败';;
    activating) printf '启动中';;
    deactivating) printf '停止中';;
    *) printf '未知（%s）' "${state:-unknown}";;
  esac
}

diagnostic_nfuse_healthy() {
  [[ -x "$NFUSE_BIN" && -S "$NFUSE_SOCKET" ]] &&
    nfuse list --json 2>/dev/null | jq -e 'type == "array"' >/dev/null
}

append_diagnostic_service_log() {
  local service="$1" label="$2" temporary="$3"
  printf '\n[%s]\n' "$label"
  if ! command -v journalctl >/dev/null 2>&1; then
    echo '无法读取：系统没有 journalctl。'
    return 0
  fi
  if ! journalctl -u "$service" --since '24 hours ago' -p warning -n 30 --no-pager -o short-iso > "$temporary" 2>/dev/null; then
    echo '无法读取该服务的日志。'
  elif [[ ! -s "$temporary" ]] || grep -Fxq -- '-- No entries --' "$temporary"; then
    echo '最近 24 小时没有警告。'
  else
    redact_diagnostic_log_networks < "$temporary"
  fi
}

diagnostic_report_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

diagnostic_report_uid() {
  stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1" 2>/dev/null
}

create_diagnostic_report() {
  local raw sanitized audit_file log_file report os_name singbox_version nfuse_version channel recorded_version
  local sing_state nfuse_state expiry_state config_result nfuse_result state_result audit_result transaction_result launcher_result overall
  local users_total=0 users_active=0 users_disabled=0 users_ss=0 users_ss_legacy=0 users_anytls=0 users_metered=0 users_self=0
  local splits_total=0 splits_active=0 splits_disabled=0 splits_all=0 splits_user=0
  local outbound_presets_total=0 rule_presets_total=0 linked_splits=0 independent_splits=0
  local lock_acquired=false
  load_diagnostic_runtime_config
  install -d -m 700 "$DIAGNOSTIC_REPORT_DIR" || die "无法创建诊断报告目录：$DIAGNOSTIC_REPORT_DIR"
  chmod 700 "$DIAGNOSTIC_REPORT_DIR" || die "无法保护诊断报告目录权限"
  if command -v flock >/dev/null 2>&1 && [[ -d "$(dirname "$LOCK_FILE")" ]]; then
    exec 9>"$LOCK_FILE"
    if flock -n 9; then lock_acquired=true
    else
      release_operation_lock
      echo '另一个管理操作正在执行，暂时不能生成一致的诊断报告。请稍后重试。'
      return 0
    fi
  fi
  raw="$(mktemp /tmp/sb-diagnostic-raw.XXXXXX)" || { [[ "$lock_acquired" == true ]] && release_operation_lock; return 1; }
  sanitized="$(mktemp /tmp/sb-diagnostic-safe.XXXXXX)" || { rm -f -- "$raw"; [[ "$lock_acquired" == true ]] && release_operation_lock; return 1; }
  audit_file="$(mktemp /tmp/sb-diagnostic-audit.XXXXXX)" || { rm -f -- "$raw" "$sanitized"; [[ "$lock_acquired" == true ]] && release_operation_lock; return 1; }
  log_file="$(mktemp /tmp/sb-diagnostic-log.XXXXXX)" || { rm -f -- "$raw" "$sanitized" "$audit_file"; [[ "$lock_acquired" == true ]] && release_operation_lock; return 1; }
  register_temp_path "$raw"; register_temp_path "$sanitized"; register_temp_path "$audit_file"; register_temp_path "$log_file"
  report="$DIAGNOSTIC_REPORT_DIR/diagnostic-$(date '+%Y%m%d-%H%M%S')-$$.txt"

  os_name="$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | head -n1 | sed 's/^"//;s/"$//' || true)"
  singbox_version="$(installed_singbox_version)"; singbox_version="${singbox_version:-未知}"
  nfuse_version="$(installed_nfuse_version)"; nfuse_version="${nfuse_version:-未知}"
  if [[ -x "$SINGBOX_BIN" ]]; then channel="$(current_singbox_channel)"; else channel=未知; fi
  case "$channel" in
    preview) channel='测试版';;
    stable) channel='正式版';;
  esac
  recorded_version="$(sed -n 's/^SCRIPT_VERSION=//p' "$DEPLOYED_VERSIONS_FILE" 2>/dev/null | head -n1 || true)"
  [[ "$recorded_version" == "$SCRIPT_VERSION" ]] && recorded_version="一致（${SCRIPT_VERSION}）" || recorded_version="不一致（记录 ${recorded_version:-缺失}，当前 ${SCRIPT_VERSION}）"
  if [[ -f /root/sb-user-manager.sh ]]; then
    cmp -s /root/sb-user-manager.sh "$SELF_PATH" && launcher_result='一致' || launcher_result='内容不一致'
  else launcher_result='未发现可选的 root 启动副本'
  fi

  sing_state="$(diagnostic_service_state sing-box.service)"
  nfuse_state="$(diagnostic_service_state nfuse.service)"
  expiry_state="$(diagnostic_service_state sb-user-expiry.timer)"
  if [[ -x "$SINGBOX_BIN" && -r "$SINGBOX_CONFIG" ]] && "$SINGBOX_BIN" check -c "$SINGBOX_CONFIG" >/dev/null 2>&1; then config_result='通过'
  else config_result='未通过'; fi
  if diagnostic_nfuse_healthy; then nfuse_result='正常'
  else nfuse_result='异常'; fi
  if [[ -r "$STATE_FILE" ]] && jq -e --argjson schema "$STATE_SCHEMA_VERSION" '
      .schema_version == $schema and (.users|type)=="array" and (.splits|type)=="array" and
      (.outbound_presets|type)=="array" and (.rule_presets|type)=="array"
    ' "$STATE_FILE" >/dev/null 2>&1; then
    state_result="正常（格式 ${STATE_SCHEMA_VERSION}）"
    users_total="$(jq '.users|length' "$STATE_FILE")"
    users_active="$(jq '[.users[] | select(.status=="active")]|length' "$STATE_FILE")"
    users_disabled=$((users_total-users_active))
    users_ss="$(jq '[.users[] | select(any(.endpoints[]; .protocol=="ss2022"))]|length' "$STATE_FILE")"
    users_ss_legacy="$(jq '[.users[] | select(any(.endpoints[]; .protocol=="ss2022" and .transport=="shadowtls"))]|length' "$STATE_FILE")"
    users_anytls="$(jq '[.users[] | select(any(.endpoints[]; .protocol=="anytls"))]|length' "$STATE_FILE")"
    users_metered="$(jq '[.users[] | select(.metered // (.limit_gib != null))]|length' "$STATE_FILE")"
    users_self=$((users_total-users_metered))
    splits_total="$(jq '.splits|length' "$STATE_FILE")"
    splits_active="$(jq '[.splits[] | select(.status=="active")]|length' "$STATE_FILE")"
    splits_disabled=$((splits_total-splits_active))
    splits_all="$(jq '[.splits[] | select(.scope=="all")]|length' "$STATE_FILE")"
    splits_user=$((splits_total-splits_all))
    outbound_presets_total="$(jq '.outbound_presets|length' "$STATE_FILE")"
    rule_presets_total="$(jq '.rule_presets|length' "$STATE_FILE")"
    linked_splits="$(jq '[.splits[] | select((.outbound_preset // "") != "" or (.rule_preset // "") != "")]|length' "$STATE_FILE")"
    independent_splits=$((splits_total-linked_splits))
  else state_result='异常或缺失'; fi
  if [[ ! -e "$TRANSACTION_JOURNAL" && ! -e "$ENVIRONMENT_TRANSACTION_JOURNAL" ]]; then transaction_result='无未完成操作'
  else transaction_result='发现未完成操作，需要先处理'; fi

  audit_result='无法执行'
  AUDIT_ISSUES=0; AUDIT_REPAIRABLE=0
  if [[ "$config_result" == 通过 && "$nfuse_result" == 正常 && "$state_result" == 正常* ]]; then
    if audit_consistency > "$audit_file" 2>&1; then
      if ((AUDIT_ISSUES==0)); then audit_result='通过'
      else audit_result="发现 ${AUDIT_ISSUES} 个问题，其中 ${AUDIT_REPAIRABLE} 个可自动修复"; fi
    fi
  else
    printf '基础服务或数据异常，无法继续执行一致性检查。\n' > "$audit_file"
  fi

  overall='正常'
  if [[ "$recorded_version" != 一致* || "$launcher_result" == '内容不一致' || "$sing_state" != 运行中 || "$nfuse_state" != 运行中 ||
        "$expiry_state" != 运行中 || "$config_result" != 通过 || "$nfuse_result" != 正常 || "$state_result" != 正常* ||
        "$transaction_result" != '无未完成操作' || "$audit_result" != 通过 ]]; then overall='发现需要处理的项目'; fi

  {
    echo 'sb-user-manager 故障诊断报告'
    echo '报告版本：1'
    printf '生成时间：%s\n' "$(date -Iseconds)"
    printf '总体结果：%s\n' "$overall"
    echo '说明：本报告不包含用户配置、密码或完整服务器配置。'
    echo
    echo '== 版本与系统 =='
    printf '管理脚本：%s\n' "$SCRIPT_VERSION"
    printf '安装版本记录：%s\n' "$recorded_version"
    printf 'root 启动副本：%s\n' "$launcher_result"
    printf 'sing-box：%s（%s）\n' "$singbox_version" "$channel"
    printf 'Nfuse：%s\n' "$nfuse_version"
    printf '系统：%s\n' "${os_name:-未知}"
    printf '内核：%s｜架构：%s\n' "$(uname -r 2>/dev/null || echo 未知)" "$(uname -m 2>/dev/null || echo 未知)"
    echo
    echo '== 服务与基础检查 =='
    printf '连接服务（sing-box）：%s\n' "$sing_state"
    printf '流量统计（Nfuse）：%s\n' "$nfuse_state"
    printf '到期自动检查：%s\n' "$expiry_state"
    printf '管理配置：%s\n' "$([[ "$DIAGNOSTIC_CONFIG_READABLE" == true ]] && echo 可读取 || echo 缺失或不可读)"
    printf 'sing-box 配置：%s\n' "$config_result"
    printf 'Nfuse 通信与数据：%s\n' "$nfuse_result"
    printf '用户数据：%s\n' "$state_result"
    printf '未完成操作：%s\n' "$transaction_result"
    echo
    echo '== 数据数量（不含名称） =='
    printf '用户：总计 %s｜启用 %s｜停用 %s｜SS2022 %s（旧版 ShadowTLS %s）｜AnyTLS %s｜计量 %s｜自用 %s\n' \
      "$users_total" "$users_active" "$users_disabled" "$users_ss" "$users_ss_legacy" "$users_anytls" "$users_metered" "$users_self"
    printf '分流：总计 %s｜启用 %s｜停用 %s｜全部用户 %s｜指定用户 %s\n' \
      "$splits_total" "$splits_active" "$splits_disabled" "$splits_all" "$splits_user"
    printf '预置内容：出口 %s｜规则 %s｜关联分流 %s｜独立分流 %s\n' \
      "$outbound_presets_total" "$rule_presets_total" "$linked_splits" "$independent_splits"
    echo
    echo '== 服务与配置一致性 =='
    printf '检查结论：%s\n' "$audit_result"
    sed -n '1,80p' "$audit_file"
    echo
    echo '== 最近 24 小时的服务警告（每项最多 30 条） =='
    echo '说明：这里是历史记录；如果总体结果为“正常”，不代表这些问题当前仍在发生。'
    append_diagnostic_service_log sing-box.service '连接服务（sing-box）' "$log_file"
    append_diagnostic_service_log nfuse.service '流量统计（Nfuse）' "$log_file"
    append_diagnostic_service_log sb-user-expiry.service '到期自动检查' "$log_file"
  } > "$raw"

  build_diagnostic_redactions
  redact_diagnostic_file "$raw" "$sanitized" || { rm -f -- "$raw" "$sanitized" "$audit_file" "$log_file"; [[ "$lock_acquired" == true ]] && release_operation_lock; return 1; }
  if ! install -m 600 "$sanitized" "$report"; then
    rm -f -- "$raw" "$sanitized" "$audit_file" "$log_file"
    [[ "$lock_acquired" == true ]] && release_operation_lock
    return 1
  fi
  rm -f -- "$raw" "$sanitized" "$audit_file" "$log_file"
  [[ "$lock_acquired" == true ]] && release_operation_lock
  printf '\n诊断报告已生成：%s\n' "$report"
  echo '报告已经自动隐藏敏感内容，可以先查看确认，再交给维护者。'
}

validate_diagnostic_report() {
  local report="$1"
  [[ -f "$report" && ! -L "$report" ]] || return 1
  [[ "$(diagnostic_report_mode "$report")" == 600 ]] || return 1
  [[ "$(diagnostic_report_uid "$report")" == "$EUID" ]] || return 1
  grep -Fxq 'sb-user-manager 故障诊断报告' "$report" &&
    grep -Fxq '报告版本：1' "$report" &&
    grep -q '^生成时间：' "$report" &&
    grep -q '^总体结果：' "$report" &&
    grep -q '^管理脚本：' "$report"
}

declare -a DIAGNOSTIC_REPORTS=()
DIAGNOSTIC_REPORT_COUNT=0

load_diagnostic_reports() {
  local report
  DIAGNOSTIC_REPORTS=()
  DIAGNOSTIC_REPORT_COUNT=0
  [[ -d "$DIAGNOSTIC_REPORT_DIR" ]] || return 0
  while IFS= read -r report; do
    validate_diagnostic_report "$report" || continue
    DIAGNOSTIC_REPORTS[DIAGNOSTIC_REPORT_COUNT]="$report"
    ((DIAGNOSTIC_REPORT_COUNT+=1))
  done < <(find "$DIAGNOSTIC_REPORT_DIR" -maxdepth 1 -type f -name 'diagnostic-*.txt' -print | sort -r)
}

print_diagnostic_reports() {
  local i report created result version
  load_diagnostic_reports
  ((DIAGNOSTIC_REPORT_COUNT>0)) || { echo '暂无诊断报告。'; return 1; }
  for ((i=0; i<DIAGNOSTIC_REPORT_COUNT; i++)); do
    report="${DIAGNOSTIC_REPORTS[$i]}"
    created="$(sed -n 's/^生成时间：//p' "$report" | head -n1)"
    result="$(sed -n 's/^总体结果：//p' "$report" | head -n1)"
    version="$(sed -n 's/^管理脚本：//p' "$report" | head -n1)"
    printf '  %d. %s｜%s｜版本 %s\n' "$((i+1))" "$created" "$result" "$version"
    printf '     %s\n' "$(basename "$report")"
  done
}

select_diagnostic_report() {
  print_diagnostic_reports || return 1
  echo '  0. 返回上一级'
  read_numbered_index '请选择报告编号：' "$DIAGNOSTIC_REPORT_COUNT" || return 1
  SELECTED_DIAGNOSTIC_REPORT="${DIAGNOSTIC_REPORTS[$SELECTED_INDEX]}"
}

show_diagnostic_report() {
  select_diagnostic_report || return 0
  validate_diagnostic_report "$SELECTED_DIAGNOSTIC_REPORT" || die '诊断报告格式或权限异常，已拒绝显示'
  printf '\n'
  sed -n '1,260p' "$SELECTED_DIAGNOSTIC_REPORT"
  printf '\n报告文件：%s\n' "$SELECTED_DIAGNOSTIC_REPORT"
}

delete_diagnostic_report() {
  local answer report
  select_diagnostic_report || return 0
  report="$SELECTED_DIAGNOSTIC_REPORT"
  read -r -p "确认删除诊断报告 $(basename "$report")？[y/N]：" answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo '已取消删除。'; return 0; }
  rm -f -- "$report"
  echo '诊断报告已删除。'
}

cleanup_diagnostic_reports() {
  local keep answer remove i
  while true; do
    read -r -p '保留最近多少份诊断报告？[10]（输入 0 返回）：' keep
    [[ "$keep" != 0 ]] || return 0
    keep="${keep:-10}"
    [[ "$keep" =~ ^[1-9][0-9]?$|^100$ ]] && break
    echo '输入无效：诊断报告保留数量必须位于 1-100，请重新输入。'
  done
  load_diagnostic_reports
  remove=$((DIAGNOSTIC_REPORT_COUNT>keep ? DIAGNOSTIC_REPORT_COUNT-keep : 0))
  printf '\n当前有效报告：%s，保留：%s，删除：%s\n' "$DIAGNOSTIC_REPORT_COUNT" "$keep" "$remove"
  ((remove>0)) || { echo '没有需要清理的旧报告。'; return 0; }
  read -r -p '确认永久删除超出保留数量的旧报告？请输入 CLEANUP：' answer
  [[ "$answer" == CLEANUP ]] || { echo '已取消清理。'; return 0; }
  for ((i=keep; i<DIAGNOSTIC_REPORT_COUNT; i++)); do rm -f -- "${DIAGNOSTIC_REPORTS[$i]}"; done
  printf '清理完成：删除诊断报告 %s 份。\n' "$remove"
}

diagnostic_report_menu() {
  local choice
  while true; do
    prepare_menu_screen
    cat <<'EOF'
检查与故障报告

1. 服务与配置检查（可自动修复）
2. 生成故障诊断报告（只读）
3. 查看已有诊断报告
4. 查看报告内容
5. 删除诊断报告
6. 清理旧诊断报告
0. 返回上一级
EOF
    read_menu_choice '请选择：' '0,1,2,3,4,5,6' '' '请输入 0-6 之间的数字' || return 0
    choice="$PROMPT_VALUE"
    case "$choice" in
      1) prompt_consistency; pause_menu;;
      2) create_diagnostic_report; pause_menu;;
      3) echo; print_diagnostic_reports || true; pause_menu;;
      4) show_diagnostic_report; pause_menu;;
      5) delete_diagnostic_report; pause_menu;;
      6) cleanup_diagnostic_reports; pause_menu;;
      0) return 0;;
    esac
  done
}
