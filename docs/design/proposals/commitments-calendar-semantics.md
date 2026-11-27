# 承诺与提醒实现契约：领域对象、生命周期与不变式（M5.0-WP1）

> 状态：**实现契约草案**（M5.0-WP1 交付，2026-11-27；待评审）。
> 来源契约：[commitments-calendar-integration.md](commitments-calendar-integration.md) §1–§5、§9（下称「提案」）。
> 本文职责：把提案 §3.2 生命周期、§4.1 十对象、§3.3 提醒纪律收敛为**可实现、可测试**的字段表、转移矩阵与判定式。排期与实现工作包不在本文。
> 删减尺：以提案 §8 非目标为界——不做完整日历建模、不做全字段双向同步、不做标签/视图体系。

## 1. 范围

- 十对象字段表（§2），每表覆盖 owner / 来源 / 权限 / 完成条件 / 跟进策略维度。
- 9 态生命周期转移矩阵（§3）：dormant / needs_clarification / waiting_condition / ready /
  active / at_risk / overdue / completed / cancelled，每格给出触发条件与拒绝条件。
- `needs_clarification` 澄清契约（§3.4）。
- 四条不变式及可反驳判定式（§4）。
- 与提案 §9 首闭环的映射（§5）。

表结构 DDL、迁移脚本、调度实现属 M5.1（#65–#68）；本文只定字段语义与约束。

## 2. 领域对象字段表

通用约定：所有对象含 `id`（uuid）、`created_at`、`updated_at`；`owner` = 持有者身份
（首期为单用户，字段保留）；外部来源对象必有 `ExternalLink` 关联。

### 2.1 Commitment（持久意图）

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| outcome | text | ✓ | 期望结果（不是提示词）。**始终必填**：缺失即捕获失败，不入库（不进 needs_clarification——澄清态只针对跟进依据缺失） |
| source | text | ✓ | 用户原话 / 来源消息 / 外部对象链接 |
| owner | text | ✓ | 持有者 |
| state | enum(§3 九态) | ✓ | 生命周期状态 |
| due_at | timestamptz | — | 硬截止（UTC）。关注时间不得晚于 due_at（T01 拒绝口径） |
| prepare_window | interval | — | 截止前准备窗口 |
| due_wall / due_tz | date / text | — | 原墙钟截止 + IANA 时区（与 due_at 互斥使用场景见提案 §4.2） |
| completion_condition | text | — | 可观察完成条件。**未配置（空）时**：完成走 `user_confirmed`（用户显式确认）——用户确认同时构成完成判定与完成证据（§4.3），不要求其他条件 |
| followup_policy | json | — | 跟进策略：检查间隔、升级预算、静默窗口 |
| remind_policy | json | — | 提醒策略：提前量、渠道、纪律参数 |
| plan_version | integer | ✓ | 计划版本号（不变式 2 判定依据） |
| paused | boolean | ✓ | 暂停跟进标记（不变式 4：暂停不删配置） |
| missing_fields | json | — | needs_clarification 态必填：缺失字段名数组（§3.3） |
| clarify_by | timestamptz | — | needs_clarification 态必填：最晚澄清时间（到期未补走 T09） |

来源=source 字段；完成条件=completion_condition；权限：首期单用户 owner 自有，外部对象权限存 ExternalLink。

### 2.2 Checkpoint（一次时间或条件评估）

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| commitment_id | uuid | ✓ | 所属 Commitment |
| reason | enum | ✓ | time_due / condition_check / external_change / manual |
| condition | json | — | 评估条件表达式（waiting_condition 用） |
| context_version | integer | ✓ | 评估时的上下文版本 |
| result | enum | ✓ | silent / notified / action_required / condition_met / condition_failed |
| next_action | enum | — | reschedule / escalate / none |

验收维度（owner/来源/权限/完成条件/跟进策略）：Checkpoint 经 commitment_id **继承**所属
Commitment 的这些维度，不自带——评估以 Commitment 的跟进策略与完成条件为准。

### 2.3 Reminder（提醒意图）

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| commitment_id | uuid | ✓ | 所属 |
| why | text | ✓ | 为什么提醒、需要用户做什么决定 |
| escalate_budget | integer | ✓ | 升级预算（剩余升级次数） |
| due_at | timestamptz | — | 提醒时间（与 Checkpoint 分离存储） |

验收维度：经 commitment_id **继承**所属 Commitment 的 owner/来源/权限与跟进策略；
不自带完成条件——Delivery 状态变迁不构成完成（不变式 3）。 |

### 2.4 NotificationDelivery（一次渠道投递）

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| reminder_id | uuid | ✓ | 所属 Reminder |
| commitment_id | uuid | ✓ | 冗余关联（判定式用） |
| trigger_reason | text | ✓ | 本次投递的触发原因（不变式 2 判定依据） |
| plan_version | integer | ✓ | 投递时的计划版本（不变式 2 判定依据） |
| channel | text | ✓ | 渠道 |
| state | enum | ✓ | scheduled / sent / seen / actioned / superseded / expired / unknown |
| supersedes | uuid | — | 被本条实际替代的 Delivery id。**state=superseded 不强制填写**：无替代者的撤销（T09 澄清超时、条件失效放弃、用户取消无后续投递）直接置 superseded 而不填 supersedes；仅当新投递实际替代旧投递内容时才记录关联（不变式 2 据此区分「重复发送」与「未发送替代」） |
| sent_at | timestamptz | — | 实际发送时刻（投递历史事实；置 sent 时写入，后续 state 变迁不得清除） |

### 2.5 Task / WorkItem（可执行工作）

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| commitment_id | uuid | — | 可关联 Commitment（独立任务为空） |
| priority | enum | ✓ | high / normal / low |
| plan_date | date | — | 计划日 |
| due_at | timestamptz | — | 硬截止 |
| estimate / remaining | interval | — | 预计 / 剩余时长 |
| source | text | ✓ | 来源（capture / user / external） |
| state | enum | ✓ | todo / doing / done / dropped |

验收维度：Task 的完成仅依据其自身 state=done，**不包含**关联 Commitment 的整体
completion_condition——完成 Task 不会自动完成 Commitment（后者单独判定，
见不变式 3）；owner/source 自带，跟进策略继承关联的 Commitment（独立任务无跟进）。

### 2.6 Event（外部或内部时间承诺）

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| series_id | uuid | — | 重复系列标识 |
| fixed | boolean | ✓ | 固定（不可挪）或弹性 |
| access | enum | ✓ | read_only / read_write |
| busy | boolean | ✓ | busy / free |
| wall_start / tz | timestamp / text | ✓ | 原墙钟开始 + IANA 时区 |
| wall_end / duration | timestamp / interval | ✓ | 原墙钟结束或时长（二者择一存储，语义全文一致）——相同开始与时区的不同会议由此区分各自的结束与 busy 时段 |

验收维度：Event 自带来源（provider/external_id 经 ExternalLink 关联）与权限（access/busy）；
完成条件不适用——外部事件完成不等于关联 Commitment 完成（不变式 3）。

### 2.7 WorkSession（一次计划执行时间）

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| task_id | uuid | ✓ | 所属任务（可多条） |
| kind | enum | ✓ | fixed / locked / skipped / external_mapped |
| planned_start / planned_end | timestamptz | ✓ | 计划时段 |

验收维度：owner/来源继承所属 Task；完成条件不适用（WorkSession 是计划执行时段，
执行结果由 ActualTime/Run 记录）；跟进策略继承所属 Commitment。

### 2.8 Projection（临时预计，非承诺）

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| task_id | uuid | ✓ | 所属任务 |
| projected_start / projected_end | timestamptz | ✓ | 临时预计时段（不生成外部事件） |

验收维度：Projection 为临时预计，**不适用** owner/权限/完成条件/跟进策略——
不构成承诺，可随时重建或丢弃。

### 2.9 ActualTime / Run（实际执行与证据）

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| task_id | uuid | ✓ | 所属任务 |
| started_at / ended_at | timestamptz | — | 实际时段 |
| outcome | enum | ✓ | done / partial / unknown / failed |
| cost | json | — | 成本与证据（token、产物链接） |

验收维度：owner 与来源继承所属任务；完成条件不适用（Run 是执行记录）；跟进策略不适用。

### 2.10 ExternalLink（外部关联）

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| subject_type / subject_id | text / uuid | ✓ | 内部对象类型与 id |
| provider | enum | ✓ | google / microsoft / caldav / todoist |
| external_id | text | ✓ | 外部资源 id（原文保留） |
| access | enum | ✓ | read_only / read_write |
| sync_state | enum | ✓ | synced / stale / failed / revoked |

### 2.11 对象间不变约束

- Reminder 与 WorkSession 都可属同一 Commitment，互不替代；外部任务完成或会议取消**不能**自动置 Commitment completed（完成条件必须显式满足，见不变式 3）。
- ExternalLink 记录权限与同步状态；`sync_state=revoked` 时该链路上未投递 Delivery 置 superseded。

## 3. 生命周期

### 3.1 九态定义

| 态 | 含义 |
|---|---|
| dormant | 已保存，尚未到关注时间 |
| needs_clarification | 已保存但缺必要信息（必含缺失字段 + 最晚澄清时间） |
| waiting_condition | 等待回复、事件或其他可观察条件 |
| ready | 已可行动 |
| active | 正在执行 |
| at_risk | 按当前条件或容量可能无法按时完成 |
| overdue | 已错过期限 |
| completed | 完成条件已满足（有证据） |
| cancelled | 用户取消或澄清超时放弃 |

### 3.2 转移矩阵（每格：触发条件 → 拒绝条件）

| # | from → to | 触发条件 | 拒绝条件 |
|---|---|---|---|
| T01 | 创建 → dormant | 有未来关注时间且**无等待的可观察条件**（两者并存时优先 waiting_condition，关注时间保留为兜底唤醒）；**仅当存在硬截止时**才要求关注时间不晚于硬截止，无硬截止时该比较不适用 | outcome 或 source 为空；存在硬截止且关注时间晚于硬截止（关注时间作为兜底唤醒已落在截止之后，休眠到点即逾期（T28），拒绝并提示调整关注时间或截止） |
| T02 | 创建 → needs_clarification | 跟进依据缺失（关注时间/可观察条件无法给出）且可给出最晚澄清时间。outcome 始终必填：缺失即捕获失败不入库 | 跟进依据完整（应入 T01/T03/T04） |
| T03 | 创建 → waiting_condition | 等待外部条件且条件可观察。**优先于 T04/T01**：未来关注时间与可观察条件并存时一律入 waiting_condition（关注时间保留为兜底唤醒；条件确认后经 T10 转 ready） | outcome 或 source 为空；条件不可观察（须转 needs_clarification）；存在硬截止且关注时间晚于硬截止（**与 T01/T04/T07 同一规则**：兜底唤醒须落在硬截止之前，晚于截止即兜底失效，拒绝并提示调整——不因先入澄清态或直接创建而异；条件提前满足仍可经 T10 转 ready，故拒绝依据是兜底失效而非必然逾期） |
| T04 | 创建 → ready | 立即可行动、无未来关注时间且**无等待的可观察条件** | outcome 或 source 为空；存在未来关注时间（应走 T01）；存在等待的可观察条件（应走 T03，waiting_condition 优先）；存在硬截止且关注时间晚于硬截止（**同 T01/T03/T07 的兜底一致性校验**，拒绝并提示调整——立即可行动不豁免字段校验） |
| T05 | dormant → ready | 关注时间到达或暂候条件满足 | 源自 needs_clarification 且字段未补全（T08 暂缓路径）——补全前不得 ready，clarify_by 到期走取消。静默窗口属通知发送逻辑（提醒纪律），不阻止状态转移 |
| T06 | dormant → cancelled | 用户显式取消 | 已 completed——completed 不可撤销，重开需新开 Commitment 并以 ExternalLink 关联旧卡（不引用 T19） |
| T07 | needs_clarification 或 dormant（T08 暂缓路径）→ dormant/waiting_condition/ready | 用户补全全部缺失字段后，**按补全后的跟进依据重判目标态**：clarify_by 已过 → 拒绝 T07（走 T09 超时取消，补全不豁免期限）；可观察条件仍待满足 → waiting_condition（**优先于 dormant**，关注时间保留为兜底唤醒）；无条件且关注时间在未来 → dormant；仅当立即可行动 → ready。补全后的关注时间不得晚于硬截止（同 T01/T03：兜底唤醒须落在硬截止之前，提示调整） | 补全后仍缺必填项；关注时间晚于硬截止 |
| T08 | needs_clarification → dormant | 用户选择「暂缓，稍后再补」；clarify_by 期限内补全 → 走 T07 重判目标态（waiting_condition 优先于 dormant，按补全后的跟进依据判定）；**逾期仍未补全走 T09 取消（暂缓不豁免期限）** | 已过 clarify_by 且仍缺字段（走 T09） |
| T09 | needs_clarification/dormant（T08 暂缓路径）→ cancelled | clarify_by 到期仍未补全（系统自动，含经 T08 暂缓转入 dormant 的承诺）；补全前不得经任何路径进入 ready。到期判定以 clarify_by 时刻为准：到期后的补全不豁免取消（补全内容保留为记录） | 到期前已补全（应走 T07） |
| T10 | waiting_condition → ready | 条件满足且计划确认仍有效 | 条件观察记录缺失（不得凭空判定满足） |
| T11 | waiting_condition → dormant | 条件失效且未撤销原意图 | 条件仍在观察中 |
| T12 | waiting_condition → cancelled | 条件永久失效或用户取消 | 存在未撤销的 scheduled Delivery 且失效撤销对账失败（同失效撤销规则对账不上时不得直接取消） |
| T12b | waiting_condition → overdue | 截止已过且所等条件仍未满足。判定：有 due_at 时按 due_at（UTC）；仅有墙钟截止时按 due_wall + due_tz 换算的当地日期末尾（23:59:59 当地）与当地当前时刻比较，过当日即逾期 | 无 due_at 且无墙钟截止（无从判逾期；此时仅继续等待条件） |
| T28 | dormant → overdue | 经 T11 转入 dormant 后硬截止到达且用户未改期/未取消；到达前有效截止提醒照常投递（提醒用户期限已到） | 无硬截止；或用户已改期（新开 Commitment 并链接旧卡） |
| T13 | ready → active | 用户或 agent 开始执行 | 容量不足（保持 ready 并提示，见提案 §3.4） |
| T14 | ready → at_risk | 剩余时长 < estimate 且未开始，或容量判定不足 | 无硬截止且无容量约束（无从判 risk） |
| T15 | ready → overdue | 硬截止已过仍未开始 | 无硬截止的卡不得 overdue |
| T16 | ready → cancelled | 用户取消 | agent 正在执行该承诺的 turn 时，须先确认副作用结果并记 outcome_unknown（与 T20 同款，不存在绕过确认的无条件取消） |
| T17 | active → completed | completion_condition 满足且有证据（不变式 3） | 仅 Delivery 状态变化（sent/seen/actioned/snoozed 不构成完成） |
| T18 | active → at_risk | 进度落后于计划或容量恶化 | 无 plan/estimate 基线（无从判「落后」） |
| T19 | active → overdue | 硬截止已过仍在执行 | 无硬截止 |
| T20 | active → cancelled | 用户取消 | 副作用执行中（须先确认结果，outcome_unknown 记录） |
| T21 | at_risk → active | 缓解措施生效（剩余容量/进度回到阈值以上） | 缓解措施未生效（容量或进度仍在阈值以下） |
| T22 | at_risk → overdue | 风险成为现实（截止已过） | 无硬截止 |
| T27 | at_risk → completed | completion_condition 满足且有完成证据（同 T17 拒绝条件；T21 缓解回正轨行为保留） | 仅 Delivery 状态变化（同 T17） |
| T23 | at_risk → cancelled | 降低承诺或取消 | 副作用执行中（同 T20：先确认结果，outcome_unknown 记录） |
| T24 | overdue → completed | 补救完成（completion_condition 满足） | 同 T17 拒绝条件 |
| T25 | overdue → cancelled | 放弃；如改期则新开 Commitment 并链接旧卡 | 副作用执行中（同 T20：先确认结果，outcome_unknown 记录） |
| T26 | 任意活跃态 → 自身 | Checkpoint 无新信息（静默续眠） | 有未决通知时不得原样重推（不变式 1/2） |

伴随规则（CR：区分「失效撤销」「用户取消」与「无变化静默」）：

- **失效撤销类**（T09/T12——澄清超时、条件失效放弃）：该 Commitment 全部 `state=scheduled` 的未投递 Delivery 置 superseded；无替代者的撤销可空 supersedes（提案 §3.2「撤销尚未投递的过时提醒」仅适用于这些失效路径）。
- **例外——T11 条件失效转 dormant**：Delivery 侧仅撤销因该已失效条件而排程的投递（trigger_reason 关联失效条件），仍有效的未来截止提醒（due_at/due_wall 类）**保留**或改排替代投递——T11 语义是「暂不跟进」而非「意图失效」，漏掉截止提醒即违反提案 §3.2「错过期限」场景。调度侧同理：撤销因失效条件排程的 WakeSchedule，保留截止类唤醒（WakeSchedule 属 M5.1 持久调度交付，与 Delivery 分开处理）。
- **静默类**（T26 无变化续眠）：**不得**撤销仍有效的未来唤醒与 scheduled Delivery——无新信息时原计划继续有效。
- **完成类**（T17/T24/T27）：completed/cancelled 使未来唤醒失去效力（提案 §3.3），已 sent/seen 的历史 Delivery 保留原状态与 sent_at。

### 3.3 needs_clarification 澄清契约

进入 T02 时必须写入：

- `missing_fields`：缺失字段名数组（非空）；
- `clarify_by`：最晚澄清时间（timestamptz，必填）。

`clarify_by` 到期仍未补全 → T09 自动 cancelled，取消原因记 `clarify_timeout`。
不得以「静默遗忘」代替到期取消；也不得无期限地停在 needs_clarification。

## 4. 四条不变式与可反驳判定式

判定式以存储查询语义书写（`Delivery(d)` 表示按对象字段过滤），每条给出**可反驳**的反例形态。

### 4.1 同一意图最多一个未决通知

```
∀ Commitment C:
  count(Delivery d WHERE d.commitment_id = C.id
        AND d.state IN {scheduled, sent, seen}
        AND NOT EXISTS (d2 WHERE d2.supersedes = d.id)) ≤ 1
```

反驳反例：存在 C 使上述计数 ≥ 2（两条 sent 未被 supersede）即违反。

### 4.2 同因、同计划版本不重推

```
∀ (commitment_id, trigger_reason, plan_version) = key:
  count(Delivery d WHERE d 的 key 匹配 AND d.sent_at IS NOT NULL) ≤ 1
```

即：同一键**至多一条**投递曾实际发送（sent_at 非空 = 历史事实，state 后续
变迁不清除）。反驳反例：同键存在两条 sent_at 非空的 Delivery 即违反——
后条以 supersedes 关联前条也救不回来（发送已发生）。

配套规则：

- **键** = (commitment_id, trigger_reason, plan_version)。更新类后条沿用原键
  （仅内容/时间更新）；键变更（如换计划版本）产生的是新投递序列，不受本式约束；
- supersedes 关联**不影响**本式的同键计数——计数只看 sent_at；
- 未发送的前条（scheduled）被后条替代：前条置 superseded（无 sent_at），
  后条正常发送 → 同键 sent 计数 = 1，**不违反**（属「未发送替代」）；
- 同键两条都曾发送（sent_at 均非空）→ 直接违反**本判定式**
  （同键 sent_at 非空计数 = 2 > 1；supersedes 关联不能改变已发生两次发送的事实）。

### 4.3 Delivery 状态不等于完成

```
∀ Commitment C WHERE C.state = completed:
  ∃ completion_evidence e
    WHERE e.kind IN {user_confirmed, agent_confirmed, condition_met}
    AND e.commitment_id = C.id
```

- `condition_met`：completion_condition 已配置且满足；
- `user_confirmed`：未配置完成条件时，用户显式确认**同时**构成完成判定与完成证据（T17/T24/T27 均可依此触发）。

反驳反例：存在 completed 的 C，其全部关联事件仅为 Delivery 状态变迁
（sent/seen/actioned/snoozed）而无上述三类证据之一即违反。

### 4.4 暂停跟进不删配置

```
∀ Commitment C WHERE C.paused = true:
  ∀ policy p ∈ {followup_policy(C), remind_policy(C)} 暂停前已存在:
    p 暂停后仍存在（enabled 位可关，但行不得删除）
```

语义：保留**暂停前已存在**的策略配置；原本为空的策略允许继续为空——
不要求暂停时两项策略都必须存在。反驳反例：暂停前已存在的配置行在暂停后被删除即违反。

## 5. 与提案 §9 首闭环的映射

| §9 条目 | 依赖的对象与状态 |
|---|---|
| 1 创建/查看/暂停/Snooze/完成/取消 | Commitment 全字段 + T01–T25 + 不变式 4 |
| 2 持久 Checkpoint 与 WakeSchedule、重启恢复 | Checkpoint + dormant 静默（T26） |
| 3 只读镜像、通知/轮询只触发重估 | ExternalLink + Event + Checkpoint(reason=external_change) |
| 4 到点检查、无变化静默、可追踪通知 | Checkpoint.result + Reminder + Delivery + 不变式 1/2 |
| 5 完成或外部失效关闭未来唤醒 | T17/T12 + superseded 规则 + 不变式 3 |

## 6. 待评审裁决点

1. T09 的 clarify_by 到期取消是否允许用户一次性顺延（本文按「到期即取消，取消可逆需新开 Commitment」起草）。
2. at_risk 判定的容量数据源（Projection 汇总 vs WorkSession 实际）在 M5.2 落地前先以「剩余时长 < estimate」保守判定。
3. Delivery `unknown` 态是否计入不变式 1 的未决通知计数（本文按**不计**起草——unknown 表示投递结果未知，非未决意图；若评审认为应计入，判定式需同步收紧）。

## 7. 验收对照（issue #63）

| 验收项 | 本文位置 |
|---|---|
| 十对象字段表（含 owner/来源/权限/完成条件/跟进策略） | §2.1–§2.11 |
| 9 态×触发/拒绝矩阵无空格 | §3.2（T01–T28 覆盖九态全部进出） |
| needs_clarification 必含缺失字段 + 最晚澄清时间 | §3.3 |
| 四条不变式各配可反驳判定式 | §4.1–§4.4 |
