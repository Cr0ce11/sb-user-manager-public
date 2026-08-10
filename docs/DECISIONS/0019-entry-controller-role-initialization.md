# ADR 0019：入口控制器角色初始化与只读依赖门禁

- 状态：已接受，基础模块尚未接入运行流程
- 日期：2026-08-08
- 关联：[ADR 0005](0005-entry-authenticated-multi-egress-controller.md)、[ADR 0006](0006-controller-state-schema.md)、[Issue #226](https://github.com/DTB201/sb-user-manager/issues/226)

## 背景

入口侧已有独立控制器状态、固定身份传输、单落地凭据、root 引导和持久 onboarding 恢复核心，但这些模块都假定入口角色及系统依赖已经安全建立。直接调用 `init_controller_state` 只负责原子创建状态，不能判断当前机器是否属于支持平台、依赖是否可信，或是否会把已有单机部署静默转换成入口角色。

## 决定

新增 dormant 的 `controller_role_preflight` 与 `initialize_entry_controller_role`，作为未来入口角色安装流程的唯一底层门禁。本阶段不把它们连接到菜单、启动、更新或服务器。

只读预检要求：

- 真实运行必须是 root、Debian 12、Linux x86_64。
- `/usr/lib/os-release`、控制器状态、秘密和锁路径必须使用固定受信任位置。
- 入口侧需要的 OpenSSH 客户端、OpenSSL、Python 3、jq、flock、摘要和基础文件工具必须由当前 `PATH` 精确解析到 `/usr/bin`，最终可执行文件由 root 拥有且不能被组或其他用户写入；函数或其他目录中的同名命令不能通过门禁。
- 缺失和不可信依赖分别返回 `missing_dependency` 与 `unsafe_dependency`；详情只保存固定依赖名称，不输出路径内容、凭据或秘密。
- 预检只读取环境，不执行 apt，不创建目录、状态、锁或临时文件。

首次初始化只接受 v4 管理与核心文件足迹均为空的 `fresh` 机器，拒绝现有完整、部分或外部部署，避免 `standalone` 被静默转换。该分类只读文件足迹，不执行既有 sing-box 或 systemctl。检查全部通过后复用 ADR 0006 的 `init_controller_state`，并再次校验状态、秘密目录和锁文件。

若合法 `entry-controller` 状态已经存在，重复调用返回 `already_initialized`，不重写状态、不清空 landings、不降低 revision。`/run` 中易失的锁目录或锁文件重启后不存在不构成状态损坏，也不会在只读识别时重建；若它们存在则必须可信。非法状态、符号链接、宽权限或包含未知文件的局部残留返回 `state_invalid`，不覆盖现场；仅受信任且为空的初始化目录或受信任锁文件允许从安全中断点继续。

结果通过 `CONTROLLER_ROLE_LAST_STATUS` 和 `CONTROLLER_ROLE_LAST_DETAIL` 暴露给未来交互层。它们是进程内结果，不写入 schema，也不是面向远端的协议。

## 依赖修复边界

本决定不自动安装缺失软件。未来菜单可以把预检结果转成中文说明，并在用户明确选择“安装或修复入口环境”后复用受管 apt 事务；到期检查、恢复钩子等非交互内部任务不得触发安装。

## 不包含

- 不建立入口数据面、共享配额或用户线路。
- 不修改 v4 菜单、安装事务、状态 schema 或迁移格式。
- 不安装落地侧账户、sudo、systemd、nftables 或 sing-box 运行依赖。
- 不登录服务器，不把 dormant 模块视为可用的多落地产品。

## 回退

该模块没有运行时调用。撤销模块、测试和本文档并重新生成私有版与分享版单脚本即可回退，不需要修改服务器、控制器状态或 v4 数据。
