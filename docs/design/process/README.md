# docs/design/process 开发流程与 Agent 角色

> 导航：[docs/design 索引](../README.md) ｜ [CONTRIBUTING](../../../CONTRIBUTING.md)

本目录定义 sebas 仓库的完整开发流程与参与流程的 Agent 角色分工。
2026-11-20 按当日讨论定稿。

## 总纲

| 文件 | 内容 |
|---|---|
| [development-workflow.md](development-workflow.md) | 分支模型、里程碑排期、issue 生命周期、验收体系、发版流程、角色总览 |
| [proposal-lifecycle.md](proposal-lifecycle.md) | Proposal 的权威归属、文档状态行、小改/大改/取代规则、拆卡后的存续 |
| [oneline.md](oneline.md) | 一句话开工速查表：每个角色一行，直接粘进 Harness |
| [quickstart.md](quickstart.md) | 克隆仓库后如何用 `tools/sebas-process` 在 5 分钟内启动各角色 Agent |
| [implementer-loop.md](implementer-loop.md) | 单 Implementer 的选卡、续跑与收口契约（可执行实现见 `tools/sebas-process`） |
| [llm-semantic-verification-evaluation.md](llm-semantic-verification-evaluation.md) | #123 评估：LLM 语义核验为什么不做（含可复查的重新评估条件） |

## Agent 角色

| 文件 | 角色 | 性质 | 核心职责 |
|---|---|---|---|
| [maintainer.md](maintainer.md) | Maintainer | 人 | 拍板：Proposal 设计与排期、范围决策、冻结口径裁断、发版终审 |
| [implementer.md](implementer.md) | Implementer | AI | 执行：实现工作包、修 review、修 CI、提 PR |
| [verifier.md](verifier.md) | Verifier | AI | 独立核验与终验：锚点实证、一致性对账、行为实测；终验对应修项复跑收口（#124 起 Reviewer 并入） |
| [triager.md](triager.md) | Triager | AI | issue 研判与 Proposal 状态维护：不替 Maintainer 接受设计或排期 |
| [scribe.md](scribe.md) | Scribe | AI | 设计定稿候选、排期与任务拆解执行、文档与记忆；不替代 Maintainer 裁决 |
| [release-manager.md](release-manager.md) | Release Manager | AI | 发版执行：版本号 bump、tag 管理、产物校验 |

## 核心原则

1. **执行与验收分离**：Implementer做的东西由Verifier验，Verifier的应修项由终验阶段复跑收口（#124 起 Reviewer 并入，两阶段分离进程）
2. **独立上下文**：验收 agent 不能是实现 agent——同一上下文既写代码又验收等于自己改考卷
3. **实证主义**：每条结论锚到具体命令输出 / 行号 / API 返回，不接受"应该""看起来"
4. **允许未实测**：跑不了就写未实测，不许编证据
5. **人做意图裁决**：产品方向、技术取舍、冻结口径、发版终审永远由Maintainer（人）拍板
