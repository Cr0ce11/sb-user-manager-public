# 内核适配层。所有对代理内核可执行文件的直接调用都集中在本模块，
# 其它模块只经由这里定义的函数与内核交互。
# 这样做的原因：上游内核会在小版本之间修改配置规范与命令行接口，
# 调用点散落在各模块时，每次跟进都要同时改多处；集中之后只改这里一处。
#
# 本模块按 $PROXY_KERNEL 分派。分派刻意只写在「取名字与路径」的存取函数和
# 「命令行写法本来就不同」的少数函数里，其余函数经存取函数间接使用，
# 因此不需要各自再写一遍 case——同一处判断写两遍才是分叉的来源。
# tests/test-static.sh 据此检查：本模块中凡是直接提到某个内核的函数，
# 都必须同时给出两个内核的分支。

# 内核名无法识别时的统一出口。载入管理配置时已经拒绝过未知内核名，
# 这里是防止将来有人绕开那条路径后静默走错分支。
kernel_unknown() {
  printf '内部错误：代理内核名无法识别：%s\n' "${PROXY_KERNEL:-未设置}" >&2
  return 1
}

# 某个内核尚未实现的操作。刻意报错而不是回落到另一个内核的实现：
# 回落会让一台 mihomo 机器按 sing-box 的结构改写配置，产生的是坏数据而不是错误。
kernel_unsupported() {
  printf '当前部署使用的代理内核（%s）尚不支持该操作：%s\n' "${PROXY_KERNEL:-未设置}" "$1" >&2
  return 1
}

# 当前部署的内核可执行文件、配置文件、服务名与工作目录。
# 工作目录是 mihomo 特有的概念：它把 cache.db 一类运行期文件写在这里，
# 并且默认拒绝加载工作目录之外的证书（公开 Issue #154）。sing-box 没有对应物。
kernel_binary_path() {
  case "$PROXY_KERNEL" in
    singbox) printf '%s' "$SINGBOX_BIN" ;;
    mihomo) printf '%s' "$MIHOMO_BIN" ;;
    *) kernel_unknown ;;
  esac
}

kernel_config_path() {
  case "$PROXY_KERNEL" in
    singbox) printf '%s' "$SINGBOX_CONFIG" ;;
    mihomo) printf '%s' "$MIHOMO_CONFIG" ;;
    *) kernel_unknown ;;
  esac
}

kernel_service_name() {
  case "$PROXY_KERNEL" in
    singbox) printf '%s' "$SINGBOX_SERVICE" ;;
    mihomo) printf '%s' "$MIHOMO_SERVICE" ;;
    *) kernel_unknown ;;
  esac
}

kernel_work_dir() {
  case "$PROXY_KERNEL" in
    singbox) printf '%s' /var/lib/sing-box ;;
    mihomo) printf '%s' "$MIHOMO_WORK_DIR" ;;
    *) kernel_unknown ;;
  esac
}

# 给使用者看的内核名称。界面上不出现 singbox / mihomo 这种内部标识。
kernel_display_name() {
  case "$PROXY_KERNEL" in
    singbox) printf 'sing-box' ;;
    mihomo) printf 'mihomo' ;;
    *) kernel_unknown ;;
  esac
}

# 内核在 `ss -p` 一类输出里出现的进程名。刻意与展示名分成两个函数：
# 两者当前取值相同纯属巧合，而「SSH 连接是不是走本机节点」这条护栏
# 依赖的是进程名的精确匹配，不能跟着展示措辞一起改。
kernel_process_name() {
  case "$PROXY_KERNEL" in
    singbox) printf 'sing-box' ;;
    mihomo) printf 'mihomo' ;;
    *) kernel_unknown ;;
  esac
}

# 按标准绝对路径读取既有安装的规范化配置。与 kernel_check_default_install 同理，
# 调用发生在接管流程中，那时运行时配置尚未加载。
kernel_normalized_default_install() {
  case "$PROXY_KERNEL" in
    singbox) /usr/local/bin/sing-box format -c /etc/sing-box/config.json || return 1 ;;
    mihomo) kernel_unsupported '读取既有安装的规范化配置' ;;
    *) kernel_unknown ;;
  esac
}

# 当前部署的运行配置文件。托管内容读写都经这里取路径，不各自写一遍 case。
kernel_runtime_config_path() {
  case "$PROXY_KERNEL" in
    singbox) printf '%s' "$SINGBOX_CONFIG" ;;
    mihomo) printf '%s' "$MIHOMO_CONFIG" ;;
    *) kernel_unknown ;;
  esac
}

# 托管内容在运行配置里所处的容器与它的标识字段。
# sing-box 把用户入口放在 .inbounds[] 并用 .tag 标识，mihomo 放在 .listeners[]
# 并用 .name 标识。两者只是名字不同，语义一致，因此抽成取值函数而不是各写一套
# 过滤器——同一段 jq 逻辑写两遍，迟早只改一遍。
kernel_managed_container() {
  case "$PROXY_KERNEL" in
    singbox) printf 'inbounds' ;;
    mihomo) printf 'listeners' ;;
    *) kernel_unknown ;;
  esac
}

kernel_managed_key() {
  case "$PROXY_KERNEL" in
    singbox) printf 'tag' ;;
    mihomo) printf 'name' ;;
    *) kernel_unknown ;;
  esac
}

# 读取当前部署的内核配置，输出规范化后的 JSON 到标准输出。
# 调用方可以重定向到文件、用命令替换取值，或直接接管道，三种形态都适用。
#
# 两个内核的规范化来源不同，这是一处有代价的取舍：
# sing-box 的 `format` 同时做两件事——确认配置能被内核解析，以及给出**内核自己
# 视角**的规范化形式。mihomo 没有等价子命令，只能拆成两步：内核负责校验
# （kernel_check_config），jq 负责规范化。代价是规范化结果是我们的视角而不是
# 内核的视角。
#
# 因此 mihomo 这一支在 jq 读不了时**失败而不是将就**：那说明配置不是 JSON
# （例如有人手工改成了带锚点与注释的真 YAML），此时把它重写成 JSON 会毁掉
# 人家的东西。宁可拒绝改写，让使用者自己决定。
# 退路：将来 mihomo 若提供等价的规范化输出，换掉这一支即可，接口不变。
kernel_normalized_config() {
  case "$PROXY_KERNEL" in
    singbox) "$SINGBOX_BIN" format -c "$SINGBOX_CONFIG" ;;
    mihomo)
      jq . "$MIHOMO_CONFIG" 2>/dev/null || {
        printf '错误：mihomo 运行配置不是 JSON，管理器不会改写它：%s\n' "$MIHOMO_CONFIG" >&2
        return 1
      }
      ;;
    *) kernel_unknown ;;
  esac
}

# 用当前安装的内核校验指定的配置文件。
# 不内建输出重定向：各调用点对错误输出的处理不同（向用户显示、静默、捕获），
# 由调用点自行决定。
kernel_check_config() {
  kernel_check_config_with "$(kernel_binary_path)" "$1" || return 1
}

# 用指定的内核可执行文件校验配置文件。
# 切换正式版与测试版通道、以及接管既有安装时，需要用非当前的二进制校验。
# 两个内核的写法不同：sing-box 是 `check -c 文件`，mihomo 是 `-t -d 工作目录 -f 文件`。
# mihomo 必须带 -d：不带时它会按自己的默认目录找配置并在那里落下运行期文件。
# 还必须带 SAFE_PATHS，且与 systemd 单元里的那一份同源：`mihomo -t` 会当场
# 拒绝允许范围之外的规则文件路径，环境不一致时校验结果就不代表服务的行为。
kernel_check_config_with() {
  case "$PROXY_KERNEL" in
    singbox) "$1" check -c "$2" || return 1 ;;
    mihomo) SAFE_PATHS="$(mihomo_safe_paths)" "$1" -t -d "$MIHOMO_WORK_DIR" -f "$2" || return 1 ;;
    *) kernel_unknown ;;
  esac
}

# 按标准绝对路径校验既有安装的配置。
# 这里刻意不使用运行时配置里的路径：调用发生在环境探测与部署流程中，
# 那时运行时配置可能尚未加载，而且这里要确认的正是标准位置上的部署是否可用。
kernel_check_default_install() {
  case "$PROXY_KERNEL" in
    singbox) /usr/local/bin/sing-box check -c /etc/sing-box/config.json || return 1 ;;
    mihomo) SAFE_PATHS="$(mihomo_safe_paths)" /usr/local/bin/mihomo -t -d /var/lib/mihomo -f /etc/mihomo/config.json || return 1 ;;
    *) kernel_unknown ;;
  esac
}

# 内核配置骨架的唯一定义。语义是「幂等补齐，不覆盖已有值」：
# 对空对象应用它得到全新安装的初始配置，对既有配置应用它只补上缺的部分。
# 全新安装、接管既有安装、一致性审计三处共用这一份，避免各写一套之后悄悄分叉——
# v4.25.11 所修的缺陷正是同一份判断被写成两处而产生的。
# 骨架属于内核特有的 schema 知识，因此放在适配层，每个内核各一份。
SINGBOX_SKELETON_ENSURE_PROGRAM='
  if type != "object" then error("运行配置不是 JSON 对象") else . end
  | .log = (.log // {level:"info",timestamp:true})
  | .dns = (.dns // {})
  | .dns.servers = (.dns.servers // [])
  | (if any(.dns.servers[]?; .tag == "local") then . else .dns.servers += [{type:"local",tag:"local"}] end)
  | .dns.final = (.dns.final // "local")
  | .inbounds = (.inbounds // [])
  | .outbounds = (.outbounds // [])
  | (if any(.outbounds[]?; .tag == "direct") then . else .outbounds += [{type:"direct",tag:"direct"}] end)
  | .route = (.route // {})
  | .route.rules = (.route.rules // [])
  | .route.rule_set = (.route.rule_set // [])
  | .route.final = (.route.final // "direct")
  | .route.default_domain_resolver = (.route.default_domain_resolver // "local")
  | .experimental = (.experimental // {})
  | .experimental.cache_file = (.experimental.cache_file // {})
  | .experimental.cache_file.enabled = (.experimental.cache_file.enabled // true)'

# mihomo 的骨架。这里刻意**不写**用来重申默认值的配置项。
# mihomo 对未知键完全静默（公开 Issue #154），写一个拼错的 external-controller
# 只会带来虚假的安全感；真正起保护作用的是「服务起来之后名下监听套接字数为 0」
# 这条可观测断言，它一条就同时证明了控制接口与所有通用入口都没有打开。
# 实测：以 {"listeners":[]} 启动的 mihomo 不监听任何端口，也不下载任何 geo 数据库。
# proxies / proxy-groups / rules 是分流要用的容器（第二步 2d），现在先以空数组占位，
# 使骨架在后续分片中保持稳定，不必每加一片就改一次定义。
MIHOMO_SKELETON_ENSURE_PROGRAM='
  if type != "object" then error("运行配置不是 JSON 对象") else . end
  | .["log-level"] = (.["log-level"] // "info")
  | .mode = (.mode // "rule")
  | .listeners = (.listeners // [])
  | .proxies = (.proxies // [])
  | .["proxy-groups"] = (.["proxy-groups"] // [])
  | .rules = (.rules // [])'

# ============================================================
# 用户入口的生成：一个用户在当前内核下的托管条目
# ============================================================
# 返回 JSON 数组。**条目数量本来就随内核不同**，调用点不得假设：
# sing-box 的 SS2022 + ShadowTLS 需要三个入站（ShadowTLS 独立入站、detour 指向的
# shadowsocks、以及单独承载 UDP 的那个），mihomo 一个监听器就同时承载 TCP 与 UDP。
# 后者是实测结论：一个 shadowsocks 监听器默认就开 tcp 与 udp，加上 shadow-tls
# 之后仍然如此；显式写 "udp": false 时 UDP 套接字消失（公开 Issue #180）。
#
# 名字沿用 sing-box 那套前缀（st- / ss- / ss-direct- / anytls-），两个内核共用，
# 因此按前缀识别与删除托管内容的逻辑不必分内核各写一遍。
#
# 涉密内容一律经环境变量传给 jq，不进命令行参数。

kernel_entries_ss2022_shadowtls() {
  local name="$1" port="$2" st_password="$3" ss_password="$4" method="$5" shadowtls_sni="$6"
  case "$PROXY_KERNEL" in
    singbox)
      SB_JQ_ST_PASSWORD="$st_password" SB_JQ_SS_PASSWORD="$ss_password" jq -n \
        --arg name "$name" --argjson port "$port" --arg method "$method" \
        --arg hs_server "$shadowtls_sni" --argjson hs_port "$HANDSHAKE_PORT" \
        --argjson strict "$SHADOWTLS_STRICT_MODE" \
        '[{"type":"shadowtls","tag":("st-" + $name),"listen":"::","listen_port":$port,"version":3,
           "users":[{"name":$name,"password":$ENV.SB_JQ_ST_PASSWORD}],
           "handshake":{"server":$hs_server,"server_port":$hs_port},
           "strict_mode":$strict,"detour":("ss-" + $name)},
          {"type":"shadowsocks","tag":("ss-" + $name),"network":"tcp","method":$method,
           "password":$ENV.SB_JQ_SS_PASSWORD},
          {"type":"shadowsocks","tag":("ss-udp-" + $name),"listen":"::","listen_port":$port,
           "network":"udp","method":$method,"password":$ENV.SB_JQ_SS_PASSWORD}]'
      ;;
    mihomo)
      # 严格模式的键名是 strict-mode，不是 strictmode——监听器配置走的是
      # inbound 结构体标签而不是 yaml 标签，二进制里 strictmode 出现 0 次。
      # 公开 Issue #154 正文那条相反的推导已在该 Issue 中更正。
      # 这个取值的行为差异已经真机观测到（公开 Issue #182）：握手目标不说 TLS 1.3
      # 时，严格模式开着的监听器拒绝承载代理、退化成把连接原样转给握手目标
      # （日志 [ShadowTLS] TLS 1.3 is not supported, will copy bidirectional），
      # 关着时照常代理；握手目标说 TLS 1.3 时两种取值都照常代理。因此写对这个键
      # 不只是「配置能加载」。反过来也成立：握手目标哪天不再支持 TLS 1.3，严格
      # 模式下这些入口会整体不通，而配置校验与启动日志都不会提前提示。
      # udp 显式写出而不是依赖默认值：这里不是「重申默认值的虚假安全感」，
      # 因为它有可观测断言把守——监听套接字里 UDP 在不在是能直接看到的。
      SB_JQ_ST_PASSWORD="$st_password" SB_JQ_SS_PASSWORD="$ss_password" jq -n \
        --arg name "$name" --argjson port "$port" --arg method "$method" \
        --arg hs_dest "${shadowtls_sni}:${HANDSHAKE_PORT}" \
        --argjson strict "$SHADOWTLS_STRICT_MODE" \
        '[{"name":("st-" + $name),"type":"shadowsocks","listen":"::","port":$port,
           "cipher":$method,"password":$ENV.SB_JQ_SS_PASSWORD,"udp":true,
           "shadow-tls":{"enable":true,"version":3,
                         "users":[{"name":$name,"password":$ENV.SB_JQ_ST_PASSWORD}],
                         "handshake":{"dest":$hs_dest},
                         "strict-mode":$strict}}]'
      ;;
    *) kernel_unknown ;;
  esac
}

# ============================================================
# ShadowTLS 握手目标的 TLS 1.3 预检
# ============================================================
# 严格模式的行为是实测出来的（公开 Issue #182）：握手目标不支持 TLS 1.3 时，开着
# 严格模式的监听器拒绝承载代理，退化成把连接原样转给握手目标。反过来读就是这条
# 预检存在的理由——握手目标哪天不再支持 TLS 1.3，这台机器上所有 ShadowTLS 入口
# 会整体不通，而配置校验、启动日志与既有审计都不会提前提示，现象只是「连不上」
# （公开 Issue #194）。
#
# 结果分四类，因为处置不同：
#   tls13        握手目标支持 TLS 1.3
#   tls-older    说 TLS，但握不出 1.3 —— 明确是问题
#   not-tls      TCP 通，但那个端口上根本不是 TLS —— 明确是问题
#   unreachable  连 TCP 都连不上，或者本机没有 timeout 命令不敢做兜底判断
#   invalid      域名或端口本身不合法
# 把 unreachable 单独分出来是刻意的：网络抖动一次就拒绝改配置、或者把检查刷红，
# 是标准的「狼来了」，而它会自愈。
#
# 判定看协商出来的版本而不是 openssl 的退出码：s_client 在证书验证失败时也会以
# 非零退出，而「这个域名说不说 TLS 1.3」与证书是否可信无关。openssl 默认就会尽量
# 协商最高版本，因此一次握手足以回答这个问题。
probe_handshake_tls13() {
  local host="$1" port="$2" output="" version
  # 调用点传进来的都是校验过的域名与端口。这里再挡一次：下面 /dev/tcp 的重定向词
  # 会经历参数展开，不该把没校验过的东西放进去。
  [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$port" =~ ^[0-9]+$ ]] || {
    printf 'invalid\n'
    return 0
  }
  if command -v timeout >/dev/null 2>&1; then
    output="$(timeout 10 openssl s_client -connect "$host:$port" -servername "$host" -brief </dev/null 2>&1)" || true
  else
    output="$(openssl s_client -connect "$host:$port" -servername "$host" -brief </dev/null 2>&1)" || true
  fi
  version="$(sed -n 's/^Protocol version: //p' <<<"$output" | head -n1)"
  case "$version" in
    TLSv1.3) printf 'tls13\n'; return 0;;
    TLS*) printf 'tls-older\n'; return 0;;
  esac
  # 握不出 TLS 时还要分清「那个端口上不是 TLS」与「根本连不上」。没有 timeout
  # 命令就不做这一步：/dev/tcp 没有自带超时，宁可报成只提示的 unreachable，
  # 也不冒把菜单挂住的风险。
  if command -v timeout >/dev/null 2>&1 && timeout 5 bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$host" "$port" 2>/dev/null; then
    printf 'not-tls\n'
  else
    printf 'unreachable\n'
  fi
}

# 这条预检只对 mihomo 做。sing-box 的 strict_mode 行为本项目没有实测过，而项目
# 方向是逐步放弃 sing-box（公开 Issue #172），不再为它新加护栏——它那一侧保持
# 一字不变。另外两个条件同样是必要的：严格模式关着时握手目标不支持 TLS 1.3
# 并不会让入口不通（公开 Issue #182 的对照格证明了这一点），而一台没有旧版
# ShadowTLS 用户的机器上这条检查恒真，报了也没有人要处理。
shadowtls_handshake_probe_applies() {
  local total
  case "$PROXY_KERNEL" in
    mihomo) ;;
    singbox) return 1;;
    *) kernel_unknown;;
  esac
  [[ "${SHADOWTLS_STRICT_MODE:-true}" == true ]] || return 1
  total="$(count_protocol_sni_users ss2022)" || return 1
  [[ "$total" =~ ^[0-9]+$ ]] || return 1
  ((total > 0))
}

kernel_entries_ss2022_direct() {
  local name="$1" port="$2" ss_password="$3" method="$4" entry_name="${5:-ss-$1}"
  case "$PROXY_KERNEL" in
    singbox)
      SB_JQ_SS_PASSWORD="$ss_password" jq -n \
        --arg tag "$entry_name" --argjson port "$port" --arg method "$method" \
        '[{"type":"shadowsocks","tag":$tag,"listen":"::","listen_port":$port,
           "method":$method,"password":$ENV.SB_JQ_SS_PASSWORD}]'
      ;;
    mihomo)
      SB_JQ_SS_PASSWORD="$ss_password" jq -n \
        --arg name "$entry_name" --argjson port "$port" --arg method "$method" \
        '[{"name":$name,"type":"shadowsocks","listen":"::","port":$port,
           "cipher":$method,"password":$ENV.SB_JQ_SS_PASSWORD,"udp":true}]'
      ;;
    *) kernel_unknown ;;
  esac
}

kernel_entries_anytls() {
  local name="$1" port="$2" password="$3"
  case "$PROXY_KERNEL" in
    singbox)
      SB_JQ_PASSWORD="$password" jq -n \
        --arg name "$name" --argjson port "$port" \
        --arg cert_path "$ANYTLS_CERT_FILE" --arg key_path "$ANYTLS_KEY_FILE" \
        '[{"type":"anytls","tag":("anytls-" + $name),"listen":"::","listen_port":$port,
           "users":[{"name":$name,"password":$ENV.SB_JQ_PASSWORD}],
           "tls":{"enabled":true,"certificate_path":$cert_path,"key_path":$key_path}}]'
      ;;
    mihomo)
      # mihomo 的 users 是映射（用户名 → 密码），不是数组；证书字段名也不同。
      # 证书必须落在 systemd 单元 SAFE_PATHS 之内，否则监听器起不来，
      # 而 mihomo -t 完全测不出这个问题（公开 Issue #154）。
      SB_JQ_PASSWORD="$password" jq -n \
        --arg name "$name" --argjson port "$port" \
        --arg cert_path "$ANYTLS_CERT_FILE" --arg key_path "$ANYTLS_KEY_FILE" \
        '[{"name":("anytls-" + $name),"type":"anytls","listen":"::","port":$port,
           "users":{($name):$ENV.SB_JQ_PASSWORD},
           "certificate":$cert_path,"private-key":$key_path}]'
      ;;
    *) kernel_unknown ;;
  esac
}

# ============================================================
# 分流的生成：上游出口、规则集与路由在当前内核下的形状
# ============================================================
# 与用户入口那一组同理，**条目数量随内核不同**，调用点不得假设：
# sing-box 的 SS2022 + ShadowTLS 上游需要两个出站（shadowsocks 出站
# 加一个 detour 指向的 shadowtls 传输），mihomo 一个 proxy 就够——
# ShadowTLS 在 mihomo 客户端一侧是 shadowsocks 的插件而不是独立对象。
#
# 涉密内容一律经环境变量传给 jq，不进命令行参数。

kernel_split_outbounds() {
  local name="$1" upstream="$2" out_tag="$3" transport_tag="$4" protocol
  protocol="$(jq -r '.protocol' <<<"$upstream")" || return 1
  case "$PROXY_KERNEL" in
    singbox)
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
      ;;
    mihomo)
      # 字段名取自二进制里的 proxy 结构体标签，不猜也不只信文档；
      # 插件参数走另一套 obfs 标签（公开 Issue #186）。每个布尔与数值字段
      # 都用「塞非法值必须被拒绝、键名写错反而通过」这一对断言确认过。
      #
      # udp 按上游真实承载能力写，不一律写 true：ShadowTLS 只承载 TCP，
      # sing-box 侧那条 detour 到 shadowtls 的出站同样带不了 UDP。
      # 写成 true 等于给出一个上游根本不提供的承诺。
      case "$protocol" in
        anytls)
          SB_JQ_UPSTREAM="$upstream" jq -cn --arg name "$out_tag" '($ENV.SB_JQ_UPSTREAM | fromjson) as $u | [{name:$name,type:"anytls",server:$u.server,port:$u.server_port,password:$u.password,sni:$u.sni,"skip-cert-verify":$u.insecure,udp:true}]'
          ;;
        shadowsocks)
          SB_JQ_UPSTREAM="$upstream" jq -cn --arg name "$out_tag" '($ENV.SB_JQ_UPSTREAM | fromjson) as $u | [{name:$name,type:"ss",server:$u.server,port:$u.server_port,cipher:$u.method,password:$u.password,udp:true}]'
          ;;
        ss_shadowtls)
          SB_JQ_UPSTREAM="$upstream" jq -cn --arg name "$out_tag" '($ENV.SB_JQ_UPSTREAM | fromjson) as $u | [{name:$name,type:"ss",server:$u.server,port:$u.server_port,cipher:$u.method,password:$u.ss_password,udp:false,
            plugin:"shadow-tls","plugin-opts":{host:$u.sni,password:$u.shadowtls_password,version:3,"skip-cert-verify":$u.insecure}}]'
          ;;
        *) die "不支持的上游协议：$protocol";;
      esac
      ;;
    *) kernel_unknown ;;
  esac
}

# 上游出口在运行配置里所处的容器。sing-box 放在 .outbounds[] 并用 .tag 标识，
# mihomo 放在 .proxies[] 并用 .name 标识。标识字段与用户入口那一组同一个键名，
# 因此直接复用 kernel_managed_key，不再单列一个函数。
kernel_split_outbound_container() {
  case "$PROXY_KERNEL" in
    singbox) printf 'outbounds' ;;
    mihomo) printf 'proxies' ;;
    *) kernel_unknown ;;
  esac
}

# 规则集来源在状态里的字段名。
# sing-box 存远程下载地址（url），mihomo 存使用者自己那个本地块状 yaml 文件的
# 路径（rule_file）。两个内核的规则集格式不通用，同一个字段装两种东西
# 会让「这是地址还是路径」变成读代码时才知道的事。
# 读取一律写成 (.url // .rule_file // "")：两个键在同一台机器上不会同时存在。
kernel_rule_source_key() {
  case "$PROXY_KERNEL" in
    singbox) printf 'url' ;;
    mihomo) printf 'rule_file' ;;
    *) kernel_unknown ;;
  esac
}

# 一条规则集在当前内核下的运行配置条目。
# sing-box 放在 route.rule_set[] 里，是带 tag 的数组元素；
# mihomo 放在 rule-providers{} 里，是以名字为键的对象成员。
# 因此这里统一返回 {tag: ..., entry: {...}}，由各自的渲染函数决定怎么摆。
kernel_split_rule_set_entry() {
  local tag="$1" source="$2" behavior="$3" format
  case "$PROXY_KERNEL" in
    singbox)
      format="$(split_rule_format "$source")" || return 1
      jq -cn --arg tag "$tag" --arg format "$format" --arg url "$source" \
        '{tag:$tag,entry:{type:"remote",tag:$tag,format:$format,url:$url,download_detour:"direct",update_interval:"24h"}}'
      ;;
    mihomo)
      # format 固定 yaml：使用者贴的是社区的块状 yaml 片段。
      # behavior 必须与文件内容相符，而 mihomo 在这一点上是**静默**的——
      # 把完整规则行按域名列表读，一条警告都没有，规则就是不生效（公开 Issue #186）。
      # 因此 behavior 由使用者明确选择，并由管理器读文件核对，不靠内核报错。
      # 写绝对路径。状态里存的是文件名，而 mihomo 会把相对路径按**工作目录**
      # 解析，那是 /var/lib/mihomo，不是规则目录——写相对路径会指到一个
      # 根本不存在的文件上，而且服务照样起得来，只在日志里留一行 error。
      jq -cn --arg tag "$tag" --arg path "$(mihomo_rule_file_path "$source")" --arg behavior "$behavior" \
        '{tag:$tag,entry:{type:"file",behavior:$behavior,format:"yaml",path:$path}}'
      ;;
    *) kernel_unknown ;;
  esac
}

# 一个 SS2022 + ShadowTLS 用户在当前内核下会产生哪几个托管条目名。
# 用户专属分流要按入口名限定，而这一项两个内核条目数不同：
# sing-box 三个（ShadowTLS 入站、detour 的 shadowsocks、单独承载 UDP 的那个），
# mihomo 一个监听器同时承载 TCP 与 UDP。
# 返回前缀数组，调用点拼上用户名——名字本身两个内核共用。
kernel_shadowtls_entry_prefixes() {
  case "$PROXY_KERNEL" in
    singbox) printf '["st-","ss-","ss-udp-"]' ;;
    mihomo) printf '["st-"]' ;;
    *) kernel_unknown ;;
  esac
}

# 托管分流在 mihomo 的 rules 里所用的 sub-rule 名。
# 管理器在 rules 顶层只留一条派发，其余整块关在这个 sub-rule 里，
# 使用者手工加在 rules 里的东西因此原样保留（公开 Issue #186）。
# 名字与分流规则集标签的前缀 managed-split- 差一个连字符，不可能相撞：
# 分流名至少一个字符，managed-split-<名字> 永远带那个连字符。
MIHOMO_MANAGED_SUB_RULE="managed-splits"

# 一个用户端点的托管条目除了「在不在」之外还要对哪些字段。
#
# 「在不在」两个内核完全一样，由审计里共用的那段程序负责；这里只写形状特有的
# 那一部分，两个内核各一份，与用户入口的生成放在同一个模块里——生成改了形状，
# 审计的断言就得跟着改，隔着模块放迟早只改一处。
#
# 两段都只用到审计程序里先定义好的 issue()，以及 $config 和 $strict_mode 这两个变量。
SINGBOX_USER_ENTRY_SHAPE_DEF='
  def sbm_entry_shape_issues($name; $protocol; $transport; $port; $status; $has_legacy; $expected):
    (if $protocol == "ss2022" and $transport == "shadowtls" and $status == "active" and
        any($config.inbounds[]?; .tag == ("ss-udp-" + $name)) and
        (any($config.inbounds[]?;
          .tag == ("ss-udp-" + $name) and .type == "shadowsocks" and .network == "udp" and .listen_port == $port) | not)
     then issue(true; "[可自动修复] 用户 \($name) 的 UDP 连接配置不正确") else empty end),
    (if $protocol == "ss2022" and $transport == "direct" and $status == "active" and
        (any($config.inbounds[]?;
          .tag == $expected and .type == "shadowsocks" and .listen_port == $port and ((.network // "") == "")) | not)
     then issue(true; "[可自动修复] 用户 \($name) 的原生 SS2022 连接配置不正确") else empty end),
    (if $protocol == "ss2022" and $transport == "direct" and ($has_legacy | not) and
        any($config.inbounds[]?; .tag == ("st-" + $name) or .tag == ("ss-udp-" + $name))
     then issue(true; "[可自动修复] 用户 \($name) 的原生 SS2022 仍有旧版 ShadowTLS 连接残留") else empty end);'

# mihomo 侧的对应物。差别来自 2c 定下的形状：
# 一个监听器同时承载 TCP 与 UDP（因此没有单独的 UDP 条目，改看 udp 字段），
# ShadowTLS 是挂在 shadowsocks 监听器上的子结构而不是独立入站。
#
# strict-mode 这一条 sing-box 侧今天没有对应检查（它的 strict_mode 同样没查）。
# mihomo 侧加它的理由是这个键**恰恰是 mihomo 会静默丢弃的那一类**——键名写错
# 不报错、严格模式悄悄关掉（公开 Issue #154 的更正评论）。运行配置里它是不是
# 管理配置里那个值，是审计能便宜地回答的问题。
MIHOMO_USER_ENTRY_SHAPE_DEF='
  def sbm_entry_shape_issues($name; $protocol; $transport; $port; $status; $has_legacy; $expected):
    (first($config.listeners[]? | select(.name == ("st-" + $name))) // null) as $shadowtls |
    (if $protocol == "ss2022" and $transport == "shadowtls" and $status == "active" and
        ($shadowtls != null) and
        (($shadowtls | .type == "shadowsocks" and .port == $port and .udp == true and
          ((.["shadow-tls"].enable // false) == true) and
          ((.["shadow-tls"].version // 0) == 3)) | not)
     then issue(true; "[可自动修复] 用户 \($name) 的 SS2022 + ShadowTLS 连接配置不正确") else empty end),
    (if $protocol == "ss2022" and $transport == "shadowtls" and $status == "active" and
        ($shadowtls != null) and
        (($shadowtls | .["shadow-tls"]["strict-mode"]) != $strict_mode)
     then issue(true; "[可自动修复] 用户 \($name) 的 ShadowTLS 严格模式与管理配置不一致") else empty end),
    (if $protocol == "ss2022" and $transport == "direct" and $status == "active" and
        (any($config.listeners[]?;
          .name == $expected and .type == "shadowsocks" and .port == $port and .udp == true and
          (has("shadow-tls") | not)) | not)
     then issue(true; "[可自动修复] 用户 \($name) 的原生 SS2022 连接配置不正确") else empty end),
    (if $protocol == "ss2022" and $transport == "direct" and ($has_legacy | not) and
        ($shadowtls != null)
     then issue(true; "[可自动修复] 用户 \($name) 的原生 SS2022 仍有旧版 ShadowTLS 连接残留") else empty end);'

kernel_user_entry_shape_def() {
  case "$PROXY_KERNEL" in
    singbox) printf '%s' "$SINGBOX_USER_ENTRY_SHAPE_DEF" ;;
    mihomo) printf '%s' "$MIHOMO_USER_ENTRY_SHAPE_DEF" ;;
    *) kernel_unknown ;;
  esac
}

# 拿运行配置与「我们写进去的样子」做比对之前，要先做的规范化。
#
# sing-box 的 Listable 字段只有一个元素时，会被 `format` 规范化成裸标量：
#   写入的 "inbound":["anytls-share"]  →  读回的 "inbound":"anytls-share"
# 直接拿它和期望的标签数组做集合运算，jq 会因类型不符而报错
# （array and string cannot be subtracted）。而这些比对的调用点写成
# `if ! jq ...` 或 `jq ... || return 1`，jq 崩溃会被当成「配置不符」，
# 于是既误报「分流尚未覆盖用户的全部连接」，又会触发一次不必要的配置重建与
# sing-box 重启。字符串上的 `.inbound[]?` 还会安静地什么都不返回，让
# 「已停用用户的规则仍在生效」这类检查静默失效（v4.25.11 修的正是这个）。
#
# **mihomo 侧不存在这件事**：这一支的规范化本身就是 `jq .`，写进去什么形状
# 读回来就是什么形状，这条管线里没有会改写形状的环节。因此它只做类型校验。
# 照搬 sing-box 那一段过去没有意义——mihomo 的配置里根本没有 route.rules。
#
# 整段放在单引号常量里，调用处只做一次普通变量展开：内联拼接会产生转义双引号，
# 而 tests/check-shell-call-targets.py 的分词器遇到那种写法会静默停止检查
# 文件剩余部分（见公开 Issue #102）。
SINGBOX_CONFIG_NORMALISE_PROGRAM='
  if type != "object" then error("运行配置不是 JSON 对象") else . end
  | if (.route.rules? | type) == "array" then
      .route.rules |= map(
        if has("inbound") and ((.inbound | type) != "array") then .inbound = [.inbound] else . end)
    else . end'

MIHOMO_CONFIG_NORMALISE_PROGRAM='
  if type != "object" then error("运行配置不是 JSON 对象") else . end'

kernel_config_normalise_program() {
  case "$PROXY_KERNEL" in
    singbox) printf '%s' "$SINGBOX_CONFIG_NORMALISE_PROGRAM" ;;
    mihomo) printf '%s' "$MIHOMO_CONFIG_NORMALISE_PROGRAM" ;;
    *) kernel_unknown ;;
  esac
}

# 骨架反推出的缺项里，期望值为空容器的那些要不要报。
#
# sing-box 的 `format` **会把空数组整个省略**，读回来分不清「没有这个键」和
# 「这个键是空数组」，而对内核而言两者语义相同——不排除就会在没有分流的
# 服务器上把 route.rules 与 route.rule_set 误报成缺项（v4.25.13 修的正是这个）。
#
# **mihomo 侧必须报。** 它的规范化是 `jq .`，空数组原样在，读回来分得清；
# 照搬那条排除的后果是：一台丢了 listeners、proxies 或 rules 的 mihomo 机器，
# 「服务与配置检查」会说一切正常。这一条有实测与对照（公开 Issue #189）。
kernel_skeleton_skips_empty_containers() {
  case "$PROXY_KERNEL" in
    singbox) return 0 ;;
    mihomo) return 1 ;;
    *) kernel_unknown ;;
  esac
}

# 判断托管 sub-rule 里的一行是什么。行的形状只有两种，都由
# kernel_render_split_plan 生成：
#   RULE-SET,<规则集>,<出口>
#   AND,((RULE-SET,<规则集>),(IN-NAME,...)),<出口>
# 生成与识别必须一起改，因此这几段判断与渲染函数放在同一个模块里，
# 由分流模块与审计以变量展开的方式注入自己的 jq 程序。
# tests/test-static.sh 据此禁止其它模块自己拼这套规则语法。
#
# 四个判断各自回答一个问题：这一行属不属于某条规则集（删除时用）、
# 是不是「某规则集 → 某出口」（审计「配置完不完整」用）、是不是不限入口的
# 那一种（审计已停用的全局分流用）、有没有覆盖到某几个入口名（审计
# 「有没有覆盖用户的全部连接」与「已停用用户是否仍在生效」用）。
MIHOMO_SPLIT_RULE_DEFS='
  def sbm_line_owned_by($line; $tags):
    ($line | type) == "string" and
    any($tags[]; . as $tag |
      ($line | startswith("RULE-SET," + $tag + ",")) or
      ($line | contains("(RULE-SET," + $tag + ")")));
  def sbm_line_routes($line; $rule; $out):
    sbm_line_owned_by($line; [$rule]) and ($line | endswith("," + $out));
  def sbm_line_scope_all($line; $rule; $out):
    ($line | type) == "string" and $line == ("RULE-SET," + $rule + "," + $out);
  def sbm_line_covers($line; $names):
    ($line | type) == "string" and
    all($names[]; . as $entry | $line | contains("(IN-NAME," + $entry + ")"));
  def sbm_line_touches($line; $rule; $names):
    sbm_line_owned_by($line; [$rule]) and
    any($names[]; . as $entry | $line | contains("(IN-NAME," + $entry + ")"));'

# 派发条目。条件写成覆盖整个端口空间的 DST-PORT，语义是「所有连接」：
# MATCH 不能当逻辑规则的条件（mihomo 明确拒绝 SUB-RULE,(MATCH),名字），
# 而按托管监听器的 IN-NAME 派发会让语义与 sing-box 不一致——sing-box 的
# 「全部用户」分流本来就不限定入站，使用者手工加的入站也一样受它管。
# 已实测这条派发确实触发（sub-rule 内 REJECT 时连接被拦下），
# 并有反面对照（条件换成不存在的 IN-NAME 时连接正常放行）。
MIHOMO_SPLIT_DISPATCH_RULE="SUB-RULE,(DST-PORT,0-65535),${MIHOMO_MANAGED_SUB_RULE}"

# 把与内核无关的分流计划渲染成当前内核的运行配置片段。
#
# 计划本身（哪条规则集配哪个出口、限定哪些入口）两个内核完全一样，
# 差别只在最终长什么样：sing-box 的路由规则是对象数组，mihomo 是字符串数组，
# 规则集容器一个是带 tag 的数组、另一个是以名字为键的对象。
# 因此计划的构造留在分流模块里只写一遍，形状差异集中在这里。
#
# 输入：{outbound_groups:[{tag,objects}],rule_sets:[{tag,entry}],
#        routes:[{rule_set,outbound,scope_all,users,inbound}]}
# 输出（sing-box）：{outbounds:[...],rule_sets:[...],rules:[...]}
# 输出（mihomo）：  {proxies:[...],rule_providers:{...},sub_rules:[...]}
kernel_render_split_plan() {
  local plan="$1"
  case "$PROXY_KERNEL" in
    singbox)
      jq -c '{
        outbounds:[.outbound_groups[].objects[]],
        rule_sets:[.rule_sets[].entry],
        rules:[.routes[] | ({rule_set:.rule_set,action:"route",outbound:.outbound} +
          (if .scope_all then {} else {inbound:.inbound} end))]
      }' <<<"$plan"
      ;;
    mihomo)
      # mihomo 的路由规则是字符串，名字直接拼进去。因此这里先挡一道：
      # 名字里出现逗号或括号会把一条规则拼成另一条，而 mihomo 只会说
      # 「规则类型不支持」，看不出是名字带进去的。当前的名字格式不可能出现
      # 这些字符，这条断言是为了将来改名字格式时当场变红而不是悄悄拼错。
      # 入口为空的用户专属条目直接丢掉：它谁都作用不到，
      # 而 OR,(()) 这种空集合写法 mihomo 不接受。
      jq -c '
        def guard($text): if ($text | test("[,()]")) then
            error("名字里不能出现逗号或括号，否则会拼坏 mihomo 规则：" + $text)
          else $text end;
        def in_name($names):
          if ($names | length) == 1 then "(IN-NAME," + guard($names[0]) + ")"
          else "(OR,(" + ([$names[] | "(IN-NAME," + guard(.) + ")"] | join(",")) + "))" end;
        {
          proxies:[.outbound_groups[].objects[]],
          rule_providers:([.rule_sets[] | {key:guard(.tag),value:.entry}] | from_entries),
          sub_rules:[.routes[] |
            if .scope_all then
              "RULE-SET," + guard(.rule_set) + "," + guard(.outbound)
            elif ((.inbound // []) | length) == 0 then empty
            else
              "AND,((RULE-SET," + guard(.rule_set) + ")," + in_name(.inbound) + ")," + guard(.outbound)
            end]
        }' <<<"$plan"
      ;;
    *) kernel_unknown ;;
  esac
}

kernel_skeleton_ensure_program() {
  case "$PROXY_KERNEL" in
    singbox) printf '%s' "$SINGBOX_SKELETON_ENSURE_PROGRAM" ;;
    mihomo) printf '%s' "$MIHOMO_SKELETON_ENSURE_PROGRAM" ;;
    *) kernel_unknown ;;
  esac
}

# 读取指定内核可执行文件的版本号。版本号的位置是内核特有的输出约定，
# 因此解析放在适配层；文件不可执行时返回空字符串而不是报错，
# 调用点据此显示「未安装」或「未保存」。
# 两个内核都把版本号放在第 1 行第 3 列，但子命令不同（sing-box 用 version，
# mihomo 用 -v），且 mihomo 带 v 前缀，这里去掉以便与 Release 标签去 v 后的写法比较。
# 顺带一层保护：微架构不匹配的 mihomo 二进制会拒绝运行并以退出码 1 结束，
# 版本输出为空，安装流程中的「解压后版本与预期一致」比对因此当场失败。
kernel_binary_version() {
  [[ -x "$1" ]] || return 0
  case "$PROXY_KERNEL" in
    singbox) "$1" version 2>/dev/null | awk 'NR==1 {print $3}' || true ;;
    mihomo) "$1" -v 2>/dev/null | awk 'NR==1 {sub(/^v/, "", $3); print $3}' || true ;;
    *) kernel_unknown ;;
  esac
}

# 内核服务控制。刻意拆成三个动作而不是合成一个重启流程：
# 两个调用点对失败的处理不同——恢复备份时要逐步记录严重错误，
# 用户操作时直接返回由上层回滚——合成一个会抹掉这个差别。
kernel_service_reset_failed() {
  local service
  service="$(kernel_service_name)" || return 1
  systemctl reset-failed "$service" 2>/dev/null || true
}

kernel_service_restart() {
  local service
  service="$(kernel_service_name)" || return 1
  systemctl restart "$service" || return 1
}

kernel_service_is_active() {
  local service
  service="$(kernel_service_name)" || return 1
  systemctl is-active --quiet "$service"
}

# 规则集编译与反编译。这两个子命令是 sing-box 特有的，mihomo 的规则集格式与
# .srs 不通用，需要另行决定来源（第二步 2d），因此这里明确报错而不是给出等价物。
kernel_rule_set_compile() {
  case "$PROXY_KERNEL" in
    singbox) "$1" rule-set compile --output "$3" "$2" >/dev/null || return 1 ;;
    mihomo) kernel_unsupported '编译规则集' ;;
    *) kernel_unknown ;;
  esac
}

kernel_rule_set_decompile() {
  case "$PROXY_KERNEL" in
    singbox) "$1" rule-set decompile --output "$3" "$2" >/dev/null || return 1 ;;
    mihomo) kernel_unsupported '反编译规则集' ;;
    *) kernel_unknown ;;
  esac
}

# 当前内核的核心文件：配置、可执行文件、systemd 单元。
# 环境分类与完整性判断用这一组——它们问的是「这台机器的内核装好了没有」，
# 因此必须只看当前内核：一台 mihomo 机器缺少 sing-box 不是损坏。
kernel_core_paths() {
  case "$PROXY_KERNEL" in
    singbox)
      cat <<'EOF'
/etc/sing-box/config.json
/usr/local/bin/sing-box
/etc/systemd/system/sing-box.service
EOF
      ;;
    mihomo)
      cat <<'EOF'
/etc/mihomo/config.json
/usr/local/bin/mihomo
/etc/systemd/system/mihomo.service
EOF
      ;;
    *) kernel_unknown ;;
  esac
}

# 两个内核的全部部署路径。备份、卸载与事务白名单用这一组——
# 它们问的是「哪些路径属于本项目」，与这台机器当前用哪个内核无关。
# 取并集而不是按内核分派：不存在的路径在这三处都被跳过，多列几条没有代价；
# 而按内核分派会让「这台机器上还留着另一个内核的残留」变成清不掉的东西。
all_kernel_deployment_paths() {
  cat <<'EOF'
/etc/sing-box
/var/lib/sing-box
/usr/local/bin/sing-box
/etc/systemd/system/sing-box.service
/etc/systemd/system/multi-user.target.wants/sing-box.service
/etc/mihomo
/var/lib/mihomo
/usr/local/bin/mihomo
/etc/systemd/system/mihomo.service
/etc/systemd/system/multi-user.target.wants/mihomo.service
EOF
}
