# ADR 0012：入口 apply package 匿名构建与原子发布

- 状态：已接受，控制器构包能力仍未接入产品界面
- 日期：2026-08-07
- 关联：[ADR 0007](0007-landing-secret-and-apply-protocol.md)、[Issue #211](https://github.com/DTB201/sb-user-manager/issues/211)

## 背景

apply package 包含 AnyTLS 密码、CA、证书、私钥、SNI 和入口地址。原 builder 先后创建具名 gateway 与 package 临时文件，再调用通用 package validator；该 validator 还会把三份 TLS 材料解到具名校验目录。常规错误和可捕获信号可以清理这些路径，但 `SIGKILL`、内核崩溃或断电不会执行 trap，因而可能留下额外可寻址的明文文件。

仅把临时文件改为“创建后立即 unlink”仍存在 create/unlink 窗口；先把匿名 inode 链接为随机隐藏名再 rename，则在 link/rename 窗口仍可能留下隐藏明文。memfd 也不能跨文件系统直接发布到最终目录，复制到目标又会重新引入部分写入状态。

## 决定

builder 先按既有规则校验秘密清单、网络参数、revision、时效、nonce、目标不存在以及输出目录为受信任的 700 目录。随后启动隔离的 Python 进程，并在读取秘密前完成以下限制：

- 将进程设为不可 dump、把 core 大小上限降为零、清空继承给校验子进程的 `coredump_filter`，并使用 077 umask，避免系统 core 收集器把内存中的 PEM 另存为持久文件；
- 设置父进程死亡时由内核发送 `SIGKILL`，避免调用 shell 被强制终止后留下孤儿构包进程；
- 所有 Python 异常折叠为固定退出状态，不输出 traceback、路径或用户值。

动态值只通过环境传入 Python，argv 只有固定的解释器参数。SNI 从 600 清单读取，密码和 PEM 从清单引用的 600 普通文件读取；重新打开时拒绝符号链接，并复核所有者、权限、类型和大小。gateway 只存在于隔离进程内存，`content_sha256` 继续严格等于 `jq -cS '.gateway'` 输出加换行后的 SHA-256，schema、字段、TTL 和调用接口均不改变。

输出目录通过 `O_NOFOLLOW | O_DIRECTORY` 打开并复核所有者和 0700 权限。最终 package 写入该目录文件系统上的 `O_TMPFILE` 匿名 inode：

1. inode 必须是期望所有者的 600 普通文件，且 link count 为 0；
2. 完整循环写入后从同一 fd 重读，与内存字节逐字节比较；
3. 在内存中复核 schema、字段类型与边界、来源值、摘要、网络字段和时效；同时把本次实际读入 package 的 CA、证书和私钥字节放入匿名 memfd，通过 `/proc/self/fd` 交给受限 OpenSSL 子进程重新执行解析、有效期、证书链和公私钥匹配校验，并在同一进程内复核 SNI。这样即使初始清单校验与读取之间恰逢合法轮换，也不会把不属于同一批次的 TLS 材料发布出去；
4. 同步匿名文件，并再次确认长度、权限和仍无目录项；
5. 使用 `linkat` 从匿名 fd 直接链接到调用者指定的最终名称，不创建隐藏中间名。非特权环境缺少 `AT_EMPTY_PATH` 能力时，只允许采用 Linux 为 `O_TMPFILE` 提供的 `/proc/self/fd/<fd>` 加 `AT_SYMLINK_FOLLOW` 直链方式；两种方式都由同一个 dirfd 发布且不覆盖已存在目标；
6. 发布后复核最终名称与匿名 fd 为同一 inode、普通文件、期望所有者、0600、唯一链接和完整长度，再次同步文件和父目录后才返回成功；shell 还会用既有 jq 规则复核结构、摘要和时效。

如果 `O_TMPFILE`、可链接匿名 inode、proc fd 桥接或目录同步不受支持，builder 给出不含秘密的固定提示并失败关闭，不允许回退到 `mktemp`、`install`、复制或其他具名明文方案。

## 中断状态不变量

直接发布把所有中断点压缩为两种可接受状态：

- `linkat` 成功前：匿名 inode 没有目录项；进程退出后由内核回收，目标不存在；
- `linkat` 成功后：最终名称一次性指向已经完整写入、校验、设为 600 且至少完成一次文件同步的 inode。即使在后续复核或父目录同步前被 `SIGKILL`，目标也是完整 package，不会是部分 JSON，也没有第二个明文名称。

这项保证针对“额外可寻址目录项”和部分目标，不宣称安全擦除文件系统数据块；长期秘密本来就按 600 存放在控制器秘密目录中。

## 兼容性与范围

Debian 12 是运行支持范围，Ubuntu 24.04 与固定 Debian 12 CI 必须实际执行正常发布和多阶段 `SIGKILL` 测试。macOS 或不支持安全匿名发布的文件系统只验证明确失败关闭，不提供不安全兼容路径。Python 3 已是既有安装依赖，不新增服务、软件包、状态 schema 或加密格式。

本能力继续 dormant：不接入 v4 菜单、在线更新流程、入口远程编排或任何服务器，不改变现有服务器可见行为。

## 回退

撤销匿名 builder、针对性测试和本文档，重新生成单脚本即可完成代码回退。由于功能未接入运行流程，回退不涉及用户状态、迁移包、receipt、服务或服务器数据。
