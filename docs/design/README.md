# docs/design 文档索引

> 导航：[仓库 README](../../README.md) ｜ [设计总览](design.md) ｜ [计划总览](development-plan.md)

本目录是 sebas 的全部设计与计划文档。原先 `design.md`（1026 行）与 `development-plan.md`（1051 行）两件过大、不利检索，2026-11-20 按章/按节拆成 `spec/` 与 `plan/` 两个子目录，两件主文件改为**总览与索引**，条目内容不重复。

## 从哪进

| 你想做 | 进这里 |
|---|---|
| 了解产品形态与设计取舍 | [design.md](design.md) → [spec/](spec/README.md) |
| 知道怎么建、多久、门禁是什么 | [development-plan.md](development-plan.md) → [plan/](plan/README.md) |
| 查当前正在推进的提案 | [proposals/](proposals/) |
| 追溯某个决策的调研依据 | [research/](research/) |
| 看历史门禁/验收/核验记录 | [review/](review/) |
| 开发流程与 Agent 角色分工 | [process/](process/README.md) |

## 设计正文 `spec/`（17 篇，按章拆自 design.md）

[spec/README.md](spec/README.md) 是章节索引。章号与 `§锚` 保持不变——`design.md §12.11` 指向 [spec/12-plugin-layer.md](spec/12-plugin-layer.md) 的对应小节；**行号锚已全部废弃**。

## 开发计划 `plan/`（18 篇，按节拆自 development-plan.md）

[plan/README.md](plan/README.md) 是总入口，四组：

- `plan/00-baseline.md`：输入与证据基线。
- `plan/wbs/`：M0–M7 工作包分解，一期一文件。
- `plan/schedule/`：B.1 DAG、B.2 逐周排期、B.3 门禁、B.4–B.7 门禁结论、B.8 M4 排期、B.9 M5–M7 排期与版本计划。
- 顶层四篇：首迭代、覆盖矩阵、外部依赖。

## 提案 `proposals/`（10 篇）

| 文件 | 行数 | 主题 |
|---|---|---|
| [fork-join-semantics.md](proposals/fork-join-semantics.md) | 391 | fork/join 影分身语义 |
| [parallel-implementers.md](proposals/parallel-implementers.md) | 377 | 多任务并行开发：每卡独立租约与集中合并收口（#190 定稿候选，未定稿） |
| [commitments-calendar-integration.md](proposals/commitments-calendar-integration.md) | 338 | 承诺与日历整合：Calendar 作为持久意图与时间上下文层（M5–M7 输入） |
| [m8-channel-expansion-slack-telegram.md](proposals/m8-channel-expansion-slack-telegram.md) | 237 | M8 渠道扩展（Slack + Telegram）——对标 Hermes/OpenClaw |
| [session-input-scheduling.md](proposals/session-input-scheduling.md) | 216 | 会话输入调度（队列/debounce/正交 steer） |
| [fork-join-shadow-clone-architecture.md](proposals/fork-join-shadow-clone-architecture.md) | 185 | 影分身架构 |
| [fork-join-shadow-clone-positioning.md](proposals/fork-join-shadow-clone-positioning.md) | 161 | 影分身定位 |
| [parallel-implementers-recovery.md](proposals/parallel-implementers-recovery.md) | 135 | 多任务并行开发续篇：恢复、迁移与验证（未定稿） |
| [agent-category-tags.md](proposals/agent-category-tags.md) | 109 | Agent 分类与标签：元数据模型与管理面查询 |
| [busy-interrupt-redirect.md](proposals/busy-interrupt-redirect.md) | 84 | 忙时插话与转向 |

## 调研 `research/`（7 篇）

| 文件 | 行数 | 主题 |
|---|---|---|
| [channels-wecom-lark-email.md](research/channels-wecom-lark-email.md) | 277 | 企业微信 / 飞书 / email 渠道调研 |
| [autobot-architecture.md](research/autobot-architecture.md) | 269 | autobot 架构与可复用件（A1–A10） |
| [crystal-hot-reload.md](research/crystal-hot-reload.md) | 237 | Crystal 热重载机制 |
| [openclaw.md](research/openclaw.md) | 225 | OpenClaw 旁证 |
| [hermes-agent.md](research/hermes-agent.md) | 218 | Hermes Agent 旁证 |
| [pi-durable.md](research/pi-durable.md) | 145 | Pi 持久化/恢复旁证 |
| [prior-art-notes.md](research/prior-art-notes.md) | 108 | 旁证汇总 |

## 核验与记录 `review/`（12 篇）

| 文件 | 行数 | 主题 |
|---|---|---|
| [verification.md](review/verification.md) | 382 | 三轮设计核验记录 |
| [plugin-evolution.md](review/plugin-evolution.md) | 193 | 插件层演进评估 |
| [development-plan-verification.md](review/development-plan-verification.md) | 140 | 开发计划核验 |
| [acceptance.md](review/acceptance.md) | 128 | 首轮验收报告 |
| [m3-plugin-feasibility.md](review/m3-plugin-feasibility.md) | 89 | mruby 插件层可行性 |
| [m1-gate.md](review/m1-gate.md) | 81 | M1 门禁证据 |
| [acceptance-round2.md](review/acceptance-round2.md) | 76 | 第二轮验收 |
| [m2-gate.md](review/m2-gate.md) | 72 | M2 门禁证据 |
| [m3-gate.md](review/m3-gate.md) | 70 | M3 门禁证据 |
| [smoke-ex-w1-03.md](review/smoke-ex-w1-03.md) | 61 | 首迭代冒烟记录 |
| [m0-gate.md](review/m0-gate.md) | 58 | M0 门禁证据 |

`review/` 下的报告是**存档证据**，其中出现的行号是当时那一版文件的行号，检索时按「行版」口径读，不再回改。

## 开发流程 `process/`（11 篇）

| 文件 | 主题 |
|---|---|
| [process/README.md](process/README.md) | 流程索引与核心原则 |
| [process/oneline.md](process/oneline.md) | 一句话开工速查表：每个角色一行，直接粘进 Harness |
| [process/quickstart.md](process/quickstart.md) | 克隆后用 `tools/sebas-process` 起各角色 Agent |
| [process/implementer-loop.md](process/implementer-loop.md) | 单 Implementer 选卡、续跑与收口契约 |
| [process/development-workflow.md](process/development-workflow.md) | 开发工作流总纲：分支模型、里程碑、issue、验收、发版 |
| [process/maintainer.md](process/maintainer.md) | Maintainer（人）：决策与裁决 |
| [process/implementer.md](process/implementer.md) | Implementer（AI）：实现与交付 |
| [process/verifier.md](process/verifier.md) | Verifier（AI）：独立核验与终验（#124 起 Reviewer 并入） |
| [process/triager.md](process/triager.md) | Triager（AI）：issue 研判 |
| [process/scribe.md](process/scribe.md) | Scribe（AI）：文档与记忆 |
| [process/release-manager.md](process/release-manager.md) | Release Manager（AI）：发版执行 |

## 其他

- [naming.md](naming.md)：平台命名（Seneschal）与 14 个候选撞名核实。
- [fork-join-shadow-clone-analysis.md](fork-join-shadow-clone-analysis.md)：fork/join 影分身分析与问题清单。

## 维护约定

- **引用一律用 `§锚` 或具体文件路径**，不用行号；`tools/check_docs.rb` 会在 CI 拦截行号锚与死链。
- 新增设计内容写进 `spec/` 对应章并在 `spec/README.md` 登记；新增计划内容写进 `plan/` 对应节并在 [plan/README.md](plan/README.md) 登记。
- 单文件体量按三项并列判定：物理行 ≤ 400、等效屏幕行 ≤ 400、单行显示宽度 ≤ 400 列；超过时 `check_docs.rb` 告警。长行应拆子列表、表格或小节，不要用硬折行——Markdown 软换行会渲染成空格。口径见 [process/scribe.md §体量口径](process/scribe.md)。
