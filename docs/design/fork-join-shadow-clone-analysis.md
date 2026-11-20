# Fork/Join 影分身定位提案 · 仓内现状与差距分析

> 翰林院编修 · 2026-11-20。依据首辅分派，对 `docs/design/proposals/fork-join-shadow-clone-positioning.md`（下称「提案」）做仓内现状与差距核实，供架构/方案/排期设计使用。本报告只述现状与差距，不做设计决策、不排期。所有结论均对码核实并附 `路径:行号`；未实测处标「未验证」。

## 0. 执行摘要（结论先行）

1. **提案兼容性表三行，一行半成立、一行不成立**：
   - per-session FIFO Pool「直接承接」：**数据结构层面成立，生产装配层面不成立**——Pool 及全部 orchestration/agents 组件在 gateway 生产链路零装配（详 §3.1）。
   - TaskLedger 期望机制「直接复用」：**不成立**——本仓 `ledger.cr` 是事件账本+预算记账，无任何 expectation/mode(all/any/allSettled) 概念；提案所引是 agentos 项目的先例，不是本仓现状（详 §3.2）。
   - 调度方案「正交无冲突」：**正交性成立**（调度提案明言 subagent 扇出 steer 首版不开启），但调度本身处于 Proposal 未实施状态，且与 fork 同碰入队路径与 Pool 改造，实施顺序需拍板（详 §3.3）。
2. **最大的隐藏欠账：orchestration 生产装配为零**。`Engine.new`/`TriggerManager.new`/`SubagentManager.new`/`AgentRegistry.new` 共 24 处引用全部位于 `dev/smoke/trig_probe.cr` 与 `spec/`；gateway 主链路（`src/platform/cli/gateway.cr:40-65`）不含任何 orchestration 组件。fork/join 无论按何种方案落地，都必须先补这道装配欠账，提案未提及。
3. **生产 agent 无工具循环**。`gateway.cr:212-223` 的 `agent_turn` 只做一次 `provider.complete(history)` + 固定 `message.send`，LLM 不产出工具调用。M1 若要求 LLM 自主调用 fork 工具需先建 ReAct 循环；M3「对话流内自然 Fork」以此为硬前置（调度提案 `session-input-scheduling.md:9-11` 亦自认「生产 agent 无工具循环」）。
4. **三轴定位与路线图错位**：轴①（弱 Session/常驻 Agent）在提案 M0.5–M4 路线图中无任何独立工作包；轴②（轻量创建）半成——`AgentRegistry.get_or_create` 建目录写 SOUL.md 已极轻量，但与 YAML `Config::AgentConfig` 双轨不打通；轴③（Fork/Join）是路线图主体，差距也最大。
5. **门禁命令存在两组口径**（§5），后续工作包应统一。
6. **CLAUDE.md 引用失效**：`development-plan.md:17` 所指「仓库 CLAUDE.md」在仓内不存在（递归搜索无果），现行权威为 `development-plan.md` B 条目 + `Makefile` + `.github/workflows/ci.yml`。

## 1. 仓与文档盘点

### 1.1 仓库顶层结构

单二进制 Crystal 项目（`shard.yml`、`src/main.cr` → `bin/sebas`）。顶层：`src/`（平台代码）、`spec/`（测试）、`docs/`（设计文档树）、`examples/`、`dev/smoke/`（冒烟探测脚本）、`Makefile`、`.github/workflows/{ci,dependency-check,release}.yml`。无 CLAUDE.md（§0.6）。

`src/` 模块划分（`design.md §13:861-902` 草案与实际一致）：`platform/{cli,config,bus,supervisor,store,keys}`、`channels/`、`routing/`、`agents/{pool,subagent,skills,agents}`、`orchestration/{dsl,engine,triggers,approvals,ledger,collaboration}`、`tools/{registry,executor}`、`providers/`、`admin/{ipc,http}`。

### 1.2 docs 树与各文档要点

| 文档 | 行数 | 内容概述 |
|---|---|---|
| `docs/design/design.md` | 1026 | 平台总设计：§3.3 session_key 五段键（:103）；§4.3 per-session worker 池（:219）；§6.1 会话 SQLite+JSONL 双写+compaction 设计（:341-342，**compaction 未实现**）；§7 幂等三件套/审批/DSL；§8 subagent=被拥有的会话（:490-491）；§9.2 管理面契约草案含 `POST /hooks/<name>`（:527）、approvals.approve/deny（:529）——**均未实现**；§11 热更新四正交件；§12 插件层；§14 路线图仅到 M3（:925-928），共同门禁「crystal spec + ./bin/ameba」（:932）；§15.2 架构风险（fiber 数量未压测 :956、SQLite 单写者 :958） |
| `docs/design/development-plan.md` | 423 | M0–M3 WBS 全记录。B.3 门禁第 3 条三命令（:317）；B.4–B.7 门禁结论 M0/M1/M2/M3-WP1/2/3 全绿（2026-11-19）；M3-WP4~6 插件层降级预研（Windows mruby 链接 blocker）；M3-WP3 subagent+信号量已验收（:247-253） |
| `docs/design/proposals/fork-join-shadow-clone-positioning.md` | 提案本体 | 三轴定位；兼容性表 :121-126；需新增 :127-133；路线图 M0.5–M4 :139-145；过渡语义 :147 |
| `docs/design/proposals/session-input-scheduling.md` | 216 | 状态 Proposal 待实施（:3，tracking issue #9）。四表 `session_inputs/session_batches/session_batch_members/session_steers`（:163-168）**未实施**；§7 调度权威上移 scheduler、`pool.cr` 保留跨会话 worker/并发限制（:195）；§8 非目标「subagent 扇出 steer 首版不开启」（:210） |
| `docs/design/review/*.md` | — | m0-gate.md（门禁三命令表 :42-46）、m1/m2/m3-gate.md、verification.md（三轮核验闭环）、m3-plugin-feasibility.md（插件 Windows blocker）、plugin-evolution.md、smoke-ex-w1-03.md（file_watcher/Atomic 冒烟） |

### 1.3 既有文档对 fork/join、session、agent 创建、TaskLedger 的约定

- **fork/join**：仓内任何文档此前无 fork/join 概念；本提案为首次引入。最接近的既有件是 subagent（`design.md §8.2:490-491`：「受限工具集、不能递归、不看主会话历史」——恰是 fork 要废除的「派员工」模式）。
- **session**：`design.md §3.3:103` session_key=`agent:<agent_id>:<account_id>:<channel_type>:<peer>`；§6.1 双写+working-set；**无 session 元数据表、无休眠/归档生命周期**。
- **agent 创建**：`design.md §13` 与 development-plan 未给「团队/模板」概念；现实现为目录+SOUL.md（§2.4）。
- **TaskLedger**：`design.md §7.4` 定义为「append-only 事件账本+预算记账」——与提案 :79 所引「agentos 的 TaskLedger 期望机制」同名不同物（§3.2）。

## 2. 核心模块现状（读码核实）

### 2.1 会话与执行链（gateway 生产链路）

| 项 | 现状 | 证据 |
|---|---|---|
| 装配链 | gateway 装配**不含** Engine/TriggerManager/AgentRegistry/SubagentManager/Pool 任何 orchestration 组件 | `src/platform/cli/gateway.cr:40-65` |
| 消息处理 | `process_message`：intent→Routing.resolve→append_transcript(user)→create_task("turn:...")→agent_turn→message.send→complete_task，单 turn 同步 | `gateway.cr:153-192` |
| LLM 调用 | `agent_turn` 一次性 `provider.complete(history)`+固定 message.send，**无工具循环** | `gateway.cr:212-223` |
| 历史窗口 | `transcripts(session_key).last(memory.window \|\| 50)` | `gateway.cr:214` |
| 入队分片键 | consume_bus 入队键硬编码 `"main"`，处理键却是 routed agent_name——**不一致** | `gateway.cr:260` vs `:171` |
| 崩溃恢复 | replay_unfinished | `gateway.cr:195-210` |

### 2.2 存储（src/platform/store/store.cr）

- SCHEMA 7 表：`intents/tasks/transcripts/memos/search(FTS5)/ledger/leases`（`store.cr:30-91`）。**无 sessions 元数据表、无 expectations 表、无调度四表**。
- `TaskRow(id,parent_id,kind,status,phase,restart_count,owner_task_id)`（`store.cr:21-23`）——`parent_id`/`owner_task_id` 现成可承载分身任务树。
- `append_transcript` SQLite+JSONL 双写（`store.cr:329-337`）；`transcripts(session_key)`（`:348-359`）——**join 全量回写与 fork 快照读取的现成挂点**。
- lease 家族（`store.cr:165-197`）、`DEFAULT_RESTART_LIMIT=5`（`:19`）、memo FWW（`:311-325`）。

### 2.3 orchestration 组件（全部未进生产链路）

| 组件 | 现状 | 证据 |
|---|---|---|
| `ledger.cr` | 仅 append/replay + `Budget.spend` 熔断；**无 expectation、无 mode** | `src/orchestration/ledger.cr:18-24,43-59` |
| `engine.cr` | 串行 execute_phases、memo 决策幂等、phase checkpoint；**无并行/fork-join 语义** | `src/orchestration/engine.cr:82-117` |
| `subagent.cr` | 「派员工」模式：独立 prompt、受限工具面、session_key=(agent_id,"internal","subagent",subtask_key)、DEFAULT_MAX_CONCURRENT=3、ownerTaskId 找回 | `src/agents/subagent.cr:16,23,31-56` |
| `triggers.cr` | cron/event/webhook/account 四触发；`fire_webhook` 仅定义+spec 调用，**HTTP 路由未接线** | `src/orchestration/triggers/triggers.cr:29-64`；`src/admin/http/server.cr:119-133` 无 `/hooks/<name>` |
| `approvals.cr` | Center.request 完备（超时/无人值守 deny、hardline 含 "fork bomb"）；**生产装配为零**，IPC caps 声明 approvals 但无 approve/deny 命令 | `src/orchestration/approvals/approvals.cr:33-97`；`src/admin/ipc/server.cr:187-215` |
| `dsl.cr` | KNOWN_TOOLS 白名单已含 `subagent.ask`，但 executor 未注册该工具（**未实现**） | `src/orchestration/dsl/dsl.cr:103,134-138`；`src/tools/executor.cr:122-129` |
| `collaboration.cr` | message_agent fire-and-forget+max_hops=4 防环，与 fork 正交 | `src/orchestration/collaboration/collaboration.cr:37-56,83-104` |

### 2.4 agents / providers / tools

- `agents.cr`：`AgentRegistry.get_or_create`=建目录写 SOUL.md（`src/agents/agents.cr:49-57`）——agent 创建已极轻量；**与 `Config::AgentConfig`(YAML, `src/platform/config/schema.cr:84-102`) 双轨不打通**（persona 文件 vs persona_file 字段、无 session/skills 字段、`tools.allow=["*"]` 全局口径 `:99-102`）。
- `pool.cr`：per-session Channel 队列+全局 Semaphore（max_concurrency=8/queue 16，`src/agents/pool.cr:40-92`）；session_key 五段键（`:11-12`）。
- `providers/pool.cr`：`for_agent(agent_id)` 实例缓存+热换（`src/providers/pool.cr:12-25`）——fork 分身取 provider 实例现成。
- `providers.cr`：`HttpProvider.complete(messages)` 纯消息数组接口（`src/providers/providers.cr:58-88`）——**fork 快照注入直接可用**。
- `registry.cr`：abstract Tool(name,description,replay,risk)、ToolContext(session_key,account_id,event_id,store)（`src/tools/registry.cr:44-59`）——**ToolContext 无 provider/子任务创建句柄，fork 工具需扩展**；redact 脱敏（`:86-98`）。
- `executor.cr`：default_registry 仅 4 工具 message.send/memory.search/memory.save/session.read（`src/tools/executor.cr:122-129`）。
- `skills.cr`：SKILL.md frontmatter→system prompt 注入（`src/agents/skills/skills.cr:43-83`）——**角色卡/人格 patch 现成挂点**。
- `admin/ipc/protocol.cr`：sebas.ipc v1、CAPABILITIES=[sessions.read,events.subscribe,approvals,config.status]（`protocol.cr:8-12`）。

## 3. 提案兼容性表逐行核实（提案 :121-126）

### 3.1 per-session FIFO Pool「✅ 直接承接」——**数据结构成立，生产装配不成立**

- 成立面：Pool 为 per-session 队列+全局并发闸（`pool.cr:40-92`），提案 :123「Fork 出去的 Agent 就是新 session」与现有分片模型吻合；分身作为新 session 的先例已有（subagent 用 `Agents.session_key(agent_id,"internal","subagent",subtask_key)`，`subagent.cr:44,56`），fork 可循此用 `"fork"` 维度建键。
- 不成立面 1（装配）：Pool/Engine/SubagentManager 生产链路零装配（§2.1、§0.2）。「直接承接」只在数据结构层面为真，**上线前必须补 gateway 装配改造**——提案未列此项。
- 不成立面 2（改造冲突）：调度提案 `session-input-scheduling.md:195` 明言调度权威将上移 scheduler、`pool.cr` 被改造为「跨会话 worker/并发限制」角色。fork 分身入队走 scheduler 时需要新的输入类型（fork 无渠道入站消息、无 sender/peer），提案未覆盖。
- 不成立面 3（键细节）：fork 分身没有 channel/peer，session_key 需要新约定（沿用 `internal` 段或新维度），影响 Pool 分片、transcripts 键、调度 admit 三处。

### 3.2 TaskLedger 期望机制「✅ 直接复用（Join 即 expectation 触发，mode all/any/allSettled）」——**不成立，需新建**

- 本仓 `ledger.cr` 实为 append-only 事件账本+预算熔断（`ledger.cr:18-59`），**无 expectation 概念、无 all/any/allSettled、无「任务完成通知父任务」机制**。提案 :79 所引是 agentos 项目先例（提案原文：「agentos 的 TaskLedger 期望机制」），与本仓同名组件不是一物。
- Join 落地需要新建：① expectation 持久化（store 新表，现有 7 表无此物，`store.cr:30-91`）；② 分身终态→expectation 判定→父任务推进的回调链（`engine.cr:82-117` 现为纯串行，无并行汇聚点）；③ mode 语义。可复用的只有任务树字段（`TaskRow.parent_id/owner_task_id`，`store.cr:21-23`）与 lease/memo 基础设施。

### 3.3 调度方案 queue/debounce/steer「✅ 正交无冲突」——**正交成立，两项补充**

- 正交成立：调度提案 :210 明言「subagent 扇出 steer 首版不开启」；steer 默认 `enabled=false`；fork 分身不参与用户会话的 queue/debounce 归并，语义上互不覆盖。
- 补充 1（未实施）：调度方案本身为 Proposal 待实施（`session-input-scheduling.md:3`，issue #9，四表未建）。「无冲突」是纸面对纸面的结论，两方案落地时同碰：入队路径（gateway consume_bus）、`pool.cr` 改造（:195）、store schema（调度四表 vs fork expectations 表）——**实施顺序需要拍板**。
- 补充 2（现存缺陷）：入队分片键硬编码 `"main"` 与处理键 routed agent_name 不一致（`gateway.cr:260` vs `:171`）——两方案都触碰此处，先修更稳。

## 4. M0.5→M4 各阶段差距清单（按提案 :139-145）

### M0.5 语义文档（fork-join-semantics.md）

- 需新建：语义矩阵文档（fork 输入、快照内容与边界、衰减默认、副作用权限分级、join 分层回写、失败/超时语义）。
- 现状差距：仓内零 fork/join 文档（§1.3）。纯文档工作，无代码挂点。本报告可作为其输入。

### M1+ 一级 Fork + 只读分身 + 全量摘要回写（三命令门禁绿）

| 类型 | 组件 | 挂点/证据 |
|---|---|---|
| 需新建 | fork 工具原语（Tool 子类，携上下文快照） | 挂 `src/tools/executor.cr:122-129` default_registry；**ToolContext 需扩展**（`registry.cr:44-48` 现无子任务创建/入队句柄；快照读取可用 `store.transcripts`，`store.cr:348-359`） |
| 需新建 | join 期望类型 | store 新表（SCHEMA 无，`store.cr:30-91`）+ 分身终态回调链；任务树复用 `TaskRow.parent_id/owner_task_id`（`store.cr:21-23`） |
| 需新建 | 分身 turn 执行体 | `HttpProvider.complete(messages)` 纯消息接口快照注入直接可用（`providers.cr:58-88`）；provider 实例取用现成（`providers/pool.cr:12-25`） |
| 需新建 | 分层 Join 回写器 | 结论+checkpoint 进主上下文、全量 transcript 落盘——`append_transcript` 双写现成（`store.cr:329-337`） |
| 需修改 | Engine 任务树登记、executor 注册表、DSL KNOWN_TOOLS（若 DSL 可声明 fork） | `engine.cr:82-117`；`executor.cr:122-129`；`dsl.cr:103` |
| **前置欠账** | **orchestration 生产装配** | Engine/Pool/SubagentManager 零装配（§0.2）——M1 必须先补，否则 fork 工具无执行链可挂 |
| 先例参考 | subagent 模式 | session_key `internal` 段（`subagent.cr:44`）、并发闸 DEFAULT_MAX_CONCURRENT=3（`:16`）、受限工具面注入（`:23`）——fork 的键格式/并发/衰减皆可循此改造 |

### M2 文件写 + 冲突处理 + 衰减（e2e）

- 需新建：**能力衰减声明机制**——现状 `tools.allow=["*"]` 是全局白名单（`schema.cr:99-102`），无 per-agent 衰减字段；衰减=父 agent 工具白名单交集或 fork 声明，需首辅定口径（§6 Q6）。
- 需新建：**secrets 注入策略**——现状 `AgentConfig.api_key` 明文过渡（`schema.cr:89`）；分身默认不应携带 secrets，需按 agent 注入+衰减矩阵。
- 需修改：审批接线——`Approvals::Center` 已完备（超时/无人值守 deny、hardline 已含 "fork bomb" 模式，`approvals.cr:33-97`），但**生产装配为零**且 IPC 无 approve/deny 命令（`ipc/server.cr:187-215`）；分身不可逆操作审批可复用此 Center。
- 冲突处理可复用：lease 家族（`store.cr:165-197`）、restartLimit=5（`:19`）、发信幂等键三明治（`executor.cr:29-72`）。

### M3 对话流内自然 Fork

- **最大改造点**：生产 agent 无工具循环（`gateway.cr:212-223` 一次性 complete+固定 message.send；调度提案 :9-11 自认）。「LLM 自主决定 fork」需要完整 ReAct 循环+工具调用解析+审批中继——这是从单次调用到工具循环的量级跃升，非增量改造。
- 正交可借鉴件：`message_agent` 工具+署名+max_hops=4 防环模式（`collaboration.cr:37-104`）——fork 一级限制的防环可循此。
- M3 依赖 M1/M2 全部件 + 衰减落地；提案把它排为「对话流内」语义，验收应含审批拦截实测（approvals Center 现成但需接线）。

### M4 团队模板库 + 角色卡 + 休眠归档回收

- 轴②半成：`AgentRegistry.get_or_create` 建目录写 SOUL.md 已极轻量（`agents.cr:49-57`）——「轻量创建」基础已在；**双轨不打通是主要差距**（AgentInstance 目录/SOUL.md vs `Config::AgentConfig` YAML，`schema.cr:84-102`；两套 persona、无引用校验）。模板库需先统一两轨，否则模板放哪边都只覆盖半仓。
- 角色卡挂点现成：SKILL.md frontmatter→system prompt（`skills.cr:43-83`）；模板库可挂 SKILL.md 或 SOUL.md 模板化，二选一需设计定夺。
- 轴①缺位最大：store 无 sessions 元数据表、无休眠/归档态（`store.cr:30-91`）；IPC `sessions.list/read` 只读 transcripts（`ipc/server.cr:187-215`）；「常驻 Agent 前台接待」无任何现成挂点（gateway process_message 与 routing binding 是渠道入站接待，非 agent 级接待）。**且提案 M0.5–M4 路线图无轴①独立工作包**——定位与排期错位，需拍板补工作包或明示并入 M4（§6 Q8）。
- 归档回收：transcript 无 TTL/归档机制；compaction 设计（`design.md:341-342`）未实现——休眠归档要么等 compaction，要么独立做，需设计定夺。

## 5. 门禁现状（三命令口径找到）

**现行权威三命令**（`development-plan.md:317` B.3 定义；`review/m0-gate.md:42-46` 实测记录）：

| 命令 | 口径 | 最近绿灯 |
|---|---|---|
| `crystal spec` | 0 failures | 2026-11-19（m0-gate.md:44 时点 52 examples） |
| `./bin/ameba` | 0 failures | 2026-11-19（m0-gate.md:45） |
| `make release` | bin/sebas 构建成功 | 2026-11-19（m0-gate.md:46） |

**CI 口径**（`.github/workflows/ci.yml` + `Makefile:41` `check: format-check spec lint` 自注「与 CI 对齐的三道门禁」）：`crystal tool format --check` + `crystal spec` + `make lint`（三平台 matrix），release-build 仅 main push；另有 `make drill`（M0-WP8 强杀演练，`Makefile:31-32`）。纯 docs 改动跳过 CI 门禁。

**第三口径**：调度提案 `session-input-scheduling.md:215` 要求四条全绿（make format-check/spec/lint/release）。

三组并存（三命令无 format / CI 四件含 release 但非 PR 门禁 / 调度四条全含）——后续 fork/join 工作包建议沿用 CI 口径为 PR 门禁+release 于交付节点（§6 Q7 拍板）。出处问题：`development-plan.md:17` 称门禁源于「仓库 CLAUDE.md」，**该文件仓内不存在**（递归搜索无果，引用失效）；design.md:932 同口径「crystal spec + ./bin/ameba」为现行书面权威。

## 6. 开放问题（设计前须首辅拍板）

| # | 问题 | 为何需拍板 |
|---|---|---|
| Q1 | fork 分身 session_key 格式：沿用 subagent `internal` 段先例，还是新维度 | 影响 Pool 分片、transcripts 键、调度 admit 三处；一旦落库迁移成本高（`subagent.cr:44` 先例） |
| Q2 | join expectation 落库形态：store 新表 vs 复用 tasks 表 kind 扩展 | 决定 SCHEMA 迁移幅度与 engine 改造量（`store.cr:30-91` 现无 expectations） |
| Q3 | M1 fork 触发路径：仅用户显式/DSL 声明（不动 agent_turn），还是直接建工具循环 | 前者工作量小、提案 :130 语义保守；后者一步到位但把 M3 前置——量级差异大（`gateway.cr:212-223` 现状） |
| Q4 | orchestration 装配欠账是否先做独立工作包 | 所有编排类功能（fork/join/调度/webhook 接线）共同前置；不做则每个方案都要自带装配，重复且易漏（§0.2） |
| Q5 | 实施顺序：调度（issue #9）vs fork/join 谁先 | 两方案同碰入队路径、pool.cr 改造、store schema（§3.3）；顺序决定谁迁就谁的接口 |
| Q6 | 能力衰减口径：白名单交集、显式声明还是两者结合；secrets 明文过渡（`schema.cr:89`）是否同期收敛 | M2 验收核心；口径不定则 spec 无法写（现状 `tools.allow=["*"]` `:99-102`） |
| Q7 | fork/join 工作包门禁用哪组口径：三命令 / CI 四件 / 调度四条 | 三组并存（§5）；排期文档需单一口径可验收 |
| Q8 | 轴①（弱 Session/常驻 Agent）在 M0.5–M4 无独立工作包——补工作包、并入 M4、还是明示降级为非目标 | 三轴定位是提案立论主体，路线图却不覆盖轴①，定位与排期错位需明示处理（§4 M4） |
| Q9 | `development-plan.md:17` 的 CLAUDE.md 失效引用与 `gateway.cr:260` 入队键不一致是否先修 | 均为小修但影响后续文档权威性与调度/fork 接口；修与不修影响排期内容 |

## 7. 未验证与诚实声明

- 本报告全部结论来自对 `src/`、`spec/`、`dev/smoke/`、`docs/`、`.github/` 的实际读取与 grep，未运行任何 `crystal spec`/构建命令——「门禁最近绿灯」引自 `review/m0-gate.md:42-46` 记录，非本次实测。
- 提案 :79 所引 agentos 项目未在本仓核对（属通政使旁证范围）。
- `design.md` §6.1 compaction「未实现」按 store/gateway 无对应代码判定；若计划中另有实现位置，此判定可复议。

（完）
