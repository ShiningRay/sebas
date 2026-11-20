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
3. **限流记账**：按 `(账号, 目标)` 维护 token bucket（§5.3.2）。
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

**接收**：
- 非 Gmail 邮箱：**IMAP IDLE 常驻**（RFC 2177）——一次 IDLE 只监听一个文件夹（默认只 IDLE INBOX）；每 **≤29 分钟**终止并重发 IDLE；NAT 可能掐空闲 TCP，需应用层心跳+重连；重连后重新 SELECT，UIDVALIDITY 变化需全量重扫；兜底轮询（渠道笔记 c1）。
- **Gmail**：官方推荐 **Gmail API `watch` + Cloud Pub/Sub** 推送（社区长期报告 Gmail IMAP IDLE 推送不可靠——**渠道笔记标注未实测，本设计照实引用**）；简化路径为 Gmail API 轮询。设计上 Gmail 账号走 API 而非依赖 IDLE。
- **认证**：basic auth 已死——Gmail 2025-03-14 起、Exchange Online 2022-10-01 起、Outlook.com 2024-09-16 起 IMAP/POP/SMTP 密码登录停用；须走 **XOAUTH2**（`base64("user=<email>\x01auth=Bearer <token>\x01\x01")`）；应用专用密码（Gmail，需两步验证）可作快速接入的过渡（渠道笔记 c2/c3/c4）。

**发送**：SMTP 465（隐式 TLS）/ 587（STARTTLS），禁 25 明文中继；XOAUTH2 认证。

**多账号要点**（渠道笔记 c5）：Gmail 每账号同时 **15 个 IMAP 连接**上限（含全部后台连接——**来源为第三方引用，渠道笔记标注未验证**）；每账号独立 refresh token 与刷新调度；统一连接池+每账号并发上限，避免多组件对同一账号各开多连接。

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
