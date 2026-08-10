# ============================================================
# v5 入口发起的落地 sing-box 运行时准备（尚未接入菜单或角色安装）
# ============================================================
# 只安装入口已核对的官方稳定版二进制；不覆盖任何未知现有目标。
# shellcheck disable=SC2034

CONTROLLER_LANDING_SINGBOX_SESSION_TIMEOUT=900
CONTROLLER_LANDING_SINGBOX_RESPONSE_MAX_BYTES=512
CONTROLLER_LANDING_SINGBOX_BINARY_MAX_BYTES=67108864
CONTROLLER_LANDING_SINGBOX_PACKAGE_MAX_BYTES=134217728
CONTROLLER_LANDING_SINGBOX_LAST_STATUS=not_checked
CONTROLLER_LANDING_SINGBOX_LAST_DETAIL=""
CONTROLLER_LANDING_SINGBOX_LAST_FINGERPRINT=""
CONTROLLER_LANDING_SINGBOX_LAST_VERSION=""
CONTROLLER_LANDING_SINGBOX_LAST_SHA256=""
CONTROLLER_LANDING_SINGBOX_PREPARED_BINARY=""
CONTROLLER_LANDING_SINGBOX_RELEASE_VERSION=""
CONTROLLER_LANDING_SINGBOX_RELEASE_ASSET=""
CONTROLLER_LANDING_SINGBOX_RELEASE_URL=""
CONTROLLER_LANDING_SINGBOX_RELEASE_SHA256=""

controller_landing_singbox_reset_result() {
  CONTROLLER_LANDING_SINGBOX_LAST_STATUS=not_checked
  CONTROLLER_LANDING_SINGBOX_LAST_DETAIL=""
  CONTROLLER_LANDING_SINGBOX_LAST_FINGERPRINT=""
  CONTROLLER_LANDING_SINGBOX_LAST_VERSION=""
  CONTROLLER_LANDING_SINGBOX_LAST_SHA256=""
  CONTROLLER_LANDING_SINGBOX_PREPARED_BINARY=""
  CONTROLLER_LANDING_SINGBOX_RELEASE_VERSION=""
  CONTROLLER_LANDING_SINGBOX_RELEASE_ASSET=""
  CONTROLLER_LANDING_SINGBOX_RELEASE_URL=""
  CONTROLLER_LANDING_SINGBOX_RELEASE_SHA256=""
}

controller_landing_singbox_set_result() {
  # 结果由后续交互层与定向测试在函数返回后读取。
  # shellcheck disable=SC2034
  CONTROLLER_LANDING_SINGBOX_LAST_STATUS="$1"
  # shellcheck disable=SC2034
  CONTROLLER_LANDING_SINGBOX_LAST_DETAIL="${2:-}"
}

controller_landing_singbox_settings_are_safe() {
  [[ "$CONTROLLER_LANDING_SINGBOX_SESSION_TIMEOUT" == 900 &&
     "$CONTROLLER_LANDING_SINGBOX_RESPONSE_MAX_BYTES" == 512 &&
     "$CONTROLLER_LANDING_SINGBOX_BINARY_MAX_BYTES" == 67108864 &&
     "$CONTROLLER_LANDING_SINGBOX_PACKAGE_MAX_BYTES" == 134217728 ]]
}

controller_landing_singbox_release_is_valid() {
  [[ $# -eq 4 ]] || return 64
  local version="$1" asset="$2" url="$3" sha256
  sha256="$(printf '%s' "$4" | tr 'A-F' 'a-f')" || return 1
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  [[ "$asset" == "sing-box-${version}-${SINGBOX_ARCH}.tar.gz" ]] || return 1
  [[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$url" != *$'\n'* && "$url" != *$'\r'* && "$url" != *'?'* && "$url" != *'#'* ]] ||
    return 1
  [[ "$url" == "https://github.com/${SINGBOX_REPOSITORY}/releases/download/v${version}/${asset}" ||
     "$url" == "https://github.com/${SINGBOX_REPOSITORY}/releases/download/${version}/${asset}" ]]
}

controller_landing_fetch_stable_singbox_release() {
  local release_json metadata
  release_json="$(github_api_get \
    "https://api.github.com/repos/${SINGBOX_REPOSITORY}/releases/latest")" || return 1
  metadata="$(singbox_release_metadata "$release_json")" || return 1
  CONTROLLER_LANDING_SINGBOX_RELEASE_VERSION="$(jq -r '.version' <<<"$metadata")" || return 1
  CONTROLLER_LANDING_SINGBOX_RELEASE_ASSET="$(jq -r '.asset' <<<"$metadata")" || return 1
  CONTROLLER_LANDING_SINGBOX_RELEASE_URL="$(jq -r '.url' <<<"$metadata")" || return 1
  CONTROLLER_LANDING_SINGBOX_RELEASE_SHA256="$(jq -r '.sha256 | ascii_downcase' \
    <<<"$metadata")" || return 1
  controller_landing_singbox_release_is_valid \
    "$CONTROLLER_LANDING_SINGBOX_RELEASE_VERSION" \
    "$CONTROLLER_LANDING_SINGBOX_RELEASE_ASSET" \
    "$CONTROLLER_LANDING_SINGBOX_RELEASE_URL" \
    "$CONTROLLER_LANDING_SINGBOX_RELEASE_SHA256"
}

controller_landing_local_singbox_binary_is_valid() {
  [[ $# -eq 3 ]] || return 64
  local binary="$1" version="$2" expected_sha
  local owner mode size actual_sha detected expected_owner
  expected_sha="$(printf '%s' "$3" | tr 'A-F' 'a-f')" || return 1
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$expected_sha" =~ ^[0-9a-f]{64}$ ]] ||
    return 1
  [[ -f "$binary" && ! -L "$binary" && -x "$binary" ]] || return 1
  owner="$(manager_file_uid "$binary")" || return 1
  expected_owner="$(controller_state_expected_uid)" || return 1
  [[ "$owner" == "$expected_owner" ]] || return 1
  mode="$(manager_file_mode "$binary")" || return 1
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0022) == 0 )) || return 1
  size="$(controller_landing_file_size "$binary")" || return 1
  ((size >= 1 && size <= CONTROLLER_LANDING_SINGBOX_BINARY_MAX_BYTES)) || return 1
  actual_sha="$(sha256sum "$binary" | awk '{print $1}')" || return 1
  [[ "$actual_sha" == "$expected_sha" ]] || return 1
  detected="$("$binary" version 2>/dev/null | awk 'NR == 1 { print $3 }')" || return 1
  [[ "$detected" == "$version" ]]
}

controller_landing_prepare_verified_singbox_binary() {
  [[ $# -eq 1 ]] || return 64
  local work="$1" binary actual_sha
  controller_landing_singbox_settings_are_safe || return 1
  controller_private_directory_is_trusted "$work" || return 1
  controller_landing_fetch_stable_singbox_release || return 1
  prepare_singbox_release_binary \
    "$CONTROLLER_LANDING_SINGBOX_RELEASE_VERSION" \
    "$CONTROLLER_LANDING_SINGBOX_RELEASE_ASSET" \
    "$CONTROLLER_LANDING_SINGBOX_RELEASE_URL" \
    "$CONTROLLER_LANDING_SINGBOX_RELEASE_SHA256" "$work" landing-stable || return 1
  binary="$PREPARED_SINGBOX_BINARY"
  actual_sha="$(sha256sum "$binary" | awk '{print $1}')" || return 1
  [[ "$actual_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
  controller_landing_local_singbox_binary_is_valid "$binary" \
    "$CONTROLLER_LANDING_SINGBOX_RELEASE_VERSION" "$actual_sha" || return 1
  CONTROLLER_LANDING_SINGBOX_PREPARED_BINARY="$binary"
  CONTROLLER_LANDING_SINGBOX_LAST_VERSION="$CONTROLLER_LANDING_SINGBOX_RELEASE_VERSION"
  # shellcheck disable=SC2034
  CONTROLLER_LANDING_SINGBOX_LAST_SHA256="$actual_sha"
}

controller_landing_build_singbox_runtime_package() {
  [[ $# -eq 3 ]] || return 64
  local version="$1" binary="$2" output="$3" output_parent binary_sha size
  local test_root="" test_system="" test_machine="" test_tool_dir="" test_failure=""
  controller_landing_singbox_settings_are_safe || return 1
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  output_parent="$(dirname -- "$output")" || return 1
  controller_private_directory_is_trusted "$output_parent" || return 1
  [[ ! -e "$output" && ! -L "$output" ]] || return 1
  binary_sha="$(sha256sum "$binary" | awk '{print $1}')" || return 1
  controller_landing_local_singbox_binary_is_valid "$binary" "$version" "$binary_sha" ||
    return 1
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true &&
        -n "${SB_LANDING_SINGBOX_PREP_TEST_ROOT:-}" ]]; then
    test_root="$SB_LANDING_SINGBOX_PREP_TEST_ROOT"
    test_system="${SB_LANDING_SINGBOX_PREP_TEST_SYSTEM:-Linux}"
    test_machine="${SB_LANDING_SINGBOX_PREP_TEST_MACHINE:-x86_64}"
    test_tool_dir="${SB_LANDING_SINGBOX_PREP_TEST_TOOL_DIR:-}"
    test_failure="${SB_LANDING_SINGBOX_PREP_TEST_FAILURE:-}"
    [[ "$test_root" == /* && "$test_root" != / && "$test_root" != */ &&
       "$test_root" != *$'\n'* && "$test_tool_dir" == /* && "$test_tool_dir" != / &&
       "$test_tool_dir" != */ && "$test_tool_dir" != *$'\n'* &&
       "$test_system" =~ ^[A-Za-z0-9._-]+$ && "$test_machine" =~ ^[A-Za-z0-9._-]+$ &&
       "$test_failure" =~ ^(install|postcheck)?$ ]] || return 1
    controller_private_directory_is_trusted "$test_root" || return 1
    controller_private_directory_is_trusted "$test_tool_dir" || return 1
  fi

  if ! cat > "$output" <<EOF
#!/bin/bash
set -Eeuo pipefail
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
LC_ALL=C
export PATH LC_ALL
unset BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH OPENSSL_CONF
expected_version=$version
expected_sha256=$binary_sha
test_root=$(printf '%q' "$test_root")
test_system=$(printf '%q' "$test_system")
test_machine=$(printf '%q' "$test_machine")
test_tool_dir=$(printf '%q' "$test_tool_dir")
test_failure=$(printf '%q' "$test_failure")

tool_path() {
  local logical="\$1"
  if [[ -n "\$test_tool_dir" ]]; then
    printf '%s/%s\n' "\$test_tool_dir" "\${logical##*/}"
  else
    printf '%s\n' "\$logical"
  fi
}

target_path() {
  if [[ -n "\$test_root" ]]; then
    printf '%s/usr/local/bin/sing-box\n' "\$test_root"
  else
    printf '/usr/local/bin/sing-box\n'
  fi
}

target_parent() {
  if [[ -n "\$test_root" ]]; then
    printf '%s/usr/local/bin\n' "\$test_root"
  else
    printf '/usr/local/bin\n'
  fi
}

os_release_path() {
  if [[ -n "\$test_root" ]]; then
    printf '%s/os-release\n' "\$test_root"
  else
    printf '/usr/lib/os-release\n'
  fi
}

expected_uid() {
  if [[ -n "\$test_root" ]]; then printf '%s\n' "\$EUID"; else printf '0\n'; fi
}

path_metadata() {
  local stat_bin
  stat_bin="\$(tool_path /usr/bin/stat)" || return 1
  "\$stat_bin" -Lc '%u %a' -- "\$1" 2>/dev/null ||
    "\$stat_bin" -f '%u %Lp' "\$1" 2>/dev/null
}

trusted_executable() {
  local logical="\$1" path metadata uid mode
  path="\$(tool_path "\$logical")" || return 1
  [[ -f "\$path" && ! -L "\$path" && -x "\$path" ]] || return 1
  metadata="\$(path_metadata "\$path")" || return 1
  read -r uid mode <<< "\$metadata"
  [[ "\$uid" == "\$(expected_uid)" && "\$mode" =~ ^[0-7]{3,4}\$ ]] || return 1
  (( (8#\$mode & 0022) == 0 ))
}

runtime_tools_are_safe() {
  local logical
  for logical in /bin/bash /usr/bin/base64 /bin/chmod /usr/bin/mktemp \
    /usr/bin/ln /bin/rm /usr/bin/sha256sum /usr/bin/stat /bin/sync /usr/bin/uname; do
    trusted_executable "\$logical" || return 1
  done
}

trusted_directory() {
  local path="\$1" metadata uid mode
  [[ -d "\$path" && ! -L "\$path" ]] || return 1
  metadata="\$(path_metadata "\$path")" || return 1
  read -r uid mode <<< "\$metadata"
  [[ "\$uid" == "\$(expected_uid)" && "\$mode" =~ ^[0-7]{3,4}\$ ]] || return 1
  (( (8#\$mode & 0022) == 0 ))
}

target_directory_chain_is_safe() {
  local path
  if [[ -n "\$test_root" ]]; then
    trusted_directory "\$(target_parent)"
    return
  fi
  for path in /usr /usr/local /usr/local/bin; do
    trusted_directory "\$path" || return 1
  done
}

platform_is_supported() {
  local os_release system machine metadata uid mode key value os_id="" version_id=""
  if [[ -n "\$test_root" ]]; then
    system="\$test_system"; machine="\$test_machine"
  else
    [[ "\$EUID" -eq 0 ]] || return 1
    system="\$("\$(tool_path /usr/bin/uname)" -s)" || return 1
    machine="\$("\$(tool_path /usr/bin/uname)" -m)" || return 1
  fi
  [[ "\$system" == Linux && "\$machine" == x86_64 ]] || return 1
  os_release="\$(os_release_path)" || return 1
  [[ -f "\$os_release" && ! -L "\$os_release" && -r "\$os_release" ]] || return 1
  metadata="\$(path_metadata "\$os_release")" || return 1
  read -r uid mode <<< "\$metadata"
  [[ "\$uid" == "\$(expected_uid)" && "\$mode" =~ ^[0-7]{3,4}\$ ]] || return 1
  (( (8#\$mode & 0022) == 0 )) || return 1
  while IFS='=' read -r key value; do
    case "\$key" in
      ID) [[ -z "\$os_id" ]] || return 1; os_id="\$value" ;;
      VERSION_ID) [[ -z "\$version_id" ]] || return 1; version_id="\$value" ;;
    esac
  done < "\$os_release"
  [[ "\$os_id" == debian && "\$version_id" == '"12"' ]]
}

binary_sha256() {
  local sha_bin output
  sha_bin="\$(tool_path /usr/bin/sha256sum)" || return 1
  output="\$("\$sha_bin" "\$1")" || return 1
  printf '%s\n' "\${output%% *}"
}

binary_version() {
  local line first second version remainder
  line="\$("\$1" version 2>/dev/null)" || return 1
  line="\${line%%\$'\n'*}"
  read -r first second version remainder <<< "\$line"
  [[ "\$first" == sing-box && "\$second" == version && -z "\$remainder" ]] || return 1
  printf '%s\n' "\$version"
}

existing_target_is_safe() {
  local target="\$1" metadata uid mode
  [[ -f "\$target" && ! -L "\$target" && -x "\$target" ]] || return 1
  metadata="\$(path_metadata "\$target")" || return 1
  read -r uid mode <<< "\$metadata"
  [[ "\$uid" == "\$(expected_uid)" && "\$mode" =~ ^[0-7]{3,4}\$ ]] || return 1
  (( (8#\$mode & 0022) == 0 ))
}

existing_target_matches() {
  existing_target_is_safe "\$1" || return 1
  [[ "\$(binary_sha256 "\$1")" == "\$expected_sha256" ]] || return 1
  [[ "\$(binary_version "\$1")" == "\$expected_version" ]]
}

emit_error() {
  printf '{"status":"error","code":"%s"}\n' "\$1"
  exit "\$2"
}

payload_to() {
  "\$(tool_path /usr/bin/base64)" -d > "\$1" 2>/dev/null <<'__SB_LANDING_SINGBOX_BINARY__'
EOF
  then
    return 1
  fi
  if ! base64 < "$binary" >> "$output"; then
    rm -f -- "$output" || true
    return 1
  fi
  if ! cat >> "$output" <<'EOF'
__SB_LANDING_SINGBOX_BINARY__
}

main() {
  local target parent temp="" chmod_bin ln_bin mktemp_bin rm_bin sync_bin
  runtime_tools_are_safe || emit_error unsafe_runtime 23
  platform_is_supported || emit_error unsupported_platform 20
  target="$(target_path)" || emit_error unsafe_runtime 23
  parent="$(target_parent)" || emit_error unsafe_runtime 23
  target_directory_chain_is_safe || emit_error unsafe_runtime 23
  if [[ -e "$target" || -L "$target" ]]; then
    existing_target_is_safe "$target" || emit_error unsafe_existing 21
    existing_target_matches "$target" || emit_error existing_conflict 22
    printf '%s\n' '{"status":"ready"}'
    return 0
  fi
  chmod_bin="$(tool_path /bin/chmod)" || emit_error unsafe_runtime 23
  mktemp_bin="$(tool_path /usr/bin/mktemp)" || emit_error unsafe_runtime 23
  ln_bin="$(tool_path /usr/bin/ln)" || emit_error unsafe_runtime 23
  rm_bin="$(tool_path /bin/rm)" || emit_error unsafe_runtime 23
  sync_bin="$(tool_path /bin/sync)" || emit_error unsafe_runtime 23
  temp="$($mktemp_bin "$parent/.sb-sing-box.XXXXXXXXXX")" || emit_error install_failed 32
  [[ "$temp" == "$parent"/.sb-sing-box.[A-Za-z0-9]* && -f "$temp" && ! -L "$temp" ]] ||
    emit_error install_failed 32
  cleanup_temp() {
    [[ -z "${temp:-}" ]] || "$rm_bin" -f -- "$temp" || true
  }
  trap cleanup_temp EXIT HUP INT QUIT TERM
  payload_to "$temp" || emit_error payload_invalid 30
  "$chmod_bin" 755 "$temp" || emit_error install_failed 32
  [[ "$(binary_sha256 "$temp")" == "$expected_sha256" ]] || emit_error payload_invalid 30
  [[ "$(binary_version "$temp")" == "$expected_version" ]] || emit_error payload_invalid 30
  [[ "$test_failure" != install ]] || emit_error install_failed 32
  "$sync_bin" "$temp" >/dev/null 2>&1 || emit_error install_failed 32
  [[ ! -e "$target" && ! -L "$target" ]] || emit_error existing_conflict 22
  if ! "$ln_bin" -- "$temp" "$target"; then
    if [[ -e "$target" || -L "$target" ]]; then
      emit_error existing_conflict 22
    fi
    emit_error install_failed 32
  fi
  "$rm_bin" -f -- "$temp" || emit_error install_failed 32
  temp=""
  "$sync_bin" "$parent" >/dev/null 2>&1 || emit_error postcheck_failed 33
  if [[ "$test_failure" == postcheck ]] || ! existing_target_matches "$target"; then
    if existing_target_is_safe "$target" &&
       [[ "$(binary_sha256 "$target")" == "$expected_sha256" ]]; then
      "$rm_bin" -f -- "$target" || true
      "$sync_bin" "$parent" >/dev/null 2>&1 || true
    fi
    emit_error postcheck_failed 33
  fi
  printf '%s\n' '{"status":"installed"}'
}

main "$@"
EOF
  then
    rm -f -- "$output" || true
    return 1
  fi
  chmod 600 "$output" || { rm -f -- "$output"; return 1; }
  controller_landing_private_file_is_trusted "$output" || {
    rm -f -- "$output"
    return 1
  }
  bash -n "$output" >/dev/null 2>&1 || { rm -f -- "$output"; return 1; }
  size="$(controller_landing_file_size "$output")" || { rm -f -- "$output"; return 1; }
  ((size >= 1 && size <= CONTROLLER_LANDING_SINGBOX_PACKAGE_MAX_BYTES)) || {
    rm -f -- "$output"
    return 1
  }
}

controller_landing_singbox_response_is_valid() {
  [[ $# -eq 2 ]] || return 64
  local response="$1" ssh_status="$2" size
  [[ "$ssh_status" =~ ^[0-9]+$ ]] || return 1
  controller_landing_private_file_is_trusted "$response" || return 1
  size="$(controller_landing_file_size "$response")" || return 1
  ((size >= 1 && size <= CONTROLLER_LANDING_SINGBOX_RESPONSE_MAX_BYTES)) || return 1
  jq -e -s --argjson ssh_status "$ssh_status" '
    length == 1 and
    if .[0] == {status:"ready"} or .[0] == {status:"installed"} then
      $ssh_status == 0
    elif .[0] == {status:"error", code:"unsupported_platform"} then
      $ssh_status == 20
    elif .[0] == {status:"error", code:"unsafe_existing"} then
      $ssh_status == 21
    elif .[0] == {status:"error", code:"existing_conflict"} then
      $ssh_status == 22
    elif .[0] == {status:"error", code:"unsafe_runtime"} then
      $ssh_status == 23
    elif .[0] == {status:"error", code:"payload_invalid"} then
      $ssh_status == 30
    elif .[0] == {status:"error", code:"install_failed"} then
      $ssh_status == 32
    elif .[0] == {status:"error", code:"postcheck_failed"} then
      $ssh_status == 33
    else false
    end
  ' "$response" >/dev/null 2>&1
}

controller_landing_prepare_singbox_runtime_in_work() {
  [[ $# -eq 5 ]] || return 64
  local address="$1" ssh_port="$2" landing_id="$3" expected_fingerprint="$4" work="$5"
  local package="$work/singbox-runtime-package.sh" response="$work/singbox-runtime-response.json"
  local known_hosts ssh_status result
  controller_landing_singbox_settings_are_safe || return 1
  controller_landing_address_is_valid "$address" || return 1
  landing_port_is_valid "$ssh_port" || return 1
  landing_id_is_valid "$landing_id" || return 1
  [[ "$expected_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || return 1
  controller_private_directory_is_trusted "$work" || return 1
  controller_landing_prepare_verified_singbox_binary "$work" || {
    controller_landing_singbox_set_result release_prepare_failed
    return 1
  }
  known_hosts="$(controller_landing_prepare_known_hosts "$address" "$ssh_port" \
    "$expected_fingerprint" "sb-landing-$landing_id" "$work")" || {
      controller_landing_singbox_set_result fingerprint_recheck_failed
      return 1
    }
  controller_landing_build_singbox_runtime_package \
    "$CONTROLLER_LANDING_SINGBOX_LAST_VERSION" \
    "$CONTROLLER_LANDING_SINGBOX_PREPARED_BINARY" "$package" || {
      controller_landing_singbox_set_result package_build_failed
      return 1
    }
  if controller_landing_root_package_exchange "$address" "$ssh_port" "$landing_id" \
      "$known_hosts" "$expected_fingerprint" "$package" "$response" \
      "$CONTROLLER_LANDING_SINGBOX_SESSION_TIMEOUT"; then
    ssh_status=0
  else
    ssh_status="$CONTROLLER_LANDING_ROOT_PACKAGE_LAST_SSH_STATUS"
  fi
  if ! controller_landing_singbox_response_is_valid "$response" "$ssh_status"; then
    controller_landing_singbox_set_result ssh_uncertain
    return 1
  fi
  result="$(jq -r 'if .status == "error" then .code else .status end' "$response")" || {
    controller_landing_singbox_set_result ssh_uncertain
    return 1
  }
  case "$result" in
    ready|installed)
      controller_landing_singbox_set_result "$result"
      return 0
      ;;
    unsupported_platform|unsafe_existing|existing_conflict|unsafe_runtime|payload_invalid|install_failed|postcheck_failed)
      controller_landing_singbox_set_result "$result"
      return 1
      ;;
    *)
      controller_landing_singbox_set_result ssh_uncertain
      return 1
      ;;
  esac
}

controller_prepare_landing_singbox_runtime() {
  [[ $# -eq 3 ]] || return 64
  local address="$1" ssh_port="$2" landing_id="$3" fingerprint work rc=1 confirm_rc=0
  controller_landing_singbox_reset_result
  controller_landing_singbox_settings_are_safe || {
    controller_landing_singbox_set_result unsafe_local_runtime
    return 1
  }
  controller_landing_transport_runtime_is_safe || {
    controller_landing_singbox_set_result unsafe_local_runtime
    return 1
  }
  controller_landing_address_is_valid "$address" || {
    controller_landing_singbox_set_result invalid_input
    return 1
  }
  landing_port_is_valid "$ssh_port" || {
    controller_landing_singbox_set_result invalid_input
    return 1
  }
  landing_id_is_valid "$landing_id" || {
    controller_landing_singbox_set_result invalid_input
    return 1
  }
  validate_controller_state_file "$CONTROLLER_STATE_FILE" || {
    controller_landing_singbox_set_result invalid_controller_state
    return 1
  }
  fingerprint="$(controller_landing_discover_fingerprint "$address" "$ssh_port")" || {
    controller_landing_singbox_set_result fingerprint_discovery_failed
    return 1
  }
  # 结果由后续交互层与定向测试在函数返回后读取。
  # shellcheck disable=SC2034
  CONTROLLER_LANDING_SINGBOX_LAST_FINGERPRINT="$fingerprint"
  controller_confirm_landing_fingerprint "$address" "$ssh_port" "$fingerprint" || confirm_rc=$?
  if ((confirm_rc != 0)); then
    if ((confirm_rc == 2)); then
      controller_landing_singbox_set_result fingerprint_rejected
    else
      controller_landing_singbox_set_result fingerprint_confirmation_failed
    fi
    return 1
  fi
  work="$(controller_landing_create_work_directory)" || {
    controller_landing_singbox_set_result unsafe_local_runtime
    return 1
  }
  register_temp_path "$work" || {
    controller_landing_remove_work_directory "$work" || true
    controller_landing_singbox_set_result unsafe_local_runtime
    return 1
  }
  if controller_landing_prepare_singbox_runtime_in_work "$address" "$ssh_port" "$landing_id" \
      "$fingerprint" "$work"; then
    rc=0
  fi
  controller_landing_remove_work_directory "$work" || {
    controller_landing_singbox_set_result local_cleanup_failed
    rc=1
  }
  return "$rc"
}
