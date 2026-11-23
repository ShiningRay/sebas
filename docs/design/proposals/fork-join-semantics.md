# Fork/Join 影分身语义（fork-join-semantics）

> **状态**：已定稿并吸收（M4.0-WP1 评审定稿 + M4.0-WP2 吸收回写完成：契约摘要落 spec/08-multi-agent.md §8.4、M4 期落 spec/14-roadmap.md §14；本文转为语义细则的权威参考）
> **日期**：2026-11-20 · **作者**：工部尚书（受首辅分派）
> **定位**：本文是 Fork/Join 影分身的**方案核心**——原语契约、Join 语义矩阵、分层回写、expectations 表、能力衰减、触发权、成本与失败语义。架构落位见 [fork-join-shadow-clone-architecture.md](fork-join-shadow-clone-architecture.md)；现状差距见 [fork-join-shadow-clone-analysis.md](../fork-join-shadow-clone-analysis.md)；定位立论见 [fork-join-shadow-clone-positioning.md](fork-join-shadow-clone-positioning.md)。
> **命名**：原语名 `fork` / `join`（POSIX 直觉）；UI 层叫「影分身」。
> **证据纪律**：`[来源: 仓库:路径:行]` 为翰林报告（analysis.md）已核实锚点，关键处已经工部抽查复核；`[推演]` 为本文新增设计判断；`[未验证]` 为待实测项。九问裁断（Q1–Q9）为设计硬约束，全部落实。

---

## 0. 摘要与裁断基线

| 裁断 | 结论（本文落实处） |
|---|---|
| Q1 session_key | 五段键结构不动；fork 分身键 = `agent:<父agent_id>:internal:fork:<fork_id>:<member_index>`（fork 级 + 成员序号两段后缀，成员级独立会话；§1.3） |
| Q2 join 落库 | 新建 `expectations` 表（store 新增表），不复用 tasks kind 扩展；分身任务挂 `TaskRow.parent_id/owner_task_id` 树（§4） |
| Q3 触发路径 | M4.1/M4.2 仅用户显式 + DSL 声明，不动生产 `agent_turn`；ReAct 工具循环是 M4.3 独立前置工作包（§6） |
| Q4 装配欠账 | 「生产装配补齐」独立工作包，全线前置，排 M4.1 首包（架构文档 §3） |
| Q5 与调度顺序 | fork/join 迁就调度接口；M4.1 开工条件 = issue #9 的 WP1/WP2 已合或 admission/envelope 接口冻结；fork 入队是调度输入类型扩展（§8.2） |
| Q6 能力衰减 | 生效能力 = fork 显式声明 ∩ 父 `tools.allow`；未声明用默认只读档（不含写副作用工具、不携带 secrets）（§5） |
| Q7 门禁口径 | M4 期统一「调度四条」= make format-check + make spec + make lint + make release；纯文档包门禁 = 评审通过 |
| Q8 轴①补位 | 前台接待入 M4.3 独立工作包；会话生命周期治理入 M4.4（排期文档承载） |
| Q9 里程碑重编 | 提案 M0.5–M4 重编为 M4.0–M4.4，映射表见排期文档 B.8 |

---

## 1. fork 原语契约

### 1.1 输入字段

fork 调用（DSL action / IPC / HTTP 显式命令，M4.1；对话流内自然调用，M4.3）统一输入契约：

| 字段 | 类型 | 必填 | 语义 |
|---|---|---|---|
| `task` | String | 是 | 分身任务描述（自然语言） |
| `count` | Int32 | 是 | 分身数 N；N=1 合法；单次 fork N ≤ 分身并发闸（§1.5），超限整体拒绝（不排队——排队语义属 DSL 编排层，不属原语） |
| `snapshot.window` | Int32? | 否 | 快照窗口行数，默认沿用父 `memory.window \|\| 50` 口径 [来源: 仓库:src/platform/cli/gateway.cr:214] |
| `snapshot.include` | Array(String)? | 否 | 快照包含项白名单，默认 `["transcripts","system_prompt","skills"]`；可选 `"memos"`（近期决策记忆）。**不提供任何 secrets 包含项**（§5.3） |
| `tools` | Array(String)? | 否 | 能力显式声明；缺省 = 默认只读档（§5.1）；生效 = 声明 ∩ 父 `tools.allow`（§5.2） |
| `role` | String? | 否 | 角色卡名（M4.4 模板库落位后生效；M4.1–M4.3 仅校验存在性并注入 system prompt 后缀 [来源: 仓库:src/agents/skills/skills.cr:43-83]） |
| `mode` | String | 是 | `all` / `any` / `allSettled`（§4.3） |
| `deadline` | Int32 (秒) | 是 | 相对超时；DSL 必填，命令行缺省 3600s。[推演]：必填防 expectation 永久悬挂；3600s 默认值循 approvals DEFAULT_TIMEOUT=300 量级上调 [来源: 仓库:src/orchestration/approvals/approvals.cr:30] |

### 1.2 快照内容与边界

快照 = fork 那一刻父会话上下文的只读拷贝，三部分：

1. **transcripts 窗口读取**：`store.transcripts(parent_session).last(window)`，即父会话最近 window 行消息 [来源: 仓库:src/platform/store/store.cr:406-417；调用先例 gateway.cr:214]。
2. **system prompt**：父 agent persona（system prompt 组装沿用现有装配口径）。
3. **skills 注入**：SKILL.md frontmatter 指令注入 [来源: 仓库:src/agents/skills/skills.cr:43-83]。

边界（**快照不含**）：父 agent 的 secrets（api_key 等，§5.3）；父未落地的在途消息（只读已落库 transcripts，天然一致 [来源: 仓库:src/platform/store/store.cr:387-395]）；其他会话的 transcript（跨会话隔离，五段键分片 [来源: 仓库:src/agents/pool.cr:11-12]）。

快照注入走 `HttpProvider.complete(messages)` 纯消息数组接口，直接可用 [来源: 仓库:src/providers/providers.cr:58-88]；provider 实例经 `Providers::Pool.for_agent` 取用 [来源: 仓库:src/providers/pool.cr:12-25]。

### 1.3 分身键与任务树（Q1 裁断）

- **session_key 五段结构不动** [来源: design.md §3.3]：`agent:<agent_id>:<account_id>:<channel_type>:<peer>`。
- fork 分身五段取值：**agent 段 = 父 agent_id**（分身以父人格运行）；**account 段 = `"internal"`**；**channel_type 段新增枚举值 `"fork"`**；**peer 段 = `fork_id:member_index`**（fork_id 标识一次 fork 调用，member_index 标识同次 fork 内的成员序号 1..N——成员级独立会话与 transcript，是 §3 分层回写按成员记录 session/行数范围的前提）。成员完整键 = `agent:<父agent_id>:internal:fork:<fork_id>:<member_index>`；成员 task_id 与之一一对应（§1.4 成员列表、§3 members[].session）。
- 先例对齐：subagent 已用 `(agent_id, "internal", "subagent", subtask_key)` 四参数先例 [来源: 仓库:src/agents/subagent.cr:44,56]——fork 与之同构，仅 channel_type 枚举值不同，Pool 分片、transcripts 键、调度 admit 三处无需新机制 [来源: analysis.md §3.1]。
- fork_id 格式：`fork:<uuid4 短码>`（[推演]：循 subagent `task_id="sub:#{subtask_key}"` 可读前缀先例 [来源: 仓库:src/agents/subagent.cr:33]）。
- **任务树登记**：每个分身一行 tasks，`kind="fork_child"`，`parent_id = owner_task_id = 父任务 id`——直接复用现成 `TaskRow(id,parent_id,kind,status,phase,restart_count,owner_task_id)` 字段，不加列 [来源: 仓库:src/platform/store/store.cr:23-25]。

### 1.4 fork 返回回执

同步返回（DSL 声明后编排执行 / 显式命令响应）：`fork_id`、分身数 N、快照行数、成员 task_id 列表、mode、deadline、**成本预估**（§9.1）。回执进父会话 transcript（role=system），保证用户与父 agent 均可见。

### 1.5 分身并发闸

fork 成员并发沿用命名信号量先例：`SubagentManager::Semaphore`（DEFAULT_MAX_CONCURRENT=3）[来源: 仓库:src/agents/subagent.cr:16,25]，fork 侧默认同 3、可配置。[推演]：并发闸限的是「同时在跑的分身 turn 数」，防 fork 风暴；DSL 层批量声明可超 3，超出部分排队执行（信号量 acquire 语义 [来源: 仓库:src/agents/subagent.cr:50]），不计入原语拒绝。

---

## 2. Join 语义矩阵

> 实现状态（M4.2-WP2，#47）：副作用四级由 `src/tools/registry.cr` 的
> `SideEffect` 枚举承载（`ReadOnly`/`FileWrite`/`NetWrite`/`Irreversible`，
> 与审批分层 `Risk` 正交）；逐工具归属定案——`memory.search`/`session.read`
> 为 L0，`memory.save`（共享写状态）与 `message.send` 为 L2，`file.write`
> （最小文件写示例）为 L1，L3 暂无实例（审批链 M2-WP4 接）。副作用清单经
> `EffectsLedger` 随 `ToolContext.ledger` 收集、由成员任务 payload 的
> `effects` 数组落库、聚合进 join.report；文件指纹冲突检测以**成员写后
> 内容摘要**为基线（成员自己的合法写入不算冲突），父在其后的改动（含删除）
> 标 `CONFLICT` 进 report.conflicts 父裁决清单，join 侧不自动 merge。

### 2.1 副作用四级定义

| 级 | 名称 | 判定 | 工具映射 |
|---|---|---|---|
| L0 | 只读 | 无任何外部状态改变 | `memory.search` / `session.read` 类 [来源: 仓库:src/tools/executor.cr:122-129 现有 4 工具中只读两个] |
| L1 | 文件写 | 改本地文件系统 | 文件类 effectful 工具（replay=effectful 口径 [来源: 仓库:src/orchestration/dsl/dsl.cr:154-155]） |
| L2 | 网络写 | 向外部系统发出不可撤回请求 | `message.send` 类（已带幂等键 [来源: 仓库:src/platform/cli/gateway.cr:178-180]）及未来 HTTP 类 |
| L3 | 不可逆 | 删除、支付、发布、发送后不可撤回的破坏性操作 | risk:high 类；hardline 地板之上（§7） |

[推演]：四级由工具注册表 `risk` 字段承载（Tool(name,description,replay,risk) [来源: 仓库:src/tools/registry.cr:44-59]），新增 `risk:readonly/effect_file/effect_net/irreversible` 四值映射；具体工具逐一归属在 M4.2-WP2 落地时定案（此处定映射规则，不定逐工具清单——避免拍脑袋编造归属）。

### 2.2 矩阵（副作用级 × Join 时机，逐格策略）

列 = Join 时机（**正常完成** = 全部/首个成员按 mode 到达终态；**超时** = deadline 到期；**失败** = 分身任务 failed；**取消** = 用户或父会话显式取消）。行 = 分身执行期间发生过的副作用最高级别。

| | 正常完成 | 超时 | 失败 | 取消 |
|---|---|---|---|---|
| **L0 只读** | 结论全量并入 L1 回写；无冲突 | 已完成成员结论照常回写，标 `partial` | 失败原因 + 已获只读结论回写 | 取消回执回写；已获结论标 `discarded` 仅落 L2 |
| **L1 文件写** | 副作用清单（文件路径×动作×时间）必进 L1 回写；**文件指纹冲突检测**：fork 快照记录工作区相关文件摘要，回写时与父当前状态对比，不一致 → 该文件标 `CONFLICT` 进「需父裁决清单」，**不自动 merge** | 同左 + `partial` 标注；未完成成员已写文件照列 | 已发生写**不回滚**，清单 + 失败上下文回写 | 已发生写不回滚（写即事实），清单 + 取消回执回写 |
| **L2 网络写** | 副作用清单（目标×内容摘要×幂等键）进 L1 回写；同目标重复发送标注（幂等键已防重复投递 [来源: 仓库:src/platform/cli/gateway.cr:178-188]） | 同左 + `partial`；在途请求不追杀（发出即事实） | 已发部分照列清单 + 失败上下文 | 尽力停在发送前；已发不可撤回，照列清单 |
| **L3 不可逆** | 仅当 Approvals::Center 批准过才可能发生（§7）——**审批凭证 + 副作用清单**进 L1 回写 | 已批准已执行的照常回写 + `partial`；**排队未批准的审批请求自动作废**（超时 deny 语义 [来源: 仓库:src/orchestration/approvals/approvals.cr:81-83]） | 不可逆工具必须「先审批后执行、失败不半途」（原子性要求）；半途失败标 `CRITICAL` 进审计 | 排队未批准的直接撤回；已批准执行中的尽力停在审批点前；已执行不可撤回，凭证 + 清单回写 |

矩阵通则（贯穿 16 格）：[推演]
1. **副作用已发生不隐瞒**：任何格的 L1/L2/L3 清单必回写（「告知本体」先于「结论合并」）。
2. **不自动 merge**：文件冲突不自动合并，列入父裁决清单——并行 agent 同改文件致事实漂移是既有教训，合并责任在父 agent/用户，不在 join 机制。
3. **partial 标注**：超时/失败/取消场景下回写内容必带成员终态数组，父 agent 可见哪些结论是完整的。

### 2.3 any 模式残余分身处置（必答项）

`any` 模式首个成员成功终态即 settle expectation 并触发 L1 回写（首个成功者结论）。残余分身三步处置：[推演]

1. **尽力取消**：向残余分身发协作式取消——复用已落地的 busy-interrupt-redirect 控制通道与协作式取消语义（[busy-interrupt-redirect.md](busy-interrupt-redirect.md)，PR #31 已合，issue #28 已关），**本文不重设计 interrupt**。分身处于安全点（未开始/未进 effectful 段）→ 任务置 `cancelled`——这是分身任务层新终态（M4.1 落地）：显式取消不参与 restartLimit 恢复，区别于 busy-interrupt 落账用的 turn 终态 `interrupted`（后者属崩溃恢复语义 [来源: 仓库:src/platform/store/store.cr:328-330]）。
2. **已写副作用不丢弃**：残余分身已发生的 L1/L2 副作用清单仍并入回写（副作用是事实）；结论不并入主上下文，全量 transcript 按分身会话键照常落盘（L2 不变，[来源: 仓库:src/platform/store/store.cr:387-395]）。
3. **越过取消点者**：正在执行 L3 不可逆动作的分身不中断（原子性要求 §2.2），等待终态；其结果登记为「迟到成员」——副作用照列、结论仅落 L2。

settle 判定补充（非处置步骤）：失败不算「先到」——`any` 只认成功终态；全部成员失败 + deadline 到期 → `expired`，全部失败明细回写（与 §4.3 any 行同口径）。

---

## 3. 分层回写（Join Writer 输出契约）

Join = 三层回写，避免「全量 transcript 上下文爆炸」与「纯摘要丢失细节」两个极端（[positioning.md](fork-join-shadow-clone-positioning.md) :77 倾向方案）：

| 层 | 内容 | 落点 |
|---|---|---|
| **L1 主上下文** | 结构化回写消息：结论 + 关键决策点 + 副作用清单 + 成员终态数组 | `append_transcript(parent_session, "agent", 回写JSON)` ——父会话下一 turn 的 transcripts 窗口自动带入 [来源: 仓库:src/platform/store/store.cr:387-395；窗口读取 :406-417] |
| **L2 全量落盘** | 分身完整 transcript | 分身会话键在执行期间已 SQLite+JSONL 双写，**无需二次搬运**——回写消息中引用分身会话键与行数范围即可 [来源: 仓库:src/platform/store/store.cr:387-395] |
| **L3 可检索索引** | 回写消息内含成员（task_id、会话键、终态、行数范围）三元组 | 供 `session.read` 与管理面回放检索 |

L1 回写消息 JSON 草案：[推演]

```json
{
  "type": "join.report",
  "fork_id": "fork:a1b2c3",
  "mode": "all",
  "outcome": "settled | failed | expired | cancelled",
  "conclusions": [{"member": 1, "conclusion": "…", "decisions": ["…"]}],
  "effects": [{"level": "L1", "target": "path/or/peer", "action": "write|send|…", "status": "done|CONFLICT"}],
  "members": [{"task_id": "fork:…:1", "session": "agent:…:internal:fork:…", "state": "done|failed|cancelled|running", "late": false, "lines": 42}]
}
```

枚举口径：`outcome` 的 `settled/cancelled/expired` 与 §4.2 回写状态机终态同名对应，`failed` 为折叠态——expectation 状态机仍落 `settled`、判定失败由 `result` 字段承载（§4.3 all 行；§9.2 全部失败行 settle(result=failed)）；`partial` **不是** outcome 值，超时/失败/取消场景的不完整信息由 `members[].state` 终态数组承载（§2.2 通则 3；§4.2 expired 同样产出带 partial 标注的报告）；`members[].state` 中 `done/failed` 即 tasks.status 原值（单一事实源 [来源: 仓库:src/platform/store/store.cr:308-315]），`cancelled` 为分身显式取消终态（§2.3 步骤 1），`running` 为回写时刻仍未达终态的成员（超时/过期场景尽力取消未及者，§9.2 超时行）——其最终终态以 tasks.status 为准，循 owner_task_id 找回（§9.2 父崩溃恢复行）；迟到与终态正交记录：`late` 布尔标注 any 残余越过取消点者（§2.3 步骤 3），成员终态仍由 `state` 如实承载，不互斥。

回写幂等：以 memo 键 `join:<fork_id>:written` 先写后发（first-write-wins 先例 [来源: 仓库:src/platform/store/store.cr:369-383]），崩溃重放不重复回写。

---

## 4. expectations 表与 mode 语义（Q2 裁断）

### 4.1 DDL 草案（store 新增表）

```sql
CREATE TABLE IF NOT EXISTS expectations (
  id             TEXT PRIMARY KEY,        -- "join:" + fork_id
  fork_id        TEXT NOT NULL,          -- fork 级标识（不含 member_index）；从成员键 peer 段 fork_id:member_index 取前段即可关联，同次 fork 全部成员共享同一 expectation 行
  parent_task_id TEXT NOT NULL REFERENCES tasks(id),
  parent_session TEXT NOT NULL,          -- L1 回写目标（父会话五段键）
  mode           TEXT NOT NULL,          -- all | any | allSettled
  deadline       TEXT NOT NULL,          -- 绝对时刻（ISO-8601，fork 时刻 + deadline 秒）
  members        TEXT NOT NULL,          -- JSON array：分身 task_id 列表
  settled_count  INTEGER NOT NULL DEFAULT 0,
  status         TEXT NOT NULL DEFAULT 'open',   -- open|settling|settled|cancelled|expired
  result         TEXT,                   -- 判定终值（§3 L1 回写摘要 + per-member 终态）
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_expectations_fork ON expectations(fork_id);
```

- 列风格、`REFERENCES tasks(id)`、索引写法全部循现有 SCHEMA 先例 [来源: 仓库:src/platform/store/store.cr:32-148]。
- **不复用 tasks kind 扩展**（Q2 裁断）：expectation 是「多成员汇聚点」，生命周期独立于任何单成员任务；塞进 tasks 会把 mode/deadline/members 塞进 payload 字符串、丧失可查询性与调度恢复能力。
- 成员终态**不在本表冗余**：tasks.status 是权威，判定器读 tasks 聚合（单一事实源，[推演]）。

### 4.2 回写状态机

`open → settling → settled`；旁路 `open → cancelled`（用户/父显式取消）；`open → expired`（deadline 到，仍走回写器产出 partial 报告后落 expired）。`settling` 为回写器执行中态：崩溃恢复扫描 `open|settling` 续判，memo 幂等键防重复回写（§3）。[推演]

### 4.3 mode 语义

| mode | settle 条件 | result 口径 | 任一成员失败时 |
|---|---|---|---|
| `all` | 全部成员到达终态（成功或失败） | 全部成功 = `settled` | 整体 outcome=`failed`，**仍等全部到位**（不短路：分身副作用已发生，等待比中途取消更可预期；deadline 兜底）；成功成员结论照供父参考 |
| `any` | 首个成员**成功**终态 | 首个成功者结论；残余处置见 §2.3 | 失败不计数；全部失败 + 超时 → `expired` |
| `allSettled` | 全部成员到达终态 | 逐成员终态数组（含失败明细），整体恒 `settled` | 失败成员标 failed 计入 settled_count（「失败也算完成」） |

[推演]：`all` 不短路的设计依据——fork 分身是独立副作用承载者，任一失败立刻取消其余会把「失败」放大成「部分完成 + 部分取消」的混合态，父 agent 更难推理；等全部到位后一次性给全貌，代价由 deadline 封顶。

---

## 5. 能力衰减（Q6 裁断）

> 实现状态（M4.2-WP1，#46）：`src/orchestration/fork/capability.cr` 的
> `Capability.resolve` 承载本节裁决——未声明 `tools` 走 §5.1 默认只读档
> （`memory.search` + `session.read`）；声明与父 `tools.allow` 求交集，`*`
> 即全允许；白名单外剔除项经 `Grant.removed` 在成员任务 payload 与 fork
> 回执（`tools_effective`/`tools_removed`）列明；生效清单注入分身 system
> prompt（`Available tools`）。secrets 不随分身由 provider 句柄共享保证（§5.3）。

### 5.1 默认只读档（未声明 `tools` 时生效）

| 能力 | 默认档 | 依据 |
|---|---|---|
| transcripts 窗口读取 | 有（快照已注入，运行期仅限读自己分身会话） | [来源: 仓库:src/platform/store/store.cr:406-417] |
| `memory.search` | 有（只读检索） | [来源: 仓库:src/tools/executor.cr:122-129] |
| `memory.save` | **无**（记忆库是共享写状态） | — |
| `message.send` | **无**（L2 网络写） | [来源: 仓库:src/platform/cli/gateway.cr:178-180] |
| 文件写 / 网络写 / 不可逆工具 | **无** | §2.1 |
| secrets（api_key 等） | **不携带**（§5.3） | — |
| fork 工具（递归） | **无**（§6 防递归） | — |
| skills / 角色卡注入 | 有（只读 prompt 内容） | [来源: 仓库:src/agents/skills/skills.cr:43-83] |

默认档 = 「只读分身」：M4.1 最小闭环的分身全在此档运行（提案 M1 门槛「只读分身」）。

### 5.2 生效能力 = fork 显式声明 ∩ 父 `tools.allow`

- 声明 `tools=["memory.search","file.write"]` → 生效集 = 该列表 ∩ 父 agent `tools.allow`。
- 父 `tools.allow=["*"]`（现状全局口径 [来源: 仓库:src/platform/config/schema.cr:104-107]）→ 视为全允许，生效集 = 声明全集。
- 声明中不在父白名单的工具**静默剔除并在回执中列明**（可观测，不静默失败）。[推演]
- L3 不可逆工具无论声明与否均叠加 §7 审批链（声明≠免审批）。

### 5.3 secrets 不随分身

> 实现状态（M4.2-WP4，#49）：配置明文 api_key 由 `GatewaySecrets#migrate_secrets`
> 迁 keys/ vault（EncryptedFileVault AES-256-GCM，主密钥 Windows Credential
> Manager / 降级 0600 master.key 文件）后经 setter 抹除内存配置树——运行期
> 配置树无明文凭据；迁移幂等可重跑（重跑时 api_key 已 nil，跳过 vault 写入
> 但仍从 vault 读取恢复凭据映射——provider 工厂注入不缺）。provider
> 工厂包装按 agent 实例身份注入 vault 解析 key（`wire_secret_factory`，
> `@agent_instances` 维护最新实例映射）——分身/父共用 provider 句柄，无凭据
> 直读路径（快照不含凭据字段断言既有）。vault 持久化加固：master.key 先读
> 后写 + mkdir 原子锁并发防护 + temp fsync → rename → 目录项 fsync 掉电安全
> 顺序 + 同步失败回滚。

- 现状 `AgentConfig.api_key` 明文过渡 [来源: 仓库:src/platform/config/schema.cr:92]；fork 快照**不含**任何凭据字段；分身 provider 调用走 `Providers::Pool.for_agent` 取共享实例——分身持有的是 provider 句柄而非凭据 [来源: 仓库:src/providers/pool.cr:12-25]。[推演]：句柄封装使分身无凭据直读路径。
- api_key 明文过渡收敛（迁 keyring）列入 M4.2 工作包（Q6 裁断：不留 M4.4）——排期文档承载。

---

## 6. 触发权与递归防护

### 6.1 触发权分阶段

| 阶段 | 允许的触发 | 依据 |
|---|---|---|
| M4.1 / M4.2 | 仅**用户显式**（IPC/HTTP 命令）+ **DSL 声明**（workflow action `tool: fork`）；不动生产 `agent_turn`（一次性 `provider.complete` + 固定 `message.send` 保持现状） | Q3 裁断；[来源: 仓库:src/platform/cli/gateway.cr:212-223] |
| M4.3 | 增加对话流内自然 fork：ReAct 工具循环落地后，LLM 经工具调用解析发起 fork——经 §5 衰减、§1.5 并发闸、§6.2 一级限制、§7 审批四重闸 | 提案 Q7（fork 是对话一等公民）；ReAct 循环是 M4.3 独立前置工作包 |

### 6.2 一级限制与防环（提案 :80/:99）

- **只允许一级 fork**：分身工具面**剔除 fork 工具**（§5.1 默认档已无；显式声明亦不接受 `fork` 声明——白名单校验直接拒绝，[推演]：在生效集计算处硬编码排除）。
- 禁 Agent 自主递归：分身不能派分身；分身内任何 fork 意图（prompt 层）只产生「建议父 fork」文本，不产生新任务。
- 防环旁证：collaboration max_hops=4 防环先例 [来源: 仓库:src/orchestration/collaboration/collaboration.cr:83-104]——fork 场景环=递归扇出，一级限制是最强形式（hops=1）。

---

## 7. 不可逆副作用：仅建议权 + Approvals::Center 接线

> 实现状态（M4.2-WP3，#48）：`Tools::Executor` 的 L3 不可逆门承载本节
> fail-closed——side_effect=Irreversible 工具执行前必经
> `Approvals::Center.request`（无审批装配一律拒绝 = 装配为零时 L3 不可达）；
> `ToolContext` 携 `approvals`/`unattended`（默认 true = 无人值守 deny，分身
> 固定）/`approval_mode`；批准执行的 decision reason 经 `Effect.approval`
> 随副作用清单回写进 join.report（凭证随 L1 回写）。生产装配：gateway 构造
> Center（先于 IPC）+ `approvals_center` setter；IPC 补齐 approvals.approve/
> deny（写命令认证强制）/approvals.pending（读匿名）。decide 拒绝 deadline
> 已过的批准（超时 deny 与人工 approve 竞态窗口内过期决策不生效）。

- 分身对 L3 不可逆操作**默认只有建议权**：工具执行前必经 `Approvals::Center.request` 批准，未批准不执行（fail-closed）。规则链现成：hardline deny > mode off > 无人值守 deny > memo 决策 > 超时 deny > 等待人工 [来源: 仓库:src/orchestration/approvals/approvals.cr:50-87]。
- hardline 地板已含 `"fork bomb"` 模式 [来源: 仓库:src/orchestration/approvals/approvals.cr:33-38]——fork 场景天然被地板覆盖。
- 接线语义：分身 ToolContext 携带 `unattended`（DSL 无人值守 run 默认 true → L3 自动 deny）/ `approval_mode`；人工双入口 `approve/deny` API 已有 [来源: 仓库:src/orchestration/approvals/approvals.cr:91-97]。**Center 生产装配与 IPC approve/deny 命令已于 M4.2-WP3 接线**（见本节顶部实现状态；M4.1 阶段装配为零、默认档无 L3 工具，自然安全）。

---

## 8. 与既有件的关系

### 8.1 已落地件：busy-interrupt-redirect（issue #28 已关，PR #31 已合）

本文**引用不重设计**：控制通道、协作式取消（双边界）、InterruptReceipt、降级表见 [busy-interrupt-redirect.md](busy-interrupt-redirect.md)。fork/join 复用其取消语义于三处：§2.2 取消列（父取消分身）、§2.3 any 模式残余分身取消、deadline 到期后的成员取消。分身取消是「协作式打断」的新调用方，协议不变。

### 8.2 在途件：调度（issue #9，Proposal 未实施 [来源: analysis.md §3.3]）

- **正交声明**：fork 分身不参与用户会话的 queue/debounce 归并；调度提案明言 subagent 扇出 steer 首版不开启 [来源: 仓库:docs/design/proposals/session-input-scheduling.md:210]。
- **迁就声明**（Q5 裁断）：fork 入队是调度**输入类型扩展**——分身无渠道入站消息、无 sender/peer，需新增 ForkEnvelope 输入类型走同一 admission（PR #32 已定型 policy/envelope/Store 单事务 admission）；M4.1 开工条件 = #9 WP1/WP2 已合或 admission/envelope 接口冻结。
- 顺序落位：同碰入队路径（gateway consume_bus）与 pool.cr 改造 [来源: 仓库:src/platform/cli/gateway.cr:260]——fork 轨全部在调度轨之后实施，接口迁就调度。

### 8.3 同名不同物声明

本仓 `ledger.cr` 是 append-only 事件账本+预算记账，**无 expectation** [来源: 仓库:src/orchestration/ledger.cr:18-24,43-59]；提案 :79 所引「agentos TaskLedger 期望机制」是外部先例（rsrs 1e4b0e4c：match 条件数组、mode all/any/all_settled、timeout_at）。本文 expectations 表是**按该先例语义在本仓新建**，不是复用本仓 ledger。[来源: analysis.md §3.2]

---

## 9. 成本透明与失败/部分失败语义

### 9.1 成本透明

- fork N 个分身 ≈ **N 倍上下文费**：每分身一次完整快照注入（transcripts 窗口 + system prompt + skills）+ 若干分身 turn（[positioning.md](fork-join-shadow-clone-positioning.md) :81）。
- 三道透明措施（[推演]）：①回执必含分身数 N 与快照行数（§1.4）；②回执给出粗估 token（快照行数 × 平均行长，标注估算口径）；③`join.report` 落父 transcript，费用随会话记录可审计。
- 上限防护：单次 N ≤ 并发闸（§1.5）；DSL 层 fork action 复用预算熔断（Budget.spend [来源: 仓库:src/orchestration/ledger.cr:43-59]）——fork 声明计入 run 预算。

### 9.2 失败 / 部分失败 / 超时

| 场景 | 语义 |
|---|---|
| 单分身失败 | `fail_task` 落库；不中断其他成员；`all` 下整体 outcome=failed（成功成员结论仍供父）；`allSettled` 下计入 settled_count |
| 全部失败 | `all`：expectation settle(result=failed)，L1 回写全部失败明细（父不盲等）；`allSettled`：正常 settle——失败计入 settled_count，整体仍 settled（§4.3）；`any`：不提前 settle——等 deadline 到期 → `expired`，全部失败明细回写（§4.3 any 行、§2.3 settle 判定补充） |
| 超时 | `expired`；已完成成员照常回写（partial）；未完成成员尽力取消（§2.2 超时列） |
| 部分取消 | any 模式残余处置（§2.3）；父显式取消走 §2.2 取消列 |
| 父崩溃恢复 | expectation 持久 → 重启扫描 open/settling 续判；回写幂等（§3 memo 键）；分身任务循 owner_task_id 找回先例 [来源: 仓库:src/agents/subagent.cr:31-38] |
| 分身崩溃循环 | 分身任务同受 restartLimit 防护 [来源: 仓库:src/platform/store/store.cr:21] |

---

## 10. 本文档验收口径（M4.0）

1. 评审通过（用户）= M4.0-WP1 定稿条件；纯文档包门禁（Q7）。
2. 矩阵自查：§2.2 四级 × 四时机 16 格逐格有策略；§2.3 any 残余分身处置有定义；§4.3 三 mode 任一失败路径有落点。
3. 与架构文档勾稽：session_key（§1.3）、expectations DDL（§4.1）、装配改造、DSL KNOWN_TOOLS 扩展在架构文档有对应组件落位。
4. 定稿后按既有流吸收进 design.md（§8 协作扩展 + §14 路线图延至 M4）——M4.0-WP2 工作包，非本文动作。

---

## 附：关键证据锚点（工部抽查复核 + 翰林报告转引）

| 断言 | 锚点 |
|---|---|
| gateway 生产装配无 orchestration 组件 | src/platform/cli/gateway.cr:40-65（工部复核） |
| agent_turn 一次性 complete、无工具循环 | src/platform/cli/gateway.cr:212-223（工部复核） |
| 入队键硬编码 "main" 与处理键不一致 | src/platform/cli/gateway.cr:260 vs :171（工部复核） |
| TaskRow 树字段 | src/platform/store/store.cr:23-25（工部复核） |
| SCHEMA 现有 11 表 | src/platform/store/store.cr:32-148（工部复核） |
| transcript 双写/读取挂点 | src/platform/store/store.cr:387-395 / :406-417（工部复核） |
| subagent 键先例 (agent_id,"internal","subagent",key) | src/agents/subagent.cr:44,56（工部复核） |
| approvals 规则链 + hardline 含 "fork bomb" | src/orchestration/approvals/approvals.cr:50-87 / :33-38（工部复核） |
| DSL KNOWN_TOOLS 白名单 | src/orchestration/dsl/dsl.cr:115（工部复核） |
| 调度四条门禁先例 | docs/design/proposals/session-input-scheduling.md:215（工部复核） |
| skills 注入挂点 | src/agents/skills/skills.cr:43-83（翰林核实） |
| tools.allow 全局口径 / api_key 明文过渡 | src/platform/config/schema.cr:104-107 / :92（翰林核实） |
| HttpProvider 纯消息接口 / provider 实例池 | src/providers/providers.cr:58-88 / src/providers/pool.cr:12-25（翰林核实） |
| Tool/ToolContext 现无子任务句柄 | src/tools/registry.cr:44-59（翰林核实） |
| collaboration max_hops 防环先例 | src/orchestration/collaboration/collaboration.cr:83-104（翰林核实） |
| IPC approvals 能力声明无命令 | src/admin/ipc/server.cr:187-215（翰林核实） |
| engine 串行无汇聚点 | src/orchestration/engine.cr:82-117（翰林核实） |

（完）
