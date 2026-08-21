#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")/.."
export SB_USER_MANAGER_LIBRARY=true
# shellcheck source=../sb-user-manager.sh
source ./sb-user-manager.sh

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# 审计夹具必须带骨架，否则新增的骨架检查会在每个用例里额外报出缺项，
# 把各用例真正要断言的东西淹掉。这里用与实现相同的补齐程序处理夹具，
# 夹具因此与真实部署保持一致，而不是靠调高期望的问题数来回避。
apply_skeleton_to_test_config() {
  local tmp
  tmp="$(mktemp "$work/skeleton.XXXXXX")" || return 1
  # 补齐骨架后再删掉空容器，模拟 sing-box format 的真实输出——它会把空数组整个
  # 省略。夹具因此与真实部署一致；不这样做就重现不了 Issue #135 那类误报：
  # 内核桩的 format 分支只做美化输出，会原样保留空数组。
  jq -c "$SINGBOX_SKELETON_ENSURE_PROGRAM
    | (if (.inbounds | length) == 0 then del(.inbounds) else . end)
    | (if (.route.rules | length) == 0 then del(.route.rules) else . end)
    | (if (.route.rule_set | length) == 0 then del(.route.rule_set) else . end)" \
    "$SINGBOX_CONFIG" > "$tmp" || return 1
  mv "$tmp" "$SINGBOX_CONFIG" || return 1
}

create_test_sqlite_database() {
  python3 - "$1" "$2" <<'PY'
import sqlite3
import sys

database = sqlite3.connect(sys.argv[1])
database.execute("CREATE TABLE test_marker (value TEXT NOT NULL)")
database.execute("INSERT INTO test_marker VALUES (?)", (sys.argv[2],))
database.commit()
database.close()
PY
}

read_test_sqlite_marker() {
  python3 - "$1" <<'PY'
import sqlite3
import sys

database = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
print(database.execute("SELECT value FROM test_marker").fetchone()[0])
database.close()
PY
}

# 两种协议共用同一套 Nfuse 新用户登记步骤；分别覆盖计量与自用参数，
# 并锁定两个协议入口都只能通过该共用函数完成登记。
(
  calls="$work/new-user-nfuse-metered"
  run_managed_step() { printf '%s\n' "$*" >> "$calls"; }
  register_new_user_nfuse alice 23001 true 100 5
  diff -u <(cat <<'EOF'
nfuse add alice --tier a --limit 100 --anchor 5
nfuse port add alice 23001
nfuse persist
EOF
  ) "$calls"
)
(
  calls="$work/new-user-nfuse-self"
  run_managed_step() { printf '%s\n' "$*" >> "$calls"; }
  register_new_user_nfuse bob 23002 false '' ''
  diff -u <(cat <<'EOF'
nfuse add bob --tier c --limit 0 --anchor 1
nfuse port add bob 23002
nfuse persist
EOF
  ) "$calls"
)
(
  calls="$work/new-user-nfuse-multi"
  run_managed_step() { printf '%s\n' "$*" >> "$calls"; }
  register_new_user_nfuse_ports multi true 88 12 23003 23004
  diff -u <(cat <<'EOF'
nfuse add multi --tier a --limit 88 --anchor 12
nfuse port add multi 23003
nfuse port add multi 23004
nfuse persist
EOF
  ) "$calls"
)
[[ "$(declare -f cmd_add | grep -Fc 'register_new_user_nfuse')" == 1 ]]
[[ "$(declare -f cmd_add_anytls | grep -Fc 'register_new_user_nfuse')" == 1 ]]

# 双协议账户只保存一份生命周期与流量字段，协议入口可独立增删且会正确同步主入口镜像。
(
  STATE_FILE="$work/state-multi-user.json"
  printf '%s\n' '{"schema_version":6,"users":[],"splits":[],"outbound_presets":[],"rule_presets":[]}' > "$STATE_FILE"
  state_add_multi_user multi 23003 23004 ss-secret at-secret 88 12 true \
    2027-01-01T00:00:00+0800 2022-blake3-aes-128-gcm at.example.com
  jq -e '
    (.users | length) == 1 and
    .users[0].limit_gib == 88 and .users[0].billing_anchor == 12 and
    .users[0].status == "active" and (.users[0].endpoints | length) == 2 and
    [.users[0].endpoints[].protocol] == ["ss2022","anytls"] and
    [.users[0].endpoints[].port] == [23003,23004] and
    .users[0].endpoints[0] == {protocol:"ss2022",transport:"direct",port:23003,
      ss2022_password:"ss-secret",method:"2022-blake3-aes-128-gcm"} and
    (.users[0] | has("shadowtls_password") | not) and
    (.users[0] | has("shadowtls_sni") | not)
  ' "$STATE_FILE" >/dev/null
  tags="$(split_user_inbound_tags multi)"
  jq -e '. == ["anytls-multi","ss-multi"]' <<<"$tags" >/dev/null
  PUBLIC_SERVER=203.0.113.10
  cmd_export multi surge > "$work/state-multi-export.txt"
  grep -Fq 'multi-SS2022 = ss, 203.0.113.10, 23003' "$work/state-multi-export.txt"
  grep -Fq 'multi-AnyTLS = anytls, 203.0.113.10, 23004' "$work/state-multi-export.txt"
  state_remove_user_endpoint multi ss2022-direct
  jq -e '
    .users[0].protocol == "anytls" and .users[0].port == 23004 and
    .users[0].anytls_password == "at-secret" and
    .users[0].endpoints == [{protocol:"anytls",port:23004,anytls_password:"at-secret",tls_sni:"at.example.com"}] and
    .users[0].limit_gib == 88 and .users[0].billing_anchor == 12
  ' "$STATE_FILE" >/dev/null
)

# 同一账户可受限共存一个旧版 ShadowTLS、一个原生 SS2022 和一个 AnyTLS；
# 三类入口必须使用独立标签、独立导出名称，并能精确编辑或移除其中一个。
(
  STATE_FILE="$work/state-three-endpoints.json"
  HANDSHAKE_PORT=443
  SHADOWTLS_STRICT_MODE=true
  cat > "$STATE_FILE" <<'EOF'
{"schema_version":7,"users":[{"name":"triple","port":23101,"protocol":"ss2022","transport":"shadowtls","shadowtls_password":"legacy-st","ss2022_password":"legacy-ss","method":"2022-blake3-aes-128-gcm","shadowtls_sni":"legacy.example.com","metered":false,"expires_at":null,"limit_gib":null,"billing_anchor":null,"usage_offset_bytes":0,"status":"disabled","created_at":"2026-08-11T00:00:00+08:00","endpoints":[{"protocol":"ss2022","transport":"shadowtls","port":23101,"shadowtls_password":"legacy-st","ss2022_password":"legacy-ss","method":"2022-blake3-aes-128-gcm","shadowtls_sni":"legacy.example.com"},{"protocol":"ss2022","transport":"direct","port":23102,"ss2022_password":"direct-ss","method":"2022-blake3-aes-128-gcm"},{"protocol":"anytls","port":23103,"anytls_password":"any-secret","tls_sni":"any.example.com"}]}],"splits":[],"outbound_presets":[],"rule_presets":[]}
EOF
  validate_state_user_endpoints "$STATE_FILE"
  jq -n --slurpfile state "$STATE_FILE" '{format_version:1,created_at:"2026-08-11T00:00:00+08:00",
    script_version:"4.25.0",source_hostname:"test",state:$state[0],nfuse_usage:[]}' \
    > "$work/state-three-migration-payload.json"
  validate_migration_payload_structure "$work/state-three-migration-payload.json"
  fragment="$(make_user_inbounds_from_state "$(jq -c '.users[0]' "$STATE_FILE")")"
  jq -e '
    length == 5 and
    ([.[].tag] | sort) == ["anytls-triple","ss-direct-triple","ss-triple","ss-udp-triple","st-triple"] and
    any(.[]; .tag == "ss-direct-triple" and .listen_port == 23102) and
    any(.[]; .tag == "st-triple" and .listen_port == 23101)
  ' <<<"$fragment" >/dev/null
  jq -e '. == ["anytls-triple","ss-direct-triple","ss-triple","ss-udp-triple","st-triple"]' \
    <<<"$(split_user_inbound_tags triple)" >/dev/null
  PUBLIC_SERVER=203.0.113.10
  cmd_export triple surge > "$work/state-three-endpoints-export.txt"
  grep -Fq 'triple-SS2022-ShadowTLS = ss, 203.0.113.10, 23101' "$work/state-three-endpoints-export.txt"
  grep -Fq 'triple-SS2022 = ss, 203.0.113.10, 23102' "$work/state-three-endpoints-export.txt"
  grep -Fq 'triple-AnyTLS = anytls, 203.0.113.10, 23103' "$work/state-three-endpoints-export.txt"

  cp "$STATE_FILE" "$work/state-three-remove-direct.json"
  STATE_FILE="$work/state-three-remove-direct.json"
  state_remove_user_endpoint triple ss2022-direct
  jq -e '
    [.users[0].endpoints[] |
      if .protocol == "anytls" then "anytls" else "ss2022-" + .transport end] ==
      ["ss2022-shadowtls","anytls"] and
    .users[0].shadowtls_password == "legacy-st" and .users[0].usage_offset_bytes == 0
  ' "$STATE_FILE" >/dev/null

  cp "$work/state-three-endpoints.json" "$work/state-three-remove-legacy.json"
  STATE_FILE="$work/state-three-remove-legacy.json"
  state_remove_user_endpoint triple ss2022-shadowtls
  jq -e '
    .users[0].protocol == "ss2022" and .users[0].transport == "direct" and .users[0].port == 23102 and
    .users[0].ss2022_password == "direct-ss" and
    [.users[0].endpoints[].protocol] == ["ss2022","anytls"]
  ' "$STATE_FILE" >/dev/null

  cp "$work/state-three-endpoints.json" "$work/state-three-edit-direct.json"
  STATE_FILE="$work/state-three-edit-direct.json"
  ensure_safe_ssh_for_kernel_restart() { return 0; }
  start_managed_operation() { :; }
  finish_managed_operation() { :; }
  generate_ss_password() { printf 'new-direct-secret\n'; }
  cmd_export() { :; }
  cmd_edit_user triple 23102 '' 2022-blake3-aes-256-gcm '' '' ss2022-direct >/dev/null
  jq -e '
    (.users[0].endpoints[] | select(.transport == "shadowtls") |
      .method == "2022-blake3-aes-128-gcm" and .ss2022_password == "legacy-ss") and
    (.users[0].endpoints[] | select(.transport == "direct") |
      .method == "2022-blake3-aes-256-gcm" and .ss2022_password == "new-direct-secret")
  ' "$STATE_FILE" >/dev/null
)

# 同类入口仍然禁止重复，避免把受限迁移模型退化为任意多开。
(
  duplicate_state="$work/state-three-duplicate.json"
  jq '.users[0].endpoints[2] = (.users[0].endpoints[1] | .port = 23103)' \
    "$work/state-three-endpoints.json" > "$duplicate_state"
  if validate_state_user_endpoints "$duplicate_state"; then
    echo 'state validation accepted two native SS2022 endpoints' >&2
    exit 1
  fi
)

(
  STATE_FILE="$work/state-three-remove-direct.json"
  MENU_RETURNED=false
  prepare_core() { :; }
  prompt_manage_user_protocols <<<$'1\n0'
  [[ "$MENU_RETURNED" == true ]]
) > "$work/state-three-protocol-menu.txt"
grep -Fq '添加原生 SS2022' "$work/state-three-protocol-menu.txt"
if grep -Fq '添加 SS2022 + ShadowTLS' "$work/state-three-protocol-menu.txt"; then
  echo 'unexpected 添加 SS2022 + ShadowTLS in $work/state-three-protocol-menu.txt' >&2
  exit 1
fi

# 不计量用户的 metered=false 是合法状态；添加共享入口时不能把 jq -e 对 false 的
# 返回码误判成读取失败，也不能在事务开始前静默退出。
(
  STATE_FILE="$work/unmetered-endpoint-add.json"
  events="$work/unmetered-endpoint-add-events"
  PORT_MIN=20001
  PORT_MAX=30000
  HANDSHAKE_PORT=443
  SHADOWTLS_STRICT_MODE=true
  cat > "$STATE_FILE" <<'EOF'
{"schema_version":7,"users":[{"name":"crocell","port":21132,"protocol":"ss2022","transport":"shadowtls","shadowtls_password":"legacy-st","ss2022_password":"legacy-ss","method":"2022-blake3-aes-128-gcm","shadowtls_sni":"legacy.example.com","metered":false,"expires_at":null,"limit_gib":null,"billing_anchor":null,"usage_offset_bytes":0,"status":"active","created_at":"2026-08-11T00:00:00+08:00","endpoints":[{"protocol":"ss2022","transport":"shadowtls","port":21132,"shadowtls_password":"legacy-st","ss2022_password":"legacy-ss","method":"2022-blake3-aes-128-gcm","shadowtls_sni":"legacy.example.com"}]}],"splits":[],"outbound_presets":[],"rule_presets":[]}
EOF
  check_new_endpoint_conflicts() { :; }
  nfuse() {
    if [[ "${1:-}" == list ]]; then
      printf '%s\n' '[{"name":"crocell","tier":"c","limit_gib":0,"used_bytes":0,"ports":[{"id":1,"start":21132,"end":21132}]}]'
    else
      printf 'unexpected direct nfuse call: %s\n' "$*" >&2
      return 91
    fi
  }
  generate_ss_password() { printf 'new-direct-secret\n'; }
  ensure_safe_ssh_for_kernel_restart() { return 0; }
  start_managed_operation() { printf 'start:%s\n' "$1" >> "$events"; }
  run_managed_step() { printf 'step:%s\n' "$*" >> "$events"; }
  rebuild_user_splits_if_needed() { return 0; }
  finish_managed_operation() { printf 'finish\n' >> "$events"; }
  cmd_export() { printf 'export:%s\n' "$1" >> "$events"; }

  cmd_add_user_endpoint crocell ss2022-direct 27353 2022-blake3-aes-128-gcm '' >/dev/null
  grep -Fxq 'start:add-user-endpoint:crocell:ss2022-direct' "$events"
  grep -Fxq 'step:nfuse port add crocell 27353' "$events"
  grep -Fxq finish "$events"
  grep -Fxq export:crocell "$events"
)

# 损坏的非布尔计费字段仍须在事务开始前明确拒绝。
(
  STATE_FILE="$work/invalid-metered-endpoint-add.json"
  transaction_marker="$work/invalid-metered-endpoint-add-transaction"
  printf '%s\n' '{"schema_version":7,"users":[{"name":"broken","port":21133,"protocol":"ss2022","transport":"shadowtls","shadowtls_password":"legacy-st","ss2022_password":"legacy-ss","method":"2022-blake3-aes-128-gcm","shadowtls_sni":"legacy.example.com","metered":"false","status":"disabled","endpoints":[{"protocol":"ss2022","transport":"shadowtls","port":21133,"shadowtls_password":"legacy-st","ss2022_password":"legacy-ss","method":"2022-blake3-aes-128-gcm","shadowtls_sni":"legacy.example.com"}]}],"splits":[],"outbound_presets":[],"rule_presets":[]}' > "$STATE_FILE"
  PORT_MIN=20001
  PORT_MAX=30000
  check_new_endpoint_conflicts() { :; }
  start_managed_operation() { printf 'unexpected\n' > "$transaction_marker"; }
  if cmd_add_user_endpoint broken ss2022-direct 27354 2022-blake3-aes-128-gcm '' \
      >"$work/invalid-metered-endpoint-add.out" 2>"$work/invalid-metered-endpoint-add.err"; then
    echo 'endpoint add accepted a non-boolean metered field' >&2
    exit 1
  fi
  grep -Fq '流量计费状态无效' "$work/invalid-metered-endpoint-add.err"
  [[ ! -e "$transaction_marker" ]]
)

multi_add_body="$(declare -f cmd_add_multi)"
multi_state_line="$(grep -n 'run_managed_step state_add_multi_user' <<<"$multi_add_body" | cut -d: -f1)"
multi_register_line="$(grep -n 'register_new_user_nfuse_ports' <<<"$multi_add_body" | cut -d: -f1)"
multi_listener_line="$(grep -n 'run_managed_step append_inbounds_from_new_user_snapshot' <<<"$multi_add_body" | cut -d: -f1)"
[[ "$multi_state_line" =~ ^[0-9]+$ && "$multi_register_line" =~ ^[0-9]+$ && "$multi_listener_line" =~ ^[0-9]+$ ]]
((multi_state_line < multi_register_line && multi_register_line < multi_listener_line))
multi_remove_body="$(declare -f cmd_remove_user_endpoint)"
multi_restart_line="$(grep -n 'run_managed_step check_singbox_and_restart' <<<"$multi_remove_body" | cut -d: -f1)"
multi_nfuse_remove_line="$(grep -n 'run_managed_step nfuse port rm' <<<"$multi_remove_body" | cut -d: -f1)"
((multi_restart_line < multi_nfuse_remove_line))

(
  STATE_FILE="$work/cmd-add-multi-state.json"
  events="$work/cmd-add-multi-events"
  PORT_MIN=20001
  PORT_MAX=30000
  HANDSHAKE_PORT=443
  SHADOWTLS_STRICT_MODE=true
  printf '%s\n' '{"schema_version":6,"users":[],"splits":[],"outbound_presets":[],"rule_presets":[]}' > "$STATE_FILE"
  check_new_user_conflicts() { printf 'preflight:%s:%s\n' "$1" "$3" >> "$events"; }
  generate_st_password() { printf 'test-st-password\n'; }
  generate_ss_password() { printf 'test-ss-password\n'; }
  ensure_safe_ssh_for_kernel_restart() { return 0; }
  start_managed_operation() { printf 'start:%s\n' "$1" >> "$events"; }
  finish_managed_operation() { printf 'finish\n' >> "$events"; }
  run_managed_step() { printf 'step:%s\n' "$1" >> "$events"; "$@"; }
  nfuse() { printf 'nfuse:%s\n' "$*" >> "$events"; }
  append_inbounds_from_new_user_snapshot() { printf 'append\n' >> "$events"; }
  check_singbox_and_restart() { printf 'restart\n' >> "$events"; }
  cmd_export() { printf 'export:%s\n' "$1" >> "$events"; }
  cmd_add_multi self live-multi 24001 24002 2022-blake3-aes-128-gcm at.example.com >/dev/null
  jq -e '
    .users[0].name == "live-multi" and .users[0].metered == false and
    [.users[0].endpoints[].port] == [24001,24002]
  ' "$STATE_FILE" >/dev/null
  nfuse_last="$(grep -n '^nfuse:persist$' "$events" | cut -d: -f1)"
  append_line="$(grep -n '^append$' "$events" | cut -d: -f1)"
  ((nfuse_last < append_line))
  [[ "$(grep -Fc 'nfuse:port add live-multi ' "$events")" == 2 ]]
  [[ "$(grep -Fc finish "$events")" == 1 ]]
)

# 新增用户的公共冲突检查保持两个协议原有顺序；AnyTLS 仅额外检查证书。
(
  trace="$work/new-user-preflight-ss2022"
  config_snapshot="" config_source=""
  user_exists() { printf 'user %s\n' "$1" >> "$trace"; return 1; }
  port_in_state() { printf 'state-port %s\n' "$1" >> "$trace"; return 1; }
  port_is_listening() { printf 'listen-port %s\n' "$1" >> "$trace"; return 1; }
  load_new_user_config_snapshot() {
    printf 'config-snapshot\n' >> "$trace"
    printf -v "$1" '%s' '{"inbounds":[]}'
    printf -v "$2" '%064d' 0
  }
  nfuse_account_exists() { printf 'nfuse-account %s\n' "$1" >> "$trace"; return 1; }
  nfuse_port_exists() { printf 'nfuse-port %s\n' "$1" >> "$trace"; return 1; }
  check_new_user_conflicts ss2022 alice 23001 config_snapshot config_source
  diff -u <(cat <<'EOF'
user alice
state-port 23001
listen-port 23001
config-snapshot
nfuse-account alice
nfuse-port 23001
EOF
  ) "$trace"
)
(
  trace="$work/new-user-preflight-anytls"
  config_snapshot="" config_source=""
  user_exists() { printf 'user %s\n' "$1" >> "$trace"; return 1; }
  port_in_state() { printf 'state-port %s\n' "$1" >> "$trace"; return 1; }
  port_is_listening() { printf 'listen-port %s\n' "$1" >> "$trace"; return 1; }
  load_new_user_config_snapshot() {
    printf 'config-snapshot\n' >> "$trace"
    printf -v "$1" '%s' '{"inbounds":[]}'
    printf -v "$2" '%064d' 0
  }
  anytls_certificate_ready() { printf 'certificate\n' >> "$trace"; }
  nfuse_account_exists() { printf 'nfuse-account %s\n' "$1" >> "$trace"; return 1; }
  nfuse_port_exists() { printf 'nfuse-port %s\n' "$1" >> "$trace"; return 1; }
  check_new_user_conflicts anytls bob 23002 config_snapshot config_source
  diff -u <(cat <<'EOF'
user bob
state-port 23002
listen-port 23002
config-snapshot
certificate
nfuse-account bob
nfuse-port 23002
EOF
  ) "$trace"
)

[[ "$(declare -f cmd_add | grep -Fc 'check_new_user_conflicts ss2022')" == 1 ]]
[[ "$(declare -f cmd_add_anytls | grep -Fc 'check_new_user_conflicts anytls')" == 1 ]]

# 新协议端点没有冲突时必须显式返回成功；不能把最后一个“不存在同名 tag”的状态 1
# 泄漏给调用者，否则在 set -e 的真实交互入口中会静默退出、永远进不了事务。
(
  trace="$work/new-endpoint-preflight-clear"
  PORT_MIN=20001
  PORT_MAX=30000
  port_in_state() { printf 'state-port %s\n' "$1" >> "$trace"; return 1; }
  port_is_listening() { printf 'listen-port %s\n' "$1" >> "$trace"; return 1; }
  nfuse_port_exists() { printf 'nfuse-port %s\n' "$1" >> "$trace"; return 1; }
  anytls_certificate_ready() { printf 'certificate\n' >> "$trace"; }
  tag_exists_in_config() { printf 'tag %s\n' "$1" >> "$trace"; return 1; }
  check_new_endpoint_conflicts anytls alice 23003
  diff -u <(cat <<'EOF'
state-port 23003
listen-port 23003
nfuse-port 23003
certificate
tag anytls-alice
EOF
  ) "$trace"
)

# 为旧版 ShadowTLS 用户补原生 SS2022 时，旧标签属于同一用户，只有新的独立标签需要查重。
(
  trace="$work/new-endpoint-preflight-legacy"
  STATE_FILE="$work/state-three-remove-direct.json"
  PORT_MIN=20001
  PORT_MAX=30000
  port_in_state() { printf 'state-port %s\n' "$1" >> "$trace"; return 1; }
  port_is_listening() { printf 'listen-port %s\n' "$1" >> "$trace"; return 1; }
  nfuse_port_exists() { printf 'nfuse-port %s\n' "$1" >> "$trace"; return 1; }
  tag_exists_in_config() { printf 'tag %s\n' "$1" >> "$trace"; return 1; }
  check_new_endpoint_conflicts ss2022-direct triple 23102
  diff -u <(cat <<'EOF'
state-port 23102
listen-port 23102
nfuse-port 23102
tag ss-direct-triple
EOF
  ) "$trace"
)

preflight_body="$(declare -f check_new_user_conflicts)"
for message in \
  '端口已被脚本记录占用：$port' \
  '端口已占用' \
  '端口已被其他服务监听：$port' \
  '端口已被监听' \
  '同名流量记录已存在，请运行「服务与配置检查」：$name' \
  '同名流量记录已存在，请运行「服务与配置检查」' \
  'Nfuse 已管理端口：$port' \
  '该端口已被其他用户的流量统计占用'; do
  grep -Fq "$message" <<<"$preflight_body"
done
if unknown_protocol_output="$(check_new_user_conflicts unknown alice 23001 2>&1)"; then
  echo 'unknown user protocol must be rejected before conflict checks' >&2
  exit 1
fi
grep -Fq '内部错误：不支持的新增用户协议：unknown' <<<"$unknown_protocol_output"

# 新增用户冲突检查只格式化一次配置，按候选顺序报告冲突，并让最终写入复用同一快照。
(
  SINGBOX_CONFIG="$work/new-user-single-pass-config.json"
  SINGBOX_BIN=counting_new_user_singbox
  format_calls="$work/new-user-single-pass-format.calls"
  base_config="$work/new-user-single-pass-base.json"
  expected_config="$work/new-user-single-pass-expected.json"
  fragment='[{"type":"shadowsocks","tag":"ss-fresh","listen":"::","listen_port":23001,"method":"2022-blake3-aes-128-gcm","password":"fixture"}]'
  printf '%s\n' '{"inbounds":[{"type":"mixed","tag":"existing","listen_port":1080}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[],"rule_set":[]}}' > "$base_config"
  cp "$base_config" "$SINGBOX_CONFIG"
  : > "$format_calls"
  counting_new_user_singbox() {
    [[ "${1:-}" == format && "${2:-}" == -c ]] || return 1
    printf 'format\n' >> "$format_calls"
    command jq . "$3"
  }
  user_exists() { return 1; }
  port_in_state() { return 1; }
  port_is_listening() { return 1; }
  nfuse_account_exists() { return 1; }
  nfuse_port_exists() { return 1; }
  anytls_certificate_ready() { return 0; }

  # 旧通用重写助手作为黄金基准；新路径必须生成逐字节相同的配置。
  SB_JQ_NEW_INBOUNDS="$fragment" rewrite_kernel_config \
    '($ENV.SB_JQ_NEW_INBOUNDS | fromjson) as $new_inbounds |
     .inbounds = ((.inbounds // []) + $new_inbounds)'
  cp "$SINGBOX_CONFIG" "$expected_config"

  cp "$base_config" "$SINGBOX_CONFIG"
  : > "$format_calls"
  config_snapshot="" config_source=""
  check_new_user_conflicts ss2022 fresh 23001 config_snapshot config_source
  [[ "$(wc -l < "$format_calls" | tr -d ' ')" == 1 ]]
  append_inbounds_from_new_user_snapshot "$config_snapshot" "$config_source" "$fragment"
  [[ "$(wc -l < "$format_calls" | tr -d ' ')" == 1 ]]
  cmp -s "$expected_config" "$SINGBOX_CONFIG"

  # 双协议的第二次冲突检查复用同一快照，不应再次 format。
  cp "$base_config" "$SINGBOX_CONFIG"
  : > "$format_calls"
  config_snapshot="" config_source=""
  check_new_user_conflicts ss2022 multi 23002 config_snapshot config_source
  check_new_user_conflicts anytls multi 23003 config_snapshot config_source
  [[ "$(wc -l < "$format_calls" | tr -d ' ')" == 1 ]]

  # 配置顺序不能改变候选 tag 的既有优先级。
  printf '%s\n' '{"inbounds":[{"tag":"ss-conflict"},{"tag":"st-conflict"}],"outbounds":[],"route":{"rules":[],"rule_set":[]}}' > "$SINGBOX_CONFIG"
  config_snapshot="" config_source=""
  if conflict_output="$(check_new_user_conflicts ss2022 conflict 23004 config_snapshot config_source 2>&1)"; then
    echo 'new user conflict check should reject an existing candidate tag' >&2
    exit 1
  fi
  grep -Fq 'sing-box 已存在 tag：st-conflict' <<<"$conflict_output"

  printf '%s\n' '{"inbounds":[{"tag":"anytls-conflict"}],"outbounds":[],"route":{"rules":[],"rule_set":[]}}' > "$SINGBOX_CONFIG"
  config_snapshot="" config_source=""
  if anytls_conflict_output="$(check_new_user_conflicts anytls conflict 23004 config_snapshot config_source 2>&1)"; then
    echo 'AnyTLS user conflict check should reject an existing candidate tag' >&2
    exit 1
  fi
  grep -Fq '错误：tag 已存在' <<<"$anytls_conflict_output"

  # 预检后配置发生变化时不得用旧快照覆盖新内容。
  cp "$base_config" "$SINGBOX_CONFIG"
  config_snapshot="" config_source=""
  check_new_user_conflicts ss2022 stale 23005 config_snapshot config_source
  printf '%s\n' '{"inbounds":[{"tag":"changed-after-preflight"}],"outbounds":[],"route":{"rules":[],"rule_set":[]}}' > "$SINGBOX_CONFIG"
  if append_inbounds_from_new_user_snapshot "$config_snapshot" "$config_source" "$fragment" >"$work/new-user-stale.out" 2>&1; then
    echo 'stale new user config snapshot should be rejected before write' >&2
    exit 1
  fi
  grep -Fq '配置在新增用户预检后发生变化' "$work/new-user-stale.out"
  grep -Fq changed-after-preflight "$SINGBOX_CONFIG"

  # 指纹必须包含尾部换行；只改变换行字节也不能被旧快照覆盖。
  cp "$base_config" "$SINGBOX_CONFIG"
  config_snapshot="" config_source=""
  check_new_user_conflicts ss2022 trailing-newline 23006 config_snapshot config_source
  printf '\n' >> "$SINGBOX_CONFIG"
  cp "$SINGBOX_CONFIG" "$work/new-user-trailing-newline.expected"
  if append_inbounds_from_new_user_snapshot "$config_snapshot" "$config_source" "$fragment" >"$work/new-user-trailing-newline.out" 2>&1; then
    echo 'trailing-newline-only config changes must invalidate the snapshot' >&2
    exit 1
  fi
  grep -Fq '配置在新增用户预检后发生变化' "$work/new-user-trailing-newline.out"
  cmp -s "$work/new-user-trailing-newline.expected" "$SINGBOX_CONFIG"

  # 临时配置已经生成后若原文件再变化，最终原子替换前的第二次核验必须拦截。
  cp "$base_config" "$SINGBOX_CONFIG"
  config_snapshot="" config_source=""
  check_new_user_conflicts ss2022 changed-during-write 23007 config_snapshot config_source
  cp "$base_config" "$work/new-user-change-during-write.expected"
  printf '\n' >> "$work/new-user-change-during-write.expected"
  jq() {
    command jq "$@"
    local rc=$?
    printf '\n' >> "$SINGBOX_CONFIG"
    return "$rc"
  }
  if append_inbounds_from_new_user_snapshot "$config_snapshot" "$config_source" "$fragment" >"$work/new-user-change-during-write.out" 2>&1; then
    echo 'config changes during snapshot write must be rejected before replacement' >&2
    exit 1
  fi
  unset -f jq
  grep -Fq '配置在新增用户预检后发生变化' "$work/new-user-change-during-write.out"
  cmp -s "$work/new-user-change-during-write.expected" "$SINGBOX_CONFIG"

  # format 失败必须在事务前失败关闭，并报出出错的配置文件。
  # 文案自 2c 起不再写死 sing-box：同一条路径在 mihomo 部署上指向的是
  # mihomo 的配置，说成 sing-box 会把人引到错误的文件上去。
  counting_new_user_singbox() { return 77; }
  config_snapshot="" config_source=""
  if format_failure_output="$(check_new_user_conflicts ss2022 broken 23008 config_snapshot config_source 2>&1)"; then
    echo 'new user preflight should fail closed when sing-box format fails' >&2
    exit 1
  fi
  grep -Fq "无法解析或格式化运行配置：$SINGBOX_CONFIG" <<<"$format_failure_output"
)

# 用户状态变化只有在存在专属分流时才重建配置；失败继续返回给既有事务回滚路径。
(
  STATE_FILE="$work/user-split-rebuild-none.json"
  calls="$work/user-split-rebuild-none.calls"
  printf '%s\n' '{"splits":[{"name":"global","scope":"all","user":null}]}' > "$STATE_FILE"
  run_managed_step() { printf '%s\n' "$*" >> "$calls"; }
  rebuild_user_splits_if_needed alice
  [[ ! -e "$calls" ]]
)
(
  STATE_FILE="$work/user-split-rebuild-linked.json"
  calls="$work/user-split-rebuild-linked.calls"
  printf '%s\n' '{"splits":[{"name":"alice-ai","scope":"user","user":"alice"},{"name":"bob-ai","scope":"user","user":"bob"}]}' > "$STATE_FILE"
  run_managed_step() { printf '%s\n' "$*" >> "$calls"; }
  rebuild_user_splits_if_needed alice
  [[ "$(wc -l < "$calls" | tr -d ' ')" == 1 ]]
  grep -Fxq 'rebuild_all_split_configs' "$calls"
)
(
  STATE_FILE="$work/user-split-rebuild-failure.json"
  printf '%s\n' '{"splits":[{"name":"alice-ai","scope":"user","user":"alice"}]}' > "$STATE_FILE"
  run_managed_step() { return 77; }
  if rebuild_user_splits_if_needed alice; then
    echo 'linked user split rebuild failure must be propagated' >&2
    exit 1
  fi
)
[[ "$(declare -f cmd_disable | grep -Fc 'rebuild_user_splits_if_needed "$name"')" == 1 ]]
[[ "$(declare -f cmd_enable | grep -Fc 'run_managed_step enable_user_without_transaction "$name"')" == 1 ]]
[[ "$(declare -f enable_user_without_transaction | grep -Fc 'rebuild_user_splits_if_needed_without_transaction "$name"')" == 1 ]]
[[ "$(declare -f cmd_expire | grep -Fc 'rebuild_user_splits_if_needed "$name"')" == 1 ]]

# 所有分流变更共用“重建、检查并重启、提交”收尾顺序，并在任一步失败后停止。
(
  trace="$work/split-operation-finish-success"
  run_managed_step() { printf 'step:%s\n' "$1" >> "$trace"; }
  finish_managed_operation() { printf 'finish\n' >> "$trace"; }
  rebuild_and_finish_split_operation
  diff -u <(cat <<'EOF'
step:rebuild_all_split_configs
step:check_singbox_and_restart
finish
EOF
  ) "$trace"
)
(
  trace="$work/split-operation-finish-rebuild-failure"
  run_managed_step() { printf 'step:%s\n' "$1" >> "$trace"; [[ "$1" != rebuild_all_split_configs ]]; }
  finish_managed_operation() { printf 'unexpected-finish\n' >> "$trace"; }
  if rebuild_and_finish_split_operation; then
    echo 'split operation must stop when config rebuild fails' >&2
    exit 1
  fi
  grep -Fxq 'step:rebuild_all_split_configs' "$trace"
  [[ "$(wc -l < "$trace" | tr -d ' ')" == 1 ]]
)
(
  trace="$work/split-operation-finish-restart-failure"
  run_managed_step() { printf 'step:%s\n' "$1" >> "$trace"; [[ "$1" != check_singbox_and_restart ]]; }
  finish_managed_operation() { printf 'unexpected-finish\n' >> "$trace"; }
  if rebuild_and_finish_split_operation; then
    echo 'split operation must stop when sing-box check or restart fails' >&2
    exit 1
  fi
  diff -u <(cat <<'EOF'
step:rebuild_all_split_configs
step:check_singbox_and_restart
EOF
  ) "$trace"
)
(
  trace="$work/split-operation-finish-commit-failure"
  run_managed_step() { printf 'step:%s\n' "$1" >> "$trace"; }
  finish_managed_operation() { printf 'finish\n' >> "$trace"; return 77; }
  if rebuild_and_finish_split_operation; then
    echo 'split operation must propagate transaction commit failure' >&2
    exit 1
  fi
  [[ "$(tail -n 1 "$trace")" == finish ]]
)
for split_operation in \
  migrate_shared_preset_runtime_configs \
  cmd_outbound_preset_edit cmd_rule_preset_edit \
  cmd_split_add cmd_split_disable cmd_split_enable cmd_split_remove cmd_split_edit cmd_split_move; do
  split_operation_body="$(declare -f "$split_operation")"
  [[ "$(grep -Fc 'rebuild_and_finish_split_operation' <<<"$split_operation_body")" == 1 ]]
  if grep -Fq 'run_managed_step rebuild_all_split_configs' <<<"$split_operation_body"; then
    echo 'unexpected run_managed_step rebuild_all_split_configs in $split_operation_body' >&2
    exit 1
  fi
  if grep -Fq 'run_managed_step check_singbox_and_restart' <<<"$split_operation_body"; then
    echo 'unexpected run_managed_step check_singbox_and_restart in $split_operation_body' >&2
    exit 1
  fi
  if grep -Fq 'finish_managed_operation' <<<"$split_operation_body"; then
    echo 'unexpected finish_managed_operation in $split_operation_body' >&2
    exit 1
  fi
done

# 交互输入的编号必须先按十进制归一，否则 03 会带着前导零传给下游 jq。
(
  moved="$work/split-move-target"
  STATE_FILE="$work/split-move-state.json"
  printf '%s\n' '{"splits":[{"name":"a"},{"name":"b"},{"name":"c"}]}' > "$STATE_FILE"
  prepare_core() { :; }
  prompt_select_split() { SELECTED_SPLIT_NAME=a; }
  cmd_split_move() { printf '%s\n' "$2" > "$moved"; }
  prompt_move_split <<<$'03\ny' >/dev/null
  [[ "$(<"$moved")" == 3 ]]
)

# 迁移预览与真实恢复共用同一条解密、升级、校验和恢复计划准备链。
(
  trace="$work/migration-payload-preparation-success"
  source_payload="$work/migration-preparation-source.json"
  payload="$work/migration-preparation-effective.json"
  decrypt_migration_backup() { printf 'decrypt:%s\n' "$1" >> "$trace"; printf '{}\n' > "$2"; }
  normalize_migration_payload_schema() { printf 'normalize:%s\n' "$1" >> "$trace"; }
  validate_migration_payload_structure() { printf 'validate:%s\n' "$1" >> "$trace"; }
  prepare_migration_effective_payload() { printf 'prepare:%s:%s\n' "$1" "$2" >> "$trace"; printf '{}\n' > "$2"; }
  prepare_migration_payload_files bundle.sbm "$source_payload" "$payload"
  diff -u <(cat <<EOF
decrypt:bundle.sbm
normalize:$source_payload
validate:$source_payload
prepare:$source_payload:$payload
EOF
  ) "$trace"
)
(
  source_payload="$work/migration-preparation-cancel-source.json"
  payload="$work/migration-preparation-cancel-effective.json"
  : > "$source_payload"; : > "$payload"
  MENU_RETURNED=false
  decrypt_migration_backup() { return 1; }
  normalize_migration_payload_schema() { echo unexpected >&2; return 91; }
  if prepare_migration_payload_files bundle.sbm "$source_payload" "$payload"; then
    echo 'cancelled migration decryption must stop payload preparation' >&2
    exit 1
  fi
  [[ "$MENU_RETURNED" == true && ! -e "$source_payload" && ! -e "$payload" ]]
)
(
  source_payload="$work/migration-preparation-schema-source.json"
  payload="$work/migration-preparation-schema-effective.json"
  error="$work/migration-preparation-schema-error"
  : > "$source_payload"; : > "$payload"
  decrypt_migration_backup() { :; }
  normalize_migration_payload_schema() { return 1; }
  validate_migration_payload_structure() { echo unexpected >&2; return 91; }
  if (prepare_migration_payload_files bundle.sbm "$source_payload" "$payload") >"$error" 2>&1; then
    echo 'migration schema upgrade failure must stop payload preparation' >&2
    exit 1
  fi
  grep -Fxq '错误：迁移包中的旧数据无法安全升级' "$error"
  [[ ! -e "$source_payload" && ! -e "$payload" ]]
)
(
  source_payload="$work/migration-preparation-invalid-source.json"
  payload="$work/migration-preparation-invalid-effective.json"
  error="$work/migration-preparation-invalid-error"
  : > "$source_payload"; : > "$payload"
  decrypt_migration_backup() { :; }
  normalize_migration_payload_schema() { :; }
  validate_migration_payload_structure() { return 1; }
  prepare_migration_effective_payload() { echo unexpected >&2; return 91; }
  if (prepare_migration_payload_files bundle.sbm "$source_payload" "$payload") >"$error" 2>&1; then
    echo 'invalid migration structure must stop payload preparation' >&2
    exit 1
  fi
  grep -Fxq '错误：迁移数据结构无效' "$error"
  [[ ! -e "$source_payload" && ! -e "$payload" ]]
)
(
  source_payload="$work/migration-preparation-plan-source.json"
  payload="$work/migration-preparation-plan-effective.json"
  : > "$source_payload"; : > "$payload"
  decrypt_migration_backup() { :; }
  normalize_migration_payload_schema() { :; }
  validate_migration_payload_structure() { :; }
  prepare_migration_effective_payload() { return 1; }
  if prepare_migration_payload_files bundle.sbm "$source_payload" "$payload"; then
    echo 'cancelled migration plan must stop payload preparation' >&2
    exit 1
  fi
  [[ ! -e "$source_payload" && ! -e "$payload" ]]
)
for migration_entry in preview_migration_backup restore_migration_backup; do
  migration_entry_body="$(declare -f "$migration_entry")"
  [[ "$(grep -Fc 'prepare_migration_payload_files "$SELECTED_MIGRATION_BACKUP" "$source_payload" "$payload"' <<<"$migration_entry_body")" == 1 ]]
  if grep -Fq 'decrypt_migration_backup "$SELECTED_MIGRATION_BACKUP"' <<<"$migration_entry_body"; then
    echo 'unexpected decrypt_migration_backup "$SELECTED_MIGRATION_BACKUP" in $migration_entry_body' >&2
    exit 1
  fi
  if grep -Fq 'normalize_migration_payload_schema "$source_payload"' <<<"$migration_entry_body"; then
    echo 'unexpected normalize_migration_payload_schema "$source_payload" in $migration_entry_body' >&2
    exit 1
  fi
  if grep -Fq 'validate_migration_payload_structure "$source_payload"' <<<"$migration_entry_body"; then
    echo 'unexpected validate_migration_payload_structure "$source_payload" in $migration_entry_body' >&2
    exit 1
  fi
  if grep -Fq 'prepare_migration_effective_payload "$source_payload"' <<<"$migration_entry_body"; then
    echo 'unexpected prepare_migration_effective_payload "$source_payload" in $migration_entry_body' >&2
    exit 1
  fi
done

# 只有当前 SSH 的回连套接字确实归 sing-box 所有时才阻止重启；普通直连和无法判断的连接保持可用。
(
  unset SSH_CONNECTION
  if ssh_connection_uses_local_kernel; then
    echo 'non-SSH sessions must not be classified as local sing-box connections' >&2
    exit 1
  fi
)
(
  export SSH_CONNECTION='203.0.113.9 54321 192.0.2.10 22'
  list_kernel_owned_ssh_sockets() { printf '%s\n' 'ESTAB 0 0 192.0.2.10:54321 192.0.2.10:22 users:(("ssh",pid=10,fd=3))'; }
  if ssh_connection_uses_local_kernel; then
    echo 'ordinary direct SSH must not be blocked' >&2
    exit 1
  fi
)
(
  socket_probe="$work/ssh-loop-socket-probe"
  export SSH_CONNECTION='192.0.2.10 54321 192.0.2.10 22'
  list_kernel_owned_ssh_sockets() {
    printf '%s %s\n' "$1" "$2" > "$socket_probe"
    printf '%s\n' 'ESTAB 0 0 192.0.2.10:54321 192.0.2.10:22 users:(("sing-box",pid=20,fd=9))'
  }
  ssh_connection_uses_local_kernel
  grep -Fxq '54321 22' "$socket_probe"
  warning="$(ensure_safe_ssh_for_kernel_restart 2>&1 || true)"
  grep -Fq '当前 SSH 连接正通过这台服务器自己的 sing-box 节点' <<<"$warning"
  grep -Fq '服务器数据尚未修改' <<<"$warning"
)
(
  export SSH_CONNECTION='2001:db8::10 60000 2001:db8::20 2222'
  list_kernel_owned_ssh_sockets() { printf '%s\n' 'ESTAB 0 0 [2001:db8::20]:60000 [2001:db8::20]:2222 users:(("sing-box",pid=20,fd=9))'; }
  ssh_connection_uses_local_kernel
)
(
  export SSH_CONNECTION='malformed connection data'
  list_kernel_owned_ssh_sockets() { echo 'socket lookup must not run for malformed SSH_CONNECTION' >&2; return 90; }
  if ssh_connection_uses_local_kernel; then
    echo 'malformed SSH_CONNECTION must fail open' >&2
    exit 1
  fi
)
(
  later_marker="$work/ssh-loop-add-menu-later"
  ensure_safe_ssh_for_kernel_restart() { printf '%s\n' blocked; return 1; }
  load_runtime_config() { printf '%s\n' unexpected > "$later_marker"; }
  add_menu_output="$(prompt_add_node)"
  grep -Fxq blocked <<<"$add_menu_output"
  [[ ! -e "$later_marker" ]]
)

[[ "$(ui_text_width '1  添加用户')" == 11 ]]
[[ "$(ui_text_width '9  导出用户配置')" == 15 ]]
ui_menu_begin
wide_menu="$(NO_COLOR=1 COLUMNS=100 ui_menu_items add '添加用户' list '查看用户')"
[[ "$(wc -l <<<"$wide_menu" | tr -d ' ')" == 1 ]]
grep -Eq '^  1  添加用户 +2  查看用户$' <<<"$wide_menu"
ui_menu_begin
narrow_menu="$(NO_COLOR=1 COLUMNS=60 ui_menu_items add '添加用户' list '查看用户')"
[[ "$(wc -l <<<"$narrow_menu" | tr -d ' ')" == 2 ]]
grep -Fxq '  1  添加用户' <<<"$narrow_menu"
grep -Fxq '  2  查看用户' <<<"$narrow_menu"

ui_menu_begin
ui_menu_items first '第一项' second '第二项' >/dev/null
ui_menu_items third '第三项' >/dev/null
[[ "$UI_MENU_COUNT" == 3 ]]
ui_menu_select <<<'2'
[[ "$UI_MENU_ACTION" == second ]]

# 三个职责板块按主菜单显示顺序自动编号；各板块内部进入后重新从 1 编号。
ui_menu_begin
main_menu="$(NO_COLOR=1 COLUMNS=60 ui_menu_items users '用户管理' splits '分流管理' system '系统管理')"
ui_menu_begin
user_menu="$(NO_COLOR=1 COLUMNS=60 ui_menu_items add '添加用户' list '查看用户')"
ui_menu_begin
split_menu="$(NO_COLOR=1 COLUMNS=60 ui_menu_items list '查看分流' add '增加分流')"
ui_menu_begin
system_menu="$(NO_COLOR=1 COLUMNS=60 ui_menu_items deploy '部署与卸载' update '检测更新')"
ui_menu_begin
deployment_menu="$(NO_COLOR=1 COLUMNS=60 ui_menu_items install '安装或修复环境' uninstall '完整卸载')"
grep -Fxq '  1  用户管理' <<<"$main_menu"
grep -Fxq '  2  分流管理' <<<"$main_menu"
grep -Fxq '  3  系统管理' <<<"$main_menu"
grep -Fxq '  1  添加用户' <<<"$user_menu"
grep -Fxq '  1  查看分流' <<<"$split_menu"
grep -Fxq '  1  部署与卸载' <<<"$system_menu"
grep -Fxq '  1  安装或修复环境' <<<"$deployment_menu"
grep -Fxq '  2  完整卸载' <<<"$deployment_menu"

config_probe() {
  local config="$1"
  SB_USER_CONF="$config" SB_USER_MANAGER_LIBRARY=true bash -c '
    set -Eeuo pipefail
    source ./sb-user-manager.sh
    load_runtime_config
  '
}

secure_config="$work/secure-manager.conf"
printf '%s\n' \
  '# ordinary comments are allowed' \
  'HANDSHAKE_PORT=443' \
  'SHADOWTLS_STRICT_MODE=true' \
  'SS2022_SHADOWTLS_SNI="publicassets.cdn-apple.com"' \
  'ANYTLS_SNI="weKbP9SVYU.download.windowsupdate.com"' \
  'PUBLIC_SERVER_OVERRIDE="43.132.173.34"' > "$secure_config"
chmod 600 "$secure_config"
config_probe "$secure_config"

legacy_token_config="$work/legacy-token-manager.conf"
printf '%s\n' 'HANDSHAKE_PORT=443' 'GITHUB_TOKEN="legacy-token-must-be-discarded"' > "$legacy_token_config"
chmod 600 "$legacy_token_config"
SB_USER_CONF="$legacy_token_config" SB_USER_MANAGER_LIBRARY=true \
  GITHUB_TOKEN=environment-token-must-be-discarded SB_GITHUB_TOKEN=legacy-environment-token \
  bash -c '
    set -Eeuo pipefail
    source ./sb-user-manager.sh
    load_runtime_config
    [[ -z "${GITHUB_TOKEN+x}" && -z "${SB_GITHUB_TOKEN+x}" ]]
  '

insecure_config="$work/insecure-manager.conf"
printf '%s\n' 'HANDSHAKE_PORT=443' > "$insecure_config"
chmod 644 "$insecure_config"
if config_probe "$insecure_config" >/dev/null 2>&1; then
  echo 'group-readable runtime config should be rejected before loading' >&2
  exit 1
fi

symlink_config="$work/symlink-manager.conf"
ln -s "$secure_config" "$symlink_config"
if config_probe "$symlink_config" >/dev/null 2>&1; then
  echo 'symlink runtime config should be rejected before loading' >&2
  exit 1
fi

unknown_config="$work/unknown-manager.conf"
printf '%s\n' 'HANDSHAKE_PORT=443' 'UNEXPECTED_SETTING="value"' > "$unknown_config"
chmod 600 "$unknown_config"
if config_probe "$unknown_config" >/dev/null 2>&1; then
  echo 'unknown runtime config setting should be rejected' >&2
  exit 1
fi

duplicate_config="$work/duplicate-manager.conf"
printf '%s\n' 'HANDSHAKE_PORT=443' 'HANDSHAKE_PORT=8443' > "$duplicate_config"
chmod 600 "$duplicate_config"
if config_probe "$duplicate_config" >/dev/null 2>&1; then
  echo 'duplicate runtime config setting should be rejected' >&2
  exit 1
fi

command_marker="$work/runtime-config-command-ran"
command_config="$work/command-manager.conf"
printf 'GITHUB_TOKEN="$(touch %s)"\n' "$command_marker" > "$command_config"
chmod 600 "$command_config"
if config_probe "$command_config" >/dev/null 2>&1; then
  echo 'shell command syntax in runtime config should be rejected' >&2
  exit 1
fi
[[ ! -e "$command_marker" ]]

owner_config="$work/owner-manager.conf"
printf '%s\n' 'HANDSHAKE_PORT=443' > "$owner_config"
chmod 600 "$owner_config"
if SB_USER_CONF="$owner_config" SB_USER_MANAGER_LIBRARY=true bash -c '
  set -Eeuo pipefail
  source ./sb-user-manager.sh
  manager_file_uid() { printf "%s\n" 4294967294; }
  load_runtime_config
' >/dev/null 2>&1; then
  echo 'runtime config owned by another account should be rejected' >&2
  exit 1
fi

password_retry_output="$work/password-retry-output"
BACKUP_PASSWORD=""
read_backup_password_twice <<<$'short\nabcdefgh\nnotmatch\nabcdefgh\nabcdefgh' >"$password_retry_output"
[[ "$BACKUP_PASSWORD" == abcdefgh ]]
grep -Fq '密码至少需要 8 个字符，请重新输入。' "$password_retry_output"
grep -Fq '两次输入的密码不一致，请重新设置。' "$password_retry_output"

BACKUP_PASSWORD="must-clear"
if read_backup_password_twice <<<$'0' >/dev/null; then
  echo 'migration backup password prompt should allow cancellation' >&2
  exit 1
fi
[[ -z "$BACKUP_PASSWORD" ]]

BACKUP_PASSWORD="must-clear"
if read_backup_password_twice <<<$'abcdefgh\n0' >/dev/null; then
  echo 'migration backup password confirmation should allow cancellation' >&2
  exit 1
fi
[[ -z "$BACKUP_PASSWORD" ]]

choice_retry_output="$work/choice-retry-output"
read_menu_choice '请选择：' '0,1,2' 1 '请输入 0、1 或 2' <<<$'wrong\n2' >"$choice_retry_output"
[[ "$PROMPT_VALUE" == 2 ]]
grep -Fq '输入无效：请输入 0、1 或 2，请重新输入。' "$choice_retry_output"

number_retry_output="$work/number-retry-output"
read_numbered_index '请选择编号：' 3 <<<$'word\n9\n2' >"$number_retry_output"
[[ "$SELECTED_INDEX" == 1 ]]
grep -Fq '输入无效：请输入列表前面的数字编号。' "$number_retry_output"
grep -Fq '输入无效：该编号不在当前列表中，请重新选择。' "$number_retry_output"

if read_numbered_index '请选择编号：' 3 </dev/null >/dev/null; then
  echo 'numbered prompt should return when its input stream closes' >&2
  exit 1
fi

# 带前导零的编号必须按十进制解析：08 不能让算术展开中断调用栈，010 也不能选中第 8 项。
SELECTED_INDEX=''
read_numbered_index '请选择编号：' 12 <<<'08' >/dev/null
[[ "$SELECTED_INDEX" == 7 ]]
SELECTED_INDEX=''
read_numbered_index '请选择编号：' 12 <<<'010' >/dev/null
[[ "$SELECTED_INDEX" == 9 ]]
SELECTED_INDEX=''
if read_numbered_index '请选择编号：' 12 <<<'00' >/dev/null; then
  echo 'numbered prompt should treat 00 as the return choice' >&2
  exit 1
fi

stderr_probe="$work/stderr-probe"
{
  release_operation_lock
  printf 'stderr-preserved\n' >&2
} 2>"$stderr_probe"
grep -Fxq 'stderr-preserved' "$stderr_probe"

# 轻量操作锁必须能在全新环境创建父目录，并在释放后关闭 fd 9。
(
  LOCK_FILE="$work/fresh-operation-lock/run/lock/sb-user-manager.lock"
  operation_flock_calls=0
  flock() {
    [[ "${1:-}" == -u ]] || operation_flock_calls=$((operation_flock_calls + 1))
    return 0
  }
  acquire_operation_lock
  acquire_operation_lock
  [[ "$operation_flock_calls" == 1 && "$OPERATION_LOCK_HELD" == true ]]
  [[ -f "$LOCK_FILE" && ! -L "$LOCK_FILE" ]]
  release_operation_lock
  if { printf x >&9; } 2>/dev/null; then
    echo 'operation lock descriptor should be closed after release' >&2
    exit 1
  fi
)

# 锁目录或锁文件是符号链接时必须失败，不能跟随到非受管位置。
(
  lock_root="$work/unsafe-operation-lock"
  mkdir -p "$lock_root/real"
  ln -s "$lock_root/real" "$lock_root/link"
  LOCK_FILE="$lock_root/link/manager.lock"
  if acquire_operation_lock >/dev/null 2>&1; then
    echo 'symlink operation lock directory should be rejected' >&2
    exit 1
  fi
  [[ ! -e "$lock_root/real/manager.lock" ]]
  rm -f -- "$lock_root/link"
  : > "$lock_root/target"
  ln -s "$lock_root/target" "$lock_root/manager.lock"
  LOCK_FILE="$lock_root/manager.lock"
  if acquire_operation_lock >/dev/null 2>&1; then
    echo 'symlink operation lock file should be rejected' >&2
    exit 1
  fi
)

# Linux CI 使用真实 flock 证明另一个进程占锁时会明确拒绝且不会遗留 fd 9。
if command -v flock >/dev/null 2>&1; then
  (
    LOCK_FILE="$work/contended-operation.lock"
    exec 7>"$LOCK_FILE"
    command flock -n 7
    if acquire_operation_lock >"$work/contended-operation.out" 2>&1; then
      echo 'contended operation lock should be rejected' >&2
      exit 1
    fi
    [[ "$OPERATION_LOCK_ERROR" == '另一个管理操作正在进行，请等待完成后再试' ]]
    if { printf x >&9; } 2>/dev/null; then
      echo 'failed operation lock acquisition should close fd 9' >&2
      exit 1
    fi
    command flock -u 7
    exec 7>&-
  )
fi

is_managed_temp_path /tmp/sb-runtime-test.example
if is_managed_temp_path /etc/passwd; then
  echo 'unmanaged path should be rejected' >&2
  exit 1
fi

is_public_ipv4 43.132.173.34
for rejected_ip in 10.0.0.8 100.64.0.1 127.0.0.1 169.254.1.1 172.16.0.1 192.168.1.1 198.18.0.1 203.0.113.8 999.1.1.1; do
  if is_public_ipv4 "$rejected_ip"; then
    echo "non-public IPv4 should be rejected: $rejected_ip" >&2
    exit 1
  fi
done

(
  PUBLIC_SERVER_OVERRIDE=""
  ip() { printf '%s\n' '1.1.1.1 via 43.132.173.1 dev eth0 src 43.132.173.34 uid 0'; }
  curl() { echo 'public route should not call an external address service' >&2; return 99; }
  [[ "$(detect_public_server)" == 43.132.173.34 ]]
)

(
  PUBLIC_SERVER_OVERRIDE=""
  ip() { printf '%s\n' '1.1.1.1 via 10.0.0.1 dev eth0 src 10.0.0.8 uid 0'; }
  curl() {
    if [[ "$*" == *api.ipify.org* ]]; then printf 'not-an-ip\n'; else printf '43.132.173.34\n'; fi
  }
  [[ "$(detect_public_server)" == 43.132.173.34 ]]
)

(
  PUBLIC_SERVER_OVERRIDE=43.132.173.35
  ip() { return 99; }
  curl() { return 99; }
  [[ "$(detect_public_server)" == 43.132.173.35 ]]
)

# Debian Bash 在 nounset 下会把空数组长度视为未绑定；首次登记不能依赖 ${#array[@]}。
RUNTIME_TEMP_PATHS=()
RUNTIME_TEMP_PATH_COUNT=0
first_runtime_temp="$(mktemp -d /tmp/sb-runtime-first.XXXXXX)"
register_temp_path "$first_runtime_temp"
[[ "$RUNTIME_TEMP_PATH_COUNT" == 1 ]]
cleanup_runtime_temp_paths
[[ ! -e "$first_runtime_temp" && "$RUNTIME_TEMP_PATH_COUNT" == 0 ]]

# 成功移走的临时路径应立即取消登记；中间项移除后数组和手工计数仍保持紧凑一致。
RUNTIME_TEMP_PATHS=()
RUNTIME_TEMP_PATH_COUNT=0
first_registered_temp="$(mktemp /tmp/sb-runtime-unregister-first.XXXXXX)"
moved_registered_temp="$(mktemp /tmp/sb-runtime-unregister-moved.XXXXXX)"
last_registered_temp="$(mktemp /tmp/sb-runtime-unregister-last.XXXXXX)"
register_temp_path "$first_registered_temp"
register_temp_path "$moved_registered_temp"
register_temp_path "$last_registered_temp"
moved_registered_destination="$work/runtime-unregistered-destination"
mv -- "$moved_registered_temp" "$moved_registered_destination"
unregister_temp_path "$moved_registered_temp"
[[ "$RUNTIME_TEMP_PATH_COUNT" == 2 ]]
[[ "${RUNTIME_TEMP_PATHS[0]}" == "$first_registered_temp" ]]
[[ "${RUNTIME_TEMP_PATHS[1]}" == "$last_registered_temp" ]]
unregister_temp_path "$moved_registered_temp"
[[ "$RUNTIME_TEMP_PATH_COUNT" == 2 ]]
cleanup_runtime_temp_paths
[[ ! -e "$first_registered_temp" && ! -e "$last_registered_temp" ]]
[[ -f "$moved_registered_destination" && "$RUNTIME_TEMP_PATH_COUNT" == 0 ]]

runtime_temp="$(mktemp -d /tmp/sb-runtime-cleanup.XXXXXX)"
RUNTIME_TRAP_PID="${BASHPID:-$$}"
RUNTIME_TRAP_SUBSHELL="$BASH_SUBSHELL"
register_temp_path "$runtime_temp"
cleanup_runtime_temp_paths
[[ ! -e "$runtime_temp" ]]
RUNTIME_TRAP_PID=""
RUNTIME_TRAP_SUBSHELL=""

exit_temp="$(mktemp -d /tmp/sb-runtime-exit.XXXXXX)"
set +e
SIGNAL_TEMP="$exit_temp" SB_USER_MANAGER_LIBRARY=true bash -c '
  set -Eeuo pipefail
  source ./sb-user-manager.sh
  install_runtime_traps
  register_temp_path "$SIGNAL_TEMP"
  exit 7
' >/dev/null 2>&1
exit_rc=$?
set -e
[[ "$exit_rc" == 7 ]]
[[ ! -e "$exit_temp" ]]

signal_temp="$(mktemp -d /tmp/sb-runtime-signal.XXXXXX)"
rollback_marker="$work/signal-rollback"
set +e
SIGNAL_TEMP="$signal_temp" ROLLBACK_MARKER="$rollback_marker" SB_USER_MANAGER_LIBRARY=true bash -c '
  set -Eeuo pipefail
  source ./sb-user-manager.sh
  install_runtime_traps
  rollback_test() {
    printf "%s\n" "$1" > "$ROLLBACK_MARKER"
    return "$1"
  }
  register_temp_path "$SIGNAL_TEMP"
  set_signal_rollback rollback_test
  kill -TERM "$$"
  exit 99
' >/dev/null 2>&1
signal_rc=$?
set -e
[[ "$signal_rc" == 143 ]]
[[ ! -e "$signal_temp" ]]
[[ "$(cat "$rollback_marker")" == 143 ]]

(
  rollback_calls=0
  rollback_rc=0
  rollback_active_operation() {
    rollback_calls=$((rollback_calls + 1))
    rollback_rc="$1"
    return "$1"
  }
  managed_step_success() { return 0; }
  managed_step_failure() { return 67; }

  run_managed_step managed_step_success
  [[ "$rollback_calls" == 0 ]]
  if run_managed_step managed_step_failure; then
    echo 'managed step should propagate the original failure' >&2
    exit 1
  else
    managed_step_rc=$?
  fi
  [[ "$managed_step_rc" == 67 && "$rollback_rc" == 67 && "$rollback_calls" == 1 ]]
)

(
  environment_rollback_calls=0
  environment_rollback_rc=0
  environment_rollback() {
    environment_rollback_calls=$((environment_rollback_calls + 1))
    environment_rollback_rc="$1"
    return "$1"
  }
  environment_step_failure() { return 68; }
  if run_step_or_rollback environment_rollback environment_step_failure; then
    echo 'environment step should propagate failure in a conditional caller' >&2
    exit 1
  else
    environment_step_rc=$?
  fi
  [[ "$environment_step_rc" == 68 && "$environment_rollback_rc" == 68 && "$environment_rollback_calls" == 1 ]]
)

set +e
missing_rollback_output="$(
  (run_step_or_rollback missing_operation_rollback true) 2>&1
)"
missing_rollback_rc=$?
set -e
[[ "$missing_rollback_rc" == 1 ]]
grep -Fq '错误：操作回滚函数不存在：missing_operation_rollback' <<<"$missing_rollback_output"

pause_output="$(printf '\n' | pause_menu)"
grep -Fq '按回车返回菜单…' <<<"$pause_output"
MANAGER_INSTALLED_PATH="$work/installed-manager"
MANAGER_VERSIONS_FILE="$work/versions"
printf '%s\n' '#!/usr/bin/env bash' 'SCRIPT_VERSION="4.6.2"' > "$MANAGER_INSTALLED_PATH"
printf '%s\n' 'SCRIPT_VERSION=4.6.0' > "$MANAGER_VERSIONS_FILE"
[[ "$(installed_manager_version)" == 4.6.2 ]]
rm -f "$MANAGER_INSTALLED_PATH"
[[ "$(installed_manager_version)" == 4.6.0 ]]
unset MANAGER_INSTALLED_PATH MANAGER_VERSIONS_FILE

old_launch_path="$work/old-launch.sh"
new_manager_path="$work/new-manager.sh"
printf '%s\n' '#!/usr/bin/env bash' 'SCRIPT_VERSION="1.0.0"' > "$old_launch_path"
printf '%s\n' '#!/usr/bin/env bash' 'SCRIPT_VERSION="9.9.9"' 'printf "HANDOFF:%s\n" "$*"' > "$new_manager_path"
chmod 700 "$old_launch_path" "$new_manager_path"
handoff_output="$(
  OLD_LAUNCH_PATH="$old_launch_path" NEW_MANAGER_PATH="$new_manager_path" \
    SB_USER_MANAGER_LIBRARY=true bash -c '
      set -Eeuo pipefail
      source ./sb-user-manager.sh
      SELF_PATH="$OLD_LAUNCH_PATH"
      MANAGER_INSTALLED_PATH="$NEW_MANAGER_PATH"
      handoff_to_newer_installed_manager --internal-expire
    '
)"
grep -Fq '高于当前启动副本' <<<"$handoff_output"
grep -Fq 'HANDOFF:--internal-expire' <<<"$handoff_output"
saved_self_path="$SELF_PATH"
SELF_PATH="$old_launch_path"
MANAGER_ROOT_LAUNCH_COPY="$work/missing-root-launch.sh"
sync_manager_launch_copy "$new_manager_path" >/dev/null
cmp -s "$old_launch_path" "$new_manager_path"

root_launch_path="$work/root-launch.sh"
printf '%s\n' '#!/usr/bin/env bash' 'SCRIPT_VERSION="1.0.0"' > "$root_launch_path"
chmod 700 "$root_launch_path"
SELF_PATH="$new_manager_path"
MANAGER_ROOT_LAUNCH_COPY="$root_launch_path"
sync_manager_launch_copy "$new_manager_path" >/dev/null
cmp -s "$root_launch_path" "$new_manager_path"

printf '%s\n' '#!/usr/bin/env bash' 'SCRIPT_VERSION="1.0.0"' > "$root_launch_path"
MANAGER_INSTALLED_PATH="$new_manager_path"
ensure_manager_launch_copies_for_interactive_startup >/dev/null
cmp -s "$root_launch_path" "$new_manager_path"
unset MANAGER_INSTALLED_PATH

unrelated_launch_path="$work/unrelated-launch.sh"
root_launch_link="$work/root-launch-link.sh"
printf '%s\n' 'do not replace' > "$unrelated_launch_path"
ln -s "$unrelated_launch_path" "$root_launch_link"
MANAGER_ROOT_LAUNCH_COPY="$root_launch_link"
sync_manager_launch_copy "$new_manager_path" >/dev/null
[[ -L "$root_launch_link" ]]
grep -Fxq 'do not replace' "$unrelated_launch_path"
unset MANAGER_ROOT_LAUNCH_COPY
SELF_PATH="$saved_self_path"

deploy_state_root="$work/deploy-state"
deploy_conf="$deploy_state_root/sb-user-manager.conf"
deploy_state="$deploy_state_root/etc/sing-box/managed-users.json"
deploy_backups="$deploy_state_root/etc/sing-box/backups"
mkdir -p "$deploy_state_root"
printf '%s\n' \
  "SINGBOX_CONFIG=\"$deploy_state_root/etc/sing-box/config.json\"" \
  "STATE_FILE=\"$deploy_state\"" \
  "BACKUP_DIR=\"$deploy_backups\"" \
  "LOCK_FILE=\"$deploy_state_root/manager.lock\"" > "$deploy_conf"
SB_USER_CONF="$deploy_conf" EXPECTED_STATE="$deploy_state" SB_USER_MANAGER_LIBRARY=true bash -c '
  set -Eeuo pipefail
  source ./sb-user-manager.sh
  initialize_deployed_state
  [[ -f "$EXPECTED_STATE" ]]
  jq -e '\''
    .schema_version == 7 and
    .users == [] and
    .splits == [] and
    .outbound_presets == [] and
    .rule_presets == []
  '\'' "$EXPECTED_STATE" >/dev/null
  mode="$(stat -c '\''%a'\'' "$EXPECTED_STATE" 2>/dev/null || stat -f '\''%Lp'\'' "$EXPECTED_STATE")"
  [[ "$mode" == 600 ]]
'
[[ -d "$deploy_backups" ]]
[[ "$(SB_USER_CONF="$deploy_conf" SB_USER_MANAGER_LIBRARY=true bash -c 'source ./sb-user-manager.sh; deployed_state_path')" == "$deploy_state" ]]

printf '%s\n' '{"schema_version":3,"users":[{"name":"stale"}],"splits":[{"name":"stale"}]}' > "$deploy_state"
SB_USER_CONF="$deploy_conf" SB_USER_MANAGER_LIBRARY=true bash -c '
  set -Eeuo pipefail
  source ./sb-user-manager.sh
  initialize_deployed_state true
'
jq -e '.schema_version == 7 and .users == [] and .splits == [] and .outbound_presets == [] and .rule_presets == []' "$deploy_state" >/dev/null

printf '%s\n' '{"schema_version":999,"users":[],"splits":[]}' > "$deploy_state"
deploy_rollback_marker="$deploy_state_root/rollback-marker"
set +e
SB_USER_CONF="$deploy_conf" ROLLBACK_MARKER="$deploy_rollback_marker" \
  SB_USER_MANAGER_LIBRARY=true bash -c '
    set -Eeuo pipefail
    source ./sb-user-manager.sh
    rollback_probe() {
      local rc=$?
      printf "%s\n" "$rc" >> "$ROLLBACK_MARKER"
      return "$rc"
    }
    trap rollback_probe ERR
    initialize_deployed_state false
  ' >/dev/null 2>&1
deploy_failure_rc=$?
set -e
[[ "$deploy_failure_rc" == 1 ]]
[[ "$(wc -l < "$deploy_rollback_marker" | tr -d ' ')" == 1 ]]
grep -Fxq '1' "$deploy_rollback_marker"

deploy_path_rollback_marker="$deploy_state_root/path-rollback-marker"
set +e
SB_USER_CONF="$deploy_state_root/missing.conf" ROLLBACK_MARKER="$deploy_path_rollback_marker" \
  SB_USER_MANAGER_LIBRARY=true bash -c '
    set -Eeuo pipefail
    source ./sb-user-manager.sh
    rollback_probe() {
      local rc=$?
      printf "%s\n" "$rc" >> "$ROLLBACK_MARKER"
      return "$rc"
    }
    trap rollback_probe ERR
    deployed_state_file="$(trap - ERR; deployed_state_path)"
  ' >/dev/null 2>&1
deploy_path_failure_rc=$?
set -e
[[ "$deploy_path_failure_rc" == 1 ]]
[[ "$(wc -l < "$deploy_path_rollback_marker" | tr -d ' ')" == 1 ]]
grep -Fxq '1' "$deploy_path_rollback_marker"

deploy_cleanup_root="$work/deploy-created-cleanup"
deploy_cleanup_sibling="$work/deploy-created-sibling"
mkdir -p "$deploy_cleanup_root/child"
mkdir -p "$deploy_cleanup_sibling"
touch "$deploy_cleanup_root/child/file"
touch "$deploy_cleanup_sibling/file"
cleanup_deploy_created_paths \
  "$deploy_cleanup_root" \
  "$deploy_cleanup_root/child" \
  "$deploy_cleanup_root/child/file" \
  "$deploy_cleanup_sibling"
[[ ! -e "$deploy_cleanup_root" ]]
[[ ! -e "$deploy_cleanup_sibling" ]]
cleanup_deploy_created_paths

nfuse_ready_bin="$work/nfuse-ready"
nfuse_ready_counter="$work/nfuse-ready-counter"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '[[ "$#" -eq 4 && "$1" == list && "$2" == --json && "$3" == --socket && "$4" == "$NFUSE_READY_EXPECTED_SOCKET" ]] || exit 64' \
  'count="$(cat "$NFUSE_READY_COUNTER" 2>/dev/null || printf 0)"' \
  'count=$((count + 1))' \
  'printf "%s\n" "$count" > "$NFUSE_READY_COUNTER"' \
  '[[ "${NFUSE_READY_ALWAYS_FAIL:-false}" != true && "$count" -ge 3 ]] || exit 1' \
  'printf "[]\n"' > "$nfuse_ready_bin"
chmod 700 "$nfuse_ready_bin"
NFUSE_BIN="$nfuse_ready_bin"
NFUSE_SOCKET="$work/nfuse-ready.sock"
NFUSE_READY_COUNTER="$nfuse_ready_counter"
NFUSE_READY_EXPECTED_SOCKET="$NFUSE_SOCKET"
export NFUSE_READY_COUNTER NFUSE_READY_EXPECTED_SOCKET
NFUSE_READY_ATTEMPTS=3
NFUSE_READY_DELAY=0
wait_for_nfuse_ready
[[ "$(cat "$nfuse_ready_counter")" == 3 ]]
printf '0\n' > "$nfuse_ready_counter"
NFUSE_READY_ALWAYS_FAIL=true
export NFUSE_READY_ALWAYS_FAIL
NFUSE_READY_ATTEMPTS=2
if wait_for_nfuse_ready; then
  echo 'Nfuse readiness should fail after the retry limit' >&2
  exit 1
fi
[[ "$(cat "$nfuse_ready_counter")" == 2 ]]
unset NFUSE_BIN NFUSE_SOCKET NFUSE_READY_COUNTER NFUSE_READY_ALWAYS_FAIL NFUSE_READY_EXPECTED_SOCKET NFUSE_READY_ATTEMPTS NFUSE_READY_DELAY

(
  ip() { printf '%s\n' 'default via 192.0.2.1 dev eth-unit proto dhcp'; }
  [[ "$(default_network_interface)" == eth-unit ]]
)

atomic_install_root="$work/atomic-install"
atomic_install_source="$atomic_install_root/source"
atomic_install_target="$atomic_install_root/target"
atomic_install_sync_log="$atomic_install_root/sync.log"
mkdir -p "$atomic_install_root"
printf 'new executable\n' > "$atomic_install_source"
printf 'old executable\n' > "$atomic_install_target"
(
  RUNTIME_TEMP_PATHS=()
  RUNTIME_TEMP_PATH_COUNT=0
  sync_transaction_path() { printf '%s\n' "$1" >> "$atomic_install_sync_log"; }
  atomic_install_file "$atomic_install_source" "$atomic_install_target" 755
  [[ "$RUNTIME_TEMP_PATH_COUNT" == 0 ]]
)
cmp -s "$atomic_install_source" "$atomic_install_target"
[[ "$(manager_file_mode "$atomic_install_target")" == 755 ]]
[[ "$(wc -l < "$atomic_install_sync_log" | tr -d ' ')" == 2 ]]
[[ "$(tail -n1 "$atomic_install_sync_log")" == "$atomic_install_root" ]]
if find "$atomic_install_root" -maxdepth 1 -name '.atomic-install.*' -print -quit | grep -q .; then
  echo 'successful atomic install left a staging file behind' >&2
  exit 1
fi

printf 'old executable\n' > "$atomic_install_target"
(
  sync_transaction_path() { return 0; }
  install() {
    local destination='' argument
    for argument in "$@"; do destination="$argument"; done
    printf 'partial executable\n' > "$destination"
    return 73
  }
  if atomic_install_file "$atomic_install_source" "$atomic_install_target" 755; then
    echo 'atomic install must report a staging write failure' >&2
    exit 1
  fi
)
grep -Fxq 'old executable' "$atomic_install_target"

(
  sync_transaction_path() { return 0; }
  mv() { return 74; }
  if atomic_install_file "$atomic_install_source" "$atomic_install_target" 755; then
    echo 'atomic install must report a rename failure' >&2
    exit 1
  fi
)
grep -Fxq 'old executable' "$atomic_install_target"
if find "$atomic_install_root" -maxdepth 1 -name '.atomic-install.*' -print -quit | grep -q .; then
  echo 'failed atomic install left a staging file behind' >&2
  exit 1
fi

atomic_install_external="$atomic_install_root/external"
printf 'external executable\n' > "$atomic_install_external"
rm -f -- "$atomic_install_target"
ln -s "$atomic_install_external" "$atomic_install_target"
if atomic_install_file "$atomic_install_source" "$atomic_install_target" 755; then
  echo 'atomic install must reject an existing symlink target' >&2
  exit 1
fi
[[ -L "$atomic_install_target" ]]
grep -Fxq 'external executable' "$atomic_install_external"

(
  SB_SYSTEM_ROOT="$work/shared-environment-root"
  SELF_PATH="$work/shared-manager-self.sh"
  manager_target="$SB_SYSTEM_ROOT/usr/local/sbin/sb-user-manager"
  manager_download_marker="$work/shared-manager-download"
  mkdir -p "$(dirname "$manager_target")"
  printf '%s\n' '#!/usr/bin/env bash' 'SCRIPT_VERSION="4.7.2"' > "$SELF_PATH"
  download_manager() {
    printf 'downloaded\n' > "$2"
    printf '%s:%s\n' "$1" "$2" > "$manager_download_marker"
  }
  install_manager_binary "$work/download-work" true
  grep -Fxq "$work/download-work:$manager_target" "$manager_download_marker"
  grep -Fxq downloaded "$manager_target"
  install_manager_binary "$work/download-work" false
  cmp -s "$SELF_PATH" "$manager_target"

  shortcut="$SB_SYSTEM_ROOT/usr/local/bin/sbm"
  install_manager_shortcut
  [[ -L "$shortcut" ]]
  [[ "$(readlink "$shortcut")" == /usr/local/sbin/sb-user-manager ]]
  install_manager_shortcut
  [[ "$(readlink "$shortcut")" == /usr/local/sbin/sb-user-manager ]]

  rm -f "$shortcut"
  printf 'keep-existing\n' > "$shortcut"
  if validate_manager_shortcut_path || install_manager_shortcut; then
    echo 'an existing regular file must block the sbm shortcut' >&2
    exit 1
  fi
  grep -Fxq keep-existing "$shortcut"

  rm -f "$shortcut"
  ln -s /usr/local/bin/another-program "$shortcut"
  if validate_manager_shortcut_path || install_manager_shortcut; then
    echo 'a foreign symlink must block the sbm shortcut' >&2
    exit 1
  fi
  [[ "$(readlink "$shortcut")" == /usr/local/bin/another-program ]]

  rm -f "$shortcut"
  ensure_manager_shortcut_for_interactive_startup
  [[ "$(readlink "$shortcut")" == /usr/local/sbin/sb-user-manager ]]
  ensure_manager_shortcut_for_interactive_startup
  [[ "$(readlink "$shortcut")" == /usr/local/sbin/sb-user-manager ]]

  rm -f "$shortcut"
  printf 'keep-startup-conflict\n' > "$shortcut"
  if ! startup_conflict_output="$(ensure_manager_shortcut_for_interactive_startup <<<' ' 2>&1)"; then
    echo 'an occupied sbm shortcut must not abort interactive startup' >&2
    exit 1
  fi
  grep -Fxq keep-startup-conflict "$shortcut"
  grep -Fq '脚本没有覆盖它' <<<"$startup_conflict_output"
  grep -Fq '按回车返回菜单' <<<"$startup_conflict_output"
  if grep -Fq 'command not found' <<<"$startup_conflict_output"; then
    echo 'an occupied sbm shortcut called an undefined command' >&2
    exit 1
  fi

  rm -f "$shortcut"
  if ! startup_install_failure_output="$(
    {
      install_manager_shortcut() { return 1; }
      ensure_manager_shortcut_for_interactive_startup <<<' '
    } 2>&1
  )"; then
    echo 'an sbm shortcut installation failure must not abort interactive startup' >&2
    exit 1
  fi
  [[ ! -e "$shortcut" && ! -L "$shortcut" ]]
  grep -Fq '未能自动创建 sbm 快捷入口' <<<"$startup_install_failure_output"
  grep -Fq '按回车返回菜单' <<<"$startup_install_failure_output"
  if grep -Fq 'command not found' <<<"$startup_install_failure_output"; then
    echo 'an sbm shortcut installation failure called an undefined command' >&2
    exit 1
  fi

  LATEST_KERNEL_VERSION=1.2.3
  LATEST_NFUSE_VERSION=4.5.6
  write_deployed_versions 4.7.2
  grep -Fxq 'SCRIPT_VERSION=4.7.2' "$SB_SYSTEM_ROOT/var/lib/sb-user-manager/versions"
  grep -Fxq 'SINGBOX_VERSION=1.2.3' "$SB_SYSTEM_ROOT/var/lib/sb-user-manager/versions"
  grep -Fxq 'NFUSE_VERSION=4.5.6' "$SB_SYSTEM_ROOT/var/lib/sb-user-manager/versions"

  cert_dir="$SB_SYSTEM_ROOT/etc/sing-box/cert"
  mkdir -p "$cert_dir"
  printf 'existing-cert\n' > "$cert_dir/anytls.crt"
  printf 'existing-key\n' > "$cert_dir/anytls.key"
  openssl() { printf 'unexpected\n' > "$work/shared-cert-regenerated"; return 1; }
  ensure_anytls_certificate
  [[ ! -e "$work/shared-cert-regenerated" ]]
  rm -f "$cert_dir/anytls.crt" "$cert_dir/anytls.key"
  hostname() { [[ "${1:-}" == -I ]] && printf '192.0.2.2\n'; }
  openssl() {
    local key_path='' cert_path=''
    while (($# > 0)); do
      case "$1" in
        -keyout) key_path="$2"; shift 2;;
        -out) cert_path="$2"; shift 2;;
        *) shift;;
      esac
    done
    printf 'generated-key\n' > "$key_path"
    printf 'generated-cert\n' > "$cert_path"
  }
  ensure_anytls_certificate
  grep -Fxq generated-key "$cert_dir/anytls.key"
  grep -Fxq generated-cert "$cert_dir/anytls.crt"
)

(
  service_events="$work/shared-service-events"
  systemctl() { printf '%s\n' "$*" >> "$service_events"; }
  wait_for_nfuse_ready() { printf 'nfuse-ready\n' >> "$service_events"; }
  activate_managed_services
  expected_service_events=$'daemon-reload\nenable nfuse sing-box sb-user-expiry.timer\nrestart nfuse sing-box\nnfuse-ready\nstart sb-user-expiry.timer\nis-active --quiet nfuse\nis-active --quiet sing-box'
  [[ "$(<"$service_events")" == "$expected_service_events" ]]

  : > "$service_events"
  systemctl() {
    printf '%s\n' "$*" >> "$service_events"
    [[ "$*" != 'restart nfuse sing-box' ]]
  }
  wait_for_nfuse_ready() { printf 'unexpected-ready\n' >> "$service_events"; }
  if activate_managed_services; then
    echo 'service activation should propagate restart failure' >&2
    exit 1
  fi
  grep -Fxq 'restart nfuse sing-box' "$service_events"
  if grep -Fq 'unexpected-ready' "$service_events"; then
    echo 'unexpected unexpected-ready in $service_events' >&2
    exit 1
  fi
  if grep -Fq 'start sb-user-expiry.timer' "$service_events"; then
    echo 'unexpected start sb-user-expiry.timer in $service_events' >&2
    exit 1
  fi
)

(
  failed_work="$work/shared-failed-work"
  failed_journal="$work/shared-failed-journal"
  restore_marker="$work/shared-failed-restored"
  clear_marker="$work/shared-failed-cleared"
  mkdir -p "$failed_work"
  : > "$failed_journal"
  ENVIRONMENT_TRANSACTION_JOURNAL="$failed_journal"
  restore_environment_backup() { printf '%s\n' "$1" > "$restore_marker"; }
  clear_environment_transaction() { rm -f "$failed_journal"; printf 'cleared\n' > "$clear_marker"; }
  restore_failed_environment_change unit-action /unit/snapshot "$failed_work" >/dev/null
  grep -Fxq /unit/snapshot "$restore_marker"
  grep -Fxq cleared "$clear_marker"
  [[ ! -e "$failed_work" && ! -e "$failed_journal" ]]

  failed_work="$work/shared-restore-failed-work"
  failed_journal="$work/shared-restore-failed-journal"
  failed_log="$work/shared-restore-failed-log"
  mkdir -p "$failed_work"
  : > "$failed_journal"
  ENVIRONMENT_TRANSACTION_JOURNAL="$failed_journal"
  restore_environment_backup() { return 78; }
  clear_environment_transaction() { printf 'unexpected-clear\n' >> "$failed_log"; }
  exec 8>"$work/shared-restore-failed.lock"
  restore_failed_environment_change unit-action /unit/broken-snapshot "$failed_work" > "$failed_log"
  grep -Fq '环境快照自动恢复失败' "$failed_log"
  if grep -Fq 'unexpected-clear' "$failed_log"; then
    echo 'unexpected unexpected-clear in $failed_log' >&2
    exit 1
  fi
  [[ ! -e "$failed_work" && -e "$failed_journal" ]]
  if { printf x >&8; } 2>/dev/null; then
    echo 'failed environment snapshot restore should release fd 8' >&2
    exit 1
  fi
)

(
  completed_work="$work/shared-completed-work"
  complete_marker="$work/shared-completed"
  signal_marker="$work/shared-signal-cleared"
  mkdir -p "$completed_work"
  clear_environment_transaction() { printf 'completed\n' > "$complete_marker"; }
  clear_signal_rollback() { printf 'signal-cleared\n' > "$signal_marker"; }
  trap 'return 99' ERR
  complete_environment_change "$completed_work"
  grep -Fxq completed "$complete_marker"
  grep -Fxq signal-cleared "$signal_marker"
  [[ ! -e "$completed_work" && -z "$(trap -p ERR)" ]]

  completed_work="$work/shared-complete-failed-work"
  mkdir -p "$completed_work"
  rm -f "$signal_marker"
  clear_environment_transaction() { return 79; }
  if complete_environment_change "$completed_work"; then
    echo 'environment completion should propagate journal cleanup failure' >&2
    exit 1
  fi
  [[ -d "$completed_work" && ! -e "$signal_marker" ]]
)

(
  uninstall_root="$work/uninstall-success-root"
  ENVIRONMENT_BACKUP_BASE="$uninstall_root/root/sb-user-manager-backups"
  MIGRATION_BACKUP_DIR="$ENVIRONMENT_BACKUP_BASE/data"
  DIAGNOSTIC_REPORT_DIR="$uninstall_root/root/sb-user-manager-diagnostics"
  ENVIRONMENT_TRANSACTION_JOURNAL="$uninstall_root/var/lib/sb-user-manager.recovery.json"
  ENVIRONMENT_LOCK_FILE="$uninstall_root/run/lock/sb-user-manager-environment.lock"
  LOCK_FILE="$uninstall_root/run/lock/sb-user-manager.lock"
  SB_SYSTEM_ROOT="$uninstall_root"
  mkdir -p \
    "$uninstall_root/etc/sing-box/backups" \
    "$uninstall_root/etc/systemd/system/multi-user.target.wants" \
    "$uninstall_root/etc/systemd/system/timers.target.wants" \
    "$uninstall_root/var/lib/nfuse" \
    "$uninstall_root/var/lib/sing-box" \
    "$uninstall_root/var/lib/sb-user-manager" \
    "$uninstall_root/usr/local/bin" \
    "$uninstall_root/usr/local/sbin" \
    "$uninstall_root/run" \
    "$MIGRATION_BACKUP_DIR" \
    "$ENVIRONMENT_BACKUP_BASE/reports" \
    "$DIAGNOSTIC_REPORT_DIR"
  printf 'config\n' > "$uninstall_root/etc/sing-box/config.json"
  printf 'state\n' > "$uninstall_root/etc/sing-box/managed-users.json"
  printf 'manager-config\n' > "$uninstall_root/etc/sb-user-manager.conf"
  create_test_sqlite_database "$uninstall_root/var/lib/nfuse/nfuse.db" nfuse-db
  printf 'cache\n' > "$uninstall_root/var/lib/sing-box/cache.db"
  printf 'versions\n' > "$uninstall_root/var/lib/sb-user-manager/versions"
  printf 'manager\n' > "$uninstall_root/usr/local/sbin/sb-user-manager"
  printf 'sing-box\n' > "$uninstall_root/usr/local/bin/sing-box"
  printf 'nfuse\n' > "$uninstall_root/usr/local/bin/nfuse"
  printf 'unit\n' > "$uninstall_root/etc/systemd/system/sing-box.service"
  printf 'unit\n' > "$uninstall_root/etc/systemd/system/nfuse.service"
  printf 'unit\n' > "$uninstall_root/etc/systemd/system/sb-user-expiry.service"
  printf 'unit\n' > "$uninstall_root/etc/systemd/system/sb-user-expiry.timer"
  ln -s ../sing-box.service "$uninstall_root/etc/systemd/system/multi-user.target.wants/sing-box.service"
  ln -s ../nfuse.service "$uninstall_root/etc/systemd/system/multi-user.target.wants/nfuse.service"
  ln -s ../sb-user-expiry.timer "$uninstall_root/etc/systemd/system/timers.target.wants/sb-user-expiry.timer"
  ln -s /usr/local/sbin/sb-user-manager "$uninstall_root/usr/local/bin/sbm"
  printf 'socket\n' > "$uninstall_root/run/nfuse.sock"
  printf 'keep-migration\n' > "$MIGRATION_BACKUP_DIR/sb-user-data-unit.sbm"
  printf 'remove-report\n' > "$ENVIRONMENT_BACKUP_BASE/reports/report.json"
  printf 'remove-diagnostic\n' > "$DIAGNOSTIC_REPORT_DIR/report.txt"
  flock() { return 0; }
  ensure_safe_ssh_for_complete_uninstall() { return 0; }
  if ! uninstall_output="$(uninstall_managed_environment)"; then
    echo 'complete uninstall should succeed in an isolated managed root' >&2
    exit 1
  fi
  grep -Fq '完整卸载已完成' <<<"$uninstall_output"
  while IFS= read -r uninstall_path; do
    [[ ! -e "$uninstall_root$uninstall_path" && ! -L "$uninstall_root$uninstall_path" ]]
  done < <(managed_uninstall_paths)
  grep -Fxq keep-migration "$MIGRATION_BACKUP_DIR/sb-user-data-unit.sbm"
  [[ ! -e "$ENVIRONMENT_BACKUP_BASE/reports" ]]
  [[ ! -e "$DIAGNOSTIC_REPORT_DIR" ]]
  [[ ! -e "$ENVIRONMENT_TRANSACTION_JOURNAL" ]]
  [[ -f "$ENVIRONMENT_LOCK_FILE" && ! -L "$ENVIRONMENT_LOCK_FILE" ]]
  [[ -f "$LOCK_FILE" && ! -L "$LOCK_FILE" ]]
)

(
  uninstall_root="$work/uninstall-rollback-root"
  ENVIRONMENT_BACKUP_BASE="$uninstall_root/root/sb-user-manager-backups"
  MIGRATION_BACKUP_DIR="$ENVIRONMENT_BACKUP_BASE/data"
  ENVIRONMENT_TRANSACTION_JOURNAL="$uninstall_root/var/lib/sb-user-manager.recovery.json"
  ENVIRONMENT_LOCK_FILE="$uninstall_root/run/lock/sb-user-manager-environment.lock"
  LOCK_FILE="$uninstall_root/run/lock/sb-user-manager.lock"
  SB_SYSTEM_ROOT="$uninstall_root"
  mkdir -p \
    "$uninstall_root/etc/sing-box" \
    "$uninstall_root/etc/systemd/system" \
    "$uninstall_root/var/lib/nfuse" \
    "$uninstall_root/var/lib/sing-box" \
    "$uninstall_root/var/lib/sb-user-manager" \
    "$uninstall_root/usr/local/bin" \
    "$uninstall_root/usr/local/sbin"
  printf 'rollback-config\n' > "$uninstall_root/etc/sing-box/config.json"
  printf 'rollback-state\n' > "$uninstall_root/etc/sing-box/managed-users.json"
  printf 'rollback-manager\n' > "$uninstall_root/etc/sb-user-manager.conf"
  create_test_sqlite_database "$uninstall_root/var/lib/nfuse/nfuse.db" rollback-nfuse
  printf 'rollback-cache\n' > "$uninstall_root/var/lib/sing-box/cache.db"
  printf 'rollback-versions\n' > "$uninstall_root/var/lib/sb-user-manager/versions"
  printf 'rollback-manager-bin\n' > "$uninstall_root/usr/local/sbin/sb-user-manager"
  printf 'rollback-sing-box\n' > "$uninstall_root/usr/local/bin/sing-box"
  printf 'rollback-nfuse-bin\n' > "$uninstall_root/usr/local/bin/nfuse"
  printf 'rollback-unit\n' > "$uninstall_root/etc/systemd/system/sing-box.service"
  printf 'rollback-unit\n' > "$uninstall_root/etc/systemd/system/nfuse.service"
  printf 'rollback-unit\n' > "$uninstall_root/etc/systemd/system/sb-user-expiry.service"
  printf 'rollback-unit\n' > "$uninstall_root/etc/systemd/system/sb-user-expiry.timer"
  flock() { return 0; }
  ensure_safe_ssh_for_complete_uninstall() { return 0; }
  remove_managed_uninstall_paths() {
    rm -f -- "$uninstall_root/etc/sing-box/config.json"
    return 77
  }
  if uninstall_managed_environment > "$work/uninstall-rollback-output" 2>&1; then
    echo 'failed uninstall step must not report success' >&2
    exit 1
  fi
  grep -Fxq rollback-config "$uninstall_root/etc/sing-box/config.json"
  grep -Fxq rollback-state "$uninstall_root/etc/sing-box/managed-users.json"
  [[ "$(read_test_sqlite_marker "$uninstall_root/var/lib/nfuse/nfuse.db")" == rollback-nfuse ]]
  grep -Fxq rollback-cache "$uninstall_root/var/lib/sing-box/cache.db"
  [[ ! -e "$ENVIRONMENT_TRANSACTION_JOURNAL" ]]
  grep -Fq '服务器已经恢复到卸载前状态' "$work/uninstall-rollback-output"
  [[ -f "$LOCK_FILE" && ! -L "$LOCK_FILE" ]]
  if { printf x >&9; } 2>/dev/null; then
    echo 'uninstall rollback should release operation lock descriptor' >&2
    exit 1
  fi
)

(
  uninstall_called="$work/uninstall-cancel-called"
  show_environment_diagnostics() { ENVIRONMENT_CLASS=managed_complete; }
  uninstall_managed_environment() { printf 'called\n' > "$uninstall_called"; }
  MENU_RETURNED=false
  uninstall_environment <<<'0' >/dev/null
  [[ "$MENU_RETURNED" == true && ! -e "$uninstall_called" ]]

  MENU_RETURNED=false
  uninstall_environment <<<$'2\n0' >/dev/null
  [[ "$MENU_RETURNED" == true && ! -e "$uninstall_called" ]]

  create_migration_backup() {
    CREATED_MIGRATION_BACKUP=""
    MENU_RETURNED=true
  }
  MENU_RETURNED=false
  uninstall_environment <<<'1' >/dev/null
  [[ "$MENU_RETURNED" == true && ! -e "$uninstall_called" ]]
)

install_flow_root="$work/install-flow-root"
install_flow_state="$install_flow_root/etc/sing-box/managed-users.json"
mkdir -p "$install_flow_root/etc/sing-box"
printf '%s\n' '{"inbounds":[],"outbounds":[],"route":{}}' > "$install_flow_root/etc/sing-box/config.json"
printf '%s\n' '{"schema_version":3,"users":[],"splits":[]}' > "$install_flow_state"

exercise_install_flow() (
  local environment="$1" input="$2"
  SB_SYSTEM_ROOT="$install_flow_root"
  STATE_FILE="$install_flow_state"
  ENVIRONMENT_CLASS="$environment"
  show_environment_diagnostics() { :; }
  install_prerequisites() { printf 'FLOW:prerequisites\n'; }
  fetch_latest_releases() { printf 'FLOW:fetch:%s\n' "$1"; }
  deploy_environment() { printf 'FLOW:deploy:%s:%s\n' "$1" "${2:-}"; }
  takeover_existing_environment() { printf 'FLOW:takeover\n'; }
  install_environment <<<"$input"
)

exercise_install_flow fresh y > "$work/install-fresh"
grep -Fxq 'FLOW:prerequisites' "$work/install-fresh"
grep -Fxq 'FLOW:fetch:false' "$work/install-fresh"
grep -Fxq 'FLOW:deploy:true:' "$work/install-fresh"
exercise_install_flow fresh n > "$work/install-fresh-cancel"
grep -Fq '已取消部署' "$work/install-fresh-cancel"
if grep -Fq 'FLOW:' "$work/install-fresh-cancel"; then
  echo 'unexpected FLOW: in $work/install-fresh-cancel' >&2
  exit 1
fi
exercise_install_flow managed_complete '' > "$work/install-complete"
grep -Fq '安装完整' "$work/install-complete"
if grep -Fq 'FLOW:' "$work/install-complete"; then
  echo 'unexpected FLOW: in $work/install-complete' >&2
  exit 1
fi

exercise_install_flow managed_partial 1 > "$work/install-repair"
grep -Fxq 'FLOW:prerequisites' "$work/install-repair"
grep -Fxq 'FLOW:fetch:false' "$work/install-repair"
grep -Fxq 'FLOW:deploy:false:' "$work/install-repair"
exercise_install_flow managed_damaged $'2\ny' > "$work/install-overwrite"
grep -Fxq 'FLOW:deploy:true:' "$work/install-overwrite"

# 管理配置缺失时运行时变量还没有加载；自动修复必须按系统路径判断用户资料，不能引用未定义变量。
set +e
(
  SB_SYSTEM_ROOT="$install_flow_root"
  SINGBOX_BIN="$work/install-flow-missing-sing-box"
  SINGBOX_CHANNEL_STATE="$work/install-flow-missing-channel.json"
  unset STATE_FILE
  ENVIRONMENT_CLASS=managed_partial
  show_environment_diagnostics() { :; }
  install_prerequisites() { printf 'FLOW:prerequisites\n'; }
  fetch_latest_releases() { printf 'FLOW:fetch:%s\n' "$1"; }
  deploy_environment() { printf 'FLOW:deploy:%s:%s\n' "$1" "${2:-}"; }
  install_environment <<<'1'
) > "$work/install-repair-without-config" 2>&1
install_repair_without_config_rc=$?
set -e
[[ "$install_repair_without_config_rc" == 0 ]]
grep -Fxq 'FLOW:deploy:false:' "$work/install-repair-without-config"
if grep -Fq 'unbound variable' "$work/install-repair-without-config"; then
  echo 'unexpected unbound variable in $work/install-repair-without-config' >&2
  exit 1
fi

# 自动修复必须沿用当前 sing-box 通道；测试版不能被静默换回正式版。
install_flow_preview_bin="$work/install-flow-preview-sing-box"
install_flow_stable_bin="$work/install-flow-stable-sing-box"
cat > "$install_flow_preview_bin" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == version ]]; then echo 'sing-box version 1.14.0-alpha.44'; else exit 0; fi
EOF
cat > "$install_flow_stable_bin" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == version ]]; then echo 'sing-box version 1.13.10'; else exit 0; fi
EOF
chmod +x "$install_flow_preview_bin" "$install_flow_stable_bin"
exercise_install_repair_channel() (
  SB_SYSTEM_ROOT="$install_flow_root"
  STATE_FILE="$install_flow_state"
  SINGBOX_BIN="$1"
  SINGBOX_CHANNEL_STATE="$work/install-flow-missing-channel.json"
  ENVIRONMENT_CLASS=managed_partial
  show_environment_diagnostics() { :; }
  install_prerequisites() { :; }
  fetch_latest_releases() { LATEST_KERNEL_VERSION=1.13.14; }
  deploy_environment() { printf 'FLOW:singbox:%s\n' "$LATEST_KERNEL_VERSION"; }
  install_environment <<<'1'
)
exercise_install_repair_channel "$install_flow_preview_bin" > "$work/install-repair-preview"
grep -Fxq 'FLOW:singbox:1.14.0-alpha.44' "$work/install-repair-preview"
exercise_install_repair_channel "$install_flow_stable_bin" > "$work/install-repair-stable"
grep -Fxq 'FLOW:singbox:1.13.14' "$work/install-repair-stable"

exercise_install_flow external $'1\ny' > "$work/install-takeover"
grep -Fxq 'FLOW:prerequisites' "$work/install-takeover"
grep -Fxq 'FLOW:takeover' "$work/install-takeover"
if grep -Fq 'FLOW:deploy' "$work/install-takeover"; then
  echo 'unexpected FLOW:deploy in $work/install-takeover' >&2
  exit 1
fi
exercise_install_flow external $'2\ny' > "$work/install-external-overwrite"
grep -Fxq 'FLOW:fetch:false' "$work/install-external-overwrite"
grep -Fxq 'FLOW:deploy:true:' "$work/install-external-overwrite"
(
  apt_get_called="$work/apt-get-install-called"
  apt-get() {
    if [[ "${1:-}" == update ]]; then return 1; fi
    : > "$apt_get_called"
  }
  if install_prerequisites >/dev/null 2>&1; then
    echo 'failed apt update must reject prerequisite installation' >&2
    exit 1
  fi
  [[ ! -e "$apt_get_called" ]]
)
(
  install_flow_failure_marker="$work/install-flow-after-prerequisites"
  ENVIRONMENT_CLASS=fresh
  show_environment_diagnostics() { :; }
  install_prerequisites() { return 1; }
  fetch_latest_releases() { : > "$install_flow_failure_marker"; }
  if install_environment <<<'y' >/dev/null 2>&1; then
    echo 'install_environment must stop after prerequisite failure' >&2
    exit 1
  fi
  [[ ! -e "$install_flow_failure_marker" ]]
)

rm -f "$install_flow_state"
printf '%s\n' '{"inbounds":[{"tag":"anytls-orphan"}]}' > "$install_flow_root/etc/sing-box/config.json"
set +e
exercise_install_flow managed_partial 1 > "$work/install-unsafe-repair" 2>&1
unsafe_repair_rc=$?
set -e
[[ "$unsafe_repair_rc" == 1 ]]
grep -Fq '已有用户连接配置，但用户资料缺失' "$work/install-unsafe-repair"
if grep -Fq 'FLOW:deploy' "$work/install-unsafe-repair"; then
  echo 'unexpected FLOW:deploy in $work/install-unsafe-repair' >&2
  exit 1
fi

set +e
(
  environment_is_deployed() { return 0; }
  load_runtime_config() { :; }
  need_cmd() { :; }
  LOCK_FILE="$work/update-failure.lock"
  flock() { return 0; }
  fetch_latest_releases() {
    LATEST_KERNEL_VERSION=1.2.3
    LATEST_NFUSE_VERSION=4.5.6
    LATEST_MANAGER_VERSION="$SCRIPT_VERSION"
  }
  installed_singbox_version() { printf '1.0.0\n'; }
  installed_nfuse_version() { printf '4.5.6\n'; }
  installed_manager_version() { printf '%s\n' "$SCRIPT_VERSION"; }
  deploy_environment() {
    if ! { printf x >&9; } 2>/dev/null; then
      echo 'update check must keep fd 9 while entering deployment' >&2
      return 74
    fi
    printf 'UPDATE:deploy-called\n'
    return 73
  }
  check_updates <<<'y'
) > "$work/update-failure" 2>&1
update_failure_rc=$?
set -e
[[ "$update_failure_rc" == 1 ]]
grep -Fxq 'UPDATE:deploy-called' "$work/update-failure"
if grep -Fq '正在切换到新进程' "$work/update-failure"; then
  echo 'unexpected 正在切换到新进程 in $work/update-failure' >&2
  exit 1
fi

# 安装或更新必须在建立备份、停止服务或写入系统前确认 127.0.0.1 可绑定。
# 该检查不能依赖 sing-box check，因为静态检查不会实际打开监听端口。
(
  python3() { return 0; }
  ensure_deploy_loopback_ready
)
(
  marker="$work/deploy-after-loopback-preflight"
  acquire_operation_lock() { return 0; }
  release_operation_lock() { :; }
  ensure_safe_ssh_for_kernel_restart() { return 0; }
  python3() { return 1; }
  validate_manager_shortcut_path() { : > "$marker"; return 0; }
  create_environment_backup() { : > "$marker"; return 0; }
  systemctl() { : > "$marker"; return 0; }
  if deploy_environment false false > "$work/deploy-loopback-rejected" 2>&1; then
    echo 'deployment accepted an unavailable 127.0.0.1 loopback address' >&2
    exit 1
  fi
  [[ ! -e "$marker" ]]
  grep -Fq '本机回环地址 127.0.0.1 不可用' "$work/deploy-loopback-rejected"
  grep -Fq '本次操作已在修改前取消' "$work/deploy-loopback-rejected"
)

# 三个会直接修改环境的入口必须先取 fd 9；锁冲突时连预检和备份都不能开始。
for environment_entry in deploy takeover uninstall; do
  (
    side_effect_marker="$work/${environment_entry}-after-operation-lock"
    acquire_operation_lock() {
      OPERATION_LOCK_ERROR='另一个管理操作正在进行，请等待完成后再试'
      return 1
    }
    ensure_safe_ssh_for_kernel_restart() { : > "$side_effect_marker"; }
    ensure_safe_ssh_for_complete_uninstall() { : > "$side_effect_marker"; }
    create_environment_backup() { : > "$side_effect_marker"; }
    case "$environment_entry" in
      deploy) deploy_environment false false ;;
      takeover) takeover_existing_environment ;;
      uninstall) uninstall_managed_environment ;;
    esac
  ) > "$work/${environment_entry}-operation-lock.out" 2>&1 && {
    echo "$environment_entry should reject an occupied operation lock" >&2
    exit 1
  }
  [[ ! -e "$work/${environment_entry}-after-operation-lock" ]]
  grep -Fq '另一个管理操作正在进行，请等待完成后再试' "$work/${environment_entry}-operation-lock.out"
done

# 更新检查同样必须在联网查询前取锁；冲突时不得开始下载元数据。
(
  update_side_effect="$work/update-after-operation-lock"
  environment_is_deployed() { return 0; }
  load_runtime_config() { :; }
  need_cmd() { :; }
  acquire_operation_lock() {
    OPERATION_LOCK_ERROR='另一个管理操作正在进行，请等待完成后再试'
    return 1
  }
  fetch_latest_releases() { : > "$update_side_effect"; }
  check_updates
) > "$work/update-operation-lock.out" 2>&1 && {
  echo 'update check should reject an occupied operation lock' >&2
  exit 1
}
[[ ! -e "$work/update-after-operation-lock" ]]
grep -Fq '另一个管理操作正在进行，请等待完成后再试' "$work/update-operation-lock.out"

# 全新环境没有锁目录时，部署必须能创建锁、完成受管步骤并在结束后关闭 fd 9。
(
  fresh_root="$work/fresh-deploy-operation-lock"
  LOCK_FILE="$fresh_root/run/lock/sb-user-manager.lock"
  fresh_log="$fresh_root/deploy.log"
  mkdir -p "$fresh_root"
  flock() { return 0; }
  ensure_safe_ssh_for_kernel_restart() { return 0; }
  ensure_deploy_loopback_ready() { return 0; }
  validate_manager_shortcut_path() { return 0; }
  uname() { printf 'x86_64\n'; }
  default_network_interface() { printf 'eth0\n'; }
  register_temp_path() { return 0; }
  create_environment_backup() {
    ENV_BACKUP="$fresh_root/snapshot"
    mkdir -p "$ENV_BACKUP"
  }
  begin_environment_transaction() { printf 'begin\n' >> "$fresh_log"; }
  run_step_or_rollback() {
    local rollback="$1" target="$2"
    shift 2
    if [[ "$target" == complete_environment_change ]]; then
      "$target" "$@"
    else
      printf 'step:%s\n' "$target" >> "$fresh_log"
    fi
  }
  complete_environment_change() { rm -rf -- "$1"; }
  deployed_state_path() { printf '%s/managed-users.json\n' "$fresh_root"; }
  sed() { printf '%s\n' "$SCRIPT_VERSION"; }
  log() { printf '%s\n' "$*" >> "$fresh_log"; }
  deploy_environment true false
  [[ -f "$LOCK_FILE" && ! -L "$LOCK_FILE" ]]
  grep -Fxq begin "$fresh_log"
  grep -Fq '部署完成' "$fresh_log"
  if { printf x >&9; } 2>/dev/null; then
    echo 'successful deployment should release operation lock descriptor' >&2
    exit 1
  fi
)

# 环境 journal 尚未建立时失败不得执行恢复；只清理临时目录并释放 fd 9。
(
  failed_root="$work/deploy-begin-transaction-failure"
  LOCK_FILE="$failed_root/run/lock/sb-user-manager.lock"
  mkdir -p "$failed_root"
  flock() { return 0; }
  ensure_safe_ssh_for_kernel_restart() { return 0; }
  ensure_deploy_loopback_ready() { return 0; }
  validate_manager_shortcut_path() { return 0; }
  uname() { printf 'x86_64\n'; }
  default_network_interface() { printf 'eth0\n'; }
  register_temp_path() { return 0; }
  create_environment_backup() { ENV_BACKUP="$failed_root/snapshot"; mkdir -p "$ENV_BACKUP"; }
  begin_environment_transaction() { return 76; }
  restore_failed_environment_change() { : > "$failed_root/unexpected-restore"; }
  if deploy_environment false false >/dev/null 2>&1; then
    echo 'deployment should stop when the environment journal cannot be created' >&2
    exit 1
  fi
  [[ ! -e "$failed_root/unexpected-restore" ]]
  if { printf x >&9; } 2>/dev/null; then
    echo 'failed environment transaction setup should release fd 9' >&2
    exit 1
  fi
)

# 信号回滚回调必须恢复环境并释放 fd 9；这里不向真实系统写入。
(
  interrupted_root="$work/deploy-signal-rollback"
  LOCK_FILE="$interrupted_root/run/lock/sb-user-manager.lock"
  interrupted_work=""
  mkdir -p "$interrupted_root"
  flock() { return 0; }
  ensure_safe_ssh_for_kernel_restart() { return 0; }
  ensure_deploy_loopback_ready() { return 0; }
  validate_manager_shortcut_path() { return 0; }
  uname() { printf 'x86_64\n'; }
  default_network_interface() { printf 'eth0\n'; }
  register_temp_path() { interrupted_work="$1"; }
  create_environment_backup() { ENV_BACKUP="$interrupted_root/snapshot"; mkdir -p "$ENV_BACKUP"; }
  begin_environment_transaction() { return 0; }
  set_signal_rollback() { ACTIVE_SIGNAL_ROLLBACK="$1"; }
  clear_signal_rollback() { ACTIVE_SIGNAL_ROLLBACK=""; }
  systemctl() { return 0; }
  cleanup_deploy_created_paths() { return 0; }
  restore_failed_environment_change() {
    printf '%s\n' "$1:$2" > "$interrupted_root/restored"
    rm -rf -- "$3"
  }
  run_step_or_rollback() {
    local rollback="$1"
    "$rollback" 143
  }
  if deploy_environment false false >/dev/null 2>&1; then
    echo 'interrupted deployment should return failure after rollback' >&2
    exit 1
  fi
  grep -Fq '部署:' "$interrupted_root/restored"
  [[ -z "$ACTIVE_SIGNAL_ROLLBACK" && ! -e "$interrupted_work" ]]
  if { printf x >&9; } 2>/dev/null; then
    echo 'deployment signal rollback should release fd 9' >&2
    exit 1
  fi
)

# 更新元数据查询失败时也必须释放 fd 9。
(
  environment_is_deployed() { return 0; }
  load_runtime_config() { :; }
  need_cmd() { :; }
  LOCK_FILE="$work/update-fetch-failure.lock"
  flock() { return 0; }
  fetch_latest_releases() { return 77; }
  if check_updates >/dev/null 2>&1; then
    echo 'failed release metadata query should stop update checking' >&2
    exit 1
  fi
  if { printf x >&9; } 2>/dev/null; then
    echo 'failed update metadata query should release fd 9' >&2
    exit 1
  fi
)

(
  environment_is_deployed() { return 0; }
  load_runtime_config() { :; }
  need_cmd() { :; }
  LOCK_FILE="$work/preview-update.lock"
  flock() { return 0; }
  fetch_latest_releases() {
    LATEST_KERNEL_VERSION=1.13.14
    LATEST_KERNEL_URL=https://example.com/stable.tar.gz
    LATEST_KERNEL_SHA256="$(printf 'a%.0s' {1..64})"
    LATEST_NFUSE_VERSION=0.1.11
    LATEST_MANAGER_VERSION="$SCRIPT_VERSION"
  }
  fetch_singbox_channel_releases() { LATEST_PREVIEW_SINGBOX_VERSION=1.14.0-alpha.44; }
  current_singbox_channel() { printf preview; }
  installed_singbox_version() { printf '1.14.0-alpha.44\n'; }
  installed_nfuse_version() { printf '0.1.11\n'; }
  installed_manager_version() { printf '9.0.0\n'; }
  deploy_environment() { echo 'preview channel must not use stable deployment' >&2; return 1; }
  check_updates
  if { printf x >&9; } 2>/dev/null; then
    echo 'no-update path should release operation lock descriptor' >&2
    exit 1
  fi
) > "$work/preview-update-guard"
grep -Fq '测试通道请在「sing-box 版本管理 → 更新当前通道」中更新' "$work/preview-update-guard"
grep -Fq '其余组件已经是最新版本' "$work/preview-update-guard"

release_fixture() {
  local version="$1" prerelease="$2" digest="${3:-$(printf 'a%.0s' {1..64})}"
  jq -cn --arg version "$version" --argjson prerelease "$prerelease" --arg digest "sha256:$digest" \
    '{tag_name:("v"+$version),draft:false,prerelease:$prerelease,published_at:"2026-07-15T00:00:00Z",
      assets:[{name:("sing-box-"+$version+"-linux-amd64.tar.gz"),browser_download_url:("https://example.com/sing-box-"+$version+"-linux-amd64.tar.gz"),digest:$digest}]}'
}

stable_release="$(release_fixture 1.13.14 false)"
preview_release="$(release_fixture 1.14.0-alpha.44 true "$(printf 'b%.0s' {1..64})")"
stable_metadata="$(singbox_release_metadata "$stable_release")"
jq -e '.version == "1.13.14" and .asset == "sing-box-1.13.14-linux-amd64.tar.gz" and (.sha256 | length) == 64' <<<"$stable_metadata" >/dev/null
[[ "$(singbox_channel_label 1.13.14)" == 正式版 ]]
[[ "$(singbox_channel_label 1.14.0-alpha.44)" == 测试版 ]]
if singbox_release_metadata "$(release_fixture 1.13.14 false invalid)" >/dev/null 2>&1; then
  echo 'sing-box release without a trusted digest should be rejected' >&2
  exit 1
fi

(
  github_api_get() {
    if [[ "$1" == */releases/latest ]]; then printf '%s\n' "$stable_release"
    else jq -cn --argjson stable "$stable_release" --argjson preview "$preview_release" '[$stable,$preview]'
    fi
  }
  fetch_singbox_channel_releases
  [[ "$LATEST_STABLE_SINGBOX_VERSION" == 1.13.14 ]]
  [[ "$LATEST_PREVIEW_SINGBOX_VERSION" == 1.14.0-alpha.44 ]]
  [[ "$LATEST_PREVIEW_SINGBOX_SHA256" == "$(printf 'b%.0s' {1..64})" ]]
)

channel_config="$work/channel-config.json"
channel_state="$work/channel-state.json"
printf '%s\n' '{"route":{"rule_set":[{"type":"remote","url":"https://example.com/active.srs"},{"type":"remote","url":"https://example.com/shared.json"}]}}' > "$channel_config"
printf '%s\n' '{"splits":[{"url":"https://example.com/shared.json"},{"url":"https://example.com/disabled.srs","status":"disabled"}]}' > "$channel_state"
SINGBOX_CONFIG="$channel_config" STATE_FILE="$channel_state" list_singbox_rule_set_urls > "$work/channel-rule-urls"
[[ "$(wc -l < "$work/channel-rule-urls" | tr -d ' ')" == 3 ]]
grep -Fxq 'https://example.com/disabled.srs' "$work/channel-rule-urls"

channel_target_bin="$work/channel-target-bin"
channel_stable_bin="$work/channel-stable-bin"
cat > "$channel_target_bin" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  check) exit 0;;
  format) cat "$3";;
  *) exit 1;;
esac
EOF
cat > "$channel_stable_bin" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  check) echo 'field removed in stable' >&2; exit 1;;
  *) exit 1;;
esac
EOF
chmod +x "$channel_target_bin" "$channel_stable_bin"
roundtrip_config="$work/roundtrip-config.json"
empty_channel_state="$work/empty-channel-state.json"
printf '%s\n' '{"inbounds":[],"outbounds":[],"route":{"rule_set":[]}}' > "$roundtrip_config"
printf '%s\n' '{"splits":[]}' > "$empty_channel_state"
if ! (
  environment_is_deployed() { return 0; }
  load_runtime_config() { SINGBOX_CONFIG="$roundtrip_config"; STATE_FILE="$empty_channel_state"; }
  need_cmd() { :; }
  fetch_singbox_channel_releases() {
    LATEST_STABLE_SINGBOX_VERSION=1.13.14
    LATEST_STABLE_SINGBOX_ASSET=stable.tar.gz
    LATEST_STABLE_SINGBOX_URL=https://example.com/stable.tar.gz
    LATEST_STABLE_SINGBOX_SHA256="$(printf 'a%.0s' {1..64})"
    LATEST_PREVIEW_SINGBOX_VERSION=1.14.0-alpha.44
    LATEST_PREVIEW_SINGBOX_ASSET=preview.tar.gz
    LATEST_PREVIEW_SINGBOX_URL=https://example.com/preview.tar.gz
    LATEST_PREVIEW_SINGBOX_SHA256="$(printf 'b%.0s' {1..64})"
  }
  prepare_singbox_release_binary() {
    if [[ "$6" == target ]]; then PREPARED_SINGBOX_BINARY="$channel_target_bin"
    else PREPARED_SINGBOX_BINARY="$channel_stable_bin"
    fi
  }
  check_singbox_release_compatibility preview
) > "$work/channel-roundtrip-check" 2>&1; then
  cat "$work/channel-roundtrip-check" >&2
  echo 'preview round-trip compatibility check should return to the menu cleanly' >&2
  exit 1
fi
grep -Fq '测试版可以读取当前配置，但不满足安全往返要求' "$work/channel-roundtrip-check"
grep -Fq '最新正式版无法读取' "$work/channel-roundtrip-check"
grep -Fq '当前版本没有改变' "$work/channel-roundtrip-check"

channel_switch_root="$work/channel-switch"
mkdir -p "$channel_switch_root/bin" "$channel_switch_root/state"
channel_installed_bin="$channel_switch_root/bin/sing-box"
channel_candidate_bin="$channel_switch_root/bin/candidate"
cat > "$channel_installed_bin" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == version ]]; then echo 'sing-box version 1.13.14'; else exit 0; fi
EOF
cat > "$channel_candidate_bin" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == version ]]; then echo 'sing-box version 1.14.0-alpha.44'; else exit 0; fi
EOF
chmod +x "$channel_installed_bin" "$channel_candidate_bin"
printf '%s\n' '{"inbounds":[],"outbounds":[]}' > "$channel_switch_root/config.json"
printf '%s\n' 'SCRIPT_VERSION=4.12.0' 'SINGBOX_VERSION=1.13.14' 'NFUSE_VERSION=0.1.11' > "$channel_switch_root/versions"
(
  SINGBOX_BIN="$channel_installed_bin"
  SINGBOX_CONFIG="$channel_switch_root/config.json"
  SINGBOX_CHANNEL_STATE="$channel_switch_root/state/channel.json"
  SINGBOX_VERSION_STORE="$channel_switch_root/state/versions"
  DEPLOYED_VERSIONS_FILE="$channel_switch_root/versions"
  installed_singbox_version() { kernel_binary_version "$SINGBOX_BIN"; }
  prepare_singbox_release_binary() { PREPARED_SINGBOX_BINARY="$channel_candidate_bin"; }
  prepare_core() { :; }
  create_environment_backup() { ENV_BACKUP="$channel_switch_root/snapshot"; }
  begin_environment_transaction() { :; }
  set_signal_rollback() { :; }
  clear_signal_rollback() { :; }
  release_operation_lock() { :; }
  sync_transaction_path() { :; }
  systemctl() { return 0; }
  complete_environment_change() { trap - ERR; rm -rf -- "$1"; }
  perform_singbox_channel_switch preview 1.14.0-alpha.44 preview.tar.gz https://example.com/preview.tar.gz "$(printf 'a%.0s' {1..64})"
  [[ "$(installed_singbox_version)" == 1.14.0-alpha.44 ]]
  [[ "$(kernel_binary_version "$SINGBOX_VERSION_STORE/stable/sing-box")" == 1.13.14 ]]
  [[ "$(kernel_binary_version "$SINGBOX_VERSION_STORE/previous/sing-box")" == 1.13.14 ]]
  jq -e '.channel == "preview" and .current_version == "1.14.0-alpha.44" and .previous.version == "1.13.14"' "$SINGBOX_CHANNEL_STATE" >/dev/null
  grep -Fxq 'SINGBOX_VERSION=1.14.0-alpha.44' "$DEPLOYED_VERSIONS_FILE"
) > "$work/channel-switch-output"
grep -Fq '用户、分流、配额和流量记录均未修改' "$work/channel-switch-output"

channel_failed_bin="$channel_switch_root/bin/failed-installed"
cp "$channel_switch_root/state/versions/stable/sing-box" "$channel_failed_bin"
set +e
(
  SINGBOX_BIN="$channel_failed_bin"
  SINGBOX_CONFIG="$channel_switch_root/config.json"
  SINGBOX_CHANNEL_STATE="$channel_switch_root/failed-state/channel.json"
  SINGBOX_VERSION_STORE="$channel_switch_root/failed-state/versions"
  DEPLOYED_VERSIONS_FILE="$channel_switch_root/versions"
  installed_singbox_version() { kernel_binary_version "$SINGBOX_BIN"; }
  prepare_singbox_release_binary() { PREPARED_SINGBOX_BINARY="$channel_candidate_bin"; }
  prepare_core() { :; }
  create_environment_backup() { ENV_BACKUP="$channel_switch_root/failed-snapshot"; }
  begin_environment_transaction() { :; }
  set_signal_rollback() { :; }
  clear_signal_rollback() { :; }
  release_operation_lock() { :; }
  sync_transaction_path() { :; }
  systemctl() { [[ "$1" != restart ]]; }
  restore_failed_environment_change() {
    install -m 755 "$SINGBOX_VERSION_STORE/previous/sing-box" "$SINGBOX_BIN"
    printf 'rollback\n' >> "$channel_switch_root/rollback-marker"
    rm -rf -- "$3"
  }
  perform_singbox_channel_switch preview 1.14.0-alpha.44 preview.tar.gz https://example.com/preview.tar.gz "$(printf 'a%.0s' {1..64})"
) >/dev/null 2>&1
failed_switch_rc=$?
set -e
[[ "$failed_switch_rc" != 0 ]]
[[ "$(kernel_binary_version "$channel_failed_bin")" == 1.13.14 ]]
[[ "$(wc -l < "$channel_switch_root/rollback-marker" | tr -d ' ')" == 1 ]]

STATE_FILE="$work/state.json"
BACKUP_DIR="$work/backups"
CONF_FILE="$work/manager.conf"
SINGBOX_CONFIG="$work/config.json"
mkdir -p "$BACKUP_DIR"
MOCK_SINGBOX_FORMAT_FAIL=false
mock_singbox() {
  [[ "$1" == format && "$2" == -c ]]
  [[ "$MOCK_SINGBOX_FORMAT_FAIL" != true ]] || return 1
  jq . "$3"
}
SINGBOX_BIN=mock_singbox
printf '%s\n' '{"inbounds":[{"type":"shadowtls","tag":"st-legacy","handshake":{"server":"legacy.example.com"}},{"type":"shadowsocks","tag":"ss-legacy","method":"2022-blake3-aes-256-gcm"}]}' > "$SINGBOX_CONFIG"
printf '%s\n' 'HANDSHAKE_SERVER="fallback.example.com"' 'SS_METHOD="2022-blake3-aes-128-gcm"' 'TLS_SERVER_NAME="anytls.example.com"' 'PORT_MIN=10000' 'PORT_MAX=65535' > "$CONF_FILE"
HANDSHAKE_SERVER=fallback.example.com
SS_METHOD=2022-blake3-aes-128-gcm
TLS_SERVER_NAME=anytls.example.com
printf '%s\n' '{"users":[{"name":"alice","port":20001,"status":"active","protocol":"anytls","anytls_password":"legacy-anytls-secret"}],"splits":[]}' > "$STATE_FILE"
chmod 600 "$STATE_FILE"

migrate_state >/dev/null
[[ "$(jq -r '.schema_version' "$STATE_FILE")" == 7 ]]
[[ "$(jq -r '.users[0].tls_sni' "$STATE_FILE")" == anytls.example.com ]]
[[ "$(jq -r '.users[0].usage_offset_bytes' "$STATE_FILE")" == 0 ]]
jq -e '.users[0].endpoints == [{protocol:"anytls",port:20001,anytls_password:"legacy-anytls-secret",tls_sni:"anytls.example.com"}]' "$STATE_FILE" >/dev/null
[[ "$(find "$BACKUP_DIR" -type f -name 'managed-users.pre-schema-0-to-7-*.json' | wc -l | tr -d ' ')" == 1 ]]

printf '%s\n' '{"schema_version":1,"users":[{"name":"legacy","port":20004,"status":"active","shadowtls_password":"st","ss2022_password":"ss"},{"name":"legacy-disabled","port":20005,"status":"disabled","shadowtls_password":"st2","ss2022_password":"ss2","method":"2022-blake3-aes-256-gcm"}],"splits":[]}' > "$STATE_FILE"
migrate_state >/dev/null
jq -e '
  .schema_version == 7 and
  .outbound_presets == [] and .rule_presets == [] and
  .users[0].method == "2022-blake3-aes-256-gcm" and
  .users[0].shadowtls_sni == "legacy.example.com" and
  .users[0].transport == "shadowtls" and
  .users[0].endpoints[0] == {protocol:"ss2022",port:20004,shadowtls_password:"st",ss2022_password:"ss",method:"2022-blake3-aes-256-gcm",shadowtls_sni:"legacy.example.com",transport:"shadowtls"} and
  .users[1].method == "2022-blake3-aes-256-gcm" and
  .users[1].shadowtls_sni == "fallback.example.com" and
  .users[1].endpoints[0].shadowtls_sni == "fallback.example.com"
' "$STATE_FILE" >/dev/null

printf '%s\n' '{"schema_version":4,"users":[{"name":"legacy-current","port":20006,"protocol":"anytls","status":"active","metered":false,"expires_at":null,"limit_gib":null,"billing_anchor":null,"created_at":"2026-07-15T00:00:00+08:00","anytls_password":"legacy-secret","tls_sni":"legacy.example.com"}],"splits":[],"outbound_presets":[],"rule_presets":[]}' > "$STATE_FILE"
migrate_state >/dev/null
jq -e '.schema_version == 7 and .users[0].usage_offset_bytes == 0 and .users[0].endpoints[0] == {protocol:"anytls",port:20006,anytls_password:"legacy-secret",tls_sni:"legacy.example.com"}' "$STATE_FILE" >/dev/null
[[ "$(find "$BACKUP_DIR" -type f -name 'managed-users.pre-schema-4-to-7-*.json' | wc -l | tr -d ' ')" == 1 ]]

printf '%s\n' '{"schema_version":6,"users":[{"name":"schema6-direct","port":20007,"protocol":"ss2022","transport":"direct","status":"disabled","metered":false,"expires_at":null,"limit_gib":null,"billing_anchor":null,"usage_offset_bytes":0,"created_at":"2026-08-11T00:00:00+08:00","ss2022_password":"keep-direct","method":"2022-blake3-aes-128-gcm","endpoints":[{"protocol":"ss2022","transport":"direct","port":20007,"ss2022_password":"keep-direct","method":"2022-blake3-aes-128-gcm"}]}],"splits":[],"outbound_presets":[],"rule_presets":[]}' > "$STATE_FILE"
migrate_state >/dev/null
jq -e '
  .schema_version == 7 and .users[0].transport == "direct" and
  .users[0].endpoints == [{protocol:"ss2022",transport:"direct",port:20007,
    ss2022_password:"keep-direct",method:"2022-blake3-aes-128-gcm"}]
' "$STATE_FILE" >/dev/null
[[ "$(find "$BACKUP_DIR" -type f -name 'managed-users.pre-schema-6-to-7-*.json' | wc -l | tr -d ' ')" == 1 ]]

multi_endpoint_state="$work/multi-endpoint-state.json"
printf '%s\n' '{"schema_version":6,"users":[{"name":"multi","port":21001,"protocol":"anytls","status":"active","metered":true,"expires_at":null,"limit_gib":10,"billing_anchor":1,"usage_offset_bytes":0,"created_at":"2026-08-10T00:00:00+08:00","anytls_password":"at-secret","tls_sni":"at.example.com","endpoints":[{"protocol":"anytls","port":21001,"anytls_password":"at-secret","tls_sni":"at.example.com"},{"protocol":"ss2022","transport":"shadowtls","port":21002,"shadowtls_password":"st-secret","ss2022_password":"ss-secret","method":"2022-blake3-aes-128-gcm","shadowtls_sni":"ss.example.com"}]}],"splits":[],"outbound_presets":[],"rule_presets":[]}' > "$multi_endpoint_state"
validate_state_user_endpoints "$multi_endpoint_state"
for invalid_filter in \
  '.users[0].endpoints[1].protocol = "anytls"' \
  '.users[0].endpoints[1].port = 21001' \
  '.users[0].port = 21999'; do
  jq "$invalid_filter" "$multi_endpoint_state" > "$work/invalid-multi-endpoint-state.json"
  if validate_state_user_endpoints "$work/invalid-multi-endpoint-state.json"; then
    echo "multi-protocol state validation accepted invalid data: $invalid_filter" >&2
    exit 1
  fi
done

(
  failed_migration_state="$work/migrate-copy-failure-state.json"
  failed_migration_backups="$work/migrate-copy-failure-backups"
  mkdir -p "$failed_migration_backups"
  printf '%s\n' '{"schema_version":3,"users":[],"splits":[]}' > "$failed_migration_state"
  if ! (
    STATE_FILE="$failed_migration_state"
    BACKUP_DIR="$failed_migration_backups"
    cp() { return 77; }
    migrate_state >/dev/null 2>&1
  ); then
    :
  else
    echo 'migrate_state must stop when its pre-migration backup cannot be created' >&2
    exit 1
  fi
  [[ "$(jq -r '.schema_version' "$failed_migration_state")" == 3 ]]
  [[ -z "$(find "$failed_migration_backups" -type f -print -quit)" ]]
)

remove_obsolete_manager_config >/dev/null
if grep -Eq '^(SS_METHOD|HANDSHAKE_SERVER|TLS_SERVER_NAME|PORT_MIN|PORT_MAX)=' "$CONF_FILE"; then
  echo 'unexpected ^(SS_METHOD|HANDSHAKE_SERVER|TLS_SERVER_NAME|PORT_MIN|PORT_MAX)= in $CONF_FILE' >&2
  exit 1
fi
SS2022_SHADOWTLS_SNI="$DEFAULT_SS2022_SHADOWTLS_SNI"
ANYTLS_SNI="$DEFAULT_ANYTLS_SNI"
ensure_global_sni_config >/dev/null
grep -Fxq 'SS2022_SHADOWTLS_SNI="publicassets.cdn-apple.com"' "$CONF_FILE"
grep -Fxq 'ANYTLS_SNI="weKbP9SVYU.download.windowsupdate.com"' "$CONF_FILE"
[[ "$(find "$BACKUP_DIR" -type f -name 'sb-user-manager.conf.pre-sni-migration-*' | wc -l | tr -d ' ')" == 1 ]]
(
  CONF_FILE="$work/new-manager.conf"
  chown() { return 0; }
  write_manager_config
  grep -Fxq 'SS2022_SHADOWTLS_SNI="publicassets.cdn-apple.com"' "$CONF_FILE"
  grep -Fxq 'ANYTLS_SNI="weKbP9SVYU.download.windowsupdate.com"' "$CONF_FILE"
)
(
  CONF_FILE="$work/manager-write-failure.conf"
  later_step="$work/manager-write-later-step"
  chmod() { return 1; }
  chown() { : > "$later_step"; }
  if write_manager_config; then
    echo 'managed config writer ignored a failed chmod' >&2
    exit 1
  fi
  [[ ! -e "$later_step" ]]
)
(
  unit_trace="$work/systemd-unit-write-failure"
  write_singbox_unit() { printf '%s\n' sing-box >> "$unit_trace"; return 1; }
  write_nfuse_unit() { printf '%s\n' nfuse >> "$unit_trace"; }
  write_expiry_units() { printf '%s\n' expiry >> "$unit_trace"; }
  if write_systemd_units eth0; then
    echo 'managed systemd writer ignored a failed unit step' >&2
    exit 1
  fi
  [[ "$(cat "$unit_trace")" == sing-box ]]
)
(
  CONF_FILE="$work/legacy-manager-without-sni.conf"
  printf '%s\n' 'HANDSHAKE_PORT=443' > "$CONF_FILE"
  SS2022_SHADOWTLS_SNI=stale-ss.example.com
  ANYTLS_SNI=stale-any.example.com
  load_runtime_config
  [[ "$SS2022_SHADOWTLS_SNI" == publicassets.cdn-apple.com ]]
  [[ "$ANYTLS_SNI" == weKbP9SVYU.download.windowsupdate.com ]]
)

validate_ss2022_method 2022-blake3-aes-128-gcm
validate_ss2022_method 2022-blake3-aes-256-gcm
validate_shadowtls_sni www.microsoft.com
if (validate_ss2022_method aes-256-gcm >/dev/null 2>&1); then
  echo 'unsupported SS2022 method should be rejected' >&2
  exit 1
fi
if (validate_shadowtls_sni invalid_sni >/dev/null 2>&1); then
  echo 'invalid ShadowTLS SNI should be rejected' >&2
  exit 1
fi
HANDSHAKE_PORT=443
SHADOWTLS_STRICT_MODE=true
fragment="$(make_user_inbounds test 20001 st-secret ss-secret 2022-blake3-aes-256-gcm edge.example.com)"
jq -e '
  (.[0].handshake.server == "edge.example.com") and
  (.[1].method == "2022-blake3-aes-256-gcm") and
  (.[2].tag == "ss-udp-test") and
  (.[2].listen_port == 20001) and
  (.[2].network == "udp") and
  (.[2].password == "ss-secret")
' <<<"$fragment" >/dev/null

direct_fragment="$(make_ss2022_inbound direct 20002 direct-secret 2022-blake3-aes-128-gcm)"
jq -e '
  length == 1 and
  .[0].type == "shadowsocks" and
  .[0].tag == "ss-direct" and
  .[0].listen == "::" and
  .[0].listen_port == 20002 and
  .[0].method == "2022-blake3-aes-128-gcm" and
  .[0].password == "direct-secret" and
  (.[0] | has("network") | not)
' <<<"$direct_fragment" >/dev/null

stored_ss_user='{"name":"stored-ss","port":20007,"status":"active","metered":false,"shadowtls_password":"stored-st","ss2022_password":"stored-ss-secret","method":"2022-blake3-aes-128-gcm","shadowtls_sni":"stored.example.com"}'
stored_ss_fragment="$(make_user_inbounds_from_state "$stored_ss_user")"
jq -e '
  length == 3 and
  .[0].tag == "st-stored-ss" and
  .[0].listen_port == 20007 and
  .[0].users[0].password == "stored-st" and
  .[0].handshake.server == "stored.example.com" and
  .[0].handshake.server_port == 443 and
  .[0].detour == "ss-stored-ss" and
  .[1].tag == "ss-stored-ss" and
  .[1].method == "2022-blake3-aes-128-gcm" and
  .[1].password == "stored-ss-secret" and
  .[2].tag == "ss-udp-stored-ss" and
  .[2].listen_port == 20007 and
  .[2].network == "udp" and
  .[2].method == "2022-blake3-aes-128-gcm" and
  .[2].password == "stored-ss-secret"
' <<<"$stored_ss_fragment" >/dev/null

stored_direct_user='{"name":"stored-direct","port":20010,"protocol":"ss2022","transport":"direct","status":"active","metered":false,"ss2022_password":"stored-direct-secret","method":"2022-blake3-aes-256-gcm","endpoints":[{"protocol":"ss2022","transport":"direct","port":20010,"ss2022_password":"stored-direct-secret","method":"2022-blake3-aes-256-gcm"}]}'
stored_direct_fragment="$(make_user_inbounds_from_state "$stored_direct_user")"
jq -e '
  length == 1 and
  .[0].type == "shadowsocks" and
  .[0].tag == "ss-stored-direct" and
  .[0].listen_port == 20010 and
  .[0].method == "2022-blake3-aes-256-gcm" and
  .[0].password == "stored-direct-secret" and
  (.[0] | has("network") | not)
' <<<"$stored_direct_fragment" >/dev/null

stored_multi_user='{"name":"stored-multi","port":20008,"protocol":"anytls","status":"active","metered":false,"anytls_password":"stored-at","tls_sni":"at.example.com","endpoints":[{"protocol":"anytls","port":20008,"anytls_password":"stored-at","tls_sni":"at.example.com"},{"protocol":"ss2022","port":20009,"shadowtls_password":"stored-st","ss2022_password":"stored-ss","method":"2022-blake3-aes-256-gcm","shadowtls_sni":"ss.example.com"}]}'
stored_multi_fragment="$(make_user_inbounds_from_state "$stored_multi_user")"
jq -e '
  length == 4 and
  any(.[]; .tag == "anytls-stored-multi" and .listen_port == 20008) and
  any(.[]; .tag == "st-stored-multi" and .listen_port == 20009) and
  any(.[]; .tag == "ss-stored-multi" and .method == "2022-blake3-aes-256-gcm") and
  any(.[]; .tag == "ss-udp-stored-multi" and .listen_port == 20009)
' <<<"$stored_multi_fragment" >/dev/null

# 多入口批量生成必须保持旧实现的 endpoint 顺序、对象字段顺序和逐字节输出。
batch_inbound_user='{"name":"equiv","status":"active","metered":false,"endpoints":[
  {"protocol":"anytls","port":22001,"anytls_password":"any-secret","tls_sni":"any.example.com"},
  {"protocol":"ss2022","transport":"shadowtls","port":22002,"shadowtls_password":"st-secret","ss2022_password":"ss-secret","method":"2022-blake3-aes-128-gcm","shadowtls_sni":"ss.example.com"},
  {"protocol":"ss2022","transport":"direct","port":22003,"ss2022_password":"direct-secret","method":"2022-blake3-aes-256-gcm"}
]}'
batch_inbound_expected='[{"type":"anytls","tag":"anytls-equiv","listen":"::","listen_port":22001,"users":[{"name":"equiv","password":"any-secret"}],"tls":{"enabled":true,"certificate_path":"/etc/sing-box/cert/anytls.crt","key_path":"/etc/sing-box/cert/anytls.key"}},{"type":"shadowtls","tag":"st-equiv","listen":"::","listen_port":22002,"version":3,"users":[{"name":"equiv","password":"st-secret"}],"handshake":{"server":"ss.example.com","server_port":443},"strict_mode":true,"detour":"ss-equiv"},{"type":"shadowsocks","tag":"ss-equiv","network":"tcp","method":"2022-blake3-aes-128-gcm","password":"ss-secret"},{"type":"shadowsocks","tag":"ss-udp-equiv","listen":"::","listen_port":22002,"network":"udp","method":"2022-blake3-aes-128-gcm","password":"ss-secret"},{"type":"shadowsocks","tag":"ss-direct-equiv","listen":"::","listen_port":22003,"method":"2022-blake3-aes-256-gcm","password":"direct-secret"}]'
[[ "$(make_user_inbounds_from_state "$batch_inbound_user")" == "$batch_inbound_expected" ]]
for invalid_user in \
  '{"name":"empty","status":"active","endpoints":[]}' \
  '{"name":"bad-port","status":"active","endpoints":[{"protocol":"anytls","port":"22001","anytls_password":"secret"}]}' \
  '{"name":"bad-protocol","status":"active","endpoints":[{"protocol":"unknown","port":22001}]}' \
  '{"name":"bad-transport","status":"active","endpoints":[{"protocol":"ss2022","transport":"invalid","port":22001,"ss2022_password":"secret","method":"2022-blake3-aes-128-gcm"}]}' \
  '{"name":"missing-password","status":"active","endpoints":[{"protocol":"anytls","port":22001}]}'
do
  if make_user_inbounds_from_state "$invalid_user" >/dev/null 2>&1; then
    echo 'invalid endpoint state must be rejected by batch inbound generation' >&2
    exit 1
  fi
done

# 三入口片段生成固定一次 jq；秘密只经 stdin，不进入 jq argv。
(
  inbound_jq_calls="$work/batch-inbound-jq.calls"
  inbound_jq_args="$work/batch-inbound-jq.args"
  : > "$inbound_jq_calls"
  : > "$inbound_jq_args"
  jq() {
    printf 'jq\n' >> "$inbound_jq_calls"
    printf '%s\0' "$@" >> "$inbound_jq_args"
    command jq "$@"
  }
  [[ "$(make_user_inbounds_from_state "$batch_inbound_user")" == "$batch_inbound_expected" ]]
  [[ "$(wc -l < "$inbound_jq_calls" | tr -d ' ')" == 1 ]]
  if tr '\0' '\n' < "$inbound_jq_args" | grep -Fq 'any-secret'; then
    echo 'unexpected any-secret in $inbound_jq_args' >&2
    exit 1
  fi
  if tr '\0' '\n' < "$inbound_jq_args" | grep -Fq 'direct-secret'; then
    echo 'unexpected direct-secret in $inbound_jq_args' >&2
    exit 1
  fi
)

# 50 个三入口用户协议重建固定为一次批量生成和一次配置改写，并保留外部入口与 endpoint 顺序。
(
  STATE_FILE="$work/batch-rebuild-state.json"
  SINGBOX_CONFIG="$work/batch-rebuild-config.json"
  SINGBOX_BIN=batch_rebuild_singbox
  batch_rebuild_singbox() {
    [[ "$1" == format && "$2" == -c ]]
    command jq . "$3"
  }
  command jq -n '{
    schema_version:7,
    users:[range(0; 50) as $index | {
      name:("user" + ($index | tostring)),status:(if $index == 49 then "disabled" else "active" end),metered:false,
      endpoints:[
        {protocol:"ss2022",transport:"shadowtls",port:(20000 + $index),shadowtls_password:"st-secret",ss2022_password:"ss-secret",method:"2022-blake3-aes-128-gcm",shadowtls_sni:"example.com"},
        {protocol:"ss2022",transport:"direct",port:(21000 + $index),ss2022_password:"direct-secret",method:"2022-blake3-aes-128-gcm"},
        {protocol:"anytls",port:(22000 + $index),anytls_password:"any-secret",tls_sni:"any.example.com"}
      ]
    }],splits:[],outbound_presets:[],rule_presets:[]
  }' > "$STATE_FILE"
  command jq '(.users[49].endpoints[]) |= del(.shadowtls_password,.ss2022_password,.method,.shadowtls_sni,.anytls_password)' \
    "$STATE_FILE" > "$STATE_FILE.tmp"
  mv -- "$STATE_FILE.tmp" "$STATE_FILE"
  printf '%s\n' '{"inbounds":[{"type":"direct","tag":"external-a"},{"type":"direct","tag":"st-user0"},{"type":"direct","tag":"external-b"}],"outbounds":[],"route":{"rules":[],"rule_set":[]}}' > "$SINGBOX_CONFIG"
  rebuild_jq_calls="$work/batch-rebuild-jq.calls"
  rebuild_jq_args="$work/batch-rebuild-jq.args"
  : > "$rebuild_jq_calls"
  : > "$rebuild_jq_args"
  jq() {
    printf 'jq\n' >> "$rebuild_jq_calls"
    printf '%s\0' "$@" >> "$rebuild_jq_args"
    command jq "$@"
  }
  rebuild_protocol_inbounds ss2022
  [[ "$(wc -l < "$rebuild_jq_calls" | tr -d ' ')" == 2 ]]
  if tr '\0' '\n' < "$rebuild_jq_args" | grep -Fq 'st-secret'; then
    echo 'unexpected st-secret in $rebuild_jq_args' >&2
    exit 1
  fi
  if tr '\0' '\n' < "$rebuild_jq_args" | grep -Fq 'direct-secret'; then
    echo 'unexpected direct-secret in $rebuild_jq_args' >&2
    exit 1
  fi
  if tr '\0' '\n' < "$rebuild_jq_args" | grep -Fq 'any-secret'; then
    echo 'unexpected any-secret in $rebuild_jq_args' >&2
    exit 1
  fi
  command jq -e '
    (.inbounds | length) == 198 and
    .inbounds[0].tag == "external-a" and .inbounds[1].tag == "external-b" and
    .inbounds[2].tag == "st-user0" and .inbounds[3].tag == "ss-user0" and
    .inbounds[4].tag == "ss-udp-user0" and .inbounds[5].tag == "ss-direct-user0" and
    (all(.inbounds[]; .tag != "st-user49" and .tag != "ss-user49" and .tag != "ss-udp-user49" and .tag != "ss-direct-user49"))
  ' "$SINGBOX_CONFIG" >/dev/null
  printf '%s\n' '{"inbounds":[{"type":"direct","tag":"external-a"},{"type":"direct","tag":"anytls-user0"},{"type":"direct","tag":"external-b"}],"outbounds":[],"route":{"rules":[],"rule_set":[]}}' > "$SINGBOX_CONFIG"
  : > "$rebuild_jq_calls"
  rebuild_protocol_inbounds anytls
  [[ "$(wc -l < "$rebuild_jq_calls" | tr -d ' ')" == 2 ]]
  command jq -e '
    (.inbounds | length) == 51 and
    .inbounds[0].tag == "external-a" and .inbounds[1].tag == "external-b" and
    .inbounds[2].tag == "anytls-user0" and
    (all(.inbounds[]; .tag != "anytls-user49"))
  ' "$SINGBOX_CONFIG" >/dev/null
  cp -- "$SINGBOX_CONFIG" "$SINGBOX_CONFIG.before-invalid-state"
  command jq '.users[0].status = null' "$STATE_FILE" > "$STATE_FILE.tmp"
  mv -- "$STATE_FILE.tmp" "$STATE_FILE"
  if rebuild_protocol_inbounds ss2022 >/dev/null 2>&1; then
    echo 'invalid active user state must stop protocol rebuild' >&2
    exit 1
  fi
  cmp -s "$SINGBOX_CONFIG.before-invalid-state" "$SINGBOX_CONFIG"
  printf '%s\n' '{"users":[{"name":null,"status":null,"endpoints":[{"protocol":"anytls","port":22001,"anytls_password":"secret"}]}]}' > "$STATE_FILE"
  [[ "$(build_user_inbound_payload rebuild ss2022 "$STATE_FILE")" == '{"managed_tags":[],"inbounds":[]}' ]]
  printf '%s\n' '{"users":[{"name":null,"status":null,"endpoints":[{"protocol":"ss2022","transport":"direct","port":22001,"ss2022_password":"secret","method":"2022-blake3-aes-128-gcm"}]}]}' > "$STATE_FILE"
  [[ "$(build_user_inbound_payload rebuild anytls "$STATE_FILE")" == '{"managed_tags":[],"inbounds":[]}' ]]
  printf '%s\n' '{"users":[{"name":123,"status":true,"endpoints":[{"protocol":"anytls","port":22001,"anytls_password":"secret"}]}]}' > "$STATE_FILE"
  [[ "$(build_user_inbound_payload rebuild anytls "$STATE_FILE")" == '{"managed_tags":["anytls-123"],"inbounds":[]}' ]]
)

# 异常旧状态继续走原实现，保留对象用户名的 pretty JSON tag 与顶层 users 损坏时的失败语义。
(
  STATE_FILE="$work/batch-rebuild-legacy-fallback-state.json"
  SINGBOX_CONFIG="$work/batch-rebuild-legacy-fallback-config.json"
  SINGBOX_BIN=mock_singbox
  printf '%s\n' '{"users":[{"name":{"x":1},"status":"active","endpoints":[{"protocol":"ss2022","transport":"direct","port":22001,"ss2022_password":"secret","method":"2022-blake3-aes-128-gcm"}]}]}' > "$STATE_FILE"
  printf '%s\n' '{"inbounds":[],"outbounds":[],"route":{"rules":[],"rule_set":[]}}' > "$SINGBOX_CONFIG"
  rebuild_protocol_inbounds ss2022
  legacy_object_name="$(command jq -r '.' <<<'{"x":1}')"
  command jq -e --arg tag "ss-$legacy_object_name" 'any(.inbounds[]; .tag == $tag)' "$SINGBOX_CONFIG" >/dev/null
  printf '%s\n' '{"users":null}' > "$STATE_FILE"
  printf '%s\n' '{"inbounds":[{"type":"direct","tag":"external"}],"outbounds":[],"route":{"rules":[],"rule_set":[]}}' > "$SINGBOX_CONFIG"
  rebuild_protocol_inbounds ss2022 2>/dev/null
  command jq -e '(.inbounds | length) == 1 and .inbounds[0].tag == "external"' "$SINGBOX_CONFIG" >/dev/null
)

(
  STATE_FILE="$work/udp-upgrade-state.json"
  SINGBOX_CONFIG="$work/udp-upgrade-config.json"
  SINGBOX_BIN=mock_singbox
  HANDSHAKE_PORT=443
  SHADOWTLS_STRICT_MODE=true
  # 历史扁平状态的重建始终按 ShadowTLS 解释，即使残留了 transport=direct 字段。
  printf '%s\n' '{"schema_version":3,"users":[{"name":"legacy-active","port":20031,"transport":"direct","status":"active","metered":false,"shadowtls_password":"legacy-st","ss2022_password":"legacy-ss","method":"2022-blake3-aes-128-gcm","shadowtls_sni":"legacy.example.com"},{"name":"legacy-disabled","port":20032,"status":"disabled","metered":false,"shadowtls_password":"disabled-st","ss2022_password":"disabled-ss","method":"2022-blake3-aes-128-gcm","shadowtls_sni":"disabled.example.com"}],"splits":[]}' > "$STATE_FILE"
  printf '%s\n' '{"inbounds":[{"type":"direct","tag":"external-in"},{"type":"shadowtls","tag":"st-legacy-active","listen":"::","listen_port":20031},{"type":"shadowsocks","tag":"ss-legacy-active","network":"tcp","method":"2022-blake3-aes-128-gcm","password":"legacy-ss"}],"outbounds":[],"route":{"rules":[],"rule_set":[]}}' > "$SINGBOX_CONFIG"
  if ss2022_udp_inbounds_are_current; then
    echo 'legacy SS2022 config without UDP inbound should require migration' >&2
    exit 1
  fi
  rebuild_protocol_inbounds ss2022
  ss2022_udp_inbounds_are_current
  jq -e '
    any(.inbounds[]; .tag == "external-in") and
    any(.inbounds[]; .tag == "st-legacy-active") and
    any(.inbounds[]; .tag == "ss-legacy-active" and .network == "tcp") and
    any(.inbounds[]; .tag == "ss-udp-legacy-active" and .network == "udp" and .listen_port == 20031) and
    all(.inbounds[]; .tag != "st-legacy-disabled" and .tag != "ss-legacy-disabled" and .tag != "ss-udp-legacy-disabled")
  ' "$SINGBOX_CONFIG" >/dev/null
)

(
  STATE_FILE="$work/udp-export-state.json"
  PUBLIC_SERVER=203.0.113.10
  CLIENT_SERVER_PORT_OVERRIDE=""
  printf '%s\n' '{"schema_version":3,"users":[{"name":"udp-export","port":20033,"status":"active","metered":false,"shadowtls_password":"export-st","ss2022_password":"export-ss","method":"2022-blake3-aes-128-gcm","shadowtls_sni":"export.example.com"}],"splits":[]}' > "$STATE_FILE"
  cmd_export udp-export surge
) > "$work/udp-export.txt"
grep -Fq 'udp-relay=true' "$work/udp-export.txt"
if grep -Fq 'udp-port=' "$work/udp-export.txt"; then
  echo 'unexpected udp-port= in $work/udp-export.txt' >&2
  exit 1
fi

[[ "$(url_percent_encode '节点 #+/')" == '%E8%8A%82%E7%82%B9%20%23%2B%2F' ]]

(
  STATE_FILE="$work/shadowrocket-export-state.json"
  PUBLIC_SERVER=198.51.100.20
  CLIENT_SERVER_PORT_OVERRIDE=24443
  printf '%s\n' '{"schema_version":3,"users":[{"name":"sr-ss","port":20041,"status":"active","metered":false,"shadowtls_password":"dummy/shadow+secret=","ss2022_password":"MDEyMzQ1Njc4OWFiY2RlZg==","method":"2022-blake3-aes-128-gcm","shadowtls_sni":"ss.example.com"},{"name":"sr-at","port":20042,"protocol":"anytls","status":"active","metered":false,"anytls_password":"dummy@+/ pass","tls_sni":"at.example.com"}],"splits":[]}' > "$STATE_FILE"
  cmd_export sr-ss shadowrocket
  cmd_export sr-at shadowrocket
) > "$work/shadowrocket-urls.txt"
if grep -Fq 'shadow-tls-password=' "$work/shadowrocket-urls.txt"; then
  echo 'unexpected shadow-tls-password= in $work/shadowrocket-urls.txt' >&2
  exit 1
fi
if grep -Fq '=anytls,' "$work/shadowrocket-urls.txt"; then
  echo 'unexpected =anytls, in $work/shadowrocket-urls.txt' >&2
  exit 1
fi
python3 - "$work/shadowrocket-urls.txt" <<'PY'
import base64
import json
import sys
from urllib.parse import parse_qs, unquote, urlsplit

lines = [line.strip() for line in open(sys.argv[1], encoding="utf-8")]
ss_url = next(line for line in lines if line.startswith("ss://"))
at_url = next(line for line in lines if line.startswith("anytls://"))

ss = urlsplit(ss_url)
credentials = base64.b64decode(ss.netloc + "===").decode()
assert credentials == "2022-blake3-aes-128-gcm:MDEyMzQ1Njc4OWFiY2RlZg==@198.51.100.20:24443"
plugin = parse_qs(ss.query, strict_parsing=True)["shadow-tls"][0]
plugin_json = json.loads(base64.b64decode(plugin + "===").decode())
assert plugin_json == {
    "version": "3",
    "host": "ss.example.com",
    "password": "dummy/shadow+secret=",
}
assert unquote(ss.fragment) == "sr-ss"

at = urlsplit(at_url)
assert unquote(at.username) == "dummy@+/ pass"
assert at.hostname == "198.51.100.20" and at.port == 24443
assert parse_qs(at.query, strict_parsing=True) == {
    "peer": ["at.example.com"],
    "insecure": ["1"],
    "udp": ["1"],
}
assert unquote(at.fragment) == "sr-at"
PY

(
  STATE_FILE="$work/direct-export-state.json"
  PUBLIC_SERVER=198.51.100.21
  CLIENT_SERVER_PORT_OVERRIDE=""
  printf '%s\n' '{"schema_version":6,"users":[{"name":"direct-ss","port":20043,"protocol":"ss2022","transport":"direct","status":"active","metered":false,"ss2022_password":"MDEyMzQ1Njc4OWFiY2RlZg==","method":"2022-blake3-aes-128-gcm","endpoints":[{"protocol":"ss2022","transport":"direct","port":20043,"ss2022_password":"MDEyMzQ1Njc4OWFiY2RlZg==","method":"2022-blake3-aes-128-gcm"}]}],"splits":[],"outbound_presets":[],"rule_presets":[]}' > "$STATE_FILE"
  cmd_export direct-ss all
) > "$work/direct-export.txt"
grep -Fq 'direct-ss = ss, 198.51.100.21, 20043, encrypt-method=2022-blake3-aes-128-gcm, password=MDEyMzQ1Njc4OWFiY2RlZg==, udp-relay=true' "$work/direct-export.txt"
if grep -Fq 'shadow-tls-' "$work/direct-export.txt"; then
  echo 'unexpected shadow-tls- in $work/direct-export.txt' >&2
  exit 1
fi
python3 - "$work/direct-export.txt" <<'PY'
import base64
import sys
from urllib.parse import unquote, urlsplit

url = next(line.strip() for line in open(sys.argv[1], encoding="utf-8") if line.startswith("ss://"))
parsed = urlsplit(url)
assert base64.b64decode(parsed.username + "===").decode() == "2022-blake3-aes-128-gcm:MDEyMzQ1Njc4OWFiY2RlZg=="
assert parsed.hostname == "198.51.100.21" and parsed.port == 20043
assert parsed.query == ""
assert unquote(parsed.fragment) == "direct-ss"
PY

qrencode_args="$work/shadowrocket-qr-args"
(
  qrencode() {
    printf '%s\0' "$@" > "$qrencode_args"
    printf 'qr:%s\n' "$(cat)"
  }
  print_shadowrocket_qr 'anytls://dummy-qr-secret@198.51.100.20:24443#sr-at'
) < /dev/null > "$work/shadowrocket-qr.txt"
grep -Fq 'qr:anytls://dummy-qr-secret@198.51.100.20:24443#sr-at' "$work/shadowrocket-qr.txt"
[[ "$(tr '\0' '|' < "$qrencode_args")" == '-t|ANSIUTF8|-l|L|-m|1|' ]]
if tr '\0' '\n' < "$qrencode_args" | grep -Fq 'dummy-qr-secret'; then
  echo '导入链接含明文密码，不能作为命令行参数出现在 qrencode 的 argv 里' >&2
  exit 1
fi

ipv6_anytls_url="$(PUBLIC_SERVER=2001:db8::1 shadowrocket_anytls_url '{"name":"ipv6-at","port":24444,"anytls_password":"dummy","tls_sni":"ipv6.example.com"}')"
grep -Fq 'anytls://dummy@[2001:db8::1]:24444?' <<<"$ipv6_anytls_url"

stored_anytls_user='{"name":"stored-at","port":20008,"protocol":"anytls","status":"active","metered":true,"anytls_password":"stored-at-secret","tls_sni":"client.example.com"}'
stored_anytls_fragment="$(make_user_inbounds_from_state "$stored_anytls_user")"
jq -e '
  length == 1 and
  .[0].tag == "anytls-stored-at" and
  .[0].listen_port == 20008 and
  .[0].users[0].password == "stored-at-secret" and
  .[0].tls.certificate_path == "/etc/sing-box/cert/anytls.crt" and
  .[0].tls.key_path == "/etc/sing-box/cert/anytls.key"
' <<<"$stored_anytls_fragment" >/dev/null
if make_user_inbounds_from_state '{"name":"invalid-at","port":20008,"protocol":"anytls"}' >/dev/null 2>&1; then
  echo 'AnyTLS state without password should be rejected' >&2
  exit 1
fi
if make_user_inbounds_from_state '{"name":"invalid-ss","port":20008,"shadowtls_password":"st","ss2022_password":"ss","method":"2022-blake3-aes-128-gcm"}' >/dev/null 2>&1; then
  echo 'SS2022 state without ShadowTLS SNI should be rejected' >&2
  exit 1
fi

printf '%s\n' '{"inbounds":[{"type":"direct","tag":"external-in"},{"type":"anytls","tag":"anytls-stored-ss"},{"type":"snell","tag":"snell-stored-ss"}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[],"rule_set":[]}}' > "$SINGBOX_CONFIG"
chmod 640 "$SINGBOX_CONFIG"
append_inbounds "$stored_ss_fragment"
append_inbounds "$stored_anytls_fragment"
jq -e '
  (.inbounds | length) == 7 and
  any(.inbounds[]; .tag == "external-in") and
  any(.inbounds[]; .tag == "st-stored-ss") and
  any(.inbounds[]; .tag == "ss-stored-ss") and
  any(.inbounds[]; .tag == "ss-udp-stored-ss") and
  any(.inbounds[]; .tag == "anytls-stored-at")
' "$SINGBOX_CONFIG" >/dev/null
config_mode="$(stat -c '%a' "$SINGBOX_CONFIG" 2>/dev/null || stat -f '%Lp' "$SINGBOX_CONFIG")"
if chmod --version >/dev/null 2>&1; then
  [[ "$config_mode" == 640 ]]
else
  # macOS/BSD chmod 不支持 --reference，脚本的安全回退固定为 600。
  [[ "$config_mode" == 600 ]]
fi

remove_user_inbounds stored-ss
jq -e '
  (.inbounds | length) == 2 and
  any(.inbounds[]; .tag == "external-in") and
  any(.inbounds[]; .tag == "anytls-stored-at") and
  (all(.inbounds[];
    .tag != "st-stored-ss" and
    .tag != "ss-stored-ss" and
    .tag != "ss-udp-stored-ss" and
    .tag != "anytls-stored-ss" and
    .tag != "snell-stored-ss"))
' "$SINGBOX_CONFIG" >/dev/null

(
  STATE_FILE="$work/global-sni-state.json"
  SINGBOX_CONFIG="$work/global-sni-config.json"
  CONF_FILE="$work/global-sni-manager.conf"
  BACKUP_DIR="$work/global-sni-backups"
  sni_events="$work/global-sni-events"
  mkdir -p "$BACKUP_DIR"
  printf '%s\n' \
    'SS2022_SHADOWTLS_SNI="old-ss.example.com"' \
    'ANYTLS_SNI="old-any.example.com"' > "$CONF_FILE"
  printf '%s\n' '{"schema_version":3,"users":[{"name":"ss-active","port":20021,"status":"active","metered":false,"shadowtls_password":"st1","ss2022_password":"ss1","method":"2022-blake3-aes-128-gcm","shadowtls_sni":"user-ss.example.com"},{"name":"ss-disabled","port":20022,"status":"disabled","metered":false,"shadowtls_password":"st2","ss2022_password":"ss2","method":"2022-blake3-aes-128-gcm","shadowtls_sni":"other-ss.example.com"},{"name":"at-active","port":20023,"protocol":"anytls","status":"active","metered":false,"anytls_password":"at1","tls_sni":"user-any.example.com"}],"splits":[]}' > "$STATE_FILE"
  printf '%s\n' '{"inbounds":[{"type":"direct","tag":"external-in"},{"type":"shadowtls","tag":"st-ss-active","listen_port":20021},{"type":"shadowsocks","tag":"ss-ss-active"},{"type":"anytls","tag":"anytls-at-active","listen_port":20023}],"outbounds":[],"route":{"rules":[],"rule_set":[]}}' > "$SINGBOX_CONFIG"
  SS2022_SHADOWTLS_SNI=old-ss.example.com
  ANYTLS_SNI=old-any.example.com
  HANDSHAKE_PORT=443
  SHADOWTLS_STRICT_MODE=true
  global_singbox() {
    case "${1:-}" in
      format) jq . "$3";;
      check) jq -e 'type == "object"' "$3" >/dev/null;;
      *) return 64;;
    esac
  }
  SINGBOX_BIN=global_singbox
  SINGBOX_SERVICE=sing-box
  systemctl() { printf 'systemctl:%s\n' "$*" >> "$sni_events"; }
  sync_transaction_path() { return 0; }
  start_managed_operation() { printf 'start:%s\n' "$1" >> "$sni_events"; }
  finish_managed_operation() { printf 'finish\n' >> "$sni_events"; }

  cmd_set_global_sni ss2022 new-ss.example.com >/dev/null
  grep -Fxq 'SS2022_SHADOWTLS_SNI="new-ss.example.com"' "$CONF_FILE"
  grep -Fxq 'ANYTLS_SNI="old-any.example.com"' "$CONF_FILE"
  jq -e '
    all(.users[] | select((.protocol // "ss2022") == "ss2022"); .shadowtls_sni == "new-ss.example.com") and
    (.users[] | select(.name == "at-active") | .tls_sni) == "user-any.example.com"
  ' "$STATE_FILE" >/dev/null
  jq -e '
    any(.inbounds[]; .tag == "external-in") and
    any(.inbounds[]; .tag == "st-ss-active" and .handshake.server == "new-ss.example.com") and
    any(.inbounds[]; .tag == "ss-ss-active") and
    any(.inbounds[]; .tag == "ss-udp-ss-active" and .network == "udp" and .listen_port == 20021) and
    any(.inbounds[]; .tag == "anytls-at-active") and
    all(.inbounds[]; .tag != "st-ss-disabled" and .tag != "ss-ss-disabled" and .tag != "ss-udp-ss-disabled")
  ' "$SINGBOX_CONFIG" >/dev/null
  grep -Fxq 'start:set-global-sni:ss2022' "$sni_events"
  grep -Fxq 'systemctl:restart sing-box' "$sni_events"

  cp "$SINGBOX_CONFIG" "$work/global-sni-before-anytls.json"
  : > "$sni_events"
  cmd_set_global_sni anytls new-any.example.com >/dev/null
  grep -Fxq 'ANYTLS_SNI="new-any.example.com"' "$CONF_FILE"
  jq -e '(.users[] | select(.name == "at-active") | .tls_sni) == "new-any.example.com"' "$STATE_FILE" >/dev/null
  cmp -s "$SINGBOX_CONFIG" "$work/global-sni-before-anytls.json"
  if grep -Fq 'systemctl:' "$sni_events"; then
    echo 'unexpected systemctl: in $sni_events' >&2
    exit 1
  fi
)

(
  STATE_FILE="$work/edit-user-state.json"
  SINGBOX_CONFIG="$work/edit-user-config.json"
  BACKUP_DIR="$work/edit-user-backups"
  edit_events="$work/edit-user-events"
  PORT_MIN=20001
  PORT_MAX=30000
  mkdir -p "$BACKUP_DIR"
  printf '%s\n' '{"schema_version":3,"users":[{"name":"alice","port":20001,"status":"active","metered":true,"limit_gib":2,"billing_anchor":5,"expires_at":"2026-08-15T00:00:00+0800","created_at":"2026-07-15T00:00:00+0800","shadowtls_password":"st-keep","ss2022_password":"ss-old","method":"2022-blake3-aes-128-gcm","shadowtls_sni":"old.example.com"}],"splits":[]}' > "$STATE_FILE"
  printf '%s\n' '{"inbounds":[{"type":"direct","tag":"external-in"},{"type":"shadowtls","tag":"st-alice","listen_port":20001},{"type":"shadowsocks","tag":"ss-alice","method":"2022-blake3-aes-128-gcm"}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[],"rule_set":[]}}' > "$SINGBOX_CONFIG"
  HANDSHAKE_PORT=443
  SHADOWTLS_STRICT_MODE=true
  edit_singbox() {
    case "${1:-}" in
      format) jq . "$3";;
      check) jq -e 'type == "object"' "$3" >/dev/null;;
      *) return 64;;
    esac
  }
  SINGBOX_BIN=edit_singbox
  # 密钥生成已不经内核，因此桩在这里而不是内核桩的 generate 分支上。
  # 内核桩保留 *) return 64，若将来又有人让内核去生成密钥，这个用例会立刻失败。
  generate_random_base64() { printf 'ss-new-secret\n'; }
  SINGBOX_SERVICE=sing-box
  port_is_listening() { return 1; }
  systemctl() { printf 'systemctl:%s\n' "$*" >> "$edit_events"; }
  start_managed_operation() { printf 'start:%s\n' "$1" >> "$edit_events"; }
  finish_managed_operation() { printf 'finish\n' >> "$edit_events"; }
  cmd_export() { printf 'export:%s\n' "$1" >> "$edit_events"; }
  date() {
    if [[ "${1:-}" == -d ]]; then printf '1786723200\n'; else command date "$@"; fi
  }
  nfuse() {
    if [[ "${1:-}" == list ]]; then
      printf '%s\n' '[{"id":7,"name":"alice","tier":"a","limit_gib":2,"limit_bytes":2147483648,"used_bytes":123,"ports":[{"id":42,"start":20001,"end":20001}]}]'
    else
      printf 'nfuse:%s\n' "$*" >> "$edit_events"
    fi
  }

  cmd_edit_user alice 20002 new.example.com 2022-blake3-aes-256-gcm 9 2026-10-15T00:00:00+0800 >/dev/null
  jq -e '
    .users[0].port == 20002 and
    .users[0].shadowtls_sni == "new.example.com" and
    .users[0].method == "2022-blake3-aes-256-gcm" and
    .users[0].ss2022_password == "ss-new-secret" and
    .users[0].shadowtls_password == "st-keep" and
    .users[0].billing_anchor == 9 and
    .users[0].expires_at == "2026-10-15T00:00:00+0800"
  ' "$STATE_FILE" >/dev/null
  jq -e '
    any(.inbounds[]; .tag == "external-in") and
    any(.inbounds[]; .tag == "st-alice" and .listen_port == 20002 and .handshake.server == "new.example.com") and
    any(.inbounds[]; .tag == "ss-alice" and .method == "2022-blake3-aes-256-gcm" and .password == "ss-new-secret") and
    any(.inbounds[]; .tag == "ss-udp-alice" and .listen_port == 20002 and .network == "udp" and .method == "2022-blake3-aes-256-gcm" and .password == "ss-new-secret") and
    all(.inbounds[]; (.tag != "st-alice" and .tag != "ss-alice" and .tag != "ss-udp-alice") or (.listen_port == 20002 or .method == "2022-blake3-aes-256-gcm"))
  ' "$SINGBOX_CONFIG" >/dev/null
  grep -Fxq 'start:edit-user:alice' "$edit_events"
  grep -Fxq 'nfuse:port add alice 20002' "$edit_events"
  grep -Fxq 'nfuse:port rm 42' "$edit_events"
  add_line="$(grep -n 'nfuse:port add alice 20002' "$edit_events" | cut -d: -f1)"
  restart_line="$(grep -n 'systemctl:restart sing-box' "$edit_events" | cut -d: -f1)"
  remove_line="$(grep -n 'nfuse:port rm 42' "$edit_events" | cut -d: -f1)"
  ((add_line < restart_line && restart_line < remove_line))
  grep -Fxq 'nfuse:set-tier alice --tier a --limit 2 --anchor 9' "$edit_events"
  [[ "$(grep -Fc 'nfuse:persist' "$edit_events")" == 2 ]]
  grep -Fxq 'export:alice' "$edit_events"
  [[ "$(grep -Fc finish "$edit_events")" == 1 ]]
)

(
  STATE_FILE="$work/edit-disabled-state.json"
  SINGBOX_CONFIG="$work/edit-disabled-config.json"
  PORT_MIN=20001
  PORT_MAX=30000
  printf '%s\n' '{"schema_version":3,"users":[{"name":"bob","port":8443,"protocol":"anytls","status":"disabled","metered":false,"anytls_password":"keep-secret","tls_sni":"old.example.com","expires_at":null,"limit_gib":null,"billing_anchor":null,"created_at":"2026-07-15T00:00:00+0800"}],"splits":[]}' > "$STATE_FILE"
  printf '%s\n' '{"inbounds":[{"type":"direct","tag":"external-in"}],"outbounds":[],"route":{"rules":[],"rule_set":[]}}' > "$SINGBOX_CONFIG"
  cp "$SINGBOX_CONFIG" "$work/edit-disabled-config.before.json"
  port_is_listening() { return 1; }
  start_managed_operation() { :; }
  finish_managed_operation() { :; }
  cmd_export() { printf 'disabled-export\n' > "$work/edit-disabled-export"; }
  nfuse() { printf 'unexpected nfuse call\n' >&2; return 88; }
  check_singbox_and_restart() { printf 'unexpected restart\n' >&2; return 89; }
  cmd_edit_user bob 8443 new.example.com '' '' '' >/dev/null
  jq -e '.users[0].port == 8443 and .users[0].tls_sni == "new.example.com" and .users[0].status == "disabled" and .users[0].anytls_password == "keep-secret"' "$STATE_FILE" >/dev/null
  cmp -s "$SINGBOX_CONFIG" "$work/edit-disabled-config.before.json"
  grep -Fxq disabled-export "$work/edit-disabled-export"
)

(
  STATE_FILE="$work/edit-secondary-endpoint-state.json"
  PORT_MIN=20001
  PORT_MAX=30000
  printf '%s\n' '{"schema_version":5,"users":[{"name":"dual-edit","port":21001,"protocol":"ss2022","status":"disabled","metered":false,"expires_at":null,"limit_gib":null,"billing_anchor":null,"usage_offset_bytes":0,"created_at":"2026-08-10T00:00:00+0800","shadowtls_password":"st","ss2022_password":"ss","method":"2022-blake3-aes-128-gcm","shadowtls_sni":"ss.example.com","endpoints":[{"protocol":"ss2022","port":21001,"shadowtls_password":"st","ss2022_password":"ss","method":"2022-blake3-aes-128-gcm","shadowtls_sni":"ss.example.com"},{"protocol":"anytls","port":21002,"anytls_password":"at","tls_sni":"old-at.example.com"}]}],"splits":[],"outbound_presets":[],"rule_presets":[]}' > "$STATE_FILE"
  start_managed_operation() { :; }
  finish_managed_operation() { :; }
  cmd_export() { :; }
  nfuse() { printf 'unexpected nfuse call\n' >&2; return 88; }
  check_singbox_and_restart() { printf 'unexpected restart\n' >&2; return 89; }
  cmd_edit_user dual-edit 21002 new-at.example.com '' '' '' anytls >/dev/null
  jq -e '
    .users[0].protocol == "ss2022" and .users[0].port == 21001 and
    .users[0].shadowtls_sni == "ss.example.com" and
    (.users[0].endpoints[] | select(.protocol == "anytls") |
      .port == 21002 and .anytls_password == "at" and .tls_sni == "new-at.example.com")
  ' "$STATE_FILE" >/dev/null
)

(
  rollback_marker="$work/edit-user-rollback"
  later_step_marker="$work/edit-user-later-step"
  PORT_MIN=20001
  PORT_MAX=30000
  user_exists() { return 0; }
  get_user_json() { printf '%s\n' '{"name":"failure","port":20010,"status":"active","metered":false,"shadowtls_password":"st","ss2022_password":"ss","method":"2022-blake3-aes-128-gcm","shadowtls_sni":"old.example.com"}'; }
  port_in_state() { return 1; }
  port_is_listening() { return 1; }
  nfuse() {
    if [[ "${1:-}" == list ]]; then
      printf '%s\n' '[{"name":"failure","tier":"c","used_bytes":0,"ports":[{"id":77,"start":20010,"end":20010}]}]'
    else
      return 0
    fi
  }
  make_user_inbounds_from_state() { printf '[]\n'; }
  start_managed_operation() { return 0; }
  state_replace_user() { return 0; }
  replace_user_inbounds() { return 77; }
  rollback_active_operation() { printf '%s\n' "$1" > "$rollback_marker"; return "$1"; }
  check_singbox_and_restart() { printf 'unexpected\n' > "$later_step_marker"; }
  finish_managed_operation() { printf 'unexpected\n' > "$later_step_marker"; }
  cmd_export() { printf 'unexpected\n' > "$later_step_marker"; }
  if cmd_edit_user failure 20011 new.example.com 2022-blake3-aes-128-gcm '' '' >/dev/null 2>&1; then
    echo 'edit user should propagate config replacement failure' >&2
    exit 1
  fi
  grep -Fxq 77 "$rollback_marker"
  [[ ! -e "$later_step_marker" ]]
)

(
  STATE_FILE="$work/edit-conflict-state.json"
  transaction_marker="$work/edit-conflict-transaction"
  PORT_MIN=20001
  PORT_MAX=30000
  printf '%s\n' '{"schema_version":3,"users":[{"name":"target","port":20010,"status":"disabled","metered":false,"shadowtls_password":"st","ss2022_password":"ss","method":"2022-blake3-aes-128-gcm","shadowtls_sni":"old.example.com"},{"name":"occupied","port":20011,"status":"active","metered":false}],"splits":[]}' > "$STATE_FILE"
  start_managed_operation() { printf 'unexpected\n' > "$transaction_marker"; }
  if (cmd_edit_user target 20011 old.example.com 2022-blake3-aes-128-gcm '' '' >/dev/null 2>&1); then
    echo 'edit user should reject a port owned by another managed user' >&2
    exit 1
  fi
  [[ ! -e "$transaction_marker" ]]
)

split_upstream='{"protocol":"ss_shadowtls","server":"upstream.example.com","server_port":443,"method":"2022-blake3-aes-128-gcm","ss_password":"split-secret","shadowtls_password":"transport-secret","sni":"upstream.example.com","insecure":false}'
printf '%s\n' '{"schema_version":6,"users":[{"name":"stored-at","port":20008,"protocol":"anytls","status":"active","metered":false,"anytls_password":"stored-at-secret","tls_sni":"client.example.com","endpoints":[{"protocol":"anytls","port":20008,"anytls_password":"stored-at-secret","tls_sni":"client.example.com"},{"protocol":"ss2022","transport":"direct","port":20009,"ss2022_password":"stored-direct-secret","method":"2022-blake3-aes-128-gcm"}]}],"splits":[],"outbound_presets":[],"rule_presets":[]}' > "$STATE_FILE"
SB_JQ_SPLIT="$split_upstream" jq -c '
  ($ENV.SB_JQ_SPLIT | fromjson) as $upstream |
  .splits = [{name:"unit-split",url:"https://rules.example.com/unit.srs",scope:"user",user:"stored-at",
    upstream:$upstream,outbound_tag:"unit-out",rule_set_tag:"unit-rule",status:"active"}]' \
  "$STATE_FILE" > "$work/unit-split-state.json"
mv "$work/unit-split-state.json" "$STATE_FILE"
rebuild_all_split_configs
jq -e '
  any(.outbounds[]; .tag == "direct") and
  any(.outbounds[]; .tag == "unit-out" and .server == "upstream.example.com") and
  any(.outbounds[]; .tag == "managed-transport-unit-split" and .server == "upstream.example.com") and
  any(.route.rule_set[]; .tag == "unit-rule" and .format == "binary") and
  any(.route.rules[]; .rule_set == "unit-rule" and .outbound == "unit-out" and
    (.inbound | index("ss-stored-at")) and
    (.inbound | index("anytls-stored-at")) and
    (.inbound | index("st-stored-at") | not) and
    (.inbound | index("ss-udp-stored-at") | not))
' "$SINGBOX_CONFIG" >/dev/null
printf '%s\n' '{"schema_version":3,"users":[],"splits":[{"name":"unit-split","rule_set_tag":"unit-rule","outbound_tag":"unit-out"}]}' > "$STATE_FILE"
remove_split_config unit-split
jq -e '
  any(.outbounds[]; .tag == "direct") and
  (all(.outbounds[]; .tag != "unit-out")) and
  (all(.outbounds[]; .tag != "managed-transport-unit-split")) and
  (all(.route.rule_set[]; .tag != "unit-rule")) and
  (all(.route.rules[]; .rule_set != "unit-rule"))
' "$SINGBOX_CONFIG" >/dev/null

(
  getent() {
    [[ "$1" == ahosts && "$2" == rules.example.com ]] || return 2
    printf '%s\n' '93.184.216.34 STREAM rules.example.com'
  }
  curl() {
    local output="" url="${!#}" index
    for ((index=1; index<=$#; index++)); do
      if [[ "${!index}" == --output ]]; then index=$((index+1)); output="${!index}"; break; fi
    done
    case "$url" in
      *.json) printf '%s\n' '{"version":3,"rules":[]}' > "$output";;
      *.srs) printf 'binary-fixture\n' > "$output";;
      *) printf 'invalid\n' > "$output";;
    esac
  }
  ruleset_singbox() {
    if [[ "$1 $2" == 'rule-set compile' ]]; then
      printf 'compiled\n' > "$4"
    elif [[ "$1 $2" == 'rule-set decompile' ]]; then
      printf '%s\n' '{"version":3,"rules":[]}' > "$4"
    else
      return 1
    fi
  }
  SINGBOX_BIN=ruleset_singbox
  validate_split_rule_source https://rules.example.com/valid.json
  validate_split_rule_source https://rules.example.com/valid.srs
)
set +e
(
  getent() {
    [[ "$1" == ahosts && "$2" == rules.example.com ]] || return 2
    printf '%s\n' '93.184.216.34 STREAM rules.example.com'
  }
  curl() {
    local output="" index
    for ((index=1; index<=$#; index++)); do
      if [[ "${!index}" == --output ]]; then index=$((index+1)); output="${!index}"; break; fi
    done
    printf '%s\n' '{"not":"a-rule-set"}' > "$output"
  }
  SINGBOX_BIN=true
  validate_split_rule_source https://rules.example.com/invalid.json
) >/dev/null 2>&1
invalid_ruleset_rc=$?
set -e
[[ "$invalid_ruleset_rc" != 0 ]]

(
  prompt_split_upstream_fields shadowsocks '{"protocol":"shadowsocks","server":"keep.example.com","server_port":443,"method":"aes-256-gcm","password":"keep-secret"}' <<'EOF'




EOF
  jq -e '.protocol == "shadowsocks" and .server == "keep.example.com" and .server_port == 443 and .method == "aes-256-gcm" and .password == "keep-secret"' <<<"$PROMPTED_SPLIT_UPSTREAM" >/dev/null
)

# 分流标签收集必须保持旧标签、运行标签、稳定摘要以及 jq unique 的字典序语义。
(
  STATE_FILE="$work/managed-split-tags-golden.json"
  printf '%s\n' '{"splits":[
    {"name":"alpha","rule_preset":"AI","outbound_preset":"Hinet","rule_set_tag":"z-rule","outbound_tag":"z-out"},
    {"name":"beta","rule_preset":"AI","outbound_preset":"Hinet","rule_set_tag":"a-rule","outbound_tag":"a-out"},
    {"name":"gamma","runtime_rule_tag":"explicit-rule","runtime_outbound_tag":"explicit-out","runtime_transport_tag":"explicit-transport","rule_set_tag":"gamma-rule","outbound_tag":"gamma-out"}
  ]}' > "$STATE_FILE"
  expected='{"rule_tags":["a-rule","explicit-rule","gamma-rule","mpr-f052daa870ac655071c548ad","z-rule"],"out_tags":["a-out","explicit-out","gamma-out","mpo-4d35dfa55179af04d424f1ab","z-out"],"transport_tags":["explicit-transport","managed-transport-alpha","managed-transport-beta","managed-transport-gamma","mpt-ced47d379049ed35b7fabc43"]}'
  [[ "$(collect_managed_split_tags)" == "$expected" ]]
  printf '%s\n' '{"splits":[]}' > "$STATE_FILE"
  [[ "$(collect_managed_split_tags)" == '{"rule_tags":[],"out_tags":[],"transport_tags":[]}' ]]
)

# 异常分隔符和 Unicode 预置也必须与原有 shell 路径逐字节一致；缺少 Python 时安全回退。
(
  STATE_FILE="$work/managed-split-tags-edge.json"
  printf '%s\n' '{"splits":[
    {"name":"pipe-name","rule_preset":"规则|集","outbound_preset":"出口|一","rule_set_tag":"legacy|rule","outbound_tag":"legacy|out"}
  ]}' > "$STATE_FILE"
  expected="$(collect_managed_split_tags_with_shell_tools)"
  [[ "$(collect_managed_split_tags)" == "$expected" ]]
  printf '%s\n' '{"splits":[
    {"name":"numeric-preset","rule_preset":1e6,"outbound_preset":1e6,"rule_set_tag":"numeric-rule","outbound_tag":"numeric-out"}
  ]}' > "$STATE_FILE"
  expected="$(collect_managed_split_tags_with_shell_tools)"
  [[ "$(collect_managed_split_tags)" == "$expected" ]]
  command() {
    if [[ "${1:-}" == "-v" && "${2:-}" == "python3" ]]; then
      return 1
    fi
    builtin command "$@"
  }
  [[ "$(collect_managed_split_tags)" == "$expected" ]]
)

# 20 条旧分流共享 4 个规则预置和 3 个出口预置时，标签收集固定为一次 Python，且不再逐条启动 jq/sha256sum/awk。
(
  STATE_FILE="$work/managed-split-tags-count.json"
  jq -n '{
    splits:[range(0; 20) as $index | {
      name:("split-" + ($index | tostring)),
      rule_preset:("rule-" + (($index % 4) | tostring)),
      outbound_preset:("out-" + (($index % 3) | tostring)),
      rule_set_tag:("legacy-rule-" + ($index | tostring)),
      outbound_tag:("legacy-out-" + ($index | tostring))
    }]
  }' > "$STATE_FILE"
  jq_calls="$work/managed-split-tags-jq.calls"
  python_calls="$work/managed-split-tags-python.calls"
  sha_calls="$work/managed-split-tags-sha.calls"
  awk_calls="$work/managed-split-tags-awk.calls"
  : > "$jq_calls"
  : > "$python_calls"
  jq() { printf 'jq\n' >> "$jq_calls"; command jq "$@"; }
  python3() { printf 'python3\n' >> "$python_calls"; command python3 "$@"; }
  sha256sum() { printf 'sha256sum\n' >> "$sha_calls"; command sha256sum "$@"; }
  awk() { printf 'awk\n' >> "$awk_calls"; command awk "$@"; }
  tags="$(collect_managed_split_tags)"
  [[ ! -s "$jq_calls" ]]
  [[ "$(wc -l < "$python_calls" | tr -d ' ')" == 1 ]]
  [[ ! -e "$sha_calls" && ! -e "$awk_calls" ]]
  jq -e '
    (.rule_tags | length) == 24 and
    (.out_tags | length) == 23 and
    (.transport_tags | length) == 23 and
    (.rule_tags == (.rule_tags | sort | unique)) and
    (.out_tags == (.out_tags | sort | unique)) and
    (.transport_tags == (.transport_tags | sort | unique))
  ' <<<"$tags" >/dev/null
)

(
  STATE_FILE="$work/split-maintenance-state.json"
  SINGBOX_CONFIG="$work/split-maintenance-config.json"
  SINGBOX_BIN=mock_singbox
  printf '%s\n' '{"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"},{"type":"direct","tag":"external-out"},{"type":"shadowsocks","tag":"old-out","server":"old"}],"route":{"rules":[{"action":"route","outbound":"external-out"},{"rule_set":"old-rule","action":"route","outbound":"old-out"}],"rule_set":[{"type":"remote","tag":"external-rule","format":"source","url":"https://example.com/external.json"},{"type":"remote","tag":"old-rule","format":"binary","url":"https://example.com/old.srs"}]}}' > "$SINGBOX_CONFIG"
  printf '%s\n' '{"schema_version":3,"users":[],"splits":[{"name":"beta","url":"https://rules.example.com/beta.srs","scope":"all","user":null,"upstream":{"protocol":"shadowsocks","server":"beta.example.com","server_port":443,"method":"aes-128-gcm","password":"beta-secret"},"outbound_tag":"beta-out","rule_set_tag":"beta-rule","status":"active","created_at":"2026-07-15T00:00:00+08:00"},{"name":"alpha","url":"https://rules.example.com/alpha.json","scope":"all","user":null,"upstream":{"protocol":"shadowsocks","server":"alpha.example.com","server_port":8443,"method":"aes-256-gcm","password":"alpha-secret"},"outbound_tag":"alpha-out","rule_set_tag":"alpha-rule","status":"active","created_at":"2026-07-15T00:00:00+08:00"},{"name":"disabled","url":"https://rules.example.com/disabled.srs","scope":"all","user":null,"upstream":{"protocol":"shadowsocks","server":"disabled.example.com","server_port":9443,"method":"aes-128-gcm","password":"disabled-secret"},"outbound_tag":"disabled-out","rule_set_tag":"disabled-rule","status":"disabled","created_at":"2026-07-15T00:00:00+08:00"}]}' > "$STATE_FILE"
  # 模拟旧配置中的受管标签，确保统一重建会清理而不是累加。
  jq '.route.rules += [{rule_set:"beta-rule",action:"route",outbound:"old-out"}] | .route.rule_set += [{type:"remote",tag:"beta-rule",format:"binary",url:"https://old"}] | .outbounds += [{type:"shadowsocks",tag:"beta-out",server:"old"}]' "$SINGBOX_CONFIG" > "$SINGBOX_CONFIG.tmp"
  mv "$SINGBOX_CONFIG.tmp" "$SINGBOX_CONFIG"
  rebuild_all_split_configs
  jq -e '
    any(.outbounds[]; .tag == "external-out") and
    any(.route.rule_set[]; .tag == "external-rule") and
    ([.route.rules[] | select(.rule_set == "beta-rule" or .rule_set == "alpha-rule") | .rule_set] == ["beta-rule","alpha-rule"]) and
    ([.route.rule_set[] | select(.tag == "beta-rule")] | length == 1) and
    ([.outbounds[] | select(.tag == "beta-out")] | length == 1) and
    (all(.route.rules[]; .rule_set != "disabled-rule")) and
    (all(.outbounds[]; .tag != "disabled-out"))
  ' "$SINGBOX_CONFIG" >/dev/null

  cp "$SINGBOX_CONFIG" "$work/split-maintenance-config.before-read-failure.json"
  cp "$STATE_FILE" "$work/split-maintenance-state.valid.json"
  printf '%s\n' '{invalid-json' > "$STATE_FILE"
  if rebuild_all_split_configs >/dev/null 2>&1; then
    echo 'split rebuild should reject an unreadable state before mutating config' >&2
    exit 1
  fi
  cmp -s "$SINGBOX_CONFIG" "$work/split-maintenance-config.before-read-failure.json"
  mv "$work/split-maintenance-state.valid.json" "$STATE_FILE"

  state_move_split '["alpha"]' 1
  jq -e '[.splits[].name] == ["alpha","beta","disabled"]' "$STATE_FILE" >/dev/null
  rebuild_all_split_configs
  jq -e '[.route.rules[] | select(.rule_set == "beta-rule" or .rule_set == "alpha-rule") | .rule_set] == ["alpha-rule","beta-rule"]' "$SINGBOX_CONFIG" >/dev/null

  # 共用同一套预置的分流在运行配置里合并成一条，共用一个匹配位置。
  # 「调整分流顺序」必须整组移动并让成员相邻，否则界面顺序会和真正生效的顺序不一致。
  (
    STATE_FILE="$work/split-merge-order-state.json"
    cat > "$STATE_FILE" <<'MERGEORDER'
{"schema_version":7,"users":[
 {"name":"alice","port":20001,"protocol":"anytls","status":"active","metered":false,"expires_at":null,"limit_gib":null,"billing_anchor":null,"usage_offset_bytes":0,"created_at":"2026-01-01T00:00:00+08:00","anytls_password":"a","tls_sni":"a.example.com","endpoints":[{"protocol":"anytls","port":20001,"anytls_password":"a","tls_sni":"a.example.com"}]},
 {"name":"bob","port":20002,"protocol":"anytls","status":"active","metered":false,"expires_at":null,"limit_gib":null,"billing_anchor":null,"usage_offset_bytes":0,"created_at":"2026-01-01T00:00:00+08:00","anytls_password":"b","tls_sni":"b.example.com","endpoints":[{"protocol":"anytls","port":20002,"anytls_password":"b","tls_sni":"b.example.com"}]}],
 "splits":[
 {"name":"s1","url":"https://rules.example.com/ai.srs","scope":"user","user":"alice","status":"active","rule_preset":"AI","outbound_preset":"HK","runtime_rule_tag":"mpr-ai","runtime_outbound_tag":"mpo-hk","runtime_transport_tag":null,"outbound_tag":"managed-out-s1","rule_set_tag":"managed-split-s1","upstream":{"protocol":"anytls","server":"hk.example.com","server_port":443,"password":"p","sni":"hk.example.com","insecure":false},"created_at":"2026-01-01T00:00:00+08:00","updated_at":"2026-01-01T00:00:00+08:00"},
 {"name":"s2","url":"https://rules.example.com/nf.srs","scope":"all","user":null,"status":"active","rule_preset":"NF","outbound_preset":"JP","runtime_rule_tag":"mpr-nf","runtime_outbound_tag":"mpo-jp","runtime_transport_tag":null,"outbound_tag":"managed-out-s2","rule_set_tag":"managed-split-s2","upstream":{"protocol":"anytls","server":"jp.example.com","server_port":443,"password":"p","sni":"jp.example.com","insecure":false},"created_at":"2026-01-01T00:00:00+08:00","updated_at":"2026-01-01T00:00:00+08:00"},
 {"name":"s3","url":"https://rules.example.com/ai.srs","scope":"user","user":"bob","status":"active","rule_preset":"AI","outbound_preset":"HK","runtime_rule_tag":"mpr-ai","runtime_outbound_tag":"mpo-hk","runtime_transport_tag":null,"outbound_tag":"managed-out-s3","rule_set_tag":"managed-split-s3","upstream":{"protocol":"anytls","server":"hk.example.com","server_port":443,"password":"p","sni":"hk.example.com","insecure":false},"created_at":"2026-01-01T00:00:00+08:00","updated_at":"2026-01-01T00:00:00+08:00"}],
 "outbound_presets":[],"rule_presets":[]}
MERGEORDER
    if [[ "$(split_merge_group_names s3)" != '["s1","s3"]' ]]; then
      echo 'splits sharing a preset pair must be reported as one merge group' >&2
      exit 1
    fi
    if [[ "$(split_merge_group_names s2)" != '["s2"]' ]]; then
      echo 'a split with its own preset pair must form a group of one' >&2
      exit 1
    fi
    ranks="$(split_effective_match_ranks)"
    if ! jq -e '.s1 == 1 and .s3 == 1 and .s2 == 2' <<<"$ranks" >/dev/null; then
      echo "merged splits must share one effective match position: $ranks" >&2
      exit 1
    fi
    # 移动组内靠后的一条，整组都要移动，且成员必须相邻
    state_move_split "$(split_merge_group_names s3)" 1
    if ! jq -e '[.splits[].name] == ["s1","s3","s2"]' "$STATE_FILE" >/dev/null; then
      echo "moving one member must move the whole merge group: $(jq -c '[.splits[].name]' "$STATE_FILE")" >&2
      exit 1
    fi
    ranks="$(split_effective_match_ranks)"
    if ! jq -e '.s1 == 1 and .s3 == 1 and .s2 == 2' <<<"$ranks" >/dev/null; then
      echo "the merge group must keep one shared position after moving: $ranks" >&2
      exit 1
    fi
    # 把整组移到最后：s2 变成第一位
    state_move_split "$(split_merge_group_names s1)" 3
    if ! jq -e '[.splits[].name] == ["s2","s1","s3"]' "$STATE_FILE" >/dev/null; then
      echo "moving the group to the end must place the other split first" >&2
      exit 1
    fi
    ranks="$(split_effective_match_ranks)"
    if ! jq -e '.s2 == 1 and .s1 == 2 and .s3 == 2' <<<"$ranks" >/dev/null; then
      echo "effective positions must follow the new group order: $ranks" >&2
      exit 1
    fi
    # 停用的分流不进入运行配置，没有匹配位置
    jq '(.splits[] | select(.name == "s3") | .status) = "disabled"' "$STATE_FILE" > "$STATE_FILE.tmp"
    mv "$STATE_FILE.tmp" "$STATE_FILE"
    ranks="$(split_effective_match_ranks)"
    if ! jq -e '.s3 == null' <<<"$ranks" >/dev/null; then
      echo "a disabled split must not claim an effective match position: $ranks" >&2
      exit 1
    fi
  )

  validate_split_rule_source() { :; }
  start_managed_operation() { :; }
  finish_managed_operation() { :; }
  check_singbox_and_restart() { :; }
  edited_upstream='{"protocol":"shadowsocks","server":"edited.example.com","server_port":9443,"method":"aes-256-gcm","password":"alpha-secret"}'
  cmd_split_edit alpha https://rules.example.com/edited.srs all '' "$edited_upstream" edited-out >/dev/null
  jq -e '.splits[0] | .name == "alpha" and .status == "active" and .created_at == "2026-07-15T00:00:00+08:00" and .url == "https://rules.example.com/edited.srs" and .outbound_tag == "edited-out" and .upstream.password == "alpha-secret" and (.updated_at | length > 0)' "$STATE_FILE" >/dev/null
  details="$(cmd_split_show alpha)"
  # 旧措辞「匹配顺序：第 N 条」拿列表行号冒充生效顺序，合并成一条路由的分流会被它误导；
  # 现在拆成「列表顺序」与「匹配位置」两项，后者才是真正生效的先后。
  grep -Fq '列表顺序：第 1 条' <<<"$details"
  grep -Fq '匹配位置：第 1 位' <<<"$details"
  grep -Fq '规则集地址：https://rules.example.com/edited.srs' <<<"$details"
  # 这条否定断言原本写成 `! grep`，仅因恰好位于子壳末尾才生效；改成显式判断，
  # 以后在它后面加语句也不会让它静默失效
  if grep -Fq 'alpha-secret' <<<"$details"; then
    echo 'split details must not print the upstream password' >&2
    exit 1
  fi
)

(
  STATE_FILE="$work/shared-preset-runtime-state.json"
  SINGBOX_CONFIG="$work/shared-preset-runtime-config.json"
  SINGBOX_BIN=mock_singbox
  printf '%s\n' '{"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"},{"type":"anytls","tag":"Hinet","server":"legacy.example.com","server_port":443,"password":"legacy","tls":{"enabled":true,"server_name":"legacy.example.com","insecure":true}},{"type":"shadowsocks","tag":"shared-legacy-out","server":"shared.example.com","server_port":443,"method":"aes-128-gcm","password":"shared"}],"route":{"rules":[{"rule_set":"legacy-ai","action":"route","outbound":"Hinet"},{"rule_set":"legacy-ai-shared","action":"route","outbound":"shared-legacy-out"},{"rule_set":"external-rule","action":"route","outbound":"shared-legacy-out"}],"rule_set":[{"type":"remote","tag":"legacy-ai","format":"binary","url":"https://rules.example.com/ai.srs"},{"type":"remote","tag":"legacy-ai-shared","format":"binary","url":"https://rules.example.com/ai.srs"},{"type":"remote","tag":"external-rule","format":"binary","url":"https://rules.example.com/external.srs"}]}}' > "$SINGBOX_CONFIG"
  printf '%s\n' '{"schema_version":4,"users":[{"name":"alice","protocol":"anytls","status":"active"},{"name":"bob","protocol":"ss2022","status":"active"},{"name":"carol","protocol":"anytls","status":"active"}],"outbound_presets":[{"name":"Hinet","upstream":{"protocol":"shadowsocks","server":"hinet.example.com","server_port":443,"method":"aes-128-gcm","password":"shared-secret"}},{"name":"Other","upstream":{"protocol":"shadowsocks","server":"other.example.com","server_port":8443,"method":"aes-256-gcm","password":"other-secret"}}],"rule_presets":[{"name":"AI","url":"https://rules.example.com/ai.srs"}],"splits":[{"name":"ai-alice","url":"https://rules.example.com/ai.srs","scope":"user","user":"alice","upstream":{"protocol":"shadowsocks","server":"hinet.example.com","server_port":443,"method":"aes-128-gcm","password":"shared-secret"},"outbound_tag":"legacy-alice-out","rule_set_tag":"legacy-alice-rule","rule_preset":"AI","outbound_preset":"Hinet","status":"active"},{"name":"ai-bob","url":"https://rules.example.com/ai.srs","scope":"user","user":"bob","upstream":{"protocol":"shadowsocks","server":"hinet.example.com","server_port":443,"method":"aes-128-gcm","password":"shared-secret"},"outbound_tag":"legacy-bob-out","rule_set_tag":"legacy-bob-rule","rule_preset":"AI","outbound_preset":"Hinet","status":"active"},{"name":"ai-carol","url":"https://rules.example.com/ai.srs","scope":"user","user":"carol","upstream":{"protocol":"shadowsocks","server":"other.example.com","server_port":8443,"method":"aes-256-gcm","password":"other-secret"},"outbound_tag":"legacy-carol-out","rule_set_tag":"legacy-carol-rule","rule_preset":"AI","outbound_preset":"Other","status":"active"}]}' > "$STATE_FILE"
  shared_rule_tag="$(stable_managed_tag rule AI)"
  shared_out_tag="$(stable_managed_tag outbound Hinet)"
  other_out_tag="$(stable_managed_tag outbound Other)"
  if shared_preset_runtime_is_current; then
    echo 'legacy rules with the same preset URL should require one-time cleanup' >&2
    exit 1
  fi
  legacy_tags="$(collect_managed_split_tags)"
  legacy_plan="$(collect_legacy_split_cleanup_plan_from_config "$(mock_singbox format -c "$SINGBOX_CONFIG")" "$legacy_tags")"
  jq -e '
    (.rule_tags | sort) == ["legacy-ai","legacy-ai-shared"] and
    (.out_tags | sort) == ["Hinet","shared-legacy-out"]
  ' <<<"$legacy_plan" >/dev/null
  rebuild_all_split_configs
  shared_preset_runtime_is_current
  jq -e --arg rule "$shared_rule_tag" --arg shared "$shared_out_tag" --arg other "$other_out_tag" '
    ([.route.rule_set[] | select(.tag == $rule)] | length) == 1 and
    ([.outbounds[] | select(.tag == $shared)] | length) == 1 and
    ([.outbounds[] | select(.tag == $other)] | length) == 1 and
    ([.route.rules[] | select(.rule_set == $rule)] | length) == 2 and
    all(.route.rule_set[]; .tag != "legacy-ai" and .tag != "legacy-ai-shared") and
    all(.route.rules[]; .rule_set != "legacy-ai" and .rule_set != "legacy-ai-shared") and
    all(.outbounds[]; .tag != "Hinet") and
    any(.route.rule_set[]; .tag == "external-rule") and
    any(.route.rules[]; .rule_set == "external-rule" and .outbound == "shared-legacy-out") and
    any(.outbounds[]; .tag == "shared-legacy-out") and
    any(.route.rules[]; .rule_set == $rule and .outbound == $shared and
      (.inbound | index("anytls-alice")) and (.inbound | index("st-bob")) and
      (.inbound | index("ss-bob")) and (.inbound | index("ss-udp-bob"))) and
    any(.route.rules[]; .rule_set == $rule and .outbound == $other and (.inbound | index("anytls-carol")))
  ' "$SINGBOX_CONFIG" >/dev/null

  if validate_split_relationships duplicate "$shared_rule_tag" "$shared_out_tag" user alice false >/dev/null 2>&1; then
    echo 'shared preset validation should reject a duplicate user route' >&2
    exit 1
  fi
  if validate_split_relationships conflict "$shared_rule_tag" "$other_out_tag" user alice false >/dev/null 2>&1; then
    echo 'shared preset validation should reject two outbounds for one user and rule' >&2
    exit 1
  fi
  validate_split_relationships allowed "$shared_rule_tag" "$other_out_tag" user dave false
  if validate_split_relationships all-conflict "$shared_rule_tag" "$shared_out_tag" all '' false >/dev/null 2>&1; then
    echo 'shared preset validation should reject an all-users overlap' >&2
    exit 1
  fi

  prepare_core() { :; }
  prompt_select_rule_preset() {
    SELECTED_RULE_PRESET=AI
    SELECTED_RULE_SOURCE=https://rules.example.com/ai.srs
    SELECTED_RULE_BEHAVIOR=''
  }
  prompt_split_scope_user() {
    PROMPTED_SPLIT_USER=alice
  }
  prompt_select_outbound_preset() {
    SELECTED_OUTBOUND_PRESET=Hinet
    SELECTED_OUTBOUND_UPSTREAM='{"protocol":"shadowsocks","server":"hinet.example.com","server_port":443,"method":"aes-128-gcm","password":"shared-secret"}'
  }
  cmd_split_add() {
    echo 'expected relationship conflict' >&2
    return 1
  }
  conflict_menu_output="$(printf 'menu-conflict\n2\ny\n' | prompt_add_split 2>&1)"
  grep -Fq 'expected relationship conflict' <<<"$conflict_menu_output"
  grep -Fq '分流没有添加，现有配置没有改变。' <<<"$conflict_menu_output"

  state_remove_split ai-alice
  rebuild_all_split_configs
  jq -e --arg rule "$shared_rule_tag" --arg out "$shared_out_tag" '
    ([.outbounds[] | select(.tag == $out)] | length) == 1 and
    any(.route.rules[]; .rule_set == $rule and .outbound == $out and
      ((.inbound | index("anytls-alice")) == null) and (.inbound | index("ss-udp-bob")))
  ' "$SINGBOX_CONFIG" >/dev/null

  state_remove_outbound_preset Hinet "$shared_out_tag" "$(stable_managed_tag transport Hinet)"
  state_remove_rule_preset AI "$shared_rule_tag"
  jq -e --arg rule "$shared_rule_tag" --arg out "$shared_out_tag" '
    all(.splits[] | select(.name == "ai-alice" or .name == "ai-bob");
      (.rule_preset | not) and (.outbound_preset | not) and
      .runtime_rule_tag == $rule and .runtime_outbound_tag == $out)
  ' "$STATE_FILE" >/dev/null
  rebuild_all_split_configs
  jq -e --arg rule "$shared_rule_tag" --arg out "$shared_out_tag" '
    ([.route.rule_set[] | select(.tag == $rule)] | length) == 1 and
    ([.outbounds[] | select(.tag == $out)] | length) == 1
  ' "$SINGBOX_CONFIG" >/dev/null

  SHARED_PRESET_RUNTIME_MARKER="$work/shared-preset-runtime.marker"
  write_shared_preset_runtime_marker
  shared_preset_runtime_marker_matches
  marker_mode="$(stat -c '%a' "$SHARED_PRESET_RUNTIME_MARKER" 2>/dev/null || stat -f '%Lp' "$SHARED_PRESET_RUNTIME_MARKER")"
  [[ "$marker_mode" == 600 ]]
  jq '.route.rules += [{action:"route",outbound:"direct"}]' "$SINGBOX_CONFIG" > "$SINGBOX_CONFIG.tmp"
  mv "$SINGBOX_CONFIG.tmp" "$SINGBOX_CONFIG"
  if shared_preset_runtime_marker_matches; then
    echo 'shared preset marker must become stale after the config changes' >&2
    exit 1
  fi
)

(
  STATE_FILE="$work/shared-shadowtls-runtime-state.json"
  SINGBOX_CONFIG="$work/shared-shadowtls-runtime-config.json"
  SINGBOX_BIN=mock_singbox
  printf '%s\n' '{"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[],"rule_set":[]}}' > "$SINGBOX_CONFIG"
  printf '%s\n' '{"schema_version":4,"users":[{"name":"alice","protocol":"anytls","status":"active"},{"name":"bob","protocol":"ss2022","status":"active"}],"outbound_presets":[{"name":"ShadowExit","upstream":{"protocol":"ss_shadowtls","server":"shared.example.com","server_port":443,"method":"2022-blake3-aes-128-gcm","ss_password":"ss-secret","shadowtls_password":"st-secret","sni":"shared.example.com","insecure":false}}],"rule_presets":[{"name":"AI","url":"https://rules.example.com/ai.srs"}],"splits":[{"name":"shadow-alice","url":"https://rules.example.com/ai.srs","scope":"user","user":"alice","upstream":{"protocol":"ss_shadowtls","server":"shared.example.com","server_port":443,"method":"2022-blake3-aes-128-gcm","ss_password":"ss-secret","shadowtls_password":"st-secret","sni":"shared.example.com","insecure":false},"outbound_tag":"legacy-shadow-a","rule_set_tag":"legacy-shadow-rule-a","rule_preset":"AI","outbound_preset":"ShadowExit","status":"active"},{"name":"shadow-bob","url":"https://rules.example.com/ai.srs","scope":"user","user":"bob","upstream":{"protocol":"ss_shadowtls","server":"shared.example.com","server_port":443,"method":"2022-blake3-aes-128-gcm","ss_password":"ss-secret","shadowtls_password":"st-secret","sni":"shared.example.com","insecure":false},"outbound_tag":"legacy-shadow-b","rule_set_tag":"legacy-shadow-rule-b","rule_preset":"AI","outbound_preset":"ShadowExit","status":"active"}]}' > "$STATE_FILE"
  shadow_rule="$(stable_managed_tag rule AI)"
  shadow_out="$(stable_managed_tag outbound ShadowExit)"
  shadow_transport="$(stable_managed_tag transport ShadowExit)"
  rebuild_all_split_configs
  jq -e --arg rule "$shadow_rule" --arg out "$shadow_out" --arg transport "$shadow_transport" '
    ([.route.rule_set[] | select(.tag == $rule)] | length) == 1 and
    ([.outbounds[] | select(.tag == $out)] | length) == 1 and
    ([.outbounds[] | select(.tag == $transport)] | length) == 1 and
    ([.route.rules[] | select(.rule_set == $rule and .outbound == $out)] | length) == 1 and
    any(.route.rules[]; .rule_set == $rule and .outbound == $out and
      (.inbound | index("anytls-alice")) and (.inbound | index("st-bob")) and
      (.inbound | index("ss-bob")) and (.inbound | index("ss-udp-bob")))
  ' "$SINGBOX_CONFIG" >/dev/null
  state_set_status bob disabled
  rebuild_all_split_configs
  jq -e --arg rule "$shadow_rule" --arg out "$shadow_out" '
    any(.route.rules[]; .rule_set == $rule and .outbound == $out and
      (.inbound | index("anytls-alice")) and ((.inbound | index("ss-udp-bob")) == null))
  ' "$SINGBOX_CONFIG" >/dev/null
  state_set_status bob active
  rebuild_all_split_configs
  jq -e --arg rule "$shadow_rule" --arg out "$shadow_out" '
    any(.route.rules[]; .rule_set == $rule and .outbound == $out and (.inbound | index("ss-udp-bob")))
  ' "$SINGBOX_CONFIG" >/dev/null
)

(
  STATE_FILE="$work/preset-state.json"
  SINGBOX_CONFIG="$work/preset-config.json"
  printf '%s\n' '{"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[],"rule_set":[]}}' > "$SINGBOX_CONFIG"
  printf '%s\n' '{"schema_version":4,"users":[],"outbound_presets":[],"rule_presets":[],"splits":[{"name":"active","url":"https://rules.example.com/old.srs","scope":"all","user":null,"upstream":{"protocol":"shadowsocks","server":"old.example.com","server_port":443,"method":"aes-128-gcm","password":"old"},"outbound_tag":"active-out","rule_set_tag":"active-rule","rule_preset":"rules","outbound_preset":"exit","status":"active"},{"name":"disabled","url":"https://rules.example.com/old.srs","scope":"all","user":null,"upstream":{"protocol":"shadowsocks","server":"old.example.com","server_port":443,"method":"aes-128-gcm","password":"old"},"outbound_tag":"disabled-out","rule_set_tag":"disabled-rule","rule_preset":"rules","outbound_preset":"exit","status":"disabled"}]}' > "$STATE_FILE"
  grep -Fxq '暂无预置出口' < <(print_outbound_preset_list)
  grep -Fxq '暂无预置规则' < <(print_rule_preset_list)
  upstream='{"protocol":"shadowsocks","server":"new.example.com","server_port":8443,"method":"aes-256-gcm","password":"new-secret"}'
  cp "$SINGBOX_CONFIG" "$work/preset-config.before.json"
  state_add_outbound_preset exit "$upstream"
  state_add_rule_preset rules https://rules.example.com/new.srs
  cmp -s "$SINGBOX_CONFIG" "$work/preset-config.before.json"
  outbound_list="$(print_outbound_preset_list)"
  rule_list="$(print_rule_preset_list)"
  grep -Eq '^exit[[:space:]]+Shadowsocks[[:space:]]+new\.example\.com:8443[[:space:]]+2[[:space:]]+1$' <<<"$outbound_list"
  grep -Eq '^rules[[:space:]]+SRS[[:space:]]+2[[:space:]]+1$' <<<"$rule_list"

  cp "$STATE_FILE" "$work/preset-state.valid.json"
  printf '%s\n' '{invalid-json' > "$STATE_FILE"
  grep -Fxq '错误：无法读取预置出口数据，请运行「检查与故障报告」。' < <(print_outbound_preset_list)
  grep -Fxq '错误：无法读取预置规则数据，请运行「检查与故障报告」。' < <(print_rule_preset_list)
  mv "$work/preset-state.valid.json" "$STATE_FILE"

  rebuild_calls=0
  restart_calls=0
  validate_upstream_candidate() { :; }
  validate_split_rule_source() { :; }
  ensure_safe_ssh_for_kernel_restart() { :; }
  start_managed_operation() { :; }
  rebuild_all_split_configs() { rebuild_calls=$((rebuild_calls + 1)); }
  check_singbox_and_restart() { restart_calls=$((restart_calls + 1)); }
  finish_managed_operation() { :; }
  updated_upstream='{"protocol":"shadowsocks","server":"updated.example.com","server_port":9443,"method":"aes-256-gcm","password":"updated-secret"}'
  cmd_outbound_preset_edit exit "$updated_upstream" >/dev/null
  [[ "$rebuild_calls" == 1 && "$restart_calls" == 1 ]]
  jq -e --argjson upstream "$updated_upstream" '
    (.outbound_presets[] | select(.name=="exit") | .upstream) == $upstream and
    all(.splits[] | select(.outbound_preset=="exit"); .upstream == $upstream) and
    (.splits[] | select(.name=="disabled") | .status) == "disabled"
  ' "$STATE_FILE" >/dev/null

  rebuild_calls=0
  restart_calls=0
  cmd_rule_preset_edit rules https://rules.example.com/updated.srs >/dev/null
  [[ "$rebuild_calls" == 1 && "$restart_calls" == 1 ]]
  jq -e 'all(.splits[] | select(.rule_preset=="rules"); .url=="https://rules.example.com/updated.srs")' "$STATE_FILE" >/dev/null

  snapshot="$(jq -c '[.splits[] | {name,url,upstream,status}]' "$STATE_FILE")"
  cmd_outbound_preset_remove exit >/dev/null
  cmd_rule_preset_remove rules >/dev/null
  [[ "$rebuild_calls" == 1 && "$restart_calls" == 1 ]]
  jq -e --argjson snapshot "$snapshot" '
    .outbound_presets == [] and .rule_presets == [] and
    all(.splits[]; (has("outbound_preset")|not) and (has("rule_preset")|not)) and
    ([.splits[] | {name,url,upstream,status}] == $snapshot)
  ' "$STATE_FILE" >/dev/null
)

# 独立配置的分流在写入状态时必须删除预置字段，不能留下空串。
(
  STATE_FILE="$work/split-preset-field-state.json"
  printf '%s\n' '{"schema_version":7,"users":[],"outbound_presets":[],"rule_presets":[],"splits":[]}' > "$STATE_FILE"
  upstream='{"protocol":"shadowsocks","server":"exit.example.com","server_port":443,"method":"aes-128-gcm","password":"secret"}'
  state_add_split standalone https://rules.example.com/standalone.srs all '' "$upstream" standalone-out standalone-rule '' '' \
    managed-split-standalone managed-out-standalone managed-transport-standalone
  state_add_split linked https://rules.example.com/ai.srs all '' "$upstream" linked-out linked-rule AI Exit \
    shared-rule shared-out shared-transport
  jq -e '
    (.splits[] | select(.name == "standalone") | (has("rule_preset") | not) and (has("outbound_preset") | not)) and
    (.splits[] | select(.name == "linked") | .rule_preset == "AI" and .outbound_preset == "Exit")
  ' "$STATE_FILE" >/dev/null

  # 「保持不变」的编辑传空串，不能把独立配置写成空白预置。
  state_replace_split standalone https://rules.example.com/standalone.srs all '' "$upstream" standalone-out '' '' \
    managed-split-standalone managed-out-standalone managed-transport-standalone
  state_replace_split linked https://rules.example.com/ai.srs all '' "$upstream" linked-out AI Exit \
    shared-rule shared-out shared-transport
  jq -e '
    (.splits[] | select(.name == "standalone") | (has("rule_preset") | not) and (has("outbound_preset") | not)) and
    (.splits[] | select(.name == "linked") | .rule_preset == "AI" and .outbound_preset == "Exit")
  ' "$STATE_FILE" >/dev/null

  # 由预置改回独立配置时字段同样要消失。
  state_replace_split linked https://rules.example.com/ai.srs all '' "$upstream" linked-out '' '' \
    shared-rule shared-out shared-transport
  jq -e '.splits[] | select(.name == "linked") |
    (has("rule_preset") | not) and (has("outbound_preset") | not) and .runtime_rule_tag == "shared-rule"
  ' "$STATE_FILE" >/dev/null
)

# 旧数据里遗留的空串预置字段要能一次性清洗成缺省，且幂等、不动其他字段。
(
  STATE_FILE="$work/split-preset-cleanup-state.json"
  printf '%s\n' '{"schema_version":7,"users":[],"outbound_presets":[{"name":"Exit","upstream":{"protocol":"shadowsocks","server":"exit.example.com","server_port":443,"method":"aes-128-gcm","password":"secret"}}],"rule_presets":[{"name":"AI","url":"https://rules.example.com/ai.srs"}],"splits":[{"name":"blank","url":"https://rules.example.com/blank.srs","scope":"all","user":null,"upstream":{"protocol":"shadowsocks","server":"exit.example.com","server_port":443,"method":"aes-128-gcm","password":"secret"},"outbound_tag":"blank-out","rule_set_tag":"blank-rule","rule_preset":"","outbound_preset":"","status":"active"},{"name":"half","url":"https://rules.example.com/ai.srs","scope":"all","user":null,"upstream":{"protocol":"shadowsocks","server":"exit.example.com","server_port":443,"method":"aes-128-gcm","password":"secret"},"outbound_tag":"half-out","rule_set_tag":"half-rule","rule_preset":"AI","outbound_preset":"","status":"disabled"},{"name":"clean","url":"https://rules.example.com/clean.srs","scope":"all","user":null,"upstream":{"protocol":"shadowsocks","server":"exit.example.com","server_port":443,"method":"aes-128-gcm","password":"secret"},"outbound_tag":"clean-out","rule_set_tag":"clean-rule","status":"active"}]}' > "$STATE_FILE"
  snapshot="$(jq -c '[.splits[] | {name,url,scope,upstream,outbound_tag,rule_set_tag,status}] + [.outbound_presets, .rule_presets]' "$STATE_FILE")"
  if split_preset_fields_are_current; then
    echo 'empty preset fields must be reported as stale data' >&2
    exit 1
  fi
  state_normalize_split_preset_fields
  split_preset_fields_are_current
  jq -e --argjson snapshot "$snapshot" '
    (.splits[] | select(.name == "blank") | (has("rule_preset") | not) and (has("outbound_preset") | not)) and
    (.splits[] | select(.name == "half") | .rule_preset == "AI" and (has("outbound_preset") | not)) and
    (.splits[] | select(.name == "clean") | (has("rule_preset") | not) and (has("outbound_preset") | not)) and
    (([.splits[] | {name,url,scope,upstream,outbound_tag,rule_set_tag,status}] + [.outbound_presets, .rule_presets]) == $snapshot)
  ' "$STATE_FILE" >/dev/null
  cleaned="$(cat "$STATE_FILE")"
  state_normalize_split_preset_fields
  [[ "$(cat "$STATE_FILE")" == "$cleaned" ]]
)

(
  rollback_marker="$work/split-edit-rollback"
  later_marker="$work/split-edit-later"
  split_exists() { return 0; }
  jq() {
    if [[ "$*" == *'.splits[] | select(.name == $name)'* ]]; then
      printf '%s\n' '{"name":"failure","status":"active","outbound_tag":"old-out","rule_set_tag":"failure","upstream":{"protocol":"shadowsocks"}}'
    else
      command jq "$@"
    fi
  }
  validate_outbound_tag() { :; }
  split_rule_format() { printf 'binary'; }
  validate_split_rule_source() { :; }
  start_managed_operation() { :; }
  remove_split_config() { :; }
  state_replace_split() { :; }
  rebuild_all_split_configs() { return 77; }
  rollback_active_operation() { printf '%s\n' "$1" > "$rollback_marker"; return "$1"; }
  check_singbox_and_restart() { printf unexpected > "$later_marker"; }
  finish_managed_operation() { printf unexpected > "$later_marker"; }
  SINGBOX_CONFIG="$work/config.json"
  STATE_FILE="$work/state.json"
  if cmd_split_edit failure https://rules.example.com/failure.srs all '' '{"protocol":"shadowsocks"}' new-out >/dev/null 2>&1; then
    echo 'split edit should propagate rebuild failure' >&2
    exit 1
  fi
  grep -Fxq 77 "$rollback_marker"
  [[ ! -e "$later_marker" ]]
)

cp "$SINGBOX_CONFIG" "$work/config.before-failure.json"
rollback_marker="$work/config-rewrite-err-trap"
MOCK_SINGBOX_FORMAT_FAIL=true
set +e
(
  trap 'printf "triggered\n" > "$rollback_marker"' ERR
  rewrite_kernel_config '.'
) >/dev/null 2>&1
format_failure_rc=$?
set -e
[[ "$format_failure_rc" != 0 ]]
grep -Fxq triggered "$rollback_marker"
MOCK_SINGBOX_FORMAT_FAIL=false
cmp -s "$SINGBOX_CONFIG" "$work/config.before-failure.json"
rm -f "$rollback_marker"

# 长交互会话中的成功原子写入不得持续累积已经移走或删除的临时路径。
(
  RUNTIME_TEMP_PATHS=()
  RUNTIME_TEMP_PATH_COUNT=0
  STATE_FILE="$work/temp-registry-state.json"
  SINGBOX_CONFIG="$work/temp-registry-config.json"
  SINGBOX_BIN=mock_singbox
  printf '%s\n' '{"schema_version":7,"users":[],"splits":[],"outbound_presets":[],"rule_presets":[],"counter":0}' > "$STATE_FILE"
  printf '%s\n' '{"inbounds":[],"outbounds":[],"route":{"rules":[],"rule_set":[]}}' > "$SINGBOX_CONFIG"
  for iteration in 1 2 3 4 5 6 7 8 9 10; do
    atomic_state_update '.counter += 1'
    rewrite_kernel_config '.'
    [[ "$RUNTIME_TEMP_PATH_COUNT" == 0 ]]
  done
  [[ "$(jq -r '.counter' "$STATE_FILE")" == 10 ]]
)

# 格式化中间文件删除失败时必须保留登记并报告失败，交给统一退出清理重试。
(
  RUNTIME_TEMP_PATHS=()
  RUNTIME_TEMP_PATH_COUNT=0
  SINGBOX_CONFIG="$work/normalized-remove-failure-config.json"
  SINGBOX_BIN=mock_singbox
  printf '%s\n' '{"inbounds":[],"outbounds":[],"route":{"rules":[],"rule_set":[]}}' > "$SINGBOX_CONFIG"
  rm() {
    [[ "${*: -1}" != *'/.normalized.'* ]] || return 77
    command rm "$@"
  }
  if rewrite_kernel_config '.' >/dev/null 2>&1; then
    echo 'config rewrite should fail when the normalized staging file cannot be removed' >&2
    exit 1
  fi
  [[ "$RUNTIME_TEMP_PATH_COUNT" == 2 ]]
  for registered_temp in "${RUNTIME_TEMP_PATHS[@]}"; do
    command rm -f -- "$registered_temp"
  done
)

set +e
(
  trap 'printf "triggered\n" > "$rollback_marker"' ERR
  rewrite_kernel_config '.inbounds, error("forced jq failure")'
) >/dev/null 2>&1
jq_failure_rc=$?
set -e
if [[ "$jq_failure_rc" == 0 ]]; then
  echo 'jq failure should reject sing-box config rewrite' >&2
  exit 1
fi
grep -Fxq triggered "$rollback_marker"
cmp -s "$SINGBOX_CONFIG" "$work/config.before-failure.json"
if find "$work" -maxdepth 1 \( -name '.config.*' -o -name '.normalized.*' \) -print -quit | grep -q .; then
  echo 'failed sing-box config rewrite left temporary files behind' >&2
  exit 1
fi

(
  SINGBOX_CONFIG="$work/chmod-failure-config.json"
  printf '%s\n' '{"inbounds":[],"outbounds":[],"route":{"rules":[],"rule_set":[]}}' > "$SINGBOX_CONFIG"
  cp "$SINGBOX_CONFIG" "$work/chmod-failure-config.before.json"
  MOCK_SINGBOX_FORMAT_FAIL=false
  chmod() { return 77; }
  chown() { return 0; }
  if rewrite_kernel_config '.inbounds += [{"tag":"must-not-commit"}]' >/dev/null 2>&1; then
    echo 'config rewrite should fail when both permission updates fail' >&2
    exit 1
  fi
  cmp -s "$SINGBOX_CONFIG" "$work/chmod-failure-config.before.json"
  if find "$work" -maxdepth 1 \( -name '.config.*' -o -name '.normalized.*' \) -print -quit | grep -q .; then
    echo 'permission failure left sing-box rewrite temporary files behind' >&2
    exit 1
  fi
)

(
  STATE_FILE="$work/conditional-enable-state.json"
  SINGBOX_CONFIG="$work/conditional-enable-config.json"
  rollback_marker="$work/conditional-enable-rollback"
  mutation_marker="$work/conditional-enable-mutated"
  printf '%s\n' '{"schema_version":3,"users":[{"name":"conditional-user","port":20009,"status":"disabled","metered":false,"shadowtls_password":"st","ss2022_password":"ss","method":"2022-blake3-aes-128-gcm","shadowtls_sni":"conditional.example.com"}],"splits":[]}' > "$STATE_FILE"
  printf '%s\n' '{"inbounds":[],"outbounds":[],"route":{"rules":[],"rule_set":[]}}' > "$SINGBOX_CONFIG"
  start_managed_operation() { return 0; }
  rollback_active_operation() { printf 'restored\n' > "$rollback_marker"; return "${1:-1}"; }
  finish_managed_operation() { return 0; }
  state_set_status() { printf 'mutated\n' > "$mutation_marker"; }
  nfuse() {
    if [[ "${1:-}" == list && "${2:-}" == --json ]]; then
      printf '%s\n' '[{"name":"conditional-user","tier":"c","used_bytes":123,"ports":[{"id":9,"start":20009,"end":20009}]}]'
      return 0
    fi
    return 0
  }
  MOCK_SINGBOX_FORMAT_FAIL=true
  if cmd_enable conditional-user >/dev/null 2>&1; then
    echo 'conditional cmd_enable should propagate config rewrite failure' >&2
    exit 1
  fi
  grep -Fxq restored "$rollback_marker"
  [[ ! -e "$mutation_marker" ]]
)

(
  STATE_FILE="$work/conditional-enable-nfuse-state.json"
  transaction_marker="$work/conditional-enable-nfuse-transaction"
  printf '%s\n' '{"schema_version":3,"users":[{"name":"metered-user","port":20010,"protocol":"anytls","status":"disabled","metered":true,"anytls_password":"secret","limit_gib":1,"billing_anchor":1}],"splits":[]}' > "$STATE_FILE"
  validate_name() { return 0; }
  user_exists() { return 0; }
  tag_exists_in_config() { return 1; }
  start_managed_operation() { printf 'started\n' > "$transaction_marker"; }
  append_inbounds() { printf 'mutated\n' > "$transaction_marker"; }
  nfuse() {
    if [[ "${1:-}" == list && "${2:-}" == --json ]]; then return 55; fi
    return 0
  }
  if cmd_enable metered-user >/dev/null 2>&1; then
    echo 'metered user enable should reject an unreadable Nfuse account list' >&2
    exit 1
  fi
  [[ ! -e "$transaction_marker" ]]
  [[ -z "$(trap -p ERR)" ]]

  nfuse() {
    if [[ "${1:-}" == list && "${2:-}" == --json ]]; then
      printf '%s\n' '[{"name":"metered-user","tier":"a","used_bytes":123,"ports":[]}]'
      return 0
    fi
    return 0
  }
  if cmd_enable metered-user >/dev/null 2>&1; then
    echo 'metered user enable should reject a missing Nfuse port binding' >&2
    exit 1
  fi
  [[ ! -e "$transaction_marker" ]]
  [[ -z "$(trap -p ERR)" ]]
)

(
  BACKUP_DIR="$work/partial-backup"
  SINGBOX_CONFIG="$work/partial-backup-config.json"
  STATE_FILE="$work/missing-state.json"
  mkdir -p "$BACKUP_DIR"
  printf '%s\n' '{}' > "$SINGBOX_CONFIG"
  if backup_files >/dev/null 2>&1; then
    echo 'partial transaction backup should fail when state copy fails' >&2
    exit 1
  fi
  if find "$BACKUP_DIR" -type f -print -quit | grep -q .; then
    echo 'partial transaction backup should be cleaned' >&2
    exit 1
  fi
)

(
  BACKUP_DIR="$work/missing-restore"
  SINGBOX_CONFIG="$work/missing-restore-config.json"
  STATE_FILE="$work/missing-restore-state.json"
  mkdir -p "$BACKUP_DIR"
  printf '%s\n' '{}' > "$SINGBOX_CONFIG"
  printf '%s\n' '{"schema_version":3,"users":[],"splits":[]}' > "$STATE_FILE"
  if restore_backup missing >/dev/null 2>&1; then
    echo 'restore should fail when transaction backup files are missing' >&2
    exit 1
  fi
)

(
  BACKUP_DIR="$work/staged-restore-backups"
  SINGBOX_CONFIG="$work/staged-restore-config.json"
  STATE_FILE="$work/staged-restore-state.json"
  SINGBOX_BIN=restore_mock_singbox
  SINGBOX_SERVICE=sing-box
  mkdir -p "$BACKUP_DIR"
  printf '%s\n' '{"marker":"current-config"}' > "$SINGBOX_CONFIG"
  printf '%s\n' '{"marker":"current-state"}' > "$STATE_FILE"
  printf '%s\n' '{"marker":"backup-config"}' > "$BACKUP_DIR/config.json.staged"
  printf '%s\n' '{"marker":"backup-state"}' > "$BACKUP_DIR/managed-users.json.staged"
  restore_mock_singbox() {
    [[ "${1:-}" == check && "${2:-}" == -c ]] || return 1
    jq -e 'type == "object"' "$3" >/dev/null
  }
  systemctl() { return 0; }
  mv() {
    local destination="${@: -1}"
    if [[ "$destination" == "$SINGBOX_CONFIG" ]]; then return 66; fi
    command mv "$@"
  }
  if restore_backup staged >/dev/null 2>&1; then
    echo 'staged restore should fail when the final config rename fails' >&2
    exit 1
  fi
  [[ "$(jq -r '.marker' "$SINGBOX_CONFIG")" == current-config ]]
  [[ "$(jq -r '.marker' "$STATE_FILE")" == current-state ]]
  if find "$work" -maxdepth 1 \( -name '.restore-config.*' -o -name '.restore-state.*' -o -name '.restore-previous-state.*' \) -print -quit | grep -q .; then
    echo 'failed staged restore left temporary files behind' >&2
    exit 1
  fi
)

# 管理配置恢复由文件属性检查和白名单解析负责，不再把配置误当成 shell 脚本校验。
(
  BACKUP_DIR="$work/manager-config-restore-backups"
  SINGBOX_CONFIG="$work/manager-config-restore-config.json"
  STATE_FILE="$work/manager-config-restore-state.json"
  CONF_FILE="$work/manager-config-restore.conf"
  SINGBOX_BIN=restore_manager_mock_singbox
  SINGBOX_SERVICE=sing-box
  mkdir -p "$BACKUP_DIR"
  printf '%s\n' '{"marker":"current-config"}' > "$SINGBOX_CONFIG"
  printf '%s\n' '{"marker":"current-state"}' > "$STATE_FILE"
  printf '%s\n' 'HANDSHAKE_PORT=443' > "$CONF_FILE"
  chmod 600 "$CONF_FILE"
  printf '%s\n' '{"marker":"backup-config"}' > "$BACKUP_DIR/config.json.manager-valid"
  printf '%s\n' '{"marker":"backup-state"}' > "$BACKUP_DIR/managed-users.json.manager-valid"
  printf '%s\n' 'HANDSHAKE_PORT=8443' 'ANYTLS_SNI="restore.example.com"' > "$BACKUP_DIR/sb-user-manager.conf.manager-valid"
  chmod 600 "$BACKUP_DIR/sb-user-manager.conf.manager-valid"
  restore_manager_mock_singbox() {
    [[ "${1:-}" == check && "${2:-}" == -c ]] || return 1
    jq -e 'type == "object"' "$3" >/dev/null
  }
  systemctl() { return 0; }
  restore_backup manager-valid
  [[ "$HANDSHAKE_PORT" == 8443 && "$ANYTLS_SNI" == restore.example.com ]]
  grep -Fxq 'HANDSHAKE_PORT=8443' "$CONF_FILE"
)

(
  BACKUP_DIR="$work/manager-config-reject-backups"
  SINGBOX_CONFIG="$work/manager-config-reject-config.json"
  STATE_FILE="$work/manager-config-reject-state.json"
  CONF_FILE="$work/manager-config-reject.conf"
  SINGBOX_BIN=restore_manager_reject_mock_singbox
  SINGBOX_SERVICE=sing-box
  command_marker="$work/manager-config-restore-command-ran"
  mkdir -p "$BACKUP_DIR"
  printf '%s\n' '{"marker":"current-config"}' > "$SINGBOX_CONFIG"
  printf '%s\n' '{"marker":"current-state"}' > "$STATE_FILE"
  printf '%s\n' 'HANDSHAKE_PORT=443' > "$CONF_FILE"
  chmod 600 "$CONF_FILE"
  printf '%s\n' '{"marker":"backup-config"}' > "$BACKUP_DIR/config.json.manager-invalid"
  printf '%s\n' '{"marker":"backup-state"}' > "$BACKUP_DIR/managed-users.json.manager-invalid"
  printf 'GITHUB_TOKEN="$(touch %s)"\n' "$command_marker" > "$BACKUP_DIR/sb-user-manager.conf.manager-invalid"
  chmod 600 "$BACKUP_DIR/sb-user-manager.conf.manager-invalid"
  restore_manager_reject_mock_singbox() {
    [[ "${1:-}" == check && "${2:-}" == -c ]] || return 1
    jq -e 'type == "object"' "$3" >/dev/null
  }
  systemctl() { return 0; }
  restore_backup manager-invalid
) >/dev/null 2>&1 && {
  echo 'runtime config shell syntax should be rejected by the whitelist parser during restore' >&2
  exit 1
}
[[ ! -e "$work/manager-config-restore-command-ran" ]]

# 未知配置键也必须在真实恢复链中由白名单拒绝。
(
  BACKUP_DIR="$work/manager-config-unknown-backups"
  SINGBOX_CONFIG="$work/manager-config-unknown-config.json"
  STATE_FILE="$work/manager-config-unknown-state.json"
  CONF_FILE="$work/manager-config-unknown.conf"
  SINGBOX_BIN=restore_manager_unknown_mock_singbox
  SINGBOX_SERVICE=sing-box
  mkdir -p "$BACKUP_DIR"
  printf '%s\n' '{"marker":"current-config"}' > "$SINGBOX_CONFIG"
  printf '%s\n' '{"marker":"current-state"}' > "$STATE_FILE"
  printf '%s\n' 'HANDSHAKE_PORT=443' > "$CONF_FILE"
  chmod 600 "$CONF_FILE"
  printf '%s\n' '{"marker":"backup-config"}' > "$BACKUP_DIR/config.json.manager-unknown"
  printf '%s\n' '{"marker":"backup-state"}' > "$BACKUP_DIR/managed-users.json.manager-unknown"
  printf '%s\n' 'UNEXPECTED_SETTING=value' > "$BACKUP_DIR/sb-user-manager.conf.manager-unknown"
  chmod 600 "$BACKUP_DIR/sb-user-manager.conf.manager-unknown"
  restore_manager_unknown_mock_singbox() {
    [[ "${1:-}" == check && "${2:-}" == -c ]] || return 1
    jq -e 'type == "object"' "$3" >/dev/null
  }
  systemctl() { return 0; }
  restore_backup manager-unknown
) >/dev/null 2>&1 && {
  echo 'unknown runtime config settings should be rejected by the whitelist parser during restore' >&2
  exit 1
}

restore_backup_body="$(declare -f restore_backup)"
if grep -Fq 'bash -n "$manager_tmp"' <<<"$restore_backup_body"; then
  echo 'restore_backup must not treat the runtime config as a shell script' >&2
  exit 1
fi

(
  BACKUP_DIR="$work/durable-transaction-backups"
  TRANSACTION_DIR="$work/durable-transactions"
  TRANSACTION_JOURNAL="$TRANSACTION_DIR/active.json"
  ENVIRONMENT_TRANSACTION_JOURNAL="$work/durable-environment-recovery.json"
  SINGBOX_CONFIG="$work/durable-config.json"
  STATE_FILE="$work/durable-state.json"
  CONF_FILE="$work/durable-manager.conf"
  SINGBOX_BIN=durable_singbox
  SINGBOX_SERVICE=sing-box
  nfuse_state="$work/durable-nfuse.json"
  mkdir -p "$BACKUP_DIR" "$TRANSACTION_DIR"
  printf '%s\n' '{"marker":"before","inbounds":[],"outbounds":[],"route":{"rules":[],"rule_set":[]}}' > "$SINGBOX_CONFIG"
  printf '%s\n' '{"schema_version":3,"users":[{"name":"alice","port":20001,"status":"active","metered":true,"limit_gib":2,"billing_anchor":5},{"name":"self-user","port":20002,"status":"active","metered":false,"usage_offset_bytes":10}],"splits":[]}' > "$STATE_FILE"
  printf '%s\n' 'SS2022_SHADOWTLS_SNI="before-ss.example.com"' 'ANYTLS_SNI="before-any.example.com"' > "$CONF_FILE"
  printf '%s\n' '[
    {"id":1,"name":"external","tier":"b","limit_gib":9,"limit_bytes":9663676416,"used_bytes":321,"ports":[{"id":1,"start":19999,"end":19999}]},
    {"id":2,"name":"alice","tier":"a","limit_gib":2,"limit_bytes":2147483648,"used_bytes":456,"ports":[{"id":2,"start":20001,"end":20001}]},
    {"id":3,"name":"self-user","tier":"c","limit_gib":0,"limit_bytes":0,"used_bytes":55,"ports":[{"id":3,"start":20002,"end":20002}]}
  ]' > "$nfuse_state"
  cp "$STATE_FILE" "$work/durable-state.before.json"
  cp "$SINGBOX_CONFIG" "$work/durable-config.before.json"
  cp "$CONF_FILE" "$work/durable-manager.before.conf"
  durable_singbox() {
    [[ "${1:-}" == check && "${2:-}" == -c ]] || return 1
    jq -e 'type == "object"' "$3" >/dev/null
  }
  systemctl() { return 0; }
  sync_transaction_path() { return 0; }
  nfuse_update() {
    local filter="$1" tmp="$nfuse_state.tmp"
    shift
    jq "$@" "$filter" "$nfuse_state" > "$tmp" && mv "$tmp" "$nfuse_state"
  }
  nfuse() {
    local command="${1:-}" name spec start end limit_bytes
    case "$command" in
      list) [[ "${2:-}" == --json ]] && cat "$nfuse_state";;
      persist) return 0;;
      rm) nfuse_update 'map(select(.name != $name))' --arg name "$2";;
      add)
        # 模拟「删除成功但重建失败」：账户会从流量库彻底消失，脚本必须给出可执行的补救命令。
        if [[ "${nfuse_fails_add:-false}" == true ]]; then
          printf 'nfuse: daemon is not available\n' >&2
          return 70
        fi
        name="$2"; limit_bytes="$(awk -v value="$6" 'BEGIN {printf "%.0f", value*1073741824}')"
        nfuse_update '. += [{id:99,name:$name,tier:$tier,limit_gib:$limit,limit_bytes:$limit_bytes,used_bytes:0,ports:[]}]' \
          --arg name "$name" --arg tier "$4" --argjson limit "$6" --argjson limit_bytes "$limit_bytes"
        ;;
      set-tier)
        name="$2"; limit_bytes="$(awk -v value="$6" 'BEGIN {printf "%.0f", value*1073741824}')"
        nfuse_update '(.[] | select(.name == $name)) |= (.tier=$tier | .limit_gib=$limit | .limit_bytes=$limit_bytes)' \
          --arg name "$name" --arg tier "$4" --argjson limit "$6" --argjson limit_bytes "$limit_bytes"
        ;;
      set-usage)
        # 真实 Nfuse 是否接受对不限额账户设置用量无从验证，这个开关用来模拟它拒绝的情况。
        if [[ "${nfuse_rejects_tier_c_set_usage:-false}" == true ]] &&
           jq -e --arg name "$2" 'any(.[]; .name == $name and .tier == "c")' "$nfuse_state" >/dev/null; then
          printf 'nfuse: set-usage is not supported for unlimited accounts\n' >&2
          return 65
        fi
        nfuse_update '(.[] | select(.name == $name) | .used_bytes) = $used' --arg name "$2" --argjson used "$3"
        ;;
      port)
        case "$2" in
          rm) nfuse_update 'map(.ports |= map(select(.id != $id)))' --argjson id "$3";;
          add)
            name="$3"; spec="$4"
            if [[ "$spec" == *-* ]]; then start="${spec%-*}"; end="${spec#*-}"; else start="$spec"; end="$spec"; fi
            nfuse_update '(.[] | select(.name == $name) | .ports) += [{id:999,start:$port_start,end:$port_end}]' \
              --arg name "$name" --argjson port_start "$start" --argjson port_end "$end"
            ;;
          *) return 64;;
        esac
        ;;
      *) return 64;;
    esac
  }

  printf '%s\n' '{}' > "$ENVIRONMENT_TRANSACTION_JOURNAL"
  if begin_operation_transaction 'blocked-by-environment' > "$work/operation-blocked-by-environment.out" 2>&1; then
    echo 'user transaction should reject an active environment journal' >&2
    exit 1
  fi
  [[ ! -e "$TRANSACTION_JOURNAL" ]]
  grep -Fq '发现尚未完成的环境操作' "$work/operation-blocked-by-environment.out"
  rm -f -- "$ENVIRONMENT_TRANSACTION_JOURNAL"

  begin_operation_transaction 'unit-power-loss'
  [[ -f "$TRANSACTION_JOURNAL" ]]
  validate_transaction_journal
  stamp="$ACTIVE_TRANSACTION_STAMP"
  [[ -f "$BACKUP_DIR/config.json.$stamp" && -f "$BACKUP_DIR/managed-users.json.$stamp" && -f "$BACKUP_DIR/sb-user-manager.conf.$stamp" && -f "$BACKUP_DIR/nfuse.json.$stamp" ]]

  printf '%s\n' '{"marker":"interrupted","inbounds":[{"tag":"new"}],"outbounds":[],"route":{"rules":[],"rule_set":[]}}' > "$SINGBOX_CONFIG"
  printf '%s\n' '{"schema_version":3,"users":[{"name":"alice","port":20009,"status":"disabled","metered":true,"limit_gib":7,"billing_anchor":8},{"name":"bob","port":20002,"status":"active","metered":true,"limit_gib":1,"billing_anchor":1}],"splits":[]}' > "$STATE_FILE"
  printf '%s\n' 'SS2022_SHADOWTLS_SNI="interrupted.example.com"' 'ANYTLS_SNI="interrupted-any.example.com"' > "$CONF_FILE"
  printf '%s\n' '[
    {"id":1,"name":"external","tier":"b","limit_gib":9,"limit_bytes":9663676416,"used_bytes":321,"ports":[{"id":1,"start":19999,"end":19999}]},
    {"id":2,"name":"alice","tier":"a","limit_gib":7,"limit_bytes":7516192768,"used_bytes":0,"ports":[{"id":20,"start":20009,"end":20009}]},
    {"id":3,"name":"bob","tier":"a","limit_gib":1,"limit_bytes":1073741824,"used_bytes":10,"ports":[{"id":30,"start":20002,"end":20002}]}
  ]' > "$nfuse_state"
  ACTIVE_TRANSACTION_STAMP=""
  ACTIVE_TRANSACTION_OPERATION=""
  ACTIVE_TRANSACTION_DEPTH=0

  recover_pending_transaction
  [[ ! -e "$TRANSACTION_JOURNAL" ]]
  cmp -s "$SINGBOX_CONFIG" "$work/durable-config.before.json"
  jq -e '
    (.users|length) == 2 and
    (.users[] | select(.name == "alice") | .port) == 20001 and
    (.users[] | select(.name == "self-user") | .usage_offset_bytes) == 65
  ' "$STATE_FILE" >/dev/null
  cmp -s "$CONF_FILE" "$work/durable-manager.before.conf"
  [[ "$SS2022_SHADOWTLS_SNI" == before-ss.example.com && "$ANYTLS_SNI" == before-any.example.com ]]
  jq -e '
    length == 3 and
    any(.[]; .name == "external" and .used_bytes == 321 and .ports[0].start == 19999) and
    any(.[]; .name == "alice" and .tier == "a" and .limit_gib == 2 and .used_bytes == 456 and (.ports|length)==1 and .ports[0].start == 20001) and
    any(.[]; .name == "self-user" and .tier == "c" and .used_bytes == 0 and (.ports|length)==1 and .ports[0].start == 20002) and
    all(.[]; .name != "bob")
  ' "$nfuse_state" >/dev/null

  # 自用账户在操作中存活（没有被删掉重建）时，tier c 的用量同样必须归零，
  # 否则收尾校验只要服务器上有跑过流量的自用用户就必然失败。
  nfuse_update '(.[] | select(.name == "self-user") | .used_bytes) = 70'
  begin_operation_transaction 'unit-self-user-survives'
  stamp="$ACTIVE_TRANSACTION_STAMP"
  jq -e 'any(.[]; .name == "self-user" and .tier == "c" and .used_bytes == 70)' "$BACKUP_DIR/nfuse.json.$stamp" >/dev/null
  printf '%s\n' '{"schema_version":3,"users":[{"name":"alice","port":20011,"status":"active","metered":true,"limit_gib":3,"billing_anchor":5},{"name":"self-user","port":20002,"status":"active","metered":false,"usage_offset_bytes":65}],"splits":[]}' > "$STATE_FILE"
  nfuse_update '(.[] | select(.name == "alice") | .limit_gib) = 3'
  nfuse_update '(.[] | select(.name == "self-user") | .used_bytes) = 90'
  ACTIVE_TRANSACTION_STAMP=""
  ACTIVE_TRANSACTION_OPERATION=""
  ACTIVE_TRANSACTION_DEPTH=0

  recover_pending_transaction
  [[ ! -e "$TRANSACTION_JOURNAL" ]]
  jq -e '
    any(.[]; .name == "alice" and .tier == "a" and .limit_gib == 2 and .used_bytes == 456) and
    any(.[]; .name == "self-user" and .tier == "c" and .used_bytes == 0 and (.ports|length)==1 and .ports[0].start == 20002)
  ' "$nfuse_state" >/dev/null
  jq -e '
    (.users[] | select(.name == "alice") | .port) == 20001 and
    (.users[] | select(.name == "self-user") | .usage_offset_bytes) == 135
  ' "$STATE_FILE" >/dev/null

  # Nfuse 若拒绝对不限额账户设置用量，回滚必须退回到删除重建，而不是整体失败；
  # 回滚前后的显示用量（used_bytes + usage_offset_bytes）必须守恒，端口也要按快照重新补回。
  printf '%s\n' '{"schema_version":3,"users":[{"name":"alice","port":20001,"status":"active","metered":true,"limit_gib":2,"billing_anchor":5},{"name":"self-user","port":20002,"status":"active","metered":false,"usage_offset_bytes":65}],"splits":[]}' > "$STATE_FILE"
  nfuse_update '(.[] | select(.name == "self-user") | .used_bytes) = 70'
  nfuse_rejects_tier_c_set_usage=true
  begin_operation_transaction 'unit-self-user-set-usage-rejected'
  stamp="$ACTIVE_TRANSACTION_STAMP"
  jq -e 'any(.[]; .name == "self-user" and .tier == "c" and .used_bytes == 70)' "$BACKUP_DIR/nfuse.json.$stamp" >/dev/null
  printf '%s\n' '{"schema_version":3,"users":[{"name":"alice","port":20011,"status":"active","metered":true,"limit_gib":3,"billing_anchor":5},{"name":"self-user","port":20002,"status":"active","metered":false,"usage_offset_bytes":65}],"splits":[]}' > "$STATE_FILE"
  nfuse_update '(.[] | select(.name == "alice") | .limit_gib) = 3'
  nfuse_update '(.[] | select(.name == "self-user") | .used_bytes) = 90'
  ACTIVE_TRANSACTION_STAMP=""
  ACTIVE_TRANSACTION_OPERATION=""
  ACTIVE_TRANSACTION_DEPTH=0

  # 自动恢复失败时 recover_pending_transaction 会直接 die，套一层子 shell 才能把失败点留在本用例里
  rc=0
  ( recover_pending_transaction ) > "$work/self-user-set-usage-rejected.out" 2>&1 || rc=$?
  if [[ "$rc" != 0 ]]; then
    echo 'rollback must still succeed when nfuse refuses set-usage on an unlimited account' >&2
    cat "$work/self-user-set-usage-rejected.out" >&2
    exit 1
  fi
  [[ ! -e "$TRANSACTION_JOURNAL" ]]
  jq -e '
    any(.[]; .name == "self-user" and .tier == "c" and .limit_gib == 0 and .used_bytes == 0 and (.ports|length)==1 and .ports[0].start == 20002) and
    any(.[]; .name == "alice" and .tier == "a" and .limit_gib == 2 and .used_bytes == 456)
  ' "$nfuse_state" >/dev/null
  jq -e '(.users[] | select(.name == "self-user") | .usage_offset_bytes) == 135' "$STATE_FILE" >/dev/null
  grep -Fq '改用删除后重建的方式恢复' "$work/self-user-set-usage-rejected.out"
  nfuse_rejects_tier_c_set_usage=false

  # 删除重建的最坏情况：删成功、建失败，自用账户彻底丢失。
  # 恢复流程不能只留下一句「自动恢复失败」，必须点名账户并给出可直接照抄的重建命令。
  (
    nfuse_rejects_tier_c_set_usage=true
    nfuse_fails_add=true
    rebuild_out="$work/tier-c-rebuild-failure.out"
    if restore_nfuse_snapshot "$stamp" > "$rebuild_out" 2>&1; then
      echo 'restoring must fail when the self-use account cannot be recreated' >&2
      exit 1
    fi
    if ! grep -Fq '已从流量库删除但未能重建' "$rebuild_out"; then
      echo 'a lost self-use account must be named explicitly in the log' >&2
      exit 1
    fi
    if ! grep -Fq 'nfuse add self-user --tier c' "$rebuild_out"; then
      echo 'the log must contain a runnable command to recreate the lost account' >&2
      exit 1
    fi
    if ! grep -Fq 'daemon is not available' "$rebuild_out"; then
      echo "Nfuse 的原始错误必须保留，管理员据此才能分辨故障类型" >&2
      exit 1
    fi
  )

  begin_operation_transaction 'nested-outer'
  begin_operation_transaction 'nested-inner'
  [[ "$ACTIVE_TRANSACTION_DEPTH" == 2 && -f "$TRANSACTION_JOURNAL" ]]
  commit_operation_transaction
  [[ "$ACTIVE_TRANSACTION_DEPTH" == 1 && -f "$TRANSACTION_JOURNAL" ]]
  commit_operation_transaction
  [[ "$ACTIVE_TRANSACTION_DEPTH" == 0 && ! -e "$TRANSACTION_JOURNAL" ]]
)

# 提交失败时改动已经被回滚，finish_managed_operation 必须把失败码交给调用方，
# 否则界面会在数据已经撤销的情况下打印成功提示。
(
  events="$work/finish-commit-failure-events"
  ACTIVE_TRANSACTION_STAMP=20240101-000000-1.1
  ACTIVE_TRANSACTION_OPERATION=finish-commit-failure
  ACTIVE_TRANSACTION_DEPTH=1
  commit_operation_transaction() { return 77; }
  rollback_operation_transaction() { printf 'rollback %s\n' "$1" >> "$events"; return "$1"; }
  if finish_managed_operation > "$work/finish-commit-failure.out" 2>&1; then
    echo 'finish_managed_operation must fail when the commit fails' >&2
    exit 1
  else
    rc=$?
  fi
  [[ "$rc" == 77 ]]
  diff -u <(printf 'rollback 77\n') "$events"
)

# 数据已经全部落盘、只有恢复标记的清理没能同步时，操作事实上已经提交成功：
# 此时既不能说「正在恢复」，也不能一个恢复动作都不执行就让用户以为改动已经被撤销。
(
  events="$work/commit-cleanup-failure-events"
  TRANSACTION_DIR="$work/commit-cleanup-failure"
  TRANSACTION_JOURNAL="$TRANSACTION_DIR/active.json"
  SINGBOX_CONFIG="$work/commit-cleanup-config.json"
  STATE_FILE="$work/commit-cleanup-state.json"
  CONF_FILE="$work/commit-cleanup-manager.conf"
  NFUSE_DB="$work/commit-cleanup-nfuse.db"
  mkdir -p "$TRANSACTION_DIR"
  printf '%s\n' '{"marker":"committed"}' > "$SINGBOX_CONFIG"
  printf '%s\n' '{"schema_version":3,"users":[],"splits":[]}' > "$STATE_FILE"
  printf '%s\n' '{"backup_stamp":"20240101-000000-1.1"}' > "$TRANSACTION_JOURNAL"
  ACTIVE_TRANSACTION_STAMP=20240101-000000-1.1
  ACTIVE_TRANSACTION_OPERATION=commit-cleanup-failure
  ACTIVE_TRANSACTION_DEPTH=1
  nfuse() { [[ "${1:-}" == persist ]]; }
  # 只有事务目录的 sync 失败：数据都已经写入并同步，日志文件也已经删掉
  sync_transaction_path() { [[ "$1" != "$TRANSACTION_DIR" ]]; }
  prune_operation_transaction_backups() { return 0; }
  restore_nfuse_snapshot() { printf 'nfuse %s\n' "$1" >> "$events"; }
  restore_backup() { printf 'backup %s\n' "$1" >> "$events"; }
  restore_tier_c_usage_offsets() { printf 'offsets %s\n' "$1" >> "$events"; }
  rc=0
  finish_managed_operation > "$work/commit-cleanup-failure.out" 2>&1 || rc=$?
  if grep -Fq '正在恢复' "$work/commit-cleanup-failure.out"; then
    echo 'a committed operation must never claim that the data is being restored' >&2
    exit 1
  fi
  if [[ -e "$events" ]]; then
    echo 'no restore step may run when the data was already committed' >&2
    exit 1
  fi
  grep -Fq '修改已经保存成功' "$work/commit-cleanup-failure.out"
  if [[ "$rc" != 0 ]]; then
    echo "a committed operation must not be reported as failed: rc=$rc" >&2
    exit 1
  fi
  [[ ! -e "$TRANSACTION_JOURNAL" ]]
  [[ "$ACTIVE_TRANSACTION_DEPTH" == 0 && -z "$ACTIVE_TRANSACTION_STAMP" ]]
)

# 恢复标记删不掉是另一回事：下次启动会按它无条件回滚，把这次修改悄悄撤销。
# 此时绝不能报告成功，必须当场失败并说明原因。
(
  events="$work/commit-journal-kept-events"
  TRANSACTION_DIR="$work/commit-journal-kept"
  TRANSACTION_JOURNAL="$TRANSACTION_DIR/active.json"
  SINGBOX_CONFIG="$work/commit-journal-kept-config.json"
  STATE_FILE="$work/commit-journal-kept-state.json"
  CONF_FILE="$work/commit-journal-kept-manager.conf"
  NFUSE_DB="$work/commit-journal-kept-nfuse.db"
  mkdir -p "$TRANSACTION_DIR"
  printf '%s\n' '{"marker":"committed"}' > "$SINGBOX_CONFIG"
  printf '%s\n' '{"schema_version":3,"users":[],"splits":[]}' > "$STATE_FILE"
  printf '%s\n' '{"backup_stamp":"20240101-000000-1.1"}' > "$TRANSACTION_JOURNAL"
  ACTIVE_TRANSACTION_STAMP=20240101-000000-1.1
  ACTIVE_TRANSACTION_OPERATION=commit-journal-kept
  ACTIVE_TRANSACTION_DEPTH=1
  nfuse() { [[ "${1:-}" == persist ]]; }
  sync_transaction_path() { return 0; }
  prune_operation_transaction_backups() { return 0; }
  # 删除失败：恢复标记留在磁盘上
  rm() { if [[ "${*}" == *"$TRANSACTION_JOURNAL"* ]]; then return 1; fi; command rm "$@"; }
  restore_nfuse_snapshot() { printf 'nfuse %s\n' "$1" >> "$events"; }
  restore_backup() { printf 'backup %s\n' "$1" >> "$events"; }
  restore_tier_c_usage_offsets() { printf 'offsets %s\n' "$1" >> "$events"; }
  rc=0
  commit_operation_transaction > "$work/commit-journal-kept.out" 2>&1 || rc=$?
  if [[ "$rc" == 0 ]]; then
    echo 'a commit whose recovery journal survives must not be reported as successful' >&2
    exit 1
  fi
  if grep -Fq '修改已经保存成功' "$work/commit-journal-kept.out"; then
    echo 'the message must not claim success while the journal still triggers a rollback' >&2
    exit 1
  fi
  grep -Fq '下次启动会按它自动撤销本次修改' "$work/commit-journal-kept.out"
  [[ -e "$TRANSACTION_JOURNAL" ]]
)

# 日志删除成功、目录同步失败时也必须复位内存状态，否则后续操作会在没有日志保护的情况下空嵌套。
(
  TRANSACTION_DIR="$work/clear-transaction-partial"
  TRANSACTION_JOURNAL="$TRANSACTION_DIR/active.json"
  mkdir -p "$TRANSACTION_DIR"
  printf '%s\n' '{"backup_stamp":"20240101-000000-1.1"}' > "$TRANSACTION_JOURNAL"
  ACTIVE_TRANSACTION_STAMP=20240101-000000-1.1
  ACTIVE_TRANSACTION_OPERATION=clear-partial
  ACTIVE_TRANSACTION_DEPTH=1
  sync_transaction_path() { return 1; }
  if clear_operation_transaction; then
    echo 'clear_operation_transaction must report the failed directory sync' >&2
    exit 1
  fi
  [[ ! -e "$TRANSACTION_JOURNAL" ]]
  [[ "$ACTIVE_TRANSACTION_DEPTH" == 0 && -z "$ACTIVE_TRANSACTION_STAMP" && -z "$ACTIVE_TRANSACTION_OPERATION" ]]
)

# 嵌套事务必须确认日志仍然存在且指向本次备份组，不满足时明确失败而不是静默嵌套。
(
  TRANSACTION_DIR="$work/nested-invariant"
  TRANSACTION_JOURNAL="$TRANSACTION_DIR/active.json"
  mkdir -p "$TRANSACTION_DIR"
  ACTIVE_TRANSACTION_STAMP=20240101-000000-1.1
  ACTIVE_TRANSACTION_OPERATION=nested-invariant
  ACTIVE_TRANSACTION_DEPTH=1
  if begin_operation_transaction 'nested-without-journal' > "$work/nested-invariant.out" 2>&1; then
    echo 'nested transaction must fail when the recovery journal is gone' >&2
    exit 1
  fi
  [[ "$ACTIVE_TRANSACTION_DEPTH" == 1 ]]
  grep -Fq '恢复记录已经丢失或不匹配' "$work/nested-invariant.out"
  printf '%s\n' '{"backup_stamp":"20240101-000000-2.2"}' > "$TRANSACTION_JOURNAL"
  if begin_operation_transaction 'nested-stamp-mismatch' >/dev/null 2>&1; then
    echo 'nested transaction must fail when the recovery journal points at another backup group' >&2
    exit 1
  fi
  [[ "$ACTIVE_TRANSACTION_DEPTH" == 1 ]]
)

# mv 成功即表示日志已经生效；结尾的目录同步失败不能把已安装的日志当成写入失败。
(
  TRANSACTION_DIR="$work/journal-dir-sync"
  TRANSACTION_JOURNAL="$TRANSACTION_DIR/active.json"
  sync_transaction_path() { [[ "$1" != "$TRANSACTION_DIR" ]]; }
  write_transaction_journal 'journal-dir-sync' '20240101-000000-1.1' > "$work/journal-dir-sync.out"
  [[ -f "$TRANSACTION_JOURNAL" ]]
  validate_transaction_journal
  grep -Fq '恢复记录目录未能同步到磁盘' "$work/journal-dir-sync.out"
)

# 日志一旦写入，失败清理就不能删掉同一 stamp 的备份组，否则会留下让脚本每次启动都失败的孤儿日志。
(
  BACKUP_DIR="$work/orphan-journal-backups"
  TRANSACTION_DIR="$work/orphan-journal-transactions"
  TRANSACTION_JOURNAL="$TRANSACTION_DIR/active.json"
  ENVIRONMENT_TRANSACTION_JOURNAL="$work/orphan-journal-environment.json"
  SINGBOX_CONFIG="$work/orphan-journal-config.json"
  STATE_FILE="$work/orphan-journal-state.json"
  CONF_FILE="$work/orphan-journal-manager.conf"
  mkdir -p "$BACKUP_DIR" "$TRANSACTION_DIR"
  printf '%s\n' '{"marker":"before"}' > "$SINGBOX_CONFIG"
  printf '%s\n' '{"schema_version":3,"users":[],"splits":[]}' > "$STATE_FILE"
  printf '%s\n' 'SS2022_SHADOWTLS_SNI="before-ss.example.com"' > "$CONF_FILE"
  ACTIVE_TRANSACTION_STAMP=""
  ACTIVE_TRANSACTION_OPERATION=""
  ACTIVE_TRANSACTION_DEPTH=0
  sync_transaction_path() { return 0; }
  nfuse() {
    case "${1:-}" in
      list) [[ "${2:-}" == --json ]] && printf '%s\n' '[]';;
      persist) return 0;;
      *) return 64;;
    esac
  }
  write_transaction_journal() {
    printf '{"format_version":%s,"status":"active","operation":"%s","backup_stamp":"%s","started_at":"unit","script_version":"%s","pid":%s}\n' \
      "$TRANSACTION_FORMAT_VERSION" "$1" "$2" "$SCRIPT_VERSION" "$$" > "$TRANSACTION_JOURNAL"
    return 1
  }
  if begin_operation_transaction 'orphan-journal' > "$work/orphan-journal.out" 2>&1; then
    echo 'begin_operation_transaction must fail when the journal cannot be completed' >&2
    exit 1
  fi
  [[ "$ACTIVE_TRANSACTION_DEPTH" == 0 ]]
  validate_transaction_journal
  orphan_stamp="$(jq -r '.backup_stamp' "$TRANSACTION_JOURNAL")"
  operation_backup_group_is_complete "$orphan_stamp"
  [[ -f "$BACKUP_DIR/nfuse.json.$orphan_stamp" ]]
)

# 回滚链必须逐项执行，前一步失败也不能跳过后面的恢复动作。
(
  events="$work/rollback-chain-events"
  TRANSACTION_JOURNAL="$work/rollback-chain-journal.json"
  ACTIVE_TRANSACTION_STAMP=20240101-000000-1.1
  ACTIVE_TRANSACTION_OPERATION=rollback-chain
  ACTIVE_TRANSACTION_DEPTH=1
  restore_nfuse_snapshot() { printf 'nfuse %s\n' "$1" >> "$events"; return 1; }
  restore_backup() { printf 'backup %s\n' "$1" >> "$events"; }
  restore_tier_c_usage_offsets() { printf 'offsets %s\n' "$1" >> "$events"; }
  if rollback_operation_transaction 9 > "$work/rollback-chain.out" 2>&1; then
    echo 'rollback must fail when a restore step fails' >&2
    exit 1
  else
    rc=$?
  fi
  [[ "$rc" == 1 ]]
  diff -u <(printf 'nfuse 20240101-000000-1.1\nbackup 20240101-000000-1.1\noffsets 20240101-000000-1.1\n') "$events"
)

# 但第三步依赖第二步：restore_backup 失败时状态文件还没被还原，
# 再累加 usage_offset_bytes 会在每次自动恢复时重复叠加一份快照用量。
(
  events="$work/rollback-offset-guard-events"
  TRANSACTION_JOURNAL="$work/rollback-offset-guard-journal.json"
  ACTIVE_TRANSACTION_STAMP=20240101-000000-1.1
  ACTIVE_TRANSACTION_OPERATION=rollback-offset-guard
  ACTIVE_TRANSACTION_DEPTH=1
  restore_nfuse_snapshot() { printf 'nfuse %s\n' "$1" >> "$events"; }
  restore_backup() { printf 'backup %s\n' "$1" >> "$events"; return 1; }
  restore_tier_c_usage_offsets() { printf 'offsets %s\n' "$1" >> "$events"; }
  if rollback_operation_transaction 9 > "$work/rollback-offset-guard.out" 2>&1; then
    echo 'rollback must fail when restoring the backup fails' >&2
    exit 1
  fi
  if grep -Fq 'offsets ' "$events"; then
    echo 'usage offsets must not be re-applied when the state file was not restored' >&2
    exit 1
  fi
  diff -u <(printf 'nfuse 20240101-000000-1.1\nbackup 20240101-000000-1.1\n') "$events"
)

# 环境锁目录已存在时只做类型检查：符号链接必须拒绝，且不得改动目标目录权限。
(
  ENVIRONMENT_LOCK_FILE="$work/environment-lock-symlink/lock-dir/environment.lock"
  ENVIRONMENT_TRANSACTION_JOURNAL="$work/environment-lock-symlink/recovery.json"
  TRANSACTION_JOURNAL="$work/environment-lock-symlink/operation.json"
  mkdir -p "$work/environment-lock-symlink/real-lock-dir"
  chmod 700 "$work/environment-lock-symlink/real-lock-dir"
  ln -s "$work/environment-lock-symlink/real-lock-dir" "$work/environment-lock-symlink/lock-dir"
  if begin_environment_transaction lock-symlink "$work/environment-lock-symlink/snapshot" /usr/local/bin/nfuse \
      > "$work/environment-lock-symlink.out" 2>&1; then
    echo 'environment transaction must reject a symlinked lock directory' >&2
    exit 1
  fi
  [[ ! -e "$ENVIRONMENT_LOCK_FILE" ]]
  [[ "$(manager_file_mode "$work/environment-lock-symlink/real-lock-dir")" == 700 ]]
)

(
  SB_SYSTEM_ROOT="$work/environment-root"
  ENVIRONMENT_BACKUP_BASE="$work/environment-snapshots"
  ENVIRONMENT_TRANSACTION_JOURNAL="$work/environment-recovery.json"
  ENVIRONMENT_LOCK_FILE="$work/environment-recovery.lock"
  TRANSACTION_JOURNAL="$work/environment-operation-active.json"
  flock() { return 0; }
  mkdir -p "$SB_SYSTEM_ROOT/etc/sing-box" "$SB_SYSTEM_ROOT/etc" "$SB_SYSTEM_ROOT/usr/local/bin"
  printf 'before\n' > "$SB_SYSTEM_ROOT/etc/sb-user-manager.conf"
  printf '%s\n' '{"marker":"before"}' > "$SB_SYSTEM_ROOT/etc/sing-box/config.json"
  printf 'old-sing-box\n' > "$SB_SYSTEM_ROOT/usr/local/bin/sing-box"
  chmod 755 "$SB_SYSTEM_ROOT/usr/local/bin/sing-box"
  create_environment_backup
  snapshot="$ENV_BACKUP"
  # v4.22.7 及更早快照会保留可执行文件的 755；新版必须先安全迁移权限，再删除任何当前文件。
  chmod 755 "$snapshot/root/usr/local/bin/sing-box"
  printf '%s\n' '{}' > "$TRANSACTION_JOURNAL"
  if begin_environment_transaction environment-blocked "$snapshot" /usr/local/bin/nfuse \
      > "$work/environment-blocked-by-operation.out" 2>&1; then
    echo 'environment transaction should reject an active user journal' >&2
    exit 1
  fi
  [[ ! -e "$ENVIRONMENT_TRANSACTION_JOURNAL" ]]
  grep -Fq '发现尚未完成的用户或分流操作' "$work/environment-blocked-by-operation.out"
  if { printf x >&8; } 2>/dev/null; then
    echo 'rejected environment transaction should close fd 8' >&2
    exit 1
  fi
  rm -f -- "$TRANSACTION_JOURNAL"
  begin_environment_transaction environment-unit "$snapshot" /usr/local/bin/nfuse
  [[ -f "$ENVIRONMENT_TRANSACTION_JOURNAL" ]]
  validate_environment_transaction
  printf 'interrupted\n' > "$SB_SYSTEM_ROOT/etc/sb-user-manager.conf"
  printf '%s\n' '{"marker":"interrupted"}' > "$SB_SYSTEM_ROOT/etc/sing-box/config.json"
  printf 'new-binary\n' > "$SB_SYSTEM_ROOT/usr/local/bin/nfuse"
  if (
    acquire_operation_lock() {
      OPERATION_LOCK_ERROR='另一个管理操作正在进行，请等待完成后再试'
      return 1
    }
    recover_environment_transaction
  ) > "$work/environment-recovery-operation-lock.out" 2>&1; then
    echo 'environment recovery should reject an active user operation lock' >&2
    exit 1
  fi
  grep -Fq '另一个管理操作正在进行' "$work/environment-recovery-operation-lock.out"
  grep -Fxq interrupted "$SB_SYSTEM_ROOT/etc/sb-user-manager.conf"
  grep -Fxq new-binary "$SB_SYSTEM_ROOT/usr/local/bin/nfuse"
  [[ -f "$ENVIRONMENT_TRANSACTION_JOURNAL" ]]
  if (
    chmod() { return 99; }
    recover_environment_transaction
  ) >/dev/null 2>&1; then
    echo 'legacy snapshot recovery should stop when permission migration fails' >&2
    exit 1
  fi
  grep -Fxq new-binary "$SB_SYSTEM_ROOT/usr/local/bin/nfuse"
  [[ -f "$ENVIRONMENT_TRANSACTION_JOURNAL" ]]
  recover_environment_transaction
  [[ ! -e "$ENVIRONMENT_TRANSACTION_JOURNAL" && ! -e "$SB_SYSTEM_ROOT/usr/local/bin/nfuse" ]]
  if { printf x >&8; } 2>/dev/null; then
    echo 'successful environment recovery should close fd 8' >&2
    exit 1
  fi
  grep -Fxq before "$SB_SYSTEM_ROOT/etc/sb-user-manager.conf"
  jq -e '.marker == "before"' "$SB_SYSTEM_ROOT/etc/sing-box/config.json" >/dev/null
  grep -Fxq old-sing-box "$SB_SYSTEM_ROOT/usr/local/bin/sing-box"
  [[ "$(manager_file_mode "$snapshot/root/usr/local/bin/sing-box")" == 700 ]]

  # 自动恢复日志必须是当前运行身份拥有且组/其他用户不可访问的普通文件。
  unsafe_journal_target="$work/unsafe-environment-recovery-target.json"
  jq -n --argjson format "$TRANSACTION_FORMAT_VERSION" \
    --arg operation unsafe-journal-unit --arg snapshot "$snapshot" \
    '{format_version:$format,status:"active",kind:"environment",operation:$operation,snapshot:$snapshot,cleanup_paths:["/usr/local/bin/nfuse"]}' \
    > "$unsafe_journal_target"
  chmod 600 "$unsafe_journal_target"
  printf 'keep-symlink-target\n' > "$SB_SYSTEM_ROOT/usr/local/bin/nfuse"
  ln -s "$unsafe_journal_target" "$ENVIRONMENT_TRANSACTION_JOURNAL"
  if (recover_environment_transaction) >"$work/unsafe-symlink-recovery.out" 2>&1; then
    echo 'symlink environment recovery journal should be rejected' >&2
    exit 1
  fi
  grep -Fq '权限或类型不安全' "$work/unsafe-symlink-recovery.out"
  grep -Fxq keep-symlink-target "$SB_SYSTEM_ROOT/usr/local/bin/nfuse"
  [[ -L "$ENVIRONMENT_TRANSACTION_JOURNAL" ]]
  rm -f -- "$ENVIRONMENT_TRANSACTION_JOURNAL"

  cp "$unsafe_journal_target" "$ENVIRONMENT_TRANSACTION_JOURNAL"
  chmod 644 "$ENVIRONMENT_TRANSACTION_JOURNAL"
  printf 'keep-open-mode-target\n' > "$SB_SYSTEM_ROOT/usr/local/bin/nfuse"
  if (recover_environment_transaction) >"$work/unsafe-mode-recovery.out" 2>&1; then
    echo 'group-readable environment recovery journal should be rejected' >&2
    exit 1
  fi
  grep -Fq '权限或类型不安全' "$work/unsafe-mode-recovery.out"
  grep -Fxq keep-open-mode-target "$SB_SYSTEM_ROOT/usr/local/bin/nfuse"
  [[ -f "$ENVIRONMENT_TRANSACTION_JOURNAL" ]]
  rm -f -- "$ENVIRONMENT_TRANSACTION_JOURNAL"

  cp "$unsafe_journal_target" "$ENVIRONMENT_TRANSACTION_JOURNAL"
  chmod 600 "$ENVIRONMENT_TRANSACTION_JOURNAL"
  printf 'keep-wrong-owner-target\n' > "$SB_SYSTEM_ROOT/usr/local/bin/nfuse"
  if (
    manager_file_uid() { printf '999999999\n'; }
    recover_environment_transaction
  ) >"$work/unsafe-owner-recovery.out" 2>&1; then
    echo 'wrong-owner environment recovery journal should be rejected' >&2
    exit 1
  fi
  grep -Fq '权限或类型不安全' "$work/unsafe-owner-recovery.out"
  grep -Fxq keep-wrong-owner-target "$SB_SYSTEM_ROOT/usr/local/bin/nfuse"
  [[ -f "$ENVIRONMENT_TRANSACTION_JOURNAL" ]]
  rm -f -- "$ENVIRONMENT_TRANSACTION_JOURNAL"
)

(
  STATE_FILE="$work/conditional-remove-state.json"
  printf '%s\n' '{"schema_version":3,"users":[{"name":"remove-user"}],"splits":[]}' > "$STATE_FILE"
  rollback_count=0
  validate_name() { return 0; }
  user_exists() { return 0; }
  start_managed_operation() { return 0; }
  rollback_active_operation() { rollback_count=$((rollback_count + 1)); return "${1:-1}"; }
  finish_managed_operation() { return 0; }
  remove_user_inbounds() { return 0; }
  state_remove_user() { return 71; }
  check_singbox_and_restart() { printf 'unexpected\n' > "$work/remove-check-ran"; }
  if cmd_remove remove-user >/dev/null 2>&1; then
    echo 'conditional remove should propagate state deletion failure' >&2
    exit 1
  fi
  [[ "$rollback_count" == 1 ]]
  [[ ! -e "$work/remove-check-ran" ]]
  [[ -z "$(trap -p ERR)" ]]

  rollback_count=0
  state_remove_user() { return 0; }
  check_singbox_and_restart() { return 72; }
  nfuse() { printf 'unexpected\n' > "$work/remove-nfuse-ran"; return 0; }
  if cmd_remove remove-user >/dev/null 2>&1; then
    echo 'conditional remove should propagate sing-box validation failure' >&2
    exit 1
  fi
  [[ "$rollback_count" == 1 ]]
  [[ ! -e "$work/remove-nfuse-ran" ]]
  [[ -z "$(trap -p ERR)" ]]
)

(
  STATE_FILE="$work/conditional-repair-state.json"
  SINGBOX_CONFIG="$work/conditional-repair-config.json"
  snapshot_marker="$work/conditional-repair-snapshot"
  restore_marker="$work/conditional-repair-restored"
  nfuse_mutation_marker="$work/conditional-repair-nfuse-mutated"
  printf '%s\n' '{"schema_version":3,"users":[{"name":"repair-user","port":20011,"status":"disabled","metered":true,"limit_gib":1,"billing_anchor":1}],"splits":[]}' > "$STATE_FILE"
  printf '%s\n' '{"inbounds":[],"outbounds":[],"route":{"rules":[],"rule_set":[]}}' > "$SINGBOX_CONFIG"
  create_environment_backup() {
    ENV_BACKUP="$work/conditional-repair-environment"
    printf 'snapshot\n' > "$snapshot_marker"
  }
  start_managed_operation() { return 0; }
  rollback_active_operation() {
    printf 'restored\n' >> "$restore_marker"
    rm -f -- "$nfuse_mutation_marker"
    return "${1:-1}"
  }
  finish_managed_operation() { return 0; }
  remove_user_inbounds() { return 0; }
  remove_split_config() { return 0; }
  check_singbox_and_restart() { return 73; }
  nfuse() {
    if [[ "${1:-}" == list && "${2:-}" == --json ]]; then printf '[]\n'; return 0; fi
    if [[ "${1:-}" == add || "${1:-}" == port ]]; then printf 'mutated\n' > "$nfuse_mutation_marker"; return 0; fi
    [[ "${1:-}" == persist ]] && return 0
    return 0
  }
  if repair_consistency >/dev/null 2>&1; then
    echo 'conditional repair should propagate the final sing-box failure' >&2
    exit 1
  fi
  grep -Fxq snapshot "$snapshot_marker"
  [[ "$(wc -l < "$restore_marker" | tr -d ' ')" == 1 ]]
  [[ ! -e "$nfuse_mutation_marker" ]]
  [[ -z "$(trap -p ERR)" ]]
)

(
  STATE_FILE="$work/row-prefetch-state.json"
  SINGBOX_CONFIG="$work/row-prefetch-config.json"
  row_mutation_marker="$work/row-prefetch-mutated"
  row_persist_marker="$work/row-prefetch-persisted"
  row_snapshot_marker="$work/row-prefetch-snapshot"
  row_restore_marker="$work/row-prefetch-restored"
  real_jq="$(command -v jq)"
  ROW_FAILURE_MODE=""
  jq() {
    local arg
    for arg in "$@"; do
      case "$ROW_FAILURE_MODE:$arg" in
        'remove:.users[].name') return 81 ;;
        audit:*'.users[] |'*) return 82 ;;
        'repair:.users[]') return 83 ;;
        repair-fields:*'(.metered // (.limit_gib != null))'*) return 84 ;;
        repair-split-fields:*'select((.upstream|type)=="object")'*) return 85 ;;
      esac
    done
    "$real_jq" "$@"
  }
  nfuse() {
    if [[ "${1:-}" == list && "${2:-}" == --json ]]; then printf '[]\n'; return 0; fi
    if [[ "${1:-}" == persist ]]; then printf 'persisted\n' > "$row_persist_marker"; return 0; fi
    return 0
  }
  remove_user_inbounds() { printf 'mutated\n' > "$row_mutation_marker"; }
  remove_split_config() { printf 'mutated\n' > "$row_mutation_marker"; }
  create_environment_backup() { printf 'snapshot\n' > "$row_snapshot_marker"; ENV_BACKUP="$work/row-prefetch-snapshot-dir"; }
  start_managed_operation() { return 0; }
  rollback_active_operation() { printf 'restored\n' >> "$row_restore_marker"; return "${1:-1}"; }
  finish_managed_operation() { return 0; }
  row_singbox() { [[ "${1:-}" == format && "${2:-}" == -c ]] && cat "$3"; }
  SINGBOX_BIN=row_singbox
  printf '%s\n' '{"schema_version":3,"users":[{"name":"row-user","status":"active","port":20012,"metered":false}],"splits":[]}' > "$STATE_FILE"
  printf '%s\n' '{"inbounds":[],"outbounds":[],"route":{"rules":[],"rule_set":[]}}' > "$SINGBOX_CONFIG"

  ROW_FAILURE_MODE=remove
  if remove_current_managed_data >/dev/null 2>&1; then
    echo 'managed-data cleanup should propagate user row extraction failure' >&2
    exit 1
  fi
  [[ ! -e "$row_mutation_marker" && ! -e "$row_persist_marker" ]]

  ROW_FAILURE_MODE=audit
  if audit_consistency >/dev/null 2>&1; then
    echo 'consistency audit should propagate user row extraction failure' >&2
    exit 1
  fi

  ROW_FAILURE_MODE=repair
  if repair_consistency >/dev/null 2>&1; then
    echo 'consistency repair should propagate user row extraction failure' >&2
    exit 1
  fi
  [[ ! -e "$row_snapshot_marker" && ! -e "$row_mutation_marker" && ! -e "$row_persist_marker" ]]

  ROW_FAILURE_MODE=repair-fields
  if repair_consistency >/dev/null 2>&1; then
    echo 'consistency repair should propagate a per-user field parsing failure' >&2
    exit 1
  fi
  grep -Fxq snapshot "$row_snapshot_marker"
  [[ "$(wc -l < "$row_restore_marker" | tr -d ' ')" == 1 ]]
  [[ ! -e "$row_mutation_marker" && ! -e "$row_persist_marker" ]]
  [[ -z "$(trap -p ERR)" ]]

  rm -f -- "$row_snapshot_marker" "$row_restore_marker"
  printf '%s\n' '{"schema_version":3,"users":[],"splits":[{"name":"row-split","status":"active","scope":"all","url":"https://example.com/rule.srs","upstream":{}}]}' > "$STATE_FILE"
  ROW_FAILURE_MODE=repair-split-fields
  if repair_consistency >/dev/null 2>&1; then
    echo 'consistency repair should propagate a per-split field parsing failure' >&2
    exit 1
  fi
  grep -Fxq snapshot "$row_snapshot_marker"
  [[ "$(wc -l < "$row_restore_marker" | tr -d ' ')" == 1 ]]
  [[ ! -e "$row_mutation_marker" && ! -e "$row_persist_marker" ]]
  [[ -z "$(trap -p ERR)" ]]
)

(
  migration_prepare_marker="$work/migration-prepare-downstream"
  prepare_core() { return 77; }
  need_cmd() { printf 'need-cmd\n' > "$migration_prepare_marker"; }
  select_migration_backup() { printf 'selected\n' > "$migration_prepare_marker"; }
  if (restore_migration_backup) >/dev/null 2>&1; then
    echo 'migration restore should propagate prepare_core failure before any downstream work' >&2
    exit 1
  fi
  [[ ! -e "$migration_prepare_marker" ]]
)

(
  STATE_FILE="$work/conditional-migration-state.json"
  migration_package="$work/conditional-migration.sbm"
  migration_rollback_marker="$work/conditional-migration-rollbacks"
  migration_report_result="$work/conditional-migration-report-result"
  migration_report_stage="$work/conditional-migration-report-stage"
  migration_persist_marker="$work/conditional-migration-persisted"
  migration_check_marker="$work/conditional-migration-check"
  migration_audit_marker="$work/conditional-migration-audit"
  printf '%s\n' '{"schema_version":3,"users":[],"splits":[]}' > "$STATE_FILE"
  : > "$migration_package"
  prepare_core() { return 0; }
  need_cmd() { return 0; }
  select_migration_backup() { SELECTED_MIGRATION_BACKUP="$migration_package"; }
  decrypt_migration_backup() {
    printf '%s\n' '{"state":{"schema_version":3,"users":[{"name":"usage-user","port":20001,"protocol":"anytls","metered":true,"limit_gib":1,"billing_anchor":1,"anytls_password":"secret","tls_sni":"usage.example.com"}],"splits":[]},"nfuse_usage":[{"name":"usage-user","used_bytes":123}],"source_hostname":"unit","created_at":"2026-07-15T00:00:00+08:00","script_version":"4.6.8"}' > "$2"
  }
  validate_migration_payload_structure() { return 0; }
  print_migration_preview() { return 0; }
  preflight_migration_payload() { return 0; }
  create_environment_backup() { ENV_BACKUP="$work/conditional-migration-snapshot"; }
  start_managed_operation() { return 0; }
  clear_operation_transaction() { return 0; }
  finish_managed_operation() { return 0; }
  remove_current_managed_data() { return 0; }
  init_state() { return 0; }
  repair_consistency() { return 0; }
  restore_environment_backup() { printf 'rollback\n' >> "$migration_rollback_marker"; }
  write_migration_restore_report() {
    printf '%s\n' "$4" > "$migration_report_result"
    printf '%s\n' "${5:-}" > "$migration_report_stage"
    MIGRATION_REPORT="$work/conditional-migration-report.json"
  }
  audit_consistency() { printf 'audited\n' > "$migration_audit_marker"; AUDIT_ISSUES=0; }
  check_singbox_and_restart() {
    printf 'checked\n' > "$migration_check_marker"
    [[ "$MIGRATION_FAILURE_STAGE" != check ]]
  }
  nfuse() {
    if [[ "${1:-}" == list && "${2:-}" == --json ]]; then
      printf '%s\n' '[{"name":"usage-user","used_bytes":0,"ports":[]}]'
      return 0
    fi
    if [[ "${1:-}" == set-usage ]]; then
      [[ "$MIGRATION_FAILURE_STAGE" != set-usage ]]
      return
    fi
    if [[ "${1:-}" == persist ]]; then
      printf 'persisted\n' > "$migration_persist_marker"
      return 0
    fi
    return 0
  }

  MIGRATION_FAILURE_STAGE=set-usage
  if (restore_migration_backup <<<$'2\nRESTORE') >/dev/null 2>&1; then
    echo 'migration restore should reject Nfuse set-usage failure inside a conditional caller' >&2
    exit 1
  fi
  [[ "$(wc -l < "$migration_rollback_marker" | tr -d ' ')" == 1 ]]
  grep -Fxq rolled_back "$migration_report_result"
  grep -Fxq restoring_nfuse_usage "$migration_report_stage"
  [[ ! -e "$migration_persist_marker" ]]
  [[ ! -e "$migration_check_marker" ]]
  [[ ! -e "$migration_audit_marker" ]]

  rm -f -- "$migration_rollback_marker" "$migration_report_result" "$migration_report_stage" \
    "$migration_persist_marker" "$migration_check_marker" "$migration_audit_marker"
  MIGRATION_FAILURE_STAGE=check
  if (restore_migration_backup <<<$'2\nRESTORE') >/dev/null 2>&1; then
    echo 'migration restore should reject sing-box validation failure inside a conditional caller' >&2
    exit 1
  fi
  [[ "$(wc -l < "$migration_rollback_marker" | tr -d ' ')" == 1 ]]
  grep -Fxq rolled_back "$migration_report_result"
  grep -Fxq validating_singbox "$migration_report_stage"
  grep -Fxq persisted "$migration_persist_marker"
  grep -Fxq checked "$migration_check_marker"
  [[ ! -e "$migration_audit_marker" ]]
)

(
  STATE_FILE="$work/conditional-disable-state.json"
  rollback_marker="$work/conditional-disable-mutated"
  printf '%s\n' '{"schema_version":3,"users":[{"name":"disable-user","port":20012,"status":"active"}],"splits":[]}' > "$STATE_FILE"
  start_managed_operation() { return 0; }
  rollback_active_operation() { return "${1:-1}"; }
  finish_managed_operation() { return 0; }
  remove_user_inbounds() { return 1; }
  state_set_status() { printf 'mutated\n' > "$rollback_marker"; }
  if cmd_disable disable-user >/dev/null 2>&1; then
    echo 'conditional cmd_disable should propagate config rewrite failure' >&2
    exit 1
  fi
  [[ ! -e "$rollback_marker" ]]
  [[ -z "$(trap -p ERR)" ]]
)

(
  STATE_FILE="$work/merge-restore-state.json"
  SINGBOX_CONFIG="$work/merge-restore-config.json"
  migration_package="$work/merge-restore.sbm"
  usage_log="$work/merge-restore-usage"
  report_mode_log="$work/merge-restore-report-mode"
  rebuild_marker="$work/merge-restore-rebuilt"
  printf '%s\n' '{"schema_version":3,"users":[{"name":"local","port":20001,"protocol":"anytls","status":"active","metered":true,"expires_at":null,"limit_gib":1,"billing_anchor":1,"usage_offset_bytes":0,"created_at":"2026-07-15T00:00:00+08:00","anytls_password":"local-secret","tls_sni":"local.example.com"}],"splits":[]}' > "$STATE_FILE"
  printf '%s\n' '{"inbounds":[],"outbounds":[],"route":{"rules":[],"rule_set":[]}}' > "$SINGBOX_CONFIG"
  : > "$migration_package"
  prepare_core() { return 0; }
  need_cmd() { return 0; }
  select_migration_backup() { SELECTED_MIGRATION_BACKUP="$migration_package"; }
  decrypt_migration_backup() {
    printf '%s\n' '{"format_version":1,"created_at":"2026-07-15T00:00:00+08:00","script_version":"4.13.0","source_hostname":"merge-source","state":{"schema_version":3,"users":[{"name":"imported","port":20002,"protocol":"anytls","status":"active","metered":false,"expires_at":null,"limit_gib":null,"billing_anchor":null,"usage_offset_bytes":10,"created_at":"2026-07-15T00:00:00+08:00","anytls_password":"imported-secret","tls_sni":"imported.example.com"}],"splits":[]},"nfuse_usage":[{"name":"imported","used_bytes":222}]}' > "$2"
  }
  merge_restore_singbox() { [[ "$1" == format && "$2" == -c ]] && cat "$3"; }
  SINGBOX_BIN=merge_restore_singbox
  port_is_listening() { return 1; }
  create_environment_backup() { ENV_BACKUP="$work/merge-restore-snapshot"; }
  start_managed_operation() { return 0; }
  finish_managed_operation() { return 0; }
  remove_current_managed_data() { return 0; }
  init_state() { return 0; }
  repair_consistency() { printf 'rebuilt\n' > "$rebuild_marker"; return 0; }
  check_singbox_and_restart() { return 0; }
  audit_consistency() { AUDIT_ISSUES=0; return 0; }
  write_migration_restore_report() {
    jq -r '.restore_mode' "$1" > "$report_mode_log"
    MIGRATION_REPORT="$work/merge-restore-report.json"
  }
  nfuse() {
    if [[ "$1" == list && "$2" == --json ]]; then
      if [[ -e "$rebuild_marker" ]]; then
        printf '%s\n' '[{"name":"local","used_bytes":0},{"name":"imported","used_bytes":0}]'
      else
        printf '%s\n' '[{"name":"local","used_bytes":111}]'
      fi
      return 0
    fi
    if [[ "$1" == set-usage ]]; then printf '%s:%s\n' "$2" "$3" >> "$usage_log"; return 0; fi
    [[ "$1" == persist ]]
  }
  restore_migration_backup <<<$'1\nMERGE' >/dev/null
  jq -e '
    (.users|length)==2 and any(.users[]; .name=="local" and .port==20001) and
    any(.users[]; .name=="imported" and .port==20002)
  ' "$STATE_FILE" >/dev/null
  grep -Fxq 'local:111' "$usage_log"
  if grep -Fq 'imported:' "$usage_log"; then
    echo 'unexpected imported: in $usage_log' >&2
    exit 1
  fi
  [[ "$(jq -r '.users[] | select(.name == "imported") | .usage_offset_bytes' "$STATE_FILE")" == 232 ]]
  grep -Fxq merge "$report_mode_log"
)

printf '%s\n' '{"schema_version":999,"users":[],"splits":[]}' > "$STATE_FILE"
if (migrate_state >/dev/null 2>&1); then
  echo 'future schema should be rejected' >&2
  exit 1
fi
printf '%s\n' '{"schema_version":3,"users":[{"name":"alice","port":20001,"status":"active","protocol":"anytls","tls_sni":"alice.example.com"}],"splits":[]}' > "$STATE_FILE"

state_set_status alice disabled
[[ "$(jq -r '.users[0].status' "$STATE_FILE")" == disabled ]]
mode="$(stat -c '%a' "$STATE_FILE" 2>/dev/null || stat -f '%Lp' "$STATE_FILE")"
[[ "$mode" == 600 ]]

state_set_limit alice 12.5
[[ "$(jq -r '.users[0].limit_gib' "$STATE_FILE")" == 12.5 ]]

load_standard_user_rows
[[ "${#USER_ROWS[@]}" == 1 ]]
[[ "${USER_ROWS[0]}" == $'alice\t20001\tAnyTLS\t停用' ]]

status_action_state="$work/status-action-state.json"
printf '%s\n' '{"schema_version":3,"users":[{"name":"zeta","port":20003,"status":"active"},{"name":"beta","port":20002,"status":"disabled","protocol":"anytls"},{"name":"alpha","port":20001,"status":"active","protocol":"anytls"}],"splits":[]}' > "$status_action_state"
(
  STATE_FILE="$status_action_state"
  MENU_RETURNED=false
  prepare_core() { :; }
  cmd_disable() { printf 'ACTION:disable:%s\n' "$1"; }
  prompt_user_status_action cmd_disable active 停用 <<<'1'
) > "$work/status-disable"
grep -Fq '1. alpha｜AnyTLS｜端口 20001｜启用' "$work/status-disable"
grep -Fq '2. zeta｜SS2022 + ShadowTLS（旧版）｜端口 20003｜启用' "$work/status-disable"
grep -Fxq 'ACTION:disable:alpha' "$work/status-disable"
if grep -Fq 'beta｜' "$work/status-disable"; then
  echo 'unexpected beta｜ in $work/status-disable' >&2
  exit 1
fi
(
  STATE_FILE="$status_action_state"
  MENU_RETURNED=false
  prepare_core() { :; }
  cmd_enable() { printf 'ACTION:enable:%s\n' "$1"; }
  prompt_user_status_action cmd_enable disabled 启用 <<<'1'
) > "$work/status-enable"
grep -Fq '1. beta｜AnyTLS｜端口 20002｜停用' "$work/status-enable"
grep -Fxq 'ACTION:enable:beta' "$work/status-enable"
(
  STATE_FILE="$status_action_state"
  MENU_RETURNED=false
  prepare_core() { :; }
  cmd_disable() { printf 'UNEXPECTED:%s\n' "$1"; }
  prompt_user_status_action cmd_disable active 停用 <<<'0'
  [[ "$MENU_RETURNED" == true ]]
) > "$work/status-return"
if grep -Fq 'UNEXPECTED:' "$work/status-return"; then
  echo 'unexpected UNEXPECTED: in $work/status-return' >&2
  exit 1
fi

add_split_return_state="$work/add-split-return-state.json"
printf '%s\n' '{"schema_version":4,"users":[],"splits":[],"outbound_presets":[{"name":"out","upstream":{"protocol":"shadowsocks","server":"example.com","server_port":443,"method":"aes-128-gcm","password":"secret"}}],"rule_presets":[{"name":"rule","url":"https://example.com/rule.srs"}]}' > "$add_split_return_state"
(
  STATE_FILE="$add_split_return_state"
  MENU_RETURNED=false
  prepare_core() { :; }
  cmd_split_add() { printf 'UNEXPECTED:%s\n' "$1"; }
  prompt_add_split <<<'0'
  [[ "$MENU_RETURNED" == true ]]
) > "$work/add-split-return"
grep -Fq '输入 0 可返回分流管理。' "$work/add-split-return"
if grep -Fq 'UNEXPECTED:' "$work/add-split-return"; then
  echo 'unexpected UNEXPECTED: in $work/add-split-return' >&2
  exit 1
fi

diagnostic_state="$work/split-diagnostic-state.json"
diagnostic_log="$work/split-diagnostic.log"
printf '%s\n' '{"schema_version":3,"users":[{"name":"cou","port":20001,"status":"active","protocol":"anytls"}],"splits":[{"name":"AI","status":"active","scope":"user","user":"cou","outbound_tag":"Hinet"},{"name":"Media","status":"active","scope":"all","outbound_tag":"media-out"}]}' > "$diagnostic_state"
cat > "$diagnostic_log" <<'EOF'
+0800 2026-07-15 19:10:01 INFO [101 0ms] inbound/anytls[anytls-cou]: [cou] inbound connection to chatgpt.com:443
+0800 2026-07-15 19:10:01 INFO [101 1ms] outbound/anytls[Hinet]: outbound connection to chatgpt.com:443
+0800 2026-07-15 19:10:01 INFO [101 2ms] inbound/anytls[anytls-cou]: [cou] inbound connection to api.openai.com:443
+0800 2026-07-15 19:10:01 INFO [101 3ms] outbound/anytls[Hinet]: outbound connection to api.openai.com:443
+0800 2026-07-15 19:10:02 INFO [102 0ms] inbound/anytls[anytls-cou]: [cou] inbound connection to example.com:443
+0800 2026-07-15 19:10:02 INFO [102 1ms] outbound/direct[direct]: outbound connection to example.com:443
+0800 2026-07-15 19:10:03 INFO [103 0ms] inbound/shadowsocks[ss-cou]: [cou] inbound connection to video.example:443
+0800 2026-07-15 19:10:03 INFO [103 1ms] outbound/shadowsocks[media-out]: outbound connection to video.example:443
+0800 2026-07-15 19:10:04 INFO [104 0ms] inbound/shadowtls[st-cou]: [cou] inbound connection to pending.example:443
+0800 2026-07-15 19:10:05 INFO [105 0ms] inbound/anytls[anytls-other]: [other] inbound connection to ignored.example:443
+0800 2026-07-15 19:10:05 INFO [105 1ms] outbound/direct[direct]: outbound connection to ignored.example:443
+0800 2026-07-15 19:10:06 INFO [107 0ms] inbound/shadowsocks[ss-udp-cou]: [cou] inbound connection to dns.example:53
+0800 2026-07-15 19:10:06 INFO [107 1ms] outbound/shadowsocks[Hinet]: outbound connection to dns.example:53
EOF
printf '\033[36mINFO\033[0m [\033[38;5;230m106\033[0m 0ms] inbound/anytls[anytls-cou]: [cou] inbound connection to colored.example:443\n' >> "$diagnostic_log"
printf '\033[36mINFO\033[0m [\033[38;5;230m106\033[0m 1ms] outbound/anytls[Hinet]: outbound connection to colored.example:443\n' >> "$diagnostic_log"
diagnostic_rows="$(extract_split_diagnostic_connections cou Hinet "$diagnostic_log")"
[[ "$(wc -l <<<"$diagnostic_rows" | tr -d ' ')" == 7 ]]
grep -Fq $'101\tchatgpt.com:443\tHinet' <<<"$diagnostic_rows"
grep -Fq $'101\tapi.openai.com:443\tHinet' <<<"$diagnostic_rows"
grep -Fq $'102\texample.com:443\tdirect' <<<"$diagnostic_rows"
grep -Fq $'103\tvideo.example:443\tmedia-out' <<<"$diagnostic_rows"
grep -Fq $'104\tpending.example:443\t' <<<"$diagnostic_rows"
grep -Fq $'106\tcolored.example:443\tHinet' <<<"$diagnostic_rows"
grep -Fq $'107\tdns.example:53\tHinet' <<<"$diagnostic_rows"
(
  STATE_FILE="$diagnostic_state"
  render_split_diagnostic_results cou AI Hinet "$diagnostic_log"
) > "$work/split-diagnostic-rendered"
grep -Fq '已命中：AI' "$work/split-diagnostic-rendered"
grep -Fq '未命中，走直连' "$work/split-diagnostic-rendered"
grep -Fq '命中其他分流：Media' "$work/split-diagnostic-rendered"
grep -Fq '未看到出口记录' "$work/split-diagnostic-rendered"
if grep -Fq 'ignored.example' "$work/split-diagnostic-rendered"; then
  echo 'unexpected ignored.example in $work/split-diagnostic-rendered' >&2
  exit 1
fi

diagnostic_root="$work/diagnostic"
diagnostic_bin="$diagnostic_root/bin"
diagnostic_reports="$diagnostic_root/reports"
diagnostic_state="$diagnostic_root/state.json"
diagnostic_config="$diagnostic_root/config.json"
diagnostic_manager_config="$diagnostic_root/manager.conf"
diagnostic_versions="$diagnostic_root/versions"
diagnostic_socket="$diagnostic_root/nfuse.sock"
mkdir -p "$diagnostic_bin" "$diagnostic_reports"
printf '%s\n' '{"schema_version":4,"users":[{"name":"a"}],"splits":[],"outbound_presets":[],"rule_presets":[]}' \
  > "$diagnostic_root/short-user-state.json"
printf '%s\n' 'a cat a-b (a) a_ a, a' > "$diagnostic_root/short-user-raw.txt"
(
  STATE_FILE="$diagnostic_root/short-user-state.json"
  PUBLIC_SERVER_OVERRIDE=""
  hostname() { printf '%s\n' diagnostic-host; }
  build_diagnostic_redactions
  short_user_token_only=false
  for ((i=0; i<DIAGNOSTIC_REDACT_COUNT; i++)); do
    if [[ "${DIAGNOSTIC_REDACT_VALUES[$i]}" == a ]]; then
      [[ "${DIAGNOSTIC_REDACT_TOKEN_ONLY[$i]}" == true ]]
      short_user_token_only=true
    fi
  done
  [[ "$short_user_token_only" == true ]]
  redact_diagnostic_file "$diagnostic_root/short-user-raw.txt" "$diagnostic_root/short-user-redacted.txt"
  grep -Fxq '[用户1] cat a-b ([用户1]) a_ [用户1], [用户1]' "$diagnostic_root/short-user-redacted.txt"
)

# 批量脱敏必须与旧实现逐字节一致，并覆盖短用户名、字面元字符、子串、秘密和网络地址。
cat > "$diagnostic_root/batch-redaction-state.json" <<'EOF'
{
  "schema_version":7,
  "users":[
    {"name":"a","ss2022_password":"pass","endpoints":[]},
    {"name":"ab","anytls_password":"pass-long-secret","endpoints":[]},
    {"name":"abc","tls_sni":"private.sni.example","endpoints":[]},
    {"name":"alpha","endpoints":[]},
    {"name":"alpha-long","endpoints":[]}
  ],
  "splits":[{
    "name":"route[1]*?","url":"https://private.example/rules?a=1",
    "upstream":{"server":"203.0.113.20","password":"upstream-secret","sni":"upstream.private.example"}
  }],
  "outbound_presets":[],
  "rule_presets":[]
}
EOF
printf '%s' 'a cat a-b (a) a_ a, a
ab abc alpha-long alpha route[1]*? route1
pass-long-secret pass upstream-secret private.sni.example
https://private.example/rules?a=1 203.0.113.20 [2001:db8::1] 2001:db8::2' \
  > "$diagnostic_root/batch-redaction-raw.txt"
(
  STATE_FILE="$diagnostic_root/batch-redaction-state.json"
  PUBLIC_SERVER_OVERRIDE=""
  hostname() { printf '%s\n' diagnostic-host; }
  build_diagnostic_redactions
  redact_diagnostic_file_with_shell_tools \
    "$diagnostic_root/batch-redaction-raw.txt" "$diagnostic_root/batch-redaction-expected.txt"
  python_args="$diagnostic_root/batch-redaction-python.args"
  python_calls="$diagnostic_root/batch-redaction-python.calls"
  : > "$python_args"
  : > "$python_calls"
  python3() {
    printf 'call\n' >> "$python_calls"
    printf '%s\0' "$@" >> "$python_args"
    command python3 "$@"
  }
  redact_diagnostic_file \
    "$diagnostic_root/batch-redaction-raw.txt" "$diagnostic_root/batch-redaction-actual.txt"
  [[ "$(wc -l < "$python_calls" | tr -d ' ')" == 1 ]]
  cmp -s "$diagnostic_root/batch-redaction-expected.txt" "$diagnostic_root/batch-redaction-actual.txt"
  [[ "$(grep -Fo '[用户1]' "$diagnostic_root/batch-redaction-actual.txt" | wc -l | tr -d ' ')" == 4 ]]
  grep -Fq 'a-b' "$diagnostic_root/batch-redaction-actual.txt"
  grep -Fq 'a_' "$diagnostic_root/batch-redaction-actual.txt"
  grep -Fq '[分流1]' "$diagnostic_root/batch-redaction-actual.txt"
  grep -Fq '[用户5] [用户4]' "$diagnostic_root/batch-redaction-actual.txt"
  grep -Fq '[已隐藏密码] [已隐藏密码] [已隐藏密码]' "$diagnostic_root/batch-redaction-actual.txt"
  grep -Fq '[已隐藏地址] [已隐藏服务器] [已隐藏IP] [已隐藏IP]' "$diagnostic_root/batch-redaction-actual.txt"
  if grep -Eq 'pass-long-secret|upstream-secret|private\.sni\.example|203\.0\.113\.20|2001:db8' "$diagnostic_root/batch-redaction-actual.txt"; then
    echo 'unexpected pass-long-secret|upstream-secret|private\.sni\.example|203\.0\.113\.20|2001:db8 in $diagnostic_root/batch-redaction-actual.txt' >&2
    exit 1
  fi
  if tr '\0' '\n' < "$python_args" | grep -Eq 'pass-long-secret|upstream-secret|private\.sni\.example|private\.example|203\.0\.113\.20|2001:db8'; then
    echo 'unexpected pass-long-secret|upstream-secret|private\.sni\.example|private\.example|203\.0\.113\.20|2001:db8 in $python_args' >&2
    exit 1
  fi
  command() {
    if [[ "${1:-}" == -v && "${2:-}" == python3 ]]; then
      return 1
    fi
    builtin command "$@"
  }
  redact_diagnostic_file \
    "$diagnostic_root/batch-redaction-raw.txt" "$diagnostic_root/batch-redaction-fallback.txt"
  cmp -s "$diagnostic_root/batch-redaction-expected.txt" "$diagnostic_root/batch-redaction-fallback.txt"
)

# 纯 C locale 下旧 Bash 边界按 ASCII 判断，Python 快速路径必须保持相同结果。
(
  export LC_ALL=C
  DIAGNOSTIC_REDACT_VALUES=(a)
  DIAGNOSTIC_REDACT_LABELS=('[用户1]')
  DIAGNOSTIC_REDACT_TOKEN_ONLY=(true)
  DIAGNOSTIC_REDACT_COUNT=1
  printf '%s' 'aé éa (a) a-é a_ a-b' > "$diagnostic_root/batch-redaction-c-locale-raw.txt"
  redact_diagnostic_file_with_shell_tools \
    "$diagnostic_root/batch-redaction-c-locale-raw.txt" \
    "$diagnostic_root/batch-redaction-c-locale-expected.txt"
  redact_diagnostic_file \
    "$diagnostic_root/batch-redaction-c-locale-raw.txt" \
    "$diagnostic_root/batch-redaction-c-locale-actual.txt"
  cmp -s "$diagnostic_root/batch-redaction-c-locale-expected.txt" \
    "$diagnostic_root/batch-redaction-c-locale-actual.txt"
)

# 100 个短用户名和 20 行报告仍只启动一次 Python。
(
  DIAGNOSTIC_REDACT_VALUES=()
  DIAGNOSTIC_REDACT_LABELS=()
  DIAGNOSTIC_REDACT_TOKEN_ONLY=()
  DIAGNOSTIC_REDACT_COUNT=0
  scale_alphabet=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789
  scale_line=""
  for ((i=0; i<100; i++)); do
    if ((i < 62)); then scale_name="${scale_alphabet:i:1}"
    else scale_name="u$((i - 62))"; fi
    add_diagnostic_redaction "$scale_name" "[用户$((i + 1))]" true
    scale_line+="($scale_name),"
  done
  sort_diagnostic_redactions
  for ((i=0; i<20; i++)); do printf '%s\n' "$scale_line"; done \
    > "$diagnostic_root/batch-redaction-scale-raw.txt"
  scale_python_calls="$diagnostic_root/batch-redaction-scale-python.calls"
  : > "$scale_python_calls"
  python3() {
    printf 'call\n' >> "$scale_python_calls"
    command python3 "$@"
  }
  redact_diagnostic_file "$diagnostic_root/batch-redaction-scale-raw.txt" \
    "$diagnostic_root/batch-redaction-scale-output.txt"
  [[ "$(wc -l < "$scale_python_calls" | tr -d ' ')" == 1 ]]
  [[ "$(wc -l < "$diagnostic_root/batch-redaction-scale-output.txt" | tr -d ' ')" == 20 ]]
)

# 输入读取失败必须传播，不能留下看似可交付的成功结果。
if redact_diagnostic_file "$diagnostic_root/missing-redaction-source.txt" \
  "$diagnostic_root/batch-redaction-missing-output.txt" 2>/dev/null; then
  echo 'missing diagnostic input must fail batch redaction' >&2
  exit 1
fi
cat > "$diagnostic_bin/sing-box" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  version) echo 'sing-box version 1.13.14';;
  check) exit 0;;
  format) printf '%s\n' '{"inbounds":[],"outbounds":[],"route":{"rule_set":[]}}';;
  *) exit 1;;
esac
EOF
cat > "$diagnostic_bin/nfuse" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list) printf '%s\n' '[{"name":"crocell","tier":"a","ports":[{"start":20001,"end":20001}]}]';;
  version) echo 'nfuse 0.1.13';;
  *) exit 1;;
esac
EOF
chmod 700 "$diagnostic_bin/sing-box" "$diagnostic_bin/nfuse"
cat > "$diagnostic_state" <<'EOF'
{
  "schema_version": 7,
  "users": [{
    "name": "crocell", "status": "active", "protocol": "anytls", "port": 20001,
    "metered": true, "limit_gib": 10, "anytls_password": "secret-crocell-123",
    "tls_sni": "secret.sni.example",
    "endpoints": [{"protocol":"anytls","port":20001,"anytls_password":"secret-crocell-123","tls_sni":"secret.sni.example"}]
  }],
  "splits": [{
    "name": "AI", "status": "active", "scope": "all",
    "url": "https://rules.private.example/ai.srs", "outbound_tag": "Hinet",
    "upstream": {"protocol":"anytls","server":"hinet.private.example","server_port":443,"password":"upstream-secret-456","sni":"upstream.sni.example"}
  }],
  "outbound_presets": [],
  "rule_presets": []
}
EOF
printf '%s\n' '{"log":{"level":"info"},"inbounds":[],"outbounds":[],"route":{"rule_set":[]}}' > "$diagnostic_config"
printf 'SCRIPT_VERSION=4.15.3\nSINGBOX_VERSION=1.13.14\nNFUSE_VERSION=0.1.13\n' > "$diagnostic_versions"
printf 'SINGBOX_BIN="%s"\nSINGBOX_CONFIG="%s"\nNFUSE_BIN="%s"\nNFUSE_SOCKET="%s"\nSTATE_FILE="%s"\nLOCK_FILE="%s"\nTRANSACTION_DIR="%s"\nGITHUB_TOKEN="github-secret-token"\nPUBLIC_SERVER_OVERRIDE="43.132.173.34"\n' \
  "$diagnostic_bin/sing-box" "$diagnostic_config" "$diagnostic_bin/nfuse" "$diagnostic_socket" \
  "$diagnostic_state" "$diagnostic_root/manager.lock" "$diagnostic_root/transactions" > "$diagnostic_manager_config"
(
  CONF_FILE="$diagnostic_manager_config"
  DEPLOYED_VERSIONS_FILE="$diagnostic_versions"
  DIAGNOSTIC_REPORT_DIR="$diagnostic_reports"
  current_singbox_channel() { echo stable; }
  diagnostic_nfuse_healthy() { return 0; }
  systemctl() {
    if [[ "$1" == is-active ]]; then echo active; return 0; fi
    return 1
  }
  hostname() { echo private-hostname; }
  journalctl() {
    printf '%s\n' "systemd[1]: sing-box.service: Failed with result 'exit-code'."
    printf '%s\n' 'warning crocell Hinet secret-crocell-123 upstream-secret-456 8.8.8.8 2001:db8::1 api.openai.com https://private.example/path token=unknown-log-token'
  }
  audit_consistency() {
    AUDIT_ISSUES=1
    AUDIT_REPAIRABLE=1
    echo '用户 crocell 的分流 AI 与出口 Hinet 需要检查'
  }
  create_diagnostic_report > "$diagnostic_root/create-output"
  report="$(find "$diagnostic_reports" -type f -name 'diagnostic-*.txt' -print -quit)"
  [[ -n "$report" ]]
  validate_diagnostic_report "$report"
  [[ "$(diagnostic_report_mode "$report")" == 600 ]]
  grep -Fq '总体结果：发现需要处理的项目' "$report"
  grep -Fq '用户：总计 1｜启用 1｜停用 0｜SS2022 0（旧版 ShadowTLS 0）｜AnyTLS 1｜计量 1｜自用 0' "$report"
  grep -Fq '[用户1]' "$report"
  grep -Fq '[分流1]' "$report"
  grep -Fq '[出口1]' "$report"
  grep -Fq '[已隐藏IP]' "$report"
  grep -Fq '[已隐藏域名]' "$report"
  grep -Fq 'sing-box.service' "$report"
  grep -Fq '如果总体结果为“正常”，不代表这些问题当前仍在发生' "$report"
  for secret in crocell Hinet secret-crocell-123 upstream-secret-456 github-secret-token private-hostname \
    43.132.173.34 8.8.8.8 2001:db8::1 api.openai.com hinet.private.example rules.private.example secret.sni.example unknown-log-token; do
    if grep -Fq "$secret" "$report"; then
      echo "diagnostic report leaked: $secret" >&2
      exit 1
    fi
  done
  print_diagnostic_reports > "$diagnostic_root/list-output"
  grep -Fq '发现需要处理的项目' "$diagnostic_root/list-output"
  printf '伪造报告\n' > "$diagnostic_reports/diagnostic-invalid.txt"
  chmod 600 "$diagnostic_reports/diagnostic-invalid.txt"
  load_diagnostic_reports
  [[ "$DIAGNOSTIC_REPORT_COUNT" == 1 ]]
  printf '1\n' | show_diagnostic_report > "$diagnostic_root/show-output"
  grep -Fq 'sb-user-manager 故障诊断报告' "$diagnostic_root/show-output"
  cp -p "$report" "$diagnostic_reports/diagnostic-99999999-999999-2.txt"
  cp -p "$report" "$diagnostic_reports/diagnostic-99999999-999999-1.txt"
  printf '1\nCLEANUP\n' | cleanup_diagnostic_reports > "$diagnostic_root/cleanup-output"
  load_diagnostic_reports
  [[ "$DIAGNOSTIC_REPORT_COUNT" == 1 ]]
  printf '1\ny\n' | delete_diagnostic_report > "$diagnostic_root/delete-output"
  load_diagnostic_reports
  [[ "$DIAGNOSTIC_REPORT_COUNT" == 0 ]]
)
(
  CONF_FILE="$diagnostic_root/missing-manager.conf"
  DEPLOYED_VERSIONS_FILE="$diagnostic_root/missing-versions"
  DIAGNOSTIC_REPORT_DIR="$diagnostic_root/partial-reports"
  create_diagnostic_report > "$diagnostic_root/partial-output"
  partial_report="$(find "$DIAGNOSTIC_REPORT_DIR" -type f -name 'diagnostic-*.txt' -print -quit)"
  [[ -n "$partial_report" ]]
  validate_diagnostic_report "$partial_report"
  grep -Fq '总体结果：发现需要处理的项目' "$partial_report"
  grep -Fq '管理配置：缺失或不可读' "$partial_report"
  grep -Fq 'sing-box 配置：未通过' "$partial_report"
  grep -Fq 'Nfuse 通信与数据：异常' "$partial_report"
)

(
  load_runtime_config() {
    SS2022_SHADOWTLS_SNI=global-ss.example.com
    ANYTLS_SNI=global-any.example.com
  }
  prompt_self() { printf 'ADD-SELF:%s|%s|%s\n' "$1" "$2" "$3"; }
  prompt_managed() { printf 'UNEXPECTED-MANAGED\n'; }
  MENU_RETURNED=false
  prompt_add_node <<'EOF'
1

2
EOF
) > "$work/add-default-ss-sni" 2>&1
grep -Fxq 'ADD-SELF:ss2022|2022-blake3-aes-128-gcm|' "$work/add-default-ss-sni"
(
  load_runtime_config() {
    SS2022_SHADOWTLS_SNI=global-ss.example.com
    ANYTLS_SNI=global-any.example.com
  }
  prompt_self() { printf 'ADD-SELF:%s|%s|%s\n' "$1" "$2" "$3"; }
  prompt_managed() { printf 'UNEXPECTED-MANAGED\n'; }
  MENU_RETURNED=false
  prompt_add_node <<'EOF'
2

2
EOF
) > "$work/add-default-anytls-sni" 2>&1
grep -Fxq 'ADD-SELF:anytls||global-any.example.com' "$work/add-default-anytls-sni"
(
  load_runtime_config() {
    SS2022_SHADOWTLS_SNI=global-ss.example.com
    ANYTLS_SNI=global-any.example.com
  }
  prompt_multi_account() { printf 'ADD-MULTI:%s|%s|%s\n' "$1" "$2" "$3"; }
  prompt_self() { printf 'UNEXPECTED-SINGLE\n'; }
  prompt_managed() { printf 'UNEXPECTED-SINGLE\n'; }
  MENU_RETURNED=false
  prompt_add_node <<'EOF'
3


2
EOF
) > "$work/add-default-multi" 2>&1
grep -Fxq 'ADD-MULTI:self|2022-blake3-aes-128-gcm|global-any.example.com' "$work/add-default-multi"
if grep -Fq 'UNEXPECTED-SINGLE' "$work/add-default-multi"; then
  echo 'unexpected UNEXPECTED-SINGLE in $work/add-default-multi' >&2
  exit 1
fi
(
  load_runtime_config() { :; }
  MENU_RETURNED=false
  prompt_add_node <<'EOF'
4
0
EOF
) > "$work/add-user-protocol-menu" 2>&1
grep -Fq '输入无效：请输入 1、2、3 或 0' "$work/add-user-protocol-menu"
if grep -Fq '为已有用户添加或移除协议' "$work/add-user-protocol-menu"; then
  echo 'unexpected 为已有用户添加或移除协议 in $work/add-user-protocol-menu' >&2
  exit 1
fi

user_management_body="$(declare -f user_management_menu)"
grep -Fq "protocols '管理用户协议'" <<<"$user_management_body"
grep -Fq 'protocols)' <<<"$user_management_body"
[[ "$(grep -Fc 'prompt_manage_user_protocols;' <<<"$user_management_body")" == 1 ]]
(
  load_runtime_config() {
    SS2022_SHADOWTLS_SNI=global-ss.example.com
    ANYTLS_SNI=global-any.example.com
  }
  prompt_self() { printf 'UNEXPECTED-SELF\n'; }
  prompt_managed() { printf 'ADD-MANAGED:%s|%s|%s\n' "$1" "$2" "$3"; }
  MENU_RETURNED=false
  prompt_add_node <<'EOF'
2


EOF
) > "$work/add-default-metered" 2>&1
grep -Fxq 'ADD-MANAGED:anytls||global-any.example.com' "$work/add-default-metered"
if grep -Fq 'UNEXPECTED-SELF' "$work/add-default-metered"; then
  echo 'unexpected UNEXPECTED-SELF in $work/add-default-metered' >&2
  exit 1
fi

(
  load_runtime_config() {
    SS2022_SHADOWTLS_SNI=global-ss.example.com
    ANYTLS_SNI=global-any.example.com
  }
  prompt_self() { printf 'UNEXPECTED-SELF\n'; }
  prompt_managed() { printf 'ADD-RETRY:%s|%s|%s\n' "$1" "$2" "$3"; }
  MENU_RETURNED=false
  prompt_add_node <<'EOF'
9
2
not a domain
valid.example.com
9
1
EOF
) > "$work/add-invalid-retry" 2>&1
grep -Fq '输入无效：请输入 1、2 或 0，请重新输入。' "$work/add-invalid-retry"
grep -Fq '输入无效：ShadowTLS SNI 必须是有效域名' "$work/add-invalid-retry"
grep -Fxq 'ADD-RETRY:anytls||valid.example.com' "$work/add-invalid-retry"
if grep -Fq 'UNEXPECTED-SELF' "$work/add-invalid-retry"; then
  echo 'unexpected UNEXPECTED-SELF in $work/add-invalid-retry' >&2
  exit 1
fi

# 有效期调整菜单必须把正数和负数月数原样交给命令；负数先预览确认。
renew_prompt_state="$work/renew-prompt-state.json"
printf '%s\n' '{"schema_version":7,"users":[{"name":"renew-user","port":20001,"status":"active","metered":true,"limit_gib":2,"billing_anchor":5,"expires_at":"2026-08-15T00:00:00+0800","created_at":"2026-07-15T00:00:00+0800","protocol":"anytls","anytls_password":"secret","tls_sni":"example.com","endpoints":[{"protocol":"anytls","port":20001,"anytls_password":"secret","tls_sni":"example.com"}]}],"splits":[],"outbound_presets":[],"rule_presets":[]}' > "$renew_prompt_state"
(
  STATE_FILE="$renew_prompt_state"
  MENU_RETURNED=false
  prepare_core() { :; }
  cmd_renew() { printf 'RENEW:%s|%s\n' "$1" "$2"; }
  prompt_renew_user <<'EOF'
1
6
EOF
) > "$work/renew-prompt"
grep -Fxq 'RENEW:renew-user|6' "$work/renew-prompt"
(
  STATE_FILE="$renew_prompt_state"
  MENU_RETURNED=false
  prepare_core() { :; }
  date() {
    if [[ "${1:-}" == -d && "${3:-}" == +%s ]]; then printf '2000\n'; else command date "$@"; fi
  }
  calculate_renewal_expiry() {
    [[ "$1" == 2000 && "$2" == -1 ]]
    printf '2026-07-15T00:00:00+0800\n'
  }
  cmd_renew() { printf 'RENEW:%s|%s\n' "$1" "$2"; }
  prompt_renew_user <<'EOF'
1
-1
y
EOF
) > "$work/renew-prompt-negative"
grep -Fq '提前到期预览：' "$work/renew-prompt-negative"
grep -Fq '当前到期：2026-08-15 00:00:00+0800' "$work/renew-prompt-negative"
grep -Fq '调整后：2026-07-15 00:00:00+0800' "$work/renew-prompt-negative"
grep -Fxq 'RENEW:renew-user|-1' "$work/renew-prompt-negative"
(
  STATE_FILE="$renew_prompt_state"
  MENU_RETURNED=false
  prepare_core() { :; }
  date() { printf '2000\n'; }
  calculate_renewal_expiry() { printf '2026-07-15T00:00:00+0800\n'; }
  cmd_renew() { printf 'UNEXPECTED-RENEW\n'; }
  prompt_renew_user <<'EOF'
1
-1
n
EOF
) > "$work/renew-prompt-cancel"
grep -Fq '已取消有效期调整。' "$work/renew-prompt-cancel"
if grep -Fq 'UNEXPECTED-RENEW' "$work/renew-prompt-cancel"; then
  echo 'unexpected UNEXPECTED-RENEW in $work/renew-prompt-cancel' >&2
  exit 1
fi
grep -Fq "renew '调整用户有效期'" src/80-menus-main.sh

edit_prompt_state="$work/edit-prompt-state.json"
printf '%s\n' '{"schema_version":3,"users":[{"name":"alice","port":20001,"status":"active","metered":true,"limit_gib":2,"billing_anchor":5,"expires_at":"2026-08-15T00:00:00+0800","created_at":"2026-07-15T00:00:00+0800","shadowtls_password":"st","ss2022_password":"ss","method":"2022-blake3-aes-128-gcm","shadowtls_sni":"old.example.com"}],"splits":[]}' > "$edit_prompt_state"
(
  STATE_FILE="$edit_prompt_state"
  MENU_RETURNED=false
  PORT_MIN=20001
  PORT_MAX=30000
  prepare_core() { :; }
  date() {
    if [[ "${1:-}" == -d ]]; then printf '2026-10-15T00:00:00+0800\n'; else command date "$@"; fi
  }
  cmd_edit_user() { printf 'EDIT:%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$6"; }
  prompt_edit_user <<'EOF'
1
20002
2
new.example.com
9
3
y
EOF
) > "$work/edit-prompt"
grep -Fq '端口：20001 → 20002' "$work/edit-prompt"
grep -Fq '加密方式：2022-blake3-aes-128-gcm → 2022-blake3-aes-256-gcm' "$work/edit-prompt"
grep -Fq '连接密码：将重新生成' "$work/edit-prompt"
grep -Fxq 'EDIT:alice|20002|new.example.com|2022-blake3-aes-256-gcm|9|2026-10-15T00:00:00+0800' "$work/edit-prompt"
(
  STATE_FILE="$edit_prompt_state"
  MENU_RETURNED=false
  prepare_core() { :; }
  cmd_edit_user() { printf 'UNEXPECTED:%s\n' "$1"; }
  prompt_edit_user <<<'0'
  [[ "$MENU_RETURNED" == true ]]
) > "$work/edit-prompt-return"
if grep -Fq 'UNEXPECTED:' "$work/edit-prompt-return"; then
  echo 'unexpected UNEXPECTED: in $work/edit-prompt-return' >&2
  exit 1
fi

state_remove_user alice
[[ "$(jq '.users | length' "$STATE_FILE")" == 0 ]]

state_add_user custom 20003 ss-secret 2 14 true 2026-08-14T00:00:00+0800 2022-blake3-aes-256-gcm
jq -e '
  .users[0].protocol == "ss2022" and
  .users[0].transport == "direct" and
  .users[0].method == "2022-blake3-aes-256-gcm" and
  .users[0].ss2022_password == "ss-secret" and
  (.users[0] | has("shadowtls_password") | not) and
  (.users[0] | has("shadowtls_sni") | not) and
  .users[0].endpoints == [{protocol:"ss2022",transport:"direct",port:20003,ss2022_password:"ss-secret",method:"2022-blake3-aes-256-gcm"}]
' "$STATE_FILE" >/dev/null
state_remove_user custom

state_add_anytls anytls-custom 20006 anytls-secret 2 14 true 2026-08-14T00:00:00+0800 anytls-user.example.com
jq -e '.users[0].tls_sni == "anytls-user.example.com"' "$STATE_FILE" >/dev/null
state_remove_user anytls-custom

(
  STATE_FILE="$work/self-create-state.json"
  self_events="$work/self-create-events"
  PORT_MIN=20001
  PORT_MAX=30000
  printf '%s\n' '{"schema_version":3,"users":[],"splits":[]}' > "$STATE_FILE"
  port_is_listening() { return 1; }
  check_new_user_conflicts() { printf -v "$4" '%s' '{"inbounds":[]}'; printf -v "$5" '%064d' 0; }
  generate_st_password() { printf 'self-st\n'; }
  generate_ss_password() { printf 'self-ss\n'; }
  append_inbounds_from_new_user_snapshot() { return 0; }
  check_singbox_and_restart() { return 0; }
  start_managed_operation() { return 0; }
  finish_managed_operation() { return 0; }
  cmd_export() { return 0; }
  nfuse() {
    if [[ "${1:-}" == list && "${2:-}" == --json ]]; then printf '[]\n'; return 0; fi
    printf '%s\n' "$*" >> "$self_events"
  }
  cmd_add self self-created 20020 2022-blake3-aes-128-gcm >/dev/null
  jq -e '.users[0] | .name == "self-created" and .metered == false and .usage_offset_bytes == 0 and .transport == "direct" and (has("shadowtls_password") | not) and (has("shadowtls_sni") | not)' "$STATE_FILE" >/dev/null
  grep -Fxq 'add self-created --tier c --limit 0 --anchor 1' "$self_events"
  grep -Fxq 'port add self-created 20020' "$self_events"
  grep -Fxq persist "$self_events"
)

(
  STATE_FILE="$work/self-create-blocked-state.json"
  transaction_marker="$work/self-create-blocked-transaction"
  nfuse_marker="$work/self-create-blocked-nfuse"
  PORT_MIN=20001
  PORT_MAX=30000
  printf '%s\n' '{"schema_version":3,"users":[],"splits":[]}' > "$STATE_FILE"
  port_is_listening() { return 1; }
  check_new_user_conflicts() { printf -v "$4" '%s' '{"inbounds":[]}'; printf -v "$5" '%064d' 0; }
  generate_st_password() { printf 'blocked-st\n'; }
  generate_ss_password() { printf 'blocked-ss\n'; }
  ensure_safe_ssh_for_kernel_restart() { return 1; }
  start_managed_operation() { printf '%s\n' started > "$transaction_marker"; }
  nfuse() {
    if [[ "${1:-}" == list && "${2:-}" == --json ]]; then printf '[]\n'; return 0; fi
    printf '%s\n' "$*" >> "$nfuse_marker"
  }
  cmd_add self blocked-user 20024 2022-blake3-aes-128-gcm >/dev/null
  [[ "$(jq '.users|length' "$STATE_FILE")" == 0 ]]
  [[ ! -e "$transaction_marker" ]]
  [[ ! -e "$nfuse_marker" ]]
)

(
  STATE_FILE="$work/self-enable-state.json"
  self_events="$work/self-enable-events"
  printf '%s\n' '{"schema_version":3,"users":[{"name":"self-enable","port":20021,"status":"disabled","metered":false,"shadowtls_password":"st","ss2022_password":"ss","method":"2022-blake3-aes-128-gcm","shadowtls_sni":"self.example.com"}],"splits":[]}' > "$STATE_FILE"
  tag_exists_in_config() { return 1; }
  append_inbounds() { return 0; }
  check_singbox_and_restart() { return 0; }
  start_managed_operation() { return 0; }
  finish_managed_operation() { return 0; }
  nfuse() {
    if [[ "${1:-}" == list && "${2:-}" == --json ]]; then
      printf '%s\n' '[{"name":"self-enable","tier":"c","used_bytes":987,"ports":[{"id":1,"start":20021,"end":20021}]}]'
      return 0
    fi
    printf '%s\n' "$*" >> "$self_events"
  }
  cmd_enable self-enable >/dev/null
  [[ "$(jq -r '.users[0].status' "$STATE_FILE")" == active ]]
  [[ ! -e "$self_events" ]] || ! grep -Fq reset "$self_events"
)

(
  STATE_FILE="$work/multi-enable-state.json"
  printf '%s\n' '{"schema_version":6,"users":[{"name":"multi-enable","port":20025,"protocol":"anytls","status":"disabled","metered":false,"usage_offset_bytes":0,"anytls_password":"at","tls_sni":"at.example.com","endpoints":[{"protocol":"anytls","port":20025,"anytls_password":"at","tls_sni":"at.example.com"},{"protocol":"ss2022","transport":"direct","port":20026,"ss2022_password":"ss","method":"2022-blake3-aes-128-gcm"}]}],"splits":[],"outbound_presets":[],"rule_presets":[]}' > "$STATE_FILE"
  tag_exists_in_config() { return 1; }
  ensure_safe_ssh_for_kernel_restart() { return 0; }
  nfuse() {
    [[ "${1:-}" == list && "${2:-}" == --json ]] || return 1
    printf '%s\n' '[{"name":"multi-enable","tier":"c","used_bytes":123,"ports":[{"id":1,"start":20025,"end":20025},{"id":2,"start":20026,"end":20026}]}]'
  }
  prepare_user_enable multi-enable
  jq -e 'length == 2 and any(.[]; .tag == "anytls-multi-enable") and any(.[]; .tag == "ss-multi-enable" and (has("network") | not)) and all(.[]; .tag != "st-multi-enable" and .tag != "ss-udp-multi-enable")' <<<"$ENABLE_USER_FRAGMENT" >/dev/null
  nfuse() {
    [[ "${1:-}" == list && "${2:-}" == --json ]] || return 1
    printf '%s\n' '[{"name":"multi-enable","tier":"c","used_bytes":123,"ports":[{"id":1,"start":20025,"end":20025}]}]'
  }
  if prepare_user_enable multi-enable >/dev/null 2>&1; then
    echo 'multi-protocol enable must reject an account missing one Nfuse port' >&2
    exit 1
  fi
)

(
  STATE_FILE="$work/self-migrate-state.json"
  self_events="$work/self-migrate-events"
  printf '%s\n' '{"schema_version":3,"users":[{"name":"old-self","port":20022,"status":"active","metered":false}],"splits":[]}' > "$STATE_FILE"
  start_managed_operation() { return 0; }
  finish_managed_operation() { return 0; }
  nfuse() {
    if [[ "${1:-}" == list && "${2:-}" == --json ]]; then printf '[]\n'; return 0; fi
    printf '%s\n' "$*" >> "$self_events"
  }
  ensure_self_nfuse_accounts >/dev/null
  grep -Fxq 'add old-self --tier c --limit 0 --anchor 1' "$self_events"
  grep -Fxq 'port add old-self 20022' "$self_events"
)

(
  STATE_FILE="$work/self-render-state.json"
  printf '%s\n' '{"schema_version":3,"users":[{"name":"self-usage","port":20023,"status":"active","metered":false,"usage_offset_bytes":536870912,"expires_at":null,"created_at":"2026-07-15T00:00:00+00:00"}],"splits":[]}' > "$STATE_FILE"
  rendered_self="$(render_user_list '[{"name":"self-usage","tier":"c","used_bytes":1073741824,"limit_bytes":0,"ports":[{"start":20023,"end":20023}]}]')"
  grep -Fq '不限' <<<"$rendered_self"
  grep -Fq '1.5 GiB' <<<"$rendered_self"
)

(
  STATE_FILE="$work/expiry-render-state.json"
  printf '%s\n' '{"schema_version":3,"users":[{"name":"expiry-render","port":20024,"status":"active","metered":false,"usage_offset_bytes":0,"expires_at":"2026-11-14T17:01:23+0800","created_at":"2026-07-15T00:00:00+08:00"}],"splits":[]}' > "$STATE_FILE"
  rendered_expiry="$(render_user_list '[]')"
  # 到期时间与创建时间是最后两列，必须整列锚定到行尾比对：
  # 只用子串匹配的话，"2026-11-14 17:01:23+0800" 也会命中 "2026-11-14 17:01:23"。
  grep -Eq '(^|[[:space:]])2026-11-14 17:01:23[[:space:]]+2026-07-15 00:00:00[[:space:]]*$' <<<"$rendered_expiry"
  if grep -Fq '+0800' <<<"$rendered_expiry"; then
    echo '到期时间不应保留 +0800 时区尾巴' >&2
    exit 1
  fi
  if grep -Fq '+08:00' <<<"$rendered_expiry"; then
    echo '创建时间不应保留 +08:00 时区尾巴' >&2
    exit 1
  fi
)

printf '%s\n' '{"schema_version":3,"users":[{"name":"quota-user","port":20002,"status":"active","metered":true,"limit_gib":1,"billing_anchor":1,"expires_at":null,"created_at":"2026-07-14T00:00:00+00:00","method":"2022-blake3-aes-128-gcm","shadowtls_sni":"quota.example.com"}],"splits":[]}' > "$STATE_FILE"
exhausted='[{"name":"quota-user","used_bytes":1073741824,"limit_bytes":1073741824,"ports":[{"start":20002,"end":20002}]}]'
rendered_users="$(render_user_list "$exhausted")"
grep -Fq '配额耗尽' <<<"$rendered_users"
available='[{"name":"quota-user","used_bytes":1073741823,"limit_bytes":1073741824,"ports":[{"start":20002,"end":20002}]}]'
rendered_users="$(render_user_list "$available")"
grep -Fq '启用' <<<"$rendered_users"
(
  STATE_FILE="$work/render-fallback-state.json"
  printf '%s\n' '{"schema_version":4,"users":[{"name":"fallback-user","port":20003,"protocol":"anytls","status":"active","metered":true,"limit_gib":1,"billing_anchor":1,"expires_at":null,"usage_offset_bytes":0,"created_at":"2026-07-15T00:00:00+00:00","anytls_password":"fallback-secret","tls_sni":"fallback.example.com"}],"splits":[]}' > "$STATE_FILE"
  column() { return 1; }
  rendered_fallback="$(render_user_list '[]')"
  grep -Fq 'fallback-user' <<<"$rendered_fallback"
  if grep -Fq 'fallback-secret' <<<"$rendered_fallback"; then
    echo 'unexpected fallback-secret in $rendered_fallback' >&2
    exit 1
  fi
  if grep -Fq 'fallback.example.com' <<<"$rendered_fallback"; then
    echo 'unexpected fallback.example.com in $rendered_fallback' >&2
    exit 1
  fi
)

SB_SYSTEM_ROOT="$work/system-root"
export SB_SYSTEM_ROOT
mkdir -p "$SB_SYSTEM_ROOT"
classify_environment
[[ "$ENVIRONMENT_CLASS" == fresh ]]

mkdir -p "$SB_SYSTEM_ROOT/etc/sing-box" "$SB_SYSTEM_ROOT/usr/local/bin" "$SB_SYSTEM_ROOT/etc/systemd/system"
touch "$SB_SYSTEM_ROOT/etc/sing-box/config.json" "$SB_SYSTEM_ROOT/usr/local/bin/sing-box" "$SB_SYSTEM_ROOT/etc/systemd/system/sing-box.service"
classify_environment
[[ "$ENVIRONMENT_CLASS" == external ]]

touch "$SB_SYSTEM_ROOT/etc/sb-user-manager.conf"
classify_environment
[[ "$ENVIRONMENT_CLASS" == managed_partial ]]

for path in \
  /etc/sing-box/managed-users.json \
  /usr/local/sbin/sb-user-manager \
  /usr/local/bin/nfuse \
  /etc/systemd/system/nfuse.service \
  /etc/systemd/system/sb-user-expiry.service \
  /etc/systemd/system/sb-user-expiry.timer; do
  mkdir -p "$SB_SYSTEM_ROOT$(dirname "$path")"
  touch "$SB_SYSTEM_ROOT$path"
done
classify_environment
[[ "$ENVIRONMENT_CLASS" == managed_complete ]]
unset SB_SYSTEM_ROOT

migration_payload="$work/migration.json"
getent() {
  [[ "${1:-}" == ahosts ]] || return 2
  printf '%s\n' "93.184.216.34 STREAM ${2:-example.com}"
}
add_test_migration_runtime_fields() {
  local file="$1"
  jq '
    def complete_users:
      map(
        .metered = (.metered // (.limit_gib != null) // false) |
        .status = (.status // "active") |
        .expires_at = (if has("expires_at") then .expires_at else null end) |
        .limit_gib = (if .metered then (.limit_gib // 1) else (.limit_gib // null) end) |
        .billing_anchor = (if .metered then (.billing_anchor // 1) else (.billing_anchor // null) end) |
        .usage_offset_bytes = (.usage_offset_bytes // 0) |
        .created_at = (.created_at // "2026-07-15T00:00:00+08:00")
      );
    if has("state") then .state.users |= complete_users else .users |= complete_users end
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}
legacy_v412_payload="$work/migration-v4.12.json"
printf '%s\n' '{"format_version":1,"created_at":"2026-07-15T00:00:00+08:00","script_version":"4.12.0","source_hostname":"legacy-source","state":{"schema_version":3,"users":[{"name":"legacy-metered","port":20031,"status":"active","metered":true,"expires_at":"2026-12-15T00:00:00+08:00","limit_gib":10,"billing_anchor":15,"created_at":"2026-07-15T00:00:00+08:00","shadowtls_password":"st","ss2022_password":"ss","method":"2022-blake3-aes-128-gcm","shadowtls_sni":"ss.example.com"},{"name":"legacy-self","port":20032,"protocol":"anytls","status":"disabled","metered":false,"expires_at":null,"limit_gib":null,"billing_anchor":null,"created_at":"2026-07-15T00:00:00+08:00","anytls_password":"at","tls_sni":"at.example.com"}],"splits":[]},"nfuse_usage":[{"name":"legacy-metered","used_bytes":123}]}' > "$legacy_v412_payload"
validate_migration_payload_structure "$legacy_v412_payload"
jq -e '
  .state.schema_version == 7 and .state.outbound_presets == [] and .state.rule_presets == [] and
  all(.state.users[]; .usage_offset_bytes == 0)
' "$legacy_v412_payload" >/dev/null
jq '.state.users[0].usage_offset_bytes = null' "$legacy_v412_payload" > "$work/migration-invalid-offset.json"
if validate_migration_payload_structure "$work/migration-invalid-offset.json" >/dev/null 2>&1; then
  echo 'migration payload must not normalize an explicit invalid usage offset' >&2
  exit 1
fi
printf '%s\n' '{"format_version":1,"state":{"schema_version":3,"users":[{"name":"migrate-ss","port":10001,"status":"active","shadowtls_password":"st","ss2022_password":"ss","method":"2022-blake3-aes-128-gcm","shadowtls_sni":"ss.example.com"},{"name":"migrate-at","port":20012,"protocol":"anytls","status":"disabled","anytls_password":"at","tls_sni":"at.example.com"}],"splits":[]},"nfuse_usage":[]}' > "$migration_payload"
add_test_migration_runtime_fields "$migration_payload"
validate_migration_payload_structure "$migration_payload"
jq 'del(.state.users[0].status)' "$migration_payload" > "$work/migration-missing-runtime.json"
if validate_migration_payload_structure "$work/migration-missing-runtime.json" >/dev/null 2>&1; then
  echo 'migration payload with missing runtime fields should be rejected' >&2
  exit 1
fi
jq '.state.splits=[{"name":"unsafe","url":"https://127.0.0.1/internal.srs","scope":"all","user":null,"status":"disabled","outbound_tag":"unsafe-out","rule_set_tag":"unsafe-rule","upstream":{"protocol":"anytls"}}]' "$migration_payload" > "$work/migration-unsafe-url.json"
if validate_migration_payload_structure "$work/migration-unsafe-url.json" >/dev/null 2>&1; then
  echo 'migration payload must reject private rule-set URLs' >&2
  exit 1
fi
# 分流预置字段是空串时迁移包会被判定为不可安全恢复；清洗成缺省字段后必须能重新通过校验。
jq '.state.splits=[{"name":"blank","url":"https://rules.example.com/blank.srs","scope":"all","user":null,"status":"active","outbound_tag":"blank-out","rule_set_tag":"blank-rule","rule_preset":"","outbound_preset":"","upstream":{"protocol":"anytls","server":"exit.example.com","server_port":443,"password":"exit-secret","sni":"exit.example.com","insecure":false}}]' \
  "$migration_payload" > "$work/migration-blank-preset.json"
if validate_migration_payload_structure "$work/migration-blank-preset.json" >/dev/null 2>&1; then
  echo 'migration payload must reject a split whose preset fields are empty strings' >&2
  exit 1
fi
(
  STATE_FILE="$work/migration-blank-preset-state.json"
  jq '.state' "$work/migration-blank-preset.json" > "$STATE_FILE"
  state_normalize_split_preset_fields
  jq --slurpfile state "$STATE_FILE" '.state = $state[0]' "$work/migration-blank-preset.json" \
    > "$work/migration-normalized-preset.json"
)
validate_migration_payload_structure "$work/migration-normalized-preset.json"
select_migration_restore_mode <<<'' >/dev/null
[[ "$MIGRATION_RESTORE_MODE" == merge ]]
select_migration_restore_mode <<<'2' >/dev/null
[[ "$MIGRATION_RESTORE_MODE" == replace ]]
MENU_RETURNED=false
if select_migration_restore_mode <<<'0' >/dev/null; then
  echo 'restore mode zero should return to the previous menu' >&2
  exit 1
fi
[[ "$MENU_RETURNED" == true ]]
(
  STATE_FILE="$work/merge-target-state.json"
  SINGBOX_CONFIG="$work/merge-target-config.json"
  printf '%s\n' '{"schema_version":3,"users":[{"name":"existing","port":20001,"protocol":"anytls","status":"active","metered":true,"anytls_password":"target-secret","tls_sni":"target.example.com"}],"splits":[]}' > "$STATE_FILE"
  add_test_migration_runtime_fields "$STATE_FILE"
  printf '%s\n' '{"inbounds":[],"outbounds":[],"route":{"rules":[],"rule_set":[]}}' > "$SINGBOX_CONFIG"
  merge_singbox() { [[ "$1" == format && "$2" == -c ]] && cat "$3"; }
  SINGBOX_BIN=merge_singbox
  port_is_listening() { return 1; }
  nfuse() {
    if [[ "$1" == list && "$2" == --json ]]; then
      printf '%s\n' '[{"name":"existing","used_bytes":100}]'
      return 0
    fi
    return 1
  }

  merge_source="$work/merge-source.json"
  merge_output="$work/merge-output.json"
  printf '%s\n' '{"format_version":1,"created_at":"2026-07-15T00:00:00+08:00","script_version":"4.11.0","source_hostname":"source","state":{"schema_version":3,"users":[{"name":"alice","port":20002,"protocol":"anytls","status":"active","metered":true,"anytls_password":"alice-secret","tls_sni":"alice.example.com"}],"splits":[{"name":"ai","url":"https://example.com/ai.srs","scope":"user","user":"alice","status":"disabled","outbound_tag":"ai-out","rule_set_tag":"ai-rule","upstream":{"protocol":"anytls"}}]},"nfuse_usage":[{"name":"alice","used_bytes":200}]}' > "$merge_source"
  add_test_migration_runtime_fields "$merge_source"
  build_merge_migration_payload "$merge_source" "$merge_output" >/dev/null
  jq -e '
    .restore_mode == "merge" and (.state.users|length)==2 and (.state.splits|length)==1 and
    any(.state.users[]; .name=="existing" and .port==20001) and
    any(.state.users[]; .name=="alice" and .port==20002) and
    any(.state.splits[]; .name=="ai" and .user=="alice") and
    any(.nfuse_usage[]; .name=="existing" and .used_bytes==100) and
    any(.nfuse_usage[]; .name=="alice" and .used_bytes==200) and
    .merge_summary.users.imported==1 and .merge_summary.splits.imported==1
  ' "$merge_output" >/dev/null

  printf '%s\n' '{"format_version":1,"created_at":"2026-07-15T00:00:00+08:00","script_version":"4.11.0","source_hostname":"source","state":{"schema_version":3,"users":[{"name":"existing","port":20001,"protocol":"anytls","status":"active","metered":true,"anytls_password":"backup-secret","tls_sni":"backup.example.com"}],"splits":[{"name":"existing-route","url":"https://example.com/route.srs","scope":"user","user":"existing","status":"disabled","outbound_tag":"route-out","rule_set_tag":"route-rule","upstream":{"protocol":"anytls"}}]},"nfuse_usage":[{"name":"existing","used_bytes":999}]}' > "$merge_source"
  add_test_migration_runtime_fields "$merge_source"
  printf '\n' | build_merge_migration_payload "$merge_source" "$merge_output" >/dev/null
  jq -e '
    (.state.users|length)==1 and .state.users[0].anytls_password=="target-secret" and
    .state.splits[0].user=="existing" and .nfuse_usage[0].used_bytes==100 and
    .merge_summary.users.skipped==1
  ' "$merge_output" >/dev/null

  printf '3\nrestored\n20003\n' | build_merge_migration_payload "$merge_source" "$merge_output" >/dev/null
  jq -e '
    (.state.users|length)==2 and any(.state.users[]; .name=="restored" and .port==20003) and
    .state.splits[0].user=="restored" and any(.nfuse_usage[]; .name=="restored" and .used_bytes==999) and
    .merge_summary.users.renamed==1
  ' "$merge_output" >/dev/null

  printf '2\n' | build_merge_migration_payload "$merge_source" "$merge_output" >/dev/null
  jq -e '
    (.state.users|length)==1 and .state.users[0].anytls_password=="backup-secret" and
    .nfuse_usage[0].used_bytes==999 and .merge_summary.users.replaced==1
  ' "$merge_output" >/dev/null

  jq '.splits=[{"name":"AI","url":"https://target.example.com/ai.srs","scope":"all","user":null,"status":"disabled","outbound_tag":"Hinet","rule_set_tag":"AI","upstream":{"protocol":"anytls"}}]' "$STATE_FILE" > "$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
  printf '%s\n' '{"format_version":1,"created_at":"2026-07-15T00:00:00+08:00","script_version":"4.11.0","source_hostname":"source","state":{"schema_version":3,"users":[],"splits":[{"name":"AI","url":"https://backup.example.com/ai.srs","scope":"all","user":null,"status":"disabled","outbound_tag":"Hinet","rule_set_tag":"AI","upstream":{"protocol":"anytls"}}]},"nfuse_usage":[]}' > "$merge_source"
  printf '3\nAI-new\nHinet-new\nAI-new-rule\n' | build_merge_migration_payload "$merge_source" "$merge_output" >/dev/null
  jq -e '
    (.state.splits|length)==2 and any(.state.splits[]; .name=="AI-new" and .outbound_tag=="Hinet-new" and .rule_set_tag=="AI-new-rule") and
    .merge_summary.splits.renamed==1
  ' "$merge_output" >/dev/null

  if build_merge_migration_payload "$merge_source" "$merge_output" <<<'0' >/dev/null 2>&1; then
    echo 'cancelling merge conflict resolution should stop plan generation' >&2
    exit 1
  fi
  [[ "$MIGRATION_MERGE_CANCELLED" == true ]]

  printf '%s\n' '{"schema_version":4,"users":[],"splits":[],"outbound_presets":[{"name":"shared","upstream":{"protocol":"shadowsocks","server":"target.example.com","server_port":443,"method":"aes-128-gcm","password":"target"}}],"rule_presets":[{"name":"shared-rule","url":"https://rules.example.com/shared.srs"}]}' > "$STATE_FILE"
  printf '%s\n' '{"format_version":1,"created_at":"2026-07-15T00:00:00+08:00","script_version":"4.19.0","source_hostname":"source","state":{"schema_version":4,"users":[],"outbound_presets":[{"name":"shared","upstream":{"protocol":"shadowsocks","server":"source.example.com","server_port":8443,"method":"aes-256-gcm","password":"source"}}],"rule_presets":[{"name":"shared-rule","url":"https://rules.example.com/shared.srs"}],"splits":[{"name":"preset-route","url":"https://rules.example.com/shared.srs","scope":"all","user":null,"status":"disabled","outbound_tag":"preset-out","rule_set_tag":"preset-rule","outbound_preset":"shared","rule_preset":"shared-rule","upstream":{"protocol":"shadowsocks","server":"source.example.com","server_port":8443,"method":"aes-256-gcm","password":"source"}}]},"nfuse_usage":[]}' > "$merge_source"
  build_merge_migration_payload "$merge_source" "$merge_output" >/dev/null
  imported_runtime_out="$(stable_managed_tag outbound shared-imported)"
  imported_runtime_rule="$(stable_managed_tag rule shared-rule)"
  jq -e --arg runtime_out "$imported_runtime_out" --arg runtime_rule "$imported_runtime_rule" '
    .merge_summary.outbound_presets.renamed == 1 and
    .merge_summary.rule_presets.deduplicated == 1 and
    any(.state.outbound_presets[]; .name == "shared-imported" and .upstream.server == "source.example.com") and
    any(.state.splits[]; .name == "preset-route" and .outbound_preset == "shared-imported" and .rule_preset == "shared-rule" and
      .runtime_outbound_tag == $runtime_out and .runtime_rule_tag == $runtime_rule)
  ' "$merge_output" >/dev/null
)
(
  STATE_FILE="$work/merge-robust-state.json"
  SINGBOX_CONFIG="$work/merge-robust-config.json"
  printf '%s\n' '{"schema_version":3,"users":[{"name":"existing","port":20001,"protocol":"anytls","status":"active","metered":true,"anytls_password":"target-secret","tls_sni":"target.example.com"}],"splits":[]}' > "$STATE_FILE"
  add_test_migration_runtime_fields "$STATE_FILE"
  printf '%s\n' '{"inbounds":[],"outbounds":[],"route":{"rules":[],"rule_set":[]}}' > "$SINGBOX_CONFIG"
  merge_singbox() { [[ "$1" == format && "$2" == -c ]] && cat "$3"; }
  SINGBOX_BIN=merge_singbox
  port_is_listening() { return 1; }
  nfuse() {
    if [[ "$1" == list && "$2" == --json ]]; then
      printf '%s\n' '[{"name":"existing","used_bytes":100}]'
      return 0
    fi
    return 1
  }

  merge_source="$work/merge-robust-source.json"
  merge_output="$work/merge-robust-output.json"
  printf '%s\n' '{"format_version":1,"created_at":"2026-07-15T00:00:00+08:00","script_version":"4.25.7","source_hostname":"source","state":{"schema_version":7,"users":[{"name":"existing","port":20051,"protocol":"anytls","anytls_password":"backup-at","tls_sni":"backup.example.com","endpoints":[{"protocol":"anytls","port":20051,"anytls_password":"backup-at","tls_sni":"backup.example.com"},{"protocol":"ss2022","transport":"direct","port":20052,"ss2022_password":"backup-ss","method":"2022-blake3-aes-128-gcm"}]}],"splits":[],"outbound_presets":[],"rule_presets":[]},"nfuse_usage":[]}' > "$merge_source"
  add_test_migration_runtime_fields "$merge_source"

  # 用户按 Ctrl-D（EOF）时不能沿用上一次的选择，否则会静默按“覆盖”处理。
  MIGRATION_CHOICE=2
  if build_merge_migration_payload "$merge_source" "$merge_output" </dev/null >/dev/null 2>&1; then
    echo 'EOF at a merge choice prompt should abort instead of reusing the previous answer' >&2
    exit 1
  fi
  jq -e '
    .merge_summary.users.replaced == 0 and (.state.users|length) == 1 and
    .state.users[0].anytls_password == "target-secret"
  ' "$merge_output" >/dev/null

  # 同一个候选用户的两个端点填了同一个端口，必须当场拒绝并重新询问。
  merge_log="$work/merge-robust-log.txt"
  if ! printf '3\ndual\n20055\n20055\ndual\n20055\n20056\n' |
      build_merge_migration_payload "$merge_source" "$merge_output" > "$merge_log"; then
    echo 'duplicate ports inside one candidate user should be rejected while prompting, not by the final structure check' >&2
    exit 1
  fi
  grep -Fq '两个协议必须使用不同端口' "$merge_log"
  jq -e '
    (.state.users|length) == 2 and
    any(.state.users[]; .name == "dual" and ([.endpoints[].port] | sort) == [20055,20056]) and
    .merge_summary.users.renamed == 1
  ' "$merge_output" >/dev/null

  # 合并中途按 Ctrl-D 与选「0. 返回」语义相同：优雅取消回菜单，不能让 die 打死整个脚本。
  cancel_log="$work/merge-robust-cancel.txt"
  if printf '1\n' | (
      cancel_status=0
      prepare_migration_effective_payload "$merge_source" "$merge_output" || cancel_status=$?
      printf 'plan-returned:%s\n' "$cancel_status"
      exit "$cancel_status"
    ) > "$cancel_log" 2>&1; then
    echo 'EOF during merge conflict resolution must not report a usable restore plan' >&2
    exit 1
  fi
  cancel_output="$(cat "$cancel_log")"
  if ! grep -Fq 'plan-returned:1' <<<"$cancel_output"; then
    echo 'EOF during merge conflict resolution killed the whole script instead of returning to the caller' >&2
    exit 1
  fi
  if grep -Fq '无法生成恢复方案' <<<"$cancel_output"; then
    echo 'EOF during merge conflict resolution must not die with the "按上方提示处理后重试" wording; there is no such hint on screen' >&2
    exit 1
  fi
  if ! grep -Fq '已取消合并，未修改服务器。' <<<"$cancel_output"; then
    echo 'EOF during merge conflict resolution must take the same cancellation path as choosing "0. 返回"' >&2
    exit 1
  fi

  # 只读的「预览备份」也走同一条准备链，按一次 Ctrl-D 必须回到菜单而不是退出脚本。
  preview_log="$work/merge-robust-preview.txt"
  ensure_migration_crypto_dependencies() { :; }
  prepare_core() { :; }
  need_cmd() { :; }
  select_migration_backup() { SELECTED_MIGRATION_BACKUP="$merge_source"; }
  decrypt_migration_backup() { cp "$1" "$2"; }
  print_migration_preview() { echo 'unexpected-preview-output'; }
  if ! printf '1\n' | (
      preview_status=0
      preview_migration_backup || preview_status=$?
      printf 'preview-returned:%s\n' "$preview_status"
      exit "$preview_status"
    ) > "$preview_log" 2>&1; then
    echo 'previewing a backup and pressing Ctrl-D must return to the menu, not abort the manager' >&2
    exit 1
  fi
  preview_output="$(cat "$preview_log")"
  if ! grep -Fq 'preview-returned:0' <<<"$preview_output"; then
    echo 'preview_migration_backup did not return to its caller after EOF at a merge choice prompt' >&2
    exit 1
  fi
  if grep -Fq '无法生成恢复方案' <<<"$preview_output"; then
    echo 'a read-only preview must never die on EOF' >&2
    exit 1
  fi
  if grep -Fq 'unexpected-preview-output' <<<"$preview_output"; then
    echo 'a cancelled merge must not reach the preview rendering step' >&2
    exit 1
  fi
)
preview_state="$work/migration-preview-state.json"
printf '%s\n' '{"schema_version":3,"users":[{"name":"migrate-ss","port":9999},{"name":"removed-user","port":10000}],"splits":[]}' > "$preview_state"
saved_state_file="$STATE_FILE"
STATE_FILE="$preview_state"
preview_rows="$(migration_entity_change_rows "$migration_payload" users 用户)"
expected_preview_rows=$'新增\t用户\tmigrate-at\n删除\t用户\tremoved-user\n替换\t用户\tmigrate-ss'
[[ "$preview_rows" == "$expected_preview_rows" ]]
STATE_FILE="$saved_state_file"
validate_migration_port 10001
if (validate_migration_port 65536) >/dev/null 2>&1; then
  echo 'out-of-range migration port should be rejected' >&2
  exit 1
fi
printf '%s\n' '{"format_version":1,"state":{"schema_version":3,"users":[{"name":"duplicate","port":20011,"protocol":"anytls","anytls_password":"a","tls_sni":"a.example.com"},{"name":"duplicate","port":20012,"protocol":"anytls","anytls_password":"b","tls_sni":"b.example.com"}],"splits":[]},"nfuse_usage":[]}' > "$migration_payload"
add_test_migration_runtime_fields "$migration_payload"
if validate_migration_payload_structure "$migration_payload" >/dev/null 2>&1; then
  echo 'duplicate migration users should be rejected' >&2
  exit 1
fi
printf '%s\n' '{"format_version":1,"created_at":"2026-07-14T00:00:00+08:00","script_version":"4.6.0","source_hostname":"unit-source","state":{"schema_version":3,"users":[{"name":"migrate-ss","port":10001,"status":"active","shadowtls_password":"st","ss2022_password":"ss","method":"2022-blake3-aes-128-gcm","shadowtls_sni":"ss.example.com"},{"name":"migrate-at","port":20012,"protocol":"anytls","status":"disabled","anytls_password":"at","tls_sni":"at.example.com"}],"splits":[]},"nfuse_usage":[]}' > "$migration_payload"
add_test_migration_runtime_fields "$migration_payload"

encrypted="$work/sb-user-data-unit.enc"
decrypted="$work/migration.decrypted.json"
SB_BACKUP_PASSWORD='unit-test-password' openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
  -in "$migration_payload" -out "$encrypted" -pass env:SB_BACKUP_PASSWORD
sha256sum "$encrypted" > "$encrypted.sha256"
write_migration_auth_file "$encrypted" 'unit-test-password'
validate_migration_checksum "$encrypted"
verify_migration_auth_file "$encrypted" 'unit-test-password'
if verify_migration_auth_file "$encrypted" 'wrong-password' >/dev/null 2>&1; then
  echo 'wrong migration password should fail authentication' >&2
  exit 1
fi
SB_BACKUP_PASSWORD='unit-test-password' openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -in "$encrypted" -out "$decrypted" -pass env:SB_BACKUP_PASSWORD
cmp -s "$migration_payload" "$decrypted"

bundle="$work/sb-user-data-unit.sbm"
build_migration_bundle "$encrypted" "$bundle"
validate_migration_bundle "$bundle"
bundle_work="$work/materialized"
mkdir -p "$bundle_work"
materialize_migration_bundle "$bundle" "$bundle_work"
cmp -s "$encrypted" "$MATERIALIZED_MIGRATION_ENCRYPTED"

batch_dir="$work/batch-migration-health"
batch_inspection_root="$work/batch-migration-inspection"
mkdir -p "$batch_dir" "$batch_inspection_root"
cp "$bundle" "$batch_dir/sb-user-data-batch-healthy.sbm"

batch_other_encrypted="$work/batch-other-password.enc"
SB_BACKUP_PASSWORD='other-test-password' openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
  -in "$migration_payload" -out "$batch_other_encrypted" -pass env:SB_BACKUP_PASSWORD
write_migration_auth_file "$batch_other_encrypted" 'other-test-password'
build_migration_bundle "$batch_other_encrypted" "$batch_dir/sb-user-data-batch-other-password.sbm"

printf '{invalid bundle\n' > "$batch_dir/sb-user-data-batch-structure-invalid.sbm"
jq --arg sha "$(printf '0%.0s' {1..64})" '.cipher_sha256=$sha' "$bundle" \
  > "$batch_dir/sb-user-data-batch-checksum-failed.sbm"

batch_invalid_payload="$work/batch-invalid-payload.json"
batch_invalid_encrypted="$work/batch-invalid-payload.enc"
printf '%s\n' '{"format_version":1}' > "$batch_invalid_payload"
SB_BACKUP_PASSWORD='unit-test-password' openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
  -in "$batch_invalid_payload" -out "$batch_invalid_encrypted" -pass env:SB_BACKUP_PASSWORD
write_migration_auth_file "$batch_invalid_encrypted" 'unit-test-password'
build_migration_bundle "$batch_invalid_encrypted" "$batch_dir/sb-user-data-batch-payload-invalid.sbm"

batch_hashes_before="$(find "$batch_dir" -maxdepth 1 -type f -name '*.sbm' -exec sha256sum {} + | LC_ALL=C sort)"
batch_state_before="$(sha256sum "$STATE_FILE" "$SINGBOX_CONFIG")"
(
  MIGRATION_BACKUP_DIR="$batch_dir"
  mktemp() {
    if [[ "${1:-}" == -d && "${2:-}" == /tmp/sb-migration-inspect.XXXXXX ]]; then
      command mktemp -d "$batch_inspection_root/sb-migration-inspect.XXXXXX"
    else
      command mktemp "$@"
    fi
  }
  register_temp_path() {
    [[ "$1" == "$batch_inspection_root"/sb-migration-inspect.* ]]
  }
  read_backup_password() {
    BACKUP_PASSWORD='unit-test-password'
  }
  batch_output="$(check_all_migration_backups)"
  grep -Fq 'sb-user-data-batch-healthy.sbm：健康' <<<"$batch_output"
  grep -Fq 'sb-user-data-batch-other-password.sbm：密码不匹配或认证失败' <<<"$batch_output"
  grep -Fq 'sb-user-data-batch-structure-invalid.sbm：结构异常' <<<"$batch_output"
  grep -Fq 'sb-user-data-batch-checksum-failed.sbm：密文校验失败' <<<"$batch_output"
  grep -Fq 'sb-user-data-batch-payload-invalid.sbm：解密后内容异常' <<<"$batch_output"
  grep -Fq '汇总：健康 1，结构异常 1，密文校验失败 1，密码不匹配或认证失败 1，解密后内容异常 1，内部检查失败 0。' <<<"$batch_output"
  grep -Fq '没有修改备份文件或服务器上的用户、分流、配置与服务' <<<"$batch_output"
  if grep -Fq 'unit-test-password' <<<"$batch_output"; then
    echo 'unexpected unit-test-password in $batch_output' >&2
    exit 1
  fi
  [[ -z "$(find "$batch_inspection_root" -mindepth 1 -print -quit)" ]]
)
[[ "$batch_hashes_before" == "$(find "$batch_dir" -maxdepth 1 -type f -name '*.sbm' -exec sha256sum {} + | LC_ALL=C sort)" ]]
[[ "$batch_state_before" == "$(sha256sum "$STATE_FILE" "$SINGBOX_CONFIG")" ]]
(
  MIGRATION_BACKUP_DIR="$batch_dir"
  read_backup_password() { return 1; }
  MENU_RETURNED=false
  check_all_migration_backups > "$work/batch-cancel-output"
  batch_cancel_output="$(cat "$work/batch-cancel-output")"
  grep -Fxq '已取消批量体检。' <<<"$batch_cancel_output"
  [[ "$MENU_RETURNED" == true ]]
)
(
  MIGRATION_BACKUP_DIR="$work/empty-batch-migration-health"
  read_backup_password() { : > "$work/unexpected-batch-password-prompt"; }
  batch_empty_output="$(check_all_migration_backups)"
  grep -Fxq '暂无迁移备份可供体检。' <<<"$batch_empty_output"
  [[ ! -e "$work/unexpected-batch-password-prompt" ]]
)

decrypt_retry_output="$work/decrypt-retry-output"
printf '%s\n' 'wrong-password' 'unit-test-password' | decrypt_migration_backup "$bundle" "$decrypted" >"$decrypt_retry_output"
jq -e --slurpfile original "$migration_payload" '
  .state.schema_version == 7 and .state.outbound_presets == [] and .state.rule_presets == [] and
  (.state.users | map(del(.endpoints) | if .protocol == "ss2022" then del(.protocol,.transport) else . end)) == $original[0].state.users and
  all(.state.users[]; (.endpoints | length) == 1 and .endpoints[0].port == .port) and
  all(.state.users[] | select(.protocol == "ss2022"); .transport == "shadowtls" and .endpoints[0].transport == "shadowtls") and
  .state.splits == $original[0].state.splits and
  .nfuse_usage == $original[0].nfuse_usage
' "$decrypted" >/dev/null
grep -Fq '密码错误，或迁移包已经损坏。请重新输入' "$decrypt_retry_output"
if printf '%s\n' 0 | decrypt_migration_backup "$bundle" "$work/cancelled-decryption.json" >/dev/null; then
  echo 'migration decryption should allow cancellation' >&2
  exit 1
fi
[[ ! -e "$work/cancelled-decryption.json" ]]

prepare_core() { :; }
nfuse() {
  if [[ "$1" == persist ]]; then return 0; fi
  if [[ "$1" == list && "$2" == --json ]]; then printf '[]\n'; return 0; fi
  return 1
}
saved_create_state_file="$STATE_FILE"
STATE_FILE="$work/created-migration-state.json"
printf '%s\n' '{"schema_version":4,"users":[{"name":"backup-legacy","port":20041,"protocol":"anytls","status":"active","metered":false,"expires_at":null,"limit_gib":null,"billing_anchor":null,"created_at":"2026-07-15T00:00:00+08:00","anytls_password":"backup-secret","tls_sni":"backup.example.com"}],"splits":[],"outbound_presets":[],"rule_presets":[]}' > "$STATE_FILE"
MIGRATION_BACKUP_DIR="$work/created"
backup_create_output="$(printf '%s\n%s\n' 'unit-test-password' 'unit-test-password' | create_migration_backup)"
grep -Fq '请另存一份到其他设备' <<<"$backup_create_output"
created_bundle="$(find "$MIGRATION_BACKUP_DIR" -type f -name '*.sbm' -print -quit)"
validate_migration_bundle "$created_bundle"
created_materialized="$work/created-materialized"
created_plain="$work/created-payload.json"
mkdir -p "$created_materialized"
materialize_migration_bundle "$created_bundle" "$created_materialized"
SB_BACKUP_PASSWORD='unit-test-password' openssl enc -d -aes-256-cbc -md sha256 -pbkdf2 -iter 200000 \
  -in "$MATERIALIZED_MIGRATION_ENCRYPTED" -out "$created_plain" -pass env:SB_BACKUP_PASSWORD
jq -e '.state.schema_version == 7 and .state.users[0].usage_offset_bytes == 0' "$created_plain" >/dev/null

MIGRATION_BACKUP_DIR="$work/rejected-created"
jq '.users[0].usage_offset_bytes = null' "$STATE_FILE" > "$work/invalid-created-migration-state.json"
STATE_FILE="$work/invalid-created-migration-state.json"
if printf '%s\n%s\n' 'unit-test-password' 'unit-test-password' | create_migration_backup >/dev/null 2>&1; then
  echo 'migration backup creation must reject payloads that cannot be restored' >&2
  exit 1
fi
[[ -z "$(find "$MIGRATION_BACKUP_DIR" -type f -name '*.sbm' -print -quit 2>/dev/null)" ]]
STATE_FILE="$saved_create_state_file"
unset MIGRATION_BACKUP_DIR

cp "$encrypted" "$work/migration-tampered.enc"
cp "$encrypted.auth" "$work/migration-tampered.enc.auth"
printf 'x' >> "$work/migration-tampered.enc"
if verify_migration_auth_file "$work/migration-tampered.enc" 'unit-test-password' >/dev/null 2>&1; then
  echo 'tampered migration ciphertext should fail authentication' >&2
  exit 1
fi

empty_import_scan="$work/empty-import-scan"
mkdir -p "$empty_import_scan"
MIGRATION_BACKUP_DIR="$work/imported"
MIGRATION_IMPORT_SCAN_DIR="$empty_import_scan"
manual_import_output="$(printf '%s\n' "$bundle" | import_migration_backup)"
grep -Fq '未在 /root 顶层发现迁移备份，可手动输入其他路径。' <<<"$manual_import_output"
cmp -s "$bundle" "$MIGRATION_BACKUP_DIR/$(basename "$bundle")"
validate_migration_bundle "$MIGRATION_BACKUP_DIR/$(basename "$bundle")"
unset MIGRATION_BACKUP_DIR MIGRATION_IMPORT_SCAN_DIR

auto_import_scan="$work/auto-import-scan"
auto_import_destination="$work/auto-imported"
mkdir -p "$auto_import_scan/nested"
cp "$bundle" "$auto_import_scan/sb-user-data-auto-old.sbm"
cp "$bundle" "$auto_import_scan/sb-user-data-auto-new.sbm"
cp "$bundle" "$auto_import_scan/nested/sb-user-data-auto-nested.sbm"
cp "$bundle" "$auto_import_scan/not-a-migration-backup.sbm"
ln -s "$auto_import_scan/sb-user-data-auto-new.sbm" "$auto_import_scan/sb-user-data-auto-link.sbm"
touch -t 202607140101.01 "$auto_import_scan/sb-user-data-auto-old.sbm"
touch -t 202607140202.02 "$auto_import_scan/sb-user-data-auto-new.sbm"
MIGRATION_IMPORT_SCAN_DIR="$auto_import_scan"
load_migration_import_candidates
[[ "${#MIGRATION_IMPORT_CANDIDATES[@]}" == 2 ]]
[[ "$(basename "${MIGRATION_IMPORT_CANDIDATES[0]}")" == sb-user-data-auto-new.sbm ]]
[[ "$(basename "${MIGRATION_IMPORT_CANDIDATES[1]}")" == sb-user-data-auto-old.sbm ]]
MIGRATION_BACKUP_DIR="$auto_import_destination"
auto_import_output="$(printf '1\n' | import_migration_backup)"
grep -Fq '发现 /root 顶层的迁移备份：' <<<"$auto_import_output"
grep -Fq '1. sb-user-data-auto-new.sbm' <<<"$auto_import_output"
grep -Fq '2. sb-user-data-auto-old.sbm' <<<"$auto_import_output"
grep -Fq '3. 手动输入其他路径' <<<"$auto_import_output"
if grep -Fq 'sb-user-data-auto-link.sbm' <<<"$auto_import_output"; then
  echo 'unexpected sb-user-data-auto-link.sbm in $auto_import_output' >&2
  exit 1
fi
if grep -Fq 'sb-user-data-auto-nested.sbm' <<<"$auto_import_output"; then
  echo 'unexpected sb-user-data-auto-nested.sbm in $auto_import_output' >&2
  exit 1
fi
cmp -s "$bundle" "$MIGRATION_BACKUP_DIR/sb-user-data-auto-new.sbm"

manual_outside_scan="$work/sb-user-data-manual-outside-scan.sbm"
cp "$bundle" "$manual_outside_scan"
MIGRATION_BACKUP_DIR="$work/manual-imported-with-candidates"
manual_with_candidates_output="$(printf '3\n%s\n' "$manual_outside_scan" | import_migration_backup)"
grep -Fq '3. 手动输入其他路径' <<<"$manual_with_candidates_output"
cmp -s "$bundle" "$MIGRATION_BACKUP_DIR/$(basename "$manual_outside_scan")"

MIGRATION_BACKUP_DIR="$work/cancelled-auto-import"
printf '0\n' | import_migration_backup > "$work/cancelled-auto-import-output"
[[ ! -d "$MIGRATION_BACKUP_DIR" ]]

invalid_import_scan="$work/invalid-auto-import-scan"
MIGRATION_BACKUP_DIR="$work/import-after-invalid-candidate"
mkdir -p "$invalid_import_scan"
printf '{invalid bundle\n' > "$invalid_import_scan/sb-user-data-invalid-auto.sbm"
cp "$bundle" "$invalid_import_scan/sb-user-data-valid-auto.sbm"
touch -t 202607140303.03 "$invalid_import_scan/sb-user-data-invalid-auto.sbm"
touch -t 202607140202.02 "$invalid_import_scan/sb-user-data-valid-auto.sbm"
MIGRATION_IMPORT_SCAN_DIR="$invalid_import_scan"
invalid_candidate_output="$(printf '1\n2\n' | import_migration_backup)"
grep -Fq 'sb-user-data-invalid-auto.sbm' <<<"$invalid_candidate_output"
grep -Fq '校验失败' <<<"$invalid_candidate_output"
grep -Fq '备份文件不完整或已经损坏，请重新复制原始 .sbm 文件。' <<<"$invalid_candidate_output"
cmp -s "$bundle" "$MIGRATION_BACKUP_DIR/sb-user-data-valid-auto.sbm"
unset MIGRATION_BACKUP_DIR MIGRATION_IMPORT_SCAN_DIR

rows="$(migration_entity_change_rows "$migration_payload" users 用户)"
grep -Fq $'新增\t用户\tmigrate-ss' <<<"$rows"
grep -Fq $'新增\t用户\tmigrate-at' <<<"$rows"
grep -Fq $'删除\t用户\tquota-user' <<<"$rows"

conflict_payload="$work/conflict-migration.json"
jq '.state.splits=[{"name":"AI","url":"https://example.com/ai.srs","scope":"all","user":null,"status":"disabled","outbound_tag":"Hinet","rule_set_tag":"AI","upstream":{"protocol":"anytls"}}]' "$migration_payload" > "$conflict_payload"
printf '%s\n' '{"inbounds":[{"tag":"external-in","listen_port":10001}],"outbounds":[{"tag":"Hinet"}],"route":{"rule_set":[{"tag":"AI"}]}}' > "$SINGBOX_CONFIG"
port_is_listening() { [[ "$1" == 10001 ]]; }
collect_migration_conflicts "$conflict_payload"
[[ "${#MIGRATION_CONFLICTS[@]}" -ge 4 ]]

MIGRATION_REPORT_DIR="$work/reports"
write_migration_restore_report "$migration_payload" "$bundle" /root/example-snapshot success
jq -e '
  .result=="success" and .restored.users==2 and .restored.splits==0 and
  .failure_stage=="" and .environment_snapshot=="/root/example-snapshot" and (.package_sha256|length)==64
' "$MIGRATION_REPORT" >/dev/null
if grep -Fq 'ss2022_password' "$MIGRATION_REPORT"; then
  echo 'unexpected ss2022_password in $MIGRATION_REPORT' >&2
  exit 1
fi
validate_migration_restore_report "$MIGRATION_REPORT"
report_list="$(print_migration_reports)"
grep -Fq '成功' <<<"$report_list"
grep -Fq '来源：unit-source' <<<"$report_list"
report_details="$(printf '1\n' | show_migration_report_details)"
grep -Fq '执行结果：成功' <<<"$report_details"
grep -Fq '失败阶段：无' <<<"$report_details"
grep -Fq '恢复前完整备份：/root/example-snapshot' <<<"$report_details"
if grep -Fq 'ss2022_password' <<<"$report_details"; then
  echo 'unexpected ss2022_password in $report_details' >&2
  exit 1
fi
printf '{"broken":true}\n' > "$MIGRATION_REPORT_DIR/migration-restore-99999999-999999-0.json"
grep -Fq '报告异常' < <(print_migration_reports)
rm -f "$MIGRATION_REPORT_DIR/migration-restore-99999999-999999-0.json"
printf '1\ny\n' | delete_migration_report >/dev/null
[[ "$(find "$MIGRATION_REPORT_DIR" -type f -name 'migration-restore-*.json' | wc -l | tr -d ' ')" == 0 ]]
write_migration_restore_report "$migration_payload" "$bundle" /root/example-snapshot rolled_back validating_singbox
report_details="$(printf '1\n' | show_migration_report_details)"
grep -Fq '执行结果：失败，已回滚' <<<"$report_details"
grep -Fq '失败阶段：检查连接配置并启动服务' <<<"$report_details"
printf '1\ny\n' | delete_migration_report >/dev/null
for stamp in 20260714-010101-1 20260714-020202-2 20260714-030303-3; do
  report="$MIGRATION_REPORT_DIR/migration-restore-$stamp.json"
  jq -n --arg completed_at "2026-07-14T00:00:00+08:00" --arg package "unit-$stamp.sbm" \
    --arg sha "$(printf '%064d' 0)" \
    '{completed_at:$completed_at,result:"success",package:$package,package_sha256:$sha,
      source:{hostname:"unit",created_at:$completed_at,script_version:"4.6.1"},
      restored:{users:1,splits:0,nfuse_accounts:1},environment_snapshot:"/root/snapshot"}' > "$report"
done
printf '1\nCLEANUP\n' | cleanup_migration_reports >/dev/null
[[ "$(find "$MIGRATION_REPORT_DIR" -type f -name 'migration-restore-*.json' | wc -l | tr -d ' ')" == 1 ]]
printf '{"broken":true}\n' > "$MIGRATION_REPORT_DIR/migration-restore-99999999-999999-invalid.json"
for stamp in 20260715-010101-1 20260715-020202-2 20260715-030303-3; do
  report="$MIGRATION_REPORT_DIR/migration-restore-$stamp.json"
  jq -n --arg completed_at "2026-07-15T00:00:00+08:00" --arg package "unit-$stamp.sbm" \
    --arg sha "$(printf '%064d' 0)" \
    '{completed_at:$completed_at,result:"success",package:$package,package_sha256:$sha,
      source:{hostname:"unit",created_at:$completed_at,script_version:"4.20.4"},
      restored:{users:1,splits:0,nfuse_accounts:1},environment_snapshot:"/root/snapshot"}' > "$report"
done
MIGRATION_REPORT_RETENTION=2
write_migration_restore_report "$migration_payload" "$bundle" /root/example-snapshot success
load_valid_migration_reports
[[ "${#VALID_MIGRATION_REPORTS[@]}" == 2 ]]
[[ -f "$MIGRATION_REPORT_DIR/migration-restore-99999999-999999-invalid.json" ]]
MIGRATION_REPORT_RETENTION=20
unset MIGRATION_REPORT_DIR
unset -f getent

for nested_menu in diagnostic_report_menu global_sni_menu migration_backup_menu singbox_channel_menu; do
  nested_menu_output="$(printf '0\n' | "$nested_menu")"
  grep -Fq '返回上一级' <<<"$nested_menu_output"
  if grep -Fq '返回主菜单' <<<"$nested_menu_output"; then
    echo 'unexpected 返回主菜单 in $nested_menu_output' >&2
    exit 1
  fi
done
migration_backup_menu_body="$(declare -f migration_backup_menu)"
grep -Fq "check_all '批量体检全部备份（只读）'" <<<"$migration_backup_menu_body"
grep -Fq 'check_all_migration_backups' <<<"$migration_backup_menu_body"

# 未部署时「服务与配置检查」要回到菜单，而生成诊断报告仍然可用。
(
  CONF_FILE="$work/absent-manager.conf"
  rm -f "$CONF_FILE"
  pause_menu() { :; }
  prepare_core() { printf 'PREPARE_CORE_RAN\n'; }
  audit_consistency() { printf 'AUDIT_RAN\n'; AUDIT_REPAIRABLE=0; }
  prompt_consistency > "$work/prompt-consistency-not-deployed"
  grep -Fq '尚未部署管理环境。' "$work/prompt-consistency-not-deployed"
  if grep -Fq 'AUDIT_RAN' "$work/prompt-consistency-not-deployed"; then
    echo 'unexpected AUDIT_RAN in $work/prompt-consistency-not-deployed' >&2
    exit 1
  fi
  if grep -Fq 'PREPARE_CORE_RAN' "$work/prompt-consistency-not-deployed"; then
    echo 'unexpected PREPARE_CORE_RAN in $work/prompt-consistency-not-deployed' >&2
    exit 1
  fi
)
# 未部署时仍能生成诊断报告是刻意设计：配置缺失时用内置默认值并在报告里如实标注，
# 这恰恰是环境装不上时最有用的功能，不得给该菜单加菜单级护栏。
# 注意断言必须写成显式 if：`! cmd` 在 set -e 下被 errexit 豁免，命中也不会变红。
# 未部署时的护栏自己已经提示并暂停过，prompt_consistency 必须用 MENU_RETURNED
# 告诉调用点不要再暂停一次，否则用户要连按两次回车才回得去菜单。
(
  CONF_FILE="$work/consistency-guard-missing.conf"
  rm -f -- "$CONF_FILE"
  pause_count=0
  pause_menu() { pause_count=$((pause_count + 1)); }
  MENU_RETURNED=false
  prompt_consistency > "$work/consistency-guard.out" 2>&1
  if [[ "$MENU_RETURNED" != true ]]; then
    echo 'prompt_consistency must report that the guard already returned to the menu' >&2
    exit 1
  fi
  if [[ "$pause_count" != 1 ]]; then
    echo "the guard must pause exactly once, saw $pause_count" >&2
    exit 1
  fi
  grep -Fq '尚未部署管理环境' "$work/consistency-guard.out"
)
# 调用点必须遵守 MENU_RETURNED，否则护栏暂停之后还会再暂停一次
diagnostic_menu_dispatch="$(declare -f diagnostic_report_menu | tr -s '[:space:]' ' ')"
if ! grep -Fq 'MENU_RETURNED=false; prompt_consistency; [[ "$MENU_RETURNED" == true ]] || pause_menu' <<<"$diagnostic_menu_dispatch"; then
  echo 'diagnostic_report_menu must not pause again after the guard already did' >&2
  exit 1
fi

diagnostic_report_menu_body="$(declare -f diagnostic_report_menu)"
if grep -Fq 'ensure_management_environment_ready' <<<"$diagnostic_report_menu_body"; then
  echo 'diagnostic_report_menu must stay usable on an undeployed server; do not add a menu-level guard' >&2
  exit 1
fi

SB_SYSTEM_ROOT="$work/snapshot-system"
ENVIRONMENT_BACKUP_BASE="$work/environment-backups"
export SB_SYSTEM_ROOT ENVIRONMENT_BACKUP_BASE
mkdir -p "$SB_SYSTEM_ROOT/etc/sing-box/backups" "$SB_SYSTEM_ROOT/usr/local/bin" "$SB_SYSTEM_ROOT/var/lib/nfuse"
mkdir -p "$SB_SYSTEM_ROOT/usr/local/sbin"
mkdir -p "$ENVIRONMENT_BACKUP_BASE"
chmod 755 \
  "$SB_SYSTEM_ROOT" \
  "$SB_SYSTEM_ROOT/etc" \
  "$SB_SYSTEM_ROOT/usr" \
  "$SB_SYSTEM_ROOT/usr/local" \
  "$SB_SYSTEM_ROOT/usr/local/bin" \
  "$SB_SYSTEM_ROOT/usr/local/sbin" \
  "$SB_SYSTEM_ROOT/var" \
  "$SB_SYSTEM_ROOT/var/lib"
chmod 755 "$ENVIRONMENT_BACKUP_BASE"
printf 'original-config\n' > "$SB_SYSTEM_ROOT/etc/sing-box/config.json"
printf 'old-transaction\n' > "$SB_SYSTEM_ROOT/etc/sing-box/backups/config.json.20260714-010101-1.1"
printf 'original-binary\n' > "$SB_SYSTEM_ROOT/usr/local/bin/sing-box"
printf 'manager\n' > "$SB_SYSTEM_ROOT/usr/local/sbin/sb-user-manager"
python3 - "$SB_SYSTEM_ROOT/var/lib/nfuse/nfuse.db" <<'PY'
import os
import sqlite3
import sys

database = sqlite3.connect(sys.argv[1])
database.execute("PRAGMA journal_mode = WAL")
database.execute("PRAGMA wal_autocheckpoint = 0")
database.execute("CREATE TABLE snapshot_marker (value TEXT NOT NULL)")
database.execute("INSERT INTO snapshot_marker VALUES ('base-row')")
database.commit()
database.execute("INSERT INTO snapshot_marker VALUES ('committed-wal-row')")
database.commit()
os._exit(0)
PY
[[ -f "$SB_SYSTEM_ROOT/var/lib/nfuse/nfuse.db-wal" ]]
ln -s /usr/local/sbin/sb-user-manager "$SB_SYSTEM_ROOT/usr/local/bin/sbm"
create_environment_backup
snapshot="$ENV_BACKUP"
verify_environment_backup "$snapshot"
verify_environment_backup_permissions "$snapshot"
[[ ! -e "$snapshot/root/etc/sing-box/backups" ]]
python3 - "$snapshot/root/var/lib/nfuse/nfuse.db" <<'PY'
import sqlite3
import sys

database = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
assert database.execute("PRAGMA quick_check").fetchall() == [("ok",)]
assert database.execute("PRAGMA journal_mode").fetchone()[0].lower() == "delete"
assert database.execute("SELECT value FROM snapshot_marker ORDER BY rowid").fetchall() == [
    ("base-row",),
    ("committed-wal-row",),
]
database.close()
PY
[[ ! -e "$snapshot/root/var/lib/nfuse/nfuse.db-wal" ]]
[[ ! -e "$snapshot/root/var/lib/nfuse/nfuse.db-shm" ]]
[[ -z "$(find "$snapshot/root/var/lib/nfuse" -maxdepth 1 -name '.nfuse-snapshot.*' -print -quit)" ]]
if grep -Fq 'nfuse.db-wal' "$snapshot/MANIFEST.sha256"; then
  echo 'unexpected nfuse.db-wal in $snapshot/MANIFEST.sha256' >&2
  exit 1
fi
if grep -Fq 'nfuse.db-shm' "$snapshot/MANIFEST.sha256"; then
  echo 'unexpected nfuse.db-shm in $snapshot/MANIFEST.sha256' >&2
  exit 1
fi
grep -Fq $'root/usr/local/bin/sbm\t/usr/local/sbin/sb-user-manager' "$snapshot/SYMLINKS.tsv"
[[ "$(manager_file_mode "$ENVIRONMENT_BACKUP_BASE")" == 700 ]]
[[ "$(manager_file_mode "$snapshot")" == 700 ]]
[[ "$(manager_file_mode "$snapshot/root")" == 700 ]]
[[ "$(manager_file_mode "$snapshot/SNAPSHOT_VERSION")" == 600 ]]
[[ "$(manager_file_mode "$snapshot/SYMLINKS.tsv")" == 600 ]]
[[ "$(manager_file_mode "$snapshot/MANIFEST.sha256")" == 600 ]]
printf 'changed-config\n' > "$SB_SYSTEM_ROOT/etc/sing-box/config.json"
printf 'changed-binary\n' > "$SB_SYSTEM_ROOT/usr/local/bin/sing-box"
rm -f "$SB_SYSTEM_ROOT/usr/local/bin/sbm"
ln -s /usr/local/bin/another-program "$SB_SYSTEM_ROOT/usr/local/bin/sbm"
python3 - "$SB_SYSTEM_ROOT/var/lib/nfuse/nfuse.db" <<'PY'
import os
import sqlite3
import sys

database = sqlite3.connect(sys.argv[1])
database.execute("PRAGMA journal_mode = WAL")
database.execute("PRAGMA wal_autocheckpoint = 0")
database.execute("DELETE FROM snapshot_marker")
database.execute("INSERT INTO snapshot_marker VALUES ('changed-after-snapshot')")
database.commit()
os._exit(0)
PY
[[ -f "$SB_SYSTEM_ROOT/var/lib/nfuse/nfuse.db-wal" ]]
restore_environment_backup "$snapshot"
grep -Fxq 'original-config' "$SB_SYSTEM_ROOT/etc/sing-box/config.json"
grep -Fxq 'original-binary' "$SB_SYSTEM_ROOT/usr/local/bin/sing-box"
[[ "$(readlink "$SB_SYSTEM_ROOT/usr/local/bin/sbm")" == /usr/local/sbin/sb-user-manager ]]
python3 - "$SB_SYSTEM_ROOT/var/lib/nfuse/nfuse.db" <<'PY'
import sqlite3
import sys

database = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
assert database.execute("PRAGMA quick_check").fetchall() == [("ok",)]
assert database.execute("SELECT value FROM snapshot_marker ORDER BY rowid").fetchall() == [
    ("base-row",),
    ("committed-wal-row",),
]
database.close()
PY
[[ ! -e "$SB_SYSTEM_ROOT/var/lib/nfuse/nfuse.db-wal" ]]
[[ ! -e "$SB_SYSTEM_ROOT/var/lib/nfuse/nfuse.db-shm" ]]
for shared_parent in \
  "$SB_SYSTEM_ROOT" \
  "$SB_SYSTEM_ROOT/etc" \
  "$SB_SYSTEM_ROOT/usr" \
  "$SB_SYSTEM_ROOT/usr/local" \
  "$SB_SYSTEM_ROOT/usr/local/bin" \
  "$SB_SYSTEM_ROOT/usr/local/sbin" \
  "$SB_SYSTEM_ROOT/var" \
  "$SB_SYSTEM_ROOT/var/lib"; do
  [[ "$(manager_file_mode "$shared_parent")" == 755 ]]
done
chmod 644 "$snapshot/root/etc/sing-box/config.json"
if verify_environment_backup_permissions "$snapshot" >/dev/null 2>&1; then
  echo 'unsafe nested environment snapshot permissions should be rejected' >&2
  exit 1
fi
harden_environment_backup_contents "$snapshot"
verify_environment_backup_permissions "$snapshot"
chmod 755 "$snapshot"
if verify_environment_backup_permissions "$snapshot" >/dev/null 2>&1; then
  echo 'unsafe environment snapshot permissions should be rejected after creation' >&2
  exit 1
fi
verify_environment_backup "$snapshot"
chmod 700 "$snapshot"
printf 'tampered\n' >> "$snapshot/root/etc/sing-box/config.json"
if verify_environment_backup "$snapshot" >/dev/null 2>&1; then
  echo 'tampered environment snapshot should be rejected' >&2
  exit 1
fi
invalid_sqlite_root="$work/invalid-sqlite-snapshot-system"
invalid_sqlite_base="$work/invalid-sqlite-environment-backups"
mkdir -p "$invalid_sqlite_root/var/lib/nfuse"
printf 'not-a-sqlite-database\n' > "$invalid_sqlite_root/var/lib/nfuse/nfuse.db"
SB_SYSTEM_ROOT="$invalid_sqlite_root"
ENVIRONMENT_BACKUP_BASE="$invalid_sqlite_base"
ENV_BACKUP=""
if create_environment_backup >/dev/null 2>&1; then
  echo 'environment snapshot must fail when the Nfuse database is not valid SQLite' >&2
  exit 1
fi
[[ -z "$(find "$invalid_sqlite_base" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]

failed_snapshot_root="$work/failed-snapshot-system"
failed_snapshot_base="$work/failed-environment-backups"
mkdir -p "$failed_snapshot_root/etc/sing-box"
printf 'unreadable\n' > "$failed_snapshot_root/etc/sing-box/config.json"
SB_SYSTEM_ROOT="$failed_snapshot_root"
ENVIRONMENT_BACKUP_BASE="$failed_snapshot_base"
ENV_BACKUP=""
if (
  cp() {
    local arg
    for arg in "$@"; do
      [[ "$arg" == "$SB_SYSTEM_ROOT/etc/sing-box" ]] && return 1
    done
    command cp "$@"
  }
  create_environment_backup
) >/dev/null 2>&1; then
  echo 'environment snapshot should fail when a managed path cannot be copied' >&2
  exit 1
fi
[[ -z "$(find "$failed_snapshot_base" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]
unset SB_SYSTEM_ROOT ENVIRONMENT_BACKUP_BASE

is_environment_recovery_path /usr/local/bin/sbm

main_body="$(declare -f main)"
[[ "$(grep -Fc 'run_standalone_interactive_startup' <<<"$main_body")" == 1 ]]
[[ "$(grep -Fc 'run_standalone_internal_expire' <<<"$main_body")" == 1 ]]
[[ "$(grep -Fc 'ensure_manager_shortcut_for_interactive_startup' <<<"$main_body")" == 0 ]]
standalone_startup_body="$(declare -f run_standalone_interactive_startup)"
[[ "$(grep -Fc 'ensure_manager_shortcut_for_interactive_startup' <<<"$standalone_startup_body")" == 1 ]]
[[ "$(grep -Fc 'interactive_main' <<<"$standalone_startup_body")" == 1 ]]

legacy_backup_base="$work/legacy-environment-backups"
legacy_permission_marker="$work/manager-state/environment-backup-permissions-v1"
legacy_snapshot="$legacy_backup_base/20260716-010101-1"
unrelated_backup_dir="$legacy_backup_base/notes"
invalid_snapshot="$legacy_backup_base/20260716-invalid"
external_backup_dir="$work/external-backup-target"
mkdir -p "$legacy_snapshot/root/etc/sing-box" "$unrelated_backup_dir" "$invalid_snapshot/root" "$external_backup_dir"
printf '1\n' > "$legacy_snapshot/SNAPSHOT_VERSION"
printf 'legacy-config-content\n' > "$legacy_snapshot/root/etc/sing-box/config.json"
write_environment_snapshot_manifest "$legacy_snapshot"
printf '1\n' > "$invalid_snapshot/SNAPSHOT_VERSION"
ln -s "$external_backup_dir" "$legacy_backup_base/external-link"
ln -s "$external_backup_dir/links.tsv" "$invalid_snapshot/SYMLINKS.tsv"
printf 'invalid-manifest\n' > "$invalid_snapshot/MANIFEST.sha256"
chmod 755 "$legacy_backup_base" "$legacy_snapshot" "$legacy_snapshot/root" "$unrelated_backup_dir" "$invalid_snapshot" "$external_backup_dir"
chmod 644 "$legacy_snapshot/SNAPSHOT_VERSION" "$legacy_snapshot/SYMLINKS.tsv" "$legacy_snapshot/MANIFEST.sha256"
legacy_content_sha_before="$(sha256sum "$legacy_snapshot/root/etc/sing-box/config.json" "$legacy_snapshot/MANIFEST.sha256")"
ENVIRONMENT_BACKUP_BASE="$legacy_backup_base"
ENVIRONMENT_BACKUP_PERMISSION_MARKER="$legacy_permission_marker"
export ENVIRONMENT_BACKUP_BASE
harden_existing_environment_backups
[[ "$(manager_file_mode "$legacy_backup_base")" == 700 ]]
[[ "$(manager_file_mode "$legacy_snapshot")" == 700 ]]
[[ "$(manager_file_mode "$legacy_snapshot/root")" == 700 ]]
[[ "$(manager_file_mode "$legacy_snapshot/root/etc/sing-box/config.json")" == 600 ]]
[[ "$(manager_file_mode "$legacy_snapshot/SNAPSHOT_VERSION")" == 600 ]]
[[ "$(manager_file_mode "$legacy_snapshot/SYMLINKS.tsv")" == 600 ]]
[[ "$(manager_file_mode "$legacy_snapshot/MANIFEST.sha256")" == 600 ]]
[[ "$(manager_file_mode "$unrelated_backup_dir")" == 755 ]]
[[ "$(manager_file_mode "$invalid_snapshot")" == 755 ]]
[[ "$(manager_file_mode "$external_backup_dir")" == 755 ]]
[[ "$legacy_content_sha_before" == "$(sha256sum "$legacy_snapshot/root/etc/sing-box/config.json" "$legacy_snapshot/MANIFEST.sha256")" ]]
[[ -f "$legacy_permission_marker" && ! -L "$legacy_permission_marker" ]]
[[ "$(manager_file_mode "$legacy_permission_marker")" == 600 ]]
if ! (
  chmod() { return 99; }
  harden_existing_environment_backups
); then
  echo 'environment snapshot permission migration should be idempotent' >&2
  exit 1
fi

# 新增快照会改变备份根目录，下一次启动必须自动重新扫描并修复。
added_legacy_snapshot="$legacy_backup_base/20260716-020202-2"
mkdir -p "$added_legacy_snapshot/root/etc/sing-box"
printf '1\n' > "$added_legacy_snapshot/SNAPSHOT_VERSION"
printf 'added-config-content\n' > "$added_legacy_snapshot/root/etc/sing-box/config.json"
write_environment_snapshot_manifest "$added_legacy_snapshot"
chmod 755 "$added_legacy_snapshot" "$added_legacy_snapshot/root"
chmod 644 "$added_legacy_snapshot/SNAPSHOT_VERSION" "$added_legacy_snapshot/SYMLINKS.tsv" "$added_legacy_snapshot/MANIFEST.sha256"
harden_existing_environment_backups
[[ "$(manager_file_mode "$added_legacy_snapshot")" == 700 ]]
[[ "$(manager_file_mode "$added_legacy_snapshot/root")" == 700 ]]
[[ "$(manager_file_mode "$added_legacy_snapshot/SNAPSHOT_VERSION")" == 600 ]]

# 标记损坏时不能跳过检查；修复后应重新写入有效标记。
printf 'damaged-cache\n' > "$legacy_permission_marker"
chmod 755 "$legacy_snapshot"
chmod 644 "$legacy_snapshot/SNAPSHOT_VERSION"
harden_existing_environment_backups
[[ "$(manager_file_mode "$legacy_snapshot")" == 700 ]]
[[ "$(manager_file_mode "$legacy_snapshot/SNAPSHOT_VERSION")" == 600 ]]
[[ "$(<"$legacy_permission_marker")" != damaged-cache ]]

# 标记文件本身不能是符号链接，避免 root 启动时覆盖外部文件。
external_permission_marker="$work/external-permission-marker"
printf 'keep-external-content\n' > "$external_permission_marker"
rm -f "$legacy_permission_marker"
ln -s "$external_permission_marker" "$legacy_permission_marker"
if harden_existing_environment_backups; then
  echo 'symlink permission cache marker should be rejected' >&2
  exit 1
fi
[[ "$(<"$external_permission_marker")" == keep-external-content ]]
rm -f "$legacy_permission_marker"

symlink_backup_base="$work/symlink-environment-backups"
ln -s "$external_backup_dir" "$symlink_backup_base"
ENVIRONMENT_BACKUP_BASE="$symlink_backup_base"
if harden_existing_environment_backups; then
  echo 'symlink environment backup base should be rejected' >&2
  exit 1
fi
[[ "$(manager_file_mode "$external_backup_dir")" == 755 ]]
missing_backup_base="$work/missing-environment-backups"
ENVIRONMENT_BACKUP_BASE="$missing_backup_base"
ENVIRONMENT_BACKUP_PERMISSION_MARKER="$work/missing-state/environment-backup-permissions-v1"
harden_existing_environment_backups
[[ ! -e "$ENVIRONMENT_BACKUP_PERMISSION_MARKER" ]]
unset ENVIRONMENT_BACKUP_BASE ENVIRONMENT_BACKUP_PERMISSION_MARKER

make_unit_environment_snapshot() {
  local snapshot="$1"
  mkdir -p "$snapshot/root"
  printf '1\n' > "$snapshot/SNAPSHOT_VERSION"
  write_environment_snapshot_manifest "$snapshot"
  chmod 700 "$snapshot" "$snapshot/root"
  chmod 600 "$snapshot/SNAPSHOT_VERSION" "$snapshot/SYMLINKS.tsv" "$snapshot/MANIFEST.sha256"
}

MIGRATION_BACKUP_DIR="$work/retention-data"
ENVIRONMENT_BACKUP_BASE="$work/retention-environment"
mkdir -p "$MIGRATION_BACKUP_DIR" "$ENVIRONMENT_BACKUP_BASE"
touch "$MIGRATION_BACKUP_DIR/sb-user-data-4.6.0-20260714-010101.sbm"
touch "$MIGRATION_BACKUP_DIR/sb-user-data-4.6.0-20260714-020202.sbm"
touch "$MIGRATION_BACKUP_DIR/sb-user-data-4.6.0-20260714-030303.sbm"
for stamp in 20260714-010101-1 20260714-020202-2 20260714-030303-3; do
  make_unit_environment_snapshot "$ENVIRONMENT_BACKUP_BASE/$stamp"
done
printf '1\n1\nCLEANUP\n' | cleanup_backup_retention >/dev/null
[[ "$(find "$MIGRATION_BACKUP_DIR" -type f -name '*.sbm' | wc -l | tr -d ' ')" == 1 ]]
[[ "$(find "$ENVIRONMENT_BACKUP_BASE" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" == 1 ]]
unset MIGRATION_BACKUP_DIR ENVIRONMENT_BACKUP_BASE

# 自动整理完整环境快照时，活动恢复点和异常目录必须保留。
ENVIRONMENT_BACKUP_BASE="$work/automatic-environment-retention"
ENVIRONMENT_TRANSACTION_JOURNAL="$work/automatic-environment-transaction.json"
mkdir -p "$ENVIRONMENT_BACKUP_BASE"
for stamp in \
  20260714-010101-1 20260714-020202-2 20260714-030303-3 \
  20260714-040404-4 20260714-050505-5 20260714-060606-6; do
  make_unit_environment_snapshot "$ENVIRONMENT_BACKUP_BASE/$stamp"
done
invalid_environment_snapshot="$ENVIRONMENT_BACKUP_BASE/20260714-070707-invalid"
mkdir -p "$invalid_environment_snapshot/root"
printf '1\n' > "$invalid_environment_snapshot/SNAPSHOT_VERSION"
external_environment_target="$work/external-environment-target"
mkdir -p "$external_environment_target"
ln -s "$external_environment_target" "$ENVIRONMENT_BACKUP_BASE/20260714-080808-link"
jq -n --arg snapshot "$ENVIRONMENT_BACKUP_BASE/20260714-010101-1" \
  '{snapshot:$snapshot}' > "$ENVIRONMENT_TRANSACTION_JOURNAL"
prune_environment_backups 2
[[ -d "$ENVIRONMENT_BACKUP_BASE/20260714-010101-1" ]]
[[ -d "$ENVIRONMENT_BACKUP_BASE/20260714-060606-6" ]]
[[ -d "$ENVIRONMENT_BACKUP_BASE/20260714-050505-5" ]]
[[ "$(find "$ENVIRONMENT_BACKUP_BASE" -mindepth 1 -maxdepth 1 -type d -exec test -f '{}/MANIFEST.sha256' \; -print | wc -l | tr -d ' ')" == 3 ]]
[[ -d "$invalid_environment_snapshot" ]]
[[ -L "$ENVIRONMENT_BACKUP_BASE/20260714-080808-link" ]]
[[ -d "$external_environment_target" ]]
rm -f "$ENVIRONMENT_TRANSACTION_JOURNAL"
prune_environment_backups 2
[[ ! -e "$ENVIRONMENT_BACKUP_BASE/20260714-010101-1" ]]
[[ "$(find "$ENVIRONMENT_BACKUP_BASE" -mindepth 1 -maxdepth 1 -type d -exec test -f '{}/MANIFEST.sha256' \; -print | wc -l | tr -d ' ')" == 2 ]]
[[ "$(count_invalid_environment_snapshots)" == 1 ]]

# 首次从旧版升级后，仅正式安装入口可以执行一次历史快照整理。
first_upgrade_base="$work/first-upgrade-environment"
first_upgrade_marker="$work/first-upgrade-state/backup-retention-v1"
first_upgrade_installed="$work/first-upgrade-installed-manager"
first_upgrade_candidate="$work/first-upgrade-candidate"
mkdir -p "$first_upgrade_base"
printf '#!/usr/bin/env bash\n' > "$first_upgrade_installed"
printf '#!/usr/bin/env bash\n' > "$first_upgrade_candidate"
chmod 700 "$first_upgrade_installed" "$first_upgrade_candidate"
for stamp in \
  20260715-010101-1 20260715-020202-2 20260715-030303-3 \
  20260715-040404-4 20260715-050505-5 20260715-060606-6; do
  make_unit_environment_snapshot "$first_upgrade_base/$stamp"
done
saved_self_path="$SELF_PATH"
ENVIRONMENT_BACKUP_BASE="$first_upgrade_base"
ENVIRONMENT_TRANSACTION_JOURNAL="$work/first-upgrade-environment-transaction.json"
BACKUP_RETENTION_MIGRATION_MARKER="$first_upgrade_marker"
MANAGER_INSTALLED_PATH="$first_upgrade_installed"
ENVIRONMENT_BACKUP_RETENTION=5

SELF_PATH="$first_upgrade_candidate"
migrate_backup_retention_once
[[ "$(find "$first_upgrade_base" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" == 6 ]]
[[ ! -e "$first_upgrade_marker" ]]

SELF_PATH="$first_upgrade_installed"
first_upgrade_output="$(migrate_backup_retention_once)"
grep -Fq '首次启用备份自动整理' <<<"$first_upgrade_output"
grep -Fq '有效快照最多保留最近 5 份' <<<"$first_upgrade_output"
[[ "$(find "$first_upgrade_base" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" == 5 ]]
[[ "$(<"$first_upgrade_marker")" == 1 ]]
[[ "$(manager_file_mode "$first_upgrade_marker")" == 600 ]]

# 完成标记使普通后续启动保持只读；活动事务则阻止首次整理。
make_unit_environment_snapshot "$first_upgrade_base/20260715-070707-7"
[[ -z "$(migrate_backup_retention_once)" ]]
[[ "$(find "$first_upgrade_base" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" == 6 ]]
rm -f "$first_upgrade_marker"
jq -n --arg snapshot "$first_upgrade_base/20260715-070707-7" \
  '{snapshot:$snapshot}' > "$ENVIRONMENT_TRANSACTION_JOURNAL"
if migrate_backup_retention_once; then
  echo 'active environment transaction should block first-upgrade retention migration' >&2
  exit 1
fi
[[ "$(find "$first_upgrade_base" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" == 6 ]]
[[ ! -e "$first_upgrade_marker" ]]
rm -f "$ENVIRONMENT_TRANSACTION_JOURNAL"

# 完成标记路径异常时不能覆盖外部文件，也不能先删除快照。
external_retention_marker="$work/external-retention-marker"
printf 'keep-external\n' > "$external_retention_marker"
mkdir -p "$(dirname "$first_upgrade_marker")"
ln -s "$external_retention_marker" "$first_upgrade_marker"
if migrate_backup_retention_once; then
  echo 'symlink backup retention marker should be rejected' >&2
  exit 1
fi
[[ "$(<"$external_retention_marker")" == keep-external ]]
[[ "$(find "$first_upgrade_base" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" == 6 ]]
rm -f "$first_upgrade_marker"
(
  prune_environment_backups() { return 72; }
  if migrate_backup_retention_once; then
    echo 'failed first-upgrade retention pruning should propagate failure' >&2
    exit 1
  fi
)
[[ ! -e "$first_upgrade_marker" ]]
[[ "$(find "$first_upgrade_base" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" == 6 ]]
SELF_PATH="$saved_self_path"
unset ENVIRONMENT_BACKUP_BASE ENVIRONMENT_TRANSACTION_JOURNAL BACKUP_RETENTION_MIGRATION_MARKER
unset MANAGER_INSTALLED_PATH

# 内部事务备份按整组整理；活动组、残缺文件和符号链接不得被删除。
BACKUP_DIR="$work/automatic-operation-retention"
TRANSACTION_DIR="$work/automatic-operation-transactions"
TRANSACTION_JOURNAL="$TRANSACTION_DIR/active.json"
mkdir -p "$BACKUP_DIR" "$TRANSACTION_DIR"
for stamp in \
  20260714-010101-1.1 20260714-020202-2.2 20260714-030303-3.3 \
  20260714-040404-4.4 20260714-050505-5.5 20260714-060606-6.6; do
  printf '{}\n' > "$BACKUP_DIR/config.json.$stamp"
  printf '{}\n' > "$BACKUP_DIR/managed-users.json.$stamp"
  printf '[]\n' > "$BACKUP_DIR/nfuse.json.$stamp"
  printf 'SS2022_SHADOWTLS_SNI="unit"\n' > "$BACKUP_DIR/sb-user-manager.conf.$stamp"
done
# 旧版完整组没有 Nfuse 文件，也应被识别并按同一保留规则整理。
printf '{}\n' > "$BACKUP_DIR/config.json.20260713-010101-1.1"
printf '{}\n' > "$BACKUP_DIR/managed-users.json.20260713-010101-1.1"
printf '{}\n' > "$BACKUP_DIR/config.json.20260714-070707-7.7"
external_operation_file="$work/external-operation-file"
printf 'external\n' > "$external_operation_file"
ln -s "$external_operation_file" "$BACKUP_DIR/config.json.20260714-080808-8.8"
jq -n --arg stamp '20260714-010101-1.1' '{backup_stamp:$stamp}' > "$TRANSACTION_JOURNAL"
prune_operation_transaction_backups 2
load_operation_backup_groups
[[ "${#OPERATION_BACKUP_GROUPS[@]}" == 3 ]]
[[ -f "$BACKUP_DIR/config.json.20260714-010101-1.1" ]]
[[ -f "$BACKUP_DIR/config.json.20260714-060606-6.6" ]]
[[ -f "$BACKUP_DIR/config.json.20260714-050505-5.5" ]]
[[ -f "$BACKUP_DIR/config.json.20260714-070707-7.7" ]]
[[ ! -e "$BACKUP_DIR/config.json.20260713-010101-1.1" ]]
[[ -L "$BACKUP_DIR/config.json.20260714-080808-8.8" ]]
[[ "$(<"$external_operation_file")" == external ]]
[[ "$(count_incomplete_operation_backup_files)" == 1 ]]
rm -f "$TRANSACTION_JOURNAL"
prune_operation_transaction_backups 2
load_operation_backup_groups
[[ "${#OPERATION_BACKUP_GROUPS[@]}" == 2 ]]
[[ ! -e "$BACKUP_DIR/config.json.20260714-010101-1.1" ]]

MIGRATION_BACKUP_DIR="$work/overview-migration"
MIGRATION_REPORT_DIR="$work/overview-reports"
mkdir -p "$MIGRATION_BACKUP_DIR" "$MIGRATION_REPORT_DIR"
overview_output="$(show_backup_storage_overview)"
grep -Fq '迁移备份' <<<"$overview_output"
grep -Fq '完整回滚备份' <<<"$overview_output"
grep -Fq '内部操作备份' <<<"$overview_output"
grep -Fq '恢复记录' <<<"$overview_output"
grep -Fq '发现未自动处理的异常文件' <<<"$overview_output"
unset MIGRATION_BACKUP_DIR MIGRATION_REPORT_DIR ENVIRONMENT_BACKUP_BASE

# 下载摘要错误时必须在解包和安装前停止。
(
  download_work="$work/download-fingerprint"
  mkdir -p "$download_work"
  LATEST_KERNEL_VERSION=1.2.3
  LATEST_KERNEL_ASSET=sing-box-1.2.3-linux-amd64.tar.gz
  LATEST_KERNEL_URL=https://example.com/sing-box.tar.gz
  LATEST_KERNEL_SHA256="$(printf '0%.0s' {1..64})"
  LATEST_NFUSE_VERSION=1.2.3
  LATEST_NFUSE_URL=https://example.com/nfuse.tar.gz
  LATEST_NFUSE_SHA256="$(printf '0%.0s' {1..64})"
  installed_singbox_version() { printf '0.0.0'; }
  installed_kernel_version() { printf '0.0.0'; }
  installed_nfuse_version() { printf '0.0.0'; }
  curl() {
    local output=""
    while (($#)); do
      if [[ "$1" == -o ]]; then output="$2"; shift 2; else shift; fi
    done
    printf 'tampered\n' > "$output"
  }
  sha256sum() { return 1; }
  tar() { printf 'unexpected\n' > "$download_work/tar-called"; }
  install() { printf 'unexpected\n' > "$download_work/install-called"; }
  if download_binaries "$download_work"; then
    echo 'download_binaries must reject an invalid release fingerprint' >&2
    exit 1
  fi
  [[ ! -e "$download_work/tar-called" && ! -e "$download_work/install-called" ]]
  LATEST_MANAGER_URL=https://example.com/sb-user-manager.sh
  LATEST_MANAGER_SHA256="$(printf '0%.0s' {1..64})"
  LATEST_MANAGER_VERSION="$SCRIPT_VERSION"
  if download_manager "$download_work" "$download_work/installed-manager"; then
    echo 'download_manager must reject an invalid release fingerprint' >&2
    exit 1
  fi
  [[ ! -e "$download_work/install-called" && ! -e "$download_work/installed-manager" ]]
)
(
  download_work="$work/download-tar-symlink"
  mkdir -p "$download_work"
  LATEST_KERNEL_VERSION=1.2.3
  LATEST_KERNEL_ASSET=sing-box-1.2.3-linux-amd64.tar.gz
  LATEST_KERNEL_URL=https://example.com/sing-box.tar.gz
  LATEST_KERNEL_SHA256="$(printf 'a%.0s' {1..64})"
  LATEST_NFUSE_VERSION=1.2.3
  LATEST_NFUSE_URL=https://example.com/nfuse.tar.gz
  LATEST_NFUSE_SHA256="$(printf 'a%.0s' {1..64})"
  installed_singbox_version() { printf '0.0.0'; }
  installed_kernel_version() { printf '0.0.0'; }
  installed_nfuse_version() { printf '0.0.0'; }
  curl() {
    local output=""
    while (($#)); do
      if [[ "$1" == -o ]]; then output="$2"; shift 2; else shift; fi
    done
    : > "$output"
  }
  sha256sum() { [[ "$1" == -c ]] && { cat >/dev/null; return 0; }; return 0; }
  tar() {
    local destination="" member="" arg
    for arg in "$@"; do member="$arg"; done
    while (($#)); do
      if [[ "$1" == -C ]]; then destination="$2"; shift 2; else shift; fi
    done
    mkdir -p "$destination/${member%/*}"
    : > "$download_work/tar-called"
    printf 'target\n' > "$download_work/tar-target"
    ln -s "$download_work/tar-target" "$destination/$member"
  }
  install() { printf 'unexpected\n' > "$download_work/install-called"; }
  if download_binaries "$download_work"; then
    echo 'download_binaries must reject a symlink release member' >&2
    exit 1
  fi
  [[ -e "$download_work/tar-called" && ! -e "$download_work/install-called" ]]
)

# 版本记录只有在二进制还在时才可信；nfuse 丢失后必须报告为未安装并重新下载。
(
  nfuse_versions="$work/nfuse-version-record"
  nfuse_missing_bin="$work/nfuse-missing-bin"
  nfuse_present_bin="$work/nfuse-present-bin"
  printf '%s\n' 'SCRIPT_VERSION=4.12.0' 'SINGBOX_VERSION=1.13.14' 'NFUSE_VERSION=0.1.13' > "$nfuse_versions"
  cat > "$nfuse_present_bin" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == version ]]; then echo 'nfuse 0.1.13'; else exit 0; fi
EOF
  chmod +x "$nfuse_present_bin"
  DEPLOYED_VERSIONS_FILE="$nfuse_versions"
  NFUSE_BIN="$nfuse_missing_bin"
  [[ -z "$(installed_nfuse_version)" ]]
  NFUSE_BIN="$nfuse_present_bin"
  [[ "$(installed_nfuse_version)" == 0.1.13 ]]

  # 文件还在、执行位还在，但内容残缺跑不起来：版本记录同样不可信，必须重新下载。
  nfuse_broken_bin="$work/nfuse-broken-bin"
  printf '\177ELF\000\000garbage' > "$nfuse_broken_bin"
  chmod +x "$nfuse_broken_bin"
  NFUSE_BIN="$nfuse_broken_bin"
  if [[ -n "$(installed_nfuse_version)" ]]; then
    echo 'a corrupted nfuse binary must not be trusted just because the version record exists' >&2
    exit 1
  fi

  # 但「跑得起来、只是 version 输出格式变了」不等于损坏：版本号仍以记录为准，
  # 否则 Nfuse 日后改版就会被误判为损坏并陷入反复重装。
  nfuse_newfmt_bin="$work/nfuse-newfmt-bin"
  cat > "$nfuse_newfmt_bin" <<'NFUSENEWFMT'
#!/usr/bin/env bash
echo 'nfuse v0.1.13 (build abcdef)'
NFUSENEWFMT
  chmod +x "$nfuse_newfmt_bin"
  NFUSE_BIN="$nfuse_newfmt_bin"
  if [[ "$(installed_nfuse_version)" != 0.1.13 ]]; then
    echo 'a working nfuse must keep using the recorded version even if its output format changed' >&2
    exit 1
  fi

  # 二进制跑得起来但没有版本记录时，才从输出里解析版本号
  nfuse_no_record="$work/nfuse-no-record"
  DEPLOYED_VERSIONS_FILE="$nfuse_no_record"
  NFUSE_BIN="$nfuse_present_bin"
  if [[ "$(installed_nfuse_version)" != 0.1.13 ]]; then
    echo 'without a version record the version must be parsed from the binary output' >&2
    exit 1
  fi
)
(
  download_work="$work/download-missing-nfuse"
  mkdir -p "$download_work"
  LATEST_KERNEL_VERSION=1.13.14
  LATEST_KERNEL_ASSET=sing-box-1.13.14-linux-amd64.tar.gz
  LATEST_KERNEL_URL=https://example.com/sing-box.tar.gz
  LATEST_KERNEL_SHA256="$(printf 'a%.0s' {1..64})"
  LATEST_NFUSE_VERSION=0.1.13
  LATEST_NFUSE_URL=https://example.com/nfuse.tar.gz
  LATEST_NFUSE_SHA256="$(printf 'a%.0s' {1..64})"
  DEPLOYED_VERSIONS_FILE="$download_work/versions"
  printf '%s\n' 'SCRIPT_VERSION=4.12.0' 'SINGBOX_VERSION=1.13.14' 'NFUSE_VERSION=0.1.13' > "$DEPLOYED_VERSIONS_FILE"
  NFUSE_BIN="$download_work/nfuse-missing"
  installed_singbox_version() { printf '1.13.14'; }
  installed_kernel_version() { printf '1.13.14'; }
  curl() {
    local output=""
    while (($#)); do
      if [[ "$1" == -o ]]; then output="$2"; shift 2; else shift; fi
    done
    : > "$output"
    printf '%s\n' "$output" >> "$download_work/curl-called"
  }
  sha256sum() { return 1; }
  if download_binaries "$download_work"; then
    echo 'download_binaries must refetch nfuse when the binary is missing' >&2
    exit 1
  fi
  grep -Fq 'nfuse.tar.gz' "$download_work/curl-called"
)

# 迁移备份与恢复报告必须按真实 mtime 排序，而不是按文件名排序。
MIGRATION_BACKUP_DIR="$work/mtime-backups"
MIGRATION_REPORT_DIR="$work/mtime-reports"
mkdir -p "$MIGRATION_BACKUP_DIR" "$MIGRATION_REPORT_DIR"
printf '{}\n' > "$MIGRATION_BACKUP_DIR/sb-user-data-9.0.0-20990101-000000.sbm"
printf '{}\n' > "$MIGRATION_BACKUP_DIR/sb-user-data-1.0.0-20000101-000000.sbm"
printf '{}\n' > "$MIGRATION_REPORT_DIR/migration-restore-20990101.json"
printf '{}\n' > "$MIGRATION_REPORT_DIR/migration-restore-20000101.json"
python3 - "$MIGRATION_BACKUP_DIR" "$MIGRATION_REPORT_DIR" <<'PY'
import os, sys
backup, report = sys.argv[1:]
os.utime(os.path.join(backup, "sb-user-data-9.0.0-20990101-000000.sbm"), (100, 100))
os.utime(os.path.join(backup, "sb-user-data-1.0.0-20000101-000000.sbm"), (200, 200))
os.utime(os.path.join(report, "migration-restore-20990101.json"), (100, 100))
os.utime(os.path.join(report, "migration-restore-20000101.json"), (200, 200))
PY
load_migration_backups
[[ "$(basename "${MIGRATION_BACKUPS[0]}")" == sb-user-data-1.0.0-20000101-000000.sbm ]]
load_migration_reports
[[ "$(basename "${MIGRATION_REPORTS[0]}")" == migration-restore-20000101.json ]]
unset MIGRATION_BACKUP_DIR MIGRATION_REPORT_DIR

# 状态恢复使用同目录临时文件和原子替换。
atomic_restore_dir="$work/atomic-state-restore"
mkdir -p "$atomic_restore_dir"
STATE_FILE="$atomic_restore_dir/state.json"
printf 'new\n' > "$STATE_FILE"
printf 'old\n' > "$atomic_restore_dir/backup.json"
chmod 600 "$atomic_restore_dir/backup.json"
restore_state_backup_atomically "$atomic_restore_dir/backup.json"
[[ "$(<"$STATE_FILE")" == old ]]
if find "$atomic_restore_dir" -maxdepth 1 -name '.state-restore.*' -print -quit | grep -q .; then
  echo 'atomic state restore left a temporary file behind' >&2
  exit 1
fi

# 内层事务结束不得清除最外层的 ERR 与信号回滚处理。
(
  ACTIVE_TRANSACTION_DEPTH=2
  ACTIVE_SIGNAL_ROLLBACK=outer-rollback
  commit_operation_transaction() { ACTIVE_TRANSACTION_DEPTH=1; }
  trap ':' ERR
  finish_managed_operation
  [[ -n "$(trap -p ERR)" ]]
  [[ "$ACTIVE_SIGNAL_ROLLBACK" == outer-rollback ]]
)
renew_body="$(declare -f cmd_renew)"
if grep -Fq 'cmd_enable ' <<<"$renew_body"; then
  echo 'unexpected cmd_enable  in $renew_body' >&2
  exit 1
fi
grep -Fq 'run_managed_step enable_user_without_transaction' <<<"$renew_body"
renew_expiry_body="$(declare -f calculate_renewal_expiry)"
grep -Fq 'date -d "$base_time ${months} months"' <<<"$renew_expiry_body"
if grep -Fq '+${months} month' <<<"$renew_expiry_body"; then
  echo 'unexpected +${months} month in $renew_expiry_body' >&2
  exit 1
fi
grep -Fq 'date -d "$base_time ${months#-} months ago"' <<<"$renew_expiry_body"
grep -Fq '^-?[1-9][0-9]*$' <<<"$renew_expiry_body"

# GNU date 必须按输入增加或减少对应月份，并保持时分秒；旧表达式会把 +N 当成时区。
if date -d '2026-08-15 10:20:30 UTC' +%s >/dev/null 2>&1; then
  (
    export TZ=UTC0
    renewal_base="$(date -d '2026-08-15 10:20:30 UTC' +%s)"
    for renewal_case in \
      '1|2026-09-15T10:20:30+0000' \
      '2|2026-10-15T10:20:30+0000' \
      '6|2027-02-15T10:20:30+0000' \
      '12|2027-08-15T10:20:30+0000' \
      '25|2028-09-15T10:20:30+0000'; do
      renewal_months="${renewal_case%%|*}"
      renewal_expected="${renewal_case#*|}"
      [[ "$(calculate_renewal_expiry "$renewal_base" "$renewal_months")" == "$renewal_expected" ]]
    done
    renewal_october_base="$(date -d '2026-10-12 10:20:30 UTC' +%s)"
    [[ "$(calculate_renewal_expiry "$renewal_october_base" -1)" == 2026-09-12T10:20:30+0000 ]]
    [[ "$(calculate_renewal_expiry "$renewal_october_base" -2)" == 2026-08-12T10:20:30+0000 ]]
    if calculate_renewal_expiry "$renewal_october_base" 0 >/dev/null 2>&1; then
      echo 'calculate_renewal_expiry must not succeed here' >&2
      exit 1
    fi
  )
else
  printf '%s\n' 'renewal date matrix skipped: GNU date is unavailable' >&2
fi

# 未到期用户从原到期时间续，已过期用户从当前时间续；计算失败不得开始事务。
(
  renewal_expires_epoch=2000
  renewal_now_epoch=1000
  renewal_new_expiry_epoch=3000
  renewal_status=active
  renewal_calls="$work/renewal-date-calls"
  : > "$renewal_calls"
  renewal_expiry_written=""
  renewal_transaction_started=false
  renewal_state_write_calls=0
  renewal_prepare_enable_calls=0
  renewal_enable_calls=0
  validate_name() { :; }
  user_exists() { :; }
  get_user_json() {
    jq -cn --arg expires "$renewal_expires_epoch" --arg status "$renewal_status" \
      '{name:"renew-user",expires_at:$expires,status:$status}'
  }
  date() {
    if [[ "$*" == '+%s' ]]; then
      printf '%s\n' "$renewal_now_epoch"
    elif [[ "${1:-}" == -d && "${3:-}" == +%s ]]; then
      if [[ "$2" == 2027-* ]]; then
        printf '%s\n' "$renewal_new_expiry_epoch"
      else
        printf '%s\n' "$renewal_expires_epoch"
      fi
    else
      return 1
    fi
  }
  calculate_renewal_expiry() {
    printf '%s|%s\n' "$1" "$2" >> "$renewal_calls"
    printf '2027-02-15T10:20:30+0000\n'
  }
  start_managed_operation() { renewal_transaction_started=true; }
  run_managed_step() { "$@"; }
  prepare_user_enable() { renewal_prepare_enable_calls=$((renewal_prepare_enable_calls + 1)); }
  enable_user_without_transaction() { renewal_enable_calls=$((renewal_enable_calls + 1)); }
  state_set_expiry() {
    renewal_state_write_calls=$((renewal_state_write_calls + 1))
    renewal_expiry_written="$2"
  }
  finish_managed_operation() { :; }
  log() { :; }

  cmd_renew renew-user 6
  [[ "$(tail -n 1 "$renewal_calls")" == '2000|6' ]]
  [[ "$renewal_expiry_written" == 2027-02-15T10:20:30+0000 ]]
  [[ "$renewal_transaction_started" == true ]]
  [[ "$renewal_state_write_calls" == 1 ]]

  renewal_expires_epoch=500
  renewal_transaction_started=false
  cmd_renew renew-user 12
  [[ "$(tail -n 1 "$renewal_calls")" == '1000|12' ]]
  [[ "$renewal_transaction_started" == true ]]
  [[ "$renewal_state_write_calls" == 2 ]]

  renewal_expires_epoch=2000
  renewal_status=active
  renewal_transaction_started=false
  cmd_renew renew-user -1
  [[ "$(tail -n 1 "$renewal_calls")" == '2000|-1' ]]
  [[ "$renewal_transaction_started" == true ]]
  [[ "$renewal_state_write_calls" == 3 ]]
  [[ "$renewal_prepare_enable_calls" == 0 ]]
  [[ "$renewal_enable_calls" == 0 ]]

  renewal_status=disabled
  renewal_transaction_started=false
  cmd_renew renew-user -1
  [[ "$renewal_transaction_started" == true ]]
  [[ "$renewal_state_write_calls" == 4 ]]
  [[ "$renewal_prepare_enable_calls" == 0 ]]
  [[ "$renewal_enable_calls" == 0 ]]

  renewal_status=active
  renewal_new_expiry_epoch=900
  renewal_transaction_started=false
  renewal_expiry_before_failure="$renewal_expiry_written"
  renewal_write_calls_before_failure="$renewal_state_write_calls"
  if cmd_renew renew-user -2 >"$work/renew-past-failure.out" 2>&1; then
    echo 'expiry reduction into the past should stop before the transaction' >&2
    exit 1
  fi
  [[ "$renewal_transaction_started" == false ]]
  [[ "$renewal_state_write_calls" == "$renewal_write_calls_before_failure" ]]
  [[ "$renewal_expiry_written" == "$renewal_expiry_before_failure" ]]
  grep -Fq '请执行「停用用户」' "$work/renew-past-failure.out"

  renewal_new_expiry_epoch=3000
  renewal_transaction_started=false
  renewal_expiry_before_failure="$renewal_expiry_written"
  renewal_write_calls_before_failure="$renewal_state_write_calls"
  calculate_renewal_expiry() { return 1; }
  if cmd_renew renew-user 2 >"$work/renew-date-failure.out" 2>&1; then
    echo 'renewal date failure should stop before the transaction' >&2
    exit 1
  fi
  [[ "$renewal_transaction_started" == false ]]
  [[ "$renewal_state_write_calls" == "$renewal_write_calls_before_failure" ]]
  [[ "$renewal_expiry_written" == "$renewal_expiry_before_failure" ]]
  grep -Fq '有效期调整未执行' "$work/renew-date-failure.out"
)

# 一条损坏的有效期不得静默放行或阻断后续正常到期用户。
(
  STATE_FILE="$work/expire-invalid-state.json"
  expire_status_calls="$work/expire-status-calls"
  expire_transaction_calls="$work/expire-transaction-calls"
  printf '%s\n' '{"users":[{"name":"invalid-expiry","status":"active","expires_at":"not-a-date"},{"name":"expired-user","status":"active","expires_at":"expired-date"}]}' > "$STATE_FILE"
  : > "$expire_status_calls"
  : > "$expire_transaction_calls"
  date() {
    if [[ "$*" == '+%s' ]]; then
      printf '2000\n'
    elif [[ "${1:-}" == -d && "${2:-}" == expired-date && "${3:-}" == +%s ]]; then
      printf '1000\n'
    else
      return 1
    fi
  }
  log() { printf '%s\n' "$*"; }
  ensure_safe_ssh_for_kernel_restart() { :; }
  start_managed_operation() { printf '%s\n' "$1" >> "$expire_transaction_calls"; }
  run_managed_step() { "$@"; }
  nfuse_account_exists() { return 1; }
  remove_user_inbounds() { :; }
  rebuild_user_splits_if_needed() { :; }
  check_singbox_and_restart() { :; }
  finish_managed_operation() { :; }
  state_set_status() {
    printf '%s:%s\n' "$1" "$2" >> "$expire_status_calls"
    atomic_state_update '(.users[] | select(.name == $name) | .status) = $status' \
      --arg name "$1" --arg status "$2"
  }

  if ! cmd_expire > "$work/expire-invalid-output" 2>&1; then
    echo 'an invalid expiry must not abort later expiry processing' >&2
    exit 1
  fi
  grep -Fq '用户 invalid-expiry 的有效期格式无效，已跳过本次自动到期处理：not-a-date' "$work/expire-invalid-output"
  if grep -Fq 'syntax error' "$work/expire-invalid-output"; then
    echo 'unexpected syntax error in $work/expire-invalid-output' >&2
    exit 1
  fi
  grep -Fxq 'expired-user:disabled' "$expire_status_calls"
  [[ "$(wc -l < "$expire_status_calls" | tr -d ' ')" == 1 ]]
  grep -Fxq 'expire-user:expired-user' "$expire_transaction_calls"
  [[ "$(jq -r '.users[] | select(.name == "invalid-expiry") | .status' "$STATE_FILE")" == active ]]
  [[ "$(jq -r '.users[] | select(.name == "expired-user") | .status' "$STATE_FILE")" == disabled ]]
)
(
  STATE_FILE="$work/unsafe-enable-state.json"
  printf '%s\n' '{"users":[{"name":"unsafe-user","port":22001,"status":"disabled","metered":false,"protocol":"anytls","anytls_password":"secret","tls_sni":"example.com"}],"splits":[]}' > "$STATE_FILE"
  validate_name() { :; }
  user_exists() { :; }
  tag_exists_in_config() { return 1; }
  make_user_inbounds_from_state() { printf '[]\n'; }
  nfuse() {
    if [[ "${1:-}" == list ]]; then
      printf '%s\n' '[{"name":"unsafe-user","tier":"c","used_bytes":0,"ports":[{"start":22001,"end":22001}]}]'
    fi
  }
  ensure_safe_ssh_for_kernel_restart() { return 1; }
  start_managed_operation() { printf 'unexpected\n' > "$work/unsafe-enable-started"; }
  if cmd_enable unsafe-user >"$work/unsafe-enable-output" 2>&1; then
    echo 'unsafe SSH enable must fail instead of reporting success' >&2
    exit 1
  fi
  [[ ! -e "$work/unsafe-enable-started" ]]
  grep -Fq '用户没有启用：unsafe-user' "$work/unsafe-enable-output"
)

# 秘密不得再通过 jq --arg 或 HMAC 外部进程 argv 传入。
if grep -Eq -- '--arg (st_password|ss_password|password) ' src/30-user-runtime.sh; then
  echo 'unexpected --arg (st_password|ss_password|password)  in src/30-user-runtime.sh' >&2
  exit 1
fi
grep -Fq '$ENV.SB_JQ_PASSWORD' src/30-user-runtime.sh
if grep -REn -- '--arg (password|ss_password|shadowtls_password|st_password) |--argjson (u|upstream|new_outbounds|user|split|preset|incoming) "\$' \
  src/20-migration-backup.sh src/30-user-runtime.sh src/40-split-runtime.sh src/70-split-prompts.sh; then
  echo 'secrets must not be passed to jq through command-line arguments' >&2
  exit 1
fi
grep -Fq 'printf '"'"'%s'"'"' "$1" | qrencode -t ' src/30-user-runtime.sh
if grep -En 'qrencode -t [^|]*\$' src/30-user-runtime.sh; then
  echo 'secrets must not be passed to qrencode through command-line arguments' >&2
  exit 1
fi
if grep -Fq 'Authorization: Bearer' src/50-install-update.sh; then
  echo 'unexpected Authorization: Bearer in src/50-install-update.sh' >&2
  exit 1
fi
if grep -Fq 'prompt_github_token' src/50-install-update.sh; then
  echo 'unexpected prompt_github_token in src/50-install-update.sh' >&2
  exit 1
fi
if grep -Fq 'github_curl_with_token' src/50-install-update.sh; then
  echo 'unexpected github_curl_with_token in src/50-install-update.sh' >&2
  exit 1
fi
(
  token_args="$work/github-token-args"
  curl() {
    printf '%s\0' "$@" > "$token_args"
    jq -cn --arg digest "sha256:$(printf 'a%.0s' {1..64})" '{
      tag_name:"v9.9.9",
      assets:[{name:"sb-user-manager.sh",browser_download_url:"https://github.com/Cr0ce11/sb-user-manager-public/releases/download/v9.9.9/sb-user-manager.sh",digest:$digest}]
    }'
  }
  GITHUB_TOKEN='github-secret-token'
  fetch_latest_manager_release
  [[ "$LATEST_MANAGER_VERSION" == 9.9.9 ]]
  [[ "$LATEST_MANAGER_URL" == https://github.com/Cr0ce11/sb-user-manager-public/releases/download/v9.9.9/sb-user-manager.sh ]]
  [[ "$LATEST_MANAGER_SHA256" == "$(printf 'a%.0s' {1..64})" ]]
  if tr '\0' '\n' < "$token_args" | grep -Fq 'github-secret-token'; then
    echo 'unexpected github-secret-token in $token_args' >&2
    exit 1
  fi
  if tr '\0' '\n' < "$token_args" | grep -Fq 'Authorization:'; then
    echo 'unexpected Authorization: in $token_args' >&2
    exit 1
  fi
  grep -Fxq 'https://api.github.com/repos/Cr0ce11/sb-user-manager-public/releases/latest' < <(tr '\0' '\n' < "$token_args")
)
ensure_migration_crypto_dependencies
for migration_entry in create_migration_backup show_migration_backup_details preview_migration_backup restore_migration_backup; do
  (
    dependency_work_started="$work/migration-dependency-${migration_entry}"
    command() {
      if [[ "${1:-}" == -v && "${2:-}" == python3 ]]; then return 1; fi
      builtin command "$@"
    }
    prepare_core() { : > "$dependency_work_started"; }
    select_migration_backup() { : > "$dependency_work_started"; return 1; }
    dependency_output="$("$migration_entry" 2>&1)"
    grep -Fxq '错误：迁移备份功能缺少运行依赖：python3' <<<"$dependency_output"
    grep -Fxq '请返回「系统管理」→「部署与卸载」→「安装或修复环境」完成修复后重试。' <<<"$dependency_output"
    [[ ! -e "$dependency_work_started" ]]
  )
done
grep -Fq 'migration_hmac_sha256_from_env' src/20-migration-backup.sh
grep -Fq 'os.environ["SB_MIGRATION_HMAC_KEY"]' src/20-migration-backup.sh
if grep -Fq 'macopt "hexkey:' src/20-migration-backup.sh; then
  echo 'unexpected macopt "hexkey: in src/20-migration-backup.sh' >&2
  exit 1
fi
printf 'migration-hmac-regression\n' > "$work/migration-hmac-vector"
(
  python3() {
    local argument
    for argument in "$@"; do
      [[ "$argument" != *"$SB_MIGRATION_HMAC_KEY"* ]] || {
        echo 'HMAC key leaked into python3 argv' >&2
        return 1
      }
    done
    command python3 "$@"
  }
  hmac_actual="$(migration_hmac_sha256 "$work/migration-hmac-vector" \
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f')"
  [[ "$hmac_actual" == '361453ea29166db5495c2700f1a22ee23ec5526c0bf4969af75dafbc760a75ad' ]]
)
constant_time_hex_equal "$(printf 'a%.0s' {1..64})" "$(printf 'a%.0s' {1..64})"
if constant_time_hex_equal "$(printf 'a%.0s' {1..64})" "$(printf 'b%.0s' {1..64})"; then
  echo 'constant-time HMAC comparison accepted different values' >&2
  exit 1
fi

(
  getent() {
    [[ "$1" == ahosts ]] || return 2
    case "$2" in
      public-rules.example) printf '%s\n' '93.184.216.34 STREAM public-rules.example';;
      private-rules.example) printf '%s\n' '10.0.0.8 STREAM private-rules.example';;
      *) return 2;;
    esac
  }
  validate_public_rule_set_url https://public-rules.example/rules.srs
  if validate_public_rule_set_url https://private-rules.example/rules.srs ||
     validate_public_rule_set_url https://127.0.0.1/rules.srs ||
     validate_public_rule_set_url https://10.0.0.1/rules.srs ||
     validate_public_rule_set_url 'https://[::ffff:127.0.0.1]/rules.srs' ||
     validate_public_rule_set_url 'https://[::ffff:10.0.0.1]/rules.srs' ||
     validate_public_rule_set_url 'https://[::]/rules.srs' ||
     validate_public_rule_set_url http://public-rules.example/rules.srs; then
    echo 'private or non-HTTPS rule-set URL was accepted' >&2
    exit 1
  fi
)
(
  command() {
    if [[ "${1:-}" == -v && "${2:-}" == getent ]]; then return 1; fi
    builtin command "$@"
  }
  if validate_public_rule_set_url https://public-rules.example/rules.srs; then
    echo 'rule-set URL validation must fail closed when getent is unavailable' >&2
    exit 1
  fi
)

# 用户审计批处理必须保持有效期、协议、启停、多入口和 Nfuse 问题的原有顺序、措辞与计数。
(
  STATE_FILE="$work/audit-batch-state.json"
  SINGBOX_CONFIG="$work/audit-batch-config.json"
  SINGBOX_BIN=audit_batch_singbox
  printf '%s\n' '{
    "schema_version":7,
    "users":[
      {"name":"shadow-active","status":"active","metered":false,"expires_at":"not-a-date","endpoints":[{"protocol":"ss2022","transport":"shadowtls","port":20001}]},
      {"name":"any-disabled","status":"disabled","metered":true,"limit_gib":10,"endpoints":[{"protocol":"anytls","port":20002}]},
      {"name":"direct-active","status":"active","metered":false,"endpoints":[{"protocol":"ss2022","transport":"direct","port":20003}]},
      {"name":"multi","status":"active","metered":false,"endpoints":[{"protocol":"ss2022","transport":"shadowtls","port":20004},{"protocol":"ss2022","transport":"direct","port":20005}]},
      {"name":"any-active","status":"active","metered":false,"endpoints":[{"protocol":"anytls","port":20006}]}
    ],
    "splits":[],
    "outbound_presets":[],
    "rule_presets":[]
  }' > "$STATE_FILE"
  printf '%s\n' '{
    "inbounds":[
      {"tag":"ss-shadow-active"},
      {"type":"shadowsocks","tag":"ss-udp-shadow-active","network":"tcp","listen_port":20001},
      {"tag":"anytls-any-disabled"},
      {"type":"shadowsocks","tag":"ss-direct-active","listen_port":19999,"password":"audit-secret"},
      {"tag":"st-direct-active"},
      {"tag":"ss-udp-direct-active"},
      {"tag":"st-multi"},
      {"tag":"ss-multi"},
      {"type":"shadowsocks","tag":"ss-udp-multi","network":"udp","listen_port":20004},
      {"type":"shadowsocks","tag":"ss-direct-multi","listen_port":20005}
    ],
    "outbounds":[],
    "route":{"rule_set":[],"rules":[]}
  }' > "$SINGBOX_CONFIG"
  apply_skeleton_to_test_config
  audit_batch_nfuse_json='[
    {"name":"any-disabled","tier":"c","ports":[{"start":20002,"end":20002}]},
    {"name":"direct-active","tier":"c","ports":[{"start":21003,"end":21003}]},
    {"name":"multi","tier":"c","ports":[{"start":20004,"end":20004}]},
    {"name":"any-active","tier":"c","ports":[{"start":20006,"end":20006}]}
  ]'
  audit_batch_singbox() {
    [[ "${1:-}" == format && "${2:-}" == -c && "${3:-}" == "$SINGBOX_CONFIG" ]] || return 1
    command cat "$SINGBOX_CONFIG"
  }
  nfuse() {
    [[ "${1:-}" == list && "${2:-}" == --json ]] || return 1
    printf '%s\n' "$audit_batch_nfuse_json"
  }
  audit_output="$work/audit-batch-output"
  audit_expected="$work/audit-batch-expected"
  audit_consistency > "$audit_output"
  [[ "$AUDIT_ISSUES" == 11 && "$AUDIT_REPAIRABLE" == 9 ]]
  cat > "$audit_expected" <<'EOF'

服务与配置检查结果

  [需要处理] 用户 shadow-active 的有效期格式无效（not-a-date）
  [可自动修复] 用户 shadow-active 缺少连接配置（st-shadow-active）
  [可自动修复] 用户 shadow-active 的 UDP 连接配置不正确
  [可自动修复] 用户 shadow-active 缺少流量统计记录
  [可自动修复] 已停用用户 any-disabled 仍保留连接配置（anytls-any-disabled）
  [需要处理] 用户 any-disabled 的流量记录类型不正确（应为 计量）
  [可自动修复] 用户 direct-active 的原生 SS2022 连接配置不正确
  [可自动修复] 用户 direct-active 的原生 SS2022 仍有旧版 ShadowTLS 连接残留
  [可自动修复] 用户 direct-active 的端口 20003 尚未接入流量统计
  [可自动修复] 用户 multi 的端口 20005 尚未接入流量统计
  [可自动修复] 用户 any-active 缺少连接配置（anytls-any-active）

共发现 11 个问题，其中 9 个可以自动修复。
EOF
  cmp -s "$audit_expected" "$audit_output"
)

# 流量记录缺失和类型不正确属于用户本身，双协议用户也只能各报一条。
(
  STATE_FILE="$work/audit-user-nfuse-state.json"
  SINGBOX_CONFIG="$work/audit-user-nfuse-config.json"
  SINGBOX_BIN=audit_user_nfuse_singbox
  printf '%s\n' '{
    "schema_version":7,
    "users":[
      {"name":"dual","status":"active","metered":false,"endpoints":[{"protocol":"ss2022","transport":"shadowtls","port":20101},{"protocol":"anytls","port":20102}]}
    ],
    "splits":[],
    "outbound_presets":[],
    "rule_presets":[]
  }' > "$STATE_FILE"
  printf '%s\n' '{
    "inbounds":[
      {"tag":"st-dual"},
      {"tag":"ss-dual"},
      {"type":"shadowsocks","tag":"ss-udp-dual","network":"udp","listen_port":20101},
      {"tag":"anytls-dual"}
    ],
    "outbounds":[],
    "route":{"rule_set":[],"rules":[]}
  }' > "$SINGBOX_CONFIG"
  apply_skeleton_to_test_config
  audit_user_nfuse_singbox() {
    [[ "${1:-}" == format && "${2:-}" == -c && "${3:-}" == "$SINGBOX_CONFIG" ]] || return 1
    command cat "$SINGBOX_CONFIG"
  }
  nfuse() {
    [[ "${1:-}" == list && "${2:-}" == --json ]] || return 1
    printf '%s\n' '[]'
  }
  audit_consistency > "$work/audit-user-missing-output"
  [[ "$AUDIT_ISSUES" == 1 && "$AUDIT_REPAIRABLE" == 1 ]]
  [[ "$(grep -Fc '缺少流量统计记录' "$work/audit-user-missing-output")" == 1 ]]
  nfuse() {
    [[ "${1:-}" == list && "${2:-}" == --json ]] || return 1
    printf '%s\n' '[{"name":"dual","tier":"a","ports":[{"start":20101,"end":20102}]}]'
  }
  audit_consistency > "$work/audit-user-tier-output"
  [[ "$AUDIT_ISSUES" == 1 && "$AUDIT_REPAIRABLE" == 0 ]]
  [[ "$(grep -Fc '流量记录类型不正确' "$work/audit-user-tier-output")" == 1 ]]
  # 端口问题仍然依端点判定，两个端点各报一条
  nfuse() {
    [[ "${1:-}" == list && "${2:-}" == --json ]] || return 1
    printf '%s\n' '[{"name":"dual","tier":"c","ports":[]}]'
  }
  audit_consistency > "$work/audit-user-port-output"
  [[ "$AUDIT_ISSUES" == 2 && "$AUDIT_REPAIRABLE" == 2 ]]
  grep -Fq '[可自动修复] 用户 dual 的端口 20101 尚未接入流量统计' "$work/audit-user-port-output"
  grep -Fq '[可自动修复] 用户 dual 的端口 20102 尚未接入流量统计' "$work/audit-user-port-output"
)

# 已停用用户的专属分流本就不会写入运行配置：不能报缺失，但残留规则仍要检出。
(
  STATE_FILE="$work/audit-disabled-split-state.json"
  SINGBOX_CONFIG="$work/audit-disabled-split-config.json"
  SINGBOX_BIN=audit_disabled_split_singbox
  printf '%s\n' '{
    "schema_version":7,
    "users":[
      {"name":"paused","status":"disabled","metered":false,"endpoints":[{"protocol":"anytls","port":20201}]}
    ],
    "splits":[
      {"name":"AI","status":"active","scope":"user","user":"paused","url":"https://rules.example/ai.srs","rule_set_tag":"AI","outbound_tag":"Hinet"}
    ],
    "outbound_presets":[],
    "rule_presets":[]
  }' > "$STATE_FILE"
  printf '%s\n' '{"inbounds":[],"outbounds":[],"route":{"rule_set":[],"rules":[]}}' > "$SINGBOX_CONFIG"
  apply_skeleton_to_test_config
  audit_disabled_split_singbox() {
    [[ "${1:-}" == format && "${2:-}" == -c && "${3:-}" == "$SINGBOX_CONFIG" ]] || return 1
    command cat "$SINGBOX_CONFIG"
  }
  nfuse() {
    [[ "${1:-}" == list && "${2:-}" == --json ]] || return 1
    printf '%s\n' '[{"name":"paused","tier":"c","ports":[{"start":20201,"end":20201}]}]'
  }
  audit_consistency > "$work/audit-disabled-split-output"
  [[ "$AUDIT_ISSUES" == 0 && "$AUDIT_REPAIRABLE" == 0 ]]
  grep -Fq '一切正常' "$work/audit-disabled-split-output"
  printf '%s\n' '{"inbounds":[],"outbounds":[{"tag":"Hinet"}],
    "route":{"rule_set":[{"tag":"AI","url":"https://rules.example/ai.srs"}],
      "rules":[{"rule_set":"AI","outbound":"Hinet","inbound":["anytls-paused"]}]}}' > "$SINGBOX_CONFIG"
  apply_skeleton_to_test_config
  audit_consistency > "$work/audit-disabled-split-stale-output"
  [[ "$AUDIT_ISSUES" == 1 && "$AUDIT_REPAIRABLE" == 1 ]]
  grep -Fq '[可自动修复] 分流 AI 指定的用户 paused 已停用，但连接规则仍在生效' "$work/audit-disabled-split-stale-output"
)

# 骨架检查：配置缺少 log / dns / route.final / experimental 这些只在装机或接管时
# 写入、此后从不复查的段落时，审计必须报出来。这是上游废弃字段后存量配置悄悄
# 过期的唯一可见信号。
(
  STATE_FILE="$work/audit-skeleton-state.json"
  SINGBOX_CONFIG="$work/audit-skeleton-config.json"
  SINGBOX_BIN=audit_skeleton_singbox
  audit_skeleton_singbox() {
    case "${1:-}" in
      format) command jq . "$3";;
      *) return 64;;
    esac
  }
  nfuse() {
    [[ "${1:-}" == list && "${2:-}" == --json ]] || return 1
    printf '%s\n' '[]'
  }
  printf '%s\n' '{"schema_version":7,"users":[],"splits":[]}' > "$STATE_FILE"
  # 骨架完整：对照组，必须一个问题都不报。缺了这一组就分不清检查是有效还是恒真。
  # 这里刻意删掉空容器，因为比对基准是 sing-box format 的输出，而它会把空数组
  # 整个省略。这同时是 Issue #135 的回归用例：修复前，一台没有配分流的服务器
  # 会被误报缺少 route.rules 与 route.rule_set。
  command jq -cn "{} | $SINGBOX_SKELETON_ENSURE_PROGRAM
    | del(.inbounds) | del(.route.rules) | del(.route.rule_set)" > "$SINGBOX_CONFIG"
  audit_consistency > "$work/audit-skeleton-complete-output"
  if [[ "$AUDIT_ISSUES" != 0 ]]; then
    printf '骨架完整时不得报出问题，实际报了 %s 个\n' "$AUDIT_ISSUES" >&2
    cat "$work/audit-skeleton-complete-output" >&2
    exit 1
  fi
  # 骨架缺失：四个段落全缺，必须逐项报出
  printf '%s\n' '{"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}]}' > "$SINGBOX_CONFIG"
  audit_consistency > "$work/audit-skeleton-missing-output"
  if [[ "$AUDIT_ISSUES" != 4 ]]; then
    printf '骨架缺 4 项时应报 4 个问题，实际 %s 个\n' "$AUDIT_ISSUES" >&2
    cat "$work/audit-skeleton-missing-output" >&2
    exit 1
  fi
  for skeleton_expected in log dns route experimental; do
    if ! grep -Fq "运行配置缺少骨架项 $skeleton_expected" "$work/audit-skeleton-missing-output"; then
      printf '审计没有报出缺失的骨架项 %s\n' "$skeleton_expected" >&2
      exit 1
    fi
  done
  # 只缺一个子项时应精确到该子项，而不是笼统报出整段
  command jq -cn "{} | $SINGBOX_SKELETON_ENSURE_PROGRAM
    | del(.inbounds) | del(.route.rules) | del(.route.rule_set)" \
    | command jq -c 'del(.route.final)' > "$SINGBOX_CONFIG"
  audit_consistency > "$work/audit-skeleton-partial-output"
  if [[ "$AUDIT_ISSUES" != 1 ]]; then
    printf '只缺 route.final 时应报 1 个问题，实际 %s 个\n' "$AUDIT_ISSUES" >&2
    exit 1
  fi
  grep -Fq '运行配置缺少骨架项 route.final' "$work/audit-skeleton-partial-output"
)

# 50 个 ShadowTLS 用户的一致性检查固定批量处理；重构前该夹具会启动 409 次 jq。
(
  STATE_FILE="$work/audit-batch-count-state.json"
  SINGBOX_CONFIG="$work/audit-batch-count-config.json"
  SINGBOX_BIN=audit_batch_count_singbox
  command jq -n '{
    schema_version:7,
    users:[range(0; 50) as $index | {
      name:("user" + ($index | tostring)),status:"active",metered:false,
      endpoints:[{protocol:"ss2022",transport:"shadowtls",port:(20000 + $index)}]
    }],
    splits:[],outbound_presets:[],rule_presets:[]
  }' > "$STATE_FILE"
  command jq -n '{
    inbounds:[range(0; 50) as $index |
      ("user" + ($index | tostring)) as $name | (20000 + $index) as $port |
      {tag:("st-" + $name)},
      {tag:("ss-" + $name)},
      {type:"shadowsocks",tag:("ss-udp-" + $name),network:"udp",listen_port:$port,password:"audit-secret"}],
    outbounds:[],route:{rule_set:[],rules:[]}
  }' > "$SINGBOX_CONFIG"
  apply_skeleton_to_test_config
  audit_batch_count_nfuse="$(command jq -cn '[range(0; 50) as $index | {
    name:("user" + ($index | tostring)),tier:"c",
    ports:[{start:(20000 + $index),end:(20000 + $index)}]
  }]')"
  audit_batch_count_singbox() {
    [[ "${1:-}" == format && "${2:-}" == -c && "${3:-}" == "$SINGBOX_CONFIG" ]] || return 1
    command cat "$SINGBOX_CONFIG"
  }
  nfuse() {
    [[ "${1:-}" == list && "${2:-}" == --json ]] || return 1
    printf '%s\n' "$audit_batch_count_nfuse"
  }
  audit_jq_calls="$work/audit-batch-jq.calls"
  audit_jq_args="$work/audit-batch-jq.args"
  : > "$audit_jq_calls"
  : > "$audit_jq_args"
  jq() {
    printf 'jq\n' >> "$audit_jq_calls"
    printf '%s\0' "$@" >> "$audit_jq_args"
    command jq "$@"
  }
  audit_consistency > "$work/audit-batch-count-output"
  [[ "$AUDIT_ISSUES" == 0 && "$AUDIT_REPAIRABLE" == 0 ]]
  grep -Fq '一切正常' "$work/audit-batch-count-output"
  # 9 次是原有批量化后的次数，第 10 次是新增的骨架检查——它与 src/05-kernel.sh
  # 共用同一份补齐程序，把「配置缺哪些骨架项」一次算出，不逐项试探。
  [[ "$(wc -l < "$audit_jq_calls" | tr -d ' ')" == 10 ]]
  if tr '\0' '\n' < "$audit_jq_args" | grep -Fq 'audit-secret'; then
    echo 'unexpected audit-secret in $audit_jq_args' >&2
    exit 1
  fi
)

printf '%s\n' '{"schema_version":3,"users":[{"name":"test","status":"disabled","port":10001,"metered":true,"limit_gib":1},{"name":"crocell","status":"active","port":10000,"metered":false},{"name":"test2","status":"active","port":22547,"metered":true,"limit_gib":2}],"splits":[{"name":"AI","status":"active","scope":"user","user":"crocell","rule_set_tag":"AI","outbound_tag":"Hinet"}]}' > "$STATE_FILE"
printf '%s\n' '{"inbounds":[{"tag":"st-crocell"},{"tag":"ss-crocell"},{"type":"shadowsocks","tag":"ss-udp-crocell","network":"udp","listen_port":10000},{"tag":"st-test2"},{"tag":"ss-test2"},{"type":"shadowsocks","tag":"ss-udp-test2","network":"udp","listen_port":22547}],"outbounds":[{"tag":"Hinet"}],"route":{"rule_set":[{"tag":"AI"}],"rules":[{"rule_set":"AI","outbound":"Hinet","inbound":["st-crocell","ss-crocell","ss-udp-crocell"]}]}}' > "$SINGBOX_CONFIG"
apply_skeleton_to_test_config
nfuse() {
  if [[ "$1" == list && "$2" == --json ]]; then
    printf '%s\n' '[{"name":"test","tier":"a","ports":[{"start":10001,"end":10001}]},{"name":"crocell","tier":"c","ports":[{"start":10000,"end":10000}]},{"name":"test2","tier":"a","ports":[{"start":22547,"end":22547}]}]'
    return 0
  fi
  return 0
}
audit_consistency > "$work/audit-output"
[[ "$AUDIT_ISSUES" == 0 ]]
grep -Fq '一切正常' "$work/audit-output"
jq '(.users[] | select(.name == "test2") | .expires_at) = "not-a-date"' "$STATE_FILE" > "$STATE_FILE.tmp"
mv "$STATE_FILE.tmp" "$STATE_FILE"
audit_consistency > "$work/audit-invalid-expiry-output"
[[ "$AUDIT_ISSUES" == 1 && "$AUDIT_REPAIRABLE" == 0 ]]
grep -Fq '[需要处理] 用户 test2 的有效期格式无效（not-a-date）' "$work/audit-invalid-expiry-output"
jq '(.users[] | select(.name == "test2") | .expires_at) = null' "$STATE_FILE" > "$STATE_FILE.tmp"
mv "$STATE_FILE.tmp" "$STATE_FILE"
jq '(.inbounds[] | select(.tag == "ss-udp-crocell") | .network) = "tcp"' "$SINGBOX_CONFIG" > "$SINGBOX_CONFIG.tmp"
mv "$SINGBOX_CONFIG.tmp" "$SINGBOX_CONFIG"
audit_consistency > "$work/audit-udp-invalid-output"
[[ "$AUDIT_ISSUES" == 1 && "$AUDIT_REPAIRABLE" == 1 ]]
grep -Fq 'UDP 连接配置不正确' "$work/audit-udp-invalid-output"

printf '%s\n' '{"schema_version":6,"users":[{"name":"direct-audit","status":"active","port":20044,"protocol":"ss2022","transport":"direct","metered":false,"usage_offset_bytes":0,"ss2022_password":"direct-secret","method":"2022-blake3-aes-128-gcm","endpoints":[{"protocol":"ss2022","transport":"direct","port":20044,"ss2022_password":"direct-secret","method":"2022-blake3-aes-128-gcm"}]}],"splits":[],"outbound_presets":[],"rule_presets":[]}' > "$STATE_FILE"
printf '%s\n' '{"inbounds":[{"type":"shadowsocks","tag":"ss-direct-audit","listen":"::","listen_port":20044,"method":"2022-blake3-aes-128-gcm","password":"direct-secret"},{"type":"shadowtls","tag":"st-direct-audit"},{"type":"shadowsocks","tag":"ss-udp-direct-audit","network":"udp","listen_port":20044}],"outbounds":[],"route":{"rule_set":[],"rules":[]}}' > "$SINGBOX_CONFIG"
apply_skeleton_to_test_config
nfuse() {
  if [[ "$1" == list && "$2" == --json ]]; then
    printf '%s\n' '[{"name":"direct-audit","tier":"c","ports":[{"start":20044,"end":20044}]}]'
    return 0
  fi
  return 0
}
audit_consistency > "$work/audit-direct-stale-output"
[[ "$AUDIT_ISSUES" == 1 && "$AUDIT_REPAIRABLE" == 1 ]]
grep -Fq '原生 SS2022 仍有旧版 ShadowTLS 连接残留' "$work/audit-direct-stale-output"

python3 tests/test-interactive.py

# ============================================================
# 非交互只读入口
# ============================================================
# 只读入口的分发位置很敏感：必须早于 root 检查与接管恢复（recover_manager_handoff 会取锁
# 并还原文件），又不能让未知参数跟着被放行。以下断言把这两头都钉住。
readonly_main_body="$(declare -f main | tr -s '[:space:]' ' ')"
# 必须是精确匹配的 case 分支：写成 status* 之类会把未知参数一起放行
if ! grep -Fq 'status | users)' <<<"$readonly_main_body"; then
  echo 'main must dispatch the read-only subcommands with an exact-match case arm' >&2
  exit 1
fi
if ! grep -Fq 'run_readonly_command "$@"' <<<"$readonly_main_body"; then
  echo 'main must hand the read-only subcommands to run_readonly_command' >&2
  exit 1
fi
# 分发必须出现在 root 检查之前，否则非 root 会拿到退出码 1 而不是 3
readonly_dispatch_pos="$(awk 'index($0, "run_readonly_command") {print NR; exit}' <<<"$(declare -f main)")"
readonly_root_pos="$(awk 'index($0, "必须使用 root 运行") {print NR; exit}' <<<"$(declare -f main)")"
if [[ -z "$readonly_dispatch_pos" || -z "$readonly_root_pos" ]] ||
   ((readonly_dispatch_pos >= readonly_root_pos)); then
  echo 'the read-only dispatch must come before the root check and handoff recovery' >&2
  exit 1
fi
# 未知参数不得被只读分发吞掉：main 里仍须保留拒绝分支
if ! grep -Fq '本脚本采用交互方式，请直接运行且不要添加参数' <<<"$readonly_main_body"; then
  echo 'main must keep rejecting unknown arguments' >&2
  exit 1
fi

# 只读路径绝不能触碰会改状态的函数。这条比任何计时测试都可靠：没取锁就不可能被锁阻塞。
# 只看代码不看注释：注释里为解释原因会提到这些函数名，那不是调用
readonly_section="$(sed -n '/^# 非交互只读入口$/,$p' src/60-operations-diagnostics.sh | sed 's/#.*//')"
for readonly_forbidden in prepare_core acquire_operation_lock recover_pending_transaction \
  init_state atomic_state_update start_managed_operation finish_managed_operation; do
  if grep -Fq "$readonly_forbidden" <<<"$readonly_section"; then
    echo "the read-only section must not call ${readonly_forbidden}" >&2
    exit 1
  fi
done

(
  readonly_work="$work/readonly"
  mkdir -p "$readonly_work"
  STATE_FILE="$readonly_work/state.json"
  SINGBOX_CONFIG="$readonly_work/config.json"
  CONF_FILE="$readonly_work/manager.conf"
  NFUSE_SOCKET="$readonly_work/nfuse.sock"
  SINGBOX_BIN="$readonly_work/fake-singbox"
  MANAGER_HANDOFF_JOURNAL="$readonly_work/handoff.json"
  TRANSACTION_JOURNAL="$readonly_work/transaction.json"
  # 状态里刻意放入密码、SNI、加密方式和端口，用来核对它们绝不进入输出
  cat > "$STATE_FILE" <<'READONLYSTATE'
{"schema_version":7,"users":[
 {"name":"ro-metered","port":24101,"protocol":"anytls","status":"active","metered":true,"limit_gib":100,"billing_anchor":5,"expires_at":"2026-09-01T00:00:00+0800","usage_offset_bytes":0,"created_at":"2026-01-01T00:00:00+08:00","anytls_password":"ro-secret-any","tls_sni":"ro.private.example","endpoints":[{"protocol":"anytls","port":24101,"anytls_password":"ro-secret-any","tls_sni":"ro.private.example"}]},
 {"name":"ro-dual","port":24102,"protocol":"ss2022","transport":"direct","status":"active","metered":true,"limit_gib":50,"billing_anchor":5,"expires_at":null,"usage_offset_bytes":0,"created_at":"2026-01-01T00:00:00+08:00","ss2022_password":"ro-secret-ss","method":"2022-blake3-aes-128-gcm","endpoints":[{"protocol":"ss2022","transport":"direct","port":24102,"ss2022_password":"ro-secret-ss","method":"2022-blake3-aes-128-gcm"},{"protocol":"anytls","port":24103,"anytls_password":"ro-secret-any2","tls_sni":"dual.private.example"}]},
 {"name":"ro-off","port":24104,"protocol":"ss2022","transport":"direct","status":"disabled","metered":false,"limit_gib":null,"billing_anchor":null,"expires_at":null,"usage_offset_bytes":0,"created_at":"2026-01-01T00:00:00+08:00","ss2022_password":"ro-secret-off","method":"2022-blake3-aes-128-gcm","endpoints":[{"protocol":"ss2022","transport":"direct","port":24104,"ss2022_password":"ro-secret-off","method":"2022-blake3-aes-128-gcm"}]}],
 "splits":[],"outbound_presets":[],"rule_presets":[]}
READONLYSTATE
  printf '%s\n' '{"inbounds":[],"outbounds":[],"route":{"rules":[]}}' > "$SINGBOX_CONFIG"
  printf '%s\n' 'placeholder' > "$CONF_FILE"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SINGBOX_BIN"
  chmod +x "$SINGBOX_BIN"
  # readonly_prepare 只检查配置可读与依赖存在，这里跳过真实的 load_runtime_config
  load_runtime_config() { :; }
  systemctl() { printf 'active\n'; }
  nfuse() {
    [[ "${1:-}" == list ]] || return 0
    cat <<'READONLYNFUSE'
[{"id":1,"name":"ro-metered","tier":"a","limit_gib":100,"limit_bytes":107374182400,"used_bytes":103079215104,"ports":[{"id":1,"start":24101,"end":24101}]},
 {"id":2,"name":"ro-dual","tier":"a","limit_gib":50,"limit_bytes":53687091200,"used_bytes":1073741824,"ports":[{"id":2,"start":24102,"end":24103}]},
 {"id":3,"name":"ro-off","tier":"c","limit_gib":0,"limit_bytes":0,"used_bytes":0,"ports":[{"id":3,"start":24104,"end":24104}]}]
READONLYNFUSE
  }
  audit_consistency() { AUDIT_ISSUES=0; AUDIT_REPAIRABLE=0; return 0; }
  # 到期解析依赖 GNU date，开发机上不一定有；这里桩掉以便在任何平台上验证本文件自己的
  # 天数与阈值逻辑，真实解析由 parse_expiry_epoch 的既有用例与 Debian CI 覆盖。
  parse_expiry_epoch() { printf '%s\n' "$(( $(date +%s) + 3 * 86400 ))"; }
  : > "$NFUSE_SOCKET"
  readonly_socket_is_real=false
  if python3 - "$NFUSE_SOCKET" <<'READONLYSOCK' 2>/dev/null
import os, socket, sys
path = sys.argv[1]
os.path.exists(path) and os.unlink(path)
socket.socket(socket.AF_UNIX).bind(path)
READONLYSOCK
  then readonly_socket_is_real=true; fi

  # --- 凭据泄露核对：这是本入口最重要的约束 ---
  readonly_all_output="$( { cmd_readonly_users; cmd_readonly_users --json; \
    cmd_readonly_status || true; cmd_readonly_status --json || true; } 2>&1 )"
  # 只用字符串搜真正的秘密与可连接链接。端口号故意不放进这个列表：它会作为数字子串
  # 出现在流量字节数里（例如 5241010000 含 24101），那是误报；端口的缺席由下面的
  # 字段集合断言保证，比子串搜索更严也不会误报。
  for readonly_secret in ro-secret-any ro-secret-ss ro-secret-any2 ro-secret-off \
    ro.private.example dual.private.example 2022-blake3 \
    'anytls://' 'ss://'; do
    if grep -Fq "$readonly_secret" <<<"$readonly_all_output"; then
      echo "read-only output must never contain credentials or connectable details: ${readonly_secret}" >&2
      exit 1
    fi
  done
  # 非 TTY 输出不得带终端转义
  if printf '%s' "$readonly_all_output" | grep -q $'\033'; then
    echo 'read-only output must not contain terminal escapes' >&2
    exit 1
  fi

  # 人读输出里的服务状态必须是中文：菜单侧早有中文映射，只读入口不得回落到
  # systemd 的英文原文（曾经出现过 "sing-box.service failed" 与中文混排）。
  # 两处共用 service_state_label，避免日后各说一套。
  if [[ "$(service_state_label failed)" != 启动失败 ]] ||
     [[ "$(service_state_label inactive)" != 未运行 ]] ||
     [[ "$(service_state_label active)" != 运行中 ]]; then
    echo 'service_state_label must render systemd states in Chinese' >&2
    exit 1
  fi
  if ! grep -Fq 'service_state_label' <<<"$(declare -f show_service_status)"; then
    echo 'show_service_status must reuse service_state_label so the two cannot drift' >&2
    exit 1
  fi
  (
    systemctl() { [[ "${2:-}" != sing-box.service ]] && printf 'active\n' || printf 'failed\n'; }
    readonly_state_out="$(cmd_readonly_status || true)"
    if ! grep -Fq 'sing-box.service 启动失败' <<<"$readonly_state_out"; then
      echo 'read-only status must show the Chinese service state' >&2
      printf '%s\n' "$readonly_state_out" >&2
      exit 1
    fi
    if grep -Eq 'sing-box\.service (failed|inactive|activating)' <<<"$readonly_state_out"; then
      echo 'read-only status must not fall back to the raw systemd state' >&2
      exit 1
    fi
    # --json 保留原始状态作为机器契约
    jq -e '[.services[] | select(.name == "sing-box.service") | .state] == ["failed"]' \
      <<<"$(cmd_readonly_status --json || true)" >/dev/null
    # systemctl 返回空时必须归一为 unknown。断言要钉 --json 里的原始状态：
    # 制表符分隔在中间字段为空时会折叠，读取端错位后中文说法会跑到 state 位上，
    # 只看人读输出里有没有「未知」是抓不到这个错位的。
    systemctl() { printf '\n'; }
    if ! jq -e '[.services[] | .state] | unique == ["unknown"]' \
        <<<"$(cmd_readonly_status --json || true)" >/dev/null; then
      echo 'an empty systemd state must be normalised to unknown in the JSON contract' >&2
      jq -c '.services' <<<"$(cmd_readonly_status --json || true)" >&2
      exit 1
    fi
    if ! grep -Fq '未知（unknown）' <<<"$(cmd_readonly_status || true)"; then
      echo 'an empty systemd state must read as 未知 for humans' >&2
      exit 1
    fi
  )

  # --- users ---
  readonly_users_json="$(cmd_readonly_users --json)"
  jq -e 'has("generated_at") and (.users | length) == 3' <<<"$readonly_users_json" >/dev/null
  jq -e '.users[] | select(.name == "ro-dual") | .protocols == ["ss2022","anytls"]' <<<"$readonly_users_json" >/dev/null
  jq -e '.users[] | select(.name == "ro-off") | .enabled == false and .quota_bytes == null' <<<"$readonly_users_json" >/dev/null
  jq -e '.users[] | select(.name == "ro-metered") | .used_bytes == 103079215104 and .remaining_bytes == 4294967296' <<<"$readonly_users_json" >/dev/null
  # 字段集合必须逐字相符：多一个字段就说明有东西溜了进来（端口、密码、SNI、加密方式…）
  if ! jq -e '([.users[] | keys] | flatten | unique) ==
      ["enabled","expires_at","metered","name","protocols","quota_bytes","remaining_bytes","status","used_bytes"]' \
      <<<"$readonly_users_json" >/dev/null; then
    echo 'read-only user records must expose exactly the non-sensitive field set' >&2
    jq -c '[.users[] | keys] | flatten | unique' <<<"$readonly_users_json" >&2
    exit 1
  fi
  jq -e '(.users | length) == 1 and .users[0].name == "ro-dual"' \
    <<<"$(cmd_readonly_users --json --name ro-dual)" >/dev/null
  readonly_rc=0
  # readonly_fail 用 exit（对命令行入口是对的），因此失败路径必须放进子壳才抓得到退出码
  ( cmd_readonly_users --name nobody ) >/dev/null 2>&1 || readonly_rc=$?
  if [[ "$readonly_rc" != 3 ]]; then
    echo "an unknown user name must exit 3, got ${readonly_rc}" >&2
    exit 1
  fi
  readonly_rc=0
  ( cmd_readonly_users --bogus ) >/dev/null 2>&1 || readonly_rc=$?
  if [[ "$readonly_rc" != 3 ]]; then
    echo "an unrecognised read-only flag must exit 3, got ${readonly_rc}" >&2
    exit 1
  fi

  # --- status 的三档退出码 ---
  if [[ "$readonly_socket_is_real" == true ]]; then
    # 干净环境：唯一的提醒来自 3 天后到期与 96% 配额，因此应为 1
    readonly_rc=0
    readonly_status_json="$(cmd_readonly_status --json)" || readonly_rc=$?
    if [[ "$readonly_rc" != 1 ]]; then
      echo "a healthy environment with an expiring user must exit 1, got ${readonly_rc}" >&2
      exit 1
    fi
    jq -e '.conclusion == "notice" and .exit_code == 1' <<<"$readonly_status_json" >/dev/null
    jq -e '[.notices[] | select(test("将在 3 天后到期"))] | length == 1' <<<"$readonly_status_json" >/dev/null
    jq -e '[.notices[] | select(test("已用 96%"))] | length == 1' <<<"$readonly_status_json" >/dev/null
    jq -e '.users == {total:3, active:2, disabled:1}' <<<"$readonly_status_json" >/dev/null
    # 服务异常必须升级为 2
    readonly_rc=0
    systemctl() { [[ "${2:-}" != sing-box.service ]] && printf 'active\n' || printf 'failed\n'; }
    cmd_readonly_status --json >/dev/null 2>&1 || readonly_rc=$?
    if [[ "$readonly_rc" != 2 ]]; then
      echo "a failed service must exit 2, got ${readonly_rc}" >&2
      exit 1
    fi
    systemctl() { printf 'active\n'; }
    # 需人工处理的一致性问题必须升级为 2；全部可自动修复则只算提醒
    readonly_rc=0
    audit_consistency() { AUDIT_ISSUES=3; AUDIT_REPAIRABLE=1; return 0; }
    cmd_readonly_status --json >/dev/null 2>&1 || readonly_rc=$?
    if [[ "$readonly_rc" != 2 ]]; then
      echo "consistency issues needing manual work must exit 2, got ${readonly_rc}" >&2
      exit 1
    fi
    readonly_rc=0
    audit_consistency() { AUDIT_ISSUES=2; AUDIT_REPAIRABLE=2; return 0; }
    readonly_status_json="$(cmd_readonly_status --json)" || readonly_rc=$?
    if [[ "$readonly_rc" != 1 ]]; then
      echo "fully repairable issues must stay a notice, got ${readonly_rc}" >&2
      exit 1
    fi
    jq -e '[.notices[] | select(test("均可在菜单中自动修复"))] | length == 1' <<<"$readonly_status_json" >/dev/null
    audit_consistency() { AUDIT_ISSUES=0; AUDIT_REPAIRABLE=0; return 0; }
    # 未完成的恢复记录必须被如实报出（只读入口不执行恢复）
    printf '%s\n' '{"backup_stamp":"20260101-000000-1.1"}' > "$TRANSACTION_JOURNAL"
    readonly_status_json="$(cmd_readonly_status --json)" || true
    jq -e '[.notices[] | select(test("未完成的操作恢复记录"))] | length == 1' <<<"$readonly_status_json" >/dev/null
    rm -f -- "$TRANSACTION_JOURNAL"
  else
    printf '%s\n' 'read-only status tiers skipped: unix socket fixture unavailable' >&2
  fi

  # --- 工具自身出错一律退出 3 ---
  readonly_rc=0
  ( CONF_FILE="$readonly_work/missing.conf"; cmd_readonly_status ) >/dev/null 2>&1 || readonly_rc=$?
  if [[ "$readonly_rc" != 3 ]]; then
    echo "a missing manager config must exit 3, got ${readonly_rc}" >&2
    exit 1
  fi
)


# ============================================================
# sing-box Listable 规范化：单元素 inbound 会被 format 塌成裸标量
# ============================================================
# 生产环境（Air）实测：写入 "inbound":["anytls-share"]，`sing-box format` 读回
# "inbound":"anytls-share"。此前的比对直接对它做集合运算，jq 报
# 「array and string cannot be subtracted」；而调用点写成 `if ! jq` / `|| return 1`，
# 崩溃被当成「配置不符」，于是误报「分流尚未覆盖用户的全部连接」，并触发一次
# 不必要的配置重建与 sing-box 重启。只有单一入口的用户会踩到 —— 而那是最常见的配置。
(
  listable_work="$work/listable"
  mkdir -p "$listable_work"
  SINGBOX_CONFIG="$listable_work/config.json"
  SINGBOX_BIN="$listable_work/fake-singbox"
  STATE_FILE="$listable_work/state.json"
  # 假 sing-box 复现真实的塌陷行为：单元素 inbound 输出为裸标量
  cat > "$SINGBOX_BIN" <<'LISTABLEBIN'
#!/usr/bin/env bash
if [[ "${1:-}" == format ]]; then
  jq -c '.route.rules |= map(
    if has("inbound") and ((.inbound | type) == "array") and ((.inbound | length) == 1)
    then .inbound = .inbound[0] else . end)' "$3"
else
  exit 0
fi
LISTABLEBIN
  chmod +x "$SINGBOX_BIN"
  cat > "$SINGBOX_CONFIG" <<'LISTABLECFG'
{"inbounds":[{"tag":"anytls-share","type":"anytls"}],
 "outbounds":[{"tag":"mpo-share","type":"anytls"}],
 "route":{"rule_set":[{"tag":"mpr-share","type":"remote"}],
 "rules":[{"rule_set":"mpr-share","action":"route","outbound":"mpo-share","inbound":["anytls-share"]},
          {"rule_set":"mpr-all","action":"route","outbound":"mpo-all"}]}}
LISTABLECFG

  # 先确认夹具真的复现了塌陷，否则这条测试测不到任何东西
  if [[ "$("$SINGBOX_BIN" format -c "$SINGBOX_CONFIG" | jq -r '.route.rules[0].inbound | type')" != string ]]; then
    echo 'the fake sing-box must reproduce the Listable collapse for a single-element inbound' >&2
    exit 1
  fi

  listable_config="$(singbox_config_for_comparison)"
  if [[ "$(jq -r '.route.rules[0].inbound | type' <<<"$listable_config")" != array ]]; then
    echo 'singbox_config_for_comparison must restore a collapsed inbound to an array' >&2
    jq -c '.route.rules' <<<"$listable_config" >&2
    exit 1
  fi
  # 本来没有 inbound 的规则不得被塞进这个字段
  if jq -e '.route.rules[1] | has("inbound")' <<<"$listable_config" >/dev/null; then
    echo 'normalisation must not invent an inbound field on rules that had none' >&2
    exit 1
  fi
  # 还原之后集合运算必须能跑通，不再崩溃
  if ! jq -e --argjson expected '["anytls-share"]' '
      .route.rules[] | select(.rule_set == "mpr-share" and
        ($expected - (.inbound // []) | length) == 0)' <<<"$listable_config" >/dev/null; then
    echo 'the coverage comparison must succeed once inbound is an array' >&2
    exit 1
  fi
  # 未还原时确实会崩（证明这条测试盯的是真问题，而不是恒真断言）
  listable_raw="$("$SINGBOX_BIN" format -c "$SINGBOX_CONFIG")"
  listable_rc=0
  jq -e --argjson expected '["anytls-share"]' '
    .route.rules[] | select(.rule_set == "mpr-share" and
      ($expected - (.inbound // []) | length) == 0)' <<<"$listable_raw" >/dev/null 2>&1 || listable_rc=$?
  if [[ "$listable_rc" == 0 ]]; then
    echo 'the un-normalised comparison was expected to fail; the fixture no longer reproduces the bug' >&2
    exit 1
  fi
)
# 两处比对必须都用共用的还原规则，不得各写一套、也不得直接拿 format 的原始输出比对。
# audit_consistency 把还原折进既有的类型校验调用（它的 jq 调用次数受性能门禁看守），
# 因此这里认「引用了共用过滤器常量」，而不是硬要求函数名。
if ! grep -Fq 'singbox_config_for_comparison' <<<"$(declare -f shared_preset_runtime_is_current)"; then
  echo 'shared_preset_runtime_is_current must read the running config through singbox_config_for_comparison' >&2
  exit 1
fi
# 两处比对都必须经适配层那份按内核分派的规范化程序，不能各写一套。
if ! grep -Fq 'kernel_config_normalise_program' <<<"$(declare -f audit_consistency)"; then
  echo 'audit_consistency must normalise the running config through kernel_config_normalise_program' >&2
  exit 1
fi
if ! grep -Fq 'kernel_config_normalise_program' <<<"$(declare -f singbox_config_for_comparison)"; then
  echo 'singbox_config_for_comparison must use the shared normalisation filter' >&2
  exit 1
fi
# 分派本身两个内核都要给出：sing-box 那一支要还原被 format 塌成标量的 inbound，
# mihomo 那一支只做类型校验——照搬 sing-box 那一段过去没有意义。
if ! grep -Fq 'SINGBOX_CONFIG_NORMALISE_PROGRAM' <<<"$(declare -f kernel_config_normalise_program)" ||
   ! grep -Fq 'MIHOMO_CONFIG_NORMALISE_PROGRAM' <<<"$(declare -f kernel_config_normalise_program)"; then
  echo 'kernel_config_normalise_program must dispatch to both kernels' >&2
  exit 1
fi

# 密钥生成已脱离代理内核改用 openssl。这里锁定输出规格：参数是随机字节数，
# 输出是带填充的标准 base64 且不含换行。规格弄错会让新建用户的密钥强度与
# 存量不等价，而这在界面上完全看不出来。
(
  assert_key_shape() {
    local label="$1" value="$2" want_chars="$3" want_bytes="$4" decoded
    if [[ "${#value}" != "$want_chars" ]]; then
      printf '%s 应为 %s 字符，实际 %s\n' "$label" "$want_chars" "${#value}" >&2
      exit 1
    fi
    decoded="$(printf '%s' "$value" | base64 -d | wc -c | tr -d ' ')"
    if [[ "$decoded" != "$want_bytes" ]]; then
      printf '%s 解码后应为 %s 字节，实际 %s\n' "$label" "$want_bytes" "$decoded" >&2
      exit 1
    fi
    if [[ "$value" == *$'\n'* ]]; then
      printf '%s 不得包含换行\n' "$label" >&2
      exit 1
    fi
  }
  assert_key_shape 'SS2022 128 位密钥' "$(generate_ss_password 2022-blake3-aes-128-gcm)" 24 16
  assert_key_shape 'SS2022 256 位密钥' "$(generate_ss_password 2022-blake3-aes-256-gcm)" 44 32
  assert_key_shape 'SS2022 chacha20 密钥' "$(generate_ss_password 2022-blake3-chacha20-poly1305)" 44 32
  assert_key_shape 'ShadowTLS/AnyTLS 密码' "$(generate_st_password)" 44 32
  # 对照：长度对了也可能是常量。连续两次必须不同，否则随机源已经失效。
  if [[ "$(generate_st_password)" == "$(generate_st_password)" ]]; then
    echo '连续两次生成的密钥相同，随机源可能已失效' >&2
    exit 1
  fi
)

# 内核配置骨架只有一处定义，全新安装与接管既有安装共用它。
# 两处各写一套正是 v4.25.11 所修缺陷的成因，所以这里既锁定行为也锁定「共用」本身。
(
  # 对空对象应用得到全新安装的初始配置，内容必须与历史一致
  skeleton_fresh="$(jq -n "{} | $SINGBOX_SKELETON_ENSURE_PROGRAM" | jq -S -c .)"
  skeleton_expected="$(jq -n '{
    log:{level:"info",timestamp:true},
    dns:{servers:[{type:"local",tag:"local"}],final:"local"},
    inbounds:[],
    outbounds:[{type:"direct",tag:"direct"}],
    route:{rules:[],rule_set:[],final:"direct",default_domain_resolver:"local"},
    experimental:{cache_file:{enabled:true}}
  }' | jq -S -c .)"
  if [[ "$skeleton_fresh" != "$skeleton_expected" ]]; then
    printf '骨架对空对象的展开结果已变化\n实际: %s\n期望: %s\n' "$skeleton_fresh" "$skeleton_expected" >&2
    exit 1
  fi
  # 幂等：对已完整的配置再应用一次不得有任何变化
  skeleton_again="$(jq -c "$SINGBOX_SKELETON_ENSURE_PROGRAM" <<<"$skeleton_fresh" | jq -S -c .)"
  if [[ "$skeleton_again" != "$skeleton_fresh" ]]; then
    echo '骨架补齐不是幂等的，重复应用会改变配置' >&2
    exit 1
  fi
  # 补齐但不覆盖：已有值必须原样保留，缺的才补
  skeleton_partial='{"log":{"level":"debug"},"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"custom-out"}}'
  skeleton_filled="$(jq -c "$SINGBOX_SKELETON_ENSURE_PROGRAM" <<<"$skeleton_partial")"
  if [[ "$(jq -r '.log.level' <<<"$skeleton_filled")" != debug ]]; then
    echo '骨架补齐覆盖了使用者已设置的日志级别' >&2
    exit 1
  fi
  if [[ "$(jq -r '.route.final' <<<"$skeleton_filled")" != custom-out ]]; then
    echo '骨架补齐覆盖了已有的 route.final' >&2
    exit 1
  fi
  if [[ "$(jq -r '.experimental.cache_file.enabled' <<<"$skeleton_filled")" != true ]]; then
    echo '骨架补齐没有补上缺失的 experimental.cache_file.enabled' >&2
    exit 1
  fi
  if [[ "$(jq -r '.dns.servers[0].tag' <<<"$skeleton_filled")" != local ]]; then
    echo '骨架补齐没有补上缺失的 local DNS 服务器' >&2
    exit 1
  fi
  # 对照：只验「能补齐」不够，直接返回完整骨架的实现也能通过上面几条。
  # 这条确认它保留的是输入里的内容，而不是丢弃输入重新造一份。
  if [[ "$(jq -r '.outbounds | length' <<<"$skeleton_filled")" != 1 ]]; then
    echo '骨架补齐改变了已有的 outbounds 内容' >&2
    exit 1
  fi
)
# 全新安装与接管既有安装必须引用同一份骨架来源，不能各写一套。
# 全新安装经适配层的分派取骨架（它按内核选 SINGBOX_/MIHOMO_ 两份之一），
# 接管既有安装按定义只针对 sing-box，因此直接引用 sing-box 那一份。
if ! grep -Fq 'kernel_skeleton_ensure_program' <<<"$(declare -f write_base_config)"; then
  echo 'write_base_config must use the shared kernel skeleton program' >&2
  exit 1
fi
if ! grep -Fq 'SINGBOX_SKELETON_ENSURE_PROGRAM' <<<"$(declare -f takeover_existing_environment)"; then
  echo 'takeover_existing_environment must use the shared kernel skeleton program' >&2
  exit 1
fi

# 部署声明的代理内核。缺失即 sing-box，这是既有部署与所有 sing-box 新装机器的形态；
# 该键不写进管理配置，正是为了让回退到旧脚本时配置内容一字不变。
(
  kernel_conf="$work/kernel.conf"
  read_kernel() {
    ( CONF_FILE="$kernel_conf"
      unset PROXY_KERNEL
      load_runtime_config >/dev/null 2>&1 || return 1
      printf '%s' "$PROXY_KERNEL" )
  }
  base='HANDSHAKE_PORT=443
SHADOWTLS_STRICT_MODE=true
SS2022_SHADOWTLS_SNI="a.example.com"
ANYTLS_SNI="b.example.com"
STATE_FILE="'"$work"'/kernel-state.json"'
  printf '%s\n' '{"schema_version":7,"users":[],"splits":[],"outbound_presets":[],"rule_presets":[]}' > "$work/kernel-state.json"

  printf '%s\n' "$base" > "$kernel_conf"
  if [[ "$(read_kernel)" != singbox ]]; then
    echo '旧配置缺少 PROXY_KERNEL 时应视为 singbox' >&2
    exit 1
  fi
  printf '%s\nPROXY_KERNEL="singbox"\n' "$base" > "$kernel_conf"
  if [[ "$(read_kernel)" != singbox ]]; then
    echo '显式写 singbox 时应被接受' >&2
    exit 1
  fi
  # 未知内核名必须报错退出，不得静默降级——静默降级会让本该跑其它内核的机器
  # 悄悄跑成 sing-box，而使用者从界面上看不出任何异常。
  printf '%s\nPROXY_KERNEL="nosuchkernel"\n' "$base" > "$kernel_conf"
  if read_kernel >/dev/null 2>&1; then
    echo '未知内核名必须被拒绝，不得静默降级为 singbox' >&2
    exit 1
  fi
  # mihomo 是本片新接入的内核名，必须被接受。
  printf '%s\nPROXY_KERNEL="mihomo"\n' "$base" > "$kernel_conf"
  if [[ "$(read_kernel)" != mihomo ]]; then
    echo 'PROXY_KERNEL=mihomo 应被接受' >&2
    exit 1
  fi
)
# 管理配置的内容按内核区分，直接检查写出来的文件而不是函数体：
# 函数体检查会被「把写入挪进另一个函数」绕过，而这条盯的是最终产物。
(
  conf_check="$work/manager-config-kernel.conf"
  # 单元测试以普通用户运行，chown root:root 在这里必然失败且与本条断言无关。
  chown() { :; }
  # sing-box 部署写出的管理配置不得包含 PROXY_KERNEL。写进去会让回退到旧脚本时
  # 因「未知配置项」而无法启动，而 sing-box 部署本来完全不需要这一项。
  ( CONF_FILE="$conf_check"; PROXY_KERNEL=singbox; write_manager_config ) || {
    echo 'sing-box 管理配置写入失败' >&2
    exit 1
  }
  if grep -Fq 'PROXY_KERNEL' "$conf_check"; then
    echo 'sing-box 部署写出的管理配置不得包含 PROXY_KERNEL' >&2
    exit 1
  fi
  if grep -Fq 'MIHOMO_' "$conf_check"; then
    echo 'sing-box 部署写出的管理配置不得包含 mihomo 的路径' >&2
    exit 1
  fi
  # 对照：只验「sing-box 那份不含这些键」不够——一个什么都不写的实现同样能通过。
  # 这条确认 mihomo 那份确实写出了内核声明与自己的路径。
  ( CONF_FILE="$conf_check"; PROXY_KERNEL=mihomo; write_manager_config ) || {
    echo 'mihomo 管理配置写入失败' >&2
    exit 1
  }
  if ! grep -Fxq 'PROXY_KERNEL="mihomo"' "$conf_check"; then
    echo 'mihomo 部署写出的管理配置必须声明 PROXY_KERNEL' >&2
    exit 1
  fi
  for mihomo_key in MIHOMO_BIN MIHOMO_CONFIG MIHOMO_SERVICE MIHOMO_WORK_DIR; do
    if ! grep -Fq "${mihomo_key}=" "$conf_check"; then
      echo "mihomo 部署写出的管理配置缺少 ${mihomo_key}" >&2
      exit 1
    fi
  done
  # 写出来的内容必须能被自己的解析器读回去，否则这台机器下次启动就起不来。
  ( CONF_FILE="$conf_check"
    STATE_FILE="$work/kernel-state.json"
    unset PROXY_KERNEL
    load_runtime_config >/dev/null 2>&1 || exit 1
    [[ "$PROXY_KERNEL" == mihomo ]] || exit 1 ) || {
    echo 'mihomo 管理配置无法被 load_runtime_config 读回' >&2
    exit 1
  }
  rm -f -- "$conf_check"
)

# 四组「哪些路径属于本项目」的清单必须都覆盖两个内核（公开 Issue #175）。
# 漏掉一个内核的后果各不相同，但都是静默的：环境备份漏了，失败回滚还原不了被
# 覆盖的内核文件；卸载漏了，卸载完还留在盘上；事务白名单漏了，清理被挡在门外；
# 部署跟踪漏了，失败之后留下半成品。#175 就是环境备份那一处漏了整个 mihomo。
(
  for kernel_owned_path in \
      /etc/sing-box /var/lib/sing-box /usr/local/bin/sing-box \
      /etc/systemd/system/sing-box.service \
      /etc/systemd/system/multi-user.target.wants/sing-box.service \
      /etc/mihomo /var/lib/mihomo /usr/local/bin/mihomo \
      /etc/systemd/system/mihomo.service \
      /etc/systemd/system/multi-user.target.wants/mihomo.service; do
    for kernel_path_list in environment_backup_paths managed_uninstall_paths deploy_tracked_paths; do
      if ! ( CONF_FILE=/etc/sb-user-manager.conf; "$kernel_path_list" ) |
          grep -Fxq "$kernel_owned_path"; then
        printf '%s 的清单里缺少 %s\n' "$kernel_path_list" "$kernel_owned_path" >&2
        exit 1
      fi
    done
    if ! is_environment_recovery_path "$kernel_owned_path"; then
      printf '事务白名单不允许属于本项目的路径：%s\n' "$kernel_owned_path" >&2
      exit 1
    fi
  done
  # 对照：不属于本项目的路径不能因为上面这条要求而被一起放行。
  if is_environment_recovery_path /etc/passwd; then
    echo '事务白名单不应放行 /etc/passwd' >&2
    exit 1
  fi
  for kernel_path_list in environment_backup_paths managed_uninstall_paths deploy_tracked_paths; do
    if ( CONF_FILE=/etc/sb-user-manager.conf; "$kernel_path_list" ) | grep -Fxq /etc/passwd; then
      printf '%s 的清单里不应出现 /etc/passwd\n' "$kernel_path_list" >&2
      exit 1
    fi
  done
)

# ============================================================
# 用户入口的 mihomo 生成（公开 Issue #180，第二步 2c）
# ============================================================
# 三种入口在两个内核下的形状。**条目数量本来就不同**：sing-box 的
# SS2022 + ShadowTLS 是三个入站，mihomo 是一个同时承载 TCP 与 UDP 的监听器。
(
  entry_hs_port=443
  entry_strict=true
  gen() { # gen <内核> <函数> <参数...>
    ( PROXY_KERNEL="$1"; HANDSHAKE_PORT="$entry_hs_port"; SHADOWTLS_STRICT_MODE="$entry_strict"
      ANYTLS_CERT_FILE=/etc/sing-box/cert/anytls.crt
      ANYTLS_KEY_FILE=/etc/sing-box/cert/anytls.key
      shift; "$@" )
  }
  expect() { # expect <说明> <期望> <实际>
    [[ "$2" == "$3" ]] && return 0
    printf '%s：期望 %s，实际 %s\n' "$1" "$2" "$3" >&2
    exit 1
  }

  # 一、SS2022 + ShadowTLS
  sb="$(gen singbox make_user_inbounds demo 20001 stpw sspw 2022-blake3-aes-128-gcm a.example.com)" || exit 1
  mh="$(gen mihomo make_user_inbounds demo 20001 stpw sspw 2022-blake3-aes-128-gcm a.example.com)" || exit 1
  expect 'sing-box 的 SS2022+ShadowTLS 条目数' 3 "$(jq 'length' <<<"$sb")"
  expect 'mihomo 的 SS2022+ShadowTLS 条目数' 1 "$(jq 'length' <<<"$mh")"
  expect 'sing-box 仍有单独承载 UDP 的入站' true \
    "$(jq '[.[] | select(.tag == "ss-udp-demo" and .network == "udp")] | length == 1' <<<"$sb")"
  expect 'mihomo 监听器名沿用 st- 前缀' '"st-demo"' "$(jq '.[0].name' <<<"$mh")"
  expect 'mihomo 监听器一条就带 UDP' true "$(jq '.[0].udp' <<<"$mh")"
  # 严格模式的键名是 strict-mode。写成 strictmode 会被 mihomo 静默丢弃，
  # 严格模式悄悄关闭，而配置测试与启动日志都不会有任何提示（公开 Issue #154 的更正）。
  expect 'mihomo 的严格模式键名' true "$(jq '.[0]["shadow-tls"] | has("strict-mode")' <<<"$mh")"
  expect 'mihomo 不得出现 strictmode 这个写法' false \
    "$(jq '.[0]["shadow-tls"] | has("strictmode")' <<<"$mh")"
  expect 'mihomo 的严格模式取值跟随配置' true "$(jq '.[0]["shadow-tls"]["strict-mode"]' <<<"$mh")"
  # 对照：配置里关掉时，生成的也必须是关的——否则上一条只证明了「这里恒为真」。
  entry_strict=false
  mh_off="$(gen mihomo make_user_inbounds demo 20001 stpw sspw 2022-blake3-aes-128-gcm a.example.com)" || exit 1
  expect '严格模式关闭时生成的取值' false "$(jq '.[0]["shadow-tls"]["strict-mode"]' <<<"$mh_off")"
  entry_strict=true
  # 握手目标：sing-box 是 server + server_port 两个字段，mihomo 是单个 dest 字符串。
  expect 'sing-box 的握手目标' '"a.example.com"' "$(jq '.[0].handshake.server' <<<"$sb")"
  expect 'mihomo 的握手目标' '"a.example.com:443"' "$(jq '.[0]["shadow-tls"].handshake.dest' <<<"$mh")"

  # 二、原生 SS2022
  sb="$(gen singbox make_ss2022_inbound demo 20002 sspw 2022-blake3-aes-128-gcm)" || exit 1
  mh="$(gen mihomo make_ss2022_inbound demo 20002 sspw 2022-blake3-aes-128-gcm)" || exit 1
  expect 'sing-box 原生 SS2022 的方法字段' '"2022-blake3-aes-128-gcm"' "$(jq '.[0].method' <<<"$sb")"
  expect 'mihomo 原生 SS2022 的方法字段叫 cipher' '"2022-blake3-aes-128-gcm"' "$(jq '.[0].cipher' <<<"$mh")"
  expect 'mihomo 原生 SS2022 带 UDP' true "$(jq '.[0].udp' <<<"$mh")"
  mh="$(gen mihomo make_ss2022_inbound demo 20002 sspw 2022-blake3-aes-128-gcm ss-direct-demo)" || exit 1
  expect 'mihomo 沿用指定的条目名' '"ss-direct-demo"' "$(jq '.[0].name' <<<"$mh")"

  # 三、AnyTLS：users 在 sing-box 是数组，在 mihomo 是映射；证书字段名也不同。
  sb="$(gen singbox make_anytls_inbound demo 20003 atpw)" || exit 1
  mh="$(gen mihomo make_anytls_inbound demo 20003 atpw)" || exit 1
  expect 'sing-box 的 AnyTLS users 是数组' '"array"' "$(jq '.[0].users | type' <<<"$sb")"
  expect 'mihomo 的 AnyTLS users 是映射' '"object"' "$(jq '.[0].users | type' <<<"$mh")"
  expect 'mihomo 的 AnyTLS 密码按用户名索引' '"atpw"' "$(jq '.[0].users.demo' <<<"$mh")"
  expect 'mihomo 的证书字段名' '"/etc/sing-box/cert/anytls.crt"' "$(jq '.[0].certificate' <<<"$mh")"
  expect 'mihomo 的私钥字段名' '"/etc/sing-box/cert/anytls.key"' "$(jq '.[0]["private-key"]' <<<"$mh")"
  # 证书路径跟着 MANAGER_DATA_DIR 走，不是写死的（公开 Issue #173）。
  mh="$( PROXY_KERNEL=mihomo
         MANAGER_DATA_DIR=/etc/sb-user-manager; resolve_manager_data_paths
         make_anytls_inbound demo 20003 atpw )" || exit 1
  expect 'mihomo 的证书路径跟随管理器数据目录' '"/etc/sb-user-manager/cert/anytls.crt"' \
    "$(jq '.[0].certificate' <<<"$mh")"

  # 四、未知内核必须报错，不得回落到任意一个内核的形状。
  if ( PROXY_KERNEL=nosuchkernel; make_anytls_inbound demo 20003 atpw >/dev/null 2>&1 ); then
    echo '未知内核时生成入口必须报错' >&2
    exit 1
  fi

  # 五、托管条目的容器与标识按内核取值。
  expect 'sing-box 的容器' inbounds "$(PROXY_KERNEL=singbox kernel_managed_container)"
  expect 'mihomo 的容器' listeners "$(PROXY_KERNEL=mihomo kernel_managed_container)"
  expect 'sing-box 的标识字段' tag "$(PROXY_KERNEL=singbox kernel_managed_key)"
  expect 'mihomo 的标识字段' name "$(PROXY_KERNEL=mihomo kernel_managed_key)"
)
# 操作事务的回滚材料必须取自当前内核自己的运行配置。此前这里写死 SINGBOX_CONFIG，
# 在 mihomo 机器上第一步就会去复制一份不存在的 sing-box 配置，整个操作失败。
# 2c 之前 mihomo 机器不可能有用户，走不到这条路；本片让它可达。
(
  txn_root="$work/txn-kernel"
  mkdir -p "$txn_root/backups"
  printf '%s' '{"inbounds":[]}' > "$txn_root/singbox.json"
  printf '%s' '{"listeners":[]}' > "$txn_root/mihomo.json"
  printf '%s' '{"schema_version":7,"users":[]}' > "$txn_root/state.json"
  for txn_kernel in singbox mihomo; do
    stamp="$( PROXY_KERNEL="$txn_kernel"
              SINGBOX_CONFIG="$txn_root/singbox.json"
              MIHOMO_CONFIG="$txn_root/mihomo.json"
              STATE_FILE="$txn_root/state.json"
              BACKUP_DIR="$txn_root/backups"
              CONF_FILE="$txn_root/absent.conf"
              backup_files )" || {
      printf '%s 部署的事务备份失败\n' "$txn_kernel" >&2
      exit 1
    }
    # 备份文件名保持 config.json.<戳>，内容取自当前内核的运行配置。
    expected="$txn_root/$txn_kernel.json"
    if ! cmp -s "$txn_root/backups/config.json.$stamp" "$expected"; then
      printf '%s 部署的事务备份内容不是该内核的运行配置\n' "$txn_kernel" >&2
      exit 1
    fi
  done
  # 对照：备份出来的两份内容必须不同，否则上面的比对可能只是「两个文件恰好一样」。
  if cmp -s "$txn_root/singbox.json" "$txn_root/mihomo.json"; then
    echo '对照失败：两个内核的样例配置内容相同，比对不成立' >&2
    exit 1
  fi
  rm -rf -- "$txn_root"
)

# 分流的运行配置改写在 mihomo 上必须明确失败，不得写到 sing-box 的配置里去。
# 2c 让 mihomo 机器第一次能有用户，分流菜单随之可达，而分流的 mihomo 侧要到 2d。
(
  split_probe_config="$work/split-guard-config.json"
  printf '%s' '{"inbounds":[],"outbounds":[]}' > "$split_probe_config"
  if ( PROXY_KERNEL=mihomo; SINGBOX_CONFIG="$split_probe_config"
       rewrite_kernel_config '.' >/dev/null 2>&1 ); then
    echo 'mihomo 部署上改写分流运行配置必须失败' >&2
    exit 1
  fi
  # 对照：sing-box 上照常工作，否则上一条也可能只是「这个函数整个坏了」。
  if ! ( PROXY_KERNEL=singbox; SINGBOX_CONFIG="$split_probe_config"
         MIHOMO_CONFIG="$split_probe_config"
         kernel_normalized_config() { cat "$SINGBOX_CONFIG"; }
         rewrite_kernel_config '.' >/dev/null 2>&1 ); then
    echo 'sing-box 部署上改写分流运行配置必须照常工作' >&2
    exit 1
  fi
  rm -f -- "$split_probe_config"
)

# ============================================================
# 管理器数据路径的单一来源（公开 Issue #172、#173）
# ============================================================
# 管理器自身的数据——用户资料、内部备份、AnyTLS 证书——全部由 MANAGER_DATA_DIR
# 派生。这一节先锁默认值（既有机器一字不变），再验「改这一个值整组跟着走」。
# 只验前者不够：默认值写死在派生公式里也能让前者通过，那样等于没有单一来源。
(
  data_conf="$work/manager-data.conf"
  base='HANDSHAKE_PORT=443
SHADOWTLS_STRICT_MODE=true
SS2022_SHADOWTLS_SNI="a.example.com"
ANYTLS_SNI="b.example.com"'

  # 一、不写 MANAGER_DATA_DIR 时，三类路径必须与历史版本逐字相同。
  printf '%s\n' "$base" > "$data_conf"
  ( CONF_FILE="$data_conf"
    # 这几项在上文的夹具里已被设过；不清掉，:= 兜底就不会生效，
    # 这条断言测到的将是夹具的值而不是默认值。与上文 unset PROXY_KERNEL 同理。
    unset MANAGER_DATA_DIR STATE_FILE BACKUP_DIR CERT_DIR ANYTLS_CERT_FILE ANYTLS_KEY_FILE
    load_runtime_config >/dev/null 2>&1 || exit 1
    [[ "$MANAGER_DATA_DIR" == /etc/sing-box ]] || exit 1
    [[ "$STATE_FILE" == /etc/sing-box/managed-users.json ]] || exit 1
    [[ "$BACKUP_DIR" == /etc/sing-box/backups ]] || exit 1
    [[ "$CERT_DIR" == /etc/sing-box/cert ]] || exit 1
    [[ "$ANYTLS_CERT_FILE" == /etc/sing-box/cert/anytls.crt ]] || exit 1
    [[ "$ANYTLS_KEY_FILE" == /etc/sing-box/cert/anytls.key ]] || exit 1 ) || {
    echo '不写 MANAGER_DATA_DIR 时，管理器数据路径必须与历史版本逐字相同' >&2
    exit 1
  }

  # 二、写了就以配置为准，且整组跟着走——包括生成的运行配置与 systemd 单元。
  moved_root="$work/manager-data-root"
  mkdir -p "$moved_root/etc/systemd/system"
  printf '%s\nMANAGER_DATA_DIR="/etc/sb-user-manager"\n' "$base" > "$data_conf"
  ( CONF_FILE="$data_conf"
    SB_SYSTEM_ROOT="$moved_root"
    unset MANAGER_DATA_DIR STATE_FILE BACKUP_DIR CERT_DIR ANYTLS_CERT_FILE ANYTLS_KEY_FILE
    load_runtime_config >/dev/null 2>&1 || exit 1
    [[ "$STATE_FILE" == /etc/sb-user-manager/managed-users.json ]] || exit 1
    [[ "$BACKUP_DIR" == /etc/sb-user-manager/backups ]] || exit 1
    [[ "$ANYTLS_CERT_FILE" == /etc/sb-user-manager/cert/anytls.crt ]] || exit 1
    # 生成的 AnyTLS 入站里的证书路径同样要跟着走：这两处此前是 jq 过滤器里的
    # 字面量，是本次收敛里最容易漏掉的一处。
    inbound="$(make_anytls_inbound demo 20001 pw)" || exit 1
    [[ "$(jq -r '.[0].tls.certificate_path' <<<"$inbound")" == /etc/sb-user-manager/cert/anytls.crt ]] || exit 1
    [[ "$(jq -r '.[0].tls.key_path' <<<"$inbound")" == /etc/sb-user-manager/cert/anytls.key ]] || exit 1
    # mihomo 单元里的 SAFE_PATHS 指的就是证书目录；它跟不上就等于监听器起不来
    # （公开 Issue #154 实测：mihomo 拒绝加载 SAFE_PATHS 之外的证书，
    # 而 mihomo -t 完全测不出这个问题）。
    write_mihomo_unit || exit 1
    grep -Fxq 'Environment=SAFE_PATHS=/etc/sb-user-manager/cert:/etc/mihomo/rules' \
      "$moved_root/etc/systemd/system/mihomo.service" || exit 1
    # 四组路径集合：漏掉任何一组，改值之后就会出现「备份里没有用户数据」
    # 或「卸载后用户资料还留在盘上」这类静默后果。
    CONF_FILE=/etc/sb-user-manager.conf
    deploy_tracked_paths | grep -Fxq /etc/sb-user-manager/cert || exit 1
    environment_backup_paths | grep -Fxq /etc/sb-user-manager || exit 1
    managed_uninstall_paths | grep -Fxq /etc/sb-user-manager || exit 1
    is_environment_recovery_path /etc/sb-user-manager/managed-users.json || exit 1 ) || {
    echo 'MANAGER_DATA_DIR 改值后，管理器数据路径必须整组跟着走' >&2
    exit 1
  }

  # 三、相对路径必须报错退出。用户资料、内部备份与证书落到脚本当时的工作目录里，
  # 丢了就是丢了，不能将就。
  printf '%s\nMANAGER_DATA_DIR="relative/path"\n' "$base" > "$data_conf"
  if ( CONF_FILE="$data_conf"; unset MANAGER_DATA_DIR; load_runtime_config >/dev/null 2>&1 ); then
    echo 'MANAGER_DATA_DIR 为相对路径时必须报错退出' >&2
    exit 1
  fi
  # 对照：绝对路径仍然被接受，证明上一条挡住的是相对路径本身，
  # 而不是这个配置项整个不能用。
  printf '%s\nMANAGER_DATA_DIR="/etc/sb-user-manager"\n' "$base" > "$data_conf"
  ( CONF_FILE="$data_conf"; unset MANAGER_DATA_DIR; load_runtime_config >/dev/null 2>&1 ) || {
    echo 'MANAGER_DATA_DIR 为绝对路径时必须被接受' >&2
    exit 1
  }
  rm -f -- "$data_conf"
)
# 两份管理配置都不写 MANAGER_DATA_DIR：写进去等于把当前默认值固化在每台机器上，
# 将来改默认值反而要逐台改配置。同时确认展开后的取值与历史版本逐字相同。
(
  conf_check="$work/manager-config-data-dir.conf"
  chown() { :; }
  for data_dir_kernel in singbox mihomo; do
    ( CONF_FILE="$conf_check"; PROXY_KERNEL="$data_dir_kernel"; write_manager_config ) || {
      echo "${data_dir_kernel} 管理配置写入失败" >&2
      exit 1
    }
    if grep -Fq 'MANAGER_DATA_DIR' "$conf_check"; then
      echo "${data_dir_kernel} 部署写出的管理配置不得包含 MANAGER_DATA_DIR" >&2
      exit 1
    fi
    if ! grep -Fxq 'STATE_FILE="/etc/sing-box/managed-users.json"' "$conf_check"; then
      echo "${data_dir_kernel} 管理配置里的 STATE_FILE 取值与历史版本不一致" >&2
      exit 1
    fi
    if ! grep -Fxq 'BACKUP_DIR="/etc/sing-box/backups"' "$conf_check"; then
      echo "${data_dir_kernel} 管理配置里的 BACKUP_DIR 取值与历史版本不一致" >&2
      exit 1
    fi
  done
  rm -f -- "$conf_check"
)

# ============================================================
# 第二内核 mihomo：安装、服务与版本（公开 Issue #165）
# ============================================================

# 内核身份三项按 PROXY_KERNEL 分派。
(
  # 用可区分的哨兵取值，确认取到的确实是当前内核那一套，而不是碰巧相同的默认值。
  SINGBOX_BIN=/sentinel/singbox-bin
  SINGBOX_CONFIG=/sentinel/singbox-config.json
  SINGBOX_SERVICE=sentinel-singbox
  MIHOMO_BIN=/sentinel/mihomo-bin
  MIHOMO_CONFIG=/sentinel/mihomo-config.json
  MIHOMO_SERVICE=sentinel-mihomo
  MIHOMO_WORK_DIR=/sentinel/mihomo-work
  ( PROXY_KERNEL=singbox
    [[ "$(kernel_binary_path)" == /sentinel/singbox-bin ]] &&
    [[ "$(kernel_config_path)" == /sentinel/singbox-config.json ]] &&
    [[ "$(kernel_service_name)" == sentinel-singbox ]] &&
    [[ "$(kernel_work_dir)" == /var/lib/sing-box ]] &&
    [[ "$(kernel_display_name)" == sing-box ]] &&
    [[ "$(kernel_process_name)" == sing-box ]] ) || {
    echo 'sing-box 部署的内核身份取值不正确' >&2
    exit 1
  }
  ( PROXY_KERNEL=mihomo
    [[ "$(kernel_binary_path)" == /sentinel/mihomo-bin ]] &&
    [[ "$(kernel_config_path)" == /sentinel/mihomo-config.json ]] &&
    [[ "$(kernel_service_name)" == sentinel-mihomo ]] &&
    [[ "$(kernel_work_dir)" == /sentinel/mihomo-work ]] &&
    [[ "$(kernel_display_name)" == mihomo ]] &&
    [[ "$(kernel_process_name)" == mihomo ]] ) || {
    echo 'mihomo 部署的内核身份取值不正确' >&2
    exit 1
  }
  # 内核名无法识别时必须报错，不得静默返回某一套取值。
  if ( PROXY_KERNEL=nosuchkernel; kernel_binary_path >/dev/null 2>&1 ); then
    echo '未知内核名下的身份查询必须失败' >&2
    exit 1
  fi
)

# mihomo 尚未实现的适配层操作必须明确报错，且不得回落到 sing-box 的实现。
# 回落产生的是按 sing-box 结构改写的坏数据，比报错难查得多。
(
  kernel_fallback="$work/kernel-fallback"
  mkdir -p "$kernel_fallback"
  marker="$kernel_fallback/singbox-was-called"
  fake_singbox="$kernel_fallback/sing-box"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf called > %q\n' "$marker"
  } > "$fake_singbox"
  chmod 755 "$fake_singbox"
  PROXY_KERNEL=mihomo
  SINGBOX_BIN="$fake_singbox"
  SINGBOX_CONFIG="$kernel_fallback/config.json"
  printf '{}\n' > "$SINGBOX_CONFIG"
  for unsupported in \
    'kernel_normalized_config' \
    'kernel_normalized_default_install' \
    "kernel_rule_set_compile $fake_singbox in out" \
    "kernel_rule_set_decompile $fake_singbox in out"; do
    if $unsupported >/dev/null 2>&1; then
      printf 'mihomo 部署下 %s 必须报错而不是成功返回\n' "$unsupported" >&2
      exit 1
    fi
  done
  # 对照：报错还不够，必须确认它根本没去调用 sing-box。
  if [[ -e "$marker" ]]; then
    echo 'mihomo 部署下的未实现操作不得回落到 sing-box 实现' >&2
    exit 1
  fi
  # 再一条对照：同样这几个操作在 sing-box 部署下必须真的调用到内核，
  # 否则「没调用 sing-box」也可能只是因为整段代码根本没跑起来。
  PROXY_KERNEL=singbox
  kernel_normalized_config >/dev/null 2>&1 || true
  if [[ ! -e "$marker" ]]; then
    echo 'sing-box 部署下读取运行配置必须调用内核' >&2
    exit 1
  fi
)

# 版本号解析：两个内核的子命令与输出格式都不同。
(
  version_work="$work/kernel-version"
  mkdir -p "$version_work"
  fake_mihomo="$version_work/mihomo"
  cat > "$fake_mihomo" <<'FAKE'
#!/usr/bin/env bash
[[ "$1" == -v ]] || exit 64
printf 'Mihomo Meta v1.19.30 linux amd64 with go1.26.6 Sun Aug 16 10:01:10 UTC 2026\n'
printf 'Use tags: with_gvisor\n'
FAKE
  chmod 755 "$fake_mihomo"
  fake_singbox="$version_work/sing-box"
  cat > "$fake_singbox" <<'FAKE'
#!/usr/bin/env bash
[[ "$1" == version ]] || exit 64
printf 'sing-box version 1.13.19\n'
FAKE
  chmod 755 "$fake_singbox"
  # mihomo 的版本号带 v 前缀，必须去掉才能与 Release 标签去 v 后的写法比较。
  if [[ "$(PROXY_KERNEL=mihomo; kernel_binary_version "$fake_mihomo")" != 1.19.30 ]]; then
    echo 'mihomo 版本号解析不正确（应去掉 v 前缀）' >&2
    exit 1
  fi
  if [[ "$(PROXY_KERNEL=singbox; kernel_binary_version "$fake_singbox")" != 1.13.19 ]]; then
    echo 'sing-box 版本号解析被改坏了' >&2
    exit 1
  fi
  # 微架构不匹配的 mihomo 二进制会拒绝运行；版本读出来必须是空字符串，
  # 安装流程正是靠这一点当场发现资产选错（公开 Issue #165）。
  # 拒绝信息走标准错误、退出码 1、标准输出为空——这是真实二进制的行为，
  # 已在测试机上实测确认，不是照着想象写的。
  wrong_arch="$version_work/mihomo-wrong-arch"
  cat > "$wrong_arch" <<'FAKE'
#!/usr/bin/env bash
printf 'This program can only be run on AMD64 processors with v3 microarchitecture support.\n' >&2
exit 1
FAKE
  chmod 755 "$wrong_arch"
  if [[ -n "$(PROXY_KERNEL=mihomo; kernel_binary_version "$wrong_arch")" ]]; then
    echo '拒绝运行的 mihomo 二进制不应报出版本号' >&2
    exit 1
  fi
)

# 资产名：mihomo 选 compatible 变体，不选不带后缀的那个（那个是 v3 构建）。
(
  # 变量名刻意避开 fetch_latest_kernel_release 里的 local release_json：
  # bash 是动态作用域，同名会让桩函数读到函数内那个尚未赋值的局部变量。
  mihomo_release_fixture='{"tag_name":"v1.19.30","assets":[
    {"name":"mihomo-linux-amd64-v1.19.30.gz","browser_download_url":"https://example.com/v3.gz","digest":"sha256:'"$(printf 'a%.0s' {1..64})"'"},
    {"name":"mihomo-linux-amd64-compatible-v1.19.30.gz","browser_download_url":"https://example.com/compatible.gz","digest":"sha256:'"$(printf 'b%.0s' {1..64})"'"}]}'
  github_api_get() { printf '%s' "$mihomo_release_fixture"; }
  PROXY_KERNEL=mihomo
  fetch_latest_kernel_release || { echo 'mihomo Release 解析失败' >&2; exit 1; }
  if [[ "$LATEST_KERNEL_ASSET" != mihomo-linux-amd64-compatible-v1.19.30.gz ]]; then
    printf 'mihomo 资产变体必须是 compatible，实际取到 %s\n' "$LATEST_KERNEL_ASSET" >&2
    exit 1
  fi
  if [[ "$LATEST_KERNEL_URL" != https://example.com/compatible.gz ]]; then
    echo 'mihomo 资产地址取错了变体' >&2
    exit 1
  fi
  if [[ "$LATEST_KERNEL_VERSION" != 1.19.30 ]]; then
    echo 'mihomo 版本号应去掉标签的 v 前缀' >&2
    exit 1
  fi
)

# 下载：版本号对不上时必须在安装前停止。这条同时是选错微架构的兜底。
(
  dl="$work/kernel-download-mihomo"
  mkdir -p "$dl"
  PROXY_KERNEL=mihomo
  LATEST_KERNEL_VERSION=1.19.30
  LATEST_KERNEL_ASSET=mihomo-linux-amd64-compatible-v1.19.30.gz
  LATEST_KERNEL_URL=https://example.com/compatible.gz
  LATEST_KERNEL_SHA256="$(printf 'b%.0s' {1..64})"
  github_download_to() { printf 'compressed' > "$1"; }
  sha256sum() { cat >/dev/null; return 0; }
  atomic_install_file() { printf 'installed\n' > "$dl/installed"; }
  # 解压出来的二进制报告的版本与预期不符。
  gzip() {
    printf '#!/usr/bin/env bash\nprintf "Mihomo Meta v9.9.9 linux amd64\\n"\n'
  }
  if download_mihomo_binary "$dl" >/dev/null 2>&1; then
    echo '解压出的 mihomo 版本与预期不符时必须失败' >&2
    exit 1
  fi
  if [[ -e "$dl/installed" ]]; then
    echo '版本不符时不得安装二进制' >&2
    exit 1
  fi
  # 对照：版本相符时同一条路径必须走通并安装，否则上面的失败可能只是别处出错。
  gzip() {
    printf '#!/usr/bin/env bash\nprintf "Mihomo Meta v1.19.30 linux amd64\\n"\n'
  }
  if ! download_mihomo_binary "$dl" >/dev/null 2>&1; then
    echo '版本相符时 mihomo 下载安装应当成功' >&2
    exit 1
  fi
  if [[ ! -e "$dl/installed" ]]; then
    echo '版本相符时应当安装二进制' >&2
    exit 1
  fi
)

# systemd 单元内容。sing-box 一侧必须与升级前一字不变，mihomo 一侧必须带上
# 两条 SAFE_PATHS：证书目录（公开 Issue #154 实测确认 mihomo 拒绝加载工作目录
# 之外的证书，而这个限制在 `mihomo -t` 阶段完全不暴露，只有真正启动监听器时
# 才报错）与使用者的分流规则目录（公开 Issue #186 实测，这一条反而在
# `mihomo -t` 阶段就当场拒绝）。分隔符是冒号，实测逗号不认。
(
  unit_root="$work/kernel-units"
  mkdir -p "$unit_root/etc/systemd/system"
  SB_SYSTEM_ROOT="$unit_root"
  expected_singbox='[Unit]
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
WantedBy=multi-user.target'
  expected_expiry_service='[Unit]
Description=Expire sing-box managed users
After=sing-box.service nfuse.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sb-user-manager --internal-expire'
  ( PROXY_KERNEL=singbox; write_kernel_unit && write_expiry_units ) || {
    echo 'sing-box 单元写入失败' >&2
    exit 1
  }
  if [[ "$(<"$unit_root/etc/systemd/system/sing-box.service")" != "$expected_singbox" ]]; then
    echo 'sing-box 服务单元内容发生了变化；既有部署升级后单元必须一字不变' >&2
    diff -u <(printf '%s\n' "$expected_singbox") "$unit_root/etc/systemd/system/sing-box.service" >&2 || true
    exit 1
  fi
  if [[ "$(<"$unit_root/etc/systemd/system/sb-user-expiry.service")" != "$expected_expiry_service" ]]; then
    echo '到期检查单元在 sing-box 部署上的内容发生了变化' >&2
    diff -u <(printf '%s\n' "$expected_expiry_service") "$unit_root/etc/systemd/system/sb-user-expiry.service" >&2 || true
    exit 1
  fi
  expected_mihomo='[Unit]
Description=mihomo service
After=network-online.target nss-lookup.target
Wants=network-online.target
[Service]
Type=simple
User=root
StateDirectory=mihomo
Environment=SAFE_PATHS=/etc/sing-box/cert:/etc/mihomo/rules
ExecStart=/usr/local/bin/mihomo -d /var/lib/mihomo -f /etc/mihomo/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity
[Install]
WantedBy=multi-user.target'
  ( PROXY_KERNEL=mihomo; write_kernel_unit && write_expiry_units ) || {
    echo 'mihomo 单元写入失败' >&2
    exit 1
  }
  if [[ "$(<"$unit_root/etc/systemd/system/mihomo.service")" != "$expected_mihomo" ]]; then
    echo 'mihomo 服务单元内容不符合预期' >&2
    diff -u <(printf '%s\n' "$expected_mihomo") "$unit_root/etc/systemd/system/mihomo.service" >&2 || true
    exit 1
  fi
  if [[ ! -e "$unit_root/etc/systemd/system/sing-box.service" ]]; then
    echo '写 mihomo 单元不应删除既有的 sing-box 单元' >&2
    exit 1
  fi
  # 到期检查单元必须跟着内核走，否则 mihomo 机器上它会等一个永远不出现的服务。
  if ! grep -Fxq 'After=mihomo.service nfuse.service' "$unit_root/etc/systemd/system/sb-user-expiry.service"; then
    echo 'mihomo 部署的到期检查单元必须依赖 mihomo.service' >&2
    exit 1
  fi
)

# 版本记录里的内核字段按内核命名；sing-box 一侧保持 SINGBOX_VERSION 不变。
(
  versions_root="$work/kernel-versions"
  mkdir -p "$versions_root"
  SB_SYSTEM_ROOT="$versions_root"
  LATEST_KERNEL_VERSION=1.19.30
  LATEST_NFUSE_VERSION=0.1.13
  ( PROXY_KERNEL=mihomo; write_deployed_versions 4.25.16 ) || {
    echo 'mihomo 版本记录写入失败' >&2
    exit 1
  }
  if ! grep -Fxq 'MIHOMO_VERSION=1.19.30' "$versions_root/var/lib/sb-user-manager/versions"; then
    echo 'mihomo 部署的版本记录应写 MIHOMO_VERSION' >&2
    exit 1
  fi
  if grep -Fq 'SINGBOX_VERSION=' "$versions_root/var/lib/sb-user-manager/versions"; then
    echo 'mihomo 部署的版本记录不应写 SINGBOX_VERSION' >&2
    exit 1
  fi
  LATEST_KERNEL_VERSION=1.13.19
  ( PROXY_KERNEL=singbox; write_deployed_versions 4.25.16 ) || {
    echo 'sing-box 版本记录写入失败' >&2
    exit 1
  }
  if ! grep -Fxq 'SINGBOX_VERSION=1.13.19' "$versions_root/var/lib/sb-user-manager/versions"; then
    echo 'sing-box 部署的版本记录必须继续写 SINGBOX_VERSION' >&2
    exit 1
  fi
)

# 「SSH 连接是否走本机节点」这条护栏按当前内核的进程名匹配。
# 写死 sing-box 会让它在 mihomo 机器上永远判为「不是本机节点」——
# 一条恒假的安全检查比没有更糟，因为它看起来还在。
(
  SSH_CONNECTION='203.0.113.9 51234 198.51.100.7 22'
  list_kernel_owned_ssh_sockets() {
    printf '198.51.100.7:22 203.0.113.9:51234 users:(("mihomo",pid=4242,fd=9))\n'
  }
  if ( PROXY_KERNEL=singbox; ssh_connection_uses_local_kernel ); then
    echo 'sing-box 部署不应把 mihomo 持有的连接判成本机节点' >&2
    exit 1
  fi
  if ! ( PROXY_KERNEL=mihomo; ssh_connection_uses_local_kernel ); then
    echo 'mihomo 部署必须识别出 mihomo 持有的 SSH 连接' >&2
    exit 1
  fi
  list_kernel_owned_ssh_sockets() {
    printf '198.51.100.7:22 203.0.113.9:51234 users:(("sing-box",pid=4242,fd=9))\n'
  }
  if ! ( PROXY_KERNEL=singbox; ssh_connection_uses_local_kernel ); then
    echo 'sing-box 部署必须继续识别出 sing-box 持有的 SSH 连接' >&2
    exit 1
  fi
)

# 环境完整性只看当前内核的核心文件：mihomo 机器上没有 sing-box 是正常状态。
(
  env_root="$work/kernel-environment"
  mkdir -p "$env_root/etc/mihomo" "$env_root/usr/local/bin" "$env_root/etc/systemd/system" \
    "$env_root/etc/sing-box" "$env_root/usr/local/sbin"
  SB_SYSTEM_ROOT="$env_root"
  : > "$env_root/etc/mihomo/config.json"
  : > "$env_root/usr/local/bin/mihomo"
  : > "$env_root/etc/systemd/system/mihomo.service"
  : > "$env_root/etc/sb-user-manager.conf"
  : > "$env_root/etc/sing-box/managed-users.json"
  : > "$env_root/usr/local/sbin/sb-user-manager"
  : > "$env_root/usr/local/bin/nfuse"
  : > "$env_root/etc/systemd/system/nfuse.service"
  : > "$env_root/etc/systemd/system/sb-user-expiry.service"
  : > "$env_root/etc/systemd/system/sb-user-expiry.timer"
  if ! ( PROXY_KERNEL=mihomo; standalone_environment_is_complete ); then
    echo '只装了 mihomo 的机器应被判为部署完整' >&2
    exit 1
  fi
  # 对照：同一套文件在 sing-box 部署下必须被判为不完整，
  # 否则「完整」可能只是因为这条检查什么都没查。
  if ( PROXY_KERNEL=singbox; standalone_environment_is_complete ); then
    echo '缺少 sing-box 的机器在 sing-box 部署下不应被判为完整' >&2
    exit 1
  fi
)

# mihomo 的配置骨架。对空对象应用得到全新安装的初始配置；
# 对既有配置应用只补缺项，不覆盖已有值。
(
  mihomo_skeleton="$(jq -n "{} | $MIHOMO_SKELETON_ENSURE_PROGRAM")" || {
    echo 'mihomo 骨架程序无法执行' >&2
    exit 1
  }
  if ! jq -e '
    .["log-level"] == "info" and .mode == "rule" and
    (.listeners | type == "array" and length == 0) and
    (.proxies | type == "array" and length == 0) and
    (.["proxy-groups"] | type == "array" and length == 0) and
    (.rules | type == "array" and length == 0)
  ' <<<"$mihomo_skeleton" >/dev/null; then
    echo 'mihomo 初始配置骨架不符合预期' >&2
    printf '%s\n' "$mihomo_skeleton" >&2
    exit 1
  fi
  # 骨架里不写用于重申默认值的键：mihomo 对未知键完全静默，写一个拼错的
  # external-controller 只会带来虚假的安全感。真正的保护是部署后
  # 「mihomo 名下监听套接字数为 0」这条可观测断言。
  if jq -e 'has("external-controller") or has("port") or has("socks-port") or has("mixed-port")' \
      <<<"$mihomo_skeleton" >/dev/null; then
    echo 'mihomo 骨架不应写入用于重申默认值的入口配置项' >&2
    exit 1
  fi
  # 对照：补齐必须保留已有内容，而不是丢弃输入重新造一份。
  existing='{"log-level":"warning","listeners":[{"name":"keep-me","type":"shadowsocks"}]}'
  filled="$(jq "$MIHOMO_SKELETON_ENSURE_PROGRAM" <<<"$existing")" || {
    echo 'mihomo 骨架补齐失败' >&2
    exit 1
  }
  if ! jq -e '.["log-level"] == "warning" and (.listeners | length) == 1 and .listeners[0].name == "keep-me" and (.rules | type) == "array"' \
      <<<"$filled" >/dev/null; then
    echo 'mihomo 骨架补齐覆盖了已有内容' >&2
    printf '%s\n' "$filled" >&2
    exit 1
  fi
)

# 已部署的机器执行「安装或修复环境」时，内核必须取自管理配置的声明。
# 这条是真机上撞出来的：不显式确定内核时，一台 mihomo 机器执行「自动修复缺失内容」
# 会按文件级默认值走 sing-box——下载 sing-box、写 sing-box 单元、
# 再用 sing-box 去校验一份不存在的配置。
(
  resolve_conf="$work/resolve-kernel.conf"
  resolve_state="$work/resolve-kernel-state.json"
  printf '%s\n' '{"schema_version":7,"users":[],"splits":[],"outbound_presets":[],"rule_presets":[]}' > "$resolve_state"
  base_conf='HANDSHAKE_PORT=443
SHADOWTLS_STRICT_MODE=true
SS2022_SHADOWTLS_SNI="a.example.com"
ANYTLS_SNI="b.example.com"
STATE_FILE="'"$resolve_state"'"'
  resolved_kernel() {
    ( CONF_FILE="$resolve_conf"
      PROXY_KERNEL=singbox
      resolve_deployment_kernel >/dev/null 2>&1 || exit 1
      printf '%s' "$PROXY_KERNEL" )
  }

  printf '%s\nPROXY_KERNEL="mihomo"\n' "$base_conf" > "$resolve_conf"
  chmod 600 "$resolve_conf"
  if [[ "$(resolved_kernel)" != mihomo ]]; then
    echo '已部署的 mihomo 机器再次部署时必须仍按 mihomo 进行' >&2
    exit 1
  fi
  # 对照：同一条路径在 sing-box 机器上必须仍然得到 singbox，
  # 否则「取到 mihomo」也可能只是因为这个函数把什么都当成 mihomo。
  printf '%s\n' "$base_conf" > "$resolve_conf"
  chmod 600 "$resolve_conf"
  if [[ "$(resolved_kernel)" != singbox ]]; then
    echo '已部署的 sing-box 机器必须仍按 sing-box 进行' >&2
    exit 1
  fi
  # 尚未部署的机器才轮到测试用的选择方式。
  rm -f -- "$resolve_conf"
  if [[ "$( CONF_FILE="$resolve_conf"; PROXY_KERNEL=singbox; SB_DEPLOY_PROXY_KERNEL=mihomo
            resolve_deployment_kernel >/dev/null 2>&1; printf '%s' "$PROXY_KERNEL" )" != mihomo ]]; then
    echo '未部署的机器应接受测试用的内核选择' >&2
    exit 1
  fi
)

# 仅供测试的内核选择：只对尚未部署的机器生效，未知取值必须拒绝。
(
  select_conf="$work/kernel-select.conf"
  rm -f -- "$select_conf"
  if [[ "$( CONF_FILE="$select_conf"; SB_DEPLOY_PROXY_KERNEL=mihomo
            apply_test_only_kernel_selection >/dev/null; printf '%s' "$PROXY_KERNEL" )" != mihomo ]]; then
    echo '未部署的机器应接受测试用的内核选择' >&2
    exit 1
  fi
  printf 'HANDSHAKE_PORT=443\n' > "$select_conf"
  if [[ "$( CONF_FILE="$select_conf"; PROXY_KERNEL=singbox; SB_DEPLOY_PROXY_KERNEL=mihomo
            apply_test_only_kernel_selection >/dev/null; printf '%s' "$PROXY_KERNEL" )" != singbox ]]; then
    echo '已部署的机器不得被环境变量改掉内核' >&2
    exit 1
  fi
  rm -f -- "$select_conf"
  if ( CONF_FILE="$select_conf"; SB_DEPLOY_PROXY_KERNEL=nosuchkernel
       apply_test_only_kernel_selection >/dev/null 2>&1 ); then
    echo '未知的测试内核选择必须被拒绝' >&2
    exit 1
  fi
)


# ============================================================
# 第二步 2d：分流的 mihomo 生成
# ============================================================
# 这一组全部在 PROXY_KERNEL=mihomo 下跑，并且每条都配一个 sing-box 侧或
# 「不该生效」的对照——只断言 mihomo 那一半，分不清「生成对了」与「整段没跑」。
(
  work_2d="$work/mihomo-split"
  mkdir -p "$work_2d/rules"
  PROXY_KERNEL=mihomo
  MIHOMO_CONFIG="$work_2d/config.json"
  MIHOMO_RULES_DIR="$work_2d/rules"
  STATE_FILE="$work_2d/state.json"

  # --- 一、上游出口的形状 ---
  anytls_upstream='{"protocol":"anytls","server":"up.example.com","server_port":443,"password":"pw","sni":"up.example.com","insecure":false}'
  ss_upstream='{"protocol":"shadowsocks","server":"up.example.com","server_port":8388,"method":"2022-blake3-aes-128-gcm","password":"pw"}'
  sst_upstream='{"protocol":"ss_shadowtls","server":"up.example.com","server_port":443,"method":"2022-blake3-aes-128-gcm","ss_password":"sspw","shadowtls_password":"stpw","sni":"up.example.com","insecure":true}'

  out="$(kernel_split_outbounds demo "$anytls_upstream" mso-demo mpt-demo)"
  jq -e 'length == 1 and .[0] == {name:"mso-demo",type:"anytls",server:"up.example.com",port:443,
    password:"pw",sni:"up.example.com","skip-cert-verify":false,udp:true}' <<<"$out" >/dev/null || {
    echo 'mihomo 的 AnyTLS 上游出口形状不对' >&2; exit 1; }

  out="$(kernel_split_outbounds demo "$ss_upstream" mso-demo mpt-demo)"
  jq -e 'length == 1 and .[0] == {name:"mso-demo",type:"ss",server:"up.example.com",port:8388,
    cipher:"2022-blake3-aes-128-gcm",password:"pw",udp:true}' <<<"$out" >/dev/null || {
    echo 'mihomo 的 Shadowsocks 上游出口形状不对' >&2; exit 1; }

  # ShadowTLS 在 mihomo 客户端一侧是 ss 的插件，一个 proxy 就够；
  # sing-box 侧同一份上游要两个出站。条目数不同这件事必须锁住。
  out="$(kernel_split_outbounds demo "$sst_upstream" mso-demo mpt-demo)"
  jq -e 'length == 1 and .[0] == {name:"mso-demo",type:"ss",server:"up.example.com",port:443,
    cipher:"2022-blake3-aes-128-gcm",password:"sspw",udp:false,plugin:"shadow-tls",
    "plugin-opts":{host:"up.example.com",password:"stpw",version:3,"skip-cert-verify":true}}' <<<"$out" >/dev/null || {
    echo 'mihomo 的 SS2022 + ShadowTLS 上游出口形状不对' >&2; exit 1; }
  ( PROXY_KERNEL=singbox
    out="$(kernel_split_outbounds demo "$sst_upstream" mso-demo mpt-demo)"
    [[ "$(jq 'length' <<<"$out")" == 2 ]] ) || {
    echo '对照失败：sing-box 侧同一份上游应当是两个出站' >&2; exit 1; }

  # ShadowTLS 只承载 TCP，udp 必须是 false；写成 true 是给出上游不提供的承诺。
  # 这一条与上面那条整体比对重复，单独再断言一次是因为它是安全/可用性语义，
  # 将来有人「顺手统一成 true」时要单独变红。
  [[ "$(jq -r '.[0].udp' <<<"$out")" == false ]] || {
    echo 'ShadowTLS 上游出口不得声明支持 UDP' >&2; exit 1; }

  # --- 二、计划渲染 ---
  plan_of() {
    jq -cn --argjson routes "$1" '{outbound_groups:[],rule_sets:[],routes:$routes}'
  }
  rendered="$(kernel_render_split_plan "$(plan_of '[{"rule_set":"mpr-a","outbound":"mpo-a","scope_all":true,"users":[],"inbound":[]}]')")"
  [[ "$(jq -r '.sub_rules[0]' <<<"$rendered")" == 'RULE-SET,mpr-a,mpo-a' ]] || {
    echo '全部用户的分流应当渲染成一条 RULE-SET 规则' >&2; exit 1; }

  rendered="$(kernel_render_split_plan "$(plan_of '[{"rule_set":"mpr-a","outbound":"mpo-a","scope_all":false,"users":["u"],"inbound":["st-u"]}]')")"
  [[ "$(jq -r '.sub_rules[0]' <<<"$rendered")" == 'AND,((RULE-SET,mpr-a),(IN-NAME,st-u)),mpo-a' ]] || {
    echo '单个入口的用户专属分流应当用 IN-NAME 直接限定' >&2; exit 1; }

  # 多个入口必须用 OR 嵌套。IN-NAME,a,b 会被 mihomo 当成「出口叫 b」而报错，
  # 这是实测过的（公开 Issue #186），不能图省事并列。
  rendered="$(kernel_render_split_plan "$(plan_of '[{"rule_set":"mpr-a","outbound":"mpo-a","scope_all":false,"users":["u"],"inbound":["st-u","anytls-u"]}]')")"
  [[ "$(jq -r '.sub_rules[0]' <<<"$rendered")" == 'AND,((RULE-SET,mpr-a),(OR,((IN-NAME,st-u),(IN-NAME,anytls-u)))),mpo-a' ]] || {
    echo '多个入口的用户专属分流应当用 OR 嵌套' >&2; exit 1; }

  # 入口为空的用户专属条目谁都作用不到，而 OR,(()) 这种空集合 mihomo 不接受。
  rendered="$(kernel_render_split_plan "$(plan_of '[{"rule_set":"mpr-a","outbound":"mpo-a","scope_all":false,"users":["u"],"inbound":[]}]')")"
  [[ "$(jq '.sub_rules | length' <<<"$rendered")" == 0 ]] || {
    echo '没有任何入口的用户专属分流不应当被渲染出来' >&2; exit 1; }

  # 名字里带逗号或括号会把一条规则拼成另一条，而 mihomo 只会说「规则类型不支持」。
  if kernel_render_split_plan "$(plan_of '[{"rule_set":"bad,name","outbound":"mpo-a","scope_all":true,"users":[],"inbound":[]}]')" >/dev/null 2>&1; then
    echo '名字里带逗号时渲染必须失败，不能拼出一条坏规则' >&2; exit 1
  fi

  # --- 三、用户入口名：两个内核条目数不同 ---
  printf '%s\n' '{"schema_version":7,"users":[{"name":"u","status":"active","endpoints":[{"protocol":"ss2022","transport":"shadowtls","port":20001}]}],"splits":[],"outbound_presets":[],"rule_presets":[]}' > "$STATE_FILE"
  [[ "$(split_user_inbound_tags u)" == '["st-u"]' ]] || {
    echo 'mihomo 上一个 SS2022 + ShadowTLS 用户只有一个托管入口' >&2; exit 1; }
  ( PROXY_KERNEL=singbox
    [[ "$(split_user_inbound_tags u)" == '["ss-u","ss-udp-u","st-u"]' ]] ) || {
    echo '对照失败：sing-box 上同一个用户应当有三个托管入口' >&2; exit 1; }

  # --- 四、规则文件与写法的核对 ---
  cat > "$work_2d/rules/classical.yaml" <<'EOF'
payload:
  # 从社区抄来的片段
  - DOMAIN-SUFFIX,openai.com
  - 'IP-CIDR,1.2.3.0/24,no-resolve'
EOF
  cat > "$work_2d/rules/domain.yaml" <<'EOF'
payload:
  - '+.openai.com'
  - anthropic.com
EOF
  cat > "$work_2d/rules/ipcidr.yaml" <<'EOF'
payload:
  - 192.168.1.0/24
  - '2001:db8::/32'
EOF
  printf -- '- DOMAIN-SUFFIX,openai.com\n' > "$work_2d/rules/nopayload.yaml"
  printf 'payload:\n' > "$work_2d/rules/empty.yaml"

  # 对照：写法与内容相符时必须一个字都不说，否则这条护栏会变成「狼来了」。
  for pair in classical:classical domain:domain ipcidr:ipcidr; do
    if [[ -n "$(mihomo_rule_file_mismatch "$work_2d/rules/${pair%%:*}.yaml" "${pair##*:}")" ]]; then
      echo "写法相符的规则文件不应当报出不一致：$pair" >&2; exit 1
    fi
  done
  # 错配必须报出来：mihomo 这一侧是完全静默的，报不报只看管理器。
  [[ -n "$(mihomo_rule_file_mismatch "$work_2d/rules/classical.yaml" domain)" ]] || {
    echo '完整规则行按域名列表读时必须报出不一致' >&2; exit 1; }
  [[ -n "$(mihomo_rule_file_mismatch "$work_2d/rules/domain.yaml" classical)" ]] || {
    echo '域名列表按完整规则行读时必须报出不一致' >&2; exit 1; }
  [[ -n "$(mihomo_rule_file_mismatch "$work_2d/rules/domain.yaml" ipcidr)" ]] || {
    echo '域名列表按 IP 段读时必须报出不一致' >&2; exit 1; }
  # 缺 payload 与空 payload 都是 mihomo 一句话都不说、规则完全不生效的情形。
  [[ -n "$(mihomo_rule_file_mismatch "$work_2d/rules/nopayload.yaml" classical)" ]] || {
    echo '没有 payload 键的文件必须报出来' >&2; exit 1; }
  [[ -n "$(mihomo_rule_file_mismatch "$work_2d/rules/empty.yaml" classical)" ]] || {
    echo 'payload 下没有任何规则的文件必须报出来' >&2; exit 1; }

  # --- 五、来源校验 ---
  validate_mihomo_rule_set classical.yaml classical
  for bad in 'classical.yaml:notabehavior' 'nosuchfile.yaml:classical' '../escape.yaml:classical' '.hidden:classical'; do
    if ( validate_mihomo_rule_set "${bad%%:*}" "${bad##*:}" ) >/dev/null 2>&1; then
      echo "无效的规则来源必须被拒绝：$bad" >&2; exit 1
    fi
  done
  ln -sf "$work_2d/rules/classical.yaml" "$work_2d/rules/link.yaml"
  if ( validate_mihomo_rule_set link.yaml classical ) >/dev/null 2>&1; then
    echo '规则文件是符号链接时必须被拒绝' >&2; exit 1
  fi
  rm -f "$work_2d/rules/link.yaml"

  # --- 六、整体重建：管理器只替换自己那几块 ---
  printf '%s\n' '{"schema_version":7,"users":[{"name":"u","status":"active","endpoints":[{"protocol":"ss2022","transport":"shadowtls","port":20001}]}],"splits":[{"name":"s1","rule_file":"classical.yaml","rule_behavior":"classical","scope":"user","user":"u","upstream":{"protocol":"shadowsocks","server":"up.example.com","server_port":8388,"method":"2022-blake3-aes-128-gcm","password":"pw"},"outbound_tag":"s1-out","rule_set_tag":"s1-rule","status":"active"}],"outbound_presets":[],"rule_presets":[]}' > "$STATE_FILE"
  # 使用者自己写在配置里的东西：一个外来 proxy、一个外来 rule-provider、
  # 两条自己的 rules、一个自己的 sub-rule。这些在管理器操作后必须原样保留。
  printf '%s\n' '{"log-level":"info","mode":"rule","listeners":[{"name":"st-u","type":"shadowsocks"}],"proxies":[{"name":"my-own","type":"ss"}],"rule-providers":{"my-list":{"type":"file","behavior":"classical","format":"yaml","path":"./mine.yaml"}},"sub-rules":{"my-block":["MATCH,DIRECT"]},"rules":["DOMAIN-SUFFIX,my.example.com,my-own","MATCH,DIRECT"],"dns":{"enable":false},"my-hand-written-key":123}' > "$MIHOMO_CONFIG"
  rebuild_all_split_configs
  jq -e '
    (.proxies | length) == 2 and
    any(.proxies[]; .name == "my-own") and
    any(.proxies[]; .name == "s1-out" and .type == "ss") and
    (.["rule-providers"] | keys | sort) == ["my-list","s1-rule"] and
    .["rule-providers"]["s1-rule"] == {type:"file",behavior:"classical",format:"yaml",path:$rule_path} and
    .["sub-rules"]["managed-splits"] == ["AND,((RULE-SET,s1-rule),(IN-NAME,st-u)),s1-out"] and
    .["sub-rules"]["my-block"] == ["MATCH,DIRECT"] and
    .rules == ["SUB-RULE,(DST-PORT,0-65535),managed-splits","DOMAIN-SUFFIX,my.example.com,my-own","MATCH,DIRECT"] and
    .dns == {enable:false} and
    .["my-hand-written-key"] == 123
  ' --arg rule_path "$work_2d/rules/classical.yaml" "$MIHOMO_CONFIG" >/dev/null || {
    echo 'mihomo 的分流重建没有正确地只替换管理器自己那几块' >&2; exit 1; }

  # 派发必须在使用者自己的规则**之前**：放在后面时使用者的 MATCH 会把整块盖掉。
  [[ "$(jq -r '.rules[0]' "$MIHOMO_CONFIG")" == 'SUB-RULE,(DST-PORT,0-65535),managed-splits' ]] || {
    echo '托管分流的派发必须排在使用者自己的规则之前' >&2; exit 1; }

  # 再跑一次必须幂等，不能每次都往 rules 里多塞一条派发。
  cp "$MIHOMO_CONFIG" "$work_2d/config.first.json"
  rebuild_all_split_configs
  cmp -s "$work_2d/config.first.json" "$MIHOMO_CONFIG" || {
    echo '重复重建应当得到逐字节相同的配置' >&2; exit 1; }

  # --- 六之二、规则文件被删掉之后不许静静地把流量改走直连 ---
  # 这是 mihomo -t 唯一测不出的一项：文件不在时配置检查照样通过、服务也起得来。
  cp "$MIHOMO_CONFIG" "$work_2d/config.before-missing.json"
  mv "$work_2d/rules/classical.yaml" "$work_2d/rules/classical.away"
  if rebuild_all_split_configs >/dev/null 2>&1; then
    echo '规则文件不存在时，分流重建必须失败而不是照常写出去' >&2; exit 1
  fi
  # 计划在任何改动之前生成，因此失败不得留下改了一半的运行配置。
  cmp -s "$work_2d/config.before-missing.json" "$MIHOMO_CONFIG" || {
    echo '重建失败时不得改动运行配置' >&2; exit 1; }
  mv "$work_2d/rules/classical.away" "$work_2d/rules/classical.yaml"
  rebuild_all_split_configs
  cmp -s "$work_2d/config.before-missing.json" "$MIHOMO_CONFIG" || {
    echo '对照失败：文件放回去之后应当重新生成出同一份配置' >&2; exit 1; }

  # --- 七、没有启用中的分流时不留残骸 ---
  # 一条指向已不存在 sub-rule 的派发会让 mihomo 直接拒绝加载配置，
  # 那等于把机器停在起不来的状态上。
  jq -c '.splits[0].status = "disabled"' "$STATE_FILE" > "$work_2d/state.tmp" && mv "$work_2d/state.tmp" "$STATE_FILE"
  rebuild_all_split_configs
  jq -e '
    (.rules == ["DOMAIN-SUFFIX,my.example.com,my-own","MATCH,DIRECT"]) and
    ((.["sub-rules"] // {}) | has("managed-splits") | not) and
    (.["sub-rules"]["my-block"] == ["MATCH,DIRECT"]) and
    ((.["rule-providers"] | keys) == ["my-list"]) and
    ((.proxies | length) == 1 and .proxies[0].name == "my-own")
  ' "$MIHOMO_CONFIG" >/dev/null || {
    echo '分流全部停用后，管理器的派发、sub-rule、规则集与出口都必须撤干净' >&2; exit 1; }

  # --- 八、单条删除 ---
  jq -c '.splits[0].status = "active"' "$STATE_FILE" > "$work_2d/state.tmp" && mv "$work_2d/state.tmp" "$STATE_FILE"
  rebuild_all_split_configs
  remove_split_config s1
  jq -e '
    (all(.proxies[]; .name != "s1-out")) and
    ((.["rule-providers"] | has("s1-rule")) | not) and
    (.["sub-rules"]["managed-splits"] == []) and
    (.["sub-rules"]["my-block"] == ["MATCH,DIRECT"]) and
    any(.proxies[]; .name == "my-own")
  ' "$MIHOMO_CONFIG" >/dev/null || {
    echo '单条分流删除必须只拿掉自己那几处' >&2; exit 1; }

  # --- 九、状态里存的键名随内核不同 ---
  printf '%s\n' '{"schema_version":7,"users":[],"splits":[],"outbound_presets":[],"rule_presets":[]}' > "$STATE_FILE"
  atomic_state_update() { jq -c "$1" "${@:2}" "$STATE_FILE" > "$work_2d/state.tmp" && mv "$work_2d/state.tmp" "$STATE_FILE"; }
  state_add_rule_preset demo classical.yaml classical
  jq -e '.rule_presets[0] | .rule_file == "classical.yaml" and .rule_behavior == "classical" and (has("url") | not)' "$STATE_FILE" >/dev/null || {
    echo 'mihomo 上的预置规则必须存成 rule_file 加写法' >&2; exit 1; }
  ( PROXY_KERNEL=singbox
    printf '%s\n' '{"schema_version":7,"users":[],"splits":[],"outbound_presets":[],"rule_presets":[]}' > "$STATE_FILE"
    state_add_rule_preset demo https://example.com/a.srs ''
    jq -e '.rule_presets[0] | .url == "https://example.com/a.srs" and (has("rule_file") | not) and (has("rule_behavior") | not)' "$STATE_FILE" >/dev/null ) || {
    echo '对照失败：sing-box 上的预置规则必须仍然只存 url' >&2; exit 1; }
)

# ============================================================
# 第二步 2e：审计与一致性检查的 mihomo 侧
# ============================================================
# 这一组的第一条是「生成与审计是否同步」：夹具不是手写的运行配置，而是用
# **生成函数**按状态算出来的。将来谁改了生成的形状而没有跟着改审计的断言，
# 这一条会当场变红——这是 #189 里定下的做法，用它换掉「审计整体比对」那条路，
# 好处留下（不脱节），噪声留在测试里而不是跑到使用者面前。
(
  work_2e="$work/mihomo-audit"
  mkdir -p "$work_2e/rules"
  PROXY_KERNEL=mihomo
  MIHOMO_CONFIG="$work_2e/config.json"
  MIHOMO_RULES_DIR="$work_2e/rules"
  STATE_FILE="$work_2e/state.json"
  HANDSHAKE_PORT=443
  SHADOWTLS_STRICT_MODE=true
  # 这一组有一个旧版 ShadowTLS 用户，握手目标预检（公开 Issue #194）因此会命中。
  # 单元测试不碰网络：在这里打桩，预检自己的判定由下面单独一组用 timeout 打桩覆盖。
  probe_handshake_tls13() { printf 'tls13\n'; }
  cat > "$work_2e/rules/lab.yaml" <<'YAML'
payload:
  - DOMAIN-SUFFIX,openai.com
YAML
  printf '%s\n' '{
    "schema_version":7,
    "users":[
      {"name":"shadow","status":"active","metered":false,
       "endpoints":[{"protocol":"ss2022","transport":"shadowtls","port":20001,
                     "shadowtls_password":"stpw","ss2022_password":"sspw",
                     "method":"2022-blake3-aes-128-gcm","shadowtls_sni":"a.example.com"}]},
      {"name":"plain","status":"active","metered":false,
       "endpoints":[{"protocol":"ss2022","transport":"direct","port":20002,
                     "ss2022_password":"sspw2","method":"2022-blake3-aes-128-gcm"}]}
    ],
    "splits":[{"name":"s1","rule_file":"lab.yaml","rule_behavior":"classical","scope":"user","user":"shadow",
               "upstream":{"protocol":"shadowsocks","server":"up.example.com","server_port":8388,
                           "method":"2022-blake3-aes-128-gcm","password":"pw"},
               "outbound_tag":"s1-out","rule_set_tag":"s1-rule","status":"active"}],
    "outbound_presets":[],"rule_presets":[]}' > "$STATE_FILE"
  printf '%s\n' '{"log-level":"info","mode":"rule","listeners":[],"proxies":[],"proxy-groups":[],"rules":[]}' > "$MIHOMO_CONFIG"
  nfuse() {
    [[ "${1:-}" == list && "${2:-}" == --json ]] || return 1
    printf '%s\n' '[{"name":"shadow","tier":"c","ports":[{"start":20001,"end":20001}]},
                    {"name":"plain","tier":"c","ports":[{"start":20002,"end":20002}]}]'
  }
  # 用生成函数把托管内容写进配置——这一步是本组测试的基准。
  rebuild_protocol_inbounds ss2022
  rebuild_all_split_configs
  cp "$MIHOMO_CONFIG" "$work_2e/config.good.json"

  audit_consistency > "$work_2e/audit.clean"
  if [[ "$AUDIT_ISSUES" != 0 ]]; then
    echo '生成函数产出的 mihomo 配置必须让审计报零问题；生成与审计已经脱节：' >&2
    cat "$work_2e/audit.clean" >&2
    exit 1
  fi

  # 逐条先破坏再确认变红。每一条都从同一份干净配置出发，避免互相干扰。
  break_and_expect() {
    local label="$1" filter="$2" expect="$3" expect_count="${4:-1}"
    cp "$work_2e/config.good.json" "$MIHOMO_CONFIG"
    jq -c "$filter" "$work_2e/config.good.json" > "$MIHOMO_CONFIG.tmp" && mv "$MIHOMO_CONFIG.tmp" "$MIHOMO_CONFIG"
    audit_consistency > "$work_2e/audit.broken"
    if [[ "$AUDIT_ISSUES" != "$expect_count" ]]; then
      printf '破坏「%s」之后期望报 %s 个问题，实际 %s 个：\n' "$label" "$expect_count" "$AUDIT_ISSUES" >&2
      cat "$work_2e/audit.broken" >&2
      exit 1
    fi
    if ! grep -Fq "$expect" "$work_2e/audit.broken"; then
      printf '破坏「%s」之后没有报出预期的那一条（%s）：\n' "$label" "$expect" >&2
      cat "$work_2e/audit.broken" >&2
      exit 1
    fi
  }

  # 条目整个不见时，「缺少连接配置」与「形状不对」会各报一条——
  # 与 sing-box 侧的行为一致，那边的形状断言同样在条目缺失时成立。
  break_and_expect '删掉一个监听器' \
    '.listeners = [.listeners[] | select(.name != "ss-plain")]' \
    '[可自动修复] 用户 plain 缺少连接配置（ss-plain）' 2
  break_and_expect '把原生 SS2022 的端口改错' \
    '.listeners |= map(if .name == "ss-plain" then .port = 29999 else . end)' \
    '[可自动修复] 用户 plain 的原生 SS2022 连接配置不正确'
  break_and_expect '把 ShadowTLS 监听器的 udp 关掉' \
    '.listeners |= map(if .name == "st-shadow" then .udp = false else . end)' \
    '[可自动修复] 用户 shadow 的 SS2022 + ShadowTLS 连接配置不正确'
  # 这一条是 mihomo 最容易静默失效的字段：键名写错时它会被丢掉、严格模式悄悄关掉。
  break_and_expect '把 ShadowTLS 严格模式改掉' \
    '.listeners |= map(if .name == "st-shadow" then .["shadow-tls"]["strict-mode"] = false else . end)' \
    '[可自动修复] 用户 shadow 的 ShadowTLS 严格模式与管理配置不一致'
  break_and_expect '给原生 SS2022 挂上 shadow-tls' \
    '.listeners |= map(if .name == "ss-plain" then .["shadow-tls"] = {"enable":true} else . end)' \
    '[可自动修复] 用户 plain 的原生 SS2022 连接配置不正确'
  break_and_expect '删掉规则集' \
    'del(.["rule-providers"][(.["rule-providers"]|keys[0])])' \
    '[可自动修复] 分流 s1 的规则或出口配置不完整'
  break_and_expect '删掉出口' \
    '.proxies = []' \
    '[可自动修复] 分流 s1 的规则或出口配置不完整'
  # 派发被删掉时整块分流一条都不生效，而配置本身完全合法、服务照常运行。
  break_and_expect '删掉顶层那条派发' \
    '.rules = []' \
    '[可自动修复] 托管分流的派发规则与分流内容不一致'

  # 覆盖不全：把用户专属那一行换成不限入口的写法，规则集与出口都还在，
  # 因此「配置完不完整」不该报，只该报「尚未覆盖用户的全部连接」。
  cp "$work_2e/config.good.json" "$MIHOMO_CONFIG"
  jq -c '.["sub-rules"]["managed-splits"] = ["RULE-SET,s1-rule,s1-out"]' "$work_2e/config.good.json" > "$MIHOMO_CONFIG.tmp"
  mv "$MIHOMO_CONFIG.tmp" "$MIHOMO_CONFIG"
  audit_consistency > "$work_2e/audit.coverage"
  if ! grep -Fq '[可自动修复] 分流 s1 尚未覆盖用户 shadow 的全部连接' "$work_2e/audit.coverage" ||
     [[ "$AUDIT_ISSUES" != 1 ]]; then
    echo '用户专属分流退化成不限入口时必须报出「尚未覆盖用户的全部连接」' >&2
    cat "$work_2e/audit.coverage" >&2
    exit 1
  fi

  # 已停用的分流不该还留着规则。
  cp "$work_2e/config.good.json" "$MIHOMO_CONFIG"
  jq -c '.splits[0].status = "disabled"' "$STATE_FILE" > "$work_2e/state.tmp" && mv "$work_2e/state.tmp" "$STATE_FILE"
  audit_consistency > "$work_2e/audit.disabled"
  if ! grep -Fq '[可自动修复] 已停用分流 s1 仍有连接规则生效' "$work_2e/audit.disabled"; then
    echo '已停用的分流仍有规则时必须报出来' >&2
    cat "$work_2e/audit.disabled" >&2
    exit 1
  fi
  # 对照：按状态重建之后，同一份状态必须报零问题。
  rebuild_all_split_configs
  audit_consistency > "$work_2e/audit.disabled-clean"
  if [[ "$AUDIT_ISSUES" != 0 ]]; then
    echo '对照失败：分流停用并重建之后审计应当报零问题' >&2
    cat "$work_2e/audit.disabled-clean" >&2
    exit 1
  fi

  # 审计的 jq 调用次数不得随用户数增长。sing-box 侧那条门禁锁的是一个具体数字，
  # 这里换成「加两个用户，次数一个不变」——数字会随分流条数变，而真正要防住的
  # 是「有人把用户检查拆成逐用户一次调用」这件事，这条写法直接说的就是它。
  cp "$work_2e/config.good.json" "$MIHOMO_CONFIG"
  jq -c '.splits[0].status = "active"' "$STATE_FILE" > "$work_2e/state.tmp" && mv "$work_2e/state.tmp" "$STATE_FILE"
  audit_call_count() {
    local marker="$1"
    : > "$marker"
    jq() { printf 'jq\n' >> "$marker"; command jq "$@"; }
    audit_consistency > /dev/null
    unset -f jq
    wc -l < "$marker" | tr -d ' '
  }
  two_user_calls="$(audit_call_count "$work_2e/calls.two")"
  jq -c '.users += [
    {name:"extra1",status:"active",metered:false,endpoints:[{protocol:"ss2022",transport:"direct",port:20011,ss2022_password:"x",method:"2022-blake3-aes-128-gcm"}]},
    {name:"extra2",status:"active",metered:false,endpoints:[{protocol:"ss2022",transport:"direct",port:20012,ss2022_password:"y",method:"2022-blake3-aes-128-gcm"}]}]' \
    "$STATE_FILE" > "$work_2e/state.tmp" && mv "$work_2e/state.tmp" "$STATE_FILE"
  nfuse() {
    [[ "${1:-}" == list && "${2:-}" == --json ]] || return 1
    printf '%s\n' '[{"name":"shadow","tier":"c","ports":[{"start":20001,"end":20001}]},
                    {"name":"plain","tier":"c","ports":[{"start":20002,"end":20002}]},
                    {"name":"extra1","tier":"c","ports":[{"start":20011,"end":20011}]},
                    {"name":"extra2","tier":"c","ports":[{"start":20012,"end":20012}]}]'
  }
  rebuild_protocol_inbounds ss2022
  four_user_calls="$(audit_call_count "$work_2e/calls.four")"
  if [[ "$two_user_calls" != "$four_user_calls" ]]; then
    printf '审计的 jq 调用次数随用户数增长了：两个用户 %s 次，四个用户 %s 次\n' \
      "$two_user_calls" "$four_user_calls" >&2
    exit 1
  fi

  # 骨架检查：mihomo 侧不能套用 sing-box 那条「空容器不报」的排除，
  # 否则一台丢了 listeners 的机器会被说成一切正常（公开 Issue #189 有实测）。
  printf '%s\n' '{"schema_version":7,"users":[],"splits":[],"outbound_presets":[],"rule_presets":[]}' > "$STATE_FILE"
  printf '%s\n' '{"log-level":"info","mode":"rule","proxies":[],"proxy-groups":[],"rules":[]}' > "$MIHOMO_CONFIG"
  nfuse() { [[ "${1:-}" == list && "${2:-}" == --json ]] || return 1; printf '[]\n'; }
  audit_consistency > "$work_2e/audit.skeleton"
  if ! grep -Fq '[需要处理] 运行配置缺少骨架项 listeners' "$work_2e/audit.skeleton"; then
    echo 'mihomo 上丢掉 listeners 必须报成骨架缺项，不能被「空容器不报」放过' >&2
    cat "$work_2e/audit.skeleton" >&2
    exit 1
  fi
  # 对照：补回去之后不再报。
  printf '%s\n' '{"log-level":"info","mode":"rule","listeners":[],"proxies":[],"proxy-groups":[],"rules":[]}' > "$MIHOMO_CONFIG"
  audit_consistency > "$work_2e/audit.skeleton-clean"
  if [[ "$AUDIT_ISSUES" != 0 ]]; then
    echo '对照失败：骨架完整的空 mihomo 配置应当报零问题' >&2
    cat "$work_2e/audit.skeleton-clean" >&2
    exit 1
  fi
)

# ============================================================
# 服务单元漂移的检查与修复（公开 Issue #190）
# ============================================================
# 单元只在部署、接管与「修复缺失内容」三条路径上写出，升级脚本从来不刷新它们。
# 因此新版本改了单元内容时，存量机器会静静地落在旧单元上。这一组锁住三件事：
# 一致时不报（否则每台正常机器天天喊）、四个单元各自改一处都报得出来、
# 以及识别不出网络接口时说「未能核对」而不是说「不一致」。
(
  unit_root="$work/unit-drift"
  mkdir -p "$unit_root/etc/systemd/system"
  SB_SYSTEM_ROOT="$unit_root"
  PROXY_KERNEL=singbox
  STATE_FILE="$work/unit-drift-state.json"
  SINGBOX_CONFIG="$work/unit-drift-config.json"
  SINGBOX_BIN=unit_drift_singbox
  unit_drift_singbox() {
    [[ "${1:-}" == format && "${2:-}" == -c && "${3:-}" == "$SINGBOX_CONFIG" ]] || return 1
    command cat "$SINGBOX_CONFIG"
  }
  nfuse() { [[ "${1:-}" == list && "${2:-}" == --json ]] || return 1; printf '[]\n'; }
  default_network_interface() { printf 'eth0\n'; }
  printf '%s\n' '{"schema_version":7,"users":[],"splits":[],"outbound_presets":[],"rule_presets":[]}' > "$STATE_FILE"
  printf '%s\n' '{"inbounds":[],"outbounds":[],"route":{"rule_set":[],"rules":[]}}' > "$SINGBOX_CONFIG"
  apply_skeleton_to_test_config
  write_systemd_units eth0

  # 对照：单元与生成结果一致时一个字都不该说。
  audit_consistency > "$work/unit-drift-clean"
  if [[ "$AUDIT_ISSUES" != 0 ]]; then
    echo '单元与当前版本一致时，审计不得报出任何东西' >&2
    cat "$work/unit-drift-clean" >&2
    exit 1
  fi

  # 四个单元逐个改一处，每次都必须精确报出被改的那一个。
  # 漏掉任何一个就意味着它永远不会被核对到——这正是 Issue #190 要防的事。
  while IFS= read -r unit_path; do
    [[ -n "$unit_path" ]] || continue
    printf '# drifted\n' >> "$unit_root$unit_path"
    audit_consistency > "$work/unit-drift-broken"
    if [[ "$AUDIT_ISSUES" != 1 ]] ||
       ! grep -Fq "[可自动修复] 服务单元 $unit_path 与当前版本不一致" "$work/unit-drift-broken"; then
      printf '改动单元 %s 之后审计必须精确报出它：\n' "$unit_path" >&2
      cat "$work/unit-drift-broken" >&2
      exit 1
    fi
    write_systemd_units eth0
  done <<<"$(managed_unit_paths)"

  # 单元整个不见时同样要报——只要机器上还有别的托管单元在，就说明这台机器是
  # 部署过的，那个不见的就是真缺项。
  rm -f "$unit_root/etc/systemd/system/nfuse.service"
  audit_consistency > "$work/unit-drift-missing"
  if ! grep -Fq '[可自动修复] 服务单元 /etc/systemd/system/nfuse.service 与当前版本不一致' "$work/unit-drift-missing"; then
    echo '单元文件缺失时必须报出来' >&2
    cat "$work/unit-drift-missing" >&2
    exit 1
  fi
  write_systemd_units eth0

  # 但一个托管单元都没有时必须安静：那不是漂移，是没部署，由环境分类那一侧管。
  # 不这样分，任何没有部署环境的场合都会被刷一屏「单元与当前版本不一致」，
  # 把真正的问题淹掉。
  rm -f "$unit_root/etc/systemd/system/"*.service "$unit_root/etc/systemd/system/"*.timer
  audit_consistency > "$work/unit-drift-none"
  if [[ "$AUDIT_ISSUES" != 0 ]]; then
    echo '一个托管单元都没有时，单元核对必须安静' >&2
    cat "$work/unit-drift-none" >&2
    exit 1
  fi
  write_systemd_units eth0

  # 识别不出默认网络接口时，说的必须是「未能核对」而不是「不一致」——
  # 把「不知道」说成「不一致」会让人去修一个并不存在的问题。
  default_network_interface() { return 1; }
  audit_consistency > "$work/unit-drift-noiface"
  if ! grep -Fq '[需要处理] 无法识别默认网络接口，未能核对服务单元' "$work/unit-drift-noiface" ||
     grep -Fq '与当前版本不一致' "$work/unit-drift-noiface"; then
    echo '识别不出网络接口时必须说「未能核对」，不得报成不一致' >&2
    cat "$work/unit-drift-noiface" >&2
    exit 1
  fi
  default_network_interface() { printf 'eth0\n'; }

  # 核对清单必须随内核变：两个内核的内核服务单元不是同一个文件。
  singbox_units="$(managed_unit_paths)"
  mihomo_units="$(PROXY_KERNEL=mihomo; managed_unit_paths)"
  if [[ "$singbox_units" == "$mihomo_units" ]] ||
     ! grep -Fxq /etc/systemd/system/sing-box.service <<<"$singbox_units" ||
     ! grep -Fxq /etc/systemd/system/mihomo.service <<<"$mihomo_units"; then
    echo '要核对的单元清单必须随内核变，且各自包含自己的内核服务单元' >&2
    exit 1
  fi
)

# ============================================================
# ShadowTLS 握手目标的 TLS 1.3 预检（公开 Issue #194）
# ============================================================
# 三件事分开锁：探测函数怎么判、什么时候才该探、探出问题之后审计与改 SNI 各自
# 怎么表现。探测函数自己不碰网络——timeout 打桩，因此这一组在没有出网的机器上
# 也是确定性的。
(
  probe_work="$work/handshake-probe"
  mkdir -p "$probe_work"

  # ---- 一、探测函数的判定 ----
  probe_openssl_output=""
  probe_tcp_rc=1
  timeout() {
    shift  # 秒数
    case "${1:-}" in
      openssl) printf '%s\n' "$probe_openssl_output"; return 0;;
      bash) return "$probe_tcp_rc";;
      *) return 127;;
    esac
  }
  expect_probe() {
    local label="$1" want="$2" got
    got="$(probe_handshake_tls13 hs.example.com 443)"
    [[ "$got" == "$want" ]] || {
      printf '握手目标预检「%s」：期望 %s，实际 %s\n' "$label" "$want" "$got" >&2
      exit 1
    }
  }
  probe_openssl_output='CONNECTION ESTABLISHED
Protocol version: TLSv1.3
Ciphersuite: TLS_AES_256_GCM_SHA384'
  expect_probe '握手目标说 TLS 1.3' tls13
  probe_openssl_output='CONNECTION ESTABLISHED
Protocol version: TLSv1.2'
  expect_probe '握手目标只说 TLS 1.2' tls-older
  # 不是 TLS 的服务：openssl 什么版本都协商不出来，再看 TCP 通不通。
  probe_openssl_output='40E7C4A7A87F0000:error:0A00010B:SSL routines:tls_validate_record_header:wrong version number'
  probe_tcp_rc=0
  expect_probe '端口上不是 TLS 服务' not-tls
  probe_tcp_rc=1
  expect_probe '连 TCP 都连不上' unreachable
  # 非法域名不做任何网络动作，直接说不合法。
  if [[ "$(probe_handshake_tls13 'bad host' 443)" != invalid ]] ||
     [[ "$(probe_handshake_tls13 hs.example.com 44a)" != invalid ]]; then
    echo '域名或端口不合法时，预检必须返回 invalid' >&2
    exit 1
  fi
  unset -f timeout

  # ---- 二、什么时候才该探 ----
  STATE_FILE="$probe_work/state.json"
  printf '%s\n' '{"schema_version":7,"users":[
    {"name":"legacy","status":"active","metered":false,
     "endpoints":[{"protocol":"ss2022","transport":"shadowtls","port":20001,
                   "shadowtls_password":"stpw","ss2022_password":"sspw",
                   "method":"2022-blake3-aes-128-gcm","shadowtls_sni":"a.example.com"}]}],
    "splits":[],"outbound_presets":[],"rule_presets":[]}' > "$STATE_FILE"
  SHADOWTLS_STRICT_MODE=true
  if ! ( PROXY_KERNEL=mihomo; shadowtls_handshake_probe_applies ); then
    echo 'mihomo + 严格模式开 + 有旧版 ShadowTLS 用户时必须探' >&2
    exit 1
  fi
  # 要探的是状态里真正在用的握手目标，去重后逐个；管理配置里的默认值不参与。
  if [[ "$(active_shadowtls_handshake_hosts)" != a.example.com ]]; then
    printf '实际在用的握手目标应当是 a.example.com，得到：%s\n' "$(active_shadowtls_handshake_hosts)" >&2
    exit 1
  fi
  # 三个对照：换成 sing-box、关掉严格模式、没有旧版用户，都不该探。
  if ( PROXY_KERNEL=singbox; shadowtls_handshake_probe_applies ); then
    echo 'sing-box 部署不做这条预检（项目方向是放弃 sing-box）' >&2
    exit 1
  fi
  if ( PROXY_KERNEL=mihomo; SHADOWTLS_STRICT_MODE=false; shadowtls_handshake_probe_applies ); then
    echo '严格模式关着时握手目标不支持 TLS 1.3 也不影响连接，不该探' >&2
    exit 1
  fi
  printf '%s\n' '{"schema_version":7,"users":[],"splits":[],"outbound_presets":[],"rule_presets":[]}' \
    > "$probe_work/state-empty.json"
  if ( PROXY_KERNEL=mihomo; STATE_FILE="$probe_work/state-empty.json"; shadowtls_handshake_probe_applies ); then
    echo '没有旧版 ShadowTLS 用户时这条检查恒真，不该探' >&2
    exit 1
  fi

  # ---- 三、审计在四种探测结果下的表现 ----
  audit_work="$probe_work/audit"
  mkdir -p "$audit_work/rules"
  PROXY_KERNEL=mihomo
  MIHOMO_CONFIG="$audit_work/config.json"
  MIHOMO_RULES_DIR="$audit_work/rules"
  # 刻意把管理配置里的默认域名设成另一个值：监听器是按**用户状态里的**
  # shadowtls_sni 生成的，预检也必须问那一个。下面的断言都盯 a.example.com，
  # 如果哪天改成读管理配置，这一组会立刻变红。
  SS2022_SHADOWTLS_SNI=default.example.com
  HANDSHAKE_PORT=443
  SB_SYSTEM_ROOT="$audit_work/system"
  mkdir -p "$SB_SYSTEM_ROOT/etc/systemd/system"
  default_network_interface() { printf 'eth0\n'; }
  nfuse() {
    [[ "${1:-}" == list && "${2:-}" == --json ]] || return 1
    printf '%s\n' '[{"name":"legacy","tier":"c","ports":[{"start":20001,"end":20001}]}]'
  }
  printf '%s\n' '{"log-level":"info","mode":"rule","listeners":[],"proxies":[],"proxy-groups":[],"rules":[]}' > "$MIHOMO_CONFIG"
  rebuild_protocol_inbounds ss2022
  write_systemd_units eth0

  expect_audit() {
    local label="$1" status="$2" want_issues="$3" want_line="$4"
    probe_handshake_tls13() { printf '%s\n' "$status"; }
    audit_consistency > "$audit_work/audit.$status"
    if [[ "$AUDIT_ISSUES" != "$want_issues" ]]; then
      printf '探测结果为 %s（%s）时期望 %s 个问题，实际 %s：\n' "$status" "$label" "$want_issues" "$AUDIT_ISSUES" >&2
      cat "$audit_work/audit.$status" >&2
      exit 1
    fi
    if [[ -n "$want_line" ]] && ! grep -Fq "$want_line" "$audit_work/audit.$status"; then
      printf '探测结果为 %s 时，输出里应当出现「%s」：\n' "$status" "$want_line" >&2
      cat "$audit_work/audit.$status" >&2
      exit 1
    fi
  }
  # 对照放在最前面：握手目标正常时这条检查一个字都不说，否则每台正常机器天天喊。
  expect_audit '握手目标正常' tls13 0 ''
  if grep -q '握手目标' "$audit_work/audit.tls13"; then
    echo '握手目标支持 TLS 1.3 时，审计不得提到它' >&2
    cat "$audit_work/audit.tls13" >&2
    exit 1
  fi
  expect_audit '只说 TLS 1.2' tls-older 1 '[需要处理] ShadowTLS 握手目标 a.example.com:443 不支持 TLS 1.3'
  expect_audit '不是 TLS 服务' not-tls 1 '[需要处理] ShadowTLS 握手目标 a.example.com:443 上不是 TLS 服务'
  expect_audit '握手目标不合法' invalid 1 '[需要处理] ShadowTLS 握手目标不合法'
  # 探不通会自愈，因此标记但不计为问题：计成问题会让一次网络抖动挡住写入型验收。
  expect_audit '网络探不通' unreachable 0 '[提示] 这次没能连上 ShadowTLS 握手目标 a.example.com:443'

  # ---- 四、改 SNI 时，明确的问题必须拦住且不动任何东西 ----
  sni_marker="$probe_work/managed-operation-started"
  start_managed_operation() { printf 'started\n' > "$sni_marker"; return 1; }
  ensure_safe_ssh_for_kernel_restart() { return 0; }
  for bad in tls-older not-tls invalid; do
    rm -f "$sni_marker"
    probe_handshake_tls13() { printf '%s\n' "$bad"; }
    if cmd_set_global_sni ss2022 b.example.com > "$probe_work/sni.$bad" 2>&1; then
      printf '探测结果为 %s 时，改 SNI 必须失败\n' "$bad" >&2
      exit 1
    fi
    if [[ -f "$sni_marker" ]]; then
      printf '探测结果为 %s 时，改 SNI 必须在动任何东西之前就停下\n' "$bad" >&2
      exit 1
    fi
  done
  # 对照：网络探不通只提示不拦，流程照常往下走（这里在取锁那一步被桩挡住）。
  rm -f "$sni_marker"
  probe_handshake_tls13() { printf 'unreachable\n'; }
  cmd_set_global_sni ss2022 b.example.com > "$probe_work/sni.unreachable" 2>&1 || true
  if [[ ! -f "$sni_marker" ]]; then
    echo '网络探不通时不应拦住修改，应当继续往下走' >&2
    cat "$probe_work/sni.unreachable" >&2
    exit 1
  fi
  if ! grep -Fq '未能确认它是否支持 TLS 1.3' "$probe_work/sni.unreachable"; then
    echo '网络探不通时必须明确说出「未能确认」，不能默默放过' >&2
    cat "$probe_work/sni.unreachable" >&2
    exit 1
  fi
)

# ============================================================
# 规则集从 sing-box 转到 mihomo（公开 Issue #203）
# ============================================================
# 这一组盯三件事：五类字段转得对、表达不了的字段一定拒绝、拒绝时不留半个文件。
# 「转得对」里有三条是真机实测定下来的写法（IP 段必须带前缀长度、IP-CIDR 对
# IPv6 同样有效、DOMAIN-REGEX 可用），改坏了这里会红。
(
  conv="$work/rule-convert"
  mkdir -p "$conv"
  MIHOMO_RULES_DIR="$conv/rules"
  mkdir -p "$MIHOMO_RULES_DIR"

  cat > "$conv/full.json" <<'JSON'
{"version":1,"rules":[
  {"domain":["a.example.com"],
   "domain_suffix":[".b.example.com","c.example.com"],
   "domain_keyword":"kw",
   "domain_regex":"^x.*\\.example\\.com$",
   "ip_cidr":["192.0.2.0/24","198.51.100.7","2001:db8::/32","2001:db8::1"]}
]}
JSON
  singbox_rule_set_json_to_mihomo_yaml "$conv/full.json" "$conv/full.yaml" || {
    echo '五类字段齐备的规则集必须转得出来' >&2
    exit 1
  }
  cat > "$conv/full.expected" <<'YAML'
payload:
  - DOMAIN,a.example.com
  - DOMAIN-SUFFIX,b.example.com
  - DOMAIN-SUFFIX,c.example.com
  - DOMAIN-KEYWORD,kw
  - DOMAIN-REGEX,^x.*\.example\.com$
  - IP-CIDR,192.0.2.0/24
  - IP-CIDR,198.51.100.7/32
  - IP-CIDR,2001:db8::/32
  - IP-CIDR,2001:db8::1/128
YAML
  if ! diff -u "$conv/full.expected" "$conv/full.yaml"; then
    echo '转换结果与期望不符' >&2
    exit 1
  fi
  # 产物必须通过运行时那条护栏（转换器写错了要在这里红，不是等机器上线之后）
  if [[ -n "$(mihomo_rule_file_mismatch "$conv/full.yaml" classical)" ]]; then
    echo '转换产物没通过 classical 写法自检' >&2
    exit 1
  fi

  # 表达不了的字段：逐个确认都会被拒绝，并且拒绝时不写出文件。
  reject_case() {
    local label="$1" json="$2" expect_key="$3"
    printf '%s\n' "$json" > "$conv/bad.json"
    rm -f "$conv/bad.yaml"
    if singbox_rule_set_json_to_mihomo_yaml "$conv/bad.json" "$conv/bad.yaml" 2>"$conv/bad.err"; then
      printf '含 %s 的规则集必须被拒绝\n' "$label" >&2
      exit 1
    fi
    if [[ -n "$expect_key" ]] && ! grep -Fq "$expect_key" "$conv/bad.err"; then
      printf '拒绝 %s 时要说出是哪个字段，实际输出：%s\n' "$label" "$(cat "$conv/bad.err")" >&2
      exit 1
    fi
    if [[ -e "$conv/bad.yaml" ]]; then
      printf '拒绝 %s 时不得写出文件\n' "$label" >&2
      exit 1
    fi
  }
  reject_case '端口' '{"version":1,"rules":[{"domain":["a.com"],"port":[443]}]}' port
  reject_case '进程名' '{"version":1,"rules":[{"domain":["a.com"],"process_name":["curl"]}]}' process_name
  reject_case '网络类型' '{"version":1,"rules":[{"domain":["a.com"],"network":["udp"]}]}' network
  reject_case '来源地址' '{"version":1,"rules":[{"domain":["a.com"],"source_ip_cidr":["10.0.0.0/8"]}]}' source_ip_cidr
  reject_case '取反' '{"version":1,"rules":[{"domain":["a.com"],"invert":true}]}' invert
  reject_case '逻辑规则' '{"version":1,"rules":[{"type":"logical","mode":"and","rules":[{"domain":["a.com"]}]}]}' type
  # 字段名必须**精确**匹配：jq 的 inside/contains 是子串语义，用它的话
  # 一个叫 ip 的字段会被误当成 ip_cidr 的一部分放过去。
  reject_case '子串型字段名' '{"version":1,"rules":[{"domain":["a.com"],"ip":["192.0.2.1"]}]}' ip
  # 这两条要盯住**是哪条守卫**拒绝的：转换器自己那句「没有可以转换的规则」比
  # 产物自检那句「payload 下面一条规则都没有」说得清楚，去掉它两条都还会被拒绝，
  # 只断言「被拒绝」的话就分不出来。
  reject_case '空规则集' '{"version":1,"rules":[]}' '没有可以转换的规则'
  reject_case '一条规则都转不出来' '{"version":1,"rules":[{"domain":[]}]}' '没有可以转换的规则'

  # 文件名：同一地址稳定、不同地址不撞、且一定是合法的规则文件名。
  name_a="$(migrated_rule_file_name https://example.com/rule-set/geosite-openai.srs)"
  name_a2="$(migrated_rule_file_name https://example.com/rule-set/geosite-openai.srs)"
  name_b="$(migrated_rule_file_name https://example.com/other/geosite-openai.srs)"
  name_c="$(migrated_rule_file_name 'https://example.com/a/b/../weird name!.json?x=1')"
  [[ "$name_a" == "$name_a2" ]] || { echo '同一个地址应当算出同一个文件名' >&2; exit 1; }
  [[ "$name_a" != "$name_b" ]] || { echo '不同地址不得算出同一个文件名' >&2; exit 1; }
  [[ "$name_a" == geosite-openai-*.yaml ]] || { printf '文件名应当保留来源的可读部分：%s\n' "$name_a" >&2; exit 1; }
  for candidate in "$name_a" "$name_b" "$name_c"; do
    ( validate_mihomo_rule_file_name "$candidate" ) || {
      printf '算出来的文件名必须是合法的规则文件名：%s\n' "$candidate" >&2
      exit 1
    }
  done

  # 取来源：.json 直接用，.srs 走本机 sing-box 反编译，非 HTTPS 与结构不对都要拒绝。
  validate_public_rule_set_url() { [[ "$1" == https://* ]]; }
  curl() {
    local target=""
    while (($#)); do
      [[ "${1:-}" != --output ]] || { target="$2"; shift; }
      shift
    done
    printf '%s\n' "$fetch_payload" > "$target"
  }
  kernel_rule_set_decompile() {
    printf '%s\n' "$decompiled_payload" > "$3"
  }
  fetch_payload='{"version":1,"rules":[{"domain":["json.example.com"]}]}'
  decompiled_payload='{"version":1,"rules":[{"domain":["srs.example.com"]}]}'
  fetch_singbox_rule_set_json https://example.com/x.json "$conv/fetched.json" || {
    echo '.json 来源应当直接可用' >&2; exit 1
  }
  grep -Fq json.example.com "$conv/fetched.json" || { echo '.json 来源的内容不对' >&2; exit 1; }
  fetch_singbox_rule_set_json https://example.com/x.srs "$conv/fetched-srs.json" || {
    echo '.srs 来源应当经反编译得到' >&2; exit 1
  }
  grep -Fq srs.example.com "$conv/fetched-srs.json" || { echo '.srs 来源的内容不对' >&2; exit 1; }
  if fetch_singbox_rule_set_json http://example.com/x.json "$conv/nope.json" 2>/dev/null; then
    echo '非 HTTPS 的来源必须被拒绝' >&2; exit 1
  fi
  fetch_payload='not-json-at-all'
  if fetch_singbox_rule_set_json https://example.com/x.json "$conv/nope2.json" 2>/dev/null; then
    echo '结构不对的规则集必须被拒绝' >&2; exit 1
  fi
)

echo 'unit checks passed'
