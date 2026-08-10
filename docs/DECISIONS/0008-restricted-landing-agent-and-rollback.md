# ADR 0008：受限落地 agent 与可恢复 apply 引擎

- 状态：已接受，执行模块与安装能力已实现但尚未接入服务器或菜单
- 日期：2026-08-07
- 关联：[ADR 0005](0005-entry-authenticated-multi-egress-controller.md)、[ADR 0007](0007-landing-secret-and-apply-protocol.md)、[ADR 0009](0009-restricted-landing-channel-installation.md)、[ADR 0010](0010-durable-landing-apply-transaction.md)、[Issue #204](https://github.com/DTB201/sb-user-manager/issues/204)

## 背景

ADR 0007 已定义短时 apply package、重放判定和 receipt，但尚未把它们连接到任何运行配置。直接开放 root SSH 或让入口传入远程命令，会扩大权限并使秘密、路径和回退语义失去约束。因此先建立一个可在隔离目录完整测试的执行引擎；账户、强制命令和 sudoers 的安装边界随后由 ADR 0009 固定，断电恢复语义由 ADR 0010 补充。

## 决定

同一份 root 拥有的生成脚本预留两个固定调用名：

- `sb-user-manager-landing-agent`：由受管 `authorized_keys` 的 `restrict,command="..."` 调用。它必须处于 SSH 会话、拒绝 `SSH_ORIGINAL_COMMAND`、TTY 和任何调用方参数，只把 stdin 交给固定 helper。
- `sb-user-manager-landing-apply`：由 sudoers 只允许携带当前通道代际运行。它必须以 root 执行，拒绝代际缺失、失配或额外参数，固定 `PATH` 和 locale，并清除可能影响 Python、OpenSSL 或 Bash 加载行为的环境变量。

agent 只接受 helper 返回的两种严格 JSON：`applied/idempotent + revision + content_sha256`，或 `error + 固定格式 code`。额外字段、多份 JSON、超长输出和任意文本全部替换为 `handoff_failed`；密码、PEM、完整 SNI 和入口地址不会返回。

## apply 顺序

root helper 最多从 stdin 读取 1 MiB，随后在通道 shared lock 与 receipt 锁内执行：

1. 严格校验单份 package、TLS 材料、摘要、落地 ID 和重放状态；首次应用使用临时空 receipt 判定，不提前创建真实 receipt。
2. 渲染只含一个 AnyTLS 网关入站和直连出口的 sing-box 候选；密码直接从 JSON 数据读取，SNI 只用于前置证书覆盖校验，二者均不进入外部命令参数。
3. 渲染独立的 `inet sb_user_manager_landing` nftables 表：只允许包中指定的入口 IPv4 访问网关端口，其他 IPv4/IPv6 来源对该端口全部丢弃。
4. 使用候选 TLS 路径执行 `sing-box check`，并使用 nftables check 模式验证规则。
5. 在固定的 root-only 持久事务目录中，以 600 权限保存并同步候选、现有配置、TLS 文件、持久化 nftables 文件、实时 nftables 表、服务状态和 receipt 快照；持久 journal 完成后才允许第一次运行态修改。
6. 每个受管文件通过同目录临时文件原子替换，再以一次 nftables transaction 应用入口限制。
7. 重启 sing-box，确认 systemd 为 active，并确认目标端口确实由 `sing-box` 进程监听。
8. 健康检查成功后才创建或推进真实 receipt；receipt 与事务终态均完成原子替换和持久化同步后才能返回 `applied`。相同 revision 和相同摘要直接幂等返回，不重载服务。

## 回退、恢复与中断

从持久事务进入非终态到 `committed` 完成之间注册专用信号回退。文件替换、防火墙、重载、健康检查、receipt 初始化或 receipt 提交任一步普通失败，均依据持久快照恢复原文件、原 nftables 表、原服务状态和原 receipt，并在完整核验后写入 `rolled_back`。SIGKILL、内核崩溃或断电留下的非终态由下一次 apply 请求在执行新包前继续回滚；回滚本身必须可重复。

`committed` 与 `rolled_back` 是唯一终态。终态只允许继续清理事务目录，不能根据残留快照反向改变已经提交或已经恢复的运行态。原子替换已经发生但文件系统同步失败时，当前调用必须报告失败并保留事务现场，不得猜测替换是否已持久，也不得用一次新的反向替换掩盖不确定性；详细规则见 ADR 0010。

短时传输 package 仍在请求结束时清理；持久事务内的候选和快照只服务于自动恢复，不是用户备份。它们可能包含 AnyTLS 密码和 TLS 私钥，必须保持 root-only，并在持久终态确认后清理。

## 固定运行边界

本阶段管理的目标固定为 `/etc/sing-box/config.json`、`/etc/sing-box/landing/`、`/etc/nftables.d/sb-user-manager-landing.nft`、`sing-box` 服务、ADR 0007 receipt 和 ADR 0010 持久事务目录。现有目标必须是受信任所有者的普通文件，目录不得为符号链接或允许组/其他用户写入。生产调用不接受环境变量改写这些路径；测试模式才允许通过隔离系统根目录验证。

## 暂不包含

本决定不接入 v4 菜单、入口侧编排或任何服务器。ADR 0009 已实现专用账户、`authorized_keys`、sudoers、调用入口与通道代际绑定，但它们仍保持 dormant。ADR 0010 当前只在下一次 apply 请求到来时恢复遗留事务，尚未提供开机阶段先于 sing-box 暴露监听执行的恢复门禁，因此本模块仍不得接入生产入口或被描述为 production-ready。

## 回退

执行模块目前没有现有 v4 运行时调用。撤销模块、测试和本文档并重新生成单脚本即可回退；不会改变 v4 用户、分流、迁移数据、服务或服务器状态。若未来测试环境已留下持久 apply 事务，必须先按 ADR 0010 完成恢复或终态清理，不能直接删除恢复上下文。
