# development-plan 0. 输入与证据基线

> 导航：[设计总览](../design.md) ｜ [文档索引](../README.md) ｜ [计划总览](../development-plan.md) ｜ 下一节：[WBS](wbs/README.md)

## 0. 输入与证据基线

| 输入 | 路径 | 关键事实 | 来源 |
|---|---|---|---|
| 设计主体 | [design.md](../design.md) | 16 章：三正交概念/分层架构/多账号/编排/协作/管理面/安全/热更新(§11)/插件(§12：子进程+包生命周期)/目录结构(§13)/M0-M3 路线图(§14)/风险(§15)/来源对照表 41 条(§16)+附录 | [来源: design.md §1~§16] |
| 目录结构基线 | design.md §13 | src/{platform,config,bus,supervisor,store,keys}/+channels/routing/agents/orchestration/tools/providers/admin/plugins/ 模块划分与 A1-A10 承接表 | [来源: design.md §13] |
| 里程碑验收 | design.md §14 | M0-M3 各期验收要点+排期依据（热更新 M1、插件 M3） | [来源: design.md §14] |
| 风险与未验证 | design.md §15 | 未验证 13 条（15.1）/架构风险 7 条（15.2）/取舍 3 条（15.3）；mrb.cr 甄别与 Windows 构建 blocker 已更新 | [来源: design.md §15] |
| 质量门禁惯例 | [CONTRIBUTING.md](../../../CONTRIBUTING.md) 质量门禁节 | `crystal spec` 全过 / `crystal tool format --check` / `./bin/ameba` 无警告 / `make release` 成功 / 改动须同步 docs | [来源: 仓库:CONTRIBUTING.md Quality gates 节] |
| 格式范本 | tessell/docs/plan.md、plan-execution.md | `M*-WP*` 编号、pd 区间估算、相对周、EX-W1-01 执行分块、DoD 分层、状态与证据边界纪律 | [来源: 任务输入] |
| 平台命名 | design.md 附录 1 | **已定名 Seneschal**（[naming.md](../naming.md) 14 候选撞名全核实；用户保留推翻权，推翻则全文再替换） | [来源: design.md 附录] |
| 承诺与日历提案（M5–M7 输入） | [proposals/commitments-calendar-integration.md](../proposals/commitments-calendar-integration.md) | 338 行：§1 核心判断（Calendar=持久意图与时间上下文层）/§2 七原则/§3 九态与提醒纪律/Today 六段/§4 十对象与四类时间表示/§5 cron 退到唤醒层/§6 三种接入深度与失败四态/§7 canonical superset + CalDAV·Google·Graph adapter/§8 非目标/§9 首闭环保留与必须验证边界 | [来源: 仓库:docs/design/proposals/commitments-calendar-integration.md；PR #61 合入 main] |

**估算口径**：单人全职（每周 5 人日），工作量单位 **人日（pd）区间**；时间只用相对周 `W1/W2…`，禁止绝对日期；估算为「熟悉 Crystal 语言与 autobot 既有代码模式、渠道文档齐备且账号申请就绪」前提下的工程量，不确定性显式保留 `[未验证]`；禁止编造任何数字。各包估时含单测与门禁自检，不含渠道账号行政审批等待（外部依赖见 E 节）。

**证据标注纪律**：`[来源: design.md §x]` / `[来源: 仓库:路径:行]` / `[来源: 任务输入]` / `[推演]` / `[未验证]`。**引用 design.md 一律用章/节号，不用行号**——2026-11-20 拆分后行号已失效，`tools/check_docs.py` 在 CI 拦截行号锚。引用 design.md 时其来源限定（「未验证/笔记推论/证据局限」）照抄不升级；本文新增的排期判断一律标 `[推演]`。
