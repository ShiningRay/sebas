# development-plan M5 · 持久意图、唤醒与提醒闭环（22–36 pd）

> 导航：[设计总览](../../design.md) ｜ [文档索引](../../README.md) ｜ [计划总览](../../development-plan.md) ｜ 上一节：[M4](m4-fork-join.md) ｜ 下一节：[M6](m6-calendar-mirror.md)

### M5 · 持久意图、唤醒与提醒闭环——估时合计 22–36 pd（2026-11-20 追加，v0.3.0）

> 依据：[proposals/commitments-calendar-integration.md](../../proposals/commitments-calendar-integration.md) §1–§5、§8–§9（提案已随 PR #61 合入 main）。本节只做工作包、依赖、估时与验收；**不新造设计决策**——语义有变更回写提案与 design.md，不在本计划内定。
> 期定位：把 cron 从「用户产品层」降到「唤醒基础设施层」（提案 §5），新增 Commitment/Checkpoint/Reminder/NotificationDelivery 领域对象与持久 WakeSchedule/Occurrence/Run 链路。**本期不含任何外部日历/TODO 接入**（M6/M7 承接），也不做 tombstone 式 UI。
> 期门禁：调度四条全绿（`make format-check` + `make spec` + `make lint` + `make release`；
> 其中 `make spec` 即 [Makefile](../../../../Makefile) 的 `spec: crystal spec`）。

**M5.0 例外且需精确表述**：

- M5.0-WP1 是纯文档包（以评审通过替代命令门禁）。
- M5.0-WP2 不是纯文档包——它同时交付纯函数时间语义模块与 spec，
  因此 **M5.0 期门禁 = 文档评审通过 + 调度四条在该模块上全绿**。

**WP2「完工」的定义就是 M5.0 期门禁通过**（即 ⓐ 全部条件，含文档评审与调度四条，不做裁剪）。
由此得一条单向箭头 **WP2 未完工 ⇒ M5.1 不得开工**（等价写法：M5.0 No-Go ⇒ M5.1 不得开工）。
反向**不成立**——M5.1 等待也可能只是因为 spec 后来变红，而 WP2 当时已完工。

**M5.1 开工闸 = spec 全绿 且 WP2 已完工**。两道闸判定标准不同、可以不等
（可出现「M5.0 已过而 M5.1 仍需等」），但不会出现「M5.0 No-Go 而 M5.1 可开工」
（判定以 M5.0-WP2 验收为准，另见 B.3「期内子门禁是开工闸」）。

**M5.0-WP1 领域对象、状态机与不变式定稿**（1–1.5 pd）
- 目标：把提案 §3.2 生命周期、§4.1 十对象、§3.3 提醒纪律收敛为实现契约。
- 范围：三部分。
  ① 十对象字段表（含 owner/来源/权限/完成条件/跟进策略）。
  ② 9 态生命周期转移表（dormant/needs_clarification/waiting_condition/ready/active/at_risk/
  overdue/completed/cancelled），每态列触发条件与拒绝条件；`needs_clarification` 必含
  「缺失字段 + 最晚澄清时间」。
  ③ 四条不变式——同意图最多一个未决通知 / 同因同计划版本不重推 /
  `sent|seen|actioned|snoozed` 不等于 completed / 暂停跟进不删配置 [来源: 提案 §3.2–§3.3]。
- 交付物：`docs/design/proposals/commitments-calendar-semantics.md`（新文档）。
- 依赖：无（提案 §1–§8 为输入）。
- 验收：评审通过；9 态×触发条件矩阵无空格，每格可指认拒绝条件；四条不变式各配一条可反驳的判定式。
- 风险：对象数偏多易滑向完整日历建模——写作时以「提案 §8 非目标」为删减尺。[推演]

**M5.0-WP2 时间语义、表结构与迁移契约定稿**（1–1.5 pd）
- 目标：把提案 §4.2 时间/重复语义与 §5.3 职责分离落成 DDL 草案与迁移方案。
- 范围：六项。
  ① 四类时间表示（UTC instant / 原墙钟+IANA / 全天 `DATE` / floating）的比较与排序规则。
  ② `RRULE/RDATE/EXDATE` 原文保留口径与 Occurrence 生成边界。
  ③ DST 缺口与重复时刻的期望结果表。
  ④ 首版表结构草案与索引。
  ⑤ 迁移序号方案（`PRAGMA user_version` + 有序迁移）。
  ⑥ [spec/14-roadmap.md](../../spec/14-roadmap.md)（§14）追加 M5–M7 行——与 M4.0-WP2 #40 同行编辑，
  **串行：#40 先落**，避免同文件冲突 [来源: design.md §14 现仅 M0–M3]。
- 交付物：语义文档 §时间/§DDL 草案 + `spec/14-roadmap.md`（§14）修订 + **纯函数时间语义模块 `src/platform/time_semantics.cr`（比较/排序/缺口与重复解析，无 IO）+ `spec/platform/time_semantics_spec.cr`**（最小实现，估时内已含单测）。
- 依赖：M5.0-WP1。
- 验收：**判据分两层，不要合并成一句话**——本包交付模块与 spec，两者都在 M5.0 期门禁范围内，因此不存在「文档通过但模块可不过」的形态：
  - ⓐ**M5.0 期门禁 = 文档评审通过（M5.0-WP1 语义文档 + 本包 §时间/§DDL 草案 + §14 修订）** 且 **调度四条（`make format-check` + `make spec` + `make lint` + `make release`）在 `src/platform/time_semantics.cr` 上全绿**。四条任一红（含 `make lint` 红）→ M5.0 No-Go，本包不完工。
  - ⓑ**M5.1 开工闸 = `spec/platform/time_semantics_spec.cr` 全绿，且本包「完工」**。**本包「完工」的定义 = ⓐ 全部条件通过**（文档评审 + 调度四条，不裁剪任何一条）。这两条缺一不可：spec 绿只证明时间语义可依赖，M5.1-WP1 要改 `SCHEMA.each` 迁移器（依赖本包交付的表结构与迁移序号方案），所以本包未完工时 M5.1 一律不得开工，哪怕 spec 已经绿。
  - 因此「spec 绿但 `make lint` 红」的形态下：**M5.0 No-Go，M5.1 也不得开工**——
    lint 红则 ⓐ 不成立，按定义本包不完工，ⓑ 的第二个条件不成立。
    同理「文档评审未通过但四条全绿」也是 M5.0 No-Go ⇒ 本包不完工 ⇒ M5.1 不得开工。
    两条闸的判定材料不同（M5.0 是文档评审 + 四条命令；M5.1 是 spec + 本包完工），
    所以可以出现「M5.0 已过而 M5.1 仍需等」，但**不会出现「M5.0 No-Go 而 M5.1 可开工」**——
    后者要求「本包完工」与「ⓐ 不成立」同时为真，与本包完工的定义直接矛盾。
    **注意方向是单向的**：WP2 未完工 ⇒ M5.1 不得开工，但 M5.1 等待**不**推出「M5.0 当时 No-Go」——
    若 M5.0 已过、之后 spec 因后续改动变红，M5.1 同样要等，此时 WP2 仍是已完工状态。
  - 三类边界用例各给确定期望值，不接受文档描述式验收：
    ① 春季缺口（`America/New_York` 2026-03-08 02:30 不存在）→ 拒绝该本地时刻并返回
    「需用户选择」错误码。
    ② 秋季重复（同日 2026-11-01 01:30 出现两次：先 EDT `−04:00`、后 EST `−05:00`）→
    取**第一次，即 UTC 偏移较大者 `−04:00`**（对应较早的 UTC 时刻），并在对象上标注
    `ambiguous_local_time`。判定式写成「比较两候选的 UTC 时刻，取较早者」，
    不得写成「偏移较小者」——`−05:00` 数值更小但对应第二次。
    ③ 全天跨时区（`Asia/Shanghai` 建全天 `DATE`，以 `America/Los_Angeles` 读取）→
    仍为同一 `DATE`，不发生日期漂移。
    另：表草案覆盖 M5.1 全部仓储字段，无悬空外键。
- 说明：模块与 spec 由本包交付（不另设包、不外推到 M5.1）。**口径统一以本包验收为准**，B.3「M5–M7 期门禁口径」与 M5 期门禁头的表述与之冲突时按本条读。[推演]
- 风险：时区规则依赖 tzdata 更新——首版以「显式拒绝无法表示的本地时刻并要求用户选择」替代自动猜测。[推演]

**M5.1-WP1 store schema 版本化与增量迁移**（1–2 pd）
- 目标：为后续新表提供可演进底座（现状只有幂等全量建表，无版本概念）。
- 范围：`SCHEMA.each { |ddl| @db.exec(ddl) }` 幂等建表改为「v1 基线快照 + 有序迁移列表」，启动时读 `user_version` 逐条前推；迁移单事务、失败回滚、新库直达最新；**存量库零手工动作**；迁移与 `make release` 兼容 [来源: 仓库:src/platform/store/store.cr:168 现仅幂等执行；同文件 :34-146 全部 DDL]。
- 交付物：迁移器 + 迁移 spec（两次连续 migrate 幂等、半途失败不留脏态）。
- 依赖：M5.0-WP2。
- 验收：以既有 v1 库样本升级到最新可重跑幂等；注入失败点在任一迁移一半时回滚且 `user_version` 不前进。
- 风险：Crystal sqlite3 绑定单语句限制（同文件 :30 注释「一次只接受一条语句」）——迁移器按语句数组执行，不复用多语句字符串。[推演]

**M5.1-WP2 commitments/checkpoints/reminders/deliveries 表与仓储**（2–3 pd）
- 目标：领域对象落库与查询面。
- 范围：四表 + 索引（按 owner/状态/下一评估时刻）；「同意图最多一个未决通知」由**部分唯一索引**强制而非应用层检查；`needs_clarification` 行必须有缺失字段非空；仓储 API（create/get/update/状态迁移/按时间窗查询/按 owner 列举）[来源: 提案 §4.1 对象责任表]。
- 交付物：DDL 迁移 + 仓储 + 约束 spec。
- 依赖：M5.1-WP1。
- 验收：并发插入第二条未决通知被 DB 拒绝；状态迁移越权（如 completed→active）被拒；`needs_clarification` 缺字段写不进去。
- 风险：状态机散在仓储与评估器两处——状态迁移只允许经单一 `transition!` 入口。[推演]

**M5.1-WP3 WakeSchedule/Occurrence 持久调度与 Occurrence 身份**（3–5 pd）
- 目标：唤醒不再依赖进程内内存表（现状重启即丢、扫描循环单线程）。
- 范围：五项。
  ① WakeSchedule 四类来源（一次性/周期 cron/interval/事件与轮询兜底）。
  ② Occurrence 稳定身份（`schedule_id + slot` 或 recurrence key）与生成窗口。
  ③ 原子 claim（条件 UPDATE 或 lease）、去重、跳过、合并、补跑、overlap 策略。
  ④ 复用 `Cron.next_after` 做时间计算 [来源: 仓库:src/orchestration/triggers/cron.cr:54]。
  ⑤ 替换 `@cron_jobs = Hash(...)` 与 `cron_loop` 扫描
  [来源: 仓库:src/orchestration/triggers/triggers.cr:20,41-45,88-118]；
  调度口径沿用会话输入调度的持久化先例。
- 交付物：持久调度器 + Occurrence spec。
- 依赖：M5.1-WP1、M5.1-WP2。
- 验收：两 fiber/两进程并发 claim 同一 Occurrence 仅一胜；停机 3 天后重启，pending 不丢且按配置策略（skip/coalesce/catch-up）补跑可指认；clock 注入下不漏不重。
- 风险：补跑与合并语义易与「提醒纪律」打架——本包只实现机制，语义选择由 M5.2-WP1 评估器定。[推演]

**M5.1-WP4 Run 持久恢复与副作用幂等**（2–3 pd）
- 目标：Occurrence → Run 的恢复语义与既有执行基座对齐，不另起炉灶。
- 范围：复用 `engine.start` 的 intent 幂等与 `tasks/leases` 恢复 [来源: 仓库:src/orchestration/engine.cr:26-39,59-77；src/platform/store/store.cr:179-190,223-258,327-342]；Run 结果三态（成功/失败/`outcome_unknown`）；`outcome_unknown` 不自动重放有副作用动作；ledger 记录每次评估与动作 [来源: 仓库:src/platform/store/store.cr:205-222]。
- 交付物：Run 恢复层 + 幂等 spec。
- 依赖：M5.1-WP3。
- 验收：执行中途强杀后重启，同一 Run 不重复投递副作用；`outcome_unknown` 走人工/下一检查点复核路径而非盲目重试。
- 风险：与 M5.3-WP3（cron 归位）共享 `event_id` 口径——先定身份格式再改触发器，避免双写。[推演]

**M5.2-WP1 Checkpoint 评估器与静默策略**（2–3 pd）
- 目标：到点不等于打扰：评估产出五选一（保持休眠/更新计划/提醒/请求审批/行动）与完成收口。
- 范围：评估输入（条件、上下文版本、上次结果、计划版本）；无新信息静默；同因同版本不重推；升级四条件（新事实/不可逆期限临近/计划失效/需用户决定）；完成或外部失效时关闭未来 Checkpoint 与未投递 Reminder [来源: 提案 §3.3、§3.4、§5.3]。
- 交付物：评估器 + 静默/升级 spec。
- 依赖：M5.1 门禁。
- 验收：无变化连续三轮零投递；有变化按升级规则各投一次；完成后再到点无提醒（迟到提醒为零）。
- 风险：评估器需要「上下文差异」定义，首版以显式字段快照比对为界，不做语义 diff。[推演]

**M5.2-WP2 统一 admission 接线（提醒与工作输入不绕过）**（1–2 pd）
- 目标：提醒投递与工作输入走同一 admission，不让第二条旁路出现。
- 范围：会话输入调度仓储已具 DDL 与 `admit_session_input`（含批次与字节预算）[来源: 仓库:src/platform/store/store.cr:98-134,453-580]；但当前**零调用者**（gateway 未接线，调度轨 #4/#5 未完成）——本包只做 Source 类型扩展（`reminder`/`work`）与接线口径，主循环接线归 #4/#5；优先级与去重不复制实现。
- 交付物：Source 扩展 + 接线点 spec（旁路调用必须失败）。
- 依赖：M5.1 门禁；E.1#8（调度轨 #4/#5 完成或 admission 接口冻结）。
- 验收：提醒注入与用户消息共用同一批次与字节预算；绕过 admission 的直写路径被拒并有审计。
- 风险：调度轨未按期则本包只能交付「接口就绪 + 冻结断言」——按 E.1#8 的冻结口径验收，不伪造联动。[推演]

**M5.2-WP3 NotificationDelivery 状态机与渠道投递**（2–3 pd）
- 目标：投递可追踪、可失败、可过期，且不污染 Commitment 状态。
- 范围：Delivery 七态（scheduled/sent/seen/actioned/superseded/expired/unknown）与合法迁移；重试与提醒预算（次数/升级档）；接线 `ChannelAdapter#send(peer, content, idempotency_key)` 并落 `message_id` [来源: 仓库:src/channels/base.cr:55]；渠道失败（无 adapter/发送错误）标 `unknown` 或 `expired`，不标 completed [来源: 提案 §3.3、§6.4]。
- 交付物：Delivery 状态机 + 投递 spec（假 adapter 注入）。
- 依赖：M5.2-WP1。
- 验收：`sent` 后 Commitment 仍 active；重复发送被 Delivery 约束挡住；渠道报错不产生「已完成」。
- 风险：`seen` 需渠道已读回执，首版仅 email IMAP `\Seen` 与 TUI/HTTP 显式查看两条来源，其余标 `unknown` 而非猜测。[推演]

**M5.2-WP4 Today 视图与 Projection/WorkSession 最小闭环**（1–2 pd）
- 目标：Today 是有限承诺场，不是逾期堆积场（提案 §3.4）。
- 范围：四项。
  ① 六段视图最小实现（当前事项 / 下一固定承诺 / 今日任务 / Projection / 容量缺口与风险项 / Inbox）。
  ② Projection 不落外部日历；计划与实际耗时分列。
  ③ 日终四操作（完成 / 改期 / 缩范围 / 退回 Inbox）**留延期历史**。「延期历史」在本包定义为
  一个可查询的迁移序列：每次日终操作写一条 `commitment_transitions` 记录
  （前后状态、操作类型、旧/新计划时间、原因、操作时刻），由本包提供 `history(commitment_id)`
  读取接口，供 M5.3-WP2 的 `today.view` 只读展示。
  ④ 不另设包、不落外部日历 [来源: 提案 §3.4]。
- **归属裁断（防两处实现）**：本包独占 Today 的**唯一归属权**——六段的取数口径、排序、容量缺口计算、四操作的语义与状态迁移全在本包；M5.3-WP2（管理面）只做命令与渲染接线，**不得再实现一套取数或排序**；M5.3-WP1（捕获）产出的 Commitment 以 Inbox 段进入，不改本包口径。
- 交付物：Today 视图 + 容量缺口 spec。
- 依赖：M5.2-WP1。
- 验收：容量不足时显示缺口与选项，不静默超载、不擅自延后硬期限；Projection 与 WorkSession 可分别查询；日终四操作各产生一次可指认的状态迁移并留延期历史，四操作之外无第二条改期路径。
- 风险：视图需要命令入口才能被人看到——渲染与命令接线归 M5.3-WP2（#74）的 `today.view`/`today.dayend`，本包交付纯函数投影计算与四操作语义，**不交付 UI**。[推演]

**M5.3-WP1 一句话捕获与 needs_clarification**（1–2 pd）
- 目标：用户一句话即可创建远期意图（Outcome/Source/跟进依据三件套）。
- 范围：四条示例话术路径（远期日期提醒/会前准备/等回复转跟进/周期检查至成功）[来源: 提案 §3.1]；歧义仅在影响执行、缺可观察条件或无法定时区时澄清；`needs_clarification` 带缺失字段与最晚澄清时间；后续补全走 update 不新建。
- 交付物：捕获解析 + 四条话术 spec。
- 依赖：M5.2 门禁（评估器与 Delivery 需先存在）。
- 验收：四条话术各产出合法 Commitment 且状态正确；缺字段进澄清态不静默丢。
- 风险：「等对方回复后提醒我」依赖外部通道信号——首版以「无回复即到下一检查点」的轮询兜底表达，不做真事件订阅。[推演]

**M5.3-WP2 IPC/HTTP 管理面扩展**（1–2 pd）
- 目标：承诺与提醒可查可控。
- 范围：`commitments.list/get/create/update/pause/snooze/complete/cancel`、`checkpoints.list`、`deliveries.list`、`today.view`（取 M5.2-WP4 纯函数结果并渲染）、`today.dayend`（日终四操作入口）；沿用既有命令分发与鉴权口径 [来源: 仓库:src/admin/ipc/server.cr:189-210 现仅 ping/system.health/sessions.*/runs.*/config.*]；TUI 与 HTTP 双入口同语义。
- **Today 渲染与日终操作的归属**：视图的取数口径、排序、容量缺口计算与四操作的**语义/状态迁移**归 M5.2-WP4（#72，唯一归属）；本包只负责**命令暴露与渲染接线**（`today.view`/`today.dayend`）与鉴权，不另实现取数或排序，也不自带状态迁移逻辑。延期历史由 M5.2-WP4 的迁移记录提供，本包只读取展示。
- 交付物：管理面命令 + 鉴权 spec。
- 依赖：M5.3-WP1。
- 验收：未授权 401；越权状态迁移被拒；snooze 必须形成新时间或条件（不接受「隐藏」）。
- 风险：命令面扩张快于语义稳定——首版命令集按本包清单闭集，新增走后续包。[推演]

**M5.3-WP3 cron 归位为唤醒基础设施层**（2–3 pd）
- 目标：保留 cronjob 能力，但不再让 cron 定义等同业务意图（提案 §5）。
- 范围：workflow `cron` trigger → WakeSchedule 映射（`event_id` 口径与现在 `cron:<workflow>:<next_at_ms>` 等价，保证 M2 幂等语义不退化）[来源: 仓库:src/orchestration/triggers/triggers.cr:103]；`cron_loop` 由内存扫描改为持久调度驱动；不新增平行 cron 管理入口；纯例行脚本仍可不建 Commitment。
- 交付物：映射层 + 回归 spec。
- 依赖：M5.1-WP3、M5.1-WP4。
- 验收：既有 M2 cron 用例全绿（触发次数一致、不漏不重）；重启后 cron 不丢；同一 workflow 不出现双调度。
- 风险：改动在产链路，回归面覆盖 gateway 启动顺序——先加开关灰度（旧扫描/新调度二选一）再切默认。[推演]

**M5.3-WP4 文档、CHANGELOG 与端到端**（1 pd）
- 目标：行为与文档一致（B.3 第 4 条）。
- 范围：`spec/06-session-memory.md`（§6，会话/时间上下文）与 `spec/14-roadmap.md`（§14）回写；CHANGELOG `Unreleased` → `0.3.0`；README 使用说明；e2e 一条主线（创建→唤醒→静默→提醒→完成→关闭未来唤醒）。
- 交付物：文档修订 + e2e spec。
- 依赖：M5.3-WP1~WP3。
- 验收：e2e 全绿；文档与实现零口径差（逐条回对提案 §9 首闭环 1/2/4/5 条）。
- 风险：无实质风险。

**M5.4-WP1 M5 门禁与 v0.3.0 发布**（1–2 pd）
- 目标：期收口与版本落定。
- 范围：M-gate 五项（B.3）+ 调度四条；`docs/design/review/m5-gate.md` 记录证据与边界；tag `v0.3.0` 触发既有 release workflow。
- 交付物：m5-gate.md + tag。
- 依赖：M5.3 门禁。
- 验收：提案 §9 首闭环第 1/2/4/5 条逐条有可复现证据；Go/No-Go 明确。
- **冻结口径裁断（CodeRabbit 问：仅冻结态交付是否挡 v0.3.0）**：**不挡**。
  若 M5.2-WP2 因 E.1#8 未满足只交付「Source 扩展 + 接口冻结断言」形态（无真实联动），
  v0.3.0 仍可发，但须同时满足三条件，缺一即 No-Go 改判：

  1. `m5-gate.md` 单列「未并入 admission」项并写明影响面（提醒独立通道，
     不与用户消息共用批次与字节预算）。
  2. 产品面（Today 与提醒）显式标注该限制，不呈现「已与用户消息统一调度」。
  3. 该限制条目同步记入 design.md §15.1。

  **不接受的形态**：把冻结断言当联动证据、或把「提醒走独立通道」写成已达成的设计目标。
- 风险：M5.2-WP2 若受调度轨阻塞，门禁须显式列「未验证项」而非默认通过。[推演]
