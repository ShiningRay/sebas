# 单 Implementer 选卡与工作循环

> 性质：开发流程约定，不是 Sebas 产品内的任务调度器。
> 目标：在 bootstrap 阶段，用 GitHub 作为协作事实源，让一个 Implementer 确定性地选择、续跑和收口工作包。

## 1. 范围与不变量

本流程回答四个问题：现在是否有在途工作、下一张 issue 选谁、何时不能开工、完成后如何重新选择。

首版坚持以下不变量：

1. **同一时刻只有一张活动工作卡、一个活动 PR、一个写入 worktree。**Verifier 和 Reviewer 的只读独立核验不属于另一个 Implementer。
2. **GitHub 是当前事实源，本地运行记录只保存执行上下文。**每次选择都重新读取 milestone、issue、依赖和 PR，不使用本地游标猜下一张卡。
3. **父子关系不等于依赖。**sub-issue 只表达分组；`blocked_by`、期门禁和外部依赖分别核验。
4. **缺少元数据不等于没有依赖。**数据不完整、冲突或成环时 fail-closed，交 Maintainer 处理。
5. **模型不决定项目路线。**Coding Agent Harness 只实现选中的工作包；选卡、状态迁移和合并条件由确定性代码执行。
6. **不自动绕到并行轨或后续 milestone。**需要改变排期、依赖或冻结口径时，由 Maintainer 裁决。

## 2. 事实源与启动前元数据

### 2.1 Milestone

沿用 milestone description 的机器可读字段：

```yaml
order: 4
track: main
```

要求：

- milestone 的 `state` 必须为 `open` 或 `closed`；`track` 只允许 `main` 或 `parallel`。主线的 `order` 严格匹配 `\A\d+\z`，并行轨严格匹配 `\A\d+x\z`，解析出的序号均为正整数；不剥掉后缀后混用排序。
- active 主线按 `order` 升序选取 `open_issues>0` 的最前一项。
- 缺字段或非法值均为配置错误，不用 title 或 issue 编号静默兜底。`order` 只在 `track=main` 的 milestone 内要求唯一；`parallel` 不参与 active 主线竞争，其 `order: 4x` 与主线 `order: 4` 合法共存。
- 选择时读取 open 与 closed milestones，寻找 `order` 最小、存在未完成工作的主线 milestone。它仍有 open issue 时按本文选卡；工作卡已清但仍 open 时返回 `handoff_release`；已关闭时继续检查下一主线。所有 open/closed 主线均无剩余工作时才返回 `idle`。
- **并行轨回退**：active 主线评估为 `blocked`（无就绪卡）时，按 `order` 数值升序在所有 open 并行轨上再评估一轮，取第一条能选出卡的轨。边界：主线有就绪卡就只用主线；主线清空时的 `handoff_release` 不被并行轨截走；`invalid_plan` 直接上报，不用换轨掩盖配置错误；并行轨也无就绪卡时仍报主线的 `blocked`。

### 2.2 Issue

三个维度全部用 GitHub 原生字段：milestone 表示已排期、`Automation.kind` 表示可认领、
issue status 表示进度（Todo / In progress / In review / Done）。

每张卡增加一个可见的 `Automation` 小节，使用 ` ```json automation ` 代码块：

```json automation
{
  "schema": 1,
  "kind": "work_package",
  "order": [4, 0, 1],
  "depends_on": [],
  "external": []
}
```

字段定义：

| 字段 | 含义 |
|---|---|
| `kind` | `work_package` 可执行；`tracking` 父卡；`manual` 人工任务；`design` Scribe 设计细化卡（不进 Implementer 选卡） |
| `order` | 计划顺序数组，例如 M4.0-WP1 为 `[4,0,1]`；只在同一 milestone 内比较 |
| `depends_on` | issue 编号、`gate:<名称>` 和 `external:<编号>` 前置；默认空数组也必须显式写出 |
| `external` | 外部依赖编号，对应 [plan/risks.md](../plan/risks.md) E.1；每项同时进入 `depends_on` |

`kind=design` 用于仅做设计细化、交付设计定稿候选的工作包（例如把 Proposal 共识整理成
`docs/design/proposals/` 文档）。它由 Scribe 执行，不进 Implementer 选卡，也不触发开工三闸；
文档 PR 合入只代表设计快照入库，设计定稿与实现排期仍是 Maintainer 的独立裁决。

硬依赖以 WP 的「依赖」字段为权威。由该字段生成或逐条核对 Automation，再与 GitHub 原生 `blocked_by` 核对 issue 编号部分；三者不一致即 `invalid_plan`。B.1 DAG 图只用于排期展示，不作为另一套独立真值。首版只做一致性检查，不自动改依赖关系。建卡时依赖节怎么写见 [scribe.md](scribe.md) 的「依赖字段格式约定」；节标题写成「依赖关系」这类变体时，工作包直接判 `invalid_plan`，不再静默跳过正文核对。

流程标签只剩暂停与元数据两类（`ruby tools/setup_process_labels.rb --apply` 创建）：
`needs:human`（等待人工决策）、`agent:resume`（允许恢复）、`metadata:invalid`（禁止自动开工）。
`agent:in-progress` 已废弃：活动工作卡由 `status=In progress` 标识，全仓最多一张的约束不变。
普通 assignee 只表示责任人，不能充当 Agent 认领锁。

认领由 `ruby tools/sebas-process claim <issue> --apply` 执行：先写本地记录（`phase=claiming`），
再把 status 写成 `In progress`，回读确认后才转为 `claimed`；回读失败则记 `claim_aborted`
（含 `status_written`），不启动 Harness。提 PR 后 `mark-review` 推进到 `In review`，`unclaim` 写回 `Todo`。
`claim` **不校验 milestone**（只要求 open、无 `needs:human`/`metadata:invalid`、无其它在途认领与 open PR、
`kind=work_package` 且依赖就绪），所以**独立小修**（type=Task、无 milestone）只能人工点名 claim 开工；
自动选卡不挑它是设计意图，见 [development-workflow.md](development-workflow.md) 四种归宿第 3 条。

### 2.3 前置完成的标准

不同类型前置分别判断：

- **issue 前置**：必须是 `CLOSED + state_reason=completed`；`not planned` 不算完成。
- **代码工作包前置**：还须有已合并 PR、merge commit 已进入 `main`、验收证据已回填；装配类工作包另须含**生产可调用性与端到端可达证据**——spec 通过不等于生产可达（M3-WP3 教训：构件 spec 验收而生产装配未接线，#187 立此条款；[roadmap §14](../spec/14-roadmap.md) 同步承载）。
- **纯文档工作包前置**：须有所需评审通过的证据；仅文件存在或仅开 PR 不算完成。
- **期门禁前置**：按 M-gate 证据与 Go/No-Go 结论判断，不由子卡关闭数量代替。
- **外部依赖前置**：须有待办 issue 的完成证据或明确的就绪标记；Agent 不猜账号、凭据或接口已经可用。

依赖查询失败、返回不可信或验收证据缺失时，结果是“未知/未满足”，不是“可开工”。

### 2.4 可机读证据契约

模型可以起草验收材料，但选择器只接受固定位置、经过授权角色登记的结构化结果：

| 前置类型 | 证据位置 | 通过条件 |
|---|---|---|
| 代码工作包 | 前置 issue 的 `Evidence` JSON 块 | PR 已合并、merge commit 属于 `main`、验收状态为 `accepted`、没有未实测的必需项 |
| 纯文档工作包 | 同上 | 文档 PR 已合入、要求的评审已由 Maintainer 明确通过 |
| 期门禁 | `gate:<名称>` 对应的 `Evidence` 记录 | M-gate 为 `Go`、证据文件已合入、必要终审已完成 |
| 外部依赖 | `external:<E.1 编号>` 对应的 `Evidence` 记录 | Maintainer 登记 `ready=true`；不把凭据写入证据 |

统一证据结构（`source` 取 `maintainer` 或 `workflow`；登记人身份必须由 `.github/agents.yml` 对应白名单佐证，JSON 里的字符串本身不算凭据）：

| `source` | 可接受 `source_ref` 作者 | 白名单段位 |
|---|---|---|
| `maintainer` | 人类维护者 | `maintainers` |
| `workflow` | 受信自动化身份（如 `github-actions[bot]`） | `trusted_bots` |

两段位互相隔离：bot 身份不能以 `source="maintainer"` 登记；未列入 `trusted_bots` 的 bot 以 `source="workflow"` 登记一律 `invalid`（fail-closed）。

**授权绑定的是评论内容，不只是作者。** `source_ref` 指向的评论正文必须本身包含 `evidence` 代码块，且其
`subject`、`status`、`gate_status`、`evidence_path` 与 issue 上的块一致。因此「bot 恰好在这条 issue 下留过
某条普通评论」不能拿来做登记——作者身份只证明这个人/这个 bot 写过该评论，不证明该评论登记了当前结论。

```json evidence
{
  "schema": 1,
  "subject": "issue:39",
  "status": "accepted",
  "source": "maintainer",
  "source_ref": "<issue-comment-or-review-url>",
  "pr": 123,
  "merge_commit": "<commit-sha>",
  "checks": "<ci-run-url>",
  "gate_status": null,
  "evidence_path": null,
  "untested": [],
  "ready": null
}
```

- 每个 `subject` 最多一条有效 Evidence，写在对应 issue 的唯一 `Evidence` 小节；发现多条、多个代码块或重复登记即 `invalid_plan`，不按时间、URL 或 SHA 猜测取最新。
- issue 与期门禁的 `status` 必须为 `accepted`、`ready` 必须为 `null`；期门禁另要求 `gate_status="go"` 和已合入的证据文件路径。
- 外部依赖的 `status` 必须为 `ready`、`ready` 必须为 `true`；登记在 [plan/risks.md](../plan/risks.md) E.1 对应编号的唯一 `evidence` 块中，`subject=external:<编号>`。
- 期门禁登记在该期门禁 issue 的唯一 Evidence 块中，`subject=gate:<名称>`；`source_ref` 指向 Maintainer 的评论或 review，含已合入 gate 文档的 PR 与 merge commit。
- `maintainer` 与 `workflow` 两段位各自独立校验：`maintainer` 的作者须在 `maintainers`，`workflow` 的作者须在 `trusted_bots`；跨段位冒用（bot 以 `maintainer` 登记）一律 `invalid`。普通 Agent 的自报不能直接解锁；Selector 回查 `source_ref` 的实际作者 login，不信任 JSON 中的字符串。
- 授予 `trusted_bots` 等于授予「写入验收结论」的能力——因此能改本仓库 workflow 的人即可伪造 Evidence。该白名单的维护必须与 `.github/` 审核红线配套，新增条目属于安全边界变更。
- `subject` 必须与前置完全匹配；`source_ref` 用于追溯登记人及原始意见。Selector 校验字段和状态，Reviewer/Verifier 按既有角色验证实际证据。缺块、非法 JSON、状态不符、对象不匹配、提交未进入 `main` 或必需项未实测均返回未满足。`needs:human`、`invalid_plan` 等状态不得用一段自然语言评论代替。

### 2.5 自动登记（workflow 段位）

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

## 3. 每次运行的完整流程

### 3.0 元数据缺口必须可见

选择器只看 active milestone 内的 issue。一张**有工作包特征但没有 milestone** 的卡（有 Automation 块、或正文依赖节含 `#N`）不会进入候选集，只会表现为笼统的「元数据未补齐」——Maintainer 无从知道要补哪几张。

因此 `blocked` 输出带 `metadata_gaps` 字段：

```json
{"issue": 19, "missing": ["milestone", "automation"]}
```

判定「工作包特征」的两条任一成立即可：存在 Automation 块、正文依赖节含 `#N`。普通 issue（如功能建议）不计入，避免清单被噪音污染。

### 3.1 刷新并对账

先读取远端，再决定动作：

1. 获取 `main` 最新提交和 open/closed milestones。
2. 分页获取主线 milestone 的所有 issues 及其依赖、父子关系和标签，以及跨 milestone 被引用的前置卡；状态必须以远端记录为准。
3. 获取 Agent 管理的 open PR、其 `Fixes #N` 关联、head SHA、checks、merge 状态和未解决 review threads。
4. 读取本地运行记录，核对 issue、分支、worktree、PR 和 base SHA 是否仍匹配。

任何 API 错误都保留为错误，不得转换成空列表。发现多张 `In progress`/`In review`、一个 PR 关联多张工作卡、或本地记录与 GitHub 冲突时停止。

### 3.2 在途工作优先

只续跑本 Implementer 管理的工作，不接管无关开放 PR。

- **已有 PR**：先处理 review、CI、冲突或合并，不开新卡。
- **已认领但无 PR**：检查原分支和 worktree 后续做；重复运行不得创建第二个分支或 PR。
- **CI/review 正常等待**：返回 `wait`，保留活动认领，等待事件或下一次运行。
- **需要人工决策**：先记 `needs:human` 和人工暂停记录；若已有 PR，保持原 PR 和分支归属，等待人工指令，不启动其他工作包。若尚未创建 PR，则保存原 worktree/branch 的暂停记录并释放活动认领，之后可按计划顺序选择其他就绪卡，不并发执行。
- **人工恢复**：仅 Maintainer 在 issue 中写明解决事项并加 `agent:resume` 后，才移除 `needs:human`。已建 PR 的卡恢复原 PR；未建 PR 的卡若暂停记录仍匹配，且当前没有其他活动工作，则恢复原 worktree；否则按普通就绪卡重新认领。`agent:resume` 不表示批准合并或绕过原验收。
- **暂停恢复**：对同时带 `needs:human` 和 `agent:resume` 的卡，先核验 Maintainer 的解决说明与 `source_ref`，再在同一动作中移除两个标签并保留原归属。已建 PR 的卡恢复该 PR；未建 PR 且暂停记录匹配的卡恢复其 worktree；若其他活动工作占用中，则返回 `wait` 而不是换卡。标签状态歧义或说明缺失均返回 `invalid_plan`。
- **PR 已合并**：远端确认 `MERGED`，验证关联 issue 已关闭且证据完整，再重新扫描；不能直接按本地记忆递增 WP 编号。

无关 PR 由 Maintainer 或专门流程处理，不得仅因“存在 open PR”永久阻塞工作包选择。

### 3.3 选择在途工作之外的新卡

只有在没有活动工作时才执行：

1. 计算唯一 active 主线 milestone。
2. 取该 milestone 的 open issues，排除 `tracking`、`manual`、`needs:human`、`metadata:invalid` 和已有活动 PR 的卡。
3. 校验所有候选的元数据与依赖声明，检查引用存在、无环、顺序合法。
4. 逐张计算 `depends_on` 和 `external`，过滤未满足项。
5. 对剩余卡按 `order` 字典序升序排列；完全相同的顺序视为计划错误，不用 issue 编号掩盖。
6. 选择第一张，重新读取该 issue 和全部前置，确认状态未变化后认领。

先原子写入 `phase=claiming` 的本地运行记录，再写 `status=In progress` 并回读确认；两者均成功后将阶段改为 `claimed`，才启动 Harness。

中断恢复必须区分两个写入点：有本地记录但无远端标签时，重读卡片满足认领条件后补写标签，否则将记录标为 `claim_aborted`；标签已写但回读结果未知时，按同一 issue/branch 对账，补全记录而不重复认领。两边内容不一致、发现其他活动卡或无法判断时返回 `invalid_plan`，不得启动编码。

### 3.4 完成、解锁与里程碑边界

一张卡的完成事件不是“模型说做完了”，而是：

```text
实现及本地门禁完成
→ PR 创建并可追踪
→ review / CI / 独立验收完成
→ PR 合入 main 并远端复核
→ issue 关闭且证据回填
→ 确认父卡已随流程同步更新
→ 删除活动认领（`ruby tools/sebas-process unclaim <issue> --apply`）
→ 重新读取 GitHub，重新选卡
```

`unclaim` 是确定性的收口动作，不是「手动清锁」：它要求 PR 已合并 **且** issue 以 `completed` 关闭，任一不满足即 `refused`（退出码 1）。因此它不可能被用来绕过依赖判定——前置未真正完成时清不掉锁。

后继是否解锁完全由新快照决定。父卡在所有子卡和门禁完成后按流程收口；版本 milestone 在发版产物验收后关闭。Selector 不越过这个边界直接开始下一版本。

### 3.5 拒判遗留的登记位

验收链（Verifier / Reviewer / 人工 review）拒判某条意见时，若该意见指向**超出本卡范围**的实质问题，PR 评论不能作为唯一留痕：

- 必须在目标 issue 的评论中登记（含 marker 结构与影响面），或写入 `docs/design/plan/risks.md` 的 E 项；
- 登记内容至少包含：位置、代价、建议三件（对齐 AGENTS.md 勤勉 ⑧）；
- 「超出范围」不构成免登记理由——拒判只决定本卡不修，不决定问题消失。

### 3.6 verify merge 的两种模式

`verify merge` 有两种口径，混用会得出相反的结论：

| 模式 | 命令 | 结构要求 | 用途 |
|---|---|---|---|
| 合并前自检 | `verify merge <pr> <issue> --pre` | PR 仍 open、issue 仍 open；校验关联 issue、CI 全绿且无未完成检查、Evidence `status=accepted` 且无未实测项、review thread 全部解决 | 合并动作前的门禁 |
| 合并后核验 | `verify merge <pr> <issue>` | PR 已合并、issue `completed` | 收口时的完整性核验 |

`--pre` **不能**复用合并后口径：后者要求 `merged?` 与 `completed`，合并前必然 blocker。反之，合并后再跑 `--pre` 会因 issue 已关闭而拒绝执行。

`--pre` 之所以要查 Evidence 与 thread，是因为这两项在合并前就已确定，且无法在合并后补救——带着未验收结论合并，事后再核验只能发现错误，不能撤销。第三方审阅（`CodeRabbit`）的进行中状态不参与「未完成检查」判定，见 [implementer.md](implementer.md) §2。

### 3.7 卡面契约的时效

工作包卡创建时，契约声明只引**已合入 main** 的文本路径。引用未合并文档时必须显式标注「待合入，开工前以最新合并版为准」。Scribe 对账周期性扫描 OPEN 卡，回填已过时的契约声明（例如「文档未合入 main」在 PR 合并后即失效）。

## 4. 输出契约与停止条件

每次选择只返回一个结构化动作：

| action | 含义 | 是否启动 Harness |
|---|---|---|
| `resume_issue` | 续做已认领但尚无 PR 的卡 | 是，沿用原 worktree |
| `resume_pr` | 修复或推进自己的在途 PR | 按需 |
| `claim_issue` | 认领一张新的就绪卡 | 认领成功后启动 |
| `wait` | 等 CI、review 或其他正常异步事件 | 否 |
| `blocked` | 当前没有就绪卡；列出前置与依赖原因，并在 `metadata_gaps` 列出挂不到 active milestone 的工作包 | 否 |
| `needs_human` | 需要 Maintainer 决策或外部输入 | 否 |
| `invalid_plan` | 元数据、依赖或状态冲突 | 否 |
| `handoff_release` | 工作包已清，进入门禁/发版收口 | 否 |
| `idle` | 所有主线 milestone 均已收口 | 否 |

示例：

```json
{
  "action": "claim_issue",
  "milestone": 2,
  "issue": 39,
  "reason": "active 主线内无前置的可执行工作包中计划顺序最小",
  "observed_main": "<commit-sha>"
}
```

`reason` 还应列出被排除卡及原因，便于审计。不要在无候选时只输出“没有任务”。

## 5. 可执行实现

首版用 Ruby 标准库和 `gh` CLI 即可，不必引入 DAG 框架、数据库或消息队列。
Shell 负责简单的 Git/CLI 管道，Ruby 负责状态、JSON 和错误处理。

目录（均已在仓库中，可直接运行）：

```text
tools/sebas-process                    # CLI 入口，默认 dry-run
tools/agents/lib/sebas_agents.rb       # 加载器
tools/agents/lib/sebas_agents/policy/  # 纯函数：milestone、依赖、证据、选卡
tools/agents/lib/sebas_agents/*.rb     # gh 适配器、Verifier、Reviewer、Triager、Release
tools/test_sebas_process.rb            # 固定快照的 minitest
```

核心接口（可直接 `require`）：

```ruby
require_relative "tools/agents/lib/sebas_agents"

# 策略层无副作用；同样快照必须得到同样动作。
action = SebasAgents::Policy::Selection.select_action(snapshot, record: run_record)

# 单卡依赖判定：Ready / Blocked / Invalid
evaluation = SebasAgents::Policy::Dependencies.evaluate(issue, snapshot)

# PR 分类：resume_pr / wait
action = SebasAgents::Policy::Selection.select_action(snapshot, record: run_record)
```

命令入口：

```sh
ruby tools/sebas-process next                  # 读取 GitHub，输出单一动作
ruby tools/sebas-process claim 39 --dry-run    # 校验可认领
ruby tools/sebas-process claim 39 --apply      # 写本地运行记录
```

`policy/` 不执行网络、Git 或模型调用；所有副作用集中在 CLI 与 `CommandRunner`，
并在每个写入点后回读确认。

### GitHub 访问

- milestone：`gh api repos/<owner>/<repo>/milestones`。
- issue：`gh issue list/view --json …`，或 REST 分页获取完整字段。
- 父子关系：`GET /repos/<owner>/<repo>/issues/<n>/sub_issues`。
- 前置关系：快照组装走 GraphQL 别名批量（每批 50 张卡，`fetch_blocked_by_batch`），依赖闭包按需补取走 `fetch_issue`（REST 单 issue）；单卡的 `fetch_blocked_by` 仍保留 REST 读取，并优先命中批量写入的缓存。批量逐卡校验别名节点存在、连接为对象、`totalCount` 为非负整数且不超 `nodes` 长度，任一不满足即 fail-closed——不把「读不到」当「没有前置」。
- PR：清单走 GraphQL 游标分页，只取身份与关联字段；`statusCheckRollup` 按需单查（open PR 与 `verify merge` 的目标 PR），其余留「未取」，不得当成「没有检查」。
- 未解决 review threads：GraphQL 分页读取 `reviewThreads(first: 100, after: ...) { nodes { isResolved } pageInfo { hasNextPage endCursor } }`，再在本地过滤未解决项；该连接没有 `isResolved` 查询参数。

所有列表处理分页和空值。evidence 的 `source_ref` 作者与正文从一次全仓 issue 评论分页中取，命中即用、未命中回退单条请求（不得以空正文放行）。`gh` 非零退出、JSON 解析失败、缺字段均 fail-closed；凭据只由运行环境注入，不写日志、运行记录或文档。

### Harness 适配

Harness 输入至少包含：issue URL 与完整契约、验收清单、允许的目录、worktree、base SHA、质量门禁和禁止事项。输出至少包含：变更摘要、真实执行的命令及结果、PR URL、未实测项和 `needs_human` 原因。

不同 Harness 的 headless 命令通过各自 `--help` 和一次最小试验核实后写入适配器；不要把交互式 UI 命令假定为自动化 API。Selector 不依赖任何特定模型或 Harness。

### Git 与认领

- 每个工作包从最新 `origin/main` 建独立 worktree，不在用户工作目录中写代码。
- 本地运行记录保存在 worktree 之外，原子写入；至少含 issue、branch、worktree、PR、base SHA、阶段和尝试次数。
- 首版用单进程 runner；若由 GitHub Actions 或 cron 触发，再用同一 concurrency group 防止运行重叠。
- 标签不是分布式事务。即使只有一个 Implementer，也要在启动 Harness 前回读认领，并在写操作前重读 GitHub。
- 推送前 fetch 并检查远端新提交；不 force-push，不直接写 `main`，不清理用户改动。

## 6. 必测场景

纯函数测试至少覆盖：

1. active milestone 的排序、并行轨排除、缺字段、主线内重复顺序，以及 M4/M4x 同号共存。
2. 并行轨回退：主线 blocked 时补位、主线有就绪卡时不抢位、`handoff_release` 不被截走、`invalid_plan` 不被掩盖、并行轨也空时报主线 blocked。
3. 父卡、人工卡、无依赖首卡、多前置、跨 milestone 前置和依赖环。
4. 前置 open、completed、not planned、缺证据和外部依赖未就绪。
5. 多张就绪卡按 `order` 稳定选择；同顺序和 issue/PR 关系歧义被拒绝。
6. 自己的 PR 优先续跑；无关 PR 不被接管；pending CI 返回 `wait`。
7. 重复运行不重复认领、不重复建分支或 PR；合并后依据新快照解锁后继。
8. milestone 清零但未发版时返回 `handoff_release`，不进入下一版本。
9. API 错误、分页遗漏、认领写入失败和 GitHub/本地状态冲突均 fail-closed。

执行器另做故障注入：在认领后、PR 创建后、合并后分别中断并重启，验证都能续跑而不是重复产生副作用。

## 7. 推荐启用顺序

1. **补齐元数据**：先为 active milestone 的工作卡登记 `kind/order/depends_on/external`，同步原生依赖；不启动编码。
2. **只读 dry-run**：只输出动作和排除原因，与人工排期对照。
3. **shadow 运行**：连续运行多次，验证结果稳定、无 GitHub 写入、无重复 PR。
4. **单卡试运行**：选择一张低风险文档卡，由 Maintainer 明确批准后允许认领和调用 Harness。
5. **逐阶段开放**：先完成单卡闭环，再开放自动修 CI/review；自动合并和发版仍遵守各自既有权限与门禁。

本流程的交付是确定性的工作循环，不是“让 Agent 自己看板决定做什么”。