# ADR 0007：受管落地秘密清单与 apply 协议

- 状态：已接受，协议模块尚未接入 SSH 或运行配置
- 日期：2026-08-07
- 关联：[ADR 0005](0005-entry-authenticated-multi-egress-controller.md)、[ADR 0006](0006-controller-state-schema.md)、[Issue #202](https://github.com/DTB201/sb-user-manager/issues/202)

## 背景

入口控制器状态只保存每台落地的 `credential_ref`，不允许内联秘密。落地 agent 尚未实现，但在开放任何远程执行前，必须先确定长期秘密文件、短时下发包、落地已应用状态和中断重试的唯一语义。

SSH 强制密钥已经提供控制器身份认证。第一版不叠加第二套签名密钥，避免制造独立轮换和恢复链；协议使用固定 SSH 主机身份、每台落地独立管理密钥、短有效期、nonce、递增 revision 和内容 SHA256 共同防止错机、篡改和旧包重放。

## 入口秘密清单

每台落地使用 `CONTROLLER_SECRET_DIR/landing-<id>.json`。清单为 root-only 600 普通文件，只允许：

- `schema_version`、`landing_id`、`gateway_server_name`；
- `ssh_private_key_file`；
- `gateway_password_file`；
- `gateway_ca_certificate_file`；
- `gateway_certificate_file`；
- `gateway_private_key_file`。

所有引用必须精确位于该落地自己的 700 子目录，文件为 600 普通文件且拒绝符号链接。SSH 私钥必须是可非交互使用的 Ed25519 密钥。网关密码采用 32–128 位 URL-safe 字符。CA、网关证书和私钥必须可解析、链验证成功、密钥匹配、证书至少还有一小时有效期，并覆盖清单中的网关 SNI。

完整 SNI 只通过 Python 标准输入参与主机名匹配；密码和 PEM 只从文件读取。它们不得通过 `--arg`、openssl 参数、日志或 Git 传递。

## apply package

入口生成的 JSON 包最大 1 MiB，schema 1 根对象只允许：

- `schema_version`、`landing_id`、大于零的 `revision`；
- `issued_at`、`expires_at`，有效期最多 600 秒，允许 60 秒未来时钟偏差；
- 64 位小写十六进制 `nonce`；
- `content_sha256`，等于规范化 `gateway` 对象的 SHA256；
- 唯一 `gateway` payload。

`gateway` 只允许监听端口、SNI、密码、入口来源 IPv4、CA PEM、证书 PEM 和私钥 PEM。builder 从受信任秘密文件读取密码、证书与密钥，从清单读取 SNI；入口地址通过环境读取，均不进入外部命令 argv。构包和摘要在隔离进程内完成，最终 package 按 [ADR 0012](0012-anonymous-apply-package-publication.md) 使用输出目录内的匿名文件对象生成、校验、同步并直接发布到最终名称；不再创建含 gateway 或 package 明文的具名临时文件。

该包是短时传输材料，不是长期备份。后续 SSH 传输必须通过 stdin，发送完成即清理，不能写入普通迁移包、诊断或日志。

## 落地 receipt 与重放语义

落地只长期保存不含秘密的 receipt：`landing_id`、`applied_revision`、最后内容摘要、最后 nonce 和 `emergency_override`。

- 包 revision 大于已应用版本、仍在有效期内、摘要正确且 nonce 未复用时返回 `apply`。
- 相同 revision 和相同内容摘要返回 `idempotent`，即使原包已过期也只确认既有结果，不重新应用。
- 旧 revision、同 revision 不同内容、新 revision 的过期包、最后 nonce 复用、落地 ID 不符或紧急接管状态全部拒绝。

receipt 只有在后续 apply agent 已完成配置语法检查、原子替换、服务重载和健康检查后才能提交。receipt 写入持有独立锁并使用同目录原子替换；提交失败必须由未来 agent 恢复运行配置快照。

## 暂不包含

本决定不开放 SSH、不安装 `authorized_keys`、专用账户、sudo 或 systemd，不渲染 sing-box/nftables，也不修改测试服务器。远程 forced command、最小权限 apply helper 和运行配置快照回退由后续独立 Issue 实现。

## 回退

协议模块没有现有运行时调用。撤销模块、测试和本文档并重新生成单脚本即可回退，不涉及 v4 状态、迁移包、用户、分流或服务器数据。
