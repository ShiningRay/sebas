# 逐租约动作与合并队列

> 契约来源：[parallel-implementers.md](../proposals/parallel-implementers.md) §4.1、§6.1、§7.2；
> 实现见 `tools/agents/lib/sebas_agents/policy/selection.rb`（逐租约动作）与
> `merge_queue.rb`（队列规划）。
> 本文是 [implementer-loop.md](implementer-loop.md) 的续篇：选卡与依赖见正文，本文只讲
> 「多张在途卡怎么各自推进」与「合并怎么串行」。

## 1. 逐租约动作

多租约下 `next` / `plan` 不再「取首卡算一个动作」，而是对**每张在途卡**分别求值：

| 条件 | 动作 | 说明 |
|---|---|---|
| PR 关联多卡 / 目标不是 main / 分支与租约不符 | `invalid_plan` | 归属校验排在一切动作之前，fail-closed |
| 失败检查 / 未解决 thread | `resume_pr` | 与单卡时一致 |
| BEHIND | `merge_ready` | **不是** `resume_pr`：sync main 是合并队列的 `update_branch` 步骤，归队列就保证「update 后必重核验」；判成 `resume_pr` 会让队列看不到这张 PR（队列只收 `merge_ready`），update 永远不执行 |
| 检查未完成 | `wait` | 本卡等，**释放算力**：容量有空位就补位认领 |
| CLEAN 且 thread 清零 | `merge_ready` | 进合并队列；仍需 `--pre` 与独立核验 |
| 本卡带 `needs:human` | `needs_human` | 只停本卡，不阻塞其他租约（Q9） |
| 记录 `phase=merging` | 按 PR 状态对账（F15） | 已合并 → `release_ready`；仍 open → 重新核验；异常 → `invalid_plan` |
| PR 变更文件越出 scope | `needs_human` | 越界即停（F14），交 Maintainer |

多条动作同时存在时按优先级取一条返回：`merge_ready` > `resume_pr` > `resume_issue` >
`needs_human`。合并就绪排最前是因为它有时效——main 每前进一次，在途 PR 就转 BEHIND，
越晚合并越贵。

`plan` 输出 `leases` 数组暴露每张卡的 `issue/action/owned/pr/reason`，便于观察与审计。

## 2. scope 冲突预算

`Automation.scope` 是路径前缀数组，判定从保守：任一路径前缀互相包含即冲突
（`src/` 与 `src/bus/x.cr` 冲突，`src/bus/` 与 `src/keys/` 不冲突）。

缺 scope 的独占语义（Q4=A 强制）：

- 在途任一租约缺 scope → 不认领任何新卡（无从判定是否重叠）；
- 候选缺 scope → 只在没有任何在途租约时可认领。

共享文件（`CHANGELOG.md`、`src/store/schema.cr`、`.github/workflows/`）靠**声明进 scope**
进入预算：谁要改谁写进自己的 scope，于是改同一文件的卡自然不并行。这条不依赖人的记性
之外的机制——漏写仍会漏报，所以另有事后检测（worker 推送前自查 diff，coordinator 进
合并队列前用 `pr.files` 复查）。

`claim` 与 `plan` 用同一套判定：人工 `claim` 不能成为绕过 scope 预算的后门。

## 3. 合并队列

```sh
ruby tools/sebas-process queue              # 只读：entries / head / step / blocked_by
ruby tools/sebas-process queue --apply      # 推进队首一步（update-branch / 追加 CHANGELOG / 合并）
```

### 3.1 链上步骤

顺序固定为 **update_branch → verify_pre → changelog → merge → evidence → release**：

| 步骤 | 判定 | 为什么在这一步 |
|---|---|---|
| `update_branch` | `merge_state_status=BEHIND` | main 前进后旧 base 上的核验结论全部作废，必须先 `gh pr update-branch`；它改 head，所以之后必须重跑 `verify merge --pre` 与独立核验 |
| `verify_pre` | 归属、目标分支（必须明确 `main`）、失败检查、未完成检查、未解决 thread、`merge_state_status=CLEAN`、**当前 head 已有核验记录** | `verify merge --pre` 是合并前唯一能判定的门禁；DIRTY/BLOCKED/UNKNOWN 一律不能进入合并 |
| `changelog` | PR 正文声明了条目而 `[Unreleased]` 还没有本 PR 的引用行 | 追加会改 head，必须排在核验之后、合并之前 |
| `merge` | `gh pr merge --squash --match-head-commit <head>` | head 绑定让 GitHub 拒绝合并未核验的提交 |

**head 核验绑定**：`update_branch` 与 `changelog` 都改 head，旧 head 上的
`verify merge --pre` 结论随之作废。本机运行记录的 `verified_head` 存「上一次
通过 `--pre` 的 head」，队列要求它与 PR 当前 head 一致才进入 `merge`；两者都在
改 head 之后把 `verified_head` 清空。没有这道判定，「CI 全绿 + Evidence 仍
accepted」就能把新 head 直接合掉——Evidence 是 issue 级的，不绑定 head，
拦不住这件事。
| `evidence` | merge commit 的 CI 成功、`merged_into_main: true` | 异步，由 `evidence-register.yml` 写 |
| `release` | 释放租约（`unclaim`） | 收口，要求 PR 已合并且 issue completed |

`--apply` 只做**一张、一步**，且只推进队列自己能完成的那两步：

| 队首 step | `--apply` 做什么 |
|---|---|
| `update_branch` | 只做 `gh pr update-branch`；改 head 后强制要求重跑核验，不接着合并 |
| `changelog` | 把 PR 正文的条目追加进 `[Unreleased]`（幂等） |
| `merge` | 先 `verify merge --pre`，再绑定 head squash 合并，合并后复核 |
| `verify_pre` | 跑 `verify merge --pre`；通过则把当前 head 写进运行记录的 `verified_head`，之后才能进 `merge` |
| `evidence` | 不做写：Evidence 升级由 workflows 完成，重跑 `queue` 看是否已解锁 |
| `release` | 不做写：`unclaim` 是收口动作，需 PR 已合并 + issue completed |

**验收串行**（#221 §4 / Proposal §7.4，Q7/Q8=A）：独立 Verifier 的核验与终验由
coordinator **按队列队首逐张发起**，不并行。理由：核验与终验虽只读，但「有条件通过」
仍要回流 Maintainer，并行收益被人工环节吃掉；实际容量上限等于 Verifier 吞吐。
`verifier_queue_depth` 是这条约束的可观察量——它数 `merge_ready` 的 PR（已进入
合并队列、接下来要做核验 / update-branch / 合并的），不是 open PR 数，也不是
「已 CLEAN 的 PR 数」：**BEHIND 的 PR 同样计入**（它要先 `update_branch`，之后还得
重核验，确实占验收通道）。`wait`（等 CI）与 `needs_human` 不计入。

**串行单位**由 `evidence` 这一步表达：只要有本机记录处于「PR 已合并、Evidence 未升级」，
`queue` 直接以 `step=evidence` 报队首，不给出任何可合并项。持续等到 `merged_into_main`
为 `true` 才回到正常队列——这就是「等 Evidence 升级完再处理下一张」的落地。

CHANGELOG 追加由**队列**执行（§6.3 裁决的唯一执行者），不是 worker：worker 不改
`CHANGELOG.md`，只把条目写进 PR 正文。

### 3.2 三次核对目标分支

`gh pr merge` 没有绑定 base 的参数：核验之后有人把 PR 的基础分支改到别处，head 不变也会
照合，合进去的分支不触发 main 的 CI。所以 base 要读三次：规划时（快照）、合并前（重读）、
合并后（复核）。这只能缩小窗口，关不掉它。

### 3.3 CHANGELOG 由队列追加

worker 不再改 `CHANGELOG.md`。PR 正文用 marker 块携带待追加条目：

````markdown
<!-- sebas-changelog -->
```
- **条目正文**（必须带 `(#<PR号>)`）
```
````

幂等与核验都按条目里的 PR 引用识别，不按文本比较：同一 PR 重跑不会重复追加；文本相同的
不同 PR 各写各的引用行，互不吞并。声明了 marker 但条目为空也算 pending——避免「空块 =
已完成」的静默放行。没有 marker 的 PR 走旧路径，队列不要求追加。

### 3.4 故障矩阵覆盖

| 编号 | 判据 | 实现位置 | 测试 |
|---|---|---|---|
| F1–F4 | claim 各写入点崩溃 | `claim` 的写后回读与 `aborted` 对账 | `test_lease_coordinator.rb` |
| F5 | worker 进程消失 | `RunRecord#heartbeat!`（锁内复核 lease_id/phase，记录 worker 的 pid）与 `#heartbeat_expired?`；路由侧 `Policy::Worker.state` 双证据：心跳新鲜或本机 pid 存活 → `wait` 不接管；心跳过期且本机 pid 不存在 → `resume_issue`；跨机或**缺 host** → `wait`；证据不足（缺 pid / 旧记录无心跳）→ `wait` 并交人决定 | `test_fault_matrix.rb`、`test_cli_queue.rb` |
| F6 / F7 | 异机租约 / 有标签无凭据 | 逐租约 `owned?` + `claim` 的租约预检 | `test_selection_scheduling.rb`、`test_lease.rb` |
| F8 | 记录与远端认领不是同一张卡 | `routing` 的 orphan 判定（`settled_record?` 排除已合并待释放） | `test_fault_matrix.rb`、`test_queue_regressions.rb` |
| F9 | 同一张卡两份有效凭据 | `Lease.active_lease` 唯一性 | `test_lease.rb` |
| F10 | PR 已建、记录未回填 | `lease_action` 按 `closing_issues` 找 PR；`branch` 与记录一致才续做，不一致 `invalid_plan` | `test_lease_actions.rb` |
| F11 | 别的 PR 关联了本卡 / 一个 PR 关联多张卡 | `lease_action` 的归属校验（多卡、base、分支三项） | `test_lease_actions.rb`、`test_fault_matrix.rb` |
| F12 | 合并后 unclaim 失败 | `unclaim` 幂等 + `release_lease_comment!` | `test_lease_coordinator.rb` |
| F14 | worker 越界写 | `Scope.violations`：非数组 / 缺清单 / 解析不出路径一律不可判定即 `needs_human`；重命名同时查原路径与新路径。**租约缺 scope 不算越界**（那属认领侧的独占容量，见 §2）。队列自有的 `CHANGELOG.md` 先由 `Scope.without_queue_owned` 剔除 | `test_fault_matrix.rb` |
| F15 | 合并中途崩溃（`phase=merging`） | `reconcile_merging` 逐条对账：已合并且 base 明确为 main → `release_ready`（base 缺失即不可判定）；仍 open → 重核验，但卡已 completed 时属矛盾态 → `invalid_plan`；其余异常 → `invalid_plan` | `test_fault_matrix.rb` |

**F13（main CI 被取消）不在上表**：它的处置是重跑被取消的 CI run 或补登记，属人工动作，
判据与步骤写在 [pr-gate.md](pr-gate.md) 的「并发语义」节。`#289` 已让 main 侧不再互相取消，
所以这条从「必然发生」降为「残余风险」。

### 3.5 写守卫

合并与 `update-branch` 是仓库里仅有的两条能改变 main 的命令，各自需要独立的写意图
（`:merge_pr` / `:update_branch`），且形态必须完整匹配：

- 合并必须同时带 `--repo`、`--squash`、`--match-head-commit <sha>`，多一个参数就不放行
  （挡住 `--admin` 之类的绕过）；
- 意图不可串用：拿 `:add_label` 的意图发合并命令会被拦。

测试断言「子进程是否真的被调用」，不看 `runner.calls`（后者在拦截前就记录，用它断言会把
「被拦」与「被执行」看成同一件事）。

## 4. 自动触发（阶段 4，#222）

阶段 3 的合并链由人工逐步触发（`queue --apply` 每轮一步）。阶段 4 换成条件齐备即
自动推进（`queue --auto`）；门禁不放宽、权限不新增（沿用 `GITHUB_TOKEN` 与分支保护），
每步仍走 `queue --apply` 的同一执行段与合并链 ref 锁。

触发条件（全满足才执行，任一不满足停在队外，不强推）：

1. 队首 PR 下一步就绪：CI 全绿、`mergeStateStatus=CLEAN`、thread 清零、head 已核验
   （`next_step` 的既有判定）；
2. `verify merge --pre` 退出码 0（含 Evidence 预登记已就位）；
3. 独立核验与终验两关结论为「通过」——终验 check 对「通过」与「有条件通过」同为绿，
   以 verifier 摘要评论（`<!-- verify-pr:summary -->`）的 `unverified` 计数区分；
   该评论只认受信自动化身份（`trusted_bots`）发布的，伪造的同 marker 评论一律无视
   （#312 review，CWE-863），且摘要正文必须含当前 head sha（摘要发布步骤
   continue-on-error，旧 head 的残留结论对新 head 不成立，#312 二轮 review）；
4. `.github/agents.yml` 的 `auto_merge_enabled: true`（缺省 false，关停时整体拒绝，
   行为与阶段 3 完全一致；启停操作见 [maintainer.md](maintainer.md)）。

「有条件通过」（`unverified > 0`）与摘要缺失恒交 Maintainer，不自动合并。同一轮只允许
`verify_pre` 成功后接续下一步（merge 在锁内全量复核）；`update_branch` 与 CHANGELOG
追加作废已核验 head（重核验是异步的），merge 之后是等 Evidence 升级的串行单位——
三者都停轮，等待发生在两次调用之间。失败回退 fail-closed：执行失败计入
`auto_merge_failures`，达 2 次（初次 + 一次重试）自动路径对本卡拒绝，人工
`queue --apply` 成功一步即重置；门拒判（有条件通过、缺摘要）是交人工的正常停轮，
不计入预算。`plan` 输出追加 `merge_queue`（队首 PR、队列长度、阻塞原因），与
`queue` 同一构造点，口径同源。
