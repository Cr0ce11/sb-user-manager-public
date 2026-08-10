# ============================================================
# v5 受限落地 SSH 通道安装层（尚未接入菜单或远程注册）
# ============================================================

LANDING_CHANNEL_SCHEMA_VERSION=1
LANDING_CHANNEL_ACCOUNT=sb-landing-agent
LANDING_CHANNEL_GROUP=sb-landing-agent
LANDING_CHANNEL_GECOS='sb-user-manager landing channel'
LANDING_CHANNEL_HOME=/var/lib/sb-user-manager-landing
LANDING_CHANNEL_GENERATION_PATH=/var/lib/sb-user-manager-landing/.channel-generation
LANDING_CHANNEL_SSH_DIRECTORY=/var/lib/sb-user-manager-landing/.ssh
LANDING_CHANNEL_AUTHORIZED_KEYS_PATH=/var/lib/sb-user-manager-landing/.ssh/authorized_keys
LANDING_CHANNEL_AGENT_PATH=/usr/local/bin/sb-user-manager-landing-agent
LANDING_CHANNEL_RUNTIME_DIRECTORY=/usr/local/libexec/sb-user-manager
LANDING_CHANNEL_RUNTIME_PATH=/usr/local/libexec/sb-user-manager/landing-runtime.sh
LANDING_CHANNEL_SUDOERS_PATH=/etc/sudoers.d/sb-user-manager-landing-agent
LANDING_CHANNEL_IDENTITY_PATH=/var/lib/sb-user-manager/landing-channel.json
LANDING_CHANNEL_LOCK_PATH=/var/lib/sb-user-manager/landing-channel.lock
LANDING_CHANNEL_INPUT_LOCK_PATH=/var/lib/sb-user-manager/landing-channel-input.lock
LANDING_CHANNEL_TRANSACTION_DIRECTORY=/var/lib/sb-user-manager/landing-channel-transaction
LANDING_CHANNEL_TRANSACTION_JOURNAL=/var/lib/sb-user-manager/landing-channel-transaction/journal.json
LANDING_CHANNEL_TRANSACTION_SCHEMA_VERSION=1
LANDING_CHANNEL_LOCK_TIMEOUT=30
LANDING_CHANNEL_SHELL=/bin/sh
LANDING_CHANNEL_PASSWORD_VALUE='*NP*'

LANDING_CHANNEL_ACTIVE_MODE=""
LANDING_CHANNEL_ACTIVE_WORK=""
LANDING_CHANNEL_ACTIVE_UID=""
LANDING_CHANNEL_ACTIVE_GID=""
LANDING_CHANNEL_ACTIVE_PHASE=""
LANDING_CHANNEL_ACTIVE_TRANSACTION_ID=""
LANDING_CHANNEL_GROUP_ATTEMPTED=false
LANDING_CHANNEL_USER_ATTEMPTED=false
LANDING_CHANNEL_BOOTSTRAP_RUNTIME_FD=""
LANDING_CHANNEL_BOOTSTRAP_RUNTIME_SHA256=""

manager_file_gid() {
  stat -c '%g' -- "$1" 2>/dev/null || stat -f '%g' "$1" 2>/dev/null
}

landing_channel_expected_root_uid() {
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true && "$EUID" -ne 0 ]]; then
    printf '%s\n' "$EUID"
  else
    printf '0\n'
  fi
}

landing_channel_expected_root_gid() {
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true && "$EUID" -ne 0 ]]; then
    id -g
  else
    printf '0\n'
  fi
}

landing_channel_path() {
  local logical="$1"
  [[ "$logical" == /* ]] || return 1
  system_path "$logical"
}

landing_channel_apply_transaction_setting_is_safe() {
  local fixed_path=/var/lib/sb-user-manager/landing-apply-transaction
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true &&
        -n "${SB_LANDING_APPLY_TRANSACTION_DIRECTORY:-}" ]]; then
    [[ "$SB_LANDING_APPLY_TRANSACTION_DIRECTORY" == /* &&
       "$SB_LANDING_APPLY_TRANSACTION_DIRECTORY" != *$'\n'* ]]
    return
  fi
  [[ "${LANDING_APPLY_TRANSACTION_DIRECTORY:-}" == "$fixed_path" ]] || return 1
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    [[ -z "${SB_LANDING_APPLY_TRANSACTION_DIRECTORY:-}" ]] || return 1
  fi
}

landing_channel_runtime_paths_are_safe() {
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true && -n "${SB_SYSTEM_ROOT:-}" ]]; then
    return 1
  fi
  landing_channel_apply_transaction_setting_is_safe || return 1
  [[ "$LANDING_CHANNEL_ACCOUNT" == sb-landing-agent &&
     "$LANDING_CHANNEL_GROUP" == sb-landing-agent &&
     "$LANDING_CHANNEL_HOME" == /var/lib/sb-user-manager-landing &&
     "$LANDING_CHANNEL_GENERATION_PATH" == /var/lib/sb-user-manager-landing/.channel-generation &&
     "$LANDING_CHANNEL_SSH_DIRECTORY" == /var/lib/sb-user-manager-landing/.ssh &&
     "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH" == /var/lib/sb-user-manager-landing/.ssh/authorized_keys &&
     "$LANDING_CHANNEL_AGENT_PATH" == /usr/local/bin/sb-user-manager-landing-agent &&
     "$LANDING_CHANNEL_RUNTIME_DIRECTORY" == /usr/local/libexec/sb-user-manager &&
     "$LANDING_CHANNEL_RUNTIME_PATH" == /usr/local/libexec/sb-user-manager/landing-runtime.sh &&
     "$LANDING_AGENT_HELPER_PATH" == /usr/local/libexec/sb-user-manager-landing-apply &&
     "$LANDING_CHANNEL_SUDOERS_PATH" == /etc/sudoers.d/sb-user-manager-landing-agent &&
     "$LANDING_CHANNEL_IDENTITY_PATH" == /var/lib/sb-user-manager/landing-channel.json &&
     "$LANDING_CHANNEL_LOCK_PATH" == /var/lib/sb-user-manager/landing-channel.lock &&
     "$LANDING_CHANNEL_INPUT_LOCK_PATH" == /var/lib/sb-user-manager/landing-channel-input.lock &&
     "$LANDING_CHANNEL_TRANSACTION_DIRECTORY" == /var/lib/sb-user-manager/landing-channel-transaction &&
     "$LANDING_CHANNEL_TRANSACTION_JOURNAL" == /var/lib/sb-user-manager/landing-channel-transaction/journal.json &&
     "$LANDING_STARTUP_RECOVERY_UNIT_PATH" == /etc/systemd/system/sb-user-manager-landing-recovery.service &&
     "$LANDING_STARTUP_RECOVERY_DROPIN_DIRECTORY" == /etc/systemd/system/sing-box.service.d &&
     "$LANDING_STARTUP_RECOVERY_DROPIN_PATH" == /etc/systemd/system/sing-box.service.d/10-sb-user-manager-landing-recovery.conf &&
     "$LANDING_CHANNEL_TRANSACTION_SCHEMA_VERSION" == 1 &&
     "$LANDING_CHANNEL_LOCK_TIMEOUT" == 30 &&
     "$LANDING_CHANNEL_SHELL" == /bin/sh &&
     "$LANDING_CHANNEL_PASSWORD_VALUE" == '*NP*' ]]
}

landing_channel_root_executable_is_safe() {
  local path="$1" resolved uid mode
  [[ -x "$path" ]] || return 1
  resolved="$(readlink -f -- "$path")" || return 1
  [[ -f "$resolved" && ! -L "$resolved" && -x "$resolved" ]] || return 1
  uid="$(manager_file_uid "$resolved")" || return 1
  mode="$(manager_file_mode "$resolved")" || return 1
  [[ "$uid" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0022) == 0 ))
}

landing_channel_dependencies_are_ready() {
  [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]] && return 0
  local dependency dependency_name
  for dependency in \
    /bin/bash /bin/sh /usr/bin/getent /usr/bin/head /usr/bin/id /usr/bin/ps \
    /usr/bin/openssl /usr/bin/python3 /usr/bin/ssh-keygen /usr/bin/systemctl /usr/bin/timeout \
    /usr/bin/uname \
    /usr/bin/sudo /usr/sbin/groupadd /usr/sbin/groupdel /usr/sbin/useradd \
    /usr/sbin/userdel /usr/sbin/visudo; do
    landing_channel_root_executable_is_safe "$dependency" || return 1
  done
  for dependency_name in \
    awk cat chmod chown cmp dirname flock install jq mktemp mv nft readlink \
    rm rmdir sha256sum stat sync tr wc; do
    dependency="$(command -v "$dependency_name")" || return 1
    [[ "$dependency" == /* ]] || return 1
    landing_channel_root_executable_is_safe "$dependency" || return 1
  done
}

landing_channel_system_get_user() {
  /usr/bin/getent passwd "$1"
}

landing_channel_system_get_shadow() {
  /usr/bin/getent shadow "$1"
}

landing_channel_system_get_group() {
  /usr/bin/getent group "$1"
}

landing_channel_system_user_groups() {
  /usr/bin/id -G "$1"
}

landing_channel_system_groupadd() {
  /usr/sbin/groupadd --system "$@"
}

landing_channel_system_useradd() {
  /usr/sbin/useradd --system "$@"
}

landing_channel_system_userdel() {
  /usr/sbin/userdel "$1"
}

landing_channel_system_groupdel() {
  /usr/sbin/groupdel "$1"
}

landing_channel_process_table_has_no_live_uid() {
  local expected_uid="$1" process_uid process_state extra saw_valid_row=false
  local process_state_pattern='^[DIRSTtWXZ][<NLsl+]*$'
  [[ "$expected_uid" =~ ^[0-9]+$ && "$expected_uid" != 0 ]] || return 1
  while read -r process_uid process_state extra; do
    [[ -n "$process_uid" ]] || continue
    [[ "$process_uid" =~ ^[0-9]+$ &&
       "$process_state" =~ $process_state_pattern && -z "$extra" ]] ||
      return 1
    saw_valid_row=true
    if [[ "$process_uid" == "$expected_uid" && "$process_state" != Z* ]]; then
      return 1
    fi
  done
  [[ "$saw_valid_row" == true ]] || return 1
  return 0
}

landing_channel_system_process_table() {
  /usr/bin/ps -eo uid=,stat=
}

landing_channel_account_has_no_processes() {
  local expected_uid="$1"
  [[ "$expected_uid" =~ ^[0-9]+$ && "$expected_uid" != 0 ]] || return 1
  landing_channel_system_process_table 2>/dev/null |
    landing_channel_process_table_has_no_live_uid "$expected_uid" ||
    return 1
  return 0
}

landing_channel_system_visudo_check() {
  /usr/sbin/visudo -cf "$1" >/dev/null
}

landing_channel_sync_account_database() {
  local etc
  etc="$(landing_channel_path /etc)" || return 1
  sync_transaction_path "$etc"
}

landing_channel_apply_ownership() {
  local path="$1" uid="$2" gid="$3"
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true && "$EUID" -ne 0 ]]; then
    [[ "$(manager_file_uid "$path")" == "$uid" && "$(manager_file_gid "$path")" == "$gid" ]]
    return
  fi
  chown "$uid:$gid" -- "$path" || return 1
}

landing_channel_directory_matches() {
  local path="$1" mode="$2" uid="$3" gid="$4" actual_mode
  [[ -d "$path" && ! -L "$path" ]] || return 1
  [[ "$(manager_file_uid "$path")" == "$uid" ]] || return 1
  [[ "$(manager_file_gid "$path")" == "$gid" ]] || return 1
  actual_mode="$(manager_file_mode "$path")" || return 1
  [[ "$actual_mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$actual_mode & 07777) == 8#$mode ))
}

landing_channel_file_matches() {
  local path="$1" mode="$2" uid="$3" gid="$4" actual_mode
  [[ -f "$path" && ! -L "$path" ]] || return 1
  [[ "$(manager_file_uid "$path")" == "$uid" ]] || return 1
  [[ "$(manager_file_gid "$path")" == "$gid" ]] || return 1
  actual_mode="$(manager_file_mode "$path")" || return 1
  [[ "$actual_mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$actual_mode & 07777) == 8#$mode ))
}

landing_channel_system_directory_is_safe() {
  local path="$1" uid gid mode expected_uid expected_gid
  [[ -d "$path" && ! -L "$path" ]] || return 1
  uid="$(manager_file_uid "$path")" || return 1
  gid="$(manager_file_gid "$path")" || return 1
  mode="$(manager_file_mode "$path")" || return 1
  expected_uid="$(landing_channel_expected_root_uid)" || return 1
  expected_gid="$(landing_channel_expected_root_gid)" || return 1
  [[ "$uid" == "$expected_uid" && "$gid" == "$expected_gid" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0700) == 0700 && (8#$mode & 0022) == 0 ))
}

landing_channel_system_directory_is_channel_traversable() {
  local path="$1" mode
  landing_channel_system_directory_is_safe "$path" || return 1
  mode="$(manager_file_mode "$path")" || return 1
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0001) == 0001 ))
}

landing_channel_install_system_paths_are_safe() {
  local system_root logical path
  system_root="${SB_SYSTEM_ROOT:-/}"
  landing_channel_system_directory_is_safe "$system_root" || return 1
  for logical in \
    /usr /usr/local /usr/local/bin /usr/local/libexec \
    /etc /etc/sudoers.d /etc/systemd /etc/systemd/system \
    "$LANDING_STARTUP_RECOVERY_DROPIN_DIRECTORY" /var /var/lib; do
    path="$(landing_channel_path "$logical")" || return 1
    [[ ! -L "$path" ]] || return 1
    [[ -e "$path" ]] || continue
    case "$logical" in
      /usr|/usr/local|/usr/local/bin|/usr/local/libexec|/var|/var/lib)
        landing_channel_system_directory_is_channel_traversable "$path" || return 1
        ;;
      *) landing_channel_system_directory_is_safe "$path" || return 1 ;;
    esac
  done
}

landing_channel_directory_is_root_controlled() {
  local path="$1" uid mode expected_uid
  [[ -d "$path" && ! -L "$path" ]] || return 1
  uid="$(manager_file_uid "$path")" || return 1
  mode="$(manager_file_mode "$path")" || return 1
  expected_uid="$(landing_channel_expected_root_uid)" || return 1
  [[ "$uid" == "$expected_uid" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0700) == 0700 && (8#$mode & 0022) == 0 ))
}

landing_channel_ensure_system_directory() {
  local logical="$1" path parent uid gid
  path="$(landing_channel_path "$logical")" || return 1
  parent="$(dirname -- "$path")" || return 1
  landing_channel_system_directory_is_safe "$parent" || return 1
  if [[ -e "$path" || -L "$path" ]]; then
    landing_channel_system_directory_is_safe "$path"
    return
  fi
  uid="$(landing_channel_expected_root_uid)" || return 1
  gid="$(landing_channel_expected_root_gid)" || return 1
  install -d -m 755 -- "$path" || return 1
  landing_channel_apply_ownership "$path" "$uid" "$gid" || return 1
  landing_channel_system_directory_is_safe "$path" || return 1
  sync_transaction_path "$path" || return 1
  sync_transaction_path "$parent" || return 1
}

landing_channel_ensure_owned_directory() {
  local logical="$1" mode="$2" uid="$3" gid="$4" path parent root_uid root_gid allowed allowed_extra=""
  path="$(landing_channel_path "$logical")" || return 1
  parent="$(dirname -- "$path")" || return 1
  landing_channel_directory_is_root_controlled "$parent" || return 1
  if [[ -e "$path" || -L "$path" ]]; then
    if landing_channel_directory_matches "$path" "$mode" "$uid" "$gid"; then
      sync_transaction_path "$path" || return 1
      sync_transaction_path "$parent" || return 1
      return 0
    fi
    # install -d 与 chown 之间被中断时会留下 root:root 的确定性目录。
    # 只有持久事务中的三处专用目录、且内容仍在允许集合内时才接续该过渡态。
    [[ -n "$LANDING_CHANNEL_ACTIVE_MODE" &&
       "$LANDING_CHANNEL_ACTIVE_WORK" == "$(landing_channel_path "$LANDING_CHANNEL_TRANSACTION_DIRECTORY")" ]] || return 1
    root_uid="$(landing_channel_expected_root_uid)" || return 1
    root_gid="$(landing_channel_expected_root_gid)" || return 1
    [[ "$uid" == "$root_uid" ]] || return 1
    if ! landing_channel_directory_matches "$path" "$mode" "$root_uid" "$root_gid" &&
       ! landing_channel_directory_matches "$path" 700 "$root_uid" "$root_gid"; then
      return 1
    fi
    case "$logical" in
      "$LANDING_CHANNEL_RUNTIME_DIRECTORY") allowed="$(landing_channel_path "$LANDING_CHANNEL_RUNTIME_PATH")" ;;
      "$LANDING_CHANNEL_HOME")
        allowed="$(landing_channel_path "$LANDING_CHANNEL_GENERATION_PATH")" || return 1
        allowed_extra="$(landing_channel_path "$LANDING_CHANNEL_SSH_DIRECTORY")" || return 1
        ;;
      "$LANDING_CHANNEL_SSH_DIRECTORY") allowed="$(landing_channel_path "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH")" ;;
      *) return 1 ;;
    esac
    landing_channel_directory_contains_only "$path" "$allowed" "$allowed_extra" || return 1
    chmod "$mode" "$path" || return 1
    landing_channel_apply_ownership "$path" "$uid" "$gid" || return 1
    landing_channel_directory_matches "$path" "$mode" "$uid" "$gid" || return 1
    sync_transaction_path "$path" || return 1
    sync_transaction_path "$parent" || return 1
    return 0
  fi
  install -d -m "$mode" -- "$path" || return 1
  landing_channel_apply_ownership "$path" "$uid" "$gid" || return 1
  landing_channel_directory_matches "$path" "$mode" "$uid" "$gid" || return 1
  sync_transaction_path "$path" || return 1
  sync_transaction_path "$parent" || return 1
}

landing_channel_atomic_install_file() {
  local source="$1" logical_target="$2" mode="$3" uid="$4" gid="$5"
  local target parent tmp transaction_id
  [[ -f "$source" && ! -L "$source" && "$logical_target" == /* ]] || return 1
  transaction_id="$LANDING_CHANNEL_ACTIVE_TRANSACTION_ID"
  [[ "$transaction_id" =~ ^[0-9a-f]{32}$ ]] || return 1
  target="$(landing_channel_path "$logical_target")" || return 1
  parent="$(dirname -- "$target")" || return 1
  landing_channel_directory_is_root_controlled "$parent" || return 1
  if [[ -e "$target" || -L "$target" ]]; then
    [[ -f "$target" && ! -L "$target" ]] || return 1
  fi
  tmp="$(mktemp "$parent/.landing-channel.${transaction_id}.XXXXXX")" || return 1
  register_temp_path "$tmp" || { rm -f -- "$tmp" || true; return 1; }
  if ! install -m "$mode" -- "$source" "$tmp" ||
     ! landing_channel_apply_ownership "$tmp" "$uid" "$gid" ||
     ! cmp -s -- "$source" "$tmp" ||
     ! landing_channel_file_matches "$tmp" "$mode" "$uid" "$gid" ||
     ! sync_transaction_path "$tmp" ||
     ! mv -- "$tmp" "$target" ||
     ! sync_transaction_path "$parent"; then
    rm -f -- "$tmp" || true
    return 1
  fi
}

landing_channel_sha256() {
  sha256sum "$1" | awk '{print $1}' || return 1
}

landing_channel_normalize_public_key() {
  local source="$1" output="$2" content key_blob fingerprint
  [[ -f "$source" && ! -L "$source" && -r "$source" ]] || return 1
  [[ "$(wc -c < "$source" | tr -d ' ')" -le 1024 ]] || return 1
  content="$(<"$source")" || return 1
  [[ -n "$content" && "$content" != *$'\n'* && "$content" != *$'\r'* ]] || return 1
  [[ "$content" =~ ^ssh-ed25519[[:space:]]+([A-Za-z0-9+/]+={0,3})([[:space:]][^[:cntrl:]]*)?$ ]] || return 1
  key_blob="${BASH_REMATCH[1]}"
  printf 'ssh-ed25519 %s\n' "$key_blob" > "$output" || return 1
  chmod 600 "$output" || return 1
  fingerprint="$(ssh-keygen -lf "$output" -E sha256 2>/dev/null | awk 'NR == 1 {print $2}')" || return 1
  [[ "$fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{20,}={0,2}$ ]]
}

landing_channel_public_key_fingerprint() {
  local key="$1" fingerprint
  fingerprint="$(ssh-keygen -lf "$key" -E sha256 2>/dev/null | awk 'NR == 1 {print $2}')" || return 1
  [[ "$fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{20,}={0,2}$ ]] || return 1
  printf '%s\n' "$fingerprint"
}

landing_channel_public_key_text_fingerprint() {
  local public_key="$1" fingerprint
  [[ "$public_key" =~ ^ssh-ed25519[[:space:]]+[A-Za-z0-9+/]+={0,3}$ ]] || return 1
  fingerprint="$(printf '%s\n' "$public_key" |
    ssh-keygen -lf - -E sha256 2>/dev/null | awk 'NR == 1 {print $2}')" || return 1
  [[ "$fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{20,}={0,2}$ ]] || return 1
  printf '%s\n' "$fingerprint"
}

landing_channel_binding_generation_from_values() {
  local landing_id="$1" allowed_ipv4="$2" public_key="$3" generation
  landing_id_is_valid "$landing_id" || return 1
  is_public_ipv4 "$allowed_ipv4" || return 1
  [[ "$public_key" =~ ^ssh-ed25519[[:space:]]+[A-Za-z0-9+/]+={0,3}$ ]] || return 1
  generation="$(printf 'schema=1\nlanding_id=%s\nallowed_entry_ipv4=%s\npublic_key=%s\n' \
    "$landing_id" "$allowed_ipv4" "$public_key" | sha256sum | awk '{print $1}')" || return 1
  [[ "$generation" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$generation"
}

landing_channel_binding_generation() {
  local landing_id="$1" allowed_ipv4="$2" normalized_key="$3" public_key
  public_key="$(<"$normalized_key")" || return 1
  landing_channel_binding_generation_from_values "$landing_id" "$allowed_ipv4" "$public_key"
}

landing_channel_render_agent_launcher() {
  local output="$1"
  cat > "$output" <<'PY' || return 1
#!/usr/bin/python3 -I
import os
import sys

safe_env = {
    "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
    "LC_ALL": "C",
}
for name in ("SSH_CONNECTION", "SSH_ORIGINAL_COMMAND", "SSH_TTY"):
    if name in os.environ:
        safe_env[name] = os.environ[name]

command = r'''
exec 8< /usr/local/libexec/sb-user-manager/landing-runtime.sh || exit 78
exec 9< /usr/local/libexec/sb-user-manager/landing-runtime.sh || exit 78
LANDING_RUNTIME_FD8_ID="$(stat -Lc '%d:%i' /proc/self/fd/8)" || exit 78
LANDING_RUNTIME_FD9_ID="$(stat -Lc '%d:%i' /proc/self/fd/9)" || exit 78
[[ -n "$LANDING_RUNTIME_FD8_ID" && "$LANDING_RUNTIME_FD8_ID" == "$LANDING_RUNTIME_FD9_ID" ]] || exit 78
LANDING_LOADED_RUNTIME_SHA256="$(sha256sum /proc/self/fd/8)" || exit 78
LANDING_LOADED_RUNTIME_SHA256="${LANDING_LOADED_RUNTIME_SHA256%% *}"
[[ "$LANDING_LOADED_RUNTIME_SHA256" =~ ^[0-9a-f]{64}$ ]] || exit 78
SB_USER_MANAGER_LIBRARY=true
. /proc/self/fd/9 || exit 78
exec 8<&- 9<&-
SB_USER_MANAGER_LIBRARY=false
install_landing_apply_runtime_traps
landing_agent_main "$@"
'''
argv = [
    "sb-user-manager-landing-agent", "--noprofile", "--norc", "-c", command,
    "sb-user-manager-landing-agent", *sys.argv[1:]
]
try:
    os.execve("/bin/bash", argv, safe_env)
except OSError:
    os.write(1, b'{"status":"error","code":"launcher_failed"}\n')
    raise SystemExit(1)
PY
  chmod 600 "$output" || return 1
}

landing_channel_render_helper_launcher() {
  local output="$1"
  cat > "$output" <<'PY' || return 1
#!/usr/bin/python3 -I
import os
import sys

safe_env = {
    "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
    "LC_ALL": "C",
}
command = r'''
exec 8< /usr/local/libexec/sb-user-manager/landing-runtime.sh || exit 78
exec 9< /usr/local/libexec/sb-user-manager/landing-runtime.sh || exit 78
LANDING_RUNTIME_FD8_ID="$(stat -Lc '%d:%i' /proc/self/fd/8)" || exit 78
LANDING_RUNTIME_FD9_ID="$(stat -Lc '%d:%i' /proc/self/fd/9)" || exit 78
[[ -n "$LANDING_RUNTIME_FD8_ID" && "$LANDING_RUNTIME_FD8_ID" == "$LANDING_RUNTIME_FD9_ID" ]] || exit 78
LANDING_LOADED_RUNTIME_SHA256="$(sha256sum /proc/self/fd/8)" || exit 78
LANDING_LOADED_RUNTIME_SHA256="${LANDING_LOADED_RUNTIME_SHA256%% *}"
[[ "$LANDING_LOADED_RUNTIME_SHA256" =~ ^[0-9a-f]{64}$ ]] || exit 78
SB_USER_MANAGER_LIBRARY=true
. /proc/self/fd/9 || exit 78
exec 8<&- 9<&-
SB_USER_MANAGER_LIBRARY=false
install_landing_apply_runtime_traps
if [[ "${1:-}" == "$LANDING_STARTUP_RECOVERY_MODE_ARGUMENT" ]]; then
  shift
  landing_startup_recovery_main "$@"
else
  landing_apply_helper_main "$@"
fi
'''
argv = [
    "sb-user-manager-landing-apply", "--noprofile", "--norc", "-c", command,
    "sb-user-manager-landing-apply", *sys.argv[1:]
]
try:
    os.execve("/bin/bash", argv, safe_env)
except OSError:
    os.write(1, b'{"status":"error","code":"launcher_failed"}\n')
    raise SystemExit(1)
PY
  chmod 600 "$output" || return 1
}

landing_channel_render_sudoers() {
  local output="$1" generation="$2"
  [[ "$generation" =~ ^[0-9a-f]{64}$ ]] || return 1
  cat > "$output" <<EOF || return 1
Defaults:${LANDING_CHANNEL_ACCOUNT} env_reset
Defaults:${LANDING_CHANNEL_ACCOUNT} secure_path=/usr/sbin:/usr/bin:/sbin:/bin
Defaults:${LANDING_CHANNEL_ACCOUNT} !set_home
${LANDING_CHANNEL_ACCOUNT} ALL=(root) NOPASSWD:NOSETENV:NOLOG_INPUT:NOLOG_OUTPUT: ${LANDING_AGENT_HELPER_PATH} ${generation}
EOF
  chmod 440 "$output" || return 1
}

landing_channel_render_authorized_keys() {
  local landing_id="$1" allowed_ipv4="$2" generation="$3" normalized_key="$4" output="$5" key_blob
  landing_id_is_valid "$landing_id" || return 1
  is_public_ipv4 "$allowed_ipv4" || return 1
  [[ "$generation" =~ ^[0-9a-f]{64}$ ]] || return 1
  key_blob="$(awk 'NR == 1 && $1 == "ssh-ed25519" {print $2}' "$normalized_key")" || return 1
  [[ "$key_blob" =~ ^[A-Za-z0-9+/]+={0,3}$ ]] || return 1
  printf 'restrict,from="%s",command="%s %s" ssh-ed25519 %s sb-user-manager:%s\n' \
    "$allowed_ipv4" "$LANDING_CHANNEL_AGENT_PATH" "$generation" "$key_blob" "$landing_id" > "$output" || return 1
  chmod 600 "$output" || return 1
}

landing_channel_runtime_source() {
  local source parent root_uid root_gid fd_identity expected_identity actual_sha
  if [[ -n "$LANDING_CHANNEL_BOOTSTRAP_RUNTIME_FD" ||
        -n "$LANDING_CHANNEL_BOOTSTRAP_RUNTIME_SHA256" ]]; then
    [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true &&
       "$LANDING_CHANNEL_BOOTSTRAP_RUNTIME_FD" =~ ^[0-9]+$ &&
       "$LANDING_CHANNEL_BOOTSTRAP_RUNTIME_SHA256" =~ ^[0-9a-f]{64}$ ]] || return 1
    source="/proc/self/fd/$LANDING_CHANNEL_BOOTSTRAP_RUNTIME_FD"
    [[ -r "$source" && -f "$source" ]] || return 1
    fd_identity="$(stat -Lc '%u:%g:%a:%d:%i' -- "$source" 2>/dev/null)" || return 1
    expected_identity="$(landing_channel_expected_root_uid):$(landing_channel_expected_root_gid):600:"
    [[ "$fd_identity" == "$expected_identity"* ]] || return 1
    actual_sha="$(sha256sum "$source" | awk '{print $1}')" || return 1
    [[ "$actual_sha" == "$LANDING_CHANNEL_BOOTSTRAP_RUNTIME_SHA256" ]] || return 1
    bash -n "$source" >/dev/null 2>&1 || return 1
    printf '%s\n' "$source"
    return
  fi
  source="$(landing_channel_path /usr/local/sbin/sb-user-manager)" || return 1
  parent="$(dirname -- "$source")" || return 1
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  landing_channel_system_directory_is_safe "$parent" || return 1
  landing_channel_file_matches "$source" 700 "$root_uid" "$root_gid" || return 1
  [[ -r "$source" ]] || return 1
  bash -n "$source" >/dev/null 2>&1 || return 1
  printf '%s\n' "$source"
}

landing_channel_prepare_candidates() {
  local landing_id="$1" allowed_ipv4="$2" public_key_file="$3" work="$4" source generation
  landing_id_is_valid "$landing_id" || return 1
  is_public_ipv4 "$allowed_ipv4" || return 1
  source="$(landing_channel_runtime_source)" || return 1
  landing_channel_normalize_public_key "$public_key_file" "$work/public-key" || return 1
  generation="$(landing_channel_binding_generation "$landing_id" "$allowed_ipv4" "$work/public-key")" || return 1
  printf '%s\n' "$generation" > "$work/generation" || return 1
  chmod 600 "$work/generation" || return 1
  install -m 600 -- "$source" "$work/runtime.sh" || return 1
  bash -n "$work/runtime.sh" || return 1
  landing_channel_render_agent_launcher "$work/agent" || return 1
  landing_channel_render_helper_launcher "$work/helper" || return 1
  python3 -I -c 'compile(open(__import__("sys").argv[1], encoding="utf-8").read(), __import__("sys").argv[1], "exec")' \
    "$work/agent" || return 1
  python3 -I -c 'compile(open(__import__("sys").argv[1], encoding="utf-8").read(), __import__("sys").argv[1], "exec")' \
    "$work/helper" || return 1
  landing_channel_render_sudoers "$work/sudoers" "$generation" || return 1
  landing_channel_system_visudo_check "$work/sudoers" || return 1
  landing_startup_render_recovery_unit "$work/startup-recovery.service" || return 1
  landing_startup_render_singbox_dropin "$work/singbox-recovery.conf" || return 1
  landing_channel_render_authorized_keys "$landing_id" "$allowed_ipv4" \
    "$generation" "$work/public-key" "$work/authorized_keys" || return 1
}

landing_channel_read_account() {
  local record
  record="$(landing_channel_system_get_user "$LANDING_CHANNEL_ACCOUNT")" || return 1
  IFS=: read -r LANDING_CHANNEL_FOUND_ACCOUNT _ LANDING_CHANNEL_FOUND_UID \
    LANDING_CHANNEL_FOUND_GID LANDING_CHANNEL_FOUND_GECOS LANDING_CHANNEL_FOUND_HOME \
    LANDING_CHANNEL_FOUND_SHELL <<<"$record"
  [[ "$LANDING_CHANNEL_FOUND_ACCOUNT" == "$LANDING_CHANNEL_ACCOUNT" &&
     "$LANDING_CHANNEL_FOUND_UID" =~ ^[0-9]+$ && "$LANDING_CHANNEL_FOUND_GID" =~ ^[0-9]+$ ]]
}

landing_channel_read_group() {
  local record password members
  record="$(landing_channel_system_get_group "$LANDING_CHANNEL_GROUP")" || return 1
  IFS=: read -r LANDING_CHANNEL_FOUND_GROUP password LANDING_CHANNEL_FOUND_GROUP_GID members <<<"$record"
  [[ "$LANDING_CHANNEL_FOUND_GROUP" == "$LANDING_CHANNEL_GROUP" &&
     "$LANDING_CHANNEL_FOUND_GROUP_GID" =~ ^[0-9]+$ && -z "$members" ]]
}

landing_channel_account_is_absent() {
  local lookup_rc
  if landing_channel_system_get_user "$LANDING_CHANNEL_ACCOUNT" >/dev/null 2>&1; then
    return 1
  else
    lookup_rc=$?
  fi
  [[ "$lookup_rc" == 2 ]] || return 1
  return 0
}

landing_channel_group_is_absent() {
  local lookup_rc
  if landing_channel_system_get_group "$LANDING_CHANNEL_GROUP" >/dev/null 2>&1; then
    return 1
  else
    lookup_rc=$?
  fi
  [[ "$lookup_rc" == 2 ]] || return 1
  return 0
}

landing_channel_remove_expected_group_if_present() {
  local expected_gid="$1" lookup_rc
  [[ "$expected_gid" =~ ^[0-9]+$ && "$expected_gid" != 0 ]] || return 1
  if landing_channel_system_get_group "$LANDING_CHANNEL_GROUP" >/dev/null 2>&1; then
    landing_channel_read_group || return 1
    [[ "$LANDING_CHANNEL_FOUND_GROUP_GID" == "$expected_gid" ]] || return 1
    landing_channel_system_groupdel "$LANDING_CHANNEL_GROUP" || return 1
    landing_channel_sync_account_database || return 1
    landing_channel_group_is_absent || return 1
    return 0
  else
    lookup_rc=$?
  fi
  [[ "$lookup_rc" == 2 ]] || return 1
  return 0
}

landing_channel_password_is_disabled() {
  local record account password rest
  record="$(landing_channel_system_get_shadow "$LANDING_CHANNEL_ACCOUNT")" || return 1
  IFS=: read -r account password rest <<<"$record"
  [[ "$account" == "$LANDING_CHANNEL_ACCOUNT" && "$password" == "$LANDING_CHANNEL_PASSWORD_VALUE" ]]
}

landing_channel_account_matches() {
  local expected_uid="$1" expected_gid="$2" groups
  landing_channel_read_account || return 1
  landing_channel_read_group || return 1
  [[ "$LANDING_CHANNEL_FOUND_UID" == "$expected_uid" &&
     "$LANDING_CHANNEL_FOUND_GID" == "$expected_gid" &&
     "$LANDING_CHANNEL_FOUND_GROUP_GID" == "$expected_gid" &&
     "$expected_uid" != 0 && "$expected_gid" != 0 &&
     "$LANDING_CHANNEL_FOUND_GECOS" == "$LANDING_CHANNEL_GECOS" &&
     "$LANDING_CHANNEL_FOUND_HOME" == "$LANDING_CHANNEL_HOME" &&
     "$LANDING_CHANNEL_FOUND_SHELL" == "$LANDING_CHANNEL_SHELL" ]] || return 1
  landing_channel_password_is_disabled || return 1
  groups="$(landing_channel_system_user_groups "$LANDING_CHANNEL_ACCOUNT")" || return 1
  [[ "$groups" == "$expected_gid" ]]
}

validate_landing_channel_identity_json() {
  local path="$1"
  jq -e -s 'length == 1' "$path" >/dev/null || return 1
  jq -e --argjson schema "$LANDING_CHANNEL_SCHEMA_VERSION" \
    --arg account "$LANDING_CHANNEL_ACCOUNT" --arg group "$LANDING_CHANNEL_GROUP" \
    --arg home "$LANDING_CHANNEL_HOME" --arg shell "$LANDING_CHANNEL_SHELL" \
    --arg generation_path "$LANDING_CHANNEL_GENERATION_PATH" \
    --arg agent "$LANDING_CHANNEL_AGENT_PATH" --arg helper "$LANDING_AGENT_HELPER_PATH" \
    --arg runtime "$LANDING_CHANNEL_RUNTIME_PATH" \
    --arg authorized_keys "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH" \
    --arg sudoers "$LANDING_CHANNEL_SUDOERS_PATH" '
      type == "object" and
      (keys | sort) == [
        "account", "agent_launcher_sha256", "agent_path", "allowed_entry_ipv4",
        "authorized_keys_path", "generation", "generation_path", "gid", "group",
        "helper_launcher_sha256", "helper_path",
        "home", "landing_id", "public_key", "public_key_fingerprint", "runtime_path",
        "runtime_sha256", "schema_version", "shell", "sudoers_path", "sudoers_sha256", "uid"
      ] and
      .schema_version == $schema and .account == $account and .group == $group and
      .home == $home and .shell == $shell and .agent_path == $agent and
      .generation_path == $generation_path and
      .helper_path == $helper and .runtime_path == $runtime and
      .authorized_keys_path == $authorized_keys and .sudoers_path == $sudoers and
      (.landing_id | type == "string" and test("^[a-z][a-z0-9-]{0,31}$")) and
      (.allowed_entry_ipv4 | type == "string" and length >= 7 and length <= 15) and
      (.uid | type == "number" and . == floor and . >= 1 and . <= 4294967294) and
      (.gid | type == "number" and . == floor and . >= 1 and . <= 4294967294) and
      (.generation | type == "string" and test("^[0-9a-f]{64}$")) and
      (.public_key | type == "string" and test("^ssh-ed25519 [A-Za-z0-9+/]+={0,3}$")) and
      (.public_key_fingerprint | type == "string" and test("^SHA256:[A-Za-z0-9+/]{20,}={0,2}$")) and
      all([.runtime_sha256, .agent_launcher_sha256, .helper_launcher_sha256, .sudoers_sha256][];
        type == "string" and test("^[0-9a-f]{64}$"))
    ' "$path" >/dev/null || return 1
  landing_id_is_valid "$(jq -r '.landing_id' "$path")" || return 1
  is_public_ipv4 "$(jq -r '.allowed_entry_ipv4' "$path")"
}

validate_landing_channel_identity_file() {
  local path="${1:-$(landing_channel_path "$LANDING_CHANNEL_IDENTITY_PATH")}" uid gid public_key fingerprint generation
  uid="$(landing_channel_expected_root_uid)" || return 1
  gid="$(landing_channel_expected_root_gid)" || return 1
  landing_channel_file_matches "$path" 600 "$uid" "$gid" || return 1
  validate_landing_channel_identity_json "$path" || return 1
  public_key="$(jq -r '.public_key' "$path")" || return 1
  fingerprint="$(landing_channel_public_key_text_fingerprint "$public_key")" || return 1
  [[ "$fingerprint" == "$(jq -r '.public_key_fingerprint' "$path")" ]] || return 1
  generation="$(landing_channel_binding_generation_from_values \
    "$(jq -r '.landing_id' "$path")" "$(jq -r '.allowed_entry_ipv4' "$path")" "$public_key")" || return 1
  [[ "$generation" == "$(jq -r '.generation' "$path")" ]]
}

landing_channel_render_identity() {
  local landing_id="$1" allowed_ipv4="$2" uid="$3" gid="$4" work="$5" output="$6"
  local public_key fingerprint generation expected_generation runtime_sha agent_sha helper_sha sudoers_sha
  public_key="$(<"$work/public-key")" || return 1
  fingerprint="$(landing_channel_public_key_fingerprint "$work/public-key")" || return 1
  generation="$(<"$work/generation")" || return 1
  expected_generation="$(landing_channel_binding_generation "$landing_id" "$allowed_ipv4" "$work/public-key")" || return 1
  [[ "$generation" == "$expected_generation" ]] || return 1
  runtime_sha="$(landing_channel_sha256 "$work/runtime.sh")" || return 1
  agent_sha="$(landing_channel_sha256 "$work/agent")" || return 1
  helper_sha="$(landing_channel_sha256 "$work/helper")" || return 1
  sudoers_sha="$(landing_channel_sha256 "$work/sudoers")" || return 1
  jq -n --argjson schema "$LANDING_CHANNEL_SCHEMA_VERSION" --arg landing_id "$landing_id" \
    --arg allowed_ipv4 "$allowed_ipv4" --arg account "$LANDING_CHANNEL_ACCOUNT" \
    --arg group "$LANDING_CHANNEL_GROUP" --argjson uid "$uid" --argjson gid "$gid" \
    --arg home "$LANDING_CHANNEL_HOME" --arg shell "$LANDING_CHANNEL_SHELL" \
    --arg public_key "$public_key" --arg fingerprint "$fingerprint" \
    --arg generation "$generation" --arg generation_path "$LANDING_CHANNEL_GENERATION_PATH" \
    --arg agent "$LANDING_CHANNEL_AGENT_PATH" --arg helper "$LANDING_AGENT_HELPER_PATH" \
    --arg runtime "$LANDING_CHANNEL_RUNTIME_PATH" \
    --arg authorized_keys "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH" \
    --arg sudoers "$LANDING_CHANNEL_SUDOERS_PATH" --arg runtime_sha "$runtime_sha" \
    --arg agent_sha "$agent_sha" --arg helper_sha "$helper_sha" --arg sudoers_sha "$sudoers_sha" '
      {
        schema_version:$schema, landing_id:$landing_id, allowed_entry_ipv4:$allowed_ipv4,
        account:$account, group:$group, uid:$uid, gid:$gid, home:$home, shell:$shell,
        public_key:$public_key, public_key_fingerprint:$fingerprint,
        generation:$generation, generation_path:$generation_path,
        agent_path:$agent, helper_path:$helper, runtime_path:$runtime,
        authorized_keys_path:$authorized_keys, sudoers_path:$sudoers,
        runtime_sha256:$runtime_sha, agent_launcher_sha256:$agent_sha,
        helper_launcher_sha256:$helper_sha, sudoers_sha256:$sudoers_sha
      }
    ' > "$output" || return 1
  chmod 600 "$output" || return 1
  validate_landing_channel_identity_json "$output"
}

landing_channel_identity_allows_package() {
  local package="$1" identity package_landing_id package_ipv4
  identity="$(landing_channel_path "$LANDING_CHANNEL_IDENTITY_PATH")" || return 1
  validate_landing_channel_identity_file "$identity" || return 1
  package_landing_id="$(jq -r '.landing_id' "$package")" || return 1
  package_ipv4="$(jq -r '.gateway.allowed_entry_ipv4' "$package")" || return 1
  [[ "$package_landing_id" == "$(jq -r '.landing_id' "$identity")" &&
     "$package_ipv4" == "$(jq -r '.allowed_entry_ipv4' "$identity")" ]]
}

landing_channel_generation_allows_request() {
  local generation="$1" identity generation_file root_uid channel_gid
  [[ "$generation" =~ ^[0-9a-f]{64}$ ]] || return 1
  landing_channel_runtime_paths_are_safe || return 1
  identity="$(landing_channel_path "$LANDING_CHANNEL_IDENTITY_PATH")" || return 1
  validate_landing_channel_identity_file "$identity" || return 1
  [[ "$generation" == "$(jq -r '.generation' "$identity")" ]] || return 1
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  channel_gid="$(jq -r '.gid' "$identity")" || return 1
  [[ "$channel_gid" =~ ^[0-9]+$ && "$channel_gid" != 0 ]] || return 1
  generation_file="$(landing_channel_path "$LANDING_CHANNEL_GENERATION_PATH")" || return 1
  landing_channel_file_matches "$generation_file" 440 "$root_uid" "$channel_gid" || return 1
  [[ "$(<"$generation_file")" == "$generation" ]]
}

landing_channel_authorized_keys_is_valid() {
  local identity="$1" authorized_keys expected actual
  authorized_keys="$(landing_channel_path "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH")" || return 1
  expected="restrict,from=\"$(jq -r '.allowed_entry_ipv4' "$identity")\",command=\"$LANDING_CHANNEL_AGENT_PATH $(jq -r '.generation' "$identity")\" $(jq -r '.public_key' "$identity") sb-user-manager:$(jq -r '.landing_id' "$identity")"
  actual="$(<"$authorized_keys")" || return 1
  [[ "$actual" == "$expected" ]]
}

landing_restricted_channel_core_is_valid() {
  local identity uid gid channel_gid generation_file runtime agent helper sudoers authorized home ssh_dir runtime_dir manager_dir logical path
  local expected_sudoers actual_sudoers
  landing_channel_runtime_paths_are_safe || return 1
  for logical in /usr /usr/local /usr/local/bin /usr/local/libexec /var /var/lib; do
    path="$(landing_channel_path "$logical")" || return 1
    landing_channel_system_directory_is_channel_traversable "$path" || return 1
  done
  for logical in /etc /etc/systemd /etc/systemd/system "$LANDING_STARTUP_RECOVERY_DROPIN_DIRECTORY"; do
    path="$(landing_channel_path "$logical")" || return 1
    landing_channel_system_directory_is_safe "$path" || return 1
  done
  identity="$(landing_channel_path "$LANDING_CHANNEL_IDENTITY_PATH")" || return 1
  validate_landing_channel_identity_file "$identity" || return 1
  uid="$(jq -r '.uid' "$identity")" || return 1
  gid="$(jq -r '.gid' "$identity")" || return 1
  landing_channel_account_matches "$uid" "$gid" || return 1
  channel_gid="$gid"
  home="$(landing_channel_path "$LANDING_CHANNEL_HOME")" || return 1
  ssh_dir="$(landing_channel_path "$LANDING_CHANNEL_SSH_DIRECTORY")" || return 1
  runtime_dir="$(landing_channel_path "$LANDING_CHANNEL_RUNTIME_DIRECTORY")" || return 1
  manager_dir="$(landing_channel_path /var/lib/sb-user-manager)" || return 1
  runtime="$(landing_channel_path "$LANDING_CHANNEL_RUNTIME_PATH")" || return 1
  agent="$(landing_channel_path "$LANDING_CHANNEL_AGENT_PATH")" || return 1
  helper="$(landing_channel_path "$LANDING_AGENT_HELPER_PATH")" || return 1
  sudoers="$(landing_channel_path "$LANDING_CHANNEL_SUDOERS_PATH")" || return 1
  authorized="$(landing_channel_path "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH")" || return 1
  generation_file="$(landing_channel_path "$LANDING_CHANNEL_GENERATION_PATH")" || return 1
  landing_channel_directory_matches "$home" 750 "$(landing_channel_expected_root_uid)" "$channel_gid" || return 1
  landing_channel_directory_matches "$ssh_dir" 750 "$(landing_channel_expected_root_uid)" "$channel_gid" || return 1
  landing_channel_directory_matches "$runtime_dir" 750 "$(landing_channel_expected_root_uid)" "$channel_gid" || return 1
  landing_channel_directory_matches "$manager_dir" 700 "$(landing_channel_expected_root_uid)" \
    "$(landing_channel_expected_root_gid)" || return 1
  landing_channel_file_matches "$runtime" 640 "$(landing_channel_expected_root_uid)" "$channel_gid" || return 1
  landing_channel_file_matches "$agent" 750 "$(landing_channel_expected_root_uid)" "$channel_gid" || return 1
  landing_channel_file_matches "$helper" 700 "$(landing_channel_expected_root_uid)" "$(landing_channel_expected_root_gid)" || return 1
  landing_channel_file_matches "$sudoers" 440 "$(landing_channel_expected_root_uid)" "$(landing_channel_expected_root_gid)" || return 1
  landing_channel_file_matches "$generation_file" 440 "$(landing_channel_expected_root_uid)" "$channel_gid" || return 1
  landing_channel_file_matches "$authorized" 640 "$(landing_channel_expected_root_uid)" "$channel_gid" || return 1
  [[ "$(<"$generation_file")" == "$(jq -r '.generation' "$identity")" ]] || return 1
  [[ "$(landing_channel_sha256 "$runtime")" == "$(jq -r '.runtime_sha256' "$identity")" ]] || return 1
  [[ "$(landing_channel_sha256 "$agent")" == "$(jq -r '.agent_launcher_sha256' "$identity")" ]] || return 1
  [[ "$(landing_channel_sha256 "$helper")" == "$(jq -r '.helper_launcher_sha256' "$identity")" ]] || return 1
  [[ "$(landing_channel_sha256 "$sudoers")" == "$(jq -r '.sudoers_sha256' "$identity")" ]] || return 1
  landing_channel_authorized_keys_is_valid "$identity" || return 1
  landing_channel_home_layout_is_expected || return 1
  landing_channel_runtime_layout_is_expected || return 1
  expected_sudoers="$(mktemp /tmp/sb-landing-sudoers.XXXXXX)" || return 1
  register_temp_path "$expected_sudoers" || { rm -f -- "$expected_sudoers" || true; return 1; }
  landing_channel_render_sudoers "$expected_sudoers" "$(jq -r '.generation' "$identity")" || return 1
  actual_sudoers="$(<"$sudoers")" || return 1
  [[ "$actual_sudoers" == "$(<"$expected_sudoers")" ]] || return 1
  rm -f -- "$expected_sudoers" || return 1
}

landing_restricted_channel_is_valid() {
  landing_restricted_channel_core_is_valid || return 1
  landing_startup_recovery_gate_files_are_valid
}

landing_channel_upgrade_source_is_valid() {
  landing_restricted_channel_core_is_valid || return 1
  landing_startup_recovery_gate_upgrade_source_is_valid
}

landing_channel_loaded_runtime_matches_identity() {
  local identity expected
  [[ "${LANDING_LOADED_RUNTIME_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || return 1
  identity="$(landing_channel_path "$LANDING_CHANNEL_IDENTITY_PATH")" || return 1
  validate_landing_channel_identity_file "$identity" || return 1
  expected="$(jq -r '.runtime_sha256' "$identity")" || return 1
  [[ "$LANDING_LOADED_RUNTIME_SHA256" == "$expected" ]]
}

landing_channel_state_parent_chain_is_safe() {
  local logical path manager root_uid root_gid
  for logical in /var /var/lib; do
    path="$(landing_channel_path "$logical")" || return 1
    landing_channel_system_directory_is_channel_traversable "$path" || return 1
  done
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  manager="$(landing_channel_path /var/lib/sb-user-manager)" || return 1
  landing_channel_directory_matches "$manager" 700 "$root_uid" "$root_gid"
}

landing_channel_create_account() {
  local gid uid
  landing_channel_update_active_journal group_attempted 0 0 || return 1
  LANDING_CHANNEL_GROUP_ATTEMPTED=true
  landing_channel_system_groupadd "$LANDING_CHANNEL_GROUP" || return 1
  landing_channel_sync_account_database || return 1
  landing_channel_read_group || return 1
  gid="$LANDING_CHANNEL_FOUND_GROUP_GID"
  [[ "$gid" =~ ^[0-9]+$ && "$gid" != 0 ]] || return 1
  LANDING_CHANNEL_ACTIVE_GID="$gid"
  landing_channel_update_active_journal user_attempted 0 "$gid" || return 1
  LANDING_CHANNEL_USER_ATTEMPTED=true
  landing_channel_system_useradd --gid "$LANDING_CHANNEL_GROUP" --home-dir "$LANDING_CHANNEL_HOME" \
    --shell "$LANDING_CHANNEL_SHELL" --comment "$LANDING_CHANNEL_GECOS" \
    --password "$LANDING_CHANNEL_PASSWORD_VALUE" --no-create-home "$LANDING_CHANNEL_ACCOUNT" || return 1
  landing_channel_sync_account_database || return 1
  landing_channel_read_account || return 1
  uid="$LANDING_CHANNEL_FOUND_UID"
  [[ "$uid" =~ ^[0-9]+$ && "$uid" != 0 ]] || return 1
  LANDING_CHANNEL_ACTIVE_UID="$uid"
  landing_channel_update_active_journal account_created "$uid" "$gid" || return 1
  landing_channel_account_matches "$uid" "$gid"
}

landing_channel_recreate_group() {
  local gid="$1"
  landing_channel_system_groupadd --gid "$gid" "$LANDING_CHANNEL_GROUP" || return 1
  landing_channel_sync_account_database || return 1
  landing_channel_read_group || return 1
  [[ "$LANDING_CHANNEL_FOUND_GROUP_GID" == "$gid" ]]
}

landing_channel_recreate_user() {
  local uid="$1" gid="$2"
  landing_channel_system_useradd --uid "$uid" --gid "$LANDING_CHANNEL_GROUP" \
    --home-dir "$LANDING_CHANNEL_HOME" --shell "$LANDING_CHANNEL_SHELL" \
    --comment "$LANDING_CHANNEL_GECOS" --password "$LANDING_CHANNEL_PASSWORD_VALUE" \
    --no-create-home "$LANDING_CHANNEL_ACCOUNT" || return 1
  landing_channel_sync_account_database || return 1
  landing_channel_account_matches "$uid" "$gid"
}

landing_channel_prepare_directories() {
  local gid="$1" root_uid root_gid system_root logical path
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  system_root="${SB_SYSTEM_ROOT:-/}"
  landing_channel_system_directory_is_safe "$system_root" || return 1
  landing_channel_ensure_system_directory /usr || return 1
  landing_channel_ensure_system_directory /usr/local || return 1
  landing_channel_ensure_system_directory /usr/local/bin || return 1
  landing_channel_ensure_system_directory /usr/local/libexec || return 1
  landing_channel_ensure_system_directory /etc || return 1
  landing_channel_ensure_system_directory /etc/sudoers.d || return 1
  landing_channel_ensure_system_directory /etc/systemd || return 1
  landing_channel_ensure_system_directory /etc/systemd/system || return 1
  landing_channel_ensure_system_directory "$LANDING_STARTUP_RECOVERY_DROPIN_DIRECTORY" || return 1
  landing_channel_ensure_system_directory /var || return 1
  landing_channel_ensure_system_directory /var/lib || return 1
  for logical in /usr /usr/local /usr/local/bin /usr/local/libexec /var /var/lib; do
    path="$(landing_channel_path "$logical")" || return 1
    landing_channel_system_directory_is_channel_traversable "$path" || return 1
  done
  landing_channel_ensure_owned_directory /var/lib/sb-user-manager 700 "$root_uid" "$root_gid" || return 1
  landing_channel_ensure_owned_directory "$LANDING_CHANNEL_RUNTIME_DIRECTORY" 750 "$root_uid" "$gid" || return 1
  landing_channel_ensure_owned_directory "$LANDING_CHANNEL_HOME" 750 "$root_uid" "$gid" || return 1
  landing_channel_ensure_owned_directory "$LANDING_CHANNEL_SSH_DIRECTORY" 750 "$root_uid" "$gid" || return 1
}

landing_channel_fresh_preflight() {
  local logical path
  if landing_channel_system_get_user "$LANDING_CHANNEL_ACCOUNT" >/dev/null 2>&1; then return 1; fi
  if landing_channel_system_get_group "$LANDING_CHANNEL_GROUP" >/dev/null 2>&1; then return 1; fi
  for logical in "$LANDING_CHANNEL_HOME" "$LANDING_CHANNEL_RUNTIME_DIRECTORY" \
    "$LANDING_CHANNEL_AGENT_PATH" "$LANDING_AGENT_HELPER_PATH" "$LANDING_CHANNEL_SUDOERS_PATH" \
    "$LANDING_CHANNEL_IDENTITY_PATH" "$LANDING_STARTUP_RECOVERY_UNIT_PATH" \
    "$LANDING_STARTUP_RECOVERY_DROPIN_PATH"; do
    path="$(landing_channel_path "$logical")" || return 1
    [[ ! -e "$path" && ! -L "$path" ]] || return 1
  done
}

landing_channel_snapshot_files() {
  local work="$1" snapshot logical label path state root_uid root_gid
  snapshot="$work/snapshot"
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  install -d -m 700 -- "$snapshot" || return 1
  while IFS=$'\t' read -r label logical; do
    path="$(landing_channel_path "$logical")" || return 1
    [[ -f "$path" && ! -L "$path" ]] || return 1
    install -m 600 -- "$path" "$snapshot/$label" || return 1
    sync_transaction_path "$snapshot/$label" || return 1
  done <<EOF
runtime	$LANDING_CHANNEL_RUNTIME_PATH
agent	$LANDING_CHANNEL_AGENT_PATH
helper	$LANDING_AGENT_HELPER_PATH
sudoers	$LANDING_CHANNEL_SUDOERS_PATH
generation	$LANDING_CHANNEL_GENERATION_PATH
identity	$LANDING_CHANNEL_IDENTITY_PATH
authorized_keys	$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH
EOF
  while IFS=$'\t' read -r label logical; do
    path="$(landing_channel_path "$logical")" || return 1
    state="$snapshot/${label}.state"
    if [[ -e "$path" || -L "$path" ]]; then
      landing_channel_file_matches "$path" 644 "$root_uid" "$root_gid" || return 1
      install -m 600 -- "$path" "$snapshot/$label" || return 1
      printf 'exists\n' > "$state" || return 1
    else
      : > "$snapshot/$label" || return 1
      printf 'missing\n' > "$state" || return 1
    fi
    chmod 600 "$snapshot/$label" "$state" || return 1
    sync_transaction_path "$snapshot/$label" || return 1
    sync_transaction_path "$state" || return 1
  done <<EOF
startup-recovery.service	$LANDING_STARTUP_RECOVERY_UNIT_PATH
singbox-recovery.conf	$LANDING_STARTUP_RECOVERY_DROPIN_PATH
EOF
  sync_transaction_path "$snapshot" || return 1
}

landing_channel_transaction_directory_is_safe() {
  local path root_uid root_gid
  path="$(landing_channel_path "$LANDING_CHANNEL_TRANSACTION_DIRECTORY")" || return 1
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  landing_channel_directory_matches "$path" 700 "$root_uid" "$root_gid"
}

validate_landing_channel_transaction_journal() {
  local path="${1:-$(landing_channel_path "$LANDING_CHANNEL_TRANSACTION_JOURNAL")}" root_uid root_gid
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  landing_channel_file_matches "$path" 600 "$root_uid" "$root_gid" || return 1
  jq -e -s 'length == 1' "$path" >/dev/null || return 1
  jq -e --argjson schema "$LANDING_CHANNEL_TRANSACTION_SCHEMA_VERSION" '
    type == "object" and
    (keys | sort) == ["gid", "mode", "phase", "schema_version", "transaction_id", "uid"] and
    .schema_version == $schema and
    (.transaction_id | type == "string" and test("^[0-9a-f]{32}$")) and
    (.mode == "fresh" or .mode == "update" or .mode == "uninstall") and
    (.phase == "prepared" or .phase == "group_attempted" or
      .phase == "user_attempted" or .phase == "account_created" or
      .phase == "files_active" or .phase == "active" or
      .phase == "committed" or .phase == "rolled_back") and
    (.uid | type == "number" and . == floor and . >= 0 and . <= 4294967294) and
    (.gid | type == "number" and . == floor and . >= 0 and . <= 4294967294) and
    if .mode == "fresh" then
      if .phase == "prepared" then .uid == 0 and .gid == 0
      elif .phase == "group_attempted" then .uid == 0
      elif .phase == "user_attempted" then .uid == 0 and .gid >= 1
      elif (.phase == "account_created" or .phase == "files_active" or .phase == "committed") then
        .uid >= 1 and .gid >= 1
      elif .phase == "rolled_back" then
        (.uid == 0 or .uid >= 1) and (.gid == 0 or .gid >= 1) and
        (.uid == 0 or .gid >= 1)
      else false
      end
    else
      (.phase == "active" or .phase == "committed" or .phase == "rolled_back") and
      .uid >= 1 and .gid >= 1
    end
  ' "$path" >/dev/null
}

landing_channel_snapshot_is_valid() {
  local work="$1" snapshot root_uid root_gid label state
  snapshot="$work/snapshot"
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  landing_channel_directory_matches "$snapshot" 700 "$root_uid" "$root_gid" || return 1
  for label in runtime agent helper sudoers generation identity authorized_keys; do
    landing_channel_file_matches "$snapshot/$label" 600 "$root_uid" "$root_gid" || return 1
  done
  for label in startup-recovery.service singbox-recovery.conf; do
    landing_channel_file_matches "$snapshot/$label" 600 "$root_uid" "$root_gid" || return 1
    landing_channel_file_matches "$snapshot/${label}.state" 600 "$root_uid" "$root_gid" || return 1
    state="$(<"$snapshot/${label}.state")" || return 1
    [[ "$state" == exists || "$state" == missing ]] || return 1
    if [[ "$state" == missing ]]; then
      [[ ! -s "$snapshot/$label" ]] || return 1
    fi
  done
}

landing_channel_persist_install_candidates() {
  local work="$1" transaction candidates root_uid root_gid name
  transaction="$(landing_channel_path "$LANDING_CHANNEL_TRANSACTION_DIRECTORY")" || return 1
  candidates="$transaction/candidates"
  landing_channel_transaction_directory_is_safe || return 1
  [[ ! -e "$candidates" && ! -L "$candidates" ]] || return 1
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  install -d -m 700 -- "$candidates" || return 1
  landing_channel_apply_ownership "$candidates" "$root_uid" "$root_gid" || return 1
  landing_channel_directory_matches "$candidates" 700 "$root_uid" "$root_gid" || return 1
  for name in runtime.sh agent helper sudoers generation identity.json authorized_keys \
    startup-recovery.service singbox-recovery.conf; do
    [[ -f "$work/$name" && ! -L "$work/$name" ]] || return 1
    install -m 600 -- "$work/$name" "$candidates/$name" || return 1
    landing_channel_apply_ownership "$candidates/$name" "$root_uid" "$root_gid" || return 1
    landing_channel_file_matches "$candidates/$name" 600 "$root_uid" "$root_gid" || return 1
    sync_transaction_path "$candidates/$name" || return 1
  done
  sync_transaction_path "$candidates" || return 1
  sync_transaction_path "$transaction" || return 1
}

landing_channel_install_candidates_are_valid() {
  local transaction candidates root_uid root_gid name
  transaction="$(landing_channel_path "$LANDING_CHANNEL_TRANSACTION_DIRECTORY")" || return 1
  candidates="$transaction/candidates"
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  landing_channel_directory_matches "$candidates" 700 "$root_uid" "$root_gid" || return 1
  for name in runtime.sh agent helper sudoers generation identity.json authorized_keys \
    startup-recovery.service singbox-recovery.conf; do
    landing_channel_file_matches "$candidates/$name" 600 "$root_uid" "$root_gid" || return 1
  done
}

landing_channel_write_transaction_journal() {
  local mode="$1" phase="$2" uid="$3" gid="$4" transaction_id="$5"
  local directory journal tmp root_uid root_gid
  directory="$(landing_channel_path "$LANDING_CHANNEL_TRANSACTION_DIRECTORY")" || return 1
  journal="$(landing_channel_path "$LANDING_CHANNEL_TRANSACTION_JOURNAL")" || return 1
  landing_channel_transaction_directory_is_safe || return 1
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  [[ "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ ]] || return 1
  [[ "$transaction_id" =~ ^[0-9a-f]{32}$ ]] || return 1
  tmp="$(mktemp "$directory/.landing-channel.XXXXXX")" || return 1
  register_temp_path "$tmp" || { rm -f -- "$tmp" || true; return 1; }
  if ! jq -n --argjson schema "$LANDING_CHANNEL_TRANSACTION_SCHEMA_VERSION" \
      --arg mode "$mode" --arg phase "$phase" --argjson uid "$uid" --argjson gid "$gid" \
      --arg transaction_id "$transaction_id" \
      '{schema_version:$schema,transaction_id:$transaction_id,mode:$mode,phase:$phase,uid:$uid,gid:$gid}' > "$tmp" ||
     ! chmod 600 "$tmp" ||
     ! landing_channel_apply_ownership "$tmp" "$root_uid" "$root_gid" ||
     ! validate_landing_channel_transaction_journal "$tmp" ||
     ! sync_transaction_path "$tmp"; then
    rm -f -- "$tmp" || true
    return 1
  fi
  mv -- "$tmp" "$journal" || { rm -f -- "$tmp" || true; return 1; }
  if ! sync_transaction_path "$directory"; then
    # 终态一旦完成 rename 就绝不反向执行；其余阶段仍沿用之前已同步的 journal 恢复。
    [[ "$phase" == committed || "$phase" == rolled_back ]] && return 2
    return 1
  fi
}

landing_channel_discard_transaction_directory() {
  local directory parent
  directory="$(landing_channel_path "$LANDING_CHANNEL_TRANSACTION_DIRECTORY")" || return 1
  [[ ! -e "$directory" && ! -L "$directory" ]] && return 0
  landing_channel_transaction_directory_is_safe || return 1
  parent="$(dirname -- "$directory")" || return 1
  rm -rf -- "$directory" || return 1
  sync_transaction_path "$parent" || return 1
}

landing_channel_begin_transaction() {
  local mode="$1" uid="$2" gid="$3" directory root_uid root_gid phase transaction_id
  directory="$(landing_channel_path "$LANDING_CHANNEL_TRANSACTION_DIRECTORY")" || return 1
  [[ ! -e "$directory" && ! -L "$directory" ]] || return 1
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  transaction_id="$(python3 -I -c 'import secrets; print(secrets.token_hex(16))')" || return 1
  [[ "$transaction_id" =~ ^[0-9a-f]{32}$ ]] || return 1
  landing_channel_ensure_owned_directory "$LANDING_CHANNEL_TRANSACTION_DIRECTORY" 700 "$root_uid" "$root_gid" || return 1
  if ! sync_transaction_path "$directory" ||
     ! sync_transaction_path "$(dirname -- "$directory")"; then
    landing_channel_discard_transaction_directory || true
    return 1
  fi
  if [[ "$mode" == fresh ]]; then
    uid=0
    gid=0
    phase=prepared
  else
    [[ "$mode" == update || "$mode" == uninstall ]] || {
      landing_channel_discard_transaction_directory || true
      return 1
    }
    landing_channel_snapshot_files "$directory" || {
      landing_channel_discard_transaction_directory || true
      return 1
    }
    landing_channel_snapshot_is_valid "$directory" || {
      landing_channel_discard_transaction_directory || true
      return 1
    }
    phase=active
  fi
  landing_channel_write_transaction_journal "$mode" "$phase" "$uid" "$gid" "$transaction_id" || {
    landing_channel_discard_transaction_directory || true
    return 1
  }
  LANDING_CHANNEL_ACTIVE_MODE="$mode"
  LANDING_CHANNEL_ACTIVE_WORK="$directory"
  LANDING_CHANNEL_ACTIVE_UID="$uid"
  LANDING_CHANNEL_ACTIVE_GID="$gid"
  LANDING_CHANNEL_ACTIVE_PHASE="$phase"
  LANDING_CHANNEL_ACTIVE_TRANSACTION_ID="$transaction_id"
}

landing_channel_update_active_journal() {
  local phase="$1" uid="${2:-$LANDING_CHANNEL_ACTIVE_UID}" gid="${3:-$LANDING_CHANNEL_ACTIVE_GID}" rc=0
  [[ -n "$LANDING_CHANNEL_ACTIVE_MODE" && -n "$LANDING_CHANNEL_ACTIVE_WORK" ]] || return 1
  [[ "$LANDING_CHANNEL_ACTIVE_WORK" == "$(landing_channel_path "$LANDING_CHANNEL_TRANSACTION_DIRECTORY")" ]] || return 1
  [[ -n "$uid" ]] || uid=0
  [[ -n "$gid" ]] || gid=0
  landing_channel_write_transaction_journal "$LANDING_CHANNEL_ACTIVE_MODE" "$phase" "$uid" "$gid" \
    "$LANDING_CHANNEL_ACTIVE_TRANSACTION_ID" || rc=$?
  [[ "$rc" != 1 ]] || return 1
  LANDING_CHANNEL_ACTIVE_PHASE="$phase"
  LANDING_CHANNEL_ACTIVE_UID="$uid"
  LANDING_CHANNEL_ACTIVE_GID="$gid"
  return "$rc"
}

landing_channel_restore_systemd_file() {
  local work="$1" label="$2" logical="$3" state target root_uid root_gid actual expected
  state="$(<"$work/snapshot/${label}.state")" || return 1
  target="$(landing_channel_path "$logical")" || return 1
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  case "$state" in
    exists)
      landing_channel_atomic_install_file "$work/snapshot/$label" "$logical" 644 "$root_uid" "$root_gid"
      ;;
    missing)
      if [[ -e "$target" || -L "$target" ]]; then
        landing_channel_file_matches "$target" 644 "$root_uid" "$root_gid" || return 1
        actual="$(<"$target")" || return 1
        case "$logical" in
          "$LANDING_STARTUP_RECOVERY_UNIT_PATH") expected="$(landing_startup_recovery_unit_content)" ;;
          "$LANDING_STARTUP_RECOVERY_DROPIN_PATH") expected="$(landing_startup_recovery_dropin_content)" ;;
          *) return 1 ;;
        esac
        [[ "$actual" == "$expected" ]] || return 1
        landing_channel_remove_file "$logical" || return 1
      fi
      ;;
    *) return 1 ;;
  esac
}

landing_channel_restore_files() {
  local work="$1" gid="$2" root_uid root_gid
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  landing_channel_snapshot_is_valid "$work" || return 1
  landing_channel_prepare_directories "$gid" || return 1
  landing_channel_atomic_install_file "$work/snapshot/runtime" "$LANDING_CHANNEL_RUNTIME_PATH" 640 "$root_uid" "$gid" || return 1
  landing_channel_atomic_install_file "$work/snapshot/agent" "$LANDING_CHANNEL_AGENT_PATH" 750 "$root_uid" "$gid" || return 1
  landing_channel_atomic_install_file "$work/snapshot/helper" "$LANDING_AGENT_HELPER_PATH" 700 "$root_uid" "$root_gid" || return 1
  landing_channel_atomic_install_file "$work/snapshot/sudoers" "$LANDING_CHANNEL_SUDOERS_PATH" 440 "$root_uid" "$root_gid" || return 1
  landing_channel_atomic_install_file "$work/snapshot/generation" "$LANDING_CHANNEL_GENERATION_PATH" 440 "$root_uid" "$gid" || return 1
  landing_channel_atomic_install_file "$work/snapshot/identity" "$LANDING_CHANNEL_IDENTITY_PATH" 600 "$root_uid" "$root_gid" || return 1
  landing_channel_atomic_install_file "$work/snapshot/authorized_keys" "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH" 640 "$root_uid" "$gid" || return 1
  landing_channel_restore_systemd_file "$work" startup-recovery.service \
    "$LANDING_STARTUP_RECOVERY_UNIT_PATH" || return 1
  landing_channel_restore_systemd_file "$work" singbox-recovery.conf \
    "$LANDING_STARTUP_RECOVERY_DROPIN_PATH" || return 1
  landing_startup_recovery_daemon_reload || return 1
}

landing_channel_remove_file() {
  local logical="$1" path
  path="$(landing_channel_path "$logical")" || return 1
  [[ ! -e "$path" && ! -L "$path" ]] && return 0
  [[ -f "$path" || -L "$path" ]] || return 1
  rm -f -- "$path" || return 1
  sync_transaction_path "$(dirname -- "$path")" || return 1
}

landing_channel_remove_empty_directory() {
  local logical="$1" path
  path="$(landing_channel_path "$logical")" || return 1
  [[ ! -e "$path" && ! -L "$path" ]] && return 0
  [[ -d "$path" && ! -L "$path" ]] || return 1
  rmdir -- "$path" || return 1
  sync_transaction_path "$(dirname -- "$path")" || return 1
}

landing_channel_home_layout_is_expected() (
  local home ssh_dir authorized generation
  home="$(landing_channel_path "$LANDING_CHANNEL_HOME")" || return 1
  ssh_dir="$(landing_channel_path "$LANDING_CHANNEL_SSH_DIRECTORY")" || return 1
  authorized="$(landing_channel_path "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH")" || return 1
  generation="$(landing_channel_path "$LANDING_CHANNEL_GENERATION_PATH")" || return 1
  landing_channel_directory_contains_only "$home" "$generation" "$ssh_dir" || return 1
  landing_channel_directory_contains_only "$ssh_dir" "$authorized"
)

landing_channel_runtime_layout_is_expected() (
  local runtime_dir runtime
  local -a runtime_entries
  runtime_dir="$(landing_channel_path "$LANDING_CHANNEL_RUNTIME_DIRECTORY")" || return 1
  runtime="$(landing_channel_path "$LANDING_CHANNEL_RUNTIME_PATH")" || return 1
  shopt -s dotglob nullglob
  runtime_entries=("$runtime_dir"/* "")
  [[ ${#runtime_entries[@]} -eq 2 && "${runtime_entries[0]}" == "$runtime" ]]
)

landing_channel_directory_contains_only() (
  local path="$1" entry allowed match
  local -a entries allowed_entries
  shift
  allowed_entries=("$@" "")
  [[ -d "$path" && ! -L "$path" ]] || return 1
  shopt -s dotglob nullglob
  entries=("$path"/* "")
  for entry in "${entries[@]}"; do
    [[ -n "$entry" ]] || continue
    match=false
    for allowed in "${allowed_entries[@]}"; do
      [[ -n "$allowed" ]] || continue
      if [[ "$entry" == "$allowed" ]]; then
        match=true
        break
      fi
    done
    [[ "$match" == true ]] || return 1
  done
)

landing_channel_fresh_files_are_owned() {
  local candidates root_uid root_gid gid candidate logical mode expected_gid path
  local home ssh_dir authorized generation runtime_dir runtime
  landing_channel_install_candidates_are_valid || return 1
  candidates="$(landing_channel_path "$LANDING_CHANNEL_TRANSACTION_DIRECTORY")/candidates"
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  gid="$LANDING_CHANNEL_ACTIVE_GID"
  [[ "$gid" =~ ^[0-9]+$ && "$gid" != 0 ]] || return 1
  while IFS=$'\t' read -r candidate logical mode expected_gid; do
    path="$(landing_channel_path "$logical")" || return 1
    [[ ! -e "$path" && ! -L "$path" ]] && continue
    [[ "$expected_gid" == channel ]] && expected_gid="$gid"
    [[ "$expected_gid" == root ]] && expected_gid="$root_gid"
    landing_channel_file_matches "$path" "$mode" "$root_uid" "$expected_gid" || return 1
    cmp -s -- "$candidates/$candidate" "$path" || return 1
  done <<EOF
runtime.sh	$LANDING_CHANNEL_RUNTIME_PATH	640	channel
agent	$LANDING_CHANNEL_AGENT_PATH	750	channel
helper	$LANDING_AGENT_HELPER_PATH	700	root
sudoers	$LANDING_CHANNEL_SUDOERS_PATH	440	root
generation	$LANDING_CHANNEL_GENERATION_PATH	440	channel
identity.json	$LANDING_CHANNEL_IDENTITY_PATH	600	root
authorized_keys	$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH	640	channel
startup-recovery.service	$LANDING_STARTUP_RECOVERY_UNIT_PATH	644	root
singbox-recovery.conf	$LANDING_STARTUP_RECOVERY_DROPIN_PATH	644	root
EOF
  home="$(landing_channel_path "$LANDING_CHANNEL_HOME")" || return 1
  ssh_dir="$(landing_channel_path "$LANDING_CHANNEL_SSH_DIRECTORY")" || return 1
  authorized="$(landing_channel_path "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH")" || return 1
  generation="$(landing_channel_path "$LANDING_CHANNEL_GENERATION_PATH")" || return 1
  runtime_dir="$(landing_channel_path "$LANDING_CHANNEL_RUNTIME_DIRECTORY")" || return 1
  runtime="$(landing_channel_path "$LANDING_CHANNEL_RUNTIME_PATH")" || return 1
  if [[ -e "$runtime_dir" || -L "$runtime_dir" ]]; then
    if ! landing_channel_directory_matches "$runtime_dir" 750 "$root_uid" "$gid" &&
       ! landing_channel_directory_matches "$runtime_dir" 750 "$root_uid" "$root_gid" &&
       ! landing_channel_directory_matches "$runtime_dir" 700 "$root_uid" "$root_gid"; then
      return 1
    fi
    landing_channel_directory_contains_only "$runtime_dir" "$runtime" || return 1
  fi
  if [[ -e "$home" || -L "$home" ]]; then
    if ! landing_channel_directory_matches "$home" 750 "$root_uid" "$gid" &&
       ! landing_channel_directory_matches "$home" 750 "$root_uid" "$root_gid" &&
       ! landing_channel_directory_matches "$home" 700 "$root_uid" "$root_gid"; then
      return 1
    fi
    landing_channel_directory_contains_only "$home" "$generation" "$ssh_dir" || return 1
  fi
  if [[ -e "$ssh_dir" || -L "$ssh_dir" ]]; then
    if ! landing_channel_directory_matches "$ssh_dir" 750 "$root_uid" "$gid" &&
       ! landing_channel_directory_matches "$ssh_dir" 750 "$root_uid" "$root_gid" &&
       ! landing_channel_directory_matches "$ssh_dir" 700 "$root_uid" "$root_gid"; then
      return 1
    fi
    landing_channel_directory_contains_only "$ssh_dir" "$authorized" || return 1
  fi
}

landing_channel_remove_fresh_resources() {
  local candidate_uid rc=0
  if [[ "$LANDING_CHANNEL_ACTIVE_PHASE" == files_active ]]; then
    landing_channel_fresh_files_are_owned || return 1
    landing_channel_remove_file "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH" || rc=1
    landing_channel_remove_file "$LANDING_CHANNEL_IDENTITY_PATH" || rc=1
    landing_channel_remove_file "$LANDING_CHANNEL_GENERATION_PATH" || rc=1
    landing_channel_remove_file "$LANDING_CHANNEL_SUDOERS_PATH" || rc=1
    landing_channel_remove_file "$LANDING_STARTUP_RECOVERY_DROPIN_PATH" || rc=1
    landing_channel_remove_file "$LANDING_STARTUP_RECOVERY_UNIT_PATH" || rc=1
    landing_startup_recovery_daemon_reload || rc=1
    landing_channel_remove_file "$LANDING_AGENT_HELPER_PATH" || rc=1
    landing_channel_remove_file "$LANDING_CHANNEL_AGENT_PATH" || rc=1
    landing_channel_remove_file "$LANDING_CHANNEL_RUNTIME_PATH" || rc=1
    landing_channel_remove_empty_directory "$LANDING_CHANNEL_SSH_DIRECTORY" || rc=1
    landing_channel_remove_empty_directory "$LANDING_CHANNEL_HOME" || rc=1
    landing_channel_remove_empty_directory "$LANDING_CHANNEL_RUNTIME_DIRECTORY" || rc=1
    [[ "$rc" == 0 ]] || return 1
  elif [[ "$LANDING_CHANNEL_ACTIVE_PHASE" != prepared &&
          "$LANDING_CHANNEL_ACTIVE_PHASE" != group_attempted &&
          "$LANDING_CHANNEL_ACTIVE_PHASE" != user_attempted &&
          "$LANDING_CHANNEL_ACTIVE_PHASE" != account_created ]]; then
    return 1
  fi
  if [[ ( -z "$LANDING_CHANNEL_ACTIVE_GID" || "$LANDING_CHANNEL_ACTIVE_GID" == 0 ) &&
        "$LANDING_CHANNEL_GROUP_ATTEMPTED" == true ]] &&
     landing_channel_system_get_group "$LANDING_CHANNEL_GROUP" >/dev/null 2>&1; then
    if landing_channel_read_group &&
       [[ "$LANDING_CHANNEL_FOUND_GROUP_GID" =~ ^[0-9]+$ && "$LANDING_CHANNEL_FOUND_GROUP_GID" != 0 ]]; then
      LANDING_CHANNEL_ACTIVE_GID="$LANDING_CHANNEL_FOUND_GROUP_GID"
    else
      rc=1
    fi
  fi
  if [[ ( -z "$LANDING_CHANNEL_ACTIVE_UID" || "$LANDING_CHANNEL_ACTIVE_UID" == 0 ) &&
        -n "$LANDING_CHANNEL_ACTIVE_GID" && "$LANDING_CHANNEL_ACTIVE_GID" != 0 &&
        "$LANDING_CHANNEL_USER_ATTEMPTED" == true ]] &&
     landing_channel_system_get_user "$LANDING_CHANNEL_ACCOUNT" >/dev/null 2>&1; then
    if landing_channel_read_account; then
      candidate_uid="$LANDING_CHANNEL_FOUND_UID"
      if [[ "$candidate_uid" =~ ^[0-9]+$ && "$candidate_uid" != 0 ]] &&
         landing_channel_account_matches "$candidate_uid" "$LANDING_CHANNEL_ACTIVE_GID"; then
        LANDING_CHANNEL_ACTIVE_UID="$candidate_uid"
      else
        rc=1
      fi
    else
      rc=1
    fi
  fi
  if landing_channel_system_get_user "$LANDING_CHANNEL_ACCOUNT" >/dev/null 2>&1; then
    if [[ -n "$LANDING_CHANNEL_ACTIVE_UID" && "$LANDING_CHANNEL_ACTIVE_UID" != 0 &&
          -n "$LANDING_CHANNEL_ACTIVE_GID" && "$LANDING_CHANNEL_ACTIVE_GID" != 0 ]] &&
       landing_channel_account_matches "$LANDING_CHANNEL_ACTIVE_UID" "$LANDING_CHANNEL_ACTIVE_GID"; then
      landing_channel_system_userdel "$LANDING_CHANNEL_ACCOUNT" || rc=1
      if [[ "$rc" == 0 ]]; then landing_channel_sync_account_database || rc=1; fi
    else
      rc=1
    fi
  fi
  [[ "$rc" == 0 ]] || return 1
  if landing_channel_system_get_group "$LANDING_CHANNEL_GROUP" >/dev/null 2>&1; then
    if landing_channel_read_group &&
       [[ -n "$LANDING_CHANNEL_ACTIVE_GID" && "$LANDING_CHANNEL_ACTIVE_GID" != 0 &&
          "$LANDING_CHANNEL_FOUND_GROUP_GID" == "$LANDING_CHANNEL_ACTIVE_GID" ]]; then
      landing_channel_system_groupdel "$LANDING_CHANNEL_GROUP" || rc=1
      if [[ "$rc" == 0 ]]; then landing_channel_sync_account_database || rc=1; fi
    else
      rc=1
    fi
  fi
  return "$rc"
}

landing_channel_update_current_entry_is_owned() {
  local authorized identity root_uid channel_gid
  authorized="$(landing_channel_path "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH")" || return 1
  [[ ! -e "$authorized" && ! -L "$authorized" ]] && return 0
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  channel_gid="$LANDING_CHANNEL_ACTIVE_GID"
  [[ "$channel_gid" =~ ^[0-9]+$ && "$channel_gid" != 0 ]] || return 1
  landing_channel_file_matches "$authorized" 640 "$root_uid" "$channel_gid" || return 1
  if cmp -s -- "$LANDING_CHANNEL_ACTIVE_WORK/snapshot/authorized_keys" "$authorized"; then
    return 0
  fi
  identity="$(landing_channel_path "$LANDING_CHANNEL_IDENTITY_PATH")" || return 1
  validate_landing_channel_identity_file "$identity" || return 1
  [[ "$(jq -r '.uid' "$identity")" == "$LANDING_CHANNEL_ACTIVE_UID" &&
     "$(jq -r '.gid' "$identity")" == "$LANDING_CHANNEL_ACTIVE_GID" ]] || return 1
  landing_channel_authorized_keys_is_valid "$identity"
}

landing_channel_cleanup_orphan_atomic_files() (
  local logical parent entry name uid mode expected_uid transaction_id
  local -a entries
  expected_uid="$(landing_channel_expected_root_uid)" || return 1
  transaction_id="$LANDING_CHANNEL_ACTIVE_TRANSACTION_ID"
  [[ "$transaction_id" =~ ^[0-9a-f]{32}$ ]] || return 1
  shopt -s nullglob
  for logical in \
    /usr/local/bin /usr/local/libexec "$LANDING_CHANNEL_RUNTIME_DIRECTORY" \
    /etc/sudoers.d /etc/systemd/system "$LANDING_STARTUP_RECOVERY_DROPIN_DIRECTORY" \
    /var/lib/sb-user-manager "$LANDING_CHANNEL_HOME" \
    "$LANDING_CHANNEL_SSH_DIRECTORY"; do
    parent="$(landing_channel_path "$logical")" || return 1
    [[ ! -e "$parent" && ! -L "$parent" ]] && continue
    landing_channel_directory_is_root_controlled "$parent" || return 1
    # Bash 3.2 在 nounset 模式下展开真正的空数组会报错；保留空哨兵。
    entries=("$parent"/.landing-channel."$transaction_id".* "")
    for entry in "${entries[@]}"; do
      [[ -n "$entry" ]] || continue
      name="${entry##*/}"
      [[ "$name" =~ ^\.landing-channel\.${transaction_id}\.[A-Za-z0-9]{6}$ ]] || return 1
      [[ -f "$entry" && ! -L "$entry" ]] || return 1
      uid="$(manager_file_uid "$entry")" || return 1
      mode="$(manager_file_mode "$entry")" || return 1
      [[ "$uid" == "$expected_uid" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
      (( (8#$mode & 0022) == 0 )) || return 1
      rm -f -- "$entry" || return 1
      sync_transaction_path "$parent" || return 1
    done
  done
)

landing_channel_reset_active_transaction() {
  LANDING_CHANNEL_ACTIVE_MODE=""
  LANDING_CHANNEL_ACTIVE_WORK=""
  LANDING_CHANNEL_ACTIVE_UID=""
  LANDING_CHANNEL_ACTIVE_GID=""
  LANDING_CHANNEL_ACTIVE_PHASE=""
  LANDING_CHANNEL_ACTIVE_TRANSACTION_ID=""
  LANDING_CHANNEL_GROUP_ATTEMPTED=false
  LANDING_CHANNEL_USER_ATTEMPTED=false
  clear_signal_rollback
}

landing_channel_finish_rollback_transaction() {
  local rc=0
  # 运行态已经完整恢复；先持久标记终态，之后即使目录清理中断也只继续清理。
  clear_signal_rollback
  landing_channel_update_active_journal rolled_back || rc=$?
  [[ "$rc" != 1 ]] || return 1
  landing_channel_reset_active_transaction
  [[ "$rc" == 0 ]] || return 2
  landing_channel_discard_transaction_directory || return 2
}

landing_channel_rollback_install() {
  local rc=0
  if [[ "$LANDING_CHANNEL_ACTIVE_MODE" == update ||
        "$LANDING_CHANNEL_ACTIVE_PHASE" == files_active ]]; then
    landing_channel_cleanup_orphan_atomic_files || rc=1
  fi
  [[ "$rc" == 0 ]] || return 1
  case "$LANDING_CHANNEL_ACTIVE_MODE" in
    fresh) landing_channel_remove_fresh_resources || rc=1 ;;
    update)
      landing_channel_update_current_entry_is_owned || rc=1
      if [[ "$rc" == 0 ]]; then
        landing_channel_remove_file "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH" || rc=1
      fi
      if [[ "$rc" == 0 ]]; then
        landing_channel_account_matches "$LANDING_CHANNEL_ACTIVE_UID" "$LANDING_CHANNEL_ACTIVE_GID" || rc=1
      fi
      if [[ "$rc" == 0 ]]; then
        landing_channel_restore_files "$LANDING_CHANNEL_ACTIVE_WORK" "$LANDING_CHANNEL_ACTIVE_GID" || rc=1
      fi
      ;;
    *) rc=1 ;;
  esac
  if [[ "$rc" == 0 ]]; then
    landing_channel_finish_rollback_transaction || rc=$?
  fi
  return "$rc"
}

landing_channel_rollback_uninstall() {
  local rc=0 lookup_rc
  landing_channel_cleanup_orphan_atomic_files || return 1
  if landing_channel_system_get_group "$LANDING_CHANNEL_GROUP" >/dev/null 2>&1; then
    if ! landing_channel_read_group ||
       [[ "$LANDING_CHANNEL_FOUND_GROUP_GID" != "$LANDING_CHANNEL_ACTIVE_GID" ]]; then
      return 1
    fi
  else
    lookup_rc=$?
    [[ "$lookup_rc" == 2 ]] || return 1
    landing_channel_recreate_group "$LANDING_CHANNEL_ACTIVE_GID" || rc=1
  fi
  if [[ "$rc" == 0 ]]; then
    if landing_channel_system_get_user "$LANDING_CHANNEL_ACCOUNT" >/dev/null 2>&1; then
      landing_channel_account_matches "$LANDING_CHANNEL_ACTIVE_UID" "$LANDING_CHANNEL_ACTIVE_GID" || rc=1
    else
      lookup_rc=$?
      if [[ "$lookup_rc" == 2 ]]; then
        landing_channel_recreate_user "$LANDING_CHANNEL_ACTIVE_UID" "$LANDING_CHANNEL_ACTIVE_GID" || rc=1
      else
        rc=1
      fi
    fi
  fi
  if [[ "$rc" == 0 ]]; then
    landing_channel_account_matches "$LANDING_CHANNEL_ACTIVE_UID" "$LANDING_CHANNEL_ACTIVE_GID" || rc=1
  fi
  if [[ "$rc" == 0 ]]; then
    landing_channel_restore_files "$LANDING_CHANNEL_ACTIVE_WORK" "$LANDING_CHANNEL_ACTIVE_GID" || rc=1
  fi
  if [[ "$rc" == 0 ]]; then
    landing_channel_finish_rollback_transaction || rc=$?
  fi
  return "$rc"
}

landing_channel_commit_active_transaction() {
  local rc=0
  # 从写入 committed 标记开始不可再回滚；中断只允许由持久 journal 判定最终状态。
  clear_signal_rollback
  landing_channel_update_active_journal committed || rc=$?
  [[ "$rc" != 1 ]] || return 1
  landing_channel_reset_active_transaction
  [[ "$rc" == 0 ]] || return 2
  landing_channel_discard_transaction_directory || return 2
}

landing_channel_load_pending_transaction() {
  local journal mode phase uid gid transaction_id
  journal="$(landing_channel_path "$LANDING_CHANNEL_TRANSACTION_JOURNAL")" || return 1
  landing_channel_transaction_directory_is_safe || return 1
  validate_landing_channel_transaction_journal "$journal" || return 1
  mode="$(jq -r '.mode' "$journal")" || return 1
  phase="$(jq -r '.phase' "$journal")" || return 1
  uid="$(jq -r '.uid' "$journal")" || return 1
  gid="$(jq -r '.gid' "$journal")" || return 1
  transaction_id="$(jq -r '.transaction_id' "$journal")" || return 1
  LANDING_CHANNEL_ACTIVE_MODE="$mode"
  LANDING_CHANNEL_ACTIVE_WORK="$(landing_channel_path "$LANDING_CHANNEL_TRANSACTION_DIRECTORY")" || return 1
  LANDING_CHANNEL_ACTIVE_UID="$uid"
  LANDING_CHANNEL_ACTIVE_GID="$gid"
  LANDING_CHANNEL_ACTIVE_PHASE="$phase"
  LANDING_CHANNEL_ACTIVE_TRANSACTION_ID="$transaction_id"
  LANDING_CHANNEL_GROUP_ATTEMPTED=false
  LANDING_CHANNEL_USER_ATTEMPTED=false
  if [[ "$mode" == fresh ]]; then
    case "$phase" in
      group_attempted) LANDING_CHANNEL_GROUP_ATTEMPTED=true ;;
      user_attempted|account_created|files_active)
        LANDING_CHANNEL_GROUP_ATTEMPTED=true
        LANDING_CHANNEL_USER_ATTEMPTED=true
        ;;
      prepared|committed|rolled_back) ;;
      *) return 1 ;;
    esac
  else
    [[ "$phase" == active || "$phase" == committed || "$phase" == rolled_back ]] || return 1
    # committed 已经是最终状态；清理事务目录中途崩溃时快照可能只剩一部分。
    # 只有仍需回滚的 active 事务才依赖完整快照。
    if [[ "$phase" == active ]]; then
      landing_channel_snapshot_is_valid "$LANDING_CHANNEL_ACTIVE_WORK" || return 1
    fi
  fi
}

landing_channel_recover_pending_transaction() {
  local directory journal phase
  directory="$(landing_channel_path "$LANDING_CHANNEL_TRANSACTION_DIRECTORY")" || return 1
  journal="$(landing_channel_path "$LANDING_CHANNEL_TRANSACTION_JOURNAL")" || return 1
  [[ -z "$LANDING_CHANNEL_ACTIVE_MODE" ]] || return 1
  [[ ! -L "$directory" ]] || return 1
  [[ -e "$directory" ]] || return 0
  landing_channel_transaction_directory_is_safe || return 1
  if [[ ! -e "$journal" && ! -L "$journal" ]]; then
    # Journal 会在任何账户或文件变更前落盘；没有 journal 的安全目录只可能是准备阶段残留。
    landing_channel_discard_transaction_directory
    return
  fi
  landing_channel_load_pending_transaction || return 1
  phase="$LANDING_CHANNEL_ACTIVE_PHASE"
  if [[ "$phase" == committed || "$phase" == rolled_back ]]; then
    landing_channel_reset_active_transaction
    landing_channel_discard_transaction_directory
    return
  fi
  set_signal_rollback landing_channel_signal_rollback || return 1
  case "$LANDING_CHANNEL_ACTIVE_MODE" in
    fresh|update) landing_channel_rollback_install ;;
    uninstall) landing_channel_rollback_uninstall ;;
    *) return 1 ;;
  esac
}

landing_channel_signal_rollback() {
  case "$LANDING_CHANNEL_ACTIVE_MODE" in
    fresh|update) landing_channel_rollback_install ;;
    uninstall) landing_channel_rollback_uninstall ;;
    *) return 0 ;;
  esac
}

landing_channel_probe_entrypoints() {
  local agent helper output rc
  [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]] && return 0
  agent="$(landing_channel_path "$LANDING_CHANNEL_AGENT_PATH")" || return 1
  helper="$(landing_channel_path "$LANDING_AGENT_HELPER_PATH")" || return 1
  rc=0
  # 显式非法参数保证探针不受管理员当前 SSH_* 环境影响，也绝不进入 stdin handoff。
  output="$($agent unexpected 2>/dev/null)" || rc=$?
  [[ "$rc" == 64 ]] || return 1
  printf '%s\n' "$output" | jq -e '.status == "error" and .code == "restricted_channel_rejected"' >/dev/null || return 1
  rc=0
  output="$($helper unexpected 2>/dev/null)" || rc=$?
  [[ "$rc" == 64 ]] || return 1
  printf '%s\n' "$output" | jq -e '.status == "error" and .code == "arguments_rejected"' >/dev/null
}

landing_channel_commit_candidates() {
  local work="$1" gid="$2" root_uid root_gid
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  landing_channel_atomic_install_file "$work/runtime.sh" "$LANDING_CHANNEL_RUNTIME_PATH" 640 "$root_uid" "$gid" || return 1
  landing_channel_atomic_install_file "$work/agent" "$LANDING_CHANNEL_AGENT_PATH" 750 "$root_uid" "$gid" || return 1
  landing_channel_atomic_install_file "$work/helper" "$LANDING_AGENT_HELPER_PATH" 700 "$root_uid" "$root_gid" || return 1
  landing_channel_atomic_install_file "$work/startup-recovery.service" \
    "$LANDING_STARTUP_RECOVERY_UNIT_PATH" 644 "$root_uid" "$root_gid" || return 1
  landing_channel_atomic_install_file "$work/singbox-recovery.conf" \
    "$LANDING_STARTUP_RECOVERY_DROPIN_PATH" 644 "$root_uid" "$root_gid" || return 1
  landing_startup_recovery_daemon_reload || return 1
  landing_channel_atomic_install_file "$work/sudoers" "$LANDING_CHANNEL_SUDOERS_PATH" 440 "$root_uid" "$root_gid" || return 1
  landing_channel_atomic_install_file "$work/generation" "$LANDING_CHANNEL_GENERATION_PATH" 440 "$root_uid" "$gid" || return 1
  landing_channel_probe_entrypoints || return 1
  landing_channel_atomic_install_file "$work/identity.json" "$LANDING_CHANNEL_IDENTITY_PATH" 600 "$root_uid" "$root_gid" || return 1
}

landing_channel_activate_remote_entry() {
  local work="$1" gid="$2" root_uid
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  [[ "$gid" =~ ^[0-9]+$ && "$gid" != 0 ]] || return 1
  # SSH key 最后激活，避免首次失败时暴露半安装通道。
  landing_channel_atomic_install_file "$work/authorized_keys" "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH" 640 "$root_uid" "$gid" || return 1
}

landing_channel_candidates_match_installed() {
  local work="$1" candidate logical path
  while IFS=$'\t' read -r candidate logical; do
    path="$(landing_channel_path "$logical")" || return 1
    cmp -s -- "$work/$candidate" "$path" || return 1
  done <<EOF
runtime.sh	$LANDING_CHANNEL_RUNTIME_PATH
agent	$LANDING_CHANNEL_AGENT_PATH
helper	$LANDING_AGENT_HELPER_PATH
sudoers	$LANDING_CHANNEL_SUDOERS_PATH
generation	$LANDING_CHANNEL_GENERATION_PATH
identity.json	$LANDING_CHANNEL_IDENTITY_PATH
authorized_keys	$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH
startup-recovery.service	$LANDING_STARTUP_RECOVERY_UNIT_PATH
singbox-recovery.conf	$LANDING_STARTUP_RECOVERY_DROPIN_PATH
EOF
}

landing_channel_install_unlocked() {
  local landing_id="$1" allowed_ipv4="$2" work="$3" identity uid gid mode transaction_rc=0
  identity="$(landing_channel_path "$LANDING_CHANNEL_IDENTITY_PATH")" || return 1
  if [[ -e "$identity" || -L "$identity" ]]; then
    landing_channel_upgrade_source_is_valid || return 1
    [[ "$(jq -r '.landing_id' "$identity")" == "$landing_id" ]] || return 1
    uid="$(jq -r '.uid' "$identity")" || return 1
    gid="$(jq -r '.gid' "$identity")" || return 1
    landing_channel_render_identity "$landing_id" "$allowed_ipv4" "$uid" "$gid" \
      "$work" "$work/identity.json" || return 1
    if landing_channel_candidates_match_installed "$work"; then
      return 0
    fi
    mode=update
  else
    landing_channel_fresh_preflight || return 1
    mode=fresh
    uid=""
    gid=""
  fi
  if [[ "$mode" == update ]]; then
    landing_channel_account_has_no_processes "$uid" || return 1
  fi
  landing_channel_begin_transaction "$mode" "$uid" "$gid" || return 1
  set_signal_rollback landing_channel_signal_rollback || {
    landing_channel_reset_active_transaction
    landing_channel_discard_transaction_directory || true
    return 1
  }
  if [[ "$mode" == fresh ]]; then
    if ! landing_channel_create_account; then
      landing_channel_rollback_install || true
      return 1
    fi
    uid="$LANDING_CHANNEL_ACTIVE_UID"
    gid="$LANDING_CHANNEL_ACTIVE_GID"
    # useradd 只检查账户数据库；立即拒绝仍以该数值 UID 运行的孤儿进程，
    # 不让它在最终二次检查前看见 helper、sudoers 或身份材料。
    if ! landing_channel_account_has_no_processes "$uid"; then
      landing_channel_rollback_install || true
      return 1
    fi
  fi
  if [[ "$mode" == update ]] &&
     { ! landing_channel_remove_file "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH" ||
       ! landing_channel_account_has_no_processes "$uid"; }; then
    landing_channel_rollback_install || true
    return 1
  fi
  if [[ "$mode" == fresh ]] &&
     ! landing_channel_render_identity "$landing_id" "$allowed_ipv4" "$uid" "$gid" "$work" "$work/identity.json"; then
    landing_channel_rollback_install || true
    return 1
  fi
  if [[ "$mode" == fresh ]] &&
     { ! landing_channel_persist_install_candidates "$work" ||
       ! landing_channel_update_active_journal files_active "$uid" "$gid"; }; then
    landing_channel_rollback_install || true
    return 1
  fi
  if ! landing_channel_prepare_directories "$gid" ||
     ! landing_channel_commit_candidates "$work" "$gid" ||
     ! landing_channel_account_has_no_processes "$uid" ||
     ! landing_channel_activate_remote_entry "$work" "$gid" ||
     ! landing_restricted_channel_is_valid; then
    landing_channel_rollback_install || true
    return 1
  fi
  landing_channel_commit_active_transaction || transaction_rc=$?
  if [[ "$transaction_rc" == 1 ]]; then
    landing_channel_rollback_install || true
    return 1
  fi
  [[ "$transaction_rc" == 0 ]]
}

landing_channel_has_no_managed_apply_state() {
  local logical path receipt transaction
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true && -n "${SB_LANDING_RECEIPT_FILE:-}" ]]; then
    receipt="$SB_LANDING_RECEIPT_FILE"
    [[ "$receipt" == /* && "$receipt" != *$'\n'* ]] || return 1
  else
    [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ||
       "$LANDING_RECEIPT_FILE" == /var/lib/sb-user-manager/landing-receipt.json ]] || return 1
    receipt="$(landing_channel_path /var/lib/sb-user-manager/landing-receipt.json)" || return 1
  fi
  transaction="$(landing_channel_apply_transaction_path)" || return 1
  for path in "$receipt" "$transaction"; do
    [[ ! -e "$path" && ! -L "$path" ]] || return 1
  done
  for logical in "$LANDING_TLS_DIRECTORY" "$LANDING_NFTABLES_RULES_PATH"; do
    path="$(landing_managed_path "$logical")" || return 1
    [[ ! -e "$path" && ! -L "$path" ]] || return 1
  done
  landing_startup_config_has_no_managed_residue || return 1
  landing_apply_live_nft_is_missing
}

landing_channel_ensure_persistent_lock_file() {
  local logical="$1" path parent root_uid root_gid
  path="$(landing_channel_path "$logical")" || return 1
  parent="$(dirname -- "$path")" || return 1
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  landing_channel_directory_matches "$parent" 700 "$root_uid" "$root_gid" || return 1
  if [[ -e "$path" || -L "$path" ]]; then
    landing_channel_file_matches "$path" 600 "$root_uid" "$root_gid"
    return
  fi
  (umask 077; : > "$path") || return 1
  landing_channel_apply_ownership "$path" "$root_uid" "$root_gid" || return 1
  chmod 600 "$path" || return 1
  landing_channel_file_matches "$path" 600 "$root_uid" "$root_gid" || return 1
  sync_transaction_path "$path" || return 1
  sync_transaction_path "$parent" || return 1
}

landing_channel_apply_transaction_path() {
  local fixed_path=/var/lib/sb-user-manager/landing-apply-transaction
  landing_channel_apply_transaction_setting_is_safe || return 1
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" == true ]]; then
    if [[ -n "${SB_LANDING_APPLY_TRANSACTION_DIRECTORY:-}" ]]; then
      [[ "$SB_LANDING_APPLY_TRANSACTION_DIRECTORY" == /* &&
         "$SB_LANDING_APPLY_TRANSACTION_DIRECTORY" != *$'\n'* ]] || return 1
      printf '%s\n' "$SB_LANDING_APPLY_TRANSACTION_DIRECTORY"
    else
      landing_channel_path "$fixed_path"
    fi
    return
  fi
  [[ -z "${SB_LANDING_APPLY_TRANSACTION_DIRECTORY:-}" ]] || return 1
  landing_channel_path "$fixed_path"
}

landing_channel_apply_transaction_is_absent() {
  local transaction
  transaction="$(landing_channel_apply_transaction_path)" || return 1
  [[ ! -e "$transaction" && ! -L "$transaction" ]]
}

with_landing_channel_lock() {
  local callback="$1" lock lock_dir root_uid root_gid rc
  shift
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  landing_channel_ensure_system_directory /var || return 1
  landing_channel_ensure_system_directory /var/lib || return 1
  landing_channel_ensure_owned_directory /var/lib/sb-user-manager 700 "$root_uid" "$root_gid" || return 1
  lock="$(landing_channel_path "$LANDING_CHANNEL_LOCK_PATH")" || return 1
  lock_dir="$(dirname -- "$lock")" || return 1
  landing_channel_ensure_persistent_lock_file "$LANDING_CHANNEL_LOCK_PATH" || return 1
  exec 5<>"$lock" || return 1
  flock -x -w "$LANDING_CHANNEL_LOCK_TIMEOUT" 5 || { exec 5>&-; return 1; }
  if ! landing_channel_ensure_persistent_lock_file "$LANDING_CHANNEL_INPUT_LOCK_PATH" 5>&-; then
    rc=1
  elif ! landing_channel_apply_transaction_is_absent 5>&-; then
    rc=1
  elif landing_channel_recover_pending_transaction 5>&-; then
    "$callback" "$@" 5>&- && rc=0 || rc=$?
  else
    rc=1
  fi
  if [[ -n "$LANDING_CHANNEL_ACTIVE_MODE" ]]; then
    # 失败恢复只留持久 journal/snapshot；延迟信号不得在释放锁后再次并发回滚。
    landing_channel_reset_active_transaction
  fi
  flock -u 5 2>/dev/null || true
  exec 5>&-
  sync_transaction_path "$lock_dir" || rc=1
  return "$rc"
}

with_landing_channel_shared_lock() {
  local callback="$1" lock lock_dir root_uid root_gid transaction rc
  shift
  landing_channel_runtime_paths_are_safe || return 1
  landing_channel_state_parent_chain_is_safe || return 1
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  lock="$(landing_channel_path "$LANDING_CHANNEL_LOCK_PATH")" || return 1
  lock_dir="$(dirname -- "$lock")" || return 1
  transaction="$(landing_channel_path "$LANDING_CHANNEL_TRANSACTION_DIRECTORY")" || return 1
  landing_channel_directory_matches "$lock_dir" 700 "$root_uid" "$root_gid" || return 1
  landing_channel_file_matches "$lock" 600 "$root_uid" "$root_gid" || return 1
  exec 5<>"$lock" || return 1
  flock -s -w "$LANDING_CHANNEL_LOCK_TIMEOUT" 5 || { exec 5>&-; return 1; }
  if [[ -e "$transaction" || -L "$transaction" ]]; then
    rc=1
  else
    "$callback" "$@" 5>&- && rc=0 || rc=$?
  fi
  flock -u 5 2>/dev/null || true
  exec 5>&-
  return "$rc"
}

with_landing_channel_input_lock() {
  local callback="$1" lock lock_dir root_uid root_gid rc
  shift
  landing_channel_runtime_paths_are_safe || return 1
  landing_channel_state_parent_chain_is_safe || return 1
  root_uid="$(landing_channel_expected_root_uid)" || return 1
  root_gid="$(landing_channel_expected_root_gid)" || return 1
  lock="$(landing_channel_path "$LANDING_CHANNEL_INPUT_LOCK_PATH")" || return 1
  lock_dir="$(dirname -- "$lock")" || return 1
  landing_channel_directory_matches "$lock_dir" 700 "$root_uid" "$root_gid" || return 1
  landing_channel_file_matches "$lock" 600 "$root_uid" "$root_gid" || return 1
  exec 4<>"$lock" || return 1
  flock -n 4 || { exec 4>&-; return 1; }
  "$callback" "$@" 4>&- && rc=0 || rc=$?
  flock -u 4 2>/dev/null || true
  exec 4>&-
  return "$rc"
}

install_landing_restricted_channel() {
  [[ $# -eq 3 ]] || return 64
  local landing_id="$1" allowed_ipv4="$2" public_key_file="$3" work rc=0
  local PATH="${PATH:-}" LC_ALL="${LC_ALL:-}"
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    PATH=/usr/sbin:/usr/bin:/sbin:/bin
    LC_ALL=C
    export PATH LC_ALL
    unset BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH OPENSSL_CONF
  fi
  landing_channel_runtime_paths_are_safe || return 1
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true && "$EUID" -ne 0 ]]; then return 77; fi
  landing_channel_dependencies_are_ready || return 1
  # 在创建账户或事务前拒绝不受 root 独占的固定系统目录；写入阶段仍会逐项复核。
  landing_channel_install_system_paths_are_safe || return 1
  landing_id_is_valid "$landing_id" || return 1
  is_public_ipv4 "$allowed_ipv4" || return 1
  work="$(mktemp -d /tmp/sb-landing-channel.XXXXXX)" || return 1
  register_temp_path "$work" || { rm -rf -- "$work" || true; return 1; }
  if ! landing_channel_prepare_candidates "$landing_id" "$allowed_ipv4" "$public_key_file" "$work"; then
    rm -rf -- "$work" || true
    return 1
  fi
  with_landing_channel_lock landing_channel_install_unlocked "$landing_id" "$allowed_ipv4" "$work" || rc=$?
  rm -rf -- "$work" || rc=1
  return "$rc"
}

landing_channel_uninstall_unlocked() {
  [[ $# -eq 0 ]] || return 64
  local identity uid gid transaction_rc=0
  identity="$(landing_channel_path "$LANDING_CHANNEL_IDENTITY_PATH")" || return 1
  landing_channel_has_no_managed_apply_state || return 1
  if [[ ! -e "$identity" && ! -L "$identity" ]]; then
    landing_startup_recovery_gate_files_are_absent || return 1
    # 覆盖上一次已提交卸载在 stop 前被 SIGKILL/失败的幂等收尾。
    landing_startup_recovery_stop
    return
  fi
  landing_restricted_channel_is_valid || return 1
  uid="$(jq -r '.uid' "$identity")" || return 1
  gid="$(jq -r '.gid' "$identity")" || return 1
  landing_channel_home_layout_is_expected || return 1
  landing_channel_runtime_layout_is_expected || return 1
  landing_channel_account_has_no_processes "$uid" || return 1
  landing_channel_begin_transaction uninstall "$uid" "$gid" || return 1
  set_signal_rollback landing_channel_signal_rollback || {
    landing_channel_reset_active_transaction
    landing_channel_discard_transaction_directory || true
    return 1
  }
  if ! landing_channel_remove_file "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH" ||
     ! landing_channel_account_has_no_processes "$uid" ||
     ! landing_channel_remove_file "$LANDING_CHANNEL_SUDOERS_PATH" ||
     ! landing_channel_remove_file "$LANDING_STARTUP_RECOVERY_DROPIN_PATH" ||
     ! landing_startup_recovery_daemon_reload ||
     ! landing_channel_remove_file "$LANDING_STARTUP_RECOVERY_UNIT_PATH" ||
     ! landing_startup_recovery_daemon_reload ||
     ! landing_channel_remove_file "$LANDING_AGENT_HELPER_PATH" ||
     ! landing_channel_remove_file "$LANDING_CHANNEL_AGENT_PATH" ||
     ! landing_channel_remove_file "$LANDING_CHANNEL_RUNTIME_PATH" ||
     ! landing_channel_remove_file "$LANDING_CHANNEL_GENERATION_PATH" ||
     ! landing_channel_remove_file "$LANDING_CHANNEL_IDENTITY_PATH"; then
    landing_channel_rollback_uninstall || true
    return 1
  fi
  if ! landing_channel_remove_empty_directory "$LANDING_CHANNEL_SSH_DIRECTORY" ||
     ! landing_channel_remove_empty_directory "$LANDING_CHANNEL_HOME" ||
     ! landing_channel_remove_empty_directory "$LANDING_CHANNEL_RUNTIME_DIRECTORY"; then
    landing_channel_rollback_uninstall || true
    return 1
  fi
  landing_channel_account_has_no_processes "$uid" || {
    landing_channel_rollback_uninstall || true
    return 1
  }
  if ! landing_channel_system_userdel "$LANDING_CHANNEL_ACCOUNT"; then
    landing_channel_rollback_uninstall || true
    return 1
  fi
  landing_channel_sync_account_database || {
    landing_channel_rollback_uninstall || true
    return 1
  }
  landing_channel_account_is_absent || {
    landing_channel_rollback_uninstall || true
    return 1
  }
  if ! landing_channel_remove_expected_group_if_present "$gid"; then
    landing_channel_rollback_uninstall || true
    return 1
  fi
  landing_channel_account_is_absent || {
    landing_channel_rollback_uninstall || true
    return 1
  }
  landing_channel_group_is_absent || {
    landing_channel_rollback_uninstall || true
    return 1
  }
  landing_channel_commit_active_transaction || transaction_rc=$?
  if [[ "$transaction_rc" == 1 ]]; then
    landing_channel_rollback_uninstall || true
    return 1
  fi
  [[ "$transaction_rc" == 0 ]] || return 1
  # 文件事务已经终结，drop-in 也已从 systemd 依赖图移除；此时停止仍被加载的
  # oneshot 不会触发 sing-box，也不会让失败回滚遗漏 systemd 运行态。
  landing_startup_recovery_stop
}

# 公开接口固定为零参数，$# 检查用于拒绝未来调用方意外扩权。
# shellcheck disable=SC2120
uninstall_landing_restricted_channel() {
  [[ $# -eq 0 ]] || return 64
  local rc=0
  local PATH="${PATH:-}" LC_ALL="${LC_ALL:-}"
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true ]]; then
    PATH=/usr/sbin:/usr/bin:/sbin:/bin
    LC_ALL=C
    export PATH LC_ALL
    unset BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH OPENSSL_CONF
  fi
  landing_channel_runtime_paths_are_safe || return 1
  if [[ "${SB_USER_MANAGER_LIBRARY:-false}" != true && "$EUID" -ne 0 ]]; then return 77; fi
  landing_channel_dependencies_are_ready || return 1
  with_landing_channel_lock landing_channel_uninstall_unlocked || rc=$?
  return "$rc"
}
