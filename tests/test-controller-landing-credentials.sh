#!/usr/bin/env bash
# 测试桩由生产函数按名称动态调用，并记录生成器外部命令参数。
# shellcheck disable=SC2317
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

fail() {
  printf 'controller landing credentials test failed: %s\n' "$1" >&2
  exit 1
}

real_openssl="$(command -v openssl)"
real_ssh_keygen="$(command -v ssh-keygen)"
openssl_argv="$work/openssl.argv"
ssh_keygen_argv="$work/ssh-keygen.argv"
openssl_wrapper="$work/openssl-wrapper"
ssh_keygen_wrapper="$work/ssh-keygen-wrapper"

cat > "$openssl_wrapper" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' '--- openssl' "$@" >> "$SB_TEST_OPENSSL_ARGV_LOG"
exec "$SB_TEST_REAL_OPENSSL" "$@"
EOF
cat > "$ssh_keygen_wrapper" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' '--- ssh-keygen' "$@" >> "$SB_TEST_SSH_KEYGEN_ARGV_LOG"
exec "$SB_TEST_REAL_SSH_KEYGEN" "$@"
EOF
chmod 700 "$openssl_wrapper" "$ssh_keygen_wrapper"
: > "$openssl_argv"
: > "$ssh_keygen_argv"
chmod 600 "$openssl_argv" "$ssh_keygen_argv"

export SB_TEST_REAL_OPENSSL="$real_openssl"
export SB_TEST_REAL_SSH_KEYGEN="$real_ssh_keygen"
export SB_TEST_OPENSSL_ARGV_LOG="$openssl_argv"
export SB_TEST_SSH_KEYGEN_ARGV_LOG="$ssh_keygen_argv"
export SB_USER_MANAGER_LIBRARY=true
export SB_CONTROLLER_STATE_FILE="$work/controller-state/controller-state.json"
export SB_CONTROLLER_SECRET_DIR="$work/controller-secrets"
export SB_CONTROLLER_STATE_LOCK_FILE="$work/controller-lock/controller-state.lock"
export SB_CONTROLLER_LANDING_CREDENTIAL_OPENSSL_BIN="$openssl_wrapper"
export SB_CONTROLLER_LANDING_CREDENTIAL_SSH_KEYGEN_BIN="$ssh_keygen_wrapper"
# shellcheck source=../sb-user-manager.sh
source "$ROOT/sb-user-manager.sh"

# macOS 本地门禁没有 flock；生产支持范围 Debian 12 由真实 flock 覆盖。
if ! command -v flock >/dev/null 2>&1; then
  flock() { return 0; }
fi

for function_name in controller_initialize_landing_credentials \
  controller_remove_unregistered_landing_credentials \
  controller_landing_credentials_material_is_valid; do
  declare -F "$function_name" >/dev/null 2>&1 || fail "missing function: $function_name"
done

# 只有已经建立且可信的 entry-controller 角色状态才能生成秘密。
if controller_initialize_landing_credentials landing-before-role \
    gw-before-role.internal.example >/dev/null 2>&1; then
  fail 'credential initialization succeeded without controller role state'
fi
[[ ! -e "$SB_CONTROLLER_SECRET_DIR/landing-landing-before-role" &&
   ! -e "$SB_CONTROLLER_SECRET_DIR/landing-landing-before-role.json" ]] ||
  fail 'credential initialization without a role created final material'

init_controller_state || fail 'controller role state could not be initialized'
validate_controller_state_file || fail 'controller role state is invalid'

assert_no_staging() {
  local landing_id="$1"
  if find "$SB_CONTROLLER_SECRET_DIR" -maxdepth 1 \
      \( -name ".landing-credentials.${landing_id}.*" -o \
         -name ".landing-manifest.${landing_id}.*" \) -print -quit | grep -q .; then
    fail "staging material remains for $landing_id"
  fi
}

assert_exact_materials() {
  local landing_id="$1" server_name="$2" directory manifest count path
  directory="$SB_CONTROLLER_SECRET_DIR/landing-$landing_id"
  manifest="$SB_CONTROLLER_SECRET_DIR/landing-$landing_id.json"
  validate_landing_credential_manifest "$manifest" || fail "invalid manifest: $landing_id"
  controller_landing_credentials_material_is_valid "$landing_id" "$server_name" \
    "$directory" || fail "invalid material: $landing_id"
  [[ "$(manager_file_mode "$directory")" == 700 ]] || fail "wrong directory mode: $landing_id"
  [[ "$(manager_file_mode "$manifest")" == 600 ]] || fail "wrong manifest mode: $landing_id"
  count="$(find "$directory" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')"
  [[ "$count" == 5 ]] || fail "unexpected material count: $landing_id"
  for path in ssh-ed25519 gateway-password gateway-ca.crt gateway.crt gateway.key; do
    [[ -f "$directory/$path" && ! -L "$directory/$path" ]] ||
      fail "missing material $path: $landing_id"
    [[ "$(manager_file_mode "$directory/$path")" == 600 ]] ||
      fail "wrong material mode $path: $landing_id"
  done
  [[ ! -e "$directory/ca.key" && ! -e "$directory/gateway.csr" &&
     ! -e "$directory/gateway.conf" && ! -e "$directory/ssh-ed25519.pub" ]] ||
    fail "temporary signing material was retained: $landing_id"
  [[ "$(wc -c < "$directory/gateway-password" | tr -d ' ')" == 64 ]] ||
    fail "gateway password length is invalid: $landing_id"
  assert_no_staging "$landing_id"
}

sni_a=gw-a.internal.example
sni_b=gw-b.internal.example
manifest_a="$SB_CONTROLLER_SECRET_DIR/landing-landing-a.json"
output="$(controller_initialize_landing_credentials landing-a "$sni_a")" ||
  fail 'normal credential initialization failed'
[[ "$output" == "$manifest_a" ]] || fail 'normal initialization returned unexpected output'
assert_exact_materials landing-a "$sni_a"

key_a_sha="$(sha256sum "$SB_CONTROLLER_SECRET_DIR/landing-landing-a/ssh-ed25519" | awk '{print $1}')"
manifest_a_sha="$(sha256sum "$manifest_a" | awk '{print $1}')"
repeat_output="$(controller_initialize_landing_credentials landing-a "$sni_a")" ||
  fail 'idempotent credential initialization failed'
[[ "$repeat_output" == "$manifest_a" ]] || fail 'idempotent initialization returned unexpected output'
[[ "$(sha256sum "$SB_CONTROLLER_SECRET_DIR/landing-landing-a/ssh-ed25519" | awk '{print $1}')" == "$key_a_sha" &&
   "$(sha256sum "$manifest_a" | awk '{print $1}')" == "$manifest_a_sha" ]] ||
  fail 'idempotent initialization replaced existing credentials'

controller_initialize_landing_credentials landing-b "$sni_b" >/dev/null ||
  fail 'second credential initialization failed'
assert_exact_materials landing-b "$sni_b"
directory_a="$SB_CONTROLLER_SECRET_DIR/landing-landing-a"
directory_b="$SB_CONTROLLER_SECRET_DIR/landing-landing-b"
for material in ssh-ed25519 gateway-password gateway-ca.crt gateway.crt gateway.key; do
  [[ "$(sha256sum "$directory_a/$material" | awk '{print $1}')" != \
     "$(sha256sum "$directory_b/$material" | awk '{print $1}')" ]] ||
    fail "two landings shared material: $material"
done

password_a="$(<"$directory_a/gateway-password")"
if grep -Fq -- "$sni_a" "$openssl_argv" || grep -Fq -- "$sni_b" "$openssl_argv" ||
   grep -Fq -- "$password_a" "$openssl_argv" ||
   grep -Fq -- "$sni_a" "$ssh_keygen_argv" || grep -Fq -- "$sni_b" "$ssh_keygen_argv"; then
  fail 'SNI or generated password appeared in an external command argv'
fi
manifest_writer_body="$(declare -f controller_landing_write_credentials_manifest)"
grep -Fq "\$ENV.SB_LANDING_CREDENTIAL_SERVER_NAME" <<< "$manifest_writer_body" ||
  fail 'manifest writer does not read the SNI from the environment'
if grep -Fq -- '--arg server_name' <<< "$manifest_writer_body"; then
  fail 'manifest writer passes the complete SNI in jq argv'
fi

if controller_initialize_landing_credentials bad-id 'bad host.example' >/dev/null 2>&1; then
  fail 'invalid SNI was accepted'
fi
[[ ! -e "$SB_CONTROLLER_SECRET_DIR/landing-bad-id" &&
   ! -e "$SB_CONTROLLER_SECRET_DIR/landing-bad-id.json" ]] ||
  fail 'invalid SNI created final material'

export SB_CONTROLLER_LANDING_CREDENTIAL_TEST_STOP_STAGE=after_material_generated
if controller_initialize_landing_credentials landing-failed gw-failed.internal.example \
    >/dev/null 2>&1; then
  fail 'injected generation failure was ignored'
fi
unset SB_CONTROLLER_LANDING_CREDENTIAL_TEST_STOP_STAGE
[[ ! -e "$SB_CONTROLLER_SECRET_DIR/landing-landing-failed" &&
   ! -e "$SB_CONTROLLER_SECRET_DIR/landing-landing-failed.json" ]] ||
  fail 'pre-publication failure created final material'
assert_no_staging landing-failed

resume_sni=gw-resume.internal.example
export SB_CONTROLLER_LANDING_CREDENTIAL_TEST_STOP_STAGE=after_directory_published
if controller_initialize_landing_credentials landing-resume "$resume_sni" >/dev/null 2>&1; then
  fail 'post-directory checkpoint unexpectedly succeeded'
fi
unset SB_CONTROLLER_LANDING_CREDENTIAL_TEST_STOP_STAGE
[[ -d "$SB_CONTROLLER_SECRET_DIR/landing-landing-resume" &&
   ! -e "$SB_CONTROLLER_SECRET_DIR/landing-landing-resume.json" ]] ||
  fail 'post-directory checkpoint did not preserve the resumable boundary'
controller_landing_credentials_material_is_valid landing-resume "$resume_sni" \
  "$SB_CONTROLLER_SECRET_DIR/landing-landing-resume" ||
  fail 'resumable directory is not complete'

controller_remove_unregistered_landing_credentials landing-resume "$resume_sni" ||
  fail 'strict cleanup could not recover the manifest-absent boundary'
[[ ! -e "$SB_CONTROLLER_SECRET_DIR/landing-landing-resume" &&
   ! -e "$SB_CONTROLLER_SECRET_DIR/landing-landing-resume.json" ]] ||
  fail 'manifest-absent cleanup retained managed material'

controller_initialize_landing_credentials landing-resume "$resume_sni" >/dev/null ||
  fail 'cleaned landing could not be initialized again'
assert_exact_materials landing-resume "$resume_sni"

if controller_remove_unregistered_landing_credentials landing-resume \
    wrong.internal.example >/dev/null 2>&1; then
  fail 'cleanup accepted the wrong SNI'
fi
assert_exact_materials landing-resume "$resume_sni"
controller_remove_unregistered_landing_credentials landing-resume "$resume_sni" ||
  fail 'strict cleanup failed'
[[ ! -e "$SB_CONTROLLER_SECRET_DIR/landing-landing-resume" &&
   ! -e "$SB_CONTROLLER_SECRET_DIR/landing-landing-resume.json" ]] ||
  fail 'strict cleanup retained managed material'

manifest_resume_sni=gw-manifest-resume.internal.example
export SB_CONTROLLER_LANDING_CREDENTIAL_TEST_STOP_STAGE=before_manifest_publish
if controller_initialize_landing_credentials landing-manifest-resume \
    "$manifest_resume_sni" >/dev/null 2>&1; then
  fail 'pre-manifest checkpoint unexpectedly succeeded'
fi
unset SB_CONTROLLER_LANDING_CREDENTIAL_TEST_STOP_STAGE
[[ -d "$SB_CONTROLLER_SECRET_DIR/landing-landing-manifest-resume" &&
   ! -e "$SB_CONTROLLER_SECRET_DIR/landing-landing-manifest-resume.json" ]] ||
  fail 'pre-manifest checkpoint did not preserve the resumable directory'
assert_no_staging landing-manifest-resume
controller_initialize_landing_credentials landing-manifest-resume \
  "$manifest_resume_sni" >/dev/null || fail 'pre-manifest checkpoint did not converge'
controller_remove_unregistered_landing_credentials landing-manifest-resume \
  "$manifest_resume_sni" || fail 'manifest-resume fixture cleanup failed'

symlink_target="$work/symlink-target"
: > "$symlink_target"
ln -s "$symlink_target" "$SB_CONTROLLER_SECRET_DIR/landing-landing-link.json"
if controller_initialize_landing_credentials landing-link gw-link.internal.example \
    >/dev/null 2>&1; then
  fail 'manifest symlink was accepted'
fi
[[ -L "$SB_CONTROLLER_SECRET_DIR/landing-landing-link.json" ]] ||
  fail 'manifest symlink was overwritten or removed'

extra_sni=gw-extra.internal.example
export SB_CONTROLLER_LANDING_CREDENTIAL_TEST_STOP_STAGE=after_directory_published
controller_initialize_landing_credentials landing-extra "$extra_sni" >/dev/null 2>&1 &&
  fail 'extra-file fixture checkpoint unexpectedly succeeded'
unset SB_CONTROLLER_LANDING_CREDENTIAL_TEST_STOP_STAGE
: > "$SB_CONTROLLER_SECRET_DIR/landing-landing-extra/unexpected"
chmod 600 "$SB_CONTROLLER_SECRET_DIR/landing-landing-extra/unexpected"
if controller_initialize_landing_credentials landing-extra "$extra_sni" >/dev/null 2>&1; then
  fail 'orphan directory with an extra file was accepted'
fi
[[ -f "$SB_CONTROLLER_SECRET_DIR/landing-landing-extra/unexpected" ]] ||
  fail 'untrusted extra file was deleted or overwritten'

wide_sni=gw-wide.internal.example
export SB_CONTROLLER_LANDING_CREDENTIAL_TEST_STOP_STAGE=after_directory_published
controller_initialize_landing_credentials landing-wide "$wide_sni" >/dev/null 2>&1 &&
  fail 'wide-directory fixture checkpoint unexpectedly succeeded'
unset SB_CONTROLLER_LANDING_CREDENTIAL_TEST_STOP_STAGE
chmod 755 "$SB_CONTROLLER_SECRET_DIR/landing-landing-wide"
if controller_initialize_landing_credentials landing-wide "$wide_sni" >/dev/null 2>&1; then
  fail 'orphan directory with wide permissions was accepted'
fi
[[ "$(manager_file_mode "$SB_CONTROLLER_SECRET_DIR/landing-landing-wide")" == 755 ]] ||
  fail 'untrusted directory permissions were silently changed'

controller_test_landing_registration_channel() { return 0; }
fingerprint="SHA256:$(printf 'A%.0s' {1..43})"
controller_register_landing landing-b 'Landing B' 192.0.2.20 22 "$fingerprint" 8443 ||
  fail 'registered landing fixture could not be created'
if controller_initialize_landing_credentials landing-b "$sni_b" >/dev/null 2>&1; then
  fail 'registered landing credentials were reinitialized'
fi
if controller_remove_unregistered_landing_credentials landing-b "$sni_b" >/dev/null 2>&1; then
  fail 'registered landing credentials were removed'
fi
assert_exact_materials landing-b "$sni_b"

controller_remove_unregistered_landing_credentials landing-a "$sni_a" ||
  fail 'unregistered landing cleanup failed'
[[ ! -e "$directory_a" && ! -e "$manifest_a" ]] ||
  fail 'unregistered landing cleanup retained material'

printf 'controller landing credential tests passed\n'
