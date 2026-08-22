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

# 下面的用例把编排里的每一步都打成桩，只验顺序。**权限修复那一步光验顺序不够**：
# 它的价值全在真的 chmod 上（公开 Issue #252）。所以先把真实实现留一份，
# 最后一个用例把它装回去，让启动编排真的跑到那次 chmod。
real_repair_system_directory_modes="$(declare -f repair_system_directory_modes)"

assert_log() {
  local expected="$1"
  [[ "$(<"$work/calls")" == "$expected" ]] || {
    printf 'expected calls:\n%s\nactual calls:\n%s\n' "$expected" "$(<"$work/calls")" >&2
    fail 'unexpected call order'
  }
}

# 每个用例都从文件级默认值重新开始。真机上定时任务每 15 分钟是一个**全新进程**，
# 而这份测试在同一个进程里连着跑十几个用例：确定内核那一步会改 PROXY_KERNEL 与
# MANAGER_DATA_DIR（干净机器按 2f 走中立数据目录），不重置就会漏到后面的用例里，
# 让后面的断言测的是一个真机上不存在的状态组合。
reset_kernel_defaults() {
  PROXY_KERNEL=singbox
  MANAGER_DATA_DIR=/etc/sing-box
  resolve_manager_data_paths
  STATE_FILE="$MANAGER_DATA_DIR/managed-users.json"
  BACKUP_DIR="$MANAGER_DATA_DIR/backups"
}

reset_calls() {
  : > "$work/calls"
  reset_kernel_defaults
}

record_call() {
  printf '%s\n' "$1" >> "$work/calls"
}

# CONF_FILE 不经 SB_SYSTEM_ROOT，否则这里会读到跑测试那台机器的真实配置，
# 用例的行为就会随宿主机而变。下面的编排用例一律按「本脚本部署过的机器」进行：
# 权限修复那一步只在管理配置存在时才跑（公开 Issue #252）。
CONF_FILE="$work/deployed-manager.conf"
: > "$CONF_FILE"

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
repair_system_directory_modes() { record_call repair-system-dirs; }
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
assert_log $'recover-environment\nhandoff:interactive\nharden-backups\nsync-launch-copy\nsync-shortcut\nrecover-state\nrepair-system-dirs\nmigrate-backup-retention\nmigrate-udp\nmigrate-split-preset-fields\nmigrate-presets\nstandalone-menu'

# 对照：一台没有管理配置的机器——只是把脚本下载下来打开菜单看看——不碰系统目录
# 权限。缺了这条对照就分不清「修复挂在启动编排上」和「脚本一运行就改别人的
# 系统目录」（公开 Issue #252）。
mv -- "$CONF_FILE" "$CONF_FILE.away"
reset_calls
run_standalone_interactive_startup || fail 'interactive startup failed without a manager config'
assert_log $'recover-environment\nhandoff:interactive\nharden-backups\nsync-launch-copy\nsync-shortcut\nrecover-state\nmigrate-backup-retention\nmigrate-udp\nmigrate-split-preset-fields\nmigrate-presets\nstandalone-menu'
mv -- "$CONF_FILE.away" "$CONF_FILE"

# 关键步骤在条件调用上下文中也必须显式失败即止，不能依赖 set -e。
for failure_case in \
  'recover-environment|recover-environment' \
  'handoff:interactive|recover-environment;handoff:interactive' \
  'sync-launch-copy|recover-environment;handoff:interactive;harden-backups;sync-launch-copy' \
  'sync-shortcut|recover-environment;handoff:interactive;harden-backups;sync-launch-copy;sync-shortcut' \
  'recover-state|recover-environment;handoff:interactive;harden-backups;sync-launch-copy;sync-shortcut;recover-state' \
  'standalone-menu|recover-environment;handoff:interactive;harden-backups;sync-launch-copy;sync-shortcut;recover-state;repair-system-dirs;migrate-backup-retention;migrate-udp;migrate-split-preset-fields;migrate-presets;standalone-menu'; do
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
assert_log $'recover-environment\nhandoff:interactive\nharden-backups\nwarning\nsync-launch-copy\nsync-shortcut\nrecover-state\nrepair-system-dirs\nmigrate-backup-retention\nwarning\nmigrate-udp\nwarning\nmigrate-split-preset-fields\nwarning\nmigrate-presets\nwarning\nstandalone-menu'

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

# 公开 Issue #251 的回归：到期任务在载入管理配置之前就检查环境完不完整，那一刻
# PROXY_KERNEL 还是文件级默认值 sing-box，于是一台 mihomo 机器会被判成「没装好」，
# 定时任务每 15 分钟失败一次、到期用户永远不会被自动停用。
# **夹具必须是 mihomo 形状**——上面那份是 sing-box 形状，恰好与那个错误的默认值一致，
# 所以它永远看不见这个缺陷。
mihomo_footprint_paths=(
  /etc/sb-user-manager.conf
  /etc/mihomo/config.json
  /usr/local/bin/mihomo
  /etc/systemd/system/mihomo.service
  /etc/sb-user-manager/managed-users.json
  /usr/local/sbin/sb-user-manager
  /usr/local/bin/nfuse
  /etc/systemd/system/nfuse.service
  /etc/systemd/system/sb-user-expiry.service
  /etc/systemd/system/sb-user-expiry.timer
)

make_mihomo_standalone_footprint() {
  local logical rooted
  rm -rf -- "$SB_SYSTEM_ROOT"
  for logical in "${mihomo_footprint_paths[@]}"; do
    rooted="$(system_path "$logical")"
    mkdir -p "$(dirname "$rooted")"
    : > "$rooted"
  done
}

(
  # 子 shell：resolve_deployment_kernel 会改 PROXY_KERNEL 与 MANAGER_DATA_DIR，
  # 不让它漏到后面的用例里。
  # 管理配置指向一个不存在的路径，以走「按机器上已有的东西推断内核」那条分支——
  # CONF_FILE 不经 SB_SYSTEM_ROOT，否则这里会读到跑测试那台机器的真实配置。
  CONF_FILE="$work/absent-manager.conf"

  make_mihomo_standalone_footprint
  reset_calls
  run_standalone_internal_expire >"$work/mihomo-expire.out" 2>&1 ||
    fail 'mihomo deployment rejected the internal expiry task'
  assert_log $'recover-environment\nhandoff:--internal-expire\nprepare-core\nexpire'

  # 对照：装了一半的 mihomo 机器仍然必须被拒绝。少了这一条，就分不清是缺陷修好了
  # 还是这项检查整个失效了。
  for missing_path in /etc/mihomo/config.json /usr/local/bin/mihomo /usr/local/bin/nfuse; do
    make_mihomo_standalone_footprint
    rm -f -- "$(system_path "$missing_path")"
    reset_calls
    if run_standalone_internal_expire >"$work/mihomo-partial-expire.out" 2>&1; then
      fail "partial mihomo environment without $missing_path accepted the internal expiry task"
    fi
    grep -Fq '尚未完成单机部署' "$work/mihomo-partial-expire.out"
  done
)

# 后面的用例仍按 sing-box 形状的完整夹具进行。
make_complete_standalone_footprint

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

# 权限修复真的发生在启动编排里（公开 Issue #252）。上面的用例只验了它在顺序里的
# 位置，这一条把真实实现装回去，造一台「目录是 700 + 已装新脚本」的机器，
# **只运行一次交互启动、不做任何部署动作**，确认两个目录变回 755。
#
# 对照有两条，缺了任何一条都分不清「修复在起作用」和「它把什么都改成 755」：
#   一、不是 700 的值不被覆盖——管理员自己设成 750 的目录必须原样留着。
#   二、管理器自己的目录（/var/lib/sb-user-manager）故意就是 700，不能被顺手放宽。
(
  eval "$real_repair_system_directory_modes"
  repair_root="$work/startup-repair-252"
  SB_SYSTEM_ROOT="$repair_root"
  mkdir -p "$repair_root/var/lib/sb-user-manager" "$repair_root/usr/local/sbin" "$repair_root/usr/local/bin"
  # 这台机器是本脚本部署过的，管理配置在。
  CONF_FILE="$work/deployed-manager.conf"
  chmod 700 "$repair_root/var/lib" "$repair_root/usr/local/sbin"
  chmod 700 "$repair_root/var/lib/sb-user-manager"
  chmod 750 "$repair_root/usr/local/bin"

  reset_calls
  run_standalone_interactive_startup || fail 'startup with the real permission repair failed'

  [[ "$(manager_file_mode "$repair_root/var/lib")" == 755 ]] || {
    printf '/var/lib 没有被启动编排修回 755，实际：%s\n' "$(manager_file_mode "$repair_root/var/lib")" >&2
    fail 'startup did not repair /var/lib'
  }
  [[ "$(manager_file_mode "$repair_root/usr/local/sbin")" == 755 ]] || {
    printf '/usr/local/sbin 没有被启动编排修回 755，实际：%s\n' "$(manager_file_mode "$repair_root/usr/local/sbin")" >&2
    fail 'startup did not repair /usr/local/sbin'
  }
  # 对照一：750 不是那个指纹，必须原样留着。
  [[ "$(manager_file_mode "$repair_root/usr/local/bin")" == 750 ]] || {
    printf '管理员自己设的 750 被覆盖了，实际：%s\n' "$(manager_file_mode "$repair_root/usr/local/bin")" >&2
    fail 'startup repair overwrote a mode it must not touch'
  }
  # 对照二：管理器自己的目录仍然是 700。
  [[ "$(manager_file_mode "$repair_root/var/lib/sb-user-manager")" == 700 ]] || {
    printf '管理器自己的目录被放宽了，实际：%s\n' "$(manager_file_mode "$repair_root/var/lib/sb-user-manager")" >&2
    fail 'startup repair widened the manager own directory'
  }
)

echo 'standalone startup checks passed'
