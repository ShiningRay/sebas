# design.md 独立核验报告

> 核验方：大理寺卿（dalisi-qing）。核验日期：2026-11-18。
> 核验对象：`docs/agent-platform-design/design.md`（713 行，14 章+附录，工部尚书产出）。
> 核验依据：`docs/agent-platform-design/research/` 下六份调研笔记（Hermes / OpenClaw / Pi / autobot / 渠道 / 旁证）+ `src/autobot/` 真实源码行号抽查。
> 方法：只读核验。design.md 全文两遍通读；三份外部项目笔记逐断言回查；autobot 行号 8 处实抽源码；未跑任何命令、未改任何被核验文件。
> **版本说明（2026-11-19）**：本文仅核验早期设计快照；进程内 mrb_state/register(api)/mrb_close 相关断言已被现行 design.md §12 的子进程协议取代，不应继续作为当前契约引用。

---

## 一、总结论

**通过（附 6 项次要缺陷修订建议，不阻塞验收）。**

- 致命缺陷：**0**（无事实编造，无硬需求未满足）。
- 重要缺陷：**0**（无依据缺失，无章节间矛盾）。
- 次要缺陷：**6**（详见第四节；均为表述/引用精度问题）。

事实引用抽验 42 条（Hermes 16 / OpenClaw 14 / Pi 12）全部与笔记一致，未发现超出笔记范围发明的新「事实」；渠道技术细节 22 项数字逐个核对一致；autobot 源码行号 8 处实抽全部命中、零漂移；笔记标注「未验证」的条目（6 条）在正文与 §13.1 均如实标注，无一条被当成确证事实引用。

---

## 二、逐项核验结果

### 2.1 事实引用抽验（清单第 1 项）

**结论：42/42 一致，无发明。** 抽验密度超过任务书要求（各 ≥8 条）。

**Hermes 抽验 16 条，全部一致：**

| # | design.md 断言（行号） | 笔记依据 | 结果 |
|---|---|---|---|
| 1 | RoutingIdentity 双轴 transport/runtime（L17/L82） | hermes-agent.md §2 | ✅ |
| 2 | 路由未服务 profile 丢弃 fail-closed（L92） | §2 | ✅ |
| 3 | duplicate adapter park 不崩溃（L239） | §4.2 | ✅ |
| 4 | `/p/<profile>/` 前缀路由+404/401/403（L251） | §4.2 | ✅ |
| 5 | max_hops=4（L472） | §4.3 | ✅ |
| 6 | fire-and-forget + ack=queued（L470） | §4.3 | ✅ |
| 7 | 署名 `Message from 🤖`（L471） | §4.3（原文含 `(@<handle>)`，design.md 简化为 `<agent_id>`，语义等价） | ✅ |
| 8 | 回复默认不可再回复 expect_reply=false（L473） | §4.3 | ✅ |
| 9 | 审批超时 300s deny（L402） | §6 层 2 | ✅ |
| 10 | cron_mode/single_query_mode/unattended_mode 三键（L403） | §6 层 2 | ✅ |
| 11 | hardline blocklist（L405） | §6 层 2 | ✅ |
| 12 | 看不全命令只 Deny（L406） | §6 末 | ✅ |
| 13 | 空 admin 列表 fail-closed（L537） | §4.2 | ✅ |
| 14 | UnscopedSecretError（L534） | §2 | ✅ |
| 15 | ambient 凭据链不用（L539） | §2 | ✅ |
| 16 | 教训 1 双运行时 / 教训 2 contextvar / 教训 5 多进程共享单 SQLite（L44/L209/L655） | hermes-agent.md:179（反面2）、:182（反面5 教训 5 原文「多进程共享单 SQLite 是持续运维痛点」） | ✅ 三条教训均实锤 |

**OpenClaw 抽验 14 条，全部一致（含 1 条缩减表述，见次要缺陷 S3）：**

| # | design.md 断言（行号） | 笔记依据 | 结果 |
|---|---|---|---|
| 1 | 三概念正交 accountId/agentId/binding（L72） | openclaw.md:169（官方原文语义） | ✅ |
| 2 | 17 渠道多账号（L17） | §3 | ✅ |
| 3 | most-specific 层级（L87） | §9（简写，见次要缺陷 S1） | ✅ 层级语义保留 |
| 4 | defaultAccount 三规则（L91） | §3.5 | ✅ |
| 5 | `account: "*"` 语义（L91） | §3.5 | ✅ |
| 6 | 出站走默认账号（L93） | §3.5 | ✅ |
| 7 | 单 agent 默认 `agent:main:main`（L101） | §9 | ✅ |
| 8 | DM 默认共享单用户假设教训 5（L334） | §4.1/反面 5 | ✅ |
| 9 | dmScope per-account-channel-peer（L334） | §4.1 | ✅ |
| 10 | 每日笔记 memory/YYYY-MM-DD.md 被索引不自动注入（L347） | openclaw.md:96 逐字一致 | ✅ |
| 11 | 记忆=纯 Markdown+SQLite 检索层（L349） | §4.2 借鉴 5 | ✅ |
| 12 | webhooks `/hooks/wake` `/hooks/<name>` 同构（L462/L514） | §8 | ✅ |
| 13 | Tailscale/SSH 远程推荐（L501） | openclaw.md:39（官方推荐） | ✅ |
| 14 | joinIntro 零工具 60s / untrusted 包装 / 网络读取 taint（L563）；sandbox 自认非完美（L564） | §7.2 借鉴 8；§7.1/反面 4 | ✅ |

**Pi 抽验 12 条，全部一致：**

| # | design.md 断言（行号） | 笔记依据 | 结果 |
|---|---|---|---|
| 1 | 效应三明治三层（L375-377） | pi-durable.md §2 | ✅ |
| 2 | 明确拒绝事件溯源（L373） | §2 | ✅ |
| 3 | 一切皆 Task、phase checkpoint、从最后 checkpoint 续跑（L375-376） | §2 | ✅ |
| 4 | requestId exactly-once 建议用入站事件 ID（L385） | §3 | ✅ |
| 5 | replay safe 显式标注才重跑、未标注 interrupted（L386） | §4 | ✅ |
| 6 | memo first-write-wins（L387） | §4 | ✅ |
| 7 | restartLimit 默认 5（L391） | §4 | ✅ |
| 8 | subagent=ownership、ownerTaskId 找回（L477） | §3 | ✅ |
| 9 | working-set 内存模型（L336） | §2/§6 | ✅ |
| 10 | compaction summary 落下一 turn 边界、老消息永远留（L337） | §3 | ✅ |
| 11 | pi.usage 逐 provider/model/工具记账（L396） | §6 | ✅ |
| 12 | 发信幂等键类比 `payment-${task.id}`（L389） | 官方例在 pi-durable.md:71；「发消息必须幂等键」为笔记 §7.5 推论（pi-durable.md:108），design.md 用「类比」措辞，边界清楚 | ✅ |

**「未验证」条目引用情况专项检查**：Hermes 未验证清单 #2（developer-guide 索引级未深读）、OpenClaw 未验证 #3/#4/#6、渠道笔记未验证 #2/#3/#7、autobot 笔记未验证 7 条、Pi 笔记「全部未运行 demo」——design.md 无一处把上述条目当确证事实引用；反向核对 §13.1 六条未验证清单与正文标注（L288/L293/L312/L646-648）一一对应。**诚实性达标。**

### 2.2 渠道技术细节核对（清单第 2 项）

**结论：22 项数字/机制全部一致，未验证处全部照标。**

| design.md（行号） | 断言 | 笔记依据 | 结果 |
|---|---|---|---|
| L287 | IDLE ≤29 分钟终止重发；一次 IDLE 一个文件夹 | c1 | ✅ |
| L288 | Gmail IDLE 不可靠为社区报告且**照标未实测**；Gmail API watch+Pub/Sub | c1 | ✅ 照标 |
| L289 | basic auth 死亡时间线 Gmail 2025-03-14 / Exchange Online 2022-10-01 / Outlook.com 2024-09-16 | c3/c4 | ✅ 三个日期逐字一致 |
| L289 | XOAUTH2 base64 格式 | c3 | ✅ |
| L291 | SMTP 465/587，禁 25 | c2 | ✅ |
| L293 | Gmail 15 IMAP 连接**照标第三方引用未验证** | c5/未验证 #7 | ✅ 照标 |
| L278 | Gmail 500 封/日、封 1-24h | c2 | ✅ |
| L268 | 企微 gettoken expires_in 7200s、重复获取同 token、可能提前失效、缓存按 (corpid, agentid/secret) | a4 | ✅ 4 项细节全一致 |
| L269 | 飞书 tenant_access_token 最长 2h 以 expires_in 为准、>30min 重复调用同 token、JWT 预留 4KB | b3 | ✅ |
| L276 | 企微应用消息同一成员 30 次/分、1000 次/小时、**超出直接丢弃不下发** | 渠道笔记:64 原文「（超出直接丢弃不下发）」 | ✅ 逐字一致 |
| L277/L280 | 飞书复合频控任一上限即 429；同一用户/群 5 次/秒；避开整点半点；自定义机器人 100 次/分 5 次/秒 | b5（:117/:119） | ✅ |
| L279 | 企微群机器人 20 条/分、45009、~65 秒 | a3 | ✅ |
| L304 | 企微验签 SHA1 字典序(token,timestamp,nonce,encrypt) | a1 | ✅ |
| L305 | AES-256-CBC、AESKey=Base64(EncodingAESKey+"=") 43→32 字节、IV 前 16 字节、PKCS#7 至 32 字节倍数、明文 random(16B)+msg_len(4B 大端)+msg+receiveid | a1 | ✅ 五项细节全一致 |
| L307 | GET 1 秒回显、POST 5 秒、重试 3 次、msgid 排重、立即应答异步处理 | a1 | ✅ |
| L298-301 | AIBot cmd 双值、明文免公网、headers.req_id 回复、from.userid 加密需转换、多媒体唯一 aeskey | a2 | ✅ |
| L299 | 一进程多企业/多机器人并存 | a5 | ✅ |
| L310 | 可信 IP 60020、先配可信域名、出口 IP 共享 | a6 | ✅ |
| L312 | touser ≤1000 人；AIBot 主动发消息**照标未逐页核对** | a7/未验证 #3 | ✅ 照标 |
| L317-318 | 飞书 WS 仅自建应用、3 秒、50 连接、非广播随机 client、事件 id 排重 | b1 | ✅ |
| L321 | X-Lark-Signature sha256(timestamp+nonce+encrypt_key+body)；不配 Encrypt Key 官方自评安全性低 | b1/d3 | ✅ |
| L325 | base_url 二域错报 1000040351；飞书/Lark 账号体系不互通 | b4 | ✅ |

### 2.3 autobot 引用核对（清单第 3 项）

**结论：8 处行号实抽源码全部命中，零漂移。**（任务书要求 3-5 处，超量抽查）

| design.md 引用 | 真实源码位置 | 实抽结果 |
|---|---|---|
| `gateway.cr:76` 命名 fiber（L200/L214） | `src/autobot/cli/gateway.cr:76`：`spawn(name: "agent-loop") { agent_loop.run }` | ✅ |
| `manager.cr:25` Hash 按类型名（笔记 B2） | `src/autobot/channels/manager.cr:25`：`getter channels : Hash(String, Channel)` | ✅ |
| `manager.cr:49-61` 每渠道一 fiber（L200） | `src/autobot/channels/manager.cr:49-61`：`spawn(name: "channel-#{name}")` 循环 | ✅ |
| `manager.cr:194-197` union case/in（L204） | `src/autobot/channels/manager.cr:194-197`：`case event in Bus::OutboundMessage …` | ✅ |
| `queue.cr:12-15` capacity=100（L201） | `src/autobot/bus/queue.cr:12-15`：`def initialize(capacity : Int32 = 100)` | ✅ |
| `schema.cr:506-517` 编译期宏（L203） | `src/autobot/config/schema.cr:506-517`：`{% for provider_name in … %}` | ✅ |
| `events.cr:29-31` 会话键 `#{channel}:#{chat_id}`（L101，B4 证据） | `src/autobot/bus/events.cr:29-31`：逐字命中 | ✅ |
| `subagent.cr:83-85` 每任务一 fiber 零信号量（L483，B8 证据） | `src/autobot/agent/subagent.cr:83-85`：`::spawn do run_and_untrack…` 无并发控制 | ✅ |

注：行号全部正确，但 design.md 与笔记均用裸文件名，同仓存在 `channels/manager.cr` 与 `session/manager.cr` 两个 manager——见次要缺陷 S2。

### 2.4 两条硬需求回对（清单第 4 项）

**结论：两条硬需求均有实质设计，非口号。**

- **① 同渠道 N 账号**：贯穿性实质设计完备——配置树 `channels.<type>.accounts[]` 数组结构（L107-151，YAML 实例含 email×2 / wecom×2 / lark×2）；每账号监督 fiber 生命周期状态机（L221-239）；TokenProvider 按账号缓存（L254-270）；限流桶按 (账号,目标)（L272-282）；会话键含账号维度防撞车（L98/L333）；企微 receiveid(corpid) 校验防跨企业混串（L306）；M1 验收条款「同渠道 N 账号并存互不串扰（两企微账号同 chat_id 不撞会话）」（L632）。✅
- **② 用户可编排**：§7 专章实质设计——三段式统一触发模型含 cron 三态/消息/账号事件/审批回执/webhook 五源（L359-369）；效应三明治持久 Task 状态机（L371-379）；幂等三件套+发信幂等键（L381-391）；lease+预算+append-only 账本（L393-397）；审批节点含超时 deny/无人值守 deny/hardline（L399-406）；两条完整 YAML DSL 实例（L410-460，含 idempotency_key/approval/max_concurrent_key 实际用法）；§9 管理面 workflows CRUD+runs 回放（L515）；M2 验收条款（L633）。✅

### 2.5 Crystal 落地真实性（清单第 5 项）

**结论：9 行特性映射每行有具体场景+实证先例，无贴标签；无与 Crystal 语言事实相悖的说法。**

- 逐行检查 §4.2 映射表（L198-209）：fiber/Channel/select/宏/union/abstract/record/rescue/重连惯用法——每行「用在哪」均为具体模块场景（fiber-per-account、per-session worker、配置 schema 宏、事件分派等），「先例」均为已实抽的 autobot 行号。✅
- 语言事实核对：Crystal buffered Channel 满时 send 阻塞（L201 表述正确）；union type + case/in 分派（L204 正确）；编译期宏（L203 正确）；record 值语义（L206 正确）。design.md L215 明确承认「无 JS Proxy」并给 op-list 应对——**诚实承认语言限制而非虚构特性**。✅
- 唯一备注：L203 说宏用于「N 渠道 × N 账号 × 校验」样板生成，autobot 先例（schema.cr:506-517）是 provider 匹配循环——先例是「宏批量生成样板」这个模式本身，用途类比扩展，属合理设计推导而非事实断言。

### 2.6 内部一致性（清单第 6 项）

**结论：术语与结构全文一致，未发现章节矛盾。**

- 会话键格式 `agent:<agent_id>:<account_id>:<channel_type>:<peer>`：L98 定义 → L333 §6.1 复述一致 → L617 A9 改造点一致。✅
- Account/Agent/Binding 定义（L76-80）与全文使用一致；「凭据归 Account、不含渠道凭据」约束在 §10.1 凭据命名空间（L534）与 §10.2（L546）延续。✅
- 架构分层图（L22-42）与 §4.1 职责表、§5-§9 文字逐一对应。✅
- 渠道类型统一 `lark` + `platform` 字段区分（L325）：L27 架构图 `lark×N`、L138-151 配置树 feishu-main/lark-intl 双账号一致。✅
- 端口无冲突：新平台 HTTP `18790`（L173）与 autobot IPC 冒烟历史 `tcp:18791`（L496）区分清楚。✅
- 路线图 M0-M3（L629-634）与 §5/§7/§8 章节内容对应，验收要点可在各章找到支撑设计。✅
- 出站默认账号规则（L93）与 DSL 示例显式指定账号（L433/L453）不矛盾（规则仅作用于「未指定时」）。✅

### 2.7 诚实性（清单第 7 项）

**结论：达标。**

- 头部即声明「未动任何代码；用户未授权前不进入实现」（L3）、「未验证处照实标注，不凭空补事实」（L5）——实际执行兑现：6 条未验证全部双处标注（正文+§13.1），无遗漏、无升格。✅
- 推论与事实的边界基本清楚：L389 幂等键用「类比 Pi 官方支付示例」、L215 无 JS Proxy 用「应对」而非「Pi 支持」措辞。两处引用笔记推论小节（§7.5/§7.8）建议加「笔记推论」字样更严谨（见 S6）。✅（带改进建议）
- 未决问题如实列出：§13.1 六条未验证、§13.2 五条风险、§13.3 三条取舍、附录 4 条待用户决策。✅

### 2.8 首辅 10 条定调符合度（清单第 8 项）

**结论：10/10 遵循，无未说明的偏离。**

| # | 定调 | design.md 落点 | 结果 |
|---|---|---|---|
| 1 | 三正交概念 | §3 全章 | ✅ |
| 2 | 长连接优先 | L250「个人部署优先长连接」+ AIBot/飞书 WS 主推 | ✅ |
| 3 | 去全局单 Loop | L214 per-session worker 池（B3 修复） | ✅ |
| 4 | SQLite+幂等三件套 | L335/L381-391 | ✅ |
| 5 | 编排三段式+fail-closed | L359 三段式；L402-406 审批 fail-closed | ✅ |
| 6 | 防环参数化 | L472 max_hops 默认 4（照抄 Hermes 配置项；可配性建议明写，见 S5） | ✅ |
| 7 | 管理面双入口，只做其一列备选 | §9.1 主线双入口 + L506 备选显式列出 | ✅ |
| 8 | 显式消息传递替代 contextvar | L44/L209 | ✅ |
| 9 | 凭据 keyring+命名空间 | §10.2（渠道,账号ID）命名空间 | ✅ |
| 10 | 不做云托管 / A2A 本期不做 | L61/L63（A2A 留未来+微软原则依据） | ✅ |

---

## 三、缺陷清单

### 致命（事实编造 / 硬需求未满足）

**无。**

### 重要（依据缺失 / 内部矛盾）

**无。**

### 次要（表述与引用精度）

- **S1 · most-specific 层级为简写而非「照抄」**。design.md L84 标题称「照抄 OpenClaw 层级」，L87 实际写 `exact peer > parent peer > peer wildcard > guild > team > account > channel > fallback`；OpenClaw 笔记原层级为「exact peer > parent peer > peer wildcard > **guild+roles** > guild > team > account > channel > fallback **owner**」。漏了 guild+roles 一级和 fallback 的 owner 对象。most-specific 语义无碍，但「照抄」名不副实。
- **S2 · autobot 源码引用用裸文件名，同仓有同名歧义**。design.md L200/L214 写 `gateway.cr:76`，实际路径 `src/autobot/cli/gateway.cr`；更实质的风险：仓库同时存在 `channels/manager.cr` 与 `session/manager.cr`，裸写 `manager.cr:25`（笔记 B2、design.md §4.2 表）实现者可能读错文件。8 处行号本身全部验证无误，但路径应写全。
- **S3 · OpenClaw auth 模式集被缩减但措辞像全集**。design.md L501「`auth.mode: token | password | tailscale`（OpenClaw gateway.auth 模式集）」；openclaw.md:25 原集为 `token | password | tailscale | trusted-proxy | none` 五种。缩减是合理设计取舍（个人平台剔除 none/trusted-proxy），但「模式集」措辞易误读为全集，宜注「取子集，剔除 none/trusted-proxy」。
- **S4 · M0 验收用语与 Windows 优先不协调**。design.md L57「Windows 优先」，L631 M0 验收写「**kill -9** 后重启续跑」——kill -9 是 POSIX 信号，Windows 无此形态（等价强制杀进程 taskkill /F）。验收语句宜写跨平台表述（如「强制杀进程后重启续跑」）。
- **S5 · max_hops「参数化」未明写可配置**。L468 标题「参数化照抄 Hermes §4.3」，L472 正文只写「（默认 4）」，未明说这是配置项 `bot_loop_guard.max_hops`（Hermes 原文为配置项）。照抄语义可推出，宜补一句「可配置项」。
- **S6 · 两处笔记推论小节引用可加标注**。L389「（Pi §7.5 关键风险点）」与 L215「（Pi §7.8）」引用的是 Pi 笔记对本平台的设计推论小节（pi-durable.md:108 及 §7.8-7.9），非 Pi 框架官方机制本身（官方的幂等键示例与「无自动记录」事实分别在 :71 与笔记正文属实）。design.md 已用「类比」「应对」措辞做了区分，边界无欺，但加「笔记推论」三字更防误读。

---

## 四、修复建议（供工部尚书修订，均不阻塞验收）

1. S1：L87 层级补全为 `exact peer > parent peer > peer wildcard > guild+roles > guild > team > account > channel > fallback(owner)`，或将 L84「照抄」改为「简化采用」。
2. S2：§4.2 表与 §4.3 的 autobot 引用补全路径前缀（`cli/gateway.cr:76`、`channels/manager.cr:25/49-61/194-197`、`agent/subagent.cr:83-85`、`bus/events.cr:29-31`、`bus/queue.cr:12-15`、`config/schema.cr:506-517`）。
3. S3：L501 注明「OpenClaw 模式集之子集，剔除 none/trusted-proxy（个人平台无需）」。
4. S4：L631 改「强制杀进程（POSIX kill -9 / Windows taskkill /F）后重启续跑」。
5. S5：L472 补「（配置项 `bot_loop_guard.max_hops`，默认 4）」。
6. S6：L389/L215 引用处加「（Pi 笔记推论 §7.5/§7.8）」字样。

---

## 五、核验方法与证据索引（备查）

- design.md 两遍全文通读（1-713 行），行号锚定以第二遍为准。
- 三份外部笔记逐断言回查：hermes-agent.md（218 行）、openclaw.md（225 行）、pi-durable.md（145 行），关键回查行号：hermes:179（contextvar 教训）、:182（教训 5 多进程 SQLite）、openclaw:25（auth 模式集）、:39（Tailscale 推荐）、:96（每日笔记）、:169（三概念原文）、pi:71（payment 官方例）、:108（发信幂等键推论）。
- 渠道笔记关键行号回查：channels:64（30 次/分超出丢弃）、:117（飞书复合频控 429）、:119（5 次/秒）。
- autobot 真实源码 8 处实抽（本报告 §2.3 表，全部命中）。
- 未验证条目流转检查：六份笔记的未验证清单 ↔ design.md §13.1 六条 + 正文内联标注（L288/L293/L312）。
- 本核验未运行任何代码、未执行任何命令、未修改 design.md 与任何调研笔记（写入范围仅本文件）。

---

# 第二轮增量复核（2026-11-18 · 热更新+插件两章增补）

> 复核方：大理寺卿（dalisi-qing）。复核对象：工部尚书第二轮增补（新增 §11 配置热更新、§12 插件脚本层两章+全局联动改动），design.md 由 713 行增至 842 行。
> 复核依据：`research/crystal-hot-reload.md`（237 行，翰林院产出）+ 第一轮全量核验结论（本报告上文，未改动）。
> 范围：仅新增与改动部分；第一轮 8 项结论维持不变，第一轮 S1/S4 两处建议已确认修复（L89「简化采用」、L743「强制杀进程（POSIX kill -9 / Windows taskkill /F）」）。
> 工具预算：≤20 次（实际 15 次，含 3 次上下文压缩）。

## 一、总结论（第二轮）

**有条件通过：修订 3 项重要缺陷（I1-I3）后放行验收。**

- 致命：**0**（无事实编造；四条硬需求③④有实质设计非口号）。
- 重要：**3**（I1 未验证局限未转引、I2 插件工具审批衔接空隙、I3 管理面契约缺 reload 行——均为文档完备性/一致性缺口，非事实错误）。
- 次要：**2**（S7、S8）。

事实抽验 20 条（超任务书 ≥12 要求）全部与热更新笔记一致，无发明新事实；「未验证」条目 6/8 转引入 §15.1（遗漏 2 项，其中 1 项正在被引用=I1）；章节顺延后 24 处 §11-§16 交叉引用全部指向正确、零残留；新旧章矛盾检查通过 3 项、发现空隙 2 项（I2/S8）。

## 二、逐项复核结果

### 2.1 新增两章外部断言抽验（清单第 1 项）——20 条全一致

| # | design.md 断言（行号） | 笔记依据 | 结果 |
|---|---|---|---|
| 1 | Hermes #48693「detect config.yaml changes」2026-06 开放未实现（L580） | 热更新笔记 §7.2 | ✅ |
| 2 | PR #13217 打印「must restart the gateway」警告（L580） | §7.2 | ✅ |
| 3 | PR #66777 2026-09 插件 toggle 仍 restart、SIGUSR2「在途」（L580） | §7.2 | ✅ 含在途标注 |
| 4 | PR #37880 仅个别 key 进 `_CACHE_BUSTING_CONFIG_KEYS` 非全量热载（L580） | §7.2 | ✅ |
| 5 | OpenClaw `gateway.reload.mode` 默认 hybrid、hot/restart/hybrid/off 四模式（L581） | §7.1 | ✅ 内容一致（证据局限未随引，见 I1） |
| 6 | nginx 语义翻译：进程不重启整根换新、进行中 turn 旧快照跑完（L582） | §7.3 | ✅ |
| 7 | mrb.cr 全量 spec 84/0 **照标本地未提交**（L641+L767 #10 双处） | §8a/§9.6 | ✅ 零升格 |
| 8 | ZeroClaw ClawHub 41.7% 含漏洞+数百恶意、弃市场（L632 域内） | §8d | ✅ |
| 9 | `naqvis/file_watcher` 选型：ReadDirectoryChangesW/inotify 原生+失败降级 snapshot 轮询（L588） | §2 | ✅（省列 kqueue，Windows 优先语境不算错） |
| 10 | Atomic#swap 详注歧义**如实注明**：「T cannot contain any reference types」指算术版 swap，以 compare_and_set/get/set 清单为准（L590） | §3 | ✅ 任务书重点项，逐字一致 |
| 11 | stdlib 拒收 Hash#deep_merge（crystal issue #6791）、deep-merge.cr TODO（L622 域内） | §5 | ✅ |
| 12 | 数组合并语义=整体替换（OpenClaw/hydra 惯例）（L623 域内） | §5 | ✅ |
| 13 | Signal.trap 在 Windows 抛 NotImplementedError、IPC reload 为 Windows 主通道（L588） | §4+autobot cli/gateway.cr:67-69 | ✅ |
| 14 | cron `reload_if_changed` 先验后换 rescue 保旧先例（L589） | §1 cron/service.cr:275-290 | ✅ |
| 15 | loader.cr:152-166 现链复用+load_env_file 不新增 dotenv（L589/L625 域内） | §1/§5 | ✅ |
| 16 | RiteVM 无模块卸载→重载=mrb_close→新建→重 load（L660 域内） | §8c | ✅ |
| 17 | cinch 常量加载无卸载=天花板反衬（L662 域内） | §8d | ✅ |
| 18 | $SAFE：CRuby 2.7 已移除+mruby 现状**未逐字照标**（L648 域内+L767） | §8b/§9.5 | ✅ 零升格 |
| 19 | GC arena MRB_GC_ARENA_SIZE 默认 100、save/restore 每批宿主调用外包（L644 域内） | §8b | ✅ |
| 20 | H2O gembox 裁剪剔除 mruby-io/mruby-socket 先例（L651 域内） | §8b | ✅ |

任务书重点项逐一对号：Hermes 四证据链编号 ✅（#48693/#13217/#66777/#37880 四条全对）；OpenClaw hybrid 四模式 ✅；nginx 语义 ✅；mrb.cr 84/0 状态标注 ✅ 照标；ZeroClaw 41.7% ✅；file_watcher 选型 ✅；Atomic swap 详注歧义 ✅ 如实注明。**无超出笔记发明的新事实。**

### 2.2 未验证转引完整性（清单第 2 项）——6/8 转引，遗漏 2 项

热更新笔记 §9 共 8 项未验证，对照 design.md §15.1（新增 #7-#11 五行）：

| 笔记 §9 | design.md §15.1 | 结果 |
|---|---|---|
| #1 OpenClaw runbook 正文仅两镜像互证未逐字 | **无对应条** | ⚠️ 遗漏且被引用（I1） |
| #2 OpenClaw 插件 fault isolation 状态机页未取正文 | **无对应条** | ⚠️ 遗漏（未引用，S7） |
| #3 file_watcher Windows 实测 | #7 | ✅ |
| #4 Atomic snippet 编译冒烟 | #8 | ✅ |
| #5 mruby $SAFE 现状未逐字 | #10（与 #6 合并，标注清楚） | ✅ |
| #6 mrb.cr 84/0 本地未提交+issue #1 修复链未复核 | #10 | ✅ |
| #7 换 secret 后旧 token 失效行为 | #9 | ✅ |
| #8 Hermes SIGUSR2 落地进度仅核到 2026-09 | #11 | ✅ |

工部自报「5 条转引」与实测相符（#5/#6 合并为一行），但 8 项中 2 项遗漏。**I1 是实质问题**：L581 把「reload.mode 默认 hybrid 四模式」作正面教材陈述，该事实的证据局限（runbook 仅两镜像快照互证、未逐字核验）未随文标注、也未入 §15.1——违反 design.md L5 总声明「笔记中标注「未验证」处本文照实标注」。#2 未被 design.md 引用（12.5 对照依据用的是笔记 §8d 汇编表，非 fault isolation 状态机页），风险低，列次要。

### 2.3 章节顺延交叉引用一致性（清单第 3 项）——24 处全对，零残留

- grep `§1[1-6]` 全文 24 处引用逐一核对：L19/L20/L60/L61（→§11/§12 新章）、L69（「A1-A10 见 §13」已从旧 §11 顺延改对）、L70（「集中列于 §15」已顺延）、L323（「见 §15」横向扩展风险，已顺延）、L576/L600/L641/L767（→§15.1）、L635/L659/L663/L664/L684/L715/L744/L748/L778（→§11 各小节）、L636（→§13 目录 skills/）、L718/L746/L842（→§12 各小节）——**全部指向顺延后的正确章节**。
- 残留表述检查：grep「两条硬需求/14 章/十四章」零命中；「硬需求①/②专章」在 §5/§7 标题保留是正确编号体系（四行表 ①②③④ 与 §5/§7/§11/§12 一一对应）。
- §11.3 与 §12.1 互引（「与 §11 同构」「复用 §11 双通道」）指向热更新章正确；附录 5 与 §12.5 互引（L672↔L842）正确。

### 2.4 新旧章矛盾检查（清单第 4 项）——通过 3 项，空隙 2 项

- **§11.3 矩阵 vs §5.1/§5.3**：✅ 无矛盾。账号增删=监督体 fiber spawn/drain 与 §5.1 生命周期状态机（disabled 用户停用）兼容；渠道凭据保守换法（等 TTL≤2h 或失效标记）与 §5.3 TokenProvider「失效重取」语义一致。
- **§11 vs §14 路线图**：✅ M1 验收「运行中改配置不重启生效/写坏保旧报警/改端口需重启提示」逐条对应 §11.2②③与 §11.3 端口行；L748 排期依据（热更新排 M1 因账号增删即矩阵一行）论证充分。
- **§12 vs §14 路线图**：✅ M3 验收「watchdog 拦死循环/崩溃只重建该 state/改脚本热重载生效」逐条对应 §12.3 watchdog、§12.4 重建与先验后换。
- **§12 vs §10 安全模型**：⚠️ 空隙（I2，重要）：§12.5 能力注册最小面含「注册工具」，但插件注册的工具进入工具层后**如何声明 replay/risk 字段（§4.1/A9 注册表体系、§7.3 幂等三件套的工具级 replay 二分）与如何过 §10.3 审批链（层 2 危险命令审批、层 4「MCP/外部工具精确控制加载」）未定义**。§12.3 三闸管的是脚本执行边界（IO/内存/宿主 API 面），不管插件工具在工具层的审批语义。「注册工具」在最小面三条之内（非挂起项），配套安全语义缺失且未列入 §15 未决或附录 5——安全模型对插件工具存在覆盖空隙。
- **§12 vs §7 编排引擎**：⚠️ 轻微（S8，次要）：插件「钩子/定时」能力与 §7.1 统一触发模型（cron/消息/账号事件/审批回执/webhook 五源）的关系未说明——插件注册的定时动作是否构成第六种触发源、编排引擎是否消费插件钩子。附录 5 挂起了「自定义触发器注册」等更强能力，但「定时」本身在最小面内未被同列挂起，边界表述不完全。

### 2.5 四条硬需求专章回对（清单第 5 项）——③④均实质满足

- **③ 免重启热更新**：执行摘要 L19 满足路径（四正交件+每 turn 快照+Hermes 反面/OpenClaw 正面）与 §11 专章逐要素一致；L576 引用户原话；§2 目标 7、§13 目录 reload 管线、§14 M1 验收、§16 #34-37 五条对照链完整。✅
- **④ mrb.cr 插件**：执行摘要 L20 满足路径（独立 mrb_state/三闸/register/不做市场/SKILL.md 分工）与 §12 专章逐要素一致；L631 引用户原话；§2 目标 8/非目标 7、§13 src/plugins/、§14 M3 验收、§16 #38-41 四条对照链完整。✅

## 三、缺陷清单（第二轮）

### 致命

无。

### 重要

- **I1 · OpenClaw runbook 证据局限未转引**。热更新笔记 §7.1/§9.1 明标「runbook 正文仅两镜像快照互证、未逐字核验」；design.md L581 将「reload.mode 默认 hybrid（四模式）」作正面教材引用时未随文标注，§15.1 新增五条未验证中也无此条。违反 L5「未验证处照实标注」总声明。修复：L581 加「（笔记标注：runbook 仅两镜像互证未逐字）」或 §15.1 增补第 12 条。
- **I2 · 插件工具的安全语义衔接未定义**。「注册工具」在 §12.5 最小面内，但插件工具与 §4.1 工具注册表（replay/risk 类型级字段）、§7.3 工具级 replay 二分、§10.3 层 2/层 4 审批链的接口均未定义，且未列入 §15 未决或附录 5。修复：§12.3 或 §12.5 补一段「插件注册工具须声明 replay/risk、默认进 allowlist 需显式启用、危险工具走 §10.3 审批」，或将其列为附录 5 决策项。
- **I3 · 管理面契约表缺 reload 行**。§11.2①（L588）设计「IPC reload 命令复用 §9 NDJSON 命令面」，但 §9.2 契约表（8 个操作域）无 reload/config 相关行——Windows 主通道的触发命令在契约定义处不存在，内部矛盾。修复：§9.2 表「系统」域加 `system.reload`（或新增「配置」域：`config.reload / config.get / config.dry-run`）。

### 次要

- **S7 · 笔记 §9.2（OpenClaw 插件 fault isolation 状态机页未取正文）未转引**。该项未被 design.md 实际引用（12.5 依据为笔记 §8d 汇编表），风险低，但 §9→§15.1 转引完整性缺口（8 项缺 2）。
- **S8 · 插件「钩子/定时」与编排触发模型关系未说明**（见 2.4）。修复：§12.5「能力注册」行加一句「插件定时/钩子与 §7.1 统一触发模型的对接面随附录 5 一并决策」。

## 四、修复建议汇总（供工部尚书，I1-I3 为放行前置）

1. I1：L581 随文标注或 §15.1 增补（二选一，建议后者：补为第 12 条「OpenClaw runbook 四模式/默认 hybrid 仅两镜像互证未逐字」）。
2. I2：§12.5 能力注册行或 §12.3 补插件工具安全语义；至少列入附录 5 决策项。
3. I3：§9.2 契约表补 reload 操作（建议「系统」域加 `system.reload`，与 §11.2 IPC 命令、M1 验收闭环）。
4. S7：§15.1 随 I1 一并补转引第 2 条（一行即可：未被引用、备查）。
5. S8：§12.5 补一句与 §7.1/附录 5 的边界说明。

## 五、复核方法与证据索引（第二轮，备查）

- 热更新笔记 237 行全文通读；design.md 增量部分两遍通读（§1/§2 改动、§11 全文 574-628、§12 全文 629-678、§13-§16+附录 679-842）。
- 交叉引用 grep 两次：`^#{1,3} `（章节结构 63 处锚定）、`§1[1-6][^0-9]`（24 处引用逐处核对）、`两条硬需求|14 章|十四章`（零残留）。
- 精读取证：L577-592（11.1 业界对照+11.2 表）、L666-678（12.5 四要素表）、L754-771（§15.1 十一条原文）。
- 工部自报改动范围独立验证：章节实测（842 行、§11/§12 新增、§13-16 顺延）✅；硬需求表 2→4 行 ✅；§15.1 6→11 条 ✅；§16 33→41 条 ✅；附录 5 项 ✅；M0 kill -9 表述已修 ✅。
- 本轮未运行任何代码、未执行任何命令、未修改 design.md/research/src（写入范围仅本文件追加）。
- 第一轮 S2/S3/S5/S6 四处次要建议的修订情况未逐一复查（不在本轮增量范围；L748/§16 #24 显示部分行号已补全路径）。

---

# 第二轮修复点验（2026-11-18 · I1-I3/S7-S8 修订验证）

> 点验方：大理寺卿（dalisi-qing）。点验对象：工部尚书按第二轮结论修复的五处落点+随动重编号。方法：五处落点逐一实读原文对照修复要求；编号 grep+实读双重核对；I2 修复段与 §10.3/§4.1/§7.1/§7.3 逐一交叉。工具 5/8 次，未改 design.md。

## 点验结论：**放行验收**，留 1 个观察项（不阻塞）

## 逐项点验结果

| 项 | 修复要求（第二轮） | 实读落点 | 结果 |
|---|---|---|---|
| I1 | L581 随文标注或 §15.1 补第 12 条（建议后者） | **双落**：L582 随文「**证据局限**：runbook 官方正文未逐字取到（docs.openclaw.ai fetch 仅返回导航目录），上述细节来自 openclawlab.com 与 openclaws.io 两镜像搜索快照互证（§7.1/§9.1；已列 §15.1.12）」+ §15.1.12（L775）全文落位并回指「§11.1 引用的」 | ✅ 超要求（建议二选一，实做双落且互指） |
| I2 | §12.5 补插件工具安全语义段或列入附录 5 | L678-680 专段：插件工具**必须走 §10.3 审批链+§4.1 工具注册表同款登记**（risk/replay 类型级字段与内置工具同规格）；**默认 `risk: high`**（理由：插件代码不受平台 spec 门禁约束，fail-closed 从严）；审批沿用全局 approval.mode；command_allowlist 同样生效；§7.5 hardline 不可被插件 override；risk 调低权挂附录 5 待决策 | ✅ 三衔接点（§10.3/§4.1/默认从严）全接上 |
| I3 | §9.2 契约表补 reload 操作 | L525 新增「配置」域：`config.reload`（触发 §11.2 先验后换管线，返回接受/拒绝与原因）+ `config.status`（摘要哈希、最近 reload 结果、restart 类待生效项）；与 §11.2①「复用 §9 命令面」双向互指闭环；config.status 的 restart 项与 §11.3 矩阵、M1 验收「改端口需重启提示」三向呼应 | ✅ |
| S7 | §15.1 补一行转引 | §15.1.13（L776）：fault isolation 状态机页未取正文+如实注明「§12.5 生命周期设计未依赖其细节，仅作方向参照」（与第二轮判定一致） | ✅ |
| S8 | §12.5 补一句与 §7.1/附录 5 边界说明 | L681 并入 I2 段：钩子=生命周期事件观察者、定时=**复用 §7.1 cron 触发器通道、插件不自建调度循环**；能力收进主链路安全机制（无人值守 fail-closed、预算、lease）不另开旁路 | ✅ 超要求（消除「第六种触发源」歧义+安全收口） |

## 编号连续性（实读验证）

§15.1 全 13 条连续（7-13 实读：file_watcher/Atomic/换 secret/mrb.cr/SIGUSR2/runbook/fault-isolation）；§15.2 重排 14-20 连续；§15.3 21-23 连续；跨节 1-23 **无撞号无跳号**。§16 对照表仍 41 条未动。文档 842→850 行（+8 与四处增量吻合）。

## I2 修复新矛盾检查——无冲突

- 默认 risk:high vs §10.3 层 2：引用的 approval.mode/deny/command_allowlist/hardline 四机制名与层 2 原文逐一一致；「从严」方向与 §10.1 fail-closed 总原则同向。
- vs §10.3 层 4「精确控制加载哪些工具」：默认 high+全局审批=先控后放行，语义兼容。
- vs §7.3 工具级 replay 二分：「risk/replay 与内置工具同规格」=同机制不同默认值，无矛盾。
- vs §7.1：「定时=复用 cron 通道」与统一触发模型（cron 为五源之一）一致。

## 观察项（1 个，不阻塞放行）

- **O1**：L680 称「是否允许插件调低自身 risk 等级，列入附录 5 待决策」，但附录 5（L850）现行文字只列「首批暴露能力/更强能力（自定义触发器、消息改写钩子、记忆读写）」，**未含 risk 调低权条目**——挂起点声明与附录本体未同步。建议下次修订附录 5 时补一句「含插件工具 risk 等级调低权（§12.5）」；属文字同步，不影响安全设计实质（默认 risk:high 已 fail-closed）。

## 终局

三轮核验闭环：第一轮通过（次要 6）→ 第二轮有条件通过（重要 3+次要 2）→ 本轮五处修复全部落位、无新矛盾 → **design.md 850 行版放行验收**。遗留：O1 文字同步项+第一轮 S2/S3/S5/S6 修订情况仍属增量外未复查（不影响本轮放行判断）。
