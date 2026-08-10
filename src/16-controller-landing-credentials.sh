# ============================================================
# v5 入口侧单落地秘密初始化（尚未接入菜单或角色安装）
# ============================================================

CONTROLLER_LANDING_CREDENTIAL_CA_DAYS=3650
CONTROLLER_LANDING_CREDENTIAL_GATEWAY_DAYS=825
CONTROLLER_LANDING_CREDENTIAL_PASSWORD_BYTES=32
if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]]; then
  CONTROLLER_LANDING_CREDENTIAL_OPENSSL_BIN="${SB_CONTROLLER_LANDING_CREDENTIAL_OPENSSL_BIN:-$(command -v openssl)}"
  CONTROLLER_LANDING_CREDENTIAL_SSH_KEYGEN_BIN="${SB_CONTROLLER_LANDING_CREDENTIAL_SSH_KEYGEN_BIN:-$(command -v ssh-keygen)}"
else
  CONTROLLER_LANDING_CREDENTIAL_OPENSSL_BIN=/usr/bin/openssl
  CONTROLLER_LANDING_CREDENTIAL_SSH_KEYGEN_BIN=/usr/bin/ssh-keygen
fi

controller_landing_credentials_runtime_is_safe() {
  [[ "$CONTROLLER_LANDING_CREDENTIAL_CA_DAYS" == 3650 &&
     "$CONTROLLER_LANDING_CREDENTIAL_GATEWAY_DAYS" == 825 &&
     "$CONTROLLER_LANDING_CREDENTIAL_PASSWORD_BYTES" == 32 ]] || return 1
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    [[ "$EUID" -eq 0 &&
       "$CONTROLLER_STATE_FILE" == /var/lib/sb-user-manager/controller-state.json &&
       "$CONTROLLER_SECRET_DIR" == /etc/sb-user-manager/controller-secrets &&
       "$CONTROLLER_STATE_LOCK_FILE" == /run/lock/sb-user-manager/controller-state.lock &&
       "$CONTROLLER_LANDING_CREDENTIAL_OPENSSL_BIN" == /usr/bin/openssl &&
       "$CONTROLLER_LANDING_CREDENTIAL_SSH_KEYGEN_BIN" == /usr/bin/ssh-keygen ]] || return 1
  fi
  [[ -x "$CONTROLLER_LANDING_CREDENTIAL_OPENSSL_BIN" &&
     -x "$CONTROLLER_LANDING_CREDENTIAL_SSH_KEYGEN_BIN" ]]
}

controller_landing_credentials_dependencies_are_ready() {
  [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]] && return 0
  local dependency dependency_name
  for dependency_name in awk chmod chown dirname flock grep install jq mktemp mv python3 \
    readlink rm rmdir sha256sum ssh-keygen stat sync tr wc; do
    dependency="$(command -v "$dependency_name")" || return 1
    [[ "$dependency" == /* ]] || return 1
    landing_channel_root_executable_is_safe "$dependency" || return 1
  done
  landing_channel_root_executable_is_safe "$CONTROLLER_LANDING_CREDENTIAL_OPENSSL_BIN"
}

controller_landing_credentials_test_checkpoint() {
  local stage="$1"
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true &&
        "${SB_CONTROLLER_LANDING_CREDENTIAL_TEST_STOP_STAGE:-}" == "$stage" ]]; then
    return 1
  fi
}

controller_landing_credentials_final_paths() {
  local landing_id="$1"
  landing_id_is_valid "$landing_id" || return 1
  CONTROLLER_LANDING_CREDENTIAL_DIRECTORY="$CONTROLLER_SECRET_DIR/landing-${landing_id}"
  CONTROLLER_LANDING_CREDENTIAL_MANIFEST="$CONTROLLER_SECRET_DIR/landing-${landing_id}.json"
  controller_secret_ref_is_valid "$landing_id" "$CONTROLLER_LANDING_CREDENTIAL_MANIFEST"
}

controller_landing_credentials_directory_has_exact_files() (
  local directory="$1" entry
  local -a entries=()
  controller_private_directory_is_trusted "$directory" || return 1
  shopt -s nullglob dotglob
  entries=("$directory"/*)
  ((${#entries[@]} == 5)) || return 1
  for entry in "${entries[@]}"; do
    [[ -f "$entry" && ! -L "$entry" ]] || return 1
    case "${entry##*/}" in
      ssh-ed25519|gateway-password|gateway-ca.crt|gateway.crt|gateway.key) ;;
      *) return 1 ;;
    esac
  done
)

controller_landing_credentials_material_is_valid() {
  local landing_id="$1" server_name="$2" directory="$3"
  local ssh_key password ca_certificate certificate private_key ssh_public_key path
  landing_id_is_valid "$landing_id" || return 1
  controller_dns_name_is_valid "$server_name" || return 1
  controller_landing_credentials_directory_has_exact_files "$directory" || return 1
  ssh_key="$directory/ssh-ed25519"
  password="$directory/gateway-password"
  ca_certificate="$directory/gateway-ca.crt"
  certificate="$directory/gateway.crt"
  private_key="$directory/gateway.key"
  for path in "$ssh_key" "$password" "$ca_certificate" "$certificate" "$private_key"; do
    controller_state_file_is_trusted "$path" || return 1
  done
  ssh_public_key="$("$CONTROLLER_LANDING_CREDENTIAL_SSH_KEYGEN_BIN" -y -P '' \
    -f "$ssh_key" 2>/dev/null)" || return 1
  [[ "$ssh_public_key" == ssh-ed25519\ * ]] || return 1
  jq -e -Rs 'length >= 32 and length <= 128 and test("^[A-Za-z0-9_-]+$")' \
    "$password" >/dev/null || return 1
  validate_controller_tls_material "$ca_certificate" "$certificate" "$private_key" \
    "$server_name"
}

controller_landing_credentials_work_directory_is_owned() (
  local landing_id="$1" directory="$2" name entry uid mode expected_uid
  local -a entries=()
  landing_id_is_valid "$landing_id" || return 1
  [[ "$(dirname -- "$directory")" == "$CONTROLLER_SECRET_DIR" ]] || return 1
  name="${directory##*/}"
  [[ "$name" =~ ^\.landing-credentials\.${landing_id}\.[A-Za-z0-9]{10}$ ]] || return 1
  controller_private_directory_is_trusted "$directory" || return 1
  expected_uid="$(controller_state_expected_uid)" || return 1
  shopt -s nullglob dotglob
  entries=("$directory"/*)
  for entry in "${entries[@]}"; do
    [[ -f "$entry" && ! -L "$entry" ]] || return 1
    case "${entry##*/}" in
      ssh-ed25519|ssh-ed25519.pub|gateway-password|gateway-ca.crt|gateway.crt|gateway.key|\
      ca.conf|ca.key|gateway.conf|gateway.csr|ca.srl) ;;
      *) return 1 ;;
    esac
    uid="$(manager_file_uid "$entry")" || return 1
    mode="$(manager_file_mode "$entry")" || return 1
    [[ "$uid" == "$expected_uid" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 0022) == 0 )) || return 1
  done
)

controller_landing_remove_credentials_work_directory() {
  local landing_id="$1" directory="$2"
  controller_landing_credentials_work_directory_is_owned "$landing_id" "$directory" || return 1
  rm -f -- \
    "$directory/ssh-ed25519" "$directory/ssh-ed25519.pub" \
    "$directory/gateway-password" "$directory/gateway-ca.crt" \
    "$directory/gateway.crt" "$directory/gateway.key" \
    "$directory/ca.conf" "$directory/ca.key" "$directory/gateway.conf" \
    "$directory/gateway.csr" "$directory/ca.srl" || return 1
  rmdir -- "$directory" || return 1
  sync_transaction_path "$CONTROLLER_SECRET_DIR"
}

controller_landing_manifest_temp_is_owned() {
  local landing_id="$1" path="$2" name uid mode expected_uid
  landing_id_is_valid "$landing_id" || return 1
  [[ "$(dirname -- "$path")" == "$CONTROLLER_SECRET_DIR" ]] || return 1
  name="${path##*/}"
  [[ "$name" =~ ^\.landing-manifest\.${landing_id}\.[A-Za-z0-9]{10}$ &&
     -f "$path" && ! -L "$path" ]] || return 1
  uid="$(manager_file_uid "$path")" || return 1
  mode="$(manager_file_mode "$path")" || return 1
  expected_uid="$(controller_state_expected_uid)" || return 1
  [[ "$uid" == "$expected_uid" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0077) == 0 ))
}

controller_landing_credentials_cleanup_staging() (
  local landing_id="$1" path
  local -a work_directories=() manifest_files=()
  landing_id_is_valid "$landing_id" || return 1
  shopt -s nullglob
  work_directories=("$CONTROLLER_SECRET_DIR/.landing-credentials.${landing_id}."*)
  manifest_files=("$CONTROLLER_SECRET_DIR/.landing-manifest.${landing_id}."*)
  shopt -u nullglob
  if ((${#work_directories[@]} > 0)); then
    for path in "${work_directories[@]}"; do
      controller_landing_remove_credentials_work_directory "$landing_id" "$path" || return 1
    done
  fi
  if ((${#manifest_files[@]} > 0)); then
    for path in "${manifest_files[@]}"; do
      controller_landing_manifest_temp_is_owned "$landing_id" "$path" || return 1
      rm -f -- "$path" || return 1
    done
  fi
  sync_transaction_path "$CONTROLLER_SECRET_DIR"
)

controller_landing_credentials_prepare_private_file() {
  local path="$1"
  chmod 600 "$path" || return 1
  if [[ "$EUID" -eq 0 && "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    chown root:root "$path" || return 1
  fi
  controller_state_file_is_trusted "$path"
}

controller_landing_generate_credentials_in_work() {
  local landing_id="$1" server_name="$2" work="$3"
  controller_private_directory_is_trusted "$work" || return 1
  controller_dns_name_is_valid "$server_name" || return 1
  (umask 077 && printf '%s\n' \
    '[req]' 'distinguished_name=dn' 'x509_extensions=v3_ca' 'prompt=no' \
    '[dn]' 'CN=sb-user-manager managed landing CA' \
    '[v3_ca]' 'basicConstraints=critical,CA:TRUE' \
    'keyUsage=critical,keyCertSign,cRLSign' > "$work/ca.conf") || return 1
  (umask 077 && {
    printf '%s\n' \
      '[req]' 'distinguished_name=dn' 'req_extensions=req_ext' 'prompt=no' \
      '[dn]' 'CN=sb-user-manager managed landing gateway' \
      '[req_ext]' "subjectAltName=DNS:${server_name}" \
      'basicConstraints=critical,CA:FALSE' \
      'keyUsage=critical,digitalSignature,keyEncipherment' \
      'extendedKeyUsage=serverAuth'
  } > "$work/gateway.conf") || return 1
  "$CONTROLLER_LANDING_CREDENTIAL_SSH_KEYGEN_BIN" -q -t ed25519 -N '' -C '' \
    -f "$work/ssh-ed25519" >/dev/null 2>&1 || return 1
  "$CONTROLLER_LANDING_CREDENTIAL_OPENSSL_BIN" rand -hex \
    "$CONTROLLER_LANDING_CREDENTIAL_PASSWORD_BYTES" 2>/dev/null |
    tr -d '\n' > "$work/gateway-password" || return 1
  "$CONTROLLER_LANDING_CREDENTIAL_OPENSSL_BIN" req -x509 -newkey rsa:2048 -sha256 \
    -nodes -days "$CONTROLLER_LANDING_CREDENTIAL_CA_DAYS" -config "$work/ca.conf" \
    -keyout "$work/ca.key" -out "$work/gateway-ca.crt" >/dev/null 2>&1 || return 1
  "$CONTROLLER_LANDING_CREDENTIAL_OPENSSL_BIN" req -newkey rsa:2048 -sha256 -nodes \
    -config "$work/gateway.conf" -keyout "$work/gateway.key" \
    -out "$work/gateway.csr" >/dev/null 2>&1 || return 1
  "$CONTROLLER_LANDING_CREDENTIAL_OPENSSL_BIN" x509 -req -sha256 \
    -days "$CONTROLLER_LANDING_CREDENTIAL_GATEWAY_DAYS" \
    -in "$work/gateway.csr" -CA "$work/gateway-ca.crt" -CAkey "$work/ca.key" \
    -CAserial "$work/ca.srl" -CAcreateserial -out "$work/gateway.crt" \
    -extfile "$work/gateway.conf" \
    -extensions req_ext >/dev/null 2>&1 || return 1
  chmod 600 "$work/ssh-ed25519" "$work/ssh-ed25519.pub" \
    "$work/gateway-password" "$work/gateway-ca.crt" "$work/gateway.crt" \
    "$work/gateway.key" "$work/ca.conf" "$work/ca.key" "$work/gateway.conf" \
    "$work/gateway.csr" "$work/ca.srl" || return 1
  rm -f -- "$work/ssh-ed25519.pub" "$work/ca.conf" "$work/ca.key" \
    "$work/gateway.conf" "$work/gateway.csr" "$work/ca.srl" || return 1
  controller_landing_credentials_material_is_valid "$landing_id" "$server_name" "$work"
}

controller_landing_write_credentials_manifest() {
  local landing_id="$1" server_name="$2" directory="$3" manifest="$4"
  local tmp
  [[ ! -e "$manifest" && ! -L "$manifest" ]] || return 1
  controller_landing_credentials_material_is_valid "$landing_id" "$server_name" \
    "$directory" || return 1
  tmp="$(mktemp "$CONTROLLER_SECRET_DIR/.landing-manifest.${landing_id}.XXXXXXXXXX")" || return 1
  register_temp_path "$tmp"
  if ! SB_LANDING_CREDENTIAL_SERVER_NAME="$server_name" jq -n \
      --argjson schema "$LANDING_CREDENTIAL_SCHEMA_VERSION" \
      --arg landing_id "$landing_id" \
      --arg ssh_key "$directory/ssh-ed25519" \
      --arg password "$directory/gateway-password" \
      --arg ca "$directory/gateway-ca.crt" \
      --arg certificate "$directory/gateway.crt" \
      --arg private_key "$directory/gateway.key" '
        {
          schema_version:$schema,
          landing_id:$landing_id,
          gateway_server_name:$ENV.SB_LANDING_CREDENTIAL_SERVER_NAME,
          ssh_private_key_file:$ssh_key,
          gateway_password_file:$password,
          gateway_ca_certificate_file:$ca,
          gateway_certificate_file:$certificate,
          gateway_private_key_file:$private_key
        }
      ' > "$tmp" ||
     ! controller_landing_credentials_prepare_private_file "$tmp" ||
     ! validate_landing_credential_manifest_json "$tmp" ||
     ! sync_transaction_path "$tmp" ||
     ! controller_landing_credentials_test_checkpoint before_manifest_publish ||
     ! mv -- "$tmp" "$manifest" ||
     ! sync_transaction_path "$CONTROLLER_SECRET_DIR"; then
    if [[ -e "$tmp" || -L "$tmp" ]]; then
      if controller_landing_manifest_temp_is_owned "$landing_id" "$tmp"; then
        rm -f -- "$tmp" || true
      fi
    fi
    return 1
  fi
  validate_landing_credential_manifest "$manifest"
}

controller_initialize_landing_credentials_unlocked() {
  local landing_id="$1" server_name="$2" directory manifest work=""
  validate_controller_state_file "$CONTROLLER_STATE_FILE" || return 1
  jq -e --arg landing_id "$landing_id" \
    'all(.landings[]; .id != $landing_id)' "$CONTROLLER_STATE_FILE" >/dev/null || return 1
  controller_landing_credentials_final_paths "$landing_id" || return 1
  directory="$CONTROLLER_LANDING_CREDENTIAL_DIRECTORY"
  manifest="$CONTROLLER_LANDING_CREDENTIAL_MANIFEST"
  controller_landing_credentials_cleanup_staging "$landing_id" || return 1

  if [[ -e "$manifest" || -L "$manifest" ]]; then
    [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
    validate_landing_credential_manifest "$manifest" || return 1
    [[ "$(jq -r '.gateway_server_name' "$manifest")" == "$server_name" ]] || return 1
    printf '%s\n' "$manifest"
    return
  fi
  if [[ -e "$directory" || -L "$directory" ]]; then
    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    controller_landing_credentials_material_is_valid "$landing_id" "$server_name" \
      "$directory" || return 1
    controller_landing_write_credentials_manifest "$landing_id" "$server_name" \
      "$directory" "$manifest" || return 1
    printf '%s\n' "$manifest"
    return
  fi

  work="$(mktemp -d "$CONTROLLER_SECRET_DIR/.landing-credentials.${landing_id}.XXXXXXXXXX")" || return 1
  chmod 700 "$work" || return 1
  register_temp_path "$work"
  controller_private_directory_is_trusted "$work" || return 1
  if ! controller_landing_credentials_test_checkpoint after_work_created ||
     ! controller_landing_generate_credentials_in_work "$landing_id" "$server_name" "$work" ||
     ! controller_landing_credentials_test_checkpoint after_material_generated; then
    controller_landing_remove_credentials_work_directory "$landing_id" "$work" || true
    return 1
  fi
  for path in "$work/ssh-ed25519" "$work/gateway-password" "$work/gateway-ca.crt" \
    "$work/gateway.crt" "$work/gateway.key"; do
    sync_transaction_path "$path" || {
      controller_landing_remove_credentials_work_directory "$landing_id" "$work" || true
      return 1
    }
  done
  sync_transaction_path "$work" || {
    controller_landing_remove_credentials_work_directory "$landing_id" "$work" || true
    return 1
  }
  mv -- "$work" "$directory" || {
    controller_landing_remove_credentials_work_directory "$landing_id" "$work" || true
    return 1
  }
  sync_transaction_path "$CONTROLLER_SECRET_DIR" || return 1
  controller_landing_credentials_test_checkpoint after_directory_published || return 1
  controller_landing_write_credentials_manifest "$landing_id" "$server_name" \
    "$directory" "$manifest" || return 1
  printf '%s\n' "$manifest"
}

controller_initialize_landing_credentials() {
  [[ $# -eq 2 ]] || return 64
  local landing_id="$1" server_name="$2"
  local PATH="${PATH:-}" LC_ALL="${LC_ALL:-}"
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    PATH=/usr/sbin:/usr/bin:/sbin:/bin
    LC_ALL=C
    export PATH LC_ALL
    unset BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH OPENSSL_CONF
  fi
  controller_landing_credentials_runtime_is_safe || return 1
  controller_landing_credentials_dependencies_are_ready || return 1
  landing_id_is_valid "$landing_id" || return 1
  controller_dns_name_is_valid "$server_name" || return 1
  validate_controller_state_file "$CONTROLLER_STATE_FILE" || return 1
  with_controller_state_lock controller_initialize_landing_credentials_unlocked \
    "$landing_id" "$server_name"
}

controller_remove_unregistered_landing_credentials_unlocked() {
  local landing_id="$1" server_name="$2" directory manifest manifest_sni
  validate_controller_state_file "$CONTROLLER_STATE_FILE" || return 1
  jq -e --arg landing_id "$landing_id" \
    'all(.landings[]; .id != $landing_id)' "$CONTROLLER_STATE_FILE" >/dev/null || return 1
  controller_landing_credentials_final_paths "$landing_id" || return 1
  directory="$CONTROLLER_LANDING_CREDENTIAL_DIRECTORY"
  manifest="$CONTROLLER_LANDING_CREDENTIAL_MANIFEST"
  controller_landing_credentials_cleanup_staging "$landing_id" || return 1
  if [[ ! -e "$manifest" && ! -L "$manifest" &&
        ! -e "$directory" && ! -L "$directory" ]]; then
    return 0
  fi
  [[ -d "$directory" && ! -L "$directory" ]] || return 1
  if [[ -e "$manifest" || -L "$manifest" ]]; then
    [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
    validate_landing_credential_manifest "$manifest" || return 1
    manifest_sni="$(jq -r '.gateway_server_name' "$manifest")" || return 1
    [[ "$manifest_sni" == "$server_name" ]] || return 1
  fi
  controller_landing_credentials_material_is_valid "$landing_id" "$server_name" \
    "$directory" || return 1
  if [[ -e "$manifest" ]]; then
    rm -f -- "$manifest" || return 1
    sync_transaction_path "$CONTROLLER_SECRET_DIR" || return 1
  fi
  rm -f -- "$directory/ssh-ed25519" "$directory/gateway-password" \
    "$directory/gateway-ca.crt" "$directory/gateway.crt" \
    "$directory/gateway.key" || return 1
  rmdir -- "$directory" || return 1
  sync_transaction_path "$CONTROLLER_SECRET_DIR"
}

controller_remove_unregistered_landing_credentials() {
  [[ $# -eq 2 ]] || return 64
  local landing_id="$1" server_name="$2"
  local PATH="${PATH:-}" LC_ALL="${LC_ALL:-}"
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    PATH=/usr/sbin:/usr/bin:/sbin:/bin
    LC_ALL=C
    export PATH LC_ALL
    unset BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH OPENSSL_CONF
  fi
  controller_landing_credentials_runtime_is_safe || return 1
  controller_landing_credentials_dependencies_are_ready || return 1
  landing_id_is_valid "$landing_id" || return 1
  controller_dns_name_is_valid "$server_name" || return 1
  validate_controller_state_file "$CONTROLLER_STATE_FILE" || return 1
  with_controller_state_lock controller_remove_unregistered_landing_credentials_unlocked \
    "$landing_id" "$server_name"
}
