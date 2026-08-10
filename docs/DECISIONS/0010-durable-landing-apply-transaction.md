# ADR 0010：落地 apply 持久事务与下一请求恢复

- 状态：已接受，持久恢复与启动门禁保持 dormant
- 日期：2026-08-07
- 关联：[ADR 0007](0007-landing-secret-and-apply-protocol.md)、[ADR 0008](0008-restricted-landing-agent-and-rollback.md)、[ADR 0009](0009-restricted-landing-channel-installation.md)、[Issue #208](https://github.com/DTB201/sb-user-manager/issues/208)

## 背景

ADR 0008 原有 apply 引擎能在普通命令失败和 HUP/INT/QUIT/TERM 时用内存中的临时快照回退，但 SIGKILL、内核崩溃或断电不会执行 trap。若进程在多个运行文件、防火墙、服务重启与 receipt 提交之间停止，下一次调用无法证明应保留新状态还是恢复旧状态；只依赖 `/tmp` 快照也无法在重启后继续恢复。

落地 apply 因此必须先把恢复依据持久化，再修改任何运行态，并用明确终态区分“回滚旧状态”与“保留新状态”。本决定只补齐下一次 apply 请求触发的恢复，不改变 v4 菜单、状态 schema、迁移格式或服务器可见行为。

## 持久事务目录

每台落地只允许一个固定事务目录：

```text
/var/lib/sb-user-manager/landing-apply-transaction/
  transaction.id
  journal.json
  .journal.next
  cleanup.started
  .cleanup.next
  apply.json
  manifest.sha256
  config.json
  check-config.json
  gateway-ca.crt
  gateway.crt
  gateway.key
  landing.nft
  nft.rollback
  receipt.base.json
  receipt.next.json
  mutation.started
  runtime.drift
  service.restart-attempted
  nft.apply-attempted
  nft.rollback-attempted
  snapshot/
  receipt-snapshot/
  .validation/
```

目录必须是 root 拥有的 `0700` 普通目录，内部文件必须是 root 拥有的 `0600` 普通文件；符号链接、未知类型、组或其他用户可写、权限或所有者漂移全部失败关闭。生产路径不能用环境变量改写该位置，测试模式才允许映射到隔离系统根。

`journal.json` 不保存秘密，并且只允许以下字段：

- `schema_version`：固定为 1；
- `role`：固定为 `landing-apply`；
- `transaction_id`：随机 128 位、即 32 位小写十六进制事务 ID；
- `landing_id`、`revision`、`content_sha256`：绑定本次 package 的身份和内容；
- `phase`：只允许 `active`、`committed` 或 `rolled_back`。

`transaction.id` 是独立生成、先于 journal 持久化的 32 位小写十六进制事务身份；它本身也进入 `manifest.sha256`。任何 journal（包括原子替换用的临时 journal）的 `transaction_id` 都必须与该文件逐字一致。只改 journal、只改 identity，或连同其他受摘要保护材料发生任何不一致时都失败关闭，不能用被篡改的 ID 清理目标目录旁的临时文件。

`nft.rollback` 是在首次运行态变更前生成并纳入 manifest 的固定回滚批次：首行只允许删除本项目固定表，旧表存在时后续内容必须逐字等于持久 nft 快照。恢复不能临时拼接或从 journal 接受任意 nft 命令。

读取实时 nftables 表时必须启用稳定的数字化输出，禁止让 `/etc/services` 把端口转写成 `ssh`、`http`、`https` 等服务名；快照、候选校验与恢复判定必须使用同一种表示。

AnyTLS 密码、TLS 私钥和完整 package 只能存在于事务目录内的 `apply.json`、候选或快照，不得进入 journal、argv、返回 JSON、日志、诊断或迁移包。journal 与固定代码共同决定目标路径，恢复流程不得从 journal 读取任意文件系统路径。

## 持久阶段标记

除 journal 外，事务目录允许以下五个运行阶段标记。它们都必须是 root 拥有、权限为 `0600` 的空普通文件；标记含义只由固定文件名表达，不能写入秘密、路径或动态状态。创建标记时必须先同步标记文件，再同步事务目录，只有两次同步都成功后才能执行它所保护的下一项不可分割动作。

- `mutation.started`：在创建或改动运行目录、停止服务、替换运行文件等任何运行态变更前创建并同步，表示事务已经越过“只准备、未改运行态”的边界。
- `nft.apply-attempted`：在执行候选 nftables 规则前创建并同步，表示实时表可能是旧表、候选表或命令中断产生的状态。
- `service.restart-attempted`：在停止 sing-box、开始本次服务转换前创建并同步，表示 systemd 状态可能处于旧稳定态、已停止状态或启动/停止中的过渡态。
- `nft.rollback-attempted`：在回滚实时表前创建并同步；旧表存在时，删除候选表与载入旧表必须放在同一个 nftables 批次中原子提交。
- `runtime.drift`：运行态检查发现无法立即解释的漂移时创建并同步，作为失败关闭和保留现场的证据。它不能因为下一次请求到来就直接删除；只有重新校验运行文件与目录仍为旧值或候选值、实时 nftables 为旧值、候选值或有 `nft.rollback-attempted` 佐证的暂时缺表、且服务状态仍在允许集合内，才能删除该标记并再次同步事务目录，然后继续回滚。

`cleanup.started` 不是运行阶段标记，而是终态清理凭证。它是原子写入并同步的单份严格 JSON，固定绑定 `transaction.id`、终态 phase 以及当时 `journal.json` 的 SHA-256；`.cleanup.next` 只用于同目录原子替换。`active` 事务出现任一清理文件都失败关闭。journal 尚在时，清理凭证不能放宽对完整 payload、摘要、运行态或上述五个阶段标记的核验；journal 删除后，它只授权删除这一个固定事务目录里的已验证清理残留。空文件、字段漂移、权限漂移、符号链接、超长内容或拼接多份 JSON 均不构成授权。

`mutation.started` 不存在时，恢复只接受“第一次运行态修改尚未开始”：其余四个阶段标记必须全部不存在，运行文件、目录、实时 nftables、服务和 receipt 必须与快照旧状态一致。满足这些条件后可直接推进 `rolled_back` 并清理，不得为了恢复而重启服务或重写运行态；任一后续标记存在或旧状态不一致都失败关闭并保留现场。

服务快照只记录稳定的 `active`、`inactive` 或 `failed`。没有 `service.restart-attempted` 时，恢复要求当前服务仍匹配快照类别；标记存在时，才允许把 `active`、`activating`、`deactivating`、`inactive` 或 `failed` 视为一次已开始重启的已知中间状态，随后恢复到快照类别（`active`，或 `inactive`/`failed`）。未知 systemd 状态一律拒绝自动恢复。

阶段标记还必须符合单向关系：`nft.apply-attempted` 只能出现在 `service.restart-attempted` 之后，`nft.rollback-attempted` 只能出现在 `nft.apply-attempted` 之后。缺少前置标记却出现后置标记属于损坏现场，不能自动清理或恢复。

只要终态 journal 仍存在，就必须保留并验证完整 payload、manifest、快照和同一阶段标记图，即使 `cleanup.started` 已经持久化也不例外：`committed` 必须同时保留服务转换与 nft apply 标记且不得出现 rollback 标记；`rolled_back` 一旦出现 apply 标记就必须同时出现 rollback 标记。`runtime.drift` 不能进入任何可自动清理的完整终态现场。

## 准备与提交顺序

在第一次替换运行文件、修改实时 nftables、改变服务或写 receipt 前，apply 必须完成：

1. 严格校验 package、当前通道代际、运行目标与 receipt；
2. 在持久事务目录保存 package、全部候选、旧文件存在状态与内容、旧实时 nftables 表、旧服务状态和旧 receipt；
3. 校验所有候选与快照的类型、权限和内容摘要；
4. 同步每个文件及其目录，并原子写入、同步 `phase=active` 的 journal。

上述任一步失败都不能开始运行态修改。越过 `mutation.started` 后，正向 apply 必须先确认旧服务与旧防火墙仍匹配快照，持久化服务转换标记并停止 sing-box；确认已停止后，才可原子替换运行文件、用单个 nftables 批次切换到候选规则，最后启动 sing-box 并执行服务与监听健康检查。运行文件在替换前同步同目录临时文件、替换后同步父目录。全部检查成功后才能推进 receipt；receipt 同样必须先同步临时文件，再原子替换并同步父目录。

新 receipt 完整持久化后，事务才能原子写入并同步 `phase=committed`。只有 `committed` 已确定持久，helper 才能把新 revision 报告为 `applied`；响应丢失后，入口以相同 revision 和相同内容重试会得到 `idempotent`，不能再次重启服务。

## 恢复方向

恢复只依据 journal 的三种 phase，不根据目标文件“看起来较新”或调用停止的位置猜测：

- `active` 是唯一非终态，一律恢复旧文件、旧实时 nftables、旧服务状态和旧 receipt。恢复过程可重复；完整核验旧状态后，原子写入并同步 `rolled_back`。
- `committed` 表示新运行态和新 receipt 已提交，只清理事务目录，绝不使用残留快照反向恢复。
- `rolled_back` 表示旧运行态已经恢复，只清理事务目录，绝不再次执行回滚。

对于 `active`，自动恢复的可解释边界是有限集合而不是任意“当前值”：每个受管运行文件和目录只能精确匹配持久快照旧状态或本事务候选状态；唯一额外允许的是，快照中不存在、目标权限为 `0755` 且由本事务创建的系统目录可以处于 `install -d` 在 `umask 077` 下留下的 `0700` 中间态，回滚只允许在目录为空时删除它。实时 nftables 只能匹配快照旧表、候选表，或仅在 `nft.rollback-attempted` 已持久化时暂时缺表。缺少该回滚标记的空表、第三种文件内容、其他目录状态或未知服务状态都属于外部漂移，必须保留事务现场并停止，不能覆盖。

候选终态的目录核验比回滚时的“已知状态集合”更严格：事务前已存在的普通系统目录保持其旧权限，新建普通系统目录必须为 `0755`，TLS 目录无论此前权限如何都必须精确为 `0700`。旧权限只是可回滚状态，不能被误认为已经成功应用的终态。

只要本事务已经尝试过服务转换，回滚就必须先把 sing-box 服务单元停止并确认其稳定状态为 `inactive` 或 `failed`，才可恢复文件和防火墙；停止失败时保留候选防火墙和完整事务现场，不得继续。旧实时表存在时，预生成的回滚批次必须在首次 mutation 前通过 nftables 检查模式验收；候选表删除与旧表恢复再使用这一个原子批次。旧文件、旧目录和旧防火墙全部恢复后，只有旧服务快照为 `active` 才重新启动服务。该顺序保证正向切换和回滚都不会在服务单元仍运行时移除入口端口防火墙。

终态清理中途再次崩溃时，下一次恢复继续清理。`active` 回滚中途再次崩溃时，journal 仍是非终态，下一次恢复从持久快照重复回滚。任何快照、候选、journal 或目标发生无法解释的类型、权限、摘要或身份漂移时，都保留完整事务现场并返回恢复失败，不覆盖外部变化，也不执行新 package。

终态清理必须先完整复核终态，再原子持久化 `cleanup.started`。在 journal 存在期间不得提前删除任何 payload、快照、回滚批次或阶段标记；随后先删除 `journal.json` 并同步事务目录。越过这一持久边界后，清理凭证必须继续保留，直到 payload、快照、回滚批次和全部阶段标记都已删除且该删除结果已经同步；随后才可删除 `cleanup.started` 并再次同步目录，最后删除 `transaction.id`、同步、删除空事务目录并同步父目录。若在 journal 删除后、清理凭证删除前中断，下一次请求只能凭一份结构与事务身份均严格有效的 `cleanup.started` 继续清理；若在凭证删除后中断，前一步同步保证现场至多只剩 identity 或不含 mutation 证据的安全残留，可以按无 journal 的严格规则收敛。绝不能在 payload 或阶段标记尚未确认删除落盘前删除清理凭证，不能先删 identity、留下无法绑定事务的 journal 或凭证，也不能让部分 payload 在 journal 尚存时伪装成“清理已经开始”。

## 同步失败与不确定性

持久事务把“命令成功”与“断电后仍存在”分开处理：

- 临时文件同步或原子替换失败时，旧目标仍是权威状态；操作返回失败并清理尚未替换的临时文件。
- 受管运行文件或 receipt 已替换但其父目录同步失败时，journal 仍为 `active`；当前调用不能报告成功，必须按非终态规则恢复旧状态，恢复本身失败则保留现场。
- `committed` 或 `rolled_back` journal 已原子替换但事务目录同步失败时，内存中可见的是新终态，断电后的目录项却不确定。此时必须保留现场并报告不确定；不得猜测终态是否已经持久，也不得在当前调用中选择相反方向。

下一次恢复只读取当时实际存在且通过严格校验的 journal：看到 `active` 就回滚，看到两个终态就只清理。这样不会用一次新的未同步写入掩盖前一次同步失败。

## 完整性边界与威胁模型

事务目录的固定位置、root-only 类型与权限、独立事务 ID、严格单文档 schema、manifest 摘要、journal 与清理凭证绑定，以及运行态交叉核验，用于发现损坏、截断、单文件替换和非一致的 phase/身份/权限/符号链接漂移，并在这些情况下失败关闭、保留现场。这里不声称能抵抗已经取得落地 root 权限、并能同时重写 journal、事务身份、manifest、payload、清理凭证及实时运行态的攻击者；在没有独立签名密钥、可信硬件或外部账本的条件下，本地代码无法为这种完全一致的特权重写提供真实性根。该边界不影响对进程中断、断电和非一致篡改的恢复保证。

## 锁与通道交互

apply 恢复和新请求继续遵守固定锁序：输入锁、通道 shared lock、receipt 锁。恢复必须在相同锁保护下完成；恢复失败时不允许校验或执行后续新 package。

通道安装、入口 IP 或公钥轮换、卸载持有通道排他锁。只要固定 apply 事务路径存在——包括不安全类型或符号链接——通道操作就在进入变更 callback 前失败，且不得修改、移动或删除 apply 恢复现场。通道层不猜测 apply phase，也不代替 apply helper 恢复；由下一次 apply 请求完成恢复后，通道运维才能继续。

## 启动恢复门禁

[ADR 0011](0011-landing-startup-recovery-gate.md) 在本决定之上增加固定 systemd 启动门禁：冷启动恢复先收敛持久事务并恢复固定 nftables 表，成功后才允许 sing-box 启动；失败会阻止服务并保留证据。普通 apply 仍使用本决定的在线恢复语义，启动入口则使用“不启动 sing-box”的冷恢复语义。

ADR 0008–0011 的模块继续保持 dormant：不接入 v4 菜单、入口自动编排或正式服务器，不宣称 production-ready。正式启用前仍须完成真实重启与断电故障注入验收。

## 回退

在 dormant 阶段，代码层可撤销本决定对应模块、测试和文档并重新生成单脚本。若测试环境已有持久事务目录，必须先由同版本恢复逻辑把它推进到 `committed` 或 `rolled_back` 并完成安全清理；不得直接删除 `active`、未知或校验失败的恢复现场。
