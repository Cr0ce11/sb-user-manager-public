
validate_split_name() {
  [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$ ]] || die "分流规则名只能包含字母、数字、下划线和连字符，长度 1-32"
}

validate_preset_name() {
  [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$ ]] ||
    die "预置名称只能包含字母、数字、下划线和连字符，长度 1-32"
}

validate_upstream_port() {
  [[ "$1" =~ ^[0-9]+$ ]] || die "出口服务器端口必须是数字"
  ((10#$1 >= 1 && 10#$1 <= 65535)) || die "出口服务器端口必须位于 1-65535"
}

split_rule_format() {
  if [[ "$1" =~ \.srs([?#].*)?$ ]]; then printf 'binary'
  elif [[ "$1" =~ \.json([?#].*)?$ ]]; then printf 'source'
  else return 1
  fi
}

is_public_rule_set_address() {
  local address="$1"
  command -v python3 >/dev/null 2>&1 || return 1
  SB_RULE_SET_ADDRESS="$address" python3 - <<'PY'
import ipaddress
import os
import sys

try:
    address = ipaddress.ip_address(os.environ["SB_RULE_SET_ADDRESS"])
except ValueError:
    sys.exit(1)
sys.exit(0 if address.is_global else 1)
PY
}

rule_set_url_host() {
  local url="$1"
  command -v python3 >/dev/null 2>&1 || return 1
  SB_RULE_SET_URL="$url" python3 - <<'PY'
from urllib.parse import urlsplit
import os
import sys

try:
    parsed = urlsplit(os.environ["SB_RULE_SET_URL"])
    if parsed.scheme != "https" or parsed.username is not None or parsed.password is not None:
        raise ValueError
    parsed.port
    host = parsed.hostname
    if not host or any(ord(char) < 0x20 for char in host):
        raise ValueError
except (ValueError, UnicodeError):
    sys.exit(1)
print(host.rstrip(".").lower())
PY
}

validate_public_rule_set_url() {
  local url="$1" host resolved address
  host="$(rule_set_url_host "$url")" || return 1
  [[ -n "$host" && "$host" != localhost && "$host" != *.localhost && "$host" != *.local ]] || return 1
  if [[ "$host" =~ ^[0-9.]+$ || "$host" == *:* ]]; then
    is_public_rule_set_address "$host" || return 1
    return 0
  fi
  command -v getent >/dev/null 2>&1 || return 1
  resolved="$(getent ahosts "$host" 2>/dev/null | awk '{print $1}' | sort -u)" || return 1
  [[ -n "$resolved" ]] || return 1
  while IFS= read -r address; do
    is_public_rule_set_address "$address" || return 1
  done <<<"$resolved"
}

validate_remote_rule_set() {
  validate_public_rule_set_url "$1" ||
    die "远程规则集地址必须使用 HTTPS，且不能指向本机或内网地址"
  check_rule_set_with_binary "$SINGBOX_BIN" "$1" ||
    die "远程规则集无法通过当前 sing-box 检查，请确认地址、格式和版本兼容性"
}

split_exists() { jq -e --arg name "$1" '.splits[]? | select(.name == $name)' "$STATE_FILE" >/dev/null; }
outbound_preset_exists() { jq -e --arg name "$1" '.outbound_presets[]? | select(.name == $name)' "$STATE_FILE" >/dev/null; }
rule_preset_exists() { jq -e --arg name "$1" '.rule_presets[]? | select(.name == $name)' "$STATE_FILE" >/dev/null; }
split_tag() {
  local name="$1" configured="${2:-}"
  if [[ -n "$configured" ]]; then printf '%s' "$configured"; else printf 'managed-split-%s' "$name"; fi
}
split_out_tag() {
  local name="$1" configured="${2:-}"
  if [[ -n "$configured" ]]; then printf '%s' "$configured"; else printf 'managed-out-%s' "$name"; fi
}
split_transport_tag() { printf 'managed-transport-%s' "$1"; }

# 预置名称是用户可见标识，运行标签只在配置内部使用。固定摘要既避免超长，
# 也让同一预置被多条分流引用时始终指向同一个 sing-box 对象。
stable_managed_tag() {
  local kind="$1" name="$2" prefix digest
  case "$kind" in
    rule) prefix='mpr-';;
    outbound) prefix='mpo-';;
    transport) prefix='mpt-';;
    split-out) prefix='mso-';;
    *) return 1;;
  esac
  digest="$(printf '%s' "${kind}:${name}" | sha256sum | awk '{print $1}')" || return 1
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s%s' "$prefix" "${digest:0:24}"
}

split_runtime_rule_tag_from_json() {
  local split="$1" name preset configured
  configured="$(jq -r '.runtime_rule_tag // ""' <<<"$split")" || return 1
  [[ -z "$configured" ]] || { printf '%s' "$configured"; return 0; }
  preset="$(jq -r '.rule_preset // ""' <<<"$split")" || return 1
  if [[ -n "$preset" ]]; then
    stable_managed_tag rule "$preset"
    return $?
  fi
  name="$(jq -r '.name' <<<"$split")" || return 1
  configured="$(jq -r '.rule_set_tag // ""' <<<"$split")" || return 1
  split_tag "$name" "$configured"
}

split_runtime_out_tag_from_json() {
  local split="$1" name preset configured
  configured="$(jq -r '.runtime_outbound_tag // ""' <<<"$split")" || return 1
  [[ -z "$configured" ]] || { printf '%s' "$configured"; return 0; }
  preset="$(jq -r '.outbound_preset // ""' <<<"$split")" || return 1
  if [[ -n "$preset" ]]; then
    stable_managed_tag outbound "$preset"
    return $?
  fi
  name="$(jq -r '.name' <<<"$split")" || return 1
  configured="$(jq -r '.outbound_tag // ""' <<<"$split")" || return 1
  split_out_tag "$name" "$configured"
}

split_runtime_transport_tag_from_json() {
  local split="$1" name preset configured
  configured="$(jq -r '.runtime_transport_tag // ""' <<<"$split")" || return 1
  [[ -z "$configured" ]] || { printf '%s' "$configured"; return 0; }
  preset="$(jq -r '.outbound_preset // ""' <<<"$split")" || return 1
  if [[ -n "$preset" ]]; then
    stable_managed_tag transport "$preset"
    return $?
  fi
  name="$(jq -r '.name' <<<"$split")" || return 1
  split_transport_tag "$name"
}

normalize_split_runtime_tags_json() {
  local split="$1" rule_preset outbound_preset rule_tag out_tag transport_tag
  rule_preset="$(jq -r '.rule_preset // ""' <<<"$split")" || return 1
  outbound_preset="$(jq -r '.outbound_preset // ""' <<<"$split")" || return 1
  if [[ -n "$rule_preset" ]]; then
    rule_tag="$(stable_managed_tag rule "$rule_preset")" || return 1
    split="$(jq -c --arg tag "$rule_tag" '.runtime_rule_tag=$tag' <<<"$split")" || return 1
  fi
  if [[ -n "$outbound_preset" ]]; then
    out_tag="$(stable_managed_tag outbound "$outbound_preset")" || return 1
    transport_tag="$(stable_managed_tag transport "$outbound_preset")" || return 1
    split="$(jq -c --arg out "$out_tag" --arg transport "$transport_tag" '.runtime_outbound_tag=$out | .runtime_transport_tag=$transport' <<<"$split")" || return 1
  fi
  printf '%s' "$split"
}

validate_outbound_tag() {
  [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$ ]] || die "出口名称只能包含字母、数字、下划线和连字符，长度 1-32"
  [[ "$1" != direct ]] || die "出口名称 direct 为系统保留名称，请换一个名称"
}

stored_split_out_tag() {
  local name="$1"
  jq -r --arg name "$name" '.splits[] | select(.name == $name) | (.outbound_tag // ("managed-out-" + .name))' "$STATE_FILE"
}

stored_split_rule_tag() {
  local name="$1"
  jq -r --arg name "$name" '.splits[] | select(.name == $name) | (.rule_set_tag // ("managed-split-" + .name))' "$STATE_FILE"
}

remove_split_config() {
  local name="$1" split tag out_tag transport_tag stored_tag stored_out stored_transport
  split="$(jq -ec --arg name "$name" '.splits[] | select(.name == $name)' "$STATE_FILE")" || return 1
  tag="$(split_runtime_rule_tag_from_json "$split")" || return 1
  out_tag="$(split_runtime_out_tag_from_json "$split")" || return 1
  transport_tag="$(split_runtime_transport_tag_from_json "$split")" || return 1
  stored_tag="$(stored_split_rule_tag "$name")" || return 1
  stored_out="$(stored_split_out_tag "$name")" || return 1
  stored_transport="$(split_transport_tag "$name")"
  rewrite_singbox_config '
    .route.rules = [(.route.rules // [])[] | select(((.rule_set // "") == $tag or (.rule_set // "") == $stored_tag) | not)] |
    .route.rule_set = [(.route.rule_set // [])[] | select((.tag == $tag or .tag == $stored_tag) | not)] |
    .outbounds = [(.outbounds // [])[] |
      select((.tag == $out_tag or .tag == $transport_tag or .tag == $stored_out or .tag == $stored_transport) | not)]
  ' --arg tag "$tag" --arg stored_tag "$stored_tag" --arg out_tag "$out_tag" --arg transport_tag "$transport_tag" \
    --arg stored_out "$stored_out" --arg stored_transport "$stored_transport"
}

build_split_outbounds() {
  local name="$1" upstream="$2" out_tag="$3" transport_tag="${4:-}" protocol
  protocol="$(jq -r '.protocol' <<<"$upstream")"
  [[ -n "$transport_tag" ]] || transport_tag="$(split_transport_tag "$name")"
  case "$protocol" in
    anytls)
      SB_JQ_UPSTREAM="$upstream" jq -cn --arg tag "$out_tag" '($ENV.SB_JQ_UPSTREAM | fromjson) as $u | [{type:"anytls",tag:$tag,server:$u.server,server_port:$u.server_port,password:$u.password,domain_resolver:"local",tls:{enabled:true,server_name:$u.sni,insecure:$u.insecure}}]'
      ;;
    shadowsocks)
      SB_JQ_UPSTREAM="$upstream" jq -cn --arg tag "$out_tag" '($ENV.SB_JQ_UPSTREAM | fromjson) as $u | [{type:"shadowsocks",tag:$tag,server:$u.server,server_port:$u.server_port,method:$u.method,password:$u.password,domain_resolver:"local"}]'
      ;;
    ss_shadowtls)
      SB_JQ_UPSTREAM="$upstream" jq -cn --arg tag "$out_tag" --arg transport "$transport_tag" '($ENV.SB_JQ_UPSTREAM | fromjson) as $u | [
        {type:"shadowsocks",tag:$tag,server:$u.server,server_port:$u.server_port,method:$u.method,password:$u.ss_password,detour:$transport},
        {type:"shadowtls",tag:$transport,server:$u.server,server_port:$u.server_port,version:3,password:$u.shadowtls_password,domain_resolver:"local",tls:{enabled:true,server_name:$u.sni,insecure:$u.insecure}}
      ]'
      ;;
    *) die "不支持的上游协议：$protocol";;
  esac
}

validate_upstream_json() {
  jq -e '
    (type == "object") and
    (.server | type == "string" and length > 0 and (test("[[:space:]]") | not)) and
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
    else false end
  ' <<<"$1" >/dev/null
}

validate_upstream_candidate() {
  local upstream="$1" name out_tag outbounds candidate
  validate_upstream_json "$upstream" || die "预置出口内容不完整或格式无效"
  name="preset-check-${BASHPID:-$$}"
  out_tag="${name}-out"
  outbounds="$(build_split_outbounds "$name" "$upstream" "$out_tag")" || return 1
  candidate="$(mktemp /tmp/sb-preset-outbound.XXXXXX.json)" || return 1
  register_temp_path "$candidate"
  if ! SB_JQ_OUTBOUNDS="$outbounds" jq '($ENV.SB_JQ_OUTBOUNDS | fromjson) as $outbounds | .outbounds += $outbounds' "$SINGBOX_CONFIG" > "$candidate" ||
     ! "$SINGBOX_BIN" check -c "$candidate" >/dev/null 2>&1; then
    rm -f -- "$candidate"
    die "预置出口无法通过当前 sing-box 检查，请确认协议和连接参数"
  fi
  rm -f -- "$candidate"
}

apply_split_config() {
  local name="$1" url="$2" scope="$3" user="$4" upstream="$5" out_tag="$6" tag="$7" transport_tag="${8:-}" format outbounds inbounds='[]'
  outbounds="$(build_split_outbounds "$name" "$upstream" "$out_tag" "$transport_tag")"
  format="$(split_rule_format "$url")" || die "远程规则集地址必须指向 .srs 或 .json 文件"
  if [[ "$scope" == user ]]; then inbounds="$(split_user_inbound_tags "$user")" || return 1; fi
  SB_JQ_NEW_OUTBOUNDS="$outbounds" rewrite_singbox_config '
    ($ENV.SB_JQ_NEW_OUTBOUNDS | fromjson) as $new_outbounds |
    .route.rules = [(.route.rules // [])[] | select((.rule_set // "") != $tag)] |
    .route.rule_set = [(.route.rule_set // [])[] | select(.tag != $tag)] |
    .outbounds += $new_outbounds |
    .route.rule_set += [{type:"remote",tag:$tag,format:$format,url:$url,download_detour:"direct",update_interval:"24h"}] |
    .route.rules += [
      ({rule_set:$tag,action:"route",outbound:$out_tag} +
       (if $scope == "user" then {inbound:$inbounds} else {} end))
    ]
  ' --arg tag "$tag" --arg out_tag "$out_tag" --arg url "$url" --arg format "$format" --arg scope "$scope" --argjson inbounds "$inbounds"
}

collect_managed_split_tags_with_shell_tools() {
  local split rows rule_tags='[]' out_tags='[]' transport_tags='[]' tag stored
  rows="$(jq -c '.splits[]' "$STATE_FILE")" || return 1
  while IFS= read -r split; do
    [[ -n "$split" ]] || continue
    tag="$(split_runtime_rule_tag_from_json "$split")" || return 1
    stored="$(jq -r '.rule_set_tag // ("managed-split-" + .name)' <<<"$split")" || return 1
    rule_tags="$(jq -cn --argjson values "$rule_tags" --arg a "$tag" --arg b "$stored" '$values + [$a,$b] | unique')" || return 1
    tag="$(split_runtime_out_tag_from_json "$split")" || return 1
    stored="$(jq -r '.outbound_tag // ("managed-out-" + .name)' <<<"$split")" || return 1
    out_tags="$(jq -cn --argjson values "$out_tags" --arg a "$tag" --arg b "$stored" '$values + [$a,$b] | unique')" || return 1
    tag="$(split_runtime_transport_tag_from_json "$split")" || return 1
    stored="$(jq -r '"managed-transport-" + .name' <<<"$split")" || return 1
    transport_tags="$(jq -cn --argjson values "$transport_tags" --arg a "$tag" --arg b "$stored" '$values + [$a,$b] | unique')" || return 1
  done <<<"$rows"
  jq -cn --argjson rules "$rule_tags" --argjson outbounds "$out_tags" --argjson transports "$transport_tags" \
    '{rule_tags:$rules,out_tags:$outbounds,transport_tags:$transports}'
}

collect_managed_split_tags() {
  local fast_rc
  if ! command -v python3 >/dev/null 2>&1; then
    collect_managed_split_tags_with_shell_tools
    return
  fi
  if python3 - "$STATE_FILE" <<'PY'
import hashlib
import json
import sys

prefixes = {
    "rule": "mpr-",
    "outbound": "mpo-",
    "transport": "mpt-",
}


class ShellFallbackRequired(Exception):
    pass


def stable_tag(kind, name):
    digest = hashlib.sha256(f"{kind}:{name}".encode("utf-8")).hexdigest()[:24]
    return prefixes[kind] + digest


def optional_text(split, key, default=""):
    value = split.get(key)
    if value is None or value is False:
        return default
    if not isinstance(value, str):
        raise ShellFallbackRequired
    return value


try:
    with open(sys.argv[1], "r", encoding="utf-8") as state_file:
        state = json.load(state_file)
    if not isinstance(state, dict):
        raise ValueError("state must be an object")
    splits = state.get("splits")
    if not isinstance(splits, list):
        raise ValueError("splits must be an array")
    rule_tags = set()
    out_tags = set()
    transport_tags = set()
    for split in splits:
        if not isinstance(split, dict) or not isinstance(split.get("name"), str):
            raise ShellFallbackRequired
        name = split["name"]
        rule_preset = optional_text(split, "rule_preset")
        outbound_preset = optional_text(split, "outbound_preset")
        stored_rule = optional_text(split, "rule_set_tag", "managed-split-" + name)
        stored_out = optional_text(split, "outbound_tag", "managed-out-" + name)
        stored_transport = "managed-transport-" + name
        runtime_rule = optional_text(split, "runtime_rule_tag")
        runtime_out = optional_text(split, "runtime_outbound_tag")
        runtime_transport = optional_text(split, "runtime_transport_tag")
        rule_tags.update((runtime_rule or (stable_tag("rule", rule_preset) if rule_preset else stored_rule), stored_rule))
        out_tags.update((runtime_out or (stable_tag("outbound", outbound_preset) if outbound_preset else stored_out), stored_out))
        transport_tags.update((runtime_transport or (stable_tag("transport", outbound_preset) if outbound_preset else stored_transport), stored_transport))
    print(json.dumps({
        "rule_tags": sorted(rule_tags),
        "out_tags": sorted(out_tags),
        "transport_tags": sorted(transport_tags),
    }, ensure_ascii=False, separators=(",", ":")))
except ShellFallbackRequired:
    sys.exit(75)
except (OSError, UnicodeError, ValueError, TypeError, json.JSONDecodeError):
    sys.exit(1)
PY
  then
    return 0
  else
    fast_rc=$?
  fi
  if [[ "$fast_rc" == 75 ]]; then
    collect_managed_split_tags_with_shell_tools
    return
  fi
  return "$fast_rc"
}

collect_legacy_split_cleanup_plan_from_config() {
  local config_json="$1" managed_tags_json="$2" managed_urls
  managed_urls="$(jq -c '[.splits[]?.url | select(type == "string" and length > 0)] | unique' "$STATE_FILE")" || return 1
  jq -c --argjson tags "$managed_tags_json" --argjson managed_urls "$managed_urls" '
    . as $config |
    [
      ($config.route.rule_set // [])[] |
      . as $rule_set |
      select((.url // "") as $url | ($managed_urls | index($url)) != null) |
      select(($tags.rule_tags | index($rule_set.tag // "")) == null) |
      .tag
    ] | unique as $legacy_rules |
    [
      ($config.route.rules // [])[] |
      . as $route |
      select(($legacy_rules | index($route.rule_set // "")) != null) |
      (.outbound // empty) |
      select(type == "string" and length > 0 and . != "direct")
    ] | unique as $legacy_primary_outs |
    [
      ($config.outbounds // [])[] |
      . as $outbound |
      select(($legacy_primary_outs | index($outbound.tag // "")) != null) |
      (.detour // empty) |
      select(type == "string" and length > 0)
    ] | unique as $legacy_detours |
    {
      rule_tags:$legacy_rules,
      out_tags:(($legacy_primary_outs + $legacy_detours) | unique)
    }
  ' <<<"$config_json"
}

legacy_split_cleanup_pending() {
  local config tags cleanup
  config="$("$SINGBOX_BIN" format -c "$SINGBOX_CONFIG")" || return 1
  tags="$(collect_managed_split_tags)" || return 1
  cleanup="$(collect_legacy_split_cleanup_plan_from_config "$config" "$tags")" || return 1
  jq -e '(.rule_tags | length) > 0' <<<"$cleanup" >/dev/null
}

remove_all_managed_split_config() {
  local tags rule_tags out_tags transport_tags
  tags="$(collect_managed_split_tags)" || return 1
  rule_tags="$(jq -c '.rule_tags' <<<"$tags")" || return 1
  out_tags="$(jq -c '.out_tags' <<<"$tags")" || return 1
  transport_tags="$(jq -c '.transport_tags' <<<"$tags")" || return 1
  rewrite_singbox_config '
    .route.rules = [(.route.rules // [])[] | . as $item | select(($rule_tags | index($item.rule_set // "")) == null)] |
    .route.rule_set = [(.route.rule_set // [])[] | . as $item | select(($rule_tags | index($item.tag)) == null)] |
    .outbounds = [(.outbounds // [])[] | . as $item | select((($out_tags + $transport_tags) | index($item.tag)) == null)]
  ' --argjson rule_tags "$rule_tags" --argjson out_tags "$out_tags" --argjson transport_tags "$transport_tags"
}

split_user_inbound_tags() {
  local user="$1"
  jq -c --arg name "$user" '
    first(.users[]? | select(.name == $name)) as $user |
    if $user == null then []
    else (if ($user.endpoints | type) == "array" then $user.endpoints
          else [{protocol:($user.protocol // "ss2022"),transport:($user.transport // "shadowtls")}] end) as $endpoints |
    ($endpoints | any(.protocol == "ss2022" and .transport == "shadowtls")) as $has_legacy |
    [ $endpoints[] |
      if .protocol == "anytls" then "anytls-" + $name
      elif .transport == "shadowtls" then "st-" + $name, "ss-" + $name, "ss-udp-" + $name
      elif $has_legacy then "ss-direct-" + $name
      else "ss-" + $name end
    ] | unique end
  ' "$STATE_FILE"
}

build_split_runtime_plan() {
  local split_rows split plan name url scope user user_status upstream out_tag rule_tag transport_tag format outbounds rule_set inbounds conflict
  split_rows="$(jq -c '.splits[] | select(.status == "active")' "$STATE_FILE")" || return 1
  plan='{"outbound_groups":[],"rule_sets":[],"routes":[]}'
  while IFS= read -r split; do
    [[ -n "$split" ]] || continue
    name="$(jq -er '.name | select(type == "string" and length > 0)' <<<"$split")" || return 1
    url="$(jq -er '.url | select(type == "string" and length > 0)' <<<"$split")" || return 1
    scope="$(jq -er '.scope | select(. == "all" or . == "user")' <<<"$split")" || return 1
    user="$(jq -er '.user // ""' <<<"$split")" || return 1
    if [[ "$scope" == user ]]; then
      user_status="$(jq -r --arg name "$user" 'first(.users[]? | select(.name == $name) | .status) // "missing"' "$STATE_FILE")" || return 1
      if [[ "$user_status" == disabled ]]; then continue; fi
      if [[ "$user_status" != active ]]; then
        echo "错误：分流 ${name} 指定的用户不存在，请先删除或修改这条分流。" >&2
        return 1
      fi
    fi
    upstream="$(jq -ec '.upstream | select(type == "object")' <<<"$split")" || return 1
    out_tag="$(split_runtime_out_tag_from_json "$split")" || return 1
    rule_tag="$(split_runtime_rule_tag_from_json "$split")" || return 1
    transport_tag="$(split_runtime_transport_tag_from_json "$split")" || return 1
    format="$(split_rule_format "$url")" || return 1
    outbounds="$(build_split_outbounds "$name" "$upstream" "$out_tag" "$transport_tag")" || return 1
    rule_set="$(jq -cn --arg tag "$rule_tag" --arg format "$format" --arg url "$url" \
      '{type:"remote",tag:$tag,format:$format,url:$url,download_detour:"direct",update_interval:"24h"}')" || return 1
    if jq -e --arg tag "$out_tag" 'any(.outbound_groups[]; .tag == $tag)' <<<"$plan" >/dev/null; then
      if ! SB_JQ_OUTBOUNDS="$outbounds" jq -e --arg tag "$out_tag" \
        '($ENV.SB_JQ_OUTBOUNDS | fromjson) as $objects | any(.outbound_groups[]; .tag == $tag and .objects == $objects)' <<<"$plan" >/dev/null; then
          echo "错误：多个分流使用了同一个预置出口名称，但连接参数不同；请重新选择预置出口。" >&2
          return 1
      fi
    else
      plan="$(SB_JQ_OUTBOUNDS="$outbounds" jq -c --arg tag "$out_tag" '($ENV.SB_JQ_OUTBOUNDS | fromjson) as $objects | .outbound_groups += [{tag:$tag,objects:$objects}]' <<<"$plan")" || return 1
    fi
    if jq -e --arg tag "$rule_tag" 'any(.rule_sets[]; .tag == $tag)' <<<"$plan" >/dev/null; then
      jq -e --arg tag "$rule_tag" --argjson item "$rule_set" 'any(.rule_sets[]; .tag == $tag and . == $item)' <<<"$plan" >/dev/null || {
        echo "错误：多个分流使用了同一个预置规则名称，但下载地址不同；请重新选择预置规则。" >&2
        return 1
      }
    else
      plan="$(jq -c --argjson item "$rule_set" '.rule_sets += [$item]' <<<"$plan")" || return 1
    fi
    if [[ "$scope" == all ]]; then inbounds='[]'; else inbounds="$(split_user_inbound_tags "$user")" || return 1; fi
    conflict="$(jq -r --arg rule "$rule_tag" --arg out "$out_tag" --arg scope "$scope" --arg user "$user" '
      first(.routes[] | select(
        .rule_set == $rule and .outbound != $out and
        ($scope == "all" or .scope_all or (.users | index($user) != null))
      ) | "yes") // ""
    ' <<<"$plan")" || return 1
    if [[ -n "$conflict" ]]; then
      echo "错误：同一用户不能让同一条预置规则同时使用两个不同出口。" >&2
      return 1
    fi
    if jq -e --arg rule "$rule_tag" --arg out "$out_tag" 'any(.routes[]; .rule_set == $rule and .outbound == $out)' <<<"$plan" >/dev/null; then
      plan="$(jq -c --arg rule "$rule_tag" --arg out "$out_tag" --arg scope "$scope" --arg user "$user" --argjson inbound "$inbounds" '
        .routes |= map(
          if .rule_set == $rule and .outbound == $out then
            if $scope == "all" then .scope_all = true | .users = [] | .inbound = []
            elif .scope_all then .
            else .users = ((.users + [$user]) | unique) | .inbound = ((.inbound + $inbound) | unique)
            end
          else . end)
      ' <<<"$plan")" || return 1
    else
      plan="$(jq -c --arg rule "$rule_tag" --arg out "$out_tag" --arg scope "$scope" --arg user "$user" --argjson inbound "$inbounds" '
        .routes += [{rule_set:$rule,outbound:$out,scope_all:($scope == "all"),users:(if $scope == "all" then [] else [$user] end),inbound:$inbound}]
      ' <<<"$plan")" || return 1
    fi
  done <<<"$split_rows"
  jq -c '{
    outbounds:[.outbound_groups[].objects[]],
    rule_sets:.rule_sets,
    rules:[.routes[] | ({rule_set:.rule_set,action:"route",outbound:.outbound} + (if .scope_all then {} else {inbound:.inbound} end))]
  }' <<<"$plan"
}

rebuild_all_split_configs() {
  local plan tags config legacy_cleanup
  # 先完整生成计划，任何读取、冲突或格式错误都不得提前改动现有配置。
  plan="$(build_split_runtime_plan)" || return 1
  tags="$(collect_managed_split_tags)" || return 1
  config="$("$SINGBOX_BIN" format -c "$SINGBOX_CONFIG")" || return 1
  legacy_cleanup="$(collect_legacy_split_cleanup_plan_from_config "$config" "$tags")" || return 1
  SB_JQ_PLAN="$plan" rewrite_singbox_config '
    ($ENV.SB_JQ_PLAN | fromjson) as $plan |
    .route.rules = [
      (.route.rules // [])[] | . as $item |
      select(($tags.rule_tags | index($item.rule_set // "")) == null) |
      select(($legacy.rule_tags | index($item.rule_set // "")) == null)
    ] |
    .route.rule_set = [
      (.route.rule_set // [])[] | . as $item |
      select(($tags.rule_tags | index($item.tag)) == null) |
      select(($legacy.rule_tags | index($item.tag)) == null)
    ] |
    ([
      (.route.rules[]?.outbound // empty),
      (.route.final // empty),
      ((.outbounds // [])[] |
        . as $outbound |
        select(($legacy.out_tags | index($outbound.tag // "")) == null) |
        (.detour // empty))
    ] | unique) as $protected_outbounds |
    .outbounds = [
      (.outbounds // [])[] | . as $item |
      select((($tags.out_tags + $tags.transport_tags) | index($item.tag)) == null) |
      select(
        ($legacy.out_tags | index($item.tag)) == null or
        ($protected_outbounds | index($item.tag)) != null
      )
    ] |
    .outbounds += $plan.outbounds |
    .route.rule_set += $plan.rule_sets |
    .route.rules += $plan.rules
  ' --argjson tags "$tags" --argjson legacy "$legacy_cleanup"
}

rebuild_and_finish_split_operation() {
  run_managed_step rebuild_all_split_configs || return 1
  run_managed_step check_singbox_and_restart || return 1
  finish_managed_operation || return 1
}

# sing-box 的 Listable 字段只有一个元素时，会被 `format` 规范化成裸标量：
#   写入的 "inbound":["anytls-share"]  →  读回的 "inbound":"anytls-share"
# 直接拿它和期望的标签数组做集合运算，jq 会因类型不符而报错
# （array and string cannot be subtracted）。而这些比对的调用点写成
# `if ! jq ...` 或 `jq ... || return 1`，jq 崩溃会被当成「配置不符」，
# 于是既误报「分流尚未覆盖用户的全部连接」，又会触发一次不必要的配置重建与
# sing-box 重启。字符串上的 `.inbound[]?` 还会安静地什么都不返回，让
# 「已停用用户的规则仍在生效」这类检查静默失效。
#
# 因此凡是要拿运行配置和期望标签做比对的地方，都必须经这里读入，
# 把 route.rules[].inbound 统一还原成数组。只有单一入口的用户会踩到，
# 而那恰恰是最常见的配置。
singbox_config_for_comparison() {
  "$SINGBOX_BIN" format -c "$SINGBOX_CONFIG" | jq -c '
    if (.route.rules? | type) == "array" then
      .route.rules |= map(
        if has("inbound") and ((.inbound | type) != "array") then .inbound = [.inbound] else . end)
    else . end'
}

shared_preset_runtime_is_current() {
  local config rows split scope user user_status rule_tag out_tag transport_tag stored_rule stored_out stored_transport protocol inbounds tags legacy_cleanup
  config="$(singbox_config_for_comparison)" || return 1
  tags="$(collect_managed_split_tags)" || return 1
  legacy_cleanup="$(collect_legacy_split_cleanup_plan_from_config "$config" "$tags")" || return 1
  [[ "$(jq '.rule_tags | length' <<<"$legacy_cleanup")" == 0 ]] || return 1
  rows="$(jq -c '.splits[]? | select(.status == "active" and (((.rule_preset // "") != "") or ((.outbound_preset // "") != "")))' "$STATE_FILE")" || return 1
  while IFS= read -r split; do
    [[ -n "$split" ]] || continue
    scope="$(jq -r '.scope' <<<"$split")" || return 1
    user="$(jq -r '.user // ""' <<<"$split")" || return 1
    if [[ "$scope" == user ]]; then
      user_status="$(jq -r --arg name "$user" 'first(.users[]? | select(.name == $name) | .status) // "missing"' "$STATE_FILE")" || return 1
      [[ "$user_status" == active ]] || continue
    fi
    rule_tag="$(split_runtime_rule_tag_from_json "$split")" || return 1
    out_tag="$(split_runtime_out_tag_from_json "$split")" || return 1
    transport_tag="$(split_runtime_transport_tag_from_json "$split")" || return 1
    stored_rule="$(jq -r '.rule_set_tag // ("managed-split-" + .name)' <<<"$split")" || return 1
    stored_out="$(jq -r '.outbound_tag // ("managed-out-" + .name)' <<<"$split")" || return 1
    stored_transport="$(jq -r '"managed-transport-" + .name' <<<"$split")" || return 1
    [[ "$(jq --arg tag "$rule_tag" '[.route.rule_set[]? | select(.tag == $tag)] | length' <<<"$config")" == 1 ]] || return 1
    [[ "$(jq --arg tag "$out_tag" '[.outbounds[]? | select(.tag == $tag)] | length' <<<"$config")" == 1 ]] || return 1
    if [[ "$stored_rule" != "$rule_tag" ]] && jq -e --arg tag "$stored_rule" '.route.rule_set[]? | select(.tag == $tag)' <<<"$config" >/dev/null; then return 1; fi
    if [[ "$stored_out" != "$out_tag" ]] && jq -e --arg tag "$stored_out" '.outbounds[]? | select(.tag == $tag)' <<<"$config" >/dev/null; then return 1; fi
    protocol="$(jq -r '.upstream.protocol // ""' <<<"$split")" || return 1
    if [[ "$protocol" == ss_shadowtls ]]; then
      [[ "$(jq --arg tag "$transport_tag" '[.outbounds[]? | select(.tag == $tag)] | length' <<<"$config")" == 1 ]] || return 1
      if [[ "$stored_transport" != "$transport_tag" ]] && jq -e --arg tag "$stored_transport" '.outbounds[]? | select(.tag == $tag)' <<<"$config" >/dev/null; then return 1; fi
    fi
    if [[ "$scope" == all ]]; then
      jq -e --arg rule "$rule_tag" --arg out "$out_tag" '
        .route.rules[]? | select(.rule_set == $rule and .outbound == $out and ((.inbound // []) | length == 0))
      ' <<<"$config" >/dev/null || return 1
    else
      inbounds="$(split_user_inbound_tags "$user")" || return 1
      jq -e --arg rule "$rule_tag" --arg out "$out_tag" --argjson expected "$inbounds" '
        .route.rules[]? | select(.rule_set == $rule and .outbound == $out and
          ($expected - (.inbound // []) | length) == 0)
      ' <<<"$config" >/dev/null || return 1
    fi
  done <<<"$rows"
}

shared_preset_runtime_fingerprint() {
  [[ -r "$STATE_FILE" && -r "$SINGBOX_CONFIG" ]] || return 1
  sha256sum "$STATE_FILE" "$SINGBOX_CONFIG" | awk '{print $1}' | tr '\n' ' '
}

shared_preset_runtime_marker_matches() {
  local expected actual
  [[ -r "$SHARED_PRESET_RUNTIME_MARKER" ]] || return 1
  expected="$(shared_preset_runtime_fingerprint)" || return 1
  actual="$(<"$SHARED_PRESET_RUNTIME_MARKER")"
  [[ "$actual" == "$expected" ]]
}

write_shared_preset_runtime_marker() {
  local value directory tmp
  value="$(shared_preset_runtime_fingerprint)" || return 1
  directory="$(dirname "$SHARED_PRESET_RUNTIME_MARKER")"
  install -d -m 700 "$directory" || return 1
  tmp="$(mktemp "$directory/.shared-preset-runtime.XXXXXX")" || return 1
  register_temp_path "$tmp"
  printf '%s\n' "$value" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -- "$tmp" "$SHARED_PRESET_RUNTIME_MARKER"
}

split_preset_fields_are_current() {
  [[ -r "$STATE_FILE" ]] || return 1
  [[ "$(jq '[.splits[]? | select(.rule_preset == "" or .outbound_preset == "")] | length' "$STATE_FILE")" == 0 ]]
}

state_normalize_split_preset_fields() {
  atomic_state_update '
    .splits |= map(
      (if .rule_preset == "" then del(.rule_preset) else . end) |
      (if .outbound_preset == "" then del(.outbound_preset) else . end))
  '
}

migrate_empty_split_preset_fields() {
  [[ -r "$CONF_FILE" ]] || return 0
  command -v jq >/dev/null || return 0
  command -v flock >/dev/null || return 0
  load_runtime_config || return 1
  [[ -f "$STATE_FILE" && -f "$SINGBOX_CONFIG" && -x "$SINGBOX_BIN" && -x "$NFUSE_BIN" && -S "$NFUSE_SOCKET" ]] || return 0
  split_preset_fields_are_current && return 0
  exec 9>"$LOCK_FILE" || return 1
  if ! flock -n 9; then release_operation_lock; return 1; fi
  if ! recover_pending_transaction || ! init_state; then release_operation_lock; return 1; fi
  if split_preset_fields_are_current; then
    release_operation_lock
    return 0
  fi
  if ! state_normalize_split_preset_fields; then
    release_operation_lock
    return 1
  fi
  log "已修正分流缺少预置来源时留下的空白记录"
  release_operation_lock
}

migrate_shared_preset_runtime_configs() {
  [[ -r "$CONF_FILE" ]] || return 0
  command -v jq >/dev/null || return 0
  command -v flock >/dev/null || return 0
  load_runtime_config || return 1
  [[ -f "$STATE_FILE" && -f "$SINGBOX_CONFIG" && -x "$SINGBOX_BIN" && -x "$NFUSE_BIN" && -S "$NFUSE_SOCKET" ]] || return 0
  shared_preset_runtime_marker_matches && return 0
  if shared_preset_runtime_is_current; then
    write_shared_preset_runtime_marker
    return $?
  fi
  exec 9>"$LOCK_FILE" || return 1
  if ! flock -n 9; then release_operation_lock; return 1; fi
  if ! recover_pending_transaction || ! init_state; then release_operation_lock; return 1; fi
  if shared_preset_runtime_is_current; then
    write_shared_preset_runtime_marker || { release_operation_lock; return 1; }
    release_operation_lock
    return 0
  fi
  if ! ensure_safe_ssh_for_singbox_restart; then release_operation_lock; return 0; fi
  if ! start_managed_operation migrate-shared-presets; then release_operation_lock; return 1; fi
  if ! rebuild_and_finish_split_operation; then
    release_operation_lock
    return 1
  fi
  write_shared_preset_runtime_marker || { release_operation_lock; return 1; }
  log "已将重复的预置规则和出口合并为共享配置"
  release_operation_lock
}

state_add_split() {
  SB_JQ_UPSTREAM="$5" atomic_state_update '(
    $ENV.SB_JQ_UPSTREAM | fromjson
  ) as $upstream |
    .splits += [{name:$name,url:$url,scope:$scope,user:(if $scope == "user" then $user else null end),upstream:$upstream,outbound_tag:$out_tag,rule_set_tag:$rule_tag,
      runtime_rule_tag:$runtime_rule_tag,runtime_outbound_tag:$runtime_outbound_tag,runtime_transport_tag:$runtime_transport_tag,
      rule_preset:$rule_preset,outbound_preset:$outbound_preset,status:"active",created_at:$created_at}
      | (if $rule_preset == "" then del(.rule_preset) else . end)
      | (if $outbound_preset == "" then del(.outbound_preset) else . end)]
  ' --arg name "$1" --arg url "$2" --arg scope "$3" --arg user "$4" \
    --arg out_tag "$6" --arg rule_tag "$7" --arg rule_preset "$8" --arg outbound_preset "$9" \
    --arg runtime_rule_tag "${10}" --arg runtime_outbound_tag "${11}" --arg runtime_transport_tag "${12}" \
    --arg created_at "$(date -Iseconds)"
}

state_set_split_status() {
  atomic_state_update '(.splits[] | select(.name == $name) | .status) = $status' \
    --arg name "$1" --arg status "$2"
}

state_replace_split() {
  SB_JQ_UPSTREAM="$5" atomic_state_update '(
    $ENV.SB_JQ_UPSTREAM | fromjson
  ) as $upstream |
    (.splits[] | select(.name == $name)) |=
      (. + {url:$url,scope:$scope,user:(if $scope == "user" then $user else null end),upstream:$upstream,outbound_tag:$out_tag,
        runtime_rule_tag:$runtime_rule_tag,runtime_outbound_tag:$runtime_outbound_tag,runtime_transport_tag:$runtime_transport_tag,
        updated_at:$updated_at}
       | (if $rule_preset == "" then del(.rule_preset) else .rule_preset = $rule_preset end)
       | (if $outbound_preset == "" then del(.outbound_preset) else .outbound_preset = $outbound_preset end))
  ' --arg name "$1" --arg url "$2" --arg scope "$3" --arg user "$4" \
    --arg out_tag "$6" --arg rule_preset "$7" --arg outbound_preset "$8" \
    --arg runtime_rule_tag "$9" --arg runtime_outbound_tag "${10}" --arg runtime_transport_tag "${11}" \
    --arg updated_at "$(date -Iseconds)"
}

# 相同「预置规则 + 预置出口」的分流在运行配置里合并成一条路由，因而共用同一个匹配位置。
# 分组键取运行期标签，必须复用 split_runtime_*_from_json —— 它们的回退分支带 sha256，
# 无法在 jq 里重写一遍，另写一套迟早会和运行配置的分组规则脱节。
# 输出 {分流名: 匹配位置}，停用的分流不进入运行配置，位置为 null。
split_effective_match_ranks() {
  local rows row name status split rule_tag out_tag key existing rank=0 seen='{}' map='{}'
  rows="$(jq -r '.splits[] | [.name, .status, tojson] | @tsv' "$STATE_FILE")" || return 1
  while IFS=$'\t' read -r name status split; do
    [[ -n "$name" ]] || continue
    if [[ "$status" != active ]]; then
      map="$(jq -c --arg name "$name" '.[$name] = null' <<<"$map")" || return 1
      continue
    fi
    rule_tag="$(split_runtime_rule_tag_from_json "$split")" || return 1
    out_tag="$(split_runtime_out_tag_from_json "$split")" || return 1
    key="$rule_tag/$out_tag"
    existing="$(jq -r --arg key "$key" '.[$key] // ""' <<<"$seen")" || return 1
    if [[ -z "$existing" ]]; then
      rank=$((rank + 1))
      existing="$rank"
      seen="$(jq -c --arg key "$key" --argjson rank "$rank" '.[$key] = $rank' <<<"$seen")" || return 1
    fi
    map="$(jq -c --arg name "$name" --argjson rank "$existing" '.[$name] = $rank' <<<"$map")" || return 1
  done <<<"$rows"
  printf '%s' "$map"
}

# 与指定分流合并成同一条路由的全部分流名（含自身），按现有先后顺序返回。
# 停用的分流不进入运行配置，因此只与启用分流分组。
split_merge_group_names() {
  local target="$1" rows row name status split rule_tag out_tag target_key='' key group='[]'
  rows="$(jq -r '.splits[] | [.name, .status, tojson] | @tsv' "$STATE_FILE")" || return 1
  while IFS=$'\t' read -r name status split; do
    [[ "$name" == "$target" ]] || continue
    [[ "$status" == active ]] || { printf '["%s"]' "$target"; return 0; }
    rule_tag="$(split_runtime_rule_tag_from_json "$split")" || return 1
    out_tag="$(split_runtime_out_tag_from_json "$split")" || return 1
    target_key="$rule_tag/$out_tag"
  done <<<"$rows"
  [[ -n "$target_key" ]] || { printf '["%s"]' "$target"; return 0; }
  while IFS=$'\t' read -r name status split; do
    [[ -n "$name" ]] || continue
    [[ "$status" == active ]] || continue
    rule_tag="$(split_runtime_rule_tag_from_json "$split")" || return 1
    out_tag="$(split_runtime_out_tag_from_json "$split")" || return 1
    key="$rule_tag/$out_tag"
    [[ "$key" == "$target_key" ]] || continue
    group="$(jq -c --arg name "$name" '. += [$name]' <<<"$group")" || return 1
  done <<<"$rows"
  printf '%s' "$group"
}

# 合并成同一条路由的分流共用一个匹配位置，必须整组一起移动并保持彼此相邻，
# 否则界面顺序会和真正生效的顺序不一致。
state_move_split() {
  SB_JQ_GROUP="$1" atomic_state_update '
    ($ENV.SB_JQ_GROUP | fromjson) as $group |
    [.splits[] | select(.name as $n | ($group | index($n)) != null)] as $selected |
    [.splits[] | select(.name as $n | ($group | index($n)) == null)] as $remaining |
    ([$position - 1, ($remaining | length)] | min) as $index |
    .splits = ($remaining[0:$index] + $selected + $remaining[$index:])
  ' --argjson position "$2"
}

state_remove_split() {
  atomic_state_update '.splits = [.splits[] | select(.name != $name)]' --arg name "$1"
}

state_add_outbound_preset() {
  SB_JQ_UPSTREAM="$2" atomic_state_update '(
    $ENV.SB_JQ_UPSTREAM | fromjson
  ) as $upstream |
    .outbound_presets += [{name:$name,upstream:$upstream,created_at:$created_at}]
  ' --arg name "$1" --arg created_at "$(date -Iseconds)"
}

state_replace_outbound_preset() {
  SB_JQ_UPSTREAM="$2" atomic_state_update '(
    $ENV.SB_JQ_UPSTREAM | fromjson
  ) as $upstream |
    (.outbound_presets[] | select(.name == $name)) |=
      (. + {upstream:$upstream,updated_at:$updated_at}) |
    .splits |= map(
      if (.outbound_preset // "") == $name then
        . + {upstream:$upstream,updated_at:$updated_at}
      else . end
    )
  ' --arg name "$1" --arg updated_at "$(date -Iseconds)"
}

state_remove_outbound_preset() {
  atomic_state_update '
    .outbound_presets = [.outbound_presets[] | select(.name != $name)] |
    .splits |= map(
      if (.outbound_preset // "") == $name then
        .runtime_outbound_tag = $runtime_outbound_tag |
        .runtime_transport_tag = $runtime_transport_tag |
        del(.outbound_preset)
      else . end)
  ' --arg name "$1" --arg runtime_outbound_tag "$2" --arg runtime_transport_tag "$3"
}

state_add_rule_preset() {
  atomic_state_update '
    .rule_presets += [{name:$name,url:$url,created_at:$created_at}]
  ' --arg name "$1" --arg url "$2" --arg created_at "$(date -Iseconds)"
}

state_replace_rule_preset() {
  atomic_state_update '
    (.rule_presets[] | select(.name == $name)) |=
      (. + {url:$url,updated_at:$updated_at}) |
    .splits |= map(
      if (.rule_preset // "") == $name then
        . + {url:$url,updated_at:$updated_at}
      else . end
    )
  ' --arg name "$1" --arg url "$2" --arg updated_at "$(date -Iseconds)"
}

state_remove_rule_preset() {
  atomic_state_update '
    .rule_presets = [.rule_presets[] | select(.name != $name)] |
    .splits |= map(
      if (.rule_preset // "") == $name then
        .runtime_rule_tag = $runtime_rule_tag |
        del(.rule_preset)
      else . end)
  ' --arg name "$1" --arg runtime_rule_tag "$2"
}

state_sync_linked_split_snapshots() {
  atomic_state_update '
    .outbound_presets as $outbounds |
    .rule_presets as $rules |
    .splits |= map(
      . as $split |
      (if (($split.outbound_preset // "") != "") then
         (first($outbounds[] | select(.name == $split.outbound_preset)) // null)
       else null end) as $outbound |
      (if (($split.rule_preset // "") != "") then
         (first($rules[] | select(.name == $split.rule_preset)) // null)
       else null end) as $rule |
      (if (($split.outbound_preset // "") != "") then
         if $outbound == null then del(.outbound_preset) else .upstream = $outbound.upstream end
       else . end) |
      (if (($split.rule_preset // "") != "") then
         if $rule == null then del(.rule_preset) else .url = $rule.url end
       else . end)
    )
  '
}

cmd_outbound_preset_add() {
  local name="$1" upstream="$2"
  validate_preset_name "$name"
  outbound_preset_exists "$name" && die "同名预置出口已经存在"
  validate_upstream_candidate "$upstream"
  state_add_outbound_preset "$name" "$upstream" || return 1
  log "预置出口已保存：${name}；它不会改变当前分流"
}

cmd_outbound_preset_edit() {
  local name="$1" upstream="$2" active
  outbound_preset_exists "$name" || die "预置出口不存在：$name"
  validate_upstream_candidate "$upstream"
  active="$(jq --arg name "$name" '[.splits[] | select((.outbound_preset // "") == $name and .status == "active")] | length' "$STATE_FILE")" || return 1
  if ((active == 0)); then
    state_replace_outbound_preset "$name" "$upstream" || return 1
  else
    ensure_safe_ssh_for_singbox_restart || return 0
    start_managed_operation "edit-outbound-preset:$name" || return 1
    run_managed_step state_replace_outbound_preset "$name" "$upstream" || return 1
    rebuild_and_finish_split_operation || return 1
  fi
  log "预置出口已更新：${name}；关联分流已经同步"
}

cmd_outbound_preset_remove() {
  local name="$1" runtime_outbound_tag runtime_transport_tag
  outbound_preset_exists "$name" || die "预置出口不存在：$name"
  runtime_outbound_tag="$(stable_managed_tag outbound "$name")" || return 1
  runtime_transport_tag="$(stable_managed_tag transport "$name")" || return 1
  state_remove_outbound_preset "$name" "$runtime_outbound_tag" "$runtime_transport_tag" || return 1
  log "预置出口已删除：${name}；关联分流已转为独立配置，现有连接参数没有变化"
}

cmd_rule_preset_add() {
  local name="$1" url="$2"
  validate_preset_name "$name"
  rule_preset_exists "$name" && die "同名预置规则已经存在"
  [[ "$url" == https://* ]] || die "规则集地址必须使用 HTTPS"
  split_rule_format "$url" >/dev/null || die "规则集地址必须指向 .srs 或 .json 文件"
  validate_remote_rule_set "$url"
  state_add_rule_preset "$name" "$url" || return 1
  log "预置规则已保存：${name}；它不会改变当前分流"
}

cmd_rule_preset_edit() {
  local name="$1" url="$2" active
  rule_preset_exists "$name" || die "预置规则不存在：$name"
  [[ "$url" == https://* ]] || die "规则集地址必须使用 HTTPS"
  split_rule_format "$url" >/dev/null || die "规则集地址必须指向 .srs 或 .json 文件"
  validate_remote_rule_set "$url"
  active="$(jq --arg name "$name" '[.splits[] | select((.rule_preset // "") == $name and .status == "active")] | length' "$STATE_FILE")" || return 1
  if ((active == 0)); then
    state_replace_rule_preset "$name" "$url" || return 1
  else
    ensure_safe_ssh_for_singbox_restart || return 0
    start_managed_operation "edit-rule-preset:$name" || return 1
    run_managed_step state_replace_rule_preset "$name" "$url" || return 1
    rebuild_and_finish_split_operation || return 1
  fi
  log "预置规则已更新：${name}；关联分流已经同步"
}

cmd_rule_preset_remove() {
  local name="$1" runtime_rule_tag
  rule_preset_exists "$name" || die "预置规则不存在：$name"
  runtime_rule_tag="$(stable_managed_tag rule "$name")" || return 1
  state_remove_rule_preset "$name" "$runtime_rule_tag" || return 1
  log "预置规则已删除：${name}；关联分流已转为独立配置，现有规则地址没有变化"
}

validate_split_relationships() {
  local exclude_name="$1" candidate_rule="$2" candidate_out="$3" candidate_scope="$4" candidate_user="$5" active_only="${6:-false}"
  local rows split other_rule other_out other_scope other_user overlap=false
  rows="$(jq -c --arg exclude "$exclude_name" --argjson active_only "$active_only" '
    .splits[]? | select(.name != $exclude and (($active_only | not) or .status == "active"))
  ' "$STATE_FILE")" || return 1
  while IFS= read -r split; do
    [[ -n "$split" ]] || continue
    other_rule="$(split_runtime_rule_tag_from_json "$split")" || return 1
    [[ "$other_rule" == "$candidate_rule" ]] || continue
    other_scope="$(jq -r '.scope' <<<"$split")" || return 1
    other_user="$(jq -r '.user // ""' <<<"$split")" || return 1
    overlap=false
    if [[ "$candidate_scope" == all || "$other_scope" == all || "$candidate_user" == "$other_user" ]]; then overlap=true; fi
    [[ "$overlap" == true ]] || continue
    other_out="$(split_runtime_out_tag_from_json "$split")" || return 1
    if [[ "$other_out" == "$candidate_out" ]]; then
      echo "错误：这条预置规则已经通过同一个出口覆盖该用户，无需重复添加。" >&2
    else
      echo "错误：同一用户不能让同一条预置规则同时使用两个不同出口。" >&2
    fi
    return 1
  done <<<"$rows"
}

runtime_rule_tag_owned_by_state() {
  local wanted="$1" split rows tag
  rows="$(jq -c '.splits[]?' "$STATE_FILE")" || return 1
  while IFS= read -r split; do
    [[ -n "$split" ]] || continue
    tag="$(split_runtime_rule_tag_from_json "$split")" || return 1
    [[ "$tag" != "$wanted" ]] || return 0
  done <<<"$rows"
  return 1
}

runtime_outbound_tag_owned_by_state() {
  local wanted="$1" split rows tag
  rows="$(jq -c '.splits[]?' "$STATE_FILE")" || return 1
  while IFS= read -r split; do
    [[ -n "$split" ]] || continue
    tag="$(split_runtime_out_tag_from_json "$split")" || return 1
    [[ "$tag" != "$wanted" ]] || return 0
  done <<<"$rows"
  return 1
}

cmd_split_add() {
  local name="$1" url="$2" scope="$3" user="$4" upstream="$5" out_tag="$6" rule_preset="${7:-}" outbound_preset="${8:-}" rule_tag="$1"
  local runtime_rule_tag runtime_outbound_tag runtime_transport_tag
  validate_split_name "$name"; split_exists "$name" && die "分流规则已存在：$name"
  rule_preset_exists "$rule_preset" || die "预置规则不存在：$rule_preset"
  outbound_preset_exists "$outbound_preset" || die "预置出口不存在：$outbound_preset"
  validate_outbound_tag "$out_tag"
  runtime_rule_tag="$(stable_managed_tag rule "$rule_preset")" || return 1
  runtime_outbound_tag="$(stable_managed_tag outbound "$outbound_preset")" || return 1
  runtime_transport_tag="$(stable_managed_tag transport "$outbound_preset")" || return 1
  [[ "$url" == https://* ]] || die "远程规则集地址必须使用 HTTPS"
  if [[ "$scope" == user ]]; then validate_name "$user"; user_exists "$user" || die "用户不存在：$user"; fi
  jq -e --arg tag "$rule_tag" '.route.rule_set[]? | select(.tag == $tag)' "$SINGBOX_CONFIG" >/dev/null && die "sing-box 已存在同名规则集标签"
  jq -e --arg out "$out_tag" '.splits[]? | select((.outbound_tag // ("managed-out-" + .name)) == $out)' "$STATE_FILE" >/dev/null && die "出口名称已被其他分流使用，请换一个名称"
  [[ "$out_tag" != "$(split_transport_tag "$name")" ]] || die "出口名称与系统内部名称冲突，请换一个名称"
  jq -e --arg out "$out_tag" '.splits[]? | select(("managed-transport-" + .name) == $out)' "$STATE_FILE" >/dev/null && die "出口名称与其他分流的内部名称冲突，请换一个名称"
  jq -e --arg out "$out_tag" --arg transport "$(split_transport_tag "$name")" '.outbounds[]? | select(.tag == $out or .tag == $transport)' "$SINGBOX_CONFIG" >/dev/null && die "sing-box 已存在同名分流出站标签"
  if jq -e --arg tag "$runtime_rule_tag" '.route.rule_set[]? | select(.tag == $tag)' "$SINGBOX_CONFIG" >/dev/null &&
     ! runtime_rule_tag_owned_by_state "$runtime_rule_tag"; then
    die "这个预置规则与现有 sing-box 配置重名，请更换预置名称"
  fi
  if jq -e --arg tag "$runtime_outbound_tag" '.outbounds[]? | select(.tag == $tag)' "$SINGBOX_CONFIG" >/dev/null &&
     ! runtime_outbound_tag_owned_by_state "$runtime_outbound_tag"; then
    die "这个预置出口与现有 sing-box 配置重名，请更换预置名称"
  fi
  validate_split_relationships "$name" "$runtime_rule_tag" "$runtime_outbound_tag" "$scope" "$user" false || return 1
  validate_remote_rule_set "$url"
  ensure_safe_ssh_for_singbox_restart || return 0
  start_managed_operation "add-split:$name" || return 1
  run_managed_step state_add_split "$name" "$url" "$scope" "$user" "$upstream" "$out_tag" "$rule_tag" "$rule_preset" "$outbound_preset" \
    "$runtime_rule_tag" "$runtime_outbound_tag" "$runtime_transport_tag" || return 1
  rebuild_and_finish_split_operation || return 1
  log "分流增加成功：$name"
}

cmd_split_disable() {
  local name="$1" split
  split_exists "$name" || die "分流不存在：$name"; split="$(jq -c --arg name "$name" '.splits[] | select(.name == $name)' "$STATE_FILE")"
  [[ "$(jq -r '.status' <<<"$split")" == active ]] || die "分流已经停用"
  ensure_safe_ssh_for_singbox_restart || return 0
  start_managed_operation "disable-split:$name" || return 1
  run_managed_step state_set_split_status "$name" disabled || return 1
  rebuild_and_finish_split_operation || return 1
  log "分流已停用：$name"
}

cmd_split_enable() {
  local name="$1" split runtime_rule_tag runtime_outbound_tag
  split_exists "$name" || die "分流不存在：$name"; split="$(jq -c --arg name "$name" '.splits[] | select(.name == $name)' "$STATE_FILE")"
  [[ "$(jq -r '.status' <<<"$split")" == disabled ]] || die "分流已经启用"
  if [[ "$(jq -r '.scope' <<<"$split")" == user ]]; then user_exists "$(jq -r '.user' <<<"$split")" || die "关联用户已不存在"; fi
  jq -e '.upstream.protocol' <<<"$split" >/dev/null || die "这条旧版分流缺少出口服务器信息，请删除后重新添加"
  local out_tag rule_tag
  out_tag="$(jq -r '.outbound_tag // ("managed-out-" + .name)' <<<"$split")"
  rule_tag="$(jq -r '.rule_set_tag // ("managed-split-" + .name)' <<<"$split")"
  runtime_rule_tag="$(split_runtime_rule_tag_from_json "$split")" || return 1
  runtime_outbound_tag="$(split_runtime_out_tag_from_json "$split")" || return 1
  validate_split_relationships "$name" "$runtime_rule_tag" "$runtime_outbound_tag" "$(jq -r '.scope' <<<"$split")" "$(jq -r '.user // ""' <<<"$split")" true || return 1
  validate_outbound_tag "$out_tag"
  jq -e --arg out "$out_tag" --arg transport "$(split_transport_tag "$name")" '.outbounds[]? | select(.tag == $out or .tag == $transport)' "$SINGBOX_CONFIG" >/dev/null && die "sing-box 已存在同名分流出站标签"
  jq -e --arg tag "$rule_tag" '.route.rule_set[]? | select(.tag == $tag)' "$SINGBOX_CONFIG" >/dev/null && die "sing-box 已存在同名规则集标签"
  ensure_safe_ssh_for_singbox_restart || return 0
  start_managed_operation "enable-split:$name" || return 1
  run_managed_step state_set_split_status "$name" active || return 1
  rebuild_and_finish_split_operation || return 1
  log "分流已启用：$name"
}

cmd_split_remove() {
  local name="$1"
  split_exists "$name" || die "分流不存在：$name"
  ensure_safe_ssh_for_singbox_restart || return 0
  start_managed_operation "remove-split:$name" || return 1
  run_managed_step remove_split_config "$name" || return 1
  run_managed_step state_remove_split "$name" || return 1
  rebuild_and_finish_split_operation || return 1
  log "分流已删除：$name"
}

cmd_split_edit() {
  local name="$1" url="$2" scope="$3" user="$4" upstream="$5" out_tag="$6" rule_preset="${7:-}" outbound_preset="${8:-}" split old_out
  local runtime_rule_tag runtime_outbound_tag runtime_transport_tag
  split_exists "$name" || die "分流不存在：$name"
  [[ -z "$rule_preset" ]] || rule_preset_exists "$rule_preset" || die "预置规则不存在：$rule_preset"
  [[ -z "$outbound_preset" ]] || outbound_preset_exists "$outbound_preset" || die "预置出口不存在：$outbound_preset"
  split="$(jq -c --arg name "$name" '.splits[] | select(.name == $name)' "$STATE_FILE")"
  old_out="$(jq -r '.outbound_tag // ("managed-out-" + .name)' <<<"$split")"
  if [[ -n "$rule_preset" ]]; then runtime_rule_tag="$(stable_managed_tag rule "$rule_preset")" || return 1
  else runtime_rule_tag="$(split_runtime_rule_tag_from_json "$split")" || return 1
  fi
  if [[ -n "$outbound_preset" ]]; then
    runtime_outbound_tag="$(stable_managed_tag outbound "$outbound_preset")" || return 1
    runtime_transport_tag="$(stable_managed_tag transport "$outbound_preset")" || return 1
  else
    runtime_outbound_tag="$(split_runtime_out_tag_from_json "$split")" || return 1
    runtime_transport_tag="$(split_runtime_transport_tag_from_json "$split")" || return 1
  fi
  validate_outbound_tag "$out_tag"
  [[ "$url" == https://* ]] || die "远程规则集地址必须使用 HTTPS"
  split_rule_format "$url" >/dev/null || die "远程规则集地址必须指向 .srs 或 .json 文件"
  if [[ "$scope" == user ]]; then validate_name "$user"; user_exists "$user" || die "用户不存在：$user"; fi
  jq -e --arg name "$name" --arg out "$out_tag" '.splits[]? | select(.name != $name and (.outbound_tag // ("managed-out-" + .name)) == $out)' "$STATE_FILE" >/dev/null && die "出口名称已被其他分流使用，请换一个名称"
  [[ "$out_tag" != "$(split_transport_tag "$name")" ]] || die "出口名称与系统内部名称冲突，请换一个名称"
  jq -e --arg name "$name" --arg out "$out_tag" '.splits[]? | select(.name != $name and ("managed-transport-" + .name) == $out)' "$STATE_FILE" >/dev/null && die "出口名称与其他分流的内部名称冲突，请换一个名称"
  if [[ "$out_tag" != "$old_out" ]]; then
    jq -e --arg out "$out_tag" '.outbounds[]? | select(.tag == $out)' "$SINGBOX_CONFIG" >/dev/null && die "sing-box 已存在同名出站"
  fi
  validate_split_relationships "$name" "$runtime_rule_tag" "$runtime_outbound_tag" "$scope" "$user" false || return 1
  validate_remote_rule_set "$url"
  ensure_safe_ssh_for_singbox_restart || return 0
  start_managed_operation "edit-split:$name" || return 1
  run_managed_step remove_split_config "$name" || return 1
  run_managed_step state_replace_split "$name" "$url" "$scope" "$user" "$upstream" "$out_tag" "$rule_preset" "$outbound_preset" \
    "$runtime_rule_tag" "$runtime_outbound_tag" "$runtime_transport_tag" || return 1
  rebuild_and_finish_split_operation || return 1
  log "分流修改成功：$name"
}

cmd_split_move() {
  local name="$1" position="$2" count current group group_size others
  split_exists "$name" || die "分流不存在：$name"
  count="$(jq '.splits | length' "$STATE_FILE")"
  if [[ ! "$position" =~ ^[0-9]+$ ]] || ((position < 1 || position > count)); then
    die "目标优先级超出范围"
  fi
  current="$(jq -r --arg name "$name" '.splits | to_entries[] | select(.value.name == $name) | (.key + 1)' "$STATE_FILE")"
  group="$(split_merge_group_names "$name")" || return 1
  group_size="$(jq 'length' <<<"$group")" || return 1
  if [[ "$current" == "$position" && "$group_size" == 1 ]]; then echo "优先级未变化。"; return 0; fi
  ensure_safe_ssh_for_singbox_restart || return 0
  start_managed_operation "move-split:$name" || return 1
  run_managed_step state_move_split "$group" "$position" || return 1
  rebuild_and_finish_split_operation || return 1
  if ((group_size > 1)); then
    others="$(jq -r --arg name "$name" '[.[] | select(. != $name)] | join("、")' <<<"$group")" || return 1
    log "分流优先级已调整：${name} → ${position}（与 ${others} 共用同一套预置，在运行配置中合并为一条，已一并移动）"
  else
    log "分流优先级已调整：$name → $position"
  fi
}

cmd_split_list() {
  local ranks
  ranks="$(split_effective_match_ranks)" || return 1
  # 「匹配位置」是真正生效的先后顺序：合并成同一条路由的分流共用一个位置，
  # 只显示行号会让人以为它们能各自排序。
  SB_JQ_RANKS="$ranks" jq -r 'if (.splits|length)==0 then "暂无分流" else
    ($ENV.SB_JQ_RANKS | fromjson) as $ranks |
    (["顺序","匹配位置","名称","状态","范围","预置规则","预置出口"]|@tsv),
    (.splits|to_entries[]|[
      ((.key+1)|tostring),
      (($ranks[.value.name] // null) as $rank | if $rank == null then "—" else ("第 " + ($rank|tostring) + " 位") end),
      .value.name,
      (if .value.status=="active" then "启用" else "停用" end),
      (if .value.scope=="all" then "全部用户" else ("用户:"+.value.user) end),
      (.value.rule_preset // "独立配置"),
      (.value.outbound_preset // "独立配置")]|@tsv) end' "$STATE_FILE" | column -t -s $'\t'
}

cmd_split_show() {
  local name="$1" ranks group
  split_exists "$name" || die "分流不存在：$name"
  ranks="$(split_effective_match_ranks)" || return 1
  group="$(split_merge_group_names "$name")" || return 1
  # 「匹配位置」必须用真正生效的顺序，不能拿行号充数：合并成同一条路由的分流共用一个位置
  SB_JQ_RANKS="$ranks" SB_JQ_GROUP="$group" jq -r --arg name "$name" '
    ($ENV.SB_JQ_RANKS | fromjson) as $ranks |
    ($ENV.SB_JQ_GROUP | fromjson) as $group |
    .splits | to_entries[] | select(.value.name == $name) |
    .key as $index | .value as $s |
    "分流名称：\($s.name)",
    "列表顺序：第 \($index + 1) 条",
    "匹配位置：\(($ranks[$s.name] // null) as $rank | if $rank == null then "未生效（分流已停用）" else "第 \($rank) 位" end)",
    (if ($group | length) > 1 then
      "合并说明：与 \([$group[] | select(. != $name)] | join("、")) 共用同一套预置，在运行配置中合并为一条，匹配位置和顺序调整都作用于整组"
     else empty end),
    "状态：\(if $s.status == "active" then "启用" else "停用" end)",
    "作用范围：\(if $s.scope == "all" then "全部用户" else "用户:" + $s.user end)",
    "规则来源：\($s.rule_preset // "独立配置")",
    "规则集地址：\($s.url)",
    "出口来源：\($s.outbound_preset // "独立配置")",
    "出口协议：\(if $s.upstream.protocol == "anytls" then "AnyTLS" elif $s.upstream.protocol == "shadowsocks" then "Shadowsocks" elif $s.upstream.protocol == "ss_shadowtls" then "SS2022 + ShadowTLS" else "旧版未配置" end)",
    "出口服务器：\($s.upstream.server // "-"):\($s.upstream.server_port // "-")",
    (if ($s.upstream.method // "") != "" then "加密方式：\($s.upstream.method)" else empty end),
    (if ($s.upstream.sni // "") != "" then "TLS SNI：\($s.upstream.sni)" else empty end),
    (if ($s.upstream | has("insecure")) then "证书验证：\(if $s.upstream.insecure then "跳过" else "验证" end)" else empty end),
    "创建时间：\($s.created_at // "-")",
    (if ($s.updated_at // "") != "" then "修改时间：\($s.updated_at)" else empty end)
  ' "$STATE_FILE"
}
