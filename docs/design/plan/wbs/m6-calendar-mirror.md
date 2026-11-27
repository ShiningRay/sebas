# development-plan M6 · 外部日历/TODO 只读镜像与变化驱动重估 + 对话式 TUI（26–43 pd）

> 导航：[设计总览](../../design.md) ｜ [文档索引](../../README.md) ｜ [计划总览](../../development-plan.md) ｜ 上一节：[M5](m5-commitments.md) ｜ 下一节：[M7](m7-projection.md)

### M6 · 外部日历/TODO 只读镜像与变化驱动重估 + 对话式 TUI——估时合计 26–43 pd（2026-11-20 追加，2026-11-27 范围扩充，v0.4.0）

> 依据：[proposals/commitments-calendar-integration.md](../../proposals/commitments-calendar-integration.md) §6–§7、§9 首闭环第 3 条（日历部分）+ [proposals/tui-conversational-console.md](../../proposals/tui-conversational-console.md)（TUI 部分，2026-11-27 Maintainer 裁决路线 A 全入 M6）。
> 期定位：**只读镜像与观察（接入深度 1）+ 显式关联（深度 2）**（日历部分，不做复制、不做双向，深度 3 归 M7）+ **本地对话入口 TUI**（channel_type="tui" 与 email/telegram 对等）。
> 期门禁：调度四条全绿；每 provider 必须有「真机 round-trip + 原文保留」证据（日历部分），未实测的 provider 不得计入验收（提案 §9「必须验证的边界」第 6 条）；TUI 部分以端到端手动验收 + spec 全绿替代真机验收（本机渠道无外部依赖）。
> 反蔓延硬约束：canonical superset + adapter，**不做最低公分母双向同步**；JMAP Calendars 不进首期（提案 §7.4）；TUI 不做完整 interrupt/redirect 语义（留给 [busy-interrupt-redirect.md](../../proposals/busy-interrupt-redirect.md)）。

**M6.0-WP1 适配器契约、同步元数据与能力矩阵定稿**（1–2 pd）
- 目标：三 provider 共用一个契约，差异落在矩阵而非分支。
- 范围：适配器接口（列集合/取页/取增量/能力探测/保原文）；同步元数据六类（provider+account+collection / resource id+href / UID+series+original recurrence key / ETag·changeKey·sequence·updated / sync-token·syncToken·deltaLink+时间窗 / watch-subscription id+expiration）[来源: 提案 §7.4]；能力矩阵模板（VEVENT/VTODO/VALARM/重复/条件写/通知），每格三值「支持/不支持/不宣称」；失败语义 `stale/conflicted/partial_failure/unknown` 与隐私档（跨账户仅 busy）[来源: 提案 §6.4]。
- 交付物：契约文档（`docs/design/proposals/calendar-adapter-contract.md`）。
- 依赖：M5.4 门禁。
- 验收：评审通过；三 provider 在矩阵上无「假设支持」空格；每个不宣称项写明后果。
- 风险：契约写得过宽会诱导双向同步——接口只暴露读与条件写探测，不暴露全字段写。[推演]

**M6.1-WP1 ExternalLink/同步元数据表与仓储**（2–3 pd）
- 目标：外部对象在 Sebas 侧的身份、版本与游标可存可查。
- 范围：ExternalLink 表（内部对象 ↔ 外部资源、来源、权限、同步方向、最后对账结果）；同步元数据列按 M6.0 六类；原始载荷本地留存（不依赖远端回取）；迁移接 M5.1-WP1 迁移器。
- 交付物：表 + 仓储 + 约束 spec。
- 依赖：M5.0-WP2（迁移契约）、M6.0-WP1。
- 验收：同一外部对象重复 upsert 不产生第二行；游标与资源版本分列存储，互不覆盖；原文可完整重放解析。
- 风险：ID 归并诱惑（UID/iCalUID 当主键）——按提案 §7.1 明确「UID 不作跨平台主键」，复合键强制。[推演]

**M6.1-WP2 增量同步引擎骨架与对账**（3–5 pd）
- 目标：全量→增量→对账三段可靠，游标只在完整一轮后前推。
- 范围：首次全量、后续增量；分页未完成不前推游标；`410`/`deltaLink` 失效按范围全量重建；漏通知/订阅失效用增量对账；短时批量变化合并为一次评估；同步结果只落镜像，不改关联 Commitment（评估归 M6.3）[来源: 提案 §6.3、§7.2–§7.3]。
- 交付物：同步引擎 + 假 provider 契约测试（含 410/部分失败/重复页）。
- 依赖：M6.1-WP1。
- 验收：中途 kill 后重启不重复入库且游标不前推；410 触发全量重建且旧游标清除；部分失败标 `partial_failure`。
- 风险：游标语义各家不同（sync-token vs deltaLink vs syncToken）——引擎只认「不透明游标 + 作用域」二元组。[推演]

**M6.2-WP1 CalDAV 适配器**（3–5 pd）
- 目标：iCalendar/CalDAV 语义底座可用（RFC 5545/4791/6578）。
- 范围：集合探测（VEVENT/VTODO/VALARM/sync）；主重复组件与例外同资源处理，不按展开实例分别 PUT；ETag 条件写；完整 ICS 与未知 IANA/X- 属性全保留；`UID + RECURRENCE-ID` 定位系列内实例 [来源: 提案 §7.1]。
- 交付物：适配器 + 固定响应录制回放 spec。
- 依赖：M6.1-WP2。
- 验收：录制回放下系列+例外还原正确；未知属性 round-trip 无损；条件写冲突返回 `conflicted` 不覆盖。
- 风险：真实 CalDAV 服务端改写资源——首版以「服务端改写即重新拉原文」处理，不做本地推断。[推演]

**M6.2-WP2 Google Calendar 适配器**（3–5 pd）
- 目标：syncToken 增量与 watch 提示语义正确。
- 范围：首次全量、后续 `syncToken`；一轮分页完成才存新 token；`410` 对该范围全量重建；`watch` 只当「有变化」提示，channel 过期需重建；重复实例保留 `id/recurringEventId/originalStartTime`；写回按最新资源字段级 diff（本期只探测能力不写）[来源: 提案 §7.2]。
- 交付物：适配器 + 回放 spec。
- 依赖：M6.1-WP2。
- 验收：token 前推时机可断言（分页中断不前推）；watch 过期后仍能靠增量对账收敛；重复实例三层身份完整。
- 风险：OAuth 只读 scope 需用户侧真实账户（E.1#9）；无真实账户时只交回放证据并**明确标未验证**（提案 §9 第 6 条）。[推演]

**M6.2-WP3 Microsoft Graph 适配器**（3–5 pd）
- 目标：`calendarView/delta` 与 To Do 独立资源正确建模。
- 范围：delta 绑定具体日历与时间窗，完整一轮后存 `deltaLink`；通知可能只带资源 ID，漏通知用 delta 对账；Immutable ID + account/mailbox 作用域；系列/实例/例外不按 iCalUID 归并；To Do 与 Event 独立，任务时间块须显式关联 WorkSession [来源: 提案 §7.3]。
- 交付物：适配器 + 回放 spec。
- 依赖：M6.1-WP2。
- 验收：时间窗变化触发新 delta 作用域并旧游标失效；To Do 完成不自动关闭关联 Commitment；例外实例不误并入系列。
- 风险：同 Google——真实租户/账户未就绪时标未验证，不把回放当集成。[推演]

**M6.3-WP1 外部变化 → 评估 → 重估链路**（2–3 pd）
- 目标：外部变化只触发评估，绝不直接通知或重排（提案 §6.3）。
- 范围：变化→增量同步→本地对账→影响判定→重算条件/准备窗口/容量/Checkpoint→撤销失效未投递 Reminder→仅在有新决策/风险/冲突时通知→展示「旧计划 → 新建议 → 原因」三段；已接受/已发生/临近开始默认锁定；涉及他人的修改默认需确认。
- 交付物：重估链路 + 三段展示 spec。
- 依赖：M6.2 门禁。
- 验收：外部改期只产生一条带原因的建议，不自动改 WorkSession；撤销已排未投递提醒可验证；批量变化合并为一次评估。
- 风险：影响判定需要「关联强度」定义——首版仅按显式 ExternalLink 关联，不做启发式推断。[推演]

**M6.3-WP2 隐私与失败语义落地**（1–2 pd）
- 目标：失败可见、隐私默认收紧。
- 范围：跨工作/私人账户默认只共享 busy 或通用标签；每对象显示来源/写入方/权限/同步方向/最后对账结果；连接器停用后意图与历史保留，投影保留或清理由用户选；`stale/conflicted/partial_failure/unknown` 四态在视图与管理面可见；无权限或结果不确定 fail-closed [来源: 提案 §6.4]。
- 交付物：隐私档 + 失败态 spec。
- 依赖：M6.3-WP1。
- 验收：busy-only 账户查不到标题详情；四失败态各有可见位；停用连接器不删意图。
- 风险：busy-only 与容量计算耦合——容量估算用 busy 即可，不反推详情。[推演]

**M6.4-WP1 真机 round-trip、能力矩阵验证与 v0.4.0 发布**（2–4 pd）
- 目标：把「声称支持」换成「实测支持」。
- 范围：真实 Google/Microsoft/CalDAV 账户（E.1#9）各跑一轮：全量→增量→改期/取消/完成→游标失效→物删除；填实能力矩阵；`docs/design/review/m6-gate.md`；tag `v0.4.0`。
- **时间边界的端到端验收（与 M5.0-WP2 的纯函数 spec 分开）**：M5.0-WP2 只在本地语义层验 DST/全天/跨时区；本包须在**真实 provider 往返链路上**再验一遍，各自给确定期望：
  - ①DST 缺口（`America/New_York` 2026-03-08 02:30 的 VEVENT）——**两个分支分开验收，证据表各占一格**：ⓐ**接受分支**（provider 按 03:30 或等价 UTC 存储）→ 回读已存对象，显示 provider 归一化后的时间，并标 `ambiguous_local_time`；**不得**本地静默改写成 03:30 却仍显示原文 02:30；证据格填「对象 id + provider 返回时间 + 本地显示时间 + 标记」。ⓑ**拒绝分支**（provider 返回错误）→ 记录 provider 原始拒绝响应（HTTP 状态/错误码/原文），并显式声明**不创建本地镜像 ExternalLink**（该 Attempt 失败即止，不留半条记录）；证据格填「原始错误响应 + 断言 `external_links` 无新增行」。两分支任一路径走通即该项通过，但**证据必须写明走的是哪一支**，不得只写「已验证」。
  - ②秋季重复——2026-11-01 01:30 建事件后回读，须仍对应同一 UTC 时刻（不是差一小时）。
  - ③全天跨时区——在 `Asia/Shanghai` 建全天 `DATE`，以 `America/Los_Angeles` 账户/时区读取，`DATE` 值不变。
  - 三条（含①的两分支）须全部进入 m6-gate.md 证据表。
- 交付物：实测矩阵 + m6-gate.md + tag。
- 依赖：M6.3 门禁、M6.5-WP7 端到端手动验收、E.1#9。
- 验收：**至少两 provider 真机 round-trip 全绿且 M6.5-WP7 TUI 全链路验收通过方可发版**（提案 §9「必须验证的边界」第 6 条）；未实测 provider 在产品面标「实验/未验证」并列入 gate 未验证项。
- **provider 数与 CalDAV 顺延的口径裁断（CodeRabbit 问）**：①「至少两 provider」指**真机实测通过数**，不是「已实现数」——回放通过不计入。②CalDAV 若超期顺延 v0.4.1，**Google + Graph 两 provider 真机全绿仍满足 M6 门禁**，v0.4.0 按原计划发布，release notes 明写「CalDAV 顺延 v0.4.1」。③反向不允许：若只有 CalDAV 一家真机通过而 Google/Graph 均未实测，则 provider 数=1，**不足两 provider → 不发 v0.4.0**，整期按 B.3 第 6 条降级为「引擎+回放就绪」并记入 §15.1，v0.4.0 顺延待第二家真机通过。④顺延 v0.4.1 不改变 M6.0–M6.3 的验收有效性，只移动 M6.2-WP1 与 M6.4 的完成时点。
- 风险：外部账户未就绪则本期降级为「引擎 + 回放就绪、集成未验证」，按 B.3 第 5 条记入 §15.1 口径，不发 v0.4.0。[推演]

---

### M6.5 对话式 TUI（2026-11-27 追加，6–9 pd）

> 依据：[proposals/tui-conversational-console.md](../../proposals/tui-conversational-console.md)。Maintainer 裁决：路线 A（TUI 作为新 channel）+ 最小 `/stop` + 全入 M6。
> 期定位：让 Sebas 拥有第一个**本地对话入口**——`sebas tui` 启动后呈现「会话列表 + 单会话对话流 + 底部输入框」，与 email/telegram 对等，走完整 binding → scheduler → pool → agent 链路。

**M6.5-WP1 提案评审与 design.md §9 回写**（0.5–1 pd）
- 目标：提案 [tui-conversational-console.md](../../proposals/tui-conversational-console.md) 评审通过；回写 spec §9.2 契约表（新增 `tui.input` / `tui.output` / `transcript.appended` / `approval.requested/decided` 五类帧）、§5.1 渠道枚举加 `tui`、§14 M6 验收条目追加。
- 交付物：提案定稿 + 三处 spec 修订 + M6 milestone 描述更新 + 期父卡 #92 范围更新。
- 依赖：无（与 M6.0 可并行）。
- 验收：评审通过；`ruby tools/check_docs.rb` FAIL=0。
- 风险：评审推翻最小 `/stop` 范围则 WP3 需重排——估时按下限单轮计。[推演]

**M6.5-WP2 后端事件扩展：transcript.appended + approval.requested/decided**（0.5–1 pd）
- 目标：TUI 的对话流增量更新与审批问答有事件源。
- 范围：`Store#append_transcript` 返回并发布 `transcripts.id` 作为 `cursor`（含 session_key/role/content/created_at），DB 提交后 `@ipc.tap.publish`；`sessions.read` entries 返回 cursor 并支持 `after_cursor` 增量对账；`Approvals::Center#request` 入口发 `approval.requested`、`#decide` 出口发 `approval.decided`；事件推送在 Mutex 外；`IPC::CAPABILITIES` 追加 `tui.subscribe`。
- 交付物：事件发布点 + spec（验证事件字段完整 + 持锁路径无 publish）。
- 依赖：M6.5-WP1。
- 验收：append_transcript 后订阅者收到事件；审批请求/决策双向事件字段与 `approvals.pending` 返回一致；spec 全绿。
- 风险：高频 transcript 事件撑爆 tap 订阅者队列——EventTap 满则丢弃策略不变，TUI 端兜底在 WP5。[推演]

**M6.5-WP3 控制命令入口：最小 `/stop` + `/flush`**（1–1.5 pd）
- 目标：调度契约 §4.5 控制通道首次落地用户入口。
- 范围：`gateway.process_message` 在 `handle_steer_command` 前增 `handle_stop_command` / `handle_flush_command`；`/stop` 标记当前 turn 终态 `stopped`（TurnRegistry 注入中断标记，下一次工具启动边界或 provider 调用前生效，无活跃 turn 时 `error_response("no active turn")`）；`/flush` 调 Scheduler 新增 `flush_current_bucket(session_key, sender)` 单桶 seal（**不做 flush_all**——越权风险），返回 `sealed_batch_id` 或 `error_response("no collecting batch")`。
- 交付物：两个控制命令 + spec（含无活跃 turn / 无 collecting batch 的失败分支）+ 与 busy-interrupt-redirect.md 的偏差口径回写。
- 依赖：M6.5-WP1。
- 验收：`/stop` 后 turn 终态 `stopped`；`/flush` 立即 seal 当前 collecting 批次；email 渠道同样生效（双渠道同口径）；spec 全绿。
- 风险：最小 `/stop` 与 busy-interrupt-redirect.md 完整 interrupt 语义的偏差必须写明——本包只标记终态，不做协作式工具取消与 correction_key 去重。[推演]

**M6.5-WP4 TUI channel：TuiBridge + IPC tui.input/tui.output**（1.5–2 pd）
- 目标：TUI 作为 channel_type="tui" 与 email/telegram 对等。
- 范围：`src/channels/tui/bridge.cr`（或内联进 `src/admin/ipc/server.cr`，由实现者按体量判断）实现 `ChannelAdapter` 接口；`start` = 空操作（TUI 主动连 IPC，无独立 fiber）；`send(peer, content)` = IPC 推 `tui.output` 帧；新增 `sessions.ensure` 先校验 binding 四段一致再 `Lifecycle#touch` 预登记空历史 TUI 会话，`sessions.list` 合并 sessions 与 transcripts 来源；IPC 收到 `tui.input` 帧校验 `session_key` 属于所选 `local:tui:peer` 会话且 agent 段等于实时 binding 结果，再包装为 `InboundMessage(channel_type: "tui", account_id: "local", peer, content)` 推 bus，不一致或非 TUI 会话拒绝且不创建 intent、不入 bus；`spawn_adapters` 装配 TuiBridge；`Routing::BindingRule` 支持 `channel: tui`；`apply_config` 账号增删覆盖 tui。
- 交付物：TuiBridge + IPC 协议扩展 + binding 路由 + spec（入站走完整链路 + 出站回传 + 多 peer 不串扰）。
- 依赖：M6.5-WP1。
- 验收：`tui.input {session_key: "agent:main:local:tui:a", peer: "a", content: "hello"}` 触发 agent turn 且 transcript 落该会话；选中 email 会话的输入被拒绝且不创建 intent；agent `message.send` 后 IPC 推 `tui.output {peer: "a"}`；两 peer 并发不串会话；`channel: tui` 的 binding 路由正确解析。
- 风险：零 binding 启动时给出明确错误 + 配置示例，不静默失败。[推演]

**M6.5-WP5 TUI 前端：终端渲染 + 会话列表 + 对话流 + 输入框**（1.5–2 pd）
- 目标：`src/admin/tui/` 从事件流监视器升级为对话界面。
- 范围：自写 ANSI + 原始终端模式（`stty raw -echo`，Windows 用 `SetConsoleMode`）；布局 = 左栏会话列表（24 列，Tab 隐藏）+ 主区对话流 + 底部输入框（3 行）；会话列表从 `sessions.list` 拉取按 `last_active_at` 倒序，空历史会话经 `sessions.ensure` 预登记后可选中；对话流从 `sessions.read` 拉历史 + `transcript.appended` 事件增量；输入框仅对所选 TUI 会话可编辑，Enter 带 `session_key` 经 `tui.input` 帧发送，其他渠道会话只读禁用；以 transcript id 游标检测间隙，发送回执后、5 秒周期及重连时主动 `after_cursor` 对账，发现缺段则重拉去重；`q` 退出（输入框空时）；`Ctrl-C` 清空当前输入。
- 交付物：TUI 前端 + spec（用 IO 注入模拟终端）+ 手动验收脚本。
- 依赖：M6.5-WP2、M6.5-WP4。
- 验收：启动后列出全部会话；选中会话显示历史 transcript；非 TUI 会话不能发送；选中 TUI 会话输入「你好」Enter 发送，agent 回复出现在对话流；队列丢帧、断线与静默丢失最后一条事件均经对账补齐，不重复渲染。
- 风险：终端兼容性（Windows Terminal / iTerm2 / tmux）——首版只承诺主流终端，异常终端降级为逐行打印模式。[推演]

**M6.5-WP6 TUI 前端：审批问答 + 控制命令发送**（0.5–1 pd）
- 目标：L3 审批问答内嵌 + `/steer` `/stop` `/flush` 从输入框发出。
- 范围：收到 `approval.requested` 事件弹模态卡片（tool/args_summary/deadline），`y` 批准 / `n` 拒绝 / `Esc` 稍后决策；启动、IPC 重连及 5 秒周期调用 `approvals.pending` 替换本地卡片集，移除已不在 pending 的卡片；输入框 `/steer <text>` `/stop` `/flush` 原样作为 `tui.input` 的 content 发送（**TUI 端零解析**，见提案 §5.4）。
- 交付物：审批弹层 + spec。
- 依赖：M6.5-WP5。
- 验收：agent 触发 L3 工具时弹出审批卡片，`y` 批准后工具继续；审批事件丢弃/断线后经 `approvals.pending` 恢复，已决卡片在对账后移除；`/steer` 注入当前 turn；`/stop` 停止活跃 turn；`/flush` 立即 seal。
- 风险：审批卡片与输入框焦点竞争——模态时输入框禁用。[推演]

**M6.5-WP7 CLI `sebas tui` 接线 + 端到端验收 + 文档回写**（0.5 pd）
- 目标：用户可 `sebas tui` 一键启动。
- 范围：`cli.cr` 加 `tui` 子命令（读 discovery.json 连 IPC）；`print_help` 加说明；端到端手动验收清单（提案 §8）逐项打勾；回写 README/CONTRIBUTING（如需）；M-gate 证据落 `docs/design/review/m6-gate.md`。
- 交付物：CLI 子命令 + 端到端验收证据 + m6-gate.md 更新。
- 依赖：M6.5-WP5、M6.5-WP6。
- 验收：`sebas tui` 启动 → 会话列表可见 → 选中对话 → 发送消息 → agent 回复 → L3 审批问答 → `/steer` `/stop` `/flush` 全链路通过；`q` 退出不影响 gateway；`crystal spec` 全绿 + `make format-check` + `make lint` 全过。
- 风险：无（收尾包）。[推演]
