# ADR 0009：受限落地 SSH 通道的安装与身份绑定

- 状态：已接受，安装模块已实现但尚未接入服务器或菜单
- 日期：2026-08-07
- 关联：[ADR 0007](0007-landing-secret-and-apply-protocol.md)、[ADR 0008](0008-restricted-landing-agent-and-rollback.md)、[ADR 0010](0010-durable-landing-apply-transaction.md)、[Issue #206](https://github.com/DTB201/sb-user-manager/issues/206)

## 背景

ADR 0008 已实现尚未安装的 landing agent 与 root apply helper。要让未来入口控制器能够安全调用它们，落地机需要一条权限固定、身份可审计并可完整回退的 SSH 通道。直接复用 root、现有业务账户或可交互的 sudo 规则，会让远程入口获得超出 apply 所需的能力，也无法区分同名外部资源与本项目拥有的资源。

本阶段只定义通道及其安装、检查和卸载能力。它不让 v4 菜单、在线更新或服务器自动使用 dormant v5 组件，也不代表多落地功能已经可用。

## 注册身份

安装接口必须同时接收并校验以下三项，不允许从 SSH 会话或既有系统对象推断：

- 稳定的 `landing_id`；
- 唯一获准连接管理通道的入口公网 IPv4；
- 入口为该落地单独持有的一把 Ed25519 公钥。

三者连同专用账户和组的 UID/GID、公钥指纹、全部固定安装路径及受管文件摘要，写入独立的 root-only 身份标记。状态检查必须从标记内的规范化公钥重新计算并核对指纹，不能只校验指纹字符串格式。身份标记是判断资源归属、幂等重装、轮换和卸载范围的唯一依据；缺失、权限不安全、字段不符或摘要漂移时不得接管同名资源。

落地 apply 在生产路径进入 receipt 判定前，必须先把 package 的 `landing_id` 和入口 IPv4 与身份标记逐项比较。这样即使落地尚无真实 receipt，首个 package 也不能把机器绑定到另一入口或另一落地身份。SSH 公钥负责认证调用方；package 不增加或替代这层身份检查。

## 专用账户与公钥边界

通道使用固定的专用系统账户和专用组。安装程序拒绝接管任何没有受管身份标记、UID/GID 或属性不一致的同名账户和组。

- 登录 shell 固定为真实 `/bin/sh`，供 OpenSSH 执行 forced command；不允许普通交互用途。
- shadow 密码字段固定为 OpenSSH 文档建议的不可认证且非 `!` 值 `*NP*`，禁止密码认证但不阻断公钥认证。
- home、`.ssh` 与 `authorized_keys` 由 root 拥有和管理；OpenSSH 会以目标用户权限打开密钥文件，因此 `authorized_keys` 固定为 `root:<专用组>` 的 `0640`：账户只能读取公钥记录，不能修改文件或目录。
- `authorized_keys` 必须且只能有一条受管记录：`restrict,from="<入口 IPv4>",command="/usr/local/bin/sb-user-manager-landing-agent <代际标识>" ssh-ed25519 ...`。

代际标识由 `landing_id + 入口 IPv4 + 规范化公钥` 确定性计算，并另存为 root 管理、专用组只读的 `0440` 标记。agent 只有在 forced-command 内保存的代际与当前标记严格一致时才会转交 helper。helper 取得通道 shared lock 后，还必须以 root 身份把参数中的代际与 root-only 身份标记、当前代际文件再次核对，之后才允许读取 stdin。密钥或入口 IP 轮换后，轮换前已经完成认证但尚未打开 session 的旧 SSH 连接仍携带旧代际；即使它在 agent 检查后等待轮换锁，root helper 也会在解锁后拒绝，不能只依赖 UID 进程枚举或 agent 的锁前检查处理这个窗口。

`restrict` 与 agent 自身检查共同拒绝交互 shell、PTY、端口转发、agent/X11 转发、用户 rc 和调用方提供的远程命令。额外公钥、未知内容、符号链接或组/其他用户可写的目录与文件均视为不安全漂移，不得静默覆盖。

## 固定 launcher 与环境隔离

安装程序原子部署 root 管理的确定性运行脚本、agent launcher 和仅 root 可执行的 apply launcher。SSH forced command 不能直接执行一份可由专用账户修改的脚本。

agent launcher 使用 Python isolated mode（`-I`）启动，先构造允许清单环境，再调用固定运行脚本：只保留固定 `PATH`、locale 及 agent 验证所需的 SSH 状态。apply launcher 同样从空白的受控环境调用固定 helper，不继承调用方的 Bash、Python、OpenSSL、sudo 或 locale 配置。launcher 和运行脚本不得接受自定义路径、额外参数或环境覆盖生产目标。

私钥、AnyTLS 密码、apply package、PEM 和真实服务器资料不得写入身份标记、日志、外部命令 argv 或测试夹具。

## sudo 最小授权

独立 sudoers 文件只授权专用账户以 root 身份、免密码调用固定 apply helper，并同时满足：

- `NOSETENV`，调用方不能保留或注入环境；
- `NOLOG_INPUT` 与 `NOLOG_OUTPUT`，短时 package 及返回值不进入 sudo I/O 日志；
- 命令参数精确限定为当前 64 位十六进制代际，不能省略、替换或追加参数；
- 不授权 shell、运行脚本、agent launcher 或其他命令。

候选 sudoers 文件必须在发布到固定路径前通过 `visudo -cf`。agent 以固定 argv 执行 `sudo -n -- <helper> <当前代际>`；`sudo -E`、其他命令、无参数调用以及代际不匹配或带额外参数的 helper 调用必须被拒绝。

## 安装、轮换与卸载事务

任何状态变更前，先验证 sudo、visudo、账户和组管理工具、Python、ssh-keygen 及所需固定系统路径。这些依赖由未来独立的角色化安装流程准备；本阶段不把它们加入 v4 的安装或在线更新路径。

安装按持久事务执行：在 root-only 事务目录中先写入并同步 journal；更新和卸载还要先保存并同步全部受管文件快照，然后才允许修改账户或文件。每次事务使用独立的随机 128 位十六进制 transaction ID，原子临时文件只允许由记录在当前 journal 中的同一 ID 清理，不能按宽泛文件名前缀删除其他事务或外部文件。资源全部校验通过后再写 `committed` 标记；回滚完成则先写 `rolled_back` 终态，再清理候选与快照。普通失败与信号中断立即恢复；SIGKILL 或断电留下的未提交 journal，则由下一次通道安装或卸载在同一排他锁内先恢复。`committed`/`rolled_back` 后即使清理只完成一部分，也只继续清理事务目录，不反向改变已经提交或已恢复的运行态。回滚失败时必须保留 journal 和快照，不能清空恢复上下文。

重复安装只接受身份标记拥有且当前状态完全一致的环境，并幂等返回。入口 IPv4、公钥和确定性运行脚本允许通过同一事务轮换；轮换先撤销旧 `authorized_keys` 并确认专用 UID 没有活动进程，再替换运行素材和身份，最后激活新公钥。进程门禁忽略已经没有可执行进程体的僵尸项（`STAT` 以 `Z` 开头），但对其他状态以及无法解析的进程表保持失败关闭。失败则从持久快照恢复旧通道。

卸载先撤销远程公钥入口，再只删除身份标记明确记录且摘要、UID/GID 和路径仍匹配的资源。账户、组、目录内容或文件已经漂移时停止并报告，不扩大删除范围。专用目录必须先安全清空，之后才能删除账户与组，避免留下引用未来复用 GID 的目录。部分发行版会在 `userdel` 时自动删除同名私有组；卸载把“组已不存在”视为成功，但若仍存在则必须再次匹配原 GID 才能调用 `groupdel`。正常删除失败时从持久快照恢复；若账户查询异常或同名资源已被替换，安全恢复所需的归属无法证明，必须停止、保留 journal 与快照，等待查询恢复或人工消除冲突后再恢复。系统账户数据库由本程序与系统管理工具共同写入，因此 GID 复核到实际删除之间仍以没有并发 root 级账户修改为前提。

通道锁固定为 `/var/lib/sb-user-manager/landing-channel.lock`，由 root 以 `0600` 持久管理。安装、轮换、恢复和卸载持排他锁；root apply helper 从代际复核和开始限时读取输入前就取得共享锁，并覆盖结构校验、身份校验、receipt 判定和完整 apply。另一个同为 root-only `0600` 的持久输入锁只允许一份 helper 请求进入上述读取与 apply 区间，其余并发请求立即以忙碌状态失败，避免大量慢请求长期占用共享锁。锁文件描述符在调用业务 callback 时显式关闭，callback 启动的长寿命子进程不能继承并在父进程退出后继续占锁。输入读取固定在 15 秒内结束，receipt 锁也有 30 秒上限。存在未恢复事务时共享锁路径拒绝 apply。卸载不删除两个锁：持锁时移除路径会允许另一进程创建并锁住不同 inode，破坏互斥。它们只是不含身份或秘密的同步设施，不代表通道仍处于启用状态。

ADR 0010 的持久 apply 事务与通道运维使用同一通道锁协调。只要 `/var/lib/sb-user-manager/landing-apply-transaction` 存在，安装、入口 IP 或公钥轮换、卸载就在进入排他变更 callback 前失败；路径是不安全目录、文件或符号链接时也保持失败关闭。通道层不得删除、移动或尝试解释该目录，避免破坏 apply 的 package、候选与旧状态快照。下一次 apply 请求完成恢复并清理事务目录后，通道运维才能继续。

## 暂不包含

本决定不登录或修改任何服务器，不修改全局 sshd 配置、不重启 SSH、不安装 sing-box，也不接入菜单、入口侧远程调用、主机指纹登记、首次注册 UI、v4 完整卸载或迁移流程。dormant v5 基础不接入 v4 在线更新；未来必须通过独立的角色化安装与更新流程启用。

[ADR 0011](0011-landing-startup-recovery-gate.md) 已在 ADR 0010 之上定义开机阶段先于 sing-box 的固定恢复门禁，并把 unit/drop-in 纳入本通道事务。该能力仍保持 dormant；在完成真实重启与断电故障注入验收前，本模块不得接入生产入口或被描述为 production-ready。

## 回退

代码层可以撤销本阶段新增的安装模块、测试和本文档，再重新生成单脚本。已执行过安装时，必须使用本阶段的事务卸载，只移除身份标记能够证明属于本项目的资源；不允许用通用账户删除或目录清理代替回退。
