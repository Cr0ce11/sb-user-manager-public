# ADR 0015：入口发起的一次性落地 root 初始化与精确回退

- 状态：已接受，初始化能力尚未接入菜单、角色安装或服务器
- 日期：2026-08-08
- 关联：[ADR 0009](0009-restricted-landing-channel-installation.md)、[ADR 0013](0013-controller-pinned-landing-transport.md)、[ADR 0014](0014-controller-landing-registration.md)、[Issue #218](https://github.com/DTB201/sb-user-manager/issues/218)

## 背景

入口已经能固定落地 SSH 主机指纹、验证受限 forced agent 并登记落地，但前提是远端已经安装专用账户、`authorized_keys`、sudoers、运行时和开机恢复门禁。要求管理员先把完整管理器长期安装到落地，再本地调用内部函数，既不构成产品流程，也无法在 SSH 结果不确定时证明可以安全回退哪一次初始化。

首次引导是唯一允许使用通用 root SSH 的阶段。完成后，入口日常操作仍只能通过 ADR 0009 的低权限账户和固定 helper；不能因为引导方便而保留 root 密钥、密码、控制连接或任意远程命令能力。

## 决定

### 一次性自校验包

入口从已经通过 ADR 0007 校验的每落地秘密清单中只派生 Ed25519 公钥。引导包包含当前受信任的完整管理器运行时、该公钥、`landing_id`、允许的入口公网 IPv4、随机 256 位 `bootstrap_id` 和运行时 SHA-256；不包含管理私钥、AnyTLS 密码、CA 私钥、网关私钥或 apply package。

包只能生成到入口的 700 临时目录和 600 普通文件，大小上限为 8 MiB。运行时以 Base64 载荷嵌入，包执行前重新提取、核对摘要和 Bash 语法。运行时通过已打开且随后取消目录项的只读文件描述符交给既有安装器；落地不需要预装或长期保留 `/usr/local/sbin/sb-user-manager`，最终仍只安装 ADR 0009 明确拥有的固定运行素材。

### 临时 root SSH

入口仍使用人工通过独立渠道确认的唯一 Ed25519 主机指纹和临时 `known_hosts`，以 `StrictHostKeyChecking=yes` 连接 `root`。连接禁用 PTY、转发、代理跳转、复用、用户配置和主机密钥自动更新。管理员密码如有需要，只能由 OpenSSH 从控制终端直接读取；程序不读取、不保存，也不把密码传入环境或 argv。

远端命令固定为一个最小接收器：在随机 700 目录中把 stdin 写为 600 文件，先与入口放入命令的整包 SHA-256 精确比较，再用清空的环境执行。整包和提取目录在成功、失败与常规信号路径均清理。SSH、摘要或依赖验证失败时不执行包。

### bootstrap 收据与回退

在调用既有通道安装事务前，落地原子写入 root-only `landing-bootstrap.json`。收据严格绑定 `bootstrap_id`、`landing_id`、入口 IPv4、公钥指纹和安装运行时摘要，状态只允许 `installing` 或 `installed`。独立 root-only 锁串行化收据操作；收据不是管理秘密，也不授予任何权限。

安装继续完全复用 `install_landing_restricted_channel`：账户、文件、sudoers、systemd、断电 journal 和普通失败回滚仍只有一套实现。收据写入后发生中断时，同一个包可以幂等重试；只有通道整体有效后才能把收据推进到 `installed`。

入口在 root 安装返回后立即用零字节 stdin 执行 ADR 0014 探测。安装结果不确定或探测失败时，入口发送相同 `bootstrap_id` 的回退包。落地只有在收据的 ID、落地身份、入口 IPv4 和公钥指纹全部匹配时才调用既有受管卸载；错误 ID、无收据但存在通道、收据漂移或已有 apply 状态均失败关闭。回退成功后才删除收据。回退 SSH 自身失败时保留收据和通道事实，入口不得声称已经清理。

## 依赖与兼容边界

引导包不自动运行 `apt`，也不修改全局 sshd 配置。目标必须是项目支持的 Debian 12 x86_64，且已经具备 ADR 0009 所列固定依赖；缺失时在账户或受管文件变更前失败。[ADR 0024](0024-entry-initiated-landing-dependency-preparation.md) 已把依赖准备实现为更早的独立阶段，因为系统包安装无法与项目文件事务使用同一种无损回退语义。

本能力继续 dormant：不接 v4 菜单、在线更新、控制器状态登记、配置 apply、真实服务器或发布流程。入口侧秘密生成已由 [ADR 0016](0016-controller-landing-credential-initialization.md) 独立实现；最终“添加并初始化落地机”向导仍须先建立入口和落地角色安装，再按顺序调用秘密准备、候选指纹确认、本 ADR、ADR 0014 登记及 ADR 0013 apply。

## 回退

代码层撤销新增 bootstrap 模块、运行时 FD 入口、测试、本文档和重新生成的单脚本即可。测试或未来服务器已经执行过引导时，优先用精确 `bootstrap_id` 回退；若已经产生 apply 状态，则按落地停用和受管卸载流程处理，不能直接删除账户、收据或系统路径。
