# ADR 0027：readiness 门禁后的单落地初始化

- 状态：已接受并实现，保持 dormant
- 日期：2026-08-09
- 关联：[ADR 0017](0017-controller-landing-onboarding-orchestration.md)、[ADR 0018](0018-controller-landing-onboarding-durable-journal.md)、[ADR 0026](0026-unified-pre-secret-landing-readiness-gate.md)、[Issue #245](https://github.com/DTB201/sb-user-manager/issues/245)

## 背景

ADR 0026 已把落地系统依赖和官方 sing-box 准备收束为一次人工主机指纹确认、两个独立远程阶段和严格短路的 readiness 门禁；ADR 0017/0018 已提供从凭据生成开始的持久 onboarding 与恢复。两者此前保持分离，未来菜单若自行串联会留下两个风险：准备失败后仍可能误入秘密阶段，或者 readiness 已确认主机后 onboarding 再次扫描并要求用户重复确认。

系统包安装和 sing-box 准备不具备与项目状态相同的事务回退能力，因此不能把它们写入从 `credentials_pending` 开始的持久 onboarding 日志。但只有这两项都通过，才允许生成每落地秘密或修改入口与远端项目状态。

## 决定

新增保持 dormant 的统一入口 `controller_prepare_and_onboard_landing(...)`。未来交互层只能使用这个入口新增落地；既有 `controller_onboard_landing(...)` 继续作为低层编排和定向恢复测试边界，不直接接菜单。

统一入口持有既有 onboarding 锁，并按以下顺序执行：

1. 在任何网络访问前检查全部输入、可信 `entry-controller` 状态、重复落地 ID 与重复“地址 + SSH 端口”。
2. 调用 ADR 0026 readiness 门禁。用户拒绝、依赖失败、sing-box 失败、本地清理失败或不完整成功结果均立即停止。
3. 只在 readiness 返回 `ready` 且携带格式正确的已确认 Ed25519 指纹时，把该值作为当前调用栈内参数交给低层 onboarding。
4. 低层 onboarding 再次执行本地预检和待恢复日志检查，但跳过第二次指纹发现与人工提示；root 引导、登记和首次 apply 的每次 SSH 连接仍按各自既有门禁重新扫描，并且只能接受同一已确认指纹。
5. 从写入 `credentials_pending` 开始，继续完全复用 ADR 0017/0018 的凭据归属、远端回退、登记不确定、待同步和持久恢复语义。

统一入口公开顶层 onboarding 阶段，以及 readiness 顶层阶段、依赖状态和 sing-box 状态。完整主机指纹只在当前调用栈内使用；无论成功、失败或取消，统一入口返回前都清除 readiness 与 onboarding 的完整指纹结果。地址、密码、私钥、完整 SNI 和客户端配置同样不进入普通结果。

## 失败与并发边界

- 本地预检失败时不调用 readiness。
- readiness 失败或用户取消时不创建 onboarding 日志、每落地秘密、受限账户、bootstrap 收据、控制器登记或 apply 包。
- readiness 返回成功但阶段或指纹结果不完整时按不可信结果拒绝，不能猜测或重新发现。
- readiness 之后若远端主机身份变化，既有依赖、sing-box、bootstrap、登记或 apply 连接中的固定身份检查会失败关闭。
- readiness 成功只说明远端共享依赖已经幂等就绪，不表示后续持久 onboarding 已成功，也不把 APT 或全局 sing-box 纳入项目回退事务。
- 同一把 onboarding 锁覆盖准备与持久编排，避免两个本地新增操作在 readiness 与日志写入之间交错；外部手工改动仍由重复预检、主机身份固定和原子状态门禁拒绝。

## 暂不包含

本决定不接入口菜单、角色安装、批量同步或启动流程，不开放入口数据面、普通用户、共享配额和分流，也不连接真实服务器。Issue #199 后续的多用户、多出口与外部 AnyTLS 兼容 POC 仍需独立验收。

## 验证与回退

定向测试覆盖参数注入拒绝、本地预检先于网络、readiness 失败和取消零持久修改、不完整成功结果拒绝、成功后不重复发现或确认指纹、低层 onboarding 失败语义保持，以及统一入口返回后不保留完整指纹。既有 readiness 测试继续证明依赖失败不会进入 sing-box、两个远程阶段分别重新固定同一主机身份并清理隔离工作目录。静态门禁证明统一入口仍未接角色路由、菜单或安装流程。

回退只需撤销统一入口、测试和本文档并重新生成单脚本。既有 readiness 与低层 onboarding 能力保持不变；已经在未来测试环境中幂等准备的 Debian 官方依赖或官方 sing-box 按 ADR 0024/0025 保留，禁止为了代码回退盲目卸载或删除。
