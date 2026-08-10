#!/usr/bin/env bash
# 测试桩由动态 source 的控制器传输函数间接调用。
# shellcheck disable=SC2016,SC2317
set -Eeuo pipefail

cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
chmod 700 "$work"

stub_dir="$work/stubs"
mkdir -m 700 "$stub_dir"

ssh_stub="$stub_dir/ssh"
keyscan_stub="$stub_dir/ssh-keyscan"
timeout_stub="$stub_dir/timeout"

cat > "$timeout_stub" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${1:-}" == -k && "${2:-}" =~ ^[0-9]+$ && "${3:-}" =~ ^[0-9]+$ ]] || exit 64
shift 3
if [[ "${SB_TEST_SSH_MODE:-}" == timeout && "${1##*/}" == ssh ]]; then
  exit 124
fi
exec "$@"
EOF

cat > "$keyscan_stub" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${SB_TEST_KEYSCAN_FAIL:-false}" != true ]] || exit 1
[[ -f "${SB_TEST_HOST_PUBLIC_KEY_FILE:-}" ]] || exit 1
read -r key_type key_blob _ < "$SB_TEST_HOST_PUBLIC_KEY_FILE"
printf '[fixture]:22 %s %s\n' "$key_type" "$key_blob"
if [[ -n "${SB_TEST_SECOND_HOST_PUBLIC_KEY_FILE:-}" ]]; then
  read -r key_type key_blob _ < "$SB_TEST_SECOND_HOST_PUBLIC_KEY_FILE"
  printf '[fixture]:22 %s %s\n' "$key_type" "$key_blob"
fi
EOF

cat > "$ssh_stub" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
: > "$SB_TEST_SSH_ARGV_LOG"
for argument in "$@"; do
  printf '%s\n' "$argument" >> "$SB_TEST_SSH_ARGV_LOG"
done
case "${SB_TEST_SSH_MODE:-applied}" in
  applied|idempotent)
    if [[ -n "${SB_TEST_MUTATE_STATE_FILE:-}" ]]; then
      next="${SB_TEST_MUTATE_STATE_FILE}.next"
      jq '.revision += 1 | .landings[0].address = "192.0.2.99"' \
        "$SB_TEST_MUTATE_STATE_FILE" > "$next"
      chmod 600 "$next"
      mv -- "$next" "$SB_TEST_MUTATE_STATE_FILE"
    fi
    jq -c --arg status "${SB_TEST_SSH_MODE:-applied}" \
      '{status:$status,revision:.revision,content_sha256:.content_sha256}'
    ;;
  remote-error)
    jq -e . >/dev/null
    printf '%s\n' '{"status":"error","code":"health_failed"}'
    exit 1
    ;;
  malformed)
    jq -e . >/dev/null
    printf '%s\n%s\n' '{"status":"applied"}' '{"status":"applied"}'
    ;;
  *) exit 64 ;;
esac
EOF
chmod 700 "$ssh_stub" "$keyscan_stub" "$timeout_stub"

export SB_USER_MANAGER_LIBRARY=true
export SB_CONTROLLER_STATE_FILE="$work/state/controller-state.json"
export SB_CONTROLLER_SECRET_DIR="$work/secrets"
export SB_CONTROLLER_STATE_LOCK_FILE="$work/lock/controller-state.lock"
export SB_CONTROLLER_LANDING_WORK_ROOT="$work/runtime"
export SB_CONTROLLER_LANDING_SSH_BIN="$ssh_stub"
export SB_CONTROLLER_LANDING_SSH_KEYSCAN_BIN="$keyscan_stub"
export SB_CONTROLLER_LANDING_SSH_KEYGEN_BIN=/usr/bin/ssh-keygen
export SB_CONTROLLER_LANDING_TIMEOUT_BIN="$timeout_stub"
export SB_CONTROLLER_LANDING_AWK_BIN=/usr/bin/awk
export SB_CONTROLLER_LANDING_SORT_BIN=/usr/bin/sort
export SB_TEST_SSH_ARGV_LOG="$work/ssh.argv"

# shellcheck source=../sb-user-manager.sh
source ./sb-user-manager.sh

if ! command -v flock >/dev/null 2>&1; then
  flock() { return 0; }
fi

fail() {
  printf 'controller landing transport test failed: %s\n' "$1" >&2
  exit 1
}

for function_name in controller_landing_prepare_known_hosts controller_landing_ssh_exchange \
  controller_landing_commit_success controller_apply_landing; do
  declare -F "$function_name" >/dev/null 2>&1 || fail "missing function: $function_name"
done

mkdir -m 700 "$work/state" "$work/secrets" "$work/lock" "$work/runtime"

landing_id=landing-test
landing_secret_dir="$SB_CONTROLLER_SECRET_DIR/landing-$landing_id"
mkdir -m 700 "$landing_secret_dir"
ssh_private_key="$landing_secret_dir/ssh-ed25519"
wrong_host_private_key="$work/wrong-host-ed25519"
host_private_key="$work/host-ed25519"
ssh-keygen -q -t ed25519 -N '' -f "$ssh_private_key"
ssh-keygen -q -t ed25519 -N '' -f "$host_private_key"
ssh-keygen -q -t ed25519 -N '' -f "$wrong_host_private_key"
chmod 600 "$ssh_private_key" "$ssh_private_key.pub" "$host_private_key" \
  "$host_private_key.pub" "$wrong_host_private_key" "$wrong_host_private_key.pub"
export SB_TEST_HOST_PUBLIC_KEY_FILE="$host_private_key.pub"
export SB_TEST_SECOND_HOST_PUBLIC_KEY_FILE=""

host_fingerprint="$(ssh-keygen -lf "$host_private_key.pub" -E sha256 | awk 'NR == 1 {print $2}')"
wrong_host_fingerprint="$(ssh-keygen -lf "$wrong_host_private_key.pub" -E sha256 | awk 'NR == 1 {print $2}')"
[[ "$host_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || fail 'invalid host fixture fingerprint'
[[ "$wrong_host_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || fail 'invalid wrong-host fingerprint'

server_name=landing-gateway.example.test
ca_key="$landing_secret_dir/gateway-ca.key"
ca_certificate="$landing_secret_dir/gateway-ca.crt"
gateway_key="$landing_secret_dir/gateway.key"
gateway_request="$work/gateway.csr"
gateway_certificate="$landing_secret_dir/gateway.crt"
gateway_extensions="$work/gateway.ext"
gateway_password="$landing_secret_dir/gateway-password"
manifest="$SB_CONTROLLER_SECRET_DIR/landing-$landing_id.json"

openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
  -keyout "$ca_key" -out "$ca_certificate" -subj '/CN=transport test CA' >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes \
  -keyout "$gateway_key" -out "$gateway_request" -subj '/CN=transport test gateway' \
  >/dev/null 2>&1
printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$server_name" > "$gateway_extensions"
openssl x509 -req -days 2 -in "$gateway_request" -CA "$ca_certificate" -CAkey "$ca_key" \
  -CAcreateserial -out "$gateway_certificate" -extfile "$gateway_extensions" >/dev/null 2>&1
printf 'TransportTestGatewayPassword_0123456789' > "$gateway_password"
chmod 600 "$ca_key" "$ca_certificate" "$gateway_key" "$gateway_certificate" "$gateway_password"

jq -n --arg landing_id "$landing_id" --arg server_name "$server_name" \
  --arg ssh_key "$ssh_private_key" --arg password "$gateway_password" \
  --arg ca "$ca_certificate" --arg certificate "$gateway_certificate" \
  --arg private_key "$gateway_key" '
  {
    schema_version:1,
    landing_id:$landing_id,
    gateway_server_name:$server_name,
    ssh_private_key_file:$ssh_key,
    gateway_password_file:$password,
    gateway_ca_certificate_file:$ca,
    gateway_certificate_file:$certificate,
    gateway_private_key_file:$private_key
  }
' > "$manifest"
chmod 600 "$manifest"
validate_landing_credential_manifest "$manifest" || fail 'valid credential manifest rejected'

write_state() {
  local revision="$1" desired="$2" applied="$3" status="$4" address="$5" fingerprint="$6"
  local config_sha="$7"
  jq -n --argjson revision "$revision" --argjson desired "$desired" --argjson applied "$applied" \
    --arg status "$status" --arg address "$address" --arg fingerprint "$fingerprint" \
    --arg manifest "$manifest" --arg config_sha "$config_sha" '
    {
      schema_version:1,
      role:"entry-controller",
      revision:$revision,
      landings:[{
        id:"landing-test",
        display_name:"测试落地",
        address:$address,
        ssh_port:2222,
        ssh_host_fingerprint:$fingerprint,
        gateway_port:24443,
        status:$status,
        desired_revision:$desired,
        applied_revision:$applied,
        config_sha256:(if $config_sha == "" then null else $config_sha end),
        credential_ref:$manifest
      }]
    }
  ' > "$SB_CONTROLLER_STATE_FILE"
  chmod 600 "$SB_CONTROLLER_STATE_FILE"
  validate_controller_state_file "$SB_CONTROLLER_STATE_FILE" || fail 'state fixture is invalid'
}

write_private_response() {
  local path="$1" content="$2"
  printf '%s\n' "$content" > "$path"
  chmod 600 "$path"
}

# 主机扫描结果只有唯一 Ed25519 密钥且固定指纹一致时才能形成 known_hosts。
host_case="$work/host-case"
mkdir -m 700 "$host_case"
known_hosts="$(controller_landing_prepare_known_hosts 192.0.2.10 2222 "$host_fingerprint" \
  "sb-landing-$landing_id" "$host_case")" || fail 'valid pinned host key rejected'
grep -Eq "^sb-landing-${landing_id} ssh-ed25519 [A-Za-z0-9+/=]+$" "$known_hosts" ||
  fail 'known_hosts does not use the fixed alias and Ed25519 key'
wrong_fingerprint_case="$work/wrong-fingerprint"
mkdir -m 700 "$wrong_fingerprint_case"
if controller_landing_prepare_known_hosts 192.0.2.10 2222 "$wrong_host_fingerprint" \
  "sb-landing-$landing_id" "$wrong_fingerprint_case" >/dev/null 2>&1; then
  fail 'changed host fingerprint accepted'
fi

ambiguous_case="$work/ambiguous-case"
mkdir -m 700 "$ambiguous_case"
export SB_TEST_SECOND_HOST_PUBLIC_KEY_FILE="$wrong_host_private_key.pub"
if controller_landing_prepare_known_hosts 192.0.2.10 2222 "$host_fingerprint" \
  "sb-landing-$landing_id" "$ambiguous_case" >/dev/null 2>&1; then
  fail 'ambiguous host keys accepted'
fi
export SB_TEST_SECOND_HOST_PUBLIC_KEY_FILE=""

missing_case="$work/missing-case"
mkdir -m 700 "$missing_case"
export SB_TEST_KEYSCAN_FAIL=true
if controller_landing_prepare_known_hosts 192.0.2.10 2222 "$host_fingerprint" \
  "sb-landing-$landing_id" "$missing_case" >/dev/null 2>&1; then
  fail 'missing host key accepted'
fi
unset SB_TEST_KEYSCAN_FAIL

# 回执必须单份、受限大小，并与 SSH 退出状态一致。
valid_sha="$(printf transport-response | sha256sum | awk '{print $1}')"
response_case="$work/response-case"
mkdir -m 700 "$response_case"
success_response="$response_case/success.json"
write_private_response "$success_response" \
  "{\"status\":\"applied\",\"revision\":1,\"content_sha256\":\"$valid_sha\"}"
controller_landing_response_file_is_safe "$success_response" 0 || fail 'valid success response rejected'
if controller_landing_response_file_is_safe "$success_response" 1; then
  fail 'success response accepted with failing SSH status'
fi
error_response="$response_case/error.json"
write_private_response "$error_response" '{"status":"error","code":"health_failed"}'
controller_landing_response_file_is_safe "$error_response" 1 || fail 'valid error response rejected'
if controller_landing_response_file_is_safe "$error_response" 0; then
  fail 'error response accepted with successful SSH status'
fi
multiple_response="$response_case/multiple.json"
printf '%s\n%s\n' '{"status":"error","code":"one"}' '{"status":"error","code":"two"}' \
  > "$multiple_response"
chmod 600 "$multiple_response"
if controller_landing_response_file_is_safe "$multiple_response" 1; then
  fail 'multiple JSON responses accepted'
fi
oversized_response="$response_case/oversized.json"
printf '%0513d' 0 > "$oversized_response"
chmod 600 "$oversized_response"
if controller_landing_response_file_is_safe "$oversized_response" 1; then
  fail 'oversized response accepted'
fi

# 状态写回使用发起时完整落地快照；并发变化后旧回执不能覆盖。
write_state 1 1 0 pending 192.0.2.10 "$host_fingerprint" ''
snapshot="$work/commit-snapshot.json"
jq '.landings[0]' "$SB_CONTROLLER_STATE_FILE" > "$snapshot"
chmod 600 "$snapshot"
wrong_revision_response="$response_case/wrong-revision.json"
write_private_response "$wrong_revision_response" \
  "{\"status\":\"applied\",\"revision\":2,\"content_sha256\":\"$valid_sha\"}"
cp "$SB_CONTROLLER_STATE_FILE" "$work/before-wrong-response"
if controller_landing_commit_success "$landing_id" "$snapshot" "$wrong_revision_response" 1 \
  "$valid_sha" >/dev/null 2>&1; then
  fail 'wrong response revision converged controller state'
fi
cmp -s "$SB_CONTROLLER_STATE_FILE" "$work/before-wrong-response" ||
  fail 'wrong response revision changed controller state'
controller_landing_commit_success "$landing_id" "$snapshot" "$success_response" 1 "$valid_sha" ||
  fail 'valid state convergence failed'
jq -e --arg sha "$valid_sha" '
  .revision == 2 and .landings[0].status == "active" and
  .landings[0].applied_revision == 1 and .landings[0].config_sha256 == $sha
' "$SB_CONTROLLER_STATE_FILE" >/dev/null || fail 'success response did not converge state'
cp "$SB_CONTROLLER_STATE_FILE" "$work/idempotent-state"
fresh_snapshot="$work/fresh-snapshot.json"
jq '.landings[0]' "$SB_CONTROLLER_STATE_FILE" > "$fresh_snapshot"
chmod 600 "$fresh_snapshot"
idempotent_response="$response_case/idempotent.json"
write_private_response "$idempotent_response" \
  "{\"status\":\"idempotent\",\"revision\":1,\"content_sha256\":\"$valid_sha\"}"
controller_landing_commit_success "$landing_id" "$fresh_snapshot" "$idempotent_response" 1 \
  "$valid_sha" || fail 'idempotent state convergence failed'
cmp -s "$SB_CONTROLLER_STATE_FILE" "$work/idempotent-state" ||
  fail 'idempotent convergence changed an already converged state'

stale_snapshot="$work/stale-snapshot.json"
jq '.landings[0]' "$SB_CONTROLLER_STATE_FILE" > "$stale_snapshot"
chmod 600 "$stale_snapshot"
atomic_controller_state_update '.revision += 1 | .landings[0].address = "192.0.2.99"'
cp "$SB_CONTROLLER_STATE_FILE" "$work/stale-state"
if controller_landing_commit_success "$landing_id" "$stale_snapshot" "$success_response" 1 \
  "$valid_sha" >/dev/null 2>&1; then
  fail 'stale success response overwrote concurrent state'
fi
cmp -s "$SB_CONTROLLER_STATE_FILE" "$work/stale-state" ||
  fail 'stale success response changed controller state'

# Linux 覆盖完整构包、stdin 传输、状态收敛和清理；macOS 只执行纯控制器门禁。
if [[ "$(uname -s)" == Linux ]]; then
  write_state 1 1 0 pending 192.0.2.10 "$host_fingerprint" ''
  export SB_TEST_SSH_MODE=applied
  unset SB_TEST_MUTATE_STATE_FILE
  controller_stdout="$work/controller.stdout"
  controller_stderr="$work/controller.stderr"
  controller_apply_landing "$landing_id" 198.51.100.10 \
    > "$controller_stdout" 2> "$controller_stderr" || fail 'full controller apply failed'
  [[ ! -s "$controller_stdout" && ! -s "$controller_stderr" ]] ||
    fail 'successful controller apply emitted unexpected output'
  applied_sha="$(jq -r '.landings[0].config_sha256' "$SB_CONTROLLER_STATE_FILE")"
  jq -e '.revision == 2 and .landings[0].status == "active" and
    .landings[0].desired_revision == 1 and .landings[0].applied_revision == 1 and
    (.landings[0].config_sha256 | test("^[0-9a-f]{64}$"))' \
    "$SB_CONTROLLER_STATE_FILE" >/dev/null || fail 'full apply did not converge state'
  [[ -z "$(find "$SB_CONTROLLER_LANDING_WORK_ROOT" -mindepth 1 -print -quit)" ]] ||
    fail 'full apply left transport work files'

  for sensitive in "$(<"$gateway_password")" "$(<"$gateway_key")" "$server_name"; do
    if grep -Fq -- "$sensitive" "$SB_TEST_SSH_ARGV_LOG"; then
      fail 'secret appeared in SSH argv'
    fi
  done
  if grep -Fq -- 'apply.json' "$SB_TEST_SSH_ARGV_LOG"; then
    fail 'apply package path appeared in SSH argv'
  fi
  grep -Fxq -- -F "$SB_TEST_SSH_ARGV_LOG" || fail 'SSH ignored-user-config option is missing'
  grep -Fxq -- /dev/null "$SB_TEST_SSH_ARGV_LOG" || fail 'SSH does not ignore user config'
  grep -Fxq -- -T "$SB_TEST_SSH_ARGV_LOG" || fail 'SSH does not disable PTY allocation'
  grep -Fxq -- 'StrictHostKeyChecking=yes' "$SB_TEST_SSH_ARGV_LOG" ||
    fail 'SSH does not require the pinned host key'
  grep -Fxq -- 'ForwardAgent=no' "$SB_TEST_SSH_ARGV_LOG" || fail 'SSH agent forwarding was not disabled'
  grep -Fxq -- 'ForwardX11=no' "$SB_TEST_SSH_ARGV_LOG" || fail 'SSH X11 forwarding was not disabled'
  grep -Fxq -- 'ProxyCommand=none' "$SB_TEST_SSH_ARGV_LOG" || fail 'SSH proxy command was not disabled'
  grep -Fxq -- 'ProxyJump=none' "$SB_TEST_SSH_ARGV_LOG" || fail 'SSH proxy jump was not disabled'
  [[ "$(tail -n 1 "$SB_TEST_SSH_ARGV_LOG")" == 192.0.2.10 ]] ||
    fail 'SSH invocation contains a remote command after the target'

  cp "$SB_CONTROLLER_STATE_FILE" "$work/before-idempotent-apply"
  export SB_TEST_SSH_MODE=idempotent
  controller_apply_landing "$landing_id" 198.51.100.10 || fail 'full idempotent retry failed'
  cmp -s "$SB_CONTROLLER_STATE_FILE" "$work/before-idempotent-apply" ||
    fail 'full idempotent retry changed state'

  atomic_controller_state_update '.revision += 1 | .landings[0].desired_revision = 2 |
    .landings[0].status = "pending"'
  cp "$SB_CONTROLLER_STATE_FILE" "$work/before-timeout"
  export SB_TEST_SSH_MODE=timeout
  if controller_apply_landing "$landing_id" 198.51.100.10 >/dev/null 2>&1; then
    fail 'transport timeout unexpectedly succeeded'
  fi
  cmp -s "$SB_CONTROLLER_STATE_FILE" "$work/before-timeout" ||
    fail 'transport timeout changed state'

  export SB_TEST_SSH_MODE=malformed
  if controller_apply_landing "$landing_id" 198.51.100.10 >/dev/null 2>&1; then
    fail 'malformed remote response unexpectedly succeeded'
  fi
  cmp -s "$SB_CONTROLLER_STATE_FILE" "$work/before-timeout" ||
    fail 'malformed remote response changed state'

  atomic_controller_state_update '.revision += 1 | .landings[0].desired_revision = 3'
  export SB_TEST_SSH_MODE=applied
  export SB_TEST_MUTATE_STATE_FILE="$SB_CONTROLLER_STATE_FILE"
  if controller_apply_landing "$landing_id" 198.51.100.10 >/dev/null 2>&1; then
    fail 'concurrent state change unexpectedly accepted an old response'
  fi
  unset SB_TEST_MUTATE_STATE_FILE
  jq -e '.landings[0].address == "192.0.2.99" and
    .landings[0].desired_revision == 3 and .landings[0].applied_revision == 1' \
    "$SB_CONTROLLER_STATE_FILE" >/dev/null ||
    fail 'old remote response overwrote the concurrent landing state'
  [[ -z "$(find "$SB_CONTROLLER_LANDING_WORK_ROOT" -mindepth 1 -print -quit)" ]] ||
    fail 'failure paths left transport work files'
  [[ "$applied_sha" =~ ^[0-9a-f]{64}$ ]] || fail 'full apply digest is invalid'
fi

printf 'controller landing transport tests passed\n'
