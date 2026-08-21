# 项目状态

## 项目目标

`sb-user-manager` 是面向非专业 Linux 用户的 VPS 代理节点管理系统。项目通过中文交互菜单管理 sing-box、Nfuse、systemd、用户、流量、分流、诊断和跨服务器迁移。

项目当前最重要的目标不是继续增加功能，而是保持正式环境稳定，以真实使用中发现的问题驱动维护，并继续使用可重复、可审计、可回退的开发与发布流程。

## 正式来源与文档职责

- GitHub 仓库的 `main` 是代码和文档的唯一正式来源。
- GitHub Issue 记录需求、问题、优先级和验收标准。
- `docs/DECISIONS/` 记录长期有效的产品或技术决定。
- Pull Request 记录实现范围、风险、测试证据和恢复方式。
- GitHub Release 是可部署脚本的唯一正式来源。
- 服务器只用于测试、部署和运行，不能作为代码或项目记录的唯一来源。

聊天可以用于讨论和确认，但长期有效的结论必须进入以上正式记录。

2026-08-13 以前的文档可能仍包含指向已退役私有仓库的历史 Issue 或 Pull Request 链接；这些链接不再是续作入口，相关版本结论以本仓库的 CHANGELOG、ADR、测试和公开不可变 Release 为准。所有新工作只使用本公开仓库的 Issue 和 Pull Request。

每类长期信息只维护一个主要正式来源：

| 信息类型 | 主要正式来源 |
|---|---|
| 当前版本、环境和所处阶段 | 本文件 `PROJECT.md` |
| 阶段目标和先后顺序 | [`ROADMAP.md`](ROADMAP.md) |
| 可执行事项、优先级和状态 | [`TODO.md`](TODO.md) |
| 分支、开发、测试和完成定义 | [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) |
| 安装、更新、验收操作和故障回退步骤 | [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) |
| 发布门禁、发布授权和发布后检查 | [`docs/RELEASE.md`](docs/RELEASE.md) |
| 长期产品与技术决定 | [`docs/DECISIONS/`](docs/DECISIONS/) |

其他文件可以提供摘要和链接，但不重复维护同一套操作步骤或门禁清单。

## 当前状态

| 项目 | 当前状态 |
|---|---|
| 最新正式版 | v4.25.19 |
| 主开发分支 | `main` |
| 正式支持环境 | Debian 12 x86_64 |
| 测试环境 | 开发机上的本地 OrbStack 测试机（Debian 12 x86_64，完整 systemd）；`audit`、`release`、`lifecycle`（含分流）、`full` 四种验收模式与跨机迁移恢复演练均已实测通过，能力范围与限制见 [公开 Issue #139](https://github.com/Cr0ce11/sb-user-manager-public/issues/139)。发布仍以本地门禁与公开仓库 GitHub CI 为基础 |
| 正式环境 | 各服务器已统一升级到 v4.25.16，升级后运行「服务与配置检查」未报出任何骨架缺项（[公开 Issue #163](https://github.com/Cr0ce11/sb-user-manager-public/issues/163)）；此前 v4.25.11 的升级与一致性检查误报消失记录见 [公开 Issue #120](https://github.com/Cr0ce11/sb-user-manager-public/issues/120)，v4.25.8 的升级与迁移备份验证记录见 [公开 Issue #100](https://github.com/Cr0ce11/sb-user-manager-public/issues/100)，v4.25.7 的升级与只读自检记录见 [公开 Issue #69](https://github.com/Cr0ce11/sb-user-manager-public/issues/69)。历次升级均由项目所有者自行执行，仓库侧未登录复核，因此没有仓库可核对的验收报告。首次上线记录见 Issue #96（地址和凭据不进入仓库） |
| 发布形态 | `Cr0ce11/sb-user-manager-public` 是唯一正式仓库；开发、Issue、Pull Request、完整 CI、匿名在线更新和不可变 Release 全部在这里完成 |
| 阶段 0 | 已完成（Issue #46，经 PR #47 合并） |
| 当前所处阶段 | 阶段 3：上线后维护 |
| 已完成的阶段 1 验收 | `audit` 基线（Issue #48）、用户生命周期（Issue #51）、分流生命周期（Issue #52）、迁移备份与恢复（Issue #56）、正式版菜单更新（Issue #63） |
| 当前阶段任务 | v4.25.24 已作为不可变 Release 发布（[公开 Issue #221](https://github.com/Cr0ce11/sb-user-manager-public/issues/221)）；正式机器搬到 mihomo 由项目所有者自己执行并记录在 [公开 Issue #217](https://github.com/Cr0ce11/sb-user-manager-public/issues/217)；当前没有已知未解决的 P0/P1 运行缺陷 |

现有最新完整正式版为 v4.25.24，主要功能包括安装、环境修复与完整卸载、原生 SS2022、既有 SS2022 + ShadowTLS 和 AnyTLS 用户管理、Nfuse 流量统计与配额、分流管理、可复用的预置出口与预置规则、共享预置运行配置、正式版与测试版 sing-box 切换、诊断报告、事务回滚以及加密迁移备份和恢复。同一用户最多可同时拥有一个原生 SS2022、一个既有 SS2022 + ShadowTLS 旧版入口和一个 AnyTLS，三类入口共享流量、配额、有效期和启停状态，并可按精确入口类型管理。v4.25.2 会在安装或更新改动系统前验证本机回环地址可用；v4.25.3 修复续期月数被误当作数字时区、导致多月输入通常仍只增加一个月的问题；v4.25.4 删除从未开放且已不可达的 v5 控制器与落地实现；v4.25.5 将“续期用户”扩展为可按月提前或延长有效期；v4.25.6 修复首次启动暂停、损坏有效期、环境与用户操作互斥等审计缺陷，并批量优化配置检查、分流标签、用户一致性、协议入口和诊断脱敏；v4.25.7 加固调度器命令目标门禁与更新锁语义，并把脚本自身的更新目标显式指向项目所有者的新 GitHub 用户名 `Cr0ce11`，不再依赖旧所有者重定向；v4.25.8 收拢一轮完整代码审查的 19 项缺陷修复、整合后核验发现的 6 处回归修正、分流顺序按合并组处理，以及 Nfuse 二进制损坏检测；v4.25.9 新增非交互只读子命令 `sbm status` 与 `sbm users`（含 `--json`），可在不进交互菜单的情况下通过 SSH 查询服务健康与用户用量，输出不含任何凭据，且不取锁、不写文件、不改变既有行为；v4.25.10 把只读状态里的服务状态改为与菜单一致的中文说法，中文映射由两处共用；v4.25.11 修复 sing-box 把单元素 inbound 塌成标量导致的一致性检查误报、启动期多余重建与停用用户检查静默失效；v4.25.12 把读取与校验内核配置的调用收敛到适配层 `src/05-kernel.sh` 并由静态门禁强制，把内核配置骨架收敛为单一来源使全新安装与接管既有安装共用同一份定义，据此在「服务与配置检查」新增只读的骨架检查项，并把密钥生成改用 `openssl rand -base64` 脱离内核；v4.25.13 修复该骨架检查把 sing-box 省略的空数组误判为缺失、在未配置分流的服务器上产生假警报的问题；v4.25.14 让安装与更新在可恢复的 TLS 瞬时握手失败时自动重试，并把 GitHub 的 API 查询与资产下载收敛为两个统一封装；v4.25.15 完成内核适配层收尾，使所有对代理内核可执行文件与其服务的调用集中在一处并由静态门禁强制，同时把同类重试修复补到验收工具；v4.25.16 让一台部署声明自己使用哪个代理内核，是接入第二内核的第一片；v4.25.17 让脚本能够安装、启停并查询 mihomo，是接入第二内核的第二片，对 sing-box 部署没有任何可感知变化，内核选择尚无菜单入口；v4.25.18 把管理器自身数据（用户资料、内部备份、AnyTLS 证书）的位置收敛为单一来源，默认位置与行为一字不变，是 [公开 Issue #172](https://github.com/Cr0ce11/sb-user-manager-public/issues/172) 三步走的第一步，同版本另修掉 mihomo 机器的环境快照漏收 mihomo 自身配置、可执行文件与单元的回滚缺口（[公开 Issue #175](https://github.com/Cr0ce11/sb-user-manager-public/issues/175)）；v4.25.19 让 mihomo 部署能生成三种入口的用户配置，是接入第二内核的第三片，对 sing-box 部署没有任何可感知变化，内核选择仍无菜单入口；v4.25.20 让 mihomo 部署能生成分流并使「服务与配置检查」和「安装或修复环境」在 mihomo 上完整可用，是接入第二内核的第四、第五片，同版本把 systemd 单元与当前版本的一致性纳入审计（[公开 Issue #190](https://github.com/Cr0ce11/sb-user-manager-public/issues/190)）——此前升级流程从不刷新单元，存量机器会静静落在旧单元上，这是本版本唯一一处 sing-box 使用者可感知的变化，检查只查、改由「安装或修复环境」执行；该版本另把 ShadowTLS 严格模式的行为断言补齐（[公开 Issue #182](https://github.com/Cr0ce11/sb-user-manager-public/issues/182)），实测确认握手目标不支持 TLS 1.3 时严格模式开着的入口拒绝承载代理，该结论只落为注释，没有行为变化；v4.25.21 让 mihomo 部署在改默认连接域名与做「服务与配置检查」时先探一次 ShadowTLS 握手目标支不支持 TLS 1.3，探通但不支持时当场拒绝、网络探不通只提示，sing-box 部署没有任何变化（[公开 Issue #194](https://github.com/Cr0ce11/sb-user-manager-public/issues/194)）；v4.25.22 让一台在跑的 sing-box 服务器可以整机换成 mihomo（[公开 Issue #203](https://github.com/Cr0ce11/sb-user-manager-public/issues/203)，[公开 Issue #122](https://github.com/Cr0ce11/sb-user-manager-public/issues/122) 三步计划的第三步）：换过去之后客户端配置不用改、端口密码有效期配额与累计用量都不变，分流的规则集由脚本转换且转换不可逆，动手前先给一次只算不改的演练，失败整体回到切换前；不点那个菜单项时 sing-box 部署的行为一字不变；v4.25.23 让全新安装只装 mihomo、新装机器的管理器数据改放在中立目录 `/etc/sb-user-manager`，并撤掉接管别人手工装的 sing-box 那条路（[公开 Issue #157](https://github.com/Cr0ce11/sb-user-manager-public/issues/157) 第二步的最后一片，同时完成 [公开 Issue #172](https://github.com/Cr0ce11/sb-user-manager-public/issues/172) 三步走的第二步）——**存量机器升级后内核、数据目录与菜单一字不变**；v4.25.24 让 mihomo 部署的分流多出两种规则来源——网址（规则集由 mihomo 每天自动更新，保存时由管理器先下载校验一遍）与 GeoSite／GeoIP 类别（不需要任何规则文件，类别名保存时由 mihomo 当场校验）（[公开 Issue #218](https://github.com/Cr0ce11/sb-user-manager-public/issues/218)、[公开 Issue #219](https://github.com/Cr0ce11/sb-user-manager-public/issues/219)），同版本新增「立即更新规则集」与「geo 数据源」两个入口、把规则集来源的漂移纳入审计，并修掉两处会让分流静静失效的缺陷；三处新界面都只在 mihomo 上出现，sing-box 部署一字不变，没有 geo 分流的机器运行配置也一字不变。v4.25.23 保留为当前直接代码回退版本；正式业务环境已统一升级到 v4.25.16，由项目所有者执行；升级后「服务与配置检查」未报出任何骨架缺项，这回答了配置骨架此前有两份不一致定义时留下的问题（[公开 PR #130](https://github.com/Cr0ce11/sb-user-manager-public/pull/130)）——就这些服务器而言骨架是完整的；该结论限于这些服务器的实测结果，不构成关于接管流程的普遍结论。正式业务环境已统一升级到 v4.25.11，由项目所有者执行；升级后已确认 v4.25.11 修复的一致性检查误报不再出现（[公开 Issue #120](https://github.com/Cr0ce11/sb-user-manager-public/issues/120)），这是该根因三处后果中唯一可由真实环境直接观察确认的一项，另外两处（启动期多余的配置重建与重启、停用用户规则检查静默失效）不产生用户可见提示，只能依靠单元测试与结构性断言。此前 v4.25.8 升级后已验证迁移备份可正常生成（[公开 Issue #100](https://github.com/Cr0ce11/sb-user-manager-public/issues/100)），这是「编辑独立配置分流后备份永久失效」修复（[公开 Issue #77](https://github.com/Cr0ce11/sb-user-manager-public/issues/77)）在真实环境的唯一确认方式。后续升级仍需独立授权。

## 职责边界

- 项目所有者保留最终业务验收、正式环境上线和高风险操作授权。
- AI 产品与技术负责人负责理解真实目标、维护路线图、决定日常优先级、形成技术方案、识别风险并定义验收标准。
- Codex 执行代理负责检查仓库、实现代码、更新测试与文档、创建分支和 Pull Request，并在获授权的测试环境验证。
- 可能造成数据丢失、服务中断、权限变更、凭据暴露、不可逆写入或正式环境影响的操作，必须在执行前建立回滚点并取得项目所有者明确授权。

完整决定参见 [`docs/DECISIONS/0002-ai-product-technical-lead.md`](docs/DECISIONS/0002-ai-product-technical-lead.md)。

## 上线状态

v4.18.1 已按原私有 Issue #96 完成首台正式服务器上线。上线前预检、固定 Release 全新部署、真实 AnyTLS 与 SS2022 + ShadowTLS 客户端 TCP/UDP、Nfuse 用量联动、上线后 30 分钟和 24 小时观察均已通过；最终 `release` 只读验收失败项为 0，观察期内没有服务异常重启或相关错误。首次上线任务已经关闭，项目进入阶段 3 的上线后维护。此后各服务器于 v4.25.7 发布后由项目所有者统一升级并确认只读自检正常（[公开 Issue #69](https://github.com/Cr0ce11/sb-user-manager-public/issues/69)），于 v4.25.8 发布后再次统一升级、验证迁移备份可正常生成（[公开 Issue #100](https://github.com/Cr0ce11/sb-user-manager-public/issues/100)），并于 v4.25.11 发布后再次统一升级、确认一致性检查误报不再出现（[公开 Issue #120](https://github.com/Cr0ce11/sb-user-manager-public/issues/120)），又于 v4.25.16 发布后统一升级、确认骨架检查未报出任何缺项（[公开 Issue #163](https://github.com/Cr0ce11/sb-user-manager-public/issues/163)）；远程专用测试服务器已经弃用，v4.23.0 至 v4.25.16 采用本地门禁与 GitHub CI 验收；自 v4.25.13 起另有开发机上的本地 OrbStack 测试机可用于真机验收（[公开 Issue #139](https://github.com/Cr0ce11/sb-user-manager-public/issues/139)），仓库侧没有在本轮治理中登录或修改服务器。当前公开仓库没有已知未解决的 P0/P1 运行缺陷；Mihomo 导出候选需求已迁到公开 [Issue #16](https://github.com/Cr0ce11/sb-user-manager-public/issues/16)，SEC-001 继续暂缓。后续正式环境变更仍需建立独立公开 Issue、准备回退方式并取得项目所有者明确授权。

## 如何更新本文件

当最新正式版、支持环境、正式环境状态、当前所处阶段或职责发生变化时，必须在同一 Pull Request 中更新本文件。具体任务和进度不要堆积在这里，分别记录到 [`ROADMAP.md`](ROADMAP.md) 和 [`TODO.md`](TODO.md)。
