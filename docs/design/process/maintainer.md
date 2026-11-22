# Maintainer：决策与裁决

> 角色性质：**人**（项目维护者 ShiningRay），不可由 AI 替代。
> Maintainer 是所有决策的最终裁决者，所有 AI 角色的产出都可被其推翻。

## 职责范围

### 1. 排期裁决

- 决定哪个 milestone 是 active（主线），哪个是并行轨
- 决定外部 feature issue 的四种归宿（塞入 milestone / backlog / 独立小修 / 不做）
- 决定 milestone 内容量置换——塞进一张新卡就要换出一张等量的卡

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

## 与其他角色的交互

| 交互方 | 方向 | 内容 |
|---|---|---|
| Implementer | Maintainer → Implementer | 下达工作包、指定验收标准 |
| Implementer | Implementer → Maintainer | needsHuman 上报（卡住 / 连续 2 轮无进展） |
| Verifier | Verifier → Maintainer | 核验报告（阻断 / 应修 / 可留）与终验结论（通过 / 有条件通过 / 打回） |
| Triager | Triager → Maintainer | issue 研判结果 + escalate 上报 |
| Release Manager | Maintainer → Release Manager | 发版指令（minor/major） |
| Scribe | Maintainer → Scribe | 文档维护指令 |

## 不可委派的权力

以下决策**永远由人做**，AI 只能摆事实，不能拍板：

1. 这个功能做不做（产品方向）
2. 这个取舍值不值（技术取舍）
3. 这版发不发（冻结口径 / No-Go）
4. 这个人加不加（协作者权限）
