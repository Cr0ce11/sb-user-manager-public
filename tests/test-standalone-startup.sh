#!/usr/bin/env bash
# 启动测试会替换已加载函数，只验证 standalone 编排，不执行真实安装或服务操作。
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
# shellcheck source=./require-strict-errexit.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/require-strict-errexit.sh"

cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

export SB_USER_MANAGER_LIBRARY=true
export SB_SYSTEM_ROOT="$work/system-root"

# shellcheck source=../sb-user-manager.sh
source ./sb-user-manager.sh

fail() {
  printf 'standalone startup test failed: %s\n' "$1" >&2
  exit 1
}

assert_log() {
  local expected="$1"
  [[ "$(<"$work/calls")" == "$expected" ]] || {
    printf 'expected calls:\n%s\nactual calls:\n%s\n' "$expected" "$(<"$work/calls")" >&2
    fail 'unexpected call order'
  }
}

reset_calls() {
  : > "$work/calls"
}

record_call() {
  printf '%s\n' "$1" >> "$work/calls"
}

FAIL_AT=""

record_stub_result() {
  local step="$1"
  record_call "$step"
  [[ "$FAIL_AT" != "$step" ]]
}

recover_environment_transaction() { record_stub_result recover-environment; }
handoff_to_newer_installed_manager() {
  if (($#)); then
    record_stub_result "handoff:$*"
  else
    record_stub_result handoff:interactive
  fi
}
harden_existing_environment_backups() { record_call harden-backups; }
ensure_manager_launch_copies_for_interactive_startup() { record_stub_result sync-launch-copy; }
ensure_manager_shortcut_for_interactive_startup() { record_stub_result sync-shortcut; }
recover_transaction_before_menu() { record_stub_result recover-state; }
migrate_backup_retention_once() { record_call migrate-backup-retention; }
migrate_legacy_ss2022_udp_inbounds() { record_call migrate-udp; }
migrate_empty_split_preset_fields() { record_call migrate-split-preset-fields; }
migrate_shared_preset_runtime_configs() { record_call migrate-presets; }
interactive_main() { record_stub_result standalone-menu; }
prepare_core() { record_stub_result prepare-core; }
cmd_expire() { record_stub_result expire; }
install_environment() { fail 'standalone startup attempted an automatic deployment'; }
log() { record_call warning; }

standalone_footprint_paths=(
  /etc/sb-user-manager.conf
  /etc/sing-box/config.json
  /etc/sing-box/managed-users.json
  /usr/local/sbin/sb-user-manager
  /usr/local/bin/sing-box
  /usr/local/bin/nfuse
  /etc/systemd/system/sing-box.service
  /etc/systemd/system/nfuse.service
  /etc/systemd/system/sb-user-expiry.service
  /etc/systemd/system/sb-user-expiry.timer
)

make_complete_standalone_footprint() {
  local logical rooted
  for logical in "${standalone_footprint_paths[@]}"; do
    rooted="$(system_path "$logical")"
    mkdir -p "$(dirname "$rooted")"
    : > "$rooted"
  done
}

# 新入口固定拒绝额外参数，且拒绝发生在任何恢复或写入动作前。
for zero_arg_entry in run_standalone_interactive_startup run_standalone_internal_expire; do
  reset_calls
  set +e
  "$zero_arg_entry" unexpected >/dev/null 2>&1
  rc=$?
  set -e
  [[ "$rc" == 64 ]] || fail "$zero_arg_entry accepted an unexpected argument"
  assert_log ''
done

# 交互启动保留原 standalone 顺序；全新服务器也只进入现有主菜单，不自动部署。
reset_calls
run_standalone_interactive_startup || fail 'interactive startup failed'
assert_log $'recover-environment\nhandoff:interactive\nharden-backups\nsync-launch-copy\nsync-shortcut\nrecover-state\nmigrate-backup-retention\nmigrate-udp\nmigrate-split-preset-fields\nmigrate-presets\nstandalone-menu'

# 关键步骤在条件调用上下文中也必须显式失败即止，不能依赖 set -e。
for failure_case in \
  'recover-environment|recover-environment' \
  'handoff:interactive|recover-environment;handoff:interactive' \
  'sync-launch-copy|recover-environment;handoff:interactive;harden-backups;sync-launch-copy' \
  'sync-shortcut|recover-environment;handoff:interactive;harden-backups;sync-launch-copy;sync-shortcut' \
  'recover-state|recover-environment;handoff:interactive;harden-backups;sync-launch-copy;sync-shortcut;recover-state' \
  'standalone-menu|recover-environment;handoff:interactive;harden-backups;sync-launch-copy;sync-shortcut;recover-state;migrate-backup-retention;migrate-udp;migrate-split-preset-fields;migrate-presets;standalone-menu'; do
  FAIL_AT="${failure_case%%|*}"
  expected_calls="${failure_case#*|}"
  expected_calls="${expected_calls//;/$'\n'}"
  reset_calls
  if run_standalone_interactive_startup >"$work/$FAIL_AT.out" 2>&1; then
    fail "interactive startup continued after $FAIL_AT failed"
  fi
  assert_log "$expected_calls"
done
FAIL_AT=""

# 非关键的快照收紧和迁移失败仍只告警，不能阻止主菜单。
harden_existing_environment_backups() { record_call harden-backups; return 1; }
migrate_backup_retention_once() { record_call migrate-backup-retention; return 1; }
migrate_legacy_ss2022_udp_inbounds() { record_call migrate-udp; return 1; }
migrate_empty_split_preset_fields() { record_call migrate-split-preset-fields; return 1; }
migrate_shared_preset_runtime_configs() { record_call migrate-presets; return 1; }
reset_calls
run_standalone_interactive_startup || fail 'warning path stopped the standalone menu'
assert_log $'recover-environment\nhandoff:interactive\nharden-backups\nwarning\nsync-launch-copy\nsync-shortcut\nrecover-state\nmigrate-backup-retention\nwarning\nmigrate-udp\nwarning\nmigrate-split-preset-fields\nwarning\nmigrate-presets\nwarning\nstandalone-menu'

# 全新或不完整环境中的无人值守到期任务必须失败关闭，不能移交或修改运行状态。
rm -rf -- "$SB_SYSTEM_ROOT"
reset_calls
if run_standalone_internal_expire >"$work/fresh-expire.out" 2>&1; then
  fail 'fresh environment accepted the internal expiry task'
fi
assert_log 'recover-environment'
grep -Fq '尚未完成单机部署' "$work/fresh-expire.out"

for missing_path in "${standalone_footprint_paths[@]}"; do
  rm -rf -- "$SB_SYSTEM_ROOT"
  make_complete_standalone_footprint
  rm -f -- "$(system_path "$missing_path")"
  reset_calls
  if run_standalone_internal_expire >"$work/partial-expire.out" 2>&1; then
    fail "partial environment without $missing_path accepted the internal expiry task"
  fi
  assert_log 'recover-environment'
  grep -Fq '尚未完成单机部署' "$work/partial-expire.out"
done

# 只有外部核心程序、没有本项目管理足迹时同样不能被定时任务接管。
rm -rf -- "$SB_SYSTEM_ROOT"
for logical in \
  /etc/sing-box/config.json \
  /usr/local/bin/sing-box \
  /usr/local/bin/nfuse \
  /etc/systemd/system/sing-box.service \
  /etc/systemd/system/nfuse.service \
  /var/lib/nfuse/nfuse.db; do
  rooted="$(system_path "$logical")"
  mkdir -p "$(dirname "$rooted")"
  : > "$rooted"
done
reset_calls
if run_standalone_internal_expire >"$work/external-expire.out" 2>&1; then
  fail 'external environment accepted the internal expiry task'
fi
assert_log 'recover-environment'
grep -Fq '尚未完成单机部署' "$work/external-expire.out"

# 完整部署中的到期任务只执行既有 v4 恢复、管理器移交、核心准备和到期处理。
make_complete_standalone_footprint
reset_calls
run_standalone_internal_expire || fail 'internal expiry failed'
assert_log $'recover-environment\nhandoff:--internal-expire\nprepare-core\nexpire'

for failure_case in \
  'recover-environment|recover-environment' \
  'handoff:--internal-expire|recover-environment;handoff:--internal-expire' \
  'prepare-core|recover-environment;handoff:--internal-expire;prepare-core' \
  'expire|recover-environment;handoff:--internal-expire;prepare-core;expire'; do
  FAIL_AT="${failure_case%%|*}"
  expected_calls="${failure_case#*|}"
  expected_calls="${expected_calls//;/$'\n'}"
  reset_calls
  if run_standalone_internal_expire >"$work/$FAIL_AT.out" 2>&1; then
    fail "internal expiry continued after $FAIL_AT failed"
  fi
  assert_log "$expected_calls"
done
FAIL_AT=""

main_body="$(declare -f main)"
grep -Fq 'run_standalone_interactive_startup' <<<"$main_body"
grep -Fq 'run_standalone_internal_expire' <<<"$main_body"
if grep -Eq 'dispatch_interactive_startup|entry_controller_main|landing_managed_main' <<<"$main_body"; then
  fail 'main still routes into a retired v5 role'
fi

startup_body="$(declare -f run_standalone_interactive_startup)"
if grep -Eq 'detect_manager_role|entry_controller|landing_managed|provision_entry' <<<"$startup_body"; then
  fail 'standalone startup still depends on a retired v5 role'
fi

# 两个遗留 helper 文件名都必须明确失败，不能再进入落地 agent/apply，也不能误进主菜单。
for retired_helper in sb-user-manager-landing-agent sb-user-manager-landing-apply; do
  cp sb-user-manager.sh "$work/$retired_helper"
  chmod 700 "$work/$retired_helper"
  if env -u SB_USER_MANAGER_LIBRARY "$work/$retired_helper" \
      >"$work/$retired_helper.out" 2>&1; then
    fail "$retired_helper entry was accepted"
  fi
  grep -Fq 'v5 入口与落地能力已经退役' "$work/$retired_helper.out"
done

echo 'standalone startup checks passed'
