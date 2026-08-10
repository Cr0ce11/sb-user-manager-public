# ADR 0014：入口侧受管落地注册与无副作用通道探测

- 状态：已接受，注册能力尚未接入菜单、角色安装或 root 引导
- 日期：2026-08-08
- 关联：[ADR 0006](0006-controller-state-schema.md)、[ADR 0007](0007-landing-secret-and-apply-protocol.md)、[ADR 0009](0009-restricted-landing-channel-installation.md)、[ADR 0013](0013-controller-pinned-landing-transport.md)、[Issue #216](https://github.com/DTB201/sb-user-manager/issues/216)

## 背景

入口远程 apply 已能安全处理控制器状态中存在、秘密清单有效且受限 SSH 通道已经初始化的落地，但此前没有正式注册入口。测试只能直接写 JSON，无法证明准备登记的地址、固定主机身份、每机管理密钥和远端 forced agent 属于同一条受限通道。

`ssh-keyscan` 返回的网络候选不能自动建立信任。仅验证端口可连接也不能证明管理密钥有效，更不能证明连接最终进入受限 agent；发送一个有效 apply package 作为测试又可能在用户确认登记前改变远端配置。

## 决定

### 候选指纹与确认

入口提供只读候选发现能力：在 root-only 临时目录中扫描目标的 Ed25519 主机公钥，拒绝空结果、非 Ed25519、畸形、超长以及归一化后存在多个不同密钥的响应，并用 `ssh-keygen -E sha256` 计算唯一候选指纹。工作目录清理完成后才向调用方输出一行 `SHA256:...`，不输出地址、原始公钥或扫描错误。

候选指纹只供管理员与落地控制台或可信资产记录核对，不能直接成为信任来源。正式注册必须由调用方重新传入经独立渠道确认的完整指纹；入口在连接前再次扫描并精确比较。两次扫描之间发生任何变化都会失败关闭。

### 无副作用通道探测

注册只接受已有且通过 ADR 0007 全部门禁的 `CONTROLLER_SECRET_DIR/landing-<id>.json`，秘密引用由 `landing_id` 唯一派生，不能由调用方指定任意路径。入口使用清单中的 Ed25519 私钥、临时固定 `known_hosts` 和 ADR 0013 的完整 OpenSSH 限制连接 `sb-landing-agent`。

探测通过匿名文件描述符发送零字节 stdin，不构建或发送 apply package。受限 agent 必须以非零状态返回唯一且严格的 `{"status":"error","code":"invalid_input"}`；只有该组合才证明固定主机身份、管理公钥、forced command 和 agent 协议同时匹配。成功退出、其他错误码、额外字段、超长或多份 JSON、连接超时和空响应全部拒绝。空输入不能通过结构校验，因此不会进入 apply、receipt 或运行配置事务。

### 原子登记和后续 apply

只有通道探测成功后，入口才初始化独立控制器状态，并在状态锁内原子新增一条落地记录：

- `status=pending`；
- `desired_revision=1`、`applied_revision=0`；
- `config_sha256=null`；
- `credential_ref` 为该 ID 唯一的严格秘密清单路径。

登记提升一次全局 revision，并拒绝重复 ID、重复 `address + ssh_port`、重复秘密引用、SSH 与网关端口相同以及 revision 耗尽。并发注册由最终锁内条件决定，网络探测期间读取的旧状态不能绕过重复检查。

组合入口可以在登记后调用 ADR 0013 的既有远程 apply。apply 成功后由原有回执门禁收敛为 `active`；apply 失败时保留 `pending` 记录和未推进的 `applied_revision`，明确表示身份登记已完成但配置仍待重试。不能因为第二阶段失败而声称添加成功，也不能删除已经完成身份绑定的事实。

## 安全和兼容边界

注册、探测和 apply 均不把密码、证书、私钥内容、完整 SNI 或远端原始错误写入 argv、终端或日志。临时扫描结果、known_hosts 和响应均为 600，工作目录为 700，成功和失败路径统一清理。

本能力继续 dormant：不接入 v4 菜单、在线更新、首次启动或服务器部署，也不生成秘密、不使用 root SSH、不安装远端账户、authorized_keys、sudoers 或 systemd。一次性 root 初始化和最终“添加并初始化落地机”交互向导必须另开高风险 Issue，记录回退并获得项目所有者授权。

## 回退

撤销注册模块、共享扫描门禁、测试、本文档和同步生成的单脚本即可。当前没有运行时入口或服务器调用，回退不涉及 v4 状态、迁移包、落地 receipt 或服务。
