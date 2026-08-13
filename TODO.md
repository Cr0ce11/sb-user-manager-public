# 项目待办

本文件是路线图的可执行清单。每个进入实施的事项必须建立 GitHub Issue；状态变化通过 Pull Request 更新，不能只在聊天中标记完成。

状态说明：`进行中`、`待办`、`暂缓`、`阻塞`、`完成`。完成项在对应 Release 或治理 PR 合并后移入 CHANGELOG 或关闭 Issue，不长期堆积在本文件。

| 编号 | 优先级 | 状态 | 正式记录 | 事项 | 完成条件 |
|---|---|---|---|---|---|
| GOV-001 | — | 完成 | [Issue #46](https://github.com/DTB201/sb-user-manager/issues/46) | 建立项目治理基线 | 项目状态、路线图、待办、部署和职责文档合并，CI 通过 |
| QA-000 | — | 完成 | [Issue #48](https://github.com/DTB201/sb-user-manager/issues/48) | v4.17.0 测试服务器 `audit` 基线验收 | 版本、服务、配置、Nfuse、定时器、事务状态和数据一致性全部通过 |
| SEC-001 | P1 | 暂缓 | 项目所有者决定 | 治理测试服务器访问凭据 | 当前不执行；如未来恢复此项，先确认不会锁死的访问和回退方式 |
| REL-001 | — | 完成 | [Issue #63](https://github.com/DTB201/sb-user-manager/issues/63) | 验证正式版菜单更新路径 | 隔离测试服务器从 v4.16.0 通过菜单更新到 v4.17.0，取消路径、数据保持、版本、服务、一致性和 `audit` 全部通过 |
| QA-001 | — | 完成 | [Issue #51](https://github.com/DTB201/sb-user-manager/issues/51)、[Issue #52](https://github.com/DTB201/sb-user-manager/issues/52) | 完成功能生命周期验收 | 用户与分流生命周期均通过，测试对象清理后原有数据恢复基线，最终 `audit` 通过 |
| BAK-001 | — | 完成 | [Issue #56](https://github.com/DTB201/sb-user-manager/issues/56) | 演练迁移备份与恢复 | 迁移包可在服务器外保存、校验、解密并恢复，失败时能够回到操作前状态 |
| BAK-002 | P1 | 完成 | [Issue #133](https://github.com/DTB201/sb-user-manager/issues/133)、[PR #134](https://github.com/DTB201/sb-user-manager/pull/134) | 管理备份保留数量并显示磁盘占用 | v4.21.0 已正式发布；迁移包不被后台删除，内部备份、完整快照和恢复记录安全限量，活动恢复点与异常文件受保护，本地、CI、Debian 隔离测试、nube2 真实整理和发布后验收全部通过 |
| BAK-003 | P2 | 完成 | [Issue #135](https://github.com/DTB201/sb-user-manager/issues/135)、[PR #137](https://github.com/DTB201/sb-user-manager/pull/137) | 首次升级后立即整理旧完整快照 | v4.21.1 已正式发布；候选版 6 份有效快照首次启动立即整理为 5 份，真实菜单从 v4.21.0 更新后保留 5 份且记录完成状态，第二次启动不重复扫描，数据、服务和异常文件保护不变，`release` 验收失败项为 0 |
| OPS-002 | P1 | 完成 | [Issue #140](https://github.com/DTB201/sb-user-manager/issues/140)、[PR #141](https://github.com/DTB201/sb-user-manager/pull/141) | 增加安全的完整卸载能力 | v4.22.0 已正式发布；本地取消、失败回滚和中断恢复测试通过，nube2 已真实验证保留 `.sbm`、删除部署与内部回滚材料、空白重装、完整恢复、真实菜单更新和发布后 `release` 验收，失败项为 0 |
| QA-003 | — | 完成 | [Issue #59](https://github.com/DTB201/sb-user-manager/issues/59) | 验收报告默认隐藏服务器主机名 | `audit`、`lifecycle` 和 `full` 新报告保留兼容字段但不写入原始主机名，测试和 CI 通过 |
| OPS-001 | — | 完成 | [Issue #68](https://github.com/DTB201/sb-user-manager/issues/68) | 编写首次正式上线检查单 | 包含部署前、部署中、部署后、观察和回退检查项，不包含地址或凭据 |
| QA-002 | P1 | 完成 | [Issue #76](https://github.com/DTB201/sb-user-manager/issues/76) | 增加只读发布验收模式 | 复用 audit 并自动核对精确 Release、已安装脚本、最新快照完整性与权限，生成统一脱敏报告 |
| PROD-001 | — | 完成 | [Issue #96](https://github.com/DTB201/sb-user-manager/issues/96) | 首次正式环境上线 | v4.18.1 完成固定 Release 部署、真实客户端验收、30 分钟与 24 小时观察，最终 `release` 验收失败项为 0 |
| QA-004 | — | 完成 | [Issue #94](https://github.com/DTB201/sb-user-manager/issues/94) | 评估阶段 1 退出条件 | 适用验收和失败恢复证据齐全，没有未解决 P0/P1；项目进入阶段 2 准备状态但未获部署授权 |
| SUP-001 | P2 | 完成 | [Issue #126](https://github.com/DTB201/sb-user-manager/issues/126)、[PR #127](https://github.com/DTB201/sb-user-manager/pull/127) | 启用不可变 Release 并禁止覆盖同版本附件 | 草稿上传、四附件摘要校验、失败清理和正式发布顺序受自动检查保护；仓库设置已读回确认为启用，下一正式版继续执行端到端发布验收 |
| GOV-002 | P1 | 完成 | [Issue #250](https://github.com/DTB201/sb-user-manager/issues/250) | 建立受保护公开仓库的审计与迁移门禁 | 历史审计、公开树策略、许可证、Actions 安全、迁移与回退记录均已建立；受保护公开仓库已由干净快照创建并通过公开 CI |
| GOV-003 | P1 | 完成 | [Issue #252](https://github.com/DTB201/sb-user-manager/issues/252) | 生成单一公开版源码快照并验证匿名更新 | v4.23.1 已完成首个公开快照和匿名 Release，旧 Token 只兼容解析后丢弃；后续公开版本已按同一模型发布到 v4.25.6 |
| GOV-004 | P1 | 完成 | [公开 PR #14](https://github.com/DTB201/sb-user-manager-public/pull/14) | 对齐公开 v4.25.2 项目状态 | 长期状态文档与 v4.25.2、公开 CI 和 Release 事实一致，不改变运行代码或服务器 |
| GOV-005 | P1 | 完成 | [公开 Issue #15](https://github.com/DTB201/sb-user-manager-public/issues/15)、[公开 PR #18](https://github.com/DTB201/sb-user-manager-public/pull/18) | 收敛为单一公开仓库并退役私有仓库 | 公开 Issues、安全报告、治理记录、CI、Release、旧私有版单向接管和删除后验证全部通过 |
| MAINT-001 | — | 完成 | [Issue #110](https://github.com/DTB201/sb-user-manager/issues/110)、[PR #111](https://github.com/DTB201/sb-user-manager/pull/111) | 机械模块化源码并确定性生成单脚本 | 模块源码、固定清单、确定性构建和 CI 校验通过；生成的 v4.20.1 与改造前逐字节相同，Debian 实机只读验收通过 |
| MAINT-002 | P2 | 完成 | [Issue #113](https://github.com/DTB201/sb-user-manager/issues/113)、[PR #114](https://github.com/DTB201/sb-user-manager/pull/114) | 合并两种协议新增用户的共用执行流程 | 菜单、文案、事务顺序和服务器行为不变；计量与自用 Nfuse 登记共用实现并有确定性测试，本地与 CI 门禁通过 |
| MAINT-003 | P2 | 完成 | [Issue #115](https://github.com/DTB201/sb-user-manager/issues/115)、[PR #116](https://github.com/DTB201/sb-user-manager/pull/116) | 统一两种协议新增用户的前置冲突检查 | 两种协议共用用户名、端口、标签、证书和 Nfuse 冲突检查；原检查顺序、错误提示和服务器行为不变，本地、CI 与 Debian 实机验收通过 |
| MAINT-004 | P2 | 完成 | [Issue #117](https://github.com/DTB201/sb-user-manager/issues/117)、[PR #118](https://github.com/DTB201/sb-user-manager/pull/118) | 统一用户状态变化后的专属分流重建判断 | 停用、启用和到期处理共用同一判断；原事务顺序、错误传播和服务器行为不变，本地、CI 与 Debian 实机验收通过 |
| MAINT-005 | P2 | 完成 | [Issue #119](https://github.com/DTB201/sb-user-manager/issues/119)、[PR #120](https://github.com/DTB201/sb-user-manager/pull/120) | 统一分流事务的配置重建与提交收尾 | 相关分流操作共用重建、检查重启和提交顺序；原校验、状态修改、锁处理和服务器行为不变，本地、CI 与 Debian 实机验收通过 |
| MAINT-006 | P2 | 完成 | [Issue #121](https://github.com/DTB201/sb-user-manager/issues/121)、[PR #122](https://github.com/DTB201/sb-user-manager/pull/122) | 统一迁移预览与恢复的数据准备流程 | 预览与真实恢复共用解密、旧格式升级、完整校验和恢复计划准备链；原加密、格式、取消、清理和回滚行为不变，本地、CI 与 Debian 实机验收通过 |
| MAINT-007 | P2 | 完成 | [公开 Issue #17](https://github.com/DTB201/sb-user-manager-public/issues/17) | 移除从未开放的休眠 v5 基础 | 分阶段恢复唯一 standalone 启动链并删除不可达源码、专属测试、POC 和 ADR；v4 菜单、状态、迁移、接管和服务器可见行为不变 |
| MAINT-008 | P3 | 完成 | [公开 Issue #42](https://github.com/DTB201/sb-user-manager-public/issues/42)、[公开 PR #43](https://github.com/DTB201/sb-user-manager-public/pull/43) | 收紧临时路径登记并移除过时配置语法校验 | 成功原子替换立即注销临时路径，长会话计数不增长；备份管理配置仍由文件属性检查和白名单解析拒绝不安全内容，生成物、本地门禁与公开 CI 通过 |
| MAINT-009 | P3 | 进行中 | [公开 Issue #60](https://github.com/DTB201/sb-user-manager-public/issues/60) | 加固调度器命令目标门禁与更新锁语义 | 待完成调度器字面量目标检查、嵌套包装器检查、回滚回调运行期守卫和更新锁注释；不改变锁实现、运行配置或服务器行为 |
| REL-002 | P1 | 完成 | [Issue #123](https://github.com/DTB201/sb-user-manager/issues/123)、[PR #124](https://github.com/DTB201/sb-user-manager/pull/124) | 发布 v4.20.2 模块化维护版本 | 版本、迭代记录和标签一致；本地门禁、GitHub CI、四个 Release 附件、nube2 真实菜单更新及发布后 `release` 验收全部通过 |
| REL-003 | P1 | 完成 | [Issue #194](https://github.com/DTB201/sb-user-manager/issues/194)、[PR #195](https://github.com/DTB201/sb-user-manager/pull/195) | 准备并发布 v4.22.9 数据安全与可靠性修复版本 | 版本、迭代记录和长期状态文档一致；本地门禁、GitHub CI、标签 CI、四个 Release 附件独立复核和不可变保护全部通过；未登录或修改服务器 |
| REL-004 | P1 | 完成 | [Issue #242](https://github.com/DTB201/sb-user-manager/issues/242)、[PR #243](https://github.com/DTB201/sb-user-manager/pull/243) | 准备并发布 v4.23.0 休眠态 v5 安全基础版本 | 版本、迭代记录和长期状态文档一致；本地门禁、PR、main 与标签 CI、四个 Release 附件摘要和不可变保护全部通过；未登录或修改服务器 |
| REL-005 | P1 | 完成 | [公开 Issue #22](https://github.com/DTB201/sb-user-manager-public/issues/22)、[公开 PR #23](https://github.com/DTB201/sb-user-manager-public/pull/23) | 准备并发布 v4.25.3 续期修复版本 | 版本、迭代记录、本地门禁、PR、main 与标签 CI、两个 Release 附件摘要和不可变保护全部通过；未登录或修改服务器 |
| REL-006 | P1 | 完成 | [公开 Issue #28](https://github.com/DTB201/sb-user-manager-public/issues/28)、[公开 PR #29](https://github.com/DTB201/sb-user-manager-public/pull/29) | 准备并发布 v4.25.4 纯 v4 维护版本 | 版本、生成物、本地门禁、PR、main 与标签 CI、两个 Release 附件摘要和不可变保护全部通过；未登录或修改服务器 |
| REL-007 | P1 | 完成 | [公开 Issue #33](https://github.com/DTB201/sb-user-manager-public/issues/33)、[公开 PR #34](https://github.com/DTB201/sb-user-manager-public/pull/34) | 准备并发布 v4.25.5 用户有效期调整版本 | 版本、生成物、本地门禁、PR、main 与标签 CI、两个 Release 附件摘要和不可变保护全部通过；未登录或修改服务器 |
| REL-008 | P1 | 完成 | [公开 Issue #57](https://github.com/DTB201/sb-user-manager-public/issues/57)、[公开 PR #58](https://github.com/DTB201/sb-user-manager-public/pull/58) | 准备并发布 v4.25.6 代码审计修复版本 | 版本、生成物、本地门禁、PR、main、发布保护预检、标签 CI、两个 Release 附件摘要、标签源码一致性和不可变保护全部通过；未登录或修改服务器 |
| UX-004 | P2 | 完成 | [公开 Issue #31](https://github.com/DTB201/sb-user-manager-public/issues/31)、[公开 PR #32](https://github.com/DTB201/sb-user-manager-public/pull/32) | 支持按月提前或延长用户有效期 | 正数行为兼容既有续期；负数预览确认、只调整有效期且不得落到当前或过去；生成物、本地门禁、PR 与主分支 CI 全部通过 |
| UX-001 | P2 | 完成 | [Issue #65](https://github.com/DTB201/sb-user-manager/issues/65) | 修正子菜单返回文案 | 返回项显示“返回上一级”，实际返回层级和提示词通过真实伪终端测试 |
| SEC-002 | P2 | 完成 | [Issue #66](https://github.com/DTB201/sb-user-manager/issues/66) | 收紧完整快照最外层目录权限 | 新建快照最外层、数据目录和清单权限符合最小访问原则，恢复兼容性不变 |
| SEC-003 | P2 | 完成 | [Issue #78](https://github.com/DTB201/sb-user-manager/issues/78) | 自动迁移历史完整快照权限 | 启动时只收紧有效历史快照权限，无关目录和符号链接不受影响，重复执行安全，实机验收通过 |
| BUG-001 | P1 | 完成 | [Issue #81](https://github.com/DTB201/sb-user-manager/issues/81) | 修复 SS2022 + ShadowTLS 的 Surge UDP 支持 | 同端口 UDP、Surge 导出、用户生命周期、分流、Nfuse 计量和配额阻断均通过自动化与实机验收 |
| PERF-001 | P1 | 完成 | [Issue #84](https://github.com/DTB201/sb-user-manager/issues/84) | 修复脚本启动阶段重复扫描导致的变慢 | 无变化时跳过历史快照全量扫描，目录变化后自动重检，nube2 启动耗时明显下降且验收通过 |
| PERF-002 | P2 | 完成 | [公开 Issue #44](https://github.com/DTB201/sb-user-manager-public/issues/44) / [PR #45](https://github.com/DTB201/sb-user-manager-public/pull/45) | 新增用户时只解析一次 sing-box 配置 | 三个候选 tag 由单次格式化和单个参数化 jq 检查，最终配置复用同一快照且逐字节等价；50 用户夹具格式化调用减少 75%，中位耗时约降低 16%，生成物、本地门禁和公开 CI 通过 |
| PERF-003 | P2 | 完成 | [公开 Issue #46](https://github.com/DTB201/sb-user-manager-public/issues/46) / [PR #47](https://github.com/DTB201/sb-user-manager-public/pull/47) | 批量收集分流受管标签 | 一次读取并批量摘要、排序去重；缺少 Python 或遇到历史异常字段时回退原实现，20 分流夹具验证调用数、耗时与旧标签兼容，生成物、本地门禁、PR CI 和主分支 CI 全部通过 |
| PERF-004 | P2 | 完成 | [公开 Issue #49](https://github.com/DTB201/sb-user-manager-public/issues/49) / [PR #50](https://github.com/DTB201/sb-user-manager-public/pull/50) | 批量执行用户一致性审计检查 | sing-box 与 Nfuse 一次 jq 批量判断，保留原问题顺序、措辞与计数；50 用户夹具验证调用数与耗时，混合协议黄金输出、生成物、本地门禁、PR CI 和主分支 CI 全部通过 |
| PERF-005 | P2 | 完成 | [公开 Issue #52](https://github.com/DTB201/sb-user-manager-public/issues/52) / [PR #53](https://github.com/DTB201/sb-user-manager-public/pull/53) | 批量生成与重建用户协议入口 | endpoint 校验、入站构造、受管 tag 与数组拼接一次处理；50 个三入口用户夹具验证调用数、耗时、逐字节配置、失败传播、生成物、本地门禁、PR CI 和主分支 CI 全部通过 |
| PERF-006 | P2 | 完成 | [公开 Issue #54](https://github.com/DTB201/sb-user-manager-public/issues/54) / [PR #55](https://github.com/DTB201/sb-user-manager-public/pull/55) | 批量处理诊断报告脱敏 | 已排序脱敏表经标准输入交给单个 Python 进程；100 用户夹具验证调用数、耗时、逐字节输出、短名边界、元字符、子串、秘密 argv、缺 Python 回退、PR CI 和主分支 CI 全部通过 |
| UX-002 | P1 | 完成 | [Issue #85](https://github.com/DTB201/sb-user-manager/issues/85) | Shadowrocket 导出改为官方 URL 与二维码 | 自动化门禁、nube2 和当前正式版 Shadowrocket 的 AnyTLS、SS2022 + ShadowTLS 真实扫码、TCP、UDP 均已通过，PR #87 已合并 |
| BUG-002 | P1 | 完成 | [Issue #91](https://github.com/DTB201/sb-user-manager/issues/91) | 防止本机代理回连 SSH 在重启 sing-box 时断联 | v4.18.1 已发布；air 原故障路径正确拦截，nube2 真实菜单更新和 `release` 验收失败项为 0 |
| SPLIT-001 | P1 | 完成 | [Issue #98](https://github.com/DTB201/sb-user-manager/issues/98) | 增加预置出口和预置规则管理 | v4.19.0 已发布；本地、CI、生命周期、完整恢复、智能合并恢复、预置关联、Nfuse 用量恢复和两台测试机发布后验收均通过 |
| BUG-003 | P1 | 完成 | [Issue #101](https://github.com/DTB201/sb-user-manager/issues/101) | 修复查看预置列表时报错并退出脚本 | v4.19.1 四个 Release 附件与标签源码一致；克隆机真实菜单更新及 release 只读验收全部通过，Issue 已关闭 |
| ROUTE-001 | P1 | 完成 | [Issue #103](https://github.com/DTB201/sb-user-manager/issues/103)、[PR #105](https://github.com/DTB201/sb-user-manager/pull/105) | 共享预置在运行配置中只生成一份 | v4.20.0 已正式发布；自动化、双版本兼容、克隆机真实菜单更新、共享生命周期和发布后 `release` 验收全部通过 |
| BUG-004 | P1 | 完成 | [Issue #107](https://github.com/DTB201/sb-user-manager/issues/107)、[PR #108](https://github.com/DTB201/sb-user-manager/pull/108) | 清理抢先命中的旧版分流残留 | v4.20.1 已正式发布；本地门禁、克隆机一次性整理与回滚、真实菜单更新和发布后 `release` 验收均已通过 |
| BUG-005 | P0 | 完成 | [公开 Issue #36](https://github.com/DTB201/sb-user-manager-public/issues/36)、[公开 PR #37](https://github.com/DTB201/sb-user-manager-public/pull/37) | 修复首次启动提示调用未定义命令 | 快捷入口冲突和安装失败均调用真实暂停函数、返回成功并继续进入菜单；静态门禁能拒绝未定义裸命令目标，生成物、本地门禁与公开 CI 通过 |
| BUG-006 | P1 | 完成 | [公开 Issue #38](https://github.com/DTB201/sb-user-manager-public/issues/38)、[公开 PR #39](https://github.com/DTB201/sb-user-manager-public/pull/39) | 修复损坏有效期在自动到期检查中被静默放行 | 坏记录明确告警并跳过，其他到期用户继续停用；一致性检查报告“需要处理”，生成物、本地门禁与公开 CI 通过 |
| BUG-007 | P1 | 完成 | [公开 Issue #40](https://github.com/DTB201/sb-user-manager-public/issues/40)、[公开 PR #41](https://github.com/DTB201/sb-user-manager-public/pull/41) | 建立环境操作与用户操作的双向互斥 | 四个环境入口、启动恢复和脚本接管与用户/分流共用操作锁，两类事务日志双向排斥；全新环境、冲突、失败、回滚、描述符释放、本地门禁与公开 CI 通过 |
| UX-003 | P2 | 暂缓 | [公开 Issue #16](https://github.com/DTB201/sb-user-manager-public/issues/16) | 增加 Mihomo 格式的用户配置导出 | 项目所有者尚未确认实际必要性；不进入目标版本，待使用场景和维护价值明确后重新评估 |

## 当前最值得继续的顺序

1. 继续以真实使用中发现的 v4 缺陷驱动维护；[公开 Issue #16](https://github.com/DTB201/sb-user-manager-public/issues/16) 和 SEC-001 维持现有暂缓状态。

任何需要登录服务器、修改 SSH、恢复数据或操作正式环境的事项必须独立执行，先记录回滚方式并取得明确授权。
