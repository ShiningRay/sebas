# docs/design/process 开发流程与 Agent 角色

> 导航：[docs/design 索引](../README.md) ｜ [CONTRIBUTING](../../../CONTRIBUTING.md)

本目录定义 sebas 仓库的完整开发流程与参与流程的 Agent 角色分工。
2026-11-20 按当日讨论定稿。

## 总纲

| 文件 | 内容 |
|---|---|
| [development-workflow.md](development-workflow.md) | 分支模型、里程碑排期、issue 生命周期、验收体系、发版流程、角色总览 |

## Agent 角色

| 文件 | 角色 | 性质 | 核心职责 |
|---|---|---|---|
| [maintainer.md](maintainer.md) | Maintainer | 人 | 拍板：排期裁决、范围决策、冻结口径裁断、发版终审 |
| [implementer.md](implementer.md) | Implementer | AI | 执行：实现工作包、修 review、修 CI、提 PR |
| [verifier.md](verifier.md) | Verifier | AI | 独立核验：锚点实证、一致性对账、行为实测 |
| [reviewer.md](reviewer.md) | Reviewer | AI | 终验复核：应修项收口、终验通过判定 |
| [triager.md](triager.md) | Triager | AI | issue 研判：六判定、type/label/assignee、milestone 建议 |
| [scribe.md](scribe.md) | Scribe | AI | 文档与记忆：设计文档维护、记忆库存取、CHANGELOG |
| [release-manager.md](release-manager.md) | Release Manager | AI | 发版执行：版本号 bump、tag 管理、产物校验 |

## 核心原则

1. **执行与验收分离**：Implementer做的东西由Verifier验，Verifier的应修项由Reviewer复核
2. **独立上下文**：验收 agent 不能是实现 agent——同一上下文既写代码又验收等于自己改考卷
3. **实证主义**：每条结论锚到具体命令输出 / 行号 / API 返回，不接受"应该""看起来"
4. **允许未实测**：跑不了就写未实测，不许编证据
5. **人做意图裁决**：产品方向、技术取舍、冻结口径、发版终审永远由Maintainer（人）拍板
