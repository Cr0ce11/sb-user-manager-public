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
SCRIPT_VERSION="4.25.29"
SCRIPT_EDITION_LABEL="公开版"
STATE_SCHEMA_VERSION=7
# 「尚未解析」的哨兵，不是一个能用的取值（公开 Issue #262）。
#
# 这两个变量必须在文件级有值，否则 `set -u` 会让任何提前读到它们的代码当场结束
# 进程。但**给它们一个像真的默认值比没有值更危险**：以前这里写的是 sing-box 与
# /etc/sing-box，于是任何在载入管理配置之前读到它们的代码，都会拿到一个看起来
# 完全正常、实际可能完全错误的答案——[公开 Issue #251] 就是这么坏的：到期任务在
# 载入配置之前判断环境完整性，那一刻脚本以为自己是 sing-box 机器，于是在 mihomo
# 机器上每次都去找一个不存在的配置文件，每 15 分钟静静失败一次，而它是一个不产生
# 任何界面提示的 oneshot 服务。
#
# 现在提前使用会当场报错：适配层的每个分派都以 kernel_unknown 收尾，
# 管理器数据路径的派生入口 resolve_manager_data_paths 也会拒绝哨兵。
#
# **存量机器的兼容兜底没有消失，只是挪了地方**：管理配置里不写这两个键的老机器，
# 由 load_runtime_config 里那两行 `:=` 给出 singbox 与 /etc/sing-box；管理配置
# 整个丢失的机器由 resolve_deployment_kernel 显式给出。两条路的结果与本次改动
# 之前一字不差。
KERNEL_UNRESOLVED="__unresolved__"
MANAGER_DATA_DIR_UNRESOLVED="/__sb-user-manager-unresolved__"
PROXY_KERNEL="$KERNEL_UNRESOLVED"
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
# 这些是管理器的数据，不是内核的。这里同样是哨兵，理由见上面 PROXY_KERNEL 那一段。
# **这个变量指着用户数据，读错的代价比内核名更高**：管理配置里没有这一行的存量
# 机器（`sbm-mihomo` 就是），AnyTLS 证书目录只能由它派生，指错了会被判定为证书
# 不存在而重新签发，所有 AnyTLS 用户当场连不上；完整环境快照的路径清单里也直接
# 放着它，指错了快照就不再收录用户数据。长期方向与搬家计划见公开 Issue #172。
LEGACY_MANAGER_DATA_DIR="/etc/sing-box"
MANAGER_DATA_DIR="$MANAGER_DATA_DIR_UNRESOLVED"
MIN_SUPPORTED_STATE_SCHEMA_VERSION=0
MIGRATION_FORMAT_VERSION=1
MIGRATION_BUNDLE_VERSION=1
TRANSACTION_FORMAT_VERSION=1
OPERATION_BACKUP_RETENTION="${SB_OPERATION_BACKUP_RETENTION:-10}"
ENVIRONMENT_BACKUP_RETENTION="${SB_ENVIRONMENT_BACKUP_RETENTION:-5}"
MIGRATION_REPORT_RETENTION="${SB_MIGRATION_REPORT_RETENTION:-20}"
# 环境事务的恢复记录。**必须放在管理器自己的目录之内**，不能直接摆在 /var/lib 下：
# begin_environment_transaction 会创建它的父目录，而 `install -d -m` 点到一个已经
# 存在的目录时会直接 chmod 它。这个默认值曾经是 /var/lib/sb-user-manager.recovery.json，
# 取出来的父目录就是 /var/lib 本身，于是每次环境操作都把 /var/lib 改成 700——
# apt 的下载沙箱与所有以非 root 身份读 /var/lib/<服务名> 的服务都会因此失效
# （公开 Issue #246）。tests/test-static.sh 有一条断言钉住这个位置。
ENVIRONMENT_TRANSACTION_JOURNAL="${SB_ENVIRONMENT_TRANSACTION_JOURNAL:-/var/lib/sb-user-manager/recovery.json}"
# 换位置之前的旧路径。**必须继续认得它**：更新流程在事务中途替换管理脚本，
# 若恰好在替换之后、清除记录之前中断，下一次运行的就是新脚本、而记录还留在
# 旧路径上。认不出它，等于把一台半截机器当成干净机器放行。
LEGACY_ENVIRONMENT_TRANSACTION_JOURNAL="${SB_LEGACY_ENVIRONMENT_TRANSACTION_JOURNAL:-/var/lib/sb-user-manager.recovery.json}"
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
DEPLOYED_VERSIONS_FILE="${SB_DEPLOYED_VERSIONS_FILE:-/var/lib/sb-user-manager/versions}"
DIAGNOSTIC_REPORT_DIR="${SB_DIAGNOSTIC_REPORT_DIR:-/root/sb-user-manager-diagnostics}"
DEFAULT_SS2022_SHADOWTLS_SNI="publicassets.cdn-apple.com"
DEFAULT_ANYTLS_SNI="weKbP9SVYU.download.windowsupdate.com"
# geo 数据源的文件级默认值（公开 Issue #219）。空字符串表示用 mihomo 自带的源。
# 必须在文件级就有值：管理配置载入之前也可能读到它们（只读查询的早期路径、
# 以及直接设置变量的单元测试），而 set -u 下读一个没定义的变量会当场结束进程。
GEOSITE_URL=""
GEOIP_URL=""

# 由 MANAGER_DATA_DIR 派生的路径。文件级与 load_runtime_config 两处共用这一个
# 函数，而不是各写一遍拼接：两份写法迟早会漂移。
# 需要文件级取值的原因与 SINGBOX_BIN 那一组相同——部署流程在管理配置写出之前
# 就要用到证书目录（mihomo 单元里的 SAFE_PATHS），而那时 load_runtime_config
# 只在子进程里跑过。
#
# **哨兵到这里必须停住**（公开 Issue #262）：这三条路径指着 AnyTLS 的证书与私钥，
# 用哨兵派生出来的目录一定不存在，上层会把它当成「证书还没生成」而重新签发一张
# ——所有 AnyTLS 用户当场连不上，而过程中没有任何一步会报错。宁可响亮地停下。
resolve_manager_data_paths() {
  if [[ "$MANAGER_DATA_DIR" == "$MANAGER_DATA_DIR_UNRESOLVED" ]]; then
    printf '内部错误：还没有确定管理器数据目录就去派生它下面的路径；请先调用 load_runtime_config 或 resolve_deployment_kernel\n' >&2
    return 1
  fi
  CERT_DIR="$MANAGER_DATA_DIR/cert"
  ANYTLS_CERT_FILE="$CERT_DIR/anytls.crt"
  ANYTLS_KEY_FILE="$CERT_DIR/anytls.key"
}
# 文件级只把三个变量摆成同样「尚未解析」的样子，好让 `set -u` 有值可读，
# **不经过上面那个函数**——源文件被 source 的这一刻本来就还没解析，
# 在这里调用它等于让守卫对着自己报错。真正的取值由 load_runtime_config 或
# resolve_deployment_kernel 给出。派生写法仍然只有函数里那一份。
CERT_DIR="$MANAGER_DATA_DIR_UNRESOLVED/cert"
ANYTLS_CERT_FILE="$CERT_DIR/anytls.crt"
ANYTLS_KEY_FILE="$CERT_DIR/anytls.key"

# 恢复记录换过位置（公开 Issue #246）。新位置不存在、旧位置却留着一份时，
# 本次运行整体以旧路径为准——认得它的每一处（开工前的拦截、开机自检的恢复、
# 诊断报告、清除记录）因此自动一致，不必逐个调用点各判一次。
# 只在这一处解析：漏掉任何一处的后果都是把一台半截机器当成干净机器放行。
resolve_environment_transaction_journal() {
  [[ ! -e "$ENVIRONMENT_TRANSACTION_JOURNAL" && ! -L "$ENVIRONMENT_TRANSACTION_JOURNAL" ]] || return 0
  [[ -e "$LEGACY_ENVIRONMENT_TRANSACTION_JOURNAL" || -L "$LEGACY_ENVIRONMENT_TRANSACTION_JOURNAL" ]] || return 0
  ENVIRONMENT_TRANSACTION_JOURNAL="$LEGACY_ENVIRONMENT_TRANSACTION_JOURNAL"
}
resolve_environment_transaction_journal

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
      MIHOMO_BIN|MIHOMO_CONFIG|MIHOMO_SERVICE|MIHOMO_WORK_DIR|MANAGER_DATA_DIR|\
      GEOSITE_URL|GEOIP_URL) ;;
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
  # geo 数据源同理：回滚到还没有这两项的旧配置时，不能沿用进程里的旧取值，
  # 否则「已经改回默认源」的机器会继续按上一次的自定义地址算（公开 Issue #219）。
  GEOSITE_URL=""
  GEOIP_URL=""
  # 内核与管理器数据目录同理，而且理由更硬：它们的文件级取值是「尚未解析」哨兵
  # （公开 Issue #262），清空之后下面那两行 `:=` 才是存量机器的兜底判据——
  # 管理配置里不写这两个键的老机器全靠它们。不清空的话，哨兵是非空值，`:=` 永远
  # 不会生效，老机器会拿到哨兵；而如果同一个进程先载入过另一份配置，还会沿用上
  # 一份的取值，回滚到旧配置的机器就会按新配置的目录去找用户资料。
  PROXY_KERNEL=""
  MANAGER_DATA_DIR=""
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
  # 取这里的兜底值后与历史版本一字不差；显式写了就以配置为准。
  # 这一行是存量机器唯一的判据，不能删（公开 Issue #262）。
  : "${MANAGER_DATA_DIR:=$LEGACY_MANAGER_DATA_DIR}"
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
  # GeoSite／GeoIP 数据库的下载地址（公开 Issue #219）。留空表示用 mihomo 自带的
  # 默认源——因此默认值是空字符串，而不是把 mihomo 的默认地址抄一份进来：抄一份
  # 就等于把上游哪天换地址的责任接过来，而且抄错了没有任何地方会说。
  : "${GEOSITE_URL:=}"
  : "${GEOIP_URL:=}"
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
# 内核适配层。所有对代理内核可执行文件的直接调用都集中在本模块，
# 其它模块只经由这里定义的函数与内核交互。
# 这样做的原因：上游内核会在小版本之间修改配置规范与命令行接口，
# 调用点散落在各模块时，每次跟进都要同时改多处；集中之后只改这里一处。
#
# 本模块按 $PROXY_KERNEL 分派。分派刻意只写在「取名字与路径」的存取函数和
# 「命令行写法本来就不同」的少数函数里，其余函数经存取函数间接使用，
# 因此不需要各自再写一遍 case——同一处判断写两遍才是分叉的来源。
# tests/test-static.sh 据此检查：本模块中凡是直接提到某个内核的函数，
# 都必须同时给出两个内核的分支。

# 内核名无法识别时的统一出口。载入管理配置时已经拒绝过未知内核名，
# 这里是防止将来有人绕开那条路径后静默走错分支。
kernel_unknown() {
  # 哨兵单独说一句：那不是「配置里写错了内核名」，而是「还没确定内核就用了适配层」，
  # 两者的下一步完全不同（公开 Issue #262）。
  if [[ "$PROXY_KERNEL" == "$KERNEL_UNRESOLVED" ]]; then
    printf '内部错误：还没有确定本机的代理内核就调用了内核适配层；请先调用 load_runtime_config 或 resolve_deployment_kernel\n' >&2
    return 1
  fi
  printf '内部错误：代理内核名无法识别：%s\n' "${PROXY_KERNEL:-未设置}" >&2
  return 1
}

# 某个内核尚未实现的操作。刻意报错而不是回落到另一个内核的实现：
# 回落会让一台 mihomo 机器按 sing-box 的结构改写配置，产生的是坏数据而不是错误。
kernel_unsupported() {
  printf '当前部署使用的代理内核（%s）尚不支持该操作：%s\n' "${PROXY_KERNEL:-未设置}" "$1" >&2
  return 1
}

# 当前部署的内核可执行文件、配置文件、服务名与工作目录。
# 工作目录是 mihomo 特有的概念：它把 cache.db 一类运行期文件写在这里，
# 并且默认拒绝加载工作目录之外的证书（公开 Issue #154）。sing-box 没有对应物。
kernel_binary_path() {
  case "$PROXY_KERNEL" in
    singbox) printf '%s' "$SINGBOX_BIN" ;;
    mihomo) printf '%s' "$MIHOMO_BIN" ;;
    *) kernel_unknown ;;
  esac
}

kernel_config_path() {
  case "$PROXY_KERNEL" in
    singbox) printf '%s' "$SINGBOX_CONFIG" ;;
    mihomo) printf '%s' "$MIHOMO_CONFIG" ;;
    *) kernel_unknown ;;
  esac
}

kernel_service_name() {
  case "$PROXY_KERNEL" in
    singbox) printf '%s' "$SINGBOX_SERVICE" ;;
    mihomo) printf '%s' "$MIHOMO_SERVICE" ;;
    *) kernel_unknown ;;
  esac
}

kernel_work_dir() {
  case "$PROXY_KERNEL" in
    singbox) printf '%s' /var/lib/sing-box ;;
    mihomo) printf '%s' "$MIHOMO_WORK_DIR" ;;
    *) kernel_unknown ;;
  esac
}

# 给使用者看的内核名称。界面上不出现 singbox / mihomo 这种内部标识。
kernel_display_name() {
  case "$PROXY_KERNEL" in
    singbox) printf 'sing-box' ;;
    mihomo) printf 'mihomo' ;;
    *) kernel_unknown ;;
  esac
}

# 内核在 `ss -p` 一类输出里出现的进程名。刻意与展示名分成两个函数：
# 两者当前取值相同纯属巧合，而「SSH 连接是不是走本机节点」这条护栏
# 依赖的是进程名的精确匹配，不能跟着展示措辞一起改。
kernel_process_name() {
  case "$PROXY_KERNEL" in
    singbox) printf 'sing-box' ;;
    mihomo) printf 'mihomo' ;;
    *) kernel_unknown ;;
  esac
}

# 按标准绝对路径读取既有安装的规范化配置。与 kernel_check_default_install 同理，
# 调用发生在接管流程中，那时运行时配置尚未加载。
kernel_normalized_default_install() {
  case "$PROXY_KERNEL" in
    singbox) /usr/local/bin/sing-box format -c /etc/sing-box/config.json || return 1 ;;
    mihomo) kernel_unsupported '读取既有安装的规范化配置' ;;
    *) kernel_unknown ;;
  esac
}

# 当前部署的运行配置文件。托管内容读写都经这里取路径，不各自写一遍 case。
kernel_runtime_config_path() {
  case "$PROXY_KERNEL" in
    singbox) printf '%s' "$SINGBOX_CONFIG" ;;
    mihomo) printf '%s' "$MIHOMO_CONFIG" ;;
    *) kernel_unknown ;;
  esac
}

# 托管内容在运行配置里所处的容器与它的标识字段。
# sing-box 把用户入口放在 .inbounds[] 并用 .tag 标识，mihomo 放在 .listeners[]
# 并用 .name 标识。两者只是名字不同，语义一致，因此抽成取值函数而不是各写一套
# 过滤器——同一段 jq 逻辑写两遍，迟早只改一遍。
kernel_managed_container() {
  case "$PROXY_KERNEL" in
    singbox) printf 'inbounds' ;;
    mihomo) printf 'listeners' ;;
    *) kernel_unknown ;;
  esac
}

kernel_managed_key() {
  case "$PROXY_KERNEL" in
    singbox) printf 'tag' ;;
    mihomo) printf 'name' ;;
    *) kernel_unknown ;;
  esac
}

# 读取当前部署的内核配置，输出规范化后的 JSON 到标准输出。
# 调用方可以重定向到文件、用命令替换取值，或直接接管道，三种形态都适用。
#
# 两个内核的规范化来源不同，这是一处有代价的取舍：
# sing-box 的 `format` 同时做两件事——确认配置能被内核解析，以及给出**内核自己
# 视角**的规范化形式。mihomo 没有等价子命令，只能拆成两步：内核负责校验
# （kernel_check_config），jq 负责规范化。代价是规范化结果是我们的视角而不是
# 内核的视角。
#
# 因此 mihomo 这一支在 jq 读不了时**失败而不是将就**：那说明配置不是 JSON
# （例如有人手工改成了带锚点与注释的真 YAML），此时把它重写成 JSON 会毁掉
# 人家的东西。宁可拒绝改写，让使用者自己决定。
# 退路：将来 mihomo 若提供等价的规范化输出，换掉这一支即可，接口不变。
kernel_normalized_config() {
  case "$PROXY_KERNEL" in
    singbox) "$SINGBOX_BIN" format -c "$SINGBOX_CONFIG" ;;
    mihomo)
      jq . "$MIHOMO_CONFIG" 2>/dev/null || {
        printf '错误：mihomo 运行配置不是 JSON，管理器不会改写它：%s\n' "$MIHOMO_CONFIG" >&2
        return 1
      }
      ;;
    *) kernel_unknown ;;
  esac
}

# 用当前安装的内核校验指定的配置文件。
# 不内建输出重定向：各调用点对错误输出的处理不同（向用户显示、静默、捕获），
# 由调用点自行决定。
kernel_check_config() {
  kernel_check_config_with "$(kernel_binary_path)" "$1" || return 1
}

# 用指定的内核可执行文件校验配置文件。校验用的二进制不一定是当前在跑的那个：
# 分流规则集的探针会拿候选二进制先试一遍。
# （接管既有安装那条路已于 v4.25.23 撤除，公开 Issue #157；sing-box 通道切换
# 已于 sing-box 线归档时撤除，公开 Issue #256。）
# 两个内核的写法不同：sing-box 是 `check -c 文件`，mihomo 是 `-t -d 工作目录 -f 文件`。
# mihomo 必须带 -d：不带时它会按自己的默认目录找配置并在那里落下运行期文件。
# 还必须带 SAFE_PATHS，且与 systemd 单元里的那一份同源：`mihomo -t` 会当场
# 拒绝允许范围之外的规则文件路径，环境不一致时校验结果就不代表服务的行为。
kernel_check_config_with() {
  case "$PROXY_KERNEL" in
    singbox) "$1" check -c "$2" || return 1 ;;
    mihomo) SAFE_PATHS="$(mihomo_safe_paths)" "$1" -t -d "$MIHOMO_WORK_DIR" -f "$2" || return 1 ;;
    *) kernel_unknown ;;
  esac
}

# 按标准绝对路径校验既有安装的配置。
# 这里刻意不使用运行时配置里的路径：调用发生在环境探测与部署流程中，
# 那时运行时配置可能尚未加载，而且这里要确认的正是标准位置上的部署是否可用。
kernel_check_default_install() {
  case "$PROXY_KERNEL" in
    singbox) /usr/local/bin/sing-box check -c /etc/sing-box/config.json || return 1 ;;
    mihomo) SAFE_PATHS="$(mihomo_safe_paths)" /usr/local/bin/mihomo -t -d /var/lib/mihomo -f /etc/mihomo/config.json || return 1 ;;
    *) kernel_unknown ;;
  esac
}

# 内核配置骨架的唯一定义。语义是「幂等补齐，不覆盖已有值」：
# 对空对象应用它得到全新安装的初始配置，对既有配置应用它只补上缺的部分。
# 全新安装与一致性审计共用这一份，避免各写一套之后悄悄分叉——
# v4.25.11 所修的缺陷正是同一份判断被写成两处而产生的。
# 骨架属于内核特有的 schema 知识，因此放在适配层，每个内核各一份。
SINGBOX_SKELETON_ENSURE_PROGRAM='
  if type != "object" then error("运行配置不是 JSON 对象") else . end
  | .log = (.log // {level:"info",timestamp:true})
  | .dns = (.dns // {})
  | .dns.servers = (.dns.servers // [])
  | (if any(.dns.servers[]?; .tag == "local") then . else .dns.servers += [{type:"local",tag:"local"}] end)
  | .dns.final = (.dns.final // "local")
  | .inbounds = (.inbounds // [])
  | .outbounds = (.outbounds // [])
  | (if any(.outbounds[]?; .tag == "direct") then . else .outbounds += [{type:"direct",tag:"direct"}] end)
  | .route = (.route // {})
  | .route.rules = (.route.rules // [])
  | .route.rule_set = (.route.rule_set // [])
  | .route.final = (.route.final // "direct")
  | .route.default_domain_resolver = (.route.default_domain_resolver // "local")
  | .experimental = (.experimental // {})
  | .experimental.cache_file = (.experimental.cache_file // {})
  | .experimental.cache_file.enabled = (.experimental.cache_file.enabled // true)'

# mihomo 的骨架。这里刻意**不写**用来重申默认值的配置项。
# mihomo 对未知键完全静默（公开 Issue #154），写一个拼错的 external-controller
# 只会带来虚假的安全感；真正起保护作用的是「服务起来之后名下监听套接字数为 0」
# 这条可观测断言，它一条就同时证明了控制接口与所有通用入口都没有打开。
# 实测：以 {"listeners":[]} 启动的 mihomo 不监听任何端口，也不下载任何 geo 数据库。
# proxies / proxy-groups / rules 是分流要用的容器（第二步 2d），现在先以空数组占位，
# 使骨架在后续分片中保持稳定，不必每加一片就改一次定义。
MIHOMO_SKELETON_ENSURE_PROGRAM='
  if type != "object" then error("运行配置不是 JSON 对象") else . end
  | .["log-level"] = (.["log-level"] // "info")
  | .mode = (.mode // "rule")
  | .listeners = (.listeners // [])
  | .proxies = (.proxies // [])
  | .["proxy-groups"] = (.["proxy-groups"] // [])
  | .rules = (.rules // [])'

# ============================================================
# 用户入口的生成：一个用户在当前内核下的托管条目
# ============================================================
# 返回 JSON 数组。**条目数量本来就随内核不同**，调用点不得假设：
# sing-box 的 SS2022 + ShadowTLS 需要三个入站（ShadowTLS 独立入站、detour 指向的
# shadowsocks、以及单独承载 UDP 的那个），mihomo 一个监听器就同时承载 TCP 与 UDP。
# 后者是实测结论：一个 shadowsocks 监听器默认就开 tcp 与 udp，加上 shadow-tls
# 之后仍然如此；显式写 "udp": false 时 UDP 套接字消失（公开 Issue #180）。
#
# 名字沿用 sing-box 那套前缀（st- / ss- / ss-direct- / anytls-），两个内核共用，
# 因此按前缀识别与删除托管内容的逻辑不必分内核各写一遍。
#
# 涉密内容一律经环境变量传给 jq，不进命令行参数。

kernel_entries_ss2022_shadowtls() {
  local name="$1" port="$2" st_password="$3" ss_password="$4" method="$5" shadowtls_sni="$6"
  case "$PROXY_KERNEL" in
    singbox)
      SB_JQ_ST_PASSWORD="$st_password" SB_JQ_SS_PASSWORD="$ss_password" jq -n \
        --arg name "$name" --argjson port "$port" --arg method "$method" \
        --arg hs_server "$shadowtls_sni" --argjson hs_port "$HANDSHAKE_PORT" \
        --argjson strict "$SHADOWTLS_STRICT_MODE" \
        '[{"type":"shadowtls","tag":("st-" + $name),"listen":"::","listen_port":$port,"version":3,
           "users":[{"name":$name,"password":$ENV.SB_JQ_ST_PASSWORD}],
           "handshake":{"server":$hs_server,"server_port":$hs_port},
           "strict_mode":$strict,"detour":("ss-" + $name)},
          {"type":"shadowsocks","tag":("ss-" + $name),"network":"tcp","method":$method,
           "password":$ENV.SB_JQ_SS_PASSWORD},
          {"type":"shadowsocks","tag":("ss-udp-" + $name),"listen":"::","listen_port":$port,
           "network":"udp","method":$method,"password":$ENV.SB_JQ_SS_PASSWORD}]'
      ;;
    mihomo)
      # 严格模式的键名是 strict-mode，不是 strictmode——监听器配置走的是
      # inbound 结构体标签而不是 yaml 标签，二进制里 strictmode 出现 0 次。
      # 公开 Issue #154 正文那条相反的推导已在该 Issue 中更正。
      # 这个取值的行为差异已经真机观测到（公开 Issue #182）：握手目标不说 TLS 1.3
      # 时，严格模式开着的监听器拒绝承载代理、退化成把连接原样转给握手目标
      # （日志 [ShadowTLS] TLS 1.3 is not supported, will copy bidirectional），
      # 关着时照常代理；握手目标说 TLS 1.3 时两种取值都照常代理。因此写对这个键
      # 不只是「配置能加载」。反过来也成立：握手目标哪天不再支持 TLS 1.3，严格
      # 模式下这些入口会整体不通，而配置校验与启动日志都不会提前提示。
      # udp 显式写出而不是依赖默认值：这里不是「重申默认值的虚假安全感」，
      # 因为它有可观测断言把守——监听套接字里 UDP 在不在是能直接看到的。
      SB_JQ_ST_PASSWORD="$st_password" SB_JQ_SS_PASSWORD="$ss_password" jq -n \
        --arg name "$name" --argjson port "$port" --arg method "$method" \
        --arg hs_dest "${shadowtls_sni}:${HANDSHAKE_PORT}" \
        --argjson strict "$SHADOWTLS_STRICT_MODE" \
        '[{"name":("st-" + $name),"type":"shadowsocks","listen":"::","port":$port,
           "cipher":$method,"password":$ENV.SB_JQ_SS_PASSWORD,"udp":true,
           "shadow-tls":{"enable":true,"version":3,
                         "users":[{"name":$name,"password":$ENV.SB_JQ_ST_PASSWORD}],
                         "handshake":{"dest":$hs_dest},
                         "strict-mode":$strict}}]'
      ;;
    *) kernel_unknown ;;
  esac
}

# ============================================================
# ShadowTLS 握手目标的 TLS 1.3 预检
# ============================================================
# 严格模式的行为是实测出来的（公开 Issue #182）：握手目标不支持 TLS 1.3 时，开着
# 严格模式的监听器拒绝承载代理，退化成把连接原样转给握手目标。反过来读就是这条
# 预检存在的理由——握手目标哪天不再支持 TLS 1.3，这台机器上所有 ShadowTLS 入口
# 会整体不通，而配置校验、启动日志与既有审计都不会提前提示，现象只是「连不上」
# （公开 Issue #194）。
#
# 结果分四类，因为处置不同：
#   tls13        握手目标支持 TLS 1.3
#   tls-older    说 TLS，但握不出 1.3 —— 明确是问题
#   not-tls      TCP 通，但那个端口上根本不是 TLS —— 明确是问题
#   unreachable  连 TCP 都连不上，或者本机没有 timeout 命令不敢做兜底判断
#   invalid      域名或端口本身不合法
# 把 unreachable 单独分出来是刻意的：网络抖动一次就拒绝改配置、或者把检查刷红，
# 是标准的「狼来了」，而它会自愈。
#
# 判定看协商出来的版本而不是 openssl 的退出码：s_client 在证书验证失败时也会以
# 非零退出，而「这个域名说不说 TLS 1.3」与证书是否可信无关。openssl 默认就会尽量
# 协商最高版本，因此一次握手足以回答这个问题。
probe_handshake_tls13() {
  local host="$1" port="$2" output="" version
  # 调用点传进来的都是校验过的域名与端口。这里再挡一次：下面 /dev/tcp 的重定向词
  # 会经历参数展开，不该把没校验过的东西放进去。
  [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$port" =~ ^[0-9]+$ ]] || {
    printf 'invalid\n'
    return 0
  }
  if command -v timeout >/dev/null 2>&1; then
    output="$(timeout 10 openssl s_client -connect "$host:$port" -servername "$host" -brief </dev/null 2>&1)" || true
  else
    output="$(openssl s_client -connect "$host:$port" -servername "$host" -brief </dev/null 2>&1)" || true
  fi
  version="$(sed -n 's/^Protocol version: //p' <<<"$output" | head -n1)"
  case "$version" in
    TLSv1.3) printf 'tls13\n'; return 0;;
    TLS*) printf 'tls-older\n'; return 0;;
  esac
  # 握不出 TLS 时还要分清「那个端口上不是 TLS」与「根本连不上」。没有 timeout
  # 命令就不做这一步：/dev/tcp 没有自带超时，宁可报成只提示的 unreachable，
  # 也不冒把菜单挂住的风险。
  if command -v timeout >/dev/null 2>&1 && timeout 5 bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$host" "$port" 2>/dev/null; then
    printf 'not-tls\n'
  else
    printf 'unreachable\n'
  fi
}

# 这条预检只对 mihomo 做。sing-box 的 strict_mode 行为本项目没有实测过，而项目
# 方向是逐步放弃 sing-box（公开 Issue #172），不再为它新加护栏——它那一侧保持
# 一字不变。另外两个条件同样是必要的：严格模式关着时握手目标不支持 TLS 1.3
# 并不会让入口不通（公开 Issue #182 的对照格证明了这一点），而一台没有旧版
# ShadowTLS 用户的机器上这条检查恒真，报了也没有人要处理。
shadowtls_handshake_probe_applies() {
  local total
  case "$PROXY_KERNEL" in
    mihomo) ;;
    singbox) return 1;;
    *) kernel_unknown;;
  esac
  [[ "${SHADOWTLS_STRICT_MODE:-true}" == true ]] || return 1
  total="$(count_protocol_sni_users ss2022)" || return 1
  [[ "$total" =~ ^[0-9]+$ ]] || return 1
  ((total > 0))
}

kernel_entries_ss2022_direct() {
  local name="$1" port="$2" ss_password="$3" method="$4" entry_name="${5:-ss-$1}"
  case "$PROXY_KERNEL" in
    singbox)
      SB_JQ_SS_PASSWORD="$ss_password" jq -n \
        --arg tag "$entry_name" --argjson port "$port" --arg method "$method" \
        '[{"type":"shadowsocks","tag":$tag,"listen":"::","listen_port":$port,
           "method":$method,"password":$ENV.SB_JQ_SS_PASSWORD}]'
      ;;
    mihomo)
      SB_JQ_SS_PASSWORD="$ss_password" jq -n \
        --arg name "$entry_name" --argjson port "$port" --arg method "$method" \
        '[{"name":$name,"type":"shadowsocks","listen":"::","port":$port,
           "cipher":$method,"password":$ENV.SB_JQ_SS_PASSWORD,"udp":true}]'
      ;;
    *) kernel_unknown ;;
  esac
}

kernel_entries_anytls() {
  local name="$1" port="$2" password="$3"
  case "$PROXY_KERNEL" in
    singbox)
      SB_JQ_PASSWORD="$password" jq -n \
        --arg name "$name" --argjson port "$port" \
        --arg cert_path "$ANYTLS_CERT_FILE" --arg key_path "$ANYTLS_KEY_FILE" \
        '[{"type":"anytls","tag":("anytls-" + $name),"listen":"::","listen_port":$port,
           "users":[{"name":$name,"password":$ENV.SB_JQ_PASSWORD}],
           "tls":{"enabled":true,"certificate_path":$cert_path,"key_path":$key_path}}]'
      ;;
    mihomo)
      # mihomo 的 users 是映射（用户名 → 密码），不是数组；证书字段名也不同。
      # 证书必须落在 systemd 单元 SAFE_PATHS 之内，否则监听器起不来，
      # 而 mihomo -t 完全测不出这个问题（公开 Issue #154）。
      SB_JQ_PASSWORD="$password" jq -n \
        --arg name "$name" --argjson port "$port" \
        --arg cert_path "$ANYTLS_CERT_FILE" --arg key_path "$ANYTLS_KEY_FILE" \
        '[{"name":("anytls-" + $name),"type":"anytls","listen":"::","port":$port,
           "users":{($name):$ENV.SB_JQ_PASSWORD},
           "certificate":$cert_path,"private-key":$key_path}]'
      ;;
    *) kernel_unknown ;;
  esac
}

# ============================================================
# 分流的生成：上游出口、规则集与路由在当前内核下的形状
# ============================================================
# 与用户入口那一组同理，**条目数量随内核不同**，调用点不得假设：
# sing-box 的 SS2022 + ShadowTLS 上游需要两个出站（shadowsocks 出站
# 加一个 detour 指向的 shadowtls 传输），mihomo 一个 proxy 就够——
# ShadowTLS 在 mihomo 客户端一侧是 shadowsocks 的插件而不是独立对象。
#
# 涉密内容一律经环境变量传给 jq，不进命令行参数。

kernel_split_outbounds() {
  local name="$1" upstream="$2" out_tag="$3" transport_tag="$4" protocol
  protocol="$(jq -r '.protocol' <<<"$upstream")" || return 1
  case "$PROXY_KERNEL" in
    singbox)
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
      ;;
    mihomo)
      # 字段名取自二进制里的 proxy 结构体标签，不猜也不只信文档；
      # 插件参数走另一套 obfs 标签（公开 Issue #186）。每个布尔与数值字段
      # 都用「塞非法值必须被拒绝、键名写错反而通过」这一对断言确认过。
      #
      # udp 按上游真实承载能力写，不一律写 true：ShadowTLS 只承载 TCP，
      # sing-box 侧那条 detour 到 shadowtls 的出站同样带不了 UDP。
      # 写成 true 等于给出一个上游根本不提供的承诺。
      case "$protocol" in
        anytls)
          SB_JQ_UPSTREAM="$upstream" jq -cn --arg name "$out_tag" '($ENV.SB_JQ_UPSTREAM | fromjson) as $u | [{name:$name,type:"anytls",server:$u.server,port:$u.server_port,password:$u.password,sni:$u.sni,"skip-cert-verify":$u.insecure,udp:true}]'
          ;;
        shadowsocks)
          SB_JQ_UPSTREAM="$upstream" jq -cn --arg name "$out_tag" '($ENV.SB_JQ_UPSTREAM | fromjson) as $u | [{name:$name,type:"ss",server:$u.server,port:$u.server_port,cipher:$u.method,password:$u.password,udp:true}]'
          ;;
        ss_shadowtls)
          SB_JQ_UPSTREAM="$upstream" jq -cn --arg name "$out_tag" '($ENV.SB_JQ_UPSTREAM | fromjson) as $u | [{name:$name,type:"ss",server:$u.server,port:$u.server_port,cipher:$u.method,password:$u.ss_password,udp:false,
            plugin:"shadow-tls","plugin-opts":{host:$u.sni,password:$u.shadowtls_password,version:3,"skip-cert-verify":$u.insecure}}]'
          ;;
        *) die "不支持的上游协议：$protocol";;
      esac
      ;;
    *) kernel_unknown ;;
  esac
}

# 上游出口在运行配置里所处的容器。sing-box 放在 .outbounds[] 并用 .tag 标识，
# mihomo 放在 .proxies[] 并用 .name 标识。标识字段与用户入口那一组同一个键名，
# 因此直接复用 kernel_managed_key，不再单列一个函数。
kernel_split_outbound_container() {
  case "$PROXY_KERNEL" in
    singbox) printf 'outbounds' ;;
    mihomo) printf 'proxies' ;;
    *) kernel_unknown ;;
  esac
}

# 规则集来源在状态里的字段名。
# sing-box 存远程下载地址（url），mihomo 存使用者自己那个本地块状 yaml 文件的
# 路径（rule_file）。两个内核的规则集格式不通用，同一个字段装两种东西
# 会让「这是地址还是路径」变成读代码时才知道的事。
# 读取一律写成 (.url // .rule_file // "")：两个键在同一台机器上不会同时存在。
kernel_rule_source_key() {
  case "$PROXY_KERNEL" in
    singbox) printf 'url' ;;
    mihomo) printf 'rule_file' ;;
    *) kernel_unknown ;;
  esac
}

# 一条规则集在当前内核下的运行配置条目。
# sing-box 放在 route.rule_set[] 里，是带 tag 的数组元素；
# mihomo 放在 rule-providers{} 里，是以名字为键的对象成员。
# 因此这里统一返回 {tag: ..., entry: {...}}，由各自的渲染函数决定怎么摆。
kernel_split_rule_set_entry() {
  local tag="$1" source="$2" behavior="$3" rule_url="${4:-}" format
  case "$PROXY_KERNEL" in
    singbox)
      format="$(split_rule_format "$source")" || return 1
      jq -cn --arg tag "$tag" --arg format "$format" --arg url "$source" \
        '{tag:$tag,entry:{type:"remote",tag:$tag,format:$format,url:$url,download_detour:"direct",update_interval:"24h"}}'
      ;;
    mihomo)
      # format 固定 yaml：使用者贴的是社区的块状 yaml 片段。
      # behavior 必须与文件内容相符，而 mihomo 在这一点上是**静默**的——
      # 把完整规则行按域名列表读，一条警告都没有，规则就是不生效（公开 Issue #186）。
      # 因此 behavior 由使用者明确选择，并由管理器读文件核对，不靠内核报错。
      # 写绝对路径。状态里存的是文件名，而 mihomo 会把相对路径按**工作目录**
      # 解析，那是 /var/lib/mihomo，不是规则目录——写相对路径会指到一个
      # 根本不存在的文件上，而且服务照样起得来，只在日志里留一行 error。
      # 远程来源写 type:http，mihomo 自己下载并按 interval 更新（公开 Issue #218）；
      # path 仍然是规则目录里那个文件，它既是缓存也是取不到时的兜底。
      # 本机来源保持原样。两种都写绝对路径，理由同上。
      if [[ -n "$rule_url" ]]; then
        jq -cn --arg tag "$tag" --arg path "$(mihomo_rule_file_path "$source")" \
          --arg behavior "$behavior" --arg url "$rule_url" \
          --argjson interval "$REMOTE_RULE_SET_UPDATE_INTERVAL" \
          '{tag:$tag,entry:{type:"http",behavior:$behavior,format:"yaml",url:$url,path:$path,interval:$interval}}'
      else
        jq -cn --arg tag "$tag" --arg path "$(mihomo_rule_file_path "$source")" --arg behavior "$behavior" \
          '{tag:$tag,entry:{type:"file",behavior:$behavior,format:"yaml",path:$path}}'
      fi
      ;;
    *) kernel_unknown ;;
  esac
}

# 一个 SS2022 + ShadowTLS 用户在当前内核下会产生哪几个托管条目名。
# 用户专属分流要按入口名限定，而这一项两个内核条目数不同：
# sing-box 三个（ShadowTLS 入站、detour 的 shadowsocks、单独承载 UDP 的那个），
# mihomo 一个监听器同时承载 TCP 与 UDP。
# 返回前缀数组，调用点拼上用户名——名字本身两个内核共用。
kernel_shadowtls_entry_prefixes() {
  case "$PROXY_KERNEL" in
    singbox) printf '["st-","ss-","ss-udp-"]' ;;
    mihomo) printf '["st-"]' ;;
    *) kernel_unknown ;;
  esac
}

# 托管分流在 mihomo 的 rules 里所用的 sub-rule 名。
# 管理器在 rules 顶层只留一条派发，其余整块关在这个 sub-rule 里，
# 使用者手工加在 rules 里的东西因此原样保留（公开 Issue #186）。
# 名字与分流规则集标签的前缀 managed-split- 差一个连字符，不可能相撞：
# 分流名至少一个字符，managed-split-<名字> 永远带那个连字符。
MIHOMO_MANAGED_SUB_RULE="managed-splits"

# 一个用户端点的托管条目除了「在不在」之外还要对哪些字段。
#
# 「在不在」两个内核完全一样，由审计里共用的那段程序负责；这里只写形状特有的
# 那一部分，两个内核各一份，与用户入口的生成放在同一个模块里——生成改了形状，
# 审计的断言就得跟着改，隔着模块放迟早只改一处。
#
# 两段都只用到审计程序里先定义好的 issue()，以及 $config 和 $strict_mode 这两个变量。
SINGBOX_USER_ENTRY_SHAPE_DEF='
  def sbm_entry_shape_issues($name; $protocol; $transport; $port; $status; $has_legacy; $expected):
    (if $protocol == "ss2022" and $transport == "shadowtls" and $status == "active" and
        any($config.inbounds[]?; .tag == ("ss-udp-" + $name)) and
        (any($config.inbounds[]?;
          .tag == ("ss-udp-" + $name) and .type == "shadowsocks" and .network == "udp" and .listen_port == $port) | not)
     then issue(true; "[可自动修复] 用户 \($name) 的 UDP 连接配置不正确") else empty end),
    (if $protocol == "ss2022" and $transport == "direct" and $status == "active" and
        (any($config.inbounds[]?;
          .tag == $expected and .type == "shadowsocks" and .listen_port == $port and ((.network // "") == "")) | not)
     then issue(true; "[可自动修复] 用户 \($name) 的原生 SS2022 连接配置不正确") else empty end),
    (if $protocol == "ss2022" and $transport == "direct" and ($has_legacy | not) and
        any($config.inbounds[]?; .tag == ("st-" + $name) or .tag == ("ss-udp-" + $name))
     then issue(true; "[可自动修复] 用户 \($name) 的原生 SS2022 仍有旧版 ShadowTLS 连接残留") else empty end);'

# mihomo 侧的对应物。差别来自 2c 定下的形状：
# 一个监听器同时承载 TCP 与 UDP（因此没有单独的 UDP 条目，改看 udp 字段），
# ShadowTLS 是挂在 shadowsocks 监听器上的子结构而不是独立入站。
#
# strict-mode 这一条 sing-box 侧今天没有对应检查（它的 strict_mode 同样没查）。
# mihomo 侧加它的理由是这个键**恰恰是 mihomo 会静默丢弃的那一类**——键名写错
# 不报错、严格模式悄悄关掉（公开 Issue #154 的更正评论）。运行配置里它是不是
# 管理配置里那个值，是审计能便宜地回答的问题。
MIHOMO_USER_ENTRY_SHAPE_DEF='
  def sbm_entry_shape_issues($name; $protocol; $transport; $port; $status; $has_legacy; $expected):
    (first($config.listeners[]? | select(.name == ("st-" + $name))) // null) as $shadowtls |
    (if $protocol == "ss2022" and $transport == "shadowtls" and $status == "active" and
        ($shadowtls != null) and
        (($shadowtls | .type == "shadowsocks" and .port == $port and .udp == true and
          ((.["shadow-tls"].enable // false) == true) and
          ((.["shadow-tls"].version // 0) == 3)) | not)
     then issue(true; "[可自动修复] 用户 \($name) 的 SS2022 + ShadowTLS 连接配置不正确") else empty end),
    (if $protocol == "ss2022" and $transport == "shadowtls" and $status == "active" and
        ($shadowtls != null) and
        (($shadowtls | .["shadow-tls"]["strict-mode"]) != $strict_mode)
     then issue(true; "[可自动修复] 用户 \($name) 的 ShadowTLS 严格模式与管理配置不一致") else empty end),
    (if $protocol == "ss2022" and $transport == "direct" and $status == "active" and
        (any($config.listeners[]?;
          .name == $expected and .type == "shadowsocks" and .port == $port and .udp == true and
          (has("shadow-tls") | not)) | not)
     then issue(true; "[可自动修复] 用户 \($name) 的原生 SS2022 连接配置不正确") else empty end),
    (if $protocol == "ss2022" and $transport == "direct" and ($has_legacy | not) and
        ($shadowtls != null)
     then issue(true; "[可自动修复] 用户 \($name) 的原生 SS2022 仍有旧版 ShadowTLS 连接残留") else empty end);'

kernel_user_entry_shape_def() {
  case "$PROXY_KERNEL" in
    singbox) printf '%s' "$SINGBOX_USER_ENTRY_SHAPE_DEF" ;;
    mihomo) printf '%s' "$MIHOMO_USER_ENTRY_SHAPE_DEF" ;;
    *) kernel_unknown ;;
  esac
}

# 拿运行配置与「我们写进去的样子」做比对之前，要先做的规范化。
#
# sing-box 的 Listable 字段只有一个元素时，会被 `format` 规范化成裸标量：
#   写入的 "inbound":["anytls-share"]  →  读回的 "inbound":"anytls-share"
# 直接拿它和期望的标签数组做集合运算，jq 会因类型不符而报错
# （array and string cannot be subtracted）。而这些比对的调用点写成
# `if ! jq ...` 或 `jq ... || return 1`，jq 崩溃会被当成「配置不符」，
# 于是既误报「分流尚未覆盖用户的全部连接」，又会触发一次不必要的配置重建与
# sing-box 重启。字符串上的 `.inbound[]?` 还会安静地什么都不返回，让
# 「已停用用户的规则仍在生效」这类检查静默失效（v4.25.11 修的正是这个）。
#
# **mihomo 侧不存在这件事**：这一支的规范化本身就是 `jq .`，写进去什么形状
# 读回来就是什么形状，这条管线里没有会改写形状的环节。因此它只做类型校验。
# 照搬 sing-box 那一段过去没有意义——mihomo 的配置里根本没有 route.rules。
#
# 整段放在单引号常量里，调用处只做一次普通变量展开：内联拼接会产生转义双引号，
# 而 tests/check-shell-call-targets.py 的分词器遇到那种写法会静默停止检查
# 文件剩余部分（见公开 Issue #102）。
SINGBOX_CONFIG_NORMALISE_PROGRAM='
  if type != "object" then error("运行配置不是 JSON 对象") else . end
  | if (.route.rules? | type) == "array" then
      .route.rules |= map(
        if has("inbound") and ((.inbound | type) != "array") then .inbound = [.inbound] else . end)
    else . end'

MIHOMO_CONFIG_NORMALISE_PROGRAM='
  if type != "object" then error("运行配置不是 JSON 对象") else . end'

kernel_config_normalise_program() {
  case "$PROXY_KERNEL" in
    singbox) printf '%s' "$SINGBOX_CONFIG_NORMALISE_PROGRAM" ;;
    mihomo) printf '%s' "$MIHOMO_CONFIG_NORMALISE_PROGRAM" ;;
    *) kernel_unknown ;;
  esac
}

# 骨架反推出的缺项里，期望值为空容器的那些要不要报。
#
# sing-box 的 `format` **会把空数组整个省略**，读回来分不清「没有这个键」和
# 「这个键是空数组」，而对内核而言两者语义相同——不排除就会在没有分流的
# 服务器上把 route.rules 与 route.rule_set 误报成缺项（v4.25.13 修的正是这个）。
#
# **mihomo 侧必须报。** 它的规范化是 `jq .`，空数组原样在，读回来分得清；
# 照搬那条排除的后果是：一台丢了 listeners、proxies 或 rules 的 mihomo 机器，
# 「服务与配置检查」会说一切正常。这一条有实测与对照（公开 Issue #189）。
kernel_skeleton_skips_empty_containers() {
  case "$PROXY_KERNEL" in
    singbox) return 0 ;;
    mihomo) return 1 ;;
    *) kernel_unknown ;;
  esac
}

# 判断托管 sub-rule 里的一行是什么。行的形状只有两种，都由
# kernel_render_split_plan 生成：
#   <匹配条件>,<出口>
#   AND,((<匹配条件>),(IN-NAME,...)),<出口>
# 生成与识别必须一起改，因此这几段判断与渲染函数放在同一个模块里，
# 由分流模块与审计以变量展开的方式注入自己的 jq 程序。
# tests/test-static.sh 据此禁止其它模块自己拼这套规则语法。
#
# **匹配条件**有两种来源（公开 Issue #219 把第二种加了进来）：
#   规则集    RULE-SET,<规则集标签>
#   geo 类别  GEOSITE,openai            单个类别
#             OR,((GEOSITE,a),(GEOIP,us))  多个类别
# 认行的办法对两者是同一套：条件要么整个摆在行首、后面跟一个逗号，要么整个摆在
# AND 的第一个括号里。因此这里统一按「条件字符串」判断，而不是按规则集标签；
# geo 来源根本没有规则集标签可用，按标签判断就没法认出它的行。
#
# **两处都必须连着分隔符一起比，不能只用 contains。** 只判「行里出现过这个条件」
# 时，一条 OR,((GEOSITE,a),(GEOIP,us)) 的行会被条件 GEOSITE,a 认领——那条行属于
# 另一条分流。后果是删一条分流会顺手删掉别人的行（重建能补回来），以及审计把
# 「已停用的分流仍在生效」报成恒真（那一条自动修复也修不掉，只会一直刷红）。
# 顺带也挡住了标签的前缀重名：条件 RULE-SET,r 不会认领 RULE-SET,rr 的行。
#
# 四个判断各自回答一个问题：这一行属不属于某条分流（删除时用）、
# 是不是「某条件 → 某出口」（审计「配置完不完整」用）、是不是不限入口的
# 那一种（审计已停用的全局分流用）、有没有覆盖到某几个入口名（审计
# 「有没有覆盖用户的全部连接」与「已停用用户是否仍在生效」用）。
MIHOMO_SPLIT_RULE_DEFS='
  def sbm_match_cond($rule_set; $geo):
    if ($geo | length) > 0 then
      (if ($geo | length) == 1 then $geo[0]
       else "OR,(" + ([$geo[] | "(" + . + ")"] | join(",")) + ")" end)
    else "RULE-SET," + $rule_set end;
  def sbm_cond_is_rule_set($cond): ($cond | startswith("RULE-SET,"));
  def sbm_line_owned_by($line; $conds):
    ($line | type) == "string" and
    any($conds[]; . as $cond | ($cond | length) > 0 and
      (($line | startswith($cond + ",")) or
       ($line | startswith("AND,((" + $cond + "),("))));
  def sbm_line_routes($line; $cond; $out):
    sbm_line_owned_by($line; [$cond]) and ($line | endswith("," + $out));
  def sbm_line_scope_all($line; $cond; $out):
    ($line | type) == "string" and $line == ($cond + "," + $out);
  def sbm_line_covers($line; $names):
    ($line | type) == "string" and
    all($names[]; . as $entry | $line | contains("(IN-NAME," + $entry + ")"));
  def sbm_line_touches($line; $cond; $names):
    sbm_line_owned_by($line; [$cond]) and
    any($names[]; . as $entry | $line | contains("(IN-NAME," + $entry + ")"));'

# mihomo 的 geo 设置（公开 Issue #219）。分流用到 GeoSite／GeoIP 类别时，这四个键
# 决定用哪份数据、更不更新、从哪里下载。三个取值都**不是重申默认值**：mihomo 默认
# geodata-mode 是假（GeoIP 用 metadb 而不是 v2ray 的 GeoIP.dat）、默认不自动更新。
#
# **只在这台机器真的有 geo 规则时才写。** 实测（v1.19.30）：三个键写上去而配置里
# 一条 geo 规则都没有时，不会下载任何数据库——但每次启动都会留下一行 error 级日志
# 「[GEO] Get GEO database update time error: stat .../GeoSite.dat: no such file or
# directory」。一台从来不用 geo 的机器不该在日志里天天报一条假错。对照也做了：
# 不写这几个键时，同一份配置连这行日志都没有。
#
# 判断依据是**配置里有没有 geo 规则**，而不是「管理器有没有 geo 分流」：使用者
# 自己写在顶层 rules 里的 GEOSITE 规则同样需要这几个键，按前者判断才不会把
# 他的设置删掉。反过来，一条 geo 规则都不剩时这四个键由管理器删掉——它们是
# 管理器放进去的，留着只剩那行假错。
#
# geox-url 由「geo 数据源」设置项决定：留空就删掉这个键，用 mihomo 自带的源。
# 写成 def 而不是一整段过滤器，是为了让调用点按既有写法拼：变量在前、单引号常量
# 在后（tests/check-shell-call-targets.py 的分词器只认这一种，见公开 Issue #102）。
# 需要 --argjson geox。
MIHOMO_GEO_SETTINGS_PROGRAM='
  def sbm_apply_geo_settings:
    def sbm_uses_geo:
      [(.rules // [])[], ((.["sub-rules"] // {}) | .[] | .[]?)] |
      any(.[]?; (type == "string") and test("(^|[(,])GEO(SITE|IP),"));
    if sbm_uses_geo then
      (if has("geodata-mode") then . else .["geodata-mode"] = true end) |
      (if has("geo-auto-update") then . else .["geo-auto-update"] = true end) |
      (if has("geo-update-interval") then . else .["geo-update-interval"] = 24 end) |
      (if ($geox | length) == 0 then del(.["geox-url"]) else .["geox-url"] = $geox end)
    else
      del(.["geodata-mode"]) | del(.["geo-auto-update"]) |
      del(.["geo-update-interval"]) | del(.["geox-url"])
    end;'

# 派发条目。条件写成覆盖整个端口空间的 DST-PORT，语义是「所有连接」：
# MATCH 不能当逻辑规则的条件（mihomo 明确拒绝 SUB-RULE,(MATCH),名字），
# 而按托管监听器的 IN-NAME 派发会让语义与 sing-box 不一致——sing-box 的
# 「全部用户」分流本来就不限定入站，使用者手工加的入站也一样受它管。
# 已实测这条派发确实触发（sub-rule 内 REJECT 时连接被拦下），
# 并有反面对照（条件换成不存在的 IN-NAME 时连接正常放行）。
MIHOMO_SPLIT_DISPATCH_RULE="SUB-RULE,(DST-PORT,0-65535),${MIHOMO_MANAGED_SUB_RULE}"

# 把与内核无关的分流计划渲染成当前内核的运行配置片段。
#
# 计划本身（哪条规则集配哪个出口、限定哪些入口）两个内核完全一样，
# 差别只在最终长什么样：sing-box 的路由规则是对象数组，mihomo 是字符串数组，
# 规则集容器一个是带 tag 的数组、另一个是以名字为键的对象。
# 因此计划的构造留在分流模块里只写一遍，形状差异集中在这里。
#
# 输入：{outbound_groups:[{tag,objects}],rule_sets:[{tag,entry}],
#        routes:[{rule_set,geo,outbound,scope_all,users,inbound}]}
# 输出（sing-box）：{outbounds:[...],rule_sets:[...],rules:[...]}
# 输出（mihomo）：  {proxies:[...],rule_providers:{...},sub_rules:[...]}
kernel_render_split_plan() {
  local plan="$1"
  case "$PROXY_KERNEL" in
    singbox)
      # geo 类别只做 mihomo 侧（公开 Issue #219）。这里明确报错而不是把它当成
      # 空条件渲染出去：静静少一个条件的路由会把**全部流量**送进上游出口。
      # 保存那一刻就已经挡住了 sing-box 上的 geo 来源，这条是第二道。
      jq -c '
        if any(.routes[]?; ((.geo // []) | length) > 0) then
          error("sing-box 不支持 GeoSite／GeoIP 类别分流")
        else . end |
        {
        outbounds:[.outbound_groups[].objects[]],
        rule_sets:[.rule_sets[].entry],
        rules:[.routes[] | ({rule_set:.rule_set,action:"route",outbound:.outbound} +
          (if .scope_all then {} else {inbound:.inbound} end))]
      }' <<<"$plan"
      ;;
    mihomo)
      # mihomo 的路由规则是字符串，名字直接拼进去。因此这里先挡一道：
      # 名字里出现逗号或括号会把一条规则拼成另一条，而 mihomo 只会说
      # 「规则类型不支持」，看不出是名字带进去的。当前的名字格式不可能出现
      # 这些字符，这条断言是为了将来改名字格式时当场变红而不是悄悄拼错。
      # 入口为空的用户专属条目直接丢掉：它谁都作用不到，
      # 而 OR,(()) 这种空集合写法 mihomo 不接受。
      jq -c "$MIHOMO_SPLIT_RULE_DEFS"'
        def guard($text): if ($text | test("[,()]")) then
            error("名字里不能出现逗号或括号，否则会拼坏 mihomo 规则：" + $text)
          else $text end;
        def in_name($names):
          if ($names | length) == 1 then "(IN-NAME," + guard($names[0]) + ")"
          else "(OR,(" + ([$names[] | "(IN-NAME," + guard(.) + ")"] | join(",")) + "))" end;
        # geo 类别本身就带一个逗号（GEOSITE,openai），过不了上面那道 guard，
        # 也不该过——它要挡的是名字里混进分隔符。这里换成按整体写法卡死：
        # 只允许 GEOSITE／GEOIP 加一个不含逗号括号的类别名，多一个逗号
        # （例如 no-resolve 后缀）或任何括号都当场报错，而不是拼出一条
        # mihomo 只会说「规则类型不支持」的规则。
        # 字符集里的 `!` 是必需的：GeoSite 用 `!cn` 后缀表示「排除中国大陆」，
        # 例如 category-ai-!cn、geolocation-!cn。实测 1546 个类别名里出现过的
        # 非字母数字字符只有 `-`（317 次）与 `!`（11 次）。
        def guard_geo($text):
          if ($text | test("^(GEOSITE|GEOIP),[A-Za-z0-9_.:@!-]+$")) then $text
          else error("geo 类别只能写成 GEOSITE,<类别> 或 GEOIP,<类别>：" + $text) end;
        {
          proxies:[.outbound_groups[].objects[]],
          rule_providers:([.rule_sets[] | {key:guard(.tag),value:.entry}] | from_entries),
          sub_rules:[.routes[] |
            sbm_match_cond(guard(.rule_set // ""); [(.geo // [])[] | guard_geo(.)]) as $cond |
            if .scope_all then
              $cond + "," + guard(.outbound)
            elif ((.inbound // []) | length) == 0 then empty
            else
              "AND,((" + $cond + ")," + in_name(.inbound) + ")," + guard(.outbound)
            end]
        }' <<<"$plan"
      ;;
    *) kernel_unknown ;;
  esac
}

kernel_skeleton_ensure_program() {
  case "$PROXY_KERNEL" in
    singbox) printf '%s' "$SINGBOX_SKELETON_ENSURE_PROGRAM" ;;
    mihomo) printf '%s' "$MIHOMO_SKELETON_ENSURE_PROGRAM" ;;
    *) kernel_unknown ;;
  esac
}

# 读取指定内核可执行文件的版本号。版本号的位置是内核特有的输出约定，
# 因此解析放在适配层；文件不可执行时返回空字符串而不是报错，
# 调用点据此显示「未安装」或「未保存」。
# 两个内核都把版本号放在第 1 行第 3 列，但子命令不同（sing-box 用 version，
# mihomo 用 -v），且 mihomo 带 v 前缀，这里去掉以便与 Release 标签去 v 后的写法比较。
# 顺带一层保护：微架构不匹配的 mihomo 二进制会拒绝运行并以退出码 1 结束，
# 版本输出为空，安装流程中的「解压后版本与预期一致」比对因此当场失败。
kernel_binary_version() {
  [[ -x "$1" ]] || return 0
  case "$PROXY_KERNEL" in
    singbox) "$1" version 2>/dev/null | awk 'NR==1 {print $3}' || true ;;
    mihomo) "$1" -v 2>/dev/null | awk 'NR==1 {sub(/^v/, "", $3); print $3}' || true ;;
    *) kernel_unknown ;;
  esac
}

# 内核服务控制。刻意拆成三个动作而不是合成一个重启流程：
# 两个调用点对失败的处理不同——恢复备份时要逐步记录严重错误，
# 用户操作时直接返回由上层回滚——合成一个会抹掉这个差别。
kernel_service_reset_failed() {
  local service
  service="$(kernel_service_name)" || return 1
  systemctl reset-failed "$service" 2>/dev/null || true
}

kernel_service_restart() {
  local service
  service="$(kernel_service_name)" || return 1
  systemctl restart "$service" || return 1
}

kernel_service_is_active() {
  local service
  service="$(kernel_service_name)" || return 1
  systemctl is-active --quiet "$service"
}

# 规则集编译与反编译。这两个子命令是 sing-box 特有的，mihomo 的规则集格式与
# .srs 不通用，需要另行决定来源（第二步 2d），因此这里明确报错而不是给出等价物。
kernel_rule_set_compile() {
  case "$PROXY_KERNEL" in
    singbox) "$1" rule-set compile --output "$3" "$2" >/dev/null || return 1 ;;
    mihomo) kernel_unsupported '编译规则集' ;;
    *) kernel_unknown ;;
  esac
}

kernel_rule_set_decompile() {
  case "$PROXY_KERNEL" in
    singbox) "$1" rule-set decompile --output "$3" "$2" >/dev/null || return 1 ;;
    mihomo) kernel_unsupported '反编译规则集' ;;
    *) kernel_unknown ;;
  esac
}

# 当前内核的核心文件：配置、可执行文件、systemd 单元。
# 环境分类与完整性判断用这一组——它们问的是「这台机器的内核装好了没有」，
# 因此必须只看当前内核：一台 mihomo 机器缺少 sing-box 不是损坏。
kernel_core_paths() {
  case "$PROXY_KERNEL" in
    singbox)
      cat <<'EOF'
/etc/sing-box/config.json
/usr/local/bin/sing-box
/etc/systemd/system/sing-box.service
EOF
      ;;
    mihomo)
      cat <<'EOF'
/etc/mihomo/config.json
/usr/local/bin/mihomo
/etc/systemd/system/mihomo.service
EOF
      ;;
    *) kernel_unknown ;;
  esac
}

# 两个内核的全部部署路径。备份、卸载与事务白名单用这一组——
# 它们问的是「哪些路径属于本项目」，与这台机器当前用哪个内核无关。
# 取并集而不是按内核分派：不存在的路径在这三处都被跳过，多列几条没有代价；
# 而按内核分派会让「这台机器上还留着另一个内核的残留」变成清不掉的东西。
all_kernel_deployment_paths() {
  cat <<'EOF'
/etc/sing-box
/var/lib/sing-box
/usr/local/bin/sing-box
/etc/systemd/system/sing-box.service
/etc/systemd/system/multi-user.target.wants/sing-box.service
/etc/mihomo
/var/lib/mihomo
/usr/local/bin/mihomo
/etc/systemd/system/mihomo.service
/etc/systemd/system/multi-user.target.wants/mihomo.service
EOF
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
  local kernel_config kernel_bin kernel_label
  kernel_config="$(kernel_config_path)" || die "无法确认代理内核的配置位置"
  kernel_bin="$(kernel_binary_path)" || die "无法确认代理内核的可执行文件位置"
  kernel_label="$(kernel_display_name)" || die "无法确认代理内核名称"
  [[ -f "$kernel_config" ]] || die "${kernel_label} 配置不存在：$kernel_config"
  [[ -x "$kernel_bin" ]] || die "${kernel_label} 不可执行：$kernel_bin"
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
  unregister_temp_path "$tmp" || return 1
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
    def endpoint_kind:
      if .protocol == "anytls" then "anytls"
      elif .protocol == "ss2022" and .transport == "direct" then "ss2022-direct"
      elif .protocol == "ss2022" and .transport == "shadowtls" then "ss2022-shadowtls"
      else null end;
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
      (.endpoints | type == "array" and length >= 1 and length <= 3) and
      ([.endpoints[] | endpoint_kind] | all(. != null) and length == (unique | length)) and
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
    if ! kernel_normalized_config > "$normalized"; then
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
  if ((schema == 6)); then
    if ! atomic_state_update '.schema_version = 7'; then
      restore_state_backup_atomically "$backup" || die "多入口共存数据升级失败，且无法自动恢复原数据；备份：$backup"
      die "多入口共存数据升级失败，原数据已自动恢复；备份：$backup"
    fi
    schema=7
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
    def endpoint_kind:
      if .protocol == "anytls" then "anytls"
      elif .protocol == "ss2022" and .transport == "direct" then "ss2022-direct"
      elif .protocol == "ss2022" and .transport == "shadowtls" then "ss2022-shadowtls"
      else null end;
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
      (.endpoints | type == "array" and length >= 1 and length <= 3) and
      ([.endpoints[] | endpoint_kind] | all(. != null) and length == (unique | length)) and
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

# geo 数据源的两个地址（公开 Issue #219）。与全局 SNI 那一处同一个写法：
# 只重写自己那两行，其余原样保留；留空表示用 mihomo 自带的源，此时**不写这一行**
# ——写一行 GEOSITE_URL="" 与不写是同一个意思，但少写一行能让配置文件如实反映
# 「这台机器没有自定义过下载源」。
write_geo_source_config() {
  local geosite_url="$1" geoip_url="$2" reason="${3:-update}" tmp backup
  backup="$BACKUP_DIR/sb-user-manager.conf.pre-geo-${reason}-$(date '+%Y%m%d-%H%M%S-%N')"
  cp -a -- "$CONF_FILE" "$backup" || return 1
  tmp="$(mktemp "$(dirname "$CONF_FILE")/.sb-user-manager.conf.XXXXXX")" || return 1
  register_temp_path "$tmp" || return 1
  if ! awk '!/^(GEOSITE_URL|GEOIP_URL)=/' "$CONF_FILE" > "$tmp" ||
     ! { [[ -z "$geosite_url" ]] || printf 'GEOSITE_URL="%s"\n' "$geosite_url" >> "$tmp"; } ||
     ! { [[ -z "$geoip_url" ]] || printf 'GEOIP_URL="%s"\n' "$geoip_url" >> "$tmp"; } ||
     ! chmod 600 "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chown root:root "$tmp" 2>/dev/null || true
  mv -- "$tmp" "$CONF_FILE" || return 1
  sync_transaction_path "$CONF_FILE" || return 1
  GEOSITE_URL="$geosite_url"
  GEOIP_URL="$geoip_url"
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

# 操作事务的回滚材料。备份的必须是**当前内核自己的**运行配置——
# 此前这里写死 SINGBOX_CONFIG，在 mihomo 机器上会去备份一份不存在的
# sing-box 配置，整个操作在第一步就失败（公开 Issue #180）。
# 备份文件名保持 config.json.<戳> 不变：它只是 BACKUP_DIR 里的一个名字，
# 改名会让既有部署里已有的回滚组认不出来。
backup_files() {
  local stamp config_backup state_backup manager_backup runtime_config
  runtime_config="$(kernel_runtime_config_path)" || return 1
  stamp="$(date '+%Y%m%d-%H%M%S-%N').$$"
  config_backup="$BACKUP_DIR/config.json.$stamp"
  state_backup="$BACKUP_DIR/managed-users.json.$stamp"
  manager_backup="$BACKUP_DIR/sb-user-manager.conf.$stamp"
  if ! cp -a -- "$runtime_config" "$config_backup"; then
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
  local stamp="$1" config_source state_source manager_source config_tmp state_tmp previous_state manager_tmp="" runtime_config
  config_source="$BACKUP_DIR/config.json.$stamp"
  state_source="$BACKUP_DIR/managed-users.json.$stamp"
  manager_source="$BACKUP_DIR/sb-user-manager.conf.$stamp"
  if [[ ! -r "$config_source" || ! -r "$state_source" ]]; then
    log "严重错误：事务备份不完整，无法恢复：$stamp"
    return 1
  fi
  runtime_config="$(kernel_runtime_config_path)" || return 1
  config_tmp="$(mktemp "$(dirname "$runtime_config")/.restore-config.XXXXXX")" || return 1
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
  if ! kernel_check_config "$config_tmp"; then
    rm -f -- "$config_tmp" "$state_tmp" "$previous_state" "$manager_tmp"
    log "严重错误：备份中的运行配置校验失败"
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
  if ! mv -- "$config_tmp" "$runtime_config"; then
    if ! mv -- "$previous_state" "$STATE_FILE"; then
      log "严重错误：运行配置恢复失败，且无法还原原用户状态"
    fi
    rm -f -- "$config_tmp" "$state_tmp" "$previous_state" "$manager_tmp"
    log "严重错误：无法从备份恢复运行配置"
    return 1
  fi
  rm -f -- "$previous_state"
  if [[ -n "$manager_tmp" ]]; then
    # 管理配置不作为 shell 脚本执行；文件属性和内容合法性由 load_runtime_config 的白名单解析验证。
    if ! mv -- "$manager_tmp" "$CONF_FILE" || ! load_runtime_config; then
      rm -f -- "$manager_tmp"
      log "严重错误：无法从备份恢复管理配置"
      return 1
    fi
  fi
  if ! kernel_check_config "$runtime_config"; then
    log "严重错误：备份已恢复，但备份配置校验失败"
    return 1
  fi
  kernel_service_reset_failed
  if ! kernel_service_restart; then
    log "严重错误：备份已恢复，但 $(kernel_display_name) 重启失败"
    return 1
  fi
  if ! kernel_service_is_active; then
    log "严重错误：备份已恢复，但 $(kernel_display_name) 未处于 active 状态"
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
    ! chmod 600 "$tmp" || ! sync_transaction_path "$tmp" || ! mv -- "$tmp" "$TRANSACTION_JOURNAL"; then
    rm -f -- "$tmp"
    return 1
  fi
  # mv 成功即表示日志已经生效；目录同步失败只影响掉电后的持久性，不能再当作日志未写入处理
  sync_transaction_path "$TRANSACTION_DIR" ||
    log "提示：恢复记录目录未能同步到磁盘，本次操作仍在保护中"
}

begin_operation_transaction() {
  local operation="$1" nfuse_tmp nfuse_snapshot stamp journal_stamp
  if ((ACTIVE_TRANSACTION_DEPTH > 0)); then
    # 嵌套前确认日志仍然存在且指向本次事务，避免在没有保护的情况下继续修改
    journal_stamp="$(active_operation_backup_stamp 2>/dev/null || true)"
    if [[ -z "$journal_stamp" || "$journal_stamp" != "${ACTIVE_TRANSACTION_STAMP:-}" ]]; then
      printf '错误：本次操作的恢复记录已经丢失或不匹配。为保护现有数据，本次操作已停止。恢复记录：%s\n' "$TRANSACTION_JOURNAL" >&2
      return 1
    fi
    ((ACTIVE_TRANSACTION_DEPTH+=1))
    return 0
  fi
  if [[ -e "$TRANSACTION_JOURNAL" || -L "$TRANSACTION_JOURNAL" ]]; then
    printf '错误：发现上次未完成的操作，而且尚未恢复。为保护现有数据，本次操作已停止。恢复记录：%s\n' "$TRANSACTION_JOURNAL" >&2
    return 1
  fi
  if [[ -e "$ENVIRONMENT_TRANSACTION_JOURNAL" || -L "$ENVIRONMENT_TRANSACTION_JOURNAL" ]]; then
    printf '错误：发现尚未完成的环境操作。为保护现有数据，本次用户或分流操作已停止。恢复记录：%s\n' "$ENVIRONMENT_TRANSACTION_JOURNAL" >&2
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
    if [[ -e "$TRANSACTION_JOURNAL" || -L "$TRANSACTION_JOURNAL" ]]; then
      # 日志一旦写入就必须保留同一 stamp 的备份，否则会留下指向已删备份的孤儿日志
      rm -f -- "$nfuse_tmp"
      printf '错误：本次操作未能开始，但恢复记录已经写入。请重新运行脚本完成自动恢复。恢复记录：%s\n' "$TRANSACTION_JOURNAL" >&2
      return 1
    fi
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
  local current_json managed_names desired_names name account tier limit anchor used port_spec port_id account_exists
  local set_usage_error
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
      account_exists=true
      nfuse set-tier "$name" --tier "$tier" --limit "$limit" --anchor "$anchor" >/dev/null || return 1
      while IFS= read -r port_id; do
        [[ -n "$port_id" ]] || continue
        nfuse port rm "$port_id" >/dev/null || return 1
      done < <(jq -r --arg name "$name" '.[] | select(.name == $name) | .ports[].id' <<<"$current_json")
    else
      account_exists=false
      nfuse add "$name" --tier "$tier" --limit "$limit" --anchor "$anchor" >/dev/null || return 1
    fi
    if [[ "$tier" == c && "$account_exists" == true ]]; then
      # 存活的自用账户不会被重建，用量需显式归零；快照用量由 restore_tier_c_usage_offsets 记入 usage_offset_bytes。
      # Nfuse 是否接受对不限额账户设置用量无法在此确认，被拒绝时退回本函数已有的删除重建路径（重建出来的账户用量本来就是 0）。
      set_usage_error=""
      if ! set_usage_error="$(nfuse set-usage "$name" 0 2>&1 >/dev/null)"; then
        # 保留 Nfuse 的原始错误，管理员据此才能分辨「不支持这个操作」和「Nfuse 临时不可用」
        log "提示：自用用户 ${name} 的流量记录无法直接归零（${set_usage_error:-无错误输出}），改用删除后重建的方式恢复"
        nfuse rm "$name" --cascade >/dev/null || return 1
        # 账户此刻已从流量库删除，重建失败会让它彻底丢失。此处不隐瞒，直接给出可照抄的重建命令，
        # 否则管理员只看到一句「自动恢复失败」，无从知道有个账户需要补回。
        if ! nfuse add "$name" --tier "$tier" --limit "$limit" --anchor "$anchor" >/dev/null; then
          log "严重错误：自用用户 ${name} 已从流量库删除但未能重建。请在排除 Nfuse 故障后手工执行：nfuse add ${name} --tier ${tier} --limit ${limit} --anchor ${anchor}"
          return 1
        fi
      fi
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

# 返回码区分两种性质完全不同的失败，调用方必须分别处理：
#   0 恢复标记已删除
#   1 恢复标记已删除，但目录同步未完成（无害，下次启动不会误判为待恢复）
#   2 恢复标记仍在磁盘上（危险，下次启动会按它自动回滚）
clear_operation_transaction() {
  local rc=0
  # 内存状态必须无条件复位，否则删除成功、同步失败时会留下没有日志保护的空嵌套
  rm -f -- "$TRANSACTION_JOURNAL" || rc=1
  sync_transaction_path "$TRANSACTION_DIR" || rc=1
  [[ ! -e "$TRANSACTION_JOURNAL" && ! -L "$TRANSACTION_JOURNAL" ]] || rc=2
  ACTIVE_TRANSACTION_STAMP=""
  ACTIVE_TRANSACTION_OPERATION=""
  ACTIVE_TRANSACTION_DEPTH=0
  return "$rc"
}

rollback_operation_transaction() {
  local rc="${1:-1}" stamp="${ACTIVE_TRANSACTION_STAMP:-}" operation="${ACTIVE_TRANSACTION_OPERATION:-未知}" failed=false
  if [[ -z "$stamp" && -r "$TRANSACTION_JOURNAL" ]]; then
    validate_transaction_journal || { log "严重错误：事务日志损坏，拒绝自动恢复：$TRANSACTION_JOURNAL"; return 1; }
    stamp="$(jq -r '.backup_stamp' "$TRANSACTION_JOURNAL")"
    operation="$(jq -r '.operation' "$TRANSACTION_JOURNAL")"
  fi
  [[ -n "$stamp" ]] || return "$rc"
  trap - ERR
  clear_signal_rollback
  log "上次操作未正常完成，正在自动恢复修改前的数据：$operation"
  # 前两个恢复动作互不依赖，必须各自执行完，避免前一步失败时留下只回滚了一半的混合状态。
  # 第三步把快照里的自用用量累加进状态文件的 usage_offset_bytes，前提是 restore_backup
  # 已经把状态文件还原到操作前；还原失败时必须跳过，否则每次自动恢复都会重复累加一次。
  restore_nfuse_snapshot "$stamp" || failed=true
  if restore_backup "$stamp"; then
    restore_tier_c_usage_offsets "$stamp" || failed=true
  else
    failed=true
  fi
  if [[ "$failed" == true ]]; then
    log "严重错误：自动恢复失败。为避免扩大问题，请勿继续修改用户或分流；恢复记录和备份已保留"
    return 1
  fi
  local clear_rc=0
  clear_operation_transaction || clear_rc=$?
  if ((clear_rc >= 2)); then
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
  sync_transaction_path "$(kernel_runtime_config_path)" || return 1
  sync_transaction_path "$STATE_FILE" || return 1
  if [[ -f "$CONF_FILE" ]]; then sync_transaction_path "$CONF_FILE" || return 1; fi
  if [[ -f "$nfuse_db" ]]; then sync_transaction_path "$nfuse_db" || return 1; fi
  if [[ -f "$nfuse_db-wal" ]]; then sync_transaction_path "$nfuse_db-wal" || return 1; fi
  # 数据到这里已经全部落盘，本次操作事实上已经提交成功。恢复标记删掉了但目录没同步不影响结果，
  # 不能再当作提交失败，否则调用方会在一个字节都没有回滚的情况下告诉用户「操作失败并已恢复」。
  # 但恢复标记仍在磁盘上是另一回事：下次启动会按它无条件自动回滚，把这次改动悄悄撤销，
  # 此时必须如实报告失败，让调用方当场回滚并明确告知，而不是先说成功、事后被静默退回。
  local clear_rc=0
  clear_operation_transaction || clear_rc=$?
  if ((clear_rc >= 2)); then
    log "错误：修改已经保存，但恢复标记未能删除，下次启动会按它自动撤销本次修改：$TRANSACTION_JOURNAL"
    return 1
  fi
  if ((clear_rc != 0)); then
    log "提示：修改已经保存成功，恢复标记也已删除，只是目录同步未完成；不需要重做本次操作"
  fi
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
    # 管理器自身数据的目录。存量机器上它是 /etc/sing-box，2f 之后新装的机器上是
    # /etc/sb-user-manager；两个名字下面都有字面量，这一条管的是管理配置把它指到
    # 别处的机器（公开 Issue #172）。
    "$MANAGER_DATA_DIR"|"$MANAGER_DATA_DIR"/*) return 0;;
    # **中立数据目录必须是字面量，不能只靠上面那条按当前取值匹配。**
    # 恢复记录是给「下一次运行的进程」读的，而那个进程的 MANAGER_DATA_DIR 来自
    # 它当时读到的管理配置——搬迁（公开 Issue #276）中途崩在改配置之前时，配置
    # 里写的还是老目录，于是记录里的 /etc/sb-user-manager 会被判为不受管路径，
    # 开机自检拒绝恢复，机器卡在半迁移状态上要人工介入。真机演练撞到过一次。
    /etc/sb-user-manager|/etc/sb-user-manager/*|/etc/sb-user-manager.conf|/etc/sing-box|/etc/sing-box/*|/etc/systemd/system/sing-box.service|/etc/systemd/system/nfuse.service|/etc/systemd/system/sb-user-expiry.service|/etc/systemd/system/sb-user-expiry.timer|/etc/systemd/system/multi-user.target.wants/sing-box.service|/etc/systemd/system/multi-user.target.wants/nfuse.service|/etc/systemd/system/timers.target.wants/sb-user-expiry.timer|/var/lib/nfuse|/var/lib/nfuse/*|/var/lib/sing-box|/var/lib/sing-box/*|/var/lib/sb-user-manager|/var/lib/sb-user-manager/*|/usr/local/sbin/sb-user-manager|/usr/local/bin/sbm|/usr/local/bin/sing-box|/usr/local/bin/nfuse|/run/nfuse.sock) return 0;;
    # mihomo 部署的路径。两个内核的路径同时列在白名单里而不是按内核分派：
    # 白名单只决定「这条路径允不允许出现在事务里」，多列几条不会让不存在的文件
    # 被创建，而按内核分派会让一台机器换内核后旧路径突然不被允许清理。
    /etc/mihomo|/etc/mihomo/*|/etc/systemd/system/mihomo.service|/etc/systemd/system/multi-user.target.wants/mihomo.service|/var/lib/mihomo|/var/lib/mihomo/*|/usr/local/bin/mihomo) return 0;;
    *) return 1;;
  esac
}

release_environment_lock() {
  flock -u 8 2>/dev/null || true
  { exec 8>&-; } 2>/dev/null || true
}

# 建一个属于管理器的目录。**已经存在时只检查类型，绝不改动权限。**
# `install -d -m` 一旦点到一个已经存在的目录，就会直接 chmod 它——把这一条
# 用在系统目录上，后果是静静改掉整台机器的权限：环境事务的恢复记录曾经放在
# /var/lib 正下方，取父目录建出来的正是 /var/lib，于是每次环境操作都把它改成
# 700，apt 的下载沙箱与所有以非 root 身份读 /var/lib/<服务名> 的服务随之失效
# （公开 Issue #246）。
# 顺带拒绝符号链接：跟随它会把权限改到别处去。
# 锁目录一直是这么做的，这里把同一份防护收敛成唯一入口，供两处共用。
ensure_manager_directory() {
  local directory="$1" mode="${2:-700}"
  if [[ -e "$directory" || -L "$directory" ]]; then
    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    return 0
  fi
  install -d -m "$mode" -- "$directory" || return 1
}

ensure_environment_lock_directory() {
  local lock_directory
  lock_directory="$(dirname "$ENVIRONMENT_LOCK_FILE")" || return 1
  ensure_manager_directory "$lock_directory" 755
}

begin_environment_transaction() {
  local operation="$1" snapshot="$2" tmp path operation_journal
  shift 2
  operation_journal="${TRANSACTION_JOURNAL:-$(system_path /var/lib/sb-user-manager/transactions/active.json)}" || return 1
  ensure_environment_lock_directory || return 1
  exec 8>"$ENVIRONMENT_LOCK_FILE"
  flock -n 8 || { release_environment_lock; return 1; }
  [[ ! -e "$ENVIRONMENT_TRANSACTION_JOURNAL" && ! -L "$ENVIRONMENT_TRANSACTION_JOURNAL" ]] || {
    release_environment_lock
    return 1
  }
  if [[ -e "$operation_journal" || -L "$operation_journal" ]]; then
    printf '错误：发现尚未完成的用户或分流操作。为保护现有数据，本次环境操作已停止。恢复记录：%s\n' "$operation_journal" >&2
    release_environment_lock
    return 1
  fi
  verify_environment_backup "$snapshot" || { release_environment_lock; return 1; }
  for path in "$@"; do is_environment_recovery_path "$path" || { release_environment_lock; return 1; }; done
  ensure_manager_directory "$(dirname "$ENVIRONMENT_TRANSACTION_JOURNAL")" || { release_environment_lock; return 1; }
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

environment_transaction_journal_is_trusted() {
  local owner mode expected_owner
  [[ -f "$ENVIRONMENT_TRANSACTION_JOURNAL" &&
     ! -L "$ENVIRONMENT_TRANSACTION_JOURNAL" ]] || return 1
  owner="$(manager_file_uid "$ENVIRONMENT_TRANSACTION_JOURNAL")" || return 1
  mode="$(manager_file_mode "$ENVIRONMENT_TRANSACTION_JOURNAL")" || return 1
  expected_owner="$(runtime_config_expected_uid)" || return 1
  [[ "$owner" == "$expected_owner" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0077) == 0 ))
}

recover_environment_transaction() {
  local snapshot operation path
  if [[ ! -e "$ENVIRONMENT_TRANSACTION_JOURNAL" &&
        ! -L "$ENVIRONMENT_TRANSACTION_JOURNAL" ]]; then
    return 0
  fi
  environment_transaction_journal_is_trusted ||
    die "环境恢复日志权限或类型不安全，拒绝继续：$ENVIRONMENT_TRANSACTION_JOURNAL"
  acquire_operation_lock || die "$OPERATION_LOCK_ERROR"
  ensure_environment_lock_directory || {
    release_operation_lock
    die "无法创建环境恢复锁目录"
  }
  exec 8>"$ENVIRONMENT_LOCK_FILE" || {
    release_operation_lock
    die "无法打开环境恢复锁"
  }
  flock -n 8 || {
    release_environment_lock
    release_operation_lock
    die "另一个环境恢复或部署操作正在执行"
  }
  validate_environment_transaction || {
    release_environment_lock
    release_operation_lock
    die "环境恢复日志无效，拒绝继续：$ENVIRONMENT_TRANSACTION_JOURNAL"
  }
  snapshot="$(jq -r '.snapshot' "$ENVIRONMENT_TRANSACTION_JOURNAL")"
  operation="$(jq -r '.operation' "$ENVIRONMENT_TRANSACTION_JOURNAL")"
  prepare_environment_backup_for_restore "$snapshot" || {
    release_environment_lock
    release_operation_lock
    die "操作前完整备份已经损坏或无法安全整理，为保护现有数据，本次自动恢复已停止：$snapshot"
  }
  log "检测到上次安装或更新未正常结束，正在恢复原环境：$operation"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    path="$(system_path "$path")"
    if [[ -d "$path" && ! -L "$path" ]]; then rm -rf -- "$path"; else rm -f -- "$path"; fi
  done < <(jq -r '.cleanup_paths[]' "$ENVIRONMENT_TRANSACTION_JOURNAL" | awk '{print length, $0}' | sort -rn | cut -d' ' -f2-)
  restore_environment_backup "$snapshot" || {
    release_environment_lock
    release_operation_lock
    die "环境自动恢复失败。请停止继续部署，并保留完整备份：$snapshot"
  }
  if ! clear_environment_transaction; then
    release_operation_lock
    die "环境已经恢复，但无法清除恢复标记：$ENVIRONMENT_TRANSACTION_JOURNAL"
  fi
  release_operation_lock
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
  local rollback="$1" rc step
  declare -F "$rollback" >/dev/null || die "操作回滚函数不存在：$rollback"
  shift
  step="$1"
  # 失败码必须写在 else 里：`if ... fi` 没有 else 分支时整条语句的退出码恒为 0，
  # 在 fi 之后读 $? 只会读到 0。静态门禁看守这条约定，本次改动正是被它抓住的。
  if "$@"; then
    return 0
  else
    rc=$?
  fi
  # 说出是哪一步失败的。以前只有一句「操作失败，正在自动撤销本次修改」，
  # 一次真实的生产故障因此只能靠逐行读源码定位（公开 Issue #265）。
  # **只记函数名，绝不记参数**：参数里有用户密码（例如 append_inbounds 收到的
  # 整段入站片段），记进日志等于把凭据扩散到日志和随后被贴出来的终端输出里。
  log "步骤失败：${step}（退出码 ${rc}）"
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

list_kernel_owned_ssh_sockets() {
  local client_port="$1" server_port="$2"
  command -v ss >/dev/null 2>&1 || return 1
  ss -Htnp state established \
    "( sport = :${client_port} and dport = :${server_port} )" 2>/dev/null
}

ssh_connection_uses_local_kernel() {
  local client_ip client_port server_ip server_port extra socket_rows process
  [[ -n "${SSH_CONNECTION:-}" ]] || return 1
  read -r client_ip client_port server_ip server_port extra <<<"$SSH_CONNECTION"
  [[ -n "$client_ip" && -n "$server_ip" && -z "${extra:-}" ]] || return 1
  [[ "$client_port" =~ ^[1-9][0-9]{0,4}$ && "$server_port" =~ ^[1-9][0-9]{0,4}$ ]] || return 1
  ((client_port <= 65535 && server_port <= 65535)) || return 1
  socket_rows="$(list_kernel_owned_ssh_sockets "$client_port" "$server_port")" || return 1
  # 按当前内核的进程名匹配。写死 sing-box 会让这条护栏在 mihomo 机器上
  # 永远判为「不是本机节点」——一条恒假的安全检查比没有更糟，
  # 因为它看起来还在。
  process="$(kernel_process_name)" || return 1
  grep -Fq "\"${process}\"" <<<"$socket_rows"
}

ensure_safe_ssh_for_kernel_restart() {
  local phase="${1:-preflight}" label
  ssh_connection_uses_local_kernel || return 0
  label="$(kernel_display_name)" || return 1
  printf '检测到当前 SSH 连接正通过这台服务器自己的 %s 节点。\n' "$label"
  printf '接下来的操作需要重启 %s；继续会中断当前连接，并使本次操作等待下次运行脚本时自动恢复。\n' "$label"
  if [[ "$phase" == rollback ]]; then
    printf '为避免连接中断，%s 尚未重启；脚本正在撤销本次尚未完成的修改。\n' "$label"
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
  if commit_operation_transaction; then
    return 0
  else
    rc=$?
  fi
  log "修改未能安全保存，正在恢复操作前的数据"
  rollback_operation_transaction "$rc" || true
  return "$rc"
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
         {protocol:"ss2022",transport:"shadowtls",port:.port,shadowtls_password:.shadowtls_password,
          ss2022_password:.ss2022_password,method:.method,shadowtls_sni:.shadowtls_sni}
       end;
     ($state[0] |
       if .schema_version == 3 and $schema >= 4 then
         . + {schema_version:4,outbound_presets:(.outbound_presets // []),rule_presets:(.rule_presets // [])}
       else . end |
       if .schema_version == 4 and $schema >= 5 then
         .users |= map(.protocol = (.protocol // "ss2022") | if has("usage_offset_bytes") then . else .usage_offset_bytes = 0 end | .endpoints = [endpoint_from_legacy]) |
         .schema_version = 5
       else . end |
       if .schema_version == 5 and $schema >= 6 then
         .users |= map(
           .endpoints |= map(if .protocol == "ss2022" then .transport = (.transport // "shadowtls") else . end) |
           if .protocol == "ss2022" then .transport = (.transport // "shadowtls") else . end
         ) |
         .schema_version = 6
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

# 不可逆操作之前当场清点服务器外退路（ADR 0032 的「配套要求」）。
# 这个函数曾随换内核与清理 sing-box 残留一并删除（公开 Issue #256）——它们是它
# 仅有的两个调用点，留着就是死代码。ADR 0032 的「后续」一节写明：**再添一个
# 不可逆操作时必须把它写回来，并同时接上调用点**，不能默认它还在。
# 现在的调用点是搬迁管理器数据目录（公开 Issue #276）——那个动作在校验通过后会
# 删掉老位置的用户资料、内部备份与证书。该入口是一次性的，撤除时这个函数会再次
# 变成孤儿，届时连同 tests/test-static.sh 里那条断言一起改回去。
#
# 它刻意**不阻止**操作：项目所有者可能有仓库不知道的服务器外副本。
# 它只保证「没有退路」这件事不会悄悄发生。
print_offsite_recovery_status() {
  local newest
  load_migration_backups
  if ((${#MIGRATION_BACKUPS[@]} == 0)); then
    printf '\n注意：本机没有任何加密迁移备份（.sbm）。\n'
    printf '这个操作成功之后如果反悔，将没有退路：操作前的完整环境快照只在本次操作失败时\n'
    printf '由脚本自动还原，菜单里没有事后手工恢复它的入口。\n'
    printf '建议先返回「数据备份与恢复」创建一份，并复制到服务器之外。\n'
    return 0
  fi
  newest="${MIGRATION_BACKUPS[0]}"
  printf '\n本机现有加密迁移备份（.sbm）%s 份，最新一份是 %s。\n' \
    "${#MIGRATION_BACKUPS[@]}" "$(basename "$newest")"
  printf '事后反悔时的退路就是它——请确认它已经复制到服务器之外，并且内容足够新。\n'
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
  if ((schema < STATE_SCHEMA_VERSION)); then
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
          {protocol:"ss2022",transport:"shadowtls",port:.port,shadowtls_password:.shadowtls_password,
           ss2022_password:.ss2022_password,method:.method,shadowtls_sni:.shadowtls_sni}
        end;
      .state.users |= map(if has("usage_offset_bytes") then . else .usage_offset_bytes = 0 end) |
      if .state.schema_version == 3 and $schema >= 4 then
        .state.outbound_presets = (.state.outbound_presets // []) |
        .state.rule_presets = (.state.rule_presets // []) |
        .state.schema_version = 4
      else . end |
      if .state.schema_version == 4 and $schema >= 5 then
        .state.users |= map(.protocol = (.protocol // "ss2022") | .endpoints = [endpoint_from_legacy]) |
        .state.schema_version = 5
      else . end |
      if .state.schema_version == 5 and $schema >= 6 then
        .state.users |= map(
          .endpoints |= map(if .protocol == "ss2022" then .transport = (.transport // "shadowtls") else . end) |
          if .protocol == "ss2022" then .transport = (.transport // "shadowtls") else . end
        ) |
        .state.schema_version = 6
      else . end |
      if .state.schema_version == 6 and $schema >= 7 then
        .state.schema_version = 7
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
    def endpoint_kind:
      if .protocol == "anytls" then "anytls"
      elif .protocol == "ss2022" and .transport == "direct" then "ss2022-direct"
      elif .protocol == "ss2022" and .transport == "shadowtls" then "ss2022-shadowtls"
      else null end;
    def valid_ss2022_endpoint:
      (.transport == "direct" or .transport == "shadowtls") and
      (.ss2022_password | type == "string" and length > 0) and
      (.method == "2022-blake3-aes-128-gcm" or .method == "2022-blake3-aes-256-gcm") and
      (if .transport == "shadowtls" then
         (.shadowtls_password | type == "string" and length > 0) and
         (.shadowtls_sni | type == "string" and length > 0)
       else
         (has("shadowtls_password") | not) and (has("shadowtls_sni") | not)
       end);
    # 规则集来源。两个内核存的东西不同：sing-box 是公网 HTTPS 上的 .srs / .json，
    # mihomo 是使用者自己那个本地块状 yaml 文件的文件名。
    # 迁移包不带那个文件，所以这里只校验写法——文件在不在由恢复之后的分流重建报。
    # 文件名限制成不含斜杠、不含 ..，迁移包里的内容因此不可能指到目录之外。
    # 第三种来源是 GeoSite／GeoIP 类别（公开 Issue #219）：既没有地址也没有文件，
    # 状态里只有一份类别清单。写法卡死到「前缀 + 不含逗号括号的类别名」，
    # 迁移包里的内容因此不可能把一条规则拼成另一条；类别名认不认得由恢复之后
    # 那次 mihomo 配置校验说——它在这件事上是当场失败，不是静默失效。
    def valid_rule_source:
      ((.url | type == "string" and test("^https://") and test("\\.(srs|json)([?#].*)?$")) or
       ((.rule_file | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")) and
        (.rule_behavior == "classical" or .rule_behavior == "domain" or .rule_behavior == "ipcidr") and
        ((.rule_url // "") == "" or (.rule_url | type == "string" and test("^https://") and test("\\.(yaml|yml)$")))) or
       ((.rule_geo | type == "array" and length > 0 and
         all(.[]; type == "string" and test("^(GEOSITE|GEOIP),[A-Za-z0-9_.:@!-]+$")))));

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
      (.endpoints | type == "array" and length >= 1 and length <= 3) and
      ([.endpoints[] | endpoint_kind] | all(. != null) and length == (unique | length)) and
      ([.endpoints[].port] | length == (unique | length)) and
      (.protocol == .endpoints[0].protocol) and (.port == .endpoints[0].port) and
      all(.endpoints[];
        (.port|type=="number") and (.port == (.port|floor)) and (.port>=1 and .port<=65535) and
        if .protocol == "anytls" then
          (.anytls_password|type=="string" and length>0) and (.tls_sni|type=="string" and length>0)
        elif .protocol == "ss2022" then
          valid_ss2022_endpoint
        else false end) and
      if .protocol == "anytls" then
        (.anytls_password == .endpoints[0].anytls_password) and (.tls_sni == .endpoints[0].tls_sni)
      elif .protocol == "ss2022" then
        (.transport == .endpoints[0].transport) and
        (.ss2022_password == .endpoints[0].ss2022_password) and
        (.method == .endpoints[0].method) and
        (if .transport == "shadowtls" then
           (.shadowtls_password == .endpoints[0].shadowtls_password) and
           (.shadowtls_sni == .endpoints[0].shadowtls_sni)
         else
           (has("shadowtls_password") | not) and (has("shadowtls_sni") | not)
         end)
      else false end) and
    all(.state.splits[];
      (.name|type=="string" and test("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$")) and
      valid_rule_source and
      (.scope=="all" or .scope=="user") and
      ((.scope=="all") or ((.user|type=="string") and (.user as $user | ($user_names | index($user)) != null))) and
      (.status=="active" or .status=="disabled") and
      ((.upstream | valid_upstream) or (.status == "disabled" and (.upstream | type == "object"))) and
      (((.outbound_preset // null) == null) or (.outbound_preset as $preset | ($outbound_preset_names | index($preset)) != null)) and # static-allow: strict-empty-check
      (((.rule_preset // null) == null) or (.rule_preset as $preset | ($rule_preset_names | index($preset)) != null)) and # static-allow: strict-empty-check
      ((.outbound_tag // ("managed-out-" + .name)) | test("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$") and . != "direct") and
      ((.rule_set_tag // ("managed-split-" + .name)) | test("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$") and . != "direct") and
      all([.runtime_rule_tag?,.runtime_outbound_tag?,.runtime_transport_tag?][];
        . == null or (type == "string" and test("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$") and . != "direct"))) and
    all(.state.outbound_presets[];
      (.name | type == "string" and test("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$")) and
      (.upstream | valid_upstream)) and
    all(.state.rule_presets[];
      (.name | type == "string" and test("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$")) and
      valid_rule_source) and
    all(.nfuse_usage[];
      (.name|type=="string" and length>0) and
      (.used_bytes|type=="number") and
      (.used_bytes == (.used_bytes|floor)) and .used_bytes>=0)
  ' "$payload" >/dev/null || return 1
  # 远程地址要逐条确认指向公网；本机规则文件名没有这个问题，
  # 结构校验里已经把它限制成一个文件名（不含斜杠、不含 ..），
  # 而「文件在不在」由恢复之后的分流重建负责报，迁移包里本来就不带那个文件。
  while IFS= read -r rule_url; do
    [[ -n "$rule_url" ]] || continue
    validate_public_rule_set_url "$rule_url" || return 1
  done < <(jq -r '.state.splits[]?.url // empty, .state.rule_presets[]?.url // empty' "$payload")
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
  local name port protocol tag owner endpoint has_legacy=false
  local -a tags
  MIGRATION_CONFLICT_REASON=""
  name="$(jq -r '.name' <<<"$candidate")"
  jq -e 'any(.endpoints[]?; .protocol == "ss2022" and .transport == "shadowtls")' <<<"$candidate" >/dev/null && has_legacy=true
  if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$ ]]; then
    MIGRATION_CONFLICT_REASON="用户名不符合规则：$name"; return 0
  fi
  owner="$(jq -r --arg replace "$replace_name" --arg name "$name" '.state.users[]? | select(.name != $replace and .name == $name) | .name' "$payload" | head -n1)"
  if [[ -n "$owner" ]]; then
    MIGRATION_CONFLICT_REASON="用户名已存在：$name"; return 0
  fi
  if ! jq -e '[.endpoints[].port] | length == (unique | length)' <<<"$candidate" >/dev/null; then
    MIGRATION_CONFLICT_REASON='两个协议必须使用不同端口'; return 0
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
    if [[ "$protocol" == anytls ]]; then
      tags=("anytls-$name")
    elif [[ "$(jq -r '.transport // "shadowtls"' <<<"$endpoint")" == shadowtls ]]; then
      tags=("st-$name" "ss-$name" "ss-udp-$name")
    elif [[ "$has_legacy" == true ]]; then
      tags=("ss-direct-$name")
    else
      tags=("ss-$name")
    fi
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
      if [[ "$protocol" == anytls ]]; then label=AnyTLS
      elif [[ "$(jq -r --argjson index "$index" '.endpoints[$index].transport // "shadowtls"' <<<"$incoming")" == shadowtls ]]; then label='SS2022 + ShadowTLS（旧版）'
      else label=SS2022
      fi
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
  kernel_normalized_config > "$normalized" || { rm -f -- "$normalized"; return 1; }
  jq --slurpfile current "$STATE_FILE" --argjson nfuse "$current_nfuse" --argjson schema "$STATE_SCHEMA_VERSION" '
    def endpoint_from_legacy:
      if (.protocol // "ss2022") == "anytls" then
        {protocol:"anytls",port:.port,anytls_password:.anytls_password,tls_sni:.tls_sni}
      else
        {protocol:"ss2022",transport:(.transport // "shadowtls"),port:.port,shadowtls_password:.shadowtls_password,
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
      if SB_JQ_INCOMING="$incoming" jq -e --arg name "$preset_name" '($ENV.SB_JQ_INCOMING | fromjson) as $incoming | .state.rule_presets[] | select(.name == $name and (.url // .rule_file) == ($incoming.url // $incoming.rule_file) and (.rule_behavior // "") == ($incoming.rule_behavior // ""))' "$output" >/dev/null; then
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
          (if .protocol == "anytls" then "AnyTLS"
           elif .transport == "shadowtls" then "SS2022 + ShadowTLS（旧版）"
           else "SS2022" end) + " 端口 " + (.port|tostring)] | join(" / "))
      ' "$output"
      jq -r '
        "  备份中用户：" + ([.endpoints[] |
          (if .protocol == "anytls" then "AnyTLS"
           elif .transport == "shadowtls" then "SS2022 + ShadowTLS（旧版）"
           else "SS2022" end) + " 端口 " + (.port|tostring)] | join(" / "))
      ' <<<"$incoming"
      cat <<'EOF'
  1. 保留这台服务器上的用户，跳过备份用户（推荐）
  2. 使用备份用户覆盖同名用户（原客户端配置可能失效）
  3. 把备份用户作为新用户导入（重新填写名称和端口）
  0. 返回，不执行任何恢复
EOF
      prompt_migration_choice '请选择 [1]：' 1 '^[0-3]$' || { MIGRATION_MERGE_CANCELLED=true; rm -f -- "$normalized"; return 1; }; choice="$MIGRATION_CHOICE"
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
      prompt_migration_choice '请选择 [2]：' 2 '^[0-2]$' || { MIGRATION_MERGE_CANCELLED=true; rm -f -- "$normalized"; return 1; }; choice="$MIGRATION_CHOICE"
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
      prompt_migration_choice '请选择 [1]：' 1 '^[0-3]$' || { MIGRATION_MERGE_CANCELLED=true; rm -f -- "$normalized"; return 1; }; choice="$MIGRATION_CHOICE"
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
      prompt_migration_choice '请选择 [2]：' 2 '^[0-2]$' || { MIGRATION_MERGE_CANCELLED=true; rm -f -- "$normalized"; return 1; }; choice="$MIGRATION_CHOICE"
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
      . as $user |
      (if (.endpoints | type) == "array" then .endpoints
       else [{protocol:(.protocol // "ss2022"),transport:(.transport // "shadowtls")}] end) as $endpoints |
      ($endpoints | any(.protocol == "ss2022" and .transport == "shadowtls")) as $has_legacy |
      any($endpoints[];
        if .protocol == "anytls" then $tag==("anytls-"+$user.name)
        elif .transport == "shadowtls" then
          ($tag==("st-"+$user.name) or $tag==("ss-"+$user.name) or $tag==("ss-udp-"+$user.name))
        elif $has_legacy then $tag==("ss-direct-"+$user.name)
        else $tag==("ss-"+$user.name) end)) or
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
  local payload="$1" normalized user name port tag split out_tag rule_tag protocol transport_tag endpoint has_legacy
  local -a tags
  MIGRATION_CONFLICTS=()
  if ! validate_migration_payload_structure "$payload"; then
    add_migration_conflict "迁移数据结构、用户名称或端口存在异常"; return 0
  fi
  normalized="$(mktemp /tmp/sb-migration-config.XXXXXX)"
  register_temp_path "$normalized"
  if ! kernel_normalized_config > "$normalized"; then
    rm -f "$normalized"; add_migration_conflict "无法读取目标 sing-box 配置"; return 0
  fi
  while IFS= read -r user; do
    name="$(jq -r '.name' <<<"$user")"
    has_legacy=false
    jq -e 'any(.endpoints[]?; .protocol == "ss2022" and .transport == "shadowtls")' <<<"$user" >/dev/null && has_legacy=true
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
      if [[ "$protocol" == anytls ]]; then
        tags=("anytls-$name")
      elif [[ "$(jq -r '.transport // "shadowtls"' <<<"$endpoint")" == shadowtls ]]; then
        tags=("st-$name" "ss-$name" "ss-udp-$name")
      elif [[ "$has_legacy" == true ]]; then
        tags=("ss-direct-$name")
      else
        tags=("ss-$name")
      fi
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
  if ! ensure_safe_ssh_for_kernel_restart; then
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
  local runtime_config
  ensure_safe_ssh_for_kernel_restart rollback || return 1
  # 校验的必须是当前内核自己的配置文件。此前这里写死 SINGBOX_CONFIG，
  # 在 mihomo 机器上会用 mihomo 去校验一份 sing-box 的配置——2c 之前
  # mihomo 机器不可能有用户，走不到这里；本片让它可达，因此一并改对。
  runtime_config="$(kernel_runtime_config_path)" || return 1
  kernel_check_config "$runtime_config" || return 1
  kernel_service_reset_failed
  kernel_service_restart || return 1
  if ! kernel_service_is_active; then
    log "错误：$(kernel_display_name) 重启后未处于 active 状态"
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
  local tag="$1" container entry_key
  container="$(kernel_managed_container)" || return 1
  entry_key="$(kernel_managed_key)" || return 1
  kernel_normalized_config |
    jq -e --arg tag "$tag" --arg container "$container" --arg entry_key "$entry_key" \
      '.[$container][]? | select(.[$entry_key] == $tag)' >/dev/null
}

read_singbox_config_source() {
  local output_name="$1" content="" config_path
  config_path="$(kernel_runtime_config_path)" || return 1
  # `read -d ''` reads through EOF without command substitution, so trailing
  # newlines remain part of the snapshot. A successful read means an embedded
  # NUL was found; that is not valid JSON and must be rejected.
  if IFS= read -r -d '' content < "$config_path"; then
    return 1
  elif [[ ! -r "$config_path" ]]; then
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

# 三个入口的托管条目形状由适配层给出，每个内核各一份（公开 Issue #180）。
# 这里保留原有的函数名与参数，只把形状那一层挪走：调用点不必知道当前内核
# 生成的是几个条目——sing-box 的 SS2022 + ShadowTLS 是三个入站，mihomo 是
# 一个同时承载 TCP 与 UDP 的监听器。
make_user_inbounds() {
  kernel_entries_ss2022_shadowtls "$1" "$2" "$3" "$4" "$5" "$6"
}

make_ss2022_inbound() {
  kernel_entries_ss2022_direct "$1" "$2" "$3" "$4" "${5:-ss-$1}"
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
  SB_JQ_NEW_INBOUNDS="$fragments" rewrite_kernel_config '
    ($ENV.SB_JQ_NEW_INBOUNDS | fromjson) as $new_entries |
    .[$managed_container] = ([((.[$managed_container] // [])[]) |
      .[$managed_key] as $entry_name | select(($managed_tags | index($entry_name)) == null)] + $new_entries)
  ' --argjson managed_tags "$managed_tags_json"
}

# 原子改写当前内核的运行配置。
#
# 过滤器里可以直接用 ${managed_container} 与 ${managed_key}，本函数总是注入这两个值：
# sing-box 把托管条目放在 .inbounds[] 并用 .tag 标识，mihomo 放在 .listeners[]
# 并用 .name 标识。让每个调用点各取一遍，等于同一段判断散在十来处。
rewrite_kernel_config() {
  local filter="$1" config_path config_dir container entry_key tmp normalized
  shift
  config_path="$(kernel_runtime_config_path)" || return 1
  container="$(kernel_managed_container)" || return 1
  entry_key="$(kernel_managed_key)" || return 1
  config_dir="$(dirname "$config_path")"
  tmp="$(mktemp "$config_dir/.config.XXXXXX")" || return 1
  register_temp_path "$tmp"
  normalized="$(mktemp "$config_dir/.normalized.XXXXXX")" || {
    rm -f -- "$tmp"
    return 1
  }
  register_temp_path "$normalized"
  if ! kernel_normalized_config > "$normalized"; then
    rm -f -- "$tmp" "$normalized"
    printf '错误：无法解析或格式化运行配置：%s\n' "$config_path" >&2
    return 1
  fi
  if ! jq --arg managed_container "$container" --arg managed_key "$entry_key" \
      "$@" "$filter" "$normalized" > "$tmp"; then
    rm -f -- "$tmp" "$normalized"
    printf '错误：无法生成新的运行配置\n' >&2
    return 1
  fi
  rm -f -- "$normalized" || return 1
  unregister_temp_path "$normalized" || return 1
  if ! chmod --reference="$config_path" "$tmp" 2>/dev/null; then
    if ! chmod 600 "$tmp"; then
      rm -f -- "$tmp"
      return 1
    fi
  fi
  chown --reference="$config_path" "$tmp" 2>/dev/null || true
  if ! mv -- "$tmp" "$config_path"; then
    rm -f -- "$tmp"
    return 1
  fi
  unregister_temp_path "$tmp" || return 1
}

append_inbounds_from_new_user_snapshot() {
  local config_json="$1" expected_source="$2" fragment="$3"
  local config_path config_dir current_source tmp container
  config_path="$(kernel_runtime_config_path)" || return 1
  container="$(kernel_managed_container)" || return 1
  config_dir="$(dirname "$config_path")" || return 1
  tmp="$(mktemp "$config_dir/.config.XXXXXX")" || return 1
  register_temp_path "$tmp" || { rm -f -- "$tmp" || true; return 1; }
  if ! SB_JQ_NEW_INBOUNDS="$fragment" jq --arg container "$container" '
    ($ENV.SB_JQ_NEW_INBOUNDS | fromjson) as $new_entries |
    .[$container] = ((.[$container] // []) + $new_entries)
  ' <<<"$config_json" > "$tmp"; then
    if rm -f -- "$tmp"; then
      unregister_temp_path "$tmp" || return 1
    fi
    printf '错误：无法生成新的运行配置\n' >&2
    return 1
  fi
  if ! chmod --reference="$config_path" "$tmp" 2>/dev/null; then
    if ! chmod 600 "$tmp"; then
      if rm -f -- "$tmp"; then
        unregister_temp_path "$tmp" || return 1
      fi
      return 1
    fi
  fi
  chown --reference="$config_path" "$tmp" 2>/dev/null || true
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
    printf '错误：运行配置在新增用户预检后发生变化，请重新操作\n' >&2
    return 1
  fi
  if ! mv -- "$tmp" "$config_path"; then
    if rm -f -- "$tmp"; then
      unregister_temp_path "$tmp" || return 1
    fi
    return 1
  fi
  unregister_temp_path "$tmp" || return 1
}

append_inbounds() {
  local fragment="$1"
  SB_JQ_NEW_INBOUNDS="$fragment" rewrite_kernel_config \
    '($ENV.SB_JQ_NEW_INBOUNDS | fromjson) as $new_entries |
     .[$managed_container] = ((.[$managed_container] // []) + $new_entries)'
}

remove_user_inbounds() {
  local name="$1"
  rewrite_kernel_config \
    '.[$managed_container] = [(.[$managed_container] // [])[] |
       .[$managed_key] as $entry_name |
       select($entry_name != $st and $entry_name != $ss and $entry_name != $ss_direct and
              $entry_name != $ss_udp and $entry_name != $at and $entry_name != $sn)]' \
    --arg st "st-$name" --arg ss "ss-$name" --arg ss_direct "ss-direct-$name" \
    --arg ss_udp "ss-udp-$name" --arg at "anytls-$name" --arg sn "snell-$name"
}

replace_user_inbounds() {
  local name="$1" fragment="$2"
  SB_JQ_NEW_INBOUNDS="$fragment" rewrite_kernel_config \
     '($ENV.SB_JQ_NEW_INBOUNDS | fromjson) as $new_entries |
      .[$managed_container] = ([((.[$managed_container] // [])[]) |
        .[$managed_key] as $entry_name |
        select($entry_name != $st and $entry_name != $ss and $entry_name != $ss_direct and
               $entry_name != $ss_udp and $entry_name != $at and $entry_name != $sn)] + $new_entries)' \
    --arg st "st-$name" --arg ss "ss-$name" --arg ss_direct "ss-direct-$name" \
    --arg ss_udp "ss-udp-$name" --arg at "anytls-$name" --arg sn "snell-$name"
}

# 重建某个协议的全部托管条目。
#
# sing-box 有一条整体 jq 快路径（build_user_inbound_payload），一次 jq 调用算出
# 所有用户的入站；状态里还是旧格式时回落到逐条生成。
# **mihomo 一律走逐条生成那条路**，不另写一份整体 jq 程序：托管条目的形状只在
# 适配层写一遍，再写一份等于同一份判断存在两处——v4.25.11 修的缺陷正是这么来的。
# 代价是每个端点一次 jq 调用，在 mihomo 部署上是可以接受的。
rebuild_protocol_inbounds() {
  local protocol="$1" rebuild_payload
  case "$PROXY_KERNEL" in
    singbox) ;;
    mihomo)
      rebuild_protocol_inbounds_with_shell_tools "$protocol"
      return
      ;;
    *) kernel_unknown; return 1 ;;
  esac
  rebuild_payload="$(build_user_inbound_payload rebuild "$protocol" "$STATE_FILE")" || return 1
  if [[ "$rebuild_payload" == '{"legacy_fallback":true}' ]]; then
    rebuild_protocol_inbounds_with_shell_tools "$protocol"
    return
  fi
  SB_JQ_PROTOCOL_REBUILD="$rebuild_payload" rewrite_kernel_config '
    ($ENV.SB_JQ_PROTOCOL_REBUILD | fromjson) as $payload |
    .[$managed_container] = ([((.[$managed_container] // [])[]) |
      .[$managed_key] as $entry_name |
      select(($payload.managed_tags | index($entry_name)) == null)] + $payload.inbounds)
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
  kernel_entries_anytls "$1" "$2" "$3"
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

# 一个用户在当前内核下的全部托管条目。
# 与 rebuild_protocol_inbounds 同理：sing-box 用整体 jq 快路径，
# mihomo 逐个端点调用适配层的生成函数，形状只有一份。
make_user_inbounds_from_state() {
  local user="$1"
  case "$PROXY_KERNEL" in
    singbox) build_user_inbound_payload user "" - <<<"$user" ;;
    mihomo) make_user_entries_per_endpoint "$user" ;;
    *) kernel_unknown ;;
  esac
}

# 逐个端点生成一个用户的托管条目。与 rebuild_protocol_inbounds_with_shell_tools
# 里那段循环共用同一套判断（是否需要 ss-direct- 前缀），不各写一遍。
make_user_entries_per_endpoint() {
  local user="$1" name endpoint direct_tag fragment entries='[]' has_legacy
  name="$(jq -er '.name' <<<"$user")" || return 1
  has_legacy="$(jq -r 'any(.endpoints[]?; .protocol == "ss2022" and .transport == "shadowtls")' <<<"$user")" || return 1
  while IFS= read -r endpoint; do
    [[ -n "$endpoint" ]] || continue
    direct_tag=""
    if [[ "$has_legacy" == true &&
          "$(jq -r '.protocol == "ss2022" and (.transport // "shadowtls") == "direct"' <<<"$endpoint")" == true ]]; then
      direct_tag="ss-direct-$name"
    fi
    fragment="$(make_endpoint_inbounds_from_state "$name" "$endpoint" "$direct_tag")" || return 1
    entries="$(SB_JQ_CURRENT="$entries" SB_JQ_ADDED="$fragment" jq -cn \
      '($ENV.SB_JQ_CURRENT | fromjson) + ($ENV.SB_JQ_ADDED | fromjson)')" || return 1
  done < <(jq -c '
    if (.endpoints | type) == "array" then .endpoints[]
    elif (.protocol // "ss2022") == "anytls" then
      {protocol:"anytls",port:.port,anytls_password:.anytls_password,tls_sni:.tls_sni}
    else
      {protocol:"ss2022",transport:(.transport // "shadowtls"),port:.port,
       shadowtls_password:.shadowtls_password,ss2022_password:.ss2022_password,
       method:.method,shadowtls_sni:.shadowtls_sni}
    end' <<<"$user")
  printf '%s' "$entries"
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
    read_singbox_config_source current_source || die "无法解析或格式化运行配置：$(kernel_runtime_config_path)"
    if [[ "$current_source" != "$source_snapshot" ]]; then
      config_json=""
      source_snapshot=""
    fi
  fi
  if [[ -z "$config_json" || -z "$source_snapshot" ]]; then
    load_new_user_config_snapshot config_json source_snapshot ||
      die "无法解析或格式化运行配置：$(kernel_runtime_config_path)"
    printf -v "$config_output_name" '%s' "$config_json"
    printf -v "$source_output_name" '%s' "$source_snapshot"
  fi
  if [[ "$protocol" == ss2022 ]]; then
    tags_json="[\"st-$name\",\"ss-$name\",\"ss-udp-$name\"]"
  else
    tags_json="[\"anytls-$name\"]"
  fi
  conflict_tag="$(jq -r --argjson tags "$tags_json" \
    --arg container "$(kernel_managed_container)" --arg entry_key "$(kernel_managed_key)" '
    [$tags[] as $wanted | select(any(.[$container][]?; .[$entry_key] == $wanted)) | $wanted][0] // empty
  ' <<<"$config_json")" || die "无法解析或格式化运行配置：$(kernel_runtime_config_path)"
  if [[ -n "$conflict_tag" ]]; then
    # 两个分支说的是同一件事，此前一边带 tag 名一边不带；统一成带名字的说法，
    # 便于直接定位是哪个入口撞了。内核名走适配层——这条路径与内核无关。
    die "$(kernel_display_name) 已存在 tag：$conflict_tag"
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
    tag_exists_in_config "anytls-$name" && die "$(kernel_display_name) 已存在 tag：anytls-$name"
  else
    jq -e --arg name "$name" 'any(.users[]? | select(.name == $name) | .endpoints[]?;
      .protocol == "ss2022" and .transport == "shadowtls")' "$STATE_FILE" >/dev/null && has_legacy=true
    if [[ "$has_legacy" == true ]]; then
      tag_exists_in_config "ss-direct-$name" && die "$(kernel_display_name) 已存在 tag：ss-direct-$name"
    else
      tag_exists_in_config "st-$name" && die "$(kernel_display_name) 已存在 tag：st-$name"
      tag_exists_in_config "ss-$name" && die "$(kernel_display_name) 已存在 tag：ss-$name"
      tag_exists_in_config "ss-udp-$name" && die "$(kernel_display_name) 已存在 tag：ss-udp-$name"
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
    tag_exists_in_config "$tag" && die "$(kernel_display_name) 已存在 tag：$tag"
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

# 某个协议下有多少个用户带着对应入口。全局 SNI 的提示、修改与 ShadowTLS 握手目标
# 的预检都要这个数，写三遍迟早只改一处。
count_protocol_sni_users() {
  local protocol="$1"
  jq --arg protocol "$protocol" '[.users[] |
    select(any(if (.endpoints | type) == "array" then .endpoints[]
      else {protocol:(.protocol // "ss2022"),transport:(.transport // "shadowtls")} end;
      .protocol == $protocol and ($protocol != "ss2022" or .transport == "shadowtls")))] | length' "$STATE_FILE"
}

# 实际在用的握手目标域名，去重。mihomo 的监听器是按**用户状态里的**
# shadowtls_sni 生成的，不是按管理配置里的默认值——两者通常一致，但生成的来源
# 是前者，所以预检也要按前者来问（公开 Issue #194）。
active_shadowtls_handshake_hosts() {
  jq -r '[.users[]? |
    (if (.endpoints | type) == "array" then .endpoints[]
     else {protocol:(.protocol // "ss2022"),transport:(.transport // "shadowtls"),shadowtls_sni:.shadowtls_sni} end) |
    select(.protocol == "ss2022" and .transport == "shadowtls") |
    (.shadowtls_sni // empty)] | unique | .[]' "$STATE_FILE"
}

cmd_set_global_sni() {
  local protocol="$1" new_sni="$2" current_sni total mismatched active_count
  validate_shadowtls_sni "$new_sni"
  case "$protocol" in
    ss2022) current_sni="$SS2022_SHADOWTLS_SNI";;
    anytls) current_sni="$ANYTLS_SNI";;
    *) die "未知 SNI 协议：$protocol";;
  esac
  total="$(count_protocol_sni_users "$protocol")" || return 1
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

  # 换握手目标之前先探一次（公开 Issue #194）。放在改动任何东西之前：严格模式下
  # 换成一个不支持 TLS 1.3 的域名，会让这台机器上所有 ShadowTLS 用户静静连不上，
  # 而配置校验与启动日志都不会提示。网络本身探不通只提示不拦——那多半是临时
  # 问题，硬拦会变成「网络一抖就改不了配置」。
  if [[ "$protocol" == ss2022 ]] && shadowtls_handshake_probe_applies; then
    case "$(probe_handshake_tls13 "$new_sni" "$HANDSHAKE_PORT")" in
      tls13) log "已确认握手目标 ${new_sni}:${HANDSHAKE_PORT} 支持 TLS 1.3";;
      tls-older)
        printf '错误：%s:%s 不支持 TLS 1.3。严格模式开着时换成它，本机所有 ShadowTLS 用户都会连不上，而服务日志不会报错。请换一个支持 TLS 1.3 的域名。\n' \
          "$new_sni" "$HANDSHAKE_PORT" >&2
        return 1;;
      not-tls)
        printf '错误：%s:%s 上不是 TLS 服务。ShadowTLS 要把握手转给一台真正的 TLS 1.3 服务器，换成它会让本机所有 ShadowTLS 用户连不上。请换一个域名。\n' \
          "$new_sni" "$HANDSHAKE_PORT" >&2
        return 1;;
      invalid)
        printf '错误：握手目标 %s:%s 的域名或端口不合法，未做修改。\n' "$new_sni" "$HANDSHAKE_PORT" >&2
        return 1;;
      *)
        printf '提示：这次没能连上 %s:%s，未能确认它是否支持 TLS 1.3。修改会照常进行；若之后 ShadowTLS 用户连不上，先回来核对这个域名。\n' \
          "$new_sni" "$HANDSHAKE_PORT";;
    esac
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

# 一个规则文件名在 mihomo 部署下的完整路径。
# 只接受目录下的一层文件名：SAFE_PATHS 覆盖的是这个目录，
# 而「只填文件名」也是界面上唯一需要使用者理解的东西。
mihomo_rule_file_path() {
  printf '%s/%s' "$MIHOMO_RULES_DIR" "$1"
}

validate_mihomo_rule_file_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] ||
    die "规则文件名只能包含字母、数字、点、下划线和连字符，长度 1-64，且不能以点开头"
}

# 规则文件的写法与配置里声明的 behavior 是否对得上。
#
# 这条检查存在的唯一理由是 **mihomo 在这件事上是静默的**：把「完整规则行」
# 按「域名列表」读，一条警告都没有，规则就是静静地不生效（公开 Issue #186 实测，
# 反方向只有 warning，也不会让服务起不来）。内核不报，就只能管理器来报。
#
# 刻意只在**确定对不上**时才拒绝，不做风格审查：这条护栏一旦误报，
# 使用者会学会绕过它，那比没有还糟。
# 输出第一条对不上的内容；全部合规时无输出。
mihomo_rule_file_mismatch() {
  local file="$1" behavior="$2"
  awk -v behavior="$behavior" '
    function trim(text) {
      sub(/^[[:space:]]+/, "", text); sub(/[[:space:]]+$/, "", text)
      return text
    }
    /^[[:space:]]*payload[[:space:]]*:/ { seen_payload = 1; next }
    {
      line = $0
      sub(/[[:space:]]*#.*$/, "", line)
      line = trim(line)
      if (line == "") next
      if (line !~ /^-[[:space:]]*/) next
      sub(/^-[[:space:]]*/, "", line)
      item = trim(line)
      gsub(/^["'"'"']|["'"'"']$/, "", item)
      if (item == "") next
      items++
      looks_like_rule = (item ~ /^[A-Z][A-Z0-9_-]*,/)
      if (behavior == "classical") {
        if (!looks_like_rule) { print "第 " NR " 行不是完整规则行：" item; exit }
      } else if (behavior == "domain") {
        if (looks_like_rule) { print "第 " NR " 行看着是完整规则行而不是域名：" item; exit }
      } else if (behavior == "ipcidr") {
        if (looks_like_rule) { print "第 " NR " 行看着是完整规则行而不是 IP 段：" item; exit }
        # 前缀长度可有可无：社区的 IP 清单里裸写一个地址是常见写法，
        # 为此报错就成了误报，而误报的护栏会被人学会绕过去。
        if (item !~ /^[0-9.]+(\/[0-9]+)?$/ && item !~ /^[0-9a-fA-F:]+(\/[0-9]+)?$/) {
          print "第 " NR " 行不是 IP 段写法：" item; exit
        }
      }
    }
    END {
      if (!seen_payload) { print "整个文件里没有 payload: 这一行"; exit }
      if (items == 0) { print "payload: 下面一条规则都没有"; exit }
    }
  ' "$file"
}

# ============================================================
# 远程规则集（公开 Issue #218）
# ============================================================
# mihomo 原生支持 `type:http` 的规则集：启动时自己下载、按 interval 自己更新，
# 不用管理器造更新机制。实测（v1.19.30）确认了这三件事：会下载并写到 path、
# 到点会自己重新拉、取不到但本地有缓存时会用旧的。
#
# **但取不到且没有缓存时它只留一行警告，服务照常起来，那条分流静静地完全不生效。**
# 这与本机文件被删掉是同一类失效（公开 Issue #186）。内核不报，只能管理器来报——
# 因此保存那一刻由管理器自己先下载一次、校验一遍，并把内容落成初始缓存。
REMOTE_RULE_SET_UPDATE_INTERVAL=86400

# 远程规则集在本机的文件名：**原样取地址里的那个文件名**，不做改写。
# 项目所有者的要求是「保持原有命名以方便识别」，因此这里宁可拒绝也不悄悄改名。
remote_rule_set_file_name() {
  local url="$1" name
  name="${url##*/}"
  name="${name%%\?*}"
  name="${name%%#*}"
  printf '%s' "$name"
}

# 远程规则集地址的写法校验。只看写法，不下载。
# 只接受 yaml：mihomo 还认 text 与 mrs 两种格式，本片不做——与 sing-box 侧只接受
# .srs／.json 是同一个思路，多一种格式就多一套校验与一种说不清的失败。
validate_remote_rule_set_url() {
  local url="$1" name
  [[ "$url" == https://* ]] || die "规则集地址必须使用 HTTPS：$url"
  [[ "$url" =~ \.(yaml|yml)$ ]] ||
    die "规则集地址必须指向 .yaml 或 .yml 文件（本项目只支持 yaml 格式的远程规则集）：$url"
  name="$(remote_rule_set_file_name "$url")"
  [[ -n "$name" ]] || die "从地址里看不出文件名：$url"
  validate_mihomo_rule_file_name "$name"
}

# 下载远程规则集并校验内容，成功后写到 $2。
# 五件要挡住的事在这里挡掉四件（地址写法在上面那个函数）：指向内网、取不到、
# 内容不是规则集、写法与所选 behavior 对不上。失败时**不写出文件**。
#
# 失败一律用返回码表达，不用 die：这个函数也给「立即更新规则集」用，那条路上
# 一条地址取不到不该把整轮更新连同管理器一起结束——其余几条还要继续更新，
# 而且旧缓存必须原样留着。调用点因此必须自己检查返回值。
download_remote_rule_set() {
  local url="$1" output="$2" behavior="$3" tmp mismatch
  if ! validate_public_rule_set_url "$url"; then
    printf '错误：规则集地址必须解析到公网，不能指向本机或内网：%s\n' "$url" >&2
    return 1
  fi
  tmp="$(mktemp /tmp/sb-remote-rule.XXXXXX)" || return 1
  register_temp_path "$tmp" || { rm -f -- "$tmp"; return 1; }
  # 不跟随跳转、限时限量：规则集是使用者贴进来的地址，按不可信输入对待。
  if ! curl --proto '=https' --proto-redir '=https' --fail --max-redirs 0 \
    --silent --show-error --connect-timeout 10 --max-time 60 \
    --max-filesize 10485760 --output "$tmp" "$url"; then
    rm -f -- "$tmp"
    unregister_temp_path "$tmp" || true
    printf '错误：取不到规则集：%s\n' "$url" >&2
    return 1
  fi
  mismatch="$(mihomo_rule_file_mismatch "$tmp" "$behavior")" || {
    rm -f -- "$tmp"
    unregister_temp_path "$tmp" || true
    return 1
  }
  if [[ -n "$mismatch" ]]; then
    rm -f -- "$tmp"
    unregister_temp_path "$tmp" || true
    printf '错误：规则集的内容与所选写法对不上：%s\n' "$mismatch" >&2
    printf '选错写法时 mihomo 不会报错，规则会静静地不生效，因此这里必须拒绝。\n' >&2
    return 1
  fi
  install -m 644 "$tmp" "$output" || {
    rm -f -- "$tmp"
    unregister_temp_path "$tmp" || true
    return 1
  }
  rm -f -- "$tmp"
  unregister_temp_path "$tmp" || true
}

# 这个文件名有没有被**另一个地址**占用。同一个地址被多条分流共用不算冲突。
remote_rule_set_name_conflict() {
  local name="$1" url="$2"
  jq -r --arg name "$name" --arg url "$url" '
    [(.splits[]?, .rule_presets[]?) |
      select((.rule_file // "") == $name and (.rule_url // "") != $url) |
      (.name // "")] | first // empty' "$STATE_FILE"
}

# 一条分流／预置的远程地址；本机文件来源时为空。
split_rule_url_from_json() {
  jq -r '(.rule_url // "")' <<<"$1"
}

# 当前用到的远程规则集清单：地址、落地文件名、写法。分流与预置放在一起去重，
# 因为它们共用同一个文件——同一个地址被多条分流引用时只该下载一次。
remote_rule_set_rows() {
  jq -r '[(.splits[]?, .rule_presets[]?) |
      select((.rule_url // "") != "" and (.rule_file // "") != "") |
      {url:.rule_url, file:.rule_file, behavior:(.rule_behavior // "")}] |
    unique | .[] | [.url, .file, .behavior] | @tsv' "$STATE_FILE"
}

# 运行配置里现在还有没有 geo 规则。判断依据与 sbm_apply_geo_settings 完全一致，
# 用的是同一段 jq——两处各写一遍迟早会对不上。
mihomo_runtime_uses_geo() {
  local config
  config="$(singbox_config_for_comparison)" || return 1
  jq -e "$MIHOMO_GEO_SETTINGS_PROGRAM"'
    (sbm_apply_geo_settings | has("geodata-mode"))' --argjson geox '{}' <<<"$config" >/dev/null
}

# 把当前的 geo 设置写进运行配置。留空的那一项会让 geox-url 里少一个键，
# 两个都留空就整个删掉这个键，回到 mihomo 自带的源。
apply_mihomo_geo_settings() {
  rewrite_kernel_config "$MIHOMO_GEO_SETTINGS_PROGRAM"'
    sbm_apply_geo_settings
  ' --argjson geox "$(mihomo_geox_url_json)"
}

# 「geo 数据源」设置项（公开 Issue #219）。$1 是 geosite 或 geoip，$2 是新地址，
# 留空表示改回 mihomo 自带的源。
#
# 校验放在改动任何东西之前：项目所有者的要求是「改成死地址时当场拒绝并保持原值」。
# 这条校验只证明这个地址现在取得到东西，不证明取到的是一份能用的 geo 数据库
# ——后者要等真的用到 geo 分流时由 mihomo 说，而它在那一步是当场失败、不是静默失效。
cmd_set_geo_source() {
  local kind="$1" new_url="${2:-}" label geosite_url geoip_url uses_geo=false
  [[ "$PROXY_KERNEL" == mihomo ]] ||
    die "只有 mihomo 部署会用到 GeoSite／GeoIP 数据；sing-box 部署没有这一项"
  geosite_url="$GEOSITE_URL"
  geoip_url="$GEOIP_URL"
  case "$kind" in
    geosite) label='GeoSite 数据源'; geosite_url="$new_url" ;;
    geoip) label='GeoIP 数据源'; geoip_url="$new_url" ;;
    *) die "未知的 geo 数据源：$kind" ;;
  esac
  if [[ "$geosite_url" == "$GEOSITE_URL" && "$geoip_url" == "$GEOIP_URL" ]]; then
    log "${label}没有变化，未做修改"
    return 0
  fi
  [[ -z "$new_url" ]] || validate_geo_source_url "$new_url" "$label"
  if mihomo_runtime_uses_geo; then uses_geo=true; fi
  if [[ "$uses_geo" == true ]]; then
    ensure_safe_ssh_for_kernel_restart || return 0
  fi
  start_managed_operation "set-geo-source:$kind" || return 1
  run_managed_step write_geo_source_config "$geosite_url" "$geoip_url" update || return 1
  run_managed_step apply_mihomo_geo_settings || return 1
  if [[ "$uses_geo" == true ]]; then
    run_managed_step check_singbox_and_restart || return 1
  fi
  finish_managed_operation || return 1
  if [[ -n "$new_url" ]]; then
    log "${label}已改为：${new_url}"
  else
    log "${label}已改回 mihomo 自带的源"
  fi
  if [[ "$uses_geo" != true ]]; then
    echo '这台机器目前没有用到 geo 规则，新的数据源会在第一次添加 geo 分流时生效。'
  fi
}

# 「立即更新规则集」（公开 Issue #218）。
#
# mihomo 自己每天更新一次，这个动作是给「现在就要用上新规则」准备的。
# 新内容要立刻生效必须重启内核：不重启的话它要等下一个 interval 才重新读文件，
# 那可能是一天以后。重启会断几秒，因此有三条硬要求：
#
#   一、**远端挂掉时保留旧缓存**。先下载到临时文件、校验通过才覆盖；一条失败
#       不影响其余几条，也绝不会把那条分流变成空规则。
#   二、**内容没变就不重启**。没有变化的重启是白白断几秒。
#   三、**重启失败时把旧文件放回去再起一次**。规则集的内容是使用者从社区拿来的，
#       保存时那套校验只保证「是个规则集、写法与 behavior 对得上」，不保证
#       mihomo 认得里面每一条规则。
cmd_remote_rule_sets_update() {
  local rows url file behavior path staged workdir restart_rc
  local total=0 changed=0 failed=0 unchanged=0
  [[ "$PROXY_KERNEL" == mihomo ]] ||
    die "只有 mihomo 部署支持远程规则集；sing-box 的规则集由 sing-box 自己下载"
  rows="$(remote_rule_set_rows)" || return 1
  if [[ -z "$rows" ]]; then
    echo '当前没有使用网址来源的规则集，没有可更新的内容。'
    return 0
  fi
  # SSH 护栏放在下载之前。它给出的说明是「服务器数据尚未修改」，先写文件再问
  # 会让那句话变成假话，而且会留下「文件已经换了、内核还没读」的半吊子状态。
  ensure_safe_ssh_for_kernel_restart || return 0
  workdir="$(mktemp -d /tmp/sb-rule-update.XXXXXX)" || return 1
  register_temp_path "$workdir" || { rm -rf -- "$workdir"; return 1; }
  printf '\n开始更新规则集：\n'
  while IFS=$'\t' read -r url file behavior; do
    [[ -n "$url" && -n "$file" ]] || continue
    total=$((total + 1))
    path="$(mihomo_rule_file_path "$file")"
    staged="$workdir/new.$file"
    if ! download_remote_rule_set "$url" "$staged" "$behavior"; then
      printf '  [失败] %s：这一条仍然沿用上一次的内容\n' "$file"
      failed=$((failed + 1))
      continue
    fi
    if [[ -f "$path" ]] && cmp -s "$staged" "$path"; then
      printf '  [没有变化] %s\n' "$file"
      unchanged=$((unchanged + 1))
      continue
    fi
    if [[ -f "$path" ]] && ! cp -p -- "$path" "$workdir/old.$file"; then
      printf '  [失败] %s：无法备份现有内容，这一条没有更新\n' "$file"
      failed=$((failed + 1))
      continue
    fi
    if ! install -m 644 "$staged" "$path"; then
      printf '  [失败] %s：无法写入 %s，这一条没有更新\n' "$file" "$path"
      failed=$((failed + 1))
      continue
    fi
    printf '  [已更新] %s\n' "$file"
    changed=$((changed + 1))
  done <<<"$rows"
  printf '\n共 %s 条：更新 %s 条，内容没有变化 %s 条，失败 %s 条。\n' \
    "$total" "$changed" "$unchanged" "$failed"
  if ((changed == 0)); then
    echo '没有内容发生变化，不需要重启，连接不受影响。'
    ((failed == 0)) || return 1
    return 0
  fi
  printf '正在重启 %s 让新规则立刻生效，现有连接会中断几秒。\n' "$(kernel_display_name)"
  restart_rc=0
  if check_singbox_and_restart; then
    :
  else
    restart_rc=$?
  fi
  if ((restart_rc == 0)); then
    log "规则集已更新并生效：${changed} 条"
    ((failed == 0)) || return 1
    return 0
  fi
  # 起不来就把旧内容放回去再起一次。这里的失败多半来自新规则集的内容——
  # 保存时那套校验管不到 mihomo 认不认得里面每一条规则。
  printf '错误：重启失败，正在把规则集恢复成更新之前的内容。\n' >&2
  restore_remote_rule_set_backups "$workdir" || true
  if check_singbox_and_restart; then
    printf '已恢复到更新之前的规则集，服务正常。请检查这几个规则集的内容。\n' >&2
  else
    printf '错误：恢复之后仍未能启动服务，请用「检查与故障报告」进一步排查。\n' >&2
  fi
  return "$restart_rc"
}

# 把 cmd_remote_rule_sets_update 备份下来的旧规则集放回原处。
restore_remote_rule_set_backups() {
  local workdir="$1" backup name rc=0
  for backup in "$workdir"/old.*; do
    [[ -f "$backup" ]] || continue
    name="${backup##*/old.}"
    install -m 644 "$backup" "$(mihomo_rule_file_path "$name")" || rc=1
  done
  return "$rc"
}

# ============================================================
# GeoSite／GeoIP 类别（公开 Issue #219）
# ============================================================
# 第三种规则来源，与前两种最要紧的差别是**它不会静默失效**：数据库缺了、类别名
# 写错，mihomo 当场拒绝加载配置（实测；换成正确的类别名就通过，对照成立）。
# 远程规则集正相反——取不到只留一行警告、服务照常起来，那条分流静静地不生效。
# 代价换到了另一头：/var/lib/mihomo 下的数据库丢了且当时下不到，服务起不来。
GEO_UPDATE_INTERVAL_HOURS=24

# 「geo 数据源」设置项的当前取值，渲染成 mihomo 的 geox-url 对象。
# 两个地址各自独立：只改一个时，另一个仍用 mihomo 自带的源。
# 键名 geosite／geoip 取自二进制里的结构体标签，不是猜的。
mihomo_geox_url_json() {
  jq -cn --arg geosite "${GEOSITE_URL:-}" --arg geoip "${GEOIP_URL:-}" '
    {} | (if $geosite == "" then . else .geosite = $geosite end)
       | (if $geoip == "" then . else .geoip = $geoip end)'
}

# 一条 geo 类别的写法。类别名对不对不在这里判——那要看 mihomo 自己的数据库，
# 由保存时那次 `mihomo -t` 当场认。这里只保证它不会把一条规则拼成另一条：
# 类别名里混进逗号或括号时，mihomo 只会说「规则类型不支持」，看不出是从哪来的。
validate_geo_category() {
  [[ "$1" =~ ^(GEOSITE|GEOIP),[A-Za-z0-9_.:@!-]+$ ]] ||
    die "geo 类别只能写成 GEOSITE,<类别> 或 GEOIP,<类别>；类别名只能用字母、数字与 _ . : @ ! -（\`!\` 用于 category-ai-!cn 这类「排除」写法），不能有第二个逗号、括号或空格：$1"
}

# 状态里的 geo 类别清单（JSON 数组）；不是 geo 来源时是空数组。
split_rule_geo_from_json() {
  jq -c '(.rule_geo // [])' <<<"$1"
}

validate_geo_categories_json() {
  local geo="$1" category
  jq -e 'type == "array" and length > 0' <<<"$geo" >/dev/null ||
    die "至少要填一个 GeoSite／GeoIP 类别"
  while IFS= read -r category; do
    [[ -n "$category" ]] || continue
    validate_geo_category "$category"
  done < <(jq -r '.[]' <<<"$geo")
  [[ "$(jq 'length' <<<"$geo")" == "$(jq 'unique | length' <<<"$geo")" ]] ||
    die "同一条分流里不能重复填同一个 geo 类别"
}

# 用 mihomo 自己校验类别名。类别名写错时 `mihomo -t` 当场失败，写对就通过
# ——这条判断有对照，因此拒绝不是恒真。
#
# 副作用要如实告知：**第一次会触发下载**。mihomo 发现工作目录里没有 GeoSite.dat
# 就自己去下（4 MB 左右；用到 GeoIP 再加 17 MB），网络慢时要等一会。
# 探针配置里每个类别单独写一行，为的是失败时 mihomo 的报错能指名道姓说出
# 是哪一个类别不认识——写成一条 OR 的话只能看出「这一整条不行」。
validate_geo_categories_with_kernel() {
  local geo="$1" probe binary rc=0
  [[ "$PROXY_KERNEL" == mihomo ]] || die "GeoSite／GeoIP 类别分流只支持 mihomo 部署"
  binary="$(kernel_binary_path)" || return 1
  probe="$(mktemp /tmp/sb-geo-probe.XXXXXX)" || return 1
  register_temp_path "$probe" || { rm -f -- "$probe"; return 1; }
  if ! jq -n --argjson geo "$geo" --argjson geox "$(mihomo_geox_url_json)" \
      --argjson interval "$GEO_UPDATE_INTERVAL_HOURS" '
      {"log-level":"warning",mode:"rule","geodata-mode":true,"geo-auto-update":true,
       "geo-update-interval":$interval,listeners:[],proxies:[],"proxy-groups":[],
       rules:([$geo[] | . + ",DIRECT"] + ["MATCH,DIRECT"])}
      | (if ($geox | length) == 0 then . else .["geox-url"] = $geox end)' > "$probe"; then
    rm -f -- "$probe"
    unregister_temp_path "$probe" || true
    return 1
  fi
  kernel_check_config_with "$binary" "$probe" || rc=1
  rm -f -- "$probe"
  unregister_temp_path "$probe" || true
  return "$rc"
}

# geo 数据源地址的校验（公开 Issue #219）。「改成死地址时当场拒绝并保持原值」。
#
# 只取头 1 KB：这两个文件一个 4 MB、一个 17 MB，为了确认地址还活着而整份拉下来
# 不划算。**要说清这条校验证明了什么**——它证明这个地址现在取得到东西，
# 不证明取到的是一份能用的 geo 数据库。后者要等真的用到 geo 分流时由 mihomo
# 自己说，而它在那一步是当场失败、不是静默失效。
validate_geo_source_url() {
  local url="$1" label="$2" code
  [[ "$url" == https://* ]] || die "${label}的地址必须使用 HTTPS：$url"
  validate_public_rule_set_url "$url" ||
    die "${label}的地址必须解析到公网，不能指向本机或内网：$url"
  code="$(curl --proto '=https' --proto-redir '=https' --silent --show-error \
    --max-redirs 0 --connect-timeout 10 --max-time 60 --max-filesize 67108864 \
    --range 0-1023 --output /dev/null --write-out '%{http_code}' "$url" 2>/dev/null)" || code=''
  case "$code" in
    200|206) return 0 ;;
    '') die "${label}的地址取不到内容，原值保持不变：$url" ;;
    *) die "${label}的地址返回了 HTTP ${code}，原值保持不变：$url" ;;
  esac
}

# mihomo 部署下的规则集来源：使用者自己放在规则目录里的一个块状 yaml 文件。
# 管理器只读它，永远不改它的内容（公开 Issue #157 的决定）。
validate_mihomo_rule_set() {
  local name="$1" behavior="$2" path mismatch
  validate_mihomo_rule_file_name "$name"
  case "$behavior" in
    classical|domain|ipcidr) ;;
    *) die "规则写法只能是 classical、domain 或 ipcidr：$behavior" ;;
  esac
  path="$(mihomo_rule_file_path "$name")"
  # 「文件在不在」是 mihomo -t 唯一测不出的一项：文件不存在时配置检查照样通过，
  # 服务也照样起得来，只在启动日志里留一行 error，规则则完全不生效
  # （公开 Issue #186 实测，与证书路径同一个毛病的镜像版本）。
  # 因此这里必须真的看一眼，不能等内核来说。
  [[ ! -L "$path" ]] || die "规则文件不能是符号链接：$path"
  [[ -f "$path" ]] || die "规则文件不存在：${path}；请先把规则文件放到 ${MIHOMO_RULES_DIR} 下"
  [[ -r "$path" ]] || die "规则文件无法读取：$path"
  mismatch="$(mihomo_rule_file_mismatch "$path" "$behavior")" || return 1
  [[ -z "$mismatch" ]] ||
    die "规则文件的内容与所选写法对不上：${mismatch}；选错写法时 mihomo 不会报错，规则会静静地不生效"
}

# 来源写法的校验。与「这个来源可不可用」分开：这一条只看写法，
# 界面上输入即时反馈用得到，不需要下载或读文件。
validate_split_rule_source_format() {
  case "$PROXY_KERNEL" in
    singbox)
      [[ "$1" == https://* ]] || die "规则集地址必须使用 HTTPS"
      split_rule_format "$1" >/dev/null || die "规则集地址必须指向 .srs 或 .json 文件"
      ;;
    mihomo) validate_mihomo_rule_file_name "$1" ;;
    *) kernel_unknown ;;
  esac
}

# 规则集来源的校验。两个内核的来源完全不同，格式也不通用：
# sing-box 是公网 HTTPS 上的 .srs / .json，由 sing-box 自己下载并检查；
# mihomo 是本机上一个块状 yaml 文件，由管理器检查存在性与写法。
validate_split_rule_source() {
  local source="$1" behavior="${2:-}" rule_url="${3:-}" rule_geo="${4:-[]}" conflict
  # geo 来源（公开 Issue #219）：没有规则集文件，也没有 behavior 可言，
  # 状态里只有一份类别清单。写法自己查，类别名交给 mihomo 当场认。
  if [[ "$(jq 'length' <<<"$rule_geo")" != 0 ]]; then
    [[ "$PROXY_KERNEL" == mihomo ]] || die "GeoSite／GeoIP 类别分流只支持 mihomo 部署"
    [[ -z "$rule_url" ]] || die "geo 类别来源不能同时带规则集网址"
    validate_geo_categories_json "$rule_geo"
    validate_geo_categories_with_kernel "$rule_geo" || return 1
    return 0
  fi
  # 远程来源（公开 Issue #218）：先看写法与重名，再**真的下载一次**并核对内容。
  # mihomo 取不到远程规则集时只留一行警告、服务照常起来，那条分流静静地不生效；
  # 因此这一关必须在保存之前由管理器自己过一遍，并把这次下载的内容落成初始缓存。
  if [[ -n "$rule_url" ]]; then
    [[ "$PROXY_KERNEL" == mihomo ]] || die "远程规则集只支持 mihomo 部署"
    validate_remote_rule_set_url "$rule_url"
    [[ "$source" == "$(remote_rule_set_file_name "$rule_url")" ]] ||
      die "规则文件名必须与地址里的文件名一致：$source"
    conflict="$(remote_rule_set_name_conflict "$source" "$rule_url")" || return 1
    [[ -z "$conflict" ]] ||
      die "规则文件名 ${source} 已经被「${conflict}」用在另一个地址上；请换一个来源，或先处理那一条"
    download_remote_rule_set "$rule_url" "$(mihomo_rule_file_path "$source")" "$behavior" || return 1
    return 0
  fi
  case "$PROXY_KERNEL" in
    singbox)
      validate_public_rule_set_url "$source" ||
        die "远程规则集地址必须使用 HTTPS，且不能指向本机或内网地址"
      check_rule_set_with_binary "$SINGBOX_BIN" "$source" ||
        die "远程规则集无法通过当前 sing-box 检查，请确认地址、格式和版本兼容性"
      ;;
    mihomo) validate_mihomo_rule_set "$source" "$behavior" ;;
    *) kernel_unknown ;;
  esac
}

# 规则集来源在状态里的取值。两个键在同一台机器上不会同时存在
# （见适配层的 kernel_rule_source_key），因此读取写成一个表达式即可。
split_rule_source_from_json() {
  jq -r '(.url // .rule_file // "")' <<<"$1"
}

split_rule_behavior_from_json() {
  jq -r '(.rule_behavior // "")' <<<"$1"
}

# 规则来源在界面上的写法。sing-box 是完整地址，mihomo 是文件名加写法说明。
split_rule_source_display() {
  local source="$1" behavior="$2"
  case "$PROXY_KERNEL" in
    singbox) printf '%s' "$source" ;;
    mihomo) printf '%s（%s）' "$(mihomo_rule_file_path "$source")" "$(mihomo_rule_behavior_label "$behavior")" ;;
    *) kernel_unknown ;;
  esac
}

mihomo_rule_behavior_label() {
  case "$1" in
    classical) printf '完整规则行' ;;
    domain) printf '域名列表' ;;
    ipcidr) printf 'IP 段列表' ;;
    *) printf '未知写法' ;;
  esac
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

# 一条分流在 mihomo 规则行里的匹配条件（公开 Issue #219）。生成、删除与审计
# 必须用同一份定义，因此这里直接调用适配层那段 jq，不在别处再写一遍。
mihomo_split_match_condition() {
  local rule_tag="$1" rule_geo="${2:-[]}"
  jq -rn --arg rule "$rule_tag" --argjson geo "$rule_geo" \
    "$MIHOMO_SPLIT_RULE_DEFS"' sbm_match_cond($rule; $geo)'
}

remove_split_config() {
  local name="$1" split tag out_tag transport_tag stored_tag stored_out stored_transport
  local rule_geo cond stored_cond
  split="$(jq -ec --arg name "$name" '.splits[] | select(.name == $name)' "$STATE_FILE")" || return 1
  tag="$(split_runtime_rule_tag_from_json "$split")" || return 1
  out_tag="$(split_runtime_out_tag_from_json "$split")" || return 1
  transport_tag="$(split_runtime_transport_tag_from_json "$split")" || return 1
  stored_tag="$(stored_split_rule_tag "$name")" || return 1
  stored_out="$(stored_split_out_tag "$name")" || return 1
  stored_transport="$(split_transport_tag "$name")"
  rule_geo="$(split_rule_geo_from_json "$split")" || return 1
  cond="$(mihomo_split_match_condition "$tag" "$rule_geo")" || return 1
  stored_cond="$(mihomo_split_match_condition "$stored_tag" "$rule_geo")" || return 1
  case "$PROXY_KERNEL" in
    singbox)
      rewrite_kernel_config '
        .route.rules = [(.route.rules // [])[] | select(((.rule_set // "") == $tag or (.rule_set // "") == $stored_tag) | not)] |
        .route.rule_set = [(.route.rule_set // [])[] | select((.tag == $tag or .tag == $stored_tag) | not)] |
        .outbounds = [(.outbounds // [])[] |
          select((.tag == $out_tag or .tag == $transport_tag or .tag == $stored_out or .tag == $stored_transport) | not)]
      ' --arg tag "$tag" --arg stored_tag "$stored_tag" --arg out_tag "$out_tag" --arg transport_tag "$transport_tag" \
        --arg stored_out "$stored_out" --arg stored_transport "$stored_transport"
      ;;
    mihomo)
      # 托管的分流条目分布在三处：proxies 里的出口、rule-providers 里的规则集、
      # 以及 sub-rules 里那一块规则。顶层 rules 里只有一条派发，
      # 它与具体某条分流无关，因此这里不动——使用者自己写在 rules 里的东西同理。
      #
      # sub-rules 里按**匹配条件**认自己的行。行的形状只有两种，都由
      # kernel_render_split_plan 生成：
      #   <匹配条件>,<出口>
      #   AND,((<匹配条件>),(IN-NAME,...)),<出口>
      # 规则集来源的条件是 RULE-SET,<规则集标签>，geo 来源的条件是类别本身
      # （公开 Issue #219）——后者没有标签可认，因此这里统一按条件认。
      # 与 sing-box 那一支同样按标签删，因此「多条分流共用同一个预置规则时
      # 一起被删掉」这个语义两个内核一致，随后的整体重建会把该留的补回来。
      rewrite_kernel_config "$MIHOMO_SPLIT_RULE_DEFS"'
        .proxies = [(.proxies // [])[] |
          select((.name == $out_tag or .name == $transport_tag or .name == $stored_out or .name == $stored_transport) | not)] |
        .["rule-providers"] = ((.["rule-providers"] // {}) |
          with_entries(select(.key != $tag and .key != $stored_tag))) |
        (if (.["sub-rules"] // {}) | has($sub_rule) then
           .["sub-rules"][$sub_rule] = [(.["sub-rules"][$sub_rule] // [])[] |
             select(sbm_line_owned_by(.; [$cond, $stored_cond]) | not)]
         else . end)
      ' --arg tag "$tag" --arg stored_tag "$stored_tag" --arg out_tag "$out_tag" --arg transport_tag "$transport_tag" \
        --arg stored_out "$stored_out" --arg stored_transport "$stored_transport" \
        --arg cond "$cond" --arg stored_cond "$stored_cond" \
        --arg sub_rule "$MIHOMO_MANAGED_SUB_RULE"
      ;;
    *) kernel_unknown ;;
  esac
}

# 上游出口的托管条目。形状与条目数量都随内核不同，因此实现在适配层，
# 这里只补上「没有显式给传输标签时用默认名」这一条与内核无关的规则。
build_split_outbounds() {
  local name="$1" upstream="$2" out_tag="$3" transport_tag="${4:-}"
  [[ -n "$transport_tag" ]] || transport_tag="$(split_transport_tag "$name")"
  kernel_split_outbounds "$name" "$upstream" "$out_tag" "$transport_tag"
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
  local upstream="$1" name out_tag outbounds candidate container runtime_config
  validate_upstream_json "$upstream" || die "预置出口内容不完整或格式无效"
  name="preset-check-${BASHPID:-$$}"
  out_tag="${name}-out"
  outbounds="$(build_split_outbounds "$name" "$upstream" "$out_tag")" || return 1
  candidate="$(mktemp /tmp/sb-preset-outbound.XXXXXX.json)" || return 1
  register_temp_path "$candidate"
  # 出口容器的键名随内核不同（sing-box 的 outbounds、mihomo 的 proxies），
  # 校验用的也必须是当前内核自己的运行配置——拿 mihomo 去检查一份
  # sing-box 配置，报出来的东西没有任何意义。
  container="$(kernel_split_outbound_container)" || return 1
  runtime_config="$(kernel_runtime_config_path)" || return 1
  if ! SB_JQ_OUTBOUNDS="$outbounds" jq --arg container "$container" \
        '($ENV.SB_JQ_OUTBOUNDS | fromjson) as $outbounds | .[$container] = ((.[$container] // []) + $outbounds)' \
        "$runtime_config" > "$candidate" ||
     ! kernel_check_config "$candidate" >/dev/null 2>&1; then
    rm -f -- "$candidate"
    die "预置出口无法通过当前 $(kernel_display_name) 检查，请确认协议和连接参数"
  fi
  rm -f -- "$candidate"
}

collect_managed_split_tags_with_shell_tools() {
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

collect_managed_split_tags() {
  local fast_rc
  if ! command -v python3 >/dev/null 2>&1; then
    collect_managed_split_tags_with_shell_tools
    return
  fi
  if python3 - "$STATE_FILE" <<'PY'
import hashlib
import json
import sys

prefixes = {
    "rule": "mpr-",
    "outbound": "mpo-",
    "transport": "mpt-",
}


class ShellFallbackRequired(Exception):
    pass


def stable_tag(kind, name):
    digest = hashlib.sha256(f"{kind}:{name}".encode("utf-8")).hexdigest()[:24]
    return prefixes[kind] + digest


def optional_text(split, key, default=""):
    value = split.get(key)
    if value is None or value is False:
        return default
    if not isinstance(value, str):
        raise ShellFallbackRequired
    return value


try:
    with open(sys.argv[1], "r", encoding="utf-8") as state_file:
        state = json.load(state_file)
    if not isinstance(state, dict):
        raise ValueError("state must be an object")
    splits = state.get("splits")
    if not isinstance(splits, list):
        raise ValueError("splits must be an array")
    rule_tags = set()
    out_tags = set()
    transport_tags = set()
    for split in splits:
        if not isinstance(split, dict) or not isinstance(split.get("name"), str):
            raise ShellFallbackRequired
        name = split["name"]
        rule_preset = optional_text(split, "rule_preset")
        outbound_preset = optional_text(split, "outbound_preset")
        stored_rule = optional_text(split, "rule_set_tag", "managed-split-" + name)
        stored_out = optional_text(split, "outbound_tag", "managed-out-" + name)
        stored_transport = "managed-transport-" + name
        runtime_rule = optional_text(split, "runtime_rule_tag")
        runtime_out = optional_text(split, "runtime_outbound_tag")
        runtime_transport = optional_text(split, "runtime_transport_tag")
        rule_tags.update((runtime_rule or (stable_tag("rule", rule_preset) if rule_preset else stored_rule), stored_rule))
        out_tags.update((runtime_out or (stable_tag("outbound", outbound_preset) if outbound_preset else stored_out), stored_out))
        transport_tags.update((runtime_transport or (stable_tag("transport", outbound_preset) if outbound_preset else stored_transport), stored_transport))
    print(json.dumps({
        "rule_tags": sorted(rule_tags),
        "out_tags": sorted(out_tags),
        "transport_tags": sorted(transport_tags),
    }, ensure_ascii=False, separators=(",", ":")))
except ShellFallbackRequired:
    sys.exit(75)
except (OSError, UnicodeError, ValueError, TypeError, json.JSONDecodeError):
    sys.exit(1)
PY
  then
    return 0
  else
    fast_rc=$?
  fi
  if [[ "$fast_rc" == 75 ]]; then
    collect_managed_split_tags_with_shell_tools
    return
  fi
  return "$fast_rc"
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

# 旧版分流的清理只对 sing-box 有意义：托管分流在 mihomo 上从第二步 2d 才开始
# 存在，不可能有「按旧写法留下的残留」。显式判断而不是依赖「查出来恰好是空的」
# ——那种依赖读起来像是碰巧成立。
legacy_split_cleanup_pending() {
  local config tags cleanup
  [[ "$PROXY_KERNEL" == singbox ]] || return 1
  config="$(kernel_normalized_config)" || return 1
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
  case "$PROXY_KERNEL" in
    singbox)
      rewrite_kernel_config '
        .route.rules = [(.route.rules // [])[] | . as $item | select(($rule_tags | index($item.rule_set // "")) == null)] |
        .route.rule_set = [(.route.rule_set // [])[] | . as $item | select(($rule_tags | index($item.tag)) == null)] |
        .outbounds = [(.outbounds // [])[] | . as $item | select((($out_tags + $transport_tags) | index($item.tag)) == null)]
      ' --argjson rule_tags "$rule_tags" --argjson out_tags "$out_tags" --argjson transport_tags "$transport_tags"
      ;;
    mihomo)
      # 托管的四处一并清掉，包括顶层 rules 里那一条派发——这里是「把托管分流
      # 全部撤走」，留着一条指向已不存在的 sub-rule 的派发会让配置加载不了。
      rewrite_kernel_config '
        .proxies = [(.proxies // [])[] | . as $item | select((($out_tags + $transport_tags) | index($item.name)) == null)] |
        .["rule-providers"] = ((.["rule-providers"] // {}) |
          with_entries(select(.key as $key | ($rule_tags | index($key)) == null))) |
        .["sub-rules"] = ((.["sub-rules"] // {}) | del(.[$sub_rule])) |
        .rules = [(.rules // [])[] | select((type == "string" and endswith("," + $sub_rule)) | not)]
      ' --argjson rule_tags "$rule_tags" --argjson out_tags "$out_tags" --argjson transport_tags "$transport_tags" \
        --arg sub_rule "$MIHOMO_MANAGED_SUB_RULE"
      ;;
    *) kernel_unknown ;;
  esac
}

# 一个用户在当前内核下的全部托管入口名。用户专属分流按这些名字限定范围。
# SS2022 + ShadowTLS 的条目数两个内核不同，因此前缀从适配层取。
split_user_inbound_tags() {
  local user="$1" shadowtls_prefixes
  shadowtls_prefixes="$(kernel_shadowtls_entry_prefixes)" || return 1
  jq -c --arg name "$user" --argjson st_prefixes "$shadowtls_prefixes" '
    first(.users[]? | select(.name == $name)) as $user |
    if $user == null then []
    else (if ($user.endpoints | type) == "array" then $user.endpoints
          else [{protocol:($user.protocol // "ss2022"),transport:($user.transport // "shadowtls")}] end) as $endpoints |
    ($endpoints | any(.protocol == "ss2022" and .transport == "shadowtls")) as $has_legacy |
    [ $endpoints[] |
      if .protocol == "anytls" then "anytls-" + $name
      elif .transport == "shadowtls" then ($st_prefixes[] + $name)
      elif $has_legacy then "ss-direct-" + $name
      else "ss-" + $name end
    ] | unique end
  ' "$STATE_FILE"
}

# 与内核无关的分流计划：哪条规则集配哪个出口、限定哪些入口、按什么顺序。
# 出口条目与规则集条目本身已经是内核形状（由适配层生成），计划只负责摆放；
# 最后一步的渲染同样在适配层——sing-box 的路由是对象数组，mihomo 是字符串数组。
build_split_runtime_plan() {
  local split_rows split plan name source behavior scope user user_status upstream out_tag rule_tag transport_tag outbounds rule_set inbounds conflict rule_file_path rule_url rule_geo match_key
  split_rows="$(jq -c '.splits[] | select(.status == "active")' "$STATE_FILE")" || return 1
  plan='{"outbound_groups":[],"rule_sets":[],"routes":[]}'
  while IFS= read -r split; do
    [[ -n "$split" ]] || continue
    name="$(jq -er '.name | select(type == "string" and length > 0)' <<<"$split")" || return 1
    rule_geo="$(split_rule_geo_from_json "$split")" || return 1
    if [[ "$(jq 'length' <<<"$rule_geo")" == 0 ]]; then
      source="$(jq -er '(.url // .rule_file) | select(type == "string" and length > 0)' <<<"$split")" || return 1
    else
      source=''
    fi
    behavior="$(split_rule_behavior_from_json "$split")" || return 1
    rule_url="$(split_rule_url_from_json "$split")" || return 1
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
    outbounds="$(build_split_outbounds "$name" "$upstream" "$out_tag" "$transport_tag")" || return 1
    # 规则文件是使用者自己的，添加之后随时可能被他删掉或改名。
    # 这是 `mihomo -t` 唯一测不出的一项：文件不在时配置检查照样通过、服务也照样
    # 起得来，只在启动日志里留一行 error，而那条分流从此静静地不生效
    # ——本该走上游的流量会改走直连。因此每次重建都真的看一眼。
    # 计划在任何配置改动之前完整生成，这里失败不会留下改了一半的运行配置。
    # 远程来源不查这一条：本地那个文件是 mihomo 自己的缓存，删了它会重新下载。
    # 该挡的是「地址取不到」，那在保存与「立即更新」时由管理器自己下载来挡。
    if [[ "$PROXY_KERNEL" == mihomo && -z "$rule_url" && -n "$source" ]]; then
      rule_file_path="$(mihomo_rule_file_path "$source")"
      if [[ ! -f "$rule_file_path" || -L "$rule_file_path" ]]; then
        printf '错误：分流 %s 的规则文件不存在或不是普通文件：%s\n' "$name" "$rule_file_path" >&2
        printf '请把该文件放回原处后重试；在此之前这条分流不会生效。\n' >&2
        return 1
      fi
    fi
    # geo 来源没有规则集条目可写：类别直接写进匹配条件，不经过 rule-providers。
    # 路由的身份因此也不能再用规则集标签——两条 geo 预置的类别清单一模一样时，
    # 渲染出来的行逐字相同，按标签分组会得到两条重复的行，其中第二条永远不生效，
    # 而「同一条件同时走两个出口」这种真冲突也会漏掉。所以身份统一改成**匹配条件**。
    if [[ "$(jq 'length' <<<"$rule_geo")" == 0 ]]; then
      match_key="rule:$rule_tag"
      rule_set="$(kernel_split_rule_set_entry "$rule_tag" "$source" "$behavior" "$rule_url")" || return 1
    else
      match_key="geo:$(jq -r 'join(",")' <<<"$rule_geo")"
      rule_set=''
    fi
    if jq -e --arg tag "$out_tag" 'any(.outbound_groups[]; .tag == $tag)' <<<"$plan" >/dev/null; then
      if ! SB_JQ_OUTBOUNDS="$outbounds" jq -e --arg tag "$out_tag" \
        '($ENV.SB_JQ_OUTBOUNDS | fromjson) as $objects | any(.outbound_groups[]; .tag == $tag and .objects == $objects)' <<<"$plan" >/dev/null; then
          echo "错误：多个分流使用了同一个预置出口名称，但连接参数不同；请重新选择预置出口。" >&2
          return 1
      fi
    else
      plan="$(SB_JQ_OUTBOUNDS="$outbounds" jq -c --arg tag "$out_tag" '($ENV.SB_JQ_OUTBOUNDS | fromjson) as $objects | .outbound_groups += [{tag:$tag,objects:$objects}]' <<<"$plan")" || return 1
    fi
    if [[ -n "$rule_set" ]]; then
      if jq -e --arg tag "$rule_tag" 'any(.rule_sets[]; .tag == $tag)' <<<"$plan" >/dev/null; then
        jq -e --arg tag "$rule_tag" --argjson item "$rule_set" 'any(.rule_sets[]; .tag == $tag and . == $item)' <<<"$plan" >/dev/null || {
          echo "错误：多个分流使用了同一条预置规则名称，但规则来源不同；请重新选择预置规则。" >&2
          return 1
        }
      else
        plan="$(jq -c --argjson item "$rule_set" '.rule_sets += [$item]' <<<"$plan")" || return 1
      fi
    fi
    if [[ "$scope" == all ]]; then inbounds='[]'; else inbounds="$(split_user_inbound_tags "$user")" || return 1; fi
    conflict="$(jq -r --arg match "$match_key" --arg out "$out_tag" --arg scope "$scope" --arg user "$user" '
      first(.routes[] | select(
        .match == $match and .outbound != $out and
        ($scope == "all" or .scope_all or (.users | index($user) != null))
      ) | "yes") // ""
    ' <<<"$plan")" || return 1
    if [[ -n "$conflict" ]]; then
      echo "错误：同一用户不能让同一条匹配规则同时使用两个不同出口。" >&2
      echo "两条分流的规则来源相同（同一条预置规则，或同一组 GeoSite／GeoIP 类别），请让它们走同一个出口，或者换一组类别。" >&2
      return 1
    fi
    if jq -e --arg match "$match_key" --arg out "$out_tag" 'any(.routes[]; .match == $match and .outbound == $out)' <<<"$plan" >/dev/null; then
      plan="$(jq -c --arg match "$match_key" --arg out "$out_tag" --arg scope "$scope" --arg user "$user" --argjson inbound "$inbounds" '
        .routes |= map(
          if .match == $match and .outbound == $out then
            if $scope == "all" then .scope_all = true | .users = [] | .inbound = []
            elif .scope_all then .
            else .users = ((.users + [$user]) | unique) | .inbound = ((.inbound + $inbound) | unique)
            end
          else . end)
      ' <<<"$plan")" || return 1
    else
      plan="$(jq -c --arg match "$match_key" --arg rule "$rule_tag" --arg out "$out_tag" --arg scope "$scope" --arg user "$user" --argjson inbound "$inbounds" --argjson geo "$rule_geo" '
        .routes += [{match:$match,rule_set:$rule,geo:$geo,outbound:$out,scope_all:($scope == "all"),users:(if $scope == "all" then [] else [$user] end),inbound:$inbound}]
      ' <<<"$plan")" || return 1
    fi
  done <<<"$split_rows"
  kernel_render_split_plan "$plan"
}

rebuild_all_split_configs() {
  local plan tags config legacy_cleanup
  # 先完整生成计划，任何读取、冲突或格式错误都不得提前改动现有配置。
  plan="$(build_split_runtime_plan)" || return 1
  tags="$(collect_managed_split_tags)" || return 1
  case "$PROXY_KERNEL" in
    singbox)
      config="$(kernel_normalized_config)" || return 1
      legacy_cleanup="$(collect_legacy_split_cleanup_plan_from_config "$config" "$tags")" || return 1
      SB_JQ_PLAN="$plan" rewrite_kernel_config '
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
      ;;
    mihomo)
      # 归属划分（公开 Issue #186）：proxies 与 rule-providers 按名字认领，
      # 外来的原样保留；sub-rules 里那一块整块归管理器；顶层 rules 里
      # 管理器只留一条派发，其余全是使用者的，原样保留。
      #
      # 派发放在最前面：使用者若在 rules 里写了 MATCH，放在后面会把整块托管
      # 分流盖掉。派发落空时流量继续走后面（使用者自己的）规则，这一点有实测。
      # 没有任何启用中的分流时不写派发，也不写空的 sub-rule——一条指向不存在
      # sub-rule 的派发会让 mihomo 直接拒绝加载配置。
      #
      # 认自己那条派发的办法是「以托管 sub-rule 名结尾」，而不是与常量整条相等：
      # 派发条件将来若改写法，按整条相等会认不出旧的那条，于是每次重建多留一条。
      # 代价是使用者若把自己的出口取名叫 managed-splits，指向它的规则会被一并
      # 拿掉——那个名字是管理器保留的，不该被拿去当出口名。
      #
      # mihomo 部署没有旧版分流的历史包袱：托管分流在 mihomo 上从本片才开始存在。
      SB_JQ_PLAN="$plan" rewrite_kernel_config "$MIHOMO_GEO_SETTINGS_PROGRAM"'
        ($ENV.SB_JQ_PLAN | fromjson) as $plan |
        .proxies = [(.proxies // [])[] | . as $item |
          select((($tags.out_tags + $tags.transport_tags) | index($item.name)) == null)] |
        .proxies += $plan.proxies |
        .["rule-providers"] = ((.["rule-providers"] // {}) |
          with_entries(select(.key as $key | ($tags.rule_tags | index($key)) == null)) +
          $plan.rule_providers) |
        .["sub-rules"] = ((.["sub-rules"] // {}) | del(.[$sub_rule])) |
        .rules = [(.rules // [])[] | select((type == "string" and endswith("," + $sub_rule)) | not)] |
        (if ($plan.sub_rules | length) > 0 then
           .["sub-rules"][$sub_rule] = $plan.sub_rules |
           .rules = [$dispatch] + .rules
         else . end) |
        (if (.["sub-rules"] | length) == 0 then del(.["sub-rules"]) else . end) |
        (if (.["rule-providers"] | length) == 0 then del(.["rule-providers"]) else . end) |
        # geo 设置放在最后：它要看的是**这一轮写完之后**配置里还有没有 geo 规则，
        # 放在前面看到的是上一轮的样子（公开 Issue #219）。
        sbm_apply_geo_settings
      ' --argjson tags "$tags" --arg sub_rule "$MIHOMO_MANAGED_SUB_RULE" \
        --arg dispatch "$MIHOMO_SPLIT_DISPATCH_RULE" \
        --argjson geox "$(mihomo_geox_url_json)"
      ;;
    *) kernel_unknown ;;
  esac
}

rebuild_and_finish_split_operation() {
  run_managed_step rebuild_all_split_configs || return 1
  run_managed_step check_singbox_and_restart || return 1
  finish_managed_operation || return 1
}

# 拿运行配置与期望标签做比对的地方都必须经这里读入：规范化程序按内核分派，
# 定义在适配层，与骨架、托管容器那几项同源（公开 Issue #189）。
singbox_config_for_comparison() {
  local program
  program="$(kernel_config_normalise_program)" || return 1
  kernel_normalized_config | jq -c "$program"
}

shared_preset_runtime_is_current() {
  local config rows split scope user user_status rule_tag out_tag transport_tag stored_rule stored_out stored_transport protocol inbounds tags legacy_cleanup
  config="$(singbox_config_for_comparison)" || return 1
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

split_preset_fields_are_current() {
  [[ -r "$STATE_FILE" ]] || return 1
  [[ "$(jq '[.splits[]? | select(.rule_preset == "" or .outbound_preset == "")] | length' "$STATE_FILE")" == 0 ]]
}

state_normalize_split_preset_fields() {
  atomic_state_update '
    .splits |= map(
      (if .rule_preset == "" then del(.rule_preset) else . end) |
      (if .outbound_preset == "" then del(.outbound_preset) else . end))
  '
}

migrate_empty_split_preset_fields() {
  [[ -r "$CONF_FILE" ]] || return 0
  command -v jq >/dev/null || return 0
  command -v flock >/dev/null || return 0
  load_runtime_config || return 1
  # 这是一次性整理历史 sing-box 数据的流程，其它内核的部署里没有对应的历史包袱。
  # 显式判断而不是依赖「sing-box 文件恰好不存在」——那种依赖在一台两个内核
  # 的二进制都还留着的机器上会失效。
  [[ "$PROXY_KERNEL" == singbox ]] || return 0
  [[ -f "$STATE_FILE" && -f "$SINGBOX_CONFIG" && -x "$SINGBOX_BIN" && -x "$NFUSE_BIN" && -S "$NFUSE_SOCKET" ]] || return 0
  split_preset_fields_are_current && return 0
  exec 9>"$LOCK_FILE" || return 1
  if ! flock -n 9; then release_operation_lock; return 1; fi
  if ! recover_pending_transaction || ! init_state; then release_operation_lock; return 1; fi
  if split_preset_fields_are_current; then
    release_operation_lock
    return 0
  fi
  if ! state_normalize_split_preset_fields; then
    release_operation_lock
    return 1
  fi
  log "已修正分流缺少预置来源时留下的空白记录"
  release_operation_lock
}

migrate_shared_preset_runtime_configs() {
  [[ -r "$CONF_FILE" ]] || return 0
  command -v jq >/dev/null || return 0
  command -v flock >/dev/null || return 0
  load_runtime_config || return 1
  # 这是一次性整理历史 sing-box 数据的流程，其它内核的部署里没有对应的历史包袱。
  # 显式判断而不是依赖「sing-box 文件恰好不存在」——那种依赖在一台两个内核
  # 的二进制都还留着的机器上会失效。
  [[ "$PROXY_KERNEL" == singbox ]] || return 0
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
  if ! ensure_safe_ssh_for_kernel_restart; then release_operation_lock; return 0; fi
  if ! start_managed_operation migrate-shared-presets; then release_operation_lock; return 1; fi
  if ! rebuild_and_finish_split_operation; then
    release_operation_lock
    return 1
  fi
  write_shared_preset_runtime_marker || { release_operation_lock; return 1; }
  log "已将重复的预置规则和出口合并为共享配置"
  release_operation_lock
}

# 规则来源的键名随内核不同（sing-box 的 url、mihomo 的 rule_file），
# 因此写入时取键名而不是写死；behavior 只有 mihomo 用得上，为空时不写这个键，
# 这样 sing-box 机器的状态文件与历史版本一字不差。
state_add_split() {
  local source_key
  source_key="$(kernel_rule_source_key)" || return 1
  SB_JQ_UPSTREAM="$5" atomic_state_update '(
    $ENV.SB_JQ_UPSTREAM | fromjson
  ) as $upstream |
    .splits += [{name:$name,scope:$scope,user:(if $scope == "user" then $user else null end),upstream:$upstream,outbound_tag:$out_tag,rule_set_tag:$rule_tag,
      runtime_rule_tag:$runtime_rule_tag,runtime_outbound_tag:$runtime_outbound_tag,runtime_transport_tag:$runtime_transport_tag,
      rule_preset:$rule_preset,outbound_preset:$outbound_preset,status:"active",created_at:$created_at}
      | (if $source == "" then . else .[$source_key] = $source end)
      | (if $behavior == "" then . else .rule_behavior = $behavior end)
      | (if $rule_url == "" then . else .rule_url = $rule_url end)
      | (if ($rule_geo | length) == 0 then . else .rule_geo = $rule_geo end)
      | (if $rule_preset == "" then del(.rule_preset) else . end)
      | (if $outbound_preset == "" then del(.outbound_preset) else . end)]
  ' --arg name "$1" --arg source "$2" --arg scope "$3" --arg user "$4" \
    --arg out_tag "$6" --arg rule_tag "$7" --arg rule_preset "$8" --arg outbound_preset "$9" \
    --arg runtime_rule_tag "${10}" --arg runtime_outbound_tag "${11}" --arg runtime_transport_tag "${12}" \
    --arg behavior "${13:-}" --arg rule_url "${14:-}" --argjson rule_geo "${15:-[]}" \
    --arg source_key "$source_key" \
    --arg created_at "$(date -Iseconds)"
}

state_set_split_status() {
  atomic_state_update '(.splits[] | select(.name == $name) | .status) = $status' \
    --arg name "$1" --arg status "$2"
}

state_replace_split() {
  local source_key
  source_key="$(kernel_rule_source_key)" || return 1
  SB_JQ_UPSTREAM="$5" atomic_state_update '(
    $ENV.SB_JQ_UPSTREAM | fromjson
  ) as $upstream |
    (.splits[] | select(.name == $name)) |=
      (. + {scope:$scope,user:(if $scope == "user" then $user else null end),upstream:$upstream,outbound_tag:$out_tag,
        runtime_rule_tag:$runtime_rule_tag,runtime_outbound_tag:$runtime_outbound_tag,runtime_transport_tag:$runtime_transport_tag,
        updated_at:$updated_at}
       | (if $source == "" then del(.[$source_key]) else .[$source_key] = $source end)
       | (if $behavior == "" then del(.rule_behavior) else .rule_behavior = $behavior end)
       | (if $rule_url == "" then del(.rule_url) else .rule_url = $rule_url end)
       | (if ($rule_geo | length) == 0 then del(.rule_geo) else .rule_geo = $rule_geo end)
       | (if $rule_preset == "" then del(.rule_preset) else .rule_preset = $rule_preset end)
       | (if $outbound_preset == "" then del(.outbound_preset) else .outbound_preset = $outbound_preset end))
  ' --arg name "$1" --arg source "$2" --arg scope "$3" --arg user "$4" \
    --arg out_tag "$6" --arg rule_preset "$7" --arg outbound_preset "$8" \
    --arg runtime_rule_tag "$9" --arg runtime_outbound_tag "${10}" --arg runtime_transport_tag "${11}" \
    --arg behavior "${12:-}" --arg rule_url "${13:-}" --argjson rule_geo "${14:-[]}" \
    --arg source_key "$source_key" \
    --arg updated_at "$(date -Iseconds)"
}

# 相同「预置规则 + 预置出口」的分流在运行配置里合并成一条路由，因而共用同一个匹配位置。
# 分组键取运行期标签，必须复用 split_runtime_*_from_json —— 它们的回退分支带 sha256，
# 无法在 jq 里重写一遍，另写一套迟早会和运行配置的分组规则脱节。
# 输出 {分流名: 匹配位置}，停用的分流不进入运行配置，位置为 null。
split_effective_match_ranks() {
  local rows row name status split rule_tag out_tag key existing rank=0 seen='{}' map='{}'
  rows="$(jq -r '.splits[] | [.name, .status, tojson] | @tsv' "$STATE_FILE")" || return 1
  while IFS=$'\t' read -r name status split; do
    [[ -n "$name" ]] || continue
    if [[ "$status" != active ]]; then
      map="$(jq -c --arg name "$name" '.[$name] = null' <<<"$map")" || return 1
      continue
    fi
    rule_tag="$(split_runtime_rule_tag_from_json "$split")" || return 1
    out_tag="$(split_runtime_out_tag_from_json "$split")" || return 1
    key="$rule_tag/$out_tag"
    existing="$(jq -r --arg key "$key" '.[$key] // ""' <<<"$seen")" || return 1
    if [[ -z "$existing" ]]; then
      rank=$((rank + 1))
      existing="$rank"
      seen="$(jq -c --arg key "$key" --argjson rank "$rank" '.[$key] = $rank' <<<"$seen")" || return 1
    fi
    map="$(jq -c --arg name "$name" --argjson rank "$existing" '.[$name] = $rank' <<<"$map")" || return 1
  done <<<"$rows"
  printf '%s' "$map"
}

# 与指定分流合并成同一条路由的全部分流名（含自身），按现有先后顺序返回。
# 停用的分流不进入运行配置，因此只与启用分流分组。
split_merge_group_names() {
  local target="$1" rows row name status split rule_tag out_tag target_key='' key group='[]'
  rows="$(jq -r '.splits[] | [.name, .status, tojson] | @tsv' "$STATE_FILE")" || return 1
  while IFS=$'\t' read -r name status split; do
    [[ "$name" == "$target" ]] || continue
    [[ "$status" == active ]] || { printf '["%s"]' "$target"; return 0; }
    rule_tag="$(split_runtime_rule_tag_from_json "$split")" || return 1
    out_tag="$(split_runtime_out_tag_from_json "$split")" || return 1
    target_key="$rule_tag/$out_tag"
  done <<<"$rows"
  [[ -n "$target_key" ]] || { printf '["%s"]' "$target"; return 0; }
  while IFS=$'\t' read -r name status split; do
    [[ -n "$name" ]] || continue
    [[ "$status" == active ]] || continue
    rule_tag="$(split_runtime_rule_tag_from_json "$split")" || return 1
    out_tag="$(split_runtime_out_tag_from_json "$split")" || return 1
    key="$rule_tag/$out_tag"
    [[ "$key" == "$target_key" ]] || continue
    group="$(jq -c --arg name "$name" '. += [$name]' <<<"$group")" || return 1
  done <<<"$rows"
  printf '%s' "$group"
}

# 合并成同一条路由的分流共用一个匹配位置，必须整组一起移动并保持彼此相邻，
# 否则界面顺序会和真正生效的顺序不一致。
state_move_split() {
  SB_JQ_GROUP="$1" atomic_state_update '
    ($ENV.SB_JQ_GROUP | fromjson) as $group |
    [.splits[] | select(.name as $n | ($group | index($n)) != null)] as $selected |
    [.splits[] | select(.name as $n | ($group | index($n)) == null)] as $remaining |
    ([$position - 1, ($remaining | length)] | min) as $index |
    .splits = ($remaining[0:$index] + $selected + $remaining[$index:])
  ' --argjson position "$2"
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
  local source_key
  source_key="$(kernel_rule_source_key)" || return 1
  atomic_state_update '
    .rule_presets += [{name:$name,created_at:$created_at}
      | (if $source == "" then . else .[$source_key] = $source end)
      | (if $behavior == "" then . else .rule_behavior = $behavior end)
      | (if $rule_url == "" then . else .rule_url = $rule_url end)
      | (if ($rule_geo | length) == 0 then . else .rule_geo = $rule_geo end)]
  ' --arg name "$1" --arg source "$2" --arg behavior "${3:-}" --arg rule_url "${4:-}" \
    --argjson rule_geo "${5:-[]}" \
    --arg source_key "$source_key" --arg created_at "$(date -Iseconds)"
}

state_replace_rule_preset() {
  local source_key
  source_key="$(kernel_rule_source_key)" || return 1
  atomic_state_update '
    def apply_source:
      (if $source == "" then del(.[$source_key]) else .[$source_key] = $source end) |
      (if $behavior == "" then del(.rule_behavior) else .rule_behavior = $behavior end) |
      (if $rule_url == "" then del(.rule_url) else .rule_url = $rule_url end) |
      (if ($rule_geo | length) == 0 then del(.rule_geo) else .rule_geo = $rule_geo end);
    (.rule_presets[] | select(.name == $name)) |= ((. + {updated_at:$updated_at}) | apply_source) |
    .splits |= map(
      if (.rule_preset // "") == $name then
        ((. + {updated_at:$updated_at}) | apply_source)
      else . end
    )
  ' --arg name "$1" --arg source "$2" --arg behavior "${3:-}" --arg rule_url "${4:-}" \
    --argjson rule_geo "${5:-[]}" \
    --arg source_key "$source_key" --arg updated_at "$(date -Iseconds)"
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
  local source_key
  source_key="$(kernel_rule_source_key)" || return 1
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
         if $rule == null then del(.rule_preset)
         else .[$source_key] = ($rule.url // $rule.rule_file) |
              (if ($rule.rule_behavior // "") == "" then . else .rule_behavior = $rule.rule_behavior end)
         end
       else . end)
    )
  ' --arg source_key "$source_key"
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
    ensure_safe_ssh_for_kernel_restart || return 0
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

# 来源写法的预检只对「有文件名的来源」有意义：远程来源的文件名由地址算出、
# 在 validate_remote_rule_set_url 里查，geo 来源根本没有文件名。
rule_source_needs_format_check() {
  local rule_url="$1" rule_geo="${2:-[]}"
  [[ -z "$rule_url" ]] || return 1
  [[ "$(jq 'length' <<<"$rule_geo")" == 0 ]] || return 1
}

cmd_rule_preset_add() {
  local name="$1" source="$2" behavior="${3:-}" rule_url="${4:-}" rule_geo="${5:-[]}"
  validate_preset_name "$name"
  rule_preset_exists "$name" && die "同名预置规则已经存在"
  if rule_source_needs_format_check "$rule_url" "$rule_geo"; then
    validate_split_rule_source_format "$source"
  fi
  validate_split_rule_source "$source" "$behavior" "$rule_url" "$rule_geo" || return 1
  state_add_rule_preset "$name" "$source" "$behavior" "$rule_url" "$rule_geo" || return 1
  log "预置规则已保存：${name}；它不会改变当前分流"
}

cmd_rule_preset_edit() {
  local name="$1" source="$2" behavior="${3:-}" rule_url="${4:-}" rule_geo="${5:-[]}" active
  rule_preset_exists "$name" || die "预置规则不存在：$name"
  if rule_source_needs_format_check "$rule_url" "$rule_geo"; then
    validate_split_rule_source_format "$source"
  fi
  validate_split_rule_source "$source" "$behavior" "$rule_url" "$rule_geo" || return 1
  active="$(jq --arg name "$name" '[.splits[] | select((.rule_preset // "") == $name and .status == "active")] | length' "$STATE_FILE")" || return 1
  if ((active == 0)); then
    state_replace_rule_preset "$name" "$source" "$behavior" "$rule_url" "$rule_geo" || return 1
  else
    ensure_safe_ssh_for_kernel_restart || return 0
    start_managed_operation "edit-rule-preset:$name" || return 1
    run_managed_step state_replace_rule_preset "$name" "$source" "$behavior" "$rule_url" "$rule_geo" || return 1
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

# 运行配置里是否已经存在同名的规则集 / 出口。
# 两个内核的容器与标识字段都不同：sing-box 是 route.rule_set[] 的 tag 与
# outbounds[] 的 tag，mihomo 是 rule-providers{} 的键与 proxies[] 的 name。
# 这两条检查的目的两个内核一致——不要覆盖掉不是管理器放进去的东西。
runtime_config_has_rule_set() {
  local tag="$1" config
  config="$(kernel_runtime_config_path)" || return 1
  case "$PROXY_KERNEL" in
    singbox) jq -e --arg tag "$tag" '.route.rule_set[]? | select(.tag == $tag)' "$config" >/dev/null ;;
    mihomo) jq -e --arg tag "$tag" '(.["rule-providers"] // {}) | has($tag)' "$config" >/dev/null ;;
    *) kernel_unknown ;;
  esac
}

runtime_config_has_outbound() {
  local config container key tags
  config="$(kernel_runtime_config_path)" || return 1
  container="$(kernel_split_outbound_container)" || return 1
  key="$(kernel_managed_key)" || return 1
  tags="$(printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0))')" || return 1
  # 先把元素绑成 $item 再进 index：jq 里函数参数是按 index 自己的输入求值的，
  # 直接写 index(.[$key]) 会拿 $tags 当输入，报「Cannot index array with string」。
  jq -e --arg container "$container" --arg key "$key" --argjson tags "$tags" \
    '(.[$container] // [])[] | . as $item | select(($tags | index($item[$key])) != null)' "$config" >/dev/null
}

# 审计要向运行配置提的四个问题。两个内核的托管分流摆在完全不同的地方
# （sing-box 在 route.rule_set／outbounds／route.rules，mihomo 在
# rule-providers／proxies／sub-rules），但问题是同一批，因此按内核分派，
# 不让审计那边各写一遍。
#
# $config 是已规范化的运行配置；$lines 是 mihomo 托管 sub-rule 里的那一块
# （sing-box 上恒为空数组，不使用）。mihomo 那几支用的规则行判断来自适配层，
# 与生成它们的渲染函数放在一起。
#
# $rule 是规则集标签，$cond 是这条分流在 mihomo 规则行里的**匹配条件**
# （公开 Issue #219）。两者对规则集来源是同一件事的两种写法，对 geo 来源
# 就不是了——geo 分流根本没有规则集标签。sing-box 那几支仍然只用规则集标签：
# 它没有 geo 这种来源，保存那一刻就已经挡住了。

# 这条分流的规则集、出口与路由是不是都在。
split_audit_runtime_complete() {
  local config="$1" lines="$2" rule="$3" out="$4" cond="${5:-}"
  case "$PROXY_KERNEL" in
    singbox)
      jq -e --arg tag "$rule" '.route.rule_set[]? | select(.tag == $tag)' <<<"$config" >/dev/null &&
      jq -e --arg out "$out" '.outbounds[]? | select(.tag == $out)' <<<"$config" >/dev/null &&
      jq -e --arg rule "$rule" --arg out "$out" \
        '.route.rules[]? | select(.rule_set == $rule and .outbound == $out)' <<<"$config" >/dev/null
      ;;
    mihomo)
      # geo 来源没有 rule-providers 条目可查，这一问对它不适用：那一条要是
      # 恒假，每台有 geo 分流的机器都会被审计说成「配置不完整」。
      [[ -n "$cond" ]] || cond="$(mihomo_split_match_condition "$rule")" || return 1
      jq -e --arg rule "$rule" --arg out "$out" --arg cond "$cond" --argjson lines "$lines" "$MIHOMO_SPLIT_RULE_DEFS"'
        (if sbm_cond_is_rule_set($cond) then ((.["rule-providers"] // {}) | has($rule)) else true end) and
        any(.proxies[]?; .name == $out) and
        any($lines[]; sbm_line_routes(.; $cond; $out))' <<<"$config" >/dev/null
      ;;
    *) kernel_unknown ;;
  esac
}

# 这条分流有没有一条限定到某个用户入口的路由。
# mode=all 要求覆盖该用户的全部入口（回答「有没有覆盖用户的全部连接」），
# mode=any 只要沾上任意一个入口就算（回答「已停用之后规则是不是还在生效」）。
split_audit_user_rule_present() {
  local config="$1" lines="$2" rule="$3" out="$4" tags="$5" mode="$6" cond="${7:-}"
  case "$PROXY_KERNEL" in
    singbox)
      if [[ "$mode" == all ]]; then
        jq -e --arg rule "$rule" --arg out "$out" --argjson expected "$tags" '
          .route.rules[]? | select(.rule_set == $rule and .outbound == $out and
            ($expected - (.inbound // []) | length) == 0)' <<<"$config" >/dev/null
      else
        jq -e --arg rule "$rule" --arg out "$out" --argjson expected "$tags" '
          .route.rules[]? | select(.rule_set == $rule and .outbound == $out and
            ([.inbound[]? as $tag | select($expected | index($tag) != null)] | length) > 0)' <<<"$config" >/dev/null
      fi
      ;;
    mihomo)
      [[ -n "$cond" ]] || cond="$(mihomo_split_match_condition "$rule")" || return 1
      if [[ "$mode" == all ]]; then
        jq -e --arg cond "$cond" --arg out "$out" --argjson expected "$tags" --argjson lines "$lines" \
          "$MIHOMO_SPLIT_RULE_DEFS"'
          any($lines[]; sbm_line_routes(.; $cond; $out) and sbm_line_covers(.; $expected))' <<<"$config" >/dev/null
      else
        jq -e --arg cond "$cond" --arg out "$out" --argjson expected "$tags" --argjson lines "$lines" \
          "$MIHOMO_SPLIT_RULE_DEFS"'
          any($lines[]; sbm_line_routes(.; $cond; $out) and sbm_line_touches(.; $cond; $expected))' <<<"$config" >/dev/null
      fi
      ;;
    *) kernel_unknown ;;
  esac
}

# 运行配置里那条规则集条目与状态里保存的来源对不对得上（公开 Issue #218）。
# 这是 mihomo 独有的一条：sing-box 的规则集本来就只有「一个公网地址」一种来源，
# 没有「本机文件」与「远程下载」两种形状可以漂移。
#
# 两个方向都要查：状态说远程、配置写成了 type:file，那条分流从此不再自动更新，
# 只会一直用本机那份旧缓存；状态说本机文件、配置写成了 type:http，mihomo 会去
# 网上下载并**覆盖**使用者自己维护的那个文件。两种都是内核一个字都不说的失效。
#
# 输出第一条对不上的说明；一致时无输出。规则集条目整个不在不在这里说——
# 那由 split_audit_runtime_complete 报，两处都报会让同一件事出现两行。
mihomo_rule_set_source_drift() {
  local config="$1" rule="$2" rule_url="$3" file="$4"
  jq -r --arg rule "$rule" --arg url "$rule_url" \
    --arg path "$(mihomo_rule_file_path "$file")" \
    --argjson interval "$REMOTE_RULE_SET_UPDATE_INTERVAL" '
    ((.["rule-providers"] // {})[$rule] // null) as $entry |
    if $entry == null then empty
    elif $url == "" then
      (if ($entry.type // "") != "file" then "保存的来源是本机文件，配置里却写成了自动下载" else empty end)
    elif ($entry.type // "") != "http" then "保存的来源是网址，配置里却没有写成自动下载，规则不会再更新"
    elif ($entry.url // "") != $url then "配置里的规则集网址与保存的不一致"
    elif ($entry.path // "") != $path then "配置里的规则集文件位置与保存的不一致"
    elif ($entry.interval // 0) != $interval then "配置里的规则集更新周期与保存的不一致"
    else empty end' <<<"$config"
}

# 不限入口的那一条路由在不在。已停用的「全部用户」分流不该还留着它。
split_audit_scope_all_rule_present() {
  local config="$1" lines="$2" rule="$3" out="$4" cond="${5:-}"
  case "$PROXY_KERNEL" in
    singbox)
      jq -e --arg rule "$rule" --arg out "$out" '
        .route.rules[]? | select(.rule_set == $rule and .outbound == $out and
          ((.inbound // []) | length == 0))' <<<"$config" >/dev/null
      ;;
    mihomo)
      [[ -n "$cond" ]] || cond="$(mihomo_split_match_condition "$rule")" || return 1
      jq -e --arg cond "$cond" --arg out "$out" --argjson lines "$lines" "$MIHOMO_SPLIT_RULE_DEFS"'
        any($lines[]; sbm_line_scope_all(.; $cond; $out))' <<<"$config" >/dev/null
      ;;
    *) kernel_unknown ;;
  esac
}

# 顶层那条派发与托管 sub-rule 的内容是否对得上：有内容就必须有派发，
# 没内容就不该留着派发。**只有 mihomo 有这一层**，sing-box 的路由规则直接摆在
# route.rules 里，不经过派发。
# 派发被删掉时整块分流一条都不生效，而运行配置本身完全合法、服务照常运行
# ——没有这条检查，就没有任何地方会把它说出来。
split_audit_dispatch_consistent() {
  local config="$1" lines="$2"
  case "$PROXY_KERNEL" in
    singbox) return 0 ;;
    mihomo)
      jq -e --argjson lines "$lines" --arg dispatch "$MIHOMO_SPLIT_DISPATCH_RULE" '
        (($lines | length) > 0) == (any(.rules[]?; . == $dispatch))' <<<"$config" >/dev/null
      ;;
    *) kernel_unknown ;;
  esac
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
  local name="$1" source="$2" scope="$3" user="$4" upstream="$5" out_tag="$6" rule_preset="${7:-}" outbound_preset="${8:-}" behavior="${9:-}" rule_url="${10:-}" rule_geo="${11:-[]}" rule_tag="$1"
  local runtime_rule_tag runtime_outbound_tag runtime_transport_tag kernel_name
  kernel_name="$(kernel_display_name)" || return 1
  validate_split_name "$name"; split_exists "$name" && die "分流规则已存在：$name"
  rule_preset_exists "$rule_preset" || die "预置规则不存在：$rule_preset"
  outbound_preset_exists "$outbound_preset" || die "预置出口不存在：$outbound_preset"
  validate_outbound_tag "$out_tag"
  runtime_rule_tag="$(stable_managed_tag rule "$rule_preset")" || return 1
  runtime_outbound_tag="$(stable_managed_tag outbound "$outbound_preset")" || return 1
  runtime_transport_tag="$(stable_managed_tag transport "$outbound_preset")" || return 1
  if rule_source_needs_format_check "$rule_url" "$rule_geo"; then
    validate_split_rule_source_format "$source"
  fi
  if [[ "$scope" == user ]]; then validate_name "$user"; user_exists "$user" || die "用户不存在：$user"; fi
  runtime_config_has_rule_set "$rule_tag" && die "${kernel_name} 已存在同名规则集标签"
  jq -e --arg out "$out_tag" '.splits[]? | select((.outbound_tag // ("managed-out-" + .name)) == $out)' "$STATE_FILE" >/dev/null && die "出口名称已被其他分流使用，请换一个名称"
  [[ "$out_tag" != "$(split_transport_tag "$name")" ]] || die "出口名称与系统内部名称冲突，请换一个名称"
  jq -e --arg out "$out_tag" '.splits[]? | select(("managed-transport-" + .name) == $out)' "$STATE_FILE" >/dev/null && die "出口名称与其他分流的内部名称冲突，请换一个名称"
  runtime_config_has_outbound "$out_tag" "$(split_transport_tag "$name")" && die "${kernel_name} 已存在同名分流出站标签"
  if runtime_config_has_rule_set "$runtime_rule_tag" &&
     ! runtime_rule_tag_owned_by_state "$runtime_rule_tag"; then
    die "这个预置规则与现有 ${kernel_name} 配置重名，请更换预置名称"
  fi
  if runtime_config_has_outbound "$runtime_outbound_tag" &&
     ! runtime_outbound_tag_owned_by_state "$runtime_outbound_tag"; then
    die "这个预置出口与现有 ${kernel_name} 配置重名，请更换预置名称"
  fi
  validate_split_relationships "$name" "$runtime_rule_tag" "$runtime_outbound_tag" "$scope" "$user" false || return 1
  validate_split_rule_source "$source" "$behavior" "$rule_url" "$rule_geo" || return 1
  ensure_safe_ssh_for_kernel_restart || return 0
  start_managed_operation "add-split:$name" || return 1
  run_managed_step state_add_split "$name" "$source" "$scope" "$user" "$upstream" "$out_tag" "$rule_tag" "$rule_preset" "$outbound_preset" \
    "$runtime_rule_tag" "$runtime_outbound_tag" "$runtime_transport_tag" "$behavior" "$rule_url" "$rule_geo" || return 1
  rebuild_and_finish_split_operation || return 1
  log "分流增加成功：$name"
}

cmd_split_disable() {
  local name="$1" split
  split_exists "$name" || die "分流不存在：$name"; split="$(jq -c --arg name "$name" '.splits[] | select(.name == $name)' "$STATE_FILE")"
  [[ "$(jq -r '.status' <<<"$split")" == active ]] || die "分流已经停用"
  ensure_safe_ssh_for_kernel_restart || return 0
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
  runtime_config_has_outbound "$out_tag" "$(split_transport_tag "$name")" && die "$(kernel_display_name) 已存在同名分流出站标签"
  runtime_config_has_rule_set "$rule_tag" && die "$(kernel_display_name) 已存在同名规则集标签"
  ensure_safe_ssh_for_kernel_restart || return 0
  start_managed_operation "enable-split:$name" || return 1
  run_managed_step state_set_split_status "$name" active || return 1
  rebuild_and_finish_split_operation || return 1
  log "分流已启用：$name"
}

cmd_split_remove() {
  local name="$1"
  split_exists "$name" || die "分流不存在：$name"
  ensure_safe_ssh_for_kernel_restart || return 0
  start_managed_operation "remove-split:$name" || return 1
  run_managed_step remove_split_config "$name" || return 1
  run_managed_step state_remove_split "$name" || return 1
  rebuild_and_finish_split_operation || return 1
  log "分流已删除：$name"
}

cmd_split_edit() {
  local name="$1" source="$2" scope="$3" user="$4" upstream="$5" out_tag="$6" rule_preset="${7:-}" outbound_preset="${8:-}" behavior="${9:-}" rule_url="${10:-}" rule_geo="${11:-[]}" split old_out
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
  if rule_source_needs_format_check "$rule_url" "$rule_geo"; then
    validate_split_rule_source_format "$source"
  fi
  if [[ "$scope" == user ]]; then validate_name "$user"; user_exists "$user" || die "用户不存在：$user"; fi
  jq -e --arg name "$name" --arg out "$out_tag" '.splits[]? | select(.name != $name and (.outbound_tag // ("managed-out-" + .name)) == $out)' "$STATE_FILE" >/dev/null && die "出口名称已被其他分流使用，请换一个名称"
  [[ "$out_tag" != "$(split_transport_tag "$name")" ]] || die "出口名称与系统内部名称冲突，请换一个名称"
  jq -e --arg name "$name" --arg out "$out_tag" '.splits[]? | select(.name != $name and ("managed-transport-" + .name) == $out)' "$STATE_FILE" >/dev/null && die "出口名称与其他分流的内部名称冲突，请换一个名称"
  if [[ "$out_tag" != "$old_out" ]]; then
    runtime_config_has_outbound "$out_tag" && die "$(kernel_display_name) 已存在同名出站"
  fi
  validate_split_relationships "$name" "$runtime_rule_tag" "$runtime_outbound_tag" "$scope" "$user" false || return 1
  validate_split_rule_source "$source" "$behavior" "$rule_url" "$rule_geo" || return 1
  ensure_safe_ssh_for_kernel_restart || return 0
  start_managed_operation "edit-split:$name" || return 1
  run_managed_step remove_split_config "$name" || return 1
  run_managed_step state_replace_split "$name" "$source" "$scope" "$user" "$upstream" "$out_tag" "$rule_preset" "$outbound_preset" \
    "$runtime_rule_tag" "$runtime_outbound_tag" "$runtime_transport_tag" "$behavior" "$rule_url" "$rule_geo" || return 1
  rebuild_and_finish_split_operation || return 1
  log "分流修改成功：$name"
}

cmd_split_move() {
  local name="$1" position="$2" count current group group_size others
  split_exists "$name" || die "分流不存在：$name"
  count="$(jq '.splits | length' "$STATE_FILE")"
  if [[ ! "$position" =~ ^[0-9]+$ ]] || ((position < 1 || position > count)); then
    die "目标优先级超出范围"
  fi
  current="$(jq -r --arg name "$name" '.splits | to_entries[] | select(.value.name == $name) | (.key + 1)' "$STATE_FILE")"
  group="$(split_merge_group_names "$name")" || return 1
  group_size="$(jq 'length' <<<"$group")" || return 1
  if [[ "$current" == "$position" && "$group_size" == 1 ]]; then echo "优先级未变化。"; return 0; fi
  ensure_safe_ssh_for_kernel_restart || return 0
  start_managed_operation "move-split:$name" || return 1
  run_managed_step state_move_split "$group" "$position" || return 1
  rebuild_and_finish_split_operation || return 1
  if ((group_size > 1)); then
    others="$(jq -r --arg name "$name" '[.[] | select(. != $name)] | join("、")' <<<"$group")" || return 1
    log "分流优先级已调整：${name} → ${position}（与 ${others} 共用同一套预置，在运行配置中合并为一条，已一并移动）"
  else
    log "分流优先级已调整：$name → $position"
  fi
}

cmd_split_list() {
  local ranks
  ranks="$(split_effective_match_ranks)" || return 1
  # 「匹配位置」是真正生效的先后顺序：合并成同一条路由的分流共用一个位置，
  # 只显示行号会让人以为它们能各自排序。
  SB_JQ_RANKS="$ranks" jq -r 'if (.splits|length)==0 then "暂无分流" else
    ($ENV.SB_JQ_RANKS | fromjson) as $ranks |
    (["顺序","匹配位置","名称","状态","范围","预置规则","预置出口"]|@tsv),
    (.splits|to_entries[]|[
      ((.key+1)|tostring),
      (($ranks[.value.name] // null) as $rank | if $rank == null then "—" else ("第 " + ($rank|tostring) + " 位") end),
      .value.name,
      (if .value.status=="active" then "启用" else "停用" end),
      (if .value.scope=="all" then "全部用户" else ("用户:"+.value.user) end),
      (.value.rule_preset // "独立配置"),
      (.value.outbound_preset // "独立配置")]|@tsv) end' "$STATE_FILE" | column -t -s $'\t'
}

cmd_split_show() {
  local name="$1" ranks group
  split_exists "$name" || die "分流不存在：$name"
  ranks="$(split_effective_match_ranks)" || return 1
  group="$(split_merge_group_names "$name")" || return 1
  # 「匹配位置」必须用真正生效的顺序，不能拿行号充数：合并成同一条路由的分流共用一个位置
  SB_JQ_RANKS="$ranks" SB_JQ_GROUP="$group" jq -r --arg name "$name" '
    ($ENV.SB_JQ_RANKS | fromjson) as $ranks |
    ($ENV.SB_JQ_GROUP | fromjson) as $group |
    .splits | to_entries[] | select(.value.name == $name) |
    .key as $index | .value as $s |
    "分流名称：\($s.name)",
    "列表顺序：第 \($index + 1) 条",
    "匹配位置：\(($ranks[$s.name] // null) as $rank | if $rank == null then "未生效（分流已停用）" else "第 \($rank) 位" end)",
    (if ($group | length) > 1 then
      "合并说明：与 \([$group[] | select(. != $name)] | join("、")) 共用同一套预置，在运行配置中合并为一条，匹配位置和顺序调整都作用于整组"
     else empty end),
    "状态：\(if $s.status == "active" then "启用" else "停用" end)",
    "作用范围：\(if $s.scope == "all" then "全部用户" else "用户:" + $s.user end)",
    "规则来源：\($s.rule_preset // "独立配置")",
    (if $kernel == "mihomo" then
       (if (($s.rule_geo // []) | length) > 0 then
          "规则类别：\(($s.rule_geo // []) | join("  "))",
          "说明：命中其中任意一个类别就走这条分流；数据库由 mihomo 自己下载与更新"
        else
          "规则文件：\($rules_dir)/\($s.rule_file // "?")",
          "规则来源：\(if ($s.rule_url // "") != "" then "网址 " + $s.rule_url + "（每天自动更新）" else "本机文件（自己维护）" end)",
          "规则写法：\(if $s.rule_behavior == "classical" then "完整规则行" elif $s.rule_behavior == "domain" then "域名列表" elif $s.rule_behavior == "ipcidr" then "IP 段列表" else "未知写法" end)"
        end)
     else "规则集地址：\($s.url)" end),
    "出口来源：\($s.outbound_preset // "独立配置")",
    "出口协议：\(if $s.upstream.protocol == "anytls" then "AnyTLS" elif $s.upstream.protocol == "shadowsocks" then "Shadowsocks" elif $s.upstream.protocol == "ss_shadowtls" then "SS2022 + ShadowTLS" else "旧版未配置" end)",
    "出口服务器：\($s.upstream.server // "-"):\($s.upstream.server_port // "-")",
    (if ($s.upstream.method // "") != "" then "加密方式：\($s.upstream.method)" else empty end),
    (if ($s.upstream.sni // "") != "" then "TLS SNI：\($s.upstream.sni)" else empty end),
    (if ($s.upstream | has("insecure")) then "证书验证：\(if $s.upstream.insecure then "跳过" else "验证" end)" else empty end),
    "创建时间：\($s.created_at // "-")",
    (if ($s.updated_at // "") != "" then "修改时间：\($s.updated_at)" else empty end)
  ' --arg kernel "$PROXY_KERNEL" --arg rules_dir "$MIHOMO_RULES_DIR" "$STATE_FILE"
}

# 全新安装时管理器自己的数据目录。**只对新机器生效**：存量机器的目录名写在它们
# 自己的管理配置里（或者由文件级默认值 /etc/sing-box 给出），升级不会动它。
# 新机器上没有存量数据，改名的代价在这一刻是零，越往后越贵——这是公开 Issue #172
# 三步走的第二步，搭 2f 的车做掉。
FRESH_INSTALL_MANAGER_DATA_DIR="/etc/sb-user-manager"

# 把管理器数据目录切到新装机器用的那个，并重新派生由它算出来的四条路径。
# 必须在部署开始之前调用：deploy_environment 建目录、写单元里的 SAFE_PATHS
# 都发生在管理配置写出之前。
apply_fresh_install_manager_data_dir() {
  MANAGER_DATA_DIR="$FRESH_INSTALL_MANAGER_DATA_DIR"
  resolve_manager_data_paths
  STATE_FILE="$MANAGER_DATA_DIR/managed-users.json"
  BACKUP_DIR="$MANAGER_DATA_DIR/backups"
}

# 存量机器的数据目录。管理配置整个丢失、但机器上还有 sing-box 痕迹时走这条路：
# 它们的用户资料、内部备份与证书都在老目录里，名字不能变。
apply_legacy_manager_data_dir() {
  MANAGER_DATA_DIR="$LEGACY_MANAGER_DATA_DIR"
  resolve_manager_data_paths
  STATE_FILE="$MANAGER_DATA_DIR/managed-users.json"
  BACKUP_DIR="$MANAGER_DATA_DIR/backups"
}

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
STATE_FILE="$MANAGER_DATA_DIR/managed-users.json"
BACKUP_DIR="$MANAGER_DATA_DIR/backups"
LOCK_FILE="/run/lock/sb-user-manager.lock"
CLIENT_SERVER_PORT_OVERRIDE=""
PUBLIC_SERVER_OVERRIDE=""
EOF
}

# mihomo 部署的管理配置。这类机器本来就退不回不支持 mihomo 的脚本，
# 因此写 PROXY_KERNEL 不构成新的回退障碍。
# **MANAGER_DATA_DIR 必须写出来**：从 2f 起新装的 mihomo 机器用中立路径
# /etc/sb-user-manager，而文件级默认值仍是 /etc/sing-box（存量机器靠它）。
# 不写进配置的话，下一次载入配置时默认值会赢，机器会去一个空目录里找用户资料。
# sing-box 那一份仍然不写：它的目录名就是默认值，写进去反而把默认值固化在
# 每台老机器上。
write_mihomo_manager_config() {
  cat > "$CONF_FILE" <<EOF || return 1
HANDSHAKE_PORT=443
SHADOWTLS_STRICT_MODE=true
SS2022_SHADOWTLS_SNI="$DEFAULT_SS2022_SHADOWTLS_SNI"
ANYTLS_SNI="$DEFAULT_ANYTLS_SNI"
PROXY_KERNEL="mihomo"
MANAGER_DATA_DIR="$MANAGER_DATA_DIR"
MIHOMO_BIN="/usr/local/bin/mihomo"
MIHOMO_CONFIG="/etc/mihomo/config.json"
MIHOMO_SERVICE="mihomo"
MIHOMO_WORK_DIR="/var/lib/mihomo"
NFUSE_BIN="/usr/local/bin/nfuse"
NFUSE_SOCKET="/run/nfuse.sock"
STATE_FILE="$MANAGER_DATA_DIR/managed-users.json"
BACKUP_DIR="$MANAGER_DATA_DIR/backups"
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
# 2. 需要 SAFE_PATHS，而且是两条：mihomo 默认拒绝加载工作目录之外的文件。
#    一条是管理器的 AnyTLS 证书目录（公开 Issue #154，该限制只在真正启动
#    监听器时才报错，`mihomo -t` 完全测不出）；另一条是使用者自己的分流规则
#    目录（公开 Issue #186，这一条反而在 `mihomo -t` 阶段就当场拒绝）。
#    分隔符是冒号——实测逗号不认，会被当成路径的一部分。
# 3. 不写 ExecReload：本项目从不执行 systemctl reload，写一条未经验证的重载
#    命令等于给出一个没验过的承诺。
# heredoc 刻意不加引号：SAFE_PATHS 的取值来自 mihomo_safe_paths，与管理器自己
# 跑 `mihomo -t` 时用的是同一份。
# 因此往这段单元里加内容时不能出现 $ —— sing-box 单元里的 $MAINPID 就是反例。
write_mihomo_unit() {
  local safe_paths
  safe_paths="$(mihomo_safe_paths)" || return 1
  cat > "$(system_path /etc/systemd/system/mihomo.service)" <<EOF || return 1
[Unit]
Description=mihomo service
After=network-online.target nss-lookup.target
Wants=network-online.target
[Service]
Type=simple
User=root
StateDirectory=mihomo
Environment=SAFE_PATHS=$safe_paths
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
Description=Expire sb-user-manager managed users
After=${kernel_unit}.service nfuse.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sb-user-manager --internal-expire
EOF
  cat > "$(system_path /etc/systemd/system/sb-user-expiry.timer)" <<'EOF' || return 1
[Unit]
Description=Check sb-user-manager user expiry
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

# 机器上活着的 systemd 单元与「当前版本应该写出的」是否一致。
#
# 单元只在全新部署与「修复缺失内容」这两条路径上写出，
# **升级脚本从来不会刷新它们**：一台完整部署的机器进「安装或修复环境」会被
# 直接告知「安装完整，无需重复部署」然后原样返回（公开 Issue #190）。
# 因此新版本改了单元内容时，存量机器会静静地落在旧单元上，而管理器按新单元的
# 假设行事——第二步 2d 撞到过一次这个形状的问题（mihomo 单元的 SAFE_PATHS）。
#
# 这里只查不改：重写单元必然意味着一次服务重启，那不能在只读的审计里做，
# 交给「自动修复」那条通路——它本来就会先做完整环境备份、再改、再重启。
#
# 输出每行一个不一致的单元路径；全部一致时无输出。
# 返回 2 表示查不了（识别不出默认网络接口），调用点据此报「未能核对」而不是
# 报「不一致」——把「不知道」说成「不一致」会让人去修一个并不存在的问题。
collect_unit_drift_rows() {
  local iface work path live expected rc=0 any_unit=false previous_root
  # 一个托管单元都没有的机器不是「漂移」，是没部署——那由环境分类那一侧管。
  # 这条判断同时让这项检查在没有部署环境的场合安静下来，不去报一堆
  # 「单元与当前版本不一致」，那种输出只会把真正的问题淹掉。
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    [[ -f "$(system_path "$path")" ]] || continue
    any_unit=true
    break
  done <<<"$(managed_unit_paths)"
  [[ "$any_unit" == true ]] || return 0
  iface="$(default_network_interface)" || return 2
  [[ -n "$iface" ]] || return 2
  work="$(mktemp -d /tmp/sb-unit-drift.XXXXXX)" || return 1
  register_temp_path "$work"
  # 借 SB_SYSTEM_ROOT 把生成结果落到临时目录，而不是另写一份「期望的单元」
  # ——那等于把单元内容抄成两份，迟早只改一处。
  # 不放在子 shell 里改这个变量：那样 shellcheck 会认为函数外面对它的读取
  # 「可能拿不到修改」（SC2030/SC2031），而这里本来就不该影响外面。
  # 因此显式存回原值，失败路径也要走到那一步，所以先收 rc 再判断。
  previous_root="${SB_SYSTEM_ROOT:-}"
  SB_SYSTEM_ROOT="$work"
  install -d -m 755 "$work/etc/systemd/system" && write_systemd_units "$iface"
  rc=$?
  SB_SYSTEM_ROOT="$previous_root"
  if ((rc != 0)); then
    rm -rf -- "$work"
    unregister_temp_path "$work" || true
    return 1
  fi
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    live="$(system_path "$path")"
    expected="$work$path"
    [[ -f "$expected" ]] || continue
    if [[ ! -f "$live" ]] || ! cmp -s "$live" "$expected"; then
      printf '%s
' "$path"
    fi
  done <<<"$(managed_unit_paths)"
  rm -rf -- "$work" || rc=1
  unregister_temp_path "$work" || rc=1
  return "$rc"
}

# write_systemd_units 会写出的全部单元。审计按这一份逐个比对，
# 因此新增一个单元时**必须**同时加进这里，否则那个单元永远不会被核对到。
# 单元测试对每一个都做过「改一处内容 → 审计必须报出来」。
managed_unit_paths() {
  local kernel_service
  kernel_service="$(kernel_service_name)" || return 1
  printf '/etc/systemd/system/%s.service\n' "$kernel_service"
  printf '%s\n' /etc/systemd/system/nfuse.service \
    /etc/systemd/system/sb-user-expiry.service \
    /etc/systemd/system/sb-user-expiry.timer
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
  for path in /etc/sb-user-manager.conf "$MANAGER_DATA_DIR/managed-users.json" /usr/local/sbin/sb-user-manager /etc/systemd/system/sb-user-expiry.timer; do
    [[ -e "$(system_path "$path")" ]] && ((managed+=1))
  done
  for path in /usr/local/bin/nfuse /etc/systemd/system/nfuse.service /var/lib/nfuse/nfuse.db; do
    [[ -e "$(system_path "$path")" ]] && ((core+=1))
  done
  while IFS= read -r path; do
    [[ -e "$(system_path "$path")" ]] && ((core+=1))
  done <<<"$kernel_paths"
  for path in /etc/sb-user-manager.conf "$MANAGER_DATA_DIR/managed-users.json" /usr/local/sbin/sb-user-manager /usr/local/bin/nfuse /etc/systemd/system/nfuse.service /etc/systemd/system/sb-user-expiry.service /etc/systemd/system/sb-user-expiry.timer; do
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
    cat <<EOF
$MANAGER_DATA_DIR/managed-users.json
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

# 写死 sing-box 路径的专用入口。只剩一个用处：判断存量 sing-box 机器上装的是不是
# 一个测试版（版本号带 `-`），好在更新与修复时不把它静默换成正式版。
installed_singbox_version() { kernel_binary_version "${SINGBOX_BIN:-/usr/local/bin/sing-box}"; }

# 这台机器上装着的是不是一个 sing-box 测试版。sing-box 的测试版版本号带 `-`
# （如 1.14.0-alpha.44），正式版不带。
#
# 正式版／测试版通道的**管理入口**已随 sing-box 线归档一并撤除（公开 Issue #256），
# 这个判据却必须留着：存量机器上可能仍然装着一个测试版，而**保留现有部署的流程
# 绝不能把它静默换成正式版**——那等于使用者点了一次「检测更新」或「修复环境」
# 之后，内核版本莫名其妙地变了。以前判据来自通道状态文件加版本号，现在只看
# 版本号，结论一样而少一个要维护的状态文件。
#
# 保留现有部署的每一条流程都必须先问这一句，静态门禁看守该约定。
singbox_preview_deployed() {
  [[ "$PROXY_KERNEL" == singbox ]] || return 1
  [[ "$(installed_singbox_version)" == *-* ]]
}
# 当前部署实际使用的内核版本，按内核取。
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
  local cert_dir cert_file key_file
  cert_dir="$(system_path "$CERT_DIR")" || return 1
  cert_file="$(system_path "$ANYTLS_CERT_FILE")" || return 1
  key_file="$(system_path "$ANYTLS_KEY_FILE")" || return 1
  install -d -m 700 "$cert_dir" || return 1
  if [[ ! -s "$cert_file" || ! -s "$key_file" ]]; then
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 -subj '/CN=localhost' \
      -addext "subjectAltName=IP:$(hostname -I | awk '{print $1}')" \
      -keyout "$key_file" -out "$cert_file" >/dev/null 2>&1 || return 1
    chmod 600 "$key_file" || return 1
    chmod 644 "$cert_file" || return 1
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
  # /usr/local/bin 是系统共享目录：缺失时才建，已经存在就不动它的权限
  # （同 Issue #246；某些发行版上它带 setgid 与组写位，按 755 覆盖会抹掉）。
  ensure_manager_directory "$(dirname "$shortcut")" 755 || return 1
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
  {
    # 管理器数据目录单列一条。今天它就是下面那个 /etc/sing-box，去重后输出不变；
    # 分开写是因为这两者是两回事——一个是内核的部署目录，一个是管理器的用户
    # 资料与内部备份。MANAGER_DATA_DIR 改值之后漏掉它，等于环境快照里没有用户数据。
    printf '%s\n' "$MANAGER_DATA_DIR"
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
    # 两个内核的全部部署路径取并集，与部署跟踪、卸载、事务白名单三处同源。
    # 放在最后追加：上面已经出现过的条目会被去重丢掉，因此 sing-box 机器上
    # 这份清单的内容与顺序一字不变，只在末尾多出 mihomo 的五条。
    # 这里不手抄一份 mihomo 路径——手抄的那份下次加内核时会再漏一遍，
    # 而漏掉的后果是失败回滚还原不了被覆盖的内核文件（公开 Issue #175）。
    all_kernel_deployment_paths
  } | awk 'NF && !seen[$0]++'
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
  # 这里刻意用默认位置而不是 ${BACKUP_DIR}：本函数在接管流程里早于 load_runtime_config
  # 运行，那时 BACKUP_DIR 还没有取值。与改动前的写死行为一致——管理配置把
  # BACKUP_DIR 指到别处的机器，这一步同样跳不掉，这一点收敛前后都成立。
  rm -rf -- "$backup/root${MANAGER_DATA_DIR}/backups"
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
    # 管理器数据目录及其下的三项。父目录在前，与本函数的顺序约定一致；
    # 今天目录本身与 all_kernel_deployment_paths 里的 /etc/sing-box 重合，去重后不变。
    printf '%s\n' "$MANAGER_DATA_DIR" "$MANAGER_DATA_DIR/backups" \
      "$CERT_DIR" "$ANYTLS_CERT_FILE" "$ANYTLS_KEY_FILE"
    cat <<'EOF'
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
  # 管理器数据目录一并清。今天它等于 all_kernel_deployment_paths 里的 /etc/sing-box，
  # 这一行是重复删除、无副作用；MANAGER_DATA_DIR 改值之后它就是唯一清得掉
  # 这份半成品用户数据的地方。
  while IFS= read -r path; do
    rm -rf -- "$path"
  done < <(all_kernel_deployment_paths; printf '%s\n' "$MANAGER_DATA_DIR")
  rm -f /etc/sb-user-manager.conf /etc/systemd/system/nfuse.service \
    /etc/systemd/system/sb-user-expiry.service /etc/systemd/system/sb-user-expiry.timer \
    /usr/local/sbin/sb-user-manager /usr/local/bin/sbm /usr/local/bin/nfuse
  rm -rf /var/lib/sb-user-manager
}

# 旧版本把两个系统共享目录按 700 建了出来（公开 Issue #246）：
#   /var/lib        —— 恢复记录曾经放在它正下方，创建父目录时连它一起改了；
#                      后果是 apt 的下载沙箱失效，以非 root 身份读
#                      /var/lib/<服务名> 的服务也够不到自己的数据。
#   /usr/local/sbin —— 与管理器自己的四个目录写在同一条 install 里，一起收到 700。
# 缺陷本身已经修掉，但**被改坏的机器不会自己好**——凡是装过旧版本的机器，
# 这两个目录到今天都还是 700。这里在部署、修复与更新三条路径上一次性修回来。
# **只在恰好等于 700 时动手**：那正是本脚本留下的指纹。管理员自己设成别的值
# 是他的决定，不要覆盖。修不动也不当失败——一次权限修复不该拖垮一次部署。
repair_system_directory_modes() {
  local path target mode
  for path in /var/lib /usr/local/sbin; do
    target="$(system_path "$path")" || continue
    [[ -d "$target" && ! -L "$target" ]] || continue
    mode="$(manager_file_mode "$target")" || continue
    [[ "$mode" == 700 ]] || continue
    chmod 755 -- "$target" || continue
    log "已把 $path 的权限从 700 修回 755（旧版本缺陷，公开 Issue #246）"
  done
}

deploy_environment() {
  local fresh="$1" update_manager="${2:-false}" iface work backup path deployed_state_file
  local -a deploy_created=()
  local deploy_created_count=0
  repair_system_directory_modes
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
  # 这四个都是本项目自己的目录，里面装的是用户资料、证书与流量库，
  # 因此即使已经存在也要按 700 收紧——那是有意的。
  run_step_or_rollback rollback_deploy install -d -m 700 \
    "$MANAGER_DATA_DIR" "$MANAGER_DATA_DIR/backups" "$CERT_DIR" /var/lib/nfuse || return 1
  # /usr/local/sbin 不是本项目的目录，是系统共享的。**已经存在就一字不动**：
  # 旧版本把它跟上面四个一起按 700 建，于是每台装过本脚本的机器上它都变成了
  # 只有 root 能进（公开 Issue #246）。缺失时按 755 建，那是它该有的样子。
  run_step_or_rollback rollback_deploy ensure_manager_directory /usr/local/sbin 755 || return 1
  if [[ "$PROXY_KERNEL" == singbox ]]; then
    # sing-box 自己的配置目录。今天与管理器数据目录是同一个，上面那行已经建好，
    # 这里是重复调用、无副作用；分开写是因为两者属于不同的东西——管理器数据
    # 搬走之后，内核仍然需要自己的目录（公开 Issue #172）。
    run_step_or_rollback rollback_deploy install -d -m 700 "$(dirname "$SINGBOX_CONFIG")" || return 1
  fi
  if [[ "$PROXY_KERNEL" == mihomo ]]; then
    # mihomo 的配置目录与工作目录。工作目录也由 systemd 的 StateDirectory 负责，
    # 但配置校验发生在服务启动之前，那时它还不存在——不预先建好的话，
    # 目录会由 `mihomo -t` 顺手创建，权限与创建时机都不在我们手里。
    run_step_or_rollback rollback_deploy install -d -m 700 /etc/mihomo || return 1
    run_step_or_rollback rollback_deploy install -d -m 755 "$MIHOMO_WORK_DIR" || return 1
    # 使用者自己放分流规则文件的目录。管理器建它、读它，但永远不写里面的文件。
    # 它必须与单元里 SAFE_PATHS 的第二条一字不差，否则 mihomo 当场拒绝加载配置。
    # 权限 755 而不是 700：这些是使用者要自己放进来的文件，不是管理器的数据。
    run_step_or_rollback rollback_deploy install -d -m 755 "$MIHOMO_RULES_DIR" || return 1
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

# 确定本次安装或更新按哪个内核进行。
# 已部署的机器一律以管理配置里的声明为准；干净机器一律装 mihomo，不给选择
# （公开 Issue #157 的 2f）。仅供测试的内核选择开关已于 sing-box 线归档后剥离
# （公开 Issue #227）；要装一台 sing-box 机器只能用 v4.25.22 或更早的 Release。
# 必须在这里显式确定，不能依赖文件级默认值：deploy_environment 内那次
# load_runtime_config 发生在子进程里，父进程拿不到结果，而写单元文件、
# 校验配置、挑选下载资产都发生在父进程。真机上验到的后果是——
# 一台 mihomo 机器执行「自动修复缺失内容」会去下载并部署 sing-box。
# 机器上还有没有 sing-box 的部署痕迹。只在管理配置缺失时用来判断这台机器原本是
# 什么：判据取 sing-box 的三样核心文件，其中任何一样还在就算数。
singbox_deployment_present() {
  local path
  for path in /usr/local/bin/sing-box /etc/sing-box/config.json /etc/systemd/system/sing-box.service; do
    [[ ! -e "$(system_path "$path")" ]] || return 0
  done
  return 1
}

resolve_deployment_kernel() {
  if [[ -r "$CONF_FILE" ]]; then
    load_runtime_config
    return 0
  fi
  # 没有管理配置时先看机器上已经有什么。**管理配置丢了的 sing-box 机器要能被修回
  # 去**，而不是被当成新机器换成另一个内核——「安装或修复环境」的修复分支走的正是
  # 这条路。真正干净的机器才按 2f 的规则装 mihomo（公开 Issue #157），不给选择。
  # 已部署且配置还在的机器一律以管理配置为准，内核与目录名都不会因为升级而改变。
  if singbox_deployment_present; then
    PROXY_KERNEL=singbox
  else
    PROXY_KERNEL=mihomo
  fi
  # 中立数据目录只给新装的 mihomo 机器。上面那条 sing-box 分支留给**存量**机器——
  # 管理配置丢了、但机器上还有 sing-box 痕迹的那种，它们的数据目录必须保持老名字。
  #
  # **两条分支都必须显式给出数据目录。** 以前 sing-box 那一支什么都不做，靠的是
  # 文件级默认值恰好就是 /etc/sing-box；那个默认值现在是「尚未解析」哨兵
  # （公开 Issue #262），不显式设的话，这类机器会带着哨兵往下走，第一次派生证书
  # 路径时就会停住。这正是把默认值换成哨兵想暴露的那种隐式依赖。
  if [[ "$PROXY_KERNEL" == mihomo ]]; then
    apply_fresh_install_manager_data_dir
  else
    apply_legacy_manager_data_dir
  fi
}

install_environment() {
  local choice answer config_path state_path
  # 一台完好的机器走不到 deploy_environment（下面第一个分支直接返回），
  # 而它同样可能带着旧版本留下的 700。「修复环境」这个名字应当名副其实，
  # 所以在这里也修一次（公开 Issue #246）。函数幂等，重复调用无副作用。
  repair_system_directory_modes
  resolve_deployment_kernel || return 1
  show_environment_diagnostics
  case "$ENVIRONMENT_CLASS" in
    managed_complete)
      echo "安装完整，无需重复部署。你可以返回上一级检查更新或运行「服务与配置检查」。"
      return 0
      ;;
    fresh)
      printf '\n全新部署会安装 %s 作为代理内核。\n' "$(kernel_display_name)"
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
          # 内核配置的位置、容器名与标识字段都按内核取值。此前这三处写死了
          # sing-box 的形状（`/etc/sing-box/config.json`、`.inbounds[]`、`.tag`），
          # 于是 mihomo 机器上这条路必定停在下面那句 die 上——而那台机器本来就
          # 不该有 sing-box 的配置文件（公开 Issue #242）。注意别把「管理器数据
          # 目录」当成内核配置：存量机器的数据目录确实叫 /etc/sing-box，但那里
          # 放的是用户资料与内部备份，不是内核的运行配置。
          config_path="$(kernel_runtime_config_path)" || return 1
          config_path="$(system_path "$config_path")"
          state_path="$(system_path "$MANAGER_DATA_DIR/managed-users.json")"
          [[ -f "$config_path" ]] || die "$(kernel_display_name) 配置缺失，无法安全自动修复；请从备份恢复或选择全新部署"
          # 入口名的前缀两个内核通用（st- / ss- / ss-direct- / ss-udp- / anytls-），
          # 不同的只是容器与标识字段，因此只有这两样按内核取。
          if [[ ! -f "$state_path" ]] && jq -e \
            --arg container "$(kernel_managed_container)" --arg entry_key "$(kernel_managed_key)" '
            any(.[$container][]?; (.[$entry_key] // "") | test("^(st-|ss-|anytls-)"))
          ' "$config_path" >/dev/null 2>&1; then
            die "检测到已有用户连接配置，但用户资料缺失。为避免用户无法连接，脚本不会自动修改；请先恢复备份或选择重新安装"
          fi
          install_prerequisites || return 1
          fetch_latest_releases false || return 1
          # 与 check_updates 同理：修复流程不得把一个测试版静默换成正式版。
          if singbox_preview_deployed; then
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
      # 接管既有 sing-box 安装已经撤除（第二步 2f，公开 Issue #157）：本项目的全新
      # 安装只装 mihomo，不再把别人手工装的 sing-box 收编进来。
      # 覆盖重装那一条也一并撤掉——它现在意味着「在一套还活着的 sing-box 旁边再装
      # 一个 mihomo」，两套东西会抢同一批端口，装出来的机器不一定能用。
      # 因此这里明确走到头，并说清楚下一步该干什么，而不是给一个半通不通的选项。
      cat <<'EOF'

检测到这台服务器上已经有其他方式安装的 sing-box。

本项目不会接管它，也不会在它旁边再装一个内核——两套代理会抢同一批端口。
如果要在这台服务器上使用本项目，请先自行停用并清理那套 sing-box，再回到这里安装。
清理时请自己确认那套配置里有没有还在用的节点。
EOF
      return 0
      ;;
  esac
}

managed_uninstall_paths() {
  {
    all_kernel_deployment_paths
    # 管理器数据目录。今天与 /etc/sing-box 重合，去重后清单不变；
    # 漏掉它就是卸载之后用户资料还留在盘上。
    printf '%s\n' "$MANAGER_DATA_DIR"
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
  printf '%s、Nfuse、用户数据、运行配置、管理脚本和内部回滚材料已移除。\n' "$(kernel_display_name)"
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
# ============================================================================
# 搬迁管理器数据目录（公开 Issue #276，公开 Issue #172 三步走第三步）
#
# **这是一次性工具。** 存量机器上管理器自己的数据——用户资料、内部备份、AnyTLS
# 自签证书——还躺在老目录里，这里把它们搬到中立目录。正式机器执行完之后本节整段
# 撤除，并按项目惯例加静态断言钉住不得复活：项目所有者 2026-08-22 明确要求一次性
# 的东西跑完即撤，不在项目里留不必要的历史遗留。
#
# **撤的是这个入口，不是兜底。** LEGACY_MANAGER_DATA_DIR 与 load_runtime_config
# 里那行 `:=` 是公开版其他使用者的老机器仍在依赖的安全网，撤入口那一版要单独判断
# 它还有没有人依赖，不能顺手一起清掉。
# ============================================================================

# 搬到哪里。取全新安装用的那个中立目录，不另写一份字面量——两份写法迟早会漂。
MANAGER_DATA_MIGRATION_TARGET="$FRESH_INSTALL_MANAGER_DATA_DIR"

# 要搬的三样，**必须一起搬**。只搬其中一两样的后果在 src/00-bootstrap.sh 里写过：
# 证书目录被判成不存在时，上层会重新签发一张，所有 AnyTLS 用户当场连不上，
# 而过程中没有任何一步会报错。
# 每行输出「名称<TAB>源<TAB>目标」；源不存在的项也照样输出，由调用方自己判断。
manager_data_migration_items() {
  local target="$1"
  printf '用户资料\t%s\t%s\n' "$STATE_FILE" "$target/managed-users.json"
  printf '内部备份\t%s\t%s\n' "$BACKUP_DIR" "$target/backups"
  printf 'AnyTLS 证书\t%s\t%s\n' "$CERT_DIR" "$target/cert"
}

# 一个文件或一棵目录的内容指纹：每行「相对路径 权限 内容摘要」。
# 搬完之后拿它与搬之前的对照，证明落到新位置的是同一份东西，而不是「看起来像」。
# 不存在的路径给出一个固定标记，好让「两边都没有」也能对上——本机从没用过
# AnyTLS 时证书目录就是这种情形。
manager_data_tree_fingerprint() {
  local path="$1" entry
  if [[ ! -e "$path" ]]; then
    printf '（不存在）\n'
    return 0
  fi
  if [[ -f "$path" ]]; then
    printf '. %s %s\n' "$(stat -c '%a' "$path")" "$(sha256sum < "$path" | awk '{print $1}')" || return 1
    return 0
  fi
  (
    cd "$path" || exit 1
    find . -mindepth 1 \( -type f -o -type d \) -printf '%P\n' | LC_ALL=C sort |
      while IFS= read -r entry; do
        if [[ -d "$entry" ]]; then
          printf '%s/ %s -\n' "$entry" "$(stat -c '%a' "$entry")"
        else
          printf '%s %s %s\n' "$entry" "$(stat -c '%a' "$entry")" "$(sha256sum < "$entry" | awk '{print $1}')"
        fi
      done
  ) || return 1
}

migrate_manager_data_preflight() {
  local target="$1"
  [[ "$PROXY_KERNEL" == mihomo ]] || {
    printf '错误：本机跑的是 %s，本次搬迁只支持 mihomo 部署。\n' "$(kernel_display_name)" >&2
    return 1
  }
  environment_is_deployed || {
    echo '错误：本机尚未完成部署，请先选择「安装或修复环境」。' >&2
    return 1
  }
  need_cmd jq
  [[ -f "$STATE_FILE" ]] || {
    printf '错误：找不到本机的用户资料：%s\n' "$STATE_FILE" >&2
    return 1
  }
  # 目标目录必须还不存在。已经存在意味着这台机器上另有一份不知来历的数据，
  # 合并或覆盖都可能悄悄用错一份用户资料——宁可停下来让人自己看一眼。
  [[ ! -e "$target" && ! -L "$target" ]] || {
    printf '错误：目标目录已经存在：%s\n' "$target" >&2
    echo '为免把两份用户资料混在一起，搬迁不会开始。请自行确认它的来历后再决定。' >&2
    return 1
  }
}

# 只算不改：把要做的事全部打印出来，机器一个字节都不动。
# 换内核那条流程（公开 Issue #203）验证过这个形状——项目所有者要的就是在动生产
# 机器之前先看一眼。
preview_manager_data_migration() {
  local target="$1" name source destination users splits anytls
  users="$(jq '[.users[]?] | length' "$STATE_FILE")" || return 1
  splits="$(jq '[.splits[]?] | length' "$STATE_FILE")" || return 1
  anytls="$(jq '[.users[]? | select([.endpoints[]?.protocol] | index("anytls"))] | length' "$STATE_FILE")" || return 1
  printf '\n将要发生的事\n'
  printf '  管理器数据目录：%s → %s\n' "$MANAGER_DATA_DIR" "$target"
  printf '  用户 %s 个（其中 AnyTLS %s 个）、分流 %s 条：端口、密码、有效期、配额与累计用量都不变，客户端配置不用改。\n' \
    "$users" "$anytls" "$splits"
  printf '\n要搬的三样\n'
  while IFS=$'\t' read -r name source destination; do
    [[ -n "$name" ]] || continue
    if [[ -e "$source" ]]; then
      printf '  %s：%s → %s\n' "$name" "$source" "$destination"
    else
      printf '  %s：%s（本机没有这一项，跳过）\n' "$name" "$source"
    fi
  done < <(manager_data_migration_items "$target")
  printf '\n还会改动\n'
  printf '  管理配置 %s：与数据目录有关的三行改指新目录，其余取值逐字不动。\n' "$CONF_FILE"
  printf '  %s 的 systemd 单元：允许读取的路径里，证书目录改指新目录。\n' "$(kernel_display_name)"
  printf '  运行配置：AnyTLS 入口里的证书路径改指新目录。\n'
  printf '  服务会重启：所有用户会断线几秒，然后客户端自己重连。\n'
  printf '\n不会动的东西\n'
  printf '  老目录里不属于管理器的文件（例如 sing-box 自己的 config.json）原样留着。\n'
  printf '  老位置那三样，要等新位置逐字节校验通过之后才删除；校验不过则整体回滚，老位置一个字节不动。\n'
}

# 只改管理配置里与数据目录有关的那三行，其余逐字保留。
# **不能用 write_manager_config 整份重写**：那份模板会把握手端口、SNI、对外地址
# 这些使用者自己改过的取值一并按默认值写回去，等于顺手抹掉他的设置。
# 临时文件的名字必须落在受管临时路径的白名单里（is_managed_temp_path），
# 写法与 remove_obsolete_manager_config、write_global_sni_config 那几个兄弟调用点
# 完全一致。真机演练第一次就撞在这上面：用 "${CONF_FILE}.XXXXXX" 建出来的名字
# 登记不上，整条流程当场回滚，还在 /etc 下留了一个没人清的残file。
#
# 与那几个兄弟不同的是这里**不额外把旧配置备份进 BACKUP_DIR**：本函数只在搬迁
# 流程里被调用，而那条流程一开始就照了完整环境快照，旧配置已经在里面；往
# BACKUP_DIR 里再写一个文件，反而会让「新位置的内部备份与搬迁前逐字节一致」
# 那条校验因为多出一个文件而失败。
rewrite_manager_config_data_dir() {
  local target="$1" tmp
  tmp="$(mktemp "$(dirname "$CONF_FILE")/.sb-user-manager.conf.XXXXXX")" || return 1
  # 兄弟调用点写的是不带守卫的 register_temp_path（它自己 die）；这里必须带，
  # 因为本函数是 run_step_or_rollback 的目标，静态门禁要求受管步骤里每条命令
  # 都说得出失败。
  register_temp_path "$tmp" || return 1
  if ! {
        grep -v '^\(MANAGER_DATA_DIR\|STATE_FILE\|BACKUP_DIR\)=' "$CONF_FILE"
        printf 'MANAGER_DATA_DIR="%s"\n' "$target"
        printf 'STATE_FILE="%s/managed-users.json"\n' "$target"
        printf 'BACKUP_DIR="%s/backups"\n' "$target"
      } > "$tmp"; then
    rm -f -- "$tmp" # managed-step-errexit-ok: best-effort cleanup before forced failure
    return 1
  fi
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; } # managed-step-errexit-ok: best-effort cleanup before forced failure
  chown root:root "$tmp" 2>/dev/null || true
  mv -- "$tmp" "$CONF_FILE" || return 1
}

# 复制，不是移动：中途任何一步失败时，老位置的数据始终原地未动。
copy_manager_data_to_target() {
  local state="$1" backups="$2" cert="$3"
  cp -a -- "$state" "$STATE_FILE" || return 1
  [[ ! -e "$backups" ]] || cp -a -- "$backups" "$BACKUP_DIR" || return 1
  [[ ! -e "$cert" ]] || cp -a -- "$cert" "$CERT_DIR" || return 1
}

# 运行配置与 systemd 单元里还有没有指着老证书目录的字面量。
# 漏掉任何一处，内核都会去一个马上要被删掉的目录里读证书。
verify_no_stale_cert_references() {
  local legacy_cert="$1" config service unit
  config="$(kernel_config_path)" || return 1
  service="$(kernel_service_name)" || return 1
  unit="$(system_path "/etc/systemd/system/${service}.service")" || return 1
  if [[ -f "$config" ]] && grep -Fq -- "$legacy_cert" "$config"; then
    printf '错误：运行配置里仍写着旧证书目录：%s\n' "$legacy_cert" >&2
    return 1
  fi
  if [[ -f "$unit" ]] && grep -Fq -- "$legacy_cert" "$unit"; then
    printf '错误：%s 的 systemd 单元里仍写着旧证书目录：%s\n' "$service" "$legacy_cert" >&2
    return 1
  fi
}

# 搬完之后的自检。任一条不过都会触发整体回滚——一台搬了一半的机器比没搬更糟。
verify_manager_data_migration() {
  local legacy_cert="$1" before_state="$2" before_backup="$3" before_cert="$4" after
  kernel_service_is_active || {
    printf '错误：%s 没有起来。\n' "$(kernel_display_name)" >&2
    return 1
  }
  systemctl is-active --quiet nfuse || { echo '错误：Nfuse 没有起来。' >&2; return 1; }
  after="$(manager_data_tree_fingerprint "$STATE_FILE")" || return 1
  [[ "$after" == "$before_state" ]] || { echo '错误：新位置的用户资料与搬迁前不一致。' >&2; return 1; }
  after="$(manager_data_tree_fingerprint "$BACKUP_DIR")" || return 1
  [[ "$after" == "$before_backup" ]] || { echo '错误：新位置的内部备份与搬迁前不一致。' >&2; return 1; }
  after="$(manager_data_tree_fingerprint "$CERT_DIR")" || return 1
  [[ "$after" == "$before_cert" ]] || { echo '错误：新位置的 AnyTLS 证书与搬迁前不一致。' >&2; return 1; }
  verify_no_stale_cert_references "$legacy_cert" || return 1
}

# 校验通过之后才删老位置，而且**只删这三样**：老目录里可能还有 sing-box 自己的
# config.json，那不是管理器的东西。目录本身空了才顺手删掉。
remove_legacy_manager_data() {
  local state="$1" backups="$2" cert="$3" legacy_dir="$4"
  rm -f -- "$state" || return 1
  rm -rf -- "$backups" || return 1
  rm -rf -- "$cert" || return 1
  rmdir -- "$legacy_dir" 2>/dev/null || true
}

migrate_manager_data_directory() {
  local target work backup iface answer kernel_service
  local legacy_dir legacy_state legacy_backup legacy_cert
  local before_state before_backup before_cert
  resolve_deployment_kernel || return 1
  load_runtime_config || return 1
  target="$MANAGER_DATA_MIGRATION_TARGET"
  # 对照：已经在中立目录上的机器要明确说「无需搬迁」，而不是空跑一遍流程。
  if [[ "$MANAGER_DATA_DIR" == "$target" ]]; then
    printf '本机的管理器数据已经在中立目录里（%s），无需搬迁。\n' "$target"
    return 0
  fi
  migrate_manager_data_preflight "$target" || return 1
  if ! acquire_operation_lock; then
    log "错误：$OPERATION_LOCK_ERROR"
    return 1
  fi
  ensure_safe_ssh_for_kernel_restart || { release_operation_lock; return 0; }
  if ! preview_manager_data_migration "$target"; then
    echo '错误：搬迁没有开始，本机未做任何改动。' >&2
    release_operation_lock
    return 1
  fi
  # 这一步会删掉老位置的用户资料、备份与证书，是不可逆操作。ADR 0032 要求在
  # 这种操作之前当场清点服务器外的退路，而不是许一句「失败了可以从快照恢复」的
  # 空头承诺——快照只服务于自动回滚，菜单里没有事后手工恢复它的入口。
  print_offsite_recovery_status
  read -r -p "确认现在把管理器数据搬到 ${target}？[y/N]：" answer || { release_operation_lock; return 1; }
  [[ "$answer" =~ ^[Yy]$ ]] || {
    echo '已取消，本机未做任何改动。'
    release_operation_lock
    return 0
  }
  iface="$(default_network_interface)" || { release_operation_lock; die '无法识别默认网络接口'; }
  [[ -n "$iface" ]] || { release_operation_lock; die '无法识别默认网络接口'; }
  legacy_dir="$MANAGER_DATA_DIR"
  legacy_state="$STATE_FILE"
  legacy_backup="$BACKUP_DIR"
  legacy_cert="$CERT_DIR"
  before_state="$(manager_data_tree_fingerprint "$legacy_state")" || { release_operation_lock; return 1; }
  before_backup="$(manager_data_tree_fingerprint "$legacy_backup")" || { release_operation_lock; return 1; }
  before_cert="$(manager_data_tree_fingerprint "$legacy_cert")" || { release_operation_lock; return 1; }
  work="$(mktemp -d /tmp/sb-user-manager.XXXXXX)" || { release_operation_lock; return 1; }
  register_temp_path "$work" || { rm -rf -- "$work"; release_operation_lock; return 1; }
  create_environment_backup || { rm -rf -- "$work"; release_operation_lock; return 1; }
  backup="$ENV_BACKUP"
  # 变量先切到新目录，再往下走：后面每一步——建目录、复制、派生证书路径、写单元里
  # 允许读取的路径——用的都是这一组取值。回滚时由 restore_manager_data_variables
  # 拨回去。（新目录能不能进事务的清理清单，靠的是 is_environment_recovery_path
  # 里那条字面量，不是这里的赋值——那条字面量正是为「崩在改配置之前」那种情形加的。）
  MANAGER_DATA_DIR="$target"
  resolve_manager_data_paths || { rm -rf -- "$work"; release_operation_lock; return 1; }
  STATE_FILE="$target/managed-users.json"
  BACKUP_DIR="$target/backups"
  restore_manager_data_variables() {
    MANAGER_DATA_DIR="$legacy_dir"
    resolve_manager_data_paths || true
    STATE_FILE="$legacy_state"
    BACKUP_DIR="$legacy_backup"
  }
  rollback_migrate_manager_data() {
    local rc="${1:-$?}"
    trap - ERR
    clear_signal_rollback
    kernel_service="$(kernel_service_name)" || kernel_service=''
    systemctl stop sb-user-expiry.timer nfuse 2>/dev/null || true
    [[ -z "$kernel_service" ]] || systemctl stop "$kernel_service" 2>/dev/null || true
    cleanup_deploy_created_paths "$target"
    # 变量拨回老取值**必须在恢复快照之前**：environment_backup_paths 里管理器数据
    # 目录那一条按当前取值算，不拨回去，恢复流程会去新目录找快照里根本没有的东西；
    # 而且回滚之后留在进程里的仍是刚被删掉的新路径。
    restore_manager_data_variables
    restore_failed_environment_change 搬迁管理器数据目录 "$backup" "$work"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl restart nfuse >/dev/null 2>&1 || true
    [[ -z "$kernel_service" ]] || systemctl restart "$kernel_service" >/dev/null 2>&1 || true
    systemctl start sb-user-expiry.timer >/dev/null 2>&1 || true
    release_operation_lock
    return "$rc"
  }
  if ! begin_environment_transaction "migrate-manager-data" "$backup" "$target"; then
    restore_manager_data_variables
    rm -rf -- "$work"
    release_operation_lock
    return 1
  fi
  trap rollback_migrate_manager_data ERR
  set_signal_rollback rollback_migrate_manager_data
  run_step_or_rollback rollback_migrate_manager_data install -d -m 700 "$target" || return 1
  run_step_or_rollback rollback_migrate_manager_data copy_manager_data_to_target \
    "$legacy_state" "$legacy_backup" "$legacy_cert" || return 1
  run_step_or_rollback rollback_migrate_manager_data rewrite_manager_config_data_dir "$target" || return 1
  # 证书路径写在 AnyTLS 入口里，单元里允许读取的路径也写着证书目录；两处都要跟着改。
  run_step_or_rollback rollback_migrate_manager_data rebuild_protocol_inbounds anytls || return 1
  run_step_or_rollback rollback_migrate_manager_data write_systemd_units "$iface" || return 1
  run_step_or_rollback rollback_migrate_manager_data kernel_check_default_install || return 1
  run_step_or_rollback rollback_migrate_manager_data activate_managed_services || return 1
  run_step_or_rollback rollback_migrate_manager_data verify_manager_data_migration \
    "$legacy_cert" "$before_state" "$before_backup" "$before_cert" || return 1
  run_step_or_rollback rollback_migrate_manager_data remove_legacy_manager_data \
    "$legacy_state" "$legacy_backup" "$legacy_cert" "$legacy_dir" || return 1
  run_step_or_rollback rollback_migrate_manager_data complete_environment_change "$work" || return 1
  release_operation_lock
  log "管理器数据已搬到 ${target}；搬迁前的完整环境快照在 $backup"
  printf '\n搬迁完成。请自己连一次确认客户端还能用——客户端配置不需要改。\n'
  if [[ -d "$legacy_dir" ]]; then
    printf '\n老目录 %s 还留着这些不属于管理器的东西，本次搬迁没有碰它们：\n' "$legacy_dir"
    find "$legacy_dir" -mindepth 1 -maxdepth 1 -printf '  %f\n' | LC_ALL=C sort
  else
    printf '\n老目录 %s 已经空了，一并删掉了。\n' "$legacy_dir"
  fi
}

check_updates() {
  local current_kernel current_nfuse current_manager current_channel kernel_latest_label answer needs_update=false update_manager=false manager_latest_label kernel_label
  resolve_deployment_kernel || return 1
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
  # 不再显示「最新测试版是多少」——那需要另查一次 GitHub 的预发布列表，
  # 而这条线已经不跟踪了。见 singbox_preview_deployed 上方的说明。
  if singbox_preview_deployed; then
    current_channel=preview
    kernel_latest_label='不跟踪（测试版）'
    LATEST_KERNEL_VERSION="$current_kernel"
  else
    current_channel=stable
    kernel_latest_label="$LATEST_KERNEL_VERSION"
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
    echo "提示：本机装的是 sing-box 测试版。测试版通道已不再由本脚本跟踪或更新，"
    echo "      这里也不会把它换成正式版；要换请自行处理 sing-box 二进制。"
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

OPERATION_LOCK_ERROR=""
OPERATION_LOCK_HELD=false

acquire_operation_lock() {
  local lock_file lock_directory
  OPERATION_LOCK_ERROR=""
  [[ "$OPERATION_LOCK_HELD" != true ]] || return 0
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
  OPERATION_LOCK_HELD=true
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
  OPERATION_LOCK_HELD=false
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
  ensure_safe_ssh_for_kernel_restart || return 0
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
    choice=$((10#$choice))
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

# systemd 状态的中文说法。菜单与非交互只读入口共用同一处，避免两边各说一套。
service_state_label() {
  case "${1:-}" in
    active) printf '运行中\n';;
    inactive) printf '未运行\n';;
    failed) printf '启动失败\n';;
    activating) printf '启动中\n';;
    deactivating) printf '停止中\n';;
    *) printf '未知（%s）\n' "${1:-unknown}";;
  esac
}

show_service_status() {
  local service state description
  printf '\n%-24s %-12s %s\n' '项目' '状态' '说明'
  printf '%-24s %-12s %s\n' '------------------------' '------------' '------------------------------'
  while IFS='|' read -r service description; do
    state="$(service_state_label "$(systemctl is-active "$service" 2>/dev/null || true)")"
    printf '%-24s %-12s %s\n' "$service" "$state" "$description"
  done < <(
    printf '%s.service|负责用户连接和分流\n' "$(kernel_service_name)"
    cat <<'EOF'
nfuse.service|负责流量统计和用量限制
sb-user-expiry.timer|负责自动停用到期用户
EOF
  )
  printf '\n流量统计通信：%s\n' "$([[ -S /run/nfuse.sock ]] && echo '正常' || echo '未就绪，请检查 Nfuse 服务')"
  printf '管理脚本：%s\n' "$([[ -x /usr/local/sbin/sb-user-manager ]] && echo '已安装' || echo '未安装')"
}

# 用户与流量统计的一致性检查。
#
# 「条目在不在」「流量记录对不对」两个内核完全一样，因此这段程序共用一份：
# 托管容器与标识字段经适配层取得，一个 SS2022 + ShadowTLS 端点会产生几个
# 条目也一样（sing-box 三个、mihomo 一个）。真正不同的只有「条目里哪些字段
# 要对」，那一段由适配层按内核注入 —— 注入点在 issue() 之后，因为它要用。
collect_user_consistency_issue_rows() {
  local config_json="$1" nfuse_json="$2" container entry_key shadowtls_prefixes shape_def
  container="$(kernel_managed_container)" || return 1
  entry_key="$(kernel_managed_key)" || return 1
  shadowtls_prefixes="$(kernel_shadowtls_entry_prefixes)" || return 1
  shape_def="$(kernel_user_entry_shape_def)" || return 1
  printf '%s\n%s\n' "$config_json" "$nfuse_json" | jq -rs --slurpfile state "$STATE_FILE" \
    --arg container "$container" --arg entry_key "$entry_key" \
    --argjson st_prefixes "$shadowtls_prefixes" --argjson strict_mode "${SHADOWTLS_STRICT_MODE:-true}" '
    .[0] as $config | .[1] as $nfuse | $state[0] as $state |
    def issue($repairable; $message): [($repairable | tostring), $message] | @tsv;
    def entry_exists($entry): any($config[$container][]?; .[$entry_key] == $entry);
    def nfuse_user_exists($name): any($nfuse[]; .name == $name);
    def nfuse_tier_exists($name; $tier): any($nfuse[]; .name == $name and .tier == $tier);
    def nfuse_port_exists($name; $port):
      any($nfuse[] | select(.name == $name) | .ports[]?; .start <= $port and .end >= $port);
    '"$shape_def"'
    $state.users[] as $user |
    $user.name as $name |
    $user.status as $status |
    ($user.metered // ($user.limit_gib != null)) as $metered |
    (if $metered then "a" else "c" end) as $expected_tier |
    any($user.endpoints[]?; .protocol == "ss2022" and .transport == "shadowtls") as $has_legacy |
    ((if ($user.endpoints | type) == "array" then $user.endpoints[]
      else {protocol:($user.protocol // "ss2022"),transport:($user.transport // "shadowtls"),port:$user.port} end) as $endpoint |
     $endpoint.protocol as $protocol |
     ($endpoint.transport // "-") as $transport |
     $endpoint.port as $port |
     (if $protocol == "anytls" then ["anytls-" + $name]
      elif $transport == "shadowtls" then [$st_prefixes[] + $name]
      elif $has_legacy then ["ss-direct-" + $name]
      else ["ss-" + $name] end) as $expected_tags |
     $expected_tags[0] as $expected |
     ($expected_tags[] as $tag |
       if $status == "active" and (entry_exists($tag) | not) then
         issue(true; "[可自动修复] 用户 \($name) 缺少连接配置（\($tag)）")
       elif $status == "disabled" and entry_exists($tag) then
         issue(true; "[可自动修复] 已停用用户 \($name) 仍保留连接配置（\($tag)）")
       else empty end),
     sbm_entry_shape_issues($name; $protocol; $transport; $port; $status; $has_legacy; $expected),
     (if nfuse_user_exists($name) and nfuse_tier_exists($name; $expected_tier) and
         (nfuse_port_exists($name; $port) | not) then
        issue(true; "[可自动修复] 用户 \($name) 的端口 \($port) 尚未接入流量统计")
      else empty end)),
    (if (nfuse_user_exists($name) | not) then
       issue(true; "[可自动修复] 用户 \($name) 缺少流量统计记录")
     elif (nfuse_tier_exists($name; $expected_tier) | not) then
       issue(false; "[需要处理] 用户 \($name) 的流量记录类型不正确（应为 \(if $metered then "计量" else "不限额统计" end)）")
     else empty end)
  '
}

audit_consistency() {
  local config_json nfuse_json skeleton_missing_rows skeleton_path user_issue_rows issue_repairable issue_message expiry_rows split_rows split name split_status rule_tag out_tag scope scope_user scope_user_status scope_tags expires
  local split_rule_url split_rule_file rule_source_drift split_rule_geo split_cond
  local preset_link_rows preset_kind preset_reason managed_tags legacy_cleanup legacy_count
  local normalise_program skeleton_program skeleton_filter sub_rule_name managed_lines
  local unit_drift_rows unit_path unit_drift_rc=0 handshake_host
  AUDIT_ISSUES=0
  AUDIT_REPAIRABLE=0
  config_json="$(kernel_normalized_config)" || return 1
  nfuse_json="$(nfuse list --json)" || return 1
  # 类型校验与 inbound 还原折在同一次 jq 调用里：本函数的 jq 调用次数受单元测试的
  # 性能门禁看守，不能为还原再多开一个进程。程序按内核分派，与
  # shared_preset_runtime_is_current 共用 kernel_config_normalise_program。
  normalise_program="$(kernel_config_normalise_program)" || return 1
  config_json="$(jq -ce "$normalise_program" <<<"$config_json")" || return 1
  jq -e 'type == "array"' <<<"$nfuse_json" >/dev/null || return 1
  user_issue_rows="$(collect_user_consistency_issue_rows "$config_json" "$nfuse_json")" || return 1
  expiry_rows="$(jq -r '.users[] | select(.expires_at != null) | [.name, (.expires_at | tostring)] | @tsv' "$STATE_FILE")" || return 1
  split_rows="$(jq -c '.splits[]?' "$STATE_FILE")" || return 1
  # 骨架段（log、dns、route.final、experimental 等）只在全新安装或接管时写入，
  # 此后从不复查；上游废弃或改写字段时，存量配置会悄悄过期而没有任何提示。
  # 这里不另写一份「期望骨架」，而是把 src/05-kernel.sh 那份补齐程序应用到当前
  # 配置上反推：被补上的就是缺项。两处共用同一定义，不会各自漂移。
  # 期望值为空容器的路径要不要排除**随内核不同**，判断在适配层：sing-box 的
  # format 会把空数组整个省略，不排除就会在没有分流的服务器上误报；mihomo 的
  # 规范化是 jq 本身，空数组原样在，排除反而会把真缺项一并放过（公开 Issue #189
  # 有实测与对照）。
  skeleton_program="$(kernel_skeleton_ensure_program)" || return 1
  if kernel_skeleton_skips_empty_containers; then
    skeleton_filter='| map(. as $p | ($full | getpath($p)) as $value | ($value | type) as $kind
        | select(($kind != "array" and $kind != "object") or ($value | length) > 0))'
  else
    skeleton_filter=''
  fi
  skeleton_missing_rows="$(jq -r '. as $orig | ($orig | '"$skeleton_program"') as $full |
    [$full | paths]
    | map(. as $p | select(($orig | getpath($p)) == null))
    | map(. as $p | select(($p[:-1] | length) == 0 or ($orig | getpath($p[:-1])) != null))
    '"$skeleton_filter"'
    | map(map(tostring) | join("."))
    | .[]' <<<"$config_json")" || return 1
  printf '\n服务与配置检查结果\n\n'
  while IFS= read -r skeleton_path; do
    [[ -n "$skeleton_path" ]] || continue
    printf '  [需要处理] 运行配置缺少骨架项 %s\n' "$skeleton_path"
    ((AUDIT_ISSUES+=1))
  done <<<"$skeleton_missing_rows"
  while IFS=$'\t' read -r name expires; do
    [[ -n "$name" ]] || continue
    if ! parse_expiry_epoch "$expires" >/dev/null; then
      printf '  [需要处理] 用户 %s 的有效期格式无效（%s）\n' "$name" "$expires"
      ((AUDIT_ISSUES+=1))
    fi
  done <<<"$expiry_rows"
  while IFS=$'\t' read -r issue_repairable issue_message; do
    [[ -n "$issue_message" ]] || continue
    printf '  %s\n' "$issue_message"
    ((AUDIT_ISSUES+=1))
    [[ "$issue_repairable" != true ]] || ((AUDIT_REPAIRABLE+=1))
  done <<<"$user_issue_rows"

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
       elif ($split.url // $split.rule_file // "") != ($preset.url // $preset.rule_file // "") or
            ($split.rule_behavior // "") != ($preset.rule_behavior // "") or
            ($split.rule_url // "") != ($preset.rule_url // "") or
            ($split.rule_geo // []) != ($preset.rule_geo // []) then [$split.name,"规则","保存内容未同步"] else empty end
     else empty end) | @tsv
  ' "$STATE_FILE")" || return 1
  while IFS=$'\t' read -r name preset_kind preset_reason; do
    [[ -n "$name" ]] || continue
    printf '  [可自动修复] 分流 %s 的预置%s关联异常（%s）\n' "$name" "$preset_kind" "$preset_reason"
    ((AUDIT_ISSUES+=1)); ((AUDIT_REPAIRABLE+=1))
  done <<<"$preset_link_rows"

  # mihomo 的托管分流全部关在一个 sub-rule 里，顶层 rules 只留一条派发；
  # 因此这里先把那一块取出来，循环里逐条分流去里面认自己的行。
  # 派发在不在是另一回事，循环之后单独查。
  sub_rule_name="$MIHOMO_MANAGED_SUB_RULE"
  managed_lines='[]'
  if [[ "$PROXY_KERNEL" == mihomo ]]; then
    managed_lines="$(jq -c --arg sub "$sub_rule_name" '(.["sub-rules"][$sub] // [])' <<<"$config_json")" || return 1
  fi
  while IFS= read -r split; do
    [[ -n "$split" ]] || continue
    name="$(jq -r '.name' <<<"$split")" || return 1
    split_status="$(jq -r '.status' <<<"$split")" || return 1
    scope="$(jq -r '.scope' <<<"$split")" || return 1
    scope_user="$(jq -r 'if .scope == "user" then (.user // "") else "" end' <<<"$split")" || return 1
    rule_tag="$(split_runtime_rule_tag_from_json "$split")" || return 1
    out_tag="$(split_runtime_out_tag_from_json "$split")" || return 1
    # 这条分流在 mihomo 规则行里的匹配条件。geo 来源没有规则集标签，
    # 认行只能靠条件（公开 Issue #219）；sing-box 那几支不看这个值。
    split_rule_geo="$(split_rule_geo_from_json "$split")" || return 1
    split_cond="$(mihomo_split_match_condition "$rule_tag" "$split_rule_geo")" || return 1
    scope_user_status=""
    if [[ -n "$scope_user" ]]; then
      scope_user_status="$(jq -r --arg name "$scope_user" 'first(.users[]? | select(.name == $name) | .status) // ""' "$STATE_FILE")" || return 1
    fi
    if [[ "$split_status" == active && "$scope_user_status" == disabled ]]; then
      # 用户已停用时这条专属分流不会写入运行配置，只需确认没有残留规则
      scope_tags="$(split_user_inbound_tags "$scope_user")" || return 1
      if split_audit_user_rule_present "$config_json" "$managed_lines" "$rule_tag" "$out_tag" "$scope_tags" any "$split_cond"; then
        printf '  [可自动修复] 分流 %s 指定的用户 %s 已停用，但连接规则仍在生效\n' "$name" "$scope_user"
        ((AUDIT_ISSUES+=1)); ((AUDIT_REPAIRABLE+=1))
      fi
    elif [[ "$split_status" == active ]]; then
      if ! split_audit_runtime_complete "$config_json" "$managed_lines" "$rule_tag" "$out_tag" "$split_cond"; then
        printf '  [可自动修复] 分流 %s 的规则或出口配置不完整\n' "$name"
        ((AUDIT_ISSUES+=1)); ((AUDIT_REPAIRABLE+=1))
      fi
      # 规则集的来源有没有漂（公开 Issue #218）。mihomo 独有：只有它才有
      # 「本机文件」与「网址自动下载」两种形状，而两者互换时内核一个字都不说。
      if [[ "$PROXY_KERNEL" == mihomo ]]; then
        split_rule_url="$(split_rule_url_from_json "$split")" || return 1
        split_rule_file="$(jq -r '(.rule_file // "")' <<<"$split")" || return 1
        if [[ -n "$split_rule_file" ]]; then
          rule_source_drift="$(mihomo_rule_set_source_drift "$config_json" "$rule_tag" "$split_rule_url" "$split_rule_file")" || return 1
          if [[ -n "$rule_source_drift" ]]; then
            printf '  [可自动修复] 分流 %s 的规则集来源与保存的不一致（%s）\n' "$name" "$rule_source_drift"
            ((AUDIT_ISSUES+=1)); ((AUDIT_REPAIRABLE+=1))
          fi
        fi
      fi
      if [[ -n "$scope_user" ]] && ! user_exists "$scope_user"; then
        printf '  [需要处理] 分流 %s 指定的用户 %s 已不存在\n' "$name" "$scope_user"
        ((AUDIT_ISSUES+=1))
      elif [[ -n "$scope_user" ]]; then
        scope_tags="$(split_user_inbound_tags "$scope_user")" || return 1
        if ! split_audit_user_rule_present "$config_json" "$managed_lines" "$rule_tag" "$out_tag" "$scope_tags" all "$split_cond"; then
          printf '  [可自动修复] 分流 %s 尚未覆盖用户 %s 的全部连接\n' "$name" "$scope_user"
          ((AUDIT_ISSUES+=1)); ((AUDIT_REPAIRABLE+=1))
        fi
      fi
    else
      if [[ "$scope" == all ]]; then
        if split_audit_scope_all_rule_present "$config_json" "$managed_lines" "$rule_tag" "$out_tag" "$split_cond"; then
          printf '  [可自动修复] 已停用分流 %s 仍有连接规则生效\n' "$name"
          ((AUDIT_ISSUES+=1)); ((AUDIT_REPAIRABLE+=1))
        fi
      elif [[ -n "$scope_user" ]]; then
        scope_tags="$(split_user_inbound_tags "$scope_user")" || return 1
        if split_audit_user_rule_present "$config_json" "$managed_lines" "$rule_tag" "$out_tag" "$scope_tags" any "$split_cond"; then
          printf '  [可自动修复] 已停用分流 %s 仍有连接规则生效\n' "$name"
          ((AUDIT_ISSUES+=1)); ((AUDIT_REPAIRABLE+=1))
        fi
      fi
    fi
  done <<<"$split_rows"

  # mihomo 独有的一条：托管分流那一块在不在，与顶层那条派发在不在，必须一致。
  # 派发被删掉时整块分流一条都不生效，而运行配置本身完全合法、服务照常运行
  # ——没有这条检查就没有任何地方会说出来。sing-box 没有对应物：它的路由规则
  # 直接摆在 route.rules 里，不经过派发这一层。
  if [[ "$PROXY_KERNEL" == mihomo ]]; then
    if ! split_audit_dispatch_consistent "$config_json" "$managed_lines"; then
      printf '  [可自动修复] 托管分流的派发规则与分流内容不一致\n'
      ((AUDIT_ISSUES+=1)); ((AUDIT_REPAIRABLE+=1))
    fi
  fi

  # 旧版分流残留只对 sing-box 有意义：托管分流在 mihomo 上从第二步 2d 才开始
  # 存在，不可能有「按旧写法留下的残留」。这里与 legacy_split_cleanup_pending
  # 用同一条判断，不靠「查出来恰好是空的」。
  legacy_count=0
  if [[ "$PROXY_KERNEL" == singbox ]]; then
    managed_tags="$(collect_managed_split_tags)" || return 1
    legacy_cleanup="$(collect_legacy_split_cleanup_plan_from_config "$config_json" "$managed_tags")" || return 1
    legacy_count="$(jq '.rule_tags | length' <<<"$legacy_cleanup")" || return 1
  fi
  if ((legacy_count > 0)); then
    printf '  [可自动修复] 检测到 %s 条与当前预置重复的旧版分流规则\n' "$legacy_count"
    ((AUDIT_ISSUES+=1)); ((AUDIT_REPAIRABLE+=1))
  fi

  # systemd 单元只在部署、接管与修复三条路径上写出，升级脚本从来不刷新它们
  # （公开 Issue #190）。因此新版本改了单元内容时，存量机器会静静地落在旧单元
  # 上；这里把差异查出来，改由「自动修复」去写——重写单元必然要重启服务。
  unit_drift_rows="$(collect_unit_drift_rows)" || unit_drift_rc=$?
  if [[ "${unit_drift_rc:-0}" == 2 ]]; then
    printf '  [需要处理] 无法识别默认网络接口，未能核对服务单元\n'
    ((AUDIT_ISSUES+=1))
  elif [[ "${unit_drift_rc:-0}" != 0 ]]; then
    printf '  [需要处理] 未能生成用于比对的服务单元，本项未执行\n'
    ((AUDIT_ISSUES+=1))
  else
    while IFS= read -r unit_path; do
      [[ -n "$unit_path" ]] || continue
      printf '  [可自动修复] 服务单元 %s 与当前版本不一致\n' "$unit_path"
      ((AUDIT_ISSUES+=1)); ((AUDIT_REPAIRABLE+=1))
    done <<<"$unit_drift_rows"
  fi

  # 严格模式下，握手目标不支持 TLS 1.3 会让所有 ShadowTLS 入口静静不通
  # （公开 Issue #182 实测出这条行为，#194 据此加了这项检查）。三个前提缺一
  # 不可，见 shadowtls_handshake_probe_applies。
  if shadowtls_handshake_probe_applies; then
    while IFS= read -r handshake_host; do
      [[ -n "$handshake_host" ]] || continue
      case "$(probe_handshake_tls13 "$handshake_host" "$HANDSHAKE_PORT")" in
        tls13) ;;
        tls-older)
          printf '  [需要处理] ShadowTLS 握手目标 %s:%s 不支持 TLS 1.3；严格模式开着时这些入口无法连接，请在「默认连接域名（SNI）」里换一个支持 TLS 1.3 的域名\n' \
            "$handshake_host" "$HANDSHAKE_PORT"
          ((AUDIT_ISSUES+=1));;
        not-tls)
          printf '  [需要处理] ShadowTLS 握手目标 %s:%s 上不是 TLS 服务；严格模式开着时这些入口无法连接，请在「默认连接域名（SNI）」里换一个域名\n' \
            "$handshake_host" "$HANDSHAKE_PORT"
          ((AUDIT_ISSUES+=1));;
        invalid)
          printf '  [需要处理] ShadowTLS 握手目标不合法（%s:%s）\n' "$handshake_host" "$HANDSHAKE_PORT"
          ((AUDIT_ISSUES+=1));;
        *)
          # 探不通多半是临时网络问题，会自愈：标记但不计为问题。计成问题的话，
          # 一次网络抖动就会把这台机器的检查刷红，还会挡住要求「只读检查零失败」
          # 的写入型验收。
          printf '  [提示] 这次没能连上 ShadowTLS 握手目标 %s:%s，未能确认它是否支持 TLS 1.3\n' \
            "$handshake_host" "$HANDSHAKE_PORT";;
      esac
    done <<<"$(active_shadowtls_handshake_hosts)"
  fi

  if ((AUDIT_ISSUES==0)); then echo '  一切正常：用户、分流、连接配置和流量统计相互一致。'
  else printf '\n共发现 %d 个问题，其中 %d 个可以自动修复。\n' "$AUDIT_ISSUES" "$AUDIT_REPAIRABLE"
  fi
}

repair_consistency() {
  local environment_backup nfuse_json user_rows split_rows parsed user name status port metered fragment limit anchor expected_tier
  local split split_status scope scope_user url upstream out_tag rule_tag
  local unit_drift="" unit_iface=""
  # 单元的比对在改动任何东西之前做完：修复流程后面会重启服务，
  # 那时再去比对读到的已经不是「修复前的样子」。
  if unit_drift="$(collect_unit_drift_rows)" && [[ -n "$unit_drift" ]]; then
    unit_iface="$(default_network_interface)" || unit_drift=""
    [[ -n "$unit_iface" ]] || unit_drift=""
  else
    unit_drift=""
  fi
  nfuse_json="$(nfuse list --json)" || return 1
  jq -e 'type == "array"' <<<"$nfuse_json" >/dev/null || return 1
  user_rows="$(jq -c '.users[]' "$STATE_FILE")" || return 1
  split_rows="$(jq -c '.splits[]?' "$STATE_FILE")" || return 1
  ensure_safe_ssh_for_kernel_restart || return 0
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
      log "无法自动修复：用户「$(jq -r '.name // "(无名)"' <<<"$user")」的记录不完整，请先在「用户管理」中检查这一条"
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
  # 分流记录的三选一来源：网址、本机规则文件、GeoSite／GeoIP 类别（公开 Issue #219）。
  # **geo 类别那种既没有网址也没有规则文件**，状态里只有一份类别清单；这里漏掉它的
  # 后果不是报错，而是整条自动修复失败并回滚，使用者看不到任何原因——正式服务器
  # Air 上就是这么坏的（公开 Issue #265）。判据与迁移包校验、重建分流配置保持一致。
  while IFS= read -r split; do
    [[ -n "$split" ]] || continue
    if ! jq -e '
      select((.name|type)=="string" and (.name|length)>0) |
      select(.status=="active" or .status=="disabled") |
      select(.scope=="all" or .scope=="user") |
      select(
        (((.url // .rule_file)|type)=="string" and ((.url // .rule_file)|length)>0) or
        ((.rule_geo|type)=="array" and (.rule_geo|length)>0)
      ) |
      select((.upstream|type)=="object")
    ' <<<"$split" >/dev/null; then
      log "无法自动修复：分流「$(jq -r '.name // "(无名)"' <<<"$split")」的记录不完整，请先在「分流管理」中检查这一条"
      rollback_active_operation 1 || true
      return 1
    fi
    scope="$(jq -er '.scope' <<<"$split")" || { rollback_active_operation 1 || true; return 1; }
    scope_user="$(jq -er '.user // ""' <<<"$split")" || { rollback_active_operation 1 || true; return 1; }
    if [[ "$scope" == user ]] && ! user_exists "$scope_user"; then
      log "无法自动修复：分流「$(jq -r '.name // "(无名)"' <<<"$split")」指向一个不存在的用户，请先在「分流管理」中处理这一条"
      rollback_active_operation 1 || true
      return 1
    fi
  done <<<"$split_rows"
  run_managed_step rebuild_all_split_configs || return 1
  run_managed_step nfuse persist || return 1
  # 单元与当前版本不一致时重写它们。写完必须 daemon-reload 并重新激活，
  # 否则 systemd 仍按旧单元跑，审计下一次还会报同一条——「修了但没生效」
  # 比没修更难查。重新激活走的正是部署时用的那一套顺序。
  # 识别不出默认网络接口时不写：那种情况下 nfuse 的单元会指向一个错的接口。
  if [[ -n "$unit_drift" ]]; then
    run_managed_step write_systemd_units "$unit_iface" || return 1
    run_managed_step activate_managed_services || return 1
  fi
  run_managed_step check_singbox_and_restart || return 1
  finish_managed_operation || return 1
  log "服务与配置已自动修复；修复前完整备份：$environment_backup"
}

prompt_consistency() {
  local answer
  # 护栏自己已经提示并暂停过，用 MENU_RETURNED 告诉调用点不要再暂停一次
  ensure_management_environment_ready || { MENU_RETURNED=true; return 0; }
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
  STATE_FILE="$MANAGER_DATA_DIR/managed-users.json"
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

redact_diagnostic_file_with_shell_tools() {
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

write_diagnostic_redactions_nul() {
  local i
  for ((i=0; i<DIAGNOSTIC_REDACT_COUNT; i++)); do
    printf '%s\0%s\0%s\0' \
      "${DIAGNOSTIC_REDACT_VALUES[$i]}" \
      "${DIAGNOSTIC_REDACT_LABELS[$i]}" \
      "${DIAGNOSTIC_REDACT_TOKEN_ONLY[$i]:-false}"
  done
}

redact_diagnostic_file() {
  local source="$1" target="$2"
  if ! command -v python3 >/dev/null 2>&1; then
    redact_diagnostic_file_with_shell_tools "$source" "$target"
    return
  fi
  write_diagnostic_redactions_nul | python3 -c '
import locale
import sys


ctype_codeset = locale.nl_langinfo(locale.CODESET).upper()
ascii_ctype = ctype_codeset in ("ANSI_X3.4-1968", "US-ASCII", "ASCII")


def is_token_character(character):
    if character in "_-":
        return True
    if ascii_ctype:
        return character.isascii() and character.isalnum()
    return character.isalnum()


def replace_token_only(line, token, replacement):
    result = []
    start = 0
    while True:
        index = line.find(token, start)
        if index < 0:
            result.append(line[start:])
            return "".join(result)
        left_safe = index == 0 or not is_token_character(line[index - 1])
        right_index = index + len(token)
        right_safe = right_index == len(line) or not is_token_character(line[right_index])
        if left_safe and right_safe:
            result.append(line[start:index])
            result.append(replacement)
            start = right_index
        else:
            result.append(line[start:index + 1])
            start = index + 1


fields = sys.stdin.buffer.read().split(b"\0")
if fields and fields[-1] == b"":
    fields.pop()
if len(fields) % 3:
    raise SystemExit("invalid diagnostic redaction table")
rules = []
for index in range(0, len(fields), 3):
    value, replacement, token_only = (
        field.decode("utf-8") for field in fields[index:index + 3]
    )
    rules.append((value, replacement, token_only == "true"))

with open(sys.argv[1], "r", encoding="utf-8", errors="surrogateescape", newline="") as source_file:
    source = source_file.read()
lines = [] if source == "" else source.split("\n")
if source.endswith("\n"):
    lines.pop()
for line in lines:
    for value, replacement, token_only in rules:
        if token_only:
            line = replace_token_only(line, value, replacement)
        else:
            line = line.replace(value, replacement)
    sys.stdout.buffer.write((line + "\n").encode("utf-8", errors="surrogateescape"))
' "$source" | redact_diagnostic_networks > "$target"
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
  local raw sanitized audit_file log_file report os_name kernel_version nfuse_version channel recorded_version kernel_bin_path kernel_cfg_path
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
  kernel_version="$(installed_kernel_version)"; kernel_version="${kernel_version:-未知}"
  nfuse_version="$(installed_nfuse_version)"; nfuse_version="${nfuse_version:-未知}"
  # 正式版／测试版通道是 sing-box 独有的概念，mihomo 没有对应物：那里只印版本号，
  # 不印一个必定「未知」的通道。此前这里写死了 sing-box 的取值入口，mihomo 机器上
  # 因此每次都印出「sing-box：未知（未知）」，而同一份报告上一行印的是「代理内核：mihomo」。
  # 通道的管理入口已随 sing-box 线归档撤除（公开 Issue #256），判据直接看版本号：
  # sing-box 的测试版版本号带 `-`（如 1.14.0-alpha.44）。报告里仍然印出来，是因为
  # 存量机器上确实可能装着一个测试版，排查时这一行有用。
  channel=""
  if [[ "$PROXY_KERNEL" == singbox && -x "$SINGBOX_BIN" ]]; then
    if [[ "$(installed_singbox_version)" == *-* ]]; then channel='（测试版）'; else channel='（正式版）'; fi
  fi
  recorded_version="$(sed -n 's/^SCRIPT_VERSION=//p' "$DEPLOYED_VERSIONS_FILE" 2>/dev/null | head -n1 || true)"
  [[ "$recorded_version" == "$SCRIPT_VERSION" ]] && recorded_version="一致（${SCRIPT_VERSION}）" || recorded_version="不一致（记录 ${recorded_version:-缺失}，当前 ${SCRIPT_VERSION}）"
  if [[ -f /root/sb-user-manager.sh ]]; then
    cmp -s /root/sb-user-manager.sh "$SELF_PATH" && launcher_result='一致' || launcher_result='内容不一致'
  else launcher_result='未发现可选的 root 启动副本'
  fi

  sing_state="$(diagnostic_service_state "$(kernel_service_name).service")"
  nfuse_state="$(diagnostic_service_state nfuse.service)"
  expiry_state="$(diagnostic_service_state sb-user-expiry.timer)"
  kernel_bin_path="$(kernel_binary_path)" || return 1
  kernel_cfg_path="$(kernel_config_path)" || return 1
  if [[ -x "$kernel_bin_path" && -r "$kernel_cfg_path" ]] && kernel_check_config "$kernel_cfg_path" >/dev/null 2>&1; then config_result='通过'
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
    printf '代理内核：%s\n' "$PROXY_KERNEL"
    printf '%s：%s%s\n' "$(kernel_display_name)" "$kernel_version" "$channel"
    printf 'Nfuse：%s\n' "$nfuse_version"
    printf '系统：%s\n' "${os_name:-未知}"
    printf '系统内核：%s｜架构：%s\n' "$(uname -r 2>/dev/null || echo 未知)" "$(uname -m 2>/dev/null || echo 未知)"
    echo
    echo '== 服务与基础检查 =='
    printf '连接服务（%s）：%s\n' "$(kernel_display_name)" "$sing_state"
    printf '流量统计（Nfuse）：%s\n' "$nfuse_state"
    printf '到期自动检查：%s\n' "$expiry_state"
    printf '管理配置：%s\n' "$([[ "$DIAGNOSTIC_CONFIG_READABLE" == true ]] && echo 可读取 || echo 缺失或不可读)"
    printf '%s 配置：%s\n' "$(kernel_display_name)" "$config_result"
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
    append_diagnostic_service_log "$(kernel_service_name).service" "连接服务（$(kernel_display_name)）" "$log_file"
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
      1) MENU_RETURNED=false; prompt_consistency; [[ "$MENU_RETURNED" == true ]] || pause_menu;;
      2) create_diagnostic_report; pause_menu;;
      3) echo; print_diagnostic_reports || true; pause_menu;;
      4) show_diagnostic_report; pause_menu;;
      5) delete_diagnostic_report; pause_menu;;
      6) cleanup_diagnostic_reports; pause_menu;;
      0) return 0;;
    esac
  done
}

# ============================================================
# 非交互只读入口
# ============================================================
# 只读查询走独立路径，绝不经过 prepare_core —— 后者会取写锁、执行事务回滚（真的会改数据）
# 并写状态文件。这里只读：不取锁、不恢复、不写任何项目文件。
#
# 不取锁是安全的：状态文件由 atomic_state_update 以临时文件加 rename 替换，无锁读到的
# 必然是某个完整版本。因此只读查询既不阻塞正在操作的会话，也不会被对方阻塞，不需要在
# 锁被占用时报错退出。
#
# 输出绝不包含密码、密钥、SNI、订阅链接或二维码：字段逐个显式构造，不复用任何导出函数。

# 提前提醒的阈值：距到期天数与配额占用比例。集中在此便于日后调整。
READONLY_EXPIRY_NOTICE_DAYS=7
READONLY_QUOTA_NOTICE_RATIO=0.9

readonly_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

readonly_fail() {
  printf '错误：%s\n' "$1" >&2
  exit 3
}

# 只做只读查询需要的最小准备：校验权限与依赖、加载运行配置。
# 期间任何内部 die 都会因 SB_READONLY_EXIT_CODE 归为退出码 3。
readonly_prepare() {
  local cmd readonly_kernel_bin
  # 单元测试会以普通用户加载隔离环境；真实运行必须是 root，否则读不到 600 权限的用户数据。
  # 与 runtime_config_expected_uid 采用同一判定方式。
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    [[ $EUID -eq 0 ]] || readonly_fail '需要 root 权限读取管理数据，请以 root 运行。'
  fi
  for cmd in jq systemctl date; do
    command -v "$cmd" >/dev/null 2>&1 || readonly_fail "缺少依赖命令：${cmd}"
  done
  [[ -r "$CONF_FILE" ]] ||
    readonly_fail '尚未部署管理环境，请先在交互菜单中执行「系统管理 → 部署与卸载 → 安装或修复环境」。'
  load_runtime_config
  [[ -r "$STATE_FILE" ]] || readonly_fail "读不到用户数据：${STATE_FILE}"
  readonly_kernel_bin="$(kernel_binary_path)" || readonly_fail '无法确认代理内核的可执行文件位置。'
  command -v "$readonly_kernel_bin" >/dev/null 2>&1 || [[ -x "$readonly_kernel_bin" ]] ||
    readonly_fail "读不到 $(kernel_display_name) 程序：${readonly_kernel_bin}"
  command -v nfuse >/dev/null 2>&1 || readonly_fail '读不到 nfuse 程序，无法查询流量。'
}

# 服务状态：输出 服务名<TAB>systemd 原始状态<TAB>中文说法。
# 人读输出用中文说法，--json 保留原始状态作为机器契约。
readonly_service_rows() {
  local service state
  for service in "$(kernel_service_name).service" nfuse.service sb-user-expiry.timer; do
    state="$(systemctl is-active "$service" 2>/dev/null || true)"
    # 空状态归一为 unknown：制表符分隔在中间字段为空时会被折叠，读取端会错位；
    # 同时也让 --json 里的 state 始终是个有意义的值而不是空串。
    [[ -n "$state" ]] || state=unknown
    printf '%s\t%s\t%s\n' "$service" "$state" "$(service_state_label "$state")"
  done
}

# 用户快照：把状态文件与 Nfuse 用量合成只含非敏感字段的 JSON 数组。
# 用量与剩余的算法与「查看用户」列表保持一致，否则同一台机器两处会给出不同数字。
readonly_users_json() {
  local usage_json name_filter="${1:-}"
  usage_json="$(nfuse list --json)" || readonly_fail '无法读取 Nfuse 流量数据。'
  jq -e 'type == "array"' <<<"$usage_json" >/dev/null || readonly_fail 'Nfuse 返回的流量数据无效。'
  jq --argjson nfuse "$usage_json" --arg only "$name_filter" '
    [.users[]
     | select($only == "" or .name == $only)
     | . as $user
     | (($user.metered // ($user.limit_gib != null))) as $metered
     | ($nfuse | map(select(.name == $user.name)) | first) as $meter
     | {
         name: $user.name,
         protocols: [
           if ($user.endpoints | type) == "array" then $user.endpoints[]
           else {protocol:($user.protocol // "ss2022"), transport:($user.transport // "shadowtls")} end
           | if .protocol == "anytls" then "anytls"
             elif .transport == "shadowtls" then "ss2022_shadowtls"
             else "ss2022" end
         ],
         enabled: ($user.status == "active"),
         status: (if $user.status == "disabled" then "disabled"
                  elif $metered and $meter != null and $meter.used_bytes >= $meter.limit_bytes then "quota_exhausted"
                  else $user.status end),
         metered: $metered,
         expires_at: $user.expires_at,
         quota_bytes: (if $metered and $meter != null then $meter.limit_bytes else null end),
         used_bytes: (if $meter == null then null else ($meter.used_bytes + ($user.usage_offset_bytes // 0)) end),
         remaining_bytes: (if ($metered | not) or $meter == null then null
                           else ([$meter.limit_bytes - $meter.used_bytes, 0] | max) end)
       }]
  ' "$STATE_FILE"
}

readonly_bytes_to_gib() {
  jq -rn --argjson v "$1" 'if $v == null then "-" else ((($v / 1073741824) * 100 | round) / 100 | tostring) + " GiB" end'
}

cmd_readonly_users() {
  local as_json=false name='' users rows
  # 只读子命令期间把「工具自身出错」统一为退出码 3。用局部变量而不是 export：
  # export 会让整个进程后续所有 die 都变成 3，污染调用方（单元测试里已经踩到过）。
  local SB_READONLY_EXIT_CODE=3
  while (($#)); do
    case "$1" in
      --json) as_json=true; shift;;
      --name) [[ -n "${2:-}" ]] || readonly_fail '--name 需要一个用户名。'; name="$2"; shift 2;;
      *) readonly_fail "无法识别的参数：$1（可用：--json、--name <用户>）";;
    esac
  done
  readonly_prepare
  users="$(readonly_users_json "$name")" || return 3
  if [[ -n "$name" ]] && [[ "$(jq 'length' <<<"$users")" == 0 ]]; then
    readonly_fail "找不到用户：${name}"
  fi
  if [[ "$as_json" == true ]]; then
    jq -n --argjson users "$users" --arg at "$(readonly_now)" '{generated_at:$at, users:$users}'
    return 0
  fi
  if [[ "$(jq 'length' <<<"$users")" == 0 ]]; then
    echo '暂无用户'
    return 0
  fi
  rows="$(jq -r '
    (["用户名","协议","状态","月配额","已用","剩余","到期时间"] | @tsv),
    (.[] | [
      .name,
      (.protocols | map(if . == "anytls" then "AnyTLS" elif . == "ss2022_shadowtls" then "SS2022+ShadowTLS" else "SS2022" end) | join(" + ")),
      (if .status == "disabled" then "停用" elif .status == "quota_exhausted" then "配额耗尽" else "启用" end),
      (if .quota_bytes == null then "不限" else (((.quota_bytes / 1073741824) * 100 | round) / 100 | tostring) + " GiB" end),
      (if .used_bytes == null then "-" else (((.used_bytes / 1073741824) * 100 | round) / 100 | tostring) + " GiB" end),
      (if .remaining_bytes == null then "-" else (((.remaining_bytes / 1073741824) * 100 | round) / 100 | tostring) + " GiB" end),
      (if .expires_at == null then "-" else (.expires_at | sub("T"; " ") | sub("[+-][0-9]{2}:?[0-9]{2}$"; "")) end)
    ] | @tsv)' <<<"$users")" || readonly_fail '用户数据无法格式化。'
  if ! printf '%s\n' "$rows" | column -t -s $'\t' 2>/dev/null; then
    printf '%s\n' "$rows"
  fi
}

cmd_readonly_status() {
  local as_json=false services users issues=0 repairable=0 audit_rc=0
  # 只读子命令期间把「工具自身出错」统一为退出码 3。用局部变量而不是 export：
  # export 会让整个进程后续所有 die 都变成 3，污染调用方（单元测试里已经踩到过）。
  local SB_READONLY_EXIT_CODE=3
  local problems='[]' notices='[]' conclusion=ok code=0
  while (($#)); do
    case "$1" in
      --json) as_json=true; shift;;
      *) readonly_fail "无法识别的参数：$1（可用：--json）";;
    esac
  done
  readonly_prepare
  services="$(readonly_service_rows)"
  while IFS=$'\t' read -r service state state_label; do
    [[ -n "$service" ]] || continue
    [[ "$state" != active ]] || continue
    problems="$(jq -c --arg m "服务未正常运行：${service}（${state_label}）" '. += [$m]' <<<"$problems")"
  done <<<"$services"
  # 用配置里的套接字路径，不写死 /run/nfuse.sock —— 只读入口既然读了配置就该尊重它
  local nfuse_socket="${NFUSE_SOCKET:-/run/nfuse.sock}"
  [[ -S "$nfuse_socket" ]] ||
    problems="$(jq -c --arg m "流量统计通信未就绪：${nfuse_socket} 不存在" '. += [$m]' <<<"$problems")"
  # 未完成的管理脚本接管：只读入口不执行恢复，但必须如实报出来，
  # 否则读到的数据可能来自一个处于中间状态的环境。
  if [[ -e "$MANAGER_HANDOFF_JOURNAL" || -L "$MANAGER_HANDOFF_JOURNAL" ]]; then
    notices="$(jq -c --arg m '存在未完成的管理脚本接管，请在交互菜单中运行一次以完成恢复' '. += [$m]' <<<"$notices")"
  fi
  if [[ -e "$TRANSACTION_JOURNAL" || -L "$TRANSACTION_JOURNAL" ]]; then
    notices="$(jq -c --arg m '存在未完成的操作恢复记录，请在交互菜单中运行一次以完成恢复' '. += [$m]' <<<"$notices")"
  fi
  # 复用「服务与配置检查」的判定逻辑本身，保证结论与菜单一致；报告正文丢弃，只取计数。
  # 必须在当前 shell 里跑，命令替换会因子壳丢掉计数变量。
  audit_consistency >/dev/null 2>&1 || audit_rc=$?
  if ((audit_rc != 0)); then
    problems="$(jq -c --arg m '配置一致性检查无法完成，请在交互菜单中查看「服务与配置检查」' '. += [$m]' <<<"$problems")"
  else
    issues="$AUDIT_ISSUES"
    repairable="$AUDIT_REPAIRABLE"
    if ((issues > repairable)); then
      # 先把算术算进变量再插值：把 $(( )) 嵌在 $( ) 内的双引号串里会让
      # tests/check-shell-call-targets.py 的分词器从此处起吞掉整个文件（静默不再检查）
      local manual_issues=$((issues - repairable))
      problems="$(jq -c --arg m "配置检查发现 ${issues} 项问题，其中 ${manual_issues} 项需要人工处理" '. += [$m]' <<<"$problems")"
    elif ((issues > 0)); then
      notices="$(jq -c --arg m "配置检查发现 ${issues} 项问题，均可在菜单中自动修复" '. += [$m]' <<<"$notices")"
    fi
  fi
  users="$(readonly_users_json)" || return 3
  # 提前提醒（一）7 天内到期。
  # 时间戳必须用 parse_expiry_epoch 解析：状态文件里的 expires_at 带 %z 偏移（如 +0800），
  # jq 的 fromdateiso8601 只认 Z 结尾，直接用它会整段报错、把提醒一起丢掉。
  # 格式无效时按 cmd_expire 的既有做法告警并跳过，不影响其余用户。
  local now_epoch expires expires_epoch days_left user_name
  now_epoch="$(date +%s)"
  while IFS=$'\t' read -r user_name expires; do
    [[ -n "$user_name" ]] || continue
    if ! expires_epoch="$(parse_expiry_epoch "$expires")"; then
      notices="$(jq -c --arg m "用户 ${user_name} 的有效期格式无效，无法判断是否临近到期：${expires}" '. += [$m]' <<<"$notices")"
      continue
    fi
    days_left=$(( (expires_epoch - now_epoch) / 86400 ))
    ((days_left <= READONLY_EXPIRY_NOTICE_DAYS)) || continue
    if ((days_left < 0)); then
      notices="$(jq -c --arg m "用户 ${user_name} 已过期，等待下次到期检查停用" '. += [$m]' <<<"$notices")"
    else
      notices="$(jq -c --arg m "用户 ${user_name} 将在 ${days_left} 天后到期" '. += [$m]' <<<"$notices")"
    fi
  done < <(jq -r '.[] | select(.status != "disabled") | select(.expires_at != null) | [.name, .expires_at] | @tsv' <<<"$users")
  # 提前提醒（二）计量用户已用超过配额的 90%。纯算术，留在 jq 里。
  while IFS= read -r message; do
    [[ -n "$message" ]] || continue
    notices="$(jq -c --arg m "$message" '. += [$m]' <<<"$notices")"
  done < <(jq -r --argjson ratio "$READONLY_QUOTA_NOTICE_RATIO" '
    .[] | select(.status != "disabled")
        | select(.quota_bytes != null and .used_bytes != null and .quota_bytes > 0)
        | select((.used_bytes / .quota_bytes) >= $ratio)
        | "用户 \(.name) 本月流量已用 \(((.used_bytes / .quota_bytes) * 100) | floor)%"
  ' <<<"$users")
  if [[ "$(jq 'length' <<<"$problems")" != 0 ]]; then
    conclusion=problem; code=2
  elif [[ "$(jq 'length' <<<"$notices")" != 0 ]]; then
    conclusion=notice; code=1
  fi
  if [[ "$as_json" == true ]]; then
    jq -n --arg at "$(readonly_now)" --arg conclusion "$conclusion" --argjson code "$code" \
      --arg kernel "$PROXY_KERNEL" \
      --argjson problems "$problems" --argjson notices "$notices" \
      --argjson issues "$issues" --argjson repairable "$repairable" \
      --argjson users "$users" --arg services "$services" '
      {generated_at:$at, conclusion:$conclusion, exit_code:$code,
       kernel:$kernel,
       services:($services | split("\n") | map(select(length > 0) | split("\t") | {name:.[0], state:.[1]})),
       consistency:{issues:$issues, repairable:$repairable},
       users:{total:($users|length),
              active:($users|map(select(.status != "disabled"))|length),
              disabled:($users|map(select(.status == "disabled"))|length)},
       problems:$problems, notices:$notices}'
    return "$code"
  fi
  case "$conclusion" in
    ok) echo '结论：正常';;
    notice) echo '结论：需要留意';;
    problem) echo '结论：异常';;
  esac
  printf '检查时间：%s\n' "$(readonly_now)"
  printf '代理内核：%s\n' "$PROXY_KERNEL"
  printf '服务：'
  printf '%s' "$(jq -rn --arg s "$services" '$s | split("\n") | map(select(length>0) | split("\t") |
    .[0] + " " + .[2]) | join(" / ")')"
  printf '\n用户：%s 个（启用 %s，停用 %s）\n' \
    "$(jq 'length' <<<"$users")" \
    "$(jq 'map(select(.status != "disabled")) | length' <<<"$users")" \
    "$(jq 'map(select(.status == "disabled")) | length' <<<"$users")"
  jq -r '.[] | "异常：" + .' <<<"$problems"
  jq -r '.[] | "留意：" + .' <<<"$notices"
  [[ "$conclusion" == ok ]] && echo '配置检查：未发现问题'
  return "$code"
}

# 只读子命令的统一入口。放在 main() 最前面调用，早于 root 检查与接管恢复，
# 因为 recover_manager_handoff 会取锁并还原文件，只读查询不得触发它。
run_readonly_command() {
  local command="$1"
  shift
  case "$command" in
    status) cmd_readonly_status "$@";;
    users) cmd_readonly_users "$@";;
    *) readonly_fail "未知的只读子命令：${command}";;
  esac
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
  # 「来源」两个内核不同：sing-box 是远程地址的格式（SRS / JSON），
  # mihomo 是本机文件名加它的写法。列名跟着变，不做成一个都说不清的通用词。
  if ! rows="$(jq -r --arg kernel "$PROXY_KERNEL" '
    . as $state |
    def source_label($p):
      if $kernel == "mihomo" then
        (if (($p.rule_geo // []) | length) > 0 then
           "geo 类别｜" + (($p.rule_geo // []) | join(" "))
         else
           ($p.rule_file // "?") + "｜" +
           (if ($p.rule_url // "") != "" then "网址" else "本机文件" end) + "｜" +
           (if $p.rule_behavior == "classical" then "完整规则行"
            elif $p.rule_behavior == "domain" then "域名列表"
            elif $p.rule_behavior == "ipcidr" then "IP 段列表"
            else "未知写法" end)
         end)
      else (if ($p.url | test("\\.srs([?#].*)?$")) then "SRS" else "JSON" end) end;
    if (.rule_presets | length) == 0 then "暂无预置规则"
    else (["名称","来源","关联分流","其中启用"] | @tsv),
      ($state.rule_presets | sort_by(.name)[] as $p |
        [ $p.name,
          source_label($p),
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
  jq -r --arg kernel "$PROXY_KERNEL" '
    def source_label($p):
      if $kernel == "mihomo" then
        (if (($p.rule_geo // []) | length) > 0 then
           "geo 类别｜" + (($p.rule_geo // []) | join(" "))
         else
           ($p.rule_file // "?") + "｜" +
           (if ($p.rule_url // "") != "" then "网址" else "本机文件" end) + "｜" +
           (if $p.rule_behavior == "classical" then "完整规则行"
            elif $p.rule_behavior == "domain" then "域名列表"
            elif $p.rule_behavior == "ipcidr" then "IP 段列表"
            else "未知写法" end)
         end)
      else (if ($p.url | test("\\.srs([?#].*)?$")) then "SRS" else "JSON" end) end;
    (["编号","名称","来源"] | @tsv),
    (to_entries[] | [(.key+1),.value.name,source_label(.value)] | @tsv)' <<<"$rows" | column -t -s $'\t'
  echo '0. 返回上一级'
  read_numbered_index '请选择预置规则：' "$count" || return 1
  SELECTED_RULE_PRESET="$(jq -r ".[${SELECTED_INDEX}].name" <<<"$rows")"
  # 用 --argjson 传下标而不是把它拼进过滤器：这里要写的是 (.url // "")，
  # 而在双引号里写 \" 会让 tests/check-shell-call-targets.py 的分词器当场放弃，
  # 文件剩下的部分从此不再受检（公开 Issue #102）。
  SELECTED_RULE_SOURCE="$(jq -r --argjson idx "$SELECTED_INDEX" '.[$idx] | (.url // .rule_file // "")' <<<"$rows")"
  SELECTED_RULE_BEHAVIOR="$(jq -r --argjson idx "$SELECTED_INDEX" '.[$idx] | (.rule_behavior // "")' <<<"$rows")"
  # 预置若是远程来源，选中它的分流要继承那个地址，否则分流会退化成「指向同名
  # 本机文件」——文件确实在（预置下载过），但从此不再自动更新。
  SELECTED_RULE_URL="$(jq -r --argjson idx "$SELECTED_INDEX" '.[$idx] | (.rule_url // "")' <<<"$rows")"
  SELECTED_RULE_GEO="$(jq -c --argjson idx "$SELECTED_INDEX" '.[$idx] | (.rule_geo // [])' <<<"$rows")"
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
  printf '说明：保存预置不会修改 %s，也不会影响现有分流。\n' "$(kernel_display_name)"
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
  if ((active > 0)); then printf '保存后会同步更新所有关联分流，并只重启一次 %s。\n' "$(kernel_display_name)"; else echo '保存后会同步更新关联记录；当前没有启用中的关联分流，不会重启服务。'; fi
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

# mihomo 部署下的规则来源：使用者自己放在规则目录里的一个块状 yaml 文件。
# 让人从目录里挑，而不是让人敲路径——路径敲错的后果是配置根本加载不了，
# 而这个目录的位置是 mihomo 唯一允许读规则文件的地方。
prompt_mihomo_rule_file() {
  local files count
  printf '\n规则文件请放在这个目录里：%s\n' "$MIHOMO_RULES_DIR"
  files="$(find "$MIHOMO_RULES_DIR" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | LC_ALL=C sort)" || files=''
  if [[ -z "$files" ]]; then
    echo '这个目录里还没有任何文件。'
    echo '请先把你的规则文件（从社区抄来的 yaml 片段）放进去，再回到这里添加。'
    return 1
  fi
  files="$(jq -Rsc 'split("\n") | map(select(length > 0))' <<<"$files")" || return 1
  count="$(jq 'length' <<<"$files")" || return 1
  echo
  jq -r 'to_entries[] | "  \(.key + 1). \(.value)"' <<<"$files"
  echo '  0. 返回上一级'
  read_numbered_index '请选择规则文件：' "$count" || return 1
  SELECTED_RULE_FILE="$(jq -r ".[${SELECTED_INDEX}]" <<<"$files")"
}

# 文件里写的是哪一种内容。这一项必须问：mihomo 在写法与声明不符时是**静默**的，
# 把完整规则行按域名列表读，一条警告都没有，规则就是静静地不生效
# （公开 Issue #186 实测）。选完之后管理器会读一遍文件核对。
prompt_mihomo_rule_behavior() {
  local choice
  echo
  echo '这个文件里写的是什么？'
  echo '  1. 完整规则行（从网上抄来的规则片段，例如 DOMAIN-SUFFIX,openai.com）'
  echo '  2. 只有域名（例如 +.openai.com）'
  echo '  3. 只有 IP 段（例如 192.168.1.0/24）'
  echo '  0. 返回上一级'
  read_menu_choice '请选择：' '0,1,2,3' '' '请输入 1、2、3 或 0' || return 1
  choice="$PROMPT_VALUE"
  case "$choice" in
    1) SELECTED_RULE_BEHAVIOR=classical ;;
    2) SELECTED_RULE_BEHAVIOR=domain ;;
    3) SELECTED_RULE_BEHAVIOR=ipcidr ;;
    0) return 1 ;;
  esac
}

# 规则从哪里来。三种来源并存（公开 Issue #218 加了网址，#219 加了 geo 类别）：
# **网址**——mihomo 自己下载规则集、每天自己更新，使用者什么都不用维护；
# **本机文件**——使用者自己往规则目录里放一份，适合手工维护的清单；
# **geo 类别**——不需要任何规则文件，直接写 GEOSITE,openai 这样的类别名。
prompt_mihomo_rule_kind() {
  SELECTED_RULE_KIND=''
  echo
  echo '规则从哪里来？'
  echo '  1. 网址（规则集自动下载，每天自动更新，推荐）'
  printf '  2. 本机文件（规则集自己放在 %s 下，自己维护）\n' "$MIHOMO_RULES_DIR"
  echo '  3. GeoSite／GeoIP 类别（例如 GEOSITE,openai，不需要规则文件）'
  echo '  0. 返回上一级'
  read_menu_choice '请选择：' '0,1,2,3' 1 '请输入 1、2、3 或 0' || return 1
  case "$PROMPT_VALUE" in
    1) SELECTED_RULE_KIND=remote ;;
    2) SELECTED_RULE_KIND=local ;;
    3) SELECTED_RULE_KIND=geo ;;
    0) return 1 ;;
  esac
}

# geo 类别的输入（公开 Issue #219）。一条分流可以填多个类别，命中任意一个就算。
# 类别名不在这里判对错——那要看 mihomo 自己的数据库，由保存时那次 `mihomo -t`
# 当场认。这里只挡住会把规则拼坏的写法，并把前缀统一成大写。
prompt_mihomo_geo_categories() {
  local entry kind value categories='[]' count
  SELECTED_RULE_GEO='[]'
  echo
  echo 'GeoSite 按域名分类（GEOSITE,openai），GeoIP 按 IP 归属的国家或地区（GEOIP,us）。'
  echo '类别名末尾的 !cn 表示「排除中国大陆」，例如 GEOSITE,category-ai-!cn；这类往往比'
  echo '单个服务的类别覆盖得全（category-ai-!cn 有 180 条，openai 只有 23 条）。'
  echo '可以填多个，命中其中任意一个就走这条分流。一行填一个，填完直接回车结束。'
  echo '类别名要与数据库里的一致；保存时会用 mihomo 当场校验，写错会指名道姓地告诉你。'
  while true; do
    count="$(jq 'length' <<<"$categories")"
    read -r -p "第 $((count + 1)) 个类别（直接回车结束，输入 0 返回）：" entry || return 1
    [[ "$entry" != 0 ]] || return 1
    if [[ -z "$entry" ]]; then
      ((count > 0)) || { echo '至少要填一个类别。'; continue; }
      break
    fi
    # 只填类别名时按 GeoSite 算：那是绝大多数场景，也是唯一不会引起歧义的默认。
    if [[ "$entry" == *,* ]]; then
      kind="$(printf '%s' "${entry%%,*}" | tr '[:lower:]' '[:upper:]')"
      value="${entry#*,}"
    else
      kind=GEOSITE
      value="$entry"
    fi
    entry="${kind},${value}"
    if ! validate_without_exit validate_geo_category "$entry"; then
      printf '输入无效：%s\n' "$VALIDATION_ERROR"
      continue
    fi
    if jq -e --arg item "$entry" 'index($item) != null' <<<"$categories" >/dev/null; then
      echo '这个类别已经填过了，换一个。'
      continue
    fi
    categories="$(jq -c --arg item "$entry" '. + [$item]' <<<"$categories")" || return 1
    printf '已加入：%s\n' "$entry"
  done
  SELECTED_RULE_GEO="$categories"
  printf '共 %s 个类别：%s\n' "$(jq 'length' <<<"$categories")" "$(jq -r 'join("  ")' <<<"$categories")"
  echo '保存时会用 mihomo 校验这些类别名；这台机器上第一次用到 geo 规则时'
  echo '还会自动下载数据库（GeoSite 约 4 MB，用到 GeoIP 再加约 17 MB），可能要等一会。'
}

# 远程规则集的地址。只接受 yaml，且**文件名原样保留**——保存下来的本机文件就叫
# 地址里那个名字，方便使用者自己认出它是哪来的（项目所有者的要求）。
prompt_mihomo_remote_rule_url() {
  local url name
  SELECTED_RULE_URL=''
  echo
  echo '规则集的网址要满足三条：HTTPS、指向 .yaml 或 .yml、内容是 mihomo 的规则清单。'
  echo '保存下来的文件会沿用网址里的文件名，放进规则目录，之后由 mihomo 每天自动更新。'
  while true; do
    read -r -p '规则集网址（输入 0 返回）：' url || return 1
    [[ "$url" != 0 ]] || return 1
    [[ "$url" == https://* ]] || { echo '输入无效：必须使用 HTTPS，请重新输入。'; continue; }
    [[ "$url" =~ \.(yaml|yml)$ ]] || { echo '输入无效：地址要指向 .yaml 或 .yml 文件，请重新输入。'; continue; }
    name="$(remote_rule_set_file_name "$url")"
    if ! validate_without_exit validate_mihomo_rule_file_name "$name"; then
      printf '输入无效：%s，请换一个地址。\n' "$VALIDATION_ERROR"
      continue
    fi
    break
  done
  SELECTED_RULE_URL="$url"
  printf '保存后的规则文件：%s\n' "$(mihomo_rule_file_path "$name")"
}

# 规则来源的输入。sing-box 要一个公网 HTTPS 地址，mihomo 要本机的一个文件
# 加上它的写法——两个内核的规则集格式不通用，界面上也就没有共同的问法。
# 第一个参数是当前取值：修改时留空表示保持不变，新增时不传。
prompt_split_rule_source() {
  local current="${1:-}" source answer
  SELECTED_RULE_SOURCE=''
  SELECTED_RULE_BEHAVIOR=''
  SELECTED_RULE_URL=''
  SELECTED_RULE_GEO='[]'
  case "$PROXY_KERNEL" in
    singbox)
      while true; do
        # 读失败即输入结束（管道读到头或使用者按了 Ctrl-D），与「输入 0」同样当作取消。
        # 不这样写的话，输入一结束这个循环就会永远打印同一条错误提示。
        if [[ -n "$current" ]]; then
          read -r -p "规则集下载地址（当前 ${current}；留空保持；输入 0 返回）：" answer || return 1
          source="${answer:-$current}"
        else
          read -r -p '规则集下载地址（HTTPS，.srs 或 .json；输入 0 返回）：' source || return 1
        fi
        [[ "$source" != 0 ]] || return 1
        [[ "$source" == https://* ]] || { echo '输入无效：必须使用 HTTPS，请重新输入。'; continue; }
        split_rule_format "$source" >/dev/null || { echo '输入无效：地址必须指向 .srs 或 .json 文件，请重新输入。'; continue; }
        break
      done
      SELECTED_RULE_SOURCE="$source"
      ;;
    mihomo)
      prompt_mihomo_rule_kind || return 1
      case "$SELECTED_RULE_KIND" in
        remote)
          prompt_mihomo_remote_rule_url || return 1
          prompt_mihomo_rule_behavior || return 1
          SELECTED_RULE_SOURCE="$(remote_rule_set_file_name "${SELECTED_RULE_URL:-}")"
          ;;
        geo)
          # geo 来源没有规则文件，也没有写法可选：类别本身就是匹配条件。
          prompt_mihomo_geo_categories || return 1
          ;;
        *)
          prompt_mihomo_rule_file || return 1
          prompt_mihomo_rule_behavior || return 1
          SELECTED_RULE_SOURCE="$SELECTED_RULE_FILE"
          ;;
      esac
      ;;
    *) kernel_unknown; return 1 ;;
  esac
}

prompt_add_rule_preset() {
  local answer
  prepare_core
  prompt_preset_name '预置规则名称' rule || { MENU_RETURNED=true; return 0; }
  prompt_split_rule_source || { MENU_RETURNED=true; return 0; }
  printf '说明：保存预置不会修改 %s，也不会影响现有分流。\n' "$(kernel_display_name)"
  read -r -p '确认检查并保存？[y/N]：' answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo '已取消保存。'; return 0; }
  cmd_rule_preset_add "$PRESET_NAME" "$SELECTED_RULE_SOURCE" "$SELECTED_RULE_BEHAVIOR" "${SELECTED_RULE_URL:-}" "${SELECTED_RULE_GEO:-[]}"
}

prompt_edit_rule_preset() {
  local name source behavior total active answer rule_url rule_geo
  prepare_core
  prompt_select_rule_preset '修改预置规则' || { MENU_RETURNED=true; return 0; }
  name="$SELECTED_RULE_PRESET"; source="$SELECTED_RULE_SOURCE"; behavior="$SELECTED_RULE_BEHAVIOR"
  rule_url="${SELECTED_RULE_URL:-}"; rule_geo="${SELECTED_RULE_GEO:-[]}"
  total="$(jq --arg name "$name" '[.splits[] | select((.rule_preset // "") == $name)] | length' "$STATE_FILE")"
  active="$(jq --arg name "$name" '[.splits[] | select((.rule_preset // "") == $name and .status == "active")] | length' "$STATE_FILE")"
  printf '\n关联分流：%s 条，其中启用 %s 条。\n' "$total" "$active"
  printf '当前来源：%s\n' "$(split_rule_source_display "$source" "$behavior")"
  prompt_split_rule_source "$source" || { MENU_RETURNED=true; return 0; }
  if ((active > 0)); then printf '保存后会同步更新所有关联分流，并只重启一次 %s。\n' "$(kernel_display_name)"; else echo '保存后会同步更新关联记录；当前没有启用中的关联分流，不会重启服务。'; fi
  read -r -p '确认检查并保存？[y/N]：' answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo '已取消修改。'; return 0; }
  cmd_rule_preset_edit "$name" "$SELECTED_RULE_SOURCE" "$SELECTED_RULE_BEHAVIOR" "${SELECTED_RULE_URL:-}" "${SELECTED_RULE_GEO:-[]}"
}

# 「立即更新规则集」（公开 Issue #218）。mihomo 自己每天更新一次；这里是给
# 「现在就要用上新规则」准备的。要断几秒必须在动手之前说清楚——新内容只有
# 重启内核才会立刻被读到，不重启就要等下一个更新周期，可能是一天以后。
prompt_remote_rule_sets_update() {
  local count answer
  prepare_core
  count="$(jq '[(.splits[]?, .rule_presets[]?) | select((.rule_url // "") != "")] | length' "$STATE_FILE")" || return 1
  if ((count == 0)); then
    echo
    echo '当前没有使用网址来源的规则集。只有来源是网址的规则集才需要更新；'
    echo '本机文件由你自己维护，管理器不会去改它。'
    return 0
  fi
  echo
  printf '将重新下载 %s 条网址来源的规则集，逐条校验之后写入本机。\n' "$count"
  echo '取不到或者内容不对的那几条会保留现在的内容，不会变成空规则。'
  printf '内容确实有变化时会重启 %s 让新规则立刻生效，现有连接中断几秒；\n' "$(kernel_display_name)"
  echo '内容没有变化就不重启，连接不受影响。'
  read -r -p '确认现在更新？[y/N]：' answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo '已取消更新。'; return 0; }
  cmd_remote_rule_sets_update || return 0
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
  local name source behavior rule_preset scope_choice scope user="" outbound_preset outbound_tag upstream answer rule_url rule_geo
  prepare_core
  if ! jq -e '(.rule_presets | length) > 0' "$STATE_FILE" >/dev/null; then echo '尚未添加预置规则，请先到“预置规则管理”中添加。'; return 0; fi
  if ! jq -e '(.outbound_presets | length) > 0' "$STATE_FILE" >/dev/null; then echo '尚未添加预置出口，请先到“预置出口管理”中添加。'; return 0; fi
  echo '输入 0 可返回分流管理。'
  while true; do
    read -r -p '分流名称：' name
    [[ "$name" != 0 ]] || { MENU_RETURNED=true; return 0; }
    if ! validate_without_exit validate_split_name "$name"; then printf '输入无效：%s，请重新输入。\n' "$VALIDATION_ERROR"; continue; fi
    split_exists "$name" && { echo '分流名称已存在，请重新输入。'; continue; }
    runtime_config_has_rule_set "$name" && { echo '这个名称已被其他规则使用，请换一个名称。'; continue; }
    break
  done
  prompt_select_rule_preset '选择要使用的预置规则' || { MENU_RETURNED=true; return 0; }
  rule_preset="$SELECTED_RULE_PRESET"; source="$SELECTED_RULE_SOURCE"; behavior="$SELECTED_RULE_BEHAVIOR"
  rule_url="${SELECTED_RULE_URL:-}"; rule_geo="${SELECTED_RULE_GEO:-[]}"
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
  if ! cmd_split_add "$name" "$source" "$scope" "$user" "$upstream" "$outbound_tag" "$rule_preset" "$outbound_preset" "$behavior" "$rule_url" "$rule_geo"; then
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
    ([.value.endpoints[] |
      if .protocol == "anytls" then "AnyTLS"
      elif .transport == "direct" then "原生 SS2022"
      else "SS2022 + ShadowTLS（旧版）" end] | join(" + ")) +
    "｜端口 " + ([.value.endpoints[].port | tostring] | join(" / "))' <<<"$rows_json"
  echo "  0. 返回分流管理"
  if ! read_numbered_index '请选择用户编号：' "$count"; then MENU_RETURNED=true; return 1; fi
  SELECTED_DIAGNOSTIC_USER="$(jq -r ".[$SELECTED_INDEX].name" <<<"$rows_json")"
}

extract_split_diagnostic_connections() {
  local user="$1" expected_outbound="$2" log_file="$3"
  awk -v anytls="anytls-$user" -v st="st-$user" -v ss="ss-$user" -v ss_direct="ss-direct-$user" \
      -v ss_udp="ss-udp-$user" -v expected="$expected_outbound" '
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
      (index(line, "[" anytls "]") || index(line, "[" st "]") || index(line, "[" ss "]") ||
       index(line, "[" ss_direct "]") || index(line, "[" ss_udp "]")) &&
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
  local split split_name scope user expected_outbound expected_outbound_display answer cursor_line cursor log_file log_level status kernel_service
  prepare_core
  # 这一项按 sing-box 的连接日志写成：它把入站标签与出站标签配成一对，
  # 因此能回答「这个用户的这条分流有没有走对出口」。
  # mihomo 的连接日志给出目的地址与所选出口，但**不带入站名**
  # （实测行形如 `[TCP] 源 --> 目的 match SubRules(...) using 出口`），
  # 按用户归因这一半拿不到，整套呈现要重做。
  # 单独立项：公开 Issue #187，不在第二步 2d 内。
  case "$PROXY_KERNEL" in
    singbox) ;;
    mihomo)
      echo
      printf '「验证分流是否生效」暂不支持 %s 部署：它依赖连接日志里的入口标签，而 %s 的日志不记这一项。\n' \
        "$(kernel_display_name)" "$(kernel_display_name)"
      echo '分流的增加、修改、停用、启用与删除都不受影响。'
      return 0
      ;;
    *) kernel_unknown; return 0 ;;
  esac
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
  kernel_service="$(kernel_service_name)" || return 1
  cursor_line="$(journalctl -u "$kernel_service" -n 0 --show-cursor --no-pager 2>/dev/null | tail -n1)"
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
  if ! journalctl -u "$kernel_service" --after-cursor="$cursor" --no-pager -o cat > "$log_file" 2>/dev/null; then
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
  local name split source behavior scope user upstream out_tag choice answer current_scope current_out rule_preset outbound_preset current_source rule_url rule_geo
  prepare_core
  prompt_select_split all "编辑分流" || return 0
  name="$SELECTED_SPLIT_NAME"
  split="$(jq -c --arg name "$name" '.splits[] | select(.name == $name)' "$STATE_FILE")"
  jq -e '.upstream.protocol' <<<"$split" >/dev/null || die "这条旧版分流缺少出口服务器信息，请删除后重新添加"
  source="$(split_rule_source_from_json "$split")"
  behavior="$(split_rule_behavior_from_json "$split")"
  # 「保持不变」那一支必须把来源的**全部**字段带上，不只是文件名与写法。
  # 少带 rule_url 的后果是：编辑一条网址来源的分流时只要不换预置规则，
  # 它就会被静静地改成「指向同名本机文件」，从此不再自动更新。
  rule_url="$(split_rule_url_from_json "$split")"
  rule_geo="$(split_rule_geo_from_json "$split")"
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
    2) prompt_select_rule_preset '选择新的预置规则' || { MENU_RETURNED=true; return 0; }; rule_preset="$SELECTED_RULE_PRESET"; source="$SELECTED_RULE_SOURCE"; behavior="$SELECTED_RULE_BEHAVIOR"; rule_url="${SELECTED_RULE_URL:-}"; rule_geo="${SELECTED_RULE_GEO:-[]}";;
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
  if ! cmd_split_edit "$name" "$source" "$scope" "$user" "$upstream" "$out_tag" "$rule_preset" "$outbound_preset" "$behavior" "$rule_url" "$rule_geo"; then
    echo '分流修改没有保存，原有配置继续使用。'
    return 0
  fi
}

prompt_move_split() {
  local name count current position answer group group_size others
  prepare_core
  prompt_select_split all "调整分流顺序" || return 0
  name="$SELECTED_SPLIT_NAME"
  count="$(jq '.splits | length' "$STATE_FILE")"
  current="$(jq -r --arg name "$name" '.splits | to_entries[] | select(.value.name == $name) | (.key + 1)' "$STATE_FILE")"
  printf '\n当前顺序：第 %s 条；可选 1-%s（越靠前越优先使用）。\n' "$current" "$count"
  # 共用同一套预置的分流在运行配置里合并成一条，只移动其中一条不会改变匹配顺序，
  # 必须在用户作出选择之前说清楚这次会连带移动哪些分流
  group="$(split_merge_group_names "$name")" || return 1
  group_size="$(jq 'length' <<<"$group")" || return 1
  if ((group_size > 1)); then
    others="$(jq -r --arg name "$name" '[.[] | select(. != $name)] | join("、")' <<<"$group")" || return 1
    printf '注意：本分流与 %s 共用同一套预置，运行时合并为一条，将一并移动到新位置。\n' "$others"
  fi
  while true; do
    read -r -p '移动到第几条（留空保持，输入 0 返回）：' position
    [[ -n "$position" ]] || { echo "顺序未变化。"; return 0; }
    [[ "$position" != 0 ]] || { MENU_RETURNED=true; return 0; }
    if [[ "$position" =~ ^[0-9]+$ ]]; then position=$((10#$position)); fi
    if [[ "$position" =~ ^[0-9]+$ ]] && ((position >= 1 && position <= count)); then break; fi
    printf '输入无效：请输入 1 到 %s 之间的数字。\n' "$count"
  done
  if ((group_size > 1)); then
    read -r -p "确认将 $name 及与其合并的 $((group_size - 1)) 条分流一并移动到第 $position 条？[y/N]：" answer
  else
    read -r -p "确认将 $name 移动到第 $position 条？[y/N]：" answer
  fi
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
    # 「立即更新规则集」只在 mihomo 上出现：sing-box 的规则集由 sing-box 自己
    # 按配置里的地址下载，管理器没有可更新的本机缓存（公开 Issue #218）。
    [[ "$PROXY_KERNEL" != mihomo ]] || ui_menu_items update_rules '立即更新规则集'
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
      update_rules) MENU_RETURNED=false; prompt_remote_rule_sets_update; [[ "$MENU_RETURNED" == true ]] || pause_menu;;
      back) return 0;;
    esac
  done
}
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
  # 一次性修回被旧版本改坏的系统目录权限（公开 Issue #246、#252）。
  # **必须挂在这里，不能只挂在部署与修复上。** 「检测更新」那一次的部署是由
  # **旧脚本**执行的——新脚本刚下载下来还没跑，跑 deploy_environment 的仍是当前
  # 进程里那份把 /var/lib 与 /usr/local/sbin 改成 700 的旧代码。真机实测的顺序是
  # 755 →（升级）→ 700，修复要等到下一次走部署或修复才生效，于是一台从旧版升上来
  # 的机器升完仍然是 700，还得再点一次「安装或修复环境」。挂进启动编排之后，
  # 升级完成 exec 进新脚本、或者下一次运行脚本时就自动修回。
  # 函数幂等且只认 700 这个指纹，管理员自己设成别的值不会被覆盖。
  #
  # **先确认这是一台本脚本部署过的机器。** 缺陷只可能出现在跑过本脚本的机器上，
  # 而这里是「运行脚本就会走到」的位置——不设门槛的话，一个人只是下载下来打开
  # 菜单看看，脚本就动了他系统目录的权限。全新 Debian 12 上这两个目录本来就是
  # 755（实测），因此不设门槛也基本不会触发；真正被误伤的是那种自己把 /var/lib
  # 收紧到 700 的机器，那是别人的决定，不该由我们改回去。
  # 判据用管理配置在不在，不用 environment_is_deployed：后者要看当前内核的核心
  # 文件，而这一刻 PROXY_KERNEL 还是文件级默认值 sing-box，一台 mihomo 机器会被
  # 判成没部署（同 #251 那个坑）。
  [[ ! -f "$CONF_FILE" ]] || repair_system_directory_modes
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
    printf '这两个地址现在还用不上：没有 geo 分流时 %s 里不会有 GeoSite.dat 或 GeoIP.dat。\n' \
      "$MIHOMO_WORK_DIR"
    echo '添加第一条 geo 分流时才会按这里的设置去下载。'
  else
    printf '数据库放在 %s，由 mihomo 每 %s 小时自己检查更新。\n' \
      "$MIHOMO_WORK_DIR" "$GEO_UPDATE_INTERVAL_HOURS"
  fi
  # 工作目录里还会有一个 ASN.mmdb，它与这两个地址无关：实测确认，只要配置里有
  # 任何一条规则集条目（本机文件或网址都一样），mihomo 启动时就会自己去下它。
  # 这不是本项目加进来的行为，在这里说一句是为了让人看到那个文件时不必猜。
  if [[ -f "$MIHOMO_WORK_DIR/ASN.mmdb" ]]; then
    echo
    echo '工作目录里的 ASN.mmdb 由 mihomo 自己下载与维护，与这里的设置无关；'
    echo '只要有规则集分流它就会存在，删掉也会被重新下载。'
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
    ui_menu_items \
      deploy '部署与卸载' update '检测更新' \
      status '查看服务状态' diagnostics '检查与故障报告' \
      backup '数据备份与恢复' sni '默认连接域名（SNI）'
    # 「geo 数据源」只在 mihomo 上出现：sing-box 部署里没有 GeoSite／GeoIP
    # 这回事，留一个永远点不动的菜单项比少一项更让人困惑（公开 Issue #219）。
    [[ "$PROXY_KERNEL" != mihomo ]] || ui_menu_items geo 'geo 数据源'
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
      back) return 0;;
    esac
  done
}

deployment_management_menu() {
  while true; do
    prepare_menu_screen
    ui_menu_begin
    ui_header '部署与卸载' '安装、修复或移除运行环境'
    ui_menu_items install '安装或修复环境'
    # 一次性入口，跑完即撤（公开 Issue #276）。
    ui_menu_items migrate '搬迁管理器数据目录'
    printf '\n'
    ui_section '危险操作'
    printf '%s' "$UI_RED"
    ui_menu_items uninstall '完整卸载'
    printf '%s' "$UI_RESET"
    ui_back_item '返回上一级'
    ui_menu_select || return 0
    case "$UI_MENU_ACTION" in
      install) install_environment; pause_menu;;
      migrate) migrate_manager_data_directory; pause_menu;;
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
