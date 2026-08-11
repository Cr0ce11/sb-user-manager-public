
is_ipv4_address() {
  local a b c d extra
  IFS=. read -r a b c d extra <<<"$1"
  [[ -z "$extra" && "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ &&
     "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 1
  ((10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255))
}

is_public_ipv4() {
  local a b c d
  is_ipv4_address "$1" || return 1
  IFS=. read -r a b c d <<<"$1"
  a=$((10#$a)); b=$((10#$b)); c=$((10#$c)); d=$((10#$d))
  if ((a == 0 || a == 10 || a == 127 || a >= 224)) ||
     ((a == 100 && b >= 64 && b <= 127)) ||
     ((a == 169 && b == 254)) ||
     ((a == 172 && b >= 16 && b <= 31)) ||
     ((a == 192 && b == 0 && (c == 0 || c == 2))) ||
     ((a == 192 && b == 88 && c == 99)) ||
     ((a == 192 && b == 168)) ||
     ((a == 198 && (b == 18 || b == 19))) ||
     ((a == 198 && b == 51 && c == 100)) ||
     ((a == 203 && b == 0 && c == 113)); then
    return 1
  fi
  return 0
}

detect_public_server() {
  local candidate url
  if [[ -n "${PUBLIC_SERVER_OVERRIDE:-}" ]]; then
    is_public_ipv4 "$PUBLIC_SERVER_OVERRIDE" || return 1
    printf '%s\n' "$PUBLIC_SERVER_OVERRIDE"
    return 0
  fi

  candidate="$(ip -4 route get 1.1.1.1 2>/dev/null |
    awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')"
  if is_public_ipv4 "$candidate"; then
    printf '%s\n' "$candidate"
    return 0
  fi

  for url in https://api.ipify.org https://checkip.amazonaws.com https://ipv4.icanhazip.com; do
    candidate="$(curl --proto '=https' --proto-redir '=https' --max-redirs 0 \
      -4fsS --noproxy '*' --connect-timeout 3 --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')" || continue
    if is_public_ipv4 "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少运行所需组件：$1。请先选择「安装或修复环境」进行检查和修复"
}

validate_name() {
  [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$ ]] ||
    die "用户名只能包含字母、数字、下划线、连字符，长度 1-32"
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] || die "端口必须是数字"
  (( "$1" >= PORT_MIN && "$1" <= PORT_MAX )) ||
    die "端口必须位于 ${PORT_MIN}-${PORT_MAX}"
}

validate_migration_port() {
  [[ "$1" =~ ^[0-9]+$ ]] || die "迁移用户端口必须是整数"
  (( "$1" >= 1 && "$1" <= 65535 )) ||
    die "迁移用户端口必须位于 1-65535"
}

validate_limit() {
  [[ "$1" =~ ^([0-9]+)(\.[0-9]+)?$ ]] || die "配额必须是正数（GiB）"
  awk -v value="$1" 'BEGIN { exit !(value > 0) }' || die "配额必须大于 0 GiB"
}

validate_anchor() {
  [[ "$1" =~ ^[0-9]+$ ]] || die "账单日必须是数字"
  (( "$1" >= 1 && "$1" <= 28 )) || die "账单日必须位于 1-28"
}

validate_ss2022_method() {
  case "$1" in
    2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm) ;;
    *) die "SS2022 加密方式仅支持 2022-blake3-aes-128-gcm 或 2022-blake3-aes-256-gcm" ;;
  esac
}

validate_shadowtls_sni() {
  [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] ||
    die "ShadowTLS SNI 必须是有效域名，例如 www.microsoft.com"
}

port_is_listening() {
  ss -H -lntu "sport = :$1" 2>/dev/null | grep -q .
}

find_available_user_port() {
  local count start offset port nfuse_json
  count=$((PORT_MAX - PORT_MIN + 1))
  start=$((PORT_MIN + RANDOM % count))
  nfuse_json="$(nfuse list --json)"
  for ((offset=0; offset<count; offset++)); do
    port=$((PORT_MIN + (start - PORT_MIN + offset) % count))
    port_in_state "$port" && continue
    port_is_listening "$port" && continue
    jq -e --argjson port "$port" '.[] | .ports[]? | select(.start <= $port and .end >= $port)' <<<"$nfuse_json" >/dev/null && continue
    printf '%s\n' "$port"
    return 0
  done
  die "${PORT_MIN}-${PORT_MAX} 范围内没有可用端口"
}

check_config_vars() {
  if ! PUBLIC_SERVER="$(detect_public_server)"; then
    die "无法识别公网 IPv4，已停止导出以避免生成内网地址。请检查服务器能否访问 HTTPS；特殊网络可在 ${CONF_FILE} 设置 PUBLIC_SERVER_OVERRIDE=\"公网IPv4\""
  fi
  [[ -f "$SINGBOX_CONFIG" ]] || die "sing-box 配置不存在：$SINGBOX_CONFIG"
  [[ -x "$SINGBOX_BIN" ]] || die "sing-box 不可执行：$SINGBOX_BIN"
  [[ -x "$NFUSE_BIN" ]] || die "nfuse 不可执行：$NFUSE_BIN"
  [[ -S "$NFUSE_SOCKET" ]] || die "流量统计服务尚未就绪（Nfuse 通信文件不存在：${NFUSE_SOCKET}）。请先查看服务状态"
  validate_runtime_config_file
}

nfuse() {
  local bin="${NFUSE_BIN:-/usr/local/bin/nfuse}" socket="${NFUSE_SOCKET:-/run/nfuse.sock}"
  "$bin" "$@" --socket "$socket"
}

wait_for_nfuse_ready() {
  local attempts="${NFUSE_READY_ATTEMPTS:-50}" delay="${NFUSE_READY_DELAY:-0.1}" i
  local bin="${NFUSE_BIN:-/usr/local/bin/nfuse}" socket="${NFUSE_SOCKET:-/run/nfuse.sock}"
  for ((i=0; i<attempts; i++)); do
    if [[ -x "$bin" ]] &&
       "$bin" list --json --socket "$socket" 2>/dev/null | jq -e 'type == "array"' >/dev/null; then
      return 0
    fi
    sleep "$delay"
  done
  return 1
}

init_state() {
  install -d -m 700 "$(dirname "$STATE_FILE")" "$BACKUP_DIR" || return 1
  if [[ ! -f "$STATE_FILE" ]]; then
    printf '{"schema_version":%d,"users":[],"splits":[],"outbound_presets":[],"rule_presets":[]}\n' "$STATE_SCHEMA_VERSION" > "$STATE_FILE" || return 1
    chmod 600 "$STATE_FILE" || return 1
  fi
  migrate_state || return 1
  remove_obsolete_manager_config || return 1
  ensure_global_sni_config || return 1
  if ! jq -e --argjson schema "$STATE_SCHEMA_VERSION" '
    .schema_version == $schema and
    (.users | type == "array") and
    all(.users[]?; (.endpoints | type == "array") and (.endpoints | length >= 1)) and
    (.splits | type == "array") and
    (.outbound_presets | type == "array") and
    (.rule_presets | type == "array") and
    all(.splits[]?;
      all([.runtime_rule_tag?,.runtime_outbound_tag?,.runtime_transport_tag?][];
        . == null or (type == "string" and test("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$") and . != "direct")))
  ' "$STATE_FILE" >/dev/null; then
    printf '错误：用户数据文件无法读取。请先运行「服务与配置检查」。详细位置：%s\n' "$STATE_FILE" >&2
    return 1
  fi
  if ((ACTIVE_TRANSACTION_DEPTH == 0)) && [[ -x "${NFUSE_BIN:-}" && -S "${NFUSE_SOCKET:-}" ]]; then
    ensure_self_nfuse_accounts || return 1
  fi
}

atomic_state_update() {
  local filter="$1" tmp
  shift
  tmp="$(mktemp "$(dirname "$STATE_FILE")/.managed-users.XXXXXX")" || return 1
  register_temp_path "$tmp"
  if ! jq "$@" "$filter" "$STATE_FILE" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! chmod 600 "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chown --reference="$STATE_FILE" "$tmp" 2>/dev/null || true
  if ! mv -- "$tmp" "$STATE_FILE"; then
    rm -f -- "$tmp"
    return 1
  fi
}

restore_state_backup_atomically() {
  local backup="$1" tmp
  [[ -f "$backup" && ! -L "$backup" ]] || return 1
  tmp="$(mktemp "$(dirname "$STATE_FILE")/.state-restore.XXXXXX")" || return 1
  register_temp_path "$tmp"
  if ! cp -a -- "$backup" "$tmp" || ! chmod 600 "$tmp" || ! mv -- "$tmp" "$STATE_FILE"; then
    rm -f -- "$tmp"
    return 1
  fi
}

validate_state_user_endpoints() {
  local file="${1:-$STATE_FILE}"
  jq -e '
    def valid_ss2022_endpoint:
      (.transport == "direct" or .transport == "shadowtls") and
      (.method == "2022-blake3-aes-128-gcm" or .method == "2022-blake3-aes-256-gcm") and
      (.ss2022_password | type == "string" and length > 0) and
      (if .transport == "shadowtls" then
         (.shadowtls_password | type == "string" and length > 0) and
         (.shadowtls_sni | type == "string" and length > 0)
       else
         (has("shadowtls_password") | not) and (has("shadowtls_sni") | not)
       end);
    (.users | type == "array") and
    ([.users[].endpoints[].port] | length == (unique | length)) and
    all(.users[];
      (has("usage_offset_bytes") and (.usage_offset_bytes | type == "number") and
       .usage_offset_bytes == (.usage_offset_bytes | floor) and .usage_offset_bytes >= 0) and
      (.endpoints | type == "array" and length >= 1 and length <= 2) and
      ([.endpoints[].protocol] | length == (unique | length)) and
      ([.endpoints[].port] | length == (unique | length)) and
      (.protocol == .endpoints[0].protocol) and (.port == .endpoints[0].port) and
      all(.endpoints[];
        (.port | type == "number" and . == floor and . >= 1 and . <= 65535) and
        if .protocol == "ss2022" then
          valid_ss2022_endpoint
        elif .protocol == "anytls" then
          (.anytls_password | type == "string" and length > 0) and
          (.tls_sni | type == "string" and length > 0)
        else false end) and
      if .protocol == "ss2022" then
        (.transport == .endpoints[0].transport) and
        (.method == .endpoints[0].method) and
        (.ss2022_password == .endpoints[0].ss2022_password) and
        (if .transport == "shadowtls" then
           (.shadowtls_password == .endpoints[0].shadowtls_password) and
           (.shadowtls_sni == .endpoints[0].shadowtls_sni)
         else
           (has("shadowtls_password") | not) and (has("shadowtls_sni") | not)
         end)
      elif .protocol == "anytls" then
        (.anytls_password == .endpoints[0].anytls_password) and
        (.tls_sni == .endpoints[0].tls_sni)
      else false end)
  ' "$file" >/dev/null 2>&1
}

migrate_state() {
  local schema original_schema backup normalized legacy_method legacy_sni legacy_anytls_sni
  local needs_usage_offset=false
  jq -e 'type == "object"' "$STATE_FILE" >/dev/null || die "用户数据文件格式不正确，请从备份恢复或运行「服务与配置检查」：$STATE_FILE"
  schema="$(jq -r '.schema_version // 0' "$STATE_FILE")"
  original_schema="$schema"
  [[ "$schema" =~ ^[0-9]+$ ]] || die "用户数据文件的版本信息无效，请从备份恢复"
  ((schema <= STATE_SCHEMA_VERSION)) ||
    die "用户数据由更新版脚本创建，当前脚本无法安全读取。请先更新管理脚本（数据版本 ${schema}，当前支持 ${STATE_SCHEMA_VERSION}）"
  if jq -e '(.users | type == "array") and any(.users[]?; has("usage_offset_bytes") | not)' \
      "$STATE_FILE" >/dev/null 2>&1; then
    needs_usage_offset=true
  fi
  if ((schema == STATE_SCHEMA_VERSION)) && [[ "$needs_usage_offset" != true ]]; then
    validate_state_user_endpoints "$STATE_FILE" ||
      die "用户协议入口数据不完整或互相冲突，请从备份恢复或运行「服务与配置检查」：$STATE_FILE"
    return 0
  fi

  if ((schema == STATE_SCHEMA_VERSION)); then
    backup="$BACKUP_DIR/managed-users.pre-runtime-normalization-$(date '+%Y%m%d-%H%M%S-%N').json"
  else
    backup="$BACKUP_DIR/managed-users.pre-schema-${schema}-to-${STATE_SCHEMA_VERSION}-$(date '+%Y%m%d-%H%M%S-%N').json"
  fi
  cp -a -- "$STATE_FILE" "$backup" || return 1
  if ((schema == 0)); then
    atomic_state_update '.schema_version = 1 | .users = (.users // []) | .splits = (.splits // [])'
    schema=1
  fi
  if ((schema == 1)); then
    normalized="$(mktemp "$(dirname "$STATE_FILE")/.migration-config.XXXXXX")"
    register_temp_path "$normalized"
    if ! "$SINGBOX_BIN" format -c "$SINGBOX_CONFIG" > "$normalized"; then
      rm -f "$normalized"; restore_state_backup_atomically "$backup" || die "旧用户资料升级失败，且无法自动恢复原数据；备份：$backup"
      die "无法读取连接配置，旧用户资料未能升级；原数据已自动恢复"
    fi
    legacy_method="${SS_METHOD:-}"
    legacy_sni="${HANDSHAKE_SERVER:-}"
    if ! atomic_state_update '
      .users |= map(
        if (.protocol // "ss2022") == "ss2022" then
          . as $user |
          ($config[0].inbounds | map(select(.tag == ("ss-" + $user.name))) | first) as $ss |
          ($config[0].inbounds | map(select(.tag == ("st-" + $user.name))) | first) as $st |
          .method = (.method // $ss.method // (if $legacy_method == "" then null else $legacy_method end)) |
          .shadowtls_sni = (.shadowtls_sni // $st.handshake.server // (if $legacy_sni == "" then null else $legacy_sni end))
        else . end
      ) |
      .schema_version = 2
    ' --slurpfile config "$normalized" --arg legacy_method "$legacy_method" --arg legacy_sni "$legacy_sni"; then
      rm -f "$normalized"; restore_state_backup_atomically "$backup" || die "旧用户资料升级失败，且无法自动恢复原数据；备份：$backup"
      die "旧用户资料升级失败，原数据已自动恢复；备份：$backup"
    fi
    rm -f "$normalized"
    schema=2
  fi
  if ((schema == 2)); then
    legacy_anytls_sni="${TLS_SERVER_NAME:-}"
    if ! atomic_state_update '
      .users |= map(
        if (.protocol // "ss2022") == "anytls" then
          .tls_sni = (.tls_sni // (if $legacy_sni == "" then null else $legacy_sni end))
        else . end
      ) |
      .schema_version = 3
    ' --arg legacy_sni "$legacy_anytls_sni"; then
      restore_state_backup_atomically "$backup" || die "AnyTLS 用户资料升级失败，且无法自动恢复原数据；备份：$backup"
      die "AnyTLS 用户资料升级失败，原数据已自动恢复；备份：$backup"
    fi
    schema=3
  fi
  if ((schema == 3)); then
    if ! atomic_state_update '
      .users |= map(if has("usage_offset_bytes") then . else .usage_offset_bytes = 0 end) |
      .outbound_presets = (.outbound_presets // []) |
      .rule_presets = (.rule_presets // []) |
      .schema_version = 4
    '; then
      restore_state_backup_atomically "$backup" || die "预置数据格式升级失败，且无法自动恢复原数据；备份：$backup"
      die "预置数据格式升级失败，原数据已自动恢复；备份：$backup"
    fi
    schema=4
  fi
  if ((schema == 4)); then
    if ! atomic_state_update '
      def endpoint_from_legacy:
        if (.protocol // "ss2022") == "anytls" then
          {protocol:"anytls",port:.port,anytls_password:.anytls_password,tls_sni:.tls_sni}
        else
          {protocol:"ss2022",port:.port,shadowtls_password:.shadowtls_password,
           ss2022_password:.ss2022_password,method:.method,shadowtls_sni:.shadowtls_sni}
        end;
      .users |= map(
        .protocol = (.protocol // "ss2022") |
        if has("usage_offset_bytes") then . else .usage_offset_bytes = 0 end |
        .endpoints = [endpoint_from_legacy]
      ) |
      .schema_version = 5
    '; then
      restore_state_backup_atomically "$backup" || die "多协议账户数据升级失败，且无法自动恢复原数据；备份：$backup"
      die "多协议账户数据升级失败，原数据已自动恢复；备份：$backup"
    fi
    schema=5
  fi
  if ((schema == 5)); then
    if ! atomic_state_update '
      .users |= map(
        .endpoints |= map(
          if .protocol == "ss2022" then .transport = "shadowtls" else . end
        ) |
        if .protocol == "ss2022" then .transport = "shadowtls" else . end
      ) |
      .schema_version = 6
    '; then
      restore_state_backup_atomically "$backup" || die "SS2022 传输模式升级失败，且无法自动恢复原数据；备份：$backup"
      die "SS2022 传输模式升级失败，原数据已自动恢复；备份：$backup"
    fi
    schema=6
  fi
  if ((schema == STATE_SCHEMA_VERSION)) && [[ "$needs_usage_offset" == true && "$original_schema" == "$STATE_SCHEMA_VERSION" ]]; then
    if ! atomic_state_update '
      .users |= map(if has("usage_offset_bytes") then . else .usage_offset_bytes = 0 end)
    '; then
      restore_state_backup_atomically "$backup" || die "用户运行字段补齐失败，且无法自动恢复原数据；备份：$backup"
      die "用户运行字段补齐失败，原数据已自动恢复；备份：$backup"
    fi
  fi
  ((schema == STATE_SCHEMA_VERSION)) || {
    restore_state_backup_atomically "$backup" || die "当前脚本无法升级这份旧用户数据，且无法自动恢复原数据；备份：$backup"
    die "当前脚本无法升级这份旧用户数据，请先安装兼容版本（数据版本 ${schema}）"
  }
  jq -e --argjson schema "$STATE_SCHEMA_VERSION" '
    def valid_ss2022_endpoint:
      (.transport == "direct" or .transport == "shadowtls") and
      (.method == "2022-blake3-aes-128-gcm" or .method == "2022-blake3-aes-256-gcm") and
      (.ss2022_password | type == "string" and length > 0) and
      (if .transport == "shadowtls" then
         (.shadowtls_password | type == "string" and length > 0) and
         (.shadowtls_sni | type == "string" and length > 0)
       else
         (has("shadowtls_password") | not) and (has("shadowtls_sni") | not)
       end);
    .schema_version == $schema and (.users | type == "array") and (.splits | type == "array") and
    (.outbound_presets | type == "array") and (.rule_presets | type == "array") and
    ([.users[].endpoints[].port] | length == (unique | length)) and
    all(.users[];
      (has("usage_offset_bytes") and (.usage_offset_bytes | type == "number") and
       .usage_offset_bytes == (.usage_offset_bytes | floor) and .usage_offset_bytes >= 0) and
      (.endpoints | type == "array" and length >= 1 and length <= 2) and
      ([.endpoints[].protocol] | length == (unique | length)) and
      ([.endpoints[].port] | length == (unique | length)) and
      (.protocol == .endpoints[0].protocol) and (.port == .endpoints[0].port) and
      all(.endpoints[];
        (.port | type == "number" and . == floor and . >= 1 and . <= 65535) and
        if .protocol == "ss2022" then
          valid_ss2022_endpoint
        elif .protocol == "anytls" then
          (.anytls_password | type == "string" and length > 0) and
          (.tls_sni | type == "string" and length > 0)
        else false end) and
      if .protocol == "ss2022" then
        (.transport == .endpoints[0].transport) and
        (.method == .endpoints[0].method) and
        (.ss2022_password == .endpoints[0].ss2022_password) and
        (if .transport == "shadowtls" then
           (.shadowtls_password == .endpoints[0].shadowtls_password) and
           (.shadowtls_sni == .endpoints[0].shadowtls_sni)
         else
           (has("shadowtls_password") | not) and (has("shadowtls_sni") | not)
         end)
      elif .protocol == "anytls" then
        (.anytls_password == .endpoints[0].anytls_password) and
        (.tls_sni == .endpoints[0].tls_sni)
      else false end)
  ' "$STATE_FILE" >/dev/null || {
    restore_state_backup_atomically "$backup" || die "升级后的用户数据检查失败，且无法自动恢复原数据；备份：$backup"
    die "升级后的用户数据检查失败，已恢复原数据；备份：$backup"
  }
  if ((original_schema == STATE_SCHEMA_VERSION)); then
    log "用户数据已自动补齐新版运行字段；补齐前备份：$backup"
  else
    log "用户数据已自动升级到新版格式；升级前备份：$backup"
  fi
}

remove_obsolete_manager_config() {
  local tmp backup
  grep -Eq '^(SS_METHOD|HANDSHAKE_SERVER|TLS_SERVER_NAME|PORT_MIN|PORT_MAX)=' "$CONF_FILE" || return 0
  backup="$BACKUP_DIR/sb-user-manager.conf.pre-legacy-cleanup-$(date '+%Y%m%d-%H%M%S-%N')"
  cp -a -- "$CONF_FILE" "$backup" || return 1
  tmp="$(mktemp "$(dirname "$CONF_FILE")/.sb-user-manager.conf.XXXXXX")" || return 1
  register_temp_path "$tmp"
  if ! awk '!/^(SS_METHOD|HANDSHAKE_SERVER|TLS_SERVER_NAME|PORT_MIN|PORT_MAX)=/' "$CONF_FILE" > "$tmp"; then rm -f -- "$tmp"; return 1; fi
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  chown root:root "$tmp" 2>/dev/null || true
  mv -- "$tmp" "$CONF_FILE" || return 1
  log "无效或过时的全局配置已删除；配置备份：$backup"
}

write_global_sni_config() {
  local ss_sni="$1" anytls_sni="$2" reason="${3:-update}" tmp backup
  validate_shadowtls_sni "$ss_sni"
  validate_shadowtls_sni "$anytls_sni"
  backup="$BACKUP_DIR/sb-user-manager.conf.pre-sni-${reason}-$(date '+%Y%m%d-%H%M%S-%N')"
  cp -a -- "$CONF_FILE" "$backup" || return 1
  tmp="$(mktemp "$(dirname "$CONF_FILE")/.sb-user-manager.conf.XXXXXX")" || return 1
  register_temp_path "$tmp" || return 1
  if ! awk '!/^(SS2022_SHADOWTLS_SNI|ANYTLS_SNI)=/' "$CONF_FILE" > "$tmp" ||
     ! printf 'SS2022_SHADOWTLS_SNI="%s"\nANYTLS_SNI="%s"\n' "$ss_sni" "$anytls_sni" >> "$tmp" ||
     ! chmod 600 "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chown root:root "$tmp" 2>/dev/null || true
  mv -- "$tmp" "$CONF_FILE" || return 1
  sync_transaction_path "$CONF_FILE" || return 1
  SS2022_SHADOWTLS_SNI="$ss_sni"
  ANYTLS_SNI="$anytls_sni"
}

ensure_global_sni_config() {
  validate_shadowtls_sni "$SS2022_SHADOWTLS_SNI"
  validate_shadowtls_sni "$ANYTLS_SNI"
  if [[ "$(grep -Ec '^SS2022_SHADOWTLS_SNI=' "$CONF_FILE" || true)" == 1 &&
        "$(grep -Ec '^ANYTLS_SNI=' "$CONF_FILE" || true)" == 1 ]]; then
    return 0
  fi
  write_global_sni_config "$SS2022_SHADOWTLS_SNI" "$ANYTLS_SNI" migration || return 1
  log "已写入全局 SNI 配置；原配置备份：$BACKUP_DIR"
}

backup_files() {
  local stamp config_backup state_backup manager_backup
  stamp="$(date '+%Y%m%d-%H%M%S-%N').$$"
  config_backup="$BACKUP_DIR/config.json.$stamp"
  state_backup="$BACKUP_DIR/managed-users.json.$stamp"
  manager_backup="$BACKUP_DIR/sb-user-manager.conf.$stamp"
  if ! cp -a -- "$SINGBOX_CONFIG" "$config_backup"; then
    rm -f -- "$config_backup" "$state_backup" "$manager_backup"
    return 1
  fi
  if ! cp -a -- "$STATE_FILE" "$state_backup"; then
    rm -f -- "$config_backup" "$state_backup" "$manager_backup"
    return 1
  fi
  if [[ -r "$CONF_FILE" ]] && ! cp -a -- "$CONF_FILE" "$manager_backup"; then
    rm -f -- "$config_backup" "$state_backup" "$manager_backup"
    return 1
  fi
  printf '%s\n' "$stamp"
}

valid_operation_backup_stamp() {
  [[ "$1" =~ ^[0-9]{8}-[0-9]{6}-[0-9]+\.[0-9]+$ ]]
}

operation_backup_group_is_complete() {
  local stamp="$1" path
  valid_operation_backup_stamp "$stamp" || return 1
  for path in \
    "$BACKUP_DIR/config.json.$stamp" \
    "$BACKUP_DIR/managed-users.json.$stamp"; do
    [[ -f "$path" && ! -L "$path" ]] || return 1
  done
  # 旧版本只保存配置和用户状态；新版额外保存 Nfuse。两种完整格式都可安全按组整理。
  path="$BACKUP_DIR/nfuse.json.$stamp"
  [[ ! -e "$path" && ! -L "$path" ]] || [[ -f "$path" && ! -L "$path" ]] || return 1
  path="$BACKUP_DIR/sb-user-manager.conf.$stamp"
  [[ ! -e "$path" && ! -L "$path" ]] || [[ -f "$path" && ! -L "$path" ]]
}

load_operation_backup_groups() {
  local path stamp
  OPERATION_BACKUP_GROUPS=()
  [[ -d "$BACKUP_DIR" && ! -L "$BACKUP_DIR" ]] || return 0
  while IFS= read -r path; do
    stamp="${path##*/config.json.}"
    operation_backup_group_is_complete "$stamp" || continue
    OPERATION_BACKUP_GROUPS[${#OPERATION_BACKUP_GROUPS[@]}]="$stamp"
  done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'config.json.*' -print | sort -r)
}

count_incomplete_operation_backup_files() {
  local path name stamp count=0
  [[ -d "$BACKUP_DIR" && ! -L "$BACKUP_DIR" ]] || { printf '0\n'; return 0; }
  while IFS= read -r path; do
    name="${path##*/}"
    case "$name" in
      config.json.*) stamp="${name#config.json.}";;
      managed-users.json.*) stamp="${name#managed-users.json.}";;
      sb-user-manager.conf.*) stamp="${name#sb-user-manager.conf.}";;
      nfuse.json.*) stamp="${name#nfuse.json.}";;
      *) continue;;
    esac
    valid_operation_backup_stamp "$stamp" || continue
    operation_backup_group_is_complete "$stamp" || ((count+=1))
  done < <(find "$BACKUP_DIR" -maxdepth 1 -type f \( \
    -name 'config.json.*' -o -name 'managed-users.json.*' -o \
    -name 'sb-user-manager.conf.*' -o -name 'nfuse.json.*' \) -print)
  printf '%s\n' "$count"
}

active_operation_backup_stamp() {
  local stamp
  [[ -f "$TRANSACTION_JOURNAL" && ! -L "$TRANSACTION_JOURNAL" ]] || return 1
  stamp="$(jq -r '.backup_stamp // empty' "$TRANSACTION_JOURNAL" 2>/dev/null)" || return 1
  valid_operation_backup_stamp "$stamp" || return 1
  printf '%s\n' "$stamp"
}

remove_operation_backup_group() {
  local stamp="$1" active="" path
  operation_backup_group_is_complete "$stamp" || return 1
  active="$(active_operation_backup_stamp 2>/dev/null || true)"
  [[ -z "$active" || "$stamp" != "$active" ]] || return 1
  for path in \
    "$BACKUP_DIR/config.json.$stamp" \
    "$BACKUP_DIR/managed-users.json.$stamp" \
    "$BACKUP_DIR/sb-user-manager.conf.$stamp" \
    "$BACKUP_DIR/nfuse.json.$stamp"; do
    if [[ -e "$path" || -L "$path" ]]; then
      [[ -f "$path" && ! -L "$path" ]] || return 1
      rm -f -- "$path" || return 1
    fi
  done
}

prune_operation_transaction_backups() {
  local keep="$1" active="" stamp kept=0 failed=false
  [[ "$keep" =~ ^[0-9]+$ ]] || return 1
  load_operation_backup_groups
  active="$(active_operation_backup_stamp 2>/dev/null || true)"
  ((${#OPERATION_BACKUP_GROUPS[@]} > 0)) || return 0
  for stamp in "${OPERATION_BACKUP_GROUPS[@]}"; do
    if [[ -n "$active" && "$stamp" == "$active" ]]; then
      continue
    fi
    if ((kept < keep)); then
      ((kept+=1))
      continue
    fi
    remove_operation_backup_group "$stamp" || failed=true
  done
  [[ "$failed" == false ]]
}

restore_backup() {
  local stamp="$1" config_source state_source manager_source config_tmp state_tmp previous_state manager_tmp=""
  config_source="$BACKUP_DIR/config.json.$stamp"
  state_source="$BACKUP_DIR/managed-users.json.$stamp"
  manager_source="$BACKUP_DIR/sb-user-manager.conf.$stamp"
  if [[ ! -r "$config_source" || ! -r "$state_source" ]]; then
    log "严重错误：事务备份不完整，无法恢复：$stamp"
    return 1
  fi
  config_tmp="$(mktemp "$(dirname "$SINGBOX_CONFIG")/.restore-config.XXXXXX")" || return 1
  register_temp_path "$config_tmp"
  state_tmp="$(mktemp "$(dirname "$STATE_FILE")/.restore-state.XXXXXX")" || {
    rm -f -- "$config_tmp"
    return 1
  }
  register_temp_path "$state_tmp"
  previous_state="$(mktemp "$(dirname "$STATE_FILE")/.restore-previous-state.XXXXXX")" || {
    rm -f -- "$config_tmp" "$state_tmp"
    return 1
  }
  register_temp_path "$previous_state"
  if [[ -r "$manager_source" ]]; then
    manager_tmp="$(mktemp "$(dirname "$CONF_FILE")/.restore-manager-config.XXXXXX")" || {
      rm -f -- "$config_tmp" "$state_tmp" "$previous_state"
      return 1
    }
    register_temp_path "$manager_tmp"
  fi
  if ! cp -a -- "$config_source" "$config_tmp" ||
     ! cp -a -- "$state_source" "$state_tmp" ||
     ! cp -a -- "$STATE_FILE" "$previous_state"; then
    rm -f -- "$config_tmp" "$state_tmp" "$previous_state" "$manager_tmp"
    log "严重错误：无法阶段化事务备份"
    return 1
  fi
  if [[ -n "$manager_tmp" ]] && ! cp -a -- "$manager_source" "$manager_tmp"; then
    rm -f -- "$config_tmp" "$state_tmp" "$previous_state" "$manager_tmp"
    log "严重错误：无法阶段化管理配置备份"
    return 1
  fi
  if ! "$SINGBOX_BIN" check -c "$config_tmp"; then
    rm -f -- "$config_tmp" "$state_tmp" "$previous_state" "$manager_tmp"
    log "严重错误：备份中的 sing-box 配置校验失败"
    return 1
  fi
  if ! jq -e 'type == "object"' "$state_tmp" >/dev/null; then
    rm -f -- "$config_tmp" "$state_tmp" "$previous_state" "$manager_tmp"
    log "严重错误：备份中的用户状态结构无效"
    return 1
  fi
  if ! mv -- "$state_tmp" "$STATE_FILE"; then
    rm -f -- "$config_tmp" "$state_tmp" "$previous_state" "$manager_tmp"
    log "严重错误：无法从备份恢复用户状态"
    return 1
  fi
  if ! mv -- "$config_tmp" "$SINGBOX_CONFIG"; then
    if ! mv -- "$previous_state" "$STATE_FILE"; then
      log "严重错误：sing-box 配置恢复失败，且无法还原原用户状态"
    fi
    rm -f -- "$config_tmp" "$state_tmp" "$previous_state" "$manager_tmp"
    log "严重错误：无法从备份恢复 sing-box 配置"
    return 1
  fi
  rm -f -- "$previous_state"
  if [[ -n "$manager_tmp" ]]; then
    if ! bash -n "$manager_tmp" || ! mv -- "$manager_tmp" "$CONF_FILE" || ! load_runtime_config; then
      rm -f -- "$manager_tmp"
      log "严重错误：无法从备份恢复管理配置"
      return 1
    fi
  fi
  if ! "$SINGBOX_BIN" check -c "$SINGBOX_CONFIG"; then
    log "严重错误：备份已恢复，但备份配置校验失败"
    return 1
  fi
  systemctl reset-failed "$SINGBOX_SERVICE" 2>/dev/null || true
  if ! systemctl restart "$SINGBOX_SERVICE"; then
    log "严重错误：备份已恢复，但 sing-box 重启失败"
    return 1
  fi
  if ! systemctl is-active --quiet "$SINGBOX_SERVICE"; then
    log "严重错误：备份已恢复，但 sing-box 未处于 active 状态"
    return 1
  fi
}

validate_nfuse_snapshot() {
  jq -e '
    type == "array" and
    all(.[ ];
      (.name | type == "string" and length > 0) and
      (.tier == "a" or .tier == "b" or .tier == "c") and
      (.limit_gib | type == "number" and . >= 0) and
      (.used_bytes | type == "number" and . >= 0 and . == floor) and
      (.ports | type == "array") and
      all(.ports[];
        .start as $port_start | .end as $port_end |
        (.id | type == "number" and . > 0 and . == floor) and
        ($port_start | type == "number" and . >= 1 and . <= 65535 and . == floor) and
        ($port_end | type == "number" and . >= $port_start and . <= 65535 and . == floor))
    )
  ' "$1" >/dev/null
}

sync_transaction_path() {
  sync -f "$1" 2>/dev/null
}

write_transaction_journal() {
  local operation="$1" stamp="$2" tmp
  install -d -m 700 "$TRANSACTION_DIR" || return 1
  tmp="$(mktemp "$TRANSACTION_DIR/.transaction.XXXXXX")" || return 1
  register_temp_path "$tmp"
  if ! jq -n \
    --argjson format "$TRANSACTION_FORMAT_VERSION" \
    --arg operation "$operation" \
    --arg stamp "$stamp" \
    --arg started_at "$(date -Iseconds)" \
    --arg script_version "$SCRIPT_VERSION" \
    --argjson pid "$$" \
    '{format_version:$format,status:"active",operation:$operation,backup_stamp:$stamp,started_at:$started_at,script_version:$script_version,pid:$pid}' > "$tmp" ||
    ! chmod 600 "$tmp" || ! sync_transaction_path "$tmp" || ! mv -- "$tmp" "$TRANSACTION_JOURNAL" ||
    ! sync_transaction_path "$TRANSACTION_DIR"; then
    rm -f -- "$tmp"
    return 1
  fi
}

begin_operation_transaction() {
  local operation="$1" nfuse_tmp nfuse_snapshot stamp
  if ((ACTIVE_TRANSACTION_DEPTH > 0)); then
    ((ACTIVE_TRANSACTION_DEPTH+=1))
    return 0
  fi
  if [[ -e "$TRANSACTION_JOURNAL" ]]; then
    printf '错误：发现上次未完成的操作，而且尚未恢复。为保护现有数据，本次操作已停止。恢复记录：%s\n' "$TRANSACTION_JOURNAL" >&2
    return 1
  fi
  install -d -m 700 "$TRANSACTION_DIR" "$BACKUP_DIR" || return 1
  nfuse_tmp="$(mktemp "$BACKUP_DIR/.nfuse-snapshot.XXXXXX")" || return 1
  register_temp_path "$nfuse_tmp"
  if ! nfuse persist >/dev/null || ! nfuse list --json | jq '.' > "$nfuse_tmp" ||
     ! validate_nfuse_snapshot "$nfuse_tmp" || ! chmod 600 "$nfuse_tmp" ||
     ! sync_transaction_path "$nfuse_tmp"; then
    rm -f -- "$nfuse_tmp"
    return 1
  fi
  stamp="$(backup_files)" || { rm -f -- "$nfuse_tmp"; return 1; }
  nfuse_snapshot="$BACKUP_DIR/nfuse.json.$stamp"
  if ! sync_transaction_path "$BACKUP_DIR/config.json.$stamp" ||
     ! sync_transaction_path "$BACKUP_DIR/managed-users.json.$stamp" ||
     ! { [[ ! -f "$BACKUP_DIR/sb-user-manager.conf.$stamp" ]] || sync_transaction_path "$BACKUP_DIR/sb-user-manager.conf.$stamp"; } ||
     ! mv -- "$nfuse_tmp" "$nfuse_snapshot" || ! sync_transaction_path "$BACKUP_DIR" ||
     ! write_transaction_journal "$operation" "$stamp"; then
    rm -f -- "$nfuse_tmp" "$nfuse_snapshot" \
      "$BACKUP_DIR/config.json.$stamp" "$BACKUP_DIR/managed-users.json.$stamp" "$BACKUP_DIR/sb-user-manager.conf.$stamp"
    return 1
  fi
  ACTIVE_TRANSACTION_STAMP="$stamp"
  ACTIVE_TRANSACTION_OPERATION="$operation"
  ACTIVE_TRANSACTION_DEPTH=1
}

validate_transaction_journal() {
  jq -e --argjson format "$TRANSACTION_FORMAT_VERSION" '
    .format_version == $format and .status == "active" and
    (.operation | type == "string" and length > 0) and
    (.backup_stamp | type == "string" and test("^[0-9]{8}-[0-9]{6}-[0-9]+\\.[0-9]+$")) and
    (.started_at | type == "string" and length > 0) and
    (.script_version | type == "string" and length > 0) and
    (.pid | type == "number" and . > 0 and . == floor)
  ' "$TRANSACTION_JOURNAL" >/dev/null
}

restore_nfuse_snapshot() {
  local stamp="$1" snapshot before_state
  local current_json managed_names desired_names name account tier limit anchor used port_spec port_id
  snapshot="$BACKUP_DIR/nfuse.json.$stamp"
  before_state="$BACKUP_DIR/managed-users.json.$stamp"
  [[ -r "$snapshot" && -r "$before_state" && -r "$STATE_FILE" ]] || return 1
  validate_nfuse_snapshot "$snapshot" || return 1
  jq -e '.users | type == "array"' "$before_state" >/dev/null || return 1
  jq -e '.users | type == "array"' "$STATE_FILE" >/dev/null || return 1
  managed_names="$(jq -r -s '
    [.[0].users[].name, .[1].users[].name] | unique[]
  ' "$before_state" "$STATE_FILE")" || return 1
  desired_names="$(jq -r --slurpfile state "$before_state" '
    .[] | .name as $name | select(any($state[0].users[]; .name == $name)) | $name
  ' "$snapshot")" || return 1
  current_json="$(nfuse list --json)" || return 1
  jq -e 'type == "array"' <<<"$current_json" >/dev/null || return 1

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if ! grep -Fxq -- "$name" <<<"$desired_names" &&
       jq -e --arg name "$name" '.[] | select(.name == $name)' <<<"$current_json" >/dev/null; then
      nfuse rm "$name" --cascade >/dev/null || return 1
      current_json="$(nfuse list --json)" || return 1
    fi
  done <<<"$managed_names"

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    account="$(jq -ec --arg name "$name" '.[] | select(.name == $name)' "$snapshot")" || return 1
    tier="$(jq -er '.tier | select(. == "a" or . == "b" or . == "c")' <<<"$account")" || return 1
    limit="$(jq -er '.limit_gib | select(type == "number" and . >= 0)' <<<"$account")" || return 1
    anchor="$(jq -r --arg name "$name" '.users[] | select(.name == $name) | (.billing_anchor // 1)' "$before_state")" || return 1
    [[ "$anchor" =~ ^[0-9]+$ ]] && ((anchor >= 1 && anchor <= 28)) || anchor=1
    used="$(jq -er '.used_bytes | select(type == "number" and . >= 0 and . == floor)' <<<"$account")" || return 1
    if jq -e --arg name "$name" '.[] | select(.name == $name)' <<<"$current_json" >/dev/null; then
      nfuse set-tier "$name" --tier "$tier" --limit "$limit" --anchor "$anchor" >/dev/null || return 1
      while IFS= read -r port_id; do
        [[ -n "$port_id" ]] || continue
        nfuse port rm "$port_id" >/dev/null || return 1
      done < <(jq -r --arg name "$name" '.[] | select(.name == $name) | .ports[].id' <<<"$current_json")
    else
      nfuse add "$name" --tier "$tier" --limit "$limit" --anchor "$anchor" >/dev/null || return 1
    fi
    while IFS= read -r port_spec; do
      [[ -n "$port_spec" ]] || continue
      nfuse port add "$name" "$port_spec" >/dev/null || return 1
    done < <(jq -r '.ports[] | if .start == .end then (.start|tostring) else ((.start|tostring) + "-" + (.end|tostring)) end' <<<"$account")
    if [[ "$tier" != c ]]; then
      nfuse set-usage "$name" "$used" >/dev/null || return 1
    fi
    current_json="$(nfuse list --json)" || return 1
  done <<<"$desired_names"
  nfuse persist >/dev/null || return 1
  current_json="$(nfuse list --json)" || return 1
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    account="$(jq -c --arg name "$name" '.[] | select(.name == $name) | {name,tier,limit_gib,used_bytes:(if .tier == "c" then 0 else .used_bytes end),ports:([.ports[]|{"start":.start,"end":.end}]|sort_by(.start,.end))}' "$snapshot")" || return 1
    jq -e --arg name "$name" --argjson expected "$account" '
      [.[] | select(.name == $name) | {name,tier,limit_gib,used_bytes,ports:([.ports[]|{"start":.start,"end":.end}]|sort_by(.start,.end))}] == [$expected]
    ' <<<"$current_json" >/dev/null || return 1
  done <<<"$desired_names"
}

restore_tier_c_usage_offsets() {
  local stamp="$1" snapshot
  snapshot="$BACKUP_DIR/nfuse.json.$stamp"
  [[ -r "$snapshot" ]] || return 1
  jq -e --slurpfile snapshot "$snapshot" '
    any(.users[];
      ((.metered // (.limit_gib != null)) == false) as $self |
      .name as $name |
      $self and any($snapshot[0][]; .name == $name and .tier == "c" and .used_bytes > 0))
  ' "$STATE_FILE" >/dev/null || return 0
  atomic_state_update '
    .users |= map(
      if ((.metered // (.limit_gib != null)) == false) then
        . as $user |
        ([ $snapshot[0][] | select(.name == $user.name and .tier == "c") | .used_bytes ] | first // 0) as $live |
        .usage_offset_bytes = ((.usage_offset_bytes // 0) + $live)
      else . end)
  ' --slurpfile snapshot "$snapshot" || return 1
  sync_transaction_path "$STATE_FILE"
}

clear_operation_transaction() {
  rm -f -- "$TRANSACTION_JOURNAL" || return 1
  sync_transaction_path "$TRANSACTION_DIR" || return 1
  ACTIVE_TRANSACTION_STAMP=""
  ACTIVE_TRANSACTION_OPERATION=""
  ACTIVE_TRANSACTION_DEPTH=0
}

rollback_operation_transaction() {
  local rc="${1:-1}" stamp="${ACTIVE_TRANSACTION_STAMP:-}" operation="${ACTIVE_TRANSACTION_OPERATION:-未知}"
  if [[ -z "$stamp" && -r "$TRANSACTION_JOURNAL" ]]; then
    validate_transaction_journal || { log "严重错误：事务日志损坏，拒绝自动恢复：$TRANSACTION_JOURNAL"; return 1; }
    stamp="$(jq -r '.backup_stamp' "$TRANSACTION_JOURNAL")"
    operation="$(jq -r '.operation' "$TRANSACTION_JOURNAL")"
  fi
  [[ -n "$stamp" ]] || return "$rc"
  trap - ERR
  clear_signal_rollback
  log "上次操作未正常完成，正在自动恢复修改前的数据：$operation"
  if ! restore_nfuse_snapshot "$stamp" || ! restore_backup "$stamp" || ! restore_tier_c_usage_offsets "$stamp"; then
    log "严重错误：自动恢复失败。为避免扩大问题，请勿继续修改用户或分流；恢复记录和备份已保留"
    return 1
  fi
  if ! clear_operation_transaction; then
    log "严重错误：数据已经恢复，但无法清除恢复标记：$TRANSACTION_JOURNAL"
    return 1
  fi
  if ! prune_operation_transaction_backups "$OPERATION_BACKUP_RETENTION"; then
    log "提示：旧的内部操作备份暂未能自动整理，不影响本次恢复结果"
  fi
  log "已恢复到上次操作开始前的状态：$operation"
  return "$rc"
}

commit_operation_transaction() {
  local nfuse_db="${NFUSE_DB:-/var/lib/nfuse/nfuse.db}"
  ((ACTIVE_TRANSACTION_DEPTH > 0)) || return 0
  if ((ACTIVE_TRANSACTION_DEPTH > 1)); then
    ((ACTIVE_TRANSACTION_DEPTH-=1))
    return 0
  fi
  nfuse persist >/dev/null || return 1
  sync_transaction_path "$SINGBOX_CONFIG" || return 1
  sync_transaction_path "$STATE_FILE" || return 1
  if [[ -f "$CONF_FILE" ]]; then sync_transaction_path "$CONF_FILE" || return 1; fi
  if [[ -f "$nfuse_db" ]]; then sync_transaction_path "$nfuse_db" || return 1; fi
  if [[ -f "$nfuse_db-wal" ]]; then sync_transaction_path "$nfuse_db-wal" || return 1; fi
  clear_operation_transaction || return 1
  if ! prune_operation_transaction_backups "$OPERATION_BACKUP_RETENTION"; then
    log "提示：旧的内部操作备份暂未能自动整理，不影响本次操作结果"
  fi
}

recover_pending_transaction() {
  [[ -e "$TRANSACTION_JOURNAL" ]] || return 0
  validate_transaction_journal || die "事务日志格式无效，拒绝继续：$TRANSACTION_JOURNAL"
  ACTIVE_TRANSACTION_STAMP="$(jq -r '.backup_stamp' "$TRANSACTION_JOURNAL")"
  ACTIVE_TRANSACTION_OPERATION="$(jq -r '.operation' "$TRANSACTION_JOURNAL")"
  ACTIVE_TRANSACTION_DEPTH=1
  log "检测到上次操作未正常结束，正在自动恢复：$ACTIVE_TRANSACTION_OPERATION"
  rollback_operation_transaction 0 || die "自动恢复失败。请保留恢复记录并停止继续操作：$TRANSACTION_JOURNAL"
}

is_environment_recovery_path() {
  case "$1" in
    /etc/sb-user-manager.conf|/etc/sing-box|/etc/sing-box/*|/etc/systemd/system/sing-box.service|/etc/systemd/system/nfuse.service|/etc/systemd/system/sb-user-expiry.service|/etc/systemd/system/sb-user-expiry.timer|/etc/systemd/system/multi-user.target.wants/sing-box.service|/etc/systemd/system/multi-user.target.wants/nfuse.service|/etc/systemd/system/timers.target.wants/sb-user-expiry.timer|/var/lib/nfuse|/var/lib/nfuse/*|/var/lib/sing-box|/var/lib/sing-box/*|/var/lib/sb-user-manager|/var/lib/sb-user-manager/*|/usr/local/sbin/sb-user-manager|/usr/local/bin/sbm|/usr/local/bin/sing-box|/usr/local/bin/nfuse|/run/nfuse.sock) return 0;;
    *) return 1;;
  esac
}

release_environment_lock() {
  flock -u 8 2>/dev/null || true
  { exec 8>&-; } 2>/dev/null || true
}

begin_environment_transaction() {
  local operation="$1" snapshot="$2" tmp path
  shift 2
  install -d -m 755 "$(dirname "$ENVIRONMENT_LOCK_FILE")" || return 1
  exec 8>"$ENVIRONMENT_LOCK_FILE"
  flock -n 8 || { release_environment_lock; return 1; }
  [[ ! -e "$ENVIRONMENT_TRANSACTION_JOURNAL" ]] || { release_environment_lock; return 1; }
  verify_environment_backup "$snapshot" || { release_environment_lock; return 1; }
  for path in "$@"; do is_environment_recovery_path "$path" || { release_environment_lock; return 1; }; done
  install -d -m 700 "$(dirname "$ENVIRONMENT_TRANSACTION_JOURNAL")" || { release_environment_lock; return 1; }
  tmp="$(mktemp "$(dirname "$ENVIRONMENT_TRANSACTION_JOURNAL")/.transaction.XXXXXX")" || { release_environment_lock; return 1; }
  register_temp_path "$tmp" || { release_environment_lock; return 1; }
  if ! jq -n --argjson format "$TRANSACTION_FORMAT_VERSION" --arg operation "$operation" \
      --arg snapshot "$snapshot" --arg started_at "$(date -Iseconds)" --arg script_version "$SCRIPT_VERSION" \
      '{format_version:$format,status:"active",kind:"environment",operation:$operation,snapshot:$snapshot,started_at:$started_at,script_version:$script_version,cleanup_paths:$ARGS.positional}' \
      --args "$@" > "$tmp" ||
     ! chmod 600 "$tmp" || ! sync_transaction_path "$tmp" ||
     ! mv -- "$tmp" "$ENVIRONMENT_TRANSACTION_JOURNAL" ||
     ! sync_transaction_path "$(dirname "$ENVIRONMENT_TRANSACTION_JOURNAL")"; then
    rm -f -- "$tmp" # managed-step-errexit-ok: best-effort cleanup before forced failure
    release_environment_lock
    return 1
  fi
}

validate_environment_transaction() {
  local path
  jq -e --argjson format "$TRANSACTION_FORMAT_VERSION" '
    .format_version == $format and .status == "active" and .kind == "environment" and
    (.operation|type=="string" and length>0) and (.snapshot|type=="string" and length>0) and
    (.cleanup_paths|type=="array") and all(.cleanup_paths[]; type=="string" and length>0)
  ' "$ENVIRONMENT_TRANSACTION_JOURNAL" >/dev/null || return 1
  while IFS= read -r path; do is_environment_recovery_path "$path" || return 1; done < <(jq -r '.cleanup_paths[]' "$ENVIRONMENT_TRANSACTION_JOURNAL")
}

clear_environment_transaction() {
  local rc=0
  rm -f -- "$ENVIRONMENT_TRANSACTION_JOURNAL" || rc=1
  sync_transaction_path "$(dirname "$ENVIRONMENT_TRANSACTION_JOURNAL")" || rc=1
  release_environment_lock
  return "$rc"
}

recover_environment_transaction() {
  local snapshot operation path
  [[ -e "$ENVIRONMENT_TRANSACTION_JOURNAL" ]] || return 0
  install -d -m 755 "$(dirname "$ENVIRONMENT_LOCK_FILE")" || die "无法创建环境恢复锁目录"
  exec 8>"$ENVIRONMENT_LOCK_FILE"
  flock -n 8 || die "另一个环境恢复或部署操作正在执行"
  validate_environment_transaction || die "环境恢复日志无效，拒绝继续：$ENVIRONMENT_TRANSACTION_JOURNAL"
  snapshot="$(jq -r '.snapshot' "$ENVIRONMENT_TRANSACTION_JOURNAL")"
  operation="$(jq -r '.operation' "$ENVIRONMENT_TRANSACTION_JOURNAL")"
  prepare_environment_backup_for_restore "$snapshot" ||
    die "操作前完整备份已经损坏或无法安全整理，为保护现有数据，本次自动恢复已停止：$snapshot"
  log "检测到上次安装或更新未正常结束，正在恢复原环境：$operation"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    path="$(system_path "$path")"
    if [[ -d "$path" && ! -L "$path" ]]; then rm -rf -- "$path"; else rm -f -- "$path"; fi
  done < <(jq -r '.cleanup_paths[]' "$ENVIRONMENT_TRANSACTION_JOURNAL" | awk '{print length, $0}' | sort -rn | cut -d' ' -f2-)
  restore_environment_backup "$snapshot" || die "环境自动恢复失败。请停止继续部署，并保留完整备份：$snapshot"
  clear_environment_transaction || die "环境已经恢复，但无法清除恢复标记：$ENVIRONMENT_TRANSACTION_JOURNAL"
  log "服务器已恢复到上次安装或更新前的状态：$operation"
}

rollback_active_operation() {
  local rc="${1:-$?}"
  trap - ERR
  clear_signal_rollback
  log "操作失败，正在自动撤销本次修改"
  rollback_operation_transaction "$rc" || true
  return "$rc"
}

run_step_or_rollback() {
  local rollback="$1" rc
  shift
  if "$@"; then
    return 0
  else
    rc=$?
  fi
  "$rollback" "$rc" || true
  return "$rc"
}

run_managed_step() {
  run_step_or_rollback rollback_active_operation "$@"
}

run_quietly() {
  "$@" >/dev/null
}

write_command_output() {
  local output="$1"
  shift
  "$@" > "$output"
}

list_singbox_owned_ssh_sockets() {
  local client_port="$1" server_port="$2"
  command -v ss >/dev/null 2>&1 || return 1
  ss -Htnp state established \
    "( sport = :${client_port} and dport = :${server_port} )" 2>/dev/null
}

ssh_connection_uses_local_singbox() {
  local client_ip client_port server_ip server_port extra socket_rows
  [[ -n "${SSH_CONNECTION:-}" ]] || return 1
  read -r client_ip client_port server_ip server_port extra <<<"$SSH_CONNECTION"
  [[ -n "$client_ip" && -n "$server_ip" && -z "${extra:-}" ]] || return 1
  [[ "$client_port" =~ ^[1-9][0-9]{0,4}$ && "$server_port" =~ ^[1-9][0-9]{0,4}$ ]] || return 1
  ((client_port <= 65535 && server_port <= 65535)) || return 1
  socket_rows="$(list_singbox_owned_ssh_sockets "$client_port" "$server_port")" || return 1
  grep -Fq '"sing-box"' <<<"$socket_rows"
}

ensure_safe_ssh_for_singbox_restart() {
  local phase="${1:-preflight}"
  ssh_connection_uses_local_singbox || return 0
  cat <<'EOF'
检测到当前 SSH 连接正通过这台服务器自己的 sing-box 节点。
接下来的操作需要重启 sing-box；继续会中断当前连接，并使本次操作等待下次运行脚本时自动恢复。
EOF
  if [[ "$phase" == rollback ]]; then
    echo '为避免连接中断，sing-box 尚未重启；脚本正在撤销本次尚未完成的修改。'
  else
    echo '为避免连接中断，本次操作已经停止，服务器数据尚未修改。'
  fi
  echo '请在当前 SSH 软件或本地代理中把这台服务器的 SSH 地址设为直连，然后重新运行。'
  return 1
}

start_managed_operation() {
  begin_operation_transaction "$1" || return 1
  trap rollback_active_operation ERR
  set_signal_rollback rollback_active_operation
}

finish_managed_operation() {
  local rc
  ((ACTIVE_TRANSACTION_DEPTH > 0)) || return 0
  if ((ACTIVE_TRANSACTION_DEPTH > 1)); then
    commit_operation_transaction
    return $?
  fi
  trap - ERR
  clear_signal_rollback
  if commit_operation_transaction; then return 0; fi
  rc=$?
  log "修改未能安全保存，正在恢复操作前的数据"
  rollback_operation_transaction "$rc" || true
  return "$rc"
}
