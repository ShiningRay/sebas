# design.md §8 多 Agent 协作

> 导航：[设计总览](../design.md) ｜ [文档索引](../README.md) ｜ 上一节：[§7](07-orchestration.md) ｜ 下一节：[§9](09-admin-protocol.md)

## 8. 多 Agent 协作

### 8.1 Agent 间消息（防环三件套，参数化照抄 Hermes §4.3）

- 工具 `message_agent(agent_id, content)`：**fire-and-forget**——发送方收 `ack=queued + delivery_id`，对方完成后带回复通知。
- **署名**：消息自动带前缀 `Message from 🤖 <agent_id>:`，收方知道来源。
- **防环上限**（配置项 `bot_loop_guard.max_hops`，默认 4）：一轮交换内 agent-to-agent 传递上限，超过拒发——防 agent 互发死循环。
- **回复默认不可再被回复**（`expect_reply=false`）：单向通知不产生回声链。

### 8.2 subagent（并行执行单元）

- subagent = **被拥有的会话/任务**（Pi §3：工具在 commit 内创建 ownership 子会话，崩溃重跑经 ownerTaskId 找回同一个）。
- 受限工具集：剔除 message/spawn 等社交工具、不能递归、不看主会话历史（autobot §8 现成先例：`create_subagent_registry`）。
- 结果以系统消息回注发起方的下一 turn（autobot `announce_result` 模式），但**不再依赖全局单 Loop**——直接投递到该 agent 的会话 worker（B3 修复）。

### 8.3 并发上限（信号量）

- autobot 教训 B8：`agent/subagent.cr:83-85` 每任务一 fiber、零信号量，多账号场景放大成资源失控。
- 本平台：subagent 并发用**命名信号量**（semaphore pool）约束，默认 `max_concurrent = 3`（可配；autobot 曾提议同值未实现）；workflow 可用 `max_concurrent_key` 共享同一个信号量（如「最多 2 个并发摘要任务」）。
- agent turn 的 worker 池同样有全局上限；请求超上限进入每会话队列排队（不丢弃、不饿死：队列按会话分片）。

### 8.4 fork / join 影分身（契约摘要）

> 本节是 fork/join 契约的**设计层摘要**；完整语义（输入字段、Join 矩阵逐格策略、expectations 状态机、失败/部分失败细则）见 [proposals/fork-join-semantics.md](../proposals/fork-join-semantics.md)（M4.0-WP1 定稿，九问裁断 Q1–Q9 全落实），架构落位见 [fork-join-shadow-clone-architecture.md](../proposals/fork-join-shadow-clone-architecture.md)。

**fork 原语**：从父会话快照派生 N 个并行分身（N=1 合法），父 agent 等待汇聚（join）。快照 = 父会话 transcripts 窗口 + system prompt + skills 注入的只读拷贝；**不含 secrets、不含在途消息、不含其他会话内容**。

- **分身键（五段结构不动，成员级独立）**：`agent:<父agent_id>:internal:fork:<fork_id>:<member_index>`——与 subagent 的 `(agent_id, "internal", "subagent", key)` 同构（channel_type 枚举值不同）；fork_id 标识一次 fork 调用、member_index 标识同次内的成员序号，**成员各自独立会话与 transcript**（分层回写按成员记录 session/行数范围的前提）；Pool 分片、transcripts 键、调度 admission 三处复用现有机制。每个分身一行 tasks（`kind="fork_child"`、`parent_id=owner_task_id=父任务 id`），复用现有任务树字段。
- **expectations 表（join 汇聚点）**：store 新增表承载 mode（`all`/`any`/`allSettled`）、deadline、成员列表与状态机 `open → settling → settled`（旁路 `cancelled`/`expired`）；成员终态不冗余，判定器读 tasks 聚合（单一事实源）。持久化保证父崩溃恢复续判，回写以 memo 键 `join:<fork_id>:written` 幂等。**落位**（M4.1-WP2）：DDL 与读写方法在 `store`（`expectations` 表 + `expectations_store.cr`），判定器/恢复扫描在 `Orchestration::Fork::Expectations`（`any` 的 result 取 tasks.updated_at 最早的先成功成员——成功先后唯一可持久化证据）。
- **Join 语义矩阵**：分身副作用按工具注册表 `risk` 字段分四级（L0 只读 / L1 文件写 / L2 网络写 / L3 不可逆），× Join 时机（正常/超时/失败/取消）16 格逐格有策略。三通则：①副作用已发生不隐瞒（清单必回写）；②文件冲突**不自动 merge**，列入父裁决清单（CONFLICT）；③不完整回写必带 `partial` 成员终态标注。回写分三层：L1 结构化结论进父上下文、L2 全量 transcript 落分身会话（引用不搬运）、L3 可检索三元组索引。
- **能力衰减（默认只读）**：未声明 `tools` 的分身运行在默认只读档（无写副作用工具、不携带 secrets、无 fork 工具）；显式声明时生效集 = 声明 ∩ 父 `tools.allow`，越界声明静默剔除并在回执列明。L3 不可逆操作无论声明与否均叠加 Approvals::Center 审批链（声明≠免审批，fail-closed）。
- **触发权与防递归**：M4.1/M4.2 仅用户显式命令 + DSL 声明，不动生产 `agent_turn`；对话流内自然 fork 属 M4.3（前置 ReAct 工具循环工作包）。**只允许一级 fork**——分身工具面剔除 fork 工具，防递归扇出（collaboration max_hops 防环先例的最强形式）。
- **成本透明**：fork N 分身 ≈ N 倍上下文费；回执必含分身数与快照行数，`join.report` 落父 transcript 可审计；DSL fork 计入 run 预算熔断。

与既有件的关系：分身取消复用 busy-interrupt-redirect 协作式取消语义（§8.2 已落地件，协议不变）；fork 入队是调度（§7.2）的**输入类型扩展**（ForkEnvelope 走同一 admission），fork 轨全部在调度轨之后实施、接口迁就调度。
