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
SCRIPT_VERSION="4.25.22"
SCRIPT_EDITION_LABEL="公开版"
STATE_SCHEMA_VERSION=7
# 代理内核的文件级默认值。载入管理配置之前也可能被读到（例如只读查询的早期路径），
# 因此这里先定义，具体取值与校验仍由 load_runtime_config 负责。
PROXY_KERNEL="singbox"
# 内核的位置与服务名同理需要文件级默认值：部署流程在管理配置写出之前就要
# 用适配层写单元文件、校验配置，而 load_runtime_config 在那之前只在子进程里跑过。
# load_runtime_config 中同名的 := 兜底保留不动，管理配置里的显式取值仍然覆盖这里。
SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_CONFIG="/etc/sing-box/config.json"
SINGBOX_SERVICE="sing-box"
MIHOMO_BIN="/usr/local/bin/mihomo"
MIHOMO_CONFIG="/etc/mihomo/config.json"
MIHOMO_SERVICE="mihomo"
MIHOMO_WORK_DIR="/var/lib/mihomo"
# 管理器自身数据的根目录：用户资料、内部备份、AnyTLS 自签证书都在这里。
# 这些是管理器的数据，不是 sing-box 的；目录名沿用 /etc/sing-box 纯属历史原因。
# 这里是这三类路径的唯一来源，改这一个值整组跟着变。默认值不变，
# 长期方向与搬家计划见公开 Issue #172。
MANAGER_DATA_DIR="/etc/sing-box"
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
MANAGER_REPOSITORY="Cr0ce11/sb-user-manager-public"
MANAGER_ASSET="sb-user-manager.sh"
# 公开版使用固定仓库和资产名匿名检查自身更新。
: "$MANAGER_REPOSITORY" "$MANAGER_ASSET"
SINGBOX_REPOSITORY="SagerNet/sing-box"
SINGBOX_ARCH="linux-amd64"
MIHOMO_REPOSITORY="MetaCubeX/mihomo"
# 资产变体刻意选 compatible（GOAMD64=v1），不是不带后缀的那个。
# 实测：mihomo 不带后缀的 linux-amd64 资产其实是 v3 构建，在不支持 v3 微架构的
# CPU 上直接拒绝运行（退出码 1）。廉价 VPS 上只到 v2 的老 Xeon 仍然常见，
# 本项目的测试机自己也跑不了 v3。详见公开 Issue #165。
MIHOMO_ARCH="linux-amd64-compatible"
SINGBOX_CHANNEL_STATE="${SB_SINGBOX_CHANNEL_STATE:-/var/lib/sb-user-manager/singbox-channel.json}"
SINGBOX_VERSION_STORE="${SB_SINGBOX_VERSION_STORE:-/var/lib/sb-user-manager/singbox-versions}"
DEPLOYED_VERSIONS_FILE="${SB_DEPLOYED_VERSIONS_FILE:-/var/lib/sb-user-manager/versions}"
DIAGNOSTIC_REPORT_DIR="${SB_DIAGNOSTIC_REPORT_DIR:-/root/sb-user-manager-diagnostics}"
DEFAULT_SS2022_SHADOWTLS_SNI="publicassets.cdn-apple.com"
DEFAULT_ANYTLS_SNI="weKbP9SVYU.download.windowsupdate.com"

# 由 MANAGER_DATA_DIR 派生的路径。文件级与 load_runtime_config 两处共用这一个
# 函数，而不是各写一遍拼接：两份写法迟早会漂移。
# 需要文件级取值的原因与 SINGBOX_BIN 那一组相同——部署流程在管理配置写出之前
# 就要用到证书目录（mihomo 单元里的 SAFE_PATHS），而那时 load_runtime_config
# 只在子进程里跑过。
resolve_manager_data_paths() {
  CERT_DIR="$MANAGER_DATA_DIR/cert"
  ANYTLS_CERT_FILE="$CERT_DIR/anytls.crt"
  ANYTLS_KEY_FILE="$CERT_DIR/anytls.key"
}
resolve_manager_data_paths

# mihomo 部署下，使用者自己的分流规则文件放在这里。管理器建这个目录、
# 读里面的文件，但**永远不写它们**——那是使用者从社区抄来的片段。
# 与 mihomo 配置文件同目录派生，不单独做成配置项：这个目录必须与 systemd
# 单元里的 SAFE_PATHS 一字不差，而 mihomo 会当场拒绝加载允许范围之外的
# 规则文件（公开 Issue #186 实测；这一点比证书那条严，证书要到启动才报）。
# 两个可以各自设置的值迟早会不一致，而不一致的后果是配置根本加载不了。
resolve_mihomo_paths() {
  MIHOMO_RULES_DIR="${MIHOMO_CONFIG%/*}/rules"
}
resolve_mihomo_paths

# mihomo 允许读取的目录清单，冒号分隔（实测逗号不认，会被当成路径的一部分）。
# systemd 单元与管理器自己跑的配置校验必须用**同一份**：单元给服务用，
# 这一份给 `mihomo -t` 用。两边不一致会出现自相矛盾的失败——管理器说配置
# 不可用、拒绝操作，而服务其实跑得起来。证书那条从来没暴露过这个问题，
# 因为 `mihomo -t` 根本不检查证书路径；规则文件路径它却当场就查
# （公开 Issue #186）。
mihomo_safe_paths() {
  printf '%s:%s' "$CERT_DIR" "$MIHOMO_RULES_DIR"
}

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
      SS_METHOD|HANDSHAKE_SERVER|TLS_SERVER_NAME|PORT_MIN|PORT_MAX|PROXY_KERNEL|\
      MIHOMO_BIN|MIHOMO_CONFIG|MIHOMO_SERVICE|MIHOMO_WORK_DIR|MANAGER_DATA_DIR) ;;
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
  # 本机使用哪个代理内核。缺失即 sing-box：既有部署与 sing-box 新装机器的
  # 管理配置里不写这一项，内容与历史版本一字不差，回退到旧脚本不受影响。
  # 只有 mihomo 部署才会写入该键，而那类机器本来就无法回退到不支持 mihomo 的脚本。
  : "${PROXY_KERNEL:=singbox}"
  case "$PROXY_KERNEL" in
    singbox|mihomo) ;;
    # 不静默降级为 sing-box：那会让一台本该跑 mihomo 的机器悄悄跑成另一个内核，
    # 而使用者从界面上看不出任何异常。
    *) die "管理配置中的内核名无法识别：${PROXY_KERNEL}。当前脚本支持：singbox、mihomo" ;;
  esac
  : "${SINGBOX_BIN:=/usr/local/bin/sing-box}"
  : "${SINGBOX_CONFIG:=/etc/sing-box/config.json}"
  : "${SINGBOX_SERVICE:=sing-box}"
  # mihomo 的位置与 sing-box 并列，互不覆盖：一台机器只跑其中一个，
  # 但两套默认值都先备好，适配层按 PROXY_KERNEL 取用哪一套。
  # 工作目录是 mihomo 特有的概念——它把 cache.db 一类运行期文件写在这里，
  # 并且默认只允许加载工作目录之内的证书（见公开 Issue #154）。
  : "${MIHOMO_BIN:=/usr/local/bin/mihomo}"
  : "${MIHOMO_CONFIG:=/etc/mihomo/config.json}"
  : "${MIHOMO_SERVICE:=mihomo}"
  : "${MIHOMO_WORK_DIR:=/var/lib/mihomo}"
  resolve_mihomo_paths
  : "${NFUSE_BIN:=/usr/local/bin/nfuse}"
  : "${NFUSE_SOCKET:=/run/nfuse.sock}"
  : "${NFUSE_DB:=/var/lib/nfuse/nfuse.db}"
  # 管理器数据目录。既有部署与 sing-box 新装机器的管理配置里不写这一项，
  # 取默认值后与历史版本一字不差；显式写了就以配置为准。
  : "${MANAGER_DATA_DIR:=/etc/sing-box}"
  # 相对路径会让用户资料、内部备份与证书落到脚本当时的工作目录里，
  # 而这三样东西丢了就是丢了。宁可拒绝启动，不将就。
  [[ "$MANAGER_DATA_DIR" == /* ]] ||
    die "管理配置中的管理器数据目录必须是绝对路径：$MANAGER_DATA_DIR"
  resolve_manager_data_paths
  : "${STATE_FILE:=$MANAGER_DATA_DIR/managed-users.json}"
  : "${LOCK_FILE:=/run/lock/sb-user-manager.lock}"
  : "${BACKUP_DIR:=$MANAGER_DATA_DIR/backups}"
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
  # 非交互只读入口把「工具自身出错」统一为退出码 3，避免与「提醒」(1) 混淆；
  # 未设置时保持原有的 1，交互路径行为不变。
  exit "${SB_READONLY_EXIT_CODE:-1}"
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

unregister_temp_path() {
  local path="$1" read_index write_index=0 registered
  [[ -n "$path" ]] || die "拒绝取消登记空临时路径"
  is_managed_temp_path "$path" || die "拒绝取消登记不受管临时路径：$path"
  for ((read_index=0; read_index<RUNTIME_TEMP_PATH_COUNT; read_index++)); do
    registered="${RUNTIME_TEMP_PATHS[$read_index]}"
    [[ "$registered" == "$path" ]] && continue
    RUNTIME_TEMP_PATHS[write_index]="$registered"
    write_index=$((write_index + 1))
  done
  for ((read_index=write_index; read_index<RUNTIME_TEMP_PATH_COUNT; read_index++)); do
    unset "RUNTIME_TEMP_PATHS[$read_index]"
  done
  RUNTIME_TEMP_PATH_COUNT="$write_index"
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
