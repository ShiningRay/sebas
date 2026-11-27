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

## 4. RRULE/RDATE/EXDATE 原文保留与 Occurrence 生成边界

1. **原文保留**：重复系列存 RFC 5545 `RRULE/RDATE/EXDATE` 原文（TEXT 列），另存结构化摘要列（`freq`/`interval`）供查询过滤；未知属性与原文一起保留，不规范化。
2. **按窗口生成**：Occurrence 只在唤醒需求窗口 `[window_start, window_end]` 内按需展开（提案 §4.2「不把无限重复展开为无限行」）；窗口外不生成行。
3. **EXDATE 匹配口径**：按**原墙钟值**匹配（系列展开出的各 occurrence 保留其原墙钟字段），EXDATE 命中即跳过该次；UTC 时刻恰因 tzdata 变化而漂移不影响匹配。
4. **Occurrence 稳定身份**：`schedule_id + slot`（一次性：`once:<utc>`；周期：`cron:<原始表达式>:<本轮起始 UTC>`）——身份生成规则归 M5.1-WP3，本文只约定「身份字段必须可由原文与窗口重算」。
5. **RDATE/EXDATE 与时区**：以 `*_tz` 的当地墙钟解释；解析遇 §2 缺口/歧义按 §2 口径处理（歧义取早、缺口该 occurrence 置 `invalid` 并要求用户选择，不静默跳过）。

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

-- notification_deliveries：一次渠道投递（§2.4；不变式 1 由部分唯一索引强制）
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
-- 不变式 1（同意图最多一个未决通知）：DB 级强制，非应用层检查
CREATE UNIQUE INDEX IF NOT EXISTS uq_deliveries_pending
  ON notification_deliveries (commitment_id)
  WHERE state IN ('scheduled');
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

-- occurrences：一次应发生的唤醒（稳定身份 + 原子 claim）
CREATE TABLE IF NOT EXISTS occurrences (
  id            TEXT PRIMARY KEY,             -- §4 稳定身份：schedule_id + slot
  schedule_id   TEXT NOT NULL REFERENCES wake_schedules(id),
  slot          TEXT NOT NULL,                -- once:<utc> / cron:<expr>:<本轮起始 UTC>
  due_at        TEXT NOT NULL,                -- 本次唤醒 UTC 时刻（排序键）
  state         TEXT NOT NULL CHECK (state IN
                  ('pending','claimed','done','skipped','merged')),
  claimed_by    TEXT,                         -- 原子 claim：持有者
  claim_expires_at TEXT,                      -- lease 到期（可回收）
  generated_for TEXT,                         -- 生成窗口标记（补跑/合并审计用）
  created_at    TEXT NOT NULL,
  UNIQUE (schedule_id, slot)
);
CREATE INDEX IF NOT EXISTS idx_occurrences_due ON occurrences (state, due_at);
```

无悬空外键自查：全部 REFERENCES 均落在六表内部（deliveries→reminders/commitments/self；checkpoints→commitments；occurrences→wake_schedules）。

## 6. 迁移方案（`PRAGMA user_version` + 有序迁移）

1. **版本承载**：SQLite `PRAGMA user_version`（单整数，0=未初始化）。迁移列表为代码内有序数组 `MIGRATIONS = [{version: 1, statements: [...]}...]`，每个版本一组**单语句数组**——Crystal sqlite3 绑定一次只接受一条语句（store.cr 既有注释），迁移器逐条 exec。
2. **执行序**：启动时读 `user_version` → 依序应用 `(当前版本, 目标版本]` 的迁移 → 每个版本单事务（`BEGIN/COMMIT`，成功后写新 `user_version`）→ 失败回滚且版本号不前进（半途不留脏态，M5.1-WP1 验收口径）。
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
| 调度四条在模块上全绿 | `crystal spec` 16 例 + `crystal tool format --check` + ameba 0 issues | PR CI + 本地输出 |

## 8. 待评审裁决点

1. ±48h 探测窗口的历史角落边界（§2 末）是否接受为已知限制。
2. `next_wake_at` 冗余列（§5 commitments）与「查询永不现场解析墙钟」（§3.7）配套——评估器写路径承担解析职责，是否认可该分工。
3. Occurrence 身份字段格式（§4.4）在 M5.1-WP3 实装前是否需要冻结更细的 slot 文法。
