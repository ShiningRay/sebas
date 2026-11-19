# Seneschal —— Crystal 多账号可编排 Personal Agent 平台 · 整体设计与方案（草案）

> 状态：**待用户过目**。本文档为调研后的整体设计草案，未动任何代码；用户未授权前不进入实现。
> 起草：工部尚书（gongbu-shangshu），2026-11-18。基于六份调研笔记：`research/hermes-agent.md`、`research/openclaw.md`、`research/pi-durable.md`、`research/autobot-architecture.md`、`research/channels-wecom-lark-email.md`、`research/prior-art-notes.md`（以下分别简称 **Hermes/OpenClaw/Pi/autobot/渠道/旁证**）。
> 事实性引用均锚定上述笔记；笔记中标注「未验证」处本文照实标注，不凭空补事实。

---

## 1. 执行摘要

**一句话定位**：运行在用户自己机器上的 **Crystal 单二进制** Personal Agent 平台——同时绑定**同渠道 N 个账号**（多个 email、多个企业微信、多个飞书/Lark），用户以「**触发→条件→动作**」编排自动化流程，并支持多 agent 协作。

**四条硬需求的满足路径**：

| 硬需求（用户原话） | 满足路径 |
|---|---|
| 「同时绑定多个比如 email、多个企业微信、多个 Lark 等等账号」 | **Account / Agent / Binding 三正交概念模型**：账号是配置树节点（`channels.<type>.accounts[]` 数组，每账号一套凭据+一条受监督的长连接），路由是显式绑定表；「账号数」不硬编码进任何渠道实现（OpenClaw §3 三概念正交 + Hermes RoutingIdentity 双身份解耦） |
| 「允许用户进行编排」 | **编排引擎**：触发（cron/事件/webhook 统一模型）→条件→动作三段式 DSL；执行采用持久 Task 状态机（意图先落库→执行效应→结果落库），幂等三件套保证崩溃恢复不重复发信（Pi §2/§4）；多 agent 协作带防环上限（Hermes Bot Mode §4.3） |
| 「修改了配置之后就要重启 gateway 感到十分厌烦……不重启热更新配置」 | **配置热更新四正交件**（§11）：触发（文件监听+IPC reload 双通道）→先验后换（校验失败保旧配置）→Atomic 整根换引用→组件重应用矩阵（数据类全热换、端口类标 restart，OpenClaw hybrid 语义）；「每 turn 取配置快照」保证 turn 内语义一致。Hermes 确认无热重载=反面教材（issue #48693 四证据链），OpenClaw reload 默认 hybrid=正面教材（热更新笔记 §0/§6/§7） |
| 「利用 mrb.cr 嵌入 mruby 来进行扩展……设计插件机制」 | **插件脚本层**（§12）：每动作独立裁剪 mruby 子进程（watchdog 可 kill）；gembox 无文件/网络 IO + 宿主能力白名单；JSON-like 协议；单文件 `.sebas-plugin` 分发与托管生命周期，不做市场；SKILL.md 承载知识文档（热更新笔记 §8；子进程修订见[可行性报告](review/m3-plugin-feasibility.md)） |

**核心架构（文字版分层图）**：

```
┌────────────────────────────────────────────────────────────┐
│ 管理面   TUI(NDJSON/IPC) ──┬── HTTP API(鉴权) ── Webhook 回调面 │
├────────────────────────────┴───────────────────────────────┤
│ 渠道适配层  每账号一个 adapter fiber（长连接型 / 回调型）        │
│            email×N │ wecom×N │ lark×N │ …（可插拔扩展）        │
├────────────────────────────────────────────────────────────┤
│ 入站事件总线  有界 Channel，事件携带账号上下文（无隐式全局态）    │
├────────────────────────────────────────────────────────────┤
│ 路由/编排层  Binding 路由表（most-specific）＋ 编排引擎        │
│            （触发→条件→动作，持久 Task，审批节点，预算/lease）   │
├────────────────────────────────────────────────────────────┤
│ Agent 执行池  per-session worker fiber 池（同会话保序、跨会话并行）│
├────────────────────────────────────────────────────────────┤
│ 工具层  注册表（replay 语义类型级）＋ ReAct 执行器 ＋ Skills    │
├────────────────────────────────────────────────────────────┤
│ Provider 层  实例池（每 agent 可绑不同模型/厂商）＋ 规格表        │
├────────────────────────────────────────────────────────────┤
│ 持久层  SQLite(WAL) 主存储 ＋ JSONL 人可读转录 ＋ 凭据 keyring  │
└────────────────────────────────────────────────────────────┘
```

差异化卖点：**单二进制部署**（Hermes 反面教训：Python+Node 双运行时安装面巨大）；**配置免重启热更新**（Hermes 无热重载痛点根治，OpenClaw hybrid 同款语义）；**显式消息传递替代隐式上下文**（Hermes contextvar 泄漏教训，Crystal 用带上下文的结构体经 Channel 传递，编译期防「读错凭据」）；**fail-closed 默认贯穿**（Hermes）。

---

## 2. 目标与非目标

### 2.1 目标（本期设计范围）

1. **多账号**：email / 企业微信（WeCom）/ 飞书（Feishu）/ Lark 三类渠道，每类支持 N 账号并存、互不串扰；接收侧优先长连接形态（免公网）。
2. **可编排**：用户以声明式 DSL 定义「触发→条件→动作」自动化；触发源覆盖 cron、消息事件、外部 webhook；动作可发消息、调工具、派 subagent、请求人工审批。
3. **多 agent**：平台内可定义多个 agent（大脑），经 binding 路由到不同账号/会话；agent 间可互发消息（带防环）；subagent 并行执行（带并发上限）。
4. **持久与恢复**：进程崩溃后从中断处精确续跑；发消息类副作用不因恢复而重复。
5. **管理面**：本地 TUI + HTTP API 双入口，账号 CRUD、编排 CRUD、审批交互、事件流订阅。
6. **个人部署友好**：单进程单二进制，Windows 优先（无 bubblewrap 场景用应用层安全策略），凭据不入明文配置。
7. **配置免重启热更新**：改配置（账号增删、路由、编排、凭据）进程不重启即生效；校验失败保旧配置不崩溃（触发→先验后换→换引用→组件重应用四正交件，§11）。
8. **插件脚本层**：裁剪 mruby 子进程执行的可选扩展模块——单文件 `.sebas-plugin` 包分发，宿主托管安装、启停、升级、回滚与卸载；脚本无直接文件/网络 IO，经 JSON-like 协议调用白名单能力（§12）。

### 2.2 非目标（scope 边界，防蔓延）

1. **不做云托管 / 多用户 SaaS**：个人平台，单用户所有（OpenClaw "shared multiplayer" 形态与 Hermes 多 profile 端用户鉴权均明确不在本期；Hermes 官方立场「A profile is a configuration, not a person」——本平台同此假设，个人使用，不做 profile 之上的多人鉴权）。
2. **不做 OpenClaw 兼容配置迁移**（旁证 §三.7：低优先级，个人新平台无此存量）。
3. **A2A 跨机协议不引入本期**：内部协作用原生 agent 间消息；A2A 留作未来跨机扩展（旁证：微软原则「内部优先原生 subagent、跨平台才 A2A」）。
4. **不做内核级沙箱**：Windows 无 bubblewrap，采用应用层策略（见 §10.4）。
5. **不改造 autobot 本身**：autobot 只作参考蓝本（可复用件按接口重写，A1-A10 见 §13）。
6. **不承诺未设计能力**：本草案中标注「未验证」「待补研」的项不构成承诺（集中列于 §15）。
7. **不做插件市场 / 不嵌 CRuby**：插件由开发者独立分发、用户从本地 `.sebas-plugin` 文件安装，不做远程市场或自动依赖下载（ZeroClaw 教训，热更新笔记 §8d）；CRuby 嵌入不做，宿主仅启动随平台交付的裁剪 mruby 解释器（§12.2）。

---

## 3. 核心概念模型：Account / Agent / Binding

三正交概念（融合 OpenClaw accountId/agentId/binding 与 Hermes RoutingIdentity 双身份解耦；OpenClaw §3、Hermes §4.2/§8.3）：

### 3.1 三概念定义

| 概念 | 定义 | 不包含 |
|---|---|---|
| **Account（账号）** | 一个渠道账号实例：`{account_id, channel_type, platform/base_url, credentials, token_ref, receive_mode}`。是「连接 + 凭据」的载体，只负责收发消息（渠道笔记设计启示 1） | 不含任何智能/人格/记忆 |
| **Agent（大脑）** | 一个人格化 agent 实例：人格（SOUL/system prompt）+ 记忆 + 会话库 + 工具集 + 模型配置 + 私有 cron（OpenClaw §9 agentId 语义；Hermes profile 的「完整 agent」减去凭据） | **不含渠道凭据**（与 Hermes profile 的关键差异：凭据归 Account，两轴正交） |
| **Binding（绑定）** | 路由表：把入站事件 `(channel_type, account_id, peer)` 映射到 `agent_id`，most-specific 优先（OpenClaw §9 binding 层级） | 不是配置的唯一真相源（只管路由） |

「哪个账号收」（transport）与「哪个 agent 执行」（runtime）是**两个可独立配置的轴**（Hermes RoutingIdentity：`transport_profile` / `runtime_profile`）。典型用法：两个企微账号（公司 A、公司 B）的消息都路由给同一个工作 agent；或一个 email 账号按发件人分流给两个 agent。

### 3.2 路由规则（most-specific 顺序，简化采用 OpenClaw 层级）

```
exact peer > parent peer > peer wildcard > guild+roles > guild > team > account > channel > fallback(owner)
```

- 同层按配置声明顺序；多字段之间 AND（OpenClaw §9）。
- `account: "*"` 匹配任意账号；省略 account 仅匹配该渠道默认账号（OpenClaw §3 语义细节：defaultAccount 显式配置 > 名为 default 的账号 > 排序第一个）。
- **fail-closed**：无匹配 binding 的入站事件**丢弃**并记审计日志（Hermes：路由到未服务 profile 即丢弃）。
- 出站：动作显式指定 `(channel, account, peer)`；未指定账号时走该渠道默认账号（OpenClaw 出站默认账号规则）。

### 3.3 会话键（含账号维度）

```
session_key = "agent:<agent_id>:<account_id>:<channel_type>:<peer>"
```

修复 autobot 的 `#{channel}:#{chat_id}` 无账号维度跨账号撞车问题（autobot B4：`bus/events.cr:29-31` 两个同渠道账号的同一 chat_id 会撞进同一会话文件）；`agent:` 前缀与 OpenClaw 单 agent 默认 `agent:main:main` 同构。

### 3.4 配置树示例（YAML）

```yaml
# config.yaml —— 顶层：channels / agents / bindings / workflows / gateway
channels:
  email:
    accounts:
      - id: personal-gmail            # Account：一个 email 账号
        platform: gmail.com
        receive: gmail-api            # Gmail 走 API（IDLE 不可靠，见 §5.4）
        smtp: { port: 465, tls: implicit }
        credentials:                   # 值经 ${ENV} 展开；敏感值入 keyring（§10.2）
          client_id: ${GMAIL_CLIENT_ID}
          refresh_token_ref: keyring:email/personal-gmail/refresh_token
      - id: work-outlook
        platform: outlook.office365.com
        receive: imap-idle            # 非 Gmail 邮箱走 IMAP IDLE
        credentials:
          client_id: ${OUTLOOK_CLIENT_ID}
          refresh_token_ref: keyring:email/work-outlook/refresh_token
  wecom:
    accounts:
      - id: company-a
        mode: aibot-longconn          # 智能机器人长连接（优先形态，§5.5）
        credentials:
          corpid: ${WECOM_A_CORPID}
          aibot_secret_ref: keyring:wecom/company-a/secret
      - id: company-b
        mode: app-callback            # 自建应用回调（备选形态）
        callback_path: /cb/wecom/company-b/
        credentials:
          corpid: ${WECOM_B_CORPID}
          agentid: 1000002
          token_ref: keyring:wecom/company-b/callback_token
          aes_key_ref: keyring:wecom/company-b/encoding_aes_key
  lark:
    accounts:
      - id: feishu-main
        platform: feishu.cn           # base_url 必须入账号配置（§5.6）
        receive: ws-longconn
        credentials:
          app_id: ${FEISHU_APP_ID}
          app_secret_ref: keyring:lark/feishu-main/secret
      - id: lark-intl
        platform: larksuite.com       # Lark 与飞书账号体系完全独立
        receive: ws-longconn
        credentials:
          app_id: ${LARK_APP_ID}
          app_secret_ref: keyring:lark/lark-intl/secret

agents:                              # Agent：大脑，可多实例
  main:
    model: deepseek/chat
    provider_ref: deepseek
    persona_file: agents/main/SOUL.md
    memory: { window: 50 }
    tools: { allow: ["*"] }
  work:
    model: anthropic/claude
    persona_file: agents/work/SOUL.md

bindings:                            # Binding：路由表（数组，most-specific 优先）
  - { channel: email, account: work-outlook, peer: "*", agent: work }
  - { channel: email, account: personal-gmail, peer: "*", agent: main }
  - { channel: wecom, account: company-a, peer: "*", agent: main }
  - { channel: lark,  account: "*",       peer: "oc_review_group", agent: work }

workflows: [ /* 编排定义，见 §7.6 */ ]

gateway:
  http: { bind: 127.0.0.1, port: 18790, auth: token }
  ipc: auto                          # NDJSON/IPC，见 §9
```

要点：`channels.<type>.accounts[]` 为**数组结构**，每项一个账号一套凭据（autobot B1 的改造方向：`accounts: Array[AccountConfig]`；OpenClaw 的具名账号条目同构）。配置加载沿用 autobot 的 `${VAR}` 展开 + chmod 0o600（autobot A 级件：`config/loader.cr` 机制），但**敏感值改为 keyring 引用**（`*_ref: keyring:<namespace>/<key>`，§10.2）。

---

## 4. 总体架构

### 4.1 分层职责

| 层 | 职责 | 关键设计 |
|---|---|---|
| **渠道适配层** | 维持每账号连接，收发消息，协议转换 | 每**账号**一个 adapter fiber + 监督 fiber；`abstract class ChannelAdapter` 扩展点；两形态归并（§5.2） |
| **入站事件总线** | 有界队列、事件路由、背压 | buffered Channel + 事件结构体显式携带 `(account_id, channel_type, peer)` 上下文 |
| **路由/编排层** | binding 查表、触发器求值、编排 Task 调度 | 路由是纯函数（配置快照原子替换）；编排引擎见 §7 |
| **Agent 执行池** | 执行 agent turn（LLM 调用 + 工具循环） | per-session worker fiber：同一会话保序、跨会话并行；全局并发上限 |
| **工具层** | 工具注册、执行、审批、Skills | 注册表声明 `replay` 语义与 `risk` 级别（类型级字段）；SKILL.md 免重编译扩展 |
| **Provider 层** | LLM 网关 | 实例池（每 agent 绑不同 provider/model）；规格表编译期常量 |
| **持久层** | 会话/任务/事件账本/审批/配置快照 | SQLite WAL 单写者；JSONL 转录归档；keyring |
| **管理面** | TUI + HTTP API 双入口 | §9 |

### 4.2 Crystal 实现要点（机制落到具体用法，均有 autobot 实证先例）

| Crystal 特性 | 用在哪 | 先例（autobot 笔记 §9 实证 14 条） |
|---|---|---|
| **fiber + spawn** | fiber-per-account（连接监督）、per-session worker、subagent | `cli/gateway.cr:76` 命名 fiber；`channels/manager.cr:49-61` 每渠道一 fiber；`agent/subagent.cr:83` 每任务一 fiber |
| **buffered Channel（有界队列）** | 事件总线、结果传递；满时 send 阻塞=协作式背压，无需锁 | `bus/queue.cr:12-15` capacity=100 |
| **select + timeout** | 消费循环可停机、OAuth 回调等待、审批等待 | `bus/queue.cr:32-43`、`auth.cr:102-108` |
| **编译期宏** | 配置 schema 样板生成（N 渠道 × N 账号 × 校验） | `config/schema.cr:506-517` `{% for %}` 批量生成 provider 匹配 |
| **union alias + case/in** | 事件类型分派（InboundMessage / OutboundEvent / TriggerEvent…） | `bus/events.cr:122` + `channels/manager.cr:194-197` |
| **abstract class** | ChannelAdapter / Provider / Plugin / ToolObserver 扩展点 | `base.cr:19`、`provider.cr:14`、`plugin.cr:40` |
| **record（值语义）** | 事件、DTO、Task checkpoint | `bus/events.cr:116-122` record TurnEnded |
| **typed rescue 转值** | 错误不炸进程：工具错误转 `ToolResult.error`，LLM 错误转 Response | `http_provider.cr:83-87`、`registry.cr:75-123` |
| **无限重连循环惯用法** | 账号连接生命周期：`@running` flag + while + begin/rescue/sleep（指数退避） | `zulip.cr:44-60`、`slack.cr:41-64` RetryBackoff 5s→60s |
| **显式消息传递** | 上下文经结构体传递，**不用隐式全局可变状态**（Hermes contextvar 教训的反面：scope 由类型/构造器保证） | Hermes §8 反面教训 2：「隐式 scope 的漏」 |

### 4.3 进程模型

- **单常驻进程**为主：渠道连接、编排引擎、agent 池、HTTP API、IPC server 全在一个进程（OpenClaw 单 Gateway 模式；Hermes 教训：多进程共享单 SQLite 是运维痛点——本平台单进程天然规避，CLI/TUI 以客户端身份连入而非直开数据库）。
- 并发模型去 autobot 全局单 Loop（autobot B3：`cli/gateway.cr:76` 唯一 agent-loop fiber，一个慢 turn 阻塞所有会话含 cron/subagent 汇报）：**per-session worker 池**——会话首次入站时按 session_key 分配/复用 worker fiber，保证同会话顺序，跨会话/跨账号并行；worker 池有全局上限（防 fiber 失控，§8.3）。
- **无 JS Proxy 的应对**（Pi 笔记推论 §7.8）：文档 patch 不做自动记录，采用 **op-list 路线**——编排 DSL 的动作即操作序列，文档状态是其物化视图；agent 记忆文件用整文件写替换（autobot `memory.cr` 已是此模式）。

---

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

---

## 6. 会话与记忆

### 6.1 会话管理

- **会话键含账号维度**（§3.3）：`agent:<agent_id>:<account_id>:<channel_type>:<peer>`。
- **路由粒度按对话形态**（OpenClaw §4.1 借鉴）：DM 默认 per-account-peer 隔离（多账号下必须，OpenClaw 教训 5：DM 默认共享是单用户假设，多人/多账号串台后补课）；group/room 按群隔离；cron/workflow 每次运行独立会话；webhook 按 hook 隔离。
- **SQLite 主存储 + JSONL 转录双写**：SQLite（WAL）存平台权威状态（会话消息、任务、事件账本、审批）；JSONL 按会话键分文件作**人可读转录归档**（保留 autobot A4 的运维友好性：文件即会话、0o600 权限、可 grep）。
- **working-set 内存模型**（Pi §2/§6）：只驻留活跃会话（活跃 transcript + live task + inbox），其余落盘；会话内存上界锚定「模型上下文窗口 + 固定余量」而非消息条数——支撑「数年消息史」。
- **compaction**：接近上下文上限时压缩，summary 落在下一 turn 边界；老消息永远留在存储不删，配 FTS5 事后检索（Pi §3 机制）。

### 6.2 记忆分层

| 层 | 内容 | 存储 |
|---|---|---|
| SOUL.md | agent 人格（system prompt 的一部分） | 每 agent 目录，人可读 Markdown |
| MEMORY.md | 长期精选事实，会话启动注入 | 每 agent，人可读 Markdown（整写替换） |
| USER.md | 关于用户（owner）的稳定偏好 | 每 agent，人可读 Markdown |
| HISTORY.md | 追加式过程日志，grep 可查 | 每 agent（autobot A5 双文件机制保留） |
| 每日笔记 | memory/YYYY-MM-DD.md，被索引不自动注入 | 每 agent（OpenClaw §4.2 形态） |

- 原则：**记忆主体是纯人可读 Markdown，SQLite 只做检索层**（OpenClaw 借鉴 5：可解释、可手改、可 git 管理）。
- **巩固流程**：会话消息数超 `memory_window` 时后台 fiber 用 LLM 产出更新（autobot A5：`memory_manager.cr` 机制；注意其教训——巩固不得与用户 turn 共用全局单 provider，须用该 agent 绑定的 provider 实例）。
- **FTS5 检索**：会话与记忆全文索引建在主 SQLite（Hermes FTS5 session search 同路线；旁证建议 4：多账号会话量下 grep 两层不可持续，直接上 FTS5）。

---

## 7. 编排引擎（硬需求②专章：用户可编排）

### 7.1 三段式原语

**触发 → 条件 → 动作** 是编排的唯一原语；cron、事件触发器、webhook 统一归入触发源：

```
TriggerEvent ──→ [条件求值] ──→ [动作序列执行（持久 Task）] ──→ 产出（发消息/写状态/审批）
   ↑
   ├─ cron 触发（At / Every / Cron 表达式三态，autobot A10）
   ├─ 消息事件（email/wecom/lark 消息到达，含账号维度过滤）
   ├─ 账号事件（连接断开/恢复、token 失效等生命周期信号）
   ├─ 审批回执（approval 结果回流）
   └─ webhook（外部系统 POST /hooks/<name>，带鉴权）
```

### 7.2 执行语义：效应三明治 + 持久 Task（Pi §2 采纳）

编排执行采用 Pi Durable 的**效应三明治**（明确拒绝事件溯源）：

1. **执行前**：意图先落库（Task 表 insert：workflow_id、参数、phase=0）——写完即崩，重启后看到已验证输入、尚未运行的操作，直接接着运行。
2. **执行中**：每个动作一个 phase，phase 尾 commit checkpoint；崩溃后从**最后一个 checkpoint** 续跑（重放单位 = phase，不是事件流）。
3. **执行后**：结果落库，三明治完成，中间态可弃（留审计 trace）。

**任务树**：编排 run 是 Task 树（run → 动作节点 → 工具调用），subagent 动作是**被拥有的子任务**（Pi ownership 模式：崩溃重跑经 ownerTaskId 找回同一个子任务）。

### 7.3 幂等三件套（全采纳，Pi §4）

| 层 | 机制 | 本平台落地 |
|---|---|---|
| 提交级 | `requestId` exactly-once，建议直接用入站事件 ID | 触发事件 ID 即 requestId；重复投递（企微重试 3 次、飞书超时重推、webhook 重试）返回原结果不重跑 |
| 工具级 | `replay: "safe"` 显式二分；**未标注一律不重跑**，模型收到 interrupted 自行决策 | 工具注册表类型级字段；只读/整文件写入标 safe |
| 决策级 | memo first-write-wins | 审批结论、条件求值结果存 memo，崩溃重跑读到已存答案不再重复决策 |

**发消息类工具必须带幂等键**（Pi 笔记推论 §7.5 关键风险点）：`send:${account_id}:${msg_uuid}`——否则崩溃恢复会**重复发信**。类比 Pi 官方支付示例 `payment-${task.id}`。

**崩溃循环防护**：`restartLimit`（默认 5）——确定性崩溃（如内存耗尽）导致 resume-再崩循环时，连续被打断 5 次的任务**终止而非再跑**，错误上报（Pi §4）。

### 7.4 任务 lease、回收与预算（旁证 §一.1 六坑迁移）

- **lease + 过期回收**：动作任务带租约与超时，超时未心跳即回收重派或标记失败（旁证：队列型机制「任务须 lease+过期回收」最值得抄进编排内核；autobot 教训 B8：无上限无回收的 subagent 是放大器）。
- **预算**：每 workflow / 每 agent 可配 token 花费上限（`pi.usage` 式逐 provider/model/工具记账，Pi §6）；超限熔断并告警（旁证坑 5：token 花费须聚合）。
- **append-only 事件账本**：触发、条件求值、动作执行、审批全记入不可变账本（SQLite append-only 表），供审计与 runs 回放（旁证：vibey-engine append-only 账本）。

### 7.5 人工审批节点

- approval 动作节点：`pending → approved / denied / timeout`。
- **超时即拒（fail-closed）**：默认 300s（Hermes §6 层 2）。
- **无人值守默认 deny**：由 cron / webhook / 事件触发（无人可答场景）的 workflow 中，危险动作默认拒绝（Hermes：`cron_mode`/`unattended_mode` 三键默认 deny）。
- **审批模式**（借鉴 Hermes）：`smart`（辅助 LLM 评风险）/ `manual` / `off`，默认 manual 起步。
- **hardline blocklist**（不可 override 的地板）：`rm -rf /` 及变体、fork bomb、mkfs 活动根、Windows `Format-Volume`/`rd /s /q C:\`、`Restart/Stop-Computer` 等——在一切模式之上仍拒绝。
- 审批通道：管理面（TUI/HTTP）+ 绑定的消息渠道（审批卡）双通道；**看不全的命令只给 Deny 选项**（Hermes 细节级借鉴：绝不让人批准被截断的命令）。

### 7.6 DSL 示例（YAML）

```yaml
workflows:
  - id: inbox-triage
    description: "工作邮箱收件分流摘要"
    enabled: true
    trigger:
      type: event                          # 统一触发模型
      source: email.work-outlook.message.received
    condition:                             # 声明式谓词（v1 不做图灵完备）
      all:
        - from_matches: "*.notify@github.com"
        - subject_contains: "PR merged"
    actions:
      - id: summarize
        tool: subagent.ask                 # 动作 = 工具调用（含内置工具）
        args:
          prompt: "总结该 PR 变更要点"
          max_concurrent_key: inbox-triage  # 共享信号量（§8.3）
        replay: safe                       # 只读，可安全重跑
      - id: notify
        tool: message.send
        args:
          channel: lark
          account: feishu-main             # 显式指定出站账号
          peer: "oc_review_group"
          content: "${summarize.result}"
        idempotency_key: "notify:${trigger.event_id}"   # 发信幂等键
      - id: archive
        tool: label.apply
        args: { mailbox: work-outlook, label: processed }

  - id: weekly-report
    trigger:
      type: cron
      schedule: "0 9 * * 1-5"              # 工作日 9 点（cron 三态之表达式态，A10）
    actions:
      - id: gather
        tool: subagent.ask
        args: { prompt: "汇总本周工作邮箱要点", budget_tokens: 20000 }
      - id: send
        tool: message.send
        args:
          channel: wecom
          account: company-a
          peer: "userid_of_me"
          content: "${gather.result}"
        idempotency_key: "weekly:${trigger.scheduled_at}"
        approval:                          # 人工审批节点
          mode: manual
          timeout_seconds: 3600            # 超时即拒（fail-closed）
```

外部 webhook 触发示例：`POST /hooks/wake`、`POST /hooks/<name>`（带鉴权；OpenClaw §8 inbound webhooks 同构）。

---

## 8. 多 Agent 协作

### 8.1 Agent 间消息（防环三件套，参数化照抄 Hermes §4.3）

- 工具 `message_agent(agent_id, content)`：**fire-and-forget**——发送方收 `ack=queued + delivery_id`，对方完成后带回复通知。
- **署名**：消息自动带前缀 `Message from 🤖 <agent_id>:`，收方知道来源。
- **防环上限**（配置项 `bot_loop_guard.max_hops`，默认 4）：一轮交换内 agent-to-agent 传递上限，超过拒发——防 agent 互发死循环。
- **回复默认不可再被回复**（`expect_reply=false`）：单向通知不产生回声链。

### 8.2 subagent（并行执行单元）

- subagent = **被拥有的会话/任务**（Pi §3：工具在 commit 内创建 ownership 子会话，崩溃重跑经 ownerTaskId 找回同一个）。
- 受限工具集：剔除 message/spawn 等社交工具、不能递归、不看主会话历史（autobot §8 现成先例：`create_subagent_registry`）。
- 结果以系统消息回注发起方的下一 turn（autobot `announce_result` 模式），但**不再依赖全局单 Loop**——直接投递到该 agent 的会话 worker（B3 修复）。

### 8.3 并发上限（信号量）

- autobot 教训 B8：`agent/subagent.cr:83-85` 每任务一 fiber、零信号量，多账号场景放大成资源失控。
- 本平台：subagent 并发用**命名信号量**（semaphore pool）约束，默认 `max_concurrent = 3`（可配；autobot 曾提议同值未实现）；workflow 可用 `max_concurrent_key` 共享同一个信号量（如「最多 2 个并发摘要任务」）。
- agent turn 的 worker 池同样有全局上限；请求超上限进入每会话队列排队（不丢弃、不饿死：队列按会话分片）。

---

## 9. 管理面与控制协议

**架构级前置决策：先定通信契约**（旁证 §一.6 教训：没有管理面协议，任何编排面板都接不上——autobot `-p PORT` 只打印不监听的历史教训）。

### 9.1 主线：双入口（NDJSON/IPC TUI + HTTP API）

**入口 A：NDJSON over IPC**（本地 TUI）——复用 autobot 已验证模式（旁证 §一.7，713ed632 已过 spec+Windows 冒烟）：
- 协议：NDJSON 一帧一行、**8MiB 上限、首帧 hello、caps/版本校验**；discovery 文件复用 token；`--ipc auto|unix:PATH|tcp:HOST:PORT`（Windows 下 unix socket 不可用时 fallback `tcp:127.0.0.1`，autobot `--ipc tcp:18791` 已冒烟通过）。
- 优点：本地使用不开网络端口，攻击面小。

**入口 B：HTTP API（带鉴权）**——与**渠道回调面共用同一个 HTTP 监听器**：
- 反正要为回调型账号（企微自建应用/飞书 webhook）开 HTTP 面，管理 API 挂同一端口统一鉴权（旁证 §三.1 建议：管理面与渠道回调可共用一个带鉴权 HTTP 面）。
- 默认 `bind 127.0.0.1`；远程访问建议 Tailscale/SSH tunnel（OpenClaw 同款推荐）；`auth.mode: token | password | tailscale`（OpenClaw 模式集之子集，剔除 none/trusted-proxy——个人平台无需）。
- SSE 事件流：`events.subscribe` 推送运行事件（编排 run 进度、账号健康、审批请求）。

**理由**：TUI 本地零端口；HTTP 面是回调账号的必需品，管理 API 搭车零额外暴露；未来 Web 编排面板消费同一 API，无需新协议。

**备选**（列为弃选但保留）：只做其一——只 IPC（无 Web 面板与远程管理能力）或只 HTTP（本地 TUI 也要走网络栈、Windows 防火墙交互）。主线双入口覆盖两者的短板。

### 9.2 契约草案（双入口共用语义，传输不同）

| 域 | 操作 |
|---|---|
| 账号 | `accounts.list / create / update / delete / enable / disable`；`accounts.status`（连接状态、token 状态、限流水位、最近错误） |
| 渠道回调 | `POST /cb/<channel>/<account_id>/<path>`（验签→落库→入总线，§5.2） |
| Webhook | `POST /hooks/wake`、`POST /hooks/<name>`（带鉴权，触发 workflow） |
| 编排 | `workflows.list / create / update / delete / enable`；`runs.list / get / replay`（账本回放）；`runs.cancel` |
| 审批 | `approvals.list / approve / deny`（含 pending 队列、超时策略展示） |
| 事件流 | `events.subscribe`（SSE / NDJSON 推送，按域过滤） |
| 会话 | `sessions.list / read`（只读查看，转录归档） |
| 插件 | `plugins.list / get / validate / install / enable / disable / activate / rollback / uninstall`；安装/升级传本地包路径，新增 capability 必须显式确认；卸载前执行引用检查（§12.7~§12.10） |
| 系统 | `system.health`（进程、SQLite、fiber 概况） |
| 配置 | `config.reload`（触发 §11.2 先验后换管线，返回接受/拒绝与原因）；`config.status`（当前配置摘要哈希、最近 reload 结果、restart 类待生效项） |

契约版本化：协议带版本号与 caps 协商（NDJSON 首帧 hello 已有此机制；HTTP 走 `/api/v1/` 前缀）。

---

## 10. 安全模型

### 10.1 fail-closed 清单（默认贯穿，Hermes §6/§8 借鉴 4）

| 场景 | 默认行为 |
|---|---|
| 路由无匹配 binding | **丢弃** + 审计日志（Hermes） |
| 回调无对应 adapter / 验签失败 | 404 / 401-403（Hermes） |
| 企微回调 receiveid(corpid) 不匹配 | 拒绝（防跨企业混串，渠道笔记 d3） |
| secret 无 scope（工具试图读不属于当前账号/agent 的凭据） | **raise 拒绝**（Hermes `UnscopedSecretError`；本平台经类型系统：凭据句柄构造时绑定账号命名空间，拿不到别人的句柄） |
| 审批超时 / 无人值守 | **deny**（Hermes 层 2 三键） |
| 审批卡展示不全的命令 | 只提供 Deny（Hermes 细节级借鉴） |
| 配置未加载时的 admin 列表 | 空列表=无管理员=拒绝（Hermes） |
| 重复凭据注册 | park 拒绝启动，不崩溃（Hermes） |
| 云端 SDK ambient 凭据链 | 不使用；账号无完整凭据则该 provider 拒绝（Hermes §2） |

### 10.2 凭据保护

- **从明文 YAML 迁到 OS keyring / 静态加密**（autobot B10 教训：明文 YAML+.env 仅 chmod 0o600）：
  - 首选 OS 凭据库：Windows Credential Manager / macOS Keychain / Linux secret service，主密钥托管于此；
  - 存量静态加密：AES-256-GCM 加密 secret 文件，主密钥入 keyring（OWASP Secrets Management 参考路线，渠道笔记 d1 工程建议）。
- **命名空间隔离**：key 按 `(渠道类型, 账号ID)` 命名空间（渠道笔记 d1）；日志全程脱敏 token/secret（autobot 已有 `LogSanitizer.redact_credentials` 可搬，A9）。
- **支持轮换**：企微/飞书 secret 均可在管理后台重置，OAuth refresh token 可撤销；管理面提供 `accounts.rotate-credential`。
- **最小权限**：企微应用可见范围最小化、secret 按能力拆分；飞书应用按需申请 scope；Gmail「不需要完整邮箱 scope 时改用 Gmail API 细粒度受限 scope」（渠道笔记 d2）。
- 官方底线遵守：secret/token 只存服务端（本平台进程），不入前端/安装包/日志（渠道笔记 d1 三家一致原文）。

### 10.3 审批链

分层（借鉴 Hermes 八层中适用于个人平台的子集）：

1. **用户鉴权**（谁可对话）：渠道级 allowlist（autobot `allowed?` 的 `"*"`/ID 管道匹配机制保留，A 级件）→ 全局 allowlist → **默认 deny**。
2. **危险命令审批**：`approval.mode: smart|manual|off` + `timeout deny` + `deny`（用户 fnmatch 黑名单）+ `command_allowlist` + **hardline blocklist 不可 override**（§7.5）。
3. **文件写安全**：protected paths 硬拒（`~/.ssh/`、`~/.aws/`、`.env`、token 缓存等；Hermes 层 3）。
4. **MCP/外部工具**：精确控制加载哪些工具；工具花费上限是预算不是提示。

### 10.4 Sandbox 策略（Windows 个人部署）

- **应用层策略**而非内核沙箱：Windows 无 bubblewrap；autobot 的 bwrap/docker 路线在 Windows 不可用（旁证 §三.5）。
- 机制：workspace_only 路径校验（工作区外的写需审批）+ 系统敏感目录屏蔽 + 外部内容一律按 untrusted 包装（OpenClaw 借鉴 8：joinIntro 零工具、网络读取 taint 当前 turn）。
- **诚实文档化**：sandbox 自认非完美边界，写清「做不到什么」（OpenClaw 反面教训 4：read-only mount 只防改不防读等局限要在文档明示）。
- Gateway 默认 localhost-only；远程走 Tailscale（§9.1）。

---

## 11. 配置热更新（硬需求③专章：免重启重载）

> 用户原话：「在深度使用 Hermes 的过程中，我对于修改了配置之后就要重启 gateway 感到十分厌烦，请调研 crystal 中如何不重启热更新配置」。本章依据 `research/crystal-hot-reload.md`（以下称**热更新笔记**）；结论均有先例锚定，未验证处照实标注（§15.1）。

### 11.1 痛点定位与业界对照

- **反面教材 Hermes**：确认无热重载——四证据链（均为仓库 issue/PR）：issue #48693（「detect config.yaml changes without /restart」，2026-06 开放未实现）；PR #13217（CLI 改配置后打印「must restart the gateway」警告）；PR #66777（2026-09 插件 toggle 仍提示 restart，SIGUSR2 reload 「在途」）；PR #37880（仅个别 key 进 `_CACHE_BUSTING_CONFIG_KEYS` 缓存失效名单，非全量热载）（热更新笔记 §7.2）。用户厌烦的正是此缺陷。
- **正面教材 OpenClaw**：reload 是一等公民——`gateway.reload.mode` 默认 **hybrid**（hot / restart / hybrid / off 四模式）：多数改动静默热应用，结构性改动须重启（热更新笔记 §7.1）。**证据局限**：runbook 官方正文未逐字取到（docs.openclaw.ai fetch 仅返回导航目录），上述细节来自 openclawlab.com 与 openclaws.io 两镜像搜索快照互证（热更新笔记 §7.1/§9.1；已列 §15.1.12）。
- **语义参照 nginx**：`nginx -s reload`=SIGHUP → master 重读配置 → 新 worker 起旧 worker 优雅收尾。单进程 Crystal 翻译：**进程不重启、配置整根换新；进行中的 turn 用旧配置快照跑完，新 turn 用新配置**（热更新笔记 §7.3）。

### 11.2 四正交件架构（触发 → 校验 → 换引用 → 重应用）

| 件 | 设计 | 依据 |
|---|---|---|
| **① 触发** | **双通道并存**：文件监听主路（`naqvis/file_watcher`：Windows ReadDirectoryChangesW / Linux inotify 原生后端，初始化失败自动降级 snapshot 轮询）+ **IPC `reload` 命令**（确定性手动触发，复用 §9 NDJSON 命令面——Windows 主通道：Crystal 在 Windows 上 `Signal.trap` 直接抛 NotImplementedError，无 SIGHUP 可用；autobot `Ipc::Server` `cli/gateway.cr:102-143` 先例）+ POSIX SIGHUP 第三便利通道（nginx 惯例）。监听不可靠兜底：保留 autobot cron 式 mtime(+size) 轮询、间隔缩至 1–5s（网络盘/编辑器原子写/watch 实例耗尽丢事件的最后防线，~20 行零依赖已在 cron 中验证）。**去抖 200–500ms 合并窗口**吸收编辑器半写瞬态 | 热更新笔记 §2/§4 |
| **② 解析校验（先验后换）** | 读盘 → `expand_env_vars` → YAML 解析 → `validate!`（从启动 fail-fast 强化为**运行时全量校验**：必填 key、binding 引用的账号必须存在、账号 id 唯一）→ **失败保留旧配置 + Log.warn，不崩溃** | autobot cron `reload_if_changed` 先验后换先例（`cron/service.cr:275-290` rescue 保旧）+ `loader.cr:152-166` 现链复用；热更新笔记 §5 |
| **③ 换引用** | **`Atomic(Config)` 整根替换**：校验通过才 `CONFIG.set(new_cfg)`，旧引用自然 GC。Crystal 默认单线程调度下裸换本就安全，Atomic 是面向 Parallel 上下文演进的零成本写法。注明歧义：`Atomic#swap` 详注有「T cannot contain any reference types」字样，指算术版 swap；以 reference type 可用方法清单为准（compare_and_set/get/set 均可用） | 热更新笔记 §3 |
| **④ 消费纪律（每 turn 快照）** | **每 turn 开头取一次 `CONFIG.get` 快照**，turn 内不再受重载影响——「一次 turn 内配置语义一致」不依赖任何同步原语，天然兼容 fiber 切换；等价于 nginx「旧 worker 优雅收尾」的单进程实现 | 热更新笔记 §3.3 模式 B；OpenClaw runtime snapshot 同思路 |

### 11.3 组件重应用矩阵（可热换 vs 必须重启）

| 组件 | 热换 | 说明 |
|---|---|---|
| 路由 binding、编排规则、工具 allowlist、提示词 | ✅ | 纯数据，换引用即生效，turn 边界切换 |
| 限流桶参数 | ✅ | 新参数下个 tick 生效，无需迁移状态 |
| provider key / LLM 凭据 | ✅ | 新 key 下次请求即用（Hermes `_CACHE_BUSTING_CONFIG_KEYS` 先例：key 级缓存失效已有先例） |
| 渠道凭据（app_id+secret） | ⚠️ | token 本就是 ~2h TTL 生命周期对象；换 secret 后保守做法=等 TTL 自然过期（≤2h）或维护失效标记——「主动作废旧 token」的 API 行为未验证（§15.1） |
| **账号增删** | ⚠️ | = **账号监督体（§5.1 账号生命周期）下的 fiber 创建/优雅停止**：加账号=spawn 新长连接 fiber；删账号=drain 在途消息后 close。与多账号设计合流，无需重启进程 |
| 监听端口/协议栈 | ❌ restart | 套接字绑定属进程资源，单进程内换端口会丢包；校验阶段对这类配置给出明确「此项需重启」提示（OpenClaw hybrid 的 restart 子集语义） |

（依据热更新笔记 §6 组件矩阵；账号增删行与渠道笔记「每账号长连接配监督体」建议合流。）

### 11.4 Crystal 实现要点

- 模式 A 代码骨架（热更新笔记 §3.3）：

```crystal
CONFIG = Atomic(Config).new(Config.load_initial)

def reload_config(path) : Bool
  new_cfg = Config.load_and_validate(path)  # 先验：读盘→展开→解析→校验，失败抛异常
  CONFIG.set(new_cfg)                       # 后换：整根替换，旧引用自然被 GC
  true
rescue ex
  Log.warn { "config reload rejected, keeping old config: #{ex.message}" }
  false
end
```

- **YAML 深合并：自写 ~20 行**。无可靠现成 shard（stdlib 拒收 `Hash#deep_merge`，crystal issue #6791；`deep-merge.cr` 数组合并 TODO 未实现、维护弱）。数组合并语义定为**整体替换**——可预测、避免半新半旧数组，与 OpenClaw/hydra 家族惯例一致（热更新笔记 §5）。
- **dotenv 不新增依赖**：autobot 自带 `load_env_file`（`loader.cr:17-31`）已够用。
- validate! 运行时强化清单：必填 key、**binding 引用的账号必须存在**（防删账号后路由悬空，fail-closed 与 §3.2 一致）、accounts 数组内 id 唯一（防重复凭据注册，§10.1 同款 park 语义）。

---

## 12. 插件脚本层（硬需求④专章：裁剪 mruby 子进程）

> 初稿依据热更新笔记 §8；2026-11-19 按用户确认采纳[子进程可行性报告](review/m3-plugin-feasibility.md)，并补充分发、生命周期与钩子契约。

### 12.1 定位与分工

- **可选模块**：插件层不进主链路——配置热更新（§11）等核心能力不依赖它。
- **与 SKILL.md 分工**：SKILL.md 承载**知识文档**扩展；插件脚本承载**代码能力**（自定义工具/钩子/定时动作/受控后端）。
- **不做插件市场**：开发者独立分发单文件包，用户显式安装；不自动下载依赖，不引入 CRuby/RubyGems/Bundler。这里的“单文件包”指一个 `.sebas-plugin` 分发文件，不承诺未来永远只有一个源文件；受控多文件的演进边界见[插件复杂化演进规划](review/plugin-evolution.md)。

### 12.2 运行时、声明与派发契约

- **每动作一个裁剪 mruby 子进程**：每次调用启动新进程，结束即释放 VM。mrb.cr 进程内绑定复核为 **84/84 通过**，但 mruby 无指令级执行配额，进程内死循环无法由宿主 watchdog 打断，故不作为首版运行形态。
- **静态声明 + 精确注册**：manifest 的 `hooks` 是插件意图和授权上限，宿主据此建立 `hook_name → [(plugin_id, version, priority)]` 索引；`on_hook(name)` 只在该次进程内登记具体 handler。manifest 未声明、handler 未注册、插件未启用或版本不一致均不派发，**不向全部插件广播所有钩子**。
- **声明校验**：安装时校验 manifest 中 hook 名称、类型、所需 capability 与配置 schema；开发/启用冒烟在无副作用沙箱中加载脚本，收集 handler 并验证 manifest 与注册集合相符。handler 重复、未知 hook、缺 handler、额外注册均拒绝激活。
- **每次调用的注入**：runner 校验请求后注入 `$action`、`$config`、`$context`、`$payload`、`$idempotency_key`，执行 `plugin.rb` 完成注册，再按 `$action` 精确调用 handler。`$context` 的授权身份以宿主保存的原始值为准，插件修改全局变量不能扩大权限。
- **无跨调用 Ruby 状态**：全局变量、block 和对象只在本次进程有效，不能当缓存或持久状态；持久状态经白名单 capability 保存并带 schema 版本。
- **JSON-like 协议**：只传数字/字符串/布尔/null/数组/哈希，不传 Crystal/Ruby 对象或 Proc。请求包含 `protocol_version`、`request_id`、`plugin_id`、`action`、`context`、`payload`、`config`；stdin 输入请求，stdout 返回结果，stderr 仅受限诊断。采用有长度上限的 NDJSON，校验恰好一个结果、schema、大小和请求 ID；预研 `RESULT` 行不是兼容承诺。
- **能力声明**：`memory.backend` 等扩展点和 capability 由 manifest 静态声明，宿主按 active 版本及授权快照派发。外部服务由宿主 driver 执行，agent/session scope 由宿主注入。
- **单入口、无原生依赖**：首版只有 `plugin.rb`，不支持包内 DLL/so、安装脚本、自动依赖下载或其他 `require` 文件。复杂插件的受控多文件、显式初始化和按插件常驻 worker 属于后续演进，见[插件复杂化演进规划](review/plugin-evolution.md)，不改变当前包契约或 M3 验收。

### 12.3 初始化与生命周期边界

首版采用**显式 action，不引入隐式全局 `init`**，避免“每次 hook 都执行一遍 init”的语义歧义：

| 时机 | 行为 | 是否执行插件业务代码 |
|---|---|---|
| 安装/升级 | 校验包、manifest、API、capability、配置 schema；无副作用冒烟加载以收集注册表 | 仅受控解析/注册，不允许外部效应 |
| 启用/激活 | 宿主生成精确 hook 索引与版本快照；旧版在途调用继续旧快照 | 不额外执行一次 init |
| 每个 action/hook | 新进程 → 注入本次请求 → 执行脚本声明 → 精确 dispatch 一个 handler | 只执行本次 handler 及其 capability |
| 禁用/卸载 | 原子摘除注册快照，保留或按 purge 规则处理数据 | 不承诺运行 cleanup；外部资源由宿主 driver 回收 |

- 如插件确需一次性建schema/检查外部服务，声明 `actions: ["install", "enable", "disable"]` 及对应 `on_action`，由宿主在生命周期节点显式调用，遵循幂等、审批、超时与迁移事务；**不是包安装脚本，不在 pack/validate 时执行**。
- `gateway.start` / `gateway.stop` 是生命周期观察钩子，不等于 init/cleanup；需要常驻 worker 的插件不属于首版模型。
- `enable` 失败保旧版；action 崩溃只影响该次调用，不自动重试副作用。重复 enable/disable 应幂等，升级数据迁移成功与版本指针切换保持原子语义。

### 12.4 沙箱与 watchdog

**不依赖语言级 `$SAFE`**；进程隔离增强故障边界，但不代替资源控制：

| 闸 | 子进程形态 | 效果与边界 |
|---|---|---|
| ① gembox 裁剪 | 剔除 `mruby-io`/`mruby-socket`，仅保留必要 stdio | 无直接文件/网络 IO，外部效应只能走 capability |
| ② 资源约束 | 构建期 allocf 配额 + 宿主 OS 级进程限制 | 插件内存失控不破坏宿主堆；仍须防整机内存压力 |
| ③ 能力白名单 | 协议动作与 capability 双重授权 | 任意名称、URL、路径、命令不自动获得权限 |
| ④ watchdog | 按 manifest 与全局较小超时终止进程树 | 死循环不卡宿主；清理后代进程并丢弃迟到输出 |

- 预研已验证脚本执行、exit code、stdout 与可 kill 模型；本机 Windows 新 exe 链接仍有环境 blocker，恢复条件见[可行性报告](review/m3-plugin-feasibility.md)。
- 解释器随平台交付并锁定版本，插件包不携带或选择解释器。API 兼容不等于已授权。
- 子进程不是内核沙箱：仍须限制 CPU、内存、输出、运行时长和进程树，不能声称仅靠 mruby 即可安全执行未知来源脚本。

### 12.5 激活与热重载 = 先验后换版本指针

- 安装包先写入独立版本目录并完整校验，通过后才原子切换当前版本指针。每次调用固定 `(plugin_id, version, config_snapshot)`；在途调用用旧快照，新调用用新版本。
- `sebas plugin dev <目录>` 提供开发 watch，修改仅影响新调用；生产不直接监视或加载任意 `plugins/*.rb`。
- 解析、manifest、注册集合、配置迁移或授权校验失败，旧 active 版本保持不变。
- 复用 §11「触发—校验—换引用—每 turn 快照」管线，payload 是插件版本指针和 manifest，而非 Config 或 mrb_state。

### 12.6 包格式与安装布局

**分发单元**是 ZIP 格式、扩展名为 `.sebas-plugin` 的单文件；扩展名不是安全边界。首版包根只允许：

```text
remote-memory-1.2.0.sebas-plugin
├── manifest.json  # 必需：身份、版本、API、扩展点、capability、配置 schema
├── plugin.rb      # 必需：唯一脚本入口
└── README.md      # 可选：用途、配置、权限和数据语义
```

```json
{
  "schema_version": 1,
  "id": "remote-memory",
  "version": "1.2.0",
  "api_version": "1",
  "entrypoint": "plugin.rb",
  "provides": ["memory.backend"],
  "actions": ["remember", "recall", "forget"],
  "capabilities": ["memory_driver.remote"],
  "timeout_ms": 1500,
  "config_schema": {"kind_weights": {"type": "object", "required": false}}
}
```

- `id` 限小写字母开头的 1–64 位小写字母/数字/连字符；`version` 为 SemVer，`api_version` 为主版本兼容契约。文件名不参与身份或升级判断。
- 安装器拒绝重复文件/大小写冲突、绝对路径、`..` 穿越、符号链接/重解析点、额外套件和超限包。限额在实现时固定并测试；按 ZIP 解压后总大小和文件数校验，防压缩炸弹。
- 首版以明确来源与人工审查为信任基础；发布者签名/可信指纹为后续增强。SHA-256 只证明内容完整，不证明作者可信。
- `pack` 只收录白名单文件；禁止包安装脚本、post-install hook、包内原生扩展与自动依赖解析。

以 `gateway.data_dir` 为根，**代码、配置、数据严格分离**：

```text
data/
├── plugins/
│   ├── installed/<plugin-id>/
│   │   ├── versions/<semver>/{manifest.json,plugin.rb,README.md}
│   │   └── current.json      # 原子版本指针；不依赖 Windows symlink
│   ├── staging/              # 仅安装器写入；永不直接执行
│   └── registry.json         # 版本、active、启停、授权、摘要
├── plugin-config/<plugin-id>.yaml  # 用户配置与凭据引用；升级不覆盖
└── plugin-data/<plugin-id>/        # 状态/迁移元数据；业务记忆优先走宿主 Store
```

注册表原子持久化 `schema_version`、各版本摘要、`active_version`、`enabled`、`approved_capabilities`、来源摘要和安装/激活时间。运行时仅从 registry 选定的 active 版本加载。

### 12.7 开发、分发与安装

```bash
sebas plugin validate .
sebas plugin pack . --output remote-memory-1.2.0.sebas-plugin
sebas plugin dev .
sebas plugin install ./remote-memory-1.2.0.sebas-plugin
sebas plugin enable remote-memory
```

`pack/validate` 校验 manifest、SemVer/API、包白名单、路径与大小，并以同版本裁剪解释器做脚本解析及无效应契约冒烟。产物可放 GitHub Release、内部分发或直接传文件，不依赖市场。

状态机为 `absent → staged → installed(disabled) → enabled(active)`；失败留在可清理的 staging。安装默认**不启用**，展示 ID、版本、扩展点、capability 和数据语义。同 ID 同版本同摘要重复安装幂等返回；同版本不同摘要拒绝覆盖，必须递增版本。

`enable` 再校验配置、宿主 API、扩展点冲突和已批准 capability。记忆后端须显式配置 `memory.backend: plugin:remote-memory`，安装不能静默替换默认后端。互斥后端由配置唯一选择；普通工具/hook 按命名空间和稳定顺序注册。

### 12.8 升级、回滚与数据迁移

```bash
sebas plugin upgrade remote-memory ./remote-memory-1.3.0.sebas-plugin
sebas plugin activate remote-memory 1.3.0
sebas plugin rollback remote-memory 1.2.0
```

1. 按安装流程校验新版本；`api_version` 主版本不兼容拒绝自动升级。新增/提升 capability、扩展点或风险等级必须再次显式批准，未批准不激活。
2. 升级只新增 `versions/<semver>`，不覆盖配置与数据。schema 变化须声明迁移版本，由宿主事务执行：备份/检查点→迁移→验证→切换指针；失败恢复旧版本，禁止代码回滚而数据静默留在不兼容的新 schema。
3. `activate` 原子换指针；当前 turn/调用继续旧快照，新调用用新版本。默认保留当前版及上一已知可回滚版；未被引用的旧版按保留策略清理，不立即删除唯一回滚点。
4. 降级安装默认拒绝；`rollback` 只允许 registry 中且与当前数据 schema 兼容的已安装版本，否则提示恢复相应备份。升级不重试未完成的副作用动作，幂等键按 §7.3 执行。

### 12.9 禁用、卸载与数据保留

```bash
sebas plugin disable remote-memory
sebas plugin uninstall remote-memory
sebas plugin uninstall remote-memory --purge
```

- `disable` 阻止新调用并注销新任务可见的工具/hook/定时注册，不删除代码、配置或数据；在途调用按快照结束或被显式取消。
- `uninstall` 默认要求先 disable；若 agent 后端、binding、workflow、approval 或其他插件仍引用它，列出引用并 fail-closed 拒绝。扩展点被引用时先显式切回 `builtin` 或另一已启用后端，不自动迁移业务数据。
- 默认卸载只删除代码、版本指针及注册项，保留 `plugin-config/` 和 `plugin-data/`；再次安装同 ID 不自动恢复授权或启用。
- `--purge` 先展示配置/数据范围并要求交互确认，非交互模式须额外明确确认参数。外部记忆服务数据不因本地 purge 自动删除，须由 driver 明确支持并再次确认。
- 卸载后相关注册对新任务不可见；已持久化任务若引用缺失插件则进入可诊断的 blocked/failed 状态，禁止悄悄改调内置后端。

### 12.10 能力安全与统一命令面

| 要素 | 本平台设计 |
|---|---|
| 发现 | 用户显式提供本地 `.sebas-plugin`；开发模式监视显式目录；不扫描远程市场 |
| 契约 | `manifest.json` + 版本化 JSON-like 请求/结果 + 静态扩展点与 capability |
| 能力注册 | 首批：工具 / 钩子 / 定时 / 受控 `memory.backend`；risk/replay 由宿主登记 |
| 生命周期/隔离 | 每动作独立进程；staging→安装→启用→激活→回滚→禁用→卸载；数据默认保留 |

- **注册工具**：走 §10.3 审批链与 §4.1 同款 registry，具有 risk/replay 类型字段；默认 `risk: high`，hardline blocklist 不可被插件 override。插件不能自行降低风险，只有宿主全局策略可按工具明确配置。
- **钩子/定时**：同步 hook 按 §12.11 精确派发；workflow 事件触发复用 §7.1 的预算、lease 和无人值守 fail-closed，插件不自建调度循环。
- **能力不是任意 RPC**：capability 仅调用宿主登记的 driver 和操作，agent/账号 scope 由宿主注入。插件 stdout/stderr 与业务数据日志必须脱敏、限量。
- CLI 与 §9 管理面共用同一 service，不允许 CLI 绕过 gateway 的 registry/授权直接改运行目录。提供 `plugins.list/get/validate/install/enable/disable/activate/rollback/uninstall`；pack/dev 为离线开发命令，不需要 gateway 权限。

### 12.11 钩子目录与执行语义（首版闭集）

对照 [OpenClaw typed hooks](https://docs.openclaw.ai/plugins/hooks)、[Hermes plugin hooks](https://hermes-agent.nousresearch.com/docs/user-guide/features/hooks) 与 [Pi Durable task hooks](https://earendil.com/posts/pi-durable/#hooks)，首版采用 21 个明确命名的钩子；未列出的专属能力不自动成为 Sebas 契约。同步 `before/transform` 与 `observe` 必须分开实现，不能一律当异步事件处理。

| 域 | 钩子 | 类型 | 宿主注入点与契约 |
|---|---|---|---|
| 消息 | `message.received` | observe | 渠道验真、鉴权、去重并解析完成后、进入路由前；只读，失败不阻断接收，不是原始传输包审计或修改入口 |
| 消息 | `message.sending` | gate + transform | 实际渠道投递前，可 `allow/modify/deny` 文本与附件元数据；不得替换账号、收件人或绕过 hardline |
| 消息 | `message.sent` | observe | 渠道返回投递结果后，含 `success/error/message_id`；不保证用户已读，不在此盲目重发 |
| Agent | `agent.turn.before` | gate | Agent turn 开始、LLM 请求前，可允许或拒绝整个 turn；宿主保留原始 prompt 与 scope |
| Agent | `agent.turn.after` | observe | turn 完成（含成功、失败、中断）后，带结果状态和耗时；不得再次启动隐式 turn |
| LLM | `llm.request.before` | gate + transform | Provider 每次请求前，可拒绝、追加受控 context 或修改允许的 request 字段；model/provider/凭据/endpoint 由宿主固定 |
| LLM | `llm.request.after` | observe | Provider 规范化成功后，含 response、usage、耗时与 request_id；日志须脱敏 |
| LLM | `llm.request.error` | observe | Provider 每次失败尝试后，含错误类型、状态码、重试序号；不改变既定重试策略 |
| LLM | `llm.response.transform` | transform | `llm.request.after` 后、最终回复/工具调用解析前，可替换文本；宿主再次解析和校验 |
| 工具 | `tool.call.before` | gate + transform | registry 查找后、执行前，可改写白名单参数、拒绝或请求审批；risk/replay/审批由宿主裁决，异常与超时 deny |
| 工具 | `tool.call.after` | observe | 工具成功、业务错误或异常转为 ToolResult 后；只读，含状态与耗时 |
| 工具 | `tool.result.transform` | transform | `tool.call.after` 后、结果返回 Agent 前，可替换受限文本结果；不能改变 replay/risk、幂等账本或已发生副作用 |
| 会话 | `session.start` | observe | 新会话上下文建立后；仅通知，不得在每次消息时误触发 |
| 会话 | `session.end` | observe | 会话重置、删除、Gateway 终止等明确边界，带 reason；在预算内做只读收尾 |
| 会话 | `session.compact.before` | observe | 压缩任务开始时，只读；首版不能 veto 或替换摘要 |
| 会话 | `session.compact.after` | observe | 压缩任务成功提交后，带计数和摘要元数据；失败/取消不触发 after |
| 记忆 | `memory.remember.before` | gate + transform | 后端写入前，返回 `allow/modify/deny` entry；宿主重新校验后才写入 |
| 记忆 | `memory.remember.after` | observe | 后端提交成功后，含 memory_id/kind/tags；失败或 deny 不触发 |
| 任务 | `task.start` | observe | 持久 workflow/task 创建并落库后，带 run_id/workflow_id；不是每次 phase 重放都创建新任务 |
| 任务 | `task.end` | observe | task 进入终态后，带 status/error；不能改变终态或重试副作用 |
| 平台 | `gateway.start` / `gateway.stop` | observe | 插件 registry 就绪后 / 渠道停止前；stop 有全局有界等待，不承诺全部消息已投递 |

`llm.request.error` 的每次尝试语义与 `agent.turn.after` 的最终 turn 语义不得混淆；`session.compact.after` 的提交完成不等于所有下游消费者已刷新。首版**不开放**原始渠道包改写、任意系统提示替换、自由 `claim` 接管 Agent 回复、`before_install`、动态 skill 改写、任意 cron 状态改写；这些需要单独 capability 和威胁模型。

**统一执行规则**：

- manifest `hooks` 与脚本 `on_hook(name)` 注册集合必须一致，宿主按 §12.2 的索引只调用订阅者；同插件重复注册拒绝，不同插件按 priority（数值大者优先）再按插件 ID/注册序稳定排序。
- `gate + transform` 同步按序执行，每个处理器接收上一个已校验结果；任一 deny 停止后续处理器。`observe` 按注册快照执行、忽略返回值，可并发但不得阻塞主流程；观察副作用不保证持久化或严格全序。
- 所有插件调用遵守独立进程、schema/大小限制和 watchdog。gate/transform 的异常、超时、非法结果默认 **deny**；observe 的异常、超时记录脱敏日志并跳过。宿主 hardline 不可被返回结果覆盖。
- 同步 hook 不是 §7.1 workflow trigger；其 handler 若要发起独立工作，只能经显式 task/capability 创建。插件不能自建循环或借 hook 递归触发自身，宿主设置每 turn hook 次数/深度/总耗时上限。
- `context` 由宿主保存并注入可信 agent/account/session/run 标识。含 prompt、历史、工具参数、消息或错误文本的 hook 属敏感数据，按 manifest capability 单独批准，默认最小字段与脱敏。
- 可恢复 task 相关 hook 可能重放；决策通过宿主 memo/idempotency_key 持久化，禁止依赖 `$` 变量保存跨调用状态。已发生的消息发送、工具执行等效应不因 transform/observe 失败而回滚，未知状态 fail-closed 不盲目重试。

**示例（声明式 DSL）**：

```ruby
on_hook "memory.remember.before" do |entry|
  deny!("empty_memory", "Memory text must not be empty") if entry["text"].to_s.empty?
  modify(entry.merge("tags" => (entry["tags"] || []).uniq))
end

on_hook "tool.call.after" do |event|
  # 只读观察；需要持久化时调用宿主显式 capability，不写本地文件。
  nil
end
```

---

## 13. 目录结构与模块划分（src/ 布局草案）

```
src/platform/
  cli/                     # 命令行入口（gateway 起 / 账号管理 / 审批）
  config/                  # 配置加载、schema（宏生成账号样板与校验，§4.2）；reload 管线（先验后换+Atomic 换引用，§11）
  bus/                     # 事件总线：有界 Channel + 账号上下文路由
  supervisor/              # 账号监督器：fiber-per-account、退避重连、健康上报
  store/                   # SQLite(WAL) 持久层：会话/任务/账本/审批 + FTS5
  keys/                    # 凭据 keyring / 静态加密（§10.2）
src/channels/
  base.cr                  # abstract ChannelAdapter（start/stop/send + account 维度）
  common/                  # markdown 转换器【A8】、token_provider【§5.3】、限流桶
  email/                   # imap_idle.cr / gmail_api.cr / smtp.cr
  wecom/                   # aibot_longconn.cr / app_callback.cr / crypto.cr（自实现 AES-CBC）
  lark/                    # ws_longconn.cr / webhook.cr
src/routing/
  binding.cr               # 路由表（most-specific，纯函数 + 快照原子替换）
src/agents/
  agent.cr                 # Agent 实例（大脑：人格+记忆+会话库+工具集+模型）
  pool.cr                  # per-session worker 池（并发上限、会话分片队列）
  session/                 # 会话管理（键含账号维度；SQLite+JSONL 双写）【A4 升级】
  memory/                  # MEMORY/HISTORY/USER/SOUL + LLM 巩固【A5】+ FTS5 检索
  skills/                  # SKILL.md 机制【A7，升格为主要扩展通道】
src/orchestration/
  dsl/                     # 触发→条件→动作 YAML 解析与校验
  engine.cr                # 持久 Task 状态机（效应三明治、phase checkpoint）
  triggers/                # cron【A10】/ event / webhook / 账号生命周期事件
  approvals/               # 审批节点（超时 deny、无人值守 deny、hardline）
  ledger.cr                # append-only 事件账本 + 预算记账
  collaboration/           # message_agent + loop guard【§8】
src/tools/
  registry.cr              # 注册表【A9 升级：replay/risk 类型级字段、allowlist、脱敏】
  executor.cr              # ReAct ToolExecutor + Observer【A6】
src/providers/             # Provider 实例池 + 规格表【A1/A2】
src/admin/
  ipc/                     # NDJSON 协议（hello/caps/8MiB 帧，autobot 713ed632 模式）+ reload 命令【§11】
  http/                    # HTTP API + 回调面 + SSE
  tui/                     # TUI（termisu 或自写，避开 AGPL 的 crysterm——旁证 §一.8）
src/plugins/               # 可选脚本层（§12）：manifest/包校验/registry、进程 runner、JSON-like 协议、
                           # 白名单 capability、精确 hook 索引、watchdog、版本生命周期 service
```

**autobot 可复用件承接表**（A1-A10，autobot 笔记 §10）：

| 件 | 去向 | 改造点 |
|---|---|---|
| A1 Provider 抽象+规格表 | `src/providers/` | 单实例→实例池 |
| A2 HttpProvider 双格式适配 | `src/providers/` | 直接搬（超时/重试/429/错误兜底齐备） |
| A3 有界 Channel 总线模式 | `src/platform/bus/` | 加账号维度路由（B3 架构改造） |
| A4 Session JSONL | `src/agents/session/` | key 加账号维度（B4）；升级为 SQLite+JSONL 双写 |
| A5 Memory 双文件+巩固 | `src/agents/memory/` | 巩固改用 agent 绑定的 provider 实例 |
| A6 ReAct ToolExecutor+Observer | `src/tools/executor.cr` | 直接搬 |
| A7 SKILL.md 机制 | `src/agents/skills/` | 升格为主扩展通道（B6 缓解） |
| A8 渠道 Markdown 转换器 | `src/channels/common/` | 直接搬（纯函数、与账号无关） |
| A9 工具注册表骨架 | `src/tools/registry.cr` | session_key 含账号；加 replay/risk 字段 |
| A10 cron 三态调度 | `src/orchestration/triggers/` | owner 加账号维度（B7）；投递进对应 worker |

---

## 14. 分期路线图

| 期 | 内容 | 验收要点 |
|---|---|---|
| **M0 · MVP** | 单账号闭环：1 个 email 账号 + 1 个 agent；效应三明治持久层；基础工具（发消息/读邮件）；NDJSON TUI 最小面 | 收发消息全链路；**强制杀进程（POSIX kill -9 / Windows taskkill /F）后重启续跑**（对照 Pi 恢复演练建立自动化用例）；发信幂等键生效（重复投递不重发） |
| **M1 · 多账号完备 + 配置热更新** | 账号数组+binding 路由；企微智能机器人长连接、飞书 WebSocket；TokenProvider；限流桶；keyring 凭据；会话键账号维度；**热更新四正交件**（file_watcher 双通道触发 / 先验后换 / Atomic 换引用 / 组件重应用矩阵，§11） | **同渠道 N 账号并存互不串扰**（两企微账号同 chat_id 不撞会话）；receiveid 校验；token 提前刷新与失效重取；限流桶触发退避；**运行中改配置（加/删账号、改路由、换 provider key）不重启进程生效**；配置写坏（YAML 语法错/binding 引用悬空）保旧运行并报警；改监听端口得到「需重启」明确提示 |
| **M2 · 编排完备** | 触发→条件→动作 DSL；cron/事件/webhook 统一；审批节点（超时 deny/无人值守 deny/hardline）；lease+回收+预算；append-only 账本 | workflow run 崩溃重放幂等；审批超时 deny 实测；预算熔断；runs 回放与审计 |
| **M3 · 协作 + 插件脚本层** | 多 agent 定义与路由；message_agent + max_hops 防环；subagent 信号量；**裁剪 mruby 子进程插件层**（能力白名单+watchdog、manifest/JSON-like 协议、`.sebas-plugin` 包与生命周期，§12） | max_hops=4 拦截互发死循环；并发上限生效；subagent 崩溃后找回同一子任务；死循环可终止不卡宿主；崩溃只影响该次调用；开发脚本热重载生效；安装默认禁用、升级保配置/数据可回滚、被引用卸载拒绝、purge 需确认；21 个首版 hook 精确派发、同步 gate deny、观察失败跳过 |

排期依据：热更新排 **M1**——「加账号」本身就是热更新组件矩阵的一行（账号增删=监督体 fiber 启停，§11.3），M1 核心验收要求账号数组「加了就生效」，四正交件必须同期落地（Hermes 无热重载的教训是「账号体系与重载割裂则用户必烦」）。插件层排 **M3**——可选模块后置：M0-M2 的扩展需求由 SKILL.md（A7）承接（§12.1 分工），主链路先稳。

各期共同门禁：`crystal spec` + `./bin/ameba`（工作区 CLAUDE.md 既有质量标准适用于后续实现，本期仅设计不涉及）。

---

## 15. 风险与未决问题（如实列）

### 15.1 关键依赖未验证（实现前须补研）

1. **企微智能机器人主动发消息 API**：官方接口文档页未逐页核对（渠道笔记未验证 #3）；AIBot 为较新形态，API 有变动风险。
2. **Gmail IMAP IDLE 不可靠**为社区长期报告（渠道笔记未实测）；Gmail API watch 需 GCP 项目 + Pub/Sub，个人运维成本未评估。
3. **Gmail 15 IMAP 连接上限**：来源为第三方引用（Microsoft Q&A/Atlassian），未找到 Google 官方页（渠道笔记未验证 #7）。
4. **企微回调明文布局** `random(16B)+msg_len(4B)+msg+receiveid`：官方描述 + 多第三方实现一致，官方原理小节未逐字核对（渠道笔记未验证 #2）。
5. **飞书单个 API → 频控等级映射**：等级表已有，每个接口属哪级需控制台查询（渠道笔记未验证 #6）。
6. **Crystal 企微加解密自实现**：无官方库，AES-CBC/SHA1/Base64 需对照官方测试向量做对称测试（设计层面可控，实现未验证）。
7. **`naqvis/file_watcher` Windows 实测**：**已冒烟验证（2026-11-18，[review/smoke-ex-w1-03.md](review/smoke-ex-w1-03.md)）**——watch 单文件路径零事件，须 watch 父目录+按路径过滤；编辑器原子替换（tmp+rename）产生 `Created(tmp)+Deleted(target)+Renamed(target)` 三连，`Deleted` 不得解释为配置被删，去抖窗口内按路径聚合判定；mtime 轮询兜底保留（热更新笔记 §9.3）。
8. **`Atomic(Config)` snippet 编译冒烟**：**已冒烟验证（2026-11-18，[review/smoke-ex-w1-03.md](review/smoke-ex-w1-03.md)）**——reference type 全部方法（new/get/set/swap/compare_and_set）编译并运行正确，`Atomic#swap` 详注歧义消项；整根替换路线成立（热更新笔记 §9.4）。
9. **企微/飞书换 secret 后旧 access_token 强制失效行为**：未验证；热换渠道凭据若依赖「主动作废」需实测，保守做法=等 TTL 自然过期（≤2h）或维护失效标记（热更新笔记 §9.7）。
10. **mrb.cr 绑定可用，但运行形态已改为子进程**：本地复核 84/84，issue #1 修复已发布 0.2.0/0.2.1；进程内死循环 watchdog 硬边界见 §12.2。裁剪 mruby.exe 在本机 Windows 的链接 blocker 与恢复路径见 [review/m3-plugin-feasibility.md](review/m3-plugin-feasibility.md)。
11. **Hermes SIGUSR2 reload（#48918/#54941）落地进度**：仅核到 2026-09 PR #66777 提及「在途」，当前是否合并未追（热更新笔记 §9.8）。
12. **OpenClaw runbook 正文未逐字**：docs.openclaw.ai/gateway/ fetch 仅返回导航目录；§11.1 引用的 reload 四模式细节来自 openclawlab.com 与 openclaws.io 两镜像搜索快照（同文互证，未逐字比对官方页）（热更新笔记 §9.1）。
13. **OpenClaw 插件 fault isolation / priority / parallelism 状态机细节**：hooks-plugins 状态机页未取正文；§12.5 生命周期设计未依赖其细节，仅作方向参照（热更新笔记 §9.2）。

### 15.2 架构与性能风险

14. **fiber 数量**：N 账号（连接+监督+心跳）× M 并发会话 worker × subagent——个人规模（≤20 账号、≤100 并发会话）理论可控，但**未做压力测试**（autobot 笔记亦未运行时验证队列行为）。缓解：worker/subagent 全局上限 + 每会话队列。
15. **飞书长连接非广播**：单机无碍；未来多实例部署每条消息只到一个 client，横向扩展受限（渠道笔记 b1 硬限制）——多实例是本期非目标，仅记录。
16. **SQLite 单写者**：单进程内写串行化；CLI 等旁路工具以只读方式访问（Pi readOnly 挂载模式）；若未来多进程，学 Hermes 恢复防呆而非重蹈（Hermes 教训 5）。
17. **3 秒/5 秒回调硬约束**：企微 POST 5 秒、飞书 3 秒、Gmail 无此约束——回调路径必须「验签+落库+入总线」即返回，业务全异步；落库写延迟需实测。
18. **出口 IP 共享**（企微可信 IP）：多企微账号共用出口 IP，云厂商浮动 IP 变更须同步各应用配置（渠道笔记 a6）。
19. **token Header 4KB**（飞书新版 JWT）：HTTP 客户端默认 header 上限需确认。
20. **热更新纪律绕过**：若有新代码绕过「每 turn 取快照」直接持有 Config 引用跨 turn，会出现半新半旧状态——靠代码评审/ameba 自定义 lint 规则约束（§11.2 ④ 是纪律不是运行时强制）。

### 15.3 设计取舍的已知代价

21. **v1 编排条件不做图灵完备**：仅声明式谓词（元数据匹配 + all/any/not 组合）——复杂逻辑引导用户写 subagent 工具而非 DSL 图灵完备（降低误配风险，能力边界明示）。
22. **不做 profile 之上的多人鉴权**：个人平台假设（Hermes non-goals 同款）；家庭/团队共用是未来项。
23. **A2A 不引入**：跨机协作留未来（旁证微软原则）；本期 agent 间原生消息已够用。

---

## 16. 调研来源对照表（决策 → 笔记依据）

| # | 设计决策 | 依据（笔记 · 小节/条目） |
|---|---|---|
| 1 | Account/Agent/Binding 三正交 + most-specific 路由 | OpenClaw §3（三概念正交、17 渠道多账号、binding 层级）、§9；渠道笔记设计启示 1 |
| 2 | transport/runtime 双轴解耦（收信账号≠执行大脑） | Hermes §2（RoutingIdentity）、§8 借鉴 3 |
| 3 | 路由无匹配丢弃（fail-closed） | Hermes §2（路由到未服务 profile 即丢弃）、§8 借鉴 4 |
| 4 | 账号=配置树数组节点，不硬编码进渠道实现 | OpenClaw §3 启示；autobot B1/B2（三层锁死证据链） |
| 5 | 接收侧两形态归并，优先长连接 | 渠道笔记结论速览 + 设计启示 2；Hermes §4.2（两类平台二分接线） |
| 6 | 回调共享监听器 + URL 前缀路由 + 各自 secret 验签 | Hermes §4.2（port-binding 型 `/p/<profile>/` 模式） |
| 7 | 重复凭据 park 不崩溃 | Hermes §4.2（duplicate adapter 被 park） |
| 8 | TokenProvider 统一抽象 | 渠道笔记设计启示 3（三渠道 token 生命周期同构）+ a4/b3/c5 |
| 9 | 限流桶 (账号,目标) | 渠道笔记设计启示 4 + a7/b5/c2 |
| 10 | 企微 AIBot 长连接优先 / 自建回调备选（AES-CBC+receiveid+msgid 排重+5 秒） | 渠道笔记 a1/a2/a5/d3 |
| 11 | 飞书 WS 长连接（自建应用、3 秒、50 连接、非广播、事件 id 排重）/ base_url 入账号配置 | 渠道笔记 b1/b2/b4 |
| 12 | Email：IMAP IDLE（非 Gmail）/ Gmail API；XOAUTH2；15 连接；29 分钟重发 | 渠道笔记 c1/c2/c3/c5 |
| 13 | 会话键含账号+agent 维度 | autobot B4；OpenClaw §4.1（dmScope per-account-channel-peer 教训 5） |
| 14 | SQLite(WAL) 主存储 + working-set 内存模型 | Pi §2（存储后端/内存模型）、§6；OpenClaw §4.1（per-agent SQLite）；旁证建议（SQLite FTS5） |
| 15 | 记忆=人可读 Markdown + FTS5 检索层 | OpenClaw §4.2 借鉴 5；autobot A5；Hermes §3（FTS5 session search） |
| 16 | 编排=触发→条件→动作 + 持久 Task（效应三明治，拒绝事件溯源） | Pi §2；首辅定调 5 |
| 17 | 幂等三件套（requestId/replay 二分/memo）+ 发信幂等键 | Pi §4（含发消息必须幂等键的推论 §7.5）；渠道笔记（企微重试 3 次/飞书重推） |
| 18 | restartLimit 崩溃循环防护 | Pi §4 |
| 19 | lease+过期回收+预算+append-only 账本 | 旁证 §一.1（六坑迁移、队列型机制最值得抄）+ §二 映射表 |
| 20 | 审批：smart/manual/off + 超时 deny + 无人值守 deny + hardline + 看不全只 Deny | Hermes §6 层 2、§8 借鉴（审批细节级） |
| 21 | agent 间消息：fire-and-forget+署名+max_hops=4+回复不可再回复 | Hermes §4.3（Bot Mode 三件套） |
| 22 | subagent=被拥有的会话/任务 | Pi §3（ownership + scanConversations 找回） |
| 23 | subagent 并发信号量（默认 3） | autobot B8（无上限教训）；旁证 §四.3（放大器警告） |
| 24 | per-session worker 池替代全局单 Loop | autobot B3（`cli/gateway.cr:76` 串行证据）；旁证 §一.3 |
| 25 | 管理面双入口：NDJSON/IPC + HTTP（与回调共用） | 旁证 §一.6（无协议接不上教训）+ §一.7（NDJSON 已验证）+ §三.1；OpenClaw §8（webhooks 同端口） |
| 26 | 凭据 keyring/静态加密 + (渠道,账号ID) 命名空间 + 脱敏 + 轮换 | 渠道笔记 d1/d2；autobot B10 |
| 27 | fail-closed 贯穿 + 显式消息传递替代隐式 scope | Hermes §6/§8 借鉴 4、反面教训 2（contextvar 漏） |
| 28 | Windows 应用层 sandbox 策略 | 旁证 §三.5（无 bubblewrap，偏 ZeroClaw 路线） |
| 29 | 单二进制=差异化卖点 | Hermes 反面教训 1（双运行时之重） |
| 30 | A2A 留未来、内部原生消息 | 旁证 §一.1（微软原则）+ §二 |
| 31 | 不做云 SaaS/多用户、不做 OpenClaw 迁移 | 首辅定调 10；旁证 §三.7 |
| 32 | Crystal 机制映射（fiber/Channel/select/宏/union/abstract/record/rescue） | autobot §9 实证 14 条 |
| 33 | TUI 选型 termisu/自写，避开 AGPL crysterm | 旁证 §一.8（Crystal TUI 生态实测） |
| 34 | 配置热更新四正交件（触发双通道/先验后换/Atomic 换引用/每 turn 快照） | 热更新笔记 §0/§2-§5；autobot `cron/service.cr:275-290`（先验后换先例）、`loader.cr:152-166`（加载链复用） |
| 35 | 组件重应用矩阵；端口类标 restart（OpenClaw hybrid 语义） | 热更新笔记 §6/§7.1 |
| 36 | Hermes 无热重载=用户痛点根源（反面教材） | 热更新笔记 §7.2（issue #48693 等四证据链） |
| 37 | YAML 深合并自写 ~20 行 + 数组整体替换语义 | 热更新笔记 §5（stdlib #6791 拒收；deep-merge.cr 数组 TODO） |
| 38 | 插件层=每动作裁剪 mruby 子进程；激活=版本指针先验后换 | 用户确认的子进程修订；[m3-plugin-feasibility.md](review/m3-plugin-feasibility.md)；mrb.cr 84/84 复核 |
| 39 | gembox/资源约束/能力白名单/watchdog；子进程不代替 OS 资源限制，不靠 $SAFE | 热更新笔记 §8b + 子进程修订 |
| 40 | manifest + JSON-like 协议 + `.sebas-plugin` 独立分发；不做市场 | 热更新笔记 §8d + 2026-11-19 用户确认的包与生命周期方案 |
| 41 | 热重载/激活与配置热更新共用触发-校验-换引用管线；配置/代码/数据分离；卸载保留数据；21 个首版 hook 精确派发 | 热更新笔记 §8e.3 + §12.5~§12.11；OpenClaw/Hermes/Pi hook 目录核实 |

---

## 附：本文档未决事项（向用户征求决策）

1. **平台命名**：**已定名 Seneschal**（[naming.md](naming.md) 14 候选撞名全核实；用户可推翻，推翻则替换 development-plan.md 与本文两处 token——development-plan.md 侧已按「Seneschal」替换，届时直接搜该词）。
2. **MVP 首渠道**：建议 email（无公网要求、回调约束最松）先行，企微/飞书次之——若用户有优先渠道偏好请指定。
3. **Gmail 路线**：Gmail API（需 GCP 项目）vs 应用专用密码过渡——涉及个人 GCP 运维意愿。
4. **审批默认模式**：本草案默认 `manual`（每次问），可改 `smart`（LLM 辅助评风险）。
5. **插件 API 首批暴露能力**：**已定为工具/钩子/定时/受控 `memory.backend`**（§12.10）；memory 只经宿主 driver 读写，不开放任意 IO。插件注册工具默认 `risk: high`，不可由插件声明调低，只能由宿主全局策略按工具配置。首版 hook 闭集见 §12.11，自定义触发器、自由 claim 与任意消息改写仍不在首批。
