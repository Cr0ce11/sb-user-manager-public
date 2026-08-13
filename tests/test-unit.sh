#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")/.."
export SB_USER_MANAGER_LIBRARY=true
# shellcheck source=../sb-user-manager.sh
source ./sb-user-manager.sh

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

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
  ensure_safe_ssh_for_singbox_restart() { return 0; }
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
! grep -Fq '添加 SS2022 + ShadowTLS' "$work/state-three-protocol-menu.txt"

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
  ensure_safe_ssh_for_singbox_restart() { return 0; }
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
multi_listener_line="$(grep -n 'run_managed_step append_inbounds' <<<"$multi_add_body" | cut -d: -f1)"
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
  ensure_safe_ssh_for_singbox_restart() { return 0; }
  start_managed_operation() { printf 'start:%s\n' "$1" >> "$events"; }
  finish_managed_operation() { printf 'finish\n' >> "$events"; }
  run_managed_step() { printf 'step:%s\n' "$1" >> "$events"; "$@"; }
  nfuse() { printf 'nfuse:%s\n' "$*" >> "$events"; }
  append_inbounds() { printf 'append\n' >> "$events"; }
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
  user_exists() { printf 'user %s\n' "$1" >> "$trace"; return 1; }
  port_in_state() { printf 'state-port %s\n' "$1" >> "$trace"; return 1; }
  port_is_listening() { printf 'listen-port %s\n' "$1" >> "$trace"; return 1; }
  tag_exists_in_config() { printf 'tag %s\n' "$1" >> "$trace"; return 1; }
  nfuse_account_exists() { printf 'nfuse-account %s\n' "$1" >> "$trace"; return 1; }
  nfuse_port_exists() { printf 'nfuse-port %s\n' "$1" >> "$trace"; return 1; }
  check_new_user_conflicts ss2022 alice 23001
  diff -u <(cat <<'EOF'
user alice
state-port 23001
listen-port 23001
tag st-alice
tag ss-alice
tag ss-udp-alice
nfuse-account alice
nfuse-port 23001
EOF
  ) "$trace"
)
(
  trace="$work/new-user-preflight-anytls"
  user_exists() { printf 'user %s\n' "$1" >> "$trace"; return 1; }
  port_in_state() { printf 'state-port %s\n' "$1" >> "$trace"; return 1; }
  port_is_listening() { printf 'listen-port %s\n' "$1" >> "$trace"; return 1; }
  tag_exists_in_config() { printf 'tag %s\n' "$1" >> "$trace"; return 1; }
  anytls_certificate_ready() { printf 'certificate\n' >> "$trace"; }
  nfuse_account_exists() { printf 'nfuse-account %s\n' "$1" >> "$trace"; return 1; }
  nfuse_port_exists() { printf 'nfuse-port %s\n' "$1" >> "$trace"; return 1; }
  check_new_user_conflicts anytls bob 23002
  diff -u <(cat <<'EOF'
user bob
state-port 23002
listen-port 23002
tag anytls-bob
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
  ! grep -Fq 'run_managed_step rebuild_all_split_configs' <<<"$split_operation_body"
  ! grep -Fq 'run_managed_step check_singbox_and_restart' <<<"$split_operation_body"
  ! grep -Fq 'finish_managed_operation' <<<"$split_operation_body"
done

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
  ! grep -Fq 'decrypt_migration_backup "$SELECTED_MIGRATION_BACKUP"' <<<"$migration_entry_body"
  ! grep -Fq 'normalize_migration_payload_schema "$source_payload"' <<<"$migration_entry_body"
  ! grep -Fq 'validate_migration_payload_structure "$source_payload"' <<<"$migration_entry_body"
  ! grep -Fq 'prepare_migration_effective_payload "$source_payload"' <<<"$migration_entry_body"
done

# 只有当前 SSH 的回连套接字确实归 sing-box 所有时才阻止重启；普通直连和无法判断的连接保持可用。
(
  unset SSH_CONNECTION
  if ssh_connection_uses_local_singbox; then
    echo 'non-SSH sessions must not be classified as local sing-box connections' >&2
    exit 1
  fi
)
(
  export SSH_CONNECTION='203.0.113.9 54321 192.0.2.10 22'
  list_singbox_owned_ssh_sockets() { printf '%s\n' 'ESTAB 0 0 192.0.2.10:54321 192.0.2.10:22 users:(("ssh",pid=10,fd=3))'; }
  if ssh_connection_uses_local_singbox; then
    echo 'ordinary direct SSH must not be blocked' >&2
    exit 1
  fi
)
(
  socket_probe="$work/ssh-loop-socket-probe"
  export SSH_CONNECTION='192.0.2.10 54321 192.0.2.10 22'
  list_singbox_owned_ssh_sockets() {
    printf '%s %s\n' "$1" "$2" > "$socket_probe"
    printf '%s\n' 'ESTAB 0 0 192.0.2.10:54321 192.0.2.10:22 users:(("sing-box",pid=20,fd=9))'
  }
  ssh_connection_uses_local_singbox
  grep -Fxq '54321 22' "$socket_probe"
  warning="$(ensure_safe_ssh_for_singbox_restart 2>&1 || true)"
  grep -Fq '当前 SSH 连接正通过这台服务器自己的 sing-box 节点' <<<"$warning"
  grep -Fq '服务器数据尚未修改' <<<"$warning"
)
(
  export SSH_CONNECTION='2001:db8::10 60000 2001:db8::20 2222'
  list_singbox_owned_ssh_sockets() { printf '%s\n' 'ESTAB 0 0 [2001:db8::20]:60000 [2001:db8::20]:2222 users:(("sing-box",pid=20,fd=9))'; }
  ssh_connection_uses_local_singbox
)
(
  export SSH_CONNECTION='malformed connection data'
  list_singbox_owned_ssh_sockets() { echo 'socket lookup must not run for malformed SSH_CONNECTION' >&2; return 90; }
  if ssh_connection_uses_local_singbox; then
    echo 'malformed SSH_CONNECTION must fail open' >&2
    exit 1
  fi
)
(
  later_marker="$work/ssh-loop-add-menu-later"
  ensure_safe_ssh_for_singbox_restart() { printf '%s\n' blocked; return 1; }
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

stderr_probe="$work/stderr-probe"
{
  release_operation_lock
  printf 'stderr-preserved\n' >&2
} 2>"$stderr_probe"
grep -Fxq 'stderr-preserved' "$stderr_probe"

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
  sync_transaction_path() { printf '%s\n' "$1" >> "$atomic_install_sync_log"; }
  atomic_install_file "$atomic_install_source" "$atomic_install_target" 755
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
  startup_pause_marker="$work/shared-manager-startup-pause"
  pause() { printf 'paused\n' > "$startup_pause_marker"; }
  ensure_manager_shortcut_for_interactive_startup
  [[ "$(readlink "$shortcut")" == /usr/local/sbin/sb-user-manager ]]
  [[ ! -e "$startup_pause_marker" ]]
  ensure_manager_shortcut_for_interactive_startup
  [[ "$(readlink "$shortcut")" == /usr/local/sbin/sb-user-manager ]]
  [[ ! -e "$startup_pause_marker" ]]

  rm -f "$shortcut"
  printf 'keep-startup-conflict\n' > "$shortcut"
  startup_conflict_output="$(ensure_manager_shortcut_for_interactive_startup)"
  grep -Fxq keep-startup-conflict "$shortcut"
  grep -Fq '脚本没有覆盖它' <<<"$startup_conflict_output"
  grep -Fxq paused "$startup_pause_marker"

  LATEST_SINGBOX_VERSION=1.2.3
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
  ! grep -Fq 'unexpected-ready' "$service_events"
  ! grep -Fq 'start sb-user-expiry.timer' "$service_events"
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
  restore_failed_environment_change unit-action /unit/broken-snapshot "$failed_work" > "$failed_log"
  grep -Fq '环境快照自动恢复失败' "$failed_log"
  ! grep -Fq 'unexpected-clear' "$failed_log"
  [[ ! -e "$failed_work" && -e "$failed_journal" ]]
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
  [[ ! -e "$ENVIRONMENT_LOCK_FILE" ]]
)

(
  uninstall_root="$work/uninstall-rollback-root"
  ENVIRONMENT_BACKUP_BASE="$uninstall_root/root/sb-user-manager-backups"
  MIGRATION_BACKUP_DIR="$ENVIRONMENT_BACKUP_BASE/data"
  ENVIRONMENT_TRANSACTION_JOURNAL="$uninstall_root/var/lib/sb-user-manager.recovery.json"
  ENVIRONMENT_LOCK_FILE="$uninstall_root/run/lock/sb-user-manager-environment.lock"
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
! grep -Fq 'FLOW:' "$work/install-fresh-cancel"
exercise_install_flow managed_complete '' > "$work/install-complete"
grep -Fq '安装完整' "$work/install-complete"
! grep -Fq 'FLOW:' "$work/install-complete"

exercise_install_flow managed_partial 1 > "$work/install-repair"
grep -Fxq 'FLOW:prerequisites' "$work/install-repair"
grep -Fxq 'FLOW:fetch:false' "$work/install-repair"
grep -Fxq 'FLOW:deploy:false:' "$work/install-repair"
exercise_install_flow managed_damaged $'2\ny' > "$work/install-overwrite"
grep -Fxq 'FLOW:deploy:true:' "$work/install-overwrite"

exercise_install_flow external $'1\ny' > "$work/install-takeover"
grep -Fxq 'FLOW:prerequisites' "$work/install-takeover"
grep -Fxq 'FLOW:takeover' "$work/install-takeover"
! grep -Fq 'FLOW:deploy' "$work/install-takeover"
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
! grep -Fq 'FLOW:deploy' "$work/install-unsafe-repair"

set +e
(
  environment_is_deployed() { return 0; }
  load_runtime_config() { :; }
  need_cmd() { :; }
  fetch_latest_releases() {
    LATEST_SINGBOX_VERSION=1.2.3
    LATEST_NFUSE_VERSION=4.5.6
    LATEST_MANAGER_VERSION="$SCRIPT_VERSION"
  }
  installed_singbox_version() { printf '1.0.0\n'; }
  installed_nfuse_version() { printf '4.5.6\n'; }
  installed_manager_version() { printf '%s\n' "$SCRIPT_VERSION"; }
  deploy_environment() { printf 'UPDATE:deploy-called\n'; return 73; }
  check_updates <<<'y'
) > "$work/update-failure" 2>&1
update_failure_rc=$?
set -e
[[ "$update_failure_rc" == 1 ]]
grep -Fxq 'UPDATE:deploy-called' "$work/update-failure"
! grep -Fq '正在切换到新进程' "$work/update-failure"

# 安装或更新必须在建立备份、停止服务或写入系统前确认 127.0.0.1 可绑定。
# 该检查不能依赖 sing-box check，因为静态检查不会实际打开监听端口。
(
  python3() { return 0; }
  ensure_deploy_loopback_ready
)
(
  marker="$work/deploy-after-loopback-preflight"
  ensure_safe_ssh_for_singbox_restart() { return 0; }
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

(
  environment_is_deployed() { return 0; }
  load_runtime_config() { :; }
  need_cmd() { :; }
  fetch_latest_releases() {
    LATEST_SINGBOX_VERSION=1.13.14
    LATEST_SINGBOX_URL=https://example.com/stable.tar.gz
    LATEST_SINGBOX_SHA256="$(printf 'a%.0s' {1..64})"
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
  installed_singbox_version() { singbox_binary_version "$SINGBOX_BIN"; }
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
  [[ "$(singbox_binary_version "$SINGBOX_VERSION_STORE/stable/sing-box")" == 1.13.14 ]]
  [[ "$(singbox_binary_version "$SINGBOX_VERSION_STORE/previous/sing-box")" == 1.13.14 ]]
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
  installed_singbox_version() { singbox_binary_version "$SINGBOX_BIN"; }
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
[[ "$(singbox_binary_version "$channel_failed_bin")" == 1.13.14 ]]
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
! grep -Eq '^(SS_METHOD|HANDSHAKE_SERVER|TLS_SERVER_NAME|PORT_MIN|PORT_MAX)=' "$CONF_FILE"
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

(
  STATE_FILE="$work/udp-upgrade-state.json"
  SINGBOX_CONFIG="$work/udp-upgrade-config.json"
  SINGBOX_BIN=mock_singbox
  HANDSHAKE_PORT=443
  SHADOWTLS_STRICT_MODE=true
  printf '%s\n' '{"schema_version":3,"users":[{"name":"legacy-active","port":20031,"status":"active","metered":false,"shadowtls_password":"legacy-st","ss2022_password":"legacy-ss","method":"2022-blake3-aes-128-gcm","shadowtls_sni":"legacy.example.com"},{"name":"legacy-disabled","port":20032,"status":"disabled","metered":false,"shadowtls_password":"disabled-st","ss2022_password":"disabled-ss","method":"2022-blake3-aes-128-gcm","shadowtls_sni":"disabled.example.com"}],"splits":[]}' > "$STATE_FILE"
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
! grep -Fq 'udp-port=' "$work/udp-export.txt"

[[ "$(url_percent_encode '节点 #+/')" == '%E8%8A%82%E7%82%B9%20%23%2B%2F' ]]

(
  STATE_FILE="$work/shadowrocket-export-state.json"
  PUBLIC_SERVER=198.51.100.20
  CLIENT_SERVER_PORT_OVERRIDE=24443
  printf '%s\n' '{"schema_version":3,"users":[{"name":"sr-ss","port":20041,"status":"active","metered":false,"shadowtls_password":"dummy/shadow+secret=","ss2022_password":"MDEyMzQ1Njc4OWFiY2RlZg==","method":"2022-blake3-aes-128-gcm","shadowtls_sni":"ss.example.com"},{"name":"sr-at","port":20042,"protocol":"anytls","status":"active","metered":false,"anytls_password":"dummy@+/ pass","tls_sni":"at.example.com"}],"splits":[]}' > "$STATE_FILE"
  cmd_export sr-ss shadowrocket
  cmd_export sr-at shadowrocket
) > "$work/shadowrocket-urls.txt"
! grep -Fq 'shadow-tls-password=' "$work/shadowrocket-urls.txt"
! grep -Fq '=anytls,' "$work/shadowrocket-urls.txt"
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
! grep -Fq 'shadow-tls-' "$work/direct-export.txt"
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

(
  qrencode() { printf 'qr:%s\n' "$*"; }
  print_shadowrocket_qr 'anytls://dummy.example'
) > "$work/shadowrocket-qr.txt"
grep -Fq 'qr:-t ANSIUTF8 -l L -m 1 -- anytls://dummy.example' "$work/shadowrocket-qr.txt"

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
  ! grep -Fq 'systemctl:' "$sni_events"
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
      generate) printf 'ss-new-secret\n';;
      *) return 64;;
    esac
  }
  SINGBOX_BIN=edit_singbox
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
apply_split_config unit-split https://rules.example.com/unit.srs user stored-at "$split_upstream" unit-out unit-rule
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
  validate_remote_rule_set https://rules.example.com/valid.json
  validate_remote_rule_set https://rules.example.com/valid.srs
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
  validate_remote_rule_set https://rules.example.com/invalid.json
) >/dev/null 2>&1
invalid_ruleset_rc=$?
set -e
[[ "$invalid_ruleset_rc" != 0 ]]

(
  prompt_split_upstream_fields shadowsocks '{"protocol":"shadowsocks","server":"keep.example.com","server_port":443,"method":"aes-256-gcm","password":"keep-secret"}' <<'EOF'




EOF
  jq -e '.protocol == "shadowsocks" and .server == "keep.example.com" and .server_port == 443 and .method == "aes-256-gcm" and .password == "keep-secret"' <<<"$PROMPTED_SPLIT_UPSTREAM" >/dev/null
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

  state_move_split alpha 1
  jq -e '[.splits[].name] == ["alpha","beta","disabled"]' "$STATE_FILE" >/dev/null
  rebuild_all_split_configs
  jq -e '[.route.rules[] | select(.rule_set == "beta-rule" or .rule_set == "alpha-rule") | .rule_set] == ["alpha-rule","beta-rule"]' "$SINGBOX_CONFIG" >/dev/null

  validate_remote_rule_set() { :; }
  start_managed_operation() { :; }
  finish_managed_operation() { :; }
  check_singbox_and_restart() { :; }
  edited_upstream='{"protocol":"shadowsocks","server":"edited.example.com","server_port":9443,"method":"aes-256-gcm","password":"alpha-secret"}'
  cmd_split_edit alpha https://rules.example.com/edited.srs all '' "$edited_upstream" edited-out >/dev/null
  jq -e '.splits[0] | .name == "alpha" and .status == "active" and .created_at == "2026-07-15T00:00:00+08:00" and .url == "https://rules.example.com/edited.srs" and .outbound_tag == "edited-out" and .upstream.password == "alpha-secret" and (.updated_at | length > 0)' "$STATE_FILE" >/dev/null
  details="$(cmd_split_show alpha)"
  grep -Fq '匹配顺序：第 1 条' <<<"$details"
  grep -Fq '规则集地址：https://rules.example.com/edited.srs' <<<"$details"
  ! grep -Fq 'alpha-secret' <<<"$details"
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
    SELECTED_RULE_URL=https://rules.example.com/ai.srs
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
  validate_remote_rule_set() { :; }
  ensure_safe_ssh_for_singbox_restart() { :; }
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
  validate_remote_rule_set() { :; }
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
  rewrite_singbox_config '.'
) >/dev/null 2>&1
format_failure_rc=$?
set -e
[[ "$format_failure_rc" != 0 ]]
grep -Fxq triggered "$rollback_marker"
MOCK_SINGBOX_FORMAT_FAIL=false
cmp -s "$SINGBOX_CONFIG" "$work/config.before-failure.json"
rm -f "$rollback_marker"
set +e
(
  trap 'printf "triggered\n" > "$rollback_marker"' ERR
  rewrite_singbox_config '.inbounds, error("forced jq failure")'
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
  if rewrite_singbox_config '.inbounds += [{"tag":"must-not-commit"}]' >/dev/null 2>&1; then
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

(
  BACKUP_DIR="$work/durable-transaction-backups"
  TRANSACTION_DIR="$work/durable-transactions"
  TRANSACTION_JOURNAL="$TRANSACTION_DIR/active.json"
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
        name="$2"; limit_bytes="$(awk -v value="$6" 'BEGIN {printf "%.0f", value*1073741824}')"
        nfuse_update '. += [{id:99,name:$name,tier:$tier,limit_gib:$limit,limit_bytes:$limit_bytes,used_bytes:0,ports:[]}]' \
          --arg name "$name" --arg tier "$4" --argjson limit "$6" --argjson limit_bytes "$limit_bytes"
        ;;
      set-tier)
        name="$2"; limit_bytes="$(awk -v value="$6" 'BEGIN {printf "%.0f", value*1073741824}')"
        nfuse_update '(.[] | select(.name == $name)) |= (.tier=$tier | .limit_gib=$limit | .limit_bytes=$limit_bytes)' \
          --arg name "$name" --arg tier "$4" --argjson limit "$6" --argjson limit_bytes "$limit_bytes"
        ;;
      set-usage) nfuse_update '(.[] | select(.name == $name) | .used_bytes) = $used' --arg name "$2" --argjson used "$3";;
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

  begin_operation_transaction 'nested-outer'
  begin_operation_transaction 'nested-inner'
  [[ "$ACTIVE_TRANSACTION_DEPTH" == 2 && -f "$TRANSACTION_JOURNAL" ]]
  commit_operation_transaction
  [[ "$ACTIVE_TRANSACTION_DEPTH" == 1 && -f "$TRANSACTION_JOURNAL" ]]
  commit_operation_transaction
  [[ "$ACTIVE_TRANSACTION_DEPTH" == 0 && ! -e "$TRANSACTION_JOURNAL" ]]
)

(
  SB_SYSTEM_ROOT="$work/environment-root"
  ENVIRONMENT_BACKUP_BASE="$work/environment-snapshots"
  ENVIRONMENT_TRANSACTION_JOURNAL="$work/environment-recovery.json"
  ENVIRONMENT_LOCK_FILE="$work/environment-recovery.lock"
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
  begin_environment_transaction environment-unit "$snapshot" /usr/local/bin/nfuse
  [[ -f "$ENVIRONMENT_TRANSACTION_JOURNAL" ]]
  validate_environment_transaction
  printf 'interrupted\n' > "$SB_SYSTEM_ROOT/etc/sb-user-manager.conf"
  printf '%s\n' '{"marker":"interrupted"}' > "$SB_SYSTEM_ROOT/etc/sing-box/config.json"
  printf 'new-binary\n' > "$SB_SYSTEM_ROOT/usr/local/bin/nfuse"
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
  ! grep -Fq 'imported:' "$usage_log"
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
! grep -Fq 'beta｜' "$work/status-disable"
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
! grep -Fq 'UNEXPECTED:' "$work/status-return"

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
! grep -Fq 'UNEXPECTED:' "$work/add-split-return"

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
! grep -Fq 'ignored.example' "$work/split-diagnostic-rendered"

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
! grep -Fq 'UNEXPECTED-SINGLE' "$work/add-default-multi"
(
  load_runtime_config() { :; }
  MENU_RETURNED=false
  prompt_add_node <<'EOF'
4
0
EOF
) > "$work/add-user-protocol-menu" 2>&1
grep -Fq '输入无效：请输入 1、2、3 或 0' "$work/add-user-protocol-menu"
! grep -Fq '为已有用户添加或移除协议' "$work/add-user-protocol-menu"

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
! grep -Fq 'UNEXPECTED-SELF' "$work/add-default-metered"

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
! grep -Fq 'UNEXPECTED-SELF' "$work/add-invalid-retry"

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
! grep -Fq 'UNEXPECTED-RENEW' "$work/renew-prompt-cancel"
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
! grep -Fq 'UNEXPECTED:' "$work/edit-prompt-return"

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
  tag_exists_in_config() { return 1; }
  generate_st_password() { printf 'self-st\n'; }
  generate_ss_password() { printf 'self-ss\n'; }
  append_inbounds() { return 0; }
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
  tag_exists_in_config() { return 1; }
  generate_st_password() { printf 'blocked-st\n'; }
  generate_ss_password() { printf 'blocked-ss\n'; }
  ensure_safe_ssh_for_singbox_restart() { return 1; }
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
  ensure_safe_ssh_for_singbox_restart() { return 0; }
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
  ! grep -Fq 'fallback-secret' <<<"$rendered_fallback"
  ! grep -Fq 'fallback.example.com' <<<"$rendered_fallback"
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
  ! grep -Fq 'unit-test-password' <<<"$batch_output"
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
! grep -Fq 'sb-user-data-auto-link.sbm' <<<"$auto_import_output"
! grep -Fq 'sb-user-data-auto-nested.sbm' <<<"$auto_import_output"
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
! grep -Fq 'ss2022_password' "$MIGRATION_REPORT"
validate_migration_restore_report "$MIGRATION_REPORT"
report_list="$(print_migration_reports)"
grep -Fq '成功' <<<"$report_list"
grep -Fq '来源：unit-source' <<<"$report_list"
report_details="$(printf '1\n' | show_migration_report_details)"
grep -Fq '执行结果：成功' <<<"$report_details"
grep -Fq '失败阶段：无' <<<"$report_details"
grep -Fq '恢复前完整备份：/root/example-snapshot' <<<"$report_details"
! grep -Fq 'ss2022_password' <<<"$report_details"
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
  ! grep -Fq '返回主菜单' <<<"$nested_menu_output"
done
migration_backup_menu_body="$(declare -f migration_backup_menu)"
grep -Fq "check_all '批量体检全部备份（只读）'" <<<"$migration_backup_menu_body"
grep -Fq 'check_all_migration_backups' <<<"$migration_backup_menu_body"

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
! grep -Fq 'nfuse.db-wal' "$snapshot/MANIFEST.sha256"
! grep -Fq 'nfuse.db-shm' "$snapshot/MANIFEST.sha256"
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
  LATEST_SINGBOX_VERSION=1.2.3
  LATEST_SINGBOX_URL=https://example.com/sing-box.tar.gz
  LATEST_SINGBOX_SHA256="$(printf '0%.0s' {1..64})"
  LATEST_NFUSE_VERSION=1.2.3
  LATEST_NFUSE_URL=https://example.com/nfuse.tar.gz
  LATEST_NFUSE_SHA256="$(printf '0%.0s' {1..64})"
  installed_singbox_version() { printf '0.0.0'; }
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
  LATEST_SINGBOX_VERSION=1.2.3
  LATEST_SINGBOX_URL=https://example.com/sing-box.tar.gz
  LATEST_SINGBOX_SHA256="$(printf 'a%.0s' {1..64})"
  LATEST_NFUSE_VERSION=1.2.3
  LATEST_NFUSE_URL=https://example.com/nfuse.tar.gz
  LATEST_NFUSE_SHA256="$(printf 'a%.0s' {1..64})"
  installed_singbox_version() { printf '0.0.0'; }
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
! grep -Fq 'cmd_enable ' <<<"$renew_body"
grep -Fq 'run_managed_step enable_user_without_transaction' <<<"$renew_body"
renew_expiry_body="$(declare -f calculate_renewal_expiry)"
grep -Fq 'date -d "$base_time ${months} months"' <<<"$renew_expiry_body"
! grep -Fq '+${months} month' <<<"$renew_expiry_body"
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
    ! calculate_renewal_expiry "$renewal_october_base" 0 >/dev/null 2>&1
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
  ensure_safe_ssh_for_singbox_restart() { return 1; }
  start_managed_operation() { printf 'unexpected\n' > "$work/unsafe-enable-started"; }
  if cmd_enable unsafe-user >"$work/unsafe-enable-output" 2>&1; then
    echo 'unsafe SSH enable must fail instead of reporting success' >&2
    exit 1
  fi
  [[ ! -e "$work/unsafe-enable-started" ]]
  grep -Fq '用户没有启用：unsafe-user' "$work/unsafe-enable-output"
)

# 秘密不得再通过 jq --arg 或 HMAC 外部进程 argv 传入。
! grep -Eq -- '--arg (st_password|ss_password|password) ' src/30-user-runtime.sh
grep -Fq '$ENV.SB_JQ_PASSWORD' src/30-user-runtime.sh
if grep -REn -- '--arg (password|ss_password|shadowtls_password|st_password) |--argjson (u|upstream|new_outbounds|user|split|preset|incoming) "\$' \
  src/20-migration-backup.sh src/30-user-runtime.sh src/40-split-runtime.sh src/70-split-prompts.sh; then
  echo 'secrets must not be passed to jq through command-line arguments' >&2
  exit 1
fi
! grep -Fq 'Authorization: Bearer' src/50-install-update.sh
! grep -Fq 'prompt_github_token' src/50-install-update.sh
! grep -Fq 'github_curl_with_token' src/50-install-update.sh
(
  token_args="$work/github-token-args"
  curl() {
    printf '%s\0' "$@" > "$token_args"
    jq -cn --arg digest "sha256:$(printf 'a%.0s' {1..64})" '{
      tag_name:"v9.9.9",
      assets:[{name:"sb-user-manager.sh",browser_download_url:"https://github.com/DTB201/sb-user-manager-public/releases/download/v9.9.9/sb-user-manager.sh",digest:$digest}]
    }'
  }
  GITHUB_TOKEN='github-secret-token'
  fetch_latest_manager_release
  [[ "$LATEST_MANAGER_VERSION" == 9.9.9 ]]
  [[ "$LATEST_MANAGER_URL" == https://github.com/DTB201/sb-user-manager-public/releases/download/v9.9.9/sb-user-manager.sh ]]
  [[ "$LATEST_MANAGER_SHA256" == "$(printf 'a%.0s' {1..64})" ]]
  ! tr '\0' '\n' < "$token_args" | grep -Fq 'github-secret-token'
  ! tr '\0' '\n' < "$token_args" | grep -Fq 'Authorization:'
  grep -Fxq 'https://api.github.com/repos/DTB201/sb-user-manager-public/releases/latest' < <(tr '\0' '\n' < "$token_args")
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
! grep -Fq 'macopt "hexkey:' src/20-migration-backup.sh
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

printf '%s\n' '{"schema_version":3,"users":[{"name":"test","status":"disabled","port":10001,"metered":true,"limit_gib":1},{"name":"crocell","status":"active","port":10000,"metered":false},{"name":"test2","status":"active","port":22547,"metered":true,"limit_gib":2}],"splits":[{"name":"AI","status":"active","scope":"user","user":"crocell","rule_set_tag":"AI","outbound_tag":"Hinet"}]}' > "$STATE_FILE"
printf '%s\n' '{"inbounds":[{"tag":"st-crocell"},{"tag":"ss-crocell"},{"type":"shadowsocks","tag":"ss-udp-crocell","network":"udp","listen_port":10000},{"tag":"st-test2"},{"tag":"ss-test2"},{"type":"shadowsocks","tag":"ss-udp-test2","network":"udp","listen_port":22547}],"outbounds":[{"tag":"Hinet"}],"route":{"rule_set":[{"tag":"AI"}],"rules":[{"rule_set":"AI","outbound":"Hinet","inbound":["st-crocell","ss-crocell","ss-udp-crocell"]}]}}' > "$SINGBOX_CONFIG"
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
jq '(.inbounds[] | select(.tag == "ss-udp-crocell") | .network) = "tcp"' "$SINGBOX_CONFIG" > "$SINGBOX_CONFIG.tmp"
mv "$SINGBOX_CONFIG.tmp" "$SINGBOX_CONFIG"
audit_consistency > "$work/audit-udp-invalid-output"
[[ "$AUDIT_ISSUES" == 1 && "$AUDIT_REPAIRABLE" == 1 ]]
grep -Fq 'UDP 连接配置不正确' "$work/audit-udp-invalid-output"

printf '%s\n' '{"schema_version":6,"users":[{"name":"direct-audit","status":"active","port":20044,"protocol":"ss2022","transport":"direct","metered":false,"usage_offset_bytes":0,"ss2022_password":"direct-secret","method":"2022-blake3-aes-128-gcm","endpoints":[{"protocol":"ss2022","transport":"direct","port":20044,"ss2022_password":"direct-secret","method":"2022-blake3-aes-128-gcm"}]}],"splits":[],"outbound_presets":[],"rule_presets":[]}' > "$STATE_FILE"
printf '%s\n' '{"inbounds":[{"type":"shadowsocks","tag":"ss-direct-audit","listen":"::","listen_port":20044,"method":"2022-blake3-aes-128-gcm","password":"direct-secret"},{"type":"shadowtls","tag":"st-direct-audit"},{"type":"shadowsocks","tag":"ss-udp-direct-audit","network":"udp","listen_port":20044}],"outbounds":[],"route":{"rule_set":[],"rules":[]}}' > "$SINGBOX_CONFIG"
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

echo 'unit checks passed'
