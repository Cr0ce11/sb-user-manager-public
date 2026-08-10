# ============================================================
# v5 落地 apply 启动恢复门禁（尚未接入菜单或正式服务器）
# ============================================================

LANDING_STARTUP_RECOVERY_UNIT_NAME=sb-user-manager-landing-recovery.service
LANDING_STARTUP_RECOVERY_UNIT_PATH=/etc/systemd/system/sb-user-manager-landing-recovery.service
LANDING_STARTUP_RECOVERY_DROPIN_DIRECTORY=/etc/systemd/system/sing-box.service.d
LANDING_STARTUP_RECOVERY_DROPIN_PATH=/etc/systemd/system/sing-box.service.d/10-sb-user-manager-landing-recovery.conf
LANDING_STARTUP_RECOVERY_MODE_ARGUMENT=--recover-startup

landing_startup_recovery_paths_are_safe() {
  [[ "$LANDING_STARTUP_RECOVERY_UNIT_NAME" == sb-user-manager-landing-recovery.service &&
     "$LANDING_STARTUP_RECOVERY_UNIT_PATH" == /etc/systemd/system/sb-user-manager-landing-recovery.service &&
     "$LANDING_STARTUP_RECOVERY_DROPIN_DIRECTORY" == /etc/systemd/system/sing-box.service.d &&
     "$LANDING_STARTUP_RECOVERY_DROPIN_PATH" == /etc/systemd/system/sing-box.service.d/10-sb-user-manager-landing-recovery.conf &&
     "$LANDING_STARTUP_RECOVERY_MODE_ARGUMENT" == --recover-startup &&
     "$LANDING_AGENT_HELPER_PATH" == /usr/local/libexec/sb-user-manager-landing-apply &&
     "$LANDING_SINGBOX_SERVICE" == sing-box ]]
}

landing_startup_recovery_unit_content() {
  cat <<EOF
[Unit]
Description=Recover sb-user-manager landing apply transaction before sing-box
After=local-fs.target nftables.service
Before=sing-box.service

[Service]
Type=oneshot
ExecStart=${LANDING_AGENT_HELPER_PATH} ${LANDING_STARTUP_RECOVERY_MODE_ARGUMENT}
RemainAfterExit=yes
User=root
Group=root
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
StandardInput=null
StandardOutput=null
EOF
}

landing_startup_recovery_dropin_content() {
  cat <<EOF
[Unit]
Requires=${LANDING_STARTUP_RECOVERY_UNIT_NAME}
After=${LANDING_STARTUP_RECOVERY_UNIT_NAME}
EOF
}

landing_startup_render_recovery_unit() {
  local output="$1"
  landing_startup_recovery_paths_are_safe || return 1
  landing_startup_recovery_unit_content > "$output" || return 1
  chmod 600 "$output" || return 1
}

landing_startup_render_singbox_dropin() {
  local output="$1"
  landing_startup_recovery_paths_are_safe || return 1
  landing_startup_recovery_dropin_content > "$output" || return 1
  chmod 600 "$output" || return 1
}

landing_startup_recovery_gate_files_are_valid() {
  local unit dropin root_uid root_gid logical path
  landing_startup_recovery_paths_are_safe || return 1
  for logical in /etc /etc/systemd /etc/systemd/system "$LANDING_STARTUP_RECOVERY_DROPIN_DIRECTORY"; do
    path="$(landing_channel_path "$logical")" || return 1
    landing_channel_system_directory_is_safe "$path" || return 1
  done
  unit="$(landing_channel_path "$LANDING_STARTUP_RECOVERY_UNIT_PATH")" || return 1
  dropin="$(landing_channel_path "$LANDING_STARTUP_RECOVERY_DROPIN_PATH")" || return 1
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  landing_channel_file_matches "$unit" 644 "$root_uid" "$root_gid" || return 1
  landing_channel_file_matches "$dropin" 644 "$root_uid" "$root_gid" || return 1
  [[ "$(<"$unit")" == "$(landing_startup_recovery_unit_content)" ]] || return 1
  [[ "$(<"$dropin")" == "$(landing_startup_recovery_dropin_content)" ]]
}

landing_startup_recovery_gate_files_are_absent() {
  local unit dropin
  unit="$(landing_channel_path "$LANDING_STARTUP_RECOVERY_UNIT_PATH")" || return 1
  dropin="$(landing_channel_path "$LANDING_STARTUP_RECOVERY_DROPIN_PATH")" || return 1
  [[ ! -e "$unit" && ! -L "$unit" && ! -e "$dropin" && ! -L "$dropin" ]]
}

landing_startup_recovery_gate_upgrade_source_is_valid() {
  landing_startup_recovery_gate_files_are_valid && return 0
  landing_startup_recovery_gate_files_are_absent
}

landing_startup_root_directory_is_safe() {
  local path="$1" allow_group_write="${2:-false}" allow_sticky_world="${3:-false}"
  local owner group mode expected_owner expected_group
  [[ "$allow_group_write" == true || "$allow_group_write" == false ]] || return 1
  [[ "$allow_sticky_world" == true || "$allow_sticky_world" == false ]] || return 1
  [[ -d "$path" && ! -L "$path" ]] || return 1
  owner="$(manager_file_uid "$path")" || return 1
  group="$(manager_file_gid "$path")" || return 1
  expected_owner="$(landing_channel_expected_root_uid)" || return 1
  expected_group="$(landing_channel_expected_root_gid)" || return 1
  # BSD `stat -f %Lp` omits setuid/setgid/sticky bits.  The startup gate must
  # see the complete mode because a world-writable lock parent is trusted only
  # when its sticky bit is present.
  mode="$(stat -c '%a' -- "$path" 2>/dev/null || stat -f '%Mp%Lp' "$path" 2>/dev/null)" || return 1
  [[ "$owner" == "$expected_owner" && "$group" == "$expected_group" &&
     "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 06000) == 0 && (8#$mode & 0700) == 0700 )) || return 1
  [[ "$allow_group_write" == true ]] || (( (8#$mode & 0020) == 0 ))
  if [[ "$allow_sticky_world" == true ]]; then
    (( (8#$mode & 0002) == 0 || (8#$mode & 01000) == 01000 ))
  else
    (( (8#$mode & 01002) == 0 ))
  fi
}

landing_startup_receipt_lock_parent_chain_is_safe() {
  local lock_parent lock_root run_root root_uid root_gid
  lock_parent="$(dirname -- "$LANDING_RECEIPT_LOCK_FILE")" || return 1
  lock_root="$(dirname -- "$lock_parent")" || return 1
  run_root="$(dirname -- "$lock_root")" || return 1
  [[ "$run_root" != / && "$lock_root" != / && "$lock_parent" != / ]] || return 1
  landing_startup_root_directory_is_safe "$run_root" false false || return 1
  landing_startup_root_directory_is_safe "$lock_root" true true || return 1
  if [[ -e "$lock_parent" || -L "$lock_parent" ]]; then
    root_uid="$(landing_channel_expected_root_uid)" || return 1
    root_gid="$(landing_channel_expected_root_gid)" || return 1
    landing_channel_directory_matches "$lock_parent" 700 "$root_uid" "$root_gid" || return 1
  fi
}

landing_startup_systemctl() {
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]]; then
    systemctl "$@"
  else
    /usr/bin/systemctl "$@"
  fi
}

landing_startup_recovery_daemon_reload() {
  landing_startup_systemctl daemon-reload >/dev/null 2>&1
}

landing_startup_recovery_ensure_active() {
  landing_startup_recovery_gate_files_are_valid || return 1
  landing_startup_systemctl start "$LANDING_STARTUP_RECOVERY_UNIT_NAME" >/dev/null 2>&1 || return 1
  landing_startup_systemctl is-active --quiet "$LANDING_STARTUP_RECOVERY_UNIT_NAME" >/dev/null 2>&1
}

landing_startup_recovery_stop() {
  local state
  state="$(landing_startup_systemctl is-active "$LANDING_STARTUP_RECOVERY_UNIT_NAME" 2>/dev/null || true)"
  case "$state" in
    inactive|failed|unknown) return 0 ;;
    active) ;;
    *) return 1 ;;
  esac
  landing_startup_systemctl stop "$LANDING_STARTUP_RECOVERY_UNIT_NAME" >/dev/null 2>&1 || return 1
  state="$(landing_startup_systemctl is-active "$LANDING_STARTUP_RECOVERY_UNIT_NAME" 2>/dev/null || true)"
  [[ "$state" == inactive || "$state" == failed || "$state" == unknown ]]
}

landing_startup_singbox_is_stopped() {
  local state
  state="$(landing_startup_systemctl is-active "$LANDING_SINGBOX_SERVICE" 2>/dev/null || true)"
  [[ "$state" == inactive || "$state" == failed ]]
}

landing_startup_singbox_is_active() {
  landing_startup_systemctl is-active --quiet "$LANDING_SINGBOX_SERVICE" >/dev/null 2>&1
}

landing_startup_root_executable_is_safe() {
  local path="$1" owner group mode expected_owner expected_group logical parent
  for logical in /usr /usr/local /usr/local/bin; do
    parent="$(landing_managed_path "$logical")" || return 1
    landing_channel_system_directory_is_safe "$parent" || return 1
  done
  [[ -f "$path" && ! -L "$path" && -x "$path" ]] || return 1
  owner="$(manager_file_uid "$path")" || return 1
  group="$(manager_file_gid "$path")" || return 1
  expected_owner="$(landing_apply_expected_uid)" || return 1
  expected_group="$(landing_channel_expected_root_gid)" || return 1
  mode="$(manager_file_mode "$path")" || return 1
  [[ "$owner" == "$expected_owner" && "$group" == "$expected_group" &&
     "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 07000) == 0 && (8#$mode & 0100) == 0100 && (8#$mode & 0022) == 0 ))
}

landing_startup_parse_nft_file() {
  local path="$1" parsed allowed_entry_ipv4 port
  landing_apply_transaction_file_is_safe "$path" || return 1
  parsed="$(SB_LANDING_EXPECTED_NFT_FAMILY="$LANDING_NFTABLES_FAMILY" \
    SB_LANDING_EXPECTED_NFT_TABLE="$LANDING_NFTABLES_TABLE" \
    SB_LANDING_EXPECTED_NFT_CHAIN="$LANDING_NFTABLES_CHAIN" \
    python3 -I -c '
import os
import re
import sys

family = re.escape(os.environ["SB_LANDING_EXPECTED_NFT_FAMILY"])
table = re.escape(os.environ["SB_LANDING_EXPECTED_NFT_TABLE"])
chain = re.escape(os.environ["SB_LANDING_EXPECTED_NFT_CHAIN"])
with open(sys.argv[1], "r", encoding="utf-8") as stream:
    lines = stream.read().splitlines()

# `jq -r` appends its own record terminator.  Releases produced before this
# gate also rendered one explicit final newline, so their otherwise canonical
# five-line rules file has exactly one trailing empty item after splitlines().
# Accept that single historical terminator, but keep rejecting any other blank
# or additional line.
if len(lines) == 6 and lines[-1] == "":
    lines.pop()
if len(lines) != 5:
    raise SystemExit(1)
expected = [
    rf"add table {family} {table}",
    rf"flush table {family} {table}",
    rf"add chain {family} {table} {chain} \{{ type filter hook input priority -10; policy accept; \}}",
]
if any(re.fullmatch(pattern, line) is None for pattern, line in zip(expected, lines[:3])):
    raise SystemExit(1)
accept = re.fullmatch(
    rf"add rule {family} {table} {chain} ip saddr ([0-9]{{1,3}}(?:\.[0-9]{{1,3}}){{3}}) tcp dport ([0-9]{{1,5}}) accept",
    lines[3],
)
if accept is None:
    raise SystemExit(1)
address, port = accept.groups()
if re.fullmatch(rf"add rule {family} {table} {chain} tcp dport {re.escape(port)} drop", lines[4]) is None:
    raise SystemExit(1)
print(f"{address}\t{port}")
' "$path")" || return 1
  IFS=$'\t' read -r allowed_entry_ipv4 port <<<"$parsed" || return 1
  is_public_ipv4 "$allowed_entry_ipv4" || return 1
  landing_port_is_valid "$port" || return 1
  printf '%s\t%s\n' "$allowed_entry_ipv4" "$port"
}

landing_startup_nft_file_matches_values() {
  local path="$1" expected_ipv4="$2" expected_port="$3" parsed_ipv4 parsed_port
  IFS=$'\t' read -r parsed_ipv4 parsed_port < <(landing_startup_parse_nft_file "$path") || return 1
  [[ "$parsed_ipv4" == "$expected_ipv4" && "$parsed_port" == "$expected_port" ]]
}

landing_startup_live_nft_matches_values() {
  local allowed_entry_ipv4="$1" port="$2" tables current
  is_ipv4_address "$allowed_entry_ipv4" || return 1
  landing_port_is_valid "$port" || return 1
  tables="$(nft -nn list tables 2>/dev/null)" || return 1
  grep -Fxq "table $LANDING_NFTABLES_FAMILY $LANDING_NFTABLES_TABLE" <<<"$tables" || return 1
  current="$(nft -nn list table "$LANDING_NFTABLES_FAMILY" "$LANDING_NFTABLES_TABLE" 2>/dev/null)" || return 1
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

landing_startup_config_has_no_managed_residue() {
  local config
  config="$(landing_managed_path "$LANDING_SINGBOX_CONFIG_PATH")" || return 1
  [[ ! -e "$config" && ! -L "$config" ]] && return 0
  [[ -f "$config" && ! -L "$config" ]] || return 1
  jq -e --arg certificate "$LANDING_CERTIFICATE_PATH" --arg key "$LANDING_PRIVATE_KEY_PATH" '
    type == "object" and
    ([.inbounds[]? |
      select(
        .tag == "landing-gateway" or
        any(.users[]?; .name == "entry-controller") or
        .tls.certificate_path? == $certificate or
        .tls.key_path? == $key
      )] | length == 0)
  ' "$config" >/dev/null
}

landing_startup_tls_material_is_valid() {
  local ca="$1" certificate="$2" private_key="$3" certificate_public_key private_public_key
  local historical_attime
  # 启动早期的系统时钟可能尚未同步；选择 CA 与证书有效期交集中的固定时刻，
  # 既验证签发关系，又避免依赖 OpenSSL 专有的 `-no_check_time` 选项。
  historical_attime="$(controller_historical_certificate_attime "$ca" "$certificate")" || return 1
  [[ "$historical_attime" =~ ^[0-9]+$ ]] || return 1
  openssl verify -attime "$historical_attime" -CAfile "$ca" "$certificate" \
    >/dev/null 2>&1 || return 1
  certificate_public_key="$(openssl x509 -in "$certificate" -pubkey -noout 2>/dev/null)" || return 1
  private_public_key="$(openssl pkey -in "$private_key" -pubout 2>/dev/null)" || return 1
  [[ -n "$certificate_public_key" && "$certificate_public_key" == "$private_public_key" ]]
}

landing_startup_runtime_directories_are_safe() {
  local requirement="${1:-optional}" system_etc config_parent nft_parent tls_directory path
  [[ "$requirement" == optional || "$requirement" == required ]] || return 1
  system_etc="$(landing_managed_path /etc)" || return 1
  config_parent="$(landing_managed_path "$(dirname -- "$LANDING_SINGBOX_CONFIG_PATH")")" || return 1
  nft_parent="$(landing_managed_path "$LANDING_NFTABLES_DIRECTORY")" || return 1
  tls_directory="$(landing_managed_path "$LANDING_TLS_DIRECTORY")" || return 1
  landing_directory_is_safe "$system_etc" || return 1
  for path in "$config_parent" "$nft_parent"; do
    if [[ -e "$path" || -L "$path" ]]; then
      landing_directory_is_safe "$path" || return 1
    else
      [[ "$requirement" == optional ]] || return 1
    fi
  done
  if [[ -e "$tls_directory" || -L "$tls_directory" ]]; then
    landing_directory_is_safe "$tls_directory" 700 || return 1
  else
    [[ "$requirement" == optional ]] || return 1
  fi
}

landing_startup_managed_state() {
  local receipt="$LANDING_RECEIPT_FILE" revision identity config ca certificate private_key nft_rules
  local allowed_entry_ipv4 nft_port port singbox_binary
  identity="$(landing_channel_path "$LANDING_CHANNEL_IDENTITY_PATH")" || return 1
  config="$(landing_managed_path "$LANDING_SINGBOX_CONFIG_PATH")" || return 1
  ca="$(landing_managed_path "$LANDING_CA_CERTIFICATE_PATH")" || return 1
  certificate="$(landing_managed_path "$LANDING_CERTIFICATE_PATH")" || return 1
  private_key="$(landing_managed_path "$LANDING_PRIVATE_KEY_PATH")" || return 1
  nft_rules="$(landing_managed_path "$LANDING_NFTABLES_RULES_PATH")" || return 1
  landing_startup_runtime_directories_are_safe optional || return 1
  if [[ ! -e "$receipt" && ! -L "$receipt" ]]; then
    [[ ! -e "$ca" && ! -L "$ca" && ! -e "$certificate" && ! -L "$certificate" &&
       ! -e "$private_key" && ! -L "$private_key" && ! -e "$nft_rules" && ! -L "$nft_rules" ]] || return 1
    landing_startup_config_has_no_managed_residue || return 1
    printf 'absent\n'
    return
  fi
  validate_landing_receipt_file "$receipt" || return 1
  revision="$(jq -r '.applied_revision' "$receipt")" || return 1
  landing_safe_integer_is_valid "$revision" || return 1
  if [[ "$revision" == 0 ]]; then
    [[ ! -e "$ca" && ! -L "$ca" && ! -e "$certificate" && ! -L "$certificate" &&
       ! -e "$private_key" && ! -L "$private_key" && ! -e "$nft_rules" && ! -L "$nft_rules" ]] || return 1
    landing_startup_config_has_no_managed_residue || return 1
    printf 'absent\n'
    return
  fi
  validate_landing_channel_identity_file "$identity" || return 1
  [[ "$(jq -r '.landing_id' "$receipt")" == "$(jq -r '.landing_id' "$identity")" ]] || return 1
  landing_startup_runtime_directories_are_safe required || return 1
  for path in "$config" "$ca" "$certificate" "$private_key" "$nft_rules"; do
    landing_managed_file_is_safe "$path" || return 1
  done
  port="$(jq -er --arg certificate "$LANDING_CERTIFICATE_PATH" --arg key "$LANDING_PRIVATE_KEY_PATH" '
    select(
    type == "object" and
    (keys | sort) == ["inbounds", "log", "outbounds", "route"] and
    .log == {level:"warn",timestamp:true} and
    (.inbounds | type == "array" and length == 1) and
    (.inbounds[0] | keys | sort) == ["listen","listen_port","tag","tls","type","users"] and
    .inbounds[0].type == "anytls" and .inbounds[0].tag == "landing-gateway" and
    .inbounds[0].listen == "0.0.0.0" and
    (.inbounds[0].listen_port | type == "number" and . == floor and . >= 1 and . <= 65535) and
    (.inbounds[0].users | type == "array" and length == 1) and
    (.inbounds[0].users[0] | keys | sort) == ["name","password"] and
    .inbounds[0].users[0].name == "entry-controller" and
    (.inbounds[0].users[0].password | type == "string" and length >= 32 and length <= 128 and
      test("^[A-Za-z0-9_-]+$")) and
    .inbounds[0].tls == {enabled:true,certificate_path:$certificate,key_path:$key} and
    .outbounds == [{type:"direct",tag:"direct"}] and .route == {final:"direct"}
    ) |
    .inbounds[0].listen_port
  ' "$config")" || return 1
  landing_port_is_valid "$port" || return 1
  IFS=$'\t' read -r allowed_entry_ipv4 nft_port < <(landing_startup_parse_nft_file "$nft_rules") || return 1
  [[ "$nft_port" == "$port" ]] || return 1
  landing_startup_tls_material_is_valid "$ca" "$certificate" "$private_key" || return 1
  singbox_binary="$(landing_managed_path "$LANDING_SINGBOX_BINARY")" || return 1
  landing_startup_root_executable_is_safe "$singbox_binary" || return 1
  "$singbox_binary" check -c "$config" >/dev/null 2>&1 || return 1
  nft -c -f "$nft_rules" >/dev/null 2>&1 || return 1
  printf 'applied\t%s\t%s\n' "$allowed_entry_ipv4" "$port"
}

landing_startup_enforce_installed_firewall() {
  local state allowed_entry_ipv4 port nft_rules
  IFS=$'\t' read -r state allowed_entry_ipv4 port < <(landing_startup_managed_state) || return 1
  [[ "$state" == absent || "$state" == applied ]] || return 1
  if [[ "$state" == absent ]]; then
    landing_apply_live_nft_is_missing
    return
  fi
  [[ "$state" == applied ]] || return 1
  nft_rules="$(landing_managed_path "$LANDING_NFTABLES_RULES_PATH")" || return 1
  if landing_startup_live_nft_matches_values "$allowed_entry_ipv4" "$port"; then
    return 0
  fi
  landing_apply_live_nft_is_missing || return 1
  nft -f "$nft_rules" >/dev/null 2>&1 || return 1
  landing_startup_live_nft_matches_values "$allowed_entry_ipv4" "$port"
}

landing_startup_installed_state_is_valid() {
  local state allowed_entry_ipv4 port
  IFS=$'\t' read -r state allowed_entry_ipv4 port < <(landing_startup_managed_state) || return 1
  case "$state" in
    absent) landing_apply_live_nft_is_missing ;;
    applied) landing_startup_live_nft_matches_values "$allowed_entry_ipv4" "$port" ;;
    *) return 1 ;;
  esac
}

landing_startup_persistent_snapshot_is_valid() {
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
  landing_apply_runtime_directories_match_snapshot
}

landing_startup_persistent_candidate_is_valid() {
  controller_private_directory_is_trusted "$(dirname -- "$LANDING_RECEIPT_FILE")" || return 1
  validate_landing_receipt_file "$LANDING_RECEIPT_FILE" || return 1
  cmp -s -- "$LANDING_ACTIVE_WORK/receipt.next.json" "$LANDING_RECEIPT_FILE" || return 1
  landing_apply_runtime_directories_match_applied || return 1
  landing_apply_candidate_files_are_active
}

landing_startup_transaction_live_nft_is_known() {
  landing_apply_live_nft_matches_snapshot && return 0
  landing_apply_live_nft_matches_candidate "$LANDING_ACTIVE_WORK/apply.json" && return 0
  landing_apply_live_nft_is_missing
}

landing_startup_replace_live_nft_with_candidate() {
  if landing_apply_live_nft_matches_candidate "$LANDING_ACTIVE_WORK/apply.json"; then
    return 0
  fi
  if landing_apply_live_nft_is_missing; then
    nft -f "$LANDING_ACTIVE_WORK/landing.nft" >/dev/null 2>&1 || return 1
  elif landing_apply_live_nft_matches_snapshot; then
    {
      printf 'delete table %s %s\n' "$LANDING_NFTABLES_FAMILY" "$LANDING_NFTABLES_TABLE" || return 1
      cat -- "$LANDING_ACTIVE_WORK/landing.nft" || return 1
    } | nft -f - >/dev/null 2>&1 || return 1
  else
    return 1
  fi
  landing_apply_live_nft_matches_candidate "$LANDING_ACTIVE_WORK/apply.json"
}

landing_startup_restore_live_nft_snapshot() {
  local nft_state
  if landing_apply_live_nft_matches_snapshot; then
    return 0
  fi
  nft_state="$(<"$LANDING_ACTIVE_SNAPSHOT/nft-live.state")" || return 1
  if landing_apply_live_nft_matches_candidate "$LANDING_ACTIVE_WORK/apply.json"; then
    landing_apply_nft_rollback_batch_is_valid "$LANDING_ACTIVE_WORK" || return 1
    nft -f "$LANDING_ACTIVE_WORK/nft.rollback" >/dev/null 2>&1 || return 1
  elif landing_apply_live_nft_is_missing; then
    if [[ "$nft_state" == exists ]]; then
      nft -f "$LANDING_ACTIVE_SNAPSHOT/nft-live" >/dev/null 2>&1 || return 1
    elif [[ "$nft_state" != missing ]]; then
      return 1
    fi
  else
    return 1
  fi
  landing_apply_live_nft_matches_snapshot
}

landing_startup_restore_persistent_snapshot() {
  local config ca certificate private_key nft_rules rc=0
  config="$(landing_managed_path "$LANDING_SINGBOX_CONFIG_PATH")" || return 1
  ca="$(landing_managed_path "$LANDING_CA_CERTIFICATE_PATH")" || return 1
  certificate="$(landing_managed_path "$LANDING_CERTIFICATE_PATH")" || return 1
  private_key="$(landing_managed_path "$LANDING_PRIVATE_KEY_PATH")" || return 1
  nft_rules="$(landing_managed_path "$LANDING_NFTABLES_RULES_PATH")" || return 1
  landing_restore_snapshot_file "$LANDING_ACTIVE_SNAPSHOT" config.json "$config" || rc=1
  if [[ "$rc" == 0 ]]; then landing_restore_snapshot_file "$LANDING_ACTIVE_SNAPSHOT" gateway-ca.crt "$ca" || rc=1; fi
  if [[ "$rc" == 0 ]]; then landing_restore_snapshot_file "$LANDING_ACTIVE_SNAPSHOT" gateway.crt "$certificate" || rc=1; fi
  if [[ "$rc" == 0 ]]; then landing_restore_snapshot_file "$LANDING_ACTIVE_SNAPSHOT" gateway.key "$private_key" || rc=1; fi
  if [[ "$rc" == 0 ]]; then landing_restore_snapshot_file "$LANDING_ACTIVE_SNAPSHOT" landing.nft "$nft_rules" || rc=1; fi
  if [[ "$rc" == 0 ]]; then landing_restore_runtime_directories "$LANDING_ACTIVE_SNAPSHOT" || rc=1; fi
  if [[ "$rc" == 0 ]]; then landing_restore_receipt_snapshot "$LANDING_ACTIVE_RECEIPT_SNAPSHOT" || rc=1; fi
  if [[ "$rc" == 0 ]]; then landing_startup_restore_live_nft_snapshot || rc=1; fi
  [[ "$rc" == 0 ]] || return 1
  landing_startup_persistent_snapshot_is_valid || return 1
  landing_apply_live_nft_matches_snapshot
}

landing_startup_clear_runtime_drift_after_revalidation() {
  local marker="$LANDING_ACTIVE_WORK/runtime.drift"
  [[ -e "$marker" || -L "$marker" ]] || return 0
  landing_apply_transaction_file_is_safe "$marker" || return 1
  [[ ! -s "$marker" ]] || return 1
  landing_apply_runtime_targets_are_known || return 1
  landing_apply_runtime_directories_are_known || return 1
  landing_startup_transaction_live_nft_is_known || return 1
  landing_startup_singbox_is_stopped || return 1
  rm -f -- "$marker" || return 1
  sync_transaction_path "$LANDING_ACTIVE_WORK"
}

landing_startup_rollback_active_transaction() {
  local marker_rc=0 rc=0
  [[ "$LANDING_ACTIVE_TRANSACTION_PHASE" == active ]] || return 1
  landing_apply_cleanup_orphan_journal_file || return 1
  landing_apply_transaction_payload_is_valid || return 1
  [[ ! -e "$LANDING_ACTIVE_WORK/cleanup.started" && ! -L "$LANDING_ACTIVE_WORK/cleanup.started" &&
     ! -e "$LANDING_ACTIVE_WORK/.cleanup.next" && ! -L "$LANDING_ACTIVE_WORK/.cleanup.next" ]] || return 1
  landing_apply_cleanup_orphan_atomic_files || return 1
  landing_apply_runtime_targets_are_known || return 1
  landing_apply_runtime_directories_are_known || return 1
  landing_startup_transaction_live_nft_is_known || return 1
  landing_startup_singbox_is_stopped || return 1
  landing_apply_mutation_marker_is_valid || marker_rc=$?
  case "$marker_rc" in 0|2) ;; *) return 1 ;; esac
  if [[ "$marker_rc" == 2 ]]; then
    landing_apply_post_mutation_markers_are_absent || return 1
    landing_startup_persistent_snapshot_is_valid || return 1
    landing_startup_restore_live_nft_snapshot || return 1
  else
    landing_apply_post_mutation_marker_sequence_is_valid || return 1
    landing_startup_clear_runtime_drift_after_revalidation || return 1
    landing_startup_restore_persistent_snapshot || rc=1
  fi
  if [[ "$rc" == 0 ]]; then
    landing_apply_cleanup_orphan_atomic_files || rc=1
  fi
  if [[ "$rc" == 0 ]]; then
    landing_startup_persistent_snapshot_is_valid || rc=1
  fi
  if [[ "$rc" == 0 ]]; then
    landing_apply_live_nft_matches_snapshot || rc=1
  fi
  if [[ "$rc" == 0 ]]; then
    landing_startup_installed_state_is_valid || rc=1
  fi
  if [[ "$rc" == 0 ]]; then
    landing_apply_finish_rollback_transaction startup || rc=$?
  fi
  return "$rc"
}

landing_startup_recover_pending_transaction() {
  local directory="$LANDING_APPLY_TRANSACTION_DIRECTORY" phase name
  landing_apply_reset_active_transaction
  [[ ! -L "$directory" ]] || return 1
  [[ -e "$directory" ]] || return 0
  landing_apply_transaction_layout_is_safe || return 1
  if [[ ! -e "$LANDING_APPLY_TRANSACTION_JOURNAL" && ! -L "$LANDING_APPLY_TRANSACTION_JOURNAL" ]]; then
    if [[ -e "$directory/cleanup.started" || -L "$directory/cleanup.started" ]]; then
      landing_apply_cleanup_marker_without_journal_is_valid || return 1
    else
      for name in mutation.started runtime.drift service.restart-attempted \
        nft.apply-attempted nft.rollback-attempted; do
        [[ ! -e "$directory/$name" && ! -L "$directory/$name" ]] || return 1
      done
    fi
    # 无 journal 只能是变更前 staging 或已越过 journal 删除边界的合法 cleanup。
    # 先从持久态恢复并只读复核 live firewall；校验失败时保留全部残留证据。
    landing_startup_enforce_installed_firewall || return 1
    landing_startup_installed_state_is_valid || return 1
    landing_apply_discard_transaction_directory
    return
  fi
  landing_apply_load_pending_transaction || return 1
  phase="$LANDING_ACTIVE_TRANSACTION_PHASE"
  if [[ "$phase" == committed || "$phase" == rolled_back ]]; then
    landing_apply_terminal_receipt_is_valid "$phase" startup-known || return 1
    if [[ "$phase" == committed ]]; then
      landing_startup_replace_live_nft_with_candidate || return 1
    else
      landing_startup_restore_live_nft_snapshot || return 1
    fi
    # 只有完整持久态与 live firewall 都已通过只读校验，才允许删除终态证据。
    landing_startup_installed_state_is_valid || return 1
    landing_apply_reset_active_transaction
    landing_apply_cleanup_terminal_transaction startup
    return
  fi
  [[ "$phase" == active ]] || return 1
  set_signal_rollback landing_startup_signal_recovery || return 1
  landing_startup_rollback_active_transaction
}

landing_startup_signal_recovery() {
  landing_startup_recover_pending_transaction || return 1
  landing_startup_enforce_installed_firewall
}

landing_startup_recovery_unlocked() {
  local state tls_directory
  if ! landing_startup_singbox_is_stopped; then
    # 首次启用门禁时，既有 v4/外部 sing-box 可能仍在运行。只允许完全没有
    # v5 事务、receipt、受管配置残留和同名实时 nft 表的严格空态通过。
    landing_startup_singbox_is_active || return 1
    [[ ! -e "$LANDING_APPLY_TRANSACTION_DIRECTORY" &&
       ! -L "$LANDING_APPLY_TRANSACTION_DIRECTORY" ]] || return 1
    [[ ! -e "$LANDING_RECEIPT_FILE" && ! -L "$LANDING_RECEIPT_FILE" ]] || return 1
    tls_directory="$(landing_managed_path "$LANDING_TLS_DIRECTORY")" || return 1
    [[ ! -e "$tls_directory" && ! -L "$tls_directory" ]] || return 1
    state="$(landing_startup_managed_state)" || return 1
    [[ "$state" == absent ]] || return 1
    landing_apply_live_nft_is_missing
    return
  fi
  landing_startup_recover_pending_transaction || return 1
  landing_startup_enforce_installed_firewall || return 1
  landing_startup_singbox_is_stopped
}

landing_startup_recovery_with_receipt_lock() {
  with_landing_receipt_lock landing_startup_recovery_unlocked
}

landing_startup_recovery_after_channel_lock() {
  # 外层早检用于快速失败；shared channel lock 内复核，关闭与通道轮换之间的 TOCTOU。
  landing_startup_recovery_gate_files_are_valid || return 1
  landing_restricted_channel_is_valid || return 1
  landing_channel_loaded_runtime_matches_identity || return 1
  landing_startup_receipt_lock_parent_chain_is_safe || return 1
  landing_startup_recovery_with_receipt_lock
}

landing_startup_recovery_with_channel_lock() {
  with_landing_channel_shared_lock landing_startup_recovery_after_channel_lock
}

landing_startup_recovery_main() {
  local rc=0
  [[ $# -eq 0 ]] || return 64
  PATH=/usr/sbin:/usr/bin:/sbin:/bin
  LC_ALL=C
  export PATH LC_ALL
  umask 077
  unset BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH OPENSSL_CONF
  landing_apply_reset_active_transaction
  [[ "$EUID" == "$(landing_apply_expected_uid)" ]] || return 77
  landing_apply_runtime_paths_are_safe || return 78
  landing_channel_runtime_paths_are_safe || return 78
  landing_startup_recovery_paths_are_safe || return 78
  landing_startup_recovery_gate_files_are_valid || return 78
  with_landing_channel_input_lock landing_startup_recovery_with_channel_lock || rc=$?
  landing_apply_reset_active_transaction
  return "$rc"
}
