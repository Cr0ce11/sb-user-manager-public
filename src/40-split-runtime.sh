
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

# 一个规则文件名在 mihomo 部署下的完整路径。
# 只接受目录下的一层文件名：SAFE_PATHS 覆盖的是这个目录，
# 而「只填文件名」也是界面上唯一需要使用者理解的东西。
mihomo_rule_file_path() {
  printf '%s/%s' "$MIHOMO_RULES_DIR" "$1"
}

validate_mihomo_rule_file_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] ||
    die "规则文件名只能包含字母、数字、点、下划线和连字符，长度 1-64，且不能以点开头"
}

# 规则文件的写法与配置里声明的 behavior 是否对得上。
#
# 这条检查存在的唯一理由是 **mihomo 在这件事上是静默的**：把「完整规则行」
# 按「域名列表」读，一条警告都没有，规则就是静静地不生效（公开 Issue #186 实测，
# 反方向只有 warning，也不会让服务起不来）。内核不报，就只能管理器来报。
#
# 刻意只在**确定对不上**时才拒绝，不做风格审查：这条护栏一旦误报，
# 使用者会学会绕过它，那比没有还糟。
# 输出第一条对不上的内容；全部合规时无输出。
mihomo_rule_file_mismatch() {
  local file="$1" behavior="$2"
  awk -v behavior="$behavior" '
    function trim(text) {
      sub(/^[[:space:]]+/, "", text); sub(/[[:space:]]+$/, "", text)
      return text
    }
    /^[[:space:]]*payload[[:space:]]*:/ { seen_payload = 1; next }
    {
      line = $0
      sub(/[[:space:]]*#.*$/, "", line)
      line = trim(line)
      if (line == "") next
      if (line !~ /^-[[:space:]]*/) next
      sub(/^-[[:space:]]*/, "", line)
      item = trim(line)
      gsub(/^["'"'"']|["'"'"']$/, "", item)
      if (item == "") next
      items++
      looks_like_rule = (item ~ /^[A-Z][A-Z0-9_-]*,/)
      if (behavior == "classical") {
        if (!looks_like_rule) { print "第 " NR " 行不是完整规则行：" item; exit }
      } else if (behavior == "domain") {
        if (looks_like_rule) { print "第 " NR " 行看着是完整规则行而不是域名：" item; exit }
      } else if (behavior == "ipcidr") {
        if (looks_like_rule) { print "第 " NR " 行看着是完整规则行而不是 IP 段：" item; exit }
        # 前缀长度可有可无：社区的 IP 清单里裸写一个地址是常见写法，
        # 为此报错就成了误报，而误报的护栏会被人学会绕过去。
        if (item !~ /^[0-9.]+(\/[0-9]+)?$/ && item !~ /^[0-9a-fA-F:]+(\/[0-9]+)?$/) {
          print "第 " NR " 行不是 IP 段写法：" item; exit
        }
      }
    }
    END {
      if (!seen_payload) { print "整个文件里没有 payload: 这一行"; exit }
      if (items == 0) { print "payload: 下面一条规则都没有"; exit }
    }
  ' "$file"
}

# mihomo 部署下的规则集来源：使用者自己放在规则目录里的一个块状 yaml 文件。
# 管理器只读它，永远不改它的内容（公开 Issue #157 的决定）。
validate_mihomo_rule_set() {
  local name="$1" behavior="$2" path mismatch
  validate_mihomo_rule_file_name "$name"
  case "$behavior" in
    classical|domain|ipcidr) ;;
    *) die "规则写法只能是 classical、domain 或 ipcidr：$behavior" ;;
  esac
  path="$(mihomo_rule_file_path "$name")"
  # 「文件在不在」是 mihomo -t 唯一测不出的一项：文件不存在时配置检查照样通过，
  # 服务也照样起得来，只在启动日志里留一行 error，规则则完全不生效
  # （公开 Issue #186 实测，与证书路径同一个毛病的镜像版本）。
  # 因此这里必须真的看一眼，不能等内核来说。
  [[ ! -L "$path" ]] || die "规则文件不能是符号链接：$path"
  [[ -f "$path" ]] || die "规则文件不存在：${path}；请先把规则文件放到 ${MIHOMO_RULES_DIR} 下"
  [[ -r "$path" ]] || die "规则文件无法读取：$path"
  mismatch="$(mihomo_rule_file_mismatch "$path" "$behavior")" || return 1
  [[ -z "$mismatch" ]] ||
    die "规则文件的内容与所选写法对不上：${mismatch}；选错写法时 mihomo 不会报错，规则会静静地不生效"
}

# 来源写法的校验。与「这个来源可不可用」分开：这一条只看写法，
# 界面上输入即时反馈用得到，不需要下载或读文件。
validate_split_rule_source_format() {
  case "$PROXY_KERNEL" in
    singbox)
      [[ "$1" == https://* ]] || die "规则集地址必须使用 HTTPS"
      split_rule_format "$1" >/dev/null || die "规则集地址必须指向 .srs 或 .json 文件"
      ;;
    mihomo) validate_mihomo_rule_file_name "$1" ;;
    *) kernel_unknown ;;
  esac
}

# 规则集来源的校验。两个内核的来源完全不同，格式也不通用：
# sing-box 是公网 HTTPS 上的 .srs / .json，由 sing-box 自己下载并检查；
# mihomo 是本机上一个块状 yaml 文件，由管理器检查存在性与写法。
validate_split_rule_source() {
  local source="$1" behavior="${2:-}"
  case "$PROXY_KERNEL" in
    singbox)
      validate_public_rule_set_url "$source" ||
        die "远程规则集地址必须使用 HTTPS，且不能指向本机或内网地址"
      check_rule_set_with_binary "$SINGBOX_BIN" "$source" ||
        die "远程规则集无法通过当前 sing-box 检查，请确认地址、格式和版本兼容性"
      ;;
    mihomo) validate_mihomo_rule_set "$source" "$behavior" ;;
    *) kernel_unknown ;;
  esac
}

# 规则集来源在状态里的取值。两个键在同一台机器上不会同时存在
# （见适配层的 kernel_rule_source_key），因此读取写成一个表达式即可。
split_rule_source_from_json() {
  jq -r '(.url // .rule_file // "")' <<<"$1"
}

split_rule_behavior_from_json() {
  jq -r '(.rule_behavior // "")' <<<"$1"
}

# 规则来源在界面上的写法。sing-box 是完整地址，mihomo 是文件名加写法说明。
split_rule_source_display() {
  local source="$1" behavior="$2"
  case "$PROXY_KERNEL" in
    singbox) printf '%s' "$source" ;;
    mihomo) printf '%s（%s）' "$(mihomo_rule_file_path "$source")" "$(mihomo_rule_behavior_label "$behavior")" ;;
    *) kernel_unknown ;;
  esac
}

mihomo_rule_behavior_label() {
  case "$1" in
    classical) printf '完整规则行' ;;
    domain) printf '域名列表' ;;
    ipcidr) printf 'IP 段列表' ;;
    *) printf '未知写法' ;;
  esac
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
  case "$PROXY_KERNEL" in
    singbox)
      rewrite_kernel_config '
        .route.rules = [(.route.rules // [])[] | select(((.rule_set // "") == $tag or (.rule_set // "") == $stored_tag) | not)] |
        .route.rule_set = [(.route.rule_set // [])[] | select((.tag == $tag or .tag == $stored_tag) | not)] |
        .outbounds = [(.outbounds // [])[] |
          select((.tag == $out_tag or .tag == $transport_tag or .tag == $stored_out or .tag == $stored_transport) | not)]
      ' --arg tag "$tag" --arg stored_tag "$stored_tag" --arg out_tag "$out_tag" --arg transport_tag "$transport_tag" \
        --arg stored_out "$stored_out" --arg stored_transport "$stored_transport"
      ;;
    mihomo)
      # 托管的分流条目分布在三处：proxies 里的出口、rule-providers 里的规则集、
      # 以及 sub-rules 里那一块规则。顶层 rules 里只有一条派发，
      # 它与具体某条分流无关，因此这里不动——使用者自己写在 rules 里的东西同理。
      #
      # sub-rules 里按规则集标签认自己的行。行的形状只有两种，都由
      # kernel_render_split_plan 生成：
      #   RULE-SET,<规则集>,<出口>
      #   AND,((RULE-SET,<规则集>),(IN-NAME,...)),<出口>
      # 与 sing-box 那一支同样按标签删，因此「多条分流共用同一个预置规则时
      # 一起被删掉」这个语义两个内核一致，随后的整体重建会把该留的补回来。
      rewrite_kernel_config "$MIHOMO_SPLIT_RULE_DEFS"'
        .proxies = [(.proxies // [])[] |
          select((.name == $out_tag or .name == $transport_tag or .name == $stored_out or .name == $stored_transport) | not)] |
        .["rule-providers"] = ((.["rule-providers"] // {}) |
          with_entries(select(.key != $tag and .key != $stored_tag))) |
        (if (.["sub-rules"] // {}) | has($sub_rule) then
           .["sub-rules"][$sub_rule] = [(.["sub-rules"][$sub_rule] // [])[] |
             select(sbm_line_owned_by(.; [$tag, $stored_tag]) | not)]
         else . end)
      ' --arg tag "$tag" --arg stored_tag "$stored_tag" --arg out_tag "$out_tag" --arg transport_tag "$transport_tag" \
        --arg stored_out "$stored_out" --arg stored_transport "$stored_transport" \
        --arg sub_rule "$MIHOMO_MANAGED_SUB_RULE"
      ;;
    *) kernel_unknown ;;
  esac
}

# 上游出口的托管条目。形状与条目数量都随内核不同，因此实现在适配层，
# 这里只补上「没有显式给传输标签时用默认名」这一条与内核无关的规则。
build_split_outbounds() {
  local name="$1" upstream="$2" out_tag="$3" transport_tag="${4:-}"
  [[ -n "$transport_tag" ]] || transport_tag="$(split_transport_tag "$name")"
  kernel_split_outbounds "$name" "$upstream" "$out_tag" "$transport_tag"
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
  local upstream="$1" name out_tag outbounds candidate container runtime_config
  validate_upstream_json "$upstream" || die "预置出口内容不完整或格式无效"
  name="preset-check-${BASHPID:-$$}"
  out_tag="${name}-out"
  outbounds="$(build_split_outbounds "$name" "$upstream" "$out_tag")" || return 1
  candidate="$(mktemp /tmp/sb-preset-outbound.XXXXXX.json)" || return 1
  register_temp_path "$candidate"
  # 出口容器的键名随内核不同（sing-box 的 outbounds、mihomo 的 proxies），
  # 校验用的也必须是当前内核自己的运行配置——拿 mihomo 去检查一份
  # sing-box 配置，报出来的东西没有任何意义。
  container="$(kernel_split_outbound_container)" || return 1
  runtime_config="$(kernel_runtime_config_path)" || return 1
  if ! SB_JQ_OUTBOUNDS="$outbounds" jq --arg container "$container" \
        '($ENV.SB_JQ_OUTBOUNDS | fromjson) as $outbounds | .[$container] = ((.[$container] // []) + $outbounds)' \
        "$runtime_config" > "$candidate" ||
     ! kernel_check_config "$candidate" >/dev/null 2>&1; then
    rm -f -- "$candidate"
    die "预置出口无法通过当前 $(kernel_display_name) 检查，请确认协议和连接参数"
  fi
  rm -f -- "$candidate"
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

# 旧版分流的清理只对 sing-box 有意义：托管分流在 mihomo 上从第二步 2d 才开始
# 存在，不可能有「按旧写法留下的残留」。显式判断而不是依赖「查出来恰好是空的」
# ——那种依赖读起来像是碰巧成立。
legacy_split_cleanup_pending() {
  local config tags cleanup
  [[ "$PROXY_KERNEL" == singbox ]] || return 1
  config="$(kernel_normalized_config)" || return 1
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
  case "$PROXY_KERNEL" in
    singbox)
      rewrite_kernel_config '
        .route.rules = [(.route.rules // [])[] | . as $item | select(($rule_tags | index($item.rule_set // "")) == null)] |
        .route.rule_set = [(.route.rule_set // [])[] | . as $item | select(($rule_tags | index($item.tag)) == null)] |
        .outbounds = [(.outbounds // [])[] | . as $item | select((($out_tags + $transport_tags) | index($item.tag)) == null)]
      ' --argjson rule_tags "$rule_tags" --argjson out_tags "$out_tags" --argjson transport_tags "$transport_tags"
      ;;
    mihomo)
      # 托管的四处一并清掉，包括顶层 rules 里那一条派发——这里是「把托管分流
      # 全部撤走」，留着一条指向已不存在的 sub-rule 的派发会让配置加载不了。
      rewrite_kernel_config '
        .proxies = [(.proxies // [])[] | . as $item | select((($out_tags + $transport_tags) | index($item.name)) == null)] |
        .["rule-providers"] = ((.["rule-providers"] // {}) |
          with_entries(select(.key as $key | ($rule_tags | index($key)) == null))) |
        .["sub-rules"] = ((.["sub-rules"] // {}) | del(.[$sub_rule])) |
        .rules = [(.rules // [])[] | select((type == "string" and endswith("," + $sub_rule)) | not)]
      ' --argjson rule_tags "$rule_tags" --argjson out_tags "$out_tags" --argjson transport_tags "$transport_tags" \
        --arg sub_rule "$MIHOMO_MANAGED_SUB_RULE"
      ;;
    *) kernel_unknown ;;
  esac
}

# 一个用户在当前内核下的全部托管入口名。用户专属分流按这些名字限定范围。
# SS2022 + ShadowTLS 的条目数两个内核不同，因此前缀从适配层取。
split_user_inbound_tags() {
  local user="$1" shadowtls_prefixes
  shadowtls_prefixes="$(kernel_shadowtls_entry_prefixes)" || return 1
  jq -c --arg name "$user" --argjson st_prefixes "$shadowtls_prefixes" '
    first(.users[]? | select(.name == $name)) as $user |
    if $user == null then []
    else (if ($user.endpoints | type) == "array" then $user.endpoints
          else [{protocol:($user.protocol // "ss2022"),transport:($user.transport // "shadowtls")}] end) as $endpoints |
    ($endpoints | any(.protocol == "ss2022" and .transport == "shadowtls")) as $has_legacy |
    [ $endpoints[] |
      if .protocol == "anytls" then "anytls-" + $name
      elif .transport == "shadowtls" then ($st_prefixes[] + $name)
      elif $has_legacy then "ss-direct-" + $name
      else "ss-" + $name end
    ] | unique end
  ' "$STATE_FILE"
}

# 与内核无关的分流计划：哪条规则集配哪个出口、限定哪些入口、按什么顺序。
# 出口条目与规则集条目本身已经是内核形状（由适配层生成），计划只负责摆放；
# 最后一步的渲染同样在适配层——sing-box 的路由是对象数组，mihomo 是字符串数组。
build_split_runtime_plan() {
  local split_rows split plan name source behavior scope user user_status upstream out_tag rule_tag transport_tag outbounds rule_set inbounds conflict rule_file_path
  split_rows="$(jq -c '.splits[] | select(.status == "active")' "$STATE_FILE")" || return 1
  plan='{"outbound_groups":[],"rule_sets":[],"routes":[]}'
  while IFS= read -r split; do
    [[ -n "$split" ]] || continue
    name="$(jq -er '.name | select(type == "string" and length > 0)' <<<"$split")" || return 1
    source="$(jq -er '(.url // .rule_file) | select(type == "string" and length > 0)' <<<"$split")" || return 1
    behavior="$(split_rule_behavior_from_json "$split")" || return 1
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
    outbounds="$(build_split_outbounds "$name" "$upstream" "$out_tag" "$transport_tag")" || return 1
    # 规则文件是使用者自己的，添加之后随时可能被他删掉或改名。
    # 这是 `mihomo -t` 唯一测不出的一项：文件不在时配置检查照样通过、服务也照样
    # 起得来，只在启动日志里留一行 error，而那条分流从此静静地不生效
    # ——本该走上游的流量会改走直连。因此每次重建都真的看一眼。
    # 计划在任何配置改动之前完整生成，这里失败不会留下改了一半的运行配置。
    if [[ "$PROXY_KERNEL" == mihomo ]]; then
      rule_file_path="$(mihomo_rule_file_path "$source")"
      if [[ ! -f "$rule_file_path" || -L "$rule_file_path" ]]; then
        printf '错误：分流 %s 的规则文件不存在或不是普通文件：%s\n' "$name" "$rule_file_path" >&2
        printf '请把该文件放回原处后重试；在此之前这条分流不会生效。\n' >&2
        return 1
      fi
    fi
    rule_set="$(kernel_split_rule_set_entry "$rule_tag" "$source" "$behavior")" || return 1
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
        echo "错误：多个分流使用了同一条预置规则名称，但规则来源不同；请重新选择预置规则。" >&2
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
  kernel_render_split_plan "$plan"
}

rebuild_all_split_configs() {
  local plan tags config legacy_cleanup
  # 先完整生成计划，任何读取、冲突或格式错误都不得提前改动现有配置。
  plan="$(build_split_runtime_plan)" || return 1
  tags="$(collect_managed_split_tags)" || return 1
  case "$PROXY_KERNEL" in
    singbox)
      config="$(kernel_normalized_config)" || return 1
      legacy_cleanup="$(collect_legacy_split_cleanup_plan_from_config "$config" "$tags")" || return 1
      SB_JQ_PLAN="$plan" rewrite_kernel_config '
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
      ;;
    mihomo)
      # 归属划分（公开 Issue #186）：proxies 与 rule-providers 按名字认领，
      # 外来的原样保留；sub-rules 里那一块整块归管理器；顶层 rules 里
      # 管理器只留一条派发，其余全是使用者的，原样保留。
      #
      # 派发放在最前面：使用者若在 rules 里写了 MATCH，放在后面会把整块托管
      # 分流盖掉。派发落空时流量继续走后面（使用者自己的）规则，这一点有实测。
      # 没有任何启用中的分流时不写派发，也不写空的 sub-rule——一条指向不存在
      # sub-rule 的派发会让 mihomo 直接拒绝加载配置。
      #
      # 认自己那条派发的办法是「以托管 sub-rule 名结尾」，而不是与常量整条相等：
      # 派发条件将来若改写法，按整条相等会认不出旧的那条，于是每次重建多留一条。
      # 代价是使用者若把自己的出口取名叫 managed-splits，指向它的规则会被一并
      # 拿掉——那个名字是管理器保留的，不该被拿去当出口名。
      #
      # mihomo 部署没有旧版分流的历史包袱：托管分流在 mihomo 上从本片才开始存在。
      SB_JQ_PLAN="$plan" rewrite_kernel_config '
        ($ENV.SB_JQ_PLAN | fromjson) as $plan |
        .proxies = [(.proxies // [])[] | . as $item |
          select((($tags.out_tags + $tags.transport_tags) | index($item.name)) == null)] |
        .proxies += $plan.proxies |
        .["rule-providers"] = ((.["rule-providers"] // {}) |
          with_entries(select(.key as $key | ($tags.rule_tags | index($key)) == null)) +
          $plan.rule_providers) |
        .["sub-rules"] = ((.["sub-rules"] // {}) | del(.[$sub_rule])) |
        .rules = [(.rules // [])[] | select((type == "string" and endswith("," + $sub_rule)) | not)] |
        (if ($plan.sub_rules | length) > 0 then
           .["sub-rules"][$sub_rule] = $plan.sub_rules |
           .rules = [$dispatch] + .rules
         else . end) |
        (if (.["sub-rules"] | length) == 0 then del(.["sub-rules"]) else . end) |
        (if (.["rule-providers"] | length) == 0 then del(.["rule-providers"]) else . end)
      ' --argjson tags "$tags" --arg sub_rule "$MIHOMO_MANAGED_SUB_RULE" \
        --arg dispatch "$MIHOMO_SPLIT_DISPATCH_RULE"
      ;;
    *) kernel_unknown ;;
  esac
}

rebuild_and_finish_split_operation() {
  run_managed_step rebuild_all_split_configs || return 1
  run_managed_step check_singbox_and_restart || return 1
  finish_managed_operation || return 1
}

# 拿运行配置与期望标签做比对的地方都必须经这里读入：规范化程序按内核分派，
# 定义在适配层，与骨架、托管容器那几项同源（公开 Issue #189）。
singbox_config_for_comparison() {
  local program
  program="$(kernel_config_normalise_program)" || return 1
  kernel_normalized_config | jq -c "$program"
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
  # 这是一次性整理历史 sing-box 数据的流程，其它内核的部署里没有对应的历史包袱。
  # 显式判断而不是依赖「sing-box 文件恰好不存在」——那种依赖在一台两个内核
  # 的二进制都还留着的机器上会失效。
  [[ "$PROXY_KERNEL" == singbox ]] || return 0
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
  # 这是一次性整理历史 sing-box 数据的流程，其它内核的部署里没有对应的历史包袱。
  # 显式判断而不是依赖「sing-box 文件恰好不存在」——那种依赖在一台两个内核
  # 的二进制都还留着的机器上会失效。
  [[ "$PROXY_KERNEL" == singbox ]] || return 0
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
  if ! ensure_safe_ssh_for_kernel_restart; then release_operation_lock; return 0; fi
  if ! start_managed_operation migrate-shared-presets; then release_operation_lock; return 1; fi
  if ! rebuild_and_finish_split_operation; then
    release_operation_lock
    return 1
  fi
  write_shared_preset_runtime_marker || { release_operation_lock; return 1; }
  log "已将重复的预置规则和出口合并为共享配置"
  release_operation_lock
}

# 规则来源的键名随内核不同（sing-box 的 url、mihomo 的 rule_file），
# 因此写入时取键名而不是写死；behavior 只有 mihomo 用得上，为空时不写这个键，
# 这样 sing-box 机器的状态文件与历史版本一字不差。
state_add_split() {
  local source_key
  source_key="$(kernel_rule_source_key)" || return 1
  SB_JQ_UPSTREAM="$5" atomic_state_update '(
    $ENV.SB_JQ_UPSTREAM | fromjson
  ) as $upstream |
    .splits += [{name:$name,scope:$scope,user:(if $scope == "user" then $user else null end),upstream:$upstream,outbound_tag:$out_tag,rule_set_tag:$rule_tag,
      runtime_rule_tag:$runtime_rule_tag,runtime_outbound_tag:$runtime_outbound_tag,runtime_transport_tag:$runtime_transport_tag,
      rule_preset:$rule_preset,outbound_preset:$outbound_preset,status:"active",created_at:$created_at}
      | .[$source_key] = $source
      | (if $behavior == "" then . else .rule_behavior = $behavior end)
      | (if $rule_preset == "" then del(.rule_preset) else . end)
      | (if $outbound_preset == "" then del(.outbound_preset) else . end)]
  ' --arg name "$1" --arg source "$2" --arg scope "$3" --arg user "$4" \
    --arg out_tag "$6" --arg rule_tag "$7" --arg rule_preset "$8" --arg outbound_preset "$9" \
    --arg runtime_rule_tag "${10}" --arg runtime_outbound_tag "${11}" --arg runtime_transport_tag "${12}" \
    --arg behavior "${13:-}" --arg source_key "$source_key" \
    --arg created_at "$(date -Iseconds)"
}

state_set_split_status() {
  atomic_state_update '(.splits[] | select(.name == $name) | .status) = $status' \
    --arg name "$1" --arg status "$2"
}

state_replace_split() {
  local source_key
  source_key="$(kernel_rule_source_key)" || return 1
  SB_JQ_UPSTREAM="$5" atomic_state_update '(
    $ENV.SB_JQ_UPSTREAM | fromjson
  ) as $upstream |
    (.splits[] | select(.name == $name)) |=
      (. + {scope:$scope,user:(if $scope == "user" then $user else null end),upstream:$upstream,outbound_tag:$out_tag,
        runtime_rule_tag:$runtime_rule_tag,runtime_outbound_tag:$runtime_outbound_tag,runtime_transport_tag:$runtime_transport_tag,
        updated_at:$updated_at}
       | .[$source_key] = $source
       | (if $behavior == "" then . else .rule_behavior = $behavior end)
       | (if $rule_preset == "" then del(.rule_preset) else .rule_preset = $rule_preset end)
       | (if $outbound_preset == "" then del(.outbound_preset) else .outbound_preset = $outbound_preset end))
  ' --arg name "$1" --arg source "$2" --arg scope "$3" --arg user "$4" \
    --arg out_tag "$6" --arg rule_preset "$7" --arg outbound_preset "$8" \
    --arg runtime_rule_tag "$9" --arg runtime_outbound_tag "${10}" --arg runtime_transport_tag "${11}" \
    --arg behavior "${12:-}" --arg source_key "$source_key" \
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
  local source_key
  source_key="$(kernel_rule_source_key)" || return 1
  atomic_state_update '
    .rule_presets += [{name:$name,created_at:$created_at}
      | .[$source_key] = $source
      | (if $behavior == "" then . else .rule_behavior = $behavior end)]
  ' --arg name "$1" --arg source "$2" --arg behavior "${3:-}" \
    --arg source_key "$source_key" --arg created_at "$(date -Iseconds)"
}

state_replace_rule_preset() {
  local source_key
  source_key="$(kernel_rule_source_key)" || return 1
  atomic_state_update '
    def apply_source: .[$source_key] = $source |
      (if $behavior == "" then . else .rule_behavior = $behavior end);
    (.rule_presets[] | select(.name == $name)) |= ((. + {updated_at:$updated_at}) | apply_source) |
    .splits |= map(
      if (.rule_preset // "") == $name then
        ((. + {updated_at:$updated_at}) | apply_source)
      else . end
    )
  ' --arg name "$1" --arg source "$2" --arg behavior "${3:-}" \
    --arg source_key "$source_key" --arg updated_at "$(date -Iseconds)"
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
  local source_key
  source_key="$(kernel_rule_source_key)" || return 1
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
         if $rule == null then del(.rule_preset)
         else .[$source_key] = ($rule.url // $rule.rule_file) |
              (if ($rule.rule_behavior // "") == "" then . else .rule_behavior = $rule.rule_behavior end)
         end
       else . end)
    )
  ' --arg source_key "$source_key"
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
    ensure_safe_ssh_for_kernel_restart || return 0
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
  local name="$1" source="$2" behavior="${3:-}"
  validate_preset_name "$name"
  rule_preset_exists "$name" && die "同名预置规则已经存在"
  validate_split_rule_source_format "$source"
  validate_split_rule_source "$source" "$behavior"
  state_add_rule_preset "$name" "$source" "$behavior" || return 1
  log "预置规则已保存：${name}；它不会改变当前分流"
}

cmd_rule_preset_edit() {
  local name="$1" source="$2" behavior="${3:-}" active
  rule_preset_exists "$name" || die "预置规则不存在：$name"
  validate_split_rule_source_format "$source"
  validate_split_rule_source "$source" "$behavior"
  active="$(jq --arg name "$name" '[.splits[] | select((.rule_preset // "") == $name and .status == "active")] | length' "$STATE_FILE")" || return 1
  if ((active == 0)); then
    state_replace_rule_preset "$name" "$source" "$behavior" || return 1
  else
    ensure_safe_ssh_for_kernel_restart || return 0
    start_managed_operation "edit-rule-preset:$name" || return 1
    run_managed_step state_replace_rule_preset "$name" "$source" "$behavior" || return 1
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

# 运行配置里是否已经存在同名的规则集 / 出口。
# 两个内核的容器与标识字段都不同：sing-box 是 route.rule_set[] 的 tag 与
# outbounds[] 的 tag，mihomo 是 rule-providers{} 的键与 proxies[] 的 name。
# 这两条检查的目的两个内核一致——不要覆盖掉不是管理器放进去的东西。
runtime_config_has_rule_set() {
  local tag="$1" config
  config="$(kernel_runtime_config_path)" || return 1
  case "$PROXY_KERNEL" in
    singbox) jq -e --arg tag "$tag" '.route.rule_set[]? | select(.tag == $tag)' "$config" >/dev/null ;;
    mihomo) jq -e --arg tag "$tag" '(.["rule-providers"] // {}) | has($tag)' "$config" >/dev/null ;;
    *) kernel_unknown ;;
  esac
}

runtime_config_has_outbound() {
  local config container key tags
  config="$(kernel_runtime_config_path)" || return 1
  container="$(kernel_split_outbound_container)" || return 1
  key="$(kernel_managed_key)" || return 1
  tags="$(printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0))')" || return 1
  # 先把元素绑成 $item 再进 index：jq 里函数参数是按 index 自己的输入求值的，
  # 直接写 index(.[$key]) 会拿 $tags 当输入，报「Cannot index array with string」。
  jq -e --arg container "$container" --arg key "$key" --argjson tags "$tags" \
    '(.[$container] // [])[] | . as $item | select(($tags | index($item[$key])) != null)' "$config" >/dev/null
}

# 审计要向运行配置提的四个问题。两个内核的托管分流摆在完全不同的地方
# （sing-box 在 route.rule_set／outbounds／route.rules，mihomo 在
# rule-providers／proxies／sub-rules），但问题是同一批，因此按内核分派，
# 不让审计那边各写一遍。
#
# $config 是已规范化的运行配置；$lines 是 mihomo 托管 sub-rule 里的那一块
# （sing-box 上恒为空数组，不使用）。mihomo 那几支用的规则行判断来自适配层，
# 与生成它们的渲染函数放在一起。

# 这条分流的规则集、出口与路由是不是都在。
split_audit_runtime_complete() {
  local config="$1" lines="$2" rule="$3" out="$4"
  case "$PROXY_KERNEL" in
    singbox)
      jq -e --arg tag "$rule" '.route.rule_set[]? | select(.tag == $tag)' <<<"$config" >/dev/null &&
      jq -e --arg out "$out" '.outbounds[]? | select(.tag == $out)' <<<"$config" >/dev/null &&
      jq -e --arg rule "$rule" --arg out "$out" \
        '.route.rules[]? | select(.rule_set == $rule and .outbound == $out)' <<<"$config" >/dev/null
      ;;
    mihomo)
      jq -e --arg rule "$rule" --arg out "$out" --argjson lines "$lines" "$MIHOMO_SPLIT_RULE_DEFS"'
        ((.["rule-providers"] // {}) | has($rule)) and
        any(.proxies[]?; .name == $out) and
        any($lines[]; sbm_line_routes(.; $rule; $out))' <<<"$config" >/dev/null
      ;;
    *) kernel_unknown ;;
  esac
}

# 这条分流有没有一条限定到某个用户入口的路由。
# mode=all 要求覆盖该用户的全部入口（回答「有没有覆盖用户的全部连接」），
# mode=any 只要沾上任意一个入口就算（回答「已停用之后规则是不是还在生效」）。
split_audit_user_rule_present() {
  local config="$1" lines="$2" rule="$3" out="$4" tags="$5" mode="$6"
  case "$PROXY_KERNEL" in
    singbox)
      if [[ "$mode" == all ]]; then
        jq -e --arg rule "$rule" --arg out "$out" --argjson expected "$tags" '
          .route.rules[]? | select(.rule_set == $rule and .outbound == $out and
            ($expected - (.inbound // []) | length) == 0)' <<<"$config" >/dev/null
      else
        jq -e --arg rule "$rule" --arg out "$out" --argjson expected "$tags" '
          .route.rules[]? | select(.rule_set == $rule and .outbound == $out and
            ([.inbound[]? as $tag | select($expected | index($tag) != null)] | length) > 0)' <<<"$config" >/dev/null
      fi
      ;;
    mihomo)
      if [[ "$mode" == all ]]; then
        jq -e --arg rule "$rule" --arg out "$out" --argjson expected "$tags" --argjson lines "$lines" \
          "$MIHOMO_SPLIT_RULE_DEFS"'
          any($lines[]; sbm_line_routes(.; $rule; $out) and sbm_line_covers(.; $expected))' <<<"$config" >/dev/null
      else
        jq -e --arg rule "$rule" --arg out "$out" --argjson expected "$tags" --argjson lines "$lines" \
          "$MIHOMO_SPLIT_RULE_DEFS"'
          any($lines[]; sbm_line_routes(.; $rule; $out) and sbm_line_touches(.; $rule; $expected))' <<<"$config" >/dev/null
      fi
      ;;
    *) kernel_unknown ;;
  esac
}

# 不限入口的那一条路由在不在。已停用的「全部用户」分流不该还留着它。
split_audit_scope_all_rule_present() {
  local config="$1" lines="$2" rule="$3" out="$4"
  case "$PROXY_KERNEL" in
    singbox)
      jq -e --arg rule "$rule" --arg out "$out" '
        .route.rules[]? | select(.rule_set == $rule and .outbound == $out and
          ((.inbound // []) | length == 0))' <<<"$config" >/dev/null
      ;;
    mihomo)
      jq -e --arg rule "$rule" --arg out "$out" --argjson lines "$lines" "$MIHOMO_SPLIT_RULE_DEFS"'
        any($lines[]; sbm_line_scope_all(.; $rule; $out))' <<<"$config" >/dev/null
      ;;
    *) kernel_unknown ;;
  esac
}

# 顶层那条派发与托管 sub-rule 的内容是否对得上：有内容就必须有派发，
# 没内容就不该留着派发。**只有 mihomo 有这一层**，sing-box 的路由规则直接摆在
# route.rules 里，不经过派发。
# 派发被删掉时整块分流一条都不生效，而运行配置本身完全合法、服务照常运行
# ——没有这条检查，就没有任何地方会把它说出来。
split_audit_dispatch_consistent() {
  local config="$1" lines="$2"
  case "$PROXY_KERNEL" in
    singbox) return 0 ;;
    mihomo)
      jq -e --argjson lines "$lines" --arg dispatch "$MIHOMO_SPLIT_DISPATCH_RULE" '
        (($lines | length) > 0) == (any(.rules[]?; . == $dispatch))' <<<"$config" >/dev/null
      ;;
    *) kernel_unknown ;;
  esac
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
  local name="$1" source="$2" scope="$3" user="$4" upstream="$5" out_tag="$6" rule_preset="${7:-}" outbound_preset="${8:-}" behavior="${9:-}" rule_tag="$1"
  local runtime_rule_tag runtime_outbound_tag runtime_transport_tag kernel_name
  kernel_name="$(kernel_display_name)" || return 1
  validate_split_name "$name"; split_exists "$name" && die "分流规则已存在：$name"
  rule_preset_exists "$rule_preset" || die "预置规则不存在：$rule_preset"
  outbound_preset_exists "$outbound_preset" || die "预置出口不存在：$outbound_preset"
  validate_outbound_tag "$out_tag"
  runtime_rule_tag="$(stable_managed_tag rule "$rule_preset")" || return 1
  runtime_outbound_tag="$(stable_managed_tag outbound "$outbound_preset")" || return 1
  runtime_transport_tag="$(stable_managed_tag transport "$outbound_preset")" || return 1
  validate_split_rule_source_format "$source"
  if [[ "$scope" == user ]]; then validate_name "$user"; user_exists "$user" || die "用户不存在：$user"; fi
  runtime_config_has_rule_set "$rule_tag" && die "${kernel_name} 已存在同名规则集标签"
  jq -e --arg out "$out_tag" '.splits[]? | select((.outbound_tag // ("managed-out-" + .name)) == $out)' "$STATE_FILE" >/dev/null && die "出口名称已被其他分流使用，请换一个名称"
  [[ "$out_tag" != "$(split_transport_tag "$name")" ]] || die "出口名称与系统内部名称冲突，请换一个名称"
  jq -e --arg out "$out_tag" '.splits[]? | select(("managed-transport-" + .name) == $out)' "$STATE_FILE" >/dev/null && die "出口名称与其他分流的内部名称冲突，请换一个名称"
  runtime_config_has_outbound "$out_tag" "$(split_transport_tag "$name")" && die "${kernel_name} 已存在同名分流出站标签"
  if runtime_config_has_rule_set "$runtime_rule_tag" &&
     ! runtime_rule_tag_owned_by_state "$runtime_rule_tag"; then
    die "这个预置规则与现有 ${kernel_name} 配置重名，请更换预置名称"
  fi
  if runtime_config_has_outbound "$runtime_outbound_tag" &&
     ! runtime_outbound_tag_owned_by_state "$runtime_outbound_tag"; then
    die "这个预置出口与现有 ${kernel_name} 配置重名，请更换预置名称"
  fi
  validate_split_relationships "$name" "$runtime_rule_tag" "$runtime_outbound_tag" "$scope" "$user" false || return 1
  validate_split_rule_source "$source" "$behavior"
  ensure_safe_ssh_for_kernel_restart || return 0
  start_managed_operation "add-split:$name" || return 1
  run_managed_step state_add_split "$name" "$source" "$scope" "$user" "$upstream" "$out_tag" "$rule_tag" "$rule_preset" "$outbound_preset" \
    "$runtime_rule_tag" "$runtime_outbound_tag" "$runtime_transport_tag" "$behavior" || return 1
  rebuild_and_finish_split_operation || return 1
  log "分流增加成功：$name"
}

cmd_split_disable() {
  local name="$1" split
  split_exists "$name" || die "分流不存在：$name"; split="$(jq -c --arg name "$name" '.splits[] | select(.name == $name)' "$STATE_FILE")"
  [[ "$(jq -r '.status' <<<"$split")" == active ]] || die "分流已经停用"
  ensure_safe_ssh_for_kernel_restart || return 0
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
  runtime_config_has_outbound "$out_tag" "$(split_transport_tag "$name")" && die "$(kernel_display_name) 已存在同名分流出站标签"
  runtime_config_has_rule_set "$rule_tag" && die "$(kernel_display_name) 已存在同名规则集标签"
  ensure_safe_ssh_for_kernel_restart || return 0
  start_managed_operation "enable-split:$name" || return 1
  run_managed_step state_set_split_status "$name" active || return 1
  rebuild_and_finish_split_operation || return 1
  log "分流已启用：$name"
}

cmd_split_remove() {
  local name="$1"
  split_exists "$name" || die "分流不存在：$name"
  ensure_safe_ssh_for_kernel_restart || return 0
  start_managed_operation "remove-split:$name" || return 1
  run_managed_step remove_split_config "$name" || return 1
  run_managed_step state_remove_split "$name" || return 1
  rebuild_and_finish_split_operation || return 1
  log "分流已删除：$name"
}

cmd_split_edit() {
  local name="$1" source="$2" scope="$3" user="$4" upstream="$5" out_tag="$6" rule_preset="${7:-}" outbound_preset="${8:-}" behavior="${9:-}" split old_out
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
  validate_split_rule_source_format "$source"
  if [[ "$scope" == user ]]; then validate_name "$user"; user_exists "$user" || die "用户不存在：$user"; fi
  jq -e --arg name "$name" --arg out "$out_tag" '.splits[]? | select(.name != $name and (.outbound_tag // ("managed-out-" + .name)) == $out)' "$STATE_FILE" >/dev/null && die "出口名称已被其他分流使用，请换一个名称"
  [[ "$out_tag" != "$(split_transport_tag "$name")" ]] || die "出口名称与系统内部名称冲突，请换一个名称"
  jq -e --arg name "$name" --arg out "$out_tag" '.splits[]? | select(.name != $name and ("managed-transport-" + .name) == $out)' "$STATE_FILE" >/dev/null && die "出口名称与其他分流的内部名称冲突，请换一个名称"
  if [[ "$out_tag" != "$old_out" ]]; then
    runtime_config_has_outbound "$out_tag" && die "$(kernel_display_name) 已存在同名出站"
  fi
  validate_split_relationships "$name" "$runtime_rule_tag" "$runtime_outbound_tag" "$scope" "$user" false || return 1
  validate_split_rule_source "$source" "$behavior"
  ensure_safe_ssh_for_kernel_restart || return 0
  start_managed_operation "edit-split:$name" || return 1
  run_managed_step remove_split_config "$name" || return 1
  run_managed_step state_replace_split "$name" "$source" "$scope" "$user" "$upstream" "$out_tag" "$rule_preset" "$outbound_preset" \
    "$runtime_rule_tag" "$runtime_outbound_tag" "$runtime_transport_tag" "$behavior" || return 1
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
  ensure_safe_ssh_for_kernel_restart || return 0
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
    (if $kernel == "mihomo" then
       "规则文件：\($rules_dir)/\($s.rule_file // "?")",
       "规则写法：\(if $s.rule_behavior == "classical" then "完整规则行" elif $s.rule_behavior == "domain" then "域名列表" elif $s.rule_behavior == "ipcidr" then "IP 段列表" else "未知写法" end)"
     else "规则集地址：\($s.url)" end),
    "出口来源：\($s.outbound_preset // "独立配置")",
    "出口协议：\(if $s.upstream.protocol == "anytls" then "AnyTLS" elif $s.upstream.protocol == "shadowsocks" then "Shadowsocks" elif $s.upstream.protocol == "ss_shadowtls" then "SS2022 + ShadowTLS" else "旧版未配置" end)",
    "出口服务器：\($s.upstream.server // "-"):\($s.upstream.server_port // "-")",
    (if ($s.upstream.method // "") != "" then "加密方式：\($s.upstream.method)" else empty end),
    (if ($s.upstream.sni // "") != "" then "TLS SNI：\($s.upstream.sni)" else empty end),
    (if ($s.upstream | has("insecure")) then "证书验证：\(if $s.upstream.insecure then "跳过" else "验证" end)" else empty end),
    "创建时间：\($s.created_at // "-")",
    (if ($s.updated_at // "") != "" then "修改时间：\($s.updated_at)" else empty end)
  ' --arg kernel "$PROXY_KERNEL" --arg rules_dir "$MIHOMO_RULES_DIR" "$STATE_FILE"
}
