# Seneschal 开发计划（WBS · 排期 · 门禁 · 首迭代）

> 文档职责：回答「怎么建」——M0-M7 工作包分解（WBS）、依赖与排期、里程碑门禁、首迭代逐任务执行清单、覆盖自查与前置风险。
> **2026-11-20 拆分**：原 1051 行单文件按 A–E 节拆入 [plan/](plan/README.md)，本文件保留为总览与索引。各节标题编号未变（`B.3`、`B.9.2` 等仍可直接引用）。
> 不负责什么：「是什么与怎么设计」见 [design.md](design.md) 与 [spec/](spec/README.md)；本文件不重复设计论证，所有模块语义、机制选型、来源依据以 design.md 为准。
> 与 design.md 的关系：本计划 `M*-WP*` 工作包编号引用 design.md §13 目录结构与 §14 路线图验收条目；若实现中范围变化，须回写 design.md 对应章节。格式惯例沿用 Tessell 仓库已验收的 `plan.md`（B 节 WBS）与 `plan-execution.md`（D 节执行分块）。

---

## 规模与版本一览

| 期 | 版本 | 估时 | 包数 | 文件 |
|---|---|---|---|---|
| M0 MVP | v0.1.0（已发布） | 17–25 pd | 9 | [plan/wbs/m0-mvp.md](plan/wbs/m0-mvp.md) |
| M1 多账号+热更新 | v0.1.0（已发布） | 19.5–30 pd | 9 | [plan/wbs/m1-multi-account.md](plan/wbs/m1-multi-account.md) |
| M2 编排完备 | v0.1.0（已发布） | 12.5–19 pd | 6 | [plan/wbs/m2-orchestration.md](plan/wbs/m2-orchestration.md) |
| M3 协作+插件层 | v0.1.0（已发布） | 15–24 pd（+3.5–5 追加） | 6（+2 追加） | [plan/wbs/m3-collab-plugins.md](plan/wbs/m3-collab-plugins.md) |
| M4 Fork/Join 影分身 | v0.2.0 | 27.5–44.5 pd | 18 | [plan/wbs/m4-fork-join.md](plan/wbs/m4-fork-join.md) |
| M5 承诺与提醒闭环 | v0.3.0 | 22–36 pd | 15 | [plan/wbs/m5-commitments.md](plan/wbs/m5-commitments.md) |
| M6 外部日历只读镜像 + 对话式 TUI | v0.4.0 | 25–42 pd | 16 | [plan/wbs/m6-calendar-mirror.md](plan/wbs/m6-calendar-mirror.md) |
| M7 受控投影与撤销审计 | v0.5.0 | 6–10 pd | 4 | [plan/wbs/m7-projection.md](plan/wbs/m7-projection.md) |
| M8 渠道补齐（WeCom + Lark + Slack + email 健壮性） | v0.6.0 | 20–33.5 pd | 10 | [plan/wbs/m8-channels.md](plan/wbs/m8-channels.md) |
| **合计 M0–M8** | — | **168–269.5 pd** | **95** | 33–53 周口径随范围调整重算，见 B.2 |

> **2026-11-26 范围调整**（Maintainer 裁决）：Telegram 相关任务由 M8 迁入 M3（M3-WP7/WP8 追加包 **3.5–5 pd**，未开工；提案 §4.2 的「调度器 failed 批次重试扩展」无估时无 issue，不计入）；企业微信、飞书相关功能与任务由 M1 欠账迁入 M8（M8.1-WP2–WP4，10–16 pd），M8 另含 WP1 扩展点定稿与 Slack WP5。
>
> **2026-11-27 范围调整**（Maintainer 裁决）：M6 追加 M6.5「对话式 TUI」7 包 **5–8 pd**（提案 [tui-conversational-console.md](proposals/tui-conversational-console.md)）；M6 期名扩为「外部日历只读镜像与重估 + 对话式 TUI」。
>
> 合计按此重算：原 M0–M7 的 139.5–223 pd 加 M3 追加 3.5–5 pd 再加 M8 17–28.5 pd 再加 M6 追加 5–8 pd = **165–264.5 pd**；包数 76 + 2 + 8 + 7 = 93。

## 章节索引

| 节 | 文件 | 内容 |
|---|---|---|
| 0 | [输入与证据基线](plan/00-baseline.md) | 输入文档、事实锚、门禁口径 |
| A | [WBS 工作包分解 M0–M7](plan/wbs/README.md) | 8 个期文件 + 拆包依据 |
| B | [排期与门禁总览](plan/schedule/README.md) | B.1–B.9 的分节入口 |
| B.1 | [依赖 DAG（无环）](plan/schedule/dag.md) | 依赖图、三条跨期长边、图-字段口径 |
| B.2 | [逐周排期（双口径）](plan/schedule/weekly.md) | 下限/上限两张时间线、周号口径、算术自查 |
| B.3 | [里程碑门禁 M-gate](plan/schedule/gates.md) | 门禁五项、两条硬约束、Go/No-Go、子门禁效力裁断 |
| B.4–B.7 | [M0–M3 门禁结论](plan/schedule/gate-results.md) | 四期已验收结论与证据链接 |
| B.8 | [M4 期排期与执行分块](plan/schedule/m4.md) | 提案原号映射、期级排期、周块表、算术自查 |
| B.9 | [M5–M7 期排期与版本计划](plan/schedule/m5-m7.md) | 期级排期、周块表、算术自查、版本计划与 milestone 口径 |
| C | [首迭代执行计划 W1–W2](plan/first-iteration.md) | 逐块任务、交付物、验证方式 |
| D | [覆盖矩阵与开放问题](plan/coverage.md) | 16 章→WP、提案 §→WP、开放问题 1–10 |
| E | [外部依赖与前置风险](plan/risks.md) | 外部依赖 1–11、§15.1 前置冒烟 |

## 状态

本文档为**规划态**：全部任务均为后续获授权执行时的验收标准，本文未执行任何代码工作。

- M0–M3 已实现并通过门禁（结论见 [B.4–B.7](plan/schedule/gate-results.md)）。
- **M3 追加包（2026-11-26）**：M3-WP7（ChannelAdapter 扩展点）**已完成**（PR #236 / 5e48db5）；M3-WP8（Telegram 适配器）**未开工**，且其前置「调度器 failed 批次重试扩展」尚无独立 issue。
- **M4**：M4.0–M4.4 代码与文档工作包已全部完成并经 PR 合入 main，milestone 仅剩 1 张 manual 卡（#19 E.1 父卡，待 Gmail 裁决收口后关闭）；v0.2.0 发版待该卡清零。
- **M5–M7** 已拆成 GitHub issue 但**未开工、无实现证据**——对应的 issue 编号与 milestone 见 [B.9.5 版本计划](plan/schedule/m5-m7.md)。
- M8 范围于 2026-11-26 重定为「渠道补齐（WeCom + Lark + Slack）」，Telegram 已迁出。
- **M6 范围于 2026-11-27 扩充**：追加 M6.5「对话式 TUI」7 包（M6.5-WP1–WP7），期名扩为「外部日历只读镜像与重估 + 对话式 TUI」。提案 [tui-conversational-console.md](proposals/tui-conversational-console.md)。
