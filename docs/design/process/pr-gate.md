# PR 门闸：先 review，再跑 CI

`await-review` 是 PR 门闸，两条职责：

1. **排序**：CodeRabbit 在 head commit 上审完，三平台矩阵与 ameba 才起跑；
2. **拦截**：审查提出需整改项，矩阵不起跑，等改完再 push。

动机是成本。原先两者并行，矩阵 1-2 分钟就绿、审查要 5-7 分钟
（实测 PR #230/#231/#237/#238），实现方按绿灯推进、收到意见再推 commit，
一整轮三平台白烧；更糟的是先跑完才发现要改，runner 全烧在废稿上。

实现：[tools/await_review.rb](../../../tools/await_review.rb)。
门禁位置：`ci.yml` 的 `await-review` job，`spec` 与 `ameba` 的 `needs` 含它。
迟到 review 的重判入口：[`await-review-rerun.yml`](../../../.github/workflows/await-review-rerun.yml)。

## 排序阶段（fail-open）

| 情形 | 处理 |
|---|---|
| check run `status=completed` 且 `conclusion=success` | 进入整改判定 |
| PR 是 draft（`.coderabbit.yaml` 的 `drafts=false`，本就不审） | 放行 + warning |
| 5 分钟内 check run 始终没出现（不在审查范围） | 放行 + warning |
| 脚本启动后 15 分钟内仍未完成 | 放行 + warning |
| 结论为 failure / cancelled / timed_out / skipped | 放行 + warning |
| 连续 3 次读 check-runs 失败 | 放行 + warning |

两个时间窗分开口径：「审查方压根不审这个 PR」（path_filters 全排除、App 未启用）
与「审查跑得慢」是两件事。实测 check run 创建延迟 18-23s、偶发 113s，故给 5 分钟宽限。

注意主上限的起点是**脚本启动**，不是 check run 出现（`deadline = start + timeout`
只算一次）。所以出现得越晚，留给审查的时间越短：第 270s 出现就只有 630s。
这是刻意的——总等待必须受 20 分钟的 job 超时约束，不能因为出现晚就无限延长。

这段 fail-open 的理由：它只回答「审查有没有跑完」，不判质量。卡住 PR 的代价
（draft 永远等不到、审查方被卸载、接口抖动）远大于「这一轮矩阵白跑」。

## 整改阶段（真判定）

审查跑完后读当前 head 上的 review，匹配 CodeRabbit 写的
`Actionable comments posted: N`，**取最新一条带该文案的 review**，N>0 即判整改：

| 情形（只看最新一条带文案的 review） | 处理 |
|---|---|
| 最新一条的 N>0 | **job 红**，矩阵不跑，贴一条整改清单评论 |
| 最新一条的 N=0 | 放行 |
| 该 head 上没有任何带该文案的 review | 放行 |
| 读不到 review 列表 / 接口形状异常 | 放行 + warning |

判定不看「所有 review 里有没有 N>0」——那会让历史轮次永久卡住 PR，
详见下一节。

只看当前 head：旧 commit 的意见不该挡住已修过的新 commit。
用 actionable 文案而不是 review thread，是因为 thread 可以被人手动 resolve
而代码未改；这条文案是审查方自己的原始判断。代价是耦合了 CodeRabbit 的措辞，
匹配不上就按无整改处理（fail-open）——所以改 `.coderabbit.yaml` 时不要动这个措辞。

整改清单评论带 `<!-- await-review:blocked -->` marker，重跑时 PATCH 同一条，
不会刷屏；找旧评论要翻页（PR 评论过百时旧评论落第二页）。

### 同一 head 上多轮 review 取最新一条

review 正文不可编辑，同一 head 上被重审时（`@coderabbitai review` / `full review`）
旧记录不会消失。**不能求和**：

| 时间 | 事件 | 该 head 上留下的记录 |
|---|---|---|
| 12:54 | 自动审 | `N=1` |
| 13:02 | 人工发 `@coderabbitai full review` | 旧记录仍在 |
| 13:08 | full review 产出 | `N=2` |

求和得 3（PR #282 实测），而 full review 的语义是「无视已有评论、重新完整审阅」，
`N=2` 才是当前全量结论。求和还让数字单调不减：整改完也回不到 0，PR 只能靠新
commit 脱身。

判定取**最新一条带该文案的 review**（按 `submitted_at`，同秒用 `id` 兜底）。
注意是「最新一条**带文案**的」，不是「最新一条 review」：CodeRabbit 常在主 review
之后补发 pre-merge 提示或 commentary，那些正文没有该文案，也不撤销先前结论。

### 迟到的 review 要重判

`check run completed` 与 review 写入之间没有顺序保证：

| PR | head | check run 完成 | 首条 review 写入 | 差 |
|---|---|---|---|---|
| #280 | `595b54c7` | 10:11:05 | 10:14:15 | +190s |
| #284 | `e7b1cbd3` | 13:46:15 | 13:39:32 | 早 403s |
| #283 | `0653ae26` | 11:48:19 | 13:13:18 | **+5099s**（PR 已合并） |

门闸在 check run 完成那一刻读 review，读到空就放行，此后不再回头。#283 那条
整改意见就这样被静默吞掉——PR 看起来全绿、可以合并。

补漏机制：`await-review-rerun.yml` 监听 `pull_request_review: [submitted]`，
按 head sha 找到该 head 上最近一次已完成的 `ci.yml` run 并 `rerun`，
让门闸在同一个 sha 上重新读 review。

重跑不是无条件触发的：

| 观察到的情况（review 提交时刻 vs `await-review` job 的 `started_at`） | 动作 |
|---|---|
| 提交 **不晚于** `started_at` | 必然读到，不重跑 |
| 提交落在 `(started_at, completed_at]` 窗口内 | 读没读到不确定，**保守重跑** |
| 提交晚于 `completed_at` | 必然没读到，重跑 |
| head 上只有进行中的 run | 有界等待（最多 150s）它结束，再按上面三行判 |
| 等待超时 / 查不到 run | warning 交人工，不动 |
| 取不到 `started_at`（`submitted_at` 与 `run_attempt` 有效） | warning，**按未读保守重跑**（受 `run_attempt` 上限约束） |
| 取不到 `submitted_at` | warning 交人工，不重跑——无从判断先后 |
| 目标 run 已是第 3 次运行（`run_attempt >= 3`），或取不到 `run_attempt` | 不再自动重跑，warning 交人工 |

`started_at` 缺失与 `submitted_at` 缺失的处置不同：前者只是判不了先后，
保守重跑仍可能救回这一轮；后者缺的是比较的一端，重跑也只是盲猜，
所以交人工。

判据用 `started_at` 而不是 `completed_at`：job 的完成时刻晚于门闸内部
`fetch_reviews` 的那一刻，拿它当「读过了」的凭据会把窗口内提交的 review
误判成已读。只有「提交早于 job 启动」才必然读到；其余情形一律偏向重跑，
用 `run_attempt` 上限兜住多烧的代价。

边界：

- 只对基线审查方（`coderabbitai[bot]`）的 review 生效。别人发的 review 不触发
  任何动作，否则任何人都能伪造一条 `Actionable comments posted: 99` 反复烧
  runner（与 CWE-345 同型）。
- 取 review 正文里**首个**匹配，不取最大值：正文可能引用示例文本
  （本仓库的文档与测试就含该文案）。用 `head -n1` 而不是 `grep -m1`——
  后者限的是**行数**，同一行出现两个标记时会输出两行，写进 `$GITHUB_OUTPUT`
  就是多行值，步骤直接红掉。
- N=0 或无该文案时不重跑：无整改项本来就不该多烧一轮。
- 重跑落在同一 head 上（按 `head_sha=` 查 run），不换 sha。
- 只对已完成的 run 调 rerun（进行中的 run 不允许，接口 403）；进行中的
  情形走上面的有界等待。
- 查询与重跑失败一律降级为 warning：重判是补漏、不是门禁本身，
  让它红会淹没真正的门闸结论。
- concurrency 分组与主 CI 的 `ci-<ref>` 分开，避免抢槽位。

**这条补漏不是兜底保证，只是缩小窗口。** 它依赖『review 事件一定能触达』，
而 runner 排队、API 抖动、fork PR 的只读 token、以及等待窗口内 run 没跑完
都会让 rerun 落空。所以判定「本轮审完了没有」仍以 head 上有没有本轮 review
记录为准（见 [implementer.md](implementer.md) §2 与合并前置第 6、7 条）。

## 为什么门闸可以红（与早期口径相反）

GitHub 文档写明「依赖失败 job 的 job 会被 skipped 且可能不阻塞合并」。
所以门闸变红必须同时满足两个条件才安全：

- `await-review` **本身是分支保护必检**（已加入，见 [development-workflow.md](development-workflow.md) §4 的必检 contexts）；
- 等待步骤**不带** `continue-on-error`（否则判定被吞成 success）。

两条互为条件：少了任一条，矩阵被 skip 就会变成事实上的放行。
改动任一处都要检查另一处，`tools/tests/workflows/test_ci_workflow.rb` 有对应断言。

## 超时分层

`REVIEW_APPEAR_SECONDS`（300s）管「审查方没打算审」，`REVIEW_TIMEOUT_SECONDS`
（900s）管「审得慢」，单次 `gh api` 硬超时（60s）管「调用挂住」，
步骤 `timeout-minutes`（16）管「脚本整体卡死」，job（20）兜最后一层。

一个反直觉的边界：**见过 check run 之后遇到接口错误，不能退回「等出现」的口径**。
否则第 280s 读到 `in_progress`、第 320s 读失败时，会按已过期的出现窗直接放行，
矩阵在审查未完时起跑。已见的审查一律按主上限重试。

`docs` 与 `verify` 不进等待链：它们数秒完成，文档与锚点的反馈早给更有用。

## 并发语义：PR 可取消，main 必须跑完

`ci.yml` 的 `concurrency` 组名沿用 `ci-<ref>`，不按事件改写：PR 事件的 ref 是
`refs/pull/<n>/merge`，`push:main` 与 `workflow_dispatch`（选 main 时）都是
`refs/heads/main`，天然分属两组。手动运行若选其他分支或标签，用的是所选 ref，
不进 main 组；这条按 GitHub 文档「并发组由 `group` 表达式求值决定」的口径推导，
未在本仓库实测。

要按事件区分的是**取消语义**：

```yaml
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```

- **PR 侧要取消。** 门闸最长等 15 分钟。同一 PR 新推送不取消旧轮，队列会堆积空等。
- **main 侧不能取消。** [evidence-register.yml](../../../.github/workflows/evidence-register.yml)
  只在 CI 结论为 `success` 时把 Evidence 升级为 `merged_into_main: true`，
  `resolve_checks_url` 还要求触发的提交就是 merge commit。下一次 push 顶掉正在跑的
  main CI，那一轮 Evidence 就停在 `false`，后继卡永久 `blocked`。

2026-11-27 实测 main 侧 100 次 run 有 5 次 cancelled，其中 2 次是已跑 30 / 53 分钟后
被下一次 push 顶掉。按 PR 量级换算，加速合并会放大这个比例。

**边界一：待跑位只有一个。** GitHub 每个并发组只保留一个 running + 一个 pending，
第三个进入时 pending 被替换。所以本改动**不能**承诺「每张合并提交都拿到成功 CI」；
它只保证后续的 main 运行不再取消正在跑的那一轮。

**边界二：排队中的提交也可能被顶掉。** 上一轮 main CI 还在跑时，下一张卡的合并提交
可以进入 pending；再来一次 main push（含手动 `workflow_dispatch` 选 main）就替换掉
这个 pending 位——被替换的提交从此没有成功 CI，Evidence 依然停在 `false`，队列会一直
等它。要真正闭合这条路径，串行单位必须限制「同一时刻只有一个 main 运行」，或对少了
成功 CI 的提交补跑。这是合并队列本体（[parallel-implementers.md](../proposals/parallel-implementers.md) §7.2）
的职责，本改动不覆盖。

**边界三：测试失败是另一回事。** CI 跑完但结论为 `failure` 时，Evidence 同样停在
`false`。本改动只防止「后续 main 运行取消正在跑的那一轮」，不承诺 CI 一定成功，
也不改变失败语义。

失败或漏跑之后的恢复路径有两条，都是**人工触发**，本改动不自动化：

1. **对同一个 merge commit 重跑 CI。** `gh run rerun <run-id>`（或 Actions 页面
   Re-run all jobs）。CI 成功后 `workflow_run` 自动触发 `evidence-register.yml`，
   按 `head_sha` 反查 PR 并升级 Evidence，无需其它动作。
   限制（[GitHub 文档](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs)）：
   重跑必须在原始运行后 **30 天内**，且每个 run 累计最多 **50 次**重跑。
2. **直接补登记。** `gh workflow run evidence-register.yml -f pr=<PR号>`。
   `resolve_pr` 接受 dispatch 输入的 PR 号，脚本自己复核「已合并 + merge commit 在
   main 上」，条件不满足即跳过、零写入。

两种方式都要先确认原因：被取消就重跑；测试真的失败必须先修代码并重新合并，
补登记不能把失败洗成通过（脚本 `merged_into_main?` 用 `git merge-base --is-ancestor`
证实，且缺 `success` 的 CI 时 `resolve_checks_url` 会失败）。

**超过 30 天或 50 次上限时**，第 1 条失效。剩下三条路，都由 Maintainer 决定：

- **临时分支重跑**：从该 merge commit 拉一个临时分支（如 `recovery/<sha前8位>`）推上去。
  注意 `ci.yml` 的 `push` 触发器只监听 `main`，推 recovery 分支**不会**触发 CI——
  必须手动指定该分支运行：`gh workflow run ci.yml --ref recovery/<sha前8位>`。
  若测试本身可通过，新 run 成功即产生「head_sha = merge commit」的成功记录；
  随后走第 2 条补登记，`resolve_checks_url` 在 `url` 为空的分支里用
  `actions/runs?head_sha=<merge_commit_sha>` 查成功 run，能直接命中。用完删分支。
  依据是 `tools/evidence_register.rb` 的两段实现：dispatch 路径按 `head_sha` 查 run，
  `merged_into_main?` 用 `git merge-base --is-ancestor` 证实该 sha 属于 main；
  `ci.yml` 的 `workflow_dispatch` 无分支限制，可在任意 ref 上手动运行。
- **走第 2 条补登记**：要求该 merge commit 已有可查的成功 CI；否则脚本必然拒绝，
  不能降格放行。
- **人工裁决该卡不可自动解锁**：在 issue 上记 `needs:human` 并写明原因，由 Maintainer
  决定是重新实现（新分支新 PR，旧卡关闭为 not planned）还是维持阻塞。下游卡随之
  停在 `blocked`，这是正确语义，不是故障。

测试确实失败时，任何一条都不能把失败洗成通过——必须先修代码并重新合并。

角色归属：这类残留目前没有自动巡检，需要人发现。合并队列落地后由 coordinator 的
串行单位兜住（等 Evidence 升级完再合下一张，超时转人工，见
[parallel-implementers.md](../proposals/parallel-implementers.md) §7.2）；在此之前，
发现与处置责任落在 Maintainer 与当轮 Implementer——`plan` 的 `verifier_queue_depth`
与 issue 上缺失的 `merged_into_main: true` 是唯一的信号源。
