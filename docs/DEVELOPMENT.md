# 开发流程

## 分支和提交

- `main` 始终保持可发布。
- 所有变更使用独立分支和 Pull Request。
- Codex 创建的分支使用 `agent/<简短说明>`。
- 一个 Pull Request 只解决一个明确主题。
- 不把服务器快照、令牌、密码、用户数据或本地导出的公开快照提交到仓库。

## 开发步骤

1. AI 产品与技术负责人从 Issue 或确认过的任务单提取产品行为、风险和验收标准。
2. 检查受影响的状态、迁移、回滚和兼容路径。
3. 只修改 `src/` 中的源码模块，不直接编辑生成物 `sb-user-manager.sh`；模块顺序只通过 `src/modules.list` 管理。
4. 运行 `bash tools/build-manager.sh` 重新生成单脚本，同时更新相应测试和文档。
5. 在本地运行发布门禁。
6. 对服务器相关变化在 Debian 12 x86_64 测试机执行适用的验收模式；当前使用开发机上的本地 OrbStack 测试机，其已验证能力与未覆盖项见 [公开 Issue #139](https://github.com/Cr0ce11/sb-user-manager-public/issues/139)。
7. 创建草稿 Pull Request，记录风险、测试和恢复方式。
8. 项目所有者确认用户体验后才进入发布流程；正式环境或高风险操作还需单独明确授权。

`tools/build-manager.sh` 需要同时兼容开发机自带的 Bash 与 Debian 12。macOS 只负责构建和不依赖服务器的检查；脚本实际运行环境只支持 Debian 12 x86_64。

## 本地发布门禁

**门禁的权威运行环境是 Linux 上的 Bash 5，不是开发机。** 测试大量使用裸
`[[ ... ]]` 作为断言，靠 Bash 因它求值为假而中止脚本来变红；开发机 macOS 自带的
Bash 3.2 不会中止，那里这类断言全部空转，门禁照常打印通过（[公开 Issue #167](https://github.com/Cr0ce11/sb-user-manager-public/issues/167)）。
每个门禁脚本开头都 source `tests/require-strict-errexit.sh`，当场探一次当前解释器
是否具备该行为，不具备就拒绝运行并提示改到门禁机——不会再跑出一个不可信的绿。

开发机上的门禁机是 OrbStack 的 `sbm-gate`（Debian 12，Bash 5.2），仓库通过
`/Users/...` 直接可见。从仓库根目录运行：

```bash
orb -m sbm-gate bash tests/test-static.sh
```

完整门禁清单（逐条在门禁机上运行）：

```bash
bash -n sb-user-manager.sh tests/acceptance.sh tests/require-strict-errexit.sh tests/check-managed-step-errexit.sh tests/check-bare-negation.sh tests/test-acceptance.sh tests/test-standalone-startup.sh tests/test-manager-handoff.sh tools/build-manager.sh tools/audit-public-readiness.sh tools/export-public-snapshot.sh tools/check-immutable-release-setting.sh tests/test-build.sh tests/test-public.sh tests/test-public-readiness.sh tests/test-public-snapshot.sh tests/test-release-workflow.sh
bash tools/build-manager.sh --check
bash tests/test-build.sh
bash tests/test-static.sh
bash tests/test-unit.sh
bash tests/test-standalone-startup.sh
bash tests/test-manager-handoff.sh
bash tests/test-acceptance.sh
bash tests/test-public.sh
bash tests/test-public-readiness.sh
bash tests/test-public-snapshot.sh
bash tests/test-release-workflow.sh
```

`tools/export-public-snapshot.sh` 只允许从干净、已提交并通过公开策略审计的工作区导出新目录；它拒绝覆盖已有目录和包含符号链接的源码树。公开仓库的初始提交必须来自这个导出结果，不能复制 `.git` 或手工挑文件。

GitHub 分支保护要求 `validate`、`jq16-compat` 和 `debian-standalone-e2e`。Debian 检查只运行固定 Debian 12 容器中的 standalone 启动、旧私有版接管和公开就绪验证，不申请 `NET_ADMIN`、创建 SSH 账户或运行任何已退役的 v5 落地测试。

门禁机没有装 ShellCheck，上面这份清单里不含它；跑完门禁后要在开发机补跑 CI 中的
两条 ShellCheck 检查。测试失败时不得通过修改测试期望来掩盖行为回归。

## 代码约定门禁

同一种写法一旦在某处确立，兄弟调用点必须跟上。`tests/test-static.sh` 和
`tests/check-shell-call-targets.py` 把下列约定变成机器检查，改动前先看这里，
不要在新代码里重新发明写法：

- 可取消的提示函数（`ui_menu_select`、`read_menu_choice`、`read_numbered_index`、
  `read_validated_value`、`prompt_migration_choice`）返回非零表示用户取消或输入结束，
  调用点必须检查返回值，不能用分号接着读全局结果。
- `if ... fi` 没有 `else` 分支时退出码恒为 0，失败码只能像 `run_step_or_rollback`
  那样写在 `else rc=$?` 里。
- 涉密内容只能通过环境变量或管道传给外部命令，不能作为命令行参数暴露给同机其他进程。
- 用户在提示里输入的十进制数字先用 `$((10#$value))` 归一再参与运算，
  否则 `08` 会被当成八进制。
- 需要已部署环境的交互入口先调用 `ensure_management_environment_ready` 护栏。
- 保留现有部署的流程（`deploy_environment false`）必须先判断 sing-box 通道，
  不得把测试通道静默替换成正式版。
- 测试断言不得写成独立成句的 `! cmd`。Bash 手册规定命令返回值被 `!` 取反时
  `set -e` 不会因它失败而退出，这类断言命中缺陷也不会让测试变红。改用
  `if cmd; then echo '说明为什么这是错的' >&2; exit 1; fi`。条件上下文中的 `!`
  （`if ! cmd`、`while ! cmd`、`[[ ! -f x ]]` 等）是合法的，门禁会放行。
- 管理器自身的数据（用户资料、内部备份、AnyTLS 证书）只能经 `MANAGER_DATA_DIR`
  派生的变量取得，不得在 `src/` 里写死 `/etc/sing-box` 下的路径。写死一处，
  将来把这些数据搬出 sing-box 目录时就会漏掉一处，而漏掉的那处指向用户数据。
  sing-box 自己的 `config.json` 不受这条约束——那是内核的文件，不是管理器的。
- 适配层（`src/05-kernel.sh`）里提到某个内核的函数必须同时提到另一个内核；
  尚未实现的操作也要写出该内核的分支并在其中明确报错，不得回落到另一个内核。
- 门禁测试脚本（`tests/test-*.sh`）必须在 `set -Eeuo pipefail` 之后立刻
  source `tests/require-strict-errexit.sh`。裸 `[[ ]]` 断言只在会因它中止的
  Bash 上才有效，漏掉这一行的脚本在开发机上会跑出不可信的通过。
  `tests/acceptance.sh` 不在此列：它在 Debian 测试机上运行、可能被单独复制过去，
  不应依赖同目录下的另一个文件。
- 可选文本字段（`outbound_preset`、`rule_preset` 以及三个 `runtime_*_tag`）
  在本项目里「空字符串」和「字段不存在」是同一个意思，判空一律写
  `(.field // "") == ""`。`(.field // null)` 对空字符串求值仍是空字符串，
  会把已保存的空值判成有值。

## 完成定义

一项代码变更只有在以下条件全部满足时才算完成：

- 产品行为和取消路径明确。
- 正常、异常和中断路径有测试。
- 数据格式变化具备兼容及回滚方案。
- README、CHANGELOG 或设计文档已按影响更新。
- 本地测试和 GitHub CI 通过。
- 涉及真实服务的变更已在 Debian 12 x86_64 测试机验证。
- Pull Request 说明用户影响、技术风险和恢复办法。

纯文档和 GitHub 模板变更可以免除测试机部署，但仍需通过本地测试和 CI。

## AI 协作交接

聊天内容不是长期项目记录。AI 产品与技术负责人或 Codex 执行代理作出的重要决定必须写入以下至少一处：

- GitHub Issue：需求、验收标准和产品确认。
- `docs/DECISIONS/`：长期技术决策。
- Pull Request：实现、测试证据和风险。
- CHANGELOG：发布后用户可感知的变化。

各类信息的主要正式来源以 [`../PROJECT.md`](../PROJECT.md) 的“正式来源与文档职责”为准，开发流程不重复维护路线图、部署步骤或发布门禁。日常技术选择由 AI 主动决定；只有产品实质歧义和高风险边界才请求项目所有者。
