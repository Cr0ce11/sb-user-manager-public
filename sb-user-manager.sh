#!/usr/bin/env bash
# jq 过滤器通过单引号传给 atomic_state_update，$name 等由 jq --arg 注入，禁止 Bash 展开。
# shellcheck disable=SC2016
# ============================================================
# sb-user-manager 单文件交互式安装与节点管理器
# ============================================================

set -Eeuo pipefail
umask 077

PROGRAM="sb-user-manager"
CONF_FILE="${SB_USER_CONF:-/etc/sb-user-manager.conf}"
SELF_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
SCRIPT_VERSION="4.23.2"
SCRIPT_EDITION_LABEL="公开版"
STATE_SCHEMA_VERSION=5
MIGRATION_FORMAT_VERSION=1
MIGRATION_BUNDLE_VERSION=1
TRANSACTION_FORMAT_VERSION=1
OPERATION_BACKUP_RETENTION="${SB_OPERATION_BACKUP_RETENTION:-10}"
ENVIRONMENT_BACKUP_RETENTION="${SB_ENVIRONMENT_BACKUP_RETENTION:-5}"
MIGRATION_REPORT_RETENTION="${SB_MIGRATION_REPORT_RETENTION:-20}"
ENVIRONMENT_TRANSACTION_JOURNAL="${SB_ENVIRONMENT_TRANSACTION_JOURNAL:-/var/lib/sb-user-manager.recovery.json}"
ENVIRONMENT_LOCK_FILE="${SB_ENVIRONMENT_LOCK_FILE:-/run/lock/sb-user-manager-environment.lock}"
ENVIRONMENT_BACKUP_PERMISSION_MARKER="${SB_ENVIRONMENT_BACKUP_PERMISSION_MARKER:-/var/lib/sb-user-manager/environment-backup-permissions-v1}"
BACKUP_RETENTION_MIGRATION_MARKER="${SB_BACKUP_RETENTION_MIGRATION_MARKER:-/var/lib/sb-user-manager/backup-retention-v1}"
SHARED_PRESET_RUNTIME_MARKER="${SB_SHARED_PRESET_RUNTIME_MARKER:-/var/lib/sb-user-manager/shared-preset-runtime-v2}"
MANAGER_REPOSITORY="DTB201/sb-user-manager-public"
MANAGER_ASSET="sb-user-manager.sh"
# 公开版使用固定仓库和资产名匿名检查自身更新。
: "$MANAGER_REPOSITORY" "$MANAGER_ASSET"
SINGBOX_REPOSITORY="SagerNet/sing-box"
SINGBOX_ARCH="linux-amd64"
SINGBOX_CHANNEL_STATE="${SB_SINGBOX_CHANNEL_STATE:-/var/lib/sb-user-manager/singbox-channel.json}"
SINGBOX_VERSION_STORE="${SB_SINGBOX_VERSION_STORE:-/var/lib/sb-user-manager/singbox-versions}"
DEPLOYED_VERSIONS_FILE="${SB_DEPLOYED_VERSIONS_FILE:-/var/lib/sb-user-manager/versions}"
DIAGNOSTIC_REPORT_DIR="${SB_DIAGNOSTIC_REPORT_DIR:-/root/sb-user-manager-diagnostics}"
DEFAULT_SS2022_SHADOWTLS_SNI="publicassets.cdn-apple.com"
DEFAULT_ANYTLS_SNI="weKbP9SVYU.download.windowsupdate.com"

manager_file_uid() {
  stat -c '%u' -- "$1" 2>/dev/null || stat -f '%u' "$1" 2>/dev/null
}

manager_file_mode() {
  stat -c '%a' -- "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

runtime_config_expected_uid() {
  # 单元测试会以普通用户加载隔离配置；真实运行始终只信任 root 配置。
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true && "$EUID" -ne 0 ]]; then
    printf '%s\n' "$EUID"
  else
    printf '0\n'
  fi
}

validate_runtime_config_file() {
  local owner mode expected_owner
  [[ ! -L "$CONF_FILE" ]] || die "管理配置不能是符号链接：$CONF_FILE"
  [[ -f "$CONF_FILE" ]] || die "管理配置不是普通文件：$CONF_FILE"
  [[ -r "$CONF_FILE" ]] || die "尚未完成安装，或脚本无法读取配置。请先选择「安装或修复环境」。详细位置：$CONF_FILE"
  owner="$(manager_file_uid "$CONF_FILE")" || die "无法确认管理配置的所有者：$CONF_FILE"
  expected_owner="$(runtime_config_expected_uid)"
  [[ "$owner" == "$expected_owner" ]] || die "配置文件必须由 root 拥有：$CONF_FILE"
  mode="$(manager_file_mode "$CONF_FILE")" || die "无法确认管理配置的权限：$CONF_FILE"
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || die "无法识别管理配置的权限：$CONF_FILE"
  (( (8#$mode & 077) == 0 )) ||
    die "配置文件不能允许组或其他用户访问：${CONF_FILE}（当前权限 ${mode}）"
}

parse_runtime_config() {
  local line key raw value seen='|' line_number=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    ((line_number+=1))
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      raw="${BASH_REMATCH[2]}"
    else
      die "管理配置第 ${line_number} 行格式无效，只能使用「配置项=值」：$CONF_FILE"
    fi
    case "$key" in
      HANDSHAKE_PORT|SHADOWTLS_STRICT_MODE|SS2022_SHADOWTLS_SNI|ANYTLS_SNI|\
      SINGBOX_BIN|SINGBOX_CONFIG|SINGBOX_SERVICE|NFUSE_BIN|NFUSE_SOCKET|NFUSE_DB|\
      STATE_FILE|LOCK_FILE|BACKUP_DIR|TRANSACTION_DIR|TRANSACTION_JOURNAL|\
      CLIENT_SERVER_PORT_OVERRIDE|PUBLIC_SERVER_OVERRIDE|GITHUB_TOKEN|\
      SS_METHOD|HANDSHAKE_SERVER|TLS_SERVER_NAME|PORT_MIN|PORT_MAX) ;;
      *) die "管理配置第 ${line_number} 行包含未知配置项：$key" ;;
    esac
    [[ "$seen" != *"|${key}|"* ]] || die "管理配置第 ${line_number} 行重复设置：$key"
    seen+="${key}|"
    if [[ "$raw" == \"* ]]; then
      [[ ${#raw} -ge 2 && "${raw: -1}" == '"' ]] ||
        die "管理配置第 ${line_number} 行的双引号不完整：$key"
      value="${raw:1:${#raw}-2}"
    else
      [[ "$raw" =~ ^[A-Za-z0-9_./:@+-]*$ ]] ||
        die "管理配置第 ${line_number} 行包含不支持的写法：$key"
      value="$raw"
    fi
    [[ "$value" != *'$'* && "$value" != *'`'* ]] ||
      die "管理配置第 ${line_number} 行不能包含 shell 命令写法：$key"
    # 兼容旧私有版配置，但不把历史令牌载入进程或用于网络请求。
    [[ "$key" != GITHUB_TOKEN ]] || continue
    printf -v "$key" '%s' "$value"
  done < "$CONF_FILE"
}

load_runtime_config() {
  validate_runtime_config_file
  # 每次加载都先恢复内置默认，避免回滚到旧配置（尚无 SNI 字段）时沿用进程内的新值。
  SS2022_SHADOWTLS_SNI="$DEFAULT_SS2022_SHADOWTLS_SNI"
  ANYTLS_SNI="$DEFAULT_ANYTLS_SNI"
  unset GITHUB_TOKEN SB_GITHUB_TOKEN
  # 配置按白名单解析，不能作为 root shell 代码执行。
  parse_runtime_config
  : "${SINGBOX_BIN:=/usr/local/bin/sing-box}"
  : "${SINGBOX_CONFIG:=/etc/sing-box/config.json}"
  : "${SINGBOX_SERVICE:=sing-box}"
  : "${NFUSE_BIN:=/usr/local/bin/nfuse}"
  : "${NFUSE_SOCKET:=/run/nfuse.sock}"
  : "${NFUSE_DB:=/var/lib/nfuse/nfuse.db}"
  : "${STATE_FILE:=/etc/sing-box/managed-users.json}"
  : "${LOCK_FILE:=/run/lock/sb-user-manager.lock}"
  : "${BACKUP_DIR:=/etc/sing-box/backups}"
  : "${TRANSACTION_DIR:=/var/lib/sb-user-manager/transactions}"
  : "${TRANSACTION_JOURNAL:=$TRANSACTION_DIR/active.json}"
  # 用户入站端口固定在管理器专用范围；不沿用旧版配置中的宽范围。
  PORT_MIN=20001
  PORT_MAX=30000
  : "${HANDSHAKE_PORT:=443}"
  : "${SHADOWTLS_STRICT_MODE:=true}"
  : "${SS2022_SHADOWTLS_SNI:=$DEFAULT_SS2022_SHADOWTLS_SNI}"
  : "${ANYTLS_SNI:=$DEFAULT_ANYTLS_SNI}"
  : "${CLIENT_SERVER_PORT_OVERRIDE:=}"
  : "${PUBLIC_SERVER_OVERRIDE:=${SB_PUBLIC_SERVER:-}}"
}

die() {
  echo "错误：$*" >&2
  exit 1
}

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

# 终端界面只使用少量语义色；非交互输出、哑终端和 NO_COLOR 环境保持纯文本。
UI_RESET="" UI_BOLD="" UI_DIM="" UI_GREEN="" UI_YELLOW="" UI_RED="" UI_CYAN=""
init_terminal_ui() {
  if [[ -t 1 && "${TERM:-dumb}" != dumb && -z "${NO_COLOR:-}" ]]; then
    UI_RESET=$'\033[0m'
    UI_BOLD=$'\033[1m'
    UI_DIM=$'\033[2m'
    UI_GREEN=$'\033[32m'
    UI_YELLOW=$'\033[33m'
    UI_RED=$'\033[31m'
    UI_CYAN=$'\033[36m'
  fi
}

terminal_width() {
  local width
  width="${COLUMNS:-}"
  [[ "$width" =~ ^[0-9]+$ ]] || width="$(tput cols 2>/dev/null || true)"
  [[ "$width" =~ ^[0-9]+$ ]] || width=80
  ((width >= 40)) || width=40
  printf '%s\n' "$width"
}

# Bash 的 printf 宽度按字符数而非终端列数计算，中文双栏菜单会因此错位。
# 菜单文案只包含普通 ASCII 与中日韩字符，按后者占两列计算即可保持常见终端对齐。
ui_text_width() {
  local text="$1" char width=0 i
  for ((i=0; i<${#text}; i++)); do
    char="${text:i:1}"
    if [[ "$char" == [[:ascii:]] ]]; then
      ((width+=1))
    else
      ((width+=2))
    fi
  done
  printf '%s\n' "$width"
}

ui_padded_item() {
  local text="$1" target="$2" width padding
  width="$(ui_text_width "$text")"
  padding=$((target - width))
  ((padding < 1)) && padding=1
  printf '  %s%*s' "$text" "$padding" ''
}

ui_rule() {
  local width rule
  width="$(terminal_width)"
  ((width > 72)) && width=72
  printf -v rule '%*s' "$width" ''
  printf '%s\n' "${UI_DIM}${rule// /─}${UI_RESET}"
}

ui_header() {
  local title="$1" context="${2:-}"
  printf '%s%s%s' "$UI_BOLD" "$title" "$UI_RESET"
  [[ -z "$context" ]] || printf '  %s%s%s' "$UI_DIM" "$context" "$UI_RESET"
  printf '\n'
  ui_rule
}

ui_section() {
  printf '%s%s%s\n' "$UI_CYAN" "$1" "$UI_RESET"
}

UI_MENU_ACTIONS=()
UI_MENU_COUNT=0
UI_MENU_ACTION=""

ui_menu_begin() {
  UI_MENU_ACTIONS=()
  UI_MENU_COUNT=0
  UI_MENU_ACTION=""
}

# 每项由“内部动作 + 显示文案”组成。编号只取决于当前菜单内的加入顺序，调整或增删菜单项时无需手工改号。
ui_menu_items() {
  local -a items=()
  local width i action label column_width=32
  while (($# >= 2)); do
    action="$1"
    label="$2"
    shift 2
    ((UI_MENU_COUNT+=1))
    UI_MENU_ACTIONS[UI_MENU_COUNT]="$action"
    printf -v label '%d  %s' "$UI_MENU_COUNT" "$label"
    items+=("$label")
  done
  width="$(terminal_width)"
  if ((width >= 72)); then
    for ((i=0; i<${#items[@]}; i+=2)); do
      if ((i + 1 < ${#items[@]})); then
        ui_padded_item "${items[$i]}" "$column_width"
        printf '  %s\n' "${items[$((i + 1))]}"
      else
        printf '  %s\n' "${items[$i]}"
      fi
    done
  else
    for i in "${!items[@]}"; do printf '  %s\n' "${items[$i]}"; done
  fi
}

ui_back_item() {
  printf '%s  0  %s%s\n' "$UI_DIM" "$1" "$UI_RESET"
  ui_rule
}

ui_menu_select() {
  local choice
  while true; do
    read -r -p '请选择：' choice || return 1
    [[ "$choice" =~ ^[0-9]+$ ]] || { ui_error "请输入 0-$UI_MENU_COUNT 之间的编号"; continue; }
    choice=$((10#$choice))
    if ((choice == 0)); then UI_MENU_ACTION=back; return 0; fi
    if ((choice >= 1 && choice <= UI_MENU_COUNT)); then
      UI_MENU_ACTION="${UI_MENU_ACTIONS[$choice]}"
      return 0
    fi
    ui_error "请输入 0-$UI_MENU_COUNT 之间的编号"
  done
}

ui_success() { printf '%s✓ %s%s\n' "$UI_GREEN" "$*" "$UI_RESET"; }
ui_warning() { printf '%s! %s%s\n' "$UI_YELLOW" "$*" "$UI_RESET"; }
ui_error() { printf '%s× %s%s\n' "$UI_RED" "$*" "$UI_RESET"; }

RUNTIME_TRAP_PID=""
RUNTIME_TRAP_SUBSHELL=""
ACTIVE_SIGNAL_ROLLBACK=""
ACTIVE_TRANSACTION_STAMP=""
ACTIVE_TRANSACTION_OPERATION=""
ACTIVE_TRANSACTION_DEPTH=0
declare -a RUNTIME_TEMP_PATHS=()
RUNTIME_TEMP_PATH_COUNT=0

is_managed_temp_path() {
  local path="$1" name="${1##*/}"
  [[ "$path" == /tmp/sb-* ]] ||
    [[ "$name" =~ ^\.(managed-users|migration-config|migration-state|state-restore|restore-config|restore-state|restore-previous-state|restore-manager-config|sb-user-manager\.conf|sb-user-manager\.launch|atomic-install|config|normalized|takeover-normalized|takeover-config)\. ]] ||
    [[ "$name" =~ ^\.(nfuse-snapshot|transaction)\. ]] ||
    [[ "$name" =~ ^\.singbox-channel\. ]] ||
    [[ "$name" =~ ^\.shared-preset-runtime\. ]] ||
    [[ "$name" =~ ^\.controller-state\. ]] ||
    [[ "$name" =~ ^\.controller-landing\. ]] ||
    [[ "$name" =~ ^\.landing-(credentials|manifest)\. ]] ||
    [[ "$name" =~ ^\.landing-bootstrap\. ]] ||
    [[ "$name" =~ ^\.(landing-apply|landing-receipt)\. ]] ||
    [[ "$name" =~ ^\.landing-channel\. ]] ||
    [[ -n "${STATE_FILE:-}" && "$path" == "${STATE_FILE}.tmp" ]] ||
    [[ "$name" == sb-user-data-*.sbm.tmp ]]
}

register_temp_path() {
  local path="$1"
  [[ -n "$path" ]] || die "拒绝登记空临时路径"
  is_managed_temp_path "$path" || die "拒绝登记不受管临时路径：$path"
  RUNTIME_TEMP_PATHS[RUNTIME_TEMP_PATH_COUNT]="$path"
  ((RUNTIME_TEMP_PATH_COUNT+=1))
}

cleanup_runtime_temp_paths() {
  local i path
  [[ -z "$RUNTIME_TRAP_PID" || "${BASHPID:-$$}" == "$RUNTIME_TRAP_PID" ]] || return 0
  [[ -z "$RUNTIME_TRAP_SUBSHELL" || "$BASH_SUBSHELL" == "$RUNTIME_TRAP_SUBSHELL" ]] || return 0
  for ((i=RUNTIME_TEMP_PATH_COUNT-1; i>=0; i--)); do
    path="${RUNTIME_TEMP_PATHS[$i]}"
    is_managed_temp_path "$path" || continue
    if [[ -d "$path" && ! -L "$path" ]]; then rm -rf -- "$path"
    else rm -f -- "$path"
    fi
  done
  RUNTIME_TEMP_PATHS=()
  RUNTIME_TEMP_PATH_COUNT=0
}

set_signal_rollback() {
  declare -F "$1" >/dev/null || die "中断回滚函数不存在：$1"
  ACTIVE_SIGNAL_ROLLBACK="$1"
}

clear_signal_rollback() {
  ACTIVE_SIGNAL_ROLLBACK=""
}

handle_runtime_signal() {
  local signal="$1" code="$2" callback="$ACTIVE_SIGNAL_ROLLBACK"
  # 回滚过程中忽略重复中断，避免环境快照只恢复一半。
  trap '' HUP INT QUIT TERM
  ACTIVE_SIGNAL_ROLLBACK=""
  if [[ -n "$callback" ]]; then
    log "收到 ${signal}，正在执行中断回滚"
    "$callback" "$code" || true
  fi
  cleanup_runtime_temp_paths || true
  exit "$code"
}

runtime_exit_cleanup() {
  local rc=$?
  cleanup_runtime_temp_paths || true
  return "$rc"
}

install_runtime_traps() {
  RUNTIME_TRAP_PID="${BASHPID:-$$}"
  RUNTIME_TRAP_SUBSHELL="$BASH_SUBSHELL"
  trap runtime_exit_cleanup EXIT
  trap 'handle_runtime_signal HUP 129' HUP
  trap 'handle_runtime_signal INT 130' INT
  trap 'handle_runtime_signal QUIT 131' QUIT
  trap 'handle_runtime_signal TERM 143' TERM
}

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
          (.method == "2022-blake3-aes-128-gcm" or .method == "2022-blake3-aes-256-gcm") and
          (.shadowtls_password | type == "string" and length > 0) and
          (.ss2022_password | type == "string" and length > 0) and
          (.shadowtls_sni | type == "string" and length > 0)
        elif .protocol == "anytls" then
          (.anytls_password | type == "string" and length > 0) and
          (.tls_sni | type == "string" and length > 0)
        else false end) and
      if .protocol == "ss2022" then
        (.method == .endpoints[0].method) and
        (.shadowtls_password == .endpoints[0].shadowtls_password) and
        (.ss2022_password == .endpoints[0].ss2022_password) and
        (.shadowtls_sni == .endpoints[0].shadowtls_sni)
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
          (.method == "2022-blake3-aes-128-gcm" or .method == "2022-blake3-aes-256-gcm") and
          (.shadowtls_password | type == "string" and length > 0) and
          (.ss2022_password | type == "string" and length > 0) and
          (.shadowtls_sni | type == "string" and length > 0)
        elif .protocol == "anytls" then
          (.anytls_password | type == "string" and length > 0) and
          (.tls_sni | type == "string" and length > 0)
        else false end) and
      if .protocol == "ss2022" then
        (.method == .endpoints[0].method) and
        (.shadowtls_password == .endpoints[0].shadowtls_password) and
        (.ss2022_password == .endpoints[0].ss2022_password) and
        (.shadowtls_sni == .endpoints[0].shadowtls_sni)
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
# ============================================================
# v5 入口控制器独立状态（尚未接入 v4 菜单或运行流程）
# ============================================================

CONTROLLER_STATE_SCHEMA_VERSION=1
CONTROLLER_STATE_FILE="${SB_CONTROLLER_STATE_FILE:-/var/lib/sb-user-manager/controller-state.json}"
CONTROLLER_SECRET_DIR="${SB_CONTROLLER_SECRET_DIR:-/etc/sb-user-manager/controller-secrets}"
CONTROLLER_STATE_LOCK_FILE="${SB_CONTROLLER_STATE_LOCK_FILE:-/run/lock/sb-user-manager/controller-state.lock}"

controller_state_expected_uid() {
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true && "$EUID" -ne 0 ]]; then
    printf '%s\n' "$EUID"
  else
    printf '0\n'
  fi
}

controller_private_directory_is_trusted() {
  local path="$1" owner mode expected_owner
  [[ -d "$path" && ! -L "$path" ]] || return 1
  owner="$(manager_file_uid "$path")" || return 1
  expected_owner="$(controller_state_expected_uid)"
  [[ "$owner" == "$expected_owner" ]] || return 1
  mode="$(manager_file_mode "$path")" || return 1
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0777) == 0700 ))
}

ensure_controller_private_directory() {
  local path="$1"
  if [[ -e "$path" || -L "$path" ]]; then
    controller_private_directory_is_trusted "$path" || return 1
    chmod 700 "$path" || return 1
    return 0
  fi
  install -d -m 700 "$path" || return 1
  controller_private_directory_is_trusted "$path"
}

controller_state_file_is_trusted() {
  local path="${1:-$CONTROLLER_STATE_FILE}" owner mode expected_owner
  [[ -f "$path" && ! -L "$path" && -r "$path" ]] || return 1
  owner="$(manager_file_uid "$path")" || return 1
  expected_owner="$(controller_state_expected_uid)"
  [[ "$owner" == "$expected_owner" ]] || return 1
  mode="$(manager_file_mode "$path")" || return 1
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0777) == 0600 ))
}

controller_dns_name_is_valid() {
  local value="$1" label
  ((${#value} >= 3 && ${#value} <= 253)) || return 1
  [[ "$value" == *.* && "$value" != .* && "$value" != *. && "$value" != *..* ]] || return 1
  [[ "$value" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
  while IFS= read -r label; do
    ((${#label} >= 1 && ${#label} <= 63)) || return 1
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done < <(tr '.' '\n' <<<"$value")
}

controller_landing_address_is_valid() {
  local value="$1"
  if [[ "$value" =~ ^[0-9.]+$ ]]; then
    is_ipv4_address "$value"
  else
    controller_dns_name_is_valid "$value"
  fi
}

controller_secret_ref_is_valid() {
  local landing_id="$1" value="$2" expected
  [[ -n "$CONTROLLER_SECRET_DIR" && "$CONTROLLER_SECRET_DIR" == /* &&
     "$CONTROLLER_SECRET_DIR" != */ && "$CONTROLLER_SECRET_DIR" != *//* &&
     "$CONTROLLER_SECRET_DIR" != */../* && "$CONTROLLER_SECRET_DIR" != */.. &&
     "$CONTROLLER_SECRET_DIR" != */./* && "$CONTROLLER_SECRET_DIR" != */. ]] || return 1
  expected="$CONTROLLER_SECRET_DIR/landing-${landing_id}.json"
  [[ "$value" == "$expected" ]]
}

validate_controller_state_json() {
  local path="${1:-$CONTROLLER_STATE_FILE}" landing_id address credential_ref
  jq -e -s 'length == 1' "$path" >/dev/null || return 1
  jq -e --argjson schema "$CONTROLLER_STATE_SCHEMA_VERSION" '
    type == "object" and
    (keys | sort) == ["landings", "revision", "role", "schema_version"] and
    .schema_version == $schema and
    .role == "entry-controller" and
    (.revision | type == "number" and . == floor and . >= 0 and . <= 9007199254740991) and
    (.landings | type == "array") and
    ([.landings[].id] | length == (unique | length)) and
    all(.landings[];
      . as $landing |
      type == "object" and
      (keys | sort) == [
        "address", "applied_revision", "config_sha256", "credential_ref",
        "desired_revision", "display_name", "gateway_port", "id",
        "ssh_host_fingerprint", "ssh_port", "status"
      ] and
      (.id | type == "string" and test("^[a-z][a-z0-9-]{0,31}$")) and
      (.display_name | type == "string" and length >= 1 and length <= 64 and
        (test("[[:cntrl:]]") | not)) and
      (.address | type == "string" and length >= 1 and length <= 253) and
      (.ssh_port | type == "number" and . == floor and . >= 1 and . <= 65535) and
      (.ssh_host_fingerprint | type == "string" and test("^SHA256:[A-Za-z0-9+/]{43}$")) and
      (.gateway_port | type == "number" and . == floor and . >= 1 and . <= 65535) and
      (.status == "pending" or .status == "active" or .status == "disabled" or
       .status == "error" or .status == "emergency_override") and
      (.desired_revision | type == "number" and . == floor and . >= 0 and
        . <= 9007199254740991) and
      (.applied_revision | type == "number" and . == floor and . >= 0 and
        . <= 9007199254740991 and . <= $landing.desired_revision) and
      (.config_sha256 == null or
        (.config_sha256 | type == "string" and test("^[0-9a-f]{64}$"))) and
      (.credential_ref | type == "string" and length >= 1)
    )
  ' "$path" >/dev/null || return 1

  while IFS=$'\t' read -r landing_id address credential_ref; do
    controller_landing_address_is_valid "$address" || return 1
    controller_secret_ref_is_valid "$landing_id" "$credential_ref" || return 1
  done < <(jq -r '.landings[] | [.id, .address, .credential_ref] | @tsv' "$path")
}

validate_controller_state_file() {
  local path="${1:-$CONTROLLER_STATE_FILE}"
  controller_state_file_is_trusted "$path" || return 1
  validate_controller_state_json "$path"
}

controller_state_transition_is_valid() {
  local previous="$1" candidate="$2"
  jq -e -s '
    .[0] as $previous | .[1] as $candidate |
    ($candidate.revision >= $previous.revision) and
    (if $candidate.landings == $previous.landings then true
     else $candidate.revision > $previous.revision end) and
    all($previous.landings[];
      . as $old |
      ([ $candidate.landings[] | select(.id == $old.id) ] | first) as $new |
      $new == null or
      ($new.desired_revision >= $old.desired_revision and
       $new.applied_revision >= $old.applied_revision))
  ' "$previous" "$candidate" >/dev/null
}

prepare_controller_state_file() {
  local path="$1"
  chmod 600 "$path" || return 1
  if [[ "$EUID" -eq 0 && "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    chown root:root "$path" || return 1
  fi
  controller_state_file_is_trusted "$path" || return 1
  validate_controller_state_json "$path"
}

with_controller_state_lock() {
  local callback="$1" lock_dir rc
  shift
  lock_dir="$(dirname "$CONTROLLER_STATE_LOCK_FILE")"
  ensure_controller_private_directory "$lock_dir" || return 1
  [[ ! -L "$CONTROLLER_STATE_LOCK_FILE" ]] || return 1
  exec 7>"$CONTROLLER_STATE_LOCK_FILE" || return 1
  flock -x 7 || { exec 7>&-; return 1; }
  "$callback" "$@" && rc=0 || rc=$?
  flock -u 7 2>/dev/null || true
  exec 7>&-
  return "$rc"
}

init_controller_state_unlocked() {
  local state_dir tmp
  state_dir="$(dirname "$CONTROLLER_STATE_FILE")"
  ensure_controller_private_directory "$state_dir" || return 1
  ensure_controller_private_directory "$CONTROLLER_SECRET_DIR" || return 1
  if [[ -e "$CONTROLLER_STATE_FILE" || -L "$CONTROLLER_STATE_FILE" ]]; then
    validate_controller_state_file "$CONTROLLER_STATE_FILE"
    return
  fi
  tmp="$(mktemp "$state_dir/.controller-state.XXXXXX")" || return 1
  register_temp_path "$tmp" || { rm -f -- "$tmp"; return 1; }
  if ! printf '{"schema_version":%d,"role":"entry-controller","revision":0,"landings":[]}\n' \
      "$CONTROLLER_STATE_SCHEMA_VERSION" > "$tmp" ||
     ! prepare_controller_state_file "$tmp" ||
     ! mv -- "$tmp" "$CONTROLLER_STATE_FILE"; then
    rm -f -- "$tmp"
    return 1
  fi
  validate_controller_state_file "$CONTROLLER_STATE_FILE"
}

init_controller_state() {
  with_controller_state_lock init_controller_state_unlocked
}

atomic_controller_state_update_unlocked() {
  local filter="$1" state_dir tmp
  shift
  validate_controller_state_file "$CONTROLLER_STATE_FILE" || return 1
  state_dir="$(dirname "$CONTROLLER_STATE_FILE")"
  ensure_controller_private_directory "$state_dir" || return 1
  tmp="$(mktemp "$state_dir/.controller-state.XXXXXX")" || return 1
  register_temp_path "$tmp" || { rm -f -- "$tmp"; return 1; }
  if ! jq "$@" "$filter" "$CONTROLLER_STATE_FILE" > "$tmp" ||
     ! prepare_controller_state_file "$tmp" ||
     ! controller_state_transition_is_valid "$CONTROLLER_STATE_FILE" "$tmp" ||
     ! mv -- "$tmp" "$CONTROLLER_STATE_FILE"; then
    rm -f -- "$tmp"
    return 1
  fi
  validate_controller_state_file "$CONTROLLER_STATE_FILE"
}

atomic_controller_state_update() {
  local filter="$1"
  shift
  with_controller_state_lock atomic_controller_state_update_unlocked "$filter" "$@"
}
# ============================================================
# v5 入口控制器角色门禁（尚未接入菜单或运行流程）
# ============================================================
# 后续交互层只读取这些稳定结果；详情只包含固定状态或依赖名称。
# shellcheck disable=SC2034

CONTROLLER_ROLE_LAST_STATUS=not_checked
CONTROLLER_ROLE_LAST_DETAIL=""
CONTROLLER_ROLE_APT_LOCK_TIMEOUT=60
CONTROLLER_ROLE_APT_ACQUIRE_TIMEOUT=30
CONTROLLER_ROLE_APT_RETRIES=3
if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]]; then
  CONTROLLER_ROLE_OS_RELEASE_FILE="${SB_CONTROLLER_ROLE_OS_RELEASE_FILE:-/usr/lib/os-release}"
  CONTROLLER_ROLE_APT_GET_BIN="${SB_CONTROLLER_ROLE_APT_GET_BIN:-/usr/bin/apt-get}"
  CONTROLLER_ROLE_ENV_BIN="${SB_CONTROLLER_ROLE_ENV_BIN:-/usr/bin/env}"
else
  CONTROLLER_ROLE_OS_RELEASE_FILE=/usr/lib/os-release
  CONTROLLER_ROLE_APT_GET_BIN=/usr/bin/apt-get
  CONTROLLER_ROLE_ENV_BIN=/usr/bin/env
fi

controller_role_reset_result() {
  CONTROLLER_ROLE_LAST_STATUS=not_checked
  CONTROLLER_ROLE_LAST_DETAIL=""
}

controller_role_set_result() {
  # 结果由后续交互层与当前定向测试在函数返回后读取。
  # shellcheck disable=SC2034
  CONTROLLER_ROLE_LAST_STATUS="$1"
  # shellcheck disable=SC2034
  CONTROLLER_ROLE_LAST_DETAIL="${2:-}"
}

controller_role_effective_uid() {
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]]; then
    printf '%s\n' "${SB_CONTROLLER_ROLE_TEST_EUID:-0}"
  else
    printf '%s\n' "$EUID"
  fi
}

controller_role_platform_is_supported() {
  local os_release="$CONTROLLER_ROLE_OS_RELEASE_FILE" owner mode expected_owner key value
  local system machine os_id="" version_id=""
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]]; then
    if [[ -n "${SB_CONTROLLER_ROLE_TEST_UNAME_SYSTEM:-}" ]]; then
      system="$SB_CONTROLLER_ROLE_TEST_UNAME_SYSTEM"
    else
      system="$(uname -s)" || return 1
    fi
    if [[ -n "${SB_CONTROLLER_ROLE_TEST_UNAME_MACHINE:-}" ]]; then
      machine="$SB_CONTROLLER_ROLE_TEST_UNAME_MACHINE"
    else
      machine="$(uname -m)" || return 1
    fi
  else
    system="$(/usr/bin/uname -s)" || return 1
    machine="$(/usr/bin/uname -m)" || return 1
  fi
  [[ "$system" == Linux && "$machine" == x86_64 ]] || return 1
  [[ "$os_release" == /* && -f "$os_release" && ! -L "$os_release" && -r "$os_release" ]] ||
    return 1
  owner="$(manager_file_uid "$os_release")" || return 1
  mode="$(manager_file_mode "$os_release")" || return 1
  expected_owner="$(controller_state_expected_uid)" || return 1
  [[ "$owner" == "$expected_owner" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0022) == 0 )) || return 1
  while IFS='=' read -r key value; do
    case "$key" in
      ID)
        [[ -z "$os_id" ]] || return 1
        os_id="$value"
        ;;
      VERSION_ID)
        [[ -z "$version_id" ]] || return 1
        version_id="$value"
        ;;
    esac
  done < "$os_release"
  [[ "$os_id" == debian && "$version_id" == '"12"' ]]
}

controller_role_runtime_paths_are_safe() {
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    [[ "$CONTROLLER_STATE_FILE" == /var/lib/sb-user-manager/controller-state.json &&
       "$CONTROLLER_SECRET_DIR" == /etc/sb-user-manager/controller-secrets &&
       "$CONTROLLER_STATE_LOCK_FILE" == /run/lock/sb-user-manager/controller-state.lock &&
       "$CONTROLLER_ROLE_OS_RELEASE_FILE" == /usr/lib/os-release ]]
  else
    [[ "$CONTROLLER_STATE_FILE" == /* && "$CONTROLLER_SECRET_DIR" == /* &&
       "$CONTROLLER_STATE_LOCK_FILE" == /* && "$CONTROLLER_ROLE_OS_RELEASE_FILE" == /* ]]
  fi
}

controller_role_required_dependencies() {
  printf '%s\n' \
    readlink stat uname awk base64 cat chmod chown date dirname flock grep install jq \
    mktemp mv openssl python3 rm rmdir sha256sum sort ssh ssh-keygen ssh-keyscan \
    sync timeout tr wc
}

controller_role_dependency_expected_path() {
  local name="$1" dependency_root="${SB_CONTROLLER_ROLE_DEPENDENCY_DIR:-}"
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true && -n "$dependency_root" ]]; then
    [[ "$dependency_root" == /* && "$dependency_root" != / && "$dependency_root" != */ ]] ||
      return 1
    printf '%s/%s\n' "$dependency_root" "$name"
  else
    printf '/usr/bin/%s\n' "$name"
  fi
}

controller_role_dependency_path() {
  local name="$1"
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true &&
        -n "${SB_CONTROLLER_ROLE_DEPENDENCY_DIR:-}" ]]; then
    controller_role_dependency_expected_path "$name"
  else
    command -v "$name"
  fi
}

controller_role_dependency_is_safe() {
  local name="$1" path="$2" expected resolved owner mode expected_owner
  expected="$(controller_role_dependency_expected_path "$name")" || return 1
  [[ "$path" == "$expected" && -f "$path" && -x "$path" ]] || return 1
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true &&
        -n "${SB_CONTROLLER_ROLE_DEPENDENCY_DIR:-}" ]]; then
    [[ ! -L "$path" ]] || return 1
    resolved="$path"
  else
    resolved="$(/usr/bin/readlink -f -- "$path")" || return 1
    [[ "$resolved" == /* && -f "$resolved" && ! -L "$resolved" && -x "$resolved" ]] ||
      return 1
  fi
  owner="$(manager_file_uid "$resolved")" || return 1
  mode="$(manager_file_mode "$resolved")" || return 1
  expected_owner="$(controller_state_expected_uid)" || return 1
  [[ "$owner" == "$expected_owner" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0022) == 0 ))
}

controller_role_dependencies_are_ready() {
  local name path
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true &&
        -n "${SB_CONTROLLER_ROLE_DEPENDENCY_DIR:-}" ]] &&
     [[ "$SB_CONTROLLER_ROLE_DEPENDENCY_DIR" != /* ||
        "$SB_CONTROLLER_ROLE_DEPENDENCY_DIR" == / ||
        "$SB_CONTROLLER_ROLE_DEPENDENCY_DIR" == */ ]]; then
    controller_role_set_result unsafe_runtime dependency_root
    return 1
  fi
  while IFS= read -r name; do
    path="$(controller_role_dependency_path "$name")" || {
      controller_role_set_result missing_dependency "$name"
      return 1
    }
    if [[ ! -e "$path" && ! -L "$path" ]]; then
      controller_role_set_result missing_dependency "$name"
      return 1
    fi
    if ! controller_role_dependency_is_safe "$name" "$path"; then
      controller_role_set_result unsafe_dependency "$name"
      return 1
    fi
  done < <(controller_role_required_dependencies)
}

controller_role_dependency_packages() {
  printf '%s\n' coreutils gawk grep jq openssh-client openssl python3 util-linux
}

controller_role_repair_executable_is_safe() {
  local path="$1" expected="$2" resolved owner mode expected_owner
  [[ "$path" == /* && -f "$path" && -x "$path" ]] || return 1
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]]; then
    [[ ! -L "$path" ]] || return 1
    resolved="$path"
  else
    [[ "$path" == "$expected" ]] || return 1
    resolved="$(/usr/bin/readlink -f -- "$path")" || return 1
    [[ "$resolved" == /* && -f "$resolved" && ! -L "$resolved" && -x "$resolved" ]] ||
      return 1
  fi
  owner="$(manager_file_uid "$resolved")" || return 1
  mode="$(manager_file_mode "$resolved")" || return 1
  expected_owner="$(controller_state_expected_uid)" || return 1
  [[ "$owner" == "$expected_owner" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0022) == 0 ))
}

controller_role_dependency_repair_base_preflight() {
  controller_role_reset_result
  if [[ "$(controller_role_effective_uid)" != 0 ]]; then
    controller_role_set_result not_root
    return 1
  fi
  if ! controller_role_runtime_paths_are_safe; then
    controller_role_set_result unsafe_runtime fixed_paths
    return 1
  fi
  if ! controller_role_platform_is_supported; then
    controller_role_set_result unsupported_platform
    return 1
  fi
  controller_role_set_result repair_base_ready
}

controller_role_apt_get_is_safe() {
  controller_role_repair_executable_is_safe \
    "$CONTROLLER_ROLE_APT_GET_BIN" /usr/bin/apt-get || return 1
  controller_role_repair_executable_is_safe "$CONTROLLER_ROLE_ENV_BIN" /usr/bin/env
}

controller_role_dependency_repair_preflight() {
  controller_role_dependency_repair_base_preflight || return 1
  if [[ "$CONTROLLER_ROLE_APT_LOCK_TIMEOUT" != 60 ||
        "$CONTROLLER_ROLE_APT_ACQUIRE_TIMEOUT" != 30 ||
        "$CONTROLLER_ROLE_APT_RETRIES" != 3 ]] ||
     ! controller_role_apt_get_is_safe; then
    controller_role_set_result unsafe_runtime apt_get
    return 1
  fi
  controller_role_set_result repair_ready
}

controller_role_run_apt_get() {
  local -a clean_environment=(
    -i
    'PATH=/usr/sbin:/usr/bin:/sbin:/bin'
    'LANG=C.UTF-8'
    'LC_ALL=C.UTF-8'
    'DEBIAN_FRONTEND=noninteractive'
  )
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]]; then
    clean_environment+=(
      "SB_CONTROLLER_ROLE_TEST_APT_LOG=${SB_CONTROLLER_ROLE_TEST_APT_LOG:-}"
      "SB_CONTROLLER_ROLE_TEST_APT_FAIL_STAGE=${SB_CONTROLLER_ROLE_TEST_APT_FAIL_STAGE:-}"
      "SB_CONTROLLER_ROLE_TEST_RESTORE_DEPENDENCY=${SB_CONTROLLER_ROLE_TEST_RESTORE_DEPENDENCY:-true}"
      "SB_CONTROLLER_ROLE_TEST_TRUE_BIN=${SB_CONTROLLER_ROLE_TEST_TRUE_BIN:-}"
      "SB_CONTROLLER_ROLE_TEST_MISSING_PATH=${SB_CONTROLLER_ROLE_TEST_MISSING_PATH:-}"
    )
  fi
  "$CONTROLLER_ROLE_ENV_BIN" "${clean_environment[@]}" \
    "$CONTROLLER_ROLE_APT_GET_BIN" "$@"
}

repair_entry_controller_dependencies() {
  [[ $# -eq 0 ]] || return 64
  local package post_status post_detail
  local -a packages=()
  controller_role_dependency_repair_base_preflight || return 1
  if controller_role_dependencies_are_ready; then
    controller_role_set_result dependencies_ready
    return 0
  fi
  [[ "$CONTROLLER_ROLE_LAST_STATUS" == missing_dependency ]] || return 1
  controller_role_dependency_repair_preflight || return 1

  while IFS= read -r package; do packages+=("$package"); done < <(
    controller_role_dependency_packages
  )
  if ((${#packages[@]} != 8)); then
    controller_role_set_result unsafe_runtime package_manifest
    return 1
  fi

  if ! controller_role_run_apt_get \
      -o "DPkg::Lock::Timeout=$CONTROLLER_ROLE_APT_LOCK_TIMEOUT" \
      -o "Acquire::Retries=$CONTROLLER_ROLE_APT_RETRIES" \
      -o "Acquire::http::Timeout=$CONTROLLER_ROLE_APT_ACQUIRE_TIMEOUT" \
      -o "Acquire::https::Timeout=$CONTROLLER_ROLE_APT_ACQUIRE_TIMEOUT" \
      update; then
    controller_role_set_result dependency_repair_failed apt_update
    return 1
  fi
  if ! controller_role_run_apt_get \
      -o "DPkg::Lock::Timeout=$CONTROLLER_ROLE_APT_LOCK_TIMEOUT" \
      -o "Acquire::Retries=$CONTROLLER_ROLE_APT_RETRIES" \
      -o "Acquire::http::Timeout=$CONTROLLER_ROLE_APT_ACQUIRE_TIMEOUT" \
      -o "Acquire::https::Timeout=$CONTROLLER_ROLE_APT_ACQUIRE_TIMEOUT" \
      install -y --reinstall --no-install-recommends "${packages[@]}"; then
    controller_role_set_result dependency_repair_failed apt_install
    return 1
  fi
  if ! controller_role_dependencies_are_ready; then
    post_status="$CONTROLLER_ROLE_LAST_STATUS"
    post_detail="$CONTROLLER_ROLE_LAST_DETAIL"
    [[ -n "$post_status" ]] || post_status=unknown
    if [[ -n "$post_detail" ]]; then post_status+="::$post_detail"; fi
    controller_role_set_result dependency_repair_failed "$post_status"
    return 1
  fi
  controller_role_set_result dependencies_repaired
}

controller_role_provision_target_preflight() {
  controller_role_dependency_repair_base_preflight || return 1

  if [[ -e "$CONTROLLER_STATE_FILE" || -L "$CONTROLLER_STATE_FILE" ]]; then
    if ! controller_role_existing_artifacts_are_trusted; then
      controller_role_set_result state_invalid existing_artifacts
      return 1
    fi
    controller_role_set_result provision_target_existing
    return 0
  fi

  if ! controller_role_fresh_artifacts_are_safe; then
    controller_role_set_result state_invalid partial_artifacts
    return 1
  fi
  controller_role_classify_environment_footprint
  if [[ "$CONTROLLER_ROLE_ENVIRONMENT_CLASS" != fresh ]]; then
    controller_role_set_result role_conflict "$CONTROLLER_ROLE_ENVIRONMENT_CLASS"
    return 1
  fi
  controller_role_set_result provision_target_fresh
}

provision_entry_controller_role() {
  [[ $# -eq 0 ]] || return 64
  local target_status repair_status initialization_status
  local PATH="${PATH:-}" LC_ALL="${LC_ALL:-}"
  local BASH_ENV="${BASH_ENV:-}" ENV="${ENV:-}" CDPATH="${CDPATH:-}"
  local GLOBIGNORE="${GLOBIGNORE:-}" PYTHONHOME="${PYTHONHOME:-}"
  local PYTHONPATH="${PYTHONPATH:-}" OPENSSL_CONF="${OPENSSL_CONF:-}"
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    PATH=/usr/sbin:/usr/bin:/sbin:/bin
    LC_ALL=C
    BASH_ENV='' ENV='' CDPATH='' GLOBIGNORE='' PYTHONHOME='' PYTHONPATH='' OPENSSL_CONF=''
    export PATH LC_ALL BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH OPENSSL_CONF
  fi

  controller_role_provision_target_preflight || return 1
  target_status="$CONTROLLER_ROLE_LAST_STATUS"
  case "$target_status" in
    provision_target_fresh|provision_target_existing) ;;
    *)
      controller_role_set_result provision_failed unexpected_target
      return 1
      ;;
  esac

  repair_entry_controller_dependencies "$@" || return 1
  repair_status="$CONTROLLER_ROLE_LAST_STATUS"
  case "$repair_status" in
    dependencies_ready|dependencies_repaired) ;;
    *)
      controller_role_set_result provision_failed unexpected_repair_result
      return 1
      ;;
  esac

  initialize_entry_controller_role || return 1
  initialization_status="$CONTROLLER_ROLE_LAST_STATUS"
  case "$initialization_status" in
    initialized)
      controller_role_set_result entry_role_initialized
      ;;
    already_initialized)
      if [[ "$repair_status" == dependencies_repaired ]]; then
        controller_role_set_result entry_role_repaired
      else
        controller_role_set_result entry_role_ready
      fi
      ;;
    *)
      controller_role_set_result provision_failed unexpected_initialization_result
      return 1
      ;;
  esac
}

controller_role_private_file_is_trusted() {
  local path="$1" owner mode expected_owner
  [[ -f "$path" && ! -L "$path" ]] || return 1
  owner="$(manager_file_uid "$path")" || return 1
  mode="$(manager_file_mode "$path")" || return 1
  expected_owner="$(controller_state_expected_uid)" || return 1
  [[ "$owner" == "$expected_owner" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0777) == 0600 ))
}

controller_role_directory_is_empty() (
  local directory="$1"
  local -a entries=()
  shopt -s nullglob dotglob
  entries=("$directory"/*)
  ((${#entries[@]} == 0))
)

controller_role_existing_artifacts_are_trusted() {
  local state_parent lock_parent
  state_parent="$(dirname -- "$CONTROLLER_STATE_FILE")" || return 1
  lock_parent="$(dirname -- "$CONTROLLER_STATE_LOCK_FILE")" || return 1
  validate_controller_state_file "$CONTROLLER_STATE_FILE" || return 1
  controller_private_directory_is_trusted "$state_parent" || return 1
  controller_private_directory_is_trusted "$CONTROLLER_SECRET_DIR" || return 1
  if [[ -e "$lock_parent" || -L "$lock_parent" ]]; then
    controller_private_directory_is_trusted "$lock_parent" || return 1
  fi
  if [[ -e "$CONTROLLER_STATE_LOCK_FILE" || -L "$CONTROLLER_STATE_LOCK_FILE" ]]; then
    controller_role_private_file_is_trusted "$CONTROLLER_STATE_LOCK_FILE" || return 1
  fi
}

controller_role_fresh_artifacts_are_safe() {
  local state_parent lock_parent
  state_parent="$(dirname -- "$CONTROLLER_STATE_FILE")" || return 1
  lock_parent="$(dirname -- "$CONTROLLER_STATE_LOCK_FILE")" || return 1
  [[ ! -e "$CONTROLLER_STATE_FILE" && ! -L "$CONTROLLER_STATE_FILE" ]] || return 1
  if [[ -e "$state_parent" || -L "$state_parent" ]]; then
    controller_private_directory_is_trusted "$state_parent" || return 1
  fi
  if [[ -e "$CONTROLLER_SECRET_DIR" || -L "$CONTROLLER_SECRET_DIR" ]]; then
    controller_private_directory_is_trusted "$CONTROLLER_SECRET_DIR" || return 1
    controller_role_directory_is_empty "$CONTROLLER_SECRET_DIR" || return 1
  fi
  if [[ -e "$lock_parent" || -L "$lock_parent" ]]; then
    controller_private_directory_is_trusted "$lock_parent" || return 1
  fi
  if [[ -e "$CONTROLLER_STATE_LOCK_FILE" || -L "$CONTROLLER_STATE_LOCK_FILE" ]]; then
    controller_role_private_file_is_trusted "$CONTROLLER_STATE_LOCK_FILE" || return 1
  fi
}

controller_role_classify_environment_footprint() {
  local managed=0 core=0 complete=true path rooted
  for path in /etc/sb-user-manager.conf /etc/sing-box/managed-users.json \
    /usr/local/sbin/sb-user-manager /etc/systemd/system/sb-user-expiry.timer; do
    rooted="${SB_SYSTEM_ROOT:-}$path"
    [[ -e "$rooted" || -L "$rooted" ]] && ((managed+=1))
  done
  for path in /etc/sing-box/config.json /usr/local/bin/sing-box \
    /etc/systemd/system/sing-box.service /usr/local/bin/nfuse \
    /etc/systemd/system/nfuse.service /var/lib/nfuse/nfuse.db; do
    rooted="${SB_SYSTEM_ROOT:-}$path"
    [[ -e "$rooted" || -L "$rooted" ]] && ((core+=1))
  done
  for path in /etc/sb-user-manager.conf /etc/sing-box/config.json \
    /etc/sing-box/managed-users.json /usr/local/sbin/sb-user-manager \
    /usr/local/bin/sing-box /usr/local/bin/nfuse \
    /etc/systemd/system/sing-box.service /etc/systemd/system/nfuse.service \
    /etc/systemd/system/sb-user-expiry.service /etc/systemd/system/sb-user-expiry.timer; do
    rooted="${SB_SYSTEM_ROOT:-}$path"
    [[ -e "$rooted" || -L "$rooted" ]] || complete=false
  done

  if ((managed == 0 && core == 0)); then
    CONTROLLER_ROLE_ENVIRONMENT_CLASS=fresh
  elif [[ "$complete" == true ]]; then
    CONTROLLER_ROLE_ENVIRONMENT_CLASS=managed_complete
  elif ((managed > 0)); then
    CONTROLLER_ROLE_ENVIRONMENT_CLASS=managed_partial
  else
    CONTROLLER_ROLE_ENVIRONMENT_CLASS=external
  fi
}

controller_role_preflight() {
  controller_role_reset_result
  if [[ "$(controller_role_effective_uid)" != 0 ]]; then
    controller_role_set_result not_root
    return 1
  fi
  if ! controller_role_runtime_paths_are_safe; then
    controller_role_set_result unsafe_runtime fixed_paths
    return 1
  fi
  if ! controller_role_platform_is_supported; then
    controller_role_set_result unsupported_platform
    return 1
  fi
  controller_role_dependencies_are_ready || return 1
  controller_role_set_result ready
}

initialize_entry_controller_role() {
  controller_role_preflight || return 1

  if [[ -e "$CONTROLLER_STATE_FILE" || -L "$CONTROLLER_STATE_FILE" ]]; then
    if ! controller_role_existing_artifacts_are_trusted; then
      controller_role_set_result state_invalid existing_artifacts
      return 1
    fi
    controller_role_set_result already_initialized
    return 0
  fi

  if ! controller_role_fresh_artifacts_are_safe; then
    controller_role_set_result state_invalid partial_artifacts
    return 1
  fi
  controller_role_classify_environment_footprint
  if [[ "$CONTROLLER_ROLE_ENVIRONMENT_CLASS" != fresh ]]; then
    controller_role_set_result role_conflict "$CONTROLLER_ROLE_ENVIRONMENT_CLASS"
    return 1
  fi
  if ! init_controller_state || ! controller_role_existing_artifacts_are_trusted; then
    controller_role_set_result initialization_failed
    return 1
  fi
  controller_role_set_result initialized
}
# ============================================================
# v5 入口到受管落地的固定身份传输（尚未接入菜单或安装流程）
# ============================================================

CONTROLLER_LANDING_SSH_ACCOUNT=sb-landing-agent
CONTROLLER_LANDING_KEYSCAN_TIMEOUT=5
CONTROLLER_LANDING_KEYSCAN_WALL_TIMEOUT=8
CONTROLLER_LANDING_CONNECT_TIMEOUT=5
CONTROLLER_LANDING_SESSION_TIMEOUT=45
CONTROLLER_LANDING_SESSION_KILL_AFTER=3
CONTROLLER_LANDING_RESPONSE_MAX_BYTES=512
CONTROLLER_LANDING_PACKAGE_TTL=300
CONTROLLER_LANDING_LAST_SSH_STATUS=""
if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]]; then
  CONTROLLER_LANDING_WORK_ROOT="${SB_CONTROLLER_LANDING_WORK_ROOT:-/run/sb-user-manager-controller}"
  CONTROLLER_LANDING_SSH_BIN="${SB_CONTROLLER_LANDING_SSH_BIN:-/usr/bin/ssh}"
  CONTROLLER_LANDING_SSH_KEYSCAN_BIN="${SB_CONTROLLER_LANDING_SSH_KEYSCAN_BIN:-/usr/bin/ssh-keyscan}"
  CONTROLLER_LANDING_SSH_KEYGEN_BIN="${SB_CONTROLLER_LANDING_SSH_KEYGEN_BIN:-/usr/bin/ssh-keygen}"
  CONTROLLER_LANDING_TIMEOUT_BIN="${SB_CONTROLLER_LANDING_TIMEOUT_BIN:-/usr/bin/timeout}"
  CONTROLLER_LANDING_AWK_BIN="${SB_CONTROLLER_LANDING_AWK_BIN:-/usr/bin/awk}"
  CONTROLLER_LANDING_SORT_BIN="${SB_CONTROLLER_LANDING_SORT_BIN:-/usr/bin/sort}"
else
  CONTROLLER_LANDING_WORK_ROOT=/run/sb-user-manager-controller
  CONTROLLER_LANDING_SSH_BIN=/usr/bin/ssh
  CONTROLLER_LANDING_SSH_KEYSCAN_BIN=/usr/bin/ssh-keyscan
  CONTROLLER_LANDING_SSH_KEYGEN_BIN=/usr/bin/ssh-keygen
  CONTROLLER_LANDING_TIMEOUT_BIN=/usr/bin/timeout
  CONTROLLER_LANDING_AWK_BIN=/usr/bin/awk
  CONTROLLER_LANDING_SORT_BIN=/usr/bin/sort
fi

controller_landing_transport_executable_is_safe() {
  local path="$1" expected="$2" resolved owner mode
  [[ "$path" == /* && -f "$path" && -x "$path" ]] || return 1
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    [[ "$path" == "$expected" ]] || return 1
    resolved="$(/usr/bin/readlink -f -- "$path")" || return 1
    [[ "$resolved" == /* && -f "$resolved" && ! -L "$resolved" && -x "$resolved" ]] || return 1
    owner="$(manager_file_uid "$resolved")" || return 1
    [[ "$owner" == 0 ]] || return 1
    mode="$(manager_file_mode "$resolved")" || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 0022) == 0 )) || return 1
  fi
}

controller_landing_transport_runtime_is_safe() {
  [[ "$CONTROLLER_LANDING_SSH_ACCOUNT" == sb-landing-agent &&
     "$CONTROLLER_LANDING_KEYSCAN_TIMEOUT" == 5 &&
     "$CONTROLLER_LANDING_KEYSCAN_WALL_TIMEOUT" == 8 &&
     "$CONTROLLER_LANDING_CONNECT_TIMEOUT" == 5 &&
     "$CONTROLLER_LANDING_SESSION_TIMEOUT" == 45 &&
     "$CONTROLLER_LANDING_SESSION_KILL_AFTER" == 3 &&
     "$CONTROLLER_LANDING_RESPONSE_MAX_BYTES" == 512 &&
     "$CONTROLLER_LANDING_PACKAGE_TTL" == 300 ]] || return 1
  controller_landing_transport_executable_is_safe \
    "$CONTROLLER_LANDING_SSH_BIN" /usr/bin/ssh || return 1
  controller_landing_transport_executable_is_safe \
    "$CONTROLLER_LANDING_SSH_KEYSCAN_BIN" /usr/bin/ssh-keyscan || return 1
  controller_landing_transport_executable_is_safe \
    "$CONTROLLER_LANDING_SSH_KEYGEN_BIN" /usr/bin/ssh-keygen || return 1
  controller_landing_transport_executable_is_safe \
    "$CONTROLLER_LANDING_TIMEOUT_BIN" /usr/bin/timeout || return 1
  controller_landing_transport_executable_is_safe \
    "$CONTROLLER_LANDING_AWK_BIN" /usr/bin/awk || return 1
  controller_landing_transport_executable_is_safe \
    "$CONTROLLER_LANDING_SORT_BIN" /usr/bin/sort
}

controller_landing_file_size() {
  local path="$1" size
  size="$(stat -c '%s' -- "$path" 2>/dev/null || stat -f '%z' "$path" 2>/dev/null)" || return 1
  [[ "$size" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$size"
}

controller_landing_private_file_is_trusted() {
  local path="$1" owner mode expected_owner
  [[ -f "$path" && ! -L "$path" && -r "$path" ]] || return 1
  owner="$(manager_file_uid "$path")" || return 1
  expected_owner="$(controller_state_expected_uid)"
  [[ "$owner" == "$expected_owner" ]] || return 1
  mode="$(manager_file_mode "$path")" || return 1
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0777) == 0600 ))
}

controller_landing_ssh_private_key_is_valid() {
  local path="$1" public_key
  controller_state_file_is_trusted "$path" || return 1
  public_key="$("$CONTROLLER_LANDING_SSH_KEYGEN_BIN" -y -P '' -f "$path" 2>/dev/null)" || return 1
  [[ "$public_key" == ssh-ed25519\ * && "$public_key" != *$'\n'* ]]
}

controller_landing_create_work_directory() {
  local work
  ensure_controller_private_directory "$CONTROLLER_LANDING_WORK_ROOT" || return 1
  work="$(mktemp -d "$CONTROLLER_LANDING_WORK_ROOT/.controller-landing.XXXXXX")" || return 1
  chmod 700 "$work" || { rm -rf -- "$work"; return 1; }
  controller_private_directory_is_trusted "$work" || { rm -rf -- "$work"; return 1; }
  printf '%s\n' "$work"
}

controller_landing_remove_work_directory() {
  local work="$1" name
  name="${work##*/}"
  [[ "$work" == "$CONTROLLER_LANDING_WORK_ROOT"/* &&
     "$name" =~ ^\.controller-landing\.[A-Za-z0-9]+$ ]] || return 1
  if [[ -e "$work" || -L "$work" ]]; then
    controller_private_directory_is_trusted "$work" || return 1
    rm -rf -- "$work" || return 1
  fi
  [[ ! -e "$work" && ! -L "$work" ]]
}

controller_landing_write_snapshot() {
  local landing_id="$1" output="$2"
  landing_id_is_valid "$landing_id" || return 1
  validate_controller_state_file "$CONTROLLER_STATE_FILE" || return 1
  [[ ! -e "$output" && ! -L "$output" ]] || return 1
  if ! jq -e --arg landing_id "$landing_id" '
      [.landings[] | select(.id == $landing_id)] as $matches |
      if ($matches | length) == 1 and
         ($matches[0].status == "pending" or $matches[0].status == "active" or
          $matches[0].status == "error") and
         $matches[0].desired_revision >= 1
      then $matches[0]
      else error("landing unavailable")
      end
    ' "$CONTROLLER_STATE_FILE" > "$output" 2>/dev/null; then
    rm -f -- "$output"
    return 1
  fi
  chmod 600 "$output" || { rm -f -- "$output"; return 1; }
  controller_landing_private_file_is_trusted "$output"
}

controller_landing_scan_ed25519_fingerprint() {
  local address="$1" ssh_port="$2" work="$3"
  local scan_file="$work/host-key.scan" public_key_file="$work/host-key.pub"
  local scan_size key_count fingerprint_line
  local key_bits actual_fingerprint remainder

  controller_landing_address_is_valid "$address" || return 1
  landing_port_is_valid "$ssh_port" || return 1
  controller_private_directory_is_trusted "$work" || return 1
  [[ ! -e "$scan_file" && ! -L "$scan_file" &&
     ! -e "$public_key_file" && ! -L "$public_key_file" ]] || return 1

  if ! "$CONTROLLER_LANDING_TIMEOUT_BIN" -k 1 "$CONTROLLER_LANDING_KEYSCAN_WALL_TIMEOUT" \
      "$CONTROLLER_LANDING_SSH_KEYSCAN_BIN" -T "$CONTROLLER_LANDING_KEYSCAN_TIMEOUT" \
      -p "$ssh_port" -t ed25519 -- "$address" > "$scan_file" 2>/dev/null; then
    return 1
  fi
  chmod 600 "$scan_file" || return 1
  controller_landing_private_file_is_trusted "$scan_file" || return 1
  scan_size="$(controller_landing_file_size "$scan_file")" || return 1
  ((scan_size >= 1 && scan_size <= 65536)) || return 1

  if ! "$CONTROLLER_LANDING_AWK_BIN" '
      NF == 0 { next }
      NF != 3 || $2 != "ssh-ed25519" { invalid = 1; next }
      { print $2 " " $3; count += 1 }
      END { if (invalid || count == 0) exit 1 }
    ' "$scan_file" | "$CONTROLLER_LANDING_SORT_BIN" -u > "$public_key_file"; then
    return 1
  fi
  chmod 600 "$public_key_file" || return 1
  controller_landing_private_file_is_trusted "$public_key_file" || return 1
  key_count="$("$CONTROLLER_LANDING_AWK_BIN" 'END { print NR }' "$public_key_file")" || return 1
  [[ "$key_count" == 1 ]] || return 1
  fingerprint_line="$("$CONTROLLER_LANDING_SSH_KEYGEN_BIN" -l -E sha256 \
    -f "$public_key_file" 2>/dev/null)" || return 1
  [[ -n "$fingerprint_line" && "$fingerprint_line" != *$'\n'* ]] || return 1
  read -r key_bits actual_fingerprint remainder <<< "$fingerprint_line"
  [[ "$key_bits" == 256 && "$actual_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ &&
     -n "$remainder" ]] || return 1
  printf '%s\n' "$actual_fingerprint"
}

controller_landing_prepare_known_hosts() {
  local address="$1" ssh_port="$2" expected_fingerprint="$3" host_alias="$4" work="$5"
  local public_key_file="$work/host-key.pub" known_hosts_file="$work/known-hosts"
  local actual_fingerprint

  [[ "$expected_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || return 1
  [[ "$host_alias" =~ ^sb-landing-[a-z][a-z0-9-]{0,31}$ ]] || return 1
  controller_private_directory_is_trusted "$work" || return 1
  [[ ! -e "$known_hosts_file" && ! -L "$known_hosts_file" ]] || return 1
  actual_fingerprint="$(controller_landing_scan_ed25519_fingerprint \
    "$address" "$ssh_port" "$work")" || return 1
  [[ "$actual_fingerprint" == "$expected_fingerprint" ]] || return 1

  printf '%s %s\n' "$host_alias" "$(<"$public_key_file")" > "$known_hosts_file" || return 1
  chmod 600 "$known_hosts_file" || return 1
  controller_landing_private_file_is_trusted "$known_hosts_file" || return 1
  printf '%s\n' "$known_hosts_file"
}

controller_landing_known_hosts_is_valid() {
  local path="$1" host_alias="$2" expected_fingerprint="$3"
  local line_count host key_type key_blob extra fingerprint_line
  local key_bits actual_fingerprint remainder
  controller_landing_private_file_is_trusted "$path" || return 1
  [[ "$host_alias" =~ ^sb-landing-[a-z][a-z0-9-]{0,31}$ ]] || return 1
  [[ "$expected_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || return 1
  line_count="$("$CONTROLLER_LANDING_AWK_BIN" 'END { print NR }' "$path")" || return 1
  [[ "$line_count" == 1 ]] || return 1
  read -r host key_type key_blob extra < "$path" || return 1
  [[ "$host" == "$host_alias" && "$key_type" == ssh-ed25519 &&
     "$key_blob" =~ ^[A-Za-z0-9+/]+={0,2}$ && -z "$extra" ]] || return 1
  fingerprint_line="$("$CONTROLLER_LANDING_SSH_KEYGEN_BIN" -l -E sha256 \
    -f "$path" 2>/dev/null)" || return 1
  [[ -n "$fingerprint_line" && "$fingerprint_line" != *$'\n'* ]] || return 1
  read -r key_bits actual_fingerprint remainder <<< "$fingerprint_line"
  [[ "$key_bits" == 256 && "$actual_fingerprint" == "$expected_fingerprint" &&
     -n "$remainder" ]]
}

controller_landing_response_file_is_safe() {
  local response_file="$1" ssh_status="$2" size response_status
  [[ "$ssh_status" =~ ^[0-9]+$ ]] || return 1
  controller_landing_private_file_is_trusted "$response_file" || return 1
  size="$(controller_landing_file_size "$response_file")" || return 1
  ((size >= 1 && size <= CONTROLLER_LANDING_RESPONSE_MAX_BYTES)) || return 1
  jq -e -s '
    length == 1 and
    (.[0] | type == "object") and
    (if .[0].status == "error" then
       (.[0] | keys | sort) == ["code", "status"] and
       (.[0].code | type == "string" and test("^[a-z][a-z0-9_]{0,47}$"))
     else
       (.[0].status == "applied" or .[0].status == "idempotent") and
       (.[0] | keys | sort) == ["content_sha256", "revision", "status"] and
       (.[0].revision | type == "number" and . == floor and . >= 1 and
         . <= 9007199254740991) and
       (.[0].content_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
     end)
  ' "$response_file" >/dev/null 2>&1 || return 1
  response_status="$(jq -r '.status' "$response_file")" || return 1
  if ((ssh_status == 0)); then
    [[ "$response_status" == applied || "$response_status" == idempotent ]]
  else
    [[ "$response_status" == error ]]
  fi
}

controller_landing_ssh_exchange() {
  local address="$1" ssh_port="$2" landing_id="$3" private_key="$4"
  local known_hosts="$5" expected_fingerprint="$6" package_fd="$7" response_file="$8"
  local host_alias
  local ssh_status=0
  CONTROLLER_LANDING_LAST_SSH_STATUS=""
  host_alias="sb-landing-$landing_id"
  controller_landing_address_is_valid "$address" || return 1
  landing_port_is_valid "$ssh_port" || return 1
  landing_id_is_valid "$landing_id" || return 1
  controller_landing_ssh_private_key_is_valid "$private_key" || return 1
  controller_landing_known_hosts_is_valid "$known_hosts" "$host_alias" \
    "$expected_fingerprint" || return 1
  [[ "$package_fd" =~ ^[0-9]+$ && -r "/dev/fd/$package_fd" ]] || return 1
  [[ ! -e "$response_file" && ! -L "$response_file" ]] || return 1

  if (
    umask 077
    ulimit -f 4 || exit 70
    exec "$CONTROLLER_LANDING_TIMEOUT_BIN" -k "$CONTROLLER_LANDING_SESSION_KILL_AFTER" \
      "$CONTROLLER_LANDING_SESSION_TIMEOUT" \
      "$CONTROLLER_LANDING_SSH_BIN" -F /dev/null -T -p "$ssh_port" \
      -i "$private_key" \
      -o BatchMode=yes \
      -o CanonicalizeHostname=no \
      -o CheckHostIP=no \
      -o ClearAllForwardings=yes \
      -o ConnectionAttempts=1 \
      -o "ConnectTimeout=$CONTROLLER_LANDING_CONNECT_TIMEOUT" \
      -o ControlMaster=no \
      -o ExitOnForwardFailure=yes \
      -o EscapeChar=none \
      -o ForwardAgent=no \
      -o ForwardX11=no \
      -o GlobalKnownHostsFile=/dev/null \
      -o "HostKeyAlias=$host_alias" \
      -o HostKeyAlgorithms=ssh-ed25519 \
      -o IdentitiesOnly=yes \
      -o IdentityAgent=none \
      -o KbdInteractiveAuthentication=no \
      -o LogLevel=ERROR \
      -o NumberOfPasswordPrompts=0 \
      -o PasswordAuthentication=no \
      -o PermitLocalCommand=no \
      -o PreferredAuthentications=publickey \
      -o ProxyCommand=none \
      -o ProxyJump=none \
      -o RequestTTY=no \
      -o PubkeyAcceptedAlgorithms=ssh-ed25519 \
      -o StrictHostKeyChecking=yes \
      -o Tunnel=no \
      -o UpdateHostKeys=no \
      -o "UserKnownHostsFile=$known_hosts" \
      -o "User=$CONTROLLER_LANDING_SSH_ACCOUNT" \
      -o VerifyHostKeyDNS=no \
      "$address"
  ) <&"$package_fd" > "$response_file" 2>/dev/null; then
    ssh_status=0
  else
    ssh_status=$?
  fi
  CONTROLLER_LANDING_LAST_SSH_STATUS="$ssh_status"
  chmod 600 "$response_file" 2>/dev/null || return 1
  controller_landing_response_file_is_safe "$response_file" "$ssh_status" || return 1
  ((ssh_status == 0))
}

controller_landing_commit_success() {
  local landing_id="$1" snapshot="$2" response_file="$3" expected_revision="$4"
  local expected_sha256="$5" response_status response_revision response_sha256
  landing_id_is_valid "$landing_id" || return 1
  controller_landing_private_file_is_trusted "$snapshot" || return 1
  controller_landing_private_file_is_trusted "$response_file" || return 1
  controller_landing_response_file_is_safe "$response_file" 0 || return 1
  landing_safe_integer_is_valid "$expected_revision" || return 1
  [[ "$expected_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
  response_status="$(jq -r '.status' "$response_file")" || return 1
  response_revision="$(jq -r '.revision' "$response_file")" || return 1
  response_sha256="$(jq -r '.content_sha256' "$response_file")" || return 1
  [[ "$response_status" == applied || "$response_status" == idempotent ]] || return 1
  [[ "$response_revision" == "$expected_revision" &&
     "$response_sha256" == "$expected_sha256" ]] || return 1

  atomic_controller_state_update '
    ([.landings[] | select(.id == $landing_id)] | first) as $current |
    if $current == $expected[0] then
      if ($current.applied_revision == $revision and
          $current.config_sha256 == $sha256 and
          $current.status == "active") then .
      elif .revision < 9007199254740991 then
        .revision += 1 |
        .landings |= map(
          if .id == $landing_id then
            .applied_revision = $revision |
            .config_sha256 = $sha256 |
            .status = "active"
          else . end
        )
      else error("controller revision exhausted") end
    else error("stale landing state") end
  ' --arg landing_id "$landing_id" --slurpfile expected "$snapshot" \
    --argjson revision "$expected_revision" --arg sha256 "$expected_sha256"
}

controller_apply_landing_in_work() {
  local landing_id="$1" allowed_entry_ipv4="$2" work="$3"
  local snapshot="$work/landing.json" known_hosts package="$work/apply.json"
  local response_file="$work/response.json" address ssh_port expected_fingerprint
  local gateway_port desired_revision credential_ref private_key issued_at expires_at nonce
  local package_fd expected_sha256
  controller_landing_transport_runtime_is_safe || return 1
  is_ipv4_address "$allowed_entry_ipv4" || return 1
  controller_landing_write_snapshot "$landing_id" "$snapshot" || return 1
  IFS=$'\t' read -r address ssh_port expected_fingerprint gateway_port \
    desired_revision credential_ref < <(
      jq -r '[.address, .ssh_port, .ssh_host_fingerprint, .gateway_port,
        .desired_revision, .credential_ref] | @tsv' "$snapshot"
    ) || return 1
  [[ -n "$credential_ref" ]] || return 1
  validate_landing_credential_manifest "$credential_ref" || return 1
  [[ "$(jq -r '.landing_id' "$credential_ref")" == "$landing_id" ]] || return 1
  private_key="$(jq -r '.ssh_private_key_file' "$credential_ref")" || return 1
  controller_landing_ssh_private_key_is_valid "$private_key" || return 1

  known_hosts="$(controller_landing_prepare_known_hosts "$address" "$ssh_port" \
    "$expected_fingerprint" "sb-landing-$landing_id" "$work")" || return 1
  issued_at="$(date +%s)" || return 1
  landing_safe_integer_is_valid "$issued_at" || return 1
  expires_at=$((10#$issued_at + CONTROLLER_LANDING_PACKAGE_TTL))
  nonce="$(openssl rand -hex 32 2>/dev/null)" || return 1
  landing_nonce_is_valid "$nonce" || return 1
  build_landing_apply_package "$credential_ref" "$allowed_entry_ipv4" "$gateway_port" \
    "$desired_revision" "$issued_at" "$expires_at" "$nonce" "$package" || return 1
  controller_landing_private_file_is_trusted "$package" || return 1
  expected_sha256="$(jq -r '.content_sha256' "$package")" || return 1
  [[ "$expected_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
  exec {package_fd}< "$package" || return 1
  rm -f -- "$package" || return 1
  sync_transaction_path "$work" || return 1
  controller_landing_ssh_exchange "$address" "$ssh_port" "$landing_id" "$private_key" \
    "$known_hosts" "$expected_fingerprint" "$package_fd" "$response_file" || return 1
  controller_landing_commit_success "$landing_id" "$snapshot" "$response_file" \
    "$desired_revision" "$expected_sha256"
}

controller_apply_landing() {
  local landing_id="${1:-}" allowed_entry_ipv4="${2:-}" work rc=1
  [[ $# -eq 2 ]] || return 1
  landing_id_is_valid "$landing_id" || return 1
  is_ipv4_address "$allowed_entry_ipv4" || return 1
  work="$(controller_landing_create_work_directory)" || return 1
  register_temp_path "$work" || { controller_landing_remove_work_directory "$work"; return 1; }
  if (controller_apply_landing_in_work "$landing_id" "$allowed_entry_ipv4" "$work"); then
    rc=0
  fi
  controller_landing_remove_work_directory "$work" || rc=1
  return "$rc"
}
# ============================================================
# v5 受管落地秘密清单与 apply 协议（尚未接入远程执行）
# ============================================================

LANDING_CREDENTIAL_SCHEMA_VERSION=1
LANDING_APPLY_SCHEMA_VERSION=1
LANDING_RECEIPT_SCHEMA_VERSION=1
LANDING_APPLY_MAX_BYTES=1048576
LANDING_APPLY_MAX_TTL=600
LANDING_APPLY_CLOCK_SKEW=60
LANDING_RECEIPT_LOCK_TIMEOUT=30
LANDING_RECEIPT_FILE="${SB_LANDING_RECEIPT_FILE:-/var/lib/sb-user-manager/landing-receipt.json}"
LANDING_RECEIPT_LOCK_FILE="${SB_LANDING_RECEIPT_LOCK_FILE:-/run/lock/sb-user-manager/landing-receipt.lock}"

landing_id_is_valid() {
  [[ "$1" =~ ^[a-z][a-z0-9-]{0,31}$ ]]
}

landing_safe_integer_is_valid() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  ((${#value} <= 16)) || return 1
  ((10#$value <= 9007199254740991))
}

landing_port_is_valid() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  ((${#value} <= 5)) || return 1
  ((10#$value >= 1 && 10#$value <= 65535))
}

landing_nonce_is_valid() {
  [[ "$1" =~ ^[0-9a-f]{64}$ ]]
}

landing_secret_material_path_is_valid() {
  local landing_id="$1" value="$2" filename="$3"
  [[ "$value" == "$CONTROLLER_SECRET_DIR/landing-${landing_id}/${filename}" ]]
}

validate_landing_credential_manifest_json() {
  local path="$1" landing_id gateway_server_name key value
  jq -e -s 'length == 1' "$path" >/dev/null || return 1
  jq -e --argjson schema "$LANDING_CREDENTIAL_SCHEMA_VERSION" '
    type == "object" and
    (keys | sort) == [
      "gateway_ca_certificate_file", "gateway_certificate_file", "gateway_password_file",
      "gateway_private_key_file", "gateway_server_name", "landing_id", "schema_version",
      "ssh_private_key_file"
    ] and
    .schema_version == $schema and
    (.landing_id | type == "string" and test("^[a-z][a-z0-9-]{0,31}$")) and
    (.gateway_server_name | type == "string" and length >= 3 and length <= 253) and
    all([
      .ssh_private_key_file, .gateway_password_file, .gateway_ca_certificate_file,
      .gateway_certificate_file, .gateway_private_key_file
    ][]; type == "string" and length >= 1)
  ' "$path" >/dev/null || return 1

  landing_id="$(jq -r '.landing_id' "$path")" || return 1
  gateway_server_name="$(jq -r '.gateway_server_name' "$path")" || return 1
  landing_id_is_valid "$landing_id" || return 1
  controller_dns_name_is_valid "$gateway_server_name" || return 1
  while IFS=$'\t' read -r key value; do
    case "$key" in
      ssh_private_key_file) landing_secret_material_path_is_valid "$landing_id" "$value" ssh-ed25519 || return 1 ;;
      gateway_password_file) landing_secret_material_path_is_valid "$landing_id" "$value" gateway-password || return 1 ;;
      gateway_ca_certificate_file) landing_secret_material_path_is_valid "$landing_id" "$value" gateway-ca.crt || return 1 ;;
      gateway_certificate_file) landing_secret_material_path_is_valid "$landing_id" "$value" gateway.crt || return 1 ;;
      gateway_private_key_file) landing_secret_material_path_is_valid "$landing_id" "$value" gateway.key || return 1 ;;
      *) return 1 ;;
    esac
  done < <(jq -r 'to_entries[] | select(.key | endswith("_file")) | [.key, .value] | @tsv' "$path")
}

controller_certificate_matches_sni() {
  local certificate="$1" server_name="$2"
  # 完整 SNI 只通过 stdin 交给 Python，不进入 python/openssl 的 argv。
  printf '%s' "$server_name" | python3 -I -c '
import ssl
import sys

name = sys.stdin.read().lower()
certificate = ssl._ssl._test_decode_cert(sys.argv[1])
dns_names = [
    value.lower()
    for kind, value in certificate.get("subjectAltName", ())
    if kind == "DNS"
]

def matches(pattern, hostname):
    if "*" not in pattern:
        return pattern == hostname
    if not pattern.startswith("*.") or pattern.count("*") != 1:
        return False
    return hostname.count(".") == pattern.count(".") and hostname.endswith(pattern[1:])

if not any(matches(pattern, name) for pattern in dns_names):
    raise SystemExit(1)
' "$certificate" >/dev/null 2>&1
}

controller_historical_certificate_attime() {
  python3 -I -c '
import calendar
import datetime
import ssl
import sys

fmt = "%b %d %H:%M:%S %Y %Z"

def bounds(path):
    cert = ssl._ssl._test_decode_cert(path)
    start = calendar.timegm(datetime.datetime.strptime(cert["notBefore"], fmt).timetuple())
    end = calendar.timegm(datetime.datetime.strptime(cert["notAfter"], fmt).timetuple())
    return start, end

ca_start, ca_end = bounds(sys.argv[1])
cert_start, cert_end = bounds(sys.argv[2])
start = max(ca_start, cert_start)
end = min(ca_end, cert_end)
if start >= end:
    raise SystemExit(1)
print(start + ((end - start) // 2))
' "$1" "$2"
}

validate_controller_tls_material() {
  local ca_certificate="$1" certificate="$2" private_key="$3" server_name="$4"
  local certificate_time_policy="${5:-current}"
  local certificate_public_sha private_public_sha historical_attime
  controller_state_file_is_trusted "$ca_certificate" || return 1
  controller_state_file_is_trusted "$certificate" || return 1
  controller_state_file_is_trusted "$private_key" || return 1
  controller_dns_name_is_valid "$server_name" || return 1
  [[ "$certificate_time_policy" == current || "$certificate_time_policy" == historical ]] || return 1
  [[ "$(grep -Fxc -- '-----BEGIN CERTIFICATE-----' "$ca_certificate" || true)" == 1 &&
     "$(grep -Fxc -- '-----END CERTIFICATE-----' "$ca_certificate" || true)" == 1 ]] || return 1
  [[ "$(grep -Fxc -- '-----BEGIN CERTIFICATE-----' "$certificate" || true)" == 1 &&
     "$(grep -Fxc -- '-----END CERTIFICATE-----' "$certificate" || true)" == 1 ]] || return 1
  [[ "$(grep -Ec '^-----BEGIN ([A-Z0-9]+ )?PRIVATE KEY-----$' "$private_key" || true)" == 1 &&
     "$(grep -Ec '^-----END ([A-Z0-9]+ )?PRIVATE KEY-----$' "$private_key" || true)" == 1 ]] || return 1
  openssl x509 -in "$ca_certificate" -noout >/dev/null 2>&1 || return 1
  if [[ "$certificate_time_policy" == current ]]; then
    openssl x509 -in "$certificate" -noout -checkend 3600 >/dev/null 2>&1 || return 1
    openssl verify -CAfile "$ca_certificate" "$certificate" >/dev/null 2>&1 || return 1
  else
    openssl x509 -in "$certificate" -noout >/dev/null 2>&1 || return 1
    historical_attime="$(controller_historical_certificate_attime "$ca_certificate" "$certificate")" || return 1
    [[ "$historical_attime" =~ ^[0-9]+$ ]] || return 1
    openssl verify -attime "$historical_attime" -CAfile "$ca_certificate" \
      "$certificate" >/dev/null 2>&1 || return 1
  fi
  certificate_public_sha="$(openssl x509 -in "$certificate" -pubkey -noout 2>/dev/null |
    sha256sum | awk '{print $1}')" || return 1
  private_public_sha="$(openssl pkey -in "$private_key" -passin pass: -pubout 2>/dev/null |
    sha256sum | awk '{print $1}')" || return 1
  [[ "$certificate_public_sha" =~ ^[0-9a-f]{64}$ &&
     "$certificate_public_sha" == "$private_public_sha" ]] || return 1
  controller_certificate_matches_sni "$certificate" "$server_name"
}

validate_landing_credential_manifest() {
  local path="$1" landing_id server_name ssh_key password_file ca_certificate certificate private_key
  local ssh_public_key
  controller_state_file_is_trusted "$path" || return 1
  validate_landing_credential_manifest_json "$path" || return 1
  landing_id="$(jq -r '.landing_id' "$path")" || return 1
  server_name="$(jq -r '.gateway_server_name' "$path")" || return 1
  controller_secret_ref_is_valid "$landing_id" "$path" || return 1
  controller_private_directory_is_trusted "$CONTROLLER_SECRET_DIR" || return 1
  controller_private_directory_is_trusted "$CONTROLLER_SECRET_DIR/landing-${landing_id}" || return 1
  ssh_key="$(jq -r '.ssh_private_key_file' "$path")" || return 1
  password_file="$(jq -r '.gateway_password_file' "$path")" || return 1
  ca_certificate="$(jq -r '.gateway_ca_certificate_file' "$path")" || return 1
  certificate="$(jq -r '.gateway_certificate_file' "$path")" || return 1
  private_key="$(jq -r '.gateway_private_key_file' "$path")" || return 1
  for path in "$ssh_key" "$password_file" "$ca_certificate" "$certificate" "$private_key"; do
    controller_state_file_is_trusted "$path" || return 1
  done
  ssh_public_key="$(ssh-keygen -y -P '' -f "$ssh_key" 2>/dev/null)" || return 1
  [[ "$ssh_public_key" == ssh-ed25519\ * ]] || return 1
  jq -e -Rs 'length >= 32 and length <= 128 and test("^[A-Za-z0-9_-]+$")' \
    "$password_file" >/dev/null || return 1
  validate_controller_tls_material "$ca_certificate" "$certificate" "$private_key" "$server_name"
}

landing_apply_content_sha256() {
  local package="$1"
  jq -cS '.gateway' "$package" | sha256sum | awk '{print $1}'
}

landing_apply_package_json_is_valid() {
  local package="$1" actual_sha expected_sha server_name allowed_entry_ipv4
  controller_state_file_is_trusted "$package" || return 1
  [[ "$(wc -c < "$package" | tr -d ' ')" -le "$LANDING_APPLY_MAX_BYTES" ]] || return 1
  jq -e -s 'length == 1' "$package" >/dev/null || return 1
  jq -e --argjson schema "$LANDING_APPLY_SCHEMA_VERSION" '
    type == "object" and
    (keys | sort) == [
      "content_sha256", "expires_at", "gateway", "issued_at", "landing_id",
      "nonce", "revision", "schema_version"
    ] and
    .schema_version == $schema and
    (.landing_id | type == "string" and test("^[a-z][a-z0-9-]{0,31}$")) and
    (.revision | type == "number" and . == floor and . >= 1 and . <= 9007199254740991) and
    (.issued_at | type == "number" and . == floor and . >= 0 and . <= 9007199254740991) and
    (.expires_at | type == "number" and . == floor and . >= 0 and . <= 9007199254740991) and
    (.nonce | type == "string" and test("^[0-9a-f]{64}$")) and
    (.content_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.gateway | type == "object") and
    (.gateway | keys | sort) == [
      "allowed_entry_ipv4", "ca_certificate_pem", "certificate_pem", "listen_port",
      "password", "private_key_pem", "server_name"
    ] and
    (.gateway.listen_port | type == "number" and . == floor and . >= 1 and . <= 65535) and
    (.gateway.server_name | type == "string" and length >= 3 and length <= 253) and
    (.gateway.password | type == "string" and length >= 32 and length <= 128 and
      test("^[A-Za-z0-9_-]+$")) and
    (.gateway.allowed_entry_ipv4 | type == "string" and length >= 7 and length <= 15) and
    (.gateway.ca_certificate_pem | type == "string" and
      startswith("-----BEGIN CERTIFICATE-----\n") and endswith("-----END CERTIFICATE-----\n")) and
    (.gateway.certificate_pem | type == "string" and
      startswith("-----BEGIN CERTIFICATE-----\n") and endswith("-----END CERTIFICATE-----\n")) and
    (.gateway.private_key_pem | type == "string" and
      startswith("-----BEGIN ") and endswith("PRIVATE KEY-----\n"))
  ' "$package" >/dev/null || return 1

  expected_sha="$(jq -r '.content_sha256' "$package")" || return 1
  actual_sha="$(landing_apply_content_sha256 "$package")" || return 1
  [[ "$actual_sha" == "$expected_sha" ]] || return 1
  server_name="$(jq -r '.gateway.server_name' "$package")" || return 1
  allowed_entry_ipv4="$(jq -r '.gateway.allowed_entry_ipv4' "$package")" || return 1
  controller_dns_name_is_valid "$server_name" || return 1
  is_ipv4_address "$allowed_entry_ipv4"
}

landing_apply_package_structure_is_valid() {
  local package="$1" certificate_time_policy="${2:-current}"
  local server_name work rc=0
  local validation_root="${SB_LANDING_APPLY_VALIDATION_ROOT:-}" persistent_validation=false
  [[ "$certificate_time_policy" == current || "$certificate_time_policy" == historical ]] || return 1
  landing_apply_package_json_is_valid "$package" || return 1
  server_name="$(jq -r '.gateway.server_name' "$package")" || return 1

  if [[ -n "$validation_root" ]]; then
    controller_private_directory_is_trusted "$validation_root" || return 1
    work="$validation_root/.validation"
    [[ ! -e "$work" && ! -L "$work" ]] || return 1
    install -d -m 700 -- "$work" || return 1
    controller_private_directory_is_trusted "$work" || return 1
    persistent_validation=true
  else
    work="$(mktemp -d /tmp/sb-landing-apply-validate.XXXXXX)" || return 1
    register_temp_path "$work" || { rm -rf -- "$work"; return 1; }
  fi
  if ! jq -r '.gateway.ca_certificate_pem' "$package" > "$work/ca.crt" ||
     ! jq -r '.gateway.certificate_pem' "$package" > "$work/gateway.crt" ||
     ! jq -r '.gateway.private_key_pem' "$package" > "$work/gateway.key" ||
     ! chmod 600 "$work/ca.crt" "$work/gateway.crt" "$work/gateway.key" ||
     ! validate_controller_tls_material \
       "$work/ca.crt" "$work/gateway.crt" "$work/gateway.key" "$server_name" \
       "$certificate_time_policy"; then
    rc=1
  fi
  rm -rf -- "$work" || rc=1
  if [[ "$persistent_validation" == true ]]; then
    sync_transaction_path "$validation_root" || rc=1
  fi
  return "$rc"
}

landing_apply_package_is_fresh() {
  local package="$1" now="${2:-$(date +%s)}" issued_at expires_at
  landing_safe_integer_is_valid "$now" || return 1
  issued_at="$(jq -r '.issued_at' "$package")" || return 1
  expires_at="$(jq -r '.expires_at' "$package")" || return 1
  landing_safe_integer_is_valid "$issued_at" || return 1
  landing_safe_integer_is_valid "$expires_at" || return 1
  ((expires_at > issued_at && expires_at - issued_at <= LANDING_APPLY_MAX_TTL)) || return 1
  ((issued_at <= now + LANDING_APPLY_CLOCK_SKEW && expires_at > now))
}

validate_landing_apply_package() {
  local package="$1" now="${2:-$(date +%s)}"
  landing_apply_package_structure_is_valid "$package" || return 1
  landing_apply_package_is_fresh "$package" "$now"
}

build_landing_apply_package() {
  local manifest="$1" allowed_entry_ipv4="$2" gateway_port="$3" revision="$4"
  local issued_at="$5" expires_at="$6" nonce="$7" output="$8"
  local output_dir openssl_path helper_rc=0 test_stop_stage='' test_unsupported_stage=''
  local test_expected_link_method='' test_forced_link_method='' test_diagnostics=''
  validate_landing_credential_manifest "$manifest" || return 1
  is_ipv4_address "$allowed_entry_ipv4" || return 1
  landing_port_is_valid "$gateway_port" || return 1
  landing_safe_integer_is_valid "$revision" || return 1
  ((10#$revision >= 1)) || return 1
  landing_safe_integer_is_valid "$issued_at" || return 1
  landing_safe_integer_is_valid "$expires_at" || return 1
  landing_nonce_is_valid "$nonce" || return 1
  [[ ! -e "$output" && ! -L "$output" ]] || return 1
  output_dir="$(dirname "$output")"
  controller_private_directory_is_trusted "$output_dir" || return 1
  openssl_path="$(type -P openssl)" || return 1
  [[ "$openssl_path" == /* && -x "$openssl_path" ]] || return 1
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]]; then
    test_stop_stage="${SB_LANDING_APPLY_TEST_STOP_STAGE:-}"
    test_unsupported_stage="${SB_LANDING_APPLY_TEST_FORCE_UNSUPPORTED_AT:-}"
    test_expected_link_method="${SB_LANDING_APPLY_TEST_EXPECT_LINK_METHOD:-}"
    test_forced_link_method="${SB_LANDING_APPLY_TEST_FORCE_LINK_METHOD:-}"
    test_diagnostics="${SB_LANDING_APPLY_TEST_DIAGNOSTICS:-}"
  fi

  if SB_LANDING_APPLY_MANIFEST_PATH="$manifest" \
    SB_LANDING_APPLY_OUTPUT_PATH="$output" \
    SB_LANDING_CONTROLLER_SECRET_DIR="$CONTROLLER_SECRET_DIR" \
    SB_LANDING_CREDENTIAL_SCHEMA_VERSION="$LANDING_CREDENTIAL_SCHEMA_VERSION" \
    SB_LANDING_OPENSSL_PATH="$openssl_path" \
    SB_LANDING_ALLOWED_ENTRY_IPV4="$allowed_entry_ipv4" \
    SB_LANDING_GATEWAY_PORT="$gateway_port" \
    SB_LANDING_APPLY_REVISION="$revision" \
    SB_LANDING_APPLY_ISSUED_AT="$issued_at" \
    SB_LANDING_APPLY_EXPIRES_AT="$expires_at" \
    SB_LANDING_APPLY_NONCE="$nonce" \
    SB_LANDING_APPLY_SCHEMA_VERSION="$LANDING_APPLY_SCHEMA_VERSION" \
    SB_LANDING_APPLY_MAX_BYTES="$LANDING_APPLY_MAX_BYTES" \
    SB_LANDING_APPLY_MAX_TTL="$LANDING_APPLY_MAX_TTL" \
    SB_LANDING_APPLY_CLOCK_SKEW="$LANDING_APPLY_CLOCK_SKEW" \
    SB_LANDING_APPLY_PARENT_PID="${BASHPID:-$$}" \
    SB_LANDING_APPLY_TEST_STOP_STAGE="$test_stop_stage" \
    SB_LANDING_APPLY_TEST_FORCE_UNSUPPORTED_AT="$test_unsupported_stage" \
    SB_LANDING_APPLY_TEST_EXPECT_LINK_METHOD="$test_expected_link_method" \
    SB_LANDING_APPLY_TEST_FORCE_LINK_METHOD="$test_forced_link_method" \
    SB_LANDING_APPLY_TEST_DIAGNOSTICS="$test_diagnostics" \
    python3 -I - <<'PY'
import ctypes
import errno
import hashlib
import hmac
import json
import os
import re
import resource
import signal
import ssl
import stat
import subprocess
import sys

UNSUPPORTED_STATUS = 73
PR_SET_PDEATHSIG = 1
PR_SET_DUMPABLE = 4
AT_FDCWD = -100
AT_SYMLINK_FOLLOW = 0x400
AT_EMPTY_PATH = 0x1000
SAFE_INTEGER_MAX = 9007199254740991


class BuildFailure(Exception):
    pass


class AnonymousPublishingUnsupported(BuildFailure):
    pass


def require(condition):
    if not condition:
        raise BuildFailure()


def emit_test_diagnostic(error):
    if os.environ.get("SB_LANDING_APPLY_TEST_DIAGNOSTICS") != "true":
        return
    kind = type(error).__name__
    if re.fullmatch(r"[A-Za-z]+", kind) is None:
        kind = "Exception"
    lines = []
    trace = error.__traceback__
    while trace is not None and len(lines) < 16:
        lines.append(str(trace.tb_lineno))
        trace = trace.tb_next
    payload = f"landing apply helper test diagnostic: {kind}:{','.join(lines)}\n"
    try:
        os.write(2, payload.encode("ascii", "strict"))
    except BaseException:
        pass


def env(name, maximum=4096):
    value = os.environ.get(name)
    require(value is not None and 0 < len(value) <= maximum)
    return value


def env_integer(name, maximum, digits):
    value = env(name, digits)
    require(re.fullmatch(r"[0-9]+", value) is not None)
    number = int(value, 10)
    require(number <= maximum)
    return number


def arm_process_safety(expected_parent):
    if not sys.platform.startswith("linux") or not hasattr(os, "O_TMPFILE"):
        raise AnonymousPublishingUnsupported()
    os.umask(0o077)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    try:
        with open("/proc/self/coredump_filter", "w", encoding="ascii") as core_filter:
            core_filter.write("0\n")
    except OSError:
        raise AnonymousPublishingUnsupported() from None
    require(os.getppid() == expected_parent)
    libc = ctypes.CDLL(None, use_errno=True)
    require(libc.prctl(PR_SET_PDEATHSIG, signal.SIGKILL, 0, 0, 0) == 0)
    require(os.getppid() == expected_parent)
    require(libc.prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) == 0)
    return libc


def read_private_text(path, maximum):
    flags = os.O_RDONLY | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        metadata = os.fstat(descriptor)
        require(stat.S_ISREG(metadata.st_mode))
        require(metadata.st_uid == os.geteuid())
        require(stat.S_IMODE(metadata.st_mode) == 0o600)
        require(0 <= metadata.st_size <= maximum)
        chunks = []
        remaining = maximum + 1
        while remaining > 0:
            chunk = os.read(descriptor, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        require(len(data) <= maximum)
        return data.decode("utf-8", "strict")
    finally:
        os.close(descriptor)


def valid_dns_name(value):
    if not 3 <= len(value) <= 253:
        return False
    if "." not in value or value.startswith(".") or value.endswith(".") or ".." in value:
        return False
    if re.fullmatch(r"[A-Za-z0-9.-]+", value) is None:
        return False
    for label in value.split("."):
        if not 1 <= len(label) <= 63:
            return False
        if re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?", label) is None:
            return False
    return True


def valid_ipv4(value):
    if not 7 <= len(value) <= 15:
        return False
    parts = value.split(".")
    return len(parts) == 4 and all(part.isascii() and part.isdigit() and int(part, 10) <= 255 for part in parts)


def checkpoint(name, selected):
    if selected == name:
        os.kill(os.getpid(), signal.SIGSTOP)


def write_all(descriptor, payload):
    position = 0
    while position < len(payload):
        written = os.write(descriptor, payload[position:])
        require(written > 0)
        position += written


def read_all(descriptor, maximum):
    os.lseek(descriptor, 0, os.SEEK_SET)
    chunks = []
    remaining = maximum + 1
    while remaining > 0:
        chunk = os.read(descriptor, min(65536, remaining))
        if not chunk:
            break
        chunks.append(chunk)
        remaining -= len(chunk)
    payload = b"".join(chunks)
    require(0 < len(payload) <= maximum)
    return payload


def safe_fsync(descriptor):
    try:
        os.fsync(descriptor)
    except OSError as error:
        if error.errno in {
            errno.EACCES, errno.EINVAL, errno.ENOSYS, errno.ENOTSUP,
            errno.EOPNOTSUPP, errno.EPERM, errno.EROFS
        }:
            raise AnonymousPublishingUnsupported() from None
        raise BuildFailure() from None


def create_secret_memfd(label, payload):
    if not hasattr(os, "memfd_create"):
        raise AnonymousPublishingUnsupported()
    flags = getattr(os, "MFD_CLOEXEC", 0x0001)
    try:
        descriptor = os.memfd_create(f"sb-landing-{label}", flags)
    except OSError as error:
        if error.errno in {
            errno.EACCES, errno.EINVAL, errno.ENOSYS, errno.ENOTSUP,
            errno.EOPNOTSUPP, errno.EPERM
        }:
            raise AnonymousPublishingUnsupported() from None
        raise BuildFailure() from None
    try:
        encoded_payload = payload.encode("utf-8")
        os.fchmod(descriptor, 0o600)
        write_all(descriptor, encoded_payload)
        os.lseek(descriptor, 0, os.SEEK_SET)
        metadata = os.fstat(descriptor)
        require(stat.S_ISREG(metadata.st_mode))
        require(metadata.st_uid == os.geteuid())
        require(stat.S_IMODE(metadata.st_mode) == 0o600)
        require(metadata.st_nlink == 0)
        require(metadata.st_size == len(encoded_payload))
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def run_openssl(libc, openssl_path, arguments, inherited_fds, capture=False):
    python_pid = os.getpid()
    for descriptor in inherited_fds:
        os.lseek(descriptor, 0, os.SEEK_SET)

    def arm_child_parent_death():
        if libc.prctl(PR_SET_PDEATHSIG, signal.SIGKILL, 0, 0, 0) != 0:
            os._exit(127)
        if os.getppid() != python_pid:
            os._exit(127)

    result = subprocess.run(
        [openssl_path, *arguments],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        close_fds=True,
        pass_fds=tuple(inherited_fds),
        env={"LANG": "C", "LC_ALL": "C"},
        timeout=10,
        check=False,
        preexec_fn=arm_child_parent_death,
    )
    require(result.returncode == 0)
    if capture:
        require(result.stdout is not None and len(result.stdout) <= 65536)
        return result.stdout
    return b""


def validate_tls_snapshot(libc, openssl_path, ca_certificate, certificate, private_key,
                          server_name, stop_stage):
    require(ca_certificate.count("-----BEGIN CERTIFICATE-----\n") == 1)
    require(ca_certificate.count("-----END CERTIFICATE-----\n") == 1)
    require(certificate.count("-----BEGIN CERTIFICATE-----\n") == 1)
    require(certificate.count("-----END CERTIFICATE-----\n") == 1)
    require(len(re.findall(r"(?m)^-----BEGIN (?:[A-Z0-9]+ )?PRIVATE KEY-----$", private_key)) == 1)
    require(len(re.findall(r"(?m)^-----END (?:[A-Z0-9]+ )?PRIVATE KEY-----$", private_key)) == 1)
    if not os.path.isdir("/proc/self/fd"):
        raise AnonymousPublishingUnsupported()
    descriptors = []
    try:
        descriptors.append(create_secret_memfd("ca", ca_certificate))
        descriptors.append(create_secret_memfd("certificate", certificate))
        descriptors.append(create_secret_memfd("private-key", private_key))
        checkpoint("validation_material_ready", stop_stage)
        ca_path, certificate_path, private_key_path = (
            f"/proc/self/fd/{descriptor}" for descriptor in descriptors
        )
        run_openssl(libc, openssl_path, ["x509", "-in", ca_path, "-noout"], descriptors)
        run_openssl(
            libc, openssl_path,
            ["x509", "-in", certificate_path, "-noout", "-checkend", "3600"],
            descriptors,
        )
        run_openssl(
            libc, openssl_path, ["verify", "-CAfile", ca_path, certificate_path], descriptors
        )
        certificate_public = run_openssl(
            libc, openssl_path, ["x509", "-in", certificate_path, "-pubkey", "-noout"],
            descriptors, capture=True
        )
        private_public = run_openssl(
            libc, openssl_path,
            ["pkey", "-in", private_key_path, "-passin", "pass:", "-pubout"],
            descriptors, capture=True
        )
        require(hmac.compare_digest(
            hashlib.sha256(certificate_public).digest(), hashlib.sha256(private_public).digest()
        ))
        os.lseek(descriptors[1], 0, os.SEEK_SET)
        decoded = ssl._ssl._test_decode_cert(certificate_path)
        dns_names = [
            value.lower()
            for kind, value in decoded.get("subjectAltName", ())
            if kind == "DNS"
        ]

        def matches(pattern, hostname):
            if "*" not in pattern:
                return pattern == hostname
            if not pattern.startswith("*.") or pattern.count("*") != 1:
                return False
            return hostname.count(".") == pattern.count(".") and hostname.endswith(pattern[1:])

        require(any(matches(pattern, server_name.lower()) for pattern in dns_names))
    finally:
        for descriptor in descriptors:
            os.close(descriptor)


def validate_package(payload, expected_gateway, expected_landing_id, schema, revision,
                     issued_at, expires_at, nonce, maximum_bytes, maximum_ttl, clock_skew):
    require(0 < len(payload) <= maximum_bytes)
    package = json.loads(payload.decode("utf-8", "strict"))
    require(type(package) is dict)
    require(set(package) == {
        "schema_version", "landing_id", "revision", "issued_at", "expires_at",
        "nonce", "content_sha256", "gateway"
    })
    require(type(package.get("schema_version")) is int and package["schema_version"] == schema)
    landing_id = package.get("landing_id")
    require(type(landing_id) is str and re.fullmatch(r"[a-z][a-z0-9-]{0,31}", landing_id) is not None)
    require(landing_id == expected_landing_id)
    for key, expected in (("revision", revision), ("issued_at", issued_at), ("expires_at", expires_at)):
        require(type(package.get(key)) is int and 0 <= package[key] <= SAFE_INTEGER_MAX)
        require(package[key] == expected)
    require(package["revision"] >= 1)
    require(expires_at > issued_at and expires_at - issued_at <= maximum_ttl)
    require(issued_at <= issued_at + clock_skew and expires_at > issued_at)
    require(type(package.get("nonce")) is str and re.fullmatch(r"[0-9a-f]{64}", package["nonce"]) is not None)
    require(package["nonce"] == nonce)
    require(type(package.get("content_sha256")) is str and
            re.fullmatch(r"[0-9a-f]{64}", package["content_sha256"]) is not None)
    gateway = package.get("gateway")
    require(type(gateway) is dict and gateway == expected_gateway)
    require(set(gateway) == {
        "listen_port", "server_name", "password", "allowed_entry_ipv4",
        "ca_certificate_pem", "certificate_pem", "private_key_pem"
    })
    require(type(gateway["listen_port"]) is int and 1 <= gateway["listen_port"] <= 65535)
    require(type(gateway["server_name"]) is str and valid_dns_name(gateway["server_name"]))
    # Keep jq's existing `test("^[A-Za-z0-9_-]+$")` semantics exactly: its `$`
    # also matches immediately before one trailing newline. Tightening that legacy
    # input rule belongs in a schema/validator change, not in this publisher.
    require(type(gateway["password"]) is str and 32 <= len(gateway["password"]) <= 128 and
            re.match(r"^[A-Za-z0-9_-]+$", gateway["password"]) is not None)
    require(type(gateway["allowed_entry_ipv4"]) is str and valid_ipv4(gateway["allowed_entry_ipv4"]))
    require(type(gateway["ca_certificate_pem"]) is str and
            gateway["ca_certificate_pem"].startswith("-----BEGIN CERTIFICATE-----\n") and
            gateway["ca_certificate_pem"].endswith("-----END CERTIFICATE-----\n"))
    require(type(gateway["certificate_pem"]) is str and
            gateway["certificate_pem"].startswith("-----BEGIN CERTIFICATE-----\n") and
            gateway["certificate_pem"].endswith("-----END CERTIFICATE-----\n"))
    require(type(gateway["private_key_pem"]) is str and
            gateway["private_key_pem"].startswith("-----BEGIN ") and
            gateway["private_key_pem"].endswith("PRIVATE KEY-----\n"))
    canonical_gateway = json.dumps(
        gateway, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8") + b"\n"
    require(hashlib.sha256(canonical_gateway).hexdigest() == package["content_sha256"])


def anonymous_open(directory_fd):
    flags = os.O_RDWR | os.O_CLOEXEC | os.O_TMPFILE
    try:
        return os.open(".", flags, 0o600, dir_fd=directory_fd)
    except OSError as error:
        if error.errno in {
            errno.EACCES, errno.EINVAL, errno.EISDIR, errno.ENOSYS, errno.ENOTSUP,
            errno.EOPNOTSUPP, errno.EPERM
        }:
            raise AnonymousPublishingUnsupported() from None
        raise BuildFailure() from None


def link_anonymous(libc, anonymous_fd, directory_fd, basename, forced_method):
    linkat = libc.linkat
    linkat.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
    linkat.restype = ctypes.c_int
    encoded_name = os.fsencode(basename)
    if forced_method != "proc":
        if linkat(anonymous_fd, b"", directory_fd, encoded_name, AT_EMPTY_PATH) == 0:
            return "direct"
        direct_errno = ctypes.get_errno()
        if direct_errno == errno.EEXIST:
            raise BuildFailure()
        if direct_errno not in {
            errno.EACCES, errno.ENOENT, errno.EINVAL, errno.ENOSYS, errno.ENOTSUP,
            errno.EOPNOTSUPP, errno.EPERM
        }:
            raise BuildFailure()
    proc_path = os.fsencode(f"/proc/self/fd/{anonymous_fd}")
    if linkat(AT_FDCWD, proc_path, directory_fd, encoded_name, AT_SYMLINK_FOLLOW) == 0:
        return "proc"
    proc_errno = ctypes.get_errno()
    if proc_errno == errno.EEXIST:
        raise BuildFailure()
    if proc_errno in {
        errno.EACCES, errno.ENOENT, errno.EINVAL, errno.ENOSYS, errno.ENOTSUP,
        errno.EOPNOTSUPP, errno.EPERM, errno.EXDEV
    }:
        raise AnonymousPublishingUnsupported()
    raise BuildFailure()


def unlink_published_if_owned(directory_fd, basename, anonymous_metadata):
    try:
        target_metadata = os.stat(basename, dir_fd=directory_fd, follow_symlinks=False)
        if (target_metadata.st_dev, target_metadata.st_ino) == (
            anonymous_metadata.st_dev, anonymous_metadata.st_ino
        ):
            os.unlink(basename, dir_fd=directory_fd)
            os.fsync(directory_fd)
    except OSError:
        pass


def main():
    expected_parent = env_integer("SB_LANDING_APPLY_PARENT_PID", SAFE_INTEGER_MAX, 16)
    libc = arm_process_safety(expected_parent)
    manifest_path = env("SB_LANDING_APPLY_MANIFEST_PATH")
    output_path = env("SB_LANDING_APPLY_OUTPUT_PATH")
    controller_secret_dir = env("SB_LANDING_CONTROLLER_SECRET_DIR")
    credential_schema = env_integer("SB_LANDING_CREDENTIAL_SCHEMA_VERSION", SAFE_INTEGER_MAX, 16)
    openssl_path = env("SB_LANDING_OPENSSL_PATH")
    require(os.path.isabs(openssl_path) and os.access(openssl_path, os.X_OK))
    openssl_metadata = os.stat(openssl_path, follow_symlinks=True)
    require(stat.S_ISREG(openssl_metadata.st_mode) and openssl_metadata.st_uid == 0)
    allowed_entry_ipv4 = env("SB_LANDING_ALLOWED_ENTRY_IPV4", 15)
    gateway_port = env_integer("SB_LANDING_GATEWAY_PORT", 65535, 5)
    revision = env_integer("SB_LANDING_APPLY_REVISION", SAFE_INTEGER_MAX, 16)
    issued_at = env_integer("SB_LANDING_APPLY_ISSUED_AT", SAFE_INTEGER_MAX, 16)
    expires_at = env_integer("SB_LANDING_APPLY_EXPIRES_AT", SAFE_INTEGER_MAX, 16)
    nonce = env("SB_LANDING_APPLY_NONCE", 64)
    schema = env_integer("SB_LANDING_APPLY_SCHEMA_VERSION", SAFE_INTEGER_MAX, 16)
    maximum_bytes = env_integer("SB_LANDING_APPLY_MAX_BYTES", SAFE_INTEGER_MAX, 16)
    maximum_ttl = env_integer("SB_LANDING_APPLY_MAX_TTL", SAFE_INTEGER_MAX, 16)
    clock_skew = env_integer("SB_LANDING_APPLY_CLOCK_SKEW", SAFE_INTEGER_MAX, 16)
    stop_stage = os.environ.get("SB_LANDING_APPLY_TEST_STOP_STAGE", "")
    unsupported_stage = os.environ.get("SB_LANDING_APPLY_TEST_FORCE_UNSUPPORTED_AT", "")
    expected_link_method = os.environ.get("SB_LANDING_APPLY_TEST_EXPECT_LINK_METHOD", "")
    forced_link_method = os.environ.get("SB_LANDING_APPLY_TEST_FORCE_LINK_METHOD", "")
    require(stop_stage in {
        "", "before_secret_read", "sources_read", "gateway_assembled",
        "package_write_started", "package_written", "before_validation",
        "validation_material_ready", "after_validation", "after_file_sync",
        "before_publish", "after_publish", "after_directory_sync"
    })
    require(unsupported_stage in {
        "", "anonymous_open", "directory_fsync", "file_fsync", "link"
    })
    require(expected_link_method in {"", "direct", "proc"})
    require(forced_link_method in {"", "proc"})

    manifest_text = read_private_text(manifest_path, maximum_bytes)
    manifest = json.loads(manifest_text)
    require(type(manifest) is dict and set(manifest) == {
        "schema_version", "landing_id", "gateway_server_name", "ssh_private_key_file",
        "gateway_password_file", "gateway_ca_certificate_file",
        "gateway_certificate_file", "gateway_private_key_file"
    })
    landing_id = manifest.get("landing_id")
    server_name = manifest.get("gateway_server_name")
    require(type(manifest.get("schema_version")) is int and
            manifest["schema_version"] == credential_schema)
    require(type(landing_id) is str and re.fullmatch(r"[a-z][a-z0-9-]{0,31}", landing_id) is not None)
    require(type(server_name) is str and valid_dns_name(server_name))
    require(manifest_path == os.path.join(controller_secret_dir, f"landing-{landing_id}.json"))
    expected_secret_directory = os.path.join(controller_secret_dir, f"landing-{landing_id}")
    expected_secret_paths = {
        "ssh_private_key_file": os.path.join(expected_secret_directory, "ssh-ed25519"),
        "gateway_password_file": os.path.join(expected_secret_directory, "gateway-password"),
        "gateway_ca_certificate_file": os.path.join(expected_secret_directory, "gateway-ca.crt"),
        "gateway_certificate_file": os.path.join(expected_secret_directory, "gateway.crt"),
        "gateway_private_key_file": os.path.join(expected_secret_directory, "gateway.key"),
    }
    require(all(type(manifest.get(name)) is str and manifest[name] == expected
                for name, expected in expected_secret_paths.items()))
    checkpoint("before_secret_read", stop_stage)
    password = read_private_text(manifest["gateway_password_file"], 512)
    ca_certificate = read_private_text(manifest["gateway_ca_certificate_file"], maximum_bytes)
    certificate = read_private_text(manifest["gateway_certificate_file"], maximum_bytes)
    private_key = read_private_text(manifest["gateway_private_key_file"], maximum_bytes)
    checkpoint("sources_read", stop_stage)

    gateway = {
        "listen_port": gateway_port,
        "server_name": server_name,
        "password": password,
        "allowed_entry_ipv4": allowed_entry_ipv4,
        "ca_certificate_pem": ca_certificate,
        "certificate_pem": certificate,
        "private_key_pem": private_key,
    }
    checkpoint("gateway_assembled", stop_stage)
    canonical_gateway = json.dumps(
        gateway, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8") + b"\n"
    digest = hashlib.sha256(canonical_gateway).hexdigest()
    package = {
        "schema_version": schema,
        "landing_id": landing_id,
        "revision": revision,
        "issued_at": issued_at,
        "expires_at": expires_at,
        "nonce": nonce,
        "content_sha256": digest,
        "gateway": gateway,
    }
    payload = json.dumps(package, ensure_ascii=False, indent=2).encode("utf-8") + b"\n"
    require(0 < len(payload) <= maximum_bytes)

    output_directory = os.path.dirname(output_path) or "."
    basename = os.path.basename(output_path)
    require(basename not in {"", ".", ".."} and "/" not in basename)
    directory_flags = os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        directory_flags |= os.O_NOFOLLOW
    directory_fd = os.open(output_directory, directory_flags)
    anonymous_fd = -1
    published = False
    anonymous_metadata = None
    try:
        directory_metadata = os.fstat(directory_fd)
        require(stat.S_ISDIR(directory_metadata.st_mode))
        require(directory_metadata.st_uid == os.geteuid())
        require(stat.S_IMODE(directory_metadata.st_mode) == 0o700)
        try:
            os.stat(basename, dir_fd=directory_fd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise BuildFailure()
        if unsupported_stage == "directory_fsync":
            raise AnonymousPublishingUnsupported()
        safe_fsync(directory_fd)
        if unsupported_stage == "anonymous_open":
            raise AnonymousPublishingUnsupported()
        anonymous_fd = anonymous_open(directory_fd)
        os.fchmod(anonymous_fd, 0o600)
        anonymous_metadata = os.fstat(anonymous_fd)
        require(stat.S_ISREG(anonymous_metadata.st_mode))
        require(anonymous_metadata.st_uid == os.geteuid())
        require(stat.S_IMODE(anonymous_metadata.st_mode) == 0o600)
        require(anonymous_metadata.st_nlink == 0)
        midpoint = max(1, len(payload) // 2)
        write_all(anonymous_fd, payload[:midpoint])
        checkpoint("package_write_started", stop_stage)
        write_all(anonymous_fd, payload[midpoint:])
        checkpoint("package_written", stop_stage)
        checkpoint("before_validation", stop_stage)
        stored_payload = read_all(anonymous_fd, maximum_bytes)
        require(stored_payload == payload)
        validate_tls_snapshot(
            libc, openssl_path, ca_certificate, certificate, private_key,
            server_name, stop_stage
        )
        validate_package(
            stored_payload, gateway, landing_id, schema, revision, issued_at, expires_at,
            nonce, maximum_bytes, maximum_ttl, clock_skew
        )
        checkpoint("after_validation", stop_stage)
        if unsupported_stage == "file_fsync":
            raise AnonymousPublishingUnsupported()
        safe_fsync(anonymous_fd)
        checkpoint("after_file_sync", stop_stage)
        anonymous_metadata = os.fstat(anonymous_fd)
        require(anonymous_metadata.st_nlink == 0)
        require(anonymous_metadata.st_size == len(payload))
        try:
            os.stat(basename, dir_fd=directory_fd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise BuildFailure()
        checkpoint("before_publish", stop_stage)
        if unsupported_stage == "link":
            raise AnonymousPublishingUnsupported()
        link_method = link_anonymous(
            libc, anonymous_fd, directory_fd, basename, forced_link_method
        )
        published = True
        require(not expected_link_method or link_method == expected_link_method)
        checkpoint("after_publish", stop_stage)
        target_metadata = os.stat(basename, dir_fd=directory_fd, follow_symlinks=False)
        require(stat.S_ISREG(target_metadata.st_mode))
        require(target_metadata.st_uid == os.geteuid())
        require(stat.S_IMODE(target_metadata.st_mode) == 0o600)
        require(target_metadata.st_nlink == 1)
        require(target_metadata.st_size == len(payload))
        require((target_metadata.st_dev, target_metadata.st_ino) == (
            anonymous_metadata.st_dev, anonymous_metadata.st_ino
        ))
        safe_fsync(anonymous_fd)
        safe_fsync(directory_fd)
        checkpoint("after_directory_sync", stop_stage)
    except BaseException:
        if published and anonymous_metadata is not None:
            unlink_published_if_owned(directory_fd, basename, anonymous_metadata)
        raise
    finally:
        if anonymous_fd >= 0:
            os.close(anonymous_fd)
        os.close(directory_fd)


try:
    main()
except AnonymousPublishingUnsupported:
    os._exit(UNSUPPORTED_STATUS)
except BaseException as error:
    emit_test_diagnostic(error)
    os._exit(1)
PY
  then
    helper_rc=0
  else
    helper_rc=$?
  fi
  if ((helper_rc == 73)); then
    printf '错误：当前文件系统不支持安全的匿名 apply package 发布，已拒绝生成。\n' >&2
    return 1
  fi
  ((helper_rc == 0)) || return 1
  if ! landing_apply_package_json_is_valid "$output" ||
     ! landing_apply_package_is_fresh "$output" "$issued_at"; then
    if [[ "$test_diagnostics" == true ]]; then
      printf 'landing apply helper test diagnostic: shell-post-validation\n' >&2
    fi
    rm -f -- "$output"
    sync_transaction_path "$output_dir" || true
    return 1
  fi
  controller_state_file_is_trusted "$output"
}

validate_landing_receipt_json() {
  local receipt="$1"
  jq -e -s 'length == 1' "$receipt" >/dev/null || return 1
  jq -e --argjson schema "$LANDING_RECEIPT_SCHEMA_VERSION" '
    type == "object" and
    (keys | sort) == [
      "applied_revision", "content_sha256", "emergency_override", "landing_id",
      "nonce", "role", "schema_version"
    ] and
    .schema_version == $schema and
    .role == "managed-landing" and
    (.landing_id | type == "string" and test("^[a-z][a-z0-9-]{0,31}$")) and
    (.applied_revision | type == "number" and . == floor and . >= 0 and . <= 9007199254740991) and
    (.emergency_override | type == "boolean") and
    (if .applied_revision == 0 then
       .content_sha256 == null and .nonce == null
     else
       (.content_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
       (.nonce | type == "string" and test("^[0-9a-f]{64}$"))
     end)
  ' "$receipt" >/dev/null
}

validate_landing_receipt_file() {
  local receipt="${1:-$LANDING_RECEIPT_FILE}"
  controller_state_file_is_trusted "$receipt" || return 1
  validate_landing_receipt_json "$receipt"
}

with_landing_receipt_lock() {
  local callback="$1" lock_dir rc
  shift
  lock_dir="$(dirname "$LANDING_RECEIPT_LOCK_FILE")"
  ensure_controller_private_directory "$lock_dir" || return 1
  [[ ! -L "$LANDING_RECEIPT_LOCK_FILE" ]] || return 1
  exec 6>"$LANDING_RECEIPT_LOCK_FILE" || return 1
  flock -x -w "$LANDING_RECEIPT_LOCK_TIMEOUT" 6 || { exec 6>&-; return 1; }
  "$callback" "$@" 6>&- && rc=0 || rc=$?
  flock -u 6 2>/dev/null || true
  exec 6>&-
  return "$rc"
}

init_landing_receipt_unlocked() {
  local landing_id="$1" state_dir tmp
  landing_id_is_valid "$landing_id" || return 1
  state_dir="$(dirname "$LANDING_RECEIPT_FILE")"
  ensure_controller_private_directory "$state_dir" || return 1
  if [[ -e "$LANDING_RECEIPT_FILE" || -L "$LANDING_RECEIPT_FILE" ]]; then
    validate_landing_receipt_file "$LANDING_RECEIPT_FILE" || return 1
    [[ "$(jq -r '.landing_id' "$LANDING_RECEIPT_FILE")" == "$landing_id" ]]
    return
  fi
  tmp="$(mktemp "$state_dir/.landing-receipt.XXXXXX")" || return 1
  register_temp_path "$tmp" || { rm -f -- "$tmp"; return 1; }
  if ! jq -n --argjson schema "$LANDING_RECEIPT_SCHEMA_VERSION" --arg landing_id "$landing_id" '
      {
        schema_version: $schema,
        role: "managed-landing",
        landing_id: $landing_id,
        applied_revision: 0,
        content_sha256: null,
        nonce: null,
        emergency_override: false
      }
    ' > "$tmp" ||
     ! chmod 600 "$tmp" ||
     ! validate_landing_receipt_json "$tmp" ||
     ! sync_transaction_path "$tmp" ||
     ! mv -- "$tmp" "$LANDING_RECEIPT_FILE" ||
     ! sync_transaction_path "$state_dir"; then
    rm -f -- "$tmp"
    return 1
  fi
  validate_landing_receipt_file "$LANDING_RECEIPT_FILE"
}

init_landing_receipt() {
  with_landing_receipt_lock init_landing_receipt_unlocked "$1"
}

landing_apply_replay_decision() {
  local package="$1" receipt="${2:-$LANDING_RECEIPT_FILE}" now="${3:-$(date +%s)}"
  local package_landing receipt_landing package_revision applied_revision package_sha applied_sha
  local package_nonce applied_nonce emergency_override
  landing_apply_package_structure_is_valid "$package" || return 1
  validate_landing_receipt_file "$receipt" || return 1
  package_landing="$(jq -r '.landing_id' "$package")" || return 1
  receipt_landing="$(jq -r '.landing_id' "$receipt")" || return 1
  [[ "$package_landing" == "$receipt_landing" ]] || return 1
  emergency_override="$(jq -r '.emergency_override' "$receipt")" || return 1
  [[ "$emergency_override" == false ]] || return 1
  package_revision="$(jq -r '.revision' "$package")" || return 1
  applied_revision="$(jq -r '.applied_revision' "$receipt")" || return 1
  package_sha="$(jq -r '.content_sha256' "$package")" || return 1
  applied_sha="$(jq -r '.content_sha256 // ""' "$receipt")" || return 1
  package_nonce="$(jq -r '.nonce' "$package")" || return 1
  applied_nonce="$(jq -r '.nonce // ""' "$receipt")" || return 1
  if ((10#$package_revision == 10#$applied_revision)) &&
     [[ "$package_sha" == "$applied_sha" && "$applied_revision" != 0 ]]; then
    printf 'idempotent\n'
    return 0
  fi
  ((10#$package_revision > 10#$applied_revision)) || return 1
  [[ -z "$applied_nonce" || "$package_nonce" != "$applied_nonce" ]] || return 1
  landing_apply_package_is_fresh "$package" "$now" || return 1
  printf 'apply\n'
}

commit_landing_apply_receipt_unlocked() {
  local package="$1" receipt="$2" now="$3" decision tmp state_dir
  local package_revision package_sha package_nonce
  decision="$(landing_apply_replay_decision "$package" "$receipt" "$now")" || return 1
  [[ "$decision" == apply ]] || [[ "$decision" == idempotent ]]
  [[ "$decision" == apply ]] || return 0
  package_revision="$(jq -r '.revision' "$package")" || return 1
  package_sha="$(jq -r '.content_sha256' "$package")" || return 1
  package_nonce="$(jq -r '.nonce' "$package")" || return 1
  state_dir="$(dirname "$receipt")"
  ensure_controller_private_directory "$state_dir" || return 1
  tmp="$(mktemp "$state_dir/.landing-receipt.XXXXXX")" || return 1
  register_temp_path "$tmp" || { rm -f -- "$tmp"; return 1; }
  if ! jq \
      --argjson revision "$package_revision" \
      --arg content_sha256 "$package_sha" \
      --arg nonce "$package_nonce" '
        .applied_revision = $revision |
        .content_sha256 = $content_sha256 |
        .nonce = $nonce
      ' "$receipt" > "$tmp" ||
     ! chmod 600 "$tmp" ||
     ! validate_landing_receipt_json "$tmp" ||
     ! sync_transaction_path "$tmp" ||
     ! mv -- "$tmp" "$receipt" ||
     ! sync_transaction_path "$state_dir"; then
    rm -f -- "$tmp"
    return 1
  fi
  validate_landing_receipt_file "$receipt"
}

commit_landing_apply_receipt() {
  local package="$1" receipt="${2:-$LANDING_RECEIPT_FILE}" now="${3:-$(date +%s)}"
  [[ "$receipt" == "$LANDING_RECEIPT_FILE" ]] || return 1
  with_landing_receipt_lock commit_landing_apply_receipt_unlocked "$package" "$receipt" "$now"
}
# ============================================================
# v5 入口侧单落地秘密初始化（尚未接入菜单或角色安装）
# ============================================================

CONTROLLER_LANDING_CREDENTIAL_CA_DAYS=3650
CONTROLLER_LANDING_CREDENTIAL_GATEWAY_DAYS=825
CONTROLLER_LANDING_CREDENTIAL_PASSWORD_BYTES=32
if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]]; then
  CONTROLLER_LANDING_CREDENTIAL_OPENSSL_BIN="${SB_CONTROLLER_LANDING_CREDENTIAL_OPENSSL_BIN:-$(command -v openssl)}"
  CONTROLLER_LANDING_CREDENTIAL_SSH_KEYGEN_BIN="${SB_CONTROLLER_LANDING_CREDENTIAL_SSH_KEYGEN_BIN:-$(command -v ssh-keygen)}"
else
  CONTROLLER_LANDING_CREDENTIAL_OPENSSL_BIN=/usr/bin/openssl
  CONTROLLER_LANDING_CREDENTIAL_SSH_KEYGEN_BIN=/usr/bin/ssh-keygen
fi

controller_landing_credentials_runtime_is_safe() {
  [[ "$CONTROLLER_LANDING_CREDENTIAL_CA_DAYS" == 3650 &&
     "$CONTROLLER_LANDING_CREDENTIAL_GATEWAY_DAYS" == 825 &&
     "$CONTROLLER_LANDING_CREDENTIAL_PASSWORD_BYTES" == 32 ]] || return 1
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    [[ "$EUID" -eq 0 &&
       "$CONTROLLER_STATE_FILE" == /var/lib/sb-user-manager/controller-state.json &&
       "$CONTROLLER_SECRET_DIR" == /etc/sb-user-manager/controller-secrets &&
       "$CONTROLLER_STATE_LOCK_FILE" == /run/lock/sb-user-manager/controller-state.lock &&
       "$CONTROLLER_LANDING_CREDENTIAL_OPENSSL_BIN" == /usr/bin/openssl &&
       "$CONTROLLER_LANDING_CREDENTIAL_SSH_KEYGEN_BIN" == /usr/bin/ssh-keygen ]] || return 1
  fi
  [[ -x "$CONTROLLER_LANDING_CREDENTIAL_OPENSSL_BIN" &&
     -x "$CONTROLLER_LANDING_CREDENTIAL_SSH_KEYGEN_BIN" ]]
}

controller_landing_credentials_dependencies_are_ready() {
  [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]] && return 0
  local dependency dependency_name
  for dependency_name in awk chmod chown dirname flock grep install jq mktemp mv python3 \
    readlink rm rmdir sha256sum ssh-keygen stat sync tr wc; do
    dependency="$(command -v "$dependency_name")" || return 1
    [[ "$dependency" == /* ]] || return 1
    landing_channel_root_executable_is_safe "$dependency" || return 1
  done
  landing_channel_root_executable_is_safe "$CONTROLLER_LANDING_CREDENTIAL_OPENSSL_BIN"
}

controller_landing_credentials_test_checkpoint() {
  local stage="$1"
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true &&
        "${SB_CONTROLLER_LANDING_CREDENTIAL_TEST_STOP_STAGE:-}" == "$stage" ]]; then
    return 1
  fi
}

controller_landing_credentials_final_paths() {
  local landing_id="$1"
  landing_id_is_valid "$landing_id" || return 1
  CONTROLLER_LANDING_CREDENTIAL_DIRECTORY="$CONTROLLER_SECRET_DIR/landing-${landing_id}"
  CONTROLLER_LANDING_CREDENTIAL_MANIFEST="$CONTROLLER_SECRET_DIR/landing-${landing_id}.json"
  controller_secret_ref_is_valid "$landing_id" "$CONTROLLER_LANDING_CREDENTIAL_MANIFEST"
}

controller_landing_credentials_directory_has_exact_files() (
  local directory="$1" entry
  local -a entries=()
  controller_private_directory_is_trusted "$directory" || return 1
  shopt -s nullglob dotglob
  entries=("$directory"/*)
  ((${#entries[@]} == 5)) || return 1
  for entry in "${entries[@]}"; do
    [[ -f "$entry" && ! -L "$entry" ]] || return 1
    case "${entry##*/}" in
      ssh-ed25519|gateway-password|gateway-ca.crt|gateway.crt|gateway.key) ;;
      *) return 1 ;;
    esac
  done
)

controller_landing_credentials_material_is_valid() {
  local landing_id="$1" server_name="$2" directory="$3"
  local ssh_key password ca_certificate certificate private_key ssh_public_key path
  landing_id_is_valid "$landing_id" || return 1
  controller_dns_name_is_valid "$server_name" || return 1
  controller_landing_credentials_directory_has_exact_files "$directory" || return 1
  ssh_key="$directory/ssh-ed25519"
  password="$directory/gateway-password"
  ca_certificate="$directory/gateway-ca.crt"
  certificate="$directory/gateway.crt"
  private_key="$directory/gateway.key"
  for path in "$ssh_key" "$password" "$ca_certificate" "$certificate" "$private_key"; do
    controller_state_file_is_trusted "$path" || return 1
  done
  ssh_public_key="$("$CONTROLLER_LANDING_CREDENTIAL_SSH_KEYGEN_BIN" -y -P '' \
    -f "$ssh_key" 2>/dev/null)" || return 1
  [[ "$ssh_public_key" == ssh-ed25519\ * ]] || return 1
  jq -e -Rs 'length >= 32 and length <= 128 and test("^[A-Za-z0-9_-]+$")' \
    "$password" >/dev/null || return 1
  validate_controller_tls_material "$ca_certificate" "$certificate" "$private_key" \
    "$server_name"
}

controller_landing_credentials_work_directory_is_owned() (
  local landing_id="$1" directory="$2" name entry uid mode expected_uid
  local -a entries=()
  landing_id_is_valid "$landing_id" || return 1
  [[ "$(dirname -- "$directory")" == "$CONTROLLER_SECRET_DIR" ]] || return 1
  name="${directory##*/}"
  [[ "$name" =~ ^\.landing-credentials\.${landing_id}\.[A-Za-z0-9]{10}$ ]] || return 1
  controller_private_directory_is_trusted "$directory" || return 1
  expected_uid="$(controller_state_expected_uid)" || return 1
  shopt -s nullglob dotglob
  entries=("$directory"/*)
  for entry in "${entries[@]}"; do
    [[ -f "$entry" && ! -L "$entry" ]] || return 1
    case "${entry##*/}" in
      ssh-ed25519|ssh-ed25519.pub|gateway-password|gateway-ca.crt|gateway.crt|gateway.key|\
      ca.conf|ca.key|gateway.conf|gateway.csr|ca.srl) ;;
      *) return 1 ;;
    esac
    uid="$(manager_file_uid "$entry")" || return 1
    mode="$(manager_file_mode "$entry")" || return 1
    [[ "$uid" == "$expected_uid" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 0022) == 0 )) || return 1
  done
)

controller_landing_remove_credentials_work_directory() {
  local landing_id="$1" directory="$2"
  controller_landing_credentials_work_directory_is_owned "$landing_id" "$directory" || return 1
  rm -f -- \
    "$directory/ssh-ed25519" "$directory/ssh-ed25519.pub" \
    "$directory/gateway-password" "$directory/gateway-ca.crt" \
    "$directory/gateway.crt" "$directory/gateway.key" \
    "$directory/ca.conf" "$directory/ca.key" "$directory/gateway.conf" \
    "$directory/gateway.csr" "$directory/ca.srl" || return 1
  rmdir -- "$directory" || return 1
  sync_transaction_path "$CONTROLLER_SECRET_DIR"
}

controller_landing_manifest_temp_is_owned() {
  local landing_id="$1" path="$2" name uid mode expected_uid
  landing_id_is_valid "$landing_id" || return 1
  [[ "$(dirname -- "$path")" == "$CONTROLLER_SECRET_DIR" ]] || return 1
  name="${path##*/}"
  [[ "$name" =~ ^\.landing-manifest\.${landing_id}\.[A-Za-z0-9]{10}$ &&
     -f "$path" && ! -L "$path" ]] || return 1
  uid="$(manager_file_uid "$path")" || return 1
  mode="$(manager_file_mode "$path")" || return 1
  expected_uid="$(controller_state_expected_uid)" || return 1
  [[ "$uid" == "$expected_uid" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0077) == 0 ))
}

controller_landing_credentials_cleanup_staging() (
  local landing_id="$1" path
  local -a work_directories=() manifest_files=()
  landing_id_is_valid "$landing_id" || return 1
  shopt -s nullglob
  work_directories=("$CONTROLLER_SECRET_DIR/.landing-credentials.${landing_id}."*)
  manifest_files=("$CONTROLLER_SECRET_DIR/.landing-manifest.${landing_id}."*)
  shopt -u nullglob
  if ((${#work_directories[@]} > 0)); then
    for path in "${work_directories[@]}"; do
      controller_landing_remove_credentials_work_directory "$landing_id" "$path" || return 1
    done
  fi
  if ((${#manifest_files[@]} > 0)); then
    for path in "${manifest_files[@]}"; do
      controller_landing_manifest_temp_is_owned "$landing_id" "$path" || return 1
      rm -f -- "$path" || return 1
    done
  fi
  sync_transaction_path "$CONTROLLER_SECRET_DIR"
)

controller_landing_credentials_prepare_private_file() {
  local path="$1"
  chmod 600 "$path" || return 1
  if [[ "$EUID" -eq 0 && "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    chown root:root "$path" || return 1
  fi
  controller_state_file_is_trusted "$path"
}

controller_landing_generate_credentials_in_work() {
  local landing_id="$1" server_name="$2" work="$3"
  controller_private_directory_is_trusted "$work" || return 1
  controller_dns_name_is_valid "$server_name" || return 1
  (umask 077 && printf '%s\n' \
    '[req]' 'distinguished_name=dn' 'x509_extensions=v3_ca' 'prompt=no' \
    '[dn]' 'CN=sb-user-manager managed landing CA' \
    '[v3_ca]' 'basicConstraints=critical,CA:TRUE' \
    'keyUsage=critical,keyCertSign,cRLSign' > "$work/ca.conf") || return 1
  (umask 077 && {
    printf '%s\n' \
      '[req]' 'distinguished_name=dn' 'req_extensions=req_ext' 'prompt=no' \
      '[dn]' 'CN=sb-user-manager managed landing gateway' \
      '[req_ext]' "subjectAltName=DNS:${server_name}" \
      'basicConstraints=critical,CA:FALSE' \
      'keyUsage=critical,digitalSignature,keyEncipherment' \
      'extendedKeyUsage=serverAuth'
  } > "$work/gateway.conf") || return 1
  "$CONTROLLER_LANDING_CREDENTIAL_SSH_KEYGEN_BIN" -q -t ed25519 -N '' -C '' \
    -f "$work/ssh-ed25519" >/dev/null 2>&1 || return 1
  "$CONTROLLER_LANDING_CREDENTIAL_OPENSSL_BIN" rand -hex \
    "$CONTROLLER_LANDING_CREDENTIAL_PASSWORD_BYTES" 2>/dev/null |
    tr -d '\n' > "$work/gateway-password" || return 1
  "$CONTROLLER_LANDING_CREDENTIAL_OPENSSL_BIN" req -x509 -newkey rsa:2048 -sha256 \
    -nodes -days "$CONTROLLER_LANDING_CREDENTIAL_CA_DAYS" -config "$work/ca.conf" \
    -keyout "$work/ca.key" -out "$work/gateway-ca.crt" >/dev/null 2>&1 || return 1
  "$CONTROLLER_LANDING_CREDENTIAL_OPENSSL_BIN" req -newkey rsa:2048 -sha256 -nodes \
    -config "$work/gateway.conf" -keyout "$work/gateway.key" \
    -out "$work/gateway.csr" >/dev/null 2>&1 || return 1
  "$CONTROLLER_LANDING_CREDENTIAL_OPENSSL_BIN" x509 -req -sha256 \
    -days "$CONTROLLER_LANDING_CREDENTIAL_GATEWAY_DAYS" \
    -in "$work/gateway.csr" -CA "$work/gateway-ca.crt" -CAkey "$work/ca.key" \
    -CAserial "$work/ca.srl" -CAcreateserial -out "$work/gateway.crt" \
    -extfile "$work/gateway.conf" \
    -extensions req_ext >/dev/null 2>&1 || return 1
  chmod 600 "$work/ssh-ed25519" "$work/ssh-ed25519.pub" \
    "$work/gateway-password" "$work/gateway-ca.crt" "$work/gateway.crt" \
    "$work/gateway.key" "$work/ca.conf" "$work/ca.key" "$work/gateway.conf" \
    "$work/gateway.csr" "$work/ca.srl" || return 1
  rm -f -- "$work/ssh-ed25519.pub" "$work/ca.conf" "$work/ca.key" \
    "$work/gateway.conf" "$work/gateway.csr" "$work/ca.srl" || return 1
  controller_landing_credentials_material_is_valid "$landing_id" "$server_name" "$work"
}

controller_landing_write_credentials_manifest() {
  local landing_id="$1" server_name="$2" directory="$3" manifest="$4"
  local tmp
  [[ ! -e "$manifest" && ! -L "$manifest" ]] || return 1
  controller_landing_credentials_material_is_valid "$landing_id" "$server_name" \
    "$directory" || return 1
  tmp="$(mktemp "$CONTROLLER_SECRET_DIR/.landing-manifest.${landing_id}.XXXXXXXXXX")" || return 1
  register_temp_path "$tmp"
  if ! SB_LANDING_CREDENTIAL_SERVER_NAME="$server_name" jq -n \
      --argjson schema "$LANDING_CREDENTIAL_SCHEMA_VERSION" \
      --arg landing_id "$landing_id" \
      --arg ssh_key "$directory/ssh-ed25519" \
      --arg password "$directory/gateway-password" \
      --arg ca "$directory/gateway-ca.crt" \
      --arg certificate "$directory/gateway.crt" \
      --arg private_key "$directory/gateway.key" '
        {
          schema_version:$schema,
          landing_id:$landing_id,
          gateway_server_name:$ENV.SB_LANDING_CREDENTIAL_SERVER_NAME,
          ssh_private_key_file:$ssh_key,
          gateway_password_file:$password,
          gateway_ca_certificate_file:$ca,
          gateway_certificate_file:$certificate,
          gateway_private_key_file:$private_key
        }
      ' > "$tmp" ||
     ! controller_landing_credentials_prepare_private_file "$tmp" ||
     ! validate_landing_credential_manifest_json "$tmp" ||
     ! sync_transaction_path "$tmp" ||
     ! controller_landing_credentials_test_checkpoint before_manifest_publish ||
     ! mv -- "$tmp" "$manifest" ||
     ! sync_transaction_path "$CONTROLLER_SECRET_DIR"; then
    if [[ -e "$tmp" || -L "$tmp" ]]; then
      if controller_landing_manifest_temp_is_owned "$landing_id" "$tmp"; then
        rm -f -- "$tmp" || true
      fi
    fi
    return 1
  fi
  validate_landing_credential_manifest "$manifest"
}

controller_initialize_landing_credentials_unlocked() {
  local landing_id="$1" server_name="$2" directory manifest work=""
  validate_controller_state_file "$CONTROLLER_STATE_FILE" || return 1
  jq -e --arg landing_id "$landing_id" \
    'all(.landings[]; .id != $landing_id)' "$CONTROLLER_STATE_FILE" >/dev/null || return 1
  controller_landing_credentials_final_paths "$landing_id" || return 1
  directory="$CONTROLLER_LANDING_CREDENTIAL_DIRECTORY"
  manifest="$CONTROLLER_LANDING_CREDENTIAL_MANIFEST"
  controller_landing_credentials_cleanup_staging "$landing_id" || return 1

  if [[ -e "$manifest" || -L "$manifest" ]]; then
    [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
    validate_landing_credential_manifest "$manifest" || return 1
    [[ "$(jq -r '.gateway_server_name' "$manifest")" == "$server_name" ]] || return 1
    printf '%s\n' "$manifest"
    return
  fi
  if [[ -e "$directory" || -L "$directory" ]]; then
    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    controller_landing_credentials_material_is_valid "$landing_id" "$server_name" \
      "$directory" || return 1
    controller_landing_write_credentials_manifest "$landing_id" "$server_name" \
      "$directory" "$manifest" || return 1
    printf '%s\n' "$manifest"
    return
  fi

  work="$(mktemp -d "$CONTROLLER_SECRET_DIR/.landing-credentials.${landing_id}.XXXXXXXXXX")" || return 1
  chmod 700 "$work" || return 1
  register_temp_path "$work"
  controller_private_directory_is_trusted "$work" || return 1
  if ! controller_landing_credentials_test_checkpoint after_work_created ||
     ! controller_landing_generate_credentials_in_work "$landing_id" "$server_name" "$work" ||
     ! controller_landing_credentials_test_checkpoint after_material_generated; then
    controller_landing_remove_credentials_work_directory "$landing_id" "$work" || true
    return 1
  fi
  for path in "$work/ssh-ed25519" "$work/gateway-password" "$work/gateway-ca.crt" \
    "$work/gateway.crt" "$work/gateway.key"; do
    sync_transaction_path "$path" || {
      controller_landing_remove_credentials_work_directory "$landing_id" "$work" || true
      return 1
    }
  done
  sync_transaction_path "$work" || {
    controller_landing_remove_credentials_work_directory "$landing_id" "$work" || true
    return 1
  }
  mv -- "$work" "$directory" || {
    controller_landing_remove_credentials_work_directory "$landing_id" "$work" || true
    return 1
  }
  sync_transaction_path "$CONTROLLER_SECRET_DIR" || return 1
  controller_landing_credentials_test_checkpoint after_directory_published || return 1
  controller_landing_write_credentials_manifest "$landing_id" "$server_name" \
    "$directory" "$manifest" || return 1
  printf '%s\n' "$manifest"
}

controller_initialize_landing_credentials() {
  [[ $# -eq 2 ]] || return 64
  local landing_id="$1" server_name="$2"
  local PATH="${PATH:-}" LC_ALL="${LC_ALL:-}"
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    PATH=/usr/sbin:/usr/bin:/sbin:/bin
    LC_ALL=C
    export PATH LC_ALL
    unset BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH OPENSSL_CONF
  fi
  controller_landing_credentials_runtime_is_safe || return 1
  controller_landing_credentials_dependencies_are_ready || return 1
  landing_id_is_valid "$landing_id" || return 1
  controller_dns_name_is_valid "$server_name" || return 1
  validate_controller_state_file "$CONTROLLER_STATE_FILE" || return 1
  with_controller_state_lock controller_initialize_landing_credentials_unlocked \
    "$landing_id" "$server_name"
}

controller_remove_unregistered_landing_credentials_unlocked() {
  local landing_id="$1" server_name="$2" directory manifest manifest_sni
  validate_controller_state_file "$CONTROLLER_STATE_FILE" || return 1
  jq -e --arg landing_id "$landing_id" \
    'all(.landings[]; .id != $landing_id)' "$CONTROLLER_STATE_FILE" >/dev/null || return 1
  controller_landing_credentials_final_paths "$landing_id" || return 1
  directory="$CONTROLLER_LANDING_CREDENTIAL_DIRECTORY"
  manifest="$CONTROLLER_LANDING_CREDENTIAL_MANIFEST"
  controller_landing_credentials_cleanup_staging "$landing_id" || return 1
  if [[ ! -e "$manifest" && ! -L "$manifest" &&
        ! -e "$directory" && ! -L "$directory" ]]; then
    return 0
  fi
  [[ -d "$directory" && ! -L "$directory" ]] || return 1
  if [[ -e "$manifest" || -L "$manifest" ]]; then
    [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
    validate_landing_credential_manifest "$manifest" || return 1
    manifest_sni="$(jq -r '.gateway_server_name' "$manifest")" || return 1
    [[ "$manifest_sni" == "$server_name" ]] || return 1
  fi
  controller_landing_credentials_material_is_valid "$landing_id" "$server_name" \
    "$directory" || return 1
  if [[ -e "$manifest" ]]; then
    rm -f -- "$manifest" || return 1
    sync_transaction_path "$CONTROLLER_SECRET_DIR" || return 1
  fi
  rm -f -- "$directory/ssh-ed25519" "$directory/gateway-password" \
    "$directory/gateway-ca.crt" "$directory/gateway.crt" \
    "$directory/gateway.key" || return 1
  rmdir -- "$directory" || return 1
  sync_transaction_path "$CONTROLLER_SECRET_DIR"
}

controller_remove_unregistered_landing_credentials() {
  [[ $# -eq 2 ]] || return 64
  local landing_id="$1" server_name="$2"
  local PATH="${PATH:-}" LC_ALL="${LC_ALL:-}"
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    PATH=/usr/sbin:/usr/bin:/sbin:/bin
    LC_ALL=C
    export PATH LC_ALL
    unset BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH OPENSSL_CONF
  fi
  controller_landing_credentials_runtime_is_safe || return 1
  controller_landing_credentials_dependencies_are_ready || return 1
  landing_id_is_valid "$landing_id" || return 1
  controller_dns_name_is_valid "$server_name" || return 1
  validate_controller_state_file "$CONTROLLER_STATE_FILE" || return 1
  with_controller_state_lock controller_remove_unregistered_landing_credentials_unlocked \
    "$landing_id" "$server_name"
}
# ============================================================
# v5 入口侧受管落地注册（尚未接入菜单、角色安装或 root 引导）
# ============================================================

CONTROLLER_LANDING_PROBE_ERROR_CODE=invalid_input

controller_landing_display_name_is_valid() {
  local value="$1"
  jq -en --arg value "$value" '
    $value | type == "string" and length >= 1 and length <= 64 and
    (test("[[:cntrl:]]") | not)
  ' >/dev/null
}

controller_landing_registration_inputs_are_valid() {
  local landing_id="$1" display_name="$2" address="$3" ssh_port="$4"
  local expected_fingerprint="$5" gateway_port="$6"
  landing_id_is_valid "$landing_id" || return 1
  controller_landing_display_name_is_valid "$display_name" || return 1
  controller_landing_address_is_valid "$address" || return 1
  landing_port_is_valid "$ssh_port" || return 1
  [[ "$expected_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || return 1
  landing_port_is_valid "$gateway_port" || return 1
  ((10#$ssh_port != 10#$gateway_port))
}

controller_landing_registration_manifest() {
  local landing_id="$1" manifest
  landing_id_is_valid "$landing_id" || return 1
  manifest="$CONTROLLER_SECRET_DIR/landing-${landing_id}.json"
  controller_secret_ref_is_valid "$landing_id" "$manifest" || return 1
  validate_landing_credential_manifest "$manifest" || return 1
  [[ "$(jq -r '.landing_id' "$manifest")" == "$landing_id" ]] || return 1
  printf '%s\n' "$manifest"
}

controller_landing_discover_fingerprint() {
  [[ $# -eq 2 ]] || return 64
  local address="$1" ssh_port="$2" work fingerprint rc=1
  controller_landing_transport_runtime_is_safe || return 1
  controller_landing_address_is_valid "$address" || return 1
  landing_port_is_valid "$ssh_port" || return 1
  work="$(controller_landing_create_work_directory)" || return 1
  register_temp_path "$work" || {
    controller_landing_remove_work_directory "$work" || true
    return 1
  }
  if fingerprint="$(controller_landing_scan_ed25519_fingerprint \
      "$address" "$ssh_port" "$work")"; then
    rc=0
  fi
  controller_landing_remove_work_directory "$work" || rc=1
  ((rc == 0)) || return "$rc"
  printf '%s\n' "$fingerprint"
}

controller_landing_probe_restricted_channel_in_work() (
  local landing_id="$1" address="$2" ssh_port="$3" expected_fingerprint="$4"
  local private_key="$5" work="$6" known_hosts probe_input response_file ssh_status
  landing_id_is_valid "$landing_id" || return 1
  controller_landing_address_is_valid "$address" || return 1
  landing_port_is_valid "$ssh_port" || return 1
  [[ "$expected_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || return 1
  controller_landing_ssh_private_key_is_valid "$private_key" || return 1
  controller_private_directory_is_trusted "$work" || return 1

  known_hosts="$(controller_landing_prepare_known_hosts "$address" "$ssh_port" \
    "$expected_fingerprint" "sb-landing-$landing_id" "$work")" || return 1
  probe_input="$work/probe-input"
  response_file="$work/probe-response.json"
  [[ ! -e "$probe_input" && ! -L "$probe_input" &&
     ! -e "$response_file" && ! -L "$response_file" ]] || return 1
  (umask 077 && : > "$probe_input") || return 1
  controller_landing_private_file_is_trusted "$probe_input" || return 1
  exec 9< "$probe_input" || return 1
  rm -f -- "$probe_input" || { exec 9<&-; return 1; }

  if controller_landing_ssh_exchange "$address" "$ssh_port" "$landing_id" \
      "$private_key" "$known_hosts" "$expected_fingerprint" 9 "$response_file"; then
    exec 9<&-
    return 1
  fi
  exec 9<&-
  ssh_status="$CONTROLLER_LANDING_LAST_SSH_STATUS"
  [[ "$ssh_status" =~ ^[0-9]+$ ]] || return 1
  ((ssh_status != 0)) || return 1
  controller_landing_response_file_is_safe "$response_file" "$ssh_status" || return 1
  jq -e --arg code "$CONTROLLER_LANDING_PROBE_ERROR_CODE" '
    . == {status:"error", code:$code}
  ' "$response_file" >/dev/null 2>&1
)

controller_test_landing_registration_channel() {
  [[ $# -eq 4 ]] || return 64
  local landing_id="$1" address="$2" ssh_port="$3" expected_fingerprint="$4"
  local manifest private_key work rc=1
  controller_landing_transport_runtime_is_safe || return 1
  landing_id_is_valid "$landing_id" || return 1
  controller_landing_address_is_valid "$address" || return 1
  landing_port_is_valid "$ssh_port" || return 1
  [[ "$expected_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || return 1
  manifest="$(controller_landing_registration_manifest "$landing_id")" || return 1
  private_key="$(jq -r '.ssh_private_key_file' "$manifest")" || return 1
  controller_landing_ssh_private_key_is_valid "$private_key" || return 1
  work="$(controller_landing_create_work_directory)" || return 1
  register_temp_path "$work" || {
    controller_landing_remove_work_directory "$work" || true
    return 1
  }
  if controller_landing_probe_restricted_channel_in_work "$landing_id" "$address" \
      "$ssh_port" "$expected_fingerprint" "$private_key" "$work"; then
    rc=0
  fi
  controller_landing_remove_work_directory "$work" || rc=1
  return "$rc"
}

controller_register_landing() {
  [[ $# -eq 6 ]] || return 64
  local landing_id="$1" display_name="$2" address="$3" ssh_port="$4"
  local expected_fingerprint="$5" gateway_port="$6" manifest
  controller_landing_registration_inputs_are_valid "$landing_id" "$display_name" \
    "$address" "$ssh_port" "$expected_fingerprint" "$gateway_port" || return 1
  manifest="$(controller_landing_registration_manifest "$landing_id")" || return 1
  controller_test_landing_registration_channel "$landing_id" "$address" "$ssh_port" \
    "$expected_fingerprint" || return 1
  init_controller_state || return 1
  ssh_port=$((10#$ssh_port))
  gateway_port=$((10#$gateway_port))
  atomic_controller_state_update '
    if ([.landings[] | select(
      .id == $landing_id or
      (.address == $address and .ssh_port == $ssh_port) or
      .credential_ref == $credential_ref
    )] | length) != 0 then
      error("landing identity already registered")
    elif .revision >= 9007199254740991 then
      error("controller revision exhausted")
    else
      .revision += 1 |
      .landings += [{
        id: $landing_id,
        display_name: $display_name,
        address: $address,
        ssh_port: $ssh_port,
        ssh_host_fingerprint: $fingerprint,
        gateway_port: $gateway_port,
        status: "pending",
        desired_revision: 1,
        applied_revision: 0,
        config_sha256: null,
        credential_ref: $credential_ref
      }]
    end
  ' --arg landing_id "$landing_id" --arg display_name "$display_name" \
    --arg address "$address" --argjson ssh_port "$ssh_port" \
    --arg fingerprint "$expected_fingerprint" --argjson gateway_port "$gateway_port" \
    --arg credential_ref "$manifest"
}

controller_register_and_apply_landing() {
  [[ $# -eq 7 ]] || return 64
  local landing_id="$1" display_name="$2" address="$3" ssh_port="$4"
  local expected_fingerprint="$5" gateway_port="$6" allowed_entry_ipv4="$7"
  is_ipv4_address "$allowed_entry_ipv4" || return 1
  controller_register_landing "$landing_id" "$display_name" "$address" "$ssh_port" \
    "$expected_fingerprint" "$gateway_port" || return 1
  controller_apply_landing "$landing_id" "$allowed_entry_ipv4"
}
# ============================================================
# v5 受限落地 agent 与可回退 apply 引擎（尚未安装远程通道）
# ============================================================

LANDING_AGENT_HELPER_PATH=/usr/local/libexec/sb-user-manager-landing-apply
LANDING_SINGBOX_CONFIG_PATH=/etc/sing-box/config.json
LANDING_TLS_DIRECTORY=/etc/sing-box/landing
LANDING_CA_CERTIFICATE_PATH=/etc/sing-box/landing/gateway-ca.crt
LANDING_CERTIFICATE_PATH=/etc/sing-box/landing/gateway.crt
LANDING_PRIVATE_KEY_PATH=/etc/sing-box/landing/gateway.key
LANDING_NFTABLES_DIRECTORY=/etc/nftables.d
LANDING_NFTABLES_RULES_PATH=/etc/nftables.d/sb-user-manager-landing.nft
LANDING_SINGBOX_BINARY=/usr/local/bin/sing-box
LANDING_SINGBOX_SERVICE=sing-box
LANDING_NFTABLES_FAMILY=inet
LANDING_NFTABLES_TABLE=sb_user_manager_landing
LANDING_NFTABLES_CHAIN=ingress_guard
LANDING_AGENT_READ_TIMEOUT=15
LANDING_APPLY_TRANSACTION_SCHEMA_VERSION=1
LANDING_APPLY_TRANSACTION_DIRECTORY="${SB_LANDING_APPLY_TRANSACTION_DIRECTORY:-/var/lib/sb-user-manager/landing-apply-transaction}"
LANDING_APPLY_TRANSACTION_JOURNAL="$LANDING_APPLY_TRANSACTION_DIRECTORY/journal.json"

LANDING_ACTIVE_SNAPSHOT=""
LANDING_ACTIVE_RECEIPT_SNAPSHOT=""
LANDING_ACTIVE_TRANSACTION_ID=""
LANDING_ACTIVE_TRANSACTION_PHASE=""
LANDING_ACTIVE_WORK=""
LANDING_RESULT_STATUS=""
LANDING_RESULT_CODE=""
LANDING_RESULT_REVISION=""
LANDING_RESULT_SHA256=""
LANDING_APPLY_ERROR_CODE=""
LANDING_REQUESTED_GENERATION=""

landing_apply_expected_uid() {
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true && "$EUID" -ne 0 ]]; then
    printf '%s\n' "$EUID"
  else
    printf '0\n'
  fi
}

landing_managed_path() {
  local logical="$1"
  [[ "$logical" == /* ]] || return 1
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]]; then
    printf '%s%s' "${SB_SYSTEM_ROOT:-}" "$logical"
  else
    printf '%s' "$logical"
  fi
}

landing_directory_is_safe() {
  local path="$1" exact_mode="${2:-}" owner mode expected_owner
  [[ -d "$path" && ! -L "$path" ]] || return 1
  owner="$(manager_file_uid "$path")" || return 1
  expected_owner="$(landing_apply_expected_uid)"
  [[ "$owner" == "$expected_owner" ]] || return 1
  mode="$(manager_file_mode "$path")" || return 1
  [[ "$mode" =~ ^[0-7]{3}$ ]] || return 1
  if [[ -n "$exact_mode" ]]; then
    (( (8#$mode & 0777) == 8#$exact_mode ))
  else
    (( (8#$mode & 0700) == 0700 && (8#$mode & 0022) == 0 ))
  fi
}

landing_ensure_directory() {
  local path="$1" mode="$2"
  [[ "$path" == /* && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  if [[ -e "$path" || -L "$path" ]]; then
    [[ -d "$path" && ! -L "$path" ]] || return 1
    chmod "$mode" "$path" || return 1
  else
    install -d -m "$mode" -- "$path" || return 1
  fi
  landing_directory_is_safe "$path" "${mode#0}"
}

landing_ensure_system_directory() {
  local path="$1"
  [[ "$path" == /* ]] || return 1
  if [[ -e "$path" || -L "$path" ]]; then
    landing_directory_is_safe "$path"
    return
  fi
  install -d -m 755 -- "$path" || return 1
  landing_directory_is_safe "$path"
}

landing_managed_file_is_safe() {
  local path="$1" owner mode expected_owner
  [[ -f "$path" && ! -L "$path" ]] || return 1
  owner="$(manager_file_uid "$path")" || return 1
  expected_owner="$(landing_apply_expected_uid)"
  [[ "$owner" == "$expected_owner" ]] || return 1
  mode="$(manager_file_mode "$path")" || return 1
  [[ "$mode" =~ ^[0-7]{3}$ ]] || return 1
  (( 8#$mode == 0600 ))
}

landing_managed_target_is_safe() {
  local target="$1" parent
  [[ "$target" == /* ]] || return 1
  parent="$(dirname -- "$target")" || return 1
  landing_directory_is_safe "$parent" || return 1
  if [[ -e "$target" || -L "$target" ]]; then
    landing_managed_file_is_safe "$target"
  fi
}

landing_apply_runtime_paths_are_safe() {
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    [[ "$LANDING_RECEIPT_FILE" == /var/lib/sb-user-manager/landing-receipt.json &&
       "$LANDING_RECEIPT_LOCK_FILE" == /run/lock/sb-user-manager/landing-receipt.lock &&
       "$LANDING_APPLY_TRANSACTION_DIRECTORY" == /var/lib/sb-user-manager/landing-apply-transaction &&
       "$LANDING_APPLY_TRANSACTION_JOURNAL" == /var/lib/sb-user-manager/landing-apply-transaction/journal.json ]] || return 1
  fi
  [[ "$LANDING_AGENT_HELPER_PATH" == /usr/local/libexec/sb-user-manager-landing-apply &&
     "$LANDING_SINGBOX_CONFIG_PATH" == /etc/sing-box/config.json &&
     "$LANDING_TLS_DIRECTORY" == /etc/sing-box/landing &&
     "$LANDING_NFTABLES_RULES_PATH" == /etc/nftables.d/sb-user-manager-landing.nft &&
     "$LANDING_SINGBOX_BINARY" == /usr/local/bin/sing-box &&
     "$LANDING_SINGBOX_SERVICE" == sing-box &&
     "$LANDING_CHANNEL_GENERATION_PATH" == /var/lib/sb-user-manager-landing/.channel-generation &&
     "$LANDING_AGENT_READ_TIMEOUT" == 15 ]]
}

landing_apply_transaction_file_is_safe() {
  local path="$1" mode
  controller_state_file_is_trusted "$path" || return 1
  # BSD `stat -f %Lp` 会隐藏 setuid/setgid/sticky 位；这里必须读取完整权限。
  mode="$(stat -c '%a' -- "$path" 2>/dev/null || stat -f '%Mp%Lp' "$path" 2>/dev/null)" || return 1
  [[ "$mode" == 600 || "$mode" == 0600 ]]
}

landing_apply_transaction_layout_is_safe() (
  local directory="$LANDING_APPLY_TRANSACTION_DIRECTORY" parent entry name
  local -a entries
  parent="$(dirname -- "$directory")" || return 1
  controller_private_directory_is_trusted "$parent" || return 1
  landing_directory_is_safe "$directory" 700 || return 1
  shopt -s dotglob nullglob
  entries=("$directory"/* "")
  for entry in "${entries[@]}"; do
    [[ -n "$entry" ]] || continue
    name="${entry##*/}"
    case "$name" in
      snapshot|receipt-snapshot|.validation)
        landing_directory_is_safe "$entry" 700 || return 1
        ;;
      transaction.id|apply.json|gateway-ca.crt|gateway.crt|gateway.key|check-config.json|config.json|landing.nft|nft.rollback|\
      receipt.base.json|receipt.next.json|manifest.sha256|journal.json|.journal.next|.cleanup.next|\
      mutation.started|cleanup.started|runtime.drift|service.restart-attempted|\
      nft.apply-attempted|nft.rollback-attempted)
        landing_apply_transaction_file_is_safe "$entry" || return 1
        ;;
      *) return 1 ;;
    esac
  done

  if [[ -d "$directory/snapshot" && ! -L "$directory/snapshot" ]]; then
    entries=("$directory/snapshot"/* "")
    for entry in "${entries[@]}"; do
      [[ -n "$entry" ]] || continue
      name="${entry##*/}"
      case "$name" in
        config.json|config.json.state|gateway-ca.crt|gateway-ca.crt.state|\
        gateway.crt|gateway.crt.state|gateway.key|gateway.key.state|\
        landing.nft|landing.nft.state|nft-live|nft-live.state|service.state|directories.json)
          landing_apply_transaction_file_is_safe "$entry" || return 1
          ;;
        *) return 1 ;;
      esac
    done
  fi
  if [[ -d "$directory/receipt-snapshot" && ! -L "$directory/receipt-snapshot" ]]; then
    entries=("$directory/receipt-snapshot"/* "")
    for entry in "${entries[@]}"; do
      [[ -n "$entry" ]] || continue
      name="${entry##*/}"
      case "$name" in
        receipt.json|receipt.state)
          landing_apply_transaction_file_is_safe "$entry" || return 1
          ;;
        *) return 1 ;;
      esac
    done
  fi
  if [[ -d "$directory/.validation" && ! -L "$directory/.validation" ]]; then
    entries=("$directory/.validation"/* "")
    for entry in "${entries[@]}"; do
      [[ -n "$entry" ]] || continue
      name="${entry##*/}"
      case "$name" in
        ca.crt|gateway.crt|gateway.key)
          landing_apply_transaction_file_is_safe "$entry" || return 1
          ;;
        *) return 1 ;;
      esac
    done
  fi
)

landing_apply_remove_validation_directory() {
  local path="$LANDING_APPLY_TRANSACTION_DIRECTORY/.validation"
  [[ ! -e "$path" && ! -L "$path" ]] && return 0
  landing_directory_is_safe "$path" 700 || return 1
  landing_apply_transaction_layout_is_safe || return 1
  rm -rf -- "$path" || return 1
  sync_transaction_path "$LANDING_APPLY_TRANSACTION_DIRECTORY"
}

landing_apply_reset_active_transaction() {
  LANDING_ACTIVE_SNAPSHOT=""
  LANDING_ACTIVE_RECEIPT_SNAPSHOT=""
  LANDING_ACTIVE_TRANSACTION_ID=""
  LANDING_ACTIVE_TRANSACTION_PHASE=""
  LANDING_ACTIVE_WORK=""
  clear_signal_rollback
}

landing_apply_discard_transaction_directory() {
  local directory="$LANDING_APPLY_TRANSACTION_DIRECTORY" parent
  [[ ! -e "$directory" && ! -L "$directory" ]] && return 0
  landing_apply_transaction_layout_is_safe || return 1
  [[ ! -e "$LANDING_APPLY_TRANSACTION_JOURNAL" && ! -L "$LANDING_APPLY_TRANSACTION_JOURNAL" ]] || return 1
  if [[ -e "$directory/cleanup.started" || -L "$directory/cleanup.started" ]]; then
    landing_apply_cleanup_marker_without_journal_is_valid || return 1
  else
    [[ ! -e "$directory/mutation.started" && ! -L "$directory/mutation.started" &&
       ! -e "$directory/runtime.drift" && ! -L "$directory/runtime.drift" &&
       ! -e "$directory/service.restart-attempted" && ! -L "$directory/service.restart-attempted" &&
       ! -e "$directory/nft.apply-attempted" && ! -L "$directory/nft.apply-attempted" &&
       ! -e "$directory/nft.rollback-attempted" && ! -L "$directory/nft.rollback-attempted" ]] || return 1
  fi
  parent="$(dirname -- "$directory")" || return 1
  rm -rf -- "$directory" || return 1
  sync_transaction_path "$parent"
}

landing_apply_cleanup_terminal_transaction() {
  local context="${1:-runtime}" directory="$LANDING_APPLY_TRANSACTION_DIRECTORY" parent name phase
  landing_apply_transaction_layout_is_safe || return 1
  landing_apply_load_pending_transaction || return 1
  phase="$LANDING_ACTIVE_TRANSACTION_PHASE"
  [[ "$phase" == committed || "$phase" == rolled_back ]] || return 1
  landing_apply_terminal_receipt_is_valid "$phase" "$context" || return 1
  landing_apply_mark_cleanup_started || return 1
  rm -f -- "$LANDING_APPLY_TRANSACTION_JOURNAL" || return 1
  sync_transaction_path "$directory" || return 1
  for name in .validation snapshot receipt-snapshot; do
    [[ ! -e "$directory/$name" && ! -L "$directory/$name" ]] ||
      rm -rf -- "${directory:?}/$name" || return 1
  done
  for name in apply.json gateway-ca.crt gateway.crt gateway.key check-config.json config.json \
    landing.nft nft.rollback receipt.base.json receipt.next.json manifest.sha256 .journal.next \
    .cleanup.next mutation.started runtime.drift service.restart-attempted \
    nft.apply-attempted nft.rollback-attempted; do
    [[ ! -e "$directory/$name" && ! -L "$directory/$name" ]] ||
      rm -f -- "$directory/$name" || return 1
  done
  sync_transaction_path "$directory" || return 1
  rm -f -- "$directory/cleanup.started" || return 1
  sync_transaction_path "$directory" || return 1
  rm -f -- "$directory/transaction.id" || return 1
  sync_transaction_path "$directory" || return 1
  parent="$(dirname -- "$directory")" || return 1
  rmdir -- "$directory" || return 1
  sync_transaction_path "$parent" || return 1
  landing_apply_reset_active_transaction
}

landing_apply_begin_staging() {
  local directory="$LANDING_APPLY_TRANSACTION_DIRECTORY" parent transaction_id
  [[ ! -e "$directory" && ! -L "$directory" ]] || return 1
  parent="$(dirname -- "$directory")" || return 1
  ensure_controller_private_directory "$parent" || return 1
  transaction_id="$(python3 -I -c 'import secrets; print(secrets.token_hex(16))')" || return 1
  [[ "$transaction_id" =~ ^[0-9a-f]{32}$ ]] || return 1
  install -d -m 700 -- "$directory" || return 1
  landing_directory_is_safe "$directory" 700 || return 1
  if ! sync_transaction_path "$directory" || ! sync_transaction_path "$parent"; then
    landing_apply_discard_transaction_directory || true
    return 1
  fi
  printf '%s\n' "$transaction_id" > "$directory/transaction.id" || {
    landing_apply_discard_transaction_directory || true
    return 1
  }
  chmod 600 "$directory/transaction.id" || {
    landing_apply_discard_transaction_directory || true
    return 1
  }
  sync_transaction_path "$directory/transaction.id" || {
    landing_apply_discard_transaction_directory || true
    return 1
  }
  sync_transaction_path "$directory" || {
    landing_apply_discard_transaction_directory || true
    return 1
  }
  LANDING_ACTIVE_TRANSACTION_ID="$transaction_id"
  LANDING_ACTIVE_TRANSACTION_PHASE=staging
  LANDING_ACTIVE_WORK="$directory"
  set_signal_rollback landing_apply_signal_rollback || {
    landing_apply_reset_active_transaction
    landing_apply_discard_transaction_directory || true
    return 1
  }
}

landing_set_error_result() {
  local code="$1"
  [[ "$code" =~ ^[a-z][a-z0-9_]{0,47}$ ]] || code=internal_error
  LANDING_RESULT_STATUS=error
  LANDING_RESULT_CODE="$code"
  LANDING_RESULT_REVISION=""
  LANDING_RESULT_SHA256=""
}

landing_set_success_result() {
  local status="$1" revision="$2" sha256="$3"
  [[ "$status" == applied || "$status" == idempotent ]] || return 1
  landing_safe_integer_is_valid "$revision" || return 1
  [[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
  LANDING_RESULT_STATUS="$status"
  LANDING_RESULT_CODE=""
  LANDING_RESULT_REVISION="$revision"
  LANDING_RESULT_SHA256="$sha256"
}

landing_emit_current_result() {
  case "$LANDING_RESULT_STATUS" in
    applied|idempotent)
      printf '{"status":"%s","revision":%s,"content_sha256":"%s"}\n' \
        "$LANDING_RESULT_STATUS" "$LANDING_RESULT_REVISION" "$LANDING_RESULT_SHA256" || return 1
      ;;
    error)
      printf '{"status":"error","code":"%s"}\n' "$LANDING_RESULT_CODE" || return 1
      ;;
    *)
      printf '{"status":"error","code":"internal_error"}\n'
      return 1
      ;;
  esac
}

landing_agent_response_is_safe() {
  local response="$1"
  ((${#response} >= 1 && ${#response} <= 512)) || return 1
  printf '%s\n' "$response" | jq -e -s '
    length == 1 and
    (.[0] | type == "object") and
    (if .[0].status == "error" then
       (.[0] | keys | sort) == ["code", "status"] and
       (.[0].code | type == "string" and test("^[a-z][a-z0-9_]{0,47}$"))
     else
       (.[0].status == "applied" or .[0].status == "idempotent") and
       (.[0] | keys | sort) == ["content_sha256", "revision", "status"] and
       (.[0].revision | type == "number" and . == floor and . >= 1 and
         . <= 9007199254740991) and
       (.[0].content_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
     end)
  ' >/dev/null
}

landing_agent_response_matches_exit() {
  local response="$1" rc="$2" response_status
  [[ "$rc" =~ ^[0-9]+$ ]] || return 1
  landing_agent_response_is_safe "$response" || return 1
  response_status="$(printf '%s\n' "$response" | jq -r '.status')" || return 1
  if [[ "$rc" == 0 ]]; then
    [[ "$response_status" == applied || "$response_status" == idempotent ]]
  else
    [[ "$response_status" == error ]]
  fi
}

landing_agent_handoff() {
  local generation="${1:-}" response rc=0
  if [[ -n "$generation" && ! "$generation" =~ ^[0-9a-f]{64}$ ]]; then
    landing_set_error_result handoff_failed
    landing_emit_current_result
    return 1
  fi
  if [[ -n "$generation" ]]; then
    response="$(/usr/bin/sudo -n -- /usr/local/libexec/sb-user-manager-landing-apply \
      "$generation" 2>/dev/null)" || rc=$?
  else
    response="$(/usr/bin/sudo -n -- /usr/local/libexec/sb-user-manager-landing-apply 2>/dev/null)" || rc=$?
  fi
  if landing_agent_response_matches_exit "$response" "$rc"; then
    printf '%s\n' "$response" || return 1
    return "$rc"
  fi
  landing_set_error_result handoff_failed
  landing_emit_current_result
  return 1
}

landing_agent_generation_is_current() {
  local generation="$1" path uid gid mode expected_gid actual
  [[ "$generation" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$LANDING_CHANNEL_GENERATION_PATH" == /var/lib/sb-user-manager-landing/.channel-generation ]] || return 1
  path="$LANDING_CHANNEL_GENERATION_PATH"
  [[ -f "$path" && ! -L "$path" && -r "$path" ]] || return 1
  uid="$(manager_file_uid "$path")" || return 1
  gid="$(manager_file_gid "$path")" || return 1
  mode="$(manager_file_mode "$path")" || return 1
  expected_gid="$(id -g)" || return 1
  [[ "$uid" == 0 && "$gid" == "$expected_gid" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 07777) == 0440 )) || return 1
  actual="$(<"$path")" || return 1
  [[ "$actual" == "$generation" ]]
}

landing_agent_main() {
  local generation="${1:-}"
  if [[ -n "${SSH_ORIGINAL_COMMAND:-}" || -n "${SSH_TTY:-}" ||
        -z "${SSH_CONNECTION:-}" ]] ||
     { [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]] && [[ $# -ne 0 ]]; } ||
     { [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]] &&
       { [[ $# -ne 1 ]] || ! landing_agent_generation_is_current "$generation"; }; }; then
    landing_set_error_result restricted_channel_rejected
    landing_emit_current_result
    return 64
  fi
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]]; then
    landing_agent_handoff
  else
    landing_agent_handoff "$generation"
  fi
}

landing_apply_handle_signal() {
  local code="$1" callback="$ACTIVE_SIGNAL_ROLLBACK"
  trap '' HUP INT QUIT TERM
  ACTIVE_SIGNAL_ROLLBACK=""
  if [[ -n "$callback" ]]; then "$callback" "$code" || true; fi
  cleanup_runtime_temp_paths || true
  exit "$code"
}

install_landing_apply_runtime_traps() {
  RUNTIME_TRAP_PID="${BASHPID:-$$}"
  RUNTIME_TRAP_SUBSHELL="$BASH_SUBSHELL"
  trap runtime_exit_cleanup EXIT
  trap 'landing_apply_handle_signal 129' HUP
  trap 'landing_apply_handle_signal 130' INT
  trap 'landing_apply_handle_signal 131' QUIT
  trap 'landing_apply_handle_signal 143' TERM
}

landing_apply_read_stdin() {
  local package="$1" byte_count
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]]; then
    head -c "$((LANDING_APPLY_MAX_BYTES + 1))" > "$package" || return 1
  else
    /usr/bin/timeout --signal=TERM --kill-after=2 "$LANDING_AGENT_READ_TIMEOUT" \
      /usr/bin/head -c "$((LANDING_APPLY_MAX_BYTES + 1))" > "$package" || return 1
  fi
  chmod 600 "$package" || return 1
  byte_count="$(wc -c < "$package" | tr -d ' ')" || return 1
  [[ "$byte_count" =~ ^[0-9]+$ ]] || return 1
  ((byte_count >= 1 && byte_count <= LANDING_APPLY_MAX_BYTES)) || return 1
  controller_state_file_is_trusted "$package"
}

landing_prepare_runtime_directories() {
  local system_etc config_parent nft_parent tls_dir
  system_etc="$(landing_managed_path /etc)" || return 1
  config_parent="$(landing_managed_path "$(dirname "$LANDING_SINGBOX_CONFIG_PATH")")" || return 1
  nft_parent="$(landing_managed_path "$LANDING_NFTABLES_DIRECTORY")" || return 1
  tls_dir="$(landing_managed_path "$LANDING_TLS_DIRECTORY")" || return 1
  landing_ensure_system_directory "$system_etc" || return 1
  sync_transaction_path "$system_etc" || return 1
  landing_ensure_system_directory "$config_parent" || return 1
  sync_transaction_path "$config_parent" || return 1
  sync_transaction_path "$system_etc" || return 1
  landing_ensure_system_directory "$nft_parent" || return 1
  sync_transaction_path "$nft_parent" || return 1
  sync_transaction_path "$system_etc" || return 1
  landing_ensure_directory "$tls_dir" 700 || return 1
  sync_transaction_path "$tls_dir" || return 1
  sync_transaction_path "$config_parent"
}

landing_render_singbox_config() {
  local package="$1" certificate_path="$2" private_key_path="$3" output="$4"
  SB_LANDING_RENDER_CERTIFICATE_PATH="$certificate_path" \
  SB_LANDING_RENDER_PRIVATE_KEY_PATH="$private_key_path" \
    jq -e '
      {
        log: {level:"warn", timestamp:true},
        inbounds: [{
          type:"anytls",
          tag:"landing-gateway",
          listen:"0.0.0.0",
          listen_port:.gateway.listen_port,
          users:[{name:"entry-controller", password:.gateway.password}],
          tls:{
            enabled:true,
            certificate_path:$ENV.SB_LANDING_RENDER_CERTIFICATE_PATH,
            key_path:$ENV.SB_LANDING_RENDER_PRIVATE_KEY_PATH
          }
        }],
        outbounds:[{type:"direct", tag:"direct"}],
        route:{final:"direct"}
      }
    ' "$package" > "$output" || return 1
  chmod 600 "$output" || return 1
}

landing_render_nftables_rules() {
  local package="$1" output="$2"
  jq -er --arg family "$LANDING_NFTABLES_FAMILY" \
    --arg table "$LANDING_NFTABLES_TABLE" --arg chain "$LANDING_NFTABLES_CHAIN" '
      "add table " + $family + " " + $table + "\n" +
      "flush table " + $family + " " + $table + "\n" +
      "add chain " + $family + " " + $table + " " + $chain +
        " { type filter hook input priority -10; policy accept; }\n" +
      "add rule " + $family + " " + $table + " " + $chain +
        " ip saddr " + .gateway.allowed_entry_ipv4 +
        " tcp dport " + (.gateway.listen_port | tostring) + " accept\n" +
      "add rule " + $family + " " + $table + " " + $chain +
        " tcp dport " + (.gateway.listen_port | tostring) + " drop\n"
    ' "$package" > "$output" || return 1
  chmod 600 "$output" || return 1
}

landing_render_candidates() {
  local package="$1" work="$2" final_certificate final_private_key
  final_certificate="$LANDING_CERTIFICATE_PATH"
  final_private_key="$LANDING_PRIVATE_KEY_PATH"
  jq -er '.gateway.ca_certificate_pem' "$package" > "$work/gateway-ca.crt" || return 1
  jq -er '.gateway.certificate_pem' "$package" > "$work/gateway.crt" || return 1
  jq -er '.gateway.private_key_pem' "$package" > "$work/gateway.key" || return 1
  chmod 600 "$work/gateway-ca.crt" "$work/gateway.crt" "$work/gateway.key" || return 1
  landing_render_singbox_config "$package" "$work/gateway.crt" "$work/gateway.key" \
    "$work/check-config.json" || return 1
  landing_render_singbox_config "$package" "$final_certificate" "$final_private_key" \
    "$work/config.json" || return 1
  landing_render_nftables_rules "$package" "$work/landing.nft"
}

landing_validate_candidates() {
  local work="$1" singbox_binary
  singbox_binary="$(landing_managed_path "$LANDING_SINGBOX_BINARY")" || return 1
  [[ -x "$singbox_binary" && ! -L "$singbox_binary" ]] || return 1
  "$singbox_binary" check -c "$work/check-config.json" >/dev/null 2>&1 || return 1
  nft -c -f "$work/landing.nft" >/dev/null 2>&1 || return 1
}

landing_snapshot_file() {
  local snapshot="$1" label="$2" target="$3" marker
  marker="$snapshot/${label}.state"
  if [[ -e "$target" || -L "$target" ]]; then
    landing_managed_file_is_safe "$target" || return 1
    install -m 600 -- "$target" "$snapshot/$label" || return 1
    printf 'exists\n' > "$marker" || return 1
  else
    : > "$snapshot/$label" || return 1
    printf 'missing\n' > "$marker" || return 1
  fi
  chmod 600 "$snapshot/$label" "$marker" || return 1
  sync_transaction_path "$snapshot/$label" || return 1
  sync_transaction_path "$marker"
}

landing_snapshot_runtime_directories() {
  local snapshot="$1" system_etc config_parent nft_parent tls_dir output directory_state
  local etc_state etc_mode config_state config_mode nft_state nft_mode tls_state tls_mode
  system_etc="$(landing_managed_path /etc)" || return 1
  config_parent="$(landing_managed_path "$(dirname "$LANDING_SINGBOX_CONFIG_PATH")")" || return 1
  nft_parent="$(landing_managed_path "$LANDING_NFTABLES_DIRECTORY")" || return 1
  tls_dir="$(landing_managed_path "$LANDING_TLS_DIRECTORY")" || return 1
  directory_state="$(landing_snapshot_directory_state "$system_etc")" || return 1
  IFS=$'\t' read -r _ etc_state etc_mode <<< "$directory_state" || return 1
  directory_state="$(landing_snapshot_directory_state "$config_parent")" || return 1
  IFS=$'\t' read -r _ config_state config_mode <<< "$directory_state" || return 1
  directory_state="$(landing_snapshot_directory_state "$nft_parent")" || return 1
  IFS=$'\t' read -r _ nft_state nft_mode <<< "$directory_state" || return 1
  directory_state="$(landing_snapshot_directory_state "$tls_dir")" || return 1
  IFS=$'\t' read -r _ tls_state tls_mode <<< "$directory_state" || return 1
  output="$snapshot/directories.json"
  jq -n \
    --arg etc_state "$etc_state" --arg etc_mode "$etc_mode" \
    --arg config_state "$config_state" --arg config_mode "$config_mode" \
    --arg nft_state "$nft_state" --arg nft_mode "$nft_mode" \
    --arg tls_state "$tls_state" --arg tls_mode "$tls_mode" '
      {
        schema_version:1,
        etc:{state:$etc_state,mode:(if $etc_state == "exists" then $etc_mode else null end)},
        config_parent:{state:$config_state,mode:(if $config_state == "exists" then $config_mode else null end)},
        nft_parent:{state:$nft_state,mode:(if $nft_state == "exists" then $nft_mode else null end)},
        tls:{state:$tls_state,mode:(if $tls_state == "exists" then $tls_mode else null end)}
      }
    ' > "$output" || return 1
  chmod 600 "$output" || return 1
  sync_transaction_path "$output"
}

landing_snapshot_directory_state() {
  local path="$1" mode
  if [[ -e "$path" || -L "$path" ]]; then
    landing_directory_is_safe "$path" || return 1
    mode="$(manager_file_mode "$path")" || return 1
    [[ "$mode" =~ ^[0-7]{3}$ ]] || return 1
    printf 'directory\texists\t%s\n' "$mode"
  else
    printf 'directory\tmissing\t-\n'
  fi
}

landing_restore_runtime_directory() {
  local path="$1" state="$2" mode="$3" parent
  case "$state" in
    exists)
      landing_directory_is_safe "$path" || return 1
      [[ "$mode" =~ ^[0-7]{3}$ ]] || return 1
      chmod "$mode" "$path" || return 1
      landing_directory_is_safe "$path" "$mode" || return 1
      sync_transaction_path "$path" || return 1
      ;;
    missing)
      parent="$(dirname -- "$path")" || return 1
      [[ "$mode" == null ]] || return 1
      if [[ -e "$path" || -L "$path" ]]; then
        landing_directory_is_safe "$path" || return 1
        rmdir -- "$path" || return 1
      fi
      if [[ -e "$parent" || -L "$parent" ]]; then
        landing_directory_is_safe "$parent" || return 1
        sync_transaction_path "$parent" || return 1
      else
        [[ ! -L "$parent" ]] || return 1
      fi
      ;;
    *) return 1 ;;
  esac
}

landing_restore_runtime_directories() {
  local snapshot="$1" states system_etc config_parent nft_parent tls_dir state mode
  states="$snapshot/directories.json"
  landing_apply_transaction_file_is_safe "$states" || return 1
  system_etc="$(landing_managed_path /etc)" || return 1
  config_parent="$(landing_managed_path "$(dirname "$LANDING_SINGBOX_CONFIG_PATH")")" || return 1
  nft_parent="$(landing_managed_path "$LANDING_NFTABLES_DIRECTORY")" || return 1
  tls_dir="$(landing_managed_path "$LANDING_TLS_DIRECTORY")" || return 1
  state="$(jq -r '.tls.state' "$states")" || return 1
  mode="$(jq -r '.tls.mode' "$states")" || return 1
  landing_restore_runtime_directory "$tls_dir" "$state" "$mode" || return 1
  state="$(jq -r '.config_parent.state' "$states")" || return 1
  mode="$(jq -r '.config_parent.mode' "$states")" || return 1
  landing_restore_runtime_directory "$config_parent" "$state" "$mode" || return 1
  state="$(jq -r '.nft_parent.state' "$states")" || return 1
  mode="$(jq -r '.nft_parent.mode' "$states")" || return 1
  landing_restore_runtime_directory "$nft_parent" "$state" "$mode" || return 1
  state="$(jq -r '.etc.state' "$states")" || return 1
  mode="$(jq -r '.etc.mode' "$states")" || return 1
  landing_restore_runtime_directory "$system_etc" "$state" "$mode"
}

landing_create_empty_receipt_file() {
  local landing_id="$1" receipt="$2"
  landing_id_is_valid "$landing_id" || return 1
  jq -n --argjson schema "$LANDING_RECEIPT_SCHEMA_VERSION" --arg landing_id "$landing_id" '
    {
      schema_version:$schema,
      role:"managed-landing",
      landing_id:$landing_id,
      applied_revision:0,
      content_sha256:null,
      nonce:null,
      emergency_override:false
    }
  ' > "$receipt" || return 1
  chmod 600 "$receipt" || return 1
  controller_state_file_is_trusted "$receipt" || return 1
  validate_landing_receipt_json "$receipt"
}

landing_prepare_receipt_base() {
  local package="$1" work="$2" landing_id base
  landing_id="$(jq -r '.landing_id' "$package")" || return 1
  landing_id_is_valid "$landing_id" || return 1
  base="$work/receipt.base.json"
  if [[ -e "$LANDING_RECEIPT_FILE" || -L "$LANDING_RECEIPT_FILE" ]]; then
    validate_landing_receipt_file "$LANDING_RECEIPT_FILE" || return 1
    install -m 600 -- "$LANDING_RECEIPT_FILE" "$base" || return 1
  else
    landing_create_empty_receipt_file "$landing_id" "$base" || return 1
  fi
  sync_transaction_path "$base"
}

landing_prepare_receipt_candidate() {
  local package="$1" work="$2" base candidate
  local revision sha256 nonce
  base="$work/receipt.base.json"
  candidate="$work/receipt.next.json"
  validate_landing_receipt_json "$base" || return 1
  revision="$(jq -r '.revision' "$package")" || return 1
  sha256="$(jq -r '.content_sha256' "$package")" || return 1
  nonce="$(jq -r '.nonce' "$package")" || return 1
  jq --argjson revision "$revision" --arg content_sha256 "$sha256" --arg nonce "$nonce" '
    .applied_revision = $revision |
    .content_sha256 = $content_sha256 |
    .nonce = $nonce
  ' "$base" > "$candidate" || return 1
  chmod 600 "$candidate" || return 1
  validate_landing_receipt_json "$candidate" || return 1
  sync_transaction_path "$candidate"
}

landing_snapshot_receipt() {
  local work="$1" snapshot
  snapshot="$work/receipt-snapshot"
  landing_ensure_directory "$snapshot" 700 || return 1
  if [[ -e "$LANDING_RECEIPT_FILE" || -L "$LANDING_RECEIPT_FILE" ]]; then
    validate_landing_receipt_file "$LANDING_RECEIPT_FILE" || return 1
    install -m 600 -- "$LANDING_RECEIPT_FILE" "$snapshot/receipt.json" || return 1
    printf 'exists\n' > "$snapshot/receipt.state" || return 1
  else
    : > "$snapshot/receipt.json" || return 1
    printf 'missing\n' > "$snapshot/receipt.state" || return 1
  fi
  chmod 600 "$snapshot/receipt.json" "$snapshot/receipt.state" || return 1
  sync_transaction_path "$snapshot/receipt.json" || return 1
  sync_transaction_path "$snapshot/receipt.state" || return 1
  sync_transaction_path "$snapshot" || return 1
  LANDING_ACTIVE_RECEIPT_SNAPSHOT="$snapshot"
}

landing_apply_nft_rollback_batch_is_valid() {
  local work="$1" batch="$1/nft.rollback" snapshot="$1/snapshot" nft_state
  local expected actual
  landing_apply_transaction_file_is_safe "$batch" || return 1
  nft_state="$(<"$snapshot/nft-live.state")" || return 1
  expected="$({
    printf 'delete table %s %s\n' "$LANDING_NFTABLES_FAMILY" "$LANDING_NFTABLES_TABLE" || exit 1
    if [[ "$nft_state" == exists ]]; then
      cat "$snapshot/nft-live" || exit 1
    elif [[ "$nft_state" != missing ]]; then
      exit 1
    fi
  } | sha256sum | awk '{print $1}')" || return 1
  actual="$(sha256sum -- "$batch" | awk '{print $1}')" || return 1
  [[ "$expected" =~ ^[0-9a-f]{64}$ && "$actual" == "$expected" ]]
}

landing_prepare_nft_rollback_batch() {
  local work="$1" batch="$1/nft.rollback" snapshot="$1/snapshot" nft_state
  [[ ! -e "$batch" && ! -L "$batch" ]] || return 1
  nft_state="$(<"$snapshot/nft-live.state")" || return 1
  {
    printf 'delete table %s %s\n' "$LANDING_NFTABLES_FAMILY" "$LANDING_NFTABLES_TABLE" || return 1
    if [[ "$nft_state" == exists ]]; then
      cat "$snapshot/nft-live" || return 1
    elif [[ "$nft_state" != missing ]]; then
      return 1
    fi
  } > "$batch" || return 1
  chmod 600 "$batch" || return 1
  landing_apply_nft_rollback_batch_is_valid "$work" || return 1
  sync_transaction_path "$batch"
}

landing_validate_nft_rollback_batch() {
  local work="$1" nft_state
  landing_apply_nft_rollback_batch_is_valid "$work" || return 1
  nft_state="$(<"$work/snapshot/nft-live.state")" || return 1
  if [[ "$nft_state" == exists ]]; then
    nft -c -f "$work/nft.rollback" >/dev/null 2>&1 || return 1
  else
    [[ "$nft_state" == missing ]] || return 1
  fi
}

landing_apply_manifest_paths() {
  printf '%s\n' \
    transaction.id apply.json gateway-ca.crt gateway.crt gateway.key check-config.json config.json \
    landing.nft nft.rollback \
    receipt.base.json receipt.next.json \
    snapshot/config.json snapshot/config.json.state \
    snapshot/gateway-ca.crt snapshot/gateway-ca.crt.state \
    snapshot/gateway.crt snapshot/gateway.crt.state \
    snapshot/gateway.key snapshot/gateway.key.state \
    snapshot/landing.nft snapshot/landing.nft.state \
    snapshot/nft-live snapshot/nft-live.state snapshot/service.state snapshot/directories.json \
    receipt-snapshot/receipt.json receipt-snapshot/receipt.state
}

landing_apply_write_manifest() {
  local work="$1" manifest relative digest
  manifest="$work/manifest.sha256"
  : > "$manifest" || return 1
  chmod 600 "$manifest" || return 1
  while IFS= read -r relative; do
    [[ -n "$relative" && -f "$work/$relative" && ! -L "$work/$relative" ]] || return 1
    sync_transaction_path "$work/$relative" || return 1
    digest="$(sha256sum -- "$work/$relative" | awk '{print $1}')" || return 1
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s  %s\n' "$digest" "$relative" >> "$manifest" || return 1
  done < <(landing_apply_manifest_paths)
  sync_transaction_path "$manifest" || return 1
  sync_transaction_path "$work/snapshot" || return 1
  sync_transaction_path "$work/receipt-snapshot" || return 1
  sync_transaction_path "$work"
}

landing_apply_manifest_is_valid() {
  local work="$1" manifest expected actual line count=0
  manifest="$work/manifest.sha256"
  [[ "$work" == "$LANDING_APPLY_TRANSACTION_DIRECTORY" ]] || return 1
  landing_apply_transaction_layout_is_safe || return 1
  landing_apply_transaction_file_is_safe "$manifest" || return 1
  expected="$(landing_apply_manifest_paths)" || return 1
  actual="$(awk '{print substr($0,67)}' "$manifest")" || return 1
  [[ "$actual" == "$expected" ]] || return 1
  while IFS= read -r line; do
    [[ "$line" =~ ^[0-9a-f]{64}\ \ [A-Za-z0-9._/-]+$ ]] || return 1
    ((count+=1))
  done < "$manifest"
  [[ "$count" == 27 ]] || return 1
  (cd "$work" && sha256sum -c manifest.sha256 >/dev/null 2>&1)
}

landing_apply_transaction_id_file_is_valid() {
  local expected="${1:-}" path="$LANDING_APPLY_TRANSACTION_DIRECTORY/transaction.id"
  local actual byte_count line_count
  landing_apply_transaction_file_is_safe "$path" || return 1
  byte_count="$(wc -c < "$path" | tr -d ' ')" || return 1
  line_count="$(wc -l < "$path" | tr -d ' ')" || return 1
  [[ "$byte_count" == 33 && "$line_count" == 1 ]] || return 1
  actual="$(<"$path")" || return 1
  [[ "$actual" =~ ^[0-9a-f]{32}$ ]] || return 1
  [[ -z "$expected" || "$actual" == "$expected" ]]
}

validate_landing_apply_transaction_journal() {
  local journal="${1:-$LANDING_APPLY_TRANSACTION_JOURNAL}" transaction_id
  landing_apply_transaction_id_file_is_valid || return 1
  transaction_id="$(<"$LANDING_APPLY_TRANSACTION_DIRECTORY/transaction.id")" || return 1
  landing_apply_transaction_file_is_safe "$journal" || return 1
  jq -e -s 'length == 1' "$journal" >/dev/null || return 1
  jq -e --argjson schema "$LANDING_APPLY_TRANSACTION_SCHEMA_VERSION" \
    --arg transaction_id "$transaction_id" '
    type == "object" and
    (keys | sort) == [
      "content_sha256", "landing_id", "phase", "revision", "role",
      "schema_version", "transaction_id"
    ] and
    .schema_version == $schema and
    .role == "landing-apply" and
    .transaction_id == $transaction_id and
    (.landing_id | type == "string" and test("^[a-z][a-z0-9-]{0,31}$")) and
    (.revision | type == "number" and . == floor and . >= 1 and . <= 9007199254740991) and
    (.content_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.phase == "active" or .phase == "committed" or .phase == "rolled_back")
  ' "$journal" >/dev/null
}

landing_apply_write_transaction_journal() {
  local phase="$1" landing_id="$2" revision="$3" sha256="$4"
  local directory="$LANDING_APPLY_TRANSACTION_DIRECTORY" tmp="$LANDING_APPLY_TRANSACTION_DIRECTORY/.journal.next"
  [[ "$phase" == active || "$phase" == committed || "$phase" == rolled_back ]] || return 1
  landing_id_is_valid "$landing_id" || return 1
  landing_safe_integer_is_valid "$revision" || return 1
  [[ "$sha256" =~ ^[0-9a-f]{64}$ && "$LANDING_ACTIVE_TRANSACTION_ID" =~ ^[0-9a-f]{32}$ ]] || return 1
  landing_apply_transaction_layout_is_safe || return 1
  landing_apply_transaction_id_file_is_valid "$LANDING_ACTIVE_TRANSACTION_ID" || return 1
  if [[ "$phase" == active ]]; then
    [[ ! -e "$LANDING_APPLY_TRANSACTION_JOURNAL" && ! -L "$LANDING_APPLY_TRANSACTION_JOURNAL" ]] || return 1
  else
    validate_landing_apply_transaction_journal || return 1
    jq -e --arg transaction_id "$LANDING_ACTIVE_TRANSACTION_ID" --arg landing_id "$landing_id" \
      --argjson revision "$revision" --arg sha256 "$sha256" '
        .phase == "active" and .transaction_id == $transaction_id and
        .landing_id == $landing_id and .revision == $revision and
        .content_sha256 == $sha256
      ' "$LANDING_APPLY_TRANSACTION_JOURNAL" >/dev/null || return 1
  fi
  [[ ! -e "$tmp" && ! -L "$tmp" ]] || return 1
  if ! jq -n --argjson schema "$LANDING_APPLY_TRANSACTION_SCHEMA_VERSION" \
      --arg transaction_id "$LANDING_ACTIVE_TRANSACTION_ID" --arg landing_id "$landing_id" \
      --argjson revision "$revision" --arg content_sha256 "$sha256" --arg phase "$phase" '
        {
          schema_version:$schema,
          role:"landing-apply",
          transaction_id:$transaction_id,
          landing_id:$landing_id,
          revision:$revision,
          content_sha256:$content_sha256,
          phase:$phase
        }
      ' > "$tmp" ||
     ! chmod 600 "$tmp" ||
     ! validate_landing_apply_transaction_journal "$tmp" ||
     ! sync_transaction_path "$tmp"; then
    rm -f -- "$tmp" || true
    return 1
  fi
  mv -- "$tmp" "$LANDING_APPLY_TRANSACTION_JOURNAL" || {
    rm -f -- "$tmp" || true
    return 1
  }
  if ! sync_transaction_path "$directory"; then
    [[ "$phase" == committed || "$phase" == rolled_back ]] && return 2
    return 1
  fi
  LANDING_ACTIVE_TRANSACTION_PHASE="$phase"
}

landing_apply_snapshot_metadata_is_valid() {
  local work="$1" snapshot receipt_snapshot
  local label state
  snapshot="$work/snapshot"
  receipt_snapshot="$work/receipt-snapshot"
  landing_directory_is_safe "$snapshot" 700 || return 1
  landing_directory_is_safe "$receipt_snapshot" 700 || return 1
  for label in config.json gateway-ca.crt gateway.crt gateway.key landing.nft; do
    state="$(<"$snapshot/${label}.state")" || return 1
    [[ "$state" == exists || "$state" == missing ]] || return 1
    [[ "$state" != missing || ! -s "$snapshot/$label" ]] || return 1
  done
  state="$(<"$snapshot/nft-live.state")" || return 1
  [[ "$state" == exists || "$state" == missing ]] || return 1
  [[ "$state" != missing || ! -s "$snapshot/nft-live" ]] || return 1
  state="$(<"$snapshot/service.state")" || return 1
  [[ "$state" == active || "$state" == inactive || "$state" == failed ]] || return 1
  state="$(<"$receipt_snapshot/receipt.state")" || return 1
  [[ "$state" == exists || "$state" == missing ]] || return 1
  if [[ "$state" == exists ]]; then
    validate_landing_receipt_json "$receipt_snapshot/receipt.json" || return 1
  else
    [[ ! -s "$receipt_snapshot/receipt.json" ]] || return 1
  fi
  jq -e '
    type == "object" and
    (keys | sort) == ["config_parent", "etc", "nft_parent", "schema_version", "tls"] and
    .schema_version == 1 and
    all([.etc,.config_parent,.nft_parent,.tls][];
      (type == "object") and (keys | sort) == ["mode","state"] and
      ((.state == "missing" and .mode == null) or
       (.state == "exists" and (.mode | type == "string" and test("^[0-7]{3}$")))))
  ' "$snapshot/directories.json" >/dev/null
}

landing_apply_transaction_payload_is_valid() {
  local work="$LANDING_ACTIVE_WORK" package landing_id revision sha256
  [[ "$work" == "$LANDING_APPLY_TRANSACTION_DIRECTORY" ]] || return 1
  landing_apply_transaction_layout_is_safe || return 1
  landing_apply_remove_validation_directory || return 1
  landing_apply_manifest_is_valid "$work" || return 1
  landing_apply_transaction_id_file_is_valid "$LANDING_ACTIVE_TRANSACTION_ID" || return 1
  landing_apply_nft_rollback_batch_is_valid "$work" || return 1
  package="$work/apply.json"
  SB_LANDING_APPLY_VALIDATION_ROOT="$work" \
    landing_apply_package_structure_is_valid "$package" historical || return 1
  landing_apply_manifest_is_valid "$work" || return 1
  landing_id="$(jq -r '.landing_id' "$package")" || return 1
  revision="$(jq -r '.revision' "$package")" || return 1
  sha256="$(jq -r '.content_sha256' "$package")" || return 1
  [[ "$landing_id" == "$(jq -r '.landing_id' "$LANDING_APPLY_TRANSACTION_JOURNAL")" &&
     "$revision" == "$(jq -r '.revision' "$LANDING_APPLY_TRANSACTION_JOURNAL")" &&
     "$sha256" == "$(jq -r '.content_sha256' "$LANDING_APPLY_TRANSACTION_JOURNAL")" ]] || return 1
  validate_landing_receipt_json "$work/receipt.base.json" || return 1
  validate_landing_receipt_json "$work/receipt.next.json" || return 1
  jq -e --arg landing_id "$landing_id" --argjson revision "$revision" --arg sha256 "$sha256" \
    --arg nonce "$(jq -r '.nonce' "$package")" '
      .landing_id == $landing_id and .emergency_override == false and
      .applied_revision == $revision and .content_sha256 == $sha256 and .nonce == $nonce
    ' "$work/receipt.next.json" >/dev/null || return 1
  if [[ "$(<"$work/receipt-snapshot/receipt.state")" == exists ]]; then
    cmp -s -- "$work/receipt.base.json" "$work/receipt-snapshot/receipt.json" || return 1
  else
    jq -e --arg landing_id "$landing_id" '
      .landing_id == $landing_id and .applied_revision == 0 and
      .content_sha256 == null and .nonce == null and .emergency_override == false
    ' "$work/receipt.base.json" >/dev/null || return 1
  fi
  landing_apply_snapshot_metadata_is_valid "$work"
}

landing_apply_load_pending_transaction() {
  validate_landing_apply_transaction_journal || return 1
  LANDING_ACTIVE_TRANSACTION_ID="$(<"$LANDING_APPLY_TRANSACTION_DIRECTORY/transaction.id")" || return 1
  LANDING_ACTIVE_TRANSACTION_PHASE="$(jq -r '.phase' "$LANDING_APPLY_TRANSACTION_JOURNAL")" || return 1
  LANDING_ACTIVE_WORK="$LANDING_APPLY_TRANSACTION_DIRECTORY"
  LANDING_ACTIVE_SNAPSHOT="$LANDING_ACTIVE_WORK/snapshot"
  LANDING_ACTIVE_RECEIPT_SNAPSHOT="$LANDING_ACTIVE_WORK/receipt-snapshot"
}

landing_apply_full_transaction_payload_is_present() {
  local work="$LANDING_ACTIVE_WORK" name
  for name in transaction.id apply.json gateway-ca.crt gateway.crt gateway.key check-config.json config.json \
    landing.nft nft.rollback receipt.base.json receipt.next.json manifest.sha256 snapshot receipt-snapshot; do
    [[ -e "$work/$name" && ! -L "$work/$name" ]] || return 1
  done
}

landing_apply_terminal_receipt_is_valid() {
  local phase="$1" context="${2:-runtime}" landing_id revision sha256 state snapshot name target cleanup_rc=0
  local ca_target certificate_target private_key_target config_target nft_target
  [[ "$context" == runtime || "$context" == startup-known || "$context" == startup ]] || return 1
  landing_apply_full_transaction_payload_is_present || return 1
  landing_apply_transaction_payload_is_valid || return 1
  landing_apply_cleanup_marker_is_valid || cleanup_rc=$?
  case "$cleanup_rc" in 0|2) ;; *) return 1 ;; esac
  landing_apply_terminal_marker_state_is_valid "$phase" || return 1
  if [[ "$phase" == committed ]]; then
    controller_private_directory_is_trusted "$(dirname -- "$LANDING_RECEIPT_FILE")" || return 1
    validate_landing_receipt_file "$LANDING_RECEIPT_FILE" || return 1
    landing_id="$(jq -r '.landing_id' "$LANDING_APPLY_TRANSACTION_JOURNAL")" || return 1
    revision="$(jq -r '.revision' "$LANDING_APPLY_TRANSACTION_JOURNAL")" || return 1
    sha256="$(jq -r '.content_sha256' "$LANDING_APPLY_TRANSACTION_JOURNAL")" || return 1
    jq -e --arg landing_id "$landing_id" --argjson revision "$revision" --arg sha256 "$sha256" '
      .landing_id == $landing_id and .applied_revision == $revision and
      .content_sha256 == $sha256 and .emergency_override == false
    ' "$LANDING_RECEIPT_FILE" >/dev/null || return 1
    landing_apply_transaction_file_is_safe "$LANDING_ACTIVE_WORK/receipt.next.json" || return 1
    validate_landing_receipt_json "$LANDING_ACTIVE_WORK/receipt.next.json" || return 1
    cmp -s -- "$LANDING_ACTIVE_WORK/receipt.next.json" "$LANDING_RECEIPT_FILE" || return 1
    ca_target="$(landing_managed_path "$LANDING_CA_CERTIFICATE_PATH")" || return 1
    certificate_target="$(landing_managed_path "$LANDING_CERTIFICATE_PATH")" || return 1
    private_key_target="$(landing_managed_path "$LANDING_PRIVATE_KEY_PATH")" || return 1
    config_target="$(landing_managed_path "$LANDING_SINGBOX_CONFIG_PATH")" || return 1
    nft_target="$(landing_managed_path "$LANDING_NFTABLES_RULES_PATH")" || return 1
    while IFS=$'\t' read -r name target; do
      [[ -n "$name" && -n "$target" ]] || return 1
      landing_apply_transaction_file_is_safe "$LANDING_ACTIVE_WORK/$name" || return 1
      landing_managed_target_is_safe "$target" || return 1
      cmp -s -- "$LANDING_ACTIVE_WORK/$name" "$target" || return 1
    done <<EOF
gateway-ca.crt	$ca_target
gateway.crt	$certificate_target
gateway.key	$private_key_target
config.json	$config_target
landing.nft	$nft_target
EOF
    case "$context" in
      runtime)
        landing_apply_new_runtime_is_valid "$LANDING_ACTIVE_WORK/apply.json" true || return 1
        ;;
      startup-known)
        landing_startup_persistent_candidate_is_valid || return 1
        landing_startup_singbox_is_stopped || return 1
        landing_startup_transaction_live_nft_is_known || return 1
        ;;
      startup)
        landing_startup_persistent_candidate_is_valid || return 1
        landing_startup_singbox_is_stopped || return 1
        landing_apply_live_nft_matches_candidate "$LANDING_ACTIVE_WORK/apply.json" || return 1
        ;;
    esac
    return
  fi
  [[ "$phase" == rolled_back ]] || return 1
  case "$context" in
    runtime) landing_apply_restored_state_is_valid || return 1 ;;
    startup-known)
      landing_startup_persistent_snapshot_is_valid || return 1
      landing_startup_singbox_is_stopped || return 1
      landing_startup_transaction_live_nft_is_known || return 1
      ;;
    startup)
      landing_startup_persistent_snapshot_is_valid || return 1
      landing_startup_singbox_is_stopped || return 1
      landing_apply_live_nft_matches_snapshot || return 1
      ;;
  esac
  snapshot="$LANDING_ACTIVE_RECEIPT_SNAPSHOT"
  landing_apply_transaction_file_is_safe "$snapshot/receipt.state" || return 1
  landing_apply_transaction_file_is_safe "$snapshot/receipt.json" || return 1
  state="$(<"$snapshot/receipt.state")" || return 1
  if [[ "$state" == exists ]]; then
    validate_landing_receipt_file "$LANDING_RECEIPT_FILE" || return 1
    cmp -s -- "$snapshot/receipt.json" "$LANDING_RECEIPT_FILE"
  elif [[ "$state" == missing ]]; then
    [[ ! -e "$LANDING_RECEIPT_FILE" && ! -L "$LANDING_RECEIPT_FILE" ]]
  else
    return 1
  fi
}

landing_apply_atomic_install_file() {
  local source="$1" target="$2" mode="$3" parent tmp actual_mode
  [[ -f "$source" && ! -L "$source" && "$target" == /* && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  [[ "$LANDING_ACTIVE_TRANSACTION_ID" =~ ^[0-9a-f]{32}$ ]] || return 1
  parent="$(dirname -- "$target")" || return 1
  landing_directory_is_safe "$parent" || return 1
  if [[ -e "$target" || -L "$target" ]]; then
    landing_managed_file_is_safe "$target" || return 1
  fi
  tmp="$parent/.landing-apply.${LANDING_ACTIVE_TRANSACTION_ID}.next"
  [[ ! -e "$tmp" && ! -L "$tmp" ]] || return 1
  if ! install -m "$mode" -- "$source" "$tmp" ||
     ! cmp -s -- "$source" "$tmp" ||
     ! actual_mode="$(manager_file_mode "$tmp")" ||
     [[ "$actual_mode" != "${mode#0}" ]] ||
     ! sync_transaction_path "$tmp" ||
     ! mv -- "$tmp" "$target" ||
     ! sync_transaction_path "$parent"; then
    rm -f -- "$tmp" || true
    return 1
  fi
}

landing_apply_cleanup_orphan_atomic_files() {
  local label target candidate snapshot parent tmp
  while IFS=$'\t' read -r label target candidate snapshot; do
    parent="$(dirname -- "$target")" || return 1
    if [[ ! -e "$parent" && ! -L "$parent" ]]; then
      continue
    fi
    landing_directory_is_safe "$parent" || return 1
    tmp="$parent/.landing-apply.${LANDING_ACTIVE_TRANSACTION_ID}.next"
    if [[ ! -e "$tmp" && ! -L "$tmp" ]]; then
      sync_transaction_path "$parent" || return 1
      continue
    fi
    landing_apply_transaction_file_is_safe "$tmp" || return 1
    # 随机 transaction ID 将临时文件绑定到当前 journal；即使写入中途断电、内容不完整也可精确清理。
    : "$label" "$candidate" "$snapshot"
    rm -f -- "$tmp" || return 1
    sync_transaction_path "$parent" || return 1
  done <<EOF
config	$(landing_managed_path "$LANDING_SINGBOX_CONFIG_PATH")	$LANDING_ACTIVE_WORK/config.json	$LANDING_ACTIVE_SNAPSHOT/config.json
ca	$(landing_managed_path "$LANDING_CA_CERTIFICATE_PATH")	$LANDING_ACTIVE_WORK/gateway-ca.crt	$LANDING_ACTIVE_SNAPSHOT/gateway-ca.crt
certificate	$(landing_managed_path "$LANDING_CERTIFICATE_PATH")	$LANDING_ACTIVE_WORK/gateway.crt	$LANDING_ACTIVE_SNAPSHOT/gateway.crt
private_key	$(landing_managed_path "$LANDING_PRIVATE_KEY_PATH")	$LANDING_ACTIVE_WORK/gateway.key	$LANDING_ACTIVE_SNAPSHOT/gateway.key
nft	$(landing_managed_path "$LANDING_NFTABLES_RULES_PATH")	$LANDING_ACTIVE_WORK/landing.nft	$LANDING_ACTIVE_SNAPSHOT/landing.nft
receipt	$LANDING_RECEIPT_FILE	$LANDING_ACTIVE_WORK/receipt.next.json	$LANDING_ACTIVE_RECEIPT_SNAPSHOT/receipt.json
EOF
}

landing_apply_cleanup_orphan_journal_file() {
  local tmp="$LANDING_APPLY_TRANSACTION_DIRECTORY/.journal.next"
  if [[ ! -e "$tmp" && ! -L "$tmp" ]]; then
    sync_transaction_path "$LANDING_APPLY_TRANSACTION_DIRECTORY"
    return
  fi
  landing_apply_transaction_file_is_safe "$tmp" || return 1
  rm -f -- "$tmp" || return 1
  sync_transaction_path "$LANDING_APPLY_TRANSACTION_DIRECTORY"
}

landing_apply_mark_mutation_started() {
  local marker="$LANDING_APPLY_TRANSACTION_DIRECTORY/mutation.started"
  [[ ! -e "$marker" && ! -L "$marker" ]] || return 1
  : > "$marker" || return 1
  chmod 600 "$marker" || return 1
  sync_transaction_path "$marker" || return 1
  sync_transaction_path "$LANDING_APPLY_TRANSACTION_DIRECTORY" || return 1
}

landing_apply_mutation_marker_is_valid() {
  local marker="$LANDING_APPLY_TRANSACTION_DIRECTORY/mutation.started"
  [[ -e "$marker" || -L "$marker" ]] || return 2
  landing_apply_transaction_file_is_safe "$marker" || return 1
  [[ ! -s "$marker" ]] || return 1
  sync_transaction_path "$marker" || return 1
  sync_transaction_path "$LANDING_APPLY_TRANSACTION_DIRECTORY" || return 1
}

landing_apply_mark_runtime_drift() {
  local marker="$LANDING_APPLY_TRANSACTION_DIRECTORY/runtime.drift"
  if [[ -e "$marker" || -L "$marker" ]]; then
    landing_apply_transaction_file_is_safe "$marker" || return 1
    [[ ! -s "$marker" ]] || return 1
    sync_transaction_path "$marker" || return 1
    sync_transaction_path "$LANDING_ACTIVE_WORK" || return 1
    return
  fi
  : > "$marker" || return 1
  chmod 600 "$marker" || return 1
  sync_transaction_path "$marker" || return 1
  sync_transaction_path "$LANDING_APPLY_TRANSACTION_DIRECTORY"
}

landing_apply_post_mutation_markers_are_absent() {
  local name
  for name in runtime.drift service.restart-attempted \
    nft.apply-attempted nft.rollback-attempted; do
    [[ ! -e "$LANDING_APPLY_TRANSACTION_DIRECTORY/$name" &&
       ! -L "$LANDING_APPLY_TRANSACTION_DIRECTORY/$name" ]] || return 1
  done
}

landing_apply_post_mutation_marker_sequence_is_valid() {
  local directory="$LANDING_APPLY_TRANSACTION_DIRECTORY" name
  for name in runtime.drift service.restart-attempted \
    nft.apply-attempted nft.rollback-attempted; do
    if [[ -e "$directory/$name" || -L "$directory/$name" ]]; then
      landing_apply_transaction_file_is_safe "$directory/$name" || return 1
      [[ ! -s "$directory/$name" ]] || return 1
    fi
  done
  if [[ -e "$directory/nft.apply-attempted" || -L "$directory/nft.apply-attempted" ]]; then
    [[ -e "$directory/service.restart-attempted" &&
       ! -L "$directory/service.restart-attempted" ]] || return 1
  fi
  if [[ -e "$directory/nft.rollback-attempted" || -L "$directory/nft.rollback-attempted" ]]; then
    [[ -e "$directory/nft.apply-attempted" &&
       ! -L "$directory/nft.apply-attempted" ]] || return 1
  fi
}

landing_apply_terminal_marker_state_is_valid() {
  local phase="$1" marker_rc=0 directory="$LANDING_APPLY_TRANSACTION_DIRECTORY" name
  [[ "$phase" == committed || "$phase" == rolled_back ]] || return 1
  landing_apply_mutation_marker_is_valid || marker_rc=$?
  case "$marker_rc" in 0|2) ;; *) return 1 ;; esac
  if [[ "$marker_rc" == 2 ]]; then
    landing_apply_post_mutation_markers_are_absent || return 1
    [[ "$phase" == rolled_back ]]
    return
  fi
  landing_apply_post_mutation_marker_sequence_is_valid || return 1
  [[ ! -e "$directory/runtime.drift" && ! -L "$directory/runtime.drift" ]] || return 1
  if [[ "$phase" == committed ]]; then
    for name in service.restart-attempted nft.apply-attempted; do
      [[ -e "$directory/$name" && ! -L "$directory/$name" ]] || return 1
    done
    [[ ! -e "$directory/nft.rollback-attempted" &&
       ! -L "$directory/nft.rollback-attempted" ]]
    return
  fi
  if [[ -e "$directory/nft.apply-attempted" || -L "$directory/nft.apply-attempted" ]]; then
    [[ -e "$directory/nft.rollback-attempted" &&
       ! -L "$directory/nft.rollback-attempted" ]] || return 1
  fi
}

landing_apply_mark_cleanup_started() {
  local directory="$LANDING_APPLY_TRANSACTION_DIRECTORY" marker tmp
  local transaction_id phase journal_sha256
  marker="$directory/cleanup.started"
  tmp="$directory/.cleanup.next"
  if [[ -e "$marker" || -L "$marker" ]]; then
    landing_apply_cleanup_marker_is_valid || return 1
    if [[ -e "$tmp" || -L "$tmp" ]]; then
      landing_apply_transaction_file_is_safe "$tmp" || return 1
      rm -f -- "$tmp" || return 1
      sync_transaction_path "$directory" || return 1
    fi
    return 0
  fi
  if [[ -e "$tmp" || -L "$tmp" ]]; then
    landing_apply_transaction_file_is_safe "$tmp" || return 1
    rm -f -- "$tmp" || return 1
    sync_transaction_path "$directory" || return 1
  fi
  transaction_id="$(<"$directory/transaction.id")" || return 1
  phase="$(jq -r '.phase' "$LANDING_APPLY_TRANSACTION_JOURNAL")" || return 1
  journal_sha256="$(sha256sum -- "$LANDING_APPLY_TRANSACTION_JOURNAL" | awk '{print $1}')" || return 1
  [[ "$transaction_id" =~ ^[0-9a-f]{32}$ &&
     ( "$phase" == committed || "$phase" == rolled_back ) &&
     "$journal_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
  jq -n --arg transaction_id "$transaction_id" --arg phase "$phase" \
    --arg journal_sha256 "$journal_sha256" '
      {
        schema_version:1,
        role:"landing-apply-cleanup",
        transaction_id:$transaction_id,
        phase:$phase,
        journal_sha256:$journal_sha256
      }
    ' > "$tmp" || return 1
  chmod 600 "$tmp" || return 1
  sync_transaction_path "$tmp" || return 1
  mv -- "$tmp" "$marker" || return 1
  sync_transaction_path "$directory" || return 1
}

landing_apply_cleanup_marker_is_valid() {
  local directory="$LANDING_APPLY_TRANSACTION_DIRECTORY" marker transaction_id phase journal_sha256 byte_count
  directory="$LANDING_APPLY_TRANSACTION_DIRECTORY"
  marker="$directory/cleanup.started"
  [[ -e "$marker" || -L "$marker" ]] || return 2
  landing_apply_transaction_file_is_safe "$marker" || return 1
  byte_count="$(wc -c < "$marker" | tr -d ' ')" || return 1
  [[ "$byte_count" =~ ^[0-9]+$ ]] || return 1
  ((byte_count >= 1 && byte_count <= 512)) || return 1
  transaction_id="$(<"$directory/transaction.id")" || return 1
  phase="$(jq -r '.phase' "$LANDING_APPLY_TRANSACTION_JOURNAL")" || return 1
  journal_sha256="$(sha256sum -- "$LANDING_APPLY_TRANSACTION_JOURNAL" | awk '{print $1}')" || return 1
  [[ "$transaction_id" =~ ^[0-9a-f]{32}$ &&
     ( "$phase" == committed || "$phase" == rolled_back ) &&
     "$journal_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
  jq -e -s --arg transaction_id "$transaction_id" --arg phase "$phase" \
    --arg journal_sha256 "$journal_sha256" '
      length == 1 and (.[0] |
        type == "object" and
        (keys | sort) == ["journal_sha256","phase","role","schema_version","transaction_id"] and
        .schema_version == 1 and .role == "landing-apply-cleanup" and
        .transaction_id == $transaction_id and .phase == $phase and
        .journal_sha256 == $journal_sha256)
    ' "$marker" >/dev/null || return 1
  sync_transaction_path "$marker" || return 1
  sync_transaction_path "$directory" || return 1
}

landing_apply_cleanup_marker_without_journal_is_valid() {
  local directory="$LANDING_APPLY_TRANSACTION_DIRECTORY" marker transaction_id byte_count
  directory="$LANDING_APPLY_TRANSACTION_DIRECTORY"
  marker="$directory/cleanup.started"
  [[ ! -e "$LANDING_APPLY_TRANSACTION_JOURNAL" && ! -L "$LANDING_APPLY_TRANSACTION_JOURNAL" &&
     ! -e "$directory/.cleanup.next" && ! -L "$directory/.cleanup.next" ]] || return 1
  landing_apply_transaction_id_file_is_valid || return 1
  landing_apply_transaction_file_is_safe "$marker" || return 1
  byte_count="$(wc -c < "$marker" | tr -d ' ')" || return 1
  [[ "$byte_count" =~ ^[0-9]+$ ]] || return 1
  ((byte_count >= 1 && byte_count <= 512)) || return 1
  transaction_id="$(<"$directory/transaction.id")" || return 1
  jq -e -s --arg transaction_id "$transaction_id" '
      length == 1 and (.[0] |
        type == "object" and
        (keys | sort) == ["journal_sha256","phase","role","schema_version","transaction_id"] and
        .schema_version == 1 and .role == "landing-apply-cleanup" and
        .transaction_id == $transaction_id and
        (.phase == "committed" or .phase == "rolled_back") and
        (.journal_sha256 | type == "string" and test("^[0-9a-f]{64}$")))
    ' "$marker" >/dev/null
}

landing_apply_clear_runtime_drift_after_revalidation() {
  local marker="$LANDING_APPLY_TRANSACTION_DIRECTORY/runtime.drift"
  [[ -e "$marker" || -L "$marker" ]] || return 0
  landing_apply_transaction_file_is_safe "$marker" || return 1
  [[ ! -s "$marker" ]] || return 1
  sync_transaction_path "$marker" || return 1
  sync_transaction_path "$LANDING_APPLY_TRANSACTION_DIRECTORY" || return 1
  rm -f -- "$marker" || return 1
  sync_transaction_path "$LANDING_APPLY_TRANSACTION_DIRECTORY"
}

landing_apply_target_path_is_safe_or_absent() {
  local target="$1" parent
  parent="$(dirname -- "$target")" || return 1
  if [[ ! -e "$parent" && ! -L "$parent" ]]; then
    [[ ! -e "$target" && ! -L "$target" ]]
    return
  fi
  landing_directory_is_safe "$parent" || return 1
  if [[ -e "$target" || -L "$target" ]]; then
    landing_managed_file_is_safe "$target"
  fi
}

landing_apply_target_matches_transaction() {
  local snapshot="$1" label="$2" target="$3" candidate="$4" state_file state
  state_file="${5:-${label}.state}"
  landing_apply_target_path_is_safe_or_absent "$target" || return 1
  state="$(<"$snapshot/$state_file")" || return 1
  case "$state" in
    exists)
      landing_managed_file_is_safe "$target" || return 1
      cmp -s -- "$snapshot/$label" "$target" || cmp -s -- "$candidate" "$target"
      ;;
    missing)
      if [[ -e "$target" || -L "$target" ]]; then
        landing_managed_file_is_safe "$target" || return 1
        cmp -s -- "$candidate" "$target"
      fi
      ;;
    *) return 1 ;;
  esac
}

landing_apply_runtime_targets_are_known() {
  landing_apply_target_matches_transaction "$LANDING_ACTIVE_SNAPSHOT" config.json \
    "$(landing_managed_path "$LANDING_SINGBOX_CONFIG_PATH")" "$LANDING_ACTIVE_WORK/config.json" || return 1
  landing_apply_target_matches_transaction "$LANDING_ACTIVE_SNAPSHOT" gateway-ca.crt \
    "$(landing_managed_path "$LANDING_CA_CERTIFICATE_PATH")" "$LANDING_ACTIVE_WORK/gateway-ca.crt" || return 1
  landing_apply_target_matches_transaction "$LANDING_ACTIVE_SNAPSHOT" gateway.crt \
    "$(landing_managed_path "$LANDING_CERTIFICATE_PATH")" "$LANDING_ACTIVE_WORK/gateway.crt" || return 1
  landing_apply_target_matches_transaction "$LANDING_ACTIVE_SNAPSHOT" gateway.key \
    "$(landing_managed_path "$LANDING_PRIVATE_KEY_PATH")" "$LANDING_ACTIVE_WORK/gateway.key" || return 1
  landing_apply_target_matches_transaction "$LANDING_ACTIVE_SNAPSHOT" landing.nft \
    "$(landing_managed_path "$LANDING_NFTABLES_RULES_PATH")" "$LANDING_ACTIVE_WORK/landing.nft" || return 1
  landing_apply_target_matches_transaction "$LANDING_ACTIVE_RECEIPT_SNAPSHOT" receipt.json \
    "$LANDING_RECEIPT_FILE" "$LANDING_ACTIVE_WORK/receipt.next.json" receipt.state
}

landing_apply_runtime_directories_are_known() {
  local states="$LANDING_ACTIVE_SNAPSHOT/directories.json" key path applied_mode state old_mode actual
  while IFS=$'\t' read -r key path applied_mode; do
    state="$(jq -r ".${key}.state" "$states")" || return 1
    old_mode="$(jq -r ".${key}.mode" "$states")" || return 1
    if [[ ! -e "$path" && ! -L "$path" ]]; then
      [[ "$state" == missing ]] || return 1
      continue
    fi
    landing_directory_is_safe "$path" || return 1
    actual="$(manager_file_mode "$path")" || return 1
    if [[ "$state" == exists ]]; then
      if [[ "$actual" != "$old_mode" ]] &&
         { [[ "$key" != tls ]] || [[ "$actual" != "$applied_mode" ]]; }; then
        return 1
      fi
    elif [[ "$state" == missing ]]; then
      if [[ "$actual" != "$applied_mode" ]] &&
         { [[ "$applied_mode" != 755 ]] || [[ "$actual" != 700 ]]; }; then
        return 1
      fi
    else
      return 1
    fi
  done <<EOF
etc	$(landing_managed_path /etc)	755
config_parent	$(landing_managed_path "$(dirname "$LANDING_SINGBOX_CONFIG_PATH")")	755
nft_parent	$(landing_managed_path "$LANDING_NFTABLES_DIRECTORY")	755
tls	$(landing_managed_path "$LANDING_TLS_DIRECTORY")	700
EOF
}

landing_apply_runtime_directories_match_applied() {
  local states="$LANDING_ACTIVE_SNAPSHOT/directories.json" key path applied_mode
  local state old_mode expected_mode actual
  while IFS=$'\t' read -r key path applied_mode; do
    state="$(jq -r ".${key}.state" "$states")" || return 1
    old_mode="$(jq -r ".${key}.mode" "$states")" || return 1
    [[ -d "$path" && ! -L "$path" ]] || return 1
    landing_directory_is_safe "$path" || return 1
    actual="$(manager_file_mode "$path")" || return 1
    case "$state" in
      exists)
        if [[ "$key" == tls ]]; then
          expected_mode=700
        else
          [[ "$old_mode" =~ ^[0-7]{3}$ ]] || return 1
          expected_mode="$old_mode"
        fi
        ;;
      missing) expected_mode="$applied_mode" ;;
      *) return 1 ;;
    esac
    [[ "$actual" == "$expected_mode" ]] || return 1
  done <<EOF
etc	$(landing_managed_path /etc)	755
config_parent	$(landing_managed_path "$(dirname "$LANDING_SINGBOX_CONFIG_PATH")")	755
nft_parent	$(landing_managed_path "$LANDING_NFTABLES_DIRECTORY")	755
tls	$(landing_managed_path "$LANDING_TLS_DIRECTORY")	700
EOF
}

landing_restore_receipt_snapshot() {
  local snapshot="$1" state receipt_dir
  [[ -d "$snapshot" && ! -L "$snapshot" ]] || return 1
  state="$(<"$snapshot/receipt.state")" || return 1
  receipt_dir="$(dirname -- "$LANDING_RECEIPT_FILE")" || return 1
  ensure_controller_private_directory "$receipt_dir" || return 1
  case "$state" in
    exists)
      landing_managed_target_is_safe "$LANDING_RECEIPT_FILE" || return 1
      landing_apply_atomic_install_file "$snapshot/receipt.json" "$LANDING_RECEIPT_FILE" 600
      ;;
    missing)
      if [[ -e "$LANDING_RECEIPT_FILE" || -L "$LANDING_RECEIPT_FILE" ]]; then
        controller_state_file_is_trusted "$LANDING_RECEIPT_FILE" || return 1
        rm -f -- "$LANDING_RECEIPT_FILE" || return 1
      fi
      sync_transaction_path "$receipt_dir" || return 1
      ;;
    *) return 1 ;;
  esac
}

landing_commit_receipt() {
  local package="$1" receipt="$2" now="$3" state_dir decision
  decision="$(landing_apply_replay_decision "$package" "$LANDING_ACTIVE_WORK/receipt.base.json" "$now")" || return 1
  [[ "$decision" == apply ]] || return 1
  [[ "$receipt" == "$LANDING_RECEIPT_FILE" ]] || return 1
  state_dir="$(dirname -- "$receipt")" || return 1
  ensure_controller_private_directory "$state_dir" || return 1
  landing_apply_atomic_install_file "$LANDING_ACTIVE_WORK/receipt.next.json" "$receipt" 600 || return 1
  validate_landing_receipt_file "$receipt" || return 1
  cmp -s -- "$LANDING_ACTIVE_WORK/receipt.next.json" "$receipt"
}

landing_create_snapshot() {
  local work="$1" snapshot tables service_state
  local config ca_certificate certificate private_key nft_rules
  snapshot="$work/snapshot"
  LANDING_APPLY_ERROR_CODE=snapshot_directory_failed
  landing_ensure_directory "$snapshot" 700 || return 1
  landing_snapshot_runtime_directories "$snapshot" || return 1
  config="$(landing_managed_path "$LANDING_SINGBOX_CONFIG_PATH")" || return 1
  ca_certificate="$(landing_managed_path "$LANDING_CA_CERTIFICATE_PATH")" || return 1
  certificate="$(landing_managed_path "$LANDING_CERTIFICATE_PATH")" || return 1
  private_key="$(landing_managed_path "$LANDING_PRIVATE_KEY_PATH")" || return 1
  nft_rules="$(landing_managed_path "$LANDING_NFTABLES_RULES_PATH")" || return 1
  LANDING_APPLY_ERROR_CODE=snapshot_files_failed
  landing_snapshot_file "$snapshot" config.json "$config" || return 1
  landing_snapshot_file "$snapshot" gateway-ca.crt "$ca_certificate" || return 1
  landing_snapshot_file "$snapshot" gateway.crt "$certificate" || return 1
  landing_snapshot_file "$snapshot" gateway.key "$private_key" || return 1
  landing_snapshot_file "$snapshot" landing.nft "$nft_rules" || return 1

  LANDING_APPLY_ERROR_CODE=snapshot_firewall_failed
  tables="$(nft -nn list tables 2>/dev/null)" || return 1
  if grep -Fxq "table $LANDING_NFTABLES_FAMILY $LANDING_NFTABLES_TABLE" <<<"$tables"; then
    nft -nn list table "$LANDING_NFTABLES_FAMILY" "$LANDING_NFTABLES_TABLE" \
      > "$snapshot/nft-live" 2>/dev/null || return 1
    printf 'exists\n' > "$snapshot/nft-live.state" || return 1
    chmod 600 "$snapshot/nft-live" "$snapshot/nft-live.state" || return 1
  else
    : > "$snapshot/nft-live" || return 1
    printf 'missing\n' > "$snapshot/nft-live.state" || return 1
    chmod 600 "$snapshot/nft-live" "$snapshot/nft-live.state" || return 1
  fi
  sync_transaction_path "$snapshot/nft-live" || return 1
  sync_transaction_path "$snapshot/nft-live.state" || return 1

  LANDING_APPLY_ERROR_CODE=snapshot_service_failed
  service_state="$(systemctl is-active "$LANDING_SINGBOX_SERVICE" 2>/dev/null || true)"
  case "$service_state" in
    active|inactive|failed) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$service_state" > "$snapshot/service.state" || return 1
  chmod 600 "$snapshot/service.state" || return 1
  sync_transaction_path "$snapshot/service.state" || return 1
  sync_transaction_path "$snapshot" || return 1
  LANDING_ACTIVE_SNAPSHOT="$snapshot"
}

landing_restore_snapshot_file() {
  local snapshot="$1" label="$2" target="$3" state parent
  state="$(<"$snapshot/${label}.state")" || return 1
  case "$state" in
    exists)
      landing_managed_target_is_safe "$target" || return 1
      landing_apply_atomic_install_file "$snapshot/$label" "$target" 600
      ;;
    missing)
      parent="$(dirname -- "$target")" || return 1
      if [[ -e "$target" || -L "$target" ]]; then
        landing_managed_target_is_safe "$target" || return 1
        rm -f -- "$target" || return 1
      fi
      if [[ -e "$parent" || -L "$parent" ]]; then
        landing_directory_is_safe "$parent" || return 1
        sync_transaction_path "$parent" || return 1
      else
        [[ ! -L "$parent" ]] || return 1
      fi
      ;;
    *) return 1 ;;
  esac
}

landing_apply_ensure_service_stopped() {
  local current
  # systemctl 的返回码不是安全判据；唯一权威后置条件是单位已不再处于运行或过渡态。
  systemctl stop "$LANDING_SINGBOX_SERVICE" >/dev/null 2>&1 || true
  current="$(systemctl is-active "$LANDING_SINGBOX_SERVICE" 2>/dev/null || true)"
  [[ "$current" == inactive || "$current" == failed ]]
}

landing_restore_snapshot() {
  local snapshot="$1" service_state current_service rc=0 service_transition=false
  local config ca_certificate certificate private_key nft_rules nft_state
  [[ -d "$snapshot" && ! -L "$snapshot" ]] || return 1
  config="$(landing_managed_path "$LANDING_SINGBOX_CONFIG_PATH")" || return 1
  ca_certificate="$(landing_managed_path "$LANDING_CA_CERTIFICATE_PATH")" || return 1
  certificate="$(landing_managed_path "$LANDING_CERTIFICATE_PATH")" || return 1
  private_key="$(landing_managed_path "$LANDING_PRIVATE_KEY_PATH")" || return 1
  nft_rules="$(landing_managed_path "$LANDING_NFTABLES_RULES_PATH")" || return 1

  if [[ -e "$LANDING_ACTIVE_WORK/service.restart-attempted" ||
        -L "$LANDING_ACTIVE_WORK/service.restart-attempted" ]]; then
    landing_apply_transaction_file_is_safe "$LANDING_ACTIVE_WORK/service.restart-attempted" || return 1
    [[ ! -s "$LANDING_ACTIVE_WORK/service.restart-attempted" ]] || return 1
    sync_transaction_path "$LANDING_ACTIVE_WORK/service.restart-attempted" || return 1
    sync_transaction_path "$LANDING_ACTIVE_WORK" || return 1
    landing_apply_ensure_service_stopped || return 1
    service_transition=true
  else
    landing_apply_service_matches_snapshot || return 1
  fi

  landing_restore_snapshot_file "$snapshot" config.json "$config" || rc=1
  if [[ "$rc" == 0 ]]; then landing_restore_snapshot_file "$snapshot" gateway-ca.crt "$ca_certificate" || rc=1; fi
  if [[ "$rc" == 0 ]]; then landing_restore_snapshot_file "$snapshot" gateway.crt "$certificate" || rc=1; fi
  if [[ "$rc" == 0 ]]; then landing_restore_snapshot_file "$snapshot" gateway.key "$private_key" || rc=1; fi
  if [[ "$rc" == 0 ]]; then landing_restore_snapshot_file "$snapshot" landing.nft "$nft_rules" || rc=1; fi

  if [[ "$rc" == 0 ]]; then
    if [[ -e "$LANDING_ACTIVE_WORK/nft.apply-attempted" ||
          -L "$LANDING_ACTIVE_WORK/nft.apply-attempted" ]]; then
      landing_apply_transaction_file_is_safe "$LANDING_ACTIVE_WORK/nft.apply-attempted" || rc=1
      [[ ! -s "$LANDING_ACTIVE_WORK/nft.apply-attempted" ]] || rc=1
      if [[ "$rc" == 0 ]]; then landing_apply_mark_nft_phase rollback || rc=1; fi
      if [[ "$rc" == 0 ]]; then
        nft_state="$(<"$snapshot/nft-live.state")" || rc=1
        if [[ "$nft_state" == exists ]]; then
          if landing_apply_live_nft_matches_snapshot; then
            :
          elif landing_apply_live_nft_is_missing; then
            nft -f "$snapshot/nft-live" >/dev/null 2>&1 || rc=1
          elif landing_apply_live_nft_matches_candidate "$LANDING_ACTIVE_WORK/apply.json"; then
            landing_apply_nft_rollback_batch_is_valid "$LANDING_ACTIVE_WORK" || rc=1
            if [[ "$rc" == 0 ]]; then
              nft -f "$LANDING_ACTIVE_WORK/nft.rollback" >/dev/null 2>&1 || rc=1
            fi
          else
            rc=1
          fi
        elif [[ "$nft_state" == missing ]]; then
          if ! landing_apply_live_nft_is_missing; then
            landing_apply_live_nft_matches_candidate "$LANDING_ACTIVE_WORK/apply.json" || rc=1
            if [[ "$rc" == 0 ]]; then
              landing_apply_nft_rollback_batch_is_valid "$LANDING_ACTIVE_WORK" || rc=1
            fi
            if [[ "$rc" == 0 ]]; then
              nft -f "$LANDING_ACTIVE_WORK/nft.rollback" >/dev/null 2>&1 || rc=1
            fi
          fi
        else
          rc=1
        fi
      fi
    else
      landing_apply_live_nft_matches_snapshot || rc=1
    fi
  fi

  if [[ "$rc" == 0 ]]; then
    landing_restore_runtime_directories "$snapshot" || rc=1
  fi
  if [[ "$rc" == 0 && "$service_transition" == true ]]; then
    service_state="$(<"$snapshot/service.state")" || rc=1
    if [[ "$rc" == 0 && "$service_state" == active ]]; then
      systemctl restart "$LANDING_SINGBOX_SERVICE" >/dev/null 2>&1 || rc=1
      if [[ "$rc" == 0 ]]; then
        systemctl is-active --quiet "$LANDING_SINGBOX_SERVICE" >/dev/null 2>&1 || rc=1
      fi
    elif [[ "$rc" == 0 && ( "$service_state" == inactive || "$service_state" == failed ) ]]; then
      current_service="$(systemctl is-active "$LANDING_SINGBOX_SERVICE" 2>/dev/null || true)"
      [[ "$current_service" == inactive || "$current_service" == failed ]] || rc=1
    elif [[ "$rc" == 0 ]]; then
      rc=1
    fi
  elif [[ "$rc" == 0 ]]; then
    landing_apply_service_matches_snapshot || rc=1
  fi
  return "$rc"
}

landing_apply_target_matches_snapshot() {
  local snapshot="$1" label="$2" target="$3" state_file state
  state_file="${4:-${label}.state}"
  landing_apply_target_path_is_safe_or_absent "$target" || return 1
  state="$(<"$snapshot/$state_file")" || return 1
  case "$state" in
    exists)
      landing_managed_file_is_safe "$target" || return 1
      cmp -s -- "$snapshot/$label" "$target"
      ;;
    missing) [[ ! -e "$target" && ! -L "$target" ]] ;;
    *) return 1 ;;
  esac
}

landing_apply_runtime_directories_match_snapshot() {
  local states="$LANDING_ACTIVE_SNAPSHOT/directories.json" key path state mode actual
  while IFS=$'\t' read -r key path; do
    state="$(jq -r ".${key}.state" "$states")" || return 1
    mode="$(jq -r ".${key}.mode" "$states")" || return 1
    case "$state" in
      exists)
        landing_directory_is_safe "$path" || return 1
        actual="$(manager_file_mode "$path")" || return 1
        [[ "$actual" == "$mode" ]] || return 1
        ;;
      missing) [[ ! -e "$path" && ! -L "$path" ]] || return 1 ;;
      *) return 1 ;;
    esac
  done <<EOF
etc	$(landing_managed_path /etc)
config_parent	$(landing_managed_path "$(dirname "$LANDING_SINGBOX_CONFIG_PATH")")
nft_parent	$(landing_managed_path "$LANDING_NFTABLES_DIRECTORY")
tls	$(landing_managed_path "$LANDING_TLS_DIRECTORY")
EOF
}

landing_apply_restored_state_is_valid() {
  local tables nft_state service_before service_after current_nft
  landing_apply_target_matches_snapshot "$LANDING_ACTIVE_SNAPSHOT" config.json \
    "$(landing_managed_path "$LANDING_SINGBOX_CONFIG_PATH")" || return 1
  landing_apply_target_matches_snapshot "$LANDING_ACTIVE_SNAPSHOT" gateway-ca.crt \
    "$(landing_managed_path "$LANDING_CA_CERTIFICATE_PATH")" || return 1
  landing_apply_target_matches_snapshot "$LANDING_ACTIVE_SNAPSHOT" gateway.crt \
    "$(landing_managed_path "$LANDING_CERTIFICATE_PATH")" || return 1
  landing_apply_target_matches_snapshot "$LANDING_ACTIVE_SNAPSHOT" gateway.key \
    "$(landing_managed_path "$LANDING_PRIVATE_KEY_PATH")" || return 1
  landing_apply_target_matches_snapshot "$LANDING_ACTIVE_SNAPSHOT" landing.nft \
    "$(landing_managed_path "$LANDING_NFTABLES_RULES_PATH")" || return 1
  landing_apply_target_matches_snapshot "$LANDING_ACTIVE_RECEIPT_SNAPSHOT" receipt.json \
    "$LANDING_RECEIPT_FILE" receipt.state || return 1
  nft_state="$(<"$LANDING_ACTIVE_SNAPSHOT/nft-live.state")" || return 1
  tables="$(nft -nn list tables 2>/dev/null)" || return 1
  if [[ "$nft_state" == exists ]]; then
    grep -Fxq "table $LANDING_NFTABLES_FAMILY $LANDING_NFTABLES_TABLE" <<<"$tables" || return 1
    current_nft="$(nft -nn list table "$LANDING_NFTABLES_FAMILY" "$LANDING_NFTABLES_TABLE" 2>/dev/null)" || return 1
    [[ "$current_nft" == "$(<"$LANDING_ACTIVE_SNAPSHOT/nft-live")" ]] || return 1
  elif [[ "$nft_state" == missing ]]; then
    ! grep -Fxq "table $LANDING_NFTABLES_FAMILY $LANDING_NFTABLES_TABLE" <<<"$tables" || return 1
  else
    return 1
  fi
  service_before="$(<"$LANDING_ACTIVE_SNAPSHOT/service.state")" || return 1
  service_after="$(systemctl is-active "$LANDING_SINGBOX_SERVICE" 2>/dev/null || true)"
  if [[ "$service_before" == active ]]; then
    [[ "$service_after" == active ]] || return 1
  else
    [[ "$service_after" == inactive || "$service_after" == failed ]] || return 1
  fi
  landing_apply_runtime_directories_match_snapshot
}

landing_apply_live_nft_matches_snapshot() {
  local nft_state tables current_nft
  nft_state="$(<"$LANDING_ACTIVE_SNAPSHOT/nft-live.state")" || return 1
  tables="$(nft -nn list tables 2>/dev/null)" || return 1
  if [[ "$nft_state" == exists ]]; then
    grep -Fxq "table $LANDING_NFTABLES_FAMILY $LANDING_NFTABLES_TABLE" <<<"$tables" || return 1
    current_nft="$(nft -nn list table "$LANDING_NFTABLES_FAMILY" "$LANDING_NFTABLES_TABLE" 2>/dev/null)" || return 1
    [[ "$current_nft" == "$(<"$LANDING_ACTIVE_SNAPSHOT/nft-live")" ]]
  elif [[ "$nft_state" == missing ]]; then
    if grep -Fxq "table $LANDING_NFTABLES_FAMILY $LANDING_NFTABLES_TABLE" <<<"$tables"; then
      return 1
    fi
    return 0
  else
    return 1
  fi
}

landing_apply_live_nft_matches_candidate() {
  local package="$1" tables current expected allowed_entry_ipv4 port
  tables="$(nft -nn list tables 2>/dev/null)" || return 1
  grep -Fxq "table $LANDING_NFTABLES_FAMILY $LANDING_NFTABLES_TABLE" <<<"$tables" || return 1
  current="$(nft -nn list table "$LANDING_NFTABLES_FAMILY" "$LANDING_NFTABLES_TABLE" 2>/dev/null)" || return 1
  expected="$(<"$LANDING_ACTIVE_WORK/landing.nft")" || return 1
  [[ "$current" == "$expected" ]] && return 0
  allowed_entry_ipv4="$(jq -r '.gateway.allowed_entry_ipv4' "$package")" || return 1
  port="$(jq -r '.gateway.listen_port' "$package")" || return 1
  is_ipv4_address "$allowed_entry_ipv4" || return 1
  landing_port_is_valid "$port" || return 1
  SB_LANDING_EXPECTED_ENTRY_IPV4="$allowed_entry_ipv4" \
  SB_LANDING_EXPECTED_PORT="$port" \
  SB_LANDING_EXPECTED_NFT_FAMILY="$LANDING_NFTABLES_FAMILY" \
  SB_LANDING_EXPECTED_NFT_TABLE="$LANDING_NFTABLES_TABLE" \
  SB_LANDING_EXPECTED_NFT_CHAIN="$LANDING_NFTABLES_CHAIN" python3 -I -c '
import os
import re
import sys

lines = [line.strip() for line in sys.stdin.read().splitlines() if line.strip()]
family = os.environ["SB_LANDING_EXPECTED_NFT_FAMILY"]
table = os.environ["SB_LANDING_EXPECTED_NFT_TABLE"]
chain = os.environ["SB_LANDING_EXPECTED_NFT_CHAIN"]
address = os.environ["SB_LANDING_EXPECTED_ENTRY_IPV4"]
port = os.environ["SB_LANDING_EXPECTED_PORT"]

if len(lines) != 7:
    raise SystemExit(1)
if lines[0] != f"table {family} {table} {{" or lines[1] != f"chain {chain} {{":
    raise SystemExit(1)
if not re.fullmatch(r"type filter hook input priority (?:-10|filter - 10); policy accept;", lines[2]):
    raise SystemExit(1)
if lines[3] != f"ip saddr {address} tcp dport {port} accept":
    raise SystemExit(1)
if lines[4] != f"tcp dport {port} drop":
    raise SystemExit(1)
if lines[5:] != ["}", "}"]:
    raise SystemExit(1)
' <<<"$current"
}

landing_apply_live_nft_is_known() {
  if landing_apply_live_nft_matches_snapshot; then return 0; fi
  if [[ -e "$LANDING_ACTIVE_WORK/nft.apply-attempted" ||
        -L "$LANDING_ACTIVE_WORK/nft.apply-attempted" ]]; then
    landing_apply_transaction_file_is_safe "$LANDING_ACTIVE_WORK/nft.apply-attempted" || return 1
    [[ ! -s "$LANDING_ACTIVE_WORK/nft.apply-attempted" ]] || return 1
    if landing_apply_live_nft_matches_candidate "$LANDING_ACTIVE_WORK/apply.json"; then return 0; fi
  fi
  if [[ -e "$LANDING_ACTIVE_WORK/nft.rollback-attempted" ||
        -L "$LANDING_ACTIVE_WORK/nft.rollback-attempted" ]]; then
    landing_apply_transaction_file_is_safe "$LANDING_ACTIVE_WORK/nft.rollback-attempted" || return 1
    [[ ! -s "$LANDING_ACTIVE_WORK/nft.rollback-attempted" ]] || return 1
    landing_apply_live_nft_is_missing
    return
  fi
  return 1
}

landing_apply_live_nft_is_missing() {
  local tables
  tables="$(nft -nn list tables 2>/dev/null)" || return 1
  ! grep -Fxq "table $LANDING_NFTABLES_FAMILY $LANDING_NFTABLES_TABLE" <<<"$tables"
}

landing_apply_mark_nft_phase() {
  local phase="$1" marker
  [[ "$phase" == apply || "$phase" == rollback ]] || return 1
  marker="$LANDING_ACTIVE_WORK/nft.${phase}-attempted"
  if [[ -e "$marker" || -L "$marker" ]]; then
    landing_apply_transaction_file_is_safe "$marker" || return 1
    [[ ! -s "$marker" ]] || return 1
    sync_transaction_path "$marker" || return 1
    sync_transaction_path "$LANDING_ACTIVE_WORK"
    return
  fi
  : > "$marker" || return 1
  chmod 600 "$marker" || return 1
  sync_transaction_path "$marker" || return 1
  sync_transaction_path "$LANDING_ACTIVE_WORK"
}

landing_apply_service_matches_snapshot() {
  local before after
  before="$(<"$LANDING_ACTIVE_SNAPSHOT/service.state")" || return 1
  after="$(systemctl is-active "$LANDING_SINGBOX_SERVICE" 2>/dev/null || true)"
  if [[ "$before" == active ]]; then
    [[ "$after" == active ]]
  else
    [[ "$after" == inactive || "$after" == failed ]]
  fi
}

landing_apply_service_is_known() {
  local before current marker="$LANDING_ACTIVE_WORK/service.restart-attempted"
  before="$(<"$LANDING_ACTIVE_SNAPSHOT/service.state")" || return 1
  current="$(systemctl is-active "$LANDING_SINGBOX_SERVICE" 2>/dev/null || true)"
  case "$current" in active|activating|deactivating|inactive|failed) ;; *) return 1 ;; esac
  if [[ -e "$marker" || -L "$marker" ]]; then
    landing_apply_transaction_file_is_safe "$marker" || return 1
    [[ ! -s "$marker" ]] || return 1
    sync_transaction_path "$marker" || return 1
    sync_transaction_path "$LANDING_ACTIVE_WORK" || return 1
    return
  fi
  if [[ "$before" == active ]]; then
    [[ "$current" == active ]]
  else
    [[ "$current" == inactive || "$current" == failed ]]
  fi
}

landing_apply_mark_service_restart_attempted() {
  local marker="$LANDING_ACTIVE_WORK/service.restart-attempted"
  [[ ! -e "$marker" && ! -L "$marker" ]] || return 1
  : > "$marker" || return 1
  chmod 600 "$marker" || return 1
  sync_transaction_path "$marker" || return 1
  sync_transaction_path "$LANDING_ACTIVE_WORK"
}

landing_apply_candidate_files_are_active() {
  local ca_target certificate_target private_key_target config_target nft_target
  ca_target="$(landing_managed_path "$LANDING_CA_CERTIFICATE_PATH")" || return 1
  certificate_target="$(landing_managed_path "$LANDING_CERTIFICATE_PATH")" || return 1
  private_key_target="$(landing_managed_path "$LANDING_PRIVATE_KEY_PATH")" || return 1
  config_target="$(landing_managed_path "$LANDING_SINGBOX_CONFIG_PATH")" || return 1
  nft_target="$(landing_managed_path "$LANDING_NFTABLES_RULES_PATH")" || return 1
  landing_managed_target_is_safe "$ca_target" || return 1
  landing_managed_target_is_safe "$certificate_target" || return 1
  landing_managed_target_is_safe "$private_key_target" || return 1
  landing_managed_target_is_safe "$config_target" || return 1
  landing_managed_target_is_safe "$nft_target" || return 1
  cmp -s -- "$LANDING_ACTIVE_WORK/gateway-ca.crt" "$ca_target" || return 1
  cmp -s -- "$LANDING_ACTIVE_WORK/gateway.crt" "$certificate_target" || return 1
  cmp -s -- "$LANDING_ACTIVE_WORK/gateway.key" "$private_key_target" || return 1
  cmp -s -- "$LANDING_ACTIVE_WORK/config.json" "$config_target" || return 1
  cmp -s -- "$LANDING_ACTIVE_WORK/landing.nft" "$nft_target"
}

landing_apply_new_runtime_is_valid() {
  local package="$1" require_receipt="${2:-false}" port
  landing_apply_runtime_directories_match_applied || return 1
  landing_apply_candidate_files_are_active || return 1
  landing_apply_live_nft_matches_candidate "$package" || return 1
  systemctl is-active --quiet "$LANDING_SINGBOX_SERVICE" >/dev/null 2>&1 || return 1
  port="$(jq -r '.gateway.listen_port' "$package")" || return 1
  landing_port_is_valid "$port" || return 1
  ss -H -ltnp "sport = :$port" 2>/dev/null | grep -Fq 'sing-box' || return 1
  if [[ "$require_receipt" == true ]]; then
    controller_private_directory_is_trusted "$(dirname -- "$LANDING_RECEIPT_FILE")" || return 1
    validate_landing_receipt_file "$LANDING_RECEIPT_FILE" || return 1
    cmp -s -- "$LANDING_ACTIVE_WORK/receipt.next.json" "$LANDING_RECEIPT_FILE" || return 1
  else
    [[ "$require_receipt" == false ]] || return 1
  fi
}

landing_apply_finish_rollback_transaction() {
  local context="${1:-runtime}" landing_id revision sha256 rc=0
  landing_id="$(jq -r '.landing_id' "$LANDING_APPLY_TRANSACTION_JOURNAL")" || return 1
  revision="$(jq -r '.revision' "$LANDING_APPLY_TRANSACTION_JOURNAL")" || return 1
  sha256="$(jq -r '.content_sha256' "$LANDING_APPLY_TRANSACTION_JOURNAL")" || return 1
  clear_signal_rollback
  landing_apply_write_transaction_journal rolled_back "$landing_id" "$revision" "$sha256" || rc=$?
  [[ "$rc" != 1 ]] || return 1
  landing_apply_reset_active_transaction
  [[ "$rc" == 0 ]] || return 2
  landing_apply_cleanup_terminal_transaction "$context" || return 2
}

landing_apply_rollback_active_transaction() {
  local rc=0 marker_rc=0
  [[ "$LANDING_ACTIVE_TRANSACTION_PHASE" == active ]] || return 1
  landing_apply_cleanup_orphan_journal_file || return 1
  landing_apply_transaction_payload_is_valid || return 1
  [[ ! -e "$LANDING_ACTIVE_WORK/cleanup.started" &&
     ! -L "$LANDING_ACTIVE_WORK/cleanup.started" &&
     ! -e "$LANDING_ACTIVE_WORK/.cleanup.next" &&
     ! -L "$LANDING_ACTIVE_WORK/.cleanup.next" ]] || return 1
  landing_apply_cleanup_orphan_atomic_files || return 1
  landing_apply_runtime_targets_are_known || return 1
  landing_apply_runtime_directories_are_known || return 1
  landing_apply_mutation_marker_is_valid || marker_rc=$?
  case "$marker_rc" in 0|2) ;; *) return 1 ;; esac
  if [[ "$marker_rc" == 2 ]]; then
    landing_apply_post_mutation_markers_are_absent || return 1
    landing_apply_restored_state_is_valid || return 1
    landing_apply_finish_rollback_transaction
    return
  fi
  landing_apply_post_mutation_marker_sequence_is_valid || return 1
  landing_apply_live_nft_is_known || return 1
  landing_apply_service_is_known || return 1
  landing_apply_clear_runtime_drift_after_revalidation || return 1
  landing_restore_snapshot "$LANDING_ACTIVE_SNAPSHOT" || rc=1
  if [[ "$rc" == 0 ]]; then
    landing_restore_receipt_snapshot "$LANDING_ACTIVE_RECEIPT_SNAPSHOT" || rc=1
  fi
  if [[ "$rc" == 0 ]]; then
    landing_apply_cleanup_orphan_atomic_files || rc=1
  fi
  if [[ "$rc" == 0 ]]; then
    landing_apply_restored_state_is_valid || rc=1
  fi
  if [[ "$rc" == 0 ]]; then
    landing_apply_finish_rollback_transaction || rc=$?
  fi
  return "$rc"
}

landing_apply_recover_pending_transaction() {
  local directory="$LANDING_APPLY_TRANSACTION_DIRECTORY" phase
  landing_apply_reset_active_transaction
  [[ ! -L "$directory" ]] || return 1
  [[ -e "$directory" ]] || return 0
  landing_apply_transaction_layout_is_safe || return 1
  if [[ ! -e "$LANDING_APPLY_TRANSACTION_JOURNAL" && ! -L "$LANDING_APPLY_TRANSACTION_JOURNAL" ]]; then
    landing_apply_discard_transaction_directory
    return
  fi
  landing_apply_load_pending_transaction || return 1
  phase="$LANDING_ACTIVE_TRANSACTION_PHASE"
  if [[ "$phase" == committed || "$phase" == rolled_back ]]; then
    landing_apply_terminal_receipt_is_valid "$phase" || return 1
    landing_apply_reset_active_transaction
    landing_apply_cleanup_terminal_transaction
    return
  fi
  [[ "$phase" == active ]] || return 1
  landing_apply_rollback_active_transaction
}

landing_apply_signal_rollback() {
  landing_apply_recover_pending_transaction
}

landing_apply_candidates() {
  local work="$1" package="$2" port
  local config ca_certificate certificate private_key nft_rules
  config="$(landing_managed_path "$LANDING_SINGBOX_CONFIG_PATH")" || return 1
  ca_certificate="$(landing_managed_path "$LANDING_CA_CERTIFICATE_PATH")" || return 1
  certificate="$(landing_managed_path "$LANDING_CERTIFICATE_PATH")" || return 1
  private_key="$(landing_managed_path "$LANDING_PRIVATE_KEY_PATH")" || return 1
  nft_rules="$(landing_managed_path "$LANDING_NFTABLES_RULES_PATH")" || return 1
  port="$(jq -r '.gateway.listen_port' "$package")" || return 1
  landing_port_is_valid "$port" || return 1

  LANDING_APPLY_ERROR_CODE=install_failed
  landing_managed_target_is_safe "$config" || return 1
  landing_managed_target_is_safe "$ca_certificate" || return 1
  landing_managed_target_is_safe "$certificate" || return 1
  landing_managed_target_is_safe "$private_key" || return 1
  landing_managed_target_is_safe "$nft_rules" || return 1

  # 先在旧运行态仍完整时确认没有外部漂移，再持久记录服务转换并停止服务单元。
  # 这样后续替换配置或切换端口防火墙时，不存在旧监听端口失去保护的窗口。
  LANDING_APPLY_ERROR_CODE=runtime_drift
  landing_apply_live_nft_matches_snapshot || return 1
  landing_apply_service_matches_snapshot || return 1
  LANDING_APPLY_ERROR_CODE=reload_failed
  landing_apply_mark_service_restart_attempted || return 1
  landing_apply_ensure_service_stopped || return 1

  LANDING_APPLY_ERROR_CODE=runtime_drift
  landing_apply_target_matches_snapshot "$LANDING_ACTIVE_SNAPSHOT" gateway-ca.crt "$ca_certificate" || return 1
  LANDING_APPLY_ERROR_CODE=install_failed
  landing_apply_atomic_install_file "$work/gateway-ca.crt" "$ca_certificate" 600 || return 1
  LANDING_APPLY_ERROR_CODE=runtime_drift
  landing_apply_target_matches_snapshot "$LANDING_ACTIVE_SNAPSHOT" gateway.crt "$certificate" || return 1
  LANDING_APPLY_ERROR_CODE=install_failed
  landing_apply_atomic_install_file "$work/gateway.crt" "$certificate" 600 || return 1
  LANDING_APPLY_ERROR_CODE=runtime_drift
  landing_apply_target_matches_snapshot "$LANDING_ACTIVE_SNAPSHOT" gateway.key "$private_key" || return 1
  LANDING_APPLY_ERROR_CODE=install_failed
  landing_apply_atomic_install_file "$work/gateway.key" "$private_key" 600 || return 1
  LANDING_APPLY_ERROR_CODE=runtime_drift
  landing_apply_target_matches_snapshot "$LANDING_ACTIVE_SNAPSHOT" config.json "$config" || return 1
  LANDING_APPLY_ERROR_CODE=install_failed
  landing_apply_atomic_install_file "$work/config.json" "$config" 600 || return 1
  LANDING_APPLY_ERROR_CODE=runtime_drift
  landing_apply_target_matches_snapshot "$LANDING_ACTIVE_SNAPSHOT" landing.nft "$nft_rules" || return 1
  LANDING_APPLY_ERROR_CODE=install_failed
  landing_apply_atomic_install_file "$work/landing.nft" "$nft_rules" 600 || return 1

  LANDING_APPLY_ERROR_CODE=runtime_drift
  landing_apply_live_nft_matches_snapshot || return 1
  LANDING_APPLY_ERROR_CODE=firewall_failed
  landing_apply_mark_nft_phase apply || return 1
  nft -f "$work/landing.nft" >/dev/null 2>&1 || return 1
  LANDING_APPLY_ERROR_CODE=reload_failed
  systemctl restart "$LANDING_SINGBOX_SERVICE" >/dev/null 2>&1 || return 1
  LANDING_APPLY_ERROR_CODE=health_failed
  systemctl is-active --quiet "$LANDING_SINGBOX_SERVICE" >/dev/null 2>&1 || return 1
  ss -H -ltnp "sport = :$port" 2>/dev/null | grep -Fq 'sing-box' || return 1
}

landing_rollback_after_failure() {
  local original_code="$1"
  if [[ "$original_code" == runtime_drift ]]; then
    if ! landing_apply_mark_runtime_drift; then
      landing_set_error_result rollback_failed
      return 1
    fi
    landing_set_error_result runtime_drift
    return 1
  fi
  if ! landing_apply_rollback_active_transaction; then
    landing_set_error_result rollback_failed
    return 1
  fi
  landing_set_error_result "$original_code"
  return 1
}

landing_apply_commit_active_transaction() {
  local landing_id="$1" revision="$2" sha256="$3" rc=0
  landing_apply_new_runtime_is_valid "$LANDING_ACTIVE_WORK/apply.json" true || return 3
  clear_signal_rollback
  landing_apply_write_transaction_journal committed "$landing_id" "$revision" "$sha256" || rc=$?
  [[ "$rc" != 1 ]] || return 1
  landing_apply_reset_active_transaction
  [[ "$rc" == 0 ]] || return 2
  landing_apply_cleanup_terminal_transaction || return 2
}

landing_apply_package_unlocked() {
  local package="$1" work="$2" now="$3" landing_id decision revision sha256 commit_rc=0
  landing_id="$(jq -r '.landing_id' "$package")" || {
    landing_set_error_result invalid_package
    return 1
  }
  if ! landing_prepare_receipt_base "$package" "$work"; then
    if [[ -e "$LANDING_RECEIPT_FILE" || -L "$LANDING_RECEIPT_FILE" ]]; then
      landing_set_error_result receipt_invalid
    else
      landing_set_error_result receipt_init_failed
    fi
    return 1
  fi
  decision="$(landing_apply_replay_decision "$package" "$work/receipt.base.json" "$now")" || {
    landing_set_error_result replay_rejected
    return 1
  }
  revision="$(jq -r '.revision' "$package")" || {
    landing_set_error_result invalid_package
    return 1
  }
  sha256="$(jq -r '.content_sha256' "$package")" || {
    landing_set_error_result invalid_package
    return 1
  }
  if [[ "$decision" == idempotent ]]; then
    landing_set_success_result idempotent "$revision" "$sha256"
    return
  fi
  [[ "$decision" == apply ]] || {
    landing_set_error_result replay_rejected
    return 1
  }

  landing_render_candidates "$package" "$work" || {
    landing_set_error_result render_failed
    return 1
  }
  LANDING_APPLY_ERROR_CODE=check_failed
  landing_validate_candidates "$work" || {
    landing_set_error_result check_failed
    return 1
  }
  LANDING_APPLY_ERROR_CODE=snapshot_failed
  landing_create_snapshot "$work" || {
    landing_set_error_result "$LANDING_APPLY_ERROR_CODE"
    return 1
  }
  if ! landing_prepare_nft_rollback_batch "$work" ||
     ! landing_validate_nft_rollback_batch "$work"; then
    landing_set_error_result transaction_prepare_failed
    return 1
  fi
  if ! landing_snapshot_receipt "$work"; then
    landing_set_error_result snapshot_receipt_failed
    return 1
  fi
  if ! landing_prepare_receipt_candidate "$package" "$work"; then
    landing_set_error_result receipt_prepare_failed
    return 1
  fi
  if ! landing_apply_write_manifest "$work" ||
     ! landing_apply_manifest_is_valid "$work" ||
     ! landing_apply_snapshot_metadata_is_valid "$work"; then
    landing_set_error_result transaction_prepare_failed
    return 1
  fi
  if ! landing_apply_write_transaction_journal active "$landing_id" "$revision" "$sha256"; then
    landing_apply_reset_active_transaction
    if [[ -e "$LANDING_APPLY_TRANSACTION_JOURNAL" || -L "$LANDING_APPLY_TRANSACTION_JOURNAL" ]]; then
      if [[ ! -L "$LANDING_APPLY_TRANSACTION_JOURNAL" ]] &&
         validate_landing_apply_transaction_journal &&
         [[ "$(jq -r '.phase' "$LANDING_APPLY_TRANSACTION_JOURNAL")" == active ]]; then
        landing_set_error_result transaction_prepare_failed
      else
        landing_set_error_result recovery_failed
      fi
    elif ! landing_apply_discard_transaction_directory; then
      landing_set_error_result recovery_failed
    else
      landing_set_error_result transaction_prepare_failed
    fi
    return 1
  fi
  LANDING_ACTIVE_SNAPSHOT="$work/snapshot"
  LANDING_ACTIVE_RECEIPT_SNAPSHOT="$work/receipt-snapshot"
  if ! landing_apply_restored_state_is_valid; then
    landing_set_error_result runtime_drift
    return 1
  fi
  if ! landing_apply_mark_mutation_started; then
    landing_set_error_result transaction_prepare_failed
    return 1
  fi
  landing_prepare_runtime_directories || {
    landing_rollback_after_failure prepare_failed
    return 1
  }
  if ! landing_apply_candidates "$work" "$package"; then
    landing_rollback_after_failure "$LANDING_APPLY_ERROR_CODE"
    return 1
  fi
  if ! landing_apply_new_runtime_is_valid "$package" false; then
    landing_rollback_after_failure verification_failed
    return 1
  fi
  if ! landing_apply_target_matches_snapshot "$LANDING_ACTIVE_RECEIPT_SNAPSHOT" receipt.json \
    "$LANDING_RECEIPT_FILE" receipt.state; then
    landing_set_error_result runtime_drift
    return 1
  fi
  LANDING_APPLY_ERROR_CODE=receipt_failed
  if ! landing_commit_receipt "$package" "$LANDING_RECEIPT_FILE" "$now"; then
    landing_rollback_after_failure receipt_failed
    return 1
  fi
  if ! landing_apply_new_runtime_is_valid "$package" true; then
    landing_rollback_after_failure verification_failed
    return 1
  fi
  landing_apply_commit_active_transaction "$landing_id" "$revision" "$sha256" || commit_rc=$?
  if [[ "$commit_rc" == 1 ]]; then
    landing_rollback_after_failure commit_failed
    return 1
  elif [[ "$commit_rc" == 2 ]]; then
    landing_set_error_result commit_uncertain
    return 1
  elif [[ "$commit_rc" == 3 ]]; then
    landing_rollback_after_failure verification_failed
    return 1
  fi
  landing_set_success_result applied "$revision" "$sha256"
}

landing_apply_execute_valid_package() {
  local package="$1" work="$2" now
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]] &&
     ! landing_channel_identity_allows_package "$package"; then
    landing_set_error_result channel_identity_mismatch
    return 1
  fi
  if ! now="$(date +%s)"; then
    landing_set_error_result clock_failed
    return 1
  fi
  if ! landing_apply_package_unlocked "$package" "$work" "$now"; then
    [[ -n "$LANDING_RESULT_STATUS" ]] || landing_set_error_result internal_error
    return 1
  fi
}

landing_apply_process_request_unlocked() {
  local work package rc=0
  if ! landing_apply_recover_pending_transaction; then
    landing_set_error_result recovery_failed
    return 1
  fi
  if ! landing_apply_begin_staging; then
    landing_set_error_result persistent_storage_failed
    return 1
  fi
  work="$LANDING_ACTIVE_WORK"
  package="$work/apply.json"
  if ! landing_apply_read_stdin "$package"; then
    landing_set_error_result invalid_input
    rc=1
  elif ! SB_LANDING_APPLY_VALIDATION_ROOT="$work" landing_apply_package_structure_is_valid "$package"; then
    landing_set_error_result invalid_package
    rc=1
  elif ! SB_LANDING_APPLY_VALIDATION_ROOT="$work" landing_apply_execute_valid_package "$package" "$work"; then
    rc=1
  fi
  if [[ ! -e "$LANDING_APPLY_TRANSACTION_JOURNAL" && ! -L "$LANDING_APPLY_TRANSACTION_JOURNAL" ]]; then
    landing_apply_reset_active_transaction
    if ! landing_apply_discard_transaction_directory; then
      landing_set_error_result cleanup_failed
      rc=1
    fi
  elif [[ -e "$LANDING_APPLY_TRANSACTION_DIRECTORY" || -L "$LANDING_APPLY_TRANSACTION_DIRECTORY" ]]; then
    # active 或终态事务的失败现场必须由下一次请求按持久 journal 收敛。
    landing_apply_reset_active_transaction
  else
    landing_apply_reset_active_transaction
  fi
  return "$rc"
}

landing_apply_process_request() {
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    if ! landing_channel_loaded_runtime_matches_identity; then
      landing_set_error_result channel_generation_mismatch
      return 1
    fi
    if ! landing_startup_receipt_lock_parent_chain_is_safe; then
      landing_set_error_result lock_failed
      return 1
    fi
    if ! landing_channel_generation_allows_request "$LANDING_REQUESTED_GENERATION"; then
      landing_set_error_result channel_generation_mismatch
      return 1
    fi
  fi
  if ! with_landing_receipt_lock landing_apply_process_request_unlocked; then
    [[ -n "$LANDING_RESULT_STATUS" ]] || landing_set_error_result lock_failed
    return 1
  fi
}

landing_apply_helper_request() {
  local rc=0
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    with_landing_channel_shared_lock landing_apply_process_request || rc=$?
    if ((rc != 0)) && [[ -z "$LANDING_RESULT_STATUS" ]]; then
      landing_set_error_result channel_unavailable
    fi
  else
    landing_apply_process_request || rc=$?
  fi
  landing_emit_current_result || rc=1
  return "$rc"
}

landing_apply_helper_main() {
  local generation="${1:-}" rc=0
  PATH=/usr/sbin:/usr/bin:/sbin:/bin
  LC_ALL=C
  export PATH LC_ALL
  umask 077
  unset BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH OPENSSL_CONF
  LANDING_RESULT_STATUS=""
  LANDING_RESULT_CODE=""
  LANDING_RESULT_REVISION=""
  LANDING_RESULT_SHA256=""
  LANDING_ACTIVE_SNAPSHOT=""
  LANDING_ACTIVE_RECEIPT_SNAPSHOT=""
  LANDING_ACTIVE_TRANSACTION_ID=""
  LANDING_ACTIVE_TRANSACTION_PHASE=""
  LANDING_ACTIVE_WORK=""
  LANDING_REQUESTED_GENERATION=""
  clear_signal_rollback
  if { [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]] && [[ $# -ne 0 ]]; } ||
     { [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]] &&
       { [[ $# -ne 1 ]] || [[ ! "$generation" =~ ^[0-9a-f]{64}$ ]]; }; }; then
    landing_set_error_result arguments_rejected
    landing_emit_current_result
    return 64
  fi
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    LANDING_REQUESTED_GENERATION="$generation"
  fi
  if [[ "$EUID" != "$(landing_apply_expected_uid)" ]]; then
    landing_set_error_result root_required
    landing_emit_current_result
    return 77
  fi
  if ! landing_apply_runtime_paths_are_safe; then
    landing_set_error_result unsafe_runtime_paths
    landing_emit_current_result
    return 78
  fi
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    if ! landing_startup_recovery_ensure_active; then
      landing_set_error_result startup_recovery_failed
      landing_emit_current_result || true
      return 1
    fi
    with_landing_channel_input_lock landing_apply_helper_request || rc=$?
    if ((rc != 0)) && [[ -z "$LANDING_RESULT_STATUS" ]]; then
      landing_set_error_result channel_busy
      landing_emit_current_result || true
    fi
    return "$rc"
  fi
  landing_apply_helper_request
}
# ============================================================
# v5 受限落地 SSH 通道安装层（尚未接入菜单或远程注册）
# ============================================================

LANDING_CHANNEL_SCHEMA_VERSION=1
LANDING_CHANNEL_ACCOUNT=sb-landing-agent
LANDING_CHANNEL_GROUP=sb-landing-agent
LANDING_CHANNEL_GECOS='sb-user-manager landing channel'
LANDING_CHANNEL_HOME=/var/lib/sb-user-manager-landing
LANDING_CHANNEL_GENERATION_PATH=/var/lib/sb-user-manager-landing/.channel-generation
LANDING_CHANNEL_SSH_DIRECTORY=/var/lib/sb-user-manager-landing/.ssh
LANDING_CHANNEL_AUTHORIZED_KEYS_PATH=/var/lib/sb-user-manager-landing/.ssh/authorized_keys
LANDING_CHANNEL_AGENT_PATH=/usr/local/bin/sb-user-manager-landing-agent
LANDING_CHANNEL_RUNTIME_DIRECTORY=/usr/local/libexec/sb-user-manager
LANDING_CHANNEL_RUNTIME_PATH=/usr/local/libexec/sb-user-manager/landing-runtime.sh
LANDING_CHANNEL_SUDOERS_PATH=/etc/sudoers.d/sb-user-manager-landing-agent
LANDING_CHANNEL_IDENTITY_PATH=/var/lib/sb-user-manager/landing-channel.json
LANDING_CHANNEL_LOCK_PATH=/var/lib/sb-user-manager/landing-channel.lock
LANDING_CHANNEL_INPUT_LOCK_PATH=/var/lib/sb-user-manager/landing-channel-input.lock
LANDING_CHANNEL_TRANSACTION_DIRECTORY=/var/lib/sb-user-manager/landing-channel-transaction
LANDING_CHANNEL_TRANSACTION_JOURNAL=/var/lib/sb-user-manager/landing-channel-transaction/journal.json
LANDING_CHANNEL_TRANSACTION_SCHEMA_VERSION=1
LANDING_CHANNEL_LOCK_TIMEOUT=30
LANDING_CHANNEL_SHELL=/bin/sh
LANDING_CHANNEL_PASSWORD_VALUE='*NP*'

LANDING_CHANNEL_ACTIVE_MODE=""
LANDING_CHANNEL_ACTIVE_WORK=""
LANDING_CHANNEL_ACTIVE_UID=""
LANDING_CHANNEL_ACTIVE_GID=""
LANDING_CHANNEL_ACTIVE_PHASE=""
LANDING_CHANNEL_ACTIVE_TRANSACTION_ID=""
LANDING_CHANNEL_GROUP_ATTEMPTED=false
LANDING_CHANNEL_USER_ATTEMPTED=false
LANDING_CHANNEL_BOOTSTRAP_RUNTIME_FD=""
LANDING_CHANNEL_BOOTSTRAP_RUNTIME_SHA256=""

manager_file_gid() {
  stat -c '%g' -- "$1" 2>/dev/null || stat -f '%g' "$1" 2>/dev/null
}

landing_channel_expected_root_uid() {
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true && "$EUID" -ne 0 ]]; then
    printf '%s\n' "$EUID"
  else
    printf '0\n'
  fi
}

landing_channel_expected_root_gid() {
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true && "$EUID" -ne 0 ]]; then
    id -g
  else
    printf '0\n'
  fi
}

landing_channel_path() {
  local logical="$1"
  [[ "$logical" == /* ]] || return 1
  system_path "$logical"
}

landing_channel_apply_transaction_setting_is_safe() {
  local fixed_path=/var/lib/sb-user-manager/landing-apply-transaction
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true &&
        -n "${SB_LANDING_APPLY_TRANSACTION_DIRECTORY:-}" ]]; then
    [[ "$SB_LANDING_APPLY_TRANSACTION_DIRECTORY" == /* &&
       "$SB_LANDING_APPLY_TRANSACTION_DIRECTORY" != *$'\n'* ]]
    return
  fi
  [[ "${LANDING_APPLY_TRANSACTION_DIRECTORY:-}" == "$fixed_path" ]] || return 1
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    [[ -z "${SB_LANDING_APPLY_TRANSACTION_DIRECTORY:-}" ]] || return 1
  fi
}

landing_channel_runtime_paths_are_safe() {
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true && -n "${SB_SYSTEM_ROOT:-}" ]]; then
    return 1
  fi
  landing_channel_apply_transaction_setting_is_safe || return 1
  [[ "$LANDING_CHANNEL_ACCOUNT" == sb-landing-agent &&
     "$LANDING_CHANNEL_GROUP" == sb-landing-agent &&
     "$LANDING_CHANNEL_HOME" == /var/lib/sb-user-manager-landing &&
     "$LANDING_CHANNEL_GENERATION_PATH" == /var/lib/sb-user-manager-landing/.channel-generation &&
     "$LANDING_CHANNEL_SSH_DIRECTORY" == /var/lib/sb-user-manager-landing/.ssh &&
     "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH" == /var/lib/sb-user-manager-landing/.ssh/authorized_keys &&
     "$LANDING_CHANNEL_AGENT_PATH" == /usr/local/bin/sb-user-manager-landing-agent &&
     "$LANDING_CHANNEL_RUNTIME_DIRECTORY" == /usr/local/libexec/sb-user-manager &&
     "$LANDING_CHANNEL_RUNTIME_PATH" == /usr/local/libexec/sb-user-manager/landing-runtime.sh &&
     "$LANDING_AGENT_HELPER_PATH" == /usr/local/libexec/sb-user-manager-landing-apply &&
     "$LANDING_CHANNEL_SUDOERS_PATH" == /etc/sudoers.d/sb-user-manager-landing-agent &&
     "$LANDING_CHANNEL_IDENTITY_PATH" == /var/lib/sb-user-manager/landing-channel.json &&
     "$LANDING_CHANNEL_LOCK_PATH" == /var/lib/sb-user-manager/landing-channel.lock &&
     "$LANDING_CHANNEL_INPUT_LOCK_PATH" == /var/lib/sb-user-manager/landing-channel-input.lock &&
     "$LANDING_CHANNEL_TRANSACTION_DIRECTORY" == /var/lib/sb-user-manager/landing-channel-transaction &&
     "$LANDING_CHANNEL_TRANSACTION_JOURNAL" == /var/lib/sb-user-manager/landing-channel-transaction/journal.json &&
     "$LANDING_STARTUP_RECOVERY_UNIT_PATH" == /etc/systemd/system/sb-user-manager-landing-recovery.service &&
     "$LANDING_STARTUP_RECOVERY_DROPIN_DIRECTORY" == /etc/systemd/system/sing-box.service.d &&
     "$LANDING_STARTUP_RECOVERY_DROPIN_PATH" == /etc/systemd/system/sing-box.service.d/10-sb-user-manager-landing-recovery.conf &&
     "$LANDING_CHANNEL_TRANSACTION_SCHEMA_VERSION" == 1 &&
     "$LANDING_CHANNEL_LOCK_TIMEOUT" == 30 &&
     "$LANDING_CHANNEL_SHELL" == /bin/sh &&
     "$LANDING_CHANNEL_PASSWORD_VALUE" == '*NP*' ]]
}

landing_channel_root_executable_is_safe() {
  local path="$1" resolved uid mode
  [[ -x "$path" ]] || return 1
  resolved="$(readlink -f -- "$path")" || return 1
  [[ -f "$resolved" && ! -L "$resolved" && -x "$resolved" ]] || return 1
  uid="$(manager_file_uid "$resolved")" || return 1
  mode="$(manager_file_mode "$resolved")" || return 1
  [[ "$uid" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0022) == 0 ))
}

landing_channel_dependencies_are_ready() {
  [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]] && return 0
  local dependency dependency_name
  for dependency in \
    /bin/bash /bin/sh /usr/bin/getent /usr/bin/head /usr/bin/id /usr/bin/ps \
    /usr/bin/openssl /usr/bin/python3 /usr/bin/ssh-keygen /usr/bin/systemctl /usr/bin/timeout \
    /usr/bin/uname \
    /usr/bin/sudo /usr/sbin/groupadd /usr/sbin/groupdel /usr/sbin/useradd \
    /usr/sbin/userdel /usr/sbin/visudo; do
    landing_channel_root_executable_is_safe "$dependency" || return 1
  done
  for dependency_name in \
    awk cat chmod chown cmp dirname flock install jq mktemp mv nft readlink \
    rm rmdir sha256sum stat sync tr wc; do
    dependency="$(command -v "$dependency_name")" || return 1
    [[ "$dependency" == /* ]] || return 1
    landing_channel_root_executable_is_safe "$dependency" || return 1
  done
}

landing_channel_system_get_user() {
  /usr/bin/getent passwd "$1"
}

landing_channel_system_get_shadow() {
  /usr/bin/getent shadow "$1"
}

landing_channel_system_get_group() {
  /usr/bin/getent group "$1"
}

landing_channel_system_user_groups() {
  /usr/bin/id -G "$1"
}

landing_channel_system_groupadd() {
  /usr/sbin/groupadd --system "$@"
}

landing_channel_system_useradd() {
  /usr/sbin/useradd --system "$@"
}

landing_channel_system_userdel() {
  /usr/sbin/userdel "$1"
}

landing_channel_system_groupdel() {
  /usr/sbin/groupdel "$1"
}

landing_channel_process_table_has_no_live_uid() {
  local expected_uid="$1" process_uid process_state extra saw_valid_row=false
  local process_state_pattern='^[DIRSTtWXZ][<NLsl+]*$'
  [[ "$expected_uid" =~ ^[0-9]+$ && "$expected_uid" != 0 ]] || return 1
  while read -r process_uid process_state extra; do
    [[ -n "$process_uid" ]] || continue
    [[ "$process_uid" =~ ^[0-9]+$ &&
       "$process_state" =~ $process_state_pattern && -z "$extra" ]] ||
      return 1
    saw_valid_row=true
    if [[ "$process_uid" == "$expected_uid" && "$process_state" != Z* ]]; then
      return 1
    fi
  done
  [[ "$saw_valid_row" == true ]] || return 1
  return 0
}

landing_channel_system_process_table() {
  /usr/bin/ps -eo uid=,stat=
}

landing_channel_account_has_no_processes() {
  local expected_uid="$1"
  [[ "$expected_uid" =~ ^[0-9]+$ && "$expected_uid" != 0 ]] || return 1
  landing_channel_system_process_table 2>/dev/null |
    landing_channel_process_table_has_no_live_uid "$expected_uid" ||
    return 1
  return 0
}

landing_channel_system_visudo_check() {
  /usr/sbin/visudo -cf "$1" >/dev/null
}

landing_channel_sync_account_database() {
  local etc
  etc="$(landing_channel_path /etc)" || return 1
  sync_transaction_path "$etc"
}

landing_channel_apply_ownership() {
  local path="$1" uid="$2" gid="$3"
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true && "$EUID" -ne 0 ]]; then
    [[ "$(manager_file_uid "$path")" == "$uid" && "$(manager_file_gid "$path")" == "$gid" ]]
    return
  fi
  chown "$uid:$gid" -- "$path" || return 1
}

landing_channel_directory_matches() {
  local path="$1" mode="$2" uid="$3" gid="$4" actual_mode
  [[ -d "$path" && ! -L "$path" ]] || return 1
  [[ "$(manager_file_uid "$path")" == "$uid" ]] || return 1
  [[ "$(manager_file_gid "$path")" == "$gid" ]] || return 1
  actual_mode="$(manager_file_mode "$path")" || return 1
  [[ "$actual_mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$actual_mode & 07777) == 8#$mode ))
}

landing_channel_file_matches() {
  local path="$1" mode="$2" uid="$3" gid="$4" actual_mode
  [[ -f "$path" && ! -L "$path" ]] || return 1
  [[ "$(manager_file_uid "$path")" == "$uid" ]] || return 1
  [[ "$(manager_file_gid "$path")" == "$gid" ]] || return 1
  actual_mode="$(manager_file_mode "$path")" || return 1
  [[ "$actual_mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$actual_mode & 07777) == 8#$mode ))
}

landing_channel_system_directory_is_safe() {
  local path="$1" uid gid mode expected_uid expected_gid
  [[ -d "$path" && ! -L "$path" ]] || return 1
  uid="$(manager_file_uid "$path")" || return 1
  gid="$(manager_file_gid "$path")" || return 1
  mode="$(manager_file_mode "$path")" || return 1
  expected_uid="$(landing_channel_expected_root_uid)" || return 1
  expected_gid="$(landing_channel_expected_root_gid)" || return 1
  [[ "$uid" == "$expected_uid" && "$gid" == "$expected_gid" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0700) == 0700 && (8#$mode & 0022) == 0 ))
}

landing_channel_system_directory_is_channel_traversable() {
  local path="$1" mode
  landing_channel_system_directory_is_safe "$path" || return 1
  mode="$(manager_file_mode "$path")" || return 1
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0001) == 0001 ))
}

landing_channel_install_system_paths_are_safe() {
  local system_root logical path
  system_root="${SB_SYSTEM_ROOT:-/}"
  landing_channel_system_directory_is_safe "$system_root" || return 1
  for logical in \
    /usr /usr/local /usr/local/bin /usr/local/libexec \
    /etc /etc/sudoers.d /etc/systemd /etc/systemd/system \
    "$LANDING_STARTUP_RECOVERY_DROPIN_DIRECTORY" /var /var/lib; do
    path="$(landing_channel_path "$logical")" || return 1
    [[ ! -L "$path" ]] || return 1
    [[ -e "$path" ]] || continue
    case "$logical" in
      /usr|/usr/local|/usr/local/bin|/usr/local/libexec|/var|/var/lib)
        landing_channel_system_directory_is_channel_traversable "$path" || return 1
        ;;
      *) landing_channel_system_directory_is_safe "$path" || return 1 ;;
    esac
  done
}

landing_channel_directory_is_root_controlled() {
  local path="$1" uid mode expected_uid
  [[ -d "$path" && ! -L "$path" ]] || return 1
  uid="$(manager_file_uid "$path")" || return 1
  mode="$(manager_file_mode "$path")" || return 1
  expected_uid="$(landing_channel_expected_root_uid)" || return 1
  [[ "$uid" == "$expected_uid" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0700) == 0700 && (8#$mode & 0022) == 0 ))
}

landing_channel_ensure_system_directory() {
  local logical="$1" path parent uid gid
  path="$(landing_channel_path "$logical")" || return 1
  parent="$(dirname -- "$path")" || return 1
  landing_channel_system_directory_is_safe "$parent" || return 1
  if [[ -e "$path" || -L "$path" ]]; then
    landing_channel_system_directory_is_safe "$path"
    return
  fi
  uid="$(landing_channel_expected_root_uid)" || return 1
  gid="$(landing_channel_expected_root_gid)" || return 1
  install -d -m 755 -- "$path" || return 1
  landing_channel_apply_ownership "$path" "$uid" "$gid" || return 1
  landing_channel_system_directory_is_safe "$path" || return 1
  sync_transaction_path "$path" || return 1
  sync_transaction_path "$parent" || return 1
}

landing_channel_ensure_owned_directory() {
  local logical="$1" mode="$2" uid="$3" gid="$4" path parent root_uid root_gid allowed allowed_extra=""
  path="$(landing_channel_path "$logical")" || return 1
  parent="$(dirname -- "$path")" || return 1
  landing_channel_directory_is_root_controlled "$parent" || return 1
  if [[ -e "$path" || -L "$path" ]]; then
    if landing_channel_directory_matches "$path" "$mode" "$uid" "$gid"; then
      sync_transaction_path "$path" || return 1
      sync_transaction_path "$parent" || return 1
      return 0
    fi
    # install -d 与 chown 之间被中断时会留下 root:root 的确定性目录。
    # 只有持久事务中的三处专用目录、且内容仍在允许集合内时才接续该过渡态。
    [[ -n "$LANDING_CHANNEL_ACTIVE_MODE" &&
       "$LANDING_CHANNEL_ACTIVE_WORK" == "$(landing_channel_path "$LANDING_CHANNEL_TRANSACTION_DIRECTORY")" ]] || return 1
    root_uid="$(landing_channel_expected_root_uid)" || return 1
    root_gid="$(landing_channel_expected_root_gid)" || return 1
    [[ "$uid" == "$root_uid" ]] || return 1
    if ! landing_channel_directory_matches "$path" "$mode" "$root_uid" "$root_gid" &&
       ! landing_channel_directory_matches "$path" 700 "$root_uid" "$root_gid"; then
      return 1
    fi
    case "$logical" in
      "$LANDING_CHANNEL_RUNTIME_DIRECTORY") allowed="$(landing_channel_path "$LANDING_CHANNEL_RUNTIME_PATH")" ;;
      "$LANDING_CHANNEL_HOME")
        allowed="$(landing_channel_path "$LANDING_CHANNEL_GENERATION_PATH")" || return 1
        allowed_extra="$(landing_channel_path "$LANDING_CHANNEL_SSH_DIRECTORY")" || return 1
        ;;
      "$LANDING_CHANNEL_SSH_DIRECTORY") allowed="$(landing_channel_path "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH")" ;;
      *) return 1 ;;
    esac
    landing_channel_directory_contains_only "$path" "$allowed" "$allowed_extra" || return 1
    chmod "$mode" "$path" || return 1
    landing_channel_apply_ownership "$path" "$uid" "$gid" || return 1
    landing_channel_directory_matches "$path" "$mode" "$uid" "$gid" || return 1
    sync_transaction_path "$path" || return 1
    sync_transaction_path "$parent" || return 1
    return 0
  fi
  install -d -m "$mode" -- "$path" || return 1
  landing_channel_apply_ownership "$path" "$uid" "$gid" || return 1
  landing_channel_directory_matches "$path" "$mode" "$uid" "$gid" || return 1
  sync_transaction_path "$path" || return 1
  sync_transaction_path "$parent" || return 1
}

landing_channel_atomic_install_file() {
  local source="$1" logical_target="$2" mode="$3" uid="$4" gid="$5"
  local target parent tmp transaction_id
  [[ -f "$source" && ! -L "$source" && "$logical_target" == /* ]] || return 1
  transaction_id="$LANDING_CHANNEL_ACTIVE_TRANSACTION_ID"
  [[ "$transaction_id" =~ ^[0-9a-f]{32}$ ]] || return 1
  target="$(landing_channel_path "$logical_target")" || return 1
  parent="$(dirname -- "$target")" || return 1
  landing_channel_directory_is_root_controlled "$parent" || return 1
  if [[ -e "$target" || -L "$target" ]]; then
    [[ -f "$target" && ! -L "$target" ]] || return 1
  fi
  tmp="$(mktemp "$parent/.landing-channel.${transaction_id}.XXXXXX")" || return 1
  register_temp_path "$tmp" || { rm -f -- "$tmp" || true; return 1; }
  if ! install -m "$mode" -- "$source" "$tmp" ||
     ! landing_channel_apply_ownership "$tmp" "$uid" "$gid" ||
     ! cmp -s -- "$source" "$tmp" ||
     ! landing_channel_file_matches "$tmp" "$mode" "$uid" "$gid" ||
     ! sync_transaction_path "$tmp" ||
     ! mv -- "$tmp" "$target" ||
     ! sync_transaction_path "$parent"; then
    rm -f -- "$tmp" || true
    return 1
  fi
}

landing_channel_sha256() {
  sha256sum "$1" | awk '{print $1}' || return 1
}

landing_channel_normalize_public_key() {
  local source="$1" output="$2" content key_blob fingerprint
  [[ -f "$source" && ! -L "$source" && -r "$source" ]] || return 1
  [[ "$(wc -c < "$source" | tr -d ' ')" -le 1024 ]] || return 1
  content="$(<"$source")" || return 1
  [[ -n "$content" && "$content" != *$'\n'* && "$content" != *$'\r'* ]] || return 1
  [[ "$content" =~ ^ssh-ed25519[[:space:]]+([A-Za-z0-9+/]+={0,3})([[:space:]][^[:cntrl:]]*)?$ ]] || return 1
  key_blob="${BASH_REMATCH[1]}"
  printf 'ssh-ed25519 %s\n' "$key_blob" > "$output" || return 1
  chmod 600 "$output" || return 1
  fingerprint="$(ssh-keygen -lf "$output" -E sha256 2>/dev/null | awk 'NR == 1 {print $2}')" || return 1
  [[ "$fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{20,}={0,2}$ ]]
}

landing_channel_public_key_fingerprint() {
  local key="$1" fingerprint
  fingerprint="$(ssh-keygen -lf "$key" -E sha256 2>/dev/null | awk 'NR == 1 {print $2}')" || return 1
  [[ "$fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{20,}={0,2}$ ]] || return 1
  printf '%s\n' "$fingerprint"
}

landing_channel_public_key_text_fingerprint() {
  local public_key="$1" fingerprint
  [[ "$public_key" =~ ^ssh-ed25519[[:space:]]+[A-Za-z0-9+/]+={0,3}$ ]] || return 1
  fingerprint="$(printf '%s\n' "$public_key" |
    ssh-keygen -lf - -E sha256 2>/dev/null | awk 'NR == 1 {print $2}')" || return 1
  [[ "$fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{20,}={0,2}$ ]] || return 1
  printf '%s\n' "$fingerprint"
}

landing_channel_binding_generation_from_values() {
  local landing_id="$1" allowed_ipv4="$2" public_key="$3" generation
  landing_id_is_valid "$landing_id" || return 1
  is_public_ipv4 "$allowed_ipv4" || return 1
  [[ "$public_key" =~ ^ssh-ed25519[[:space:]]+[A-Za-z0-9+/]+={0,3}$ ]] || return 1
  generation="$(printf 'schema=1\nlanding_id=%s\nallowed_entry_ipv4=%s\npublic_key=%s\n' \
    "$landing_id" "$allowed_ipv4" "$public_key" | sha256sum | awk '{print $1}')" || return 1
  [[ "$generation" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$generation"
}

landing_channel_binding_generation() {
  local landing_id="$1" allowed_ipv4="$2" normalized_key="$3" public_key
  public_key="$(<"$normalized_key")" || return 1
  landing_channel_binding_generation_from_values "$landing_id" "$allowed_ipv4" "$public_key"
}

landing_channel_render_agent_launcher() {
  local output="$1"
  cat > "$output" <<'PY' || return 1
#!/usr/bin/python3 -I
import os
import sys

safe_env = {
    "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
    "LC_ALL": "C",
}
for name in ("SSH_CONNECTION", "SSH_ORIGINAL_COMMAND", "SSH_TTY"):
    if name in os.environ:
        safe_env[name] = os.environ[name]

command = r'''
exec 8< /usr/local/libexec/sb-user-manager/landing-runtime.sh || exit 78
exec 9< /usr/local/libexec/sb-user-manager/landing-runtime.sh || exit 78
LANDING_RUNTIME_FD8_ID="$(stat -Lc '%d:%i' /proc/self/fd/8)" || exit 78
LANDING_RUNTIME_FD9_ID="$(stat -Lc '%d:%i' /proc/self/fd/9)" || exit 78
[[ -n "$LANDING_RUNTIME_FD8_ID" && "$LANDING_RUNTIME_FD8_ID" == "$LANDING_RUNTIME_FD9_ID" ]] || exit 78
LANDING_LOADED_RUNTIME_SHA256="$(sha256sum /proc/self/fd/8)" || exit 78
LANDING_LOADED_RUNTIME_SHA256="${LANDING_LOADED_RUNTIME_SHA256%% *}"
[[ "$LANDING_LOADED_RUNTIME_SHA256" =~ ^[0-9a-f]{64}$ ]] || exit 78
SB_USER_MANAGER_LIBRARY=true
. /proc/self/fd/9 || exit 78
exec 8<&- 9<&-
SB_USER_MANAGER_LIBRARY=false
install_landing_apply_runtime_traps
landing_agent_main "$@"
'''
argv = [
    "sb-user-manager-landing-agent", "--noprofile", "--norc", "-c", command,
    "sb-user-manager-landing-agent", *sys.argv[1:]
]
try:
    os.execve("/bin/bash", argv, safe_env)
except OSError:
    os.write(1, b'{"status":"error","code":"launcher_failed"}\n')
    raise SystemExit(1)
PY
  chmod 600 "$output" || return 1
}

landing_channel_render_helper_launcher() {
  local output="$1"
  cat > "$output" <<'PY' || return 1
#!/usr/bin/python3 -I
import os
import sys

safe_env = {
    "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
    "LC_ALL": "C",
}
command = r'''
exec 8< /usr/local/libexec/sb-user-manager/landing-runtime.sh || exit 78
exec 9< /usr/local/libexec/sb-user-manager/landing-runtime.sh || exit 78
LANDING_RUNTIME_FD8_ID="$(stat -Lc '%d:%i' /proc/self/fd/8)" || exit 78
LANDING_RUNTIME_FD9_ID="$(stat -Lc '%d:%i' /proc/self/fd/9)" || exit 78
[[ -n "$LANDING_RUNTIME_FD8_ID" && "$LANDING_RUNTIME_FD8_ID" == "$LANDING_RUNTIME_FD9_ID" ]] || exit 78
LANDING_LOADED_RUNTIME_SHA256="$(sha256sum /proc/self/fd/8)" || exit 78
LANDING_LOADED_RUNTIME_SHA256="${LANDING_LOADED_RUNTIME_SHA256%% *}"
[[ "$LANDING_LOADED_RUNTIME_SHA256" =~ ^[0-9a-f]{64}$ ]] || exit 78
SB_USER_MANAGER_LIBRARY=true
. /proc/self/fd/9 || exit 78
exec 8<&- 9<&-
SB_USER_MANAGER_LIBRARY=false
install_landing_apply_runtime_traps
if [[ "${1:-}" == "$LANDING_STARTUP_RECOVERY_MODE_ARGUMENT" ]]; then
  shift
  landing_startup_recovery_main "$@"
else
  landing_apply_helper_main "$@"
fi
'''
argv = [
    "sb-user-manager-landing-apply", "--noprofile", "--norc", "-c", command,
    "sb-user-manager-landing-apply", *sys.argv[1:]
]
try:
    os.execve("/bin/bash", argv, safe_env)
except OSError:
    os.write(1, b'{"status":"error","code":"launcher_failed"}\n')
    raise SystemExit(1)
PY
  chmod 600 "$output" || return 1
}

landing_channel_render_sudoers() {
  local output="$1" generation="$2"
  [[ "$generation" =~ ^[0-9a-f]{64}$ ]] || return 1
  cat > "$output" <<EOF || return 1
Defaults:${LANDING_CHANNEL_ACCOUNT} env_reset
Defaults:${LANDING_CHANNEL_ACCOUNT} secure_path=/usr/sbin:/usr/bin:/sbin:/bin
Defaults:${LANDING_CHANNEL_ACCOUNT} !set_home
${LANDING_CHANNEL_ACCOUNT} ALL=(root) NOPASSWD:NOSETENV:NOLOG_INPUT:NOLOG_OUTPUT: ${LANDING_AGENT_HELPER_PATH} ${generation}
EOF
  chmod 440 "$output" || return 1
}

landing_channel_render_authorized_keys() {
  local landing_id="$1" allowed_ipv4="$2" generation="$3" normalized_key="$4" output="$5" key_blob
  landing_id_is_valid "$landing_id" || return 1
  is_public_ipv4 "$allowed_ipv4" || return 1
  [[ "$generation" =~ ^[0-9a-f]{64}$ ]] || return 1
  key_blob="$(awk 'NR == 1 && $1 == "ssh-ed25519" {print $2}' "$normalized_key")" || return 1
  [[ "$key_blob" =~ ^[A-Za-z0-9+/]+={0,3}$ ]] || return 1
  printf 'restrict,from="%s",command="%s %s" ssh-ed25519 %s sb-user-manager:%s\n' \
    "$allowed_ipv4" "$LANDING_CHANNEL_AGENT_PATH" "$generation" "$key_blob" "$landing_id" > "$output" || return 1
  chmod 600 "$output" || return 1
}

landing_channel_runtime_source() {
  local source parent root_uid root_gid fd_identity expected_identity actual_sha
  if [[ -n "$LANDING_CHANNEL_BOOTSTRAP_RUNTIME_FD" ||
        -n "$LANDING_CHANNEL_BOOTSTRAP_RUNTIME_SHA256" ]]; then
    [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true &&
       "$LANDING_CHANNEL_BOOTSTRAP_RUNTIME_FD" =~ ^[0-9]+$ &&
       "$LANDING_CHANNEL_BOOTSTRAP_RUNTIME_SHA256" =~ ^[0-9a-f]{64}$ ]] || return 1
    source="/proc/self/fd/$LANDING_CHANNEL_BOOTSTRAP_RUNTIME_FD"
    [[ -r "$source" && -f "$source" ]] || return 1
    fd_identity="$(stat -Lc '%u:%g:%a:%d:%i' -- "$source" 2>/dev/null)" || return 1
    expected_identity="$(landing_channel_expected_root_uid):$(landing_channel_expected_root_gid):600:"
    [[ "$fd_identity" == "$expected_identity"* ]] || return 1
    actual_sha="$(sha256sum "$source" | awk '{print $1}')" || return 1
    [[ "$actual_sha" == "$LANDING_CHANNEL_BOOTSTRAP_RUNTIME_SHA256" ]] || return 1
    bash -n "$source" >/dev/null 2>&1 || return 1
    printf '%s\n' "$source"
    return
  fi
  source="$(landing_channel_path /usr/local/sbin/sb-user-manager)" || return 1
  parent="$(dirname -- "$source")" || return 1
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  landing_channel_system_directory_is_safe "$parent" || return 1
  landing_channel_file_matches "$source" 700 "$root_uid" "$root_gid" || return 1
  [[ -r "$source" ]] || return 1
  bash -n "$source" >/dev/null 2>&1 || return 1
  printf '%s\n' "$source"
}

landing_channel_prepare_candidates() {
  local landing_id="$1" allowed_ipv4="$2" public_key_file="$3" work="$4" source generation
  landing_id_is_valid "$landing_id" || return 1
  is_public_ipv4 "$allowed_ipv4" || return 1
  source="$(landing_channel_runtime_source)" || return 1
  landing_channel_normalize_public_key "$public_key_file" "$work/public-key" || return 1
  generation="$(landing_channel_binding_generation "$landing_id" "$allowed_ipv4" "$work/public-key")" || return 1
  printf '%s\n' "$generation" > "$work/generation" || return 1
  chmod 600 "$work/generation" || return 1
  install -m 600 -- "$source" "$work/runtime.sh" || return 1
  bash -n "$work/runtime.sh" || return 1
  landing_channel_render_agent_launcher "$work/agent" || return 1
  landing_channel_render_helper_launcher "$work/helper" || return 1
  python3 -I -c 'compile(open(__import__("sys").argv[1], encoding="utf-8").read(), __import__("sys").argv[1], "exec")' \
    "$work/agent" || return 1
  python3 -I -c 'compile(open(__import__("sys").argv[1], encoding="utf-8").read(), __import__("sys").argv[1], "exec")' \
    "$work/helper" || return 1
  landing_channel_render_sudoers "$work/sudoers" "$generation" || return 1
  landing_channel_system_visudo_check "$work/sudoers" || return 1
  landing_startup_render_recovery_unit "$work/startup-recovery.service" || return 1
  landing_startup_render_singbox_dropin "$work/singbox-recovery.conf" || return 1
  landing_channel_render_authorized_keys "$landing_id" "$allowed_ipv4" \
    "$generation" "$work/public-key" "$work/authorized_keys" || return 1
}

landing_channel_read_account() {
  local record
  record="$(landing_channel_system_get_user "$LANDING_CHANNEL_ACCOUNT")" || return 1
  IFS=: read -r LANDING_CHANNEL_FOUND_ACCOUNT _ LANDING_CHANNEL_FOUND_UID \
    LANDING_CHANNEL_FOUND_GID LANDING_CHANNEL_FOUND_GECOS LANDING_CHANNEL_FOUND_HOME \
    LANDING_CHANNEL_FOUND_SHELL <<<"$record"
  [[ "$LANDING_CHANNEL_FOUND_ACCOUNT" == "$LANDING_CHANNEL_ACCOUNT" &&
     "$LANDING_CHANNEL_FOUND_UID" =~ ^[0-9]+$ && "$LANDING_CHANNEL_FOUND_GID" =~ ^[0-9]+$ ]]
}

landing_channel_read_group() {
  local record password members
  record="$(landing_channel_system_get_group "$LANDING_CHANNEL_GROUP")" || return 1
  IFS=: read -r LANDING_CHANNEL_FOUND_GROUP password LANDING_CHANNEL_FOUND_GROUP_GID members <<<"$record"
  [[ "$LANDING_CHANNEL_FOUND_GROUP" == "$LANDING_CHANNEL_GROUP" &&
     "$LANDING_CHANNEL_FOUND_GROUP_GID" =~ ^[0-9]+$ && -z "$members" ]]
}

landing_channel_account_is_absent() {
  local lookup_rc
  if landing_channel_system_get_user "$LANDING_CHANNEL_ACCOUNT" >/dev/null 2>&1; then
    return 1
  else
    lookup_rc=$?
  fi
  [[ "$lookup_rc" == 2 ]] || return 1
  return 0
}

landing_channel_group_is_absent() {
  local lookup_rc
  if landing_channel_system_get_group "$LANDING_CHANNEL_GROUP" >/dev/null 2>&1; then
    return 1
  else
    lookup_rc=$?
  fi
  [[ "$lookup_rc" == 2 ]] || return 1
  return 0
}

landing_channel_remove_expected_group_if_present() {
  local expected_gid="$1" lookup_rc
  [[ "$expected_gid" =~ ^[0-9]+$ && "$expected_gid" != 0 ]] || return 1
  if landing_channel_system_get_group "$LANDING_CHANNEL_GROUP" >/dev/null 2>&1; then
    landing_channel_read_group || return 1
    [[ "$LANDING_CHANNEL_FOUND_GROUP_GID" == "$expected_gid" ]] || return 1
    landing_channel_system_groupdel "$LANDING_CHANNEL_GROUP" || return 1
    landing_channel_sync_account_database || return 1
    landing_channel_group_is_absent || return 1
    return 0
  else
    lookup_rc=$?
  fi
  [[ "$lookup_rc" == 2 ]] || return 1
  return 0
}

landing_channel_password_is_disabled() {
  local record account password rest
  record="$(landing_channel_system_get_shadow "$LANDING_CHANNEL_ACCOUNT")" || return 1
  IFS=: read -r account password rest <<<"$record"
  [[ "$account" == "$LANDING_CHANNEL_ACCOUNT" && "$password" == "$LANDING_CHANNEL_PASSWORD_VALUE" ]]
}

landing_channel_account_matches() {
  local expected_uid="$1" expected_gid="$2" groups
  landing_channel_read_account || return 1
  landing_channel_read_group || return 1
  [[ "$LANDING_CHANNEL_FOUND_UID" == "$expected_uid" &&
     "$LANDING_CHANNEL_FOUND_GID" == "$expected_gid" &&
     "$LANDING_CHANNEL_FOUND_GROUP_GID" == "$expected_gid" &&
     "$expected_uid" != 0 && "$expected_gid" != 0 &&
     "$LANDING_CHANNEL_FOUND_GECOS" == "$LANDING_CHANNEL_GECOS" &&
     "$LANDING_CHANNEL_FOUND_HOME" == "$LANDING_CHANNEL_HOME" &&
     "$LANDING_CHANNEL_FOUND_SHELL" == "$LANDING_CHANNEL_SHELL" ]] || return 1
  landing_channel_password_is_disabled || return 1
  groups="$(landing_channel_system_user_groups "$LANDING_CHANNEL_ACCOUNT")" || return 1
  [[ "$groups" == "$expected_gid" ]]
}

validate_landing_channel_identity_json() {
  local path="$1"
  jq -e -s 'length == 1' "$path" >/dev/null || return 1
  jq -e --argjson schema "$LANDING_CHANNEL_SCHEMA_VERSION" \
    --arg account "$LANDING_CHANNEL_ACCOUNT" --arg group "$LANDING_CHANNEL_GROUP" \
    --arg home "$LANDING_CHANNEL_HOME" --arg shell "$LANDING_CHANNEL_SHELL" \
    --arg generation_path "$LANDING_CHANNEL_GENERATION_PATH" \
    --arg agent "$LANDING_CHANNEL_AGENT_PATH" --arg helper "$LANDING_AGENT_HELPER_PATH" \
    --arg runtime "$LANDING_CHANNEL_RUNTIME_PATH" \
    --arg authorized_keys "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH" \
    --arg sudoers "$LANDING_CHANNEL_SUDOERS_PATH" '
      type == "object" and
      (keys | sort) == [
        "account", "agent_launcher_sha256", "agent_path", "allowed_entry_ipv4",
        "authorized_keys_path", "generation", "generation_path", "gid", "group",
        "helper_launcher_sha256", "helper_path",
        "home", "landing_id", "public_key", "public_key_fingerprint", "runtime_path",
        "runtime_sha256", "schema_version", "shell", "sudoers_path", "sudoers_sha256", "uid"
      ] and
      .schema_version == $schema and .account == $account and .group == $group and
      .home == $home and .shell == $shell and .agent_path == $agent and
      .generation_path == $generation_path and
      .helper_path == $helper and .runtime_path == $runtime and
      .authorized_keys_path == $authorized_keys and .sudoers_path == $sudoers and
      (.landing_id | type == "string" and test("^[a-z][a-z0-9-]{0,31}$")) and
      (.allowed_entry_ipv4 | type == "string" and length >= 7 and length <= 15) and
      (.uid | type == "number" and . == floor and . >= 1 and . <= 4294967294) and
      (.gid | type == "number" and . == floor and . >= 1 and . <= 4294967294) and
      (.generation | type == "string" and test("^[0-9a-f]{64}$")) and
      (.public_key | type == "string" and test("^ssh-ed25519 [A-Za-z0-9+/]+={0,3}$")) and
      (.public_key_fingerprint | type == "string" and test("^SHA256:[A-Za-z0-9+/]{20,}={0,2}$")) and
      all([.runtime_sha256, .agent_launcher_sha256, .helper_launcher_sha256, .sudoers_sha256][];
        type == "string" and test("^[0-9a-f]{64}$"))
    ' "$path" >/dev/null || return 1
  landing_id_is_valid "$(jq -r '.landing_id' "$path")" || return 1
  is_public_ipv4 "$(jq -r '.allowed_entry_ipv4' "$path")"
}

validate_landing_channel_identity_file() {
  local path="${1:-$(landing_channel_path "$LANDING_CHANNEL_IDENTITY_PATH")}" uid gid public_key fingerprint generation
  uid="$(landing_channel_expected_root_uid)" || return 1
  gid="$(landing_channel_expected_root_gid)" || return 1
  landing_channel_file_matches "$path" 600 "$uid" "$gid" || return 1
  validate_landing_channel_identity_json "$path" || return 1
  public_key="$(jq -r '.public_key' "$path")" || return 1
  fingerprint="$(landing_channel_public_key_text_fingerprint "$public_key")" || return 1
  [[ "$fingerprint" == "$(jq -r '.public_key_fingerprint' "$path")" ]] || return 1
  generation="$(landing_channel_binding_generation_from_values \
    "$(jq -r '.landing_id' "$path")" "$(jq -r '.allowed_entry_ipv4' "$path")" "$public_key")" || return 1
  [[ "$generation" == "$(jq -r '.generation' "$path")" ]]
}

landing_channel_render_identity() {
  local landing_id="$1" allowed_ipv4="$2" uid="$3" gid="$4" work="$5" output="$6"
  local public_key fingerprint generation expected_generation runtime_sha agent_sha helper_sha sudoers_sha
  public_key="$(<"$work/public-key")" || return 1
  fingerprint="$(landing_channel_public_key_fingerprint "$work/public-key")" || return 1
  generation="$(<"$work/generation")" || return 1
  expected_generation="$(landing_channel_binding_generation "$landing_id" "$allowed_ipv4" "$work/public-key")" || return 1
  [[ "$generation" == "$expected_generation" ]] || return 1
  runtime_sha="$(landing_channel_sha256 "$work/runtime.sh")" || return 1
  agent_sha="$(landing_channel_sha256 "$work/agent")" || return 1
  helper_sha="$(landing_channel_sha256 "$work/helper")" || return 1
  sudoers_sha="$(landing_channel_sha256 "$work/sudoers")" || return 1
  jq -n --argjson schema "$LANDING_CHANNEL_SCHEMA_VERSION" --arg landing_id "$landing_id" \
    --arg allowed_ipv4 "$allowed_ipv4" --arg account "$LANDING_CHANNEL_ACCOUNT" \
    --arg group "$LANDING_CHANNEL_GROUP" --argjson uid "$uid" --argjson gid "$gid" \
    --arg home "$LANDING_CHANNEL_HOME" --arg shell "$LANDING_CHANNEL_SHELL" \
    --arg public_key "$public_key" --arg fingerprint "$fingerprint" \
    --arg generation "$generation" --arg generation_path "$LANDING_CHANNEL_GENERATION_PATH" \
    --arg agent "$LANDING_CHANNEL_AGENT_PATH" --arg helper "$LANDING_AGENT_HELPER_PATH" \
    --arg runtime "$LANDING_CHANNEL_RUNTIME_PATH" \
    --arg authorized_keys "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH" \
    --arg sudoers "$LANDING_CHANNEL_SUDOERS_PATH" --arg runtime_sha "$runtime_sha" \
    --arg agent_sha "$agent_sha" --arg helper_sha "$helper_sha" --arg sudoers_sha "$sudoers_sha" '
      {
        schema_version:$schema, landing_id:$landing_id, allowed_entry_ipv4:$allowed_ipv4,
        account:$account, group:$group, uid:$uid, gid:$gid, home:$home, shell:$shell,
        public_key:$public_key, public_key_fingerprint:$fingerprint,
        generation:$generation, generation_path:$generation_path,
        agent_path:$agent, helper_path:$helper, runtime_path:$runtime,
        authorized_keys_path:$authorized_keys, sudoers_path:$sudoers,
        runtime_sha256:$runtime_sha, agent_launcher_sha256:$agent_sha,
        helper_launcher_sha256:$helper_sha, sudoers_sha256:$sudoers_sha
      }
    ' > "$output" || return 1
  chmod 600 "$output" || return 1
  validate_landing_channel_identity_json "$output"
}

landing_channel_identity_allows_package() {
  local package="$1" identity package_landing_id package_ipv4
  identity="$(landing_channel_path "$LANDING_CHANNEL_IDENTITY_PATH")" || return 1
  validate_landing_channel_identity_file "$identity" || return 1
  package_landing_id="$(jq -r '.landing_id' "$package")" || return 1
  package_ipv4="$(jq -r '.gateway.allowed_entry_ipv4' "$package")" || return 1
  [[ "$package_landing_id" == "$(jq -r '.landing_id' "$identity")" &&
     "$package_ipv4" == "$(jq -r '.allowed_entry_ipv4' "$identity")" ]]
}

landing_channel_generation_allows_request() {
  local generation="$1" identity generation_file root_uid channel_gid
  [[ "$generation" =~ ^[0-9a-f]{64}$ ]] || return 1
  landing_channel_runtime_paths_are_safe || return 1
  identity="$(landing_channel_path "$LANDING_CHANNEL_IDENTITY_PATH")" || return 1
  validate_landing_channel_identity_file "$identity" || return 1
  [[ "$generation" == "$(jq -r '.generation' "$identity")" ]] || return 1
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  channel_gid="$(jq -r '.gid' "$identity")" || return 1
  [[ "$channel_gid" =~ ^[0-9]+$ && "$channel_gid" != 0 ]] || return 1
  generation_file="$(landing_channel_path "$LANDING_CHANNEL_GENERATION_PATH")" || return 1
  landing_channel_file_matches "$generation_file" 440 "$root_uid" "$channel_gid" || return 1
  [[ "$(<"$generation_file")" == "$generation" ]]
}

landing_channel_authorized_keys_is_valid() {
  local identity="$1" authorized_keys expected actual
  authorized_keys="$(landing_channel_path "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH")" || return 1
  expected="restrict,from=\"$(jq -r '.allowed_entry_ipv4' "$identity")\",command=\"$LANDING_CHANNEL_AGENT_PATH $(jq -r '.generation' "$identity")\" $(jq -r '.public_key' "$identity") sb-user-manager:$(jq -r '.landing_id' "$identity")"
  actual="$(<"$authorized_keys")" || return 1
  [[ "$actual" == "$expected" ]]
}

landing_restricted_channel_core_is_valid() {
  local identity uid gid channel_gid generation_file runtime agent helper sudoers authorized home ssh_dir runtime_dir manager_dir logical path
  local expected_sudoers actual_sudoers
  landing_channel_runtime_paths_are_safe || return 1
  for logical in /usr /usr/local /usr/local/bin /usr/local/libexec /var /var/lib; do
    path="$(landing_channel_path "$logical")" || return 1
    landing_channel_system_directory_is_channel_traversable "$path" || return 1
  done
  for logical in /etc /etc/systemd /etc/systemd/system "$LANDING_STARTUP_RECOVERY_DROPIN_DIRECTORY"; do
    path="$(landing_channel_path "$logical")" || return 1
    landing_channel_system_directory_is_safe "$path" || return 1
  done
  identity="$(landing_channel_path "$LANDING_CHANNEL_IDENTITY_PATH")" || return 1
  validate_landing_channel_identity_file "$identity" || return 1
  uid="$(jq -r '.uid' "$identity")" || return 1
  gid="$(jq -r '.gid' "$identity")" || return 1
  landing_channel_account_matches "$uid" "$gid" || return 1
  channel_gid="$gid"
  home="$(landing_channel_path "$LANDING_CHANNEL_HOME")" || return 1
  ssh_dir="$(landing_channel_path "$LANDING_CHANNEL_SSH_DIRECTORY")" || return 1
  runtime_dir="$(landing_channel_path "$LANDING_CHANNEL_RUNTIME_DIRECTORY")" || return 1
  manager_dir="$(landing_channel_path /var/lib/sb-user-manager)" || return 1
  runtime="$(landing_channel_path "$LANDING_CHANNEL_RUNTIME_PATH")" || return 1
  agent="$(landing_channel_path "$LANDING_CHANNEL_AGENT_PATH")" || return 1
  helper="$(landing_channel_path "$LANDING_AGENT_HELPER_PATH")" || return 1
  sudoers="$(landing_channel_path "$LANDING_CHANNEL_SUDOERS_PATH")" || return 1
  authorized="$(landing_channel_path "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH")" || return 1
  generation_file="$(landing_channel_path "$LANDING_CHANNEL_GENERATION_PATH")" || return 1
  landing_channel_directory_matches "$home" 750 "$(landing_channel_expected_root_uid)" "$channel_gid" || return 1
  landing_channel_directory_matches "$ssh_dir" 750 "$(landing_channel_expected_root_uid)" "$channel_gid" || return 1
  landing_channel_directory_matches "$runtime_dir" 750 "$(landing_channel_expected_root_uid)" "$channel_gid" || return 1
  landing_channel_directory_matches "$manager_dir" 700 "$(landing_channel_expected_root_uid)" \
    "$(landing_channel_expected_root_gid)" || return 1
  landing_channel_file_matches "$runtime" 640 "$(landing_channel_expected_root_uid)" "$channel_gid" || return 1
  landing_channel_file_matches "$agent" 750 "$(landing_channel_expected_root_uid)" "$channel_gid" || return 1
  landing_channel_file_matches "$helper" 700 "$(landing_channel_expected_root_uid)" "$(landing_channel_expected_root_gid)" || return 1
  landing_channel_file_matches "$sudoers" 440 "$(landing_channel_expected_root_uid)" "$(landing_channel_expected_root_gid)" || return 1
  landing_channel_file_matches "$generation_file" 440 "$(landing_channel_expected_root_uid)" "$channel_gid" || return 1
  landing_channel_file_matches "$authorized" 640 "$(landing_channel_expected_root_uid)" "$channel_gid" || return 1
  [[ "$(<"$generation_file")" == "$(jq -r '.generation' "$identity")" ]] || return 1
  [[ "$(landing_channel_sha256 "$runtime")" == "$(jq -r '.runtime_sha256' "$identity")" ]] || return 1
  [[ "$(landing_channel_sha256 "$agent")" == "$(jq -r '.agent_launcher_sha256' "$identity")" ]] || return 1
  [[ "$(landing_channel_sha256 "$helper")" == "$(jq -r '.helper_launcher_sha256' "$identity")" ]] || return 1
  [[ "$(landing_channel_sha256 "$sudoers")" == "$(jq -r '.sudoers_sha256' "$identity")" ]] || return 1
  landing_channel_authorized_keys_is_valid "$identity" || return 1
  landing_channel_home_layout_is_expected || return 1
  landing_channel_runtime_layout_is_expected || return 1
  expected_sudoers="$(mktemp /tmp/sb-landing-sudoers.XXXXXX)" || return 1
  register_temp_path "$expected_sudoers" || { rm -f -- "$expected_sudoers" || true; return 1; }
  landing_channel_render_sudoers "$expected_sudoers" "$(jq -r '.generation' "$identity")" || return 1
  actual_sudoers="$(<"$sudoers")" || return 1
  [[ "$actual_sudoers" == "$(<"$expected_sudoers")" ]] || return 1
  rm -f -- "$expected_sudoers" || return 1
}

landing_restricted_channel_is_valid() {
  landing_restricted_channel_core_is_valid || return 1
  landing_startup_recovery_gate_files_are_valid
}

landing_channel_upgrade_source_is_valid() {
  landing_restricted_channel_core_is_valid || return 1
  landing_startup_recovery_gate_upgrade_source_is_valid
}

landing_channel_loaded_runtime_matches_identity() {
  local identity expected
  [[ "${LANDING_LOADED_RUNTIME_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || return 1
  identity="$(landing_channel_path "$LANDING_CHANNEL_IDENTITY_PATH")" || return 1
  validate_landing_channel_identity_file "$identity" || return 1
  expected="$(jq -r '.runtime_sha256' "$identity")" || return 1
  [[ "$LANDING_LOADED_RUNTIME_SHA256" == "$expected" ]]
}

landing_channel_state_parent_chain_is_safe() {
  local logical path manager root_uid root_gid
  for logical in /var /var/lib; do
    path="$(landing_channel_path "$logical")" || return 1
    landing_channel_system_directory_is_channel_traversable "$path" || return 1
  done
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  manager="$(landing_channel_path /var/lib/sb-user-manager)" || return 1
  landing_channel_directory_matches "$manager" 700 "$root_uid" "$root_gid"
}

landing_channel_create_account() {
  local gid uid
  landing_channel_update_active_journal group_attempted 0 0 || return 1
  LANDING_CHANNEL_GROUP_ATTEMPTED=true
  landing_channel_system_groupadd "$LANDING_CHANNEL_GROUP" || return 1
  landing_channel_sync_account_database || return 1
  landing_channel_read_group || return 1
  gid="$LANDING_CHANNEL_FOUND_GROUP_GID"
  [[ "$gid" =~ ^[0-9]+$ && "$gid" != 0 ]] || return 1
  LANDING_CHANNEL_ACTIVE_GID="$gid"
  landing_channel_update_active_journal user_attempted 0 "$gid" || return 1
  LANDING_CHANNEL_USER_ATTEMPTED=true
  landing_channel_system_useradd --gid "$LANDING_CHANNEL_GROUP" --home-dir "$LANDING_CHANNEL_HOME" \
    --shell "$LANDING_CHANNEL_SHELL" --comment "$LANDING_CHANNEL_GECOS" \
    --password "$LANDING_CHANNEL_PASSWORD_VALUE" --no-create-home "$LANDING_CHANNEL_ACCOUNT" || return 1
  landing_channel_sync_account_database || return 1
  landing_channel_read_account || return 1
  uid="$LANDING_CHANNEL_FOUND_UID"
  [[ "$uid" =~ ^[0-9]+$ && "$uid" != 0 ]] || return 1
  LANDING_CHANNEL_ACTIVE_UID="$uid"
  landing_channel_update_active_journal account_created "$uid" "$gid" || return 1
  landing_channel_account_matches "$uid" "$gid"
}

landing_channel_recreate_group() {
  local gid="$1"
  landing_channel_system_groupadd --gid "$gid" "$LANDING_CHANNEL_GROUP" || return 1
  landing_channel_sync_account_database || return 1
  landing_channel_read_group || return 1
  [[ "$LANDING_CHANNEL_FOUND_GROUP_GID" == "$gid" ]]
}

landing_channel_recreate_user() {
  local uid="$1" gid="$2"
  landing_channel_system_useradd --uid "$uid" --gid "$LANDING_CHANNEL_GROUP" \
    --home-dir "$LANDING_CHANNEL_HOME" --shell "$LANDING_CHANNEL_SHELL" \
    --comment "$LANDING_CHANNEL_GECOS" --password "$LANDING_CHANNEL_PASSWORD_VALUE" \
    --no-create-home "$LANDING_CHANNEL_ACCOUNT" || return 1
  landing_channel_sync_account_database || return 1
  landing_channel_account_matches "$uid" "$gid"
}

landing_channel_prepare_directories() {
  local gid="$1" root_uid root_gid system_root logical path
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  system_root="${SB_SYSTEM_ROOT:-/}"
  landing_channel_system_directory_is_safe "$system_root" || return 1
  landing_channel_ensure_system_directory /usr || return 1
  landing_channel_ensure_system_directory /usr/local || return 1
  landing_channel_ensure_system_directory /usr/local/bin || return 1
  landing_channel_ensure_system_directory /usr/local/libexec || return 1
  landing_channel_ensure_system_directory /etc || return 1
  landing_channel_ensure_system_directory /etc/sudoers.d || return 1
  landing_channel_ensure_system_directory /etc/systemd || return 1
  landing_channel_ensure_system_directory /etc/systemd/system || return 1
  landing_channel_ensure_system_directory "$LANDING_STARTUP_RECOVERY_DROPIN_DIRECTORY" || return 1
  landing_channel_ensure_system_directory /var || return 1
  landing_channel_ensure_system_directory /var/lib || return 1
  for logical in /usr /usr/local /usr/local/bin /usr/local/libexec /var /var/lib; do
    path="$(landing_channel_path "$logical")" || return 1
    landing_channel_system_directory_is_channel_traversable "$path" || return 1
  done
  landing_channel_ensure_owned_directory /var/lib/sb-user-manager 700 "$root_uid" "$root_gid" || return 1
  landing_channel_ensure_owned_directory "$LANDING_CHANNEL_RUNTIME_DIRECTORY" 750 "$root_uid" "$gid" || return 1
  landing_channel_ensure_owned_directory "$LANDING_CHANNEL_HOME" 750 "$root_uid" "$gid" || return 1
  landing_channel_ensure_owned_directory "$LANDING_CHANNEL_SSH_DIRECTORY" 750 "$root_uid" "$gid" || return 1
}

landing_channel_fresh_preflight() {
  local logical path
  if landing_channel_system_get_user "$LANDING_CHANNEL_ACCOUNT" >/dev/null 2>&1; then return 1; fi
  if landing_channel_system_get_group "$LANDING_CHANNEL_GROUP" >/dev/null 2>&1; then return 1; fi
  for logical in "$LANDING_CHANNEL_HOME" "$LANDING_CHANNEL_RUNTIME_DIRECTORY" \
    "$LANDING_CHANNEL_AGENT_PATH" "$LANDING_AGENT_HELPER_PATH" "$LANDING_CHANNEL_SUDOERS_PATH" \
    "$LANDING_CHANNEL_IDENTITY_PATH" "$LANDING_STARTUP_RECOVERY_UNIT_PATH" \
    "$LANDING_STARTUP_RECOVERY_DROPIN_PATH"; do
    path="$(landing_channel_path "$logical")" || return 1
    [[ ! -e "$path" && ! -L "$path" ]] || return 1
  done
}

landing_channel_snapshot_files() {
  local work="$1" snapshot logical label path state root_uid root_gid
  snapshot="$work/snapshot"
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  install -d -m 700 -- "$snapshot" || return 1
  while IFS=$'\t' read -r label logical; do
    path="$(landing_channel_path "$logical")" || return 1
    [[ -f "$path" && ! -L "$path" ]] || return 1
    install -m 600 -- "$path" "$snapshot/$label" || return 1
    sync_transaction_path "$snapshot/$label" || return 1
  done <<EOF
runtime	$LANDING_CHANNEL_RUNTIME_PATH
agent	$LANDING_CHANNEL_AGENT_PATH
helper	$LANDING_AGENT_HELPER_PATH
sudoers	$LANDING_CHANNEL_SUDOERS_PATH
generation	$LANDING_CHANNEL_GENERATION_PATH
identity	$LANDING_CHANNEL_IDENTITY_PATH
authorized_keys	$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH
EOF
  while IFS=$'\t' read -r label logical; do
    path="$(landing_channel_path "$logical")" || return 1
    state="$snapshot/${label}.state"
    if [[ -e "$path" || -L "$path" ]]; then
      landing_channel_file_matches "$path" 644 "$root_uid" "$root_gid" || return 1
      install -m 600 -- "$path" "$snapshot/$label" || return 1
      printf 'exists\n' > "$state" || return 1
    else
      : > "$snapshot/$label" || return 1
      printf 'missing\n' > "$state" || return 1
    fi
    chmod 600 "$snapshot/$label" "$state" || return 1
    sync_transaction_path "$snapshot/$label" || return 1
    sync_transaction_path "$state" || return 1
  done <<EOF
startup-recovery.service	$LANDING_STARTUP_RECOVERY_UNIT_PATH
singbox-recovery.conf	$LANDING_STARTUP_RECOVERY_DROPIN_PATH
EOF
  sync_transaction_path "$snapshot" || return 1
}

landing_channel_transaction_directory_is_safe() {
  local path root_uid root_gid
  path="$(landing_channel_path "$LANDING_CHANNEL_TRANSACTION_DIRECTORY")" || return 1
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  landing_channel_directory_matches "$path" 700 "$root_uid" "$root_gid"
}

validate_landing_channel_transaction_journal() {
  local path="${1:-$(landing_channel_path "$LANDING_CHANNEL_TRANSACTION_JOURNAL")}" root_uid root_gid
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  landing_channel_file_matches "$path" 600 "$root_uid" "$root_gid" || return 1
  jq -e -s 'length == 1' "$path" >/dev/null || return 1
  jq -e --argjson schema "$LANDING_CHANNEL_TRANSACTION_SCHEMA_VERSION" '
    type == "object" and
    (keys | sort) == ["gid", "mode", "phase", "schema_version", "transaction_id", "uid"] and
    .schema_version == $schema and
    (.transaction_id | type == "string" and test("^[0-9a-f]{32}$")) and
    (.mode == "fresh" or .mode == "update" or .mode == "uninstall") and
    (.phase == "prepared" or .phase == "group_attempted" or
      .phase == "user_attempted" or .phase == "account_created" or
      .phase == "files_active" or .phase == "active" or
      .phase == "committed" or .phase == "rolled_back") and
    (.uid | type == "number" and . == floor and . >= 0 and . <= 4294967294) and
    (.gid | type == "number" and . == floor and . >= 0 and . <= 4294967294) and
    if .mode == "fresh" then
      if .phase == "prepared" then .uid == 0 and .gid == 0
      elif .phase == "group_attempted" then .uid == 0
      elif .phase == "user_attempted" then .uid == 0 and .gid >= 1
      elif (.phase == "account_created" or .phase == "files_active" or .phase == "committed") then
        .uid >= 1 and .gid >= 1
      elif .phase == "rolled_back" then
        (.uid == 0 or .uid >= 1) and (.gid == 0 or .gid >= 1) and
        (.uid == 0 or .gid >= 1)
      else false
      end
    else
      (.phase == "active" or .phase == "committed" or .phase == "rolled_back") and
      .uid >= 1 and .gid >= 1
    end
  ' "$path" >/dev/null
}

landing_channel_snapshot_is_valid() {
  local work="$1" snapshot root_uid root_gid label state
  snapshot="$work/snapshot"
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  landing_channel_directory_matches "$snapshot" 700 "$root_uid" "$root_gid" || return 1
  for label in runtime agent helper sudoers generation identity authorized_keys; do
    landing_channel_file_matches "$snapshot/$label" 600 "$root_uid" "$root_gid" || return 1
  done
  for label in startup-recovery.service singbox-recovery.conf; do
    landing_channel_file_matches "$snapshot/$label" 600 "$root_uid" "$root_gid" || return 1
    landing_channel_file_matches "$snapshot/${label}.state" 600 "$root_uid" "$root_gid" || return 1
    state="$(<"$snapshot/${label}.state")" || return 1
    [[ "$state" == exists || "$state" == missing ]] || return 1
    if [[ "$state" == missing ]]; then
      [[ ! -s "$snapshot/$label" ]] || return 1
    fi
  done
}

landing_channel_persist_install_candidates() {
  local work="$1" transaction candidates root_uid root_gid name
  transaction="$(landing_channel_path "$LANDING_CHANNEL_TRANSACTION_DIRECTORY")" || return 1
  candidates="$transaction/candidates"
  landing_channel_transaction_directory_is_safe || return 1
  [[ ! -e "$candidates" && ! -L "$candidates" ]] || return 1
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  install -d -m 700 -- "$candidates" || return 1
  landing_channel_apply_ownership "$candidates" "$root_uid" "$root_gid" || return 1
  landing_channel_directory_matches "$candidates" 700 "$root_uid" "$root_gid" || return 1
  for name in runtime.sh agent helper sudoers generation identity.json authorized_keys \
    startup-recovery.service singbox-recovery.conf; do
    [[ -f "$work/$name" && ! -L "$work/$name" ]] || return 1
    install -m 600 -- "$work/$name" "$candidates/$name" || return 1
    landing_channel_apply_ownership "$candidates/$name" "$root_uid" "$root_gid" || return 1
    landing_channel_file_matches "$candidates/$name" 600 "$root_uid" "$root_gid" || return 1
    sync_transaction_path "$candidates/$name" || return 1
  done
  sync_transaction_path "$candidates" || return 1
  sync_transaction_path "$transaction" || return 1
}

landing_channel_install_candidates_are_valid() {
  local transaction candidates root_uid root_gid name
  transaction="$(landing_channel_path "$LANDING_CHANNEL_TRANSACTION_DIRECTORY")" || return 1
  candidates="$transaction/candidates"
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  landing_channel_directory_matches "$candidates" 700 "$root_uid" "$root_gid" || return 1
  for name in runtime.sh agent helper sudoers generation identity.json authorized_keys \
    startup-recovery.service singbox-recovery.conf; do
    landing_channel_file_matches "$candidates/$name" 600 "$root_uid" "$root_gid" || return 1
  done
}

landing_channel_write_transaction_journal() {
  local mode="$1" phase="$2" uid="$3" gid="$4" transaction_id="$5"
  local directory journal tmp root_uid root_gid
  directory="$(landing_channel_path "$LANDING_CHANNEL_TRANSACTION_DIRECTORY")" || return 1
  journal="$(landing_channel_path "$LANDING_CHANNEL_TRANSACTION_JOURNAL")" || return 1
  landing_channel_transaction_directory_is_safe || return 1
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  [[ "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ ]] || return 1
  [[ "$transaction_id" =~ ^[0-9a-f]{32}$ ]] || return 1
  tmp="$(mktemp "$directory/.landing-channel.XXXXXX")" || return 1
  register_temp_path "$tmp" || { rm -f -- "$tmp" || true; return 1; }
  if ! jq -n --argjson schema "$LANDING_CHANNEL_TRANSACTION_SCHEMA_VERSION" \
      --arg mode "$mode" --arg phase "$phase" --argjson uid "$uid" --argjson gid "$gid" \
      --arg transaction_id "$transaction_id" \
      '{schema_version:$schema,transaction_id:$transaction_id,mode:$mode,phase:$phase,uid:$uid,gid:$gid}' > "$tmp" ||
     ! chmod 600 "$tmp" ||
     ! landing_channel_apply_ownership "$tmp" "$root_uid" "$root_gid" ||
     ! validate_landing_channel_transaction_journal "$tmp" ||
     ! sync_transaction_path "$tmp"; then
    rm -f -- "$tmp" || true
    return 1
  fi
  mv -- "$tmp" "$journal" || { rm -f -- "$tmp" || true; return 1; }
  if ! sync_transaction_path "$directory"; then
    # 终态一旦完成 rename 就绝不反向执行；其余阶段仍沿用之前已同步的 journal 恢复。
    [[ "$phase" == committed || "$phase" == rolled_back ]] && return 2
    return 1
  fi
}

landing_channel_discard_transaction_directory() {
  local directory parent
  directory="$(landing_channel_path "$LANDING_CHANNEL_TRANSACTION_DIRECTORY")" || return 1
  [[ ! -e "$directory" && ! -L "$directory" ]] && return 0
  landing_channel_transaction_directory_is_safe || return 1
  parent="$(dirname -- "$directory")" || return 1
  rm -rf -- "$directory" || return 1
  sync_transaction_path "$parent" || return 1
}

landing_channel_begin_transaction() {
  local mode="$1" uid="$2" gid="$3" directory root_uid root_gid phase transaction_id
  directory="$(landing_channel_path "$LANDING_CHANNEL_TRANSACTION_DIRECTORY")" || return 1
  [[ ! -e "$directory" && ! -L "$directory" ]] || return 1
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  transaction_id="$(python3 -I -c 'import secrets; print(secrets.token_hex(16))')" || return 1
  [[ "$transaction_id" =~ ^[0-9a-f]{32}$ ]] || return 1
  landing_channel_ensure_owned_directory "$LANDING_CHANNEL_TRANSACTION_DIRECTORY" 700 "$root_uid" "$root_gid" || return 1
  if ! sync_transaction_path "$directory" ||
     ! sync_transaction_path "$(dirname -- "$directory")"; then
    landing_channel_discard_transaction_directory || true
    return 1
  fi
  if [[ "$mode" == fresh ]]; then
    uid=0
    gid=0
    phase=prepared
  else
    [[ "$mode" == update || "$mode" == uninstall ]] || {
      landing_channel_discard_transaction_directory || true
      return 1
    }
    landing_channel_snapshot_files "$directory" || {
      landing_channel_discard_transaction_directory || true
      return 1
    }
    landing_channel_snapshot_is_valid "$directory" || {
      landing_channel_discard_transaction_directory || true
      return 1
    }
    phase=active
  fi
  landing_channel_write_transaction_journal "$mode" "$phase" "$uid" "$gid" "$transaction_id" || {
    landing_channel_discard_transaction_directory || true
    return 1
  }
  LANDING_CHANNEL_ACTIVE_MODE="$mode"
  LANDING_CHANNEL_ACTIVE_WORK="$directory"
  LANDING_CHANNEL_ACTIVE_UID="$uid"
  LANDING_CHANNEL_ACTIVE_GID="$gid"
  LANDING_CHANNEL_ACTIVE_PHASE="$phase"
  LANDING_CHANNEL_ACTIVE_TRANSACTION_ID="$transaction_id"
}

landing_channel_update_active_journal() {
  local phase="$1" uid="${2:-$LANDING_CHANNEL_ACTIVE_UID}" gid="${3:-$LANDING_CHANNEL_ACTIVE_GID}" rc=0
  [[ -n "$LANDING_CHANNEL_ACTIVE_MODE" && -n "$LANDING_CHANNEL_ACTIVE_WORK" ]] || return 1
  [[ "$LANDING_CHANNEL_ACTIVE_WORK" == "$(landing_channel_path "$LANDING_CHANNEL_TRANSACTION_DIRECTORY")" ]] || return 1
  [[ -n "$uid" ]] || uid=0
  [[ -n "$gid" ]] || gid=0
  landing_channel_write_transaction_journal "$LANDING_CHANNEL_ACTIVE_MODE" "$phase" "$uid" "$gid" \
    "$LANDING_CHANNEL_ACTIVE_TRANSACTION_ID" || rc=$?
  [[ "$rc" != 1 ]] || return 1
  LANDING_CHANNEL_ACTIVE_PHASE="$phase"
  LANDING_CHANNEL_ACTIVE_UID="$uid"
  LANDING_CHANNEL_ACTIVE_GID="$gid"
  return "$rc"
}

landing_channel_restore_systemd_file() {
  local work="$1" label="$2" logical="$3" state target root_uid root_gid actual expected
  state="$(<"$work/snapshot/${label}.state")" || return 1
  target="$(landing_channel_path "$logical")" || return 1
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  case "$state" in
    exists)
      landing_channel_atomic_install_file "$work/snapshot/$label" "$logical" 644 "$root_uid" "$root_gid"
      ;;
    missing)
      if [[ -e "$target" || -L "$target" ]]; then
        landing_channel_file_matches "$target" 644 "$root_uid" "$root_gid" || return 1
        actual="$(<"$target")" || return 1
        case "$logical" in
          "$LANDING_STARTUP_RECOVERY_UNIT_PATH") expected="$(landing_startup_recovery_unit_content)" ;;
          "$LANDING_STARTUP_RECOVERY_DROPIN_PATH") expected="$(landing_startup_recovery_dropin_content)" ;;
          *) return 1 ;;
        esac
        [[ "$actual" == "$expected" ]] || return 1
        landing_channel_remove_file "$logical" || return 1
      fi
      ;;
    *) return 1 ;;
  esac
}

landing_channel_restore_files() {
  local work="$1" gid="$2" root_uid root_gid
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  landing_channel_snapshot_is_valid "$work" || return 1
  landing_channel_prepare_directories "$gid" || return 1
  landing_channel_atomic_install_file "$work/snapshot/runtime" "$LANDING_CHANNEL_RUNTIME_PATH" 640 "$root_uid" "$gid" || return 1
  landing_channel_atomic_install_file "$work/snapshot/agent" "$LANDING_CHANNEL_AGENT_PATH" 750 "$root_uid" "$gid" || return 1
  landing_channel_atomic_install_file "$work/snapshot/helper" "$LANDING_AGENT_HELPER_PATH" 700 "$root_uid" "$root_gid" || return 1
  landing_channel_atomic_install_file "$work/snapshot/sudoers" "$LANDING_CHANNEL_SUDOERS_PATH" 440 "$root_uid" "$root_gid" || return 1
  landing_channel_atomic_install_file "$work/snapshot/generation" "$LANDING_CHANNEL_GENERATION_PATH" 440 "$root_uid" "$gid" || return 1
  landing_channel_atomic_install_file "$work/snapshot/identity" "$LANDING_CHANNEL_IDENTITY_PATH" 600 "$root_uid" "$root_gid" || return 1
  landing_channel_atomic_install_file "$work/snapshot/authorized_keys" "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH" 640 "$root_uid" "$gid" || return 1
  landing_channel_restore_systemd_file "$work" startup-recovery.service \
    "$LANDING_STARTUP_RECOVERY_UNIT_PATH" || return 1
  landing_channel_restore_systemd_file "$work" singbox-recovery.conf \
    "$LANDING_STARTUP_RECOVERY_DROPIN_PATH" || return 1
  landing_startup_recovery_daemon_reload || return 1
}

landing_channel_remove_file() {
  local logical="$1" path
  path="$(landing_channel_path "$logical")" || return 1
  [[ ! -e "$path" && ! -L "$path" ]] && return 0
  [[ -f "$path" || -L "$path" ]] || return 1
  rm -f -- "$path" || return 1
  sync_transaction_path "$(dirname -- "$path")" || return 1
}

landing_channel_remove_empty_directory() {
  local logical="$1" path
  path="$(landing_channel_path "$logical")" || return 1
  [[ ! -e "$path" && ! -L "$path" ]] && return 0
  [[ -d "$path" && ! -L "$path" ]] || return 1
  rmdir -- "$path" || return 1
  sync_transaction_path "$(dirname -- "$path")" || return 1
}

landing_channel_home_layout_is_expected() (
  local home ssh_dir authorized generation
  home="$(landing_channel_path "$LANDING_CHANNEL_HOME")" || return 1
  ssh_dir="$(landing_channel_path "$LANDING_CHANNEL_SSH_DIRECTORY")" || return 1
  authorized="$(landing_channel_path "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH")" || return 1
  generation="$(landing_channel_path "$LANDING_CHANNEL_GENERATION_PATH")" || return 1
  landing_channel_directory_contains_only "$home" "$generation" "$ssh_dir" || return 1
  landing_channel_directory_contains_only "$ssh_dir" "$authorized"
)

landing_channel_runtime_layout_is_expected() (
  local runtime_dir runtime
  local -a runtime_entries
  runtime_dir="$(landing_channel_path "$LANDING_CHANNEL_RUNTIME_DIRECTORY")" || return 1
  runtime="$(landing_channel_path "$LANDING_CHANNEL_RUNTIME_PATH")" || return 1
  shopt -s dotglob nullglob
  runtime_entries=("$runtime_dir"/* "")
  [[ ${#runtime_entries[@]} -eq 2 && "${runtime_entries[0]}" == "$runtime" ]]
)

landing_channel_directory_contains_only() (
  local path="$1" entry allowed match
  local -a entries allowed_entries
  shift
  allowed_entries=("$@" "")
  [[ -d "$path" && ! -L "$path" ]] || return 1
  shopt -s dotglob nullglob
  entries=("$path"/* "")
  for entry in "${entries[@]}"; do
    [[ -n "$entry" ]] || continue
    match=false
    for allowed in "${allowed_entries[@]}"; do
      [[ -n "$allowed" ]] || continue
      if [[ "$entry" == "$allowed" ]]; then
        match=true
        break
      fi
    done
    [[ "$match" == true ]] || return 1
  done
)

landing_channel_fresh_files_are_owned() {
  local candidates root_uid root_gid gid candidate logical mode expected_gid path
  local home ssh_dir authorized generation runtime_dir runtime
  landing_channel_install_candidates_are_valid || return 1
  candidates="$(landing_channel_path "$LANDING_CHANNEL_TRANSACTION_DIRECTORY")/candidates"
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  gid="$LANDING_CHANNEL_ACTIVE_GID"
  [[ "$gid" =~ ^[0-9]+$ && "$gid" != 0 ]] || return 1
  while IFS=$'\t' read -r candidate logical mode expected_gid; do
    path="$(landing_channel_path "$logical")" || return 1
    [[ ! -e "$path" && ! -L "$path" ]] && continue
    [[ "$expected_gid" == channel ]] && expected_gid="$gid"
    [[ "$expected_gid" == root ]] && expected_gid="$root_gid"
    landing_channel_file_matches "$path" "$mode" "$root_uid" "$expected_gid" || return 1
    cmp -s -- "$candidates/$candidate" "$path" || return 1
  done <<EOF
runtime.sh	$LANDING_CHANNEL_RUNTIME_PATH	640	channel
agent	$LANDING_CHANNEL_AGENT_PATH	750	channel
helper	$LANDING_AGENT_HELPER_PATH	700	root
sudoers	$LANDING_CHANNEL_SUDOERS_PATH	440	root
generation	$LANDING_CHANNEL_GENERATION_PATH	440	channel
identity.json	$LANDING_CHANNEL_IDENTITY_PATH	600	root
authorized_keys	$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH	640	channel
startup-recovery.service	$LANDING_STARTUP_RECOVERY_UNIT_PATH	644	root
singbox-recovery.conf	$LANDING_STARTUP_RECOVERY_DROPIN_PATH	644	root
EOF
  home="$(landing_channel_path "$LANDING_CHANNEL_HOME")" || return 1
  ssh_dir="$(landing_channel_path "$LANDING_CHANNEL_SSH_DIRECTORY")" || return 1
  authorized="$(landing_channel_path "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH")" || return 1
  generation="$(landing_channel_path "$LANDING_CHANNEL_GENERATION_PATH")" || return 1
  runtime_dir="$(landing_channel_path "$LANDING_CHANNEL_RUNTIME_DIRECTORY")" || return 1
  runtime="$(landing_channel_path "$LANDING_CHANNEL_RUNTIME_PATH")" || return 1
  if [[ -e "$runtime_dir" || -L "$runtime_dir" ]]; then
    if ! landing_channel_directory_matches "$runtime_dir" 750 "$root_uid" "$gid" &&
       ! landing_channel_directory_matches "$runtime_dir" 750 "$root_uid" "$root_gid" &&
       ! landing_channel_directory_matches "$runtime_dir" 700 "$root_uid" "$root_gid"; then
      return 1
    fi
    landing_channel_directory_contains_only "$runtime_dir" "$runtime" || return 1
  fi
  if [[ -e "$home" || -L "$home" ]]; then
    if ! landing_channel_directory_matches "$home" 750 "$root_uid" "$gid" &&
       ! landing_channel_directory_matches "$home" 750 "$root_uid" "$root_gid" &&
       ! landing_channel_directory_matches "$home" 700 "$root_uid" "$root_gid"; then
      return 1
    fi
    landing_channel_directory_contains_only "$home" "$generation" "$ssh_dir" || return 1
  fi
  if [[ -e "$ssh_dir" || -L "$ssh_dir" ]]; then
    if ! landing_channel_directory_matches "$ssh_dir" 750 "$root_uid" "$gid" &&
       ! landing_channel_directory_matches "$ssh_dir" 750 "$root_uid" "$root_gid" &&
       ! landing_channel_directory_matches "$ssh_dir" 700 "$root_uid" "$root_gid"; then
      return 1
    fi
    landing_channel_directory_contains_only "$ssh_dir" "$authorized" || return 1
  fi
}

landing_channel_remove_fresh_resources() {
  local candidate_uid rc=0
  if [[ "$LANDING_CHANNEL_ACTIVE_PHASE" == files_active ]]; then
    landing_channel_fresh_files_are_owned || return 1
    landing_channel_remove_file "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH" || rc=1
    landing_channel_remove_file "$LANDING_CHANNEL_IDENTITY_PATH" || rc=1
    landing_channel_remove_file "$LANDING_CHANNEL_GENERATION_PATH" || rc=1
    landing_channel_remove_file "$LANDING_CHANNEL_SUDOERS_PATH" || rc=1
    landing_channel_remove_file "$LANDING_STARTUP_RECOVERY_DROPIN_PATH" || rc=1
    landing_channel_remove_file "$LANDING_STARTUP_RECOVERY_UNIT_PATH" || rc=1
    landing_startup_recovery_daemon_reload || rc=1
    landing_channel_remove_file "$LANDING_AGENT_HELPER_PATH" || rc=1
    landing_channel_remove_file "$LANDING_CHANNEL_AGENT_PATH" || rc=1
    landing_channel_remove_file "$LANDING_CHANNEL_RUNTIME_PATH" || rc=1
    landing_channel_remove_empty_directory "$LANDING_CHANNEL_SSH_DIRECTORY" || rc=1
    landing_channel_remove_empty_directory "$LANDING_CHANNEL_HOME" || rc=1
    landing_channel_remove_empty_directory "$LANDING_CHANNEL_RUNTIME_DIRECTORY" || rc=1
    [[ "$rc" == 0 ]] || return 1
  elif [[ "$LANDING_CHANNEL_ACTIVE_PHASE" != prepared &&
          "$LANDING_CHANNEL_ACTIVE_PHASE" != group_attempted &&
          "$LANDING_CHANNEL_ACTIVE_PHASE" != user_attempted &&
          "$LANDING_CHANNEL_ACTIVE_PHASE" != account_created ]]; then
    return 1
  fi
  if [[ ( -z "$LANDING_CHANNEL_ACTIVE_GID" || "$LANDING_CHANNEL_ACTIVE_GID" == 0 ) &&
        "$LANDING_CHANNEL_GROUP_ATTEMPTED" == true ]] &&
     landing_channel_system_get_group "$LANDING_CHANNEL_GROUP" >/dev/null 2>&1; then
    if landing_channel_read_group &&
       [[ "$LANDING_CHANNEL_FOUND_GROUP_GID" =~ ^[0-9]+$ && "$LANDING_CHANNEL_FOUND_GROUP_GID" != 0 ]]; then
      LANDING_CHANNEL_ACTIVE_GID="$LANDING_CHANNEL_FOUND_GROUP_GID"
    else
      rc=1
    fi
  fi
  if [[ ( -z "$LANDING_CHANNEL_ACTIVE_UID" || "$LANDING_CHANNEL_ACTIVE_UID" == 0 ) &&
        -n "$LANDING_CHANNEL_ACTIVE_GID" && "$LANDING_CHANNEL_ACTIVE_GID" != 0 &&
        "$LANDING_CHANNEL_USER_ATTEMPTED" == true ]] &&
     landing_channel_system_get_user "$LANDING_CHANNEL_ACCOUNT" >/dev/null 2>&1; then
    if landing_channel_read_account; then
      candidate_uid="$LANDING_CHANNEL_FOUND_UID"
      if [[ "$candidate_uid" =~ ^[0-9]+$ && "$candidate_uid" != 0 ]] &&
         landing_channel_account_matches "$candidate_uid" "$LANDING_CHANNEL_ACTIVE_GID"; then
        LANDING_CHANNEL_ACTIVE_UID="$candidate_uid"
      else
        rc=1
      fi
    else
      rc=1
    fi
  fi
  if landing_channel_system_get_user "$LANDING_CHANNEL_ACCOUNT" >/dev/null 2>&1; then
    if [[ -n "$LANDING_CHANNEL_ACTIVE_UID" && "$LANDING_CHANNEL_ACTIVE_UID" != 0 &&
          -n "$LANDING_CHANNEL_ACTIVE_GID" && "$LANDING_CHANNEL_ACTIVE_GID" != 0 ]] &&
       landing_channel_account_matches "$LANDING_CHANNEL_ACTIVE_UID" "$LANDING_CHANNEL_ACTIVE_GID"; then
      landing_channel_system_userdel "$LANDING_CHANNEL_ACCOUNT" || rc=1
      if [[ "$rc" == 0 ]]; then landing_channel_sync_account_database || rc=1; fi
    else
      rc=1
    fi
  fi
  [[ "$rc" == 0 ]] || return 1
  if landing_channel_system_get_group "$LANDING_CHANNEL_GROUP" >/dev/null 2>&1; then
    if landing_channel_read_group &&
       [[ -n "$LANDING_CHANNEL_ACTIVE_GID" && "$LANDING_CHANNEL_ACTIVE_GID" != 0 &&
          "$LANDING_CHANNEL_FOUND_GROUP_GID" == "$LANDING_CHANNEL_ACTIVE_GID" ]]; then
      landing_channel_system_groupdel "$LANDING_CHANNEL_GROUP" || rc=1
      if [[ "$rc" == 0 ]]; then landing_channel_sync_account_database || rc=1; fi
    else
      rc=1
    fi
  fi
  return "$rc"
}

landing_channel_update_current_entry_is_owned() {
  local authorized identity root_uid channel_gid
  authorized="$(landing_channel_path "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH")" || return 1
  [[ ! -e "$authorized" && ! -L "$authorized" ]] && return 0
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  channel_gid="$LANDING_CHANNEL_ACTIVE_GID"
  [[ "$channel_gid" =~ ^[0-9]+$ && "$channel_gid" != 0 ]] || return 1
  landing_channel_file_matches "$authorized" 640 "$root_uid" "$channel_gid" || return 1
  if cmp -s -- "$LANDING_CHANNEL_ACTIVE_WORK/snapshot/authorized_keys" "$authorized"; then
    return 0
  fi
  identity="$(landing_channel_path "$LANDING_CHANNEL_IDENTITY_PATH")" || return 1
  validate_landing_channel_identity_file "$identity" || return 1
  [[ "$(jq -r '.uid' "$identity")" == "$LANDING_CHANNEL_ACTIVE_UID" &&
     "$(jq -r '.gid' "$identity")" == "$LANDING_CHANNEL_ACTIVE_GID" ]] || return 1
  landing_channel_authorized_keys_is_valid "$identity"
}

landing_channel_cleanup_orphan_atomic_files() (
  local logical parent entry name uid mode expected_uid transaction_id
  local -a entries
  expected_uid="$(landing_channel_expected_root_uid)" || return 1
  transaction_id="$LANDING_CHANNEL_ACTIVE_TRANSACTION_ID"
  [[ "$transaction_id" =~ ^[0-9a-f]{32}$ ]] || return 1
  shopt -s nullglob
  for logical in \
    /usr/local/bin /usr/local/libexec "$LANDING_CHANNEL_RUNTIME_DIRECTORY" \
    /etc/sudoers.d /etc/systemd/system "$LANDING_STARTUP_RECOVERY_DROPIN_DIRECTORY" \
    /var/lib/sb-user-manager "$LANDING_CHANNEL_HOME" \
    "$LANDING_CHANNEL_SSH_DIRECTORY"; do
    parent="$(landing_channel_path "$logical")" || return 1
    [[ ! -e "$parent" && ! -L "$parent" ]] && continue
    landing_channel_directory_is_root_controlled "$parent" || return 1
    # Bash 3.2 在 nounset 模式下展开真正的空数组会报错；保留空哨兵。
    entries=("$parent"/.landing-channel."$transaction_id".* "")
    for entry in "${entries[@]}"; do
      [[ -n "$entry" ]] || continue
      name="${entry##*/}"
      [[ "$name" =~ ^\.landing-channel\.${transaction_id}\.[A-Za-z0-9]{6}$ ]] || return 1
      [[ -f "$entry" && ! -L "$entry" ]] || return 1
      uid="$(manager_file_uid "$entry")" || return 1
      mode="$(manager_file_mode "$entry")" || return 1
      [[ "$uid" == "$expected_uid" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
      (( (8#$mode & 0022) == 0 )) || return 1
      rm -f -- "$entry" || return 1
      sync_transaction_path "$parent" || return 1
    done
  done
)

landing_channel_reset_active_transaction() {
  LANDING_CHANNEL_ACTIVE_MODE=""
  LANDING_CHANNEL_ACTIVE_WORK=""
  LANDING_CHANNEL_ACTIVE_UID=""
  LANDING_CHANNEL_ACTIVE_GID=""
  LANDING_CHANNEL_ACTIVE_PHASE=""
  LANDING_CHANNEL_ACTIVE_TRANSACTION_ID=""
  LANDING_CHANNEL_GROUP_ATTEMPTED=false
  LANDING_CHANNEL_USER_ATTEMPTED=false
  clear_signal_rollback
}

landing_channel_finish_rollback_transaction() {
  local rc=0
  # 运行态已经完整恢复；先持久标记终态，之后即使目录清理中断也只继续清理。
  clear_signal_rollback
  landing_channel_update_active_journal rolled_back || rc=$?
  [[ "$rc" != 1 ]] || return 1
  landing_channel_reset_active_transaction
  [[ "$rc" == 0 ]] || return 2
  landing_channel_discard_transaction_directory || return 2
}

landing_channel_rollback_install() {
  local rc=0
  if [[ "$LANDING_CHANNEL_ACTIVE_MODE" == update ||
        "$LANDING_CHANNEL_ACTIVE_PHASE" == files_active ]]; then
    landing_channel_cleanup_orphan_atomic_files || rc=1
  fi
  [[ "$rc" == 0 ]] || return 1
  case "$LANDING_CHANNEL_ACTIVE_MODE" in
    fresh) landing_channel_remove_fresh_resources || rc=1 ;;
    update)
      landing_channel_update_current_entry_is_owned || rc=1
      if [[ "$rc" == 0 ]]; then
        landing_channel_remove_file "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH" || rc=1
      fi
      if [[ "$rc" == 0 ]]; then
        landing_channel_account_matches "$LANDING_CHANNEL_ACTIVE_UID" "$LANDING_CHANNEL_ACTIVE_GID" || rc=1
      fi
      if [[ "$rc" == 0 ]]; then
        landing_channel_restore_files "$LANDING_CHANNEL_ACTIVE_WORK" "$LANDING_CHANNEL_ACTIVE_GID" || rc=1
      fi
      ;;
    *) rc=1 ;;
  esac
  if [[ "$rc" == 0 ]]; then
    landing_channel_finish_rollback_transaction || rc=$?
  fi
  return "$rc"
}

landing_channel_rollback_uninstall() {
  local rc=0 lookup_rc
  landing_channel_cleanup_orphan_atomic_files || return 1
  if landing_channel_system_get_group "$LANDING_CHANNEL_GROUP" >/dev/null 2>&1; then
    if ! landing_channel_read_group ||
       [[ "$LANDING_CHANNEL_FOUND_GROUP_GID" != "$LANDING_CHANNEL_ACTIVE_GID" ]]; then
      return 1
    fi
  else
    lookup_rc=$?
    [[ "$lookup_rc" == 2 ]] || return 1
    landing_channel_recreate_group "$LANDING_CHANNEL_ACTIVE_GID" || rc=1
  fi
  if [[ "$rc" == 0 ]]; then
    if landing_channel_system_get_user "$LANDING_CHANNEL_ACCOUNT" >/dev/null 2>&1; then
      landing_channel_account_matches "$LANDING_CHANNEL_ACTIVE_UID" "$LANDING_CHANNEL_ACTIVE_GID" || rc=1
    else
      lookup_rc=$?
      if [[ "$lookup_rc" == 2 ]]; then
        landing_channel_recreate_user "$LANDING_CHANNEL_ACTIVE_UID" "$LANDING_CHANNEL_ACTIVE_GID" || rc=1
      else
        rc=1
      fi
    fi
  fi
  if [[ "$rc" == 0 ]]; then
    landing_channel_account_matches "$LANDING_CHANNEL_ACTIVE_UID" "$LANDING_CHANNEL_ACTIVE_GID" || rc=1
  fi
  if [[ "$rc" == 0 ]]; then
    landing_channel_restore_files "$LANDING_CHANNEL_ACTIVE_WORK" "$LANDING_CHANNEL_ACTIVE_GID" || rc=1
  fi
  if [[ "$rc" == 0 ]]; then
    landing_channel_finish_rollback_transaction || rc=$?
  fi
  return "$rc"
}

landing_channel_commit_active_transaction() {
  local rc=0
  # 从写入 committed 标记开始不可再回滚；中断只允许由持久 journal 判定最终状态。
  clear_signal_rollback
  landing_channel_update_active_journal committed || rc=$?
  [[ "$rc" != 1 ]] || return 1
  landing_channel_reset_active_transaction
  [[ "$rc" == 0 ]] || return 2
  landing_channel_discard_transaction_directory || return 2
}

landing_channel_load_pending_transaction() {
  local journal mode phase uid gid transaction_id
  journal="$(landing_channel_path "$LANDING_CHANNEL_TRANSACTION_JOURNAL")" || return 1
  landing_channel_transaction_directory_is_safe || return 1
  validate_landing_channel_transaction_journal "$journal" || return 1
  mode="$(jq -r '.mode' "$journal")" || return 1
  phase="$(jq -r '.phase' "$journal")" || return 1
  uid="$(jq -r '.uid' "$journal")" || return 1
  gid="$(jq -r '.gid' "$journal")" || return 1
  transaction_id="$(jq -r '.transaction_id' "$journal")" || return 1
  LANDING_CHANNEL_ACTIVE_MODE="$mode"
  LANDING_CHANNEL_ACTIVE_WORK="$(landing_channel_path "$LANDING_CHANNEL_TRANSACTION_DIRECTORY")" || return 1
  LANDING_CHANNEL_ACTIVE_UID="$uid"
  LANDING_CHANNEL_ACTIVE_GID="$gid"
  LANDING_CHANNEL_ACTIVE_PHASE="$phase"
  LANDING_CHANNEL_ACTIVE_TRANSACTION_ID="$transaction_id"
  LANDING_CHANNEL_GROUP_ATTEMPTED=false
  LANDING_CHANNEL_USER_ATTEMPTED=false
  if [[ "$mode" == fresh ]]; then
    case "$phase" in
      group_attempted) LANDING_CHANNEL_GROUP_ATTEMPTED=true ;;
      user_attempted|account_created|files_active)
        LANDING_CHANNEL_GROUP_ATTEMPTED=true
        LANDING_CHANNEL_USER_ATTEMPTED=true
        ;;
      prepared|committed|rolled_back) ;;
      *) return 1 ;;
    esac
  else
    [[ "$phase" == active || "$phase" == committed || "$phase" == rolled_back ]] || return 1
    # committed 已经是最终状态；清理事务目录中途崩溃时快照可能只剩一部分。
    # 只有仍需回滚的 active 事务才依赖完整快照。
    if [[ "$phase" == active ]]; then
      landing_channel_snapshot_is_valid "$LANDING_CHANNEL_ACTIVE_WORK" || return 1
    fi
  fi
}

landing_channel_recover_pending_transaction() {
  local directory journal phase
  directory="$(landing_channel_path "$LANDING_CHANNEL_TRANSACTION_DIRECTORY")" || return 1
  journal="$(landing_channel_path "$LANDING_CHANNEL_TRANSACTION_JOURNAL")" || return 1
  [[ -z "$LANDING_CHANNEL_ACTIVE_MODE" ]] || return 1
  [[ ! -L "$directory" ]] || return 1
  [[ -e "$directory" ]] || return 0
  landing_channel_transaction_directory_is_safe || return 1
  if [[ ! -e "$journal" && ! -L "$journal" ]]; then
    # Journal 会在任何账户或文件变更前落盘；没有 journal 的安全目录只可能是准备阶段残留。
    landing_channel_discard_transaction_directory
    return
  fi
  landing_channel_load_pending_transaction || return 1
  phase="$LANDING_CHANNEL_ACTIVE_PHASE"
  if [[ "$phase" == committed || "$phase" == rolled_back ]]; then
    landing_channel_reset_active_transaction
    landing_channel_discard_transaction_directory
    return
  fi
  set_signal_rollback landing_channel_signal_rollback || return 1
  case "$LANDING_CHANNEL_ACTIVE_MODE" in
    fresh|update) landing_channel_rollback_install ;;
    uninstall) landing_channel_rollback_uninstall ;;
    *) return 1 ;;
  esac
}

landing_channel_signal_rollback() {
  case "$LANDING_CHANNEL_ACTIVE_MODE" in
    fresh|update) landing_channel_rollback_install ;;
    uninstall) landing_channel_rollback_uninstall ;;
    *) return 0 ;;
  esac
}

landing_channel_probe_entrypoints() {
  local agent helper output rc
  [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]] && return 0
  agent="$(landing_channel_path "$LANDING_CHANNEL_AGENT_PATH")" || return 1
  helper="$(landing_channel_path "$LANDING_AGENT_HELPER_PATH")" || return 1
  rc=0
  # 显式非法参数保证探针不受管理员当前 SSH_* 环境影响，也绝不进入 stdin handoff。
  output="$($agent unexpected 2>/dev/null)" || rc=$?
  [[ "$rc" == 64 ]] || return 1
  printf '%s\n' "$output" | jq -e '.status == "error" and .code == "restricted_channel_rejected"' >/dev/null || return 1
  rc=0
  output="$($helper unexpected 2>/dev/null)" || rc=$?
  [[ "$rc" == 64 ]] || return 1
  printf '%s\n' "$output" | jq -e '.status == "error" and .code == "arguments_rejected"' >/dev/null
}

landing_channel_commit_candidates() {
  local work="$1" gid="$2" root_uid root_gid
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  landing_channel_atomic_install_file "$work/runtime.sh" "$LANDING_CHANNEL_RUNTIME_PATH" 640 "$root_uid" "$gid" || return 1
  landing_channel_atomic_install_file "$work/agent" "$LANDING_CHANNEL_AGENT_PATH" 750 "$root_uid" "$gid" || return 1
  landing_channel_atomic_install_file "$work/helper" "$LANDING_AGENT_HELPER_PATH" 700 "$root_uid" "$root_gid" || return 1
  landing_channel_atomic_install_file "$work/startup-recovery.service" \
    "$LANDING_STARTUP_RECOVERY_UNIT_PATH" 644 "$root_uid" "$root_gid" || return 1
  landing_channel_atomic_install_file "$work/singbox-recovery.conf" \
    "$LANDING_STARTUP_RECOVERY_DROPIN_PATH" 644 "$root_uid" "$root_gid" || return 1
  landing_startup_recovery_daemon_reload || return 1
  landing_channel_atomic_install_file "$work/sudoers" "$LANDING_CHANNEL_SUDOERS_PATH" 440 "$root_uid" "$root_gid" || return 1
  landing_channel_atomic_install_file "$work/generation" "$LANDING_CHANNEL_GENERATION_PATH" 440 "$root_uid" "$gid" || return 1
  landing_channel_probe_entrypoints || return 1
  landing_channel_atomic_install_file "$work/identity.json" "$LANDING_CHANNEL_IDENTITY_PATH" 600 "$root_uid" "$root_gid" || return 1
}

landing_channel_activate_remote_entry() {
  local work="$1" gid="$2" root_uid
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  [[ "$gid" =~ ^[0-9]+$ && "$gid" != 0 ]] || return 1
  # SSH key 最后激活，避免首次失败时暴露半安装通道。
  landing_channel_atomic_install_file "$work/authorized_keys" "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH" 640 "$root_uid" "$gid" || return 1
}

landing_channel_candidates_match_installed() {
  local work="$1" candidate logical path
  while IFS=$'\t' read -r candidate logical; do
    path="$(landing_channel_path "$logical")" || return 1
    cmp -s -- "$work/$candidate" "$path" || return 1
  done <<EOF
runtime.sh	$LANDING_CHANNEL_RUNTIME_PATH
agent	$LANDING_CHANNEL_AGENT_PATH
helper	$LANDING_AGENT_HELPER_PATH
sudoers	$LANDING_CHANNEL_SUDOERS_PATH
generation	$LANDING_CHANNEL_GENERATION_PATH
identity.json	$LANDING_CHANNEL_IDENTITY_PATH
authorized_keys	$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH
startup-recovery.service	$LANDING_STARTUP_RECOVERY_UNIT_PATH
singbox-recovery.conf	$LANDING_STARTUP_RECOVERY_DROPIN_PATH
EOF
}

landing_channel_install_unlocked() {
  local landing_id="$1" allowed_ipv4="$2" work="$3" identity uid gid mode transaction_rc=0
  identity="$(landing_channel_path "$LANDING_CHANNEL_IDENTITY_PATH")" || return 1
  if [[ -e "$identity" || -L "$identity" ]]; then
    landing_channel_upgrade_source_is_valid || return 1
    [[ "$(jq -r '.landing_id' "$identity")" == "$landing_id" ]] || return 1
    uid="$(jq -r '.uid' "$identity")" || return 1
    gid="$(jq -r '.gid' "$identity")" || return 1
    landing_channel_render_identity "$landing_id" "$allowed_ipv4" "$uid" "$gid" \
      "$work" "$work/identity.json" || return 1
    if landing_channel_candidates_match_installed "$work"; then
      return 0
    fi
    mode=update
  else
    landing_channel_fresh_preflight || return 1
    mode=fresh
    uid=""
    gid=""
  fi
  if [[ "$mode" == update ]]; then
    landing_channel_account_has_no_processes "$uid" || return 1
  fi
  landing_channel_begin_transaction "$mode" "$uid" "$gid" || return 1
  set_signal_rollback landing_channel_signal_rollback || {
    landing_channel_reset_active_transaction
    landing_channel_discard_transaction_directory || true
    return 1
  }
  if [[ "$mode" == fresh ]]; then
    if ! landing_channel_create_account; then
      landing_channel_rollback_install || true
      return 1
    fi
    uid="$LANDING_CHANNEL_ACTIVE_UID"
    gid="$LANDING_CHANNEL_ACTIVE_GID"
    # useradd 只检查账户数据库；立即拒绝仍以该数值 UID 运行的孤儿进程，
    # 不让它在最终二次检查前看见 helper、sudoers 或身份材料。
    if ! landing_channel_account_has_no_processes "$uid"; then
      landing_channel_rollback_install || true
      return 1
    fi
  fi
  if [[ "$mode" == update ]] &&
     { ! landing_channel_remove_file "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH" ||
       ! landing_channel_account_has_no_processes "$uid"; }; then
    landing_channel_rollback_install || true
    return 1
  fi
  if [[ "$mode" == fresh ]] &&
     ! landing_channel_render_identity "$landing_id" "$allowed_ipv4" "$uid" "$gid" "$work" "$work/identity.json"; then
    landing_channel_rollback_install || true
    return 1
  fi
  if [[ "$mode" == fresh ]] &&
     { ! landing_channel_persist_install_candidates "$work" ||
       ! landing_channel_update_active_journal files_active "$uid" "$gid"; }; then
    landing_channel_rollback_install || true
    return 1
  fi
  if ! landing_channel_prepare_directories "$gid" ||
     ! landing_channel_commit_candidates "$work" "$gid" ||
     ! landing_channel_account_has_no_processes "$uid" ||
     ! landing_channel_activate_remote_entry "$work" "$gid" ||
     ! landing_restricted_channel_is_valid; then
    landing_channel_rollback_install || true
    return 1
  fi
  landing_channel_commit_active_transaction || transaction_rc=$?
  if [[ "$transaction_rc" == 1 ]]; then
    landing_channel_rollback_install || true
    return 1
  fi
  [[ "$transaction_rc" == 0 ]]
}

landing_channel_has_no_managed_apply_state() {
  local logical path receipt transaction
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true && -n "${SB_LANDING_RECEIPT_FILE:-}" ]]; then
    receipt="$SB_LANDING_RECEIPT_FILE"
    [[ "$receipt" == /* && "$receipt" != *$'\n'* ]] || return 1
  else
    [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ||
       "$LANDING_RECEIPT_FILE" == /var/lib/sb-user-manager/landing-receipt.json ]] || return 1
    receipt="$(landing_channel_path /var/lib/sb-user-manager/landing-receipt.json)" || return 1
  fi
  transaction="$(landing_channel_apply_transaction_path)" || return 1
  for path in "$receipt" "$transaction"; do
    [[ ! -e "$path" && ! -L "$path" ]] || return 1
  done
  for logical in "$LANDING_TLS_DIRECTORY" "$LANDING_NFTABLES_RULES_PATH"; do
    path="$(landing_managed_path "$logical")" || return 1
    [[ ! -e "$path" && ! -L "$path" ]] || return 1
  done
  landing_startup_config_has_no_managed_residue || return 1
  landing_apply_live_nft_is_missing
}

landing_channel_ensure_persistent_lock_file() {
  local logical="$1" path parent root_uid root_gid
  path="$(landing_channel_path "$logical")" || return 1
  parent="$(dirname -- "$path")" || return 1
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  landing_channel_directory_matches "$parent" 700 "$root_uid" "$root_gid" || return 1
  if [[ -e "$path" || -L "$path" ]]; then
    landing_channel_file_matches "$path" 600 "$root_uid" "$root_gid"
    return
  fi
  (umask 077; : > "$path") || return 1
  landing_channel_apply_ownership "$path" "$root_uid" "$root_gid" || return 1
  chmod 600 "$path" || return 1
  landing_channel_file_matches "$path" 600 "$root_uid" "$root_gid" || return 1
  sync_transaction_path "$path" || return 1
  sync_transaction_path "$parent" || return 1
}

landing_channel_apply_transaction_path() {
  local fixed_path=/var/lib/sb-user-manager/landing-apply-transaction
  landing_channel_apply_transaction_setting_is_safe || return 1
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]]; then
    if [[ -n "${SB_LANDING_APPLY_TRANSACTION_DIRECTORY:-}" ]]; then
      [[ "$SB_LANDING_APPLY_TRANSACTION_DIRECTORY" == /* &&
         "$SB_LANDING_APPLY_TRANSACTION_DIRECTORY" != *$'\n'* ]] || return 1
      printf '%s\n' "$SB_LANDING_APPLY_TRANSACTION_DIRECTORY"
    else
      landing_channel_path "$fixed_path"
    fi
    return
  fi
  [[ -z "${SB_LANDING_APPLY_TRANSACTION_DIRECTORY:-}" ]] || return 1
  landing_channel_path "$fixed_path"
}

landing_channel_apply_transaction_is_absent() {
  local transaction
  transaction="$(landing_channel_apply_transaction_path)" || return 1
  [[ ! -e "$transaction" && ! -L "$transaction" ]]
}

with_landing_channel_lock() {
  local callback="$1" lock lock_dir root_uid root_gid rc
  shift
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  landing_channel_ensure_system_directory /var || return 1
  landing_channel_ensure_system_directory /var/lib || return 1
  landing_channel_ensure_owned_directory /var/lib/sb-user-manager 700 "$root_uid" "$root_gid" || return 1
  lock="$(landing_channel_path "$LANDING_CHANNEL_LOCK_PATH")" || return 1
  lock_dir="$(dirname -- "$lock")" || return 1
  landing_channel_ensure_persistent_lock_file "$LANDING_CHANNEL_LOCK_PATH" || return 1
  exec 5<>"$lock" || return 1
  flock -x -w "$LANDING_CHANNEL_LOCK_TIMEOUT" 5 || { exec 5>&-; return 1; }
  if ! landing_channel_ensure_persistent_lock_file "$LANDING_CHANNEL_INPUT_LOCK_PATH" 5>&-; then
    rc=1
  elif ! landing_channel_apply_transaction_is_absent 5>&-; then
    rc=1
  elif landing_channel_recover_pending_transaction 5>&-; then
    "$callback" "$@" 5>&- && rc=0 || rc=$?
  else
    rc=1
  fi
  if [[ -n "$LANDING_CHANNEL_ACTIVE_MODE" ]]; then
    # 失败恢复只留持久 journal/snapshot；延迟信号不得在释放锁后再次并发回滚。
    landing_channel_reset_active_transaction
  fi
  flock -u 5 2>/dev/null || true
  exec 5>&-
  sync_transaction_path "$lock_dir" || rc=1
  return "$rc"
}

with_landing_channel_shared_lock() {
  local callback="$1" lock lock_dir root_uid root_gid transaction rc
  shift
  landing_channel_runtime_paths_are_safe || return 1
  landing_channel_state_parent_chain_is_safe || return 1
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  lock="$(landing_channel_path "$LANDING_CHANNEL_LOCK_PATH")" || return 1
  lock_dir="$(dirname -- "$lock")" || return 1
  transaction="$(landing_channel_path "$LANDING_CHANNEL_TRANSACTION_DIRECTORY")" || return 1
  landing_channel_directory_matches "$lock_dir" 700 "$root_uid" "$root_gid" || return 1
  landing_channel_file_matches "$lock" 600 "$root_uid" "$root_gid" || return 1
  exec 5<>"$lock" || return 1
  flock -s -w "$LANDING_CHANNEL_LOCK_TIMEOUT" 5 || { exec 5>&-; return 1; }
  if [[ -e "$transaction" || -L "$transaction" ]]; then
    rc=1
  else
    "$callback" "$@" 5>&- && rc=0 || rc=$?
  fi
  flock -u 5 2>/dev/null || true
  exec 5>&-
  return "$rc"
}

with_landing_channel_input_lock() {
  local callback="$1" lock lock_dir root_uid root_gid rc
  shift
  landing_channel_runtime_paths_are_safe || return 1
  landing_channel_state_parent_chain_is_safe || return 1
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  lock="$(landing_channel_path "$LANDING_CHANNEL_INPUT_LOCK_PATH")" || return 1
  lock_dir="$(dirname -- "$lock")" || return 1
  landing_channel_directory_matches "$lock_dir" 700 "$root_uid" "$root_gid" || return 1
  landing_channel_file_matches "$lock" 600 "$root_uid" "$root_gid" || return 1
  exec 4<>"$lock" || return 1
  flock -n 4 || { exec 4>&-; return 1; }
  "$callback" "$@" 4>&- && rc=0 || rc=$?
  flock -u 4 2>/dev/null || true
  exec 4>&-
  return "$rc"
}

install_landing_restricted_channel() {
  [[ $# -eq 3 ]] || return 64
  local landing_id="$1" allowed_ipv4="$2" public_key_file="$3" work rc=0
  local PATH="${PATH:-}" LC_ALL="${LC_ALL:-}"
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    PATH=/usr/sbin:/usr/bin:/sbin:/bin
    LC_ALL=C
    export PATH LC_ALL
    unset BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH OPENSSL_CONF
  fi
  landing_channel_runtime_paths_are_safe || return 1
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true && "$EUID" -ne 0 ]]; then return 77; fi
  landing_channel_dependencies_are_ready || return 1
  # 在创建账户或事务前拒绝不受 root 独占的固定系统目录；写入阶段仍会逐项复核。
  landing_channel_install_system_paths_are_safe || return 1
  landing_id_is_valid "$landing_id" || return 1
  is_public_ipv4 "$allowed_ipv4" || return 1
  work="$(mktemp -d /tmp/sb-landing-channel.XXXXXX)" || return 1
  register_temp_path "$work" || { rm -rf -- "$work" || true; return 1; }
  if ! landing_channel_prepare_candidates "$landing_id" "$allowed_ipv4" "$public_key_file" "$work"; then
    rm -rf -- "$work" || true
    return 1
  fi
  with_landing_channel_lock landing_channel_install_unlocked "$landing_id" "$allowed_ipv4" "$work" || rc=$?
  rm -rf -- "$work" || rc=1
  return "$rc"
}

landing_channel_uninstall_unlocked() {
  [[ $# -eq 0 ]] || return 64
  local identity uid gid transaction_rc=0
  identity="$(landing_channel_path "$LANDING_CHANNEL_IDENTITY_PATH")" || return 1
  landing_channel_has_no_managed_apply_state || return 1
  if [[ ! -e "$identity" && ! -L "$identity" ]]; then
    landing_startup_recovery_gate_files_are_absent || return 1
    # 覆盖上一次已提交卸载在 stop 前被 SIGKILL/失败的幂等收尾。
    landing_startup_recovery_stop
    return
  fi
  landing_restricted_channel_is_valid || return 1
  uid="$(jq -r '.uid' "$identity")" || return 1
  gid="$(jq -r '.gid' "$identity")" || return 1
  landing_channel_home_layout_is_expected || return 1
  landing_channel_runtime_layout_is_expected || return 1
  landing_channel_account_has_no_processes "$uid" || return 1
  landing_channel_begin_transaction uninstall "$uid" "$gid" || return 1
  set_signal_rollback landing_channel_signal_rollback || {
    landing_channel_reset_active_transaction
    landing_channel_discard_transaction_directory || true
    return 1
  }
  if ! landing_channel_remove_file "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH" ||
     ! landing_channel_account_has_no_processes "$uid" ||
     ! landing_channel_remove_file "$LANDING_CHANNEL_SUDOERS_PATH" ||
     ! landing_channel_remove_file "$LANDING_STARTUP_RECOVERY_DROPIN_PATH" ||
     ! landing_startup_recovery_daemon_reload ||
     ! landing_channel_remove_file "$LANDING_STARTUP_RECOVERY_UNIT_PATH" ||
     ! landing_startup_recovery_daemon_reload ||
     ! landing_channel_remove_file "$LANDING_AGENT_HELPER_PATH" ||
     ! landing_channel_remove_file "$LANDING_CHANNEL_AGENT_PATH" ||
     ! landing_channel_remove_file "$LANDING_CHANNEL_RUNTIME_PATH" ||
     ! landing_channel_remove_file "$LANDING_CHANNEL_GENERATION_PATH" ||
     ! landing_channel_remove_file "$LANDING_CHANNEL_IDENTITY_PATH"; then
    landing_channel_rollback_uninstall || true
    return 1
  fi
  if ! landing_channel_remove_empty_directory "$LANDING_CHANNEL_SSH_DIRECTORY" ||
     ! landing_channel_remove_empty_directory "$LANDING_CHANNEL_HOME" ||
     ! landing_channel_remove_empty_directory "$LANDING_CHANNEL_RUNTIME_DIRECTORY"; then
    landing_channel_rollback_uninstall || true
    return 1
  fi
  landing_channel_account_has_no_processes "$uid" || {
    landing_channel_rollback_uninstall || true
    return 1
  }
  if ! landing_channel_system_userdel "$LANDING_CHANNEL_ACCOUNT"; then
    landing_channel_rollback_uninstall || true
    return 1
  fi
  landing_channel_sync_account_database || {
    landing_channel_rollback_uninstall || true
    return 1
  }
  landing_channel_account_is_absent || {
    landing_channel_rollback_uninstall || true
    return 1
  }
  if ! landing_channel_remove_expected_group_if_present "$gid"; then
    landing_channel_rollback_uninstall || true
    return 1
  fi
  landing_channel_account_is_absent || {
    landing_channel_rollback_uninstall || true
    return 1
  }
  landing_channel_group_is_absent || {
    landing_channel_rollback_uninstall || true
    return 1
  }
  landing_channel_commit_active_transaction || transaction_rc=$?
  if [[ "$transaction_rc" == 1 ]]; then
    landing_channel_rollback_uninstall || true
    return 1
  fi
  [[ "$transaction_rc" == 0 ]] || return 1
  # 文件事务已经终结，drop-in 也已从 systemd 依赖图移除；此时停止仍被加载的
  # oneshot 不会触发 sing-box，也不会让失败回滚遗漏 systemd 运行态。
  landing_startup_recovery_stop
}

# 公开接口固定为零参数，$# 检查用于拒绝未来调用方意外扩权。
# shellcheck disable=SC2120
uninstall_landing_restricted_channel() {
  [[ $# -eq 0 ]] || return 64
  local rc=0
  local PATH="${PATH:-}" LC_ALL="${LC_ALL:-}"
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    PATH=/usr/sbin:/usr/bin:/sbin:/bin
    LC_ALL=C
    export PATH LC_ALL
    unset BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH OPENSSL_CONF
  fi
  landing_channel_runtime_paths_are_safe || return 1
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true && "$EUID" -ne 0 ]]; then return 77; fi
  landing_channel_dependencies_are_ready || return 1
  with_landing_channel_lock landing_channel_uninstall_unlocked || rc=$?
  return "$rc"
}
# ============================================================
# v5 入口发起的一次性落地 root 初始化（尚未接入菜单或角色安装）
# ============================================================

LANDING_BOOTSTRAP_SCHEMA_VERSION=1
LANDING_BOOTSTRAP_RECEIPT_PATH=/var/lib/sb-user-manager/landing-bootstrap.json
LANDING_BOOTSTRAP_LOCK_PATH=/var/lib/sb-user-manager/landing-bootstrap.lock
LANDING_BOOTSTRAP_LOCK_TIMEOUT=30
LANDING_BOOTSTRAP_PACKAGE_MAX_BYTES=8388608

CONTROLLER_LANDING_BOOTSTRAP_ROOT_ACCOUNT=root
CONTROLLER_LANDING_BOOTSTRAP_SESSION_TIMEOUT=180
CONTROLLER_LANDING_BOOTSTRAP_SESSION_KILL_AFTER=5
CONTROLLER_LANDING_BOOTSTRAP_RESPONSE_MAX_BYTES=512
CONTROLLER_LANDING_BOOTSTRAP_LAST_ID=""
CONTROLLER_LANDING_BOOTSTRAP_LAST_ROLLBACK=""
CONTROLLER_LANDING_ROOT_PACKAGE_LAST_SSH_STATUS=""
if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]]; then
  CONTROLLER_LANDING_BOOTSTRAP_RUNTIME_SOURCE="${SB_CONTROLLER_LANDING_BOOTSTRAP_RUNTIME_SOURCE:-}"
  CONTROLLER_LANDING_BOOTSTRAP_ROOT_IDENTITY_FILE="${SB_CONTROLLER_LANDING_BOOTSTRAP_ROOT_IDENTITY_FILE:-}"
else
  CONTROLLER_LANDING_BOOTSTRAP_RUNTIME_SOURCE=/usr/local/sbin/sb-user-manager
  CONTROLLER_LANDING_BOOTSTRAP_ROOT_IDENTITY_FILE=""
fi

controller_landing_root_package_settings_are_safe() {
  [[ "$CONTROLLER_LANDING_BOOTSTRAP_ROOT_ACCOUNT" == root &&
     "$CONTROLLER_LANDING_BOOTSTRAP_SESSION_TIMEOUT" == 180 &&
     "$CONTROLLER_LANDING_BOOTSTRAP_SESSION_KILL_AFTER" == 5 &&
     "$CONTROLLER_LANDING_BOOTSTRAP_RESPONSE_MAX_BYTES" == 512 ]]
}

landing_bootstrap_paths_are_safe() {
  [[ "$LANDING_BOOTSTRAP_SCHEMA_VERSION" == 1 &&
     "$LANDING_BOOTSTRAP_RECEIPT_PATH" == /var/lib/sb-user-manager/landing-bootstrap.json &&
     "$LANDING_BOOTSTRAP_LOCK_PATH" == /var/lib/sb-user-manager/landing-bootstrap.lock &&
     "$LANDING_BOOTSTRAP_LOCK_TIMEOUT" == 30 &&
     "$LANDING_BOOTSTRAP_PACKAGE_MAX_BYTES" == 8388608 ]]
}

landing_bootstrap_platform_is_supported() {
  local os_release=/usr/lib/os-release uid mode key value
  local os_id="" version_id=""
  [[ "$EUID" -eq 0 && "${SB_USER_MANAGER_LIBRARY:-false}" != true ]] || return 1
  [[ "$(/usr/bin/uname -s)" == Linux && "$(/usr/bin/uname -m)" == x86_64 ]] || return 1
  [[ -f "$os_release" && ! -L "$os_release" && -r "$os_release" ]] || return 1
  uid="$(manager_file_uid "$os_release")" || return 1
  mode="$(manager_file_mode "$os_release")" || return 1
  [[ "$uid" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0022) == 0 )) || return 1
  while IFS='=' read -r key value; do
    case "$key" in
      ID)
        [[ -z "$os_id" ]] || return 1
        os_id="$value"
        ;;
      VERSION_ID)
        [[ -z "$version_id" ]] || return 1
        version_id="$value"
        ;;
    esac
  done < "$os_release"
  [[ "$os_id" == debian && "$version_id" == '"12"' ]]
}

landing_bootstrap_receipt_file() {
  landing_bootstrap_paths_are_safe || return 1
  landing_channel_path "$LANDING_BOOTSTRAP_RECEIPT_PATH"
}

landing_bootstrap_receipt_json_is_valid() {
  local path="$1"
  jq -e --argjson schema "$LANDING_BOOTSTRAP_SCHEMA_VERSION" '
    type == "object" and
    (keys | sort) == [
      "allowed_entry_ipv4", "bootstrap_id", "landing_id", "public_key_fingerprint",
      "runtime_sha256", "schema_version", "status"
    ] and
    .schema_version == $schema and
    (.bootstrap_id | type == "string" and test("^[0-9a-f]{64}$")) and
    (.landing_id | type == "string" and test("^[a-z][a-z0-9-]{0,31}$")) and
    (.allowed_entry_ipv4 | type == "string" and length >= 7 and length <= 15) and
    (.public_key_fingerprint | type == "string" and test("^SHA256:[A-Za-z0-9+/]{43}$")) and
    (.runtime_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.status == "installing" or .status == "installed")
  ' "$path" >/dev/null 2>&1 || return 1
  is_public_ipv4 "$(jq -r '.allowed_entry_ipv4' "$path")"
}

landing_bootstrap_receipt_is_trusted() {
  local path="${1:-}" root_uid root_gid
  [[ -n "$path" ]] || path="$(landing_bootstrap_receipt_file)" || return 1
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  landing_channel_file_matches "$path" 600 "$root_uid" "$root_gid" || return 1
  landing_bootstrap_receipt_json_is_valid "$path"
}

landing_bootstrap_receipt_matches() {
  local path="$1" bootstrap_id="$2" landing_id="$3" allowed_ipv4="$4"
  local public_key_fingerprint="$5"
  landing_bootstrap_receipt_is_trusted "$path" || return 1
  jq -e --arg bootstrap_id "$bootstrap_id" --arg landing_id "$landing_id" \
    --arg allowed_ipv4 "$allowed_ipv4" --arg fingerprint "$public_key_fingerprint" '
      .bootstrap_id == $bootstrap_id and .landing_id == $landing_id and
      .allowed_entry_ipv4 == $allowed_ipv4 and
      .public_key_fingerprint == $fingerprint
    ' "$path" >/dev/null 2>&1
}

landing_bootstrap_write_receipt() {
  local bootstrap_id="$1" landing_id="$2" allowed_ipv4="$3"
  local public_key_fingerprint="$4" runtime_sha256="$5" status="$6"
  local receipt parent tmp root_uid root_gid
  [[ "$bootstrap_id" =~ ^[0-9a-f]{64}$ &&
     "$runtime_sha256" =~ ^[0-9a-f]{64}$ &&
     "$public_key_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || return 1
  landing_id_is_valid "$landing_id" || return 1
  is_public_ipv4 "$allowed_ipv4" || return 1
  [[ "$status" == installing || "$status" == installed ]] || return 1
  receipt="$(landing_bootstrap_receipt_file)" || return 1
  parent="$(dirname -- "$receipt")" || return 1
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  landing_channel_directory_matches "$parent" 700 "$root_uid" "$root_gid" || return 1
  if [[ -e "$receipt" || -L "$receipt" ]]; then
    landing_bootstrap_receipt_is_trusted "$receipt" || return 1
  fi
  tmp="$(mktemp "$parent/.landing-bootstrap.XXXXXX")" || return 1
  register_temp_path "$tmp" || { rm -f -- "$tmp" || true; return 1; }
  if ! jq -n --argjson schema "$LANDING_BOOTSTRAP_SCHEMA_VERSION" \
      --arg bootstrap_id "$bootstrap_id" --arg landing_id "$landing_id" \
      --arg allowed_ipv4 "$allowed_ipv4" --arg fingerprint "$public_key_fingerprint" \
      --arg runtime_sha256 "$runtime_sha256" --arg status "$status" '
        {
          schema_version:$schema,
          bootstrap_id:$bootstrap_id,
          landing_id:$landing_id,
          allowed_entry_ipv4:$allowed_ipv4,
          public_key_fingerprint:$fingerprint,
          runtime_sha256:$runtime_sha256,
          status:$status
        }
      ' > "$tmp" ||
     ! chmod 600 "$tmp" ||
     ! landing_channel_apply_ownership "$tmp" "$root_uid" "$root_gid" ||
     ! landing_bootstrap_receipt_json_is_valid "$tmp" ||
     ! sync_transaction_path "$tmp" ||
     ! mv -- "$tmp" "$receipt" ||
     ! sync_transaction_path "$parent"; then
    rm -f -- "$tmp" || true
    return 1
  fi
  landing_bootstrap_receipt_is_trusted "$receipt"
}

landing_bootstrap_remove_receipt() {
  local bootstrap_id="$1" landing_id="$2" allowed_ipv4="$3"
  local public_key_fingerprint="$4" receipt parent
  receipt="$(landing_bootstrap_receipt_file)" || return 1
  [[ -e "$receipt" || -L "$receipt" ]] || return 0
  landing_bootstrap_receipt_matches "$receipt" "$bootstrap_id" "$landing_id" \
    "$allowed_ipv4" "$public_key_fingerprint" || return 1
  parent="$(dirname -- "$receipt")" || return 1
  rm -f -- "$receipt" || return 1
  sync_transaction_path "$parent" || return 1
  [[ ! -e "$receipt" && ! -L "$receipt" ]]
}

landing_bootstrap_with_lock() {
  local callback="$1" lock lock_parent root_uid root_gid rc
  shift
  landing_bootstrap_paths_are_safe || return 1
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  landing_channel_ensure_system_directory /var || return 1
  landing_channel_ensure_system_directory /var/lib || return 1
  landing_channel_ensure_owned_directory /var/lib/sb-user-manager 700 "$root_uid" "$root_gid" || return 1
  landing_channel_ensure_persistent_lock_file "$LANDING_BOOTSTRAP_LOCK_PATH" || return 1
  lock="$(landing_channel_path "$LANDING_BOOTSTRAP_LOCK_PATH")" || return 1
  lock_parent="$(dirname -- "$lock")" || return 1
  exec 3<>"$lock" || return 1
  flock -x -w "$LANDING_BOOTSTRAP_LOCK_TIMEOUT" 3 || { exec 3>&-; return 1; }
  "$callback" "$@" 3>&- && rc=0 || rc=$?
  flock -u 3 2>/dev/null || true
  exec 3>&-
  sync_transaction_path "$lock_parent" || rc=1
  return "$rc"
}

landing_bootstrap_emit_status() {
  local status="$1"
  [[ "$status" == installed || "$status" == rolled_back ||
     "$status" == already_rolled_back ]] || return 1
  jq -nc --arg status "$status" '{status:$status}'
}

landing_bootstrap_install_unlocked() {
  local bootstrap_id="$1" landing_id="$2" allowed_ipv4="$3" public_key_file="$4"
  local public_key_fingerprint="$5" runtime_sha256="$6" receipt identity status
  receipt="$(landing_bootstrap_receipt_file)" || return 1
  identity="$(landing_channel_path "$LANDING_CHANNEL_IDENTITY_PATH")" || return 1
  if [[ -e "$receipt" || -L "$receipt" ]]; then
    landing_bootstrap_receipt_matches "$receipt" "$bootstrap_id" "$landing_id" \
      "$allowed_ipv4" "$public_key_fingerprint" || return 1
    [[ "$(jq -r '.runtime_sha256' "$receipt")" == "$runtime_sha256" ]] || return 1
  else
    [[ ! -e "$identity" && ! -L "$identity" ]] || return 1
    landing_channel_fresh_preflight || return 1
    landing_bootstrap_write_receipt "$bootstrap_id" "$landing_id" "$allowed_ipv4" \
      "$public_key_fingerprint" "$runtime_sha256" installing || return 1
  fi

  if ! install_landing_restricted_channel "$landing_id" "$allowed_ipv4" "$public_key_file"; then
    if [[ ! -e "$identity" && ! -L "$identity" ]] && landing_channel_fresh_preflight; then
      landing_bootstrap_remove_receipt "$bootstrap_id" "$landing_id" "$allowed_ipv4" \
        "$public_key_fingerprint" || true
    fi
    return 1
  fi
  landing_restricted_channel_is_valid || return 1
  status="$(jq -r '.status' "$receipt")" || return 1
  if [[ "$status" != installed ]]; then
    landing_bootstrap_write_receipt "$bootstrap_id" "$landing_id" "$allowed_ipv4" \
      "$public_key_fingerprint" "$runtime_sha256" installed || return 1
  fi
  landing_bootstrap_emit_status installed
}

landing_bootstrap_rollback_unlocked() {
  local bootstrap_id="$1" landing_id="$2" allowed_ipv4="$3" public_key_fingerprint="$4"
  local receipt identity
  receipt="$(landing_bootstrap_receipt_file)" || return 1
  identity="$(landing_channel_path "$LANDING_CHANNEL_IDENTITY_PATH")" || return 1
  if [[ ! -e "$receipt" && ! -L "$receipt" ]]; then
    [[ ! -e "$identity" && ! -L "$identity" ]] || return 1
    landing_bootstrap_emit_status already_rolled_back
    return
  fi
  landing_bootstrap_receipt_matches "$receipt" "$bootstrap_id" "$landing_id" \
    "$allowed_ipv4" "$public_key_fingerprint" || return 1
  # 固定零参数受管卸载；不能把 bootstrap 包参数透传给 root 卸载层。
  # shellcheck disable=SC2119
  uninstall_landing_restricted_channel || return 1
  [[ ! -e "$identity" && ! -L "$identity" ]] || return 1
  landing_bootstrap_remove_receipt "$bootstrap_id" "$landing_id" "$allowed_ipv4" \
    "$public_key_fingerprint" || return 1
  landing_bootstrap_emit_status rolled_back
}

landing_bootstrap_execute() {
  [[ $# -eq 6 ]] || return 64
  local action="$1" bootstrap_id="$2" landing_id="$3" allowed_ipv4="$4"
  local public_key_file="$5" runtime_sha256="$6" public_key_fingerprint
  local runtime_source
  [[ "$action" == install || "$action" == rollback ]] || return 64
  [[ "$bootstrap_id" =~ ^[0-9a-f]{64}$ && "$runtime_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
  landing_id_is_valid "$landing_id" || return 1
  is_public_ipv4 "$allowed_ipv4" || return 1
  [[ "$EUID" -eq 0 && "${SB_USER_MANAGER_LIBRARY:-false}" != true ]] || return 77
  landing_channel_runtime_paths_are_safe || return 1
  landing_channel_dependencies_are_ready || return 1
  landing_bootstrap_platform_is_supported || return 1
  landing_channel_install_system_paths_are_safe || return 1
  LANDING_CHANNEL_BOOTSTRAP_RUNTIME_SHA256="$runtime_sha256"
  runtime_source="$(landing_channel_runtime_source)" || return 1
  [[ "$runtime_source" == "/proc/self/fd/$LANDING_CHANNEL_BOOTSTRAP_RUNTIME_FD" ]] || return 1
  landing_channel_normalize_public_key "$public_key_file" "${public_key_file}.normalized" || return 1
  public_key_fingerprint="$(landing_channel_public_key_fingerprint \
    "${public_key_file}.normalized")" || return 1
  rm -f -- "$public_key_file" || return 1
  mv -- "${public_key_file}.normalized" "$public_key_file" || return 1
  case "$action" in
    install)
      landing_bootstrap_with_lock landing_bootstrap_install_unlocked "$bootstrap_id" \
        "$landing_id" "$allowed_ipv4" "$public_key_file" "$public_key_fingerprint" \
        "$runtime_sha256"
      ;;
    rollback)
      landing_bootstrap_with_lock landing_bootstrap_rollback_unlocked "$bootstrap_id" \
        "$landing_id" "$allowed_ipv4" "$public_key_fingerprint"
      ;;
  esac
}

controller_landing_bootstrap_runtime_source_is_trusted() {
  local source="$1" expected_uid uid mode
  [[ "$source" == /* && -f "$source" && ! -L "$source" && -r "$source" ]] || return 1
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]]; then
    expected_uid="$(controller_state_expected_uid)"
  else
    [[ "$source" == /usr/local/sbin/sb-user-manager ]] || return 1
    expected_uid=0
  fi
  uid="$(manager_file_uid "$source")" || return 1
  [[ "$uid" == "$expected_uid" ]] || return 1
  mode="$(manager_file_mode "$source")" || return 1
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0077) == 0 )) || return 1
  bash -n "$source" >/dev/null 2>&1
}

controller_landing_build_bootstrap_package() {
  [[ $# -eq 6 ]] || return 64
  local action="$1" bootstrap_id="$2" landing_id="$3" allowed_ipv4="$4"
  local public_key_file="$5" output="$6" runtime runtime_sha public_key_b64 size
  local output_parent normalized
  [[ "$action" == install || "$action" == rollback ]] || return 1
  [[ "$bootstrap_id" =~ ^[0-9a-f]{64}$ ]] || return 1
  landing_id_is_valid "$landing_id" || return 1
  is_public_ipv4 "$allowed_ipv4" || return 1
  output_parent="$(dirname -- "$output")" || return 1
  controller_private_directory_is_trusted "$output_parent" || return 1
  [[ ! -e "$output" && ! -L "$output" ]] || return 1
  runtime="$CONTROLLER_LANDING_BOOTSTRAP_RUNTIME_SOURCE"
  controller_landing_bootstrap_runtime_source_is_trusted "$runtime" || return 1
  runtime_sha="$(sha256sum "$runtime" | awk '{print $1}')" || return 1
  [[ "$runtime_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
  normalized="$output_parent/.landing-bootstrap.public-key"
  [[ ! -e "$normalized" && ! -L "$normalized" ]] || return 1
  landing_channel_normalize_public_key "$public_key_file" "$normalized" || return 1
  public_key_b64="$(base64 < "$normalized" | tr -d '\n')" || { rm -f -- "$normalized"; return 1; }
  rm -f -- "$normalized" || return 1
  [[ "$public_key_b64" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || return 1

  if ! {
    cat <<EOF
#!/bin/bash
set -Eeuo pipefail
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
LC_ALL=C
export PATH LC_ALL
unset BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH OPENSSL_CONF
bootstrap_action=$action
bootstrap_id=$bootstrap_id
landing_id=$landing_id
allowed_entry_ipv4=$allowed_ipv4
runtime_sha256=$runtime_sha
public_key_base64=$public_key_b64
work="\$(/usr/bin/mktemp -d /tmp/sb-landing-bootstrap-runtime.XXXXXXXXXX)" || exit 70
[[ "\$work" =~ ^/tmp/sb-landing-bootstrap-runtime\.[A-Za-z0-9]{10}\$ &&
   -d "\$work" && ! -L "\$work" ]] || exit 70
cleanup_bootstrap_work() {
  [[ "\${work:-}" =~ ^/tmp/sb-landing-bootstrap-runtime\.[A-Za-z0-9]{10}\$ &&
     -d "\$work" && ! -L "\$work" ]] || return 1
  /bin/rm -rf -- "\$work"
}
trap 'cleanup_bootstrap_work || true' EXIT HUP INT QUIT TERM
runtime="\$work/runtime.sh"
public_key="\$work/public-key"
/usr/bin/awk 'found { print } \$0 == "__SB_USER_MANAGER_RUNTIME__" { found=1; next }' "\$0" |
  /usr/bin/base64 -d > "\$runtime" || exit 70
printf '%s' "\$public_key_base64" | /usr/bin/base64 -d > "\$public_key" || exit 70
/bin/chmod 600 "\$runtime" "\$public_key" || exit 70
actual_sha="\$(/usr/bin/sha256sum "\$runtime" | /usr/bin/awk '{print \$1}')" || exit 70
[[ "\$actual_sha" == "\$runtime_sha256" ]] || exit 70
/bin/bash -n "\$runtime" >/dev/null 2>&1 || exit 70
exec 8< "\$runtime" || exit 70
exec 9< "\$runtime" || exit 70
runtime_fd8="\$(/usr/bin/stat -Lc '%d:%i' /proc/self/fd/8)" || exit 70
runtime_fd9="\$(/usr/bin/stat -Lc '%d:%i' /proc/self/fd/9)" || exit 70
[[ "\$runtime_fd8" == "\$runtime_fd9" ]] || exit 70
SB_USER_MANAGER_LIBRARY=true
. /proc/self/fd/9 || exit 70
SB_USER_MANAGER_LIBRARY=false
export SB_USER_MANAGER_LIBRARY
/bin/rm -f -- "\$runtime" || exit 70
LANDING_CHANNEL_BOOTSTRAP_RUNTIME_FD=8
LANDING_CHANNEL_BOOTSTRAP_RUNTIME_SHA256="\$runtime_sha256"
register_temp_path "\$work"
install_landing_apply_runtime_traps
landing_bootstrap_execute "\$bootstrap_action" "\$bootstrap_id" "\$landing_id" \
  "\$allowed_entry_ipv4" "\$public_key" "\$runtime_sha256"
exit \$?
__SB_USER_MANAGER_RUNTIME__
EOF
    base64 < "$runtime"
  } > "$output"; then
    rm -f -- "$output"
    return 1
  fi
  chmod 600 "$output" || { rm -f -- "$output"; return 1; }
  controller_landing_private_file_is_trusted "$output" || { rm -f -- "$output"; return 1; }
  size="$(controller_landing_file_size "$output")" || { rm -f -- "$output"; return 1; }
  ((size >= 1 && size <= LANDING_BOOTSTRAP_PACKAGE_MAX_BYTES)) || {
    rm -f -- "$output"
    return 1
  }
}

controller_landing_bootstrap_response_is_valid() {
  local response="$1" size
  controller_landing_private_file_is_trusted "$response" || return 1
  size="$(controller_landing_file_size "$response")" || return 1
  ((size >= 1 && size <= CONTROLLER_LANDING_BOOTSTRAP_RESPONSE_MAX_BYTES)) || return 1
  jq -e -s '
    length == 1 and .[0] == {status:.[0].status} and
    (.[0].status == "installed" or .[0].status == "rolled_back" or
     .[0].status == "already_rolled_back")
  ' "$response" >/dev/null 2>&1
}

controller_landing_root_package_remote_command() {
  local expected_sha="$1"
  [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
  cat <<EOF
expected=$expected_sha; umask 077; work=\$(/usr/bin/mktemp -d /tmp/sb-landing-root.XXXXXXXXXX) || exit 70; case \$work in /tmp/sb-landing-root.[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]) ;; *) exit 70 ;; esac; trap '/bin/rm -rf -- "\$work"' EXIT HUP INT QUIT TERM; /bin/cat > "\$work/package" || exit 70; /bin/chmod 600 "\$work/package" || exit 70; actual=\$(/usr/bin/sha256sum "\$work/package") || exit 70; actual=\${actual%% *}; [ "\$actual" = "\$expected" ] || exit 70; /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C /bin/bash --noprofile --norc "\$work/package"
EOF
}

controller_landing_bootstrap_remote_command() {
  controller_landing_root_package_remote_command "$@"
}

controller_landing_root_package_exchange() {
  [[ $# -eq 8 ]] || return 64
  local address="$1" ssh_port="$2" landing_id="$3" known_hosts="$4"
  local expected_fingerprint="$5" package="$6" response="$7"
  local session_timeout="$8"
  local host_alias package_sha remote_command ssh_status=0 identity_args=()
  CONTROLLER_LANDING_ROOT_PACKAGE_LAST_SSH_STATUS=""
  controller_landing_root_package_settings_are_safe || return 1
  controller_landing_transport_runtime_is_safe || return 1
  controller_landing_address_is_valid "$address" || return 1
  landing_port_is_valid "$ssh_port" || return 1
  landing_id_is_valid "$landing_id" || return 1
  [[ "$session_timeout" =~ ^[0-9]+$ ]] || return 1
  ((10#$session_timeout >= 30 && 10#$session_timeout <= 900)) || return 1
  host_alias="sb-landing-$landing_id"
  controller_landing_known_hosts_is_valid "$known_hosts" "$host_alias" \
    "$expected_fingerprint" || return 1
  controller_landing_private_file_is_trusted "$package" || return 1
  [[ ! -e "$response" && ! -L "$response" ]] || return 1
  package_sha="$(sha256sum "$package" | awk '{print $1}')" || return 1
  [[ "$package_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
  remote_command="$(controller_landing_root_package_remote_command "$package_sha")" || return 1
  [[ -n "$remote_command" && "$remote_command" != *$'\n'* ]] || return 1
  if [[ -n "$CONTROLLER_LANDING_BOOTSTRAP_ROOT_IDENTITY_FILE" ]]; then
    [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]] || return 1
    controller_landing_ssh_private_key_is_valid \
      "$CONTROLLER_LANDING_BOOTSTRAP_ROOT_IDENTITY_FILE" || return 1
    identity_args=(-i "$CONTROLLER_LANDING_BOOTSTRAP_ROOT_IDENTITY_FILE")
  fi
  if (
    umask 077
    ulimit -f 4 || exit 70
    exec "$CONTROLLER_LANDING_TIMEOUT_BIN" -k "$CONTROLLER_LANDING_BOOTSTRAP_SESSION_KILL_AFTER" \
      "$session_timeout" \
      "$CONTROLLER_LANDING_SSH_BIN" -F /dev/null -T -p "$ssh_port" \
      "${identity_args[@]}" \
      -o BatchMode=no \
      -o CanonicalizeHostname=no \
      -o CheckHostIP=no \
      -o ClearAllForwardings=yes \
      -o ConnectionAttempts=1 \
      -o "ConnectTimeout=$CONTROLLER_LANDING_CONNECT_TIMEOUT" \
      -o ControlMaster=no \
      -o ExitOnForwardFailure=yes \
      -o EscapeChar=none \
      -o ForwardAgent=no \
      -o ForwardX11=no \
      -o GlobalKnownHostsFile=/dev/null \
      -o "HostKeyAlias=$host_alias" \
      -o HostKeyAlgorithms=ssh-ed25519 \
      -o IdentitiesOnly=yes \
      -o KbdInteractiveAuthentication=yes \
      -o LogLevel=ERROR \
      -o NumberOfPasswordPrompts=3 \
      -o PasswordAuthentication=yes \
      -o PermitLocalCommand=no \
      -o PreferredAuthentications=publickey,keyboard-interactive,password \
      -o ProxyCommand=none \
      -o ProxyJump=none \
      -o PubkeyAcceptedAlgorithms=ssh-ed25519 \
      -o RequestTTY=no \
      -o StrictHostKeyChecking=yes \
      -o Tunnel=no \
      -o UpdateHostKeys=no \
      -o "UserKnownHostsFile=$known_hosts" \
      -o "User=$CONTROLLER_LANDING_BOOTSTRAP_ROOT_ACCOUNT" \
      -o VerifyHostKeyDNS=no \
      "$address" "$remote_command"
  ) < "$package" > "$response"; then
    ssh_status=0
  else
    ssh_status=$?
  fi
  CONTROLLER_LANDING_ROOT_PACKAGE_LAST_SSH_STATUS="$ssh_status"
  chmod 600 "$response" 2>/dev/null || return 1
  ((ssh_status == 0))
}

controller_landing_root_bootstrap_exchange() {
  [[ $# -eq 7 ]] || return 64
  local response="$7"
  controller_landing_root_package_exchange "$@" \
    "$CONTROLLER_LANDING_BOOTSTRAP_SESSION_TIMEOUT" || return 1
  controller_landing_bootstrap_response_is_valid "$response"
}

controller_landing_bootstrap_public_key() {
  local landing_id="$1" output="$2" manifest private_key
  manifest="$(controller_landing_registration_manifest "$landing_id")" || return 1
  private_key="$(jq -r '.ssh_private_key_file' "$manifest")" || return 1
  controller_landing_ssh_private_key_is_valid "$private_key" || return 1
  [[ ! -e "$output" && ! -L "$output" ]] || return 1
  "$CONTROLLER_LANDING_SSH_KEYGEN_BIN" -y -P '' -f "$private_key" > "$output" 2>/dev/null || return 1
  chmod 600 "$output" || return 1
  landing_channel_normalize_public_key "$output" "${output}.normalized" || return 1
  mv -- "${output}.normalized" "$output" || return 1
  controller_landing_private_file_is_trusted "$output"
}

controller_landing_send_bootstrap_action_in_work() {
  local action="$1" bootstrap_id="$2" landing_id="$3" address="$4" ssh_port="$5"
  local expected_fingerprint="$6" allowed_ipv4="$7" public_key="$8" work="$9"
  local package="$work/bootstrap-${action}.sh" response="$work/bootstrap-${action}.json"
  local known_hosts status
  controller_landing_build_bootstrap_package "$action" "$bootstrap_id" "$landing_id" \
    "$allowed_ipv4" "$public_key" "$package" || return 1
  known_hosts="$(controller_landing_prepare_known_hosts "$address" "$ssh_port" \
    "$expected_fingerprint" "sb-landing-$landing_id" "$work")" || return 1
  controller_landing_root_bootstrap_exchange "$address" "$ssh_port" "$landing_id" \
    "$known_hosts" "$expected_fingerprint" "$package" "$response" || return 1
  status="$(jq -r '.status' "$response")" || return 1
  case "$action:$status" in
    install:installed|rollback:rolled_back|rollback:already_rolled_back) return 0 ;;
    *) return 1 ;;
  esac
}

controller_landing_remove_bootstrap_action_files() {
  local work="$1" action="$2"
  rm -f -- "$work/bootstrap-${action}.sh" "$work/bootstrap-${action}.json" \
    "$work/host-key.scan" "$work/host-key.pub" "$work/known-hosts" || return 1
}

controller_bootstrap_landing_channel_in_work() {
  local landing_id="$1" address="$2" ssh_port="$3" expected_fingerprint="$4"
  local allowed_ipv4="$5" bootstrap_id="$6" work="$7"
  local public_key="$work/public-key"
  local install_confirmed=false rollback_ok=false
  controller_landing_bootstrap_public_key "$landing_id" "$public_key" || return 1
  if controller_landing_send_bootstrap_action_in_work install "$bootstrap_id" "$landing_id" \
      "$address" "$ssh_port" "$expected_fingerprint" "$allowed_ipv4" "$public_key" "$work"; then
    install_confirmed=true
  fi
  controller_landing_remove_bootstrap_action_files "$work" install || return 1
  if [[ "$install_confirmed" == true ]] &&
     controller_test_landing_registration_channel "$landing_id" "$address" "$ssh_port" \
       "$expected_fingerprint"; then
    CONTROLLER_LANDING_BOOTSTRAP_LAST_ROLLBACK=not_needed
    return 0
  fi
  if controller_landing_send_bootstrap_action_in_work rollback "$bootstrap_id" "$landing_id" \
      "$address" "$ssh_port" "$expected_fingerprint" "$allowed_ipv4" "$public_key" "$work"; then
    rollback_ok=true
  fi
  controller_landing_remove_bootstrap_action_files "$work" rollback || rollback_ok=false
  if [[ "$rollback_ok" == true ]]; then
    CONTROLLER_LANDING_BOOTSTRAP_LAST_ROLLBACK=completed
  else
    CONTROLLER_LANDING_BOOTSTRAP_LAST_ROLLBACK=failed
  fi
  return 1
}

controller_bootstrap_landing_channel() {
  [[ $# -eq 5 || $# -eq 6 ]] || return 64
  local landing_id="$1" address="$2" ssh_port="$3" expected_fingerprint="$4"
  local allowed_ipv4="$5" requested_bootstrap_id="${6:-}" bootstrap_id work rc=1
  controller_landing_transport_runtime_is_safe || return 1
  landing_id_is_valid "$landing_id" || return 1
  controller_landing_address_is_valid "$address" || return 1
  landing_port_is_valid "$ssh_port" || return 1
  [[ "$expected_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || return 1
  is_public_ipv4 "$allowed_ipv4" || return 1
  controller_landing_registration_manifest "$landing_id" >/dev/null || return 1
  if [[ -n "$requested_bootstrap_id" ]]; then
    bootstrap_id="$requested_bootstrap_id"
  else
    bootstrap_id="$(openssl rand -hex 32 2>/dev/null)" || return 1
  fi
  [[ "$bootstrap_id" =~ ^[0-9a-f]{64}$ ]] || return 1
  # 后续交互层与恢复入口在 source 后读取这两个结果；dormant 单脚本尚无菜单读者。
  # shellcheck disable=SC2034
  CONTROLLER_LANDING_BOOTSTRAP_LAST_ID="$bootstrap_id"
  # shellcheck disable=SC2034
  CONTROLLER_LANDING_BOOTSTRAP_LAST_ROLLBACK=not_started
  work="$(controller_landing_create_work_directory)" || return 1
  register_temp_path "$work" || {
    controller_landing_remove_work_directory "$work" || true
    return 1
  }
  if controller_bootstrap_landing_channel_in_work "$landing_id" "$address" "$ssh_port" \
      "$expected_fingerprint" "$allowed_ipv4" "$bootstrap_id" "$work"; then
    rc=0
  fi
  controller_landing_remove_work_directory "$work" || rc=1
  return "$rc"
}

controller_rollback_landing_bootstrap() {
  [[ $# -eq 6 ]] || return 64
  local landing_id="$1" address="$2" ssh_port="$3" expected_fingerprint="$4"
  local allowed_ipv4="$5" bootstrap_id="$6" work public_key rc=1
  controller_landing_transport_runtime_is_safe || return 1
  landing_id_is_valid "$landing_id" || return 1
  controller_landing_address_is_valid "$address" || return 1
  landing_port_is_valid "$ssh_port" || return 1
  [[ "$expected_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ &&
     "$bootstrap_id" =~ ^[0-9a-f]{64}$ ]] || return 1
  is_public_ipv4 "$allowed_ipv4" || return 1
  work="$(controller_landing_create_work_directory)" || return 1
  register_temp_path "$work" || {
    controller_landing_remove_work_directory "$work" || true
    return 1
  }
  public_key="$work/public-key"
  if controller_landing_bootstrap_public_key "$landing_id" "$public_key" &&
     controller_landing_send_bootstrap_action_in_work rollback "$bootstrap_id" "$landing_id" \
       "$address" "$ssh_port" "$expected_fingerprint" "$allowed_ipv4" "$public_key" "$work"; then
    rc=0
  fi
  controller_landing_remove_work_directory "$work" || rc=1
  return "$rc"
}
# ============================================================
# v5 入口发起的落地依赖准备（尚未接入菜单或角色安装）
# ============================================================
# 只产生稳定结果；不会创建入口状态、落地身份或项目运行文件。
# shellcheck disable=SC2034

CONTROLLER_LANDING_DEPENDENCY_SESSION_TIMEOUT=600
CONTROLLER_LANDING_DEPENDENCY_RESPONSE_MAX_BYTES=512
CONTROLLER_LANDING_DEPENDENCY_PACKAGE_MAX_BYTES=65536
CONTROLLER_LANDING_DEPENDENCY_LAST_STATUS=not_checked
CONTROLLER_LANDING_DEPENDENCY_LAST_DETAIL=""
CONTROLLER_LANDING_DEPENDENCY_LAST_FINGERPRINT=""

controller_landing_dependency_reset_result() {
  CONTROLLER_LANDING_DEPENDENCY_LAST_STATUS=not_checked
  CONTROLLER_LANDING_DEPENDENCY_LAST_DETAIL=""
  CONTROLLER_LANDING_DEPENDENCY_LAST_FINGERPRINT=""
}

controller_landing_dependency_set_result() {
  # shellcheck disable=SC2034
  CONTROLLER_LANDING_DEPENDENCY_LAST_STATUS="$1"
  # shellcheck disable=SC2034
  CONTROLLER_LANDING_DEPENDENCY_LAST_DETAIL="${2:-}"
}

controller_landing_dependency_settings_are_safe() {
  [[ "$CONTROLLER_LANDING_DEPENDENCY_SESSION_TIMEOUT" == 600 &&
     "$CONTROLLER_LANDING_DEPENDENCY_RESPONSE_MAX_BYTES" == 512 &&
     "$CONTROLLER_LANDING_DEPENDENCY_PACKAGE_MAX_BYTES" == 65536 ]]
}

controller_landing_build_dependency_package() {
  [[ $# -eq 1 ]] || return 64
  local output="$1" output_parent test_root="" test_system="" test_machine="" size
  controller_landing_dependency_settings_are_safe || return 1
  output_parent="$(dirname -- "$output")" || return 1
  controller_private_directory_is_trusted "$output_parent" || return 1
  [[ ! -e "$output" && ! -L "$output" ]] || return 1
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true &&
        -n "${SB_LANDING_DEPENDENCY_PREP_TEST_ROOT:-}" ]]; then
    test_root="$SB_LANDING_DEPENDENCY_PREP_TEST_ROOT"
    test_system="${SB_LANDING_DEPENDENCY_PREP_TEST_SYSTEM:-Linux}"
    test_machine="${SB_LANDING_DEPENDENCY_PREP_TEST_MACHINE:-x86_64}"
    [[ "$test_root" == /* && "$test_root" != / && "$test_root" != */ &&
       "$test_root" != *$'\n'* && "$test_system" =~ ^[A-Za-z0-9._-]+$ &&
       "$test_machine" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    controller_private_directory_is_trusted "$test_root" || return 1
  fi
  if ! {
    printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail' 'umask 077'
    printf 'test_root=%q\n' "$test_root"
    printf 'test_system=%q\n' "$test_system"
    printf 'test_machine=%q\n' "$test_machine"
    cat <<'EOF'

dependency_path() {
  local logical="$1"
  if [[ -n "$test_root" ]]; then
    printf '%s/dependencies/%s\n' "$test_root" "${logical##*/}"
  else
    printf '%s\n' "$logical"
  fi
}

os_release_path() {
  if [[ -n "$test_root" ]]; then
    printf '%s/os-release\n' "$test_root"
  else
    printf '/usr/lib/os-release\n'
  fi
}

apt_get_path() {
  if [[ -n "$test_root" ]]; then
    printf '%s/bin/apt-get\n' "$test_root"
  else
    printf '/usr/bin/apt-get\n'
  fi
}

env_path() {
  if [[ -n "$test_root" ]]; then
    printf '%s/bin/env\n' "$test_root"
  else
    printf '/usr/bin/env\n'
  fi
}

required_dependency_paths() {
  printf '%s\n' \
    /bin/bash /bin/sh /usr/bin/awk /usr/bin/base64 /usr/bin/cat \
    /usr/bin/chmod /usr/bin/chown /usr/bin/cmp /usr/bin/date /usr/bin/dirname \
    /usr/bin/flock /usr/bin/getent /usr/bin/grep /usr/bin/head /usr/bin/id \
    /usr/bin/install /usr/bin/jq /usr/bin/ln /usr/bin/mktemp /usr/bin/mv /usr/sbin/nft \
    /usr/bin/openssl /usr/bin/ps /usr/bin/python3 /usr/bin/readlink /usr/bin/rm \
    /usr/bin/rmdir /usr/bin/sha256sum /usr/bin/sort /usr/bin/ss /usr/bin/stat \
    /usr/bin/sudo /usr/bin/sync /usr/bin/systemctl /usr/bin/timeout /usr/bin/tr \
    /usr/bin/uname /usr/bin/wc /usr/bin/ssh-keygen /usr/sbin/groupadd \
    /usr/sbin/groupdel /usr/sbin/useradd /usr/sbin/userdel /usr/sbin/visudo
}

fixed_packages() {
  printf '%s\n' \
    bash coreutils gawk grep iproute2 jq nftables openssh-client openssl passwd \
    procps python3 sudo systemd util-linux
}

expected_uid() {
  if [[ -n "$test_root" ]]; then
    printf '%s\n' "$EUID"
  else
    printf '0\n'
  fi
}

executable_is_safe() {
  local logical="$1" path resolved metadata uid mode
  path="$(dependency_path "$logical")" || return 1
  [[ -f "$path" && -x "$path" ]] || return 1
  if [[ -n "$test_root" ]]; then
    [[ ! -L "$path" ]] || return 1
    resolved="$path"
  else
    resolved="$(/usr/bin/readlink -f -- "$path")" || return 1
  fi
  [[ "$resolved" == /* && -f "$resolved" && ! -L "$resolved" && -x "$resolved" ]] ||
    return 1
  metadata="$(/usr/bin/stat -Lc '%u %a' -- "$resolved" 2>/dev/null ||
    /usr/bin/stat -f '%u %Lp' "$resolved" 2>/dev/null)" || return 1
  read -r uid mode <<< "$metadata"
  [[ "$uid" == "$(expected_uid)" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0022) == 0 ))
}

dependency_state() {
  local logical="$1" path
  path="$(dependency_path "$logical")" || return 1
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    printf 'missing\n'
  elif executable_is_safe "$logical"; then
    printf 'ready\n'
  else
    printf 'unsafe\n'
  fi
}

platform_is_supported() {
  local os_release uid mode metadata key value os_id="" version_id=""
  local system machine
  if [[ -n "$test_root" ]]; then
    system="$test_system"
    machine="$test_machine"
  else
    [[ "$EUID" -eq 0 ]] || return 1
    system="$(/usr/bin/uname -s)" || return 1
    machine="$(/usr/bin/uname -m)" || return 1
  fi
  [[ "$system" == Linux && "$machine" == x86_64 ]] || return 1
  os_release="$(os_release_path)" || return 1
  [[ -f "$os_release" && ! -L "$os_release" && -r "$os_release" ]] || return 1
  metadata="$(/usr/bin/stat -Lc '%u %a' -- "$os_release" 2>/dev/null ||
    /usr/bin/stat -f '%u %Lp' "$os_release" 2>/dev/null)" || return 1
  read -r uid mode <<< "$metadata"
  [[ "$uid" == "$(expected_uid)" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0022) == 0 )) || return 1
  while IFS='=' read -r key value; do
    case "$key" in
      ID) [[ -z "$os_id" ]] || return 1; os_id="$value" ;;
      VERSION_ID) [[ -z "$version_id" ]] || return 1; version_id="$value" ;;
    esac
  done < "$os_release"
  [[ "$os_id" == debian && "$version_id" == '"12"' ]]
}

runtime_executable_is_safe() {
  local path="$1" expected="$2" resolved metadata uid mode
  [[ "$path" == "$expected" || -n "$test_root" ]] || return 1
  [[ -f "$path" && -x "$path" ]] || return 1
  if [[ -n "$test_root" ]]; then
    [[ ! -L "$path" ]] || return 1
    resolved="$path"
  else
    resolved="$(/usr/bin/readlink -f -- "$path")" || return 1
  fi
  [[ "$resolved" == /* && -f "$resolved" && ! -L "$resolved" && -x "$resolved" ]] ||
    return 1
  metadata="$(/usr/bin/stat -Lc '%u %a' -- "$resolved" 2>/dev/null ||
    /usr/bin/stat -f '%u %Lp' "$resolved" 2>/dev/null)" || return 1
  read -r uid mode <<< "$metadata"
  [[ "$uid" == "$(expected_uid)" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0022) == 0 ))
}

emit_error() {
  local code="$1" exit_code="$2"
  printf '{"status":"error","code":"%s"}\n' "$code"
  exit "$exit_code"
}

run_fixed_apt() {
  local apt_get env_bin stage="$1" package
  local -a packages=()
  apt_get="$(apt_get_path)" || return 1
  env_bin="$(env_path)" || return 1
  while IFS= read -r package; do packages+=("$package"); done < <(fixed_packages)
  ((${#packages[@]} == 15)) || return 1
  case "$stage" in
    update)
      "$env_bin" -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LANG=C.UTF-8 LC_ALL=C.UTF-8 \
        DEBIAN_FRONTEND=noninteractive "$apt_get" \
        -o DPkg::Lock::Timeout=60 -o Acquire::Retries=3 \
        -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 update \
        >/dev/null 2>&1
      ;;
    install)
      "$env_bin" -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LANG=C.UTF-8 LC_ALL=C.UTF-8 \
        DEBIAN_FRONTEND=noninteractive "$apt_get" \
        -o DPkg::Lock::Timeout=60 -o Acquire::Retries=3 \
        -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 \
        install -y --reinstall --no-install-recommends "${packages[@]}" \
        >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
}

main() {
  local logical state saw_missing=false
  platform_is_supported || emit_error unsupported_platform 20
  while IFS= read -r logical; do
    state="$(dependency_state "$logical")" || emit_error unsafe_dependency 21
    case "$state" in
      ready) ;;
      missing) saw_missing=true ;;
      *) emit_error unsafe_dependency 21 ;;
    esac
  done < <(required_dependency_paths)
  if [[ "$saw_missing" == false ]]; then
    printf '%s\n' '{"status":"ready"}'
    return 0
  fi
  runtime_executable_is_safe "$(apt_get_path)" /usr/bin/apt-get ||
    emit_error unsafe_runtime 22
  runtime_executable_is_safe "$(env_path)" /usr/bin/env || emit_error unsafe_runtime 22
  run_fixed_apt update || emit_error apt_update_failed 30
  run_fixed_apt install || emit_error apt_install_failed 31
  while IFS= read -r logical; do
    [[ "$(dependency_state "$logical")" == ready ]] || emit_error postcheck_failed 32
  done < <(required_dependency_paths)
  printf '%s\n' '{"status":"repaired"}'
}

main "$@"
EOF
  } > "$output"; then
    rm -f -- "$output" || true
    return 1
  fi
  chmod 600 "$output" || { rm -f -- "$output"; return 1; }
  controller_landing_private_file_is_trusted "$output" || {
    rm -f -- "$output"
    return 1
  }
  bash -n "$output" >/dev/null 2>&1 || { rm -f -- "$output"; return 1; }
  size="$(controller_landing_file_size "$output")" || { rm -f -- "$output"; return 1; }
  ((size >= 1 && size <= CONTROLLER_LANDING_DEPENDENCY_PACKAGE_MAX_BYTES)) || {
    rm -f -- "$output"
    return 1
  }
}

controller_landing_dependency_response_is_valid() {
  [[ $# -eq 2 ]] || return 64
  local response="$1" ssh_status="$2" size
  [[ "$ssh_status" =~ ^[0-9]+$ ]] || return 1
  controller_landing_private_file_is_trusted "$response" || return 1
  size="$(controller_landing_file_size "$response")" || return 1
  ((size >= 1 && size <= CONTROLLER_LANDING_DEPENDENCY_RESPONSE_MAX_BYTES)) || return 1
  jq -e -s --argjson ssh_status "$ssh_status" '
    length == 1 and
    if .[0] == {status:"ready"} or .[0] == {status:"repaired"} then
      $ssh_status == 0
    elif .[0] == {status:"error", code:"unsupported_platform"} then
      $ssh_status == 20
    elif .[0] == {status:"error", code:"unsafe_dependency"} then
      $ssh_status == 21
    elif .[0] == {status:"error", code:"unsafe_runtime"} then
      $ssh_status == 22
    elif .[0] == {status:"error", code:"apt_update_failed"} then
      $ssh_status == 30
    elif .[0] == {status:"error", code:"apt_install_failed"} then
      $ssh_status == 31
    elif .[0] == {status:"error", code:"postcheck_failed"} then
      $ssh_status == 32
    else false
    end
  ' "$response" >/dev/null 2>&1
}

controller_landing_prepare_dependencies_in_work() {
  [[ $# -eq 5 ]] || return 64
  local address="$1" ssh_port="$2" landing_id="$3" expected_fingerprint="$4" work="$5"
  local package="$work/dependency-package.sh" response="$work/dependency-response.json"
  local known_hosts ssh_status result
  controller_landing_dependency_settings_are_safe || return 1
  controller_landing_address_is_valid "$address" || return 1
  landing_port_is_valid "$ssh_port" || return 1
  landing_id_is_valid "$landing_id" || return 1
  [[ "$expected_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || return 1
  controller_private_directory_is_trusted "$work" || return 1
  known_hosts="$(controller_landing_prepare_known_hosts "$address" "$ssh_port" \
    "$expected_fingerprint" "sb-landing-$landing_id" "$work")" || {
      controller_landing_dependency_set_result fingerprint_recheck_failed
      return 1
    }
  controller_landing_build_dependency_package "$package" || {
    controller_landing_dependency_set_result package_build_failed
    return 1
  }
  if controller_landing_root_package_exchange "$address" "$ssh_port" "$landing_id" \
      "$known_hosts" "$expected_fingerprint" "$package" "$response" \
      "$CONTROLLER_LANDING_DEPENDENCY_SESSION_TIMEOUT"; then
    ssh_status=0
  else
    ssh_status="$CONTROLLER_LANDING_ROOT_PACKAGE_LAST_SSH_STATUS"
  fi
  if ! controller_landing_dependency_response_is_valid "$response" "$ssh_status"; then
    controller_landing_dependency_set_result ssh_uncertain
    return 1
  fi
  result="$(jq -r 'if .status == "error" then .code else .status end' "$response")" || {
    controller_landing_dependency_set_result ssh_uncertain
    return 1
  }
  case "$result" in
    ready|repaired)
      controller_landing_dependency_set_result "$result"
      return 0
      ;;
    unsupported_platform|unsafe_dependency|unsafe_runtime|apt_update_failed|apt_install_failed|postcheck_failed)
      controller_landing_dependency_set_result "$result"
      return 1
      ;;
    *)
      controller_landing_dependency_set_result ssh_uncertain
      return 1
      ;;
  esac
}

controller_prepare_landing_dependencies() {
  [[ $# -eq 3 ]] || return 64
  local address="$1" ssh_port="$2" landing_id="$3" fingerprint work rc=1 confirm_rc=0
  controller_landing_dependency_reset_result
  controller_landing_dependency_settings_are_safe || {
    controller_landing_dependency_set_result unsafe_local_runtime
    return 1
  }
  controller_landing_transport_runtime_is_safe || {
    controller_landing_dependency_set_result unsafe_local_runtime
    return 1
  }
  controller_landing_address_is_valid "$address" || {
    controller_landing_dependency_set_result invalid_input
    return 1
  }
  landing_port_is_valid "$ssh_port" || {
    controller_landing_dependency_set_result invalid_input
    return 1
  }
  landing_id_is_valid "$landing_id" || {
    controller_landing_dependency_set_result invalid_input
    return 1
  }
  validate_controller_state_file "$CONTROLLER_STATE_FILE" || {
    controller_landing_dependency_set_result invalid_controller_state
    return 1
  }
  fingerprint="$(controller_landing_discover_fingerprint "$address" "$ssh_port")" || {
    controller_landing_dependency_set_result fingerprint_discovery_failed
    return 1
  }
  # 结果由后续交互层与当前定向测试在函数返回后读取。
  # shellcheck disable=SC2034
  CONTROLLER_LANDING_DEPENDENCY_LAST_FINGERPRINT="$fingerprint"
  controller_confirm_landing_fingerprint "$address" "$ssh_port" "$fingerprint" || confirm_rc=$?
  if ((confirm_rc != 0)); then
    if ((confirm_rc == 2)); then
      controller_landing_dependency_set_result fingerprint_rejected
    else
      controller_landing_dependency_set_result fingerprint_confirmation_failed
    fi
    return 1
  fi
  work="$(controller_landing_create_work_directory)" || {
    controller_landing_dependency_set_result unsafe_local_runtime
    return 1
  }
  register_temp_path "$work" || {
    controller_landing_remove_work_directory "$work" || true
    controller_landing_dependency_set_result unsafe_local_runtime
    return 1
  }
  if controller_landing_prepare_dependencies_in_work "$address" "$ssh_port" "$landing_id" \
      "$fingerprint" "$work"; then
    rc=0
  fi
  controller_landing_remove_work_directory "$work" || {
    controller_landing_dependency_set_result local_cleanup_failed
    rc=1
  }
  return "$rc"
}
# ============================================================
# v5 入口发起的落地 sing-box 运行时准备（尚未接入菜单或角色安装）
# ============================================================
# 只安装入口已核对的官方稳定版二进制；不覆盖任何未知现有目标。
# shellcheck disable=SC2034

CONTROLLER_LANDING_SINGBOX_SESSION_TIMEOUT=900
CONTROLLER_LANDING_SINGBOX_RESPONSE_MAX_BYTES=512
CONTROLLER_LANDING_SINGBOX_BINARY_MAX_BYTES=67108864
CONTROLLER_LANDING_SINGBOX_PACKAGE_MAX_BYTES=134217728
CONTROLLER_LANDING_SINGBOX_LAST_STATUS=not_checked
CONTROLLER_LANDING_SINGBOX_LAST_DETAIL=""
CONTROLLER_LANDING_SINGBOX_LAST_FINGERPRINT=""
CONTROLLER_LANDING_SINGBOX_LAST_VERSION=""
CONTROLLER_LANDING_SINGBOX_LAST_SHA256=""
CONTROLLER_LANDING_SINGBOX_PREPARED_BINARY=""
CONTROLLER_LANDING_SINGBOX_RELEASE_VERSION=""
CONTROLLER_LANDING_SINGBOX_RELEASE_ASSET=""
CONTROLLER_LANDING_SINGBOX_RELEASE_URL=""
CONTROLLER_LANDING_SINGBOX_RELEASE_SHA256=""

controller_landing_singbox_reset_result() {
  CONTROLLER_LANDING_SINGBOX_LAST_STATUS=not_checked
  CONTROLLER_LANDING_SINGBOX_LAST_DETAIL=""
  CONTROLLER_LANDING_SINGBOX_LAST_FINGERPRINT=""
  CONTROLLER_LANDING_SINGBOX_LAST_VERSION=""
  CONTROLLER_LANDING_SINGBOX_LAST_SHA256=""
  CONTROLLER_LANDING_SINGBOX_PREPARED_BINARY=""
  CONTROLLER_LANDING_SINGBOX_RELEASE_VERSION=""
  CONTROLLER_LANDING_SINGBOX_RELEASE_ASSET=""
  CONTROLLER_LANDING_SINGBOX_RELEASE_URL=""
  CONTROLLER_LANDING_SINGBOX_RELEASE_SHA256=""
}

controller_landing_singbox_set_result() {
  # 结果由后续交互层与定向测试在函数返回后读取。
  # shellcheck disable=SC2034
  CONTROLLER_LANDING_SINGBOX_LAST_STATUS="$1"
  # shellcheck disable=SC2034
  CONTROLLER_LANDING_SINGBOX_LAST_DETAIL="${2:-}"
}

controller_landing_singbox_settings_are_safe() {
  [[ "$CONTROLLER_LANDING_SINGBOX_SESSION_TIMEOUT" == 900 &&
     "$CONTROLLER_LANDING_SINGBOX_RESPONSE_MAX_BYTES" == 512 &&
     "$CONTROLLER_LANDING_SINGBOX_BINARY_MAX_BYTES" == 67108864 &&
     "$CONTROLLER_LANDING_SINGBOX_PACKAGE_MAX_BYTES" == 134217728 ]]
}

controller_landing_singbox_release_is_valid() {
  [[ $# -eq 4 ]] || return 64
  local version="$1" asset="$2" url="$3" sha256
  sha256="$(printf '%s' "$4" | tr 'A-F' 'a-f')" || return 1
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  [[ "$asset" == "sing-box-${version}-${SINGBOX_ARCH}.tar.gz" ]] || return 1
  [[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$url" != *$'\n'* && "$url" != *$'\r'* && "$url" != *'?'* && "$url" != *'#'* ]] ||
    return 1
  [[ "$url" == "https://github.com/${SINGBOX_REPOSITORY}/releases/download/v${version}/${asset}" ||
     "$url" == "https://github.com/${SINGBOX_REPOSITORY}/releases/download/${version}/${asset}" ]]
}

controller_landing_fetch_stable_singbox_release() {
  local release_json metadata
  release_json="$(github_api_get \
    "https://api.github.com/repos/${SINGBOX_REPOSITORY}/releases/latest")" || return 1
  metadata="$(singbox_release_metadata "$release_json")" || return 1
  CONTROLLER_LANDING_SINGBOX_RELEASE_VERSION="$(jq -r '.version' <<<"$metadata")" || return 1
  CONTROLLER_LANDING_SINGBOX_RELEASE_ASSET="$(jq -r '.asset' <<<"$metadata")" || return 1
  CONTROLLER_LANDING_SINGBOX_RELEASE_URL="$(jq -r '.url' <<<"$metadata")" || return 1
  CONTROLLER_LANDING_SINGBOX_RELEASE_SHA256="$(jq -r '.sha256 | ascii_downcase' \
    <<<"$metadata")" || return 1
  controller_landing_singbox_release_is_valid \
    "$CONTROLLER_LANDING_SINGBOX_RELEASE_VERSION" \
    "$CONTROLLER_LANDING_SINGBOX_RELEASE_ASSET" \
    "$CONTROLLER_LANDING_SINGBOX_RELEASE_URL" \
    "$CONTROLLER_LANDING_SINGBOX_RELEASE_SHA256"
}

controller_landing_local_singbox_binary_is_valid() {
  [[ $# -eq 3 ]] || return 64
  local binary="$1" version="$2" expected_sha
  local owner mode size actual_sha detected expected_owner
  expected_sha="$(printf '%s' "$3" | tr 'A-F' 'a-f')" || return 1
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$expected_sha" =~ ^[0-9a-f]{64}$ ]] ||
    return 1
  [[ -f "$binary" && ! -L "$binary" && -x "$binary" ]] || return 1
  owner="$(manager_file_uid "$binary")" || return 1
  expected_owner="$(controller_state_expected_uid)" || return 1
  [[ "$owner" == "$expected_owner" ]] || return 1
  mode="$(manager_file_mode "$binary")" || return 1
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0022) == 0 )) || return 1
  size="$(controller_landing_file_size "$binary")" || return 1
  ((size >= 1 && size <= CONTROLLER_LANDING_SINGBOX_BINARY_MAX_BYTES)) || return 1
  actual_sha="$(sha256sum "$binary" | awk '{print $1}')" || return 1
  [[ "$actual_sha" == "$expected_sha" ]] || return 1
  detected="$("$binary" version 2>/dev/null | awk 'NR == 1 { print $3 }')" || return 1
  [[ "$detected" == "$version" ]]
}

controller_landing_prepare_verified_singbox_binary() {
  [[ $# -eq 1 ]] || return 64
  local work="$1" binary actual_sha
  controller_landing_singbox_settings_are_safe || return 1
  controller_private_directory_is_trusted "$work" || return 1
  controller_landing_fetch_stable_singbox_release || return 1
  prepare_singbox_release_binary \
    "$CONTROLLER_LANDING_SINGBOX_RELEASE_VERSION" \
    "$CONTROLLER_LANDING_SINGBOX_RELEASE_ASSET" \
    "$CONTROLLER_LANDING_SINGBOX_RELEASE_URL" \
    "$CONTROLLER_LANDING_SINGBOX_RELEASE_SHA256" "$work" landing-stable || return 1
  binary="$PREPARED_SINGBOX_BINARY"
  actual_sha="$(sha256sum "$binary" | awk '{print $1}')" || return 1
  [[ "$actual_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
  controller_landing_local_singbox_binary_is_valid "$binary" \
    "$CONTROLLER_LANDING_SINGBOX_RELEASE_VERSION" "$actual_sha" || return 1
  CONTROLLER_LANDING_SINGBOX_PREPARED_BINARY="$binary"
  CONTROLLER_LANDING_SINGBOX_LAST_VERSION="$CONTROLLER_LANDING_SINGBOX_RELEASE_VERSION"
  # shellcheck disable=SC2034
  CONTROLLER_LANDING_SINGBOX_LAST_SHA256="$actual_sha"
}

controller_landing_build_singbox_runtime_package() {
  [[ $# -eq 3 ]] || return 64
  local version="$1" binary="$2" output="$3" output_parent binary_sha size
  local test_root="" test_system="" test_machine="" test_tool_dir="" test_failure=""
  controller_landing_singbox_settings_are_safe || return 1
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  output_parent="$(dirname -- "$output")" || return 1
  controller_private_directory_is_trusted "$output_parent" || return 1
  [[ ! -e "$output" && ! -L "$output" ]] || return 1
  binary_sha="$(sha256sum "$binary" | awk '{print $1}')" || return 1
  controller_landing_local_singbox_binary_is_valid "$binary" "$version" "$binary_sha" ||
    return 1
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true &&
        -n "${SB_LANDING_SINGBOX_PREP_TEST_ROOT:-}" ]]; then
    test_root="$SB_LANDING_SINGBOX_PREP_TEST_ROOT"
    test_system="${SB_LANDING_SINGBOX_PREP_TEST_SYSTEM:-Linux}"
    test_machine="${SB_LANDING_SINGBOX_PREP_TEST_MACHINE:-x86_64}"
    test_tool_dir="${SB_LANDING_SINGBOX_PREP_TEST_TOOL_DIR:-}"
    test_failure="${SB_LANDING_SINGBOX_PREP_TEST_FAILURE:-}"
    [[ "$test_root" == /* && "$test_root" != / && "$test_root" != */ &&
       "$test_root" != *$'\n'* && "$test_tool_dir" == /* && "$test_tool_dir" != / &&
       "$test_tool_dir" != */ && "$test_tool_dir" != *$'\n'* &&
       "$test_system" =~ ^[A-Za-z0-9._-]+$ && "$test_machine" =~ ^[A-Za-z0-9._-]+$ &&
       "$test_failure" =~ ^(install|postcheck)?$ ]] || return 1
    controller_private_directory_is_trusted "$test_root" || return 1
    controller_private_directory_is_trusted "$test_tool_dir" || return 1
  fi

  if ! cat > "$output" <<EOF
#!/bin/bash
set -Eeuo pipefail
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
LC_ALL=C
export PATH LC_ALL
unset BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH OPENSSL_CONF
expected_version=$version
expected_sha256=$binary_sha
test_root=$(printf '%q' "$test_root")
test_system=$(printf '%q' "$test_system")
test_machine=$(printf '%q' "$test_machine")
test_tool_dir=$(printf '%q' "$test_tool_dir")
test_failure=$(printf '%q' "$test_failure")

tool_path() {
  local logical="\$1"
  if [[ -n "\$test_tool_dir" ]]; then
    printf '%s/%s\n' "\$test_tool_dir" "\${logical##*/}"
  else
    printf '%s\n' "\$logical"
  fi
}

target_path() {
  if [[ -n "\$test_root" ]]; then
    printf '%s/usr/local/bin/sing-box\n' "\$test_root"
  else
    printf '/usr/local/bin/sing-box\n'
  fi
}

target_parent() {
  if [[ -n "\$test_root" ]]; then
    printf '%s/usr/local/bin\n' "\$test_root"
  else
    printf '/usr/local/bin\n'
  fi
}

os_release_path() {
  if [[ -n "\$test_root" ]]; then
    printf '%s/os-release\n' "\$test_root"
  else
    printf '/usr/lib/os-release\n'
  fi
}

expected_uid() {
  if [[ -n "\$test_root" ]]; then printf '%s\n' "\$EUID"; else printf '0\n'; fi
}

path_metadata() {
  local stat_bin
  stat_bin="\$(tool_path /usr/bin/stat)" || return 1
  "\$stat_bin" -Lc '%u %a' -- "\$1" 2>/dev/null ||
    "\$stat_bin" -f '%u %Lp' "\$1" 2>/dev/null
}

trusted_executable() {
  local logical="\$1" path metadata uid mode
  path="\$(tool_path "\$logical")" || return 1
  [[ -f "\$path" && ! -L "\$path" && -x "\$path" ]] || return 1
  metadata="\$(path_metadata "\$path")" || return 1
  read -r uid mode <<< "\$metadata"
  [[ "\$uid" == "\$(expected_uid)" && "\$mode" =~ ^[0-7]{3,4}\$ ]] || return 1
  (( (8#\$mode & 0022) == 0 ))
}

runtime_tools_are_safe() {
  local logical
  for logical in /bin/bash /usr/bin/base64 /bin/chmod /usr/bin/mktemp \
    /usr/bin/ln /bin/rm /usr/bin/sha256sum /usr/bin/stat /bin/sync /usr/bin/uname; do
    trusted_executable "\$logical" || return 1
  done
}

trusted_directory() {
  local path="\$1" metadata uid mode
  [[ -d "\$path" && ! -L "\$path" ]] || return 1
  metadata="\$(path_metadata "\$path")" || return 1
  read -r uid mode <<< "\$metadata"
  [[ "\$uid" == "\$(expected_uid)" && "\$mode" =~ ^[0-7]{3,4}\$ ]] || return 1
  (( (8#\$mode & 0022) == 0 ))
}

target_directory_chain_is_safe() {
  local path
  if [[ -n "\$test_root" ]]; then
    trusted_directory "\$(target_parent)"
    return
  fi
  for path in /usr /usr/local /usr/local/bin; do
    trusted_directory "\$path" || return 1
  done
}

platform_is_supported() {
  local os_release system machine metadata uid mode key value os_id="" version_id=""
  if [[ -n "\$test_root" ]]; then
    system="\$test_system"; machine="\$test_machine"
  else
    [[ "\$EUID" -eq 0 ]] || return 1
    system="\$("\$(tool_path /usr/bin/uname)" -s)" || return 1
    machine="\$("\$(tool_path /usr/bin/uname)" -m)" || return 1
  fi
  [[ "\$system" == Linux && "\$machine" == x86_64 ]] || return 1
  os_release="\$(os_release_path)" || return 1
  [[ -f "\$os_release" && ! -L "\$os_release" && -r "\$os_release" ]] || return 1
  metadata="\$(path_metadata "\$os_release")" || return 1
  read -r uid mode <<< "\$metadata"
  [[ "\$uid" == "\$(expected_uid)" && "\$mode" =~ ^[0-7]{3,4}\$ ]] || return 1
  (( (8#\$mode & 0022) == 0 )) || return 1
  while IFS='=' read -r key value; do
    case "\$key" in
      ID) [[ -z "\$os_id" ]] || return 1; os_id="\$value" ;;
      VERSION_ID) [[ -z "\$version_id" ]] || return 1; version_id="\$value" ;;
    esac
  done < "\$os_release"
  [[ "\$os_id" == debian && "\$version_id" == '"12"' ]]
}

binary_sha256() {
  local sha_bin output
  sha_bin="\$(tool_path /usr/bin/sha256sum)" || return 1
  output="\$("\$sha_bin" "\$1")" || return 1
  printf '%s\n' "\${output%% *}"
}

binary_version() {
  local line first second version remainder
  line="\$("\$1" version 2>/dev/null)" || return 1
  line="\${line%%\$'\n'*}"
  read -r first second version remainder <<< "\$line"
  [[ "\$first" == sing-box && "\$second" == version && -z "\$remainder" ]] || return 1
  printf '%s\n' "\$version"
}

existing_target_is_safe() {
  local target="\$1" metadata uid mode
  [[ -f "\$target" && ! -L "\$target" && -x "\$target" ]] || return 1
  metadata="\$(path_metadata "\$target")" || return 1
  read -r uid mode <<< "\$metadata"
  [[ "\$uid" == "\$(expected_uid)" && "\$mode" =~ ^[0-7]{3,4}\$ ]] || return 1
  (( (8#\$mode & 0022) == 0 ))
}

existing_target_matches() {
  existing_target_is_safe "\$1" || return 1
  [[ "\$(binary_sha256 "\$1")" == "\$expected_sha256" ]] || return 1
  [[ "\$(binary_version "\$1")" == "\$expected_version" ]]
}

emit_error() {
  printf '{"status":"error","code":"%s"}\n' "\$1"
  exit "\$2"
}

payload_to() {
  "\$(tool_path /usr/bin/base64)" -d > "\$1" 2>/dev/null <<'__SB_LANDING_SINGBOX_BINARY__'
EOF
  then
    return 1
  fi
  if ! base64 < "$binary" >> "$output"; then
    rm -f -- "$output" || true
    return 1
  fi
  if ! cat >> "$output" <<'EOF'
__SB_LANDING_SINGBOX_BINARY__
}

main() {
  local target parent temp="" chmod_bin ln_bin mktemp_bin rm_bin sync_bin
  runtime_tools_are_safe || emit_error unsafe_runtime 23
  platform_is_supported || emit_error unsupported_platform 20
  target="$(target_path)" || emit_error unsafe_runtime 23
  parent="$(target_parent)" || emit_error unsafe_runtime 23
  target_directory_chain_is_safe || emit_error unsafe_runtime 23
  if [[ -e "$target" || -L "$target" ]]; then
    existing_target_is_safe "$target" || emit_error unsafe_existing 21
    existing_target_matches "$target" || emit_error existing_conflict 22
    printf '%s\n' '{"status":"ready"}'
    return 0
  fi
  chmod_bin="$(tool_path /bin/chmod)" || emit_error unsafe_runtime 23
  mktemp_bin="$(tool_path /usr/bin/mktemp)" || emit_error unsafe_runtime 23
  ln_bin="$(tool_path /usr/bin/ln)" || emit_error unsafe_runtime 23
  rm_bin="$(tool_path /bin/rm)" || emit_error unsafe_runtime 23
  sync_bin="$(tool_path /bin/sync)" || emit_error unsafe_runtime 23
  temp="$($mktemp_bin "$parent/.sb-sing-box.XXXXXXXXXX")" || emit_error install_failed 32
  [[ "$temp" == "$parent"/.sb-sing-box.[A-Za-z0-9]* && -f "$temp" && ! -L "$temp" ]] ||
    emit_error install_failed 32
  cleanup_temp() {
    [[ -z "${temp:-}" ]] || "$rm_bin" -f -- "$temp" || true
  }
  trap cleanup_temp EXIT HUP INT QUIT TERM
  payload_to "$temp" || emit_error payload_invalid 30
  "$chmod_bin" 755 "$temp" || emit_error install_failed 32
  [[ "$(binary_sha256 "$temp")" == "$expected_sha256" ]] || emit_error payload_invalid 30
  [[ "$(binary_version "$temp")" == "$expected_version" ]] || emit_error payload_invalid 30
  [[ "$test_failure" != install ]] || emit_error install_failed 32
  "$sync_bin" "$temp" >/dev/null 2>&1 || emit_error install_failed 32
  [[ ! -e "$target" && ! -L "$target" ]] || emit_error existing_conflict 22
  if ! "$ln_bin" -- "$temp" "$target"; then
    if [[ -e "$target" || -L "$target" ]]; then
      emit_error existing_conflict 22
    fi
    emit_error install_failed 32
  fi
  "$rm_bin" -f -- "$temp" || emit_error install_failed 32
  temp=""
  "$sync_bin" "$parent" >/dev/null 2>&1 || emit_error postcheck_failed 33
  if [[ "$test_failure" == postcheck ]] || ! existing_target_matches "$target"; then
    if existing_target_is_safe "$target" &&
       [[ "$(binary_sha256 "$target")" == "$expected_sha256" ]]; then
      "$rm_bin" -f -- "$target" || true
      "$sync_bin" "$parent" >/dev/null 2>&1 || true
    fi
    emit_error postcheck_failed 33
  fi
  printf '%s\n' '{"status":"installed"}'
}

main "$@"
EOF
  then
    rm -f -- "$output" || true
    return 1
  fi
  chmod 600 "$output" || { rm -f -- "$output"; return 1; }
  controller_landing_private_file_is_trusted "$output" || {
    rm -f -- "$output"
    return 1
  }
  bash -n "$output" >/dev/null 2>&1 || { rm -f -- "$output"; return 1; }
  size="$(controller_landing_file_size "$output")" || { rm -f -- "$output"; return 1; }
  ((size >= 1 && size <= CONTROLLER_LANDING_SINGBOX_PACKAGE_MAX_BYTES)) || {
    rm -f -- "$output"
    return 1
  }
}

controller_landing_singbox_response_is_valid() {
  [[ $# -eq 2 ]] || return 64
  local response="$1" ssh_status="$2" size
  [[ "$ssh_status" =~ ^[0-9]+$ ]] || return 1
  controller_landing_private_file_is_trusted "$response" || return 1
  size="$(controller_landing_file_size "$response")" || return 1
  ((size >= 1 && size <= CONTROLLER_LANDING_SINGBOX_RESPONSE_MAX_BYTES)) || return 1
  jq -e -s --argjson ssh_status "$ssh_status" '
    length == 1 and
    if .[0] == {status:"ready"} or .[0] == {status:"installed"} then
      $ssh_status == 0
    elif .[0] == {status:"error", code:"unsupported_platform"} then
      $ssh_status == 20
    elif .[0] == {status:"error", code:"unsafe_existing"} then
      $ssh_status == 21
    elif .[0] == {status:"error", code:"existing_conflict"} then
      $ssh_status == 22
    elif .[0] == {status:"error", code:"unsafe_runtime"} then
      $ssh_status == 23
    elif .[0] == {status:"error", code:"payload_invalid"} then
      $ssh_status == 30
    elif .[0] == {status:"error", code:"install_failed"} then
      $ssh_status == 32
    elif .[0] == {status:"error", code:"postcheck_failed"} then
      $ssh_status == 33
    else false
    end
  ' "$response" >/dev/null 2>&1
}

controller_landing_prepare_singbox_runtime_in_work() {
  [[ $# -eq 5 ]] || return 64
  local address="$1" ssh_port="$2" landing_id="$3" expected_fingerprint="$4" work="$5"
  local package="$work/singbox-runtime-package.sh" response="$work/singbox-runtime-response.json"
  local known_hosts ssh_status result
  controller_landing_singbox_settings_are_safe || return 1
  controller_landing_address_is_valid "$address" || return 1
  landing_port_is_valid "$ssh_port" || return 1
  landing_id_is_valid "$landing_id" || return 1
  [[ "$expected_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || return 1
  controller_private_directory_is_trusted "$work" || return 1
  controller_landing_prepare_verified_singbox_binary "$work" || {
    controller_landing_singbox_set_result release_prepare_failed
    return 1
  }
  known_hosts="$(controller_landing_prepare_known_hosts "$address" "$ssh_port" \
    "$expected_fingerprint" "sb-landing-$landing_id" "$work")" || {
      controller_landing_singbox_set_result fingerprint_recheck_failed
      return 1
    }
  controller_landing_build_singbox_runtime_package \
    "$CONTROLLER_LANDING_SINGBOX_LAST_VERSION" \
    "$CONTROLLER_LANDING_SINGBOX_PREPARED_BINARY" "$package" || {
      controller_landing_singbox_set_result package_build_failed
      return 1
    }
  if controller_landing_root_package_exchange "$address" "$ssh_port" "$landing_id" \
      "$known_hosts" "$expected_fingerprint" "$package" "$response" \
      "$CONTROLLER_LANDING_SINGBOX_SESSION_TIMEOUT"; then
    ssh_status=0
  else
    ssh_status="$CONTROLLER_LANDING_ROOT_PACKAGE_LAST_SSH_STATUS"
  fi
  if ! controller_landing_singbox_response_is_valid "$response" "$ssh_status"; then
    controller_landing_singbox_set_result ssh_uncertain
    return 1
  fi
  result="$(jq -r 'if .status == "error" then .code else .status end' "$response")" || {
    controller_landing_singbox_set_result ssh_uncertain
    return 1
  }
  case "$result" in
    ready|installed)
      controller_landing_singbox_set_result "$result"
      return 0
      ;;
    unsupported_platform|unsafe_existing|existing_conflict|unsafe_runtime|payload_invalid|install_failed|postcheck_failed)
      controller_landing_singbox_set_result "$result"
      return 1
      ;;
    *)
      controller_landing_singbox_set_result ssh_uncertain
      return 1
      ;;
  esac
}

controller_prepare_landing_singbox_runtime() {
  [[ $# -eq 3 ]] || return 64
  local address="$1" ssh_port="$2" landing_id="$3" fingerprint work rc=1 confirm_rc=0
  controller_landing_singbox_reset_result
  controller_landing_singbox_settings_are_safe || {
    controller_landing_singbox_set_result unsafe_local_runtime
    return 1
  }
  controller_landing_transport_runtime_is_safe || {
    controller_landing_singbox_set_result unsafe_local_runtime
    return 1
  }
  controller_landing_address_is_valid "$address" || {
    controller_landing_singbox_set_result invalid_input
    return 1
  }
  landing_port_is_valid "$ssh_port" || {
    controller_landing_singbox_set_result invalid_input
    return 1
  }
  landing_id_is_valid "$landing_id" || {
    controller_landing_singbox_set_result invalid_input
    return 1
  }
  validate_controller_state_file "$CONTROLLER_STATE_FILE" || {
    controller_landing_singbox_set_result invalid_controller_state
    return 1
  }
  fingerprint="$(controller_landing_discover_fingerprint "$address" "$ssh_port")" || {
    controller_landing_singbox_set_result fingerprint_discovery_failed
    return 1
  }
  # 结果由后续交互层与定向测试在函数返回后读取。
  # shellcheck disable=SC2034
  CONTROLLER_LANDING_SINGBOX_LAST_FINGERPRINT="$fingerprint"
  controller_confirm_landing_fingerprint "$address" "$ssh_port" "$fingerprint" || confirm_rc=$?
  if ((confirm_rc != 0)); then
    if ((confirm_rc == 2)); then
      controller_landing_singbox_set_result fingerprint_rejected
    else
      controller_landing_singbox_set_result fingerprint_confirmation_failed
    fi
    return 1
  fi
  work="$(controller_landing_create_work_directory)" || {
    controller_landing_singbox_set_result unsafe_local_runtime
    return 1
  }
  register_temp_path "$work" || {
    controller_landing_remove_work_directory "$work" || true
    controller_landing_singbox_set_result unsafe_local_runtime
    return 1
  }
  if controller_landing_prepare_singbox_runtime_in_work "$address" "$ssh_port" "$landing_id" \
      "$fingerprint" "$work"; then
    rc=0
  fi
  controller_landing_remove_work_directory "$work" || {
    controller_landing_singbox_set_result local_cleanup_failed
    rc=1
  }
  return "$rc"
}
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
# ============================================================
# v5 入口侧落地初始化持久日志（尚未接入菜单或服务器）
# ============================================================

CONTROLLER_LANDING_ONBOARDING_JOURNAL_SCHEMA_VERSION=1
CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE="${SB_CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE:-/var/lib/sb-user-manager/controller-onboarding.json}"
CONTROLLER_LANDING_ONBOARDING_JOURNAL_NEXT="${CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE}.next"
CONTROLLER_LANDING_ONBOARDING_LOCK_FILE="${SB_CONTROLLER_LANDING_ONBOARDING_LOCK_FILE:-/run/lock/sb-user-manager/controller-onboarding.lock}"
CONTROLLER_LANDING_ONBOARDING_LOCK_TIMEOUT=30
CONTROLLER_LANDING_ONBOARDING_JOURNAL_MAX_BYTES=8192

controller_landing_onboarding_absolute_path_is_safe() {
  local path="$1"
  [[ "$path" == /* && "$path" != / && "$path" != */ &&
     "$path" != *//* && "$path" != */../* && "$path" != */.. &&
     "$path" != */./* && "$path" != */. ]]
}

controller_landing_onboarding_paths_are_safe() {
  local journal_parent state_parent
  controller_landing_onboarding_absolute_path_is_safe \
    "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE" || return 1
  controller_landing_onboarding_absolute_path_is_safe \
    "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_NEXT" || return 1
  controller_landing_onboarding_absolute_path_is_safe \
    "$CONTROLLER_LANDING_ONBOARDING_LOCK_FILE" || return 1
  [[ "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_NEXT" == "${CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE}.next" &&
     "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE" != "$CONTROLLER_STATE_FILE" &&
     "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE" != "$CONTROLLER_LANDING_ONBOARDING_LOCK_FILE" ]] ||
    return 1
  journal_parent="$(dirname -- "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE")" || return 1
  state_parent="$(dirname -- "$CONTROLLER_STATE_FILE")" || return 1
  [[ "$journal_parent" == "$state_parent" ]] || return 1
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    [[ "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE" == /var/lib/sb-user-manager/controller-onboarding.json &&
       "$CONTROLLER_LANDING_ONBOARDING_LOCK_FILE" == /run/lock/sb-user-manager/controller-onboarding.lock ]] ||
      return 1
  fi
}

controller_landing_onboarding_private_file_is_trusted() {
  local path="$1" max_bytes="$2" owner mode expected_owner size
  [[ -f "$path" && ! -L "$path" && -r "$path" ]] || return 1
  owner="$(manager_file_uid "$path")" || return 1
  expected_owner="$(controller_state_expected_uid)" || return 1
  [[ "$owner" == "$expected_owner" ]] || return 1
  mode="$(manager_file_mode "$path")" || return 1
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0777) == 0600 )) || return 1
  size="$(controller_landing_file_size "$path")" || return 1
  [[ "$size" =~ ^[0-9]+$ ]] || return 1
  ((size <= max_bytes))
}

controller_landing_onboarding_values_are_valid() {
  [[ $# -eq 12 ]] || return 64
  local stage="$1" operation_id="$2" bootstrap_id="$3" landing_id="$4"
  local display_name="$5" address="$6" ssh_port="$7" gateway_port="$8"
  local server_name="$9" allowed_entry_ipv4="${10}" fingerprint="${11}"
  local credentials_preexisting="${12}"
  case "$stage" in
    credentials_pending|bootstrap_pending|registration_pending|apply_pending|local_aborted|remote_rolled_back|completed) ;;
    *) return 1 ;;
  esac
  [[ "$operation_id" =~ ^[0-9a-f]{64}$ &&
     "$bootstrap_id" =~ ^[0-9a-f]{64}$ ]] || return 1
  landing_id_is_valid "$landing_id" || return 1
  controller_landing_display_name_is_valid "$display_name" || return 1
  controller_landing_address_is_valid "$address" || return 1
  landing_port_is_valid "$ssh_port" || return 1
  landing_port_is_valid "$gateway_port" || return 1
  ((10#$ssh_port != 10#$gateway_port)) || return 1
  controller_dns_name_is_valid "$server_name" || return 1
  is_public_ipv4 "$allowed_entry_ipv4" || return 1
  [[ "$fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || return 1
  [[ "$credentials_preexisting" == true || "$credentials_preexisting" == false ]]
}

controller_landing_onboarding_journal_json_is_valid() {
  local path="$1" operation_id bootstrap_id landing_id display_name address
  local ssh_port gateway_port server_name allowed_entry_ipv4 fingerprint
  local credentials_preexisting stage
  jq -e -s --argjson schema "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_SCHEMA_VERSION" '
    length == 1 and
    .[0] as $journal |
    ($journal | type == "object") and
    ($journal | keys | sort) == [
      "address", "allowed_entry_ipv4", "bootstrap_id", "credentials_preexisting",
      "display_name", "gateway_port", "landing_id", "operation_id",
      "schema_version", "server_name", "ssh_host_fingerprint", "ssh_port", "stage"
    ] and
    $journal.schema_version == $schema and
    ($journal.operation_id | type == "string" and test("^[0-9a-f]{64}$")) and
    ($journal.bootstrap_id | type == "string" and test("^[0-9a-f]{64}$")) and
    ($journal.landing_id | type == "string" and test("^[a-z][a-z0-9-]{0,31}$")) and
    ($journal.display_name | type == "string" and length >= 1 and length <= 64 and
      (test("[[:cntrl:]]") | not)) and
    ($journal.address | type == "string" and length >= 1 and length <= 253) and
    ($journal.ssh_port | type == "number" and . == floor and . >= 1 and . <= 65535) and
    ($journal.gateway_port | type == "number" and . == floor and . >= 1 and . <= 65535) and
    ($journal.server_name | type == "string" and length >= 3 and length <= 253) and
    ($journal.allowed_entry_ipv4 | type == "string" and length >= 7 and length <= 15) and
    ($journal.ssh_host_fingerprint | type == "string" and
      test("^SHA256:[A-Za-z0-9+/]{43}$")) and
    ($journal.credentials_preexisting | type == "boolean") and
    ($journal.stage == "credentials_pending" or
      $journal.stage == "bootstrap_pending" or
      $journal.stage == "registration_pending" or
      $journal.stage == "apply_pending" or
      $journal.stage == "local_aborted" or
      $journal.stage == "remote_rolled_back" or
      $journal.stage == "completed")
  ' "$path" >/dev/null 2>&1 || return 1
  IFS=$'\t' read -r operation_id bootstrap_id landing_id display_name address \
    ssh_port gateway_port server_name allowed_entry_ipv4 fingerprint \
    credentials_preexisting stage < <(
      jq -r '[
        .operation_id, .bootstrap_id, .landing_id, .display_name, .address,
        .ssh_port, .gateway_port, .server_name, .allowed_entry_ipv4,
        .ssh_host_fingerprint, .credentials_preexisting, .stage
      ] | @tsv' "$path"
    ) || return 1
  controller_landing_onboarding_values_are_valid "$stage" "$operation_id" \
    "$bootstrap_id" "$landing_id" "$display_name" "$address" "$ssh_port" \
    "$gateway_port" "$server_name" "$allowed_entry_ipv4" "$fingerprint" \
    "$credentials_preexisting"
}

controller_landing_onboarding_journal_is_trusted() {
  local path="${1:-$CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE}"
  controller_landing_onboarding_paths_are_safe || return 1
  [[ "$path" == "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE" ||
     "$path" == "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_NEXT" ]] || return 1
  controller_landing_onboarding_private_file_is_trusted "$path" \
    "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_MAX_BYTES" || return 1
  controller_landing_onboarding_journal_json_is_valid "$path"
}

controller_landing_onboarding_remove_next_file() {
  local next="$CONTROLLER_LANDING_ONBOARDING_JOURNAL_NEXT" parent
  controller_landing_onboarding_paths_are_safe || return 1
  [[ -e "$next" || -L "$next" ]] || return 0
  controller_landing_onboarding_private_file_is_trusted "$next" \
    "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_MAX_BYTES" || return 1
  parent="$(dirname -- "$next")" || return 1
  rm -f -- "$next" || return 1
  sync_transaction_path "$parent"
}

controller_landing_onboarding_stage_transition_is_valid() {
  local current="$1" next="$2"
  [[ "$current" == "$next" ]] && return 0
  case "$current:$next" in
    credentials_pending:bootstrap_pending|credentials_pending:local_aborted|bootstrap_pending:local_aborted|bootstrap_pending:registration_pending|bootstrap_pending:remote_rolled_back|registration_pending:apply_pending|registration_pending:remote_rolled_back|apply_pending:completed) return 0 ;;
    *) return 1 ;;
  esac
}

controller_landing_onboarding_journal_matches_values() {
  [[ $# -eq 11 ]] || return 64
  local operation_id="$1" bootstrap_id="$2" landing_id="$3" display_name="$4"
  local address="$5" ssh_port="$6" gateway_port="$7" server_name="$8"
  local allowed_entry_ipv4="$9" fingerprint="${10}" credentials_preexisting="${11}"
  local SB_CONTROLLER_ONBOARDING_SERVER_NAME="$server_name"
  export SB_CONTROLLER_ONBOARDING_SERVER_NAME
  controller_landing_onboarding_journal_is_trusted || return 1
  jq -e --arg operation_id "$operation_id" --arg bootstrap_id "$bootstrap_id" \
    --arg landing_id "$landing_id" --arg display_name "$display_name" \
    --arg address "$address" --argjson ssh_port "$((10#$ssh_port))" \
    --argjson gateway_port "$((10#$gateway_port))" \
    --arg allowed_entry_ipv4 "$allowed_entry_ipv4" --arg fingerprint "$fingerprint" \
    --argjson credentials_preexisting "$credentials_preexisting" '
      .operation_id == $operation_id and
      .bootstrap_id == $bootstrap_id and
      .landing_id == $landing_id and
      .display_name == $display_name and
      .address == $address and
      .ssh_port == $ssh_port and
      .gateway_port == $gateway_port and
      .server_name == $ENV.SB_CONTROLLER_ONBOARDING_SERVER_NAME and
      .allowed_entry_ipv4 == $allowed_entry_ipv4 and
      .ssh_host_fingerprint == $fingerprint and
      .credentials_preexisting == $credentials_preexisting
    ' "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE" >/dev/null 2>&1
}

controller_landing_onboarding_write_journal() {
  [[ $# -eq 12 ]] || return 64
  local stage="$1" operation_id="$2" bootstrap_id="$3" landing_id="$4"
  local display_name="$5" address="$6" ssh_port="$7" gateway_port="$8"
  local server_name="$9" allowed_entry_ipv4="${10}" fingerprint="${11}"
  local credentials_preexisting="${12}" journal next parent current_stage
  local SB_CONTROLLER_ONBOARDING_SERVER_NAME="$server_name"
  export SB_CONTROLLER_ONBOARDING_SERVER_NAME
  controller_landing_onboarding_values_are_valid "$stage" "$operation_id" \
    "$bootstrap_id" "$landing_id" "$display_name" "$address" "$ssh_port" \
    "$gateway_port" "$server_name" "$allowed_entry_ipv4" "$fingerprint" \
    "$credentials_preexisting" || return 1
  controller_landing_onboarding_paths_are_safe || return 1
  journal="$CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE"
  next="$CONTROLLER_LANDING_ONBOARDING_JOURNAL_NEXT"
  parent="$(dirname -- "$journal")" || return 1
  ensure_controller_private_directory "$parent" || return 1
  if [[ -e "$journal" || -L "$journal" ]]; then
    controller_landing_onboarding_journal_matches_values "$operation_id" \
      "$bootstrap_id" "$landing_id" "$display_name" "$address" "$ssh_port" \
      "$gateway_port" "$server_name" "$allowed_entry_ipv4" "$fingerprint" \
      "$credentials_preexisting" || return 1
    current_stage="$(jq -r '.stage' "$journal")" || return 1
    controller_landing_onboarding_stage_transition_is_valid "$current_stage" \
      "$stage" || return 1
  else
    [[ "$stage" == credentials_pending ]] || return 1
  fi
  controller_landing_onboarding_remove_next_file || return 1
  (umask 077; set -o noclobber; : > "$next") 2>/dev/null || return 1
  chmod 600 "$next" || { rm -f -- "$next" || true; return 1; }
  if ! jq -n --argjson schema "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_SCHEMA_VERSION" \
      --arg stage "$stage" --arg operation_id "$operation_id" \
      --arg bootstrap_id "$bootstrap_id" --arg landing_id "$landing_id" \
      --arg display_name "$display_name" --arg address "$address" \
      --argjson ssh_port "$((10#$ssh_port))" \
      --argjson gateway_port "$((10#$gateway_port))" \
      --arg allowed_entry_ipv4 "$allowed_entry_ipv4" --arg fingerprint "$fingerprint" \
      --argjson credentials_preexisting "$credentials_preexisting" '
        {
          schema_version:$schema,
          operation_id:$operation_id,
          bootstrap_id:$bootstrap_id,
          landing_id:$landing_id,
          display_name:$display_name,
          address:$address,
          ssh_port:$ssh_port,
          gateway_port:$gateway_port,
          server_name:$ENV.SB_CONTROLLER_ONBOARDING_SERVER_NAME,
          allowed_entry_ipv4:$allowed_entry_ipv4,
          ssh_host_fingerprint:$fingerprint,
          credentials_preexisting:$credentials_preexisting,
          stage:$stage
        }
      ' > "$next" ||
     ! chmod 600 "$next" ||
     ! controller_landing_onboarding_journal_is_trusted "$next" ||
     ! sync_transaction_path "$next" ||
     ! mv -- "$next" "$journal" ||
     ! sync_transaction_path "$parent"; then
    rm -f -- "$next" || true
    return 1
  fi
  controller_landing_onboarding_journal_is_trusted "$journal"
}

controller_landing_onboarding_clear_journal() {
  [[ $# -eq 1 ]] || return 64
  local operation_id="$1" journal parent
  [[ "$operation_id" =~ ^[0-9a-f]{64}$ ]] || return 1
  controller_landing_onboarding_paths_are_safe || return 1
  journal="$CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE"
  controller_landing_onboarding_journal_is_trusted "$journal" || return 1
  jq -e --arg operation_id "$operation_id" '.operation_id == $operation_id' \
    "$journal" >/dev/null 2>&1 || return 1
  controller_landing_onboarding_remove_next_file || return 1
  parent="$(dirname -- "$journal")" || return 1
  rm -f -- "$journal" || return 1
  sync_transaction_path "$parent" || return 1
  [[ ! -e "$journal" && ! -L "$journal" ]]
}

controller_landing_onboarding_generate_id() {
  local purpose="$1" value
  [[ "$purpose" == operation || "$purpose" == bootstrap ]] || return 64
  value="$(openssl rand -hex 32 2>/dev/null)" || return 1
  [[ "$value" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$value"
}

controller_landing_onboarding_lock_file_is_trusted() {
  local lock="$CONTROLLER_LANDING_ONBOARDING_LOCK_FILE"
  controller_landing_onboarding_paths_are_safe || return 1
  controller_landing_onboarding_private_file_is_trusted "$lock" 0
}

controller_landing_onboarding_prepare_lock_file() {
  local lock="$CONTROLLER_LANDING_ONBOARDING_LOCK_FILE" parent
  controller_landing_onboarding_paths_are_safe || return 1
  parent="$(dirname -- "$lock")" || return 1
  ensure_controller_private_directory "$parent" || return 1
  if [[ ! -e "$lock" && ! -L "$lock" ]]; then
    (umask 077; set -o noclobber; : > "$lock") 2>/dev/null || return 1
    chmod 600 "$lock" || return 1
    sync_transaction_path "$lock" || return 1
    sync_transaction_path "$parent" || return 1
  fi
  controller_landing_onboarding_lock_file_is_trusted
}

with_controller_landing_onboarding_lock() {
  local callback="$1" rc lock="$CONTROLLER_LANDING_ONBOARDING_LOCK_FILE"
  shift
  declare -F "$callback" >/dev/null 2>&1 || return 1
  controller_landing_onboarding_prepare_lock_file || return 1
  exec 6<>"$lock" || return 1
  flock -x -w "$CONTROLLER_LANDING_ONBOARDING_LOCK_TIMEOUT" 6 || {
    exec 6>&-
    return 1
  }
  "$callback" "$@" 6>&- && rc=0 || rc=$?
  flock -u 6 2>/dev/null || true
  exec 6>&-
  return "$rc"
}
# ============================================================
# v5 单落地初始化向导编排（尚未接入角色路由或菜单）
# ============================================================
# 后续交互层读取这些结果；当前 dormant 模块由定向测试覆盖。
# shellcheck disable=SC2034

CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=not_started
CONTROLLER_LANDING_ONBOARDING_LAST_FINGERPRINT=""
CONTROLLER_LANDING_ONBOARDING_LAST_REMOTE_ROLLBACK=not_needed
CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=not_changed
CONTROLLER_LANDING_ONBOARDING_LAST_READINESS_STAGE=not_started
CONTROLLER_LANDING_ONBOARDING_LAST_DEPENDENCY_STATUS=not_checked
CONTROLLER_LANDING_ONBOARDING_LAST_SINGBOX_STATUS=not_checked

controller_landing_onboarding_reset_result() {
  CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=not_started
  CONTROLLER_LANDING_ONBOARDING_LAST_FINGERPRINT=""
  CONTROLLER_LANDING_ONBOARDING_LAST_REMOTE_ROLLBACK=not_needed
  CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=not_changed
  CONTROLLER_LANDING_ONBOARDING_LAST_READINESS_STAGE=not_started
  CONTROLLER_LANDING_ONBOARDING_LAST_DEPENDENCY_STATUS=not_checked
  CONTROLLER_LANDING_ONBOARDING_LAST_SINGBOX_STATUS=not_checked
}

controller_landing_onboarding_capture_readiness_result() {
  # 这些脱敏结果由后续交互层在统一入口返回后读取。
  # shellcheck disable=SC2034
  CONTROLLER_LANDING_ONBOARDING_LAST_READINESS_STAGE="$CONTROLLER_LANDING_READINESS_LAST_STAGE"
  CONTROLLER_LANDING_ONBOARDING_LAST_DEPENDENCY_STATUS="$CONTROLLER_LANDING_READINESS_LAST_DEPENDENCY_STATUS"
  CONTROLLER_LANDING_ONBOARDING_LAST_SINGBOX_STATUS="$CONTROLLER_LANDING_READINESS_LAST_SINGBOX_STATUS"
}

controller_landing_onboarding_clear_fingerprint_results() {
  # 完整主机指纹只在当前调用栈内传递，不作为统一入口的普通结果保留。
  # shellcheck disable=SC2034
  CONTROLLER_LANDING_READINESS_LAST_FINGERPRINT=""
  CONTROLLER_LANDING_ONBOARDING_LAST_FINGERPRINT=""
}

controller_landing_onboarding_inputs_are_valid() {
  [[ $# -eq 7 ]] || return 64
  local landing_id="$1" display_name="$2" address="$3" ssh_port="$4"
  local gateway_port="$5" server_name="$6" allowed_entry_ipv4="$7"
  landing_id_is_valid "$landing_id" || return 1
  controller_landing_display_name_is_valid "$display_name" || return 1
  controller_landing_address_is_valid "$address" || return 1
  landing_port_is_valid "$ssh_port" || return 1
  landing_port_is_valid "$gateway_port" || return 1
  ((10#$ssh_port != 10#$gateway_port)) || return 1
  controller_dns_name_is_valid "$server_name" || return 1
  is_public_ipv4 "$allowed_entry_ipv4"
}

controller_landing_onboarding_preflight() {
  [[ $# -eq 7 ]] || return 64
  local landing_id="$1" display_name="$2" address="$3" ssh_port="$4"
  local gateway_port="$5" server_name="$6" allowed_entry_ipv4="$7"
  controller_landing_onboarding_inputs_are_valid "$landing_id" "$display_name" \
    "$address" "$ssh_port" "$gateway_port" "$server_name" \
    "$allowed_entry_ipv4" || return 1
  validate_controller_state_file "$CONTROLLER_STATE_FILE" || return 1
  ssh_port=$((10#$ssh_port))
  jq -e --arg landing_id "$landing_id" --arg address "$address" \
    --argjson ssh_port "$ssh_port" '
      all(.landings[];
        .id != $landing_id and
        (.address != $address or .ssh_port != $ssh_port)
      )
    ' "$CONTROLLER_STATE_FILE" >/dev/null
}

controller_landing_onboarding_credentials_exist() {
  local landing_id="$1" directory manifest
  controller_landing_credentials_final_paths "$landing_id" || return 1
  directory="$CONTROLLER_LANDING_CREDENTIAL_DIRECTORY"
  manifest="$CONTROLLER_LANDING_CREDENTIAL_MANIFEST"
  [[ -e "$directory" || -L "$directory" || -e "$manifest" || -L "$manifest" ]]
}

controller_landing_onboarding_credential_artifacts_exist() (
  local landing_id="$1"
  local -a staging=()
  controller_landing_onboarding_credentials_exist "$landing_id" && return 0
  shopt -s nullglob
  staging=("$CONTROLLER_SECRET_DIR/.landing-credentials.${landing_id}."* \
    "$CONTROLLER_SECRET_DIR/.landing-manifest.${landing_id}."*)
  ((${#staging[@]} > 0))
)

controller_landing_onboarding_registration_state() {
  [[ $# -eq 6 ]] || return 64
  local landing_id="$1" display_name="$2" address="$3" ssh_port="$4"
  local fingerprint="$5" gateway_port="$6" credential_ref
  validate_controller_state_file "$CONTROLLER_STATE_FILE" || return 2
  if ! jq -e --arg landing_id "$landing_id" \
      'any(.landings[]; .id == $landing_id)' "$CONTROLLER_STATE_FILE" >/dev/null; then
    return 1
  fi
  credential_ref="$CONTROLLER_SECRET_DIR/landing-${landing_id}.json"
  ssh_port=$((10#$ssh_port))
  gateway_port=$((10#$gateway_port))
  jq -e --arg landing_id "$landing_id" --arg display_name "$display_name" \
    --arg address "$address" --argjson ssh_port "$ssh_port" \
    --arg fingerprint "$fingerprint" --argjson gateway_port "$gateway_port" \
    --arg credential_ref "$credential_ref" '
      any(.landings[];
        .id == $landing_id and
        .display_name == $display_name and
        .address == $address and
        .ssh_port == $ssh_port and
        .ssh_host_fingerprint == $fingerprint and
        .gateway_port == $gateway_port and
        .credential_ref == $credential_ref
      )
    ' "$CONTROLLER_STATE_FILE" >/dev/null || return 2
}

controller_confirm_landing_fingerprint() {
  [[ $# -eq 3 ]] || return 64
  local address="$1" ssh_port="$2" fingerprint="$3" choice
  printf '\n即将连接的落地机：%s:%s\n' "$address" "$ssh_port"
  printf 'Ed25519 主机指纹：%s\n' "$fingerprint"
  printf '请通过服务商控制台或可信渠道核对该指纹。\n'
  read_menu_choice '确认指纹完全一致并继续？[y/N]：' 'y,Y,n,N' N \
    '请输入 y、n 或直接回车' || return 1
  choice="$PROMPT_VALUE"
  case "$choice" in
    y|Y) return 0 ;;
    *) return 2 ;;
  esac
}

controller_landing_onboarding_cleanup_credentials() {
  local landing_id="$1" server_name="$2" credentials_preexisting="$3"
  if [[ "$credentials_preexisting" == true ]]; then
    CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_preexisting
    return 0
  fi
  if ! controller_landing_onboarding_credential_artifacts_exist "$landing_id"; then
    CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=not_created
    return 0
  fi
  if controller_remove_unregistered_landing_credentials "$landing_id" "$server_name"; then
    CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=removed
    return 0
  fi
  CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=cleanup_failed
  return 1
}

controller_landing_onboarding_finalize_local_cleanup() {
  [[ $# -eq 6 ]] || return 64
  local operation_id="$1" landing_id="$2" server_name="$3"
  local credentials_preexisting="$4" success_stage="$5" failure_stage="$6"
  if ! controller_landing_onboarding_cleanup_credentials "$landing_id" "$server_name" \
      "$credentials_preexisting"; then
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE="$failure_stage"
    return 1
  fi
  if ! controller_landing_onboarding_clear_journal "$operation_id"; then
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE="$failure_stage"
    return 1
  fi
  CONTROLLER_LANDING_ONBOARDING_LAST_STAGE="$success_stage"
}

controller_landing_onboarding_apply_and_complete() {
  [[ $# -eq 12 ]] || return 64
  local operation_id="$1" bootstrap_id="$2" landing_id="$3" display_name="$4"
  local address="$5" ssh_port="$6" gateway_port="$7" server_name="$8"
  local allowed_entry_ipv4="$9" fingerprint="${10}"
  local credentials_preexisting="${11}" apply_stage="${12}"
  CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=registered
  if ! controller_apply_landing "$landing_id" "$allowed_entry_ipv4"; then
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=registered_sync_pending
    return 1
  fi
  if ! controller_landing_onboarding_write_journal completed "$operation_id" \
      "$bootstrap_id" "$landing_id" "$display_name" "$address" "$ssh_port" \
      "$gateway_port" "$server_name" "$allowed_entry_ipv4" "$fingerprint" \
      "$credentials_preexisting"; then
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=completed_recovery_required
    return 1
  fi
  if ! controller_landing_onboarding_clear_journal "$operation_id"; then
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=completed_recovery_required
    return 1
  fi
  CONTROLLER_LANDING_ONBOARDING_LAST_STAGE="$apply_stage"
}

controller_onboard_landing_unlocked() {
  [[ $# -eq 7 || $# -eq 8 ]] || return 64
  local landing_id="$1" display_name="$2" address="$3" ssh_port="$4"
  local gateway_port="$5" server_name="$6" allowed_entry_ipv4="$7"
  local confirmed_fingerprint="${8:-}" fingerprint confirmation_rc
  local credentials_preexisting=false bootstrap_id=""
  local operation_id="" registration_state bootstrap_rc

  if ! controller_landing_onboarding_preflight "$landing_id" "$display_name" \
      "$address" "$ssh_port" "$gateway_port" "$server_name" \
      "$allowed_entry_ipv4"; then
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=preflight_failed
    return 1
  fi
  if [[ -e "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE" ||
        -L "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE" ]]; then
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=pending_recovery
    return 1
  fi
  if ! controller_landing_onboarding_remove_next_file; then
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=journal_invalid
    return 1
  fi

  if [[ -n "$confirmed_fingerprint" ]]; then
    if [[ ! "$confirmed_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]]; then
      CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=readiness_result_invalid
      return 1
    fi
    fingerprint="$confirmed_fingerprint"
  else
    if ! fingerprint="$(controller_landing_discover_fingerprint "$address" "$ssh_port")"; then
      CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=fingerprint_discovery_failed
      return 1
    fi
    [[ "$fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || {
      CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=fingerprint_discovery_failed
      return 1
    }
    CONTROLLER_LANDING_ONBOARDING_LAST_FINGERPRINT="$fingerprint"
    if controller_confirm_landing_fingerprint "$address" "$ssh_port" "$fingerprint"; then
      confirmation_rc=0
    else
      confirmation_rc=$?
    fi
    if ((confirmation_rc != 0)); then
      if ((confirmation_rc == 2)); then
        CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=cancelled
        return 2
      fi
      CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=fingerprint_confirmation_failed
      return 1
    fi
  fi
  CONTROLLER_LANDING_ONBOARDING_LAST_FINGERPRINT="$fingerprint"

  if controller_landing_onboarding_credentials_exist "$landing_id"; then
    credentials_preexisting=true
  fi
  operation_id="$(controller_landing_onboarding_generate_id operation)" || {
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=journal_unavailable
    return 1
  }
  bootstrap_id="$(controller_landing_onboarding_generate_id bootstrap)" || {
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=journal_unavailable
    return 1
  }
  if ! controller_landing_onboarding_write_journal credentials_pending "$operation_id" \
      "$bootstrap_id" "$landing_id" "$display_name" "$address" "$ssh_port" \
      "$gateway_port" "$server_name" "$allowed_entry_ipv4" "$fingerprint" \
      "$credentials_preexisting"; then
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=journal_unavailable
    return 1
  fi
  if ! controller_initialize_landing_credentials "$landing_id" "$server_name" \
      >/dev/null; then
    if ! controller_landing_onboarding_write_journal local_aborted "$operation_id" \
        "$bootstrap_id" "$landing_id" "$display_name" "$address" "$ssh_port" \
        "$gateway_port" "$server_name" "$allowed_entry_ipv4" "$fingerprint" \
        "$credentials_preexisting"; then
      CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_for_recovery
      CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=credentials_failed_recovery_required
      return 1
    fi
    controller_landing_onboarding_finalize_local_cleanup "$operation_id" "$landing_id" \
      "$server_name" "$credentials_preexisting" credentials_failed \
      credentials_failed_recovery_required || return 1
    return 1
  fi
  if [[ "$credentials_preexisting" == true ]]; then
    CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_preexisting
  else
    CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=created
  fi

  if ! controller_landing_onboarding_write_journal bootstrap_pending "$operation_id" \
      "$bootstrap_id" "$landing_id" "$display_name" "$address" "$ssh_port" \
      "$gateway_port" "$server_name" "$allowed_entry_ipv4" "$fingerprint" \
      "$credentials_preexisting"; then
    if controller_landing_onboarding_write_journal local_aborted "$operation_id" \
        "$bootstrap_id" "$landing_id" "$display_name" "$address" "$ssh_port" \
        "$gateway_port" "$server_name" "$allowed_entry_ipv4" "$fingerprint" \
        "$credentials_preexisting"; then
      controller_landing_onboarding_finalize_local_cleanup "$operation_id" "$landing_id" \
        "$server_name" "$credentials_preexisting" journal_update_failed \
        journal_recovery_required || return 1
    else
      CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_for_recovery
      CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=journal_recovery_required
    fi
    return 1
  fi

  CONTROLLER_LANDING_BOOTSTRAP_LAST_ID=""
  CONTROLLER_LANDING_BOOTSTRAP_LAST_ROLLBACK=not_started
  if controller_bootstrap_landing_channel "$landing_id" "$address" "$ssh_port" \
      "$fingerprint" "$allowed_entry_ipv4" "$bootstrap_id"; then
    bootstrap_rc=0
  else
    bootstrap_rc=$?
  fi
  if [[ "${CONTROLLER_LANDING_BOOTSTRAP_LAST_ID:-}" != "$bootstrap_id" ]]; then
    CONTROLLER_LANDING_ONBOARDING_LAST_REMOTE_ROLLBACK=not_attempted
    CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_for_recovery
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=bootstrap_state_unknown
    return 1
  fi
  if ((bootstrap_rc != 0)); then
    if [[ "${CONTROLLER_LANDING_BOOTSTRAP_LAST_ROLLBACK:-failed}" == completed ]]; then
      CONTROLLER_LANDING_ONBOARDING_LAST_REMOTE_ROLLBACK=completed
      if ! controller_landing_onboarding_write_journal remote_rolled_back "$operation_id" \
          "$bootstrap_id" "$landing_id" "$display_name" "$address" "$ssh_port" \
          "$gateway_port" "$server_name" "$allowed_entry_ipv4" "$fingerprint" \
          "$credentials_preexisting"; then
        CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_for_recovery
        CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=bootstrap_failed_recovery_required
        return 1
      fi
      controller_landing_onboarding_finalize_local_cleanup "$operation_id" "$landing_id" \
        "$server_name" "$credentials_preexisting" bootstrap_failed_rolled_back \
        bootstrap_failed_recovery_required || return 1
    else
      CONTROLLER_LANDING_ONBOARDING_LAST_REMOTE_ROLLBACK=failed
      CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_for_recovery
      CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=bootstrap_failed_recovery_required
    fi
    return 1
  fi
  if ! controller_landing_onboarding_write_journal registration_pending "$operation_id" \
      "$bootstrap_id" "$landing_id" "$display_name" "$address" "$ssh_port" \
      "$gateway_port" "$server_name" "$allowed_entry_ipv4" "$fingerprint" \
      "$credentials_preexisting"; then
    CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_for_recovery
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=bootstrap_recovery_required
    return 1
  fi

  if controller_register_landing "$landing_id" "$display_name" "$address" \
      "$ssh_port" "$fingerprint" "$gateway_port"; then
    if controller_landing_onboarding_registration_state "$landing_id" "$display_name" \
        "$address" "$ssh_port" "$fingerprint" "$gateway_port"; then
      registration_state=registered
    else
      registration_state=unknown
    fi
  else
    if controller_landing_onboarding_registration_state "$landing_id" "$display_name" \
        "$address" "$ssh_port" "$fingerprint" "$gateway_port"; then
      registration_state=registered
    else
      case $? in
        1) registration_state=unregistered ;;
        *) registration_state=unknown ;;
      esac
    fi
  fi

  case "$registration_state" in
    registered)
      if ! controller_landing_onboarding_write_journal apply_pending "$operation_id" \
          "$bootstrap_id" "$landing_id" "$display_name" "$address" "$ssh_port" \
          "$gateway_port" "$server_name" "$allowed_entry_ipv4" "$fingerprint" \
          "$credentials_preexisting"; then
        CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=registered
        CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=registered_sync_pending
        return 1
      fi
      ;;
    unregistered)
      if controller_rollback_landing_bootstrap "$landing_id" "$address" "$ssh_port" \
          "$fingerprint" "$allowed_entry_ipv4" "$bootstrap_id"; then
        CONTROLLER_LANDING_ONBOARDING_LAST_REMOTE_ROLLBACK=completed
        if ! controller_landing_onboarding_write_journal remote_rolled_back "$operation_id" \
            "$bootstrap_id" "$landing_id" "$display_name" "$address" "$ssh_port" \
            "$gateway_port" "$server_name" "$allowed_entry_ipv4" "$fingerprint" \
            "$credentials_preexisting"; then
          CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_for_recovery
          CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=registration_failed_recovery_required
          return 1
        fi
        controller_landing_onboarding_finalize_local_cleanup "$operation_id" "$landing_id" \
          "$server_name" "$credentials_preexisting" registration_failed_rolled_back \
          registration_failed_recovery_required || return 1
      else
        CONTROLLER_LANDING_ONBOARDING_LAST_REMOTE_ROLLBACK=failed
        CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_for_recovery
        CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=registration_failed_recovery_required
      fi
      return 1
      ;;
    *)
      CONTROLLER_LANDING_ONBOARDING_LAST_REMOTE_ROLLBACK=not_attempted
      CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_for_recovery
      CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=registration_state_unknown
      return 1
      ;;
  esac

  controller_landing_onboarding_apply_and_complete "$operation_id" "$bootstrap_id" \
    "$landing_id" "$display_name" "$address" "$ssh_port" "$gateway_port" \
    "$server_name" "$allowed_entry_ipv4" "$fingerprint" "$credentials_preexisting" \
    completed
}

controller_prepare_and_onboard_landing_unlocked() {
  [[ $# -eq 7 ]] || return 64
  local landing_id="$1" display_name="$2" address="$3" ssh_port="$4"
  local gateway_port="$5" server_name="$6" allowed_entry_ipv4="$7"
  local readiness_rc fingerprint onboarding_rc

  if ! controller_landing_onboarding_preflight "$landing_id" "$display_name" \
      "$address" "$ssh_port" "$gateway_port" "$server_name" \
      "$allowed_entry_ipv4"; then
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=preflight_failed
    return 1
  fi

  if controller_prepare_landing_readiness "$address" "$ssh_port" "$landing_id"; then
    readiness_rc=0
  else
    readiness_rc=$?
  fi
  controller_landing_onboarding_capture_readiness_result
  fingerprint="$CONTROLLER_LANDING_READINESS_LAST_FINGERPRINT"
  CONTROLLER_LANDING_READINESS_LAST_FINGERPRINT=""

  if ((readiness_rc != 0)); then
    CONTROLLER_LANDING_ONBOARDING_LAST_FINGERPRINT=""
    if ((readiness_rc == 2)); then
      CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=readiness_cancelled
      return 2
    fi
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=readiness_failed
    return 1
  fi
  if [[ "$CONTROLLER_LANDING_ONBOARDING_LAST_READINESS_STAGE" != ready ||
        ! "$CONTROLLER_LANDING_ONBOARDING_LAST_DEPENDENCY_STATUS" =~ ^(ready|repaired)$ ||
        ! "$CONTROLLER_LANDING_ONBOARDING_LAST_SINGBOX_STATUS" =~ ^(ready|installed)$ ||
        ! "$fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]]; then
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=readiness_result_invalid
    CONTROLLER_LANDING_ONBOARDING_LAST_FINGERPRINT=""
    return 1
  fi

  if controller_onboard_landing_unlocked "$landing_id" "$display_name" "$address" \
      "$ssh_port" "$gateway_port" "$server_name" "$allowed_entry_ipv4" \
      "$fingerprint"; then
    onboarding_rc=0
  else
    onboarding_rc=$?
  fi
  CONTROLLER_LANDING_ONBOARDING_LAST_FINGERPRINT=""
  return "$onboarding_rc"
}

controller_recover_landing_onboarding_unlocked() {
  local journal="$CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE"
  local operation_id bootstrap_id landing_id display_name address ssh_port gateway_port
  local server_name allowed_entry_ipv4 fingerprint credentials_preexisting stage
  local registration_state registration_rc
  if [[ ! -e "$journal" && ! -L "$journal" ]]; then
    if ! controller_landing_onboarding_remove_next_file; then
      CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=journal_invalid
      return 1
    fi
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=recovery_no_pending
    return 0
  fi
  if ! controller_landing_onboarding_journal_is_trusted "$journal" ||
     ! controller_landing_onboarding_remove_next_file; then
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=journal_invalid
    return 1
  fi
  IFS=$'\t' read -r operation_id bootstrap_id landing_id display_name address \
    ssh_port gateway_port server_name allowed_entry_ipv4 fingerprint \
    credentials_preexisting stage < <(
      jq -r '[
        .operation_id, .bootstrap_id, .landing_id, .display_name, .address,
        .ssh_port, .gateway_port, .server_name, .allowed_entry_ipv4,
        .ssh_host_fingerprint, .credentials_preexisting, .stage
      ] | @tsv' "$journal"
    ) || {
      CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=journal_invalid
      return 1
    }
  # 恢复调用者在函数返回后读取该公共结果。
  # shellcheck disable=SC2034
  CONTROLLER_LANDING_ONBOARDING_LAST_FINGERPRINT="$fingerprint"
  if controller_landing_onboarding_registration_state "$landing_id" "$display_name" \
      "$address" "$ssh_port" "$fingerprint" "$gateway_port"; then
    registration_state=registered
  else
    registration_rc=$?
    case "$registration_rc" in
      1) registration_state=unregistered ;;
      *) registration_state=unknown ;;
    esac
  fi

  case "$stage" in
    credentials_pending)
      [[ "$registration_state" == unregistered ]] || {
        CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=registration_state_unknown
        return 1
      }
      if ! controller_landing_onboarding_write_journal local_aborted "$operation_id" \
          "$bootstrap_id" "$landing_id" "$display_name" "$address" "$ssh_port" \
          "$gateway_port" "$server_name" "$allowed_entry_ipv4" "$fingerprint" \
          "$credentials_preexisting"; then
        CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=journal_recovery_required
        return 1
      fi
      controller_landing_onboarding_finalize_local_cleanup "$operation_id" "$landing_id" \
        "$server_name" "$credentials_preexisting" recovery_local_cleaned \
        journal_recovery_required
      ;;
    local_aborted)
      [[ "$registration_state" == unregistered ]] || {
        CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=registration_state_unknown
        return 1
      }
      controller_landing_onboarding_finalize_local_cleanup "$operation_id" "$landing_id" \
        "$server_name" "$credentials_preexisting" recovery_local_cleaned \
        journal_recovery_required
      ;;
    bootstrap_pending)
      [[ "$registration_state" == unregistered ]] || {
        CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=registration_state_unknown
        return 1
      }
      if ! controller_rollback_landing_bootstrap "$landing_id" "$address" "$ssh_port" \
          "$fingerprint" "$allowed_entry_ipv4" "$bootstrap_id"; then
        CONTROLLER_LANDING_ONBOARDING_LAST_REMOTE_ROLLBACK=failed
        CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_for_recovery
        CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=bootstrap_failed_recovery_required
        return 1
      fi
      CONTROLLER_LANDING_ONBOARDING_LAST_REMOTE_ROLLBACK=completed
      if ! controller_landing_onboarding_write_journal remote_rolled_back "$operation_id" \
          "$bootstrap_id" "$landing_id" "$display_name" "$address" "$ssh_port" \
          "$gateway_port" "$server_name" "$allowed_entry_ipv4" "$fingerprint" \
          "$credentials_preexisting"; then
        CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_for_recovery
        CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=bootstrap_failed_recovery_required
        return 1
      fi
      controller_landing_onboarding_finalize_local_cleanup "$operation_id" "$landing_id" \
        "$server_name" "$credentials_preexisting" recovery_remote_rolled_back \
        bootstrap_failed_recovery_required
      ;;
    registration_pending)
      case "$registration_state" in
        registered)
          if ! controller_landing_onboarding_write_journal apply_pending "$operation_id" \
              "$bootstrap_id" "$landing_id" "$display_name" "$address" "$ssh_port" \
              "$gateway_port" "$server_name" "$allowed_entry_ipv4" "$fingerprint" \
              "$credentials_preexisting"; then
            CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=registered
            CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=registered_sync_pending
            return 1
          fi
          controller_landing_onboarding_apply_and_complete "$operation_id" "$bootstrap_id" \
            "$landing_id" "$display_name" "$address" "$ssh_port" "$gateway_port" \
            "$server_name" "$allowed_entry_ipv4" "$fingerprint" \
            "$credentials_preexisting" completed
          ;;
        unregistered)
          if ! controller_rollback_landing_bootstrap "$landing_id" "$address" "$ssh_port" \
              "$fingerprint" "$allowed_entry_ipv4" "$bootstrap_id"; then
            CONTROLLER_LANDING_ONBOARDING_LAST_REMOTE_ROLLBACK=failed
            CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_for_recovery
            CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=registration_failed_recovery_required
            return 1
          fi
          CONTROLLER_LANDING_ONBOARDING_LAST_REMOTE_ROLLBACK=completed
          if ! controller_landing_onboarding_write_journal remote_rolled_back \
              "$operation_id" "$bootstrap_id" "$landing_id" "$display_name" \
              "$address" "$ssh_port" "$gateway_port" "$server_name" \
              "$allowed_entry_ipv4" "$fingerprint" "$credentials_preexisting"; then
            CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_for_recovery
            CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=registration_failed_recovery_required
            return 1
          fi
          controller_landing_onboarding_finalize_local_cleanup "$operation_id" "$landing_id" \
            "$server_name" "$credentials_preexisting" recovery_remote_rolled_back \
            registration_failed_recovery_required
          ;;
        *)
          CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_for_recovery
          CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=registration_state_unknown
          return 1
          ;;
      esac
      ;;
    apply_pending)
      [[ "$registration_state" == registered ]] || {
        CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_for_recovery
        CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=registration_state_unknown
        return 1
      }
      controller_landing_onboarding_apply_and_complete "$operation_id" "$bootstrap_id" \
        "$landing_id" "$display_name" "$address" "$ssh_port" "$gateway_port" \
        "$server_name" "$allowed_entry_ipv4" "$fingerprint" \
        "$credentials_preexisting" completed
      ;;
    remote_rolled_back)
      [[ "$registration_state" == unregistered ]] || {
        CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_for_recovery
        CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=registration_state_unknown
        return 1
      }
      # 恢复调用者在函数返回后读取该公共结果。
      # shellcheck disable=SC2034
      CONTROLLER_LANDING_ONBOARDING_LAST_REMOTE_ROLLBACK=completed
      controller_landing_onboarding_finalize_local_cleanup "$operation_id" "$landing_id" \
        "$server_name" "$credentials_preexisting" recovery_remote_rolled_back \
        journal_recovery_required
      ;;
    completed)
      [[ "$registration_state" == registered ]] || {
        CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_for_recovery
        CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=registration_state_unknown
        return 1
      }
      # 恢复调用者在函数返回后读取该公共结果。
      # shellcheck disable=SC2034
      CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=registered
      if ! controller_landing_onboarding_clear_journal "$operation_id"; then
        CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=completed_recovery_required
        return 1
      fi
      CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=completed
      ;;
    *)
      CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=journal_invalid
      return 1
      ;;
  esac
}

# 结果变量是公共调用约定，由后续交互层在函数返回后读取。
# shellcheck disable=SC2034
controller_onboard_landing() {
  [[ $# -eq 7 ]] || return 64
  local rc
  controller_landing_onboarding_reset_result
  if with_controller_landing_onboarding_lock controller_onboard_landing_unlocked "$@"; then
    return 0
  else
    rc=$?
  fi
  if [[ "$CONTROLLER_LANDING_ONBOARDING_LAST_STAGE" == not_started ]]; then
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=journal_unavailable
  fi
  return "$rc"
}

# 未来交互层只调用该统一入口；完整指纹不会作为普通结果保留。
# shellcheck disable=SC2034
controller_prepare_and_onboard_landing() {
  local rc
  controller_landing_onboarding_reset_result
  controller_landing_onboarding_clear_fingerprint_results
  [[ $# -eq 7 ]] || return 64
  if with_controller_landing_onboarding_lock \
      controller_prepare_and_onboard_landing_unlocked "$@"; then
    rc=0
  else
    rc=$?
  fi
  controller_landing_onboarding_clear_fingerprint_results
  if [[ "$CONTROLLER_LANDING_ONBOARDING_LAST_STAGE" == not_started ]]; then
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=journal_unavailable
    return 1
  fi
  return "$rc"
}

# shellcheck disable=SC2034
controller_recover_landing_onboarding() {
  [[ $# -eq 0 ]] || return 64
  local rc
  controller_landing_onboarding_reset_result
  if with_controller_landing_onboarding_lock \
      controller_recover_landing_onboarding_unlocked; then
    return 0
  else
    rc=$?
  fi
  if [[ "$CONTROLLER_LANDING_ONBOARDING_LAST_STAGE" == not_started ]]; then
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=journal_unavailable
  fi
  return "$rc"
}
# ============================================================
# v5 落地 apply 启动恢复门禁（尚未接入菜单或正式服务器）
# ============================================================

LANDING_STARTUP_RECOVERY_UNIT_NAME=sb-user-manager-landing-recovery.service
LANDING_STARTUP_RECOVERY_UNIT_PATH=/etc/systemd/system/sb-user-manager-landing-recovery.service
LANDING_STARTUP_RECOVERY_DROPIN_DIRECTORY=/etc/systemd/system/sing-box.service.d
LANDING_STARTUP_RECOVERY_DROPIN_PATH=/etc/systemd/system/sing-box.service.d/10-sb-user-manager-landing-recovery.conf
LANDING_STARTUP_RECOVERY_MODE_ARGUMENT=--recover-startup

landing_startup_recovery_paths_are_safe() {
  [[ "$LANDING_STARTUP_RECOVERY_UNIT_NAME" == sb-user-manager-landing-recovery.service &&
     "$LANDING_STARTUP_RECOVERY_UNIT_PATH" == /etc/systemd/system/sb-user-manager-landing-recovery.service &&
     "$LANDING_STARTUP_RECOVERY_DROPIN_DIRECTORY" == /etc/systemd/system/sing-box.service.d &&
     "$LANDING_STARTUP_RECOVERY_DROPIN_PATH" == /etc/systemd/system/sing-box.service.d/10-sb-user-manager-landing-recovery.conf &&
     "$LANDING_STARTUP_RECOVERY_MODE_ARGUMENT" == --recover-startup &&
     "$LANDING_AGENT_HELPER_PATH" == /usr/local/libexec/sb-user-manager-landing-apply &&
     "$LANDING_SINGBOX_SERVICE" == sing-box ]]
}

landing_startup_recovery_unit_content() {
  cat <<EOF
[Unit]
Description=Recover sb-user-manager landing apply transaction before sing-box
After=local-fs.target nftables.service
Before=sing-box.service

[Service]
Type=oneshot
ExecStart=${LANDING_AGENT_HELPER_PATH} ${LANDING_STARTUP_RECOVERY_MODE_ARGUMENT}
RemainAfterExit=yes
User=root
Group=root
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
StandardInput=null
StandardOutput=null
EOF
}

landing_startup_recovery_dropin_content() {
  cat <<EOF
[Unit]
Requires=${LANDING_STARTUP_RECOVERY_UNIT_NAME}
After=${LANDING_STARTUP_RECOVERY_UNIT_NAME}
EOF
}

landing_startup_render_recovery_unit() {
  local output="$1"
  landing_startup_recovery_paths_are_safe || return 1
  landing_startup_recovery_unit_content > "$output" || return 1
  chmod 600 "$output" || return 1
}

landing_startup_render_singbox_dropin() {
  local output="$1"
  landing_startup_recovery_paths_are_safe || return 1
  landing_startup_recovery_dropin_content > "$output" || return 1
  chmod 600 "$output" || return 1
}

landing_startup_recovery_gate_files_are_valid() {
  local unit dropin root_uid root_gid logical path
  landing_startup_recovery_paths_are_safe || return 1
  for logical in /etc /etc/systemd /etc/systemd/system "$LANDING_STARTUP_RECOVERY_DROPIN_DIRECTORY"; do
    path="$(landing_channel_path "$logical")" || return 1
    landing_channel_system_directory_is_safe "$path" || return 1
  done
  unit="$(landing_channel_path "$LANDING_STARTUP_RECOVERY_UNIT_PATH")" || return 1
  dropin="$(landing_channel_path "$LANDING_STARTUP_RECOVERY_DROPIN_PATH")" || return 1
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  landing_channel_file_matches "$unit" 644 "$root_uid" "$root_gid" || return 1
  landing_channel_file_matches "$dropin" 644 "$root_uid" "$root_gid" || return 1
  [[ "$(<"$unit")" == "$(landing_startup_recovery_unit_content)" ]] || return 1
  [[ "$(<"$dropin")" == "$(landing_startup_recovery_dropin_content)" ]]
}

landing_startup_recovery_gate_files_are_absent() {
  local unit dropin
  unit="$(landing_channel_path "$LANDING_STARTUP_RECOVERY_UNIT_PATH")" || return 1
  dropin="$(landing_channel_path "$LANDING_STARTUP_RECOVERY_DROPIN_PATH")" || return 1
  [[ ! -e "$unit" && ! -L "$unit" && ! -e "$dropin" && ! -L "$dropin" ]]
}

landing_startup_recovery_gate_upgrade_source_is_valid() {
  landing_startup_recovery_gate_files_are_valid && return 0
  landing_startup_recovery_gate_files_are_absent
}

landing_startup_root_directory_is_safe() {
  local path="$1" allow_group_write="${2:-false}" allow_sticky_world="${3:-false}"
  local owner group mode expected_owner expected_group
  [[ "$allow_group_write" == true || "$allow_group_write" == false ]] || return 1
  [[ "$allow_sticky_world" == true || "$allow_sticky_world" == false ]] || return 1
  [[ -d "$path" && ! -L "$path" ]] || return 1
  owner="$(manager_file_uid "$path")" || return 1
  group="$(manager_file_gid "$path")" || return 1
  expected_owner="$(landing_channel_expected_root_uid)" || return 1
  expected_group="$(landing_channel_expected_root_gid)" || return 1
  # BSD `stat -f %Lp` omits setuid/setgid/sticky bits.  The startup gate must
  # see the complete mode because a world-writable lock parent is trusted only
  # when its sticky bit is present.
  mode="$(stat -c '%a' -- "$path" 2>/dev/null || stat -f '%Mp%Lp' "$path" 2>/dev/null)" || return 1
  [[ "$owner" == "$expected_owner" && "$group" == "$expected_group" &&
     "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 06000) == 0 && (8#$mode & 0700) == 0700 )) || return 1
  [[ "$allow_group_write" == true ]] || (( (8#$mode & 0020) == 0 ))
  if [[ "$allow_sticky_world" == true ]]; then
    (( (8#$mode & 0002) == 0 || (8#$mode & 01000) == 01000 ))
  else
    (( (8#$mode & 01002) == 0 ))
  fi
}

landing_startup_receipt_lock_parent_chain_is_safe() {
  local lock_parent lock_root run_root root_uid root_gid
  lock_parent="$(dirname -- "$LANDING_RECEIPT_LOCK_FILE")" || return 1
  lock_root="$(dirname -- "$lock_parent")" || return 1
  run_root="$(dirname -- "$lock_root")" || return 1
  [[ "$run_root" != / && "$lock_root" != / && "$lock_parent" != / ]] || return 1
  landing_startup_root_directory_is_safe "$run_root" false false || return 1
  landing_startup_root_directory_is_safe "$lock_root" true true || return 1
  if [[ -e "$lock_parent" || -L "$lock_parent" ]]; then
    root_uid="$(landing_channel_expected_root_uid)" || return 1
    root_gid="$(landing_channel_expected_root_gid)" || return 1
    landing_channel_directory_matches "$lock_parent" 700 "$root_uid" "$root_gid" || return 1
  fi
}

landing_startup_systemctl() {
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]]; then
    systemctl "$@"
  else
    /usr/bin/systemctl "$@"
  fi
}

landing_startup_recovery_daemon_reload() {
  landing_startup_systemctl daemon-reload >/dev/null 2>&1
}

landing_startup_recovery_ensure_active() {
  landing_startup_recovery_gate_files_are_valid || return 1
  landing_startup_systemctl start "$LANDING_STARTUP_RECOVERY_UNIT_NAME" >/dev/null 2>&1 || return 1
  landing_startup_systemctl is-active --quiet "$LANDING_STARTUP_RECOVERY_UNIT_NAME" >/dev/null 2>&1
}

landing_startup_recovery_stop() {
  local state
  state="$(landing_startup_systemctl is-active "$LANDING_STARTUP_RECOVERY_UNIT_NAME" 2>/dev/null || true)"
  case "$state" in
    inactive|failed|unknown) return 0 ;;
    active) ;;
    *) return 1 ;;
  esac
  landing_startup_systemctl stop "$LANDING_STARTUP_RECOVERY_UNIT_NAME" >/dev/null 2>&1 || return 1
  state="$(landing_startup_systemctl is-active "$LANDING_STARTUP_RECOVERY_UNIT_NAME" 2>/dev/null || true)"
  [[ "$state" == inactive || "$state" == failed || "$state" == unknown ]]
}

landing_startup_singbox_is_stopped() {
  local state
  state="$(landing_startup_systemctl is-active "$LANDING_SINGBOX_SERVICE" 2>/dev/null || true)"
  [[ "$state" == inactive || "$state" == failed ]]
}

landing_startup_singbox_is_active() {
  landing_startup_systemctl is-active --quiet "$LANDING_SINGBOX_SERVICE" >/dev/null 2>&1
}

landing_startup_root_executable_is_safe() {
  local path="$1" owner group mode expected_owner expected_group logical parent
  for logical in /usr /usr/local /usr/local/bin; do
    parent="$(landing_managed_path "$logical")" || return 1
    landing_channel_system_directory_is_safe "$parent" || return 1
  done
  [[ -f "$path" && ! -L "$path" && -x "$path" ]] || return 1
  owner="$(manager_file_uid "$path")" || return 1
  group="$(manager_file_gid "$path")" || return 1
  expected_owner="$(landing_apply_expected_uid)" || return 1
  expected_group="$(landing_channel_expected_root_gid)" || return 1
  mode="$(manager_file_mode "$path")" || return 1
  [[ "$owner" == "$expected_owner" && "$group" == "$expected_group" &&
     "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 07000) == 0 && (8#$mode & 0100) == 0100 && (8#$mode & 0022) == 0 ))
}

landing_startup_parse_nft_file() {
  local path="$1" parsed allowed_entry_ipv4 port
  landing_apply_transaction_file_is_safe "$path" || return 1
  parsed="$(SB_LANDING_EXPECTED_NFT_FAMILY="$LANDING_NFTABLES_FAMILY" \
    SB_LANDING_EXPECTED_NFT_TABLE="$LANDING_NFTABLES_TABLE" \
    SB_LANDING_EXPECTED_NFT_CHAIN="$LANDING_NFTABLES_CHAIN" \
    python3 -I -c '
import os
import re
import sys

family = re.escape(os.environ["SB_LANDING_EXPECTED_NFT_FAMILY"])
table = re.escape(os.environ["SB_LANDING_EXPECTED_NFT_TABLE"])
chain = re.escape(os.environ["SB_LANDING_EXPECTED_NFT_CHAIN"])
with open(sys.argv[1], "r", encoding="utf-8") as stream:
    lines = stream.read().splitlines()

# `jq -r` appends its own record terminator.  Releases produced before this
# gate also rendered one explicit final newline, so their otherwise canonical
# five-line rules file has exactly one trailing empty item after splitlines().
# Accept that single historical terminator, but keep rejecting any other blank
# or additional line.
if len(lines) == 6 and lines[-1] == "":
    lines.pop()
if len(lines) != 5:
    raise SystemExit(1)
expected = [
    rf"add table {family} {table}",
    rf"flush table {family} {table}",
    rf"add chain {family} {table} {chain} \{{ type filter hook input priority -10; policy accept; \}}",
]
if any(re.fullmatch(pattern, line) is None for pattern, line in zip(expected, lines[:3])):
    raise SystemExit(1)
accept = re.fullmatch(
    rf"add rule {family} {table} {chain} ip saddr ([0-9]{{1,3}}(?:\.[0-9]{{1,3}}){{3}}) tcp dport ([0-9]{{1,5}}) accept",
    lines[3],
)
if accept is None:
    raise SystemExit(1)
address, port = accept.groups()
if re.fullmatch(rf"add rule {family} {table} {chain} tcp dport {re.escape(port)} drop", lines[4]) is None:
    raise SystemExit(1)
print(f"{address}\t{port}")
' "$path")" || return 1
  IFS=$'\t' read -r allowed_entry_ipv4 port <<<"$parsed" || return 1
  is_public_ipv4 "$allowed_entry_ipv4" || return 1
  landing_port_is_valid "$port" || return 1
  printf '%s\t%s\n' "$allowed_entry_ipv4" "$port"
}

landing_startup_nft_file_matches_values() {
  local path="$1" expected_ipv4="$2" expected_port="$3" parsed_ipv4 parsed_port
  IFS=$'\t' read -r parsed_ipv4 parsed_port < <(landing_startup_parse_nft_file "$path") || return 1
  [[ "$parsed_ipv4" == "$expected_ipv4" && "$parsed_port" == "$expected_port" ]]
}

landing_startup_live_nft_matches_values() {
  local allowed_entry_ipv4="$1" port="$2" tables current
  is_ipv4_address "$allowed_entry_ipv4" || return 1
  landing_port_is_valid "$port" || return 1
  tables="$(nft -nn list tables 2>/dev/null)" || return 1
  grep -Fxq "table $LANDING_NFTABLES_FAMILY $LANDING_NFTABLES_TABLE" <<<"$tables" || return 1
  current="$(nft -nn list table "$LANDING_NFTABLES_FAMILY" "$LANDING_NFTABLES_TABLE" 2>/dev/null)" || return 1
  SB_LANDING_EXPECTED_ENTRY_IPV4="$allowed_entry_ipv4" \
  SB_LANDING_EXPECTED_PORT="$port" \
  SB_LANDING_EXPECTED_NFT_FAMILY="$LANDING_NFTABLES_FAMILY" \
  SB_LANDING_EXPECTED_NFT_TABLE="$LANDING_NFTABLES_TABLE" \
  SB_LANDING_EXPECTED_NFT_CHAIN="$LANDING_NFTABLES_CHAIN" python3 -I -c '
import os
import re
import sys

lines = [line.strip() for line in sys.stdin.read().splitlines() if line.strip()]
family = os.environ["SB_LANDING_EXPECTED_NFT_FAMILY"]
table = os.environ["SB_LANDING_EXPECTED_NFT_TABLE"]
chain = os.environ["SB_LANDING_EXPECTED_NFT_CHAIN"]
address = os.environ["SB_LANDING_EXPECTED_ENTRY_IPV4"]
port = os.environ["SB_LANDING_EXPECTED_PORT"]

if len(lines) != 7:
    raise SystemExit(1)
if lines[0] != f"table {family} {table} {{" or lines[1] != f"chain {chain} {{":
    raise SystemExit(1)
if not re.fullmatch(r"type filter hook input priority (?:-10|filter - 10); policy accept;", lines[2]):
    raise SystemExit(1)
if lines[3] != f"ip saddr {address} tcp dport {port} accept":
    raise SystemExit(1)
if lines[4] != f"tcp dport {port} drop":
    raise SystemExit(1)
if lines[5:] != ["}", "}"]:
    raise SystemExit(1)
' <<<"$current"
}

landing_startup_config_has_no_managed_residue() {
  local config
  config="$(landing_managed_path "$LANDING_SINGBOX_CONFIG_PATH")" || return 1
  [[ ! -e "$config" && ! -L "$config" ]] && return 0
  [[ -f "$config" && ! -L "$config" ]] || return 1
  jq -e --arg certificate "$LANDING_CERTIFICATE_PATH" --arg key "$LANDING_PRIVATE_KEY_PATH" '
    type == "object" and
    ([.inbounds[]? |
      select(
        .tag == "landing-gateway" or
        any(.users[]?; .name == "entry-controller") or
        .tls.certificate_path? == $certificate or
        .tls.key_path? == $key
      )] | length == 0)
  ' "$config" >/dev/null
}

landing_startup_tls_material_is_valid() {
  local ca="$1" certificate="$2" private_key="$3" certificate_public_key private_public_key
  local historical_attime
  # 启动早期的系统时钟可能尚未同步；选择 CA 与证书有效期交集中的固定时刻，
  # 既验证签发关系，又避免依赖 OpenSSL 专有的 `-no_check_time` 选项。
  historical_attime="$(controller_historical_certificate_attime "$ca" "$certificate")" || return 1
  [[ "$historical_attime" =~ ^[0-9]+$ ]] || return 1
  openssl verify -attime "$historical_attime" -CAfile "$ca" "$certificate" \
    >/dev/null 2>&1 || return 1
  certificate_public_key="$(openssl x509 -in "$certificate" -pubkey -noout 2>/dev/null)" || return 1
  private_public_key="$(openssl pkey -in "$private_key" -pubout 2>/dev/null)" || return 1
  [[ -n "$certificate_public_key" && "$certificate_public_key" == "$private_public_key" ]]
}

landing_startup_runtime_directories_are_safe() {
  local requirement="${1:-optional}" system_etc config_parent nft_parent tls_directory path
  [[ "$requirement" == optional || "$requirement" == required ]] || return 1
  system_etc="$(landing_managed_path /etc)" || return 1
  config_parent="$(landing_managed_path "$(dirname -- "$LANDING_SINGBOX_CONFIG_PATH")")" || return 1
  nft_parent="$(landing_managed_path "$LANDING_NFTABLES_DIRECTORY")" || return 1
  tls_directory="$(landing_managed_path "$LANDING_TLS_DIRECTORY")" || return 1
  landing_directory_is_safe "$system_etc" || return 1
  for path in "$config_parent" "$nft_parent"; do
    if [[ -e "$path" || -L "$path" ]]; then
      landing_directory_is_safe "$path" || return 1
    else
      [[ "$requirement" == optional ]] || return 1
    fi
  done
  if [[ -e "$tls_directory" || -L "$tls_directory" ]]; then
    landing_directory_is_safe "$tls_directory" 700 || return 1
  else
    [[ "$requirement" == optional ]] || return 1
  fi
}

landing_startup_managed_state() {
  local receipt="$LANDING_RECEIPT_FILE" revision identity config ca certificate private_key nft_rules
  local allowed_entry_ipv4 nft_port port singbox_binary
  identity="$(landing_channel_path "$LANDING_CHANNEL_IDENTITY_PATH")" || return 1
  config="$(landing_managed_path "$LANDING_SINGBOX_CONFIG_PATH")" || return 1
  ca="$(landing_managed_path "$LANDING_CA_CERTIFICATE_PATH")" || return 1
  certificate="$(landing_managed_path "$LANDING_CERTIFICATE_PATH")" || return 1
  private_key="$(landing_managed_path "$LANDING_PRIVATE_KEY_PATH")" || return 1
  nft_rules="$(landing_managed_path "$LANDING_NFTABLES_RULES_PATH")" || return 1
  landing_startup_runtime_directories_are_safe optional || return 1
  if [[ ! -e "$receipt" && ! -L "$receipt" ]]; then
    [[ ! -e "$ca" && ! -L "$ca" && ! -e "$certificate" && ! -L "$certificate" &&
       ! -e "$private_key" && ! -L "$private_key" && ! -e "$nft_rules" && ! -L "$nft_rules" ]] || return 1
    landing_startup_config_has_no_managed_residue || return 1
    printf 'absent\n'
    return
  fi
  validate_landing_receipt_file "$receipt" || return 1
  revision="$(jq -r '.applied_revision' "$receipt")" || return 1
  landing_safe_integer_is_valid "$revision" || return 1
  if [[ "$revision" == 0 ]]; then
    [[ ! -e "$ca" && ! -L "$ca" && ! -e "$certificate" && ! -L "$certificate" &&
       ! -e "$private_key" && ! -L "$private_key" && ! -e "$nft_rules" && ! -L "$nft_rules" ]] || return 1
    landing_startup_config_has_no_managed_residue || return 1
    printf 'absent\n'
    return
  fi
  validate_landing_channel_identity_file "$identity" || return 1
  [[ "$(jq -r '.landing_id' "$receipt")" == "$(jq -r '.landing_id' "$identity")" ]] || return 1
  landing_startup_runtime_directories_are_safe required || return 1
  for path in "$config" "$ca" "$certificate" "$private_key" "$nft_rules"; do
    landing_managed_file_is_safe "$path" || return 1
  done
  port="$(jq -er --arg certificate "$LANDING_CERTIFICATE_PATH" --arg key "$LANDING_PRIVATE_KEY_PATH" '
    select(
    type == "object" and
    (keys | sort) == ["inbounds", "log", "outbounds", "route"] and
    .log == {level:"warn",timestamp:true} and
    (.inbounds | type == "array" and length == 1) and
    (.inbounds[0] | keys | sort) == ["listen","listen_port","tag","tls","type","users"] and
    .inbounds[0].type == "anytls" and .inbounds[0].tag == "landing-gateway" and
    .inbounds[0].listen == "0.0.0.0" and
    (.inbounds[0].listen_port | type == "number" and . == floor and . >= 1 and . <= 65535) and
    (.inbounds[0].users | type == "array" and length == 1) and
    (.inbounds[0].users[0] | keys | sort) == ["name","password"] and
    .inbounds[0].users[0].name == "entry-controller" and
    (.inbounds[0].users[0].password | type == "string" and length >= 32 and length <= 128 and
      test("^[A-Za-z0-9_-]+$")) and
    .inbounds[0].tls == {enabled:true,certificate_path:$certificate,key_path:$key} and
    .outbounds == [{type:"direct",tag:"direct"}] and .route == {final:"direct"}
    ) |
    .inbounds[0].listen_port
  ' "$config")" || return 1
  landing_port_is_valid "$port" || return 1
  IFS=$'\t' read -r allowed_entry_ipv4 nft_port < <(landing_startup_parse_nft_file "$nft_rules") || return 1
  [[ "$nft_port" == "$port" ]] || return 1
  landing_startup_tls_material_is_valid "$ca" "$certificate" "$private_key" || return 1
  singbox_binary="$(landing_managed_path "$LANDING_SINGBOX_BINARY")" || return 1
  landing_startup_root_executable_is_safe "$singbox_binary" || return 1
  "$singbox_binary" check -c "$config" >/dev/null 2>&1 || return 1
  nft -c -f "$nft_rules" >/dev/null 2>&1 || return 1
  printf 'applied\t%s\t%s\n' "$allowed_entry_ipv4" "$port"
}

landing_startup_enforce_installed_firewall() {
  local state allowed_entry_ipv4 port nft_rules
  IFS=$'\t' read -r state allowed_entry_ipv4 port < <(landing_startup_managed_state) || return 1
  [[ "$state" == absent || "$state" == applied ]] || return 1
  if [[ "$state" == absent ]]; then
    landing_apply_live_nft_is_missing
    return
  fi
  [[ "$state" == applied ]] || return 1
  nft_rules="$(landing_managed_path "$LANDING_NFTABLES_RULES_PATH")" || return 1
  if landing_startup_live_nft_matches_values "$allowed_entry_ipv4" "$port"; then
    return 0
  fi
  landing_apply_live_nft_is_missing || return 1
  nft -f "$nft_rules" >/dev/null 2>&1 || return 1
  landing_startup_live_nft_matches_values "$allowed_entry_ipv4" "$port"
}

landing_startup_installed_state_is_valid() {
  local state allowed_entry_ipv4 port
  IFS=$'\t' read -r state allowed_entry_ipv4 port < <(landing_startup_managed_state) || return 1
  case "$state" in
    absent) landing_apply_live_nft_is_missing ;;
    applied) landing_startup_live_nft_matches_values "$allowed_entry_ipv4" "$port" ;;
    *) return 1 ;;
  esac
}

landing_startup_persistent_snapshot_is_valid() {
  landing_apply_target_matches_snapshot "$LANDING_ACTIVE_SNAPSHOT" config.json \
    "$(landing_managed_path "$LANDING_SINGBOX_CONFIG_PATH")" || return 1
  landing_apply_target_matches_snapshot "$LANDING_ACTIVE_SNAPSHOT" gateway-ca.crt \
    "$(landing_managed_path "$LANDING_CA_CERTIFICATE_PATH")" || return 1
  landing_apply_target_matches_snapshot "$LANDING_ACTIVE_SNAPSHOT" gateway.crt \
    "$(landing_managed_path "$LANDING_CERTIFICATE_PATH")" || return 1
  landing_apply_target_matches_snapshot "$LANDING_ACTIVE_SNAPSHOT" gateway.key \
    "$(landing_managed_path "$LANDING_PRIVATE_KEY_PATH")" || return 1
  landing_apply_target_matches_snapshot "$LANDING_ACTIVE_SNAPSHOT" landing.nft \
    "$(landing_managed_path "$LANDING_NFTABLES_RULES_PATH")" || return 1
  landing_apply_target_matches_snapshot "$LANDING_ACTIVE_RECEIPT_SNAPSHOT" receipt.json \
    "$LANDING_RECEIPT_FILE" receipt.state || return 1
  landing_apply_runtime_directories_match_snapshot
}

landing_startup_persistent_candidate_is_valid() {
  controller_private_directory_is_trusted "$(dirname -- "$LANDING_RECEIPT_FILE")" || return 1
  validate_landing_receipt_file "$LANDING_RECEIPT_FILE" || return 1
  cmp -s -- "$LANDING_ACTIVE_WORK/receipt.next.json" "$LANDING_RECEIPT_FILE" || return 1
  landing_apply_runtime_directories_match_applied || return 1
  landing_apply_candidate_files_are_active
}

landing_startup_transaction_live_nft_is_known() {
  landing_apply_live_nft_matches_snapshot && return 0
  landing_apply_live_nft_matches_candidate "$LANDING_ACTIVE_WORK/apply.json" && return 0
  landing_apply_live_nft_is_missing
}

landing_startup_replace_live_nft_with_candidate() {
  if landing_apply_live_nft_matches_candidate "$LANDING_ACTIVE_WORK/apply.json"; then
    return 0
  fi
  if landing_apply_live_nft_is_missing; then
    nft -f "$LANDING_ACTIVE_WORK/landing.nft" >/dev/null 2>&1 || return 1
  elif landing_apply_live_nft_matches_snapshot; then
    {
      printf 'delete table %s %s\n' "$LANDING_NFTABLES_FAMILY" "$LANDING_NFTABLES_TABLE" || return 1
      cat -- "$LANDING_ACTIVE_WORK/landing.nft" || return 1
    } | nft -f - >/dev/null 2>&1 || return 1
  else
    return 1
  fi
  landing_apply_live_nft_matches_candidate "$LANDING_ACTIVE_WORK/apply.json"
}

landing_startup_restore_live_nft_snapshot() {
  local nft_state
  if landing_apply_live_nft_matches_snapshot; then
    return 0
  fi
  nft_state="$(<"$LANDING_ACTIVE_SNAPSHOT/nft-live.state")" || return 1
  if landing_apply_live_nft_matches_candidate "$LANDING_ACTIVE_WORK/apply.json"; then
    landing_apply_nft_rollback_batch_is_valid "$LANDING_ACTIVE_WORK" || return 1
    nft -f "$LANDING_ACTIVE_WORK/nft.rollback" >/dev/null 2>&1 || return 1
  elif landing_apply_live_nft_is_missing; then
    if [[ "$nft_state" == exists ]]; then
      nft -f "$LANDING_ACTIVE_SNAPSHOT/nft-live" >/dev/null 2>&1 || return 1
    elif [[ "$nft_state" != missing ]]; then
      return 1
    fi
  else
    return 1
  fi
  landing_apply_live_nft_matches_snapshot
}

landing_startup_restore_persistent_snapshot() {
  local config ca certificate private_key nft_rules rc=0
  config="$(landing_managed_path "$LANDING_SINGBOX_CONFIG_PATH")" || return 1
  ca="$(landing_managed_path "$LANDING_CA_CERTIFICATE_PATH")" || return 1
  certificate="$(landing_managed_path "$LANDING_CERTIFICATE_PATH")" || return 1
  private_key="$(landing_managed_path "$LANDING_PRIVATE_KEY_PATH")" || return 1
  nft_rules="$(landing_managed_path "$LANDING_NFTABLES_RULES_PATH")" || return 1
  landing_restore_snapshot_file "$LANDING_ACTIVE_SNAPSHOT" config.json "$config" || rc=1
  if [[ "$rc" == 0 ]]; then landing_restore_snapshot_file "$LANDING_ACTIVE_SNAPSHOT" gateway-ca.crt "$ca" || rc=1; fi
  if [[ "$rc" == 0 ]]; then landing_restore_snapshot_file "$LANDING_ACTIVE_SNAPSHOT" gateway.crt "$certificate" || rc=1; fi
  if [[ "$rc" == 0 ]]; then landing_restore_snapshot_file "$LANDING_ACTIVE_SNAPSHOT" gateway.key "$private_key" || rc=1; fi
  if [[ "$rc" == 0 ]]; then landing_restore_snapshot_file "$LANDING_ACTIVE_SNAPSHOT" landing.nft "$nft_rules" || rc=1; fi
  if [[ "$rc" == 0 ]]; then landing_restore_runtime_directories "$LANDING_ACTIVE_SNAPSHOT" || rc=1; fi
  if [[ "$rc" == 0 ]]; then landing_restore_receipt_snapshot "$LANDING_ACTIVE_RECEIPT_SNAPSHOT" || rc=1; fi
  if [[ "$rc" == 0 ]]; then landing_startup_restore_live_nft_snapshot || rc=1; fi
  [[ "$rc" == 0 ]] || return 1
  landing_startup_persistent_snapshot_is_valid || return 1
  landing_apply_live_nft_matches_snapshot
}

landing_startup_clear_runtime_drift_after_revalidation() {
  local marker="$LANDING_ACTIVE_WORK/runtime.drift"
  [[ -e "$marker" || -L "$marker" ]] || return 0
  landing_apply_transaction_file_is_safe "$marker" || return 1
  [[ ! -s "$marker" ]] || return 1
  landing_apply_runtime_targets_are_known || return 1
  landing_apply_runtime_directories_are_known || return 1
  landing_startup_transaction_live_nft_is_known || return 1
  landing_startup_singbox_is_stopped || return 1
  rm -f -- "$marker" || return 1
  sync_transaction_path "$LANDING_ACTIVE_WORK"
}

landing_startup_rollback_active_transaction() {
  local marker_rc=0 rc=0
  [[ "$LANDING_ACTIVE_TRANSACTION_PHASE" == active ]] || return 1
  landing_apply_cleanup_orphan_journal_file || return 1
  landing_apply_transaction_payload_is_valid || return 1
  [[ ! -e "$LANDING_ACTIVE_WORK/cleanup.started" && ! -L "$LANDING_ACTIVE_WORK/cleanup.started" &&
     ! -e "$LANDING_ACTIVE_WORK/.cleanup.next" && ! -L "$LANDING_ACTIVE_WORK/.cleanup.next" ]] || return 1
  landing_apply_cleanup_orphan_atomic_files || return 1
  landing_apply_runtime_targets_are_known || return 1
  landing_apply_runtime_directories_are_known || return 1
  landing_startup_transaction_live_nft_is_known || return 1
  landing_startup_singbox_is_stopped || return 1
  landing_apply_mutation_marker_is_valid || marker_rc=$?
  case "$marker_rc" in 0|2) ;; *) return 1 ;; esac
  if [[ "$marker_rc" == 2 ]]; then
    landing_apply_post_mutation_markers_are_absent || return 1
    landing_startup_persistent_snapshot_is_valid || return 1
    landing_startup_restore_live_nft_snapshot || return 1
  else
    landing_apply_post_mutation_marker_sequence_is_valid || return 1
    landing_startup_clear_runtime_drift_after_revalidation || return 1
    landing_startup_restore_persistent_snapshot || rc=1
  fi
  if [[ "$rc" == 0 ]]; then
    landing_apply_cleanup_orphan_atomic_files || rc=1
  fi
  if [[ "$rc" == 0 ]]; then
    landing_startup_persistent_snapshot_is_valid || rc=1
  fi
  if [[ "$rc" == 0 ]]; then
    landing_apply_live_nft_matches_snapshot || rc=1
  fi
  if [[ "$rc" == 0 ]]; then
    landing_startup_installed_state_is_valid || rc=1
  fi
  if [[ "$rc" == 0 ]]; then
    landing_apply_finish_rollback_transaction startup || rc=$?
  fi
  return "$rc"
}

landing_startup_recover_pending_transaction() {
  local directory="$LANDING_APPLY_TRANSACTION_DIRECTORY" phase name
  landing_apply_reset_active_transaction
  [[ ! -L "$directory" ]] || return 1
  [[ -e "$directory" ]] || return 0
  landing_apply_transaction_layout_is_safe || return 1
  if [[ ! -e "$LANDING_APPLY_TRANSACTION_JOURNAL" && ! -L "$LANDING_APPLY_TRANSACTION_JOURNAL" ]]; then
    if [[ -e "$directory/cleanup.started" || -L "$directory/cleanup.started" ]]; then
      landing_apply_cleanup_marker_without_journal_is_valid || return 1
    else
      for name in mutation.started runtime.drift service.restart-attempted \
        nft.apply-attempted nft.rollback-attempted; do
        [[ ! -e "$directory/$name" && ! -L "$directory/$name" ]] || return 1
      done
    fi
    # 无 journal 只能是变更前 staging 或已越过 journal 删除边界的合法 cleanup。
    # 先从持久态恢复并只读复核 live firewall；校验失败时保留全部残留证据。
    landing_startup_enforce_installed_firewall || return 1
    landing_startup_installed_state_is_valid || return 1
    landing_apply_discard_transaction_directory
    return
  fi
  landing_apply_load_pending_transaction || return 1
  phase="$LANDING_ACTIVE_TRANSACTION_PHASE"
  if [[ "$phase" == committed || "$phase" == rolled_back ]]; then
    landing_apply_terminal_receipt_is_valid "$phase" startup-known || return 1
    if [[ "$phase" == committed ]]; then
      landing_startup_replace_live_nft_with_candidate || return 1
    else
      landing_startup_restore_live_nft_snapshot || return 1
    fi
    # 只有完整持久态与 live firewall 都已通过只读校验，才允许删除终态证据。
    landing_startup_installed_state_is_valid || return 1
    landing_apply_reset_active_transaction
    landing_apply_cleanup_terminal_transaction startup
    return
  fi
  [[ "$phase" == active ]] || return 1
  set_signal_rollback landing_startup_signal_recovery || return 1
  landing_startup_rollback_active_transaction
}

landing_startup_signal_recovery() {
  landing_startup_recover_pending_transaction || return 1
  landing_startup_enforce_installed_firewall
}

landing_startup_recovery_unlocked() {
  local state tls_directory
  if ! landing_startup_singbox_is_stopped; then
    # 首次启用门禁时，既有 v4/外部 sing-box 可能仍在运行。只允许完全没有
    # v5 事务、receipt、受管配置残留和同名实时 nft 表的严格空态通过。
    landing_startup_singbox_is_active || return 1
    [[ ! -e "$LANDING_APPLY_TRANSACTION_DIRECTORY" &&
       ! -L "$LANDING_APPLY_TRANSACTION_DIRECTORY" ]] || return 1
    [[ ! -e "$LANDING_RECEIPT_FILE" && ! -L "$LANDING_RECEIPT_FILE" ]] || return 1
    tls_directory="$(landing_managed_path "$LANDING_TLS_DIRECTORY")" || return 1
    [[ ! -e "$tls_directory" && ! -L "$tls_directory" ]] || return 1
    state="$(landing_startup_managed_state)" || return 1
    [[ "$state" == absent ]] || return 1
    landing_apply_live_nft_is_missing
    return
  fi
  landing_startup_recover_pending_transaction || return 1
  landing_startup_enforce_installed_firewall || return 1
  landing_startup_singbox_is_stopped
}

landing_startup_recovery_with_receipt_lock() {
  with_landing_receipt_lock landing_startup_recovery_unlocked
}

landing_startup_recovery_after_channel_lock() {
  # 外层早检用于快速失败；shared channel lock 内复核，关闭与通道轮换之间的 TOCTOU。
  landing_startup_recovery_gate_files_are_valid || return 1
  landing_restricted_channel_is_valid || return 1
  landing_channel_loaded_runtime_matches_identity || return 1
  landing_startup_receipt_lock_parent_chain_is_safe || return 1
  landing_startup_recovery_with_receipt_lock
}

landing_startup_recovery_with_channel_lock() {
  with_landing_channel_shared_lock landing_startup_recovery_after_channel_lock
}

landing_startup_recovery_main() {
  local rc=0
  [[ $# -eq 0 ]] || return 64
  PATH=/usr/sbin:/usr/bin:/sbin:/bin
  LC_ALL=C
  export PATH LC_ALL
  umask 077
  unset BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH OPENSSL_CONF
  landing_apply_reset_active_transaction
  [[ "$EUID" == "$(landing_apply_expected_uid)" ]] || return 77
  landing_apply_runtime_paths_are_safe || return 78
  landing_channel_runtime_paths_are_safe || return 78
  landing_startup_recovery_paths_are_safe || return 78
  landing_startup_recovery_gate_files_are_valid || return 78
  with_landing_channel_input_lock landing_startup_recovery_with_channel_lock || rc=$?
  landing_apply_reset_active_transaction
  return "$rc"
}
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

migration_backup_dir() {
  printf '%s' "${MIGRATION_BACKUP_DIR:-/root/sb-user-manager-backups/data}"
}

CREATED_MIGRATION_BACKUP=""
MIGRATION_MATERIALIZE_FAILURE=""
MIGRATION_INSPECTION_RESULT=""
MIGRATION_IMPORT_CANDIDATES=()
MIGRATION_IMPORT_SOURCE=""

ensure_migration_crypto_dependencies() {
  local dependency
  local -a missing=()
  for dependency in jq openssl python3 sha256sum; do
    command -v "$dependency" >/dev/null 2>&1 || missing+=("$dependency")
  done
  ((${#missing[@]} == 0)) && return 0
  printf '错误：迁移备份功能缺少运行依赖：%s\n' "${missing[*]}"
  echo '请返回「系统管理」→「部署与卸载」→「安装或修复环境」完成修复后重试。'
  return 1
}

read_backup_password_twice() {
  local first second
  while true; do
    read -r -s -p '设置迁移密码（至少 8 位；输入 0 取消）：' first; echo
    [[ "$first" != 0 ]] || { BACKUP_PASSWORD=""; return 1; }
    if [[ -z "$first" ]]; then
      echo '密码不能为空，请重新输入。'
      continue
    fi
    if ((${#first} < 8)); then
      echo '密码至少需要 8 个字符，请重新输入。'
      continue
    fi
    read -r -s -p '再次输入密码（输入 0 取消）：' second; echo
    [[ "$second" != 0 ]] || { BACKUP_PASSWORD=""; return 1; }
    if [[ "$first" != "$second" ]]; then
      echo '两次输入的密码不一致，请重新设置。'
      continue
    fi
    BACKUP_PASSWORD="$first"
    return 0
  done
}

read_backup_password() {
  while true; do
    read -r -s -p '迁移包密码（输入 0 取消）：' BACKUP_PASSWORD; echo
    [[ "$BACKUP_PASSWORD" != 0 ]] || { BACKUP_PASSWORD=""; return 1; }
    [[ -n "$BACKUP_PASSWORD" ]] && return 0
    echo '密码不能为空，请重新输入。'
  done
}

validate_migration_checksum() {
  local encrypted="$1" expected actual
  [[ -f "$encrypted.sha256" ]] || return 1
  expected="$(awk 'NR==1 {print $1}' "$encrypted.sha256")"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  actual="$(sha256sum "$encrypted" | awk '{print $1}' | tr 'A-F' 'a-f')"
  expected="$(printf '%s' "$expected" | tr 'A-F' 'a-f')"
  [[ "$actual" == "$expected" ]]
}

derive_migration_auth_key() {
  local password="$1" salt="$2" key
  [[ "$salt" =~ ^[0-9a-fA-F]{16}$ ]] || return 1
  key="$(SB_BACKUP_PASSWORD="$password" openssl enc -aes-256-cbc -md sha256 -pbkdf2 -iter 200000 \
    -P -S "$salt" -pass env:SB_BACKUP_PASSWORD 2>/dev/null |
    awk -F= 'tolower($1)=="key" {gsub(/[[:space:]]/,"",$2); print $2; exit}')"
  [[ "$key" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  printf '%s' "$key"
}

migration_hmac_sha256_from_env() {
  local encrypted="$1"
  [[ "${SB_MIGRATION_HMAC_KEY:-}" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  SB_MIGRATION_HMAC_KEY="$SB_MIGRATION_HMAC_KEY" python3 -c \
    'import hashlib, hmac, os, sys
with open(sys.argv[1], "rb") as source:
    data = source.read()
print(hmac.new(bytes.fromhex(os.environ["SB_MIGRATION_HMAC_KEY"]), data, hashlib.sha256).hexdigest())' \
    "$encrypted"
}

migration_hmac_sha256() {
  local encrypted="$1" key="$2"
  SB_MIGRATION_HMAC_KEY="$key" migration_hmac_sha256_from_env "$encrypted"
}

constant_time_hex_equal() {
  local left="$1" right="$2" i mismatch=0
  [[ "$left" =~ ^[0-9a-f]{64}$ && "$right" =~ ^[0-9a-f]{64}$ ]] || return 1
  for ((i=0; i<64; i++)); do
    [[ "${left:i:1}" == "${right:i:1}" ]] || mismatch=1
  done
  ((mismatch == 0))
}

write_migration_auth_file() {
  local encrypted="$1" password="$2" salt key tag
  salt="$(openssl rand -hex 8)"
  key="$(derive_migration_auth_key "$password" "$salt")" || return 1
  tag="$(migration_hmac_sha256 "$encrypted" "$key")"
  [[ "$tag" =~ ^[0-9a-f]{64}$ ]] || return 1
  jq -n --arg salt "$salt" --arg tag "$tag" \
    '{version:1,kdf:"PBKDF2-SHA256",iterations:200000,mac:"HMAC-SHA256",salt:$salt,tag:$tag}' > "$encrypted.auth.tmp"
  chmod 600 "$encrypted.auth.tmp"; mv "$encrypted.auth.tmp" "$encrypted.auth"
  key=""; tag=""
}

verify_migration_auth_file() {
  local encrypted="$1" password="$2" salt expected key actual
  [[ -f "$encrypted.auth" ]] || return 2
  jq -e '
    .version==1 and .kdf=="PBKDF2-SHA256" and .iterations==200000 and
    .mac=="HMAC-SHA256" and (.salt|test("^[0-9a-fA-F]{16}$")) and
    (.tag|test("^[0-9a-fA-F]{64}$"))
  ' "$encrypted.auth" >/dev/null 2>&1 || return 1
  salt="$(jq -r '.salt' "$encrypted.auth")"; expected="$(jq -r '.tag|ascii_downcase' "$encrypted.auth")"
  key="$(derive_migration_auth_key "$password" "$salt")" || return 1
  actual="$(migration_hmac_sha256 "$encrypted" "$key")"
  key=""
  constant_time_hex_equal "$actual" "$expected"
}

materialize_migration_bundle() {
  local bundle="$1" work="$2" encrypted sha
  MIGRATION_MATERIALIZE_FAILURE="structure-invalid"
  jq -e --argjson version "$MIGRATION_BUNDLE_VERSION" '
    .bundle_version==$version and .encryption=="AES-256-CBC" and
    .payload_format_version==1 and
    (.cipher_sha256|type=="string" and test("^[0-9a-fA-F]{64}$")) and
    (.ciphertext_base64|type=="string" and length>0) and
    (.auth.version==1) and (.auth.kdf=="PBKDF2-SHA256") and
    (.auth.iterations==200000) and (.auth.mac=="HMAC-SHA256") and
    (.auth.salt|test("^[0-9a-fA-F]{16}$")) and
    (.auth.tag|test("^[0-9a-fA-F]{64}$"))
  ' "$bundle" >/dev/null 2>&1 || return 1
  encrypted="$work/payload.enc"
  jq -r '.ciphertext_base64' "$bundle" | openssl base64 -d -A -out "$encrypted" 2>/dev/null || return 1
  [[ -s "$encrypted" ]] || return 1
  sha="$(jq -r '.cipher_sha256|ascii_downcase' "$bundle")"
  printf '%s  payload.enc\n' "$sha" > "$encrypted.sha256" || return 1
  jq '.auth' "$bundle" > "$encrypted.auth" || return 1
  chmod 600 "$encrypted" "$encrypted.sha256" "$encrypted.auth" || return 1
  MIGRATION_MATERIALIZE_FAILURE="checksum-failed"
  validate_migration_checksum "$encrypted" || return 1
  MATERIALIZED_MIGRATION_ENCRYPTED="$encrypted"
  MIGRATION_MATERIALIZE_FAILURE=""
}

validate_migration_bundle() {
  local bundle="$1" work
  [[ -f "$bundle" && "$bundle" == *.sbm ]] || return 1
  work="$(mktemp -d /tmp/sb-migration-bundle.XXXXXX)"
  register_temp_path "$work"
  if materialize_migration_bundle "$bundle" "$work"; then rm -rf "$work"; return 0; fi
  rm -rf "$work"; return 1
}

build_migration_bundle() {
  local encrypted="$1" bundle="$2" encoded sha
  encoded="$(mktemp /tmp/sb-migration-cipher.XXXXXX.b64)"
  register_temp_path "$encoded"
  openssl base64 -A -in "$encrypted" -out "$encoded"
  sha="$(sha256sum "$encrypted" | awk '{print $1}')"
  register_temp_path "$bundle.tmp"
  jq -n \
    --argjson bundle_version "$MIGRATION_BUNDLE_VERSION" \
    --argjson payload_format "$MIGRATION_FORMAT_VERSION" \
    --arg created_at "$(date -Iseconds)" \
    --arg script_version "$SCRIPT_VERSION" \
    --arg sha "$sha" \
    --slurpfile auth "$encrypted.auth" \
    --rawfile ciphertext "$encoded" \
    '{bundle_version:$bundle_version,created_at:$created_at,script_version:$script_version,
      payload_format_version:$payload_format,encryption:"AES-256-CBC",cipher_sha256:$sha,
      auth:$auth[0],ciphertext_base64:$ciphertext}' > "$bundle.tmp"
  rm -f "$encoded"
  chmod 600 "$bundle.tmp"; mv "$bundle.tmp" "$bundle"
  validate_migration_bundle "$bundle"
}

create_migration_backup() {
  local dir stamp base work plain encrypted bundle password
  CREATED_MIGRATION_BACKUP=""
  ensure_migration_crypto_dependencies || return 0
  prepare_core
  need_cmd openssl
  nfuse persist >/dev/null
  dir="$(migration_backup_dir)"
  install -d -m 700 "$dir"
  stamp="$(date '+%Y%m%d-%H%M%S')"
  base="sb-user-data-${SCRIPT_VERSION}-${stamp}"
  work="$(mktemp -d /tmp/sb-user-data.XXXXXX)"
  register_temp_path "$work"
  plain="$work/payload.json"
  encrypted="$work/payload.enc"
  bundle="$dir/$base.sbm"
  jq -n \
    --argjson format "$MIGRATION_FORMAT_VERSION" \
    --arg created_at "$(date -Iseconds)" \
    --arg script_version "$SCRIPT_VERSION" \
    --arg hostname "$(hostname)" \
    --argjson schema "$STATE_SCHEMA_VERSION" \
    --slurpfile state "$STATE_FILE" \
    --argjson nfuse "$(nfuse list --json)" \
    'def endpoint_from_legacy:
       if (.protocol // "ss2022") == "anytls" then
         {protocol:"anytls",port:.port,anytls_password:.anytls_password,tls_sni:.tls_sni}
       else
         {protocol:"ss2022",port:.port,shadowtls_password:.shadowtls_password,
          ss2022_password:.ss2022_password,method:.method,shadowtls_sni:.shadowtls_sni}
       end;
     ($state[0] |
       if .schema_version == 3 and $schema >= 4 then
         . + {schema_version:4,outbound_presets:(.outbound_presets // []),rule_presets:(.rule_presets // [])}
       else . end |
       if .schema_version == 4 and $schema == 5 then
         .users |= map(.protocol = (.protocol // "ss2022") | if has("usage_offset_bytes") then . else .usage_offset_bytes = 0 end | .endpoints = [endpoint_from_legacy]) |
         .schema_version = 5
       else . end) as $snapshot |
      {format_version:$format,created_at:$created_at,script_version:$script_version,source_hostname:$hostname,state:$snapshot,
       nfuse_usage:[$nfuse[] as $account | select(any($snapshot.users[]; .name == $account.name)) | $account]}' > "$plain"
  chmod 600 "$plain"
  validate_migration_payload_structure "$plain" >/dev/null 2>&1 ||
    { rm -rf "$work"; die "无法生成可安全恢复的迁移数据"; }
  if ! read_backup_password_twice; then
    BACKUP_PASSWORD=""
    rm -rf "$work"
    MENU_RETURNED=true
    echo '已取消创建备份。'
    return 0
  fi
  password="$BACKUP_PASSWORD"; BACKUP_PASSWORD=""
  if ! SB_BACKUP_PASSWORD="$password" openssl enc -aes-256-cbc -md sha256 -pbkdf2 -iter 200000 -salt \
    -in "$plain" -out "$encrypted" -pass env:SB_BACKUP_PASSWORD; then
    password=""; rm -rf "$work"; die "迁移包加密失败"
  fi
  rm -f "$plain"; chmod 600 "$encrypted"
  if ! write_migration_auth_file "$encrypted" "$password"; then
    password=""; rm -rf "$work"; die "迁移包认证信息生成失败"
  fi
  password=""
  if ! build_migration_bundle "$encrypted" "$bundle"; then
    rm -rf "$work" "$bundle" "$bundle.tmp"; die "单文件迁移包封装或校验失败"
  fi
  rm -rf "$work"
  CREATED_MIGRATION_BACKUP="$bundle"
  printf '单文件迁移备份创建成功：%s\n' "$bundle"
  printf '备份已加密并设置密码保护（.sbm 单文件）。\n'
  printf '这份备份仍在当前服务器上；为防止服务器重装或磁盘损坏，请另存一份到其他设备。\n'
  printf '包含：用户 %s 个，分流 %s 条，预置出口 %s 个，预置规则 %s 个，流量记录 %s 份。\n' \
    "$(jq '.users|length' "$STATE_FILE")" "$(jq '.splits|length' "$STATE_FILE")" \
    "$(jq '(.outbound_presets // [])|length' "$STATE_FILE")" "$(jq '(.rule_presets // [])|length' "$STATE_FILE")" \
    "$(nfuse list --json | jq 'length')"
}

file_mtime_epoch() {
  stat -c '%Y' -- "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null
}

list_files_newest_first() {
  local file epoch
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    epoch="$(file_mtime_epoch "$file")" || continue
    [[ "$epoch" =~ ^[0-9]+$ ]] || continue
    printf '%s\t%s\n' "$epoch" "$file"
  done | sort -t $'\t' -k1,1nr -k2,2r | cut -f2-
}

load_migration_backups() {
  local dir file
  MIGRATION_BACKUPS=()
  dir="$(migration_backup_dir)"
  [[ -d "$dir" ]] || return 0
  while IFS= read -r file; do MIGRATION_BACKUPS[${#MIGRATION_BACKUPS[@]}]="$file"; done < <(
    find "$dir" -maxdepth 1 -type f -name 'sb-user-data-*.sbm' -print | list_files_newest_first
  )
}

print_migration_backups() {
  local i file size integrity
  load_migration_backups
  if ((${#MIGRATION_BACKUPS[@]} == 0)); then echo '暂无迁移备份。'; return 1; fi
  for i in "${!MIGRATION_BACKUPS[@]}"; do
    file="${MIGRATION_BACKUPS[$i]}"; size="$(du -h "$file" | awk '{print $1}')"
    if validate_migration_bundle "$file"; then integrity='结构完整'
    else integrity='校验失败'; fi
    printf '  %d. %s｜%s｜%s｜已设置密码\n' "$((i+1))" "$(basename "$file")" "$size" "$integrity"
  done
}

backup_directory_usage_kib() {
  local dir="$1"
  [[ -d "$dir" && ! -L "$dir" ]] || { printf '0\n'; return 0; }
  du -sk -- "$dir" 2>/dev/null | awk 'NR==1 {print $1+0}'
}

backup_paths_usage_kib() {
  local path total=0 size
  for path in "$@"; do
    [[ -d "$path" && ! -L "$path" ]] || continue
    size="$(du -sk -- "$path" 2>/dev/null | awk 'NR==1 {print $1+0}')" || continue
    [[ "$size" =~ ^[0-9]+$ ]] || continue
    ((total+=size))
  done
  printf '%s\n' "$total"
}

format_backup_usage() {
  awk -v kib="${1:-0}" 'BEGIN {
    if (kib >= 1048576) printf "%.1f GB", kib / 1048576;
    else if (kib >= 1024) printf "%.1f MB", kib / 1024;
    else printf "%d KB", kib;
  }'
}

show_backup_storage_overview() {
  local migration_dir report_dir migration_size snapshot_size operation_size report_size
  local invalid_snapshots incomplete_operation invalid_reports report
  migration_dir="$(migration_backup_dir)"
  report_dir="$(migration_report_dir)"
  load_migration_backups
  load_environment_snapshot_candidates
  load_operation_backup_groups
  load_migration_reports
  migration_size="$(backup_directory_usage_kib "$migration_dir")"
  snapshot_size=0
  if ((${#ENVIRONMENT_SNAPSHOTS[@]} > 0)); then
    snapshot_size="$(backup_paths_usage_kib "${ENVIRONMENT_SNAPSHOTS[@]}")"
  fi
  operation_size="$(backup_directory_usage_kib "$BACKUP_DIR")"
  report_size="$(backup_directory_usage_kib "$report_dir")"
  invalid_snapshots="$(count_invalid_environment_snapshots)"
  incomplete_operation="$(count_incomplete_operation_backup_files)"
  invalid_reports=0
  if ((${#MIGRATION_REPORTS[@]} > 0)); then
    for report in "${MIGRATION_REPORTS[@]}"; do
      validate_migration_restore_report "$report" || ((invalid_reports+=1))
    done
  fi

  cat <<EOF
备份保存情况

  迁移备份        ${#MIGRATION_BACKUPS[@]} 份｜$(format_backup_usage "$migration_size")｜由你决定何时删除
  完整回滚备份    ${#ENVIRONMENT_SNAPSHOTS[@]} 份｜$(format_backup_usage "$snapshot_size")｜自动保留最近 ${ENVIRONMENT_BACKUP_RETENTION} 份
  内部操作备份    ${#OPERATION_BACKUP_GROUPS[@]} 组｜$(format_backup_usage "$operation_size")｜自动保留最近 ${OPERATION_BACKUP_RETENTION} 组
  恢复记录        ${#MIGRATION_REPORTS[@]} 份｜$(format_backup_usage "$report_size")｜自动保留最近 ${MIGRATION_REPORT_RETENTION} 份
EOF
  if ((invalid_snapshots > 0 || incomplete_operation > 0 || invalid_reports > 0)); then
    printf '\n  提示：发现未自动处理的异常文件：完整备份 %s 份、内部备份文件 %s 个、恢复记录 %s 份。\n' \
      "$invalid_snapshots" "$incomplete_operation" "$invalid_reports"
    echo '  脚本不会自动删除这些文件，可通过检查与故障报告进一步确认。'
  fi
}

load_migration_import_candidates() {
  local scan_dir file
  MIGRATION_IMPORT_CANDIDATES=()
  scan_dir="${MIGRATION_IMPORT_SCAN_DIR:-/root}"
  [[ -d "$scan_dir" && ! -L "$scan_dir" ]] || return 0
  while IFS= read -r file; do
    MIGRATION_IMPORT_CANDIDATES[${#MIGRATION_IMPORT_CANDIDATES[@]}]="$file"
  done < <(
    find "$scan_dir" -mindepth 1 -maxdepth 1 -type f -name 'sb-user-data-*.sbm' -print |
      list_files_newest_first
  )
}

read_migration_import_path() {
  local source
  if ! read -r -e -p '请输入单文件迁移包 .sbm 路径（输入 0 返回）：' source; then return 1; fi
  [[ "$source" != 0 ]] || return 1
  MIGRATION_IMPORT_SOURCE="$source"
}

select_migration_import_source() {
  local i file size integrity manual_index
  MIGRATION_IMPORT_SOURCE=""
  load_migration_import_candidates
  if ((${#MIGRATION_IMPORT_CANDIDATES[@]} == 0)); then
    echo '未在 /root 顶层发现迁移备份，可手动输入其他路径。'
    read_migration_import_path
    return
  fi

  printf '\n发现 /root 顶层的迁移备份：\n'
  for i in "${!MIGRATION_IMPORT_CANDIDATES[@]}"; do
    file="${MIGRATION_IMPORT_CANDIDATES[$i]}"
    size="$(du -h "$file" | awk '{print $1}')"
    if validate_migration_bundle "$file" >/dev/null 2>&1; then integrity='结构完整'
    else integrity='校验失败'; fi
    printf '  %d. %s｜%s｜%s\n' "$((i + 1))" "$(basename "$file")" "$size" "$integrity"
  done
  manual_index=$((${#MIGRATION_IMPORT_CANDIDATES[@]} + 1))
  printf '  %d. 手动输入其他路径\n' "$manual_index"
  echo '  0. 返回上一级'
  read_numbered_index '请选择要添加的备份：' "$manual_index" || return 1
  if ((SELECTED_INDEX == ${#MIGRATION_IMPORT_CANDIDATES[@]})); then
    read_migration_import_path
  else
    MIGRATION_IMPORT_SOURCE="${MIGRATION_IMPORT_CANDIDATES[$SELECTED_INDEX]}"
  fi
}

import_migration_backup() {
  local source dir name destination answer
  prepare_core
  while true; do
    select_migration_import_source || return 0
    source="$MIGRATION_IMPORT_SOURCE"
    if [[ ! -f "$source" ]]; then echo '文件不存在，请检查路径后重新输入。'; continue; fi
    source="$(readlink -f -- "$source")"
    name="$(basename "$source")"
    if [[ "$name" != sb-user-data-*.sbm ]]; then echo '文件名必须符合 sb-user-data-*.sbm，请重新选择。'; continue; fi
    if ! validate_migration_bundle "$source"; then echo '备份文件不完整或已经损坏，请重新复制原始 .sbm 文件。'; continue; fi
    break
  done
  dir="$(migration_backup_dir)"; install -d -m 700 "$dir"
  destination="$dir/$name"
  if [[ "$source" == "$(readlink -f -- "$destination" 2>/dev/null || true)" ]]; then
    echo '该迁移包已经位于备份目录。'; return 0
  fi
  if [[ -e "$destination" ]]; then
    read -r -p '备份目录中已有同名文件，是否覆盖？[y/N]：' answer
    [[ "$answer" =~ ^[Yy]$ ]] || { echo '已取消导入。'; return 0; }
  fi
  register_temp_path "$destination.tmp"
  install -m 600 "$source" "$destination.tmp"
  mv "$destination.tmp" "$destination"
  validate_migration_bundle "$destination" || { rm -f "$destination"; die "导入后的单文件迁移包校验失败"; }
  printf '单文件迁移包已导入：%s\n' "$destination"
}

select_migration_backup() {
  print_migration_backups || return 1
  echo '  0. 返回上一级'
  read_numbered_index '请选择备份编号：' "${#MIGRATION_BACKUPS[@]}" || return 1
  SELECTED_MIGRATION_BACKUP="${MIGRATION_BACKUPS[$SELECTED_INDEX]}"
}

normalize_migration_payload_schema() {
  local file="$1" schema tmp needs_update=false
  schema="$(jq -r '.state.schema_version // 0' "$file" 2>/dev/null)" || return 1
  [[ "$schema" =~ ^[0-9]+$ ]] || return 1
  if ((schema == 3 && STATE_SCHEMA_VERSION >= 4)); then
    needs_update=true
  elif ((schema == 4 && STATE_SCHEMA_VERSION == 5)); then
    needs_update=true
  elif jq -e '(.state.users | type == "array") and any(.state.users[]?; has("usage_offset_bytes") | not)' \
      "$file" >/dev/null 2>&1; then
    needs_update=true
  fi
  if [[ "$needs_update" == true ]]; then
    tmp="$(mktemp "$(dirname "$file")/.migration-schema.XXXXXX")" || return 1
    if ! jq --argjson schema "$STATE_SCHEMA_VERSION" '
      def endpoint_from_legacy:
        if (.protocol // "ss2022") == "anytls" then
          {protocol:"anytls",port:.port,anytls_password:.anytls_password,tls_sni:.tls_sni}
        else
          {protocol:"ss2022",port:.port,shadowtls_password:.shadowtls_password,
           ss2022_password:.ss2022_password,method:.method,shadowtls_sni:.shadowtls_sni}
        end;
      .state.users |= map(if has("usage_offset_bytes") then . else .usage_offset_bytes = 0 end) |
      if .state.schema_version == 3 and $schema >= 4 then
        .state.outbound_presets = (.state.outbound_presets // []) |
        .state.rule_presets = (.state.rule_presets // []) |
        .state.schema_version = 4
      else . end |
      if .state.schema_version == 4 and $schema == 5 then
        .state.users |= map(.protocol = (.protocol // "ss2022") | .endpoints = [endpoint_from_legacy]) |
        .state.schema_version = 5
      else . end
    ' "$file" > "$tmp"; then
      rm -f -- "$tmp"
      return 1
    fi
    chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
  fi
}

decrypt_migration_backup() {
  local bundle="$1" output="$2" password work encrypted
  work="$(mktemp -d /tmp/sb-migration-decrypt.XXXXXX)"
  register_temp_path "$work"
  if ! materialize_migration_bundle "$bundle" "$work"; then
    rm -rf "$work" "$output"; die "单文件迁移包结构或密文 SHA256 校验失败"
  fi
  encrypted="$MATERIALIZED_MIGRATION_ENCRYPTED"
  while true; do
    if ! read_backup_password; then rm -rf "$work" "$output"; return 1; fi
    password="$BACKUP_PASSWORD"; BACKUP_PASSWORD=""
    if ! verify_migration_auth_file "$encrypted" "$password"; then
      password=""; rm -f -- "$output"
      echo '密码错误，或迁移包已经损坏。请重新输入；如果多次失败，请重新复制原始备份。'
      continue
    fi
    if ! (umask 077; SB_BACKUP_PASSWORD="$password" openssl enc -d -aes-256-cbc -md sha256 -pbkdf2 -iter 200000 \
      -in "$encrypted" -out "$output" -pass env:SB_BACKUP_PASSWORD 2>/dev/null); then
      password=""; rm -f -- "$output"
      echo '无法解密备份，请重新输入密码；如果密码正确，请重新复制原始备份。'
      continue
    fi
    break
  done
  password=""; rm -rf "$work"; chmod 600 "$output"
  normalize_migration_payload_schema "$output" || { rm -f "$output"; die "迁移包中的旧数据无法安全升级"; }
  jq -e --argjson format "$MIGRATION_FORMAT_VERSION" '
    .format_version == $format and (.state|type=="object") and
    (.state.users|type=="array") and (.state.splits|type=="array") and
    (.state.outbound_presets|type=="array") and (.state.rule_presets|type=="array") and
    (.nfuse_usage|type=="array")
  ' "$output" >/dev/null || { rm -f "$output"; die "迁移包格式无效或版本不受支持"; }
}

show_migration_backup_details() {
  local plain
  ensure_migration_crypto_dependencies || return 0
  select_migration_backup || return 0
  plain="$(mktemp /tmp/sb-user-data-details.XXXXXX.json)"
  register_temp_path "$plain"
  decrypt_migration_backup "$SELECTED_MIGRATION_BACKUP" "$plain" || { rm -f -- "$plain"; MENU_RETURNED=true; return 0; }
  normalize_migration_payload_schema "$plain" || { rm -f -- "$plain"; die "迁移包中的旧数据无法安全升级"; }
  jq -r '
    "\n备份内容\n",
    "创建时间：\(.created_at)",
    "脚本版本：\(.script_version)",
    "来源主机：\(.source_hostname)",
    "用户数量：\(.state.users|length)",
    "分流数量：\(.state.splits|length)",
    "预置出口：\(.state.outbound_presets|length)",
    "预置规则：\(.state.rule_presets|length)",
    "流量记录：\(.nfuse_usage|length)",
    "数据格式版本：\(.state.schema_version)"
  ' "$plain"
  rm -f "$plain"
}

validate_migration_payload_structure() {
  local payload="$1" rule_url
  normalize_migration_payload_schema "$payload" || return 1
  jq -e --argjson schema "$STATE_SCHEMA_VERSION" '
    def valid_upstream:
      (type == "object") and
      (.server | type == "string" and length > 0) and
      (.server_port | type == "number" and . == floor and . >= 1 and . <= 65535) and
      if .protocol == "anytls" then
        (.password | type == "string" and length > 0) and
        (.sni | type == "string" and length > 0) and
        (.insecure | type == "boolean")
      elif .protocol == "shadowsocks" then
        (.method | type == "string" and length > 0) and
        (.password | type == "string" and length > 0)
      elif .protocol == "ss_shadowtls" then
        (.method | type == "string" and startswith("2022-")) and
        (.ss_password | type == "string" and length > 0) and
        (.shadowtls_password | type == "string" and length > 0) and
        (.sni | type == "string" and length > 0) and
        (.insecure | type == "boolean")
      else false end;
    (.state.users | map(.name)) as $user_names |
    (.state.outbound_presets | map(.name)) as $outbound_preset_names |
    (.state.rule_presets | map(.name)) as $rule_preset_names |
    .state.schema_version == $schema and
    (.state.outbound_presets | type == "array") and
    (.state.rule_presets | type == "array") and
    (.state.users | map(.name) as $values | ($values|length) == ($values|unique|length)) and
    ([.state.users[].endpoints[].port] as $values | ($values|length) == ($values|unique|length)) and
    (.state.splits | map(.name) as $values | ($values|length) == ($values|unique|length)) and
    (.state.splits | map(.outbound_tag // ("managed-out-" + .name)) as $values | ($values|length) == ($values|unique|length)) and
    (.state.splits | map(.rule_set_tag // ("managed-split-" + .name)) as $values | ($values|length) == ($values|unique|length)) and
    ($outbound_preset_names | length == (unique | length)) and
    ($rule_preset_names | length == (unique | length)) and
    ([.state.splits[] |
      (.outbound_tag // ("managed-out-" + .name)),
      (if (.upstream.protocol // "") == "ss_shadowtls" then ("managed-transport-" + .name) else empty end)
    ] as $values | ($values|length) == ($values|unique|length)) and
    (.nfuse_usage | map(.name) as $values | ($values|length) == ($values|unique|length)) and
    all(.state.users[];
      (.name|type=="string") and
      (.port|type=="number") and (.port == (.port|floor)) and (.port>=1 and .port<=65535) and
      (.status == "active" or .status == "disabled") and
      (.metered|type=="boolean") and
      (has("expires_at") and (.expires_at == null or (.expires_at|type=="string"))) and
      (has("limit_gib") and (.limit_gib == null or (((.limit_gib|type) == "number") and .limit_gib>0))) and
      (has("billing_anchor") and (.billing_anchor == null or (((.billing_anchor|type) == "number") and .billing_anchor==(.billing_anchor|floor) and .billing_anchor>=1))) and
      (has("usage_offset_bytes") and ((.usage_offset_bytes|type) == "number") and (.usage_offset_bytes == (.usage_offset_bytes|floor)) and (.usage_offset_bytes >= 0)) and
      (has("created_at") and ((.created_at|type) == "string" and length>0)) and
      (if .metered then (((.limit_gib|type) == "number") and .limit_gib>0) and (((.billing_anchor|type) == "number") and .billing_anchor==(.billing_anchor|floor) and .billing_anchor>=1) else true end) and
      (.endpoints | type == "array" and length >= 1 and length <= 2) and
      ([.endpoints[].protocol] | length == (unique | length)) and
      ([.endpoints[].port] | length == (unique | length)) and
      (.protocol == .endpoints[0].protocol) and (.port == .endpoints[0].port) and
      all(.endpoints[];
        (.port|type=="number") and (.port == (.port|floor)) and (.port>=1 and .port<=65535) and
        if .protocol == "anytls" then
          (.anytls_password|type=="string" and length>0) and (.tls_sni|type=="string" and length>0)
        elif .protocol == "ss2022" then
          (.shadowtls_password|type=="string" and length>0) and
          (.ss2022_password|type=="string" and length>0) and
          (.method=="2022-blake3-aes-128-gcm" or .method=="2022-blake3-aes-256-gcm") and
          (.shadowtls_sni|type=="string" and length>0)
        else false end) and
      if .protocol == "anytls" then
        (.anytls_password == .endpoints[0].anytls_password) and (.tls_sni == .endpoints[0].tls_sni)
      elif .protocol == "ss2022" then
        (.shadowtls_password == .endpoints[0].shadowtls_password) and
        (.ss2022_password == .endpoints[0].ss2022_password) and
        (.method == .endpoints[0].method) and
        (.shadowtls_sni == .endpoints[0].shadowtls_sni)
      else false end) and
    all(.state.splits[];
      (.name|type=="string" and test("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$")) and
      (.url|type=="string" and test("^https://") and test("\\.(srs|json)([?#].*)?$")) and
      (.scope=="all" or .scope=="user") and
      ((.scope=="all") or ((.user|type=="string") and (.user as $user | ($user_names | index($user)) != null))) and
      (.status=="active" or .status=="disabled") and
      ((.upstream | valid_upstream) or (.status == "disabled" and (.upstream | type == "object"))) and
      (((.outbound_preset // null) == null) or (.outbound_preset as $preset | ($outbound_preset_names | index($preset)) != null)) and
      (((.rule_preset // null) == null) or (.rule_preset as $preset | ($rule_preset_names | index($preset)) != null)) and
      ((.outbound_tag // ("managed-out-" + .name)) | test("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$") and . != "direct") and
      ((.rule_set_tag // ("managed-split-" + .name)) | test("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$") and . != "direct") and
      all([.runtime_rule_tag?,.runtime_outbound_tag?,.runtime_transport_tag?][];
        . == null or (type == "string" and test("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$") and . != "direct"))) and
    all(.state.outbound_presets[];
      (.name | type == "string" and test("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$")) and
      (.upstream | valid_upstream)) and
    all(.state.rule_presets[];
      (.name | type == "string" and test("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$")) and
      (.url | type == "string" and test("^https://") and test("\\.(srs|json)([?#].*)?$"))) and
    all(.nfuse_usage[];
      (.name|type=="string" and length>0) and
      (.used_bytes|type=="number") and
      (.used_bytes == (.used_bytes|floor)) and .used_bytes>=0)
  ' "$payload" >/dev/null || return 1
  while IFS= read -r rule_url; do
    [[ -n "$rule_url" ]] || continue
    validate_public_rule_set_url "$rule_url" || return 1
  done < <(jq -r '.state.splits[]?.url, .state.rule_presets[]?.url' "$payload")
}

inspect_migration_bundle_with_password() {
  local bundle="$1" password="$2" work encrypted plain
  MIGRATION_INSPECTION_RESULT="internal-error"
  work="$(mktemp -d /tmp/sb-migration-inspect.XXXXXX)" || return 1
  chmod 700 "$work" || { rm -rf -- "$work"; return 1; }
  register_temp_path "$work" || { rm -rf -- "$work"; return 1; }
  plain="$work/payload.json"
  if ! materialize_migration_bundle "$bundle" "$work"; then
    MIGRATION_INSPECTION_RESULT="${MIGRATION_MATERIALIZE_FAILURE:-structure-invalid}"
    rm -rf -- "$work"
    return 1
  fi
  encrypted="$MATERIALIZED_MIGRATION_ENCRYPTED"
  if ! verify_migration_auth_file "$encrypted" "$password"; then
    MIGRATION_INSPECTION_RESULT="password-mismatch"
    rm -rf -- "$work"
    return 1
  fi
  if ! (umask 077; SB_BACKUP_PASSWORD="$password" openssl enc -d -aes-256-cbc -md sha256 -pbkdf2 -iter 200000 \
    -in "$encrypted" -out "$plain" -pass env:SB_BACKUP_PASSWORD 2>/dev/null); then
    MIGRATION_INSPECTION_RESULT="payload-invalid"
    rm -rf -- "$work"
    return 1
  fi
  chmod 600 "$plain" || { rm -rf -- "$work"; return 1; }
  if ! validate_migration_payload_structure "$plain" >/dev/null 2>&1; then
    MIGRATION_INSPECTION_RESULT="payload-invalid"
    rm -rf -- "$work"
    return 1
  fi
  rm -rf -- "$work" || return 1
  MIGRATION_INSPECTION_RESULT="healthy"
}

check_all_migration_backups() {
  local password bundle name result
  local healthy=0 structure_invalid=0 checksum_failed=0 password_mismatch=0 payload_invalid=0 internal_error=0
  ensure_migration_crypto_dependencies || return 0
  load_migration_backups
  if ((${#MIGRATION_BACKUPS[@]} == 0)); then
    echo '暂无迁移备份可供体检。'
    return 0
  fi
  printf '将使用同一个密码只读体检本地 %s 份迁移备份；不同密码的备份会单独标记，不会被判为损坏。\n' \
    "${#MIGRATION_BACKUPS[@]}"
  if ! read_backup_password; then
    BACKUP_PASSWORD=""
    MENU_RETURNED=true
    echo '已取消批量体检。'
    return 0
  fi
  password="$BACKUP_PASSWORD"
  BACKUP_PASSWORD=""
  printf '\n体检结果\n'
  for bundle in "${MIGRATION_BACKUPS[@]}"; do
    name="$(basename "$bundle")"
    if inspect_migration_bundle_with_password "$bundle" "$password"; then
      result='健康'
      ((healthy+=1))
    else
      case "$MIGRATION_INSPECTION_RESULT" in
        structure-invalid) result='结构异常'; ((structure_invalid+=1));;
        checksum-failed) result='密文校验失败'; ((checksum_failed+=1));;
        password-mismatch) result='密码不匹配或认证失败'; ((password_mismatch+=1));;
        payload-invalid) result='解密后内容异常'; ((payload_invalid+=1));;
        *) result='内部检查失败'; ((internal_error+=1));;
      esac
    fi
    printf '  %s：%s\n' "$name" "$result"
  done
  password=""
  printf '\n汇总：健康 %s，结构异常 %s，密文校验失败 %s，密码不匹配或认证失败 %s，解密后内容异常 %s，内部检查失败 %s。\n' \
    "$healthy" "$structure_invalid" "$checksum_failed" "$password_mismatch" "$payload_invalid" "$internal_error"
  echo '批量体检完成；没有修改备份文件或服务器上的用户、分流、配置与服务。'
}

migration_update_json_file() {
  local file="$1" tmp
  shift
  tmp="$(mktemp "$(dirname "$file")/.migration-update.XXXXXX")" || return 1
  if ! jq "$@" "$file" > "$tmp"; then rm -f -- "$tmp"; return 1; fi
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -- "$tmp" "$file"
}

prompt_migration_choice() {
  local prompt="$1" default="$2" pattern="$3" choice
  while true; do
    if ! read -r -p "$prompt" choice; then return 1; fi
    choice="${choice:-$default}"
    if [[ "$choice" =~ $pattern ]]; then MIGRATION_CHOICE="$choice"; return 0; fi
    echo '输入的编号无效，请按照上方菜单重新选择。'
  done
}

select_migration_restore_mode() {
  cat <<'EOF'

恢复方式：
  1. 合并到这台服务器（推荐；保留已有用户和分流）
  2. 完全恢复成备份内容（会删除这台服务器现有的用户和分流）
  0. 返回上一级
EOF
  prompt_migration_choice '请选择恢复方式 [1]：' 1 '^[0-2]$' || return 1
  case "$MIGRATION_CHOICE" in
    1) MIGRATION_RESTORE_MODE=merge;;
    2) MIGRATION_RESTORE_MODE=replace;;
    0) MENU_RETURNED=true; return 1;;
  esac
}

migration_user_conflict() {
  local payload="$1" candidate="$2" replace_name="$3" normalized="$4"
  local name port protocol tag owner endpoint
  local -a tags
  MIGRATION_CONFLICT_REASON=""
  name="$(jq -r '.name' <<<"$candidate")"
  if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$ ]]; then
    MIGRATION_CONFLICT_REASON="用户名不符合规则：$name"; return 0
  fi
  owner="$(jq -r --arg replace "$replace_name" --arg name "$name" '.state.users[]? | select(.name != $replace and .name == $name) | .name' "$payload" | head -n1)"
  if [[ -n "$owner" ]]; then
    MIGRATION_CONFLICT_REASON="用户名已存在：$name"; return 0
  fi
  while IFS= read -r endpoint; do
    [[ -n "$endpoint" ]] || continue
    port="$(jq -r '.port' <<<"$endpoint")"
    protocol="$(jq -r '.protocol' <<<"$endpoint")"
    if [[ ! "$port" =~ ^[0-9]+$ ]] || ((10#$port < 1 || 10#$port > 65535)); then
      MIGRATION_CONFLICT_REASON="端口必须位于 1-65535：$port"; return 0
    fi
    owner="$(jq -r --arg name "$replace_name" --argjson port "$port" '
      .state.users[]? | select(.name != $name and any(.endpoints[]; .port == $port)) | .name
    ' "$payload" | head -n1)"
    if [[ -n "$owner" ]]; then
      MIGRATION_CONFLICT_REASON="端口 $port 已由目标用户 $owner 使用"; return 0
    fi
    if port_is_listening "$port" && ! jq -e --argjson port "$port" '
      any(.users[]?; any(if (.endpoints | type) == "array" then .endpoints[] else {port:.port} end; .port == $port))
    ' "$STATE_FILE" >/dev/null; then
      MIGRATION_CONFLICT_REASON="端口 $port 已被目标服务器上的其他服务监听"; return 0
    fi
    while IFS= read -r tag; do
      [[ -n "$tag" ]] || continue
      if ! current_state_owns_tag "$tag"; then
        MIGRATION_CONFLICT_REASON="端口 ${port} 已被其他连接配置占用（${tag}）"; return 0
      fi
    done < <(jq -r --argjson port "$port" '.inbounds[]? | select(.listen_port == $port) | (.tag // "")' "$normalized")
    if [[ "$protocol" == anytls ]]; then tags=("anytls-$name"); else tags=("st-$name" "ss-$name" "ss-udp-$name"); fi
    for tag in "${tags[@]}"; do
      if jq -e --arg tag "$tag" '.inbounds[]? | select(.tag == $tag)' "$normalized" >/dev/null && ! current_state_owns_tag "$tag"; then
        MIGRATION_CONFLICT_REASON="连接名称已被其他配置占用：$tag"; return 0
      fi
    done
  done < <(jq -c '.endpoints[]' <<<"$candidate")
  return 1
}

prompt_migration_user_reconfigure() {
  local incoming="$1" payload="$2" replace_name="$3" normalized="$4"
  local original_name original_port name port candidate count index protocol label
  original_name="$(jq -r '.name' <<<"$incoming")"
  while true; do
    read -r -p "新用户名 [${original_name}]（输入 0 取消合并）：" name
    [[ "$name" != 0 ]] || { MIGRATION_MERGE_CANCELLED=true; return 1; }
    name="${name:-$original_name}"
    if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$ ]]; then
      echo '用户名只能包含字母、数字、下划线和连字符，长度 1-32。'; continue
    fi
    candidate="$(jq -c --arg name "$name" '.name=$name' <<<"$incoming")" || return 1
    count="$(jq '.endpoints | length' <<<"$candidate")" || return 1
    for ((index=0; index<count; index++)); do
      original_port="$(jq -r --argjson index "$index" '.endpoints[$index].port' <<<"$incoming")"
      protocol="$(jq -r --argjson index "$index" '.endpoints[$index].protocol' <<<"$incoming")"
      [[ "$protocol" == anytls ]] && label=AnyTLS || label='SS2022 + ShadowTLS'
      read -r -p "${label} 新端口 [${original_port}]（输入 0 取消合并）：" port
      [[ "$port" != 0 ]] || { MIGRATION_MERGE_CANCELLED=true; return 1; }
      port="${port:-$original_port}"
      candidate="$(jq -c --argjson index "$index" --argjson port "$port" '
        .endpoints[$index].port=$port | if $index == 0 then .port=$port else . end
      ' <<<"$candidate" 2>/dev/null)" || { echo '端口必须是整数。'; candidate=""; break; }
    done
    [[ -n "$candidate" ]] || continue
    if migration_user_conflict "$payload" "$candidate" "$replace_name" "$normalized"; then
      echo "无法使用该用户名或端口：$MIGRATION_CONFLICT_REASON"; continue
    fi
    MIGRATION_CONFIGURED_ENTITY="$candidate"
    return 0
  done
}

migration_split_conflict() {
  local payload="$1" candidate="$2" replace_name="$3" normalized="$4"
  local name out_tag rule_tag protocol transport_tag owner
  MIGRATION_CONFLICT_REASON=""
  name="$(jq -r '.name' <<<"$candidate")"
  out_tag="$(jq -r '.outbound_tag // ("managed-out-" + .name)' <<<"$candidate")"
  rule_tag="$(jq -r '.rule_set_tag // ("managed-split-" + .name)' <<<"$candidate")"
  protocol="$(jq -r '.upstream.protocol // ""' <<<"$candidate")"
  transport_tag="managed-transport-$name"
  for owner in "$name" "$out_tag" "$rule_tag"; do
    if [[ ! "$owner" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$ ]]; then
      MIGRATION_CONFLICT_REASON="分流名称或内部名称不符合规则：$owner"; return 0
    fi
  done
  if [[ "$out_tag" == direct || "$rule_tag" == direct ]]; then
    MIGRATION_CONFLICT_REASON='direct 是系统保留标签'; return 0
  fi
  owner="$(jq -r --arg replace "$replace_name" --arg name "$name" '.state.splits[]? | select(.name != $replace and .name == $name) | .name' "$payload" | head -n1)"
  if [[ -n "$owner" ]]; then MIGRATION_CONFLICT_REASON="分流名称已存在：$name"; return 0; fi
  owner="$(jq -r --arg replace "$replace_name" --arg out "$out_tag" '
    .state.splits[]? | select(.name != $replace and (
      (.outbound_tag // ("managed-out-" + .name)) == $out or
      ((.upstream.protocol // "") == "ss_shadowtls" and ("managed-transport-" + .name) == $out)
    )) | .name
  ' "$payload" | head -n1)"
  if [[ -n "$owner" ]]; then MIGRATION_CONFLICT_REASON="出口名称 $out_tag 已由分流 $owner 使用"; return 0; fi
  owner="$(jq -r --arg replace "$replace_name" --arg tag "$rule_tag" '
    .state.splits[]? | select(.name != $replace and (.rule_set_tag // ("managed-split-" + .name)) == $tag) | .name
  ' "$payload" | head -n1)"
  if [[ -n "$owner" ]]; then MIGRATION_CONFLICT_REASON="规则名称 $rule_tag 已由分流 $owner 使用"; return 0; fi
  if [[ "$protocol" == ss_shadowtls ]]; then
    owner="$(jq -r --arg replace "$replace_name" --arg tag "$transport_tag" '
      .state.splits[]? | select(.name != $replace and (
        (.outbound_tag // ("managed-out-" + .name)) == $tag or
        ((.upstream.protocol // "") == "ss_shadowtls" and ("managed-transport-" + .name) == $tag)
      )) | .name
    ' "$payload" | head -n1)"
    if [[ -n "$owner" ]]; then MIGRATION_CONFLICT_REASON="ShadowTLS 传输标签 $transport_tag 与分流 $owner 冲突"; return 0; fi
  fi
  if jq -e --arg tag "$out_tag" '.outbounds[]? | select(.tag == $tag)' "$normalized" >/dev/null && ! current_state_owns_tag "$out_tag"; then
    MIGRATION_CONFLICT_REASON="出口名称已被其他配置占用：$out_tag"; return 0
  fi
  if [[ "$protocol" == ss_shadowtls ]] &&
     jq -e --arg tag "$transport_tag" '.outbounds[]? | select(.tag == $tag)' "$normalized" >/dev/null &&
     ! current_state_owns_tag "$transport_tag"; then
    MIGRATION_CONFLICT_REASON="系统内部名称已被其他配置占用：$transport_tag"; return 0
  fi
  if jq -e --arg tag "$rule_tag" '.route.rule_set[]? | select(.tag == $tag)' "$normalized" >/dev/null && ! current_state_owns_tag "$rule_tag"; then
    MIGRATION_CONFLICT_REASON="规则名称已被其他配置占用：$rule_tag"; return 0
  fi
  return 1
}

prompt_migration_split_reconfigure() {
  local incoming="$1" payload="$2" replace_name="$3" normalized="$4"
  local original_name original_out original_rule name out_tag rule_tag candidate
  original_name="$(jq -r '.name' <<<"$incoming")"
  original_out="$(jq -r '.outbound_tag // ("managed-out-" + .name)' <<<"$incoming")"
  original_rule="$(jq -r '.rule_set_tag // ("managed-split-" + .name)' <<<"$incoming")"
  while true; do
    read -r -p "新分流名称 [${original_name}]（输入 0 取消合并）：" name
    [[ "$name" != 0 ]] || { MIGRATION_MERGE_CANCELLED=true; return 1; }
    name="${name:-$original_name}"
    read -r -p "新出口名称 [${original_out}]（用于区分这条分流，例如 ai-out；输入 0 取消）：" out_tag
    [[ "$out_tag" != 0 ]] || { MIGRATION_MERGE_CANCELLED=true; return 1; }
    out_tag="${out_tag:-$original_out}"
    read -r -p "新规则名称 [${original_rule}]（用于区分规则，例如 ai-rule；输入 0 取消）：" rule_tag
    [[ "$rule_tag" != 0 ]] || { MIGRATION_MERGE_CANCELLED=true; return 1; }
    rule_tag="${rule_tag:-$original_rule}"
    candidate="$(jq -c --arg name "$name" --arg out "$out_tag" --arg rule "$rule_tag" '.name=$name | .outbound_tag=$out | .rule_set_tag=$rule' <<<"$incoming")"
    if migration_split_conflict "$payload" "$candidate" "$replace_name" "$normalized"; then
      echo "这个名称无法使用：$MIGRATION_CONFLICT_REASON"; continue
    fi
    MIGRATION_CONFIGURED_ENTITY="$candidate"
    return 0
  done
}

migration_unique_preset_name() {
  local payload="$1" collection="$2" original="$3" base candidate suffix=1 max_base
  base="${original:0:23}-imported"
  candidate="$base"
  while jq -e --arg name "$candidate" ".state.${collection}[]? | select(.name == \$name)" "$payload" >/dev/null; do
    suffix=$((suffix + 1))
    max_base=$((32 - ${#suffix} - 1))
    candidate="${base:0:max_base}-${suffix}"
  done
  printf '%s' "$candidate"
}

build_merge_migration_payload() {
  local source="$1" output="$2" current_nfuse normalized incoming candidate usage
  local source_name final_name choice action replace_name scope scope_user mapped_user
  local split_name preset_name mapped_preset unique_name
  local user_map='{}' outbound_preset_map='{}' rule_preset_map='{}'
  normalize_migration_payload_schema "$source" || return 1
  current_nfuse="$(nfuse list --json)" || return 1
  jq -e 'type == "array"' <<<"$current_nfuse" >/dev/null || return 1
  normalized="$(mktemp /tmp/sb-migration-merge-config.XXXXXX)" || return 1
  register_temp_path "$normalized"
  "$SINGBOX_BIN" format -c "$SINGBOX_CONFIG" > "$normalized" || { rm -f -- "$normalized"; return 1; }
  jq --slurpfile current "$STATE_FILE" --argjson nfuse "$current_nfuse" --argjson schema "$STATE_SCHEMA_VERSION" '
    def endpoint_from_legacy:
      if (.protocol // "ss2022") == "anytls" then
        {protocol:"anytls",port:.port,anytls_password:.anytls_password,tls_sni:.tls_sni}
      else
        {protocol:"ss2022",port:.port,shadowtls_password:.shadowtls_password,
         ss2022_password:.ss2022_password,method:.method,shadowtls_sni:.shadowtls_sni}
      end;
    ($current[0] |
      .users |= map(
        .protocol = (.protocol // "ss2022") |
        if has("usage_offset_bytes") then . else .usage_offset_bytes = 0 end |
        if (.endpoints | type) == "array" then . else .endpoints = [endpoint_from_legacy] end
      )) as $current_state |
    . + {restore_mode:"merge",state:($current_state + {
        schema_version:$schema,
        outbound_presets:($current_state.outbound_presets // []),
        rule_presets:($current_state.rule_presets // [])
      }),nfuse_usage:$nfuse,
      merge_summary:{
        users:{imported:0,replaced:0,renamed:0,skipped:0},
        splits:{imported:0,replaced:0,renamed:0,skipped:0},
        outbound_presets:{imported:0,renamed:0,deduplicated:0},
        rule_presets:{imported:0,renamed:0,deduplicated:0}
      }}
  ' "$source" > "$output" || { rm -f -- "$normalized"; return 1; }
  chmod 600 "$output"
  MIGRATION_MERGE_CANCELLED=false

  while IFS= read -r incoming <&3; do
    [[ -n "$incoming" ]] || continue
    preset_name="$(jq -r '.name' <<<"$incoming")"
    mapped_preset="$preset_name"
    if jq -e --arg name "$preset_name" '.state.outbound_presets[]? | select(.name == $name)' "$output" >/dev/null; then
      if SB_JQ_INCOMING="$incoming" jq -e --arg name "$preset_name" '($ENV.SB_JQ_INCOMING | fromjson) as $incoming | .state.outbound_presets[] | select(.name == $name and .upstream == $incoming.upstream)' "$output" >/dev/null; then
        migration_update_json_file "$output" '.merge_summary.outbound_presets.deduplicated += 1' || return 1
      else
        unique_name="$(migration_unique_preset_name "$output" outbound_presets "$preset_name")" || return 1
        mapped_preset="$unique_name"
        candidate="$(jq -c --arg name "$unique_name" '.name=$name' <<<"$incoming")" || return 1
        SB_JQ_PRESET="$candidate" migration_update_json_file "$output" '($ENV.SB_JQ_PRESET | fromjson) as $preset | .state.outbound_presets += [$preset] | .merge_summary.outbound_presets.renamed += 1' || return 1
      fi
    else
      SB_JQ_PRESET="$incoming" migration_update_json_file "$output" '($ENV.SB_JQ_PRESET | fromjson) as $preset | .state.outbound_presets += [$preset] | .merge_summary.outbound_presets.imported += 1' || return 1
    fi
    outbound_preset_map="$(jq -c --arg key "$preset_name" --arg value "$mapped_preset" '. + {($key):$value}' <<<"$outbound_preset_map")" || return 1
  done 3< <(jq -c '.state.outbound_presets[]' "$source")

  while IFS= read -r incoming <&3; do
    [[ -n "$incoming" ]] || continue
    preset_name="$(jq -r '.name' <<<"$incoming")"
    mapped_preset="$preset_name"
    if jq -e --arg name "$preset_name" '.state.rule_presets[]? | select(.name == $name)' "$output" >/dev/null; then
      if SB_JQ_INCOMING="$incoming" jq -e --arg name "$preset_name" '($ENV.SB_JQ_INCOMING | fromjson) as $incoming | .state.rule_presets[] | select(.name == $name and .url == $incoming.url)' "$output" >/dev/null; then
        migration_update_json_file "$output" '.merge_summary.rule_presets.deduplicated += 1' || return 1
      else
        unique_name="$(migration_unique_preset_name "$output" rule_presets "$preset_name")" || return 1
        mapped_preset="$unique_name"
        candidate="$(jq -c --arg name "$unique_name" '.name=$name' <<<"$incoming")" || return 1
        SB_JQ_PRESET="$candidate" migration_update_json_file "$output" '($ENV.SB_JQ_PRESET | fromjson) as $preset | .state.rule_presets += [$preset] | .merge_summary.rule_presets.renamed += 1' || return 1
      fi
    else
      SB_JQ_PRESET="$incoming" migration_update_json_file "$output" '($ENV.SB_JQ_PRESET | fromjson) as $preset | .state.rule_presets += [$preset] | .merge_summary.rule_presets.imported += 1' || return 1
    fi
    rule_preset_map="$(jq -c --arg key "$preset_name" --arg value "$mapped_preset" '. + {($key):$value}' <<<"$rule_preset_map")" || return 1
  done 3< <(jq -c '.state.rule_presets[]' "$source")

  while IFS= read -r incoming <&3; do
    [[ -n "$incoming" ]] || continue
    source_name="$(jq -r '.name' <<<"$incoming")"
    candidate="$incoming"; action=imported; replace_name=""
    if jq -e --arg name "$source_name" '.state.users[]? | select(.name == $name)' "$output" >/dev/null; then
      printf '\n发现同名用户：%s\n' "$source_name"
      jq -r --arg name "$source_name" '
        .state.users[] | select(.name == $name) |
        "  这台服务器：" + ([.endpoints[] |
          (if .protocol == "anytls" then "AnyTLS" else "SS2022 + ShadowTLS" end) + " 端口 " + (.port|tostring)] | join(" / "))
      ' "$output"
      jq -r '
        "  备份中用户：" + ([.endpoints[] |
          (if .protocol == "anytls" then "AnyTLS" else "SS2022 + ShadowTLS" end) + " 端口 " + (.port|tostring)] | join(" / "))
      ' <<<"$incoming"
      cat <<'EOF'
  1. 保留这台服务器上的用户，跳过备份用户（推荐）
  2. 使用备份用户覆盖同名用户（原客户端配置可能失效）
  3. 把备份用户作为新用户导入（重新填写名称和端口）
  0. 返回，不执行任何恢复
EOF
      prompt_migration_choice '请选择 [1]：' 1 '^[0-3]$'; choice="$MIGRATION_CHOICE"
      case "$choice" in
        1) user_map="$(jq -c --arg key "$source_name" --arg value "$source_name" '. + {($key):$value}' <<<"$user_map")"; migration_update_json_file "$output" '.merge_summary.users.skipped += 1' || return 1; continue;;
        2) action=replaced; replace_name="$source_name";;
        3) action=renamed; prompt_migration_user_reconfigure "$incoming" "$output" "" "$normalized" || { rm -f -- "$normalized"; return 1; }; candidate="$MIGRATION_CONFIGURED_ENTITY";;
        0) MIGRATION_MERGE_CANCELLED=true; rm -f -- "$normalized"; return 1;;
      esac
    fi
    if migration_user_conflict "$output" "$candidate" "$replace_name" "$normalized"; then
      printf '\n备份中的用户 %s 暂时无法导入：%s\n' "$source_name" "$MIGRATION_CONFLICT_REASON"
      cat <<'EOF'
  1. 修改名称或端口后继续导入
  2. 不导入这个用户（推荐）
  0. 返回，不执行任何恢复
EOF
      prompt_migration_choice '请选择 [2]：' 2 '^[0-2]$'; choice="$MIGRATION_CHOICE"
      case "$choice" in
        1) action=renamed; replace_name=""; prompt_migration_user_reconfigure "$incoming" "$output" "" "$normalized" || { rm -f -- "$normalized"; return 1; }; candidate="$MIGRATION_CONFIGURED_ENTITY";;
        2) user_map="$(jq -c --arg key "$source_name" --arg value "" '. + {($key):$value}' <<<"$user_map")"; migration_update_json_file "$output" '.merge_summary.users.skipped += 1' || return 1; continue;;
        0) MIGRATION_MERGE_CANCELLED=true; rm -f -- "$normalized"; return 1;;
      esac
    fi
    final_name="$(jq -r '.name' <<<"$candidate")"
    user_map="$(jq -c --arg key "$source_name" --arg value "$final_name" '. + {($key):$value}' <<<"$user_map")"
    usage="$(jq -c --arg name "$source_name" 'first(.nfuse_usage[]? | select(.name == $name)) // null' "$source")"
    if [[ "$action" == replaced ]]; then
      SB_JQ_USER="$candidate" migration_update_json_file "$output" --arg name "$source_name" --arg final "$final_name" --argjson usage "$usage" '
        ($ENV.SB_JQ_USER | fromjson) as $user |
        .state.users |= map(if .name == $name then $user else . end) |
        .nfuse_usage = [.nfuse_usage[] | select(.name != $name and .name != $final)] |
        (if $usage == null then . else .nfuse_usage += [($usage | .name=$final)] end) |
        .merge_summary.users.replaced += 1
      ' || { rm -f -- "$normalized"; return 1; }
    else
      SB_JQ_USER="$candidate" migration_update_json_file "$output" --arg final "$final_name" --argjson usage "$usage" --arg action "$action" '
        ($ENV.SB_JQ_USER | fromjson) as $user |
        .state.users += [$user] |
        .nfuse_usage = [.nfuse_usage[] | select(.name != $final)] |
        (if $usage == null then . else .nfuse_usage += [($usage | .name=$final)] end) |
        if $action == "renamed" then .merge_summary.users.renamed += 1 else .merge_summary.users.imported += 1 end
      ' || { rm -f -- "$normalized"; return 1; }
    fi
  done 3< <(jq -c '.state.users[]' "$source")

  while IFS= read -r incoming <&3; do
    [[ -n "$incoming" ]] || continue
    split_name="$(jq -r '.name' <<<"$incoming")"; candidate="$incoming"; action=imported; replace_name=""
    preset_name="$(jq -r '.outbound_preset // ""' <<<"$candidate")"
    if [[ -n "$preset_name" ]]; then
      mapped_preset="$(jq -r --arg key "$preset_name" '.[$key] // ""' <<<"$outbound_preset_map")"
      if [[ -n "$mapped_preset" ]]; then candidate="$(jq -c --arg preset "$mapped_preset" '.outbound_preset=$preset' <<<"$candidate")"; else candidate="$(jq -c 'del(.outbound_preset)' <<<"$candidate")"; fi
    fi
    preset_name="$(jq -r '.rule_preset // ""' <<<"$candidate")"
    if [[ -n "$preset_name" ]]; then
      mapped_preset="$(jq -r --arg key "$preset_name" '.[$key] // ""' <<<"$rule_preset_map")"
      if [[ -n "$mapped_preset" ]]; then candidate="$(jq -c --arg preset "$mapped_preset" '.rule_preset=$preset' <<<"$candidate")"; else candidate="$(jq -c 'del(.rule_preset)' <<<"$candidate")"; fi
    fi
    scope="$(jq -r '.scope // "all"' <<<"$candidate")"
    if [[ "$scope" == user ]]; then
      scope_user="$(jq -r '.user // ""' <<<"$candidate")"
      mapped_user="$(jq -r --arg key "$scope_user" 'if has($key) then .[$key] else $key end' <<<"$user_map")"
      if [[ -z "$mapped_user" ]] || ! jq -e --arg name "$mapped_user" '.state.users[]? | select(.name == $name)' "$output" >/dev/null; then
      printf '\n已跳过分流 %s：它指定的用户 %s 没有导入。\n' "$split_name" "$scope_user"
        migration_update_json_file "$output" '.merge_summary.splits.skipped += 1' || return 1
        continue
      fi
      candidate="$(jq -c --arg user "$mapped_user" '.user=$user' <<<"$candidate")"
    fi
    if jq -e --arg name "$split_name" '.state.splits[]? | select(.name == $name)' "$output" >/dev/null; then
      printf '\n发现同名分流：%s\n' "$split_name"
      cat <<'EOF'
  1. 保留这台服务器上的分流，跳过备份分流（推荐）
  2. 使用备份分流覆盖同名分流
  3. 把备份分流作为新分流导入（需要重新命名）
  0. 返回，不执行任何恢复
EOF
      prompt_migration_choice '请选择 [1]：' 1 '^[0-3]$'; choice="$MIGRATION_CHOICE"
      case "$choice" in
        1) migration_update_json_file "$output" '.merge_summary.splits.skipped += 1' || return 1; continue;;
        2) action=replaced; replace_name="$split_name";;
        3) action=renamed; prompt_migration_split_reconfigure "$candidate" "$output" "" "$normalized" || { rm -f -- "$normalized"; return 1; }; candidate="$MIGRATION_CONFIGURED_ENTITY";;
        0) MIGRATION_MERGE_CANCELLED=true; rm -f -- "$normalized"; return 1;;
      esac
    fi
    if migration_split_conflict "$output" "$candidate" "$replace_name" "$normalized"; then
      printf '\n备份中的分流 %s 暂时无法导入：%s\n' "$split_name" "$MIGRATION_CONFLICT_REASON"
      cat <<'EOF'
  1. 修改名称后继续导入
  2. 不导入这个分流（推荐）
  0. 返回，不执行任何恢复
EOF
      prompt_migration_choice '请选择 [2]：' 2 '^[0-2]$'; choice="$MIGRATION_CHOICE"
      case "$choice" in
        1) action=renamed; replace_name=""; prompt_migration_split_reconfigure "$candidate" "$output" "" "$normalized" || { rm -f -- "$normalized"; return 1; }; candidate="$MIGRATION_CONFIGURED_ENTITY";;
        2) migration_update_json_file "$output" '.merge_summary.splits.skipped += 1' || return 1; continue;;
        0) MIGRATION_MERGE_CANCELLED=true; rm -f -- "$normalized"; return 1;;
      esac
    fi
    candidate="$(normalize_split_runtime_tags_json "$candidate")" || { rm -f -- "$normalized"; return 1; }
    if [[ "$action" == replaced ]]; then
      SB_JQ_SPLIT="$candidate" migration_update_json_file "$output" --arg name "$split_name" '
        ($ENV.SB_JQ_SPLIT | fromjson) as $split |
        .state.splits |= map(if .name == $name then $split else . end) | .merge_summary.splits.replaced += 1
      ' || { rm -f -- "$normalized"; return 1; }
    else
      SB_JQ_SPLIT="$candidate" migration_update_json_file "$output" --arg action "$action" '
        ($ENV.SB_JQ_SPLIT | fromjson) as $split |
        .state.splits += [$split] |
        if $action == "renamed" then .merge_summary.splits.renamed += 1 else .merge_summary.splits.imported += 1 end
      ' || { rm -f -- "$normalized"; return 1; }
    fi
  done 3< <(jq -c '.state.splits[]' "$source")
  rm -f -- "$normalized"
  validate_migration_payload_structure "$output"
}

prepare_migration_effective_payload() {
  local source="$1" output="$2"
  select_migration_restore_mode || return 1
  if [[ "$MIGRATION_RESTORE_MODE" == merge ]]; then
    if ! build_merge_migration_payload "$source" "$output"; then
      [[ "${MIGRATION_MERGE_CANCELLED:-false}" == true ]] && { echo '已取消合并，未修改服务器。'; return 1; }
      die "无法生成恢复方案，服务器尚未被修改。请根据上方提示处理后重试"
    fi
  else
    jq '
      (.state.users | map(.name)) as $managed_names |
      . + {restore_mode:"replace"} |
      .nfuse_usage = [.nfuse_usage[] as $account | select($managed_names | index($account.name)) | $account]
    ' "$source" > "$output" || return 1
    chmod 600 "$output"
  fi
}

prepare_migration_payload_files() {
  local bundle="$1" source_payload="$2" payload="$3"
  decrypt_migration_backup "$bundle" "$source_payload" || {
    rm -f "$source_payload" "$payload"
    MENU_RETURNED=true
    return 1
  }
  normalize_migration_payload_schema "$source_payload" || {
    rm -f "$source_payload" "$payload"
    die "迁移包中的旧数据无法安全升级"
  }
  validate_migration_payload_structure "$source_payload" || {
    rm -f "$source_payload" "$payload"
    die "迁移数据结构无效"
  }
  if ! prepare_migration_effective_payload "$source_payload" "$payload"; then
    rm -f "$source_payload" "$payload"
    return 1
  fi
}

current_state_owns_tag() {
  local tag="$1" rows split runtime_tag
  jq -e --arg tag "$tag" '
    any(.users[]?;
      . as $user | any(if (.endpoints | type) == "array" then .endpoints[] else {protocol:(.protocol // "ss2022")} end;
        if .protocol == "anytls" then $tag==("anytls-"+$user.name)
        else ($tag==("st-"+$user.name) or $tag==("ss-"+$user.name) or $tag==("ss-udp-"+$user.name)) end)) or
    any(.splits[]?;
      $tag==(.outbound_tag // ("managed-out-"+.name)) or
      $tag==(.rule_set_tag // ("managed-split-"+.name)) or
      $tag==("managed-transport-"+.name) or
      $tag==(.runtime_outbound_tag // "") or
      $tag==(.runtime_rule_tag // "") or
      $tag==(.runtime_transport_tag // ""))
  ' "$STATE_FILE" >/dev/null && return 0
  rows="$(jq -c '.splits[]?' "$STATE_FILE")" || return 1
  while IFS= read -r split; do
    [[ -n "$split" ]] || continue
    runtime_tag="$(split_runtime_rule_tag_from_json "$split")" || return 1
    [[ "$runtime_tag" != "$tag" ]] || return 0
    runtime_tag="$(split_runtime_out_tag_from_json "$split")" || return 1
    [[ "$runtime_tag" != "$tag" ]] || return 0
    runtime_tag="$(split_runtime_transport_tag_from_json "$split")" || return 1
    [[ "$runtime_tag" != "$tag" ]] || return 0
  done <<<"$rows"
  return 1
}

add_migration_conflict() {
  MIGRATION_CONFLICTS[${#MIGRATION_CONFLICTS[@]}]="$1"
}

collect_migration_conflicts() {
  local payload="$1" normalized user name port tag split out_tag rule_tag protocol transport_tag endpoint
  local -a tags
  MIGRATION_CONFLICTS=()
  if ! validate_migration_payload_structure "$payload"; then
    add_migration_conflict "迁移数据结构、用户名称或端口存在异常"; return 0
  fi
  normalized="$(mktemp /tmp/sb-migration-config.XXXXXX)"
  register_temp_path "$normalized"
  if ! "$SINGBOX_BIN" format -c "$SINGBOX_CONFIG" > "$normalized"; then
    rm -f "$normalized"; add_migration_conflict "无法读取目标 sing-box 配置"; return 0
  fi
  while IFS= read -r user; do
    name="$(jq -r '.name' <<<"$user")"
    if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$ ]]; then
      add_migration_conflict "用户名不符合规则：$name"; continue
    fi
    while IFS= read -r endpoint; do
      port="$(jq -r '.port' <<<"$endpoint")"
      protocol="$(jq -r '.protocol' <<<"$endpoint")"
      if port_is_listening "$port" && ! jq -e --argjson port "$port" '
        any(.users[]?; any(if (.endpoints | type) == "array" then .endpoints[] else {port:.port} end; .port==$port))
      ' "$STATE_FILE" >/dev/null; then
        add_migration_conflict "端口 $port 已被目标服务器上的其他服务监听"
      fi
      while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        current_state_owns_tag "$tag" || add_migration_conflict "端口 ${port} 已被其他连接配置占用（${tag}）"
      done < <(jq -r --argjson port "$port" '.inbounds[]? | select(.listen_port==$port) | (.tag//"")' "$normalized")
      if [[ "$protocol" == anytls ]]; then tags=("anytls-$name"); else tags=("st-$name" "ss-$name" "ss-udp-$name"); fi
      for tag in "${tags[@]}"; do
        if jq -e --arg tag "$tag" '.inbounds[]? | select(.tag==$tag)' "$normalized" >/dev/null && ! current_state_owns_tag "$tag"; then
          add_migration_conflict "连接名称已被其他配置占用：$tag"
        fi
      done
    done < <(jq -c '.endpoints[]' <<<"$user")
  done < <(jq -c '.state.users[]' "$payload")
  while IFS= read -r split; do
    out_tag="$(split_runtime_out_tag_from_json "$split")" || { add_migration_conflict "无法读取分流出口信息"; continue; }
    rule_tag="$(split_runtime_rule_tag_from_json "$split")" || { add_migration_conflict "无法读取分流规则信息"; continue; }
    protocol="$(jq -r '.upstream.protocol // ""' <<<"$split")"
    transport_tag="$(split_runtime_transport_tag_from_json "$split")" || { add_migration_conflict "无法读取分流连接信息"; continue; }
    for tag in "$out_tag" "$rule_tag"; do
      if [[ ! "$tag" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$ || "$tag" == direct ]]; then
        add_migration_conflict "出口名称或规则名称不符合规则：$tag"
      fi
    done
    if jq -e --arg out "$out_tag" '.outbounds[]? | select(.tag==$out)' "$normalized" >/dev/null &&
       ! current_state_owns_tag "$out_tag"; then
      add_migration_conflict "出口名称已被其他配置占用：$out_tag"
    fi
    if jq -e --arg tag "$rule_tag" '.route.rule_set[]? | select(.tag==$tag)' "$normalized" >/dev/null &&
       ! current_state_owns_tag "$rule_tag"; then
      add_migration_conflict "规则名称已被其他配置占用：$rule_tag"
    fi
    if [[ "$protocol" == ss_shadowtls ]] &&
       jq -e --arg tag "$transport_tag" '.outbounds[]? | select(.tag==$tag)' "$normalized" >/dev/null &&
       ! current_state_owns_tag "$transport_tag"; then
      add_migration_conflict "ShadowTLS 内部名称已被其他配置占用：$transport_tag"
    fi
  done < <(jq -c '.state.splits[]' "$payload")
  rm -f "$normalized"
}

preflight_migration_payload() {
  local payload="$1" conflict
  collect_migration_conflicts "$payload"
  if ((${#MIGRATION_CONFLICTS[@]}>0)); then
    printf '现在还不能恢复，共发现 %s 个问题：\n' "${#MIGRATION_CONFLICTS[@]}" >&2
    for conflict in "${MIGRATION_CONFLICTS[@]}"; do printf '  - %s\n' "$conflict" >&2; done
    return 1
  fi
}

migration_entity_change_rows() {
  local payload="$1" key="$2" entity_label="$3"
  jq -r --slurpfile current "$STATE_FILE" --arg key "$key" --arg entity_label "$entity_label" '
    ($current[0][$key] // []) as $old | (.state[$key] // []) as $new |
    ($old|map(.name)) as $old_names | ($new|map(.name)) as $new_names |
    (($new_names-$old_names)[] | ["新增",$entity_label,.] | @tsv),
    (($old_names-$new_names)[] | ["删除",$entity_label,.] | @tsv),
    (($new_names-($new_names-$old_names))[] as $name |
      ($old[]|select(.name==$name)) as $before | ($new[]|select(.name==$name)) as $after |
      select($before!=$after) | ["替换",$entity_label,$name] | @tsv)
  ' "$payload"
}

print_migration_preview() {
  local payload="$1" rows current_nfuse usage_rows conflict mode
  mode="$(jq -r '.restore_mode // "replace"' "$payload")"
  printf '\n恢复内容预览（此时尚未修改服务器）\n\n'
  printf '来源：%s｜创建时间：%s｜脚本版本：%s\n' \
    "$(jq -r '.source_hostname' "$payload")" "$(jq -r '.created_at' "$payload")" "$(jq -r '.script_version' "$payload")"
  if [[ "$mode" == merge ]]; then
    echo '恢复方式：合并到这台服务器（保留现有内容）'
    jq -r '
      .merge_summary as $s |
      "合并计划：用户新增 \($s.users.imported)、替换 \($s.users.replaced)、重命名 \($s.users.renamed)、跳过 \($s.users.skipped)；" +
      "分流新增 \($s.splits.imported)、替换 \($s.splits.replaced)、重命名 \($s.splits.renamed)、跳过 \($s.splits.skipped)；" +
      "预置出口新增 \($s.outbound_presets.imported)、自动改名 \($s.outbound_presets.renamed)、复用 \($s.outbound_presets.deduplicated)；" +
      "预置规则新增 \($s.rule_presets.imported)、自动改名 \($s.rule_presets.renamed)、复用 \($s.rule_presets.deduplicated)"
    ' "$payload"
  else
    echo '恢复方式：完全恢复成备份内容'
  fi
  printf '恢复前后：用户 %s → %s，分流 %s → %s，预置出口 %s → %s，预置规则 %s → %s\n\n' \
    "$(jq '.users|length' "$STATE_FILE")" "$(jq '.state.users|length' "$payload")" \
    "$(jq '.splits|length' "$STATE_FILE")" "$(jq '.state.splits|length' "$payload")" \
    "$(jq '.outbound_presets|length' "$STATE_FILE")" "$(jq '.state.outbound_presets|length' "$payload")" \
    "$(jq '.rule_presets|length' "$STATE_FILE")" "$(jq '.state.rule_presets|length' "$payload")"
  rows="$(migration_entity_change_rows "$payload" users 用户; migration_entity_change_rows "$payload" splits 分流; migration_entity_change_rows "$payload" outbound_presets 预置出口; migration_entity_change_rows "$payload" rule_presets 预置规则)"
  if [[ -n "$rows" ]]; then
    { printf '动作\t类型\t名称\n'; printf '%s\n' "$rows"; } | column -t -s $'\t'
  else
    echo '用户和分流内容无变化。'
  fi
  current_nfuse="$(nfuse list --json)"
  usage_rows="$(jq -r --argjson old "$current_nfuse" --slurpfile oldstate "$STATE_FILE" '
    def format_bytes:
      if . < 1048576 then (tostring)+" B"
      elif . < 1073741824 then (((./1048576*100|round)/100|tostring)+" MiB")
      else (((./1073741824*100|round)/100|tostring)+" GiB") end;
    (.nfuse_usage // []) as $new |
    (($old|map(.name)) + ($new|map(.name)) + ($oldstate[0].users|map(.name)) + (.state.users|map(.name)) | unique[]) as $name |
    ((($old[]?|select(.name==$name)|.used_bytes) // 0) +
     (($oldstate[0].users[]?|select(.name==$name)|.usage_offset_bytes) // 0)) as $before |
    ((($new[]?|select(.name==$name)|.used_bytes) // 0) +
     ((.state.users[]?|select(.name==$name)|.usage_offset_bytes) // 0)) as $after |
    select($before!=$after) |
    [$name,($before|format_bytes),($after|format_bytes)] | @tsv
  ' "$payload")"
  if [[ -n "$usage_rows" ]]; then
    printf '\n用户已用流量变化：\n'
    { printf '用户\t当前\t恢复后\n'; printf '%s\n' "$usage_rows"; } | column -t -s $'\t'
  fi
  collect_migration_conflicts "$payload"
  printf '\n安全检查：'
  if ((${#MIGRATION_CONFLICTS[@]}==0)); then echo '通过，可以继续恢复。'
  else
    printf '发现 %s 个问题，解决前不会修改服务器。\n' "${#MIGRATION_CONFLICTS[@]}"
    for conflict in "${MIGRATION_CONFLICTS[@]}"; do printf '  - %s\n' "$conflict"; done
  fi
}

preview_migration_backup() {
  local source_payload payload
  ensure_migration_crypto_dependencies || return 0
  prepare_core; need_cmd openssl
  select_migration_backup || return 0
  source_payload="$(mktemp /tmp/sb-user-preview-source.XXXXXX)"
  payload="$(mktemp /tmp/sb-user-preview.XXXXXX)"
  register_temp_path "$source_payload"
  register_temp_path "$payload"
  prepare_migration_payload_files "$SELECTED_MIGRATION_BACKUP" "$source_payload" "$payload" || return 0
  print_migration_preview "$payload"
  rm -f "$source_payload" "$payload"
}

remove_current_managed_data() {
  local name split nfuse_json split_names user_names
  nfuse_json="$(nfuse list --json)" || return 1
  jq -e 'type == "array"' <<<"$nfuse_json" >/dev/null || return 1
  split_names="$(jq -r '.splits[].name' "$STATE_FILE")" || return 1
  user_names="$(jq -r '.users[].name' "$STATE_FILE")" || return 1
  while IFS= read -r split; do
    [[ -n "$split" ]] || continue
    remove_split_config "$split" || return 1
  done <<<"$split_names"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    remove_user_inbounds "$name" || return 1
    if jq -e --arg name "$name" '.[] | select(.name == $name)' <<<"$nfuse_json" >/dev/null; then
      nfuse rm "$name" --cascade >/dev/null || return 1
    fi
  done <<<"$user_names"
  nfuse persist >/dev/null || return 1
}

write_migration_restore_report() {
  local payload="$1" package="$2" snapshot="$3" result="$4" failure_stage="${5:-}" dir report
  local package_sha source_hostname source_created_at source_script_version users splits nfuse_accounts mode merge_summary
  dir="${MIGRATION_REPORT_DIR:-/root/sb-user-manager-backups/reports}"
  install -d -m 700 "$dir" || return 1
  report="$dir/migration-restore-$(date '+%Y%m%d-%H%M%S-%N').json"
  package_sha="$(sha256sum "$package" | awk '{print $1}')" || return 1
  source_hostname="$(jq -r '.source_hostname' "$payload")" || return 1
  source_created_at="$(jq -r '.created_at' "$payload")" || return 1
  source_script_version="$(jq -r '.script_version' "$payload")" || return 1
  users="$(jq '.state.users|length' "$payload")" || return 1
  splits="$(jq '.state.splits|length' "$payload")" || return 1
  nfuse_accounts="$(jq '.nfuse_usage|length' "$payload")" || return 1
  mode="$(jq -r '.restore_mode // "replace"' "$payload")" || return 1
  merge_summary="$(jq -c '.merge_summary // null' "$payload")" || return 1
  if ! jq -n \
    --arg completed_at "$(date -Iseconds)" \
    --arg result "$result" \
    --arg package "$(basename "$package")" \
    --arg package_sha256 "$package_sha" \
    --arg source_hostname "$source_hostname" \
    --arg source_created_at "$source_created_at" \
    --arg source_script_version "$source_script_version" \
    --arg mode "$mode" \
    --arg snapshot "$snapshot" \
    --arg failure_stage "$failure_stage" \
    --argjson users "$users" \
    --argjson splits "$splits" \
    --argjson nfuse_accounts "$nfuse_accounts" \
    --argjson merge_summary "$merge_summary" \
    '{completed_at:$completed_at,result:$result,failure_stage:$failure_stage,package:$package,package_sha256:$package_sha256,
      source:{hostname:$source_hostname,created_at:$source_created_at,script_version:$source_script_version},
      mode:$mode,merge_summary:$merge_summary,
      restored:{users:$users,splits:$splits,nfuse_accounts:$nfuse_accounts},environment_snapshot:$snapshot}' > "$report"; then
    rm -f -- "$report"
    return 1
  fi
  if ! chmod 600 "$report"; then
    rm -f -- "$report"
    return 1
  fi
  MIGRATION_REPORT="$report"
  if ! prune_migration_reports "$MIGRATION_REPORT_RETENTION"; then
    log "提示：旧的恢复记录暂未能自动整理，不影响本次恢复结果"
  fi
}

migration_report_dir() {
  printf '%s' "${MIGRATION_REPORT_DIR:-/root/sb-user-manager-backups/reports}"
}

validate_migration_restore_report() {
  local report="$1"
  [[ -f "$report" ]] || return 1
  jq -e '
    (.completed_at|type=="string" and length>0) and
    (.result|type=="string" and length>0) and
    ((.failure_stage // "")|type=="string") and
    (.package|type=="string" and length>0) and
    (.package_sha256|type=="string" and test("^[0-9a-fA-F]{64}$")) and
    (.source|type=="object") and
    (.source.hostname|type=="string") and
    (.source.created_at|type=="string") and
    (.source.script_version|type=="string") and
    ((.mode // "replace") == "replace" or (.mode // "replace") == "merge") and
    ((.merge_summary // null) == null or (.merge_summary|type=="object")) and
    (.restored|type=="object") and
    (.restored.users|type=="number" and .>=0 and .==floor) and
    (.restored.splits|type=="number" and .>=0 and .==floor) and
    (.restored.nfuse_accounts|type=="number" and .>=0 and .==floor) and
    (.environment_snapshot|type=="string")
  ' "$report" >/dev/null 2>&1
}

migration_report_result_label() {
  case "$1" in
    success) printf '成功';;
    rolled_back) printf '失败，已回滚';;
    rollback_failed) printf '失败，回滚异常';;
    *) printf '未知结果：%s' "$1";;
  esac
}

migration_report_failure_label() {
  case "$1" in
    '') printf '无';;
    removing_current_data) printf '清理这台服务器原有的用户和分流';;
    writing_managed_state) printf '写入备份中的用户资料';;
    rebuilding_managed_data) printf '重新建立节点、分流和流量统计';;
    restoring_nfuse_usage) printf '恢复用户已用流量';;
    validating_singbox) printf '检查连接配置并启动服务';;
    auditing_consistency) printf '检查恢复结果';;
    *) printf '未知阶段：%s' "$1";;
  esac
}

load_migration_reports() {
  local dir file
  MIGRATION_REPORTS=()
  dir="$(migration_report_dir)"
  [[ -d "$dir" ]] || return 0
  while IFS= read -r file; do MIGRATION_REPORTS[${#MIGRATION_REPORTS[@]}]="$file"; done < <(
    find "$dir" -maxdepth 1 -type f -name 'migration-restore-*.json' -print | list_files_newest_first
  )
}

load_valid_migration_reports() {
  local report
  VALID_MIGRATION_REPORTS=()
  load_migration_reports
  ((${#MIGRATION_REPORTS[@]} > 0)) || return 0
  for report in "${MIGRATION_REPORTS[@]}"; do
    validate_migration_restore_report "$report" || continue
    VALID_MIGRATION_REPORTS[${#VALID_MIGRATION_REPORTS[@]}]="$report"
  done
}

prune_migration_reports() {
  local keep="$1" i failed=false
  [[ "$keep" =~ ^[0-9]+$ ]] || return 1
  load_valid_migration_reports
  ((${#VALID_MIGRATION_REPORTS[@]} > 0)) || return 0
  for ((i=keep; i<${#VALID_MIGRATION_REPORTS[@]}; i++)); do
    [[ -f "${VALID_MIGRATION_REPORTS[$i]}" && ! -L "${VALID_MIGRATION_REPORTS[$i]}" ]] || {
      failed=true
      continue
    }
    rm -f -- "${VALID_MIGRATION_REPORTS[$i]}" || failed=true
  done
  [[ "$failed" == false ]]
}

print_migration_reports() {
  local i file result
  load_migration_reports
  if ((${#MIGRATION_REPORTS[@]} == 0)); then echo '暂无恢复报告。'; return 1; fi
  for i in "${!MIGRATION_REPORTS[@]}"; do
    file="${MIGRATION_REPORTS[$i]}"
    if ! validate_migration_restore_report "$file"; then
      printf '  %d. 报告异常｜%s\n' "$((i+1))" "$(basename "$file")"
      continue
    fi
    result="$(migration_report_result_label "$(jq -r '.result' "$file")")"
    jq -r --argjson number "$((i+1))" --arg result "$result" '
      ((.mode // "replace") as $mode |
       "  \($number). \($result)｜" + (if $mode == "merge" then "合并导入" else "完全替换" end) + "｜\(.completed_at)｜来源：\(.source.hostname)"),
      "     最终用户 \(.restored.users)｜最终分流 \(.restored.splits)｜Nfuse \(.restored.nfuse_accounts)｜迁移包：\(.package)"
    ' "$file"
  done
}

select_migration_report() {
  print_migration_reports || return 1
  echo '  0. 返回上一级'
  read_numbered_index '请选择报告编号：' "${#MIGRATION_REPORTS[@]}" || return 1
  SELECTED_MIGRATION_REPORT="${MIGRATION_REPORTS[$SELECTED_INDEX]}"
}

show_migration_report_details() {
  local result failure mode_label
  select_migration_report || return 0
  validate_migration_restore_report "$SELECTED_MIGRATION_REPORT" || die "恢复报告格式异常，无法查看详情"
  result="$(migration_report_result_label "$(jq -r '.result' "$SELECTED_MIGRATION_REPORT")")"
  failure="$(migration_report_failure_label "$(jq -r '.failure_stage // ""' "$SELECTED_MIGRATION_REPORT")")"
  if [[ "$(jq -r '.mode // "replace"' "$SELECTED_MIGRATION_REPORT")" == merge ]]; then mode_label='合并导入'; else mode_label='完全替换'; fi
  jq -r --arg result "$result" --arg failure "$failure" --arg mode "$mode_label" --arg report "$SELECTED_MIGRATION_REPORT" '
    "\n恢复记录详情\n",
    "完成时间：\(.completed_at)",
    "执行结果：\($result)",
    "恢复方式：\($mode)",
    "失败阶段：\($failure)",
    "来源主机：\(.source.hostname)",
    "源端创建：\(.source.created_at)",
    "源端版本：\(.source.script_version)",
    "最终用户：\(.restored.users)",
    "最终分流：\(.restored.splits)",
    "流量记录：\(.restored.nfuse_accounts)",
    (if (.mode // "replace") == "merge" and (.merge_summary // null) != null then
      (.merge_summary as $s |
       "合并处理：用户新增 \($s.users.imported)、覆盖 \($s.users.replaced)、改名 \($s.users.renamed)、跳过 \($s.users.skipped)；" +
       "分流新增 \($s.splits.imported)、覆盖 \($s.splits.replaced)、改名 \($s.splits.renamed)、跳过 \($s.splits.skipped)；" +
       "预置出口新增 \($s.outbound_presets.imported)、改名 \($s.outbound_presets.renamed)、复用 \($s.outbound_presets.deduplicated)；" +
       "预置规则新增 \($s.rule_presets.imported)、改名 \($s.rule_presets.renamed)、复用 \($s.rule_presets.deduplicated)")
     else empty end),
    "迁移包：\(.package)",
    "备份文件校验值（SHA256）：\(.package_sha256)",
    "恢复前完整备份：\(.environment_snapshot)",
    "记录文件：" + $report
  ' "$SELECTED_MIGRATION_REPORT"
}

delete_migration_report() {
  local answer file
  select_migration_report || return 0
  file="$SELECTED_MIGRATION_REPORT"
  read -r -p "确认删除报告 $(basename "$file")？[y/N]：" answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo '已取消删除。'; return 0; }
  rm -f -- "$file"
  echo '恢复报告已删除。'
}

cleanup_migration_reports() {
  local keep answer i remove
  while true; do
    read -r -p '保留最近多少份恢复报告？[20]（输入 0 返回）：' keep
    [[ "$keep" != 0 ]] || return 0
    keep="${keep:-20}"
    [[ "$keep" =~ ^[1-9][0-9]?$|^100$ ]] && break
    echo '输入无效：保留数量必须位于 1-100，请重新输入。'
  done
  load_migration_reports
  remove=$((${#MIGRATION_REPORTS[@]}>keep ? ${#MIGRATION_REPORTS[@]}-keep : 0))
  printf '\n当前恢复报告：%s，保留：%s，删除：%s\n' "${#MIGRATION_REPORTS[@]}" "$keep" "$remove"
  ((remove>0)) || { echo '没有需要清理的旧报告。'; return 0; }
  read -r -p '确认永久删除超出保留数量的旧报告？请输入 CLEANUP：' answer
  [[ "$answer" == CLEANUP ]] || { echo '已取消清理。'; return 0; }
  for ((i=keep; i<${#MIGRATION_REPORTS[@]}; i++)); do rm -f -- "${MIGRATION_REPORTS[$i]}"; done
  printf '清理完成：删除恢复报告 %s 份。\n' "$remove"
}

migration_report_menu() {
  while true; do
    prepare_menu_screen
    cat <<'EOF'
恢复记录

1. 查看记录列表
2. 查看记录详情
3. 删除一条记录
4. 清理旧记录
0. 返回上一级
EOF
    read_menu_choice '请选择：' '0,1,2,3,4' '' '请输入 0-4 之间的数字' || return 0
    choice="$PROMPT_VALUE"
    case "$choice" in
      1) echo; print_migration_reports || true; pause_menu;;
      2) show_migration_report_details; pause_menu;;
      3) delete_migration_report; pause_menu;;
      4) cleanup_migration_reports; pause_menu;;
      0) return 0;;
    esac
  done
}

restore_migration_backup() {
  local source_payload payload answer confirm_token current_users current_splits environment_backup name used rollback_result restore_stage
  local state_tmp usage_rows nfuse_json
  ensure_migration_crypto_dependencies || return 0
  prepare_core || return 1
  need_cmd openssl
  select_migration_backup || return 0
  source_payload="$(mktemp /tmp/sb-user-restore-source.XXXXXX)" || die "无法创建迁移解密临时文件"
  payload="$(mktemp /tmp/sb-user-restore.XXXXXX)" || { rm -f -- "$source_payload"; die "无法创建迁移计划临时文件"; }
  register_temp_path "$source_payload"
  register_temp_path "$payload"
  prepare_migration_payload_files "$SELECTED_MIGRATION_BACKUP" "$source_payload" "$payload" || return 0
  rm -f -- "$source_payload"
  print_migration_preview "$payload"
  if ! preflight_migration_payload "$payload"; then rm -f "$payload"; die "安全检查未通过，服务器尚未被修改。请先处理上方列出的问题"; fi
  current_users="$(jq '.users|length' "$STATE_FILE")"; current_splits="$(jq '.splits|length' "$STATE_FILE")"
  printf '\n最终状态：用户 %s，分流 %s，来源 %s，创建于 %s。\n' \
    "$(jq '.state.users|length' "$payload")" "$(jq '.state.splits|length' "$payload")" \
    "$(jq -r '.source_hostname' "$payload")" "$(jq -r '.created_at' "$payload")"
  if [[ "$MIGRATION_RESTORE_MODE" == replace ]] && ((current_users>0 || current_splits>0)); then
    printf '这台服务器已有用户 %s 个、分流 %s 条；继续后会删除它们并改用备份内容。其他手工配置不会被修改。\n' "$current_users" "$current_splits"
    confirm_token=RESTORE
  elif [[ "$MIGRATION_RESTORE_MODE" == merge ]]; then
    printf '合并会保留上方没有标记为「替换」的现有内容，并加入备份中的内容。\n'
    confirm_token=MERGE
  else
    confirm_token=RESTORE
  fi
  read -r -p "确认继续？请输入 ${confirm_token}：" answer
  [[ "$answer" == "$confirm_token" ]] || { rm -f "$payload"; echo '已取消恢复。'; return 0; }
  if ! ensure_safe_ssh_for_singbox_restart; then
    rm -f -- "$payload"
    return 0
  fi
  if ! create_environment_backup; then
    rm -f -- "$payload"
    die "无法创建恢复前的安全备份，因此没有修改任何数据"
  fi
  environment_backup="$ENV_BACKUP"
  if ! start_managed_operation "restore-migration:$(basename "$SELECTED_MIGRATION_BACKUP")"; then
    rm -f -- "$payload"
    die "无法开启安全恢复保护，因此没有修改任何数据"
  fi
  restore_stage=removing_current_data
  rollback_migration_restore() {
    local rc="${1:-$?}"
    trap - ERR
    clear_signal_rollback
    log "恢复失败，正在自动还原恢复前的数据：$environment_backup"
    rollback_result=rolled_back
    if ! restore_environment_backup "$environment_backup"; then
      rollback_result=rollback_failed
      log "严重错误：自动还原失败。请停止继续操作，并保留完整备份：$environment_backup"
    elif ! clear_operation_transaction; then
      rollback_result=rollback_failed
      log "严重错误：环境已回滚，但无法清除事务日志：$TRANSACTION_JOURNAL"
    fi
    write_migration_restore_report "$payload" "$SELECTED_MIGRATION_BACKUP" "$environment_backup" "$rollback_result" "$restore_stage" || true
    rm -f "$payload"
    return "$rc"
  }
  fail_migration_restore() {
    local message="$1"
    rollback_migration_restore 1 || true
    die "${message}。脚本已尝试还原到操作前状态，请查看上方结果"
  }
  trap rollback_migration_restore ERR
  set_signal_rollback rollback_migration_restore
  if ! remove_current_managed_data; then
    fail_migration_restore "无法安全清理这台服务器原有的用户和分流"
  fi
  restore_stage=writing_managed_state
  state_tmp="$(mktemp "$(dirname "$STATE_FILE")/.migration-state.XXXXXX")" ||
    fail_migration_restore "无法创建迁移状态临时文件"
  register_temp_path "$state_tmp"
  if ! jq '.state' "$payload" > "$state_tmp"; then
    rm -f -- "$state_tmp"
    fail_migration_restore "无法生成迁移状态"
  fi
  if ! chmod 600 "$state_tmp"; then
    rm -f -- "$state_tmp"
    fail_migration_restore "无法设置迁移状态权限"
  fi
  chown --reference="$STATE_FILE" "$state_tmp" 2>/dev/null || true
  if ! mv -- "$state_tmp" "$STATE_FILE"; then
    rm -f -- "$state_tmp"
    fail_migration_restore "无法写入迁移状态"
  fi
  if ! (init_state); then
    fail_migration_restore "初始化迁移状态失败"
  fi
  restore_stage=rebuilding_managed_data
  if ! (repair_consistency >/dev/null); then
    fail_migration_restore "无法重新建立用户连接、分流和流量统计"
  fi
  restore_stage=restoring_nfuse_usage
  usage_rows="$(jq -r '
    .state.users[] as $user |
    first(.nfuse_usage[]? | select(.name == $user.name)) as $usage |
    select($usage != null) |
    [$user.name,($usage.used_bytes|tostring),((($user.metered // ($user.limit_gib != null)))|tostring)] | @tsv
  ' "$payload")" ||
    fail_migration_restore "无法读取迁移包中的 Nfuse 用量"
  nfuse_json="$(nfuse list --json)" || fail_migration_restore "无法读取恢复后的流量记录"
  if ! jq -e 'type == "array"' <<<"$nfuse_json" >/dev/null; then
    fail_migration_restore "恢复后的 Nfuse 数据结构无效"
  fi
  while IFS=$'\t' read -r name used metered; do
    [[ -n "$name" && "$used" =~ ^[0-9]+$ ]] || continue
    if ! jq -e --arg name "$name" '.[] | select(.name == $name)' <<<"$nfuse_json" >/dev/null; then
      fail_migration_restore "恢复后缺少用户 $name 的流量记录"
    fi
    if [[ "$metered" == true ]]; then
      if ! nfuse set-usage "$name" "$used" >/dev/null; then
        fail_migration_restore "无法恢复 Nfuse 已用流量：$name"
      fi
    elif ! state_add_usage_offset "$name" "$used"; then
      fail_migration_restore "无法衔接自用用户的累计用量：$name"
    fi
  done <<<"$usage_rows"
  if ! nfuse persist >/dev/null; then
    fail_migration_restore "无法持久化恢复后的 Nfuse 数据"
  fi
  restore_stage=validating_singbox
  if ! check_singbox_and_restart; then
    fail_migration_restore "恢复后的 sing-box 配置或服务校验失败"
  fi
  restore_stage=auditing_consistency
  if ! audit_consistency; then
    fail_migration_restore "无法检查恢复后的服务和配置"
  fi
  if ((AUDIT_ISSUES != 0)); then
    fail_migration_restore "恢复后的服务或配置仍有问题"
  fi
  if ! finish_managed_operation; then
    fail_migration_restore "恢复结果未能安全保存"
  fi
  if ! write_migration_restore_report "$payload" "$SELECTED_MIGRATION_BACKUP" "$environment_backup" success; then
    rm -f -- "$payload"
    log "迁移数据已恢复，但恢复报告写入失败"
    return 1
  fi
  rm -f "$payload"
  log "恢复完成；操作前完整备份：$environment_backup"
  log "本次恢复结果：$MIGRATION_REPORT"
}

delete_migration_backup() {
  local answer file
  select_migration_backup || return 0
  file="$SELECTED_MIGRATION_BACKUP"
  read -r -p "确认删除 $(basename "$file")？[y/N]：" answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo '已取消删除。'; return 0; }
  rm -f -- "$file"
  echo '迁移备份已删除。'
}

cleanup_backup_retention() {
  local keep_migration keep_snapshots answer i remove_migration remove_snapshots path
  prepare_core
  while true; do
    read -r -p '保留最近多少份单文件迁移备份？[10]（输入 0 返回）：' keep_migration
    [[ "$keep_migration" != 0 ]] || return 0
    keep_migration="${keep_migration:-10}"
    [[ "$keep_migration" =~ ^[1-9][0-9]?$|^100$ ]] && break
    echo '输入无效：迁移备份保留数量必须位于 1-100，请重新输入。'
  done
  while true; do
    read -r -p '保留最近多少份操作前完整备份？[5]（输入 0 返回）：' keep_snapshots
    [[ "$keep_snapshots" != 0 ]] || return 0
    keep_snapshots="${keep_snapshots:-5}"
    [[ "$keep_snapshots" =~ ^[1-9][0-9]?$|^100$ ]] && break
    echo '输入无效：操作前完整备份保留数量必须位于 1-100，请重新输入。'
  done
  load_migration_backups
  load_environment_snapshot_candidates
  VERIFIED_ENVIRONMENT_SNAPSHOTS=()
  if ((${#ENVIRONMENT_SNAPSHOTS[@]} > 0)); then
    for path in "${ENVIRONMENT_SNAPSHOTS[@]}"; do
      verify_environment_backup "$path" >/dev/null 2>&1 || continue
      VERIFIED_ENVIRONMENT_SNAPSHOTS[${#VERIFIED_ENVIRONMENT_SNAPSHOTS[@]}]="$path"
    done
  fi
  if ((${#VERIFIED_ENVIRONMENT_SNAPSHOTS[@]} > 0)); then
    ENVIRONMENT_SNAPSHOTS=("${VERIFIED_ENVIRONMENT_SNAPSHOTS[@]}")
  else
    ENVIRONMENT_SNAPSHOTS=()
  fi
  remove_migration=$((${#MIGRATION_BACKUPS[@]}>keep_migration ? ${#MIGRATION_BACKUPS[@]}-keep_migration : 0))
  remove_snapshots=$((${#ENVIRONMENT_SNAPSHOTS[@]}>keep_snapshots ? ${#ENVIRONMENT_SNAPSHOTS[@]}-keep_snapshots : 0))
  printf '\n当前单文件迁移备份：%s，保留：%s，删除：%s\n' "${#MIGRATION_BACKUPS[@]}" "$keep_migration" "$remove_migration"
  printf '当前操作前完整备份：%s，保留：%s，删除：%s\n' "${#ENVIRONMENT_SNAPSHOTS[@]}" "$keep_snapshots" "$remove_snapshots"
  if ((remove_migration==0 && remove_snapshots==0)); then echo '没有需要清理的旧备份。'; return 0; fi
  read -r -p '确认永久删除超出保留数量的旧备份？请输入 CLEANUP：' answer
  [[ "$answer" == CLEANUP ]] || { echo '已取消清理。'; return 0; }
  for ((i=keep_migration; i<${#MIGRATION_BACKUPS[@]}; i++)); do rm -f -- "${MIGRATION_BACKUPS[$i]}"; done
  for ((i=keep_snapshots; i<${#ENVIRONMENT_SNAPSHOTS[@]}; i++)); do
    verify_environment_backup "${ENVIRONMENT_SNAPSHOTS[$i]}" >/dev/null 2>&1 || continue
    rm -rf -- "${ENVIRONMENT_SNAPSHOTS[$i]}"
  done
  printf '清理完成：删除迁移备份 %s 份、操作前完整备份 %s 份。\n' "$remove_migration" "$remove_snapshots"
}

check_singbox_and_restart() {
  ensure_safe_ssh_for_singbox_restart rollback || return 1
  "$SINGBOX_BIN" check -c "$SINGBOX_CONFIG" || return 1
  systemctl reset-failed "$SINGBOX_SERVICE" 2>/dev/null || true
  systemctl restart "$SINGBOX_SERVICE" || return 1
  if ! systemctl is-active --quiet "$SINGBOX_SERVICE"; then
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
  "$SINGBOX_BIN" format -c "$SINGBOX_CONFIG" |
    jq -e --arg tag "$tag" '.inbounds[]? | select(.tag == $tag)' >/dev/null
}

nfuse_account_exists() {
  nfuse list --json 2>/dev/null | jq -e --arg name "$1" '.[] | select(.name == $name)' >/dev/null
}

nfuse_port_exists() {
  nfuse list --json 2>/dev/null | jq -e --argjson port "$1" \
    '.[] | .ports[]? | select(.start <= $port and .end >= $port)' >/dev/null
}

generate_ss_password() {
  case "$1" in
    2022-blake3-aes-128-gcm)
      "$SINGBOX_BIN" generate rand --base64 16
      ;;
    2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305)
      "$SINGBOX_BIN" generate rand --base64 32
      ;;
    *)
      die "脚本只支持 Shadowsocks 2022 方法，当前：$1"
      ;;
  esac
}

generate_st_password() {
  "$SINGBOX_BIN" generate rand --base64 32
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
  if ! "$SINGBOX_BIN" format -c "$SINGBOX_CONFIG" > "$normalized"; then
    rm -f -- "$tmp" "$normalized"
    printf '错误：无法解析或格式化 sing-box 配置：%s\n' "$SINGBOX_CONFIG" >&2
    return 1
  fi
  if ! jq "$@" "$filter" "$normalized" > "$tmp"; then
    rm -f -- "$tmp" "$normalized"
    printf '错误：无法生成新的 sing-box 配置\n' >&2
    return 1
  fi
  rm -f -- "$normalized"
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
    '.inbounds = [(.inbounds // [])[] | select(.tag != $st and .tag != $ss and .tag != $ss_udp and .tag != $at and .tag != $sn)]' \
    --arg st "st-$name" --arg ss "ss-$name" --arg ss_udp "ss-udp-$name" --arg at "anytls-$name" --arg sn "snell-$name"
}

replace_user_inbounds() {
  local name="$1" fragment="$2"
  SB_JQ_NEW_INBOUNDS="$fragment" rewrite_singbox_config \
     '($ENV.SB_JQ_NEW_INBOUNDS | fromjson) as $new_inbounds |
     .inbounds = ([((.inbounds // [])[]) | select(.tag != $st and .tag != $ss and .tag != $ss_udp and .tag != $at and .tag != $sn)] + $new_inbounds)' \
    --arg st "st-$name" --arg ss "ss-$name" --arg ss_udp "ss-udp-$name" --arg at "anytls-$name" --arg sn "snell-$name"
}

rebuild_protocol_inbounds() {
  local protocol="$1" row name status endpoint fragment fragments='[]' managed_tags_json='[]'
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    name="$(jq -er '.name' <<<"$row")" || return 1
    status="$(jq -er '.status' <<<"$row")" || return 1
    endpoint="$(jq -ec '.endpoint' <<<"$row")" || return 1
    if [[ "$protocol" == anytls ]]; then
      managed_tags_json="$(jq -c --arg tag "anytls-$name" '. + [$tag]' <<<"$managed_tags_json")" || return 1
    else
      managed_tags_json="$(jq -c --arg st "st-$name" --arg ss "ss-$name" --arg ss_udp "ss-udp-$name" --arg sn "snell-$name" '. + [$st,$ss,$ss_udp,$sn]' <<<"$managed_tags_json")" || return 1
    fi
    if [[ "$status" == active ]]; then
      fragment="$(make_endpoint_inbounds_from_state "$name" "$endpoint")" || return 1
      fragments="$(SB_JQ_CURRENT="$fragments" SB_JQ_ADDED="$fragment" jq -cn '($ENV.SB_JQ_CURRENT | fromjson) as $current | ($ENV.SB_JQ_ADDED | fromjson) as $added | $current + $added')" || return 1
    fi
  done < <(jq -c --arg protocol "$protocol" '
    .users[] as $user |
    (if ($user.endpoints | type) == "array" then $user.endpoints[]
     elif ($user.protocol // "ss2022") == "anytls" then
       {protocol:"anytls",port:$user.port,anytls_password:$user.anytls_password,tls_sni:$user.tls_sni}
     else
       {protocol:"ss2022",port:$user.port,shadowtls_password:$user.shadowtls_password,
        ss2022_password:$user.ss2022_password,method:$user.method,shadowtls_sni:$user.shadowtls_sni}
     end) |
    select(.protocol == $protocol) | {name:$user.name,status:$user.status,endpoint:.}
  ' "$STATE_FILE")
  SB_JQ_NEW_INBOUNDS="$fragments" rewrite_singbox_config '
    ($ENV.SB_JQ_NEW_INBOUNDS | fromjson) as $new_inbounds |
    .inbounds = ([((.inbounds // [])[]) |
      .tag as $tag | select(($managed_tags | index($tag)) == null)] + $new_inbounds)
  ' --argjson managed_tags "$managed_tags_json"
}

ss2022_udp_inbounds_are_current() {
  local split rows user user_status rule_tag inbound
  jq -e --slurpfile config "$SINGBOX_CONFIG" '
    .users as $users |
    all($users[]?;
        . as $user |
        ([if (.endpoints | type) == "array" then .endpoints[]
          elif (.protocol // "ss2022") == "ss2022" then
            {protocol:"ss2022",port:.port,ss2022_password:.ss2022_password,method:.method}
          else empty end | select(.protocol == "ss2022")] | first) as $endpoint |
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
      if (.endpoints | type) == "array" then any(.endpoints[]; .protocol == "ss2022")
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
  if ! ensure_safe_ssh_for_singbox_restart; then
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
    '[{"type":"anytls","tag":("anytls-" + $name),"listen":"::","listen_port":$port,"users":[{"name":$name,"password":$ENV.SB_JQ_PASSWORD}],"tls":{"enabled":true,"certificate_path":"/etc/sing-box/cert/anytls.crt","key_path":"/etc/sing-box/cert/anytls.key"}}]'
}

make_endpoint_inbounds_from_state() {
  local name="$1" endpoint="$2" port protocol anytls_password st_password ss_password method shadowtls_sni
  port="$(jq -er '.port | select(type == "number")' <<<"$endpoint")" || return 1
  protocol="$(jq -er '.protocol | select(type == "string" and length > 0)' <<<"$endpoint")" || return 1
  if [[ "$protocol" == anytls ]]; then
    anytls_password="$(jq -er '.anytls_password | select(type == "string" and length > 0)' <<<"$endpoint")" || return 1
    make_anytls_inbound "$name" "$port" "$anytls_password"
  elif [[ "$protocol" == ss2022 ]]; then
    st_password="$(jq -er '.shadowtls_password | select(type == "string" and length > 0)' <<<"$endpoint")" || return 1
    ss_password="$(jq -er '.ss2022_password | select(type == "string" and length > 0)' <<<"$endpoint")" || return 1
    method="$(jq -er '.method | select(type == "string" and length > 0)' <<<"$endpoint")" || return 1
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
  local user="$1" name endpoint fragment fragments='[]' count=0
  name="$(jq -er '.name | select(type == "string" and length > 0)' <<<"$user")" || return 1
  while IFS= read -r endpoint; do
    [[ -n "$endpoint" ]] || continue
    fragment="$(make_endpoint_inbounds_from_state "$name" "$endpoint")" || return 1
    fragments="$(SB_JQ_CURRENT="$fragments" SB_JQ_ADDED="$fragment" jq -cn \
      '($ENV.SB_JQ_CURRENT | fromjson) + ($ENV.SB_JQ_ADDED | fromjson)')" || return 1
    count=$((count + 1))
  done < <(jq -c 'if (.endpoints | type) == "array" then .endpoints[] else
    if (.protocol // "ss2022") == "anytls" then
      {protocol:"anytls",port:.port,anytls_password:.anytls_password,tls_sni:.tls_sni}
    else
      {protocol:"ss2022",port:.port,shadowtls_password:.shadowtls_password,
       ss2022_password:.ss2022_password,method:.method,shadowtls_sni:.shadowtls_sni}
    end end' <<<"$user")
  if ((count == 0)); then
    return 1
  fi
  printf '%s\n' "$fragments"
}

state_add_user() {
  local name="$1" port="$2" st_password="$3" ss_password="$4" limit="$5" anchor="$6" metered="$7" expires_at="$8" method="$9" shadowtls_sni="${10}"
  SB_JQ_ST_PASSWORD="$st_password" SB_JQ_SS_PASSWORD="$ss_password" atomic_state_update '.users += [{
      name: $name,
      port: $port,
      protocol: "ss2022",
      shadowtls_password: $ENV.SB_JQ_ST_PASSWORD,
      ss2022_password: $ENV.SB_JQ_SS_PASSWORD,
      method: $method,
      shadowtls_sni: $shadowtls_sni,
      metered: $metered,
      expires_at: (if $expires_at == "" then null else $expires_at end),
      limit_gib: (if $metered then ($limit | tonumber) else null end),
      billing_anchor: (if $metered then ($anchor | tonumber) else null end),
      usage_offset_bytes: 0,
      status: "active",
      created_at: $created_at,
      endpoints: [{
        protocol: "ss2022",
        port: $port,
        shadowtls_password: $ENV.SB_JQ_ST_PASSWORD,
        ss2022_password: $ENV.SB_JQ_SS_PASSWORD,
        method: $method,
        shadowtls_sni: $shadowtls_sni
      }]
    }]' \
    --arg name "$name" \
    --argjson port "$port" \
    --arg method "$method" \
    --arg shadowtls_sni "$shadowtls_sni" \
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
  local name="$1" ss_port="$2" anytls_port="$3" st_password="$4" ss_password="$5" anytls_password="$6"
  local limit="$7" anchor="$8" metered="$9" expires_at="${10}" method="${11}" shadowtls_sni="${12}" tls_sni="${13}"
  SB_JQ_ST_PASSWORD="$st_password" SB_JQ_SS_PASSWORD="$ss_password" SB_JQ_ANYTLS_PASSWORD="$anytls_password" \
    atomic_state_update '.users += [{
      name:$name,port:$ss_port,protocol:"ss2022",
      shadowtls_password:$ENV.SB_JQ_ST_PASSWORD,ss2022_password:$ENV.SB_JQ_SS_PASSWORD,
      method:$method,shadowtls_sni:$shadowtls_sni,
      metered:$metered,expires_at:(if $expires_at=="" then null else $expires_at end),
      limit_gib:(if $metered then ($limit|tonumber) else null end),
      billing_anchor:(if $metered then ($anchor|tonumber) else null end),
      usage_offset_bytes:0,status:"active",created_at:$created_at,
      endpoints:[
        {protocol:"ss2022",port:$ss_port,shadowtls_password:$ENV.SB_JQ_ST_PASSWORD,
         ss2022_password:$ENV.SB_JQ_SS_PASSWORD,method:$method,shadowtls_sni:$shadowtls_sni},
        {protocol:"anytls",port:$anytls_port,anytls_password:$ENV.SB_JQ_ANYTLS_PASSWORD,tls_sni:$tls_sni}
      ]
    }]' \
    --arg name "$name" --argjson ss_port "$ss_port" --argjson anytls_port "$anytls_port" \
    --arg limit "$limit" --arg anchor "$anchor" --argjson metered "$metered" --arg expires_at "$expires_at" \
    --arg method "$method" --arg shadowtls_sni "$shadowtls_sni" --arg tls_sni "$tls_sni" \
    --arg created_at "$(date -Iseconds)"
}

state_add_user_endpoint() {
  local name="$1" endpoint="$2"
  SB_JQ_ENDPOINT="$endpoint" atomic_state_update '
    (.users[] | select(.name == $name) | .endpoints) += [($ENV.SB_JQ_ENDPOINT | fromjson)]
  ' --arg name "$name"
}

state_remove_user_endpoint() {
  local name="$1" protocol="$2"
  atomic_state_update '
    .users |= map(
      if .name == $name then
        .endpoints = [.endpoints[] | select(.protocol != $protocol)] |
        .endpoints[0] as $primary |
        del(.anytls_password,.tls_sni,.shadowtls_password,.ss2022_password,.method,.shadowtls_sni) |
        .protocol = $primary.protocol | .port = $primary.port |
        if $primary.protocol == "anytls" then
          .anytls_password = $primary.anytls_password | .tls_sni = $primary.tls_sni
        else
          .shadowtls_password = $primary.shadowtls_password |
          .ss2022_password = $primary.ss2022_password |
          .method = $primary.method | .shadowtls_sni = $primary.shadowtls_sni
        end
      else . end)
  ' --arg name "$name" --arg protocol "$protocol"
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
       if (.protocol // "ss2022") == "anytls" then
         .protocol = "anytls" |
         .endpoints[0] = {protocol:"anytls",port:.port,anytls_password:.anytls_password,tls_sni:.tls_sni}
       else
         .protocol = "ss2022" |
         .endpoints[0] = {protocol:"ss2022",port:.port,shadowtls_password:.shadowtls_password,
                          ss2022_password:.ss2022_password,method:.method,shadowtls_sni:.shadowtls_sni}
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
            if .protocol == "ss2022" then .shadowtls_sni = $sni else . end
          end)
      else . end |
      if (.protocol // "ss2022") == $protocol then
        if $protocol == "anytls" then .tls_sni = $sni else .shadowtls_sni = $sni end
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
  [[ -f /etc/sing-box/cert/anytls.crt && -f /etc/sing-box/cert/anytls.key ]]
}

check_new_user_conflicts() {
  local protocol="$1" name="$2" port="$3"
  case "$protocol" in
    ss2022|anytls) ;;
    *) die "内部错误：不支持的新增用户协议：$protocol";;
  esac
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
  if [[ "$protocol" == ss2022 ]]; then
    tag_exists_in_config "st-$name" && die "sing-box 已存在 tag：st-$name"
    tag_exists_in_config "ss-$name" && die "sing-box 已存在 tag：ss-$name"
    tag_exists_in_config "ss-udp-$name" && die "sing-box 已存在 tag：ss-udp-$name"
  else
    tag_exists_in_config "anytls-$name" && die "tag 已存在"
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
  local protocol="$1" name="$2" port="$3"
  validate_port "$port"
  port_in_state "$port" && die "端口已被脚本记录占用：$port"
  port_is_listening "$port" && die "端口已被其他服务监听：$port"
  nfuse_port_exists "$port" && die "Nfuse 已管理端口：$port"
  if [[ "$protocol" == anytls ]]; then
    anytls_certificate_ready || die "AnyTLS 证书不存在，请先重新安装环境"
    tag_exists_in_config "anytls-$name" && die "sing-box 已存在 tag：anytls-$name"
  else
    tag_exists_in_config "st-$name" && die "sing-box 已存在 tag：st-$name"
    tag_exists_in_config "ss-$name" && die "sing-box 已存在 tag：ss-$name"
    tag_exists_in_config "ss-udp-$name" && die "sing-box 已存在 tag：ss-udp-$name"
  fi
  return 0
}

cmd_add() {
  local mode="$1"; shift
  local name="${1:-}" port="${2:-}" limit="${3:-}" anchor="${4:-}" months="${5:-}" method shadowtls_sni metered=true expires_at
  if [[ "$mode" == self ]]; then
    (( $# == 4 )) || die "用法：$PROGRAM add-me <用户名> <公网端口> <加密方式> <ShadowTLS-SNI>"
    method="$3"; shadowtls_sni="$4"
    metered=false
    expires_at=""
  else
    (( $# == 7 )) || die "用法：$PROGRAM add <用户名> <公网端口> <配额GiB> <账单日1-28> <有效期月数> <加密方式> <ShadowTLS-SNI>"
    method="$6"; shadowtls_sni="$7"
  fi

  validate_name "$name"
  validate_port "$port"
  validate_ss2022_method "$method"
  validate_shadowtls_sni "$shadowtls_sni"
  if [[ "$metered" == true ]]; then
    [[ "$months" =~ ^[1-9][0-9]*$ ]] || die "有效期月数必须是正整数"
    expires_at="$(date -d "+${months} month" '+%Y-%m-%dT%H:%M:%S%z')"
  fi
  if [[ "$metered" == true ]]; then
    validate_limit "$limit"
    validate_anchor "$anchor"
  fi
  check_new_user_conflicts ss2022 "$name" "$port"

  local st_password ss_password fragment
  st_password="$(generate_st_password)"
  ss_password="$(generate_ss_password "$method")"
  fragment="$(make_user_inbounds "$name" "$port" "$st_password" "$ss_password" "$method" "$shadowtls_sni")"
  ensure_safe_ssh_for_singbox_restart || return 0
  start_managed_operation "add-user:$name" || return 1

  run_managed_step state_add_user "$name" "$port" "$st_password" "$ss_password" "$limit" "$anchor" "$metered" "$expires_at" "$method" "$shadowtls_sni" || return 1
  register_new_user_nfuse "$name" "$port" "$metered" "$limit" "$anchor" || return 1
  run_managed_step append_inbounds "$fragment" || return 1
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
  check_new_user_conflicts anytls "$name" "$port"
  local password fragment
  password="$(generate_st_password)"
  fragment="$(make_anytls_inbound "$name" "$port" "$password")"
  ensure_safe_ssh_for_singbox_restart || return 0
  start_managed_operation "add-anytls-user:$name" || return 1
  run_managed_step state_add_anytls "$name" "$port" "$password" "$limit" "$anchor" "$metered" "$expires_at" "$tls_sni" || return 1
  register_new_user_nfuse "$name" "$port" "$metered" "$limit" "$anchor" || return 1
  run_managed_step append_inbounds "$fragment" || return 1
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
  local method shadowtls_sni tls_sni metered=true expires_at=""
  if [[ "$mode" == self ]]; then
    (( $# == 6 )) || die "用法：$PROGRAM add-multi-me <用户名> <SS端口> <AnyTLS端口> <加密方式> <ShadowTLS-SNI> <AnyTLS-SNI>"
    method="$4"; shadowtls_sni="$5"; tls_sni="$6"; metered=false
    limit=""; anchor=""
  else
    (( $# == 9 )) || die "用法：$PROGRAM add-multi <用户名> <SS端口> <AnyTLS端口> <配额GiB> <账单日> <有效期月数> <加密方式> <ShadowTLS-SNI> <AnyTLS-SNI>"
    method="$7"; shadowtls_sni="$8"; tls_sni="$9"
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
  validate_shadowtls_sni "$shadowtls_sni"
  validate_shadowtls_sni "$tls_sni"
  check_new_user_conflicts ss2022 "$name" "$ss_port"
  check_new_user_conflicts anytls "$name" "$anytls_port"

  local st_password ss_password anytls_password prospective fragment
  st_password="$(generate_st_password)" || return 1
  ss_password="$(generate_ss_password "$method")" || return 1
  anytls_password="$(generate_st_password)" || return 1
  prospective="$(SB_JQ_ST_PASSWORD="$st_password" SB_JQ_SS_PASSWORD="$ss_password" SB_JQ_ANYTLS_PASSWORD="$anytls_password" jq -cn \
    --arg name "$name" --argjson ss_port "$ss_port" --argjson anytls_port "$anytls_port" \
    --arg method "$method" --arg shadowtls_sni "$shadowtls_sni" --arg tls_sni "$tls_sni" '
      {name:$name,status:"active",endpoints:[
        {protocol:"ss2022",port:$ss_port,shadowtls_password:$ENV.SB_JQ_ST_PASSWORD,
         ss2022_password:$ENV.SB_JQ_SS_PASSWORD,method:$method,shadowtls_sni:$shadowtls_sni},
        {protocol:"anytls",port:$anytls_port,anytls_password:$ENV.SB_JQ_ANYTLS_PASSWORD,tls_sni:$tls_sni}
      ]}')" || return 1
  fragment="$(make_user_inbounds_from_state "$prospective")" || return 1
  ensure_safe_ssh_for_singbox_restart || return 0
  start_managed_operation "add-multi-user:$name" || return 1

  # 先登记可回滚的账户状态，再把两个端口纳入同一流量账户，最后才开放认证入口。
  run_managed_step state_add_multi_user "$name" "$ss_port" "$anytls_port" "$st_password" "$ss_password" "$anytls_password" \
    "$limit" "$anchor" "$metered" "$expires_at" "$method" "$shadowtls_sni" "$tls_sni" || return 1
  register_new_user_nfuse_ports "$name" "$metered" "$limit" "$anchor" "$ss_port" "$anytls_port" || return 1
  run_managed_step append_inbounds "$fragment" || return 1
  run_managed_step check_singbox_and_restart || return 1
  finish_managed_operation || return 1

  if [[ "$metered" == true ]]; then
    log "双协议用户创建成功：${name}，SS2022 端口：${ss_port}，AnyTLS 端口：${anytls_port}，共享每月 ${limit} GiB"
  else
    log "双协议自用用户创建成功：${name}，SS2022 端口：${ss_port}，AnyTLS 端口：${anytls_port}（共享不限额统计）"
  fi
  cmd_export "$name"
}

cmd_add_user_endpoint() {
  local name="$1" protocol="$2" port="$3" method="${4:-}" sni="$5"
  local user status metered expected_tier nfuse_json endpoint prospective fragment password st_password ss_password
  validate_name "$name"
  user_exists "$name" || die "用户不存在：$name"
  user="$(get_user_json "$name")" || return 1
  jq -e '.endpoints | type == "array" and length < 2' <<<"$user" >/dev/null || die "用户已经拥有全部支持的协议"
  jq -e --arg protocol "$protocol" 'all(.endpoints[]; .protocol != $protocol)' <<<"$user" >/dev/null || die "用户已经拥有该协议"
  case "$protocol" in
    ss2022) validate_ss2022_method "$method";;
    anytls) [[ -z "$method" ]] || die "AnyTLS 不支持 SS2022 加密方式";;
    *) die "不支持的协议：$protocol";;
  esac
  validate_shadowtls_sni "$sni"
  check_new_endpoint_conflicts "$protocol" "$name" "$port"
  status="$(jq -er '.status | select(. == "active" or . == "disabled")' <<<"$user")" || return 1
  metered="$(jq -er '(.metered // (.limit_gib != null)) | select(type == "boolean")' <<<"$user")" || return 1
  expected_tier="$([[ "$metered" == true ]] && echo a || echo c)"
  nfuse_json="$(nfuse list --json)" || die "无法读取流量统计数据，请查看服务状态"
  jq -e --arg name "$name" --arg tier "$expected_tier" '.[] | select(.name == $name and .tier == $tier)' <<<"$nfuse_json" >/dev/null ||
    die "找不到用户 $name 的正确流量记录，请先运行「服务与配置检查」"

  if [[ "$protocol" == anytls ]]; then
    password="$(generate_st_password)" || return 1
    endpoint="$(SB_JQ_PASSWORD="$password" jq -cn --argjson port "$port" --arg sni "$sni" \
      '{protocol:"anytls",port:$port,anytls_password:$ENV.SB_JQ_PASSWORD,tls_sni:$sni}')" || return 1
  else
    st_password="$(generate_st_password)" || return 1
    ss_password="$(generate_ss_password "$method")" || return 1
    endpoint="$(SB_JQ_ST_PASSWORD="$st_password" SB_JQ_SS_PASSWORD="$ss_password" jq -cn \
      --argjson port "$port" --arg method "$method" --arg sni "$sni" \
      '{protocol:"ss2022",port:$port,shadowtls_password:$ENV.SB_JQ_ST_PASSWORD,
       ss2022_password:$ENV.SB_JQ_SS_PASSWORD,method:$method,shadowtls_sni:$sni}')" || return 1
  fi
  prospective="$(SB_JQ_ENDPOINT="$endpoint" jq -c '.endpoints += [($ENV.SB_JQ_ENDPOINT | fromjson)]' <<<"$user")" || return 1
  if [[ "$status" == active ]]; then
    fragment="$(make_user_inbounds_from_state "$prospective")" || return 1
    ensure_safe_ssh_for_singbox_restart || return 0
  fi
  start_managed_operation "add-user-endpoint:$name:$protocol" || return 1
  run_managed_step nfuse port add "$name" "$port" || return 1
  run_managed_step nfuse persist || return 1
  run_managed_step state_add_user_endpoint "$name" "$endpoint" || return 1
  if [[ "$status" == active ]]; then
    run_managed_step replace_user_inbounds "$name" "$fragment" || return 1
    rebuild_user_splits_if_needed "$name" || return 1
    run_managed_step check_singbox_and_restart || return 1
  fi
  finish_managed_operation || return 1
  log "已为用户 ${name} 添加协议：$([[ "$protocol" == anytls ]] && echo AnyTLS || echo 'SS2022 + ShadowTLS')（端口 ${port}，共享原流量与有效期）"
  cmd_export "$name"
}

cmd_remove_user_endpoint() {
  local name="$1" protocol="$2" user status port nfuse_json port_id prospective fragment=""
  validate_name "$name"
  user_exists "$name" || die "用户不存在：$name"
  user="$(get_user_json "$name")" || return 1
  jq -e '.endpoints | type == "array" and length > 1' <<<"$user" >/dev/null || die "不能移除用户唯一的连接协议；如不再需要该用户，请删除用户"
  jq -e --arg protocol "$protocol" 'any(.endpoints[]; .protocol == $protocol)' <<<"$user" >/dev/null || die "用户没有该协议"
  port="$(jq -er --arg protocol "$protocol" '.endpoints[] | select(.protocol == $protocol) | .port' <<<"$user")" || return 1
  nfuse_json="$(nfuse list --json)" || die "无法读取流量统计数据，请查看服务状态"
  port_id="$(jq -er --arg name "$name" --argjson port "$port" \
    '.[] | select(.name == $name) | .ports[] | select(.start == $port and .end == $port) | .id' <<<"$nfuse_json")" ||
    die "协议端口没有正确接入流量统计，请先运行「服务与配置检查」"
  prospective="$(jq -c --arg protocol "$protocol" '
    .endpoints = [.endpoints[] | select(.protocol != $protocol)] |
    .endpoints[0] as $primary |
    del(.anytls_password,.tls_sni,.shadowtls_password,.ss2022_password,.method,.shadowtls_sni) |
    .protocol = $primary.protocol | .port = $primary.port |
    if $primary.protocol == "anytls" then .anytls_password=$primary.anytls_password | .tls_sni=$primary.tls_sni
    else .shadowtls_password=$primary.shadowtls_password | .ss2022_password=$primary.ss2022_password |
      .method=$primary.method | .shadowtls_sni=$primary.shadowtls_sni end' <<<"$user")" || return 1
  status="$(jq -er '.status | select(. == "active" or . == "disabled")' <<<"$user")" || return 1
  if [[ "$status" == active ]]; then
    fragment="$(make_user_inbounds_from_state "$prospective")" || return 1
    ensure_safe_ssh_for_singbox_restart || return 0
  fi
  start_managed_operation "remove-user-endpoint:$name:$protocol" || return 1
  run_managed_step state_remove_user_endpoint "$name" "$protocol" || return 1
  if [[ "$status" == active ]]; then
    run_managed_step replace_user_inbounds "$name" "$fragment" || return 1
    rebuild_user_splits_if_needed "$name" || return 1
    run_managed_step check_singbox_and_restart || return 1
  fi
  # 先关闭监听并重启成功，最后再解除流量端口，避免残留未计费入口。
  run_managed_step nfuse port rm "$port_id" || return 1
  run_managed_step nfuse persist || return 1
  finish_managed_operation || return 1
  log "已移除用户 ${name} 的协议：$([[ "$protocol" == anytls ]] && echo AnyTLS || echo 'SS2022 + ShadowTLS')；共享账户与用量保持不变"
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
  ensure_safe_ssh_for_singbox_restart || return 0
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
  local user status endpoint protocol port fragment metered nfuse_json expected_tier
  user="$(get_user_json "$name")" || return 1
  status="$(jq -er '.status | select(type == "string" and length > 0)' <<<"$user")" || return 1
  [[ "$status" == "disabled" ]] || die "用户当前不是 disabled 状态：$status"

  while IFS= read -r endpoint; do
    [[ -n "$endpoint" ]] || continue
    protocol="$(jq -er '.protocol' <<<"$endpoint")" || return 1
    if [[ "$protocol" == anytls ]]; then
      tag_exists_in_config "anytls-$name" && die "sing-box 已存在 AnyTLS tag"
    else
      tag_exists_in_config "st-$name" && die "sing-box 已存在 tag：st-$name"
      tag_exists_in_config "ss-$name" && die "sing-box 已存在 tag：ss-$name"
      tag_exists_in_config "ss-udp-$name" && die "sing-box 已存在 tag：ss-udp-$name"
    fi
  done < <(jq -c 'if (.endpoints | type) == "array" then .endpoints[] else {protocol:(.protocol // "ss2022")} end' <<<"$user")
  fragment="$(make_user_inbounds_from_state "$user")" || return 1
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
  if ! ensure_safe_ssh_for_singbox_restart; then
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

cmd_renew() {
  local name="$1" months="$2" user expires status now_epoch expires_epoch base_epoch base_time new_expiry
  validate_name "$name"
  [[ "$months" =~ ^[1-9][0-9]*$ ]] || die "续期月数必须是正整数"
  user_exists "$name" || die "用户不存在：$name"
  user="$(get_user_json "$name")"
  expires="$(jq -r '.expires_at // empty' <<<"$user")"
  [[ -n "$expires" ]] || die "自用用户没有有效期，不能续期"
  status="$(jq -r '.status' <<<"$user")"
  now_epoch="$(date +%s)"
  expires_epoch="$(date -d "$expires" +%s)"
  if ((expires_epoch > now_epoch)); then base_epoch="$expires_epoch"; else base_epoch="$now_epoch"; fi
  base_time="$(date -d "@$base_epoch" '+%Y-%m-%d %H:%M:%S')"
  new_expiry="$(date -d "$base_time +${months} month" '+%Y-%m-%dT%H:%M:%S%z')"
  if [[ "$status" == disabled ]]; then
    prepare_user_enable "$name" || return 1
  fi
  start_managed_operation "renew-user:$name" || return 1
  run_managed_step state_set_expiry "$name" "$new_expiry" || return 1
  if [[ "$status" == disabled ]]; then
    if ! run_managed_step enable_user_without_transaction "$name"; then
      log "续期和自动启用失败，已恢复到续期前状态"
      return 1
    fi
  fi
  finish_managed_operation || return 1
  log "用户续期成功：${name}，新到期时间：${new_expiry}"
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
  local name="$1" new_port="$2" new_sni="$3" new_method="$4" new_anchor="$5" new_expiry="$6" target_protocol="${7:-}"
  local user endpoint protocol metered status old_port old_sni old_method old_anchor old_expiry new_user fragment=""
  local config_changed=false method_changed=false nfuse_changed=false nfuse_json="" old_port_id="" limit expected_tier

  validate_name "$name"
  user_exists "$name" || die "用户不存在：$name"
  user="$(get_user_json "$name")" || return 1
  [[ -n "$target_protocol" ]] || target_protocol="$(jq -er '.protocol // "ss2022"' <<<"$user")"
  endpoint="$(jq -ec --arg protocol "$target_protocol" '
    if (.endpoints | type) == "array" then .endpoints[] | select(.protocol == $protocol)
    elif (.protocol // "ss2022") == "anytls" then
      {protocol:"anytls",port:.port,anytls_password:.anytls_password,tls_sni:.tls_sni} | select(.protocol == $protocol)
    else
      {protocol:"ss2022",port:.port,shadowtls_password:.shadowtls_password,ss2022_password:.ss2022_password,
       method:.method,shadowtls_sni:.shadowtls_sni} | select(.protocol == $protocol)
    end
  ' <<<"$user")" || die "用户没有该协议：$target_protocol"
  protocol="$(jq -er '.protocol | select(. == "ss2022" or . == "anytls")' <<<"$endpoint")" || return 1
  metered="$(jq -r '(.metered // (.limit_gib != null)) | select(type == "boolean")' <<<"$user")" || return 1
  [[ "$metered" == true || "$metered" == false ]] || return 1
  status="$(jq -er '.status | select(. == "active" or . == "disabled")' <<<"$user")" || return 1
  old_port="$(jq -er '.port | select(type == "number" and . == floor and . >= 1 and . <= 65535)' <<<"$endpoint")" || return 1
  if [[ "$new_port" == "$old_port" ]]; then validate_migration_port "$new_port"; else validate_port "$new_port"; fi

  if [[ "$protocol" == anytls ]]; then
    old_sni="$(jq -er '.tls_sni | select(type == "string" and length > 0)' <<<"$endpoint")" || return 1
    [[ -z "$new_method" ]] || die "AnyTLS 用户不支持 SS2022 加密方式"
  else
    old_sni="$(jq -er '.shadowtls_sni | select(type == "string" and length > 0)' <<<"$endpoint")" || return 1
    old_method="$(jq -er '.method | select(type == "string" and length > 0)' <<<"$endpoint")" || return 1
    validate_ss2022_method "$new_method"
  fi
  validate_shadowtls_sni "$new_sni"

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
    --arg protocol "$protocol" --argjson port "$new_port" --arg sni "$new_sni" --arg method "$new_method" \
    --arg anchor "$new_anchor" --arg expiry "$new_expiry" \
    'if (.endpoints | type) != "array" then
       if (.protocol // "ss2022") == "anytls" then
         .endpoints=[{protocol:"anytls",port:.port,anytls_password:.anytls_password,tls_sni:.tls_sni}]
       else .endpoints=[{protocol:"ss2022",port:.port,shadowtls_password:.shadowtls_password,
         ss2022_password:.ss2022_password,method:.method,shadowtls_sni:.shadowtls_sni}] end
     else . end |
     .endpoints |= map(
       if .protocol == $protocol then
         .port = $port |
         if $protocol == "anytls" then .tls_sni = $sni
         else .shadowtls_sni = $sni | .method = $method end
       else . end) |
     if (.protocol // "ss2022") == $protocol then
       .port = $port |
       if $protocol == "anytls" then .tls_sni = $sni
       else .shadowtls_sni = $sni | .method = $method end
     else . end |
     if (.metered // (.limit_gib != null)) then
       .billing_anchor = ($anchor | tonumber) | .expires_at = $expiry
     else . end' <<<"$user")" || return 1
  if [[ "$method_changed" == true ]]; then
    local new_password
    new_password="$(generate_ss_password "$new_method")" || return 1
    new_user="$(SB_JQ_PASSWORD="$new_password" jq -c --arg protocol "$protocol" '
      .endpoints |= map(if .protocol == $protocol then .ss2022_password = $ENV.SB_JQ_PASSWORD else . end) |
      if (.protocol // "ss2022") == $protocol then .ss2022_password = $ENV.SB_JQ_PASSWORD else . end
    ' <<<"$new_user")" || return 1
  fi
  if [[ "$status" == active && "$config_changed" == true ]]; then
    fragment="$(make_user_inbounds_from_state "$new_user")" || return 1
  fi

  if [[ "$config_changed" == true ]]; then ensure_safe_ssh_for_singbox_restart || return 0; fi
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
    select(any(if (.endpoints | type) == "array" then .endpoints[] else {protocol:(.protocol // "ss2022")} end; .protocol == $protocol))] | length' "$STATE_FILE")" || return 1
  mismatched="$(jq --arg protocol "$protocol" --arg sni "$new_sni" '[.users[] |
    (if (.endpoints | type) == "array" then .endpoints[]
     else {protocol:(.protocol // "ss2022"),tls_sni:.tls_sni,shadowtls_sni:.shadowtls_sni} end) |
    select(.protocol == $protocol) | select((if $protocol == "anytls" then .tls_sni else .shadowtls_sni end) != $sni)] | length' "$STATE_FILE")" || return 1
  active_count="$(jq --arg protocol "$protocol" '[.users[] |
    select(.status == "active" and any(if (.endpoints | type) == "array" then .endpoints[] else {protocol:(.protocol // "ss2022")} end; .protocol == $protocol))] | length' "$STATE_FILE")" || return 1
  if [[ "$new_sni" == "$current_sni" && "$mismatched" == 0 ]]; then
    log "全局 SNI 与既有用户已一致，无需修改"
    return 0
  fi

  if [[ "$protocol" == ss2022 ]] && ((active_count > 0)); then ensure_safe_ssh_for_singbox_restart || return 0; fi
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
  ensure_safe_ssh_for_singbox_restart || return 0
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
         ([if ($user.endpoints | type) == "array" then $user.endpoints[].protocol else ($user.protocol // "ss2022") end |
           if . == "anytls" then "AnyTLS" else "SS2022+ShadowTLS" end] | join(" + ")),
         ([if ($user.endpoints | type) == "array" then $user.endpoints[].port else $user.port end | tostring] | join(" / ")),
         (if $user.status == "disabled" then "停用"
          elif $user.status == "active" and $metered and $meter != null and $meter.used_bytes >= $meter.limit_bytes then "配额耗尽"
          elif $user.status == "active" then "启用"
          else $user.status end),
         (if $metered then (($user.limit_gib | tostring) + " GiB") else "不限" end),
         (if $meter == null then "-" else (((((($meter.used_bytes + ($user.usage_offset_bytes // 0)) / 1073741824) * 100 | round) / 100) | tostring) + " GiB") end),
         (if ($metered | not) or $meter == null then "-" else ((((([$meter.limit_bytes - $meter.used_bytes, 0] | max) / 1073741824) * 100 | round) / 100 | tostring) + " GiB") end),
         (if $metered then (($user.billing_anchor | tostring) + " 日") else "-" end),
         (if $user.expires_at == null then "-" else ($user.expires_at | sub("T"; " ") | sub("[+-][0-9]{2}:[0-9]{2}$"; "")) end),
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

cmd_expire() {
  local now name user expires
  now="$(date +%s)"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    user="$(get_user_json "$name")"
    expires="$(jq -r '.expires_at // empty' <<<"$user")"
    [[ -n "$expires" ]] || continue
    [[ "$(jq -r '.status' <<<"$user")" == active ]] || continue
    if (( "$(date -d "$expires" +%s)" <= now )); then
      log "用户已到期，正在停用：$name"
      ensure_safe_ssh_for_singbox_restart || return 0
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

print_shadowrocket_qr() {
  qrencode -t ANSIUTF8 -l L -m 1 -- "$1"
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

  local user endpoint endpoint_user protocol endpoint_count node_name port st_password ss_password method shadowtls_sni server_port shadowrocket_url
  user="$(get_user_json "$name")"
  endpoint_count="$(jq 'if (.endpoints | type) == "array" then .endpoints | length else 1 end' <<<"$user")" || return 1
  while IFS= read -r endpoint; do
    [[ -n "$endpoint" ]] || continue
    protocol="$(jq -er '.protocol' <<<"$endpoint")" || return 1
    port="$(jq -er '.port' <<<"$endpoint")" || return 1
    if ((endpoint_count > 1)); then
      [[ "$protocol" == anytls ]] && node_name="${name}-AnyTLS" || node_name="${name}-SS2022"
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
    st_password="$(jq -r '.shadowtls_password' <<<"$endpoint")"
    ss_password="$(jq -r '.ss2022_password' <<<"$endpoint")"
    method="$(jq -r '.method' <<<"$endpoint")"
    shadowtls_sni="$(jq -r '.shadowtls_sni' <<<"$endpoint")"
    if [[ "$format" == all || "$format" == surge ]]; then
      printf '\n[Surge]\n'
      printf '%s = ss, %s, %s, encrypt-method=%s, password=%s, shadow-tls-password=%s, shadow-tls-sni=%s, shadow-tls-version=3, udp-relay=true\n' \
        "$node_name" "$PUBLIC_SERVER" "$server_port" "$method" "$ss_password" "$st_password" "$shadowtls_sni"
    fi
    if [[ "$format" == all || "$format" == shadowrocket ]]; then
      shadowrocket_url="$(shadowrocket_ss2022_url "$endpoint_user" "$server_port")" || die "无法生成 Shadowrocket SS2022 + ShadowTLS 导入链接"
      render_shadowrocket_export "$shadowrocket_url"
    fi
  done < <(jq -c '
    if (.endpoints | type) == "array" then .endpoints[]
    elif (.protocol // "ss2022") == "anytls" then
      {protocol:"anytls",port:.port,anytls_password:.anytls_password,tls_sni:.tls_sni}
    else
      {protocol:"ss2022",port:.port,shadowtls_password:.shadowtls_password,
       ss2022_password:.ss2022_password,method:.method,shadowtls_sni:.shadowtls_sni}
    end
  ' <<<"$user")
}

validate_split_name() {
  [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$ ]] || die "分流规则名只能包含字母、数字、下划线和连字符，长度 1-32"
}

validate_preset_name() {
  [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$ ]] ||
    die "预置名称只能包含字母、数字、下划线和连字符，长度 1-32"
}

validate_upstream_port() {
  [[ "$1" =~ ^[0-9]+$ ]] || die "出口服务器端口必须是数字"
  ((10#$1 >= 1 && 10#$1 <= 65535)) || die "出口服务器端口必须位于 1-65535"
}

split_rule_format() {
  if [[ "$1" =~ \.srs([?#].*)?$ ]]; then printf 'binary'
  elif [[ "$1" =~ \.json([?#].*)?$ ]]; then printf 'source'
  else return 1
  fi
}

is_public_rule_set_address() {
  local address="$1"
  command -v python3 >/dev/null 2>&1 || return 1
  SB_RULE_SET_ADDRESS="$address" python3 - <<'PY'
import ipaddress
import os
import sys

try:
    address = ipaddress.ip_address(os.environ["SB_RULE_SET_ADDRESS"])
except ValueError:
    sys.exit(1)
sys.exit(0 if address.is_global else 1)
PY
}

rule_set_url_host() {
  local url="$1"
  command -v python3 >/dev/null 2>&1 || return 1
  SB_RULE_SET_URL="$url" python3 - <<'PY'
from urllib.parse import urlsplit
import os
import sys

try:
    parsed = urlsplit(os.environ["SB_RULE_SET_URL"])
    if parsed.scheme != "https" or parsed.username is not None or parsed.password is not None:
        raise ValueError
    parsed.port
    host = parsed.hostname
    if not host or any(ord(char) < 0x20 for char in host):
        raise ValueError
except (ValueError, UnicodeError):
    sys.exit(1)
print(host.rstrip(".").lower())
PY
}

validate_public_rule_set_url() {
  local url="$1" host resolved address
  host="$(rule_set_url_host "$url")" || return 1
  [[ -n "$host" && "$host" != localhost && "$host" != *.localhost && "$host" != *.local ]] || return 1
  if [[ "$host" =~ ^[0-9.]+$ || "$host" == *:* ]]; then
    is_public_rule_set_address "$host" || return 1
    return 0
  fi
  command -v getent >/dev/null 2>&1 || return 1
  resolved="$(getent ahosts "$host" 2>/dev/null | awk '{print $1}' | sort -u)" || return 1
  [[ -n "$resolved" ]] || return 1
  while IFS= read -r address; do
    is_public_rule_set_address "$address" || return 1
  done <<<"$resolved"
}

validate_remote_rule_set() {
  validate_public_rule_set_url "$1" ||
    die "远程规则集地址必须使用 HTTPS，且不能指向本机或内网地址"
  check_rule_set_with_binary "$SINGBOX_BIN" "$1" ||
    die "远程规则集无法通过当前 sing-box 检查，请确认地址、格式和版本兼容性"
}

split_exists() { jq -e --arg name "$1" '.splits[]? | select(.name == $name)' "$STATE_FILE" >/dev/null; }
outbound_preset_exists() { jq -e --arg name "$1" '.outbound_presets[]? | select(.name == $name)' "$STATE_FILE" >/dev/null; }
rule_preset_exists() { jq -e --arg name "$1" '.rule_presets[]? | select(.name == $name)' "$STATE_FILE" >/dev/null; }
split_tag() {
  local name="$1" configured="${2:-}"
  if [[ -n "$configured" ]]; then printf '%s' "$configured"; else printf 'managed-split-%s' "$name"; fi
}
split_out_tag() {
  local name="$1" configured="${2:-}"
  if [[ -n "$configured" ]]; then printf '%s' "$configured"; else printf 'managed-out-%s' "$name"; fi
}
split_transport_tag() { printf 'managed-transport-%s' "$1"; }

# 预置名称是用户可见标识，运行标签只在配置内部使用。固定摘要既避免超长，
# 也让同一预置被多条分流引用时始终指向同一个 sing-box 对象。
stable_managed_tag() {
  local kind="$1" name="$2" prefix digest
  case "$kind" in
    rule) prefix='mpr-';;
    outbound) prefix='mpo-';;
    transport) prefix='mpt-';;
    split-out) prefix='mso-';;
    *) return 1;;
  esac
  digest="$(printf '%s' "${kind}:${name}" | sha256sum | awk '{print $1}')" || return 1
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s%s' "$prefix" "${digest:0:24}"
}

split_runtime_rule_tag_from_json() {
  local split="$1" name preset configured
  configured="$(jq -r '.runtime_rule_tag // ""' <<<"$split")" || return 1
  [[ -z "$configured" ]] || { printf '%s' "$configured"; return 0; }
  preset="$(jq -r '.rule_preset // ""' <<<"$split")" || return 1
  if [[ -n "$preset" ]]; then
    stable_managed_tag rule "$preset"
    return $?
  fi
  name="$(jq -r '.name' <<<"$split")" || return 1
  configured="$(jq -r '.rule_set_tag // ""' <<<"$split")" || return 1
  split_tag "$name" "$configured"
}

split_runtime_out_tag_from_json() {
  local split="$1" name preset configured
  configured="$(jq -r '.runtime_outbound_tag // ""' <<<"$split")" || return 1
  [[ -z "$configured" ]] || { printf '%s' "$configured"; return 0; }
  preset="$(jq -r '.outbound_preset // ""' <<<"$split")" || return 1
  if [[ -n "$preset" ]]; then
    stable_managed_tag outbound "$preset"
    return $?
  fi
  name="$(jq -r '.name' <<<"$split")" || return 1
  configured="$(jq -r '.outbound_tag // ""' <<<"$split")" || return 1
  split_out_tag "$name" "$configured"
}

split_runtime_transport_tag_from_json() {
  local split="$1" name preset configured
  configured="$(jq -r '.runtime_transport_tag // ""' <<<"$split")" || return 1
  [[ -z "$configured" ]] || { printf '%s' "$configured"; return 0; }
  preset="$(jq -r '.outbound_preset // ""' <<<"$split")" || return 1
  if [[ -n "$preset" ]]; then
    stable_managed_tag transport "$preset"
    return $?
  fi
  name="$(jq -r '.name' <<<"$split")" || return 1
  split_transport_tag "$name"
}

normalize_split_runtime_tags_json() {
  local split="$1" rule_preset outbound_preset rule_tag out_tag transport_tag
  rule_preset="$(jq -r '.rule_preset // ""' <<<"$split")" || return 1
  outbound_preset="$(jq -r '.outbound_preset // ""' <<<"$split")" || return 1
  if [[ -n "$rule_preset" ]]; then
    rule_tag="$(stable_managed_tag rule "$rule_preset")" || return 1
    split="$(jq -c --arg tag "$rule_tag" '.runtime_rule_tag=$tag' <<<"$split")" || return 1
  fi
  if [[ -n "$outbound_preset" ]]; then
    out_tag="$(stable_managed_tag outbound "$outbound_preset")" || return 1
    transport_tag="$(stable_managed_tag transport "$outbound_preset")" || return 1
    split="$(jq -c --arg out "$out_tag" --arg transport "$transport_tag" '.runtime_outbound_tag=$out | .runtime_transport_tag=$transport' <<<"$split")" || return 1
  fi
  printf '%s' "$split"
}

validate_outbound_tag() {
  [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$ ]] || die "出口名称只能包含字母、数字、下划线和连字符，长度 1-32"
  [[ "$1" != direct ]] || die "出口名称 direct 为系统保留名称，请换一个名称"
}

stored_split_out_tag() {
  local name="$1"
  jq -r --arg name "$name" '.splits[] | select(.name == $name) | (.outbound_tag // ("managed-out-" + .name))' "$STATE_FILE"
}

stored_split_rule_tag() {
  local name="$1"
  jq -r --arg name "$name" '.splits[] | select(.name == $name) | (.rule_set_tag // ("managed-split-" + .name))' "$STATE_FILE"
}

remove_split_config() {
  local name="$1" split tag out_tag transport_tag stored_tag stored_out stored_transport
  split="$(jq -ec --arg name "$name" '.splits[] | select(.name == $name)' "$STATE_FILE")" || return 1
  tag="$(split_runtime_rule_tag_from_json "$split")" || return 1
  out_tag="$(split_runtime_out_tag_from_json "$split")" || return 1
  transport_tag="$(split_runtime_transport_tag_from_json "$split")" || return 1
  stored_tag="$(stored_split_rule_tag "$name")" || return 1
  stored_out="$(stored_split_out_tag "$name")" || return 1
  stored_transport="$(split_transport_tag "$name")"
  rewrite_singbox_config '
    .route.rules = [(.route.rules // [])[] | select(((.rule_set // "") == $tag or (.rule_set // "") == $stored_tag) | not)] |
    .route.rule_set = [(.route.rule_set // [])[] | select((.tag == $tag or .tag == $stored_tag) | not)] |
    .outbounds = [(.outbounds // [])[] |
      select((.tag == $out_tag or .tag == $transport_tag or .tag == $stored_out or .tag == $stored_transport) | not)]
  ' --arg tag "$tag" --arg stored_tag "$stored_tag" --arg out_tag "$out_tag" --arg transport_tag "$transport_tag" \
    --arg stored_out "$stored_out" --arg stored_transport "$stored_transport"
}

build_split_outbounds() {
  local name="$1" upstream="$2" out_tag="$3" transport_tag="${4:-}" protocol
  protocol="$(jq -r '.protocol' <<<"$upstream")"
  [[ -n "$transport_tag" ]] || transport_tag="$(split_transport_tag "$name")"
  case "$protocol" in
    anytls)
      SB_JQ_UPSTREAM="$upstream" jq -cn --arg tag "$out_tag" '($ENV.SB_JQ_UPSTREAM | fromjson) as $u | [{type:"anytls",tag:$tag,server:$u.server,server_port:$u.server_port,password:$u.password,domain_resolver:"local",tls:{enabled:true,server_name:$u.sni,insecure:$u.insecure}}]'
      ;;
    shadowsocks)
      SB_JQ_UPSTREAM="$upstream" jq -cn --arg tag "$out_tag" '($ENV.SB_JQ_UPSTREAM | fromjson) as $u | [{type:"shadowsocks",tag:$tag,server:$u.server,server_port:$u.server_port,method:$u.method,password:$u.password,domain_resolver:"local"}]'
      ;;
    ss_shadowtls)
      SB_JQ_UPSTREAM="$upstream" jq -cn --arg tag "$out_tag" --arg transport "$transport_tag" '($ENV.SB_JQ_UPSTREAM | fromjson) as $u | [
        {type:"shadowsocks",tag:$tag,server:$u.server,server_port:$u.server_port,method:$u.method,password:$u.ss_password,detour:$transport},
        {type:"shadowtls",tag:$transport,server:$u.server,server_port:$u.server_port,version:3,password:$u.shadowtls_password,domain_resolver:"local",tls:{enabled:true,server_name:$u.sni,insecure:$u.insecure}}
      ]'
      ;;
    *) die "不支持的上游协议：$protocol";;
  esac
}

validate_upstream_json() {
  jq -e '
    (type == "object") and
    (.server | type == "string" and length > 0 and (test("[[:space:]]") | not)) and
    (.server_port | type == "number" and . == floor and . >= 1 and . <= 65535) and
    if .protocol == "anytls" then
      (.password | type == "string" and length > 0) and
      (.sni | type == "string" and length > 0) and
      (.insecure | type == "boolean")
    elif .protocol == "shadowsocks" then
      (.method | type == "string" and length > 0) and
      (.password | type == "string" and length > 0)
    elif .protocol == "ss_shadowtls" then
      (.method | type == "string" and startswith("2022-")) and
      (.ss_password | type == "string" and length > 0) and
      (.shadowtls_password | type == "string" and length > 0) and
      (.sni | type == "string" and length > 0) and
      (.insecure | type == "boolean")
    else false end
  ' <<<"$1" >/dev/null
}

validate_upstream_candidate() {
  local upstream="$1" name out_tag outbounds candidate
  validate_upstream_json "$upstream" || die "预置出口内容不完整或格式无效"
  name="preset-check-${BASHPID:-$$}"
  out_tag="${name}-out"
  outbounds="$(build_split_outbounds "$name" "$upstream" "$out_tag")" || return 1
  candidate="$(mktemp /tmp/sb-preset-outbound.XXXXXX.json)" || return 1
  register_temp_path "$candidate"
  if ! SB_JQ_OUTBOUNDS="$outbounds" jq '($ENV.SB_JQ_OUTBOUNDS | fromjson) as $outbounds | .outbounds += $outbounds' "$SINGBOX_CONFIG" > "$candidate" ||
     ! "$SINGBOX_BIN" check -c "$candidate" >/dev/null 2>&1; then
    rm -f -- "$candidate"
    die "预置出口无法通过当前 sing-box 检查，请确认协议和连接参数"
  fi
  rm -f -- "$candidate"
}

apply_split_config() {
  local name="$1" url="$2" scope="$3" user="$4" upstream="$5" out_tag="$6" tag="$7" transport_tag="${8:-}" format outbounds
  outbounds="$(build_split_outbounds "$name" "$upstream" "$out_tag" "$transport_tag")"
  format="$(split_rule_format "$url")" || die "远程规则集地址必须指向 .srs 或 .json 文件"
  SB_JQ_NEW_OUTBOUNDS="$outbounds" rewrite_singbox_config '
    ($ENV.SB_JQ_NEW_OUTBOUNDS | fromjson) as $new_outbounds |
    .route.rules = [(.route.rules // [])[] | select((.rule_set // "") != $tag)] |
    .route.rule_set = [(.route.rule_set // [])[] | select(.tag != $tag)] |
    .outbounds += $new_outbounds |
    .route.rule_set += [{type:"remote",tag:$tag,format:$format,url:$url,download_detour:"direct",update_interval:"24h"}] |
    .route.rules += [
      ({rule_set:$tag,action:"route",outbound:$out_tag} +
       (if $scope == "user" then {inbound:[("st-"+$user),("ss-"+$user),("ss-udp-"+$user),("anytls-"+$user)]} else {} end))
    ]
  ' --arg tag "$tag" --arg out_tag "$out_tag" --arg url "$url" --arg format "$format" --arg scope "$scope" --arg user "$user"
}

collect_managed_split_tags() {
  local split rows rule_tags='[]' out_tags='[]' transport_tags='[]' tag stored
  rows="$(jq -c '.splits[]' "$STATE_FILE")" || return 1
  while IFS= read -r split; do
    [[ -n "$split" ]] || continue
    tag="$(split_runtime_rule_tag_from_json "$split")" || return 1
    stored="$(jq -r '.rule_set_tag // ("managed-split-" + .name)' <<<"$split")" || return 1
    rule_tags="$(jq -cn --argjson values "$rule_tags" --arg a "$tag" --arg b "$stored" '$values + [$a,$b] | unique')" || return 1
    tag="$(split_runtime_out_tag_from_json "$split")" || return 1
    stored="$(jq -r '.outbound_tag // ("managed-out-" + .name)' <<<"$split")" || return 1
    out_tags="$(jq -cn --argjson values "$out_tags" --arg a "$tag" --arg b "$stored" '$values + [$a,$b] | unique')" || return 1
    tag="$(split_runtime_transport_tag_from_json "$split")" || return 1
    stored="$(jq -r '"managed-transport-" + .name' <<<"$split")" || return 1
    transport_tags="$(jq -cn --argjson values "$transport_tags" --arg a "$tag" --arg b "$stored" '$values + [$a,$b] | unique')" || return 1
  done <<<"$rows"
  jq -cn --argjson rules "$rule_tags" --argjson outbounds "$out_tags" --argjson transports "$transport_tags" \
    '{rule_tags:$rules,out_tags:$outbounds,transport_tags:$transports}'
}

collect_legacy_split_cleanup_plan_from_config() {
  local config_json="$1" managed_tags_json="$2" managed_urls
  managed_urls="$(jq -c '[.splits[]?.url | select(type == "string" and length > 0)] | unique' "$STATE_FILE")" || return 1
  jq -c --argjson tags "$managed_tags_json" --argjson managed_urls "$managed_urls" '
    . as $config |
    [
      ($config.route.rule_set // [])[] |
      . as $rule_set |
      select((.url // "") as $url | ($managed_urls | index($url)) != null) |
      select(($tags.rule_tags | index($rule_set.tag // "")) == null) |
      .tag
    ] | unique as $legacy_rules |
    [
      ($config.route.rules // [])[] |
      . as $route |
      select(($legacy_rules | index($route.rule_set // "")) != null) |
      (.outbound // empty) |
      select(type == "string" and length > 0 and . != "direct")
    ] | unique as $legacy_primary_outs |
    [
      ($config.outbounds // [])[] |
      . as $outbound |
      select(($legacy_primary_outs | index($outbound.tag // "")) != null) |
      (.detour // empty) |
      select(type == "string" and length > 0)
    ] | unique as $legacy_detours |
    {
      rule_tags:$legacy_rules,
      out_tags:(($legacy_primary_outs + $legacy_detours) | unique)
    }
  ' <<<"$config_json"
}

legacy_split_cleanup_pending() {
  local config tags cleanup
  config="$("$SINGBOX_BIN" format -c "$SINGBOX_CONFIG")" || return 1
  tags="$(collect_managed_split_tags)" || return 1
  cleanup="$(collect_legacy_split_cleanup_plan_from_config "$config" "$tags")" || return 1
  jq -e '(.rule_tags | length) > 0' <<<"$cleanup" >/dev/null
}

remove_all_managed_split_config() {
  local tags rule_tags out_tags transport_tags
  tags="$(collect_managed_split_tags)" || return 1
  rule_tags="$(jq -c '.rule_tags' <<<"$tags")" || return 1
  out_tags="$(jq -c '.out_tags' <<<"$tags")" || return 1
  transport_tags="$(jq -c '.transport_tags' <<<"$tags")" || return 1
  rewrite_singbox_config '
    .route.rules = [(.route.rules // [])[] | . as $item | select(($rule_tags | index($item.rule_set // "")) == null)] |
    .route.rule_set = [(.route.rule_set // [])[] | . as $item | select(($rule_tags | index($item.tag)) == null)] |
    .outbounds = [(.outbounds // [])[] | . as $item | select((($out_tags + $transport_tags) | index($item.tag)) == null)]
  ' --argjson rule_tags "$rule_tags" --argjson out_tags "$out_tags" --argjson transport_tags "$transport_tags"
}

split_user_inbound_tags() {
  local user="$1"
  jq -c --arg name "$user" '
    first(.users[]? | select(.name == $name)) as $user |
    if $user == null then []
    else [
      (if ($user.endpoints | type) == "array" then $user.endpoints[] else {protocol:($user.protocol // "ss2022")} end) |
      if .protocol == "anytls" then "anytls-" + $name
      else "st-" + $name, "ss-" + $name, "ss-udp-" + $name end
    ] | unique end
  ' "$STATE_FILE"
}

build_split_runtime_plan() {
  local split_rows split plan name url scope user user_status upstream out_tag rule_tag transport_tag format outbounds rule_set inbounds conflict
  split_rows="$(jq -c '.splits[] | select(.status == "active")' "$STATE_FILE")" || return 1
  plan='{"outbound_groups":[],"rule_sets":[],"routes":[]}'
  while IFS= read -r split; do
    [[ -n "$split" ]] || continue
    name="$(jq -er '.name | select(type == "string" and length > 0)' <<<"$split")" || return 1
    url="$(jq -er '.url | select(type == "string" and length > 0)' <<<"$split")" || return 1
    scope="$(jq -er '.scope | select(. == "all" or . == "user")' <<<"$split")" || return 1
    user="$(jq -er '.user // ""' <<<"$split")" || return 1
    if [[ "$scope" == user ]]; then
      user_status="$(jq -r --arg name "$user" 'first(.users[]? | select(.name == $name) | .status) // "missing"' "$STATE_FILE")" || return 1
      if [[ "$user_status" == disabled ]]; then continue; fi
      if [[ "$user_status" != active ]]; then
        echo "错误：分流 ${name} 指定的用户不存在，请先删除或修改这条分流。" >&2
        return 1
      fi
    fi
    upstream="$(jq -ec '.upstream | select(type == "object")' <<<"$split")" || return 1
    out_tag="$(split_runtime_out_tag_from_json "$split")" || return 1
    rule_tag="$(split_runtime_rule_tag_from_json "$split")" || return 1
    transport_tag="$(split_runtime_transport_tag_from_json "$split")" || return 1
    format="$(split_rule_format "$url")" || return 1
    outbounds="$(build_split_outbounds "$name" "$upstream" "$out_tag" "$transport_tag")" || return 1
    rule_set="$(jq -cn --arg tag "$rule_tag" --arg format "$format" --arg url "$url" \
      '{type:"remote",tag:$tag,format:$format,url:$url,download_detour:"direct",update_interval:"24h"}')" || return 1
    if jq -e --arg tag "$out_tag" 'any(.outbound_groups[]; .tag == $tag)' <<<"$plan" >/dev/null; then
      if ! SB_JQ_OUTBOUNDS="$outbounds" jq -e --arg tag "$out_tag" \
        '($ENV.SB_JQ_OUTBOUNDS | fromjson) as $objects | any(.outbound_groups[]; .tag == $tag and .objects == $objects)' <<<"$plan" >/dev/null; then
          echo "错误：多个分流使用了同一个预置出口名称，但连接参数不同；请重新选择预置出口。" >&2
          return 1
      fi
    else
      plan="$(SB_JQ_OUTBOUNDS="$outbounds" jq -c --arg tag "$out_tag" '($ENV.SB_JQ_OUTBOUNDS | fromjson) as $objects | .outbound_groups += [{tag:$tag,objects:$objects}]' <<<"$plan")" || return 1
    fi
    if jq -e --arg tag "$rule_tag" 'any(.rule_sets[]; .tag == $tag)' <<<"$plan" >/dev/null; then
      jq -e --arg tag "$rule_tag" --argjson item "$rule_set" 'any(.rule_sets[]; .tag == $tag and . == $item)' <<<"$plan" >/dev/null || {
        echo "错误：多个分流使用了同一个预置规则名称，但下载地址不同；请重新选择预置规则。" >&2
        return 1
      }
    else
      plan="$(jq -c --argjson item "$rule_set" '.rule_sets += [$item]' <<<"$plan")" || return 1
    fi
    if [[ "$scope" == all ]]; then inbounds='[]'; else inbounds="$(split_user_inbound_tags "$user")" || return 1; fi
    conflict="$(jq -r --arg rule "$rule_tag" --arg out "$out_tag" --arg scope "$scope" --arg user "$user" '
      first(.routes[] | select(
        .rule_set == $rule and .outbound != $out and
        ($scope == "all" or .scope_all or (.users | index($user) != null))
      ) | "yes") // ""
    ' <<<"$plan")" || return 1
    if [[ -n "$conflict" ]]; then
      echo "错误：同一用户不能让同一条预置规则同时使用两个不同出口。" >&2
      return 1
    fi
    if jq -e --arg rule "$rule_tag" --arg out "$out_tag" 'any(.routes[]; .rule_set == $rule and .outbound == $out)' <<<"$plan" >/dev/null; then
      plan="$(jq -c --arg rule "$rule_tag" --arg out "$out_tag" --arg scope "$scope" --arg user "$user" --argjson inbound "$inbounds" '
        .routes |= map(
          if .rule_set == $rule and .outbound == $out then
            if $scope == "all" then .scope_all = true | .users = [] | .inbound = []
            elif .scope_all then .
            else .users = ((.users + [$user]) | unique) | .inbound = ((.inbound + $inbound) | unique)
            end
          else . end)
      ' <<<"$plan")" || return 1
    else
      plan="$(jq -c --arg rule "$rule_tag" --arg out "$out_tag" --arg scope "$scope" --arg user "$user" --argjson inbound "$inbounds" '
        .routes += [{rule_set:$rule,outbound:$out,scope_all:($scope == "all"),users:(if $scope == "all" then [] else [$user] end),inbound:$inbound}]
      ' <<<"$plan")" || return 1
    fi
  done <<<"$split_rows"
  jq -c '{
    outbounds:[.outbound_groups[].objects[]],
    rule_sets:.rule_sets,
    rules:[.routes[] | ({rule_set:.rule_set,action:"route",outbound:.outbound} + (if .scope_all then {} else {inbound:.inbound} end))]
  }' <<<"$plan"
}

rebuild_all_split_configs() {
  local plan tags config legacy_cleanup
  # 先完整生成计划，任何读取、冲突或格式错误都不得提前改动现有配置。
  plan="$(build_split_runtime_plan)" || return 1
  tags="$(collect_managed_split_tags)" || return 1
  config="$("$SINGBOX_BIN" format -c "$SINGBOX_CONFIG")" || return 1
  legacy_cleanup="$(collect_legacy_split_cleanup_plan_from_config "$config" "$tags")" || return 1
  SB_JQ_PLAN="$plan" rewrite_singbox_config '
    ($ENV.SB_JQ_PLAN | fromjson) as $plan |
    .route.rules = [
      (.route.rules // [])[] | . as $item |
      select(($tags.rule_tags | index($item.rule_set // "")) == null) |
      select(($legacy.rule_tags | index($item.rule_set // "")) == null)
    ] |
    .route.rule_set = [
      (.route.rule_set // [])[] | . as $item |
      select(($tags.rule_tags | index($item.tag)) == null) |
      select(($legacy.rule_tags | index($item.tag)) == null)
    ] |
    ([
      (.route.rules[]?.outbound // empty),
      (.route.final // empty),
      ((.outbounds // [])[] |
        . as $outbound |
        select(($legacy.out_tags | index($outbound.tag // "")) == null) |
        (.detour // empty))
    ] | unique) as $protected_outbounds |
    .outbounds = [
      (.outbounds // [])[] | . as $item |
      select((($tags.out_tags + $tags.transport_tags) | index($item.tag)) == null) |
      select(
        ($legacy.out_tags | index($item.tag)) == null or
        ($protected_outbounds | index($item.tag)) != null
      )
    ] |
    .outbounds += $plan.outbounds |
    .route.rule_set += $plan.rule_sets |
    .route.rules += $plan.rules
  ' --argjson tags "$tags" --argjson legacy "$legacy_cleanup"
}

rebuild_and_finish_split_operation() {
  run_managed_step rebuild_all_split_configs || return 1
  run_managed_step check_singbox_and_restart || return 1
  finish_managed_operation || return 1
}

shared_preset_runtime_is_current() {
  local config rows split scope user user_status rule_tag out_tag transport_tag stored_rule stored_out stored_transport protocol inbounds tags legacy_cleanup
  config="$("$SINGBOX_BIN" format -c "$SINGBOX_CONFIG")" || return 1
  tags="$(collect_managed_split_tags)" || return 1
  legacy_cleanup="$(collect_legacy_split_cleanup_plan_from_config "$config" "$tags")" || return 1
  [[ "$(jq '.rule_tags | length' <<<"$legacy_cleanup")" == 0 ]] || return 1
  rows="$(jq -c '.splits[]? | select(.status == "active" and (((.rule_preset // "") != "") or ((.outbound_preset // "") != "")))' "$STATE_FILE")" || return 1
  while IFS= read -r split; do
    [[ -n "$split" ]] || continue
    scope="$(jq -r '.scope' <<<"$split")" || return 1
    user="$(jq -r '.user // ""' <<<"$split")" || return 1
    if [[ "$scope" == user ]]; then
      user_status="$(jq -r --arg name "$user" 'first(.users[]? | select(.name == $name) | .status) // "missing"' "$STATE_FILE")" || return 1
      [[ "$user_status" == active ]] || continue
    fi
    rule_tag="$(split_runtime_rule_tag_from_json "$split")" || return 1
    out_tag="$(split_runtime_out_tag_from_json "$split")" || return 1
    transport_tag="$(split_runtime_transport_tag_from_json "$split")" || return 1
    stored_rule="$(jq -r '.rule_set_tag // ("managed-split-" + .name)' <<<"$split")" || return 1
    stored_out="$(jq -r '.outbound_tag // ("managed-out-" + .name)' <<<"$split")" || return 1
    stored_transport="$(jq -r '"managed-transport-" + .name' <<<"$split")" || return 1
    [[ "$(jq --arg tag "$rule_tag" '[.route.rule_set[]? | select(.tag == $tag)] | length' <<<"$config")" == 1 ]] || return 1
    [[ "$(jq --arg tag "$out_tag" '[.outbounds[]? | select(.tag == $tag)] | length' <<<"$config")" == 1 ]] || return 1
    if [[ "$stored_rule" != "$rule_tag" ]] && jq -e --arg tag "$stored_rule" '.route.rule_set[]? | select(.tag == $tag)' <<<"$config" >/dev/null; then return 1; fi
    if [[ "$stored_out" != "$out_tag" ]] && jq -e --arg tag "$stored_out" '.outbounds[]? | select(.tag == $tag)' <<<"$config" >/dev/null; then return 1; fi
    protocol="$(jq -r '.upstream.protocol // ""' <<<"$split")" || return 1
    if [[ "$protocol" == ss_shadowtls ]]; then
      [[ "$(jq --arg tag "$transport_tag" '[.outbounds[]? | select(.tag == $tag)] | length' <<<"$config")" == 1 ]] || return 1
      if [[ "$stored_transport" != "$transport_tag" ]] && jq -e --arg tag "$stored_transport" '.outbounds[]? | select(.tag == $tag)' <<<"$config" >/dev/null; then return 1; fi
    fi
    if [[ "$scope" == all ]]; then
      jq -e --arg rule "$rule_tag" --arg out "$out_tag" '
        .route.rules[]? | select(.rule_set == $rule and .outbound == $out and ((.inbound // []) | length == 0))
      ' <<<"$config" >/dev/null || return 1
    else
      inbounds="$(split_user_inbound_tags "$user")" || return 1
      jq -e --arg rule "$rule_tag" --arg out "$out_tag" --argjson expected "$inbounds" '
        .route.rules[]? | select(.rule_set == $rule and .outbound == $out and
          ($expected - (.inbound // []) | length) == 0)
      ' <<<"$config" >/dev/null || return 1
    fi
  done <<<"$rows"
}

shared_preset_runtime_fingerprint() {
  [[ -r "$STATE_FILE" && -r "$SINGBOX_CONFIG" ]] || return 1
  sha256sum "$STATE_FILE" "$SINGBOX_CONFIG" | awk '{print $1}' | tr '\n' ' '
}

shared_preset_runtime_marker_matches() {
  local expected actual
  [[ -r "$SHARED_PRESET_RUNTIME_MARKER" ]] || return 1
  expected="$(shared_preset_runtime_fingerprint)" || return 1
  actual="$(<"$SHARED_PRESET_RUNTIME_MARKER")"
  [[ "$actual" == "$expected" ]]
}

write_shared_preset_runtime_marker() {
  local value directory tmp
  value="$(shared_preset_runtime_fingerprint)" || return 1
  directory="$(dirname "$SHARED_PRESET_RUNTIME_MARKER")"
  install -d -m 700 "$directory" || return 1
  tmp="$(mktemp "$directory/.shared-preset-runtime.XXXXXX")" || return 1
  register_temp_path "$tmp"
  printf '%s\n' "$value" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -- "$tmp" "$SHARED_PRESET_RUNTIME_MARKER"
}

migrate_shared_preset_runtime_configs() {
  [[ -r "$CONF_FILE" ]] || return 0
  command -v jq >/dev/null || return 0
  command -v flock >/dev/null || return 0
  load_runtime_config || return 1
  [[ -f "$STATE_FILE" && -f "$SINGBOX_CONFIG" && -x "$SINGBOX_BIN" && -x "$NFUSE_BIN" && -S "$NFUSE_SOCKET" ]] || return 0
  shared_preset_runtime_marker_matches && return 0
  if shared_preset_runtime_is_current; then
    write_shared_preset_runtime_marker
    return $?
  fi
  exec 9>"$LOCK_FILE" || return 1
  if ! flock -n 9; then release_operation_lock; return 1; fi
  if ! recover_pending_transaction || ! init_state; then release_operation_lock; return 1; fi
  if shared_preset_runtime_is_current; then
    write_shared_preset_runtime_marker || { release_operation_lock; return 1; }
    release_operation_lock
    return 0
  fi
  if ! ensure_safe_ssh_for_singbox_restart; then release_operation_lock; return 0; fi
  if ! start_managed_operation migrate-shared-presets; then release_operation_lock; return 1; fi
  if ! rebuild_and_finish_split_operation; then
    release_operation_lock
    return 1
  fi
  write_shared_preset_runtime_marker || { release_operation_lock; return 1; }
  log "已将重复的预置规则和出口合并为共享配置"
  release_operation_lock
}

state_add_split() {
  SB_JQ_UPSTREAM="$5" atomic_state_update '(
    $ENV.SB_JQ_UPSTREAM | fromjson
  ) as $upstream |
    .splits += [{name:$name,url:$url,scope:$scope,user:(if $scope == "user" then $user else null end),upstream:$upstream,outbound_tag:$out_tag,rule_set_tag:$rule_tag,
      runtime_rule_tag:$runtime_rule_tag,runtime_outbound_tag:$runtime_outbound_tag,runtime_transport_tag:$runtime_transport_tag,
      rule_preset:$rule_preset,outbound_preset:$outbound_preset,status:"active",created_at:$created_at}]
  ' --arg name "$1" --arg url "$2" --arg scope "$3" --arg user "$4" \
    --arg out_tag "$6" --arg rule_tag "$7" --arg rule_preset "$8" --arg outbound_preset "$9" \
    --arg runtime_rule_tag "${10}" --arg runtime_outbound_tag "${11}" --arg runtime_transport_tag "${12}" \
    --arg created_at "$(date -Iseconds)"
}

state_set_split_status() {
  atomic_state_update '(.splits[] | select(.name == $name) | .status) = $status' \
    --arg name "$1" --arg status "$2"
}

state_replace_split() {
  SB_JQ_UPSTREAM="$5" atomic_state_update '(
    $ENV.SB_JQ_UPSTREAM | fromjson
  ) as $upstream |
    (.splits[] | select(.name == $name)) |=
      (. + {url:$url,scope:$scope,user:(if $scope == "user" then $user else null end),upstream:$upstream,outbound_tag:$out_tag,
        runtime_rule_tag:$runtime_rule_tag,runtime_outbound_tag:$runtime_outbound_tag,runtime_transport_tag:$runtime_transport_tag,
        rule_preset:$rule_preset,outbound_preset:$outbound_preset,updated_at:$updated_at})
  ' --arg name "$1" --arg url "$2" --arg scope "$3" --arg user "$4" \
    --arg out_tag "$6" --arg rule_preset "$7" --arg outbound_preset "$8" \
    --arg runtime_rule_tag "$9" --arg runtime_outbound_tag "${10}" --arg runtime_transport_tag "${11}" \
    --arg updated_at "$(date -Iseconds)"
}

state_move_split() {
  atomic_state_update '
    (.splits[] | select(.name == $name)) as $selected |
    [.splits[] | select(.name != $name)] as $remaining |
    ($position - 1) as $index |
    .splits = ($remaining[0:$index] + [$selected] + $remaining[$index:])
  ' --arg name "$1" --argjson position "$2"
}

state_remove_split() {
  atomic_state_update '.splits = [.splits[] | select(.name != $name)]' --arg name "$1"
}

state_add_outbound_preset() {
  SB_JQ_UPSTREAM="$2" atomic_state_update '(
    $ENV.SB_JQ_UPSTREAM | fromjson
  ) as $upstream |
    .outbound_presets += [{name:$name,upstream:$upstream,created_at:$created_at}]
  ' --arg name "$1" --arg created_at "$(date -Iseconds)"
}

state_replace_outbound_preset() {
  SB_JQ_UPSTREAM="$2" atomic_state_update '(
    $ENV.SB_JQ_UPSTREAM | fromjson
  ) as $upstream |
    (.outbound_presets[] | select(.name == $name)) |=
      (. + {upstream:$upstream,updated_at:$updated_at}) |
    .splits |= map(
      if (.outbound_preset // "") == $name then
        . + {upstream:$upstream,updated_at:$updated_at}
      else . end
    )
  ' --arg name "$1" --arg updated_at "$(date -Iseconds)"
}

state_remove_outbound_preset() {
  atomic_state_update '
    .outbound_presets = [.outbound_presets[] | select(.name != $name)] |
    .splits |= map(
      if (.outbound_preset // "") == $name then
        .runtime_outbound_tag = $runtime_outbound_tag |
        .runtime_transport_tag = $runtime_transport_tag |
        del(.outbound_preset)
      else . end)
  ' --arg name "$1" --arg runtime_outbound_tag "$2" --arg runtime_transport_tag "$3"
}

state_add_rule_preset() {
  atomic_state_update '
    .rule_presets += [{name:$name,url:$url,created_at:$created_at}]
  ' --arg name "$1" --arg url "$2" --arg created_at "$(date -Iseconds)"
}

state_replace_rule_preset() {
  atomic_state_update '
    (.rule_presets[] | select(.name == $name)) |=
      (. + {url:$url,updated_at:$updated_at}) |
    .splits |= map(
      if (.rule_preset // "") == $name then
        . + {url:$url,updated_at:$updated_at}
      else . end
    )
  ' --arg name "$1" --arg url "$2" --arg updated_at "$(date -Iseconds)"
}

state_remove_rule_preset() {
  atomic_state_update '
    .rule_presets = [.rule_presets[] | select(.name != $name)] |
    .splits |= map(
      if (.rule_preset // "") == $name then
        .runtime_rule_tag = $runtime_rule_tag |
        del(.rule_preset)
      else . end)
  ' --arg name "$1" --arg runtime_rule_tag "$2"
}

state_sync_linked_split_snapshots() {
  atomic_state_update '
    .outbound_presets as $outbounds |
    .rule_presets as $rules |
    .splits |= map(
      . as $split |
      (if (($split.outbound_preset // "") != "") then
         (first($outbounds[] | select(.name == $split.outbound_preset)) // null)
       else null end) as $outbound |
      (if (($split.rule_preset // "") != "") then
         (first($rules[] | select(.name == $split.rule_preset)) // null)
       else null end) as $rule |
      (if (($split.outbound_preset // "") != "") then
         if $outbound == null then del(.outbound_preset) else .upstream = $outbound.upstream end
       else . end) |
      (if (($split.rule_preset // "") != "") then
         if $rule == null then del(.rule_preset) else .url = $rule.url end
       else . end)
    )
  '
}

cmd_outbound_preset_add() {
  local name="$1" upstream="$2"
  validate_preset_name "$name"
  outbound_preset_exists "$name" && die "同名预置出口已经存在"
  validate_upstream_candidate "$upstream"
  state_add_outbound_preset "$name" "$upstream" || return 1
  log "预置出口已保存：${name}；它不会改变当前分流"
}

cmd_outbound_preset_edit() {
  local name="$1" upstream="$2" active
  outbound_preset_exists "$name" || die "预置出口不存在：$name"
  validate_upstream_candidate "$upstream"
  active="$(jq --arg name "$name" '[.splits[] | select((.outbound_preset // "") == $name and .status == "active")] | length' "$STATE_FILE")" || return 1
  if ((active == 0)); then
    state_replace_outbound_preset "$name" "$upstream" || return 1
  else
    ensure_safe_ssh_for_singbox_restart || return 0
    start_managed_operation "edit-outbound-preset:$name" || return 1
    run_managed_step state_replace_outbound_preset "$name" "$upstream" || return 1
    rebuild_and_finish_split_operation || return 1
  fi
  log "预置出口已更新：${name}；关联分流已经同步"
}

cmd_outbound_preset_remove() {
  local name="$1" runtime_outbound_tag runtime_transport_tag
  outbound_preset_exists "$name" || die "预置出口不存在：$name"
  runtime_outbound_tag="$(stable_managed_tag outbound "$name")" || return 1
  runtime_transport_tag="$(stable_managed_tag transport "$name")" || return 1
  state_remove_outbound_preset "$name" "$runtime_outbound_tag" "$runtime_transport_tag" || return 1
  log "预置出口已删除：${name}；关联分流已转为独立配置，现有连接参数没有变化"
}

cmd_rule_preset_add() {
  local name="$1" url="$2"
  validate_preset_name "$name"
  rule_preset_exists "$name" && die "同名预置规则已经存在"
  [[ "$url" == https://* ]] || die "规则集地址必须使用 HTTPS"
  split_rule_format "$url" >/dev/null || die "规则集地址必须指向 .srs 或 .json 文件"
  validate_remote_rule_set "$url"
  state_add_rule_preset "$name" "$url" || return 1
  log "预置规则已保存：${name}；它不会改变当前分流"
}

cmd_rule_preset_edit() {
  local name="$1" url="$2" active
  rule_preset_exists "$name" || die "预置规则不存在：$name"
  [[ "$url" == https://* ]] || die "规则集地址必须使用 HTTPS"
  split_rule_format "$url" >/dev/null || die "规则集地址必须指向 .srs 或 .json 文件"
  validate_remote_rule_set "$url"
  active="$(jq --arg name "$name" '[.splits[] | select((.rule_preset // "") == $name and .status == "active")] | length' "$STATE_FILE")" || return 1
  if ((active == 0)); then
    state_replace_rule_preset "$name" "$url" || return 1
  else
    ensure_safe_ssh_for_singbox_restart || return 0
    start_managed_operation "edit-rule-preset:$name" || return 1
    run_managed_step state_replace_rule_preset "$name" "$url" || return 1
    rebuild_and_finish_split_operation || return 1
  fi
  log "预置规则已更新：${name}；关联分流已经同步"
}

cmd_rule_preset_remove() {
  local name="$1" runtime_rule_tag
  rule_preset_exists "$name" || die "预置规则不存在：$name"
  runtime_rule_tag="$(stable_managed_tag rule "$name")" || return 1
  state_remove_rule_preset "$name" "$runtime_rule_tag" || return 1
  log "预置规则已删除：${name}；关联分流已转为独立配置，现有规则地址没有变化"
}

validate_split_relationships() {
  local exclude_name="$1" candidate_rule="$2" candidate_out="$3" candidate_scope="$4" candidate_user="$5" active_only="${6:-false}"
  local rows split other_rule other_out other_scope other_user overlap=false
  rows="$(jq -c --arg exclude "$exclude_name" --argjson active_only "$active_only" '
    .splits[]? | select(.name != $exclude and (($active_only | not) or .status == "active"))
  ' "$STATE_FILE")" || return 1
  while IFS= read -r split; do
    [[ -n "$split" ]] || continue
    other_rule="$(split_runtime_rule_tag_from_json "$split")" || return 1
    [[ "$other_rule" == "$candidate_rule" ]] || continue
    other_scope="$(jq -r '.scope' <<<"$split")" || return 1
    other_user="$(jq -r '.user // ""' <<<"$split")" || return 1
    overlap=false
    if [[ "$candidate_scope" == all || "$other_scope" == all || "$candidate_user" == "$other_user" ]]; then overlap=true; fi
    [[ "$overlap" == true ]] || continue
    other_out="$(split_runtime_out_tag_from_json "$split")" || return 1
    if [[ "$other_out" == "$candidate_out" ]]; then
      echo "错误：这条预置规则已经通过同一个出口覆盖该用户，无需重复添加。" >&2
    else
      echo "错误：同一用户不能让同一条预置规则同时使用两个不同出口。" >&2
    fi
    return 1
  done <<<"$rows"
}

runtime_rule_tag_owned_by_state() {
  local wanted="$1" split rows tag
  rows="$(jq -c '.splits[]?' "$STATE_FILE")" || return 1
  while IFS= read -r split; do
    [[ -n "$split" ]] || continue
    tag="$(split_runtime_rule_tag_from_json "$split")" || return 1
    [[ "$tag" != "$wanted" ]] || return 0
  done <<<"$rows"
  return 1
}

runtime_outbound_tag_owned_by_state() {
  local wanted="$1" split rows tag
  rows="$(jq -c '.splits[]?' "$STATE_FILE")" || return 1
  while IFS= read -r split; do
    [[ -n "$split" ]] || continue
    tag="$(split_runtime_out_tag_from_json "$split")" || return 1
    [[ "$tag" != "$wanted" ]] || return 0
  done <<<"$rows"
  return 1
}

cmd_split_add() {
  local name="$1" url="$2" scope="$3" user="$4" upstream="$5" out_tag="$6" rule_preset="${7:-}" outbound_preset="${8:-}" rule_tag="$1"
  local runtime_rule_tag runtime_outbound_tag runtime_transport_tag
  validate_split_name "$name"; split_exists "$name" && die "分流规则已存在：$name"
  rule_preset_exists "$rule_preset" || die "预置规则不存在：$rule_preset"
  outbound_preset_exists "$outbound_preset" || die "预置出口不存在：$outbound_preset"
  validate_outbound_tag "$out_tag"
  runtime_rule_tag="$(stable_managed_tag rule "$rule_preset")" || return 1
  runtime_outbound_tag="$(stable_managed_tag outbound "$outbound_preset")" || return 1
  runtime_transport_tag="$(stable_managed_tag transport "$outbound_preset")" || return 1
  [[ "$url" == https://* ]] || die "远程规则集地址必须使用 HTTPS"
  if [[ "$scope" == user ]]; then validate_name "$user"; user_exists "$user" || die "用户不存在：$user"; fi
  jq -e --arg tag "$rule_tag" '.route.rule_set[]? | select(.tag == $tag)' "$SINGBOX_CONFIG" >/dev/null && die "sing-box 已存在同名规则集标签"
  jq -e --arg out "$out_tag" '.splits[]? | select((.outbound_tag // ("managed-out-" + .name)) == $out)' "$STATE_FILE" >/dev/null && die "出口名称已被其他分流使用，请换一个名称"
  [[ "$out_tag" != "$(split_transport_tag "$name")" ]] || die "出口名称与系统内部名称冲突，请换一个名称"
  jq -e --arg out "$out_tag" '.splits[]? | select(("managed-transport-" + .name) == $out)' "$STATE_FILE" >/dev/null && die "出口名称与其他分流的内部名称冲突，请换一个名称"
  jq -e --arg out "$out_tag" --arg transport "$(split_transport_tag "$name")" '.outbounds[]? | select(.tag == $out or .tag == $transport)' "$SINGBOX_CONFIG" >/dev/null && die "sing-box 已存在同名分流出站标签"
  if jq -e --arg tag "$runtime_rule_tag" '.route.rule_set[]? | select(.tag == $tag)' "$SINGBOX_CONFIG" >/dev/null &&
     ! runtime_rule_tag_owned_by_state "$runtime_rule_tag"; then
    die "这个预置规则与现有 sing-box 配置重名，请更换预置名称"
  fi
  if jq -e --arg tag "$runtime_outbound_tag" '.outbounds[]? | select(.tag == $tag)' "$SINGBOX_CONFIG" >/dev/null &&
     ! runtime_outbound_tag_owned_by_state "$runtime_outbound_tag"; then
    die "这个预置出口与现有 sing-box 配置重名，请更换预置名称"
  fi
  validate_split_relationships "$name" "$runtime_rule_tag" "$runtime_outbound_tag" "$scope" "$user" false || return 1
  validate_remote_rule_set "$url"
  ensure_safe_ssh_for_singbox_restart || return 0
  start_managed_operation "add-split:$name" || return 1
  run_managed_step state_add_split "$name" "$url" "$scope" "$user" "$upstream" "$out_tag" "$rule_tag" "$rule_preset" "$outbound_preset" \
    "$runtime_rule_tag" "$runtime_outbound_tag" "$runtime_transport_tag" || return 1
  rebuild_and_finish_split_operation || return 1
  log "分流增加成功：$name"
}

cmd_split_disable() {
  local name="$1" split
  split_exists "$name" || die "分流不存在：$name"; split="$(jq -c --arg name "$name" '.splits[] | select(.name == $name)' "$STATE_FILE")"
  [[ "$(jq -r '.status' <<<"$split")" == active ]] || die "分流已经停用"
  ensure_safe_ssh_for_singbox_restart || return 0
  start_managed_operation "disable-split:$name" || return 1
  run_managed_step state_set_split_status "$name" disabled || return 1
  rebuild_and_finish_split_operation || return 1
  log "分流已停用：$name"
}

cmd_split_enable() {
  local name="$1" split runtime_rule_tag runtime_outbound_tag
  split_exists "$name" || die "分流不存在：$name"; split="$(jq -c --arg name "$name" '.splits[] | select(.name == $name)' "$STATE_FILE")"
  [[ "$(jq -r '.status' <<<"$split")" == disabled ]] || die "分流已经启用"
  if [[ "$(jq -r '.scope' <<<"$split")" == user ]]; then user_exists "$(jq -r '.user' <<<"$split")" || die "关联用户已不存在"; fi
  jq -e '.upstream.protocol' <<<"$split" >/dev/null || die "这条旧版分流缺少出口服务器信息，请删除后重新添加"
  local out_tag rule_tag
  out_tag="$(jq -r '.outbound_tag // ("managed-out-" + .name)' <<<"$split")"
  rule_tag="$(jq -r '.rule_set_tag // ("managed-split-" + .name)' <<<"$split")"
  runtime_rule_tag="$(split_runtime_rule_tag_from_json "$split")" || return 1
  runtime_outbound_tag="$(split_runtime_out_tag_from_json "$split")" || return 1
  validate_split_relationships "$name" "$runtime_rule_tag" "$runtime_outbound_tag" "$(jq -r '.scope' <<<"$split")" "$(jq -r '.user // ""' <<<"$split")" true || return 1
  validate_outbound_tag "$out_tag"
  jq -e --arg out "$out_tag" --arg transport "$(split_transport_tag "$name")" '.outbounds[]? | select(.tag == $out or .tag == $transport)' "$SINGBOX_CONFIG" >/dev/null && die "sing-box 已存在同名分流出站标签"
  jq -e --arg tag "$rule_tag" '.route.rule_set[]? | select(.tag == $tag)' "$SINGBOX_CONFIG" >/dev/null && die "sing-box 已存在同名规则集标签"
  ensure_safe_ssh_for_singbox_restart || return 0
  start_managed_operation "enable-split:$name" || return 1
  run_managed_step state_set_split_status "$name" active || return 1
  rebuild_and_finish_split_operation || return 1
  log "分流已启用：$name"
}

cmd_split_remove() {
  local name="$1"
  split_exists "$name" || die "分流不存在：$name"
  ensure_safe_ssh_for_singbox_restart || return 0
  start_managed_operation "remove-split:$name" || return 1
  run_managed_step remove_split_config "$name" || return 1
  run_managed_step state_remove_split "$name" || return 1
  rebuild_and_finish_split_operation || return 1
  log "分流已删除：$name"
}

cmd_split_edit() {
  local name="$1" url="$2" scope="$3" user="$4" upstream="$5" out_tag="$6" rule_preset="${7:-}" outbound_preset="${8:-}" split old_out
  local runtime_rule_tag runtime_outbound_tag runtime_transport_tag
  split_exists "$name" || die "分流不存在：$name"
  [[ -z "$rule_preset" ]] || rule_preset_exists "$rule_preset" || die "预置规则不存在：$rule_preset"
  [[ -z "$outbound_preset" ]] || outbound_preset_exists "$outbound_preset" || die "预置出口不存在：$outbound_preset"
  split="$(jq -c --arg name "$name" '.splits[] | select(.name == $name)' "$STATE_FILE")"
  old_out="$(jq -r '.outbound_tag // ("managed-out-" + .name)' <<<"$split")"
  if [[ -n "$rule_preset" ]]; then runtime_rule_tag="$(stable_managed_tag rule "$rule_preset")" || return 1
  else runtime_rule_tag="$(split_runtime_rule_tag_from_json "$split")" || return 1
  fi
  if [[ -n "$outbound_preset" ]]; then
    runtime_outbound_tag="$(stable_managed_tag outbound "$outbound_preset")" || return 1
    runtime_transport_tag="$(stable_managed_tag transport "$outbound_preset")" || return 1
  else
    runtime_outbound_tag="$(split_runtime_out_tag_from_json "$split")" || return 1
    runtime_transport_tag="$(split_runtime_transport_tag_from_json "$split")" || return 1
  fi
  validate_outbound_tag "$out_tag"
  [[ "$url" == https://* ]] || die "远程规则集地址必须使用 HTTPS"
  split_rule_format "$url" >/dev/null || die "远程规则集地址必须指向 .srs 或 .json 文件"
  if [[ "$scope" == user ]]; then validate_name "$user"; user_exists "$user" || die "用户不存在：$user"; fi
  jq -e --arg name "$name" --arg out "$out_tag" '.splits[]? | select(.name != $name and (.outbound_tag // ("managed-out-" + .name)) == $out)' "$STATE_FILE" >/dev/null && die "出口名称已被其他分流使用，请换一个名称"
  [[ "$out_tag" != "$(split_transport_tag "$name")" ]] || die "出口名称与系统内部名称冲突，请换一个名称"
  jq -e --arg name "$name" --arg out "$out_tag" '.splits[]? | select(.name != $name and ("managed-transport-" + .name) == $out)' "$STATE_FILE" >/dev/null && die "出口名称与其他分流的内部名称冲突，请换一个名称"
  if [[ "$out_tag" != "$old_out" ]]; then
    jq -e --arg out "$out_tag" '.outbounds[]? | select(.tag == $out)' "$SINGBOX_CONFIG" >/dev/null && die "sing-box 已存在同名出站"
  fi
  validate_split_relationships "$name" "$runtime_rule_tag" "$runtime_outbound_tag" "$scope" "$user" false || return 1
  validate_remote_rule_set "$url"
  ensure_safe_ssh_for_singbox_restart || return 0
  start_managed_operation "edit-split:$name" || return 1
  run_managed_step remove_split_config "$name" || return 1
  run_managed_step state_replace_split "$name" "$url" "$scope" "$user" "$upstream" "$out_tag" "$rule_preset" "$outbound_preset" \
    "$runtime_rule_tag" "$runtime_outbound_tag" "$runtime_transport_tag" || return 1
  rebuild_and_finish_split_operation || return 1
  log "分流修改成功：$name"
}

cmd_split_move() {
  local name="$1" position="$2" count current
  split_exists "$name" || die "分流不存在：$name"
  count="$(jq '.splits | length' "$STATE_FILE")"
  if [[ ! "$position" =~ ^[0-9]+$ ]] || ((position < 1 || position > count)); then
    die "目标优先级超出范围"
  fi
  current="$(jq -r --arg name "$name" '.splits | to_entries[] | select(.value.name == $name) | (.key + 1)' "$STATE_FILE")"
  if [[ "$current" == "$position" ]]; then echo "优先级未变化。"; return 0; fi
  ensure_safe_ssh_for_singbox_restart || return 0
  start_managed_operation "move-split:$name" || return 1
  run_managed_step state_move_split "$name" "$position" || return 1
  rebuild_and_finish_split_operation || return 1
  log "分流优先级已调整：$name → $position"
}

cmd_split_list() {
  jq -r 'if (.splits|length)==0 then "暂无分流" else (["顺序","名称","状态","范围","预置规则","预置出口"]|@tsv),(.splits|to_entries[]|[((.key+1)|tostring),.value.name,(if .value.status=="active" then "启用" else "停用" end),(if .value.scope=="all" then "全部用户" else ("用户:"+.value.user) end),(.value.rule_preset // "独立配置"),(.value.outbound_preset // "独立配置")]|@tsv) end' "$STATE_FILE" | column -t -s $'\t'
}

cmd_split_show() {
  local name="$1"
  split_exists "$name" || die "分流不存在：$name"
  jq -r --arg name "$name" '
    .splits | to_entries[] | select(.value.name == $name) |
    .key as $index | .value as $s |
    "分流名称：\($s.name)",
    "匹配顺序：第 \($index + 1) 条",
    "状态：\(if $s.status == "active" then "启用" else "停用" end)",
    "作用范围：\(if $s.scope == "all" then "全部用户" else "用户:" + $s.user end)",
    "规则来源：\($s.rule_preset // "独立配置")",
    "规则集地址：\($s.url)",
    "出口来源：\($s.outbound_preset // "独立配置")",
    "出口协议：\(if $s.upstream.protocol == "anytls" then "AnyTLS" elif $s.upstream.protocol == "shadowsocks" then "Shadowsocks" elif $s.upstream.protocol == "ss_shadowtls" then "SS2022 + ShadowTLS" else "旧版未配置" end)",
    "出口服务器：\($s.upstream.server // "-"):\($s.upstream.server_port // "-")",
    (if ($s.upstream.method // "") != "" then "加密方式：\($s.upstream.method)" else empty end),
    (if ($s.upstream.sni // "") != "" then "TLS SNI：\($s.upstream.sni)" else empty end),
    (if ($s.upstream | has("insecure")) then "证书验证：\(if $s.upstream.insecure then "跳过" else "验证" end)" else empty end),
    "创建时间：\($s.created_at // "-")",
    (if ($s.updated_at // "") != "" then "修改时间：\($s.updated_at)" else empty end)
  ' "$STATE_FILE"
}

write_manager_config() {
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
  chmod 600 "$CONF_FILE" || return 1
  chown root:root "$CONF_FILE" || return 1
}

write_base_config() {
  jq -n '{
    log:{level:"info",timestamp:true},
    dns:{servers:[{type:"local",tag:"local"}],final:"local"},
    inbounds:[],
    outbounds:[{type:"direct",tag:"direct"}],
    route:{rules:[],rule_set:[],final:"direct",default_domain_resolver:"local"},
    experimental:{cache_file:{enabled:true}}
  }' > /etc/sing-box/config.json || return 1
  chmod 600 /etc/sing-box/config.json || return 1
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
  cat > /etc/systemd/system/sing-box.service <<'EOF' || return 1
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

write_nfuse_unit() {
  local iface="$1"
  cat > /etc/systemd/system/nfuse.service <<EOF || return 1
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
  cat > /etc/systemd/system/sb-user-expiry.service <<'EOF' || return 1
[Unit]
Description=Expire sing-box managed users
After=sing-box.service nfuse.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sb-user-manager --internal-expire
EOF
  cat > /etc/systemd/system/sb-user-expiry.timer <<'EOF' || return 1
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
  write_singbox_unit || return 1
  write_nfuse_unit "$1" || return 1
  write_expiry_units || return 1
}

install_prerequisites() {
  log "检查并安装系统依赖"
  apt-get update || return 1
  DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl jq nftables iproute2 util-linux bsdextrautils tar openssl python3 qrencode || return 1
}

environment_is_deployed() {
  [[ -f /etc/sing-box/config.json && -f "$CONF_FILE" && -x /usr/local/bin/sing-box && -x /usr/local/bin/nfuse ]]
}

system_path() {
  printf '%s%s' "${SB_SYSTEM_ROOT:-}" "$1"
}

classify_environment() {
  local managed=0 core=0 complete=true runtime_ok=true path
  for path in /etc/sb-user-manager.conf /etc/sing-box/managed-users.json /usr/local/sbin/sb-user-manager /etc/systemd/system/sb-user-expiry.timer; do
    [[ -e "$(system_path "$path")" ]] && ((managed+=1))
  done
  for path in /etc/sing-box/config.json /usr/local/bin/sing-box /etc/systemd/system/sing-box.service /usr/local/bin/nfuse /etc/systemd/system/nfuse.service /var/lib/nfuse/nfuse.db; do
    [[ -e "$(system_path "$path")" ]] && ((core+=1))
  done
  for path in /etc/sb-user-manager.conf /etc/sing-box/config.json /etc/sing-box/managed-users.json /usr/local/sbin/sb-user-manager /usr/local/bin/sing-box /usr/local/bin/nfuse /etc/systemd/system/sing-box.service /etc/systemd/system/nfuse.service /etc/systemd/system/sb-user-expiry.service /etc/systemd/system/sb-user-expiry.timer; do
    [[ -e "$(system_path "$path")" ]] || complete=false
  done

  if ((managed==0 && core==0)); then ENVIRONMENT_CLASS=fresh
  elif [[ "$complete" == true ]]; then
    if [[ -z "${SB_SYSTEM_ROOT:-}" ]]; then
      /usr/local/bin/sing-box check -c /etc/sing-box/config.json >/dev/null 2>&1 || runtime_ok=false
      systemctl is-active --quiet sing-box || runtime_ok=false
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
  done <<'EOF'
/etc/sing-box/config.json
/etc/sing-box/managed-users.json
/etc/sb-user-manager.conf
/usr/local/bin/sing-box
/usr/local/bin/nfuse
/usr/local/sbin/sb-user-manager
/etc/systemd/system/sing-box.service
/etc/systemd/system/nfuse.service
/etc/systemd/system/sb-user-expiry.timer
EOF
  if [[ -z "${SB_SYSTEM_ROOT:-}" ]]; then
    service_state="$(systemctl is-active sing-box 2>/dev/null || true)"
    printf '\n%-24s %s\n' '节点服务（sing-box）' "${service_state:-未安装}"
    service_state="$(systemctl is-active nfuse 2>/dev/null || true)"
    printf '%-24s %s\n' '流量统计（Nfuse）' "${service_state:-未安装}"
    printf '%-24s %s\n' '流量统计通信' "$([[ -S /run/nfuse.sock ]] && echo 正常 || echo 未就绪)"
  fi
}

github_api_get() {
  local url="$1"
  curl --proto '=https' --proto-redir '=https' --max-redirs 5 \
    --connect-timeout 10 --max-time 30 -fsSL --retry 3 \
    -H 'Accept: application/vnd.github+json' "$url"
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

singbox_binary_version() {
  [[ -x "$1" ]] || return 0
  "$1" version 2>/dev/null | awk 'NR==1 {print $3}' || true
}

write_singbox_channel_state() {
  local channel="$1" version="$2" previous_channel="$3" previous_version="$4"
  local dir tmp stable_version preview_version
  dir="$(dirname "$SINGBOX_CHANNEL_STATE")"
  install -d -m 700 "$dir" || return 1
  tmp="$(mktemp "$dir/.singbox-channel.XXXXXX")" || return 1
  register_temp_path "$tmp" || return 1
  stable_version="$(singbox_binary_version "$SINGBOX_VERSION_STORE/stable/sing-box")"
  preview_version="$(singbox_binary_version "$SINGBOX_VERSION_STORE/preview/sing-box")"
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
  cached_stable="$(singbox_binary_version "$SINGBOX_VERSION_STORE/stable/sing-box")"; cached_stable="${cached_stable:-未保存}"
  cached_preview="$(singbox_binary_version "$SINGBOX_VERSION_STORE/preview/sing-box")"; cached_preview="${cached_preview:-未保存}"
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
      "$binary" rule-set compile --output "$decoded" "$downloaded" >/dev/null
  else
    "$binary" rule-set decompile --output "$decoded" "$downloaded" >/dev/null &&
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
  if ! curl --proto '=https' --proto-redir '=https' --max-redirs 5 \
     --connect-timeout 10 --max-time 300 -fL --retry 3 -o "$archive" "$url" ||
     ! printf '%s  %s\n' "$sha256" "$archive" | sha256sum -c - >/dev/null; then
    return 1
  fi
  if ! tar -xzf "$archive" -C "$target_dir" --no-same-owner --strip-components=1 "sing-box-${version}-${SINGBOX_ARCH}/sing-box" ||
     [[ ! -f "$binary" || -L "$binary" || ! -x "$binary" ]]; then
    return 1
  fi
  detected="$($binary version 2>/dev/null | awk 'NR==1 {print $3}')"
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
  if ! output="$($binary check -c "$SINGBOX_CONFIG" 2>&1)"; then
    echo "检查结果：暂时不能切换到 sing-box ${version}。"
    echo "原因：现有连接配置不被该版本接受。"
    [[ -n "$output" ]] && printf '详细信息：%s\n' "$(tail -n 1 <<<"$output")"
    echo "当前版本和全部配置均未改变。"
    rm -rf -- "$work"
    return 0
  fi
  normalized="$work/target-formatted-config.json"
  if ! output="$($binary format -c "$SINGBOX_CONFIG" 2>&1 >"$normalized")" ||
     ! output="$($binary check -c "$normalized" 2>&1)"; then
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
    if ! output="$($stable_binary check -c "$normalized" 2>&1)"; then
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
  ensure_safe_ssh_for_singbox_restart || return 0
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
  if ! "$binary" check -c "$SINGBOX_CONFIG" >/dev/null 2>&1; then
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
  run_step_or_rollback rollback_channel_switch "$SINGBOX_BIN" check -c "$SINGBOX_CONFIG" || return 1
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
  manager_json="$(curl --proto '=https' --proto-redir '=https' --max-redirs 5 \
    --connect-timeout 10 --max-time 30 -fsSL --retry 3 \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/repos/${MANAGER_REPOSITORY}/releases/latest")" ||
    die "无法查询管理脚本最新版本"
  LATEST_MANAGER_VERSION="$(jq -r '.tag_name // empty | sub("^v"; "")' <<<"$manager_json")"
  [[ -n "$LATEST_MANAGER_VERSION" ]] || die "管理脚本 Release 版本信息无效"
  LATEST_MANAGER_URL="$(jq -r --arg name "$MANAGER_ASSET" '.assets[] | select(.name == $name) | .browser_download_url' <<<"$manager_json")"
  LATEST_MANAGER_SHA256="$(jq -r --arg name "$MANAGER_ASSET" '.assets[] | select(.name == $name) | (.digest // "") | sub("^sha256:"; "")' <<<"$manager_json")"
}

fetch_latest_releases() {
  local include_manager="${1:-true}" sing_json nfuse_json sing_asset nfuse_asset
  sing_json="$(curl --proto '=https' --proto-redir '=https' --max-redirs 5 \
    --connect-timeout 10 --max-time 30 -fsSL --retry 3 \
    -H 'Accept: application/vnd.github+json' https://api.github.com/repos/SagerNet/sing-box/releases/latest)" || die "无法查询 sing-box 最新版本"
  nfuse_json="$(curl --proto '=https' --proto-redir '=https' --max-redirs 5 \
    --connect-timeout 10 --max-time 30 -fsSL --retry 3 \
    -H 'Accept: application/vnd.github+json' https://api.github.com/repos/sketchain/Nfuse/releases/latest)" || die "无法查询 Nfuse 最新版本"
  LATEST_SINGBOX_VERSION="$(jq -r '.tag_name // empty | sub("^v"; "")' <<<"$sing_json")"
  LATEST_NFUSE_VERSION="$(jq -r '.tag_name // empty | sub("^v"; "")' <<<"$nfuse_json")"
  [[ -n "$LATEST_SINGBOX_VERSION" && -n "$LATEST_NFUSE_VERSION" ]] || die "GitHub Release 返回的版本信息无效"
  if [[ "$include_manager" == true ]]; then
    fetch_latest_manager_release
  else
    LATEST_MANAGER_VERSION="$SCRIPT_VERSION"
  fi
  sing_asset="sing-box-${LATEST_SINGBOX_VERSION}-linux-amd64.tar.gz"
  nfuse_asset="nfuse-amd64.tar.gz"
  LATEST_SINGBOX_URL="$(jq -r --arg name "$sing_asset" '.assets[] | select(.name == $name) | .browser_download_url' <<<"$sing_json")"
  LATEST_NFUSE_URL="$(jq -r --arg name "$nfuse_asset" '.assets[] | select(.name == $name) | .browser_download_url' <<<"$nfuse_json")"
  LATEST_SINGBOX_SHA256="$(jq -r --arg name "$sing_asset" '.assets[] | select(.name == $name) | (.digest // "") | sub("^sha256:"; "")' <<<"$sing_json")"
  LATEST_NFUSE_SHA256="$(jq -r --arg name "$nfuse_asset" '.assets[] | select(.name == $name) | (.digest // "") | sub("^sha256:"; "")' <<<"$nfuse_json")"
  if [[ "$include_manager" != true ]]; then
    LATEST_MANAGER_URL=""; LATEST_MANAGER_SHA256=""
  fi
  [[ "$LATEST_SINGBOX_URL" == https://* && "$LATEST_NFUSE_URL" == https://* ]] || die "未找到适用于 linux-amd64 的发行资产"
  [[ "$LATEST_SINGBOX_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || die "sing-box 发行资产缺少可信 SHA-256 digest，停止更新"
  [[ "$LATEST_NFUSE_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || die "Nfuse 发行资产缺少可信 SHA-256 digest，停止更新"
  if [[ -n "$LATEST_MANAGER_URL" ]]; then
    [[ "$LATEST_MANAGER_URL" == https://* ]] || die "管理脚本发行资产地址无效"
    [[ "$LATEST_MANAGER_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || die "管理脚本发行资产缺少可信 SHA-256 digest，停止更新"
  fi
}

version_gt() {
  [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ]]
}

installed_singbox_version() { "${SINGBOX_BIN:-/usr/local/bin/sing-box}" version 2>/dev/null | awk 'NR==1 {print $3}' || true; }
installed_nfuse_version() {
  if [[ -r "$DEPLOYED_VERSIONS_FILE" ]]; then sed -n 's/^NFUSE_VERSION=//p' "$DEPLOYED_VERSIONS_FILE"
  else "${NFUSE_BIN:-/usr/local/bin/nfuse}" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true
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
    ! mv -- "$tmp" "$target" ||
    ! sync_transaction_path "$parent"; then
    rm -f -- "$tmp" || true
    return 1
  fi
}

download_binaries() {
  local work="$1" sing_current nfuse_current archive
  sing_current="$(installed_singbox_version)"; nfuse_current="$(installed_nfuse_version)"
  if [[ "$sing_current" != "$LATEST_SINGBOX_VERSION" ]]; then
    [[ "$LATEST_SINGBOX_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z][0-9A-Za-z.-]*)?$ ]] || return 1
    archive="sing-box-${LATEST_SINGBOX_VERSION}-linux-amd64.tar.gz"
    curl --proto '=https' --proto-redir '=https' --max-redirs 5 \
      --connect-timeout 10 --max-time 300 -fL --retry 3 -o "$work/$archive" "$LATEST_SINGBOX_URL" || return 1
    printf '%s  %s\n' "$LATEST_SINGBOX_SHA256" "$work/$archive" | sha256sum -c - >/dev/null || return 1
    tar -xzf "$work/$archive" -C "$work" --no-same-owner \
      "sing-box-${LATEST_SINGBOX_VERSION}-linux-amd64/sing-box" || return 1
    [[ -f "$work/sing-box-${LATEST_SINGBOX_VERSION}-linux-amd64/sing-box" &&
      ! -L "$work/sing-box-${LATEST_SINGBOX_VERSION}-linux-amd64/sing-box" ]] || return 1
    atomic_install_file "$work/sing-box-${LATEST_SINGBOX_VERSION}-linux-amd64/sing-box" /usr/local/bin/sing-box 755 || return 1
  fi
  if [[ "$nfuse_current" != "$LATEST_NFUSE_VERSION" ]]; then
    [[ "$LATEST_NFUSE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z][0-9A-Za-z.-]*)?$ ]] || return 1
    curl --proto '=https' --proto-redir '=https' --max-redirs 5 \
      --connect-timeout 10 --max-time 300 -fL --retry 3 -o "$work/nfuse.tar.gz" "$LATEST_NFUSE_URL" || return 1
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
  curl --proto '=https' --proto-redir '=https' --max-redirs 5 \
    --connect-timeout 10 --max-time 300 -fL --retry 3 \
    -o "$work/$MANAGER_ASSET" "$LATEST_MANAGER_URL" || return 1
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
    pause
    return 0
  fi
  [[ -e "$shortcut" || -L "$shortcut" ]] && return 0
  if ! install_manager_shortcut; then
    log "警告：未能自动创建 sbm 快捷入口；完整命令 sb-user-manager 仍可正常使用"
    pause
  fi
}

write_deployed_versions() {
  local manager_version="$1" state_dir
  state_dir="$(system_path /var/lib/sb-user-manager)" || return 1
  install -d -m 700 "$state_dir" || return 1
  printf 'SCRIPT_VERSION=%s\nSINGBOX_VERSION=%s\nNFUSE_VERSION=%s\n' \
    "$manager_version" "$LATEST_SINGBOX_VERSION" "$LATEST_NFUSE_VERSION" > "$state_dir/versions" || return 1
  chmod 600 "$state_dir/versions" || return 1
}

activate_managed_services() {
  systemctl daemon-reload || return 1
  systemctl enable nfuse sing-box sb-user-expiry.timer >/dev/null || return 1
  systemctl restart nfuse sing-box || return 1
  wait_for_nfuse_ready || return 1
  systemctl start sb-user-expiry.timer || return 1
  systemctl is-active --quiet nfuse || return 1
  systemctl is-active --quiet sing-box || return 1
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
  local nfuse_target_dir nfuse_target_wal nfuse_target_shm path source target_parent copy_ok=true
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
    systemctl stop sing-box 2>/dev/null || true
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
    if [[ -f /etc/systemd/system/sing-box.service ]] && ! systemctl restart sing-box; then log "警告：快照恢复后 sing-box 启动失败"; copy_ok=false; fi
    if [[ -f /etc/systemd/system/sb-user-expiry.timer ]] && ! systemctl start sb-user-expiry.timer; then log "警告：快照恢复后到期检测定时器启动失败"; copy_ok=false; fi
  fi
  [[ "$copy_ok" == true ]] || { log "环境快照文件恢复失败"; return 1; }
}

deploy_environment() {
  local fresh="$1" update_manager="${2:-false}" iface work backup path deployed_state_file
  local -a deploy_created=()
  local deploy_created_count=0
  ensure_safe_ssh_for_singbox_restart || return 0
  validate_manager_shortcut_path ||
    die "检测到 /usr/local/bin/sbm 已被其他文件或链接占用；为避免覆盖现有程序，本次操作已停止"
  [[ "$(uname -m)" == x86_64 ]] || die "仅支持 x86_64 Linux"
  iface="$(default_network_interface)"
  [[ -n "$iface" ]] || die "无法识别默认网络接口"
  work="$(mktemp -d /tmp/sb-user-manager.XXXXXX)"
  register_temp_path "$work"
  create_environment_backup
  backup="$ENV_BACKUP"
  rollback_deploy() {
    local rc="${1:-$?}"
    trap - ERR
    clear_signal_rollback
    systemctl stop sb-user-expiry.timer sing-box nfuse 2>/dev/null || true
    if ((deploy_created_count > 0)); then
      cleanup_deploy_created_paths "${deploy_created[@]}"
    fi
    if [[ "$fresh" == true ]]; then
      rm -rf /etc/sing-box
      rm -f /etc/sb-user-manager.conf /etc/systemd/system/sing-box.service /etc/systemd/system/nfuse.service /etc/systemd/system/sb-user-expiry.service /etc/systemd/system/sb-user-expiry.timer /usr/local/sbin/sb-user-manager /usr/local/bin/sbm
      rm -f /usr/local/bin/sing-box /usr/local/bin/nfuse
      rm -rf /var/lib/sb-user-manager
    fi
    restore_failed_environment_change 部署 "$backup" "$work"
    return "$rc"
  }
  trap rollback_deploy ERR
  set_signal_rollback rollback_deploy
  for path in \
    "$CONF_FILE" \
    /etc/sing-box \
    /etc/sing-box/backups \
    /etc/sing-box/cert \
    /etc/sing-box/cert/anytls.crt \
    /etc/sing-box/cert/anytls.key \
    /etc/systemd/system/sing-box.service \
    /etc/systemd/system/nfuse.service \
    /etc/systemd/system/sb-user-expiry.service \
    /etc/systemd/system/sb-user-expiry.timer \
    /etc/systemd/system/multi-user.target.wants/sing-box.service \
    /etc/systemd/system/multi-user.target.wants/nfuse.service \
    /etc/systemd/system/timers.target.wants/sb-user-expiry.timer \
    /var/lib/nfuse \
    /var/lib/nfuse/nfuse.db \
    /var/lib/sing-box \
    /var/lib/sb-user-manager \
    /var/lib/sb-user-manager/versions \
    /usr/local/sbin/sb-user-manager \
    /usr/local/bin/sbm \
    /usr/local/bin/sing-box \
    /usr/local/bin/nfuse \
    /run/nfuse.sock; do
    if [[ ! -e "$path" && ! -L "$path" ]]; then
      deploy_created[deploy_created_count]="$path"
      ((deploy_created_count+=1))
    fi
  done
  run_step_or_rollback rollback_deploy begin_environment_transaction \
    "deploy-environment" "$backup" "${deploy_created[@]}" || return 1
  run_step_or_rollback rollback_deploy download_binaries "$work" || return 1
  run_step_or_rollback rollback_deploy install -d -m 700 \
    /etc/sing-box /etc/sing-box/backups /etc/sing-box/cert /var/lib/nfuse /usr/local/sbin || return 1
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
  run_step_or_rollback rollback_deploy /usr/local/bin/sing-box check -c /etc/sing-box/config.json || return 1
  run_step_or_rollback rollback_deploy activate_managed_services || return 1
  run_step_or_rollback rollback_deploy complete_environment_change "$work" || return 1
  if [[ "$update_manager" == true ]]; then
    sync_manager_launch_copy /usr/local/sbin/sb-user-manager
  fi
  log "部署完成；备份位于 $backup"
}

takeover_existing_environment() {
  local iface work normalized tmp nfuse_compatible=false path existing_singbox_bin
  local -a takeover_created=()
  ensure_safe_ssh_for_singbox_restart || return 0
  validate_manager_shortcut_path ||
    die "检测到 /usr/local/bin/sbm 已被其他文件或链接占用；为避免覆盖现有程序，本次操作已停止"
  existing_singbox_bin="$(command -v sing-box 2>/dev/null || true)"
  [[ -f /etc/sing-box/config.json && -n "$existing_singbox_bin" && -x "$existing_singbox_bin" ]] ||
    die "保留配置接管要求现有 sing-box 配置和 PATH 中可执行的 sing-box 均存在"
  "$existing_singbox_bin" check -c /etc/sing-box/config.json || die "现有 sing-box 配置校验失败，拒绝接管"
  if [[ -f /etc/systemd/system/nfuse.service ]]; then
    if grep -Fq -- '--db /var/lib/nfuse/nfuse.db' /etc/systemd/system/nfuse.service &&
       grep -Fq -- '--socket /run/nfuse.sock' /etc/systemd/system/nfuse.service; then nfuse_compatible=true
    else die "现有流量统计服务使用了特殊存储或通信位置，脚本无法安全接管；请选择备份后重新安装"
    fi
  fi
  iface="$(default_network_interface)"
  [[ -n "$iface" ]] || die "无法识别默认网络接口"
  create_environment_backup
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
  work="$(mktemp -d /tmp/sb-user-manager.takeover.XXXXXX)"
  register_temp_path "$work"
  rollback_takeover() {
    local rc="${1:-$?}"
    trap - ERR
    clear_signal_rollback
    for path in "${takeover_created[@]}"; do rm -f -- "$path" || true; done
    restore_failed_environment_change 接管 "$ENV_BACKUP" "$work"
    return "$rc"
  }
  trap rollback_takeover ERR
  set_signal_rollback rollback_takeover
  run_step_or_rollback rollback_takeover begin_environment_transaction \
    "takeover-environment" "$ENV_BACKUP" "${takeover_created[@]}" || return 1
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
    /usr/local/bin/sing-box format -c /etc/sing-box/config.json || return 1
  run_step_or_rollback rollback_takeover write_command_output "$tmp" jq '
    .inbounds = (.inbounds // []) |
    .outbounds = (.outbounds // []) |
    if any(.outbounds[]?; .tag == "direct") then . else .outbounds += [{type:"direct",tag:"direct"}] end |
    .dns = (.dns // {}) |
    .dns.servers = (.dns.servers // []) |
    if any(.dns.servers[]?; .tag == "local") then . else .dns.servers += [{type:"local",tag:"local"}] end |
    .route = (.route // {}) |
    .route.rules = (.route.rules // []) |
    .route.rule_set = (.route.rule_set // []) |
    .route.default_domain_resolver = (.route.default_domain_resolver // "local")
  ' "$normalized" || return 1
  run_step_or_rollback rollback_takeover rm -f -- "$normalized" || return 1
  if chmod --reference=/etc/sing-box/config.json "$tmp" 2>/dev/null || chmod 600 "$tmp"; then :; else
    rollback_takeover 1 || true
    return 1
  fi
  chown --reference=/etc/sing-box/config.json "$tmp" 2>/dev/null || true
  run_step_or_rollback rollback_takeover mv "$tmp" /etc/sing-box/config.json || return 1
  run_step_or_rollback rollback_takeover /usr/local/bin/sing-box check -c /etc/sing-box/config.json || return 1

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
  log "现有环境已在保留 sing-box 配置的前提下接管；原环境备份：$ENV_BACKUP"
  log "原有节点和路由会继续保留，但不会自动出现在本脚本的用户或分流列表中"
}

install_environment() {
  local choice answer config_path
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
          [[ -f "$config_path" ]] || die "sing-box 配置缺失，无法安全自动修复；请从备份恢复或选择全新部署"
          if [[ ! -f "$STATE_FILE" ]] && jq -e '
            any(.inbounds[]?; (.tag // "") | test("^(st-|ss-|anytls-)"))
          ' "$config_path" >/dev/null 2>&1; then
            die "检测到已有用户连接配置，但用户资料缺失。为避免用户无法连接，脚本不会自动修改；请先恢复备份或选择重新安装"
          fi
          install_prerequisites || return 1
          fetch_latest_releases false || return 1
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
  cat <<'EOF'
/etc/sing-box
/etc/sb-user-manager.conf
/etc/systemd/system/sing-box.service
/etc/systemd/system/nfuse.service
/etc/systemd/system/sb-user-expiry.service
/etc/systemd/system/sb-user-expiry.timer
/etc/systemd/system/multi-user.target.wants/sing-box.service
/etc/systemd/system/multi-user.target.wants/nfuse.service
/etc/systemd/system/timers.target.wants/sb-user-expiry.timer
/var/lib/nfuse
/var/lib/sing-box
/var/lib/sb-user-manager
/usr/local/sbin/sb-user-manager
/usr/local/bin/sbm
/usr/local/bin/sing-box
/usr/local/bin/nfuse
/run/nfuse.sock
EOF
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
  for unit in sb-user-expiry.timer sing-box.service nfuse.service; do
    systemctl stop "$unit" 2>/dev/null || true
    state="$(systemctl is-active "$unit" 2>/dev/null || true)"
    [[ "$state" != active && "$state" != activating ]] || return 1
    systemctl disable "$unit" >/dev/null 2>&1 || true
  done
}

restore_managed_service_enablement() {
  [[ -z "${SB_SYSTEM_ROOT:-}" ]] || return 0
  systemctl enable nfuse.service sing-box.service sb-user-expiry.timer >/dev/null || return 1
}

ensure_safe_ssh_for_complete_uninstall() {
  ssh_connection_uses_local_singbox || return 0
  cat <<'EOF'
检测到当前 SSH 连接正通过这台服务器自己的 sing-box 节点。
完整卸载需要停止 sing-box，继续会立即中断当前连接。
为避免连接中断，本次卸载已经停止，服务器数据尚未修改。
请在当前 SSH 软件或本地代理中把这台服务器的 SSH 地址设为直连，然后重新运行。
EOF
  return 1
}

cleanup_internal_material_after_uninstall() {
  local base data path name operation_lock failed=false
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
  operation_lock="${LOCK_FILE:-$(system_path /run/lock/sb-user-manager.lock)}"
  rm -f -- "$ENVIRONMENT_LOCK_FILE" "$operation_lock" 2>/dev/null || failed=true
  [[ "$failed" == false ]]
}

uninstall_managed_environment() {
  local work backup candidate="" cleanup_failed=false migration_dir
  local -a uninstall_paths=()
  local uninstall_path_count=0 path installed self
  ensure_safe_ssh_for_complete_uninstall || return 0
  [[ ! -e "$ENVIRONMENT_TRANSACTION_JOURNAL" && ! -L "$ENVIRONMENT_TRANSACTION_JOURNAL" ]] ||
    die "检测到尚未完成的环境操作，请重新运行脚本让它先自动恢复"
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
  work="$(mktemp -d /tmp/sb-user-manager-uninstall.XXXXXX)"
  register_temp_path "$work"
  create_environment_backup
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
    return "$rollback_rc"
  }

  trap rollback_uninstall ERR
  set_signal_rollback rollback_uninstall
  run_step_or_rollback rollback_uninstall begin_environment_transaction \
    "uninstall-environment" "$backup" "${uninstall_paths[@]}" || return 1
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
  local current_singbox current_nfuse current_manager current_channel singbox_latest_label answer needs_update=false update_manager=false manager_latest_label
  environment_is_deployed || { echo "检测结果：尚未安装，请先选择「安装或修复环境」。"; return 0; }
  load_runtime_config
  need_cmd curl; need_cmd jq
  echo "正在查询稳定版更新…"
  fetch_latest_releases true
  current_singbox="$(installed_singbox_version)"; current_nfuse="$(installed_nfuse_version)"
  current_manager="$(installed_manager_version)"
  current_channel="$(current_singbox_channel)"
  singbox_latest_label="$LATEST_SINGBOX_VERSION"
  if [[ "$current_channel" == preview ]]; then
    if fetch_singbox_channel_releases; then
      singbox_latest_label="${LATEST_PREVIEW_SINGBOX_VERSION}（测试通道）"
    else
      singbox_latest_label="未知（请到版本管理检查）"
    fi
    # 通用更新流程不得把测试通道静默替换为正式版；sing-box 由版本管理单独更新。
    LATEST_SINGBOX_VERSION="$current_singbox"
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
    [[ "$current_singbox" == "$LATEST_SINGBOX_VERSION" ]] || needs_update=true
  fi
  [[ "$current_nfuse" == "$LATEST_NFUSE_VERSION" ]] || needs_update=true
  printf '\n%-18s %-18s %-18s\n' '组件' '当前版本' '最新稳定版'
  printf '%-18s %-18s %-18s\n' '------------------' '------------------' '------------------'
  printf '%-18s %-18s %-18s\n' 'sing-box' "${current_singbox:-未知}" "$singbox_latest_label"
  printf '%-18s %-18s %-18s\n' 'Nfuse' "${current_nfuse:-未知}" "$LATEST_NFUSE_VERSION"
  printf '%-18s %-18s %-18s\n' '管理脚本' "${current_manager:-未知}" "$manager_latest_label"
  if [[ "$current_channel" == preview ]]; then
    echo "提示：sing-box 测试通道请在「sing-box 版本管理 → 更新当前通道」中更新。"
  fi
  if [[ "$needs_update" != true ]]; then
    if [[ "$current_channel" == preview ]]; then printf '\n其余组件已经是最新版本。\n'
    else printf '\n当前环境已经是最新版本。\n'
    fi
    return 0
  fi
  read -r -p $'\n检测到可更新内容，是否现在更新？[y/N]：' answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo "已取消更新。"; return 0; }
  deploy_environment false "$update_manager" || return 1
  if [[ "$update_manager" == true ]]; then
    printf '\n管理脚本已更新到 %s，正在切换到新进程。\n' "$LATEST_MANAGER_VERSION"
    exec /usr/local/sbin/sb-user-manager
  fi
}
# <<< check_updates

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
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "另一个管理操作正在进行，请等待完成后再试"
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
  if [[ "$protocol" == anytls ]]; then cmd_add_anytls managed "$name" "$port" "$limit" "$anchor" "$months" "$protocol_sni"; else cmd_add managed "$name" "$port" "$limit" "$anchor" "$months" "$method" "$protocol_sni"; fi
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
  if [[ "$protocol" == anytls ]]; then cmd_add_anytls self "$name" "$port" "$protocol_sni"; else cmd_add self "$name" "$port" "$method" "$protocol_sni"; fi
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
  local mode="$1" method="$2" shadowtls_sni="$3" tls_sni="$4"
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
  if ! prompt_available_user_port 'SS2022 + ShadowTLS 公网端口'; then MENU_RETURNED=true; return 0; fi
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
    cmd_add_multi managed "$name" "$ss_port" "$anytls_port" "$limit" "$anchor" "$months" "$method" "$shadowtls_sni" "$tls_sni"
  else
    cmd_add_multi self "$name" "$ss_port" "$anytls_port" "$method" "$shadowtls_sni" "$tls_sni"
  fi
}

prompt_add_node() {
  local protocol_choice account_choice protocol method="" protocol_sni="" shadowtls_sni="" tls_sni=""
  ensure_safe_ssh_for_singbox_restart || return 0
  load_runtime_config
  while true; do
    echo
    cat <<'EOF'
选择连接协议：
  1. SS2022 + ShadowTLS v3
  2. AnyTLS
  3. 同时启用两种协议（共享流量、有效期和状态）
  4. 为已有用户添加或移除协议
  0. 返回用户管理
EOF
    read_menu_choice '请选择协议：' '0,1,2,3,4' '' '请输入 1、2、3、4 或 0' || return 1
    protocol_choice="$PROMPT_VALUE"
    case "$protocol_choice" in
      1) protocol=ss2022;;
      2) protocol=anytls;;
      3) protocol=multi;;
      4) prompt_manage_user_protocols; return 0;;
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
      if ! read_validated_value "ShadowTLS SNI（留空使用全局默认 ${SS2022_SHADOWTLS_SNI}；输入 0 返回协议选择）：" "$SS2022_SHADOWTLS_SNI" 0 validate_shadowtls_sni; then continue; fi
      shadowtls_sni="$PROMPT_VALUE"
      protocol_sni="$shadowtls_sni"
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
      1) if [[ "$protocol" == multi ]]; then prompt_multi_account managed "$method" "$shadowtls_sni" "$tls_sni"; else prompt_managed "$protocol" "$method" "$protocol_sni"; fi; return 0;;
      2) if [[ "$protocol" == multi ]]; then prompt_multi_account self "$method" "$shadowtls_sni" "$tls_sni"; else prompt_self "$protocol" "$method" "$protocol_sni"; fi; return 0;;
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
     ([if (.endpoints | type) == "array" then .endpoints[].protocol else (.protocol // "ss2022") end |
       if . == "anytls" then "AnyTLS" else "SS2022 + ShadowTLS" end] | join(" + ")),
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
  local row name ports protocol_label status user count existing missing port method="" sni choice answer
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
  count="$(jq '.endpoints | length' <<<"$user")" || return 1
  if ((count == 1)); then
    existing="$(jq -r '.endpoints[0].protocol' <<<"$user")" || return 1
    [[ "$existing" == anytls ]] && missing=ss2022 || missing=anytls
    printf '\n用户 %s 当前只有 %s。\n' "$name" "$protocol_label"
    read -r -p "是否添加 $([[ "$missing" == anytls ]] && echo AnyTLS || echo 'SS2022 + ShadowTLS')，并共享现有流量、有效期和启停状态？[y/N]：" answer
    [[ "$answer" =~ ^[Yy]$ ]] || { echo '已取消。'; return 0; }
    if ! prompt_available_user_port '新协议公网端口'; then MENU_RETURNED=true; return 0; fi
    port="$PROMPT_VALUE"
    if [[ "$missing" == ss2022 ]]; then
      cat <<'EOF'
选择 SS2022 加密方式：
  1. 2022-blake3-aes-128-gcm（默认）
  2. 2022-blake3-aes-256-gcm
  0. 取消
EOF
      read_menu_choice '请选择加密方式 [1]：' '0,1,2' 1 '请输入 1、2 或 0' || return 1
      choice="$PROMPT_VALUE"
      [[ "$choice" != 0 ]] || { MENU_RETURNED=true; return 0; }
      [[ "$choice" == 1 ]] && method=2022-blake3-aes-128-gcm || method=2022-blake3-aes-256-gcm
      if ! read_validated_value "ShadowTLS SNI（留空使用 ${SS2022_SHADOWTLS_SNI}；输入 0 取消）：" "$SS2022_SHADOWTLS_SNI" 0 validate_shadowtls_sni; then MENU_RETURNED=true; return 0; fi
    else
      if ! read_validated_value "AnyTLS SNI（留空使用 ${ANYTLS_SNI}；输入 0 取消）：" "$ANYTLS_SNI" 0 validate_shadowtls_sni; then MENU_RETURNED=true; return 0; fi
    fi
    sni="$PROMPT_VALUE"
    cmd_add_user_endpoint "$name" "$missing" "$port" "$method" "$sni"
    return 0
  fi

  printf '\n用户 %s 当前同时拥有两个协议。移除协议不会改变账户累计用量、配额或有效期。\n' "$name"
  cat <<'EOF'
  1. 移除 SS2022 + ShadowTLS
  2. 移除 AnyTLS
  0. 取消
EOF
  read_menu_choice '请选择：' '0,1,2' '' '请输入 1、2 或 0' || return 1
  choice="$PROMPT_VALUE"
  case "$choice" in 1) missing=ss2022;; 2) missing=anytls;; 0) MENU_RETURNED=true; return 0;; esac
  read -r -p '确认移除该协议入口？客户端中的对应连接将立即失效。[y/N]：' answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo '已取消。'; return 0; }
  cmd_remove_user_endpoint "$name" "$missing"
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
  local row name port protocol_label status user endpoint endpoint_count protocol metered old_sni old_method old_anchor old_expiry
  local new_port new_sni new_method new_anchor new_expiry input choice answer changed=false
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
  endpoint_count="$(jq 'if (.endpoints | type) == "array" then .endpoints | length else 1 end' <<<"$user")" || return 1
  if ((endpoint_count > 1)); then
    cat <<'EOF'

请选择要编辑的连接协议：
  1. SS2022 + ShadowTLS
  2. AnyTLS
  0. 取消编辑
EOF
    read_menu_choice '请选择：' '0,1,2' '' '请输入 1、2 或 0' || return 1
    choice="$PROMPT_VALUE"
    case "$choice" in 1) protocol=ss2022; protocol_label='SS2022 + ShadowTLS';; 2) protocol=anytls; protocol_label=AnyTLS;; 0) MENU_RETURNED=true; return 0;; esac
  else
    protocol="$(jq -r 'if (.endpoints | type) == "array" then .endpoints[0].protocol else (.protocol // "ss2022") end' <<<"$user")" || return 1
  fi
  endpoint="$(jq -ec --arg protocol "$protocol" '
    if (.endpoints | type) == "array" then .endpoints[] | select(.protocol == $protocol)
    elif $protocol == "anytls" then {protocol:"anytls",port:.port,anytls_password:.anytls_password,tls_sni:.tls_sni}
    else {protocol:"ss2022",port:.port,shadowtls_password:.shadowtls_password,ss2022_password:.ss2022_password,
      method:.method,shadowtls_sni:.shadowtls_sni} end
  ' <<<"$user")" || return 1
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
    old_sni="$(jq -r '.shadowtls_sni' <<<"$endpoint")"
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
    if ! read_validated_value "ShadowTLS SNI（当前 ${old_sni}；留空保持；输入 0 取消）：" "$old_sni" 0 validate_shadowtls_sni; then MENU_RETURNED=true; return 0; fi
    new_sni="$PROMPT_VALUE"
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
  cmd_edit_user "$name" "$new_port" "$new_sni" "$new_method" "$new_anchor" "$new_expiry" "$protocol"
}

prompt_renew_user() {
  local -a rows
  local line i name expires status choice months
  prepare_core
  rows=()
  while IFS= read -r line; do rows[${#rows[@]}]="$line"; done < <(jq -r '
    .users[] | select(.expires_at != null) |
    [.name,
     .expires_at,
     (if .status == "active" then "启用" elif .status == "disabled" then "停用" else .status end)] |
    @tsv
  ' "$STATE_FILE" | sort -V)
  if ((${#rows[@]} == 0)); then echo "暂无可续期用户。"; return 0; fi
  echo
  echo "有有效期的用户（按用户名排序）："
  for i in "${!rows[@]}"; do
    IFS=$'\t' read -r name expires status <<<"${rows[$i]}"
    printf '  %d. %s｜到期 %s｜%s\n' "$((i + 1))" "$name" "${expires/T/ }" "$status"
  done
  echo "  0. 返回用户管理"
  if ! read_numbered_index '请选择要续期的用户编号：' "${#rows[@]}"; then MENU_RETURNED=true; return 0; fi
  IFS=$'\t' read -r name expires status <<<"${rows[$SELECTED_INDEX]}"
  while true; do
    read -r -p '请输入续期月数（输入 0 返回）：' months
    [[ "$months" != 0 ]] || { MENU_RETURNED=true; return 0; }
    [[ "$months" =~ ^[1-9][0-9]*$ ]] && break
    echo '输入无效：续期月数必须是正整数，请重新输入。'
  done
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
  local config_json nfuse_json user_rows split_rows split name status protocol port metered expected expected_tier tag split_status rule_tag out_tag scope scope_user scope_tags
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
     else {protocol:($user.protocol // "ss2022"),port:$user.port} end) |
    [$user.name,$user.status,.protocol,(.port|tostring),
     (($user.metered // ($user.limit_gib != null))|tostring)] | @tsv
  ' "$STATE_FILE")" || return 1
  split_rows="$(jq -c '.splits[]?' "$STATE_FILE")" || return 1
  printf '\n服务与配置检查结果\n\n'
  while IFS=$'\t' read -r name status protocol port metered; do
    [[ -n "$name" ]] || continue
    if [[ "$protocol" == anytls ]]; then expected="anytls-$name"
    else expected="st-$name ss-$name ss-udp-$name"
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
    if [[ "$protocol" != anytls && "$status" == active ]] &&
       jq -e --arg tag "ss-udp-$name" '.inbounds[]? | select(.tag == $tag)' <<<"$config_json" >/dev/null &&
       ! jq -e --arg tag "ss-udp-$name" --argjson port "$port" '
         .inbounds[]? | select(.tag == $tag and .type == "shadowsocks" and .network == "udp" and .listen_port == $port)
       ' <<<"$config_json" >/dev/null; then
      printf '  [可自动修复] 用户 %s 的 UDP 连接配置不正确\n' "$name"
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
  local users_total=0 users_active=0 users_disabled=0 users_ss=0 users_anytls=0 users_metered=0 users_self=0
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
    printf '用户：总计 %s｜启用 %s｜停用 %s｜SS2022 + ShadowTLS %s｜AnyTLS %s｜计量 %s｜自用 %s\n' \
      "$users_total" "$users_active" "$users_disabled" "$users_ss" "$users_anytls" "$users_metered" "$users_self"
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

show_global_sni_settings() {
  local ss_total ss_mismatch anytls_total anytls_mismatch
  prepare_core
  ss_total="$(jq '[.users[] | . as $user |
    (if (.endpoints | type) == "array" then .endpoints[] else {protocol:(.protocol // "ss2022")} end) |
    select(.protocol == "ss2022")] | length' "$STATE_FILE")"
  ss_mismatch="$(jq --arg sni "$SS2022_SHADOWTLS_SNI" '[.users[] | . as $user |
    (if (.endpoints | type) == "array" then .endpoints[] else {protocol:(.protocol // "ss2022"),shadowtls_sni:.shadowtls_sni} end) |
    select(.protocol == "ss2022" and .shadowtls_sni != $sni)] | length' "$STATE_FILE")"
  anytls_total="$(jq '[.users[] | . as $user |
    (if (.endpoints | type) == "array" then .endpoints[] else {protocol:(.protocol // "ss2022")} end) |
    select(.protocol == "anytls")] | length' "$STATE_FILE")"
  anytls_mismatch="$(jq --arg sni "$ANYTLS_SNI" '[.users[] | . as $user |
    (if (.endpoints | type) == "array" then .endpoints[] else {protocol:(.protocol // "ss2022"),tls_sni:.tls_sni} end) |
    select(.protocol == "anytls" and .tls_sni != $sni)] | length' "$STATE_FILE")"
  printf '\nSS2022 + ShadowTLS 默认连接域名：%s\n' "$SS2022_SHADOWTLS_SNI"
  printf '  用户数：%s，仍在使用其他域名：%s\n' "$ss_total" "$ss_mismatch"
  printf 'AnyTLS 默认连接域名：%s\n' "$ANYTLS_SNI"
  printf '  用户数：%s，仍在使用其他域名：%s\n' "$anytls_total" "$anytls_mismatch"
}

prompt_global_sni_change() {
  local protocol="$1" label="$2" current total answer new_sni
  prepare_core
  if [[ "$protocol" == ss2022 ]]; then current="$SS2022_SHADOWTLS_SNI"
  else current="$ANYTLS_SNI"
  fi
  total="$(jq --arg protocol "$protocol" '[.users[] | select(
    if (.endpoints | type) == "array" then any(.endpoints[]; .protocol == $protocol)
    else (.protocol // "ss2022") == $protocol end)] | length' "$STATE_FILE")"
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
  local choice
  while true; do
    prepare_menu_screen
    ui_menu_begin
    ui_header '默认连接域名（SNI）' '连接参数'
    ui_section '查看与修改'
    ui_menu_items \
      show '查看当前默认域名' \
      ss2022 '修改 SS2022 + ShadowTLS 默认域名' \
      anytls '修改 AnyTLS 默认域名'
    ui_back_item '返回上一级'
    ui_menu_select || return 0
    case "$UI_MENU_ACTION" in
      show) show_global_sni_settings; pause_menu;;
      ss2022) prompt_global_sni_change ss2022 'SS2022 + ShadowTLS'; pause_menu;;
      anytls) prompt_global_sni_change anytls AnyTLS; pause_menu;;
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
      edit '编辑用户' export '导出用户配置'
    printf '\n'
    ui_section '状态与计费'
    ui_menu_items \
      disable '停用用户' enable '启用用户' \
      renew '续期用户' traffic '调整用户流量'
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
      create) MENU_RETURNED=false; create_migration_backup; [[ "$MENU_RETURNED" == true ]] || pause_menu;;
      import) import_migration_backup; pause_menu;;
      list) echo; show_backup_storage_overview; echo; print_migration_backups || true; pause_menu;;
      details) show_migration_backup_details; pause_menu;;
      check) MENU_RETURNED=false; preview_migration_backup; [[ "$MENU_RETURNED" == true ]] || pause_menu;;
      check_all) MENU_RETURNED=false; check_all_migration_backups; [[ "$MENU_RETURNED" == true ]] || pause_menu;;
      restore) MENU_RETURNED=false; restore_migration_backup; [[ "$MENU_RETURNED" == true ]] || pause_menu;;
      remove) delete_migration_backup; pause_menu;;
      cleanup) cleanup_backup_retention; pause_menu;;
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
    ui_menu_items \
      deploy '部署与卸载' update '检测更新' \
      status '查看服务状态' diagnostics '检查与故障报告' \
      backup '数据备份与恢复' sni '默认连接域名（SNI）' \
      channel 'sing-box 版本管理'
    ui_back_item '返回主菜单'
    ui_menu_select || return 0
    case "$UI_MENU_ACTION" in
      deploy) deployment_management_menu;;
      update) check_updates; pause_menu;;
      status) show_service_status; pause_menu;;
      diagnostics) diagnostic_report_menu;;
      backup) migration_backup_menu;;
      sni) global_sni_menu;;
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
      install '安装或修复环境'
    printf '\n'
    ui_section '危险操作'
    printf '%s' "$UI_RED"
    ui_menu_items uninstall '完整卸载'
    printf '%s' "$UI_RESET"
    ui_back_item '返回上一级'
    ui_menu_select || return 0
    case "$UI_MENU_ACTION" in
      install) install_environment; pause_menu;;
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
  [[ $EUID -eq 0 ]] || die "必须使用 root 运行"
  case "${1:-}" in
    "") dispatch_interactive_startup "$@" ;;
    --internal-expire) run_standalone_internal_expire "${@:2}" ;;
    *) die "本脚本采用交互方式，请直接运行且不要添加参数" ;;
  esac
}

if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
  case "${0##*/}" in
    sb-user-manager-landing-agent)
      install_landing_apply_runtime_traps
      landing_agent_main "$@"
      ;;
    sb-user-manager-landing-apply)
      install_landing_apply_runtime_traps
      landing_apply_helper_main "$@"
      ;;
    *)
      install_runtime_traps
      main "$@"
      ;;
  esac
fi
