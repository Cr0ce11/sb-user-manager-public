
prompt_split_scope_user() {
  local -a users=()
  local line i
  while IFS= read -r line; do users[${#users[@]}]="$line"; done < <(jq -r '.users[].name' "$STATE_FILE" | sort -V)
  ((${#users[@]})) || { echo '当前没有可选择用户。'; return 1; }
  echo "已有用户："
  for i in "${!users[@]}"; do printf '  %d. %s\n' "$((i+1))" "${users[$i]}"; done
  echo "  0. 返回上一级"
  if ! read_numbered_index '请选择用户编号：' "${#users[@]}"; then return 1; fi
  PROMPTED_SPLIT_USER="${users[$SELECTED_INDEX]}"
}

prompt_split_upstream_fields() {
  local protocol="$1" existing="${2:-}" current_protocol server server_port method password ss_password shadowtls_password sni insecure answer input
  PROMPTED_SPLIT_UPSTREAM=""
  [[ -n "$existing" ]] || existing='{}'
  current_protocol="$(jq -r '.protocol // ""' <<<"$existing")"
  [[ "$current_protocol" == "$protocol" ]] || existing='{}'
  server="$(jq -r '.server // ""' <<<"$existing")"
  while true; do
    read -r -p "出口服务器地址${server:+（当前 ${server}；留空保持）}（输入 0 取消）：" input
    [[ "$input" != 0 ]] || return 1
    server="${input:-$server}"
    if [[ -n "$server" && "$server" != *[[:space:]]* ]]; then break; fi
    echo '输入无效：出口服务器地址不能为空，也不能包含空格，请重新输入。'
  done
  server_port="$(jq -r '.server_port // ""' <<<"$existing")"
  while true; do
    read -r -p "出口服务器端口${server_port:+（当前 ${server_port}；留空保持）}（输入 0 取消）：" input
    [[ "$input" != 0 ]] || return 1
    server_port="${input:-$server_port}"
    if validate_without_exit validate_upstream_port "$server_port"; then break; fi
    printf '输入无效：%s，请重新输入。\n' "$VALIDATION_ERROR"
  done
  case "$protocol" in
    anytls)
      password="$(jq -r '.password // ""' <<<"$existing")"
      while true; do
        if [[ -n "$password" ]]; then read -r -s -p 'AnyTLS 密码（留空保持，输入 0 取消）：' input
        else read -r -s -p 'AnyTLS 密码（输入 0 取消）：' input
        fi
        echo
        [[ "$input" != 0 ]] || return 1
        password="${input:-$password}"
        [[ -n "$password" ]] && break
        echo '输入无效：AnyTLS 密码不能为空，请重新输入。'
      done
      sni="$(jq -r '.sni // ""' <<<"$existing")"
      if ! read_validated_value "TLS SNI${sni:+（当前 ${sni}；留空保持）}（输入 0 取消）：" "$sni" 0 validate_shadowtls_sni; then return 1; fi
      sni="$PROMPT_VALUE"
      insecure="$(jq -r '.insecure // false' <<<"$existing")"
      read_menu_choice "跳过证书验证？[y/n，留空保持当前 $([[ "$insecure" == true ]] && echo 是 || echo 否)]：" 'y,Y,n,N,keep' keep '请输入 y、n 或直接回车' || return 1
      answer="$PROMPT_VALUE"
      case "$answer" in [Yy]) insecure=true;; [Nn]) insecure=false;; keep) :;; esac
      PROMPTED_SPLIT_UPSTREAM="$(SB_JQ_PASSWORD="$password" jq -cn --arg server "$server" --argjson port "$server_port" --arg sni "$sni" --argjson insecure "$insecure" '{protocol:"anytls",server:$server,server_port:$port,password:$ENV.SB_JQ_PASSWORD,sni:$sni,insecure:$insecure}')"
      ;;
    shadowsocks)
      method="$(jq -r '.method // ""' <<<"$existing")"
      while true; do
        read -r -p "加密方式${method:+（当前 ${method}；留空保持）}（输入 0 取消）：" input
        [[ "$input" != 0 ]] || return 1
        method="${input:-$method}"
        [[ -n "$method" ]] && break
        echo '输入无效：加密方式不能为空，请重新输入。'
      done
      password="$(jq -r '.password // ""' <<<"$existing")"
      while true; do
        if [[ -n "$password" ]]; then read -r -s -p 'Shadowsocks 密码（留空保持，输入 0 取消）：' input
        else read -r -s -p 'Shadowsocks 密码（输入 0 取消）：' input
        fi
        echo
        [[ "$input" != 0 ]] || return 1
        password="${input:-$password}"
        [[ -n "$password" ]] && break
        echo '输入无效：Shadowsocks 密码不能为空，请重新输入。'
      done
      PROMPTED_SPLIT_UPSTREAM="$(SB_JQ_PASSWORD="$password" jq -cn --arg server "$server" --argjson port "$server_port" --arg method "$method" '{protocol:"shadowsocks",server:$server,server_port:$port,method:$method,password:$ENV.SB_JQ_PASSWORD}')"
      ;;
    ss_shadowtls)
      method="$(jq -r '.method // "2022-blake3-aes-128-gcm"' <<<"$existing")"
      while true; do
        read -r -p "SS2022 加密方式（当前 ${method}；留空保持；输入 0 取消）：" input
        [[ "$input" != 0 ]] || return 1
        method="${input:-$method}"
        [[ "$method" == 2022-* ]] && break
        echo '输入无效：SS2022 + ShadowTLS 必须使用 2022 系列加密方式，请重新输入。'
      done
      ss_password="$(jq -r '.ss_password // ""' <<<"$existing")"
      while true; do
        if [[ -n "$ss_password" ]]; then read -r -s -p 'SS2022 密码（留空保持，输入 0 取消）：' input
        else read -r -s -p 'SS2022 密码（输入 0 取消）：' input
        fi
        echo
        [[ "$input" != 0 ]] || return 1
        ss_password="${input:-$ss_password}"
        [[ -n "$ss_password" ]] && break
        echo '输入无效：SS2022 密码不能为空，请重新输入。'
      done
      shadowtls_password="$(jq -r '.shadowtls_password // ""' <<<"$existing")"
      while true; do
        if [[ -n "$shadowtls_password" ]]; then read -r -s -p 'ShadowTLS v3 密码（留空保持，输入 0 取消）：' input
        else read -r -s -p 'ShadowTLS v3 密码（输入 0 取消）：' input
        fi
        echo
        [[ "$input" != 0 ]] || return 1
        shadowtls_password="${input:-$shadowtls_password}"
        [[ -n "$shadowtls_password" ]] && break
        echo '输入无效：ShadowTLS 密码不能为空，请重新输入。'
      done
      sni="$(jq -r '.sni // ""' <<<"$existing")"
      if ! read_validated_value "TLS SNI${sni:+（当前 ${sni}；留空保持）}（输入 0 取消）：" "$sni" 0 validate_shadowtls_sni; then return 1; fi
      sni="$PROMPT_VALUE"
      insecure="$(jq -r '.insecure // false' <<<"$existing")"
      read_menu_choice "跳过证书验证？[y/n，留空保持当前 $([[ "$insecure" == true ]] && echo 是 || echo 否)]：" 'y,Y,n,N,keep' keep '请输入 y、n 或直接回车' || return 1
      answer="$PROMPT_VALUE"
      case "$answer" in [Yy]) insecure=true;; [Nn]) insecure=false;; keep) :;; esac
      PROMPTED_SPLIT_UPSTREAM="$(SB_JQ_SS_PASSWORD="$ss_password" SB_JQ_SHADOWTLS_PASSWORD="$shadowtls_password" jq -cn --arg server "$server" --argjson port "$server_port" --arg method "$method" --arg sni "$sni" --argjson insecure "$insecure" '{protocol:"ss_shadowtls",server:$server,server_port:$port,method:$method,ss_password:$ENV.SB_JQ_SS_PASSWORD,shadowtls_password:$ENV.SB_JQ_SHADOWTLS_PASSWORD,sni:$sni,insecure:$insecure}')"
      ;;
    *) die "不支持的上游协议：$protocol";;
  esac
}

outbound_protocol_label() {
  case "$1" in
    anytls) echo 'AnyTLS';;
    shadowsocks) echo 'Shadowsocks';;
    ss_shadowtls) echo 'SS2022 + ShadowTLS';;
    *) echo '未知';;
  esac
}

print_outbound_preset_list() {
  local rows
  if ! rows="$(jq -r '
    . as $state |
    if (.outbound_presets | length) == 0 then "暂无预置出口"
    else (["名称","协议","服务器","关联分流","其中启用"] | @tsv),
      ($state.outbound_presets | sort_by(.name)[] as $p |
        [ $p.name,
          (if $p.upstream.protocol == "anytls" then "AnyTLS" elif $p.upstream.protocol == "shadowsocks" then "Shadowsocks" else "SS2022+ShadowTLS" end),
          ($p.upstream.server + ":" + ($p.upstream.server_port | tostring)),
          ([$state.splits[] | select((.outbound_preset // "") == $p.name)] | length),
          ([$state.splits[] | select((.outbound_preset // "") == $p.name and .status == "active")] | length)
        ] | @tsv)
    end
  ' "$STATE_FILE" 2>/dev/null)"; then
    echo '错误：无法读取预置出口数据，请运行「检查与故障报告」。'
    return 0
  fi
  if ! printf '%s\n' "$rows" | column -t -s $'\t'; then
    echo '错误：无法显示预置出口列表，请重新进入此页面。'
  fi
  return 0
}

print_rule_preset_list() {
  local rows
  if ! rows="$(jq -r '
    . as $state |
    if (.rule_presets | length) == 0 then "暂无预置规则"
    else (["名称","格式","关联分流","其中启用"] | @tsv),
      ($state.rule_presets | sort_by(.name)[] as $p |
        [ $p.name,
          (if ($p.url | test("\\.srs([?#].*)?$")) then "SRS" else "JSON" end),
          ([$state.splits[] | select((.rule_preset // "") == $p.name)] | length),
          ([$state.splits[] | select((.rule_preset // "") == $p.name and .status == "active")] | length)
        ] | @tsv)
    end
  ' "$STATE_FILE" 2>/dev/null)"; then
    echo '错误：无法读取预置规则数据，请运行「检查与故障报告」。'
    return 0
  fi
  if ! printf '%s\n' "$rows" | column -t -s $'\t'; then
    echo '错误：无法显示预置规则列表，请重新进入此页面。'
  fi
  return 0
}

prompt_select_outbound_preset() {
  local title="$1" rows count
  rows="$(jq -c '.outbound_presets | sort_by(.name)' "$STATE_FILE")" || return 1
  count="$(jq 'length' <<<"$rows")"
  ((count > 0)) || { echo '尚未添加预置出口，请先到“预置出口管理”中添加。'; return 1; }
  printf '\n%s\n\n' "$title"
  jq -r '(["编号","名称","协议","服务器"] | @tsv), (to_entries[] | [(.key+1),.value.name,(if .value.upstream.protocol=="anytls" then "AnyTLS" elif .value.upstream.protocol=="shadowsocks" then "Shadowsocks" else "SS2022+ShadowTLS" end),(.value.upstream.server+":"+(.value.upstream.server_port|tostring))] | @tsv)' <<<"$rows" | column -t -s $'\t'
  echo '0. 返回上一级'
  read_numbered_index '请选择预置出口：' "$count" || return 1
  SELECTED_OUTBOUND_PRESET="$(jq -r ".[${SELECTED_INDEX}].name" <<<"$rows")"
  SELECTED_OUTBOUND_UPSTREAM="$(jq -c ".[${SELECTED_INDEX}].upstream" <<<"$rows")"
}

prompt_select_rule_preset() {
  local title="$1" rows count
  rows="$(jq -c '.rule_presets | sort_by(.name)' "$STATE_FILE")" || return 1
  count="$(jq 'length' <<<"$rows")"
  ((count > 0)) || { echo '尚未添加预置规则，请先到“预置规则管理”中添加。'; return 1; }
  printf '\n%s\n\n' "$title"
  jq -r '(["编号","名称","格式"] | @tsv), (to_entries[] | [(.key+1),.value.name,(if (.value.url|test("\\.srs([?#].*)?$")) then "SRS" else "JSON" end)] | @tsv)' <<<"$rows" | column -t -s $'\t'
  echo '0. 返回上一级'
  read_numbered_index '请选择预置规则：' "$count" || return 1
  SELECTED_RULE_PRESET="$(jq -r ".[${SELECTED_INDEX}].name" <<<"$rows")"
  SELECTED_RULE_URL="$(jq -r ".[${SELECTED_INDEX}].url" <<<"$rows")"
}

prompt_preset_name() {
  local label="$1" kind="$2" name
  while true; do
    read -r -p "${label}（输入 0 返回）：" name
    [[ "$name" != 0 ]] || return 1
    if ! validate_without_exit validate_preset_name "$name"; then
      printf '输入无效：%s，请重新输入。\n' "$VALIDATION_ERROR"; continue
    fi
    if [[ "$kind" == outbound ]] && outbound_preset_exists "$name"; then echo '同名预置出口已经存在，请换一个名称。'; continue; fi
    if [[ "$kind" == rule ]] && rule_preset_exists "$name"; then echo '同名预置规则已经存在，请换一个名称。'; continue; fi
    PRESET_NAME="$name"; return 0
  done
}

prompt_outbound_protocol() {
  cat <<'EOF'
出口协议：
  1. AnyTLS
  2. Shadowsocks
  3. SS2022 + ShadowTLS
  0. 返回上一级
EOF
  read_menu_choice '请选择：' '0,1,2,3' '' '请输入 1、2、3 或 0' || return 1
  case "$PROMPT_VALUE" in 1) PRESET_PROTOCOL=anytls;; 2) PRESET_PROTOCOL=shadowsocks;; 3) PRESET_PROTOCOL=ss_shadowtls;; 0) return 1;; esac
}

prompt_add_outbound_preset() {
  local upstream answer
  prepare_core
  prompt_preset_name '预置出口名称' outbound || { MENU_RETURNED=true; return 0; }
  prompt_outbound_protocol || { MENU_RETURNED=true; return 0; }
  prompt_split_upstream_fields "$PRESET_PROTOCOL" '{}' || { MENU_RETURNED=true; return 0; }
  upstream="$PROMPTED_SPLIT_UPSTREAM"
  printf '\n保存预览：\n  名称：%s\n  协议：%s\n  服务器：%s:%s\n' "$PRESET_NAME" "$(outbound_protocol_label "$PRESET_PROTOCOL")" "$(jq -r '.server' <<<"$upstream")" "$(jq -r '.server_port' <<<"$upstream")"
  echo '说明：保存预置不会修改 sing-box，也不会影响现有分流。'
  read -r -p '确认检查并保存？[y/N]：' answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo '已取消保存。'; return 0; }
  cmd_outbound_preset_add "$PRESET_NAME" "$upstream"
}

prompt_edit_outbound_preset() {
  local name current protocol upstream total active choice answer
  prepare_core
  prompt_select_outbound_preset '修改预置出口' || { MENU_RETURNED=true; return 0; }
  name="$SELECTED_OUTBOUND_PRESET"
  current="$SELECTED_OUTBOUND_UPSTREAM"
  total="$(jq --arg name "$name" '[.splits[] | select((.outbound_preset // "") == $name)] | length' "$STATE_FILE")"
  active="$(jq --arg name "$name" '[.splits[] | select((.outbound_preset // "") == $name and .status == "active")] | length' "$STATE_FILE")"
  printf '\n关联分流：%s 条，其中启用 %s 条。\n' "$total" "$active"
  printf '当前协议：%s\n' "$(outbound_protocol_label "$(jq -r '.protocol' <<<"$current")")"
  cat <<'EOF'
  1. 保持当前协议并修改参数（默认）
  2. 改用 AnyTLS
  3. 改用 Shadowsocks
  4. 改用 SS2022 + ShadowTLS
  0. 返回上一级
EOF
  read_menu_choice '请选择 [1]：' '0,1,2,3,4' 1 '请输入 1、2、3、4 或 0' || return 1
  choice="$PROMPT_VALUE"
  case "$choice" in 1) protocol="$(jq -r '.protocol' <<<"$current")";; 2) protocol=anytls; current='{}';; 3) protocol=shadowsocks; current='{}';; 4) protocol=ss_shadowtls; current='{}';; 0) MENU_RETURNED=true; return 0;; esac
  prompt_split_upstream_fields "$protocol" "$current" || { MENU_RETURNED=true; return 0; }
  upstream="$PROMPTED_SPLIT_UPSTREAM"
  if ((active > 0)); then echo '保存后会同步更新所有关联分流，并只重启一次 sing-box。'; else echo '保存后会同步更新关联记录；当前没有启用中的关联分流，不会重启服务。'; fi
  read -r -p '确认检查并保存？[y/N]：' answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo '已取消修改。'; return 0; }
  cmd_outbound_preset_edit "$name" "$upstream"
}

prompt_remove_outbound_preset() {
  local name total active answer
  prepare_core
  prompt_select_outbound_preset '删除预置出口' || { MENU_RETURNED=true; return 0; }
  name="$SELECTED_OUTBOUND_PRESET"
  total="$(jq --arg name "$name" '[.splits[] | select((.outbound_preset // "") == $name)] | length' "$STATE_FILE")"
  active="$(jq --arg name "$name" '[.splits[] | select((.outbound_preset // "") == $name and .status == "active")] | length' "$STATE_FILE")"
  printf '\n关联分流：%s 条，其中启用 %s 条。\n' "$total" "$active"
  echo '删除后，这些分流会保留最后一次可用参数并转为独立配置；不会重启服务。'
  read -r -p "确认删除预置出口 ${name}？[y/N]：" answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo '已取消删除。'; return 0; }
  cmd_outbound_preset_remove "$name"
}

prompt_add_rule_preset() {
  local url answer
  prepare_core
  prompt_preset_name '预置规则名称' rule || { MENU_RETURNED=true; return 0; }
  while true; do
    read -r -p '规则集下载地址（HTTPS，.srs 或 .json；输入 0 返回）：' url
    [[ "$url" != 0 ]] || { MENU_RETURNED=true; return 0; }
    [[ "$url" == https://* ]] || { echo '输入无效：必须使用 HTTPS，请重新输入。'; continue; }
    split_rule_format "$url" >/dev/null || { echo '输入无效：地址必须指向 .srs 或 .json 文件，请重新输入。'; continue; }
    break
  done
  echo '说明：保存预置不会修改 sing-box，也不会影响现有分流。'
  read -r -p '确认检查并保存？[y/N]：' answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo '已取消保存。'; return 0; }
  cmd_rule_preset_add "$PRESET_NAME" "$url"
}

prompt_edit_rule_preset() {
  local name url total active answer
  prepare_core
  prompt_select_rule_preset '修改预置规则' || { MENU_RETURNED=true; return 0; }
  name="$SELECTED_RULE_PRESET"; url="$SELECTED_RULE_URL"
  total="$(jq --arg name "$name" '[.splits[] | select((.rule_preset // "") == $name)] | length' "$STATE_FILE")"
  active="$(jq --arg name "$name" '[.splits[] | select((.rule_preset // "") == $name and .status == "active")] | length' "$STATE_FILE")"
  printf '\n关联分流：%s 条，其中启用 %s 条。\n' "$total" "$active"
  while true; do
    read -r -p "规则集下载地址（当前 ${url}；留空保持；输入 0 返回）：" answer
    [[ "$answer" != 0 ]] || { MENU_RETURNED=true; return 0; }
    url="${answer:-$url}"
    [[ "$url" == https://* ]] || { echo '输入无效：必须使用 HTTPS，请重新输入。'; continue; }
    split_rule_format "$url" >/dev/null || { echo '输入无效：地址必须指向 .srs 或 .json 文件，请重新输入。'; continue; }
    break
  done
  if ((active > 0)); then echo '保存后会同步更新所有关联分流，并只重启一次 sing-box。'; else echo '保存后会同步更新关联记录；当前没有启用中的关联分流，不会重启服务。'; fi
  read -r -p '确认检查并保存？[y/N]：' answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo '已取消修改。'; return 0; }
  cmd_rule_preset_edit "$name" "$url"
}

prompt_remove_rule_preset() {
  local name total active answer
  prepare_core
  prompt_select_rule_preset '删除预置规则' || { MENU_RETURNED=true; return 0; }
  name="$SELECTED_RULE_PRESET"
  total="$(jq --arg name "$name" '[.splits[] | select((.rule_preset // "") == $name)] | length' "$STATE_FILE")"
  active="$(jq --arg name "$name" '[.splits[] | select((.rule_preset // "") == $name and .status == "active")] | length' "$STATE_FILE")"
  printf '\n关联分流：%s 条，其中启用 %s 条。\n' "$total" "$active"
  echo '删除后，这些分流会保留最后一次可用地址并转为独立配置；不会重启服务。'
  read -r -p "确认删除预置规则 ${name}？[y/N]：" answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo '已取消删除。'; return 0; }
  cmd_rule_preset_remove "$name"
}

prompt_add_split() {
  local name url rule_preset scope_choice scope user="" outbound_preset outbound_tag upstream answer
  prepare_core
  if ! jq -e '(.rule_presets | length) > 0' "$STATE_FILE" >/dev/null; then echo '尚未添加预置规则，请先到“预置规则管理”中添加。'; return 0; fi
  if ! jq -e '(.outbound_presets | length) > 0' "$STATE_FILE" >/dev/null; then echo '尚未添加预置出口，请先到“预置出口管理”中添加。'; return 0; fi
  echo '输入 0 可返回分流管理。'
  while true; do
    read -r -p '分流名称：' name
    [[ "$name" != 0 ]] || { MENU_RETURNED=true; return 0; }
    if ! validate_without_exit validate_split_name "$name"; then printf '输入无效：%s，请重新输入。\n' "$VALIDATION_ERROR"; continue; fi
    split_exists "$name" && { echo '分流名称已存在，请重新输入。'; continue; }
    jq -e --arg tag "$name" '.route.rule_set[]? | select(.tag == $tag)' "$SINGBOX_CONFIG" >/dev/null && { echo '这个名称已被其他规则使用，请换一个名称。'; continue; }
    break
  done
  prompt_select_rule_preset '选择要使用的预置规则' || { MENU_RETURNED=true; return 0; }
  rule_preset="$SELECTED_RULE_PRESET"; url="$SELECTED_RULE_URL"
  while true; do
    cat <<'EOF'
作用范围：
  1. 全部用户
  2. 指定用户
  0. 返回分流管理
EOF
    read_menu_choice '请选择：' '0,1,2' '' '请输入 1、2 或 0' || return 1
    scope_choice="$PROMPT_VALUE"
    case "$scope_choice" in 1) scope=all; user=""; break;; 2) scope=user;; 0) MENU_RETURNED=true; return 0;; esac
    if prompt_split_scope_user; then user="$PROMPTED_SPLIT_USER"; break; fi
  done
  prompt_select_outbound_preset '选择要使用的预置出口' || { MENU_RETURNED=true; return 0; }
  outbound_preset="$SELECTED_OUTBOUND_PRESET"; upstream="$SELECTED_OUTBOUND_UPSTREAM"
  outbound_tag="$(stable_managed_tag split-out "$name")" || return 1
  printf '\n分流预览：\n  名称：%s\n  预置规则：%s\n  范围：%s\n  预置出口：%s\n' "$name" "$rule_preset" "$(if [[ "$scope" == all ]]; then echo 全部用户; else echo "用户:$user"; fi)" "$outbound_preset"
  read -r -p '确认检查并添加？[y/N]：' answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo '已取消添加。'; return 0; }
  if ! cmd_split_add "$name" "$url" "$scope" "$user" "$upstream" "$outbound_tag" "$rule_preset" "$outbound_preset"; then
    echo '分流没有添加，现有配置没有改变。'
    return 0
  fi
}

print_split_selection_table() {
  jq -r '
    (["编号","顺序","名称","状态","范围","出口协议","预置出口","出口服务器"] | @tsv),
    (to_entries[] | [
      (.key + 1),
      .value.priority,
      .value.split.name,
      (if .value.split.status == "active" then "启用" else "停用" end),
      (if .value.split.scope == "all" then "全部用户" else ("用户:" + .value.split.user) end),
      (if .value.split.upstream.protocol == "anytls" then "AnyTLS"
       elif .value.split.upstream.protocol == "shadowsocks" then "Shadowsocks"
       elif .value.split.upstream.protocol == "ss_shadowtls" then "SS2022+ShadowTLS"
       else "旧版未配置" end),
      (.value.split.outbound_preset // "独立配置"),
      ((.value.split.upstream.server // "-") + ":" + ((.value.split.upstream.server_port // "-") | tostring))
    ] | @tsv)
  ' <<<"$1" | column -t -s $'\t'
}

prompt_select_split() {
  local desired="$1" title="$2" rows_json count
  rows_json="$(jq -c --arg desired "$desired" '[.splits | to_entries[] | select($desired == "all" or .value.status == $desired) | {priority:(.key+1),split:.value}]' "$STATE_FILE")"
  count="$(jq 'length' <<<"$rows_json")"
  ((count>0)) || { echo "没有符合条件的分流。"; return 1; }
  printf '\n%s\n\n' "$title"
  print_split_selection_table "$rows_json"
  echo
  echo "0. 返回分流管理"
  if ! read_numbered_index '请选择分流编号：' "$count"; then MENU_RETURNED=true; return 1; fi
  SELECTED_SPLIT_NAME="$(jq -r ".[$SELECTED_INDEX].split.name" <<<"$rows_json")"
}

prompt_select_split_diagnostic_user() {
  local rows_json count
  rows_json="$(jq -c '[.users[] | select(.status == "active")] | sort_by(.name)' "$STATE_FILE")" || return 1
  count="$(jq 'length' <<<"$rows_json")"
  ((count > 0)) || { echo "没有启用中的用户，暂时无法验证分流。"; return 1; }
  echo
  echo "请选择用于测试的用户："
  jq -r 'to_entries[] |
    "  \(.key + 1). \(.value.name)｜" +
    ([.value.endpoints[].protocol | if . == "anytls" then "AnyTLS" else "SS2022 + ShadowTLS" end] | join(" + ")) +
    "｜端口 " + ([.value.endpoints[].port | tostring] | join(" / "))' <<<"$rows_json"
  echo "  0. 返回分流管理"
  if ! read_numbered_index '请选择用户编号：' "$count"; then MENU_RETURNED=true; return 1; fi
  SELECTED_DIAGNOSTIC_USER="$(jq -r ".[$SELECTED_INDEX].name" <<<"$rows_json")"
}

extract_split_diagnostic_connections() {
  local user="$1" expected_outbound="$2" log_file="$3"
  awk -v anytls="anytls-$user" -v st="st-$user" -v ss="ss-$user" -v ss_udp="ss-udp-$user" -v expected="$expected_outbound" '
    function connection_id(line, token) {
      if (!match(line, /\[[0-9][0-9]*[[:space:]]/)) return ""
      token = substr(line, RSTART + 1, RLENGTH - 2)
      sub(/[[:space:]]+$/, "", token)
      return token
    }
    {
      line = $0
      gsub(/\033\[[0-9;]*m/, "", line)
    }
    index(line, "inbound/") &&
      (index(line, "[" anytls "]") || index(line, "[" st "]") || index(line, "[" ss "]") || index(line, "[" ss_udp "]")) &&
      index(line, "inbound connection to ") {
        id = connection_id(line)
        if (id == "") next
        marker = "inbound connection to "
        destination = substr(line, index(line, marker) + length(marker))
        gsub(/[\t\r\n]/, "", destination)
        event = ++count
        event_id[event] = id
        target[event] = destination
        tail[id]++
        queue[id, tail[id]] = event
        next
      }
    index(line, "outbound/") {
      id = connection_id(line)
      if (id == "") next
      part = substr(line, index(line, "outbound/") + length("outbound/"))
      if (!match(part, /\[[^][]+\]/)) next
      tag = substr(part, RSTART + 1, RLENGTH - 2)
      if (head[id] < tail[id]) {
        head[id]++
        event = queue[id, head[id]]
        outbound[event] = tag
        last_event[id] = event
      } else if ((id in last_event) && outbound[last_event[id]] != expected && tag == expected) {
        outbound[last_event[id]] = tag
      }
    }
    END {
      start = count > 20 ? count - 19 : 1
      for (i = start; i <= count; i++) {
        printf "%s\t%s\t%s\n", event_id[i], target[i], outbound[i]
      }
    }
  ' "$log_file"
}

split_display_outbound_name_from_json() {
  jq -r '.outbound_preset // .outbound_tag // ("managed-out-" + .name)' <<<"$1"
}

find_active_split_by_runtime_outbound() {
  local wanted="$1" rows split tag
  rows="$(jq -c '.splits[]? | select(.status == "active")' "$STATE_FILE")" || return 1
  while IFS= read -r split; do
    [[ -n "$split" ]] || continue
    tag="$(split_runtime_out_tag_from_json "$split")" || return 1
    if [[ "$tag" == "$wanted" ]]; then
      printf '%s' "$split"
      return 0
    fi
  done <<<"$rows"
  return 1
}

render_split_diagnostic_results() {
  local user="$1" split_name="$2" expected_outbound="$3" log_file="$4"
  local rows destination outbound matched_split matched_json result display_outbound expected_json
  expected_json="$(jq -c --arg name "$split_name" '.splits[] | select(.name == $name)' "$STATE_FILE")" || return 1
  rows="$(extract_split_diagnostic_connections "$user" "$expected_outbound" "$log_file")" || return 1
  if [[ -z "$rows" ]]; then
    echo "没有发现该用户的新连接。"
    echo "请确认客户端正在使用用户 ${user}，然后重新验证；也可以检查 sing-box 日志级别是否为 info。"
    return 0
  fi
  {
    printf '目标地址\t判断结果\t实际出口\n'
    while IFS=$'\t' read -r _ destination outbound; do
      display_outbound="$outbound"
      if [[ "$outbound" == "$expected_outbound" ]]; then
        result="已命中：$split_name"
        display_outbound="$(split_display_outbound_name_from_json "$expected_json")" || return 1
      elif [[ "$outbound" == direct ]]; then
        result="未命中，走直连"
      elif [[ -z "$outbound" ]]; then
        result="未看到出口记录"
        display_outbound="-"
      else
        if matched_json="$(find_active_split_by_runtime_outbound "$outbound")"; then
          matched_split="$(jq -r '.name' <<<"$matched_json")" || return 1
          display_outbound="$(split_display_outbound_name_from_json "$matched_json")" || return 1
        else
          matched_split=""
        fi
        if [[ -n "$matched_split" ]]; then result="命中其他分流：$matched_split"
        else result="使用其他出口"
        fi
      fi
      printf '%s\t%s\t%s\n' "$destination" "$result" "$display_outbound"
    done <<<"$rows"
  } | column -t -s $'\t'
  echo
  echo "提示：同一页面可能同时访问多个域名，因此出现命中和直连并存属于正常现象。"
}

prompt_split_diagnostic() {
  local split split_name scope user expected_outbound expected_outbound_display answer cursor_line cursor log_file log_level status
  prepare_core
  need_cmd journalctl
  if legacy_split_cleanup_pending; then
    echo '检测到旧版分流仍在当前规则之前生效，暂时无法准确验证。'
    echo '请先运行「系统管理 → 服务与配置检查」并选择自动修复；修复会在备份后重启 sing-box。'
    return 0
  fi
  prompt_select_split active "验证分流是否生效" || return 0
  split_name="$SELECTED_SPLIT_NAME"
  split="$(jq -c --arg name "$split_name" '.splits[] | select(.name == $name)' "$STATE_FILE")" || return 1
  scope="$(jq -r '.scope' <<<"$split")"
  expected_outbound="$(split_runtime_out_tag_from_json "$split")" || return 1
  expected_outbound_display="$(split_display_outbound_name_from_json "$split")" || return 1
  if [[ "$scope" == user ]]; then
    user="$(jq -r '.user' <<<"$split")"
    status="$(jq -r --arg name "$user" 'first(.users[] | select(.name == $name) | .status) // "missing"' "$STATE_FILE")"
    if [[ "$status" != active ]]; then
      echo "关联用户 ${user} 当前未启用，无法产生测试连接。"
      return 0
    fi
  else
    prompt_select_split_diagnostic_user || return 0
    user="$SELECTED_DIAGNOSTIC_USER"
  fi
  log_level="$(jq -r '.log.level // "info"' "$SINGBOX_CONFIG")"
  case "$log_level" in trace|debug|info) :;;
    *) echo "当前 sing-box 日志级别是 ${log_level}，不会记录连接去向；请先改为 info 后再验证。"; return 0;;
  esac

  printf '\n诊断对象：\n  分流：%s\n  用户：%s\n  预期出口：%s\n' "$split_name" "$user" "$expected_outbound_display"
  cat <<'EOF'

使用方法：
  1. 准备好使用该用户配置的客户端。
  2. 开始记录后，在客户端访问你想验证的网站或应用。
  3. 返回这里按回车，脚本会整理这段时间的新连接。
EOF
  read -r -p '按回车开始记录，输入 0 返回：' answer
  [[ "$answer" != 0 ]] || { MENU_RETURNED=true; return 0; }
  cursor_line="$(journalctl -u "$SINGBOX_SERVICE" -n 0 --show-cursor --no-pager 2>/dev/null | tail -n1)"
  cursor="${cursor_line#-- cursor: }"
  if [[ -z "$cursor" || "$cursor" == "$cursor_line" ]]; then
    echo "无法读取连接日志起点，请确认 systemd 日志服务正常。"
    return 0
  fi
  release_operation_lock
  read -r -p '现在请在客户端访问目标；完成后按回车查看结果，输入 0 取消：' answer
  [[ "$answer" != 0 ]] || { MENU_RETURNED=true; return 0; }
  log_file="$(mktemp /tmp/sb-split-diagnostic.XXXXXX)" || return 1
  register_temp_path "$log_file"
  if ! journalctl -u "$SINGBOX_SERVICE" --after-cursor="$cursor" --no-pager -o cat > "$log_file" 2>/dev/null; then
    rm -f -- "$log_file"
    echo "读取新增连接日志失败，请确认 systemd 日志服务正常。"
    return 0
  fi
  echo
  render_split_diagnostic_results "$user" "$split_name" "$expected_outbound" "$log_file"
  rm -f -- "$log_file"
}

prompt_split_action() {
  local action="$1" desired="$2" name answer title
  prepare_core
  case "$action" in remove) title="删除分流";; disable) title="停用分流";; enable) title="启用分流";; esac
  prompt_select_split "$desired" "$title" || return 0
  name="$SELECTED_SPLIT_NAME"
  case "$action" in
    remove) read -r -p "确认删除分流 ${name}？[y/N]：" answer; [[ "$answer" =~ ^[Yy]$ ]] || { echo "已取消删除。"; return 0; }; cmd_split_remove "$name";;
    disable) cmd_split_disable "$name";;
    enable)
      if ! cmd_split_enable "$name"; then
        echo '分流没有启用，现有配置没有改变。'
        return 0
      fi
      ;;
  esac
}

prompt_split_details() {
  prepare_core
  prompt_select_split all "查看分流详情" || return 0
  echo
  cmd_split_show "$SELECTED_SPLIT_NAME"
}

prompt_edit_split() {
  local name split url scope user upstream out_tag choice answer current_scope current_out rule_preset outbound_preset current_source
  prepare_core
  prompt_select_split all "编辑分流" || return 0
  name="$SELECTED_SPLIT_NAME"
  split="$(jq -c --arg name "$name" '.splits[] | select(.name == $name)' "$STATE_FILE")"
  jq -e '.upstream.protocol' <<<"$split" >/dev/null || die "这条旧版分流缺少出口服务器信息，请删除后重新添加"
  url="$(jq -r '.url' <<<"$split")"
  rule_preset="$(jq -r '.rule_preset // ""' <<<"$split")"
  current_source="${rule_preset:-独立配置}"
  cat <<EOF
规则来源（当前：${current_source}）：
  1. 保持不变（默认）
  2. 选择预置规则
  0. 取消编辑
EOF
  read_menu_choice '请选择 [1]：' '0,1,2' 1 '请输入 1、2 或 0' || return 1
  choice="$PROMPT_VALUE"
  case "$choice" in
    1) :;;
    2) prompt_select_rule_preset '选择新的预置规则' || { MENU_RETURNED=true; return 0; }; rule_preset="$SELECTED_RULE_PRESET"; url="$SELECTED_RULE_URL";;
    0) MENU_RETURNED=true; return 0;;
  esac
  current_scope="$(jq -r '.scope' <<<"$split")"
  scope="$current_scope"; user="$(jq -r '.user // ""' <<<"$split")"
  cat <<EOF
作用范围（当前：$(if [[ "$current_scope" == all ]]; then echo 全部用户; else echo "用户:$user"; fi)）：
  1. 保持不变（默认）
  2. 全部用户
  3. 指定用户
  0. 取消编辑
EOF
  read_menu_choice '请选择 [1]：' '0,1,2,3' 1 '请输入 1、2、3 或 0' || return 1
  choice="$PROMPT_VALUE"
  case "$choice" in
    1) :;;
    2) scope=all; user="";;
    3) scope=user; prompt_split_scope_user || return 0; user="$PROMPTED_SPLIT_USER";;
    0) MENU_RETURNED=true; return 0;;
  esac
  outbound_preset="$(jq -r '.outbound_preset // ""' <<<"$split")"
  current_source="${outbound_preset:-独立配置}"
  cat <<EOF
出口来源（当前：${current_source}）：
  1. 保持不变（默认）
  2. 选择预置出口
  0. 取消编辑
EOF
  read_menu_choice '请选择 [1]：' '0,1,2' 1 '请输入 1、2 或 0' || return 1
  choice="$PROMPT_VALUE"
  case "$choice" in
    1) upstream="$(jq -c '.upstream' <<<"$split")";;
    2) prompt_select_outbound_preset '选择新的预置出口' || { MENU_RETURNED=true; return 0; }; outbound_preset="$SELECTED_OUTBOUND_PRESET"; upstream="$SELECTED_OUTBOUND_UPSTREAM";;
    0) MENU_RETURNED=true; return 0;;
  esac
  current_out="$(jq -r '.outbound_tag // ("managed-out-" + .name)' <<<"$split")"
  out_tag="$current_out"
  printf '\n修改预览：\n'
  printf '  名称：%s（保持不变）\n' "$name"
  printf '  规则来源：%s\n' "${rule_preset:-独立配置}"
  printf '  范围：%s\n' "$(if [[ "$scope" == all ]]; then echo 全部用户; else echo "用户:$user"; fi)"
  printf '  出口来源：%s\n' "${outbound_preset:-独立配置}"
  read -r -p '确认检查并保存？[y/N]：' answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo "已取消修改。"; return 0; }
  if ! cmd_split_edit "$name" "$url" "$scope" "$user" "$upstream" "$out_tag" "$rule_preset" "$outbound_preset"; then
    echo '分流修改没有保存，原有配置继续使用。'
    return 0
  fi
}

prompt_move_split() {
  local name count current position answer
  prepare_core
  prompt_select_split all "调整分流顺序" || return 0
  name="$SELECTED_SPLIT_NAME"
  count="$(jq '.splits | length' "$STATE_FILE")"
  current="$(jq -r --arg name "$name" '.splits | to_entries[] | select(.value.name == $name) | (.key + 1)' "$STATE_FILE")"
  printf '\n当前顺序：第 %s 条；可选 1-%s（越靠前越优先使用）。\n' "$current" "$count"
  while true; do
    read -r -p '移动到第几条（留空保持，输入 0 返回）：' position
    [[ -n "$position" ]] || { echo "顺序未变化。"; return 0; }
    [[ "$position" != 0 ]] || { MENU_RETURNED=true; return 0; }
    if [[ "$position" =~ ^[0-9]+$ ]] && ((position >= 1 && position <= count)); then break; fi
    printf '输入无效：请输入 1 到 %s 之间的数字。\n' "$count"
  done
  read -r -p "确认将 $name 移动到第 $position 条？[y/N]：" answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo "已取消调整。"; return 0; }
  cmd_split_move "$name" "$position"
}

outbound_preset_management_menu() {
  while true; do
    prepare_menu_screen
    ui_menu_begin
    ui_header '预置出口管理' '保存常用出口，需要分流选择后才会生效'
    ui_section '查看与维护'
    ui_menu_items list '查看预置出口' add '添加预置出口' edit '修改预置出口'
    printf '\n'
    ui_section '危险操作'
    printf '%s' "$UI_RED"
    ui_menu_items remove '删除预置出口'
    printf '%s' "$UI_RESET"
    ui_back_item '返回分流管理'
    ui_menu_select || return 0
    case "$UI_MENU_ACTION" in
      list) prepare_core; print_outbound_preset_list; pause_menu;;
      add) MENU_RETURNED=false; prompt_add_outbound_preset; [[ "$MENU_RETURNED" == true ]] || pause_menu;;
      edit) MENU_RETURNED=false; prompt_edit_outbound_preset; [[ "$MENU_RETURNED" == true ]] || pause_menu;;
      remove) MENU_RETURNED=false; prompt_remove_outbound_preset; [[ "$MENU_RETURNED" == true ]] || pause_menu;;
      back) return 0;;
    esac
  done
}

rule_preset_management_menu() {
  while true; do
    prepare_menu_screen
    ui_menu_begin
    ui_header '预置规则管理' '保存常用规则集，需要分流选择后才会生效'
    ui_section '查看与维护'
    ui_menu_items list '查看预置规则' add '添加预置规则' edit '修改预置规则'
    printf '\n'
    ui_section '危险操作'
    printf '%s' "$UI_RED"
    ui_menu_items remove '删除预置规则'
    printf '%s' "$UI_RESET"
    ui_back_item '返回分流管理'
    ui_menu_select || return 0
    case "$UI_MENU_ACTION" in
      list) prepare_core; print_rule_preset_list; pause_menu;;
      add) MENU_RETURNED=false; prompt_add_rule_preset; [[ "$MENU_RETURNED" == true ]] || pause_menu;;
      edit) MENU_RETURNED=false; prompt_edit_rule_preset; [[ "$MENU_RETURNED" == true ]] || pause_menu;;
      remove) MENU_RETURNED=false; prompt_remove_rule_preset; [[ "$MENU_RETURNED" == true ]] || pause_menu;;
      back) return 0;;
    esac
  done
}

split_management_menu() {
  ensure_management_environment_ready || return 0
  while true; do
    prepare_menu_screen
    ui_menu_begin
    ui_header '分流管理' '规则、出口与验证'
    ui_section '查看与验证'
    ui_menu_items \
      list '查看分流' details '查看分流详情' \
      diagnose '验证分流是否生效'
    printf '\n'
    ui_section '配置与状态'
    ui_menu_items \
      add '增加分流' edit '编辑分流' \
      move '调整分流顺序' disable '停用分流' \
      enable '启用分流'
    printf '\n'
    ui_section '预置内容（保存后不会自动生效）'
    ui_menu_items outbound_presets '预置出口管理' rule_presets '预置规则管理'
    printf '\n'
    ui_section '危险操作'
    printf '%s' "$UI_RED"
    ui_menu_items remove '删除分流'
    printf '%s' "$UI_RESET"
    ui_back_item '返回主菜单'
    ui_menu_select || return 0
    case "$UI_MENU_ACTION" in
      add) MENU_RETURNED=false; prompt_add_split; [[ "$MENU_RETURNED" == true ]] || pause_menu;;
      remove) MENU_RETURNED=false; prompt_split_action remove all; [[ "$MENU_RETURNED" == true ]] || pause_menu;;
      list) prepare_core; cmd_split_list; pause_menu;;
      details) MENU_RETURNED=false; prompt_split_details; [[ "$MENU_RETURNED" == true ]] || pause_menu;;
      edit) MENU_RETURNED=false; prompt_edit_split; [[ "$MENU_RETURNED" == true ]] || pause_menu;;
      move) MENU_RETURNED=false; prompt_move_split; [[ "$MENU_RETURNED" == true ]] || pause_menu;;
      disable) MENU_RETURNED=false; prompt_split_action disable active; [[ "$MENU_RETURNED" == true ]] || pause_menu;;
      enable) MENU_RETURNED=false; prompt_split_action enable disabled; [[ "$MENU_RETURNED" == true ]] || pause_menu;;
      diagnose) MENU_RETURNED=false; prompt_split_diagnostic; [[ "$MENU_RETURNED" == true ]] || pause_menu;;
      outbound_presets) outbound_preset_management_menu;;
      rule_presets) rule_preset_management_menu;;
      back) return 0;;
    esac
  done
}
