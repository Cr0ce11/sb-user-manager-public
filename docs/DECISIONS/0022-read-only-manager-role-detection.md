# ADR 0022：只读管理器角色识别

- 状态：已接受，识别模块尚未接入运行流程
- 日期：2026-08-08
- 关联：[ADR 0005](0005-entry-authenticated-multi-egress-controller.md)、[ADR 0019](0019-entry-controller-role-initialization.md)、[ADR 0021](0021-entry-controller-role-provisioning.md)、[Issue #232](https://github.com/DTB201/sb-user-manager/issues/232)

## 背景

未来启动界面需要在 standalone、entry-controller 和 landing 之间自动分发，也要在全新机器提供一次角色选择。若菜单层分别检查某个配置文件是否存在，很容易把部分部署、外部 sing-box、非法角色标记或两种角色混装误认为可用环境。角色判断必须先收束为一个只读、失败关闭的底层入口。

## 决定

新增 dormant 的 `detect_manager_role`，只接受零参数。成功时 `MANAGER_ROLE` 只可能是 `undeployed`、`standalone`、`entry-controller` 或 `landing`，状态固定为 `role_detected`。失败时角色保持 `unknown`，详情只包含固定分类，不输出路径、地址、用户数据或秘密。

识别顺序固定为：

1. 验证 root、控制器和落地固定路径；真实运行固定 `PATH`、区域设置，并清空会影响解析器的继承环境。
2. 同时检查控制器状态标记、落地 identity 标记和落地专用文件足迹。控制器标记与落地标记或足迹并存时返回 `role_conflict/mixed_role_markers`，不调用任一内容解析器。
3. 单独存在控制器标记时，完整验证控制器状态、秘密目录和可选锁文件；成功才识别为 `entry-controller`。
4. 单独存在落地标记时，先排除不安全的控制器残留，再复用落地 identity 的权限、schema、密钥指纹和绑定 generation 校验；成功才识别为 `landing`。
5. 没有身份标记但存在落地专用文件时返回 `environment_incomplete/landing`；存在不安全控制器残留时返回 `role_invalid/controller_artifacts`。
6. 最后只按既有文件足迹区分全新环境、完整 standalone、standalone 部分部署和外部环境。只有前两者成功；部分部署和外部环境不得冒充全新机器。

完整 standalone 的识别只读取文件足迹，不执行其 sing-box、Nfuse、管理脚本或 systemd。合法 entry-controller 和 landing 的身份标记可以在对应运行环境暂时损坏时仍指明事实源，但标记本身必须可完整验证；缺少验证依赖时失败关闭，不根据文件名猜测。

## 落地残留范围

无 identity 时，以下任一落地专用对象存在都视为未完成或损坏的落地环境：专用账户 home、generation、SSH 目录和 authorized_keys、forced agent、runtime、apply helper、sudoers、通道锁、事务目录、启动恢复 unit 与 drop-in。通用 sing-box 文件不单独证明 landing 身份。

## 不包含

- 不接入 main、菜单、安装、更新、定时任务或恢复钩子。
- 不创建、修复、删除或迁移任何角色文件。
- 不执行服务检查、网络访问、APT 或远程 SSH。
- 不把 CI 中的文件模型等同于真实服务器的启动、重启和故障恢复验收。

## 回退

在接入启动分发前，删除该模块和测试、从 `modules.list` 移除条目并重新生成单脚本即可回退，不需要修改服务器或数据。
