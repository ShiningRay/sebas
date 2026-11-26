# M8 渠道扩展（Slack + Telegram）——对标 Hermes/OpenClaw

> 状态：**Proposal**（设计提案，2026-11-23）。
> 关联：[design.md §5 多账号设计](../spec/05-multi-account.md)、[research/hermes-agent.md](../research/hermes-agent.md)、[research/openclaw.md](../research/openclaw.md)。
> 本文职责：在 Email / WeCom / Lark 三渠道之外扩展 Slack 与 Telegram 两个新渠道，对齐 Hermes 21+ 与 OpenClaw 33+ 渠道矩阵中已验证多账号形态的两个最常见入口。

## 1. 背景与动机

### 1.1 现状

Sebas 本期已规划三类渠道（design.md §2.1）：

| 渠道 | channel_type | 接收形态 | 多账号 |
|---|---|---|---|
| Email | `email` | IMAP IDLE / Gmail API | N |
| 企业微信 | `wecom` | 智能机器人长连接 / 自建应用回调 | N |
| 飞书 / Lark | `lark` | WebSocket / Webhook | N（platform 字段区分） |

另有单向出站 webhook（企微群机器人、飞书自定义机器人）作为低敏通知通道。

### 1.2 对标差距

Hermes Agent 官方 messaging gateway 覆盖 **21+ 平台**（[research/hermes-agent.md §消歧定案](../research/hermes-agent.md)）：

> telegram、discord、slack、whatsapp、whatsapp_cloud、signal、email（IMAP/SMTP）、sms、matrix、line、teams（插件）、google_chat、msgraph-webhook、wecom、wecom-callback、feishu、dingtalk、qqbot、weixin、webhooks

OpenClaw 官方渠道目录 2026-11 版共 **33 项**（[research/openclaw.md §2.1 官方渠道目录](../research/openclaw.md)）：

> bundled：Telegram、WebChat、A2A、Reef、X/Twitter；
> official plugin：Discord、Feishu(Lark)、Google Chat、iMessage、IRC、LINE、Matrix、Mattermost、Microsoft Teams、Nextcloud Talk、Nostr、QQ bot、Signal、Slack、SMS(Twilio)、Synology Chat、Tlon、Twitch、WhatsApp、Zalo、…；
> external plugin：WeChat、WeCom、Yuanbao、Zalo ClawBot。

**明确支持「同渠道 N 账号」的 17 个渠道**（OpenClaw multi-agent.md）：

> discord、feishu、googlechat、imessage、irc、line、mattermost、matrix、msteams、nextcloud-talk、nostr、signal、slack、telegram、whatsapp、zalo、zalouser。

Sebas 当前渠道数 = 3，对标对象成熟渠道数 ≥ 17（多账号一等公民）。差距显著。

### 1.3 优先级判据

按以下三条收敛首期范围：

1. **两家对照对象都已实现**（避免踩独家渠道的坑）；
2. **官方支持同渠道 N 账号**（在 OpenClaw 17 个清单内）；
3. **个人单机部署友好**：优先长连接 / long-poll（免公网 IP、免内网穿透），与 Sebas §5.2「接收侧两形态归并」中长连接优先的设计一致。

## 2. 候选渠道矩阵

| 渠道 | Hermes | OpenClaw | 多账号 | 接收形态 | 国内可用性 | 优先级 |
|---|---|---|---|---|---|---|
| **Slack** | ✅ native | ✅ official | ✅ | Socket Mode（WSS）/ HTTP Request URLs | 需科学上网 | **P0** |
| **Telegram** | ✅ native | ✅ bundled（首推） | ✅ | long-poll / webhook | 需科学上网 | **P0** |
| Discord | ✅ native | ✅ official | ✅ | Gateway（WSS） | 需科学上网 | P1 |
| Matrix | ✅ native | ✅ official | ✅ | AS / Client-Server API | 自建 Synapse 可国内 | P1 |
| Microsoft Teams | ✅ plugin | ✅ official | ✅ | Bot Framework webhook | 国内可 | P1 |
| LINE | ✅ native | ✅ official | ✅ | webhook | 国内不可 | P2 |
| Google Chat | ✅ native | ✅ official | ✅ | HTTP webhook | 需科学上网 | P2 |
| WhatsApp | ✅ native | ✅ official | ✅ | Baileys（WSS）/ Cloud API | 需科学上网 | P2 |
| Signal | ✅ native | ✅ official | ✅ | signal-cli 子进程 | 需科学上网 | P2 |
| iMessage | ✅ via BlueBubbles | ✅ official | ✅ | imsg（macOS only） | macOS 限定 | P2 |
| IRC | ✅ via plugin | ✅ official | ✅ | 长连接 | 国内可 | P3 |
| Mattermost | — | ✅ official | ✅ | 长连接 | 自建可 | P3 |
| QQ bot | ✅ native | ✅ official | ❌ 未列入 | 长连接 | 国内可 | P3 |
| 钉钉 DingTalk | ✅ native | — | — | Stream 长连接 | 国内可 | P3 |
| 个人微信 WeChat | ✅ via iLink | ✅ external plugin | — | iLink Bot API | 国内可，协议风险 | **不做**（OpenClaw 同款由社区在仓外维护，风险隔离） |
| SMS（Twilio） | ✅ native | ✅ official | — | webhook | 付费 + 国内落地困难 | **本期排除**（用户决策） |

**P0 = 首期（M8）落地；P1 = 主线 M8+1 候选；P2 = 视需求另立 milestone；P3 = 仅当有用户诉求。**

## 3. 首期范围（M8 · v0.6.0）

仅 **Slack + Telegram** 两个渠道。理由：

- Hermes 与 OpenClaw 都把 Telegram 列为首推接入渠道（"一个 bot token 即可"）；Slack 是 Hermes 多 profile 长轮询形态的教科书示例。
- 两者都提供免公网的接收形态（Slack Socket Mode = 出站 WSS；Telegram long-poll = 出站 HTTPS 轮询），与 Sebas §5.2 长连接优先的设计一致。
- 两者都在 OpenClaw 17 个多账号清单内，profile/accountId 范式可直接对接 Sebas 的 `(channel_type, account_id)` 命名空间。
- 两者发送侧都是 Bot API HTTP 调用，无 SMTP/IMAP 类历史包袱。

### 3.1 非目标（本期不做）

- 不做 Discord / Matrix / Teams / WhatsApp / Signal / LINE / Google Chat / iMessage / IRC / Mattermost / QQ bot / 钉钉（见 §2 优先级）。
- 不做 SMS（用户决策排除）。
- 不做个人微信 WeChat（协议风险渠道，按 OpenClaw 惯例由社区仓外维护）。
- 不做 Slack Relay Mode / HTTP Request URLs（OpenClaw 已明列为三种 transport 中的历史形态，首期只做 Socket Mode）。
- 不做 Telegram webhook 形态（需公网 IP，与 §5.2 长连接优先原则冲突；long-poll 在单机部署下完全够用）。
- 不做 voice call（Plivo/Telnyx/Twilio）。

## 4. 设计要点

### 4.1 配置树（沿用 §3.4 账号数组结构）

```yaml
channels:
  slack:
    accounts:
      - id: work-team
        app_token: "xapp-..."          # Socket Mode 用
        bot_token: "xoxb-..."          # Web API 用
        token_ref: keyring://sebas/slack/work-team
      - id: personal-team
        app_token: "xapp-..."
        bot_token: "xoxb-..."
        token_ref: keyring://sebas/slack/personal-team
  telegram:
    accounts:
      - id: personal-bot
        bot_token: "123456:ABC..."
        token_ref: keyring://sebas/telegram/personal-bot
      - id: work-bot
        bot_token: "..."
        token_ref: keyring://sebas/telegram/work-bot
```

**session_key 五段不变**：`agent:<agent_id>:<account_id>:slack:<peer>` / `...:telegram:<peer>`。

#### 扩展点定稿（M3-WP7，2026-11-26 自 M8.1-WP1 迁槽；Telegram 侧先行落地）

> 逐条盘点既有抽象对 Telegram 接入的覆盖情况；**不重写抽象，只补必要字段**。
> 落地件：`CHANNEL_TYPES` 登记 `telegram`、`TelegramAccount`（`bot_token` 必填、
> `api_base_url`/`token_ref` 可选）与 loader 校验、`InboundMessage.message_id`。
> 适配器接线不在本卡范围（属 M8.1-WP3）：接入前配置可校验、发送时
> `Channels::Registry` 查无适配器 fail-loud。

| 扩展点 | Telegram 所需 | 判定 |
|---|---|---|
| `ChannelAdapter` 方法集 `start`/`stop`/`send`/`health` | getUpdates 长轮询=`start`、优雅停止=`stop`、`sendMessage`=`send(peer=chat_id)`、health 用默认实现 | 已覆盖——接入实现零抽象改动 |
| `handle_callback` 回调扩展点 | Telegram 为拉取型（getUpdates），无回调面 | 已覆盖——默认 404 语义合适 |
| `InboundMessage.peer` | `chat.id`（字符串承载） | 已覆盖 |
| `InboundMessage.message_id` | `message.message_id`（排重与回复定位；`update_id` 归排重层） | **需新增**——已补 `message_id : String? = nil`（尾置默认，旧适配器五参构造零改动；回放路径随 JSON 保真） |
| `OutboundMessage` | 无独立 record：`send(peer, content, idempotency_key)` 即覆盖（`chat_id`=peer；客户端幂等键见 §4.4） | 已覆盖 |
| 配置 `channels.telegram.accounts[]` | `bot_token` 必填（缺键 YAML 解析即报、空串由 loader 校验拒绝）、`api_base_url` 可选（自建 Bot API server）、`token_ref` keyring 指针 | **需新增**——已登记 `telegram` 并落地校验 |
| TokenProvider / 限流桶 / 监督骨架 | 长期凭据无 refresh（§4.3）；token bucket 按 `(account_id, chat_id)`；fiber-per-account 监督（§5.1） | 已覆盖——沿用既有骨架，接入属 M8.1-WP3 |
| Binding 路由 | `bindings[].channel: telegram` 校验与 `account_ids` 解析 | 已覆盖——`CHANNEL_TYPES` 登记后自动生效 |

Slack 侧字段（`team_id`/`channel`/`ts`、`app_token`/`bot_token`）在同卡范围之外，接入前按同法盘点（M8.1-WP2）。

#### Slack ACK 后崩溃恢复

Slack Socket Mode 的「先落库 → 再 ACK → 再入总线」顺序防的是「ACK 早于落库」的静默丢失窗口，但 **ACK 后、入总线前崩溃**仍有窗口——Slack 已收到确认不再重推，本地事件已落库但尚未入总线。恢复机制：

- **持久化表**：`slack_events(event_id, account_id, envelope_id, raw_payload, dispatched, created_at)`——落库时 `dispatched=false`，入总线后消费者 `record_intent` 成功回调置 `dispatched=true`。
- **启动恢复**：每次启动 Socket Mode 连接前，先扫 `slack_events.dispatched=false` 的行，按 `created_at` 升序经 `Bus#publish` 重投（走正常 admission → dispatch 流程，不绕过会话调度器的串行约束）。
- **运行期恢复（admission 失败重投）**：若 `admit` 因会话积压已满而拒绝事件，`dispatched` 保持 `false`——适配器**运行期持续重投** `dispatched=false` 的记录（每 60s 扫描一次，与 Telegram 周期扫描同构），使临时 admission 拒绝的事件在容量恢复后无需重启即可重新进入正常 admission → dispatch 流程。
- **与 Telegram 恢复机制同构**：`dispatched` 标记、消费者确认回调、启动扫描 + 运行期扫描重投——两渠道共用同一恢复模式。

### 4.2 接收侧形态归并（沿用 §5.2）

两渠道都属于**长连接型**（出站连接，免公网）：

| 渠道 | 形态 | 心跳/重连 | 排重 |
|---|---|---|---|
| Slack | Socket Mode（WSS 长连接，Endpoint 由 `apps.connections.open` 换取） | 服务端 ping；断线指数退避 5s→60s（沿用 §5.1） | `event_id` 排重；`envelope_id` ACK；**ACK 顺序：先落库 → 再 ACK → 再入总线**（防 ACK 后崩溃丢消息） |
| Telegram | `getUpdates` long-poll（HTTPS 长轮询，默认 timeout=50s） | 轮询循环 + 指数退避 | `update_id` 在活跃窗口内单调递增，**空闲 ≥1 周后可能被 Telegram 重置为随机值**（见下方专门策略） |

每账号一条监督 fiber（§5.1 生命周期状态机：connecting→online⇄backoff→disabled/degraded）。

#### Telegram 空闲后 `update_id` 重置策略（官方语义）

Telegram 官方 Bot API 文档明示：**`update_id` 在至少一周无新 update 后不再保证单调递增**，下一个 `update_id` 会从随机位置重新开始，可能小于持久化 offset。若沿用「`getUpdates(offset=last+1)` 确认旧值」的活跃期策略，会把重置后的新消息确认跳过、静默丢失。本设计采用「**活跃/空闲双模 + 重置检测**」：

1. **活跃窗口内（持久化优先于 offset 推进）**：对收到的每条 update，按以下顺序处理：
   - **Step 1 · 持久化**：先把 update 原文 + 内容指纹落 `telegram_updates` 表（含 `dispatched: false` 标记）。**唯一索引冲突处理**：若 INSERT 触发 `(content_fingerprint, account_id)` 唯一索引冲突，说明该 update 之前已持久化（典型场景：上一次进程在 Step 1 后、Step 2 前崩溃，重启后 Telegram 再次返回同一条 update）——**不视为失败**，继续执行 Step 2 推进 `persisted_offset`；同时查一次该行的 `dispatched` 标记，`dispatched=true` 则 Step 3 跳过（不重复入总线），`dispatched=false` 则 Step 3 照常执行。
   - **Step 2 · 推进 offset**：持久化成功（含唯一索引冲突被视为已持久化）后，才把 `persisted_offset = update_id` 落库；下次 `getUpdates(offset=persisted_offset+1)` 才确认旧值。**绝不在持久化前推进 offset**——否则崩溃后 Telegram 已确认、本地无记录，静默丢消息。**空闲计时起点**：`last_update_at` 在**每次收到非空 `getUpdates` 响应时立即持久化为该响应到达时刻**，空响应不刷新。它表示「Telegram 最近一次有 update 交付给本进程的时刻」，不是批次处理完成时刻，因此 Step 1–3 的阻塞不会推迟空闲计时——否则响应到达 0 天、Step 3 阻塞 2 天、计时起点后移到第 2 天，Telegram 第 7 天投递的小 ID update 在本地只算 5 天空闲，未达 6 天阈值，会被活跃模式的 offset 跳过。到达即落库也保留崩溃安全：重启后不会把空闲基准误推进到尚未交付的后续响应。
   - **Step 3 · 入总线 + 消费者确认**：把该 update 投递到 bus。**`Bus#publish` 成功返回 ≠ 处理完成**——`Bus#publish` 只把事件写入进程内存 Channel，没有落盘或确认机制；消费者在接收事件后才调用 `record_intent` 把 intent 写入 intents 表。因此 `dispatched=true` 的置位必须由**消费者侧**发起：
     - 消费者 `process_message` 在 `record_intent` 落库成功后，回调 Telegram adapter 把对应 `telegram_updates.dispatched` 置 `true`；
     - **已有 intent 分支也要确认**：若消费者 `process_message` 在 `record_intent` 时发现已有持久化 intent（`INSERT OR IGNORE` 返回 false）而提前返回，**也必须**回调把对应 `telegram_updates.dispatched` 置 `true`——否则启动恢复会重投该行，消费者又走「已有 intent」分支提前返回，永远卡在 `dispatched=false`，每次启动都被重复重投。
     - 生产者在 `Bus#publish` 返回后**不置位**——`dispatched` 仍为 `false`，直到消费者确认；
     - 已标 `dispatched=true` 的行不得再次入总线。
   - **`record_intent` 失败的运行期恢复**：若消费者 `record_intent` 因临时数据库错误抛异常，`dispatched` 保持 `false`、Telegram `update_id` 已被生产者侧推进 offset（Telegram 不会重投）。恢复路径依赖**调度器 failed 批次重试扩展**（见下方「前置依赖」节），M8 Telegram 适配器只负责渠道接入（long-poll 接收、持久化、offset 管理、发送），不实现调度器扩展。适配器通过标准 `Bus#publish` 入总线，由调度器扩展保证恢复语义。
   - **入站 `event_id` 派生规则（确定性，含内容指纹）**：Telegram 入站消息的 `event_id` **唯一形式**为 `tg:<account_id>:<sha256(update_id || ":" || content_fingerprint)>`——同时纳入 `update_id` 与 `content_fingerprint`。原因：Telegram 空闲重置后可能再次分配相同的 `update_id`，纯 `(account_id, update_id)` 派生会让内容不同的两条 update 得到相同 `event_id`，消费者 `record_intent` 用 `INSERT OR IGNORE` 会忽略新消息、且 Step 3 已标 `dispatched=true`，启动恢复也不会再投递，新消息被静默跳过。加入内容指纹后：
     - 同一条 update（同 `update_id` + 同内容）在所有投递路径上得到相同 `event_id`；
     - 内容不同的 update 即使 `update_id` 相同也得到不同 `event_id`，不会被 intent 排重忽略；
     - 启动恢复路径用持久化行的 `update_id` 与 `content_fingerprint` 按同一规则重建 `event_id`，与原投递路径同值；
     - 消费者按 `event_id` 做提交级排重（已有先例：`src/platform/cli/gateway.cr` 与 `src/platform/store/store.cr` 的 intent 落库路径——非重放路径中已存在的 intent 直接返回，不再派发），**同一条 update 被处理一次**；
     - 出站幂等键由 `event_id` 派生（`src/tools/executor.cr` 发消息工具实现），同一条 update 触发的发消息动作也不会重复。
   - **启动恢复**：每次启动轮询循环前，先扫 `telegram_updates` 里 `dispatched=false` 且 `status != 'dead_letter'` 的行，按 update_id 升序重建消息（`event_id` 按上述含指纹规则派生）、经 **`Bus#publish`** 重新入总线（走正常 admission → dispatch 流程，不绕过会话调度器的串行约束）。这样「Step 1 落库后崩溃、Step 2/3 未执行」「Step 3 入总线成功但消费者尚未 `record_intent` 就崩溃」两个窗口都能恢复，且不依赖 Telegram 重推（Telegram 在 Step 2 已确认）。intent 落库之后的崩溃由既有重放规则覆盖。
   - **已有 admission 的恢复记录补确认**：若进程在 `record_intent` 成功后、确认回调前崩溃，重投会在正常 admission 的 `session_inputs` 查重处返回 `duplicate`，不会进入 `process_message` 的已有 intent 分支；既有 intent 重放使用 `replay=true`，也不执行该分支。此时 `dispatched` 可能一直为 `false`。补确认路径：**在 `admit` 返回 `duplicate` 的分支中，先检查该 `event_id` 对应的 intent 是否已持久化**——`intents` 表中存在该 `event_id` 且状态为 `done` 或 `dispatched` 才置 `telegram_updates.dispatched=true`；**不存在时保留 `dispatched=false`**，由调度器扩展的恢复路径处理（不提前确认，避免 `record_intent` 失败后无法被扫描恢复）。此操作在 `admit` 内部完成，不绕过会话串行约束（`admit` 本身就在调度器上下文中执行）。同时，在 `replay_unfinished` 完成后的 `recover_dispatch` 中，对 replay 涉及的所有 `event_id` 统一检查 intent 持久化状态后补置 `telegram_updates.dispatched=true`。
   - **单调排重保留**：`update_id > persisted_offset` 才进入 Step 1，等于或小于直接跳过（同 update_id 重推场景由内容指纹唯一索引兜底，不会重复落库）。
   - **非空响应到达即更新空闲基准**：收到非空响应时先把 `last_update_at` 持久化为该响应到达时刻，再执行 Step 1–3，不得推迟到退出重置模式时。空响应不刷新——活跃模式空轮询收到空数组时不更新 `last_update_at`，确保连续空闲能达到 6 天重置阈值。
2. **空闲检测与重置模式状态**：每次启动轮询循环前读 `last_update_at`，若距今 ≥ **6 天**（留 1 天安全边际，官方阈值是「至少一周」）则进入**重置模式**。重置模式另需持久化状态位 `telegram_accounts.reset_mode`（布尔，默认 false）：进入时置 true，退出时与 `persisted_offset` 同事务置 false。启动判定为 `reset_mode = true OR last_update_at 距今 ≥ 6 天`——**只看 `last_update_at` 不够**：重置模式下收到较小 `update_id` 的非空响应会先把 `last_update_at` 刷成当前时刻，若此时在 update 落库前崩溃，重启后 `last_update_at` 是近期值，会被误判为活跃窗口并用旧 offset 轮询，该较小 ID 的 update 被确认后丢失，而启动恢复只扫已落库行、无法补回。`reset_mode` 为 true 时重启后继续无 offset 轮询，直到退出条件满足、该模式下收到的 update 全部持久化并入总线。
3. **重置模式轮询（持续到收到新 update 才退出）**：调用 `getUpdates()` **不传 offset**（拉取未确认的全集）。对返回的每条 update 走「活跃窗口 Step 1–3」（持久化 → 入总线，暂不推进 offset）。**只有满足下述退出条件才离开重置模式**：
   - **退出条件**：本轮**至少收到 1 条 update 且全部持久化 + 入总线成功**后，才在**同一事务内**把 `persisted_offset` 重置为本轮最大 `update_id`、把 `reset_mode` 置 false，下一轮回到活跃窗口逻辑（带 offset 轮询）；两步分开写会留下「offset 已推进但 `reset_mode` 仍为 true」的半完成态。`last_update_at` 已在非空响应到达时更新，此处不得再次刷新，避免处理耗时改变空闲计时。
   - **空轮询不退出**：若本轮 `getUpdates()` 返回空数组，**继续保持重置模式**——不重置 offset、不更新 `last_update_at`、不切换回活跃窗口。下一轮仍用无 offset 轮询，直到收到至少 1 条新 update。原因：空轮询时若恢复旧 offset，bot 空闲超过一周后的较小新 ID 仍会被确认跳过，与本策略目的直接冲突。
   - **重置模式与活跃窗口的持久化口径一致**：每一步都先持久化、再入总线，崩溃恢复路径与活跃窗口共用同一「扫 `dispatched=false` 重投」逻辑。
4. **拒绝跳过新消息**：任何路径下，`getUpdates` 的 `offset` 参数都必须 ≥ 已确认的 `persisted_offset+1`，不允许因为「新值比旧值小」就跳过；重置模式通过内容指纹而非 offset 比较保证幂等。
5. **store 表新增字段**：`telegram_accounts.last_update_at`（UTC instant）与 `telegram_accounts.reset_mode`（布尔，默认 false，标记重置模式是否跨崩溃延续）、`telegram_updates(content_fingerprint, account_id, update_id, raw_payload, dispatched, status, retry_count, bus_publish_timeout_count, created_at)`，`(content_fingerprint, account_id)` 唯一索引（指纹维度用于跨重置周期排重），`dispatched` 布尔标记用于启动时与周期扫描未投递行做恢复，`status` 枚举值 `'pending' | 'dead_letter'`（默认 `'pending'`）用于 dead-letter 排除，`retry_count` 用于 `max_dispatch_retries` 上限控制（仅 `record_intent` 失败计数），`bus_publish_timeout_count` 用于 bus 饱和观测与告警（不影响消息生命周期）。

> 该策略参考 Telegram 官方 Bot API 文档「getUpdates」节对 `update_id` 的明确约束，并在 [plan/wbs/m8-channels.md §M8.1-WP3 验收](../plan/wbs/m8-channels.md) 落地为可测验收条目。

#### 前置依赖：调度器 failed 批次重试扩展（独立 WP）

Telegram 适配器的「`record_intent` 失败的运行期恢复」依赖 SessionScheduler 支持 `failed → queued` 状态迁移与重派触发器。这些属于**调度器本身的设计演进**，不在 M8 渠道接入范围内。M8 开工前，以下调度器扩展必须已完成（由独立 issue 跟踪，建议挂在 M4x 并行轨或 M5 主线）：

- **扩展点 1 · `SessionScheduler#retry_failed_batch(batch_id)`**：批次内所有成员都是「无 intent 失败」（`intents` 表中无该 `event_id` 行）时，允许 `failed → queued` 迁移；`retry_failed_batch` 只在 `@running_batch.nil?` 且同会话无 `running` 批次时执行（保持会话串行约束）。**混合批次处理**：若批次中部分成员已有 intent、部分成员无 intent 失败，`retry_failed_batch` 只迁移无 intent 失败的成员回 `queued`，已有 intent 的成员保持原状态（由 `replay_unfinished` 覆盖）；批次状态迁移以「所有无 intent 失败成员已迁回 queued」为准。
- **扩展点 2 · 重试成员状态流转**：无 intent 失败成员从 `failed` 重新排队后，由 `dispatch_locked` 推进至 `dispatched`，`batch_done` 能结算其成功完成或再次失败的结果。**混合批次执行体过滤**：`run_batch_job` 只处理本次迁回 `queued` 的无 intent 失败成员——已有 intent 的成员（`intents` 表中该 `event_id` 状态为 `done` 或 `dispatched`）**不纳入本次执行体**，避免其被重复计为失败；`batch_done` 结算也仅依据这些待重试成员的结果，已有 intent 成员通过 `replay_unfinished` 独立恢复。
- **扩展点 3 · queued 批次重派触发器**：`dispatch_locked` 在 `@dispatch.call` 抛异常后把批次回退为 `queued` 时，需要显式重派触发器（周期扫描调用调度器派发入口，或仅依赖后续事件/启动恢复）。
- **扩展点 4 · 启动屏障**：`Gateway#recover_dispatch` 在 `replay_unfinished` 完成后、适配器启动前设置 `@replay_completed = true`；扫描器在屏障前跳过 dispatch 触发，避免旧重放与新派发并发执行。

M8 Telegram 适配器只负责**渠道接入**（long-poll 接收、持久化、offset 管理、发送），**不实现上述调度器扩展**。适配器通过标准 `Bus#publish` 入总线，由调度器扩展保证恢复语义。

### 4.3 TokenProvider 与凭据

- Slack 的 `app_token` / `bot_token` 是长期凭据，无 refresh 概念；失效凭人工在 api.slack.com 后台重置。TokenProvider 抽象在 Slack 适配器退化为「从 keyring 读取并缓存」，无临期刷新逻辑。
- Telegram 的 `bot_token` 同理，长期凭据。
- 两者都按 `(channel_type, account_id)` 命名空间存 keyring（§10 安全）。
- 限流：
  - Slack Web API：按方法分级 Tier 1–4（如 `chat.postMessage` 每秒每 workspace ~1 条 + 突发）。token bucket 按 `(account_id, method, target)` 建桶。
  - Telegram Bot API：单群每秒 1 条、单用户每秒 1 条、全局每秒 30 条（官方 FAQ）。token bucket 按 `(account_id, chat_id)` 建桶。

### 4.4 发送侧幂等（沿用 §5 + Pi 教训）

- Slack：`chat.postMessage` 的幂等键 `send:slack:<account_id>:<channel>:<client_msg_id>`（客户端生成 UUID），复用 Sebas 已有的 intent 幂等表。
- Telegram：`sendMessage` 不支持服务端幂等键，客户端幂等键 `send:telegram:<account_id>:<chat_id>:<client_msg_id>`，崩溃恢复时**默认不重放**（沿用 design.md §11.2④ 的副作用幂等纪律——发送类动作 outcome_unknown 不自动重放）。

### 4.5 Binding 路由

沿用 design.md §3.4 most-specific 优先级：

```
exact peer > parent peer > peer wildcard > guild+roles > guild > team > account > channel > fallback(owner)
```

Slack 的 `guild` 对应 `team_id`，Telegram 没有对应概念（跳过该层）。

### 4.6 出站群机器人形态

Slack Incoming Webhooks、Telegram 群通知（`sendMessage` 直接发到 chat_id）都属于单向出站，与现有企微/飞书自定义机器人一致；M8 不需要新增机制，账号 CRUD 即可覆盖。

## 5. 风险与未验证项

| 项 | 风险 | 缓解 |
|---|---|---|
| Slack Socket Mode 在国内不可达 | 网络环境依赖 | 文档明示需科学上网；`degraded` 状态上报管理面 |
| Telegram Bot API 在国内不可达 | 同上 | 同上；提供 `api_base_url` 账号级配置以支持自建反代 |
| Slack 限流分级表 | 未逐页核对 | 实现前补研官方 rate-limits 页，按 Tier 实现通用 token bucket |
| Telegram long-poll offset 持久化 | 进程重启 offset 丢失会重拉旧消息 | offset 落 store，启动时读取；已 ACK 的 update_id 排重 |
| 多账号并发接收 | Slack 单 app 单 Socket Mode 连接数上限（默认 50） | 每账号一连接；同账号不重复启动 |
| Crystal WebSocket 客户端成熟度 | Crystal 标准库 `HTTP::WebSocket` 已稳定 | M0 已有 WebSocket 用例（飞书）；Socket Mode 协议字段为 JSON，无新序列化负担 |

## 6. 验收（设计评审口径）

- [ ] 配置树与 §3.4 一致，无新原语
- [ ] 接收形态归并进 §5.2 长连接型，无第三类形态引入
- [ ] TokenProvider 抽象在 Slack/Telegram 退化为「无刷新」形态，不破坏 WeCom/Lark 已有临期刷新逻辑
- [ ] session_key 五段不动，`channel_type` 新增枚举值 `slack` / `telegram`
- [ ] 幂等键与既有 email/wecom/lark 命名空间一致
- [ ] 单文件不超 400 行约束覆盖两个新适配器

## 7. 实施拆解

详见 [plan/wbs/m8-channels.md](../plan/wbs/m8-channels.md)（本文只列设计决策，不重复 WBS）。

## 8. 来源

- [research/hermes-agent.md](../research/hermes-agent.md) §4.1–§4.2、§8.4（21+ 平台矩阵、profile 隔离、per-credential 轮询 vs port-binding webhook）
- [research/openclaw.md](../research/openclaw.md) §2.1、§3（33 渠道目录、17 多账号清单、配置树 `channels.<channel>.accounts.<accountId>`）
- [spec/05-multi-account.md](../spec/05-multi-account.md) §5.1–§5.3（账号生命周期、接收形态归并、TokenProvider、限流桶）
- [spec/10-security.md](../spec/10-security.md)（凭据 keyring 命名空间）
