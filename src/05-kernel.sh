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

# 读取当前部署的内核配置，输出内核自身规范化后的 JSON 到标准输出。
# 调用方可以重定向到文件、用命令替换取值，或直接接管道，三种形态都适用。
# 失败时按内核的退出码返回，由调用方决定如何处理。
# mihomo 没有对应的子命令，且它的调用点全部属于用户与分流的配置生成，
# 那些还没有 mihomo 实现，因此这里明确报错而不是给出一个半成品。
kernel_normalized_config() {
  case "$PROXY_KERNEL" in
    singbox) "$SINGBOX_BIN" format -c "$SINGBOX_CONFIG" ;;
    mihomo) kernel_unsupported '读取规范化后的运行配置' ;;
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
kernel_check_config_with() {
  case "$PROXY_KERNEL" in
    singbox) "$1" check -c "$2" || return 1 ;;
    mihomo) "$1" -t -d "$MIHOMO_WORK_DIR" -f "$2" || return 1 ;;
    *) kernel_unknown ;;
  esac
}

# 按标准绝对路径校验既有安装的配置。
# 这里刻意不使用运行时配置里的路径：调用发生在环境探测与部署流程中，
# 那时运行时配置可能尚未加载，而且这里要确认的正是标准位置上的部署是否可用。
kernel_check_default_install() {
  case "$PROXY_KERNEL" in
    singbox) /usr/local/bin/sing-box check -c /etc/sing-box/config.json || return 1 ;;
    mihomo) /usr/local/bin/mihomo -t -d /var/lib/mihomo -f /etc/mihomo/config.json || return 1 ;;
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
