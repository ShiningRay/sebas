# development-plan M3 · 协作 + 插件脚本层（15–24 pd）

> 导航：[设计总览](../../design.md) ｜ [文档索引](../../README.md) ｜ [计划总览](../../development-plan.md) ｜ 上一节：[M2](m2-orchestration.md) ｜ 下一节：[M4](m4-fork-join.md)

### M3 · 协作 + 插件脚本层——估时合计 15–24 pd（包与生命周期 +1.5–2.5 pd；22 个 hook/DSL/初始化 +2.5–3.5 pd）

**M3-WP1 多 agent 定义与路由**（1–1.5 pd）
- 目标：N 个 agent 大脑可定义可路由。
- 范围：`agents/` agent 实例（人格/记忆/工具集独立）、binding 到 agent 维度。
- 交付物：多 agent 配置+路由 spec。
- 依赖：M2 门禁。
- 验收：两 agent 各自人格记忆独立应答。
- 风险：无实质风险。

**M3-WP2 agent 间消息+防环**（1.5–2 pd）
- 目标：互发不死循环。
- 范围：`orchestration/collaboration/`：fire-and-forget+署名+max_hops（默认 4）[来源: design.md §8]。
- 交付物：消息通道+防环 spec。
- 依赖：M3-WP1。
- 验收：**max_hops=4 拦截互发死循环**（构造两 agent 互回场景在第 4 跳截断）（§14 M3 验收第 1 条 [来源: design.md §14]）。
- 风险：无实质风险。

**M3-WP3 subagent+信号量**（2–3 pd）
- 目标：子任务被拥有、并发受控。
- 范围：subagent=被拥有的会话（ownerTaskId 找回）[来源: design.md §16#22]、并发信号量（默认 3）[来源: design.md §16#23]。
- 交付物：subagent 管理+信号量 spec。
- 依赖：M3-WP1。
- 验收：**并发上限生效（超限排队不失控）+ subagent 崩溃后找回同一子任务**（§14 M3 验收第 2/3 条 [来源: design.md §14]）。
- 风险：无实质风险。

**M3-WP4 裁剪 mruby 子进程运行时**（4–6 pd）
- 目标：子进程插件协议与精确 action/hook 派发跑通（硬需求④载体；design.md §12.2~§12.3）。
- 范围：`plugins/`：每动作独立裁剪 mruby 子进程、manifest + JSON-like 请求/结果协议、gembox 无 mruby-io/socket、请求 ID/schema/大小校验；`$action/$config/$context/$payload` 注入；`on_action/on_hook` 声明式 DSL；manifest 与注册集合一致性校验；`hook → 订阅插件` 索引；显式 install/enable/disable action（无隐式 init）；宿主工具与受控 `memory.backend` 扩展点。
- 交付物：进程 runner+DSL/精确派发 spec+首个示例插件。
- 依赖：M3-WP1；mrb.cr 甄别已完成（84/84，2026-11-19），但产品化受 Windows 新 mruby.exe 链接环境 blocker，恢复路径见 [review/m3-plugin-feasibility.md](../../review/m3-plugin-feasibility.md)。
- 验收：示例插件注册工具可被 agent 调用；**只派发 manifest 声明且本次注册 handler 的插件，不群发**；未声明/未注册/重复注册拒绝；初始化 action 不被普通 hook 隐式重复执行；**插件崩溃只影响该次调用并返回结构化错误，不卡宿主**（§14 M3 验收第 5 条）；请求缺字段、重复/超限结果和跨 scope capability 被拒绝。
- 风险：本机解释器产物 blocker 未消项时，WP4~WP6 仍按 B.3 降级条款只交预研，不宣称产品化。

**M3-WP5 沙箱、钩子目录与宿主注入点**（4–6 pd）
- 目标：插件失控不伤宿主；首版 22 个命名 hook 各有真实宿主注入点和可测失败语义。
- 范围：gembox 裁剪（WP4）、allocf/OS 资源约束、capability 与 scope 双重白名单、watchdog 终止进程树及迟到输出丢弃；实现 design.md §12.11 的消息（3）、Agent（2）、LLM（4）、工具（3）、会话/压缩（4）、记忆（2）、任务（2）、Gateway（start/stop 两名分别验证）共 22 个 hook；gate/transform 同步链、priority、deny fail-closed、observe 隔离、递归/次数/总预算限制、memo/idempotency。
- 交付物：沙箱配置、hook registry/dispatcher 与各注入点 spec、恶意插件样本（死循环/内存爆/未授权 API/递归 hook/非法 transform）。
- 依赖：M3-WP4；M2-WP2（task 生命周期）、M1-WP9（gateway 管理边界）。会话压缩若实现时仍无生产压缩器，先交付明确的 `SessionCompactor` 接口与协议完整实现，不能用假 hook 声称完成生产压缩。
- 验收：**插件死循环被 watchdog 超时终止不卡宿主**（§14 M3 验收第 4 条）；未授权 capability 拒绝；22 个 hook 按目录逐一验证精确派发与 payload schema；gate 异常/超时 deny、observe 异常跳过；transform 不越权；task 重放 memo 不重复副作用；资源上限与后代进程清理有实测证据。
- 风险：OS 资源限制/进程树终止的 Windows 行为须实测；LLM/工具/消息 hook 可能接触敏感内容，须按 manifest capability 最小化 payload 并脱敏。

**M3-WP6 插件包、热重载与生命周期**（3–5 pd）
- 目标：单文件插件可分发、免重启开发重载，安装/升级/卸载不破坏配置与数据。
- 范围：`.sebas-plugin` ZIP 白名单及路径/大小校验；`plugins/installed/<id>/versions/`、staging、registry 原子版本指针；开发目录 watch；安装默认禁用、显式授权与启停；升级/配置数据迁移/回滚；引用检查、卸载保留数据、purge 确认；CLI 与管理 API 共用 service（design.md §12.4~§12.9）。
- 交付物：pack/dev 工具、生命周期 service/API/CLI、恶意包与生命周期 spec、示例包。
- 依赖：M3-WP5、M1-WP8（共用触发-校验-换引用管线）、M1-WP9（管理 API）。
- 验收：**改开发目录脚本仅影响新调用，在途调用不受干扰**；安装默认禁用；同版本异摘要、路径穿越/压缩炸弹、未批准新 capability 均拒绝；升级保留配置/数据且失败保旧可回滚；被引用卸载拒绝、默认卸载保留数据、purge 有确认。
- 风险：ZIP 安全限制、原子替换与 Windows 文件占用须测试；签名/远程市场不在本包范围。复杂插件的受控多文件与常驻 worker 见 [review/plugin-evolution.md](../../review/plugin-evolution.md)，**不计入 M3 WP4~WP6 范围或门禁**。

### M3 追加包 · Telegram 渠道补位（2026-11-26 由 M8 迁入，5.5–8.5 pd）

> 迁入依据：Maintainer 2026-11-26 裁决「Telegram 相关任务移入 M3」。原属 M8.1-WP1 与 M8.1-WP3，现挂 milestone `M3 · Telegram 渠道补位`（`order: 3`、`track: main`）。**M0–M3 的 v0.1.0 门禁结论不受影响**——本组是已发布期号下的追加轨道，不是对 M3 门禁的追溯修改。
>
> 编号取舍：沿用 M3-WP7 / M3-WP8 两个新号，不重排既有 WP1–WP6（重排会让 §14 与各 review 存档的引用失效）。

**M3-WP7 ChannelAdapter 抽象层扩展点定稿**（1–1.5 pd）
- 目标：确认 Telegram 接入所需的适配层扩展点；不重写抽象，只补必要字段。
- 范围：核对 `src/channels/base.cr` 的 `start` / `stop` / `send` / `health`；核对入站/出站字段是否覆盖 Telegram 的 `chat_id` / `message_id`；配置 schema 增加 `channels.telegram.accounts[]`（`bot_token` 必填、`api_base_url` 可选）；email/wecom/lark 三渠道回归。
- 交付物：扩展点设计稿 + schema 校验 spec + 三渠道回归证据。
- 依赖：无前置。
- 验收：`crystal spec` 全绿（含旧三渠道）；新 schema 拒绝缺 `bot_token` 的账号；设计稿逐条标注「已覆盖 / 需新增」。
- 风险：若既有抽象假定「每渠道至多一个 token」，Telegram 的 `bot_token` 单 token 恰好适配，Slack 的双 token 才是顶破点——Slack 留在 M8 处理。[推演]
- ✅ **已完成（2026-11-26）**：PR #236 / 5e48db5。`CHANNEL_TYPES` 登记 `telegram`、`TelegramAccount` 校验（`bot_token` 必填、`api_base_url`/`token_ref` 可选）、`InboundMessage.message_id` 尾置默认 nil；提案 §4.1 增扩展点逐条判定表。门禁 spec 388/0、format、ameba 150/0、check_docs FAIL 0。

**M3-WP8 Telegram 适配器（long-poll + Bot API）**（2.5–3.5 pd）
- 目标：跑通 Telegram 多账号收发。
- 范围：`src/channels/telegram/`（adapter/long_poll/bot_api）；`getUpdates(offset, timeout=50)` 循环 + `persisted_offset` 落 store。核心机制分四条：
  - **双模空闲检测**：`last_update_at` 距今 ≥6 天进入重置模式，`reset_mode` 与 offset 同事务退出；
  - **写入顺序纪律**：先落 `telegram_updates` 的 `dispatched=false` → 再推进 offset → 再入总线；
  - **确定性 event_id**：`tg:<account_id>:<sha256(update_id || ":" || content_fingerprint)>`；
  - **恢复扫描**：启动扫描 + 运行期周期扫描重投 `dispatched=false` 且 `status != 'dead_letter'` 的行。
- 范围（出站）：`sendMessage` + token bucket（`(account_id, chat_id)` 1 msg/s、全局 30 msg/s）；`api_base_url` 账号级配置支持反代。
- 交付物：Telegram 适配器 + spec + 单账号本地实测报告。
- 依赖：M3-WP7；**调度器 failed 批次重试扩展**（`retry_failed_batch` + failed→queued + 重派触发器 + 启动屏障，见 [提案 §4.2 前置依赖](../../proposals/m8-channel-expansion-slack-telegram.md)）；外部：Telegram BotFather 注册 2 bot。
- 验收：两账号同时 online 不串扰；重启后 offset 续接；单 chat 限流排队不丢；`api_base_url` 指向 mock server 收发全通（CI 路径）；空闲重置不丢消息且按内容指纹排重；三个崩溃窗口经 `dispatched=false` 扫描恢复；dead-letter 行不被两条扫描路径选中。
- 风险：long-poll 在 NAT/反代后易被中间设备掐空闲连接——`timeout=50` 为官方推荐值，不低于 30 不高于 60。[推演]
