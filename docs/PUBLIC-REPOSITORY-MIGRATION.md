# 单一公开仓库迁移记录

本文记录 `sb-user-manager` 从原私有双版本仓库收敛到单一公开仓库的边界。长期决定见 [ADR 0028](DECISIONS/0028-clean-public-repository-transition.md) 与取代它的 [ADR 0029](DECISIONS/0029-single-public-repository.md)。

## 最终结果（2026-08-13）

- `DTB201/sb-user-manager-public` 由经过审计的干净历史建立，采用 MIT License；当前正式版为不可变 [v4.25.2 Release](https://github.com/DTB201/sb-user-manager-public/releases/tag/v4.25.2)。
- 公开仓库独立承担源码、Issue、Pull Request、确定性构建、完整 CI、匿名在线更新、私密安全报告和不可变 Release。
- `main` 要求 Pull Request、`validate`、`jq16-compat`、`debian-landing-e2e`、对话解决和线性历史，禁止强推、删除及管理员绕过。
- 原私有版和分享版停止发布，原私有仓库永久退役；公开仓库保持现名，避免破坏现有公开客户端更新地址。
- 旧私有版配置中的 `GITHUB_TOKEN` 只为迁移兼容而接受并立即丢弃，不载入进程、不发送到网络、不写回配置。
- 仍运行旧私有版的服务器可以使用同版本或更高版本的公开 Release 执行 `--take-over-installed-manager`。接管只替换管理脚本与版本记录，不修改用户、流量、配额、有效期、证书、分流、sing-box 或 Nfuse，也不会启停服务。
- 原 v5 方向永久终止；已经进入公开 v4.25.2 的休眠基础由 [公开 Issue #17](https://github.com/DTB201/sb-user-manager-public/issues/17) 独立清理。

## 初次公开审计基线

原私有仓库在 2026-08-10 的基线提交为 `020031ad3939b35eb06a30f6153af3e9f1c149a4`。当时完成了以下只读检查：

- 扫描全部本地可达引用，共 393 个提交和 2,330 个 Git 对象。
- 未发现常见私钥头、GitHub、AWS、Google、Slack、Stripe、OpenAI 令牌格式或带账号密码的 URL。
- 未发现 `.env`、SSH 私钥、证书私钥、密码库或迁移备份等敏感文件曾进入可达历史。
- 单独核对已知测试服务器地址和曾用于测试的凭据，当前树与可达历史均未命中。
- 提交作者邮箱均为 GitHub `noreply` 地址。

这些结果只能证明已检查的特征没有命中，不能证明代码绝对不存在业务秘密。最终公开树另由 `tools/audit-public-readiness.sh --check-public-tree` 执行历史与策略审计。

## 为什么使用干净公开历史

原私有仓库曾包含 GitHub Token 更新路径、私有/分享双版本生成器、未发布 v5 分支，以及大量未经逐项公开审计的协作记录。直接改变其可见性会一次性公开全部可达历史，并允许外部永久保存副本。

因此公开仓库只包含审计后的正式源码树和后续公开提交，不包含私有 Token 更新分支、双版本构建器、服务器验收数据、旧聊天材料、内部快照或未发布实验分支。旧标签、Issue、PR、Actions 日志和私有 Release 没有复制；公开不可变 Release 历史从 v4.23.1 开始。

## 删除私有仓库前的门禁

1. 公开 Issues 与 Private Vulnerability Reporting 已启用。
2. 原私有仓库唯一仍有产品价值的 Mihomo 候选需求已迁为 [公开 Issue #16](https://github.com/DTB201/sb-user-manager-public/issues/16)。
3. 私有双版本与 v5 开放事项不迁移；休眠 v5 代码清理由公开 Issue 独立跟踪。
4. 已用真实旧私有 v4.18.1、v4.22.1、v4.23.0 脚本在隔离目录接管到公开 v4.25.2，三组数据摘要均保持不变。
5. 公开仓库完整本地门禁、Pull Request CI 与合并后 `main` CI 必须通过。
6. 删除前保存最终只读恢复材料、SHA-256、引用清单和仓库设置记录；不得把服务器秘密或访问凭据写入归档。
7. 删除后重新核对公开仓库可访问、Issue 可创建、`main` 保护有效、最新 Release 可匿名下载且更新源只指向公开仓库。

## 旧私有版接管

从公开不可变 Release 下载脚本和 SHA-256，独立校验后，以 root 执行：

```bash
chmod 700 sb-user-manager.sh
./sb-user-manager.sh --take-over-installed-manager
```

目标版本必须等于或高于已安装版本，并支持当前数据 schema。接管事务会保留原脚本与版本记录，写入或最终核验失败立即恢复；中途断电时，下次目标脚本启动会先恢复再进入其他功能。项目不再提供从公开版切回私有版的发布渠道。

## 公开仓库持续门禁

常规完整历史扫描：

```bash
bash tools/audit-public-readiness.sh
```

公开源码树策略检查：

```bash
bash tools/audit-public-readiness.sh --check-public-tree
```

额外精确值必须放在仓库外的临时普通文件中，通过 `--extra-pattern-file` 输入；审计后立即删除。审计输出只报告命中文件路径，不回显秘密。

## 回退

公开仓库、名称和 Release 不因私有仓库退役而回退。删除后若发现遗漏，只在 GitHub 允许的恢复期限内恢复原私有仓库；恢复不重新启动双版本或 v5 开发。旧服务器接管失败时使用接管事务保存的原脚本和版本记录恢复，业务数据保持不变。
