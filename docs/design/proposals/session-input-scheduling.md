# 会话输入调度：持久 Busy Queue、Debounce 与 Steer（Proposal 契约）

> 状态：**Proposal**（2026-11-19 评审成稿，待实施；实现合入后由 WP6 回写为 implemented 并记录版本/PR）。
> Tracking：[issue #9](https://github.com/ShiningRay/sebas/issues/9) —— 执行进度、WP 拆分（#3–#8）与总体验收以 issue 为权威。
> 本文职责：调度层**唯一权威契约**（模型、配置、状态机、持久化、安全、恢复）；实施 WBS、逐阶段清单与测试矩阵在 issues，不复制进本文。契约变更一律先改本文走 PR，不散落在 issue 评论。

## 1. 背景与动机

- `src/agents/pool.cr` 已有内存 per-session FIFO：同会话保序、跨会话并行、有界 Channel 背压、全局并发上限——但进程重启即丢，且只是普通消息队列。
- webhook 每次 `Engine.start + spawn_run`，未经会话调度，同 hook 不保证串行；HTTP 管理面尚无 `/hooks/*` 接线。
- provider 仅一次性 `complete(messages)`，生产 agent 无工具循环 → 无可注入纠偏消息的安全边界。
- Store 已有 intents/tasks/transcripts/memos/ledger，但没有持久 pending queue、批次、成员关系与 steer 注入回执。
- Hermes busy 语义已核实并作为口径：queue=持久 FIFO 后续轮；steer=下一次工具结果边界注入；不可 steer 时降级 queue，未消费转后续轮。

## 2. 核心模型：queue/debounce 两态 + steer 正交开关

| 策略 | 语义 | 主要用途 |
|---|---|---|
| `queue` | 同会话 FIFO；新消息作为后续独立批次执行 | 兼容现有行为、确定性自动化（默认） |
| `debounce` | 等待短暂静默，将连续消息组成一批；有最大等待与批量上限 | 人类连续输入、外部消息 burst |
| `steer` | agent 忙时收集纠偏消息，在安全工具边界注入当前 turn | 不中断任务的补充与纠偏（正交开关，默认关） |

核心结论：

1. **queue 是持久排队基线，debounce 是批次形成策略，steer 是运行中纠偏通道**。前两者是同一维度 `batch_mode` 的两态；steer 是正交的 busy 输入选项，不是第三个互斥模式。全部共用持久输入与审计协议。
2. **默认 `batch_mode: queue`、`steer.enabled: false`**。人类会话可配置 debounce 并同时允许 steer；确定性 workflow 默认逐事件执行，显式声明才聚合。
3. **steer 不允许静默成功**：accepted ≠ injected；必须区分已接受、已注入、降级排队和拒绝；未赶上前一轮自动进入后续批次，不丢消息。
4. **停止、审批、授权等控制输入走独立通道**，绝不等待 debounce，也不与普通消息拼接。
5. 沿用单常驻 gateway 权威写入模型，不承诺跨进程分布式队列。

## 3. 配置与覆盖

### 3.1 层级与优先级

`GatewayConfig` 增加系统级 `gateway.session`，所有支持对话调度的 agent 共用；`AgentConfig.session` 只声明定向覆盖字段；webhook workflow `batch` 仅作用于该 workflow。首版不在 binding 增加第三层覆盖。

优先级固定：**内置安全默认值 → `gateway.session` → `agents.<name>.session` → `workflow.batch`**。嵌套对象按字段递归合并，标量/布尔/枚举整体覆盖；每次 admission 解析一次并保存策略快照。

### 3.2 配置示例

```yaml
gateway:
  session:
    batch_mode: queue             # 系统默认保持兼容；可切换为 debounce
    debounce:
      idle_ms: 1000
      max_wait_ms: 5000
      max_messages: 20
      max_bytes: 32768
      flush_on_turn_end: true
      group_by: sender
      max_active_buckets: 32
    queue:
      max_pending_batches: 32
      max_pending_bytes: 262144
    steer:
      enabled: false
      debounce_ms: 300
      max_pending_messages: 16
      max_wait_ms: 30000

agents:
  main:
    session:                      # 可选；只覆盖需要微调的字段，其余继承 gateway.session
      batch_mode: debounce
      steer:
        enabled: true

workflows:
  deploy-hook:
    trigger: { type: webhook, source: hooks/deploy }
    batch:                        # 仅该 workflow 生效
      mode: debounce
      idle_ms: 500
      max_wait_ms: 3000
      max_messages: 50
      max_bytes: 65536
```

### 3.3 参数微调契约

| 参数 | 系统默认值 | 允许范围 | 调整效果与约束 |
|---|---:|---:|---|
| `batch_mode` | `queue` | `queue/debounce` | 仅 debounce 启用等待与聚合；queue 忽略 debounce 定时器 |
| `debounce.idle_ms` | 1000 | 0–10000 | 允许 0 表示不等待静默（由 count/bytes/max_wait 封冻）；越大越聚合但响应越慢 |
| `debounce.max_wait_ms` | 5000 | 1–60000，且 >= idle_ms | 防止持续输入饥饿；不被新消息重置 |
| `debounce.max_messages` | 20 | 1–200 | 达到立即 seal；控制批次上下文规模 |
| `debounce.max_bytes` | 32768 | 256–1048576 | 原始 UTF-8 字节计量；单条自身超限明确拒绝 |
| `debounce.flush_on_turn_end` | true | boolean | true 时 busy turn 结束立即提交下一批，不再白等 idle |
| `debounce.group_by` | `sender` | `sender/session` | 默认隔离发送者；session 模式允许多人同批但不可丢署名/安全上下文 |
| `debounce.max_active_buckets` | 32 | 1–256 | 单 session 活跃桶上限，超限快速失败并计数 |
| `steer.debounce_ms` | 300 | 0–5000 | 运行中收集插话的短窗口；0 为立即进入 pending correction |
| `steer.max_pending_messages` | 16 | 1–100 | 运行中纠偏堆积上限，不得静默覆盖 |
| `steer.max_wait_ms` | 30000 | 1–300000，且 >= steer.debounce_ms | 超时未注入则转后续批次 |

参数属运行时调度数据，修改走现有「先验后换」热更新管线，不要求重启；schema 层再次硬校验，管理面不能只靠前端限制。

### 3.4 校验规则

- 数量/字节上限必须为正；普通 debounce `max_wait_ms` 必须为正、`idle_ms` 允许 0；`steer.debounce_ms` 允许 0；全部字段受 §3.3 硬范围约束。
- `batch_mode: debounce` 时校验完整 debounce 配置；`steer.enabled: true` 时校验完整 steer 配置；功能关闭时显式提供的字段仍需通过类型与范围校验，不保存潜伏的非法配置。
- `batch_mode: queue` 为缺省值；非法枚举拒绝加载，不静默回退。
- `steer.enabled: true` 不等于运行时一定能 steer；能力不可用必须走明确降级。

### 3.5 热更新生效边界

- 已 `sealed/queued/running` 批次与 active turn 永久沿用创建时策略快照，不 retroactive 改参数。
- `collecting` 批次默认沿用旧快照；新参数只作用于更新成功后新创建的批次，不重置 idle/max_wait 或批次归属。
- 操作者可显式 `flush`：按旧策略 seal 当前批次，新输入再形成新批次；不隐式 flush。
- `debounce → queue`：已 collecting 批次按原快照完成；`flush_on_policy_change: true` 为一次性管理操作，而非持久配置。
- 配置状态接口必须能展示默认值、覆盖值和最终 effective policy；参数修改不做自适应「智能调参」，所有变更留配置版本、操作者与审计记录。

## 4. 状态机与关键时序

### 4.1 状态定义

- Input：`accepted → batched → dispatched → done`，另有明确 `failed`。
- Batch：`collecting → sealed → queued → running → done/failed`。
- Steer：`accepted → injected`，或 `accepted → queued / expired / rejected`（附原因）。
- 「输入已接受」与「LLM 已看到」是两个状态，不得折叠为同一状态。

### 4.2 Admission 与 seal 时序

- Router 在 admission 前完成 agent/account/peer/session 解析；无 binding 按现有 fail-closed 丢弃并审计，不能先占队列。
- 新输入的去重、原文持久化、加入当前批次在**一个 SQLite 事务**内完成，成功后才对渠道 ACK。
- seal 操作与「创建下一 collecting 批次」原子化；seal 后新消息只能进入下一批。
- `batch_id` 由 session 与持久序号生成，不依赖拼接文本 hash；以本地持久接收序号保序，外部时间戳仅作元数据。

### 4.3 Debounce 批次形成

seal 条件（任一满足）：idle 到时（可被新输入重置）；max_wait 到时（不可重置）；达 `max_messages`；达 `max_bytes`；显式 flush；`flush_on_turn_end` 且前一批 running turn 已结束；shutdown/recovery 保守 seal。

- 聚合桶 = `session_key + sender/source + security_context`；同桶按接收序保序，跨桶由同一 session scheduler 按各桶首条输入接收序依次 seal/dispatch；活跃桶有硬上限，防伪造 sender 绕过限制。
- 给 LLM 的是带 sender、event type、时间边界的结构化批次；原始 envelope 永久可查，不只保存拼接文本。
- 空批次、重复事件、定时器重入和 seal/dispatch 竞态必须可测试且无副作用。

### 4.4 Steer 注入时序

- 只对已登记 `turn_id + generation` 的运行中 agent turn 开放；steer 先持久化，再入该 turn 的 pending correction 队列（`steer.debounce_ms` 短聚合 + `steer.max_wait_ms` 上限）。
- 来源须为明确 correction 语义（管理面 `sessions.steer` / 显式 `/steer` 命令）；普通聊天正文不依赖 LLM 或关键词猜测纠偏意图。
- **在工具结果已持久化、下一次 provider 调用之前 drain**；correction 作为独立用户/来源消息追加 transcript（附 turn/generation 元数据）；以原子状态迁移标记 injected 后才发布 injected 回执。
- 不在工具执行中途篡改参数，不取消正在运行的工具，不修改已完成的 phase。
- 崩溃若发生在注入边界：无法证明已进入上下文时保守转 queued 并记录 `unknown_not_injected`，不得伪报成功。
- 注入前 turn 结束、generation 不匹配、无可用工具边界、超过 `steer.max_wait_ms`：自动转 queued 后续批次；多条未消费 steer 按接收序组成一个后续批次，不覆盖旧消息。
- 压缩/session reset 等世代变化必须使旧 steer 失效转 queue，不能注入新世代；首版只 steer 父 turn；外部 webhook 默认 queue/debounce。

### 4.5 控制通道

- `/stop`、审批 approve/deny、安全撤销、授权与 reset 不进入普通 batch，不等待 idle/max wait；需独立权限校验、目标 generation 和审计。
- `/flush` 只 seal 当前发送者/来源有权限操作的 collecting batch，不越过队列优先权。
- 本期只提供 stop 的独立控制路径；redirect/cancel 工具语义不借 steer 名义隐式实现。

## 5. 持久化与恢复

### 5.1 存储表（版本化 migration）

1. `session_inputs`：原始 envelope、去重键、接收序号、状态、所属 batch。
2. `session_batches`：批次状态、策略快照、起止序号、时间窗、关联 turn/run、`seal_reason`（idle/max_wait/count/bytes/flush/shutdown/recovery）。
3. `session_batch_members`：`event_id` 唯一；`batch_id + position` 唯一。
4. `session_steers`：目标 turn/generation、payload、状态、注入位置和错误原因。

可复用现有 `intents/tasks/ledger`，但「输入已接受」与「LLM 已看到」不得折叠为同一状态。

### 5.2 重启与故障恢复

- `collecting`：立即按原策略快照 seal 并标记 `seal_reason: recovery`，不重新等待完整 debounce。
- `sealed/queued`：重新入队；`running`：按现有 task 恢复规则处理；结果不确定时沿用现有 fail-closed 口径，不得仅因 pending 存在就自动重放副作用。
- 已 accepted 未 injected 的 steer 在重启后转为 queued 后续批次并记录原因。
- 已完成批次不重跑；一批多事件共享 turn/run，审计可追溯全部成员。

## 6. 安全与可观测性

- 未知 hook、鉴权失败、超限、容量满：fail-closed 或返回可重试的明确错误；SQLite 写超时/饱和不得先 ACK 再补写；webhook 持久化后快速 202，异步执行，不长时间占用回调。
- 有界容量硬上限：`queue.max_pending_batches/max_pending_bytes` 与 `debounce.max_active_buckets`；超限明确拒绝并计数。
- 事件（`batch.*`、`steer.*`、`config.scheduling.*`）与指标（批次大小、静默/等待时长、降级次数、pending bytes、恢复批次数、超限拒绝数）可观测；事件流不是权威存储，管理面重连后以持久状态为准。
- 日志不记录未脱敏 payload 或凭据；IPC 与 HTTP 双入口语义一致；参数修改留配置版本/操作者/审计。

## 7. 模块落位与链路

| 模块 | 职责 |
|---|---|
| `src/sessions/scheduling/envelope.cr` | InputEnvelope / Batch / BatchMember / AdmissionReceipt / SteerReceipt / TurnLease |
| `src/sessions/scheduling/policy.cr` | 配置快照与纯函数校验 |
| `src/sessions/scheduling/scheduler.cr` | 每会话状态机、定时器、seal 与 dispatch（唯一会话调度权威） |
| `src/sessions/scheduling/registry.cr` | session scheduler 与 active turn registry |
| `src/sessions/scheduling/recovery.cr` | 启动恢复与 shutdown 行为 |
| `src/agents/pool.cr` | 保留跨会话 worker/并发限制；调度权威上移至 scheduler，避免双队列 |
| `src/platform/store/store.cr` | 四表 migration、事务 API、恢复查询 |
| `src/platform/config/{schema,loader}.cr` | session/batch 配置与热更新校验 |

- 普通消息链路：`Channel Adapter → Router（admission 前完成）→ Scheduler.admit → SQLite 事务成功后 ACK → queue/debounce seal → SessionWorker dispatch → AgentRuntime.run_turn → 发送/转录/task 完成`。
- webhook 链路：`POST /hooks/<name> + Idempotency-Key → 管理鉴权/来源验签 → 查 workflow 与策略 → 解析 hook session → 持久 admit → 202 + event_id/batch_id → scheduler 异步执行`。外部幂等键取代 `SHA1(payload + 当前时间)` 重试语义；同 hook 复用会话但每批独立 run，不同 hook 不串会话；确定性 workflow 默认一事件一 run，显式 batch 才进批量 dispatcher（run payload 记录 batch + 全部 event IDs）。
- Agent 工具循环：模型响应 → 工具调用 → 工具结果落库 → drain steer → 下一次模型调用；workflow action 之间的补充输入边界不自动等同 agent steer，需单独消费同一 correction 协议。

## 8. 非目标

- 不实现 Hermes 式 `interrupt/redirect`（另立变更，不把取消与纠偏混入本期）。
- 不用 LLM 判断「用户是否说完」；只用确定性时间/数量/字节/显式 flush 条件。
- 不对所有 workflow 默认合并事件；不改变 cron 每次运行独立会话语义。
- 不自动摘要或丢弃原始消息；超限/摘要是后续显式能力。
- 不承诺跨多 gateway 进程的分布式队列；沿用单常驻 gateway 权威写入模型。
- subagent 扇出 steer 首版不开启；复杂插件多文件/常驻 worker 属插件演进预案（[review/plugin-evolution.md](../review/plugin-evolution.md)），与本文无关。

## 9. 验收与门禁

- 总体验收清单见 [tracking issue #9](https://github.com/ShiningRay/sebas/issues/9)；逐 WP 目标/范围/验收见子卡 #3–#8。
- 必跑门禁：`make format-check` / `make spec` / `make lint` / `make release` 全绿，另附专项压力/故障注入与恢复测试证据；实现合入前不声称任何验收通过。
- 文档同步：实现行为与本文一致，偏差回写本文；本文标记 implemented 时记录版本与 PR。
