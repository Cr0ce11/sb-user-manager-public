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
SELF_SOURCE_PATH="${BASH_SOURCE[0]}"
SELF_PATH="$(readlink -f -- "$SELF_SOURCE_PATH")"
SCRIPT_VERSION="4.25.3"
SCRIPT_EDITION_LABEL="公开版"
STATE_SCHEMA_VERSION=7
MIN_SUPPORTED_STATE_SCHEMA_VERSION=0
MIGRATION_FORMAT_VERSION=1
MIGRATION_BUNDLE_VERSION=1
TRANSACTION_FORMAT_VERSION=1
OPERATION_BACKUP_RETENTION="${SB_OPERATION_BACKUP_RETENTION:-10}"
ENVIRONMENT_BACKUP_RETENTION="${SB_ENVIRONMENT_BACKUP_RETENTION:-5}"
MIGRATION_REPORT_RETENTION="${SB_MIGRATION_REPORT_RETENTION:-20}"
ENVIRONMENT_TRANSACTION_JOURNAL="${SB_ENVIRONMENT_TRANSACTION_JOURNAL:-/var/lib/sb-user-manager.recovery.json}"
ENVIRONMENT_LOCK_FILE="${SB_ENVIRONMENT_LOCK_FILE:-/run/lock/sb-user-manager-environment.lock}"
MANAGER_HANDOFF_DIRECTORY="${SB_MANAGER_HANDOFF_DIRECTORY:-/var/lib/sb-user-manager/manager-handoff}"
MANAGER_HANDOFF_JOURNAL="${SB_MANAGER_HANDOFF_JOURNAL:-$MANAGER_HANDOFF_DIRECTORY/active.json}"
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
    [[ "$name" =~ ^\.(managed-users|migration-config|migration-state|state-restore|restore-config|restore-state|restore-previous-state|restore-manager-config|sb-user-manager\.conf|sb-user-manager\.launch|atomic-install|manager-handoff|config|normalized|takeover-normalized|takeover-config)\. ]] ||
    [[ "$name" =~ ^\.(nfuse-snapshot|transaction)\. ]] ||
    [[ "$name" =~ ^\.singbox-channel\. ]] ||
    [[ "$name" =~ ^\.shared-preset-runtime\. ]] ||
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
