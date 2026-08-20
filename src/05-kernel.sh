# 内核适配层。所有对代理内核可执行文件的直接调用都集中在本模块，
# 其它模块只经由这里定义的函数与内核交互。
# 这样做的原因：上游内核会在小版本之间修改配置规范与命令行接口，
# 调用点散落在各模块时，每次跟进都要同时改多处；集中之后只改这里一处。

# 读取当前部署的内核配置，输出内核自身规范化后的 JSON 到标准输出。
# 调用方可以重定向到文件、用命令替换取值，或直接接管道，三种形态都适用。
# 失败时按内核的退出码返回，由调用方决定如何处理。
kernel_normalized_config() {
  "$SINGBOX_BIN" format -c "$SINGBOX_CONFIG"
}

# 用当前安装的内核校验指定的配置文件。
# 不内建输出重定向：各调用点对错误输出的处理不同（向用户显示、静默、捕获），
# 由调用点自行决定。
kernel_check_config() {
  kernel_check_config_with "$SINGBOX_BIN" "$1" || return 1
}

# 用指定的内核可执行文件校验配置文件。
# 切换正式版与测试版通道、以及接管既有安装时，需要用非当前的二进制校验。
kernel_check_config_with() {
  "$1" check -c "$2" || return 1
}

# 按标准绝对路径校验既有安装的配置。
# 这里刻意不使用运行时配置里的路径：调用发生在环境探测与部署流程中，
# 那时运行时配置可能尚未加载，而且这里要确认的正是标准位置上的部署是否可用。
kernel_check_default_install() {
  /usr/local/bin/sing-box check -c /etc/sing-box/config.json || return 1
}

# 内核配置骨架的唯一定义。语义是「幂等补齐，不覆盖已有值」：
# 对空对象应用它得到全新安装的初始配置，对既有配置应用它只补上缺的部分。
# 全新安装、接管既有安装、一致性审计三处共用这一份，避免各写一套之后悄悄分叉——
# v4.25.11 所修的缺陷正是同一份判断被写成两处而产生的。
# 骨架属于内核特有的 schema 知识，因此放在适配层：接入第二内核时这里要各写一份。
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
