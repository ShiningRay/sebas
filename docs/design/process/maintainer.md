# Maintainer：决策与裁决

> 角色性质：**人**（项目维护者 ShiningRay），不可由 AI 替代。
> Maintainer 是所有决策的最终裁决者，所有 AI 角色的产出都可被其推翻。

## 职责范围

### 1. Proposal 设计与排期裁决

- 对 Proposal issue 分别决定：拒绝、要求补设计、接受设计；结论和理由留在原 issue
- `accepted-design` 只表示设计原则可接受，不等于批准排期、实现或版本交付
- 需要设计文档时，指令 Scribe 整理 Issue 共识并提交归档 PR；文档入库不等于定稿
- 对 Scribe 提交的定稿候选作最终裁决；只有明确 `accepted-design` 才算设计定稿
- 排期批准后指令 Scribe 创建带 Automation 块的工作包并挂 milestone；禁止把 Proposal 直接交给 Implementer 开工
- 决定外部 feature issue 的四种归宿（塞入 milestone / backlog / 独立小修 / 不做）
- 决定哪个 milestone 是 active（主线），哪个是并行轨
- 决定 milestone 内容量置换——塞进一张新卡就要换出一张等量的卡
- 排期批准后创建工作包并挂 milestone（status=Todo）；禁止把 Proposal 直接交给 Implementer 开工

### 并行容量与合并队列

- 在途租约上限由 `.github/agents.yml` 的 `capacity` 键决定，缺键即 1；提升后
  `plan` 与 `claim` 都按新容量判定（迁移窗口内仍钳回 1）。
- 提升容量前先确认要并行的卡都写了 `scope`：缺 scope 的卡独占容量，等于没提。
- 合并由 `queue --apply` 逐张推进；Evidence 升级是异步的，串行单位到升级完成。
  卡住（verify 不通过、CHANGELOG 未就绪、Evidence 超时）时停下来由 Maintainer 裁决，
  不要让 coordinator 自行重试。

### 指令格式

设计阶段可写：`接受 #N 的方向，先由 Scribe 提交定稿候选，不排实现。`
定稿阶段可写：`#N 设计定稿，按 <文档/章节> 执行；暂不排期。`
排期阶段可写：`#N 纳入 <已有/新 milestone>，范围为 <包含/排除项>；请 Scribe 拆 plan 工作包，先不要实现。`
新 milestone 指令补充版本目标、`order` 与 `track`；已有 milestone 的容量置换由 Maintainer 决定。
独立小修属于明确实现排期指令：type=Task、不挂 milestone，开工方式是显式给出 issue 号由执行者 `claim`，
不进自动选卡（详见 [development-workflow.md](development-workflow.md) 的四种归宿）。
`backlog` 只记录延期，不授权创建实现工作包，后续须另行批准实现排期。
缺少归宿或范围时，Scribe 应提问而非推断。

### 可执行工具：accept-proposal

`tools/accept-proposal` 把上述接受与排期裁决落成一条命令，替代手工发评论与改标签。
默认 dry-run，`--apply` 才写 GitHub；`--reason`（或 `--reason-file`）给公开理由，
`--milestone`（数字或标题，须已开放）顺带把 Proposal 挂到该 milestone。

```sh
ruby tools/accept-proposal 159 --reason "方向成立，按建议收敛"
ruby tools/accept-proposal 159 --reason "排期进 v0.2.0" --milestone v0.2.0 --apply
```

脚本发带 `<!-- proposal-verdict: accepted-design -->` 的公开评论、登记裁决证据 marker，
复用 `Triager.plan` 完成校验与状态标签落地；指定 milestone 时在评论留公开排期理由并挂载。
它只做设计定稿与排期登记，**不拆 plan 工作包**——拆卡仍由 Maintainer 另发指令、Scribe 执行。
Proposal 上的 milestone 只是排期意图记录，Implementer 只按 Scribe 拆出的工作包卡（有 Automation 块）选卡；
Proposal 本身不进实现选卡。
使用前提与完整参数见 [quickstart.md](quickstart.md) 的 Maintainer 段；测试见
`tools/tests/process/test_accept_proposal.rb`。

### 2. 范围决策

- 决定某期的 WP 划分是否合理，是否需要拆并
- 决定并行轨的开启与关闭（上限 2 条）
- 决定 DAG 上的依赖关系是否准确

### 3. 冻结口径裁断

当某期验收时外部依赖未就绪（如 E.1 系列账号未配置），决定是否允许"冻结态交付"：

三条件缺一不可：
1. mX-gate.md 单列「未并入」项并写明影响面
2. 产品面（README / 文档）显式标注该限制，不呈现为已达成目标
3. 该限制条目同步记入 design.md §15.1

任一条件不满足即 No-Go，改判。

### 4. 发版终审

- minor 版本：审 m-gate 证据后点 workflow_dispatch 确认
- major 版本：走完整人工九步流程
- patch 版本：信任 auto-release.yml 的自动化，但保留随时叫停的权力

### 5. 直接干预

任何 AI 角色的产出——Implementer 的代码、Verifier 的核验报告、Triager 的研判结论——
Maintainer 都可以直接修改、推翻、或接管。这不是例外，是常态。

## 工作逻辑

Maintainer 不主动执行任务，而是**响应两种输入**：

1. **AI 角色的上报**：Verifier 的"应修"项、Triager 的"escalate"判定、Implementer 的"needsHuman"状态
2. **定期巡检**：看板上过一遍 active milestone 的进度，确认没有卡死或跑偏

### 决策依据

每个决策必须锚到具体证据：
- 排期裁决 → DAG 依赖图 + 容量估算
- 冻结口径 → m-gate.md 的未实测项清单
- 发版终审分两个阶段：
  - **pre-tag 审批**（打 tag 前）→ Verifier 的核验报告 + CI 全绿 + m-gate.md 证据完整
  - **post-build 产物验收**（release.yml 跑完后）→ sha256 全过 + 裸容器冒烟通过，过了才关 milestone

不做没有证据支撑的决定。如果证据不足，打回给对应 Agent 补证据。

### 自动合并开关（auto_merge_enabled，#222）

合并队列自动触发（阶段 4）由 `.github/agents.yml` 的 `auto_merge_enabled` 控制，
**缺省 false**——不显式启用就保持阶段 3 的人工触发，任何机器上的 `queue --auto`
都会整体拒绝。

- **启用**：把该键置 `true` 并合入 main。启用前自检三件事：分支保护规则未被放宽、
  `trusted_bots` / `coordinators` 白名单未扩、近一周无未收口的 Evidence 链异常。
  启用后 coordinator 在条件齐备时自动推进合并队列（触发条件与接续边界见
  [implementer-loop.md §3.8](implementer-loop.md)）。
- **关停**：置回 `false` 即回到阶段 3 行为，进行中的自动链在下一步自然停轮；
  无需清理运行记录。紧急关停只改这一处配置，不需要撤 PR 或动 workflow 权限。
- **巡检**：`plan` 输出的 `merge_queue` 字段是自动链的观察窗（队首 PR、队列长度、
  阻塞原因）；自动失败达 2 次的卡会停在 `auto_gate` 报错上等人工
  `queue --apply` 成功一步重置。终验「有条件通过」的 PR 永远不会自动合并，
  由 Maintainer 逐张裁决。

## 与其他角色的交互

| 交互方 | 方向 | 内容 |
|---|---|---|
| Implementer | Maintainer → Implementer | 下达工作包、指定验收标准 |
| Implementer | Implementer → Maintainer | needsHuman 上报（卡住 / 连续 2 轮无进展） |
| Verifier | Verifier → Maintainer | 核验报告（阻断 / 应修 / 可留）与终验结论（通过 / 有条件通过 / 打回） |
| Triager | Triager → Maintainer | issue 研判结果 + escalate 上报 |
| Release Manager | Maintainer → Release Manager | 发版指令（minor/major） |
| Scribe | Maintainer → Scribe | 定稿候选请求；含版本与范围的排期指令 |
| Scribe | Scribe → Maintainer | 定稿候选、待裁决项、工作包与开工前置条件回报 |

## 不可委派的权力

以下决策**永远由人做**，AI 只能摆事实，不能拍板：

1. 这个功能做不做（产品方向）
2. 这个取舍值不值（技术取舍）
3. 这版发不发（冻结口径 / No-Go）
4. 这个人加不加（协作者权限）
