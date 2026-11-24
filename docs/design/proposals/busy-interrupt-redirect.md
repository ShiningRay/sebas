# Busy Interrupt / Redirect：运行中取消与重定向（Proposal）

> 状态：**Proposal**（评估与设计，2026-11-20；实现另行拆分，不在 #3–#8 调度实施内）。
> 关联：[tracking #9](https://github.com/ShiningRay/sebas/issues/9)、[#28](https://github.com/ShiningRay/sebas/issues/28)；调度契约见 [session-input-scheduling.md](session-input-scheduling.md)。
> 本文职责：定义 busy `interrupt`/`redirect` 的语义边界、回执协议、降级路径与控制通道整合方式；实现计划不写进本文。

## 1. 背景与定位

调度契约引入 `queue`（排队）、`debounce`（聚合）与 `steer`（工具边界纠偏注入）三种输入处理；Hermes 核实口径中还有第三种 busy 语义 `interrupt`（中止/重定向当前模型请求），在调度方案中显式列为非目标、另立变更——本文即该变更。

**核心定位：interrupt/redirect 是控制通道操作，不是输入模式。**

- `queue`/`steer` 的语义是「输入排队/纠偏」——不打断当前 turn 的生命周期。
- `interrupt`/`redirect` 的语义是「改变当前 turn 的生命周期」——与 `/stop` 同族（影响运行中 turn），要求**生效**而非等待；因此归入 §4.5 控制通道扩展，沿用其独立权限校验、目标 generation 与审计要求。

三种 busy 语义对照：

| 语义 | 对当前 turn | 对新输入 | 生效时机 |
|---|---|---|---|
| queue | 不打断 | 后续独立批次 | turn 结束后按 FIFO |
| steer | 不打断 | 工具边界注入 | 工具结果落库后、下次模型调用前 |
| **interrupt** | **中止剩余执行**（未开始的模型调用不再发起；已由飞行中响应返回、尚未启动的工具调用启动前复查并返回结构化 cancelled；已启动工具协作式结束） | —— | 模型调用边界 + 工具启动边界（协作式，见 §4） |
| **redirect** | **中止剩余执行** | 作为新 turn 输入优先执行 | 中止生效后 |

## 2. 语义定义

### 2.1 interrupt（中止）

- 目标是已登记 `turn_id + generation` 的运行中 turn；先持久化请求，再标记 turn 中止意图。
- **生效边界 = 模型调用边界 + 工具启动边界**：取消在下一次 provider 调用前应用（不等工具边界）；由飞行中模型响应已返回、**尚未启动的工具调用在启动前复查中断标记，不再启动**（写入结构化 `cancelled` 工具结果并落库，代理可见）；已启动的工具调用协作式结束、结果照常落库——与 steer 相反，interrupt 不需要安全注入点，它丢弃「尚未开始的执行」。
- 已完成并落库的工具结果保留；正在执行的工具调用**协作式取消**：宿主标记取消意图，工具自然结束并落库后生效，不强行终止正在运行的工具进程/调用（不篡改参数、不回滚已发生副作用——与 steer 同一条红线）。
- turn 以终态 `interrupted` 落账（task/ledger 审计可重放）；不自动重试，不静默改为其他行为。

### 2.2 redirect（重定向）

- **= interrupt + 新指令**：中止当前 turn（同 2.1），新指令持久化为独立输入事件（原始 envelope 保留），走正常 admission，并获得**队首插队位**——以接受时刻为准的固定顺序「R, 既有已排队批次（A…）, 此后新到批次（B…）」：R 排在所有已排队批次之前、所有后续新到批次之后；已 dispatch/running 的批次不受影响。
- 新 turn 使用新 `generation`；旧 turn 的未消费 pending steer 按世代规则失效转 queued，不注入新世代（沿用调度契约）。
- run/审计：新输入与新 turn 正常落账，旧 turn 终态 `interrupted` 附 `redirected_to: event_id`。

### 2.3 与 `/stop` 的关系

- `/stop`：取消并丢弃后续执行，无新输入（turn 终态 `stopped`）。
- `interrupt`：取消但保留已完成进度与审计（终态 `interrupted`）。
- `redirect`：interrupt + 注入新输入。
- 三者共用控制通道权限模型（§4.5）：独立权限校验、目标 generation、审计；审批/授权类操作仍走独立通道，不并入。

## 3. 回执协议

新增与 `SteerReceipt` 并列的 `InterruptReceipt`（复用其结构约定）：

- 状态：`accepted → cancelled | redirected`，或 `accepted → queued | rejected | expired`（附原因）。
- `accepted` ≠ 生效；`cancelled/redirected` 只在中止实际应用后原子标记发布（与 steer 的「注入后才发回执」同款纪律）。
- 持久化 `session_interrupts` 表（或并入 `session_steers` 同构表，迁移时定）；崩溃恢复口径与 steer 一致：无法证明已生效时保守降级，不伪报成功。

## 4. 降级路径（不允许静默成功）

| 情形 | 处置 |
|---|---|
| turn 未启动 / 已结束 | 降级 `queued` 后续批次（新输入不丢，按正常批次执行） |
| 活跃 subagent / session 压缩边界（generation 变化） | 降级 `queued`（Hermes 同款先例） |
| 长工具执行中（协作式取消未到边界） | 保持 `accepted`，工具自然结束后生效；超过 `interrupt.max_wait_ms`：**有新输入（redirect）→ 新指令降级 `queued`（不丢）**；**无新输入（纯 interrupt）→ 回执终态 `expired`（原因 `tool_not_ended`），turn 保持运行至自然结束——不取消、不伪造取消、不凭空造出「后续批次」** |
| 无效 generation / 无权限 | `rejected`，附原因 |

## 5. 与调度契约的整合点

- **调度层**：调度契约只增加「控制通道操作」的定义引用，queue/debounce/steer 语义不变；redirect 的「队列优先位」在 scheduler 中实现为受审计的显式插队，不改变普通输入的 FIFO 保证。
- **AgentRuntime（WP4 产物）**：循环顺序修订为「模型响应 → **检查 interrupt** → 逐个工具调用（每个启动前复查中断标记；未启动的写入结构化 `cancelled` 结果并落库）→ 工具结果落库 → 检查 interrupt（先于 steer）→ drain steer → 下一次模型调用」。interrupt 生效时：turn 终止/重定向，**pending steer 不标记 injected，而是按 steer 降级规则转后续批次**——严禁 steer 先被标注入、中断又阻止模型调用看到它（否则伪报 injected）。
- **中断与 steer 的同步边界**：所有会改变 turn 执行方向的操作纳入同一个 turn 临界区。drain steer 前先读一次中断标记，steer 追加进 transcript 后再读一次，且只有 provider 调用已登记为本轮下一个执行点时，才把该 steer 原子标记为 `injected`。第二次检查若发现 interrupt，已追加的 correction 保留在 transcript（历史不可改写），但该 steer **不得标记为 `injected`**——按降级规则转 queued 后续批次，回执明确 `not_consumed / interrupted`，说明它已进入记录但未随模型调用被消费。interrupt 在 drain 完成后、provider 调用前到达时，同样走这条回退路径。
- **禁止回执早于模型消费**：不能把「写入 transcript」当作「模型已看到」。`injected` 只表示该 correction 已包含在一次实际发起的 provider 调用输入中；调用因 interrupt 未发起时必须撤销 pending 标记并转 queued，不允许留下 `injected` 与 turn 终态并存的假成功记录。
- **保留的 correction 不得二次生效**：上一段保留进 transcript 的行必须带 `correction_key`（与 queued 批次里的同一条 steer 同一个键）。上下文组装读取历史 transcript 时**跳过已带 `correction_key` 且对应 steer 仍处于 queued 的行**——它会在后续批次入队时作为一次正常用户输入被投递，模型只看到一次。若该 queued 批次最终被丢弃或过期，则解除跳过，让它以历史记录身份生效一次（历史不可改写，但也不留永久空转的纠偏）。`injected` 的 steer 不写入 `correction_key`，因为它的可见性已由那次 provider 调用保证。
- **管理面**：`sessions.interrupt` / `sessions.redirect`（IPC + HTTP 双入口）、渠道显式 `/interrupt` / `/redirect` 命令（来源须明确控制语义，同 steer 的来源纪律）；事件 `interrupt.accepted/cancelled/redirected/queued/expired/rejected`（expired 为无输入 interrupt 的显式失败终态，订阅者可观察）。

## 6. 非目标

- 不实现「即时硬中断」：不终止正在运行的工具调用，不回滚已发生副作用（幂等/memo 保护不变）；硬性资源终止仍由 watchdog 管辖。
- 不重写已执行工具参数，不修改已完成 phase；不承诺 subagent 扇出（首版只作用于父 turn）。
- 不把普通聊天正文当 interrupt 信号（来源须明确控制语义，同 steer）。
- 实现与验收拆分为独立工作包（在调度 WP4 AgentRuntime 落地后启动），不在 #3–#8 内。

## 7. 验收（设计评审口径）

- [ ] 语义边界表（§1）与降级表（§4）经评审确认，无与调度契约（steer 降级、世代失效、控制通道）冲突
- [ ] 回执协议与崩溃恢复口径与 steer 同款（accepted ≠ 生效、不伪报）
- [ ] 实现拆分（工作包/估时）在评审通过后另立 issue
