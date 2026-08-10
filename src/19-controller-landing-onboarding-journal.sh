# ============================================================
# v5 入口侧落地初始化持久日志（尚未接入菜单或服务器）
# ============================================================

CONTROLLER_LANDING_ONBOARDING_JOURNAL_SCHEMA_VERSION=1
CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE="${SB_CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE:-/var/lib/sb-user-manager/controller-onboarding.json}"
CONTROLLER_LANDING_ONBOARDING_JOURNAL_NEXT="${CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE}.next"
CONTROLLER_LANDING_ONBOARDING_LOCK_FILE="${SB_CONTROLLER_LANDING_ONBOARDING_LOCK_FILE:-/run/lock/sb-user-manager/controller-onboarding.lock}"
CONTROLLER_LANDING_ONBOARDING_LOCK_TIMEOUT=30
CONTROLLER_LANDING_ONBOARDING_JOURNAL_MAX_BYTES=8192

controller_landing_onboarding_absolute_path_is_safe() {
  local path="$1"
  [[ "$path" == /* && "$path" != / && "$path" != */ &&
     "$path" != *//* && "$path" != */../* && "$path" != */.. &&
     "$path" != */./* && "$path" != */. ]]
}

controller_landing_onboarding_paths_are_safe() {
  local journal_parent state_parent
  controller_landing_onboarding_absolute_path_is_safe \
    "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE" || return 1
  controller_landing_onboarding_absolute_path_is_safe \
    "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_NEXT" || return 1
  controller_landing_onboarding_absolute_path_is_safe \
    "$CONTROLLER_LANDING_ONBOARDING_LOCK_FILE" || return 1
  [[ "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_NEXT" == "${CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE}.next" &&
     "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE" != "$CONTROLLER_STATE_FILE" &&
     "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE" != "$CONTROLLER_LANDING_ONBOARDING_LOCK_FILE" ]] ||
    return 1
  journal_parent="$(dirname -- "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE")" || return 1
  state_parent="$(dirname -- "$CONTROLLER_STATE_FILE")" || return 1
  [[ "$journal_parent" == "$state_parent" ]] || return 1
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    [[ "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE" == /var/lib/sb-user-manager/controller-onboarding.json &&
       "$CONTROLLER_LANDING_ONBOARDING_LOCK_FILE" == /run/lock/sb-user-manager/controller-onboarding.lock ]] ||
      return 1
  fi
}

controller_landing_onboarding_private_file_is_trusted() {
  local path="$1" max_bytes="$2" owner mode expected_owner size
  [[ -f "$path" && ! -L "$path" && -r "$path" ]] || return 1
  owner="$(manager_file_uid "$path")" || return 1
  expected_owner="$(controller_state_expected_uid)" || return 1
  [[ "$owner" == "$expected_owner" ]] || return 1
  mode="$(manager_file_mode "$path")" || return 1
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0777) == 0600 )) || return 1
  size="$(controller_landing_file_size "$path")" || return 1
  [[ "$size" =~ ^[0-9]+$ ]] || return 1
  ((size <= max_bytes))
}

controller_landing_onboarding_values_are_valid() {
  [[ $# -eq 12 ]] || return 64
  local stage="$1" operation_id="$2" bootstrap_id="$3" landing_id="$4"
  local display_name="$5" address="$6" ssh_port="$7" gateway_port="$8"
  local server_name="$9" allowed_entry_ipv4="${10}" fingerprint="${11}"
  local credentials_preexisting="${12}"
  case "$stage" in
    credentials_pending|bootstrap_pending|registration_pending|apply_pending|local_aborted|remote_rolled_back|completed) ;;
    *) return 1 ;;
  esac
  [[ "$operation_id" =~ ^[0-9a-f]{64}$ &&
     "$bootstrap_id" =~ ^[0-9a-f]{64}$ ]] || return 1
  landing_id_is_valid "$landing_id" || return 1
  controller_landing_display_name_is_valid "$display_name" || return 1
  controller_landing_address_is_valid "$address" || return 1
  landing_port_is_valid "$ssh_port" || return 1
  landing_port_is_valid "$gateway_port" || return 1
  ((10#$ssh_port != 10#$gateway_port)) || return 1
  controller_dns_name_is_valid "$server_name" || return 1
  is_public_ipv4 "$allowed_entry_ipv4" || return 1
  [[ "$fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || return 1
  [[ "$credentials_preexisting" == true || "$credentials_preexisting" == false ]]
}

controller_landing_onboarding_journal_json_is_valid() {
  local path="$1" operation_id bootstrap_id landing_id display_name address
  local ssh_port gateway_port server_name allowed_entry_ipv4 fingerprint
  local credentials_preexisting stage
  jq -e -s --argjson schema "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_SCHEMA_VERSION" '
    length == 1 and
    .[0] as $journal |
    ($journal | type == "object") and
    ($journal | keys | sort) == [
      "address", "allowed_entry_ipv4", "bootstrap_id", "credentials_preexisting",
      "display_name", "gateway_port", "landing_id", "operation_id",
      "schema_version", "server_name", "ssh_host_fingerprint", "ssh_port", "stage"
    ] and
    $journal.schema_version == $schema and
    ($journal.operation_id | type == "string" and test("^[0-9a-f]{64}$")) and
    ($journal.bootstrap_id | type == "string" and test("^[0-9a-f]{64}$")) and
    ($journal.landing_id | type == "string" and test("^[a-z][a-z0-9-]{0,31}$")) and
    ($journal.display_name | type == "string" and length >= 1 and length <= 64 and
      (test("[[:cntrl:]]") | not)) and
    ($journal.address | type == "string" and length >= 1 and length <= 253) and
    ($journal.ssh_port | type == "number" and . == floor and . >= 1 and . <= 65535) and
    ($journal.gateway_port | type == "number" and . == floor and . >= 1 and . <= 65535) and
    ($journal.server_name | type == "string" and length >= 3 and length <= 253) and
    ($journal.allowed_entry_ipv4 | type == "string" and length >= 7 and length <= 15) and
    ($journal.ssh_host_fingerprint | type == "string" and
      test("^SHA256:[A-Za-z0-9+/]{43}$")) and
    ($journal.credentials_preexisting | type == "boolean") and
    ($journal.stage == "credentials_pending" or
      $journal.stage == "bootstrap_pending" or
      $journal.stage == "registration_pending" or
      $journal.stage == "apply_pending" or
      $journal.stage == "local_aborted" or
      $journal.stage == "remote_rolled_back" or
      $journal.stage == "completed")
  ' "$path" >/dev/null 2>&1 || return 1
  IFS=$'\t' read -r operation_id bootstrap_id landing_id display_name address \
    ssh_port gateway_port server_name allowed_entry_ipv4 fingerprint \
    credentials_preexisting stage < <(
      jq -r '[
        .operation_id, .bootstrap_id, .landing_id, .display_name, .address,
        .ssh_port, .gateway_port, .server_name, .allowed_entry_ipv4,
        .ssh_host_fingerprint, .credentials_preexisting, .stage
      ] | @tsv' "$path"
    ) || return 1
  controller_landing_onboarding_values_are_valid "$stage" "$operation_id" \
    "$bootstrap_id" "$landing_id" "$display_name" "$address" "$ssh_port" \
    "$gateway_port" "$server_name" "$allowed_entry_ipv4" "$fingerprint" \
    "$credentials_preexisting"
}

controller_landing_onboarding_journal_is_trusted() {
  local path="${1:-$CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE}"
  controller_landing_onboarding_paths_are_safe || return 1
  [[ "$path" == "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE" ||
     "$path" == "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_NEXT" ]] || return 1
  controller_landing_onboarding_private_file_is_trusted "$path" \
    "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_MAX_BYTES" || return 1
  controller_landing_onboarding_journal_json_is_valid "$path"
}

controller_landing_onboarding_remove_next_file() {
  local next="$CONTROLLER_LANDING_ONBOARDING_JOURNAL_NEXT" parent
  controller_landing_onboarding_paths_are_safe || return 1
  [[ -e "$next" || -L "$next" ]] || return 0
  controller_landing_onboarding_private_file_is_trusted "$next" \
    "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_MAX_BYTES" || return 1
  parent="$(dirname -- "$next")" || return 1
  rm -f -- "$next" || return 1
  sync_transaction_path "$parent"
}

controller_landing_onboarding_stage_transition_is_valid() {
  local current="$1" next="$2"
  [[ "$current" == "$next" ]] && return 0
  case "$current:$next" in
    credentials_pending:bootstrap_pending|credentials_pending:local_aborted|bootstrap_pending:local_aborted|bootstrap_pending:registration_pending|bootstrap_pending:remote_rolled_back|registration_pending:apply_pending|registration_pending:remote_rolled_back|apply_pending:completed) return 0 ;;
    *) return 1 ;;
  esac
}

controller_landing_onboarding_journal_matches_values() {
  [[ $# -eq 11 ]] || return 64
  local operation_id="$1" bootstrap_id="$2" landing_id="$3" display_name="$4"
  local address="$5" ssh_port="$6" gateway_port="$7" server_name="$8"
  local allowed_entry_ipv4="$9" fingerprint="${10}" credentials_preexisting="${11}"
  local SB_CONTROLLER_ONBOARDING_SERVER_NAME="$server_name"
  export SB_CONTROLLER_ONBOARDING_SERVER_NAME
  controller_landing_onboarding_journal_is_trusted || return 1
  jq -e --arg operation_id "$operation_id" --arg bootstrap_id "$bootstrap_id" \
    --arg landing_id "$landing_id" --arg display_name "$display_name" \
    --arg address "$address" --argjson ssh_port "$((10#$ssh_port))" \
    --argjson gateway_port "$((10#$gateway_port))" \
    --arg allowed_entry_ipv4 "$allowed_entry_ipv4" --arg fingerprint "$fingerprint" \
    --argjson credentials_preexisting "$credentials_preexisting" '
      .operation_id == $operation_id and
      .bootstrap_id == $bootstrap_id and
      .landing_id == $landing_id and
      .display_name == $display_name and
      .address == $address and
      .ssh_port == $ssh_port and
      .gateway_port == $gateway_port and
      .server_name == $ENV.SB_CONTROLLER_ONBOARDING_SERVER_NAME and
      .allowed_entry_ipv4 == $allowed_entry_ipv4 and
      .ssh_host_fingerprint == $fingerprint and
      .credentials_preexisting == $credentials_preexisting
    ' "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE" >/dev/null 2>&1
}

controller_landing_onboarding_write_journal() {
  [[ $# -eq 12 ]] || return 64
  local stage="$1" operation_id="$2" bootstrap_id="$3" landing_id="$4"
  local display_name="$5" address="$6" ssh_port="$7" gateway_port="$8"
  local server_name="$9" allowed_entry_ipv4="${10}" fingerprint="${11}"
  local credentials_preexisting="${12}" journal next parent current_stage
  local SB_CONTROLLER_ONBOARDING_SERVER_NAME="$server_name"
  export SB_CONTROLLER_ONBOARDING_SERVER_NAME
  controller_landing_onboarding_values_are_valid "$stage" "$operation_id" \
    "$bootstrap_id" "$landing_id" "$display_name" "$address" "$ssh_port" \
    "$gateway_port" "$server_name" "$allowed_entry_ipv4" "$fingerprint" \
    "$credentials_preexisting" || return 1
  controller_landing_onboarding_paths_are_safe || return 1
  journal="$CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE"
  next="$CONTROLLER_LANDING_ONBOARDING_JOURNAL_NEXT"
  parent="$(dirname -- "$journal")" || return 1
  ensure_controller_private_directory "$parent" || return 1
  if [[ -e "$journal" || -L "$journal" ]]; then
    controller_landing_onboarding_journal_matches_values "$operation_id" \
      "$bootstrap_id" "$landing_id" "$display_name" "$address" "$ssh_port" \
      "$gateway_port" "$server_name" "$allowed_entry_ipv4" "$fingerprint" \
      "$credentials_preexisting" || return 1
    current_stage="$(jq -r '.stage' "$journal")" || return 1
    controller_landing_onboarding_stage_transition_is_valid "$current_stage" \
      "$stage" || return 1
  else
    [[ "$stage" == credentials_pending ]] || return 1
  fi
  controller_landing_onboarding_remove_next_file || return 1
  (umask 077; set -o noclobber; : > "$next") 2>/dev/null || return 1
  chmod 600 "$next" || { rm -f -- "$next" || true; return 1; }
  if ! jq -n --argjson schema "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_SCHEMA_VERSION" \
      --arg stage "$stage" --arg operation_id "$operation_id" \
      --arg bootstrap_id "$bootstrap_id" --arg landing_id "$landing_id" \
      --arg display_name "$display_name" --arg address "$address" \
      --argjson ssh_port "$((10#$ssh_port))" \
      --argjson gateway_port "$((10#$gateway_port))" \
      --arg allowed_entry_ipv4 "$allowed_entry_ipv4" --arg fingerprint "$fingerprint" \
      --argjson credentials_preexisting "$credentials_preexisting" '
        {
          schema_version:$schema,
          operation_id:$operation_id,
          bootstrap_id:$bootstrap_id,
          landing_id:$landing_id,
          display_name:$display_name,
          address:$address,
          ssh_port:$ssh_port,
          gateway_port:$gateway_port,
          server_name:$ENV.SB_CONTROLLER_ONBOARDING_SERVER_NAME,
          allowed_entry_ipv4:$allowed_entry_ipv4,
          ssh_host_fingerprint:$fingerprint,
          credentials_preexisting:$credentials_preexisting,
          stage:$stage
        }
      ' > "$next" ||
     ! chmod 600 "$next" ||
     ! controller_landing_onboarding_journal_is_trusted "$next" ||
     ! sync_transaction_path "$next" ||
     ! mv -- "$next" "$journal" ||
     ! sync_transaction_path "$parent"; then
    rm -f -- "$next" || true
    return 1
  fi
  controller_landing_onboarding_journal_is_trusted "$journal"
}

controller_landing_onboarding_clear_journal() {
  [[ $# -eq 1 ]] || return 64
  local operation_id="$1" journal parent
  [[ "$operation_id" =~ ^[0-9a-f]{64}$ ]] || return 1
  controller_landing_onboarding_paths_are_safe || return 1
  journal="$CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE"
  controller_landing_onboarding_journal_is_trusted "$journal" || return 1
  jq -e --arg operation_id "$operation_id" '.operation_id == $operation_id' \
    "$journal" >/dev/null 2>&1 || return 1
  controller_landing_onboarding_remove_next_file || return 1
  parent="$(dirname -- "$journal")" || return 1
  rm -f -- "$journal" || return 1
  sync_transaction_path "$parent" || return 1
  [[ ! -e "$journal" && ! -L "$journal" ]]
}

controller_landing_onboarding_generate_id() {
  local purpose="$1" value
  [[ "$purpose" == operation || "$purpose" == bootstrap ]] || return 64
  value="$(openssl rand -hex 32 2>/dev/null)" || return 1
  [[ "$value" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$value"
}

controller_landing_onboarding_lock_file_is_trusted() {
  local lock="$CONTROLLER_LANDING_ONBOARDING_LOCK_FILE"
  controller_landing_onboarding_paths_are_safe || return 1
  controller_landing_onboarding_private_file_is_trusted "$lock" 0
}

controller_landing_onboarding_prepare_lock_file() {
  local lock="$CONTROLLER_LANDING_ONBOARDING_LOCK_FILE" parent
  controller_landing_onboarding_paths_are_safe || return 1
  parent="$(dirname -- "$lock")" || return 1
  ensure_controller_private_directory "$parent" || return 1
  if [[ ! -e "$lock" && ! -L "$lock" ]]; then
    (umask 077; set -o noclobber; : > "$lock") 2>/dev/null || return 1
    chmod 600 "$lock" || return 1
    sync_transaction_path "$lock" || return 1
    sync_transaction_path "$parent" || return 1
  fi
  controller_landing_onboarding_lock_file_is_trusted
}

with_controller_landing_onboarding_lock() {
  local callback="$1" rc lock="$CONTROLLER_LANDING_ONBOARDING_LOCK_FILE"
  shift
  declare -F "$callback" >/dev/null 2>&1 || return 1
  controller_landing_onboarding_prepare_lock_file || return 1
  exec 6<>"$lock" || return 1
  flock -x -w "$CONTROLLER_LANDING_ONBOARDING_LOCK_TIMEOUT" 6 || {
    exec 6>&-
    return 1
  }
  "$callback" "$@" 6>&- && rc=0 || rc=$?
  flock -u 6 2>/dev/null || true
  exec 6>&-
  return "$rc"
}
