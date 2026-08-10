#!/usr/bin/env bash
# 此测试会在临时本地 sshd 中验证真实账户、authorized_keys 与 sudoers 边界。
# shellcheck disable=SC2034,SC2317
set -Eeuo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
LC_ALL=C
export LC_ALL
umask 077

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
REQUIRE_E2E="${SB_REQUIRE_LANDING_CHANNEL_E2E:-false}"
E2E_CONTAINER="${SB_LANDING_CHANNEL_E2E_CONTAINER:-false}"
NORMALIZE_LOCAL_BIN="${SB_LANDING_CHANNEL_E2E_NORMALIZE_LOCAL_BIN:-false}"

fail() {
  printf 'landing channel e2e test failed: %s\n' "$1" >&2
  exit 1
}

skip_or_fail() {
  local reason="$1"
  if [[ "$REQUIRE_E2E" == true ]]; then
    fail "$reason"
  fi
  printf 'landing channel e2e test skipped: %s\n' "$reason"
  exit 0
}

case "$REQUIRE_E2E" in
  true|false) ;;
  *) fail 'SB_REQUIRE_LANDING_CHANNEL_E2E must be true or false' ;;
esac
case "$E2E_CONTAINER" in
  true|false) ;;
  *) fail 'SB_LANDING_CHANNEL_E2E_CONTAINER must be true or false' ;;
esac
case "$NORMALIZE_LOCAL_BIN" in
  true|false) ;;
  *) fail 'SB_LANDING_CHANNEL_E2E_NORMALIZE_LOCAL_BIN must be true or false' ;;
esac

[[ "$(uname -s)" == Linux ]] || skip_or_fail 'Linux is required'
((EUID == 0)) || skip_or_fail 'root is required'

required_commands=(
  base64 flock getent groupadd groupdel ip jq nft openssl python3 readlink sha256sum ssh ssh-keygen sshd
  setpriv sudo systemctl timeout unshare useradd userdel visudo
)
missing_commands=()
for command_name in "${required_commands[@]}"; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    missing_commands+=("$command_name")
  fi
done
if ((${#missing_commands[@]} > 0)); then
  skip_or_fail "missing dependencies: ${missing_commands[*]}"
fi
fixed_executables=(
  /bin/bash /bin/cat /bin/chmod /bin/rm /bin/sh /usr/bin/awk /usr/bin/base64 /usr/bin/env
  /usr/bin/getent /usr/bin/id /usr/bin/mktemp /usr/bin/ps /usr/bin/python3 /usr/bin/sha256sum
  /usr/bin/setpriv /usr/bin/ssh-keygen /usr/bin/sudo /usr/bin/systemctl /usr/bin/uname \
  /usr/sbin/groupadd /usr/sbin/groupdel
  /usr/sbin/useradd /usr/sbin/userdel /usr/sbin/visudo
)
missing_executables=()
for executable in "${fixed_executables[@]}"; do
  if [[ ! -x "$executable" ]]; then
    missing_executables+=("$executable")
  fi
done
if ((${#missing_executables[@]} > 0)); then
  skip_or_fail "missing fixed executables: ${missing_executables[*]}"
fi

if [[ "$E2E_CONTAINER" == true ]]; then
  [[ -e /.dockerenv || -e /run/.containerenv ]] ||
    skip_or_fail 'the declared isolated container marker is missing'
elif [[ "${SB_LANDING_CHANNEL_E2E_IN_NETNS:-false}" != true ]]; then
  if ! unshare --net -- ip link set lo up 2>/dev/null; then
    skip_or_fail 'an isolated network namespace is required'
  fi
  export SB_LANDING_CHANNEL_E2E_IN_NETNS=true
  export SB_REQUIRE_LANDING_CHANNEL_E2E="$REQUIRE_E2E"
  export SB_LANDING_CHANNEL_E2E_NORMALIZE_LOCAL_BIN="$NORMALIZE_LOCAL_BIN"
  exec unshare --net -- bash "$ROOT/tests/test-landing-channel-e2e.sh"
fi
if [[ "$E2E_CONTAINER" != true ]]; then
  [[ "$(readlink /proc/self/ns/net)" != "$(readlink /proc/1/ns/net)" ]] ||
    skip_or_fail 'the isolated network namespace marker is invalid'
fi

ip link set lo up
ip address add 8.8.8.8/32 dev lo
ip address add 1.1.1.1/32 dev lo

work="$(mktemp -d /tmp/sb-landing-channel-e2e.XXXXXX)"
chmod 700 "$work"
cleanup_armed=false
sshd_pid=""
slow_ssh_pid=""
sshd_runtime_dir_created=false
manager_runtime_created=false
manager_runtime_directory_created=false
usr_local_bin_mode_changed=false
usr_local_bin_original_mode=""
account_probe_pid=""
account_probe_supervisor_pid=""
stale_helper_pid=""
client_fingerprint=""
wrong_fingerprint=""
systemctl_stub_installed=false
systemctl_original_mode=""
systemctl_original_uid=""
systemctl_original_gid=""
systemctl_original_sha256=""
systemctl_backup="$work/systemctl.original"
systemctl_stub="$work/systemctl.stub"
systemctl_gate_state="$work/systemctl-gate.active"
systemctl_events="$work/systemctl.events"
controller_receipt_owned=false
controller_receipt_sha=""
controller_receipt_nonce=""
bootstrap_receipt_owned=false
bootstrap_id=""
bootstrap_root_authorized_keys_owned=false
bootstrap_root_authorized_keys=""
bootstrap_root_key=""

channel_account=sb-landing-agent
channel_group=sb-landing-agent
channel_home=/var/lib/sb-user-manager-landing
channel_ssh_directory=/var/lib/sb-user-manager-landing/.ssh
channel_generation=/var/lib/sb-user-manager-landing/.channel-generation
channel_authorized_keys="$channel_home/.ssh/authorized_keys"
channel_agent=/usr/local/bin/sb-user-manager-landing-agent
channel_helper=/usr/local/libexec/sb-user-manager-landing-apply
channel_runtime_directory=/usr/local/libexec/sb-user-manager
channel_runtime=/usr/local/libexec/sb-user-manager/landing-runtime.sh
channel_identity=/var/lib/sb-user-manager/landing-channel.json
channel_lock=/var/lib/sb-user-manager/landing-channel.lock
channel_input_lock=/var/lib/sb-user-manager/landing-channel-input.lock
channel_transaction=/var/lib/sb-user-manager/landing-channel-transaction
bootstrap_receipt=/var/lib/sb-user-manager/landing-bootstrap.json
channel_sudoers=/etc/sudoers.d/sb-user-manager-landing-agent
channel_recovery_unit=/etc/systemd/system/sb-user-manager-landing-recovery.service
channel_recovery_dropin=/etc/systemd/system/sing-box.service.d/10-sb-user-manager-landing-recovery.conf
manager_runtime=/usr/local/sbin/sb-user-manager

cleanup() {
  local rc=$? cleanup_rc=0 path cleanup_identity_owned=false
  trap - EXIT HUP INT QUIT TERM

  if [[ -n "$slow_ssh_pid" ]] && kill -0 "$slow_ssh_pid" 2>/dev/null; then
    kill "$slow_ssh_pid" 2>/dev/null || true
    wait "$slow_ssh_pid" 2>/dev/null || true
  fi

  if [[ -n "$sshd_pid" ]] && kill -0 "$sshd_pid" 2>/dev/null; then
    kill "$sshd_pid" 2>/dev/null || true
    wait "$sshd_pid" 2>/dev/null || true
  fi

  if [[ -n "$account_probe_pid" ]] && kill -0 "$account_probe_pid" 2>/dev/null; then
    kill "$account_probe_pid" 2>/dev/null || true
  fi
  if [[ -n "$account_probe_supervisor_pid" ]]; then
    wait "$account_probe_supervisor_pid" 2>/dev/null || true
  fi
  if [[ -n "$stale_helper_pid" ]] && kill -0 "$stale_helper_pid" 2>/dev/null; then
    kill "$stale_helper_pid" 2>/dev/null || true
    wait "$stale_helper_pid" 2>/dev/null || true
  fi

  if [[ "$controller_receipt_owned" == true ]]; then
    if [[ ! -e "$LANDING_RECEIPT_FILE" && ! -L "$LANDING_RECEIPT_FILE" ]]; then
      controller_receipt_owned=false
    elif [[ -f "$LANDING_RECEIPT_FILE" && ! -L "$LANDING_RECEIPT_FILE" ]] &&
         jq -e --arg sha "$controller_receipt_sha" --arg nonce "$controller_receipt_nonce" '
           .landing_id == "e2e-local" and .applied_revision == 1 and
           .content_sha256 == $sha and .nonce == $nonce
         ' "$LANDING_RECEIPT_FILE" >/dev/null 2>&1 &&
         rm -f -- "$LANDING_RECEIPT_FILE"; then
      controller_receipt_owned=false
    else
      printf 'landing channel e2e cleanup refused: controller receipt is not owned by this test\n' >&2
      cleanup_rc=1
    fi
  fi

  if [[ "$bootstrap_receipt_owned" == true ]]; then
    if [[ -f "$bootstrap_receipt" && ! -L "$bootstrap_receipt" ]] &&
       jq -e --arg bootstrap_id "$bootstrap_id" \
         '.bootstrap_id == $bootstrap_id and .landing_id == "e2e-local"' \
         "$bootstrap_receipt" >/dev/null 2>&1; then
      if [[ -f "$channel_identity" && ! -L "$channel_identity" ]]; then
        uninstall_landing_restricted_channel || cleanup_rc=1
      fi
      if [[ ! -e "$channel_identity" && ! -L "$channel_identity" ]] &&
         rm -f -- "$bootstrap_receipt"; then
        bootstrap_receipt_owned=false
      else
        printf 'landing channel e2e cleanup failed: bootstrap receipt could not be safely removed\n' >&2
        cleanup_rc=1
      fi
    elif [[ ! -e "$bootstrap_receipt" && ! -L "$bootstrap_receipt" ]]; then
      bootstrap_receipt_owned=false
    else
      printf 'landing channel e2e cleanup refused: bootstrap receipt is not owned by this test\n' >&2
      cleanup_rc=1
    fi
  fi

  if [[ "$cleanup_armed" == true ]] &&
     declare -F uninstall_landing_restricted_channel >/dev/null 2>&1; then
    if [[ -f "$channel_identity" && ! -L "$channel_identity" ]] &&
       jq -e --arg landing_id e2e-local --arg client "$client_fingerprint" \
         --arg alternate "$wrong_fingerprint" '
           .landing_id == $landing_id and
           ((($client | length) > 0 and .public_key_fingerprint == $client) or
            (($alternate | length) > 0 and .public_key_fingerprint == $alternate))
         ' \
         "$channel_identity" >/dev/null 2>&1; then
      cleanup_identity_owned=true
    fi
    if [[ "$cleanup_identity_owned" != true ]]; then
      printf 'landing channel e2e cleanup refused: identity is not owned by this test\n' >&2
      cleanup_rc=1
    elif ! uninstall_landing_restricted_channel; then
      printf 'landing channel e2e cleanup failed: managed uninstall failed\n' >&2
      cleanup_rc=1
    fi
    if [[ "$cleanup_identity_owned" == true ]] && landing_restricted_channel_is_valid; then
      printf 'landing channel e2e cleanup failed: removed channel is still valid\n' >&2
      cleanup_rc=1
    fi
    if getent passwd "$channel_account" >/dev/null 2>&1 ||
       getent group "$channel_group" >/dev/null 2>&1; then
      printf 'landing channel e2e cleanup failed: managed account or group remains\n' >&2
      cleanup_rc=1
    fi
    for path in "$channel_generation" "$channel_authorized_keys" "$channel_ssh_directory" \
      "$channel_home" "$channel_agent" "$channel_helper" "$channel_runtime" \
      "$channel_runtime_directory" "$channel_identity" "$channel_sudoers" "$channel_transaction" \
      "$channel_recovery_unit" "$channel_recovery_dropin"; do
      if [[ -e "$path" || -L "$path" ]]; then
        printf 'landing channel e2e cleanup failed: managed path remains: %s\n' "$path" >&2
        cleanup_rc=1
      fi
    done
  fi

  if [[ "$usr_local_bin_mode_changed" == true ]]; then
    if [[ -d /usr/local/bin && ! -L /usr/local/bin &&
          "$(stat -c '%u:%g' -- /usr/local/bin 2>/dev/null)" == 0:0 ]] &&
       chmod "$usr_local_bin_original_mode" -- /usr/local/bin; then
      usr_local_bin_mode_changed=false
    else
      printf 'landing channel e2e cleanup failed: could not restore /usr/local/bin mode\n' >&2
      cleanup_rc=1
    fi
  fi

  if [[ "$sshd_runtime_dir_created" == true ]]; then
    rmdir -- /run/sshd 2>/dev/null || true
  fi
  if [[ "$manager_runtime_created" == true ]]; then
    rm -f -- "$manager_runtime"
  fi
  if [[ "$manager_runtime_directory_created" == true ]]; then
    rmdir -- /usr/local/sbin 2>/dev/null || true
  fi
  if [[ "$systemctl_stub_installed" == true ]]; then
    if [[ -f "$systemctl_backup" && ! -L "$systemctl_backup" ]] &&
       install -m "$systemctl_original_mode" -- "$systemctl_backup" /usr/bin/systemctl &&
       chown "$systemctl_original_uid:$systemctl_original_gid" -- /usr/bin/systemctl &&
       [[ "$(sha256sum /usr/bin/systemctl | awk '{print $1}')" == "$systemctl_original_sha256" ]]; then
      systemctl_stub_installed=false
    else
      printf 'landing channel e2e cleanup failed: could not restore /usr/bin/systemctl\n' >&2
      cleanup_rc=1
    fi
  fi
  if [[ "$bootstrap_root_authorized_keys_owned" == true ]]; then
    if [[ "$bootstrap_root_authorized_keys" =~ ^/run/sb-user-manager-bootstrap-e2e\.[A-Za-z0-9]{6}$ &&
          -f "$bootstrap_root_authorized_keys" && ! -L "$bootstrap_root_authorized_keys" &&
          "$(stat -c '%u:%g:%a' -- "$bootstrap_root_authorized_keys" 2>/dev/null)" == 0:0:600 &&
          -f "$bootstrap_root_key.pub" &&
          "$(stat -c '%u:%g:%a' -- "$bootstrap_root_key.pub" 2>/dev/null)" == 0:0:600 ]] &&
       cmp -s -- "$bootstrap_root_key.pub" "$bootstrap_root_authorized_keys" &&
       rm -f -- "$bootstrap_root_authorized_keys"; then
      bootstrap_root_authorized_keys_owned=false
    else
      printf 'landing channel e2e cleanup refused: root bootstrap key fixture is not owned by this test\n' >&2
      cleanup_rc=1
    fi
  fi
  rm -rf -- "$work"
  if ((rc == 0 && cleanup_rc != 0)); then
    rc="$cleanup_rc"
  fi
  exit "$rc"
}

install_container_systemctl_stub() {
  [[ "$E2E_CONTAINER" == true && ( -e /.dockerenv || -e /run/.containerenv ) ]] ||
    return 1
  [[ "$work" =~ ^/tmp/sb-landing-channel-e2e\.[A-Za-z0-9]+$ ]] || return 1
  [[ -f /usr/bin/systemctl && ! -L /usr/bin/systemctl ]] || return 1
  [[ "$(stat -c '%u:%g' -- /usr/bin/systemctl)" == 0:0 ]] || return 1
  systemctl_original_mode="$(stat -c '%a' -- /usr/bin/systemctl)" || return 1
  systemctl_original_uid="$(stat -c '%u' -- /usr/bin/systemctl)" || return 1
  systemctl_original_gid="$(stat -c '%g' -- /usr/bin/systemctl)" || return 1
  systemctl_original_sha256="$(sha256sum /usr/bin/systemctl | awk '{print $1}')" || return 1
  [[ "$systemctl_original_mode" =~ ^[0-7]{3,4}$ &&
     "$systemctl_original_uid" == 0 && "$systemctl_original_gid" == 0 &&
     "$systemctl_original_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
  cp -p -- /usr/bin/systemctl "$systemctl_backup" || return 1
  {
    printf '#!/bin/bash\nset -Eeuo pipefail\n'
    printf 'state=%q\n' "$systemctl_gate_state"
    printf 'events=%q\n' "$systemctl_events"
    printf 'unit=%q\n' 'sb-user-manager-landing-recovery.service'
    printf 'helper=%q\n' "$channel_helper"
    cat <<'EOF'
printf '%q ' "$@" >> "$events"
printf '\n' >> "$events"
case "${1:-}" in
  daemon-reload)
    [[ $# -eq 1 ]]
    ;;
  start)
    [[ $# -eq 2 && "$2" == "$unit" ]] || exit 64
    if [[ ! -e "$state" && ! -L "$state" ]]; then
      [[ -x "$helper" && ! -L "$helper" ]] || exit 1
      "$helper" --recover-startup </dev/null >/dev/null 2>&1 || exit 1
      (umask 077; : > "$state") || exit 1
    fi
    [[ -f "$state" && ! -L "$state" ]]
    ;;
  is-active)
    quiet=false
    if [[ "${2:-}" == --quiet ]]; then
      [[ $# -eq 3 ]] || exit 64
      quiet=true
      target="$3"
    else
      [[ $# -eq 2 ]] || exit 64
      target="$2"
    fi
    if [[ "$target" == "$unit" && -f "$state" && ! -L "$state" ]]; then
      [[ "$quiet" == true ]] || printf 'active\n'
      exit 0
    fi
    [[ "$quiet" == true ]] || printf 'inactive\n'
    exit 3
    ;;
  stop)
    [[ $# -eq 2 && "$2" == "$unit" ]] || exit 64
    rm -f -- "$state"
    ;;
  *) exit 64 ;;
esac
EOF
  } > "$systemctl_stub" || return 1
  chmod 700 "$systemctl_stub" || return 1
  chown 0:0 "$systemctl_stub" || return 1
  : > "$systemctl_events" || return 1
  chmod 600 "$systemctl_events" || return 1
  systemctl_stub_installed=true
  install -m 700 -- "$systemctl_stub" /usr/bin/systemctl || return 1
  chown 0:0 -- /usr/bin/systemctl || return 1
  [[ -f /usr/bin/systemctl && ! -L /usr/bin/systemctl && -x /usr/bin/systemctl ]]
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 131' QUIT
trap 'exit 143' TERM

if [[ "$E2E_CONTAINER" == true ]]; then
  install_container_systemctl_stub ||
    fail 'could not install the disposable-container systemctl fixture'
fi

export SB_USER_MANAGER_LIBRARY=true
export SB_CONTROLLER_STATE_FILE="$work/controller-state/controller-state.json"
export SB_CONTROLLER_SECRET_DIR="$work/controller-secrets"
export SB_CONTROLLER_STATE_LOCK_FILE="$work/controller-lock/controller-state.lock"
export SB_CONTROLLER_LANDING_WORK_ROOT="$work/controller-runtime"
unset SB_SYSTEM_ROOT
# shellcheck source=../sb-user-manager.sh
source "$ROOT/sb-user-manager.sh"
SB_USER_MANAGER_LIBRARY=false
export SB_USER_MANAGER_LIBRARY

for function_name in install_landing_restricted_channel \
  landing_restricted_channel_is_valid uninstall_landing_restricted_channel \
  controller_register_landing; do
  declare -F "$function_name" >/dev/null 2>&1 ||
    fail "required function is missing: $function_name"
done

[[ "${LANDING_CHANNEL_ACCOUNT:-}" == "$channel_account" ]] ||
  fail 'unexpected restricted account constant'
[[ "${LANDING_CHANNEL_GROUP:-}" == "$channel_group" ]] ||
  fail 'unexpected restricted group constant'

preexisting=false
if getent passwd "$channel_account" >/dev/null 2>&1 ||
   getent group "$channel_group" >/dev/null 2>&1; then
  preexisting=true
fi
for path in "$channel_home" "$channel_agent" "$channel_helper" \
  "$channel_runtime" "$channel_identity" "$channel_sudoers" "$channel_transaction" \
  "$channel_recovery_unit" "$channel_recovery_dropin"; do
  if [[ -e "$path" || -L "$path" ]]; then
    preexisting=true
  fi
done
if [[ "$preexisting" == true ]]; then
  skip_or_fail 'managed landing-channel resources already exist; refusing to alter them'
fi
if [[ -e "$manager_runtime" || -L "$manager_runtime" ]]; then
  skip_or_fail 'the fixed manager runtime already exists; refusing to replace it'
fi
if landing_restricted_channel_is_valid; then
  fail 'an absent restricted channel was reported as valid'
fi

# GitHub 托管 Ubuntu 会把该目录预置为 0777；测试仅在确认 root:root 普通目录后
# 临时移除危险写位，生产安装层仍严格拒绝不安全目录，EXIT 清理会恢复原模式。
[[ -d /usr/local/bin && ! -L /usr/local/bin ]] ||
  fail '/usr/local/bin is not a regular directory'
[[ "$(stat -c '%u:%g' -- /usr/local/bin)" == 0:0 ]] ||
  fail '/usr/local/bin is not owned by root:root'
landing_channel_system_directory_is_channel_traversable /usr ||
  fail '/usr is not safe for the restricted channel test'
landing_channel_system_directory_is_channel_traversable /usr/local ||
  fail '/usr/local is not safe for the restricted channel test'
usr_local_bin_mode="$(stat -c '%a' -- /usr/local/bin)" ||
  fail 'could not read /usr/local/bin mode'
[[ "$usr_local_bin_mode" =~ ^[0-7]{3,4}$ ]] ||
  fail '/usr/local/bin mode is invalid'
if (( (8#$usr_local_bin_mode & 0022) != 0 )); then
  [[ "$NORMALIZE_LOCAL_BIN" == true ]] ||
    fail '/usr/local/bin is writable; explicit isolated-fixture normalization is required'
  usr_local_bin_original_mode="$usr_local_bin_mode"
  usr_local_bin_mode_changed=true
  chmod go-w -- /usr/local/bin || fail 'could not secure /usr/local/bin for the isolated test'
fi
landing_channel_system_directory_is_channel_traversable /usr/local/bin ||
  fail '/usr/local/bin is not safe for the restricted channel test'

if [[ ! -d /usr/local/sbin ]]; then
  install -d -m 755 -- /usr/local/sbin
  manager_runtime_directory_created=true
fi
install -m 700 -- "$ROOT/sb-user-manager.sh" "$manager_runtime"
manager_runtime_created=true

client_key="$work/client-ed25519"
wrong_key="$work/wrong-ed25519"
host_key="$work/host-ed25519"
ssh-keygen -q -t ed25519 -N '' -f "$client_key"
ssh-keygen -q -t ed25519 -N '' -f "$wrong_key"
ssh-keygen -q -t ed25519 -N '' -f "$host_key"
chmod 600 "$client_key" "$wrong_key" "$host_key" "$client_key.pub"
client_fingerprint="$(ssh-keygen -lf "$client_key.pub" -E sha256 | awk 'NR == 1 {print $2}')"
[[ "$client_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{20,}={0,2}$ ]] ||
  fail 'test client fingerprint is invalid'
wrong_fingerprint="$(ssh-keygen -lf "$wrong_key.pub" -E sha256 | awk 'NR == 1 {print $2}')"
[[ "$wrong_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{20,}={0,2}$ ]] ||
  fail 'test rotation fingerprint is invalid'

if ! SSH_CONNECTION='203.0.113.10 50000 203.0.113.20 22' \
  install_landing_restricted_channel e2e-local 8.8.8.8 "$client_key.pub"; then
  fail 'restricted channel installation failed'
fi
cleanup_armed=true
landing_restricted_channel_is_valid || fail 'installed restricted channel is invalid'
[[ -f "$channel_recovery_unit" && ! -L "$channel_recovery_unit" &&
   "$(stat -c '%u:%g:%a' -- "$channel_recovery_unit")" == 0:0:644 ]] ||
  fail 'startup recovery unit is missing or unsafe'
[[ -f "$channel_recovery_dropin" && ! -L "$channel_recovery_dropin" &&
   "$(stat -c '%u:%g:%a' -- "$channel_recovery_dropin")" == 0:0:644 ]] ||
  fail 'sing-box recovery drop-in is missing or unsafe'
grep -Fxq 'RemainAfterExit=yes' "$channel_recovery_unit" ||
  fail 'startup recovery unit does not remain active'
grep -Fxq 'Requires=sb-user-manager-landing-recovery.service' "$channel_recovery_dropin" ||
  fail 'sing-box does not require the startup recovery gate'
grep -Fxq 'After=sb-user-manager-landing-recovery.service' "$channel_recovery_dropin" ||
  fail 'sing-box is not ordered after the startup recovery gate'
[[ -f "$channel_lock" && ! -L "$channel_lock" ]] ||
  fail 'persistent channel lock is missing or unsafe'
[[ "$(stat -c '%u:%g:%a' -- "$channel_lock")" == 0:0:600 ]] ||
  fail 'persistent channel lock must be root:root mode 600'
[[ -f "$channel_input_lock" && ! -L "$channel_input_lock" ]] ||
  fail 'persistent channel input lock is missing or unsafe'
[[ "$(stat -c '%u:%g:%a' -- "$channel_input_lock")" == 0:0:600 ]] ||
  fail 'persistent channel input lock must be root:root mode 600'

passwd_record="$(getent passwd "$channel_account")" ||
  fail 'restricted account was not created'
IFS=: read -r installed_name _ _ _ _ installed_home installed_shell <<< "$passwd_record"
[[ "$installed_name" == "$channel_account" ]] || fail 'restricted account name changed'
[[ "$installed_home" == "$channel_home" ]] || fail 'restricted account home changed'
[[ "$installed_shell" == /bin/sh ]] || fail 'restricted account shell is not /bin/sh'
shadow_record="$(getent shadow "$channel_account")" ||
  fail 'restricted account shadow record is unavailable'
IFS=: read -r shadow_name shadow_password _ <<< "$shadow_record"
[[ "$shadow_name" == "$channel_account" && "$shadow_password" == '*NP*' ]] ||
  fail 'restricted account password field is not *NP*'

[[ -f "$channel_authorized_keys" && ! -L "$channel_authorized_keys" ]] ||
  fail 'managed authorized_keys is missing or unsafe'
channel_gid="$(getent group "$channel_group" | cut -d: -f3)"
[[ "$channel_gid" =~ ^[0-9]+$ && "$channel_gid" != 0 ]] ||
  fail 'managed channel group id is invalid'
[[ "$(stat -c '%u:%g:%a' -- "$channel_authorized_keys")" == "0:${channel_gid}:640" ]] ||
  fail 'managed authorized_keys must be root:channel mode 640'
[[ "$(wc -l < "$channel_authorized_keys" | tr -d ' ')" == 1 ]] ||
  fail 'managed authorized_keys must contain exactly one record'
authorized_record="$(<"$channel_authorized_keys")"
public_key_blob="$(awk 'NR == 1 {print $2}' "$client_key.pub")"
channel_generation_value="$(jq -r '.generation' "$channel_identity")"
[[ "$channel_generation_value" =~ ^[0-9a-f]{64}$ ]] || fail 'identity generation is invalid'
[[ -f "$channel_generation" && ! -L "$channel_generation" ]] ||
  fail 'channel generation marker is missing or unsafe'
[[ "$(<"$channel_generation")" == "$channel_generation_value" ]] ||
  fail 'channel generation marker does not match the identity'
[[ "$authorized_record" == *'restrict'* ]] || fail 'authorized key lacks restrict'
[[ "$authorized_record" == *'from="8.8.8.8"'* ]] ||
  fail 'authorized key lacks the expected source restriction'
[[ "$authorized_record" == *"command=\"/usr/local/bin/sb-user-manager-landing-agent ${channel_generation_value}\""* ]] ||
  fail 'authorized key lacks the fixed forced command'
[[ "$authorized_record" == *" $public_key_blob"* ]] ||
  fail 'authorized key does not match the supplied key'

# 下列材料只在临时目录中生成，用于证明身份 gate 位于后续 apply 步骤之前。
mismatch_server_name=identity-mismatch.example.test
mismatch_ca_key="$work/mismatch-ca.key"
mismatch_ca_certificate="$work/mismatch-ca.crt"
mismatch_gateway_key="$work/mismatch-gateway.key"
mismatch_gateway_request="$work/mismatch-gateway.csr"
mismatch_gateway_certificate="$work/mismatch-gateway.crt"
mismatch_gateway_extensions="$work/mismatch-gateway.ext"
mismatch_password_file="$work/mismatch-password"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
  -keyout "$mismatch_ca_key" -out "$mismatch_ca_certificate" \
  -subj '/CN=SBM landing channel e2e CA' >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes \
  -keyout "$mismatch_gateway_key" -out "$mismatch_gateway_request" \
  -subj '/CN=SBM landing channel e2e gateway' >/dev/null 2>&1
printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' \
  "$mismatch_server_name" > "$mismatch_gateway_extensions"
openssl x509 -req -days 2 -in "$mismatch_gateway_request" \
  -CA "$mismatch_ca_certificate" -CAkey "$mismatch_ca_key" -CAcreateserial \
  -out "$mismatch_gateway_certificate" -extfile "$mismatch_gateway_extensions" \
  >/dev/null 2>&1
printf 'E2EOnlyIdentityMismatchPassword_01' > "$mismatch_password_file"
chmod 600 "$mismatch_ca_certificate" "$mismatch_gateway_certificate" \
  "$mismatch_gateway_key" "$mismatch_password_file"

mismatch_gateway="$work/mismatch-gateway.json"
mismatch_package="$work/mismatch-package.json"
mismatch_package_tmp="$work/mismatch-package.tmp"
jq -n --arg server_name "$mismatch_server_name" --arg allowed_ipv4 8.8.8.8 \
  --rawfile password "$mismatch_password_file" \
  --rawfile ca_certificate "$mismatch_ca_certificate" \
  --rawfile certificate "$mismatch_gateway_certificate" \
  --rawfile private_key "$mismatch_gateway_key" '
    {
      listen_port:24443,
      server_name:$server_name,
      password:$password,
      allowed_entry_ipv4:$allowed_ipv4,
      ca_certificate_pem:$ca_certificate,
      certificate_pem:$certificate,
      private_key_pem:$private_key
    }
  ' > "$mismatch_gateway"
chmod 600 "$mismatch_gateway"
mismatch_content_sha256="$(jq -cS . "$mismatch_gateway" | sha256sum | awk '{print $1}')"
mismatch_issued_at="$(date +%s)"
mismatch_expires_at=$((mismatch_issued_at + 300))
mismatch_nonce="$(printf 'c%.0s' {1..64})"
jq -n --argjson schema "$LANDING_APPLY_SCHEMA_VERSION" \
  --arg landing_id e2e-other --argjson issued_at "$mismatch_issued_at" \
  --argjson expires_at "$mismatch_expires_at" --arg nonce "$mismatch_nonce" \
  --arg content_sha256 "$mismatch_content_sha256" --slurpfile gateway "$mismatch_gateway" '
    {
      schema_version:$schema,
      landing_id:$landing_id,
      revision:1,
      issued_at:$issued_at,
      expires_at:$expires_at,
      nonce:$nonce,
      content_sha256:$content_sha256,
      gateway:$gateway[0]
    }
  ' > "$mismatch_package_tmp"
chmod 600 "$mismatch_package_tmp"
mv -- "$mismatch_package_tmp" "$mismatch_package"
landing_apply_package_structure_is_valid "$mismatch_package" ||
  fail 'identity-mismatch fixture is not a structurally valid apply package'

if [[ ! -d /run/sshd ]]; then
  install -d -m 755 -- /run/sshd
  sshd_runtime_dir_created=true
fi

sshd_bin="$(command -v sshd)"
ssh_bin="$(command -v ssh)"
sudo_bin="$(command -v sudo)"
setpriv_bin="$(command -v setpriv)"
timeout_bin="$(command -v timeout)"
sshd_port=""
sshd_config="$work/sshd_config"
sshd_log="$work/sshd.log"
known_hosts="$work/known_hosts"

start_local_sshd() {
  local candidate
  for _ in {1..20}; do
    candidate=$((42000 + RANDOM % 18000))
    cat > "$sshd_config" <<EOF
AddressFamily inet
ListenAddress 127.0.0.1
ListenAddress 8.8.8.8
Port $candidate
HostKey $host_key
PidFile $work/sshd.pid
AuthorizedKeysFile $channel_authorized_keys
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitEmptyPasswords no
PermitRootLogin no
UsePAM no
StrictModes yes
AllowUsers $channel_account
AllowTcpForwarding yes
AllowAgentForwarding yes
X11Forwarding yes
PermitTTY yes
PermitUserRC yes
UseDNS no
PrintMotd no
PrintLastLog no
LogLevel VERBOSE
EOF
    "$sshd_bin" -t -f "$sshd_config" || fail 'temporary sshd configuration is invalid'
    : > "$sshd_log"
    "$sshd_bin" -D -e -f "$sshd_config" > "$sshd_log" 2>&1 &
    sshd_pid=$!
    sleep 0.2
    if kill -0 "$sshd_pid" 2>/dev/null; then
      sshd_port="$candidate"
      read -r host_key_type host_key_blob _ < "$host_key.pub"
      printf '[127.0.0.1]:%s %s %s\n' \
        "$sshd_port" "$host_key_type" "$host_key_blob" > "$known_hosts"
      chmod 600 "$known_hosts"
      return 0
    fi
    wait "$sshd_pid" 2>/dev/null || true
    sshd_pid=""
  done
  sed -n '1,120p' "$sshd_log" >&2
  fail 'temporary sshd could not bind a local high port'
}
start_local_sshd

ssh_common=(
  "$ssh_bin" -F /dev/null -p "$sshd_port"
  -o BatchMode=yes
  -o ConnectionAttempts=1
  -o ConnectTimeout=3
  -o GlobalKnownHostsFile=/dev/null
  -o IdentitiesOnly=yes
  -o KbdInteractiveAuthentication=no
  -o LogLevel=ERROR
  -o PasswordAuthentication=no
  -o PreferredAuthentications=publickey
  -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile="$known_hosts"
)

assert_strict_json_error() {
  local response_file="$1" expected_code="${2:-}" label="${3:-forced agent}"
  local actual_code=""
  [[ -s "$response_file" && "$(wc -c < "$response_file" | tr -d ' ')" -le 512 ]] ||
    fail 'forced agent did not return a bounded JSON error'
  jq -e -s '
    length == 1 and
    (.[0] | type == "object") and
    (.[0] | keys | sort) == ["code", "status"] and
    .[0].status == "error" and
    (.[0].code | type == "string" and test("^[a-z][a-z0-9_]{0,47}$"))
  ' "$response_file" >/dev/null || fail 'forced agent returned a non-strict response'
  if [[ -n "$expected_code" ]]; then
    actual_code="$(jq -r '.code' "$response_file")" ||
      fail "$label response code could not be read"
    [[ "$actual_code" == "$expected_code" ]] ||
      fail "$label returned code $actual_code; expected $expected_code"
  fi
}

wait_for_channel_ssh_quiescence() {
  local channel_uid="$1" attempt
  local wait_seconds="$((LANDING_AGENT_READ_TIMEOUT + 5))"
  for ((attempt = 0; attempt < wait_seconds * 10; attempt++)); do
    landing_channel_account_has_no_processes "$channel_uid" && break
    sleep 0.1
  done
  if ! landing_channel_account_has_no_processes "$channel_uid"; then
    /usr/bin/ps -u "$channel_uid" -o pid=,ppid=,stat=,comm= >&2 || true
    fail 'a completed SSH boundary request retained a dedicated-account process past the read timeout'
  fi
  exec 6<>"$channel_input_lock" || fail 'channel input lock could not be opened for the release probe'
  if ! flock -w "$wait_seconds" 6; then
    exec 6>&-
    fail 'a completed SSH boundary request retained the channel input lock past the read timeout'
  fi
  if ! flock -u 6; then
    exec 6>&-
    fail 'channel input lock release probe could not be unlocked'
  fi
  exec 6>&-
}

valid_stdout="$work/valid.stdout"
valid_stderr="$work/valid.stderr"
valid_rc=0
"${ssh_common[@]}" -T -i "$client_key" \
  -b 8.8.8.8 \
  "$channel_account@127.0.0.1" </dev/null > "$valid_stdout" 2> "$valid_stderr" || valid_rc=$?
((valid_rc != 0)) || fail 'empty apply input unexpectedly succeeded'
assert_strict_json_error "$valid_stdout" invalid_input 'empty-input request'
systemctl is-active --quiet sb-user-manager-landing-recovery.service ||
  fail 'first helper request did not activate the startup recovery gate'

# 一次只允许一份 helper 读取输入；慢请求必须限时结束，第二份请求立即失败。
slow_fifo="$work/slow-input.fifo"
slow_stdout="$work/slow.stdout"
slow_stderr="$work/slow.stderr"
mkfifo "$slow_fifo"
slow_rc=0
"$timeout_bin" 20 "${ssh_common[@]}" -T -i "$client_key" \
  -b 8.8.8.8 "$channel_account@127.0.0.1" \
  < "$slow_fifo" > "$slow_stdout" 2> "$slow_stderr" &
slow_ssh_pid=$!
exec 7>"$slow_fifo"
exec 8<>"$channel_input_lock"
input_lock_observed=false
for _ in {1..50}; do
  if flock -n 8; then
    flock -u 8
    sleep 0.1
  else
    input_lock_observed=true
    break
  fi
done
[[ "$input_lock_observed" == true ]] || fail 'slow SSH request did not acquire the input lock'

busy_stdout="$work/busy.stdout"
busy_stderr="$work/busy.stderr"
busy_rc=0
"$timeout_bin" 5 "${ssh_common[@]}" -T -i "$client_key" \
  -b 8.8.8.8 "$channel_account@127.0.0.1" </dev/null \
  > "$busy_stdout" 2> "$busy_stderr" || busy_rc=$?
((busy_rc != 0 && busy_rc != 124)) || fail 'concurrent helper request did not fail promptly'
assert_strict_json_error "$busy_stdout" channel_busy 'concurrent request'

wait "$slow_ssh_pid" || slow_rc=$?
slow_ssh_pid=""
exec 7>&-
exec 8>&-
((slow_rc != 0 && slow_rc != 124)) || fail 'slow helper input did not stop at the bounded read timeout'
assert_strict_json_error "$slow_stdout" invalid_input 'slow-input request'

mismatch_stdout="$work/mismatch.stdout"
mismatch_stderr="$work/mismatch.stderr"
mismatch_rc=0
"${ssh_common[@]}" -T -i "$client_key" \
  -b 8.8.8.8 \
  "$channel_account@127.0.0.1" < "$mismatch_package" \
  > "$mismatch_stdout" 2> "$mismatch_stderr" || mismatch_rc=$?
((mismatch_rc != 0)) || fail 'an apply package for another landing unexpectedly succeeded'
assert_strict_json_error "$mismatch_stdout" channel_identity_mismatch 'identity-mismatch request'

command_stdout="$work/command.stdout"
command_stderr="$work/command.stderr"
command_rc=0
"${ssh_common[@]}" -T -i "$client_key" \
  -b 8.8.8.8 \
  "$channel_account@127.0.0.1" 'printf SHOULD_NOT_RUN' \
  </dev/null > "$command_stdout" 2> "$command_stderr" || command_rc=$?
((command_rc != 0)) || fail 'an arbitrary remote command succeeded'
assert_strict_json_error "$command_stdout" restricted_channel_rejected 'remote-command request'
if grep -Fq 'SHOULD_NOT_RUN' "$command_stdout"; then
  fail 'an arbitrary remote command reached a shell'
fi

tty_stdout="$work/tty.stdout"
tty_stderr="$work/tty.stderr"
tty_rc=0
"${ssh_common[@]}" -tt -i "$client_key" \
  -b 8.8.8.8 \
  "$channel_account@127.0.0.1" </dev/null > "$tty_stdout" 2> "$tty_stderr" || tty_rc=$?
((tty_rc != 0)) || fail 'a TTY request succeeded'
if [[ -s "$tty_stdout" ]]; then
  assert_strict_json_error "$tty_stdout"
  tty_code="$(jq -r '.code' "$tty_stdout")"
  if [[ "$tty_code" != restricted_channel_rejected ]] &&
     ! grep -Fq 'PTY allocation request failed' "$tty_stderr"; then
    fail 'a TTY request was not rejected by the key or the forced agent'
  fi
elif ! grep -Fq 'PTY allocation request failed' "$tty_stderr"; then
  fail 'a TTY request failed without evidence from the key or forced agent'
fi

forward_port=$((42000 + RANDOM % 18000))
if [[ "$forward_port" == "$sshd_port" ]]; then
  forward_port=$((forward_port == 59999 ? 42000 : forward_port + 1))
fi
forward_stdout="$work/forward.stdout"
forward_stderr="$work/forward.stderr"
forward_rc=0
"$timeout_bin" 5 "${ssh_common[@]}" -N -i "$client_key" \
  -b 8.8.8.8 \
  -o ExitOnForwardFailure=yes \
  -R "127.0.0.1:${forward_port}:127.0.0.1:9" \
  "$channel_account@127.0.0.1" \
  </dev/null > "$forward_stdout" 2> "$forward_stderr" || forward_rc=$?
((forward_rc != 0)) || fail 'port forwarding succeeded'
((forward_rc != 124)) || fail 'port forwarding remained active until the test timeout'

wrong_key_stdout="$work/wrong-key.stdout"
wrong_key_stderr="$work/wrong-key.stderr"
wrong_key_rc=0
"${ssh_common[@]}" -T -i "$wrong_key" \
  -b 8.8.8.8 \
  "$channel_account@127.0.0.1" </dev/null \
  > "$wrong_key_stdout" 2> "$wrong_key_stderr" || wrong_key_rc=$?
((wrong_key_rc != 0)) || fail 'an unregistered SSH key authenticated'
[[ ! -s "$wrong_key_stdout" ]] || fail 'an unregistered SSH key reached the forced agent'

wrong_source_stdout="$work/wrong-source.stdout"
wrong_source_stderr="$work/wrong-source.stderr"
wrong_source_rc=0
"${ssh_common[@]}" -T -b 1.1.1.1 -i "$client_key" \
  "$channel_account@127.0.0.1" </dev/null \
  > "$wrong_source_stdout" 2> "$wrong_source_stderr" || wrong_source_rc=$?
((wrong_source_rc != 0)) || fail 'the registered key authenticated from a disallowed source'
[[ ! -s "$wrong_source_stdout" ]] || fail 'a disallowed source reached the forced agent'

# OpenSSH may report a denied PTY/forwarding request before its forced helper has completed
# bounded stdin cleanup.  The sudo boundary below is not a concurrency test, so first prove
# that every preceding SSH session releases the singleton input lock within the production limit.
channel_uid="$(id -u "$channel_account")"
wait_for_channel_ssh_quiescence "$channel_uid"

# 使用同一真实 sshd、受限账户、forced command 和 sudo helper，验证入口侧固定
# 主机指纹、stdin package、幂等回执与控制器状态收敛。预置匹配 receipt 让本用例
# 保持只读，不要求在边界测试里额外安装 sing-box 或改写运行配置。
controller_host_fingerprint="$(ssh-keygen -lf "$host_key.pub" -E sha256 | awk 'NR == 1 {print $2}')"
[[ "$controller_host_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] ||
  fail 'controller host fingerprint fixture is invalid'
controller_secret_landing="$SB_CONTROLLER_SECRET_DIR/landing-e2e-local"
controller_state_dir="$(dirname "$SB_CONTROLLER_STATE_FILE")"
controller_lock_dir="$(dirname "$SB_CONTROLLER_STATE_LOCK_FILE")"
mkdir -m 700 "$controller_state_dir" "$SB_CONTROLLER_SECRET_DIR" "$controller_secret_landing" \
  "$controller_lock_dir" "$SB_CONTROLLER_LANDING_WORK_ROOT"
controller_ca="$controller_secret_landing/gateway-ca.crt"
controller_certificate="$controller_secret_landing/gateway.crt"
controller_private_key="$controller_secret_landing/gateway.key"
controller_password="$controller_secret_landing/gateway-password"
controller_ssh_key="$controller_secret_landing/ssh-ed25519"
controller_manifest="$SB_CONTROLLER_SECRET_DIR/landing-e2e-local.json"
install -m 600 -- "$mismatch_ca_certificate" "$controller_ca"
install -m 600 -- "$mismatch_gateway_certificate" "$controller_certificate"
install -m 600 -- "$mismatch_gateway_key" "$controller_private_key"
install -m 600 -- "$mismatch_password_file" "$controller_password"
install -m 600 -- "$client_key" "$controller_ssh_key"
jq -n --arg landing_id e2e-local --arg server_name "$mismatch_server_name" \
  --arg ssh_key "$controller_ssh_key" --arg password "$controller_password" \
  --arg ca "$controller_ca" --arg certificate "$controller_certificate" \
  --arg private_key "$controller_private_key" '
  {
    schema_version:1,
    landing_id:$landing_id,
    gateway_server_name:$server_name,
    ssh_private_key_file:$ssh_key,
    gateway_password_file:$password,
    gateway_ca_certificate_file:$ca,
    gateway_certificate_file:$certificate,
    gateway_private_key_file:$private_key
  }
' > "$controller_manifest"
chmod 600 "$controller_manifest"
validate_landing_credential_manifest "$controller_manifest" ||
  fail 'controller e2e credential manifest is invalid'
controller_register_landing e2e-local 'E2E local landing' 8.8.8.8 "$sshd_port" \
  "$controller_host_fingerprint" 24443 ||
  fail 'controller could not register through the real restricted SSH channel'
validate_controller_state_file "$SB_CONTROLLER_STATE_FILE" ||
  fail 'controller e2e state is invalid'
[[ ! -e "$LANDING_RECEIPT_FILE" && ! -L "$LANDING_RECEIPT_FILE" ]] ||
  fail 'registration probe changed the landing receipt'

controller_seed_dir="$work/controller-seed"
mkdir -m 700 "$controller_seed_dir"
controller_seed_package="$controller_seed_dir/apply.json"
controller_seed_now="$(date +%s)"
controller_seed_nonce="$(printf 'e%.0s' {1..64})"
build_landing_apply_package "$controller_manifest" 8.8.8.8 24443 1 \
  "$controller_seed_now" "$((controller_seed_now + 300))" "$controller_seed_nonce" \
  "$controller_seed_package" || fail 'controller e2e seed package could not be built'
controller_seed_sha="$(jq -r '.content_sha256' "$controller_seed_package")"
[[ "$controller_seed_sha" =~ ^[0-9a-f]{64}$ ]] || fail 'controller e2e seed digest is invalid'
controller_receipt_next="$work/controller-receipt.next"
jq -n --arg sha "$controller_seed_sha" --arg nonce "$controller_seed_nonce" '
  {
    schema_version:1,
    role:"managed-landing",
    landing_id:"e2e-local",
    applied_revision:1,
    content_sha256:$sha,
    nonce:$nonce,
    emergency_override:false
  }
' > "$controller_receipt_next"
chmod 600 "$controller_receipt_next"
validate_landing_receipt_json "$controller_receipt_next" ||
  fail 'controller e2e receipt candidate is invalid'
controller_receipt_sha="$controller_seed_sha"
controller_receipt_nonce="$controller_seed_nonce"
controller_receipt_owned=true
mv -- "$controller_receipt_next" "$LANDING_RECEIPT_FILE"
validate_landing_receipt_file "$LANDING_RECEIPT_FILE" ||
  fail 'controller e2e receipt fixture is invalid'

controller_landing_transport_runtime_is_safe ||
  fail 'controller transport runtime executables are not trusted'
ip route get 8.8.8.8 | grep -Fq 'src 8.8.8.8' ||
  fail 'controller e2e route does not use the registered source address'
controller_probe_work="$work/controller-probe"
mkdir -m 700 "$controller_probe_work"
controller_probe_known_hosts="$(controller_landing_prepare_known_hosts 8.8.8.8 "$sshd_port" \
  "$controller_host_fingerprint" sb-landing-e2e-local "$controller_probe_work")" ||
  fail 'controller could not pin the real local sshd host key'
exec {controller_probe_fd}< "$controller_seed_package" ||
  fail 'controller e2e seed package could not be opened'
controller_probe_response="$controller_probe_work/response.json"
if ! controller_landing_ssh_exchange 8.8.8.8 "$sshd_port" e2e-local "$controller_ssh_key" \
    "$controller_probe_known_hosts" "$controller_host_fingerprint" "$controller_probe_fd" \
    "$controller_probe_response"; then
  fail 'controller pinned SSH exchange failed before state convergence'
fi
exec {controller_probe_fd}<&-
jq -e --arg sha "$controller_seed_sha" '
  .status == "idempotent" and .revision == 1 and .content_sha256 == $sha
' "$controller_probe_response" >/dev/null ||
  fail 'controller pinned SSH exchange returned the wrong receipt'
rm -rf -- "$controller_probe_work"

controller_apply_landing e2e-local 8.8.8.8 ||
  fail 'controller could not apply through the real restricted SSH channel'
jq -e --arg sha "$controller_seed_sha" '
  .revision == 2 and .landings[0].status == "active" and
  .landings[0].desired_revision == 1 and .landings[0].applied_revision == 1 and
  .landings[0].config_sha256 == $sha
' "$SB_CONTROLLER_STATE_FILE" >/dev/null ||
  fail 'real restricted SSH response did not converge controller state'
[[ -z "$(find "$SB_CONTROLLER_LANDING_WORK_ROOT" -mindepth 1 -print -quit)" ]] ||
  fail 'real restricted SSH transport left controller work files'
rm -f -- "$LANDING_RECEIPT_FILE"
controller_receipt_owned=false
sync_transaction_path "$(dirname "$LANDING_RECEIPT_FILE")" ||
  fail 'controller e2e receipt cleanup could not be synchronized'
rm -f -- "$controller_seed_package"
wait_for_channel_ssh_quiescence "$channel_uid"

sudo_allowed_stdout="$work/sudo-allowed.stdout"
sudo_allowed_stderr="$work/sudo-allowed.stderr"
sudo_allowed_rc=0
"$sudo_bin" -n -u "$channel_account" -- \
  "$sudo_bin" -n -- "$channel_helper" "$channel_generation_value" </dev/null \
  > "$sudo_allowed_stdout" 2> "$sudo_allowed_stderr" || sudo_allowed_rc=$?
((sudo_allowed_rc != 0)) || fail 'empty helper input unexpectedly succeeded through sudo'
assert_strict_json_error "$sudo_allowed_stdout" invalid_input 'sudo empty-input request'

sudo_argument_stdout="$work/sudo-argument.stdout"
sudo_argument_stderr="$work/sudo-argument.stderr"
sudo_argument_rc=0
"$sudo_bin" -n -u "$channel_account" -- \
  "$sudo_bin" -n -- "$channel_helper" unexpected </dev/null \
  > "$sudo_argument_stdout" 2> "$sudo_argument_stderr" || sudo_argument_rc=$?
((sudo_argument_rc != 0)) || fail 'sudo allowed an argument for the fixed helper'
[[ ! -s "$sudo_argument_stdout" ]] || fail 'the helper ran after an argument was supplied'

sudo_no_argument_stdout="$work/sudo-no-argument.stdout"
sudo_no_argument_rc=0
"$sudo_bin" -n -u "$channel_account" -- \
  "$sudo_bin" -n -- "$channel_helper" </dev/null \
  > "$sudo_no_argument_stdout" 2>/dev/null || sudo_no_argument_rc=$?
((sudo_no_argument_rc != 0)) || fail 'sudo allowed the helper without its bound generation'
[[ ! -s "$sudo_no_argument_stdout" ]] || fail 'the helper ran without its bound generation'

wrong_generation="$(printf '0%.0s' {1..64})"
[[ "$wrong_generation" != "$channel_generation_value" ]] ||
  wrong_generation="$(printf 'f%.0s' {1..64})"
sudo_wrong_generation_stdout="$work/sudo-wrong-generation.stdout"
sudo_wrong_generation_rc=0
"$sudo_bin" -n -u "$channel_account" -- \
  "$sudo_bin" -n -- "$channel_helper" "$wrong_generation" </dev/null \
  > "$sudo_wrong_generation_stdout" 2>/dev/null || sudo_wrong_generation_rc=$?
((sudo_wrong_generation_rc != 0)) || fail 'sudo allowed a helper generation outside the exact binding'
[[ ! -s "$sudo_wrong_generation_stdout" ]] ||
  fail 'the helper ran with a generation outside the exact sudo binding'

sudo_environment_stdout="$work/sudo-environment.stdout"
sudo_environment_stderr="$work/sudo-environment.stderr"
sudo_environment_rc=0
"$sudo_bin" -n -u "$channel_account" -- /usr/bin/env SB_E2E_FORBIDDEN=1 \
  "$sudo_bin" -n -E -- "$channel_helper" "$channel_generation_value" </dev/null \
  > "$sudo_environment_stdout" 2> "$sudo_environment_stderr" || sudo_environment_rc=$?
((sudo_environment_rc != 0)) || fail 'sudo -E unexpectedly succeeded'
[[ ! -s "$sudo_environment_stdout" ]] || fail 'the helper ran through sudo -E'

sudo_other_stdout="$work/sudo-other.stdout"
sudo_other_stderr="$work/sudo-other.stderr"
sudo_other_rc=0
"$sudo_bin" -n -u "$channel_account" -- \
  "$sudo_bin" -n -- /usr/bin/id </dev/null \
  > "$sudo_other_stdout" 2> "$sudo_other_stderr" || sudo_other_rc=$?
((sudo_other_rc != 0)) || fail 'sudo allowed an unrelated command'
[[ ! -s "$sudo_other_stdout" ]] || fail 'an unrelated sudo command produced output'

# 专用 UID 仍有进程时，轮换和卸载都必须失败并完整恢复旧通道。
"$setpriv_bin" --reuid "$channel_uid" --regid "$channel_gid" --clear-groups /bin/sleep 30 &
account_probe_pid=$!
account_probe_supervisor_pid="$account_probe_pid"
observed_probe_uid=""
for _ in {1..50}; do
  observed_probe_uid="$(/usr/bin/ps -o uid= -p "$account_probe_pid" 2>/dev/null | tr -d ' ')" ||
    observed_probe_uid=""
  [[ "$observed_probe_uid" == "$channel_uid" ]] && break
  sleep 0.1
done
[[ "$observed_probe_uid" == "$channel_uid" ]] || fail 'dedicated-account process probe did not start'

# 完全相同的重复安装必须零写入幂等返回，不受活动进程影响。
install_landing_restricted_channel e2e-local 8.8.8.8 "$client_key.pub" ||
  fail 'identical reinstall was not idempotent while the dedicated UID was active'
if install_landing_restricted_channel e2e-local 1.1.1.1 "$wrong_key.pub"; then
  fail 'channel rotation succeeded while the dedicated UID had an active process'
fi
landing_restricted_channel_is_valid || fail 'blocked rotation did not restore the original channel'
[[ ! -e "$channel_transaction" && ! -L "$channel_transaction" ]] ||
  fail 'blocked rotation left a pending transaction'
if uninstall_landing_restricted_channel; then
  fail 'channel uninstall succeeded while the dedicated UID had an active process'
fi
landing_restricted_channel_is_valid || fail 'blocked uninstall did not restore the original channel'
[[ ! -e "$channel_transaction" && ! -L "$channel_transaction" ]] ||
  fail 'blocked uninstall left a pending transaction'

kill "$account_probe_pid"
wait "$account_probe_supervisor_pid" 2>/dev/null || true
account_probe_pid=""
account_probe_supervisor_pid=""
for _ in {1..50}; do
  landing_channel_account_has_no_processes "$channel_uid" && break
  sleep 0.1
done
if ! landing_channel_account_has_no_processes "$channel_uid"; then
  /usr/bin/ps -u "$channel_uid" -o pid=,ppid=,stat=,comm= >&2 || true
  fail 'dedicated-account process did not stop after the gate test'
fi

# 旧 helper 先在排他锁内等待；轮换后获 shared lock 时必须由 root 代际门禁拒绝。
old_generation="$channel_generation_value"
rotation_work="$work/rotation-candidates"
install -d -m 700 -- "$rotation_work"
landing_channel_prepare_candidates e2e-local 1.1.1.1 "$wrong_key.pub" "$rotation_work" ||
  fail 'channel generation rotation candidates failed'
stale_wait_stdout="$work/stale-wait.stdout"
rotate_with_stale_waiter() {
  local input_lock_seen=false
  "$channel_helper" "$old_generation" </dev/null > "$stale_wait_stdout" 2>/dev/null &
  stale_helper_pid=$!
  exec 9<>"$channel_input_lock"
  for _ in {1..50}; do
    if flock -n 9; then
      flock -u 9
      sleep 0.1
    else
      input_lock_seen=true
      break
    fi
  done
  exec 9>&-
  [[ "$input_lock_seen" == true ]] || return 1
  landing_channel_install_unlocked e2e-local 1.1.1.1 "$rotation_work"
}
with_landing_channel_lock rotate_with_stale_waiter ||
  fail 'channel generation rotation failed while the stale helper waited'
new_generation="$(jq -r '.generation' "$channel_identity")"
[[ "$new_generation" =~ ^[0-9a-f]{64}$ && "$new_generation" != "$old_generation" ]] ||
  fail 'channel generation did not change after key and source rotation'
stale_wait_rc=0
wait "$stale_helper_pid" || stale_wait_rc=$?
stale_helper_pid=""
((stale_wait_rc != 0)) || fail 'stale waiting helper unexpectedly succeeded after rotation'
assert_strict_json_error "$stale_wait_stdout" channel_generation_mismatch 'stale-generation request'

stale_agent_stdout="$work/stale-agent.stdout"
stale_agent_rc=0
"$sudo_bin" -n -u "$channel_account" -- /usr/bin/env \
  SSH_CONNECTION='8.8.8.8 50000 127.0.0.1 22' \
  "$channel_agent" "$old_generation" </dev/null > "$stale_agent_stdout" 2>/dev/null || stale_agent_rc=$?
((stale_agent_rc != 0)) || fail 'stale agent generation unexpectedly succeeded'
assert_strict_json_error "$stale_agent_stdout" restricted_channel_rejected 'stale-agent request'

rotated_stdout="$work/rotated.stdout"
rotated_rc=0
"${ssh_common[@]}" -T -i "$wrong_key" -b 1.1.1.1 \
  "$channel_account@127.0.0.1" </dev/null > "$rotated_stdout" 2>/dev/null || rotated_rc=$?
((rotated_rc != 0)) || fail 'empty input unexpectedly succeeded after channel rotation'
assert_strict_json_error "$rotated_stdout" invalid_input 'rotated-channel request'

for _ in {1..50}; do
  landing_channel_account_has_no_processes "$channel_uid" && break
  sleep 0.1
done
landing_channel_account_has_no_processes "$channel_uid" ||
  fail 'rotated SSH session did not release the dedicated account before restore'

install_landing_restricted_channel e2e-local 8.8.8.8 "$client_key.pub" ||
  fail 'channel did not rotate back to the cleanup identity'
landing_restricted_channel_is_valid || fail 'restored channel is invalid after generation test'

# root 引导明确只支持 Debian 12 x86_64；通用受限通道边界仍在上方对全部 CI 系统验收。
if [[ "$(/usr/bin/uname -m)" == x86_64 && -f /usr/lib/os-release &&
      ! -L /usr/lib/os-release ]] &&
   grep -Fxq 'ID=debian' /usr/lib/os-release &&
   grep -Fxq 'VERSION_ID="12"' /usr/lib/os-release; then
# 释放已有 apply receipt 和直接安装的通道，随后在同一隔离网络中经真实 root SSH
# 执行入口生成的自校验引导包。root 登录只接受本测试的临时 Ed25519 密钥。
if [[ "$controller_receipt_owned" == true ]]; then
  jq -e --arg sha "$controller_receipt_sha" --arg nonce "$controller_receipt_nonce" '
    .landing_id == "e2e-local" and .applied_revision == 1 and
    .content_sha256 == $sha and .nonce == $nonce
  ' "$LANDING_RECEIPT_FILE" >/dev/null ||
    fail 'controller receipt changed before bootstrap E2E cleanup'
  rm -f -- "$LANDING_RECEIPT_FILE" || fail 'controller receipt could not be removed'
  controller_receipt_owned=false
fi
uninstall_landing_restricted_channel ||
  fail 'directly installed channel could not be removed before bootstrap E2E'
cleanup_armed=false
landing_restricted_channel_is_valid &&
  fail 'directly installed channel remained before bootstrap E2E'
if [[ -n "$sshd_pid" ]] && kill -0 "$sshd_pid" 2>/dev/null; then
  kill "$sshd_pid"
  wait "$sshd_pid" 2>/dev/null || true
  sshd_pid=""
fi

bootstrap_root_key="$work/bootstrap-root-ed25519"
bootstrap_root_authorized_keys="/run/sb-user-manager-bootstrap-e2e.${work##*.}"
[[ "$bootstrap_root_authorized_keys" =~ ^/run/sb-user-manager-bootstrap-e2e\.[A-Za-z0-9]{6}$ &&
   ! -e "$bootstrap_root_authorized_keys" && ! -L "$bootstrap_root_authorized_keys" ]] ||
  fail 'root bootstrap authorized_keys fixture path is unsafe'
ssh-keygen -q -t ed25519 -N '' -f "$bootstrap_root_key"
chmod 600 "$bootstrap_root_key" "$bootstrap_root_key.pub"
install -o root -g root -m 600 -- "$bootstrap_root_key.pub" "$bootstrap_root_authorized_keys"
bootstrap_root_authorized_keys_owned=true

start_bootstrap_sshd() {
  local candidate
  for _ in {1..20}; do
    candidate=$((42000 + RANDOM % 18000))
    cat > "$sshd_config" <<EOF
AddressFamily inet
ListenAddress 8.8.8.8
Port $candidate
HostKey $host_key
PidFile $work/sshd.pid
AuthorizedKeysFile $channel_authorized_keys
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitEmptyPasswords no
PermitRootLogin prohibit-password
UsePAM no
StrictModes yes
AllowUsers root $channel_account
AllowTcpForwarding yes
AllowAgentForwarding yes
X11Forwarding yes
PermitTTY yes
PermitUserRC yes
UseDNS no
PrintMotd no
PrintLastLog no
LogLevel VERBOSE
Match User root
    AuthorizedKeysFile $bootstrap_root_authorized_keys
EOF
    "$sshd_bin" -t -f "$sshd_config" || fail 'bootstrap sshd configuration is invalid'
    : > "$sshd_log"
    "$sshd_bin" -D -e -f "$sshd_config" > "$sshd_log" 2>&1 &
    sshd_pid=$!
    sleep 0.2
    if kill -0 "$sshd_pid" 2>/dev/null; then
      sshd_port="$candidate"
      return 0
    fi
    wait "$sshd_pid" 2>/dev/null || true
    sshd_pid=""
  done
  sed -n '1,120p' "$sshd_log" >&2
  fail 'bootstrap sshd could not bind a local high port'
}
start_bootstrap_sshd

bootstrap_root_known_hosts="$work/bootstrap-root-known-hosts"
read -r bootstrap_host_key_type bootstrap_host_key_blob _ < "$host_key.pub"
printf 'sb-landing-e2e-local %s %s\n' \
  "$bootstrap_host_key_type" "$bootstrap_host_key_blob" > "$bootstrap_root_known_hosts"
chmod 600 "$bootstrap_root_known_hosts"
if ! "$ssh_bin" -F /dev/null -T -p "$sshd_port" -i "$bootstrap_root_key" \
    -o BatchMode=yes -o GlobalKnownHostsFile=/dev/null \
    -o HostKeyAlias=sb-landing-e2e-local -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$bootstrap_root_known_hosts" \
    root@8.8.8.8 /usr/bin/true; then
  sed -n '1,120p' "$sshd_log" >&2
  fail 'temporary root SSH fixture rejected its dedicated key'
fi

SB_USER_MANAGER_LIBRARY=true
export SB_USER_MANAGER_LIBRARY
CONTROLLER_LANDING_BOOTSTRAP_RUNTIME_SOURCE="$manager_runtime"
CONTROLLER_LANDING_BOOTSTRAP_ROOT_IDENTITY_FILE="$bootstrap_root_key"
CONTROLLER_LANDING_PROBE_ERROR_CODE=bootstrap_probe_failure
if controller_bootstrap_landing_channel e2e-local 8.8.8.8 "$sshd_port" \
    "$controller_host_fingerprint" 8.8.8.8; then
  fail 'injected post-install probe failure was reported as success'
fi
bootstrap_id="$CONTROLLER_LANDING_BOOTSTRAP_LAST_ID"
[[ "$bootstrap_id" =~ ^[0-9a-f]{64}$ ]] || fail 'bootstrap id was not generated'
[[ "$CONTROLLER_LANDING_BOOTSTRAP_LAST_ROLLBACK" == completed ]] ||
  fail 'failed post-install probe did not complete an exact rollback'
[[ ! -e "$bootstrap_receipt" && ! -L "$bootstrap_receipt" ]] ||
  fail 'failed bootstrap rollback left its receipt'
[[ ! -e "$channel_identity" && ! -L "$channel_identity" ]] ||
  fail 'failed bootstrap rollback left the restricted channel'
if getent passwd "$channel_account" >/dev/null 2>&1 ||
   getent group "$channel_group" >/dev/null 2>&1; then
  fail 'failed bootstrap rollback left its account or group'
fi

CONTROLLER_LANDING_PROBE_ERROR_CODE=invalid_input
controller_bootstrap_landing_channel e2e-local 8.8.8.8 "$sshd_port" \
  "$controller_host_fingerprint" 8.8.8.8 ||
  fail 'real root SSH bootstrap did not install and verify the restricted channel'
bootstrap_id="$CONTROLLER_LANDING_BOOTSTRAP_LAST_ID"
bootstrap_receipt_owned=true
[[ "$CONTROLLER_LANDING_BOOTSTRAP_LAST_ROLLBACK" == not_needed ]] ||
  fail 'successful bootstrap unexpectedly reported rollback'
landing_restricted_channel_is_valid || fail 'bootstrapped restricted channel is invalid'
landing_bootstrap_receipt_is_trusted "$bootstrap_receipt" ||
  fail 'successful bootstrap receipt is invalid'
jq -e --arg bootstrap_id "$bootstrap_id" '
  .bootstrap_id == $bootstrap_id and .landing_id == "e2e-local" and
  .allowed_entry_ipv4 == "8.8.8.8" and .status == "installed"
' "$bootstrap_receipt" >/dev/null || fail 'bootstrap receipt binding is incorrect'

wrong_bootstrap_id="$(printf 'f%.0s' {1..64})"
if controller_rollback_landing_bootstrap e2e-local 8.8.8.8 "$sshd_port" \
    "$controller_host_fingerprint" 8.8.8.8 "$wrong_bootstrap_id"; then
  fail 'wrong bootstrap id removed the installed channel'
fi
landing_restricted_channel_is_valid || fail 'wrong bootstrap id damaged the installed channel'
controller_rollback_landing_bootstrap e2e-local 8.8.8.8 "$sshd_port" \
  "$controller_host_fingerprint" 8.8.8.8 "$bootstrap_id" ||
  fail 'exact bootstrap rollback failed over real root SSH'
bootstrap_receipt_owned=false
[[ ! -e "$bootstrap_receipt" && ! -L "$bootstrap_receipt" ]] ||
  fail 'exact bootstrap rollback left its receipt'
[[ ! -e "$channel_identity" && ! -L "$channel_identity" ]] ||
  fail 'exact bootstrap rollback left the restricted channel'
SB_USER_MANAGER_LIBRARY=false
export SB_USER_MANAGER_LIBRARY
fi

printf 'landing channel e2e tests passed\n'
