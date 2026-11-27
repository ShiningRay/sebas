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
| 失败检查 / 未解决 thread / BEHIND | `resume_pr` | 与单卡时一致 |
| 检查未完成 | `wait` | 本卡等，**释放算力**：容量有空位就补位认领 |
| CLEAN 且 thread 清零 | `merge_ready` | 进合并队列；仍需 `--pre` 与独立核验 |
| 本卡带 `needs:human` | `needs_human` | 只停本卡，不阻塞其他租约（Q9） |

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
ruby tools/sebas-process queue --apply      # 推进队首一步（只做「合并」这一步）
```

### 3.1 链上步骤

顺序固定为 **verify_pre → changelog → merge → evidence → release**：

| 步骤 | 判定 | 为什么在这一步 |
|---|---|---|
| `verify_pre` | 归属、目标分支、失败检查、未完成检查、未解决 thread | `verify merge --pre` 是合并前唯一能判定的门禁 |
| `changelog` | PR 正文声明了条目而 `[Unreleased]` 还没有本 PR 的引用行 | 追加会改 head，必须排在核验之后、合并之前 |
| `merge` | `gh pr merge --squash --match-head-commit <head>` | head 绑定让 GitHub 拒绝合并未核验的提交 |
| `evidence` | merge commit 的 CI 成功、`merged_into_main: true` | 异步，由 `evidence-register.yml` 写 |
| `release` | 释放租约（`unclaim`） | 收口，要求 PR 已合并且 issue completed |

`--apply` 只做**一张、一步**，且只推进队列自己能完成的那两步：

| 队首 step | `--apply` 做什么 |
|---|---|
| `changelog` | 把 PR 正文的条目追加进 `[Unreleased]`（幂等） |
| `merge` | 先 `verify merge --pre`，再绑定 head squash 合并，合并后复核 |
| `verify_pre` | 不做写，报出阻塞原因 |
| `evidence` | 不做写：Evidence 升级由 workflows 完成，重跑 `queue` 看是否已解锁 |
| `release` | 不做写：`unclaim` 是收口动作，需 PR 已合并 + issue completed |

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

### 3.4 写守卫

合并与 `update-branch` 是仓库里仅有的两条能改变 main 的命令，各自需要独立的写意图
（`:merge_pr` / `:update_branch`），且形态必须完整匹配：

- 合并必须同时带 `--repo`、`--squash`、`--match-head-commit <sha>`，多一个参数就不放行
  （挡住 `--admin` 之类的绕过）；
- 意图不可串用：拿 `:add_label` 的意图发合并命令会被拦。

测试断言「子进程是否真的被调用」，不看 `runner.calls`（后者在拦截前就记录，用它断言会把
「被拦」与「被执行」看成同一件事）。
