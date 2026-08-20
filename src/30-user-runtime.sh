
check_singbox_and_restart() {
  ensure_safe_ssh_for_kernel_restart rollback || return 1
  kernel_check_config "$SINGBOX_CONFIG" || return 1
  kernel_service_reset_failed
  kernel_service_restart || return 1
  if ! kernel_service_is_active; then
    log "错误：sing-box 重启后未处于 active 状态"
    return 1
  fi
}

user_exists() {
  jq -e --arg name "$1" '.users[] | select(.name == $name)' "$STATE_FILE" >/dev/null
}

port_in_state() {
  jq -e --argjson port "$1" '.users[] | (if (.endpoints | type) == "array" then .endpoints[] else {port:.port} end) | select(.port == $port)' "$STATE_FILE" >/dev/null
}

tag_exists_in_config() {
  local tag="$1"
  kernel_normalized_config |
    jq -e --arg tag "$tag" '.inbounds[]? | select(.tag == $tag)' >/dev/null
}

read_singbox_config_source() {
  local output_name="$1" content=""
  # `read -d ''` reads through EOF without command substitution, so trailing
  # newlines remain part of the snapshot. A successful read means an embedded
  # NUL was found; that is not valid JSON and must be rejected.
  if IFS= read -r -d '' content < "$SINGBOX_CONFIG"; then
    return 1
  elif [[ ! -r "$SINGBOX_CONFIG" ]]; then
    return 1
  fi
  printf -v "$output_name" '%s' "$content"
}

load_new_user_config_snapshot() {
  local json_output_name="$1" source_output_name="$2"
  local source_before snapshot_json
  read_singbox_config_source source_before || return 1
  snapshot_json="$(kernel_normalized_config)" || return 1
  printf -v "$json_output_name" '%s' "$snapshot_json"
  printf -v "$source_output_name" '%s' "$source_before"
}

nfuse_account_exists() {
  nfuse list --json 2>/dev/null | jq -e --arg name "$1" '.[] | select(.name == $name)' >/dev/null
}

nfuse_port_exists() {
  nfuse list --json 2>/dev/null | jq -e --argjson port "$1" \
    '.[] | .ports[]? | select(.start <= $port and .end >= $port)' >/dev/null
}

# 生成 base64 编码的随机密钥，参数是随机字节数。
# 这里刻意不使用代理内核的随机数命令：密钥生成与内核无关，绑在内核上会让
# 每个内核都要各实现一遍。openssl 已是本项目的既有依赖（迁移备份加密与
# AnyTLS 自签证书都在用），语义也与原先一致——参数同为随机字节数，输出同为
# 带填充的标准 base64。
# 去掉换行是因为 openssl 在超过 48 字节时会折行；当前只用到 16 与 32 字节，
# 不触及该边界，但不去掉的话将来改用更长密钥会静默出错。
generate_random_base64() {
  openssl rand -base64 "$1" | tr -d '\n' || return 1
}

generate_ss_password() {
  case "$1" in
    2022-blake3-aes-128-gcm)
      generate_random_base64 16
      ;;
    2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305)
      generate_random_base64 32
      ;;
    *)
      die "脚本只支持 Shadowsocks 2022 方法，当前：$1"
      ;;
  esac
}

generate_st_password() {
  generate_random_base64 32
}

make_user_inbounds() {
  local name="$1" port="$2" st_password="$3" ss_password="$4" method="$5" shadowtls_sni="$6"
  SB_JQ_ST_PASSWORD="$st_password" SB_JQ_SS_PASSWORD="$ss_password" jq -n \
    --arg name "$name" \
    --argjson port "$port" \
    --arg method "$method" \
    --arg hs_server "$shadowtls_sni" \
    --argjson hs_port "$HANDSHAKE_PORT" \
    --argjson strict "$SHADOWTLS_STRICT_MODE" \
    '[
      {
        "type": "shadowtls",
        "tag": ("st-" + $name),
        "listen": "::",
        "listen_port": $port,
        "version": 3,
        "users": [
          {
            "name": $name,
            "password": $ENV.SB_JQ_ST_PASSWORD
          }
        ],
        "handshake": {
          "server": $hs_server,
          "server_port": $hs_port
        },
        "strict_mode": $strict,
        "detour": ("ss-" + $name)
      },
      {
        "type": "shadowsocks",
        "tag": ("ss-" + $name),
        "network": "tcp",
        "method": $method,
        "password": $ENV.SB_JQ_SS_PASSWORD
      },
      {
        "type": "shadowsocks",
        "tag": ("ss-udp-" + $name),
        "listen": "::",
        "listen_port": $port,
        "network": "udp",
        "method": $method,
        "password": $ENV.SB_JQ_SS_PASSWORD
      }
    ]'
}

make_ss2022_inbound() {
  local name="$1" port="$2" ss_password="$3" method="$4" tag="${5:-ss-$1}"
  SB_JQ_SS_PASSWORD="$ss_password" jq -n \
    --arg name "$name" \
    --arg tag "$tag" \
    --argjson port "$port" \
    --arg method "$method" \
    '[{
      "type": "shadowsocks",
      "tag": $tag,
      "listen": "::",
      "listen_port": $port,
      "method": $method,
      "password": $ENV.SB_JQ_SS_PASSWORD
    }]'
}

build_user_inbound_payload() {
  local mode="$1" protocol="$2" input_path="$3"
  jq -ce --arg mode "$mode" --arg protocol "$protocol" \
    --arg cert_path "$ANYTLS_CERT_FILE" --arg key_path "$ANYTLS_KEY_FILE" \
    --argjson handshake_port "$HANDSHAKE_PORT" --argjson strict_mode "$SHADOWTLS_STRICT_MODE" '
    def required_string: if type == "string" and length > 0 then . else error("required string is missing") end;
    def required_number: if type == "number" then . else error("required number is missing") end;
    def normalized_user_endpoints($user):
      if ($user.endpoints | type) == "array" then $user.endpoints
      elif ($user.protocol // "ss2022") == "anytls" then
        [{protocol:"anytls",port:$user.port,anytls_password:$user.anytls_password,tls_sni:$user.tls_sni}]
      else
        [{protocol:"ss2022",transport:($user.transport // "shadowtls"),port:$user.port,
          shadowtls_password:$user.shadowtls_password,ss2022_password:$user.ss2022_password,
          method:$user.method,shadowtls_sni:$user.shadowtls_sni}]
      end;
    def normalized_rebuild_endpoints($user):
      if ($user.endpoints | type) == "array" then $user.endpoints
      elif ($user.protocol // "ss2022") == "anytls" then
        [{protocol:"anytls",port:$user.port,anytls_password:$user.anytls_password,tls_sni:$user.tls_sni}]
      else
        [{protocol:"ss2022",transport:"shadowtls",port:$user.port,
          shadowtls_password:$user.shadowtls_password,ss2022_password:$user.ss2022_password,
          method:$user.method,shadowtls_sni:$user.shadowtls_sni}]
      end;
    def endpoint_inbounds($name; $has_legacy; $handshake_port; $strict_mode):
      . as $endpoint |
      ($endpoint.port | required_number) as $port |
      ($endpoint.protocol | required_string) as $protocol |
      if $protocol == "anytls" then
        ($endpoint.anytls_password | required_string) as $password |
        [{"type":"anytls","tag":("anytls-" + $name),"listen":"::","listen_port":$port,
          "users":[{"name":$name,"password":$password}],
          "tls":{"enabled":true,"certificate_path":$cert_path,"key_path":$key_path}}]
      elif $protocol == "ss2022" then
        ($endpoint.transport // "shadowtls") as $transport |
        if ($transport == "direct" or $transport == "shadowtls") then . else error("unsupported SS2022 transport") end |
        ($endpoint.ss2022_password | required_string) as $ss_password |
        ($endpoint.method | required_string) as $method |
        if $transport == "direct" then
          [{"type":"shadowsocks","tag":((if $has_legacy then "ss-direct-" else "ss-" end) + $name),
            "listen":"::","listen_port":$port,"method":$method,"password":$ss_password}]
        else
          ($endpoint.shadowtls_password | required_string) as $st_password |
          ($endpoint.shadowtls_sni | required_string) as $shadowtls_sni |
          [{"type":"shadowtls","tag":("st-" + $name),"listen":"::","listen_port":$port,"version":3,
            "users":[{"name":$name,"password":$st_password}],
            "handshake":{"server":$shadowtls_sni,"server_port":$handshake_port},
            "strict_mode":$strict_mode,"detour":("ss-" + $name)},
           {"type":"shadowsocks","tag":("ss-" + $name),"network":"tcp","method":$method,"password":$ss_password},
           {"type":"shadowsocks","tag":("ss-udp-" + $name),"listen":"::","listen_port":$port,
            "network":"udp","method":$method,"password":$ss_password}]
        end
      else error("unsupported endpoint protocol") end;
    def user_inbounds($user; $handshake_port; $strict_mode):
      ($user.name | required_string) as $name |
      normalized_user_endpoints($user) as $endpoints |
      select(($endpoints | length) > 0) |
      any($endpoints[]; .protocol == "ss2022" and .transport == "shadowtls") as $has_legacy |
      [$endpoints[] | endpoint_inbounds($name; $has_legacy; $handshake_port; $strict_mode)[]];
    if $mode == "user" then
      user_inbounds(.; $handshake_port; $strict_mode)
    elif $mode == "rebuild" then
      if (.users | type) != "array" then {legacy_fallback:true}
      else
        [
          .users[] as $user |
          normalized_rebuild_endpoints($user) as $endpoints |
          $endpoints[] | select(.protocol == $protocol) as $endpoint |
          {user:$user,endpoint:$endpoint,
           has_legacy:(any($user.endpoints[]?; .protocol == "ss2022" and .transport == "shadowtls"))}
        ] as $candidates |
        if any($candidates[];
          (.user.name == null or .user.name == false or
           (.user.name | type) == "object" or (.user.name | type) == "array") or
          (.user.status == null or .user.status == false or
           (.user.status | type) == "object" or (.user.status | type) == "array"))
        then {legacy_fallback:true}
        else
          [$candidates[] |
            (.user.name | tostring) as $name |
            (.user.status | tostring) as $status |
            {name:$name,status:$status,endpoint:.endpoint,has_legacy:.has_legacy}
          ] as $rows |
          {
            managed_tags:([
              $rows[] |
              if $protocol == "anytls" then "anytls-" + .name
              else "st-" + .name, "ss-" + .name, "ss-direct-" + .name, "ss-udp-" + .name, "snell-" + .name end
            ]),
            inbounds:([
              $rows[] | select(.status == "active") | . as $row |
              $row.endpoint | endpoint_inbounds($row.name; $row.has_legacy; $handshake_port; $strict_mode)[]
            ])
          }
        end
      end
    else
      error("unsupported inbound payload mode")
    end
  ' "$input_path"
}

rebuild_protocol_inbounds_with_shell_tools() {
  local protocol="$1" row name status endpoint fragment direct_tag fragments='[]' managed_tags_json='[]'
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    name="$(jq -er '.name' <<<"$row")" || return 1
    status="$(jq -er '.status' <<<"$row")" || return 1
    endpoint="$(jq -ec '.endpoint' <<<"$row")" || return 1
    if [[ "$protocol" == anytls ]]; then
      managed_tags_json="$(jq -c --arg tag "anytls-$name" '. + [$tag]' <<<"$managed_tags_json")" || return 1
    else
      managed_tags_json="$(jq -c --arg st "st-$name" --arg ss "ss-$name" --arg ss_direct "ss-direct-$name" \
        --arg ss_udp "ss-udp-$name" --arg sn "snell-$name" '. + [$st,$ss,$ss_direct,$ss_udp,$sn]' <<<"$managed_tags_json")" || return 1
    fi
    if [[ "$status" == active ]]; then
      direct_tag=""
      if [[ "$(jq -r '.has_legacy_ss2022 // false' <<<"$row")" == true &&
            "$(jq -r '.protocol == "ss2022" and .transport == "direct"' <<<"$endpoint")" == true ]]; then
        direct_tag="ss-direct-$name"
      fi
      fragment="$(make_endpoint_inbounds_from_state "$name" "$endpoint" "$direct_tag")" || return 1
      fragments="$(SB_JQ_CURRENT="$fragments" SB_JQ_ADDED="$fragment" jq -cn \
        '($ENV.SB_JQ_CURRENT | fromjson) as $current | ($ENV.SB_JQ_ADDED | fromjson) as $added | $current + $added')" || return 1
    fi
  done < <(jq -c --arg protocol "$protocol" '
    .users[] as $user |
    (if ($user.endpoints | type) == "array" then $user.endpoints[]
     elif ($user.protocol // "ss2022") == "anytls" then
       {protocol:"anytls",port:$user.port,anytls_password:$user.anytls_password,tls_sni:$user.tls_sni}
     else
       {protocol:"ss2022",transport:"shadowtls",port:$user.port,shadowtls_password:$user.shadowtls_password,
        ss2022_password:$user.ss2022_password,method:$user.method,shadowtls_sni:$user.shadowtls_sni}
     end) |
    select(.protocol == $protocol) |
    {name:$user.name,status:$user.status,endpoint:.,
     has_legacy_ss2022:(any($user.endpoints[]?; .protocol == "ss2022" and .transport == "shadowtls"))}
  ' "$STATE_FILE")
  SB_JQ_NEW_INBOUNDS="$fragments" rewrite_singbox_config '
    ($ENV.SB_JQ_NEW_INBOUNDS | fromjson) as $new_inbounds |
    .inbounds = ([((.inbounds // [])[]) |
      .tag as $tag | select(($managed_tags | index($tag)) == null)] + $new_inbounds)
  ' --argjson managed_tags "$managed_tags_json"
}

rewrite_singbox_config() {
  local filter="$1" config_dir tmp normalized
  shift
  config_dir="$(dirname "$SINGBOX_CONFIG")"
  tmp="$(mktemp "$config_dir/.config.XXXXXX")" || return 1
  register_temp_path "$tmp"
  normalized="$(mktemp "$config_dir/.normalized.XXXXXX")" || {
    rm -f -- "$tmp"
    return 1
  }
  register_temp_path "$normalized"
  if ! kernel_normalized_config > "$normalized"; then
    rm -f -- "$tmp" "$normalized"
    printf '错误：无法解析或格式化 sing-box 配置：%s\n' "$SINGBOX_CONFIG" >&2
    return 1
  fi
  if ! jq "$@" "$filter" "$normalized" > "$tmp"; then
    rm -f -- "$tmp" "$normalized"
    printf '错误：无法生成新的 sing-box 配置\n' >&2
    return 1
  fi
  rm -f -- "$normalized" || return 1
  unregister_temp_path "$normalized" || return 1
  if ! chmod --reference="$SINGBOX_CONFIG" "$tmp" 2>/dev/null; then
    if ! chmod 600 "$tmp"; then
      rm -f -- "$tmp"
      return 1
    fi
  fi
  chown --reference="$SINGBOX_CONFIG" "$tmp" 2>/dev/null || true
  if ! mv -- "$tmp" "$SINGBOX_CONFIG"; then
    rm -f -- "$tmp"
    return 1
  fi
  unregister_temp_path "$tmp" || return 1
}

append_inbounds_from_new_user_snapshot() {
  local config_json="$1" expected_source="$2" fragment="$3"
  local config_dir current_source tmp
  config_dir="$(dirname "$SINGBOX_CONFIG")" || return 1
  tmp="$(mktemp "$config_dir/.config.XXXXXX")" || return 1
  register_temp_path "$tmp" || { rm -f -- "$tmp" || true; return 1; }
  if ! SB_JQ_NEW_INBOUNDS="$fragment" jq '
    ($ENV.SB_JQ_NEW_INBOUNDS | fromjson) as $new_inbounds |
    .inbounds = ((.inbounds // []) + $new_inbounds)
  ' <<<"$config_json" > "$tmp"; then
    if rm -f -- "$tmp"; then
      unregister_temp_path "$tmp" || return 1
    fi
    printf '错误：无法生成新的 sing-box 配置\n' >&2
    return 1
  fi
  if ! chmod --reference="$SINGBOX_CONFIG" "$tmp" 2>/dev/null; then
    if ! chmod 600 "$tmp"; then
      if rm -f -- "$tmp"; then
        unregister_temp_path "$tmp" || return 1
      fi
      return 1
    fi
  fi
  chown --reference="$SINGBOX_CONFIG" "$tmp" 2>/dev/null || true
  read_singbox_config_source current_source || {
    if rm -f -- "$tmp"; then
      unregister_temp_path "$tmp" || return 1
    fi
    return 1
  }
  if [[ "$current_source" != "$expected_source" ]]; then
    if rm -f -- "$tmp"; then
      unregister_temp_path "$tmp" || return 1
    fi
    printf '错误：sing-box 配置在新增用户预检后发生变化，请重新操作\n' >&2
    return 1
  fi
  if ! mv -- "$tmp" "$SINGBOX_CONFIG"; then
    if rm -f -- "$tmp"; then
      unregister_temp_path "$tmp" || return 1
    fi
    return 1
  fi
  unregister_temp_path "$tmp" || return 1
}

append_inbounds() {
  local fragment="$1"
  SB_JQ_NEW_INBOUNDS="$fragment" rewrite_singbox_config \
    '($ENV.SB_JQ_NEW_INBOUNDS | fromjson) as $new_inbounds |
     .inbounds = ((.inbounds // []) + $new_inbounds)'
}

remove_user_inbounds() {
  local name="$1"
  rewrite_singbox_config \
    '.inbounds = [(.inbounds // [])[] | select(.tag != $st and .tag != $ss and .tag != $ss_direct and .tag != $ss_udp and .tag != $at and .tag != $sn)]' \
    --arg st "st-$name" --arg ss "ss-$name" --arg ss_direct "ss-direct-$name" \
    --arg ss_udp "ss-udp-$name" --arg at "anytls-$name" --arg sn "snell-$name"
}

replace_user_inbounds() {
  local name="$1" fragment="$2"
  SB_JQ_NEW_INBOUNDS="$fragment" rewrite_singbox_config \
     '($ENV.SB_JQ_NEW_INBOUNDS | fromjson) as $new_inbounds |
     .inbounds = ([((.inbounds // [])[]) | select(.tag != $st and .tag != $ss and .tag != $ss_direct and .tag != $ss_udp and .tag != $at and .tag != $sn)] + $new_inbounds)' \
    --arg st "st-$name" --arg ss "ss-$name" --arg ss_direct "ss-direct-$name" \
    --arg ss_udp "ss-udp-$name" --arg at "anytls-$name" --arg sn "snell-$name"
}

rebuild_protocol_inbounds() {
  local protocol="$1" rebuild_payload
  rebuild_payload="$(build_user_inbound_payload rebuild "$protocol" "$STATE_FILE")" || return 1
  if [[ "$rebuild_payload" == '{"legacy_fallback":true}' ]]; then
    rebuild_protocol_inbounds_with_shell_tools "$protocol"
    return
  fi
  SB_JQ_PROTOCOL_REBUILD="$rebuild_payload" rewrite_singbox_config '
    ($ENV.SB_JQ_PROTOCOL_REBUILD | fromjson) as $payload |
    .inbounds = ([((.inbounds // [])[]) |
      .tag as $tag | select(($payload.managed_tags | index($tag)) == null)] + $payload.inbounds)
  '
}

ss2022_udp_inbounds_are_current() {
  local split rows user user_status rule_tag inbound
  jq -e --slurpfile config "$SINGBOX_CONFIG" '
    .users as $users |
    all($users[]?;
        . as $user |
        ([if (.endpoints | type) == "array" then .endpoints[]
          elif (.protocol // "ss2022") == "ss2022" then
            {protocol:"ss2022",transport:"shadowtls",port:.port,ss2022_password:.ss2022_password,method:.method}
          else empty end | select(.protocol == "ss2022" and (.transport // "shadowtls") == "shadowtls")] | first) as $endpoint |
        if $endpoint != null and .status == "active" then
          any($config[0].inbounds[]?;
            .tag == ("ss-udp-" + $user.name) and
            .type == "shadowsocks" and
            .listen_port == $endpoint.port and
            .network == "udp" and
            .method == $endpoint.method and
            .password == $endpoint.ss2022_password)
        elif $endpoint != null then
          all($config[0].inbounds[]?; .tag != ("ss-udp-" + $user.name))
        else true end)
  ' "$STATE_FILE" >/dev/null || return 1
  rows="$(jq -c '.splits[]? | select(.status == "active" and .scope == "user")' "$STATE_FILE")" || return 1
  while IFS= read -r split; do
    [[ -n "$split" ]] || continue
    user="$(jq -r '.user' <<<"$split")" || return 1
    user_status="$(jq -r --arg name "$user" 'first(.users[]? | select(.name == $name) | .status) // "missing"' "$STATE_FILE")" || return 1
    [[ "$user_status" == active ]] || continue
    jq -e --arg name "$user" '.users[]? | select(.name == $name) |
      if (.endpoints | type) == "array" then any(.endpoints[]; .protocol == "ss2022" and (.transport // "shadowtls") == "shadowtls")
      else (.protocol // "ss2022") == "ss2022" end' "$STATE_FILE" >/dev/null || continue
    rule_tag="$(split_runtime_rule_tag_from_json "$split")" || return 1
    inbound="ss-udp-$user"
    jq -e --arg rule "$rule_tag" --arg inbound "$inbound" '
      any(.route.rules[]?; .rule_set == $rule and ((.inbound // []) | index($inbound)))
    ' "$SINGBOX_CONFIG" >/dev/null || return 1
  done <<<"$rows"
}

migrate_legacy_ss2022_udp_inbounds() {
  [[ -r "$CONF_FILE" ]] || return 0
  command -v jq >/dev/null || return 0
  command -v flock >/dev/null || return 0
  load_runtime_config || return 1
  # 这是一次性整理历史 sing-box 数据的流程，其它内核的部署里没有对应的历史包袱。
  # 显式判断而不是依赖「sing-box 文件恰好不存在」——那种依赖在一台两个内核
  # 的二进制都还留着的机器上会失效。
  [[ "$PROXY_KERNEL" == singbox ]] || return 0
  [[ -f "$STATE_FILE" && -f "$SINGBOX_CONFIG" && -x "$SINGBOX_BIN" && -x "$NFUSE_BIN" && -S "$NFUSE_SOCKET" ]] || return 0
  ss2022_udp_inbounds_are_current && return 0

  exec 9>"$LOCK_FILE" || return 1
  if ! flock -n 9; then
    release_operation_lock
    return 1
  fi
  if ! recover_pending_transaction || ! init_state; then
    release_operation_lock
    return 1
  fi
  if ss2022_udp_inbounds_are_current; then
    release_operation_lock
    return 0
  fi
  if ! ensure_safe_ssh_for_kernel_restart; then
    release_operation_lock
    return 0
  fi
  if ! start_managed_operation migrate-ss2022-udp; then
    release_operation_lock
    return 1
  fi
  if ! run_managed_step rebuild_protocol_inbounds ss2022 ||
     ! run_managed_step rebuild_all_split_configs ||
     ! run_managed_step check_singbox_and_restart ||
     ! finish_managed_operation; then
    release_operation_lock
    return 1
  fi
  log "已为旧版 SS2022 + ShadowTLS 用户启用同端口 UDP 支持"
  release_operation_lock
}

make_anytls_inbound() {
  local name="$1" port="$2" password="$3"
  SB_JQ_PASSWORD="$password" jq -n --arg name "$name" --argjson port "$port" \
    --arg cert_path "$ANYTLS_CERT_FILE" --arg key_path "$ANYTLS_KEY_FILE" \
    '[{"type":"anytls","tag":("anytls-" + $name),"listen":"::","listen_port":$port,"users":[{"name":$name,"password":$ENV.SB_JQ_PASSWORD}],"tls":{"enabled":true,"certificate_path":$cert_path,"key_path":$key_path}}]'
}

make_endpoint_inbounds_from_state() {
  local name="$1" endpoint="$2" direct_tag="${3:-}" port protocol transport anytls_password st_password ss_password method shadowtls_sni
  port="$(jq -er '.port | select(type == "number")' <<<"$endpoint")" || return 1
  protocol="$(jq -er '.protocol | select(type == "string" and length > 0)' <<<"$endpoint")" || return 1
  if [[ "$protocol" == anytls ]]; then
    anytls_password="$(jq -er '.anytls_password | select(type == "string" and length > 0)' <<<"$endpoint")" || return 1
    make_anytls_inbound "$name" "$port" "$anytls_password"
  elif [[ "$protocol" == ss2022 ]]; then
    transport="$(jq -er '.transport // "shadowtls" | select(. == "direct" or . == "shadowtls")' <<<"$endpoint")" || return 1
    ss_password="$(jq -er '.ss2022_password | select(type == "string" and length > 0)' <<<"$endpoint")" || return 1
    method="$(jq -er '.method | select(type == "string" and length > 0)' <<<"$endpoint")" || return 1
    if [[ "$transport" == direct ]]; then
      make_ss2022_inbound "$name" "$port" "$ss_password" "$method" "${direct_tag:-ss-$name}"
      return
    fi
    st_password="$(jq -er '.shadowtls_password | select(type == "string" and length > 0)' <<<"$endpoint")" || return 1
    shadowtls_sni="$(jq -er '.shadowtls_sni | select(type == "string" and length > 0)' <<<"$endpoint")" || return 1
    make_user_inbounds \
      "$name" \
      "$port" \
      "$st_password" \
      "$ss_password" \
      "$method" \
      "$shadowtls_sni"
  else
    return 1
  fi
}

make_user_inbounds_from_state() {
  local user="$1"
  build_user_inbound_payload user "" - <<<"$user"
}

state_add_user() {
  local name="$1" port="$2" ss_password="$3" limit="$4" anchor="$5" metered="$6" expires_at="$7" method="$8"
  SB_JQ_SS_PASSWORD="$ss_password" atomic_state_update '.users += [{
      name: $name,
      port: $port,
      protocol: "ss2022",
      transport: "direct",
      ss2022_password: $ENV.SB_JQ_SS_PASSWORD,
      method: $method,
      metered: $metered,
      expires_at: (if $expires_at == "" then null else $expires_at end),
      limit_gib: (if $metered then ($limit | tonumber) else null end),
      billing_anchor: (if $metered then ($anchor | tonumber) else null end),
      usage_offset_bytes: 0,
      status: "active",
      created_at: $created_at,
      endpoints: [{
        protocol: "ss2022",
        transport: "direct",
        port: $port,
        ss2022_password: $ENV.SB_JQ_SS_PASSWORD,
        method: $method
      }]
    }]' \
    --arg name "$name" \
    --argjson port "$port" \
    --arg method "$method" \
    --arg created_at "$(date -Iseconds)" \
    --arg limit "$limit" \
    --arg anchor "$anchor" \
    --argjson metered "$metered" \
    --arg expires_at "$expires_at"
}

state_add_anytls() {
  SB_JQ_PASSWORD="$3" atomic_state_update '.users += [{name:$name,port:$port,protocol:"anytls",anytls_password:$ENV.SB_JQ_PASSWORD,tls_sni:$tls_sni,metered:$metered,expires_at:(if $expires_at=="" then null else $expires_at end),limit_gib:(if $metered then ($limit|tonumber) else null end),billing_anchor:(if $metered then ($anchor|tonumber) else null end),usage_offset_bytes:0,status:"active",created_at:$created_at,endpoints:[{protocol:"anytls",port:$port,anytls_password:$ENV.SB_JQ_PASSWORD,tls_sni:$tls_sni}]}]' \
    --arg name "$1" --argjson port "$2" --arg created_at "$(date -Iseconds)" \
    --arg limit "$4" --arg anchor "$5" --argjson metered "$6" --arg expires_at "$7" --arg tls_sni "$8"
}

state_add_multi_user() {
  local name="$1" ss_port="$2" anytls_port="$3" ss_password="$4" anytls_password="$5"
  local limit="$6" anchor="$7" metered="$8" expires_at="$9" method="${10}" tls_sni="${11}"
  SB_JQ_SS_PASSWORD="$ss_password" SB_JQ_ANYTLS_PASSWORD="$anytls_password" \
    atomic_state_update '.users += [{
      name:$name,port:$ss_port,protocol:"ss2022",
      transport:"direct",ss2022_password:$ENV.SB_JQ_SS_PASSWORD,method:$method,
      metered:$metered,expires_at:(if $expires_at=="" then null else $expires_at end),
      limit_gib:(if $metered then ($limit|tonumber) else null end),
      billing_anchor:(if $metered then ($anchor|tonumber) else null end),
      usage_offset_bytes:0,status:"active",created_at:$created_at,
      endpoints:[
        {protocol:"ss2022",transport:"direct",port:$ss_port,
         ss2022_password:$ENV.SB_JQ_SS_PASSWORD,method:$method},
        {protocol:"anytls",port:$anytls_port,anytls_password:$ENV.SB_JQ_ANYTLS_PASSWORD,tls_sni:$tls_sni}
      ]
    }]' \
    --arg name "$name" --argjson ss_port "$ss_port" --argjson anytls_port "$anytls_port" \
    --arg limit "$limit" --arg anchor "$anchor" --argjson metered "$metered" --arg expires_at "$expires_at" \
    --arg method "$method" --arg tls_sni "$tls_sni" \
    --arg created_at "$(date -Iseconds)"
}

state_add_user_endpoint() {
  local name="$1" endpoint="$2"
  SB_JQ_ENDPOINT="$endpoint" atomic_state_update '
    (.users[] | select(.name == $name) | .endpoints) += [($ENV.SB_JQ_ENDPOINT | fromjson)]
  ' --arg name "$name"
}

state_remove_user_endpoint() {
  local name="$1" kind="$2"
  atomic_state_update '
    def endpoint_kind:
      if .protocol == "anytls" then "anytls"
      elif .protocol == "ss2022" and .transport == "direct" then "ss2022-direct"
      elif .protocol == "ss2022" and .transport == "shadowtls" then "ss2022-shadowtls"
      else null end;
    .users |= map(
      if .name == $name then
        .endpoints = [.endpoints[] | select(endpoint_kind != $kind)] |
        .endpoints[0] as $primary |
        del(.anytls_password,.tls_sni,.transport,.shadowtls_password,.ss2022_password,.method,.shadowtls_sni) |
        .protocol = $primary.protocol | .port = $primary.port |
        if $primary.protocol == "anytls" then
          .anytls_password = $primary.anytls_password | .tls_sni = $primary.tls_sni
        else
          .transport = $primary.transport |
          .ss2022_password = $primary.ss2022_password |
          .method = $primary.method |
          if $primary.transport == "shadowtls" then
            .shadowtls_password = $primary.shadowtls_password | .shadowtls_sni = $primary.shadowtls_sni
          else . end
        end
      else . end)
  ' --arg name "$name" --arg kind "$kind"
}

state_set_status() {
  atomic_state_update '(.users[] | select(.name == $name) | .status) = $status' \
    --arg name "$1" --arg status "$2"
}

state_set_expiry() {
  atomic_state_update '(.users[] | select(.name == $name) | .expires_at) = $expires_at' \
    --arg name "$1" --arg expires_at "$2"
}

state_set_limit() {
  atomic_state_update '(.users[] | select(.name == $name) | .limit_gib) = ($limit | tonumber)' \
    --arg name "$1" --arg limit "$2"
}

state_add_usage_offset() {
  atomic_state_update '
    (.users[] | select(.name == $name) | .usage_offset_bytes) |=
      ((. // 0) + ($bytes | tonumber))
  ' --arg name "$1" --arg bytes "$2"
}

ensure_self_nfuse_accounts() {
  local nfuse_json rows user name port account owner migrated=0
  nfuse_json="$(nfuse list --json)" || return 1
  jq -e 'type == "array"' <<<"$nfuse_json" >/dev/null || return 1
  rows="$(jq -c '.users[] | select((.metered // (.limit_gib != null)) == false)' "$STATE_FILE")" || return 1
  while IFS= read -r user; do
    [[ -n "$user" ]] || continue
    name="$(jq -er '.name' <<<"$user")" || return 1
    account="$(jq -c --arg name "$name" 'first(.[] | select(.name == $name)) // null' <<<"$nfuse_json")" || return 1
    if [[ "$account" != null ]]; then
      if [[ "$(jq -r '.tier' <<<"$account")" != c ]]; then
        log "提醒：自用用户 ${name} 的流量记录类型不正确，请运行「服务与配置检查」"
      else
        while IFS= read -r port; do
          [[ -n "$port" ]] || continue
          if ! jq -e --argjson port "$port" '.ports[]? | select(.start <= $port and .end >= $port)' <<<"$account" >/dev/null; then
            log "提醒：自用用户 ${name} 的端口 ${port} 尚未接入流量统计，请运行「服务与配置检查」"
          fi
        done < <(jq -r 'if (.endpoints | type) == "array" then .endpoints[].port else .port end' <<<"$user")
      fi
      continue
    fi
    while IFS= read -r port; do
      [[ -n "$port" ]] || continue
      owner="$(jq -r --argjson port "$port" 'first(.[] | select(any(.ports[]?; .start <= $port and .end >= $port)) | .name) // empty' <<<"$nfuse_json")" || return 1
      if [[ -n "$owner" ]]; then
        log "提醒：自用用户 ${name} 的端口 ${port} 已由流量记录 ${owner} 使用，请运行「服务与配置检查」"
        account=conflict
        break
      fi
    done < <(jq -r 'if (.endpoints | type) == "array" then .endpoints[].port else .port end' <<<"$user")
    [[ "$account" != conflict ]] || continue
    start_managed_operation "migrate-self-usage:$name" || return 1
    run_managed_step nfuse add "$name" --tier c --limit 0 --anchor 1 || return 1
    while IFS= read -r port; do
      [[ -n "$port" ]] || continue
      run_managed_step nfuse port add "$name" "$port" || return 1
    done < <(jq -r 'if (.endpoints | type) == "array" then .endpoints[].port else .port end' <<<"$user")
    run_managed_step nfuse persist || return 1
    finish_managed_operation || return 1
    migrated=$((migrated + 1))
    nfuse_json="$(nfuse list --json)" || return 1
  done <<<"$rows"
  ((migrated == 0)) || log "已为 ${migrated} 个既有自用用户启用不限额流量统计"
}

state_replace_user() {
  SB_JQ_USER="$2" atomic_state_update \
    'def sync_primary_endpoint:
       .endpoints[0] as $primary |
       del(.anytls_password,.tls_sni,.transport,.shadowtls_password,.ss2022_password,.method,.shadowtls_sni) |
       .protocol = $primary.protocol | .port = $primary.port |
       if $primary.protocol == "anytls" then
         .anytls_password = $primary.anytls_password | .tls_sni = $primary.tls_sni
       else
         .transport = ($primary.transport // "shadowtls") | .ss2022_password = $primary.ss2022_password | .method = $primary.method |
         if .transport == "shadowtls" then
           .shadowtls_password = $primary.shadowtls_password | .shadowtls_sni = $primary.shadowtls_sni
         else . end
       end;
     .users = [.users[] | if .name == $name then (($ENV.SB_JQ_USER | fromjson) | sync_primary_endpoint) else . end]' \
    --arg name "$1"
}

state_set_protocol_sni() {
  local protocol="$1" sni="$2"
  atomic_state_update '
    .users |= map(
      if (.endpoints | type) == "array" then
        .endpoints |= map(
          if $protocol == "anytls" then
            if .protocol == "anytls" then .tls_sni = $sni else . end
          else
            if .protocol == "ss2022" and (.transport // "shadowtls") == "shadowtls" then .shadowtls_sni = $sni else . end
          end)
      else . end |
      if (.protocol // "ss2022") == $protocol then
        if $protocol == "anytls" then .tls_sni = $sni
        elif (.transport // "shadowtls") == "shadowtls" then .shadowtls_sni = $sni
        else . end
      else . end)
  ' --arg protocol "$protocol" --arg sni "$sni"
}

state_remove_user() {
  atomic_state_update '.users = [.users[] | select(.name != $name)]' --arg name "$1"
}

get_user_json() {
  jq -c --arg name "$1" '.users[] | select(.name == $name)' "$STATE_FILE"
}

anytls_certificate_ready() {
  [[ -f "$ANYTLS_CERT_FILE" && -f "$ANYTLS_KEY_FILE" ]]
}

check_new_user_conflicts() {
  local protocol="$1" name="$2" port="$3" config_output_name="${4:-}" source_output_name="${5:-}"
  local config_json source_snapshot current_source tags_json conflict_tag
  case "$protocol" in
    ss2022|anytls) ;;
    *) die "内部错误：不支持的新增用户协议：$protocol";;
  esac
  [[ -n "$config_output_name" && -n "$source_output_name" ]] ||
    die "内部错误：新增用户冲突检查缺少配置快照接收变量"
  user_exists "$name" && die "用户已存在：$name"
  if port_in_state "$port"; then
    if [[ "$protocol" == ss2022 ]]; then
      die "端口已被脚本记录占用：$port"
    else
      die "端口已占用"
    fi
  fi
  if port_is_listening "$port"; then
    if [[ "$protocol" == ss2022 ]]; then
      die "端口已被其他服务监听：$port"
    else
      die "端口已被监听"
    fi
  fi
  config_json="${!config_output_name:-}"
  source_snapshot="${!source_output_name:-}"
  if [[ -n "$config_json" && -n "$source_snapshot" ]]; then
    read_singbox_config_source current_source || die "无法解析或格式化 sing-box 配置：$SINGBOX_CONFIG"
    if [[ "$current_source" != "$source_snapshot" ]]; then
      config_json=""
      source_snapshot=""
    fi
  fi
  if [[ -z "$config_json" || -z "$source_snapshot" ]]; then
    load_new_user_config_snapshot config_json source_snapshot ||
      die "无法解析或格式化 sing-box 配置：$SINGBOX_CONFIG"
    printf -v "$config_output_name" '%s' "$config_json"
    printf -v "$source_output_name" '%s' "$source_snapshot"
  fi
  if [[ "$protocol" == ss2022 ]]; then
    tags_json="[\"st-$name\",\"ss-$name\",\"ss-udp-$name\"]"
  else
    tags_json="[\"anytls-$name\"]"
  fi
  conflict_tag="$(jq -r --argjson tags "$tags_json" '
    [$tags[] as $wanted | select(any(.inbounds[]?; .tag == $wanted)) | $wanted][0] // empty
  ' <<<"$config_json")" || die "无法解析或格式化 sing-box 配置：$SINGBOX_CONFIG"
  if [[ -n "$conflict_tag" ]]; then
    if [[ "$protocol" == ss2022 ]]; then
      die "sing-box 已存在 tag：$conflict_tag"
    else
      die "tag 已存在"
    fi
  fi
  if [[ "$protocol" == anytls ]]; then
    anytls_certificate_ready || die "AnyTLS 证书不存在，请先重新安装环境"
  fi
  if nfuse_account_exists "$name"; then
    if [[ "$protocol" == ss2022 ]]; then
      die "同名流量记录已存在，请运行「服务与配置检查」：$name"
    else
      die "同名流量记录已存在，请运行「服务与配置检查」"
    fi
  fi
  if nfuse_port_exists "$port"; then
    if [[ "$protocol" == ss2022 ]]; then
      die "Nfuse 已管理端口：$port"
    else
      die "该端口已被其他用户的流量统计占用"
    fi
  fi
}

register_new_user_nfuse() {
  local name="$1" port="$2" metered="$3" limit="$4" anchor="$5"
  register_new_user_nfuse_ports "$name" "$metered" "$limit" "$anchor" "$port"
}

register_new_user_nfuse_ports() {
  local name="$1" metered="$2" limit="$3" anchor="$4" port
  shift 4
  if [[ "$metered" == true ]]; then
    run_managed_step nfuse add "$name" --tier a --limit "$limit" --anchor "$anchor" || return 1
  else
    run_managed_step nfuse add "$name" --tier c --limit 0 --anchor 1 || return 1
  fi
  for port in "$@"; do
    run_managed_step nfuse port add "$name" "$port" || return 1
  done
  run_managed_step nfuse persist || return 1
}

check_new_endpoint_conflicts() {
  local kind="$1" name="$2" port="$3" has_legacy=false
  validate_port "$port"
  port_in_state "$port" && die "端口已被脚本记录占用：$port"
  port_is_listening "$port" && die "端口已被其他服务监听：$port"
  nfuse_port_exists "$port" && die "Nfuse 已管理端口：$port"
  if [[ "$kind" == anytls ]]; then
    anytls_certificate_ready || die "AnyTLS 证书不存在，请先重新安装环境"
    tag_exists_in_config "anytls-$name" && die "sing-box 已存在 tag：anytls-$name"
  else
    jq -e --arg name "$name" 'any(.users[]? | select(.name == $name) | .endpoints[]?;
      .protocol == "ss2022" and .transport == "shadowtls")' "$STATE_FILE" >/dev/null && has_legacy=true
    if [[ "$has_legacy" == true ]]; then
      tag_exists_in_config "ss-direct-$name" && die "sing-box 已存在 tag：ss-direct-$name"
    else
      tag_exists_in_config "st-$name" && die "sing-box 已存在 tag：st-$name"
      tag_exists_in_config "ss-$name" && die "sing-box 已存在 tag：ss-$name"
      tag_exists_in_config "ss-udp-$name" && die "sing-box 已存在 tag：ss-udp-$name"
    fi
  fi
  return 0
}

cmd_add() {
  local mode="$1"; shift
  local name="${1:-}" port="${2:-}" limit="${3:-}" anchor="${4:-}" months="${5:-}" method metered=true expires_at
  if [[ "$mode" == self ]]; then
    (( $# == 3 )) || die "用法：$PROGRAM add-me <用户名> <公网端口> <加密方式>"
    method="$3"
    metered=false
    expires_at=""
  else
    (( $# == 6 )) || die "用法：$PROGRAM add <用户名> <公网端口> <配额GiB> <账单日1-28> <有效期月数> <加密方式>"
    method="$6"
  fi

  validate_name "$name"
  validate_port "$port"
  validate_ss2022_method "$method"
  if [[ "$metered" == true ]]; then
    [[ "$months" =~ ^[1-9][0-9]*$ ]] || die "有效期月数必须是正整数"
    expires_at="$(date -d "+${months} month" '+%Y-%m-%dT%H:%M:%S%z')"
  fi
  if [[ "$metered" == true ]]; then
    validate_limit "$limit"
    validate_anchor "$anchor"
  fi
  local config_snapshot="" config_source=""
  check_new_user_conflicts ss2022 "$name" "$port" config_snapshot config_source

  local ss_password fragment
  ss_password="$(generate_ss_password "$method")" || return 1
  fragment="$(make_ss2022_inbound "$name" "$port" "$ss_password" "$method")" || return 1
  ensure_safe_ssh_for_kernel_restart || return 0
  start_managed_operation "add-user:$name" || return 1

  run_managed_step state_add_user "$name" "$port" "$ss_password" "$limit" "$anchor" "$metered" "$expires_at" "$method" || return 1
  register_new_user_nfuse "$name" "$port" "$metered" "$limit" "$anchor" || return 1
  run_managed_step append_inbounds_from_new_user_snapshot "$config_snapshot" "$config_source" "$fragment" || return 1
  run_managed_step check_singbox_and_restart || return 1

  finish_managed_operation || return 1
  if [[ "$metered" == true ]]; then
    log "用户创建成功：${name}，端口：${port}，每月流量：${limit} GiB，重置日：${anchor}"
  else
    log "自用用户创建成功：${name}，端口：${port}（不限流量，仅统计使用量）"
  fi
  cmd_export "$name"
}

cmd_add_anytls() {
  local mode="$1"; shift
  local name="${1:-}" port="${2:-}" limit="${3:-}" anchor="${4:-}" months="${5:-}" tls_sni metered=true expires_at=""
  if [[ "$mode" == self ]]; then (( $# == 3 )) || die "用法：$PROGRAM add-anytls-me <用户名> <公网端口> <TLS-SNI>"; tls_sni="$3"; metered=false
  else (( $# == 6 )) || die "用法：$PROGRAM add-anytls <用户名> <公网端口> <配额GiB> <账单日> <有效期月数> <TLS-SNI>"; tls_sni="$6"; [[ "$months" =~ ^[1-9][0-9]*$ ]] || die "有效期月数必须是正整数"; expires_at="$(date -d "+${months} month" '+%Y-%m-%dT%H:%M:%S%z')"; validate_limit "$limit"; validate_anchor "$anchor"; fi
  validate_name "$name"
  validate_port "$port"
  validate_shadowtls_sni "$tls_sni"
  local config_snapshot="" config_source=""
  check_new_user_conflicts anytls "$name" "$port" config_snapshot config_source
  local password fragment
  password="$(generate_st_password)"
  fragment="$(make_anytls_inbound "$name" "$port" "$password")"
  ensure_safe_ssh_for_kernel_restart || return 0
  start_managed_operation "add-anytls-user:$name" || return 1
  run_managed_step state_add_anytls "$name" "$port" "$password" "$limit" "$anchor" "$metered" "$expires_at" "$tls_sni" || return 1
  register_new_user_nfuse "$name" "$port" "$metered" "$limit" "$anchor" || return 1
  run_managed_step append_inbounds_from_new_user_snapshot "$config_snapshot" "$config_source" "$fragment" || return 1
  run_managed_step check_singbox_and_restart || return 1
  finish_managed_operation || return 1
  if [[ "$metered" == true ]]; then
    log "AnyTLS 用户创建成功：${name}，端口：${port}"
  else
    log "AnyTLS 自用用户创建成功：${name}，端口：${port}（不限流量，仅统计使用量）"
  fi
  cmd_export "$name"
}

cmd_add_multi() {
  local mode="$1"; shift
  local name="${1:-}" ss_port="${2:-}" anytls_port="${3:-}" limit="${4:-}" anchor="${5:-}" months="${6:-}"
  local method tls_sni metered=true expires_at=""
  if [[ "$mode" == self ]]; then
    (( $# == 5 )) || die "用法：$PROGRAM add-multi-me <用户名> <SS端口> <AnyTLS端口> <加密方式> <AnyTLS-SNI>"
    method="$4"; tls_sni="$5"; metered=false
    limit=""; anchor=""
  else
    (( $# == 8 )) || die "用法：$PROGRAM add-multi <用户名> <SS端口> <AnyTLS端口> <配额GiB> <账单日> <有效期月数> <加密方式> <AnyTLS-SNI>"
    method="$7"; tls_sni="$8"
    [[ "$months" =~ ^[1-9][0-9]*$ ]] || die "有效期月数必须是正整数"
    validate_limit "$limit"
    validate_anchor "$anchor"
    expires_at="$(date -d "+${months} month" '+%Y-%m-%dT%H:%M:%S%z')"
  fi
  validate_name "$name"
  validate_port "$ss_port"
  validate_port "$anytls_port"
  [[ "$ss_port" != "$anytls_port" ]] || die "两个协议必须使用不同端口"
  validate_ss2022_method "$method"
  validate_shadowtls_sni "$tls_sni"
  local config_snapshot="" config_source=""
  check_new_user_conflicts ss2022 "$name" "$ss_port" config_snapshot config_source
  check_new_user_conflicts anytls "$name" "$anytls_port" config_snapshot config_source

  local ss_password anytls_password prospective fragment
  ss_password="$(generate_ss_password "$method")" || return 1
  anytls_password="$(generate_st_password)" || return 1
  prospective="$(SB_JQ_SS_PASSWORD="$ss_password" SB_JQ_ANYTLS_PASSWORD="$anytls_password" jq -cn \
    --arg name "$name" --argjson ss_port "$ss_port" --argjson anytls_port "$anytls_port" \
    --arg method "$method" --arg tls_sni "$tls_sni" '
      {name:$name,status:"active",endpoints:[
        {protocol:"ss2022",transport:"direct",port:$ss_port,
         ss2022_password:$ENV.SB_JQ_SS_PASSWORD,method:$method},
        {protocol:"anytls",port:$anytls_port,anytls_password:$ENV.SB_JQ_ANYTLS_PASSWORD,tls_sni:$tls_sni}
      ]}')" || return 1
  fragment="$(make_user_inbounds_from_state "$prospective")" || return 1
  ensure_safe_ssh_for_kernel_restart || return 0
  start_managed_operation "add-multi-user:$name" || return 1

  # 先登记可回滚的账户状态，再把两个端口纳入同一流量账户，最后才开放认证入口。
  run_managed_step state_add_multi_user "$name" "$ss_port" "$anytls_port" "$ss_password" "$anytls_password" \
    "$limit" "$anchor" "$metered" "$expires_at" "$method" "$tls_sni" || return 1
  register_new_user_nfuse_ports "$name" "$metered" "$limit" "$anchor" "$ss_port" "$anytls_port" || return 1
  run_managed_step append_inbounds_from_new_user_snapshot "$config_snapshot" "$config_source" "$fragment" || return 1
  run_managed_step check_singbox_and_restart || return 1
  finish_managed_operation || return 1

  if [[ "$metered" == true ]]; then
    log "双协议用户创建成功：${name}，SS2022 端口：${ss_port}，AnyTLS 端口：${anytls_port}，共享每月 ${limit} GiB"
  else
    log "双协议自用用户创建成功：${name}，SS2022 端口：${ss_port}，AnyTLS 端口：${anytls_port}（共享不限额统计）"
  fi
  cmd_export "$name"
}

endpoint_kind_label() {
  case "$1" in
    anytls) printf 'AnyTLS\n';;
    ss2022-direct) printf '原生 SS2022\n';;
    ss2022-shadowtls) printf 'SS2022 + ShadowTLS（旧版）\n';;
    *) return 1;;
  esac
}

normalize_user_endpoints_json() {
  jq -c '
    if (.endpoints | type) == "array" then .
    elif (.protocol // "ss2022") == "anytls" then
      .endpoints=[{protocol:"anytls",port:.port,anytls_password:.anytls_password,tls_sni:.tls_sni}]
    else
      .endpoints=[{protocol:"ss2022",transport:(.transport // "shadowtls"),port:.port,
        shadowtls_password:.shadowtls_password,ss2022_password:.ss2022_password,
        method:.method,shadowtls_sni:.shadowtls_sni}]
    end
  ' <<<"$1"
}

cmd_add_user_endpoint() {
  local name="$1" kind="$2" port="$3" method="${4:-}" sni="$5"
  local user status metered expected_tier nfuse_json endpoint prospective fragment password ss_password
  [[ "$kind" != ss2022 ]] || kind=ss2022-direct
  validate_name "$name"
  user_exists "$name" || die "用户不存在：$name"
  user="$(get_user_json "$name")" || return 1
  user="$(normalize_user_endpoints_json "$user")" || return 1
  jq -e '.endpoints | type == "array" and length < 3' <<<"$user" >/dev/null || die "用户已经拥有全部支持的连接入口"
  jq -e --arg kind "$kind" '
    def endpoint_kind:
      if .protocol == "anytls" then "anytls"
      elif .protocol == "ss2022" and .transport == "direct" then "ss2022-direct"
      elif .protocol == "ss2022" and .transport == "shadowtls" then "ss2022-shadowtls"
      else null end;
    all(.endpoints[]; endpoint_kind != $kind)
  ' <<<"$user" >/dev/null || die "用户已经拥有该连接入口"
  case "$kind" in
    ss2022-direct) validate_ss2022_method "$method";;
    anytls) [[ -z "$method" ]] || die "AnyTLS 不支持 SS2022 加密方式";;
    ss2022-shadowtls) die "不再支持新增 ShadowTLS；只能保留或管理已有旧版入口";;
    *) die "不支持的连接入口：$kind";;
  esac
  if [[ "$kind" == anytls ]]; then validate_shadowtls_sni "$sni"; fi
  check_new_endpoint_conflicts "$kind" "$name" "$port"
  status="$(jq -er '.status | select(. == "active" or . == "disabled")' <<<"$user")" || return 1
  metered="$(jq -er '
    (if has("metered") then .metered else (.limit_gib != null) end) |
    select(type == "boolean") | tostring
  ' <<<"$user")" || {
    printf '错误：用户 %s 的流量计费状态无效，请先运行「服务与配置检查」\n' "$name" >&2
    return 1
  }
  expected_tier="$([[ "$metered" == true ]] && echo a || echo c)"
  nfuse_json="$(nfuse list --json)" || die "无法读取流量统计数据，请查看服务状态"
  jq -e --arg name "$name" --arg tier "$expected_tier" '.[] | select(.name == $name and .tier == $tier)' <<<"$nfuse_json" >/dev/null ||
    die "找不到用户 $name 的正确流量记录，请先运行「服务与配置检查」"

  if [[ "$kind" == anytls ]]; then
    password="$(generate_st_password)" || return 1
    endpoint="$(SB_JQ_PASSWORD="$password" jq -cn --argjson port "$port" --arg sni "$sni" \
      '{protocol:"anytls",port:$port,anytls_password:$ENV.SB_JQ_PASSWORD,tls_sni:$sni}')" || return 1
  else
    ss_password="$(generate_ss_password "$method")" || return 1
    endpoint="$(SB_JQ_SS_PASSWORD="$ss_password" jq -cn \
      --argjson port "$port" --arg method "$method" \
      '{protocol:"ss2022",transport:"direct",port:$port,
       ss2022_password:$ENV.SB_JQ_SS_PASSWORD,method:$method}')" || return 1
  fi
  prospective="$(SB_JQ_ENDPOINT="$endpoint" jq -c '.endpoints += [($ENV.SB_JQ_ENDPOINT | fromjson)]' <<<"$user")" || return 1
  if [[ "$status" == active ]]; then
    fragment="$(make_user_inbounds_from_state "$prospective")" || return 1
    ensure_safe_ssh_for_kernel_restart || return 0
  fi
  start_managed_operation "add-user-endpoint:$name:$kind" || return 1
  run_managed_step nfuse port add "$name" "$port" || return 1
  run_managed_step nfuse persist || return 1
  run_managed_step state_add_user_endpoint "$name" "$endpoint" || return 1
  if [[ "$status" == active ]]; then
    run_managed_step replace_user_inbounds "$name" "$fragment" || return 1
    rebuild_user_splits_if_needed "$name" || return 1
    run_managed_step check_singbox_and_restart || return 1
  fi
  finish_managed_operation || return 1
  log "已为用户 ${name} 添加连接入口：$(endpoint_kind_label "$kind")（端口 ${port}，共享原流量与有效期）"
  cmd_export "$name"
}

cmd_remove_user_endpoint() {
  local name="$1" kind="$2" user status port nfuse_json port_id prospective fragment="" matches
  validate_name "$name"
  user_exists "$name" || die "用户不存在：$name"
  user="$(get_user_json "$name")" || return 1
  jq -e '.endpoints | type == "array" and length > 1' <<<"$user" >/dev/null || die "不能移除用户唯一的连接协议；如不再需要该用户，请删除用户"
  if [[ "$kind" == ss2022 ]]; then
    matches="$(jq '[.endpoints[] | select(.protocol == "ss2022")] | length' <<<"$user")" || return 1
    ((matches == 1)) || die "用户有两个 SS2022 入口，请明确选择原生或旧版 ShadowTLS 入口"
    kind="$(jq -r '.endpoints[] | select(.protocol == "ss2022") |
      if .transport == "direct" then "ss2022-direct" else "ss2022-shadowtls" end' <<<"$user")" || return 1
  fi
  port="$(jq -er --arg kind "$kind" '
    def endpoint_kind:
      if .protocol == "anytls" then "anytls"
      elif .protocol == "ss2022" and .transport == "direct" then "ss2022-direct"
      elif .protocol == "ss2022" and .transport == "shadowtls" then "ss2022-shadowtls"
      else null end;
    .endpoints[] | select(endpoint_kind == $kind) | .port
  ' <<<"$user")" || die "用户没有该连接入口：$kind"
  nfuse_json="$(nfuse list --json)" || die "无法读取流量统计数据，请查看服务状态"
  port_id="$(jq -er --arg name "$name" --argjson port "$port" \
    '.[] | select(.name == $name) | .ports[] | select(.start == $port and .end == $port) | .id' <<<"$nfuse_json")" ||
    die "协议端口没有正确接入流量统计，请先运行「服务与配置检查」"
  prospective="$(jq -c --arg kind "$kind" '
    def endpoint_kind:
      if .protocol == "anytls" then "anytls"
      elif .protocol == "ss2022" and .transport == "direct" then "ss2022-direct"
      elif .protocol == "ss2022" and .transport == "shadowtls" then "ss2022-shadowtls"
      else null end;
    .endpoints = [.endpoints[] | select(endpoint_kind != $kind)] |
    .endpoints[0] as $primary |
    del(.anytls_password,.tls_sni,.transport,.shadowtls_password,.ss2022_password,.method,.shadowtls_sni) |
    .protocol = $primary.protocol | .port = $primary.port |
    if $primary.protocol == "anytls" then .anytls_password=$primary.anytls_password | .tls_sni=$primary.tls_sni
    else .transport=$primary.transport | .ss2022_password=$primary.ss2022_password | .method=$primary.method |
      if $primary.transport == "shadowtls" then
        .shadowtls_password=$primary.shadowtls_password | .shadowtls_sni=$primary.shadowtls_sni
      else . end
    end' <<<"$user")" || return 1
  status="$(jq -er '.status | select(. == "active" or . == "disabled")' <<<"$user")" || return 1
  if [[ "$status" == active ]]; then
    fragment="$(make_user_inbounds_from_state "$prospective")" || return 1
    ensure_safe_ssh_for_kernel_restart || return 0
  fi
  start_managed_operation "remove-user-endpoint:$name:$kind" || return 1
  run_managed_step state_remove_user_endpoint "$name" "$kind" || return 1
  if [[ "$status" == active ]]; then
    run_managed_step replace_user_inbounds "$name" "$fragment" || return 1
    rebuild_user_splits_if_needed "$name" || return 1
    run_managed_step check_singbox_and_restart || return 1
  fi
  # 先关闭监听并重启成功，最后再解除流量端口，避免残留未计费入口。
  run_managed_step nfuse port rm "$port_id" || return 1
  run_managed_step nfuse persist || return 1
  finish_managed_operation || return 1
  log "已移除用户 ${name} 的连接入口：$(endpoint_kind_label "$kind")；共享账户与用量保持不变"
  cmd_export "$name"
}

rebuild_user_splits_if_needed() {
  local name="$1"
  if jq -e --arg name "$name" '.splits[]? | select(.scope == "user" and .user == $name)' "$STATE_FILE" >/dev/null; then
    run_managed_step rebuild_all_split_configs || return 1
  fi
}

rebuild_user_splits_if_needed_without_transaction() {
  local name="$1"
  if jq -e --arg name "$name" '.splits[]? | select(.scope == "user" and .user == $name)' "$STATE_FILE" >/dev/null; then
    rebuild_all_split_configs || return 1
  fi
}

cmd_disable() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "用法：$PROGRAM disable <用户名>"
  validate_name "$name"
  user_exists "$name" || die "用户不存在：$name"

  local status
  status="$(get_user_json "$name" | jq -r '.status')"
  [[ "$status" != "disabled" ]] || die "用户已经停用：$name"
  ensure_safe_ssh_for_kernel_restart || return 0
  start_managed_operation "disable-user:$name" || return 1

  run_managed_step remove_user_inbounds "$name" || return 1
  run_managed_step state_set_status "$name" "disabled" || return 1
  rebuild_user_splits_if_needed "$name" || return 1
  run_managed_step check_singbox_and_restart || return 1

  finish_managed_operation || return 1
  if nfuse_account_exists "$name"; then
    log "用户已停用：${name}（已用流量记录保留）"
  else
    log "用户已停用：$name"
  fi
}

ENABLE_USAGE_RESET=false
ENABLE_USER_FRAGMENT=""
ENABLE_USER_METERED=false

prepare_user_enable() {
  local name="${1:-}"
  local user status port fragment tag metered nfuse_json expected_tier
  user="$(get_user_json "$name")" || return 1
  status="$(jq -er '.status | select(type == "string" and length > 0)' <<<"$user")" || return 1
  [[ "$status" == "disabled" ]] || die "用户当前不是 disabled 状态：$status"

  fragment="$(make_user_inbounds_from_state "$user")" || return 1
  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    tag_exists_in_config "$tag" && die "sing-box 已存在 tag：$tag"
  done < <(jq -r '.[].tag' <<<"$fragment")
  metered="$(jq -r '.metered // (.limit_gib != null)' <<<"$user")" || return 1
  [[ "$metered" == true || "$metered" == false ]] || return 1
  expected_tier="$([[ "$metered" == true ]] && echo a || echo c)"
  nfuse_json="$(nfuse list --json)" || {
    printf '错误：无法读取流量记录，因此没有启用用户：%s\n' "$name" >&2
    return 1
  }
  if ! jq -e 'type == "array"' <<<"$nfuse_json" >/dev/null; then
    printf '错误：Nfuse 返回的数据结构无效，未启用用户：%s\n' "$name" >&2
    return 1
  fi
  if ! jq -e --arg name "$name" --arg tier "$expected_tier" \
    '.[] | select(.name == $name and .tier == $tier and (.used_bytes|type) == "number" and .used_bytes >= 0)' \
    <<<"$nfuse_json" >/dev/null; then
    printf '错误：用户的流量统计记录缺失或类型不正确，因此没有启用：%s。请运行「服务与配置检查」\n' "$name" >&2
    return 1
  fi
  while IFS= read -r port; do
    [[ -n "$port" ]] || continue
    if ! jq -e --arg name "$name" --argjson port "$port" \
      '.[] | select(.name == $name) | .ports[]? | select(.start <= $port and .end >= $port)' \
      <<<"$nfuse_json" >/dev/null; then
      printf '错误：用户端口尚未接入流量统计，因此没有启用：%s（端口 %s）。请运行「服务与配置检查」\n' "$name" "$port" >&2
      return 1
    fi
  done < <(jq -r 'if (.endpoints | type) == "array" then .endpoints[].port else .port end' <<<"$user")
  if ! ensure_safe_ssh_for_kernel_restart; then
    printf '错误：为保护当前 SSH 连接，用户没有启用：%s\n' "$name" >&2
    return 1
  fi
  ENABLE_USER_FRAGMENT="$fragment"
  ENABLE_USER_METERED="$metered"
}

enable_user_without_transaction() {
  local name="$1" usage_reset=false
  append_inbounds "$ENABLE_USER_FRAGMENT" || return 1
  state_set_status "$name" "active" || return 1
  rebuild_user_splits_if_needed_without_transaction "$name" || return 1
  check_singbox_and_restart || return 1

  if [[ "$ENABLE_USER_METERED" == true ]]; then
    usage_reset=true
    nfuse reset "$name" || return 1
    nfuse persist || return 1
  fi
  ENABLE_USAGE_RESET="$usage_reset"
}

cmd_enable() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "用法：$PROGRAM enable <用户名>"
  validate_name "$name"
  user_exists "$name" || die "用户不存在：$name"
  prepare_user_enable "$name" || return 1
  start_managed_operation "enable-user:$name" || return 1
  run_managed_step enable_user_without_transaction "$name" || return 1
  finish_managed_operation || return 1
  if [[ "$ENABLE_USAGE_RESET" == true ]]; then
    log "用户已恢复并清零已用配额：$name"
  else
    log "用户已恢复：$name"
  fi
}

calculate_renewal_expiry() {
  [[ $# -eq 2 ]] || return 64
  local base_epoch="$1" months="$2" base_time
  [[ "$base_epoch" =~ ^[0-9]+$ && "$months" =~ ^-?[1-9][0-9]*$ ]] || return 1
  base_time="$(date -d "@$base_epoch" '+%Y-%m-%d %H:%M:%S')" || return 1
  # 不要在完整时刻后直接使用 +N/-N month；GNU date 会把带符号数字误解析为时区。
  if [[ "$months" == -* ]]; then
    date -d "$base_time ${months#-} months ago" '+%Y-%m-%dT%H:%M:%S%z' || return 1
  else
    date -d "$base_time ${months} months" '+%Y-%m-%dT%H:%M:%S%z' || return 1
  fi
}

cmd_renew() {
  local name="$1" months="$2" user expires status now_epoch expires_epoch base_epoch new_expiry new_expiry_epoch
  validate_name "$name"
  [[ "$months" =~ ^-?[1-9][0-9]*$ ]] || die "有效期调整月数必须是非零整数"
  user_exists "$name" || die "用户不存在：$name"
  user="$(get_user_json "$name")" || return 1
  expires="$(jq -r '.expires_at // empty' <<<"$user")" || return 1
  [[ -n "$expires" ]] || die "自用用户没有有效期，不能调整"
  status="$(jq -er '.status | select(. == "active" or . == "disabled")' <<<"$user")" ||
    die "用户状态无效，不能调整有效期：$name"
  now_epoch="$(date +%s)" || return 1
  expires_epoch="$(date -d "$expires" +%s)" || die "用户有效期格式无效，不能调整：$name"
  if [[ "$months" != -* ]] && ((expires_epoch <= now_epoch)); then
    base_epoch="$now_epoch"
  else
    base_epoch="$expires_epoch"
  fi
  if ! new_expiry="$(calculate_renewal_expiry "$base_epoch" "$months")"; then
    echo "错误：无法按 ${months} 个月计算用户的新到期时间，有效期调整未执行：$name" >&2
    return 1
  fi
  if [[ "$months" == -* ]]; then
    new_expiry_epoch="$(date -d "$new_expiry" +%s)" || {
      echo "错误：无法验证调整后的到期时间，有效期调整未执行：$name" >&2
      return 1
    }
    if ((new_expiry_epoch <= now_epoch)); then
      echo "错误：调整后的到期时间不能早于或等于当前时间；如需立即停止使用，请执行「停用用户」：$name" >&2
      return 1
    fi
  fi
  if [[ "$status" == disabled && "$months" != -* ]]; then
    prepare_user_enable "$name" || return 1
  fi
  start_managed_operation "adjust-user-expiry:$name" || return 1
  run_managed_step state_set_expiry "$name" "$new_expiry" || return 1
  if [[ "$status" == disabled && "$months" != -* ]]; then
    if ! run_managed_step enable_user_without_transaction "$name"; then
      log "续期和自动启用失败，已恢复到续期前状态"
      return 1
    fi
  fi
  finish_managed_operation || return 1
  if [[ "$months" != -* ]]; then
    log "用户续期成功：${name}，新到期时间：${new_expiry}"
  else
    log "用户有效期已提前：${name}，新到期时间：${new_expiry}"
  fi
}

cmd_adjust_traffic() {
  local name="$1" delta_gib="$2" mode="$3" user meter used limit delta_bytes new_used before_remaining after_remaining old_limit_gib new_limit_gib anchor
  validate_name "$name"
  [[ "$delta_gib" =~ ^-?([0-9]+)(\.[0-9]+)?$ ]] || die "调整值必须是正数或负数（GiB）"
  awk -v value="$delta_gib" 'BEGIN { exit !(value != 0) }' || die "调整值不能为 0"
  if [[ "$mode" == temporary ]]; then
    awk -v value="$delta_gib" 'BEGIN { exit !(value > 0) }' || die "临时调整只能输入正数，用于增加剩余流量"
  fi
  user_exists "$name" || die "用户不存在：$name"
  user="$(get_user_json "$name")"
  [[ "$(jq -r '.metered // (.limit_gib != null)' <<<"$user")" == true ]] || die "自用用户不支持流量调整"
  meter="$(nfuse list --json | jq -c --arg name "$name" '.[] | select(.name == $name)')"
  [[ -n "$meter" ]] || die "找不到用户 $name 的流量记录，请先运行「服务与配置检查」"
  used="$(jq -r '.used_bytes' <<<"$meter")"; limit="$(jq -r '.limit_bytes' <<<"$meter")"
  [[ "$used" =~ ^[0-9]+$ && "$limit" =~ ^[0-9]+$ ]] || die "Nfuse 流量数据无效：$name"
  start_managed_operation "adjust-traffic:$name:$mode" || return 1
  case "$mode" in
    temporary)
      delta_bytes="$(awk -v value="$delta_gib" 'BEGIN { printf "%.0f", value * 1073741824 }')"
      new_used=$((used - delta_bytes))
      ((new_used < 0)) && new_used=0
      ((new_used > limit)) && new_used="$limit"
      before_remaining=$((limit - used)); ((before_remaining < 0)) && before_remaining=0
      after_remaining=$((limit - new_used))
      run_managed_step run_quietly nfuse set-usage "$name" "$new_used" || return 1
      run_managed_step run_quietly nfuse persist || return 1
      printf '临时流量调整成功：%s\n' "$name"
      printf '月配额保持：%.2f GiB\n' "$(awk -v bytes="$limit" 'BEGIN { print bytes / 1073741824 }')"
      printf '调整前剩余：%.2f GiB\n' "$(awk -v bytes="$before_remaining" 'BEGIN { print bytes / 1073741824 }')"
      printf '调整后剩余：%.2f GiB\n' "$(awk -v bytes="$after_remaining" 'BEGIN { print bytes / 1073741824 }')"
      ;;
    permanent)
      old_limit_gib="$(jq -r '.limit_gib' <<<"$user")"; anchor="$(jq -r '.billing_anchor' <<<"$user")"
      if ! new_limit_gib="$(awk -v old="$old_limit_gib" -v delta="$delta_gib" 'BEGIN { value=old+delta; if (value <= 0) exit 1; printf "%.6f", value }')"; then
        rollback_active_operation 1 || true
        printf '错误：永久调整后的月配额必须大于 0 GiB\n' >&2
        return 1
      fi
      new_limit_gib="$(awk -v value="$new_limit_gib" 'BEGIN { sub(/0+$/, "", value); sub(/\.$/, "", value); print value }')"
      run_managed_step run_quietly nfuse set-tier "$name" --tier a --limit "$new_limit_gib" --anchor "$anchor" || return 1
      run_managed_step run_quietly nfuse persist || return 1
      run_managed_step state_set_limit "$name" "$new_limit_gib" || return 1
      printf '永久流量调整成功：%s\n' "$name"
      printf '原月配额：%s GiB\n' "$old_limit_gib"
      printf '新月配额：%s GiB\n' "$new_limit_gib"
      ;;
    *) rollback_active_operation 1 || true; printf '错误：未知流量调整模式\n' >&2; return 1;;
  esac
  finish_managed_operation || return 1
}

cmd_edit_user() {
  local name="$1" new_port="$2" new_sni="$3" new_method="$4" new_anchor="$5" new_expiry="$6" target_kind="${7:-}"
  local user endpoint protocol transport="" metered status old_port old_sni old_method old_anchor old_expiry new_user fragment=""
  local config_changed=false method_changed=false nfuse_changed=false nfuse_json="" old_port_id="" limit expected_tier

  validate_name "$name"
  user_exists "$name" || die "用户不存在：$name"
  user="$(get_user_json "$name")" || return 1
  user="$(normalize_user_endpoints_json "$user")" || return 1
  if [[ -z "$target_kind" ]]; then
    target_kind="$(jq -er '
      if .endpoints[0].protocol == "anytls" then "anytls"
      elif .endpoints[0].transport == "direct" then "ss2022-direct"
      else "ss2022-shadowtls" end
    ' <<<"$user")" || return 1
  elif [[ "$target_kind" == ss2022 ]]; then
    target_kind="$(jq -er '
      [.endpoints[] | select(.protocol == "ss2022")] as $matches |
      select(($matches | length) == 1) |
      if $matches[0].transport == "direct" then "ss2022-direct" else "ss2022-shadowtls" end
    ' <<<"$user")" || die "用户有两个 SS2022 入口，请明确选择要编辑的入口"
  fi
  endpoint="$(jq -ec --arg kind "$target_kind" '
    def endpoint_kind:
      if .protocol == "anytls" then "anytls"
      elif .protocol == "ss2022" and .transport == "direct" then "ss2022-direct"
      elif .protocol == "ss2022" and .transport == "shadowtls" then "ss2022-shadowtls"
      else null end;
    .endpoints[] | select(endpoint_kind == $kind)
  ' <<<"$user")" || die "用户没有该连接入口：$target_kind"
  protocol="$(jq -er '.protocol | select(. == "ss2022" or . == "anytls")' <<<"$endpoint")" || return 1
  metered="$(jq -r '(.metered // (.limit_gib != null)) | select(type == "boolean")' <<<"$user")" || return 1
  [[ "$metered" == true || "$metered" == false ]] || return 1
  status="$(jq -er '.status | select(. == "active" or . == "disabled")' <<<"$user")" || return 1
  old_port="$(jq -er '.port | select(type == "number" and . == floor and . >= 1 and . <= 65535)' <<<"$endpoint")" || return 1
  if [[ "$new_port" == "$old_port" ]]; then validate_migration_port "$new_port"; else validate_port "$new_port"; fi

  if [[ "$protocol" == anytls ]]; then
    old_sni="$(jq -er '.tls_sni | select(type == "string" and length > 0)' <<<"$endpoint")" || return 1
    [[ -z "$new_method" ]] || die "AnyTLS 用户不支持 SS2022 加密方式"
    validate_shadowtls_sni "$new_sni"
  else
    transport="$(jq -er '.transport // "shadowtls" | select(. == "direct" or . == "shadowtls")' <<<"$endpoint")" || return 1
    if [[ "$transport" == shadowtls ]]; then
      old_sni="$(jq -er '.shadowtls_sni | select(type == "string" and length > 0)' <<<"$endpoint")" || return 1
      validate_shadowtls_sni "$new_sni"
    else
      old_sni=""
      [[ -z "$new_sni" ]] || die "原生 SS2022 不使用 SNI"
    fi
    old_method="$(jq -er '.method | select(type == "string" and length > 0)' <<<"$endpoint")" || return 1
    validate_ss2022_method "$new_method"
  fi

  if [[ "$metered" == true ]]; then
    old_anchor="$(jq -er '.billing_anchor | select(type == "number" and . == floor)' <<<"$user")" || return 1
    old_expiry="$(jq -er '.expires_at | select(type == "string" and length > 0)' <<<"$user")" || return 1
    validate_anchor "$new_anchor"
    [[ -n "$new_expiry" ]] || die "计量用户必须保留有效期"
    date -d "$new_expiry" +%s >/dev/null 2>&1 || die "有效期格式无效"
  else
    [[ -z "$new_anchor" && -z "$new_expiry" ]] || die "自用用户不支持账单日或有效期"
    old_anchor=""
    old_expiry=""
  fi

  if [[ "$new_port" != "$old_port" ]]; then
    port_in_state "$new_port" && die "端口已被脚本记录占用：$new_port"
    port_is_listening "$new_port" && die "端口已被其他服务监听：$new_port"
    config_changed=true
  fi
  [[ "$new_sni" == "$old_sni" ]] || config_changed=true
  if [[ "$protocol" == ss2022 && "$new_method" != "$old_method" ]]; then
    config_changed=true
    method_changed=true
  fi

  if [[ "$new_port" != "$old_port" || ( "$metered" == true && "$new_anchor" != "$old_anchor" ) ]]; then
    nfuse_json="$(nfuse list --json)" || die "无法读取流量统计数据，请查看服务状态"
    jq -e 'type == "array"' <<<"$nfuse_json" >/dev/null || die "Nfuse 返回的数据结构无效"
    expected_tier="$([[ "$metered" == true ]] && echo a || echo c)"
    jq -e --arg name "$name" --arg tier "$expected_tier" '.[] | select(.name == $name and .tier == $tier)' <<<"$nfuse_json" >/dev/null || die "找不到用户 $name 的正确流量记录，请先运行「服务与配置检查」"
    if [[ "$new_port" != "$old_port" ]]; then
      jq -e --argjson port "$new_port" \
        '.[] | .ports[]? | select(.start <= $port and .end >= $port)' \
        <<<"$nfuse_json" >/dev/null && die "Nfuse 已由其他账户管理端口：$new_port"
      old_port_id="$(jq -er --arg name "$name" --argjson port "$old_port" \
        '.[] | select(.name == $name) | .ports[] | select(.start == $port and .end == $port) | .id' \
        <<<"$nfuse_json")" || die "原端口没有正确接入流量统计，请先运行「服务与配置检查」"
    fi
    nfuse_changed=true
  fi

  if [[ "$new_port" == "$old_port" && "$new_sni" == "$old_sni" && \
        ( "$protocol" == anytls || "$new_method" == "$old_method" ) && \
        "$new_anchor" == "$old_anchor" && "$new_expiry" == "$old_expiry" ]]; then
    log "用户信息没有变化：$name"
    return 0
  fi

  new_user="$(jq -c \
    --arg kind "$target_kind" --argjson port "$new_port" --arg sni "$new_sni" --arg method "$new_method" \
    --arg anchor "$new_anchor" --arg expiry "$new_expiry" \
    'def endpoint_kind:
       if .protocol == "anytls" then "anytls"
       elif .protocol == "ss2022" and .transport == "direct" then "ss2022-direct"
       elif .protocol == "ss2022" and .transport == "shadowtls" then "ss2022-shadowtls"
       else null end;
     .endpoints |= map(
       if endpoint_kind == $kind then
         .port = $port |
         if .protocol == "anytls" then .tls_sni = $sni
         else .method = $method |
           if .transport == "shadowtls" then .shadowtls_sni = $sni
           else del(.shadowtls_password,.shadowtls_sni) end
         end
       else . end) |
     if (.metered // (.limit_gib != null)) then
       .billing_anchor = ($anchor | tonumber) | .expires_at = $expiry
     else . end' <<<"$user")" || return 1
  if [[ "$method_changed" == true ]]; then
    local new_password
    new_password="$(generate_ss_password "$new_method")" || return 1
    new_user="$(SB_JQ_PASSWORD="$new_password" jq -c --arg kind "$target_kind" '
      def endpoint_kind:
        if .protocol == "anytls" then "anytls"
        elif .protocol == "ss2022" and .transport == "direct" then "ss2022-direct"
        elif .protocol == "ss2022" and .transport == "shadowtls" then "ss2022-shadowtls"
        else null end;
      .endpoints |= map(if endpoint_kind == $kind then .ss2022_password = $ENV.SB_JQ_PASSWORD else . end)
    ' <<<"$new_user")" || return 1
  fi
  if [[ "$status" == active && "$config_changed" == true ]]; then
    fragment="$(make_user_inbounds_from_state "$new_user")" || return 1
  fi

  if [[ "$config_changed" == true ]]; then ensure_safe_ssh_for_kernel_restart || return 0; fi
  start_managed_operation "edit-user:$name" || return 1
  if [[ "$new_port" != "$old_port" ]]; then
    # 先持久化新端口的流量统计，再开放新监听；旧端口在服务切换完成前继续受控。
    run_managed_step nfuse port add "$name" "$new_port" || return 1
    run_managed_step nfuse persist || return 1
  fi
  run_managed_step state_replace_user "$name" "$new_user" || return 1
  if [[ "$status" == active && "$config_changed" == true ]]; then
    run_managed_step replace_user_inbounds "$name" "$fragment" || return 1
    run_managed_step check_singbox_and_restart || return 1
  fi
  if [[ "$nfuse_changed" == true ]]; then
    if [[ "$new_port" != "$old_port" ]]; then
      run_managed_step nfuse port rm "$old_port_id" || return 1
    fi
    if [[ "$new_anchor" != "$old_anchor" ]]; then
      limit="$(jq -er '.limit_gib | select(type == "number" and . > 0)' <<<"$new_user")" || return 1
      run_managed_step nfuse set-tier "$name" --tier a --limit "$limit" --anchor "$new_anchor" || return 1
    fi
    run_managed_step nfuse persist || return 1
  fi
  finish_managed_operation || return 1

  log "用户编辑成功：$name"
  if [[ "$method_changed" == true ]]; then
    log "SS2022 加密方式已变化并重新生成密钥，旧客户端配置已失效"
  fi
  if [[ "$config_changed" == true ]]; then
    cmd_export "$name"
  fi
}

cmd_set_global_sni() {
  local protocol="$1" new_sni="$2" current_sni total mismatched active_count
  validate_shadowtls_sni "$new_sni"
  case "$protocol" in
    ss2022) current_sni="$SS2022_SHADOWTLS_SNI";;
    anytls) current_sni="$ANYTLS_SNI";;
    *) die "未知 SNI 协议：$protocol";;
  esac
  total="$(jq --arg protocol "$protocol" '[.users[] |
    select(any(if (.endpoints | type) == "array" then .endpoints[]
      else {protocol:(.protocol // "ss2022"),transport:(.transport // "shadowtls")} end;
      .protocol == $protocol and ($protocol != "ss2022" or .transport == "shadowtls")))] | length' "$STATE_FILE")" || return 1
  mismatched="$(jq --arg protocol "$protocol" --arg sni "$new_sni" '[.users[] |
    (if (.endpoints | type) == "array" then .endpoints[]
     else {protocol:(.protocol // "ss2022"),transport:(.transport // "shadowtls"),tls_sni:.tls_sni,shadowtls_sni:.shadowtls_sni} end) |
    select(.protocol == $protocol and ($protocol != "ss2022" or .transport == "shadowtls")) |
    select((if $protocol == "anytls" then .tls_sni else .shadowtls_sni end) != $sni)] | length' "$STATE_FILE")" || return 1
  active_count="$(jq --arg protocol "$protocol" '[.users[] |
    select(.status == "active" and any(if (.endpoints | type) == "array" then .endpoints[]
      else {protocol:(.protocol // "ss2022"),transport:(.transport // "shadowtls")} end;
      .protocol == $protocol and ($protocol != "ss2022" or .transport == "shadowtls")))] | length' "$STATE_FILE")" || return 1
  if [[ "$new_sni" == "$current_sni" && "$mismatched" == 0 ]]; then
    log "全局 SNI 与既有用户已一致，无需修改"
    return 0
  fi

  if [[ "$protocol" == ss2022 ]] && ((active_count > 0)); then ensure_safe_ssh_for_kernel_restart || return 0; fi
  start_managed_operation "set-global-sni:$protocol" || return 1
  if [[ "$protocol" == ss2022 ]]; then
    run_managed_step write_global_sni_config "$new_sni" "$ANYTLS_SNI" update || return 1
  else
    run_managed_step write_global_sni_config "$SS2022_SHADOWTLS_SNI" "$new_sni" update || return 1
  fi
  if ((total > 0)); then
    run_managed_step state_set_protocol_sni "$protocol" "$new_sni" || return 1
  fi
  if [[ "$protocol" == ss2022 ]] && ((active_count > 0)); then
    run_managed_step rebuild_protocol_inbounds "$protocol" || return 1
    run_managed_step check_singbox_and_restart || return 1
  fi
  finish_managed_operation || return 1
  log "全局 SNI 修改成功：${new_sni}；同步用户：$total"
}

cmd_remove() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "用法：$PROGRAM remove <用户名>"
  validate_name "$name"
  user_exists "$name" || die "用户不存在：$name"

  local split_name split_names split_count=0 nfuse_json
  ensure_safe_ssh_for_kernel_restart || return 0
  start_managed_operation "remove-user:$name" || return 1

  if ! split_names="$(jq -r --arg name "$name" '.splits[]? | select(.scope == "user" and .user == $name) | .name' "$STATE_FILE")"; then
    rollback_active_operation 1 || true
    return 1
  fi
  while IFS= read -r split_name; do
    [[ -n "$split_name" ]] || continue
    run_managed_step remove_split_config "$split_name" || return 1
    run_managed_step state_remove_split "$split_name" || return 1
    ((split_count+=1))
  done <<<"$split_names"
  run_managed_step remove_user_inbounds "$name" || return 1
  run_managed_step state_remove_user "$name" || return 1
  # 关联分流可能与其他用户共享规则集或出口，删除后必须按剩余状态统一重建。
  if ((split_count > 0)); then run_managed_step rebuild_all_split_configs || return 1; fi
  run_managed_step check_singbox_and_restart || return 1

  if ! nfuse_json="$(nfuse list --json)" || ! jq -e 'type == "array"' <<<"$nfuse_json" >/dev/null; then
    rollback_active_operation 1 || true
    return 1
  fi
  if jq -e --arg name "$name" '.[] | select(.name == $name)' <<<"$nfuse_json" >/dev/null; then
    run_managed_step nfuse rm "$name" --cascade || return 1
    run_managed_step nfuse persist || return 1
  fi

  finish_managed_operation || return 1

  if ((split_count>0)); then log "用户已删除：${name}，并清理关联分流 ${split_count} 条"
  else log "用户已删除：$name"
  fi
}

render_user_list() {
  local usage_json="$1" safe_rows
  if ! safe_rows="$(jq -r --argjson nfuse "$usage_json" '
    if (.users | length) == 0 then
      "暂无用户"
    else
      (["用户名", "协议", "端口", "状态", "月配额", "已用", "剩余", "账单日", "到期时间", "创建时间"] | @tsv),
      (.users[] as $user |
        (($user.metered // ($user.limit_gib != null))) as $metered |
        ($nfuse | map(select(.name == $user.name)) | first) as $meter |
        [$user.name,
         ([if ($user.endpoints | type) == "array" then $user.endpoints[]
           else {protocol:($user.protocol // "ss2022"),transport:($user.transport // "shadowtls")} end |
           if .protocol == "anytls" then "AnyTLS"
           elif .transport == "shadowtls" then "SS2022+ShadowTLS（旧版）"
           else "SS2022" end] | join(" + ")),
         ([if ($user.endpoints | type) == "array" then $user.endpoints[].port else $user.port end | tostring] | join(" / ")),
         (if $user.status == "disabled" then "停用"
          elif $user.status == "active" and $metered and $meter != null and $meter.used_bytes >= $meter.limit_bytes then "配额耗尽"
          elif $user.status == "active" then "启用"
          else $user.status end),
         (if $metered then (($user.limit_gib | tostring) + " GiB") else "不限" end),
         (if $meter == null then "-" else (((((($meter.used_bytes + ($user.usage_offset_bytes // 0)) / 1073741824) * 100 | round) / 100) | tostring) + " GiB") end),
         (if ($metered | not) or $meter == null then "-" else ((((([$meter.limit_bytes - $meter.used_bytes, 0] | max) / 1073741824) * 100 | round) / 100 | tostring) + " GiB") end),
         (if $metered then (($user.billing_anchor | tostring) + " 日") else "-" end),
         (if $user.expires_at == null then "-" else ($user.expires_at | sub("T"; " ") | sub("[+-][0-9]{2}:?[0-9]{2}$"; "")) end),
         ($user.created_at | sub("T"; " ") | sub("[+-][0-9]{2}:[0-9]{2}$"; ""))]
        | @tsv)
    end
  ' "$STATE_FILE")"; then
    echo '用户列表暂时无法格式化，敏感字段已隐藏。' >&2
    return 1
  fi
  if ! printf '%s\n' "$safe_rows" | column -t -s $'\t' 2>/dev/null; then
    printf '%s\n' "$safe_rows"
  fi
}

cmd_list() {
  render_user_list "$(nfuse list --json)"
}

parse_expiry_epoch() {
  local expires="$1" epoch
  epoch="$(date -d "$expires" +%s 2>/dev/null)" || return 1
  [[ "$epoch" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$epoch"
}

cmd_expire() {
  local now name user expires expires_epoch
  now="$(date +%s)"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    user="$(get_user_json "$name")"
    expires="$(jq -r '.expires_at // empty' <<<"$user")"
    [[ -n "$expires" ]] || continue
    [[ "$(jq -r '.status' <<<"$user")" == active ]] || continue
    if ! expires_epoch="$(parse_expiry_epoch "$expires")"; then
      log "警告：用户 ${name} 的有效期格式无效，已跳过本次自动到期处理：${expires}"
      continue
    fi
    if ((expires_epoch <= now)); then
      log "用户已到期，正在停用：$name"
      ensure_safe_ssh_for_kernel_restart || return 0
      start_managed_operation "expire-user:$name" || return 1
      if nfuse_account_exists "$name"; then
        local limit_bytes
        limit_bytes="$(nfuse list --json | jq -r --arg name "$name" '.[] | select(.name == $name) | .limit_bytes')"
        if [[ ! "$limit_bytes" =~ ^[0-9]+$ ]]; then
          rollback_active_operation 1 || true
          return 1
        fi
        run_managed_step run_quietly nfuse set-usage "$name" "$limit_bytes" || return 1
        run_managed_step run_quietly nfuse persist || return 1
      fi
      run_managed_step remove_user_inbounds "$name" || return 1
      run_managed_step state_set_status "$name" disabled || return 1
      rebuild_user_splits_if_needed "$name" || return 1
      run_managed_step check_singbox_and_restart || return 1
      finish_managed_operation || return 1
      log "用户已停用，已用流量记录继续保留：$name"
    fi
  done < <(jq -r '.users[].name' "$STATE_FILE")
}

url_percent_encode() {
  local LC_ALL=C input="$1" output="" char hex i
  for ((i=0; i<${#input}; i++)); do
    char="${input:i:1}"
    case "$char" in
      [a-zA-Z0-9.~_-]) output+="$char" ;;
      *)
        printf -v hex '%02X' "'$char"
        output+="%${hex}"
        ;;
    esac
  done
  printf '%s' "$output"
}

base64_without_padding() {
  base64 | tr -d '\n='
}

url_authority_host() {
  local host="$1"
  if [[ "$host" == \[*\] ]]; then printf '%s' "$host"
  elif [[ "$host" == *:* ]]; then printf '[%s]' "$host"
  else printf '%s' "$host"
  fi
}

shadowrocket_anytls_url() {
  local user="$1" override_port="${2:-}" name port password sni host
  name="$(jq -er '.name' <<<"$user")" || return 1
  port="$(jq -er '.port' <<<"$user")" || return 1
  [[ -z "$override_port" ]] || port="$override_port"
  password="$(jq -er '.anytls_password' <<<"$user")" || return 1
  sni="$(jq -er '.tls_sni' <<<"$user")" || return 1
  host="$(url_authority_host "$PUBLIC_SERVER")"
  printf 'anytls://%s@%s:%s?peer=%s&insecure=1&udp=1#%s' \
    "$(url_percent_encode "$password")" "$host" "$port" \
    "$(url_percent_encode "$sni")" "$(url_percent_encode "$name")"
}

shadowrocket_ss2022_url() {
  local user="$1" override_port="${2:-}" name port method ss_password st_password sni host credentials plugin_json
  local credentials_base64 plugin_base64
  name="$(jq -er '.name' <<<"$user")" || return 1
  port="$(jq -er '.port' <<<"$user")" || return 1
  [[ -z "$override_port" ]] || port="$override_port"
  method="$(jq -er '.method' <<<"$user")" || return 1
  ss_password="$(jq -er '.ss2022_password' <<<"$user")" || return 1
  st_password="$(jq -er '.shadowtls_password' <<<"$user")" || return 1
  sni="$(jq -er '.shadowtls_sni' <<<"$user")" || return 1
  host="$(url_authority_host "$PUBLIC_SERVER")"
  credentials="${method}:${ss_password}@${host}:${port}"
  credentials_base64="$(printf '%s' "$credentials" | base64_without_padding)" || return 1
  plugin_json="$(SB_JQ_PASSWORD="$st_password" jq -cn --arg host "$sni" \
    '{version:"3",host:$host,password:$ENV.SB_JQ_PASSWORD}' | sed 's#/#\\/#g')" || return 1
  plugin_base64="$(printf '%s' "$plugin_json" | base64_without_padding)" || return 1
  printf 'ss://%s?shadow-tls=%s#%s' \
    "$credentials_base64" "$(url_percent_encode "$plugin_base64")" "$(url_percent_encode "$name")"
}

shadowrocket_ss2022_direct_url() {
  local user="$1" override_port="${2:-}" name port method ss_password host userinfo
  name="$(jq -er '.name' <<<"$user")" || return 1
  port="$(jq -er '.port' <<<"$user")" || return 1
  [[ -z "$override_port" ]] || port="$override_port"
  method="$(jq -er '.method' <<<"$user")" || return 1
  ss_password="$(jq -er '.ss2022_password' <<<"$user")" || return 1
  host="$(url_authority_host "$PUBLIC_SERVER")"
  userinfo="$(printf '%s' "${method}:${ss_password}" | base64_without_padding)" || return 1
  printf 'ss://%s@%s:%s#%s' "$userinfo" "$host" "$port" "$(url_percent_encode "$name")"
}

print_shadowrocket_qr() {
  # 导入链接含明文密码，改走标准输入，避免出现在进程列表里
  printf '%s' "$1" | qrencode -t ANSIUTF8 -l L -m 1
}

render_shadowrocket_export() {
  local url="$1"
  printf '\n[Shadowrocket]\n导入链接：\n%s\n' "$url"
  if command -v qrencode >/dev/null 2>&1 && [[ -t 1 && "${TERM:-dumb}" != dumb ]]; then
    printf '\n二维码（使用 Shadowrocket 扫描）：\n'
    print_shadowrocket_qr "$url" || echo '二维码生成失败，请复制上方链接导入。'
  elif command -v qrencode >/dev/null 2>&1 && [[ -t 1 ]]; then
    printf '\n当前终端不支持显示二维码，请复制上方链接导入。\n'
  elif [[ -t 1 ]]; then
    printf '\n二维码组件尚未安装，请复制上方链接导入。\n'
  fi
}

ensure_shadowrocket_qr_support() {
  local choice
  command -v qrencode >/dev/null 2>&1 && return 0
  printf '\n首次显示二维码需要安装服务器本地二维码组件，不会把节点信息发送给第三方。\n'
  read_menu_choice '是否现在安装？[Y/n]：' 'y,Y,n,N' Y '请输入 y、n 或直接回车' || return 1
  choice="$PROMPT_VALUE"
  [[ ! "$choice" =~ ^[Nn]$ ]] || return 1
  if apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y qrencode; then
    return 0
  fi
  echo '二维码组件安装失败，本次仍会显示可复制的完整链接。'
  return 1
}

cmd_export() {
  local name="${1:-}"
  local format="${2:-all}"
  [[ -n "$name" ]] || die "用法：$PROGRAM export <用户名> [all|surge|shadowrocket]"
  (( $# <= 2 )) || die "用法：$PROGRAM export <用户名> [all|surge|shadowrocket]"
  validate_name "$name"
  user_exists "$name" || die "用户不存在：$name"
  case "$format" in
    all|surge|shadowrocket) ;;
    *) die "导出格式必须是 all、surge 或 shadowrocket" ;;
  esac

  local user endpoint endpoint_user protocol transport endpoint_count ss_endpoint_count node_name port st_password ss_password method shadowtls_sni server_port shadowrocket_url
  user="$(get_user_json "$name")"
  endpoint_count="$(jq 'if (.endpoints | type) == "array" then .endpoints | length else 1 end' <<<"$user")" || return 1
  ss_endpoint_count="$(jq '[.endpoints[]? | select(.protocol == "ss2022")] | length' <<<"$user")" || return 1
  while IFS= read -r endpoint; do
    [[ -n "$endpoint" ]] || continue
    protocol="$(jq -er '.protocol' <<<"$endpoint")" || return 1
    port="$(jq -er '.port' <<<"$endpoint")" || return 1
    if ((endpoint_count > 1)); then
      if [[ "$protocol" == anytls ]]; then
        node_name="${name}-AnyTLS"
      else
        transport="$(jq -r '.transport // "shadowtls"' <<<"$endpoint")" || return 1
        if [[ "$transport" == shadowtls ]] && ((ss_endpoint_count > 1)); then
          node_name="${name}-SS2022-ShadowTLS"
        else
          node_name="${name}-SS2022"
        fi
      fi
      server_port="$port"
    else
      node_name="$name"
      server_port="${CLIENT_SERVER_PORT_OVERRIDE:-$port}"
    fi
    endpoint_user="$(jq -c --arg name "$node_name" '. + {name:$name}' <<<"$endpoint")" || return 1
    if [[ "$protocol" == anytls ]]; then
      if [[ "$format" == all || "$format" == surge ]]; then
        printf '\n[Surge]\n%s = anytls, %s, %s, password=%s, sni=%s, skip-cert-verify=true\n' "$node_name" "$PUBLIC_SERVER" "$server_port" "$(jq -r '.anytls_password' <<<"$endpoint")" "$(jq -r '.tls_sni' <<<"$endpoint")"
      fi
      if [[ "$format" == all || "$format" == shadowrocket ]]; then
        shadowrocket_url="$(shadowrocket_anytls_url "$endpoint_user" "$server_port")" || die "无法生成 Shadowrocket AnyTLS 导入链接"
        render_shadowrocket_export "$shadowrocket_url"
      fi
      continue
    fi
    transport="$(jq -r '.transport // "shadowtls"' <<<"$endpoint")"
    ss_password="$(jq -r '.ss2022_password' <<<"$endpoint")"
    method="$(jq -r '.method' <<<"$endpoint")"
    if [[ "$transport" == shadowtls ]]; then
      st_password="$(jq -er '.shadowtls_password' <<<"$endpoint")" || return 1
      shadowtls_sni="$(jq -er '.shadowtls_sni' <<<"$endpoint")" || return 1
      if [[ "$format" == all || "$format" == surge ]]; then
        printf '\n[Surge]\n'
        printf '%s = ss, %s, %s, encrypt-method=%s, password=%s, shadow-tls-password=%s, shadow-tls-sni=%s, shadow-tls-version=3, udp-relay=true\n' \
          "$node_name" "$PUBLIC_SERVER" "$server_port" "$method" "$ss_password" "$st_password" "$shadowtls_sni"
      fi
      if [[ "$format" == all || "$format" == shadowrocket ]]; then
        shadowrocket_url="$(shadowrocket_ss2022_url "$endpoint_user" "$server_port")" || die "无法生成 Shadowrocket SS2022 + ShadowTLS 导入链接"
        render_shadowrocket_export "$shadowrocket_url"
      fi
    else
      if [[ "$format" == all || "$format" == surge ]]; then
        printf '\n[Surge]\n%s = ss, %s, %s, encrypt-method=%s, password=%s, udp-relay=true\n' \
          "$node_name" "$PUBLIC_SERVER" "$server_port" "$method" "$ss_password"
      fi
      if [[ "$format" == all || "$format" == shadowrocket ]]; then
        shadowrocket_url="$(shadowrocket_ss2022_direct_url "$endpoint_user" "$server_port")" || die "无法生成 Shadowrocket SS2022 导入链接"
        render_shadowrocket_export "$shadowrocket_url"
      fi
    fi
  done < <(jq -c '
    if (.endpoints | type) == "array" then .endpoints[]
    elif (.protocol // "ss2022") == "anytls" then
      {protocol:"anytls",port:.port,anytls_password:.anytls_password,tls_sni:.tls_sni}
    else
      {protocol:"ss2022",transport:(.transport // "shadowtls"),port:.port,shadowtls_password:.shadowtls_password,
       ss2022_password:.ss2022_password,method:.method,shadowtls_sni:.shadowtls_sni}
    end
  ' <<<"$user")
}
