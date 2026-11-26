# development-plan M8 · 渠道补齐（WeCom + Lark + Slack）（17–28.5 pd）

> 导航：[设计总览](../../design.md) ｜ [文档索引](../../README.md) ｜ [计划总览](../../development-plan.md) ｜ 上一节：[M7](m7-projection.md)

### M8 · 渠道补齐（WeCom + Lark + Slack）——估时合计 17–28.5 pd（2026-11-23 追加，2026-11-26 重定范围，v0.6.0）

> 依据：[proposals/m8-channel-expansion-slack-telegram.md](../../proposals/m8-channel-expansion-slack-telegram.md)（本文档只做工作包、依赖、估时与验收；**不新造设计决策**——语义有变更回写提案与 design.md，不在本计划内定）。
> **2026-11-26 范围调整（Maintainer 裁决）**：①企业微信、飞书相关功能与任务迁入本 milestone——M1-WP4/WP5 只交过协议层与 spec，生产装配从未发生（`spawn_adapters` 仅遍历 email），真实账号集成验收一直挂 E.1 未闭环；②Telegram 相关任务迁出至 milestone `M3 · Telegram 渠道补位`（见 [m3-collab-plugins.md](m3-collab-plugins.md) 追加包 M3-WP7/WP8）。期名由「渠道扩展」改为「渠道补齐」。
> 期定位：把 Email 之外的三个渠道补到「生产可跑 + 真机验过」：企微自建回调、企微 AIBot 长连接、飞书 WS 长连接，外加新渠道 Slack。适配层复用 §5 的「账号生命周期监督 fiber + TokenProvider + 限流桶 + 接收形态归并」骨架，不引入新原语。
> 期门禁：标准四条（`make format-check` + `make spec` + `make lint` + `make release`）。M8.0-WP1 为纯文档包豁免命令门禁（评审通过即可）；其余 WP 不豁免。
> 开工三闸：在 active milestone 内 / WP 依赖前置已有完成证据 / 外部依赖就绪（E.1 见下）。

**外部依赖（E.1）**：

| 编号 | 依赖项 | 就绪时点 | 说明 |
|---|---|---|---|
| #21 | 企微测试企业 + 应用/机器人 + 可信 IP（含出口 IP 固定） | M8.1-WP2/WP3 真机段前 | 用户侧动作；可信 IP 需已认证企业 + 可信域名先行 |
| #22 | 飞书自建应用（至少 2 个，多账号验收用） | M8.1-WP4 真机段前 | 用户侧动作；WS 形态仅自建应用可用 |
| E.1#13 | Slack workspace + Slack App（Socket Mode enabled）×2 | M8.1-WP5 开工前 | 用户侧动作；见 [risks.md](../risks.md) E.1#13 |
| E.1#14 | 科学上网环境（CI 不需要，仅本地实测需要） | Slack 验收前 | Slack 公网端点国内不可达；E.1#14 |

---

**M8.0-WP1 提案评审与回写定稿**（0.5–1 pd）
- 目标：提案 [m8-channel-expansion-slack-telegram.md](../../proposals/m8-channel-expansion-slack-telegram.md) 评审修订并回写 design.md。
- 范围：评审 §2 候选矩阵、§3 首期范围、§4 设计要点、§5 风险；回写 [spec/02-goals-non-goals.md](../../spec/02-goals-non-goals.md) §2.1 渠道清单、[spec/05-multi-account.md](../../spec/05-multi-account.md) §5 追加 §5.7 Slack 接入方案、[spec/14-roadmap.md](../../spec/14-roadmap.md) 追加 M5–M8 行（与 M5/M6/M7 同步回写，避免再次欠账）。
- 交付物：提案定稿版 + 三处 spec 修订。
- 依赖：无。
- 验收：评审通过；§14 含 M8 期验收条目；`ruby tools/check_docs.rb` FAIL=0。
- 风险：评审若推翻首期范围（如改首批为 Discord），后续 WP 链整体调整——估时按下限单轮计。[推演]

**M8.1-WP1 ChannelAdapter 抽象层核对与最小扩展点定稿**（0.5–1 pd；对应 #235）
- 目标：确认 Slack 接入所需的扩展点；**不重写抽象**，只补必要字段。Telegram 侧的同类核对已随 Telegram 迁至 M3-WP7，本包只处理双 token 形态。
- 范围：核对 `abstract class ChannelAdapter` 的方法集（`start` / `stop` / `send` / `health`）；核对入站/出站字段是否覆盖 Slack 的 `team_id/channel/ts`；若缺则补字段（新字段必须非破坏，旧适配器零改动通过）；配置 schema 加 `channels.slack.accounts[]` 校验规则。
- 交付物：扩展点设计稿 + spec 校验规则 + 现有 email/wecom/lark 适配器回归通过证据。
- 依赖：M8.0-WP1。
- 验收：`crystal spec` 全绿（含旧三渠道回归）；新配置 schema 拒绝缺 `bot_token` 的 Slack 账号。
- 风险：M1 抽象若已假定「每渠道至多一个 token 类型」，Slack 的 `app_token + bot_token` 双 token 会顶破假设——扩展点必须支持命名凭据集（map of tokens），不能沿用单 token 字段。[推演]

**M8.1-WP2 企微自建应用回调生产接线**（3–5 pd；对应 #232）
- 目标：让 `WecomCallbackAdapter` 真正跑在 gateway 里。M1-WP4 的 `crypto.cr` + `app_callback.cr` 与 6 个 spec 已在库，但生产装配从未发生。
- 范围（装配与路由）：`spawn_adapters` 装配 `app-callback` 账号，`apply_config` 账号增删分支按 `CHANNEL_TYPES` 处理 wecom；`/cb/wecom/<account_id>` 路由与 `callback_path` 对齐（与 lark 共用一套规则）。
- 范围（出站与解析）：注入 `WecomTokenProvider`；`send` 实装 `POST /cgi-bin/message/send`（`agentid` 必填、`touser` ≤1000、幂等键透传）；回调体外层报文按 XML 取 `encrypt`（保留 JSON 兼容不破坏既有 spec）；`errcode=60020` 转 typed error 并显式上报。
- 交付物：装配 + 路由 + token + send + XML 解析 + 热更新，五项各带 spec。
- 依赖：M8.1-WP1（共用适配层扩展点）。
- 验收：配置含 app-callback 账号时启动后 registry 可查到；`POST /cb/wecom/<account>` 走完验签→解密→receiveid→msgid 排重→入总线，重复投递 200 但不二投；mock server 断言 `message/send` 请求体含 `agentid`；`60020` 转 typed error 且日志脱敏；运行中加/删账号不重启生效。真机段（依赖 #21）单列：URL 验证 1 秒回显、POST 5 秒内响应、跨企业密文 403；未实测时卡面列「未实测」。
- 风险：回调体是 XML 而现实现按 JSON 解析——真机会落通用 rescue 的 500；本包须先以真机抓包确认再改。[推演]

**M8.1-WP3 企微 AIBot 长连接主路**（3–5 pd，含开工首日核对 0.5–1 pd；对应 #233）
- 目标：`cmd=aibot_msg_callback` / `cmd=aibot_event_callback` 出站长连接接收，回透传 `headers.req_id`。
- 范围（核对）：**开工首日逐页核对 AIBot 官方接口**（握手帧、心跳、`cmd` 分发、回复帧、主动发消息），产出 10 行 demo 并回写 [spec/15-risks.md](../../spec/15-risks.md) 未验证 #1。
- 范围（实现）：`src/channels/wecom/aibot_longconn.cr` 建连/心跳/退避 5s→60s/凭据指纹 park；`cmd` 分发入 `InboundMessage`（peer 取 `chatid`，`from.userid` 为加密值时经应用接口转换）；多媒体按消息内 `aeskey` 下载；`msgid` 排重落 store memo；`spawn_adapters` 按 `mode: aibot-longconn` 装配且与 app-callback 互斥。
- 交付物：核对报告 + 长连接适配器 + mock WSS spec + 真机报告。
- 依赖：M8.1-WP2（共用装配点、路由、排重 memo、TokenProvider 注入点，先落一套再扩展）。
- 验收：mock WSS 单账号入总线且会话键含 account 维度；两账号同 peer 不串扰；心跳超时按 5s→60s 退避重连且不重放已消费消息；回复帧字段齐全。真机段（依赖 #21 + 机器人）单列。
- 风险：**AIBot 主动发消息 API 官方页未逐页核对**（§15.1 未验证 #1）——若形态与调研不符，按原口径把回调备选升级为主路，估时内含不扩期；本包范围相应收窄为「核对结论 + 风险回写」。

**M8.1-WP4 飞书/Lark 生产接线**（4–6 pd，含 WS 帧协议核对；对应 #234）
- 目标：WS 长连接主路 + `LarkCallbackAdapter` 装配 + 出站实装。
- 范围（接收）：`src/channels/lark/ws_longconn.cr` 逐帧对照官方 SDK 核对后实现（事件 id 排重、3 秒处理、单应用 ≤50 连接、`base_url` 取账号 `platform`，混用报 `1000040351`）；`spawn_adapters` 按 `receive` 装配 WS 或 webhook。
- 范围（出站与装配）：`im/v1/messages` + token bucket（`(account_id, chat_id)` 5 次/秒）+ `230020` 退避；注入 `LarkTokenProvider`（现有实现无调用者）；Header 预留 4KB（§15.2.19）；账号增删走 `CHANNEL_TYPES`。
- 交付物：WS 适配器 + 装配 + 出站 + mock 双账号 spec + 真机报告。
- 依赖：M8.1-WP1。
- 验收：mock WS 下两账号（`feishu.cn` / `larksuite.com` 各一）事件各自入会话不串扰；重复 `event_id` 不二投；入总线即返回（3 秒约束）；mock `im/v1/messages` 断言 tenant token header 与请求体；运行中加 lark 账号不重启生效。真机段（依赖 #22）单列。
- 风险：WS 帧协议细节依赖官方 SDK 对照，若 Crystal 侧无可用 WS 客户端需退化为 webhook 备选，估时不变但真机验收依赖公网 URL。[推演]

**M8.1-WP5 Slack 适配器：Socket Mode 接收 + Web API 发送**（3–4.5 pd；对应 #141）
- 目标：跑通 Slack 多账号收发。
- 范围：
  - `src/channels/slack/` 目录：adapter.cr / socket_mode.cr / web_api.cr / markdown.cr；
  - Socket Mode 连接：`apps.connections.open` 换 WSS endpoint → 建立 WebSocket → 收 `events_api` envelope → **先落库（含 envelope 原文与 `event_id` 唯一索引）→ 再按 `envelope_id` 发 ACK → 再入总线**（沿用 §5.2「回调 fiber 只验签+落库+入总线」纪律；顺序修正原因：若 ACK 早于落库，进程在 ACK 后、落库前崩溃会静默丢消息——Slack 已收到确认不再重推，本地无记录）；
  - **ACK 后崩溃恢复**：`slack_events` 表（`event_id, account_id, envelope_id, raw_payload, dispatched, created_at`）——落库时 `dispatched=false`，入总线后消费者 `record_intent` 成功回调置 `dispatched=true`；启动时扫 `dispatched=false` 行经 `Bus#publish` 重投（走正常 admission → dispatch 流程，不绕过会话调度器的串行约束）；
  - 排重：`event_id` 唯一索引；
  - 发送：`chat.postMessage` + token bucket（按 `(account_id, method, channel)` 建桶，Slack Tier 2 起步 ~1 msg/s）；
  - TokenProvider 退化为「从 keyring 读取缓存」（无 refresh）；
  - 限流 429 响应处理：读 `Retry-After` 头退避；
  - 多账号：每账号一连接一 fiber，配置增删走 §11 热更新（不重写热更新机制，直接复用）。
- 交付物：Slack 适配器 + 接收/发送 spec（用 vcr/webmock 风格 fixture）+ 单账号本地实测报告。
- 依赖：M8.1-WP1；E.1#13（Slack workspace + App）；E.1#14（科学上网，验收依赖）。
- 验收：
  - 两账号同时 online，互不串扰（A 收的 message 不会进 B 的 session）；
  - 同账号同 `event_id` 重推被排重；
  - 发送触发 429 后按 `Retry-After` 退避，不丢消息；
  - 进程强杀重启后 offset 恢复，未 ACK 的 envelope 重推可被消费；
  - **ACK 后、入总线前强杀进程**：用 fault-injection 在 ACK 帧发出后立即 `kill -9`，重启后从持久化记录恢复该事件并入总线（不依赖 Slack 重推，因为 Slack 已收到 ACK）——验证「先落库再 ACK」顺序真的挡住了静默丢失窗口。
- 风险：Crystal `HTTP::WebSocket` 客户端长连接稳定性——若发现 keepalive 不足，退化为「心跳超时后主动断线重连」。[推演]

**M8.2-WP1 管理面与运维闭环**（1.5–2 pd；对应 #143）
- 目标：WeCom/Lark/Slack 账号纳入 TUI/HTTP 双入口管理。
- 范围：`accounts.create/list/disable/enable/rotate-credential` 对四渠道生效；健康上报（连接状态、最近 event 时刻、限流水位）经管理面可查（沿用 §5.1 第 5 项职责）；`sebas channels probe` 自检命令。
- 交付物：管理面命令 + spec + TUI 截图。
- 依赖：M8.1-WP2、M8.1-WP4、M8.1-WP5。
- 验收：`sebas accounts list` 输出四渠道账号状态；`sebas accounts disable <id>` 后该账号 fiber 优雅停止；`sebas channels probe` 报告可达性。
- 风险：TUI 现有代码若硬编码渠道枚举需要逐一展开——必须改为遍历 adapter registry。[推演]

**M8.2-WP2 文档、示例与发布准备**（1.5–2.5 pd；对应 #144）
- 目标：让用户能照着文档接入 WeCom / Lark / Slack 账号。
- 范围：
  - README 渠道矩阵补齐；
  - `docs/examples/` 新增 `wecom-callback.yaml` / `lark-bot.yaml` / `slack-bot.yaml` 示例配置；
  - `docs/design/spec/05-multi-account.md` §5.7 Slack 写作落档（M8.0-WP1 是占位，此包填实）；§5.5/§5.6 补齐生产接线后的实际行为；
  - 限流数字、接收形态、排重字段的核实引用补全；
  - 版本号同步：`shard.yml` + `src/version.cr` → v0.6.0。
- 交付物：文档 + 示例 + 版本号修订。
- 依赖：M8.2-WP1、M8.1-WP3（期级验收要求「企微 AIBot 长连接跑通」，v0.6.0 不得在该能力缺席时发版；管理面包 M8.2-WP1 不依赖 AIBot，保持原样）。
- 验收：`ruby tools/check_docs.rb` FAIL=0；新用户按 README 配置示例即可启动；`make release` 全绿。
- 风险：文档与代码漂移——发布前 Verifier 逐条对照示例配置字段名与代码 schema。[推演]

---

## 期级验收主线（M8）

- 同渠道 N 账号并存：WeCom 2 账号 / Lark 2 账号 / Slack 2 账号分别验，互不串扰（继承 M1 期级验收主线）。
- 长连接形态覆盖：企微 AIBot 长连接 + 飞书 WS 长连接 + Slack Socket Mode 都跑通，无新增公网 IP 依赖。
- TokenProvider 抽象未破坏：现有临期刷新路径回归通过。
- 配置热更新覆盖新渠道：运行中增/删/改账号不需重启（当前实现仅 email，四渠道均需补齐）。
- 标准四条全绿 + `ruby tools/check_docs.rb` FAIL=0。

## DAG

```
M8.0-WP1 ──> M8.1-WP1 ──┬──> M8.1-WP2 (企微回调) ──> M8.1-WP3 (企微 AIBot) ──┐
                        ├──> M8.1-WP4 (飞书 WS) ──┐                          │
                        └──> M8.1-WP5 (Slack) ────┤                          │
                                                 └──> M8.2-WP1 ─────────────┤
                                                                             │
                                             M8.2-WP2 <─────────────────────┘
#21 ─────────────────────> M8.1-WP2 / WP3 真机段
#22 ─────────────────────> M8.1-WP4 真机段
E.1#13 / E.1#14 ─────────> M8.1-WP5
```

边义：`{M8.1-WP2, M8.1-WP4, M8.1-WP5} → M8.2-WP1`；`{M8.2-WP1, M8.1-WP3} → M8.2-WP2`。

发布包 M8.2-WP2 依赖 `M8.2-WP1` **与** `M8.1-WP3`：期级验收要求企微 AIBot 长连接跑通，而 M8.2-WP1 的依赖链不含 WP3，若不显式加边，v0.6.0 会在 AIBot 缺席时完成发布准备。

跨期依赖：M8 开工需 M5–M7 主线已收尾（v0.5.0 已发），且 M4x 并行轨无阻断。Telegram 两张卡已迁至 M3 轨道，不再属本图。

## 估时合计

| 包 | 下限 | 上限 |
|---|---|---|
| M8.0-WP1 | 0.5 | 1 |
| M8.1-WP1 | 0.5 | 1 |
| M8.1-WP2 企微回调 | 3 | 5 |
| M8.1-WP3 企微 AIBot | 3 | 5 |
| M8.1-WP4 飞书 WS | 4 | 6 |
| M8.1-WP5 Slack | 3 | 4.5 |
| M8.2-WP1 | 1.5 | 2 |
| M8.2-WP2 | 1.5 | 2.5 |
| **合计** | **17** | **27** |

**卡片对应（2026-11-26 复核）**：M8.0-WP1 → #139（`kind=design`，Scribe 执行）；M8.1-WP1 → #235；M8.1-WP2 → #232；M8.1-WP3 → #233；M8.1-WP4 → #234；M8.1-WP5 → #141；M8.2-WP1 → #143；M8.2-WP2 → #144。八张卡均带 Automation 块与原生 blocked_by，`M8.1-WP1` 为其余四个实现包的共同前置。

原表（Slack + Telegram 两渠道）为 10.0–15.0 pd。迁出 Telegram（2.5–3.5 pd）后剩 7.5–11.5 pd；迁入企微回调 + AIBot + 飞书（10–16 pd）后为 17–27 pd。逐包复算下限 0.5+0.5+3+3+4+3+1.5+1.5 = **17**，上限 1+1+5+5+6+4.5+2+2.5 = **27**。对外口径 **17–28.5 pd** = 下限不另加缓冲、上限再加 1.5 pd 缓冲（评审与真机段的不确定性集中在上限侧）。

## 版本计划

- milestone：`M8 · v0.6.0 渠道补齐（WeCom + Lark + Slack）`
- 期序：主线第 8 期（order: 8）
- 排期：原 W48–W51（4 周）估算随范围变化失效，**待重排**
- 发版：manual minor（`workflow_dispatch` 输入 `minor`），三平台资产 + sha256 + 裸 ubuntu:24.04 容器冒烟
