# ADR 0018：落地初始化持久日志与保守恢复

- 状态：已接受，恢复核心尚未接入角色路由、菜单或服务器
- 日期：2026-08-08
- 关联：[ADR 0015](0015-entry-initiated-landing-root-bootstrap.md)、[ADR 0016](0016-controller-landing-credential-initialization.md)、[ADR 0017](0017-controller-landing-onboarding-orchestration.md)、[Issue #224](https://github.com/DTB201/sb-user-manager/issues/224)

## 背景

ADR 0017 的进程内编排能处理普通失败，却不能跨越 `SIGKILL`、进程崩溃或断电。尤其是入口完成远端 root 引导后、把 bootstrap ID 返回给上层前，若进程被终止，入口会失去精确回退远端收据所需的标识。仅靠重新检查本地文件不能安全推断远端动作是否已经发生，也不能在登记提交结果不明时统一执行删除。

本决定在菜单启用前补齐这条数据安全边界。它不建立入口角色、不连接真实服务器，也不改变现有 v4 菜单和运行行为。

## 决定

### 先持久化身份，再修改任何一端

用户确认 SSH 主机指纹后，入口先生成操作 ID 和 bootstrap ID，并把完整目标事实以 schema 1 写入固定日志 `/var/lib/sb-user-manager/controller-onboarding.json`。初始 `credentials_pending` 必须在生成凭据、root 登录或控制器登记前完成持久化。root 引导函数接受调用方预先生成的 bootstrap ID，不再要求上层等远端动作结束后才取得它。

日志与控制器状态位于同一 root 专用目录，必须是 root 所有的普通文件且权限为 `0600`，大小不超过 8192 字节。写入只使用同目录固定 `.next`、文件同步、原子替换和目录同步；不信任符号链接、错误所有者、宽松权限、额外 JSON 字段、多个 JSON 值或不合法目标。完整 SNI 不进入命令行、普通输出或日志，只经环境传给 `jq` 并保存于该 root-only 恢复文件。

单独的 `/run/lock/sb-user-manager/controller-onboarding.lock` 覆盖一次完整初始化或恢复，避免两个进程同时解释同一日志；控制器状态仍使用自己的锁，两个锁使用不同文件描述符。

### 固定阶段图

日志只允许下列前进转换，且操作 ID、bootstrap ID、落地 ID、地址、端口、SNI、入口 IPv4、主机指纹和“凭据是否预先存在”在整个操作中不得漂移：

| 阶段 | 已获准或已完成的动作 |
|---|---|
| `credentials_pending` | 只获准创建本地凭据 |
| `bootstrap_pending` | 已持久化精确 bootstrap ID，root 引导可能尚未开始或已经发生 |
| `registration_pending` | 远端引导已确认成功，控制器登记可能尚未开始或已经提交 |
| `apply_pending` | 精确目标已登记，首次 apply 可能尚未开始或已经发生 |
| `local_aborted` | 没有获准的远端变更，只待收敛本次本地材料 |
| `remote_rolled_back` | 精确远端回退已确认，只待收敛本次本地材料 |
| `completed` | 登记和 apply 已确认，只待删除日志 |

阶段只能沿实现定义的有向边移动；不能跳阶段，也不能用新目标覆盖旧日志。终止阶段先写入日志，相关清理成功并同步后才删除日志，因此再次中断最多导致幂等重试，不会把已经回退的操作误判为仍需继续。

### 恢复必须证明方向

恢复先严格验证日志和当前控制器状态，再按阶段收敛：

- `credentials_pending` / `local_aborted`：只有能证明目标未登记时，才清理由本次新建的凭据；预先存在的材料保留。
- `bootstrap_pending`：只有能证明目标未登记时，才使用日志中的完整目标和同一个 bootstrap ID 精确回退；已登记、目标冲突或状态不可信时失败关闭。
- `registration_pending`：精确目标已登记则进入首次 apply；能证明未登记则精确回退；否则保留现场。
- `apply_pending`：只有精确目标仍已登记时才幂等重做 apply。
- `remote_rolled_back`：只有能证明未登记时才完成本地清理。
- `completed`：只有精确目标仍已登记时才删除日志，不重复 apply。

恢复不根据“文件看起来存在”猜测远端事实，不回退不同 bootstrap ID，不删除已登记或归属不明的凭据。远端回退、状态验证、apply、日志推进或清理任一步失败时，日志和恢复材料继续保留。

## 验证

定向测试覆盖权限、严格 schema、阶段跳跃、目标漂移、残留 `.next`、符号链接、损坏日志、登记三态和全部恢复阶段。测试还在写入 `bootstrap_pending` 后真实发送 `SIGKILL`，确认新进程能读取同一个 ID 并只执行精确回退。调用方指定 bootstrap ID 的传播另由 root 引导测试覆盖。

## 暂不包含

本决定不把恢复入口接到启动流程或菜单，不自动创建入口角色，不准备远端依赖，不改变数据面，不执行真实 SSH，也不提供批量恢复。交互层启用初始化前，必须先提供明确的“存在待恢复操作”提示和恢复入口；不得在后台静默登录 root 或自动选择破坏性方向。

## 回退

在能力保持 dormant 且不存在服务器日志时，可以撤销日志模块、编排改动、测试和本文档并重新生成单脚本。未来若已经启用且日志存在，必须先按原版本完成恢复或人工核对入口状态与精确 bootstrap 收据；不得通过删除日志或降级代码代替收敛远端事实。
