#!/usr/bin/env bash
set -Eeuo pipefail

script="${1:-sb-user-manager.sh}"
[[ -f "$script" && ! -L "$script" ]] || {
  echo "managed-step check requires a regular script: $script" >&2
  exit 1
}

work="$(mktemp -d "${TMPDIR:-/tmp}/sb-managed-step-check.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT

# Direct shell-function targets discovered behind run_managed_step and
# run_step_or_rollback. External commands are intentionally excluded.
cat > "$work/expected-direct-functions" <<'EOF'
activate_managed_services
append_inbounds
append_inbounds_from_new_user_snapshot
apply_rule_set_migration
atomic_install_file
begin_environment_transaction
check_singbox_and_restart
complete_environment_change
download_binaries
enable_user_without_transaction
ensure_anytls_certificate
fetch_latest_releases
initialize_deployed_state
install_manager_binary
install_manager_shortcut
kernel_check_config
kernel_check_default_install
nfuse
rebuild_all_split_configs
rebuild_protocol_inbounds
remove_managed_uninstall_paths
remove_split_config
remove_user_inbounds
replace_user_inbounds
run_quietly
state_add_anytls
state_add_multi_user
state_add_split
state_add_user
state_add_user_endpoint
state_move_split
state_remove_split
state_remove_user
state_remove_user_endpoint
state_replace_outbound_preset
state_replace_rule_preset
state_replace_split
state_replace_user
state_set_expiry
state_set_limit
state_set_protocol_sni
state_set_split_status
state_set_status
state_sync_linked_split_snapshots
stop_managed_services_for_uninstall
stop_singbox_for_switch
update_deployed_singbox_version
verify_kernel_switch
verify_managed_uninstall_paths_removed
verify_singbox_cleanup
write_base_config
write_deployed_versions
write_global_sni_config
write_manager_config
write_singbox_channel_state
write_systemd_units
EOF

awk '
  /^[[:alpha:]_][[:alnum:]_]*\(\) \{$/ {
    name=$0
    sub(/\(\) \{$/, "", name)
    print name
  }
' "$script" | LC_ALL=C sort -u > "$work/defined-functions"

awk '
  {
    line=$0
    while (match(line, /run_managed_step[[:space:]]+[[:alpha:]_][[:alnum:]_]*/)) {
      call=substr(line, RSTART, RLENGTH)
      sub(/^run_managed_step[[:space:]]+/, "", call)
      print call
      line=substr(line, RSTART + RLENGTH)
    }
    line=$0
    while (match(line, /run_step_or_rollback[[:space:]]+[^[:space:]]+[[:space:]]+[[:alpha:]_][[:alnum:]_]*/)) {
      call=substr(line, RSTART, RLENGTH)
      sub(/^run_step_or_rollback[[:space:]]+[^[:space:]]+[[:space:]]+/, "", call)
      print call
      line=substr(line, RSTART + RLENGTH)
    }
  }
' "$script" | LC_ALL=C sort -u > "$work/called-targets"

comm -12 "$work/defined-functions" "$work/called-targets" > "$work/actual-direct-functions"
if ! diff -u "$work/expected-direct-functions" "$work/actual-direct-functions"; then
  echo 'managed shell-function targets changed; classify the new or removed target explicitly' >&2
  exit 1
fi

# Direct targets plus mutation-sensitive helpers reached from those targets.
cp "$work/expected-direct-functions" "$work/checked-functions"
cat >> "$work/checked-functions" <<'EOF'
download_kernel_binary
download_manager
download_mihomo_binary
download_singbox_binary
write_expiry_units
write_kernel_unit
write_mihomo_manager_config
write_mihomo_unit
write_nfuse_unit
write_singbox_manager_config
write_singbox_unit
EOF
LC_ALL=C sort -u -o "$work/checked-functions" "$work/checked-functions"

awk '
  FNR == NR {
    checked[$1]=1
    next
  }

  function inspect(statement, line_number, next_statement) {
    if (statement !~ /(^|[[:space:];|&!])(cat|chmod|chown|clear_environment_transaction|cp|curl|download_kernel_binary|download_manager|download_mihomo_binary|download_singbox_binary|github_api_get|github_download_to|gzip|install|ln|mv|register_temp_path|rm|sha256sum|sync_transaction_path|systemctl|tar|write_expiry_units|write_kernel_unit|write_mihomo_manager_config|write_mihomo_unit|write_nfuse_unit|write_singbox_manager_config|write_singbox_unit)([[:space:]]|$)/ &&
        statement !~ /openssl[[:space:]]+enc([[:space:]]|$)/) {
      return
    }
    if (statement ~ /\|\|[^#]*(return|die|true)([[:space:];}]|$)/ ||
        statement ~ /^[[:space:]]*(if|elif|while|until)[[:space:]]/ ||
        statement ~ /^[[:space:]]*!([[:space:]]|$)/ ||
        statement ~ /\|\|[[:space:]]*![^;]+;[[:space:]]*then([[:space:]]|$)/ ||
        statement ~ /#[[:space:]]*managed-step-errexit-ok:/) {
      return
    }
    if (statement ~ /^[[:space:]]*rm[[:space:]]/ &&
        next_statement ~ /^[[:space:]]*(return|die)([[:space:]]|$)/) {
      return
    }
    printf "%s:%d: managed function %s has an unguarded command: %s\n",
      FILENAME, line_number, current_function, statement > "/dev/stderr"
    failed=1
  }

  function flush_statement(    next_statement) {
    if (logical == "") return
    statements[++statement_count]=logical
    statement_lines[statement_count]=logical_start
    logical=""
  }

  function inspect_function(    i, next_statement) {
    if (!checked[current_function]) return
    for (i=1; i<=statement_count; i++) {
      next_statement=(i < statement_count ? statements[i+1] : "")
      inspect(statements[i], statement_lines[i], next_statement)
    }
  }

  /^[[:alpha:]_][[:alnum:]_]*\(\) \{$/ {
    current_function=$0
    sub(/\(\) \{$/, "", current_function)
    statement_count=0
    logical=""
    in_function=1
    next
  }

  in_function && /^}$/ {
    flush_statement()
    inspect_function()
    delete statements
    delete statement_lines
    in_function=0
    current_function=""
    next
  }

  in_function {
    line=$0
    if (logical == "") logical_start=FNR
    if (logical == "") logical=line
    else logical=logical " " line
    if (line ~ /\\[[:space:]]*$/) {
      sub(/\\[[:space:]]*$/, "", logical)
      next
    }
    flush_statement()
  }

  END {exit failed ? 1 : 0}
' "$work/checked-functions" "$script"
