# Evidence 自动登记（workflow 段位）

> 本文是 [implementer-loop.md](implementer-loop.md) §2.5 的全文；正文的「前置完成的标准」
> 与「可机读证据契约」仍留在 implementer-loop.md，这里只讲自动登记这一侧。
> 实现：`.github/workflows/evidence-register.yml` 与 `tools/evidence_register_twophase.rb`。

`workflow` 段位的实际承载是 [`.github/workflows/evidence-register.yml`](../../../.github/workflows/evidence-register.yml)：
以 `github-actions[bot]` 身份发一条含 Evidence 块的评论，并把同一块回填进 issue 正文的 `Evidence` 小节。

**分两阶段登记（#126）**，因为合并前门禁要求 Evidence 已存在，而合并后才能证实 merge commit：

| 阶段 | 触发 | 写入 |
|---|---|---|
| 合并前 | PR 仍 open、目标 `main`、CI 全绿、issue 仍 open | `merged_into_main: false`、`merge_commit: null` |
| 合并后 | PR 已合并、issue `completed`、merge commit 属 main | 升级同一块为 `true` + 真实 commit |

合并前登记让 `verify merge --pre` 有据可依；合并后升级由 `workflow_run` 在合并事件上完成。

| 性质 | 行为 |
|---|---|
| 幂等 | 已有**有效** Evidence 时跳过；结构非法则 fail-closed 报错，不假装成功 |
| fail-closed | 目标非 main / issue 非 open（合并前）或非 completed（合并后）/ 无唯一 `Fixes #n` 时跳过，零写入 |
| CI 证据 | 合并前反查 head sha 的 check-runs：为空、有未完成、有失败一律拒绝；合并后由 `workflow_run` 携带 |
| 原子性 | 评论发出后若回填正文失败，先重读正文核对；仅当正文未引用该评论时才删除 |
| 不伪造 | `untested` 唯一来源是 issue 正文的「未实测」小节；升级时沿用登记期冻结值，不重新读取 |
| 防伪造 | 未合并却带 `merged_into_main: true` 的块一律拒绝（登记路径与门禁两侧都查） |

补充三条判定口径：

- **`merged_into_main` 由 git 祖先关系证实**（`git merge-base --is-ancestor <sha> origin/main`），
  不因 `merged_at` 存在就置 `true`——手动触发可以选择合并进 release 分支的 PR。
- **`push` 事件必须反查 PR**：合并后 main 上的 CI 里 `pull_requests` 通常为空，
  脚本用 `head_sha` 走 `commits/{sha}/pulls` 找已合并的那个。
- **中间态按 blocked 处理**：`merged_into_main: false` 期间下游前置仍是 blocked，这是正确语义
  （稍后重跑即通过），不得为消除这个窗口放宽判据。
- **`status` 与 `merged_into_main` 正交**：合并前块写 `status=accepted` 表示「验收判断已成立」，
  不表示「已合并」；合并事实只由 `merged_into_main` 承载。因此 `accepted + false` 是合法中间态，
  而 `true` 必须由合并事件写入。

**它自动化的是机械登记，不是验收判断。** 门禁要求的「必须实测」项仍由 Verifier 判定并写入
`untested`；workflow 只负责在条件满足后把结论落成可机读凭据。里程碑级验收（M-gate、冻结口径、
发版终审）依旧由人在 PR 级自动化之上裁决。
