# Fork/Join 影分身架构（fork-join-shadow-clone-architecture）

> **状态**：Proposal · 待评审（与 [fork-join-semantics.md](fork-join-semantics.md) 同批过 M4.0 评审）
> **日期**：2026-11-20 · **作者**：工部尚书（受首辅分派）
> **职责**：本文回答「**怎么落位**」——三轴总体架构、fork/join 全数据流、装配欠账改造、与既有件勾稽、数据模型清单、定稿流声明。语义契约（矩阵/DDL 语义/衰减细则）以 semantics 文档为准，本文不重复论证。
> **证据纪律**：同 semantics 文档；`[推演]` 为架构新增判断。

---

## 1. 三轴总体架构

> 实现状态（M4.3-WP1，#50）：生产 `agent_turn`（gateway_dispatch.cr）已升为
> ReAct 工具循环——模型响应 → `Providers::ToolCallParser` 解析 ```json
> {"tool","args"}``` 块 → 衰减工具面（`tools.allow` 白名单过滤注册表）执行 →
> 结果回注 → 下一轮；轮数上限 `MAX_TOOL_ROUNDS=8`，超限强制索要终答；无工具
> 调用 = 终答（与 M0 现状一致的回归口径）；checkpoint 复用 task phase（每轮
> `checkpoint(round)`，崩溃重放从最后一轮续跑）。


三轴（[positioning.md](fork-join-shadow-clone-positioning.md)）：轴① 弱 Session / 常驻 Agent；轴② 轻量 Agent 团队；轴③ Fork/Join 影分身（主线）。

### 1.1 文本组件图

```text
用户（email/wecom/lark）──> channels/ ──> bus/
                                        │
                     gateway 装配层（§3 改造后）
                     ├── Routing/Rules（most-specific）
                     ├── [调度预留] session scheduler（issue #9 在途：admit/envelope/单事务）
                     │        ▲ fork 入队 = 新输入类型 ForkEnvelope（无 sender/peer）
                     ├── Pool（跨会话 worker + 全局并发闸；#9 落地后调度权威上移）
                     │
              ┌───────┴──────────────────────────────┐
              │ agent 执行体                            │
              │  M4.1–M4.2: 单 turn（provider.complete 一次性）│
              │  M4.3:  ReAct 工具循环（新增前置工作包）  │
              │     ├── fork 执行体 ForkManager          │
              │     │    快照组装 → expectations 登记     │
              │     │    → 分身任务树（tasks）→ 派发       │
              │     └── join 回写器 JoinWriter           │
              │          成员终态钩子 → mode 判定         │
              │          → L1/L2/L3 分层回写（§2 数据流） │
              ├── Approvals::Center（M4.2 接线：L3 审批链）
              └── 前台接待层（M4.3：匿名/临时会话包装，Session 藏而不删）
                        │
  store（SQLite WAL + JSONL 双写）
     调度四表落地后 store 现 11 表 + expectations（M4.1 新增表）+ sessions 元数据（M4.4 新增表）
                        │
  模板库与注册双轨（M4.4：AgentRegistry 目录/SOUL.md ⇄ Config::AgentConfig YAML 统一）
     └── 角色卡：SKILL.md frontmatter 挂点（src/agents/skills/skills.cr:43-83）
```

组件到期的里程碑：ForkManager/JoinWriter（M4.1）；审批接线与衰减执行面（M4.2）；ReAct 循环与前台接待（M4.3）；sessions 表/模板库/双轨统一/生命周期（M4.4）。

### 1.2 组件归属（design.md §13 目录对齐 [来源: analysis.md §1.1]）

| 新组件 | 落位 | 依据 |
|---|---|---|
| ForkManager（快照组装+任务树+派发） | `src/agents/fork/`（与 subagent 平级——同为「派生会话」族） | [推演]：subagent 落 `src/agents/subagent.cr` 先例 |
| JoinWriter（终态判定+分层回写） | `src/agents/fork/join_writer.cr` | 同上 |
| expectations 判定器（mode 聚合） | `src/agents/fork/expectation.cr`，读 store.tasks + expectations | [推演]：判定器无独立状态，薄层 |
| ReAct 工具循环 | `src/platform/cli/gateway.cr` agent_turn 改造（M4.3） | [来源: 仓库:src/platform/cli/gateway.cr:212-223] |
| 前台接待 | `src/agents/reception/`（M4.3） | [推演]：routing binding 是渠道级接待，接待层在其上做 agent 级包装 |
| sessions 生命周期 | `src/platform/store/store.cr` + `src/agents/lifecycle/`（M4.4） | [来源: analysis.md §4 M4 轴①] |

---

## 2. fork/join 全数据流（含 Q1/Q2 裁断落位）

十步数据流（编号与 semantics §1/§2/§3 契约对应）：

```text
 1. 触发        DSL workflow action（tool: fork）或 IPC/HTTP 显式命令
 2. 快照组装    store.transcripts(parent_session).last(window)     [store.cr:406-417]
               + system prompt（父 persona）+ skills 注入            [skills.cr:43-83]
               （不含 secrets，semantics §5.3）
 3. 登记        fork_id 生成（fork:<uuid 短码>）
               每分身一行 tasks：kind="fork_child"，
               parent_id=owner_task_id=父任务 id                    [store.cr:23-25]
               expectations 行插入（mode/deadline/members）           [semantics §4.1 DDL]
 4. 分身键      Agents.session_key(父agent_id, "internal", "fork", fork_id + ":" + member_index)
               成员键 = agent:<父>:internal:fork:<fork_id>:<member_index>   [Q1；subagent.cr:44 先例]
               （fork_id 标识一次 fork 调用，member_index 标识成员序号——成员级独立会话/transcript）
 5. 派发        分身 turn 入队：
               · #9 已合 → scheduler.admit(ForkEnvelope)（新输入类型：无渠道入站消息、
                 无 sender/peer；policy 走 fork 专用档）
               · #9 未合但接口冻结 → 按 ForkEnvelope 契约直连 Pool.enqueue（预留适配层）
               并发闸：fork 信号量默认 3                              [subagent.cr:16 先例]
 6. 分身执行    HttpProvider.complete(快照+task)                       [providers.cr:58-88]
               provider 实例：Providers::Pool.for_agent               [providers/pool.cr:12-25]
               能力面：默认只读档或 声明∩父 tools.allow               [semantics §5]
 7. 终态        complete_task / fail_task 落库 → JoinWriter 成员终态钩子
 8. 判定        expectation 判定器读 tasks.status 聚合，按 mode 判 settle
               [all/any/allSettled；any 残余处置 semantics §2.3]
 9. 分层回写    L1 join.report 进父会话 append_transcript              [store.cr:387-395]
               L2 分身全量 transcript 已在分身会话键下双写，无需搬运
               L3 成员索引（task_id/会话键/行数范围）随 L1 消息
               幂等：memo 键 join:<fork_id>:written                    [store.cr:369-383 先例]
10. 父续行      父会话下一 turn 的 transcripts 窗口自动带入 join.report
```

崩溃恢复：expectations 持久行 + 分身任务 owner_task_id 找回（subagent.cr:31-38 先例）+ 回写 memo 幂等 → 重启扫描 open/settling 续判（semantics §4.2 状态机）。

### 2.1 Q1/Q2 裁断落位摘要

- **键**：五段结构不动，channel_type 新增枚举 `"fork"`——影响三处（Pool 分片、transcripts 键、调度 admit），因沿 subagent "internal"/"subagent" 先例同构，均为「新枚举值」级改动，无迁移 [来源: analysis.md §3.1；仓库:src/agents/subagent.cr:44（工部复核）]。
- **表**：expectations 为 store 新增表（SCHEMA 数组追加一条 DDL [来源: 仓库:src/platform/store/store.cr:32-148]）；成员终态以 tasks.status 为单一事实源，expectations 不冗余成员态。

---

## 3. 装配欠账改造（Q4 裁断：全线前置，M4.1 首包）

### 3.1 现状（工部复核 [来源: 仓库:src/platform/cli/gateway.cr:40-65]）

gateway `initialize` 装配：Store / Bus / Channels::Registry / Providers::Pool / Tools::Executor(default_registry) / Rules / Pool(8,16) / Supervisor / ReloadManager / IPC / HTTP。**不含** Engine / TriggerManager / AgentRegistry / SubagentManager / Approvals::Center 任何 orchestration 组件——orchestration/agents 全部 24 处引用都在 dev/smoke 与 spec [来源: analysis.md §0.2]。

另一处现存缺陷：`consume_bus` 入队键硬编码 `"main"`（gateway.cr:260），处理键却是 routed `agent_name`（gateway.cr:171）——**不一致** [来源: 仓库:src/platform/cli/gateway.cr:260 vs :171（工部复核）]；调度（#9）与 fork 两方案都触碰此处，先修更稳 [来源: analysis.md §3.3]。

### 3.2 目标装配链（M4.1-WP1）

```text
initialize 现状链 …
  + AgentRegistry.new（agent 目录/persona 注册）                [agents.cr:49-57]
  + Approvals::Center.new(store)（装配即通，M4.1 默认档无 L3 不触发；M4.2 接线）
  + ForkManager.new(store, registry, providers_pool, approvals)（新组件 §1.2）
  + JoinWriter.new(store)（新组件）
  + 修 consume_bus：入队前 Routing.resolve → 入队 routed agent_name（消除 "main" 硬编码）
```

- Engine/TriggerManager 是否装配：M4.1 仅装配 fork/join 必需件；Engine 任务树登记在 M4.1-WP2 以「store 任务树写入」承载（不引入完整 workflow engine——DSL 声明的 fork action 由现有 DSL executor 路径派发）；TriggerManager/webhook HTTP 路由接线不在 M4 范围（维持 analysis.md §2.3 现状，另轨处理）。[推演]
- 装配验收：`crystal spec` 中以「gateway 生产链路 fork 冒烟」证明装配成立（M4.1-WP5 e2e），非仅组件单测。[推演]

---

## 4. 与既有件勾稽表

| 既有件 | 关系 | 处置 |
|---|---|---|
| **Pool**（per-session FIFO） | 数据结构承接 + 装配改造 | 数据结构层直接承接（分身=新 session 键分片 [来源: 仓库:src/agents/pool.cr:40-92；gateway.cr:243 Pool.new(8,16)（工部复核）]）；#9 落地后调度权威上移、Pool 改「跨会话 worker/并发限制」角色 [来源: 仓库:docs/design/proposals/session-input-scheduling.md:195]——fork 分身入队走调度 admit，Pool 不另设旁路 |
| **调度（issue #9）** | 正交 + 接口迁就 | 正交（steer 首版不开启 [:210]）；fork 迁就：ForkEnvelope 新输入类型（无 sender/peer），M4.1 开工条件 = #9 WP1/WP2 已合或 admission/envelope 接口冻结（PR #32 已定型 policy/envelope/Store 单事务 admission）；依赖列排期 E 节，不并卡 |
| **webhook DSL** | 扩展 | `KNOWN_TOOLS` 白名单加 `fork`/`join`（现为 message.send/memory.search/memory.save/session.read/subagent.ask [来源: 仓库:src/orchestration/dsl/dsl.cr:115（工部复核）]）；fork action 校验：count/mode/deadline 必填、tools 声明引用存在、fork/join 需 workflow 声明 [推演]；join 作为 DSL 动作 = 显式登记 expectation（§2 步骤 3 的 DSL 入口） |
| **approvals** | M4.2 接线 | Center 完备（超时/无人值守 deny、hardline 含 "fork bomb" [来源: 仓库:src/orchestration/approvals/approvals.cr:33-38,50-87（工部复核）]）；生产装配为零、IPC 无 approve/deny 命令 [来源: 仓库:src/admin/ipc/server.cr:187-215] → M4.2-WP3 装配+命令补齐（semantics §7） |
| **collaboration**（message_agent） | 正交 | fire-and-forget+署名+max_hops=4 防环 [来源: 仓库:src/orchestration/collaboration/collaboration.cr:37-56,83-104]；「找别的 agent」走 collaboration，「分自己」走 fork——两条正交通道并存，互不替代 |
| **subagent** | 对照保留（非替代） | 派员工 vs 影分身取舍：subagent = 独立 prompt + 受限工具 + 不看父历史 + 末条汇报（「派员工」，design.md §8.2 [来源: design.md §8.2]）；fork = 父快照 + 衰减工具 + 全过程回写（「分自己」）。**保留 subagent** 用于异人格/隔离子任务；fork 用于同人格并行。两机制共用 internal 段键先例与 Semaphore 并发闸（subagent.cr:16,44 先例）[推演] |
| **busy-interrupt-redirect（#28 已合）** | 复用取消语义 | 控制通道/协作式取消/InterruptReceipt 引用不重设计（semantics §8.1）；PR #31 已合，引用远端 main 路径 [busy-interrupt-redirect.md](busy-interrupt-redirect.md) |
| **Config::AgentConfig（YAML 轨）** | 双轨统一 | M4.4-WP1 已落地（#53）：`src/agents/agents.cr` `RegistryDualView` 双轨互查（snapshot 列出 config 定义 + 磁盘存量目录 [SOUL.md 已落盘]；`in_registry` 表示**已加载实例**而非磁盘在位）。`sync_config_agents` **仅同步 config 中定义的 agent**——其余磁盘存量保持只读可见不加载；存量 SOUL.md 不覆盖只读兼容不强制迁移；persona_file 悬空引用 loader 校验报错可读；AgentConfig 增 skills 字段（M4.4-WP2 消费前置）。模板落位定夺：SOUL.md=人格 / SKILL.md=技能 各司其职 |

---

## 5. 数据模型清单

| # | 表 | 引入期 | 用途 | 关键列 | 与既有表关系 |
|---|---|---|---|---|---|
| 8 | `expectations` | M4.1 | join 汇聚点（mode/deadline/members/状态机） | 详 semantics §4.1 DDL | `parent_task_id REFERENCES tasks(id)`（树锚点；members 为 tasks.id 数组；成员终态读 tasks.status 单一事实源） |
| 9 | `sessions` 元数据表 | M4.4 | 会话生命周期治理（轴①重） | 草案：`session_key PK / agent_id / kind(user\|fork\|subagent\|anonymous) / fork_id? / status(active\|dormant\|archived) / last_active_at / created_at / archived_path?` [推演] | 对 transcripts 按 session_key 聚合的元数据面；不外键 transcripts（历史行允许先于本表存在，回填口径 M4.4 定） |
| — | 调度四表（session_inputs/session_batches/session_batch_members/session_steers） | #9 在途 | 用户输入 queue/debounce/steer | — | **正交并列**：四表管「渠道入站输入归并」，expectations 管「fork 分身汇聚」，互不外键；fork 不入四表（分身非渠道输入，ForkEnvelope 为第五种派发路径）[推演] |

sessions 表落位依赖：IPC 现仅 sessions.list/read 只读 transcripts [来源: 仓库:src/admin/ipc/server.cr:187-215]；compaction（design.md §6.1）未实现 [来源: analysis.md §1.2]——休眠/归档不绑 compaction，独立先行（M4.4 裁断：不等、不绑）。[推演]

---

## 6. 定稿流声明（M4.0 工作包，非本轮动作）

- 本文与 [fork-join-semantics.md](fork-join-semantics.md) 经用户评审定稿后，按仓内既有文档流（research → proposals → **design.md 契约吸收** → development-plan 承接 → review 证据；插件 §12 与调度两例均为提案经 PR 合入后吸收进 design.md 的先例 [来源: .tmp-cabinet/tongzheng-conventions.md §四]）：
  - fork/join 契约吸收进 **design.md §8（协作扩展：fork/join 节）**；
  - 路线图延伸 **design.md §14 至 M4**（现行仅到 M3 [来源: analysis.md §1.2]）；
  - 吸收回写 + plan/00-baseline.md 第 0 节的失效引用修正（CLAUDE.md 不存在，改指 CONTRIBUTING.md 质量门禁节 + Makefile + .github/workflows/ci.yml 现行权威 [来源: analysis.md §5]）列 **M4.0-WP2**。
- 吸收动作为「文档工作包」，走 PR 评审（Q7 纯文档包门禁 = 评审通过）；本轮只交三文档，不做 git 操作（用户仅授权本地文档写作）。

---

## 附：与 semantics 文档的勾稽自查

| 架构组件 | semantics 节 |
|---|---|
| ForkManager 输入 | §1.1 字段表 / §1.2 快照边界 |
| 分身键（§2 步骤 4） | §1.3（Q1） |
| expectations 登记/判定（§2 步骤 3/8） | §4（Q2：DDL/状态机/mode） |
| JoinWriter（§2 步骤 9） | §2 矩阵 / §3 分层回写 |
| ForkEnvelope（§2 步骤 5） | §8.2 调度迁就声明 |
| Approvals 接线（§3.2/§4） | §7 建议权 |
| 前台接待（§1.1，M4.3） | —（轴①补位，验收在排期文档） |
| sessions 表（§5） | —（轴①治理，M4.4） |

（完）
