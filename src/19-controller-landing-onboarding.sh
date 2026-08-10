# ============================================================
# v5 单落地初始化向导编排（尚未接入角色路由或菜单）
# ============================================================
# 后续交互层读取这些结果；当前 dormant 模块由定向测试覆盖。
# shellcheck disable=SC2034

CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=not_started
CONTROLLER_LANDING_ONBOARDING_LAST_FINGERPRINT=""
CONTROLLER_LANDING_ONBOARDING_LAST_REMOTE_ROLLBACK=not_needed
CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=not_changed
CONTROLLER_LANDING_ONBOARDING_LAST_READINESS_STAGE=not_started
CONTROLLER_LANDING_ONBOARDING_LAST_DEPENDENCY_STATUS=not_checked
CONTROLLER_LANDING_ONBOARDING_LAST_SINGBOX_STATUS=not_checked

controller_landing_onboarding_reset_result() {
  CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=not_started
  CONTROLLER_LANDING_ONBOARDING_LAST_FINGERPRINT=""
  CONTROLLER_LANDING_ONBOARDING_LAST_REMOTE_ROLLBACK=not_needed
  CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=not_changed
  CONTROLLER_LANDING_ONBOARDING_LAST_READINESS_STAGE=not_started
  CONTROLLER_LANDING_ONBOARDING_LAST_DEPENDENCY_STATUS=not_checked
  CONTROLLER_LANDING_ONBOARDING_LAST_SINGBOX_STATUS=not_checked
}

controller_landing_onboarding_capture_readiness_result() {
  # 这些脱敏结果由后续交互层在统一入口返回后读取。
  # shellcheck disable=SC2034
  CONTROLLER_LANDING_ONBOARDING_LAST_READINESS_STAGE="$CONTROLLER_LANDING_READINESS_LAST_STAGE"
  CONTROLLER_LANDING_ONBOARDING_LAST_DEPENDENCY_STATUS="$CONTROLLER_LANDING_READINESS_LAST_DEPENDENCY_STATUS"
  CONTROLLER_LANDING_ONBOARDING_LAST_SINGBOX_STATUS="$CONTROLLER_LANDING_READINESS_LAST_SINGBOX_STATUS"
}

controller_landing_onboarding_clear_fingerprint_results() {
  # 完整主机指纹只在当前调用栈内传递，不作为统一入口的普通结果保留。
  # shellcheck disable=SC2034
  CONTROLLER_LANDING_READINESS_LAST_FINGERPRINT=""
  CONTROLLER_LANDING_ONBOARDING_LAST_FINGERPRINT=""
}

controller_landing_onboarding_inputs_are_valid() {
  [[ $# -eq 7 ]] || return 64
  local landing_id="$1" display_name="$2" address="$3" ssh_port="$4"
  local gateway_port="$5" server_name="$6" allowed_entry_ipv4="$7"
  landing_id_is_valid "$landing_id" || return 1
  controller_landing_display_name_is_valid "$display_name" || return 1
  controller_landing_address_is_valid "$address" || return 1
  landing_port_is_valid "$ssh_port" || return 1
  landing_port_is_valid "$gateway_port" || return 1
  ((10#$ssh_port != 10#$gateway_port)) || return 1
  controller_dns_name_is_valid "$server_name" || return 1
  is_public_ipv4 "$allowed_entry_ipv4"
}

controller_landing_onboarding_preflight() {
  [[ $# -eq 7 ]] || return 64
  local landing_id="$1" display_name="$2" address="$3" ssh_port="$4"
  local gateway_port="$5" server_name="$6" allowed_entry_ipv4="$7"
  controller_landing_onboarding_inputs_are_valid "$landing_id" "$display_name" \
    "$address" "$ssh_port" "$gateway_port" "$server_name" \
    "$allowed_entry_ipv4" || return 1
  validate_controller_state_file "$CONTROLLER_STATE_FILE" || return 1
  ssh_port=$((10#$ssh_port))
  jq -e --arg landing_id "$landing_id" --arg address "$address" \
    --argjson ssh_port "$ssh_port" '
      all(.landings[];
        .id != $landing_id and
        (.address != $address or .ssh_port != $ssh_port)
      )
    ' "$CONTROLLER_STATE_FILE" >/dev/null
}

controller_landing_onboarding_credentials_exist() {
  local landing_id="$1" directory manifest
  controller_landing_credentials_final_paths "$landing_id" || return 1
  directory="$CONTROLLER_LANDING_CREDENTIAL_DIRECTORY"
  manifest="$CONTROLLER_LANDING_CREDENTIAL_MANIFEST"
  [[ -e "$directory" || -L "$directory" || -e "$manifest" || -L "$manifest" ]]
}

controller_landing_onboarding_credential_artifacts_exist() (
  local landing_id="$1"
  local -a staging=()
  controller_landing_onboarding_credentials_exist "$landing_id" && return 0
  shopt -s nullglob
  staging=("$CONTROLLER_SECRET_DIR/.landing-credentials.${landing_id}."* \
    "$CONTROLLER_SECRET_DIR/.landing-manifest.${landing_id}."*)
  ((${#staging[@]} > 0))
)

controller_landing_onboarding_registration_state() {
  [[ $# -eq 6 ]] || return 64
  local landing_id="$1" display_name="$2" address="$3" ssh_port="$4"
  local fingerprint="$5" gateway_port="$6" credential_ref
  validate_controller_state_file "$CONTROLLER_STATE_FILE" || return 2
  if ! jq -e --arg landing_id "$landing_id" \
      'any(.landings[]; .id == $landing_id)' "$CONTROLLER_STATE_FILE" >/dev/null; then
    return 1
  fi
  credential_ref="$CONTROLLER_SECRET_DIR/landing-${landing_id}.json"
  ssh_port=$((10#$ssh_port))
  gateway_port=$((10#$gateway_port))
  jq -e --arg landing_id "$landing_id" --arg display_name "$display_name" \
    --arg address "$address" --argjson ssh_port "$ssh_port" \
    --arg fingerprint "$fingerprint" --argjson gateway_port "$gateway_port" \
    --arg credential_ref "$credential_ref" '
      any(.landings[];
        .id == $landing_id and
        .display_name == $display_name and
        .address == $address and
        .ssh_port == $ssh_port and
        .ssh_host_fingerprint == $fingerprint and
        .gateway_port == $gateway_port and
        .credential_ref == $credential_ref
      )
    ' "$CONTROLLER_STATE_FILE" >/dev/null || return 2
}

controller_confirm_landing_fingerprint() {
  [[ $# -eq 3 ]] || return 64
  local address="$1" ssh_port="$2" fingerprint="$3" choice
  printf '\n即将连接的落地机：%s:%s\n' "$address" "$ssh_port"
  printf 'Ed25519 主机指纹：%s\n' "$fingerprint"
  printf '请通过服务商控制台或可信渠道核对该指纹。\n'
  read_menu_choice '确认指纹完全一致并继续？[y/N]：' 'y,Y,n,N' N \
    '请输入 y、n 或直接回车' || return 1
  choice="$PROMPT_VALUE"
  case "$choice" in
    y|Y) return 0 ;;
    *) return 2 ;;
  esac
}

controller_landing_onboarding_cleanup_credentials() {
  local landing_id="$1" server_name="$2" credentials_preexisting="$3"
  if [[ "$credentials_preexisting" == true ]]; then
    CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_preexisting
    return 0
  fi
  if ! controller_landing_onboarding_credential_artifacts_exist "$landing_id"; then
    CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=not_created
    return 0
  fi
  if controller_remove_unregistered_landing_credentials "$landing_id" "$server_name"; then
    CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=removed
    return 0
  fi
  CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=cleanup_failed
  return 1
}

controller_landing_onboarding_finalize_local_cleanup() {
  [[ $# -eq 6 ]] || return 64
  local operation_id="$1" landing_id="$2" server_name="$3"
  local credentials_preexisting="$4" success_stage="$5" failure_stage="$6"
  if ! controller_landing_onboarding_cleanup_credentials "$landing_id" "$server_name" \
      "$credentials_preexisting"; then
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE="$failure_stage"
    return 1
  fi
  if ! controller_landing_onboarding_clear_journal "$operation_id"; then
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE="$failure_stage"
    return 1
  fi
  CONTROLLER_LANDING_ONBOARDING_LAST_STAGE="$success_stage"
}

controller_landing_onboarding_apply_and_complete() {
  [[ $# -eq 12 ]] || return 64
  local operation_id="$1" bootstrap_id="$2" landing_id="$3" display_name="$4"
  local address="$5" ssh_port="$6" gateway_port="$7" server_name="$8"
  local allowed_entry_ipv4="$9" fingerprint="${10}"
  local credentials_preexisting="${11}" apply_stage="${12}"
  CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=registered
  if ! controller_apply_landing "$landing_id" "$allowed_entry_ipv4"; then
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=registered_sync_pending
    return 1
  fi
  if ! controller_landing_onboarding_write_journal completed "$operation_id" \
      "$bootstrap_id" "$landing_id" "$display_name" "$address" "$ssh_port" \
      "$gateway_port" "$server_name" "$allowed_entry_ipv4" "$fingerprint" \
      "$credentials_preexisting"; then
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=completed_recovery_required
    return 1
  fi
  if ! controller_landing_onboarding_clear_journal "$operation_id"; then
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=completed_recovery_required
    return 1
  fi
  CONTROLLER_LANDING_ONBOARDING_LAST_STAGE="$apply_stage"
}

controller_onboard_landing_unlocked() {
  [[ $# -eq 7 || $# -eq 8 ]] || return 64
  local landing_id="$1" display_name="$2" address="$3" ssh_port="$4"
  local gateway_port="$5" server_name="$6" allowed_entry_ipv4="$7"
  local confirmed_fingerprint="${8:-}" fingerprint confirmation_rc
  local credentials_preexisting=false bootstrap_id=""
  local operation_id="" registration_state bootstrap_rc

  if ! controller_landing_onboarding_preflight "$landing_id" "$display_name" \
      "$address" "$ssh_port" "$gateway_port" "$server_name" \
      "$allowed_entry_ipv4"; then
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=preflight_failed
    return 1
  fi
  if [[ -e "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE" ||
        -L "$CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE" ]]; then
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=pending_recovery
    return 1
  fi
  if ! controller_landing_onboarding_remove_next_file; then
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=journal_invalid
    return 1
  fi

  if [[ -n "$confirmed_fingerprint" ]]; then
    if [[ ! "$confirmed_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]]; then
      CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=readiness_result_invalid
      return 1
    fi
    fingerprint="$confirmed_fingerprint"
  else
    if ! fingerprint="$(controller_landing_discover_fingerprint "$address" "$ssh_port")"; then
      CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=fingerprint_discovery_failed
      return 1
    fi
    [[ "$fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || {
      CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=fingerprint_discovery_failed
      return 1
    }
    CONTROLLER_LANDING_ONBOARDING_LAST_FINGERPRINT="$fingerprint"
    if controller_confirm_landing_fingerprint "$address" "$ssh_port" "$fingerprint"; then
      confirmation_rc=0
    else
      confirmation_rc=$?
    fi
    if ((confirmation_rc != 0)); then
      if ((confirmation_rc == 2)); then
        CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=cancelled
        return 2
      fi
      CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=fingerprint_confirmation_failed
      return 1
    fi
  fi
  CONTROLLER_LANDING_ONBOARDING_LAST_FINGERPRINT="$fingerprint"

  if controller_landing_onboarding_credentials_exist "$landing_id"; then
    credentials_preexisting=true
  fi
  operation_id="$(controller_landing_onboarding_generate_id operation)" || {
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=journal_unavailable
    return 1
  }
  bootstrap_id="$(controller_landing_onboarding_generate_id bootstrap)" || {
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=journal_unavailable
    return 1
  }
  if ! controller_landing_onboarding_write_journal credentials_pending "$operation_id" \
      "$bootstrap_id" "$landing_id" "$display_name" "$address" "$ssh_port" \
      "$gateway_port" "$server_name" "$allowed_entry_ipv4" "$fingerprint" \
      "$credentials_preexisting"; then
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=journal_unavailable
    return 1
  fi
  if ! controller_initialize_landing_credentials "$landing_id" "$server_name" \
      >/dev/null; then
    if ! controller_landing_onboarding_write_journal local_aborted "$operation_id" \
        "$bootstrap_id" "$landing_id" "$display_name" "$address" "$ssh_port" \
        "$gateway_port" "$server_name" "$allowed_entry_ipv4" "$fingerprint" \
        "$credentials_preexisting"; then
      CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_for_recovery
      CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=credentials_failed_recovery_required
      return 1
    fi
    controller_landing_onboarding_finalize_local_cleanup "$operation_id" "$landing_id" \
      "$server_name" "$credentials_preexisting" credentials_failed \
      credentials_failed_recovery_required || return 1
    return 1
  fi
  if [[ "$credentials_preexisting" == true ]]; then
    CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_preexisting
  else
    CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=created
  fi

  if ! controller_landing_onboarding_write_journal bootstrap_pending "$operation_id" \
      "$bootstrap_id" "$landing_id" "$display_name" "$address" "$ssh_port" \
      "$gateway_port" "$server_name" "$allowed_entry_ipv4" "$fingerprint" \
      "$credentials_preexisting"; then
    if controller_landing_onboarding_write_journal local_aborted "$operation_id" \
        "$bootstrap_id" "$landing_id" "$display_name" "$address" "$ssh_port" \
        "$gateway_port" "$server_name" "$allowed_entry_ipv4" "$fingerprint" \
        "$credentials_preexisting"; then
      controller_landing_onboarding_finalize_local_cleanup "$operation_id" "$landing_id" \
        "$server_name" "$credentials_preexisting" journal_update_failed \
        journal_recovery_required || return 1
    else
      CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_for_recovery
      CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=journal_recovery_required
    fi
    return 1
  fi

  CONTROLLER_LANDING_BOOTSTRAP_LAST_ID=""
  CONTROLLER_LANDING_BOOTSTRAP_LAST_ROLLBACK=not_started
  if controller_bootstrap_landing_channel "$landing_id" "$address" "$ssh_port" \
      "$fingerprint" "$allowed_entry_ipv4" "$bootstrap_id"; then
    bootstrap_rc=0
  else
    bootstrap_rc=$?
  fi
  if [[ "${CONTROLLER_LANDING_BOOTSTRAP_LAST_ID:-}" != "$bootstrap_id" ]]; then
    CONTROLLER_LANDING_ONBOARDING_LAST_REMOTE_ROLLBACK=not_attempted
    CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_for_recovery
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=bootstrap_state_unknown
    return 1
  fi
  if ((bootstrap_rc != 0)); then
    if [[ "${CONTROLLER_LANDING_BOOTSTRAP_LAST_ROLLBACK:-failed}" == completed ]]; then
      CONTROLLER_LANDING_ONBOARDING_LAST_REMOTE_ROLLBACK=completed
      if ! controller_landing_onboarding_write_journal remote_rolled_back "$operation_id" \
          "$bootstrap_id" "$landing_id" "$display_name" "$address" "$ssh_port" \
          "$gateway_port" "$server_name" "$allowed_entry_ipv4" "$fingerprint" \
          "$credentials_preexisting"; then
        CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_for_recovery
        CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=bootstrap_failed_recovery_required
        return 1
      fi
      controller_landing_onboarding_finalize_local_cleanup "$operation_id" "$landing_id" \
        "$server_name" "$credentials_preexisting" bootstrap_failed_rolled_back \
        bootstrap_failed_recovery_required || return 1
    else
      CONTROLLER_LANDING_ONBOARDING_LAST_REMOTE_ROLLBACK=failed
      CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_for_recovery
      CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=bootstrap_failed_recovery_required
    fi
    return 1
  fi
  if ! controller_landing_onboarding_write_journal registration_pending "$operation_id" \
      "$bootstrap_id" "$landing_id" "$display_name" "$address" "$ssh_port" \
      "$gateway_port" "$server_name" "$allowed_entry_ipv4" "$fingerprint" \
      "$credentials_preexisting"; then
    CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_for_recovery
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=bootstrap_recovery_required
    return 1
  fi

  if controller_register_landing "$landing_id" "$display_name" "$address" \
      "$ssh_port" "$fingerprint" "$gateway_port"; then
    if controller_landing_onboarding_registration_state "$landing_id" "$display_name" \
        "$address" "$ssh_port" "$fingerprint" "$gateway_port"; then
      registration_state=registered
    else
      registration_state=unknown
    fi
  else
    if controller_landing_onboarding_registration_state "$landing_id" "$display_name" \
        "$address" "$ssh_port" "$fingerprint" "$gateway_port"; then
      registration_state=registered
    else
      case $? in
        1) registration_state=unregistered ;;
        *) registration_state=unknown ;;
      esac
    fi
  fi

  case "$registration_state" in
    registered)
      if ! controller_landing_onboarding_write_journal apply_pending "$operation_id" \
          "$bootstrap_id" "$landing_id" "$display_name" "$address" "$ssh_port" \
          "$gateway_port" "$server_name" "$allowed_entry_ipv4" "$fingerprint" \
          "$credentials_preexisting"; then
        CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=registered
        CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=registered_sync_pending
        return 1
      fi
      ;;
    unregistered)
      if controller_rollback_landing_bootstrap "$landing_id" "$address" "$ssh_port" \
          "$fingerprint" "$allowed_entry_ipv4" "$bootstrap_id"; then
        CONTROLLER_LANDING_ONBOARDING_LAST_REMOTE_ROLLBACK=completed
        if ! controller_landing_onboarding_write_journal remote_rolled_back "$operation_id" \
            "$bootstrap_id" "$landing_id" "$display_name" "$address" "$ssh_port" \
            "$gateway_port" "$server_name" "$allowed_entry_ipv4" "$fingerprint" \
            "$credentials_preexisting"; then
          CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_for_recovery
          CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=registration_failed_recovery_required
          return 1
        fi
        controller_landing_onboarding_finalize_local_cleanup "$operation_id" "$landing_id" \
          "$server_name" "$credentials_preexisting" registration_failed_rolled_back \
          registration_failed_recovery_required || return 1
      else
        CONTROLLER_LANDING_ONBOARDING_LAST_REMOTE_ROLLBACK=failed
        CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_for_recovery
        CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=registration_failed_recovery_required
      fi
      return 1
      ;;
    *)
      CONTROLLER_LANDING_ONBOARDING_LAST_REMOTE_ROLLBACK=not_attempted
      CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_for_recovery
      CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=registration_state_unknown
      return 1
      ;;
  esac

  controller_landing_onboarding_apply_and_complete "$operation_id" "$bootstrap_id" \
    "$landing_id" "$display_name" "$address" "$ssh_port" "$gateway_port" \
    "$server_name" "$allowed_entry_ipv4" "$fingerprint" "$credentials_preexisting" \
    completed
}

controller_prepare_and_onboard_landing_unlocked() {
  [[ $# -eq 7 ]] || return 64
  local landing_id="$1" display_name="$2" address="$3" ssh_port="$4"
  local gateway_port="$5" server_name="$6" allowed_entry_ipv4="$7"
  local readiness_rc fingerprint onboarding_rc

  if ! controller_landing_onboarding_preflight "$landing_id" "$display_name" \
      "$address" "$ssh_port" "$gateway_port" "$server_name" \
      "$allowed_entry_ipv4"; then
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=preflight_failed
    return 1
  fi

  if controller_prepare_landing_readiness "$address" "$ssh_port" "$landing_id"; then
    readiness_rc=0
  else
    readiness_rc=$?
  fi
  controller_landing_onboarding_capture_readiness_result
  fingerprint="$CONTROLLER_LANDING_READINESS_LAST_FINGERPRINT"
  CONTROLLER_LANDING_READINESS_LAST_FINGERPRINT=""

  if ((readiness_rc != 0)); then
    CONTROLLER_LANDING_ONBOARDING_LAST_FINGERPRINT=""
    if ((readiness_rc == 2)); then
      CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=readiness_cancelled
      return 2
    fi
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=readiness_failed
    return 1
  fi
  if [[ "$CONTROLLER_LANDING_ONBOARDING_LAST_READINESS_STAGE" != ready ||
        ! "$CONTROLLER_LANDING_ONBOARDING_LAST_DEPENDENCY_STATUS" =~ ^(ready|repaired)$ ||
        ! "$CONTROLLER_LANDING_ONBOARDING_LAST_SINGBOX_STATUS" =~ ^(ready|installed)$ ||
        ! "$fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]]; then
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=readiness_result_invalid
    CONTROLLER_LANDING_ONBOARDING_LAST_FINGERPRINT=""
    return 1
  fi

  if controller_onboard_landing_unlocked "$landing_id" "$display_name" "$address" \
      "$ssh_port" "$gateway_port" "$server_name" "$allowed_entry_ipv4" \
      "$fingerprint"; then
    onboarding_rc=0
  else
    onboarding_rc=$?
  fi
  CONTROLLER_LANDING_ONBOARDING_LAST_FINGERPRINT=""
  return "$onboarding_rc"
}

controller_recover_landing_onboarding_unlocked() {
  local journal="$CONTROLLER_LANDING_ONBOARDING_JOURNAL_FILE"
  local operation_id bootstrap_id landing_id display_name address ssh_port gateway_port
  local server_name allowed_entry_ipv4 fingerprint credentials_preexisting stage
  local registration_state registration_rc
  if [[ ! -e "$journal" && ! -L "$journal" ]]; then
    if ! controller_landing_onboarding_remove_next_file; then
      CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=journal_invalid
      return 1
    fi
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=recovery_no_pending
    return 0
  fi
  if ! controller_landing_onboarding_journal_is_trusted "$journal" ||
     ! controller_landing_onboarding_remove_next_file; then
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=journal_invalid
    return 1
  fi
  IFS=$'\t' read -r operation_id bootstrap_id landing_id display_name address \
    ssh_port gateway_port server_name allowed_entry_ipv4 fingerprint \
    credentials_preexisting stage < <(
      jq -r '[
        .operation_id, .bootstrap_id, .landing_id, .display_name, .address,
        .ssh_port, .gateway_port, .server_name, .allowed_entry_ipv4,
        .ssh_host_fingerprint, .credentials_preexisting, .stage
      ] | @tsv' "$journal"
    ) || {
      CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=journal_invalid
      return 1
    }
  # 恢复调用者在函数返回后读取该公共结果。
  # shellcheck disable=SC2034
  CONTROLLER_LANDING_ONBOARDING_LAST_FINGERPRINT="$fingerprint"
  if controller_landing_onboarding_registration_state "$landing_id" "$display_name" \
      "$address" "$ssh_port" "$fingerprint" "$gateway_port"; then
    registration_state=registered
  else
    registration_rc=$?
    case "$registration_rc" in
      1) registration_state=unregistered ;;
      *) registration_state=unknown ;;
    esac
  fi

  case "$stage" in
    credentials_pending)
      [[ "$registration_state" == unregistered ]] || {
        CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=registration_state_unknown
        return 1
      }
      if ! controller_landing_onboarding_write_journal local_aborted "$operation_id" \
          "$bootstrap_id" "$landing_id" "$display_name" "$address" "$ssh_port" \
          "$gateway_port" "$server_name" "$allowed_entry_ipv4" "$fingerprint" \
          "$credentials_preexisting"; then
        CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=journal_recovery_required
        return 1
      fi
      controller_landing_onboarding_finalize_local_cleanup "$operation_id" "$landing_id" \
        "$server_name" "$credentials_preexisting" recovery_local_cleaned \
        journal_recovery_required
      ;;
    local_aborted)
      [[ "$registration_state" == unregistered ]] || {
        CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=registration_state_unknown
        return 1
      }
      controller_landing_onboarding_finalize_local_cleanup "$operation_id" "$landing_id" \
        "$server_name" "$credentials_preexisting" recovery_local_cleaned \
        journal_recovery_required
      ;;
    bootstrap_pending)
      [[ "$registration_state" == unregistered ]] || {
        CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=registration_state_unknown
        return 1
      }
      if ! controller_rollback_landing_bootstrap "$landing_id" "$address" "$ssh_port" \
          "$fingerprint" "$allowed_entry_ipv4" "$bootstrap_id"; then
        CONTROLLER_LANDING_ONBOARDING_LAST_REMOTE_ROLLBACK=failed
        CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_for_recovery
        CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=bootstrap_failed_recovery_required
        return 1
      fi
      CONTROLLER_LANDING_ONBOARDING_LAST_REMOTE_ROLLBACK=completed
      if ! controller_landing_onboarding_write_journal remote_rolled_back "$operation_id" \
          "$bootstrap_id" "$landing_id" "$display_name" "$address" "$ssh_port" \
          "$gateway_port" "$server_name" "$allowed_entry_ipv4" "$fingerprint" \
          "$credentials_preexisting"; then
        CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_for_recovery
        CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=bootstrap_failed_recovery_required
        return 1
      fi
      controller_landing_onboarding_finalize_local_cleanup "$operation_id" "$landing_id" \
        "$server_name" "$credentials_preexisting" recovery_remote_rolled_back \
        bootstrap_failed_recovery_required
      ;;
    registration_pending)
      case "$registration_state" in
        registered)
          if ! controller_landing_onboarding_write_journal apply_pending "$operation_id" \
              "$bootstrap_id" "$landing_id" "$display_name" "$address" "$ssh_port" \
              "$gateway_port" "$server_name" "$allowed_entry_ipv4" "$fingerprint" \
              "$credentials_preexisting"; then
            CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=registered
            CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=registered_sync_pending
            return 1
          fi
          controller_landing_onboarding_apply_and_complete "$operation_id" "$bootstrap_id" \
            "$landing_id" "$display_name" "$address" "$ssh_port" "$gateway_port" \
            "$server_name" "$allowed_entry_ipv4" "$fingerprint" \
            "$credentials_preexisting" completed
          ;;
        unregistered)
          if ! controller_rollback_landing_bootstrap "$landing_id" "$address" "$ssh_port" \
              "$fingerprint" "$allowed_entry_ipv4" "$bootstrap_id"; then
            CONTROLLER_LANDING_ONBOARDING_LAST_REMOTE_ROLLBACK=failed
            CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_for_recovery
            CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=registration_failed_recovery_required
            return 1
          fi
          CONTROLLER_LANDING_ONBOARDING_LAST_REMOTE_ROLLBACK=completed
          if ! controller_landing_onboarding_write_journal remote_rolled_back \
              "$operation_id" "$bootstrap_id" "$landing_id" "$display_name" \
              "$address" "$ssh_port" "$gateway_port" "$server_name" \
              "$allowed_entry_ipv4" "$fingerprint" "$credentials_preexisting"; then
            CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_for_recovery
            CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=registration_failed_recovery_required
            return 1
          fi
          controller_landing_onboarding_finalize_local_cleanup "$operation_id" "$landing_id" \
            "$server_name" "$credentials_preexisting" recovery_remote_rolled_back \
            registration_failed_recovery_required
          ;;
        *)
          CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_for_recovery
          CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=registration_state_unknown
          return 1
          ;;
      esac
      ;;
    apply_pending)
      [[ "$registration_state" == registered ]] || {
        CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_for_recovery
        CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=registration_state_unknown
        return 1
      }
      controller_landing_onboarding_apply_and_complete "$operation_id" "$bootstrap_id" \
        "$landing_id" "$display_name" "$address" "$ssh_port" "$gateway_port" \
        "$server_name" "$allowed_entry_ipv4" "$fingerprint" \
        "$credentials_preexisting" completed
      ;;
    remote_rolled_back)
      [[ "$registration_state" == unregistered ]] || {
        CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_for_recovery
        CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=registration_state_unknown
        return 1
      }
      # 恢复调用者在函数返回后读取该公共结果。
      # shellcheck disable=SC2034
      CONTROLLER_LANDING_ONBOARDING_LAST_REMOTE_ROLLBACK=completed
      controller_landing_onboarding_finalize_local_cleanup "$operation_id" "$landing_id" \
        "$server_name" "$credentials_preexisting" recovery_remote_rolled_back \
        journal_recovery_required
      ;;
    completed)
      [[ "$registration_state" == registered ]] || {
        CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=retained_for_recovery
        CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=registration_state_unknown
        return 1
      }
      # 恢复调用者在函数返回后读取该公共结果。
      # shellcheck disable=SC2034
      CONTROLLER_LANDING_ONBOARDING_LAST_LOCAL_CREDENTIALS=registered
      if ! controller_landing_onboarding_clear_journal "$operation_id"; then
        CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=completed_recovery_required
        return 1
      fi
      CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=completed
      ;;
    *)
      CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=journal_invalid
      return 1
      ;;
  esac
}

# 结果变量是公共调用约定，由后续交互层在函数返回后读取。
# shellcheck disable=SC2034
controller_onboard_landing() {
  [[ $# -eq 7 ]] || return 64
  local rc
  controller_landing_onboarding_reset_result
  if with_controller_landing_onboarding_lock controller_onboard_landing_unlocked "$@"; then
    return 0
  else
    rc=$?
  fi
  if [[ "$CONTROLLER_LANDING_ONBOARDING_LAST_STAGE" == not_started ]]; then
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=journal_unavailable
  fi
  return "$rc"
}

# 未来交互层只调用该统一入口；完整指纹不会作为普通结果保留。
# shellcheck disable=SC2034
controller_prepare_and_onboard_landing() {
  local rc
  controller_landing_onboarding_reset_result
  controller_landing_onboarding_clear_fingerprint_results
  [[ $# -eq 7 ]] || return 64
  if with_controller_landing_onboarding_lock \
      controller_prepare_and_onboard_landing_unlocked "$@"; then
    rc=0
  else
    rc=$?
  fi
  controller_landing_onboarding_clear_fingerprint_results
  if [[ "$CONTROLLER_LANDING_ONBOARDING_LAST_STAGE" == not_started ]]; then
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=journal_unavailable
    return 1
  fi
  return "$rc"
}

# shellcheck disable=SC2034
controller_recover_landing_onboarding() {
  [[ $# -eq 0 ]] || return 64
  local rc
  controller_landing_onboarding_reset_result
  if with_controller_landing_onboarding_lock \
      controller_recover_landing_onboarding_unlocked; then
    return 0
  else
    rc=$?
  fi
  if [[ "$CONTROLLER_LANDING_ONBOARDING_LAST_STAGE" == not_started ]]; then
    CONTROLLER_LANDING_ONBOARDING_LAST_STAGE=journal_unavailable
  fi
  return "$rc"
}
