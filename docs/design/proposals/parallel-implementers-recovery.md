# 多任务并行开发：恢复、迁移与验证（Proposal）

> 状态：**Proposal · 定稿候选，未定稿**。本文是 [parallel-implementers.md](parallel-implementers.md) 的续篇，两篇合读，未裁决项见主篇 §10。
> 关联：讨论与裁决理由的事实源是 [#190](https://github.com/ShiningRay/sebas/issues/190)。
> 本文职责：租约的写入点与故障恢复矩阵、单 coordinator 的防双实例、容量、暂停、迁移与必测场景。
> 本文合入只是设计快照入库，不代表设计定稿或排期批准。

## 1. 租约的写入点

租约记录的 `phase` 只对应写入点。崩溃恢复靠它定位中断在哪一步，再决定补哪一步。

| 进入阶段 | 写入序列，按序执行，任一步失败即停 |
|---|---|
| `claiming` | 写本地记录，含 `lease_id`、`base_sha`、`scope`；Q1 选 B 时再发租约评论并记下评论 id |
| `claimed` | 写 `agent:in-progress`，回读标签（Q1 选 B 时一并回读评论），记录置为 `claimed` |
| `pr_open` | worker 建 worktree 与 PR，回填 `worktree`、`pr`，记录置为 `pr_open` |
| `merging` | coordinator 取到队首，记录置为 `merging` |
| `released` | 远端 PR 已合并且 issue completed，移除标签，回读，记录置为 `released` |

两个异常态：`aborted` 表示认领写入未确认；`paused` 只用于「未建 PR 就暂停」，此时认领标签已按 implementer-loop.md §3.2 释放，记录独自承载暂停状态。已有 PR 的暂停不改 `phase`，由卡上的 `needs:human` 标签表达。

`plan` 对账时把 `paused` 的记录排除在在途租约之外，不占容量。恢复它要先确认暂停记录仍与卡的 issue、worktree 匹配，并且有空位。

## 2. 恢复原则

- 租约到期不等于可抢占。只有心跳过期，且进程、分支、worktree、远端标签与 PR 都能对账时才恢复。
- 幂等重入：每个写入点都可以重放。重放不产生第二分支、第二 PR、第二份租约凭据，不改动其他租约的记录。
- 不确定即 `invalid_plan`，整份 `plan` 拒绝输出。API 错误保留为错误，不转换成空结果。
- 现有的恢复分支原样保留：`aborted` 的两种处置、「已认领但缺本地运行记录」、记录的 issue 与远端认领冲突。

## 3. 故障矩阵

「与现状」列说明该处置是沿用、细化还是新增。

| 编号 | 故障 | 判据 | 处置 | 与现状 |
|---|---|---|---|---|
| F1 | 写本地记录后崩溃，标签未写 | 记录 `claiming`，远端无标签 | 认领未成立，重走 claim。Q1 选 B 时按 `lease_id` 检索该 issue 的租约评论：有就复用并补记评论 id，没有才发 | 细化：现为笼统的「回读补全」 |
| F2 | 标签已写，回读前崩溃 | 记录 `claiming`；远端有标签，凭据的 `lease_id` 等于记录 | 认领成立，补全记录为 `claimed` | 沿用：`resume_issue` 回读补全 |
| F3 | 标签写成功但回读失败 | 记录 `aborted`，`label_written=true` | 远端状态未知，`invalid_plan`，人工核对 | 沿用 |
| F4 | 写标签即失败 | 记录 `aborted`，`label_written=false` | `invalid_plan`。`label_written=false` 只说明标签没写成：Q1 选 A 或 B 时凭据先于标签写入，要先对账并把它置为 `released`，确认再无远端变更，才删记录重新认领 | 细化：现在直接提示删记录重认领 |
| F5 | worker 进程消失 | 心跳过期；同机且 pid 不存活；worktree 与分支同记录一致 | `resume_issue`，沿用原 worktree | 细化：现在没有心跳，只能靠下一次运行发现 |
| F6 | 租约属于另一台机器 | 凭据的 `host` 不是本机 | 不是本 coordinator 的租约，不接管，占着容量 | 新增；Q1 选 C 时不可见，按 F7 处理 |
| F7 | 有标签，没有有效凭据 | 远端带 `agent:in-progress`，本地无记录，GitHub 侧无有效凭据 | 所有权不明，`invalid_plan` | 沿用：「已认领但缺本地运行记录」 |
| F8 | 记录与远端认领不是同一张卡 | 记录的 `issue` 不等于带标签的卡 | `invalid_plan` | 沿用 |
| F9 | 同一张卡有两份有效凭据 | 扫到两条 `state` 不是 `released` 的租约 | `invalid_plan`，全仓停止认领 | 新增；只有 Q1 选 A 或 B 时检得出 |
| F10 | PR 已建，记录未回填 | 快照里 PR 关联本卡，分支等于租约分支 | 回填 `pr`，续做 | 细化：现在按 `closing_issues` 推断，不比对分支 |
| F11 | 别的 PR 关联了本卡 | PR 分支不等于租约分支，或 PR 关联多张卡 | 不是本 worker 所建，`invalid_plan` | 细化：「关联多张卡」文档已要求，代码未见判定 |
| F12 | PR 已合并，unclaim 中途失败 | PR 已合并，issue completed，Evidence 已是 `merged_into_main: true` | 重跑 `unclaim`。标签已移除时按已释放收尾并补写记录。Q1 选 A 或 B 时，收尾前先核对 GitHub 侧凭据的 `state`，不是 `released` 就先改为 `released`，核对不了则 `invalid_plan`；选 C 时没有凭据可核对 | 细化：现在这种情形返回 `refused`，要改成幂等；另要求 Evidence 已升级，选 A 或 B 时还要求凭据已释放 |
| F13 | 合并后 main 上的 CI 被下一次合并取消 | 合并提交的 CI 结论为 `cancelled`，Evidence 仍是 `merged_into_main: false` | 重跑被取消的那次 CI run：成功后升级自动触发，或 dispatch 补登记。重跑仍失败就转人工手工登记 | 新增 |
| F14 | worker 越界写 | PR 的变更文件不在租约 `scope` 内 | 本租约转 `needs_human`，停止新认领 | 新增 |
| F15 | coordinator 在合并步骤中途崩溃 | 记录 `merging` | 重读远端。已合并：Evidence 未升级就先续等 main CI 成功与升级，必要时按 F13 补救，升级后才走 F12。仍 open：从归属校验与 `verify merge --pre` 重来。读不到：`invalid_plan` | 新增 |

F13 是从 [ci.yml](../../../.github/workflows/ci.yml) 的 `cancel-in-progress: true` 与 [evidence-register.yml](../../../.github/workflows/evidence-register.yml) 的成功条件推出来的。
登记脚本的 `resolve_checks_url` 只认 merge commit 自己的成功 CI run，所以 dispatch 不能代替重跑。处置栏里的补偿路径还没有实测。

## 4. 单 coordinator 与防双实例：Q2

首期只允许一个 coordinator 进程，并且只在一台机器上运行。同一台机器上出现两个，靠本地锁在认领之前拦下；两台机器各跑一个，首期只能事后检出，见下文。

- **本地锁**：`.sebas-agent/coordinator.lock`，用 `File::CREAT` 加 `File::EXCL` 原子创建，内容是 `coordinator_id`、`host`、`pid` 与创建时间。`coordinator_id` 标识一台机器上的一个 coordinator，跨重启稳定，不是进程号。不用 `flock`。
- **拿不到锁时**读出持有者再判。同机且 pid 存活：退出码 2，不重试。同机且 pid 不存活：过了宽限期才接管，并留下接管记录。机器不同：不接管，转人工。
- **首期只允许一台机器担任 coordinator**。本地锁只管一台机器，两台机器各持各的锁时互不知情。这条约束靠配置强制：coordinator 身份在仓库配置里只登记一个（主篇 S2），启动时本机不是那个身份就拒绝启动。Q1 选 C 时没有 GitHub 侧身份可查，这条约束只能靠约定。
- **GitHub 侧兜底**（Q1 选 A 或 B 时才有判据）：认领前重扫所有带认领标签的卡的凭据，`coordinator_id` 不是自己就拒绝认领，再按 F5、F6 处置。这是事后检测，不是互斥：两台机器都在对方写入前完成扫描，仍可能同时认领，要靠 F9 在下一轮对账时拦下。跨机器的原子互斥不在首期范围。
- **coordinator 日后移入 Actions**：用 `concurrency` 组 `sebas-coordinator` 加 `cancel-in-progress: false`。Actions 与本地同时启用不在首期范围。

Q2 尚未回答的部分：单 coordinator 是否足够。已知短板是 coordinator 所在机器离线时全部在途租约停摆，因为 worker 与它同机。跨机接管只有在 Q1 选 A 或 B 时才有判据，留待后续。

## 5. 容量与轨：Q3

- 默认 1。没有显式配置时，任何机器上的行为都与现状一致。
- 上限不写死在代码里。建议放进 `.github/agents.yml` 的新键，经 PR 评审才看得到改动；没有这个键就是 1。
- 是否另按 CI 配额、模型费用、本机资源设硬上限，待裁决。
- 容量按轨声明，没有声明容量的轨不调度。主线之外启用哪条并行轨、由谁启用，待裁决（主篇 §10.2）。

## 6. 暂停与超时：Q9

- `needs:human` 与 `agent:resume` 作用于单卡。带标签的租约停下，其余租约与候选照常。
- 已有 PR 的暂停保留归属，仍占在途名额。未建 PR 的暂停保存 worktree、释放认领标签，不占名额，记录保留供对账。
- 全仓 pause 是显式动作。`plan` 遇到它只输出 `paused` 与原因，不认领，不合并。
- 哪些情况必须升级为全仓 pause（共享契约变更、凭证风险、main 回归）由 Maintainer 定义。可自动触发的候选只有一条有代码判据：合并后 main 上的 CI 失败。
- pause 的载体待裁决（主篇 S4）：本地标志文件，或 GitHub 上可见的标签。心跳宽限期的取值在试点期测定。

## 7. 兼容迁移：Q10

| | 排空后切换 | 搬迁旧记录并双读一个版本 |
|---|---|---|
| 做法 | 升级工具前先让在途卡走完；没有在途卡时删除 v1 记录 | 把 `.sebas-agent/run.json` 搬到 `runs/<issue>.json`，工具对两种路径都读，一个版本后删旧路径 |
| 迁移期能否并行 | 否，容量固定为 1 | 否，容量固定为 1 |
| 旧记录由谁确认 | 不需要确认 | 活动中的 v1 记录缺 `base_sha`、`scope`、`lease_id`，须人工确认后才能搬 |
| 代价 | 升级要等在途卡收口，长寿命 PR 会拖住升级 | 多一段一次性的搬迁代码与一个版本的双读分支 |
| 立场 | #190 未提 | Triager 建议 |

两种做法都不允许迁移期并行。无论选哪种，`runs/` 里出现 schema 不是 2 的记录即 `invalid_plan`。

## 8. 必测场景

### 8.1 纯函数测试

固定快照，minitest，沿用 `tools/test_sebas_process.rb` 的做法。

1. 容量为 1 且快照里没有暂停卡时，`plan` 的首选候选与 `next` 的 `claim_issue` 恒等，对现有全部选卡用例成立。有暂停卡的快照单列，两者的差异只允许出现在 Q9 的暂停语义上。
2. 容量为 N：候选按 `order` 稳定排序；`order` 重复与依赖成环仍 `invalid_plan`。
3. 依赖冻结：候选依赖在途卡时进 `excluded`，原因是前置仍 open。
4. scope：重叠的候选被过滤，原因写明对方卡；非法 scope 值 `invalid_plan`；缺 scope 的处理随 Q4 的裁决。
5. 逐租约动作：`wait` 的租约不占算力；一张租约 `needs_human` 不影响另一张；任一租约 `invalid_plan` 则整体拒绝；归属不符的租约即使检查全绿也不得给出 `merge_ready`。
6. 租约唯一性：两张卡共用 `branch`、`worktree` 或 PR 号即 `invalid_plan`；PR 关联多张卡即 `invalid_plan`。
7. 队列：`merge_ready` 按先后入队；`verify_queue.depth` 正确。
8. 锁：第二实例拿不到锁，退出码 2；残锁按存活、死亡、异机三种判据处置。
9. 写守卫：Q1 选 B 时，新增的写意图逐条断言放行形态，其余命令仍被拦截。
10. 迁移：v1 记录、schema 不是 2 的记录、迁移期容量恒为 1。
11. 租约评论：评论已发出而评论 id 未落盘时崩溃，恢复按 `lease_id` 复用既有评论，不重发。
12. 合并后崩溃：恢复不得跳过 main CI 成功与 Evidence 升级直接释放租约。
13. 合并绑定：head 与已核验的提交不一致时合并被拒，流程重做核验后用新的 head 绑定。Q1 选 A 或 B 时，标签已删而凭据未释放的 F12 先释放凭据再补写记录；选 C 时不因缺凭据而 `invalid_plan`。

### 8.2 故障注入

在执行器层逐条制造 §3 的 F1 到 F15，核对处置栏，并确认没有产生第二分支、第二 PR，没有改动其他租约的记录。重点五项：

- 在认领后、PR 创建后、合并后分别杀进程再重启。这是 implementer-loop.md §6 已有的要求。
- 两张 PR 相继合并，复现 F13。结果决定主篇 §7.3 的裁决：补偿路径可用就放宽，否则维持串行到 Evidence 升级。
- `update-branch` 之后 head 变化：只有同步提交时结论保留，含冲突解决提交时失效。
- Windows 与 macOS 各跑一遍锁、原子重命名与路径分隔。
- 动手前抽查存量 PR 的 head 分支名，确认与 `feat/<issue>` 的约定一致；不一致就放宽为「以记录回填的分支为准」。

### 8.3 试点观察

阶段 2 期间记录三类数据，作为后续裁决的输入：

- 每次认领与合并的人工批准耗时。
- 合并队列的驻留时长，以及每张 PR 因 BEHIND 重跑 CI 的次数。
- main 上 CI 的实际耗时。

## 9. 未核实项

- GitHub 原生 merge queue 是否适用于本仓库。
- main 上 CI 的实际耗时；本文只有 `ci.yml` 的超时上限。
- F13 的并发合并复现，以及它的补偿路径。
- 锁、原子重命名与路径分隔在 Windows 上的行为。
- 存量 PR 的 head 分支名是否都符合 `feat/<issue>`。
- 两台机器同时认领的竞态：首期只有配置约束与事后检测，没有做并发实测。
