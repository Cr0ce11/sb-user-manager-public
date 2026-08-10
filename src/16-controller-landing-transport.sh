# ============================================================
# v5 入口到受管落地的固定身份传输（尚未接入菜单或安装流程）
# ============================================================

CONTROLLER_LANDING_SSH_ACCOUNT=sb-landing-agent
CONTROLLER_LANDING_KEYSCAN_TIMEOUT=5
CONTROLLER_LANDING_KEYSCAN_WALL_TIMEOUT=8
CONTROLLER_LANDING_CONNECT_TIMEOUT=5
CONTROLLER_LANDING_SESSION_TIMEOUT=45
CONTROLLER_LANDING_SESSION_KILL_AFTER=3
CONTROLLER_LANDING_RESPONSE_MAX_BYTES=512
CONTROLLER_LANDING_PACKAGE_TTL=300
CONTROLLER_LANDING_LAST_SSH_STATUS=""
if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]]; then
  CONTROLLER_LANDING_WORK_ROOT="${SB_CONTROLLER_LANDING_WORK_ROOT:-/run/sb-user-manager-controller}"
  CONTROLLER_LANDING_SSH_BIN="${SB_CONTROLLER_LANDING_SSH_BIN:-/usr/bin/ssh}"
  CONTROLLER_LANDING_SSH_KEYSCAN_BIN="${SB_CONTROLLER_LANDING_SSH_KEYSCAN_BIN:-/usr/bin/ssh-keyscan}"
  CONTROLLER_LANDING_SSH_KEYGEN_BIN="${SB_CONTROLLER_LANDING_SSH_KEYGEN_BIN:-/usr/bin/ssh-keygen}"
  CONTROLLER_LANDING_TIMEOUT_BIN="${SB_CONTROLLER_LANDING_TIMEOUT_BIN:-/usr/bin/timeout}"
  CONTROLLER_LANDING_AWK_BIN="${SB_CONTROLLER_LANDING_AWK_BIN:-/usr/bin/awk}"
  CONTROLLER_LANDING_SORT_BIN="${SB_CONTROLLER_LANDING_SORT_BIN:-/usr/bin/sort}"
else
  CONTROLLER_LANDING_WORK_ROOT=/run/sb-user-manager-controller
  CONTROLLER_LANDING_SSH_BIN=/usr/bin/ssh
  CONTROLLER_LANDING_SSH_KEYSCAN_BIN=/usr/bin/ssh-keyscan
  CONTROLLER_LANDING_SSH_KEYGEN_BIN=/usr/bin/ssh-keygen
  CONTROLLER_LANDING_TIMEOUT_BIN=/usr/bin/timeout
  CONTROLLER_LANDING_AWK_BIN=/usr/bin/awk
  CONTROLLER_LANDING_SORT_BIN=/usr/bin/sort
fi

controller_landing_transport_executable_is_safe() {
  local path="$1" expected="$2" resolved owner mode
  [[ "$path" == /* && -f "$path" && -x "$path" ]] || return 1
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    [[ "$path" == "$expected" ]] || return 1
    resolved="$(/usr/bin/readlink -f -- "$path")" || return 1
    [[ "$resolved" == /* && -f "$resolved" && ! -L "$resolved" && -x "$resolved" ]] || return 1
    owner="$(manager_file_uid "$resolved")" || return 1
    [[ "$owner" == 0 ]] || return 1
    mode="$(manager_file_mode "$resolved")" || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 0022) == 0 )) || return 1
  fi
}

controller_landing_transport_runtime_is_safe() {
  [[ "$CONTROLLER_LANDING_SSH_ACCOUNT" == sb-landing-agent &&
     "$CONTROLLER_LANDING_KEYSCAN_TIMEOUT" == 5 &&
     "$CONTROLLER_LANDING_KEYSCAN_WALL_TIMEOUT" == 8 &&
     "$CONTROLLER_LANDING_CONNECT_TIMEOUT" == 5 &&
     "$CONTROLLER_LANDING_SESSION_TIMEOUT" == 45 &&
     "$CONTROLLER_LANDING_SESSION_KILL_AFTER" == 3 &&
     "$CONTROLLER_LANDING_RESPONSE_MAX_BYTES" == 512 &&
     "$CONTROLLER_LANDING_PACKAGE_TTL" == 300 ]] || return 1
  controller_landing_transport_executable_is_safe \
    "$CONTROLLER_LANDING_SSH_BIN" /usr/bin/ssh || return 1
  controller_landing_transport_executable_is_safe \
    "$CONTROLLER_LANDING_SSH_KEYSCAN_BIN" /usr/bin/ssh-keyscan || return 1
  controller_landing_transport_executable_is_safe \
    "$CONTROLLER_LANDING_SSH_KEYGEN_BIN" /usr/bin/ssh-keygen || return 1
  controller_landing_transport_executable_is_safe \
    "$CONTROLLER_LANDING_TIMEOUT_BIN" /usr/bin/timeout || return 1
  controller_landing_transport_executable_is_safe \
    "$CONTROLLER_LANDING_AWK_BIN" /usr/bin/awk || return 1
  controller_landing_transport_executable_is_safe \
    "$CONTROLLER_LANDING_SORT_BIN" /usr/bin/sort
}

controller_landing_file_size() {
  local path="$1" size
  size="$(stat -c '%s' -- "$path" 2>/dev/null || stat -f '%z' "$path" 2>/dev/null)" || return 1
  [[ "$size" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$size"
}

controller_landing_private_file_is_trusted() {
  local path="$1" owner mode expected_owner
  [[ -f "$path" && ! -L "$path" && -r "$path" ]] || return 1
  owner="$(manager_file_uid "$path")" || return 1
  expected_owner="$(controller_state_expected_uid)"
  [[ "$owner" == "$expected_owner" ]] || return 1
  mode="$(manager_file_mode "$path")" || return 1
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0777) == 0600 ))
}

controller_landing_ssh_private_key_is_valid() {
  local path="$1" public_key
  controller_state_file_is_trusted "$path" || return 1
  public_key="$("$CONTROLLER_LANDING_SSH_KEYGEN_BIN" -y -P '' -f "$path" 2>/dev/null)" || return 1
  [[ "$public_key" == ssh-ed25519\ * && "$public_key" != *$'\n'* ]]
}

controller_landing_create_work_directory() {
  local work
  ensure_controller_private_directory "$CONTROLLER_LANDING_WORK_ROOT" || return 1
  work="$(mktemp -d "$CONTROLLER_LANDING_WORK_ROOT/.controller-landing.XXXXXX")" || return 1
  chmod 700 "$work" || { rm -rf -- "$work"; return 1; }
  controller_private_directory_is_trusted "$work" || { rm -rf -- "$work"; return 1; }
  printf '%s\n' "$work"
}

controller_landing_remove_work_directory() {
  local work="$1" name
  name="${work##*/}"
  [[ "$work" == "$CONTROLLER_LANDING_WORK_ROOT"/* &&
     "$name" =~ ^\.controller-landing\.[A-Za-z0-9]+$ ]] || return 1
  if [[ -e "$work" || -L "$work" ]]; then
    controller_private_directory_is_trusted "$work" || return 1
    rm -rf -- "$work" || return 1
  fi
  [[ ! -e "$work" && ! -L "$work" ]]
}

controller_landing_write_snapshot() {
  local landing_id="$1" output="$2"
  landing_id_is_valid "$landing_id" || return 1
  validate_controller_state_file "$CONTROLLER_STATE_FILE" || return 1
  [[ ! -e "$output" && ! -L "$output" ]] || return 1
  if ! jq -e --arg landing_id "$landing_id" '
      [.landings[] | select(.id == $landing_id)] as $matches |
      if ($matches | length) == 1 and
         ($matches[0].status == "pending" or $matches[0].status == "active" or
          $matches[0].status == "error") and
         $matches[0].desired_revision >= 1
      then $matches[0]
      else error("landing unavailable")
      end
    ' "$CONTROLLER_STATE_FILE" > "$output" 2>/dev/null; then
    rm -f -- "$output"
    return 1
  fi
  chmod 600 "$output" || { rm -f -- "$output"; return 1; }
  controller_landing_private_file_is_trusted "$output"
}

controller_landing_scan_ed25519_fingerprint() {
  local address="$1" ssh_port="$2" work="$3"
  local scan_file="$work/host-key.scan" public_key_file="$work/host-key.pub"
  local scan_size key_count fingerprint_line
  local key_bits actual_fingerprint remainder

  controller_landing_address_is_valid "$address" || return 1
  landing_port_is_valid "$ssh_port" || return 1
  controller_private_directory_is_trusted "$work" || return 1
  [[ ! -e "$scan_file" && ! -L "$scan_file" &&
     ! -e "$public_key_file" && ! -L "$public_key_file" ]] || return 1

  if ! "$CONTROLLER_LANDING_TIMEOUT_BIN" -k 1 "$CONTROLLER_LANDING_KEYSCAN_WALL_TIMEOUT" \
      "$CONTROLLER_LANDING_SSH_KEYSCAN_BIN" -T "$CONTROLLER_LANDING_KEYSCAN_TIMEOUT" \
      -p "$ssh_port" -t ed25519 -- "$address" > "$scan_file" 2>/dev/null; then
    return 1
  fi
  chmod 600 "$scan_file" || return 1
  controller_landing_private_file_is_trusted "$scan_file" || return 1
  scan_size="$(controller_landing_file_size "$scan_file")" || return 1
  ((scan_size >= 1 && scan_size <= 65536)) || return 1

  if ! "$CONTROLLER_LANDING_AWK_BIN" '
      NF == 0 { next }
      NF != 3 || $2 != "ssh-ed25519" { invalid = 1; next }
      { print $2 " " $3; count += 1 }
      END { if (invalid || count == 0) exit 1 }
    ' "$scan_file" | "$CONTROLLER_LANDING_SORT_BIN" -u > "$public_key_file"; then
    return 1
  fi
  chmod 600 "$public_key_file" || return 1
  controller_landing_private_file_is_trusted "$public_key_file" || return 1
  key_count="$("$CONTROLLER_LANDING_AWK_BIN" 'END { print NR }' "$public_key_file")" || return 1
  [[ "$key_count" == 1 ]] || return 1
  fingerprint_line="$("$CONTROLLER_LANDING_SSH_KEYGEN_BIN" -l -E sha256 \
    -f "$public_key_file" 2>/dev/null)" || return 1
  [[ -n "$fingerprint_line" && "$fingerprint_line" != *$'\n'* ]] || return 1
  read -r key_bits actual_fingerprint remainder <<< "$fingerprint_line"
  [[ "$key_bits" == 256 && "$actual_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ &&
     -n "$remainder" ]] || return 1
  printf '%s\n' "$actual_fingerprint"
}

controller_landing_prepare_known_hosts() {
  local address="$1" ssh_port="$2" expected_fingerprint="$3" host_alias="$4" work="$5"
  local public_key_file="$work/host-key.pub" known_hosts_file="$work/known-hosts"
  local actual_fingerprint

  [[ "$expected_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || return 1
  [[ "$host_alias" =~ ^sb-landing-[a-z][a-z0-9-]{0,31}$ ]] || return 1
  controller_private_directory_is_trusted "$work" || return 1
  [[ ! -e "$known_hosts_file" && ! -L "$known_hosts_file" ]] || return 1
  actual_fingerprint="$(controller_landing_scan_ed25519_fingerprint \
    "$address" "$ssh_port" "$work")" || return 1
  [[ "$actual_fingerprint" == "$expected_fingerprint" ]] || return 1

  printf '%s %s\n' "$host_alias" "$(<"$public_key_file")" > "$known_hosts_file" || return 1
  chmod 600 "$known_hosts_file" || return 1
  controller_landing_private_file_is_trusted "$known_hosts_file" || return 1
  printf '%s\n' "$known_hosts_file"
}

controller_landing_known_hosts_is_valid() {
  local path="$1" host_alias="$2" expected_fingerprint="$3"
  local line_count host key_type key_blob extra fingerprint_line
  local key_bits actual_fingerprint remainder
  controller_landing_private_file_is_trusted "$path" || return 1
  [[ "$host_alias" =~ ^sb-landing-[a-z][a-z0-9-]{0,31}$ ]] || return 1
  [[ "$expected_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || return 1
  line_count="$("$CONTROLLER_LANDING_AWK_BIN" 'END { print NR }' "$path")" || return 1
  [[ "$line_count" == 1 ]] || return 1
  read -r host key_type key_blob extra < "$path" || return 1
  [[ "$host" == "$host_alias" && "$key_type" == ssh-ed25519 &&
     "$key_blob" =~ ^[A-Za-z0-9+/]+={0,2}$ && -z "$extra" ]] || return 1
  fingerprint_line="$("$CONTROLLER_LANDING_SSH_KEYGEN_BIN" -l -E sha256 \
    -f "$path" 2>/dev/null)" || return 1
  [[ -n "$fingerprint_line" && "$fingerprint_line" != *$'\n'* ]] || return 1
  read -r key_bits actual_fingerprint remainder <<< "$fingerprint_line"
  [[ "$key_bits" == 256 && "$actual_fingerprint" == "$expected_fingerprint" &&
     -n "$remainder" ]]
}

controller_landing_response_file_is_safe() {
  local response_file="$1" ssh_status="$2" size response_status
  [[ "$ssh_status" =~ ^[0-9]+$ ]] || return 1
  controller_landing_private_file_is_trusted "$response_file" || return 1
  size="$(controller_landing_file_size "$response_file")" || return 1
  ((size >= 1 && size <= CONTROLLER_LANDING_RESPONSE_MAX_BYTES)) || return 1
  jq -e -s '
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
  ' "$response_file" >/dev/null 2>&1 || return 1
  response_status="$(jq -r '.status' "$response_file")" || return 1
  if ((ssh_status == 0)); then
    [[ "$response_status" == applied || "$response_status" == idempotent ]]
  else
    [[ "$response_status" == error ]]
  fi
}

controller_landing_ssh_exchange() {
  local address="$1" ssh_port="$2" landing_id="$3" private_key="$4"
  local known_hosts="$5" expected_fingerprint="$6" package_fd="$7" response_file="$8"
  local host_alias
  local ssh_status=0
  CONTROLLER_LANDING_LAST_SSH_STATUS=""
  host_alias="sb-landing-$landing_id"
  controller_landing_address_is_valid "$address" || return 1
  landing_port_is_valid "$ssh_port" || return 1
  landing_id_is_valid "$landing_id" || return 1
  controller_landing_ssh_private_key_is_valid "$private_key" || return 1
  controller_landing_known_hosts_is_valid "$known_hosts" "$host_alias" \
    "$expected_fingerprint" || return 1
  [[ "$package_fd" =~ ^[0-9]+$ && -r "/dev/fd/$package_fd" ]] || return 1
  [[ ! -e "$response_file" && ! -L "$response_file" ]] || return 1

  if (
    umask 077
    ulimit -f 4 || exit 70
    exec "$CONTROLLER_LANDING_TIMEOUT_BIN" -k "$CONTROLLER_LANDING_SESSION_KILL_AFTER" \
      "$CONTROLLER_LANDING_SESSION_TIMEOUT" \
      "$CONTROLLER_LANDING_SSH_BIN" -F /dev/null -T -p "$ssh_port" \
      -i "$private_key" \
      -o BatchMode=yes \
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
      -o IdentityAgent=none \
      -o KbdInteractiveAuthentication=no \
      -o LogLevel=ERROR \
      -o NumberOfPasswordPrompts=0 \
      -o PasswordAuthentication=no \
      -o PermitLocalCommand=no \
      -o PreferredAuthentications=publickey \
      -o ProxyCommand=none \
      -o ProxyJump=none \
      -o RequestTTY=no \
      -o PubkeyAcceptedAlgorithms=ssh-ed25519 \
      -o StrictHostKeyChecking=yes \
      -o Tunnel=no \
      -o UpdateHostKeys=no \
      -o "UserKnownHostsFile=$known_hosts" \
      -o "User=$CONTROLLER_LANDING_SSH_ACCOUNT" \
      -o VerifyHostKeyDNS=no \
      "$address"
  ) <&"$package_fd" > "$response_file" 2>/dev/null; then
    ssh_status=0
  else
    ssh_status=$?
  fi
  CONTROLLER_LANDING_LAST_SSH_STATUS="$ssh_status"
  chmod 600 "$response_file" 2>/dev/null || return 1
  controller_landing_response_file_is_safe "$response_file" "$ssh_status" || return 1
  ((ssh_status == 0))
}

controller_landing_commit_success() {
  local landing_id="$1" snapshot="$2" response_file="$3" expected_revision="$4"
  local expected_sha256="$5" response_status response_revision response_sha256
  landing_id_is_valid "$landing_id" || return 1
  controller_landing_private_file_is_trusted "$snapshot" || return 1
  controller_landing_private_file_is_trusted "$response_file" || return 1
  controller_landing_response_file_is_safe "$response_file" 0 || return 1
  landing_safe_integer_is_valid "$expected_revision" || return 1
  [[ "$expected_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
  response_status="$(jq -r '.status' "$response_file")" || return 1
  response_revision="$(jq -r '.revision' "$response_file")" || return 1
  response_sha256="$(jq -r '.content_sha256' "$response_file")" || return 1
  [[ "$response_status" == applied || "$response_status" == idempotent ]] || return 1
  [[ "$response_revision" == "$expected_revision" &&
     "$response_sha256" == "$expected_sha256" ]] || return 1

  atomic_controller_state_update '
    ([.landings[] | select(.id == $landing_id)] | first) as $current |
    if $current == $expected[0] then
      if ($current.applied_revision == $revision and
          $current.config_sha256 == $sha256 and
          $current.status == "active") then .
      elif .revision < 9007199254740991 then
        .revision += 1 |
        .landings |= map(
          if .id == $landing_id then
            .applied_revision = $revision |
            .config_sha256 = $sha256 |
            .status = "active"
          else . end
        )
      else error("controller revision exhausted") end
    else error("stale landing state") end
  ' --arg landing_id "$landing_id" --slurpfile expected "$snapshot" \
    --argjson revision "$expected_revision" --arg sha256 "$expected_sha256"
}

controller_apply_landing_in_work() {
  local landing_id="$1" allowed_entry_ipv4="$2" work="$3"
  local snapshot="$work/landing.json" known_hosts package="$work/apply.json"
  local response_file="$work/response.json" address ssh_port expected_fingerprint
  local gateway_port desired_revision credential_ref private_key issued_at expires_at nonce
  local package_fd expected_sha256
  controller_landing_transport_runtime_is_safe || return 1
  is_ipv4_address "$allowed_entry_ipv4" || return 1
  controller_landing_write_snapshot "$landing_id" "$snapshot" || return 1
  IFS=$'\t' read -r address ssh_port expected_fingerprint gateway_port \
    desired_revision credential_ref < <(
      jq -r '[.address, .ssh_port, .ssh_host_fingerprint, .gateway_port,
        .desired_revision, .credential_ref] | @tsv' "$snapshot"
    ) || return 1
  [[ -n "$credential_ref" ]] || return 1
  validate_landing_credential_manifest "$credential_ref" || return 1
  [[ "$(jq -r '.landing_id' "$credential_ref")" == "$landing_id" ]] || return 1
  private_key="$(jq -r '.ssh_private_key_file' "$credential_ref")" || return 1
  controller_landing_ssh_private_key_is_valid "$private_key" || return 1

  known_hosts="$(controller_landing_prepare_known_hosts "$address" "$ssh_port" \
    "$expected_fingerprint" "sb-landing-$landing_id" "$work")" || return 1
  issued_at="$(date +%s)" || return 1
  landing_safe_integer_is_valid "$issued_at" || return 1
  expires_at=$((10#$issued_at + CONTROLLER_LANDING_PACKAGE_TTL))
  nonce="$(openssl rand -hex 32 2>/dev/null)" || return 1
  landing_nonce_is_valid "$nonce" || return 1
  build_landing_apply_package "$credential_ref" "$allowed_entry_ipv4" "$gateway_port" \
    "$desired_revision" "$issued_at" "$expires_at" "$nonce" "$package" || return 1
  controller_landing_private_file_is_trusted "$package" || return 1
  expected_sha256="$(jq -r '.content_sha256' "$package")" || return 1
  [[ "$expected_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
  exec {package_fd}< "$package" || return 1
  rm -f -- "$package" || return 1
  sync_transaction_path "$work" || return 1
  controller_landing_ssh_exchange "$address" "$ssh_port" "$landing_id" "$private_key" \
    "$known_hosts" "$expected_fingerprint" "$package_fd" "$response_file" || return 1
  controller_landing_commit_success "$landing_id" "$snapshot" "$response_file" \
    "$desired_revision" "$expected_sha256"
}

controller_apply_landing() {
  local landing_id="${1:-}" allowed_entry_ipv4="${2:-}" work rc=1
  [[ $# -eq 2 ]] || return 1
  landing_id_is_valid "$landing_id" || return 1
  is_ipv4_address "$allowed_entry_ipv4" || return 1
  work="$(controller_landing_create_work_directory)" || return 1
  register_temp_path "$work" || { controller_landing_remove_work_directory "$work"; return 1; }
  if (controller_apply_landing_in_work "$landing_id" "$allowed_entry_ipv4" "$work"); then
    rc=0
  fi
  controller_landing_remove_work_directory "$work" || rc=1
  return "$rc"
}
