# Implementer：实现与交付

> 角色性质：**AI**（ZCode agent / DimAgent），有代码写权限。
> Implementer 是所有工作包的实际执行者，负责从分支创建到 PR 合并的全流程。

## 职责范围

### 1. 工作包实现

接收 Maintainer 下达的工作包（issue），完成从分支创建到 PR 合并的全流程：

```
读 issue 的「目标 / 契约来源 / 验收」三节
  → 确认三道开工闸（active milestone / DAG 前置 / 外部依赖）
  → 从 main 拉分支 feat/… 或 fix/… 或 docs/…
  → 实现，跑本地三门禁（crystal spec / format --check / ameba）
  → 提 PR，body 写 "Fixes #<issue号>"
  → 处理 CodeRabbit review：逐条修 → reply → resolve
  → 循环直到 unresolved=0 且 mergeStateStatus=CLEAN
  → squash 合并
  → 回 issue 填「证据」节
```

### 2. Review 意见修复

CodeRabbit 每推一个新 commit 都可能开新 thread。Implementer 必须循环：

```
while unresolved_threads > 0:
  读 thread 内容
  判断是 bug / 建议 / 误报
  bug → 修代码 + reply 说明改了什么 + resolve
  建议 → 采纳则修，不采纳则 reply 说明理由 + resolve
  误报 → reply 给出证据 + resolve
  push 新 commit → 等 CodeRabbit 再扫 → 重复
```

直到 `mergeStateStatus=CLEAN`。

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

Implementer 同时只处理一个 PR。单工作树 + 合并互斥，避免交叉污染。
用户在同一目录并行开发时，Implementer 必须用独立 worktree。

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

## 伪代码：完整工作包执行

```pseudo
function execute_work_package(issue):
  # 开工闸
  assert issue.milestone == active_milestone()
  assert all_dependencies_closed(issue)
  assert external_deps_ready(issue)

  branch = create_branch("feat/#{issue.number}-#{slug(issue.title)}")
  worktree = create_worktree(branch)  # 独立工作树

  # 实现
  implement(issue, worktree)
  run_local_gates(worktree)  # spec + format + ameba

  # 提 PR
  pr = create_pr(branch, body="Fixes ##{issue.number}\n\n#{summary}")

  # 修复循环
  for round in 1..5:
    if pr.mergeStateStatus == "CLEAN" && get_unresolved_review_threads(pr).empty?:
      break

    if pr.mergeStateStatus == "BEHIND":
      gh_pr_update_branch(pr)
      wait_for_ci(pr)
      continue

    threads = get_unresolved_review_threads(pr)
    ci_failures = get_ci_failures(pr)
    ci_pending = get_ci_pending(pr)

    if threads.empty? && ci_failures.empty?:
      if ci_pending.any?:
        wait_for_ci(pr)  # CI 还在跑，等完再重新评估
        continue
      else:
        break

    for thread in threads:
      fix_or_reply(thread, worktree)
      resolve_thread(thread)

    for failure in ci_failures:
      root_cause = read_log_before_first_error(failure)
      fix(root_cause, worktree)

    run_local_gates(worktree)
    git_fetch_and_check_remote(branch)
    push(worktree, branch)
    wait_for_ci(pr)

    if no_progress_this_round(round):
      consecutive_stall += 1
    else:
      consecutive_stall = 0

    if consecutive_stall >= 2:
      consult_fresh_agent(pr)  # 会诊
      break

  # 合并
  if pr.mergeStateStatus == "CLEAN" && get_unresolved_review_threads(pr).empty?:
    squash_merge(pr)
    verify_merged(pr)  # 远程复核 state=MERGED
    fill_issue_evidence(issue, pr)
  else:
    escalate_to_maintainer(issue, pr, reason)
```
