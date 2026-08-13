#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sb-manager-handoff-test.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

export SB_USER_MANAGER_LIBRARY=true
# shellcheck source=../sb-user-manager.sh
source "$ROOT/sb-user-manager.sh"

fail() {
  printf 'manager handoff test failed: %s\n' "$1" >&2
  exit 1
}

REAL_FLOCK_AVAILABLE=true
if ! command -v flock >/dev/null 2>&1; then
  REAL_FLOCK_AVAILABLE=false
  flock() { return 0; }
fi
if ! sync -f "$ROOT/sb-user-manager.sh" 2>/dev/null; then
  sync_transaction_path() { return 0; }
fi

systemctl() {
  printf '%s\n' "$*" >> "$WORK/systemctl.events"
  return 1
}

make_manager_fixture() {
  local output="$1" version="$2" edition="$3" schema="$4" minimum_schema="$5"
  sed \
    -e "s/^SCRIPT_VERSION=\"[^\"]*\"$/SCRIPT_VERSION=\"${version}\"/" \
    -e "s/^SCRIPT_EDITION_LABEL=\"[^\"]*\"$/SCRIPT_EDITION_LABEL=\"${edition}\"/" \
    -e "s/^STATE_SCHEMA_VERSION=[0-9][0-9]*$/STATE_SCHEMA_VERSION=${schema}/" \
    -e "s/^MIN_SUPPORTED_STATE_SCHEMA_VERSION=[0-9][0-9]*$/MIN_SUPPORTED_STATE_SCHEMA_VERSION=${minimum_schema}/" \
    "$ROOT/sb-user-manager.sh" > "$output"
  chmod 755 "$output"
}

activate_candidate() {
  local candidate="$1" version="$2" edition="$3" schema="$4" minimum_schema="$5"
  SELF_SOURCE_PATH="$candidate"
  SELF_PATH="$candidate"
  SCRIPT_VERSION="$version"
  SCRIPT_EDITION_LABEL="$edition"
  STATE_SCHEMA_VERSION="$schema"
  MIN_SUPPORTED_STATE_SCHEMA_VERSION="$minimum_schema"
}

setup_case() {
  local name="$1" installed_fixture="$2" installed_version="$3"
  CASE_ROOT="$WORK/$name"
  install -d -m 700 \
    "$CASE_ROOT/usr/local/sbin" "$CASE_ROOT/var/lib/sb-user-manager" \
    "$CASE_ROOT/run/lock" "$CASE_ROOT/etc/sing-box/cert" "$CASE_ROOT/var/lib/nfuse" \
    "$CASE_ROOT/root"
  MANAGER_INSTALLED_PATH="$CASE_ROOT/usr/local/sbin/sb-user-manager"
  DEPLOYED_VERSIONS_FILE="$CASE_ROOT/var/lib/sb-user-manager/versions"
  LOCK_FILE="$CASE_ROOT/run/lock/operation.lock"
  ENVIRONMENT_LOCK_FILE="$CASE_ROOT/run/lock/environment.lock"
  ENVIRONMENT_TRANSACTION_JOURNAL="$CASE_ROOT/var/lib/sb-user-manager.recovery.json"
  MANAGER_HANDOFF_DIRECTORY="$CASE_ROOT/var/lib/sb-user-manager/manager-handoff"
  MANAGER_HANDOFF_JOURNAL="$MANAGER_HANDOFF_DIRECTORY/active.json"
  MANAGER_ROOT_LAUNCH_COPY="$CASE_ROOT/root/sb-user-manager.sh"
  install -m 700 "$installed_fixture" "$MANAGER_INSTALLED_PATH"
  install -m 700 "$installed_fixture" "$MANAGER_ROOT_LAUNCH_COPY"
  printf 'SCRIPT_VERSION=%s\nSINGBOX_VERSION=1.12.0\nNFUSE_VERSION=0.1.13\n' \
    "$installed_version" > "$DEPLOYED_VERSIONS_FILE"
  chmod 600 "$DEPLOYED_VERSIONS_FILE"
  printf '{"schema_version":4,"users":[],"splits":[]}\n' > "$CASE_ROOT/etc/sing-box/managed-users.json"
  printf '{"inbounds":[],"outbounds":[],"route":{"rules":[]}}\n' > "$CASE_ROOT/etc/sing-box/config.json"
  printf 'certificate-data\n' > "$CASE_ROOT/etc/sing-box/cert/anytls.crt"
  printf 'private-key-data\n' > "$CASE_ROOT/etc/sing-box/cert/anytls.key"
  printf 'nfuse-database-data\n' > "$CASE_ROOT/var/lib/nfuse/nfuse.db"
  CASE_DATA_DIGEST="$(case_data_digest)"
}

case_data_digest() {
  sha256sum \
    "$CASE_ROOT/etc/sing-box/managed-users.json" \
    "$CASE_ROOT/etc/sing-box/config.json" \
    "$CASE_ROOT/etc/sing-box/cert/anytls.crt" \
    "$CASE_ROOT/etc/sing-box/cert/anytls.key" \
    "$CASE_ROOT/var/lib/nfuse/nfuse.db" |
    sha256sum | awk '{print $1}'
}

assert_case_data_unchanged() {
  [[ "$(case_data_digest)" == "$CASE_DATA_DIGEST" ]] || fail 'handoff changed managed data'
}

public_current="$WORK/public-current.sh"
private_old="$WORK/private-old.sh"
public_old="$WORK/public-old.sh"
private_future="$WORK/private-future.sh"
schema_future="$WORK/schema-future.sh"
public_min5="$WORK/public-min5.sh"
make_manager_fixture "$public_current" 4.23.5 公开版 5 0
make_manager_fixture "$private_old" 4.22.9 私有版 4 0
make_manager_fixture "$public_old" 4.22.9 公开版 4 0
make_manager_fixture "$private_future" 9.0.0 私有版 5 0
make_manager_fixture "$schema_future" 4.22.9 私有版 6 0
make_manager_fixture "$public_min5" 4.23.5 公开版 5 5

# 低版本私有版必须可由较新公开版直接接管，并保留完整数据和可恢复旧脚本。
setup_case forward-private-to-public "$private_old" 4.22.9
old_installed="$WORK/forward-private-old.sh"
cp "$MANAGER_INSTALLED_PATH" "$old_installed"
activate_candidate "$public_current" 4.23.5 公开版 5 0
take_over_installed_manager >/dev/null || fail 'new public manager could not take over old private manager'
if { printf x >&9; } 2>/dev/null; then fail 'successful handoff left operation lock descriptor open'; fi
cmp -s "$public_current" "$MANAGER_INSTALLED_PATH" || fail 'public target was not installed'
cmp -s "$old_installed" "$MANAGER_HANDOFF_DIRECTORY/previous.sh" || fail 'old private manager rollback copy is wrong'
cmp -s "$public_current" "$MANAGER_ROOT_LAUNCH_COPY" || fail 'root launch copy was not synchronized'
grep -Fxq 'SCRIPT_VERSION=4.23.5' "$DEPLOYED_VERSIONS_FILE" || fail 'manager version record was not advanced'
grep -Fxq 'SINGBOX_VERSION=1.12.0' "$DEPLOYED_VERSIONS_FILE" || fail 'sing-box version record changed'
grep -Fxq 'NFUSE_VERSION=0.1.13' "$DEPLOYED_VERSIONS_FILE" || fail 'Nfuse version record changed'
[[ ! -e "$MANAGER_HANDOFF_JOURNAL" ]] || fail 'successful handoff left an active journal'
assert_case_data_unchanged

# 已接管的公开版必须允许同版本公开目标安全重复执行，不再承诺切回私有发布渠道。
activate_candidate "$public_current" 4.23.5 公开版 5 0
take_over_installed_manager >/dev/null || fail 'same-version public handoff was not idempotent'
cmp -s "$public_current" "$MANAGER_INSTALLED_PATH" || fail 'same-version public target was not preserved'
assert_case_data_unchanged

# 活跃用户/分流操作持有 fd 9 时，管理脚本接管也不能并发写入。
if [[ "$REAL_FLOCK_AVAILABLE" == true ]]; then
  setup_case reject-live-operation "$private_old" 4.22.9
  activate_candidate "$public_current" 4.23.5 公开版 5 0
  exec 7>"$LOCK_FILE"
  command flock -n 7
  if take_over_installed_manager >"$CASE_ROOT/output" 2>&1; then
    fail 'manager handoff ignored an active user operation lock'
  fi
  grep -Fq '另一个安装、恢复或接管操作正在执行' "$CASE_ROOT/output" ||
    fail 'manager handoff lock rejection was unclear'
  command flock -u 7
  exec 7>&-
  assert_case_data_unchanged
fi

# 同渠道也允许严格向前升级。
setup_case forward-public-to-public "$public_old" 4.22.9
activate_candidate "$public_current" 4.23.5 公开版 5 0
take_over_installed_manager >/dev/null || fail 'same-channel forward manager upgrade was rejected'
cmp -s "$public_current" "$MANAGER_INSTALLED_PATH" || fail 'same-channel forward target was not installed'
assert_case_data_unchanged

# 任何版本降级都必须在创建回退目录前拒绝。
setup_case reject-downgrade "$private_future" 9.0.0
future_digest="$(manager_handoff_sha256 "$MANAGER_INSTALLED_PATH")"
activate_candidate "$public_current" 4.23.5 公开版 5 0
if take_over_installed_manager >"$CASE_ROOT/output" 2>&1; then
  fail 'manager downgrade was accepted'
fi
grep -Fq '禁止管理脚本降级' "$CASE_ROOT/output" || fail 'downgrade rejection was unclear'
[[ "$(manager_handoff_sha256 "$MANAGER_INSTALLED_PATH")" == "$future_digest" ]] || fail 'downgrade rejection changed installed manager'
[[ ! -e "$MANAGER_HANDOFF_DIRECTORY" ]] || fail 'downgrade rejection created a rollback directory'
assert_case_data_unchanged

# schema 倒退或超出目标迁移下限都必须拒绝。
setup_case reject-schema-downgrade "$schema_future" 4.22.9
activate_candidate "$public_current" 4.23.5 公开版 5 0
if take_over_installed_manager >"$CASE_ROOT/output" 2>&1; then
  fail 'schema downgrade was accepted'
fi
grep -Fq '不支持当前数据版本范围' "$CASE_ROOT/output" || fail 'schema downgrade rejection was unclear'
assert_case_data_unchanged

setup_case reject-schema-minimum "$private_old" 4.22.9
activate_candidate "$public_min5" 4.23.5 公开版 5 5
if take_over_installed_manager >"$CASE_ROOT/output" 2>&1; then
  fail 'unsupported old schema was accepted'
fi
grep -Fq '不支持当前数据版本范围' "$CASE_ROOT/output" || fail 'minimum schema rejection was unclear'
assert_case_data_unchanged

# 目标、安装入口、权限和结构异常都必须在写入前拒绝。
setup_case reject-candidate-symlink "$private_old" 4.22.9
ln -s "$public_current" "$CASE_ROOT/public-link.sh"
activate_candidate "$public_current" 4.23.5 公开版 5 0
SELF_SOURCE_PATH="$CASE_ROOT/public-link.sh"
if take_over_installed_manager >/dev/null 2>&1; then fail 'candidate symlink was accepted'; fi
assert_case_data_unchanged

setup_case reject-installed-symlink "$private_old" 4.22.9
mv "$MANAGER_INSTALLED_PATH" "$CASE_ROOT/installed-real.sh"
ln -s "$CASE_ROOT/installed-real.sh" "$MANAGER_INSTALLED_PATH"
activate_candidate "$public_current" 4.23.5 公开版 5 0
if take_over_installed_manager >/dev/null 2>&1; then fail 'installed manager symlink was accepted'; fi
assert_case_data_unchanged

setup_case reject-unsafe-mode "$private_old" 4.22.9
chmod 755 "$MANAGER_INSTALLED_PATH"
activate_candidate "$public_current" 4.23.5 公开版 5 0
if take_over_installed_manager >/dev/null 2>&1; then fail 'unsafe installed manager mode was accepted'; fi
assert_case_data_unchanged

setup_case reject-damaged-candidate "$private_old" 4.22.9
damaged="$CASE_ROOT/damaged.sh"
printf '#!/usr/bin/env bash\nPROGRAM="sb-user-manager"\nif (\n' > "$damaged"
chmod 700 "$damaged"
activate_candidate "$damaged" 4.23.5 公开版 5 0
if take_over_installed_manager >/dev/null 2>&1; then fail 'damaged target manager was accepted'; fi
assert_case_data_unchanged

# 最终核验失败必须原子恢复脚本和版本记录，并清除活动日志。
setup_case rollback-final-verification "$private_old" 4.22.9
rollback_old_digest="$(manager_handoff_sha256 "$MANAGER_INSTALLED_PATH")"
rollback_versions_digest="$(manager_handoff_sha256 "$DEPLOYED_VERSIONS_FILE")"
activate_candidate "$public_current" 4.23.5 公开版 5 0
if (
  verify_manager_handoff_installation() { return 1; }
  take_over_installed_manager >/dev/null 2>&1
); then
  fail 'forced final verification failure succeeded'
fi
[[ "$(manager_handoff_sha256 "$MANAGER_INSTALLED_PATH")" == "$rollback_old_digest" ]] || fail 'failed handoff did not restore old manager'
[[ "$(manager_handoff_sha256 "$DEPLOYED_VERSIONS_FILE")" == "$rollback_versions_digest" ]] || fail 'failed handoff did not restore version record'
[[ ! -e "$MANAGER_HANDOFF_JOURNAL" ]] || fail 'successful rollback left an active journal'
assert_case_data_unchanged

# 即使活动日志已删除、目录同步随后失败，也必须使用内存中的旧摘要完成回滚。
setup_case rollback-journal-sync "$private_old" 4.22.9
rollback_old_digest="$(manager_handoff_sha256 "$MANAGER_INSTALLED_PATH")"
rollback_versions_digest="$(manager_handoff_sha256 "$DEPLOYED_VERSIONS_FILE")"
activate_candidate "$public_current" 4.23.5 公开版 5 0
if (
  clear_manager_handoff_journal() {
    rm -f -- "$MANAGER_HANDOFF_JOURNAL"
    return 1
  }
  take_over_installed_manager >/dev/null 2>&1
); then
  fail 'forced journal sync failure succeeded'
fi
[[ "$(manager_handoff_sha256 "$MANAGER_INSTALLED_PATH")" == "$rollback_old_digest" ]] || fail 'journal sync failure did not restore old manager'
[[ "$(manager_handoff_sha256 "$DEPLOYED_VERSIONS_FILE")" == "$rollback_versions_digest" ]] || fail 'journal sync failure did not restore version record'
assert_case_data_unchanged

# 模拟替换后断电：下次启动前的恢复入口必须先恢复旧脚本与版本记录。
setup_case recover-interrupted "$private_old" 4.22.9
activate_candidate "$public_current" 4.23.5 公开版 5 0
prepare_manager_handoff_directory
backup_script="$(manager_handoff_backup_script_path)"
backup_versions="$(manager_handoff_backup_versions_path)"
old_sha256="$(manager_handoff_sha256 "$MANAGER_INSTALLED_PATH")"
atomic_install_file "$MANAGER_INSTALLED_PATH" "$backup_script" 700
atomic_install_file "$DEPLOYED_VERSIONS_FILE" "$backup_versions" 600
write_manager_handoff_journal 4.22.9 私有版 4 "$old_sha256" 4.23.5 公开版 5
atomic_install_file "$public_current" "$MANAGER_INSTALLED_PATH" 700
update_deployed_manager_version 4.23.5
recover_manager_handoff >/dev/null || fail 'interrupted handoff was not recovered'
if { printf x >&9; } 2>/dev/null; then fail 'handoff recovery left operation lock descriptor open'; fi
[[ "$MANAGER_HANDOFF_RECOVERED" == true ]] || fail 'startup recovery was not exposed to the dispatcher'
[[ "$(manager_handoff_sha256 "$MANAGER_INSTALLED_PATH")" == "$old_sha256" ]] || fail 'startup recovery did not restore old manager'
grep -Fxq 'SCRIPT_VERSION=4.22.9' "$DEPLOYED_VERSIONS_FILE" || fail 'startup recovery did not restore old version record'
[[ ! -e "$MANAGER_HANDOFF_JOURNAL" ]] || fail 'startup recovery left an active journal'
assert_case_data_unchanged

[[ ! -s "$WORK/systemctl.events" ]] || fail 'manager handoff called a service lifecycle command'

echo 'manager channel handoff checks passed'
