#!/usr/bin/env bash
# jq 过滤器中的 $ENV 来自 jq 环境，不是 Bash 展开。
# 测试桩由动态 source 的落地函数间接调用。
# 备用系统根只在隔离子 shell 内覆写路径；父 shell 后续继续使用原始固定路径。
# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
set -Eeuo pipefail

cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

real_jq="$(command -v jq)"
real_openssl="$(command -v openssl)"
real_python3="$(command -v python3)"
real_ssh_keygen="$(command -v ssh-keygen)"
argv_log="$work/external-argv.log"
capture_external_argv=false
jq() {
  if [[ "$capture_external_argv" == true ]]; then printf 'jq\t%s\n' "$*" >> "$argv_log"; fi
  "$real_jq" "$@"
}
openssl() {
  if [[ "$capture_external_argv" == true ]]; then printf 'openssl\t%s\n' "$*" >> "$argv_log"; fi
  "$real_openssl" "$@"
}
python3() {
  if [[ "$capture_external_argv" == true ]]; then printf 'python3\t%s\n' "$*" >> "$argv_log"; fi
  "$real_python3" "$@"
}
ssh-keygen() {
  if [[ "$capture_external_argv" == true ]]; then printf 'ssh-keygen\t%s\n' "$*" >> "$argv_log"; fi
  "$real_ssh_keygen" "$@"
}

system_root="$work/system-root"
export SB_USER_MANAGER_LIBRARY=true
export SB_SYSTEM_ROOT="$system_root"
export SB_CONTROLLER_SECRET_DIR="$work/controller-secrets"
export SB_LANDING_RECEIPT_FILE="$system_root/var/lib/sb-user-manager/landing-receipt.json"
export SB_LANDING_RECEIPT_LOCK_FILE="$system_root/run/lock/sb-user-manager/landing-receipt.lock"
export SB_LANDING_APPLY_TRANSACTION_DIRECTORY="$system_root/var/lib/sb-user-manager/landing-apply-transaction"
# shellcheck source=../sb-user-manager.sh
source ./sb-user-manager.sh

if ! command -v flock >/dev/null 2>&1; then
  flock() { return 0; }
fi

fail() {
  printf 'landing agent test failed: %s\n' "$1" >&2
  exit 1
}

report_unexpected_failure() {
  local rc="$1" line="$2"
  trap - ERR
  printf 'landing agent test failed unexpectedly at line %s\n' "$line" >&2
  exit "$rc"
}
trap 'report_unexpected_failure "$?" "$LINENO"' ERR

if [[ "$(uname -s)" != Linux ]]; then
  printf 'landing agent Linux runtime checks skipped; anonymous apply publication is fail-closed here\n'
  exit 0
fi

nft_state_file="$work/nft-live.state"
service_state_file="$work/service.state"
service_log="$work/service.log"
runtime_event_log="$work/runtime-events.log"
nft_fail_check="$work/nft-fail-check"
nft_fail_rollback_check="$work/nft-fail-rollback-check"
nft_fail_apply_once="$work/nft-fail-apply-once"
restart_fail_once="$work/restart-fail-once"
stop_fail="$work/stop-fail"
health_fail="$work/health-fail"
singbox_check_fail="$work/singbox-check-fail"
: > "$nft_state_file"
printf 'inactive\n' > "$service_state_file"
: > "$service_log"
: > "$runtime_event_log"

nft() {
  local batch_file="" first_line=""
  if [[ "$capture_external_argv" == true ]]; then printf 'nft\t%s\n' "$*" >> "$argv_log"; fi
  if [[ "${1:-}" == -nn ]]; then shift; fi
  if [[ "${1:-}" == list && "${2:-}" == tables ]]; then
    if [[ -s "$nft_state_file" ]]; then
      printf 'table %s %s\n' "$LANDING_NFTABLES_FAMILY" "$LANDING_NFTABLES_TABLE"
    fi
    return 0
  fi
  if [[ "${1:-}" == list && "${2:-}" == table ]]; then
    [[ -s "$nft_state_file" ]] || return 1
    cat "$nft_state_file"
    return
  fi
  if [[ "${1:-}" == delete && "${2:-}" == table ]]; then
    printf 'nft-delete\n' >> "$runtime_event_log"
    : > "$nft_state_file"
    return 0
  fi
  if [[ "${1:-}" == -c && "${2:-}" == -f ]]; then
    [[ ! -e "$nft_fail_check" ]] || return 71
    if [[ "${3:-}" == */nft.rollback && -e "$nft_fail_rollback_check" ]]; then
      return 76
    fi
    grep -Fq 'add table inet sb_user_manager_landing' "$3" || return 1
    grep -Fq 'flush table inet sb_user_manager_landing' "$3" || return 1
    grep -Fq ' tcp dport ' "$3" || return 1
    return 0
  fi
  if [[ "${1:-}" == -f ]]; then
    if [[ "${2:-}" == - || "${2:-}" == */nft.rollback ]]; then
      printf 'nft-rollback-batch\n' >> "$runtime_event_log"
    elif [[ "${2:-}" == */landing.nft ]]; then
      printf 'nft-apply\n' >> "$runtime_event_log"
    else
      printf 'nft-restore\n' >> "$runtime_event_log"
    fi
    if [[ -e "$nft_fail_apply_once" ]]; then
      rm -f -- "$nft_fail_apply_once"
      return 72
    fi
    if [[ "${2:-}" == - ]]; then
      batch_file="$(mktemp "$work/nft-batch.XXXXXX")" || return 1
      cat > "$batch_file" || { rm -f -- "$batch_file"; return 1; }
      first_line="$(head -n 1 "$batch_file")" || { rm -f -- "$batch_file"; return 1; }
      [[ "$first_line" == "delete table $LANDING_NFTABLES_FAMILY $LANDING_NFTABLES_TABLE" ]] || return 1
      tail -n +2 "$batch_file" > "$nft_state_file" || { rm -f -- "$batch_file"; return 1; }
      rm -f -- "$batch_file" || return 1
    elif [[ "${2:-}" == */nft.rollback ]]; then
      first_line="$(head -n 1 "$2")" || return 1
      [[ "$first_line" == "delete table $LANDING_NFTABLES_FAMILY $LANDING_NFTABLES_TABLE" ]] || return 1
      tail -n +2 "$2" > "$nft_state_file"
    else
      cp -- "$2" "$nft_state_file"
    fi
    return
  fi
  return 1
}

systemctl() {
  if [[ "$capture_external_argv" == true ]]; then printf 'systemctl\t%s\n' "$*" >> "$argv_log"; fi
  case "${1:-}" in
    is-active)
      if [[ "${2:-}" == --quiet ]]; then
        [[ "$(<"$service_state_file")" == active ]]
      else
        cat "$service_state_file"
        [[ "$(<"$service_state_file")" == active ]]
      fi
      ;;
    restart)
      printf 'service-restart\n' >> "$runtime_event_log"
      printf 'restart\n' >> "$service_log"
      if [[ -e "$restart_fail_once" ]]; then
        rm -f -- "$restart_fail_once"
        printf 'failed\n' > "$service_state_file"
        return 73
      fi
      printf 'active\n' > "$service_state_file"
      ;;
    stop)
      printf 'service-stop\n' >> "$runtime_event_log"
      printf 'stop\n' >> "$service_log"
      [[ ! -e "$stop_fail" ]] || return 75
      printf 'inactive\n' > "$service_state_file"
      ;;
    *) return 1 ;;
  esac
}

ss() {
  local argument requested_port=""
  if [[ "$capture_external_argv" == true ]]; then printf 'ss\t%s\n' "$*" >> "$argv_log"; fi
  [[ ! -e "$health_fail" ]] || return 0
  for argument in "$@"; do
    case "$argument" in
      'sport = :'*) requested_port="${argument##*:}" ;;
    esac
  done
  [[ "$requested_port" =~ ^[0-9]+$ ]] || return 1
  printf 'LISTEN 0 4096 0.0.0.0:%s 0.0.0.0:* users:(("sing-box",pid=123,fd=7))\n' \
    "$requested_port"
}

mkdir -p "$system_root/usr/local/bin"
export SB_TEST_LANDING_CHECK_FAIL_FILE="$singbox_check_fail"
export SB_TEST_LANDING_ARGV_LOG="$argv_log"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [[ -n "${SB_TEST_LANDING_ARGV_LOG:-}" ]]; then printf "sing-box\\t%s\\n" "$*" >> "$SB_TEST_LANDING_ARGV_LOG"; fi' \
  '[[ ! -e "${SB_TEST_LANDING_CHECK_FAIL_FILE:-/nonexistent}" ]] || exit 74' \
  '[[ "${1:-}" == check && "${2:-}" == -c && -s "${3:-}" ]]' \
  > "$system_root/usr/local/bin/sing-box"
chmod 755 "$system_root/usr/local/bin/sing-box"

landing_id=landing-a
server_name="landing-${RANDOM}${RANDOM}.example.test"
secret_dir="$CONTROLLER_SECRET_DIR/landing-${landing_id}"
manifest="$CONTROLLER_SECRET_DIR/landing-${landing_id}.json"
install -d -m 700 "$CONTROLLER_SECRET_DIR" "$secret_dir"
ssh-keygen -q -t ed25519 -N '' -f "$secret_dir/ssh-ed25519"
password="$(openssl rand -hex 32)"
printf '%s' "$password" > "$secret_dir/gateway-password"
openssl req -x509 -newkey rsa:2048 -nodes -days 3 \
  -keyout "$work/ca.key" -out "$secret_dir/gateway-ca.crt" \
  -subj '/CN=SBM landing agent test CA' >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes \
  -keyout "$secret_dir/gateway.key" -out "$work/gateway.csr" \
  -subj '/CN=SBM landing agent test gateway' >/dev/null 2>&1
printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$server_name" > "$work/gateway.ext"
openssl x509 -req -days 2 -in "$work/gateway.csr" \
  -CA "$secret_dir/gateway-ca.crt" -CAkey "$work/ca.key" -CAcreateserial \
  -out "$secret_dir/gateway.crt" -extfile "$work/gateway.ext" >/dev/null 2>&1
chmod 600 "$secret_dir/ssh-ed25519" "$secret_dir/gateway-password" \
  "$secret_dir/gateway-ca.crt" "$secret_dir/gateway.crt" "$secret_dir/gateway.key"

jq -n --arg landing_id "$landing_id" --arg server_name "$server_name" --arg secret_dir "$secret_dir" '
  {
    schema_version:1,
    landing_id:$landing_id,
    gateway_server_name:$server_name,
    ssh_private_key_file:($secret_dir + "/ssh-ed25519"),
    gateway_password_file:($secret_dir + "/gateway-password"),
    gateway_ca_certificate_file:($secret_dir + "/gateway-ca.crt"),
    gateway_certificate_file:($secret_dir + "/gateway.crt"),
    gateway_private_key_file:($secret_dir + "/gateway.key")
  }
' > "$manifest"
chmod 600 "$manifest"

package_dir="$work/packages"
mkdir -m 700 "$package_dir"
issued_at="$(date +%s)"
expires_at=$((issued_at + LANDING_APPLY_MAX_TTL))
build_package() {
  local revision="$1" nonce_char="$2" output="$3" issued="${4:-$issued_at}" expires="${5:-$expires_at}"
  local allowed_entry_ipv4="${6:-192.0.2.50}" gateway_port="${7:-24443}" nonce
  printf -v nonce '%*s' 64 ''
  nonce="${nonce// /$nonce_char}"
  build_landing_apply_package "$manifest" "$allowed_entry_ipv4" "$gateway_port" "$revision" \
    "$issued" "$expires" "$nonce" "$output"
}

package_one="$package_dir/apply-1.json"
build_package 1 a "$package_one"

valid_response_sha="$(printf 'd%.0s' {1..64})"
valid_success_response="{\"status\":\"applied\",\"revision\":1,\"content_sha256\":\"$valid_response_sha\"}"
valid_error_response='{"status":"error","code":"health_failed"}'
landing_agent_response_is_safe "$valid_success_response"
landing_agent_response_is_safe "$valid_error_response"
landing_agent_response_matches_exit "$valid_success_response" 0
landing_agent_response_matches_exit "$valid_error_response" 1
if landing_agent_response_matches_exit "$valid_success_response" 1; then
  fail 'agent accepted a success response with a failing exit status'
fi
if landing_agent_response_matches_exit "$valid_error_response" 0; then
  fail 'agent accepted an error response with a successful exit status'
fi
if landing_agent_response_is_safe '{"status":"error","code":"bad","secret":"value"}'; then
  fail 'agent accepted a response with an extra field'
fi
if landing_agent_response_is_safe '{"status":"applied","revision":1,"content_sha256":"short"}'; then
  fail 'agent accepted an invalid response digest'
fi

agent_entry="$work/sb-user-manager-landing-agent"
helper_entry="$work/sb-user-manager-landing-apply"
ln -s "$PWD/sb-user-manager.sh" "$agent_entry"
ln -s "$PWD/sb-user-manager.sh" "$helper_entry"
if SB_USER_MANAGER_LIBRARY=false "$agent_entry" > "$work/agent-dispatch.json" 2>&1; then
  fail 'retired agent basename was accepted'
fi
grep -Fq 'v5 入口与落地能力已经退役' "$work/agent-dispatch.json"
if SB_USER_MANAGER_LIBRARY=false "$helper_entry" unexpected > "$work/helper-dispatch.json" 2>&1; then
  fail 'retired helper basename was accepted'
fi
grep -Fq 'v5 入口与落地能力已经退役' "$work/helper-dispatch.json"

snapshot_probe="$(mktemp -d /tmp/sb-landing-agent.probe.XXXXXX)"
register_temp_path "$snapshot_probe"
[[ ! -e "$system_root/etc" && ! -L "$system_root/etc" ]] ||
  fail 'test system unexpectedly had runtime directories before the empty-state snapshot'
if ! landing_create_snapshot "$snapshot_probe"; then
  fail "empty-state snapshot failed at $LANDING_APPLY_ERROR_CODE; service=$(systemctl is-active sing-box 2>/dev/null || true)"
fi
jq -e 'all([.etc,.config_parent,.nft_parent,.tls][]; .state == "missing" and .mode == null)' \
  "$snapshot_probe/snapshot/directories.json" >/dev/null ||
  fail 'empty-state snapshot did not record missing runtime directories'
[[ "$(manager_file_mode "$snapshot_probe/snapshot")" == 700 ]]
while IFS= read -r -d '' snapshot_file; do
  [[ "$(manager_file_mode "$snapshot_file")" == 600 ]] || fail 'snapshot file mode is not 600'
done < <(find "$snapshot_probe/snapshot" -type f -print0)
rm -rf -- "$snapshot_probe"
LANDING_ACTIVE_SNAPSHOT=""

# 受限入口拒绝原始命令、TTY、额外参数和非 SSH 调用；合法调用只转交 stdin。
handoff_file="$work/handoff.json"
handoff_called=false
landing_agent_handoff() {
  handoff_called=true
  cat > "$handoff_file"
}
expect_agent_rejected() {
  local label="$1"
  shift
  if "$@" > "$work/agent-rejected.json" 2>/dev/null; then fail "agent accepted $label"; fi
  jq -e '.status == "error" and .code == "restricted_channel_rejected"' \
    "$work/agent-rejected.json" >/dev/null
}
unset SSH_CONNECTION SSH_ORIGINAL_COMMAND SSH_TTY
expect_agent_rejected non-ssh landing_agent_main
SSH_CONNECTION='192.0.2.50 50000 192.0.2.60 22'
SSH_ORIGINAL_COMMAND='id'
expect_agent_rejected command landing_agent_main
SSH_ORIGINAL_COMMAND=''
SSH_TTY='/dev/pts/1'
expect_agent_rejected tty landing_agent_main
SSH_TTY=''
expect_agent_rejected arguments landing_agent_main unexpected
landing_agent_main < "$package_one"
[[ "$handoff_called" == true ]]
cmp -s "$package_one" "$handoff_file"
unset SSH_CONNECTION SSH_ORIGINAL_COMMAND SSH_TTY

result="$work/result.json"
result_log="$work/results.jsonl"
: > "$result_log"
: > "$argv_log"
capture_external_argv=true

# 首次应用在运行检查失败时不得提前创建真实 receipt。
: > "$singbox_check_fail"
if landing_apply_helper_main < "$package_one" > "$result"; then
  fail 'failed first apply unexpectedly succeeded'
fi
rm -f -- "$singbox_check_fail"
jq -e '.status == "error" and .code == "check_failed"' "$result" >/dev/null
cat "$result" >> "$result_log"
[[ ! -e "$LANDING_RECEIPT_FILE" && ! -L "$LANDING_RECEIPT_FILE" ]]

# 首次部署在创建运行目录后失败时，必须按 directories.json 删除全部新增目录。
: > "$nft_fail_apply_once"
if landing_apply_helper_main < "$package_one" > "$result"; then
  fail 'failed clean-system apply unexpectedly succeeded'
fi
jq -e '.status == "error" and .code == "firewall_failed"' "$result" >/dev/null ||
  fail "clean-system rollback returned the wrong result: $(cat "$result")"
cat "$result" >> "$result_log"
[[ ! -e "$system_root/etc" && ! -L "$system_root/etc" ]] ||
  fail 'clean-system rollback retained newly created runtime directories'
[[ ! -e "$LANDING_RECEIPT_FILE" && ! -L "$LANDING_RECEIPT_FILE" ]] ||
  fail 'clean-system rollback created a receipt'
[[ ! -s "$nft_state_file" && "$(<"$service_state_file")" == inactive ]] ||
  fail 'clean-system rollback retained runtime state'

if ! landing_apply_helper_main < "$package_one" > "$result"; then
  fail "first apply failed: $(cat "$result")"
fi
cat "$result" >> "$result_log"
jq -e '.status == "applied" and .revision == 1 and (.content_sha256 | test("^[0-9a-f]{64}$"))' \
  "$result" >/dev/null

config="$system_root$LANDING_SINGBOX_CONFIG_PATH"
ca_certificate="$system_root$LANDING_CA_CERTIFICATE_PATH"
certificate="$system_root$LANDING_CERTIFICATE_PATH"
private_key="$system_root$LANDING_PRIVATE_KEY_PATH"
nft_rules="$system_root$LANDING_NFTABLES_RULES_PATH"
for protected_file in "$config" "$ca_certificate" "$certificate" "$private_key" "$nft_rules" \
  "$LANDING_RECEIPT_FILE"; do
  [[ "$(manager_file_mode "$protected_file")" == 600 ]] || fail "unsafe mode: $protected_file"
done
jq -e --rawfile password "$secret_dir/gateway-password" --slurpfile manifest "$manifest" '
  .inbounds[0].type == "anytls" and
  .inbounds[0].listen == "0.0.0.0" and
  .inbounds[0].listen_port == 24443 and
  .inbounds[0].users[0].name == "entry-controller" and
  .inbounds[0].users[0].password == $password and
  .inbounds[0].tls.certificate_path == "/etc/sing-box/landing/gateway.crt" and
  .route.final == "direct"
' "$config" >/dev/null
grep -Fq 'ip saddr 192.0.2.50 tcp dport 24443 accept' "$nft_rules"
grep -Fq 'tcp dport 24443 drop' "$nft_rules"
[[ "$(<"$service_state_file")" == active ]]

baseline="$work/baseline"
mkdir -m 700 "$baseline"
cp "$config" "$baseline/config.json"
cp "$ca_certificate" "$baseline/gateway-ca.crt"
cp "$certificate" "$baseline/gateway.crt"
cp "$private_key" "$baseline/gateway.key"
cp "$nft_rules" "$baseline/landing.nft"
cp "$nft_state_file" "$baseline/nft-live"
cp "$LANDING_RECEIPT_FILE" "$baseline/receipt.json"
chmod 600 "$baseline"/*

assert_baseline_restored() {
  cmp -s "$baseline/config.json" "$config" || fail 'config was not restored'
  cmp -s "$baseline/gateway-ca.crt" "$ca_certificate" || fail 'CA was not restored'
  cmp -s "$baseline/gateway.crt" "$certificate" || fail 'certificate was not restored'
  cmp -s "$baseline/gateway.key" "$private_key" || fail 'private key was not restored'
  cmp -s "$baseline/landing.nft" "$nft_rules" || fail 'nft file was not restored'
  if ! cmp -s "$baseline/nft-live" "$nft_state_file"; then
    diff -u "$baseline/nft-live" "$nft_state_file" >&2 || true
    fail 'live nft state was not restored'
  fi
  cmp -s "$baseline/receipt.json" "$LANDING_RECEIPT_FILE" || fail 'receipt advanced on failure'
  [[ "$(<"$service_state_file")" == active ]] || fail 'service state was not restored'
}

expect_helper_failure() {
  local label="$1" package="$2" expected_code="$3"
  if landing_apply_helper_main < "$package" > "$result"; then fail "$label unexpectedly succeeded"; fi
  jq -e --arg code "$expected_code" '.status == "error" and .code == $code' "$result" >/dev/null ||
    fail "$label returned the wrong error: $(cat "$result")"
  cat "$result" >> "$result_log"
}

active_transaction_work=""
prepare_active_transaction() {
  local package="$1" revision sha256
  landing_apply_begin_staging
  active_transaction_work="$LANDING_ACTIVE_WORK"
  install -m 600 -- "$package" "$active_transaction_work/apply.json"
  SB_LANDING_APPLY_VALIDATION_ROOT="$active_transaction_work" \
    landing_apply_package_structure_is_valid "$active_transaction_work/apply.json"
  landing_prepare_receipt_base "$active_transaction_work/apply.json" "$active_transaction_work"
  landing_render_candidates "$active_transaction_work/apply.json" "$active_transaction_work"
  landing_validate_candidates "$active_transaction_work"
  landing_create_snapshot "$active_transaction_work"
  landing_prepare_nft_rollback_batch "$active_transaction_work"
  landing_validate_nft_rollback_batch "$active_transaction_work"
  landing_snapshot_receipt "$active_transaction_work"
  landing_prepare_receipt_candidate "$active_transaction_work/apply.json" "$active_transaction_work"
  landing_apply_write_manifest "$active_transaction_work"
  revision="$(jq -r '.revision' "$active_transaction_work/apply.json")"
  sha256="$(jq -r '.content_sha256' "$active_transaction_work/apply.json")"
  landing_apply_write_transaction_journal active "$landing_id" "$revision" "$sha256"
  landing_apply_restored_state_is_valid
  landing_apply_mark_mutation_started
}

activate_prepared_transaction() {
  landing_prepare_runtime_directories
  landing_apply_candidates "$active_transaction_work" "$active_transaction_work/apply.json"
}

remove_test_apply_transaction() {
  landing_apply_reset_active_transaction
  rm -rf -- "$LANDING_APPLY_TRANSACTION_DIRECTORY"
}

# `install -d` 在 umask 077 下可能先留下 0700 再 chmod 755；该 SIGKILL 边界必须可恢复。
(
  intermediate_root="$work/intermediate-system-root"
  intermediate_state="$work/intermediate-state"
  intermediate_ready="$work/intermediate-directory-ready"
  intermediate_invalid="$work/intermediate-invalid.json"
  mkdir -m 700 -- "$intermediate_root"
  mkdir -p -- "$intermediate_root/usr/local/bin"
  install -m 755 -- "$system_root/usr/local/bin/sing-box" \
    "$intermediate_root/usr/local/bin/sing-box"
  printf '{}\n' > "$intermediate_invalid"
  SB_SYSTEM_ROOT="$intermediate_root"
  LANDING_RECEIPT_FILE="$intermediate_state/landing-receipt.json"
  LANDING_RECEIPT_LOCK_FILE="$intermediate_state/landing-receipt.lock"
  LANDING_APPLY_TRANSACTION_DIRECTORY="$intermediate_state/landing-apply-transaction"
  LANDING_APPLY_TRANSACTION_JOURNAL="$LANDING_APPLY_TRANSACTION_DIRECTORY/journal.json"
  prepare_active_transaction "$package_one"
  (
    install() {
      if [[ "${1:-}" == -d && "${2:-}" == -m && "${3:-}" == 755 &&
            "${4:-}" == -- && "${5:-}" == "$intermediate_root/etc" ]]; then
        command mkdir -m 700 -- "$5" || return 1
        : > "$intermediate_ready" || return 1
        while :; do :; done
      fi
      command install "$@"
    }
    landing_prepare_runtime_directories
  ) 2>/dev/null &
  intermediate_pid=$!
  for _ in {1..500}; do
    [[ ! -e "$intermediate_ready" ]] || break
    kill -0 "$intermediate_pid" 2>/dev/null || break
    sleep 0.01
  done
  if [[ ! -e "$intermediate_ready" ]]; then
    kill -KILL "$intermediate_pid" 2>/dev/null || true
    wait "$intermediate_pid" 2>/dev/null || true
    fail 'directory SIGKILL child did not reach the private intermediate mode'
  fi
  kill -KILL "$intermediate_pid"
  if wait "$intermediate_pid" 2>/dev/null; then
    fail 'directory SIGKILL child unexpectedly exited successfully'
  else
    intermediate_status=$?
  fi
  [[ "$intermediate_status" == 137 ]] ||
    fail "directory SIGKILL child returned unexpected status $intermediate_status"
  [[ "$(manager_file_mode "$intermediate_root/etc")" == 700 ]] ||
    fail 'directory SIGKILL did not leave the expected private intermediate mode'
  landing_apply_reset_active_transaction
  expect_helper_failure directory-private-intermediate "$intermediate_invalid" invalid_package
  [[ ! -e "$intermediate_root/etc" && ! -L "$intermediate_root/etc" ]] ||
    fail 'recovery did not remove the interrupted transaction directory'
  [[ ! -e "$LANDING_APPLY_TRANSACTION_DIRECTORY" &&
     ! -L "$LANDING_APPLY_TRANSACTION_DIRECTORY" ]] ||
    fail 'directory SIGKILL recovery retained the transaction'
)

# 已有目录 chmod 到候选权限后被 SIGKILL，也必须恢复快照中的旧权限。
(
  permission_ready="$work/permission-directory-ready"
  permission_invalid="$work/permission-invalid.json"
  tls_directory="$system_root$LANDING_TLS_DIRECTORY"
  printf '{}\n' > "$permission_invalid"
  chmod 750 "$tls_directory"
  prepare_active_transaction "$package_one"
  (
    sync_transaction_path() {
      if [[ "${1:-}" == "$tls_directory" &&
            "$(manager_file_mode "$tls_directory")" == 700 ]]; then
        : > "$permission_ready" || return 1
        while :; do :; done
      fi
      command sync -f "$1" 2>/dev/null
    }
    landing_prepare_runtime_directories
  ) 2>/dev/null &
  permission_pid=$!
  for _ in {1..500}; do
    [[ ! -e "$permission_ready" ]] || break
    kill -0 "$permission_pid" 2>/dev/null || break
    sleep 0.01
  done
  if [[ ! -e "$permission_ready" ]]; then
    kill -KILL "$permission_pid" 2>/dev/null || true
    wait "$permission_pid" 2>/dev/null || true
    fail 'directory chmod SIGKILL child did not reach the candidate mode'
  fi
  kill -KILL "$permission_pid"
  if wait "$permission_pid" 2>/dev/null; then
    fail 'directory chmod SIGKILL child unexpectedly exited successfully'
  else
    permission_status=$?
  fi
  [[ "$permission_status" == 137 ]] ||
    fail "directory chmod SIGKILL child returned unexpected status $permission_status"
  [[ "$(manager_file_mode "$tls_directory")" == 700 ]] ||
    fail 'directory chmod SIGKILL did not leave the candidate mode'
  landing_apply_reset_active_transaction
  expect_helper_failure directory-permission-intermediate "$permission_invalid" invalid_package
  [[ "$(manager_file_mode "$tls_directory")" == 750 ]] ||
    fail 'recovery did not restore the snapshotted directory mode'
  [[ ! -e "$LANDING_APPLY_TRANSACTION_DIRECTORY" &&
     ! -L "$LANDING_APPLY_TRANSACTION_DIRECTORY" ]] ||
    fail 'directory permission recovery retained the transaction'
  chmod 700 "$tls_directory"
)

# 输入上限和多文档在接触 receipt 或运行配置前拒绝。
oversized="$work/oversized.json"
dd if=/dev/zero of="$oversized" bs=$((LANDING_APPLY_MAX_BYTES + 1)) count=1 2>/dev/null

# 无 journal 的安全 staging 代表首次系统修改前中断；下一请求必须先清理再读取输入。
landing_apply_begin_staging
stale_staging="$LANDING_ACTIVE_WORK"
[[ -d "$stale_staging" && ! -L "$stale_staging" ]]
[[ ! -e "$LANDING_APPLY_TRANSACTION_JOURNAL" && ! -L "$LANDING_APPLY_TRANSACTION_JOURNAL" ]]
landing_apply_reset_active_transaction
expect_helper_failure oversized "$oversized" invalid_input
[[ ! -e "$stale_staging" && ! -L "$stale_staging" ]] ||
  fail 'safe journal-less staging was not cleaned before the next request'
multiple="$work/multiple.json"
printf '%s\n%s\n' "$(cat "$package_one")" "$(cat "$package_one")" > "$multiple"
expect_helper_failure multiple "$multiple" invalid_package
assert_baseline_restored

package_two="$package_dir/apply-2.json"
build_package 2 b "$package_two" "$issued_at" "$expires_at" 198.51.100.50 25443

(
  date() { trap - ERR; return 77; }
  expect_helper_failure clock "$package_two" clock_failed
)
assert_baseline_restored

# 候选语法检查失败不得修改现有运行状态。
: > "$singbox_check_fail"
expect_helper_failure singbox-check "$package_two" check_failed
rm -f -- "$singbox_check_fail"
: > "$nft_fail_check"
expect_helper_failure nft-check "$package_two" check_failed
rm -f -- "$nft_fail_check"

: > "$nft_fail_rollback_check"
expect_helper_failure nft-rollback-check "$package_two" transaction_prepare_failed
rm -f -- "$nft_fail_rollback_check"
assert_baseline_restored

# 服务无法先停下时，候选文件和防火墙不得开始切换；现场保留到故障解除后恢复。
: > "$stop_fail"
: > "$runtime_event_log"
expect_helper_failure stop-gate "$package_two" rollback_failed
cmp -s "$baseline/config.json" "$config" || fail 'stop gate changed config before stopping the service'
cmp -s "$baseline/nft-live" "$nft_state_file" || fail 'stop gate changed nft before stopping the service'
[[ "$(<"$service_state_file")" == active ]] || fail 'stop gate changed the old service state'
[[ -e "$LANDING_APPLY_TRANSACTION_JOURNAL" && ! -L "$LANDING_APPLY_TRANSACTION_JOURNAL" ]] ||
  fail 'stop gate failure did not preserve the active transaction'
if grep -Eq '^nft-(apply|rollback-batch|delete|restore)$' "$runtime_event_log"; then
  fail 'stop gate reached an nft mutation'
fi
rm -f -- "$stop_fail"
expect_helper_failure resumed-stop-gate "$multiple" invalid_package
assert_baseline_restored

# 每个受管文件的原子替换命令失败，都必须回到完整旧态。
while IFS=$'\t' read -r mv_label mv_target mv_expected_code; do
  mv_failure_marker="$work/mv-failure-$mv_label"
  (
    mv() {
      local -a arguments=("$@")
      local destination="${arguments[${#arguments[@]}-1]}"
      if [[ -e "$mv_failure_marker" && "$destination" == "$mv_target" ]]; then
        command rm -f -- "$mv_failure_marker"
        return 75
      fi
      command mv "$@"
    }
    : > "$mv_failure_marker"
    expect_helper_failure "mv-$mv_label" "$package_two" "$mv_expected_code"
    [[ ! -e "$mv_failure_marker" ]] || fail "mv failure was not reached for $mv_label"
  )
  assert_baseline_restored
done <<EOF
ca	$ca_certificate	install_failed
certificate	$certificate	install_failed
private-key	$private_key	install_failed
config	$config	install_failed
nft-file	$nft_rules	install_failed
receipt	$LANDING_RECEIPT_FILE	receipt_failed
EOF

# rename 已发生但目标父目录 sync 失败时，回滚必须识别候选值并恢复。
eval "$(declare -f sync_transaction_path | \
  sed '1s/^sync_transaction_path /sync_transaction_path_without_fault_injection /')"
while IFS=$'\t' read -r sync_label sync_target sync_expected_code; do
  sync_parent="$(dirname -- "$sync_target")"
  sync_failure_enabled="$work/sync-failure-enabled-$sync_label"
  sync_failure_armed="$work/sync-failure-armed-$sync_label"
  (
    mv() {
      local -a arguments=("$@")
      local destination="${arguments[${#arguments[@]}-1]}"
      command mv "$@" || return 1
      if [[ -e "$sync_failure_enabled" && "$destination" == "$sync_target" ]]; then
        : > "$sync_failure_armed" || return 1
      fi
    }
    sync_transaction_path() {
      if [[ -e "$sync_failure_armed" && "${1:-}" == "$sync_parent" ]]; then
        command rm -f -- "$sync_failure_enabled" "$sync_failure_armed"
        return 76
      fi
      sync_transaction_path_without_fault_injection "$@"
    }
    : > "$sync_failure_enabled"
    expect_helper_failure "sync-$sync_label" "$package_two" "$sync_expected_code"
    [[ ! -e "$sync_failure_enabled" && ! -e "$sync_failure_armed" ]] ||
      fail "post-rename sync failure was not reached for $sync_label"
  )
  assert_baseline_restored
done <<EOF
config	$config	install_failed
receipt	$LANDING_RECEIPT_FILE	receipt_failed
EOF

# committed journal 的原子 rename 失败时，旧 active journal 仍必须驱动完整回滚。
terminal_rename_failure="$work/terminal-rename-failure"
(
  mv() {
    local -a arguments=("$@")
    local source="${arguments[${#arguments[@]}-2]}" destination="${arguments[${#arguments[@]}-1]}"
    if [[ -e "$terminal_rename_failure" && "$destination" == "$LANDING_APPLY_TRANSACTION_JOURNAL" &&
          "$source" == "$LANDING_APPLY_TRANSACTION_DIRECTORY/.journal.next" ]] &&
       jq -e '.phase == "committed"' "$source" >/dev/null 2>&1; then
      command rm -f -- "$terminal_rename_failure"
      return 77
    fi
    command mv "$@"
  }
  : > "$terminal_rename_failure"
  expect_helper_failure terminal-journal-rename "$package_two" commit_failed
  [[ ! -e "$terminal_rename_failure" ]] || fail 'terminal journal rename failure was not reached'
)
assert_baseline_restored

: > "$nft_fail_apply_once"
expect_helper_failure firewall "$package_two" firewall_failed
assert_baseline_restored

: > "$restart_fail_once"
expect_helper_failure restart "$package_two" reload_failed
assert_baseline_restored

: > "$health_fail"
: > "$runtime_event_log"
expect_helper_failure health "$package_two" health_failed
rm -f -- "$health_fail"
assert_baseline_restored
[[ "$(<"$runtime_event_log")" == $'service-stop\nnft-apply\nservice-restart\nservice-stop\nnft-rollback-batch\nservice-restart' ]] ||
  fail "unsafe apply/rollback event order: $(tr '\n' ' ' < "$runtime_event_log")"

(
  landing_commit_receipt() {
    commit_landing_apply_receipt_unlocked "$@" || return 1
    return 76
  }
  expect_helper_failure receipt "$package_two" receipt_failed
)
assert_baseline_restored

# receipt 已推进后用不可捕获的 SIGKILL 终止独立 Bash 子进程；下一请求必须先按 active journal 恢复旧态。
prepare_active_transaction "$package_two"
crashed_active_work="$active_transaction_work"
# 后续损坏与回滚场景复用修改运行态之前的完整持久事务，避免重复生成证书校验素材。
active_fixture="$work/active-transaction-fixture"
cp -a -- "$LANDING_APPLY_TRANSACTION_DIRECTORY" "$active_fixture"
crash_status=0
crash_ready="$work/sigkill-ready"
(
  activate_prepared_transaction
  landing_commit_receipt "$crashed_active_work/apply.json" "$LANDING_RECEIPT_FILE" "$(date +%s)"
  : > "$crash_ready"
  while :; do :; done
) 2>/dev/null &
crash_pid=$!
for _ in {1..500}; do
  [[ ! -e "$crash_ready" ]] || break
  kill -0 "$crash_pid" 2>/dev/null || break
  sleep 0.01
done
if [[ ! -e "$crash_ready" ]]; then
  kill -KILL "$crash_pid" 2>/dev/null || true
  wait "$crash_pid" 2>/dev/null || true
  fail 'SIGKILL child did not reach the durable receipt boundary'
fi
kill -KILL "$crash_pid"
if wait "$crash_pid" 2>/dev/null; then
  fail 'SIGKILL child unexpectedly exited successfully'
else
  crash_status=$?
fi
[[ "$crash_status" == 137 ]] || fail "SIGKILL child returned unexpected status $crash_status"
jq -e '.applied_revision == 2' "$LANDING_RECEIPT_FILE" >/dev/null ||
  fail 'simulated crash did not advance the receipt before recovery'
jq -e '.phase == "active"' "$LANDING_APPLY_TRANSACTION_JOURNAL" >/dev/null ||
  fail 'simulated crash lost its active journal'
landing_apply_reset_active_transaction
expect_helper_failure process-death-recovery "$multiple" invalid_package
assert_baseline_restored
[[ ! -e "$crashed_active_work" && ! -L "$crashed_active_work" ]] ||
  fail 'successful crash recovery retained the active transaction'

# 复用一份完整 active 事务，逐类验证损坏现场必须失败关闭并原样保留。
restore_active_fixture() {
  [[ ! -e "$LANDING_APPLY_TRANSACTION_DIRECTORY" &&
     ! -L "$LANDING_APPLY_TRANSACTION_DIRECTORY" ]] || return 1
  cp -a -- "$active_fixture" "$LANDING_APPLY_TRANSACTION_DIRECTORY"
  landing_apply_reset_active_transaction
}

# 启动门禁复用同一持久事务，但冷启动时服务保持停止、内核 nft 表可为空。
# 这里直接复用上面的真实证书、配置、receipt 与 active fixture，验证三种阶段、
# 无事务恢复以及关键失败/进程中断都不会提前删除证据。
(
  startup_identity="$system_root$LANDING_CHANNEL_IDENTITY_PATH"
  startup_identity_parent="$(dirname -- "$startup_identity")"
  install -d -m 700 -- "$startup_identity_parent"
  jq -n --arg landing_id "$landing_id" '{landing_id:$landing_id}' > "$startup_identity"
  chmod 600 "$startup_identity"

  # 生产通道只允许公网地址；本测试现有 fixture 使用 RFC 5737 文档地址，
  # 仅在此隔离子 shell 中保留严格 IPv4 语法并复用其余真实校验链。
  is_public_ipv4() { is_ipv4_address "$1"; }
  validate_landing_channel_identity_file() {
    local identity="${1:-}"
    [[ "$identity" == "$startup_identity" && -f "$identity" && ! -L "$identity" &&
       "$(manager_file_mode "$identity")" == 600 ]] || return 1
    jq -e --arg landing_id "$landing_id" '.landing_id == $landing_id' "$identity" >/dev/null
  }
  # 现有 renderer 的 `jq -r` 与显式尾换行会留下一个历史尾空行；门禁必须兼容
  # 该精确格式，但仍拒绝第二个空行或任意额外成员。
  IFS=$'\t' read -r startup_rendered_ipv4 startup_rendered_port < <(
    landing_startup_parse_nft_file "$baseline/landing.nft"
  ) || fail 'startup parser rejected the existing rendered nft rules'
  [[ "$startup_rendered_ipv4" == 192.0.2.50 && "$startup_rendered_port" == 24443 ]] ||
    fail 'startup parser returned the wrong rendered nft values'
  startup_extra_nft="$work/startup-extra-trailing-line.nft"
  cp -- "$baseline/landing.nft" "$startup_extra_nft"
  printf '\n' >> "$startup_extra_nft"
  chmod 600 "$startup_extra_nft"
  if landing_startup_parse_nft_file "$startup_extra_nft" >/dev/null; then
    fail 'startup parser accepted more than the one historical trailing empty line'
  fi
  # 主测试的 nft 桩把 batch 原文作为 live 状态；生产解析器另有精确声明式输出测试。
  landing_startup_live_nft_matches_values() {
    local allowed_entry_ipv4="$1" port="$2"
    landing_startup_nft_file_matches_values "$nft_rules" "$allowed_entry_ipv4" "$port" || return 1
    cmp -s -- "$nft_rules" "$nft_state_file"
  }

  startup_reset_baseline() {
    rm -rf -- "$LANDING_APPLY_TRANSACTION_DIRECTORY"
    install -m 600 -- "$baseline/config.json" "$config"
    install -m 600 -- "$baseline/gateway-ca.crt" "$ca_certificate"
    install -m 600 -- "$baseline/gateway.crt" "$certificate"
    install -m 600 -- "$baseline/gateway.key" "$private_key"
    install -m 600 -- "$baseline/landing.nft" "$nft_rules"
    install -m 600 -- "$baseline/receipt.json" "$LANDING_RECEIPT_FILE"
    cp -- "$baseline/nft-live" "$nft_state_file"
    printf 'active\n' > "$service_state_file"
    landing_apply_reset_active_transaction
  }

  startup_restore_active_fixture() {
    startup_reset_baseline
    cp -a -- "$active_fixture" "$LANDING_APPLY_TRANSACTION_DIRECTORY"
    landing_apply_reset_active_transaction
  }

  startup_make_cold() {
    printf 'inactive\n' > "$service_state_file"
    : > "$nft_state_file"
  }

  startup_assert_baseline_cold() {
    cmp -s -- "$baseline/config.json" "$config" || fail 'cold recovery did not restore config'
    cmp -s -- "$baseline/gateway-ca.crt" "$ca_certificate" || fail 'cold recovery did not restore CA'
    cmp -s -- "$baseline/gateway.crt" "$certificate" || fail 'cold recovery did not restore certificate'
    cmp -s -- "$baseline/gateway.key" "$private_key" || fail 'cold recovery did not restore private key'
    cmp -s -- "$baseline/landing.nft" "$nft_rules" || fail 'cold recovery did not restore nft file'
    cmp -s -- "$baseline/nft-live" "$nft_state_file" || fail 'cold recovery did not restore live nft'
    cmp -s -- "$baseline/receipt.json" "$LANDING_RECEIPT_FILE" || fail 'cold recovery changed old receipt'
    [[ "$(<"$service_state_file")" == inactive ]] || fail 'cold recovery started sing-box'
    [[ ! -e "$LANDING_APPLY_TRANSACTION_DIRECTORY" &&
       ! -L "$LANDING_APPLY_TRANSACTION_DIRECTORY" ]] || fail 'cold recovery retained a terminal transaction'
  }

  # active：恢复完整旧态，恢复防火墙后才写 rolled_back 并清理。
  startup_restore_active_fixture
  startup_make_cold
  landing_startup_recovery_unlocked || fail 'active cold-start recovery failed'
  startup_assert_baseline_cold

  # committed：持久候选与新 receipt 是线性化结果，冷启动只补齐候选 nft 并清理。
  startup_restore_active_fixture
  landing_apply_load_pending_transaction
  active_transaction_work="$LANDING_ACTIVE_WORK"
  activate_prepared_transaction
  landing_commit_receipt "$active_transaction_work/apply.json" "$LANDING_RECEIPT_FILE" "$(date +%s)"
  package_two_sha="$(jq -r '.content_sha256' "$active_transaction_work/apply.json")"
  landing_apply_write_transaction_journal committed "$landing_id" 2 "$package_two_sha"
  landing_apply_reset_active_transaction
  startup_make_cold
  landing_startup_recovery_unlocked || fail 'committed cold-start recovery failed'
  cmp -s -- "$active_fixture/config.json" "$config" || fail 'committed cold start did not retain new config'
  cmp -s -- "$active_fixture/receipt.next.json" "$LANDING_RECEIPT_FILE" ||
    fail 'committed cold start did not retain new receipt'
  cmp -s -- "$nft_rules" "$nft_state_file" || fail 'committed cold start did not load new nft'
  [[ "$(<"$service_state_file")" == inactive ]] || fail 'committed cold start started sing-box'
  [[ ! -e "$LANDING_APPLY_TRANSACTION_DIRECTORY" ]] || fail 'committed cold start retained transaction'

  # rolled_back：只接受并恢复旧态。
  startup_restore_active_fixture
  landing_apply_load_pending_transaction
  package_two_sha="$(jq -r '.content_sha256' "$LANDING_ACTIVE_WORK/apply.json")"
  landing_apply_write_transaction_journal rolled_back "$landing_id" 2 "$package_two_sha"
  landing_apply_reset_active_transaction
  startup_make_cold
  landing_startup_recovery_unlocked || fail 'rolled-back cold-start recovery failed'
  startup_assert_baseline_cold

  # 无事务、receipt 已应用：重启后同名表为空时从严格持久规则恢复；未知表拒绝覆盖。
  startup_reset_baseline
  startup_make_cold
  landing_startup_recovery_unlocked || fail 'steady cold-start nft recovery failed'
  startup_assert_baseline_cold
  startup_reset_baseline
  printf 'unknown live nft state\n' > "$nft_state_file"
  printf 'inactive\n' > "$service_state_file"
  if landing_startup_recovery_unlocked; then
    fail 'steady cold-start gate overwrote an unknown live nft table'
  fi
  cmp -s -- "$baseline/config.json" "$config" || fail 'unknown live nft changed persistent config'
  [[ "$(<"$nft_state_file")" == 'unknown live nft state' ]] ||
    fail 'unknown live nft evidence was changed'

  # 无事务 steady config 必须逐字段匹配生成形状，不能接受 sing-box 容忍的未知字段。
  startup_reset_baseline
  startup_extra_config="$work/startup-extra-config.json"
  jq '.inbounds[0].unexpected = true' "$config" > "$startup_extra_config"
  install -m 600 -- "$startup_extra_config" "$config"
  startup_make_cold
  if landing_startup_recovery_unlocked; then
    fail 'steady cold-start gate accepted an extra managed inbound field'
  fi
  jq -e '.inbounds[0].unexpected == true' "$config" >/dev/null ||
    fail 'steady config rejection changed the unknown field evidence'

  # 配置恢复失败：active journal 与现场必须保留。
  startup_restore_active_fixture
  startup_make_cold
  if (
    landing_restore_snapshot_file() {
      [[ "${2:-}" != config.json ]] || return 81
      command landing_restore_snapshot_file "$@"
    }
    landing_startup_recovery_unlocked
  ); then
    fail 'cold config restore failure was swallowed'
  fi
  jq -e '.phase == "active"' "$LANDING_APPLY_TRANSACTION_JOURNAL" >/dev/null ||
    fail 'cold config restore failure removed active journal'

  # nft 恢复失败：不得写终态或清理证据，修复后可重试。
  startup_restore_active_fixture
  startup_make_cold
  : > "$nft_fail_apply_once"
  if landing_startup_recovery_unlocked; then
    fail 'cold nft restore failure was swallowed'
  fi
  jq -e '.phase == "active"' "$LANDING_APPLY_TRANSACTION_JOURNAL" >/dev/null ||
    fail 'cold nft restore failure removed active journal'
  landing_startup_recovery_unlocked || fail 'cold nft restore did not resume after transient failure'
  startup_assert_baseline_cold

  # 恢复 live nft 后遭 SIGKILL：journal 仍是 active；下一进程继续收敛并清理。
  startup_restore_active_fixture
  startup_make_cold
  startup_kill_ready="$work/startup-kill-ready"
  startup_kill_status=0
  (
    eval "$(declare -f landing_startup_restore_live_nft_snapshot | \
      sed '1s/^landing_startup_restore_live_nft_snapshot /landing_startup_restore_live_nft_snapshot_before_kill /')"
    landing_startup_restore_live_nft_snapshot() {
      landing_startup_restore_live_nft_snapshot_before_kill "$@" || return 1
      : > "$startup_kill_ready"
      while :; do :; done
    }
    landing_startup_recovery_unlocked
  ) 2>/dev/null &
  startup_kill_pid=$!
  for _ in {1..500}; do
    [[ ! -e "$startup_kill_ready" ]] || break
    kill -0 "$startup_kill_pid" 2>/dev/null || break
    sleep 0.01
  done
  [[ -e "$startup_kill_ready" ]] || {
    kill -KILL "$startup_kill_pid" 2>/dev/null || true
    wait "$startup_kill_pid" 2>/dev/null || true
    fail 'cold-start SIGKILL child did not reach nft recovery boundary'
  }
  kill -KILL "$startup_kill_pid"
  if wait "$startup_kill_pid" 2>/dev/null; then
    fail 'cold-start SIGKILL child exited successfully'
  else
    startup_kill_status=$?
  fi
  [[ "$startup_kill_status" == 137 ]] || fail 'cold-start SIGKILL returned unexpected status'
  jq -e '.phase == "active"' "$LANDING_APPLY_TRANSACTION_JOURNAL" >/dev/null ||
    fail 'cold-start SIGKILL removed active journal'
  landing_startup_recovery_unlocked || fail 'cold-start SIGKILL recovery did not resume'
  startup_assert_baseline_cold

  # 终态 cleanup 删除 journal 失败：保留 cleanup proof 与 journal，下一次继续。
  startup_restore_active_fixture
  landing_apply_load_pending_transaction
  package_two_sha="$(jq -r '.content_sha256' "$LANDING_ACTIVE_WORK/apply.json")"
  landing_apply_write_transaction_journal rolled_back "$landing_id" 2 "$package_two_sha"
  landing_apply_reset_active_transaction
  startup_make_cold
  startup_cleanup_fail_once="$work/startup-cleanup-fail-once"
  : > "$startup_cleanup_fail_once"
  if (
    rm() {
      if [[ -e "$startup_cleanup_fail_once" && "$*" == *"$LANDING_APPLY_TRANSACTION_JOURNAL"* ]]; then
        command rm -f -- "$startup_cleanup_fail_once"
        return 82
      fi
      command rm "$@"
    }
    landing_startup_recovery_unlocked
  ); then
    fail 'cold terminal cleanup failure was swallowed'
  fi
  [[ -e "$LANDING_APPLY_TRANSACTION_JOURNAL" &&
     -e "$LANDING_APPLY_TRANSACTION_DIRECTORY/cleanup.started" ]] ||
    fail 'cold cleanup failure did not preserve terminal evidence'
  landing_startup_recovery_unlocked || fail 'cold terminal cleanup did not resume'
  startup_assert_baseline_cold

  # journal 已删除后的 cleanup 中断也必须先校验 steady state；漂移时不能丢证据。
  startup_restore_active_fixture
  landing_apply_load_pending_transaction
  package_two_sha="$(jq -r '.content_sha256' "$LANDING_ACTIVE_WORK/apply.json")"
  landing_apply_write_transaction_journal rolled_back "$landing_id" 2 "$package_two_sha"
  landing_apply_mark_cleanup_started
  rm -f -- "$LANDING_APPLY_TRANSACTION_JOURNAL"
  sync_transaction_path "$LANDING_APPLY_TRANSACTION_DIRECTORY"
  landing_apply_reset_active_transaction
  startup_make_cold
  chmod 750 "$system_root$LANDING_TLS_DIRECTORY"
  if landing_startup_recovery_unlocked; then
    fail 'post-journal cleanup accepted a drifted steady state'
  fi
  [[ ! -e "$LANDING_APPLY_TRANSACTION_JOURNAL" &&
     -e "$LANDING_APPLY_TRANSACTION_DIRECTORY/cleanup.started" ]] ||
    fail 'post-journal drift removed cleanup evidence'
  chmod 700 "$system_root$LANDING_TLS_DIRECTORY"
  landing_startup_recovery_unlocked || fail 'post-journal cleanup did not resume after repair'
  startup_assert_baseline_cold

  # 缺 journal 且仍有 mutation 证据不是 staging/cleanup 残留，必须原样失败关闭。
  startup_restore_active_fixture
  rm -f -- "$LANDING_APPLY_TRANSACTION_JOURNAL"
  startup_make_cold
  if landing_startup_recovery_unlocked; then
    fail 'journal-less active mutation was accepted'
  fi
  [[ -e "$LANDING_APPLY_TRANSACTION_DIRECTORY/mutation.started" &&
     ! -s "$nft_state_file" ]] || fail 'journal-less active mutation changed evidence or live nft'

  startup_reset_baseline
  rm -f -- "$startup_identity"
)

# 运行文件与防火墙已回滚、但旧 receipt 恢复命令失败时，active 现场必须保留并可重试。
eval "$(declare -f landing_restore_receipt_snapshot | \
  sed '1s/^landing_restore_receipt_snapshot /landing_restore_receipt_snapshot_without_fault_injection /')"
restore_active_fixture
landing_apply_load_pending_transaction
active_transaction_work="$LANDING_ACTIVE_WORK"
activate_prepared_transaction
landing_commit_receipt "$active_transaction_work/apply.json" "$LANDING_RECEIPT_FILE" "$(date +%s)"
landing_apply_reset_active_transaction
receipt_restore_fail_once="$work/receipt-restore-fail-once"
: > "$receipt_restore_fail_once"
(
  landing_restore_receipt_snapshot() {
    if [[ -e "$receipt_restore_fail_once" ]]; then
      command rm -f -- "$receipt_restore_fail_once"
      return 78
    fi
    landing_restore_receipt_snapshot_without_fault_injection "$@"
  }
  expect_helper_failure receipt-restore "$package_two" recovery_failed
)
jq -e '.phase == "active"' "$LANDING_APPLY_TRANSACTION_JOURNAL" >/dev/null ||
  fail 'receipt restore failure removed the active journal'
jq -e '.applied_revision == 2' "$LANDING_RECEIPT_FILE" >/dev/null ||
  fail 'receipt restore failure did not preserve the state needing recovery'
expect_helper_failure resumed-receipt-restore "$multiple" invalid_package
assert_baseline_restored

# 生产 `nft list table` 的声明式输出必须只接受精确的入口地址、端口和固定结构。
restore_active_fixture
landing_apply_load_pending_transaction
(
  production_nft_extra=false
  nft() {
    local rendered_port=https
    if [[ "${1:-}" == -nn ]]; then
      rendered_port=25443
      shift
    fi
    if [[ "${1:-}" == list && "${2:-}" == tables ]]; then
      printf 'table inet sb_user_manager_landing\n'
      return
    fi
    if [[ "${1:-}" == list && "${2:-}" == table ]]; then
      printf '%s\n' \
        'table inet sb_user_manager_landing {' \
        '  chain ingress_guard {' \
        '    type filter hook input priority filter - 10; policy accept;' \
        "    ip saddr 198.51.100.50 tcp dport $rendered_port accept" \
        "    tcp dport $rendered_port drop"
      [[ "$production_nft_extra" != true ]] || printf '    tcp dport 22 accept\n'
      printf '%s\n' '  }' '}'
      return
    fi
    return 1
  }
  landing_apply_live_nft_matches_candidate "$LANDING_ACTIVE_WORK/apply.json" ||
    fail 'production nft listing was not recognized as the candidate state'
  production_nft_extra=true
  if landing_apply_live_nft_matches_candidate "$LANDING_ACTIVE_WORK/apply.json"; then
    fail 'nft candidate parser accepted an extra rule'
  fi
)
remove_test_apply_transaction

eval "$(declare -f landing_apply_candidates | \
  sed '1s/^landing_apply_candidates /landing_apply_candidates_before_directory_drift /')"

# 即使 TLS 目录的旧权限也是 0750，候选终态仍必须精确收敛到 0700；
# 若它在最终核验前被改回旧权限，只能回滚并报告验证失败，不能提交。
chmod 750 "$system_root$LANDING_TLS_DIRECTORY"
(
  landing_apply_candidates() {
    landing_apply_candidates_before_directory_drift "$@" || return 1
    chmod 750 "$system_root$LANDING_TLS_DIRECTORY" || return 1
  }
  expect_helper_failure applied-directory-reverted "$package_two" verification_failed
)
[[ "$(manager_file_mode "$system_root$LANDING_TLS_DIRECTORY")" == 750 ]] ||
  fail 'failed exact directory verification did not restore the snapshotted mode'
[[ ! -e "$LANDING_APPLY_TRANSACTION_DIRECTORY" &&
   ! -L "$LANDING_APPLY_TRANSACTION_DIRECTORY" ]] ||
  fail 'failed exact directory verification retained the transaction'
chmod 700 "$system_root$LANDING_TLS_DIRECTORY"
assert_baseline_restored

# 最终核验必须覆盖目录 mode；未知 mode 保留 active 现场，修复漂移后下一请求才能回滚。
(
  landing_apply_candidates() {
    landing_apply_candidates_before_directory_drift "$@" || return 1
    chmod 750 "$system_root$LANDING_TLS_DIRECTORY" || return 1
  }
  expect_helper_failure final-directory-drift "$package_two" rollback_failed
)
[[ -e "$LANDING_APPLY_TRANSACTION_JOURNAL" && ! -L "$LANDING_APPLY_TRANSACTION_JOURNAL" ]] ||
  fail 'directory drift did not preserve the active transaction'
chmod 700 "$system_root$LANDING_TLS_DIRECTORY"
expect_helper_failure resumed-directory-drift "$multiple" invalid_package
assert_baseline_restored

# journal 原子替换前留下的部分临时文件必须按事务 ID 精确清理并继续恢复。
restore_active_fixture
printf '{"partial":' > "$LANDING_APPLY_TRANSACTION_DIRECTORY/.journal.next"
chmod 600 "$LANDING_APPLY_TRANSACTION_DIRECTORY/.journal.next"
expect_helper_failure partial-journal-next "$multiple" invalid_package
assert_baseline_restored
[[ ! -e "$LANDING_APPLY_TRANSACTION_DIRECTORY" &&
   ! -L "$LANDING_APPLY_TRANSACTION_DIRECTORY" ]] ||
  fail 'partial journal temp prevented deterministic recovery'

# cleanup.started 必须在 journal 前持久化；journal 删除失败后下一进程继续核验完整 payload。
restore_active_fixture
journal_cleanup_fail_once="$work/journal-cleanup-fail-once"
: > "$journal_cleanup_fail_once"
(
  rm() {
    if [[ -e "$journal_cleanup_fail_once" && "$*" == *"$LANDING_APPLY_TRANSACTION_JOURNAL"* ]]; then
      command rm -f -- "$journal_cleanup_fail_once"
      return 76
    fi
    command rm "$@"
  }
  expect_helper_failure terminal-journal-cleanup "$multiple" recovery_failed
)
jq -e '.phase == "rolled_back"' "$LANDING_APPLY_TRANSACTION_JOURNAL" >/dev/null ||
  fail 'journal cleanup failure lost the rolled-back terminal state'
[[ -e "$LANDING_APPLY_TRANSACTION_DIRECTORY/cleanup.started" &&
   -e "$LANDING_APPLY_TRANSACTION_DIRECTORY/apply.json" &&
   -d "$LANDING_APPLY_TRANSACTION_DIRECTORY/snapshot" &&
   -e "$LANDING_APPLY_TRANSACTION_DIRECTORY/mutation.started" ]] ||
  fail 'journal cleanup failure crossed the durable cleanup boundary incorrectly'
expect_helper_failure resumed-terminal-journal-cleanup "$multiple" invalid_package
assert_baseline_restored
[[ ! -e "$LANDING_APPLY_TRANSACTION_DIRECTORY" &&
   ! -L "$LANDING_APPLY_TRANSACTION_DIRECTORY" ]] ||
  fail 'resumed terminal journal cleanup retained the transaction'

# 终态清理必须先删除 journal、再删除独立 identity；该边界再次中断也能收敛。
restore_active_fixture
identity_cleanup_fail_once="$work/identity-cleanup-fail-once"
: > "$identity_cleanup_fail_once"
(
  rm() {
    if [[ -e "$identity_cleanup_fail_once" &&
          "$*" == *"$LANDING_APPLY_TRANSACTION_DIRECTORY/transaction.id"* ]]; then
      command rm -f -- "$identity_cleanup_fail_once"
      return 76
    fi
    command rm "$@"
  }
  expect_helper_failure terminal-identity-cleanup "$multiple" recovery_failed
)
[[ ! -e "$LANDING_APPLY_TRANSACTION_JOURNAL" &&
   -e "$LANDING_APPLY_TRANSACTION_DIRECTORY/transaction.id" ]] ||
  fail 'terminal cleanup did not leave the safe post-journal identity boundary'
expect_helper_failure resumed-terminal-identity-cleanup "$multiple" invalid_package
[[ ! -e "$LANDING_APPLY_TRANSACTION_DIRECTORY" &&
   ! -L "$LANDING_APPLY_TRANSACTION_DIRECTORY" ]] ||
  fail 'post-journal identity residue did not converge'

# payload 与阶段标记已同步删除后，才允许删除 cleanup proof。即使在 proof 删除后
# 遭遇不可捕获的 SIGKILL，下一进程也必须把仅剩 identity 的合法残留收敛掉。
restore_active_fixture
landing_apply_load_pending_transaction
package_two_sha="$(jq -r '.content_sha256' "$LANDING_ACTIVE_WORK/apply.json")"
landing_apply_write_transaction_journal rolled_back "$landing_id" 2 "$package_two_sha"
landing_apply_reset_active_transaction
cleanup_proof_delete_ready="$work/cleanup-proof-delete-ready"
cleanup_proof_delete_status=0
(
  rm() {
    local cleanup_removed
    if [[ "$*" == *"$LANDING_APPLY_TRANSACTION_DIRECTORY/cleanup.started"* ]]; then
      [[ ! -e "$LANDING_APPLY_TRANSACTION_JOURNAL" &&
         -e "$LANDING_APPLY_TRANSACTION_DIRECTORY/transaction.id" ]] || return 91
      for cleanup_removed in .validation snapshot receipt-snapshot apply.json gateway-ca.crt \
        gateway.crt gateway.key check-config.json config.json landing.nft nft.rollback \
        receipt.base.json receipt.next.json manifest.sha256 mutation.started runtime.drift \
        service.restart-attempted nft.apply-attempted nft.rollback-attempted; do
        [[ ! -e "$LANDING_APPLY_TRANSACTION_DIRECTORY/$cleanup_removed" &&
           ! -L "$LANDING_APPLY_TRANSACTION_DIRECTORY/$cleanup_removed" ]] || return 91
      done
      command rm "$@" || return 1
      : > "$cleanup_proof_delete_ready" || return 1
      while :; do :; done
    fi
    command rm "$@"
  }
  landing_apply_recover_pending_transaction
) 2>/dev/null &
cleanup_proof_delete_pid=$!
for _ in {1..500}; do
  [[ ! -e "$cleanup_proof_delete_ready" ]] || break
  kill -0 "$cleanup_proof_delete_pid" 2>/dev/null || break
  sleep 0.01
done
if [[ ! -e "$cleanup_proof_delete_ready" ]]; then
  kill -KILL "$cleanup_proof_delete_pid" 2>/dev/null || true
  wait "$cleanup_proof_delete_pid" 2>/dev/null || true
  fail 'terminal cleanup SIGKILL child did not reach cleanup proof deletion'
fi
kill -KILL "$cleanup_proof_delete_pid"
if wait "$cleanup_proof_delete_pid" 2>/dev/null; then
  fail 'terminal cleanup SIGKILL child unexpectedly exited successfully'
else
  cleanup_proof_delete_status=$?
fi
[[ "$cleanup_proof_delete_status" == 137 ]] ||
  fail "terminal cleanup SIGKILL child returned unexpected status $cleanup_proof_delete_status"
[[ ! -e "$LANDING_APPLY_TRANSACTION_JOURNAL" &&
   ! -e "$LANDING_APPLY_TRANSACTION_DIRECTORY/cleanup.started" &&
   ! -e "$LANDING_APPLY_TRANSACTION_DIRECTORY/mutation.started" &&
   ! -e "$LANDING_APPLY_TRANSACTION_DIRECTORY/apply.json" &&
   -e "$LANDING_APPLY_TRANSACTION_DIRECTORY/transaction.id" ]] ||
  fail 'terminal cleanup SIGKILL did not leave the safe identity-only boundary'
landing_apply_reset_active_transaction
expect_helper_failure resumed-proof-deletion-cleanup "$multiple" invalid_package
[[ ! -e "$LANDING_APPLY_TRANSACTION_DIRECTORY" &&
   ! -L "$LANDING_APPLY_TRANSACTION_DIRECTORY" ]] ||
  fail 'cleanup proof deletion residue did not converge'

# journal 已删除后的整目录清理只能由一份严格、单文档的 cleanup proof 授权。
# 在有效 proof 前拼接另一份 JSON 时必须失败关闭并保留全部残留。
restore_active_fixture
landing_apply_load_pending_transaction
package_two_sha="$(jq -r '.content_sha256' "$LANDING_ACTIVE_WORK/apply.json")"
landing_apply_write_transaction_journal rolled_back "$landing_id" 2 "$package_two_sha"
landing_apply_mark_cleanup_started
cleanup_proof="$work/cleanup-proof.json"
install -m 600 -- "$LANDING_APPLY_TRANSACTION_DIRECTORY/cleanup.started" "$cleanup_proof"
rm -f -- "$LANDING_APPLY_TRANSACTION_JOURNAL"
printf '{"tampered":true}\n' > "$LANDING_APPLY_TRANSACTION_DIRECTORY/cleanup.started"
cat "$cleanup_proof" >> "$LANDING_APPLY_TRANSACTION_DIRECTORY/cleanup.started"
chmod 600 "$LANDING_APPLY_TRANSACTION_DIRECTORY/cleanup.started"
landing_apply_reset_active_transaction
expect_helper_failure multi-document-cleanup-proof "$package_two" recovery_failed
[[ ! -e "$LANDING_APPLY_TRANSACTION_JOURNAL" &&
   -e "$LANDING_APPLY_TRANSACTION_DIRECTORY/apply.json" &&
   -e "$LANDING_APPLY_TRANSACTION_DIRECTORY/mutation.started" ]] ||
  fail 'invalid cleanup proof modified the post-journal recovery residue'
install -m 600 -- "$cleanup_proof" "$LANDING_APPLY_TRANSACTION_DIRECTORY/cleanup.started"
expect_helper_failure repaired-cleanup-proof "$multiple" invalid_package
assert_baseline_restored
[[ ! -e "$LANDING_APPLY_TRANSACTION_DIRECTORY" &&
   ! -L "$LANDING_APPLY_TRANSACTION_DIRECTORY" ]] ||
  fail 'valid cleanup proof did not authorize residue cleanup'

# 只有纯 staging 才能在缺少 journal 时清理；已有 mutation 证据必须原样保留。
restore_active_fixture
rm -f -- "$LANDING_APPLY_TRANSACTION_JOURNAL"
expect_helper_failure missing-active-journal "$package_two" recovery_failed
[[ -e "$LANDING_APPLY_TRANSACTION_DIRECTORY/mutation.started" &&
   -e "$LANDING_APPLY_TRANSACTION_DIRECTORY/snapshot/config.json" ]] ||
  fail 'journal-less mutated transaction evidence was removed'
remove_test_apply_transaction

# 固定目标旁的截断临时文件只按当前 journal 的随机 ID 清理，不得碰相邻事务 ID。
restore_active_fixture
landing_apply_load_pending_transaction
target_tmp="$(dirname -- "$config")/.landing-apply.${LANDING_ACTIVE_TRANSACTION_ID}.next"
other_transaction_id="$(printf 'f%.0s' {1..32})"
[[ "$other_transaction_id" != "$LANDING_ACTIVE_TRANSACTION_ID" ]] ||
  other_transaction_id="$(printf 'e%.0s' {1..32})"
other_target_tmp="$(dirname -- "$config")/.landing-apply.${other_transaction_id}.next"
printf 'truncated current transaction\n' > "$target_tmp"
printf 'preserve adjacent transaction\n' > "$other_target_tmp"
chmod 600 "$target_tmp" "$other_target_tmp"
landing_apply_reset_active_transaction
expect_helper_failure partial-target-temp "$multiple" invalid_package
[[ ! -e "$target_tmp" && ! -L "$target_tmp" ]] ||
  fail 'current transaction target temp was not cleaned'
grep -Fxq 'preserve adjacent transaction' "$other_target_tmp" ||
  fail 'adjacent transaction target temp was modified'
rm -f -- "$other_target_tmp"
assert_baseline_restored

# marker 必须遵守持久状态机；不可能的组合只能保留证据并失败关闭。
restore_active_fixture
cp -- "$LANDING_APPLY_TRANSACTION_DIRECTORY/landing.nft" "$nft_state_file"
: > "$runtime_event_log"
expect_helper_failure candidate-nft-without-marker "$package_two" recovery_failed
cmp -s "$baseline/config.json" "$config" ||
  fail 'unmarked candidate nft changed a managed file during failed recovery'
[[ "$(<"$service_state_file")" == active ]] ||
  fail 'unmarked candidate nft changed the service during failed recovery'
[[ ! -s "$runtime_event_log" ]] ||
  fail 'unmarked candidate nft reached a runtime mutation'
cmp -s "$LANDING_APPLY_TRANSACTION_DIRECTORY/landing.nft" "$nft_state_file" ||
  fail 'unmarked candidate nft evidence was overwritten'
cp -- "$baseline/nft-live" "$nft_state_file"
remove_test_apply_transaction

restore_active_fixture
rm -f -- "$LANDING_APPLY_TRANSACTION_DIRECTORY/mutation.started"
: > "$LANDING_APPLY_TRANSACTION_DIRECTORY/service.restart-attempted"
chmod 600 "$LANDING_APPLY_TRANSACTION_DIRECTORY/service.restart-attempted"
expect_helper_failure missing-mutation-marker "$package_two" recovery_failed
[[ -e "$LANDING_APPLY_TRANSACTION_DIRECTORY/service.restart-attempted" ]] ||
  fail 'invalid post-mutation marker evidence was removed'
remove_test_apply_transaction

restore_active_fixture
: > "$LANDING_APPLY_TRANSACTION_DIRECTORY/cleanup.started"
chmod 600 "$LANDING_APPLY_TRANSACTION_DIRECTORY/cleanup.started"
expect_helper_failure active-cleanup-marker "$package_two" recovery_failed
jq -e '.phase == "active"' "$LANDING_APPLY_TRANSACTION_JOURNAL" >/dev/null ||
  fail 'active cleanup marker removed the active journal'
[[ -e "$LANDING_APPLY_TRANSACTION_DIRECTORY/cleanup.started" ]] ||
  fail 'active cleanup marker evidence was removed'
remove_test_apply_transaction

restore_active_fixture
: > "$LANDING_APPLY_TRANSACTION_DIRECTORY/.cleanup.next"
chmod 600 "$LANDING_APPLY_TRANSACTION_DIRECTORY/.cleanup.next"
expect_helper_failure active-cleanup-temp "$package_two" recovery_failed
jq -e '.phase == "active"' "$LANDING_APPLY_TRANSACTION_JOURNAL" >/dev/null ||
  fail 'active cleanup temp removed the active journal'
[[ -e "$LANDING_APPLY_TRANSACTION_DIRECTORY/.cleanup.next" ]] ||
  fail 'active cleanup temp evidence was removed'
remove_test_apply_transaction

restore_active_fixture
(
  marker_sync_armed=false
  sync_transaction_path() {
    if [[ "${1:-}" == "$LANDING_APPLY_TRANSACTION_DIRECTORY/mutation.started" ]]; then
      sync_transaction_path_without_fault_injection "$@" || return 1
      marker_sync_armed=true
      return 0
    fi
    if [[ "$marker_sync_armed" == true && "${1:-}" == "$LANDING_APPLY_TRANSACTION_DIRECTORY" ]]; then
      return 76
    fi
    sync_transaction_path_without_fault_injection "$@"
  }
  expect_helper_failure mutation-marker-sync "$package_two" recovery_failed
)
jq -e '.phase == "active"' "$LANDING_APPLY_TRANSACTION_JOURNAL" >/dev/null ||
  fail 'mutation marker sync failure removed the active journal'
expect_helper_failure resumed-mutation-marker-sync "$multiple" invalid_package
assert_baseline_restored

restore_active_fixture
: > "$LANDING_APPLY_TRANSACTION_DIRECTORY/nft.rollback-attempted"
chmod 600 "$LANDING_APPLY_TRANSACTION_DIRECTORY/nft.rollback-attempted"
expect_helper_failure impossible-nft-marker-sequence "$package_two" recovery_failed
[[ -e "$LANDING_APPLY_TRANSACTION_DIRECTORY/nft.rollback-attempted" ]] ||
  fail 'invalid nft marker sequence was removed'
remove_test_apply_transaction

# rolled_back 终态若记录过候选防火墙应用，就必须也记录过回滚批次尝试。
restore_active_fixture
: > "$LANDING_APPLY_TRANSACTION_DIRECTORY/service.restart-attempted"
: > "$LANDING_APPLY_TRANSACTION_DIRECTORY/nft.apply-attempted"
chmod 600 "$LANDING_APPLY_TRANSACTION_DIRECTORY/service.restart-attempted" \
  "$LANDING_APPLY_TRANSACTION_DIRECTORY/nft.apply-attempted"
landing_apply_load_pending_transaction
package_two_sha="$(jq -r '.content_sha256' "$LANDING_ACTIVE_WORK/apply.json")"
landing_apply_write_transaction_journal rolled_back "$landing_id" 2 "$package_two_sha"
landing_apply_mark_cleanup_started
landing_apply_reset_active_transaction
expect_helper_failure rolled-back-without-nft-rollback-marker "$package_two" recovery_failed
jq -e '.phase == "rolled_back"' "$LANDING_APPLY_TRANSACTION_JOURNAL" >/dev/null ||
  fail 'invalid rolled-back marker state removed the terminal journal'
[[ -e "$LANDING_APPLY_TRANSACTION_DIRECTORY/nft.apply-attempted" ]] ||
  fail 'invalid rolled-back marker state removed recovery evidence'
remove_test_apply_transaction

# rolled_back journal 存在时，缺失 payload 加运行目标漂移不得伪装成合法清理中断。
restore_active_fixture
landing_apply_load_pending_transaction
package_two_sha="$(jq -r '.content_sha256' "$LANDING_ACTIVE_WORK/apply.json")"
landing_apply_write_transaction_journal rolled_back "$landing_id" 2 "$package_two_sha"
landing_apply_reset_active_transaction
install -m 600 -- "$config" "$work/rolled-back-config.before-drift"
rm -f -- "$config"
ln -s "$work/rolled-back-config.before-drift" "$config"
rm -f -- "$LANDING_APPLY_TRANSACTION_DIRECTORY/snapshot/config.json"
expect_helper_failure rolled-back-partial-payload-drift "$package_two" recovery_failed
[[ -L "$config" ]] || fail 'rolled-back partial payload drift changed the target symlink'
jq -e '.phase == "rolled_back"' "$LANDING_APPLY_TRANSACTION_JOURNAL" >/dev/null ||
  fail 'rolled-back partial payload drift removed the terminal journal'
rm -f -- "$config"
install -m 600 -- "$work/rolled-back-config.before-drift" "$config"
install -m 600 -- "$active_fixture/snapshot/config.json" \
  "$LANDING_APPLY_TRANSACTION_DIRECTORY/snapshot/config.json"
expect_helper_failure repaired-rolled-back-partial-payload "$multiple" invalid_package
assert_baseline_restored

restore_active_fixture
original_transaction_id="$(<"$LANDING_APPLY_TRANSACTION_DIRECTORY/transaction.id")"
tampered_transaction_id="$(printf 'a%.0s' {1..32})"
[[ "$tampered_transaction_id" != "$original_transaction_id" ]] ||
  tampered_transaction_id="$(printf 'b%.0s' {1..32})"
jq --arg transaction_id "$tampered_transaction_id" '.transaction_id = $transaction_id' \
  "$LANDING_APPLY_TRANSACTION_JOURNAL" > "$work/tampered-journal.json"
install -m 600 -- "$work/tampered-journal.json" "$LANDING_APPLY_TRANSACTION_JOURNAL"
expect_helper_failure tampered-transaction-id "$package_two" recovery_failed
[[ "$(<"$LANDING_APPLY_TRANSACTION_DIRECTORY/transaction.id")" == "$original_transaction_id" ]] ||
  fail 'transaction identity file changed during failed recovery'
jq -e --arg transaction_id "$tampered_transaction_id" \
  '.transaction_id == $transaction_id and .phase == "active"' \
  "$LANDING_APPLY_TRANSACTION_JOURNAL" >/dev/null ||
  fail 'tampered transaction journal was modified during failed recovery'
remove_test_apply_transaction

restore_active_fixture
printf '{"corrupt":true}\n' > "$LANDING_APPLY_TRANSACTION_JOURNAL"
chmod 600 "$LANDING_APPLY_TRANSACTION_JOURNAL"
expect_helper_failure damaged-journal "$package_two" recovery_failed
grep -Fxq '{"corrupt":true}' "$LANDING_APPLY_TRANSACTION_JOURNAL" ||
  fail 'journal validation failure modified the recovery evidence'
remove_test_apply_transaction

restore_active_fixture
chmod 644 "$LANDING_APPLY_TRANSACTION_JOURNAL"
expect_helper_failure journal-permission "$package_two" recovery_failed
[[ "$(manager_file_mode "$LANDING_APPLY_TRANSACTION_JOURNAL")" == 644 ]] ||
  fail 'journal permission drift was modified during failed recovery'
remove_test_apply_transaction

restore_active_fixture
chmod 1600 "$LANDING_APPLY_TRANSACTION_JOURNAL"
expect_helper_failure journal-special-permission "$package_two" recovery_failed
journal_special_mode="$(stat -c '%a' -- "$LANDING_APPLY_TRANSACTION_JOURNAL" 2>/dev/null ||
  stat -f '%Mp%Lp' "$LANDING_APPLY_TRANSACTION_JOURNAL" 2>/dev/null)"
[[ "$journal_special_mode" == 1600 ]] ||
  fail 'journal special permission drift was modified during failed recovery'
remove_test_apply_transaction

restore_active_fixture
printf 'corrupt manifest\n' >> "$LANDING_APPLY_TRANSACTION_DIRECTORY/manifest.sha256"
expect_helper_failure damaged-manifest "$package_two" recovery_failed
tail -n 1 "$LANDING_APPLY_TRANSACTION_DIRECTORY/manifest.sha256" | grep -Fxq 'corrupt manifest' ||
  fail 'manifest validation failure modified the recovery evidence'
jq -e '.phase == "active"' "$LANDING_APPLY_TRANSACTION_JOURNAL" >/dev/null ||
  fail 'manifest validation failure removed the active journal'
remove_test_apply_transaction

restore_active_fixture
printf 'unknown recovery material\n' > "$LANDING_APPLY_TRANSACTION_DIRECTORY/unknown-file"
chmod 600 "$LANDING_APPLY_TRANSACTION_DIRECTORY/unknown-file"
expect_helper_failure unknown-transaction-file "$package_two" recovery_failed
grep -Fxq 'unknown recovery material' "$LANDING_APPLY_TRANSACTION_DIRECTORY/unknown-file" ||
  fail 'unknown transaction file was removed or modified'
remove_test_apply_transaction

restore_active_fixture
rm -f -- "$LANDING_APPLY_TRANSACTION_DIRECTORY/snapshot/service.state"
ln -s "$work/nonexistent-service-state" \
  "$LANDING_APPLY_TRANSACTION_DIRECTORY/snapshot/service.state"
expect_helper_failure transaction-symlink "$package_two" recovery_failed
[[ -L "$LANDING_APPLY_TRANSACTION_DIRECTORY/snapshot/service.state" ]] ||
  fail 'transaction symlink was removed during failed recovery'
transaction_symlink_target="$(readlink -- "$LANDING_APPLY_TRANSACTION_DIRECTORY/snapshot/service.state")"
[[ "$transaction_symlink_target" == "$work/nonexistent-service-state" ]] ||
  fail 'transaction symlink was modified during failed recovery'
remove_test_apply_transaction

# 回滚中途失败必须保留 active journal；故障解除后下一请求可重复恢复。
restore_active_fixture
landing_apply_load_pending_transaction
active_transaction_work="$LANDING_ACTIVE_WORK"
activate_prepared_transaction
landing_apply_reset_active_transaction
: > "$nft_fail_apply_once"
expect_helper_failure interrupted-rollback "$package_two" recovery_failed
[[ -d "$LANDING_APPLY_TRANSACTION_DIRECTORY" &&
   ! -L "$LANDING_APPLY_TRANSACTION_DIRECTORY" ]] ||
  fail 'failed rollback removed the durable transaction'
jq -e '.phase == "active"' "$LANDING_APPLY_TRANSACTION_JOURNAL" >/dev/null ||
  fail 'failed rollback did not retain the active journal'
expect_helper_failure resumed-rollback "$multiple" invalid_package
assert_baseline_restored
[[ ! -e "$LANDING_APPLY_TRANSACTION_DIRECTORY" &&
   ! -L "$LANDING_APPLY_TRANSACTION_DIRECTORY" ]] ||
  fail 'resumed rollback did not clean the durable transaction'

# 中断回调使用持久 journal 恢复全部运行文件、防火墙、服务和 receipt。
restore_active_fixture
landing_apply_load_pending_transaction
signal_work="$LANDING_ACTIVE_WORK"
active_transaction_work="$signal_work"
activate_prepared_transaction
ACTIVE_SIGNAL_ROLLBACK=landing_apply_signal_rollback
if (landing_apply_handle_signal 143); then fail 'signal handler returned success'; else signal_rc=$?; fi
[[ "$signal_rc" == 143 ]]
assert_baseline_restored
[[ ! -e "$signal_work" ]]
landing_apply_reset_active_transaction

# 正常升级后，过期的相同 revision + 相同内容只能幂等确认，不能再次重载。
# 完整故障注入套件可能超过协议固定的 10 分钟 TTL；正常应用必须在使用前
# 即时重签，不能通过放宽生产 freshness 校验让测试偶然依赖机器速度。
second_apply_issued_at="$(date +%s)"
second_apply_expires_at=$((second_apply_issued_at + LANDING_APPLY_MAX_TTL))
rm -f -- "$package_two" || fail 'could not retire the expired second-apply fixture'
build_package 2 b "$package_two" "$second_apply_issued_at" "$second_apply_expires_at" \
  198.51.100.50 25443
: > "$runtime_event_log"
if ! landing_apply_helper_main < "$package_two" > "$result"; then fail 'second apply failed'; fi
cat "$result" >> "$result_log"
jq -e '.status == "applied" and .revision == 2' "$result" >/dev/null
[[ "$(<"$runtime_event_log")" == $'service-stop\nnft-apply\nservice-restart' ]] ||
  fail "unsafe successful apply event order: $(tr '\n' ' ' < "$runtime_event_log")"
restart_count="$(wc -l < "$service_log" | tr -d ' ')"
expired_issued=$((issued_at - 3600))
expired_expires=$((expired_issued + 300))
package_two_expired="$package_dir/apply-2-expired.json"
build_package 2 c "$package_two_expired" "$expired_issued" "$expired_expires" 198.51.100.50 25443
if ! landing_apply_helper_main < "$package_two_expired" > "$result"; then fail 'idempotent retry failed'; fi
cat "$result" >> "$result_log"
jq -e '.status == "idempotent" and .revision == 2' "$result" >/dev/null
[[ "$(wc -l < "$service_log" | tr -d ' ')" == "$restart_count" ]]

# 完整 committed 现场必须证明已持久记录服务重启与防火墙应用；否则保留证据并失败关闭。
restore_active_fixture
landing_apply_load_pending_transaction
package_two_sha="$(jq -r '.content_sha256' "$LANDING_ACTIVE_WORK/apply.json")"
landing_apply_write_transaction_journal committed "$landing_id" 2 "$package_two_sha"
landing_apply_mark_cleanup_started
landing_apply_reset_active_transaction
expect_helper_failure committed-without-apply-markers "$package_two" recovery_failed
jq -e '.phase == "committed"' "$LANDING_APPLY_TRANSACTION_JOURNAL" >/dev/null ||
  fail 'invalid committed marker state removed the terminal journal'
[[ -e "$LANDING_APPLY_TRANSACTION_DIRECTORY/mutation.started" ]] ||
  fail 'invalid committed marker state removed recovery evidence'
remove_test_apply_transaction

# committed 是新状态的持久线性化点：残留只能清理，重试不得回滚或再次重载。
restore_active_fixture
landing_apply_load_pending_transaction
committed_work="$LANDING_ACTIVE_WORK"
package_two_sha="$(jq -r '.content_sha256' "$committed_work/apply.json")"
: > "$committed_work/service.restart-attempted"
: > "$committed_work/nft.apply-attempted"
chmod 600 "$committed_work/service.restart-attempted" "$committed_work/nft.apply-attempted"
landing_apply_write_transaction_journal committed "$landing_id" 2 "$package_two_sha"
committed_restart_count="$(wc -l < "$service_log" | tr -d ' ')"
jq -e '.applied_revision == 2' "$LANDING_RECEIPT_FILE" >/dev/null ||
  fail 'committed transaction did not retain the new receipt'
landing_apply_reset_active_transaction
if ! landing_apply_helper_main < "$package_two" > "$result"; then
  fail "committed retry failed: $(cat "$result")"
fi
cat "$result" >> "$result_log"
jq -e '.status == "idempotent" and .revision == 2' "$result" >/dev/null ||
  fail 'committed retry was not idempotent'
[[ "$(wc -l < "$service_log" | tr -d ' ')" == "$committed_restart_count" ]] ||
  fail 'committed retry restarted the service'
jq -e '.applied_revision == 2' "$LANDING_RECEIPT_FILE" >/dev/null ||
  fail 'committed recovery rolled the receipt back'
[[ ! -e "$committed_work" && ! -L "$committed_work" ]] ||
  fail 'committed recovery did not clean the stale transaction'

# committed journal 存在时，缺失 payload 加运行目标漂移不得伪装成合法清理中断。
restore_active_fixture
landing_apply_load_pending_transaction
package_two_sha="$(jq -r '.content_sha256' "$LANDING_ACTIVE_WORK/apply.json")"
: > "$LANDING_ACTIVE_WORK/service.restart-attempted"
: > "$LANDING_ACTIVE_WORK/nft.apply-attempted"
chmod 600 "$LANDING_ACTIVE_WORK/service.restart-attempted" \
  "$LANDING_ACTIVE_WORK/nft.apply-attempted"
landing_apply_write_transaction_journal committed "$landing_id" 2 "$package_two_sha"
install -m 600 -- "$ca_certificate" "$work/committed-ca.before-drift"
rm -f -- "$LANDING_ACTIVE_WORK/gateway-ca.crt" "$ca_certificate"
ln -s "$work/committed-ca.before-drift" "$ca_certificate"
landing_apply_reset_active_transaction
expect_helper_failure committed-partial-payload-drift "$package_two" recovery_failed
jq -e '.phase == "committed"' "$LANDING_APPLY_TRANSACTION_JOURNAL" >/dev/null ||
  fail 'committed partial payload drift removed the terminal journal'
[[ -L "$ca_certificate" ]] || fail 'committed partial payload drift changed the target symlink'
rm -f -- "$ca_certificate"
install -m 600 -- "$work/committed-ca.before-drift" "$ca_certificate"
install -m 600 -- "$active_fixture/gateway-ca.crt" \
  "$LANDING_APPLY_TRANSACTION_DIRECTORY/gateway-ca.crt"
if ! landing_apply_helper_main < "$package_two" > "$result"; then
  fail "committed partial payload recovery failed after repair: $(cat "$result")"
fi
cat "$result" >> "$result_log"
jq -e '.status == "idempotent" and .revision == 2' "$result" >/dev/null ||
  fail 'repaired committed payload did not converge idempotently'
[[ ! -e "$LANDING_APPLY_TRANSACTION_DIRECTORY" &&
   ! -L "$LANDING_APPLY_TRANSACTION_DIRECTORY" ]] ||
  fail 'repaired committed transaction was not cleaned'

# committed journal rename 已完成但事务目录 sync 失败时，不得报告 applied；重试只清理并幂等返回。
package_three="$package_dir/apply-3.json"
package_three_issued="$(date +%s)"
package_three_expires=$((package_three_issued + 300))
build_package 3 d "$package_three" "$package_three_issued" "$package_three_expires" \
  203.0.113.50 26443
terminal_sync_failure="$work/terminal-sync-failure"
: > "$terminal_sync_failure"
: > "$runtime_event_log"
(
  sync_transaction_path() {
    if [[ -e "$terminal_sync_failure" && "${1:-}" == "$LANDING_APPLY_TRANSACTION_DIRECTORY" &&
          -f "$LANDING_APPLY_TRANSACTION_JOURNAL" ]] &&
       jq -e '.phase == "committed"' "$LANDING_APPLY_TRANSACTION_JOURNAL" >/dev/null 2>&1; then
      command rm -f -- "$terminal_sync_failure"
      return 79
    fi
    sync_transaction_path_without_fault_injection "$@"
  }
  expect_helper_failure terminal-journal-sync "$package_three" commit_uncertain
)
[[ ! -e "$terminal_sync_failure" ]] || fail 'terminal journal sync failure was not reached'
jq -e '.phase == "committed"' "$LANDING_APPLY_TRANSACTION_JOURNAL" >/dev/null ||
  fail 'terminal journal sync failure did not retain the committed journal'
jq -e '.applied_revision == 3' "$LANDING_RECEIPT_FILE" >/dev/null ||
  fail 'terminal journal sync failure did not retain the committed receipt'
[[ "$(<"$runtime_event_log")" == $'service-stop\nnft-apply\nservice-restart' ]] ||
  fail "terminal sync apply order was unsafe: $(tr '\n' ' ' < "$runtime_event_log")"
terminal_sync_restart_count="$(wc -l < "$service_log" | tr -d ' ')"
if ! landing_apply_helper_main < "$package_three" > "$result"; then
  fail "terminal sync recovery failed: $(cat "$result")"
fi
cat "$result" >> "$result_log"
jq -e '.status == "idempotent" and .revision == 3' "$result" >/dev/null ||
  fail 'terminal sync retry did not converge idempotently'
[[ "$(wc -l < "$service_log" | tr -d ' ')" == "$terminal_sync_restart_count" ]] ||
  fail 'terminal sync retry restarted the service'
[[ ! -e "$LANDING_APPLY_TRANSACTION_DIRECTORY" &&
   ! -L "$LANDING_APPLY_TRANSACTION_DIRECTORY" ]] ||
  fail 'terminal sync retry retained the transaction'

# helper 拒绝参数；结果和外部命令参数均不能包含秘密、SNI 或入口地址。
if landing_apply_helper_main unexpected > "$result"; then fail 'helper accepted arguments'; fi
cat "$result" >> "$result_log"
jq -e '.status == "error" and .code == "arguments_rejected"' "$result" >/dev/null
for sensitive in "$password" "$server_name" 192.0.2.50 198.51.100.50 203.0.113.50 \
  '-----BEGIN PRIVATE KEY-----'; do
  if grep -Fq -- "$sensitive" "$argv_log"; then fail 'sensitive value leaked into argv'; fi
  if grep -Fq -- "$sensitive" "$result_log"; then fail 'sensitive value leaked into result'; fi
done

if find /tmp -maxdepth 1 -type d \
  \( -name 'sb-landing-agent.*' -o -name 'sb-landing-apply-validate.*' \) \
  -print -quit | grep -q .; then
  fail 'landing agent left a temporary plaintext directory'
fi

printf 'landing agent tests passed\n'
