# 时间语义与存储迁移契约（M5.0-WP2 交付）

> 状态：**Proposal → 评审中**（2026-11-27 成稿，随 M5.0-WP2 #64 交付）。
> 关联：[承诺与提醒实现契约](commitments-calendar-semantics.md)（M5.0-WP1）、[整体提案](commitments-calendar-integration.md) §4.2/§5.3。
> 本文职责：把 §4.2 的时间/重复语义落成**可实现、可测试**的规则——四类时间表示的比较与排序、DST 缺口与重复时刻的确定期望、首版表结构草案与索引、`PRAGMA user_version` 有序迁移方案；并交付纯函数模块 `src/platform/time_semantics.cr` + `spec/platform/time_semantics_spec.cr`（M5.1 开工闸）。
> 实现排期不在本文：迁移器在 M5.1-WP1，四表仓储在 M5.1-WP2，持久调度在 M5.1-WP3。

## 1. 四类时间表示

| 表示 | 字段（列） | 语义 | 典型用途 |
|---|---|---|---|
| Instant | `*_at`（UTC timestamptz） | 绝对时刻，无本地解释 | `due_at`、`sent_at`、`clarify_by` |
| WallClock | `*_wall`（无偏移墙钟）+ `*_tz`（IANA 名） | 用户原话保留的当地时刻 | 墙钟截止 `due_wall/due_tz` |
| AllDay | `*_date`（`YYYY-MM-DD`） | 全天日，无时区绑定 | 全天事件、日级截止 |
| Floating | 墙钟值（无时区信息） | 未定时区的墙钟 | 用户未给时区的裸时间（首版仅捕获，不入排序） |

规则：

1. **Instant 是唯一权威交换形态**。任何跨时区比较、排序、唤醒计算，先把参与值归一到 UTC 时刻。
2. **WallClock 保留原话**：`due_wall` 存当地墙钟、`due_tz` 存 IANA 名（如 `America/New_York`），**不预解析成 due_at 存储**——tzdata 更新后原话仍可重解析。需要 instant 时按 §2 解析规则现场换算。
3. **AllDay 不绑时区**：`LocalDate` 是年月日三元组，相等与排序只看字段；跨时区读取不发生日期漂移（验收③）。需要与 instant 比较时，显式给归属时区取「当日开始锚」（00:00 严格解析）。
4. **Floating fail-closed**：无时区信息的墙钟值只允许字段字典序比较（自身之间），**不得猜测时区**换算成 instant；入库前必须补齐 `due_tz` 或由用户确认转 Instant，否则拒绝入排序队列。

## 2. DST 缺口与重复时刻（确定期望表）

解析入口：`TimeSemantics.resolve_wall(wall, tz)` → `Resolution(status: Unique | Ambiguous | Gap)`。
算法：以墙钟字段伪 UTC 值为基准，取 ±48h 两探测点的现行偏移各构造一个候选，用「回读墙钟字段与输入一致」过滤；0 个 → Gap，1 个 → Unique，2 个 → Ambiguous。

| 场景 | 输入（America/New_York） | 判定 | 确定期望 |
|---|---|---|---|
| ① 春季缺口 | 2026-03-08 02:30（不存在） | Gap | **拒绝该本地时刻**，返回错误码 `needs_user_choice`（`GapError`），提示用户选择；**禁止自动平移**（stdlib `Time.local` 的平移行为明确不采用，spec 有对照断言） |
| ② 秋季重复 | 2026-11-01 01:30（出现两次） | Ambiguous | 取**两候选中 UTC 时刻较早者**（判定式：比较两候选的 UTC 时刻取较早者；对同一墙钟值等价于 UTC 偏移较大者——EDT `−04:00` 早于 EST `−05:00`）。**不得写成「偏移较小者」**（`−05:00` 数值更小但对应第二次）。对象上标注 `ambiguous_local_time`；`secondary` 携带另一候选供用户切换 |
| 常规 | 2026-06-01 12:00 / 2026-11-01 02:30 | Unique | 唯一解，偏移分别为 `−04:00` / `−05:00` |
| 午夜缺口 | 归属时区 00:00 恰逢缺口（少数时区） | Gap | 同①：`day_anchor` 拒绝并要求用户选择，不平移 |

边界声明：±48h 探测窗口覆盖现行 IANA 时区的单次变迁；「96h 内两次变迁且偏移恰好回退」的历史角落（极少数 19–20 世纪条目）不在首版支持范围，解析按 Unique 返回的可能误判接受为已知边界（§5 待裁决）。

非法字段（月 0/13、平年 2/30、小时 24 等）：`ArgumentError`，fail-closed。

## 3. 比较与排序规则

1. **Instant vs Instant**：`Time` 直接按 UTC 时刻比较。
2. **WallClock vs Instant**：WallClock 先经 §2 解析（Gap 即拒绝，不入比较）取 UTC 时刻，再按 instant 比较。歧义值取 primary（较早者）参与排序，`ambiguous_local_time` 标记不改变排序位置。
3. **AllDay vs Instant**：区间比较 `instant_vs_all_day`——−1（时刻在当日开始锚前）/ 0（落在 `[当日锚, 次日锚)`）/ +1（次日锚及以后）。**统一排序队列不得用它**（区间比较不构成全序），排序场景以 `day_anchor` 产生的 instant 参与。
4. **AllDay vs AllDay**：年月日字典序（`LocalDate#<=>`）。
5. **Floating vs Floating**：墙钟字段字典序（`LocalWall#<=>`）。
6. **Floating vs 任何 instant 形态**：**不可比**——不提供比较函数；调用方必须先补时区（转 WallClock）或解析为 Instant，否则拒绝。
7. WallClock vs AllDay / WallClock vs Floating：先归一（§1 规则 1/4），同形态后按上述规则比较；不可归一的组合不可比。

存储层排序约定：所有「下一评估时刻」类查询（M5.1-WP2 按时间窗、M5.1-WP3 唤醒）以 UTC instant 为排序键；WallClock/AllDay 在**写入时**即算出下一 instant 锚存独立列（`next_wake_at` 类），原话列只作来源保留——查询永不现场解析墙钟。

**缓存锚的失效与重算**（tzdata 变化会使已缓存锚过期，例如纽约 12:00 写入时为 EDT 缓存 `16:00Z`，规则改为 `−05:00` 后正确锚是 `17:00Z`）：

1. **失效触发条件**（满足其一即标记 `next_wake_at` 待重算）：①启动时检测到 tzdata 版本较上次写入更新（记录写入时的 tzdata 版本号或对时区规则做摘要比对）；②该行 `*_tz`/墙钟原话/重复规则被显式修改；③评估器发现锚与按原话现算值不一致（对账即重算）。
2. **重算路径**：从保留的 WallClock/AllDay 原话列按 §2 规则**重新解析**（歧义取早、缺口拒绝交用户选择），回写 `next_wake_at`；重算发生在启动对账或该行评估时，不在查询热路径。
3. **重算完成前不得使用旧锚**：待重算的行不参与唤醒排序与触发（视为「锚不可信」），只参与原话展示；缺列 `wake_anchor_stale`（boolean）承载该标记，评估器/调度器查询过滤之。

## 4. RRULE/RDATE/EXDATE 原文保留与 Occurrence 生成边界

1. **原文保留**：重复系列存 RFC 5545 `RRULE/RDATE/EXDATE` 原文（TEXT 列），另存结构化摘要列（`freq`/`interval`）供查询过滤；未知属性与原文一起保留，不规范化。
2. **按窗口生成**：Occurrence 只在唤醒需求窗口 `[window_start, window_end]` 内按需展开（提案 §4.2「不把无限重复展开为无限行」）；窗口外不生成行。
3. **RDATE/EXDATE 集合运算**（RFC 5545 语义，两步不得合并）：
   - **加入**：实例集合 = DTSTART + RRULE 展开 + RDATE 附加。**实例身份按各值自身的时间表示解析出的 UTC 时刻判定**，身份相同才去重合并——同一当地墙钟但对应不同绝对时刻的实例（如纽约 2026-11-01 01:30 的 `05:30Z` 与 `06:30Z` 两个候选）是**不同实例**，不得按墙钟值合并丢失；RDATE 添加的实例与 RRULE 生成结果地位相同，不因「不属于 RRULE 展开结果」而被遗漏；
   - **缺口实例的去重身份**：解析为 Gap 的值没有 UTC 时刻，身份改按**原墙钟 + IANA 时区**判定，文法与 §4.4 缺口 slot 一致——`gap:<wall>@<tz>`（周期序列与 RDATE 产生的缺口实例同用此身份，避免同一缺口墙钟被 RRULE 与 RDATE 重复生成或相互顶替）；有效实例仍按 UTC 时刻去重，两规则并存不冲突（一个值要么解析为有效、要么为缺口，不同时具两种身份）；
   - **排除**：再对合并后的集合应用 EXDATE，「命中即跳过」**仅适用于 EXDATE**。
4. **EXDATE/RDATE 值的时区口径**：先按**属性自身的时间表示**解释每个值，再换算到系列的匹配表示：
   - 值带 `Z` 后缀 → **UTC 时刻**，按对应 UTC 时刻匹配（例：纽约系列中 `EXDATE:20260601T160000Z` 排除的是当地 12:00 那次，不是当地 16:00）；不得直接当作当地墙钟；
   - 值带 `TZID=` 参数 → 按**该 IANA 时区**的当地墙钟解释；
   - `DATE-TIME` 无 `Z` 无 `TZID`（RFC 5545 floating）→ 按系列 `*_tz` 的当地墙钟解释；
   - `DATE` 值（VALUE=DATE）→ 按日历日整日匹配。
   匹配针对系列展开出的各 occurrence 的原墙钟字段。tzdata 变化导致的 UTC 时刻漂移不影响原墙钟匹配。
4. **Occurrence 稳定身份**：`schedule_id + slot`，**slot 由实例身份生成、与生成窗口无关**——同一实例在重叠窗口重复展开映射到同一 slot（不重复入库），不同实例（不同 UTC 时刻或不同缺口墙钟）映射到不同 slot（不撞 `(schedule_id, slot)` 唯一约束）。身份生成规则的工程细节归 M5.1-WP3，本文约定文法与判据：
   - **有效实例**（有 UTC 时刻）：slot = `inst:<utc>`——来源无关：一次性 DTSTART、RRULE 展开、RDATE 附加共用同一文法；RRULE 与 RDATE 各自产出的同一 UTC 时刻天然去重，不再因来源前缀不同而重复入库；
   - **缺口实例**（无 UTC 时刻）：slot = `gap:<wall>@<tz>`——按原墙钟 + IANA 时区判身份（来源无关；同一缺口墙钟在任意窗口重展开都映射到同一 slot）。
   生成窗口只决定「哪些实例被展开」，不参与 slot 取值。
5. **缺口与歧义 occurrence**：解析遇 §2 缺口 → 该 occurrence 置 `state=invalid`，**不生成 UTC `due_at`**，但必须持久化原始墙钟信息（`original_wall` + `original_tz` 列）供用户决策后重解析；歧义按 §2 取较早者正常生成并标 `ambiguous_local_time`。缺口实例 slot 统一为 `gap:<wall>@<tz>`（§4.4，与来源和窗口无关；如 `gap:2026-03-08T02:30:00@America/New_York`）。`invalid` 不静默跳过，须用户选择：**改时间/换时区 → 原 gap slot 置一条 `skipped` 墓碑行（保留原墙钟，占住 slot），新解实例以 `inst:<新utc>` 另起一行转 `pending`**——墓碑使重叠窗口重展开命中既有 slot 而不再复活用户已处理的原缺口；**跳过 → 本行直接置 `skipped` 并保留原墙钟（`due_at` 保持空，不伪造 UTC 时刻）**。
6. **tzdata 变化对已持久化 occurrence 的失效与对账**（保证同一墙钟实例最多一次唤醒）：
   - **展开时记录来源墙钟**：所有有效实例行写入 `source_wall` + `source_tz`（展开器手握墙钟值，落列即可）——使任一行都可独立重解析，不依赖 slot 反推；
   - **失效触发**：§3 的 tzdata 版本变更检测点同步标记受影响 schedule 为「occurrence 对账中」，对账完成前该 schedule 的未完成 occurrence 暂停唤醒（schedule 级 stale，同 §3 缓存锚口径）；
   - **对账规则**：对每条未完成（pending/claimed）行按 `source_wall`+`source_tz` 现算新 UTC 时刻——与旧 `due_at` 一致则不动；不一致则**旧行置 `superseded`**（状态集合见 §5，调度器只取 pending/claimed，旧时刻不再触发），新时刻由下一窗口展开以 `inst:<新utc>` 正常生成；
   - 对账由启动对账或该 schedule 下次评估执行（§3 重算路径同源），不在查询热路径。

## 5. 首版表结构草案（M5.1 六表）

覆盖 M5.1-WP2（四表）+ M5.1-WP3（两表）全部仓储字段；外键只在这六表内部，无悬空引用。`ExternalLink`（M6 日历镜像）与 `Run/ledger`（复用既有 `intents/tasks/leases/ledger`，M5.1-WP4）不在本草案。

SQLite 方言约定：主键 `INTEGER PRIMARY KEY` 自增或 `TEXT` 稳定 id（uuid）；时间列按 §1 存 TEXT（ISO8601 UTC）；`json` 列存 TEXT（应用层校验结构）；枚举列 TEXT + CHECK 约束（迁移器单语句限制，见 §6）。

```sql
-- commitments：持久意图（M5.0-WP1 §2.1 字段表逐一对应）
CREATE TABLE IF NOT EXISTS commitments (
  id                  TEXT PRIMARY KEY,          -- uuid
  outcome             TEXT NOT NULL,             -- §2.1：始终必填
  source              TEXT NOT NULL,             -- §2.1：必填（T01/T03/T04 拒绝空值）
  owner               TEXT NOT NULL,
  state               TEXT NOT NULL CHECK (state IN
                        ('dormant','needs_clarification','waiting_condition','ready',
                         'active','at_risk','overdue','completed','cancelled')),
  due_at              TEXT,                      -- UTC ISO8601；硬截止
  prepare_window      TEXT,                      -- ISO8601 duration
  due_wall            TEXT,                      -- 墙钟截止原话（YYYY-MM-DDTHH:MM:SS，无偏移）
  due_tz              TEXT,                      -- IANA 名；due_wall 非空时必非空
  completion_condition TEXT,                     -- 空 → 完成走 user_confirmed
  followup_policy     TEXT,                      -- json
  remind_policy       TEXT,                      -- json
  plan_version        INTEGER NOT NULL DEFAULT 1,
  paused              INTEGER NOT NULL DEFAULT 0,-- boolean 0/1（不变式 4）
  missing_fields      TEXT,                      -- json 数组；needs_clarification 态必非空
  clarify_by          TEXT,                      -- UTC ISO8601；needs_clarification 态必填
  next_wake_at        TEXT,                      -- §3 排序键：写入时算出的下一 UTC 锚（查询用）
  wake_anchor_stale   INTEGER NOT NULL DEFAULT 0,-- §3 缓存锚失效标记：1=待重算，重算前不参与唤醒排序
  ambiguous_local_time INTEGER NOT NULL DEFAULT 0, -- §2 口径②：歧义标注
  created_at          TEXT NOT NULL,
  updated_at          TEXT NOT NULL,
  CHECK (state != 'needs_clarification' OR
         (missing_fields IS NOT NULL AND missing_fields != '[]' AND clarify_by IS NOT NULL)),
  CHECK ((due_wall IS NULL) = (due_tz IS NULL)),
  CHECK (NOT (due_wall IS NOT NULL AND due_at IS NOT NULL))                             -- 墙钟与 UTC 互斥
);
CREATE INDEX IF NOT EXISTS idx_commitments_owner_state ON commitments (owner, state);
CREATE INDEX IF NOT EXISTS idx_commitments_next_wake ON commitments (next_wake_at)
  WHERE next_wake_at IS NOT NULL;

-- checkpoints：一次时间或条件评估（§2.2；验收维度经 commitment_id 继承，不冗余列）
CREATE TABLE IF NOT EXISTS checkpoints (
  id              TEXT PRIMARY KEY,
  commitment_id   TEXT NOT NULL REFERENCES commitments(id),
  reason          TEXT NOT NULL CHECK (reason IN
                    ('time_due','condition_check','external_change','manual')),
  condition       TEXT,                       -- json；waiting_condition 用
  context_version INTEGER NOT NULL,
  result          TEXT NOT NULL CHECK (result IN
                    ('silent','notified','action_required','condition_met','condition_failed')),
  next_action     TEXT CHECK (next_action IN ('reschedule','escalate','none')),
  evaluated_at    TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_checkpoints_commitment ON checkpoints (commitment_id, evaluated_at);

-- reminders：提醒意图（§2.3）
CREATE TABLE IF NOT EXISTS reminders (
  id              TEXT PRIMARY KEY,
  commitment_id   TEXT NOT NULL REFERENCES commitments(id),
  why             TEXT NOT NULL,
  escalate_budget INTEGER NOT NULL DEFAULT 0,
  due_at          TEXT,                       -- 提醒时刻（与 Checkpoint 分离）
  state           TEXT NOT NULL DEFAULT 'pending'
                    CHECK (state IN ('pending','delivered','cancelled')),
  created_at      TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_reminders_commitment ON reminders (commitment_id, state);

-- notification_deliveries：一次渠道投递（§2.4；不变式 1 由触发器 DB 级强制）
CREATE TABLE IF NOT EXISTS notification_deliveries (
  id             TEXT PRIMARY KEY,
  reminder_id    TEXT NOT NULL REFERENCES reminders(id),
  commitment_id  TEXT NOT NULL REFERENCES commitments(id),  -- 冗余关联（判定式用）
  trigger_reason TEXT NOT NULL,
  plan_version   INTEGER NOT NULL,
  channel        TEXT NOT NULL,
  state          TEXT NOT NULL CHECK (state IN
                   ('scheduled','sent','seen','actioned','superseded','expired','unknown')),
  supersedes     TEXT REFERENCES notification_deliveries(id), -- §2.4：superseded 可空
  sent_at        TEXT,                        -- 置 sent 时写入，变迁不清除
  created_at     TEXT NOT NULL
);
-- 不变式 1（同意图最多一个未决通知，§4.1 口径 = 未被后续投递替代的
-- scheduled/sent/seen 计一条）：纯部分唯一索引无法表达「已被 supersedes
-- 豁免」，故用 BEFORE INSERT/UPDATE 触发器 DB 级强制，非应用层检查。
CREATE UNIQUE INDEX IF NOT EXISTS uq_deliveries_scheduled
  ON notification_deliveries (commitment_id)
  WHERE state = 'scheduled';                 -- 快路径：scheduled 永远至多一条
CREATE TRIGGER IF NOT EXISTS trg_deliveries_invariant1_insert
BEFORE INSERT ON notification_deliveries
WHEN NEW.state IN ('scheduled','sent','seen') AND EXISTS (
  SELECT 1 FROM notification_deliveries d
  WHERE d.commitment_id = NEW.commitment_id
    AND d.state IN ('scheduled','sent','seen')
    AND d.id IS NOT NEW.supersedes                   -- NULL 安全：supersedes 为 NULL 时仍检查；替代某投递时豁免该投递
    AND NOT EXISTS (SELECT 1 FROM notification_deliveries s
                    WHERE s.supersedes = d.id)       -- 已有替代者的历史投递豁免
)
BEGIN
  SELECT RAISE(ABORT, '不变式 1：同一意图已存在未决投递（scheduled/sent/seen 且无替代者）');
END;
-- 触发器 2a：从非未决态转入未决态时，NEW 自身已有替代者（无论替代者处于
-- 何种状态）则拒绝。已在未决态内部的迁移（如 sent→seen 迟到回执）不增加
-- 未决数量，放行记录——故限定 OLD.state 不在未决集合内才检查。
-- 独立触发器而非 invariant1_update 的 WHEN 条件——放进 WHEN 只会「抑制触发」
-- （条件为假 → 不检查 → 更新照常成功），而这里需要的是「拒绝更新」。
-- 例：A、B(supersedes=A) 均 unknown，A→sent 被本触发器拦下。
CREATE TRIGGER IF NOT EXISTS trg_deliveries_no_pending_with_successor
BEFORE UPDATE OF state, supersedes, commitment_id ON notification_deliveries
WHEN NEW.state IN ('scheduled','sent','seen')
  AND OLD.state NOT IN ('scheduled','sent','seen')
  AND EXISTS (SELECT 1 FROM notification_deliveries s
              WHERE s.supersedes = NEW.id)
BEGIN
  SELECT RAISE(ABORT, '不变式 1：该投递已有替代者，不得转入未决态');
END;
-- 触发器 2b：进入未决态/替代关系或归属变化时，同意图不得已存在其他未决投递
CREATE TRIGGER IF NOT EXISTS trg_deliveries_invariant1_update
BEFORE UPDATE OF state, supersedes, commitment_id ON notification_deliveries
WHEN NEW.state IN ('scheduled','sent','seen')
  AND (
    OLD.state NOT IN ('scheduled','sent','seen')     -- 进入未决态
    OR OLD.supersedes IS NOT NEW.supersedes          -- 替代关系变化（如清除 supersedes 会使两条同时未决）
    OR OLD.commitment_id IS NOT NEW.commitment_id    -- 归属变化
  )
  AND EXISTS (
  SELECT 1 FROM notification_deliveries d
  WHERE d.commitment_id = NEW.commitment_id AND d.id != NEW.id
    AND d.state IN ('scheduled','sent','seen')
    AND d.id IS NOT NEW.supersedes                   -- NULL 安全比较（!= 遇 NULL 结果为 NULL，会漏检）
    AND NOT EXISTS (SELECT 1 FROM notification_deliveries s
                    WHERE s.supersedes = d.id
                      AND s.id IS NOT NEW.id)        -- 排除 NEW 自身的旧引用：BEFORE UPDATE 时存储里的
                                                     -- 本行仍是旧值（如旧 supersedes 仍指向 d），
                                                     -- 不排除会把 d 误判为「已有替代者」而漏检
)
BEGIN
  SELECT RAISE(ABORT, '不变式 1：同一意图已存在未决投递（scheduled/sent/seen 且无替代者）');
END;

-- Delivery 状态对账迁移规则（与上两触发器一致；完整状态机表归 M5.2-WP3）：
-- `unknown → sent` 仅当该投递**无替代者**时允许（投递结果确认的事实回填）；
-- 已被替代（存在 B.supersedes=A）的 unknown 行不得转 sent/scheduled/seen——
-- 其收口走 superseded（B 承接投递职责）；触发器对这类迁移 RAISE ABORT 与本规则一致。
CREATE INDEX IF NOT EXISTS idx_deliveries_reminder ON notification_deliveries (reminder_id, state);

-- wake_schedules：唤醒定义（提案 §5.3 职责分离：不承载长期目标）
CREATE TABLE IF NOT EXISTS wake_schedules (
  id            TEXT PRIMARY KEY,
  kind          TEXT NOT NULL CHECK (kind IN ('once','cron','interval','event','poll')),
  spec          TEXT NOT NULL,                -- 原文：cron 表达式 / interval 秒 / 事件条件 json
  tz            TEXT,                         -- 墙钟解释时区（一次性/周期可空=UTC）
  starts_at     TEXT,                         -- 生效下界（UTC）
  ends_at       TEXT,                         -- 生效上界（UTC；可空=无限，不展开仅判窗）
  enabled       INTEGER NOT NULL DEFAULT 1,
  created_at    TEXT NOT NULL
);

-- occurrences：一次应发生的唤醒（稳定身份 + 原子 claim；缺口实例可持久化待用户选择）
CREATE TABLE IF NOT EXISTS occurrences (
  id            TEXT PRIMARY KEY,             -- §4 稳定身份：schedule_id + slot
  schedule_id   TEXT NOT NULL REFERENCES wake_schedules(id),
  slot          TEXT NOT NULL,                -- 实例身份（§4.4）：inst:<utc> / gap:<wall>@<tz>，与窗口无关
  due_at        TEXT,                         -- 本次唤醒 UTC 时刻（排序键）；缺口来源行可为空
  state         TEXT NOT NULL CHECK (state IN
                  ('pending','claimed','done','skipped','merged','invalid','superseded')),
  original_wall TEXT,                         -- 缺口实例的原始墙钟（不可解析时的持久化恢复信息）
  original_tz   TEXT,                         -- 缺口实例的 IANA 时区
  source_wall   TEXT,                         -- 有效实例的来源墙钟（展开时记录，tzdata 对账重解析用，§4.6）
  source_tz     TEXT,                         -- 有效实例的来源时区
  claimed_by    TEXT,                         -- 原子 claim：持有者
  claim_expires_at TEXT,                      -- lease 到期（可回收）
  generated_for TEXT,                         -- 生成窗口标记（补跑/合并审计用）
  created_at    TEXT NOT NULL,
  UNIQUE (schedule_id, slot),
  -- 唤醒态（pending/claimed/done/merged）必须有 UTC 时刻且不带缺口恢复信息
  CHECK (state NOT IN ('pending','claimed','done','merged')
         OR (due_at IS NOT NULL AND original_wall IS NULL)),
  -- invalid 必带缺口恢复信息且无 due_at
  CHECK (state != 'invalid'
         OR (original_wall IS NOT NULL AND original_tz IS NOT NULL AND due_at IS NULL)),
  -- 无 due_at 的行（缺口来源的 invalid/skipped）必须携带恢复信息；缺口来源的
  -- skipped 保留原墙钟（不伪造 UTC 时刻），正常来源的 skipped 保留原 due_at
  CHECK (due_at IS NOT NULL OR (original_wall IS NOT NULL AND original_tz IS NOT NULL))
)
CREATE INDEX IF NOT EXISTS idx_occurrences_due ON occurrences (state, due_at);
```

无悬空外键自查：全部 REFERENCES 均落在六表内部（deliveries→reminders/commitments/self；checkpoints→commitments；occurrences→wake_schedules）。

## 6. 迁移方案（`PRAGMA user_version` + 有序迁移）

1. **版本承载**：SQLite `PRAGMA user_version`（单整数，0=未初始化）。迁移列表为代码内有序数组 `MIGRATIONS = [{version: 1, statements: [...]}...]`，每个版本一组**单语句数组**——Crystal sqlite3 绑定一次只接受一条语句（store.cr 既有注释），迁移器逐条 exec。
2. **执行序**：启动时读 `user_version` → 依序应用 `(当前版本, 目标版本]` 的迁移。**每个版本严格按此顺序单事务执行**：`BEGIN` → 逐条执行迁移语句 → **写新 `user_version`** → `COMMIT`；任一步失败即 `ROLLBACK`——结构变更与版本号要么一起提交、要么一起回滚（若先 COMMIT 再写版本号，两步之间进程终止会导致重启后重跑已提交的语句，违背「半途不留脏态」）。M5.1-WP1 验收口径不变。
3. **新库直达最新**：`user_version=0` 的全新库按序跑全部迁移；**存量库零手工动作**（v1 基线快照迁移动作由 M5.1-WP1 实装，本文定契约）。
4. **幂等**：连续两次 migrate 第二次为 no-op（版本已最新）；同一版本内语句用 `IF NOT EXISTS`/幂等写法兜底重入。
5. **与 `make release` 兼容**：迁移只动 `data_dir` 下的库文件，不写配置目录（M5.0-WP3 应用根契约：数据根启动时固定，热更新不迁移）。
6. **版本与代码同步**：`MIGRATIONS` 尾版本号与发布版本无关，只随表结构变更递增；禁止修改已发布版本的语句（只追加）。

## 7. 模块交付与验收对照（issue #64）

| 验收项 | 交付物 | 证据 |
|---|---|---|
| ①缺口拒绝返回 needs_user_choice | `resolve_wall` Gap / `resolve_wall!` GapError（code=needs_user_choice） | `spec/platform/time_semantics_spec.cr`「① 春季缺口」3 例 |
| ②歧义取 UTC 较早者 + 标注 | `Resolution#primary`（较早）+ `#ambiguous?` | 「② 秋季重复」：primary=−04:00 且 `primary.to_unix < secondary.to_unix` |
| ③全天跨时区不漂移 | `LocalDate` 无时区绑定 + `day_anchor` 回读同日历日 | 「③ 全天 DATE」3 例（上海建/洛杉矶读同 DATE） |
| 四类比较排序规则 | §3 规则 + `LocalDate#<=>`、`LocalWall#<=>`、instant 锚比较 | 「排序规则」3 例 + 区间比较例 |
| RRULE 口径与 Occurrence 边界 | §4（文本契约；展开实现归 M5.1-WP3/M6） | 本文 §4 |
| 表草案覆盖 M5.1 全部仓储字段、无悬空外键 | §5 六表 + 外键自查 | 本文 §5 |
| `PRAGMA user_version` 迁移方案 | §6（契约；迁移器实装归 M5.1-WP1） | 本文 §6 |
| 代码质量门禁 | `crystal tool format --check` + ameba 0 issues + 全量 `crystal spec` 回归 | PR CI + 本地输出（18 例时间语义 spec 全绿；文档部分验收按 issue #64 ⓐ 以评审通过为准，不因 spec 未绿判本期 No-Go） |

## 8. 待评审裁决点

1. ±48h 探测窗口的历史角落边界（§2 末）是否接受为已知限制。
2. **M5.0 期门禁中调度四条的取舍**：WBS B.9（[m5-commitments.md](../plan/wbs/m5-commitments.md) 期门禁节）写「M5.0 期门禁 = 文档评审 + 调度四条全绿（含 `make spec`）」，issue #64 验收 ⓐ 写「文档部分以评审通过为准、不因 spec 未绿判本期 No-Go」——两者对 `make spec` 的处理冲突。§14 roadmap 按后者口径书写；**是否保留 format/lint/release 而剔除 spec、并同步修订 WBS 与 gates.md，待计划负责人裁决**（本文不代裁决）。
3. Occurrence 身份字段格式（§4.4）在 M5.1-WP3 实装前是否需要冻结更细的 slot 文法。
