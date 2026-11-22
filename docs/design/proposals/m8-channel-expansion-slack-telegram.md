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
   - **Step 2 · 推进 offset**：持久化成功（含唯一索引冲突被视为已持久化）后，才把 `persisted_offset = update_id` 落库；下次 `getUpdates(offset=persisted_offset+1)` 才确认旧值。**绝不在持久化前推进 offset**——否则崩溃后 Telegram 已确认、本地无记录，静默丢消息。
   - **Step 3 · 入总线 + 消费者确认**：把该 update 投递到 bus。**`Bus#publish` 成功返回 ≠ 处理完成**——`Bus#publish` 只把事件写入进程内存 Channel，没有落盘或确认机制；消费者在接收事件后才调用 `record_intent` 把 intent 写入 intents 表。因此 `dispatched=true` 的置位必须由**消费者侧**发起：
     - 消费者 `process_message` 在 `record_intent` 落库成功后，回调 Telegram adapter 把对应 `telegram_updates.dispatched` 置 `true`；
     - **已有 intent 分支也要确认**：若消费者 `process_message` 在 `record_intent` 时发现已有持久化 intent（`INSERT OR IGNORE` 返回 false）而提前返回，**也必须**回调把对应 `telegram_updates.dispatched` 置 `true`——否则启动恢复会重投该行，消费者又走「已有 intent」分支提前返回，永远卡在 `dispatched=false`，每次启动都被重复重投。
     - 生产者在 `Bus#publish` 返回后**不置位**——`dispatched` 仍为 `false`，直到消费者确认；
     - 已标 `dispatched=true` 的行不得再次入总线。
   - **`record_intent` 失败的运行期恢复**：若消费者 `record_intent` 因临时数据库错误抛异常，`dispatched` 保持 `false`、Telegram `update_id` 已被生产者侧推进 offset（Telegram 不会重投），现有 `process_message` 捕获该异常只记录日志、不重试。提案采用「**周期性扫描 + 重启兜底**」双路恢复：
     - **周期扫描**：消费者进程内每 **60 秒**扫一次 `telegram_updates.dispatched=false` 且 `created_at < now() - 30s` 的行（30 秒豁免避免与正常 in-flight 冲突），按 update_id 升序重建消息、经非重放路径入总线（让 intent 排重生效）——`record_intent` 已成功的行会走「已有 intent」分支被确认，新失败的行会重试 `record_intent`。
     - **重启兜底**：进程重启时同样扫 `dispatched=false`（见下方启动恢复）——双路合流，任何路径下 `dispatched=false` 的行都会在**最迟 90 秒内**被重新处理（周期扫描 60s + 30s 豁免）。
     - **明确延迟上限**：在不重启的前提下，一次 `record_intent` 失败的消息**最多延迟 90 秒**就会被重新处理；多次连续失败会被周期性扫描反复重试，直到成功或达到重试上限 `max_dispatch_retries = 20`（超出后转入 `dead_letter` 状态、上报管理面告警、不再重试）。
   - **入站 `event_id` 派生规则（确定性，含内容指纹）**：Telegram 入站消息的 `event_id` **唯一形式**为 `tg:<account_id>:<sha256(update_id || ":" || content_fingerprint)>`——同时纳入 `update_id` 与 `content_fingerprint`。原因：Telegram 空闲重置后可能再次分配相同的 `update_id`，纯 `(account_id, update_id)` 派生会让内容不同的两条 update 得到相同 `event_id`，消费者 `record_intent` 用 `INSERT OR IGNORE` 会忽略新消息、且 Step 3 已标 `dispatched=true`，启动恢复也不会再投递，新消息被静默跳过。加入内容指纹后：
     - 同一条 update（同 `update_id` + 同内容）在所有投递路径上得到相同 `event_id`；
     - 内容不同的 update 即使 `update_id` 相同也得到不同 `event_id`，不会被 intent 排重忽略；
     - 启动恢复路径用持久化行的 `update_id` 与 `content_fingerprint` 按同一规则重建 `event_id`，与原投递路径同值；
     - 消费者按 `event_id` 做提交级排重（已有先例：`src/platform/cli/gateway.cr` 与 `src/platform/store/store.cr` 的 intent 落库路径——非重放路径中已存在的 intent 直接返回，不再派发），**同一条 update 被处理一次**；
     - 出站幂等键由 `event_id` 派生（`src/tools/executor.cr` 发消息工具实现），同一条 update 触发的发消息动作也不会重复。
   - **启动恢复**：每次启动轮询循环前，先扫 `telegram_updates` 里 `dispatched=false` 的行，按 update_id 升序重建消息（`event_id` 按上述含指纹规则派生）、经**非重放路径**重新入总线（让 intent 排重生效）。这样「Step 1 落库后崩溃、Step 2/3 未执行」「Step 3 入总线成功但消费者尚未 `record_intent` 就崩溃」两个窗口都能恢复，且不依赖 Telegram 重推（Telegram 在 Step 2 已确认）。intent 落库之后的崩溃由既有重放规则覆盖。
   - **单调排重保留**：`update_id > persisted_offset` 才进入 Step 1，等于或小于直接跳过（同 update_id 重推场景由内容指纹唯一索引兜底，不会重复落库）。
   - `last_update_at` 在 Step 2 同步落库。
2. **空闲检测**：每次启动轮询循环前，读 `last_update_at`；若距今 ≥ **6 天**（留 1 天安全边际，官方阈值是「至少一周」），进入**重置模式**。
3. **重置模式轮询（持续到收到新 update 才退出）**：调用 `getUpdates()` **不传 offset**（拉取未确认的全集）。对返回的每条 update 走「活跃窗口 Step 1–3」（持久化 → 入总线，暂不推进 offset）。**只有满足下述退出条件才离开重置模式**：
   - **退出条件**：本轮**至少收到 1 条 update 且全部持久化 + 入总线成功**后，才把 `persisted_offset` 重置为本轮最大 `update_id`，把 `last_update_at` 更新为当前时刻，下一轮回到活跃窗口逻辑（带 offset 轮询）。
   - **空轮询不退出**：若本轮 `getUpdates()` 返回空数组，**继续保持重置模式**——不重置 offset、不更新 `last_update_at`、不切换回活跃窗口。下一轮仍用无 offset 轮询，直到收到至少 1 条新 update。原因：空轮询时若恢复旧 offset，bot 空闲超过一周后的较小新 ID 仍会被确认跳过，与本策略目的直接冲突。
   - **重置模式与活跃窗口的持久化口径一致**：每一步都先持久化、再入总线，崩溃恢复路径与活跃窗口共用同一「扫 `dispatched=false` 重投」逻辑。
4. **拒绝跳过新消息**：任何路径下，`getUpdates` 的 `offset` 参数都必须 ≥ 已确认的 `persisted_offset+1`，不允许因为「新值比旧值小」就跳过；重置模式通过内容指纹而非 offset 比较保证幂等。
5. **store 表新增字段**：`telegram_accounts.last_update_at`（UTC instant）、`telegram_updates(content_fingerprint, account_id, update_id, raw_payload, dispatched, retry_count, created_at)`，`(content_fingerprint, account_id)` 唯一索引（指纹维度用于跨重置周期排重），`dispatched` 布尔标记用于启动时与周期扫描未投递行做恢复，`retry_count` 用于 `max_dispatch_retries` 上限控制。

> 该策略参考 Telegram 官方 Bot API 文档「getUpdates」节对 `update_id` 的明确约束，并在 [plan/wbs/m8-channels.md §M8.1-WP3 验收](../plan/wbs/m8-channels.md) 落地为可测验收条目。

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
