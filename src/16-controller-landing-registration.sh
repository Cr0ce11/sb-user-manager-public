# ============================================================
# v5 入口侧受管落地注册（尚未接入菜单、角色安装或 root 引导）
# ============================================================

CONTROLLER_LANDING_PROBE_ERROR_CODE=invalid_input

controller_landing_display_name_is_valid() {
  local value="$1"
  jq -en --arg value "$value" '
    $value | type == "string" and length >= 1 and length <= 64 and
    (test("[[:cntrl:]]") | not)
  ' >/dev/null
}

controller_landing_registration_inputs_are_valid() {
  local landing_id="$1" display_name="$2" address="$3" ssh_port="$4"
  local expected_fingerprint="$5" gateway_port="$6"
  landing_id_is_valid "$landing_id" || return 1
  controller_landing_display_name_is_valid "$display_name" || return 1
  controller_landing_address_is_valid "$address" || return 1
  landing_port_is_valid "$ssh_port" || return 1
  [[ "$expected_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || return 1
  landing_port_is_valid "$gateway_port" || return 1
  ((10#$ssh_port != 10#$gateway_port))
}

controller_landing_registration_manifest() {
  local landing_id="$1" manifest
  landing_id_is_valid "$landing_id" || return 1
  manifest="$CONTROLLER_SECRET_DIR/landing-${landing_id}.json"
  controller_secret_ref_is_valid "$landing_id" "$manifest" || return 1
  validate_landing_credential_manifest "$manifest" || return 1
  [[ "$(jq -r '.landing_id' "$manifest")" == "$landing_id" ]] || return 1
  printf '%s\n' "$manifest"
}

controller_landing_discover_fingerprint() {
  [[ $# -eq 2 ]] || return 64
  local address="$1" ssh_port="$2" work fingerprint rc=1
  controller_landing_transport_runtime_is_safe || return 1
  controller_landing_address_is_valid "$address" || return 1
  landing_port_is_valid "$ssh_port" || return 1
  work="$(controller_landing_create_work_directory)" || return 1
  register_temp_path "$work" || {
    controller_landing_remove_work_directory "$work" || true
    return 1
  }
  if fingerprint="$(controller_landing_scan_ed25519_fingerprint \
      "$address" "$ssh_port" "$work")"; then
    rc=0
  fi
  controller_landing_remove_work_directory "$work" || rc=1
  ((rc == 0)) || return "$rc"
  printf '%s\n' "$fingerprint"
}

controller_landing_probe_restricted_channel_in_work() (
  local landing_id="$1" address="$2" ssh_port="$3" expected_fingerprint="$4"
  local private_key="$5" work="$6" known_hosts probe_input response_file ssh_status
  landing_id_is_valid "$landing_id" || return 1
  controller_landing_address_is_valid "$address" || return 1
  landing_port_is_valid "$ssh_port" || return 1
  [[ "$expected_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || return 1
  controller_landing_ssh_private_key_is_valid "$private_key" || return 1
  controller_private_directory_is_trusted "$work" || return 1

  known_hosts="$(controller_landing_prepare_known_hosts "$address" "$ssh_port" \
    "$expected_fingerprint" "sb-landing-$landing_id" "$work")" || return 1
  probe_input="$work/probe-input"
  response_file="$work/probe-response.json"
  [[ ! -e "$probe_input" && ! -L "$probe_input" &&
     ! -e "$response_file" && ! -L "$response_file" ]] || return 1
  (umask 077 && : > "$probe_input") || return 1
  controller_landing_private_file_is_trusted "$probe_input" || return 1
  exec 9< "$probe_input" || return 1
  rm -f -- "$probe_input" || { exec 9<&-; return 1; }

  if controller_landing_ssh_exchange "$address" "$ssh_port" "$landing_id" \
      "$private_key" "$known_hosts" "$expected_fingerprint" 9 "$response_file"; then
    exec 9<&-
    return 1
  fi
  exec 9<&-
  ssh_status="$CONTROLLER_LANDING_LAST_SSH_STATUS"
  [[ "$ssh_status" =~ ^[0-9]+$ ]] || return 1
  ((ssh_status != 0)) || return 1
  controller_landing_response_file_is_safe "$response_file" "$ssh_status" || return 1
  jq -e --arg code "$CONTROLLER_LANDING_PROBE_ERROR_CODE" '
    . == {status:"error", code:$code}
  ' "$response_file" >/dev/null 2>&1
)

controller_test_landing_registration_channel() {
  [[ $# -eq 4 ]] || return 64
  local landing_id="$1" address="$2" ssh_port="$3" expected_fingerprint="$4"
  local manifest private_key work rc=1
  controller_landing_transport_runtime_is_safe || return 1
  landing_id_is_valid "$landing_id" || return 1
  controller_landing_address_is_valid "$address" || return 1
  landing_port_is_valid "$ssh_port" || return 1
  [[ "$expected_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || return 1
  manifest="$(controller_landing_registration_manifest "$landing_id")" || return 1
  private_key="$(jq -r '.ssh_private_key_file' "$manifest")" || return 1
  controller_landing_ssh_private_key_is_valid "$private_key" || return 1
  work="$(controller_landing_create_work_directory)" || return 1
  register_temp_path "$work" || {
    controller_landing_remove_work_directory "$work" || true
    return 1
  }
  if controller_landing_probe_restricted_channel_in_work "$landing_id" "$address" \
      "$ssh_port" "$expected_fingerprint" "$private_key" "$work"; then
    rc=0
  fi
  controller_landing_remove_work_directory "$work" || rc=1
  return "$rc"
}

controller_register_landing() {
  [[ $# -eq 6 ]] || return 64
  local landing_id="$1" display_name="$2" address="$3" ssh_port="$4"
  local expected_fingerprint="$5" gateway_port="$6" manifest
  controller_landing_registration_inputs_are_valid "$landing_id" "$display_name" \
    "$address" "$ssh_port" "$expected_fingerprint" "$gateway_port" || return 1
  manifest="$(controller_landing_registration_manifest "$landing_id")" || return 1
  controller_test_landing_registration_channel "$landing_id" "$address" "$ssh_port" \
    "$expected_fingerprint" || return 1
  init_controller_state || return 1
  ssh_port=$((10#$ssh_port))
  gateway_port=$((10#$gateway_port))
  atomic_controller_state_update '
    if ([.landings[] | select(
      .id == $landing_id or
      (.address == $address and .ssh_port == $ssh_port) or
      .credential_ref == $credential_ref
    )] | length) != 0 then
      error("landing identity already registered")
    elif .revision >= 9007199254740991 then
      error("controller revision exhausted")
    else
      .revision += 1 |
      .landings += [{
        id: $landing_id,
        display_name: $display_name,
        address: $address,
        ssh_port: $ssh_port,
        ssh_host_fingerprint: $fingerprint,
        gateway_port: $gateway_port,
        status: "pending",
        desired_revision: 1,
        applied_revision: 0,
        config_sha256: null,
        credential_ref: $credential_ref
      }]
    end
  ' --arg landing_id "$landing_id" --arg display_name "$display_name" \
    --arg address "$address" --argjson ssh_port "$ssh_port" \
    --arg fingerprint "$expected_fingerprint" --argjson gateway_port "$gateway_port" \
    --arg credential_ref "$manifest"
}

controller_register_and_apply_landing() {
  [[ $# -eq 7 ]] || return 64
  local landing_id="$1" display_name="$2" address="$3" ssh_port="$4"
  local expected_fingerprint="$5" gateway_port="$6" allowed_entry_ipv4="$7"
  is_ipv4_address "$allowed_entry_ipv4" || return 1
  controller_register_landing "$landing_id" "$display_name" "$address" "$ssh_port" \
    "$expected_fingerprint" "$gateway_port" || return 1
  controller_apply_landing "$landing_id" "$allowed_entry_ipv4"
}
