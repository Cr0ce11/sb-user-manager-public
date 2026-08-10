# ============================================================
# v5 入口发起的一次性落地 root 初始化（尚未接入菜单或角色安装）
# ============================================================

LANDING_BOOTSTRAP_SCHEMA_VERSION=1
LANDING_BOOTSTRAP_RECEIPT_PATH=/var/lib/sb-user-manager/landing-bootstrap.json
LANDING_BOOTSTRAP_LOCK_PATH=/var/lib/sb-user-manager/landing-bootstrap.lock
LANDING_BOOTSTRAP_LOCK_TIMEOUT=30
LANDING_BOOTSTRAP_PACKAGE_MAX_BYTES=8388608

CONTROLLER_LANDING_BOOTSTRAP_ROOT_ACCOUNT=root
CONTROLLER_LANDING_BOOTSTRAP_SESSION_TIMEOUT=180
CONTROLLER_LANDING_BOOTSTRAP_SESSION_KILL_AFTER=5
CONTROLLER_LANDING_BOOTSTRAP_RESPONSE_MAX_BYTES=512
CONTROLLER_LANDING_BOOTSTRAP_LAST_ID=""
CONTROLLER_LANDING_BOOTSTRAP_LAST_ROLLBACK=""
CONTROLLER_LANDING_ROOT_PACKAGE_LAST_SSH_STATUS=""
if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]]; then
  CONTROLLER_LANDING_BOOTSTRAP_RUNTIME_SOURCE="${SB_CONTROLLER_LANDING_BOOTSTRAP_RUNTIME_SOURCE:-}"
  CONTROLLER_LANDING_BOOTSTRAP_ROOT_IDENTITY_FILE="${SB_CONTROLLER_LANDING_BOOTSTRAP_ROOT_IDENTITY_FILE:-}"
else
  CONTROLLER_LANDING_BOOTSTRAP_RUNTIME_SOURCE=/usr/local/sbin/sb-user-manager
  CONTROLLER_LANDING_BOOTSTRAP_ROOT_IDENTITY_FILE=""
fi

controller_landing_root_package_settings_are_safe() {
  [[ "$CONTROLLER_LANDING_BOOTSTRAP_ROOT_ACCOUNT" == root &&
     "$CONTROLLER_LANDING_BOOTSTRAP_SESSION_TIMEOUT" == 180 &&
     "$CONTROLLER_LANDING_BOOTSTRAP_SESSION_KILL_AFTER" == 5 &&
     "$CONTROLLER_LANDING_BOOTSTRAP_RESPONSE_MAX_BYTES" == 512 ]]
}

landing_bootstrap_paths_are_safe() {
  [[ "$LANDING_BOOTSTRAP_SCHEMA_VERSION" == 1 &&
     "$LANDING_BOOTSTRAP_RECEIPT_PATH" == /var/lib/sb-user-manager/landing-bootstrap.json &&
     "$LANDING_BOOTSTRAP_LOCK_PATH" == /var/lib/sb-user-manager/landing-bootstrap.lock &&
     "$LANDING_BOOTSTRAP_LOCK_TIMEOUT" == 30 &&
     "$LANDING_BOOTSTRAP_PACKAGE_MAX_BYTES" == 8388608 ]]
}

landing_bootstrap_platform_is_supported() {
  local os_release=/usr/lib/os-release uid mode key value
  local os_id="" version_id=""
  [[ "$EUID" -eq 0 && "${SB_USER_MANAGER_LIBRARY:-false}" != true ]] || return 1
  [[ "$(/usr/bin/uname -s)" == Linux && "$(/usr/bin/uname -m)" == x86_64 ]] || return 1
  [[ -f "$os_release" && ! -L "$os_release" && -r "$os_release" ]] || return 1
  uid="$(manager_file_uid "$os_release")" || return 1
  mode="$(manager_file_mode "$os_release")" || return 1
  [[ "$uid" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0022) == 0 )) || return 1
  while IFS='=' read -r key value; do
    case "$key" in
      ID)
        [[ -z "$os_id" ]] || return 1
        os_id="$value"
        ;;
      VERSION_ID)
        [[ -z "$version_id" ]] || return 1
        version_id="$value"
        ;;
    esac
  done < "$os_release"
  [[ "$os_id" == debian && "$version_id" == '"12"' ]]
}

landing_bootstrap_receipt_file() {
  landing_bootstrap_paths_are_safe || return 1
  landing_channel_path "$LANDING_BOOTSTRAP_RECEIPT_PATH"
}

landing_bootstrap_receipt_json_is_valid() {
  local path="$1"
  jq -e --argjson schema "$LANDING_BOOTSTRAP_SCHEMA_VERSION" '
    type == "object" and
    (keys | sort) == [
      "allowed_entry_ipv4", "bootstrap_id", "landing_id", "public_key_fingerprint",
      "runtime_sha256", "schema_version", "status"
    ] and
    .schema_version == $schema and
    (.bootstrap_id | type == "string" and test("^[0-9a-f]{64}$")) and
    (.landing_id | type == "string" and test("^[a-z][a-z0-9-]{0,31}$")) and
    (.allowed_entry_ipv4 | type == "string" and length >= 7 and length <= 15) and
    (.public_key_fingerprint | type == "string" and test("^SHA256:[A-Za-z0-9+/]{43}$")) and
    (.runtime_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.status == "installing" or .status == "installed")
  ' "$path" >/dev/null 2>&1 || return 1
  is_public_ipv4 "$(jq -r '.allowed_entry_ipv4' "$path")"
}

landing_bootstrap_receipt_is_trusted() {
  local path="${1:-}" root_uid root_gid
  [[ -n "$path" ]] || path="$(landing_bootstrap_receipt_file)" || return 1
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  landing_channel_file_matches "$path" 600 "$root_uid" "$root_gid" || return 1
  landing_bootstrap_receipt_json_is_valid "$path"
}

landing_bootstrap_receipt_matches() {
  local path="$1" bootstrap_id="$2" landing_id="$3" allowed_ipv4="$4"
  local public_key_fingerprint="$5"
  landing_bootstrap_receipt_is_trusted "$path" || return 1
  jq -e --arg bootstrap_id "$bootstrap_id" --arg landing_id "$landing_id" \
    --arg allowed_ipv4 "$allowed_ipv4" --arg fingerprint "$public_key_fingerprint" '
      .bootstrap_id == $bootstrap_id and .landing_id == $landing_id and
      .allowed_entry_ipv4 == $allowed_ipv4 and
      .public_key_fingerprint == $fingerprint
    ' "$path" >/dev/null 2>&1
}

landing_bootstrap_write_receipt() {
  local bootstrap_id="$1" landing_id="$2" allowed_ipv4="$3"
  local public_key_fingerprint="$4" runtime_sha256="$5" status="$6"
  local receipt parent tmp root_uid root_gid
  [[ "$bootstrap_id" =~ ^[0-9a-f]{64}$ &&
     "$runtime_sha256" =~ ^[0-9a-f]{64}$ &&
     "$public_key_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || return 1
  landing_id_is_valid "$landing_id" || return 1
  is_public_ipv4 "$allowed_ipv4" || return 1
  [[ "$status" == installing || "$status" == installed ]] || return 1
  receipt="$(landing_bootstrap_receipt_file)" || return 1
  parent="$(dirname -- "$receipt")" || return 1
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  landing_channel_directory_matches "$parent" 700 "$root_uid" "$root_gid" || return 1
  if [[ -e "$receipt" || -L "$receipt" ]]; then
    landing_bootstrap_receipt_is_trusted "$receipt" || return 1
  fi
  tmp="$(mktemp "$parent/.landing-bootstrap.XXXXXX")" || return 1
  register_temp_path "$tmp" || { rm -f -- "$tmp" || true; return 1; }
  if ! jq -n --argjson schema "$LANDING_BOOTSTRAP_SCHEMA_VERSION" \
      --arg bootstrap_id "$bootstrap_id" --arg landing_id "$landing_id" \
      --arg allowed_ipv4 "$allowed_ipv4" --arg fingerprint "$public_key_fingerprint" \
      --arg runtime_sha256 "$runtime_sha256" --arg status "$status" '
        {
          schema_version:$schema,
          bootstrap_id:$bootstrap_id,
          landing_id:$landing_id,
          allowed_entry_ipv4:$allowed_ipv4,
          public_key_fingerprint:$fingerprint,
          runtime_sha256:$runtime_sha256,
          status:$status
        }
      ' > "$tmp" ||
     ! chmod 600 "$tmp" ||
     ! landing_channel_apply_ownership "$tmp" "$root_uid" "$root_gid" ||
     ! landing_bootstrap_receipt_json_is_valid "$tmp" ||
     ! sync_transaction_path "$tmp" ||
     ! mv -- "$tmp" "$receipt" ||
     ! sync_transaction_path "$parent"; then
    rm -f -- "$tmp" || true
    return 1
  fi
  landing_bootstrap_receipt_is_trusted "$receipt"
}

landing_bootstrap_remove_receipt() {
  local bootstrap_id="$1" landing_id="$2" allowed_ipv4="$3"
  local public_key_fingerprint="$4" receipt parent
  receipt="$(landing_bootstrap_receipt_file)" || return 1
  [[ -e "$receipt" || -L "$receipt" ]] || return 0
  landing_bootstrap_receipt_matches "$receipt" "$bootstrap_id" "$landing_id" \
    "$allowed_ipv4" "$public_key_fingerprint" || return 1
  parent="$(dirname -- "$receipt")" || return 1
  rm -f -- "$receipt" || return 1
  sync_transaction_path "$parent" || return 1
  [[ ! -e "$receipt" && ! -L "$receipt" ]]
}

landing_bootstrap_with_lock() {
  local callback="$1" lock lock_parent root_uid root_gid rc
  shift
  landing_bootstrap_paths_are_safe || return 1
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  landing_channel_ensure_system_directory /var || return 1
  landing_channel_ensure_system_directory /var/lib || return 1
  landing_channel_ensure_owned_directory /var/lib/sb-user-manager 700 "$root_uid" "$root_gid" || return 1
  landing_channel_ensure_persistent_lock_file "$LANDING_BOOTSTRAP_LOCK_PATH" || return 1
  lock="$(landing_channel_path "$LANDING_BOOTSTRAP_LOCK_PATH")" || return 1
  lock_parent="$(dirname -- "$lock")" || return 1
  exec 3<>"$lock" || return 1
  flock -x -w "$LANDING_BOOTSTRAP_LOCK_TIMEOUT" 3 || { exec 3>&-; return 1; }
  "$callback" "$@" 3>&- && rc=0 || rc=$?
  flock -u 3 2>/dev/null || true
  exec 3>&-
  sync_transaction_path "$lock_parent" || rc=1
  return "$rc"
}

landing_bootstrap_emit_status() {
  local status="$1"
  [[ "$status" == installed || "$status" == rolled_back ||
     "$status" == already_rolled_back ]] || return 1
  jq -nc --arg status "$status" '{status:$status}'
}

landing_bootstrap_install_unlocked() {
  local bootstrap_id="$1" landing_id="$2" allowed_ipv4="$3" public_key_file="$4"
  local public_key_fingerprint="$5" runtime_sha256="$6" receipt identity status
  receipt="$(landing_bootstrap_receipt_file)" || return 1
  identity="$(landing_channel_path "$LANDING_CHANNEL_IDENTITY_PATH")" || return 1
  if [[ -e "$receipt" || -L "$receipt" ]]; then
    landing_bootstrap_receipt_matches "$receipt" "$bootstrap_id" "$landing_id" \
      "$allowed_ipv4" "$public_key_fingerprint" || return 1
    [[ "$(jq -r '.runtime_sha256' "$receipt")" == "$runtime_sha256" ]] || return 1
  else
    [[ ! -e "$identity" && ! -L "$identity" ]] || return 1
    landing_channel_fresh_preflight || return 1
    landing_bootstrap_write_receipt "$bootstrap_id" "$landing_id" "$allowed_ipv4" \
      "$public_key_fingerprint" "$runtime_sha256" installing || return 1
  fi

  if ! install_landing_restricted_channel "$landing_id" "$allowed_ipv4" "$public_key_file"; then
    if [[ ! -e "$identity" && ! -L "$identity" ]] && landing_channel_fresh_preflight; then
      landing_bootstrap_remove_receipt "$bootstrap_id" "$landing_id" "$allowed_ipv4" \
        "$public_key_fingerprint" || true
    fi
    return 1
  fi
  landing_restricted_channel_is_valid || return 1
  status="$(jq -r '.status' "$receipt")" || return 1
  if [[ "$status" != installed ]]; then
    landing_bootstrap_write_receipt "$bootstrap_id" "$landing_id" "$allowed_ipv4" \
      "$public_key_fingerprint" "$runtime_sha256" installed || return 1
  fi
  landing_bootstrap_emit_status installed
}

landing_bootstrap_rollback_unlocked() {
  local bootstrap_id="$1" landing_id="$2" allowed_ipv4="$3" public_key_fingerprint="$4"
  local receipt identity
  receipt="$(landing_bootstrap_receipt_file)" || return 1
  identity="$(landing_channel_path "$LANDING_CHANNEL_IDENTITY_PATH")" || return 1
  if [[ ! -e "$receipt" && ! -L "$receipt" ]]; then
    [[ ! -e "$identity" && ! -L "$identity" ]] || return 1
    landing_bootstrap_emit_status already_rolled_back
    return
  fi
  landing_bootstrap_receipt_matches "$receipt" "$bootstrap_id" "$landing_id" \
    "$allowed_ipv4" "$public_key_fingerprint" || return 1
  # 固定零参数受管卸载；不能把 bootstrap 包参数透传给 root 卸载层。
  # shellcheck disable=SC2119
  uninstall_landing_restricted_channel || return 1
  [[ ! -e "$identity" && ! -L "$identity" ]] || return 1
  landing_bootstrap_remove_receipt "$bootstrap_id" "$landing_id" "$allowed_ipv4" \
    "$public_key_fingerprint" || return 1
  landing_bootstrap_emit_status rolled_back
}

landing_bootstrap_execute() {
  [[ $# -eq 6 ]] || return 64
  local action="$1" bootstrap_id="$2" landing_id="$3" allowed_ipv4="$4"
  local public_key_file="$5" runtime_sha256="$6" public_key_fingerprint
  local runtime_source
  [[ "$action" == install || "$action" == rollback ]] || return 64
  [[ "$bootstrap_id" =~ ^[0-9a-f]{64}$ && "$runtime_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
  landing_id_is_valid "$landing_id" || return 1
  is_public_ipv4 "$allowed_ipv4" || return 1
  [[ "$EUID" -eq 0 && "${SB_USER_MANAGER_LIBRARY:-false}" != true ]] || return 77
  landing_channel_runtime_paths_are_safe || return 1
  landing_channel_dependencies_are_ready || return 1
  landing_bootstrap_platform_is_supported || return 1
  landing_channel_install_system_paths_are_safe || return 1
  LANDING_CHANNEL_BOOTSTRAP_RUNTIME_SHA256="$runtime_sha256"
  runtime_source="$(landing_channel_runtime_source)" || return 1
  [[ "$runtime_source" == "/proc/self/fd/$LANDING_CHANNEL_BOOTSTRAP_RUNTIME_FD" ]] || return 1
  landing_channel_normalize_public_key "$public_key_file" "${public_key_file}.normalized" || return 1
  public_key_fingerprint="$(landing_channel_public_key_fingerprint \
    "${public_key_file}.normalized")" || return 1
  rm -f -- "$public_key_file" || return 1
  mv -- "${public_key_file}.normalized" "$public_key_file" || return 1
  case "$action" in
    install)
      landing_bootstrap_with_lock landing_bootstrap_install_unlocked "$bootstrap_id" \
        "$landing_id" "$allowed_ipv4" "$public_key_file" "$public_key_fingerprint" \
        "$runtime_sha256"
      ;;
    rollback)
      landing_bootstrap_with_lock landing_bootstrap_rollback_unlocked "$bootstrap_id" \
        "$landing_id" "$allowed_ipv4" "$public_key_fingerprint"
      ;;
  esac
}

controller_landing_bootstrap_runtime_source_is_trusted() {
  local source="$1" expected_uid uid mode
  [[ "$source" == /* && -f "$source" && ! -L "$source" && -r "$source" ]] || return 1
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]]; then
    expected_uid="$(controller_state_expected_uid)"
  else
    [[ "$source" == /usr/local/sbin/sb-user-manager ]] || return 1
    expected_uid=0
  fi
  uid="$(manager_file_uid "$source")" || return 1
  [[ "$uid" == "$expected_uid" ]] || return 1
  mode="$(manager_file_mode "$source")" || return 1
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0077) == 0 )) || return 1
  bash -n "$source" >/dev/null 2>&1
}

controller_landing_build_bootstrap_package() {
  [[ $# -eq 6 ]] || return 64
  local action="$1" bootstrap_id="$2" landing_id="$3" allowed_ipv4="$4"
  local public_key_file="$5" output="$6" runtime runtime_sha public_key_b64 size
  local output_parent normalized
  [[ "$action" == install || "$action" == rollback ]] || return 1
  [[ "$bootstrap_id" =~ ^[0-9a-f]{64}$ ]] || return 1
  landing_id_is_valid "$landing_id" || return 1
  is_public_ipv4 "$allowed_ipv4" || return 1
  output_parent="$(dirname -- "$output")" || return 1
  controller_private_directory_is_trusted "$output_parent" || return 1
  [[ ! -e "$output" && ! -L "$output" ]] || return 1
  runtime="$CONTROLLER_LANDING_BOOTSTRAP_RUNTIME_SOURCE"
  controller_landing_bootstrap_runtime_source_is_trusted "$runtime" || return 1
  runtime_sha="$(sha256sum "$runtime" | awk '{print $1}')" || return 1
  [[ "$runtime_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
  normalized="$output_parent/.landing-bootstrap.public-key"
  [[ ! -e "$normalized" && ! -L "$normalized" ]] || return 1
  landing_channel_normalize_public_key "$public_key_file" "$normalized" || return 1
  public_key_b64="$(base64 < "$normalized" | tr -d '\n')" || { rm -f -- "$normalized"; return 1; }
  rm -f -- "$normalized" || return 1
  [[ "$public_key_b64" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || return 1

  if ! {
    cat <<EOF
#!/bin/bash
set -Eeuo pipefail
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
LC_ALL=C
export PATH LC_ALL
unset BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH OPENSSL_CONF
bootstrap_action=$action
bootstrap_id=$bootstrap_id
landing_id=$landing_id
allowed_entry_ipv4=$allowed_ipv4
runtime_sha256=$runtime_sha
public_key_base64=$public_key_b64
work="\$(/usr/bin/mktemp -d /tmp/sb-landing-bootstrap-runtime.XXXXXXXXXX)" || exit 70
[[ "\$work" =~ ^/tmp/sb-landing-bootstrap-runtime\.[A-Za-z0-9]{10}\$ &&
   -d "\$work" && ! -L "\$work" ]] || exit 70
cleanup_bootstrap_work() {
  [[ "\${work:-}" =~ ^/tmp/sb-landing-bootstrap-runtime\.[A-Za-z0-9]{10}\$ &&
     -d "\$work" && ! -L "\$work" ]] || return 1
  /bin/rm -rf -- "\$work"
}
trap 'cleanup_bootstrap_work || true' EXIT HUP INT QUIT TERM
runtime="\$work/runtime.sh"
public_key="\$work/public-key"
/usr/bin/awk 'found { print } \$0 == "__SB_USER_MANAGER_RUNTIME__" { found=1; next }' "\$0" |
  /usr/bin/base64 -d > "\$runtime" || exit 70
printf '%s' "\$public_key_base64" | /usr/bin/base64 -d > "\$public_key" || exit 70
/bin/chmod 600 "\$runtime" "\$public_key" || exit 70
actual_sha="\$(/usr/bin/sha256sum "\$runtime" | /usr/bin/awk '{print \$1}')" || exit 70
[[ "\$actual_sha" == "\$runtime_sha256" ]] || exit 70
/bin/bash -n "\$runtime" >/dev/null 2>&1 || exit 70
exec 8< "\$runtime" || exit 70
exec 9< "\$runtime" || exit 70
runtime_fd8="\$(/usr/bin/stat -Lc '%d:%i' /proc/self/fd/8)" || exit 70
runtime_fd9="\$(/usr/bin/stat -Lc '%d:%i' /proc/self/fd/9)" || exit 70
[[ "\$runtime_fd8" == "\$runtime_fd9" ]] || exit 70
SB_USER_MANAGER_LIBRARY=true
. /proc/self/fd/9 || exit 70
SB_USER_MANAGER_LIBRARY=false
export SB_USER_MANAGER_LIBRARY
/bin/rm -f -- "\$runtime" || exit 70
LANDING_CHANNEL_BOOTSTRAP_RUNTIME_FD=8
LANDING_CHANNEL_BOOTSTRAP_RUNTIME_SHA256="\$runtime_sha256"
register_temp_path "\$work"
install_landing_apply_runtime_traps
landing_bootstrap_execute "\$bootstrap_action" "\$bootstrap_id" "\$landing_id" \
  "\$allowed_entry_ipv4" "\$public_key" "\$runtime_sha256"
exit \$?
__SB_USER_MANAGER_RUNTIME__
EOF
    base64 < "$runtime"
  } > "$output"; then
    rm -f -- "$output"
    return 1
  fi
  chmod 600 "$output" || { rm -f -- "$output"; return 1; }
  controller_landing_private_file_is_trusted "$output" || { rm -f -- "$output"; return 1; }
  size="$(controller_landing_file_size "$output")" || { rm -f -- "$output"; return 1; }
  ((size >= 1 && size <= LANDING_BOOTSTRAP_PACKAGE_MAX_BYTES)) || {
    rm -f -- "$output"
    return 1
  }
}

controller_landing_bootstrap_response_is_valid() {
  local response="$1" size
  controller_landing_private_file_is_trusted "$response" || return 1
  size="$(controller_landing_file_size "$response")" || return 1
  ((size >= 1 && size <= CONTROLLER_LANDING_BOOTSTRAP_RESPONSE_MAX_BYTES)) || return 1
  jq -e -s '
    length == 1 and .[0] == {status:.[0].status} and
    (.[0].status == "installed" or .[0].status == "rolled_back" or
     .[0].status == "already_rolled_back")
  ' "$response" >/dev/null 2>&1
}

controller_landing_root_package_remote_command() {
  local expected_sha="$1"
  [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
  cat <<EOF
expected=$expected_sha; umask 077; work=\$(/usr/bin/mktemp -d /tmp/sb-landing-root.XXXXXXXXXX) || exit 70; case \$work in /tmp/sb-landing-root.[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]) ;; *) exit 70 ;; esac; trap '/bin/rm -rf -- "\$work"' EXIT HUP INT QUIT TERM; /bin/cat > "\$work/package" || exit 70; /bin/chmod 600 "\$work/package" || exit 70; actual=\$(/usr/bin/sha256sum "\$work/package") || exit 70; actual=\${actual%% *}; [ "\$actual" = "\$expected" ] || exit 70; /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C /bin/bash --noprofile --norc "\$work/package"
EOF
}

controller_landing_bootstrap_remote_command() {
  controller_landing_root_package_remote_command "$@"
}

controller_landing_root_package_exchange() {
  [[ $# -eq 8 ]] || return 64
  local address="$1" ssh_port="$2" landing_id="$3" known_hosts="$4"
  local expected_fingerprint="$5" package="$6" response="$7"
  local session_timeout="$8"
  local host_alias package_sha remote_command ssh_status=0 identity_args=()
  CONTROLLER_LANDING_ROOT_PACKAGE_LAST_SSH_STATUS=""
  controller_landing_root_package_settings_are_safe || return 1
  controller_landing_transport_runtime_is_safe || return 1
  controller_landing_address_is_valid "$address" || return 1
  landing_port_is_valid "$ssh_port" || return 1
  landing_id_is_valid "$landing_id" || return 1
  [[ "$session_timeout" =~ ^[0-9]+$ ]] || return 1
  ((10#$session_timeout >= 30 && 10#$session_timeout <= 900)) || return 1
  host_alias="sb-landing-$landing_id"
  controller_landing_known_hosts_is_valid "$known_hosts" "$host_alias" \
    "$expected_fingerprint" || return 1
  controller_landing_private_file_is_trusted "$package" || return 1
  [[ ! -e "$response" && ! -L "$response" ]] || return 1
  package_sha="$(sha256sum "$package" | awk '{print $1}')" || return 1
  [[ "$package_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
  remote_command="$(controller_landing_root_package_remote_command "$package_sha")" || return 1
  [[ -n "$remote_command" && "$remote_command" != *$'\n'* ]] || return 1
  if [[ -n "$CONTROLLER_LANDING_BOOTSTRAP_ROOT_IDENTITY_FILE" ]]; then
    [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]] || return 1
    controller_landing_ssh_private_key_is_valid \
      "$CONTROLLER_LANDING_BOOTSTRAP_ROOT_IDENTITY_FILE" || return 1
    identity_args=(-i "$CONTROLLER_LANDING_BOOTSTRAP_ROOT_IDENTITY_FILE")
  fi
  if (
    umask 077
    ulimit -f 4 || exit 70
    exec "$CONTROLLER_LANDING_TIMEOUT_BIN" -k "$CONTROLLER_LANDING_BOOTSTRAP_SESSION_KILL_AFTER" \
      "$session_timeout" \
      "$CONTROLLER_LANDING_SSH_BIN" -F /dev/null -T -p "$ssh_port" \
      "${identity_args[@]}" \
      -o BatchMode=no \
      -o CanonicalizeHostname=no \
      -o CheckHostIP=no \
      -o ClearAllForwardings=yes \
      -o ConnectionAttempts=1 \
      -o "ConnectTimeout=$CONTROLLER_LANDING_CONNECT_TIMEOUT" \
      -o ControlMaster=no \
      -o ExitOnForwardFailure=yes \
      -o EscapeChar=none \
      -o ForwardAgent=no \
      -o ForwardX11=no \
      -o GlobalKnownHostsFile=/dev/null \
      -o "HostKeyAlias=$host_alias" \
      -o HostKeyAlgorithms=ssh-ed25519 \
      -o IdentitiesOnly=yes \
      -o KbdInteractiveAuthentication=yes \
      -o LogLevel=ERROR \
      -o NumberOfPasswordPrompts=3 \
      -o PasswordAuthentication=yes \
      -o PermitLocalCommand=no \
      -o PreferredAuthentications=publickey,keyboard-interactive,password \
      -o ProxyCommand=none \
      -o ProxyJump=none \
      -o PubkeyAcceptedAlgorithms=ssh-ed25519 \
      -o RequestTTY=no \
      -o StrictHostKeyChecking=yes \
      -o Tunnel=no \
      -o UpdateHostKeys=no \
      -o "UserKnownHostsFile=$known_hosts" \
      -o "User=$CONTROLLER_LANDING_BOOTSTRAP_ROOT_ACCOUNT" \
      -o VerifyHostKeyDNS=no \
      "$address" "$remote_command"
  ) < "$package" > "$response"; then
    ssh_status=0
  else
    ssh_status=$?
  fi
  CONTROLLER_LANDING_ROOT_PACKAGE_LAST_SSH_STATUS="$ssh_status"
  chmod 600 "$response" 2>/dev/null || return 1
  ((ssh_status == 0))
}

controller_landing_root_bootstrap_exchange() {
  [[ $# -eq 7 ]] || return 64
  local response="$7"
  controller_landing_root_package_exchange "$@" \
    "$CONTROLLER_LANDING_BOOTSTRAP_SESSION_TIMEOUT" || return 1
  controller_landing_bootstrap_response_is_valid "$response"
}

controller_landing_bootstrap_public_key() {
  local landing_id="$1" output="$2" manifest private_key
  manifest="$(controller_landing_registration_manifest "$landing_id")" || return 1
  private_key="$(jq -r '.ssh_private_key_file' "$manifest")" || return 1
  controller_landing_ssh_private_key_is_valid "$private_key" || return 1
  [[ ! -e "$output" && ! -L "$output" ]] || return 1
  "$CONTROLLER_LANDING_SSH_KEYGEN_BIN" -y -P '' -f "$private_key" > "$output" 2>/dev/null || return 1
  chmod 600 "$output" || return 1
  landing_channel_normalize_public_key "$output" "${output}.normalized" || return 1
  mv -- "${output}.normalized" "$output" || return 1
  controller_landing_private_file_is_trusted "$output"
}

controller_landing_send_bootstrap_action_in_work() {
  local action="$1" bootstrap_id="$2" landing_id="$3" address="$4" ssh_port="$5"
  local expected_fingerprint="$6" allowed_ipv4="$7" public_key="$8" work="$9"
  local package="$work/bootstrap-${action}.sh" response="$work/bootstrap-${action}.json"
  local known_hosts status
  controller_landing_build_bootstrap_package "$action" "$bootstrap_id" "$landing_id" \
    "$allowed_ipv4" "$public_key" "$package" || return 1
  known_hosts="$(controller_landing_prepare_known_hosts "$address" "$ssh_port" \
    "$expected_fingerprint" "sb-landing-$landing_id" "$work")" || return 1
  controller_landing_root_bootstrap_exchange "$address" "$ssh_port" "$landing_id" \
    "$known_hosts" "$expected_fingerprint" "$package" "$response" || return 1
  status="$(jq -r '.status' "$response")" || return 1
  case "$action:$status" in
    install:installed|rollback:rolled_back|rollback:already_rolled_back) return 0 ;;
    *) return 1 ;;
  esac
}

controller_landing_remove_bootstrap_action_files() {
  local work="$1" action="$2"
  rm -f -- "$work/bootstrap-${action}.sh" "$work/bootstrap-${action}.json" \
    "$work/host-key.scan" "$work/host-key.pub" "$work/known-hosts" || return 1
}

controller_bootstrap_landing_channel_in_work() {
  local landing_id="$1" address="$2" ssh_port="$3" expected_fingerprint="$4"
  local allowed_ipv4="$5" bootstrap_id="$6" work="$7"
  local public_key="$work/public-key"
  local install_confirmed=false rollback_ok=false
  controller_landing_bootstrap_public_key "$landing_id" "$public_key" || return 1
  if controller_landing_send_bootstrap_action_in_work install "$bootstrap_id" "$landing_id" \
      "$address" "$ssh_port" "$expected_fingerprint" "$allowed_ipv4" "$public_key" "$work"; then
    install_confirmed=true
  fi
  controller_landing_remove_bootstrap_action_files "$work" install || return 1
  if [[ "$install_confirmed" == true ]] &&
     controller_test_landing_registration_channel "$landing_id" "$address" "$ssh_port" \
       "$expected_fingerprint"; then
    CONTROLLER_LANDING_BOOTSTRAP_LAST_ROLLBACK=not_needed
    return 0
  fi
  if controller_landing_send_bootstrap_action_in_work rollback "$bootstrap_id" "$landing_id" \
      "$address" "$ssh_port" "$expected_fingerprint" "$allowed_ipv4" "$public_key" "$work"; then
    rollback_ok=true
  fi
  controller_landing_remove_bootstrap_action_files "$work" rollback || rollback_ok=false
  if [[ "$rollback_ok" == true ]]; then
    CONTROLLER_LANDING_BOOTSTRAP_LAST_ROLLBACK=completed
  else
    CONTROLLER_LANDING_BOOTSTRAP_LAST_ROLLBACK=failed
  fi
  return 1
}

controller_bootstrap_landing_channel() {
  [[ $# -eq 5 || $# -eq 6 ]] || return 64
  local landing_id="$1" address="$2" ssh_port="$3" expected_fingerprint="$4"
  local allowed_ipv4="$5" requested_bootstrap_id="${6:-}" bootstrap_id work rc=1
  controller_landing_transport_runtime_is_safe || return 1
  landing_id_is_valid "$landing_id" || return 1
  controller_landing_address_is_valid "$address" || return 1
  landing_port_is_valid "$ssh_port" || return 1
  [[ "$expected_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || return 1
  is_public_ipv4 "$allowed_ipv4" || return 1
  controller_landing_registration_manifest "$landing_id" >/dev/null || return 1
  if [[ -n "$requested_bootstrap_id" ]]; then
    bootstrap_id="$requested_bootstrap_id"
  else
    bootstrap_id="$(openssl rand -hex 32 2>/dev/null)" || return 1
  fi
  [[ "$bootstrap_id" =~ ^[0-9a-f]{64}$ ]] || return 1
  # 后续交互层与恢复入口在 source 后读取这两个结果；dormant 单脚本尚无菜单读者。
  # shellcheck disable=SC2034
  CONTROLLER_LANDING_BOOTSTRAP_LAST_ID="$bootstrap_id"
  # shellcheck disable=SC2034
  CONTROLLER_LANDING_BOOTSTRAP_LAST_ROLLBACK=not_started
  work="$(controller_landing_create_work_directory)" || return 1
  register_temp_path "$work" || {
    controller_landing_remove_work_directory "$work" || true
    return 1
  }
  if controller_bootstrap_landing_channel_in_work "$landing_id" "$address" "$ssh_port" \
      "$expected_fingerprint" "$allowed_ipv4" "$bootstrap_id" "$work"; then
    rc=0
  fi
  controller_landing_remove_work_directory "$work" || rc=1
  return "$rc"
}

controller_rollback_landing_bootstrap() {
  [[ $# -eq 6 ]] || return 64
  local landing_id="$1" address="$2" ssh_port="$3" expected_fingerprint="$4"
  local allowed_ipv4="$5" bootstrap_id="$6" work public_key rc=1
  controller_landing_transport_runtime_is_safe || return 1
  landing_id_is_valid "$landing_id" || return 1
  controller_landing_address_is_valid "$address" || return 1
  landing_port_is_valid "$ssh_port" || return 1
  [[ "$expected_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ &&
     "$bootstrap_id" =~ ^[0-9a-f]{64}$ ]] || return 1
  is_public_ipv4 "$allowed_ipv4" || return 1
  work="$(controller_landing_create_work_directory)" || return 1
  register_temp_path "$work" || {
    controller_landing_remove_work_directory "$work" || true
    return 1
  }
  public_key="$work/public-key"
  if controller_landing_bootstrap_public_key "$landing_id" "$public_key" &&
     controller_landing_send_bootstrap_action_in_work rollback "$bootstrap_id" "$landing_id" \
       "$address" "$ssh_port" "$expected_fingerprint" "$allowed_ipv4" "$public_key" "$work"; then
    rc=0
  fi
  controller_landing_remove_work_directory "$work" || rc=1
  return "$rc"
}
