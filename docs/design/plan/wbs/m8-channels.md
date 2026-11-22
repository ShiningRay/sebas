# development-plan M8 · 渠道扩展（Slack + Telegram）（10.5–16.5 pd）

> 导航：[设计总览](../../design.md) ｜ [文档索引](../../README.md) ｜ [计划总览](../../development-plan.md) ｜ 上一节：[M7](m7-projection.md)

### M8 · 渠道扩展（Slack + Telegram）——估时合计 10.5–16.5 pd（2026-11-23 追加，v0.6.0）

> 依据：[proposals/m8-channel-expansion-slack-telegram.md](../../proposals/m8-channel-expansion-slack-telegram.md)（本文档只做工作包、依赖、估时与验收；**不新造设计决策**——语义有变更回写提案与 design.md，不在本计划内定）。
> 期定位：在 Email / WeCom / Lark 三渠道之外扩展 Slack 与 Telegram 两个新渠道，对齐 Hermes/OpenClaw 已验证多账号形态的两个最常见入口。渠道适配复用 §5 已有的「账号生命周期监督 fiber + TokenProvider + 限流桶 + 接收形态归并」骨架，不引入新原语。
> 期门禁：标准四条（`make format-check` + `make spec` + `make lint` + `make release`）。M8.0-WP1 为纯文档包豁免命令门禁（评审通过即可）；其余 WP 不豁免。
> 开工三闸：在 active milestone 内 / WP 依赖前置已有完成证据 / 外部依赖就绪（E.1 见下）。

**外部依赖（E.1）**：

| 编号 | 依赖项 | 就绪时点 | 说明 |
|---|---|---|---|
| E.1#1 | Slack workspace + Slack App（Socket Mode enabled） | M8.1-WP2 开工前 | 至少 1 个 workspace、2 个 app（多账号验收需要），用户侧动作 |
| E.1#2 | Telegram BotFather 注册 2 个 bot | M8.1-WP3 开工前 | 多账号验收需要，用户侧动作 |
| E.1#3 | 科学上网环境（CI 不需要，仅本地实测需要） | M8.1-WP2/WP3 验收前 | 两个渠道的公网端点国内不可达 |

---

**M8.0-WP1 提案评审与回写定稿**（0.5–1 pd）
- 目标：提案 [m8-channel-expansion-slack-telegram.md](../../proposals/m8-channel-expansion-slack-telegram.md) 评审修订并回写 design.md。
- 范围：评审 §2 候选矩阵、§3 首期范围、§4 设计要点、§5 风险；回写 [spec/02-goals-non-goals.md](../../spec/02-goals-non-goals.md) §2.1 渠道清单扩至 5 类、[spec/05-multi-account.md](../../spec/05-multi-account.md) §5 追加 §5.7 Slack 接入方案 / §5.8 Telegram 接入方案、[spec/14-roadmap.md](../../spec/14-roadmap.md) 追加 M5–M8 行（与 M5/M6/M7 同步回写，避免再次欠账）。
- 交付物：提案定稿版 + 三处 spec 修订。
- 依赖：无。
- 验收：评审通过；§14 含 M8 期验收条目；`ruby tools/check_docs.rb` FAIL=0。
- 风险：评审若推翻首期范围（如改首批为 Discord），后续 WP 链整体调整——估时按下限单轮计。[推演]

**M8.1-WP1 ChannelAdapter 抽象层核对与最小扩展点定稿**（1–1.5 pd）
- 目标：盘点 M0/M1 已落地的 `src/channels/base.cr` 抽象接口，确认 Slack/Telegram 接入所需的扩展点；**不重写抽象**，只补必要字段。
- 范围：核对 `abstract class ChannelAdapter` 的方法集（connect/disconnect/send/health）；核对 InboundEvent/OutboundMessage 字段是否覆盖 Slack 的 `team_id/channel/ts`、Telegram 的 `chat_id/message_id`；若缺则补字段（新字段必须非破坏，旧适配器零改动通过）；配置 schema 加 `channels.slack.accounts[]` / `channels.telegram.accounts[]` 校验规则。
- 交付物：扩展点设计稿 + spec 校验规则 + 现有 email/wecom/lark 适配器回归通过证据。
- 依赖：M8.0-WP1。
- 验收：`crystal spec` 全绿（含旧三渠道回归）；新配置 schema 拒绝缺 `bot_token` 的 Slack 账号、缺 `bot_token` 的 Telegram 账号。
- 风险：M1 抽象若已假定「每渠道至多一个 token 类型」，Slack 的 `app_token + bot_token` 双 token 会顶破假设——扩展点必须支持命名凭据集（map of tokens），不能沿用单 token 字段。[推演]

**M8.1-WP2 Slack 适配器：Socket Mode 接收 + Web API 发送**（3–4.5 pd）
- 目标：跑通 Slack 多账号收发。
- 范围：
  - `src/channels/slack/` 目录：adapter.cr / socket_mode.cr / web_api.cr / markdown.cr；
  - Socket Mode 连接：`apps.connections.open` 换 WSS endpoint → 建立 WebSocket → 收 `events_api` envelope → **先落库（含 envelope 原文与 `event_id` 唯一索引）→ 再按 `envelope_id` 发 ACK → 再入总线**（沿用 §5.2「回调 fiber 只验签+落库+入总线」纪律；顺序修正原因：若 ACK 早于落库，进程在 ACK 后、落库前崩溃会静默丢消息——Slack 已收到确认不再重推，本地无记录）；
  - 排重：`event_id` 唯一索引；
  - 发送：`chat.postMessage` + token bucket（按 `(account_id, method, channel)` 建桶，Slack Tier 2 起步 ~1 msg/s）；
  - TokenProvider 退化为「从 keyring 读取缓存」（无 refresh）；
  - 限流 429 响应处理：读 `Retry-After` 头退避；
  - 多账号：每账号一连接一 fiber，配置增删走 §11 热更新（不重写热更新机制，直接复用）。
- 交付物：Slack 适配器 + 接收/发送 spec（用 vcr/webmock 风格 fixture）+ 单账号本地实测报告。
- 依赖：M8.1-WP1；E.1#1；E.1#3。
- 验收：
  - 两账号同时 online，互不串扰（A 收的 message 不会进 B 的 session）；
  - 同账号同 `event_id` 重推被排重；
  - 发送触发 429 后按 `Retry-After` 退避，不丢消息；
  - 进程强杀重启后 offset 恢复，未 ACK 的 envelope 重推可被消费；
  - **ACK 后、入总线前强杀进程**：用 fault-injection 在 ACK 帧发出后立即 `kill -9`，重启后从持久化记录恢复该事件并入总线（不依赖 Slack 重推，因为 Slack 已收到 ACK）——验证「先落库再 ACK」顺序真的挡住了静默丢失窗口。
- 风险：Crystal `HTTP::WebSocket` 客户端长连接稳定性——若发现 keepalive 不足，退化为「心跳超时后主动断线重连」。[推演]

**M8.1-WP3 Telegram 适配器：long-poll 接收 + Bot API 发送**（2.5–3.5 pd）
- 目标：跑通 Telegram 多账号收发。
- 范围：
  - `src/channels/telegram/` 目录：adapter.cr / long_poll.cr / bot_api.cr；
  - long-poll：`getUpdates(offset, timeout=50)` 循环；offset 落 store 持久化，启动时读；**活跃窗口/空闲双模**——`last_update_at` 距今 ≥6 天进入重置模式（详见 [proposals/m8-channel-expansion-slack-telegram.md §4.2](../../proposals/m8-channel-expansion-slack-telegram.md)「Telegram 空闲后 `update_id` 重置策略」）；
  - 排重：活跃窗口内 `update_id` 单调递增推进；重置模式下用内容指纹（`update_id + chat_id + message_id + text hash`）查重，不靠 offset 比较；**持久化优先于 offset 推进**——每条 update 按「Step 1 落 `telegram_updates`（含 `dispatched=false`）→ Step 2 推进 `persisted_offset` → Step 3 入总线」顺序；**`dispatched=true` 由消费者侧在 `record_intent` 落库成功后回调置位**，`Bus#publish` 返回不等于处理完成；启动时扫 `dispatched=false` 重投；
  - 重置模式退出条件：本轮 ≥1 条新 update 且全部持久化 + 入总线成功后才重置 `persisted_offset` 并切回活跃窗口；**空轮询继续保持重置模式**；
  - store 表新增 `telegram_accounts.last_update_at` 与 `telegram_updates(content_fingerprint, account_id, update_id, raw_payload, dispatched, created_at)`，`(content_fingerprint, account_id)` 唯一索引；
  - 发送：`sendMessage` + token bucket（按 `(account_id, chat_id)` 建桶，1 msg/s；全局 30 msg/s 桶）；
  - TokenProvider 同 Slack 退化形态；
  - 多账号：每账号一 long-poll fiber；
  - `api_base_url` 账号级配置（支持自建反代，应对国内不可达）。
- 交付物：Telegram 适配器 + spec + 单账号本地实测报告。
- 依赖：M8.1-WP1；E.1#2；E.1#3。
- 验收：
  - 两账号同时 online，互不串扰；
  - 重启后 offset 续接，未消费 update 不丢；
  - 单 chat 限流触发时排队而非丢弃；
  - `api_base_url` 指向 mock server 时收发全通（CI 用此路径，无需公网）；
  - **空闲重置场景**：mock server 模拟「bot 空闲 ≥1 周后，下一条 update 的 `update_id` 小于持久化 offset」——适配器进入重置模式，**不丢弃该消息**（内容指纹查重落库 + 入总线），并把 `persisted_offset` 重置为新值；同一条 update 重推时按内容指纹排重，不重复入总线；
  - **拒绝旧 offset 确认**：在重置模式下，任何 `getUpdates` 调用不得因为「新 `update_id` < persisted_offset」而直接 ACK 跳过——必须在内容指纹查重后才决定是否消费；
  - **活跃窗口持久化优先**：fault-injection 在「Step 1 落库后、Step 2 推进 offset 前」`kill -9`，重启后扫 `dispatched=false` 行重投入总线，不丢消息；再注入「Step 2 推进 offset 后、Step 3 入总线前」`kill -9`，同样靠 `dispatched=false` 扫描恢复；
  - **`dispatched` 由消费者置位**：fault-injection 在「`Bus#publish` 已返回但消费者尚未 `record_intent`」`kill -9`——生产者侧 `dispatched` 仍为 `false`；重启后扫到该行重投入总线，消费者这次完成 `record_intent` 并回调置 `dispatched=true`；验证 bus 投递成功不等于处理完成、`dispatched` 不会因 bus 返回被过早置位；
  - **唯一索引冲突不阻塞 offset 推进**：mock server 让进程在 Step 1 后、Step 2 前崩溃，重启并恢复后 mock server 再次返回同一条 `update_id`——适配器在 Step 1 命中唯一索引冲突时**不视为失败**，继续 Step 2 推进 `persisted_offset`；该行的 `dispatched` 已为 `true`，Step 3 跳过不重复入总线。验证轮询不停滞、消息不重复入总线；
  - **入站 `event_id` 确定性派生（含内容指纹）**：fault-injection 在「消费者 `record_intent` 落库成功后、`dispatched` 置位前」`kill -9`，重启后扫到 `dispatched=false` 行重建消息——用持久化行的 `update_id` 与 `content_fingerprint` 按提案 §4.2 唯一形式 `tg:<account_id>:<sha256(update_id || ":" || content_fingerprint)>` 算出与原投递**同值**的 `event_id`；经 **`Bus#publish`** 重新入总线（走正常 admission → dispatch 流程，不绕过会话调度器的串行约束），消费者 `process_message` 被调起，`record_intent` 命中已有 intent（`INSERT OR IGNORE` 返回 false）走「已有 intent」分支**也要**回调置 `dispatched=true`——该 update 全程只被处理一次，触发的发消息动作也只执行一次；额外验证：mock server 让适配器进入重置模式后收到两条 `update_id` 相同但内容不同的 update，两条都能得到独立 `event_id`，第二条不会被消费者 intent 排重忽略；
  - **空轮询不退重置模式**：mock server 让适配器进入重置模式后，前 N 轮 `getUpdates()` 返回空数组，第 N+1 轮返回一条 `update_id` 小于持久化 offset 的 update——前 N 轮持续无 offset 轮询、不重置 offset；第 N+1 轮该 update 被消费，`persisted_offset` 重置为新值，下一轮回到活跃窗口；
  - **`record_intent` 失败的运行期恢复（前置依赖：调度器 failed 批次重试扩展）**：fault-injection 让消费者 `record_intent` 第一次抛 SQLite 临时错误（`SQLITE_BUSY`），`dispatched` 保持 `false`、入站事件已完成 admission、`session_inputs` 行已落库；**前置依赖**：调度器 failed 批次重试扩展（`SessionScheduler#retry_failed_batch` + failed → queued 状态迁移 + queued 批次重派触发器 + 启动屏障）已完工；适配器通过标准 `Bus#publish` 入总线，由调度器扩展保证恢复语义；第二次 `record_intent` 成功并回调置 `dispatched=true`；再注入「连续 20 次 `record_intent` 失败」，该行 `status` 置为 `'dead_letter'`、上报管理面告警、**两条扫描路径都用 `status != 'dead_letter'` 显式排除**——验证 dead-letter 行不再被周期扫描或启动扫描选中；
  - **Case B · 首次 admission 前崩溃的 update**：fault-injection 在「Step 1 落库后、Step 3 入总线前」`kill -9`——事件从未进入 admission、`session_inputs` 无对应行；重启后扫描器经 **`Bus#publish`** 重新入总线（走正常 admission 流程建立 `session_inputs` 行——含 `received_seq`、批次归属、`policy_snapshot`——再经 `SessionScheduler` 按批次串行约束 dispatch）；断言恢复后该事件具有完整 `session_inputs` 行、正确的 `received_seq` 与批次归属、`policy_snapshot`，且**不绕过会话调度器的串行约束**（同 session 其他事件按 received_seq 顺序被调度）；
  - **bus 饱和降级与两类失败分开计数**：mock bus 队列容量填满，适配器调 `Bus#publish` 阻塞；扫描器用 `select` + 5s 超时降级为非阻塞投递，超时跳过本轮、`bus_publish_timeout_count` 加 1、下一轮再试，验证扫描器不被卡死。再让 bus 持续饱和直到 `bus_publish_timeout_count > 20`——验证 `retry_count` **未增加**、行**未转入 `dead_letter`**（bus 超时不计入消费者失败上限）；恢复 bus 容量，下一轮扫描成功入总线、`record_intent` 成功、回调置 `dispatched=true`——验证 bus 恢复后健康消息无需人工重放；
  - **启动屏障（等待 replay_unfinished 完成）**：**前置依赖**：调度器启动屏障扩展（`Gateway#recover_dispatch` 在 `replay_unfinished` 完成后、适配器启动前设置 `@replay_completed = true`）已完工；mock Gateway 启动流程——`replay_unfinished` 期间扫描器检查 `@replay_completed = false`，跳过本轮、记录 `dispatch_recovery_deferred_total`、不触发 dispatch；`replay_unfinished` 完成后 `@replay_completed = true`，下一轮扫描正常触发 dispatch；断言旧 intent 重放期间不会有新批次被派发、两个 turn 不并发执行；再注入 `replay_unfinished` 超过 300s 未完成，Gateway 上报 `ReplayStuck` 告警、扫描器继续等待（不强行突破屏障）；
  - **已有 intent 也要确认**：消费者 `process_message` 在 `record_intent` 时发现已有持久化 intent 而提前返回的分支，**必须**回调置 `dispatched=true`——fault-injection 让进程在「`record_intent` 成功后、回调置位前」崩溃，重启后扫到 `dispatched=false` 行重投入总线，消费者走「已有 intent」分支也置位，验证不会卡在 `dispatched=false` 被无限重投。
- 风险：long-poll 在 NAT/反代后容易被中间设备掐空闲连接——`timeout=50` 是官方推荐值，不低于 30 不高于 60。[推演]

**M8.2-WP1 管理面与运维闭环**（1.5–2 pd）
- 目标：Slack/Telegram 账号纳入 TUI/HTTP 双入口管理。
- 范围：`accounts.create/list/disable/enable/rotate-credential` 命令对 slack/telegram 生效；健康上报（连接状态、最近 event 时刻、限流水位）经管理面可查（沿用 §5.1 第 5 项职责）；`sebas channels probe` 自检命令。
- 交付物：管理面命令 + spec + TUI 截图。
- 依赖：M8.1-WP2、M8.1-WP3。
- 验收：`sebas accounts list` 输出 slack/telegram 账号状态；`sebas accounts disable <id>` 后该账号 fiber 优雅停止；`sebas channels probe` 报告可达性。
- 风险：TUI 现有代码若硬编码渠道枚举需要逐一展开——必须改为遍历 adapter registry。[推演]

**M8.2-WP2 文档、示例与发布准备**（1.5–2.5 pd）
- 目标：让用户能照着文档 5 分钟接入一个 Slack 或 Telegram 账号。
- 范围：
  - README 渠道矩阵扩至 5 类；
  - `docs/examples/` 新增 `slack-bot.yaml` / `telegram-bot.yaml` 示例配置；
  - `docs/design/spec/05-multi-account.md` §5.7/§5.8 写作落档（M8.0-WP1 是占位，此包填实）；
  - 限流数字、接收形态、排重字段的核实引用补全；
  - 版本号同步：`shard.yml` + `src/version.cr` → v0.6.0。
- 交付物：文档 + 示例 + 版本号修订。
- 依赖：M8.2-WP1。
- 验收：`ruby tools/check_docs.rb` FAIL=0；新用户按 README 配置示例即可启动；`make release` 全绿。
- 风险：文档与代码漂移——发布前 Verifier 逐条对照示例配置字段名与代码 schema。[推演]

---

## 期级验收主线（M8）

- 同渠道 N 账号并存：Slack 2 账号 + Telegram 2 账号同时 online，互不串扰（继承 M1 期级验收主线）。
- 长连接形态覆盖：Slack Socket Mode（WSS）+ Telegram long-poll（HTTPS 出站）都跑通，无新增公网 IP 依赖。
- TokenProvider 抽象未破坏：现有 WeCom/Lark 临期刷新路径回归通过。
- 配置热更新覆盖新渠道：运行中增/删/改 Slack/Telegram 账号不需重启进程。
- 标准四条全绿 + `ruby tools/check_docs.rb` FAIL=0。

## DAG

```
M8.0-WP1 ──> M8.1-WP1 ──┬──> M8.1-WP2 (Slack) ────┐
                        └──> M8.1-WP3 (Telegram) ───┤
                                                    ├──> M8.2-WP1 ──> M8.2-WP2
E.1#1 ────────────────────> M8.1-WP2
E.1#2 ────────────────────> M8.1-WP3
E.1#3 ────────────────────> M8.1-WP2 / WP3 验收
```

跨期依赖：M8 开工需 M5–M7 主线已收尾（v0.5.0 已发），且 M4x 并行轨无阻断。

## 估时合计

| 包 | 下限 | 上限 |
|---|---|---|
| M8.0-WP1 | 0.5 | 1 |
| M8.1-WP1 | 1 | 1.5 |
| M8.1-WP2 | 3 | 4.5 |
| M8.1-WP3 | 2.5 | 3.5 |
| M8.2-WP1 | 1.5 | 2 |
| M8.2-WP2 | 1.5 | 2.5 |
| **合计** | **10.0** | **15.0** |

含 +0.5–1.5 pd 缓冲（依 Tessell 口径）→ **10.5–16.5 pd**。

## 版本计划

- milestone：`M8 · v0.6.0 渠道扩展（Slack + Telegram）`
- 期序：主线第 8 期（order: 8）
- 排期：W48–W51（4 周窗口，含缓冲），紧随 M7 之后
- 发版：manual minor（`workflow_dispatch` 输入 `minor`），三平台资产 + sha256 + 裸 ubuntu:24.04 容器冒烟
