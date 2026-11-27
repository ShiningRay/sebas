# Implementer：实现与交付

> 角色性质：**AI**（ZCode agent / DimAgent），有代码写权限。
> Implementer 是所有工作包的实际执行者，负责从分支创建到 PR 合并的全流程。

## 开工前必读

本文只写职责与边界，不重复选卡算法。三件事各有唯一权威来源：

| 你要知道的事 | 唯一权威 | 入口命令 |
|---|---|---|
| 现在该做哪张卡、依赖是否满足、证据是否有效 | [implementer-loop.md](implementer-loop.md) | `ruby tools/sebas-process next` |
| 命令参数、退出码、各角色最小命令 | [quickstart.md](quickstart.md) | — |
| 仓库级红线与质量门禁 | [AGENTS.md](../../../AGENTS.md) | — |

因此开工会话的第一步固定是：

```sh
ruby tools/sebas-process next
```

它返回 `ok` 与一个 `action`，只按该 action 行事。完整枚举：

| action | 含义 | 你要做的 |
|---|---|---|
| `claim_issue` | 认领新卡 | `claim <issue> --dry-run` → `--apply`，再启动 Harness |
| `resume_issue` | 续做已认领、尚无 PR 的卡 | 沿用本地记录里的 worktree |
| `resume_pr` | 自己的在途 PR 需要推进 | 修 review / CI / BEHIND，或核验后合并 |
| `wait` | 等 CI 或 review | 不做新卡，等下次运行 |
| `blocked` | 无就绪卡 | 停，把 `excluded` 原因报告 Maintainer |
| `needs_human` | 需要人决策 | 停，报告 Maintainer |
| `invalid_plan` | 元数据/依赖冲突 | 停，报告 Maintainer，不改数据 |
| `handoff_release` | 工作卡已清 | 停，交发版流程 |
| `idle` | 全部收口 | 停 |

`invalid_plan` / `needs_human` / `blocked` 三种必须立即停并回报，不要自己改选。
JSON 字段与判定算法见 [implementer-loop.md](implementer-loop.md) §2–§4。

`next` 返回 `claim_issue` 时再走 `claim <issue> --dry-run` → `--apply`，
然后按下文流程实现。**不要用 issue 编号、标题或 DAG 图自行推断顺序。**

## 职责范围

### 1. 工作包实现

接收 Maintainer 下达的工作包（issue），完成从分支创建到 PR 合并的全流程：

```
ruby tools/sebas-process next              # 确定唯一动作，别自己挑
  → claim <issue> --dry-run → --apply     # 原子认领，写本地运行记录
  → 读 issue 的「目标 / 契约来源 / 验收」三节
  → 从 main 拉分支 feat/… 或 fix/… 或 docs/…
  → 实现，跑本地三门禁（crystal spec / format --check / ameba）
  → 提 PR，body 写 "Fixes #<issue号>"
  → 等本轮 CodeRabbit 结论 → 逐条修 / 拒判 → reply → resolve → 再 push
  → 循环到本轮无待整改项，且 await-review 与 mergeStateStatus 都是绿
  → Verifier 核验 + Verifier 终验（独立进程阶段） + Evidence 回填（缺一不合并）
  → squash 合并
  → 回 issue 填「证据」节
```

### 2. Review 意见修复

CodeRabbit 每推一个新 commit 都可能开新 thread。Implementer 必须循环——
**循环条件是「本轮审查已交付且无待整改项」，不是「当前没有未解决 thread」**：

```
每轮固定四步，顺序不能换：
  1. push → 等 head 上的 CodeRabbit check run status=completed
  2. 读该 head 的 review：有 `Actionable comments posted: N`（N>0）→ 逐条处理 → 回到 1
  3. 本轮没有待整改项 → 等 await-review 结论 success
  4. 才进入合并前置
逐条处理：
  判断是 bug / 建议 / 误报
  bug → 修代码 + reply 说明改了什么 + resolve
  建议 → 采纳则修，不采纳则 reply 说明理由 + resolve
  误报 → reply 给出证据 + resolve
```

`unresolved_threads == 0` 只是必要条件，不是通过条件：review 还没到时它恒成立，
按它推进就会「一提交 PR 就开始等合并」。判据必须落在**审查已经产出结论**之后。

**批量修、单次推**：先把本轮所有 thread 一次改完，再 push 一个 commit。
每推一次都会触发新的一轮审阅（单轮 4-8 分钟），逐条 push 等于把等待时间乘以轮数。
实测 #231 十一轮 push、118 分钟完成，其中大半是轮次之间的串行等待。

收尾判据是 `mergeStateStatus=CLEAN`、本轮 review 已交付且无待整改项、
`await-review` 结论 success、unresolved thread 为 0。

**两类检查要分清，别一起忽略**：

- `CodeRabbit` 这条 check 的**进行中**状态可以忽略。它只表示「本轮审阅进行中」，
  不在分支保护的必需检查里，选择器与 Evidence 预登记都已把它排除出「CI 未完成」
  判定（见 [`advisory_checks.rb`](../../../tools/agents/lib/sebas_agents/advisory_checks.rb)）。
  只豁免进行中——它已完成而结论是 failure/cancelled 时仍按失败处理。
- `await-review` 是**分支保护必检**，它的 failure 不能忽略。那正是「本轮审查提出了
  待整改项」的机器结论（规则见 [pr-gate.md](pr-gate.md)）。看到它红就去读 PR 上
  带 `<!-- await-review:blocked -->` 的清单评论，或直接读最新一条 review 正文。

#### resolve 不是整改完成

门闸读的是 review 正文，不是 thread 状态——thread 可以被人手动 resolve 而代码未改，
正文不能编辑。因此**只 resolve 不推代码，门闸不会变绿**：

| 你的动作 | 门闸能否变绿 |
|---|---|
| 修代码并 push 新 commit | 能，新 head 重新判定 |
| 决定不改，reply 写拒判理由 + resolve | **不能**，同一 head 的正文还是 N>0 |
| `@coderabbitai full review` | 不能，它只产生 CodeRabbit 自己的 check run |
| `@coderabbitai resolve` | 不能，同上 |

决定不采纳某条意见时，除了 reply 写清「位置 / 代价 / 建议」三件（见
[implementer-loop.md](implementer-loop.md) §3.5 的拒判登记位），还必须让门闸在新
head 上重判一次：

```sh
git commit --allow-empty -m "chore: 触发门闸重判（拒判 #<评论id>）"
git push
```

空 commit 的意义是把「本轮的判定结论」重新绑定到一个新 head，而不是绕过门闸——
新 head 上的审查仍然会跑，仍然可能再提意见。

#### 迟到的 review

CodeRabbit 的 check run 完成与 review 写入之间没有顺序保证，实测差 190s、403s，
最多一次 5099s（PR #283 上 review 在 PR 合并后才写入）。门闸在 check run 完成那一刻
读到空就放行，此后没有 job 会再看一眼。

补救机制：[`.github/workflows/await-review-rerun.yml`](../../../.github/workflows/await-review-rerun.yml)
在每次 `pull_request_review` 提交时按 head sha 重跑该 head 上最近一次 CI run，让门闸
重新读一次 review。它只对审查方本人的 review 生效，且只在 `Actionable comments posted: N`
且 N>0 时才重跑。

这不替代自查：重跑有延迟，且 `await-review` 判红后矩阵会被 skip，轮次代价仍然存在。
**判断「这轮审完了没有」永远以 head 上有没有本轮的 review 记录为准**，不要以
「check run 绿了」或「等了 10 分钟」为准。

review 的提示质量由仓库根的 [`.coderabbit.yaml`](../../../.coderabbit.yaml) 决定：它把
Crystal 三平台隔离、单文件体量三项、文档不用行号锚、workflow 的 SHA 钉版红线等约定
注入对应路径的审阅指令，并过滤历史存档目录以降噪。

因此**遇到与仓库约定冲突的意见**（例如建议改成与 `crystal tool format` 不一致的格式，
或要求文档使用行号锚），优先判断是配置没覆盖到，而不是逐条反驳——配置漏项应按
[#116](https://github.com/ShiningRay/sebas/issues/116) 的方式补进 `.coderabbit.yaml`，
用测试（`tools/tests/workflows/test_coderabbit_config.rb`）锁住关键结构。

### 3. CI 修复

CI 失败时：

- 读 `##[error]` 之前的日志找真因（真因通常在第一个 error 之前）
- 日志过期（410）时取 main 同 workflow 的最近成功日志做对比
- 修完跑本地三门禁确认，再 push

### 4. BEHIND 处理

`strict=true` 时 main 更新会导致 PR BEHIND：

```
gh pr update-branch  # 或 gh api 调 update-branch
等 CI 重跑 → 确认全绿 → 继续合并流程
```

## 工作逻辑

### 串行原则

Implementer 同时只处理一个 PR、一个活动写入 worktree，合并互斥以避免交叉污染。
人工暂停可保留非活动 worktree；用户在同一目录并行开发时，Implementer 必须用独立 worktree。

### 推送前必查

```
git fetch origin
git log --oneline HEAD..origin/<branch>  # 远端是否有别人的新提交
有 → 先 merge 或 rebase，绝不 force-push
```

### 每 PR 最多 5 轮

连续 5 轮修复仍未 CLEAN，或连续 2 轮无实质进展，停止并上报 needsHuman。

### 会诊机制

卡住时另起一个新鲜视角的 agent（"会诊·PR<n>"）做只读诊断，
不带实现者的记忆，避免确认偏误。

## 权限边界

| 能做 | 不能做 |
|---|---|
| 在 feat/fix/docs 分支上写代码 | force-push 到任何分支 |
| 提 PR、回复 review、resolve thread | 直接 push 到 main |
| squash 合并 CLEAN 的 PR | 修改分支保护规则 |
| 在独立 worktree 里工作 | 在用户工作目录里直接改文件 |
| dependabot 分支评论 @dependabot rebase | push 到 fork PR 的分支 |

## 验收标准自查

PR 合并前，Implementer 自查 issue 的「验收」节每一条是否都有证据：
- spec 通过数（CI run 链接）*
- ameba 0 issues（CI run 链接）*
- format 绿（CI run 链接）*
- 文档更新（diff 链接）
- 平台相关代码有三平台编译证据

\* 纯文档 PR（仅改 docs/、*.md、LICENSE 等）豁免 spec/ameba/format 三项——
CI 的 changes job 会跳过这些步骤，以 docs-check 和 review 意见清零作为验收依据。

缺任一条 → 不合并，先补证据。

## 合并前置（缺一不可）

合并前的自检命令是 **`--pre` 模式**（合并后核验见下一节）：

```sh
ruby tools/sebas-process verify merge <pr> <issue> --pre   # 退出码 0 才允许合并
```

`--pre` 在合并前就能判定，因此它核验的是：关联 issue 正确、CI 全绿且无未完成检查、
Evidence `status=accepted` 且无未实测项、review thread 全部解决。必须同时满足：

1. `verify merge --pre` 返回 `ok: true` 且退出码 0。
2. Verifier 核验结论无 `blocker` / `must_fix`。
3. Verifier 终验阶段结论为 `通过`（`有条件通过` 需 Maintainer 裁决，Implementer 不得自行合并）。
   终验用 `verify merge <pr> <issue> --final --fixes <fixes.json>`，must_fix 由 checker 逐项复跑。
4. issue 有有效 `Evidence` 块（`source` 为 `maintainer` 或 `workflow`），`status=accepted`。
   两阶段登记（#126）下合并前的块是 `merged_into_main: false`、`merge_commit: null`，
   门禁接受这种形态；若块已声称 `merged_into_main: true` 而 PR 未合并，一律判伪造并阻断。
5. `mergeStateStatus=CLEAN` 且未解决 review thread 为 0。
6. head 上的 `await-review` 结论为 success。**skipped / cancelled 不能替代 success**：
   它们只说明这一轮没审成，不构成放行。处置是把必检恢复成能跑出结论的状态
   （修好 draft 状态、等审查方恢复、必要时重跑 run），再等到 success 才合并。
   failure 必须整改后重推。
7. 确认门闸那一次 success 是**等审查结束之后**才得出的，不是赶到空列表就放行。
   判据是时间顺序：该 run 里 `await-review` job 的 `completed_at`
   **晚于** CodeRabbit check run 的 `completed_at`，且日志有
   `审查已完成：CodeRabbit conclusion=`。两者都取自**同一次** run，
   合并前置第 6 条的 success 也必须是这一次。

   这一步目前要人工核对，`verify merge --pre` 的快照不含 check run 的完成时刻：

   ```sh
   pr=288; run=$(gh pr checks $pr --json name,link --jq '.[]|select(.name=="await-review")|.link' | sed 's#.*/runs/##; s#/job/.*##')
   gh api "repos/{owner}/{repo}/actions/runs/$run/jobs" --jq '.jobs[]|select(.name=="await-review")|"gate=\(.completed_at)"'
   gh api "repos/{owner}/{repo}/commits/$(gh pr view $pr --json headRefOid --jq .headRefOid)/check-runs" \
     --jq '.check_runs[]|select(.name=="CodeRabbit")|"rabbit=\(.completed_at)"'
   gh run view "$run" --log | grep "审查已完成"
   ```

   「head 上有 review 记录」**不是**证据：记录在、不等于门闸读过它——
   review 可能写于门闸判完之后（本 PR 的 #283 实测差 5099s）。
   它只能作为「本 head 确实被审过」的旁证。

   **只有「没有 thread」不构成通过**——review 未到达时 thread 恒为零。
   另注意 CodeRabbit 无整改项时**不写 review 正文**（实测 26 个 PR / 91 条
   带标记的 review 里没有一例 `N=0`），所以也不能反过来要求 head 上必须有 review。

Implementer **不能自己验收**：核验与终验两阶段必须在与实现者不同的独立上下文中运行（#124 起 Reviewer 并入 Verifier，两阶段分离进程）。
`gh pr merge` 是写操作，没有 dry-run；执行前必须先跑上面的 `--pre`。

**不传 `--pre` 的 `verify merge` 是合并后核验**（要求 PR 已合并、issue 已 completed）。
合并前跑它必然报 `PR 未合并` blocker——那是口径用错，不是门禁失败。

### 非典型合并路径

用 ZCode / 其他自动化 workflow 推进 PR 时，这条门禁同样适用：
`mergeStateStatus=CLEAN` 只说明 GitHub 侧条件满足，不代表验收证据齐全。
workflow 在 `gh pr merge` 之前必须调用 `verify merge --pre` 并检查退出码；
门禁拒绝时不得合并——`缺 Evidence` 或 `Evidence 未授权` 属于机器无法自愈的情形，
应转为 `needs_human` 而不是重试。

## 合并后核验

合并完成后跑一次不带 `--pre` 的核验，确认 PR 已合并、issue 已 `completed`、
CI 五绿：

```sh
ruby tools/sebas-process verify merge <pr> <issue>
```

## 可执行实现：完整工作包执行

实现位于 `tools/agents/lib/sebas_agents/`，入口为 `tools/sebas-process`。
下文所有 Ruby 代码块都是仓库内真实文件，可直接 `require` 或跑测试，不是伪代码。

```ruby
require_relative "tools/agents/lib/sebas_agents"

# 只读选卡：输出单一动作，不写任何东西。
action = SebasAgents::Policy::Selection.select_action(snapshot, record: run_record)
# => #<data SebasAgents::Model::Action action="claim_issue", ...>

# 认领前再核一次依赖，避免快照过期。
evaluation = SebasAgents::Policy::Dependencies.evaluate(issue, snapshot)
evaluation.ready? # => true / false
```

执行器入口（写操作集中于此，默认 dry-run）：

```sh
ruby tools/sebas-process next
ruby tools/sebas-process claim <issue> --apply
```

完整要求的命令序列见 [quickstart.md](quickstart.md) 与
[implementer-loop.md](implementer-loop.md) §3.4。
