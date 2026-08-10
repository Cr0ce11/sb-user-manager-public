# 架构说明

## 系统边界

项目交付物是一个可直接运行的 Bash 管理脚本。它以 root 身份协调以下组件：

- sing-box：连接、入站、出站和分流执行层。
- Nfuse：用户流量统计和配额执行层。
- systemd：服务、定时器和故障恢复入口。
- 本地 JSON 状态：受管用户、分流和事务状态。
- GitHub Release：管理脚本及外部程序的版本来源。

## 逻辑模块

开发源码按职责保存在 `src/`，模块顺序由 `src/modules.list` 唯一确定。`tools/build-manager.sh` 只按清单顺序逐字节拼接模块，并生成仓库根目录的 `sb-user-manager.sh`。部署、更新和 Release 始终只使用这个单脚本，不在服务器安装源码模块或构建工具。

主程序逻辑分为：

1. 运行配置解析与权限验证。
2. 输入校验和交互菜单。
3. 用户、协议和客户端配置管理。
4. Nfuse 账户、端口和用量管理。
5. 分流、规则集和出口管理。
6. 原子状态更新与一致性检查。
7. 操作事务、环境事务和中断恢复。
8. 迁移备份、冲突预览和恢复。
9. 安装、外部环境接管和版本更新。
10. 诊断、脱敏和验收报告。

## 数据权威来源

- sing-box 配置描述实际网络运行结构。
- 管理状态文件描述本项目负责管理的对象。
- Nfuse 数据描述账户、端口和流量执行状态。
- 三者必须通过一致性检查保持对应，任何一方都不能被无条件覆盖。

状态 schema 4 在用户和分流之外保存两类惰性对象：`outbound_presets` 与 `rule_presets`。预置只保存可复用输入，不直接生成 sing-box 配置。每条新分流仍保存完整规则地址与出口快照，并通过可选的预置名称保持关联；因此运行时不依赖预置即时存在，删除预置时可以安全解除关联而不改变正在使用的配置。

修改预置会先把新内容写入所有关联分流的快照。只要存在启用中的关联分流，状态更新、全部启用分流重建、sing-box 校验和单次重启必须处于同一个受保护事务中；任何步骤失败都恢复事务前状态。停用分流保留新快照但不生成运行配置。旧 schema 3 分流升级后不自动猜测关联关系。

## 变更原则

- 状态写入使用同目录临时文件和原子替换。
- 多组件变更必须进入事务，先备份再修改。
- 下载内容必须验证来源、HTTPS 地址和 SHA-256 digest。
- 配置、备份、报告和临时明文使用 root 专用权限。
- `sb-user-manager.sh` 是确定性生成物，不应手工修改；源码修改后必须重新构建并提交同步生成的单脚本。
- 模块化只改变仓库内的维护方式，不改变函数名称、函数顺序、配置、菜单、部署文件或服务器行为。
- 现有单文件发布和运行方式保持不变。

## 兼容性

服务器运行环境只支持 Debian 12 x86_64。macOS 仅作为本地源码构建和静态测试环境，不属于部署或运行支持范围。

涉及以下内容的变更必须提供升级与回滚设计：

- 状态 schema。
- 迁移包格式。
- 事务日志格式。
- sing-box 配置结构。
- Nfuse 账户类型和端口绑定。
- systemd 单元及安装路径。

格式版本只能显式递增，不能根据字段存在与否进行不可逆猜测。

## 规划中的 v5 控制器

[ADR 0005](DECISIONS/0005-entry-authenticated-multi-egress-controller.md) 已接受“入口完成 AnyTLS 认证后再计费、集中管理受管落地、继续兼容现有 AnyTLS 分流出口”的未来方向；[POC 验收方案](V5-ENTRY-CONTROLLER-POC.md) 定义了开始实现前必须取得的证据。

Issue #199 的第一阶段专用测试环境 POC 已验证单入口、单落地的认证后计费和失败关闭。[ADR 0006](DECISIONS/0006-controller-state-schema.md) 定义了独立的入口控制器状态基础，[ADR 0007](DECISIONS/0007-landing-secret-and-apply-protocol.md) 定义了每台落地的秘密清单、短时 apply package 和重放 receipt，[ADR 0008](DECISIONS/0008-restricted-landing-agent-and-rollback.md) 定义了受限 agent 与本地可回退 apply 引擎，[ADR 0009](DECISIONS/0009-restricted-landing-channel-installation.md) 固定了身份绑定和事务安装边界，[ADR 0010](DECISIONS/0010-durable-landing-apply-transaction.md) 增加跨 `SIGKILL` 与断电的持久 apply 事务，[ADR 0011](DECISIONS/0011-landing-startup-recovery-gate.md) 让该恢复在 systemd 启动 sing-box 前完成，[ADR 0012](DECISIONS/0012-anonymous-apply-package-publication.md) 保证控制器构包期间被强制终止也不会留下额外的具名秘密文件，[ADR 0013](DECISIONS/0013-controller-pinned-landing-transport.md) 用固定 Ed25519 主机指纹、受限 OpenSSH stdin 和乐观并发门禁完成已初始化落地的单次远程 apply 与回执收敛，[ADR 0014](DECISIONS/0014-controller-landing-registration.md) 则在不发送有效配置包的前提下验证主机、管理密钥和 forced agent，并原子登记待同步落地。[ADR 0015](DECISIONS/0015-entry-initiated-landing-root-bootstrap.md) 使用固定主机身份的一次性 root SSH、自校验公开材料包和精确 bootstrap 收据，为干净落地建立可审计且可回退的受限通道。[ADR 0016](DECISIONS/0016-controller-landing-credential-initialization.md) 在已建立入口角色后原子生成每落地独立 SSH、密码和 TLS 材料，并固定中断续接与未登记秘密清理边界。[ADR 0017](DECISIONS/0017-controller-landing-onboarding-orchestration.md) 在持久修改前完成输入、重复目标和主机指纹确认，再按明确失败阶段串联凭据、root 引导、登记与首次 apply。[ADR 0018](DECISIONS/0018-controller-landing-onboarding-durable-journal.md) 则在本地或远端修改前持久化操作身份和精确目标，并按可证明的登记事实跨 `SIGKILL`、崩溃或断电保守恢复。[ADR 0019](DECISIONS/0019-entry-controller-role-initialization.md) 增加只读的平台与入口依赖门禁，并把首次角色建立收束为拒绝现有单机部署、保护合法既有状态的幂等入口。[ADR 0020](DECISIONS/0020-entry-controller-dependency-repair.md) 用固定包清单和干净环境提供显式依赖修复，[ADR 0021](DECISIONS/0021-entry-controller-role-provisioning.md) 再把目标确认、依赖修复与最终角色复检固定为单一的幂等编排入口。[ADR 0022](DECISIONS/0022-read-only-manager-role-detection.md) 则以受信任身份标记和文件足迹只读区分尚未部署、standalone、entry-controller 与 landing，并拒绝混合角色、非法标记和部分环境。[ADR 0023](DECISIONS/0023-role-aware-startup-routing.md) 首次把该事实源接入真实启动分发，保留 standalone 原流程，并把入口安装、入口菜单骨架和落地只读骨架限制在互相隔离的角色路径。[ADR 0024](DECISIONS/0024-entry-initiated-landing-dependency-preparation.md) 在任何项目状态或秘密落地前，用人工确认且二次固定的主机指纹、完整包摘要和固定 APT 清单从入口补齐干净落地的运行依赖，并把无法事务回退的系统包安装隔离为可复检、可重试的独立阶段。[ADR 0025](DECISIONS/0025-entry-initiated-landing-singbox-runtime-preparation.md) 再由入口获取并校验官方稳定版 sing-box，只在干净目标上原子安装或对完全一致目标幂等通过，拒绝覆盖任何未知现有二进制。[ADR 0026](DECISIONS/0026-unified-pre-secret-landing-readiness-gate.md) 把两项准备收束为一次指纹确认、两次连接前复核和严格短路的统一秘密生成前门禁，并以隔离临时目录和稳定子阶段结果保持可诊断、可重试且不提前写入项目状态。[ADR 0027](DECISIONS/0027-readiness-gated-landing-onboarding.md) 最后让统一 onboarding 入口在任何持久日志或秘密之前强制通过该门禁，内部复用同一已确认指纹，并保留既有回退与恢复语义。

角色感知启动和首次入口安装已经完成专用入口、落地测试机的安装、重启、失败恢复和回退验收，但入口数据面、入口业务操作、落地添加/同步/恢复和 v5 迁移仍未开放。入口或落地界面中的未开放动作不会回落到 v4；standalone 保持原菜单与启动顺序。此次验收只证明角色分发和空入口初始化边界成立，不能据此推断脚本已经具备可用的多落地产品能力或可以发布正式版本。
