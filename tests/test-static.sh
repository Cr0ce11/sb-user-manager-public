#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")/.."

[[ -x tools/build-manager.sh ]]
[[ -f src/modules.list && ! -L src/modules.list ]]
source_module_count="$(find src -maxdepth 1 -type f -name '[0-9][0-9]-*.sh' | wc -l | tr -d ' ')"
if [[ "$source_module_count" != 10 ]]; then
  printf 'expected 10 source modules, found %s\n' "$source_module_count" >&2
  exit 1
fi
expected_modules='00-bootstrap.sh
10-state-transactions.sh
20-migration-backup.sh
30-user-runtime.sh
40-split-runtime.sh
50-install-update.sh
60-operations-diagnostics.sh
70-split-prompts.sh
79-standalone-startup.sh
80-menus-main.sh'
[[ "$(<src/modules.list)" == "$expected_modules" ]]
if find src tests -maxdepth 1 -type f \
    \( -name '*controller*' -o -name '*landing*' -o -name '*manager-role*' \) | grep -q .; then
  echo 'retired v5 source or dedicated test files remain' >&2
  exit 1
fi
decision_count="$(find docs/DECISIONS -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-*.md' | wc -l | tr -d ' ')"
if [[ "$decision_count" != 6 || -e docs/V5-ENTRY-CONTROLLER-POC.md ]]; then
  echo 'retired v5 ADR or POC documents remain' >&2
  exit 1
fi
bash tools/build-manager.sh --check >/dev/null
bash tests/check-managed-step-errexit.sh sb-user-manager.sh
if grep -REn --include='*.sh' \
  "<<-?[[:space:]]*['\"]?[A-Za-z_][A-Za-z0-9_]*['\"]?[[:space:]]*\\|\\|[[:space:]]*$" \
  src tests tools; then
  echo 'heredoc opener must not end with a dangling ||; wrap the heredoc in a group' >&2
  exit 1
fi

managed_step_fixture="$(mktemp "${TMPDIR:-/tmp}/sb-managed-step-negative.XXXXXX")"
managed_step_output="$(mktemp "${TMPDIR:-/tmp}/sb-managed-step-output.XXXXXX")"
trap 'rm -f -- "$managed_step_fixture" "$managed_step_output"' EXIT
sed '/^download_binaries() {/,/^}$/ {
  /LATEST_SINGBOX_URL/ s/ || return 1//
}' sb-user-manager.sh > "$managed_step_fixture"
if bash tests/check-managed-step-errexit.sh "$managed_step_fixture" >"$managed_step_output" 2>&1; then
  echo 'managed-step check must reject an unguarded download command' >&2
  exit 1
fi
grep -Fq 'managed function download_binaries has an unguarded command' "$managed_step_output"

sed '/^write_systemd_units() {/,/^}$/ {
  /write_singbox_unit || return 1/ s/ || return 1//
}' sb-user-manager.sh > "$managed_step_fixture"
if bash tests/check-managed-step-errexit.sh "$managed_step_fixture" >"$managed_step_output" 2>&1; then
  echo 'managed-step check must reject an unguarded mutation helper' >&2
  exit 1
fi
grep -Fq 'managed function write_systemd_units has an unguarded command' "$managed_step_output"

cp sb-user-manager.sh "$managed_step_fixture"
printf '\nunclassified_managed_step() {\n  :\n}\nmanaged_step_manifest_fixture() {\n  run_managed_step unclassified_managed_step\n}\n' >> "$managed_step_fixture"
if bash tests/check-managed-step-errexit.sh "$managed_step_fixture" >"$managed_step_output" 2>&1; then
  echo 'managed-step check must reject an unclassified managed function' >&2
  exit 1
fi
grep -Fq 'managed shell-function targets changed' "$managed_step_output"

rm -f -- "$managed_step_fixture" "$managed_step_output"
trap - EXIT

version="$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)"/\1/p' sb-user-manager.sh | head -n1)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
grep -Fq "## $version " CHANGELOG.md
grep -Fxq 'SCRIPT_EDITION_LABEL="公开版"' sb-user-manager.sh
grep -Fq 'PORT_MIN=20001' sb-user-manager.sh
grep -Fq 'PORT_MAX=30000' sb-user-manager.sh
grep -Fq 'MANAGER_REPOSITORY="DTB201/sb-user-manager-public"' sb-user-manager.sh
grep -Fq 'SINGBOX_REPOSITORY="SagerNet/sing-box"' sb-user-manager.sh
grep -Fq 'validate_runtime_config_file()' sb-user-manager.sh
grep -Fq 'parse_runtime_config()' sb-user-manager.sh
grep -Fq 'run_standalone_interactive_startup()' sb-user-manager.sh
grep -Fq 'run_standalone_internal_expire()' sb-user-manager.sh
grep -Fq '"") run_standalone_interactive_startup "${@:2}" ;;' sb-user-manager.sh
grep -Fq -- '--internal-expire) run_standalone_internal_expire "${@:2}" ;;' sb-user-manager.sh
grep -Fq -- '--take-over-installed-manager) take_over_installed_manager "${@:2}" ;;' sb-user-manager.sh
grep -Fq 'MIN_SUPPORTED_STATE_SCHEMA_VERSION=0' sb-user-manager.sh
grep -Fq 'recover_manager_handoff || die' sb-user-manager.sh
grep -Fq 'exec "$recovered_installed" "$@"' sb-user-manager.sh
[[ "$(grep -Fc '# >>> manager_channel_handoff' src/50-install-update.sh)" == 1 ]]
[[ "$(grep -Fc '# <<< manager_channel_handoff' src/50-install-update.sh)" == 1 ]]
grep -Fq 'sb-user-manager-landing-agent|sb-user-manager-landing-apply)' sb-user-manager.sh
grep -Fq 'v5 入口与落地能力已经退役，拒绝运行遗留 helper 入口' sb-user-manager.sh
if grep -Eq 'CONTROLLER_STATE_SCHEMA_VERSION|CONTROLLER_ROLE_LAST_STATUS|controller_role_preflight|detect_manager_role|controller_(apply|register|onboard)_landing|LANDING_APPLY_SCHEMA_VERSION|landing_(agent|apply_helper)_main|install_landing_restricted_channel|LANDING_STARTUP_RECOVERY_UNIT_NAME' \
    sb-user-manager.sh src/*.sh; then
  echo 'retired v5 executable implementation remains in the manager' >&2
  exit 1
fi
grep -Fq 'harden_existing_environment_backups()' sb-user-manager.sh
grep -Fq 'if ! harden_existing_environment_backups; then' sb-user-manager.sh
grep -Fq 'migrate_legacy_ss2022_udp_inbounds()' sb-user-manager.sh
grep -Fq 'if ! migrate_legacy_ss2022_udp_inbounds; then' sb-user-manager.sh
grep -Fq 'run_managed_step rebuild_all_split_configs' sb-user-manager.sh
grep -Fq 'make_ss2022_inbound()' sb-user-manager.sh
grep -Fq 'transport:"direct"' sb-user-manager.sh
grep -Fq '"tag": ("ss-udp-" + $name)' sb-user-manager.sh
grep -Fq 'shadow-tls-version=3, udp-relay=true' sb-user-manager.sh
grep -Fq 'shadowrocket_anytls_url()' sb-user-manager.sh
grep -Fq 'shadowrocket_ss2022_url()' sb-user-manager.sh
grep -Fq 'shadowrocket_ss2022_direct_url()' sb-user-manager.sh
grep -Fq 'qrencode -t ANSIUTF8 -l L -m 1 -- "$1"' sb-user-manager.sh
grep -Fq 'apt-get install -y ca-certificates curl jq nftables iproute2 util-linux bsdextrautils tar openssl python3 qrencode' sb-user-manager.sh
if grep -Fq "printf '%s=ss,%s,%s,encrypt-method=%s" sb-user-manager.sh || grep -Fq '%s=anytls,%s,%s,password=%s' sb-user-manager.sh; then
  echo 'legacy Shadowrocket text export must not remain in the manager' >&2
  exit 1
fi
if grep -Fq 'source "$CONF_FILE"' sb-user-manager.sh; then
  echo 'runtime config must be parsed as data instead of sourced as root shell code' >&2
  exit 1
fi
if grep -Eq 'runs-on: ubuntu-latest|uses: actions/checkout@v[0-9]+|container: debian:(12-slim|bookworm-slim)' .github/workflows/ci-release.yml; then
  echo 'release workflow contains a floating runner, action or Debian image reference' >&2
  exit 1
fi
[[ "$(grep -Ec '^[[:space:]]+container: debian:bookworm-[0-9]+-slim@sha256:[0-9a-f]{64}$' .github/workflows/ci-release.yml)" == 2 ]]
grep -Fq 'bash tests/test-release-workflow.sh' .github/workflows/ci-release.yml
grep -Fq 'bash tests/test-manager-handoff.sh' .github/workflows/ci-release.yml
grep -Fq 'bash tests/test-standalone-startup.sh' .github/workflows/ci-release.yml
grep -Fq 'bash tests/test-public-readiness.sh' .github/workflows/ci-release.yml
grep -Fq 'debian-landing-e2e:' .github/workflows/ci-release.yml
if grep -Eq 'tests/test-(controller|landing|manager-role-detection)|SB_LANDING|openssh-server|NET_ADMIN|--privileged' \
    .github/workflows/ci-release.yml; then
  echo 'retired v5 tests or elevated container capabilities remain in CI' >&2
  exit 1
fi
grep -Fq 'fetch_singbox_channel_releases()' sb-user-manager.sh
grep -Fq 'singbox_release_metadata()' sb-user-manager.sh
grep -Fq 'check_singbox_release_compatibility()' sb-user-manager.sh
grep -Fq 'check_rule_set_with_binary()' sb-user-manager.sh
grep -Fq 'prepare_singbox_release_binary()' sb-user-manager.sh
grep -Fq 'perform_singbox_channel_switch()' sb-user-manager.sh
grep -Fq 'write_singbox_channel_state()' sb-user-manager.sh
grep -Fq 'update_current_singbox_channel()' sb-user-manager.sh
grep -Fq 'singbox_channel_menu()' sb-user-manager.sh
grep -Fq 'system_management_menu()' sb-user-manager.sh
grep -Fq 'deployment_management_menu()' sb-user-manager.sh
grep -Fq "deploy '部署与卸载'" sb-user-manager.sh
grep -Fq "uninstall '完整卸载'" sb-user-manager.sh
grep -Fq 'uninstall_environment()' sb-user-manager.sh
grep -Fq 'uninstall_managed_environment()' sb-user-manager.sh
grep -Fq 'managed_uninstall_paths()' sb-user-manager.sh
grep -Fq 'ensure_safe_ssh_for_complete_uninstall()' sb-user-manager.sh
grep -Fq 'cleanup_internal_material_after_uninstall()' sb-user-manager.sh
grep -Fq '完整卸载需要停止 sing-box' sb-user-manager.sh
grep -Fq '加密迁移备份已保留在' sb-user-manager.sh
grep -Fq "channel 'sing-box 版本管理'" sb-user-manager.sh
grep -Fq 'audit_consistency()' sb-user-manager.sh
grep -Fq 'is_public_ipv4()' sb-user-manager.sh
grep -Fq 'https://api.ipify.org' sb-user-manager.sh
grep -Fq 'PUBLIC_SERVER_OVERRIDE=""' sb-user-manager.sh
grep -Fq 'repair_consistency()' sb-user-manager.sh
grep -Fq 'rewrite_singbox_config()' sb-user-manager.sh
grep -Fq 'make_user_inbounds_from_state()' sb-user-manager.sh
grep -Fq 'replace_user_inbounds()' sb-user-manager.sh
grep -Fq 'state_replace_user()' sb-user-manager.sh
grep -Fq 'cmd_edit_user()' sb-user-manager.sh
grep -Fq 'prompt_edit_user()' sb-user-manager.sh
grep -Fq 'ensure_global_sni_config()' sb-user-manager.sh
grep -Fq 'cmd_set_global_sni()' sb-user-manager.sh
grep -Fq 'global_sni_menu()' sb-user-manager.sh
grep -Fq 'validate_remote_rule_set()' sb-user-manager.sh
grep -Fq 'rebuild_all_split_configs()' sb-user-manager.sh
grep -Fq 'build_split_runtime_plan()' sb-user-manager.sh
grep -Fq 'stable_managed_tag()' sb-user-manager.sh
grep -Fq 'validate_split_relationships()' sb-user-manager.sh
grep -Fq 'migrate_shared_preset_runtime_configs()' sb-user-manager.sh
grep -Fq 'if ! cmd_split_add "$name" "$url" "$scope" "$user" "$upstream" "$outbound_tag" "$rule_preset" "$outbound_preset"; then' sb-user-manager.sh
grep -Fq '分流没有添加，现有配置没有改变。' sb-user-manager.sh
grep -Fq 'SHARED_PRESET_RUNTIME_MARKER=' sb-user-manager.sh
grep -Fq '同一用户不能让同一条预置规则同时使用两个不同出口' sb-user-manager.sh
if grep -Fq '本分流的出口名称' sb-user-manager.sh; then
  echo 'per-split outbound name prompt must not return after shared preset runtime reuse' >&2
  exit 1
fi
grep -Fq 'cmd_split_show()' sb-user-manager.sh
grep -Fq 'cmd_split_edit()' sb-user-manager.sh
grep -Fq 'cmd_split_move()' sb-user-manager.sh
grep -Fq 'prompt_edit_split()' sb-user-manager.sh
grep -Fq 'prompt_move_split()' sb-user-manager.sh
grep -Fq 'prompt_split_diagnostic()' sb-user-manager.sh
grep -Fq 'cmd_outbound_preset_edit()' sb-user-manager.sh
grep -Fq 'cmd_rule_preset_edit()' sb-user-manager.sh
grep -Fq 'outbound_preset_management_menu()' sb-user-manager.sh
grep -Fq 'rule_preset_management_menu()' sb-user-manager.sh
grep -Fq 'state_remove_outbound_preset()' sb-user-manager.sh
grep -Fq 'state_remove_rule_preset()' sb-user-manager.sh
grep -Fq "ui_section '预置内容（保存后不会自动生效）'" sb-user-manager.sh
grep -Fq 'extract_split_diagnostic_connections()' sb-user-manager.sh
grep -Fq "diagnose '验证分流是否生效'" sb-user-manager.sh
grep -Fq 'create_diagnostic_report()' sb-user-manager.sh
grep -Fq 'redact_diagnostic_file()' sb-user-manager.sh
grep -Fq 'validate_diagnostic_report()' sb-user-manager.sh
grep -Fq 'diagnostic_report_menu()' sb-user-manager.sh
grep -Fq "diagnostics '检查与故障报告'" sb-user-manager.sh
grep -Fq '生成故障诊断报告（只读）' sb-user-manager.sh
grep -Fq '/root/sb-user-manager-diagnostics' sb-user-manager.sh
grep -Fq 'DEFAULT_SS2022_SHADOWTLS_SNI="publicassets.cdn-apple.com"' sb-user-manager.sh
grep -Fq 'DEFAULT_ANYTLS_SNI="weKbP9SVYU.download.windowsupdate.com"' sb-user-manager.sh
if grep -Fq 'ShadowTLS SNI（留空使用全局默认 ${SS2022_SHADOWTLS_SNI}；输入 0 返回协议选择）' sb-user-manager.sh; then
  echo 'new SS2022 users must not be prompted for a ShadowTLS SNI' >&2
  exit 1
fi
grep -Fq 'AnyTLS SNI（留空使用全局默认 ${ANYTLS_SNI}；输入 0 返回协议选择）' sb-user-manager.sh
grep -Fq '请选择使用方式 [1]：' sb-user-manager.sh
grep -Fq 'prompt_managed "$protocol" "$method" "$protocol_sni"' sb-user-manager.sh
grep -Fq 'prompt_multi_account managed' sb-user-manager.sh
grep -Fq 'cmd_add_user_endpoint()' sb-user-manager.sh
grep -Fq 'cmd_remove_user_endpoint()' sb-user-manager.sh
grep -Fq 'read_menu_choice()' sb-user-manager.sh
grep -Fq 'read_numbered_index()' sb-user-manager.sh
grep -Fq 'create_migration_backup()' sb-user-manager.sh
grep -Fq '设置迁移密码（至少 8 位；输入 0 取消）' sb-user-manager.sh
grep -Fq 'if ! read_backup_password_twice; then' sb-user-manager.sh
grep -Fq 'restore_migration_backup()' sb-user-manager.sh
grep -Fq 'build_merge_migration_payload()' sb-user-manager.sh
grep -Fq 'select_migration_restore_mode()' sb-user-manager.sh
grep -Fq '合并到这台服务器（推荐；保留已有用户和分流）' sb-user-manager.sh
grep -Fq '确认继续？请输入 ${confirm_token}：' sb-user-manager.sh
grep -Fq 'import_migration_backup()' sb-user-manager.sh
grep -Fq 'preview_migration_backup()' sb-user-manager.sh
grep -Fq 'validate_migration_bundle()' sb-user-manager.sh
grep -Fq 'cleanup_backup_retention()' sb-user-manager.sh
grep -Fq 'write_migration_restore_report()' sb-user-manager.sh
grep -Fq 'verify_migration_auth_file()' sb-user-manager.sh
grep -Fq 'verify_environment_backup()' sb-user-manager.sh
grep -Fq 'restore_environment_backup()' sb-user-manager.sh
grep -Fq 'install_runtime_traps()' sb-user-manager.sh
grep -Fq "handle_runtime_signal HUP 129" sb-user-manager.sh
grep -Fq "handle_runtime_signal QUIT 131" sb-user-manager.sh
grep -Fxq '# >>> check_updates' sb-user-manager.sh
grep -Fxq '# <<< check_updates' sb-user-manager.sh
grep -Fq 'restore_state_backup_atomically()' sb-user-manager.sh
grep -Fq 'validate_public_rule_set_url()' sb-user-manager.sh
grep -Fq "curl --proto '=https' --proto-redir '=https'" sb-user-manager.sh
grep -Fq -- '--max-redirs 0' sb-user-manager.sh
grep -Fq -- '--connect-timeout 10 --max-time 30' sb-user-manager.sh
grep -Fq -- '--connect-timeout 10 --max-time 300' sb-user-manager.sh
grep -Fq 'apt-get update || return 1' sb-user-manager.sh
grep -Fq 'apt-get install -y ca-certificates curl jq nftables iproute2 util-linux bsdextrautils tar openssl python3 qrencode || return 1' sb-user-manager.sh
grep -Fq 'openssl enc -aes-256-cbc -md sha256 -pbkdf2' sb-user-manager.sh
grep -Fq 'echo '\''用户列表暂时无法格式化，敏感字段已隐藏。'\''' sb-user-manager.sh
grep -Fq 'prepare_menu_screen()' sb-user-manager.sh
grep -Fq 'handoff_to_newer_installed_manager()' sb-user-manager.sh
grep -Fq 'ssh_connection_uses_local_singbox()' sb-user-manager.sh
grep -Fq 'ensure_safe_ssh_for_singbox_restart()' sb-user-manager.sh
grep -Fq 'ss -Htnp state established' sb-user-manager.sh
grep -Fq 'ensure_safe_ssh_for_singbox_restart || return 0' sb-user-manager.sh
grep -A3 -F 'prompt_add_node()' sb-user-manager.sh | grep -Fq 'ensure_safe_ssh_for_singbox_restart || return 0'
grep -Fq 'sync_manager_launch_copy()' sb-user-manager.sh
grep -Fq 'initialize_deployed_state()' sb-user-manager.sh
grep -Fq 'deployed_state_path()' sb-user-manager.sh
grep -Fq 'cleanup_deploy_created_paths()' sb-user-manager.sh
grep -Fq 'wait_for_nfuse_ready()' sb-user-manager.sh
grep -Fq 'default_network_interface()' sb-user-manager.sh
grep -Fq 'ensure_anytls_certificate()' sb-user-manager.sh
grep -Fq 'install_manager_binary()' sb-user-manager.sh
grep -Fq 'validate_manager_shortcut_path()' sb-user-manager.sh
grep -Fq 'install_manager_shortcut()' sb-user-manager.sh
grep -Fq 'ensure_manager_shortcut_for_interactive_startup()' sb-user-manager.sh
grep -Fq "target='/usr/local/sbin/sb-user-manager'" sb-user-manager.sh
grep -Fq 'shortcut="$(system_path /usr/local/bin/sbm)"' sb-user-manager.sh
grep -Fq 'run_step_or_rollback rollback_deploy install_manager_shortcut' sb-user-manager.sh
grep -Fq 'run_step_or_rollback rollback_takeover install_manager_shortcut' sb-user-manager.sh
grep -Fq '/usr/local/bin/sbm|/usr/local/bin/sing-box' sb-user-manager.sh
[[ "$(grep -Fc 'ensure_manager_shortcut_for_interactive_startup' sb-user-manager.sh)" == 2 ]]
grep -Fq 'write_deployed_versions()' sb-user-manager.sh
grep -Fq 'activate_managed_services()' sb-user-manager.sh
grep -Fq 'restore_failed_environment_change()' sb-user-manager.sh
grep -Fq 'complete_environment_change()' sb-user-manager.sh
for shared_helper in default_network_interface ensure_anytls_certificate install_manager_binary \
  write_deployed_versions activate_managed_services restore_failed_environment_change complete_environment_change; do
  shared_helper_calls="$(awk -v helper="$shared_helper" 'index($0, helper) && !index($0, helper "()") {count++} END {print count+0}' sb-user-manager.sh)"
  expected_calls=2
  [[ "$shared_helper" == restore_failed_environment_change || "$shared_helper" == complete_environment_change ]] && expected_calls=3
  if [[ "$shared_helper_calls" != "$expected_calls" ]]; then
    echo "expected shared $shared_helper to have $expected_calls callers, found $shared_helper_calls" >&2
    exit 1
  fi
done
[[ "$(grep -Fc 'openssl req -x509 -newkey rsa:2048' sb-user-manager.sh)" == 1 ]]
[[ "$(grep -Fc 'systemctl enable nfuse sing-box sb-user-expiry.timer' sb-user-manager.sh)" == 1 ]]
grep -Fq 'begin_operation_transaction()' sb-user-manager.sh
grep -Fq 'recover_pending_transaction()' sb-user-manager.sh
grep -Fq 'restore_nfuse_snapshot()' sb-user-manager.sh
grep -Fq 'run_step_or_rollback()' sb-user-manager.sh
grep -Fq 'run_managed_step()' sb-user-manager.sh
grep -Fq 'begin_environment_transaction()' sb-user-manager.sh
grep -Fq 'recover_environment_transaction()' sb-user-manager.sh
grep -Fq 'migrate_backup_retention_once()' sb-user-manager.sh
[[ "$(grep -Fc 'migrate_backup_retention_once' sb-user-manager.sh)" == 2 ]]
grep -Fq 'SB_BACKUP_RETENTION_MIGRATION_MARKER' sb-user-manager.sh
grep -Fq 'prompt_user_status_action()' sb-user-manager.sh
grep -Fq 'config_path="$(system_path /etc/sing-box/config.json)"' sb-user-manager.sh
grep -Fq 'deploy_environment false "$update_manager" || return 1' sb-user-manager.sh
if grep -Fq 'prompt_name_action' sb-user-manager.sh; then
  echo 'legacy free-form enable/disable user prompt should not remain' >&2
  exit 1
fi
wait_ready_call_count="$(grep -Ec '^[[:space:]]+.*wait_for_nfuse_ready' sb-user-manager.sh || true)"
[[ "$wait_ready_call_count" == 2 ]]
managed_operation_start_count="$(grep -Ec '^[[:space:]]+.*start_managed_operation ' sb-user-manager.sh || true)"
managed_operation_finish_count="$(grep -Ec '^[[:space:]]+.*finish_managed_operation' sb-user-manager.sh || true)"
split_operation_finish_count="$(grep -Ec '^[[:space:]]+.*rebuild_and_finish_split_operation' sb-user-manager.sh || true)"
# finish_managed_operation 在分流收尾函数内部出现一次；该实现行本身不是新的事务入口。
managed_operation_finish_coverage=$((managed_operation_finish_count - 1 + split_operation_finish_count))
if [[ "$managed_operation_start_count" != 26 || "$split_operation_finish_count" != 9 ||
      "$managed_operation_finish_coverage" != "$managed_operation_start_count" ]]; then
  echo "managed operations must keep one finish path each: starts=$managed_operation_start_count direct_finishes=$managed_operation_finish_count split_finishes=$split_operation_finish_count coverage=$managed_operation_finish_coverage" >&2
  exit 1
fi
managed_step_count="$(grep -Ec '^[[:space:]]+run_managed_step ' sb-user-manager.sh || true)"
if ((managed_step_count < 50)); then
  echo "expected managed operations to use the shared step runner, found $managed_step_count calls" >&2
  exit 1
fi
deploy_step_count="$(grep -Ec '^[[:space:]]+run_step_or_rollback rollback_deploy ' sb-user-manager.sh || true)"
takeover_step_count="$(grep -Ec '^[[:space:]]+run_step_or_rollback rollback_takeover ' sb-user-manager.sh || true)"
if ((deploy_step_count < 10 || takeover_step_count < 15)); then
  echo "environment flows must explicitly wrap failure-prone steps: deploy=$deploy_step_count takeover=$takeover_step_count" >&2
  exit 1
fi
if grep -Fq 'repair_consistency_step' sb-user-manager.sh; then
  echo 'legacy consistency-only transaction step wrapper should not remain' >&2
  exit 1
fi
grep -Fq 'run_step_or_rollback rollback_deploy initialize_deployed_state "$fresh"' sb-user-manager.sh
deploy_config_line="$(grep -nF 'run_step_or_rollback rollback_deploy write_base_config' sb-user-manager.sh | cut -d: -f1)"
deploy_state_line="$(grep -nF 'run_step_or_rollback rollback_deploy initialize_deployed_state' sb-user-manager.sh | cut -d: -f1)"
[[ "$deploy_config_line" =~ ^[0-9]+$ && "$deploy_state_line" =~ ^[0-9]+$ ]]
((deploy_state_line > deploy_config_line))
grep -Fq 'deployed_state_file="$(trap - ERR; deployed_state_path)"' sb-user-manager.sh
grep -Fq 'cleanup_deploy_created_paths "${deploy_created[@]}"' sb-user-manager.sh
if grep -Fq -- '--arg label' sb-user-manager.sh; then
  echo 'jq 1.6 reserves label; use a non-reserved jq variable name' >&2
  exit 1
fi
grep -Fq 'SB_ACCEPTANCE_CONFIRM=YES' tests/acceptance.sh
grep -Fq "fail '空机迁移保护'" tests/acceptance.sh
if grep -Eq '^[[:space:]]*exec[[:space:]].*2>/dev/null' sb-user-manager.sh; then
  echo 'unsafe persistent exec stderr redirection detected' >&2
  exit 1
fi
if grep -Eq 'if[[:space:]]+run_lifecycle|run_mutation .*\|\|[[:space:]]+return' tests/acceptance.sh; then
  echo 'acceptance lifecycle must not run mutations inside an errexit-suppressed condition' >&2
  exit 1
fi
grep -Fq "trap 'handle_runtime_signal INT 130' INT" sb-user-manager.sh
grep -Fq "trap 'handle_runtime_signal TERM 143' TERM" sb-user-manager.sh
signal_rollback_count="$(grep -Ec '^[[:space:]]+set_signal_rollback rollback_' sb-user-manager.sh || true)"
clear_rollback_count="$(grep -Ec '^[[:space:]]+clear_signal_rollback$' sb-user-manager.sh || true)"
if [[ "$signal_rollback_count" != 7 ]]; then
  echo "expected 7 signal rollback registrations, found $signal_rollback_count" >&2
  exit 1
fi
if [[ "$clear_rollback_count" != 12 ]]; then
  echo "expected 12 signal rollback clears, found $clear_rollback_count" >&2
  exit 1
fi
grep -Fq 'set_signal_rollback rollback_manager_handoff' sb-user-manager.sh
grep -Fq 'MIGRATION_FORMAT_VERSION=1' sb-user-manager.sh
grep -Fq 'MIGRATION_BUNDLE_VERSION=1' sb-user-manager.sh
if perl -ne '$found=1 if /\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7f]/; END { exit($found ? 0 : 1) }' sb-user-manager.sh; then
  echo 'shell variable directly followed by non-ASCII text; use ${name} to avoid locale-dependent parsing' >&2
  exit 1
fi

echo "static checks passed for $version"
