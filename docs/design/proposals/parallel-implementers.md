# 多任务并行开发：每卡独立租约与集中合并收口（Proposal）

> 状态：**Proposal · 定稿候选，未定稿**（2026-11-24 整理自 issue #190 及其 Triager 研判，当前 `proposal:needs-design`）。
> 关联：讨论与裁决理由的事实源是 [#190](https://github.com/ShiningRay/sebas/issues/190)；单卡现状契约见
> [implementer-loop.md](../process/implementer-loop.md)；恢复、迁移与验证见续篇 [parallel-implementers-recovery.md](parallel-implementers-recovery.md)。
> 本文职责：把 #190 的建议方案细化到可实现、可验证的程度，并列出裁决所需的选项与代价。
> 本文合入只是设计快照入库，不代表设计定稿或排期批准；工作包拆分由排期指令另行决定。

## 1. 背景与问题

#190 指出的问题是排期允许并行、实现只允许串行：PR 等 CI 或 review 期间选择器返回 `wait`，其他已就绪且无依赖的工作包只能排队。

现状核实（2026-11-24，main `2ad28c6`，只读核对）。函数与常量名可直接定位；行号随版本漂移，不写。

| 约束点 | 位置 | 现行为 |
|---|---|---|
| 选卡全仓单卡 | `Policy::Selection.select_action` | 快照内 open 且带 `agent:in-progress` 的卡多于一张即 `invalid_plan` |
| 认领拒第二张 | `CLI#claim_blocker`、`CLI#run_resume` | 存在另一张活动认领即拒绝 |
| 暂停即全局停 | `Policy::Selection.select_action` | 任一 open 卡带 `needs:human` 即返回 `needs_human`，不再选新卡 |
| 在途 PR 即全局等待 | `Policy::Selection#classify_pr` | 自有 PR 有未完成检查或状态未知时返回 `wait`，不看其他卡 |
| 运行记录单例 | `RunRecord::DEFAULT_PATH`、`RunRecord::FIELDS` | `.sebas-agent/run.json`，schema 1；无 worker、租约、scope、心跳字段 |
| 写能力仅标签 | `CommandRunner::ALLOWED_WRITES` | 写意图白名单只有 `add_label`、`remove_label` |
| 无评论读写 | `GithubGateway` | 不写评论；快照不含 issue 评论，只按 Evidence 的 `source_ref` 回查被引用评论 |
| 认领写路径 | `CLI#run_claim` | 本地记录 `claiming` → 写标签 → 回读 → `claimed`；未确认则 `aborted` 并记 `label_written` |
| 候选已算好 | `Policy::Selection#select_new_card` | 已按 milestone 产出有序候选与逐卡排除原因，但只返回 `order` 最小的一张 |
| 无只读多候选入口 | `CLI#dispatch` | 选卡入口只有 `next`；`plan` 是 `release` 的子命令 |
| 并行轨不参与选卡 | `Policy::Milestones.active` | 只计算 `track=main` |

文档层是同一口径：[implementer-loop.md](../process/implementer-loop.md) §1 不变量 1、[implementer.md](../process/implementer.md) 的「串行原则」。[development-workflow.md](../process/development-workflow.md) §2 的「并行轨」指 milestone 的 `track=parallel`，与实现并发无关。

可续用的既有资产有四件，本设计在其上推广，不另造对账机制：`run_claim` 的写后回读与不确定即 `aborted`、`select_new_card` 的候选与排除原因、`Dependencies.evaluate` 的逐卡依赖判定、`unclaim` 的「PR 已合并且 issue completed 才释放」。

## 2. 目标与非目标

### 2.1 目标

以不变量表述，每条都要有测试锁定。

| 编号 | 不变量 |
|---|---|
| I1 | 一张卡至多一个有效租约、一个 worker、一个分支、一个写入 worktree、一个活动 PR；一个 PR 只关联一张卡 |
| I2 | 调度与认领分离：只读 `plan --capacity N` 在同一冻结快照上给出有序候选与排除原因；写操作只由 coordinator 串行执行 |
| I3 | 等待不占算力：某卡等 CI 或 review 时，coordinator 继续处理其他租约 |
| I4 | 合并串行：每个 PR 独立经过 `verify merge --pre`、独立核验与终验；worker 不执行合并 |
| I5 | 崩溃、写入未确认、worker 失联均可对账恢复；无法确定所有权即 fail-closed，不接管，不重复开工 |
| I6 | 容量为 1 时行为与现状等价：`plan` 的首选候选恒等于 `next` 的选择 |

### 2.2 非目标

- 不改 Sebas 产品运行时的调度与并发语义。产品侧 fork/join 见 [fork-join-semantics.md](fork-join-semantics.md)。
- 不改分支保护、必检项、auto-merge 与 Evidence 的授权模型；不为并行扩大 token 或 workflow 权限。
- 不引入数据库、消息队列或常驻调度服务，仍用 Ruby 标准库与 `gh`。
- 不自动跨轨或跨 milestone 填满容量，保持 implementer-loop.md §1 不变量 6。
- 不做远程执行后端（Actions 多 runner），列为后续工作。
- 不改「排期并行」的含义：active 主线唯一、并行轨上限 2 条不变。

## 3. 总体结构

```
GitHub 快照 ─► Plan（只读）：leases / candidates / excluded / verify_queue
                            │
              coordinator（单实例，持本地锁，唯一写者）
                claim ─► 派发 ─► 合并队列 ─► unclaim
                            │
            ┌───────────────┴───────────────┐
         租约 #41                      租约 #43
         worker：等 CI，不占算力        worker：在自己的 worktree 编码
```

| 部件 | 职责 | 形态 |
|---|---|---|
| Plan | 算候选、算每张租约的下一步动作、报排除原因与队列深度 | `policy/` 下的纯函数，无副作用 |
| Lease | 一张卡的所有权凭据与执行上下文 | 本地 `.sebas-agent/runs/<issue>.json`，加 GitHub 侧凭据（§5，Q1 待裁决） |
| Worker | 实现一张卡：编码、修 review 与 CI、备验收材料 | 一个 Implementer Harness 实例，只持一个租约 |
| Coordinator | 唯一写者：claim、派发、合并、unclaim | 串行执行 `sebas-process` 写命令的进程 |

- coordinator 每轮做三件事：跑 `plan`、执行其中不需要等待的动作、等事件或定时后再跑。触发方式沿用 implementer-loop.md §5 的口径：单进程 runner，cron 触发时共用同一把锁。
- worker 是一次 Harness 运行，拿到租约后跑到本段工作结束即退出：提了 PR、修完一轮 review 或 CI、或转 `needs_human`。等待期间没有 worker 进程。
- `next` 不改。它遇到多张 `agent:in-progress` 时仍返回 `invalid_plan`，旧会话误入并行环境会被拦下。

角色归属是建议，未裁决：不新增第 7 个角色。Plan 与合并队列是 `tools/sebas-process` 的确定性部分，worker 就是现有 Implementer，coordinator 是执行这些命令的进程。

## 4. 调度与认领分离：只读 `plan`

```sh
ruby tools/sebas-process plan --capacity 2   # 只读：不写 GitHub，也不写本地记录
```

- 输入与 `next` 相同的快照，外加 `runs/` 下的全部租约记录。`--snapshot` 离线可用。
- 同样输入必得同样输出。退出码沿用现有约定：可计算为 0，全局 `invalid_plan` 为 1，用法错误为 2。
- `--capacity` 省略时取配置，配置也缺则取 1（§10.2）。

计算顺序：

1. 全局合法性：milestone 元数据（`Milestones.normalize`）。非法即整体 `invalid_plan`，与现状一致。
2. 逐租约对账：对每份租约记录算一个动作（§4.1）。任一租约 `invalid_plan` 即整体拒绝，不确定的所有权不能被其他租约的进度掩盖。
3. 逐轨算新卡候选：复用 `select_new_card` 的过滤与排序。已有 open PR、`needs:human`、`metadata:invalid`、已认领、缺 Automation、`tracking` 与 `manual`、依赖未满足，各有排除原因。
4. 冲突预算过滤：候选之间、候选与在途租约之间做 scope 重叠检查（§6）。被过滤的候选进 `excluded`，原因写明与哪张卡重叠。
5. 补位：在途租约数小于 `capacity` 时，按 `order` 取候选填满空位。

依赖在认领时冻结，不需要新机制：候选的 `depends_on` 指向在途卡时，该卡尚未 `completed`，`Dependencies.evaluate_issue_dependency` 已判 `blocked`。要做的是用测试锁定「同批不得互相依赖」。

### 4.1 每张租约的动作

把 `select_action` 里「全局只看一张」的分支，改成对单张租约求值。条件按序判定。

| 条件 | 动作 | 与现状的差异 |
|---|---|---|
| 记录 `phase=aborted` | `invalid_plan`；`label_written=true` 时需人工核对远端 | 无 |
| 本卡带 `needs:human` 与 `agent:resume` | `resume_issue`：核验说明后移除两标签 | 无 |
| 本卡带 `needs:human` | `needs_human`，只作用于本卡 | 不再阻塞其他租约 |
| 无 PR，记录与远端认领一致 | `resume_issue`，沿用原 worktree | 无 |
| 有 PR：失败检查、未解决 thread、BEHIND | `resume_pr` | 无 |
| 有 PR：检查未完成或状态未知 | `wait`：本卡等待，释放其算力 | 不再是全局停止 |
| 有 PR：CLEAN 且 thread 清零 | `merge_ready`，进入合并队列 | 新动作，替代现有「已 CLEAN；核验后再合并」的 `resume_pr` |
| 记录与远端认领不是同一张卡 | `invalid_plan` | 无 |
| PR 的分支不是租约分支，或 PR 关联多张卡 | `invalid_plan` | 分支比对是新增；「关联多张卡」implementer-loop.md §3.1 已要求，`policy/selection.rb` 未见对应判定 |

### 4.2 输出

```json
{
  "ok": true,
  "observed_main": "<commit-sha>",
  "capacity": 3,
  "leases": [
    {"issue": 41, "action": "wait", "reason": "PR #60 等待 CI"},
    {"issue": 43, "action": "merge_ready", "reason": "PR #62 已 CLEAN 且 thread 清零"}
  ],
  "candidates": [{"issue": 45, "order": [4, 2, 1], "scope": ["src/store/"]}],
  "excluded": [{"issue": 46, "reason": "scope 与在途 #43 重叠：src/admin/"}],
  "verify_queue": {"depth": 1, "ready": [43]},
  "metadata_gaps": []
}
```

- `leases` 与 `candidates` 合计不超过 `capacity`。
- `excluded` 与 `metadata_gaps` 沿用现有字段与原因文案；`next` 的 `claim_issue` 输出不变。

## 5. per-issue lease

### 5.1 本地租约记录（schema 2）

路径 `.sebas-agent/runs/<issue>.json`。原子写入沿用 `RunRecord#save`（临时文件加 rename），仍不保存凭据。

| 字段 | 写入时机 | 用途 |
|---|---|---|
| `schema` | 常量 2 | 与 v1 单例记录区分 |
| `issue`、`branch`、`base_sha` | claim | 对账基准：哪张卡、哪个分支、从哪个提交切的 |
| `worktree`、`pr` | worker 回填 | 对账基准：哪个目录、哪个 PR |
| `lease_id` | coordinator 生成；Q1 选 B 时另存评论 id | 关联 GitHub 侧凭据 |
| `coordinator_id`、`host` | claim | `coordinator_id` 标识一台机器上的一个 coordinator，跨重启稳定；恢复时判断归属 |
| `worker_id`、`pid` | 派发 | 恢复时判断 worker 进程是否还在 |
| `scope` | claim 时从 Automation 冻结 | 冲突预算与越界检测的基准 |
| `phase`、`attempts`、`label_written` | 各写入点 | 定位中断位置 |
| `claimed_at`、`last_heartbeat_at` | 各写入点 | 心跳过期判定 |

现状缺口一并补上：`run_claim` 只写 `issue`、`branch`、`phase`、`attempts`；`base_sha` 在 `FIELDS` 里，工具内却没有写入点。schema 2 由 coordinator 在认领时写入 `snapshot.main_sha`。

`phase` 只对应写入点，不表达「正在做什么」：`claiming` → `claimed` → `pr_open` → `merging` → `released`，异常态 `aborted` 与 `paused`。「下一步做什么」一律由快照推导（§4.1），不存进记录，避免本地状态与 GitHub 分叉。

### 5.2 GitHub 侧凭据：Q1 待裁决

本地记录只在一台机器上可见，而 implementer-loop.md §1 不变量 2 规定 GitHub 是事实源。「谁持有租约」因此需要一份 GitHub 上可读的凭据。三个候选位置：

- **A.** issue 正文里的 `lease` 代码块。
- **B.** 带 marker 的协调评论，comment id 即租约 id。
- **C.** 只有本地记录加 `agent:in-progress` 标签。

A 与 B 的凭据内容相同：`lease_id`、`issue`、`branch`、`base_sha`、`coordinator_id`、`host`、`state`、`claimed_at`。

| | A. 正文 `lease` 块 | B. 协调评论 | C. 仅本地记录与标签 |
|---|---|---|---|
| 唯一性 | `JsonBlock.one` 能查出多块，但正文可编辑，覆盖写就能恢复成「唯一」 | `state` 不是 `released` 的租约评论每个 issue 恰为一条，多于一条即 `invalid_plan` | 标签天然唯一；凭据本身无法跨机核对 |
| 作者绑定 | 无：块内字符串不是凭据 | 评论作者须在白名单，作者与正文都可回查，做法同 Evidence 的 `source_ref` | GitHub 侧没有作者可查 |
| 内容绑定 | 与正文其余部分同生共死 | 发出后只改一次：释放时把 `state` 改为 `released`；不承载心跳 | 记录可被本地进程改写 |
| 新增写能力 | PATCH issue 正文 | POST 评论，外加一次 PATCH 评论 | 无 |
| 与 Evidence 登记的关系 | 登记与升级都重读正文再整体 PATCH，没有并发写保护；租约块与 Evidence 块同在正文，有丢失更新的窗口 | 写入对象是评论，与正文回填互不覆盖 | 无交集 |
| 失效模式 | 正文被人工或 workflow 覆盖后所有权不可证 | 评论被删改，或标签与评论不一致 | 换一台机器即 `invalid_plan` |
| 立场 | #190 列为候选；Triager 不建议 | #190 列为候选；Triager 建议 | #190 的 Q1 列为候选，正文未展开；Triager 未评 |

三个选项共同的部分，无论怎么裁决都要做：`agent:in-progress` 保留为人类可见信号，并继续作为依赖判定的输入（`evaluate_issue_dependency` 靠它发现「已关闭但仍带认领」）。标签本身永不作为所有权证明；有标签而无有效凭据即 `invalid_plan`。

选 B 时的写入顺序。两步写入没有事务，顺序决定崩溃之后能否幂等补全：

```
写本地记录（claiming，含 lease_id）
→ 发租约评论，把评论 id 记入记录
→ 写 agent:in-progress，回读标签与评论
→ 记录置为 claimed；任一步失败则置 aborted 并记下已完成的写入点
```

评论先于标签：崩溃在两者之间时留下的是「有评论、无标签」，不会出现人类可见的「进行中」却没有所有权凭据。恢复按记录里的评论 id 续做，不重复发评论。

选 B 的代价有三项：`ALLOWED_WRITES` 新增 `post_comment` 与 `update_comment` 意图及命令形态，这是写守卫面的变更，要补 dry-run 守卫测试；`.github/agents.yml` 新增可登记租约的身份白名单，属安全边界变更，口径同 `trusted_bots`；每次对账多读认领卡的评论列表。

## 6. 隔离开发与冲突预算

- 每个 worker 从租约记录的 `base_sha` 建独立分支与 worktree。分支名沿用 `run_claim` 现状 `feat/<issue>`，靠名字唯一杜绝第二分支。
- worktree 路径记入租约，不得落在其他租约的 worktree 或用户工作目录内。
- worker 只持有自己这张卡的 issue、分支、worktree、PR。一个 worker 失败不清理其他 worker 的状态。
- `scope` 是调度预算，不是沙箱。越界靠事后检测，安全边界不依赖模型守约：推送前 worker 自查 `git diff --name-only <base_sha>..HEAD`；PR 进入合并队列前，coordinator 用快照里已有的 `pr.files` 再查一次。越界即本租约转 `needs_human`，并停止新认领。

### 6.1 `scope` 字段

Automation 块新增可选数组字段，值为路径前缀：

```json automation
{
  "schema": 1,
  "kind": "work_package",
  "order": [4, 2, 1],
  "depends_on": [],
  "external": [],
  "scope": ["src/store/", "spec/store/", "docs/design/spec/"]
}
```

- `automation_for` 目前只校验 `kind`、`order`、`depends_on`、`external`，不拒绝未知键。存量卡不加 `scope` 也不会被判非法。
- 新增校验：非空字符串数组；不含 `..`；不以 `/` 开头；尾部 `/` 归一。
- 冲突判定：两个 scope 里任一路径前缀互相包含即冲突。`src/` 与 `src/bus/x.cr` 冲突，`src/bus/` 与 `src/keys/` 不冲突。判定从保守，不猜测「同目录不同文件能否共存」。
- 共享文件靠声明进入预算：索引、`docs/design/plan/`、`.github/workflows/`、`src/store/schema.cr` 这类文件，谁要改谁就得写进自己的 `scope`，于是改同一文件的卡自然不并行。

### 6.2 是否强制：Q4 待裁决

| | 强制：缺 `scope` 不可并行 | 不强制：缺 `scope` 可人工确认并行 |
|---|---|---|
| 规则 | 缺 `scope` 的卡只在没有其他在途租约时才能认领 | 缺 `scope` 的卡经人工逐次确认后可与其他租约并行 |
| 对存量卡 | 容量为 1 时行为不变，不必补元数据；要并行才补 `scope` | 存量卡可直接并行 |
| 漏报面 | 漏写共享文件仍会漏报，但不会被「没声明」放大 | 安全边界取决于人的记性 |
| 立场 | Triager 建议；与 triager.md「不猜」的口径一致 | #190 原文列为可选项 |

### 6.3 CHANGELOG：Q4 的子项

[scribe.md](../process/scribe.md) §5 要求每个 PR 往 `[Unreleased]` 写一行。按 §6.1 的规则，任何两张在途 PR 都会在 `CHANGELOG.md` 上重叠，也就都不能并行。处置二选一，待裁决：

1. worker 照旧自写 CHANGELOG，把该文件排除出冲突预算，接受 `strict=true` 下后合并者 `update-branch` 时的文本冲突由 worker 解决并重跑 CI。
2. CHANGELOG 改由合并队列在合并时统一追加，worker 不改，PR 正文携带待追加条目。两张 PR 可以完全不重叠，但这改变了 scribe.md §5 的约定。

## 7. 等待、验收背压与集中合并

### 7.1 等待与容量

`wait` 只说明本卡在等异步事件。coordinator 收到某张租约的 `wait` 后不为其保留算力，转去处理其他租约或补位；事件到达后下一次 `plan` 自然给出新动作。

容量定义为在途租约的上限，等待中的租约也算在途：它不占算力，但占名额。这样合并队列的长度与待验收的 PR 数都被 `capacity` 封顶。

### 7.2 合并队列

worker 不合并。合并队列由 coordinator 串行处理，每个 PR 走完整条链才轮到下一张：

```
取队首（按进入 merge_ready 的先后）
→ 重读远端：PR 仍 open，租约与 PR 归属一致，head 与核验时一致
→ verify merge <pr> <issue> --pre，退出码 0
→ Verifier 核验与终验（独立进程），结论为「通过」
→ BEHIND 则 update-branch，等 CI 与 verify.yml 重跑
→ squash 合并，远端复核 MERGED
→ 等 main 上该合并提交的 CI 成功，Evidence 升级为 merged_into_main=true
→ unclaim，租约置为 released，下一张
```

链上有三处事实决定它必须这么长：

- **`strict=true`**（development-workflow.md §4）：main 每前进一次，其余在途 PR 全部转 BEHIND，各需 `update-branch` 加整轮 CI。并行的 PR 越多，队尾等得越久。
- **main 上的 CI 会取消前一次运行**：[ci.yml](../../../.github/workflows/ci.yml) 的并发组是 `ci-<ref>`，且 `cancel-in-progress: true`。上一张卡的合并提交 CI 没跑完就合入下一张，上一轮被取消。
- **Evidence 升级只由 CI 成功触发**：[evidence-register.yml](../../../.github/workflows/evidence-register.yml) 只在 CI run 结论为 `success` 时登记。上一轮被取消，该卡的 Evidence 停在 `merged_into_main: false`，后继卡一直 `blocked`，要人工 `workflow_dispatch` 补登记。

后两条是从 workflow 定义读出的事实，尚未做并发合并的实测复现，已列入必测场景。

### 7.3 合并串行化的强度：Q6 待裁决

| | 串行到 Evidence 升级完成 | 只串行合并操作 |
|---|---|---|
| 吞吐 | 每张 PR 占用一个 main CI 周期。`ci.yml` 里 spec 的超时上限 40 分钟、release-build 45 分钟；实际耗时未取 | 合并操作本身的时长 |
| Evidence 链 | 不断 | 需要补偿：重跑被取消的 CI，或 dispatch 补登记 |
| 风险 | 长寿命 PR 堵队 | 补偿路径未经故障注入验证 |
| 立场 | #190 建议集中合并 | #190 的 Q6 提出放宽留待实测后决定；Triager 未评 |

### 7.4 验收背压：Q7 与 Q8 待裁决

开发并行之后，验收若仍是单队列，加 worker 只会堆 PR。Triager 建议开发并行、合并与独立验收仍单队列，由 `plan` 报队列深度。两个选项：

- 验收串行：Verifier 核验与终验也由 coordinator 按队首逐张发起。实际容量上限等于 Verifier 吞吐。
- 验收并行、合并串行：核验与终验只读，可对多张 `merge_ready` 的 PR 并行发起，只有合并走队列。需另设 Verifier 并发上限，`有条件通过` 仍交 Maintainer。

Evidence 登记本身按 issue 与 PR 各写各的：登记脚本只改本 issue 的评论与正文块，跨 PR 的覆盖或错绑在结构上不会发生。跨 PR 的真实耦合是 §7.2 的后两条。

### 7.5 核验结论与 head 的绑定：新子项

`update-branch` 会改变 head。若规定「head 变则结论失效」，main 每前进一次都要重做语义核验，队列更长。建议规则，未裁决：结论绑定 PR 自有提交。新 head 相对旧 head 只多出同步 main 的合并提交时结论仍有效，但 CI 与 verify.yml 必须重跑；出现冲突解决提交或任何非同步提交即失效。无法证明只是同步提交时，按失效处理。

## 8. 分阶段启用

| 阶段 | 做什么 | 不做什么 | 进入下一阶段的证据 |
|---|---|---|---|
| 1 | 只读 `plan`，容量 1 | 不改任何写行为 | 多次运行的候选与排除原因与人工判断一致；首选候选与 `next` 恒等 |
| 2 | 双 worker 文档卡试点，目录不重叠 | 代码卡不并行 | 人工批准每次认领与合并；试点期无重复分支、重复 PR |
| 3 | 开放代码卡并行 | 不放宽合并权限 | 故障注入与跨平台测试通过，见续篇；容量默认仍为 1 |
| 4 | 自动合并沿用现有权限模型 | 不因并行放权 | 无 |

阶段 1 可以先于其余部分独立交付：它不改写行为，却把「这张卡为什么没被选」变成可观察的输出。

## 9. 备选方案

| 方案 | 不采纳的原因 |
|---|---|
| 多个会话各自 `claim` | 触发现有全仓锁；绕开锁则租约、运行记录、恢复都不一致 |
| 只把 `agent:in-progress` 上限从 1 改成 N | 没解决单例运行记录、并发认领、暂停恢复与合并竞态，只是把串行假设藏进更多故障路径 |
| 只按目录 scope 并行 | 声明会漏共享契约、生成文件与测试；只能做预算，替代不了租约与合并门禁 |
| 每条并行轨一个 Implementer | 同轨内无依赖卡仍不能并行；轨道数不是资源容量模型 |
| Actions 多 runner | 隔离好，但远程 worktree、恢复、成本与权限管理复杂；留作后续执行后端 |
| 维持串行 | 最稳妥，当前单卡容量未饱和时收益不明显。若裁决维持，只需补一句「人工多 worktree 不受自动调度支持」 |

## 10. 待裁决项

「立场」列记录 #190 原文与 Triager 研判的既有表态，不是结论。裁决请回 #190 的 thread，状态标签由 Triager 按证据维护。

### 10.1 须先裁决的四项

| 编号 | 问题 | 选项 | 裁决 |
|---|---|---|---|
| Q1 | 租约的 GitHub 侧凭据放哪 | A 正文块 / B 协调评论 / C 仅本地记录与标签 | 待定 |
| Q4 | `scope` 是否强制 | 强制，缺则不可并行 / 不强制，人工确认 | 待定 |
| Q4 子项 | CHANGELOG 写入时机 | worker 自写并接受同步冲突 / 合并队列统一追加 | 待定 |
| Q7、Q8 | 验收是否并行 | 验收串行 / 验收并行、合并串行 | 待定 |
| Q10 | 迁移方式 | 排空在途卡后切换 / 搬迁旧记录并双读一个版本 | 待定 |

### 10.2 可按默认值走、仍需确认的六项

| 编号 | 问题 | 建议默认值 |
|---|---|---|
| Q2 | 单 coordinator 是否足够 | 首期足够；防双实例见续篇 §4 |
| Q3 | 容量默认值与上限 | 默认 1；上限由 Maintainer 在仓库配置里显式设置，未配置即 1 |
| Q5 | 依赖冻结与降级 | 某卡失败只停止其后继，不撤销同批其他未提交的工作 |
| Q6 | 合并串行化的强度 | 试点期串行到 Evidence 升级完成；补偿路径验证后再放宽 |
| Q9 | 暂停语义 | `needs:human` 作用于单卡；全仓 pause 的触发条件由 Maintainer 定义 |
| 并行轨 | 并行轨如何纳入调度 | 容量按轨声明，未声明的轨不调度；启用方式待定 |

### 10.3 细化中新出现的子项

| 编号 | 问题 | 说明 |
|---|---|---|
| S1 | coordinator 是否为新角色 | §3 建议不新增角色 |
| S2 | 租约登记身份的白名单 | 只在 Q1 选 B 时出现；要新增 `.github/agents.yml` 键，属安全边界变更 |
| S3 | 核验结论与 head 的绑定 | §7.5 |
| S4 | 全仓 pause 的载体 | 本地标志文件，或 GitHub 上可见的标签；见续篇 §6 |

## 11. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 增加的复杂度换不回吞吐 | 阶段 1 先交付只读 `plan`；合并队列吞吐在试点期实测后再决定是否进阶段 3 |
| 合并队列被长寿命 PR 堵住 | `verify_queue.depth` 可观察；超限转 Maintainer 裁决 |
| scope 漏报共享文件 | 越界检测，越界即停；§6.1 要求共享文件写进 scope |
| PR 列表达到 gateway 的单页上限 | `fetch_pull_requests` 在 PR 总数达到 100 时 fail-closed；main 上 squash 合并提交已有 65 个。并行会更快逼近，须在阶段 3 前改为分页 |
| 含点路径的 worktree 使文档门禁假绿 | `check_docs.rb` 按路径分段过滤点开头的目录，worktree 落在 `.zcode/` 下时输出「检查 0 个 Markdown 文件」且 FAIL 0（2026-11-24 在 `2ad28c6` 上本机复现）。跑门禁要核对文件计数，过滤逻辑另行修复 |
| 自动发版放大 main 的变更 | 含 `fix(...)` 的合并会触发 auto-release，发版 PR 合入 main 又使在途 PR BEHIND |
| Windows 上的锁与路径语义 | 工具链已为 Windows 客户端的 CRLF 做兼容（`json_block.rb`）；锁、原子重命名与路径分隔在 Windows 上的行为未实测，列入必测场景 |

## 12. 对流程文档与角色的影响

随实现工作包回写，本 PR 不改这些文档。

| 文档 | 要改的内容 |
|---|---|
| implementer-loop.md | §1 不变量 1 换成 I1–I6；§2.2 标签表的「全仓最多一张」；§3 流程改为逐租约；§4 增加 `merge_ready`；§5 记录路径；§6 必测场景 |
| implementer.md | 「串行原则」；「合并前置」里合并动作归 coordinator |
| quickstart.md | `plan` 命令与 `runs/` 记录目录 |
| development-workflow.md | §4 合并自动化层级加入合并队列 |
| verifier.md | 核验结论与 head 的绑定规则，若 §7.5 获裁决 |

## 13. 后续工作（本期外）

- 远程执行后端：Actions runner 池。
- 放宽合并串行化：批量合并后统一补 Evidence。
- GitHub 原生 merge queue 是否适用于本仓库，未核实。
