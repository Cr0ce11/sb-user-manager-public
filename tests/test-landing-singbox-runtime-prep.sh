#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2317,SC2329
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME="${SB_LANDING_SINGBOX_PREP_RUNTIME:-$ROOT/sb-user-manager.sh}"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

fail() {
  printf 'landing sing-box runtime preparation test failed: %s\n' "$1" >&2
  exit 1
}

export SB_USER_MANAGER_LIBRARY=true
export SB_CONTROLLER_STATE_FILE="$work/controller-state/state.json"
export SB_CONTROLLER_SECRET_DIR="$work/controller-secrets"
export SB_CONTROLLER_STATE_LOCK_FILE="$work/controller-lock/state.lock"
export SB_CONTROLLER_LANDING_WORK_ROOT="$work/controller-work"
export SB_LANDING_SINGBOX_PREP_TEST_ROOT="$work/remote"
export SB_LANDING_SINGBOX_PREP_TEST_SYSTEM=Linux
export SB_LANDING_SINGBOX_PREP_TEST_MACHINE=x86_64
export SB_LANDING_SINGBOX_PREP_TEST_TOOL_DIR="$work/remote-tools"
unset SB_LANDING_SINGBOX_PREP_TEST_FAILURE
# shellcheck source=../sb-user-manager.sh
source "$RUNTIME"

for function_name in controller_landing_singbox_release_is_valid \
  controller_landing_fetch_stable_singbox_release \
  controller_landing_prepare_verified_singbox_binary \
  controller_landing_build_singbox_runtime_package \
  controller_landing_singbox_response_is_valid \
  controller_landing_prepare_singbox_runtime_in_work \
  controller_prepare_landing_singbox_runtime; do
  declare -F "$function_name" >/dev/null 2>&1 || fail "missing function: $function_name"
done

mkdir -m 700 "$SB_CONTROLLER_SECRET_DIR" "$SB_CONTROLLER_LANDING_WORK_ROOT" \
  "$SB_LANDING_SINGBOX_PREP_TEST_ROOT" "$SB_LANDING_SINGBOX_PREP_TEST_TOOL_DIR"
mkdir -m 700 "$SB_LANDING_SINGBOX_PREP_TEST_ROOT/usr" \
  "$SB_LANDING_SINGBOX_PREP_TEST_ROOT/usr/local" \
  "$SB_LANDING_SINGBOX_PREP_TEST_ROOT/usr/local/bin"
printf 'ID=debian\nVERSION_ID="12"\n' > "$SB_LANDING_SINGBOX_PREP_TEST_ROOT/os-release"
chmod 644 "$SB_LANDING_SINGBOX_PREP_TEST_ROOT/os-release"

write_tool_wrapper() {
  local name="$1" target="$2"
  printf '#!/bin/bash\nexec %q "$@"\n' "$target" > "$SB_LANDING_SINGBOX_PREP_TEST_TOOL_DIR/$name"
  chmod 700 "$SB_LANDING_SINGBOX_PREP_TEST_TOOL_DIR/$name"
}

host_ln="$(command -v ln)"
write_tool_wrapper bash "$(command -v bash)"
write_tool_wrapper base64 "$(command -v base64)"
write_tool_wrapper chmod "$(command -v chmod)"
write_tool_wrapper ln "$host_ln"
write_tool_wrapper mktemp "$(command -v mktemp)"
write_tool_wrapper rm "$(command -v rm)"
write_tool_wrapper sha256sum "$(command -v sha256sum)"
write_tool_wrapper stat "$(command -v stat)"
write_tool_wrapper sync "$(command -v sync)"
write_tool_wrapper uname "$(command -v uname)"

make_fake_singbox() {
  local path="$1" version="$2"
  printf '#!/bin/bash\nif [[ "$1" == version ]]; then printf "sing-box version %s\\n"; else exit 64; fi\n' \
    "$version" > "$path"
  chmod 700 "$path"
}

version=1.12.3
asset="sing-box-${version}-linux-amd64.tar.gz"
url="https://github.com/SagerNet/sing-box/releases/download/v${version}/${asset}"
release_sha="$(printf 'a%.0s' {1..64})"
controller_landing_singbox_release_is_valid "$version" "$asset" "$url" "$release_sha" ||
  fail 'valid official stable release was rejected'
if controller_landing_singbox_release_is_valid "${version}-rc.1" \
    "sing-box-${version}-rc.1-linux-amd64.tar.gz" \
    "https://github.com/SagerNet/sing-box/releases/download/v${version}-rc.1/sing-box-${version}-rc.1-linux-amd64.tar.gz" \
    "$release_sha"; then
  fail 'preview version was accepted as stable'
fi
if controller_landing_singbox_release_is_valid "$version" "$asset" \
    "https://example.com/$asset" "$release_sha"; then
  fail 'non-official release URL was accepted'
fi
if controller_landing_singbox_release_is_valid "$version" "$asset" "$url" bad-digest; then
  fail 'malformed release digest was accepted'
fi

(
  github_api_get() {
    jq -n --arg version "v$version" --arg name "$asset" --arg url "$url" \
      --arg digest "sha256:$release_sha" '
      {tag_name:$version,assets:[{name:$name,browser_download_url:$url,digest:$digest}]}
    '
  }
  controller_landing_fetch_stable_singbox_release || fail 'official stable metadata fetch failed'
  [[ "$CONTROLLER_LANDING_SINGBOX_RELEASE_VERSION" == "$version" &&
     "$CONTROLLER_LANDING_SINGBOX_RELEASE_ASSET" == "$asset" &&
     "$CONTROLLER_LANDING_SINGBOX_RELEASE_URL" == "$url" &&
     "$CONTROLLER_LANDING_SINGBOX_RELEASE_SHA256" == "$release_sha" ]] ||
    fail 'official stable metadata drifted'
)

local_binary="$work/sing-box"
make_fake_singbox "$local_binary" "$version"
binary_sha="$(sha256sum "$local_binary" | awk '{print $1}')"
controller_landing_local_singbox_binary_is_valid "$local_binary" "$version" "$binary_sha" ||
  fail 'valid local binary was rejected'
if controller_landing_local_singbox_binary_is_valid "$local_binary" 9.9.9 "$binary_sha"; then
  fail 'local binary with wrong version was accepted'
fi
if controller_landing_local_singbox_binary_is_valid "$local_binary" "$version" "$release_sha"; then
  fail 'local binary with wrong digest was accepted'
fi

# 下载、摘要、成员或版本准备失败时，不能产生后续可发送的二进制。
(
  controller_landing_fetch_stable_singbox_release() {
    CONTROLLER_LANDING_SINGBOX_RELEASE_VERSION="$version"
    CONTROLLER_LANDING_SINGBOX_RELEASE_ASSET="$asset"
    CONTROLLER_LANDING_SINGBOX_RELEASE_URL="$url"
    CONTROLLER_LANDING_SINGBOX_RELEASE_SHA256="$release_sha"
  }
  prepare_singbox_release_binary() { return 1; }
  prepare_work="$work/prepare-failure"
  mkdir -m 700 "$prepare_work"
  if controller_landing_prepare_verified_singbox_binary "$prepare_work"; then
    fail 'failed official asset preparation was accepted'
  fi
  [[ -z "$CONTROLLER_LANDING_SINGBOX_PREPARED_BINARY" ]] ||
    fail 'failed release preparation exposed a binary'
)

run_package() {
  PACKAGE_OUTPUT=""
  if PACKAGE_OUTPUT="$(/bin/bash "$1")"; then PACKAGE_RC=0; else PACKAGE_RC=$?; fi
}

reset_remote_target() {
  rm -f -- "$SB_LANDING_SINGBOX_PREP_TEST_ROOT/usr/local/bin/sing-box"
  chmod 700 "$SB_LANDING_SINGBOX_PREP_TEST_ROOT/usr/local/bin"
  chmod 700 "$SB_LANDING_SINGBOX_PREP_TEST_TOOL_DIR"/*
  printf 'ID=debian\nVERSION_ID="12"\n' > "$SB_LANDING_SINGBOX_PREP_TEST_ROOT/os-release"
  chmod 644 "$SB_LANDING_SINGBOX_PREP_TEST_ROOT/os-release"
}

package="$work/runtime-package.sh"
controller_landing_build_singbox_runtime_package "$version" "$local_binary" "$package" ||
  fail 'runtime package build failed'
controller_landing_private_file_is_trusted "$package" || fail 'runtime package is not private'
grep -Fq "expected_version=$version" "$package" || fail 'package version binding is missing'
grep -Fq "expected_sha256=$binary_sha" "$package" || fail 'package binary digest binding is missing'
grep -Fq '__SB_LANDING_SINGBOX_BINARY__' "$package" || fail 'package payload marker is missing'
if grep -Eq '/etc/sing-box|/etc/sb-user-manager|/var/lib/sb-user-manager|systemctl|nft' "$package"; then
  fail 'runtime package references configuration, state or service paths'
fi
if controller_landing_build_singbox_runtime_package "$version" "$local_binary" "$package"; then
  fail 'package builder overwrote an existing output'
fi

# 干净目标只安装一次；断线后的同包重试必须收敛为 ready。
reset_remote_target
run_package "$package"
target="$SB_LANDING_SINGBOX_PREP_TEST_ROOT/usr/local/bin/sing-box"
[[ "$PACKAGE_RC" == 0 && "$PACKAGE_OUTPUT" == '{"status":"installed"}' ]] ||
  fail "clean runtime install failed: $PACKAGE_RC/$PACKAGE_OUTPUT"
[[ -x "$target" && ! -L "$target" && "$(sha256sum "$target" | awk '{print $1}')" == "$binary_sha" ]] ||
  fail 'installed target does not match the verified binary'
run_package "$package"
[[ "$PACKAGE_RC" == 0 && "$PACKAGE_OUTPUT" == '{"status":"ready"}' ]] ||
  fail 'idempotent retry did not converge to ready'

# 不安全或不同的已有目标必须原样保留，绝不能覆盖。
reset_remote_target
make_fake_singbox "$target" 9.9.9
conflict_sha="$(sha256sum "$target" | awk '{print $1}')"
run_package "$package"
[[ "$PACKAGE_RC" == 22 && "$PACKAGE_OUTPUT" == '{"status":"error","code":"existing_conflict"}' ]] ||
  fail 'different existing target was not rejected'
[[ "$(sha256sum "$target" | awk '{print $1}')" == "$conflict_sha" ]] ||
  fail 'different existing target was overwritten'
chmod 777 "$target"
run_package "$package"
[[ "$PACKAGE_RC" == 21 && "$PACKAGE_OUTPUT" == '{"status":"error","code":"unsafe_existing"}' ]] ||
  fail 'unsafe existing target was not rejected'

# 固定工具、平台、载荷、安装与复检失败都必须稳定失败且不留下目标。
reset_remote_target
chmod 777 "$SB_LANDING_SINGBOX_PREP_TEST_TOOL_DIR/ln"
run_package "$package"
[[ "$PACKAGE_RC" == 23 && "$PACKAGE_OUTPUT" == '{"status":"error","code":"unsafe_runtime"}' ]] ||
  fail 'unsafe fixed runtime tool was accepted'
[[ ! -e "$target" ]] || fail 'unsafe runtime created a target'

reset_remote_target
export SB_LANDING_SINGBOX_PREP_TEST_MACHINE=aarch64
unsupported_package="$work/unsupported-package.sh"
controller_landing_build_singbox_runtime_package "$version" "$local_binary" "$unsupported_package" ||
  fail 'unsupported platform package build failed'
export SB_LANDING_SINGBOX_PREP_TEST_MACHINE=x86_64
run_package "$unsupported_package"
[[ "$PACKAGE_RC" == 20 && "$PACKAGE_OUTPUT" == '{"status":"error","code":"unsupported_platform"}' ]] ||
  fail 'unsupported platform was accepted'

reset_remote_target
corrupt_package="$work/corrupt-package.sh"
awk '
  found && !changed && /^[A-Za-z0-9+\/=]+$/ { sub(/^./, "!"); changed=1 }
  { print }
  /__SB_LANDING_SINGBOX_BINARY__/ { found=1 }
' "$package" > "$corrupt_package"
chmod 600 "$corrupt_package"
run_package "$corrupt_package"
[[ "$PACKAGE_RC" == 30 && "$PACKAGE_OUTPUT" == '{"status":"error","code":"payload_invalid"}' ]] ||
  fail 'corrupt embedded payload was accepted'
[[ ! -e "$target" ]] || fail 'corrupt payload created a target'

export SB_LANDING_SINGBOX_PREP_TEST_FAILURE=install
install_failure_package="$work/install-failure-package.sh"
controller_landing_build_singbox_runtime_package "$version" "$local_binary" \
  "$install_failure_package" || fail 'install failure package build failed'
unset SB_LANDING_SINGBOX_PREP_TEST_FAILURE
run_package "$install_failure_package"
[[ "$PACKAGE_RC" == 32 && "$PACKAGE_OUTPUT" == '{"status":"error","code":"install_failed"}' ]] ||
  fail 'install failure was not stable'
[[ ! -e "$target" ]] || fail 'install failure left a target'

# 目标在最终发布瞬间出现时，硬链接必须原子失败且保留竞争方内容。
reset_remote_target
printf '#!/bin/bash\nprintf race > "$3"\nexit 1\n' > \
  "$SB_LANDING_SINGBOX_PREP_TEST_TOOL_DIR/ln"
chmod 700 "$SB_LANDING_SINGBOX_PREP_TEST_TOOL_DIR/ln"
run_package "$package"
[[ "$PACKAGE_RC" == 22 && "$PACKAGE_OUTPUT" == '{"status":"error","code":"existing_conflict"}' ]] ||
  fail 'last-moment target race was not rejected'
[[ "$(<"$target")" == race ]] || fail 'last-moment target was overwritten'
write_tool_wrapper ln "$host_ln"
reset_remote_target

export SB_LANDING_SINGBOX_PREP_TEST_FAILURE=postcheck
postcheck_failure_package="$work/postcheck-failure-package.sh"
controller_landing_build_singbox_runtime_package "$version" "$local_binary" \
  "$postcheck_failure_package" || fail 'postcheck failure package build failed'
unset SB_LANDING_SINGBOX_PREP_TEST_FAILURE
run_package "$postcheck_failure_package"
[[ "$PACKAGE_RC" == 33 && "$PACKAGE_OUTPUT" == '{"status":"error","code":"postcheck_failed"}' ]] ||
  fail 'postcheck failure was not stable'
[[ ! -e "$target" ]] || fail 'postcheck failure did not remove its exact target'

# 响应必须是单一严格 JSON，并与 SSH 退出码绑定。
response="$work/response.json"
printf '%s\n' '{"status":"installed"}' > "$response"
chmod 600 "$response"
controller_landing_singbox_response_is_valid "$response" 0 || fail 'installed response rejected'
if controller_landing_singbox_response_is_valid "$response" 22; then
  fail 'success response accepted a failure exit code'
fi
printf '%s\n' '{"status":"error","code":"existing_conflict"}' > "$response"
controller_landing_singbox_response_is_valid "$response" 22 || fail 'conflict response rejected'
printf '%s\n' '{"status":"ready","extra":true}' > "$response"
if controller_landing_singbox_response_is_valid "$response" 0; then
  fail 'response accepted an extra field'
fi
head -c 513 /dev/zero | tr '\0' x > "$response"
if controller_landing_singbox_response_is_valid "$response" 0; then
  fail 'oversized response was accepted'
fi

# 顶层顺序固定为发现 -> 人工确认 -> 本地准备/二次指纹/远端动作。
fixture_fingerprint="SHA256:$(printf 'A%.0s' {1..43})"
(
  actions="$work/actions-success"
  : > "$actions"
  orchestration_work="$SB_CONTROLLER_LANDING_WORK_ROOT/orchestration"
  controller_landing_transport_runtime_is_safe() { return 0; }
  validate_controller_state_file() { return 0; }
  controller_landing_discover_fingerprint() { printf '%s\n' "$fixture_fingerprint"; }
  controller_confirm_landing_fingerprint() { printf 'confirmed\n' >> "$actions"; }
  controller_landing_create_work_directory() {
    mkdir -m 700 "$orchestration_work"; printf '%s\n' "$orchestration_work"
  }
  register_temp_path() { return 0; }
  controller_landing_prepare_singbox_runtime_in_work() {
    [[ "$(tail -n 1 "$actions")" == confirmed ]] || return 1
    printf 'remote\n' >> "$actions"
    controller_landing_singbox_set_result installed
  }
  controller_landing_remove_work_directory() { rmdir "$1"; }
  controller_prepare_landing_singbox_runtime 1.1.1.1 22 landing-a ||
    fail 'successful orchestration failed'
  [[ "$(tr '\n' ' ' < "$actions")" == 'confirmed remote ' ]] ||
    fail 'orchestration order drifted'
  [[ "$CONTROLLER_LANDING_SINGBOX_LAST_STATUS" == installed &&
     "$CONTROLLER_LANDING_SINGBOX_LAST_FINGERPRINT" == "$fixture_fingerprint" ]] ||
    fail 'successful orchestration result drifted'
)
(
  controller_landing_transport_runtime_is_safe() { return 0; }
  validate_controller_state_file() { return 0; }
  controller_landing_discover_fingerprint() { printf '%s\n' "$fixture_fingerprint"; }
  controller_confirm_landing_fingerprint() { return 2; }
  controller_landing_create_work_directory() { fail 'rejected fingerprint reached runtime setup'; }
  if controller_prepare_landing_singbox_runtime 1.1.1.1 22 landing-a; then
    fail 'rejected fingerprint was accepted'
  fi
  [[ "$CONTROLLER_LANDING_SINGBOX_LAST_STATUS" == fingerprint_rejected ]] ||
    fail 'rejected fingerprint result drifted'
)
(
  recheck_work="$SB_CONTROLLER_LANDING_WORK_ROOT/recheck"
  mkdir -m 700 "$recheck_work"
  controller_landing_prepare_verified_singbox_binary() {
    CONTROLLER_LANDING_SINGBOX_LAST_VERSION="$version"
    CONTROLLER_LANDING_SINGBOX_PREPARED_BINARY="$local_binary"
  }
  controller_landing_prepare_known_hosts() { return 1; }
  if controller_landing_prepare_singbox_runtime_in_work 1.1.1.1 22 landing-a \
      "$fixture_fingerprint" "$recheck_work"; then
    fail 'fingerprint recheck failure was accepted'
  fi
  [[ "$CONTROLLER_LANDING_SINGBOX_LAST_STATUS" == fingerprint_recheck_failed ]] ||
    fail 'fingerprint recheck result drifted'
)

printf 'landing sing-box runtime preparation tests passed\n'
