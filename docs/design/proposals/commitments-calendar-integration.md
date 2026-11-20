# 远期计划、提醒与外部 Calendar 整合（Proposal）

> 状态：**Proposal**（2026-11-20 调研与讨论成稿，待评审与实施拆分）。
> 关联：[整体设计](../design.md)、[会话输入调度](session-input-scheduling.md)。
> 本文职责：定义 Sebas 的持久意图、时间上下文、提醒与执行语义，以及外部 TODO/Calendar 的接入边界。实现工作包与排期不在本文。
> 证据范围：竞品与协议结论来自 2026-11-20 官方文档/标准研究，未登录真实账户做交互或 round-trip 实测；产品方案均为建议，不代表现有实现。

## 1. 问题与核心判断

周期 cron 能解决「按固定节奏启动工作」，但不能完整表达：

- 一个远期目标在数月后才需要关注；
- 等待外部回复、文件、预订或其他条件；
- 截止期之前需要分阶段准备；
- 外部日历变化后重新评估既有安排；
- 提醒之后仍需确认处理与实际结果；
- 用户已有 Google、Microsoft、Apple、Todoist 等工具，不能被迫迁移。

**核心判断：Sebas 的 Calendar 是「持久意图与时间上下文层」，不是另一个需要用户维护的日历，也不是 cron job 表。**

产品目标不是把日历塞满，而是维持一个**现实、可调整、可信任的计划**：

> 保存意图 → 在合适的时间或条件下醒来 → 获取最新上下文 → 决定静默、提醒或行动 → 跟进到结果明确。

## 2. 设计原则

1. **意图先于排程**：远期事项可以只有目标和来源，不要求先成为完整任务或日历事件。
2. **先评估，再打扰**：Checkpoint 到点不意味着必须发通知；无新信息时继续休眠。
3. **唤醒不等于执行，通知不等于完成**：调度、提醒投递、实际工作、结果确认分别记录。
4. **期限、计划时间、提醒和实际耗时分离**：不能用一个 `due_at` 承担所有时间语义。
5. **原系统保留所有权**：外部 Event/Task 默认只读；Sebas 不通过全量双向同步接管用户数据。
6. **自动化可解释、可预览、可撤销**：涉及他人、共享日历或不可逆动作时默认需要确认。
7. **承认无解**：容量不足或条件冲突时显示缺口和选项，不静默超载或擅自延后硬期限。

## 3. 产品体验

### 3.1 最小捕获

用户可以用一句话表达远期意图，例如：

- 「明年三月提醒我准备搬家。」
- 「会议前两周帮我检查材料。」
- 「等对方回复后提醒我；三天没回复再跟进。」
- 「每周五检查订阅是否取消，成功就停止。」

首次只要求：

- **Outcome**：期望结果，而不只是提示词；
- **Source**：用户原话、来源消息或外部对象链接；
- **跟进依据**：时间、条件，或明确的暂候状态。

完整步骤、优先级、预计工时、提前量、提醒渠道和次数均可后补。仅当歧义会影响执行、缺少可观察条件或无法确定时区时才澄清；`needs_clarification` 必须包含缺失字段与最晚澄清时间，不能等同于遗忘。

### 3.2 生命周期

```text
dormant                 休眠，尚未到关注时间
needs_clarification     已保存，但缺少必要信息
waiting_condition       等待回复、事件或其他条件
ready                   已经可以行动
active                  正在执行
at_risk                 按当前条件或容量可能无法按时完成
overdue                 已错过期限
completed / cancelled   已完成或取消
```

| 场景 | 体验 |
|---|---|
| 暂候 | 明示「已保存，暂不跟进」或下次评估时间，不占当前执行列表 |
| 条件未满足 | 显示等待条件、最后核实时间和下次检查时间；无变化时静默 |
| 条件满足 | 先确认计划仍有效，再提醒；说明条件、来源和核实时间 |
| 提醒被忽略 | 保留未决项，不反复原样推送；下一有效检查点重新判断 |
| 错过提醒/期限 | 说明错过了什么、能否补救，提供处理、改期、降低承诺或取消 |
| 条件失效 | 撤销尚未投递的过时提醒，不沿用旧上下文执行 |
| 结果未知 | 标记 `outcome_unknown`，不盲目重复有副作用的动作 |
| 结果确认 | 关闭关联的未来检查点和提醒，保留历史与复盘 |

### 3.3 提醒纪律

- 同一意图最多一个未决通知；新信息更新原通知，不重复堆叠。
- 同原因、同计划版本、同请求决定不重复推送。
- 普通进度和无变化进入摘要；只有新事实、不可逆期限临近或计划失效才升级。
- Snooze 必须形成新的时间或条件，不是暂时隐藏。
- 暂停跟进不删除配置；完成、取消和外部失效应使未来唤醒失去效力。
- `sent`、`seen`、`actioned`、`snoozed` 都是 Delivery 状态，不能自动关闭 Commitment。

### 3.4 Today 与计划—执行—复盘

Today 是用户选择的**有限承诺**，不是所有逾期和到期事项的堆积场。

建议视图：

1. 当前事项、计时和继续/暂停；
2. 下一固定承诺；
3. 主动选择的今日任务；
4. 按顺序、剩余时长、会议和工作时间计算的临时 Projection；
5. 容量不足、截止风险和待重新决策项；
6. Inbox，暂存而不抢占注意力。

Projection 不落外部日历；用户 Pin 或批准后才形成 WorkSession。计划与实际耗时分开保存，日终提供完成、改期、缩小范围、退回 Inbox、放弃等操作，并保留延期历史。

## 4. 内部对象模型

### 4.1 领域对象

| 对象 | 责任 |
|---|---|
| **Commitment** | 持久意图：期望结果、原话/来源、owner、期限、准备窗口、状态、完成条件、跟进与提醒策略 |
| **Checkpoint** | 某次时间或条件评估：评估理由、条件、上下文版本、结果及后续动作 |
| **Reminder** | 面向用户的提醒意图：为什么提醒、需要什么决定、升级预算 |
| **NotificationDelivery** | 一次具体渠道投递：scheduled/sent/seen/actioned/superseded/expired/unknown |
| **Task / WorkItem** | 可执行工作：优先级、计划日、硬截止、预计/剩余时长、来源、状态 |
| **Event** | 外部或内部时间承诺：系列、固定/弹性、读写权限、busy/free |
| **WorkSession** | 某次计划执行时间；一个任务可有多个；支持固定、锁定、跳过、外部映射 |
| **Projection** | 临时预计时间，不是承诺，不生成外部事件 |
| **ActualTime / Run** | 实际执行、结果、成本和证据 |
| **ExternalLink** | 内部对象与外部资源的关联、来源、权限和同步状态 |

`Reminder` 与 `WorkSession` 都可属于同一 Commitment，但互不替代；外部任务完成或会议取消也不能自动证明整个 Commitment 已完成。

### 4.2 时间与重复

- 区分 UTC instant、原墙钟时间＋IANA 时区、全天 `DATE`、floating time。
- 重复系列保留 `RRULE/RDATE/EXDATE` 或平台结构化规则的原文；例外单独表达。
- 截止日、计划执行时段、提醒时间分别存储。
- 不把无限重复展开为无限行；Occurrence 按窗口或唤醒需求生成。
- 时区数据库更新、DST 缺口和重复时刻必须有明确计算与测试策略。

## 5. cronjob 的定位与统一调度

**保留 cronjob 机制，但退到唤醒基础设施层；用户产品层围绕计划、跟进和提醒，而不是 cronjob。**

> cron 决定何时醒；Commitment 决定为什么醒、醒来后做什么，以及下次何时再醒。

### 5.1 适合直接使用 cron 的工作

- 固定周期巡检、晨报、账单汇总；
- 定期同步和对账；
- 明确无结束目标的例行自动化；
- 无外部事件通道时的低频轮询兜底。

无需为纯确定性例行脚本强加 Commitment 和 Agent turn。

### 5.2 需要持久意图的工作

- 到某日期开始准备或提醒；
- 等待回复、文件、状态或外部事件；
- 多次检查直至满足完成条件；
- 外部日历变化后需要重新安排；
- 提醒之后仍需跟进实际结果。

### 5.3 统一链路

```text
Commitment：为什么持续关注（纯例行任务可省略）
    ↓
Checkpoint：什么时候需要重新评估
    ↓
WakeSchedule：如何保证醒来
    ├─ 指定时间 / 相对延迟
    ├─ 周期 cron / interval
    ├─ 外部事件 / 用户回复
    └─ 低频轮询兜底
    ↓
Occurrence：本次应发生的唤醒（稳定身份）
    ↓
Run：本次检查或执行（持久恢复）
    ↓
保持休眠 / 更新计划 / 提醒 / 请求审批 / 行动 / 完成
    ↓
必要时生成下一个 Checkpoint
```

职责分离：

| 对象 | 责任 |
|---|---|
| `WakeSchedule` | 一次性、周期或事件的唤醒定义，不承载长期目标 |
| `Occurrence` | 一次应发生的唤醒，支持原子 claim、去重、跳过、合并和补跑 |
| `Run` | 实际检查或执行；效应幂等和结果恢复 |
| `Checkpoint` | 本次评估的领域语义与结果 |
| `Reminder / Delivery` | 用户通知意图与实际投递，不混入 Run 成功状态 |

例如「每周五检查续费，直到取消成功」：WakeSchedule 持有周期规则，Commitment 持有目标与完成条件，每次 Occurrence 对应一个周五；确认取消后关闭未来检查点和提醒。

### 5.4 与现有实现的边界

- `src/orchestration/triggers/cron.cr` 可保留并扩展为时间计算组件。
- `src/orchestration/triggers/triggers.cr` 当前以内存 Hash 和扫描循环启动 workflow；后续应演进为持久唤醒调度，不再让 cron 定义直接等同业务意图。
- `src/platform/store/store.cr` 的 `TaskRow` 是运行任务，不兼任 Commitment。
- 已有 `intents/tasks/leases/ledger` 可复用为执行与恢复基础；会话调度仍遵循 [session-input-scheduling.md](session-input-scheduling.md)，通知与工作输入不得绕过统一 admission。
- 现有 workflow DSL 的 cron trigger 可映射为 WakeSchedule；新增用户侧远期意图不等于增加一个平行 cron 管理入口。

## 6. 外部 TODO / Calendar 集成

### 6.1 三种接入深度

1. **只读镜像与观察（默认）**：读取用户明确选择的集合，展示事件/任务，提供忙闲与期限依据，观察变化，不修改原对象。
2. **显式关联，不复制**：Commitment 关联外部 Event/Task，用于推导准备窗口、重估和回访来源，不合并对象所有权。
3. **受控投影（明确授权）**：向独立 Sebas 日历/清单或用户指定目标写 WorkSession、截止标记或任务；支持整体启停、审计和清理。

不默认把外部对象复制成 Sebas 原生对象，也不默认把所有 Sebas 意图导出为日历事件。

### 6.2 所有权矩阵

| 数据 | 权威所有者 |
|---|---|
| 外部会议、参与者、邀请、RSVP | 原日历系统 |
| 外部 TODO 的清单、状态和截止日 | 原 TODO 系统 |
| Sebas 的意图、准备策略、跟进状态 | Sebas |
| Sebas 的提醒策略和通知历史 | Sebas |
| 用户批准的 WorkSession 投影 | Sebas 管映射，外部系统持有实际资源 |
| 外部对象原文、版本、游标 | 外部系统为权威，Sebas 保存镜像 |
| 实际执行与复盘 | Sebas |

### 6.3 外部变化处理

```text
变化通知或轮询提示
 → 增量同步与本地对账
 → 判断是否影响关联 Commitment
 → 重算条件、准备窗口、容量和 Checkpoint
 → 撤销失效的未投递提醒
 → 仅在有新增决策、风险或冲突时通知
 → 展示旧计划 → 新建议 → 原因，允许接受/修改/撤销
```

外部变化触发**评估**，不直接触发通知或重排。已接受、已发生或临近开始的安排默认锁定；涉及他人的会议、邀请、取消、改期和消息发送默认需要确认。短时间批量变化先合并评估。

### 6.4 隐私与失败

- 跨工作/私人账户默认只共享 busy 或通用标签，除非明确允许详情。
- 每个对象显示来源、写入方、读写权限、同步方向和最后对账结果。
- 外部连接器停用后，Sebas 的意图与历史仍保留；投影保留/清理由用户选择。
- 预览过期、外部已变化、部分写入失败时标 `stale/conflicted/partial_failure/unknown`，不显示全量成功。
- 撤销应覆盖整次计划批次；无权限或结果不确定时 fail-closed。

## 7. 协议与适配器边界

采用 **canonical superset + adapter**，不做最低公分母的双向同步。

### 7.1 iCalendar / CalDAV

- RFC 5545 提供 VEVENT、VTODO、VALARM、重复与例外，可作语义底座，但不能替代 Sebas 的意图与跟进模型。
- `UID + RECURRENCE-ID` 用于系列内实例定位；UID/iCalUID 不作跨平台主键。
- CalDAV 主重复组件及例外可位于同一资源；不能按展开实例分别覆盖 PUT。
- 按集合探测 VTODO、sync 和 alarm 能力；使用 ETag 条件写，服务端可能改写资源。
- 保存完整 ICS、未知 IANA/X- 属性、原始重复与 alarm；不能只存规范化字段。

### 7.2 Google Calendar

- 首次全量、后续 `syncToken` 增量；只在一轮分页完成后保存新 token；410 时对该范围全量重建。
- `watch` 只提示集合有变化，不带具体更新内容；channel 会过期。通知是 hint，不是完整变更日志。
- 重复实例保留 `id/recurringEventId/originalStartTime`；提醒、扩展属性和忙闲分别处理。
- 写回以最新资源为基础做字段级 diff；不把 `sequence` 或 `syncToken` 当写版本。

### 7.3 Microsoft Graph

- `calendarView/delta` 绑定具体日历与时间窗；完整一轮后保存 `deltaLink`。
- 通知可能只带资源 ID，漏通知或订阅失效后用 delta 对账。
- 使用 Immutable ID，并保留 account/mailbox 作用域；系列、实例和例外不能仅按 iCalUID 归并。
- To Do 与日历 Event 是独立资源；任务的时间块须另建 Event/WorkSession 显式关联。
- 保留结构化 recurrence、changeKey/etag、原始 reminder 与扩展，不宣称任意 RRULE 无损互通。

### 7.4 同步元数据

分别保存资源身份、版本与游标：

```text
provider/account/collection + resource id/href
UID/iCalUID + series id + original recurrence key
ETag/changeKey/sequence/updated
CalDAV sync-token / Google syncToken + query / Graph deltaLink + time window
watch/subscription id + expiration
```

扩展字段只放简短、命名空间化的 Sebas 关联键；原始载荷留在本地。JMAP Calendars 在正式标准化前不作为首期主同步协议。

## 8. 非目标

- 不做替代 Google/Outlook/Apple/Todoist 的全功能日历或项目管理器。
- 不默认全量双向同步，不承诺复杂重复、提醒和扩展字段跨平台无损互通。
- 不默认全量自动重排，不自动修改多人会议或共享承诺。
- 不以逾期红点、扣分或连续提醒代替实际处理。
- 不把调度唤醒、通知送达或用户点击当成任务完成。
- 不在本文内确定数据库 DDL、API 字段或实施排期；这些在评审后拆分。

## 9. 建议的首个闭环与验证

1. 一句话创建远期 Commitment，可查看、修改、暂停、Snooze、完成和取消。
2. 持久 Checkpoint 与 WakeSchedule；重启、休眠和漏跑后按明确策略恢复。
3. Google/Microsoft 选定集合只读镜像；通知/轮询只触发同步和重估。
4. 到点检查最新条件，无变化静默；需要用户决定时发送可追踪通知。
5. 完成或外部失效后关闭未来唤醒，不重复提醒。
6. 用户明确授权后，向独立 Sebas 日历写 WorkSession；展示同步与撤销结果。
7. 第一版不做全字段、全对象双向同步。

### 必须验证的边界

- 一次性、周期、事件和条件唤醒的统一 occurrence 身份与防重。
- 离线/休眠/重启后的 skip、coalesce、catch-up 和 overlap 策略。
- 外部改期、取消、完成、权限撤销、token 失效、游标失效和通知丢失。
- 重复系列的单次覆盖、全天事件、DST、跨时区和部分写入失败。
- 通知已发送但用户未处理、执行成功但投递未知、完成后的迟到提醒。
- 真实 Google/Microsoft/CalDAV 账户的 round-trip 与原文保留能力矩阵。

## 10. 主要依据

### 产品与体验

- [Todoist：任务日期与硬截止](https://www.todoist.com/help/todoist/features/introduction-to-deadlines-in-todoist-uMqbSLM6U)
- [Things：开始日期与 Deadline](https://culturedcode.com/things/support/articles/2803579/)
- [Microsoft To Do：My Day 与建议](https://support.microsoft.com/en-us/ToDo/my-day-and-suggestions)
- [Sunsama：任务 Projection 与 Pin](https://help.sunsama.com/docs/usage-guides/playlisting)
- [Morgen：Frames、预览与批准后计划](https://www.morgen.so/ai-planner)
- [Reclaim 2.0：时间块内推荐任务，而非每任务一事件](https://help.reclaim.ai/en/articles/16558552-tasks-overview-decide-what-to-work-on-when)
- [Structured：未完成事项 Replan](https://help.structured.app/en/articles/4526850)
- [Todoist：日历集成的有限双向边界](https://www.todoist.com/help/todoist/integrations/use-the-calendar-integration-rCqwLCt3G)

### 调度与持久执行

- [OpenClaw：运行、补跑与恢复](https://docs.openclaw.ai/automation/cron-jobs/how-it-works)
- [Hermes：Cron 内部机制](https://hermes-agent.nousresearch.com/docs/developer-guide/cron-internals)
- [Hermes：保留会话上下文的 Heartbeat](https://hermes-agent.nousresearch.com/docs/user-guide/features/heartbeat)
- [Pi Durable：持久任务、checkpoint 与等待](https://github.com/earendil-works/pi/blob/main/packages/durable/README.md)
- [Cloudflare Agents：Scheduler](https://developers.cloudflare.com/agents/runtime/capabilities/scheduler/)

### 标准与平台

- [RFC 5545：iCalendar](https://www.rfc-editor.org/rfc/rfc5545)
- [RFC 4791：CalDAV](https://www.rfc-editor.org/rfc/rfc4791.html)
- [RFC 6578：WebDAV Collection Synchronization](https://www.rfc-editor.org/rfc/rfc6578.html)
- [Google Calendar：增量同步](https://developers.google.com/workspace/calendar/api/guides/sync)
- [Google Calendar：Push 通知](https://developers.google.com/workspace/calendar/api/guides/push)
- [Google Calendar：重复事件](https://developers.google.com/workspace/calendar/api/guides/recurringevents)
- [Microsoft Graph：Event 增量同步](https://learn.microsoft.com/en-us/graph/delta-query-events)
- [Microsoft Graph：Change Notifications](https://learn.microsoft.com/en-us/graph/change-notifications-overview)
- [Microsoft Graph：To Do 资源](https://learn.microsoft.com/en-us/graph/api/resources/todo-overview?view=graph-rest-1.0)
