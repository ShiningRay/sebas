# design.md §5 多账号设计（硬需求①）

> 导航：[设计总览](../design.md) ｜ [文档索引](../README.md) ｜ 上一节：[§4](04-architecture.md) ｜ 下一节：[§6](06-session-memory.md)

## 5. 多账号设计（硬需求①专章：同渠道 N 账号并存）

### 5.1 账号生命周期

每个 Account 由一个**监督 fiber** 全生命周期管理：

```
注册(config) → connecting → online ⇄ backoff(指数退避重连) → disabled(用户停用)
                              │
                              └→ token 刷新失败 N 次 / 凭据失效 → degraded(告警+等待轮换)
```

监督 fiber 职责清单：

1. **连接维持**：长连接心跳 / IDLE 重发（email 每 ≤29 分钟，渠道笔记 c1）；断线指数退避重连（autobot 惯用法 5s→60s）。
2. **token 生命周期**：经 TokenProvider 缓存+临期提前刷新+失效重取（§5.3）。
3. **限流记账**：按 `(账号, 目标)` 维护 token bucket（§5.3.1）。
4. **事件入总线**：所有收到的消息/事件统一封装为带账号上下文的 InboundEvent。
5. **健康上报**：连接状态、token 状态、限流水位，经管理面可查（§9）。

**重复凭据检测**：同渠道同凭据的第二个账号注册时 **park（拒绝启动）而非进程崩溃**（Hermes：duplicate adapter 被 park，gateway 不退出）。

### 5.2 接收侧两形态归并

每渠道适配器实现为以下之一（渠道笔记结论速览：接收侧归并为两种形态）：

| 形态 | 适用 | 共性机制 |
|---|---|---|
| **长连接型**（出站连接，免公网） | 企微智能机器人长连接、飞书 WebSocket、IMAP IDLE | 通道建立时已认证+加密；心跳/重连；事件仍须按 id 排重（超时重推） |
| **回调型**（入站 HTTP，需公网） | 企微自建应用回调、飞书 webhook | 验签/解密 + challenge + 排重 + 秒级响应（异步处理） |

- **个人部署优先长连接**（两家官方均为 AI 助手场景提供该形态；渠道笔记设计启示 2）。
- 回调型平台共享**同一个 HTTP 监听器**，按 URL 前缀 `/cb/<channel>/<account_id>/` 路由到对应账号 adapter，各账号用自己的 secret 验签；**无对应 adapter → 404，验签失败 → 401/403（fail-closed）**（Hermes port-binding 型平台接线方式：`/p/<profile>/` 前缀路由模式的移植）。
- 另有第三类**单向出站 webhook**（企微群机器人、飞书自定义机器人）：只有 send，作为低敏通知的轻量出站通道。

### 5.3 TokenProvider 统一抽象

三渠道 token 生命周期同构（渠道笔记：每账号独立 secret → ~2h token → 缓存 + 提前刷新 + 失效重取），统一为一个凭据管理器：

```crystal
abstract class TokenProvider
  # 返回有效 token：缓存命中直返；临期(如剩余<30min)提前刷新；
  # 上游报失效(force 401/错误码)时重取一次并重放请求
  abstract def token : Token        # Token = {value, expires_at}
end
```

渠道差异吸收在子类：

- **企微**：`gettoken(corpid, corpsecret)`，`expires_in` 7200s；有效期内重复获取返回**相同 token**；企微可能**提前使 token 失效**，须实现失效重取；缓存按 `(corpid, agentid/secret)` 区分（渠道笔记 a4）。
- **飞书**：tenant_access_token（Client Credentials），最长 2h 以 `expires_in` 为准勿硬编码；剩余 >30min 重复调用返回同一 token；新版 JWT 格式长度增加，缓存/Header **预留 4KB**（渠道笔记 b3）。
- **Email**：每账号独立 OAuth refresh token；access token 过期时 XOAUTH2 失败→刷新→重认证连接（渠道笔记 c5）。

#### 5.3.1 限流桶（按 `(账号, 目标)` 建桶）

| 渠道 | 限流事实（渠道笔记） |
|---|---|
| 企微应用消息 | 同一成员 **30 次/分钟、1000 次/小时**（超出直接丢弃不下发）；基础频率每企业单 API 1 万次/分 |
| 飞书 | 复合频控任一上限触发即限流（HTTP 429）；发送消息对同一用户/同一群 ≤ **5 次/秒**；官方建议避开整点/半点 |
| Gmail | 单账号 **500 封/日**（触发限流封 1-24 小时） |
| 企微群机器人 | 20 条/分钟；超限 45009，第三方实践建议等 ~65 秒重试 |
| 飞书自定义机器人 | 单租户单机器人 100 次/分钟、5 次/秒 |

实现：每 `(account_id, target)` 一个 token bucket，发送前置检查，超限排队/退避；触发上游限流错误码（如企微 45009、飞书 429/230020）时记录并冷却。

### 5.4 Email 渠道接入方案

**路线裁决（2026-11-26，E.1-4 / #23）**：Gmail 账号**继续走应用专用密码 + IMAP IDLE / SMTP**，不迁 Gmail API。
依据：单账号个人规模下 IDLE 满足「秒级到分钟级」到达；Gmail API 需 GCP 项目、OAuth 同意屏与
Pub/Sub 拓扑，凭据面与运维成本都更大；M0 已用真实 Gmail 邮箱跑通收发（#20、PR #230）。
Gmail API 作为**存档备选**保留，切换条件见本节末。

**接收**（长连接型，见 §5.2）：

- **IMAP IDLE 常驻**（RFC 2177）：一次 IDLE 只监听一个文件夹（默认 INBOX）；每 **≤29 分钟**终止并重发
  IDLE（RFC 2177 建议；RFC 3501 §5.4 要求服务器 autologout ≥30 分钟）；NAT/中间设备可能掐断空闲 TCP，
  需应用层心跳与重连；重连后重新 SELECT，UIDVALIDITY 变化须作废旧游标并重建基线。
- **兜底轮询**（与 IDLE 并存）：独立 watchdog 每 **5 分钟**用**短连接**执行 `SELECT` + `UIDNEXT` 比对
  （必要时 `SEARCH UID <last+1>:*`），有新增即触发一次补收。短连接不复用 IDLE 连接，单账号占用 2 条
  （IDLE 1 + 轮询 1），在 15 连接上限内；IDLE 正常时轮询只是两条极小命令。
- **假活判定**：一个 IDLE 窗口内（≤29 分钟）未收到任何服务器响应（含 `OK` 收尾）即判连接假活，
  主动断开重连，不等 TCP 超时。
- **重连退避**：指数退避 **5s → 10s → 20s → 40s → 60s 封顶**，成功 SELECT 后重置；带 ±20% 抖动，
  避免多账号同拍重连。
- **游标**：首连以 `UIDNEXT - 1` 为基线（历史视为已读）；同 UIDVALIDITY 重连续用游标补收断线窗口；
  UIDVALIDITY 变化作废旧游标。

**认证**：basic auth 已死——Gmail 2025-03-14 起、Exchange Online 2022-10-01 起、
Outlook.com 2024-09-16 起 IMAP/POP/SMTP 密码登录停用（渠道笔记 c2/c3/c4）。
本路线用**应用专用密码**（Gmail，需账号开启两步验证）；XOAUTH2
（`base64("user=<email>\x01auth=Bearer <token>\x01\x01")`）为升级路径，切 Gmail API 时一并启用，
本轮不作为必需项。

**主机与端口约束**（当前实现）：`schema` 的 `smtp` 段只有 `port` / `tls`，**没有 `host` 字段**，
适配器把 `account.platform` 同时当 IMAP 与 SMTP 主机。因此 Gmail 只能填 `platform: imap.gmail.com`：

| 组合 | 结果 |
|---|---|
| `imap.gmail.com` + `465`/`implicit` | 可用：imap.gmail.com 同时提供 SMTPS 465，实测能走到 AUTH |
| `imap.gmail.com` + `587`/`starttls` | **不可用**：587 出示 smtp.gmail.com 证书，TLS 校验失败 |
| `smtp.gmail.com` 作 platform | 不可用：IMAP 993 连到 smtp.gmail.com 失败 |

新增 `smtp.host` 字段（或把 `examples/config.example.yaml` 的 `465 + implicit` 模板改掉）属实现改动，
现有模板对 Gmail 虽可用、对 587-only 服务商不适用，落实现时一并处理。

**多账号要点**（渠道笔记 c5）：Gmail 每账号同时 **15 个 IMAP 连接**上限（含全部后台连接——
**来源为第三方引用，渠道笔记标注未验证**）；每账号独立凭据与连接；统一连接池 + 每账号并发上限，
避免多组件对同一账号各开多连接。

**已知边界**（如实列）：

- Gmail IMAP IDLE 推送不可靠为社区长期报告，本项目**未实测**（渠道笔记 c1、§15.1.2）；
  兜底轮询与假活判定即为此设——**这两项与指数退避当前尚未实现**（见下方差距表），补齐前无此保护。
- 轮询间隔 5 分钟只在**轮询成功**时成立：IDLE 静默失效且轮询本身失败（网络、认证、服务端异常）期间没有任何到达保证，
  恢复后按退避重试；5 分钟不是无条件延迟上界。
- 进程重启后游标不持久：首连以 `UIDNEXT - 1` 重建基线，**停机窗口内到达的邮件不补投**
  （持久化游标与停机补收未实现）。
- 只监听 INBOX；其他文件夹/标签需多连接或轮换。
- 应用专用密码依赖两步验证，Google 账户安全策略可致其失效（#20 实测遇到过一次）。
- 发送限额：500 封/日（超限封 1–24 小时）；第三方 IMAP 客户端另有约 100 封/24h 的更低口径
  （未逐字核对，渠道笔记 c2）。
- 配置项 `receive` 的 `gmail-api` 值**尚无实现**：校验层放行但适配器不读取，等效静默降级为
  IMAP IDLE；实现该值时必须同时补 fail-closed 校验。

**设计口径与当前实现的差距**（截至 2026-11-26）：

| 机制 | 设计口径 | 实现状态 |
|---|---|---|
| IDLE ≤29 分钟重发 | 有 | 已实现（`read_timeout = idle_poll + 1min`，超时后 NOOP 重发） |
| 断线补收、跨重连游标、UIDVALIDITY 重建 | 有 | 已实现（PR #230） |
| 兜底轮询 5 分钟 | 有 | **未实现** |
| 假活判定 | 有 | **未实现** |
| 指数退避 5s→60s | 有 | **未实现**（`@backoff` 固定 5s，不递增） |

后三项需另开实现工作包；本条（E.1-4）只做路线裁决与文档回写。

**切换 Gmail API 的触发条件**（满足任一即重开 E.1-4；第 1、3 条要先补齐上文差距表的三项实现，
否则量不到真实基线）：

1. 真实 Gmail 账号上「IDLE + 兜底轮询」在连续 7×24 内漏收 ≥1 次，或到达延迟 P95 > 5 分钟；
2. 需要低延迟监听 INBOX 之外的文件夹/标签（IDLE 单连接单文件夹，多标签要多连接）；
3. 单个 Gmail 账号的连接数需超过 15（IDLE + 轮询默认 2 条，余量给多文件夹监听与其他组件）；
   多账号并存时按**每账号**计，不因账号数增加而互相挤占；
4. Google 收紧或取消应用专用密码 / IMAP 访问（政策变更或实测不可用）；
5. 需要 Gmail 语义能力（`historyId` 增量同步、`threadId`）或受限 scope 合规要求；
6. GCP 项目、OAuth 凭据与 Pub/Sub 拓扑已就绪，边际成本低于维持 IDLE 兜底。

切换时清单：GCP 项目 + OAuth 客户端；受限 scope 最小集（`gmail.readonly` + `gmail.send`，
优先于完整邮箱 `https://mail.google.com/`）；Pub/Sub topic + 订阅 + `users.watch` 续期（7 天）；
refresh token 入 vault；`receive: gmail-api` 接线与 fail-closed 校验。

### 5.5 企业微信（WeCom）接入方案

**主推：智能机器人（AIBot）长连接**（官方为 AI 助手场景设计；渠道笔记 a2）：
- `cmd=aibot_msg_callback` / `aibot_event_callback`，**明文推送、无需解密、免公网 URL**；多媒体资源每个下载链接对应唯一 `aeskey`（不同于统一 EncodingAESKey）。
- 天然支持一台机器同时维持**多个企业/多个机器人**的连接（渠道笔记 a5）。
- 回复：回调中透传 `headers.req_id` 回复。
- 注意：`from.userid` 创建者非超管时为**加密 userid**，需经应用接口转换。

**备选：自建应用回调**（渠道笔记 a1）：
- 验签：`msg_signature = SHA1(字典序排序(token, timestamp, nonce, encrypt))`。
- 解密：AES-256-CBC；`AESKey = Base64_Decode(EncodingAESKey + "=")`（43 字符→32 字节）；IV 取 AESKey 前 16 字节；PKCS#7 填充至 32 字节倍数；明文布局 `random(16B) + msg_len(4B 大端) + msg + receiveid`。
- **校验 `receiveid`(corpid) 防跨企业回调混串**——多企业账号并存的天然隔离锚点（回调按应用配置 URL，多应用可指向同一端点，按报文应用/机器人标识路由）。
- 时序硬约束：GET 验证 **1 秒内**回显明文；POST **5 秒内**响应否则断开重试（**总共 3 次**）；回调可能重复，按 **msgid 排重**；官方建议「立即应答、业务异步处理」——本平台回调 fiber 只验签+落库+入总线即返回。
- **Crystal 生态事实**：无官方加解密库，需自实现 AES-CBC + SHA1 + Base64（OpenSSL 绑定，工作量可控），并加对称测试（对照官方库向量，渠道笔记 a1/设计启示 5）。

**出站注意**：应用调用服务端 API 的出口公网 IP 必须配**企业可信 IP**（否则 60020）；已认证企业先配可信域名才能配可信 IP；**多账号平台的出口 IP 是共享资源**，IP 变更须同步更新各应用配置（渠道笔记 a6）。

**主动发消息**：`POST /cgi-bin/message/send`，agentid 必填，touser 最多 1000 人（渠道笔记 a7）。智能机器人主动发消息接口本轮调研**未逐页核对**（渠道笔记未验证 #3），实现前需补研。

### 5.6 飞书 / Lark 接入方案

**主推：WebSocket 长连接**（渠道笔记 b1）：
- 只需本机能访问公网，**无需公网 IP/域名/内网穿透**；内置加密与鉴权（无需验签/解密）。
- **硬限制（官方「注意事项」）**：仅支持**企业自建应用**（商店应用只能 Webhook）；收到消息须 **3 秒内**处理完成且不抛异常否则超时重推（按**事件 id** 排重）；**每应用最多 50 个连接**；推送为**集群模式、不支持广播**——同一应用多 client 部署时每条消息只由随机一个 client 收到（单机平台无碍；**横向扩展受限**，见 §15）。
- 3 秒约束同企微回调的应对：回调/长连接 fiber 只做验签+落库+入总线，业务异步处理（与企微「立即应答」同构）。

**备选：Webhook 回调**：URL 校验 challenge；签名校验（推荐）`X-Lark-Signature = sha256(X-Lark-Request-Timestamp + X-Lark-Request-Nonce + encrypt_key + body)`；配 Encrypt Key 后密文推送需解密；不配时仅有明文 Verification Token 比对，官方自评「安全性低」（渠道笔记 b1）。

**多账号要点**：
- **每租户各建一个自建应用**（多组 `app_id/app_secret` 并存，单进程分别取 token）——个人平台多飞书账号的最简路径（渠道笔记 b2）；商店应用（ISV）模式不采用（本轮未展开）。
- **base_url 必须入账号配置**：飞书 `open.feishu.cn` / Lark `open.larksuite.com`，用错报 `1000040351 Incorrect domain name`；**飞书与 Lark 是不同主体运营的独立产品，账号体系完全不互通**（渠道笔记 b4）——渠道类型统一为 `lark`，`platform` 字段区分。
