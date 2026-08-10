# ADR 0006：入口控制器独立状态 schema

- 状态：已接受，基础模块尚未接入运行流程
- 日期：2026-08-07
- 关联：[ADR 0005](0005-entry-authenticated-multi-egress-controller.md)、[Issue #200](https://github.com/DTB201/sb-user-manager/issues/200)

## 背景

入口控制器需要保存受管落地的身份、固定 SSH 主机指纹和同步 revision。v4 的 `managed-users.json` 已是正式用户、分流和预置数据的权威来源；在 v5 的用户路由、计费绑定和迁移策略尚未完成前直接升级该文件，会让现有服务器承担不必要的迁移和回退风险。

Issue #199 的最小 POC 已证明认证后计费与失败关闭可行，但 POC 配置不是正式状态格式，也不能成为第二个事实源。

## 决定

v5 入口控制器先使用独立的 `/var/lib/sb-user-manager/controller-state.json`，schema 从 1 开始。该文件在正式入口安装流程接入前不会自动创建，现有 v4 启动、菜单、用户状态和迁移包均不读取它。

根对象只允许以下字段：

- `schema_version`：固定为 1。
- `role`：固定为 `entry-controller`。
- `revision`：入口期望状态的全局非负安全整数版本（不超过 JSON 精确整数上限）。
- `landings`：受管落地数组。

每个受管落地只允许以下字段：

- `id`：稳定、不可复用的机器标识，不使用地址或显示名称充当身份。
- `display_name`：只用于交互显示。
- `address`、`ssh_port`：入口连接落地管理通道的目标。
- `ssh_host_fingerprint`：注册时固定的 OpenSSH SHA256 主机指纹。
- `gateway_port`：入口到落地 AnyTLS 网关端口。
- `status`：`pending`、`active`、`disabled`、`error` 或 `emergency_override`。
- `desired_revision`、`applied_revision`：入口期望版本与最后确认应用版本；已应用版本不能大于期望版本。
- `config_sha256`：落地返回的脱敏配置摘要，尚未应用时为 `null`。
- `credential_ref`：该落地独立秘密文件的绝对引用。

状态文件拒绝未知字段、重复 ID、非法地址/端口/指纹、未知状态、revision 倒退和内联秘密。任何落地内容变化都必须提升全局 `revision`；同一落地的期望和已应用 revision 保持单调递增。

## 秘密边界

状态文件可以保存地址和固定主机指纹，但不得保存 SSH 私钥、AnyTLS 密码、证书私钥、Token 或完整客户端 URL。每台落地只保存形如 `CONTROLLER_SECRET_DIR/landing-<id>.json` 的引用；秘密文件的具体 schema、创建、轮换和销毁由后续独立 Issue 定义。

控制器状态、秘密目录和锁目录必须是受信任的普通路径：目录权限 700，状态文件权限 600，拒绝符号链接。真实运行要求 root 所有；库模式只为单元测试允许当前测试用户。

## 写入与兼容

- 初始化和更新持有独立锁。
- 新内容先写入同目录临时文件，完成 schema、权限和 revision 转换校验后再原子替换。
- 任一步失败时保留原文件并清理临时文件。
- schema 不根据字段存在与否猜测升级；未来格式变化必须显式递增版本并另行设计迁移。
- v4 `STATE_SCHEMA_VERSION=4`、迁移格式 1、菜单、事务顺序和服务器行为不变。

## 暂不包含

本决定不定义用户客户端路由、外部 AnyTLS 出口、计费绑定、秘密文件内容、落地 agent 包、远程 SSH 应用或菜单。这些对象只有在各自安全不变量和回退方式确定后才能加入后续 schema。

## 回退

在控制器安装流程接入前，该模块没有运行时调用。撤销模块、测试和本文档并重新生成单脚本即可回退，不需要修改现有状态、迁移包或服务器。
