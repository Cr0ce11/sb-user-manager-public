#!/usr/bin/env bash
# 路由测试会替换已加载函数，只验证启动编排，不执行真实安装或服务操作。
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail

cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

export SB_USER_MANAGER_LIBRARY=true
export SB_CONTROLLER_STATE_FILE="$work/controller-state.json"
export SB_CONTROLLER_SECRET_DIR="$work/controller-secrets"
export SB_CONTROLLER_STATE_LOCK_FILE="$work/controller-state.lock"
export SB_ENVIRONMENT_TRANSACTION_JOURNAL="$work/environment-recovery.json"

# shellcheck source=../sb-user-manager.sh
source ./sb-user-manager.sh

fail() {
  printf 'manager role routing test failed: %s\n' "$1" >&2
  exit 1
}

# 所有新启动公开入口固定拒绝额外参数，避免未来调用方意外扩权。
for zero_arg_entry in \
  detect_manager_role_with_legacy_recovery confirm_and_provision_entry_controller \
  undeployed_role_selection_menu run_standalone_interactive_startup \
  dispatch_interactive_startup run_standalone_internal_expire; do
  set +e
  "$zero_arg_entry" unexpected >/dev/null 2>&1
  rc=$?
  set -e
  [[ "$rc" == 64 ]] || fail "$zero_arg_entry accepted an unexpected argument"
done

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

# 四种已识别角色只能进入各自入口；失败结果不得回落到任一菜单。
for role in undeployed standalone entry-controller landing; do
  reset_calls
  TEST_DETECTED_ROLE="$role"
  detect_manager_role() {
    record_call detect
    MANAGER_ROLE="$TEST_DETECTED_ROLE"
    MANAGER_ROLE_DETECTION_STATUS=role_detected
    MANAGER_ROLE_DETECTION_DETAIL=""
  }
  undeployed_role_selection_menu() { record_call undeployed; }
  run_standalone_interactive_startup() { record_call standalone; }
  entry_controller_main() { record_call entry-controller; }
  landing_managed_main() { record_call landing; }
  dispatch_interactive_startup || fail "dispatch rejected $role"
  assert_log $'detect\n'"$role"
done

reset_calls
detect_manager_role() {
  record_call detect
  MANAGER_ROLE=unknown
  MANAGER_ROLE_DETECTION_STATUS=role_conflict
  MANAGER_ROLE_DETECTION_DETAIL=mixed_role_markers
  return 1
}
if dispatch_interactive_startup > "$work/unknown-output"; then
  fail 'unknown role entered a menu'
fi
assert_log detect
grep -Fq '检测到互相冲突的管理角色标记' "$work/unknown-output"
if grep -Fq '/var/' "$work/unknown-output"; then fail 'failure output exposed a path'; fi

# 未部署页面在选择或 EOF 前不调用任何安装；入口安装必须二次确认。
# 恢复刚才为分发矩阵替换的真实菜单函数。
source ./sb-user-manager.sh
prepare_menu_screen() { return 0; }
install_environment() { record_call install-standalone; }
provision_entry_controller_role() {
  record_call provision-entry
  CONTROLLER_ROLE_LAST_STATUS=entry_role_initialized
}

reset_calls
undeployed_role_selection_menu <<< '0' > "$work/undeployed-cancel"
assert_log ''
grep -Fq '安装为单机节点' "$work/undeployed-cancel"
grep -Fq '安装为入口控制器' "$work/undeployed-cancel"

reset_calls
undeployed_role_selection_menu </dev/null > "$work/undeployed-eof"
assert_log ''

reset_calls
undeployed_role_selection_menu <<< $'2\nn\n0' > "$work/entry-cancel"
assert_log ''
grep -Fq '已取消入口控制器安装' "$work/entry-cancel"

reset_calls
set +e
undeployed_role_selection_menu <<< $'1\n'
rc=$?
set -e
[[ "$rc" == 10 ]] || fail 'standalone install did not request redispatch'
assert_log install-standalone

reset_calls
set +e
undeployed_role_selection_menu <<< $'2\ny\n'
rc=$?
set -e
[[ "$rc" == 10 ]] || fail 'entry install did not request redispatch'
assert_log provision-entry

# 安装失败必须保留在未部署页面并显示稳定原因，随后仍可退出。
provision_entry_controller_role() {
  record_call provision-entry-failed
  CONTROLLER_ROLE_LAST_STATUS=dependency_repair_failed
  CONTROLLER_ROLE_LAST_DETAIL=apt_update
  return 1
}
reset_calls
undeployed_role_selection_menu <<< $'2\ny\n0' > "$work/entry-failed"
assert_log provision-entry-failed
grep -Fq '系统依赖修复失败' "$work/entry-failed"
grep -Fq '软件源更新' "$work/entry-failed"

# standalone 继续使用原启动顺序，角色恢复后必须重新识别。
recover_environment_transaction() { record_call recover-environment; }
detect_manager_role() {
  record_call detect
  MANAGER_ROLE=standalone
  MANAGER_ROLE_DETECTION_STATUS=role_detected
  MANAGER_ROLE_DETECTION_DETAIL=""
}
harden_existing_environment_backups() { record_call harden-backups; }
ensure_manager_launch_copies_for_interactive_startup() { record_call sync-launch-copy; }
ensure_manager_shortcut_for_interactive_startup() { record_call sync-shortcut; }
recover_transaction_before_menu() { record_call recover-state; }
migrate_backup_retention_once() { record_call migrate-backup-retention; }
migrate_legacy_ss2022_udp_inbounds() { record_call migrate-udp; }
migrate_shared_preset_runtime_configs() { record_call migrate-presets; }
interactive_main() { record_call standalone-menu; }

reset_calls
run_standalone_interactive_startup || fail 'standalone startup failed'
assert_log $'recover-environment\ndetect\nharden-backups\nsync-launch-copy\nsync-shortcut\nrecover-state\nmigrate-backup-retention\nmigrate-udp\nmigrate-presets\nstandalone-menu'

# 只有 standalone 可执行内部到期任务；入口与落地不碰 v4 恢复或用户状态。
prepare_core() { record_call prepare-core; }
cmd_expire() { record_call expire; }
reset_calls
run_standalone_internal_expire || fail 'standalone expiry failed'
assert_log $'detect\nrecover-environment\ndetect\nprepare-core\nexpire'

detect_manager_role() {
  record_call detect
  MANAGER_ROLE='entry-controller'
  MANAGER_ROLE_DETECTION_STATUS=role_detected
  MANAGER_ROLE_DETECTION_DETAIL=""
}
reset_calls
if run_standalone_internal_expire > "$work/non-standalone-expire"; then
  fail 'entry controller ran standalone expiry'
fi
assert_log detect
grep -Fq '当前角色不执行单机到期任务' "$work/non-standalone-expire"

# 旧 v4 环境恢复日志只允许在 standalone/undeployed/standalone 部分部署中恢复。
: > "$ENVIRONMENT_TRANSACTION_JOURNAL"
TEST_DETECT_COUNT=0
detect_manager_role() {
  record_call detect
  ((TEST_DETECT_COUNT+=1))
  if ((TEST_DETECT_COUNT == 1)); then
    MANAGER_ROLE=undeployed
  else
    MANAGER_ROLE=standalone
  fi
  MANAGER_ROLE_DETECTION_STATUS=role_detected
  MANAGER_ROLE_DETECTION_DETAIL=""
}
recover_environment_transaction() {
  record_call recover-environment
  rm -f -- "$ENVIRONMENT_TRANSACTION_JOURNAL"
}
run_standalone_interactive_startup() { record_call standalone; }
reset_calls
dispatch_interactive_startup || fail 'recoverable old environment did not redispatch'
assert_log $'detect\nrecover-environment\ndetect\nstandalone'

: > "$ENVIRONMENT_TRANSACTION_JOURNAL"
detect_manager_role() {
  record_call detect
  MANAGER_ROLE=landing
  MANAGER_ROLE_DETECTION_STATUS=role_detected
  MANAGER_ROLE_DETECTION_DETAIL=""
}
landing_managed_main() { record_call landing; }
reset_calls
if dispatch_interactive_startup > "$work/landing-conflict"; then
  fail 'landing ignored a v4 recovery journal'
fi
assert_log detect
grep -Fq '存在不属于当前角色的旧版恢复标记' "$work/landing-conflict"
rm -f -- "$ENVIRONMENT_TRANSACTION_JOURNAL"

# 角色菜单保持隔离：入口只显示四板块，落地只显示只读/未来恢复骨架。
# 恢复前面为调用顺序测试替换的真实角色菜单。
source ./sb-user-manager.sh
prepare_menu_screen() { return 0; }
if ! command -v flock >/dev/null 2>&1; then flock() { return 0; }; fi
init_controller_state || fail 'could not create entry summary fixture'
cp "$CONTROLLER_STATE_FILE" "$work/controller-state.snapshot"
reset_calls
entry_controller_main <<< '0' > "$work/entry-menu"
cmp -s "$CONTROLLER_STATE_FILE" "$work/controller-state.snapshot"
grep -Fq '入口机管理' "$work/entry-menu"
grep -Fq '落地机管理' "$work/entry-menu"
grep -Fq '数据备份与恢复' "$work/entry-menu"
grep -Fq '系统管理' "$work/entry-menu"
grep -Fq '入口状态：就绪' "$work/entry-menu"
grep -Fq '正常落地：0/0' "$work/entry-menu"
if grep -Fq '添加用户' "$work/entry-menu"; then fail 'entry menu exposed standalone action'; fi

SB_SYSTEM_ROOT="$work/landing-root"
export SB_SYSTEM_ROOT
landing_managed_main <<< '0' > "$work/landing-menu"
grep -Fq '本机由入口控制器管理' "$work/landing-menu"
grep -Fq '查看只读状态' "$work/landing-menu"
grep -Fq '紧急恢复上一个版本（尚未开放）' "$work/landing-menu"
if grep -Fq '分流管理' "$work/landing-menu"; then fail 'landing menu exposed standalone action'; fi

# 静态边界：路由层不得直接运行 APT、创建控制器状态或远程 SSH。
route_functions="$(
  declare -f dispatch_interactive_startup undeployed_role_selection_menu \
    confirm_and_provision_entry_controller run_standalone_interactive_startup \
    entry_controller_main landing_managed_main
)"
if grep -Eq '(^|[[:space:]])(apt-get|init_controller_state|ssh)([[:space:]]|$)' <<< "$route_functions"; then
  fail 'routing layer bypassed a lower-level gate'
fi
grep -Fq 'provision_entry_controller_role' <<< "$route_functions"
grep -Fq 'detect_manager_role' <<< "$route_functions"

echo 'manager role routing checks passed'
