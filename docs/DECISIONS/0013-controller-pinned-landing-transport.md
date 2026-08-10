# ADR 0013：入口固定主机身份的受限落地传输

- 状态：已接受，入口远程 apply 能力尚未接入菜单或安装流程
- 日期：2026-08-08
- 关联：[ADR 0005](0005-entry-authenticated-multi-egress-controller.md)、[ADR 0006](0006-controller-state-schema.md)、[ADR 0007](0007-landing-secret-and-apply-protocol.md)、[ADR 0009](0009-restricted-landing-channel-installation.md)、[ADR 0012](0012-anonymous-apply-package-publication.md)、[Issue #214](https://github.com/DTB201/sb-user-manager/issues/214)

## 背景

落地侧已经能安装身份绑定的受限 SSH 通道，并能通过 forced command 把短时 apply package 交给可回退 helper。入口侧此前仍没有正式传输实现：状态中的 SSH 主机指纹没有参与真实连接，package 也没有通过日常最小权限通道发送，远端回执尚不能安全收敛入口的 `applied_revision`。

直接使用 `StrictHostKeyChecking=accept-new`、共享 `known_hosts` 或 `ssh-keyscan` 输出建立信任，会把首次网络响应当成主机身份，无法阻止中间人替换。仅收到一个成功 JSON 便写回状态，也会让过期、错机或并发变更前发出的请求覆盖入口的新期望状态。

## 决定

### 主机身份

入口只处理控制器状态中已存在且状态为 `pending`、`active` 或 `error` 的落地。首次注册必须事先通过后续独立流程让用户核验并保存该落地的 Ed25519 SSH 主机指纹；本模块不自动建立信任。

每次调用使用 `ssh-keyscan` 取得当前网络端点提供的 Ed25519 候选公钥，但扫描结果只用于发现，不是信任来源。入口执行以下门禁：

1. 只接受格式严格且归一化后唯一的 Ed25519 公钥；没有结果、包含其他格式或存在两个不同公钥均拒绝。
2. 使用 `ssh-keygen -E sha256` 计算候选指纹，并与控制器状态中固定的指纹精确比较。
3. 只有完全一致时才为本次调用生成 0600 的临时 `known_hosts`；记录使用由 `landing_id` 派生的固定 `HostKeyAlias`，不把地址当成身份。
4. OpenSSH 仍启用 `StrictHostKeyChecking=yes` 并把主机密钥算法固定为 Ed25519。指纹变化、算法变化、DNS 变化后出现不同主机或扫描歧义都在用户认证前失败关闭。

### SSH 权限和传输

入口使用秘密清单中该落地独有、可非交互使用的 Ed25519 私钥连接固定的 `sb-landing-agent` 账户。OpenSSH 忽略系统和用户配置，不使用代理跳转或本地命令，并明确禁用密码、键盘交互、agent/X11/端口转发、隧道和 PTY；目标主机是 argv 中最后一项，不携带远程命令，因此只能触发落地 `authorized_keys` 中已经固定的 forced command。

主机密钥探测、建连和整个会话都有固定超时。标准错误丢弃，标准输出受文件大小上限保护，只允许 landing agent 定义的最大 512 字节严格 JSON。SSH 退出状态必须与回执类型一致：退出 0 只能对应 `applied` 或 `idempotent`，非零只能对应受限 `error`。远端不能借由日志、终端控制序列、额外 JSON 字段或超长输出把不受信任内容带入管理界面。

apply package 仍由 ADR 0012 的匿名 builder 构建。入口在验证 package 的 revision 和摘要后打开文件描述符，立即删除最终目录项并同步工作目录；SSH 只从该匿名化 fd 的 stdin 读取。传输期间 package 不出现在 SSH argv，也没有可通过文件名重新打开的副本；会话结束或入口进程消失时，内核关闭 fd 并回收 inode。

### 回执和状态收敛

成功回执必须同时满足：

- `revision` 等于本次 package 的期望 revision；
- `content_sha256` 等于本次实际 package 的 gateway 摘要；
- 当前控制器中该落地的完整记录仍与发起请求时快照一致。

三项全部满足后，入口才在控制器状态锁内原子更新 `applied_revision`、`config_sha256` 和 `status=active`，并按 schema 规则提升全局 revision。已经完全收敛的 `idempotent` 重试不再产生状态写入。若网络调用期间地址、固定指纹、秘密引用、期望 revision、状态或任何其他落地字段发生并发变化，旧回执即使真实来自落地也不能覆盖新状态；下一次 reconcile 使用新期望重新执行。

远端错误、连接超时、主机身份变化、畸形回执、退出状态矛盾、revision/摘要不符和并发状态变化都保持入口状态不变。远端可能已完成旧 revision 但入口因并发门禁拒绝确认时，状态仍保留旧 `applied_revision`，后续更高 revision 的幂等 reconcile 会重新建立一致性。

### 临时材料和诊断

控制器传输工作目录固定在 root-only 的运行目录中。主机候选公钥、临时 `known_hosts`、落地快照和受限回执均为 0600；package 在传输前已 unlink。成功、失败和可捕获信号路径清理整份本次工作目录。模块本身不输出地址、候选指纹、密钥路径、SNI、密码、PEM、package 或远端原始错误。

SSH 私钥内容、网关密码和 PEM 从不进入外部命令 argv。SSH 私钥文件路径和目标地址是本地 OpenSSH 建连所需参数，但不会被本模块写入诊断或日志。

## 兼容性与范围

本模块继续 dormant：不接入 v4 菜单、在线更新、角色安装、首次 root 引导、批量同步或入口数据面，也不登录或修改任何服务器。控制器状态 schema、秘密清单和 apply package 格式不变。

macOS 本地只覆盖纯状态和协议门禁。Ubuntu 与固定 Debian 12 CI 覆盖完整匿名构包；隔离的 Debian OpenSSH 环境还必须覆盖真实主机指纹固定、受限账户、forced command 和 sudo 边界。真实服务器启用仍需独立 Issue、回退记录和项目所有者授权。

## 回退

撤销入口传输模块、测试、本文档和同步生成的单脚本即可回退。由于没有菜单、安装或服务器调用，回退不涉及 v4 状态、落地 receipt、服务或服务器数据。
