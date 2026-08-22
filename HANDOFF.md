# 交接文档

本文件是**跨会话交接的当前快照**：接手的人先读它，就能知道现在做到哪、下一步该干什么、
哪些决定已经定了不必重问、哪些路已经走不通不必再试。

写作日期：**2026-08-22**，对应 `main` 提交 `b1ab362`、最新正式版 **v4.25.27**。

**它不是正式来源。** 每类长期信息的主要正式来源见 [`PROJECT.md`](PROJECT.md) 的
「正式来源与文档职责」；本文件只做摘要与指路。两者冲突时以那些文件与 GitHub Issue 为准。

**接手前必读**：[公开 Issue #63](https://github.com/Cr0ce11/sb-user-manager-public/issues/63)
的最后几条评论。

---

## 一、当前任务和进度

### 仓库与版本状态（本轮实读）

| 项 | 取值 |
|---|---|
| `main` | `b1ab362`，与 `origin/main` 一致，工作区干净 |
| 最新正式版 | **v4.25.27**（不可变 Release），直接代码回退点 v4.25.26 |
| 开放 Pull Request | **无** |
| 分支 | 只有 `main` |
| `main` 与最新 Release 的差距 | **无未发布的改动**——上一轮那份「main 上积着 P1」的警告已经不成立 |

### 正式业务环境

五台正式服务器（Air、Pro、Malibu、HKRFC、JPRFC）**已全部升到 v4.25.27**，
由项目所有者自己执行；仓库侧不登录正式服务器。

- 到期检查已恢复正常（Air 上有日志实证：升级前 `Failed to start`，升级后 `Finished`）。
- `/var/lib` 与 `/usr/local/sbin` 的权限已由项目所有者手工修回 755（**升级本身修不好它**，
  见第五节）。
- 两台机器上 apt 装的 sing-box 残包已卸净（Air、Malibu 各 65 MB），Malibu 的 sagernet
  软件源与密钥一并清掉。

### 正在做：sing-box 残留审查，三步走，第一步已完成，**第二步刚摸清范围、尚未动手**

| 步骤 | 内容 | 状态 |
|---|---|---|
| 第一步 | 修文案与文档：内核无关路径不再写死 sing-box | **已完成**（#243，随 v4.25.27 发出） |
| **第二步** | **撤掉两个永远点不动的菜单项，连同底下无人可达的实现** | **待做——范围已摸清，见第三节** |
| 第三步 | 文件级默认值仍然是 sing-box | **待做**，但**已经不再是纯清理**，见第三节 |

第二步是项目所有者主动叫停在「动手前」的：本轮已经发了一版、修了三个缺陷，
六百行规模的删除留给一个上下文干净的会话做，出问题也好回溯。

### 测试环境（本轮逐台实读）

| 机器 | 版本 | 内核 | 管理器数据目录 | `/var/lib` |
|---|---|---|---|---|
| `sbm-deb13` | 4.25.27 | mihomo | `/etc/sb-user-manager` | **700** |
| `sbm-mihomo` | 4.25.27 | mihomo | 默认（`/etc/sing-box`，配置里没写这一行） | 755 |
| `sbm-gate` | 未部署 | — | — | 755 |

- 两台部署机上的 4.25.27 是**用 `cp` 直装**的（`sbm-mihomo` 另外走过一次真实菜单更新路径），
  版本记录与 root 启动副本都同步过，所以 `audit` 不会报那两项已知的假失败。
- **`sbm-deb13` 的 `/var/lib` 故意留在 700**：它是验证 [#252](https://github.com/Cr0ce11/sb-user-manager-public/issues/252) 的现成夹具，别顺手修掉。
- **`sbm-mihomo` 的管理配置里没有 `MANAGER_DATA_DIR` 这一行**（装得早），它靠文件级默认值。
  第三步动那个默认值之前必须知道这件事。
- 仍然**没有任何办法在真机上验证 sing-box 的行为**；该代码路径只剩单元测试夹具覆盖。

**机器版本一律以登机实读为准**，不要引用记录里的旧数字。

---

## 二、已完成事项

只列结构性的；逐版本的用户可感知变化见 [`CHANGELOG.md`](CHANGELOG.md)，逐条事项见 [`TODO.md`](TODO.md)。

### v4.25.27（2026-08-22 发布）

本版带四件事，其中两件是本轮新发现的缺陷：

1. **[#246](https://github.com/Cr0ce11/sb-user-manager-public/issues/246)：每次环境操作都把
   `/var/lib` 与 `/usr/local/sbin` 改成 700**，影响每一台装过本脚本的机器。根因是
   `install -d -m` 点到已存在的目录会直接 chmod 它，而事务恢复记录当时放在 `/var/lib` 正下方。
   修复：恢复记录挪进 `/var/lib/sb-user-manager/recovery.json`（旧位置留着记录时仍以旧位置为准）；
   新增 `ensure_manager_directory`（已存在只检查类型、绝不改权限、拒绝符号链接）；
   被改坏的机器在部署与修复两条路径上修回 755，只认 700 这个指纹；静态断言禁止把管理器的文件
   直接摆在 `/var/lib` 正下方。
2. **[#251](https://github.com/Cr0ce11/sb-user-manager-public/issues/251)：mihomo 机器上到期检查
   每次都失败，到期用户不会被自动停用**（P1，发布验收途中发现）。到期任务在载入管理配置**之前**
   就检查环境完整性，那一刻 `PROXY_KERNEL` 还是文件级默认值 `singbox`。修复：先
   `resolve_deployment_kernel` 再检查，并补了 mihomo 形状的回归夹具与三条对照。
3. #242／#244：「安装或修复环境」的自动修复分支在 mihomo 上必定失败（此前已合入、未发布）。
4. #243：一批内核无关却写死 sing-box 的文案与文档（此前已合入、未发布）；同期剥离
   `SB_DEPLOY_PROXY_KERNEL`（#240）。

发布验收：本地门禁 12 条、单元测试、`test-standalone-startup.sh` 在 `sbm-gate` 通过；
两台测试机 `audit` 各 0 失败；`sbm-mihomo` `lifecycle` 0 失败（含「到期用户自动停用」）；
发布后退回 v4.25.26 走真实菜单更新路径升回来，`release` 模式 0 失败，附件摘要
`ab596c1e…` 与本地生成物逐字节一致，`immutable` 读回为 true。

### 本轮另外两件不改代码的事

- **[#247](https://github.com/Cr0ce11/sb-user-manager-public/issues/247)：apt 装的 sing-box 包，
  脚本的「清理 sing-box 残留」够不着**，会报假的「已清理」。**结论是不改实现**（见第四节），
  两台正式服务器由项目所有者手工 `apt purge` 卸净。
- **`docs/RELEASE.md` 新增一条发布后检查**：CHANGELOG 里关于「升级之后会怎样」的断言，
  只能由真实菜单更新那一步证实。这条是用一次错误换来的，见第五节。

---

## 三、下一步计划

### 第二步：撤掉两个永远点不动的菜单项（**范围已摸清，尚未动手**）

「部署与卸载」里这两项无条件显示，而所有机器都是 mihomo，因此永远点不动：

| 菜单项 | 现在的结果 |
|---|---|
| 切换到 mihomo 内核 | 必定报「本机的代理内核不是 sing-box，无需切换」 |
| 清理 sing-box 残留 | 必定报「没有找到 sing-box 的残留文件，无需清理」 |

**#247 让撤除更有理由**：后者不只是点不动，它在真实的生产机上**报了假的「已清理」**——
那台机器上还留着一整套 apt 装的 sing-box。

要删的东西（本轮实测统计，比之前估的大）：

| 组 | 内容 | 位置 | 规模 |
|---|---|---|---|
| A | sing-box 版本管理（通道切换）10 个函数 | `src/50-install-update.sh:445-830` | ~230 行 |
| B | 换内核 3 个函数（`switch_kernel_preflight`／`switch_kernel_to_mihomo`／`verify_kernel_switch`） | 同上 `2422-2612` | ~155 行 |
| C | 清理残留 3 个函数（`singbox_leftover_paths`／`verify_singbox_cleanup`／`cleanup_singbox_leftovers`） | 同上 `2613-2712` | ~78 行 |
| **D** | **删完之后变成孤儿的**：`stop_singbox_for_switch`、`apply_rule_set_migration`，以及 `src/40-split-runtime.sh` 里那整套把 sing-box 的 `.srs` 规则集转成 mihomo yaml 的机器；连带 `kernel_rule_set_decompile`（届时无人调用） | `40-split-runtime.sh` ~`517-660`、`05-kernel.sh` | 150 行以上 |

还要动：两个菜单项与分派（`src/80-menus-main.sh:263-275`）、失去用途的常量
（`SINGBOX_CHANNEL_STATE`、`SINGBOX_VERSION_STORE`）、测试里约 22 处引用
（`test-unit.sh` 15 处、`test-static.sh` 7 处，其中 `test-static.sh:802` 是一条
「`singbox_channel_menu()` 必须存在」的断言）、README 约 30 处 sing-box 语境的说明，
以及 `sb-user-expiry` 两个单元里写死 sing-box 的描述文字。

**合计六百行上下的删除，跨 4 个文件。**

**项目所有者已经知道并接受的两个后果**（2026-08-22 当面确认，不必再问）：

- D 组删掉之后，**再没有任何把 sing-box 规则集自动转成 mihomo 格式的路**；哪天冒出一台
  还在跑 sing-box 且带分流的机器，只能手工重建分流。
- 撤掉「切换到 mihomo 内核」之后，**公开仓库里其他人的 sing-box 机器也没有迁移入口了**。
  这符合 sing-box 线归档的方向。

保留 `singbox_deployment_present`（7 行）：它是「管理配置丢了怎么判」的判据，逻辑仍要留着。

**动手建议**：先删代码跑门禁，让 `check-shell-call-targets.py` 把漏网的调用点报出来；
再改测试；README 与单元描述文字放在同一个 PR（避免改两遍）。改单元描述会让每台存量机器的
「服务与配置检查」多报一条「[可自动修复] 服务单元与当前版本不一致」，直到跑一次
「安装或修复环境」——这一点要写进 CHANGELOG。

### 第三步：文件级默认值仍然是 sing-box（待做，**性质已经变了**）

`src/00-bootstrap.sh` 第 20 行 `PROXY_KERNEL="singbox"`、第 35 行 `MANAGER_DATA_DIR="/etc/sing-box"`。

本轮的 #251 证明**这不只是「不好看」**：任何在载入管理配置之前读 `PROXY_KERNEL` 的代码，
拿到的都是错的内核。#251 修的是其中一个调用点，**默认值本身还在那里**。

改它之前必须知道两件事：

1. `resolve_deployment_kernel` 的注释里记着一次事故——一台 mihomo 机器执行「自动修复缺失内容」
   曾经去下载并部署了 sing-box。
2. **`sbm-mihomo` 的管理配置里没有 `MANAGER_DATA_DIR` 这一行**，它靠的正是那个默认值。
   正式机器是用 v4.25.22+ 切过来的、切换时重写过配置，应该都有这一行，但**动手前值得让项目
   所有者在一台正式机上跑一次 `grep -c '^MANAGER_DATA_DIR=' /etc/sb-user-manager.conf` 确认**。

### 其余开放项

| 事项 | 状态 |
|---|---|
| [#252](https://github.com/Cr0ce11/sb-user-manager-public/issues/252) 系统目录权限修复挂错了地方，从旧版升上来的机器升完仍是 700 | **P2，待做**；解法是挂到 `run_standalone_interactive_startup` 那串一次性迁移里。`sbm-deb13` 是现成夹具 |
| [#187](https://github.com/Cr0ce11/sb-user-manager-public/issues/187) 「验证分流是否生效」在 mihomo 上不可用 | 人肉兜底、不排期，**有意保留** |
| [#16](https://github.com/Cr0ce11/sb-user-manager-public/issues/16) Mihomo 格式的用户配置导出 | 候选 |
| `TODO.md` 的 MAINT-013 | 开发机 ShellCheck 比 CI 新，本地报 CI 不报的 SC2329（5 条） |

---

## 四、已确定的技术决策及原因

长期决定以 [`docs/DECISIONS/`](docs/DECISIONS/) 为准。下面是接手后马上会用到的：

### 方向与范围

- **sing-box 线已归档。** 新功能、新护栏只做 mihomo 侧；sing-box 侧只维持现状，不加新东西。
- **代理协议只用 SS2022（可加 ShadowTLS）与 AnyTLS。** 不引入 Hysteria2、TUIC。
- **不再支持接管别人手工装的 sing-box。** 相关实现整段删除而不是把入口藏起来——
  留着一段谁都调不到的部署代码，迟早有人以为它还能用。**第二步正是按这条规矩处理。**
- **内核无关的路径不许写死内核名**，用 `kernel_display_name` 等适配层入口。

### apt 装的 sing-box：不改实现（#247）

正确的清理方式是 `apt purge sing-box`——dpkg 装的东西必须由 dpkg 卸载，用 `rm` 删只会留下
「登记着但文件没了」的半残包状态。**这不该由本脚本代劳**：sing-box 线已归档不再添新东西，
而让脚本去 `rm` 掉 dpkg 管理的文件本身就是错做法。手工步骤记在 #247 里。

### 目录权限（#246）

- **`install -d -m` 点到一个已经存在的目录会直接 chmod 它。** 管理器自己的目录（数据目录、
  备份、证书、`/var/lib/nfuse`）**故意**即使已存在也收紧到 700；系统共享目录
  （`/var/lib`、`/usr/local/sbin`、`/usr/local/bin`、`/run/lock`）**一律只在缺失时创建**，
  走 `ensure_manager_directory`。
- **管理器自己的文件不许直接摆在 `/var/lib` 正下方**，必须放进子目录；有静态断言钉着。
- 修复已被改坏的机器时**只认 700 这个指纹**，管理员自己设成别的值不覆盖。

### 备份与退路（ADR 0032）

- **操作前的完整环境快照只服务于自动回滚，不做手工恢复入口。**
- **任何不可逆操作之前必须先有一份复制到服务器之外的 `.sbm`。**

### 门禁

- **权威运行环境是 Linux 上的 Bash 5（`sbm-gate`）**；开发机是 macOS／arm64，
  整份单元测试在上面必定失败。
- **不改写那 502 条裸 `[[ ]]` 断言**；**新写的断言要用会自己报错的写法**。
- **新增护栏必须配反面样本与对照**：反面样本证明它不是恒真，对照证明它不误伤。

### 发布与授权

- **发布正式版前停下来等项目所有者确认。**
- **创建 Release 不等于授权部署到正式环境。**
- **仓库侧不登录任何正式服务器。**
- **任何凭据都不写进报告。**
- **CHANGELOG 由发布准备 PR 统一写，功能 PR 不动它。**
- **CHANGELOG 里关于「升级之后会怎样」的断言，只能由发布后那次真实菜单更新证实**
  （`docs/RELEASE.md` 发布后第 5 条，本轮新增）。

---

## 五、踩过的坑和已否决的方案及原因

### 本轮新增的四条（都会再遇到）

1. **在新脚本上验证一个修复「有效」，不等于验证了「从上一版升上来之后有效」。**
   v4.25.27 的 CHANGELOG 写了「升级之后不用做任何事，两个目录会恢复成 755」，
   被发布后的真机复检当场证伪：**升级那一次是由旧脚本执行部署的**，跑的仍是那份把目录改坏的
   旧代码。实测 755 →（升级）→ 700 →（再点一次「安装或修复环境」）→ 755。
   已在 CHANGELOG 标明更正，解法记在 #252。

2. **测试夹具的形状会决定它能不能看见缺陷。** #251 之所以躲过所有测试，是因为
   `test-standalone-startup.sh` 的完整部署夹具是 **sing-box 形状**的，恰好与那个错误的
   文件级默认值一致。**给 mihomo 侧的行为写测试时，先问一句夹具是什么形状。**

3. **同一个进程里连跑多个用例会串状态。** 给到期任务加上「先确定内核」之后，原有的
   sing-box 用例开始报错——因为确定内核会改 `PROXY_KERNEL` 与 `MANAGER_DATA_DIR`，
   而真机上定时任务每次是全新进程。现在 `reset_calls` 里会把这两个值恢复成文件级默认值。

4. **等一个「会失败的服务」变成 `inactive` 会永远等下去。** 本轮写等待脚本时，
   条件写的是「等 `sb-user-expiry.service` 变回 inactive」，而它的状态是 `failed`，
   于是空转了半小时。**要么等 `ActiveState` 不再是 `activating`／`active`，
   要么直接看 `systemctl list-timers` 的下一次触发时刻。** 顺带一提：正是那个
   `failed` 状态让我们发现了 #251。

### 更早的坑（仍然有效）

5. **护栏可能把缺陷一起钉住。** #242 那处写死的 sing-box 配置路径，静态门禁里正好有一条断言
   钉着它。**写结构性断言时必须写清它保护的是哪个不变量。**

6. **跟在 `if`／`!`／`&&`／`||` 后面的命令，其整个动态调用范围内 `set -e` 都不生效。**
   从菜单进去的 `cmd_*` 内部的 `return 1` 不会中断流程。

7. **裸 `[[ ]]` 断言失败时一个字都不打印。** 定位手法：
   `bash -x tests/test-unit.sh 2>/tmp/x.log >/dev/null; tail -25 /tmp/x.log`。

8. **OrbStack 的共享文件系统偶尔让构建或客机读到半份文件。** 本轮 `tools/build-manager.sh`
   报过一次「生成脚本语法检查失败」，而每个 `src/*.sh` 单独 `bash -n` 都是好的，重跑即通过。
   **先比对摘要再重试，不要当成代码缺陷去查。**

9. **`$(...)` 会在 `gh pr create --body "..."` 里被 shell 执行**；正文一律用 `--body-file`，
   提交说明一律用 `-F` 文件。

10. **`sb-user-expiry.timer` 每 15 分钟触发一次，会拿走管理锁。** 跑 `lifecycle` 前先看
    `systemctl list-timers`，**排在一次触发刚结束之后**。
    ⚠️ **不要用「停掉定时器」来避开它**：只读验收有一条「服务 sb-user-expiry.timer：active」，
    停掉它会让整个写入型验收前置检查失败。本轮踩过。

11. **`lifecycle` 等写入型验收需要 `SB_ACCEPTANCE_CONFIRM=YES`**，否则会拒绝执行并回滚。

12. **用 `cp` 直装脚本到测试机，`audit` 会报两项假失败**（版本记录、root 启动副本）。
    同步 `/var/lib/sb-user-manager/versions` 与 `/root/sb-user-manager.sh` 即可避免。

13. **宿主机的代理客户端工作在 fake-IP 模式**，会把公网域名解析成 `198.18.x.x`；
    两台部署机上有绕开它的 `/etc/hosts` 条目。

14. **文档里靠人记得的那一行迟早会漂。** 遇到同类「必须一起改」的两处，直接加断言。

### 已否决的方案

| 方案 | 为什么否决 |
|---|---|
| 给完整环境快照加「从操作前快照恢复」的菜单入口 | 会静静抹掉快照之后的用户、分流与用量；详见 ADR 0032 |
| 把 502 条裸 `[[ ]]` 断言全部改写 | 它们在 Bash 5 上有效，问题出在运行环境 |
| 给生产线单开一条只修 bug 的 sing-box 稳定线 | 前提（生产全是 sing-box）已消失，#202 已关闭 |
| 让脚本去清理 apt 装的 sing-box 残包 | dpkg 装的东西必须由 dpkg 卸载；且 sing-box 线已归档不再添新东西（#247） |
| 停掉到期定时器来避开验收时的锁冲突 | 只读验收要求它是 active，停掉会让写入型验收整个前置检查失败 |
| 用 `openssl s_client` 的退出码判断对方说不说 TLS 1.3 | 证书验证失败时它也非零退出 |

### 环境与流程

- **门禁在门禁机上跑**：`orb -m sbm-gate bash tests/test-static.sh`；单元测试、
  `test-standalone-startup.sh` 同理。**门禁 12 条不含 ShellCheck**，跑完在开发机补跑 CI 里
  那两条（第二条会报 5 条 CI 不报的 SC2329，见 MAINT-013）。
- **`tests/test-public-snapshot.sh` 要求工作区干净**，必须提交之后才能跑。
- **还原临时破坏先 `cp` 一份**，不要用 `git checkout <文件>`；还原后比对生成物摘要。
- **提交前跑 `git status --short` 和 `git diff --stat` 逐处确认**。
- **改 `src/` 之后要跑 `bash tools/build-manager.sh`** 重新生成单脚本。

### 怎么跑「真实菜单更新路径」

用伪终端驱动编号式菜单：`pty.fork()` 起脚本，读屏幕、用正则从 `  N  标签` 里取编号发过去。
本轮实际走通的两条路径：

- 更新：`系统管理` → `检测更新` → `y`
- 修复：`系统管理` → `部署与卸载` → `安装或修复环境` → `自动修复缺失内容`

**驱动器要注意**：按键发完不能因为没输出就退出（下载内核和 Nfuse 时会长时间静默），
要一直等到完成标记命中或总超时；跑更新之前先把机器退回上一版的**已安装脚本、版本记录和
root 启动副本**三处，否则脚本会认为已是最新而不走下载。
