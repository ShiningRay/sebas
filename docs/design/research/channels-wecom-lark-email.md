# 三渠道多账号接入调研：企业微信 / 飞书(Lark) / Email

- 调研目的：为 Crystal 个人 Agent 平台的「统一连接抽象层」提供技术事实依据。核心诉求：同一渠道类型可绑定 N 个账号并存、可编排消息/事件→动作。
- 调研方式：官方文档优先，检索日期 2026-11-18。所有结论附来源；查不到或未实测的统一进文末「未验证」小节。
- 结论速览：三渠道的接收侧都可归并为两种形态——**入站回调（需公网 + 验签解密）** 与 **出站长连接（免公网，通道内置鉴权）**；凭据/token 管理同构（每账号独立 secret → 短时效 token → 缓存 + 提前刷新）。个人 Agent 平台应优先长连接形态。

---

## (a) 企业微信 WeCom

### a1. 自建应用：回调 URL 模式（接收消息/事件）

配置三要素：**URL、Token、EncodingAESKey**（[回调配置](https://developer.work.weixin.qq.com/document/path/90930)）。

- **URL 验证（GET）**：企微发 GET，带 `msg_signature`、`timestamp`、`nonce`、`echostr`。
  开发者解密 `echostr` 得明文（含 `random`、`msg_len`、`msg` 三段），**1 秒内**回显明文 msg
  （不能加引号、不能带 BOM、不能带换行）。
  依据：[回调和回复的加解密方案](https://developer.work.weixin.qq.com/document/path/101033)；
  官方社区确认 GET 1 秒、POST 5 秒要求（[社区回复](https://developer.work.weixin.qq.com/community/question/detail?content_id=16852975329130074534)）。
- **消息推送（POST）**：企微以 XML 密文 POST 到 URL；被动回复也需加密后返回
  （[加解密方案说明](https://developer.work.weixin.qq.com/document/path/90968)）。
- **加解密**：AES-256-CBC，四步——
  ① `AESKey = Base64_Decode(EncodingAESKey + "=")`，43 字符 → 32 字节；
  ② IV 取 AESKey 前 16 字节；
  ③ PKCS#7 填充至 32 字节倍数；
  ④ 解密后明文布局为 `random(16B) + msg_len(4B 大端) + msg + receiveid`。

  依据：官方 [90968](https://developer.work.weixin.qq.com/document/path/90968) 与
  [101033](https://developer.work.weixin.qq.com/document/path/101033) 说明解密后字段；
  第三方实现一致佐证（[wxkefu-rs](https://docs.rs/wxkefu-rs/latest/wxkefu_rs/callback/struct.CallbackCrypto.html)、
  [WeKnora 错误说明](https://errors.standardbeagle.com/Tencent/WeKnora/plaintext-too-short/)）。

  `receiveid` 即 corpid——**校验它可防跨企业回调混串**，是天然的多企业路由/校验锚点。
- **验签**：`msg_signature = SHA1(字典序排序(token, timestamp, nonce, encrypt))`，用于确认来源与内容完整性（[90930](https://developer.work.weixin.qq.com/document/path/90930)、[90968](https://developer.work.weixin.qq.com/document/path/90968)）。
- **超时与重试**：POST **5 秒内**收不到响应会断开连接并重新发起请求，**总共重试 3 次**；回调可能重复，须按 `msgid` 排重；官方建议「立即应答、业务异步处理」（[社区官方回复 1](https://developer.work.weixin.qq.com/community/question/detail?content_id=16852975329130074534)、[回复 2](https://developer.work.weixin.qq.com/community/question/detail?content_id=16729413638223055356)）。
- 官方提供加解密库（C++/Python/PHP/Java/Go/C# 等），Crystal 无官方库需自行实现（AES-CBC + SHA1 + Base64，工作量可控）（[90968](https://developer.work.weixin.qq.com/document/path/90968)）。

### a2. 智能机器人（AIBot，官方为 AI 助手场景设计的新形态）

对个人 Agent 平台最贴合的企微通道。用户在单聊/群聊 @ 机器人即可交互，支持**两种接收方式**：

| 方式 | 消息 | 事件 | 说明 |
| --- | --- | --- | --- |
| **长连接** | [接收消息 101834](https://developer.work.weixin.qq.com/document/path/101834) | [接收事件 101835](https://developer.work.weixin.qq.com/document/path/101835) | `cmd=aibot_msg_callback` / `aibot_event_callback`，**明文推送、无需解密**，免公网 URL；多媒体资源每个下载链接对应唯一 `aeskey`（不同于统一 EncodingAESKey） |
| **URL 回调** | [接收消息 100719](https://developer.work.weixin.qq.com/document/path/100719) | [接收事件 101843](https://developer.work.weixin.qq.com/document/path/101843) | JSON 密文；用官方加解密库解 `encrypt` 字段，**自建智能机器人场景 `receiveid` 传空字符串**；回复需加密（[101033](https://developer.work.weixin.qq.com/document/path/101033)） |

- 回复机制：回调中透传 `headers.req_id` 回复；URL 回调方式还带 `response_url`（临时主动回复 URL）（[101834](https://developer.work.weixin.qq.com/document/path/101834)、[100719](https://developer.work.weixin.qq.com/document/path/100719)）。
- 字段：`aibotid`（机器人 id）、`chatid`/`chattype`（single/group）、`from.userid`（创建者非超管时为**加密 userid**，需经应用对接转换）、`compat_info.source`（ai_assistant/频道来源）（[101834](https://developer.work.weixin.qq.com/document/path/101834)、[100719](https://developer.work.weixin.qq.com/document/path/100719)）。
- 主动发送：官方 Node SDK（[WecomTeam/aibot-node-sdk](https://github.com/WecomTeam/aibot-node-sdk)）含主动发送消息体类型（markdown/模板卡片/流式消息等）；对应官方「发送消息」接口文档本轮未逐页核对（见未验证）。

### a3. 群机器人 webhook（仅出站）

- 群内添加机器人获得 webhook URL（`https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=...`），**只能向该群发消息、不能接收**（[官方社区](https://developer.work.weixin.qq.com/community/question/detail?content_id=16766473678046456954)、[七牛操作说明](https://developer.qiniu.com/af/13434/wechat)）。
- 频率：**20 条/分钟**（官方社区回复，见 [同上](https://developer.work.weixin.qq.com/community/question/detail?content_id=16766473678046456954)）；超限报 `api freq out of limit`（45009）。第三方实践建议本地滑动窗口限流 + 触发 45009 后等 ~65 秒重试（[wecom-notifier 实践](https://pypi.org/project/wecom-notifier/0.3.1/#security#2)）。

### a4. access_token 获取与刷新

- 接口：`GET https://qyapi.weixin.qq.com/cgi-bin/gettoken?corpid=ID&corpsecret=SECRET`；**每个应用有独立 secret，token 只能本应用使用**（[获取access_token 91039](https://developer.work.weixin.qq.com/document/path/91039)）。
- 有效期 `expires_in` **7200 秒（2 小时）**；token 至少保留 512 字节存储；**勿返回前端**（[91039](https://developer.work.weixin.qq.com/document/path/91039)）。
- 行为细节（官方社区回复）：有效期内重复获取返回**相同 token**；过期后获取返回新 token；企微可能**提前使 token 失效**，须实现失效重取逻辑；缓存须按应用区分（[社区回复](https://developer.work.weixin.qq.com/community/question/detail?content_id=16408357570741837071)）。
- gettoken 本身的独立频率数值未见官方公开（受基础频率约束，见 a7），标记未验证。

### a5. 一个进程多企业 / 多应用并存

- 凭据矩阵：每个账号 = 一对 `(corpid, secret)` → 独立 access_token；单进程维护 **token 缓存 key = (corpid, agentid/secret)**，各自缓存、各自刷新节流（[91039](https://developer.work.weixin.qq.com/document/path/91039)）。
- 回调按应用配置 URL，多个应用可指向同一服务端点，按报文中的应用/机器人标识字段路由；解密后 `receiveid`(corpid) 可作跨企业隔离校验（[90968](https://developer.work.weixin.qq.com/document/path/90968)）。
- 智能机器人长连接为出站连接，天然支持一台服务器同时维持多个企业/多个机器人的连接，无需公网入口。

### a6. 可信域名 / 可信IP

- **企业可信IP（出向 API 调用必需）**：自建应用调用服务端 API 的出口公网 IP 必须配到
  「管理后台-应用管理-应用详情-企业可信IP」，否则报错 **60020 `not allow to access from your ip`**。
  依据：[社区案例 1](https://developer.work.weixin.qq.com/community/question/detail?content_id=16798088819581233102)、
  [案例 2](https://developer.work.weixin.qq.com/community/question/detail?content_id=16855989729235200518)；
  官方排查工具 [devtool/query](https://developer.work.weixin.qq.com/devtool/query)。
- 已认证企业须**先配置可信域名才能配置可信IP**（[社区回复](https://developer.work.weixin.qq.com/community/question/detail?content_id=16855989729235200518)）；可信域名用于网页授权/JS-SDK 场景，每企业设置上限 **20 个/月**（[访问频率限制 90312](https://developer.work.weixin.qq.com/document/path/90312)）。
- 工程含义：多账号平台的出口 IP 是共享资源，所有企业/应用共用同一出口 IP 池；IP 变更（云厂商浮动）须同步更新各应用配置。

### a7. 主动发消息与 API 频率限制

- 应用消息：`POST /cgi-bin/message/send`，`agentid` 必填，`touser` 最多 1000 人（或 `@all`）、`toparty` 最多 100 个（[发送应用消息 90236](https://developer.work.weixin.qq.com/document/path/90236)）。
- 频率（[90312](https://developer.work.weixin.qq.com/document/path/90312)，官方声明可能按运营调整）：
  - 基础频率：每企业单 API ≤ **1 万次/分、15 万次/小时**；每 IP 单 API ≤ **2 万次/分、60 万次/小时**；第三方应用每 IP ≤ 4 万次/分、120 万次/小时。
  - 发送应用消息（不计入基础频率）：每应用对**同一成员 ≤ 30 次/分钟、1000 次/小时**（超出直接丢弃不下发）；每应用每天 ≤ 账号上限数 × 200 人次。
  - 打卡/审批数据 ≤ 600 次/分；创建应用上限 300 个/企业。
- 超限错误码 `45009: api freq out of limit`（[社区](https://developer.work.weixin.qq.com/community/question/detail?content_id=16708584653094111621)）。

---

## (b) Lark / 飞书

### b1. 事件订阅两种方式

**方式一：将事件发送至开发者服务器（Webhook 回调）**（[接收事件/加密策略](https://open.feishu.cn/document/server-docs/event-subscription-guide/event-subscription-configure-/encrypt-key-encryption-configuration-case?lang=en-US)）
- 需公网可访问 URL；配置时飞书发 URL 校验挑战（challenge），须按挑战要求回包。
- 安全校验两种（官方明确对比）：
  - **Verification Token 校验**：简单但**安全性低**（明文比对 token）；
  - **签名校验（推荐）**：`sha256( X-Lark-Request-Timestamp + X-Lark-Request-Nonce + encrypt_key + 原始 body )` 与请求头 `X-Lark-Signature` 比对。
- 配置 Encrypt Key 后事件密文推送，需解密。

**方式二：使用长连接接收事件（WebSocket）**（[使用长连接接收事件](https://open.feishu.cn/document/server-docs/event-subscription-guide/event-subscription-configure-/request-url-configuration-case)）
- 飞书 SDK（Go/Python/Java/Node）与开放平台建立 WebSocket 全双工通道；**只需本机能访问公网，无需公网 IP/域名/内网穿透**；官方称将接入周期从 ~1 周降到 5 分钟。
- **内置加密与鉴权**：事件密文传输，开发者无需验签/解密，也无需部署防火墙或白名单。
- 硬性限制（官方「注意事项」）：
  - **仅支持企业自建应用**（商店应用只能用 Webhook 方式）；
  - 收到消息须 **3 秒内**处理完成且不抛异常，否则触发超时重推（需按事件 id 排重）；
  - **每应用最多 50 个连接**（每初始化一个 client 即一个连接）；
  - 推送为**集群模式、不支持广播**：同一应用多 client 部署时，每条消息只由**随机一个** client 收到（不能当广播/负载均衡用）。
- 适用场景：个人 Agent、本地开发、无公网设施 → 长连接；多实例生产集群需消息可控分发 → Webhook。

### b2. 多应用 / 多租户并存

- **自建应用 = 单租户**：tenant_access_token 的目标租户由应用自身确定，**不能用本接口获取其他租户的凭证**（[tenant_access_token 文档](https://open.feishu.cn/document/uAjLw4CM/ukTMukTMukTM/authentication-management/access-token/tenant_access_token)）。多租户并存的正路：
  1. 每个租户各建一个自建应用（多组 `app_id/app_secret` 并存，单进程分别取 token）——个人平台多飞书账号的最简路径；
  2. 或走商店应用（ISV）模式，统一多租户分发（长连接文档明确商店应用只能走 Webhook 方式；ISV 的 app_ticket 换 token 流程本轮未展开，见未验证）。
- 飞书另有**自定义机器人**（群 webhook，仅出站），频率独立（见 b5）。

### b3. tenant_access_token 管理

（[自建应用获取 tenant_access_token](https://open.feishu.cn/document/uAjLw4CM/ukTMukTMukTM/authentication-management/access-token/tenant_access_token)，2026-10 更新版）
- OAuth 2.0 **Client Credentials** 授权（`grant_type=client_credentials`）；支持 `client_secret_basic`（Basic Auth）与 `client_secret_post` 两种认证。
- **有效期最长 2 小时**，以响应 `expires_in` 为准，**勿硬编码**；服务端缓存复用，临近过期再取。
- 新版 token 为 **JWT 格式**，长度显著增加：存储/缓存/Header 至少预留 **4 KB**；新版从响应 `access_token` 字段读取（旧版字段 `tenant_access_token`）。
- 刷新行为（官方教程镜像佐证）：剩余有效期 > 30 分钟时重复调用返回**同一 token 不续期**；< 30 分钟时发新 token，旧 token 至原到期时间仍有效（[镜像教程](https://open.xfchat.iflytek.com/document/home/integrating-web-apps-in-5-minutes/debug-and-release)）。
- **App Secret 只能保存在应用服务端，勿写入前端代码、客户端安装包或日志**（官方原文）。

### b4. 飞书（国内）与 Lark（国际版）

- API 域名：飞书 `https://open.feishu.cn`；Lark `https://open.larksuite.com`。官方 SDK 内置 `FeishuBaseUrl` / `LarkBaseUrl` 常量切换；用错域名报 `1000040351 Incorrect domain name`（[picoclaw PR](https://github.com/sipeed/picoclaw/pull/1753)、[deer-flow commit](https://github.com/bytedance/deer-flow/commit/7db95926b08626ab688400562977d2996078ae36)——均为第三方工程实践，与官方 SDK 行为一致）。
- **账号体系完全独立**：Lark 官方帮助中心明确「Lark 与飞书是**不同主体运营的独立产品**，Lark 账号只能用于 Lark 应用，反之亦然」（[Lark Help Center](https://www.larksuite.com/hc/en-US/articles/499556070769-lark-accounts-cannot-log-in-to-the-current-app)）。
- 工程含义：一个「飞书渠道账号」实际要按平台二选一（或两套并存）；`app_id/app_secret` 必须在对应平台的开放平台分别注册；抽象层应把 base_url 当作账号配置的一部分。

### b5. API 频率限制

（[频控策略](https://open.feishu.cn/document/server-docs/api-call-guide/frequency-control)）
- 维度：**每 API × 每应用 × 每租户**；自建应用按企业套餐（基础版/商业版）分级，商店应用独立。等级节选：L1=10 次/分，L2=20 次/分，L3=100 次/分，L4=1000 次/分 & 50 次/秒，L5=1 次/秒，L6=5 次/秒，L9=50 次/秒，L11=100 次/秒。
- 复合频控（如 1000 次/分 & 50 次/秒）**任一上限触发即限流**；限流返回 HTTP 429，部分老接口返回非 429 错误码（如发消息 230020，见 [发送消息](https://open.xfchat.iflytek.com/document/uAjLw4CM/ukTMukTMukTM/reference/im-v1/message/create#-f367d31)）。
- **自定义机器人（群 webhook）**：单租户单机器人 **100 次/分钟、5 次/秒**；官方还建议避开整点/半点发送，否则易因系统压力触发 `11232` 限流。
- 老版频控摘要（镜像佐证）：所有接口每应用 ≤ 50 次/秒；发送消息接口每应用 ≤ 1000 次/分钟；机器人对同一用户/同一群 ≤ 5 次/秒（[镜像](https://github.com/jasonqwj/feishu_api_docs/blob/090a5e8f8e20bb98c80207a6fc24c6bbbd8bce1c/doc/doc-1939846.md)）。
- 单个 API 属于哪个等级需在文档/控制台查询（见未验证）。

---

## (c) Email

### c1. IMAP IDLE 长连接 vs 轮询

- IDLE（[RFC 2177](https://datatracker.ietf.org/doc/html/rfc2177)）：客户端在已选中的 mailbox 上发出 IDLE 后，服务器在同一条连接上实时推送新邮件通知（unsolicited EXISTS 等）。
- 关键约束：
  - **一次 IDLE 只监听一个文件夹**；多文件夹需多连接或轮换；
  - 客户端应**每 ≤29 分钟终止并重发 IDLE**，避免被服务器 inactivity 超时登出（RFC 2177 原文建议；RFC 3501 §5.4 要求服务器 autologout 定时器 ≥30 分钟）（[Apache Jira IMAP-246 引 RFC 原文](https://issues.apache.org/jira/browse/IMAP-246)）；
  - NAT/防火墙中间设备可能提前掐断空闲 TCP，需应用层心跳与重连；重连后须重新 SELECT 再 IDLE。
- 轮询：实现简单、可统一调度多账号；延迟与轮询间隔成正比，高频轮询浪费配额与流量。
- **Gmail 特例**：官方 IMAP 扩展文档的 CAPABILITY 示例中含 `IDLE`（[IMAP Extensions](https://developers.google.com/workspace/gmail/imap/imap-extensions)），但社区长期报告 Gmail 的 IDLE 推送不可靠；Google 官方推荐的推送替代是 **Gmail API `watch` + Cloud Pub/Sub**（[推送通知指南](https://developers.google.com/gmail/api/guides/push)）。设计上 Gmail 账号建议走 Gmail API 而非依赖 IDLE。
- 取舍结论：连接管理能力强（Crystal fiber 天然适合多连接）→ 非邮箱用 IDLE 常驻 + 兜底轮询 + 指数退避重连；Gmail 走 API watch/轮询。

### c2. SMTP 发件

- 端口：465（隐式 TLS）/ 587（STARTTLS）/ 25（明文中继，基本被封禁，禁用）。
- 认证：Gmail/Outlook 均要求 **SASL XOAUTH2**（OAuth2 access token）或应用专用密码（Gmail），见 c3；XOAUTH2 同时用于 IMAP/POP/SMTP AUTH（[XOAUTH2 机制](https://developers.google.com/workspace/gmail/imap/xoauth2-protocol)）。
- Gmail 发送限额：单封 > 500 收件人或 > 500 封/日触发限流，封 1–24 小时
  （[Gmail 官方限额](https://support.google.com/mail/answer/22839)）。
  第三方邮件客户端（IMAP/POP）发信另有更低限额：产品专家口径约 100 封/24h 滚动窗口，
  官方页该小节未逐字核对（见未验证；
  [社区佐证](https://support.google.com/mail/thread/364755365/you-have-reached-a-limit-for-sending-mail-not-resolved-after-24-hours)）。
  Google Workspace 版限额未核。

### c3. Gmail OAuth2 与应用专用密码现状

- **Basic auth（用户名+密码，LSA）已淘汰**（官方时间线）：
  - 2024 年夏：首次尝试用 LSA 连接的新账户直接不可用（覆盖 IMAP/SMTP/POP/CalDAV/CardDAV）；
  - **2025-03-14 起**：所有账户 IMAP/SMTP/POP 不再支持旧版密码认证；**应用专用密码除外**（[Google Workspace 官方过渡指南](https://knowledge.workspace.google.com/admin/sync/transition-from-less-secure-apps-to-oauth)）。
- **XOAUTH2**：`base64("user=<email>\x01auth=Bearer <token>\x01\x01")`；IMAP/POP/SMTP 的 scope 为 `https://mail.google.com/`（完整邮箱 scope 须符合 Google 用户数据政策；**不需要全量邮箱时，官方明确建议改用 Gmail API 的细粒度受限 scope**）（[XOAUTH2](https://developers.google.com/workspace/gmail/imap/xoauth2-protocol)）。全域委派场景可用 `gmail.imap_admin` scope（同上）。
- **应用专用密码**：仍可用，但需账号开启两步验证后创建（官方帮助入口 [answer/185833](https://support.google.com/accounts/answer/185833)；页面未逐字核对，见未验证）。平台可用它作快速接入，长期应走 OAuth2。

### c4. Outlook / Microsoft 365

- **Exchange Online**：2022-10-01 起 basic auth 对 Outlook/EWS/RPS/POP/**IMAP**/EAS **永久停用**（默认关闭且无法再开启），须改新式认证（OAuth2）（[Microsoft Lifecycle 公告](https://learn.microsoft.com/en-us/lifecycle/announcements/basic-auth-deprecation-exchange-online)；检索到其 ja-JP/ko-KR 版本，内容一致）。
- **Outlook.com/Hotmail 个人账号**：**2024-09-16 起** basic auth 停用，IMAP/POP/SMTP 密码登录失败，需新式认证；旧版 Outlook 客户端亦不支（[Microsoft Q&A（引官方公告）](https://learn.microsoft.com/zh-cn/answers/questions/2078776/outlook-pop-imap-smtp)、[另一 Q&A](https://learn.microsoft.com/pt-br/answers/questions/4687782/aplicativo-outlook-do-microsoft-365-parou-de-sincr)）。
- 替代路径：IMAP/SMTP + OAuth2（XOAUTH2，Azure AD 注册应用）或 **Microsoft Graph API + change notifications（webhook 推送）**；Graph 订阅细节本轮未核对（见未验证）。

### c5. 多邮箱并存注意点

- **连接数上限**：Gmail 每账号同时 **15 个 IMAP 连接**，超过报 `Too many simultaneous connections`。
  依据：[Microsoft Q&A 引 Google 文档](https://learn.microsoft.com/en-us/answers/questions/4473979/too-many-simultaneous-connections-error-with-gmail)、
  [Atlassian KB](https://support.atlassian.com/jira/kb/email-handler-for-gmail-does-not-process-all-email-requests/)——
  均非 Google 官方页数值（见未验证）。
  IDLE 每文件夹占一条连接 → 通常只 IDLE INBOX（或收件文件夹）。
- **心跳/断线重连**：每 ≤29 分钟 NOOP 或重发 IDLE；处理服务器 `BYE`/autologout；指数退避；重连后恢复 SELECT 状态与 UID 同步（UIDVALIDITY 变化需全量重扫）。
- **OAuth 生命周期**：每账号独立 refresh token；access token 过期时 XOAUTH2 失败返回 JSON 错误，须刷新 token 后重认证连接；token 存储与刷新调度按账号隔离。
- **多账号调度**：统一连接池 + 每账号并发上限 + 全局 QPS；避免同一账号多组件各开多连接（15 上限含全部后台连接）。

---

## (d) 三渠道共通的合规 / 安全注意

### d1. 凭据如何存

- 官方底线（三家一致）：secret/token **只存服务端**，不入前端、安装包、日志：
  - 飞书原文「App Secret 只能保存在应用服务端，勿写入前端代码、客户端安装包或日志」（[tenant doc](https://open.feishu.cn/document/uAjLw4CM/ukTMukTMukTM/authentication-management/access-token/tenant_access_token)）；
  - 企微「请勿将 access_token 返回给前端」（[91039](https://developer.work.weixin.qq.com/document/path/91039)）。
- 平台级建议（工程指南，非官方强制）：多账号凭据集中存储须**静态加密**（AES-256-GCM 等），
  主密钥托管于 OS 凭据库（Windows Credential Manager/DPAPI、macOS Keychain、Linux secret service）
  或专用 Vault。按 `(渠道类型, 账号ID)` 命名空间隔离；日志全程脱敏 token/secret。
  支持轮换——企微 secret、飞书 secret 均可在管理后台重置，OAuth refresh token 可撤销
  （参考 [OWASP Secrets Management Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html)）。

### d2. 最小权限

- WeCom：应用**可见范围**最小化（发消息只对可见范围内成员生效）；secret 按能力拆分（应用 secret、通讯录 secret、客户联系 secret 相互独立，各发各的 token）。
- 飞书：应用按需申请权限 scope，避免全量勾选；token 按 `(app_id)` 隔离。
- Gmail：官方明确「**不需要完整邮箱 scope 时改用 Gmail API 细粒度受限 scope**（readonly/send/compose/metadata）」（[XOAUTH2](https://developers.google.com/workspace/gmail/imap/xoauth2-protocol)）；Microsoft 区分 delegated / application 权限，个人平台用 delegated。
- 出站 webhook 发送类（企微群机器人 key、飞书自定义机器人）只有「向该会话发消息」单一能力，天然最小权限，适合低敏通知场景。

### d3. 回调验签（企微 / 飞书）

- WeCom：`msg_signature = SHA1(sort(token, timestamp, nonce, encrypt))` + AES-CBC 解密 + **校验 receiveid(corpid)** 防跨企业混串 + `msgid` 排重（重试 3 次）（[90930](https://developer.work.weixin.qq.com/document/path/90930)、[90968](https://developer.work.weixin.qq.com/document/path/90968)、[101033](https://developer.work.weixin.qq.com/document/path/101033)）。
- 飞书 webhook：URL 校验 challenge + `X-Lark-Signature = sha256(timestamp + nonce + encrypt_key + body)` + Encrypt Key 解密（[接收事件](https://open.feishu.cn/document/server-docs/event-subscription-guide/event-subscription-configure-/encrypt-key-encryption-configuration-case?lang=en-US)）；不配置 Encrypt Key 时仅有明文 Verification Token 比对，官方自评「安全性低」。
- 长连接模式（企微智能机器人、飞书 SDK）：通道建立时已完成凭据认证 + 传输加密，**无需验签**，但事件可能超时重推，仍须按 id 排重（[飞书长连接](https://open.feishu.cn/document/server-docs/event-subscription-guide/event-subscription-configure-/request-url-configuration-case)、[企微 101834](https://developer.work.weixin.qq.com/document/path/101834)）。
- Email 无回调面：信任根是 OAuth 授权本身 + TLS 传输；SMTP 必须走 TLS 端口。

### d4. 传输与审计

- 全渠道强制 HTTPS/WSS；SMTP 禁明文 25 中继；回调端点即使有验签也应仅限必要路径暴露。
- 多账号平台防「串号」：所有 API 调用与回调处理都携带账号上下文；token 缓存、限流器、审计日志按账号隔离；回调路由错误（企微跨企业混串）有 receiveid 可校验兜底。

---

## 对统一连接抽象层的设计启示（推论，非官方事实）

1. **账号建模**：统一凭证上下文 `Account = {channel_type, platform/base_url, credentials, token_ref}`——WeCom `(corpid, secret, agentid/aibotid)`、飞书 `(app_id, secret, feishu.cn|larksuite.com)`、Email `(mailbox, OAuth client/token 或 app password)`。
2. **接收侧三形态归一**：
   - 入站 HTTP 回调（企微自建应用、飞书 webhook、企微智能机器人 URL 模式）→ 共性是「验签/解密 + challenge + 排重」；
   - 出站长连接（企微智能机器人长连接、飞书 WebSocket 长连接、IMAP IDLE）→ 共性是「免公网、通道鉴权、心跳/重连」；
   - 单向出站 webhook（企微群机器人、飞书自定义机器人）→ 只有 send。
   个人 Agent 平台优先长连接形态（两家官方均为 AI 助手场景提供）。
3. **TokenProvider 抽象**：三渠道 token 生命周期同构（独立获取、~2h 有效、缓存复用、临期刷新、失效重取、按账号隔离缓存），可统一为一个带 TTL 与刷新节流的凭据管理器。
4. **限流器维度**：按 `(账号, 目标)` 建 token bucket——企微同一成员 30 次/分；飞书同一用户/群 5 次/秒且避开整点半点；Gmail 500 封/日；企微群机器人 20 条/分、飞书自定义机器人 100 次/分。
5. **Crystal 贴合点**：多账号 = 大量常驻长连接 + 少量 HTTP 回调端点，fiber/事件循环模型适合「每账号一个监督体 + 断线指数退避重启」的结构；企微加解密只需 AES-CBC/SHA1/Base64（OpenSSL 绑定即可），无官方 Crystal 库需自实现并加解密对称测试。

---

## 来源 URL 清单

### 企业微信（官方域名 developer.work.weixin.qq.com / work.weixin.qq.com）
1. 回调配置：https://developer.work.weixin.qq.com/document/path/90930
2. 加解密方案说明：https://developer.work.weixin.qq.com/document/path/90968
3. 回调和回复的加解密方案（智能机器人）：https://developer.work.weixin.qq.com/document/path/101033
4. 获取 access_token：https://developer.work.weixin.qq.com/document/path/91039
5. 访问频率限制：https://developer.work.weixin.qq.com/document/path/90312
6. 发送应用消息：https://developer.work.weixin.qq.com/document/path/90236
7. 智能机器人·长连接·接收消息：https://developer.work.weixin.qq.com/document/path/101834
8. 智能机器人·长连接·接收事件：https://developer.work.weixin.qq.com/document/path/101835
9. 智能机器人·URL 回调·接收消息：https://developer.work.weixin.qq.com/document/path/100719
10. 智能机器人·URL 回调·接收事件：https://developer.work.weixin.qq.com/document/path/101843
11. 官方智能机器人 Node SDK：https://github.com/WecomTeam/aibot-node-sdk
12. 社区：群机器人 20 条/分钟：https://developer.work.weixin.qq.com/community/question/detail?content_id=16766473678046456954
13. 社区：token 有效期/重复获取/提前失效：https://developer.work.weixin.qq.com/community/question/detail?content_id=16408357570741837071
14. 社区：回调 5 秒重试/GET 1 秒：https://developer.work.weixin.qq.com/community/question/detail?content_id=16852975329130074534
15. 社区：重试三次/异步处理建议：https://developer.work.weixin.qq.com/community/question/detail?content_id=16729413638223055356
16. 社区：可信IP 60020 案例：https://developer.work.weixin.qq.com/community/question/detail?content_id=16798088819581233102
17. 社区：可信域名先行/可信IP：https://developer.work.weixin.qq.com/community/question/detail?content_id=16855989729235200518
18. 排查工具（60020/token 归属）：https://developer.work.weixin.qq.com/devtool/query
19. 45009 频率超限案例：https://developer.work.weixin.qq.com/community/question/detail?content_id=16708584653094111621
20. 第三方佐证（明文布局）：https://docs.rs/wxkefu-rs/latest/wxkefu_rs/callback/struct.CallbackCrypto.html 、https://errors.standardbeagle.com/Tencent/WeKnora/plaintext-too-short/ 、https://pypi.org/project/wecom-notifier/0.3.1/#security

### 飞书 / Lark（官方域名 open.feishu.cn / larksuite.com）
21. 使用长连接接收事件：https://open.feishu.cn/document/server-docs/event-subscription-guide/event-subscription-configure-/request-url-configuration-case
22. 接收事件（Webhook 模式、签名/加密校验）：https://open.feishu.cn/document/server-docs/event-subscription-guide/event-subscription-configure-/encrypt-key-encryption-configuration-case?lang=en-US
23. 自建应用获取 tenant_access_token：https://open.feishu.cn/document/uAjLw4CM/ukTMukTMukTM/authentication-management/access-token/tenant_access_token
24. 频控策略：https://open.feishu.cn/document/server-docs/api-call-guide/frequency-control
25. Lark 与飞书为独立产品（账号不互通）：https://www.larksuite.com/hc/en-US/articles/499556070769-lark-accounts-cannot-log-in-to-the-current-app
26. 镜像佐证（token 刷新行为）：https://open.xfchat.iflytek.com/document/home/integrating-web-apps-in-5-minutes/debug-and-release
27. 镜像佐证（老版频控摘要）：https://github.com/jasonqwj/feishu_api_docs/blob/090a5e8f8e20bb98c80207a6fc24c6bbbd8bce1c/doc/doc-1939846.md
28. 域名切换工程实践：https://github.com/sipeed/picoclaw/pull/1753 、https://github.com/bytedance/deer-flow/commit/7db95926b08626ab688400562977d2996078ae36

### Email
29. RFC 2177 (IMAP IDLE)：https://datatracker.ietf.org/doc/html/rfc2177
30. RFC 2177 29 分钟建议引文（Apache IMAP-246）：https://issues.apache.org/jira/browse/IMAP-246
31. Gmail IMAP Extensions：https://developers.google.com/workspace/gmail/imap/imap-extensions
32. Gmail XOAUTH2 机制：https://developers.google.com/workspace/gmail/imap/xoauth2-protocol
33. Gmail API 推送（watch + Pub/Sub）：https://developers.google.com/gmail/api/guides/push
34. Gmail 发送限额：https://support.google.com/mail/answer/22839
35. Google LSA → OAuth 过渡（basic auth 停用时间线）：https://knowledge.workspace.google.com/admin/sync/transition-from-less-secure-apps-to-oauth
36. Google 应用专用密码帮助页：https://support.google.com/accounts/answer/185833
37. Exchange Online basic auth 弃用公告：https://learn.microsoft.com/en-us/lifecycle/announcements/basic-auth-deprecation-exchange-online （检索验证为其 ja-JP/ko-KR 本地化版本）
38. Outlook.com 2024-09-16 停 basic auth（Microsoft Q&A）：https://learn.microsoft.com/zh-cn/answers/questions/2078776/outlook-pop-imap-smtp
39. Gmail 15 连接上限（Microsoft Q&A）：https://learn.microsoft.com/en-us/answers/questions/4473979/too-many-simultaneous-connections-error-with-gmail
40. Gmail 15 连接上限（Atlassian KB）：https://support.atlassian.com/jira/kb/email-handler-for-gmail-does-not-process-all-email-requests/
41. Gmail 发送限额社区佐证：https://support.google.com/mail/thread/364755365/you-have-reached-a-limit-for-sending-mail-not-resolved-after-24-hours

### 通用
42. OWASP Secrets Management Cheat Sheet（d1 工程建议参考）：https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html

---

## 未验证清单

1. **企微 gettoken 接口本身的独立频率数值**：官方未公开专门数值（基础频率按企业/IP 计），仅能确认须缓存。未实测。
2. **企微回调解密明文布局的官方原文逐字核对**：`random(16B)+msg_len(4B)+msg+receiveid` 来自官方文档描述 + 多个第三方实现一致；官方 90968「原理详解」小节本轮未逐字展开。
3. **企微智能机器人「发送消息/主动发消息」官方接口文档页**：SDK 类型证明能力存在，具体 API 文档与频率限制未逐页核对。
4. **企微群机器人文档（path/9176）内容**：20 条/分钟与接口地址来自官方社区回复与第三方实践，未展开官方文档原文。
5. **飞书商店应用（ISV）多租户流程**（app_ticket、app_access_token 换 tenant_access_token）：本轮未展开核对。
6. **飞书单个 API → 频控等级的具体映射**：等级表已获取，但每个接口属哪一级需在控制台/接口文档查询。
7. **Gmail IMAP 15 连接上限**：Microsoft Q&A 与 Atlassian 一致引用，但未找到 Google 官方页面直接给出该数值。
8. **Gmail IMAP/POP 客户端发信 100 封/24h 与 Workspace 2000 封/日**：前者为 Google 产品专家口径（官方页对应小节未逐字核对），后者未核。
9. **Gmail IMAP IDLE 实际推送行为**：官方扩展文档 CAPABILITY 示例含 IDLE，但社区长期报告不可靠；未实测。
10. **Exchange Online / Outlook.com IMAP IDLE 支持与行为**：常见可用，未取官方文档佐证。
11. **Microsoft Graph 邮件 change notifications（webhook 订阅）细节**：作为 IMAP 替代方案提及，官方页未核对。
12. **企微可信域名验证流程细节**（校验文件/ICP 备案要求）：来自社区线索与常识，未逐字核对官方配置文档。
