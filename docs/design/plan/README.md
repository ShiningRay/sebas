# development-plan 分册索引

> 导航：[设计总览](../design.md) ｜ [文档索引](../README.md) ｜ [计划总览](../development-plan.md)

`development-plan.md` 原为 1051 行单文件，2026-11-20 按 A–E 节拆到本目录。**节编号未变**——`B.3`、`B.9.2` 这类引用仍然成立，只是内容落在下列文件中。

## 0 与 A 节：WBS 工作包分解

| 文件 | 内容 |
|---|---|
| [00-baseline.md](00-baseline.md) | 0. 输入与证据基线：输入文档、事实锚、估算口径、证据标注纪律 |
| [wbs/README.md](wbs/README.md) | A. WBS 总览：8 期表、期与版本对应、拆包依据 |

各期分册（一期一文件，含全部 `M*-WP*` 包）：

- [wbs/m0-mvp.md](wbs/m0-mvp.md) · [wbs/m1-multi-account.md](wbs/m1-multi-account.md) · [wbs/m2-orchestration.md](wbs/m2-orchestration.md) · [wbs/m3-collab-plugins.md](wbs/m3-collab-plugins.md)
- [wbs/m4-fork-join.md](wbs/m4-fork-join.md) · [wbs/m4x-platform.md](wbs/m4x-platform.md) · [wbs/m5-commitments.md](wbs/m5-commitments.md) · [wbs/m6-calendar-mirror.md](wbs/m6-calendar-mirror.md) · [wbs/m7-projection.md](wbs/m7-projection.md) · [wbs/m8-channels.md](wbs/m8-channels.md)

## B 节：排期与门禁

| 节 | 文件 | 内容 |
|---|---|---|
| B | [schedule/README.md](schedule/README.md) | 本节入口 |
| B.1 | [schedule/dag.md](schedule/dag.md) | 依赖 DAG（无环）、三条跨期长边 |
| B.2 | [schedule/weekly.md](schedule/weekly.md) | 逐周排期（下限/上限双口径）、周号口径 |
| B.3 | [schedule/gates.md](schedule/gates.md) | 里程碑门禁五项、两条硬约束、Go/No-Go、子门禁效力 |
| B.4–B.7 | [schedule/gate-results.md](schedule/gate-results.md) | M0–M3 门禁结论 |
| B.8 | [schedule/m4.md](schedule/m4.md) | M4 期排期与执行分块 |
| B.9 | [schedule/m5-m7.md](schedule/m5-m7.md) | M5–M7 期排期、周块表、算术自查、版本计划与 milestone 口径 |

## C–E 节

| 节 | 文件 | 内容 |
|---|---|---|
| C | [first-iteration.md](first-iteration.md) | 首迭代执行计划（W1–W2）逐块任务与验证 |
| D | [coverage.md](coverage.md) | 覆盖矩阵（16 章→WP、提案 §→WP）与开放问题 1–10 |
| E | [risks.md](risks.md) | 外部依赖 1–11 与前置冒烟 |

## 维护约定

- 新增工作包写进对应期分册，并在 [wbs/README.md](wbs/README.md) 的期表里更新估时与行数。
- 新增排期/门禁内容写进 `schedule/` 对应节；不要回填到主文件。
- 引用一律用节号（`B.3`）或文件路径，不用行号。
