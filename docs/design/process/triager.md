# Triager：Issue 研判

> 角色性质：**AI**（独立 agent），只读仓库 + 可写 issue 元数据（标签/类型/指派/评论）。
> 负责 issue 的接收、研判与分派。

## 职责范围

### 1. Issue 研判

对非计划类 issue 做完整研判，产出六档判定：

| 判定 | 含义 | 动作 |
|---|---|---|
| `bug-confirmed` | 确认是 bug | 加 `bug` 标签 + `type=Bug` + 指派 ShiningRay |
| `needs-info` | 信息不足无法判断 | 加 `question` 标签，不指派 |
| `accepted` | 确认是值得做的建议 | 加 `enhancement` 标签 + 指派 ShiningRay |
| `rejected` | 不适合做 | 加 `invalid` 标签 + 写明补足哪点才重新考虑 |
| `duplicate` | 重复 | 给出重复对象后 close --reason "not planned" |
| `escalate` | 需要人拍板 | 不改状态，进最终回复与飞书通知 |

判定顺序：先查重 → 再看是否已修复/设计如此 → 最后按 bug/建议分派。

### 2. Proposal 的状态维护

带 `proposal` 标签的 issue 由 Triager 查重、澄清和整理讨论，但**不接受设计、不指派开发、
不设置 milestone**。可使用以下提案专用判定：

| 判定 | 使用条件 | 动作 |
|---|---|---|
| `needs-design` | 方向值得讨论，但取舍或影响尚不清楚 | 加 `proposal:needs-design` + `question`，说明待解决问题 |
| `accepted-design` | Maintainer 已明确接受设计 | 加 `proposal:accepted-design`；评论须含 `maintainer_decision_url`，不自动拆卡 |
| `declined` | Maintainer 已明确拒绝 | 加 `proposal:declined`；评论须含 `maintainer_decision_url` 和理由，关闭为 not planned |

`needs-design` 不要求提案者自行提交文档 PR。达到可整理程度后由 Scribe 接续；接受设计后，
排期仍由 Maintainer 单独决定。`accepted-design` / `declined` 的 verdict 必须带 Maintainer
公开评论或 review 的 `maintainer_decision_url`，缺链接时工具拒绝生成状态变更。状态标签互斥，
新判定生成清理旧状态的 remove_label 动作。普通 bug / feature 继续使用既有六档判定。

### 3. 计划类 issue 的特殊处理

带 `plan` 标签的 issue（工作包卡）不做研判，只做一件事：
- 无 assignee → 自动补指派 ShiningRay
- 已有 assignee → 直接跳过，零成本

### 4. Issue Type 与 Assignee 规则

- **type 按 issue 性质定**，不按判定定：报 bug 的 Bug、提需求或 Proposal 的 Feature、文档/CI/工具的 Task
- **assignee 唯一规则**：仅普通 issue 的 `bug-confirmed` 或 `accepted` 才指派；Proposal 三判定不指派
- `escalate` 不指派——它需要人拍板但不是开发任务，靠飞书转告不占 assignee

### 5. Bug 的 milestone 归属建议

研判时多问一句"影响已发布版本吗？严重吗？"：

- 严重（崩溃/数据丢失/安全）→ 建议建 hotfix milestone，评论写明"走 hotfix 通道"
- 普通 → 建议挂 active feature milestone，评论注明"占用本期容量"
- 本期范围内缺陷 → 建议挂在对应 WP 卡下做 sub-issue

建议不直接执行——milestone 归属由Maintainer裁决。

## 工作逻辑

### 复现标准

依赖运行时行为的缺陷必须真跑一遍：

- 跑现有测试或写 scratch 最小脚本
- 把失败输出贴评论
- 没跑出失败 → 写 `needs-info`，不猜

只读到代码逻辑矛盾（注释声称做了某事、实现却没做）可直接判 bug——那是代码事实。

环境跑不起来 → 写 `escalate`，不降级成推断。

### 绝对禁止

- 改仓库源码
- git commit / push / 建分支
- 发版
- 动生产

允许：读代码、跑现有测试、在 scratch 目录写临时脚本。

### 评论格式

每条研判评论带三部分：

```
<!-- status: <判定> -->
<!-- arch: issue-arch -->
<研判正文：结论 + 证据 + 建议动作>
```

## 可执行实现：完整研判流程

Triager 的确定性部分在 `tools/agents/lib/sebas_agents/triager.rb`：

```ruby
require_relative "tools/agents/lib/sebas_agents"

plan = SebasAgents::Triager.plan(issue, snapshot)
plan["decision"]    # plan-card / needs-model-verdict / 判定值
plan["actions"]     # [{action: "add_label", name: "bug"}, ...]
plan["needs_model"] # 需要模型判断的项；不猜
```

判定由模型给出，工具只负责把它翻译成确定的元数据动作：

```sh
ruby tools/sebas-process triage 42
```

## 可执行实现：active milestone 判定

唯一实现为 `tools/agents/lib/sebas_agents/policy/milestones.rb`；Triager 不另写排序或 title 兜底：

```ruby
require_relative "tools/agents/lib/sebas_agents"

milestones = SebasAgents::Policy::Milestones.normalize(snapshot.milestones)
state, active = SebasAgents::Policy::Milestones.active(milestones)
# state: :select / :handoff_release / :idle
active&.number # => 2
```

## 基础设施

Triager通过两条路径触发：

1. **webhook**：issue 创建/编辑时实时触发（`github-issues` 路由）
2. **cron**：每日 05:00 全量扫描（当前外部脚本为 `github-issue-reconcile.py`；按仓库运维约定迁移为 `github-issue-reconcile.rb`，迁移前旧脚本仍为事实源）。

两条路径共享同一份 `scope.json` 配置和同一份研判规则。
`skip_labels: ["plan"]` 控制计划类跳过，`plan_assign_to: "ShiningRay"` 控制自动补指派。
