#!/usr/bin/env bash
# 测试桩会替换生产 systemctl 与锁函数；这些函数只在测试调用链中使用。
# shellcheck disable=SC2317
set -Eeuo pipefail
umask 077

cd "$(dirname "$0")/.."

work="$(mktemp -d)"
runtime_systemd_gate_unit=""
runtime_systemd_target_unit=""
runtime_systemd_nft_unit=""
runtime_systemd_gate_source=""
runtime_systemd_target_source=""
runtime_systemd_nft_source=""
runtime_systemd_root=""
runtime_systemd_registered=false

cleanup_systemd_runtime_fixture() {
  local cleanup_rc=0 unit target expected asset path identity mode
  if [[ "$runtime_systemd_registered" == true ]]; then
    systemctl stop "$runtime_systemd_target_unit" "$runtime_systemd_gate_unit" \
      "$runtime_systemd_nft_unit" \
      >/dev/null 2>&1 || true
    systemctl reset-failed "$runtime_systemd_target_unit" "$runtime_systemd_gate_unit" \
      "$runtime_systemd_nft_unit" \
      >/dev/null 2>&1 || true
    for unit in "$runtime_systemd_target_unit" "$runtime_systemd_gate_unit" \
      "$runtime_systemd_nft_unit"; do
      target="/run/systemd/system/$unit"
      if [[ "$unit" == "$runtime_systemd_target_unit" ]]; then
        expected="$runtime_systemd_target_source"
      elif [[ "$unit" == "$runtime_systemd_gate_unit" ]]; then
        expected="$runtime_systemd_gate_source"
      else
        expected="$runtime_systemd_nft_source"
      fi
      if [[ -L "$target" ]]; then
        cleanup_rc=1
      elif [[ -f "$target" ]]; then
        identity="$(stat -c '%u:%g:%a' -- "$target" 2>/dev/null)" || identity=""
        if [[ -f "$expected" && ! -L "$expected" && "$identity" == 0:0:600 ]] &&
           cmp -s -- "$expected" "$target"; then
          rm -f -- "$target" || cleanup_rc=1
        else
          cleanup_rc=1
        fi
      elif [[ -e "$target" ]]; then
        cleanup_rc=1
      fi
    done
    systemctl daemon-reload >/dev/null 2>&1 || cleanup_rc=1
    if ((cleanup_rc == 0)); then
      runtime_systemd_registered=false
    fi
  fi
  if ((cleanup_rc == 0)) && [[ -n "$runtime_systemd_root" ]]; then
    identity="$(stat -c '%u:%g:%a' -- "$runtime_systemd_root" 2>/dev/null)" || identity=""
    if [[ "$runtime_systemd_root" =~ ^/run/sb-user-manager-test\.[A-Za-z0-9]{10}$ &&
       -d "$runtime_systemd_root" && ! -L "$runtime_systemd_root" &&
       "$identity" == 0:0:700 ]]; then
      for asset in events fail-recovery recovery-gate singbox-marker nftables-marker \
        "$runtime_systemd_gate_unit" "$runtime_systemd_target_unit" \
        "$runtime_systemd_nft_unit"; do
        [[ -n "$asset" && "$asset" != */* ]] || { cleanup_rc=1; break; }
        path="$runtime_systemd_root/$asset"
        if [[ -L "$path" || ( -e "$path" && ! -f "$path" ) ]]; then
          cleanup_rc=1
          break
        fi
        if [[ -f "$path" ]]; then
          identity="$(stat -c '%u:%g' -- "$path" 2>/dev/null)" || identity=""
          mode="$(stat -c '%a' -- "$path" 2>/dev/null)" || mode=""
          if [[ "$identity" != 0:0 || ( "$mode" != 600 && "$mode" != 700 ) ]]; then
            cleanup_rc=1
            break
          fi
          rm -f -- "$path" || { cleanup_rc=1; break; }
        fi
      done
      if ((cleanup_rc == 0)); then
        rmdir -- "$runtime_systemd_root" || cleanup_rc=1
        if [[ ! -e "$runtime_systemd_root" && ! -L "$runtime_systemd_root" ]]; then
          runtime_systemd_root=""
        fi
      fi
    else
      cleanup_rc=1
    fi
  fi
  return "$cleanup_rc"
}

cleanup() {
  local rc=$? cleanup_rc=0
  trap - EXIT
  cleanup_systemd_runtime_fixture || cleanup_rc=1
  rm -rf -- "$work" || cleanup_rc=1
  if ((rc == 0 && cleanup_rc != 0)); then rc="$cleanup_rc"; fi
  exit "$rc"
}
trap cleanup EXIT

export SB_USER_MANAGER_LIBRARY=true
# shellcheck source=../sb-user-manager.sh
source ./sb-user-manager.sh
landing_default_receipt_file="$LANDING_RECEIPT_FILE"

fail() {
  printf 'landing startup gate test failed: %s\n' "$1" >&2
  exit 1
}

for required_function in \
  landing_startup_render_recovery_unit \
  landing_startup_render_singbox_dropin \
  landing_startup_recovery_daemon_reload \
  landing_startup_recovery_ensure_active \
  landing_startup_recovery_unlocked; do
  declare -F "$required_function" >/dev/null ||
    fail "missing callable function: $required_function"
done

for required_value in \
  LANDING_STARTUP_RECOVERY_UNIT_NAME \
  LANDING_STARTUP_RECOVERY_UNIT_PATH \
  LANDING_STARTUP_RECOVERY_DROPIN_DIRECTORY \
  LANDING_STARTUP_RECOVERY_DROPIN_PATH \
  LANDING_STARTUP_RECOVERY_MODE_ARGUMENT; do
  [[ -n "${!required_value:-}" ]] || fail "missing fixed value: $required_value"
done

[[ "$LANDING_STARTUP_RECOVERY_UNIT_NAME" == *.service ]] ||
  fail 'recovery unit name is not a service unit'
[[ "${LANDING_STARTUP_RECOVERY_UNIT_PATH##*/}" == "$LANDING_STARTUP_RECOVERY_UNIT_NAME" ]] ||
  fail 'recovery unit path does not match its fixed unit name'
[[ "$LANDING_STARTUP_RECOVERY_DROPIN_PATH" == "$LANDING_STARTUP_RECOVERY_DROPIN_DIRECTORY/"* ]] ||
  fail 'sing-box drop-in is outside its fixed directory'
[[ "$LANDING_STARTUP_RECOVERY_MODE_ARGUMENT" == --recover-startup ]] ||
  fail 'startup recovery mode is not the fixed internal argument'

unit="$work/$LANDING_STARTUP_RECOVERY_UNIT_NAME"
dropin="$work/${LANDING_STARTUP_RECOVERY_DROPIN_PATH##*/}"
landing_startup_render_recovery_unit "$unit" || fail 'recovery unit rendering failed'
landing_startup_render_singbox_dropin "$dropin" || fail 'sing-box drop-in rendering failed'

[[ -f "$unit" && ! -L "$unit" && -f "$dropin" && ! -L "$dropin" ]] ||
  fail 'rendered systemd artifacts are not regular files'

unit_directive_has_word() {
  local file="$1" section="$2" directive="$3" expected="$4"
  awk -v wanted_section="$section" -v wanted_directive="$directive" -v expected="$expected" '
    /^\[[^]]+\]$/ {
      current = substr($0, 2, length($0) - 2)
      next
    }
    current == wanted_section && index($0, wanted_directive "=") == 1 {
      value = substr($0, length(wanted_directive) + 2)
      count = split(value, words, /[[:space:]]+/)
      for (i = 1; i <= count; i++) {
        if (words[i] == expected) found = 1
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$file"
}

grep -Fxq 'Type=oneshot' "$unit" || fail 'recovery unit is not Type=oneshot'
grep -Fxq 'RemainAfterExit=yes' "$unit" ||
  fail 'recovery gate would be re-entered by an ordinary sing-box restart'
grep -Fxq 'StandardInput=null' "$unit" ||
  fail 'startup recovery unit can inherit or wait for input'
grep -Fxq "ExecStart=${LANDING_AGENT_HELPER_PATH} ${LANDING_STARTUP_RECOVERY_MODE_ARGUMENT}" "$unit" ||
  fail 'recovery unit does not call the fixed root helper in startup mode'
[[ "$(grep -Ec '^ExecStart=' "$unit")" == 1 ]] ||
  fail 'recovery unit must have exactly one ExecStart'

unit_directive_has_word "$dropin" Unit Requires "$LANDING_STARTUP_RECOVERY_UNIT_NAME" ||
  fail 'sing-box does not require the recovery gate'
unit_directive_has_word "$dropin" Unit After "$LANDING_STARTUP_RECOVERY_UNIT_NAME" ||
  fail 'sing-box is not ordered after the recovery gate'
unit_directive_has_word "$unit" Unit Before sing-box.service ||
  fail 'recovery unit is not ordered before sing-box'
unit_directive_has_word "$unit" Unit After nftables.service ||
  fail 'recovery unit lost its ordering edge after optional nftables'
if unit_directive_has_word "$unit" Unit Wants nftables.service ||
   unit_directive_has_word "$unit" Unit Requires nftables.service; then
  fail 'nftables must be ordering-only, not a hard startup dependency'
fi

if grep -Eiq '^[[:space:]]*ConditionPathExists=' "$unit" "$dropin"; then
  fail 'ConditionPathExists can turn a damaged recovery path into a successful skip'
fi

# systemd-analyze also checks the drop-in as part of the effective sing-box unit.
# The production helper is intentionally absent on CI hosts, so only that one
# executable path is replaced in the verification copy after its exact value was
# asserted above.
verify_systemd_units() {
  local verify_root="$work/systemd-verify" verify_log="$work/systemd-verify.log"
  local verify_unit="$verify_root/$LANDING_STARTUP_RECOVERY_UNIT_NAME"
  local verify_dropin_directory="$verify_root/sing-box.service.d"
  if ! command -v systemd-analyze >/dev/null 2>&1; then
    [[ "${SB_REQUIRE_LANDING_STARTUP_SYSTEMD_VERIFY:-false}" != true ]] ||
      fail 'systemd-analyze is required by CI but is unavailable'
    printf 'landing startup gate: systemd-analyze unavailable; verification skipped\n'
    return 0
  fi

  install -d -m 700 -- "$verify_dropin_directory" || return 1
  sed "s|^ExecStart=.*$|ExecStart=/bin/true|" "$unit" > "$verify_unit" || return 1
  cp -- "$dropin" "$verify_dropin_directory/${LANDING_STARTUP_RECOVERY_DROPIN_PATH##*/}" ||
    return 1
  cat > "$verify_root/sing-box.service" <<'EOF' || return 1
[Unit]
Description=sb-user-manager startup-gate verification target

[Service]
Type=oneshot
ExecStart=/bin/true
RemainAfterExit=yes
EOF
  cat > "$verify_root/nftables.service" <<'EOF' || return 1
[Unit]
Description=sb-user-manager startup-gate nftables verification target

[Service]
Type=oneshot
ExecStart=/bin/true
RemainAfterExit=yes
EOF

  if ! SYSTEMD_UNIT_PATH="$verify_root:" \
    systemd-analyze verify --man=no \
      "$verify_unit" "$verify_root/sing-box.service" \
      "$verify_root/nftables.service" >"$verify_log" 2>&1; then
    sed -n '1,160p' "$verify_log" >&2
    fail 'systemd-analyze rejected the recovery unit graph'
  fi
}
verify_systemd_units

# root 门禁执行 sing-box 前必须同时信任可执行文件和固定父目录链。
(
  executable_root="$work/executable-root"
  executable="$executable_root/usr/local/bin/sing-box"
  SB_SYSTEM_ROOT="$executable_root"
  install -d -m 755 -- "$executable_root/usr" "$executable_root/usr/local" \
    "$executable_root/usr/local/bin"
  printf '#!/bin/sh\nexit 0\n' > "$executable"
  chmod 755 "$executable"
  chgrp "$(id -g)" "$executable_root/usr" "$executable_root/usr/local" \
    "$executable_root/usr/local/bin" "$executable"
  landing_startup_root_executable_is_safe "$executable" ||
    fail 'trusted startup executable fixture was rejected'
  chmod 777 "$executable_root/usr/local/bin"
  if landing_startup_root_executable_is_safe "$executable"; then
    fail 'startup executable accepted a writable parent directory'
  fi
  chmod 755 "$executable_root/usr/local/bin"
  if chmod 2755 "$executable" 2>/dev/null; then
    if landing_startup_root_executable_is_safe "$executable"; then
      fail 'startup executable accepted special permission bits'
    fi
  else
    printf 'landing startup gate: special-bit chmod unavailable; assertion skipped\n'
  fi
)

(
  state_root="$work/state-parent-root"
  SB_SYSTEM_ROOT="$state_root"
  install -d -m 755 -- "$state_root/var" "$state_root/var/lib"
  install -d -m 700 -- "$state_root/var/lib/sb-user-manager"
  chgrp "$(id -g)" "$state_root/var" "$state_root/var/lib" \
    "$state_root/var/lib/sb-user-manager"
  landing_channel_state_parent_chain_is_safe || fail 'trusted state parent chain was rejected'
  chmod 777 "$state_root/var/lib"
  if landing_channel_state_parent_chain_is_safe; then
    fail 'state parent chain accepted a writable /var/lib'
  fi
)

(
  lock_root="$work/receipt-lock-root"
  LANDING_RECEIPT_LOCK_FILE="$lock_root/run/lock/sb-user-manager/landing-receipt.lock"
  receipt_lock_private_directory="$(dirname -- "$LANDING_RECEIPT_LOCK_FILE")"
  install -d -m 755 -- "$lock_root/run"
  install -d -m 1777 -- "$lock_root/run/lock"
  chgrp "$(id -g)" "$lock_root/run" "$lock_root/run/lock"
  landing_startup_receipt_lock_parent_chain_is_safe ||
    fail 'trusted sticky receipt-lock parent chain was rejected'
  install -d -m 700 -- "$receipt_lock_private_directory"
  chgrp "$(id -g)" "$receipt_lock_private_directory"
  landing_startup_receipt_lock_parent_chain_is_safe ||
    fail 'trusted receipt-lock private directory was rejected'
  chmod 777 "$lock_root/run"
  if landing_startup_receipt_lock_parent_chain_is_safe; then
    fail 'receipt-lock chain accepted a writable non-sticky /run'
  fi
)

# Ubuntu CI 的 PID 1 是真实 systemd。这里用唯一命名、仅安装到 /run 的合成
# oneshot 单元证明运行期依赖语义，不接触宿主的 sing-box 或项目正式门禁。
verify_systemd_runtime_gate() {
  local requirement="${SB_REQUIRE_LANDING_STARTUP_SYSTEMD_RUNTIME:-false}"
  local runtime_root events failure_flag gate_script target_script nft_script
  local unit_suffix system_state source unit_name
  case "$requirement" in
    false) return 0 ;;
    true) ;;
    *) fail 'SB_REQUIRE_LANDING_STARTUP_SYSTEMD_RUNTIME must be true or false' ;;
  esac

  [[ "$(uname -s)" == Linux ]] ||
    fail 'systemd runtime verification requires Linux'
  [[ "$EUID" -eq 0 ]] ||
    fail 'systemd runtime verification requires root'
  command -v systemctl >/dev/null 2>&1 ||
    fail 'systemd runtime verification requires systemctl'
  [[ "$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]')" == systemd ]] ||
    fail 'systemd runtime verification requires systemd as PID 1'
  system_state="$(systemctl is-system-running 2>/dev/null || true)"
  [[ "$system_state" == running || "$system_state" == degraded ]] ||
    fail "systemd runtime verification found an unusable manager state: $system_state"

  unit_suffix="$$-$RANDOM"
  runtime_systemd_gate_unit="sb-user-manager-test-${unit_suffix}-recovery.service"
  runtime_systemd_target_unit="sb-user-manager-test-${unit_suffix}-singbox.service"
  runtime_systemd_nft_unit="sb-user-manager-test-${unit_suffix}-nftables.service"
  runtime_systemd_root="$(mktemp -d /run/sb-user-manager-test.XXXXXXXXXX)" ||
    fail 'could not create systemd runtime fixture directory'
  runtime_root="$runtime_systemd_root"
  [[ "$runtime_root" =~ ^/run/sb-user-manager-test\.[A-Za-z0-9]{10}$ &&
     -d "$runtime_root" && ! -L "$runtime_root" &&
     "$(stat -c '%u:%g:%a' -- "$runtime_root")" == 0:0:700 ]] ||
    fail 'systemd runtime fixture directory is not root-owned private storage'
  events="$runtime_root/events"
  failure_flag="$runtime_root/fail-recovery"
  gate_script="$runtime_root/recovery-gate"
  target_script="$runtime_root/singbox-marker"
  nft_script="$runtime_root/nftables-marker"
  runtime_systemd_gate_source="$runtime_root/$runtime_systemd_gate_unit"
  runtime_systemd_target_source="$runtime_root/$runtime_systemd_target_unit"
  runtime_systemd_nft_source="$runtime_root/$runtime_systemd_nft_unit"

  [[ ! -e "/run/systemd/system/$runtime_systemd_gate_unit" &&
     ! -L "/run/systemd/system/$runtime_systemd_gate_unit" &&
     ! -e "/run/systemd/system/$runtime_systemd_target_unit" &&
     ! -L "/run/systemd/system/$runtime_systemd_target_unit" &&
     ! -e "/run/systemd/system/$runtime_systemd_nft_unit" &&
     ! -L "/run/systemd/system/$runtime_systemd_nft_unit" ]] ||
    fail 'unique systemd runtime fixture name unexpectedly already exists'
  # 从第一次发布前即交给 EXIT trap 收尾，覆盖部分安装与 reload 失败。
  runtime_systemd_registered=true
  : > "$events" || fail 'could not initialize systemd runtime event log'
  chmod 600 "$events" || fail 'could not protect systemd runtime event log'
  {
    printf '#!/bin/bash\nset -Eeuo pipefail\n'
    printf 'events=%q\n' "$events"
    printf 'failure_flag=%q\n' "$failure_flag"
    cat <<'EOF'
printf 'recovery\n' >> "$events"
if [[ -e "$failure_flag" || -L "$failure_flag" ]]; then
  exit 93
fi
printf 'nft-ready\n' >> "$events"
EOF
  } > "$gate_script" || fail 'could not render synthetic recovery helper'
  {
    printf '#!/bin/bash\nset -Eeuo pipefail\n'
    printf 'events=%q\n' "$events"
    cat <<'EOF'
printf 'singbox-start\n' >> "$events"
EOF
  } > "$target_script" || fail 'could not render synthetic sing-box helper'
  {
    printf '#!/bin/bash\nset -Eeuo pipefail\n'
    printf 'events=%q\n' "$events"
    cat <<'EOF'
printf 'nftables-service-start\n' >> "$events"
EOF
  } > "$nft_script" || fail 'could not render synthetic nftables helper'
  chmod 700 "$gate_script" "$target_script" "$nft_script" ||
    fail 'could not protect synthetic systemd helpers'
  {
    cat <<EOF
[Unit]
Description=sb-user-manager synthetic startup recovery gate
After=$runtime_systemd_nft_unit
Before=$runtime_systemd_target_unit

[Service]
Type=oneshot
ExecStart=$gate_script
RemainAfterExit=yes
EOF
  } > "$runtime_systemd_gate_source" || fail 'could not render synthetic recovery unit'
  {
    cat <<EOF
[Unit]
Description=sb-user-manager synthetic sing-box target
Requires=$runtime_systemd_gate_unit
After=$runtime_systemd_gate_unit

[Service]
Type=oneshot
ExecStart=$target_script
RemainAfterExit=yes
EOF
  } > "$runtime_systemd_target_source" || fail 'could not render synthetic sing-box unit'
  {
    cat <<EOF
[Unit]
Description=sb-user-manager synthetic optional nftables target

[Service]
Type=oneshot
ExecStart=$nft_script
RemainAfterExit=yes
EOF
  } > "$runtime_systemd_nft_source" || fail 'could not render synthetic nftables unit'
  chmod 600 "$runtime_systemd_gate_source" "$runtime_systemd_target_source" \
    "$runtime_systemd_nft_source" ||
    fail 'could not protect synthetic systemd units'
  for source in "$runtime_systemd_gate_source" "$runtime_systemd_target_source" \
    "$runtime_systemd_nft_source"; do
    [[ -f "$source" && ! -L "$source" &&
       "$(stat -c '%u:%g:%a' -- "$source")" == 0:0:600 ]] ||
      fail 'synthetic systemd source is not a root-owned private file'
  done

  install -T -o root -g root -m 600 -- "$runtime_systemd_gate_source" \
    "/run/systemd/system/$runtime_systemd_gate_unit" ||
    fail 'could not install synthetic recovery unit into /run'
  install -T -o root -g root -m 600 -- "$runtime_systemd_target_source" \
    "/run/systemd/system/$runtime_systemd_target_unit" ||
    fail 'could not install synthetic sing-box unit into /run'
  install -T -o root -g root -m 600 -- "$runtime_systemd_nft_source" \
    "/run/systemd/system/$runtime_systemd_nft_unit" ||
    fail 'could not install synthetic nftables unit into /run'
  if ! cmp -s -- "$runtime_systemd_gate_source" "/run/systemd/system/$runtime_systemd_gate_unit" ||
     ! cmp -s -- "$runtime_systemd_target_source" "/run/systemd/system/$runtime_systemd_target_unit" ||
     ! cmp -s -- "$runtime_systemd_nft_source" "/run/systemd/system/$runtime_systemd_nft_unit"; then
    fail 'synthetic systemd runtime units changed during installation'
  fi
  systemctl daemon-reload >/dev/null ||
    fail 'could not load synthetic systemd runtime graph'

  systemctl start "$runtime_systemd_target_unit" >/dev/null ||
    fail 'healthy synthetic startup graph did not start'
  [[ "$(<"$events")" == $'recovery\nnft-ready\nsingbox-start' ]] ||
    fail 'synthetic sing-box started before recovery and nft readiness'
  systemctl is-active --quiet "$runtime_systemd_gate_unit" ||
    fail 'successful synthetic recovery gate did not remain active'
  systemctl is-active --quiet "$runtime_systemd_target_unit" ||
    fail 'successful synthetic sing-box target is not active'
  if systemctl is-active --quiet "$runtime_systemd_nft_unit"; then
    fail 'ordering-only startup edge unexpectedly activated nftables'
  fi
  systemctl restart "$runtime_systemd_target_unit" >/dev/null ||
    fail 'synthetic sing-box target could not restart behind an active gate'
  [[ "$(<"$events")" == $'recovery\nnft-ready\nsingbox-start\nsingbox-start' ]] ||
    fail 'sing-box restart re-entered the recovery gate in one boot cycle'

  systemctl stop "$runtime_systemd_target_unit" "$runtime_systemd_gate_unit" \
    "$runtime_systemd_nft_unit" >/dev/null ||
    fail 'could not reset synthetic systemd units between scenarios'
  for unit_name in "$runtime_systemd_target_unit" "$runtime_systemd_gate_unit" \
    "$runtime_systemd_nft_unit"; do
    if systemctl is-failed --quiet "$unit_name" >/dev/null 2>&1; then
      systemctl reset-failed "$unit_name" >/dev/null ||
        fail 'could not clear a failed synthetic systemd unit between scenarios'
    fi
  done
  : > "$events" || fail 'could not reset systemd runtime event log'
  : > "$failure_flag" || fail 'could not arm synthetic recovery failure'
  chmod 600 "$failure_flag" || fail 'could not protect synthetic failure marker'

  if systemctl start "$runtime_systemd_target_unit" >/dev/null 2>&1; then
    fail 'systemd started the synthetic sing-box target after recovery failed'
  fi
  [[ "$(<"$events")" == recovery ]] ||
    fail 'failed synthetic recovery allowed nft readiness or sing-box ExecStart'
  if systemctl is-active --quiet "$runtime_systemd_target_unit"; then
    fail 'failed synthetic recovery left the sing-box target active'
  fi

  cleanup_systemd_runtime_fixture ||
    fail 'could not remove synthetic systemd runtime fixture'
}
verify_systemd_runtime_gate

# 门禁内部先收敛 journal，再恢复固定 nftables 表；任一步失败都阻断后续阶段。
(
  events="$work/startup-order.events"
  : > "$events"
  landing_startup_singbox_is_stopped() { printf 'sing-box-stopped\n' >> "$events"; }
  landing_startup_recover_pending_transaction() { printf 'recovery\n' >> "$events"; }
  landing_startup_enforce_installed_firewall() { printf 'nft-ready\n' >> "$events"; }
  landing_startup_recovery_unlocked || fail 'healthy cold-start sequence failed'
  [[ "$(<"$events")" == $'sing-box-stopped\nrecovery\nnft-ready\nsing-box-stopped' ]] ||
    fail 'cold-start recovery did not precede nftables readiness'
)

(
  events="$work/startup-failure.events"
  : > "$events"
  landing_startup_singbox_is_stopped() { printf 'sing-box-stopped\n' >> "$events"; }
  landing_startup_recover_pending_transaction() {
    printf 'recovery-failed\n' >> "$events"
    return 89
  }
  landing_startup_enforce_installed_firewall() { printf 'nft-must-not-run\n' >> "$events"; }
  if landing_startup_recovery_unlocked; then
    fail 'cold-start gate swallowed a recovery failure'
  fi
  [[ "$(<"$events")" == $'sing-box-stopped\nrecovery-failed' ]] ||
    fail 'cold-start recovery failure reached nftables or service readiness'
)

# 外层快速校验后若通道恰好完成轮换，shared channel lock 内必须再次校验，
# 且失败时不得进入 receipt 锁或恢复逻辑。
(
  events="$work/channel-lock-revalidation.events"
  validation_count=0
  : > "$events"
  landing_apply_expected_uid() { printf '%s\n' "$EUID"; }
  landing_apply_runtime_paths_are_safe() { return 0; }
  landing_channel_runtime_paths_are_safe() { return 0; }
  landing_startup_recovery_paths_are_safe() { return 0; }
  landing_startup_recovery_gate_files_are_valid() {
    ((validation_count+=1))
    printf 'gate-validation-%s\n' "$validation_count" >> "$events"
    [[ "$validation_count" == 1 ]]
  }
  with_landing_channel_input_lock() {
    local callback="$1"
    shift
    printf 'input-lock\n' >> "$events"
    "$callback" "$@"
  }
  with_landing_channel_shared_lock() {
    local callback="$1"
    shift
    printf 'channel-shared-lock\n' >> "$events"
    "$callback" "$@"
  }
  landing_startup_recovery_with_receipt_lock() {
    printf 'receipt-lock-must-not-run\n' >> "$events"
    return 0
  }
  if landing_startup_recovery_main; then
    fail 'startup recovery accepted gate files changed across the channel lock'
  fi
  [[ "$(<"$events")" == $'gate-validation-1\ninput-lock\nchannel-shared-lock\ngate-validation-2' ]] ||
    fail 'startup recovery did not revalidate gate files inside the channel lock'
)

# 已运行的 v4/外部 sing-box 只在首次启用门禁且 v5 状态严格为空时获准
# 穿过门禁；此例外不执行事务恢复，也不改动 nftables。
(
  events="$work/active-empty.events"
  SB_SYSTEM_ROOT="$work/active-empty-root"
  LANDING_APPLY_TRANSACTION_DIRECTORY="$work/active-empty-transaction"
  LANDING_RECEIPT_FILE="$SB_SYSTEM_ROOT/landing-receipt.json"
  : > "$events"
  landing_startup_singbox_is_stopped() {
    printf 'sing-box-not-stopped\n' >> "$events"
    return 1
  }
  landing_startup_singbox_is_active() { printf 'sing-box-active\n' >> "$events"; }
  landing_startup_managed_state() { printf 'managed-state\n' >> "$events"; printf 'absent\n'; }
  landing_apply_live_nft_is_missing() { printf 'live-nft-missing\n' >> "$events"; }
  landing_startup_recover_pending_transaction() {
    printf 'recovery-must-not-run\n' >> "$events"
    return 1
  }
  landing_startup_enforce_installed_firewall() {
    printf 'firewall-must-not-run\n' >> "$events"
    return 1
  }
  landing_startup_recovery_unlocked ||
    fail 'strictly empty first activation was not allowed for active sing-box'
  [[ "$(<"$events")" == $'sing-box-not-stopped\nsing-box-active\nmanaged-state\nlive-nft-missing' ]] ||
    fail 'active sing-box exception performed recovery or firewall mutation'
)

(
  events="$work/active-managed.events"
  SB_SYSTEM_ROOT="$work/active-managed-root"
  LANDING_APPLY_TRANSACTION_DIRECTORY="$work/active-managed-transaction"
  LANDING_RECEIPT_FILE="$SB_SYSTEM_ROOT/landing-receipt.json"
  : > "$events"
  landing_startup_singbox_is_stopped() { return 1; }
  landing_startup_singbox_is_active() { return 0; }
  landing_startup_managed_state() { printf 'applied\t8.8.8.8\t24443\n'; }
  landing_apply_live_nft_is_missing() { printf 'must-not-check-live-nft\n' >> "$events"; }
  if landing_startup_recovery_unlocked; then
    fail 'active sing-box exception accepted applied v5 state'
  fi
  [[ ! -s "$events" ]] ||
    fail 'active sing-box exception continued after finding applied v5 state'
)

(
  events="$work/active-receipt.events"
  receipt="$work/active-first-activation.receipt"
  SB_SYSTEM_ROOT="$work/active-receipt-root"
  LANDING_APPLY_TRANSACTION_DIRECTORY="$work/active-receipt-transaction"
  LANDING_RECEIPT_FILE="$receipt"
  : > "$events"
  printf '{}\n' > "$receipt"
  chmod 600 "$receipt"
  landing_startup_singbox_is_stopped() { return 1; }
  landing_startup_singbox_is_active() { return 0; }
  landing_startup_managed_state() { printf 'managed-state-must-not-run\n' >> "$events"; printf 'absent\n'; }
  landing_apply_live_nft_is_missing() { printf 'must-not-check-live-nft\n' >> "$events"; }
  if landing_startup_recovery_unlocked; then
    fail 'active sing-box exception accepted an existing v5 receipt'
  fi
  [[ ! -s "$events" ]] ||
    fail 'active sing-box exception continued after finding a v5 receipt'
)

(
  events="$work/active-tls-directory.events"
  strict_root="$work/active-tls-root"
  tls_directory="${strict_root}${LANDING_TLS_DIRECTORY}"
  LANDING_APPLY_TRANSACTION_DIRECTORY="$work/active-tls-transaction"
  LANDING_RECEIPT_FILE="$work/active-tls.receipt"
  SB_SYSTEM_ROOT="$strict_root"
  : > "$events"
  install -d -m 700 -- "$tls_directory"
  landing_startup_singbox_is_stopped() { return 1; }
  landing_startup_singbox_is_active() { return 0; }
  landing_startup_managed_state() { printf 'managed-state-must-not-run\n' >> "$events"; printf 'absent\n'; }
  landing_apply_live_nft_is_missing() { printf 'must-not-check-live-nft\n' >> "$events"; }
  if landing_startup_recovery_unlocked; then
    fail 'active sing-box exception accepted an existing v5 TLS directory'
  fi
  [[ ! -s "$events" ]] ||
    fail 'active sing-box exception continued after finding a v5 TLS directory'
)

(
  events="$work/active-transaction.events"
  SB_SYSTEM_ROOT="$work/active-transaction-root"
  LANDING_APPLY_TRANSACTION_DIRECTORY="$work/active-partial-transaction"
  LANDING_RECEIPT_FILE="$SB_SYSTEM_ROOT/landing-receipt.json"
  : > "$events"
  : > "$LANDING_APPLY_TRANSACTION_DIRECTORY"
  landing_startup_singbox_is_stopped() { return 1; }
  landing_startup_singbox_is_active() { return 0; }
  landing_startup_managed_state() { printf 'must-not-read-managed-state\n' >> "$events"; }
  landing_apply_live_nft_is_missing() { printf 'must-not-check-live-nft\n' >> "$events"; }
  if landing_startup_recovery_unlocked; then
    fail 'active sing-box exception accepted a partial v5 transaction'
  fi
  [[ ! -s "$events" ]] ||
    fail 'active sing-box exception continued after finding a v5 transaction'
)

generation="$(printf '%064d' 0)"

# 普通 apply 必须先让 oneshot gate 进入 active，再取得会保护 stdin 的输入锁。
(
  events="$work/helper-order.events"
  : > "$events"
  SB_USER_MANAGER_LIBRARY=false
  landing_apply_expected_uid() { printf '%s\n' "$EUID"; }
  landing_apply_runtime_paths_are_safe() { return 0; }
  landing_startup_recovery_ensure_active() {
    printf 'startup-gate\n' >> "$events"
  }
  with_landing_channel_input_lock() {
    printf 'input-lock\n' >> "$events"
  }
  landing_apply_helper_main "$generation" >/dev/null ||
    fail 'ordinary helper rejected a successful startup preflight'
  [[ "$(<"$events")" == $'startup-gate\ninput-lock' ]] ||
    fail 'ordinary helper did not run startup recovery before its input lock'
)

# 门禁失败时不能触碰输入锁，也不能消费 stdin；调用方随后仍能读到原始首行。
(
  events="$work/helper-failure.events"
  stdin_file="$work/helper-failure.stdin"
  output="$work/helper-failure.output"
  printf 'package-must-remain-unread\n' > "$stdin_file"
  : > "$events"
  exec 9< "$stdin_file"
  SB_USER_MANAGER_LIBRARY=false
  landing_apply_expected_uid() { printf '%s\n' "$EUID"; }
  landing_apply_runtime_paths_are_safe() { return 0; }
  landing_startup_recovery_ensure_active() {
    printf 'startup-gate\n' >> "$events"
    return 91
  }
  with_landing_channel_input_lock() {
    printf 'input-lock\n' >> "$events"
    return 0
  }
  if landing_apply_helper_main "$generation" <&9 > "$output"; then
    fail 'ordinary helper accepted a failed startup preflight'
  fi
  [[ "$(<"$events")" == startup-gate ]] ||
    fail 'failed startup preflight reached the input lock'
  IFS= read -r remaining <&9 || fail 'failed startup preflight consumed or closed stdin'
  [[ "$remaining" == package-must-remain-unread ]] ||
    fail 'failed startup preflight consumed package input'
  landing_agent_response_is_safe "$(<"$output")" ||
    fail 'failed startup preflight did not emit a bounded error response'
  jq -e '.status == "error"' "$output" >/dev/null ||
    fail 'failed startup preflight did not report an error'
  exec 9<&-
)

# 生产 wrapper 是唯一 daemon-reload seam；失败必须原样传播，供通道事务回滚。
(
  systemctl_events="$work/daemon-reload.events"
  : > "$systemctl_events"
  landing_startup_systemctl() {
    printf '%s\n' "$*" >> "$systemctl_events"
    return 92
  }
  if landing_startup_recovery_daemon_reload; then
    fail 'daemon-reload wrapper swallowed a systemctl failure'
  fi
  [[ "$(<"$systemctl_events")" == daemon-reload ]] ||
    fail 'daemon-reload wrapper used an unexpected systemctl command'
)

# ensure-active 不能只相信 systemctl start 的返回值，还要确认 gate 保持 active。
(
  systemctl_events="$work/ensure-active.events"
  : > "$systemctl_events"
  landing_startup_systemctl() {
    printf '%s\n' "$*" >> "$systemctl_events"
    return 0
  }
  landing_startup_recovery_gate_files_are_valid() { return 0; }
  landing_startup_recovery_ensure_active || fail 'healthy startup gate was rejected'
  [[ "$(<"$systemctl_events")" == $'start '"$LANDING_STARTUP_RECOVERY_UNIT_NAME"$'\nis-active --quiet '"$LANDING_STARTUP_RECOVERY_UNIT_NAME" ]] ||
    fail 'ensure-active did not start and then verify the fixed recovery unit'
)

(
  systemctl_events="$work/ensure-active-failure.events"
  : > "$systemctl_events"
  landing_startup_systemctl() {
    printf '%s\n' "$*" >> "$systemctl_events"
    [[ "${1:-}" != is-active ]]
  }
  landing_startup_recovery_gate_files_are_valid() { return 0; }
  if landing_startup_recovery_ensure_active; then
    fail 'ensure-active accepted a gate that was not active'
  fi
)

# 只要 receipt 存在（包括悬空符号链接），卸载都必须保留通道与恢复门禁。
(
  uninstall_root="$work/uninstall-root"
  receipt_directory=""
  receipt="${uninstall_root}${landing_default_receipt_file}"
  receipt_directory="$(dirname -- "$landing_default_receipt_file")"
  install -d -m 700 -- "$uninstall_root$receipt_directory"
  SB_SYSTEM_ROOT="$uninstall_root"
  landing_channel_runtime_paths_are_safe() { return 0; }
  landing_channel_dependencies_are_ready() { return 0; }
  nft() {
    [[ "$*" == '-nn list tables' ]] || return 1
    return 0
  }
  systemctl_events="$work/uninstall-systemctl.events"
  : > "$systemctl_events"
  landing_startup_systemctl() {
    printf '%s\n' "$*" >> "$systemctl_events"
    if [[ "${1:-}" == is-active ]]; then
      printf 'inactive\n'
      return 3
    fi
    return 0
  }
  with_landing_channel_lock() {
    local callback="$1"
    shift
    "$callback" "$@"
  }

  printf '{}\n' > "$receipt"
  chmod 600 "$receipt"
  if uninstall_landing_restricted_channel; then
    fail 'channel uninstall accepted an existing landing receipt'
  fi
  [[ -f "$receipt" && ! -L "$receipt" ]] ||
    fail 'blocked uninstall changed the landing receipt'
  [[ ! -s "$systemctl_events" ]] ||
    fail 'receipt gate reached startup-gate teardown'

  rm -f -- "$receipt"
  ln -s "$work/missing-receipt-target" "$receipt"
  if uninstall_landing_restricted_channel; then
    fail 'channel uninstall accepted a landing receipt symlink'
  fi
  [[ -L "$receipt" && "$(readlink -- "$receipt")" == "$work/missing-receipt-target" ]] ||
    fail 'blocked uninstall changed the landing receipt symlink'
  [[ ! -s "$systemctl_events" ]] ||
    fail 'receipt symlink gate reached startup-gate teardown'

  rm -f -- "$receipt"
  uninstall_landing_restricted_channel ||
    fail 'empty dormant channel could not pass the receipt gate'
  [[ "$(<"$systemctl_events")" == "is-active $LANDING_STARTUP_RECOVERY_UNIT_NAME" ]] ||
    fail 'empty dormant uninstall did not finalize startup-gate state safely'
)

printf 'landing startup gate checks passed\n'
