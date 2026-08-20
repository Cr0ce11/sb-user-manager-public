
# sing-box 部署的管理配置。内容与历史版本一字不变，**不写 PROXY_KERNEL**：
# 管理配置的解析对未知键直接报错退出，写进去会让回退到旧脚本时启动不了。
# 详见公开 Issue #158。
write_singbox_manager_config() {
  cat > "$CONF_FILE" <<EOF || return 1
HANDSHAKE_PORT=443
SHADOWTLS_STRICT_MODE=true
SS2022_SHADOWTLS_SNI="$DEFAULT_SS2022_SHADOWTLS_SNI"
ANYTLS_SNI="$DEFAULT_ANYTLS_SNI"
SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_CONFIG="/etc/sing-box/config.json"
SINGBOX_SERVICE="sing-box"
NFUSE_BIN="/usr/local/bin/nfuse"
NFUSE_SOCKET="/run/nfuse.sock"
STATE_FILE="/etc/sing-box/managed-users.json"
BACKUP_DIR="/etc/sing-box/backups"
LOCK_FILE="/run/lock/sb-user-manager.lock"
CLIENT_SERVER_PORT_OVERRIDE=""
PUBLIC_SERVER_OVERRIDE=""
EOF
}

# mihomo 部署的管理配置。这类机器本来就退不回不支持 mihomo 的脚本，
# 因此写 PROXY_KERNEL 不构成新的回退障碍。
# 管理器自身的数据（用户资料、内部备份、AnyTLS 证书）仍然放在 /etc/sing-box 下：
# 那些路径是管理器的，不是 sing-box 的，改动它们会牵动迁移与备份子系统——
# 本片不动那里。代价是 mihomo 机器上会出现一个名字容易误解的 /etc/sing-box 目录。
# 退路：若在 2f 开放菜单选择之前认为这个名字不可接受，把管理器数据整体迁到
# /etc/sb-user-manager 是一片独立的工作；此刻还没有任何 mihomo 正式部署，
# 迁移成本为零，越往后越贵。
write_mihomo_manager_config() {
  cat > "$CONF_FILE" <<EOF || return 1
HANDSHAKE_PORT=443
SHADOWTLS_STRICT_MODE=true
SS2022_SHADOWTLS_SNI="$DEFAULT_SS2022_SHADOWTLS_SNI"
ANYTLS_SNI="$DEFAULT_ANYTLS_SNI"
PROXY_KERNEL="mihomo"
MIHOMO_BIN="/usr/local/bin/mihomo"
MIHOMO_CONFIG="/etc/mihomo/config.json"
MIHOMO_SERVICE="mihomo"
MIHOMO_WORK_DIR="/var/lib/mihomo"
NFUSE_BIN="/usr/local/bin/nfuse"
NFUSE_SOCKET="/run/nfuse.sock"
STATE_FILE="/etc/sing-box/managed-users.json"
BACKUP_DIR="/etc/sing-box/backups"
LOCK_FILE="/run/lock/sb-user-manager.lock"
CLIENT_SERVER_PORT_OVERRIDE=""
PUBLIC_SERVER_OVERRIDE=""
EOF
}

write_manager_config() {
  case "$PROXY_KERNEL" in
    singbox) write_singbox_manager_config || return 1 ;;
    mihomo) write_mihomo_manager_config || return 1 ;;
    *) kernel_unknown || return 1 ;;
  esac
  chmod 600 "$CONF_FILE" || return 1
  chown root:root "$CONF_FILE" || return 1
}

write_base_config() {
  local config skeleton
  config="$(kernel_config_path)" || return 1
  skeleton="$(kernel_skeleton_ensure_program)" || return 1
  # 骨架只在 src/05-kernel.sh 定义一处；这里对空对象应用它得到初始配置。
  jq -n "{} | $skeleton" > "$config" || return 1
  chmod 600 "$config" || return 1
}

deployed_state_path() {
  if ! (
    trap - ERR
    load_runtime_config || exit 1
    printf '%s\n' "$STATE_FILE"
  ); then
    return 1
  fi
}

initialize_deployed_state() {
  local reset="${1:-false}"
  if ! (
    # load_runtime_config/init_state 的 die 会显式 exit；在子进程内捕获，
    # 再将普通非零状态交给外层部署事务的 ERR trap 统一回滚。
    trap - ERR
    load_runtime_config || exit 1
    if [[ "$reset" == true ]]; then rm -f -- "$STATE_FILE" || exit 1; fi
    init_state || exit 1
  ); then
    return 1
  fi
}

cleanup_deploy_created_paths() {
  (($# > 0)) || return 0
  local -a paths=("$@")
  local i
  for ((i=${#paths[@]}-1; i>=0; i--)); do
    rm -rf -- "${paths[$i]}" || true
  done
}

write_singbox_unit() {
  cat > "$(system_path /etc/systemd/system/sing-box.service)" <<'EOF' || return 1
[Unit]
Description=sing-box service
After=network-online.target nss-lookup.target
Wants=network-online.target
[Service]
Type=simple
User=root
StateDirectory=sing-box
ExecStart=/usr/local/bin/sing-box -D /var/lib/sing-box -c /etc/sing-box/config.json run
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity
[Install]
WantedBy=multi-user.target
EOF
}

# mihomo 的服务单元。与 sing-box 单元的三处实质差别：
# 1. 命令行是 `-d 工作目录 -f 配置`，不是 `-c 配置`。
# 2. 需要 SAFE_PATHS：mihomo 默认拒绝加载工作目录之外的证书，而管理器的
#    AnyTLS 证书目录早于 mihomo 支持存在（公开 Issue #154 实测确认，
#    且该限制在 `mihomo -t` 阶段完全不暴露，只有真正启动监听器时才报错）。
# 3. 不写 ExecReload：本项目从不执行 systemctl reload，写一条未经验证的重载
#    命令等于给出一个没验过的承诺。
write_mihomo_unit() {
  cat > "$(system_path /etc/systemd/system/mihomo.service)" <<'EOF' || return 1
[Unit]
Description=mihomo service
After=network-online.target nss-lookup.target
Wants=network-online.target
[Service]
Type=simple
User=root
StateDirectory=mihomo
Environment=SAFE_PATHS=/etc/sing-box/cert
ExecStart=/usr/local/bin/mihomo -d /var/lib/mihomo -f /etc/mihomo/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity
[Install]
WantedBy=multi-user.target
EOF
}

write_kernel_unit() {
  case "$PROXY_KERNEL" in
    singbox) write_singbox_unit || return 1 ;;
    mihomo) write_mihomo_unit || return 1 ;;
    *) kernel_unknown || return 1 ;;
  esac
}

write_nfuse_unit() {
  local iface="$1"
  cat > "$(system_path /etc/systemd/system/nfuse.service)" <<EOF || return 1
[Unit]
Description=Nfuse per-port traffic accounting and quota service
After=network-online.target nftables.service
Wants=network-online.target
[Service]
Type=simple
User=root
RuntimeDirectory=nfuse
StateDirectory=nfuse
ExecStart=/usr/local/bin/nfuse server --iface $iface --db /var/lib/nfuse/nfuse.db --socket /run/nfuse.sock
Restart=on-failure
RestartSec=5s
NoNewPrivileges=yes
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=/var/lib/nfuse /run
[Install]
WantedBy=multi-user.target
EOF
}

write_expiry_units() {
  local kernel_unit
  kernel_unit="$(kernel_service_name)" || return 1
  cat > "$(system_path /etc/systemd/system/sb-user-expiry.service)" <<EOF || return 1
[Unit]
Description=Expire sing-box managed users
After=${kernel_unit}.service nfuse.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sb-user-manager --internal-expire
EOF
  cat > "$(system_path /etc/systemd/system/sb-user-expiry.timer)" <<'EOF' || return 1
[Unit]
Description=Check sing-box user expiry
[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
Persistent=true
[Install]
WantedBy=timers.target
EOF
}

write_systemd_units() {
  write_kernel_unit || return 1
  write_nfuse_unit "$1" || return 1
  write_expiry_units || return 1
}

install_prerequisites() {
  log "检查并安装系统依赖"
  apt-get update || return 1
  # gzip 与 tar 并列声明：mihomo 的发行资产是单个 gz 压缩的可执行文件，
  # 不经 tar。Debian 上 gzip 属于必备包，这里写出来是为了把依赖记在一处。
  DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl jq nftables iproute2 util-linux bsdextrautils tar gzip openssl python3 qrencode || return 1
}

environment_is_deployed() {
  local path
  [[ -f "$CONF_FILE" && -x /usr/local/bin/nfuse ]] || return 1
  # 只看当前内核的核心文件：一台 mihomo 机器上没有 sing-box 是正常状态，不是未部署。
  while IFS= read -r path; do
    [[ -e "$path" ]] || return 1
  done < <(kernel_core_paths)
}

system_path() {
  printf '%s%s' "${SB_SYSTEM_ROOT:-}" "$1"
}

classify_environment() {
  local managed=0 core=0 complete=true runtime_ok=true path kernel_paths
  kernel_paths="$(kernel_core_paths)" || return 1
  for path in /etc/sb-user-manager.conf /etc/sing-box/managed-users.json /usr/local/sbin/sb-user-manager /etc/systemd/system/sb-user-expiry.timer; do
    [[ -e "$(system_path "$path")" ]] && ((managed+=1))
  done
  for path in /usr/local/bin/nfuse /etc/systemd/system/nfuse.service /var/lib/nfuse/nfuse.db; do
    [[ -e "$(system_path "$path")" ]] && ((core+=1))
  done
  while IFS= read -r path; do
    [[ -e "$(system_path "$path")" ]] && ((core+=1))
  done <<<"$kernel_paths"
  for path in /etc/sb-user-manager.conf /etc/sing-box/managed-users.json /usr/local/sbin/sb-user-manager /usr/local/bin/nfuse /etc/systemd/system/nfuse.service /etc/systemd/system/sb-user-expiry.service /etc/systemd/system/sb-user-expiry.timer; do
    [[ -e "$(system_path "$path")" ]] || complete=false
  done
  while IFS= read -r path; do
    [[ -e "$(system_path "$path")" ]] || complete=false
  done <<<"$kernel_paths"

  if ((managed==0 && core==0)); then ENVIRONMENT_CLASS=fresh
  elif [[ "$complete" == true ]]; then
    if [[ -z "${SB_SYSTEM_ROOT:-}" ]]; then
      kernel_check_default_install >/dev/null 2>&1 || runtime_ok=false
      kernel_service_is_active || runtime_ok=false
      systemctl is-active --quiet nfuse || runtime_ok=false
      [[ -S /run/nfuse.sock ]] || runtime_ok=false
    fi
    [[ "$runtime_ok" == true ]] && ENVIRONMENT_CLASS=managed_complete || ENVIRONMENT_CLASS=managed_damaged
  elif ((managed>0)); then ENVIRONMENT_CLASS=managed_partial
  else ENVIRONMENT_CLASS=external
  fi
}

environment_class_label() {
  case "$1" in
    fresh) echo '全新环境';;
    managed_complete) echo '本项目完整部署';;
    managed_damaged) echo '本项目部署损坏';;
    managed_partial) echo '本项目部分部署';;
    external) echo '外部/第三方部署';;
    *) echo '未知环境';;
  esac
}

show_environment_diagnostics() {
  local path status service_state
  classify_environment
  printf '\n安装环境检查：%s\n\n' "$(environment_class_label "$ENVIRONMENT_CLASS")"
  printf '%-34s %s\n' '检查项' '结果'
  printf '%-34s %s\n' '----------------------------------' '--------'
  while IFS= read -r path; do
    [[ -e "$(system_path "$path")" ]] && status='存在' || status='缺失'
    printf '%-34s %s\n' "$path" "$status"
  done < <(
    kernel_core_paths
    cat <<'EOF'
/etc/sing-box/managed-users.json
/etc/sb-user-manager.conf
/usr/local/bin/nfuse
/usr/local/sbin/sb-user-manager
/etc/systemd/system/nfuse.service
/etc/systemd/system/sb-user-expiry.timer
EOF
  )
  if [[ -z "${SB_SYSTEM_ROOT:-}" ]]; then
    service_state="$(systemctl is-active "$(kernel_service_name)" 2>/dev/null || true)"
    printf '\n%-24s %s\n' "节点服务（$(kernel_display_name)）" "${service_state:-未安装}"
    service_state="$(systemctl is-active nfuse 2>/dev/null || true)"
    printf '%-24s %s\n' '流量统计（Nfuse）' "${service_state:-未安装}"
    printf '%-24s %s\n' '流量统计通信' "$([[ -S /run/nfuse.sock ]] && echo 正常 || echo 未就绪)"
  fi
}

# 查询 GitHub API。所有 API 请求都必须经过这里，静态门禁看守该约定。
# --retry-all-errors 是必需的：curl 的 --retry 只覆盖超时、连接被拒和部分 5xx，
# 不覆盖退出码 35 一类的 TLS 握手失败。链路中有代理客户端时这种瞬时失败并不罕见，
# 而安装与更新是长流程，一次抖动会让整个已开启的事务回滚重来。
# 第一个参数是 URL，其余参数原样传给 curl；URL 保持在 argv 末尾，
# 便于调用点追加额外请求头而不改变参数顺序。
github_api_get() {
  local url="$1"
  shift
  curl --proto '=https' --proto-redir '=https' --max-redirs 5 \
    --connect-timeout 10 --max-time 30 -fsSL --retry 3 --retry-all-errors \
    -H 'Accept: application/vnd.github+json' "$@" "$url"
}

# 下载 Release 资产到指定路径。与 API 查询同理需要覆盖 TLS 瞬时失败；
# 超时放宽到 300 秒是因为附件有几十兆。
github_download_to() {
  local target="$1" url="$2"
  curl --proto '=https' --proto-redir '=https' --max-redirs 5 \
    --connect-timeout 10 --max-time 300 -fL --retry 3 --retry-all-errors \
    -o "$target" "$url"
}

singbox_release_metadata() {
  local release_json="$1"
  jq -cer --arg arch "$SINGBOX_ARCH" '
    (.tag_name // "" | sub("^v"; "")) as $version |
    ("sing-box-" + $version + "-" + $arch + ".tar.gz") as $asset_name |
    ([.assets[]? | select(.name == $asset_name)] | first) as $asset |
    {
      version: $version,
      asset: $asset_name,
      url: ($asset.browser_download_url // ""),
      sha256: (($asset.digest // "") | sub("^sha256:"; ""))
    } |
    select(
      (.version | length) > 0 and
      (.url | startswith("https://")) and
      (.sha256 | test("^[0-9a-fA-F]{64}$"))
    )
  ' <<<"$release_json"
}

fetch_singbox_channel_releases() {
  local stable_json releases_json preview_json stable_metadata preview_metadata
  stable_json="$(github_api_get "https://api.github.com/repos/${SINGBOX_REPOSITORY}/releases/latest")" || {
    echo "无法查询 sing-box 最新正式版，请检查服务器网络。" >&2
    return 1
  }
  releases_json="$(github_api_get "https://api.github.com/repos/${SINGBOX_REPOSITORY}/releases?per_page=30")" || {
    echo "无法查询 sing-box 最新测试版，请检查服务器网络。" >&2
    return 1
  }
  preview_json="$(jq -cer '[.[] | select(.draft == false and .prerelease == true)] | max_by(.published_at)' <<<"$releases_json")" || {
    echo "sing-box 当前没有可用的测试版。" >&2
    return 1
  }
  stable_metadata="$(singbox_release_metadata "$stable_json")" || {
    echo "最新正式版缺少适用于 ${SINGBOX_ARCH} 的可信发行文件。" >&2
    return 1
  }
  preview_metadata="$(singbox_release_metadata "$preview_json")" || {
    echo "最新测试版缺少适用于 ${SINGBOX_ARCH} 的可信发行文件。" >&2
    return 1
  }
  LATEST_STABLE_SINGBOX_VERSION="$(jq -r '.version' <<<"$stable_metadata")"
  LATEST_STABLE_SINGBOX_ASSET="$(jq -r '.asset' <<<"$stable_metadata")"
  LATEST_STABLE_SINGBOX_URL="$(jq -r '.url' <<<"$stable_metadata")"
  LATEST_STABLE_SINGBOX_SHA256="$(jq -r '.sha256' <<<"$stable_metadata")"
  LATEST_PREVIEW_SINGBOX_VERSION="$(jq -r '.version' <<<"$preview_metadata")"
  LATEST_PREVIEW_SINGBOX_ASSET="$(jq -r '.asset' <<<"$preview_metadata")"
  LATEST_PREVIEW_SINGBOX_URL="$(jq -r '.url' <<<"$preview_metadata")"
  LATEST_PREVIEW_SINGBOX_SHA256="$(jq -r '.sha256' <<<"$preview_metadata")"
}

singbox_channel_label() {
  if [[ "$1" == *-* ]]; then printf '测试版'; else printf '正式版'; fi
}

singbox_channel_name() {
  if [[ "$1" == *-* ]]; then printf 'preview'; else printf 'stable'; fi
}

current_singbox_channel() {
  local current stored_channel stored_version
  current="$(installed_singbox_version)"
  if [[ -r "$SINGBOX_CHANNEL_STATE" ]] && jq -e '
      .format_version == 1 and (.channel == "stable" or .channel == "preview") and
      (.current_version | type == "string" and length > 0)
    ' "$SINGBOX_CHANNEL_STATE" >/dev/null 2>&1; then
    stored_channel="$(jq -r '.channel' "$SINGBOX_CHANNEL_STATE")"
    stored_version="$(jq -r '.current_version' "$SINGBOX_CHANNEL_STATE")"
    if [[ -n "$current" && "$stored_version" == "$current" ]]; then printf '%s' "$stored_channel"; return 0; fi
  fi
  singbox_channel_name "${current:-0.0.0}"
}

write_singbox_channel_state() {
  local channel="$1" version="$2" previous_channel="$3" previous_version="$4"
  local dir tmp stable_version preview_version
  dir="$(dirname "$SINGBOX_CHANNEL_STATE")"
  install -d -m 700 "$dir" || return 1
  tmp="$(mktemp "$dir/.singbox-channel.XXXXXX")" || return 1
  register_temp_path "$tmp" || return 1
  stable_version="$(kernel_binary_version "$SINGBOX_VERSION_STORE/stable/sing-box")"
  preview_version="$(kernel_binary_version "$SINGBOX_VERSION_STORE/preview/sing-box")"
  if ! jq -n --arg channel "$channel" --arg version "$version" \
      --arg stable "$stable_version" --arg preview "$preview_version" \
      --arg previous_channel "$previous_channel" --arg previous_version "$previous_version" \
      --arg updated_at "$(date -Iseconds)" '
        {format_version:1,channel:$channel,current_version:$version,updated_at:$updated_at,
         cached:{stable_version:$stable,preview_version:$preview},
         previous:{channel:$previous_channel,version:$previous_version}}
      ' > "$tmp" || ! chmod 600 "$tmp" || ! mv -- "$tmp" "$SINGBOX_CHANNEL_STATE"; then
    rm -f -- "$tmp"
    return 1
  fi
  sync_transaction_path "$SINGBOX_CHANNEL_STATE" || return 1
}

update_deployed_singbox_version() {
  local version="$1" versions="$DEPLOYED_VERSIONS_FILE" tmp
  [[ -f "$versions" ]] || return 0
  tmp="$(mktemp "$(dirname "$versions")/.singbox-channel.XXXXXX")" || return 1
  register_temp_path "$tmp" || return 1
  awk -v version="$version" '
    BEGIN {updated=0}
    /^SINGBOX_VERSION=/ {print "SINGBOX_VERSION=" version; updated=1; next}
    {print}
    END {if (!updated) print "SINGBOX_VERSION=" version}
  ' "$versions" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod --reference="$versions" "$tmp" 2>/dev/null || chmod 600 "$tmp" || return 1
  mv -- "$tmp" "$versions" || return 1
  sync_transaction_path "$versions" || return 1
}

show_singbox_channel_versions() {
  local current current_channel current_label='未知' cached_stable='未保存' cached_preview='未保存'
  environment_is_deployed || { echo "检测结果：尚未安装，请先选择「安装或修复环境」。"; return 0; }
  load_runtime_config
  need_cmd curl; need_cmd jq
  echo "正在查询 sing-box 官方版本…"
  fetch_singbox_channel_releases || return 0
  current="$(installed_singbox_version)"
  [[ -z "$current" ]] || current_label="$(singbox_channel_label "$current")"
  current_channel="$(current_singbox_channel)"
  cached_stable="$(kernel_binary_version "$SINGBOX_VERSION_STORE/stable/sing-box")"; cached_stable="${cached_stable:-未保存}"
  cached_preview="$(kernel_binary_version "$SINGBOX_VERSION_STORE/preview/sing-box")"; cached_preview="${cached_preview:-未保存}"
  printf '\n%-16s %-26s\n' '项目' '版本'
  printf '%-16s %-26s\n' '----------------' '--------------------------'
  printf '%-16s %-26s\n' '当前版本' "${current:-未知}（${current_label}）"
  printf '%-16s %-26s\n' '最新正式版' "$LATEST_STABLE_SINGBOX_VERSION"
  printf '%-16s %-26s\n' '最新测试版' "$LATEST_PREVIEW_SINGBOX_VERSION"
  printf '%-16s %-26s\n' '当前通道' "$([[ "$current_channel" == preview ]] && echo 测试版 || echo 正式版)"
  printf '%-16s %-26s\n' '已保存正式版' "$cached_stable"
  printf '%-16s %-26s\n' '已保存测试版' "$cached_preview"
  cat <<'EOF'

这里只显示官方版本信息，不会更换当前版本。
EOF
}

check_rule_set_with_binary() {
  local binary="$1" url="$2" format downloaded decoded
  format="$(split_rule_format "$url")" || { echo "规则集地址格式不受支持：$url" >&2; return 1; }
  validate_public_rule_set_url "$url" || { echo "规则集地址必须使用 HTTPS 且不能指向内网：$url" >&2; return 1; }
  downloaded="$(mktemp /tmp/sb-channel-rule.XXXXXX)" || return 1
  decoded="$(mktemp /tmp/sb-channel-rule-decoded.XXXXXX)" || { rm -f -- "$downloaded"; return 1; }
  register_temp_path "$downloaded"
  register_temp_path "$decoded"
  if ! curl --proto '=https' --proto-redir '=https' --fail --max-redirs 0 \
    --silent --show-error --connect-timeout 10 --max-time 30 --output "$downloaded" "$url"; then
    echo "无法下载规则集：$url" >&2
    rm -f -- "$downloaded" "$decoded"
    return 1
  fi
  if [[ "$format" == source ]]; then
    jq -e 'type == "object" and (.version | type == "number") and (.rules | type == "array")' "$downloaded" >/dev/null &&
      kernel_rule_set_compile "$binary" "$downloaded" "$decoded"
  else
    kernel_rule_set_decompile "$binary" "$downloaded" "$decoded" &&
      jq -e 'type == "object" and (.version | type == "number") and (.rules | type == "array")' "$decoded" >/dev/null
  fi
  local rc=$?
  rm -f -- "$downloaded" "$decoded"
  ((rc == 0)) || echo "目标版本无法识别规则集：$url" >&2
  return "$rc"
}

list_singbox_rule_set_urls() {
  {
    jq -r '.route.rule_set[]? | select(.type == "remote") | .url // empty' "$SINGBOX_CONFIG" 2>/dev/null || true
    jq -r '.splits[]? | .url // empty' "$STATE_FILE" 2>/dev/null || true
  } | awk 'NF && !seen[$0]++'
}

prepare_singbox_release_binary() {
  local version="$1" asset="$2" url="$3" sha256="$4" work="$5" slot="$6"
  local target_dir="$work/$slot" archive binary detected
  install -d -m 700 "$target_dir" || return 1
  archive="$target_dir/$asset"
  binary="$target_dir/sing-box"
  if ! github_download_to "$archive" "$url" ||
     ! printf '%s  %s\n' "$sha256" "$archive" | sha256sum -c - >/dev/null; then
    return 1
  fi
  if ! tar -xzf "$archive" -C "$target_dir" --no-same-owner --strip-components=1 "sing-box-${version}-${SINGBOX_ARCH}/sing-box" ||
     [[ ! -f "$binary" || -L "$binary" || ! -x "$binary" ]]; then
    return 1
  fi
  detected="$(kernel_binary_version "$binary")"
  [[ "$detected" == "$version" ]] || return 1
  PREPARED_SINGBOX_BINARY="$binary"
}

check_singbox_release_compatibility() {
  local channel="$1" version asset url sha256 work binary stable_binary normalized output rule_url rule_count=0
  SINGBOX_COMPATIBLE=false
  SINGBOX_COMPATIBLE_VERSION=""
  environment_is_deployed || { echo "检测结果：尚未安装，请先选择「安装或修复环境」。"; return 0; }
  load_runtime_config
  need_cmd curl; need_cmd jq; need_cmd tar; need_cmd sha256sum
  echo "正在查询 sing-box 官方版本…"
  fetch_singbox_channel_releases || return 0
  case "$channel" in
    stable)
      version="$LATEST_STABLE_SINGBOX_VERSION"; asset="$LATEST_STABLE_SINGBOX_ASSET"
      url="$LATEST_STABLE_SINGBOX_URL"; sha256="$LATEST_STABLE_SINGBOX_SHA256"
      ;;
    preview)
      version="$LATEST_PREVIEW_SINGBOX_VERSION"; asset="$LATEST_PREVIEW_SINGBOX_ASSET"
      url="$LATEST_PREVIEW_SINGBOX_URL"; sha256="$LATEST_PREVIEW_SINGBOX_SHA256"
      ;;
    *) echo "未知版本通道。" >&2; return 0;;
  esac
  work="$(mktemp -d /tmp/sb-channel-check.XXXXXX)" || return 1
  register_temp_path "$work"
  printf '正在下载 sing-box %s（%s）…\n' "$version" "$(singbox_channel_label "$version")"
  if ! prepare_singbox_release_binary "$version" "$asset" "$url" "$sha256" "$work" target; then
    echo "检查失败：下载文件、校验值、压缩包内容或版本标记不符合预期；当前版本没有改变。"
    rm -rf -- "$work"
    return 0
  fi
  binary="$PREPARED_SINGBOX_BINARY"
  if ! output="$(kernel_check_config_with "$binary" "$SINGBOX_CONFIG" 2>&1)"; then
    echo "检查结果：暂时不能切换到 sing-box ${version}。"
    echo "原因：现有连接配置不被该版本接受。"
    [[ -n "$output" ]] && printf '详细信息：%s\n' "$(tail -n 1 <<<"$output")"
    echo "当前版本和全部配置均未改变。"
    rm -rf -- "$work"
    return 0
  fi
  normalized="$work/target-formatted-config.json"
  if ! output="$($binary format -c "$SINGBOX_CONFIG" 2>&1 >"$normalized")" ||
     ! output="$(kernel_check_config_with "$binary" "$normalized" 2>&1)"; then
    echo "检查结果：暂时不能切换到 sing-box ${version}。"
    echo "原因：目标版本无法安全解析并重新生成现有配置。"
    [[ -n "$output" ]] && printf '详细信息：%s\n' "$(tail -n 1 <<<"$output")"
    echo "当前版本和全部配置均未改变。"
    rm -rf -- "$work"
    return 0
  fi
  while IFS= read -r rule_url; do
    [[ -n "$rule_url" ]] || continue
    ((rule_count+=1))
    if ! check_rule_set_with_binary "$binary" "$rule_url"; then
      echo "检查结果：暂时不能切换到 sing-box ${version}。"
      echo "原因：至少有一个现有分流规则集不兼容或无法下载。"
      echo "当前版本和全部配置均未改变。"
      rm -rf -- "$work"
      return 0
    fi
  done < <(list_singbox_rule_set_urls)
  if [[ "$channel" == preview ]]; then
    echo "正在检查测试版处理后的配置能否安全回到最新正式版…"
    if ! prepare_singbox_release_binary \
      "$LATEST_STABLE_SINGBOX_VERSION" "$LATEST_STABLE_SINGBOX_ASSET" \
      "$LATEST_STABLE_SINGBOX_URL" "$LATEST_STABLE_SINGBOX_SHA256" "$work" stable; then
      echo "检查失败：无法验证回到正式版所需的官方程序；当前版本没有改变。"
      rm -rf -- "$work"
      return 0
    fi
    stable_binary="$PREPARED_SINGBOX_BINARY"
    if ! output="$(kernel_check_config_with "$stable_binary" "$normalized" 2>&1)"; then
      echo "检查结果：测试版可以读取当前配置，但不满足安全往返要求。"
      echo "原因：测试版重新整理配置后，最新正式版无法读取。"
      [[ -n "$output" ]] && printf '详细信息：%s\n' "$(tail -n 1 <<<"$output")"
      echo "为避免以后无法切回正式版，本阶段会把它视为不兼容；当前版本没有改变。"
      rm -rf -- "$work"
      return 0
    fi
  fi
  printf '\n检查通过：sing-box %s 可以读取当前连接配置' "$version"
  if ((rule_count > 0)); then printf '和 %d 个分流规则集' "$rule_count"; fi
  printf '。\n'
  if [[ "$channel" == preview ]]; then
    printf '测试版处理后的配置也通过了最新正式版检查。\n'
  fi
  SINGBOX_COMPATIBLE=true
  SINGBOX_COMPATIBLE_VERSION="$version"
  printf '本次只做检查，没有更换当前版本。\n'
  rm -rf -- "$work"
}

perform_singbox_channel_switch() {
  local channel="$1" version="$2" asset="$3" url="$4" sha256="$5"
  local work binary current_channel current_version previous_dir current_dir target_dir
  ensure_safe_ssh_for_kernel_restart || return 0
  work="$(mktemp -d /tmp/sb-channel-switch.XXXXXX)" || return 1
  register_temp_path "$work"
  if ! prepare_singbox_release_binary "$version" "$asset" "$url" "$sha256" "$work" target; then
    echo "下载或校验目标版本失败，当前版本没有改变。"
    rm -rf -- "$work"
    return 1
  fi
  binary="$PREPARED_SINGBOX_BINARY"
  prepare_core
  current_channel="$(current_singbox_channel)"
  current_version="$(installed_singbox_version)"
  if ! kernel_check_config_with "$binary" "$SINGBOX_CONFIG" >/dev/null 2>&1; then
    echo "写入前复检失败，现有配置已经发生变化；本次切换已取消。"
    release_operation_lock
    rm -rf -- "$work"
    return 1
  fi
  create_environment_backup || { release_operation_lock; rm -rf -- "$work"; return 1; }
  rollback_channel_switch() {
    local rc="${1:-$?}"
    trap - ERR
    clear_signal_rollback
    restore_failed_environment_change "sing-box 版本切换" "$ENV_BACKUP" "$work" || true
    release_operation_lock
    return "$rc"
  }
  trap rollback_channel_switch ERR
  set_signal_rollback rollback_channel_switch
  run_step_or_rollback rollback_channel_switch begin_environment_transaction \
    "sing-box-${current_channel}-to-${channel}" "$ENV_BACKUP" "$SINGBOX_VERSION_STORE" || return 1
  previous_dir="$SINGBOX_VERSION_STORE/previous"
  current_dir="$SINGBOX_VERSION_STORE/$current_channel"
  target_dir="$SINGBOX_VERSION_STORE/$channel"
  run_step_or_rollback rollback_channel_switch install -d -m 700 "$previous_dir" "$current_dir" "$target_dir" || return 1
  run_step_or_rollback rollback_channel_switch atomic_install_file "$SINGBOX_BIN" "$previous_dir/sing-box" 755 || return 1
  run_step_or_rollback rollback_channel_switch atomic_install_file "$SINGBOX_BIN" "$current_dir/sing-box" 755 || return 1
  run_step_or_rollback rollback_channel_switch atomic_install_file "$binary" "$target_dir/sing-box" 755 || return 1
  run_step_or_rollback rollback_channel_switch atomic_install_file "$binary" "$SINGBOX_BIN" 755 || return 1
  run_step_or_rollback rollback_channel_switch kernel_check_config "$SINGBOX_CONFIG" || return 1
  run_step_or_rollback rollback_channel_switch systemctl restart sing-box || return 1
  run_step_or_rollback rollback_channel_switch systemctl is-active --quiet sing-box || return 1
  run_step_or_rollback rollback_channel_switch systemctl is-active --quiet nfuse || return 1
  run_step_or_rollback rollback_channel_switch systemctl is-active --quiet sb-user-expiry.timer || return 1
  run_step_or_rollback rollback_channel_switch write_singbox_channel_state \
    "$channel" "$version" "$current_channel" "$current_version" || return 1
  run_step_or_rollback rollback_channel_switch update_deployed_singbox_version "$version" || return 1
  run_step_or_rollback rollback_channel_switch complete_environment_change "$work" || return 1
  release_operation_lock
  printf '\nsing-box 已从 %s %s 切换到 %s %s。\n' \
    "$(singbox_channel_label "$current_version")" "$current_version" "$(singbox_channel_label "$version")" "$version"
  echo "用户、分流、配额和流量记录均未修改。"
}

switch_singbox_channel() {
  local channel="$1" mode="${2:-switch}" current current_channel answer token
  environment_is_deployed || { echo "检测结果：尚未安装，请先选择「安装或修复环境」。"; return 0; }
  current="$(installed_singbox_version)"
  current_channel="$(current_singbox_channel)"
  if [[ "$channel" == preview && "$mode" == switch ]]; then
    cat <<'EOF'
测试版可能包含尚未稳定的功能和破坏式配置变更，切换时会短暂重启连接服务。
脚本会先检查能否安全回到正式版；不满足往返条件时不会切换。
EOF
    read -r -p '是否开始兼容检查？[y/N]：' answer
    [[ "$answer" =~ ^[Yy]$ ]] || { echo "已取消。"; return 0; }
  fi
  check_singbox_release_compatibility "$channel"
  [[ "${SINGBOX_COMPATIBLE:-false}" == true ]] || return 0
  if [[ "$current_channel" == "$channel" && "$current" == "$SINGBOX_COMPATIBLE_VERSION" ]]; then
    printf '当前已经是最新%s %s。\n' "$(singbox_channel_label "$current")" "$current"
    return 0
  fi
  if [[ "$channel" == preview ]]; then token='TEST'; else token='SWITCH'; fi
  printf '\n准备从 %s %s 切换到 %s %s。\n' \
    "$(singbox_channel_label "$current")" "$current" \
    "$(singbox_channel_label "$SINGBOX_COMPATIBLE_VERSION")" "$SINGBOX_COMPATIBLE_VERSION"
  read -r -p "确认继续请输入 ${token}：" answer
  [[ "$answer" == "$token" ]] || { echo "已取消切换。"; return 0; }
  if [[ "$channel" == stable ]]; then
    perform_singbox_channel_switch stable "$LATEST_STABLE_SINGBOX_VERSION" "$LATEST_STABLE_SINGBOX_ASSET" "$LATEST_STABLE_SINGBOX_URL" "$LATEST_STABLE_SINGBOX_SHA256"
  else
    perform_singbox_channel_switch preview "$LATEST_PREVIEW_SINGBOX_VERSION" "$LATEST_PREVIEW_SINGBOX_ASSET" "$LATEST_PREVIEW_SINGBOX_URL" "$LATEST_PREVIEW_SINGBOX_SHA256"
  fi
}

update_current_singbox_channel() {
  local channel
  channel="$(current_singbox_channel)"
  switch_singbox_channel "$channel" update
}

singbox_channel_menu() {
  local choice
  # 正式版／测试版通道是 sing-box 特有的发布形态。其它内核没有对应物，
  # 这里明确说明并返回，而不是让下面的流程按 sing-box 的资产名去查一个不存在的东西。
  if [[ "$PROXY_KERNEL" != singbox ]]; then
    printf '当前部署使用的代理内核是 %s，没有正式版／测试版通道之分。\n' "$(kernel_display_name)"
    printf '内核版本随「检查更新」一并更新。\n'
    pause_menu
    return 0
  fi
  while true; do
    prepare_menu_screen
    cat <<'EOF'
sing-box 版本管理

1. 查看当前通道和可用版本
2. 切换到最新测试版
3. 切换回最新正式版
4. 更新当前通道
0. 返回上一级
EOF
    read_menu_choice '请选择：' '0,1,2,3,4' '' '请输入 0-4 之间的数字' || return 0
    choice="$PROMPT_VALUE"
    case "$choice" in
      1) show_singbox_channel_versions; pause_menu;;
      2) switch_singbox_channel preview; pause_menu;;
      3) switch_singbox_channel stable; pause_menu;;
      4) update_current_singbox_channel; pause_menu;;
      0) return 0;;
    esac
  done
}

fetch_latest_manager_release() {
  local manager_json
  manager_json="$(github_api_get \
    "https://api.github.com/repos/${MANAGER_REPOSITORY}/releases/latest" \
    -H 'X-GitHub-Api-Version: 2022-11-28')" ||
    die "无法查询管理脚本最新版本"
  LATEST_MANAGER_VERSION="$(jq -r '.tag_name // empty | sub("^v"; "")' <<<"$manager_json")"
  [[ -n "$LATEST_MANAGER_VERSION" ]] || die "管理脚本 Release 版本信息无效"
  LATEST_MANAGER_URL="$(jq -r --arg name "$MANAGER_ASSET" '.assets[] | select(.name == $name) | .browser_download_url' <<<"$manager_json")"
  LATEST_MANAGER_SHA256="$(jq -r --arg name "$MANAGER_ASSET" '.assets[] | select(.name == $name) | (.digest // "") | sub("^sha256:"; "")' <<<"$manager_json")"
}

# 查询当前内核的最新正式版，填入 LATEST_KERNEL_VERSION / _ASSET / _URL / _SHA256。
# 资产名的构成规则是内核特有的，因此两个内核各写一份而不是拼一个通用模板：
# sing-box 是 tar.gz 内含目录，mihomo 是单文件 gz，连解包方式都不同。
fetch_latest_kernel_release() {
  local release_json asset
  case "$PROXY_KERNEL" in
    singbox)
      release_json="$(github_api_get "https://api.github.com/repos/${SINGBOX_REPOSITORY}/releases/latest")" ||
        die "无法查询 sing-box 最新版本"
      LATEST_KERNEL_VERSION="$(jq -r '.tag_name // empty | sub("^v"; "")' <<<"$release_json")"
      [[ -n "$LATEST_KERNEL_VERSION" ]] || die "GitHub Release 返回的版本信息无效"
      asset="sing-box-${LATEST_KERNEL_VERSION}-${SINGBOX_ARCH}.tar.gz"
      ;;
    mihomo)
      release_json="$(github_api_get "https://api.github.com/repos/${MIHOMO_REPOSITORY}/releases/latest")" ||
        die "无法查询 mihomo 最新版本"
      LATEST_KERNEL_VERSION="$(jq -r '.tag_name // empty | sub("^v"; "")' <<<"$release_json")"
      [[ -n "$LATEST_KERNEL_VERSION" ]] || die "GitHub Release 返回的版本信息无效"
      # 资产名里的版本号带 v 前缀，与标签一致；这里刻意重新拼上而不是复用标签原文，
      # 使「去掉 v 的版本号」在整个流程里只有一处来源。
      asset="mihomo-${MIHOMO_ARCH}-v${LATEST_KERNEL_VERSION}.gz"
      ;;
    *) kernel_unknown || return 1 ;;
  esac
  LATEST_KERNEL_ASSET="$asset"
  LATEST_KERNEL_URL="$(jq -r --arg name "$asset" '.assets[] | select(.name == $name) | .browser_download_url' <<<"$release_json")"
  LATEST_KERNEL_SHA256="$(jq -r --arg name "$asset" '.assets[] | select(.name == $name) | (.digest // "") | sub("^sha256:"; "")' <<<"$release_json")"
}

fetch_latest_releases() {
  local include_manager="${1:-true}" nfuse_json nfuse_asset kernel_label
  kernel_label="$(kernel_display_name)" || return 1
  fetch_latest_kernel_release || return 1
  nfuse_json="$(github_api_get https://api.github.com/repos/sketchain/Nfuse/releases/latest)" || die "无法查询 Nfuse 最新版本"
  LATEST_NFUSE_VERSION="$(jq -r '.tag_name // empty | sub("^v"; "")' <<<"$nfuse_json")"
  [[ -n "$LATEST_NFUSE_VERSION" ]] || die "GitHub Release 返回的版本信息无效"
  if [[ "$include_manager" == true ]]; then
    fetch_latest_manager_release
  else
    LATEST_MANAGER_VERSION="$SCRIPT_VERSION"
  fi
  nfuse_asset="nfuse-amd64.tar.gz"
  LATEST_NFUSE_URL="$(jq -r --arg name "$nfuse_asset" '.assets[] | select(.name == $name) | .browser_download_url' <<<"$nfuse_json")"
  LATEST_NFUSE_SHA256="$(jq -r --arg name "$nfuse_asset" '.assets[] | select(.name == $name) | (.digest // "") | sub("^sha256:"; "")' <<<"$nfuse_json")"
  if [[ "$include_manager" != true ]]; then
    LATEST_MANAGER_URL=""; LATEST_MANAGER_SHA256=""
  fi
  [[ "$LATEST_KERNEL_URL" == https://* && "$LATEST_NFUSE_URL" == https://* ]] || die "未找到适用于 linux-amd64 的发行资产"
  [[ "$LATEST_KERNEL_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || die "${kernel_label} 发行资产缺少可信 SHA-256 digest，停止更新"
  [[ "$LATEST_NFUSE_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || die "Nfuse 发行资产缺少可信 SHA-256 digest，停止更新"
  if [[ -n "$LATEST_MANAGER_URL" ]]; then
    [[ "$LATEST_MANAGER_URL" == https://* ]] || die "管理脚本发行资产地址无效"
    [[ "$LATEST_MANAGER_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || die "管理脚本发行资产缺少可信 SHA-256 digest，停止更新"
  fi
}

version_gt() {
  [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ]]
}

# >>> manager_channel_handoff
manager_handoff_installed_path() {
  if [[ -n "${MANAGER_INSTALLED_PATH:-}" ]]; then
    printf '%s\n' "$MANAGER_INSTALLED_PATH"
  else
    system_path /usr/local/sbin/sb-user-manager
  fi
}

manager_handoff_backup_script_path() {
  printf '%s/previous.sh\n' "$MANAGER_HANDOFF_DIRECTORY"
}

manager_handoff_backup_versions_path() {
  printf '%s/previous.versions\n' "$MANAGER_HANDOFF_DIRECTORY"
}

manager_handoff_read_quoted_assignment() {
  local file="$1" key="$2" count value
  count="$(grep -Ec "^${key}=\"[^\"]+\"$" "$file" 2>/dev/null || true)"
  [[ "$count" == 1 ]] || return 1
  value="$(sed -n "s/^${key}=\"\([^\"]*\)\"$/\1/p" "$file")" || return 1
  [[ -n "$value" ]] || return 1
  printf '%s\n' "$value"
}

manager_handoff_read_integer_assignment() {
  local file="$1" key="$2" count value
  count="$(grep -Ec "^${key}=[0-9][0-9]*$" "$file" 2>/dev/null || true)"
  [[ "$count" == 1 ]] || return 1
  value="$(sed -n "s/^${key}=\([0-9][0-9]*\)$/\1/p" "$file")" || return 1
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$value"
}

read_manager_handoff_metadata() {
  local file="$1" require_handoff="${2:-false}" program minimum_schema=0
  [[ -f "$file" && ! -L "$file" && -r "$file" ]] || return 1
  [[ "$(head -n 1 "$file" 2>/dev/null || true)" == '#!/usr/bin/env bash' ]] || return 1
  bash -n "$file" >/dev/null 2>&1 || return 1
  program="$(manager_handoff_read_quoted_assignment "$file" PROGRAM)" || return 1
  MANAGER_HANDOFF_METADATA_VERSION="$(manager_handoff_read_quoted_assignment "$file" SCRIPT_VERSION)" || return 1
  MANAGER_HANDOFF_METADATA_EDITION="$(manager_handoff_read_quoted_assignment "$file" SCRIPT_EDITION_LABEL)" || return 1
  MANAGER_HANDOFF_METADATA_SCHEMA="$(manager_handoff_read_integer_assignment "$file" STATE_SCHEMA_VERSION)" || return 1
  [[ "$program" == sb-user-manager ]] || return 1
  [[ "$MANAGER_HANDOFF_METADATA_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  case "$MANAGER_HANDOFF_METADATA_EDITION" in
    公开版|私有版) ;;
    *) return 1 ;;
  esac
  grep -Fq 'main() {' "$file" || return 1
  grep -Fq 'install_manager_binary() {' "$file" || return 1
  grep -Fq 'if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then' "$file" || return 1
  if [[ "$require_handoff" == true ]]; then
    minimum_schema="$(manager_handoff_read_integer_assignment "$file" MIN_SUPPORTED_STATE_SCHEMA_VERSION)" || return 1
    grep -Fq 'take_over_installed_manager() {' "$file" || return 1
  elif minimum_schema="$(manager_handoff_read_integer_assignment "$file" MIN_SUPPORTED_STATE_SCHEMA_VERSION 2>/dev/null)"; then
    :
  else
    minimum_schema=0
  fi
  ((minimum_schema <= MANAGER_HANDOFF_METADATA_SCHEMA)) || return 1
  MANAGER_HANDOFF_METADATA_MIN_SCHEMA="$minimum_schema"
}

manager_handoff_file_is_safe() {
  local file="$1" installed="${2:-false}" owner mode expected_owner
  [[ -f "$file" && ! -L "$file" && -r "$file" ]] || return 1
  owner="$(manager_file_uid "$file")" || return 1
  mode="$(manager_file_mode "$file")" || return 1
  expected_owner="$(runtime_config_expected_uid)"
  [[ "$owner" == "$expected_owner" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  if [[ "$installed" == true ]]; then
    (( (8#$mode & 077) == 0 ))
  else
    (( (8#$mode & 022) == 0 ))
  fi
}

manager_handoff_sha256() {
  sha256sum "$1" 2>/dev/null | awk 'NR==1 {print $1}'
}

manager_handoff_versions_file_is_safe() {
  local file="$1" installed_version="$2" owner mode expected_owner count recorded
  [[ -f "$file" && ! -L "$file" && -r "$file" ]] || return 1
  owner="$(manager_file_uid "$file")" || return 1
  mode="$(manager_file_mode "$file")" || return 1
  expected_owner="$(runtime_config_expected_uid)"
  [[ "$owner" == "$expected_owner" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 077) == 0 )) || return 1
  count="$(grep -Ec '^SCRIPT_VERSION=[0-9]+\.[0-9]+\.[0-9]+$' "$file" 2>/dev/null || true)"
  [[ "$count" == 1 ]] || return 1
  recorded="$(sed -n 's/^SCRIPT_VERSION=//p' "$file")" || return 1
  [[ "$recorded" == "$installed_version" ]]
}

update_deployed_manager_version() {
  local version="$1" versions="$DEPLOYED_VERSIONS_FILE" tmp expected_owner
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  [[ -f "$versions" && ! -L "$versions" ]] || return 1
  tmp="$(mktemp "$(dirname "$versions")/.manager-handoff.XXXXXX")" || return 1
  register_temp_path "$tmp" || { rm -f -- "$tmp"; return 1; }
  if ! awk -v version="$version" '
      BEGIN {updated=0}
      /^SCRIPT_VERSION=/ {if (updated) exit 2; print "SCRIPT_VERSION=" version; updated=1; next}
      {print}
      END {if (!updated) exit 3}
    ' "$versions" > "$tmp" ||
     ! chmod 600 "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! chown --reference="$versions" "$tmp" 2>/dev/null; then
    expected_owner="$(runtime_config_expected_uid)"
    if [[ "$expected_owner" == 0 ]]; then
      rm -f -- "$tmp"
      return 1
    fi
  fi
  if ! sync_transaction_path "$tmp" || ! mv -- "$tmp" "$versions" ||
     ! sync_transaction_path "$(dirname "$versions")"; then
    rm -f -- "$tmp"
    return 1
  fi
}

acquire_manager_handoff_lock() {
  local lock_directory
  acquire_operation_lock || return 1
  # 锁目录已存在时只接受真实目录；符号链接会被跟随并改写目标目录权限。
  lock_directory="$(dirname "$ENVIRONMENT_LOCK_FILE")" || { release_operation_lock; return 1; }
  if [[ -e "$lock_directory" || -L "$lock_directory" ]]; then
    [[ -d "$lock_directory" && ! -L "$lock_directory" ]] || { release_operation_lock; return 1; }
  elif ! install -d -m 755 -- "$lock_directory"; then
    release_operation_lock
    return 1
  fi
  exec 8>"$ENVIRONMENT_LOCK_FILE" || { release_operation_lock; return 1; }
  flock -n 8 || { release_environment_lock; release_operation_lock; return 1; }
  [[ ! -e "$ENVIRONMENT_TRANSACTION_JOURNAL" && ! -L "$ENVIRONMENT_TRANSACTION_JOURNAL" ]] || {
    release_environment_lock
    release_operation_lock
    return 1
  }
}

release_manager_handoff_locks() {
  release_environment_lock
  release_operation_lock
}

prepare_manager_handoff_directory() {
  local owner mode expected_owner
  if [[ -e "$MANAGER_HANDOFF_DIRECTORY" || -L "$MANAGER_HANDOFF_DIRECTORY" ]]; then
    [[ -d "$MANAGER_HANDOFF_DIRECTORY" && ! -L "$MANAGER_HANDOFF_DIRECTORY" ]] || return 1
    owner="$(manager_file_uid "$MANAGER_HANDOFF_DIRECTORY")" || return 1
    mode="$(manager_file_mode "$MANAGER_HANDOFF_DIRECTORY")" || return 1
    expected_owner="$(runtime_config_expected_uid)"
    [[ "$owner" == "$expected_owner" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 077) == 0 )) || return 1
    return 0
  fi
  install -d -m 700 "$MANAGER_HANDOFF_DIRECTORY" || return 1
}

write_manager_handoff_journal() {
  local old_version="$1" old_edition="$2" old_schema="$3" old_sha256="$4"
  local new_version="$5" new_edition="$6" new_schema="$7" tmp
  [[ ! -L "$MANAGER_HANDOFF_JOURNAL" ]] || return 1
  if [[ -e "$MANAGER_HANDOFF_JOURNAL" ]]; then
    [[ -f "$MANAGER_HANDOFF_JOURNAL" ]] || return 1
  fi
  tmp="$(mktemp "$MANAGER_HANDOFF_DIRECTORY/.manager-handoff.XXXXXX")" || return 1
  register_temp_path "$tmp" || { rm -f -- "$tmp"; return 1; }
  if ! jq -n \
      --argjson format 1 --arg status active \
      --arg old_version "$old_version" --arg old_edition "$old_edition" \
      --argjson old_schema "$old_schema" --arg old_sha256 "$old_sha256" \
      --arg new_version "$new_version" --arg new_edition "$new_edition" \
      --argjson new_schema "$new_schema" --arg started_at "$(date -Iseconds)" \
      '{format_version:$format,status:$status,old_version:$old_version,
        old_edition:$old_edition,old_schema:$old_schema,old_sha256:$old_sha256,
        new_version:$new_version,new_edition:$new_edition,new_schema:$new_schema,
        versions_existed:true,started_at:$started_at}' > "$tmp" ||
     ! chmod 600 "$tmp" || ! sync_transaction_path "$tmp" ||
     ! mv -- "$tmp" "$MANAGER_HANDOFF_JOURNAL" ||
     ! sync_transaction_path "$MANAGER_HANDOFF_DIRECTORY"; then
    rm -f -- "$tmp"
    return 1
  fi
}

validate_manager_handoff_journal() {
  [[ -f "$MANAGER_HANDOFF_JOURNAL" && ! -L "$MANAGER_HANDOFF_JOURNAL" ]] || return 1
  jq -e '
    .format_version == 1 and .status == "active" and .versions_existed == true and
    (.old_version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
    (.new_version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
    (.old_edition == "公开版" or .old_edition == "私有版") and
    (.new_edition == "公开版" or .new_edition == "私有版") and
    (.old_schema | type == "number" and . >= 0 and . == floor) and
    (.new_schema | type == "number" and . >= 0 and . == floor) and
    (.old_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.started_at | type == "string" and length > 0)
  ' "$MANAGER_HANDOFF_JOURNAL" >/dev/null
}

clear_manager_handoff_journal() {
  rm -f -- "$MANAGER_HANDOFF_JOURNAL" || return 1
  sync_transaction_path "$MANAGER_HANDOFF_DIRECTORY" || return 1
}

restore_manager_handoff_backups_locked() {
  local old_sha256="$1" old_version="$2" installed backup_script backup_versions
  installed="$(manager_handoff_installed_path)" || return 1
  backup_script="$(manager_handoff_backup_script_path)"
  backup_versions="$(manager_handoff_backup_versions_path)"
  [[ "$old_sha256" =~ ^[0-9a-f]{64}$ && "$old_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  manager_handoff_file_is_safe "$backup_script" true || return 1
  [[ "$(manager_handoff_sha256 "$backup_script")" == "$old_sha256" ]] || return 1
  manager_handoff_versions_file_is_safe "$backup_versions" "$old_version" || return 1
  atomic_install_file "$backup_script" "$installed" 700 || return 1
  atomic_install_file "$backup_versions" "$DEPLOYED_VERSIONS_FILE" 600 || return 1
  [[ "$(manager_handoff_sha256 "$installed")" == "$old_sha256" ]] || return 1
  manager_handoff_versions_file_is_safe "$DEPLOYED_VERSIONS_FILE" "$old_version" || return 1
}

restore_manager_handoff_locked() {
  local old_sha256 old_version
  validate_manager_handoff_journal || return 1
  old_sha256="$(jq -r '.old_sha256' "$MANAGER_HANDOFF_JOURNAL")" || return 1
  old_version="$(jq -r '.old_version' "$MANAGER_HANDOFF_JOURNAL")" || return 1
  restore_manager_handoff_backups_locked "$old_sha256" "$old_version"
}

MANAGER_HANDOFF_ROLLBACK_ACTIVE=false
MANAGER_HANDOFF_RECOVERED=false
MANAGER_HANDOFF_ROLLBACK_OLD_SHA256=""
MANAGER_HANDOFF_ROLLBACK_OLD_VERSION=""

rollback_manager_handoff() {
  local rc="${1:-1}"
  trap - ERR
  clear_signal_rollback
  if [[ "$MANAGER_HANDOFF_ROLLBACK_ACTIVE" == true ]]; then
    if restore_manager_handoff_backups_locked \
         "$MANAGER_HANDOFF_ROLLBACK_OLD_SHA256" "$MANAGER_HANDOFF_ROLLBACK_OLD_VERSION"; then
      if [[ ! -e "$MANAGER_HANDOFF_JOURNAL" && ! -L "$MANAGER_HANDOFF_JOURNAL" ]] ||
         clear_manager_handoff_journal; then
        log '管理脚本接管失败，已原子恢复原脚本和版本记录'
      else
        log "严重错误：原脚本已恢复，但无法清除接管日志：$MANAGER_HANDOFF_JOURNAL"
      fi
    else
      log "严重错误：管理脚本接管回滚未能完成；请保留恢复目录：$MANAGER_HANDOFF_DIRECTORY"
    fi
  fi
  MANAGER_HANDOFF_ROLLBACK_ACTIVE=false
  MANAGER_HANDOFF_ROLLBACK_OLD_SHA256=""
  MANAGER_HANDOFF_ROLLBACK_OLD_VERSION=""
  release_manager_handoff_locks
  return "$rc"
}

recover_manager_handoff() {
  MANAGER_HANDOFF_RECOVERED=false
  [[ -e "$MANAGER_HANDOFF_JOURNAL" || -L "$MANAGER_HANDOFF_JOURNAL" ]] || return 0
  acquire_manager_handoff_lock || {
    echo '错误：发现未完成的管理脚本接管，但恢复锁不可用。请停止其他管理操作后重试。' >&2
    return 1
  }
  if restore_manager_handoff_locked && clear_manager_handoff_journal; then
    release_manager_handoff_locks
    MANAGER_HANDOFF_RECOVERED=true
    log '已恢复上次未完成接管前的管理脚本和版本记录'
    return 0
  fi
  release_manager_handoff_locks
  echo "错误：未完成的管理脚本接管无法自动恢复。请保留恢复目录并停止继续操作：$MANAGER_HANDOFF_DIRECTORY" >&2
  return 1
}

verify_manager_handoff_installation() {
  local installed="$1" candidate="$2" target_version="$3" target_edition="$4" target_schema="$5"
  cmp -s -- "$candidate" "$installed" || return 1
  read_manager_handoff_metadata "$installed" true || return 1
  [[ "$MANAGER_HANDOFF_METADATA_VERSION" == "$target_version" &&
     "$MANAGER_HANDOFF_METADATA_EDITION" == "$target_edition" &&
     "$MANAGER_HANDOFF_METADATA_SCHEMA" == "$target_schema" ]] || return 1
  manager_handoff_versions_file_is_safe "$DEPLOYED_VERSIONS_FILE" "$target_version"
}

sync_manager_handoff_root_copy() {
  local installed="$1" old_sha256="$2" root_copy="${MANAGER_ROOT_LAUNCH_COPY:-/root/sb-user-manager.sh}"
  root_copy="$(system_path "$root_copy")" || return 0
  [[ "$root_copy" != "$installed" && "$root_copy" != "$SELF_PATH" ]] || return 0
  [[ -f "$root_copy" && ! -L "$root_copy" ]] || return 0
  [[ "$(manager_handoff_sha256 "$root_copy")" == "$old_sha256" ]] || return 0
  if atomic_install_file "$installed" "$root_copy" 700; then
    log "已同步 root 启动副本：$root_copy"
  else
    log "警告：未能同步 root 启动副本；请直接运行 $installed"
  fi
}

take_over_installed_manager() {
  local installed candidate candidate_source versions backup_script backup_versions
  local target_version target_edition target_schema target_min_schema
  local current_version current_edition current_schema current_sha256
  [[ $# -eq 0 ]] || { echo '错误：管理脚本接管命令不接受额外参数。' >&2; return 64; }
  candidate="$SELF_PATH"
  candidate_source="$SELF_SOURCE_PATH"
  installed="$(manager_handoff_installed_path)" || return 1
  versions="$DEPLOYED_VERSIONS_FILE"
  [[ ! -L "$candidate_source" ]] || { echo '错误：目标管理脚本不能通过符号链接执行。' >&2; return 1; }
  manager_handoff_file_is_safe "$candidate" false || {
    echo '错误：目标管理脚本必须是当前用户拥有、且不可被组或其他用户修改的普通文件。' >&2
    return 1
  }
  read_manager_handoff_metadata "$candidate" true || {
    echo '错误：目标管理脚本的语法、版本信息或项目结构不完整。' >&2
    return 1
  }
  target_version="$MANAGER_HANDOFF_METADATA_VERSION"
  target_edition="$MANAGER_HANDOFF_METADATA_EDITION"
  target_schema="$MANAGER_HANDOFF_METADATA_SCHEMA"
  target_min_schema="$MANAGER_HANDOFF_METADATA_MIN_SCHEMA"
  [[ "$target_version" == "$SCRIPT_VERSION" && "$target_edition" == "$SCRIPT_EDITION_LABEL" &&
     "$target_schema" == "$STATE_SCHEMA_VERSION" &&
     "$target_min_schema" == "$MIN_SUPPORTED_STATE_SCHEMA_VERSION" ]] || {
    echo '错误：正在运行的目标脚本与其静态版本标记不一致，已拒绝接管。' >&2
    return 1
  }
  [[ "$candidate" != "$installed" ]] || {
    echo '当前脚本已经位于正式安装路径，无需再次接管。'
    return 0
  }
  manager_handoff_file_is_safe "$installed" true || {
    echo "错误：正式安装入口不是安全的 root 专用普通文件：$installed" >&2
    return 1
  }
  read_manager_handoff_metadata "$installed" false || {
    echo '错误：当前已安装管理脚本的语法、版本信息或项目结构无效。' >&2
    return 1
  }
  current_version="$MANAGER_HANDOFF_METADATA_VERSION"
  current_edition="$MANAGER_HANDOFF_METADATA_EDITION"
  current_schema="$MANAGER_HANDOFF_METADATA_SCHEMA"
  if version_gt "$current_version" "$target_version"; then
    printf '错误：禁止管理脚本降级（当前 %s，目标 %s）。\n' "$current_version" "$target_version" >&2
    return 1
  fi
  if [[ "$current_version" == "$target_version" && "$current_edition" == "$target_edition" ]]; then
    printf '当前已经是 %s %s，无需重复接管。\n' "$target_version" "$target_edition"
    return 0
  fi
  if ((current_schema > target_schema || current_schema < target_min_schema)); then
    printf '错误：目标脚本不支持当前数据版本范围（当前支持 %s，目标支持 %s-%s）。\n' \
      "$current_schema" "$target_min_schema" "$target_schema" >&2
    return 1
  fi
  manager_handoff_versions_file_is_safe "$versions" "$current_version" || {
    echo "错误：管理脚本版本记录缺失、不安全或与当前脚本不一致：$versions" >&2
    return 1
  }
  candidate_sha256="$(manager_handoff_sha256 "$candidate")" || return 1
  current_sha256="$(manager_handoff_sha256 "$installed")" || return 1
  [[ "$candidate_sha256" =~ ^[0-9a-f]{64}$ && "$current_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1

  acquire_manager_handoff_lock || {
    echo '错误：另一个安装、恢复或接管操作正在执行，已停止本次接管。' >&2
    return 1
  }
  if [[ -e "$MANAGER_HANDOFF_JOURNAL" || -L "$MANAGER_HANDOFF_JOURNAL" ]]; then
    release_manager_handoff_locks
    echo '错误：发现尚未恢复的管理脚本接管记录；请重新运行脚本先完成自动恢复。' >&2
    return 1
  fi
  if [[ "$(manager_handoff_sha256 "$candidate")" != "$candidate_sha256" ||
        "$(manager_handoff_sha256 "$installed")" != "$current_sha256" ]] ||
     ! manager_handoff_versions_file_is_safe "$versions" "$current_version"; then
    release_manager_handoff_locks
    echo '错误：接管准备期间脚本或版本记录发生变化，已取消本次操作。' >&2
    return 1
  fi
  if ! prepare_manager_handoff_directory; then
    release_manager_handoff_locks
    echo "错误：无法创建安全的管理脚本恢复目录：$MANAGER_HANDOFF_DIRECTORY" >&2
    return 1
  fi
  backup_script="$(manager_handoff_backup_script_path)"
  backup_versions="$(manager_handoff_backup_versions_path)"
  if ! atomic_install_file "$installed" "$backup_script" 700 ||
     ! atomic_install_file "$versions" "$backup_versions" 600 ||
     [[ "$(manager_handoff_sha256 "$backup_script")" != "$current_sha256" ]] ||
     ! manager_handoff_versions_file_is_safe "$backup_versions" "$current_version" ||
     ! write_manager_handoff_journal \
       "$current_version" "$current_edition" "$current_schema" "$current_sha256" \
       "$target_version" "$target_edition" "$target_schema"; then
    release_manager_handoff_locks
    echo '错误：无法建立完整的接管回退点，当前安装脚本没有改变。' >&2
    return 1
  fi

  MANAGER_HANDOFF_ROLLBACK_ACTIVE=true
  MANAGER_HANDOFF_ROLLBACK_OLD_SHA256="$current_sha256"
  MANAGER_HANDOFF_ROLLBACK_OLD_VERSION="$current_version"
  trap rollback_manager_handoff ERR
  set_signal_rollback rollback_manager_handoff
  if ! atomic_install_file "$candidate" "$installed" 700 ||
     ! update_deployed_manager_version "$target_version" ||
     ! verify_manager_handoff_installation \
       "$installed" "$candidate" "$target_version" "$target_edition" "$target_schema" ||
     ! clear_manager_handoff_journal; then
    rollback_manager_handoff 1 || true
    return 1
  fi
  MANAGER_HANDOFF_ROLLBACK_ACTIVE=false
  MANAGER_HANDOFF_ROLLBACK_OLD_SHA256=""
  MANAGER_HANDOFF_ROLLBACK_OLD_VERSION=""
  trap - ERR
  clear_signal_rollback
  release_manager_handoff_locks
  sync_manager_handoff_root_copy "$installed" "$current_sha256"
  printf '管理脚本接管完成：%s %s → %s %s\n' \
    "$current_version" "$current_edition" "$target_version" "$target_edition"
  printf '用户、流量、证书、分流和运行服务均未修改；原脚本保存在：%s\n' "$backup_script"
}
# <<< manager_channel_handoff

installed_singbox_version() { kernel_binary_version "${SINGBOX_BIN:-/usr/local/bin/sing-box}"; }
# 当前部署实际使用的内核版本。sing-box 通道管理仍用上面那个专用入口，
# 因为通道是 sing-box 独有的概念，换内核后不存在对应物。
installed_kernel_version() {
  local binary
  binary="$(kernel_binary_path)" || return 1
  kernel_binary_version "$binary"
}
installed_nfuse_version() {
  local bin="${NFUSE_BIN:-/usr/local/bin/nfuse}" reported rc=0
  # 二进制缺失、丢执行位或根本跑不起来时版本记录都不可信；返回空串让部署流程重新下载。
  [[ -x "$bin" ]] || return 0
  # 残缺的二进制可能挂起而不是立刻失败，因此加超时；没有 timeout 命令的环境退回直接执行。
  if command -v timeout >/dev/null 2>&1; then
    reported="$(timeout 5 "$bin" version 2>/dev/null)" || rc=$?
  else
    reported="$("$bin" version 2>/dev/null)" || rc=$?
  fi
  # 只要能跑起来（正常退出或有输出）就认为二进制可用。版本号仍以记录为准，
  # 这样 Nfuse 日后改变 version 输出格式时不会被误判为损坏而陷入反复重装。
  if ((rc != 0)) && [[ -z "$reported" ]]; then return 0; fi
  if [[ -r "$DEPLOYED_VERSIONS_FILE" ]]; then sed -n 's/^NFUSE_VERSION=//p' "$DEPLOYED_VERSIONS_FILE"
  else grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$reported" | head -n1 || true
  fi
}

installed_manager_version() {
  local path="${MANAGER_INSTALLED_PATH:-/usr/local/sbin/sb-user-manager}"
  local versions="${MANAGER_VERSIONS_FILE:-/var/lib/sb-user-manager/versions}" version=""
  if [[ -r "$path" ]]; then
    version="$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)"/\1/p' "$path" | head -n1)"
  fi
  if [[ -z "$version" && -r "$versions" ]]; then
    version="$(sed -n 's/^SCRIPT_VERSION=//p' "$versions" | head -n1)"
  fi
  printf '%s' "$version"
}

handoff_to_newer_installed_manager() {
  local installed version
  installed="${MANAGER_INSTALLED_PATH:-/usr/local/sbin/sb-user-manager}"
  installed="$(readlink -f -- "$installed" 2>/dev/null || printf '%s' "$installed")"
  [[ "$SELF_PATH" != "$installed" && -x "$installed" ]] || return 0
  version="$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)"/\1/p' "$installed" | head -n1)"
  [[ -n "$version" ]] || return 0
  version_gt "$version" "$SCRIPT_VERSION" || return 0
  printf '检测到已安装管理脚本 %s，高于当前启动副本 %s；正在切换到 %s。\n' \
    "$version" "$SCRIPT_VERSION" "$installed"
  exec "$installed" "$@"
}

sync_manager_launch_path() {
  local installed="$1" target="$2" label="$3" resolved tmp
  installed="$(readlink -f -- "$installed" 2>/dev/null || printf '%s' "$installed")"
  [[ "$target" != "$installed" ]] || return 0
  if [[ -L "$target" ]]; then
    resolved="$(readlink -f -- "$target" 2>/dev/null || true)"
    [[ "$resolved" == "$installed" ]] && return 0
    log "警告：${label}是指向其他位置的链接，为避免覆盖现有文件，本次没有修改；以后请直接运行 $installed"
    return 0
  fi
  [[ -f "$target" ]] || return 0
  if ! tmp="$(mktemp "$(dirname "$target")/.sb-user-manager.launch.XXXXXX")"; then
    log "警告：无法在${label}目录创建临时文件；以后请直接运行 $installed"
    return 0
  fi
  register_temp_path "$tmp"
  if install -m 700 "$installed" "$tmp" && mv -f "$tmp" "$target"; then
    log "已同步${label}：$target"
  else
    rm -f "$tmp"
    log "警告：无法同步${label} ${target}；以后请直接运行 $installed"
  fi
}

sync_manager_launch_copy() {
  local installed="$1" self root_copy="${MANAGER_ROOT_LAUNCH_COPY:-/root/sb-user-manager.sh}"
  installed="$(readlink -f -- "$installed" 2>/dev/null || printf '%s' "$installed")"
  self="$(readlink -f -- "$SELF_PATH" 2>/dev/null || printf '%s' "$SELF_PATH")"
  sync_manager_launch_path "$installed" "$self" '当前启动副本'
  if [[ "$root_copy" != "$self" ]]; then
    sync_manager_launch_path "$installed" "$root_copy" 'root 启动副本'
  fi
}

ensure_manager_launch_copies_for_interactive_startup() {
  local installed="${MANAGER_INSTALLED_PATH:-/usr/local/sbin/sb-user-manager}" self
  installed="$(readlink -f -- "$installed" 2>/dev/null || printf '%s' "$installed")"
  self="$(readlink -f -- "$SELF_PATH" 2>/dev/null || printf '%s' "$SELF_PATH")"
  [[ "$self" == "$installed" && -x "$installed" ]] || return 0
  sync_manager_launch_copy "$installed"
}

atomic_install_file() {
  local source="$1" target="$2" mode="$3" parent tmp actual_mode
  [[ -f "$source" && ! -L "$source" ]] || return 1
  [[ "$target" == /* && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  parent="$(dirname -- "$target")" || return 1
  [[ -d "$parent" && ! -L "$parent" ]] || return 1
  if [[ -e "$target" || -L "$target" ]]; then
    [[ -f "$target" && ! -L "$target" ]] || return 1
  fi
  tmp="$(mktemp "$parent/.atomic-install.XXXXXX")" || return 1
  if ! register_temp_path "$tmp"; then
    rm -f -- "$tmp" || true
    return 1
  fi
  if ! install -m "$mode" -- "$source" "$tmp" ||
    ! cmp -s -- "$source" "$tmp" ||
    ! actual_mode="$(manager_file_mode "$tmp")" ||
    [[ "$actual_mode" != "${mode#0}" ]] ||
    ! sync_transaction_path "$tmp" ||
    ! mv -- "$tmp" "$target"; then
    rm -f -- "$tmp" || true
    return 1
  fi
  unregister_temp_path "$tmp" || return 1
  sync_transaction_path "$parent" || return 1
}

# 下载并安装 sing-box。资产是 tar.gz，内含一个以「名字-版本-架构」命名的目录。
download_singbox_binary() {
  local work="$1" archive member
  archive="$LATEST_KERNEL_ASSET"
  member="sing-box-${LATEST_KERNEL_VERSION}-${SINGBOX_ARCH}/sing-box"
  github_download_to "$work/$archive" "$LATEST_KERNEL_URL" || return 1
  printf '%s  %s\n' "$LATEST_KERNEL_SHA256" "$work/$archive" | sha256sum -c - >/dev/null || return 1
  tar -xzf "$work/$archive" -C "$work" --no-same-owner "$member" || return 1
  [[ -f "$work/$member" && ! -L "$work/$member" ]] || return 1
  atomic_install_file "$work/$member" /usr/local/bin/sing-box 755 || return 1
}

# 下载并安装 mihomo。资产是**单个 gz 压缩的可执行文件**，不是 tar 包，
# 因此用 gzip -dc 定向写出，文件名由我们决定，不依赖压缩包内记录的原名。
# 解压后核对版本：这一步顺带挡住选错微架构的资产——不匹配时二进制拒绝运行，
# 版本读出来是空字符串，比对当场失败（见公开 Issue #165）。
download_mihomo_binary() {
  local work="$1" archive binary detected
  archive="$LATEST_KERNEL_ASSET"
  binary="$work/mihomo"
  github_download_to "$work/$archive" "$LATEST_KERNEL_URL" || return 1
  printf '%s  %s\n' "$LATEST_KERNEL_SHA256" "$work/$archive" | sha256sum -c - >/dev/null || return 1
  gzip -dc -- "$work/$archive" > "$binary" || return 1
  [[ -f "$binary" && ! -L "$binary" ]] || return 1
  chmod 755 "$binary" || return 1
  detected="$(kernel_binary_version "$binary")" || return 1
  [[ "$detected" == "$LATEST_KERNEL_VERSION" ]] || {
    echo "下载到的 mihomo 无法报告预期版本（期望 ${LATEST_KERNEL_VERSION}，实际「${detected:-空}」）；可能是该资产与本机 CPU 微架构不匹配。" >&2
    return 1
  }
  atomic_install_file "$binary" /usr/local/bin/mihomo 755 || return 1
}

download_kernel_binary() {
  case "$PROXY_KERNEL" in
    singbox) download_singbox_binary "$1" || return 1 ;;
    mihomo) download_mihomo_binary "$1" || return 1 ;;
    *) kernel_unknown || return 1 ;;
  esac
}

download_binaries() {
  local work="$1" kernel_current nfuse_current
  kernel_current="$(installed_kernel_version)"; nfuse_current="$(installed_nfuse_version)"
  if [[ "$kernel_current" != "$LATEST_KERNEL_VERSION" ]]; then
    [[ "$LATEST_KERNEL_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z][0-9A-Za-z.-]*)?$ ]] || return 1
    download_kernel_binary "$work" || return 1
  fi
  if [[ "$nfuse_current" != "$LATEST_NFUSE_VERSION" ]]; then
    [[ "$LATEST_NFUSE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z][0-9A-Za-z.-]*)?$ ]] || return 1
    github_download_to "$work/nfuse.tar.gz" "$LATEST_NFUSE_URL" || return 1
    printf '%s  %s\n' "$LATEST_NFUSE_SHA256" "$work/nfuse.tar.gz" | sha256sum -c - >/dev/null || return 1
    install -d -m 700 "$work/nfuse" || return 1
    tar -xzf "$work/nfuse.tar.gz" -C "$work/nfuse" --no-same-owner nfuse || return 1
    [[ -f "$work/nfuse/nfuse" && ! -L "$work/nfuse/nfuse" ]] || return 1
    atomic_install_file "$work/nfuse/nfuse" /usr/local/bin/nfuse 755 || return 1
  fi
}

download_manager() {
  local work="$1" target="$2" downloaded_version
  [[ -n "${LATEST_MANAGER_URL:-}" ]] || die "最新 Release 缺少 ${MANAGER_ASSET} 附件"
  github_download_to "$work/$MANAGER_ASSET" "$LATEST_MANAGER_URL" || return 1
  printf '%s  %s\n' "$LATEST_MANAGER_SHA256" "$work/$MANAGER_ASSET" | sha256sum -c - >/dev/null || return 1
  bash -n "$work/$MANAGER_ASSET" || return 1
  downloaded_version="$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)"/\1/p' "$work/$MANAGER_ASSET" | head -n1)"
  [[ "$downloaded_version" == "$LATEST_MANAGER_VERSION" ]] ||
    die "Release 标签与脚本版本不一致：${LATEST_MANAGER_VERSION} != ${downloaded_version:-未知}"
  atomic_install_file "$work/$MANAGER_ASSET" "$target" 700 || return 1
}

default_network_interface() {
  ip -4 route show default | awk 'NR==1 {print $5}'
}

ensure_anytls_certificate() {
  local cert_dir
  cert_dir="$(system_path /etc/sing-box/cert)" || return 1
  install -d -m 700 "$cert_dir" || return 1
  if [[ ! -s "$cert_dir/anytls.crt" || ! -s "$cert_dir/anytls.key" ]]; then
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 -subj '/CN=localhost' \
      -addext "subjectAltName=IP:$(hostname -I | awk '{print $1}')" \
      -keyout "$cert_dir/anytls.key" -out "$cert_dir/anytls.crt" >/dev/null 2>&1 || return 1
    chmod 600 "$cert_dir/anytls.key" || return 1
    chmod 644 "$cert_dir/anytls.crt" || return 1
  fi
}

install_manager_binary() {
  local work="$1" update_manager="${2:-false}" target
  target="$(system_path /usr/local/sbin/sb-user-manager)" || return 1
  if [[ "$update_manager" == true ]]; then
    download_manager "$work" "$target" || return 1
    return 0
  fi
  if [[ "$SELF_PATH" != "$target" ]] || ! cmp -s "$SELF_PATH" "$target"; then
    atomic_install_file "$SELF_PATH" "$target" 700 || return 1
  fi
}

validate_manager_shortcut_path() {
  local shortcut target='/usr/local/sbin/sb-user-manager'
  shortcut="$(system_path /usr/local/bin/sbm)" || return 1
  [[ ! -e "$shortcut" && ! -L "$shortcut" ]] && return 0
  [[ -L "$shortcut" && "$(readlink "$shortcut")" == "$target" ]]
}

install_manager_shortcut() {
  local shortcut target='/usr/local/sbin/sb-user-manager'
  shortcut="$(system_path /usr/local/bin/sbm)" || return 1
  validate_manager_shortcut_path || return 1
  [[ -L "$shortcut" ]] && return 0
  install -d -m 755 -- "$(dirname "$shortcut")" || return 1
  ln -s -- "$target" "$shortcut" || return 1
}

ensure_manager_shortcut_for_interactive_startup() {
  local installed shortcut
  installed="$(system_path /usr/local/sbin/sb-user-manager)" || return 0
  shortcut="$(system_path /usr/local/bin/sbm)" || return 0
  [[ -x "$installed" ]] || return 0
  if ! validate_manager_shortcut_path; then
    log "提示：/usr/local/bin/sbm 已被其他文件或链接占用，脚本没有覆盖它；完整命令 sb-user-manager 仍可正常使用"
    pause_menu
    return 0
  fi
  [[ -e "$shortcut" || -L "$shortcut" ]] && return 0
  if ! install_manager_shortcut; then
    log "警告：未能自动创建 sbm 快捷入口；完整命令 sb-user-manager 仍可正常使用"
    pause_menu
  fi
}

write_deployed_versions() {
  local manager_version="$1" state_dir kernel_key
  # 版本记录里的内核字段按内核命名。sing-box 部署保持 SINGBOX_VERSION 不变——
  # 该文件的内容在管理脚本接管流程中被逐字节比对，改名会影响既有部署。
  case "$PROXY_KERNEL" in
    singbox) kernel_key=SINGBOX_VERSION ;;
    mihomo) kernel_key=MIHOMO_VERSION ;;
    *) kernel_unknown || return 1 ;;
  esac
  state_dir="$(system_path /var/lib/sb-user-manager)" || return 1
  install -d -m 700 "$state_dir" || return 1
  printf 'SCRIPT_VERSION=%s\n%s=%s\nNFUSE_VERSION=%s\n' \
    "$manager_version" "$kernel_key" "$LATEST_KERNEL_VERSION" "$LATEST_NFUSE_VERSION" > "$state_dir/versions" || return 1
  chmod 600 "$state_dir/versions" || return 1
}

activate_managed_services() {
  local kernel_service
  kernel_service="$(kernel_service_name)" || return 1
  systemctl daemon-reload || return 1
  systemctl enable nfuse "$kernel_service" sb-user-expiry.timer >/dev/null || return 1
  systemctl restart nfuse "$kernel_service" || return 1
  wait_for_nfuse_ready || return 1
  systemctl start sb-user-expiry.timer || return 1
  systemctl is-active --quiet nfuse || return 1
  kernel_service_is_active || return 1
}

restore_failed_environment_change() {
  local action="$1" backup="$2" work="$3"
  log "${action}失败，正在从 $backup 恢复"
  if restore_environment_backup "$backup"; then
    [[ ! -e "$ENVIRONMENT_TRANSACTION_JOURNAL" ]] || clear_environment_transaction ||
      log "严重错误：环境已回滚，但无法清除恢复日志：$ENVIRONMENT_TRANSACTION_JOURNAL"
  else
    log "严重错误：环境快照自动恢复失败，请保留 $backup 并人工检查"
  fi
  release_environment_lock
  rm -rf -- "$work"
}

complete_environment_change() {
  local work="$1"
  clear_environment_transaction || return 1
  trap - ERR
  clear_signal_rollback
  rm -rf -- "$work" || return 1
}

environment_backup_paths() {
  cat <<'EOF'
/etc/sing-box
/var/lib/nfuse
/var/lib/sing-box
/var/lib/sb-user-manager
/etc/sb-user-manager.conf
/etc/systemd/system/sing-box.service
/etc/systemd/system/nfuse.service
/etc/systemd/system/sb-user-expiry.service
/etc/systemd/system/sb-user-expiry.timer
/etc/systemd/system/multi-user.target.wants/sing-box.service
/etc/systemd/system/multi-user.target.wants/nfuse.service
/etc/systemd/system/timers.target.wants/sb-user-expiry.timer
/usr/local/sbin/sb-user-manager
/usr/local/bin/sbm
/usr/local/bin/sing-box
/usr/local/bin/nfuse
EOF
}

write_environment_snapshot_manifest() {
  local backup="$1" file link target
  : > "$backup/SYMLINKS.tsv" || return 1
  while IFS= read -r -d '' link; do
    target="$(readlink "$link")" || return 1
    printf '%s\t%s\n' "${link#"$backup/"}" "$target" >> "$backup/SYMLINKS.tsv" || return 1
  done < <(find "$backup/root" -type l -print0 | sort -z)
  if ! (
    cd "$backup" || exit 1
    while IFS= read -r -d '' file; do sha256sum "$file" || exit 1; done < <(find root -type f -print0 | sort -z)
    sha256sum SNAPSHOT_VERSION SYMLINKS.tsv || exit 1
  ) > "$backup/MANIFEST.sha256"; then return 1; fi
  chmod 600 "$backup/SNAPSHOT_VERSION" "$backup/SYMLINKS.tsv" "$backup/MANIFEST.sha256" || return 1
}

verify_environment_backup() {
  local backup="$1" generated_manifest generated_links link relative
  [[ -d "$backup/root" && -f "$backup/SNAPSHOT_VERSION" && -f "$backup/SYMLINKS.tsv" && -f "$backup/MANIFEST.sha256" ]] || {
    log "环境快照缺少格式或校验文件：$backup"; return 1;
  }
  [[ "$(<"$backup/SNAPSHOT_VERSION")" == 1 ]] || { log "不支持的环境快照版本"; return 1; }
  generated_manifest="$(mktemp /tmp/sb-snapshot-manifest.XXXXXX)" || return 1
  generated_links="$(mktemp /tmp/sb-snapshot-links.XXXXXX)" || { rm -f -- "$generated_manifest"; return 1; }
  register_temp_path "$generated_manifest"; register_temp_path "$generated_links"
  while IFS= read -r -d '' link; do
    printf '%s\t%s\n' "${link#"$backup/"}" "$(readlink "$link")" >> "$generated_links"
  done < <(find "$backup/root" -type l -print0 | sort -z)
  if ! cmp -s "$generated_links" "$backup/SYMLINKS.tsv"; then
    rm -f "$generated_manifest" "$generated_links"; log "环境快照符号链接清单校验失败"; return 1
  fi
  (
    cd "$backup" || exit 1
    while IFS= read -r -d '' relative; do sha256sum "$relative" || exit 1; done < <(find root -type f -print0 | sort -z)
    sha256sum SNAPSHOT_VERSION SYMLINKS.tsv || exit 1
  ) > "$generated_manifest" || { rm -f -- "$generated_manifest" "$generated_links"; return 1; }
  if ! cmp -s "$generated_manifest" "$backup/MANIFEST.sha256"; then
    rm -f "$generated_manifest" "$generated_links"; log "环境快照 SHA256 清单校验失败"; return 1
  fi
  rm -f "$generated_manifest" "$generated_links"
}

verify_environment_backup_permissions() {
  local backup="$1" path expected actual mode
  while IFS=$'\t' read -r path expected; do
    actual="$(manager_file_mode "$path")" || {
      log "无法确认环境快照权限：$path"
      return 1
    }
    if [[ "$actual" != "$expected" ]]; then
      log "环境快照权限不安全：${path}（当前 ${actual}，应为 ${expected}）"
      return 1
    fi
  done <<EOF
$backup	700
$backup/root	700
$backup/SNAPSHOT_VERSION	600
$backup/SYMLINKS.tsv	600
$backup/MANIFEST.sha256	600
EOF
  while IFS= read -r -d '' path; do
    mode="$(manager_file_mode "$path")" || return 1
    [[ "$mode" == 700 ]] || {
      log "环境快照目录权限不安全：${path}（当前 ${mode}，应为 700）"
      return 1
    }
  done < <(find "$backup/root" -type d -print0)
  while IFS= read -r -d '' path; do
    mode="$(manager_file_mode "$path")" || return 1
    [[ "$mode" == 600 || "$mode" == 700 ]] || {
      log "环境快照文件权限不安全：${path}（当前 ${mode}，应为 600 或 700）"
      return 1
    }
  done < <(find "$backup/root" -type f -print0)
}

harden_environment_backup_contents() {
  local backup="$1" path mode
  [[ -d "$backup/root" && ! -L "$backup/root" ]] || return 1
  set_path_mode_if_needed "$backup" 700 || return 1
  set_path_mode_if_needed "$backup/root" 700 || return 1
  while IFS= read -r -d '' path; do
    set_path_mode_if_needed "$path" 700 || return 1
  done < <(find "$backup/root" -type d -print0)
  while IFS= read -r -d '' path; do
    mode="$(manager_file_mode "$path")" || return 1
    if [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 0100) != 0 )); then
      set_path_mode_if_needed "$path" 700 || return 1
    else
      set_path_mode_if_needed "$path" 600 || return 1
    fi
  done < <(find "$backup/root" -type f -print0)
}

set_path_mode_if_needed() {
  local path="$1" expected="$2" actual
  actual="$(manager_file_mode "$path")" || return 1
  [[ "$actual" == "$expected" ]] || chmod "$expected" "$path"
}

environment_backup_base_fingerprint() {
  local base="$1"
  stat -c '%d:%i:%y:%z' -- "$base" 2>/dev/null || stat -f '%d:%i:%m:%c' "$base" 2>/dev/null
}

environment_backup_permission_cache_matches() {
  local base="$1" marker="$ENVIRONMENT_BACKUP_PERMISSION_MARKER" current cached
  [[ -f "$marker" && ! -L "$marker" ]] || return 1
  current="$(environment_backup_base_fingerprint "$base")" || return 1
  IFS= read -r cached < "$marker" || return 1
  [[ -n "$cached" && "$cached" == "$current" ]]
}

record_environment_backup_permission_cache() {
  local base="$1" marker="$ENVIRONMENT_BACKUP_PERMISSION_MARKER" dir tmp fingerprint
  dir="$(dirname "$marker")"
  if [[ -e "$dir" || -L "$dir" ]]; then
    [[ -d "$dir" && ! -L "$dir" ]] || return 1
  else
    install -d -m 700 -- "$dir" || return 1
  fi
  if [[ -e "$marker" || -L "$marker" ]]; then
    [[ -f "$marker" && ! -L "$marker" ]] || return 1
  fi
  fingerprint="$(environment_backup_base_fingerprint "$base")" || return 1
  tmp="$(mktemp "$dir/.environment-backup-permissions.XXXXXX")" || return 1
  if ! printf '%s\n' "$fingerprint" > "$tmp" || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$marker"; then
    rm -f -- "$tmp"
    return 1
  fi
}

is_environment_snapshot_for_permission_migration() {
  local snapshot="$1" version
  [[ -d "$snapshot" && ! -L "$snapshot" ]] || return 1
  [[ -d "$snapshot/root" && ! -L "$snapshot/root" ]] || return 1
  [[ -f "$snapshot/SNAPSHOT_VERSION" && ! -L "$snapshot/SNAPSHOT_VERSION" ]] || return 1
  [[ -f "$snapshot/SYMLINKS.tsv" && ! -L "$snapshot/SYMLINKS.tsv" ]] || return 1
  [[ -f "$snapshot/MANIFEST.sha256" && ! -L "$snapshot/MANIFEST.sha256" ]] || return 1
  version="$(head -n1 -- "$snapshot/SNAPSHOT_VERSION" 2>/dev/null)" || return 1
  [[ "$version" == 1 ]]
}

prepare_environment_backup_for_restore() {
  local backup="$1"
  is_environment_snapshot_for_permission_migration "$backup" || {
    log "环境快照结构不安全，拒绝恢复：$backup"
    return 1
  }
  verify_environment_backup "$backup" || return 1
  if ! harden_environment_backup_contents "$backup" ||
     ! set_path_mode_if_needed "$backup/SNAPSHOT_VERSION" 600 ||
     ! set_path_mode_if_needed "$backup/SYMLINKS.tsv" 600 ||
     ! set_path_mode_if_needed "$backup/MANIFEST.sha256" 600; then
    log "环境快照权限无法安全整理，拒绝恢复：$backup"
    return 1
  fi
  # 权限迁移不应改变内容；清理现有文件前再次校验，防止竞态或意外改写。
  verify_environment_backup "$backup" || return 1
  verify_environment_backup_permissions "$backup" || return 1
}

harden_existing_environment_backups() {
  local base snapshot failed=false
  base="${ENVIRONMENT_BACKUP_BASE:-/root/sb-user-manager-backups}"
  [[ -e "$base" || -L "$base" ]] || return 0
  [[ -d "$base" && ! -L "$base" ]] || return 1
  # 子文件权限也必须每次复核；仅比较备份根目录元数据无法发现内部文件被放宽。

  set_path_mode_if_needed "$base" 700 || failed=true
  while IFS= read -r -d '' snapshot; do
    is_environment_snapshot_for_permission_migration "$snapshot" || continue
    harden_environment_backup_contents "$snapshot" || failed=true
    set_path_mode_if_needed "$snapshot/SNAPSHOT_VERSION" 600 || failed=true
    set_path_mode_if_needed "$snapshot/SYMLINKS.tsv" 600 || failed=true
    set_path_mode_if_needed "$snapshot/MANIFEST.sha256" 600 || failed=true
  done < <(find "$base" -mindepth 1 -maxdepth 1 -type d -print0)
  [[ "$failed" == false ]] || return 1
  environment_backup_permission_cache_matches "$base" && return 0
  record_environment_backup_permission_cache "$base"
}

verify_restored_environment_files() {
  local backup="$1" destination="${SB_SYSTEM_ROOT:-/}" source relative restored
  while IFS= read -r -d '' source; do
    relative="${source#"$backup/root/"}"; restored="$destination/$relative"
    [[ -f "$restored" && ! -L "$restored" ]] && cmp -s "$source" "$restored" || return 1
  done < <(find "$backup/root" -mindepth 1 -type f -print0)
  while IFS= read -r -d '' source; do
    relative="${source#"$backup/root/"}"; restored="$destination/$relative"
    [[ -L "$restored" && "$(readlink "$source")" == "$(readlink "$restored")" ]] || return 1
  done < <(find "$backup/root" -mindepth 1 -type l -print0)
  while IFS= read -r -d '' source; do
    relative="${source#"$backup/root/"}"; restored="$destination/$relative"
    [[ -d "$restored" && ! -L "$restored" ]] || return 1
  done < <(find "$backup/root" -mindepth 1 -type d -print0)
}

active_environment_backup_snapshot() {
  local snapshot
  [[ -f "$ENVIRONMENT_TRANSACTION_JOURNAL" && ! -L "$ENVIRONMENT_TRANSACTION_JOURNAL" ]] || return 1
  snapshot="$(jq -r '.snapshot // empty' "$ENVIRONMENT_TRANSACTION_JOURNAL" 2>/dev/null)" || return 1
  [[ -n "$snapshot" ]] || return 1
  printf '%s\n' "$snapshot"
}

load_environment_snapshot_candidates() {
  local base="${ENVIRONMENT_BACKUP_BASE:-/root/sb-user-manager-backups}" snapshot
  ENVIRONMENT_SNAPSHOTS=()
  [[ -d "$base" && ! -L "$base" ]] || return 0
  while IFS= read -r snapshot; do
    is_environment_snapshot_for_permission_migration "$snapshot" || continue
    ENVIRONMENT_SNAPSHOTS[${#ENVIRONMENT_SNAPSHOTS[@]}]="$snapshot"
  done < <(find "$base" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' -print | sort -r)
}

count_invalid_environment_snapshots() {
  local base="${ENVIRONMENT_BACKUP_BASE:-/root/sb-user-manager-backups}" snapshot count=0
  [[ -d "$base" && ! -L "$base" ]] || { printf '0\n'; return 0; }
  while IFS= read -r snapshot; do
    is_environment_snapshot_for_permission_migration "$snapshot" || ((count+=1))
  done < <(find "$base" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' -print)
  printf '%s\n' "$count"
}

prune_environment_backups() {
  local keep="$1" active="" snapshot kept=0 failed=false
  [[ "$keep" =~ ^[0-9]+$ ]] || return 1
  load_environment_snapshot_candidates
  active="$(active_environment_backup_snapshot 2>/dev/null || true)"
  ((${#ENVIRONMENT_SNAPSHOTS[@]} > 0)) || return 0
  for snapshot in "${ENVIRONMENT_SNAPSHOTS[@]}"; do
    if [[ -n "$active" && "$snapshot" == "$active" ]]; then
      continue
    fi
    verify_environment_backup "$snapshot" >/dev/null 2>&1 || continue
    if ((kept < keep)); then
      ((kept+=1))
      continue
    fi
    rm -rf -- "$snapshot" || failed=true
  done
  [[ "$failed" == false ]]
}

backup_retention_migration_completed() {
  local marker="$BACKUP_RETENTION_MIGRATION_MARKER" value
  [[ -f "$marker" && ! -L "$marker" ]] || return 1
  IFS= read -r value < "$marker" || return 1
  [[ "$value" == 1 ]]
}

backup_retention_migration_marker_path_safe() {
  local marker="$BACKUP_RETENTION_MIGRATION_MARKER" dir
  dir="$(dirname "$marker")"
  if [[ -e "$dir" || -L "$dir" ]]; then
    [[ -d "$dir" && ! -L "$dir" ]] || return 1
  fi
  if [[ -e "$marker" || -L "$marker" ]]; then
    [[ -f "$marker" && ! -L "$marker" ]] || return 1
  fi
}

record_backup_retention_migration_complete() {
  local marker="$BACKUP_RETENTION_MIGRATION_MARKER" dir tmp
  dir="$(dirname "$marker")"
  backup_retention_migration_marker_path_safe || return 1
  if [[ -e "$dir" || -L "$dir" ]]; then
    :
  else
    install -d -m 700 -- "$dir" || return 1
  fi
  tmp="$(mktemp "$dir/.backup-retention.XXXXXX")" || return 1
  if ! printf '1\n' > "$tmp" || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$marker"; then
    rm -f -- "$tmp"
    return 1
  fi
}

migrate_backup_retention_once() {
  local installed self candidate_count
  installed="${MANAGER_INSTALLED_PATH:-/usr/local/sbin/sb-user-manager}"
  installed="$(readlink -f -- "$installed" 2>/dev/null || printf '%s' "$installed")"
  self="$(readlink -f -- "$SELF_PATH" 2>/dev/null || printf '%s' "$SELF_PATH")"
  # 候选文件和旧启动副本只负责转交；仅正式安装入口可以删除历史回滚材料。
  [[ "$self" == "$installed" && -x "$installed" ]] || return 0
  backup_retention_migration_completed && return 0
  backup_retention_migration_marker_path_safe || return 1
  [[ ! -e "$ENVIRONMENT_TRANSACTION_JOURNAL" && ! -L "$ENVIRONMENT_TRANSACTION_JOURNAL" ]] || return 1
  load_environment_snapshot_candidates
  candidate_count="${#ENVIRONMENT_SNAPSHOTS[@]}"
  if ((candidate_count > ENVIRONMENT_BACKUP_RETENTION)); then
    log "首次启用备份自动整理，正在安全检查旧的完整备份，请稍候…"
  fi
  prune_environment_backups "$ENVIRONMENT_BACKUP_RETENTION" || return 1
  record_backup_retention_migration_complete || return 1
  if ((candidate_count > ENVIRONMENT_BACKUP_RETENTION)); then
    log "旧的完整备份已整理完成；有效快照最多保留最近 ${ENVIRONMENT_BACKUP_RETENTION} 份"
  fi
}

snapshot_nfuse_sqlite_database() {
  local source="$1" destination="$2" parent tmp
  [[ -e "$source" || -L "$source" ]] || return 0
  [[ -f "$source" && ! -L "$source" ]] || {
    log "Nfuse 数据库不是普通文件，拒绝创建不可靠快照：$source"
    return 1
  }
  command -v python3 >/dev/null 2>&1 || {
    log "缺少 python3，无法为运行中的 Nfuse 数据库创建一致快照"
    return 1
  }
  parent="$(dirname "$destination")"
  [[ -d "$parent" && ! -L "$parent" ]] || return 1
  tmp="$(mktemp "$parent/.nfuse-snapshot.XXXXXX")" || return 1
  if ! python3 - "$source" "$tmp" 2>/dev/null <<'PY'
import pathlib
import sqlite3
import sys

source_path = pathlib.Path(sys.argv[1]).resolve()
destination_path = sys.argv[2]
source = sqlite3.connect(source_path.as_uri() + "?mode=ro", uri=True, timeout=30.0)
destination = sqlite3.connect(destination_path, timeout=30.0)
try:
    source.execute("PRAGMA query_only = ON")
    source.backup(destination, pages=256, sleep=0.05)
    destination.commit()
    destination.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    if destination.execute("PRAGMA journal_mode = DELETE").fetchone()[0].lower() != "delete":
        raise RuntimeError("could not make standalone SQLite snapshot")
    if destination.execute("PRAGMA quick_check").fetchall() != [("ok",)]:
        raise RuntimeError("SQLite quick_check failed")
finally:
    destination.close()
    source.close()
PY
  then
    rm -f -- "$tmp" "$tmp-wal" "$tmp-shm" || true
    log "无法创建或校验 Nfuse 数据库一致快照：$source"
    return 1
  fi
  if ! rm -f -- "$tmp-wal" "$tmp-shm" || ! chmod 600 "$tmp" || ! mv -- "$tmp" "$destination"; then
    rm -f -- "$tmp" "$tmp-wal" "$tmp-shm" || true
    return 1
  fi
}

create_environment_backup() {
  local path source backup base
  base="${ENVIRONMENT_BACKUP_BASE:-/root/sb-user-manager-backups}"
  backup="$base/$(date '+%Y%m%d-%H%M%S-%N')"
  install -d -m 700 "$base" || return 1
  install -d -m 700 "$backup" || return 1
  install -d -m 700 "$backup/root" || return 1
  while IFS= read -r path; do
    source="$(system_path "$path")"
    if [[ -e "$source" || -L "$source" ]]; then
      if ! install -d -m 700 "$backup/root/$(dirname "${path#/}")" ||
         ! cp -a -- "$source" "$backup/root/${path#/}"; then
        rm -rf -- "$backup"
        return 1
      fi
    fi
  done < <(environment_backup_paths)
  # 内部事务备份另有独立保留策略；不把历史回滚组反复复制进每份完整环境快照。
  rm -rf -- "$backup/root/etc/sing-box/backups"
  if ! snapshot_nfuse_sqlite_database \
      "$(system_path /var/lib/nfuse/nfuse.db)" "$backup/root/var/lib/nfuse/nfuse.db"; then
    rm -rf -- "$backup"
    return 1
  fi
  # 在线备份已生成可独立恢复的数据库；WAL/SHM 会被运行进程重建，不能混入快照。
  if ! rm -f -- "$backup/root/var/lib/nfuse/nfuse.db-wal" "$backup/root/var/lib/nfuse/nfuse.db-shm"; then
    rm -rf -- "$backup"
    return 1
  fi
  if ! harden_environment_backup_contents "$backup"; then
    rm -rf -- "$backup"
    return 1
  fi
  if ! printf '1\n' > "$backup/SNAPSHOT_VERSION" ||
     ! write_environment_snapshot_manifest "$backup" ||
     ! verify_environment_backup "$backup" ||
     ! verify_environment_backup_permissions "$backup"; then
    rm -rf -- "$backup"
    return 1
  fi
  ENV_BACKUP="$backup"
  if ! prune_environment_backups "$ENVIRONMENT_BACKUP_RETENTION"; then
    log "提示：旧的操作前完整备份暂未能自动整理，不影响本次安全备份"
  fi
}

restore_environment_backup() {
  local backup="$1" destination nfuse_snapshot_dir nfuse_snapshot_wal nfuse_snapshot_shm
  local nfuse_target_dir nfuse_target_wal nfuse_target_shm path source target_parent copy_ok=true restored_kernel
  prepare_environment_backup_for_restore "$backup" || return 1
  destination="${SB_SYSTEM_ROOT:-/}"
  nfuse_snapshot_dir="$backup/root/var/lib/nfuse"
  nfuse_snapshot_wal="$nfuse_snapshot_dir/nfuse.db-wal"
  nfuse_snapshot_shm="$nfuse_snapshot_dir/nfuse.db-shm"
  nfuse_target_dir="$destination/var/lib/nfuse"
  nfuse_target_wal="$nfuse_target_dir/nfuse.db-wal"
  nfuse_target_shm="$nfuse_target_dir/nfuse.db-shm"
  if [[ -z "${SB_SYSTEM_ROOT:-}" ]]; then
    systemctl stop sb-user-expiry.timer 2>/dev/null || true
    systemctl stop sing-box mihomo 2>/dev/null || true
    systemctl stop nfuse 2>/dev/null || true
  fi
  # 独立 SQLite 快照不保存 WAL/SHM；复制前移除目标机旧日志，避免覆盖刚恢复的数据。
  if [[ -d "$nfuse_snapshot_dir" ]]; then
    if [[ -e "$nfuse_target_dir" || -L "$nfuse_target_dir" ]]; then
      [[ -d "$nfuse_target_dir" && ! -L "$nfuse_target_dir" ]] || copy_ok=false
    fi
    if [[ "$copy_ok" == true && ! -e "$nfuse_snapshot_wal" && ! -L "$nfuse_snapshot_wal" ]]; then
      rm -f -- "$nfuse_target_wal" || copy_ok=false
    fi
    if [[ "$copy_ok" == true && ! -e "$nfuse_snapshot_shm" && ! -L "$nfuse_snapshot_shm" ]]; then
      rm -f -- "$nfuse_target_shm" || copy_ok=false
    fi
  fi
  while [[ "$copy_ok" == true ]] && IFS= read -r path; do
    source="$backup/root$path"
    [[ -e "$source" || -L "$source" ]] || continue
    target_parent="${destination%/}$(dirname "$path")"
    if [[ ! -d "$target_parent" || -L "$target_parent" ]]; then
      log "环境快照目标父目录不可用：$target_parent"
      copy_ok=false
      break
    fi
    # 逐项复制受管路径，避免把快照容器 root/etc/usr/var 的 700 权限写回系统共享目录。
    if ! cp -a -- "$source" "$target_parent/"; then
      copy_ok=false
      break
    fi
  done < <(environment_backup_paths)
  if [[ "$copy_ok" == true ]] && ! verify_restored_environment_files "$backup"; then copy_ok=false; fi
  if [[ -z "${SB_SYSTEM_ROOT:-}" ]]; then
    if ! systemctl daemon-reload; then log "警告：快照恢复后 systemd 配置重载失败"; copy_ok=false; fi
    if [[ -f /etc/systemd/system/nfuse.service ]]; then
      if ! systemctl restart nfuse; then
        log "警告：快照恢复后 Nfuse 启动失败"; copy_ok=false
      elif [[ -f /etc/sb-user-manager.conf ]] && ! wait_for_nfuse_ready; then
        log "警告：快照恢复后 Nfuse Socket 未在限定时间内就绪"; copy_ok=false
      fi
    fi
    for restored_kernel in sing-box mihomo; do
      if [[ -f "/etc/systemd/system/${restored_kernel}.service" ]] && ! systemctl restart "$restored_kernel"; then
        log "警告：快照恢复后 ${restored_kernel} 启动失败"; copy_ok=false
      fi
    done
    if [[ -f /etc/systemd/system/sb-user-expiry.timer ]] && ! systemctl start sb-user-expiry.timer; then log "警告：快照恢复后到期检测定时器启动失败"; copy_ok=false; fi
  fi
  [[ "$copy_ok" == true ]] || { log "环境快照文件恢复失败"; return 1; }
}

loopback_runtime_bind_is_ready() {
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - >/dev/null 2>&1 <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
    listener.bind(("127.0.0.1", 0))
PY
}

ensure_deploy_loopback_ready() {
  if ! command -v python3 >/dev/null 2>&1; then
    log "安装或更新前安全检查无法执行：缺少 python3。"
    log "为避免停止当前仍在运行的连接服务，本次操作已在修改前取消。"
    log "请先进入「安装或修复环境」补齐依赖，再重新执行。"
    return 1
  fi
  if loopback_runtime_bind_is_ready; then return 0; fi
  log "安装或更新前安全检查未通过：本机回环地址 127.0.0.1 不可用。"
  log "为避免停止当前仍在运行的连接服务，本次操作已在修改前取消。"
  log "请先修复 lo 接口的 127.0.0.1 地址，再重新执行。"
  return 1
}

# 部署过程中可能被创建的路径，顺序为「父目录在前」——
# cleanup_deploy_created_paths 按倒序删除，靠这个顺序先清子项再清父目录。
# 两个内核的路径都列出：已经存在的路径不会被记录为「本次创建」，
# 因此对另一个内核的机器没有任何影响。
deploy_tracked_paths() {
  {
    printf '%s\n' "$CONF_FILE"
    all_kernel_deployment_paths
    cat <<'EOF'
/etc/sing-box/backups
/etc/sing-box/cert
/etc/sing-box/cert/anytls.crt
/etc/sing-box/cert/anytls.key
/etc/systemd/system/nfuse.service
/etc/systemd/system/sb-user-expiry.service
/etc/systemd/system/sb-user-expiry.timer
/etc/systemd/system/multi-user.target.wants/nfuse.service
/etc/systemd/system/timers.target.wants/sb-user-expiry.timer
/var/lib/nfuse
/var/lib/nfuse/nfuse.db
/var/lib/sb-user-manager
/var/lib/sb-user-manager/versions
/usr/local/sbin/sb-user-manager
/usr/local/bin/sbm
/usr/local/bin/nfuse
/run/nfuse.sock
EOF
  } | awk 'NF && !seen[$0]++'
}

# 全新部署失败时清空的路径。与 deploy_tracked_paths 的区别是这里无条件删除，
# 用于「本次是从零开始装的，失败就不该留下任何东西」。
purge_fresh_deploy_paths() {
  local path
  while IFS= read -r path; do
    rm -rf -- "$path"
  done < <(all_kernel_deployment_paths)
  rm -f /etc/sb-user-manager.conf /etc/systemd/system/nfuse.service \
    /etc/systemd/system/sb-user-expiry.service /etc/systemd/system/sb-user-expiry.timer \
    /usr/local/sbin/sb-user-manager /usr/local/bin/sbm /usr/local/bin/nfuse
  rm -rf /var/lib/sb-user-manager
}

deploy_environment() {
  local fresh="$1" update_manager="${2:-false}" iface work backup path deployed_state_file
  local -a deploy_created=()
  local deploy_created_count=0
  # 再确认一次内核，使这个函数不依赖调用点是否记得先确定。
  resolve_deployment_kernel || return 1
  if ! acquire_operation_lock; then
    log "错误：$OPERATION_LOCK_ERROR"
    return 1
  fi
  ensure_safe_ssh_for_kernel_restart || { release_operation_lock; return 0; }
  ensure_deploy_loopback_ready || { release_operation_lock; return 1; }
  validate_manager_shortcut_path || {
    release_operation_lock
    die "检测到 /usr/local/bin/sbm 已被其他文件或链接占用；为避免覆盖现有程序，本次操作已停止"
  }
  [[ "$(uname -m)" == x86_64 ]] || { release_operation_lock; die "仅支持 x86_64 Linux"; }
  iface="$(default_network_interface)" || { release_operation_lock; die "无法识别默认网络接口"; }
  [[ -n "$iface" ]] || { release_operation_lock; die "无法识别默认网络接口"; }
  work="$(mktemp -d /tmp/sb-user-manager.XXXXXX)" || { release_operation_lock; return 1; }
  register_temp_path "$work" || { rm -rf -- "$work"; release_operation_lock; return 1; }
  create_environment_backup || { rm -rf -- "$work"; release_operation_lock; return 1; }
  backup="$ENV_BACKUP"
  rollback_deploy() {
    local rc="${1:-$?}"
    trap - ERR
    clear_signal_rollback
    systemctl stop sb-user-expiry.timer sing-box mihomo nfuse 2>/dev/null || true
    if ((deploy_created_count > 0)); then
      cleanup_deploy_created_paths "${deploy_created[@]}"
    fi
    if [[ "$fresh" == true ]]; then
      purge_fresh_deploy_paths
    fi
    restore_failed_environment_change 部署 "$backup" "$work"
    release_operation_lock
    return "$rc"
  }
  while IFS= read -r path; do
    if [[ ! -e "$path" && ! -L "$path" ]]; then
      deploy_created[deploy_created_count]="$path"
      ((deploy_created_count+=1))
    fi
  done < <(deploy_tracked_paths)
  if ! begin_environment_transaction "deploy-environment" "$backup" "${deploy_created[@]}"; then
    rm -rf -- "$work"
    release_operation_lock
    return 1
  fi
  trap rollback_deploy ERR
  set_signal_rollback rollback_deploy
  run_step_or_rollback rollback_deploy download_binaries "$work" || return 1
  run_step_or_rollback rollback_deploy install -d -m 700 \
    /etc/sing-box /etc/sing-box/backups /etc/sing-box/cert /var/lib/nfuse /usr/local/sbin || return 1
  if [[ "$PROXY_KERNEL" == mihomo ]]; then
    # mihomo 的配置目录与工作目录。工作目录也由 systemd 的 StateDirectory 负责，
    # 但配置校验发生在服务启动之前，那时它还不存在——不预先建好的话，
    # 目录会由 `mihomo -t` 顺手创建，权限与创建时机都不在我们手里。
    run_step_or_rollback rollback_deploy install -d -m 700 /etc/mihomo || return 1
    run_step_or_rollback rollback_deploy install -d -m 755 "$MIHOMO_WORK_DIR" || return 1
  fi
  if [[ "$fresh" == true ]]; then
    run_step_or_rollback rollback_deploy write_manager_config || return 1
    run_step_or_rollback rollback_deploy write_base_config || return 1
  elif [[ ! -f "$CONF_FILE" ]]; then
    run_step_or_rollback rollback_deploy write_manager_config || return 1
  fi
  # 命令替换会继承 errtrace；先清除子进程的 ERR trap，失败只由父事务回滚一次。
  if deployed_state_file="$(trap - ERR; deployed_state_path)"; then :; else
    rollback_deploy 1 || true
    return 1
  fi
  if [[ ! -e "$deployed_state_file" && ! -L "$deployed_state_file" ]]; then
    deploy_created[deploy_created_count]="$deployed_state_file"
    ((deploy_created_count+=1))
  fi
  run_step_or_rollback rollback_deploy initialize_deployed_state "$fresh" || return 1
  run_step_or_rollback rollback_deploy ensure_anytls_certificate || return 1
  run_step_or_rollback rollback_deploy install_manager_binary "$work" "$update_manager" || return 1
  run_step_or_rollback rollback_deploy install_manager_shortcut || return 1
  local deployed_manager_version
  if deployed_manager_version="$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)"/\1/p' /usr/local/sbin/sb-user-manager | head -n1)" &&
     [[ -n "$deployed_manager_version" ]]; then :; else
    rollback_deploy 1 || true
    return 1
  fi
  run_step_or_rollback rollback_deploy write_deployed_versions "$deployed_manager_version" || return 1
  run_step_or_rollback rollback_deploy write_systemd_units "$iface" || return 1
  run_step_or_rollback rollback_deploy kernel_check_default_install || return 1
  run_step_or_rollback rollback_deploy activate_managed_services || return 1
  run_step_or_rollback rollback_deploy complete_environment_change "$work" || return 1
  if [[ "$update_manager" == true ]]; then
    sync_manager_launch_copy /usr/local/sbin/sb-user-manager
  fi
  release_operation_lock
  log "部署完成；备份位于 $backup"
}

takeover_existing_environment() {
  local iface work normalized tmp nfuse_compatible=false path existing_singbox_bin
  local -a takeover_created=()
  if ! acquire_operation_lock; then
    log "错误：$OPERATION_LOCK_ERROR"
    return 1
  fi
  ensure_safe_ssh_for_kernel_restart || { release_operation_lock; return 0; }
  validate_manager_shortcut_path || {
    release_operation_lock
    die "检测到 /usr/local/bin/sbm 已被其他文件或链接占用；为避免覆盖现有程序，本次操作已停止"
  }
  # 接管既有安装按定义只针对既有的 sing-box 部署：它要读的就是现场那份
  # sing-box 配置。选了别的内核还走这条路会得到一台内核与配置对不上的机器。
  [[ "$PROXY_KERNEL" == singbox ]] || {
    release_operation_lock
    die "接管既有安装目前只支持 sing-box 部署"
  }
  existing_singbox_bin="$(command -v sing-box 2>/dev/null || true)"
  [[ -f /etc/sing-box/config.json && -n "$existing_singbox_bin" && -x "$existing_singbox_bin" ]] || {
    release_operation_lock
    die "保留配置接管要求现有 sing-box 配置和 PATH 中可执行的 sing-box 均存在"
  }
  kernel_check_config_with "$existing_singbox_bin" /etc/sing-box/config.json || {
    release_operation_lock
    die "现有 sing-box 配置校验失败，拒绝接管"
  }
  if [[ -f /etc/systemd/system/nfuse.service ]]; then
    if grep -Fq -- '--db /var/lib/nfuse/nfuse.db' /etc/systemd/system/nfuse.service &&
       grep -Fq -- '--socket /run/nfuse.sock' /etc/systemd/system/nfuse.service; then nfuse_compatible=true
    else
      release_operation_lock
      die "现有流量统计服务使用了特殊存储或通信位置，脚本无法安全接管；请选择备份后重新安装"
    fi
  fi
  iface="$(default_network_interface)" || { release_operation_lock; die "无法识别默认网络接口"; }
  [[ -n "$iface" ]] || { release_operation_lock; die "无法识别默认网络接口"; }
  create_environment_backup || { release_operation_lock; return 1; }
  for path in \
    /etc/sb-user-manager.conf \
    /etc/sing-box/managed-users.json \
    /usr/local/sbin/sb-user-manager \
    /usr/local/bin/sbm \
    /etc/systemd/system/sing-box.service \
    /etc/systemd/system/nfuse.service \
    /etc/systemd/system/sb-user-expiry.service \
    /etc/systemd/system/sb-user-expiry.timer \
    /var/lib/sb-user-manager/versions \
    /etc/sing-box/cert/anytls.crt \
    /etc/sing-box/cert/anytls.key; do
    [[ -e "$path" || -L "$path" ]] || takeover_created+=("$path")
  done
  work="$(mktemp -d /tmp/sb-user-manager.takeover.XXXXXX)" || { release_operation_lock; return 1; }
  register_temp_path "$work" || { rm -rf -- "$work"; release_operation_lock; return 1; }
  rollback_takeover() {
    local rc="${1:-$?}"
    trap - ERR
    clear_signal_rollback
    for path in "${takeover_created[@]}"; do rm -f -- "$path" || true; done
    restore_failed_environment_change 接管 "$ENV_BACKUP" "$work"
    release_operation_lock
    return "$rc"
  }
  if ! begin_environment_transaction "takeover-environment" "$ENV_BACKUP" "${takeover_created[@]}"; then
    rm -rf -- "$work"
    release_operation_lock
    return 1
  fi
  trap rollback_takeover ERR
  set_signal_rollback rollback_takeover
  run_step_or_rollback rollback_takeover fetch_latest_releases false || return 1
  run_step_or_rollback rollback_takeover download_binaries "$work" || return 1
  if normalized="$(mktemp /etc/sing-box/.takeover-normalized.XXXXXX)"; then :; else
    rollback_takeover 1 || true
    return 1
  fi
  run_step_or_rollback rollback_takeover register_temp_path "$normalized" || return 1
  if tmp="$(mktemp /etc/sing-box/.takeover-config.XXXXXX)"; then :; else
    rm -f -- "$normalized"
    rollback_takeover 1 || true
    return 1
  fi
  run_step_or_rollback rollback_takeover register_temp_path "$tmp" || return 1
  run_step_or_rollback rollback_takeover write_command_output "$normalized" \
    kernel_normalized_default_install || return 1
  # 与全新安装共用同一份骨架定义，避免接管出来的部署与全新安装不一致。
  run_step_or_rollback rollback_takeover write_command_output "$tmp" \
    jq "$SINGBOX_SKELETON_ENSURE_PROGRAM" "$normalized" || return 1
  run_step_or_rollback rollback_takeover rm -f -- "$normalized" || return 1
  if chmod --reference=/etc/sing-box/config.json "$tmp" 2>/dev/null || chmod 600 "$tmp"; then :; else
    rollback_takeover 1 || true
    return 1
  fi
  chown --reference=/etc/sing-box/config.json "$tmp" 2>/dev/null || true
  run_step_or_rollback rollback_takeover mv "$tmp" /etc/sing-box/config.json || return 1
  run_step_or_rollback rollback_takeover kernel_check_default_install || return 1

  if [[ ! -f "$CONF_FILE" ]]; then run_step_or_rollback rollback_takeover write_manager_config || return 1; fi
  run_step_or_rollback rollback_takeover load_runtime_config || return 1
  run_step_or_rollback rollback_takeover init_state || return 1
  run_step_or_rollback rollback_takeover install_manager_binary "$work" false || return 1
  run_step_or_rollback rollback_takeover install_manager_shortcut || return 1
  run_step_or_rollback rollback_takeover install -d -m 700 \
    /var/lib/nfuse /var/lib/sb-user-manager /etc/sing-box/backups /etc/sing-box/cert || return 1
  run_step_or_rollback rollback_takeover ensure_anytls_certificate || return 1
  if [[ ! -f /etc/systemd/system/sing-box.service ]]; then
    run_step_or_rollback rollback_takeover write_singbox_unit || return 1
  fi
  if [[ "$nfuse_compatible" != true ]]; then
    run_step_or_rollback rollback_takeover write_nfuse_unit "$iface" || return 1
  fi
  run_step_or_rollback rollback_takeover write_expiry_units || return 1
  run_step_or_rollback rollback_takeover write_deployed_versions "$SCRIPT_VERSION" || return 1
  run_step_or_rollback rollback_takeover activate_managed_services || return 1
  run_step_or_rollback rollback_takeover complete_environment_change "$work" || return 1
  release_operation_lock
  log "现有环境已在保留 sing-box 配置的前提下接管；原环境备份：$ENV_BACKUP"
  log "原有节点和路由会继续保留，但不会自动出现在本脚本的用户或分流列表中"
}

# 仅供测试使用的内核选择。菜单里没有这个入口：内核选择要等第二步 2f，
# 而 2f 必须排在 2e 的审计护栏之后——把一台无法自检的机器交出去是不行的。
# 只对尚未部署的机器生效：已部署机器的内核由管理配置决定，部署后不允许更改，
# 中途改会得到一台配置属于旧内核、服务属于新内核的半迁移机器。
apply_test_only_kernel_selection() {
  local requested="${SB_DEPLOY_PROXY_KERNEL:-}"
  [[ -n "$requested" ]] || return 0
  if [[ -f "$CONF_FILE" ]]; then
    log "提示：本机已完成部署，代理内核由管理配置决定，SB_DEPLOY_PROXY_KERNEL 已忽略"
    return 0
  fi
  case "$requested" in
    singbox|mihomo) PROXY_KERNEL="$requested" ;;
    *) die "SB_DEPLOY_PROXY_KERNEL 只能是 singbox 或 mihomo：$requested" ;;
  esac
  log "提示：本次部署使用测试用的内核选择：$(kernel_display_name)"
}

# 确定本次安装或更新按哪个内核进行。
# 已部署的机器一律以管理配置里的声明为准；只有尚未部署的机器才看测试用的选择。
# 必须在这里显式确定，不能依赖文件级默认值：deploy_environment 内那次
# load_runtime_config 发生在子进程里，父进程拿不到结果，而写单元文件、
# 校验配置、挑选下载资产都发生在父进程。真机上验到的后果是——
# 一台 mihomo 机器执行「自动修复缺失内容」会去下载并部署 sing-box。
resolve_deployment_kernel() {
  if [[ -r "$CONF_FILE" ]]; then
    load_runtime_config
    return 0
  fi
  apply_test_only_kernel_selection || return 1
}

install_environment() {
  local choice answer config_path state_path
  resolve_deployment_kernel || return 1
  show_environment_diagnostics
  case "$ENVIRONMENT_CLASS" in
    managed_complete)
      echo "安装完整，无需重复部署。你可以返回上一级检查更新或运行「服务与配置检查」。"
      return 0
      ;;
    fresh)
      read -r -p '确认开始全新部署？[y/N]：' answer
      [[ "$answer" =~ ^[Yy]$ ]] || { echo "已取消部署。"; return 0; }
      install_prerequisites || return 1
      fetch_latest_releases false || return 1
      deploy_environment true
      ;;
    managed_partial|managed_damaged)
      cat <<'EOF'

处理方式：
  1. 自动修复缺失内容（保留现有节点配置，推荐）
  2. 备份后重新安装（会覆盖现有节点配置）
  0. 返回上一级
EOF
      read_menu_choice '请选择：' '0,1,2' '' '请输入 1、2 或 0' || return 1
      choice="$PROMPT_VALUE"
      case "$choice" in
        1)
          config_path="$(system_path /etc/sing-box/config.json)"
          state_path="$(system_path /etc/sing-box/managed-users.json)"
          [[ -f "$config_path" ]] || die "sing-box 配置缺失，无法安全自动修复；请从备份恢复或选择全新部署"
          if [[ ! -f "$state_path" ]] && jq -e '
            any(.inbounds[]?; (.tag // "") | test("^(st-|ss-|anytls-)"))
          ' "$config_path" >/dev/null 2>&1; then
            die "检测到已有用户连接配置，但用户资料缺失。为避免用户无法连接，脚本不会自动修改；请先恢复备份或选择重新安装"
          fi
          install_prerequisites || return 1
          fetch_latest_releases false || return 1
          # 修复流程不得把测试通道静默替换为正式版；sing-box 由版本管理单独更新。
          if [[ "$(current_singbox_channel)" == preview ]]; then
            LATEST_KERNEL_VERSION="$(installed_singbox_version)"
          fi
          deploy_environment false
          ;;
        2)
          read -r -p '现有节点配置将被覆盖，确认重新安装？[y/N]：' answer
          [[ "$answer" =~ ^[Yy]$ ]] || return 0
          install_prerequisites || return 1
          fetch_latest_releases false || return 1
          deploy_environment true
          ;;
        0) return 0;;
      esac
      ;;
    external)
      cat <<'EOF'

检测到这台服务器已有其他方式安装的 sing-box。脚本默认不会覆盖现有配置。
处理方式：
  1. 保留现有配置并加入本脚本管理（推荐）
  2. 备份后重新安装（会覆盖现有配置）
  0. 返回上一级
EOF
      read_menu_choice '请选择：' '0,1,2' '' '请输入 1、2 或 0' || return 1
      choice="$PROMPT_VALUE"
      case "$choice" in
        1)
          read -r -p '将保留现有节点，并安装用户管理和流量统计功能。确认继续？[y/N]：' answer
          [[ "$answer" =~ ^[Yy]$ ]] || return 0
          install_prerequisites || return 1
          takeover_existing_environment
          ;;
        2)
          read -r -p '现有节点配置将被覆盖，确认重新安装？[y/N]：' answer
          [[ "$answer" =~ ^[Yy]$ ]] || return 0
          install_prerequisites || return 1
          fetch_latest_releases false || return 1
          deploy_environment true
          ;;
        0) return 0;;
      esac
      ;;
  esac
}

managed_uninstall_paths() {
  {
    all_kernel_deployment_paths
    cat <<'EOF'
/etc/sb-user-manager.conf
/etc/systemd/system/nfuse.service
/etc/systemd/system/sb-user-expiry.service
/etc/systemd/system/sb-user-expiry.timer
/etc/systemd/system/multi-user.target.wants/nfuse.service
/etc/systemd/system/timers.target.wants/sb-user-expiry.timer
/var/lib/nfuse
/var/lib/sb-user-manager
/usr/local/sbin/sb-user-manager
/usr/local/bin/sbm
/usr/local/bin/nfuse
/run/nfuse.sock
EOF
  } | awk 'NF && !seen[$0]++'
}

remove_managed_uninstall_paths() {
  local path target
  while IFS= read -r path; do
    target="$(system_path "$path")"
    [[ -e "$target" || -L "$target" ]] || continue
    if [[ -d "$target" && ! -L "$target" ]]; then
      rm -rf -- "$target" || return 1
    else
      rm -f -- "$target" || return 1
    fi
  done < <(managed_uninstall_paths)
}

verify_managed_uninstall_paths_removed() {
  local path target
  while IFS= read -r path; do
    target="$(system_path "$path")"
    [[ ! -e "$target" && ! -L "$target" ]] || return 1
  done < <(managed_uninstall_paths)
}

stop_managed_services_for_uninstall() {
  local unit state
  [[ -z "${SB_SYSTEM_ROOT:-}" ]] || return 0
  # 两个内核的单元都停：不存在的单元 stop 会失败，is-active 报 inactive，
  # 后面的判断照常通过；漏停一个还在跑的内核才是真的问题。
  for unit in sb-user-expiry.timer sing-box.service mihomo.service nfuse.service; do
    systemctl stop "$unit" 2>/dev/null || true
    state="$(systemctl is-active "$unit" 2>/dev/null || true)"
    [[ "$state" != active && "$state" != activating ]] || return 1
    systemctl disable "$unit" >/dev/null 2>&1 || true
  done
}

restore_managed_service_enablement() {
  local kernel_service
  [[ -z "${SB_SYSTEM_ROOT:-}" ]] || return 0
  kernel_service="$(kernel_service_name)" || return 1
  systemctl enable nfuse.service "${kernel_service}.service" sb-user-expiry.timer >/dev/null || return 1
}

ensure_safe_ssh_for_complete_uninstall() {
  local label
  ssh_connection_uses_local_kernel || return 0
  label="$(kernel_display_name)" || return 1
  printf '检测到当前 SSH 连接正通过这台服务器自己的 %s 节点。\n' "$label"
  printf '完整卸载需要停止 %s，继续会立即中断当前连接。\n' "$label"
  cat <<'EOF'
为避免连接中断，本次卸载已经停止，服务器数据尚未修改。
请在当前 SSH 软件或本地代理中把这台服务器的 SSH 地址设为直连，然后重新运行。
EOF
  return 1
}

cleanup_internal_material_after_uninstall() {
  local base data path name failed=false
  base="${ENVIRONMENT_BACKUP_BASE:-/root/sb-user-manager-backups}"
  data="$(migration_backup_dir)"
  if [[ -d "$base" && ! -L "$base" ]]; then
    while IFS= read -r -d '' path; do
      [[ "$path" == "$data" ]] && continue
      name="${path##*/}"
      # data 是用户主动保留的迁移备份目录；该项目备份根目录内的其余内容均为内部材料。
      [[ "$name" == data ]] && continue
      if [[ -d "$path" && ! -L "$path" ]]; then
        rm -rf -- "$path" || failed=true
      else
        rm -f -- "$path" || failed=true
      fi
    done < <(find "$base" -mindepth 1 -maxdepth 1 -print0)
    rmdir -- "$data" 2>/dev/null || true
    rmdir -- "$base" 2>/dev/null || true
  fi
  path="${DIAGNOSTIC_REPORT_DIR:-/root/sb-user-manager-diagnostics}"
  if [[ -e "$path" || -L "$path" ]]; then
    if [[ -d "$path" && ! -L "$path" ]]; then rm -rf -- "$path" || failed=true
    else rm -f -- "$path" || failed=true
    fi
  fi
  # 两个锁文件都保持在原位；删除仍被进程持有的锁会让另一进程创建新 inode 并绕过互斥。
  [[ "$failed" == false ]]
}

uninstall_managed_environment() {
  local work backup candidate="" cleanup_failed=false migration_dir
  local -a uninstall_paths=()
  local uninstall_path_count=0 path installed self
  if ! acquire_operation_lock; then
    log "错误：$OPERATION_LOCK_ERROR"
    return 1
  fi
  ensure_safe_ssh_for_complete_uninstall || { release_operation_lock; return 0; }
  [[ ! -e "$ENVIRONMENT_TRANSACTION_JOURNAL" && ! -L "$ENVIRONMENT_TRANSACTION_JOURNAL" ]] || {
    release_operation_lock
    die "检测到尚未完成的环境操作，请重新运行脚本让它先自动恢复"
  }
  installed="$(readlink -f -- /usr/local/sbin/sb-user-manager 2>/dev/null || printf '%s' /usr/local/sbin/sb-user-manager)"
  self="$(readlink -f -- "$SELF_PATH" 2>/dev/null || printf '%s' "$SELF_PATH")"
  if [[ "$self" != "$installed" && -f "$self" && ! -L "$self" &&
        -f "$installed" && ! -L "$installed" ]] && cmp -s "$self" "$installed"; then
    candidate="$self"
  fi
  while IFS= read -r path; do
    uninstall_paths[uninstall_path_count]="$path"
    ((uninstall_path_count+=1))
  done < <(managed_uninstall_paths)
  work="$(mktemp -d /tmp/sb-user-manager-uninstall.XXXXXX)" || { release_operation_lock; return 1; }
  register_temp_path "$work" || { rm -rf -- "$work"; release_operation_lock; return 1; }
  create_environment_backup || { rm -rf -- "$work"; release_operation_lock; return 1; }
  backup="$ENV_BACKUP"

  rollback_uninstall() {
    local rollback_rc="${1:-$?}" restored=true
    trap - ERR
    clear_signal_rollback
    log "完整卸载未能安全完成，正在恢复卸载前环境"
    if ! restore_environment_backup "$backup"; then
      restored=false
    elif ! restore_managed_service_enablement; then
      restored=false
    fi
    if [[ "$restored" == true ]]; then
      if [[ ! -e "$ENVIRONMENT_TRANSACTION_JOURNAL" ]] || clear_environment_transaction; then
        log "服务器已经恢复到卸载前状态"
      else
        log "严重错误：环境已恢复，但无法清除恢复记录：$ENVIRONMENT_TRANSACTION_JOURNAL"
      fi
    else
      log "严重错误：自动恢复失败，请保留完整备份并停止继续操作：$backup"
    fi
    rm -rf -- "$work"
    release_environment_lock
    release_operation_lock
    return "$rollback_rc"
  }

  if ! begin_environment_transaction "uninstall-environment" "$backup" "${uninstall_paths[@]}"; then
    rm -rf -- "$work"
    release_operation_lock
    return 1
  fi
  trap rollback_uninstall ERR
  set_signal_rollback rollback_uninstall
  run_step_or_rollback rollback_uninstall stop_managed_services_for_uninstall || return 1
  run_step_or_rollback rollback_uninstall remove_managed_uninstall_paths || return 1
  if [[ -z "${SB_SYSTEM_ROOT:-}" ]]; then
    run_step_or_rollback rollback_uninstall systemctl daemon-reload || return 1
    systemctl reset-failed >/dev/null 2>&1 || true
  fi
  run_step_or_rollback rollback_uninstall verify_managed_uninstall_paths_removed || return 1
  if ! clear_environment_transaction; then
    rollback_uninstall 1 || true
    return 1
  fi
  trap - ERR
  clear_signal_rollback
  rm -rf -- "$work"

  cleanup_internal_material_after_uninstall || cleanup_failed=true
  if [[ -n "$candidate" && ( -e "$candidate" || -L "$candidate" ) ]]; then
    rm -f -- "$candidate" || cleanup_failed=true
  fi
  migration_dir="$(migration_backup_dir)"
  printf '\n完整卸载已完成。\n'
  printf 'sing-box、Nfuse、用户数据、运行配置、管理脚本和内部回滚材料已移除。\n'
  if [[ -d "$migration_dir" ]]; then
    printf '加密迁移备份已保留在：%s\n' "$migration_dir"
  else
    printf '当前没有需要保留的加密迁移备份。\n'
  fi
  if [[ "$cleanup_failed" == true ]]; then
    printf '提示：少量非运行文件未能自动清理，不影响卸载结果；服务器上已经没有本项目服务在运行。\n'
  fi
  printf 'Debian 共用工具和无法确认归属的 root 文件没有删除。\n'
  release_operation_lock
  exit 0
}

uninstall_environment() {
  local choice
  show_environment_diagnostics
  case "$ENVIRONMENT_CLASS" in
    fresh)
      echo '没有检测到本项目部署，无需卸载。'
      return 0
      ;;
    external)
      echo '检测到的是外部或第三方环境，不属于本项目，脚本不会删除。'
      return 0
      ;;
    managed_partial|managed_damaged)
      cat <<'EOF'

当前部署不完整，无法保证迁移备份包含全部数据。
请先选择“安装或修复环境”完成修复，再执行完整卸载。
EOF
      return 0
      ;;
  esac

  cat <<'EOF'

完整卸载会停止所有节点连接，并删除：
  - sing-box、Nfuse 和到期检查服务
  - 全部用户、节点、分流、配额、流量记录、证书和运行配置
  - 管理脚本、sbm 快捷命令、内部操作备份和完整回滚备份

不会删除：
  - 用户主动创建或导入的加密迁移备份（.sbm）
  - Debian 共用工具以及无法确认归属的其他文件

如果这台服务器最初由脚本接管已有环境，卸载不会恢复成接管前的配置。

处理方式：
  1. 创建新的加密迁移备份后卸载（推荐）
  2. 不创建新备份，直接卸载
  0. 返回上一级
EOF
  read_menu_choice '请选择：' '0,1,2' '' '请输入 1、2 或 0' || return 1
  choice="$PROMPT_VALUE"
  case "$choice" in
    0)
      MENU_RETURNED=true
      return 0
      ;;
    1)
      MENU_RETURNED=false
      create_migration_backup
      if [[ -z "$CREATED_MIGRATION_BACKUP" ]]; then
        MENU_RETURNED=true
        return 0
      fi
      printf '\n迁移备份已经通过完整性检查，接下来可以安全卸载。\n'
      ;;
    2)
      printf '\n你选择了不创建新备份。现有迁移备份仍会保留，但当前未备份的数据将永久删除。\n'
      ;;
  esac
  read_menu_choice '确认停止全部节点并完整卸载？输入 1 继续，输入 0 返回：' \
    '0,1' '' '请输入 1 或 0' || return 1
  if [[ "$PROMPT_VALUE" == 0 ]]; then
    echo '已取消卸载，服务器没有修改。'
    MENU_RETURNED=true
    return 0
  fi
  uninstall_managed_environment
}

# >>> check_updates
check_updates() {
  local current_kernel current_nfuse current_manager current_channel kernel_latest_label answer needs_update=false update_manager=false manager_latest_label kernel_label
  environment_is_deployed || { echo "检测结果：尚未安装，请先选择「安装或修复环境」。"; return 0; }
  load_runtime_config
  need_cmd curl; need_cmd jq
  if ! acquire_operation_lock; then
    echo "错误：$OPERATION_LOCK_ERROR"
    return 1
  fi
  echo "正在查询稳定版更新…"
  fetch_latest_releases true || { release_operation_lock; return 1; }
  kernel_label="$(kernel_display_name)" || { release_operation_lock; return 1; }
  current_kernel="$(installed_kernel_version)"; current_nfuse="$(installed_nfuse_version)"
  current_manager="$(installed_manager_version)"
  # 版本通道是 sing-box 独有的概念，其它内核没有对应物。
  if [[ "$PROXY_KERNEL" == singbox ]]; then current_channel="$(current_singbox_channel)"; else current_channel=stable; fi
  kernel_latest_label="$LATEST_KERNEL_VERSION"
  if [[ "$current_channel" == preview ]]; then
    if fetch_singbox_channel_releases; then
      kernel_latest_label="${LATEST_PREVIEW_SINGBOX_VERSION}（测试通道）"
    else
      kernel_latest_label="未知（请到版本管理检查）"
    fi
    # 通用更新流程不得把测试通道静默替换为正式版；sing-box 由版本管理单独更新。
    LATEST_KERNEL_VERSION="$current_kernel"
  fi
  manager_latest_label="$LATEST_MANAGER_VERSION"
  if version_gt "$LATEST_MANAGER_VERSION" "${current_manager:-0}"; then
    needs_update=true
    if version_gt "$LATEST_MANAGER_VERSION" "$SCRIPT_VERSION"; then update_manager=true; fi
  elif version_gt "$SCRIPT_VERSION" "${current_manager:-0}"; then
    needs_update=true
    manager_latest_label="${SCRIPT_VERSION}（当前脚本）"
  elif [[ "$current_manager" == "$SCRIPT_VERSION" ]] && { [[ ! -x /usr/local/sbin/sb-user-manager ]] || ! cmp -s "$SELF_PATH" /usr/local/sbin/sb-user-manager; }; then
    needs_update=true
    manager_latest_label="${SCRIPT_VERSION}（本地内容修订）"
  fi
  if [[ "$current_channel" == stable ]]; then
    [[ "$current_kernel" == "$LATEST_KERNEL_VERSION" ]] || needs_update=true
  fi
  [[ "$current_nfuse" == "$LATEST_NFUSE_VERSION" ]] || needs_update=true
  printf '\n%-18s %-18s %-18s\n' '组件' '当前版本' '最新稳定版'
  printf '%-18s %-18s %-18s\n' '------------------' '------------------' '------------------'
  printf '%-18s %-18s %-18s\n' "$kernel_label" "${current_kernel:-未知}" "$kernel_latest_label"
  printf '%-18s %-18s %-18s\n' 'Nfuse' "${current_nfuse:-未知}" "$LATEST_NFUSE_VERSION"
  printf '%-18s %-18s %-18s\n' '管理脚本' "${current_manager:-未知}" "$manager_latest_label"
  if [[ "$current_channel" == preview ]]; then
    echo "提示：sing-box 测试通道请在「sing-box 版本管理 → 更新当前通道」中更新。"
  fi
  if [[ "$needs_update" != true ]]; then
    if [[ "$current_channel" == preview ]]; then printf '\n其余组件已经是最新版本。\n'
    else printf '\n当前环境已经是最新版本。\n'
    fi
    release_operation_lock
    return 0
  fi
  read -r -p $'\n检测到可更新内容，是否现在更新？[y/N]：' answer || {
    release_operation_lock
    return 1
  }
  if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    echo "已取消更新。"
    release_operation_lock
    return 0
  fi
  # deploy_environment 识别当前进程已持锁，不会重开 fd 9；查询、确认与部署保持同一互斥区间。
  # deploy_environment 返回前会释放操作锁；此行之后不得添加需要互斥保护的逻辑。
  if ! deploy_environment false "$update_manager"; then
    release_operation_lock
    return 1
  fi
  release_operation_lock
  if [[ "$update_manager" == true ]]; then
    printf '\n管理脚本已更新到 %s，正在切换到新进程。\n' "$LATEST_MANAGER_VERSION"
    exec /usr/local/sbin/sb-user-manager
  fi
}
# <<< check_updates
