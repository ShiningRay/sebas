# development-plan M2 · 编排完备（12.5–19 pd）

> 导航：[设计总览](../../design.md) ｜ [文档索引](../../README.md) ｜ [计划总览](../../development-plan.md) ｜ 上一节：[M1](m1-multi-account.md) ｜ 下一节：[M3](m3-collab-plugins.md)

### M2 · 编排完备——估时合计 12.5–19 pd

**M2-WP1 编排 DSL 解析与校验**（2–3 pd）
- 目标：触发→条件→动作 YAML 可写可校验。
- 范围：`orchestration/dsl/` 解析、校验器（动作引用悬空/账号不存在报错）、示例库。
- 交付物：DSL 解析+校验 spec。
- 依赖：M1 门禁。
- 验收：坏 DSL 报错可读；示例两则（design.md §7 DSL）解析通过。
- 风险：无实质风险。

**M2-WP2 持久 Task 引擎**（3–4 pd）
- 目标：workflow=持久状态机。
- 范围：`orchestration/engine.cr`：状态机+phase checkpoint、崩溃重放（重放单位=phase）、restartLimit。
- 交付物：引擎+重放 spec。
- 依赖：M2-WP1。
- 验收：**workflow run 崩溃重放幂等**（kill 点重放不重复执行已完 phase）（§14 M2 验收第 1 条 [来源: design.md §14]）。
- 风险：phase 粒度过细致重放开销——默认粗粒度+文档指导。

**M2-WP3 触发器统一**（2–3 pd）
- 目标：cron/事件/webhook 归一。
- 范围：`orchestration/triggers/`：cron【A10 owner 加账号维度】、消息事件触发、webhook 唤醒（复用 M1-WP9 监听器）。
- 交付物：触发器+调度 spec。
- 依赖：M2-WP2。
- 验收：三种触发器各起一个 run 且落账本。
- 风险：无实质风险。

**M2-WP4 审批节点**（2–3 pd）
- 目标：审批链 fail-closed。
- 范围：`orchestration/approvals/`：超时 deny、无人值守 deny、hardline blocklist 不可 override、审批交互（TUI+HTTP 双入口）。
- 交付物：审批模块+交互 spec。
- 依赖：M2-WP3、M0-WP7（交互面）。
- 验收：**审批超时 deny 实测**（注入时钟快进）（§14 M2 验收第 2 条 [来源: design.md §14]）。
- 风险：无实质风险。

**M2-WP5 lease+回收+预算+账本**（2–3 pd）
- 目标：任务不悬空、预算可熔断。
- 范围：`orchestration/ledger.cr`：append-only 账本、lease 过期回收、预算记账。
- 交付物：账本+回收 spec。
- 依赖：M2-WP2。
- 验收：**预算熔断**（超预算动作拒绝+账本留痕）（§14 M2 验收第 3 条 [来源: design.md §14]）。
- 风险：无实质风险。

**M2-WP6 编排面板消费 API**（1.5–2.5 pd）
- 目标：runs 可回放可审计。
- 范围：HTTP API 扩展：runs 列表/详情/事件回放。
- 交付物：API+回放 spec。
- 依赖：M2-WP5。
- 验收：**runs 回放与审计**（任一 run 可按事件序重放展示）（§14 M2 验收第 4 条 [来源: design.md §14]）。
- 风险：无实质风险。
