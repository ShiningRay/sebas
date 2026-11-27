# 对话式 TUI：TUI 作为新 channel 接入完整对话链路（Proposal）

> 状态：**Proposal**（2026-11-27 Maintainer 裁决路线 A + 范围扩充 M6，待评审）。
> Tracking：[#263](https://github.com/ShiningRay/sebas/issues/263)（WP 子卡 #264–#270）。
> 本文职责：定义对话式 TUI 的**契约**——架构定位、通道协议、UI 信息架构、后端事件扩展、控制命令入口、与既有调度/审批/审计纪律的关系。实施 WBS 见 [plan/wbs/m6-calendar-mirror.md](../plan/wbs/m6-calendar-mirror.md) M6.5 段。

## 1. 背景与动机

Sebas 当前的用户可见入口：

| 入口 | 形态 | 能否与 agent 对话 |
|---|---|---|
| CLI（`sebas gateway/version/crashwrite`） | 进程控制 | 否 |
| HTTP Admin（`/api/v1/*`） | JSON API | 否（无消息提交路由） |
| IPC Admin（`sessions.read/events.subscribe/...`） | NDJSON | 否（无消息提交命令） |
| TUI（`src/admin/tui/app.cr`） | 事件流监视器 | 否（无输入框，未接入 CLI） |
| Email channel | IMAP/SMTP | **是（唯一对话入口）** |

问题：

1. **本地无对话入口**——开发者想「跟 agent 说一句话」必须配真实邮箱（IMAP/SMTP/App Password），门槛过高；
2. **TUI 只读**——现有 `src/admin/tui/app.cr` 只打印事件流，连输入框都没有，且未挂到 `sebas` 子命令；
3. **多账号编排的对话体验未被验证**——email 是异步渠道，无法直观验证 debounce/steer/审批的实时交互。

目标用户（Maintainer 2026-11-27 裁决）：**本机操作者 + 远程终端用户两者都要**——本地开发自测 + 作为首个「非邮箱」对话渠道验证多账号编排。

## 2. 架构定位：TUI 作为新 channel（Maintainer 裁决路线 A）

新增 `channel_type="tui"` 的 channel，TUI 进程通过 IPC 与 gateway 通信。gateway 侧注册一个 `TuiChannelAdapter`（落地形态允许内联为 IPC server 内的 TuiBridge），职责：

- **入站**：IPC 收到 `tui.input {session_key, peer, content}` 帧后，服务端校验目标确为选中 TUI 会话，再包装为 `Bus::InboundMessage(channel_type: "tui", account_id: "local", peer: peer, content: content)` 推 bus → 走完整 Router → Scheduler → Pool → AgentRuntime；
- **出站**：agent 调 `message.send` → `TuiChannelAdapter.send(peer, content)` → IPC 推 `tui.output {peer, content}` 帧 → TUI 渲染。

```
┌──────┐  tui.input   ┌──────────────┐  InboundMessage  ┌─────┐  ┌─────────┐
│ TUI  │ ───────────► │ TuiChannel   │ ───────────────► │ Bus │─►│ Router  │
│Process│              │ Adapter      │                  │     │  │ Sched   │
│      │ ◄─────────── │ (gateway 内) │ ◄─────────────── │     │◄─│ Pool    │
└──────┘  tui.output  └──────────────┘   message.send    └─────┘  └─────────┘
```

**关键纪律**：TUI 与 email/telegram/slack **完全对等**，复用：

- binding 路由（`Routing::BindingRule` 增加 `channel: tui` 维度）；
- 持久 admission（`Scheduler.admit` 的 SQLite 事务）；
- debounce/steer（session-input-scheduling.md 全部语义）；
- L3 审批闸（`Approvals::Center`）；
- 审计 ledger（`store.ledger`）；
- 崩溃恢复（`store.recover!` + `Recovery.recover_stale`）；
- 幂等三件套（intents + memo + ledger）。

**零 binding 启动**：`sebas tui` 启动时先解析本机 `tui/local/<peer>` 的 binding。无 binding、目标 agent 不存在或配置无效时，给出明确错误 + 配置示例，**不创建空会话、不进入可输入状态**。默认 binding 的引导与 #145（初始安装配置引导）协同，不在本期范围。

**首个会话预登记**：binding 有效但会话列表没有该 peer 的 TUI 会话时，TUI 在发送第一条消息前调用认证写命令 `sessions.ensure {session_key, peer}`。服务端重新解析 binding，校验它与 `session_key` 的 agent/account/channel/peer 四段一致，然后调用 `Sessions::Lifecycle::Store#touch` 将 active 会话 upsert 到 `sessions` 表；该操作只预登记生命周期，不写 transcript、不创建 intent、不触发 agent turn。`sessions.list` 合并 `sessions` 表与既有 transcript 会话键并去重，因此空历史会话也能列出、选中并满足 §3.1 的输入契约。`sessions.ensure` 只支持 `local:tui` 目标，重复调用幂等，归档会话返回错误；不借它预建其他渠道会话。

## 3. IPC 协议扩展

在 `src/admin/ipc/protocol.cr` 的帧类型命名空间追加两类：

### 3.1 `tui.input`（TUI → gateway，写命令，需认证）

```json
{"type": "tui.input", "id": "...", "session_key": "agent:main:local:tui:operator", "peer": "operator", "content": "帮我看下昨天 cron 跑的结果"}
```

- `session_key`：**必填**，取 TUI 当前选中会话；服务端校验其五段结构中的 `account_id="local"` 且 `channel_type="tui"`，`peer` 段等于帧内 `peer`，且 `agent` 段等于按 `tui/local/peer` 实时解析出的 binding agent。校验失败返回 `error_response("tui.input requires the selected tui session")`，**不创建 intent、不入 bus**；binding 热换导致旧选中会话与新 agent 不一致时同样拒绝，TUI 提示重新选择/预登记会话。email/telegram 等会话只读，不能借 TUI 输入框跨渠道发言；
- `peer`：TUI 侧用户标识，默认 `"operator"`，多 TUI 实例可各起 peer 隔离会话；`session_key` 与 `peer` 同时发送是为显式绑定当前选中项，不是任选会话的旁路；
- `content`：原始输入文本；
- 响应：标准 `ok_response`，附 `event_id`（admission 接受后）或 `error_response`（目标非 TUI 会话 / 无 binding / 容量满 / 归档会话）。binding 仍按 `tui/local/peer` 解析 agent，`session_key` 不用于绕过路由指定 agent。

### 3.2 `tui.output`（gateway → TUI，推送帧）

```json
{"type": "tui.output", "peer": "operator", "content": "昨天的 cron 全部成功...", "event_id": "..."}
```

- 经 `EventTap.publish` 扇出到所有订阅了 `events.subscribe` 且 caps 含 `tui.subscribe` 的连接；
- 新增 capability：`tui.subscribe`（`IPC::CAPABILITIES` 追加）。

### 3.3 会话订阅复用 `events.subscribe`

TUI 的对话流增量更新走 `transcript.appended` 事件（见 §4.1），与 `tui.output` 的区别：

- `tui.output`：出站消息的**发送动作**事件（adapter.send 触发）；
- `transcript.appended`：**transcript 落库**事件（任何来源的 user/agent/tool 行）。

TUI 主区对话流订阅 `transcript.appended`；`tui.output` 主要用于跨 TUI 实例的同步（可选订阅）。

## 4. 后端事件扩展

### 4.1 `transcript.appended`（新增）

触发点：`Store#append_transcript` 成功提交后。

```json
{"type": "event.transcript.appended", "ts": "...", "payload": {
  "session_key": "agent:main:local:tui:operator",
  "cursor": 42,
  "role": "user|agent|tool",
  "content": "...",
  "created_at": "..."
}}
```

- `cursor` 直接取 `transcripts.id`（SQLite `INTEGER PRIMARY KEY AUTOINCREMENT`）；它是**提交后可查询、严格递增的持久游标**，不是 IPC 连接内的临时计数。`Store#append_transcript` 返回该行 id，DB 提交后再发布事件；`sessions.read` 的 entries 同步返回 `cursor`（对应 transcript id），支持 `after_cursor` 只取 `id > after_cursor` 的行并按 id 升序返回；
- 经 `@ipc.tap.publish(Admin::IPC.event_line("transcript.appended", ...))` 广播；
- **间隙检测**：TUI 为每个会话保存 `last_cursor`。首次加载、重连或切换会话时以 `sessions.read` 全量对账；增量帧仅当 `cursor > last_cursor` 时处理。收到 `cursor > last_cursor + 1` 不直接断言丢帧——其他会话的 transcript 也消耗全局 id——而是调 `sessions.read(session_key, after_cursor=last_cursor)` 补齐该会话缺段，再更新游标；
- **静默丢失最后一条事件**：不能依赖后续帧触发检测。TUI 每次发送/收到本会话输入回执后、周期性（建议 5 秒）以及 IPC 重连后都做轻量对账：`sessions.read(after_cursor=last_cursor)`，有新增行则按序补渲染；若客户端只看到部分旧历史，直接全量 `sessions.read` 后按 cursor 去重重绘。事件只是提示，SQLite transcript 才是权威；
- EventTap 满则丢弃策略不变。上述「持久游标 + 主动对账」只恢复 **transcript 状态**，覆盖 transcript 事件的队列丢弃、断线和最后一条静默丢失；审批待决状态按 §4.2 独立对账。

### 4.2 `approval.requested` / `approval.decided`（新增）

触发点：`Orchestration::Approvals::Center#request` 入口 / `#decide` 出口。

```json
{"type": "event.approval.requested", "ts": "...", "payload": {
  "id": "...", "tool": "...", "args_summary": "...", "run_id": "...", "deadline": "..."
}}
```

- **不得在持锁路径上同步 publish**——`Approvals::Center` 内部 Mutex 区域外发事件；
- TUI 收到 `approval.requested` 弹模态卡片，`y`/`n` 决策 → 已有 `approvals.approve/deny` 命令；
- **审批对账独立于 transcript**：TUI 启动、IPC 重连及与 transcript 同周期的 5 秒对账时都调用只读 `approvals.pending`，以服务端待决队列替换本地审批卡片集；新出现的 id 弹卡，已显示但不在 pending 中的 id 立即移除。`approval.requested/decided` 仅用于降低延迟，不作为可靠送达保证，队列丢弃或断线不会遗留永久等待的不可见审批。

## 5. 控制命令入口

### 5.1 `/steer`（复用）

已有 `GatewaySteer#handle_steer_command`（src/platform/cli/gateway_steer.cr）。TUI 输入框 `/steer <text>` → 走 `tui.input` 帧，content 原样带 `/steer ` 前缀 → gateway 现有路径接管，**TUI 不做本地解析**。

### 5.2 `/stop`（本期最小实现，Maintainer 裁决）

- 入口：`gateway.process_message` 在 `handle_steer_command` 之前增加 `handle_stop_command`；
- 语义：session 当前活跃 turn 标记终态 `stopped`（`TurnRegistry` 注入中断标记，下一次工具启动边界或 provider 调用前生效）；
- 回执：`ok_response` 附 `turn_id` + `status: stopped`；无活跃 turn 时返回 `error_response("no active turn")`；
- **与 busy-interrupt-redirect.md 的关系**：本期只落最小 `/stop`（无 redirect、无协作式工具取消、无 correction_key 去重）。完整 interrupt/redirect 语义留给那张卡。文档须写明偏差口径。

### 5.3 `/flush`（新增）

- 入口：`gateway.process_message` 增加 `handle_flush_command`；
- 语义：调 `Scheduler.flush_current_bucket(session_key, sender)`——按 session-input-scheduling.md §4.5「只 seal 当前发送者/来源有权限操作的 collecting batch」；
- 回执：`ok_response` 附 `sealed_batch_id` 或 `error_response("no collecting batch")`；
- `Scheduler#flush_all_buckets` 已存在但无入口，本包新增**单桶 flush** 方法（不接受「flush 全部」作为用户命令——越权风险）。

### 5.4 命令解析位置

**TUI 端零解析**：所有 `/xxx` 命令原样作为 `tui.input` 的 content 发送，由 gateway 在 `process_message` 入口统一识别。理由：

- 命令语义权威在服务端（与 email/telegram 同口径——记忆 1fbef2bf：当前所有聊天文本一律直送 LLM，本包首次引入对话层斜杠指令，必须双渠道同步生效）；
- TUI 只是渲染层，未来加新命令不改 TUI 前端。

## 6. UI 信息架构

```
┌─ Sebas TUI ──────────────────────────────────────────────────┐
│ Sessions (Tab 切换)      │ agent:main:local:tui:operator     │
│  ▸ main/local/operator   │ ──────────────────────────────── │
│    main/email/foo        │ [user]  帮我看下昨天 cron 跑的结果 │
│    reception/*           │ [agent] 昨天的 cron 全部成功...    │
│    telegram/bar          │ [tool]  session.read(...)         │
│                          │ [agent] 需要我继续做什么吗？        │
│ ────────────────────────│ ──────────────────────────────── │
│ Events (Ctrl-E 展开)     │ > _                               │
│  batch.sealed...         │                                   │
└──────────────────────────┴───────────────────────────────────┘
```

### 6.1 布局

- **左栏会话列表**（宽 24 列，可 `Tab` 隐藏）：从 `sessions.list` / `sessions.lifecycle` 拉取，按 `last_active_at` 倒序；选中切换主区。启动时若当前 peer 尚无 TUI 会话且 binding 有效，经 §2 的 `sessions.ensure` 预登记后选中；binding 无效则保持只读并显示配置引导。
- **主区对话流**：从 `sessions.read` 拉历史 transcript（首屏最近 50 行，向上滚动分页）；新消息通过 `transcript.appended` 事件增量推送。
- **底部输入框**（高 3 行）：仅对选中的 `agent:*:local:tui:*` 会话可编辑，发送时带该 `session_key`；选中 email/telegram 等会话时显示「只读：不能从 TUI 向其他渠道会话发言」，禁用发送。Enter 发送；`/steer` `/stop` `/flush` 由服务端解析；`Ctrl-C` 清空当前输入，`q`（输入框空时）退出 TUI。
- **审批弹层**：模态卡片覆盖主区，显示 tool/args_summary/deadline，`y` 批准 / `n` 拒绝 / `Esc` 稍后决策。
- **事件流尾栏**：默认折叠，`Ctrl-E` 展开看最近 N 条 `batch.*` / `steer.*` / `account.*` 事件。

### 6.2 终端渲染层选型

延续自写路线（记忆 cab59f2d：Crysterm AGPL 不可用，crystal_tui 生态小）：

- ANSI 转义 + 原始终端模式（`stty raw -echo`，Windows 用 `SetConsoleMode`）；
- 输入框读字符循环 + 光标管理（左右移动、删除、Home/End）；
- 对话流维护行缓冲 + 视口偏移（PgUp/PgDn 翻页）；
- **不引入外部依赖**，避免新 license 风险。

若评审认为自写成本过高，备选：crystal_tui（MIT）。**不推荐** ratatui FFI（过重）。

## 7. 非目标

- 不做 Web UI（复用 HTTP API，另立卡）；
- 不做多窗口/分屏；
- 不做 markdown 渲染（首版纯文本，代码块 ANSI 高亮留后续）；
- 不做 mouse 支持；
- 不动 busy interrupt/redirect 语义（另有 [busy-interrupt-redirect.md](busy-interrupt-redirect.md) proposal）；
- 不做 `/stop` 的完整 interrupt 语义（本期只最小实现，见 §5.2）；
- 不做从 TUI 向 email/telegram 等其他渠道会话代发消息（那些会话只读；跨渠道发言须另立带身份与授权契约的提案）；
- 不做 TUI 多用户认证（首版本机回环 + IPC token，与现有管理面同口径）。

## 8. 验收（设计评审口径）

- [ ] 路线 A 的 channel 抽象与 IPC 协议扩展经评审确认；
- [ ] `transcript.appended` / `approval.requested/decided` 事件契约明确；
- [ ] `/stop` 最小实现与 busy-interrupt-redirect.md 的等价/偏差口径写明；
- [ ] `/flush` 单桶语义明确（不做 flush_all）；
- [ ] TUI 端零命令解析的设计经评审确认；
- [ ] 端到端验收清单（WBS M6.5-WP7）评审通过。

## 9. 与既有文档的关系

- **调度契约**：[session-input-scheduling.md](session-input-scheduling.md) §4.5 控制通道——本包首次落地 `/stop` `/flush` 用户入口；
- **busy interrupt/redirect**：[busy-interrupt-redirect.md](busy-interrupt-redirect.md)——本包 `/stop` 是最小实现，不动该 proposal 的 interrupt/redirect 语义；
- **管理面协议**：[spec/09-admin-protocol.md](../spec/09-admin-protocol.md) §9.2 契约草案——本包新增 `tui.input` / `tui.output` / `transcript.appended` / `approval.requested/decided` 五类帧，需回写该节；
- **渠道抽象**：[spec/05-multi-account.md](../spec/05-multi-account.md) §5.1——`channel_type=tui` 纳入渠道枚举；
- **路线图**：[spec/14-roadmap.md](../spec/14-roadmap.md)——M6 期验收条目追加「对话式 TUI 全链路」。

## 10. 风险

1. **Transcript 事件粒度**：高频事件可能撑爆 tap 订阅者队列——TUI 端以 transcript id 为持久游标，主动对账并整段重拉，不把事件流当权威（见 §4.1）；
2. **审批事件源**：`Approvals::Center#request` 是同步等待决策——事件推送必须在 Mutex 外发，避免阻塞决策路径；
3. **会话列表规模**：`sessions.list` 全量返回，量大时需分页——本期先全量拉 + 客户端排序，量级失控再优化；
4. **TUI 与 gateway 同机假设**：IPC 明文 TCP 只允许回环绑定，远程场景需 SSH 端口转发——文档写明；
5. **M6 范围扩充的连锁影响**：M6 原估 20–34 pd，加 6–9 pd 后 26–43 pd，发版节奏后延——development-plan.md / roadmap / milestone 描述同步改写。
