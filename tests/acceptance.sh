#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

MODE="${1:-audit}"
MANAGER="${SB_ACCEPTANCE_MANAGER:-/usr/local/sbin/sb-user-manager}"
REPORT_DIR="${SB_ACCEPTANCE_REPORT_DIR:-/root/sb-user-manager-backups/reports}"
VERSIONS_FILE="${SB_ACCEPTANCE_VERSIONS_FILE:-/var/lib/sb-user-manager/versions}"
LAUNCHER_PATH="${SB_ACCEPTANCE_LAUNCHER_PATH:-/root/sb-user-manager.sh}"
CONFIRM="${SB_ACCEPTANCE_CONFIRM:-}"
RULESET_URL="${SB_ACCEPTANCE_RULESET_URL:-}"
TEST_MODE="${SB_ACCEPTANCE_TEST_MODE:-false}"
RELEASE_ASSET="${SB_ACCEPTANCE_RELEASE_ASSET:-}"
ENVIRONMENT_BACKUP_BASE="${SB_ACCEPTANCE_ENVIRONMENT_BACKUP_BASE:-/root/sb-user-manager-backups}"
STARTED_AT="$(date -Iseconds)"
RUN_ID="$(date '+%Y%m%d-%H%M%S')-$$"
WORK=""
RESULTS=""
REPORT=""
FAILURES=0
LIVE_STARTED=false
LIVE_CLEANED=false
SNAPSHOT=""
SS_USER=""
ANYTLS_USER=""
SPLIT_NAME=""
MERGE_TARGET_USER=""
BASELINE_USERS=""
BASELINE_SPLITS=""
CURRENT_MUTATION_LABEL=""

cleanup_acceptance_work() {
  [[ -n "${WORK:-}" ]] || return 0
  case "$WORK" in
    /tmp/sb-acceptance.*) rm -rf -- "$WORK" ;;
  esac
}

init_acceptance_work() {
  WORK="$(mktemp -d /tmp/sb-acceptance.XXXXXX)" || return 1
  RESULTS="$WORK/results.jsonl"
}

if [[ "${SB_ACCEPTANCE_LIBRARY:-false}" != true ]]; then
  trap cleanup_acceptance_work EXIT
fi

usage() {
  cat <<'EOF'
用法：
  sudo bash tests/acceptance.sh audit
  sudo bash tests/acceptance.sh release
  sudo SB_ACCEPTANCE_CONFIRM=YES bash tests/acceptance.sh lifecycle
  sudo SB_ACCEPTANCE_CONFIRM=YES bash tests/acceptance.sh full

模式：
  audit       只读检查版本、服务、配置、Nfuse、定时器和一致性（默认）
  release     在 audit 基础上核对正式 Release、已安装脚本和最新环境快照
  lifecycle   创建临时用户并验证完整生命周期，完成后自动清理
  full        仅限空白专用测试机；额外验证单文件迁移备份与恢复

可选环境变量：
  SB_ACCEPTANCE_MANAGER       待测脚本路径
  SB_ACCEPTANCE_REPORT_DIR    脱敏 JSON 报告目录
  SB_ACCEPTANCE_VERSIONS_FILE 版本记录路径
  SB_ACCEPTANCE_LAUNCHER_PATH root 启动副本路径
  SB_ACCEPTANCE_RELEASE_ASSET 覆盖待核对的 Release 脚本附件名
  SB_ACCEPTANCE_ENVIRONMENT_BACKUP_BASE 覆盖完整环境快照目录
  SB_ACCEPTANCE_SNI           测试 SNI，默认 www.microsoft.com
  SB_ACCEPTANCE_RULESET_URL   HTTPS .srs/.json；设置后验证分流生命周期
EOF
}

record_result() {
  local status="$1" check="$2" detail="${3:-}"
  jq -cn --arg status "$status" --arg check "$check" --arg detail "$detail" \
    '{status:$status,check:$check,detail:$detail}' >> "$RESULTS"
  printf '  [%s] %s%s\n' "$status" "$check" "$([[ -n "$detail" ]] && printf '：%s' "$detail")"
  if [[ "$status" == FAIL ]]; then FAILURES=$((FAILURES + 1)); fi
}

pass() { record_result PASS "$1" "${2:-}"; }
fail() { record_result FAIL "$1" "${2:-}"; }
skip() { record_result SKIP "$1" "${2:-}"; }

file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
file_uid() { stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1" 2>/dev/null; }

write_report() {
  local completed_at result users=0 splits=0
  completed_at="$(date -Iseconds)"
  if ((FAILURES == 0)); then result=success; else result=failed; fi
  if [[ -n "${STATE_FILE:-}" && -r "${STATE_FILE:-}" ]]; then
    users="$(jq '.users | length' "$STATE_FILE" 2>/dev/null || printf 0)"
    splits="$(jq '.splits | length' "$STATE_FILE" 2>/dev/null || printf 0)"
  fi
  install -d -m 700 "$REPORT_DIR"
  REPORT="$REPORT_DIR/acceptance-${MODE}-${RUN_ID}.json"
  jq -n \
    --arg started_at "$STARTED_AT" \
    --arg completed_at "$completed_at" \
    --arg mode "$MODE" \
    --arg result "$result" \
    --arg hostname '[redacted]' \
    --arg manager_version "${SCRIPT_VERSION:-unknown}" \
    --argjson failures "$FAILURES" \
    --argjson users "$users" \
    --argjson splits "$splits" \
    --slurpfile checks "$RESULTS" \
    '{format_version:1,started_at:$started_at,completed_at:$completed_at,mode:$mode,
      result:$result,hostname:$hostname,manager_version:$manager_version,
      failures:$failures,final_counts:{users:$users,splits:$splits},checks:$checks}' > "$REPORT"
  chmod 600 "$REPORT"
  printf '\n验收结果：%s；失败项：%d\n报告：%s\n' "$result" "$FAILURES" "$REPORT"
}

source_manager() {
  [[ -f "$MANAGER" ]] || { printf '验收失败：脚本不存在：%s\n' "$MANAGER" >&2; return 1; }
  bash -n "$MANAGER" || return 1
  export SB_USER_MANAGER_LIBRARY=true
  # shellcheck source=/usr/local/sbin/sb-user-manager
  source "$MANAGER"
  set +e
}

run_audit() {
  local installed_version recorded_version audit_output audit_rc launcher conf_mode conf_uid expected_uid runtime_journal environment_journal
  printf '\n只读环境验收\n\n'
  if bash -n "$MANAGER"; then pass '管理脚本语法'; else fail '管理脚本语法'; fi
  installed_version="$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)"/\1/p' "$MANAGER" | head -n1)"
  if [[ "$installed_version" == "$SCRIPT_VERSION" ]]; then pass '脚本版本解析' "$SCRIPT_VERSION"; else fail '脚本版本解析' "${installed_version:-unknown}"; fi

  if [[ -r "$VERSIONS_FILE" ]]; then
    recorded_version="$(sed -n 's/^SCRIPT_VERSION=//p' "$VERSIONS_FILE" | head -n1)"
    if [[ "$recorded_version" == "$SCRIPT_VERSION" ]]; then pass '版本记录一致' "$recorded_version"; else fail '版本记录一致' "记录 ${recorded_version:-unknown}，脚本 $SCRIPT_VERSION"; fi
  else
    fail '版本记录一致' '版本记录不可读'
  fi

  launcher="$LAUNCHER_PATH"
  if [[ -f "$launcher" ]]; then
    if cmp -s "$launcher" "$MANAGER"; then pass 'root 启动副本一致'; else fail 'root 启动副本一致' '内容与安装路径不同'; fi
  else
    skip 'root 启动副本一致' '未发现该可选副本'
  fi

  if [[ ! -r "$CONF_FILE" ]]; then fail '管理配置读取' "$CONF_FILE 不可读"; return 1; fi
  load_runtime_config
  conf_mode="$(file_mode "$CONF_FILE" || printf unknown)"
  conf_uid="$(file_uid "$CONF_FILE" || printf '%s' -1)"
  expected_uid=0
  [[ "$TEST_MODE" != true ]] || expected_uid="$(id -u)"
  if [[ "$conf_uid" == "$expected_uid" && "$conf_mode" =~ ^[0-7]00$ ]]; then pass '管理配置权限' "$conf_mode"; else fail '管理配置权限' "$conf_mode"; fi
  for service in sing-box.service nfuse.service sb-user-expiry.timer; do
    if systemctl is-active --quiet "$service"; then pass "服务 $service" 'active'; else fail "服务 $service" "$(systemctl is-active "$service" 2>/dev/null || printf unknown)"; fi
  done
  if systemctl is-enabled --quiet sb-user-expiry.timer; then pass '到期定时器开机启用'; else fail '到期定时器开机启用'; fi
  if "$SINGBOX_BIN" check -c "$SINGBOX_CONFIG"; then pass 'sing-box 配置校验'; else fail 'sing-box 配置校验'; fi
  if [[ -S "$NFUSE_SOCKET" || ( "$TEST_MODE" == true && -e "$NFUSE_SOCKET" ) ]]; then pass 'Nfuse Socket'; else fail 'Nfuse Socket' "$NFUSE_SOCKET 不存在"; fi
  if nfuse list --json | jq -e 'type == "array"' >/dev/null; then pass 'Nfuse 数据读取'; else fail 'Nfuse 数据读取'; fi
  runtime_journal="${TRANSACTION_JOURNAL:-/var/lib/sb-user-manager/transactions/active.json}"
  environment_journal="${ENVIRONMENT_TRANSACTION_JOURNAL:-/var/lib/sb-user-manager.recovery.json}"
  if [[ ! -e "$runtime_journal" && ! -e "$environment_journal" ]]; then
    pass '持久化事务状态' '无未完成事务'
  else
    fail '持久化事务状态' '存在未完成事务日志'
  fi

  if [[ ! -r "$STATE_FILE" ]] || ! jq -e --argjson schema "$STATE_SCHEMA_VERSION" \
    '.schema_version == $schema and (.users | type == "array") and (.splits | type == "array") and
     ($schema < 4 or ((.outbound_presets | type == "array") and (.rule_presets | type == "array")))' "$STATE_FILE" >/dev/null; then
    fail '管理状态结构' '状态文件缺失、不可读或结构无效'
    return 1
  fi
  pass '管理状态结构' "schema $STATE_SCHEMA_VERSION"
  command -v flock >/dev/null || { fail '管理锁' '缺少 flock'; return 1; }
  exec 9>"$LOCK_FILE"
  if flock -n 9; then pass '管理锁' '已取得只读验收锁'; else fail '管理锁' '存在其他管理操作'; return 1; fi
  audit_output="$WORK/audit.txt"
  audit_consistency > "$audit_output"
  audit_rc=$?
  if ((audit_rc == 0)); then
    if ((AUDIT_ISSUES == 0)); then pass '管理数据一致性'; else fail '管理数据一致性' "发现 $AUDIT_ISSUES 项"; fi
  else
    fail '管理数据一致性' '一致性检测无法执行'
  fi
  release_operation_lock
}

fetch_release_json() {
  local url="$1" output="$2"
  curl -fsSL --retry 3 -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' "$url" > "$output"
}

download_release_asset() {
  local url="$1" output="$2"
  curl -fsSL --retry 3 --proto '=https' --max-redirs 5 -o "$output" "$url"
}

latest_environment_snapshot() {
  local candidate latest=""
  [[ -d "$ENVIRONMENT_BACKUP_BASE" ]] || return 1
  while IFS= read -r candidate; do
    [[ -f "$candidate/SNAPSHOT_VERSION" && -d "$candidate/root" ]] && latest="$candidate"
  done < <(find "$ENVIRONMENT_BACKUP_BASE" -mindepth 1 -maxdepth 1 -type d -print | LC_ALL=C sort)
  [[ -n "$latest" ]] || return 1
  printf '%s\n' "$latest"
}

run_release_audit() {
  local repository asset tag release_json asset_url expected_digest downloaded downloaded_digest installed_digest downloaded_version snapshot base_mode
  printf '\n正式发布验收（只读）\n\n'
  repository="${MANAGER_REPOSITORY:-}"
  asset="${RELEASE_ASSET:-${MANAGER_ASSET:-sb-user-manager.sh}}"
  tag="v${SCRIPT_VERSION}"
  release_json="$WORK/release.json"
  downloaded="$WORK/$asset"

  if [[ -z "$repository" ]]; then
    fail '正式 Release 信息' '管理脚本没有提供仓库信息'
  elif ! fetch_release_json "https://api.github.com/repos/${repository}/releases/tags/${tag}" "$release_json"; then
    fail '正式 Release 信息' "无法匿名读取公开 Release ${tag}"
  elif jq -e --arg tag "$tag" '.tag_name == $tag and .draft == false and .prerelease == false' "$release_json" >/dev/null; then
    pass '正式 Release 状态' "$tag"
  else
    fail '正式 Release 状态' "${tag} 不存在、仍是草稿或属于预发布"
  fi

  if [[ -s "$release_json" ]]; then
    asset_url="$(jq -r --arg asset "$asset" '.assets[]? | select(.name == $asset) | .browser_download_url // empty' "$release_json" | head -n1)"
    expected_digest="$(jq -r --arg asset "$asset" '.assets[]? | select(.name == $asset) | (.digest // "") | sub("^sha256:"; "")' "$release_json" | head -n1)"
    if [[ -n "$asset_url" && "$expected_digest" =~ ^[0-9a-fA-F]{64}$ ]]; then
      pass 'Release 脚本附件与摘要' "$asset"
    else
      fail 'Release 脚本附件与摘要' "${asset} 缺失或没有有效 SHA-256"
    fi
    if [[ -n "$asset_url" && "$expected_digest" =~ ^[0-9a-fA-F]{64}$ ]] &&
       download_release_asset "$asset_url" "$downloaded"; then
      downloaded_digest="$(sha256sum "$downloaded" | awk '{print $1}')"
      installed_digest="$(sha256sum "$MANAGER" | awk '{print $1}')"
      if [[ "$downloaded_digest" == "$expected_digest" && "$installed_digest" == "$expected_digest" ]]; then
        pass '已安装脚本与 Release 一致' "$expected_digest"
      else
        fail '已安装脚本与 Release 一致' 'GitHub 摘要、下载文件或已安装脚本不一致'
      fi
      downloaded_version="$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)"/\1/p' "$downloaded" | head -n1)"
      if [[ "$downloaded_version" == "$SCRIPT_VERSION" ]] && bash -n "$downloaded"; then
        pass 'Release 脚本版本与语法' "$downloaded_version"
      else
        fail 'Release 脚本版本与语法' "附件版本 ${downloaded_version:-无法识别}"
      fi
    elif [[ -n "$asset_url" ]]; then
      fail '下载 Release 脚本' "$asset"
    fi
  fi

  if [[ ! -d "$ENVIRONMENT_BACKUP_BASE" ]]; then
    fail '完整环境快照目录' '目录不存在'
  else
    base_mode="$(file_mode "$ENVIRONMENT_BACKUP_BASE" || printf unknown)"
    if [[ "$base_mode" == 700 ]]; then pass '完整环境快照根目录权限' "$base_mode"
    else fail '完整环境快照根目录权限' "当前 ${base_mode}，应为 700"
    fi
  fi
  if ! snapshot="$(latest_environment_snapshot)"; then
    fail '最近完整环境快照' '未找到可验收的快照'
  else
    if verify_environment_backup "$snapshot" > "$WORK/snapshot-verify.log" 2>&1; then
      pass '最近完整环境快照校验' "$(basename "$snapshot")"
    else
      fail '最近完整环境快照校验' "$(basename "$snapshot")"
    fi
    if declare -F verify_environment_backup_permissions >/dev/null &&
       verify_environment_backup_permissions "$snapshot" > "$WORK/snapshot-permissions.log" 2>&1; then
      pass '最近完整环境快照权限' '目录 700，清单 600'
    else
      fail '最近完整环境快照权限' '目录或清单权限不符合安全要求'
    fi
  fi
}

run_mutation() {
  local label="$1"
  shift
  CURRENT_MUTATION_LABEL="$label"
  (trap - ERR; set -Eeuo pipefail; "$@") > "$WORK/mutation.log" 2>&1
  CURRENT_MUTATION_LABEL=""
  pass "$label"
}

run_mutation_with_input() {
  local label="$1" input="$2"
  shift 2
  CURRENT_MUTATION_LABEL="$label"
  (trap - ERR; set -Eeuo pipefail; "$@") <<<"$input" > "$WORK/mutation.log" 2>&1
  CURRENT_MUTATION_LABEL=""
  pass "$label"
}

verify_state_value() {
  local label="$1" filter="$2" expected="$3" actual
  actual="$(jq -r "$filter" "$STATE_FILE" 2>/dev/null)"
  if [[ "$actual" == "$expected" ]]; then pass "$label"; else fail "$label" "预期 ${expected}，实际 ${actual:-empty}"; return 1; fi
}

cleanup_live_objects() {
  [[ "$LIVE_STARTED" == true && "$LIVE_CLEANED" != true ]] || return 0
  printf '\n清理验收对象\n'
  if [[ -n "$SPLIT_NAME" ]] && split_exists "$SPLIT_NAME"; then
    run_mutation '清理测试分流' cmd_split_remove "$SPLIT_NAME"
  fi
  if outbound_preset_exists "${SPLIT_NAME}-exit"; then
    run_mutation '清理测试预置出口' cmd_outbound_preset_remove "${SPLIT_NAME}-exit"
  fi
  if rule_preset_exists "${SPLIT_NAME}-rule"; then
    run_mutation '清理测试预置规则' cmd_rule_preset_remove "${SPLIT_NAME}-rule"
  fi
  for name in "$SS_USER" "$ANYTLS_USER" "$MERGE_TARGET_USER"; do
    [[ -n "$name" ]] || continue
    if user_exists "$name"; then
      run_mutation "清理测试用户 $name" cmd_remove "$name"
    fi
  done
}

run_split_lifecycle() {
  local upstream updated_upstream updated_url password config_before config_after
  if [[ -z "$RULESET_URL" ]]; then
    skip '分流生命周期' '未设置 SB_ACCEPTANCE_RULESET_URL'
    return 0
  fi
  [[ "$RULESET_URL" == https://* && "$RULESET_URL" =~ \.(srs|json)([?#].*)?$ ]] || {
    fail '分流生命周期' '规则集必须是 HTTPS .srs/.json 地址'
    return 1
  }
  password="$(generate_ss_password 2022-blake3-aes-128-gcm)"
  upstream="$(jq -cn --arg password "$password" '{protocol:"shadowsocks",server:"127.0.0.1",server_port:9,method:"2022-blake3-aes-128-gcm",password:$password}')"
  state_add_outbound_preset "${SPLIT_NAME}-exit" "$upstream"
  state_add_rule_preset "${SPLIT_NAME}-rule" "$RULESET_URL"
  run_mutation '增加用户专属分流' cmd_split_add "$SPLIT_NAME" "$RULESET_URL" user "$ANYTLS_USER" "$upstream" "${SPLIT_NAME}-out" "${SPLIT_NAME}-rule" "${SPLIT_NAME}-exit"
  verify_state_value '分流状态为启用' ".splits[] | select(.name == \"$SPLIT_NAME\") | .status" active || return 1
  updated_upstream="$(jq -cn --arg password "$password" '{protocol:"shadowsocks",server:"127.0.0.1",server_port:10,method:"2022-blake3-aes-128-gcm",password:$password}')"
  run_mutation '修改关联预置出口并同步分流' cmd_outbound_preset_edit "${SPLIT_NAME}-exit" "$updated_upstream"
  if jq -e --arg name "$SPLIT_NAME" --arg preset "${SPLIT_NAME}-exit" --argjson upstream "$updated_upstream" '
      .splits[] | select(.name == $name and .outbound_preset == $preset and .upstream == $upstream)
    ' "$STATE_FILE" >/dev/null; then pass '预置出口修改已同步关联分流'; else fail '预置出口修改已同步关联分流'; return 1; fi
  if [[ "$RULESET_URL" == *\?* ]]; then updated_url="${RULESET_URL}&sbm_acceptance=1"; else updated_url="${RULESET_URL}?sbm_acceptance=1"; fi
  run_mutation '修改关联预置规则并同步分流' cmd_rule_preset_edit "${SPLIT_NAME}-rule" "$updated_url"
  if jq -e --arg name "$SPLIT_NAME" --arg preset "${SPLIT_NAME}-rule" --arg url "$updated_url" '
      .splits[] | select(.name == $name and .rule_preset == $preset and .url == $url)
    ' "$STATE_FILE" >/dev/null; then pass '预置规则修改已同步关联分流'; else fail '预置规则修改已同步关联分流'; return 1; fi
  if [[ "$MODE" != full ]]; then
    config_before="$(sha256sum "$SINGBOX_CONFIG" | awk '{print $1}')"
    run_mutation '删除预置出口并保留分流快照' cmd_outbound_preset_remove "${SPLIT_NAME}-exit"
    run_mutation '删除预置规则并保留分流快照' cmd_rule_preset_remove "${SPLIT_NAME}-rule"
    config_after="$(sha256sum "$SINGBOX_CONFIG" | awk '{print $1}')"
    if [[ "$config_before" == "$config_after" ]] && jq -e --arg name "$SPLIT_NAME" '
        .splits[] | select(.name == $name and (has("outbound_preset")|not) and (has("rule_preset")|not) and .upstream.server_port == 10)
      ' "$STATE_FILE" >/dev/null; then pass '删除预置只解除关联且不改运行配置'; else fail '删除预置只解除关联且不改运行配置'; return 1; fi
  fi
  run_mutation '停用分流' cmd_split_disable "$SPLIT_NAME"
  verify_state_value '分流状态为停用' ".splits[] | select(.name == \"$SPLIT_NAME\") | .status" disabled || return 1
  run_mutation '重新启用分流' cmd_split_enable "$SPLIT_NAME"
  if [[ "$MODE" == full ]]; then pass '保留测试分流供迁移恢复'; else
    run_mutation '删除分流' cmd_split_remove "$SPLIT_NAME"
  fi
}

expire_acceptance_user() {
  state_set_expiry "$1" "$2"
  cmd_expire
}

set_acceptance_usage() {
  nfuse set-usage "$1" "$2" >/dev/null
  nfuse persist >/dev/null
}

remove_full_test_users() {
  cmd_remove "$SS_USER"
  cmd_remove "$ANYTLS_USER"
}

run_lifecycle() {
  local suffix ss_port anytls_port sni edited_sni edited_expiry old_secret new_secret limit_bytes list_output expires usage
  [[ "$CONFIRM" == YES ]] || { fail '写入型验收授权' '必须设置 SB_ACCEPTANCE_CONFIRM=YES'; return 1; }
  if ((FAILURES > 0)); then fail '写入型验收前置检查' '只读验收存在失败项'; return 1; fi
  prepare_core
  BASELINE_USERS="$(jq '.users | length' "$STATE_FILE")"
  BASELINE_SPLITS="$(jq '.splits | length' "$STATE_FILE")"
  if [[ "$MODE" == full && ( "$BASELINE_USERS" != 0 || "$BASELINE_SPLITS" != 0 ) ]]; then
    fail '空机迁移保护' "基线包含用户 ${BASELINE_USERS}、分流 ${BASELINE_SPLITS}"
    release_operation_lock
    return 1
  fi
  if [[ "$MODE" == full && -z "$RULESET_URL" ]]; then
    fail '完整迁移分流前置条件' 'full 模式必须设置 SB_ACCEPTANCE_RULESET_URL'
    release_operation_lock
    return 1
  fi
  CURRENT_MUTATION_LABEL='创建验收前环境快照'
  create_environment_backup
  CURRENT_MUTATION_LABEL=""
  SNAPSHOT="$ENV_BACKUP"
  pass '创建验收前环境快照' "$SNAPSHOT"
  suffix="$(date '+%H%M%S')$((RANDOM % 1000))"
  SS_USER="accss${suffix}"
  ANYTLS_USER="accat${suffix}"
  SPLIT_NAME="accsp${suffix}"
  sni="${SB_ACCEPTANCE_SNI:-www.microsoft.com}"
  validate_shadowtls_sni "$sni"
  LIVE_STARTED=true

  ss_port="$(find_available_user_port)"
  run_mutation '创建自用 SS2022 + ShadowTLS 用户' cmd_add self "$SS_USER" "$ss_port" 2022-blake3-aes-128-gcm "$sni"
  if ss -H -lnu "sport = :$ss_port" | grep -q .; then pass 'SS2022 同端口 UDP 监听'; else fail 'SS2022 同端口 UDP 监听'; return 1; fi
  anytls_port="$(find_available_user_port)"
  run_mutation '创建计量 AnyTLS 用户' cmd_add_anytls managed "$ANYTLS_USER" "$anytls_port" 1 1 1 "$sni"
  verify_state_value 'SS2022 用户写入状态' ".users[] | select(.name == \"$SS_USER\") | .protocol // \"ss2022\"" ss2022 || return 1
  verify_state_value 'AnyTLS 用户写入状态' ".users[] | select(.name == \"$ANYTLS_USER\") | .protocol" anytls || return 1
  if nfuse_account_exists "$ANYTLS_USER" && nfuse_port_exists "$anytls_port"; then pass 'Nfuse 账户与端口联动'; else fail 'Nfuse 账户与端口联动'; return 1; fi

  if cmd_export "$SS_USER" surge > "$WORK/export-ss.txt" &&
     grep -Fq '[Surge]' "$WORK/export-ss.txt" && grep -Fq 'udp-relay=true' "$WORK/export-ss.txt" &&
     ! grep -Fq 'udp-port=' "$WORK/export-ss.txt"; then
    pass '导出 SS2022 Surge 同端口 UDP 配置'
  else
    fail '导出 SS2022 Surge 同端口 UDP 配置'
    return 1
  fi
  if cmd_export "$SS_USER" shadowrocket > "$WORK/export-ss-shadowrocket.txt" &&
     grep -Eq '^ss://[^[:space:]]+\?shadow-tls=[^[:space:]]+#[^[:space:]]+$' "$WORK/export-ss-shadowrocket.txt" &&
     ! grep -Fq 'shadow-tls-password=' "$WORK/export-ss-shadowrocket.txt"; then
    pass '导出 SS2022 + ShadowTLS Shadowrocket URL'
  else
    fail '导出 SS2022 + ShadowTLS Shadowrocket URL'
    return 1
  fi
  if cmd_export "$ANYTLS_USER" shadowrocket > "$WORK/export-anytls.txt" &&
     grep -Eq '^anytls://[^[:space:]]+\?peer=[^&[:space:]]+&insecure=1&udp=1#[^[:space:]]+$' "$WORK/export-anytls.txt" &&
     ! grep -Fq '=anytls,' "$WORK/export-anytls.txt"; then
    pass '导出 AnyTLS Shadowrocket URL'
  else
    fail '导出 AnyTLS Shadowrocket URL'
    return 1
  fi

  old_secret="$(jq -r --arg name "$SS_USER" '.users[] | select(.name == $name) | .ss2022_password' "$STATE_FILE")"
  ss_port="$(find_available_user_port)"
  edited_sni="edit.${sni}"
  run_mutation '编辑启用中的 SS2022 用户' cmd_edit_user "$SS_USER" "$ss_port" "$edited_sni" 2022-blake3-aes-256-gcm '' ''
  new_secret="$(jq -r --arg name "$SS_USER" '.users[] | select(.name == $name) | .ss2022_password' "$STATE_FILE")"
  if [[ "$new_secret" != "$old_secret" ]] &&
     jq -e --arg name "$SS_USER" --arg sni "$edited_sni" --argjson port "$ss_port" '
       .users[] | select(.name == $name and .port == $port and .shadowtls_sni == $sni and .method == "2022-blake3-aes-256-gcm")
     ' "$STATE_FILE" >/dev/null &&
     tag_exists_in_config "st-$SS_USER" && tag_exists_in_config "ss-$SS_USER" && tag_exists_in_config "ss-udp-$SS_USER"; then
    pass 'SS2022 编辑同步状态、入站并更换密钥'
  else
    fail 'SS2022 编辑同步状态、入站并更换密钥'
    return 1
  fi

  old_secret="$(jq -r --arg name "$ANYTLS_USER" '.users[] | select(.name == $name) | .anytls_password' "$STATE_FILE")"
  anytls_port="$(find_available_user_port)"
  edited_sni="edit-anytls.${sni}"
  edited_expiry="$(date -d '+2 month' '+%Y-%m-%dT%H:%M:%S%z')"
  run_mutation '编辑启用中的计量 AnyTLS 用户' cmd_edit_user "$ANYTLS_USER" "$anytls_port" "$edited_sni" '' 2 "$edited_expiry"
  new_secret="$(jq -r --arg name "$ANYTLS_USER" '.users[] | select(.name == $name) | .anytls_password' "$STATE_FILE")"
  if [[ "$new_secret" == "$old_secret" ]] &&
     jq -e --arg name "$ANYTLS_USER" --arg sni "$edited_sni" --arg expiry "$edited_expiry" --argjson port "$anytls_port" '
       .users[] | select(.name == $name and .port == $port and .tls_sni == $sni and .billing_anchor == 2 and .expires_at == $expiry)
     ' "$STATE_FILE" >/dev/null &&
     nfuse_port_exists "$anytls_port" && tag_exists_in_config "anytls-$ANYTLS_USER"; then
    pass 'AnyTLS 编辑同步状态、入站和 Nfuse 且保留密钥'
  else
    fail 'AnyTLS 编辑同步状态、入站和 Nfuse 且保留密钥'
    return 1
  fi

  run_mutation '停用自用 SS2022 + ShadowTLS 用户' cmd_disable "$SS_USER"
  verify_state_value 'SS2022 用户状态为停用' ".users[] | select(.name == \"$SS_USER\") | .status" disabled || return 1
  if ss -H -lnu "sport = :$ss_port" | grep -q .; then fail 'SS2022 停用后 UDP 监听清理'; return 1; else pass 'SS2022 停用后 UDP 监听清理'; fi
  run_mutation '重新启用自用 SS2022 + ShadowTLS 用户' cmd_enable "$SS_USER"
  verify_state_value 'SS2022 用户状态为启用' ".users[] | select(.name == \"$SS_USER\") | .status" active || return 1
  if tag_exists_in_config "st-$SS_USER" && tag_exists_in_config "ss-$SS_USER" && tag_exists_in_config "ss-udp-$SS_USER" &&
     ss -H -lnu "sport = :$ss_port" | grep -q . &&
     nfuse list --json | jq -e --arg name "$SS_USER" --argjson port "$ss_port" '
       .[] | select(.name == $name and .tier == "c") |
       .ports[] | select(.start <= $port and .end >= $port)
     ' >/dev/null; then
    pass 'SS2022 入站重建且自用用户保持不限额流量统计'
  else
    fail 'SS2022 入站重建且自用用户保持不限额流量统计'
    return 1
  fi

  run_mutation '停用 AnyTLS 用户' cmd_disable "$ANYTLS_USER"
  verify_state_value 'AnyTLS 用户状态为停用' ".users[] | select(.name == \"$ANYTLS_USER\") | .status" disabled || return 1
  run_mutation '重新启用 AnyTLS 用户' cmd_enable "$ANYTLS_USER"
  verify_state_value 'AnyTLS 用户状态为启用' ".users[] | select(.name == \"$ANYTLS_USER\") | .status" active || return 1

  limit_bytes="$(nfuse list --json | jq -r --arg name "$ANYTLS_USER" '.[] | select(.name == $name) | .limit_bytes')"
  if nfuse set-usage "$ANYTLS_USER" "$limit_bytes" >/dev/null && nfuse persist >/dev/null; then pass '写入配额耗尽状态'; else fail '写入配额耗尽状态'; return 1; fi
  list_output="$(render_user_list "$(nfuse list --json)")"
  if grep -F "$ANYTLS_USER" <<<"$list_output" | grep -Fq '配额耗尽'; then pass '配额耗尽显示'; else fail '配额耗尽显示'; return 1; fi

  expires="$(date -d '-1 minute' '+%Y-%m-%dT%H:%M:%S%z')"
  run_mutation '到期用户自动停用' expire_acceptance_user "$ANYTLS_USER" "$expires"
  verify_state_value '到期后状态为停用' ".users[] | select(.name == \"$ANYTLS_USER\") | .status" disabled || return 1
  run_mutation '续期并自动启用用户' cmd_renew "$ANYTLS_USER" 1
  verify_state_value '续期后状态为启用' ".users[] | select(.name == \"$ANYTLS_USER\") | .status" active || return 1
  usage="$(nfuse list --json | jq -r --arg name "$ANYTLS_USER" '.[] | select(.name == $name) | .used_bytes')"
  if [[ "$usage" == 0 ]]; then pass '续期启用后已用流量清零'; else fail '续期启用后已用流量清零' "实际 $usage"; return 1; fi

  run_split_lifecycle
}

run_full_migration() {
  local password bundle restored_usage expected_usage target_port target_sni
  [[ "$MODE" == full ]] || return 0
  if ((BASELINE_USERS != 0 || BASELINE_SPLITS != 0)); then
    fail '空机迁移保护' "基线包含用户 ${BASELINE_USERS}、分流 ${BASELINE_SPLITS}"
    return 1
  fi
  password="acceptance-${RUN_ID}"
  expected_usage=123456
  run_mutation '准备迁移流量数据' set_acceptance_usage "$ANYTLS_USER" "$expected_usage"
  export MIGRATION_BACKUP_DIR="$WORK/migration"
  # create/restore 函数会自行取得管理锁；先释放父进程持有的锁，避免自锁冲突。
  release_operation_lock
  run_mutation_with_input '创建单文件迁移备份' "$password"$'\n'"$password" create_migration_backup
  bundle="$(find "$MIGRATION_BACKUP_DIR" -type f -name '*.sbm' -print -quit)"
  [[ -n "$bundle" ]] || { fail '定位单文件迁移备份'; return 1; }
  validate_migration_bundle "$bundle"
  pass '迁移包结构校验'
  prepare_core
  run_mutation '清空测试用户准备恢复' remove_full_test_users
  release_operation_lock
  run_mutation_with_input '恢复单文件迁移备份' "1"$'\n'"$password"$'\n'2$'\n'RESTORE restore_migration_backup
  prepare_core
  if user_exists "$SS_USER" && user_exists "$ANYTLS_USER"; then pass '迁移恢复用户'; else fail '迁移恢复用户'; return 1; fi
  if split_exists "$SPLIT_NAME"; then pass '迁移恢复分流'; else fail '迁移恢复分流'; return 1; fi
  if outbound_preset_exists "${SPLIT_NAME}-exit" && rule_preset_exists "${SPLIT_NAME}-rule" &&
     jq -e --arg name "$SPLIT_NAME" --arg outbound "${SPLIT_NAME}-exit" --arg rule "${SPLIT_NAME}-rule" '
       .splits[] | select(.name == $name and .outbound_preset == $outbound and .rule_preset == $rule)
     ' "$STATE_FILE" >/dev/null; then pass '迁移恢复预置及关联关系'; else fail '迁移恢复预置及关联关系'; return 1; fi
  restored_usage="$(nfuse list --json | jq -r --arg name "$ANYTLS_USER" '.[] | select(.name == $name) | .used_bytes')"
  if [[ "$restored_usage" == "$expected_usage" ]]; then pass '迁移恢复 Nfuse 已用流量'; else fail '迁移恢复 Nfuse 已用流量' "预期 ${expected_usage}，实际 ${restored_usage:-empty}"; return 1; fi

  run_mutation '准备合并测试：移除源分流' cmd_split_remove "$SPLIT_NAME"
  run_mutation '准备合并测试：移除一个源用户' cmd_remove "$ANYTLS_USER"
  MERGE_TARGET_USER="accmg$((RANDOM % 100000))"
  target_port="$(find_available_user_port)"
  target_sni="${SB_ACCEPTANCE_SNI:-www.microsoft.com}"
  run_mutation '准备合并测试：创建目标服务器独有用户' cmd_add_anytls self "$MERGE_TARGET_USER" "$target_port" "$target_sni"
  release_operation_lock
  run_mutation_with_input '智能合并恢复单文件迁移备份' \
    "1"$'\n'"$password"$'\n'1$'\n\n'MERGE restore_migration_backup
  prepare_core
  if user_exists "$SS_USER" && user_exists "$ANYTLS_USER" && user_exists "$MERGE_TARGET_USER"; then
    pass '合并恢复同时保留目标用户并导入缺失用户'
  else
    fail '合并恢复同时保留目标用户并导入缺失用户'
    return 1
  fi
  if split_exists "$SPLIT_NAME"; then pass '合并恢复关联分流'; else fail '合并恢复关联分流'; return 1; fi
  if outbound_preset_exists "${SPLIT_NAME}-exit" && rule_preset_exists "${SPLIT_NAME}-rule" &&
     jq -e --arg name "$SPLIT_NAME" --arg outbound "${SPLIT_NAME}-exit" --arg rule "${SPLIT_NAME}-rule" '
       .splits[] | select(.name == $name and .outbound_preset == $outbound and .rule_preset == $rule)
     ' "$STATE_FILE" >/dev/null; then pass '合并恢复保留预置关联'; else fail '合并恢复保留预置关联'; return 1; fi
  restored_usage="$(nfuse list --json | jq -r --arg name "$ANYTLS_USER" '.[] | select(.name == $name) | .used_bytes')"
  if [[ "$restored_usage" == "$expected_usage" ]]; then pass '合并恢复 Nfuse 已用流量'; else fail '合并恢复 Nfuse 已用流量' "预期 ${expected_usage}，实际 ${restored_usage:-empty}"; return 1; fi
  run_mutation '清理合并测试目标独有用户' cmd_remove "$MERGE_TARGET_USER"
  MERGE_TARGET_USER=""
}

finish_live() {
  # full 模式的子流程会自行加锁；统一重取一次，保证清理期间没有并发管理操作。
  release_operation_lock
  prepare_core
  cleanup_live_objects
  if [[ -z "${STATE_FILE:-}" || ! -r "$STATE_FILE" ]]; then
    fail '清理后管理状态读取' '状态文件不可读'
    CURRENT_MUTATION_LABEL='清理后管理状态读取'
    return 1
  fi
  if [[ "$(jq '.users | length' "$STATE_FILE")" == "$BASELINE_USERS" && "$(jq '.splits | length' "$STATE_FILE")" == "$BASELINE_SPLITS" ]]; then
    pass '清理后对象数量恢复基线'
  else
    fail '清理后对象数量恢复基线'
    CURRENT_MUTATION_LABEL='清理后对象数量验证'
    return 1
  fi
  if ! audit_consistency > "$WORK/final-audit.txt"; then
    fail '清理后管理数据一致性' '一致性检测无法执行'
    CURRENT_MUTATION_LABEL='清理后一致性检测执行'
    return 1
  fi
  if ((AUDIT_ISSUES == 0)); then
    pass '清理后管理数据一致性'
  else
    fail '清理后管理数据一致性' "发现 $AUDIT_ISSUES 项"
    CURRENT_MUTATION_LABEL='清理后一致性验证'
    return 1
  fi
  LIVE_CLEANED=true
  CURRENT_MUTATION_LABEL=""
  release_operation_lock
}

restore_acceptance_snapshot() {
  local recovery_ok=true service audit_rc
  [[ "$LIVE_STARTED" == true && "$LIVE_CLEANED" != true && -n "$SNAPSHOT" ]] || return 0
  release_operation_lock
  if restore_environment_backup "$SNAPSHOT" > "$WORK/snapshot-restore.log" 2>&1; then
    "$SINGBOX_BIN" check -c "$SINGBOX_CONFIG" >> "$WORK/snapshot-restore.log" 2>&1 || recovery_ok=false
    nfuse list --json | jq -e 'type == "array"' >> "$WORK/snapshot-restore.log" 2>&1 || recovery_ok=false
    for service in sing-box.service nfuse.service sb-user-expiry.timer; do
      systemctl is-active --quiet "$service" || recovery_ok=false
    done
    if [[ "$recovery_ok" == true ]]; then
      AUDIT_ISSUES=1
      if audit_consistency >> "$WORK/snapshot-restore.log" 2>&1; then audit_rc=0; else audit_rc=$?; fi
      if ((audit_rc != 0 || AUDIT_ISSUES != 0)); then recovery_ok=false; fi
    fi
    if [[ "$recovery_ok" == true ]]; then
      LIVE_CLEANED=true
      pass '失败后恢复验收前环境并通过复检'
    else
      fail '失败后恢复验收前环境并通过复检' "快照文件已恢复，但服务或一致性复检失败；请检查 $SNAPSHOT"
    fi
  else
    fail '失败后恢复验收前环境并通过复检' "请人工保留并检查 $SNAPSHOT"
  fi
}

print_mutation_failure_context() {
  local label="${1:-}"
  if [[ "$label" == '恢复单文件迁移备份' && -s "$WORK/mutation.log" ]]; then
    printf '\n失败步骤输出（末尾 80 行）：\n' >&2
    tail -n 80 "$WORK/mutation.log" >&2
  fi
}

handle_write_failure() {
  local rc="${1:-1}" label="${CURRENT_MUTATION_LABEL:-写入型验收}"
  trap - ERR
  trap '' INT TERM
  set +e
  fail "$label" '执行失败，正在恢复验收前环境'
  print_mutation_failure_context "$label"
  CURRENT_MUTATION_LABEL=""
  restore_acceptance_snapshot
  write_report
  rm -rf "$WORK"
  exit "$rc"
}

on_signal() {
  trap - ERR
  trap '' INT TERM
  set +e
  fail '验收进程被中断' "$1"
  restore_acceptance_snapshot
  write_report
  rm -rf "$WORK"
  exit "$2"
}

main() {
  case "$MODE" in audit|release|lifecycle|full) ;; -h|--help) usage; exit 0;; *) usage >&2; exit 2;; esac
  if [[ "$TEST_MODE" != true && $EUID -ne 0 ]]; then printf '验收脚本必须使用 root 运行。\n' >&2; exit 1; fi
  command -v jq >/dev/null || { printf '验收脚本缺少 jq。\n' >&2; exit 1; }
  init_acceptance_work || { printf '无法创建验收临时目录。\n' >&2; exit 1; }
  : > "$RESULTS"
  trap 'on_signal INT 130' INT
  trap 'on_signal TERM 143' TERM
  if ! source_manager; then fail '载入管理脚本'; write_report; rm -rf "$WORK"; exit 1; fi
  pass '载入管理脚本' "$MANAGER"
  run_audit
  if [[ "$MODE" == release ]]; then
    command -v curl >/dev/null || fail '正式 Release 检查工具' '缺少 curl'
    command -v sha256sum >/dev/null || fail '正式 Release 检查工具' '缺少 sha256sum'
    if command -v curl >/dev/null && command -v sha256sum >/dev/null; then run_release_audit; fi
  elif [[ "$MODE" != audit ]]; then
    trap 'handle_write_failure $?' ERR
    run_lifecycle
    run_full_migration
    if [[ "$LIVE_STARTED" == true ]]; then finish_live; else release_operation_lock; fi
    trap - ERR
  fi
  write_report
  rm -rf "$WORK"
  ((FAILURES == 0))
}

if [[ "${SB_ACCEPTANCE_LIBRARY:-false}" != true ]]; then
  main "$@"
fi
