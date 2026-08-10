# ============================================================
# v5 受限落地 agent 与可回退 apply 引擎（尚未安装远程通道）
# ============================================================

LANDING_AGENT_HELPER_PATH=/usr/local/libexec/sb-user-manager-landing-apply
LANDING_SINGBOX_CONFIG_PATH=/etc/sing-box/config.json
LANDING_TLS_DIRECTORY=/etc/sing-box/landing
LANDING_CA_CERTIFICATE_PATH=/etc/sing-box/landing/gateway-ca.crt
LANDING_CERTIFICATE_PATH=/etc/sing-box/landing/gateway.crt
LANDING_PRIVATE_KEY_PATH=/etc/sing-box/landing/gateway.key
LANDING_NFTABLES_DIRECTORY=/etc/nftables.d
LANDING_NFTABLES_RULES_PATH=/etc/nftables.d/sb-user-manager-landing.nft
LANDING_SINGBOX_BINARY=/usr/local/bin/sing-box
LANDING_SINGBOX_SERVICE=sing-box
LANDING_NFTABLES_FAMILY=inet
LANDING_NFTABLES_TABLE=sb_user_manager_landing
LANDING_NFTABLES_CHAIN=ingress_guard
LANDING_AGENT_READ_TIMEOUT=15
LANDING_APPLY_TRANSACTION_SCHEMA_VERSION=1
LANDING_APPLY_TRANSACTION_DIRECTORY="${SB_LANDING_APPLY_TRANSACTION_DIRECTORY:-/var/lib/sb-user-manager/landing-apply-transaction}"
LANDING_APPLY_TRANSACTION_JOURNAL="$LANDING_APPLY_TRANSACTION_DIRECTORY/journal.json"

LANDING_ACTIVE_SNAPSHOT=""
LANDING_ACTIVE_RECEIPT_SNAPSHOT=""
LANDING_ACTIVE_TRANSACTION_ID=""
LANDING_ACTIVE_TRANSACTION_PHASE=""
LANDING_ACTIVE_WORK=""
LANDING_RESULT_STATUS=""
LANDING_RESULT_CODE=""
LANDING_RESULT_REVISION=""
LANDING_RESULT_SHA256=""
LANDING_APPLY_ERROR_CODE=""
LANDING_REQUESTED_GENERATION=""

landing_apply_expected_uid() {
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true && "$EUID" -ne 0 ]]; then
    printf '%s\n' "$EUID"
  else
    printf '0\n'
  fi
}

landing_managed_path() {
  local logical="$1"
  [[ "$logical" == /* ]] || return 1
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]]; then
    printf '%s%s' "${SB_SYSTEM_ROOT:-}" "$logical"
  else
    printf '%s' "$logical"
  fi
}

landing_directory_is_safe() {
  local path="$1" exact_mode="${2:-}" owner mode expected_owner
  [[ -d "$path" && ! -L "$path" ]] || return 1
  owner="$(manager_file_uid "$path")" || return 1
  expected_owner="$(landing_apply_expected_uid)"
  [[ "$owner" == "$expected_owner" ]] || return 1
  mode="$(manager_file_mode "$path")" || return 1
  [[ "$mode" =~ ^[0-7]{3}$ ]] || return 1
  if [[ -n "$exact_mode" ]]; then
    (( (8#$mode & 0777) == 8#$exact_mode ))
  else
    (( (8#$mode & 0700) == 0700 && (8#$mode & 0022) == 0 ))
  fi
}

landing_ensure_directory() {
  local path="$1" mode="$2"
  [[ "$path" == /* && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  if [[ -e "$path" || -L "$path" ]]; then
    [[ -d "$path" && ! -L "$path" ]] || return 1
    chmod "$mode" "$path" || return 1
  else
    install -d -m "$mode" -- "$path" || return 1
  fi
  landing_directory_is_safe "$path" "${mode#0}"
}

landing_ensure_system_directory() {
  local path="$1"
  [[ "$path" == /* ]] || return 1
  if [[ -e "$path" || -L "$path" ]]; then
    landing_directory_is_safe "$path"
    return
  fi
  install -d -m 755 -- "$path" || return 1
  landing_directory_is_safe "$path"
}

landing_managed_file_is_safe() {
  local path="$1" owner mode expected_owner
  [[ -f "$path" && ! -L "$path" ]] || return 1
  owner="$(manager_file_uid "$path")" || return 1
  expected_owner="$(landing_apply_expected_uid)"
  [[ "$owner" == "$expected_owner" ]] || return 1
  mode="$(manager_file_mode "$path")" || return 1
  [[ "$mode" =~ ^[0-7]{3}$ ]] || return 1
  (( 8#$mode == 0600 ))
}

landing_managed_target_is_safe() {
  local target="$1" parent
  [[ "$target" == /* ]] || return 1
  parent="$(dirname -- "$target")" || return 1
  landing_directory_is_safe "$parent" || return 1
  if [[ -e "$target" || -L "$target" ]]; then
    landing_managed_file_is_safe "$target"
  fi
}

landing_apply_runtime_paths_are_safe() {
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    [[ "$LANDING_RECEIPT_FILE" == /var/lib/sb-user-manager/landing-receipt.json &&
       "$LANDING_RECEIPT_LOCK_FILE" == /run/lock/sb-user-manager/landing-receipt.lock &&
       "$LANDING_APPLY_TRANSACTION_DIRECTORY" == /var/lib/sb-user-manager/landing-apply-transaction &&
       "$LANDING_APPLY_TRANSACTION_JOURNAL" == /var/lib/sb-user-manager/landing-apply-transaction/journal.json ]] || return 1
  fi
  [[ "$LANDING_AGENT_HELPER_PATH" == /usr/local/libexec/sb-user-manager-landing-apply &&
     "$LANDING_SINGBOX_CONFIG_PATH" == /etc/sing-box/config.json &&
     "$LANDING_TLS_DIRECTORY" == /etc/sing-box/landing &&
     "$LANDING_NFTABLES_RULES_PATH" == /etc/nftables.d/sb-user-manager-landing.nft &&
     "$LANDING_SINGBOX_BINARY" == /usr/local/bin/sing-box &&
     "$LANDING_SINGBOX_SERVICE" == sing-box &&
     "$LANDING_CHANNEL_GENERATION_PATH" == /var/lib/sb-user-manager-landing/.channel-generation &&
     "$LANDING_AGENT_READ_TIMEOUT" == 15 ]]
}

landing_apply_transaction_file_is_safe() {
  local path="$1" mode
  controller_state_file_is_trusted "$path" || return 1
  # BSD `stat -f %Lp` 会隐藏 setuid/setgid/sticky 位；这里必须读取完整权限。
  mode="$(stat -c '%a' -- "$path" 2>/dev/null || stat -f '%Mp%Lp' "$path" 2>/dev/null)" || return 1
  [[ "$mode" == 600 || "$mode" == 0600 ]]
}

landing_apply_transaction_layout_is_safe() (
  local directory="$LANDING_APPLY_TRANSACTION_DIRECTORY" parent entry name
  local -a entries
  parent="$(dirname -- "$directory")" || return 1
  controller_private_directory_is_trusted "$parent" || return 1
  landing_directory_is_safe "$directory" 700 || return 1
  shopt -s dotglob nullglob
  entries=("$directory"/* "")
  for entry in "${entries[@]}"; do
    [[ -n "$entry" ]] || continue
    name="${entry##*/}"
    case "$name" in
      snapshot|receipt-snapshot|.validation)
        landing_directory_is_safe "$entry" 700 || return 1
        ;;
      transaction.id|apply.json|gateway-ca.crt|gateway.crt|gateway.key|check-config.json|config.json|landing.nft|nft.rollback|\
      receipt.base.json|receipt.next.json|manifest.sha256|journal.json|.journal.next|.cleanup.next|\
      mutation.started|cleanup.started|runtime.drift|service.restart-attempted|\
      nft.apply-attempted|nft.rollback-attempted)
        landing_apply_transaction_file_is_safe "$entry" || return 1
        ;;
      *) return 1 ;;
    esac
  done

  if [[ -d "$directory/snapshot" && ! -L "$directory/snapshot" ]]; then
    entries=("$directory/snapshot"/* "")
    for entry in "${entries[@]}"; do
      [[ -n "$entry" ]] || continue
      name="${entry##*/}"
      case "$name" in
        config.json|config.json.state|gateway-ca.crt|gateway-ca.crt.state|\
        gateway.crt|gateway.crt.state|gateway.key|gateway.key.state|\
        landing.nft|landing.nft.state|nft-live|nft-live.state|service.state|directories.json)
          landing_apply_transaction_file_is_safe "$entry" || return 1
          ;;
        *) return 1 ;;
      esac
    done
  fi
  if [[ -d "$directory/receipt-snapshot" && ! -L "$directory/receipt-snapshot" ]]; then
    entries=("$directory/receipt-snapshot"/* "")
    for entry in "${entries[@]}"; do
      [[ -n "$entry" ]] || continue
      name="${entry##*/}"
      case "$name" in
        receipt.json|receipt.state)
          landing_apply_transaction_file_is_safe "$entry" || return 1
          ;;
        *) return 1 ;;
      esac
    done
  fi
  if [[ -d "$directory/.validation" && ! -L "$directory/.validation" ]]; then
    entries=("$directory/.validation"/* "")
    for entry in "${entries[@]}"; do
      [[ -n "$entry" ]] || continue
      name="${entry##*/}"
      case "$name" in
        ca.crt|gateway.crt|gateway.key)
          landing_apply_transaction_file_is_safe "$entry" || return 1
          ;;
        *) return 1 ;;
      esac
    done
  fi
)

landing_apply_remove_validation_directory() {
  local path="$LANDING_APPLY_TRANSACTION_DIRECTORY/.validation"
  [[ ! -e "$path" && ! -L "$path" ]] && return 0
  landing_directory_is_safe "$path" 700 || return 1
  landing_apply_transaction_layout_is_safe || return 1
  rm -rf -- "$path" || return 1
  sync_transaction_path "$LANDING_APPLY_TRANSACTION_DIRECTORY"
}

landing_apply_reset_active_transaction() {
  LANDING_ACTIVE_SNAPSHOT=""
  LANDING_ACTIVE_RECEIPT_SNAPSHOT=""
  LANDING_ACTIVE_TRANSACTION_ID=""
  LANDING_ACTIVE_TRANSACTION_PHASE=""
  LANDING_ACTIVE_WORK=""
  clear_signal_rollback
}

landing_apply_discard_transaction_directory() {
  local directory="$LANDING_APPLY_TRANSACTION_DIRECTORY" parent
  [[ ! -e "$directory" && ! -L "$directory" ]] && return 0
  landing_apply_transaction_layout_is_safe || return 1
  [[ ! -e "$LANDING_APPLY_TRANSACTION_JOURNAL" && ! -L "$LANDING_APPLY_TRANSACTION_JOURNAL" ]] || return 1
  if [[ -e "$directory/cleanup.started" || -L "$directory/cleanup.started" ]]; then
    landing_apply_cleanup_marker_without_journal_is_valid || return 1
  else
    [[ ! -e "$directory/mutation.started" && ! -L "$directory/mutation.started" &&
       ! -e "$directory/runtime.drift" && ! -L "$directory/runtime.drift" &&
       ! -e "$directory/service.restart-attempted" && ! -L "$directory/service.restart-attempted" &&
       ! -e "$directory/nft.apply-attempted" && ! -L "$directory/nft.apply-attempted" &&
       ! -e "$directory/nft.rollback-attempted" && ! -L "$directory/nft.rollback-attempted" ]] || return 1
  fi
  parent="$(dirname -- "$directory")" || return 1
  rm -rf -- "$directory" || return 1
  sync_transaction_path "$parent"
}

landing_apply_cleanup_terminal_transaction() {
  local context="${1:-runtime}" directory="$LANDING_APPLY_TRANSACTION_DIRECTORY" parent name phase
  landing_apply_transaction_layout_is_safe || return 1
  landing_apply_load_pending_transaction || return 1
  phase="$LANDING_ACTIVE_TRANSACTION_PHASE"
  [[ "$phase" == committed || "$phase" == rolled_back ]] || return 1
  landing_apply_terminal_receipt_is_valid "$phase" "$context" || return 1
  landing_apply_mark_cleanup_started || return 1
  rm -f -- "$LANDING_APPLY_TRANSACTION_JOURNAL" || return 1
  sync_transaction_path "$directory" || return 1
  for name in .validation snapshot receipt-snapshot; do
    [[ ! -e "$directory/$name" && ! -L "$directory/$name" ]] ||
      rm -rf -- "${directory:?}/$name" || return 1
  done
  for name in apply.json gateway-ca.crt gateway.crt gateway.key check-config.json config.json \
    landing.nft nft.rollback receipt.base.json receipt.next.json manifest.sha256 .journal.next \
    .cleanup.next mutation.started runtime.drift service.restart-attempted \
    nft.apply-attempted nft.rollback-attempted; do
    [[ ! -e "$directory/$name" && ! -L "$directory/$name" ]] ||
      rm -f -- "$directory/$name" || return 1
  done
  sync_transaction_path "$directory" || return 1
  rm -f -- "$directory/cleanup.started" || return 1
  sync_transaction_path "$directory" || return 1
  rm -f -- "$directory/transaction.id" || return 1
  sync_transaction_path "$directory" || return 1
  parent="$(dirname -- "$directory")" || return 1
  rmdir -- "$directory" || return 1
  sync_transaction_path "$parent" || return 1
  landing_apply_reset_active_transaction
}

landing_apply_begin_staging() {
  local directory="$LANDING_APPLY_TRANSACTION_DIRECTORY" parent transaction_id
  [[ ! -e "$directory" && ! -L "$directory" ]] || return 1
  parent="$(dirname -- "$directory")" || return 1
  ensure_controller_private_directory "$parent" || return 1
  transaction_id="$(python3 -I -c 'import secrets; print(secrets.token_hex(16))')" || return 1
  [[ "$transaction_id" =~ ^[0-9a-f]{32}$ ]] || return 1
  install -d -m 700 -- "$directory" || return 1
  landing_directory_is_safe "$directory" 700 || return 1
  if ! sync_transaction_path "$directory" || ! sync_transaction_path "$parent"; then
    landing_apply_discard_transaction_directory || true
    return 1
  fi
  printf '%s\n' "$transaction_id" > "$directory/transaction.id" || {
    landing_apply_discard_transaction_directory || true
    return 1
  }
  chmod 600 "$directory/transaction.id" || {
    landing_apply_discard_transaction_directory || true
    return 1
  }
  sync_transaction_path "$directory/transaction.id" || {
    landing_apply_discard_transaction_directory || true
    return 1
  }
  sync_transaction_path "$directory" || {
    landing_apply_discard_transaction_directory || true
    return 1
  }
  LANDING_ACTIVE_TRANSACTION_ID="$transaction_id"
  LANDING_ACTIVE_TRANSACTION_PHASE=staging
  LANDING_ACTIVE_WORK="$directory"
  set_signal_rollback landing_apply_signal_rollback || {
    landing_apply_reset_active_transaction
    landing_apply_discard_transaction_directory || true
    return 1
  }
}

landing_set_error_result() {
  local code="$1"
  [[ "$code" =~ ^[a-z][a-z0-9_]{0,47}$ ]] || code=internal_error
  LANDING_RESULT_STATUS=error
  LANDING_RESULT_CODE="$code"
  LANDING_RESULT_REVISION=""
  LANDING_RESULT_SHA256=""
}

landing_set_success_result() {
  local status="$1" revision="$2" sha256="$3"
  [[ "$status" == applied || "$status" == idempotent ]] || return 1
  landing_safe_integer_is_valid "$revision" || return 1
  [[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
  LANDING_RESULT_STATUS="$status"
  LANDING_RESULT_CODE=""
  LANDING_RESULT_REVISION="$revision"
  LANDING_RESULT_SHA256="$sha256"
}

landing_emit_current_result() {
  case "$LANDING_RESULT_STATUS" in
    applied|idempotent)
      printf '{"status":"%s","revision":%s,"content_sha256":"%s"}\n' \
        "$LANDING_RESULT_STATUS" "$LANDING_RESULT_REVISION" "$LANDING_RESULT_SHA256" || return 1
      ;;
    error)
      printf '{"status":"error","code":"%s"}\n' "$LANDING_RESULT_CODE" || return 1
      ;;
    *)
      printf '{"status":"error","code":"internal_error"}\n'
      return 1
      ;;
  esac
}

landing_agent_response_is_safe() {
  local response="$1"
  ((${#response} >= 1 && ${#response} <= 512)) || return 1
  printf '%s\n' "$response" | jq -e -s '
    length == 1 and
    (.[0] | type == "object") and
    (if .[0].status == "error" then
       (.[0] | keys | sort) == ["code", "status"] and
       (.[0].code | type == "string" and test("^[a-z][a-z0-9_]{0,47}$"))
     else
       (.[0].status == "applied" or .[0].status == "idempotent") and
       (.[0] | keys | sort) == ["content_sha256", "revision", "status"] and
       (.[0].revision | type == "number" and . == floor and . >= 1 and
         . <= 9007199254740991) and
       (.[0].content_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
     end)
  ' >/dev/null
}

landing_agent_response_matches_exit() {
  local response="$1" rc="$2" response_status
  [[ "$rc" =~ ^[0-9]+$ ]] || return 1
  landing_agent_response_is_safe "$response" || return 1
  response_status="$(printf '%s\n' "$response" | jq -r '.status')" || return 1
  if [[ "$rc" == 0 ]]; then
    [[ "$response_status" == applied || "$response_status" == idempotent ]]
  else
    [[ "$response_status" == error ]]
  fi
}

landing_agent_handoff() {
  local generation="${1:-}" response rc=0
  if [[ -n "$generation" && ! "$generation" =~ ^[0-9a-f]{64}$ ]]; then
    landing_set_error_result handoff_failed
    landing_emit_current_result
    return 1
  fi
  if [[ -n "$generation" ]]; then
    response="$(/usr/bin/sudo -n -- /usr/local/libexec/sb-user-manager-landing-apply \
      "$generation" 2>/dev/null)" || rc=$?
  else
    response="$(/usr/bin/sudo -n -- /usr/local/libexec/sb-user-manager-landing-apply 2>/dev/null)" || rc=$?
  fi
  if landing_agent_response_matches_exit "$response" "$rc"; then
    printf '%s\n' "$response" || return 1
    return "$rc"
  fi
  landing_set_error_result handoff_failed
  landing_emit_current_result
  return 1
}

landing_agent_generation_is_current() {
  local generation="$1" path uid gid mode expected_gid actual
  [[ "$generation" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$LANDING_CHANNEL_GENERATION_PATH" == /var/lib/sb-user-manager-landing/.channel-generation ]] || return 1
  path="$LANDING_CHANNEL_GENERATION_PATH"
  [[ -f "$path" && ! -L "$path" && -r "$path" ]] || return 1
  uid="$(manager_file_uid "$path")" || return 1
  gid="$(manager_file_gid "$path")" || return 1
  mode="$(manager_file_mode "$path")" || return 1
  expected_gid="$(id -g)" || return 1
  [[ "$uid" == 0 && "$gid" == "$expected_gid" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 07777) == 0440 )) || return 1
  actual="$(<"$path")" || return 1
  [[ "$actual" == "$generation" ]]
}

landing_agent_main() {
  local generation="${1:-}"
  if [[ -n "${SSH_ORIGINAL_COMMAND:-}" || -n "${SSH_TTY:-}" ||
        -z "${SSH_CONNECTION:-}" ]] ||
     { [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]] && [[ $# -ne 0 ]]; } ||
     { [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]] &&
       { [[ $# -ne 1 ]] || ! landing_agent_generation_is_current "$generation"; }; }; then
    landing_set_error_result restricted_channel_rejected
    landing_emit_current_result
    return 64
  fi
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]]; then
    landing_agent_handoff
  else
    landing_agent_handoff "$generation"
  fi
}

landing_apply_handle_signal() {
  local code="$1" callback="$ACTIVE_SIGNAL_ROLLBACK"
  trap '' HUP INT QUIT TERM
  ACTIVE_SIGNAL_ROLLBACK=""
  if [[ -n "$callback" ]]; then "$callback" "$code" || true; fi
  cleanup_runtime_temp_paths || true
  exit "$code"
}

install_landing_apply_runtime_traps() {
  RUNTIME_TRAP_PID="${BASHPID:-$$}"
  RUNTIME_TRAP_SUBSHELL="$BASH_SUBSHELL"
  trap runtime_exit_cleanup EXIT
  trap 'landing_apply_handle_signal 129' HUP
  trap 'landing_apply_handle_signal 130' INT
  trap 'landing_apply_handle_signal 131' QUIT
  trap 'landing_apply_handle_signal 143' TERM
}

landing_apply_read_stdin() {
  local package="$1" byte_count
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]]; then
    head -c "$((LANDING_APPLY_MAX_BYTES + 1))" > "$package" || return 1
  else
    /usr/bin/timeout --signal=TERM --kill-after=2 "$LANDING_AGENT_READ_TIMEOUT" \
      /usr/bin/head -c "$((LANDING_APPLY_MAX_BYTES + 1))" > "$package" || return 1
  fi
  chmod 600 "$package" || return 1
  byte_count="$(wc -c < "$package" | tr -d ' ')" || return 1
  [[ "$byte_count" =~ ^[0-9]+$ ]] || return 1
  ((byte_count >= 1 && byte_count <= LANDING_APPLY_MAX_BYTES)) || return 1
  controller_state_file_is_trusted "$package"
}

landing_prepare_runtime_directories() {
  local system_etc config_parent nft_parent tls_dir
  system_etc="$(landing_managed_path /etc)" || return 1
  config_parent="$(landing_managed_path "$(dirname "$LANDING_SINGBOX_CONFIG_PATH")")" || return 1
  nft_parent="$(landing_managed_path "$LANDING_NFTABLES_DIRECTORY")" || return 1
  tls_dir="$(landing_managed_path "$LANDING_TLS_DIRECTORY")" || return 1
  landing_ensure_system_directory "$system_etc" || return 1
  sync_transaction_path "$system_etc" || return 1
  landing_ensure_system_directory "$config_parent" || return 1
  sync_transaction_path "$config_parent" || return 1
  sync_transaction_path "$system_etc" || return 1
  landing_ensure_system_directory "$nft_parent" || return 1
  sync_transaction_path "$nft_parent" || return 1
  sync_transaction_path "$system_etc" || return 1
  landing_ensure_directory "$tls_dir" 700 || return 1
  sync_transaction_path "$tls_dir" || return 1
  sync_transaction_path "$config_parent"
}

landing_render_singbox_config() {
  local package="$1" certificate_path="$2" private_key_path="$3" output="$4"
  SB_LANDING_RENDER_CERTIFICATE_PATH="$certificate_path" \
  SB_LANDING_RENDER_PRIVATE_KEY_PATH="$private_key_path" \
    jq -e '
      {
        log: {level:"warn", timestamp:true},
        inbounds: [{
          type:"anytls",
          tag:"landing-gateway",
          listen:"0.0.0.0",
          listen_port:.gateway.listen_port,
          users:[{name:"entry-controller", password:.gateway.password}],
          tls:{
            enabled:true,
            certificate_path:$ENV.SB_LANDING_RENDER_CERTIFICATE_PATH,
            key_path:$ENV.SB_LANDING_RENDER_PRIVATE_KEY_PATH
          }
        }],
        outbounds:[{type:"direct", tag:"direct"}],
        route:{final:"direct"}
      }
    ' "$package" > "$output" || return 1
  chmod 600 "$output" || return 1
}

landing_render_nftables_rules() {
  local package="$1" output="$2"
  jq -er --arg family "$LANDING_NFTABLES_FAMILY" \
    --arg table "$LANDING_NFTABLES_TABLE" --arg chain "$LANDING_NFTABLES_CHAIN" '
      "add table " + $family + " " + $table + "\n" +
      "flush table " + $family + " " + $table + "\n" +
      "add chain " + $family + " " + $table + " " + $chain +
        " { type filter hook input priority -10; policy accept; }\n" +
      "add rule " + $family + " " + $table + " " + $chain +
        " ip saddr " + .gateway.allowed_entry_ipv4 +
        " tcp dport " + (.gateway.listen_port | tostring) + " accept\n" +
      "add rule " + $family + " " + $table + " " + $chain +
        " tcp dport " + (.gateway.listen_port | tostring) + " drop\n"
    ' "$package" > "$output" || return 1
  chmod 600 "$output" || return 1
}

landing_render_candidates() {
  local package="$1" work="$2" final_certificate final_private_key
  final_certificate="$LANDING_CERTIFICATE_PATH"
  final_private_key="$LANDING_PRIVATE_KEY_PATH"
  jq -er '.gateway.ca_certificate_pem' "$package" > "$work/gateway-ca.crt" || return 1
  jq -er '.gateway.certificate_pem' "$package" > "$work/gateway.crt" || return 1
  jq -er '.gateway.private_key_pem' "$package" > "$work/gateway.key" || return 1
  chmod 600 "$work/gateway-ca.crt" "$work/gateway.crt" "$work/gateway.key" || return 1
  landing_render_singbox_config "$package" "$work/gateway.crt" "$work/gateway.key" \
    "$work/check-config.json" || return 1
  landing_render_singbox_config "$package" "$final_certificate" "$final_private_key" \
    "$work/config.json" || return 1
  landing_render_nftables_rules "$package" "$work/landing.nft"
}

landing_validate_candidates() {
  local work="$1" singbox_binary
  singbox_binary="$(landing_managed_path "$LANDING_SINGBOX_BINARY")" || return 1
  [[ -x "$singbox_binary" && ! -L "$singbox_binary" ]] || return 1
  "$singbox_binary" check -c "$work/check-config.json" >/dev/null 2>&1 || return 1
  nft -c -f "$work/landing.nft" >/dev/null 2>&1 || return 1
}

landing_snapshot_file() {
  local snapshot="$1" label="$2" target="$3" marker
  marker="$snapshot/${label}.state"
  if [[ -e "$target" || -L "$target" ]]; then
    landing_managed_file_is_safe "$target" || return 1
    install -m 600 -- "$target" "$snapshot/$label" || return 1
    printf 'exists\n' > "$marker" || return 1
  else
    : > "$snapshot/$label" || return 1
    printf 'missing\n' > "$marker" || return 1
  fi
  chmod 600 "$snapshot/$label" "$marker" || return 1
  sync_transaction_path "$snapshot/$label" || return 1
  sync_transaction_path "$marker"
}

landing_snapshot_runtime_directories() {
  local snapshot="$1" system_etc config_parent nft_parent tls_dir output directory_state
  local etc_state etc_mode config_state config_mode nft_state nft_mode tls_state tls_mode
  system_etc="$(landing_managed_path /etc)" || return 1
  config_parent="$(landing_managed_path "$(dirname "$LANDING_SINGBOX_CONFIG_PATH")")" || return 1
  nft_parent="$(landing_managed_path "$LANDING_NFTABLES_DIRECTORY")" || return 1
  tls_dir="$(landing_managed_path "$LANDING_TLS_DIRECTORY")" || return 1
  directory_state="$(landing_snapshot_directory_state "$system_etc")" || return 1
  IFS=$'\t' read -r _ etc_state etc_mode <<< "$directory_state" || return 1
  directory_state="$(landing_snapshot_directory_state "$config_parent")" || return 1
  IFS=$'\t' read -r _ config_state config_mode <<< "$directory_state" || return 1
  directory_state="$(landing_snapshot_directory_state "$nft_parent")" || return 1
  IFS=$'\t' read -r _ nft_state nft_mode <<< "$directory_state" || return 1
  directory_state="$(landing_snapshot_directory_state "$tls_dir")" || return 1
  IFS=$'\t' read -r _ tls_state tls_mode <<< "$directory_state" || return 1
  output="$snapshot/directories.json"
  jq -n \
    --arg etc_state "$etc_state" --arg etc_mode "$etc_mode" \
    --arg config_state "$config_state" --arg config_mode "$config_mode" \
    --arg nft_state "$nft_state" --arg nft_mode "$nft_mode" \
    --arg tls_state "$tls_state" --arg tls_mode "$tls_mode" '
      {
        schema_version:1,
        etc:{state:$etc_state,mode:(if $etc_state == "exists" then $etc_mode else null end)},
        config_parent:{state:$config_state,mode:(if $config_state == "exists" then $config_mode else null end)},
        nft_parent:{state:$nft_state,mode:(if $nft_state == "exists" then $nft_mode else null end)},
        tls:{state:$tls_state,mode:(if $tls_state == "exists" then $tls_mode else null end)}
      }
    ' > "$output" || return 1
  chmod 600 "$output" || return 1
  sync_transaction_path "$output"
}

landing_snapshot_directory_state() {
  local path="$1" mode
  if [[ -e "$path" || -L "$path" ]]; then
    landing_directory_is_safe "$path" || return 1
    mode="$(manager_file_mode "$path")" || return 1
    [[ "$mode" =~ ^[0-7]{3}$ ]] || return 1
    printf 'directory\texists\t%s\n' "$mode"
  else
    printf 'directory\tmissing\t-\n'
  fi
}

landing_restore_runtime_directory() {
  local path="$1" state="$2" mode="$3" parent
  case "$state" in
    exists)
      landing_directory_is_safe "$path" || return 1
      [[ "$mode" =~ ^[0-7]{3}$ ]] || return 1
      chmod "$mode" "$path" || return 1
      landing_directory_is_safe "$path" "$mode" || return 1
      sync_transaction_path "$path" || return 1
      ;;
    missing)
      parent="$(dirname -- "$path")" || return 1
      [[ "$mode" == null ]] || return 1
      if [[ -e "$path" || -L "$path" ]]; then
        landing_directory_is_safe "$path" || return 1
        rmdir -- "$path" || return 1
      fi
      if [[ -e "$parent" || -L "$parent" ]]; then
        landing_directory_is_safe "$parent" || return 1
        sync_transaction_path "$parent" || return 1
      else
        [[ ! -L "$parent" ]] || return 1
      fi
      ;;
    *) return 1 ;;
  esac
}

landing_restore_runtime_directories() {
  local snapshot="$1" states system_etc config_parent nft_parent tls_dir state mode
  states="$snapshot/directories.json"
  landing_apply_transaction_file_is_safe "$states" || return 1
  system_etc="$(landing_managed_path /etc)" || return 1
  config_parent="$(landing_managed_path "$(dirname "$LANDING_SINGBOX_CONFIG_PATH")")" || return 1
  nft_parent="$(landing_managed_path "$LANDING_NFTABLES_DIRECTORY")" || return 1
  tls_dir="$(landing_managed_path "$LANDING_TLS_DIRECTORY")" || return 1
  state="$(jq -r '.tls.state' "$states")" || return 1
  mode="$(jq -r '.tls.mode' "$states")" || return 1
  landing_restore_runtime_directory "$tls_dir" "$state" "$mode" || return 1
  state="$(jq -r '.config_parent.state' "$states")" || return 1
  mode="$(jq -r '.config_parent.mode' "$states")" || return 1
  landing_restore_runtime_directory "$config_parent" "$state" "$mode" || return 1
  state="$(jq -r '.nft_parent.state' "$states")" || return 1
  mode="$(jq -r '.nft_parent.mode' "$states")" || return 1
  landing_restore_runtime_directory "$nft_parent" "$state" "$mode" || return 1
  state="$(jq -r '.etc.state' "$states")" || return 1
  mode="$(jq -r '.etc.mode' "$states")" || return 1
  landing_restore_runtime_directory "$system_etc" "$state" "$mode"
}

landing_create_empty_receipt_file() {
  local landing_id="$1" receipt="$2"
  landing_id_is_valid "$landing_id" || return 1
  jq -n --argjson schema "$LANDING_RECEIPT_SCHEMA_VERSION" --arg landing_id "$landing_id" '
    {
      schema_version:$schema,
      role:"managed-landing",
      landing_id:$landing_id,
      applied_revision:0,
      content_sha256:null,
      nonce:null,
      emergency_override:false
    }
  ' > "$receipt" || return 1
  chmod 600 "$receipt" || return 1
  controller_state_file_is_trusted "$receipt" || return 1
  validate_landing_receipt_json "$receipt"
}

landing_prepare_receipt_base() {
  local package="$1" work="$2" landing_id base
  landing_id="$(jq -r '.landing_id' "$package")" || return 1
  landing_id_is_valid "$landing_id" || return 1
  base="$work/receipt.base.json"
  if [[ -e "$LANDING_RECEIPT_FILE" || -L "$LANDING_RECEIPT_FILE" ]]; then
    validate_landing_receipt_file "$LANDING_RECEIPT_FILE" || return 1
    install -m 600 -- "$LANDING_RECEIPT_FILE" "$base" || return 1
  else
    landing_create_empty_receipt_file "$landing_id" "$base" || return 1
  fi
  sync_transaction_path "$base"
}

landing_prepare_receipt_candidate() {
  local package="$1" work="$2" base candidate
  local revision sha256 nonce
  base="$work/receipt.base.json"
  candidate="$work/receipt.next.json"
  validate_landing_receipt_json "$base" || return 1
  revision="$(jq -r '.revision' "$package")" || return 1
  sha256="$(jq -r '.content_sha256' "$package")" || return 1
  nonce="$(jq -r '.nonce' "$package")" || return 1
  jq --argjson revision "$revision" --arg content_sha256 "$sha256" --arg nonce "$nonce" '
    .applied_revision = $revision |
    .content_sha256 = $content_sha256 |
    .nonce = $nonce
  ' "$base" > "$candidate" || return 1
  chmod 600 "$candidate" || return 1
  validate_landing_receipt_json "$candidate" || return 1
  sync_transaction_path "$candidate"
}

landing_snapshot_receipt() {
  local work="$1" snapshot
  snapshot="$work/receipt-snapshot"
  landing_ensure_directory "$snapshot" 700 || return 1
  if [[ -e "$LANDING_RECEIPT_FILE" || -L "$LANDING_RECEIPT_FILE" ]]; then
    validate_landing_receipt_file "$LANDING_RECEIPT_FILE" || return 1
    install -m 600 -- "$LANDING_RECEIPT_FILE" "$snapshot/receipt.json" || return 1
    printf 'exists\n' > "$snapshot/receipt.state" || return 1
  else
    : > "$snapshot/receipt.json" || return 1
    printf 'missing\n' > "$snapshot/receipt.state" || return 1
  fi
  chmod 600 "$snapshot/receipt.json" "$snapshot/receipt.state" || return 1
  sync_transaction_path "$snapshot/receipt.json" || return 1
  sync_transaction_path "$snapshot/receipt.state" || return 1
  sync_transaction_path "$snapshot" || return 1
  LANDING_ACTIVE_RECEIPT_SNAPSHOT="$snapshot"
}

landing_apply_nft_rollback_batch_is_valid() {
  local work="$1" batch="$1/nft.rollback" snapshot="$1/snapshot" nft_state
  local expected actual
  landing_apply_transaction_file_is_safe "$batch" || return 1
  nft_state="$(<"$snapshot/nft-live.state")" || return 1
  expected="$({
    printf 'delete table %s %s\n' "$LANDING_NFTABLES_FAMILY" "$LANDING_NFTABLES_TABLE" || exit 1
    if [[ "$nft_state" == exists ]]; then
      cat "$snapshot/nft-live" || exit 1
    elif [[ "$nft_state" != missing ]]; then
      exit 1
    fi
  } | sha256sum | awk '{print $1}')" || return 1
  actual="$(sha256sum -- "$batch" | awk '{print $1}')" || return 1
  [[ "$expected" =~ ^[0-9a-f]{64}$ && "$actual" == "$expected" ]]
}

landing_prepare_nft_rollback_batch() {
  local work="$1" batch="$1/nft.rollback" snapshot="$1/snapshot" nft_state
  [[ ! -e "$batch" && ! -L "$batch" ]] || return 1
  nft_state="$(<"$snapshot/nft-live.state")" || return 1
  {
    printf 'delete table %s %s\n' "$LANDING_NFTABLES_FAMILY" "$LANDING_NFTABLES_TABLE" || return 1
    if [[ "$nft_state" == exists ]]; then
      cat "$snapshot/nft-live" || return 1
    elif [[ "$nft_state" != missing ]]; then
      return 1
    fi
  } > "$batch" || return 1
  chmod 600 "$batch" || return 1
  landing_apply_nft_rollback_batch_is_valid "$work" || return 1
  sync_transaction_path "$batch"
}

landing_validate_nft_rollback_batch() {
  local work="$1" nft_state
  landing_apply_nft_rollback_batch_is_valid "$work" || return 1
  nft_state="$(<"$work/snapshot/nft-live.state")" || return 1
  if [[ "$nft_state" == exists ]]; then
    nft -c -f "$work/nft.rollback" >/dev/null 2>&1 || return 1
  else
    [[ "$nft_state" == missing ]] || return 1
  fi
}

landing_apply_manifest_paths() {
  printf '%s\n' \
    transaction.id apply.json gateway-ca.crt gateway.crt gateway.key check-config.json config.json \
    landing.nft nft.rollback \
    receipt.base.json receipt.next.json \
    snapshot/config.json snapshot/config.json.state \
    snapshot/gateway-ca.crt snapshot/gateway-ca.crt.state \
    snapshot/gateway.crt snapshot/gateway.crt.state \
    snapshot/gateway.key snapshot/gateway.key.state \
    snapshot/landing.nft snapshot/landing.nft.state \
    snapshot/nft-live snapshot/nft-live.state snapshot/service.state snapshot/directories.json \
    receipt-snapshot/receipt.json receipt-snapshot/receipt.state
}

landing_apply_write_manifest() {
  local work="$1" manifest relative digest
  manifest="$work/manifest.sha256"
  : > "$manifest" || return 1
  chmod 600 "$manifest" || return 1
  while IFS= read -r relative; do
    [[ -n "$relative" && -f "$work/$relative" && ! -L "$work/$relative" ]] || return 1
    sync_transaction_path "$work/$relative" || return 1
    digest="$(sha256sum -- "$work/$relative" | awk '{print $1}')" || return 1
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s  %s\n' "$digest" "$relative" >> "$manifest" || return 1
  done < <(landing_apply_manifest_paths)
  sync_transaction_path "$manifest" || return 1
  sync_transaction_path "$work/snapshot" || return 1
  sync_transaction_path "$work/receipt-snapshot" || return 1
  sync_transaction_path "$work"
}

landing_apply_manifest_is_valid() {
  local work="$1" manifest expected actual line count=0
  manifest="$work/manifest.sha256"
  [[ "$work" == "$LANDING_APPLY_TRANSACTION_DIRECTORY" ]] || return 1
  landing_apply_transaction_layout_is_safe || return 1
  landing_apply_transaction_file_is_safe "$manifest" || return 1
  expected="$(landing_apply_manifest_paths)" || return 1
  actual="$(awk '{print substr($0,67)}' "$manifest")" || return 1
  [[ "$actual" == "$expected" ]] || return 1
  while IFS= read -r line; do
    [[ "$line" =~ ^[0-9a-f]{64}\ \ [A-Za-z0-9._/-]+$ ]] || return 1
    ((count+=1))
  done < "$manifest"
  [[ "$count" == 27 ]] || return 1
  (cd "$work" && sha256sum -c manifest.sha256 >/dev/null 2>&1)
}

landing_apply_transaction_id_file_is_valid() {
  local expected="${1:-}" path="$LANDING_APPLY_TRANSACTION_DIRECTORY/transaction.id"
  local actual byte_count line_count
  landing_apply_transaction_file_is_safe "$path" || return 1
  byte_count="$(wc -c < "$path" | tr -d ' ')" || return 1
  line_count="$(wc -l < "$path" | tr -d ' ')" || return 1
  [[ "$byte_count" == 33 && "$line_count" == 1 ]] || return 1
  actual="$(<"$path")" || return 1
  [[ "$actual" =~ ^[0-9a-f]{32}$ ]] || return 1
  [[ -z "$expected" || "$actual" == "$expected" ]]
}

validate_landing_apply_transaction_journal() {
  local journal="${1:-$LANDING_APPLY_TRANSACTION_JOURNAL}" transaction_id
  landing_apply_transaction_id_file_is_valid || return 1
  transaction_id="$(<"$LANDING_APPLY_TRANSACTION_DIRECTORY/transaction.id")" || return 1
  landing_apply_transaction_file_is_safe "$journal" || return 1
  jq -e -s 'length == 1' "$journal" >/dev/null || return 1
  jq -e --argjson schema "$LANDING_APPLY_TRANSACTION_SCHEMA_VERSION" \
    --arg transaction_id "$transaction_id" '
    type == "object" and
    (keys | sort) == [
      "content_sha256", "landing_id", "phase", "revision", "role",
      "schema_version", "transaction_id"
    ] and
    .schema_version == $schema and
    .role == "landing-apply" and
    .transaction_id == $transaction_id and
    (.landing_id | type == "string" and test("^[a-z][a-z0-9-]{0,31}$")) and
    (.revision | type == "number" and . == floor and . >= 1 and . <= 9007199254740991) and
    (.content_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.phase == "active" or .phase == "committed" or .phase == "rolled_back")
  ' "$journal" >/dev/null
}

landing_apply_write_transaction_journal() {
  local phase="$1" landing_id="$2" revision="$3" sha256="$4"
  local directory="$LANDING_APPLY_TRANSACTION_DIRECTORY" tmp="$LANDING_APPLY_TRANSACTION_DIRECTORY/.journal.next"
  [[ "$phase" == active || "$phase" == committed || "$phase" == rolled_back ]] || return 1
  landing_id_is_valid "$landing_id" || return 1
  landing_safe_integer_is_valid "$revision" || return 1
  [[ "$sha256" =~ ^[0-9a-f]{64}$ && "$LANDING_ACTIVE_TRANSACTION_ID" =~ ^[0-9a-f]{32}$ ]] || return 1
  landing_apply_transaction_layout_is_safe || return 1
  landing_apply_transaction_id_file_is_valid "$LANDING_ACTIVE_TRANSACTION_ID" || return 1
  if [[ "$phase" == active ]]; then
    [[ ! -e "$LANDING_APPLY_TRANSACTION_JOURNAL" && ! -L "$LANDING_APPLY_TRANSACTION_JOURNAL" ]] || return 1
  else
    validate_landing_apply_transaction_journal || return 1
    jq -e --arg transaction_id "$LANDING_ACTIVE_TRANSACTION_ID" --arg landing_id "$landing_id" \
      --argjson revision "$revision" --arg sha256 "$sha256" '
        .phase == "active" and .transaction_id == $transaction_id and
        .landing_id == $landing_id and .revision == $revision and
        .content_sha256 == $sha256
      ' "$LANDING_APPLY_TRANSACTION_JOURNAL" >/dev/null || return 1
  fi
  [[ ! -e "$tmp" && ! -L "$tmp" ]] || return 1
  if ! jq -n --argjson schema "$LANDING_APPLY_TRANSACTION_SCHEMA_VERSION" \
      --arg transaction_id "$LANDING_ACTIVE_TRANSACTION_ID" --arg landing_id "$landing_id" \
      --argjson revision "$revision" --arg content_sha256 "$sha256" --arg phase "$phase" '
        {
          schema_version:$schema,
          role:"landing-apply",
          transaction_id:$transaction_id,
          landing_id:$landing_id,
          revision:$revision,
          content_sha256:$content_sha256,
          phase:$phase
        }
      ' > "$tmp" ||
     ! chmod 600 "$tmp" ||
     ! validate_landing_apply_transaction_journal "$tmp" ||
     ! sync_transaction_path "$tmp"; then
    rm -f -- "$tmp" || true
    return 1
  fi
  mv -- "$tmp" "$LANDING_APPLY_TRANSACTION_JOURNAL" || {
    rm -f -- "$tmp" || true
    return 1
  }
  if ! sync_transaction_path "$directory"; then
    [[ "$phase" == committed || "$phase" == rolled_back ]] && return 2
    return 1
  fi
  LANDING_ACTIVE_TRANSACTION_PHASE="$phase"
}

landing_apply_snapshot_metadata_is_valid() {
  local work="$1" snapshot receipt_snapshot
  local label state
  snapshot="$work/snapshot"
  receipt_snapshot="$work/receipt-snapshot"
  landing_directory_is_safe "$snapshot" 700 || return 1
  landing_directory_is_safe "$receipt_snapshot" 700 || return 1
  for label in config.json gateway-ca.crt gateway.crt gateway.key landing.nft; do
    state="$(<"$snapshot/${label}.state")" || return 1
    [[ "$state" == exists || "$state" == missing ]] || return 1
    [[ "$state" != missing || ! -s "$snapshot/$label" ]] || return 1
  done
  state="$(<"$snapshot/nft-live.state")" || return 1
  [[ "$state" == exists || "$state" == missing ]] || return 1
  [[ "$state" != missing || ! -s "$snapshot/nft-live" ]] || return 1
  state="$(<"$snapshot/service.state")" || return 1
  [[ "$state" == active || "$state" == inactive || "$state" == failed ]] || return 1
  state="$(<"$receipt_snapshot/receipt.state")" || return 1
  [[ "$state" == exists || "$state" == missing ]] || return 1
  if [[ "$state" == exists ]]; then
    validate_landing_receipt_json "$receipt_snapshot/receipt.json" || return 1
  else
    [[ ! -s "$receipt_snapshot/receipt.json" ]] || return 1
  fi
  jq -e '
    type == "object" and
    (keys | sort) == ["config_parent", "etc", "nft_parent", "schema_version", "tls"] and
    .schema_version == 1 and
    all([.etc,.config_parent,.nft_parent,.tls][];
      (type == "object") and (keys | sort) == ["mode","state"] and
      ((.state == "missing" and .mode == null) or
       (.state == "exists" and (.mode | type == "string" and test("^[0-7]{3}$")))))
  ' "$snapshot/directories.json" >/dev/null
}

landing_apply_transaction_payload_is_valid() {
  local work="$LANDING_ACTIVE_WORK" package landing_id revision sha256
  [[ "$work" == "$LANDING_APPLY_TRANSACTION_DIRECTORY" ]] || return 1
  landing_apply_transaction_layout_is_safe || return 1
  landing_apply_remove_validation_directory || return 1
  landing_apply_manifest_is_valid "$work" || return 1
  landing_apply_transaction_id_file_is_valid "$LANDING_ACTIVE_TRANSACTION_ID" || return 1
  landing_apply_nft_rollback_batch_is_valid "$work" || return 1
  package="$work/apply.json"
  SB_LANDING_APPLY_VALIDATION_ROOT="$work" \
    landing_apply_package_structure_is_valid "$package" historical || return 1
  landing_apply_manifest_is_valid "$work" || return 1
  landing_id="$(jq -r '.landing_id' "$package")" || return 1
  revision="$(jq -r '.revision' "$package")" || return 1
  sha256="$(jq -r '.content_sha256' "$package")" || return 1
  [[ "$landing_id" == "$(jq -r '.landing_id' "$LANDING_APPLY_TRANSACTION_JOURNAL")" &&
     "$revision" == "$(jq -r '.revision' "$LANDING_APPLY_TRANSACTION_JOURNAL")" &&
     "$sha256" == "$(jq -r '.content_sha256' "$LANDING_APPLY_TRANSACTION_JOURNAL")" ]] || return 1
  validate_landing_receipt_json "$work/receipt.base.json" || return 1
  validate_landing_receipt_json "$work/receipt.next.json" || return 1
  jq -e --arg landing_id "$landing_id" --argjson revision "$revision" --arg sha256 "$sha256" \
    --arg nonce "$(jq -r '.nonce' "$package")" '
      .landing_id == $landing_id and .emergency_override == false and
      .applied_revision == $revision and .content_sha256 == $sha256 and .nonce == $nonce
    ' "$work/receipt.next.json" >/dev/null || return 1
  if [[ "$(<"$work/receipt-snapshot/receipt.state")" == exists ]]; then
    cmp -s -- "$work/receipt.base.json" "$work/receipt-snapshot/receipt.json" || return 1
  else
    jq -e --arg landing_id "$landing_id" '
      .landing_id == $landing_id and .applied_revision == 0 and
      .content_sha256 == null and .nonce == null and .emergency_override == false
    ' "$work/receipt.base.json" >/dev/null || return 1
  fi
  landing_apply_snapshot_metadata_is_valid "$work"
}

landing_apply_load_pending_transaction() {
  validate_landing_apply_transaction_journal || return 1
  LANDING_ACTIVE_TRANSACTION_ID="$(<"$LANDING_APPLY_TRANSACTION_DIRECTORY/transaction.id")" || return 1
  LANDING_ACTIVE_TRANSACTION_PHASE="$(jq -r '.phase' "$LANDING_APPLY_TRANSACTION_JOURNAL")" || return 1
  LANDING_ACTIVE_WORK="$LANDING_APPLY_TRANSACTION_DIRECTORY"
  LANDING_ACTIVE_SNAPSHOT="$LANDING_ACTIVE_WORK/snapshot"
  LANDING_ACTIVE_RECEIPT_SNAPSHOT="$LANDING_ACTIVE_WORK/receipt-snapshot"
}

landing_apply_full_transaction_payload_is_present() {
  local work="$LANDING_ACTIVE_WORK" name
  for name in transaction.id apply.json gateway-ca.crt gateway.crt gateway.key check-config.json config.json \
    landing.nft nft.rollback receipt.base.json receipt.next.json manifest.sha256 snapshot receipt-snapshot; do
    [[ -e "$work/$name" && ! -L "$work/$name" ]] || return 1
  done
}

landing_apply_terminal_receipt_is_valid() {
  local phase="$1" context="${2:-runtime}" landing_id revision sha256 state snapshot name target cleanup_rc=0
  local ca_target certificate_target private_key_target config_target nft_target
  [[ "$context" == runtime || "$context" == startup-known || "$context" == startup ]] || return 1
  landing_apply_full_transaction_payload_is_present || return 1
  landing_apply_transaction_payload_is_valid || return 1
  landing_apply_cleanup_marker_is_valid || cleanup_rc=$?
  case "$cleanup_rc" in 0|2) ;; *) return 1 ;; esac
  landing_apply_terminal_marker_state_is_valid "$phase" || return 1
  if [[ "$phase" == committed ]]; then
    controller_private_directory_is_trusted "$(dirname -- "$LANDING_RECEIPT_FILE")" || return 1
    validate_landing_receipt_file "$LANDING_RECEIPT_FILE" || return 1
    landing_id="$(jq -r '.landing_id' "$LANDING_APPLY_TRANSACTION_JOURNAL")" || return 1
    revision="$(jq -r '.revision' "$LANDING_APPLY_TRANSACTION_JOURNAL")" || return 1
    sha256="$(jq -r '.content_sha256' "$LANDING_APPLY_TRANSACTION_JOURNAL")" || return 1
    jq -e --arg landing_id "$landing_id" --argjson revision "$revision" --arg sha256 "$sha256" '
      .landing_id == $landing_id and .applied_revision == $revision and
      .content_sha256 == $sha256 and .emergency_override == false
    ' "$LANDING_RECEIPT_FILE" >/dev/null || return 1
    landing_apply_transaction_file_is_safe "$LANDING_ACTIVE_WORK/receipt.next.json" || return 1
    validate_landing_receipt_json "$LANDING_ACTIVE_WORK/receipt.next.json" || return 1
    cmp -s -- "$LANDING_ACTIVE_WORK/receipt.next.json" "$LANDING_RECEIPT_FILE" || return 1
    ca_target="$(landing_managed_path "$LANDING_CA_CERTIFICATE_PATH")" || return 1
    certificate_target="$(landing_managed_path "$LANDING_CERTIFICATE_PATH")" || return 1
    private_key_target="$(landing_managed_path "$LANDING_PRIVATE_KEY_PATH")" || return 1
    config_target="$(landing_managed_path "$LANDING_SINGBOX_CONFIG_PATH")" || return 1
    nft_target="$(landing_managed_path "$LANDING_NFTABLES_RULES_PATH")" || return 1
    while IFS=$'\t' read -r name target; do
      [[ -n "$name" && -n "$target" ]] || return 1
      landing_apply_transaction_file_is_safe "$LANDING_ACTIVE_WORK/$name" || return 1
      landing_managed_target_is_safe "$target" || return 1
      cmp -s -- "$LANDING_ACTIVE_WORK/$name" "$target" || return 1
    done <<EOF
gateway-ca.crt	$ca_target
gateway.crt	$certificate_target
gateway.key	$private_key_target
config.json	$config_target
landing.nft	$nft_target
EOF
    case "$context" in
      runtime)
        landing_apply_new_runtime_is_valid "$LANDING_ACTIVE_WORK/apply.json" true || return 1
        ;;
      startup-known)
        landing_startup_persistent_candidate_is_valid || return 1
        landing_startup_singbox_is_stopped || return 1
        landing_startup_transaction_live_nft_is_known || return 1
        ;;
      startup)
        landing_startup_persistent_candidate_is_valid || return 1
        landing_startup_singbox_is_stopped || return 1
        landing_apply_live_nft_matches_candidate "$LANDING_ACTIVE_WORK/apply.json" || return 1
        ;;
    esac
    return
  fi
  [[ "$phase" == rolled_back ]] || return 1
  case "$context" in
    runtime) landing_apply_restored_state_is_valid || return 1 ;;
    startup-known)
      landing_startup_persistent_snapshot_is_valid || return 1
      landing_startup_singbox_is_stopped || return 1
      landing_startup_transaction_live_nft_is_known || return 1
      ;;
    startup)
      landing_startup_persistent_snapshot_is_valid || return 1
      landing_startup_singbox_is_stopped || return 1
      landing_apply_live_nft_matches_snapshot || return 1
      ;;
  esac
  snapshot="$LANDING_ACTIVE_RECEIPT_SNAPSHOT"
  landing_apply_transaction_file_is_safe "$snapshot/receipt.state" || return 1
  landing_apply_transaction_file_is_safe "$snapshot/receipt.json" || return 1
  state="$(<"$snapshot/receipt.state")" || return 1
  if [[ "$state" == exists ]]; then
    validate_landing_receipt_file "$LANDING_RECEIPT_FILE" || return 1
    cmp -s -- "$snapshot/receipt.json" "$LANDING_RECEIPT_FILE"
  elif [[ "$state" == missing ]]; then
    [[ ! -e "$LANDING_RECEIPT_FILE" && ! -L "$LANDING_RECEIPT_FILE" ]]
  else
    return 1
  fi
}

landing_apply_atomic_install_file() {
  local source="$1" target="$2" mode="$3" parent tmp actual_mode
  [[ -f "$source" && ! -L "$source" && "$target" == /* && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  [[ "$LANDING_ACTIVE_TRANSACTION_ID" =~ ^[0-9a-f]{32}$ ]] || return 1
  parent="$(dirname -- "$target")" || return 1
  landing_directory_is_safe "$parent" || return 1
  if [[ -e "$target" || -L "$target" ]]; then
    landing_managed_file_is_safe "$target" || return 1
  fi
  tmp="$parent/.landing-apply.${LANDING_ACTIVE_TRANSACTION_ID}.next"
  [[ ! -e "$tmp" && ! -L "$tmp" ]] || return 1
  if ! install -m "$mode" -- "$source" "$tmp" ||
     ! cmp -s -- "$source" "$tmp" ||
     ! actual_mode="$(manager_file_mode "$tmp")" ||
     [[ "$actual_mode" != "${mode#0}" ]] ||
     ! sync_transaction_path "$tmp" ||
     ! mv -- "$tmp" "$target" ||
     ! sync_transaction_path "$parent"; then
    rm -f -- "$tmp" || true
    return 1
  fi
}

landing_apply_cleanup_orphan_atomic_files() {
  local label target candidate snapshot parent tmp
  while IFS=$'\t' read -r label target candidate snapshot; do
    parent="$(dirname -- "$target")" || return 1
    if [[ ! -e "$parent" && ! -L "$parent" ]]; then
      continue
    fi
    landing_directory_is_safe "$parent" || return 1
    tmp="$parent/.landing-apply.${LANDING_ACTIVE_TRANSACTION_ID}.next"
    if [[ ! -e "$tmp" && ! -L "$tmp" ]]; then
      sync_transaction_path "$parent" || return 1
      continue
    fi
    landing_apply_transaction_file_is_safe "$tmp" || return 1
    # 随机 transaction ID 将临时文件绑定到当前 journal；即使写入中途断电、内容不完整也可精确清理。
    : "$label" "$candidate" "$snapshot"
    rm -f -- "$tmp" || return 1
    sync_transaction_path "$parent" || return 1
  done <<EOF
config	$(landing_managed_path "$LANDING_SINGBOX_CONFIG_PATH")	$LANDING_ACTIVE_WORK/config.json	$LANDING_ACTIVE_SNAPSHOT/config.json
ca	$(landing_managed_path "$LANDING_CA_CERTIFICATE_PATH")	$LANDING_ACTIVE_WORK/gateway-ca.crt	$LANDING_ACTIVE_SNAPSHOT/gateway-ca.crt
certificate	$(landing_managed_path "$LANDING_CERTIFICATE_PATH")	$LANDING_ACTIVE_WORK/gateway.crt	$LANDING_ACTIVE_SNAPSHOT/gateway.crt
private_key	$(landing_managed_path "$LANDING_PRIVATE_KEY_PATH")	$LANDING_ACTIVE_WORK/gateway.key	$LANDING_ACTIVE_SNAPSHOT/gateway.key
nft	$(landing_managed_path "$LANDING_NFTABLES_RULES_PATH")	$LANDING_ACTIVE_WORK/landing.nft	$LANDING_ACTIVE_SNAPSHOT/landing.nft
receipt	$LANDING_RECEIPT_FILE	$LANDING_ACTIVE_WORK/receipt.next.json	$LANDING_ACTIVE_RECEIPT_SNAPSHOT/receipt.json
EOF
}

landing_apply_cleanup_orphan_journal_file() {
  local tmp="$LANDING_APPLY_TRANSACTION_DIRECTORY/.journal.next"
  if [[ ! -e "$tmp" && ! -L "$tmp" ]]; then
    sync_transaction_path "$LANDING_APPLY_TRANSACTION_DIRECTORY"
    return
  fi
  landing_apply_transaction_file_is_safe "$tmp" || return 1
  rm -f -- "$tmp" || return 1
  sync_transaction_path "$LANDING_APPLY_TRANSACTION_DIRECTORY"
}

landing_apply_mark_mutation_started() {
  local marker="$LANDING_APPLY_TRANSACTION_DIRECTORY/mutation.started"
  [[ ! -e "$marker" && ! -L "$marker" ]] || return 1
  : > "$marker" || return 1
  chmod 600 "$marker" || return 1
  sync_transaction_path "$marker" || return 1
  sync_transaction_path "$LANDING_APPLY_TRANSACTION_DIRECTORY" || return 1
}

landing_apply_mutation_marker_is_valid() {
  local marker="$LANDING_APPLY_TRANSACTION_DIRECTORY/mutation.started"
  [[ -e "$marker" || -L "$marker" ]] || return 2
  landing_apply_transaction_file_is_safe "$marker" || return 1
  [[ ! -s "$marker" ]] || return 1
  sync_transaction_path "$marker" || return 1
  sync_transaction_path "$LANDING_APPLY_TRANSACTION_DIRECTORY" || return 1
}

landing_apply_mark_runtime_drift() {
  local marker="$LANDING_APPLY_TRANSACTION_DIRECTORY/runtime.drift"
  if [[ -e "$marker" || -L "$marker" ]]; then
    landing_apply_transaction_file_is_safe "$marker" || return 1
    [[ ! -s "$marker" ]] || return 1
    sync_transaction_path "$marker" || return 1
    sync_transaction_path "$LANDING_ACTIVE_WORK" || return 1
    return
  fi
  : > "$marker" || return 1
  chmod 600 "$marker" || return 1
  sync_transaction_path "$marker" || return 1
  sync_transaction_path "$LANDING_APPLY_TRANSACTION_DIRECTORY"
}

landing_apply_post_mutation_markers_are_absent() {
  local name
  for name in runtime.drift service.restart-attempted \
    nft.apply-attempted nft.rollback-attempted; do
    [[ ! -e "$LANDING_APPLY_TRANSACTION_DIRECTORY/$name" &&
       ! -L "$LANDING_APPLY_TRANSACTION_DIRECTORY/$name" ]] || return 1
  done
}

landing_apply_post_mutation_marker_sequence_is_valid() {
  local directory="$LANDING_APPLY_TRANSACTION_DIRECTORY" name
  for name in runtime.drift service.restart-attempted \
    nft.apply-attempted nft.rollback-attempted; do
    if [[ -e "$directory/$name" || -L "$directory/$name" ]]; then
      landing_apply_transaction_file_is_safe "$directory/$name" || return 1
      [[ ! -s "$directory/$name" ]] || return 1
    fi
  done
  if [[ -e "$directory/nft.apply-attempted" || -L "$directory/nft.apply-attempted" ]]; then
    [[ -e "$directory/service.restart-attempted" &&
       ! -L "$directory/service.restart-attempted" ]] || return 1
  fi
  if [[ -e "$directory/nft.rollback-attempted" || -L "$directory/nft.rollback-attempted" ]]; then
    [[ -e "$directory/nft.apply-attempted" &&
       ! -L "$directory/nft.apply-attempted" ]] || return 1
  fi
}

landing_apply_terminal_marker_state_is_valid() {
  local phase="$1" marker_rc=0 directory="$LANDING_APPLY_TRANSACTION_DIRECTORY" name
  [[ "$phase" == committed || "$phase" == rolled_back ]] || return 1
  landing_apply_mutation_marker_is_valid || marker_rc=$?
  case "$marker_rc" in 0|2) ;; *) return 1 ;; esac
  if [[ "$marker_rc" == 2 ]]; then
    landing_apply_post_mutation_markers_are_absent || return 1
    [[ "$phase" == rolled_back ]]
    return
  fi
  landing_apply_post_mutation_marker_sequence_is_valid || return 1
  [[ ! -e "$directory/runtime.drift" && ! -L "$directory/runtime.drift" ]] || return 1
  if [[ "$phase" == committed ]]; then
    for name in service.restart-attempted nft.apply-attempted; do
      [[ -e "$directory/$name" && ! -L "$directory/$name" ]] || return 1
    done
    [[ ! -e "$directory/nft.rollback-attempted" &&
       ! -L "$directory/nft.rollback-attempted" ]]
    return
  fi
  if [[ -e "$directory/nft.apply-attempted" || -L "$directory/nft.apply-attempted" ]]; then
    [[ -e "$directory/nft.rollback-attempted" &&
       ! -L "$directory/nft.rollback-attempted" ]] || return 1
  fi
}

landing_apply_mark_cleanup_started() {
  local directory="$LANDING_APPLY_TRANSACTION_DIRECTORY" marker tmp
  local transaction_id phase journal_sha256
  marker="$directory/cleanup.started"
  tmp="$directory/.cleanup.next"
  if [[ -e "$marker" || -L "$marker" ]]; then
    landing_apply_cleanup_marker_is_valid || return 1
    if [[ -e "$tmp" || -L "$tmp" ]]; then
      landing_apply_transaction_file_is_safe "$tmp" || return 1
      rm -f -- "$tmp" || return 1
      sync_transaction_path "$directory" || return 1
    fi
    return 0
  fi
  if [[ -e "$tmp" || -L "$tmp" ]]; then
    landing_apply_transaction_file_is_safe "$tmp" || return 1
    rm -f -- "$tmp" || return 1
    sync_transaction_path "$directory" || return 1
  fi
  transaction_id="$(<"$directory/transaction.id")" || return 1
  phase="$(jq -r '.phase' "$LANDING_APPLY_TRANSACTION_JOURNAL")" || return 1
  journal_sha256="$(sha256sum -- "$LANDING_APPLY_TRANSACTION_JOURNAL" | awk '{print $1}')" || return 1
  [[ "$transaction_id" =~ ^[0-9a-f]{32}$ &&
     ( "$phase" == committed || "$phase" == rolled_back ) &&
     "$journal_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
  jq -n --arg transaction_id "$transaction_id" --arg phase "$phase" \
    --arg journal_sha256 "$journal_sha256" '
      {
        schema_version:1,
        role:"landing-apply-cleanup",
        transaction_id:$transaction_id,
        phase:$phase,
        journal_sha256:$journal_sha256
      }
    ' > "$tmp" || return 1
  chmod 600 "$tmp" || return 1
  sync_transaction_path "$tmp" || return 1
  mv -- "$tmp" "$marker" || return 1
  sync_transaction_path "$directory" || return 1
}

landing_apply_cleanup_marker_is_valid() {
  local directory="$LANDING_APPLY_TRANSACTION_DIRECTORY" marker transaction_id phase journal_sha256 byte_count
  directory="$LANDING_APPLY_TRANSACTION_DIRECTORY"
  marker="$directory/cleanup.started"
  [[ -e "$marker" || -L "$marker" ]] || return 2
  landing_apply_transaction_file_is_safe "$marker" || return 1
  byte_count="$(wc -c < "$marker" | tr -d ' ')" || return 1
  [[ "$byte_count" =~ ^[0-9]+$ ]] || return 1
  ((byte_count >= 1 && byte_count <= 512)) || return 1
  transaction_id="$(<"$directory/transaction.id")" || return 1
  phase="$(jq -r '.phase' "$LANDING_APPLY_TRANSACTION_JOURNAL")" || return 1
  journal_sha256="$(sha256sum -- "$LANDING_APPLY_TRANSACTION_JOURNAL" | awk '{print $1}')" || return 1
  [[ "$transaction_id" =~ ^[0-9a-f]{32}$ &&
     ( "$phase" == committed || "$phase" == rolled_back ) &&
     "$journal_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
  jq -e -s --arg transaction_id "$transaction_id" --arg phase "$phase" \
    --arg journal_sha256 "$journal_sha256" '
      length == 1 and (.[0] |
        type == "object" and
        (keys | sort) == ["journal_sha256","phase","role","schema_version","transaction_id"] and
        .schema_version == 1 and .role == "landing-apply-cleanup" and
        .transaction_id == $transaction_id and .phase == $phase and
        .journal_sha256 == $journal_sha256)
    ' "$marker" >/dev/null || return 1
  sync_transaction_path "$marker" || return 1
  sync_transaction_path "$directory" || return 1
}

landing_apply_cleanup_marker_without_journal_is_valid() {
  local directory="$LANDING_APPLY_TRANSACTION_DIRECTORY" marker transaction_id byte_count
  directory="$LANDING_APPLY_TRANSACTION_DIRECTORY"
  marker="$directory/cleanup.started"
  [[ ! -e "$LANDING_APPLY_TRANSACTION_JOURNAL" && ! -L "$LANDING_APPLY_TRANSACTION_JOURNAL" &&
     ! -e "$directory/.cleanup.next" && ! -L "$directory/.cleanup.next" ]] || return 1
  landing_apply_transaction_id_file_is_valid || return 1
  landing_apply_transaction_file_is_safe "$marker" || return 1
  byte_count="$(wc -c < "$marker" | tr -d ' ')" || return 1
  [[ "$byte_count" =~ ^[0-9]+$ ]] || return 1
  ((byte_count >= 1 && byte_count <= 512)) || return 1
  transaction_id="$(<"$directory/transaction.id")" || return 1
  jq -e -s --arg transaction_id "$transaction_id" '
      length == 1 and (.[0] |
        type == "object" and
        (keys | sort) == ["journal_sha256","phase","role","schema_version","transaction_id"] and
        .schema_version == 1 and .role == "landing-apply-cleanup" and
        .transaction_id == $transaction_id and
        (.phase == "committed" or .phase == "rolled_back") and
        (.journal_sha256 | type == "string" and test("^[0-9a-f]{64}$")))
    ' "$marker" >/dev/null
}

landing_apply_clear_runtime_drift_after_revalidation() {
  local marker="$LANDING_APPLY_TRANSACTION_DIRECTORY/runtime.drift"
  [[ -e "$marker" || -L "$marker" ]] || return 0
  landing_apply_transaction_file_is_safe "$marker" || return 1
  [[ ! -s "$marker" ]] || return 1
  sync_transaction_path "$marker" || return 1
  sync_transaction_path "$LANDING_APPLY_TRANSACTION_DIRECTORY" || return 1
  rm -f -- "$marker" || return 1
  sync_transaction_path "$LANDING_APPLY_TRANSACTION_DIRECTORY"
}

landing_apply_target_path_is_safe_or_absent() {
  local target="$1" parent
  parent="$(dirname -- "$target")" || return 1
  if [[ ! -e "$parent" && ! -L "$parent" ]]; then
    [[ ! -e "$target" && ! -L "$target" ]]
    return
  fi
  landing_directory_is_safe "$parent" || return 1
  if [[ -e "$target" || -L "$target" ]]; then
    landing_managed_file_is_safe "$target"
  fi
}

landing_apply_target_matches_transaction() {
  local snapshot="$1" label="$2" target="$3" candidate="$4" state_file state
  state_file="${5:-${label}.state}"
  landing_apply_target_path_is_safe_or_absent "$target" || return 1
  state="$(<"$snapshot/$state_file")" || return 1
  case "$state" in
    exists)
      landing_managed_file_is_safe "$target" || return 1
      cmp -s -- "$snapshot/$label" "$target" || cmp -s -- "$candidate" "$target"
      ;;
    missing)
      if [[ -e "$target" || -L "$target" ]]; then
        landing_managed_file_is_safe "$target" || return 1
        cmp -s -- "$candidate" "$target"
      fi
      ;;
    *) return 1 ;;
  esac
}

landing_apply_runtime_targets_are_known() {
  landing_apply_target_matches_transaction "$LANDING_ACTIVE_SNAPSHOT" config.json \
    "$(landing_managed_path "$LANDING_SINGBOX_CONFIG_PATH")" "$LANDING_ACTIVE_WORK/config.json" || return 1
  landing_apply_target_matches_transaction "$LANDING_ACTIVE_SNAPSHOT" gateway-ca.crt \
    "$(landing_managed_path "$LANDING_CA_CERTIFICATE_PATH")" "$LANDING_ACTIVE_WORK/gateway-ca.crt" || return 1
  landing_apply_target_matches_transaction "$LANDING_ACTIVE_SNAPSHOT" gateway.crt \
    "$(landing_managed_path "$LANDING_CERTIFICATE_PATH")" "$LANDING_ACTIVE_WORK/gateway.crt" || return 1
  landing_apply_target_matches_transaction "$LANDING_ACTIVE_SNAPSHOT" gateway.key \
    "$(landing_managed_path "$LANDING_PRIVATE_KEY_PATH")" "$LANDING_ACTIVE_WORK/gateway.key" || return 1
  landing_apply_target_matches_transaction "$LANDING_ACTIVE_SNAPSHOT" landing.nft \
    "$(landing_managed_path "$LANDING_NFTABLES_RULES_PATH")" "$LANDING_ACTIVE_WORK/landing.nft" || return 1
  landing_apply_target_matches_transaction "$LANDING_ACTIVE_RECEIPT_SNAPSHOT" receipt.json \
    "$LANDING_RECEIPT_FILE" "$LANDING_ACTIVE_WORK/receipt.next.json" receipt.state
}

landing_apply_runtime_directories_are_known() {
  local states="$LANDING_ACTIVE_SNAPSHOT/directories.json" key path applied_mode state old_mode actual
  while IFS=$'\t' read -r key path applied_mode; do
    state="$(jq -r ".${key}.state" "$states")" || return 1
    old_mode="$(jq -r ".${key}.mode" "$states")" || return 1
    if [[ ! -e "$path" && ! -L "$path" ]]; then
      [[ "$state" == missing ]] || return 1
      continue
    fi
    landing_directory_is_safe "$path" || return 1
    actual="$(manager_file_mode "$path")" || return 1
    if [[ "$state" == exists ]]; then
      if [[ "$actual" != "$old_mode" ]] &&
         { [[ "$key" != tls ]] || [[ "$actual" != "$applied_mode" ]]; }; then
        return 1
      fi
    elif [[ "$state" == missing ]]; then
      if [[ "$actual" != "$applied_mode" ]] &&
         { [[ "$applied_mode" != 755 ]] || [[ "$actual" != 700 ]]; }; then
        return 1
      fi
    else
      return 1
    fi
  done <<EOF
etc	$(landing_managed_path /etc)	755
config_parent	$(landing_managed_path "$(dirname "$LANDING_SINGBOX_CONFIG_PATH")")	755
nft_parent	$(landing_managed_path "$LANDING_NFTABLES_DIRECTORY")	755
tls	$(landing_managed_path "$LANDING_TLS_DIRECTORY")	700
EOF
}

landing_apply_runtime_directories_match_applied() {
  local states="$LANDING_ACTIVE_SNAPSHOT/directories.json" key path applied_mode
  local state old_mode expected_mode actual
  while IFS=$'\t' read -r key path applied_mode; do
    state="$(jq -r ".${key}.state" "$states")" || return 1
    old_mode="$(jq -r ".${key}.mode" "$states")" || return 1
    [[ -d "$path" && ! -L "$path" ]] || return 1
    landing_directory_is_safe "$path" || return 1
    actual="$(manager_file_mode "$path")" || return 1
    case "$state" in
      exists)
        if [[ "$key" == tls ]]; then
          expected_mode=700
        else
          [[ "$old_mode" =~ ^[0-7]{3}$ ]] || return 1
          expected_mode="$old_mode"
        fi
        ;;
      missing) expected_mode="$applied_mode" ;;
      *) return 1 ;;
    esac
    [[ "$actual" == "$expected_mode" ]] || return 1
  done <<EOF
etc	$(landing_managed_path /etc)	755
config_parent	$(landing_managed_path "$(dirname "$LANDING_SINGBOX_CONFIG_PATH")")	755
nft_parent	$(landing_managed_path "$LANDING_NFTABLES_DIRECTORY")	755
tls	$(landing_managed_path "$LANDING_TLS_DIRECTORY")	700
EOF
}

landing_restore_receipt_snapshot() {
  local snapshot="$1" state receipt_dir
  [[ -d "$snapshot" && ! -L "$snapshot" ]] || return 1
  state="$(<"$snapshot/receipt.state")" || return 1
  receipt_dir="$(dirname -- "$LANDING_RECEIPT_FILE")" || return 1
  ensure_controller_private_directory "$receipt_dir" || return 1
  case "$state" in
    exists)
      landing_managed_target_is_safe "$LANDING_RECEIPT_FILE" || return 1
      landing_apply_atomic_install_file "$snapshot/receipt.json" "$LANDING_RECEIPT_FILE" 600
      ;;
    missing)
      if [[ -e "$LANDING_RECEIPT_FILE" || -L "$LANDING_RECEIPT_FILE" ]]; then
        controller_state_file_is_trusted "$LANDING_RECEIPT_FILE" || return 1
        rm -f -- "$LANDING_RECEIPT_FILE" || return 1
      fi
      sync_transaction_path "$receipt_dir" || return 1
      ;;
    *) return 1 ;;
  esac
}

landing_commit_receipt() {
  local package="$1" receipt="$2" now="$3" state_dir decision
  decision="$(landing_apply_replay_decision "$package" "$LANDING_ACTIVE_WORK/receipt.base.json" "$now")" || return 1
  [[ "$decision" == apply ]] || return 1
  [[ "$receipt" == "$LANDING_RECEIPT_FILE" ]] || return 1
  state_dir="$(dirname -- "$receipt")" || return 1
  ensure_controller_private_directory "$state_dir" || return 1
  landing_apply_atomic_install_file "$LANDING_ACTIVE_WORK/receipt.next.json" "$receipt" 600 || return 1
  validate_landing_receipt_file "$receipt" || return 1
  cmp -s -- "$LANDING_ACTIVE_WORK/receipt.next.json" "$receipt"
}

landing_create_snapshot() {
  local work="$1" snapshot tables service_state
  local config ca_certificate certificate private_key nft_rules
  snapshot="$work/snapshot"
  LANDING_APPLY_ERROR_CODE=snapshot_directory_failed
  landing_ensure_directory "$snapshot" 700 || return 1
  landing_snapshot_runtime_directories "$snapshot" || return 1
  config="$(landing_managed_path "$LANDING_SINGBOX_CONFIG_PATH")" || return 1
  ca_certificate="$(landing_managed_path "$LANDING_CA_CERTIFICATE_PATH")" || return 1
  certificate="$(landing_managed_path "$LANDING_CERTIFICATE_PATH")" || return 1
  private_key="$(landing_managed_path "$LANDING_PRIVATE_KEY_PATH")" || return 1
  nft_rules="$(landing_managed_path "$LANDING_NFTABLES_RULES_PATH")" || return 1
  LANDING_APPLY_ERROR_CODE=snapshot_files_failed
  landing_snapshot_file "$snapshot" config.json "$config" || return 1
  landing_snapshot_file "$snapshot" gateway-ca.crt "$ca_certificate" || return 1
  landing_snapshot_file "$snapshot" gateway.crt "$certificate" || return 1
  landing_snapshot_file "$snapshot" gateway.key "$private_key" || return 1
  landing_snapshot_file "$snapshot" landing.nft "$nft_rules" || return 1

  LANDING_APPLY_ERROR_CODE=snapshot_firewall_failed
  tables="$(nft -nn list tables 2>/dev/null)" || return 1
  if grep -Fxq "table $LANDING_NFTABLES_FAMILY $LANDING_NFTABLES_TABLE" <<<"$tables"; then
    nft -nn list table "$LANDING_NFTABLES_FAMILY" "$LANDING_NFTABLES_TABLE" \
      > "$snapshot/nft-live" 2>/dev/null || return 1
    printf 'exists\n' > "$snapshot/nft-live.state" || return 1
    chmod 600 "$snapshot/nft-live" "$snapshot/nft-live.state" || return 1
  else
    : > "$snapshot/nft-live" || return 1
    printf 'missing\n' > "$snapshot/nft-live.state" || return 1
    chmod 600 "$snapshot/nft-live" "$snapshot/nft-live.state" || return 1
  fi
  sync_transaction_path "$snapshot/nft-live" || return 1
  sync_transaction_path "$snapshot/nft-live.state" || return 1

  LANDING_APPLY_ERROR_CODE=snapshot_service_failed
  service_state="$(systemctl is-active "$LANDING_SINGBOX_SERVICE" 2>/dev/null || true)"
  case "$service_state" in
    active|inactive|failed) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$service_state" > "$snapshot/service.state" || return 1
  chmod 600 "$snapshot/service.state" || return 1
  sync_transaction_path "$snapshot/service.state" || return 1
  sync_transaction_path "$snapshot" || return 1
  LANDING_ACTIVE_SNAPSHOT="$snapshot"
}

landing_restore_snapshot_file() {
  local snapshot="$1" label="$2" target="$3" state parent
  state="$(<"$snapshot/${label}.state")" || return 1
  case "$state" in
    exists)
      landing_managed_target_is_safe "$target" || return 1
      landing_apply_atomic_install_file "$snapshot/$label" "$target" 600
      ;;
    missing)
      parent="$(dirname -- "$target")" || return 1
      if [[ -e "$target" || -L "$target" ]]; then
        landing_managed_target_is_safe "$target" || return 1
        rm -f -- "$target" || return 1
      fi
      if [[ -e "$parent" || -L "$parent" ]]; then
        landing_directory_is_safe "$parent" || return 1
        sync_transaction_path "$parent" || return 1
      else
        [[ ! -L "$parent" ]] || return 1
      fi
      ;;
    *) return 1 ;;
  esac
}

landing_apply_ensure_service_stopped() {
  local current
  # systemctl 的返回码不是安全判据；唯一权威后置条件是单位已不再处于运行或过渡态。
  systemctl stop "$LANDING_SINGBOX_SERVICE" >/dev/null 2>&1 || true
  current="$(systemctl is-active "$LANDING_SINGBOX_SERVICE" 2>/dev/null || true)"
  [[ "$current" == inactive || "$current" == failed ]]
}

landing_restore_snapshot() {
  local snapshot="$1" service_state current_service rc=0 service_transition=false
  local config ca_certificate certificate private_key nft_rules nft_state
  [[ -d "$snapshot" && ! -L "$snapshot" ]] || return 1
  config="$(landing_managed_path "$LANDING_SINGBOX_CONFIG_PATH")" || return 1
  ca_certificate="$(landing_managed_path "$LANDING_CA_CERTIFICATE_PATH")" || return 1
  certificate="$(landing_managed_path "$LANDING_CERTIFICATE_PATH")" || return 1
  private_key="$(landing_managed_path "$LANDING_PRIVATE_KEY_PATH")" || return 1
  nft_rules="$(landing_managed_path "$LANDING_NFTABLES_RULES_PATH")" || return 1

  if [[ -e "$LANDING_ACTIVE_WORK/service.restart-attempted" ||
        -L "$LANDING_ACTIVE_WORK/service.restart-attempted" ]]; then
    landing_apply_transaction_file_is_safe "$LANDING_ACTIVE_WORK/service.restart-attempted" || return 1
    [[ ! -s "$LANDING_ACTIVE_WORK/service.restart-attempted" ]] || return 1
    sync_transaction_path "$LANDING_ACTIVE_WORK/service.restart-attempted" || return 1
    sync_transaction_path "$LANDING_ACTIVE_WORK" || return 1
    landing_apply_ensure_service_stopped || return 1
    service_transition=true
  else
    landing_apply_service_matches_snapshot || return 1
  fi

  landing_restore_snapshot_file "$snapshot" config.json "$config" || rc=1
  if [[ "$rc" == 0 ]]; then landing_restore_snapshot_file "$snapshot" gateway-ca.crt "$ca_certificate" || rc=1; fi
  if [[ "$rc" == 0 ]]; then landing_restore_snapshot_file "$snapshot" gateway.crt "$certificate" || rc=1; fi
  if [[ "$rc" == 0 ]]; then landing_restore_snapshot_file "$snapshot" gateway.key "$private_key" || rc=1; fi
  if [[ "$rc" == 0 ]]; then landing_restore_snapshot_file "$snapshot" landing.nft "$nft_rules" || rc=1; fi

  if [[ "$rc" == 0 ]]; then
    if [[ -e "$LANDING_ACTIVE_WORK/nft.apply-attempted" ||
          -L "$LANDING_ACTIVE_WORK/nft.apply-attempted" ]]; then
      landing_apply_transaction_file_is_safe "$LANDING_ACTIVE_WORK/nft.apply-attempted" || rc=1
      [[ ! -s "$LANDING_ACTIVE_WORK/nft.apply-attempted" ]] || rc=1
      if [[ "$rc" == 0 ]]; then landing_apply_mark_nft_phase rollback || rc=1; fi
      if [[ "$rc" == 0 ]]; then
        nft_state="$(<"$snapshot/nft-live.state")" || rc=1
        if [[ "$nft_state" == exists ]]; then
          if landing_apply_live_nft_matches_snapshot; then
            :
          elif landing_apply_live_nft_is_missing; then
            nft -f "$snapshot/nft-live" >/dev/null 2>&1 || rc=1
          elif landing_apply_live_nft_matches_candidate "$LANDING_ACTIVE_WORK/apply.json"; then
            landing_apply_nft_rollback_batch_is_valid "$LANDING_ACTIVE_WORK" || rc=1
            if [[ "$rc" == 0 ]]; then
              nft -f "$LANDING_ACTIVE_WORK/nft.rollback" >/dev/null 2>&1 || rc=1
            fi
          else
            rc=1
          fi
        elif [[ "$nft_state" == missing ]]; then
          if ! landing_apply_live_nft_is_missing; then
            landing_apply_live_nft_matches_candidate "$LANDING_ACTIVE_WORK/apply.json" || rc=1
            if [[ "$rc" == 0 ]]; then
              landing_apply_nft_rollback_batch_is_valid "$LANDING_ACTIVE_WORK" || rc=1
            fi
            if [[ "$rc" == 0 ]]; then
              nft -f "$LANDING_ACTIVE_WORK/nft.rollback" >/dev/null 2>&1 || rc=1
            fi
          fi
        else
          rc=1
        fi
      fi
    else
      landing_apply_live_nft_matches_snapshot || rc=1
    fi
  fi

  if [[ "$rc" == 0 ]]; then
    landing_restore_runtime_directories "$snapshot" || rc=1
  fi
  if [[ "$rc" == 0 && "$service_transition" == true ]]; then
    service_state="$(<"$snapshot/service.state")" || rc=1
    if [[ "$rc" == 0 && "$service_state" == active ]]; then
      systemctl restart "$LANDING_SINGBOX_SERVICE" >/dev/null 2>&1 || rc=1
      if [[ "$rc" == 0 ]]; then
        systemctl is-active --quiet "$LANDING_SINGBOX_SERVICE" >/dev/null 2>&1 || rc=1
      fi
    elif [[ "$rc" == 0 && ( "$service_state" == inactive || "$service_state" == failed ) ]]; then
      current_service="$(systemctl is-active "$LANDING_SINGBOX_SERVICE" 2>/dev/null || true)"
      [[ "$current_service" == inactive || "$current_service" == failed ]] || rc=1
    elif [[ "$rc" == 0 ]]; then
      rc=1
    fi
  elif [[ "$rc" == 0 ]]; then
    landing_apply_service_matches_snapshot || rc=1
  fi
  return "$rc"
}

landing_apply_target_matches_snapshot() {
  local snapshot="$1" label="$2" target="$3" state_file state
  state_file="${4:-${label}.state}"
  landing_apply_target_path_is_safe_or_absent "$target" || return 1
  state="$(<"$snapshot/$state_file")" || return 1
  case "$state" in
    exists)
      landing_managed_file_is_safe "$target" || return 1
      cmp -s -- "$snapshot/$label" "$target"
      ;;
    missing) [[ ! -e "$target" && ! -L "$target" ]] ;;
    *) return 1 ;;
  esac
}

landing_apply_runtime_directories_match_snapshot() {
  local states="$LANDING_ACTIVE_SNAPSHOT/directories.json" key path state mode actual
  while IFS=$'\t' read -r key path; do
    state="$(jq -r ".${key}.state" "$states")" || return 1
    mode="$(jq -r ".${key}.mode" "$states")" || return 1
    case "$state" in
      exists)
        landing_directory_is_safe "$path" || return 1
        actual="$(manager_file_mode "$path")" || return 1
        [[ "$actual" == "$mode" ]] || return 1
        ;;
      missing) [[ ! -e "$path" && ! -L "$path" ]] || return 1 ;;
      *) return 1 ;;
    esac
  done <<EOF
etc	$(landing_managed_path /etc)
config_parent	$(landing_managed_path "$(dirname "$LANDING_SINGBOX_CONFIG_PATH")")
nft_parent	$(landing_managed_path "$LANDING_NFTABLES_DIRECTORY")
tls	$(landing_managed_path "$LANDING_TLS_DIRECTORY")
EOF
}

landing_apply_restored_state_is_valid() {
  local tables nft_state service_before service_after current_nft
  landing_apply_target_matches_snapshot "$LANDING_ACTIVE_SNAPSHOT" config.json \
    "$(landing_managed_path "$LANDING_SINGBOX_CONFIG_PATH")" || return 1
  landing_apply_target_matches_snapshot "$LANDING_ACTIVE_SNAPSHOT" gateway-ca.crt \
    "$(landing_managed_path "$LANDING_CA_CERTIFICATE_PATH")" || return 1
  landing_apply_target_matches_snapshot "$LANDING_ACTIVE_SNAPSHOT" gateway.crt \
    "$(landing_managed_path "$LANDING_CERTIFICATE_PATH")" || return 1
  landing_apply_target_matches_snapshot "$LANDING_ACTIVE_SNAPSHOT" gateway.key \
    "$(landing_managed_path "$LANDING_PRIVATE_KEY_PATH")" || return 1
  landing_apply_target_matches_snapshot "$LANDING_ACTIVE_SNAPSHOT" landing.nft \
    "$(landing_managed_path "$LANDING_NFTABLES_RULES_PATH")" || return 1
  landing_apply_target_matches_snapshot "$LANDING_ACTIVE_RECEIPT_SNAPSHOT" receipt.json \
    "$LANDING_RECEIPT_FILE" receipt.state || return 1
  nft_state="$(<"$LANDING_ACTIVE_SNAPSHOT/nft-live.state")" || return 1
  tables="$(nft -nn list tables 2>/dev/null)" || return 1
  if [[ "$nft_state" == exists ]]; then
    grep -Fxq "table $LANDING_NFTABLES_FAMILY $LANDING_NFTABLES_TABLE" <<<"$tables" || return 1
    current_nft="$(nft -nn list table "$LANDING_NFTABLES_FAMILY" "$LANDING_NFTABLES_TABLE" 2>/dev/null)" || return 1
    [[ "$current_nft" == "$(<"$LANDING_ACTIVE_SNAPSHOT/nft-live")" ]] || return 1
  elif [[ "$nft_state" == missing ]]; then
    ! grep -Fxq "table $LANDING_NFTABLES_FAMILY $LANDING_NFTABLES_TABLE" <<<"$tables" || return 1
  else
    return 1
  fi
  service_before="$(<"$LANDING_ACTIVE_SNAPSHOT/service.state")" || return 1
  service_after="$(systemctl is-active "$LANDING_SINGBOX_SERVICE" 2>/dev/null || true)"
  if [[ "$service_before" == active ]]; then
    [[ "$service_after" == active ]] || return 1
  else
    [[ "$service_after" == inactive || "$service_after" == failed ]] || return 1
  fi
  landing_apply_runtime_directories_match_snapshot
}

landing_apply_live_nft_matches_snapshot() {
  local nft_state tables current_nft
  nft_state="$(<"$LANDING_ACTIVE_SNAPSHOT/nft-live.state")" || return 1
  tables="$(nft -nn list tables 2>/dev/null)" || return 1
  if [[ "$nft_state" == exists ]]; then
    grep -Fxq "table $LANDING_NFTABLES_FAMILY $LANDING_NFTABLES_TABLE" <<<"$tables" || return 1
    current_nft="$(nft -nn list table "$LANDING_NFTABLES_FAMILY" "$LANDING_NFTABLES_TABLE" 2>/dev/null)" || return 1
    [[ "$current_nft" == "$(<"$LANDING_ACTIVE_SNAPSHOT/nft-live")" ]]
  elif [[ "$nft_state" == missing ]]; then
    if grep -Fxq "table $LANDING_NFTABLES_FAMILY $LANDING_NFTABLES_TABLE" <<<"$tables"; then
      return 1
    fi
    return 0
  else
    return 1
  fi
}

landing_apply_live_nft_matches_candidate() {
  local package="$1" tables current expected allowed_entry_ipv4 port
  tables="$(nft -nn list tables 2>/dev/null)" || return 1
  grep -Fxq "table $LANDING_NFTABLES_FAMILY $LANDING_NFTABLES_TABLE" <<<"$tables" || return 1
  current="$(nft -nn list table "$LANDING_NFTABLES_FAMILY" "$LANDING_NFTABLES_TABLE" 2>/dev/null)" || return 1
  expected="$(<"$LANDING_ACTIVE_WORK/landing.nft")" || return 1
  [[ "$current" == "$expected" ]] && return 0
  allowed_entry_ipv4="$(jq -r '.gateway.allowed_entry_ipv4' "$package")" || return 1
  port="$(jq -r '.gateway.listen_port' "$package")" || return 1
  is_ipv4_address "$allowed_entry_ipv4" || return 1
  landing_port_is_valid "$port" || return 1
  SB_LANDING_EXPECTED_ENTRY_IPV4="$allowed_entry_ipv4" \
  SB_LANDING_EXPECTED_PORT="$port" \
  SB_LANDING_EXPECTED_NFT_FAMILY="$LANDING_NFTABLES_FAMILY" \
  SB_LANDING_EXPECTED_NFT_TABLE="$LANDING_NFTABLES_TABLE" \
  SB_LANDING_EXPECTED_NFT_CHAIN="$LANDING_NFTABLES_CHAIN" python3 -I -c '
import os
import re
import sys

lines = [line.strip() for line in sys.stdin.read().splitlines() if line.strip()]
family = os.environ["SB_LANDING_EXPECTED_NFT_FAMILY"]
table = os.environ["SB_LANDING_EXPECTED_NFT_TABLE"]
chain = os.environ["SB_LANDING_EXPECTED_NFT_CHAIN"]
address = os.environ["SB_LANDING_EXPECTED_ENTRY_IPV4"]
port = os.environ["SB_LANDING_EXPECTED_PORT"]

if len(lines) != 7:
    raise SystemExit(1)
if lines[0] != f"table {family} {table} {{" or lines[1] != f"chain {chain} {{":
    raise SystemExit(1)
if not re.fullmatch(r"type filter hook input priority (?:-10|filter - 10); policy accept;", lines[2]):
    raise SystemExit(1)
if lines[3] != f"ip saddr {address} tcp dport {port} accept":
    raise SystemExit(1)
if lines[4] != f"tcp dport {port} drop":
    raise SystemExit(1)
if lines[5:] != ["}", "}"]:
    raise SystemExit(1)
' <<<"$current"
}

landing_apply_live_nft_is_known() {
  if landing_apply_live_nft_matches_snapshot; then return 0; fi
  if [[ -e "$LANDING_ACTIVE_WORK/nft.apply-attempted" ||
        -L "$LANDING_ACTIVE_WORK/nft.apply-attempted" ]]; then
    landing_apply_transaction_file_is_safe "$LANDING_ACTIVE_WORK/nft.apply-attempted" || return 1
    [[ ! -s "$LANDING_ACTIVE_WORK/nft.apply-attempted" ]] || return 1
    if landing_apply_live_nft_matches_candidate "$LANDING_ACTIVE_WORK/apply.json"; then return 0; fi
  fi
  if [[ -e "$LANDING_ACTIVE_WORK/nft.rollback-attempted" ||
        -L "$LANDING_ACTIVE_WORK/nft.rollback-attempted" ]]; then
    landing_apply_transaction_file_is_safe "$LANDING_ACTIVE_WORK/nft.rollback-attempted" || return 1
    [[ ! -s "$LANDING_ACTIVE_WORK/nft.rollback-attempted" ]] || return 1
    landing_apply_live_nft_is_missing
    return
  fi
  return 1
}

landing_apply_live_nft_is_missing() {
  local tables
  tables="$(nft -nn list tables 2>/dev/null)" || return 1
  ! grep -Fxq "table $LANDING_NFTABLES_FAMILY $LANDING_NFTABLES_TABLE" <<<"$tables"
}

landing_apply_mark_nft_phase() {
  local phase="$1" marker
  [[ "$phase" == apply || "$phase" == rollback ]] || return 1
  marker="$LANDING_ACTIVE_WORK/nft.${phase}-attempted"
  if [[ -e "$marker" || -L "$marker" ]]; then
    landing_apply_transaction_file_is_safe "$marker" || return 1
    [[ ! -s "$marker" ]] || return 1
    sync_transaction_path "$marker" || return 1
    sync_transaction_path "$LANDING_ACTIVE_WORK"
    return
  fi
  : > "$marker" || return 1
  chmod 600 "$marker" || return 1
  sync_transaction_path "$marker" || return 1
  sync_transaction_path "$LANDING_ACTIVE_WORK"
}

landing_apply_service_matches_snapshot() {
  local before after
  before="$(<"$LANDING_ACTIVE_SNAPSHOT/service.state")" || return 1
  after="$(systemctl is-active "$LANDING_SINGBOX_SERVICE" 2>/dev/null || true)"
  if [[ "$before" == active ]]; then
    [[ "$after" == active ]]
  else
    [[ "$after" == inactive || "$after" == failed ]]
  fi
}

landing_apply_service_is_known() {
  local before current marker="$LANDING_ACTIVE_WORK/service.restart-attempted"
  before="$(<"$LANDING_ACTIVE_SNAPSHOT/service.state")" || return 1
  current="$(systemctl is-active "$LANDING_SINGBOX_SERVICE" 2>/dev/null || true)"
  case "$current" in active|activating|deactivating|inactive|failed) ;; *) return 1 ;; esac
  if [[ -e "$marker" || -L "$marker" ]]; then
    landing_apply_transaction_file_is_safe "$marker" || return 1
    [[ ! -s "$marker" ]] || return 1
    sync_transaction_path "$marker" || return 1
    sync_transaction_path "$LANDING_ACTIVE_WORK" || return 1
    return
  fi
  if [[ "$before" == active ]]; then
    [[ "$current" == active ]]
  else
    [[ "$current" == inactive || "$current" == failed ]]
  fi
}

landing_apply_mark_service_restart_attempted() {
  local marker="$LANDING_ACTIVE_WORK/service.restart-attempted"
  [[ ! -e "$marker" && ! -L "$marker" ]] || return 1
  : > "$marker" || return 1
  chmod 600 "$marker" || return 1
  sync_transaction_path "$marker" || return 1
  sync_transaction_path "$LANDING_ACTIVE_WORK"
}

landing_apply_candidate_files_are_active() {
  local ca_target certificate_target private_key_target config_target nft_target
  ca_target="$(landing_managed_path "$LANDING_CA_CERTIFICATE_PATH")" || return 1
  certificate_target="$(landing_managed_path "$LANDING_CERTIFICATE_PATH")" || return 1
  private_key_target="$(landing_managed_path "$LANDING_PRIVATE_KEY_PATH")" || return 1
  config_target="$(landing_managed_path "$LANDING_SINGBOX_CONFIG_PATH")" || return 1
  nft_target="$(landing_managed_path "$LANDING_NFTABLES_RULES_PATH")" || return 1
  landing_managed_target_is_safe "$ca_target" || return 1
  landing_managed_target_is_safe "$certificate_target" || return 1
  landing_managed_target_is_safe "$private_key_target" || return 1
  landing_managed_target_is_safe "$config_target" || return 1
  landing_managed_target_is_safe "$nft_target" || return 1
  cmp -s -- "$LANDING_ACTIVE_WORK/gateway-ca.crt" "$ca_target" || return 1
  cmp -s -- "$LANDING_ACTIVE_WORK/gateway.crt" "$certificate_target" || return 1
  cmp -s -- "$LANDING_ACTIVE_WORK/gateway.key" "$private_key_target" || return 1
  cmp -s -- "$LANDING_ACTIVE_WORK/config.json" "$config_target" || return 1
  cmp -s -- "$LANDING_ACTIVE_WORK/landing.nft" "$nft_target"
}

landing_apply_new_runtime_is_valid() {
  local package="$1" require_receipt="${2:-false}" port
  landing_apply_runtime_directories_match_applied || return 1
  landing_apply_candidate_files_are_active || return 1
  landing_apply_live_nft_matches_candidate "$package" || return 1
  systemctl is-active --quiet "$LANDING_SINGBOX_SERVICE" >/dev/null 2>&1 || return 1
  port="$(jq -r '.gateway.listen_port' "$package")" || return 1
  landing_port_is_valid "$port" || return 1
  ss -H -ltnp "sport = :$port" 2>/dev/null | grep -Fq 'sing-box' || return 1
  if [[ "$require_receipt" == true ]]; then
    controller_private_directory_is_trusted "$(dirname -- "$LANDING_RECEIPT_FILE")" || return 1
    validate_landing_receipt_file "$LANDING_RECEIPT_FILE" || return 1
    cmp -s -- "$LANDING_ACTIVE_WORK/receipt.next.json" "$LANDING_RECEIPT_FILE" || return 1
  else
    [[ "$require_receipt" == false ]] || return 1
  fi
}

landing_apply_finish_rollback_transaction() {
  local context="${1:-runtime}" landing_id revision sha256 rc=0
  landing_id="$(jq -r '.landing_id' "$LANDING_APPLY_TRANSACTION_JOURNAL")" || return 1
  revision="$(jq -r '.revision' "$LANDING_APPLY_TRANSACTION_JOURNAL")" || return 1
  sha256="$(jq -r '.content_sha256' "$LANDING_APPLY_TRANSACTION_JOURNAL")" || return 1
  clear_signal_rollback
  landing_apply_write_transaction_journal rolled_back "$landing_id" "$revision" "$sha256" || rc=$?
  [[ "$rc" != 1 ]] || return 1
  landing_apply_reset_active_transaction
  [[ "$rc" == 0 ]] || return 2
  landing_apply_cleanup_terminal_transaction "$context" || return 2
}

landing_apply_rollback_active_transaction() {
  local rc=0 marker_rc=0
  [[ "$LANDING_ACTIVE_TRANSACTION_PHASE" == active ]] || return 1
  landing_apply_cleanup_orphan_journal_file || return 1
  landing_apply_transaction_payload_is_valid || return 1
  [[ ! -e "$LANDING_ACTIVE_WORK/cleanup.started" &&
     ! -L "$LANDING_ACTIVE_WORK/cleanup.started" &&
     ! -e "$LANDING_ACTIVE_WORK/.cleanup.next" &&
     ! -L "$LANDING_ACTIVE_WORK/.cleanup.next" ]] || return 1
  landing_apply_cleanup_orphan_atomic_files || return 1
  landing_apply_runtime_targets_are_known || return 1
  landing_apply_runtime_directories_are_known || return 1
  landing_apply_mutation_marker_is_valid || marker_rc=$?
  case "$marker_rc" in 0|2) ;; *) return 1 ;; esac
  if [[ "$marker_rc" == 2 ]]; then
    landing_apply_post_mutation_markers_are_absent || return 1
    landing_apply_restored_state_is_valid || return 1
    landing_apply_finish_rollback_transaction
    return
  fi
  landing_apply_post_mutation_marker_sequence_is_valid || return 1
  landing_apply_live_nft_is_known || return 1
  landing_apply_service_is_known || return 1
  landing_apply_clear_runtime_drift_after_revalidation || return 1
  landing_restore_snapshot "$LANDING_ACTIVE_SNAPSHOT" || rc=1
  if [[ "$rc" == 0 ]]; then
    landing_restore_receipt_snapshot "$LANDING_ACTIVE_RECEIPT_SNAPSHOT" || rc=1
  fi
  if [[ "$rc" == 0 ]]; then
    landing_apply_cleanup_orphan_atomic_files || rc=1
  fi
  if [[ "$rc" == 0 ]]; then
    landing_apply_restored_state_is_valid || rc=1
  fi
  if [[ "$rc" == 0 ]]; then
    landing_apply_finish_rollback_transaction || rc=$?
  fi
  return "$rc"
}

landing_apply_recover_pending_transaction() {
  local directory="$LANDING_APPLY_TRANSACTION_DIRECTORY" phase
  landing_apply_reset_active_transaction
  [[ ! -L "$directory" ]] || return 1
  [[ -e "$directory" ]] || return 0
  landing_apply_transaction_layout_is_safe || return 1
  if [[ ! -e "$LANDING_APPLY_TRANSACTION_JOURNAL" && ! -L "$LANDING_APPLY_TRANSACTION_JOURNAL" ]]; then
    landing_apply_discard_transaction_directory
    return
  fi
  landing_apply_load_pending_transaction || return 1
  phase="$LANDING_ACTIVE_TRANSACTION_PHASE"
  if [[ "$phase" == committed || "$phase" == rolled_back ]]; then
    landing_apply_terminal_receipt_is_valid "$phase" || return 1
    landing_apply_reset_active_transaction
    landing_apply_cleanup_terminal_transaction
    return
  fi
  [[ "$phase" == active ]] || return 1
  landing_apply_rollback_active_transaction
}

landing_apply_signal_rollback() {
  landing_apply_recover_pending_transaction
}

landing_apply_candidates() {
  local work="$1" package="$2" port
  local config ca_certificate certificate private_key nft_rules
  config="$(landing_managed_path "$LANDING_SINGBOX_CONFIG_PATH")" || return 1
  ca_certificate="$(landing_managed_path "$LANDING_CA_CERTIFICATE_PATH")" || return 1
  certificate="$(landing_managed_path "$LANDING_CERTIFICATE_PATH")" || return 1
  private_key="$(landing_managed_path "$LANDING_PRIVATE_KEY_PATH")" || return 1
  nft_rules="$(landing_managed_path "$LANDING_NFTABLES_RULES_PATH")" || return 1
  port="$(jq -r '.gateway.listen_port' "$package")" || return 1
  landing_port_is_valid "$port" || return 1

  LANDING_APPLY_ERROR_CODE=install_failed
  landing_managed_target_is_safe "$config" || return 1
  landing_managed_target_is_safe "$ca_certificate" || return 1
  landing_managed_target_is_safe "$certificate" || return 1
  landing_managed_target_is_safe "$private_key" || return 1
  landing_managed_target_is_safe "$nft_rules" || return 1

  # 先在旧运行态仍完整时确认没有外部漂移，再持久记录服务转换并停止服务单元。
  # 这样后续替换配置或切换端口防火墙时，不存在旧监听端口失去保护的窗口。
  LANDING_APPLY_ERROR_CODE=runtime_drift
  landing_apply_live_nft_matches_snapshot || return 1
  landing_apply_service_matches_snapshot || return 1
  LANDING_APPLY_ERROR_CODE=reload_failed
  landing_apply_mark_service_restart_attempted || return 1
  landing_apply_ensure_service_stopped || return 1

  LANDING_APPLY_ERROR_CODE=runtime_drift
  landing_apply_target_matches_snapshot "$LANDING_ACTIVE_SNAPSHOT" gateway-ca.crt "$ca_certificate" || return 1
  LANDING_APPLY_ERROR_CODE=install_failed
  landing_apply_atomic_install_file "$work/gateway-ca.crt" "$ca_certificate" 600 || return 1
  LANDING_APPLY_ERROR_CODE=runtime_drift
  landing_apply_target_matches_snapshot "$LANDING_ACTIVE_SNAPSHOT" gateway.crt "$certificate" || return 1
  LANDING_APPLY_ERROR_CODE=install_failed
  landing_apply_atomic_install_file "$work/gateway.crt" "$certificate" 600 || return 1
  LANDING_APPLY_ERROR_CODE=runtime_drift
  landing_apply_target_matches_snapshot "$LANDING_ACTIVE_SNAPSHOT" gateway.key "$private_key" || return 1
  LANDING_APPLY_ERROR_CODE=install_failed
  landing_apply_atomic_install_file "$work/gateway.key" "$private_key" 600 || return 1
  LANDING_APPLY_ERROR_CODE=runtime_drift
  landing_apply_target_matches_snapshot "$LANDING_ACTIVE_SNAPSHOT" config.json "$config" || return 1
  LANDING_APPLY_ERROR_CODE=install_failed
  landing_apply_atomic_install_file "$work/config.json" "$config" 600 || return 1
  LANDING_APPLY_ERROR_CODE=runtime_drift
  landing_apply_target_matches_snapshot "$LANDING_ACTIVE_SNAPSHOT" landing.nft "$nft_rules" || return 1
  LANDING_APPLY_ERROR_CODE=install_failed
  landing_apply_atomic_install_file "$work/landing.nft" "$nft_rules" 600 || return 1

  LANDING_APPLY_ERROR_CODE=runtime_drift
  landing_apply_live_nft_matches_snapshot || return 1
  LANDING_APPLY_ERROR_CODE=firewall_failed
  landing_apply_mark_nft_phase apply || return 1
  nft -f "$work/landing.nft" >/dev/null 2>&1 || return 1
  LANDING_APPLY_ERROR_CODE=reload_failed
  systemctl restart "$LANDING_SINGBOX_SERVICE" >/dev/null 2>&1 || return 1
  LANDING_APPLY_ERROR_CODE=health_failed
  systemctl is-active --quiet "$LANDING_SINGBOX_SERVICE" >/dev/null 2>&1 || return 1
  ss -H -ltnp "sport = :$port" 2>/dev/null | grep -Fq 'sing-box' || return 1
}

landing_rollback_after_failure() {
  local original_code="$1"
  if [[ "$original_code" == runtime_drift ]]; then
    if ! landing_apply_mark_runtime_drift; then
      landing_set_error_result rollback_failed
      return 1
    fi
    landing_set_error_result runtime_drift
    return 1
  fi
  if ! landing_apply_rollback_active_transaction; then
    landing_set_error_result rollback_failed
    return 1
  fi
  landing_set_error_result "$original_code"
  return 1
}

landing_apply_commit_active_transaction() {
  local landing_id="$1" revision="$2" sha256="$3" rc=0
  landing_apply_new_runtime_is_valid "$LANDING_ACTIVE_WORK/apply.json" true || return 3
  clear_signal_rollback
  landing_apply_write_transaction_journal committed "$landing_id" "$revision" "$sha256" || rc=$?
  [[ "$rc" != 1 ]] || return 1
  landing_apply_reset_active_transaction
  [[ "$rc" == 0 ]] || return 2
  landing_apply_cleanup_terminal_transaction || return 2
}

landing_apply_package_unlocked() {
  local package="$1" work="$2" now="$3" landing_id decision revision sha256 commit_rc=0
  landing_id="$(jq -r '.landing_id' "$package")" || {
    landing_set_error_result invalid_package
    return 1
  }
  if ! landing_prepare_receipt_base "$package" "$work"; then
    if [[ -e "$LANDING_RECEIPT_FILE" || -L "$LANDING_RECEIPT_FILE" ]]; then
      landing_set_error_result receipt_invalid
    else
      landing_set_error_result receipt_init_failed
    fi
    return 1
  fi
  decision="$(landing_apply_replay_decision "$package" "$work/receipt.base.json" "$now")" || {
    landing_set_error_result replay_rejected
    return 1
  }
  revision="$(jq -r '.revision' "$package")" || {
    landing_set_error_result invalid_package
    return 1
  }
  sha256="$(jq -r '.content_sha256' "$package")" || {
    landing_set_error_result invalid_package
    return 1
  }
  if [[ "$decision" == idempotent ]]; then
    landing_set_success_result idempotent "$revision" "$sha256"
    return
  fi
  [[ "$decision" == apply ]] || {
    landing_set_error_result replay_rejected
    return 1
  }

  landing_render_candidates "$package" "$work" || {
    landing_set_error_result render_failed
    return 1
  }
  LANDING_APPLY_ERROR_CODE=check_failed
  landing_validate_candidates "$work" || {
    landing_set_error_result check_failed
    return 1
  }
  LANDING_APPLY_ERROR_CODE=snapshot_failed
  landing_create_snapshot "$work" || {
    landing_set_error_result "$LANDING_APPLY_ERROR_CODE"
    return 1
  }
  if ! landing_prepare_nft_rollback_batch "$work" ||
     ! landing_validate_nft_rollback_batch "$work"; then
    landing_set_error_result transaction_prepare_failed
    return 1
  fi
  if ! landing_snapshot_receipt "$work"; then
    landing_set_error_result snapshot_receipt_failed
    return 1
  fi
  if ! landing_prepare_receipt_candidate "$package" "$work"; then
    landing_set_error_result receipt_prepare_failed
    return 1
  fi
  if ! landing_apply_write_manifest "$work" ||
     ! landing_apply_manifest_is_valid "$work" ||
     ! landing_apply_snapshot_metadata_is_valid "$work"; then
    landing_set_error_result transaction_prepare_failed
    return 1
  fi
  if ! landing_apply_write_transaction_journal active "$landing_id" "$revision" "$sha256"; then
    landing_apply_reset_active_transaction
    if [[ -e "$LANDING_APPLY_TRANSACTION_JOURNAL" || -L "$LANDING_APPLY_TRANSACTION_JOURNAL" ]]; then
      if [[ ! -L "$LANDING_APPLY_TRANSACTION_JOURNAL" ]] &&
         validate_landing_apply_transaction_journal &&
         [[ "$(jq -r '.phase' "$LANDING_APPLY_TRANSACTION_JOURNAL")" == active ]]; then
        landing_set_error_result transaction_prepare_failed
      else
        landing_set_error_result recovery_failed
      fi
    elif ! landing_apply_discard_transaction_directory; then
      landing_set_error_result recovery_failed
    else
      landing_set_error_result transaction_prepare_failed
    fi
    return 1
  fi
  LANDING_ACTIVE_SNAPSHOT="$work/snapshot"
  LANDING_ACTIVE_RECEIPT_SNAPSHOT="$work/receipt-snapshot"
  if ! landing_apply_restored_state_is_valid; then
    landing_set_error_result runtime_drift
    return 1
  fi
  if ! landing_apply_mark_mutation_started; then
    landing_set_error_result transaction_prepare_failed
    return 1
  fi
  landing_prepare_runtime_directories || {
    landing_rollback_after_failure prepare_failed
    return 1
  }
  if ! landing_apply_candidates "$work" "$package"; then
    landing_rollback_after_failure "$LANDING_APPLY_ERROR_CODE"
    return 1
  fi
  if ! landing_apply_new_runtime_is_valid "$package" false; then
    landing_rollback_after_failure verification_failed
    return 1
  fi
  if ! landing_apply_target_matches_snapshot "$LANDING_ACTIVE_RECEIPT_SNAPSHOT" receipt.json \
    "$LANDING_RECEIPT_FILE" receipt.state; then
    landing_set_error_result runtime_drift
    return 1
  fi
  LANDING_APPLY_ERROR_CODE=receipt_failed
  if ! landing_commit_receipt "$package" "$LANDING_RECEIPT_FILE" "$now"; then
    landing_rollback_after_failure receipt_failed
    return 1
  fi
  if ! landing_apply_new_runtime_is_valid "$package" true; then
    landing_rollback_after_failure verification_failed
    return 1
  fi
  landing_apply_commit_active_transaction "$landing_id" "$revision" "$sha256" || commit_rc=$?
  if [[ "$commit_rc" == 1 ]]; then
    landing_rollback_after_failure commit_failed
    return 1
  elif [[ "$commit_rc" == 2 ]]; then
    landing_set_error_result commit_uncertain
    return 1
  elif [[ "$commit_rc" == 3 ]]; then
    landing_rollback_after_failure verification_failed
    return 1
  fi
  landing_set_success_result applied "$revision" "$sha256"
}

landing_apply_execute_valid_package() {
  local package="$1" work="$2" now
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]] &&
     ! landing_channel_identity_allows_package "$package"; then
    landing_set_error_result channel_identity_mismatch
    return 1
  fi
  if ! now="$(date +%s)"; then
    landing_set_error_result clock_failed
    return 1
  fi
  if ! landing_apply_package_unlocked "$package" "$work" "$now"; then
    [[ -n "$LANDING_RESULT_STATUS" ]] || landing_set_error_result internal_error
    return 1
  fi
}

landing_apply_process_request_unlocked() {
  local work package rc=0
  if ! landing_apply_recover_pending_transaction; then
    landing_set_error_result recovery_failed
    return 1
  fi
  if ! landing_apply_begin_staging; then
    landing_set_error_result persistent_storage_failed
    return 1
  fi
  work="$LANDING_ACTIVE_WORK"
  package="$work/apply.json"
  if ! landing_apply_read_stdin "$package"; then
    landing_set_error_result invalid_input
    rc=1
  elif ! SB_LANDING_APPLY_VALIDATION_ROOT="$work" landing_apply_package_structure_is_valid "$package"; then
    landing_set_error_result invalid_package
    rc=1
  elif ! SB_LANDING_APPLY_VALIDATION_ROOT="$work" landing_apply_execute_valid_package "$package" "$work"; then
    rc=1
  fi
  if [[ ! -e "$LANDING_APPLY_TRANSACTION_JOURNAL" && ! -L "$LANDING_APPLY_TRANSACTION_JOURNAL" ]]; then
    landing_apply_reset_active_transaction
    if ! landing_apply_discard_transaction_directory; then
      landing_set_error_result cleanup_failed
      rc=1
    fi
  elif [[ -e "$LANDING_APPLY_TRANSACTION_DIRECTORY" || -L "$LANDING_APPLY_TRANSACTION_DIRECTORY" ]]; then
    # active 或终态事务的失败现场必须由下一次请求按持久 journal 收敛。
    landing_apply_reset_active_transaction
  else
    landing_apply_reset_active_transaction
  fi
  return "$rc"
}

landing_apply_process_request() {
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    if ! landing_channel_loaded_runtime_matches_identity; then
      landing_set_error_result channel_generation_mismatch
      return 1
    fi
    if ! landing_startup_receipt_lock_parent_chain_is_safe; then
      landing_set_error_result lock_failed
      return 1
    fi
    if ! landing_channel_generation_allows_request "$LANDING_REQUESTED_GENERATION"; then
      landing_set_error_result channel_generation_mismatch
      return 1
    fi
  fi
  if ! with_landing_receipt_lock landing_apply_process_request_unlocked; then
    [[ -n "$LANDING_RESULT_STATUS" ]] || landing_set_error_result lock_failed
    return 1
  fi
}

landing_apply_helper_request() {
  local rc=0
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    with_landing_channel_shared_lock landing_apply_process_request || rc=$?
    if ((rc != 0)) && [[ -z "$LANDING_RESULT_STATUS" ]]; then
      landing_set_error_result channel_unavailable
    fi
  else
    landing_apply_process_request || rc=$?
  fi
  landing_emit_current_result || rc=1
  return "$rc"
}

landing_apply_helper_main() {
  local generation="${1:-}" rc=0
  PATH=/usr/sbin:/usr/bin:/sbin:/bin
  LC_ALL=C
  export PATH LC_ALL
  umask 077
  unset BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH OPENSSL_CONF
  LANDING_RESULT_STATUS=""
  LANDING_RESULT_CODE=""
  LANDING_RESULT_REVISION=""
  LANDING_RESULT_SHA256=""
  LANDING_ACTIVE_SNAPSHOT=""
  LANDING_ACTIVE_RECEIPT_SNAPSHOT=""
  LANDING_ACTIVE_TRANSACTION_ID=""
  LANDING_ACTIVE_TRANSACTION_PHASE=""
  LANDING_ACTIVE_WORK=""
  LANDING_REQUESTED_GENERATION=""
  clear_signal_rollback
  if { [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]] && [[ $# -ne 0 ]]; } ||
     { [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]] &&
       { [[ $# -ne 1 ]] || [[ ! "$generation" =~ ^[0-9a-f]{64}$ ]]; }; }; then
    landing_set_error_result arguments_rejected
    landing_emit_current_result
    return 64
  fi
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    LANDING_REQUESTED_GENERATION="$generation"
  fi
  if [[ "$EUID" != "$(landing_apply_expected_uid)" ]]; then
    landing_set_error_result root_required
    landing_emit_current_result
    return 77
  fi
  if ! landing_apply_runtime_paths_are_safe; then
    landing_set_error_result unsafe_runtime_paths
    landing_emit_current_result
    return 78
  fi
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    if ! landing_startup_recovery_ensure_active; then
      landing_set_error_result startup_recovery_failed
      landing_emit_current_result || true
      return 1
    fi
    with_landing_channel_input_lock landing_apply_helper_request || rc=$?
    if ((rc != 0)) && [[ -z "$LANDING_RESULT_STATUS" ]]; then
      landing_set_error_result channel_busy
      landing_emit_current_result || true
    fi
    return "$rc"
  fi
  landing_apply_helper_request
}
