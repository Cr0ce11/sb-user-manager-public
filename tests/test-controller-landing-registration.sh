#!/usr/bin/env bash
# 测试桩由动态 source 的控制器注册函数间接调用。
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
exec "$@"
EOF

cat > "$keyscan_stub" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
: > "$SB_TEST_KEYSCAN_ARGV_LOG"
for argument in "$@"; do
  printf '%s\n' "$argument" >> "$SB_TEST_KEYSCAN_ARGV_LOG"
done
case "${SB_TEST_KEYSCAN_MODE:-valid}" in
  valid)
    read -r key_type key_blob _ < "$SB_TEST_HOST_PUBLIC_KEY_FILE"
    printf '[fixture]:22 %s %s\n' "$key_type" "$key_blob"
    ;;
  ambiguous)
    read -r key_type key_blob _ < "$SB_TEST_HOST_PUBLIC_KEY_FILE"
    printf '[fixture]:22 %s %s\n' "$key_type" "$key_blob"
    read -r key_type key_blob _ < "$SB_TEST_SECOND_HOST_PUBLIC_KEY_FILE"
    printf '[fixture]:22 %s %s\n' "$key_type" "$key_blob"
    ;;
  rsa)
    read -r _ key_blob _ < "$SB_TEST_RSA_PUBLIC_KEY_FILE"
    printf '[fixture]:22 ssh-rsa %s\n' "$key_blob"
    ;;
  malformed)
    printf '%s\n' 'not a host key'
    ;;
  oversized)
    printf '[fixture]:22 ssh-ed25519 '
    printf '%070000d\n' 0
    ;;
  missing) exit 1 ;;
  *) exit 64 ;;
esac
EOF

cat > "$ssh_stub" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
count=0
if [[ -f "$SB_TEST_SSH_COUNT_FILE" ]]; then
  count="$(<"$SB_TEST_SSH_COUNT_FILE")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$SB_TEST_SSH_COUNT_FILE"
{
  printf '%s\n' "CALL:$count"
  for argument in "$@"; do
    printf '%s\n' "$argument"
  done
} >> "$SB_TEST_SSH_ARGV_LOG"
input="$SB_TEST_SSH_INPUT_ROOT/input-$count"
payload="$(/bin/cat)"
if [[ -z "$payload" ]]; then
  (umask 077 && : > "$input")
  case "${SB_TEST_SSH_MODE:-probe-ok}" in
    probe-wrong-code)
      printf '%s\n' '{"status":"error","code":"health_failed"}'
      exit 1
      ;;
    probe-malformed)
      printf '%s\n' '{"status":"error","code":"invalid_input","extra":true}'
      exit 1
      ;;
    probe-zero-exit)
      printf '%s\n' '{"status":"error","code":"invalid_input"}'
      exit 0
      ;;
    probe-timeout) exit 124 ;;
    *)
      printf '%s\n' '{"status":"error","code":"invalid_input"}'
      exit 1
      ;;
    esac
fi
(umask 077 && printf '%s\n' nonempty > "$input")
case "${SB_TEST_SSH_MODE:-probe-ok}" in
  register-apply)
    printf '%s' "$payload" |
      jq -c '{status:"applied",revision:.revision,content_sha256:.content_sha256}'
    ;;
  register-apply-timeout) exit 124 ;;
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
export SB_TEST_KEYSCAN_ARGV_LOG="$work/keyscan.argv"
export SB_TEST_SSH_ARGV_LOG="$work/ssh.argv"
export SB_TEST_SSH_COUNT_FILE="$work/ssh.count"
export SB_TEST_SSH_INPUT_ROOT="$work/ssh-input"
mkdir -m 700 "$SB_TEST_SSH_INPUT_ROOT"

# shellcheck source=../sb-user-manager.sh
source ./sb-user-manager.sh

if ! command -v flock >/dev/null 2>&1; then
  flock() { return 0; }
fi

fail() {
  printf 'controller landing registration test failed: %s\n' "$1" >&2
  exit 1
}

for function_name in controller_landing_scan_ed25519_fingerprint \
  controller_landing_discover_fingerprint controller_test_landing_registration_channel \
  controller_register_landing controller_register_and_apply_landing; do
  declare -F "$function_name" >/dev/null 2>&1 || fail "missing function: $function_name"
done

if grep -Fq 'controller_register_landing' <<<"$(declare -f main)"; then
  fail 'v4 main unexpectedly invokes controller landing registration'
fi
if grep -Fq 'controller_register_landing' <<<"$(declare -f interactive_main)"; then
  fail 'v4 interactive menu unexpectedly invokes controller landing registration'
fi

mkdir -m 700 "$SB_CONTROLLER_SECRET_DIR"

host_private_key="$work/host-ed25519"
second_host_private_key="$work/host-second-ed25519"
rsa_private_key="$work/host-rsa"
ssh-keygen -q -t ed25519 -N '' -f "$host_private_key"
ssh-keygen -q -t ed25519 -N '' -f "$second_host_private_key"
ssh-keygen -q -t rsa -b 2048 -N '' -f "$rsa_private_key"
chmod 600 "$host_private_key" "$host_private_key.pub" "$second_host_private_key" \
  "$second_host_private_key.pub" "$rsa_private_key" "$rsa_private_key.pub"
export SB_TEST_HOST_PUBLIC_KEY_FILE="$host_private_key.pub"
export SB_TEST_SECOND_HOST_PUBLIC_KEY_FILE="$second_host_private_key.pub"
export SB_TEST_RSA_PUBLIC_KEY_FILE="$rsa_private_key.pub"

host_fingerprint="$(ssh-keygen -lf "$host_private_key.pub" -E sha256 | awk 'NR == 1 {print $2}')"
second_host_fingerprint="$(ssh-keygen -lf "$second_host_private_key.pub" -E sha256 | awk 'NR == 1 {print $2}')"
[[ "$host_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || fail 'host fingerprint fixture is invalid'
[[ "$second_host_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || fail 'second fingerprint fixture is invalid'

template="$work/template"
mkdir -m 700 "$template"
server_name=landing-gateway.example.test
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
  -keyout "$template/ca.key" -out "$template/ca.crt" -subj '/CN=registration test CA' \
  >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout "$template/gateway.key" \
  -out "$template/gateway.csr" -subj '/CN=registration test gateway' >/dev/null 2>&1
printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$server_name" \
  > "$template/gateway.ext"
openssl x509 -req -days 2 -in "$template/gateway.csr" -CA "$template/ca.crt" \
  -CAkey "$template/ca.key" -CAcreateserial -out "$template/gateway.crt" \
  -extfile "$template/gateway.ext" >/dev/null 2>&1

create_manifest() {
  local landing_id="$1" secret_dir manifest ssh_key
  secret_dir="$SB_CONTROLLER_SECRET_DIR/landing-$landing_id"
  manifest="$SB_CONTROLLER_SECRET_DIR/landing-$landing_id.json"
  mkdir -m 700 "$secret_dir"
  ssh_key="$secret_dir/ssh-ed25519"
  ssh-keygen -q -t ed25519 -N '' -f "$ssh_key"
  install -m 600 -- "$template/ca.crt" "$secret_dir/gateway-ca.crt"
  install -m 600 -- "$template/gateway.crt" "$secret_dir/gateway.crt"
  install -m 600 -- "$template/gateway.key" "$secret_dir/gateway.key"
  printf 'RegistrationTestGatewayPassword_0123456789' > "$secret_dir/gateway-password"
  chmod 600 "$ssh_key" "$ssh_key.pub" "$secret_dir/gateway-password"
  jq -n --arg landing_id "$landing_id" --arg server_name "$server_name" \
    --arg ssh_key "$ssh_key" --arg password "$secret_dir/gateway-password" \
    --arg ca "$secret_dir/gateway-ca.crt" --arg certificate "$secret_dir/gateway.crt" \
    --arg private_key "$secret_dir/gateway.key" '
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
  validate_landing_credential_manifest "$manifest" || fail "invalid fixture manifest: $landing_id"
}

for landing_id in landing-a landing-b landing-c landing-d; do
  create_manifest "$landing_id"
done

# 候选扫描只输出唯一 Ed25519 SHA256 指纹，并始终清理工作目录。
export SB_TEST_KEYSCAN_MODE=valid
discovered="$(controller_landing_discover_fingerprint 192.0.2.10 2222)" ||
  fail 'valid host fingerprint discovery failed'
[[ "$discovered" == "$host_fingerprint" ]] || fail 'discovered fingerprint does not match fixture'
grep -Fxq -- -t "$SB_TEST_KEYSCAN_ARGV_LOG" || fail 'keyscan does not select a key type'
grep -Fxq -- ed25519 "$SB_TEST_KEYSCAN_ARGV_LOG" || fail 'keyscan does not require Ed25519'
[[ -z "$(find "$SB_CONTROLLER_LANDING_WORK_ROOT" -mindepth 1 -print -quit)" ]] ||
  fail 'fingerprint discovery left work files'

for invalid_mode in ambiguous rsa malformed oversized missing; do
  export SB_TEST_KEYSCAN_MODE="$invalid_mode"
  if controller_landing_discover_fingerprint 192.0.2.10 2222 >/dev/null 2>&1; then
    fail "invalid keyscan mode accepted: $invalid_mode"
  fi
  [[ -z "$(find "$SB_CONTROLLER_LANDING_WORK_ROOT" -mindepth 1 -print -quit)" ]] ||
    fail "invalid keyscan mode left work files: $invalid_mode"
done
export SB_TEST_KEYSCAN_MODE=valid

# 指纹、通道或秘密门禁失败时不得创建控制器状态。
export SB_TEST_SSH_MODE=probe-ok
if controller_register_landing landing-a '测试落地 A' 192.0.2.10 2222 \
    "$second_host_fingerprint" 24443 >/dev/null 2>&1; then
  fail 'mismatched confirmed fingerprint was accepted'
fi
[[ ! -e "$SB_CONTROLLER_STATE_FILE" && ! -L "$SB_CONTROLLER_STATE_FILE" ]] ||
  fail 'fingerprint mismatch created controller state'

for invalid_probe in probe-wrong-code probe-malformed probe-zero-exit probe-timeout; do
  export SB_TEST_SSH_MODE="$invalid_probe"
  if controller_register_landing landing-a '测试落地 A' 192.0.2.10 2222 \
      "$host_fingerprint" 24443 >/dev/null 2>&1; then
    fail "invalid channel probe accepted: $invalid_probe"
  fi
  [[ ! -e "$SB_CONTROLLER_STATE_FILE" && ! -L "$SB_CONTROLLER_STATE_FILE" ]] ||
    fail "invalid channel probe created controller state: $invalid_probe"
done

landing_a_key="$SB_CONTROLLER_SECRET_DIR/landing-landing-a/ssh-ed25519"
chmod 644 "$landing_a_key"
export SB_TEST_SSH_MODE=probe-ok
if controller_register_landing landing-a '测试落地 A' 192.0.2.10 2222 \
    "$host_fingerprint" 24443 >/dev/null 2>&1; then
  fail 'wide SSH private key permissions were accepted'
fi
chmod 600 "$landing_a_key"
[[ ! -e "$SB_CONTROLLER_STATE_FILE" && ! -L "$SB_CONTROLLER_STATE_FILE" ]] ||
  fail 'invalid private key created controller state'

if controller_register_landing landing-a '测试落地 A' 192.0.2.10 2222 \
    "$host_fingerprint" 2222 >/dev/null 2>&1; then
  fail 'identical SSH and gateway ports were accepted'
fi
[[ ! -e "$SB_CONTROLLER_STATE_FILE" && ! -L "$SB_CONTROLLER_STATE_FILE" ]] ||
  fail 'port conflict created controller state'

# 合法通道探测只发送空输入；注册原子新增一条 pending 记录。
: > "$SB_TEST_SSH_ARGV_LOG"
: > "$SB_TEST_SSH_COUNT_FILE"
controller_register_landing landing-a '测试落地 A' 192.0.2.10 2222 \
  "$host_fingerprint" 24443 || fail 'valid landing registration failed'
validate_controller_state_file "$SB_CONTROLLER_STATE_FILE" || fail 'registered state is invalid'
jq -e --arg fingerprint "$host_fingerprint" --arg ref \
  "$SB_CONTROLLER_SECRET_DIR/landing-landing-a.json" '
  .revision == 1 and (.landings | length) == 1 and
  .landings[0] == {
    id:"landing-a",
    display_name:"测试落地 A",
    address:"192.0.2.10",
    ssh_port:2222,
    ssh_host_fingerprint:$fingerprint,
    gateway_port:24443,
    status:"pending",
    desired_revision:1,
    applied_revision:0,
    config_sha256:null,
    credential_ref:$ref
  }
' "$SB_CONTROLLER_STATE_FILE" >/dev/null || fail 'registered state fields are wrong'
[[ ! -s "$SB_TEST_SSH_INPUT_ROOT/input-1" ]] || fail 'registration probe sent a package'
[[ "$(tail -n 1 "$SB_TEST_SSH_ARGV_LOG")" == 192.0.2.10 ]] ||
  fail 'registration SSH invocation appended a remote command'
grep -Fxq -- 'StrictHostKeyChecking=yes' "$SB_TEST_SSH_ARGV_LOG" ||
  fail 'registration probe did not require the pinned host key'
grep -Fxq -- 'PasswordAuthentication=no' "$SB_TEST_SSH_ARGV_LOG" ||
  fail 'registration probe did not disable password authentication'
grep -Fxq -- 'ClearAllForwardings=yes' "$SB_TEST_SSH_ARGV_LOG" ||
  fail 'registration probe did not disable forwarding'
[[ -z "$(find "$SB_CONTROLLER_LANDING_WORK_ROOT" -mindepth 1 -print -quit)" ]] ||
  fail 'valid registration left work files'

# 重复 ID 与重复 address + ssh_port 必须保持状态逐字节不变。
cp "$SB_CONTROLLER_STATE_FILE" "$work/state-before-duplicates"
if controller_register_landing landing-a '重复落地' 192.0.2.20 2224 \
    "$host_fingerprint" 24445 >/dev/null 2>&1; then
  fail 'duplicate landing ID was accepted'
fi
cmp -s "$SB_CONTROLLER_STATE_FILE" "$work/state-before-duplicates" ||
  fail 'duplicate landing ID changed state'
if controller_register_landing landing-b '测试落地 B' 192.0.2.10 2222 \
    "$host_fingerprint" 24446 >/dev/null 2>&1; then
  fail 'duplicate landing endpoint was accepted'
fi
cmp -s "$SB_CONTROLLER_STATE_FILE" "$work/state-before-duplicates" ||
  fail 'duplicate landing endpoint changed state'

# Linux 覆盖注册后真实构包、apply 收敛，以及 apply 失败保留 pending 供重试。
if [[ "$(uname -s)" == Linux ]]; then
  export SB_TEST_SSH_MODE=register-apply
  : > "$SB_TEST_SSH_ARGV_LOG"
  controller_register_and_apply_landing landing-b '测试落地 B' 192.0.2.11 2223 \
    "$host_fingerprint" 24444 198.51.100.10 || fail 'register-and-apply failed'
  jq -e '
    .revision == 3 and
    ([.landings[] | select(.id == "landing-b")] | first) as $landing |
    $landing.status == "active" and $landing.desired_revision == 1 and
    $landing.applied_revision == 1 and
    ($landing.config_sha256 | test("^[0-9a-f]{64}$"))
  ' "$SB_CONTROLLER_STATE_FILE" >/dev/null || fail 'register-and-apply did not converge state'

  export SB_TEST_SSH_MODE=register-apply-timeout
  : > "$SB_TEST_SSH_ARGV_LOG"
  if controller_register_and_apply_landing landing-c '测试落地 C' 192.0.2.12 2224 \
      "$host_fingerprint" 24445 198.51.100.10 >/dev/null 2>&1; then
    fail 'timed-out apply unexpectedly succeeded'
  fi
  jq -e '
    .revision == 4 and
    ([.landings[] | select(.id == "landing-c")] | first) as $landing |
    $landing.status == "pending" and $landing.desired_revision == 1 and
    $landing.applied_revision == 0 and $landing.config_sha256 == null
  ' "$SB_CONTROLLER_STATE_FILE" >/dev/null || fail 'failed apply did not preserve pending registration'
fi

[[ -z "$(find "$SB_CONTROLLER_LANDING_WORK_ROOT" -mindepth 1 -print -quit)" ]] ||
  fail 'registration or apply failure left work files'
for secret in "$(<"$SB_CONTROLLER_SECRET_DIR/landing-landing-a/gateway-password")" \
  "$(<"$SB_CONTROLLER_SECRET_DIR/landing-landing-a/gateway.key")" "$server_name"; do
  if grep -Fq -- "$secret" "$SB_TEST_SSH_ARGV_LOG"; then
    fail 'landing secret appeared in SSH argv'
  fi
done

printf 'controller landing registration tests passed\n'
