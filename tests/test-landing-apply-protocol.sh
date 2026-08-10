#!/usr/bin/env bash
# jq 过滤器中的 $name 来自 jq 参数，不是 Bash 展开。
# 测试桩由动态 source 的协议函数间接调用。
# shellcheck disable=SC2016,SC2034,SC2317
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

export SB_USER_MANAGER_LIBRARY=true
export SB_CONTROLLER_SECRET_DIR="$work/controller-secrets"
export SB_LANDING_RECEIPT_FILE="$work/landing-state/receipt.json"
export SB_LANDING_RECEIPT_LOCK_FILE="$work/landing-lock/receipt.lock"
# shellcheck source=../sb-user-manager.sh
source ./sb-user-manager.sh

if ! command -v flock >/dev/null 2>&1; then
  flock() { return 0; }
fi

fail() {
  printf 'landing apply protocol test failed: %s\n' "$1" >&2
  exit 1
}

report_unexpected_failure() {
  local rc="$1" line="$2"
  trap - ERR
  printf 'landing apply protocol test failed unexpectedly at line %s\n' "$line" >&2
  exit "$rc"
}
trap 'report_unexpected_failure "$?" "$LINENO"' ERR

assert_file_excludes_apply_secrets() {
  local candidate="$1" label="$2"
  if SB_SCAN_PASSWORD_FILE="$secret_dir/gateway-password" \
    SB_SCAN_CA_FILE="$secret_dir/gateway-ca.crt" \
    SB_SCAN_CERTIFICATE_FILE="$secret_dir/gateway.crt" \
    SB_SCAN_PRIVATE_KEY_FILE="$secret_dir/gateway.key" \
    SB_SCAN_SERVER_NAME="$server_name" \
    SB_SCAN_ENTRY_IPV4=192.0.2.50 \
    "$real_python3" -I - "$candidate" <<'PY'
import os
import sys

data = open(sys.argv[1], "rb").read()
probes = {
    open(os.environ["SB_SCAN_PASSWORD_FILE"], "rb").read(),
    os.environ["SB_SCAN_SERVER_NAME"].encode(),
    os.environ["SB_SCAN_ENTRY_IPV4"].encode(),
}
for name in ("SB_SCAN_CA_FILE", "SB_SCAN_CERTIFICATE_FILE", "SB_SCAN_PRIVATE_KEY_FILE"):
    material = open(os.environ[name], "rb").read()
    probes.add(material)
    probes.update(
        line for line in material.splitlines()
        if len(line) >= 16 and not line.startswith(b"-----")
    )
if any(probe and probe in data for probe in probes):
    raise SystemExit(1)
PY
  then
    return 0
  fi
  fail "apply secret leaked into ${label}"
}

read_proc_state() {
  local status_file="$1" status_snapshot label state rest
  if ! status_snapshot="$(<"$status_file")" 2>/dev/null; then
    return 1
  fi
  while read -r label state rest; do
    if [[ "$label" == State: ]]; then
      printf '%s\n' "$state"
      return 0
    fi
  done <<<"$status_snapshot"
  return 1
}

wait_for_stopped_builder_child() {
  local parent="$1" attempt children child state
  local -a child_pids=()
  for ((attempt=0; attempt<500; attempt++)); do
    if [[ -r "/proc/$parent/task/$parent/children" ]]; then
      children="$(<"/proc/$parent/task/$parent/children")"
      read -r -a child_pids <<<"$children"
      for child in "${child_pids[@]}"; do
        if ! state="$(read_proc_state "/proc/$child/status")"; then
          state=''
        fi
        if [[ "$state" == T || "$state" == t ]]; then
          printf '%s\n' "$child"
          return 0
        fi
      done
    fi
    sleep 0.02
  done
  return 1
}

file_can_be_read_now() {
  "$real_python3" -I - "$1" <<'PY'
import sys

try:
    open(sys.argv[1], "rb").read(1)
except OSError:
    raise SystemExit(1)
PY
}

wait_for_builder_exit_bounded() {
  local pid="$1" label="$2"
  if timeout 15 tail --pid="$pid" -f /dev/null; then
    return 0
  fi
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  fail "builder timed out during ${label}"
}

run_builder_until_stopped() {
  local stage="$1" output="$2" stdout_file="$3" stderr_file="$4" runtime_tmp="$5"
  (
    if TMPDIR="$runtime_tmp" SB_LANDING_APPLY_TEST_STOP_STAGE="$stage" \
      build_landing_apply_package "$manifest" 192.0.2.50 24443 1 \
        "$issued_at" "$expires_at" "$nonce_one" "$output"; then
      exit 0
    else
      exit $?
    fi
  ) >"$stdout_file" 2>"$stderr_file" &
  BUILDER_PID=$!
  BUILDER_CHILD="$(wait_for_stopped_builder_child "$BUILDER_PID")" || {
    kill -KILL "$BUILDER_PID" 2>/dev/null || true
    wait "$BUILDER_PID" 2>/dev/null || true
    fail "builder did not stop at ${stage}"
  }
}

run_builder_sigkill_case() {
  local stage="$1" expect_target="$2" case_root output_dir runtime_tmp output
  local stdout_file stderr_file rc entry_count
  local child_state
  case_root="$work/package-sigkill/$stage"
  output_dir="$case_root/output"
  runtime_tmp="$case_root/runtime-tmp"
  mkdir -p "$output_dir" "$runtime_tmp"
  chmod 700 "$case_root" "$output_dir" "$runtime_tmp"
  output="$output_dir/apply.json"
  stdout_file="$case_root/stdout.log"
  stderr_file="$case_root/stderr.log"
  run_builder_until_stopped "$stage" "$output" "$stdout_file" "$stderr_file" "$runtime_tmp"
  if file_can_be_read_now "/proc/$BUILDER_CHILD/cmdline"; then
    assert_file_excludes_apply_secrets "/proc/$BUILDER_CHILD/cmdline" "${stage} helper argv"
  fi
  kill -KILL "$BUILDER_PID"
  if wait "$BUILDER_PID" 2>/dev/null; then rc=0; else rc=$?; fi
  [[ "$rc" == 137 ]] || fail "${stage} builder was not terminated by SIGKILL"
  for _ in {1..200}; do
    if ! child_state="$(read_proc_state "/proc/$BUILDER_CHILD/status")"; then
      child_state=''
    fi
    [[ ! -e "/proc/$BUILDER_CHILD" || "$child_state" == Z ]] && break
    sleep 0.01
  done
  [[ ! -e "/proc/$BUILDER_CHILD" || "$child_state" == Z ]] ||
    fail "${stage} helper survived its parent"
  assert_file_excludes_apply_secrets "$stdout_file" "${stage} stdout"
  assert_file_excludes_apply_secrets "$stderr_file" "${stage} stderr"
  entry_count="$(find "$output_dir" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
  [[ "$(find "$runtime_tmp" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" == 0 ]] ||
    fail "${stage} left an unexpected TMPDIR residue"
  if [[ "$expect_target" == true ]]; then
    [[ "$entry_count" == 1 && -f "$output" && ! -L "$output" ]] ||
      fail "${stage} did not leave exactly one complete target"
    [[ "$(manager_file_mode "$output")" == 600 ]] || fail "${stage} target mode changed"
    [[ "$(manager_file_uid "$output")" == "$(controller_state_expected_uid)" ]] ||
      fail "${stage} target owner changed"
    [[ "$(stat -c '%h' -- "$output")" == 1 ]] || fail "${stage} target has extra links"
    validate_landing_apply_package "$output" "$issued_at" ||
      fail "${stage} target is not a complete compatible package"
  else
    [[ "$entry_count" == 0 && ! -e "$output" && ! -L "$output" ]] ||
      fail "${stage} left a named package residue"
  fi
}

restore_file() {
  local backup="$1" destination="$2"
  rm -f -- "$destination"
  mv -- "$backup" "$destination"
}

rewrite_package_digest() {
  local package="$1" tmp digest
  digest="$(jq -cS '.gateway' "$package" | sha256sum | awk '{print $1}')"
  tmp="$package.digest"
  jq --arg digest "$digest" '.content_sha256 = $digest' "$package" > "$tmp"
  chmod 600 "$tmp"
  mv -- "$tmp" "$package"
}

expect_invalid_manifest() {
  local label="$1" filter="$2" path="$work/invalid-manifest-${1}.json"
  shift 2
  jq "$@" "$filter" "$manifest" > "$path"
  chmod 600 "$path"
  if validate_landing_credential_manifest_json "$path"; then
    fail "invalid manifest accepted: $label"
  fi
}

expect_invalid_package() {
  local label="$1" filter="$2" recompute="${3:-false}" path="$work/invalid-package-${1}.json"
  jq "$filter" "$package_one" > "$path"
  chmod 600 "$path"
  if [[ "$recompute" == true ]]; then rewrite_package_digest "$path"; fi
  if validate_landing_apply_package "$path" "$issued_at"; then
    fail "invalid package accepted: $label"
  fi
}

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
  -subj '/CN=SBM protocol test CA' >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes \
  -keyout "$secret_dir/gateway.key" -out "$work/gateway.csr" \
  -subj '/CN=SBM protocol test gateway' >/dev/null 2>&1
printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$server_name" > "$work/gateway.ext"
openssl x509 -req -days 2 -in "$work/gateway.csr" \
  -CA "$secret_dir/gateway-ca.crt" -CAkey "$work/ca.key" -CAcreateserial \
  -out "$secret_dir/gateway.crt" -extfile "$work/gateway.ext" >/dev/null 2>&1
chmod 600 "$secret_dir/ssh-ed25519" "$secret_dir/gateway-password" \
  "$secret_dir/gateway-ca.crt" "$secret_dir/gateway.crt" "$secret_dir/gateway.key"

jq -n \
  --arg landing_id "$landing_id" \
  --arg server_name "$server_name" \
  --arg secret_dir "$secret_dir" '
    {
      schema_version: 1,
      landing_id: $landing_id,
      gateway_server_name: $server_name,
      ssh_private_key_file: ($secret_dir + "/ssh-ed25519"),
      gateway_password_file: ($secret_dir + "/gateway-password"),
      gateway_ca_certificate_file: ($secret_dir + "/gateway-ca.crt"),
      gateway_certificate_file: ($secret_dir + "/gateway.crt"),
      gateway_private_key_file: ($secret_dir + "/gateway.key")
    }
  ' > "$manifest"
chmod 600 "$manifest"

# 仅加载脚本不会创建秘密、下发包或落地 receipt。
[[ ! -e "$LANDING_RECEIPT_FILE" && ! -L "$LANDING_RECEIPT_FILE" ]]
if grep -Fq 'init_landing_receipt' <<<"$(declare -f main)"; then
  fail 'main must not initialize a landing receipt'
fi
if grep -Fq 'build_landing_apply_package' <<<"$(declare -f interactive_main)"; then
  fail 'the v4 menu must not build landing packages'
fi

validate_landing_credential_manifest "$manifest"

# 清单拒绝内联秘密、越界路径、宽权限和符号链接。
expect_invalid_manifest schema '.schema_version = 2'
expect_invalid_manifest unknown-field '.password = "inline-secret"'
expect_invalid_manifest landing-id '.landing_id = "Landing_A"'
expect_invalid_manifest relative-path '.ssh_private_key_file = "ssh-ed25519"'
expect_invalid_manifest outside-path '.gateway_password_file = "/tmp/gateway-password"'
expect_invalid_manifest mismatched-path '.gateway_certificate_file = ($root + "/landing-other/gateway.crt")' \
  --arg root "$CONTROLLER_SECRET_DIR"
expect_invalid_manifest sni '.gateway_server_name = "bad host.example"'

wide_manifest="$work/wide-manifest.json"
cp "$manifest" "$wide_manifest"
chmod 644 "$wide_manifest"
if validate_landing_credential_manifest "$wide_manifest"; then fail 'wide manifest accepted'; fi
linked_manifest="$work/linked-manifest.json"
ln -s "$manifest" "$linked_manifest"
if validate_landing_credential_manifest "$linked_manifest"; then fail 'linked manifest accepted'; fi

mv "$secret_dir/ssh-ed25519" "$secret_dir/ssh-ed25519.real"
ln -s "$secret_dir/ssh-ed25519.real" "$secret_dir/ssh-ed25519"
if validate_landing_credential_manifest "$manifest"; then fail 'linked SSH key accepted'; fi
restore_file "$secret_dir/ssh-ed25519.real" "$secret_dir/ssh-ed25519"

cp "$secret_dir/gateway-password" "$work/password.valid"
printf 'short' > "$secret_dir/gateway-password"
chmod 600 "$secret_dir/gateway-password"
if validate_landing_credential_manifest "$manifest"; then fail 'weak gateway password accepted'; fi
restore_file "$work/password.valid" "$secret_dir/gateway-password"

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
  -out "$work/wrong-gateway.key" >/dev/null 2>&1
chmod 600 "$work/wrong-gateway.key"
mv "$secret_dir/gateway.key" "$work/gateway.key.valid"
cp "$work/wrong-gateway.key" "$secret_dir/gateway.key"
chmod 600 "$secret_dir/gateway.key"
if validate_landing_credential_manifest "$manifest"; then fail 'mismatched TLS key accepted'; fi
restore_file "$work/gateway.key.valid" "$secret_dir/gateway.key"

if validate_controller_tls_material \
    "$secret_dir/gateway-ca.crt" "$secret_dir/gateway.crt" "$secret_dir/gateway.key" \
    'wrong.example.test'; then
  fail 'mismatched certificate SNI accepted'
fi

# 恢复历史事务时按证书有效期交集选取 attime，不得再次依赖当前时钟有效性。
(
  openssl() {
    if [[ "$*" == *'-checkend 3600'* ]]; then return 87; fi
    "$real_openssl" "$@"
  }
  if validate_controller_tls_material \
      "$secret_dir/gateway-ca.crt" "$secret_dir/gateway.crt" "$secret_dir/gateway.key" \
      "$server_name" current; then
    fail 'injected current-time certificate failure was ignored'
  fi
  validate_controller_tls_material \
    "$secret_dir/gateway-ca.crt" "$secret_dir/gateway.crt" "$secret_dir/gateway.key" \
    "$server_name" historical ||
    fail 'historical certificate validation still depended on the current time'
)

# 构建有效的短时 apply package，秘密不进入外部命令 argv。
package_dir="$work/packages"
mkdir -m 700 "$package_dir"
issued_at=1800000000
expires_at=$((issued_at + 300))
nonce_one="$(printf 'a%.0s' {1..64})"
package_one="$package_dir/apply-1.json"

: > "$argv_log"
capture_external_argv=true

builder_body="$(declare -f build_landing_apply_package)"
for forbidden in gateway_tmp package_tmp '.landing-apply.gateway' \
  '.landing-apply.package' 'mktemp ' 'register_temp_path' 'validate_landing_apply_package'; do
  if grep -Fq -- "$forbidden" <<<"$builder_body"; then
    fail "builder still contains named or extracting staging logic: $forbidden"
  fi
done
for required in os.O_TMPFILE memfd_create linkat safe_fsync RLIMIT_CORE \
  PR_SET_PDEATHSIG PR_SET_DUMPABLE validate_tls_snapshot; do
  grep -Fq -- "$required" <<<"$builder_body" || fail "builder lacks anonymous publish guard: $required"
done
if grep -Eq -- '--arg (password|server_name|allowed_entry_ipv4)' <<<"$builder_body"; then
  fail 'builder passes sensitive values through jq argv'
fi

if [[ "$(uname -s)" != Linux ]]; then
  unsupported_output="$package_dir/unsupported.json"
  unsupported_log="$work/unsupported-platform.log"
  if build_landing_apply_package "$manifest" 192.0.2.50 24443 1 \
      "$issued_at" "$expires_at" "$nonce_one" "$unsupported_output" 2>"$unsupported_log"; then
    fail 'unsupported platform unexpectedly published an apply package'
  fi
  grep -Fq '不支持安全的匿名 apply package 发布' "$unsupported_log" ||
    fail 'unsupported platform failure was not explicit'
  [[ ! -e "$unsupported_output" && ! -L "$unsupported_output" ]]
  assert_file_excludes_apply_secrets "$unsupported_log" 'unsupported-platform stderr'
  assert_file_excludes_apply_secrets "$argv_log" 'unsupported-platform argv log'
  printf 'landing apply protocol Linux runtime checks skipped after fail-closed platform check\n'
  exit 0
fi

SB_LANDING_APPLY_TEST_DIAGNOSTICS=true \
build_landing_apply_package "$manifest" 192.0.2.50 24443 1 \
  "$issued_at" "$expires_at" "$nonce_one" "$package_one"
validate_landing_apply_package "$package_one" "$issued_at"
[[ "$(manager_file_mode "$package_one")" == 600 ]]
[[ "$(stat -c '%h' -- "$package_one")" == 1 ]]
jq -e --rawfile password "$secret_dir/gateway-password" --slurpfile manifest "$manifest" '
  .gateway.password == $password and .gateway.server_name == $manifest[0].gateway_server_name
' "$package_one" >/dev/null
assert_file_excludes_apply_secrets "$argv_log" 'external argv log'

# 测试专用地跳过 direct，仍真实执行 /proc/self/fd + AT_SYMLINK_FOLLOW 发布。
forced_proc_package="$package_dir/apply-forced-proc.json"
forced_proc_nonce="$(printf 'e%.0s' {1..64})"
SB_LANDING_APPLY_TEST_FORCE_LINK_METHOD=proc \
SB_LANDING_APPLY_TEST_EXPECT_LINK_METHOD=proc \
build_landing_apply_package "$manifest" 192.0.2.50 24443 8 \
  "$issued_at" "$expires_at" "$forced_proc_nonce" "$forced_proc_package"
validate_landing_apply_package "$forced_proc_package" "$issued_at"
[[ "$(manager_file_mode "$forced_proc_package")" == 600 ]]
[[ "$(stat -c '%h' -- "$forced_proc_package")" == 1 ]]

# 匿名构建器保持旧 jq 校验与 --rawfile 的兼容语义：单个末尾换行仍计入密码与摘要。
legacy_password_backup="$work/gateway-password.before-legacy-newline"
cp "$secret_dir/gateway-password" "$legacy_password_backup"
chmod 600 "$legacy_password_backup"
printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n' > "$secret_dir/gateway-password"
chmod 600 "$secret_dir/gateway-password"
legacy_gateway_reference="$work/legacy-trailing-newline-gateway.json"
SB_LANDING_ALLOWED_ENTRY_IPV4=192.0.2.50 jq -n \
  --slurpfile manifest "$manifest" \
  --rawfile password "$secret_dir/gateway-password" \
  --rawfile ca_certificate "$secret_dir/gateway-ca.crt" \
  --rawfile certificate "$secret_dir/gateway.crt" \
  --rawfile private_key "$secret_dir/gateway.key" \
  --argjson gateway_port 24443 '
    {
      listen_port: $gateway_port,
      server_name: $manifest[0].gateway_server_name,
      password: $password,
      allowed_entry_ipv4: $ENV.SB_LANDING_ALLOWED_ENTRY_IPV4,
      ca_certificate_pem: $ca_certificate,
      certificate_pem: $certificate,
      private_key_pem: $private_key
    }
  ' > "$legacy_gateway_reference"
legacy_digest="$(jq -cS . "$legacy_gateway_reference" | sha256sum | awk '{print $1}')"
legacy_password_package="$package_dir/apply-trailing-newline.json"
legacy_nonce="$(printf 'd%.0s' {1..64})"
build_landing_apply_package "$manifest" 192.0.2.50 24443 9 \
  "$issued_at" "$expires_at" "$legacy_nonce" "$legacy_password_package"
validate_landing_apply_package "$legacy_password_package" "$issued_at"
jq -e --slurpfile gateway "$legacy_gateway_reference" --arg digest "$legacy_digest" '
  .gateway == $gateway[0] and .content_sha256 == $digest and
  (.gateway.password | endswith("\n"))
' "$legacy_password_package" >/dev/null
restore_file "$legacy_password_backup" "$secret_dir/gateway-password"

# 严格拒绝未知字段、摘要篡改、非法网络参数、时效和超限输入。
expect_invalid_package schema '.schema_version = 2'
expect_invalid_package unknown-field '.gateway.unexpected = true'
expect_invalid_package nonce '.nonce = "short"'
expect_invalid_package digest '.gateway.listen_port = 24444'
expect_invalid_package password '.gateway.password = "short"' true
expect_invalid_package port '.gateway.listen_port = 0' true
expect_invalid_package ip '.gateway.allowed_entry_ipv4 = "999.1.1.1"' true
expect_invalid_package sni '.gateway.server_name = "bad host.example"' true
expect_invalid_package revision '.revision = 0'
expect_invalid_package ttl ".expires_at = (.issued_at + $((LANDING_APPLY_MAX_TTL + 1)))"

multiple_pem_package="$work/multiple-pem-package.json"
jq '.gateway.ca_certificate_pem += .gateway.ca_certificate_pem' \
  "$package_one" > "$multiple_pem_package"
chmod 600 "$multiple_pem_package"
rewrite_package_digest "$multiple_pem_package"
if validate_landing_apply_package "$multiple_pem_package" "$issued_at"; then
  fail 'multiple PEM blocks accepted'
fi

huge_revision_output="$package_dir/huge-revision.json"
if build_landing_apply_package "$manifest" 192.0.2.50 24443 \
    999999999999999999999999999999 "$issued_at" "$expires_at" "$nonce_one" \
    "$huge_revision_output"; then
  fail 'oversized revision accepted by builder'
fi
[[ ! -e "$huge_revision_output" && ! -L "$huge_revision_output" ]]

multiple_package="$work/multiple-package.json"
printf '%s\n%s\n' "$(cat "$package_one")" "$(cat "$package_one")" > "$multiple_package"
chmod 600 "$multiple_package"
if validate_landing_apply_package "$multiple_package" "$issued_at"; then fail 'multiple package documents accepted'; fi
oversized_package="$work/oversized-package.json"
cp "$package_one" "$oversized_package"
dd if=/dev/zero bs=1 count=$((LANDING_APPLY_MAX_BYTES + 1)) >> "$oversized_package" 2>/dev/null
chmod 600 "$oversized_package"
if landing_apply_package_structure_is_valid "$oversized_package"; then fail 'oversized package accepted'; fi
if validate_landing_apply_package "$package_one" "$expires_at"; then fail 'expired package accepted'; fi

existing_output="$package_dir/existing-output.json"
printf 'keep-existing\n' > "$existing_output"
chmod 600 "$existing_output"
if build_landing_apply_package "$manifest" 192.0.2.50 24443 1 \
    "$issued_at" "$expires_at" "$nonce_one" "$existing_output"; then
  fail 'builder overwrote an existing target'
fi
[[ "$(<"$existing_output")" == keep-existing ]]
linked_output="$package_dir/linked-output.json"
ln -s "$existing_output" "$linked_output"
if build_landing_apply_package "$manifest" 192.0.2.50 24443 1 \
    "$issued_at" "$expires_at" "$nonce_one" "$linked_output"; then
  fail 'builder accepted a target symlink'
fi
[[ -L "$linked_output" && "$(<"$existing_output")" == keep-existing ]]

for unsupported_stage in directory_fsync anonymous_open file_fsync link; do
  unsupported_dir="$work/forced-unsupported-$unsupported_stage"
  mkdir -m 700 "$unsupported_dir"
  unsupported_output="$unsupported_dir/apply.json"
  unsupported_log="$unsupported_dir/stderr.log"
  if SB_LANDING_APPLY_TEST_FORCE_UNSUPPORTED_AT="$unsupported_stage" \
    build_landing_apply_package "$manifest" 192.0.2.50 24443 1 \
      "$issued_at" "$expires_at" "$nonce_one" "$unsupported_output" 2>"$unsupported_log"; then
    fail "forced unsupported ${unsupported_stage} unexpectedly succeeded"
  fi
  grep -Fq '不支持安全的匿名 apply package 发布' "$unsupported_log" ||
    fail "unsupported ${unsupported_stage} failure was not explicit"
  [[ ! -e "$unsupported_output" && ! -L "$unsupported_output" ]]
  [[ "$(find "$unsupported_dir" -mindepth 1 -maxdepth 1 ! -name stderr.log | wc -l | tr -d ' ')" == 0 ]]
  assert_file_excludes_apply_secrets "$unsupported_log" "unsupported ${unsupported_stage} stderr"
done

validation_residue_before="$work/validation-residue.before"
validation_residue_after="$work/validation-residue.after"
find /tmp -maxdepth 1 -name 'sb-landing-apply-validate.*' -print | LC_ALL=C sort \
  > "$validation_residue_before"
for stage in before_secret_read sources_read gateway_assembled package_write_started \
  package_written before_validation validation_material_ready after_validation \
  after_file_sync before_publish; do
  run_builder_sigkill_case "$stage" false
done
run_builder_sigkill_case after_publish true
run_builder_sigkill_case after_directory_sync true
find /tmp -maxdepth 1 -name 'sb-landing-apply-validate.*' -print | LC_ALL=C sort \
  > "$validation_residue_after"
cmp -s "$validation_residue_before" "$validation_residue_after" ||
  fail 'SIGKILL package builds left a named validation directory'
[[ "$(find "$work/package-sigkill" -name '.landing-apply.*' | wc -l | tr -d ' ')" == 0 ]]
assert_file_excludes_apply_secrets "$argv_log" 'SIGKILL external argv log'

mutation_dir="$work/package-source-mutation"
mutation_output_dir="$mutation_dir/output"
mutation_tmp="$mutation_dir/runtime-tmp"
mkdir -p "$mutation_output_dir" "$mutation_tmp"
chmod 700 "$mutation_dir" "$mutation_output_dir" "$mutation_tmp"
mutation_output="$mutation_output_dir/apply.json"
mutation_stdout="$mutation_dir/stdout.log"
mutation_stderr="$mutation_dir/stderr.log"
valid_private_key="$work/gateway.key.before-source-mutation"
cp "$secret_dir/gateway.key" "$valid_private_key"
chmod 600 "$valid_private_key"
run_builder_until_stopped before_secret_read \
  "$mutation_output" "$mutation_stdout" "$mutation_stderr" "$mutation_tmp"
cp "$work/wrong-gateway.key" "$secret_dir/gateway.key"
chmod 600 "$secret_dir/gateway.key"
kill -CONT "$BUILDER_CHILD"
wait_for_builder_exit_bounded "$BUILDER_PID" 'secret source mutation'
if wait "$BUILDER_PID"; then mutation_rc=0; else mutation_rc=$?; fi
assert_file_excludes_apply_secrets "$mutation_stdout" 'mutated-source stdout'
assert_file_excludes_apply_secrets "$mutation_stderr" 'mutated-source stderr'
restore_file "$valid_private_key" "$secret_dir/gateway.key"
((mutation_rc != 0)) || fail 'builder accepted TLS material changed after initial validation'
[[ ! -e "$mutation_output" && ! -L "$mutation_output" ]]
[[ "$(find "$mutation_output_dir" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" == 0 ]]
[[ "$(find "$mutation_tmp" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" == 0 ]]
assert_file_excludes_apply_secrets "$mutation_stdout" 'original-source stdout'
assert_file_excludes_apply_secrets "$mutation_stderr" 'original-source stderr'

race_dir="$work/package-publish-race"
race_output_dir="$race_dir/output"
race_tmp="$race_dir/runtime-tmp"
mkdir -p "$race_output_dir" "$race_tmp"
chmod 700 "$race_dir" "$race_output_dir" "$race_tmp"
race_output="$race_output_dir/apply.json"
race_stdout="$race_dir/stdout.log"
race_stderr="$race_dir/stderr.log"
run_builder_until_stopped before_publish \
  "$race_output" "$race_stdout" "$race_stderr" "$race_tmp"
printf 'keep-race-winner\n' > "$race_output"
chmod 600 "$race_output"
kill -CONT "$BUILDER_CHILD"
wait_for_builder_exit_bounded "$BUILDER_PID" 'publish boundary race'
if wait "$BUILDER_PID"; then race_rc=0; else race_rc=$?; fi
((race_rc != 0)) || fail 'builder overwrote a target created at the publish boundary'
[[ "$(<"$race_output")" == keep-race-winner ]]
[[ "$(find "$race_output_dir" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" == 1 ]]
[[ "$(find "$race_tmp" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" == 0 ]]
assert_file_excludes_apply_secrets "$race_stdout" 'publish-race stdout'
assert_file_excludes_apply_secrets "$race_stderr" 'publish-race stderr'
assert_file_excludes_apply_secrets "$argv_log" 'publish-race external argv log'

# receipt 初始化幂等；新包、幂等重试、旧包和异常状态具有明确结果。
init_landing_receipt "$landing_id"
validate_landing_receipt_file
[[ "$(manager_file_mode "$LANDING_RECEIPT_FILE")" == 600 ]]
cp "$LANDING_RECEIPT_FILE" "$work/receipt.empty"
init_landing_receipt "$landing_id"
cmp -s "$LANDING_RECEIPT_FILE" "$work/receipt.empty"
[[ "$(landing_apply_replay_decision "$package_one" "$LANDING_RECEIPT_FILE" "$issued_at")" == apply ]]
commit_landing_apply_receipt "$package_one" "$LANDING_RECEIPT_FILE" "$issued_at"
jq -e '.applied_revision == 1 and .content_sha256 != null and .nonce != null' \
  "$LANDING_RECEIPT_FILE" >/dev/null
cp "$LANDING_RECEIPT_FILE" "$work/receipt.revision-one"
[[ "$(landing_apply_replay_decision "$package_one" "$LANDING_RECEIPT_FILE" "$((expires_at + 100))")" == idempotent ]]
commit_landing_apply_receipt "$package_one" "$LANDING_RECEIPT_FILE" "$((expires_at + 100))"
cmp -s "$LANDING_RECEIPT_FILE" "$work/receipt.revision-one"

same_revision_tampered="$package_dir/same-revision-tampered.json"
jq '.gateway.listen_port = 24444' "$package_one" > "$same_revision_tampered"
chmod 600 "$same_revision_tampered"
rewrite_package_digest "$same_revision_tampered"
if landing_apply_replay_decision "$same_revision_tampered" "$LANDING_RECEIPT_FILE" "$issued_at"; then
  fail 'same revision with different content accepted'
fi

nonce_two="$(printf 'b%.0s' {1..64})"
package_two="$package_dir/apply-2.json"
build_landing_apply_package "$manifest" 192.0.2.50 24443 2 \
  "$issued_at" "$expires_at" "$nonce_two" "$package_two"
[[ "$(landing_apply_replay_decision "$package_two" "$LANDING_RECEIPT_FILE" "$issued_at")" == apply ]]
commit_landing_apply_receipt "$package_two" "$LANDING_RECEIPT_FILE" "$issued_at"
cp "$LANDING_RECEIPT_FILE" "$work/receipt.revision-two"
if landing_apply_replay_decision "$package_one" "$LANDING_RECEIPT_FILE" "$issued_at"; then
  fail 'older revision accepted'
fi

package_three="$package_dir/apply-3.json"
build_landing_apply_package "$manifest" 192.0.2.50 24443 3 \
  "$issued_at" "$expires_at" "$nonce_two" "$package_three"
if landing_apply_replay_decision "$package_three" "$LANDING_RECEIPT_FILE" "$issued_at"; then
  fail 'reused nonce accepted for a new revision'
fi

nonce_three="$(printf 'c%.0s' {1..64})"
package_four="$package_dir/apply-4.json"
build_landing_apply_package "$manifest" 192.0.2.50 24443 4 \
  "$issued_at" "$expires_at" "$nonce_three" "$package_four"
if landing_apply_replay_decision "$package_four" "$LANDING_RECEIPT_FILE" "$expires_at"; then
  fail 'expired new revision accepted'
fi

wrong_landing_package="$package_dir/wrong-landing.json"
jq '.landing_id = "landing-b"' "$package_four" > "$wrong_landing_package"
chmod 600 "$wrong_landing_package"
if landing_apply_replay_decision "$wrong_landing_package" "$LANDING_RECEIPT_FILE" "$issued_at"; then
  fail 'package for another landing accepted'
fi

receipt_tmp="$work/receipt.override"
jq '.emergency_override = true' "$LANDING_RECEIPT_FILE" > "$receipt_tmp"
chmod 600 "$receipt_tmp"
mv "$receipt_tmp" "$LANDING_RECEIPT_FILE"
if landing_apply_replay_decision "$package_four" "$LANDING_RECEIPT_FILE" "$issued_at"; then
  fail 'automatic apply accepted during emergency override'
fi
cp "$work/receipt.revision-two" "$LANDING_RECEIPT_FILE"
chmod 600 "$LANDING_RECEIPT_FILE"

# receipt 提交失败必须保留旧状态并清理临时文件。
(
  chmod() { return 77; }
  if commit_landing_apply_receipt "$package_four" "$LANDING_RECEIPT_FILE" "$issued_at"; then
    fail 'receipt chmod failure unexpectedly committed'
  fi
)
cmp -s "$LANDING_RECEIPT_FILE" "$work/receipt.revision-two"
(
  mv() { return 78; }
  if commit_landing_apply_receipt "$package_four" "$LANDING_RECEIPT_FILE" "$issued_at"; then
    fail 'receipt mv failure unexpectedly committed'
  fi
)
cmp -s "$LANDING_RECEIPT_FILE" "$work/receipt.revision-two"
[[ "$(find "$(dirname "$LANDING_RECEIPT_FILE")" -maxdepth 1 -type f -name '.landing-receipt.*' | wc -l | tr -d ' ')" == 0 ]]

# receipt 初始化必须先持久化临时文件，再原子替换并持久化父目录。
init_file_sync_dir="$work/init-file-sync-failure"
init_file_sync_receipt="$init_file_sync_dir/receipt.json"
(
  LANDING_RECEIPT_FILE="$init_file_sync_receipt"
  LANDING_RECEIPT_LOCK_FILE="$work/init-file-sync-failure.lock"
  init_file_sync_injected=false
  sync_transaction_path() {
    [[ "$1" == "$init_file_sync_dir"/.landing-receipt.* ]] ||
      fail 'receipt init synced an unexpected path before file sync failure'
    init_file_sync_injected=true
    return 79
  }
  if init_landing_receipt "$landing_id"; then
    fail 'receipt init file sync failure unexpectedly succeeded'
  fi
  [[ "$init_file_sync_injected" == true ]] || fail 'receipt init file sync failure was not injected'
)
[[ ! -e "$init_file_sync_receipt" && ! -L "$init_file_sync_receipt" ]]
[[ "$(find "$init_file_sync_dir" -maxdepth 1 -type f -name '.landing-receipt.*' | wc -l | tr -d ' ')" == 0 ]]

init_dir_sync_dir="$work/init-directory-sync-failure"
init_dir_sync_receipt="$init_dir_sync_dir/receipt.json"
(
  LANDING_RECEIPT_FILE="$init_dir_sync_receipt"
  LANDING_RECEIPT_LOCK_FILE="$work/init-directory-sync-failure.lock"
  init_file_sync_observed=false
  init_dir_sync_injected=false
  sync_transaction_path() {
    if [[ "$1" == "$init_dir_sync_dir"/.landing-receipt.* ]]; then
      init_file_sync_observed=true
      return 0
    fi
    [[ "$1" == "$init_dir_sync_dir" ]] || fail 'receipt init synced an unexpected parent path'
    [[ "$init_file_sync_observed" == true ]] || fail 'receipt init synced its parent before its file'
    jq -e '.applied_revision == 0' "$LANDING_RECEIPT_FILE" >/dev/null ||
      fail 'receipt init synced its parent before atomic replacement'
    init_dir_sync_injected=true
    return 80
  }
  if init_landing_receipt "$landing_id"; then
    fail 'receipt init directory sync failure unexpectedly succeeded'
  fi
  [[ "$init_dir_sync_injected" == true ]] || fail 'receipt init directory sync failure was not injected'
)
validate_landing_receipt_file "$init_dir_sync_receipt"
jq -e '.applied_revision == 0' "$init_dir_sync_receipt" >/dev/null
[[ "$(find "$init_dir_sync_dir" -maxdepth 1 -type f -name '.landing-receipt.*' | wc -l | tr -d ' ')" == 0 ]]

# 提交临时文件 sync 失败时旧 receipt 不得变化；目录 sync 失败时必须报告失败，
# 但不得回滚已经原子替换且结构完整的新 receipt。
commit_file_sync_dir="$work/commit-file-sync-failure"
commit_file_sync_receipt="$commit_file_sync_dir/receipt.json"
install -d -m 700 "$commit_file_sync_dir"
cp "$work/receipt.revision-two" "$commit_file_sync_receipt"
chmod 600 "$commit_file_sync_receipt"
(
  LANDING_RECEIPT_FILE="$commit_file_sync_receipt"
  LANDING_RECEIPT_LOCK_FILE="$work/commit-file-sync-failure.lock"
  commit_file_sync_injected=false
  sync_transaction_path() {
    [[ "$1" == "$commit_file_sync_dir"/.landing-receipt.* ]] ||
      fail 'receipt commit synced an unexpected path before file sync failure'
    commit_file_sync_injected=true
    return 81
  }
  if commit_landing_apply_receipt "$package_four" "$LANDING_RECEIPT_FILE" "$issued_at"; then
    fail 'receipt commit file sync failure unexpectedly succeeded'
  fi
  [[ "$commit_file_sync_injected" == true ]] || fail 'receipt commit file sync failure was not injected'
)
cmp -s "$commit_file_sync_receipt" "$work/receipt.revision-two"
[[ "$(find "$commit_file_sync_dir" -maxdepth 1 -type f -name '.landing-receipt.*' | wc -l | tr -d ' ')" == 0 ]]

commit_dir_sync_dir="$work/commit-directory-sync-failure"
commit_dir_sync_receipt="$commit_dir_sync_dir/receipt.json"
install -d -m 700 "$commit_dir_sync_dir"
cp "$work/receipt.revision-two" "$commit_dir_sync_receipt"
chmod 600 "$commit_dir_sync_receipt"
(
  LANDING_RECEIPT_FILE="$commit_dir_sync_receipt"
  LANDING_RECEIPT_LOCK_FILE="$work/commit-directory-sync-failure.lock"
  commit_file_sync_observed=false
  commit_dir_sync_injected=false
  sync_transaction_path() {
    if [[ "$1" == "$commit_dir_sync_dir"/.landing-receipt.* ]]; then
      commit_file_sync_observed=true
      return 0
    fi
    [[ "$1" == "$commit_dir_sync_dir" ]] || fail 'receipt commit synced an unexpected parent path'
    [[ "$commit_file_sync_observed" == true ]] || fail 'receipt commit synced its parent before its file'
    jq -e '.applied_revision == 4' "$LANDING_RECEIPT_FILE" >/dev/null ||
      fail 'receipt commit synced its parent before atomic replacement'
    commit_dir_sync_injected=true
    return 82
  }
  if commit_landing_apply_receipt "$package_four" "$LANDING_RECEIPT_FILE" "$issued_at"; then
    fail 'receipt commit directory sync failure unexpectedly succeeded'
  fi
  [[ "$commit_dir_sync_injected" == true ]] || fail 'receipt commit directory sync failure was not injected'
)
validate_landing_receipt_file "$commit_dir_sync_receipt"
jq -e '.applied_revision == 4' "$commit_dir_sync_receipt" >/dev/null
[[ "$(find "$commit_dir_sync_dir" -maxdepth 1 -type f -name '.landing-receipt.*' | wc -l | tr -d ' ')" == 0 ]]

# 完整构建、校验和 receipt 流程均不得把真实秘密或入口地址放入外部命令参数。
if grep -Fq -- "$password" "$argv_log"; then fail 'gateway password leaked into later argv'; fi
if grep -Fq -- "$server_name" "$argv_log"; then fail 'gateway SNI leaked into later argv'; fi
if grep -Fq -- '192.0.2.50' "$argv_log"; then fail 'entry address leaked into later argv'; fi

printf 'landing apply protocol tests passed\n'
