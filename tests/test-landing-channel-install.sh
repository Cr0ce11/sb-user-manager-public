#!/usr/bin/env bash
# 测试桩由动态 source 的安装层间接调用。
# shellcheck disable=SC2034,SC2317
set -Eeuo pipefail

cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

export SB_USER_MANAGER_LIBRARY=true
# shellcheck source=../sb-user-manager.sh
source ./sb-user-manager.sh

fail() {
  printf 'landing channel install test failed: %s\n' "$1" >&2
  exit 1
}

report_unexpected_failure() {
  local rc="$1" line="$2"
  trap - ERR
  printf 'landing channel install test failed unexpectedly at line %s\n' "$line" >&2
  exit "$rc"
}
trap 'report_unexpected_failure "$?" "$LINENO"' ERR

zombie_only_process_table=$'    0 Ss\n29991 Z\n29991 Zs\n29992 R+\n29992 t+'
landing_channel_process_table_has_no_live_uid 29991 <<< "$zombie_only_process_table" ||
  fail 'zombie-only dedicated-account process rows were rejected'
if landing_channel_process_table_has_no_live_uid 29991 <<'EOF'; then
29991 S
EOF
  fail 'live dedicated-account process row was accepted'
fi
if landing_channel_process_table_has_no_live_uid 29991 <<'EOF'; then
29991 t
EOF
  fail 'traced dedicated-account process row was accepted'
fi
if landing_channel_process_table_has_no_live_uid 29991 <<'EOF'; then
29991
EOF
  fail 'malformed process row was accepted'
fi
if landing_channel_process_table_has_no_live_uid 29991 <<'EOF'; then
29992 Q
EOF
  fail 'unknown process state was accepted'
fi
if landing_channel_process_table_has_no_live_uid 29991 </dev/null; then
  fail 'empty process table was accepted'
fi
landing_channel_system_process_table() {
  printf '29991 S\n'
}
if landing_channel_account_has_no_processes 29991; then
  fail 'account process gate swallowed a live-process rejection'
fi
landing_channel_system_process_table() {
  printf '29991 Zs\n'
}
landing_channel_account_has_no_processes 29991 ||
  fail 'account process gate rejected a zombie-only process table'
landing_channel_system_process_table() {
  return 1
}
if landing_channel_account_has_no_processes 29991; then
  fail 'account process gate swallowed a process-table read failure'
fi

test_flock_input_held=false
have_real_flock=true
if ! command -v flock >/dev/null 2>&1; then
  have_real_flock=false
  flock() {
    case "${1:-}" in
      -n)
        if [[ "${2:-}" == 3 || "${2:-}" == 4 ]]; then
          [[ "$test_flock_input_held" == false ]] || return 1
          test_flock_input_held=true
        fi
        ;;
      -u)
        if [[ "${2:-}" == 3 || "${2:-}" == 4 ]]; then
          test_flock_input_held=false
        fi
        ;;
    esac
    return 0
  }
fi

real_mv="$(command -v mv)"
mv() {
  local target="${!#}"
  "$real_mv" "$@" || return 1
  if [[ -n "$fail_atomic_target" &&
        "$target" == "${SB_SYSTEM_ROOT}${fail_atomic_target}" ]]; then
    fail_atomic_target=""
    return 86
  fi
}

# 默认跳过真实文件系统同步；可精确注入 committed journal 原子替换后的目录同步失败。
sync_transaction_path() {
  local path="$1" journal
  journal="${SB_SYSTEM_ROOT:-}${LANDING_CHANNEL_TRANSACTION_JOURNAL}"
  if [[ "${fail_committed_transaction_sync:-false}" == true &&
        "$path" == "${SB_SYSTEM_ROOT:-}${LANDING_CHANNEL_TRANSACTION_DIRECTORY}" &&
        -f "$journal" ]] && jq -e '.phase == "committed"' "$journal" >/dev/null 2>&1; then
    fail_committed_transaction_sync=false
    return 87
  fi
  return 0
}

if ((EUID == 0)); then
  fake_uid=29991
  fake_gid=29992
else
  fake_uid="$EUID"
  fake_gid="$(id -g)"
fi

system_root=""
account_db=""
group_record=""
user_record=""
shadow_record=""
fail_groupadd_after=""
fail_useradd_after=""
fail_userdel_after=""
fail_groupdel_after=""
fail_visudo=""
fail_atomic_target=""
fail_committed_transaction_sync=false
fail_startup_daemon_reload_count=0
startup_systemctl_events=""
userdel_removes_group=false
userdel_replaces_group_gid=""
user_lookup_failure=""
group_lookup_failure=""
useradd_call_count=0
groupadd_call_count=0

setup_case() {
  local name="$1"
  system_root="$work/$name/system-root"
  account_db="$work/$name/account-db"
  group_record="$account_db/group"
  user_record="$account_db/passwd"
  shadow_record="$account_db/shadow"
  fail_groupadd_after="$account_db/fail-groupadd-after"
  fail_useradd_after="$account_db/fail-useradd-after"
  fail_userdel_after="$account_db/fail-userdel-after"
  fail_groupdel_after="$account_db/fail-groupdel-after"
  fail_visudo="$account_db/fail-visudo"
  fail_atomic_target=""
  fail_committed_transaction_sync=false
  fail_startup_daemon_reload_count=0
  startup_systemctl_events="$account_db/startup-systemctl.events"
  userdel_removes_group=false
  userdel_replaces_group_gid=""
  user_lookup_failure=""
  group_lookup_failure=""
  useradd_call_count=0
  groupadd_call_count=0
  install -d -m 700 -- "$system_root" "$account_db"
  : > "$startup_systemctl_events"
  install -d -m 755 -- "$system_root/usr" "$system_root/usr/local" \
    "$system_root/usr/local/sbin"
  install -m 700 -- ./sb-user-manager.sh \
    "$system_root/usr/local/sbin/sb-user-manager"
  export SB_SYSTEM_ROOT="$system_root"
  landing_channel_reset_active_transaction
}

landing_channel_system_get_user() {
  [[ -z "$user_lookup_failure" ]] || return "$user_lookup_failure"
  [[ "$1" == "$LANDING_CHANNEL_ACCOUNT" && -s "$user_record" ]] || return 2
  cat "$user_record"
}

landing_channel_system_get_shadow() {
  [[ "$1" == "$LANDING_CHANNEL_ACCOUNT" && -s "$shadow_record" ]] || return 2
  cat "$shadow_record"
}

landing_channel_system_get_group() {
  [[ -z "$group_lookup_failure" ]] || return "$group_lookup_failure"
  [[ "$1" == "$LANDING_CHANNEL_GROUP" && -s "$group_record" ]] || return 2
  cat "$group_record"
}

landing_channel_system_user_groups() {
  local gid
  [[ "$1" == "$LANDING_CHANNEL_ACCOUNT" && -s "$user_record" ]] || return 2
  gid="$(cut -d: -f4 "$user_record")" || return 1
  printf '%s\n' "$gid"
}

landing_channel_system_groupadd() {
  local gid="" name=""
  ((groupadd_call_count+=1))
  while (($# > 0)); do
    case "$1" in
      --system) shift ;;
      --gid)
        (($# >= 2)) || return 64
        gid="$2"
        shift 2
        ;;
      *)
        [[ -z "$name" ]] || return 64
        name="$1"
        shift
        ;;
    esac
  done
  [[ "$name" == "$LANDING_CHANNEL_GROUP" && ! -e "$group_record" ]] || return 9
  [[ -n "$gid" ]] || gid="$fake_gid"
  printf '%s:x:%s:\n' "$name" "$gid" > "$group_record" || return 1
  if [[ -e "$fail_groupadd_after" ]]; then
    rm -f -- "$fail_groupadd_after"
    return 81
  fi
}

landing_channel_system_useradd() {
  local uid="" gid_name="" home="" shell="" gecos="" password="" name=""
  ((useradd_call_count+=1))
  while (($# > 0)); do
    case "$1" in
      --system|--no-create-home) shift ;;
      --uid)
        (($# >= 2)) || return 64
        uid="$2"
        shift 2
        ;;
      --gid)
        (($# >= 2)) || return 64
        gid_name="$2"
        shift 2
        ;;
      --home-dir)
        (($# >= 2)) || return 64
        home="$2"
        shift 2
        ;;
      --shell)
        (($# >= 2)) || return 64
        shell="$2"
        shift 2
        ;;
      --comment)
        (($# >= 2)) || return 64
        gecos="$2"
        shift 2
        ;;
      --password)
        (($# >= 2)) || return 64
        password="$2"
        shift 2
        ;;
      *)
        [[ -z "$name" ]] || return 64
        name="$1"
        shift
        ;;
    esac
  done
  [[ "$name" == "$LANDING_CHANNEL_ACCOUNT" && "$gid_name" == "$LANDING_CHANNEL_GROUP" ]] || return 9
  [[ "$home" == "$LANDING_CHANNEL_HOME" && "$shell" == "$LANDING_CHANNEL_SHELL" ]] || return 9
  [[ "$gecos" == "$LANDING_CHANNEL_GECOS" && "$password" == "$LANDING_CHANNEL_PASSWORD_VALUE" ]] || return 9
  [[ -s "$group_record" && ! -e "$user_record" && ! -e "$shadow_record" ]] || return 9
  [[ -n "$uid" ]] || uid="$fake_uid"
  local gid
  gid="$(cut -d: -f3 "$group_record")" || return 1
  printf '%s:x:%s:%s:%s:%s:%s\n' \
    "$name" "$uid" "$gid" "$gecos" "$home" "$shell" > "$user_record" || return 1
  printf '%s:%s:1:0:99999:7:::\n' "$name" "$password" > "$shadow_record" || return 1
  if [[ -e "$fail_useradd_after" ]]; then
    rm -f -- "$fail_useradd_after"
    return 82
  fi
}

landing_channel_system_userdel() {
  [[ "$1" == "$LANDING_CHANNEL_ACCOUNT" && -s "$user_record" ]] || return 6
  rm -f -- "$user_record" "$shadow_record" || return 1
  if [[ "$userdel_removes_group" == true ]]; then
    rm -f -- "$group_record" || return 1
  elif [[ -n "$userdel_replaces_group_gid" ]]; then
    printf '%s:x:%s:\n' "$LANDING_CHANNEL_GROUP" "$userdel_replaces_group_gid" \
      > "$group_record" || return 1
  fi
  if [[ -e "$fail_userdel_after" ]]; then
    rm -f -- "$fail_userdel_after"
    return 83
  fi
}

landing_channel_system_groupdel() {
  [[ "$1" == "$LANDING_CHANNEL_GROUP" && -s "$group_record" ]] || return 6
  [[ ! -e "$user_record" ]] || return 8
  rm -f -- "$group_record" || return 1
  if [[ -e "$fail_groupdel_after" ]]; then
    rm -f -- "$fail_groupdel_after"
    return 84
  fi
}

fail_account_process_check=false
fresh_process_gate_artifact_observed=false
landing_channel_account_has_no_processes() {
  local logical path
  if [[ "$fail_account_process_check" == true ]]; then
    for logical in "$LANDING_AGENT_HELPER_PATH" "$LANDING_CHANNEL_SUDOERS_PATH" \
      "$LANDING_CHANNEL_GENERATION_PATH" "$LANDING_CHANNEL_IDENTITY_PATH" \
      "$LANDING_STARTUP_RECOVERY_UNIT_PATH" "$LANDING_STARTUP_RECOVERY_DROPIN_PATH"; do
      path="$(channel_path "$logical")"
      if [[ -e "$path" || -L "$path" ]]; then
        fresh_process_gate_artifact_observed=true
      fi
    done
    return 1
  fi
  return 0
}

landing_channel_system_visudo_check() {
  local candidate="$1" line prefix generation
  [[ ! -e "$fail_visudo" ]] || return 85
  grep -Fqx "Defaults:${LANDING_CHANNEL_ACCOUNT} env_reset" "$candidate" || return 1
  line="$(tail -n 1 "$candidate")" || return 1
  prefix="${LANDING_CHANNEL_ACCOUNT} ALL=(root) NOPASSWD:NOSETENV:NOLOG_INPUT:NOLOG_OUTPUT: ${LANDING_AGENT_HELPER_PATH} "
  [[ "$line" == "$prefix"* ]] || return 1
  generation="${line#"$prefix"}"
  [[ "$generation" =~ ^[0-9a-f]{64}$ ]]
}

landing_startup_systemctl() {
  printf '%s\n' "$*" >> "$startup_systemctl_events" || return 1
  case "${1:-}" in
    daemon-reload)
      if ((fail_startup_daemon_reload_count > 0)); then
        fail_startup_daemon_reload_count=$((fail_startup_daemon_reload_count - 1))
        return 88
      fi
      ;;
    is-active)
      if [[ "${2:-}" != --quiet ]]; then
        printf 'inactive\n'
      fi
      ;;
  esac
}

nft() {
  [[ "$*" == '-nn list tables' ]] || return 1
  return 0
}

channel_path() {
  printf '%s%s\n' "$system_root" "$1"
}

assert_transaction_absent() {
  local transaction
  transaction="$(channel_path "$LANDING_CHANNEL_TRANSACTION_DIRECTORY")"
  [[ ! -e "$transaction" && ! -L "$transaction" ]] ||
    fail 'landing channel transaction directory was left behind'
}

channel_artifacts_absent() {
  local logical path
  for logical in \
    "$LANDING_CHANNEL_HOME" "$LANDING_CHANNEL_RUNTIME_DIRECTORY" \
    "$LANDING_CHANNEL_AGENT_PATH" "$LANDING_AGENT_HELPER_PATH" \
    "$LANDING_CHANNEL_SUDOERS_PATH" "$LANDING_CHANNEL_IDENTITY_PATH" \
    "$LANDING_STARTUP_RECOVERY_UNIT_PATH" "$LANDING_STARTUP_RECOVERY_DROPIN_PATH" \
    "$LANDING_CHANNEL_TRANSACTION_DIRECTORY"; do
    path="$(channel_path "$logical")"
    [[ ! -e "$path" && ! -L "$path" ]] || return 1
  done
  [[ ! -e "$user_record" && ! -e "$shadow_record" && ! -e "$group_record" ]]
}

channel_snapshot_manifest() {
  local logical path
  printf 'group\t%s\n' "$(<"$group_record")"
  printf 'passwd\t%s\n' "$(<"$user_record")"
  printf 'shadow\t%s\n' "$(<"$shadow_record")"
  for logical in \
    "$LANDING_CHANNEL_RUNTIME_PATH" "$LANDING_CHANNEL_AGENT_PATH" \
    "$LANDING_AGENT_HELPER_PATH" "$LANDING_CHANNEL_SUDOERS_PATH" \
    "$LANDING_CHANNEL_GENERATION_PATH" "$LANDING_CHANNEL_IDENTITY_PATH" \
    "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH" "$LANDING_STARTUP_RECOVERY_UNIT_PATH" \
    "$LANDING_STARTUP_RECOVERY_DROPIN_PATH"; do
    path="$(channel_path "$logical")"
    printf '%s\t%s\t%s\n' "$logical" \
      "$(sha256sum "$path" | awk '{print $1}')" "$(manager_file_mode "$path")"
  done
}

channel_snapshot_digest() {
  channel_snapshot_manifest | sha256sum | awk '{print $1}'
}

assert_install_state() {
  local landing_id="$1" allowed_ipv4="$2" public_key_file="$3"
  local identity authorized generation_file expected_key generation
  identity="$(channel_path "$LANDING_CHANNEL_IDENTITY_PATH")"
  authorized="$(channel_path "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH")"
  generation_file="$(channel_path "$LANDING_CHANNEL_GENERATION_PATH")"
  landing_restricted_channel_is_valid || fail 'installed channel did not pass status validation'
  jq -e --arg landing_id "$landing_id" --arg ip "$allowed_ipv4" \
    '.landing_id == $landing_id and .allowed_entry_ipv4 == $ip' "$identity" >/dev/null ||
    fail 'identity marker did not bind landing id and entry IP'
  expected_key="$(awk 'NR == 1 {print $1 " " $2}' "$public_key_file")"
  [[ "$(jq -r '.public_key' "$identity")" == "$expected_key" ]] ||
    fail 'identity marker did not bind the normalized public key'
  generation="$(jq -r '.generation' "$identity")"
  [[ "$generation" =~ ^[0-9a-f]{64}$ && "$(<"$generation_file")" == "$generation" ]] ||
    fail 'channel generation marker did not match the identity'
  grep -Fqx "restrict,from=\"${allowed_ipv4}\",command=\"${LANDING_CHANNEL_AGENT_PATH} ${generation}\" ${expected_key} sb-user-manager:${landing_id}" \
    "$authorized" || fail 'authorized_keys restriction did not match the identity'
  [[ "$(cut -d: -f2 "$shadow_record")" == '*NP*' ]] || fail 'password field was not disabled with *NP*'
}

write_minimal_package() {
  local output="$1" landing_id="$2" allowed_ipv4="$3"
  jq -n --arg landing_id "$landing_id" --arg ip "$allowed_ipv4" \
    '{landing_id:$landing_id,gateway:{allowed_entry_ipv4:$ip}}' > "$output"
}

shared_callback_called=false
shared_lock_probe() {
  shared_callback_called=true
}

input_callback_count=0
input_lock_probe() {
  ((input_callback_count+=1))
}

inherited_lock_child_pid=""
spawn_inherited_lock_child() {
  /bin/sleep 5 &
  inherited_lock_child_pid=$!
}

observed_recovery_digest=""
recovery_digest_probe() {
  observed_recovery_digest="$(channel_snapshot_digest)"
}

exclusive_callback_count=0
exclusive_lock_probe() {
  ((exclusive_callback_count+=1))
}

ssh-keygen -q -t ed25519 -N '' -f "$work/key-one"
ssh-keygen -q -t ed25519 -N '' -f "$work/key-two"
ssh-keygen -q -t rsa -b 2048 -N '' -f "$work/key-rsa"
printf 'not-an-ssh-key\n' > "$work/key-invalid.pub"

# 通道运维与持久 apply 事务互斥；目录存在时不得进入排他 callback 或触碰现场。
setup_case apply-transaction-gate
apply_transaction="$work/apply-transaction-gate/pending-apply"
install -d -m 700 -- "$apply_transaction"
printf 'preserve apply recovery context\n' > "$apply_transaction/marker"
chmod 600 "$apply_transaction/marker"
apply_marker_before="$(sha256sum "$apply_transaction/marker" | awk '{print $1}')"
export SB_LANDING_APPLY_TRANSACTION_DIRECTORY="$apply_transaction"
[[ "$(landing_channel_apply_transaction_path)" == "$apply_transaction" ]] ||
  fail 'library apply transaction path mapping was rejected'
exclusive_callback_count=0
if with_landing_channel_lock exclusive_lock_probe; then
  fail 'exclusive callback was allowed during a pending apply transaction'
fi
[[ "$exclusive_callback_count" == 0 ]] ||
  fail 'pending apply transaction invoked the exclusive callback'
if install_landing_restricted_channel landing-a 8.8.8.8 "$work/key-one.pub"; then
  fail 'fresh channel install crossed a pending apply transaction'
fi
[[ "$groupadd_call_count" == 0 && "$useradd_call_count" == 0 ]] ||
  fail 'blocked fresh channel install changed the account database'
[[ -d "$apply_transaction" && ! -L "$apply_transaction" ]] ||
  fail 'blocked channel operation removed or replaced the apply transaction directory'
[[ "$(sha256sum "$apply_transaction/marker" | awk '{print $1}')" == "$apply_marker_before" ]] ||
  fail 'blocked channel operation modified the apply recovery context'

unset SB_LANDING_APPLY_TRANSACTION_DIRECTORY
install_landing_restricted_channel landing-a 8.8.8.8 "$work/key-one.pub"
apply_installed_digest="$(channel_snapshot_digest)"
export SB_LANDING_APPLY_TRANSACTION_DIRECTORY="$apply_transaction"
if install_landing_restricted_channel landing-a 1.1.1.1 "$work/key-two.pub"; then
  fail 'channel rotation crossed a pending apply transaction'
fi
[[ "$(channel_snapshot_digest)" == "$apply_installed_digest" ]] ||
  fail 'blocked channel rotation changed the installed channel'
if uninstall_landing_restricted_channel; then
  fail 'channel uninstall crossed a pending apply transaction'
fi
[[ "$(channel_snapshot_digest)" == "$apply_installed_digest" ]] ||
  fail 'blocked channel uninstall changed the installed channel'
[[ -d "$apply_transaction" && ! -L "$apply_transaction" ]] ||
  fail 'blocked rotation or uninstall removed the apply transaction directory'
[[ "$(sha256sum "$apply_transaction/marker" | awk '{print $1}')" == "$apply_marker_before" ]] ||
  fail 'blocked rotation or uninstall modified the apply recovery context'
unset SB_LANDING_APPLY_TRANSACTION_DIRECTORY
uninstall_landing_restricted_channel
channel_artifacts_absent || fail 'apply transaction gate cleanup left channel resources behind'

# 损坏为悬空符号链接的 apply 事务路径同样必须保留并失败关闭。
setup_case apply-transaction-symlink-gate
apply_transaction_link="$work/apply-transaction-symlink-gate/pending-apply"
apply_transaction_link_target="$work/apply-transaction-symlink-gate/missing-target"
ln -s "$apply_transaction_link_target" "$apply_transaction_link"
export SB_LANDING_APPLY_TRANSACTION_DIRECTORY="$apply_transaction_link"
if install_landing_restricted_channel landing-a 8.8.8.8 "$work/key-one.pub"; then
  fail 'fresh channel install crossed an apply transaction symlink'
fi
[[ -L "$apply_transaction_link" ]] || fail 'blocked channel install removed the apply transaction symlink'
[[ "$(readlink -- "$apply_transaction_link")" == "$apply_transaction_link_target" ]] ||
  fail 'blocked channel install modified the apply transaction symlink'
[[ ! -e "$apply_transaction_link_target" && ! -L "$apply_transaction_link_target" ]] ||
  fail 'blocked channel install created the apply transaction symlink target'
[[ "$groupadd_call_count" == 0 && "$useradd_call_count" == 0 ]] ||
  fail 'apply transaction symlink gate changed the account database'
unset SB_LANDING_APPLY_TRANSACTION_DIRECTORY

# 测试映射只能在 library 模式使用，生产常量被篡改或映射时必须失败关闭。
if (
  LANDING_APPLY_TRANSACTION_DIRECTORY=/tmp/not-the-fixed-apply-transaction
  landing_channel_apply_transaction_path >/dev/null
); then
  fail 'changed production apply transaction constant was accepted'
fi
if (
  SB_USER_MANAGER_LIBRARY=false
  SB_LANDING_APPLY_TRANSACTION_DIRECTORY="$work/not-production-path"
  landing_channel_apply_transaction_path >/dev/null
); then
  fail 'library apply transaction mapping was accepted in production mode'
fi

# 会复制进 root helper 的 manager 源必须保持受信 owner/mode。
setup_case untrusted-manager-source
chmod 755 "$system_root/usr/local/sbin/sb-user-manager"
trap - ERR
if install_landing_restricted_channel landing-a 8.8.8.8 "$work/key-one.pub"; then
  trap 'report_unexpected_failure "$?" "$LINENO"' ERR
  fail 'manager runtime source with drifted permissions was accepted'
fi
trap 'report_unexpected_failure "$?" "$LINENO"' ERR
channel_artifacts_absent || fail 'untrusted manager source changed managed resources'

# 固定系统目录不受 root 独占时，必须在创建账户或事务前拒绝安装。
setup_case unsafe-install-system-path
install -d -m 777 -- "$system_root/usr/local/bin"
if install_landing_restricted_channel landing-a 8.8.8.8 "$work/key-one.pub"; then
  fail 'world-writable install system path was accepted'
fi
[[ "$groupadd_call_count" == 0 && "$useradd_call_count" == 0 ]] ||
  fail 'unsafe install system path changed the account database'
assert_transaction_absent
channel_artifacts_absent || fail 'unsafe install system path left managed resources behind'

# groupadd 已创建同名组却返回失败时，回滚只回收精确匹配的本次资源。
setup_case partial-groupadd
: > "$fail_groupadd_after"
if install_landing_restricted_channel landing-a 8.8.8.8 "$work/key-one.pub"; then
  fail 'partial groupadd failure was accepted'
fi
channel_artifacts_absent || fail 'partial groupadd failure left managed resources behind'

# useradd 同样可能在写入账户后报错，需完整回收用户和组。
setup_case partial-useradd
: > "$fail_useradd_after"
if install_landing_restricted_channel landing-a 8.8.8.8 "$work/key-one.pub"; then
  fail 'partial useradd failure was accepted'
fi
channel_artifacts_absent || fail 'partial useradd failure left managed resources behind'

# useradd 复用了仍有孤儿进程的数值 UID 时，必须在部署任何提权材料前回滚。
setup_case fresh-uid-process
fail_account_process_check=true
fresh_process_gate_artifact_observed=false
if install_landing_restricted_channel landing-a 8.8.8.8 "$work/key-one.pub"; then
  fail 'fresh install accepted an active numeric UID'
fi
fail_account_process_check=false
[[ "$fresh_process_gate_artifact_observed" == false ]] ||
  fail 'fresh UID gate ran after privileged channel artifacts were deployed'
channel_artifacts_absent || fail 'fresh UID gate failure left managed resources behind'

# 不接管事先存在的同名用户或组。
setup_case foreign-group
printf '%s:x:31337:someone\n' "$LANDING_CHANNEL_GROUP" > "$group_record"
foreign_group_before="$(<"$group_record")"
if install_landing_restricted_channel landing-a 8.8.8.8 "$work/key-one.pub"; then
  fail 'foreign same-name group was accepted'
fi
[[ "$(<"$group_record")" == "$foreign_group_before" ]] || fail 'foreign group was modified'
[[ ! -e "$user_record" ]] || fail 'user was created beside a foreign group'

setup_case foreign-user
printf '%s:x:31338:31339:foreign:/srv/foreign:/bin/false\n' \
  "$LANDING_CHANNEL_ACCOUNT" > "$user_record"
printf '%s:x:31339:\n' "$LANDING_CHANNEL_GROUP" > "$group_record"
printf '%s:!:1:0:99999:7:::\n' "$LANDING_CHANNEL_ACCOUNT" > "$shadow_record"
foreign_user_before="$(<"$user_record")"
if install_landing_restricted_channel landing-a 8.8.8.8 "$work/key-one.pub"; then
  fail 'foreign same-name account was accepted'
fi
[[ "$(<"$user_record")" == "$foreign_user_before" ]] || fail 'foreign account was modified'

# 不跟随预置在受管路径上的符号链接。
setup_case symlink
install -d -m 755 -- "$system_root/var" "$system_root/var/lib"
printf 'outside\n' > "$work/symlink-target"
ln -s "$work/symlink-target" "$(channel_path "$LANDING_CHANNEL_HOME")"
if install_landing_restricted_channel landing-a 8.8.8.8 "$work/key-one.pub"; then
  fail 'managed home symlink was accepted'
fi
[[ -L "$(channel_path "$LANDING_CHANNEL_HOME")" ]] || fail 'foreign symlink was removed'
grep -Fxq outside "$work/symlink-target" || fail 'symlink target was modified'

# 预置在固定 systemd 目标上的符号链接同样不能被通道安装接管。
setup_case systemd-artifact-symlink
install -d -m 755 -- "$system_root/etc" "$system_root/etc/systemd" \
  "$system_root/etc/systemd/system"
printf 'outside systemd artifact\n' > "$work/systemd-symlink-target"
ln -s "$work/systemd-symlink-target" \
  "$(channel_path "$LANDING_STARTUP_RECOVERY_UNIT_PATH")"
if install_landing_restricted_channel landing-a 8.8.8.8 "$work/key-one.pub"; then
  fail 'startup recovery unit symlink was accepted'
fi
[[ -L "$(channel_path "$LANDING_STARTUP_RECOVERY_UNIT_PATH")" ]] ||
  fail 'startup recovery unit symlink was removed'
grep -Fxq 'outside systemd artifact' "$work/systemd-symlink-target" ||
  fail 'startup recovery unit symlink target was modified'
[[ "$groupadd_call_count" == 0 && "$useradd_call_count" == 0 ]] ||
  fail 'startup recovery unit symlink changed the account database'
assert_transaction_absent

# fresh 事务在账户已创建后“进程中断”：只丢失内存状态，不调用常规回滚。
setup_case recovery-fresh
with_landing_channel_lock true
landing_channel_begin_transaction fresh '' ''
landing_channel_create_account
jq -e '.mode == "fresh" and .phase == "account_created"' \
  "$(channel_path "$LANDING_CHANNEL_TRANSACTION_JOURNAL")" >/dev/null ||
  fail 'fresh transaction journal did not record the created account'
landing_channel_reset_active_transaction
install_landing_restricted_channel landing-a 8.8.8.8 "$work/key-one.pub"
assert_install_state landing-a 8.8.8.8 "$work/key-one.pub"
assert_transaction_absent
uninstall_landing_restricted_channel
channel_artifacts_absent || fail 'recovered fresh transaction left managed resources behind'

# Debian 可由 userdel 同时移除同名私有组；已安全消失不能触发回滚。
setup_case userdel-removes-private-group
install_landing_restricted_channel landing-a 8.8.8.8 "$work/key-one.pub"
userdel_removes_group=true
uninstall_landing_restricted_channel
channel_artifacts_absent || fail 'automatic private-group removal left managed resources behind'

# 若同名组在 userdel 后被替换，不能按旧身份记录删除外部资源。
setup_case userdel-replaced-group
install_landing_restricted_channel landing-a 8.8.8.8 "$work/key-one.pub"
userdel_replaces_group_gid=31337
if uninstall_landing_restricted_channel; then
  fail 'uninstall deleted a same-name group that replaced the managed group'
fi
grep -Fxq "${LANDING_CHANNEL_GROUP}:x:31337:" "$group_record" ||
  fail 'uninstall modified a replacement same-name group'
jq -e '.mode == "uninstall" and .phase == "active"' \
  "$(channel_path "$LANDING_CHANNEL_TRANSACTION_JOURNAL")" >/dev/null ||
  fail 'replacement-group conflict did not preserve recovery context'

# NSS 查询异常不是“不存在”；回滚不得在身份未知时尝试重建组。
setup_case rollback-group-lookup-failure
install_landing_restricted_channel landing-a 8.8.8.8 "$work/key-one.pub"
rollback_uid="$(cut -d: -f3 "$user_record")"
rollback_gid="$(cut -d: -f3 "$group_record")"
rollback_lookup_digest="$(channel_snapshot_digest)"
landing_channel_begin_transaction uninstall "$rollback_uid" "$rollback_gid"
group_lookup_failure=3
groupadd_call_count=0
if landing_channel_rollback_uninstall; then
  fail 'uninstall rollback accepted a group lookup failure'
fi
[[ "$groupadd_call_count" == 0 ]] || fail 'group lookup failure attempted to recreate the group'
[[ "$(channel_snapshot_digest)" == "$rollback_lookup_digest" ]] ||
  fail 'group lookup failure changed the installed channel'
jq -e '.mode == "uninstall" and .phase == "active"' \
  "$(channel_path "$LANDING_CHANNEL_TRANSACTION_JOURNAL")" >/dev/null ||
  fail 'group lookup failure did not preserve recovery context'

# 用户查询异常同样必须失败关闭，不得把未知状态当作用户缺失。
setup_case rollback-user-lookup-failure
install_landing_restricted_channel landing-a 8.8.8.8 "$work/key-one.pub"
rollback_uid="$(cut -d: -f3 "$user_record")"
rollback_gid="$(cut -d: -f3 "$group_record")"
rollback_lookup_digest="$(channel_snapshot_digest)"
landing_channel_begin_transaction uninstall "$rollback_uid" "$rollback_gid"
user_lookup_failure=3
useradd_call_count=0
if landing_channel_rollback_uninstall; then
  fail 'uninstall rollback accepted an account lookup failure'
fi
[[ "$useradd_call_count" == 0 ]] || fail 'account lookup failure attempted to recreate the user'
[[ "$(channel_snapshot_digest)" == "$rollback_lookup_digest" ]] ||
  fail 'account lookup failure changed the installed channel'
jq -e '.mode == "uninstall" and .phase == "active"' \
  "$(channel_path "$LANDING_CHANNEL_TRANSACTION_JOURNAL")" >/dev/null ||
  fail 'account lookup failure did not preserve recovery context'

# fresh 事务在候选集已持久化且部分文件已落地后中断。
setup_case recovery-fresh-files
with_landing_channel_lock true
fresh_files_work="$(mktemp -d /tmp/sb-landing-channel-test.XXXXXX)"
register_temp_path "$fresh_files_work"
landing_channel_prepare_candidates landing-a 8.8.8.8 "$work/key-one.pub" "$fresh_files_work"
landing_channel_begin_transaction fresh '' ''
landing_channel_create_account
fresh_uid="$LANDING_CHANNEL_ACTIVE_UID"
fresh_gid="$LANDING_CHANNEL_ACTIVE_GID"
landing_channel_render_identity landing-a 8.8.8.8 "$fresh_uid" "$fresh_gid" \
  "$fresh_files_work" "$fresh_files_work/identity.json"
landing_channel_persist_install_candidates "$fresh_files_work"
landing_channel_update_active_journal files_active "$fresh_uid" "$fresh_gid"
landing_channel_prepare_directories "$fresh_gid"
# 模拟目录 install 完成、切换到专用组前崩溃；root:root 过渡态仍必须可证明并回收。
landing_channel_apply_ownership \
  "$(channel_path "$LANDING_CHANNEL_RUNTIME_DIRECTORY")" \
  "$(landing_channel_expected_root_uid)" "$(landing_channel_expected_root_gid)"
chmod 700 "$(channel_path "$LANDING_CHANNEL_RUNTIME_DIRECTORY")"
landing_channel_atomic_install_file "$fresh_files_work/runtime.sh" \
  "$LANDING_CHANNEL_RUNTIME_PATH" 640 "$(landing_channel_expected_root_uid)" "$fresh_gid"
jq -e '.mode == "fresh" and .phase == "files_active"' \
  "$(channel_path "$LANDING_CHANNEL_TRANSACTION_JOURNAL")" >/dev/null ||
  fail 'fresh transaction journal did not reach files_active phase'
landing_channel_reset_active_transaction
install_landing_restricted_channel landing-a 8.8.8.8 "$work/key-one.pub"
assert_install_state landing-a 8.8.8.8 "$work/key-one.pub"
assert_transaction_absent
rm -rf -- "$fresh_files_work"
uninstall_landing_restricted_channel
channel_artifacts_absent || fail 'recovered files_active transaction left managed resources behind'

# 回滚完成后先落盘 rolled_back；即使清理候选集时崩溃，下次也只清事务目录。
setup_case recovery-fresh-rolled-back
with_landing_channel_lock true
fresh_rolled_back_work="$(mktemp -d /tmp/sb-landing-channel-test.XXXXXX)"
register_temp_path "$fresh_rolled_back_work"
landing_channel_prepare_candidates landing-a 8.8.8.8 "$work/key-one.pub" "$fresh_rolled_back_work"
landing_channel_begin_transaction fresh '' ''
landing_channel_create_account
fresh_rolled_back_uid="$LANDING_CHANNEL_ACTIVE_UID"
fresh_rolled_back_gid="$LANDING_CHANNEL_ACTIVE_GID"
landing_channel_render_identity landing-a 8.8.8.8 "$fresh_rolled_back_uid" "$fresh_rolled_back_gid" \
  "$fresh_rolled_back_work" "$fresh_rolled_back_work/identity.json"
landing_channel_persist_install_candidates "$fresh_rolled_back_work"
landing_channel_update_active_journal files_active "$fresh_rolled_back_uid" "$fresh_rolled_back_gid"
landing_channel_remove_fresh_resources
landing_channel_update_active_journal rolled_back
jq -e '.mode == "fresh" and .phase == "rolled_back" and
  (.transaction_id | test("^[0-9a-f]{32}$"))' \
  "$(channel_path "$LANDING_CHANNEL_TRANSACTION_JOURNAL")" >/dev/null ||
  fail 'fresh rollback terminal journal is invalid'
landing_channel_reset_active_transaction
rm -f -- "$(channel_path "$LANDING_CHANNEL_TRANSACTION_DIRECTORY")/candidates/runtime.sh"
with_landing_channel_lock true
assert_transaction_absent
channel_artifacts_absent || fail 'rolled-back fresh recovery recreated or retained managed resources'
rm -rf -- "$fresh_rolled_back_work"

# 主流程：首次安装、状态负例、幂等更新、IP/密钥轮换。
setup_case lifecycle
install_landing_restricted_channel landing-a 8.8.8.8 "$work/key-one.pub"
assert_install_state landing-a 8.8.8.8 "$work/key-one.pub"
assert_transaction_absent
identity_path="$(channel_path "$LANDING_CHANNEL_IDENTITY_PATH")"

# 无待恢复事务时共享锁应调用回调；输入锁必须单飞且释放后可再用。
shared_callback_called=false
with_landing_channel_shared_lock shared_lock_probe
[[ "$shared_callback_called" == true ]] || fail 'shared lock did not invoke callback on clean state'

input_callback_count=0
with_landing_channel_input_lock input_lock_probe
[[ "$input_callback_count" == 1 ]] || fail 'input lock did not invoke its callback'
input_lock_path="$(channel_path "$LANDING_CHANNEL_INPUT_LOCK_PATH")"
exec 3<>"$input_lock_path"
flock -n 3
if with_landing_channel_input_lock input_lock_probe; then
  fail 'input lock allowed a concurrent callback'
fi
[[ "$input_callback_count" == 1 ]] || fail 'contended input lock invoked its callback'
flock -u 3
exec 3>&-
with_landing_channel_input_lock input_lock_probe
[[ "$input_callback_count" == 2 ]] || fail 'released input lock could not be reused'

# callback 启动的长寿命子进程不得继承输入锁 FD，否则父 shell 异常退出后会卡住后续请求。
if [[ "$have_real_flock" == true ]]; then
  with_landing_channel_input_lock spawn_inherited_lock_child
  [[ "$inherited_lock_child_pid" =~ ^[0-9]+$ ]] || fail 'lock inheritance probe did not start'
  exec 3<>"$input_lock_path"
  flock -n 3 || fail 'callback child inherited the input lock descriptor'
  flock -u 3
  exec 3>&-
  kill "$inherited_lock_child_pid" 2>/dev/null || true
  wait "$inherited_lock_child_pid" 2>/dev/null || true
  inherited_lock_child_pid=""
fi

agent_path="$(channel_path "$LANDING_CHANNEL_AGENT_PATH")"
cp -p -- "$agent_path" "$work/agent-pristine"
printf '# tampered\n' >> "$agent_path"
if landing_restricted_channel_is_valid; then
  fail 'status validation accepted a modified launcher'
fi
cp -p -- "$work/agent-pristine" "$agent_path"
landing_restricted_channel_is_valid || fail 'status validation did not recover after exact restoration'

dropin_path="$(channel_path "$LANDING_STARTUP_RECOVERY_DROPIN_PATH")"
cp -p -- "$dropin_path" "$work/dropin-pristine"
printf 'outside drop-in\n' > "$work/dropin-outside"
rm -f -- "$dropin_path"
ln -s "$work/dropin-outside" "$dropin_path"
if landing_restricted_channel_is_valid; then
  fail 'status validation accepted a startup recovery drop-in symlink'
fi
grep -Fxq 'outside drop-in' "$work/dropin-outside" ||
  fail 'status validation modified the drop-in symlink target'
rm -f -- "$dropin_path"
cp -p -- "$work/dropin-pristine" "$dropin_path"
landing_restricted_channel_is_valid ||
  fail 'status validation did not recover after exact drop-in restoration'

before_idempotent="$(channel_snapshot_digest)"
fail_account_process_check=true
install_landing_restricted_channel landing-a 8.8.8.8 "$work/key-one.pub"
fail_account_process_check=false
[[ "$(channel_snapshot_digest)" == "$before_idempotent" ]] || fail 'idempotent install changed durable state'
assert_transaction_absent

# update 回滚终态不再依赖已开始清理的 snapshot。
channel_uid="$(jq -r '.uid' "$identity_path")"
channel_gid="$(jq -r '.gid' "$identity_path")"
landing_channel_begin_transaction update "$channel_uid" "$channel_gid"
landing_channel_update_active_journal rolled_back
landing_channel_reset_active_transaction
rm -f -- "$(channel_path "$LANDING_CHANNEL_TRANSACTION_DIRECTORY")/snapshot/runtime"
observed_recovery_digest=""
with_landing_channel_lock recovery_digest_probe
[[ "$observed_recovery_digest" == "$before_idempotent" ]] ||
  fail 'rolled-back update recovery changed the restored runtime state'
assert_transaction_absent

install_landing_restricted_channel landing-a 1.1.1.1 "$work/key-two.pub"
assert_install_state landing-a 1.1.1.1 "$work/key-two.pub"
assert_transaction_absent

# 生产 apply 只接受同时匹配已安装 landing_id 和入口 IPv4 的包。
write_minimal_package "$work/package-match.json" landing-a 1.1.1.1
write_minimal_package "$work/package-wrong-id.json" landing-b 1.1.1.1
write_minimal_package "$work/package-wrong-ip.json" landing-a 9.9.9.9
landing_channel_identity_allows_package "$work/package-match.json" ||
  fail 'matching package was rejected by the installed identity'
if landing_channel_identity_allows_package "$work/package-wrong-id.json"; then
  fail 'package with a different landing id passed the identity gate'
fi
if landing_channel_identity_allows_package "$work/package-wrong-ip.json"; then
  fail 'package with a different entry IP passed the identity gate'
fi

cp -p -- "$identity_path" "$work/lifecycle-identity-pristine"
jq '.unexpected = true' "$work/lifecycle-identity-pristine" > "$work/identity-content-drift"
install -m 600 -- "$work/identity-content-drift" "$identity_path"
landing_channel_apply_ownership "$identity_path" \
  "$(landing_channel_expected_root_uid)" "$(landing_channel_expected_root_gid)"
if landing_channel_identity_allows_package "$work/package-match.json"; then
  fail 'identity marker with unexpected content passed the package gate'
fi

jq '.allowed_entry_ipv4 = "9.9.9.9"' "$work/lifecycle-identity-pristine" > "$work/identity-field-drift"
install -m 600 -- "$work/identity-field-drift" "$identity_path"
landing_channel_apply_ownership "$identity_path" \
  "$(landing_channel_expected_root_uid)" "$(landing_channel_expected_root_gid)"
if landing_channel_identity_allows_package "$work/package-match.json"; then
  fail 'package passed after the identity binding content drifted'
fi

jq '.public_key_fingerprint = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"' \
  "$work/lifecycle-identity-pristine" > "$work/identity-fingerprint-drift"
install -m 600 -- "$work/identity-fingerprint-drift" "$identity_path"
landing_channel_apply_ownership "$identity_path" \
  "$(landing_channel_expected_root_uid)" "$(landing_channel_expected_root_gid)"
if landing_channel_identity_allows_package "$work/package-match.json"; then
  fail 'identity marker with a fingerprint unrelated to its public key passed the package gate'
fi

install -m 600 -- "$work/lifecycle-identity-pristine" "$identity_path"
landing_channel_apply_ownership "$identity_path" \
  "$(landing_channel_expected_root_uid)" "$(landing_channel_expected_root_gid)"
chmod 644 "$identity_path"
if landing_channel_identity_allows_package "$work/package-match.json"; then
  fail 'identity marker with unsafe permissions passed the package gate'
fi
chmod 600 "$identity_path"
landing_channel_identity_allows_package "$work/package-match.json" ||
  fail 'package gate did not recover after exact marker restoration'
assert_install_state landing-a 1.1.1.1 "$work/key-two.pub"
rotated_digest="$(channel_snapshot_digest)"

# daemon-reload 是通道事务的一部分：候选图重载失败必须恢复旧文件并重载旧图。
: > "$startup_systemctl_events"
fail_startup_daemon_reload_count=1
if install_landing_restricted_channel landing-a 9.9.9.9 "$work/key-one.pub"; then
  fail 'injected daemon-reload failure was accepted'
fi
[[ "$fail_startup_daemon_reload_count" == 0 ]] ||
  fail 'daemon-reload failure was not injected'
[[ "$(grep -Fxc daemon-reload "$startup_systemctl_events")" == 2 ]] ||
  fail 'failed candidate graph was not followed by a restored-graph daemon-reload'
[[ "$(channel_snapshot_digest)" == "$rotated_digest" ]] ||
  fail 'daemon-reload failure did not restore the exact prior channel'
assert_install_state landing-a 1.1.1.1 "$work/key-two.pub"
assert_transaction_absent

# identity 一旦建立，不允许用另一个 landing_id 接管。
if install_landing_restricted_channel landing-b 9.9.9.9 "$work/key-one.pub"; then
  fail 'different landing id replaced an existing identity'
fi
[[ "$(channel_snapshot_digest)" == "$rotated_digest" ]] || fail 'landing-id rejection changed state'

# 私网/保留地址、非 Ed25519 及非法密钥都在修改系统前被拒绝。
for invalid_ip in 127.0.0.1 10.0.0.1 192.0.2.10 not-an-ip; do
  if install_landing_restricted_channel landing-a "$invalid_ip" "$work/key-one.pub"; then
    fail "invalid entry IP was accepted: $invalid_ip"
  fi
done
if install_landing_restricted_channel landing-a 9.9.9.9 "$work/key-rsa.pub"; then
  fail 'RSA key was accepted for the restricted channel'
fi
if install_landing_restricted_channel landing-a 9.9.9.9 "$work/key-invalid.pub"; then
  fail 'malformed public key was accepted'
fi
[[ "$(channel_snapshot_digest)" == "$rotated_digest" ]] || fail 'invalid input changed state'

# 更新已写入一部分候选文件后失败，必须恢复到原子快照。
foreign_atomic="$system_root/usr/local/bin/.landing-channel.00000000000000000000000000000000.ABC123"
printf 'foreign namespace\n' > "$foreign_atomic"
chmod 600 "$foreign_atomic"
landing_channel_apply_ownership "$foreign_atomic" \
  "$(landing_channel_expected_root_uid)" "$(landing_channel_expected_root_gid)"
fail_atomic_target="$LANDING_CHANNEL_IDENTITY_PATH"
if install_landing_restricted_channel landing-a 9.9.9.9 "$work/key-one.pub"; then
  fail 'injected commit failure was accepted'
fi
[[ "$(channel_snapshot_digest)" == "$rotated_digest" ]] || fail 'failed update did not restore exact prior state'
assert_install_state landing-a 1.1.1.1 "$work/key-two.pub"
assert_transaction_absent
grep -Fxq 'foreign namespace' "$foreign_atomic" ||
  fail 'rollback deleted an atomic temp outside the active transaction id'
rm -f -- "$foreign_atomic"

# update 事务在旧入口已撤下、文件已部分改写后中断。
channel_uid="$(jq -r '.uid' "$identity_path")"
channel_gid="$(jq -r '.gid' "$identity_path")"
landing_channel_begin_transaction update "$channel_uid" "$channel_gid"
landing_channel_remove_file "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH"
printf '# interrupted update\n' >> "$(channel_path "$LANDING_CHANNEL_AGENT_PATH")"
current_atomic="$system_root/usr/local/bin/.landing-channel.${LANDING_CHANNEL_ACTIVE_TRANSACTION_ID}.ABC123"
printf 'active transaction orphan\n' > "$current_atomic"
chmod 600 "$current_atomic"
landing_channel_apply_ownership "$current_atomic" \
  "$(landing_channel_expected_root_uid)" "$(landing_channel_expected_root_gid)"
jq -e '.mode == "update" and .phase == "active"' \
  "$(channel_path "$LANDING_CHANNEL_TRANSACTION_JOURNAL")" >/dev/null ||
  fail 'update transaction journal was not active'
landing_channel_reset_active_transaction

# 只读共享锁在待恢复事务存在时不得调用业务回调。
shared_callback_called=false
if with_landing_channel_shared_lock shared_lock_probe; then
  fail 'shared lock accepted a pending transaction'
fi
[[ "$shared_callback_called" == false ]] || fail 'shared lock invoked callback during a pending transaction'

observed_recovery_digest=""
with_landing_channel_lock recovery_digest_probe
[[ "$observed_recovery_digest" == "$rotated_digest" ]] ||
  fail 'exclusive lock callback did not observe the recovered update state'
assert_install_state landing-a 1.1.1.1 "$work/key-two.pub"
assert_transaction_absent
[[ ! -e "$current_atomic" && ! -L "$current_atomic" ]] ||
  fail 'recovery retained an orphan atomic file from the active transaction id'

# committed journal 已原子替换、随后目录 sync 失败时，不能回滚已完整激活的新状态。
fail_committed_transaction_sync=true
if install_landing_restricted_channel landing-a 9.9.9.9 "$work/key-one.pub"; then
  fail 'commit durability uncertainty was reported as a clean success'
fi
[[ "$fail_committed_transaction_sync" == false ]] || fail 'committed journal sync failure was not injected'
jq -e '.mode == "update" and .phase == "committed"' \
  "$(channel_path "$LANDING_CHANNEL_TRANSACTION_JOURNAL")" >/dev/null ||
  fail 'committed journal was not retained after directory sync failure'
assert_install_state landing-a 9.9.9.9 "$work/key-one.pub"
committed_digest="$(channel_snapshot_digest)"
# 模拟 committed 已持久、事务目录递归清理到一半后断电。
rm -f -- "$(channel_path "$LANDING_CHANNEL_TRANSACTION_DIRECTORY")/snapshot/runtime"
observed_recovery_digest=""
with_landing_channel_lock recovery_digest_probe
[[ "$observed_recovery_digest" == "$committed_digest" ]] ||
  fail 'committed recovery with a partial stale snapshot changed the fully activated new state'
assert_install_state landing-a 9.9.9.9 "$work/key-one.pub"
assert_transaction_absent

# 回到基准状态，后续卸载恢复仍应逐字节匹配原快照。
install_landing_restricted_channel landing-a 1.1.1.1 "$work/key-two.pub"
[[ "$(channel_snapshot_digest)" == "$rotated_digest" ]] ||
  fail 'normal update after committed recovery did not restore the baseline state'
assert_transaction_absent

# uninstall 事务在全部文件与账户已删除后中断，下次独占锁操作应自动重建。
landing_channel_begin_transaction uninstall "$channel_uid" "$channel_gid"
landing_channel_remove_file "$LANDING_CHANNEL_AUTHORIZED_KEYS_PATH"
landing_channel_remove_file "$LANDING_CHANNEL_SUDOERS_PATH"
landing_channel_remove_file "$LANDING_AGENT_HELPER_PATH"
landing_channel_remove_file "$LANDING_CHANNEL_AGENT_PATH"
landing_channel_remove_file "$LANDING_CHANNEL_RUNTIME_PATH"
landing_channel_remove_file "$LANDING_CHANNEL_GENERATION_PATH"
landing_channel_remove_file "$LANDING_CHANNEL_IDENTITY_PATH"
landing_channel_remove_empty_directory "$LANDING_CHANNEL_SSH_DIRECTORY"
landing_channel_remove_empty_directory "$LANDING_CHANNEL_HOME"
landing_channel_remove_empty_directory "$LANDING_CHANNEL_RUNTIME_DIRECTORY"
landing_channel_system_userdel "$LANDING_CHANNEL_ACCOUNT"
landing_channel_system_groupdel "$LANDING_CHANNEL_GROUP"
jq -e '.mode == "uninstall" and .phase == "active"' \
  "$(channel_path "$LANDING_CHANNEL_TRANSACTION_JOURNAL")" >/dev/null ||
  fail 'uninstall transaction journal was not active'
landing_channel_reset_active_transaction
# 模拟回滚重建目录后、切换到专用组前再次崩溃。
install -d -m 750 -- "$(channel_path "$LANDING_CHANNEL_RUNTIME_DIRECTORY")"
landing_channel_apply_ownership \
  "$(channel_path "$LANDING_CHANNEL_RUNTIME_DIRECTORY")" \
  "$(landing_channel_expected_root_uid)" "$(landing_channel_expected_root_gid)"
observed_recovery_digest=""
with_landing_channel_lock recovery_digest_probe
[[ "$observed_recovery_digest" == "$rotated_digest" ]] ||
  fail 'exclusive lock callback did not observe the recovered uninstall state'
assert_install_state landing-a 1.1.1.1 "$work/key-two.pub"
assert_transaction_absent

# 未知 home 内容必须使状态失效并阻止更新/卸载，不能删除不属于本项目的数据。
printf 'keep\n' > "$(channel_path "$LANDING_CHANNEL_HOME")/foreign-data"
if landing_restricted_channel_is_valid; then
  fail 'status accepted unknown home content'
fi
if install_landing_restricted_channel landing-a 1.1.1.1 "$work/key-two.pub"; then
  fail 'reinstall accepted unknown home content'
fi
if uninstall_landing_restricted_channel; then
  fail 'uninstall accepted unknown home content'
fi
grep -Fxq keep "$(channel_path "$LANDING_CHANNEL_HOME")/foreign-data" || fail 'unknown home content was modified'
assert_transaction_absent
rm -f -- "$(channel_path "$LANDING_CHANNEL_HOME")/foreign-data"
landing_restricted_channel_is_valid || fail 'status did not recover after unknown home content was removed'

printf 'keep runtime\n' > "$(channel_path "$LANDING_CHANNEL_RUNTIME_DIRECTORY")/foreign-runtime"
if landing_restricted_channel_is_valid; then
  fail 'status accepted unknown runtime content'
fi
rm -f -- "$(channel_path "$LANDING_CHANNEL_RUNTIME_DIRECTORY")/foreign-runtime"
landing_restricted_channel_is_valid || fail 'status did not recover after unknown runtime content was removed'

# groupdel 在实际删除后报错，回滚要按原 UID/GID 重建账户并恢复全部文件。
: > "$fail_groupdel_after"
if uninstall_landing_restricted_channel; then
  fail 'partial groupdel failure was accepted'
fi
[[ "$(channel_snapshot_digest)" == "$rotated_digest" ]] || fail 'failed uninstall did not restore exact prior state'
assert_install_state landing-a 1.1.1.1 "$work/key-two.pub"
assert_transaction_absent

uninstall_landing_restricted_channel
channel_artifacts_absent || fail 'final uninstall left managed resources behind'
uninstall_landing_restricted_channel

printf 'landing channel install tests passed\n'
