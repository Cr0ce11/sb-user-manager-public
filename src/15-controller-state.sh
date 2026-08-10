# ============================================================
# v5 入口控制器独立状态（尚未接入 v4 菜单或运行流程）
# ============================================================

CONTROLLER_STATE_SCHEMA_VERSION=1
CONTROLLER_STATE_FILE="${SB_CONTROLLER_STATE_FILE:-/var/lib/sb-user-manager/controller-state.json}"
CONTROLLER_SECRET_DIR="${SB_CONTROLLER_SECRET_DIR:-/etc/sb-user-manager/controller-secrets}"
CONTROLLER_STATE_LOCK_FILE="${SB_CONTROLLER_STATE_LOCK_FILE:-/run/lock/sb-user-manager/controller-state.lock}"

controller_state_expected_uid() {
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true && "$EUID" -ne 0 ]]; then
    printf '%s\n' "$EUID"
  else
    printf '0\n'
  fi
}

controller_private_directory_is_trusted() {
  local path="$1" owner mode expected_owner
  [[ -d "$path" && ! -L "$path" ]] || return 1
  owner="$(manager_file_uid "$path")" || return 1
  expected_owner="$(controller_state_expected_uid)"
  [[ "$owner" == "$expected_owner" ]] || return 1
  mode="$(manager_file_mode "$path")" || return 1
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0777) == 0700 ))
}

ensure_controller_private_directory() {
  local path="$1"
  if [[ -e "$path" || -L "$path" ]]; then
    controller_private_directory_is_trusted "$path" || return 1
    chmod 700 "$path" || return 1
    return 0
  fi
  install -d -m 700 "$path" || return 1
  controller_private_directory_is_trusted "$path"
}

controller_state_file_is_trusted() {
  local path="${1:-$CONTROLLER_STATE_FILE}" owner mode expected_owner
  [[ -f "$path" && ! -L "$path" && -r "$path" ]] || return 1
  owner="$(manager_file_uid "$path")" || return 1
  expected_owner="$(controller_state_expected_uid)"
  [[ "$owner" == "$expected_owner" ]] || return 1
  mode="$(manager_file_mode "$path")" || return 1
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0777) == 0600 ))
}

controller_dns_name_is_valid() {
  local value="$1" label
  ((${#value} >= 3 && ${#value} <= 253)) || return 1
  [[ "$value" == *.* && "$value" != .* && "$value" != *. && "$value" != *..* ]] || return 1
  [[ "$value" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
  while IFS= read -r label; do
    ((${#label} >= 1 && ${#label} <= 63)) || return 1
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done < <(tr '.' '\n' <<<"$value")
}

controller_landing_address_is_valid() {
  local value="$1"
  if [[ "$value" =~ ^[0-9.]+$ ]]; then
    is_ipv4_address "$value"
  else
    controller_dns_name_is_valid "$value"
  fi
}

controller_secret_ref_is_valid() {
  local landing_id="$1" value="$2" expected
  [[ -n "$CONTROLLER_SECRET_DIR" && "$CONTROLLER_SECRET_DIR" == /* &&
     "$CONTROLLER_SECRET_DIR" != */ && "$CONTROLLER_SECRET_DIR" != *//* &&
     "$CONTROLLER_SECRET_DIR" != */../* && "$CONTROLLER_SECRET_DIR" != */.. &&
     "$CONTROLLER_SECRET_DIR" != */./* && "$CONTROLLER_SECRET_DIR" != */. ]] || return 1
  expected="$CONTROLLER_SECRET_DIR/landing-${landing_id}.json"
  [[ "$value" == "$expected" ]]
}

validate_controller_state_json() {
  local path="${1:-$CONTROLLER_STATE_FILE}" landing_id address credential_ref
  jq -e -s 'length == 1' "$path" >/dev/null || return 1
  jq -e --argjson schema "$CONTROLLER_STATE_SCHEMA_VERSION" '
    type == "object" and
    (keys | sort) == ["landings", "revision", "role", "schema_version"] and
    .schema_version == $schema and
    .role == "entry-controller" and
    (.revision | type == "number" and . == floor and . >= 0 and . <= 9007199254740991) and
    (.landings | type == "array") and
    ([.landings[].id] | length == (unique | length)) and
    all(.landings[];
      . as $landing |
      type == "object" and
      (keys | sort) == [
        "address", "applied_revision", "config_sha256", "credential_ref",
        "desired_revision", "display_name", "gateway_port", "id",
        "ssh_host_fingerprint", "ssh_port", "status"
      ] and
      (.id | type == "string" and test("^[a-z][a-z0-9-]{0,31}$")) and
      (.display_name | type == "string" and length >= 1 and length <= 64 and
        (test("[[:cntrl:]]") | not)) and
      (.address | type == "string" and length >= 1 and length <= 253) and
      (.ssh_port | type == "number" and . == floor and . >= 1 and . <= 65535) and
      (.ssh_host_fingerprint | type == "string" and test("^SHA256:[A-Za-z0-9+/]{43}$")) and
      (.gateway_port | type == "number" and . == floor and . >= 1 and . <= 65535) and
      (.status == "pending" or .status == "active" or .status == "disabled" or
       .status == "error" or .status == "emergency_override") and
      (.desired_revision | type == "number" and . == floor and . >= 0 and
        . <= 9007199254740991) and
      (.applied_revision | type == "number" and . == floor and . >= 0 and
        . <= 9007199254740991 and . <= $landing.desired_revision) and
      (.config_sha256 == null or
        (.config_sha256 | type == "string" and test("^[0-9a-f]{64}$"))) and
      (.credential_ref | type == "string" and length >= 1)
    )
  ' "$path" >/dev/null || return 1

  while IFS=$'\t' read -r landing_id address credential_ref; do
    controller_landing_address_is_valid "$address" || return 1
    controller_secret_ref_is_valid "$landing_id" "$credential_ref" || return 1
  done < <(jq -r '.landings[] | [.id, .address, .credential_ref] | @tsv' "$path")
}

validate_controller_state_file() {
  local path="${1:-$CONTROLLER_STATE_FILE}"
  controller_state_file_is_trusted "$path" || return 1
  validate_controller_state_json "$path"
}

controller_state_transition_is_valid() {
  local previous="$1" candidate="$2"
  jq -e -s '
    .[0] as $previous | .[1] as $candidate |
    ($candidate.revision >= $previous.revision) and
    (if $candidate.landings == $previous.landings then true
     else $candidate.revision > $previous.revision end) and
    all($previous.landings[];
      . as $old |
      ([ $candidate.landings[] | select(.id == $old.id) ] | first) as $new |
      $new == null or
      ($new.desired_revision >= $old.desired_revision and
       $new.applied_revision >= $old.applied_revision))
  ' "$previous" "$candidate" >/dev/null
}

prepare_controller_state_file() {
  local path="$1"
  chmod 600 "$path" || return 1
  if [[ "$EUID" -eq 0 && "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    chown root:root "$path" || return 1
  fi
  controller_state_file_is_trusted "$path" || return 1
  validate_controller_state_json "$path"
}

with_controller_state_lock() {
  local callback="$1" lock_dir rc
  shift
  lock_dir="$(dirname "$CONTROLLER_STATE_LOCK_FILE")"
  ensure_controller_private_directory "$lock_dir" || return 1
  [[ ! -L "$CONTROLLER_STATE_LOCK_FILE" ]] || return 1
  exec 7>"$CONTROLLER_STATE_LOCK_FILE" || return 1
  flock -x 7 || { exec 7>&-; return 1; }
  "$callback" "$@" && rc=0 || rc=$?
  flock -u 7 2>/dev/null || true
  exec 7>&-
  return "$rc"
}

init_controller_state_unlocked() {
  local state_dir tmp
  state_dir="$(dirname "$CONTROLLER_STATE_FILE")"
  ensure_controller_private_directory "$state_dir" || return 1
  ensure_controller_private_directory "$CONTROLLER_SECRET_DIR" || return 1
  if [[ -e "$CONTROLLER_STATE_FILE" || -L "$CONTROLLER_STATE_FILE" ]]; then
    validate_controller_state_file "$CONTROLLER_STATE_FILE"
    return
  fi
  tmp="$(mktemp "$state_dir/.controller-state.XXXXXX")" || return 1
  register_temp_path "$tmp" || { rm -f -- "$tmp"; return 1; }
  if ! printf '{"schema_version":%d,"role":"entry-controller","revision":0,"landings":[]}\n' \
      "$CONTROLLER_STATE_SCHEMA_VERSION" > "$tmp" ||
     ! prepare_controller_state_file "$tmp" ||
     ! mv -- "$tmp" "$CONTROLLER_STATE_FILE"; then
    rm -f -- "$tmp"
    return 1
  fi
  validate_controller_state_file "$CONTROLLER_STATE_FILE"
}

init_controller_state() {
  with_controller_state_lock init_controller_state_unlocked
}

atomic_controller_state_update_unlocked() {
  local filter="$1" state_dir tmp
  shift
  validate_controller_state_file "$CONTROLLER_STATE_FILE" || return 1
  state_dir="$(dirname "$CONTROLLER_STATE_FILE")"
  ensure_controller_private_directory "$state_dir" || return 1
  tmp="$(mktemp "$state_dir/.controller-state.XXXXXX")" || return 1
  register_temp_path "$tmp" || { rm -f -- "$tmp"; return 1; }
  if ! jq "$@" "$filter" "$CONTROLLER_STATE_FILE" > "$tmp" ||
     ! prepare_controller_state_file "$tmp" ||
     ! controller_state_transition_is_valid "$CONTROLLER_STATE_FILE" "$tmp" ||
     ! mv -- "$tmp" "$CONTROLLER_STATE_FILE"; then
    rm -f -- "$tmp"
    return 1
  fi
  validate_controller_state_file "$CONTROLLER_STATE_FILE"
}

atomic_controller_state_update() {
  local filter="$1"
  shift
  with_controller_state_lock atomic_controller_state_update_unlocked "$filter" "$@"
}
