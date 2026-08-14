
migration_backup_dir() {
  printf '%s' "${MIGRATION_BACKUP_DIR:-/root/sb-user-manager-backups/data}"
}

CREATED_MIGRATION_BACKUP=""
MIGRATION_MATERIALIZE_FAILURE=""
MIGRATION_INSPECTION_RESULT=""
MIGRATION_IMPORT_CANDIDATES=()
MIGRATION_IMPORT_SOURCE=""

ensure_migration_crypto_dependencies() {
  local dependency
  local -a missing=()
  for dependency in jq openssl python3 sha256sum; do
    command -v "$dependency" >/dev/null 2>&1 || missing+=("$dependency")
  done
  ((${#missing[@]} == 0)) && return 0
  printf '错误：迁移备份功能缺少运行依赖：%s\n' "${missing[*]}"
  echo '请返回「系统管理」→「部署与卸载」→「安装或修复环境」完成修复后重试。'
  return 1
}

read_backup_password_twice() {
  local first second
  while true; do
    read -r -s -p '设置迁移密码（至少 8 位；输入 0 取消）：' first; echo
    [[ "$first" != 0 ]] || { BACKUP_PASSWORD=""; return 1; }
    if [[ -z "$first" ]]; then
      echo '密码不能为空，请重新输入。'
      continue
    fi
    if ((${#first} < 8)); then
      echo '密码至少需要 8 个字符，请重新输入。'
      continue
    fi
    read -r -s -p '再次输入密码（输入 0 取消）：' second; echo
    [[ "$second" != 0 ]] || { BACKUP_PASSWORD=""; return 1; }
    if [[ "$first" != "$second" ]]; then
      echo '两次输入的密码不一致，请重新设置。'
      continue
    fi
    BACKUP_PASSWORD="$first"
    return 0
  done
}

read_backup_password() {
  while true; do
    read -r -s -p '迁移包密码（输入 0 取消）：' BACKUP_PASSWORD; echo
    [[ "$BACKUP_PASSWORD" != 0 ]] || { BACKUP_PASSWORD=""; return 1; }
    [[ -n "$BACKUP_PASSWORD" ]] && return 0
    echo '密码不能为空，请重新输入。'
  done
}

validate_migration_checksum() {
  local encrypted="$1" expected actual
  [[ -f "$encrypted.sha256" ]] || return 1
  expected="$(awk 'NR==1 {print $1}' "$encrypted.sha256")"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  actual="$(sha256sum "$encrypted" | awk '{print $1}' | tr 'A-F' 'a-f')"
  expected="$(printf '%s' "$expected" | tr 'A-F' 'a-f')"
  [[ "$actual" == "$expected" ]]
}

derive_migration_auth_key() {
  local password="$1" salt="$2" key
  [[ "$salt" =~ ^[0-9a-fA-F]{16}$ ]] || return 1
  key="$(SB_BACKUP_PASSWORD="$password" openssl enc -aes-256-cbc -md sha256 -pbkdf2 -iter 200000 \
    -P -S "$salt" -pass env:SB_BACKUP_PASSWORD 2>/dev/null |
    awk -F= 'tolower($1)=="key" {gsub(/[[:space:]]/,"",$2); print $2; exit}')"
  [[ "$key" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  printf '%s' "$key"
}

migration_hmac_sha256_from_env() {
  local encrypted="$1"
  [[ "${SB_MIGRATION_HMAC_KEY:-}" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  SB_MIGRATION_HMAC_KEY="$SB_MIGRATION_HMAC_KEY" python3 -c \
    'import hashlib, hmac, os, sys
with open(sys.argv[1], "rb") as source:
    data = source.read()
print(hmac.new(bytes.fromhex(os.environ["SB_MIGRATION_HMAC_KEY"]), data, hashlib.sha256).hexdigest())' \
    "$encrypted"
}

migration_hmac_sha256() {
  local encrypted="$1" key="$2"
  SB_MIGRATION_HMAC_KEY="$key" migration_hmac_sha256_from_env "$encrypted"
}

constant_time_hex_equal() {
  local left="$1" right="$2" i mismatch=0
  [[ "$left" =~ ^[0-9a-f]{64}$ && "$right" =~ ^[0-9a-f]{64}$ ]] || return 1
  for ((i=0; i<64; i++)); do
    [[ "${left:i:1}" == "${right:i:1}" ]] || mismatch=1
  done
  ((mismatch == 0))
}

write_migration_auth_file() {
  local encrypted="$1" password="$2" salt key tag
  salt="$(openssl rand -hex 8)"
  key="$(derive_migration_auth_key "$password" "$salt")" || return 1
  tag="$(migration_hmac_sha256 "$encrypted" "$key")"
  [[ "$tag" =~ ^[0-9a-f]{64}$ ]] || return 1
  jq -n --arg salt "$salt" --arg tag "$tag" \
    '{version:1,kdf:"PBKDF2-SHA256",iterations:200000,mac:"HMAC-SHA256",salt:$salt,tag:$tag}' > "$encrypted.auth.tmp"
  chmod 600 "$encrypted.auth.tmp"; mv "$encrypted.auth.tmp" "$encrypted.auth"
  key=""; tag=""
}

verify_migration_auth_file() {
  local encrypted="$1" password="$2" salt expected key actual
  [[ -f "$encrypted.auth" ]] || return 2
  jq -e '
    .version==1 and .kdf=="PBKDF2-SHA256" and .iterations==200000 and
    .mac=="HMAC-SHA256" and (.salt|test("^[0-9a-fA-F]{16}$")) and
    (.tag|test("^[0-9a-fA-F]{64}$"))
  ' "$encrypted.auth" >/dev/null 2>&1 || return 1
  salt="$(jq -r '.salt' "$encrypted.auth")"; expected="$(jq -r '.tag|ascii_downcase' "$encrypted.auth")"
  key="$(derive_migration_auth_key "$password" "$salt")" || return 1
  actual="$(migration_hmac_sha256 "$encrypted" "$key")"
  key=""
  constant_time_hex_equal "$actual" "$expected"
}

materialize_migration_bundle() {
  local bundle="$1" work="$2" encrypted sha
  MIGRATION_MATERIALIZE_FAILURE="structure-invalid"
  jq -e --argjson version "$MIGRATION_BUNDLE_VERSION" '
    .bundle_version==$version and .encryption=="AES-256-CBC" and
    .payload_format_version==1 and
    (.cipher_sha256|type=="string" and test("^[0-9a-fA-F]{64}$")) and
    (.ciphertext_base64|type=="string" and length>0) and
    (.auth.version==1) and (.auth.kdf=="PBKDF2-SHA256") and
    (.auth.iterations==200000) and (.auth.mac=="HMAC-SHA256") and
    (.auth.salt|test("^[0-9a-fA-F]{16}$")) and
    (.auth.tag|test("^[0-9a-fA-F]{64}$"))
  ' "$bundle" >/dev/null 2>&1 || return 1
  encrypted="$work/payload.enc"
  jq -r '.ciphertext_base64' "$bundle" | openssl base64 -d -A -out "$encrypted" 2>/dev/null || return 1
  [[ -s "$encrypted" ]] || return 1
  sha="$(jq -r '.cipher_sha256|ascii_downcase' "$bundle")"
  printf '%s  payload.enc\n' "$sha" > "$encrypted.sha256" || return 1
  jq '.auth' "$bundle" > "$encrypted.auth" || return 1
  chmod 600 "$encrypted" "$encrypted.sha256" "$encrypted.auth" || return 1
  MIGRATION_MATERIALIZE_FAILURE="checksum-failed"
  validate_migration_checksum "$encrypted" || return 1
  MATERIALIZED_MIGRATION_ENCRYPTED="$encrypted"
  MIGRATION_MATERIALIZE_FAILURE=""
}

validate_migration_bundle() {
  local bundle="$1" work
  [[ -f "$bundle" && "$bundle" == *.sbm ]] || return 1
  work="$(mktemp -d /tmp/sb-migration-bundle.XXXXXX)"
  register_temp_path "$work"
  if materialize_migration_bundle "$bundle" "$work"; then rm -rf "$work"; return 0; fi
  rm -rf "$work"; return 1
}

build_migration_bundle() {
  local encrypted="$1" bundle="$2" encoded sha
  encoded="$(mktemp /tmp/sb-migration-cipher.XXXXXX.b64)"
  register_temp_path "$encoded"
  openssl base64 -A -in "$encrypted" -out "$encoded"
  sha="$(sha256sum "$encrypted" | awk '{print $1}')"
  register_temp_path "$bundle.tmp"
  jq -n \
    --argjson bundle_version "$MIGRATION_BUNDLE_VERSION" \
    --argjson payload_format "$MIGRATION_FORMAT_VERSION" \
    --arg created_at "$(date -Iseconds)" \
    --arg script_version "$SCRIPT_VERSION" \
    --arg sha "$sha" \
    --slurpfile auth "$encrypted.auth" \
    --rawfile ciphertext "$encoded" \
    '{bundle_version:$bundle_version,created_at:$created_at,script_version:$script_version,
      payload_format_version:$payload_format,encryption:"AES-256-CBC",cipher_sha256:$sha,
      auth:$auth[0],ciphertext_base64:$ciphertext}' > "$bundle.tmp"
  rm -f "$encoded"
  chmod 600 "$bundle.tmp"; mv "$bundle.tmp" "$bundle"
  validate_migration_bundle "$bundle"
}

create_migration_backup() {
  local dir stamp base work plain encrypted bundle password
  CREATED_MIGRATION_BACKUP=""
  ensure_migration_crypto_dependencies || return 0
  prepare_core
  need_cmd openssl
  nfuse persist >/dev/null
  dir="$(migration_backup_dir)"
  install -d -m 700 "$dir"
  stamp="$(date '+%Y%m%d-%H%M%S')"
  base="sb-user-data-${SCRIPT_VERSION}-${stamp}"
  work="$(mktemp -d /tmp/sb-user-data.XXXXXX)"
  register_temp_path "$work"
  plain="$work/payload.json"
  encrypted="$work/payload.enc"
  bundle="$dir/$base.sbm"
  jq -n \
    --argjson format "$MIGRATION_FORMAT_VERSION" \
    --arg created_at "$(date -Iseconds)" \
    --arg script_version "$SCRIPT_VERSION" \
    --arg hostname "$(hostname)" \
    --argjson schema "$STATE_SCHEMA_VERSION" \
    --slurpfile state "$STATE_FILE" \
    --argjson nfuse "$(nfuse list --json)" \
    'def endpoint_from_legacy:
       if (.protocol // "ss2022") == "anytls" then
         {protocol:"anytls",port:.port,anytls_password:.anytls_password,tls_sni:.tls_sni}
       else
         {protocol:"ss2022",transport:"shadowtls",port:.port,shadowtls_password:.shadowtls_password,
          ss2022_password:.ss2022_password,method:.method,shadowtls_sni:.shadowtls_sni}
       end;
     ($state[0] |
       if .schema_version == 3 and $schema >= 4 then
         . + {schema_version:4,outbound_presets:(.outbound_presets // []),rule_presets:(.rule_presets // [])}
       else . end |
       if .schema_version == 4 and $schema >= 5 then
         .users |= map(.protocol = (.protocol // "ss2022") | if has("usage_offset_bytes") then . else .usage_offset_bytes = 0 end | .endpoints = [endpoint_from_legacy]) |
         .schema_version = 5
       else . end |
       if .schema_version == 5 and $schema >= 6 then
         .users |= map(
           .endpoints |= map(if .protocol == "ss2022" then .transport = (.transport // "shadowtls") else . end) |
           if .protocol == "ss2022" then .transport = (.transport // "shadowtls") else . end
         ) |
         .schema_version = 6
       else . end) as $snapshot |
      {format_version:$format,created_at:$created_at,script_version:$script_version,source_hostname:$hostname,state:$snapshot,
       nfuse_usage:[$nfuse[] as $account | select(any($snapshot.users[]; .name == $account.name)) | $account]}' > "$plain"
  chmod 600 "$plain"
  validate_migration_payload_structure "$plain" >/dev/null 2>&1 ||
    { rm -rf "$work"; die "无法生成可安全恢复的迁移数据"; }
  if ! read_backup_password_twice; then
    BACKUP_PASSWORD=""
    rm -rf "$work"
    MENU_RETURNED=true
    echo '已取消创建备份。'
    return 0
  fi
  password="$BACKUP_PASSWORD"; BACKUP_PASSWORD=""
  if ! SB_BACKUP_PASSWORD="$password" openssl enc -aes-256-cbc -md sha256 -pbkdf2 -iter 200000 -salt \
    -in "$plain" -out "$encrypted" -pass env:SB_BACKUP_PASSWORD; then
    password=""; rm -rf "$work"; die "迁移包加密失败"
  fi
  rm -f "$plain"; chmod 600 "$encrypted"
  if ! write_migration_auth_file "$encrypted" "$password"; then
    password=""; rm -rf "$work"; die "迁移包认证信息生成失败"
  fi
  password=""
  if ! build_migration_bundle "$encrypted" "$bundle"; then
    rm -rf "$work" "$bundle" "$bundle.tmp"; die "单文件迁移包封装或校验失败"
  fi
  rm -rf "$work"
  CREATED_MIGRATION_BACKUP="$bundle"
  printf '单文件迁移备份创建成功：%s\n' "$bundle"
  printf '备份已加密并设置密码保护（.sbm 单文件）。\n'
  printf '这份备份仍在当前服务器上；为防止服务器重装或磁盘损坏，请另存一份到其他设备。\n'
  printf '包含：用户 %s 个，分流 %s 条，预置出口 %s 个，预置规则 %s 个，流量记录 %s 份。\n' \
    "$(jq '.users|length' "$STATE_FILE")" "$(jq '.splits|length' "$STATE_FILE")" \
    "$(jq '(.outbound_presets // [])|length' "$STATE_FILE")" "$(jq '(.rule_presets // [])|length' "$STATE_FILE")" \
    "$(nfuse list --json | jq 'length')"
}

file_mtime_epoch() {
  stat -c '%Y' -- "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null
}

list_files_newest_first() {
  local file epoch
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    epoch="$(file_mtime_epoch "$file")" || continue
    [[ "$epoch" =~ ^[0-9]+$ ]] || continue
    printf '%s\t%s\n' "$epoch" "$file"
  done | sort -t $'\t' -k1,1nr -k2,2r | cut -f2-
}

load_migration_backups() {
  local dir file
  MIGRATION_BACKUPS=()
  dir="$(migration_backup_dir)"
  [[ -d "$dir" ]] || return 0
  while IFS= read -r file; do MIGRATION_BACKUPS[${#MIGRATION_BACKUPS[@]}]="$file"; done < <(
    find "$dir" -maxdepth 1 -type f -name 'sb-user-data-*.sbm' -print | list_files_newest_first
  )
}

print_migration_backups() {
  local i file size integrity
  load_migration_backups
  if ((${#MIGRATION_BACKUPS[@]} == 0)); then echo '暂无迁移备份。'; return 1; fi
  for i in "${!MIGRATION_BACKUPS[@]}"; do
    file="${MIGRATION_BACKUPS[$i]}"; size="$(du -h "$file" | awk '{print $1}')"
    if validate_migration_bundle "$file"; then integrity='结构完整'
    else integrity='校验失败'; fi
    printf '  %d. %s｜%s｜%s｜已设置密码\n' "$((i+1))" "$(basename "$file")" "$size" "$integrity"
  done
}

backup_directory_usage_kib() {
  local dir="$1"
  [[ -d "$dir" && ! -L "$dir" ]] || { printf '0\n'; return 0; }
  du -sk -- "$dir" 2>/dev/null | awk 'NR==1 {print $1+0}'
}

backup_paths_usage_kib() {
  local path total=0 size
  for path in "$@"; do
    [[ -d "$path" && ! -L "$path" ]] || continue
    size="$(du -sk -- "$path" 2>/dev/null | awk 'NR==1 {print $1+0}')" || continue
    [[ "$size" =~ ^[0-9]+$ ]] || continue
    ((total+=size))
  done
  printf '%s\n' "$total"
}

format_backup_usage() {
  awk -v kib="${1:-0}" 'BEGIN {
    if (kib >= 1048576) printf "%.1f GB", kib / 1048576;
    else if (kib >= 1024) printf "%.1f MB", kib / 1024;
    else printf "%d KB", kib;
  }'
}

show_backup_storage_overview() {
  local migration_dir report_dir migration_size snapshot_size operation_size report_size
  local invalid_snapshots incomplete_operation invalid_reports report
  migration_dir="$(migration_backup_dir)"
  report_dir="$(migration_report_dir)"
  load_migration_backups
  load_environment_snapshot_candidates
  load_operation_backup_groups
  load_migration_reports
  migration_size="$(backup_directory_usage_kib "$migration_dir")"
  snapshot_size=0
  if ((${#ENVIRONMENT_SNAPSHOTS[@]} > 0)); then
    snapshot_size="$(backup_paths_usage_kib "${ENVIRONMENT_SNAPSHOTS[@]}")"
  fi
  operation_size="$(backup_directory_usage_kib "$BACKUP_DIR")"
  report_size="$(backup_directory_usage_kib "$report_dir")"
  invalid_snapshots="$(count_invalid_environment_snapshots)"
  incomplete_operation="$(count_incomplete_operation_backup_files)"
  invalid_reports=0
  if ((${#MIGRATION_REPORTS[@]} > 0)); then
    for report in "${MIGRATION_REPORTS[@]}"; do
      validate_migration_restore_report "$report" || ((invalid_reports+=1))
    done
  fi

  cat <<EOF
备份保存情况

  迁移备份        ${#MIGRATION_BACKUPS[@]} 份｜$(format_backup_usage "$migration_size")｜由你决定何时删除
  完整回滚备份    ${#ENVIRONMENT_SNAPSHOTS[@]} 份｜$(format_backup_usage "$snapshot_size")｜自动保留最近 ${ENVIRONMENT_BACKUP_RETENTION} 份
  内部操作备份    ${#OPERATION_BACKUP_GROUPS[@]} 组｜$(format_backup_usage "$operation_size")｜自动保留最近 ${OPERATION_BACKUP_RETENTION} 组
  恢复记录        ${#MIGRATION_REPORTS[@]} 份｜$(format_backup_usage "$report_size")｜自动保留最近 ${MIGRATION_REPORT_RETENTION} 份
EOF
  if ((invalid_snapshots > 0 || incomplete_operation > 0 || invalid_reports > 0)); then
    printf '\n  提示：发现未自动处理的异常文件：完整备份 %s 份、内部备份文件 %s 个、恢复记录 %s 份。\n' \
      "$invalid_snapshots" "$incomplete_operation" "$invalid_reports"
    echo '  脚本不会自动删除这些文件，可通过检查与故障报告进一步确认。'
  fi
}

load_migration_import_candidates() {
  local scan_dir file
  MIGRATION_IMPORT_CANDIDATES=()
  scan_dir="${MIGRATION_IMPORT_SCAN_DIR:-/root}"
  [[ -d "$scan_dir" && ! -L "$scan_dir" ]] || return 0
  while IFS= read -r file; do
    MIGRATION_IMPORT_CANDIDATES[${#MIGRATION_IMPORT_CANDIDATES[@]}]="$file"
  done < <(
    find "$scan_dir" -mindepth 1 -maxdepth 1 -type f -name 'sb-user-data-*.sbm' -print |
      list_files_newest_first
  )
}

read_migration_import_path() {
  local source
  if ! read -r -e -p '请输入单文件迁移包 .sbm 路径（输入 0 返回）：' source; then return 1; fi
  [[ "$source" != 0 ]] || return 1
  MIGRATION_IMPORT_SOURCE="$source"
}

select_migration_import_source() {
  local i file size integrity manual_index
  MIGRATION_IMPORT_SOURCE=""
  load_migration_import_candidates
  if ((${#MIGRATION_IMPORT_CANDIDATES[@]} == 0)); then
    echo '未在 /root 顶层发现迁移备份，可手动输入其他路径。'
    read_migration_import_path
    return
  fi

  printf '\n发现 /root 顶层的迁移备份：\n'
  for i in "${!MIGRATION_IMPORT_CANDIDATES[@]}"; do
    file="${MIGRATION_IMPORT_CANDIDATES[$i]}"
    size="$(du -h "$file" | awk '{print $1}')"
    if validate_migration_bundle "$file" >/dev/null 2>&1; then integrity='结构完整'
    else integrity='校验失败'; fi
    printf '  %d. %s｜%s｜%s\n' "$((i + 1))" "$(basename "$file")" "$size" "$integrity"
  done
  manual_index=$((${#MIGRATION_IMPORT_CANDIDATES[@]} + 1))
  printf '  %d. 手动输入其他路径\n' "$manual_index"
  echo '  0. 返回上一级'
  read_numbered_index '请选择要添加的备份：' "$manual_index" || return 1
  if ((SELECTED_INDEX == ${#MIGRATION_IMPORT_CANDIDATES[@]})); then
    read_migration_import_path
  else
    MIGRATION_IMPORT_SOURCE="${MIGRATION_IMPORT_CANDIDATES[$SELECTED_INDEX]}"
  fi
}

import_migration_backup() {
  local source dir name destination answer
  prepare_core
  while true; do
    select_migration_import_source || return 0
    source="$MIGRATION_IMPORT_SOURCE"
    if [[ ! -f "$source" ]]; then echo '文件不存在，请检查路径后重新输入。'; continue; fi
    source="$(readlink -f -- "$source")"
    name="$(basename "$source")"
    if [[ "$name" != sb-user-data-*.sbm ]]; then echo '文件名必须符合 sb-user-data-*.sbm，请重新选择。'; continue; fi
    if ! validate_migration_bundle "$source"; then echo '备份文件不完整或已经损坏，请重新复制原始 .sbm 文件。'; continue; fi
    break
  done
  dir="$(migration_backup_dir)"; install -d -m 700 "$dir"
  destination="$dir/$name"
  if [[ "$source" == "$(readlink -f -- "$destination" 2>/dev/null || true)" ]]; then
    echo '该迁移包已经位于备份目录。'; return 0
  fi
  if [[ -e "$destination" ]]; then
    read -r -p '备份目录中已有同名文件，是否覆盖？[y/N]：' answer
    [[ "$answer" =~ ^[Yy]$ ]] || { echo '已取消导入。'; return 0; }
  fi
  register_temp_path "$destination.tmp"
  install -m 600 "$source" "$destination.tmp"
  mv "$destination.tmp" "$destination"
  validate_migration_bundle "$destination" || { rm -f "$destination"; die "导入后的单文件迁移包校验失败"; }
  printf '单文件迁移包已导入：%s\n' "$destination"
}

select_migration_backup() {
  print_migration_backups || return 1
  echo '  0. 返回上一级'
  read_numbered_index '请选择备份编号：' "${#MIGRATION_BACKUPS[@]}" || return 1
  SELECTED_MIGRATION_BACKUP="${MIGRATION_BACKUPS[$SELECTED_INDEX]}"
}

normalize_migration_payload_schema() {
  local file="$1" schema tmp needs_update=false
  schema="$(jq -r '.state.schema_version // 0' "$file" 2>/dev/null)" || return 1
  [[ "$schema" =~ ^[0-9]+$ ]] || return 1
  if ((schema < STATE_SCHEMA_VERSION)); then
    needs_update=true
  elif jq -e '(.state.users | type == "array") and any(.state.users[]?; has("usage_offset_bytes") | not)' \
      "$file" >/dev/null 2>&1; then
    needs_update=true
  fi
  if [[ "$needs_update" == true ]]; then
    tmp="$(mktemp "$(dirname "$file")/.migration-schema.XXXXXX")" || return 1
    if ! jq --argjson schema "$STATE_SCHEMA_VERSION" '
      def endpoint_from_legacy:
        if (.protocol // "ss2022") == "anytls" then
          {protocol:"anytls",port:.port,anytls_password:.anytls_password,tls_sni:.tls_sni}
        else
          {protocol:"ss2022",transport:"shadowtls",port:.port,shadowtls_password:.shadowtls_password,
           ss2022_password:.ss2022_password,method:.method,shadowtls_sni:.shadowtls_sni}
        end;
      .state.users |= map(if has("usage_offset_bytes") then . else .usage_offset_bytes = 0 end) |
      if .state.schema_version == 3 and $schema >= 4 then
        .state.outbound_presets = (.state.outbound_presets // []) |
        .state.rule_presets = (.state.rule_presets // []) |
        .state.schema_version = 4
      else . end |
      if .state.schema_version == 4 and $schema >= 5 then
        .state.users |= map(.protocol = (.protocol // "ss2022") | .endpoints = [endpoint_from_legacy]) |
        .state.schema_version = 5
      else . end |
      if .state.schema_version == 5 and $schema >= 6 then
        .state.users |= map(
          .endpoints |= map(if .protocol == "ss2022" then .transport = (.transport // "shadowtls") else . end) |
          if .protocol == "ss2022" then .transport = (.transport // "shadowtls") else . end
        ) |
        .state.schema_version = 6
      else . end |
      if .state.schema_version == 6 and $schema >= 7 then
        .state.schema_version = 7
      else . end
    ' "$file" > "$tmp"; then
      rm -f -- "$tmp"
      return 1
    fi
    chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
  fi
}

decrypt_migration_backup() {
  local bundle="$1" output="$2" password work encrypted
  work="$(mktemp -d /tmp/sb-migration-decrypt.XXXXXX)"
  register_temp_path "$work"
  if ! materialize_migration_bundle "$bundle" "$work"; then
    rm -rf "$work" "$output"; die "单文件迁移包结构或密文 SHA256 校验失败"
  fi
  encrypted="$MATERIALIZED_MIGRATION_ENCRYPTED"
  while true; do
    if ! read_backup_password; then rm -rf "$work" "$output"; return 1; fi
    password="$BACKUP_PASSWORD"; BACKUP_PASSWORD=""
    if ! verify_migration_auth_file "$encrypted" "$password"; then
      password=""; rm -f -- "$output"
      echo '密码错误，或迁移包已经损坏。请重新输入；如果多次失败，请重新复制原始备份。'
      continue
    fi
    if ! (umask 077; SB_BACKUP_PASSWORD="$password" openssl enc -d -aes-256-cbc -md sha256 -pbkdf2 -iter 200000 \
      -in "$encrypted" -out "$output" -pass env:SB_BACKUP_PASSWORD 2>/dev/null); then
      password=""; rm -f -- "$output"
      echo '无法解密备份，请重新输入密码；如果密码正确，请重新复制原始备份。'
      continue
    fi
    break
  done
  password=""; rm -rf "$work"; chmod 600 "$output"
  normalize_migration_payload_schema "$output" || { rm -f "$output"; die "迁移包中的旧数据无法安全升级"; }
  jq -e --argjson format "$MIGRATION_FORMAT_VERSION" '
    .format_version == $format and (.state|type=="object") and
    (.state.users|type=="array") and (.state.splits|type=="array") and
    (.state.outbound_presets|type=="array") and (.state.rule_presets|type=="array") and
    (.nfuse_usage|type=="array")
  ' "$output" >/dev/null || { rm -f "$output"; die "迁移包格式无效或版本不受支持"; }
}

show_migration_backup_details() {
  local plain
  ensure_migration_crypto_dependencies || return 0
  select_migration_backup || return 0
  plain="$(mktemp /tmp/sb-user-data-details.XXXXXX.json)"
  register_temp_path "$plain"
  decrypt_migration_backup "$SELECTED_MIGRATION_BACKUP" "$plain" || { rm -f -- "$plain"; MENU_RETURNED=true; return 0; }
  normalize_migration_payload_schema "$plain" || { rm -f -- "$plain"; die "迁移包中的旧数据无法安全升级"; }
  jq -r '
    "\n备份内容\n",
    "创建时间：\(.created_at)",
    "脚本版本：\(.script_version)",
    "来源主机：\(.source_hostname)",
    "用户数量：\(.state.users|length)",
    "分流数量：\(.state.splits|length)",
    "预置出口：\(.state.outbound_presets|length)",
    "预置规则：\(.state.rule_presets|length)",
    "流量记录：\(.nfuse_usage|length)",
    "数据格式版本：\(.state.schema_version)"
  ' "$plain"
  rm -f "$plain"
}

validate_migration_payload_structure() {
  local payload="$1" rule_url
  normalize_migration_payload_schema "$payload" || return 1
  jq -e --argjson schema "$STATE_SCHEMA_VERSION" '
    def endpoint_kind:
      if .protocol == "anytls" then "anytls"
      elif .protocol == "ss2022" and .transport == "direct" then "ss2022-direct"
      elif .protocol == "ss2022" and .transport == "shadowtls" then "ss2022-shadowtls"
      else null end;
    def valid_ss2022_endpoint:
      (.transport == "direct" or .transport == "shadowtls") and
      (.ss2022_password | type == "string" and length > 0) and
      (.method == "2022-blake3-aes-128-gcm" or .method == "2022-blake3-aes-256-gcm") and
      (if .transport == "shadowtls" then
         (.shadowtls_password | type == "string" and length > 0) and
         (.shadowtls_sni | type == "string" and length > 0)
       else
         (has("shadowtls_password") | not) and (has("shadowtls_sni") | not)
       end);
    def valid_upstream:
      (type == "object") and
      (.server | type == "string" and length > 0) and
      (.server_port | type == "number" and . == floor and . >= 1 and . <= 65535) and
      if .protocol == "anytls" then
        (.password | type == "string" and length > 0) and
        (.sni | type == "string" and length > 0) and
        (.insecure | type == "boolean")
      elif .protocol == "shadowsocks" then
        (.method | type == "string" and length > 0) and
        (.password | type == "string" and length > 0)
      elif .protocol == "ss_shadowtls" then
        (.method | type == "string" and startswith("2022-")) and
        (.ss_password | type == "string" and length > 0) and
        (.shadowtls_password | type == "string" and length > 0) and
        (.sni | type == "string" and length > 0) and
        (.insecure | type == "boolean")
      else false end;
    (.state.users | map(.name)) as $user_names |
    (.state.outbound_presets | map(.name)) as $outbound_preset_names |
    (.state.rule_presets | map(.name)) as $rule_preset_names |
    .state.schema_version == $schema and
    (.state.outbound_presets | type == "array") and
    (.state.rule_presets | type == "array") and
    (.state.users | map(.name) as $values | ($values|length) == ($values|unique|length)) and
    ([.state.users[].endpoints[].port] as $values | ($values|length) == ($values|unique|length)) and
    (.state.splits | map(.name) as $values | ($values|length) == ($values|unique|length)) and
    (.state.splits | map(.outbound_tag // ("managed-out-" + .name)) as $values | ($values|length) == ($values|unique|length)) and
    (.state.splits | map(.rule_set_tag // ("managed-split-" + .name)) as $values | ($values|length) == ($values|unique|length)) and
    ($outbound_preset_names | length == (unique | length)) and
    ($rule_preset_names | length == (unique | length)) and
    ([.state.splits[] |
      (.outbound_tag // ("managed-out-" + .name)),
      (if (.upstream.protocol // "") == "ss_shadowtls" then ("managed-transport-" + .name) else empty end)
    ] as $values | ($values|length) == ($values|unique|length)) and
    (.nfuse_usage | map(.name) as $values | ($values|length) == ($values|unique|length)) and
    all(.state.users[];
      (.name|type=="string") and
      (.port|type=="number") and (.port == (.port|floor)) and (.port>=1 and .port<=65535) and
      (.status == "active" or .status == "disabled") and
      (.metered|type=="boolean") and
      (has("expires_at") and (.expires_at == null or (.expires_at|type=="string"))) and
      (has("limit_gib") and (.limit_gib == null or (((.limit_gib|type) == "number") and .limit_gib>0))) and
      (has("billing_anchor") and (.billing_anchor == null or (((.billing_anchor|type) == "number") and .billing_anchor==(.billing_anchor|floor) and .billing_anchor>=1))) and
      (has("usage_offset_bytes") and ((.usage_offset_bytes|type) == "number") and (.usage_offset_bytes == (.usage_offset_bytes|floor)) and (.usage_offset_bytes >= 0)) and
      (has("created_at") and ((.created_at|type) == "string" and length>0)) and
      (if .metered then (((.limit_gib|type) == "number") and .limit_gib>0) and (((.billing_anchor|type) == "number") and .billing_anchor==(.billing_anchor|floor) and .billing_anchor>=1) else true end) and
      (.endpoints | type == "array" and length >= 1 and length <= 3) and
      ([.endpoints[] | endpoint_kind] | all(. != null) and length == (unique | length)) and
      ([.endpoints[].port] | length == (unique | length)) and
      (.protocol == .endpoints[0].protocol) and (.port == .endpoints[0].port) and
      all(.endpoints[];
        (.port|type=="number") and (.port == (.port|floor)) and (.port>=1 and .port<=65535) and
        if .protocol == "anytls" then
          (.anytls_password|type=="string" and length>0) and (.tls_sni|type=="string" and length>0)
        elif .protocol == "ss2022" then
          valid_ss2022_endpoint
        else false end) and
      if .protocol == "anytls" then
        (.anytls_password == .endpoints[0].anytls_password) and (.tls_sni == .endpoints[0].tls_sni)
      elif .protocol == "ss2022" then
        (.transport == .endpoints[0].transport) and
        (.ss2022_password == .endpoints[0].ss2022_password) and
        (.method == .endpoints[0].method) and
        (if .transport == "shadowtls" then
           (.shadowtls_password == .endpoints[0].shadowtls_password) and
           (.shadowtls_sni == .endpoints[0].shadowtls_sni)
         else
           (has("shadowtls_password") | not) and (has("shadowtls_sni") | not)
         end)
      else false end) and
    all(.state.splits[];
      (.name|type=="string" and test("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$")) and
      (.url|type=="string" and test("^https://") and test("\\.(srs|json)([?#].*)?$")) and
      (.scope=="all" or .scope=="user") and
      ((.scope=="all") or ((.user|type=="string") and (.user as $user | ($user_names | index($user)) != null))) and
      (.status=="active" or .status=="disabled") and
      ((.upstream | valid_upstream) or (.status == "disabled" and (.upstream | type == "object"))) and
      (((.outbound_preset // null) == null) or (.outbound_preset as $preset | ($outbound_preset_names | index($preset)) != null)) and # static-allow: strict-empty-check
      (((.rule_preset // null) == null) or (.rule_preset as $preset | ($rule_preset_names | index($preset)) != null)) and # static-allow: strict-empty-check
      ((.outbound_tag // ("managed-out-" + .name)) | test("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$") and . != "direct") and
      ((.rule_set_tag // ("managed-split-" + .name)) | test("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$") and . != "direct") and
      all([.runtime_rule_tag?,.runtime_outbound_tag?,.runtime_transport_tag?][];
        . == null or (type == "string" and test("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$") and . != "direct"))) and
    all(.state.outbound_presets[];
      (.name | type == "string" and test("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$")) and
      (.upstream | valid_upstream)) and
    all(.state.rule_presets[];
      (.name | type == "string" and test("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$")) and
      (.url | type == "string" and test("^https://") and test("\\.(srs|json)([?#].*)?$"))) and
    all(.nfuse_usage[];
      (.name|type=="string" and length>0) and
      (.used_bytes|type=="number") and
      (.used_bytes == (.used_bytes|floor)) and .used_bytes>=0)
  ' "$payload" >/dev/null || return 1
  while IFS= read -r rule_url; do
    [[ -n "$rule_url" ]] || continue
    validate_public_rule_set_url "$rule_url" || return 1
  done < <(jq -r '.state.splits[]?.url, .state.rule_presets[]?.url' "$payload")
}

inspect_migration_bundle_with_password() {
  local bundle="$1" password="$2" work encrypted plain
  MIGRATION_INSPECTION_RESULT="internal-error"
  work="$(mktemp -d /tmp/sb-migration-inspect.XXXXXX)" || return 1
  chmod 700 "$work" || { rm -rf -- "$work"; return 1; }
  register_temp_path "$work" || { rm -rf -- "$work"; return 1; }
  plain="$work/payload.json"
  if ! materialize_migration_bundle "$bundle" "$work"; then
    MIGRATION_INSPECTION_RESULT="${MIGRATION_MATERIALIZE_FAILURE:-structure-invalid}"
    rm -rf -- "$work"
    return 1
  fi
  encrypted="$MATERIALIZED_MIGRATION_ENCRYPTED"
  if ! verify_migration_auth_file "$encrypted" "$password"; then
    MIGRATION_INSPECTION_RESULT="password-mismatch"
    rm -rf -- "$work"
    return 1
  fi
  if ! (umask 077; SB_BACKUP_PASSWORD="$password" openssl enc -d -aes-256-cbc -md sha256 -pbkdf2 -iter 200000 \
    -in "$encrypted" -out "$plain" -pass env:SB_BACKUP_PASSWORD 2>/dev/null); then
    MIGRATION_INSPECTION_RESULT="payload-invalid"
    rm -rf -- "$work"
    return 1
  fi
  chmod 600 "$plain" || { rm -rf -- "$work"; return 1; }
  if ! validate_migration_payload_structure "$plain" >/dev/null 2>&1; then
    MIGRATION_INSPECTION_RESULT="payload-invalid"
    rm -rf -- "$work"
    return 1
  fi
  rm -rf -- "$work" || return 1
  MIGRATION_INSPECTION_RESULT="healthy"
}

check_all_migration_backups() {
  local password bundle name result
  local healthy=0 structure_invalid=0 checksum_failed=0 password_mismatch=0 payload_invalid=0 internal_error=0
  ensure_migration_crypto_dependencies || return 0
  load_migration_backups
  if ((${#MIGRATION_BACKUPS[@]} == 0)); then
    echo '暂无迁移备份可供体检。'
    return 0
  fi
  printf '将使用同一个密码只读体检本地 %s 份迁移备份；不同密码的备份会单独标记，不会被判为损坏。\n' \
    "${#MIGRATION_BACKUPS[@]}"
  if ! read_backup_password; then
    BACKUP_PASSWORD=""
    MENU_RETURNED=true
    echo '已取消批量体检。'
    return 0
  fi
  password="$BACKUP_PASSWORD"
  BACKUP_PASSWORD=""
  printf '\n体检结果\n'
  for bundle in "${MIGRATION_BACKUPS[@]}"; do
    name="$(basename "$bundle")"
    if inspect_migration_bundle_with_password "$bundle" "$password"; then
      result='健康'
      ((healthy+=1))
    else
      case "$MIGRATION_INSPECTION_RESULT" in
        structure-invalid) result='结构异常'; ((structure_invalid+=1));;
        checksum-failed) result='密文校验失败'; ((checksum_failed+=1));;
        password-mismatch) result='密码不匹配或认证失败'; ((password_mismatch+=1));;
        payload-invalid) result='解密后内容异常'; ((payload_invalid+=1));;
        *) result='内部检查失败'; ((internal_error+=1));;
      esac
    fi
    printf '  %s：%s\n' "$name" "$result"
  done
  password=""
  printf '\n汇总：健康 %s，结构异常 %s，密文校验失败 %s，密码不匹配或认证失败 %s，解密后内容异常 %s，内部检查失败 %s。\n' \
    "$healthy" "$structure_invalid" "$checksum_failed" "$password_mismatch" "$payload_invalid" "$internal_error"
  echo '批量体检完成；没有修改备份文件或服务器上的用户、分流、配置与服务。'
}

migration_update_json_file() {
  local file="$1" tmp
  shift
  tmp="$(mktemp "$(dirname "$file")/.migration-update.XXXXXX")" || return 1
  if ! jq "$@" "$file" > "$tmp"; then rm -f -- "$tmp"; return 1; fi
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -- "$tmp" "$file"
}

prompt_migration_choice() {
  local prompt="$1" default="$2" pattern="$3" choice
  while true; do
    if ! read -r -p "$prompt" choice; then return 1; fi
    choice="${choice:-$default}"
    if [[ "$choice" =~ $pattern ]]; then MIGRATION_CHOICE="$choice"; return 0; fi
    echo '输入的编号无效，请按照上方菜单重新选择。'
  done
}

select_migration_restore_mode() {
  cat <<'EOF'

恢复方式：
  1. 合并到这台服务器（推荐；保留已有用户和分流）
  2. 完全恢复成备份内容（会删除这台服务器现有的用户和分流）
  0. 返回上一级
EOF
  prompt_migration_choice '请选择恢复方式 [1]：' 1 '^[0-2]$' || return 1
  case "$MIGRATION_CHOICE" in
    1) MIGRATION_RESTORE_MODE=merge;;
    2) MIGRATION_RESTORE_MODE=replace;;
    0) MENU_RETURNED=true; return 1;;
  esac
}

migration_user_conflict() {
  local payload="$1" candidate="$2" replace_name="$3" normalized="$4"
  local name port protocol tag owner endpoint has_legacy=false
  local -a tags
  MIGRATION_CONFLICT_REASON=""
  name="$(jq -r '.name' <<<"$candidate")"
  jq -e 'any(.endpoints[]?; .protocol == "ss2022" and .transport == "shadowtls")' <<<"$candidate" >/dev/null && has_legacy=true
  if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$ ]]; then
    MIGRATION_CONFLICT_REASON="用户名不符合规则：$name"; return 0
  fi
  owner="$(jq -r --arg replace "$replace_name" --arg name "$name" '.state.users[]? | select(.name != $replace and .name == $name) | .name' "$payload" | head -n1)"
  if [[ -n "$owner" ]]; then
    MIGRATION_CONFLICT_REASON="用户名已存在：$name"; return 0
  fi
  if ! jq -e '[.endpoints[].port] | length == (unique | length)' <<<"$candidate" >/dev/null; then
    MIGRATION_CONFLICT_REASON='两个协议必须使用不同端口'; return 0
  fi
  while IFS= read -r endpoint; do
    [[ -n "$endpoint" ]] || continue
    port="$(jq -r '.port' <<<"$endpoint")"
    protocol="$(jq -r '.protocol' <<<"$endpoint")"
    if [[ ! "$port" =~ ^[0-9]+$ ]] || ((10#$port < 1 || 10#$port > 65535)); then
      MIGRATION_CONFLICT_REASON="端口必须位于 1-65535：$port"; return 0
    fi
    owner="$(jq -r --arg name "$replace_name" --argjson port "$port" '
      .state.users[]? | select(.name != $name and any(.endpoints[]; .port == $port)) | .name
    ' "$payload" | head -n1)"
    if [[ -n "$owner" ]]; then
      MIGRATION_CONFLICT_REASON="端口 $port 已由目标用户 $owner 使用"; return 0
    fi
    if port_is_listening "$port" && ! jq -e --argjson port "$port" '
      any(.users[]?; any(if (.endpoints | type) == "array" then .endpoints[] else {port:.port} end; .port == $port))
    ' "$STATE_FILE" >/dev/null; then
      MIGRATION_CONFLICT_REASON="端口 $port 已被目标服务器上的其他服务监听"; return 0
    fi
    while IFS= read -r tag; do
      [[ -n "$tag" ]] || continue
      if ! current_state_owns_tag "$tag"; then
        MIGRATION_CONFLICT_REASON="端口 ${port} 已被其他连接配置占用（${tag}）"; return 0
      fi
    done < <(jq -r --argjson port "$port" '.inbounds[]? | select(.listen_port == $port) | (.tag // "")' "$normalized")
    if [[ "$protocol" == anytls ]]; then
      tags=("anytls-$name")
    elif [[ "$(jq -r '.transport // "shadowtls"' <<<"$endpoint")" == shadowtls ]]; then
      tags=("st-$name" "ss-$name" "ss-udp-$name")
    elif [[ "$has_legacy" == true ]]; then
      tags=("ss-direct-$name")
    else
      tags=("ss-$name")
    fi
    for tag in "${tags[@]}"; do
      if jq -e --arg tag "$tag" '.inbounds[]? | select(.tag == $tag)' "$normalized" >/dev/null && ! current_state_owns_tag "$tag"; then
        MIGRATION_CONFLICT_REASON="连接名称已被其他配置占用：$tag"; return 0
      fi
    done
  done < <(jq -c '.endpoints[]' <<<"$candidate")
  return 1
}

prompt_migration_user_reconfigure() {
  local incoming="$1" payload="$2" replace_name="$3" normalized="$4"
  local original_name original_port name port candidate count index protocol label
  original_name="$(jq -r '.name' <<<"$incoming")"
  while true; do
    read -r -p "新用户名 [${original_name}]（输入 0 取消合并）：" name
    [[ "$name" != 0 ]] || { MIGRATION_MERGE_CANCELLED=true; return 1; }
    name="${name:-$original_name}"
    if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$ ]]; then
      echo '用户名只能包含字母、数字、下划线和连字符，长度 1-32。'; continue
    fi
    candidate="$(jq -c --arg name "$name" '.name=$name' <<<"$incoming")" || return 1
    count="$(jq '.endpoints | length' <<<"$candidate")" || return 1
    for ((index=0; index<count; index++)); do
      original_port="$(jq -r --argjson index "$index" '.endpoints[$index].port' <<<"$incoming")"
      protocol="$(jq -r --argjson index "$index" '.endpoints[$index].protocol' <<<"$incoming")"
      if [[ "$protocol" == anytls ]]; then label=AnyTLS
      elif [[ "$(jq -r --argjson index "$index" '.endpoints[$index].transport // "shadowtls"' <<<"$incoming")" == shadowtls ]]; then label='SS2022 + ShadowTLS（旧版）'
      else label=SS2022
      fi
      read -r -p "${label} 新端口 [${original_port}]（输入 0 取消合并）：" port
      [[ "$port" != 0 ]] || { MIGRATION_MERGE_CANCELLED=true; return 1; }
      port="${port:-$original_port}"
      candidate="$(jq -c --argjson index "$index" --argjson port "$port" '
        .endpoints[$index].port=$port | if $index == 0 then .port=$port else . end
      ' <<<"$candidate" 2>/dev/null)" || { echo '端口必须是整数。'; candidate=""; break; }
    done
    [[ -n "$candidate" ]] || continue
    if migration_user_conflict "$payload" "$candidate" "$replace_name" "$normalized"; then
      echo "无法使用该用户名或端口：$MIGRATION_CONFLICT_REASON"; continue
    fi
    MIGRATION_CONFIGURED_ENTITY="$candidate"
    return 0
  done
}

migration_split_conflict() {
  local payload="$1" candidate="$2" replace_name="$3" normalized="$4"
  local name out_tag rule_tag protocol transport_tag owner
  MIGRATION_CONFLICT_REASON=""
  name="$(jq -r '.name' <<<"$candidate")"
  out_tag="$(jq -r '.outbound_tag // ("managed-out-" + .name)' <<<"$candidate")"
  rule_tag="$(jq -r '.rule_set_tag // ("managed-split-" + .name)' <<<"$candidate")"
  protocol="$(jq -r '.upstream.protocol // ""' <<<"$candidate")"
  transport_tag="managed-transport-$name"
  for owner in "$name" "$out_tag" "$rule_tag"; do
    if [[ ! "$owner" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$ ]]; then
      MIGRATION_CONFLICT_REASON="分流名称或内部名称不符合规则：$owner"; return 0
    fi
  done
  if [[ "$out_tag" == direct || "$rule_tag" == direct ]]; then
    MIGRATION_CONFLICT_REASON='direct 是系统保留标签'; return 0
  fi
  owner="$(jq -r --arg replace "$replace_name" --arg name "$name" '.state.splits[]? | select(.name != $replace and .name == $name) | .name' "$payload" | head -n1)"
  if [[ -n "$owner" ]]; then MIGRATION_CONFLICT_REASON="分流名称已存在：$name"; return 0; fi
  owner="$(jq -r --arg replace "$replace_name" --arg out "$out_tag" '
    .state.splits[]? | select(.name != $replace and (
      (.outbound_tag // ("managed-out-" + .name)) == $out or
      ((.upstream.protocol // "") == "ss_shadowtls" and ("managed-transport-" + .name) == $out)
    )) | .name
  ' "$payload" | head -n1)"
  if [[ -n "$owner" ]]; then MIGRATION_CONFLICT_REASON="出口名称 $out_tag 已由分流 $owner 使用"; return 0; fi
  owner="$(jq -r --arg replace "$replace_name" --arg tag "$rule_tag" '
    .state.splits[]? | select(.name != $replace and (.rule_set_tag // ("managed-split-" + .name)) == $tag) | .name
  ' "$payload" | head -n1)"
  if [[ -n "$owner" ]]; then MIGRATION_CONFLICT_REASON="规则名称 $rule_tag 已由分流 $owner 使用"; return 0; fi
  if [[ "$protocol" == ss_shadowtls ]]; then
    owner="$(jq -r --arg replace "$replace_name" --arg tag "$transport_tag" '
      .state.splits[]? | select(.name != $replace and (
        (.outbound_tag // ("managed-out-" + .name)) == $tag or
        ((.upstream.protocol // "") == "ss_shadowtls" and ("managed-transport-" + .name) == $tag)
      )) | .name
    ' "$payload" | head -n1)"
    if [[ -n "$owner" ]]; then MIGRATION_CONFLICT_REASON="ShadowTLS 传输标签 $transport_tag 与分流 $owner 冲突"; return 0; fi
  fi
  if jq -e --arg tag "$out_tag" '.outbounds[]? | select(.tag == $tag)' "$normalized" >/dev/null && ! current_state_owns_tag "$out_tag"; then
    MIGRATION_CONFLICT_REASON="出口名称已被其他配置占用：$out_tag"; return 0
  fi
  if [[ "$protocol" == ss_shadowtls ]] &&
     jq -e --arg tag "$transport_tag" '.outbounds[]? | select(.tag == $tag)' "$normalized" >/dev/null &&
     ! current_state_owns_tag "$transport_tag"; then
    MIGRATION_CONFLICT_REASON="系统内部名称已被其他配置占用：$transport_tag"; return 0
  fi
  if jq -e --arg tag "$rule_tag" '.route.rule_set[]? | select(.tag == $tag)' "$normalized" >/dev/null && ! current_state_owns_tag "$rule_tag"; then
    MIGRATION_CONFLICT_REASON="规则名称已被其他配置占用：$rule_tag"; return 0
  fi
  return 1
}

prompt_migration_split_reconfigure() {
  local incoming="$1" payload="$2" replace_name="$3" normalized="$4"
  local original_name original_out original_rule name out_tag rule_tag candidate
  original_name="$(jq -r '.name' <<<"$incoming")"
  original_out="$(jq -r '.outbound_tag // ("managed-out-" + .name)' <<<"$incoming")"
  original_rule="$(jq -r '.rule_set_tag // ("managed-split-" + .name)' <<<"$incoming")"
  while true; do
    read -r -p "新分流名称 [${original_name}]（输入 0 取消合并）：" name
    [[ "$name" != 0 ]] || { MIGRATION_MERGE_CANCELLED=true; return 1; }
    name="${name:-$original_name}"
    read -r -p "新出口名称 [${original_out}]（用于区分这条分流，例如 ai-out；输入 0 取消）：" out_tag
    [[ "$out_tag" != 0 ]] || { MIGRATION_MERGE_CANCELLED=true; return 1; }
    out_tag="${out_tag:-$original_out}"
    read -r -p "新规则名称 [${original_rule}]（用于区分规则，例如 ai-rule；输入 0 取消）：" rule_tag
    [[ "$rule_tag" != 0 ]] || { MIGRATION_MERGE_CANCELLED=true; return 1; }
    rule_tag="${rule_tag:-$original_rule}"
    candidate="$(jq -c --arg name "$name" --arg out "$out_tag" --arg rule "$rule_tag" '.name=$name | .outbound_tag=$out | .rule_set_tag=$rule' <<<"$incoming")"
    if migration_split_conflict "$payload" "$candidate" "$replace_name" "$normalized"; then
      echo "这个名称无法使用：$MIGRATION_CONFLICT_REASON"; continue
    fi
    MIGRATION_CONFIGURED_ENTITY="$candidate"
    return 0
  done
}

migration_unique_preset_name() {
  local payload="$1" collection="$2" original="$3" base candidate suffix=1 max_base
  base="${original:0:23}-imported"
  candidate="$base"
  while jq -e --arg name "$candidate" ".state.${collection}[]? | select(.name == \$name)" "$payload" >/dev/null; do
    suffix=$((suffix + 1))
    max_base=$((32 - ${#suffix} - 1))
    candidate="${base:0:max_base}-${suffix}"
  done
  printf '%s' "$candidate"
}

build_merge_migration_payload() {
  local source="$1" output="$2" current_nfuse normalized incoming candidate usage
  local source_name final_name choice action replace_name scope scope_user mapped_user
  local split_name preset_name mapped_preset unique_name
  local user_map='{}' outbound_preset_map='{}' rule_preset_map='{}'
  normalize_migration_payload_schema "$source" || return 1
  current_nfuse="$(nfuse list --json)" || return 1
  jq -e 'type == "array"' <<<"$current_nfuse" >/dev/null || return 1
  normalized="$(mktemp /tmp/sb-migration-merge-config.XXXXXX)" || return 1
  register_temp_path "$normalized"
  "$SINGBOX_BIN" format -c "$SINGBOX_CONFIG" > "$normalized" || { rm -f -- "$normalized"; return 1; }
  jq --slurpfile current "$STATE_FILE" --argjson nfuse "$current_nfuse" --argjson schema "$STATE_SCHEMA_VERSION" '
    def endpoint_from_legacy:
      if (.protocol // "ss2022") == "anytls" then
        {protocol:"anytls",port:.port,anytls_password:.anytls_password,tls_sni:.tls_sni}
      else
        {protocol:"ss2022",transport:(.transport // "shadowtls"),port:.port,shadowtls_password:.shadowtls_password,
         ss2022_password:.ss2022_password,method:.method,shadowtls_sni:.shadowtls_sni}
      end;
    ($current[0] |
      .users |= map(
        .protocol = (.protocol // "ss2022") |
        if has("usage_offset_bytes") then . else .usage_offset_bytes = 0 end |
        if (.endpoints | type) == "array" then . else .endpoints = [endpoint_from_legacy] end
      )) as $current_state |
    . + {restore_mode:"merge",state:($current_state + {
        schema_version:$schema,
        outbound_presets:($current_state.outbound_presets // []),
        rule_presets:($current_state.rule_presets // [])
      }),nfuse_usage:$nfuse,
      merge_summary:{
        users:{imported:0,replaced:0,renamed:0,skipped:0},
        splits:{imported:0,replaced:0,renamed:0,skipped:0},
        outbound_presets:{imported:0,renamed:0,deduplicated:0},
        rule_presets:{imported:0,renamed:0,deduplicated:0}
      }}
  ' "$source" > "$output" || { rm -f -- "$normalized"; return 1; }
  chmod 600 "$output"
  MIGRATION_MERGE_CANCELLED=false

  while IFS= read -r incoming <&3; do
    [[ -n "$incoming" ]] || continue
    preset_name="$(jq -r '.name' <<<"$incoming")"
    mapped_preset="$preset_name"
    if jq -e --arg name "$preset_name" '.state.outbound_presets[]? | select(.name == $name)' "$output" >/dev/null; then
      if SB_JQ_INCOMING="$incoming" jq -e --arg name "$preset_name" '($ENV.SB_JQ_INCOMING | fromjson) as $incoming | .state.outbound_presets[] | select(.name == $name and .upstream == $incoming.upstream)' "$output" >/dev/null; then
        migration_update_json_file "$output" '.merge_summary.outbound_presets.deduplicated += 1' || return 1
      else
        unique_name="$(migration_unique_preset_name "$output" outbound_presets "$preset_name")" || return 1
        mapped_preset="$unique_name"
        candidate="$(jq -c --arg name "$unique_name" '.name=$name' <<<"$incoming")" || return 1
        SB_JQ_PRESET="$candidate" migration_update_json_file "$output" '($ENV.SB_JQ_PRESET | fromjson) as $preset | .state.outbound_presets += [$preset] | .merge_summary.outbound_presets.renamed += 1' || return 1
      fi
    else
      SB_JQ_PRESET="$incoming" migration_update_json_file "$output" '($ENV.SB_JQ_PRESET | fromjson) as $preset | .state.outbound_presets += [$preset] | .merge_summary.outbound_presets.imported += 1' || return 1
    fi
    outbound_preset_map="$(jq -c --arg key "$preset_name" --arg value "$mapped_preset" '. + {($key):$value}' <<<"$outbound_preset_map")" || return 1
  done 3< <(jq -c '.state.outbound_presets[]' "$source")

  while IFS= read -r incoming <&3; do
    [[ -n "$incoming" ]] || continue
    preset_name="$(jq -r '.name' <<<"$incoming")"
    mapped_preset="$preset_name"
    if jq -e --arg name "$preset_name" '.state.rule_presets[]? | select(.name == $name)' "$output" >/dev/null; then
      if SB_JQ_INCOMING="$incoming" jq -e --arg name "$preset_name" '($ENV.SB_JQ_INCOMING | fromjson) as $incoming | .state.rule_presets[] | select(.name == $name and .url == $incoming.url)' "$output" >/dev/null; then
        migration_update_json_file "$output" '.merge_summary.rule_presets.deduplicated += 1' || return 1
      else
        unique_name="$(migration_unique_preset_name "$output" rule_presets "$preset_name")" || return 1
        mapped_preset="$unique_name"
        candidate="$(jq -c --arg name "$unique_name" '.name=$name' <<<"$incoming")" || return 1
        SB_JQ_PRESET="$candidate" migration_update_json_file "$output" '($ENV.SB_JQ_PRESET | fromjson) as $preset | .state.rule_presets += [$preset] | .merge_summary.rule_presets.renamed += 1' || return 1
      fi
    else
      SB_JQ_PRESET="$incoming" migration_update_json_file "$output" '($ENV.SB_JQ_PRESET | fromjson) as $preset | .state.rule_presets += [$preset] | .merge_summary.rule_presets.imported += 1' || return 1
    fi
    rule_preset_map="$(jq -c --arg key "$preset_name" --arg value "$mapped_preset" '. + {($key):$value}' <<<"$rule_preset_map")" || return 1
  done 3< <(jq -c '.state.rule_presets[]' "$source")

  while IFS= read -r incoming <&3; do
    [[ -n "$incoming" ]] || continue
    source_name="$(jq -r '.name' <<<"$incoming")"
    candidate="$incoming"; action=imported; replace_name=""
    if jq -e --arg name "$source_name" '.state.users[]? | select(.name == $name)' "$output" >/dev/null; then
      printf '\n发现同名用户：%s\n' "$source_name"
      jq -r --arg name "$source_name" '
        .state.users[] | select(.name == $name) |
        "  这台服务器：" + ([.endpoints[] |
          (if .protocol == "anytls" then "AnyTLS"
           elif .transport == "shadowtls" then "SS2022 + ShadowTLS（旧版）"
           else "SS2022" end) + " 端口 " + (.port|tostring)] | join(" / "))
      ' "$output"
      jq -r '
        "  备份中用户：" + ([.endpoints[] |
          (if .protocol == "anytls" then "AnyTLS"
           elif .transport == "shadowtls" then "SS2022 + ShadowTLS（旧版）"
           else "SS2022" end) + " 端口 " + (.port|tostring)] | join(" / "))
      ' <<<"$incoming"
      cat <<'EOF'
  1. 保留这台服务器上的用户，跳过备份用户（推荐）
  2. 使用备份用户覆盖同名用户（原客户端配置可能失效）
  3. 把备份用户作为新用户导入（重新填写名称和端口）
  0. 返回，不执行任何恢复
EOF
      prompt_migration_choice '请选择 [1]：' 1 '^[0-3]$' || { MIGRATION_MERGE_CANCELLED=true; rm -f -- "$normalized"; return 1; }; choice="$MIGRATION_CHOICE"
      case "$choice" in
        1) user_map="$(jq -c --arg key "$source_name" --arg value "$source_name" '. + {($key):$value}' <<<"$user_map")"; migration_update_json_file "$output" '.merge_summary.users.skipped += 1' || return 1; continue;;
        2) action=replaced; replace_name="$source_name";;
        3) action=renamed; prompt_migration_user_reconfigure "$incoming" "$output" "" "$normalized" || { rm -f -- "$normalized"; return 1; }; candidate="$MIGRATION_CONFIGURED_ENTITY";;
        0) MIGRATION_MERGE_CANCELLED=true; rm -f -- "$normalized"; return 1;;
      esac
    fi
    if migration_user_conflict "$output" "$candidate" "$replace_name" "$normalized"; then
      printf '\n备份中的用户 %s 暂时无法导入：%s\n' "$source_name" "$MIGRATION_CONFLICT_REASON"
      cat <<'EOF'
  1. 修改名称或端口后继续导入
  2. 不导入这个用户（推荐）
  0. 返回，不执行任何恢复
EOF
      prompt_migration_choice '请选择 [2]：' 2 '^[0-2]$' || { MIGRATION_MERGE_CANCELLED=true; rm -f -- "$normalized"; return 1; }; choice="$MIGRATION_CHOICE"
      case "$choice" in
        1) action=renamed; replace_name=""; prompt_migration_user_reconfigure "$incoming" "$output" "" "$normalized" || { rm -f -- "$normalized"; return 1; }; candidate="$MIGRATION_CONFIGURED_ENTITY";;
        2) user_map="$(jq -c --arg key "$source_name" --arg value "" '. + {($key):$value}' <<<"$user_map")"; migration_update_json_file "$output" '.merge_summary.users.skipped += 1' || return 1; continue;;
        0) MIGRATION_MERGE_CANCELLED=true; rm -f -- "$normalized"; return 1;;
      esac
    fi
    final_name="$(jq -r '.name' <<<"$candidate")"
    user_map="$(jq -c --arg key "$source_name" --arg value "$final_name" '. + {($key):$value}' <<<"$user_map")"
    usage="$(jq -c --arg name "$source_name" 'first(.nfuse_usage[]? | select(.name == $name)) // null' "$source")"
    if [[ "$action" == replaced ]]; then
      SB_JQ_USER="$candidate" migration_update_json_file "$output" --arg name "$source_name" --arg final "$final_name" --argjson usage "$usage" '
        ($ENV.SB_JQ_USER | fromjson) as $user |
        .state.users |= map(if .name == $name then $user else . end) |
        .nfuse_usage = [.nfuse_usage[] | select(.name != $name and .name != $final)] |
        (if $usage == null then . else .nfuse_usage += [($usage | .name=$final)] end) |
        .merge_summary.users.replaced += 1
      ' || { rm -f -- "$normalized"; return 1; }
    else
      SB_JQ_USER="$candidate" migration_update_json_file "$output" --arg final "$final_name" --argjson usage "$usage" --arg action "$action" '
        ($ENV.SB_JQ_USER | fromjson) as $user |
        .state.users += [$user] |
        .nfuse_usage = [.nfuse_usage[] | select(.name != $final)] |
        (if $usage == null then . else .nfuse_usage += [($usage | .name=$final)] end) |
        if $action == "renamed" then .merge_summary.users.renamed += 1 else .merge_summary.users.imported += 1 end
      ' || { rm -f -- "$normalized"; return 1; }
    fi
  done 3< <(jq -c '.state.users[]' "$source")

  while IFS= read -r incoming <&3; do
    [[ -n "$incoming" ]] || continue
    split_name="$(jq -r '.name' <<<"$incoming")"; candidate="$incoming"; action=imported; replace_name=""
    preset_name="$(jq -r '.outbound_preset // ""' <<<"$candidate")"
    if [[ -n "$preset_name" ]]; then
      mapped_preset="$(jq -r --arg key "$preset_name" '.[$key] // ""' <<<"$outbound_preset_map")"
      if [[ -n "$mapped_preset" ]]; then candidate="$(jq -c --arg preset "$mapped_preset" '.outbound_preset=$preset' <<<"$candidate")"; else candidate="$(jq -c 'del(.outbound_preset)' <<<"$candidate")"; fi
    fi
    preset_name="$(jq -r '.rule_preset // ""' <<<"$candidate")"
    if [[ -n "$preset_name" ]]; then
      mapped_preset="$(jq -r --arg key "$preset_name" '.[$key] // ""' <<<"$rule_preset_map")"
      if [[ -n "$mapped_preset" ]]; then candidate="$(jq -c --arg preset "$mapped_preset" '.rule_preset=$preset' <<<"$candidate")"; else candidate="$(jq -c 'del(.rule_preset)' <<<"$candidate")"; fi
    fi
    scope="$(jq -r '.scope // "all"' <<<"$candidate")"
    if [[ "$scope" == user ]]; then
      scope_user="$(jq -r '.user // ""' <<<"$candidate")"
      mapped_user="$(jq -r --arg key "$scope_user" 'if has($key) then .[$key] else $key end' <<<"$user_map")"
      if [[ -z "$mapped_user" ]] || ! jq -e --arg name "$mapped_user" '.state.users[]? | select(.name == $name)' "$output" >/dev/null; then
      printf '\n已跳过分流 %s：它指定的用户 %s 没有导入。\n' "$split_name" "$scope_user"
        migration_update_json_file "$output" '.merge_summary.splits.skipped += 1' || return 1
        continue
      fi
      candidate="$(jq -c --arg user "$mapped_user" '.user=$user' <<<"$candidate")"
    fi
    if jq -e --arg name "$split_name" '.state.splits[]? | select(.name == $name)' "$output" >/dev/null; then
      printf '\n发现同名分流：%s\n' "$split_name"
      cat <<'EOF'
  1. 保留这台服务器上的分流，跳过备份分流（推荐）
  2. 使用备份分流覆盖同名分流
  3. 把备份分流作为新分流导入（需要重新命名）
  0. 返回，不执行任何恢复
EOF
      prompt_migration_choice '请选择 [1]：' 1 '^[0-3]$' || { MIGRATION_MERGE_CANCELLED=true; rm -f -- "$normalized"; return 1; }; choice="$MIGRATION_CHOICE"
      case "$choice" in
        1) migration_update_json_file "$output" '.merge_summary.splits.skipped += 1' || return 1; continue;;
        2) action=replaced; replace_name="$split_name";;
        3) action=renamed; prompt_migration_split_reconfigure "$candidate" "$output" "" "$normalized" || { rm -f -- "$normalized"; return 1; }; candidate="$MIGRATION_CONFIGURED_ENTITY";;
        0) MIGRATION_MERGE_CANCELLED=true; rm -f -- "$normalized"; return 1;;
      esac
    fi
    if migration_split_conflict "$output" "$candidate" "$replace_name" "$normalized"; then
      printf '\n备份中的分流 %s 暂时无法导入：%s\n' "$split_name" "$MIGRATION_CONFLICT_REASON"
      cat <<'EOF'
  1. 修改名称后继续导入
  2. 不导入这个分流（推荐）
  0. 返回，不执行任何恢复
EOF
      prompt_migration_choice '请选择 [2]：' 2 '^[0-2]$' || { MIGRATION_MERGE_CANCELLED=true; rm -f -- "$normalized"; return 1; }; choice="$MIGRATION_CHOICE"
      case "$choice" in
        1) action=renamed; replace_name=""; prompt_migration_split_reconfigure "$candidate" "$output" "" "$normalized" || { rm -f -- "$normalized"; return 1; }; candidate="$MIGRATION_CONFIGURED_ENTITY";;
        2) migration_update_json_file "$output" '.merge_summary.splits.skipped += 1' || return 1; continue;;
        0) MIGRATION_MERGE_CANCELLED=true; rm -f -- "$normalized"; return 1;;
      esac
    fi
    candidate="$(normalize_split_runtime_tags_json "$candidate")" || { rm -f -- "$normalized"; return 1; }
    if [[ "$action" == replaced ]]; then
      SB_JQ_SPLIT="$candidate" migration_update_json_file "$output" --arg name "$split_name" '
        ($ENV.SB_JQ_SPLIT | fromjson) as $split |
        .state.splits |= map(if .name == $name then $split else . end) | .merge_summary.splits.replaced += 1
      ' || { rm -f -- "$normalized"; return 1; }
    else
      SB_JQ_SPLIT="$candidate" migration_update_json_file "$output" --arg action "$action" '
        ($ENV.SB_JQ_SPLIT | fromjson) as $split |
        .state.splits += [$split] |
        if $action == "renamed" then .merge_summary.splits.renamed += 1 else .merge_summary.splits.imported += 1 end
      ' || { rm -f -- "$normalized"; return 1; }
    fi
  done 3< <(jq -c '.state.splits[]' "$source")
  rm -f -- "$normalized"
  validate_migration_payload_structure "$output"
}

prepare_migration_effective_payload() {
  local source="$1" output="$2"
  select_migration_restore_mode || return 1
  if [[ "$MIGRATION_RESTORE_MODE" == merge ]]; then
    if ! build_merge_migration_payload "$source" "$output"; then
      [[ "${MIGRATION_MERGE_CANCELLED:-false}" == true ]] && { echo '已取消合并，未修改服务器。'; return 1; }
      die "无法生成恢复方案，服务器尚未被修改。请根据上方提示处理后重试"
    fi
  else
    jq '
      (.state.users | map(.name)) as $managed_names |
      . + {restore_mode:"replace"} |
      .nfuse_usage = [.nfuse_usage[] as $account | select($managed_names | index($account.name)) | $account]
    ' "$source" > "$output" || return 1
    chmod 600 "$output"
  fi
}

prepare_migration_payload_files() {
  local bundle="$1" source_payload="$2" payload="$3"
  decrypt_migration_backup "$bundle" "$source_payload" || {
    rm -f "$source_payload" "$payload"
    MENU_RETURNED=true
    return 1
  }
  normalize_migration_payload_schema "$source_payload" || {
    rm -f "$source_payload" "$payload"
    die "迁移包中的旧数据无法安全升级"
  }
  validate_migration_payload_structure "$source_payload" || {
    rm -f "$source_payload" "$payload"
    die "迁移数据结构无效"
  }
  if ! prepare_migration_effective_payload "$source_payload" "$payload"; then
    rm -f "$source_payload" "$payload"
    return 1
  fi
}

current_state_owns_tag() {
  local tag="$1" rows split runtime_tag
  jq -e --arg tag "$tag" '
    any(.users[]?;
      . as $user |
      (if (.endpoints | type) == "array" then .endpoints
       else [{protocol:(.protocol // "ss2022"),transport:(.transport // "shadowtls")}] end) as $endpoints |
      ($endpoints | any(.protocol == "ss2022" and .transport == "shadowtls")) as $has_legacy |
      any($endpoints[];
        if .protocol == "anytls" then $tag==("anytls-"+$user.name)
        elif .transport == "shadowtls" then
          ($tag==("st-"+$user.name) or $tag==("ss-"+$user.name) or $tag==("ss-udp-"+$user.name))
        elif $has_legacy then $tag==("ss-direct-"+$user.name)
        else $tag==("ss-"+$user.name) end)) or
    any(.splits[]?;
      $tag==(.outbound_tag // ("managed-out-"+.name)) or
      $tag==(.rule_set_tag // ("managed-split-"+.name)) or
      $tag==("managed-transport-"+.name) or
      $tag==(.runtime_outbound_tag // "") or
      $tag==(.runtime_rule_tag // "") or
      $tag==(.runtime_transport_tag // ""))
  ' "$STATE_FILE" >/dev/null && return 0
  rows="$(jq -c '.splits[]?' "$STATE_FILE")" || return 1
  while IFS= read -r split; do
    [[ -n "$split" ]] || continue
    runtime_tag="$(split_runtime_rule_tag_from_json "$split")" || return 1
    [[ "$runtime_tag" != "$tag" ]] || return 0
    runtime_tag="$(split_runtime_out_tag_from_json "$split")" || return 1
    [[ "$runtime_tag" != "$tag" ]] || return 0
    runtime_tag="$(split_runtime_transport_tag_from_json "$split")" || return 1
    [[ "$runtime_tag" != "$tag" ]] || return 0
  done <<<"$rows"
  return 1
}

add_migration_conflict() {
  MIGRATION_CONFLICTS[${#MIGRATION_CONFLICTS[@]}]="$1"
}

collect_migration_conflicts() {
  local payload="$1" normalized user name port tag split out_tag rule_tag protocol transport_tag endpoint has_legacy
  local -a tags
  MIGRATION_CONFLICTS=()
  if ! validate_migration_payload_structure "$payload"; then
    add_migration_conflict "迁移数据结构、用户名称或端口存在异常"; return 0
  fi
  normalized="$(mktemp /tmp/sb-migration-config.XXXXXX)"
  register_temp_path "$normalized"
  if ! "$SINGBOX_BIN" format -c "$SINGBOX_CONFIG" > "$normalized"; then
    rm -f "$normalized"; add_migration_conflict "无法读取目标 sing-box 配置"; return 0
  fi
  while IFS= read -r user; do
    name="$(jq -r '.name' <<<"$user")"
    has_legacy=false
    jq -e 'any(.endpoints[]?; .protocol == "ss2022" and .transport == "shadowtls")' <<<"$user" >/dev/null && has_legacy=true
    if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$ ]]; then
      add_migration_conflict "用户名不符合规则：$name"; continue
    fi
    while IFS= read -r endpoint; do
      port="$(jq -r '.port' <<<"$endpoint")"
      protocol="$(jq -r '.protocol' <<<"$endpoint")"
      if port_is_listening "$port" && ! jq -e --argjson port "$port" '
        any(.users[]?; any(if (.endpoints | type) == "array" then .endpoints[] else {port:.port} end; .port==$port))
      ' "$STATE_FILE" >/dev/null; then
        add_migration_conflict "端口 $port 已被目标服务器上的其他服务监听"
      fi
      while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        current_state_owns_tag "$tag" || add_migration_conflict "端口 ${port} 已被其他连接配置占用（${tag}）"
      done < <(jq -r --argjson port "$port" '.inbounds[]? | select(.listen_port==$port) | (.tag//"")' "$normalized")
      if [[ "$protocol" == anytls ]]; then
        tags=("anytls-$name")
      elif [[ "$(jq -r '.transport // "shadowtls"' <<<"$endpoint")" == shadowtls ]]; then
        tags=("st-$name" "ss-$name" "ss-udp-$name")
      elif [[ "$has_legacy" == true ]]; then
        tags=("ss-direct-$name")
      else
        tags=("ss-$name")
      fi
      for tag in "${tags[@]}"; do
        if jq -e --arg tag "$tag" '.inbounds[]? | select(.tag==$tag)' "$normalized" >/dev/null && ! current_state_owns_tag "$tag"; then
          add_migration_conflict "连接名称已被其他配置占用：$tag"
        fi
      done
    done < <(jq -c '.endpoints[]' <<<"$user")
  done < <(jq -c '.state.users[]' "$payload")
  while IFS= read -r split; do
    out_tag="$(split_runtime_out_tag_from_json "$split")" || { add_migration_conflict "无法读取分流出口信息"; continue; }
    rule_tag="$(split_runtime_rule_tag_from_json "$split")" || { add_migration_conflict "无法读取分流规则信息"; continue; }
    protocol="$(jq -r '.upstream.protocol // ""' <<<"$split")"
    transport_tag="$(split_runtime_transport_tag_from_json "$split")" || { add_migration_conflict "无法读取分流连接信息"; continue; }
    for tag in "$out_tag" "$rule_tag"; do
      if [[ ! "$tag" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$ || "$tag" == direct ]]; then
        add_migration_conflict "出口名称或规则名称不符合规则：$tag"
      fi
    done
    if jq -e --arg out "$out_tag" '.outbounds[]? | select(.tag==$out)' "$normalized" >/dev/null &&
       ! current_state_owns_tag "$out_tag"; then
      add_migration_conflict "出口名称已被其他配置占用：$out_tag"
    fi
    if jq -e --arg tag "$rule_tag" '.route.rule_set[]? | select(.tag==$tag)' "$normalized" >/dev/null &&
       ! current_state_owns_tag "$rule_tag"; then
      add_migration_conflict "规则名称已被其他配置占用：$rule_tag"
    fi
    if [[ "$protocol" == ss_shadowtls ]] &&
       jq -e --arg tag "$transport_tag" '.outbounds[]? | select(.tag==$tag)' "$normalized" >/dev/null &&
       ! current_state_owns_tag "$transport_tag"; then
      add_migration_conflict "ShadowTLS 内部名称已被其他配置占用：$transport_tag"
    fi
  done < <(jq -c '.state.splits[]' "$payload")
  rm -f "$normalized"
}

preflight_migration_payload() {
  local payload="$1" conflict
  collect_migration_conflicts "$payload"
  if ((${#MIGRATION_CONFLICTS[@]}>0)); then
    printf '现在还不能恢复，共发现 %s 个问题：\n' "${#MIGRATION_CONFLICTS[@]}" >&2
    for conflict in "${MIGRATION_CONFLICTS[@]}"; do printf '  - %s\n' "$conflict" >&2; done
    return 1
  fi
}

migration_entity_change_rows() {
  local payload="$1" key="$2" entity_label="$3"
  jq -r --slurpfile current "$STATE_FILE" --arg key "$key" --arg entity_label "$entity_label" '
    ($current[0][$key] // []) as $old | (.state[$key] // []) as $new |
    ($old|map(.name)) as $old_names | ($new|map(.name)) as $new_names |
    (($new_names-$old_names)[] | ["新增",$entity_label,.] | @tsv),
    (($old_names-$new_names)[] | ["删除",$entity_label,.] | @tsv),
    (($new_names-($new_names-$old_names))[] as $name |
      ($old[]|select(.name==$name)) as $before | ($new[]|select(.name==$name)) as $after |
      select($before!=$after) | ["替换",$entity_label,$name] | @tsv)
  ' "$payload"
}

print_migration_preview() {
  local payload="$1" rows current_nfuse usage_rows conflict mode
  mode="$(jq -r '.restore_mode // "replace"' "$payload")"
  printf '\n恢复内容预览（此时尚未修改服务器）\n\n'
  printf '来源：%s｜创建时间：%s｜脚本版本：%s\n' \
    "$(jq -r '.source_hostname' "$payload")" "$(jq -r '.created_at' "$payload")" "$(jq -r '.script_version' "$payload")"
  if [[ "$mode" == merge ]]; then
    echo '恢复方式：合并到这台服务器（保留现有内容）'
    jq -r '
      .merge_summary as $s |
      "合并计划：用户新增 \($s.users.imported)、替换 \($s.users.replaced)、重命名 \($s.users.renamed)、跳过 \($s.users.skipped)；" +
      "分流新增 \($s.splits.imported)、替换 \($s.splits.replaced)、重命名 \($s.splits.renamed)、跳过 \($s.splits.skipped)；" +
      "预置出口新增 \($s.outbound_presets.imported)、自动改名 \($s.outbound_presets.renamed)、复用 \($s.outbound_presets.deduplicated)；" +
      "预置规则新增 \($s.rule_presets.imported)、自动改名 \($s.rule_presets.renamed)、复用 \($s.rule_presets.deduplicated)"
    ' "$payload"
  else
    echo '恢复方式：完全恢复成备份内容'
  fi
  printf '恢复前后：用户 %s → %s，分流 %s → %s，预置出口 %s → %s，预置规则 %s → %s\n\n' \
    "$(jq '.users|length' "$STATE_FILE")" "$(jq '.state.users|length' "$payload")" \
    "$(jq '.splits|length' "$STATE_FILE")" "$(jq '.state.splits|length' "$payload")" \
    "$(jq '.outbound_presets|length' "$STATE_FILE")" "$(jq '.state.outbound_presets|length' "$payload")" \
    "$(jq '.rule_presets|length' "$STATE_FILE")" "$(jq '.state.rule_presets|length' "$payload")"
  rows="$(migration_entity_change_rows "$payload" users 用户; migration_entity_change_rows "$payload" splits 分流; migration_entity_change_rows "$payload" outbound_presets 预置出口; migration_entity_change_rows "$payload" rule_presets 预置规则)"
  if [[ -n "$rows" ]]; then
    { printf '动作\t类型\t名称\n'; printf '%s\n' "$rows"; } | column -t -s $'\t'
  else
    echo '用户和分流内容无变化。'
  fi
  current_nfuse="$(nfuse list --json)"
  usage_rows="$(jq -r --argjson old "$current_nfuse" --slurpfile oldstate "$STATE_FILE" '
    def format_bytes:
      if . < 1048576 then (tostring)+" B"
      elif . < 1073741824 then (((./1048576*100|round)/100|tostring)+" MiB")
      else (((./1073741824*100|round)/100|tostring)+" GiB") end;
    (.nfuse_usage // []) as $new |
    (($old|map(.name)) + ($new|map(.name)) + ($oldstate[0].users|map(.name)) + (.state.users|map(.name)) | unique[]) as $name |
    ((($old[]?|select(.name==$name)|.used_bytes) // 0) +
     (($oldstate[0].users[]?|select(.name==$name)|.usage_offset_bytes) // 0)) as $before |
    ((($new[]?|select(.name==$name)|.used_bytes) // 0) +
     ((.state.users[]?|select(.name==$name)|.usage_offset_bytes) // 0)) as $after |
    select($before!=$after) |
    [$name,($before|format_bytes),($after|format_bytes)] | @tsv
  ' "$payload")"
  if [[ -n "$usage_rows" ]]; then
    printf '\n用户已用流量变化：\n'
    { printf '用户\t当前\t恢复后\n'; printf '%s\n' "$usage_rows"; } | column -t -s $'\t'
  fi
  collect_migration_conflicts "$payload"
  printf '\n安全检查：'
  if ((${#MIGRATION_CONFLICTS[@]}==0)); then echo '通过，可以继续恢复。'
  else
    printf '发现 %s 个问题，解决前不会修改服务器。\n' "${#MIGRATION_CONFLICTS[@]}"
    for conflict in "${MIGRATION_CONFLICTS[@]}"; do printf '  - %s\n' "$conflict"; done
  fi
}

preview_migration_backup() {
  local source_payload payload
  ensure_migration_crypto_dependencies || return 0
  prepare_core; need_cmd openssl
  select_migration_backup || return 0
  source_payload="$(mktemp /tmp/sb-user-preview-source.XXXXXX)"
  payload="$(mktemp /tmp/sb-user-preview.XXXXXX)"
  register_temp_path "$source_payload"
  register_temp_path "$payload"
  prepare_migration_payload_files "$SELECTED_MIGRATION_BACKUP" "$source_payload" "$payload" || return 0
  print_migration_preview "$payload"
  rm -f "$source_payload" "$payload"
}

remove_current_managed_data() {
  local name split nfuse_json split_names user_names
  nfuse_json="$(nfuse list --json)" || return 1
  jq -e 'type == "array"' <<<"$nfuse_json" >/dev/null || return 1
  split_names="$(jq -r '.splits[].name' "$STATE_FILE")" || return 1
  user_names="$(jq -r '.users[].name' "$STATE_FILE")" || return 1
  while IFS= read -r split; do
    [[ -n "$split" ]] || continue
    remove_split_config "$split" || return 1
  done <<<"$split_names"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    remove_user_inbounds "$name" || return 1
    if jq -e --arg name "$name" '.[] | select(.name == $name)' <<<"$nfuse_json" >/dev/null; then
      nfuse rm "$name" --cascade >/dev/null || return 1
    fi
  done <<<"$user_names"
  nfuse persist >/dev/null || return 1
}

write_migration_restore_report() {
  local payload="$1" package="$2" snapshot="$3" result="$4" failure_stage="${5:-}" dir report
  local package_sha source_hostname source_created_at source_script_version users splits nfuse_accounts mode merge_summary
  dir="${MIGRATION_REPORT_DIR:-/root/sb-user-manager-backups/reports}"
  install -d -m 700 "$dir" || return 1
  report="$dir/migration-restore-$(date '+%Y%m%d-%H%M%S-%N').json"
  package_sha="$(sha256sum "$package" | awk '{print $1}')" || return 1
  source_hostname="$(jq -r '.source_hostname' "$payload")" || return 1
  source_created_at="$(jq -r '.created_at' "$payload")" || return 1
  source_script_version="$(jq -r '.script_version' "$payload")" || return 1
  users="$(jq '.state.users|length' "$payload")" || return 1
  splits="$(jq '.state.splits|length' "$payload")" || return 1
  nfuse_accounts="$(jq '.nfuse_usage|length' "$payload")" || return 1
  mode="$(jq -r '.restore_mode // "replace"' "$payload")" || return 1
  merge_summary="$(jq -c '.merge_summary // null' "$payload")" || return 1
  if ! jq -n \
    --arg completed_at "$(date -Iseconds)" \
    --arg result "$result" \
    --arg package "$(basename "$package")" \
    --arg package_sha256 "$package_sha" \
    --arg source_hostname "$source_hostname" \
    --arg source_created_at "$source_created_at" \
    --arg source_script_version "$source_script_version" \
    --arg mode "$mode" \
    --arg snapshot "$snapshot" \
    --arg failure_stage "$failure_stage" \
    --argjson users "$users" \
    --argjson splits "$splits" \
    --argjson nfuse_accounts "$nfuse_accounts" \
    --argjson merge_summary "$merge_summary" \
    '{completed_at:$completed_at,result:$result,failure_stage:$failure_stage,package:$package,package_sha256:$package_sha256,
      source:{hostname:$source_hostname,created_at:$source_created_at,script_version:$source_script_version},
      mode:$mode,merge_summary:$merge_summary,
      restored:{users:$users,splits:$splits,nfuse_accounts:$nfuse_accounts},environment_snapshot:$snapshot}' > "$report"; then
    rm -f -- "$report"
    return 1
  fi
  if ! chmod 600 "$report"; then
    rm -f -- "$report"
    return 1
  fi
  MIGRATION_REPORT="$report"
  if ! prune_migration_reports "$MIGRATION_REPORT_RETENTION"; then
    log "提示：旧的恢复记录暂未能自动整理，不影响本次恢复结果"
  fi
}

migration_report_dir() {
  printf '%s' "${MIGRATION_REPORT_DIR:-/root/sb-user-manager-backups/reports}"
}

validate_migration_restore_report() {
  local report="$1"
  [[ -f "$report" ]] || return 1
  jq -e '
    (.completed_at|type=="string" and length>0) and
    (.result|type=="string" and length>0) and
    ((.failure_stage // "")|type=="string") and
    (.package|type=="string" and length>0) and
    (.package_sha256|type=="string" and test("^[0-9a-fA-F]{64}$")) and
    (.source|type=="object") and
    (.source.hostname|type=="string") and
    (.source.created_at|type=="string") and
    (.source.script_version|type=="string") and
    ((.mode // "replace") == "replace" or (.mode // "replace") == "merge") and
    ((.merge_summary // null) == null or (.merge_summary|type=="object")) and
    (.restored|type=="object") and
    (.restored.users|type=="number" and .>=0 and .==floor) and
    (.restored.splits|type=="number" and .>=0 and .==floor) and
    (.restored.nfuse_accounts|type=="number" and .>=0 and .==floor) and
    (.environment_snapshot|type=="string")
  ' "$report" >/dev/null 2>&1
}

migration_report_result_label() {
  case "$1" in
    success) printf '成功';;
    rolled_back) printf '失败，已回滚';;
    rollback_failed) printf '失败，回滚异常';;
    *) printf '未知结果：%s' "$1";;
  esac
}

migration_report_failure_label() {
  case "$1" in
    '') printf '无';;
    removing_current_data) printf '清理这台服务器原有的用户和分流';;
    writing_managed_state) printf '写入备份中的用户资料';;
    rebuilding_managed_data) printf '重新建立节点、分流和流量统计';;
    restoring_nfuse_usage) printf '恢复用户已用流量';;
    validating_singbox) printf '检查连接配置并启动服务';;
    auditing_consistency) printf '检查恢复结果';;
    *) printf '未知阶段：%s' "$1";;
  esac
}

load_migration_reports() {
  local dir file
  MIGRATION_REPORTS=()
  dir="$(migration_report_dir)"
  [[ -d "$dir" ]] || return 0
  while IFS= read -r file; do MIGRATION_REPORTS[${#MIGRATION_REPORTS[@]}]="$file"; done < <(
    find "$dir" -maxdepth 1 -type f -name 'migration-restore-*.json' -print | list_files_newest_first
  )
}

load_valid_migration_reports() {
  local report
  VALID_MIGRATION_REPORTS=()
  load_migration_reports
  ((${#MIGRATION_REPORTS[@]} > 0)) || return 0
  for report in "${MIGRATION_REPORTS[@]}"; do
    validate_migration_restore_report "$report" || continue
    VALID_MIGRATION_REPORTS[${#VALID_MIGRATION_REPORTS[@]}]="$report"
  done
}

prune_migration_reports() {
  local keep="$1" i failed=false
  [[ "$keep" =~ ^[0-9]+$ ]] || return 1
  load_valid_migration_reports
  ((${#VALID_MIGRATION_REPORTS[@]} > 0)) || return 0
  for ((i=keep; i<${#VALID_MIGRATION_REPORTS[@]}; i++)); do
    [[ -f "${VALID_MIGRATION_REPORTS[$i]}" && ! -L "${VALID_MIGRATION_REPORTS[$i]}" ]] || {
      failed=true
      continue
    }
    rm -f -- "${VALID_MIGRATION_REPORTS[$i]}" || failed=true
  done
  [[ "$failed" == false ]]
}

print_migration_reports() {
  local i file result
  load_migration_reports
  if ((${#MIGRATION_REPORTS[@]} == 0)); then echo '暂无恢复报告。'; return 1; fi
  for i in "${!MIGRATION_REPORTS[@]}"; do
    file="${MIGRATION_REPORTS[$i]}"
    if ! validate_migration_restore_report "$file"; then
      printf '  %d. 报告异常｜%s\n' "$((i+1))" "$(basename "$file")"
      continue
    fi
    result="$(migration_report_result_label "$(jq -r '.result' "$file")")"
    jq -r --argjson number "$((i+1))" --arg result "$result" '
      ((.mode // "replace") as $mode |
       "  \($number). \($result)｜" + (if $mode == "merge" then "合并导入" else "完全替换" end) + "｜\(.completed_at)｜来源：\(.source.hostname)"),
      "     最终用户 \(.restored.users)｜最终分流 \(.restored.splits)｜Nfuse \(.restored.nfuse_accounts)｜迁移包：\(.package)"
    ' "$file"
  done
}

select_migration_report() {
  print_migration_reports || return 1
  echo '  0. 返回上一级'
  read_numbered_index '请选择报告编号：' "${#MIGRATION_REPORTS[@]}" || return 1
  SELECTED_MIGRATION_REPORT="${MIGRATION_REPORTS[$SELECTED_INDEX]}"
}

show_migration_report_details() {
  local result failure mode_label
  select_migration_report || return 0
  validate_migration_restore_report "$SELECTED_MIGRATION_REPORT" || die "恢复报告格式异常，无法查看详情"
  result="$(migration_report_result_label "$(jq -r '.result' "$SELECTED_MIGRATION_REPORT")")"
  failure="$(migration_report_failure_label "$(jq -r '.failure_stage // ""' "$SELECTED_MIGRATION_REPORT")")"
  if [[ "$(jq -r '.mode // "replace"' "$SELECTED_MIGRATION_REPORT")" == merge ]]; then mode_label='合并导入'; else mode_label='完全替换'; fi
  jq -r --arg result "$result" --arg failure "$failure" --arg mode "$mode_label" --arg report "$SELECTED_MIGRATION_REPORT" '
    "\n恢复记录详情\n",
    "完成时间：\(.completed_at)",
    "执行结果：\($result)",
    "恢复方式：\($mode)",
    "失败阶段：\($failure)",
    "来源主机：\(.source.hostname)",
    "源端创建：\(.source.created_at)",
    "源端版本：\(.source.script_version)",
    "最终用户：\(.restored.users)",
    "最终分流：\(.restored.splits)",
    "流量记录：\(.restored.nfuse_accounts)",
    (if (.mode // "replace") == "merge" and (.merge_summary // null) != null then
      (.merge_summary as $s |
       "合并处理：用户新增 \($s.users.imported)、覆盖 \($s.users.replaced)、改名 \($s.users.renamed)、跳过 \($s.users.skipped)；" +
       "分流新增 \($s.splits.imported)、覆盖 \($s.splits.replaced)、改名 \($s.splits.renamed)、跳过 \($s.splits.skipped)；" +
       "预置出口新增 \($s.outbound_presets.imported)、改名 \($s.outbound_presets.renamed)、复用 \($s.outbound_presets.deduplicated)；" +
       "预置规则新增 \($s.rule_presets.imported)、改名 \($s.rule_presets.renamed)、复用 \($s.rule_presets.deduplicated)")
     else empty end),
    "迁移包：\(.package)",
    "备份文件校验值（SHA256）：\(.package_sha256)",
    "恢复前完整备份：\(.environment_snapshot)",
    "记录文件：" + $report
  ' "$SELECTED_MIGRATION_REPORT"
}

delete_migration_report() {
  local answer file
  select_migration_report || return 0
  file="$SELECTED_MIGRATION_REPORT"
  read -r -p "确认删除报告 $(basename "$file")？[y/N]：" answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo '已取消删除。'; return 0; }
  rm -f -- "$file"
  echo '恢复报告已删除。'
}

cleanup_migration_reports() {
  local keep answer i remove
  while true; do
    read -r -p '保留最近多少份恢复报告？[20]（输入 0 返回）：' keep
    [[ "$keep" != 0 ]] || return 0
    keep="${keep:-20}"
    [[ "$keep" =~ ^[1-9][0-9]?$|^100$ ]] && break
    echo '输入无效：保留数量必须位于 1-100，请重新输入。'
  done
  load_migration_reports
  remove=$((${#MIGRATION_REPORTS[@]}>keep ? ${#MIGRATION_REPORTS[@]}-keep : 0))
  printf '\n当前恢复报告：%s，保留：%s，删除：%s\n' "${#MIGRATION_REPORTS[@]}" "$keep" "$remove"
  ((remove>0)) || { echo '没有需要清理的旧报告。'; return 0; }
  read -r -p '确认永久删除超出保留数量的旧报告？请输入 CLEANUP：' answer
  [[ "$answer" == CLEANUP ]] || { echo '已取消清理。'; return 0; }
  for ((i=keep; i<${#MIGRATION_REPORTS[@]}; i++)); do rm -f -- "${MIGRATION_REPORTS[$i]}"; done
  printf '清理完成：删除恢复报告 %s 份。\n' "$remove"
}

migration_report_menu() {
  while true; do
    prepare_menu_screen
    cat <<'EOF'
恢复记录

1. 查看记录列表
2. 查看记录详情
3. 删除一条记录
4. 清理旧记录
0. 返回上一级
EOF
    read_menu_choice '请选择：' '0,1,2,3,4' '' '请输入 0-4 之间的数字' || return 0
    choice="$PROMPT_VALUE"
    case "$choice" in
      1) echo; print_migration_reports || true; pause_menu;;
      2) show_migration_report_details; pause_menu;;
      3) delete_migration_report; pause_menu;;
      4) cleanup_migration_reports; pause_menu;;
      0) return 0;;
    esac
  done
}

restore_migration_backup() {
  local source_payload payload answer confirm_token current_users current_splits environment_backup name used rollback_result restore_stage
  local state_tmp usage_rows nfuse_json
  ensure_migration_crypto_dependencies || return 0
  prepare_core || return 1
  need_cmd openssl
  select_migration_backup || return 0
  source_payload="$(mktemp /tmp/sb-user-restore-source.XXXXXX)" || die "无法创建迁移解密临时文件"
  payload="$(mktemp /tmp/sb-user-restore.XXXXXX)" || { rm -f -- "$source_payload"; die "无法创建迁移计划临时文件"; }
  register_temp_path "$source_payload"
  register_temp_path "$payload"
  prepare_migration_payload_files "$SELECTED_MIGRATION_BACKUP" "$source_payload" "$payload" || return 0
  rm -f -- "$source_payload"
  print_migration_preview "$payload"
  if ! preflight_migration_payload "$payload"; then rm -f "$payload"; die "安全检查未通过，服务器尚未被修改。请先处理上方列出的问题"; fi
  current_users="$(jq '.users|length' "$STATE_FILE")"; current_splits="$(jq '.splits|length' "$STATE_FILE")"
  printf '\n最终状态：用户 %s，分流 %s，来源 %s，创建于 %s。\n' \
    "$(jq '.state.users|length' "$payload")" "$(jq '.state.splits|length' "$payload")" \
    "$(jq -r '.source_hostname' "$payload")" "$(jq -r '.created_at' "$payload")"
  if [[ "$MIGRATION_RESTORE_MODE" == replace ]] && ((current_users>0 || current_splits>0)); then
    printf '这台服务器已有用户 %s 个、分流 %s 条；继续后会删除它们并改用备份内容。其他手工配置不会被修改。\n' "$current_users" "$current_splits"
    confirm_token=RESTORE
  elif [[ "$MIGRATION_RESTORE_MODE" == merge ]]; then
    printf '合并会保留上方没有标记为「替换」的现有内容，并加入备份中的内容。\n'
    confirm_token=MERGE
  else
    confirm_token=RESTORE
  fi
  read -r -p "确认继续？请输入 ${confirm_token}：" answer
  [[ "$answer" == "$confirm_token" ]] || { rm -f "$payload"; echo '已取消恢复。'; return 0; }
  if ! ensure_safe_ssh_for_singbox_restart; then
    rm -f -- "$payload"
    return 0
  fi
  if ! create_environment_backup; then
    rm -f -- "$payload"
    die "无法创建恢复前的安全备份，因此没有修改任何数据"
  fi
  environment_backup="$ENV_BACKUP"
  if ! start_managed_operation "restore-migration:$(basename "$SELECTED_MIGRATION_BACKUP")"; then
    rm -f -- "$payload"
    die "无法开启安全恢复保护，因此没有修改任何数据"
  fi
  restore_stage=removing_current_data
  rollback_migration_restore() {
    local rc="${1:-$?}"
    trap - ERR
    clear_signal_rollback
    log "恢复失败，正在自动还原恢复前的数据：$environment_backup"
    rollback_result=rolled_back
    if ! restore_environment_backup "$environment_backup"; then
      rollback_result=rollback_failed
      log "严重错误：自动还原失败。请停止继续操作，并保留完整备份：$environment_backup"
    elif ! clear_operation_transaction; then
      rollback_result=rollback_failed
      log "严重错误：环境已回滚，但无法清除事务日志：$TRANSACTION_JOURNAL"
    fi
    write_migration_restore_report "$payload" "$SELECTED_MIGRATION_BACKUP" "$environment_backup" "$rollback_result" "$restore_stage" || true
    rm -f "$payload"
    return "$rc"
  }
  fail_migration_restore() {
    local message="$1"
    rollback_migration_restore 1 || true
    die "${message}。脚本已尝试还原到操作前状态，请查看上方结果"
  }
  trap rollback_migration_restore ERR
  set_signal_rollback rollback_migration_restore
  if ! remove_current_managed_data; then
    fail_migration_restore "无法安全清理这台服务器原有的用户和分流"
  fi
  restore_stage=writing_managed_state
  state_tmp="$(mktemp "$(dirname "$STATE_FILE")/.migration-state.XXXXXX")" ||
    fail_migration_restore "无法创建迁移状态临时文件"
  register_temp_path "$state_tmp"
  if ! jq '.state' "$payload" > "$state_tmp"; then
    rm -f -- "$state_tmp"
    fail_migration_restore "无法生成迁移状态"
  fi
  if ! chmod 600 "$state_tmp"; then
    rm -f -- "$state_tmp"
    fail_migration_restore "无法设置迁移状态权限"
  fi
  chown --reference="$STATE_FILE" "$state_tmp" 2>/dev/null || true
  if ! mv -- "$state_tmp" "$STATE_FILE"; then
    rm -f -- "$state_tmp"
    fail_migration_restore "无法写入迁移状态"
  fi
  if ! (init_state); then
    fail_migration_restore "初始化迁移状态失败"
  fi
  restore_stage=rebuilding_managed_data
  if ! (repair_consistency >/dev/null); then
    fail_migration_restore "无法重新建立用户连接、分流和流量统计"
  fi
  restore_stage=restoring_nfuse_usage
  usage_rows="$(jq -r '
    .state.users[] as $user |
    first(.nfuse_usage[]? | select(.name == $user.name)) as $usage |
    select($usage != null) |
    [$user.name,($usage.used_bytes|tostring),((($user.metered // ($user.limit_gib != null)))|tostring)] | @tsv
  ' "$payload")" ||
    fail_migration_restore "无法读取迁移包中的 Nfuse 用量"
  nfuse_json="$(nfuse list --json)" || fail_migration_restore "无法读取恢复后的流量记录"
  if ! jq -e 'type == "array"' <<<"$nfuse_json" >/dev/null; then
    fail_migration_restore "恢复后的 Nfuse 数据结构无效"
  fi
  while IFS=$'\t' read -r name used metered; do
    [[ -n "$name" && "$used" =~ ^[0-9]+$ ]] || continue
    if ! jq -e --arg name "$name" '.[] | select(.name == $name)' <<<"$nfuse_json" >/dev/null; then
      fail_migration_restore "恢复后缺少用户 $name 的流量记录"
    fi
    if [[ "$metered" == true ]]; then
      if ! nfuse set-usage "$name" "$used" >/dev/null; then
        fail_migration_restore "无法恢复 Nfuse 已用流量：$name"
      fi
    elif ! state_add_usage_offset "$name" "$used"; then
      fail_migration_restore "无法衔接自用用户的累计用量：$name"
    fi
  done <<<"$usage_rows"
  if ! nfuse persist >/dev/null; then
    fail_migration_restore "无法持久化恢复后的 Nfuse 数据"
  fi
  restore_stage=validating_singbox
  if ! check_singbox_and_restart; then
    fail_migration_restore "恢复后的 sing-box 配置或服务校验失败"
  fi
  restore_stage=auditing_consistency
  if ! audit_consistency; then
    fail_migration_restore "无法检查恢复后的服务和配置"
  fi
  if ((AUDIT_ISSUES != 0)); then
    fail_migration_restore "恢复后的服务或配置仍有问题"
  fi
  if ! finish_managed_operation; then
    fail_migration_restore "恢复结果未能安全保存"
  fi
  if ! write_migration_restore_report "$payload" "$SELECTED_MIGRATION_BACKUP" "$environment_backup" success; then
    rm -f -- "$payload"
    log "迁移数据已恢复，但恢复报告写入失败"
    return 1
  fi
  rm -f "$payload"
  log "恢复完成；操作前完整备份：$environment_backup"
  log "本次恢复结果：$MIGRATION_REPORT"
}

delete_migration_backup() {
  local answer file
  select_migration_backup || return 0
  file="$SELECTED_MIGRATION_BACKUP"
  read -r -p "确认删除 $(basename "$file")？[y/N]：" answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo '已取消删除。'; return 0; }
  rm -f -- "$file"
  echo '迁移备份已删除。'
}

cleanup_backup_retention() {
  local keep_migration keep_snapshots answer i remove_migration remove_snapshots path
  prepare_core
  while true; do
    read -r -p '保留最近多少份单文件迁移备份？[10]（输入 0 返回）：' keep_migration
    [[ "$keep_migration" != 0 ]] || return 0
    keep_migration="${keep_migration:-10}"
    [[ "$keep_migration" =~ ^[1-9][0-9]?$|^100$ ]] && break
    echo '输入无效：迁移备份保留数量必须位于 1-100，请重新输入。'
  done
  while true; do
    read -r -p '保留最近多少份操作前完整备份？[5]（输入 0 返回）：' keep_snapshots
    [[ "$keep_snapshots" != 0 ]] || return 0
    keep_snapshots="${keep_snapshots:-5}"
    [[ "$keep_snapshots" =~ ^[1-9][0-9]?$|^100$ ]] && break
    echo '输入无效：操作前完整备份保留数量必须位于 1-100，请重新输入。'
  done
  load_migration_backups
  load_environment_snapshot_candidates
  VERIFIED_ENVIRONMENT_SNAPSHOTS=()
  if ((${#ENVIRONMENT_SNAPSHOTS[@]} > 0)); then
    for path in "${ENVIRONMENT_SNAPSHOTS[@]}"; do
      verify_environment_backup "$path" >/dev/null 2>&1 || continue
      VERIFIED_ENVIRONMENT_SNAPSHOTS[${#VERIFIED_ENVIRONMENT_SNAPSHOTS[@]}]="$path"
    done
  fi
  if ((${#VERIFIED_ENVIRONMENT_SNAPSHOTS[@]} > 0)); then
    ENVIRONMENT_SNAPSHOTS=("${VERIFIED_ENVIRONMENT_SNAPSHOTS[@]}")
  else
    ENVIRONMENT_SNAPSHOTS=()
  fi
  remove_migration=$((${#MIGRATION_BACKUPS[@]}>keep_migration ? ${#MIGRATION_BACKUPS[@]}-keep_migration : 0))
  remove_snapshots=$((${#ENVIRONMENT_SNAPSHOTS[@]}>keep_snapshots ? ${#ENVIRONMENT_SNAPSHOTS[@]}-keep_snapshots : 0))
  printf '\n当前单文件迁移备份：%s，保留：%s，删除：%s\n' "${#MIGRATION_BACKUPS[@]}" "$keep_migration" "$remove_migration"
  printf '当前操作前完整备份：%s，保留：%s，删除：%s\n' "${#ENVIRONMENT_SNAPSHOTS[@]}" "$keep_snapshots" "$remove_snapshots"
  if ((remove_migration==0 && remove_snapshots==0)); then echo '没有需要清理的旧备份。'; return 0; fi
  read -r -p '确认永久删除超出保留数量的旧备份？请输入 CLEANUP：' answer
  [[ "$answer" == CLEANUP ]] || { echo '已取消清理。'; return 0; }
  for ((i=keep_migration; i<${#MIGRATION_BACKUPS[@]}; i++)); do rm -f -- "${MIGRATION_BACKUPS[$i]}"; done
  for ((i=keep_snapshots; i<${#ENVIRONMENT_SNAPSHOTS[@]}; i++)); do
    verify_environment_backup "${ENVIRONMENT_SNAPSHOTS[$i]}" >/dev/null 2>&1 || continue
    rm -rf -- "${ENVIRONMENT_SNAPSHOTS[$i]}"
  done
  printf '清理完成：删除迁移备份 %s 份、操作前完整备份 %s 份。\n' "$remove_migration" "$remove_snapshots"
}
