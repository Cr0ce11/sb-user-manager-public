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
6. 对服务器相关变化执行 Debian 12 x86_64 专用测试机验收。
7. 创建草稿 Pull Request，记录风险、测试和恢复方式。
8. 项目所有者确认用户体验后才进入发布流程；正式环境或高风险操作还需单独明确授权。

`tools/build-manager.sh` 需要同时兼容开发机自带的 Bash 与 Debian 12。macOS 只负责构建和不依赖服务器的检查；脚本实际运行环境只支持 Debian 12 x86_64。

## 本地发布门禁

从仓库根目录运行：

```bash
bash -n sb-user-manager.sh tests/acceptance.sh tests/test-acceptance.sh tests/test-controller-state.sh tests/test-controller-role.sh tests/test-controller-role-repair.sh tests/test-controller-role-provision.sh tests/test-manager-role-detection.sh tests/test-manager-role-routing.sh tests/test-controller-landing-transport.sh tests/test-controller-landing-registration.sh tests/test-controller-landing-credentials.sh tests/test-controller-landing-onboarding.sh tests/test-controller-landing-onboarding-journal.sh tests/test-landing-apply-protocol.sh tests/test-landing-agent.sh tests/test-landing-channel-install.sh tests/test-landing-bootstrap.sh tests/test-landing-channel-e2e.sh tests/test-landing-startup-gate.sh tools/build-manager.sh tools/audit-public-readiness.sh tools/export-public-snapshot.sh tests/test-build.sh tests/test-public.sh tests/test-public-readiness.sh tests/test-public-snapshot.sh tests/test-release-workflow.sh
bash tools/build-manager.sh --check
bash tests/test-build.sh
bash tests/test-static.sh
bash tests/test-unit.sh
bash tests/test-controller-state.sh
bash tests/test-controller-role.sh
bash tests/test-controller-role-repair.sh
bash tests/test-controller-role-provision.sh
bash tests/test-manager-role-detection.sh
bash tests/test-manager-role-routing.sh
bash tests/test-controller-landing-credentials.sh
bash tests/test-controller-landing-onboarding.sh
bash tests/test-controller-landing-onboarding-journal.sh
bash tests/test-landing-apply-protocol.sh
bash tests/test-landing-agent.sh
bash tests/test-landing-channel-install.sh
bash tests/test-landing-bootstrap.sh
bash tests/test-landing-startup-gate.sh
bash tests/test-acceptance.sh
bash tests/test-public.sh
bash tests/test-public-readiness.sh
bash tests/test-public-snapshot.sh
bash tests/test-release-workflow.sh
```

`tools/export-public-snapshot.sh` 只允许从干净、已提交并通过公开策略审计的工作区导出新目录；它拒绝覆盖已有目录和包含符号链接的源码树。公开仓库的初始提交必须来自这个导出结果，不能复制 `.git` 或手工挑文件。

`tests/test-landing-channel-e2e.sh` 会创建并删除固定的本地系统账户、sudoers 和安装路径，并经临时真实 root SSH 执行一次性引导与精确回退，只能在 Linux root 的一次性隔离测试环境运行；CI 在 Ubuntu 24.04 与固定摘要、仅增加 `NET_ADMIN` 能力的 Debian 12 隔离容器中以 `SB_REQUIRE_LANDING_CHANNEL_E2E=true` 强制执行。Debian 容器的 PID 1 不是 systemd，测试只在确认一次性容器标记后临时安装严格的 `systemctl` 行为桩，并在退出时恢复原二进制；生产代码仍会在没有真实 systemd 时失败关闭。macOS 和有业务数据的服务器不得运行该 E2E。

`tests/test-landing-startup-gate.sh` 在普通本地环境验证渲染内容、helper 顺序和失败传播；没有 `systemd-analyze` 时只跳过单元图语法检查。CI 必须设置 `SB_REQUIRE_LANDING_STARTUP_SYSTEMD_VERIFY=true`，在 Ubuntu 24.04 和 Debian 12 都强制执行该离线检查。Ubuntu 24.04 还以 root 设置 `SB_REQUIRE_LANDING_STARTUP_SYSTEMD_RUNTIME=true`，在真实 systemd PID 1 下运行唯一命名、只链接到 `/run` 的合成单元，验证成功顺序与失败阻断；该测试不使用或修改本机真实 sing-box 和项目正式门禁。Debian 容器的 PID 1 不是 systemd，因此只执行离线 `systemd-analyze verify`。

`tests/test-controller-landing-onboarding-journal.sh` 只在临时目录中模拟控制器状态和远端调用，并真实终止一个测试子进程来验证日志可恢复性；它不登录服务器、不修改系统服务，也不发送网络请求。

安装了 ShellCheck 时还应运行 CI 中的对应检查。测试失败时不得通过修改测试期望来掩盖行为回归。

## 完成定义

一项代码变更只有在以下条件全部满足时才算完成：

- 产品行为和取消路径明确。
- 正常、异常和中断路径有测试。
- 数据格式变化具备兼容及回滚方案。
- README、CHANGELOG 或设计文档已按影响更新。
- 本地测试和 GitHub CI 通过。
- 涉及真实服务的变更已上传专用测试服务器验证。
- Pull Request 说明用户影响、技术风险和恢复办法。

纯文档和 GitHub 模板变更可以免除测试服务器部署，但仍需通过本地测试和 CI。

## AI 协作交接

聊天内容不是长期项目记录。AI 产品与技术负责人或 Codex 执行代理作出的重要决定必须写入以下至少一处：

- GitHub Issue：需求、验收标准和产品确认。
- `docs/DECISIONS/`：长期技术决策。
- Pull Request：实现、测试证据和风险。
- CHANGELOG：发布后用户可感知的变化。

各类信息的主要正式来源以 [`../PROJECT.md`](../PROJECT.md) 的“正式来源与文档职责”为准，开发流程不重复维护路线图、部署步骤或发布门禁。日常技术选择由 AI 主动决定；只有产品实质歧义和高风险边界才请求项目所有者。
