# ADR 0011：落地启动恢复门禁与 systemd 顺序

- 状态：已接受，能力保持 dormant
- 日期：2026-08-07
- 关联：[ADR 0008](0008-restricted-landing-agent-and-rollback.md)、[ADR 0009](0009-restricted-landing-channel-installation.md)、[ADR 0010](0010-durable-landing-apply-transaction.md)、[Issue #210](https://github.com/DTB201/sb-user-manager/issues/210)

## 背景

ADR 0010 能在下一次 apply 请求到来时恢复断电或 `SIGKILL` 留下的持久事务，但机器重启后，原有 `sing-box.service` 仍可能先读取中间配置并开放端口。恢复因此必须成为 sing-box 的硬启动前置条件：恢复失败时，systemd 必须阻止 sing-box 启动并保留完整证据，而不是等待远程入口再次发包。

启动恢复不能直接复用在线 apply 的服务语义。冷启动时 sing-box 本来就应处于停止状态，门禁不得为了匹配事务快照而提前启动或重启它；服务只能由 systemd 在门禁成功退出后启动。同时，普通 apply 会在事务中重启 sing-box，门禁不能因这次重启再次进入并与 apply 已持有的锁互相等待。

## 固定启动图

受限落地通道安装层同时管理以下 root 控制的固定文件：

- `/etc/systemd/system/sb-user-manager-landing-recovery.service`；
- `/etc/systemd/system/sing-box.service.d/10-sb-user-manager-landing-recovery.conf`。

恢复单元是 `Type=oneshot`、`RemainAfterExit=yes`，以 root 身份执行现有 root-only helper 的固定 `--recover-startup` 模式，并设置 `StandardInput=null`。它以 `After=nftables.service` 表达顺序，但不以 `Wants=` 或 `Requires=` 把可选的 nftables 基础服务变成硬依赖；随后在 sing-box 之前运行。sing-box drop-in 同时使用 `Requires=` 和 `After=` 指向恢复单元：`After=`保证顺序，`Requires=`保证恢复失败会传播为 sing-box 启动失败。

单元和 drop-in 禁止使用 `ConditionPathExists=`。事务路径损坏、悬空符号链接或证据缺失都必须进入恢复代码并失败关闭，不能被 systemd 当作“条件不满足、成功跳过”。

`RemainAfterExit=yes` 使一次启动周期内的普通 `systemctl restart sing-box` 不会重新执行门禁。首次普通 apply 在取得任何输入、通道或 receipt 锁之前，必须先执行 `systemctl start sb-user-manager-landing-recovery.service`，再确认该单元为 `active`。门禁的 `ExecStart` 随后自行按既有固定顺序取得：

1. 输入锁；
2. 通道 shared lock；
3. receipt 锁。

因此首次 apply 会先让门禁完成并保持 active，再进入自己的锁链；后续 apply 内部重启 sing-box 不会重入门禁。门禁启动或 active 检查失败时，普通 helper 必须在取得输入锁和读取 stdin 之前返回固定、无秘密的错误。

## 冷启动恢复语义

启动入口只接受零参数、root 身份、固定生产路径和已安装且逐字匹配的 unit/drop-in。它不安装软件、不访问网络、不读取 stdin，也不启动或重启 sing-box。正常冷启动恢复在进入与退出时都要求 sing-box 为 `inactive` 或 `failed`。

唯一例外是首次把门禁动态接入一台已有 v4 或外部 sing-box、且该服务已经 `active` 的机器。为了避免仅安装 dormant 通道就中断既有服务，此时只允许“v5 完全空态”直接通过：apply 事务目录不存在且不是符号链接、receipt 不存在且不是符号链接、v5 TLS 目录与持久 nftables 文件不存在、sing-box 配置没有 v5 受管残留，并且内核中没有项目同名 nftables 表。该分支不得运行事务恢复、写文件或更改防火墙；任何部分 v5 状态、未知 systemd 状态或检查失败都必须失败关闭。下一次真实开机时 sing-box 尚未启动，仍走上述正常冷恢复路径。

恢复继续以 ADR 0010 的固定事务目录、journal、manifest、阶段标记和锁为唯一依据：

- `active`：只接受快照旧值、候选新值或 ADR 0010 明确授权的中间状态；恢复旧文件、目录、receipt 与 nftables，持久化 `rolled_back` 后清理；
- `committed`：保留候选文件与新 receipt，恢复候选 nftables 表，只清理已验证的终态事务；
- `rolled_back`：保留旧文件与旧 receipt，恢复旧 nftables 表，只清理已验证的终态事务；
- 无事务：严格检查持久化的落地状态；已应用时确保固定项目 nftables 表与持久规则一致，尚未应用时不创建运行状态。

重启后内核中的项目 nftables 表可能为空，这是可解释的冷启动状态；门禁只可从已验证的固定持久规则或事务材料恢复它。出现第三种实时表、未知文件内容、损坏 journal/manifest、权限漂移或符号链接时，门禁返回失败并保留证据，sing-box 不得启动。

## 通道安装、升级与卸载

unit 和 drop-in 属于 ADR 0009 的通道生命周期，而不是 v4 全局安装器。全新安装、通道轮换、失败恢复和中断恢复都必须把它们纳入同一持久通道事务：候选逐字校验，目标只接受 root 拥有的普通文件，旧文件及“原先不存在”状态均进入快照。

`daemon-reload` 是会影响运行图的事务步骤，统一通过可测试的固定 wrapper 调用。候选激活后的 reload 失败必须恢复旧 unit/drop-in、再次 reload 旧图并保留事务证据；不能忽略失败。远程 `authorized_keys` 仍是最后激活项，只有门禁文件、systemd 运行图和其余提权材料全部有效后才能开放入口。

只要 landing receipt 路径存在或是符号链接，通道卸载就失败关闭并保留门禁。这样不会在已有落地运行状态时移除下一次开机所需的恢复边界；完整角色卸载应由未来独立流程先安全撤销运行状态和 receipt。

## 范围与限制

本能力继续保持 dormant：不接入 v4 菜单、全局安装/更新/卸载流程、入口编排、正式服务器或发布行为，不改变状态 schema、apply package、receipt 或加密格式。只有显式调用尚未接入产品界面的受限落地通道安装函数时，才会安装门禁。

`RemainAfterExit=yes` 解决同一启动周期内 apply 重启 sing-box 的锁重入问题。若管理员在一次在线 apply 被不可捕获中断后绕过管理器手工启动 sing-box，systemd 不会重新执行已经 active 的门禁；该越权运维不在本决定的自动恢复保证内。正常路径会保持 sing-box 停止，下一次 apply 会先恢复；机器重启时门禁也会重新运行。

## 验证

CI 必须同时验证：

- 渲染后的 unit/drop-in 含 `Requires=`、`After=`、`RemainAfterExit=yes` 和 `StandardInput=null`，且没有 `ConditionPathExists=`；
- Ubuntu 24.04 与 Debian 12 使用 `systemd-analyze verify` 验证有效单元图；
- Ubuntu 24.04 在真实 systemd PID 1 下运行唯一命名且只链接到 `/run` 的合成单元：健康门禁必须先记录恢复与 nftables 就绪再运行合成 sing-box，纯 `After=` 的可选 nftables 单元不得被主动启动，同一启动周期重启合成 sing-box 不得重入门禁，门禁失败则合成 sing-box 的 `ExecStart` 不得执行；
- 普通 helper 的门禁预检早于输入锁，预检失败时 stdin 保持未读；
- 已 active 的既有 sing-box 只在 v5 完全空态下通过首次激活，且该例外不得执行恢复或防火墙变更；
- `systemctl start` 成功后仍必须通过 `is-active`，`daemon-reload` 失败可注入且会向事务层传播；
- receipt 普通文件或符号链接都会阻止通道卸载；
- v4 菜单、全局安装器、生成物一致性和既有测试保持不变。

## 回退

在 dormant 且尚无 receipt、无 apply 事务、无已应用落地运行状态时，可通过同版本通道卸载事务恢复原 unit/drop-in 并执行 `daemon-reload`。只要 receipt 或事务证据存在，就不得手工删除 unit、drop-in 或持久目录；必须先由同版本恢复逻辑收敛现场，再由未来角色卸载流程撤销运行状态。
