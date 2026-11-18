# OpenClaw 深度调研笔记

- 调研人：翰林院编修（hanlin-bianxiu-2），受首辅 lead 委托
- 调研日期：2026-11-18
- 方法：官方文档 docs.openclaw.ai + GitHub 官方仓库原文；纯只读调研
- 用途：为 Crystal 语言「个人 Agent 平台」设计提供参照。autobot(Crystal) README 自述 "Inspired by OpenClaw — rebuilt in Crystal"，OpenClaw 即本平台最重要参照系
- 证据标注：引用处附英文原文；查不到的统一进文末「未验证」小节

## 0. 项目概况

- OpenClaw：开源个人 AI 助理，作者 Peter Steinberger；曾用名 Clawdbot → Moltbot → OpenClaw。
- 官方仓库（已验证）：github.com/openclaw/openclaw（MIT License）；官方文档：docs.openclaw.ai。
- 技术栈：TypeScript / Node.js（pnpm workspace monorepo，Node 24.16+），npm 包名 `openclaw`。
- 治理：OpenClaw Foundation（独立 501(c)(3)）；README 明言 OpenAI 只是 donor，不受单厂商控制。
- 定位（README 原文）："One Gateway runs it as a personal claw or shared multiplayer claw — configuration is the only difference."；local-first："状态/记忆/凭据全在本机"。
- 模型与 agent harness 均为可插拔 plugin（Claude、Codex、local models 等都是 plugin）。

## 1. 总体架构

### 1.1 进程模型

- 单一长驻 **Gateway daemon** 是唯一的消息面/状态/凭据持有者：每 host 一个 Gateway 进程，全部渠道接入（WhatsApp via Baileys、Telegram via grammY、Slack、Discord、Signal、iMessage、WebChat 等）都在 Gateway 进程内。
- 控制面客户端（macOS 菜单栏 app、CLI、WebUI/Control UI）与 nodes 都通过同一条 WebSocket 连接 Gateway（默认 127.0.0.1:18789）。
- Gateway 内置 **GatewayScheduler** 统一驱动 cron 与维护唤醒；WS 上 events 不重放，`send`/`agent` 调用要求 idempotency key。
- Gateway 鉴权模式：`gateway.auth.mode: token | password | tailscale | trusted-proxy | none`。
- 架构不变量（architecture.md 原文）："Exactly one Gateway controls a single Baileys session per host." —— 注意与「多账号 WhatsApp」并存的 nuance：多账号 = 每账号一个 Baileys 实例各配独立 authDir；该不变量应理解为「Gateway 是唯一控制 Baileys 会话的进程」（渠道会话不散落到其他进程），而非「每 host 只能一个 WhatsApp 账号」（后者被 multi-agent.md 明确否定）。

### 1.2 Nodes 多设备机制

- node = 伴生设备（macOS / iOS / watchOS / Android / headless），以 `role: "node"` 连 Gateway WS；device-based pairing（connect.challenge 签名 v3 + device token）；node 声明 caps/commands，通过 `node.invoke` 暴露命令面：`camera.*`、`screen.record`、`system.*`、`notifications.*`、`device.*`（命令受 allowlist 约束）。
- nodes 是 peripherals，不是 gateway：不跑 gateway 服务、不落渠道消息（nodes.md 原文 "channel messages land on the gateway, not on nodes"）。
- Apple Watch 走签名 HTTPS polling（watchOS 禁止普通 app 的低层网络）。
- node 可托管：MCP servers、skills、本地模型推理、OpenClaw session hosting（worker session 放到 node 上跑，容器隔离）、file transfer。
- macOS 菜单栏 app = 该 Mac 唯一 node 身份（内部以 CLI node-host runtime 作为 worker；不可再起第二个 CLI node）。

### 1.3 relay / 远程访问

- 当前文档体系中**没有独立托管 relay 组件**；"relay mode" 仅作为 Slack 渠道的 transport 选项之一存在（Socket Mode / HTTP Request URLs / relay mode 三选一）。
- 远程访问模型 = Gateway WS + Tailscale / SSH tunnel（官方推荐）；`gateway.auth.mode` 原生支持 tailscale / trusted-proxy。
- 早期 Clawdbot/Moltbot 时代的托管 relay（relay.openclaw.ai）现状：未验证（文档索引无该页面）。

### 1.4 消息数据流（综合各页）

渠道消息 → Gateway 内 channel plugin 接收 → binding 路由（把 `(channel, accountId, peer)` 映射到 agentId，most-specific 优先，见 §3/§9）→ session（per-agent SQLite）→ agent runtime 执行 LLM turn（工具调用可选进 sandbox）→ 回包渠道。cron/webhook/Gmail 等触发由 GatewayScheduler 唤醒 agent turn，输出按 delivery 配置回写渠道或 webhook。

## 2. Channel 抽象与凭据管理

### 2.1 官方渠道目录（docs.openclaw.ai/channels.md，2026-11 版，共 33 项）

- bundled（随核心安装）：**Telegram**（官方推荐首个接入：一个 bot token 即可，`openclaw channels add --channel telegram --token <bot-token>`）、WebChat、A2A、Reef、X/Twitter。
- official plugin（一条命令安装 `openclaw plugins install @openclaw/<id>`，或 onboard / channels add 按需装）：Discord、Feishu(Lark)、Google Chat、iMessage(imsg)、IRC、LINE、Matrix、Mattermost、Microsoft Teams、Nextcloud Talk、Nostr、QQ bot、Raft、Signal(signal-cli)、Slack、SMS(Twilio)、Synology Chat、Tlon、Twitch、WhatsApp、Zalo、Zalo personal、Buzz、ClickClack。
- external plugin（OpenClaw 仓库外维护）：WeChat（openclaw-weixin 插件）、WeCom、Yuanbao、Zalo ClawBot。
- 相关通信插件：Voice Call（Plivo / Telnyx / Twilio 电话语音）。
- **Email 不在渠道目录**：收发邮件走 automation 触发器——Gmail PubSub trigger（官方推荐配 restricted reader agent）与 IMAP email trigger，本质是「触发器路由到受限 agent」而非常驻 email 渠道。
- 多渠道可同时运行（原文 "Channels can run simultaneously; configure multiple and OpenClaw will route per chat."）。
- 共性机制：群加入自我介绍 joinIntro（默认开；该 turn 零工具运行、内容按 untrusted 包装、60s 上限、90 天去重 claim）；bot loop protection（防两个 bot 互刷）；ambient room events（未被 @ 的群聊变安静上下文）。

### 2.2 配置与凭据管理

- 配置树：`openclaw.json` 的 `channels.<channel>.accounts.<accountId>`——**每个账号一份凭据条目**：
  - WhatsApp：每账号独立 authDir（默认 `~/.openclaw/credentials/whatsapp/<accountId>`），登录 `openclaw channels login --channel whatsapp --account personal`；
  - Discord：`accounts.<id>.token`；Telegram：`accounts.<id>.botToken`（默认账号可用 `TEMMGRAM_BOT_TOKEN` 环境变量，正确键名 `TELEGRAM_BOT_TOKEN`）。
- 管理命令：`openclaw channels add` / `channels status --probe` / `channels login`；hot reload 默认开，改配置对运行中 Gateway 自动生效。
- 凭据存本机文件（local-first，README："your state stays on your machine"）。

## 3. ★重点结论：同一渠道类型能否绑定多个账号 —— **支持**（一等公民特性）

**结论：支持。** OpenClaw 把「同一渠道 N 个账号」建模为一等公民：每个账号是 `channels.<channel>.accounts` 下的一个具名条目（accountId），凭据按账号隔离存储；出站默认账号可显式配置；accountId 参与消息路由（binding），每个 accountId 可绑定到独立 agent（独立大脑），会话互不混淆。

**证据链**：

1. 官方 multi-agent 文档原文（docs.openclaw.ai/concepts/multi-agent.md）："Channels that support multiple accounts (e.g. WhatsApp) use accountId to identify each login. Each accountId routes to its own agent, so one server can host multiple phone numbers without mixing sessions."
2. 官方列明支持多账号的渠道 **17 个**：discord, feishu, googlechat, imessage, irc, line, mattermost, matrix, msteams, nextcloud-talk, nostr, signal, slack, telegram, whatsapp, zalo, zalouser（同页列表）。
3. 配置样例：`channels.whatsapp.accounts.personal` / `.work` 两账号并存（multi-agent.md 与 docs.openclaw.ai/gateway/config-channels/personal-messaging 的 "Multi-account WhatsApp" 节——出站默认账号规则 + `openclaw doctor` 会把 legacy 单账号 auth dir 迁移为 `whatsapp/default`）。
4. 仓库源佐证：GitHub openclaw/openclaw docs/gateway/configuration.md（commit bf6ec64）含「两个 WhatsApp 账号 → 两个 agent」的配置示例。
5. 语义细节（multi-agent.md）：
   - 默认账号：`channels.<channel>.defaultAccount` 可选；未设置时用名为 `default` 的账号（若配置了），否则取排序后的第一个 accountId；
   - binding 中 `accountId: "*"` = 匹配任意账号；省略 = 仅默认账号；
   - 出站消息默认经 defaultAccount 账号发出（personal-messaging.md）。
   - skills 文档亦提醒：多账号渠道插件中凭据可能挂在具名账号下（"credentials may live under a named account"），技能 gating 应落在 `channels.<channel>` 子树——佐证多账号凭据布局是常态设计。

**对本平台的启示**：OpenClaw 用三个正交概念满足该诉求——**accountId（渠道账号实例）／agentId（大脑）／binding（路由表）**。这是值得直接借鉴的核心抽象：不要把「账号数」硬编码进渠道实现，账号应是配置树的节点，路由应是带 most-specific 语义的显式绑定表。

## 4. 会话 / 记忆 / 持久化

### 4.1 session（docs.openclaw.ai/concepts/session.md）

- session 状态全部由 Gateway 管理。默认路由表：DM → 共享（单用户友好）；group/room → 按群隔离；cron → 每次新 session；webhook → 按 hook 隔离。
- 可调粒度：`session.dmScope: main | per-peer | per-channel-peer(官方推荐) | per-account-channel-peer`；`session.groupScope: per-group | main`；`session.identityLinks` 可把跨渠道的同一人合并。
- reset 模式：none / daily（atHour=4）/ idle（idleMinutes）。
- 持久化：runtime 行 + transcripts 存 per-agent SQLite `<agentDir>/openclaw-agent.sqlite`（`~/.openclaw/agents/<agentId>/agent/`）；归档 transcripts 存 `~/.openclaw/agents/<agentId>/sessions/`；maintenance 默认 pruneAfter 30d、maxEntries 5000、archiveDashboardAfter 7d、transcript 压缩归档（>4GiB 拒绝）。
- incognito session 仅内存、24h；restart recovery 用 shutdown marker + 恢复输入；会话命令 `/new`、`/reset`、`/btw`（ephemeral /side）。

### 4.2 memory（docs.openclaw.ai/concepts/memory.md）

- 纯 Markdown 文件、无隐藏状态：`USER.md`（稳定偏好）、`MEMORY.md`（长期精选，session 启动注入）、`memory/YYYY-MM-DD.md`（每日笔记，被索引但不自动注入）、`DREAMS.md`。
- 工具 `memory_search` / `memory_get` / `intent` 由默认 memory-core plugin 提供；默认 SQLite 后端支持 keyword + vector + hybrid 检索；可选 PostgreSQL（memory-core 内建）、LanceDB / Honcho plugin。
- embeddings 默认 OpenAI，可换 Gemini / Voyage / Mistral / Bedrock / DeepInfra / 本地 GGUF / Ollama / LM Studio / 任意 OpenAI-compatible。
- dreaming：后台巩固，默认开；阈值化晋升入 MEMORY.md，DREAMS.md 供人审。
- memory provenance：不可信来源的记忆隔离 + 隔离警告；compaction 前自动 memory flush；active memory 跨会话召回（rememberAcrossConversations）；可从 Codex / Claude Code / Hermes 导入记忆。

## 5. Agent 运行时与 LLM 接入（docs.openclaw.ai/concepts/agent-runtimes.md）

- **四层模型**：Provider（auth + 模型目录 + 命名，如 `anthropic`、`openai`、`github-copilot`）／ Model（如 `claude-opus-4-6`、`gpt-6-astra`，引用形如 `openai/gpt-6-astra`）／ Agent runtime（执行 prepared turn 的 loop）／ Channel（消息出入口）。
- runtime 家族：
  - embedded harness（跑在 OpenClaw loop 内）：`openclaw`（内置兜底）、`codex`（app-server）、`copilot`、`muse`；
  - CLI backend：`claude-cli`（模型引用保持 `anthropic/<model>` 标准形，执行走本地 Claude CLI 进程）；
  - 外部 harness（Claude Code、Gemini CLI、OpenCode、Cursor）走 ACP/acpx 适配。
- runtime 选择顺序：model-scoped `agentRuntime` > provider-scoped > `auto`（注册插件可认领支持的 provider/model 对）> `openclaw` 兜底。
- 订阅型接入：ChatGPT/Codex 订阅 → `openai/*` refs + codex runtime + Codex OAuth；GitHub Copilot 订阅 → `github-copilot` provider + `copilot` runtime（外部 `@openclaw/copilot` 插件，`auto` 永不自动选它）。
- 非 openclaw runtime 的**兼容契约**公开成表：谁拥有 model loop / 主线程状态 / dynamic tools / hooks / context engine / compaction；不支持的表面明示降级行为。对多 runtime 平台这是认真的接口边界做法。
- Code Mode：实验性 agent-runtime 特性，按模型自动激活。

## 6. 技能 / 插件 / 扩展

### 6.1 Skills（docs.openclaw.ai/tools/skills.md）

- skill = 一个目录 + `SKILL.md`（YAML frontmatter `name`/`description` + markdown 正文），教 agent 何时/如何用工具；**无独立运行时**，编译成 compact XML block 注入 system prompt（每 skill ≈ 97 chars + name + description，约 24 token 级）。
- 加载优先级（同名高优先覆盖）：workspace `<workspace>/skills` > project `<workspace>/.agents/skills` > personal `~/.agents/skills` > managed `<state-dir>/skills` > workshop `<state-dir>/agents/<agentId>/agent/workshop-skills` > bundled > custodian > `skills.load.extraDirs` + plugin skills。
- gating：`requires.bins / anyBins / env / config`、`os` 平台过滤；per-agent allowlist：`agents.entries.*.skills`（非空即最终集合，不与 defaults 合并）。
- 引用：prompt 中 `$skill-name`（单消息最多 8 个）；`skills_search` / `skills_read` 工具按需读全文（正文上限 256KiB、分页续读）。
- **ClawHub**（clawhub.ai）公共 registry：`openclaw skills install @owner/<slug>`（支持 git:、本地目录、skills-sh: 源）；`openclaw skills verify` 拉取 trust envelope + VirusTotal/ClawScan 静态扫描；`security.installPolicy` 可在安装前跑本地策略命令 allow/warn/block。
- Skill Workshop：agent 自学技能自存于 workshop-skills，变更立即生效、留版本可 undo；node-hosted skills：headless node 连上时可发布本机技能，断线即消失。
- sandbox 同步：沙箱内读 materialized 副本；`requires.bins` 在 host 检查后还要求容器内存在（setupCommand 一次性装）。

### 6.2 Plugins

- 插件 **in-process 跑在 Gateway 内**（官方按 trusted code 对待）；`openclaw.plugin.json` 可声明 skills 目录、工具、渠道。
- 安装：ClawHub / 官方目录为 trusted 源；任意 npm/git/local 源需要 `--force`（确认来源后允许覆盖）且过 `security.installPolicy`；深度审计 `openclaw security audit --deep`。
- 「一切皆插件」倾向：模型 provider、agent harness（codex/copilot/muse）、多数渠道、memory 后端（LanceDB/Honcho）都是 plugin。

## 7. 安全与审批

### 7.1 Sandbox（docs.openclaw.ai/gateway/sandboxing.md）

- 默认关；`agents.defaults.sandbox`（全局）或 `agents.entries.*.sandbox`（per-agent）开启。Gateway 进程永远留在 host，**只有工具执行**进沙箱。
- 关键参数：mode（all / non-main / off，见 modes 子页）、`scope: agent(默认) | session | shared`（shared=一容器多 agent 共用，需谨慎）、`workspaceAccess: none(默认) | ro | rw`（沙箱对 agent workspace 的可见性）。
- backend 矩阵：Docker（默认本地）、Podman、SSH（远端机承接）、OpenShell、Crabbox（云盒租赁）。
- 官方定位诚实："This is not a perfect security boundary, but it materially limits filesystem and process access."

### 7.2 工具权限与审批（docs.openclaw.ai/gateway/security/tool-permissions.md）

- tool policy：`tools.allow` / `tools.deny`（全局或 per-agent），**先于 sandbox 生效**；控制面敏感工具 `gateway`、`cron` 为 owner-only；untrusted 面板建议默认 deny 清单含 `sessions_spawn`、`sessions_send`。
- `tools.elevated` = 显式逃逸舱（在 gateway/node 上跑 exec、绕过沙箱），需收紧 `allowFrom`。
- 跨 provider 消息默认开（`tools.message.crossContext.allowAcrossProviders: true`），可分别关 across/within provider。
- node 执行 = RCE 面：靠 pairing 信任 + gateway 全局命令 allow/deny + Mac 本地 exec approvals 文件（security+ask+allowlist）双层管控；approval 绑定精确命令上下文，无法唯一定位本地文件 operand 时宁可拒绝。
- sub-agent 委派护栏：`sessions_spawn` 默认 sandbox "inherit"，严格场景用 `"require"`（子 runtime 不在沙箱则 fail fast）。
- install policy：`security.installPolicy` 在技能/插件安装前跑本地策略命令，返回 allow/warn/block，interactive 下 warn 要求操作员逐项确认。
- prompt injection 防线：外部内容一律 untrusted input 包装；网络读取 taint 当前 turn（显式 owner 归因可保留 live authority）；joinIntro turn 零工具 + 60s 上限。
- per-agent access profile 三档样板（官方给的 pattern）：personal（全访问无沙箱）/ family（沙箱 + 只读工具）/ public（沙箱 + 无 fs/shell，只留消息工具）。
- 跨 agent 可见性：`tools.sessions.visibility: self | tree | agent | all`；agent-to-agent 消息默认开，用 `tools.agentToAgent` 收窄（含 send-only 模式）。

## 8. 自动化入口：cron / webhook / Gmail / IMAP（docs.openclaw.ai/automation/cron-jobs.md）

- **Automations** = 内置调度器（`openclaw automations` CLI，`openclaw cron` 是别名）：持久化 job、到点唤醒 agent、输出投递到渠道 / webhook / 静默。
- schedule 类型：一次性（`--delete-after-run`）、recurring cron 规则（day-of-month 与 day-of-week 是 OR 逻辑）、聊天快捷 `/loop`、dynamic cadence (pacing)、event triggers（condition watchers，事件驱动不依赖时刻）。
- payload：`--message` / command / script / agentTurn（可覆盖 `--model --thinking --light-context --tools`）；执行样式 main session / current / isolated（fresh session）/ custom。
- delivery：渠道消息 / webhook 输出 / 无输出；失败有通知。
- inbound webhooks：Gateway HTTP 面 `POST /hooks/wake`、`POST /hooks/agent`、mapped hooks `POST /hooks/<name>`（带鉴权）。
- **Gmail PubSub trigger**：官方推荐配 restricted reader agent（deny 面 + 专用 model 的受限读邮件 agent）；另有 IMAP email trigger。
- standing intents / standing orders：事件触发的持续意图与长期授权机制（不依赖 schedule）。
- `cron` 工具默认 owner-only（control-plane 敏感）；automation job 可按 job pin access 档位。

## 9. 多 agent 支持

- **一个 Gateway 进程可跑多个隔离 agent**；配置 `agents.entries.<agentId>`：每个 agent 独立 workspace（默认 `~/.openclaw/workspace-<agentId>`）、agentDir（`~/.openclaw/agents/<agentId>/agent`）、独立 SQLite session store（`<agentDir>/openclaw-agent.sqlite`）、独立 auth profiles、skills allowlist、sandbox 配置、tools allow/deny。**禁止跨 agent 复用 agentDir**（auth/session 会碰撞）。
- CLI：`openclaw agents add work --bind <channel[:accountId]>`；`openclaw agents team create` 预设团队（coordinator/researcher/writer/reviewer，配 `subagents.allowAgents` + delegationMode）。
- **binding 路由层级**（most-specific 优先）：exact peer > parent peer > peer wildcard > guild+roles > guild > team > account > channel > fallback owner；同层按 config 顺序，多字段之间 AND。
- 概念正交（官方原文语义）：agentId = 一个「大脑」（workspace + auth + session store 的集合）；accountId = 一个渠道账号实例；binding = 把 `(channel, accountId, peer)` 三元组路由到 agentId。
- 单 agent 默认 agentId=main（session key `agent:main:main`）；跨 agent 访问由 `tools.agentToAgent` 控制（默认开，可收窄至 send-only）；session 可见性由 `tools.sessions.visibility` 控制。
- skills 可 per-agent（workspace/skills）或共享（`<state-dir>/skills`）；sandbox/tools/skills 均可 per-agent 覆盖全局默认。
- node session hosting：worker session 可放到配对 node 上执行（容器隔离），capacity/设备放置由 Gateway 管理。

## 10. 对本平台的借鉴点与反面教训

### 借鉴点

1. **账号/agent/binding 三概念正交**是「同渠道多账号」的正解：账号是配置树节点（`channels.<ch>.accounts.<id>`），路由是显式绑定表带 most-specific 语义。不要把账号数硬编码进渠道实现。
2. **Gateway 单进程持有全部消息面 + 状态 + 凭据**：local-first、单 SQLite、单 WS 端口、单调度器，简单且可审计；对 Crystal 的 actor/fiber 并发模型天然适配（每渠道一 actor、路由器一 actor、调度器一 actor）。
3. **一切皆插件**：渠道、模型 provider、agent harness、memory 后端全是 plugin；monorepo 内 official plugin + 仓外 external plugin 的双层生态，让 WeChat/WeCom 这类协议风险渠道由社区在仓外维护。
4. **skills = 纯 markdown 注入 prompt**（无代码运行时）+ registry 信任信封（ClawHub verify：版本指纹 + 静态扫描）+ 本地 installPolicy 审批命令：轻量、可审计、token 成本可算（官方给了公式）。
5. **memory 全是人可读 markdown**（MEMORY.md / USER.md / 每日笔记 / dreaming 人审通道）+ SQLite 只做检索层：可解释、可手改、可 git 管理。
6. **session 路由按来源分粒度**（DM 共享 / group 隔离 / cron 一次性 / webhook 按 hook）且 dmScope/groupScope 可调——隔离粒度按对话形态而非一刀切。
7. **runtime 兼容契约表**：多 runtime（openclaw/codex/claude-cli/ACP）并存时，把「谁拥有 model loop/线程状态/hooks/compaction」写成公开契约，能力不支持就显式降级——多 harness 平台的接口边界范本。
8. **危险面默认最小**：joinIntro 零工具 60s、外部内容 untrusted 包装、网络读取 taint、subagent sandbox:"require" fail-fast、安装策略命令门禁。
9. **doctor 命令模式**：`openclaw doctor --fix` 内建配置迁移（如 legacy 单账号 authDir → whatsapp/default、legacy 模型引用重写）——升级路径产品化。

### 反面教训 / 注意

1. **文档「不变量」会腐烂**：architecture 页仍写 "Exactly one Gateway controls a single Baileys session per host"，而 multi-account WhatsApp 已是主推特性，两页并排容易误读。平台设计文档中的架构不变量要版本化并随特性演进同步修订。
2. **relay 概念消失且无迁移专页**：早期托管 relay 被 Tailscale/SSH 方案取代，文档里只剩 Slack 的 "relay mode" 残影；被移除的外部组件应在 changelog 留明确迁移说明。
3. **复杂度重心移到配置体系**：openclaw.json 的 agents/channels/skills/tools/sandbox 树 + per-agent 覆盖 + 默认继承 + 大量 legacy 键（whole-agent runtime keys、codex-cli/* 模型引用、agentHarnessId…）要靠 doctor 清理——命名稳定性和 schema 版本化必须从第一天做对，否则迁移工具永远追不完。
4. **sandbox 自认非完美边界**：GitHub identity 注入沙箱即暴露凭据（官方明说 read-only mount 只防改不防读）、`tools.elevated` 逃逸舱、`scope: shared` 串台——安全边界的「做不到」要显式文档化，不能只写能做到的。
5. **session DM 默认共享是单用户假设**：多人共用 Gateway 时 DM 会话天然串台，官方事后用 multiplayer 文档 + dmScope: per-account-channel-peer 补课。多租户/多用户场景应在设计期就定好 peer 维度。
6. **单 Gateway 进程 = 单点**：全部渠道 + 状态 + 调度集中在一个 Node 进程，无水平扩展参考（cloud workers/cloud sessions 是另一种形态但未覆盖渠道接入）。Crystal 平台若预期多实例，需自行设计分片/接管语义，OpenClaw 给不了参照。

## 来源 URL 清单

1. README（仓库主介绍）: https://raw.githubusercontent.com/openclaw/openclaw/main/README.md
2. 官方文档总索引: https://docs.openclaw.ai/llms.txt
3. Architecture（架构/进程模型/WS/不变量）: https://docs.openclaw.ai/concepts/architecture.md
4. Multi-agent（★多账号/binding/agents.entries/团队）: https://docs.openclaw.ai/concepts/multi-agent.md
5. Nodes（多设备/pairing/命令面）: https://docs.openclaw.ai/nodes.md
6. Chat channels（渠道目录/凭据/joinIntro）: https://docs.openclaw.ai/channels.md
7. Config channels: personal messaging（多账号 WhatsApp/默认账号/doctor 迁移）: https://docs.openclaw.ai/gateway/config-channels/personal-messaging
8. Session（路由表/scope/持久化/maintenance）: https://docs.openclaw.ai/concepts/session.md
9. Memory（MEMORY.md/后端/dreaming/provenance）: https://docs.openclaw.ai/concepts/memory.md
10. Agent runtimes（四层模型/runtime 家族/兼容契约）: https://docs.openclaw.ai/concepts/agent-runtimes.md
11. Skills（加载优先级/allowlist/ClawHub/Workshop）: https://docs.openclaw.ai/tools/skills.md
12. Sandboxing（模式/scope/backend 矩阵）: https://docs.openclaw.ai/gateway/sandboxing.md
13. Tool permissions（allow/deny/elevated/node exec/审批/profiles）: https://docs.openclaw.ai/gateway/security/tool-permissions.md
14. Automations（cron/webhooks/Gmail/IMAP/standing orders）: https://docs.openclaw.ai/automation/cron-jobs.md
15. 仓库配置参考（two WhatsApp accounts → two agents 示例所在）: https://github.com/openclaw/openclaw/blob/main/docs/gateway/configuration.md
16. Slack relay mode（唯一现存 "relay" 用法）: https://docs.openclaw.ai/channels/slack/transports

## 未验证清单

1. **relay.openclaw.ai（早期托管 relay）现状**：文档索引无该页面，未单独访问；仅确认当前架构无独立 relay 组件。
2. **GitHub issues 层证据**：未抓取 openclaw/openclaw 的 issues/PR 讨论；「多账号支持」结论基于官方文档与仓库 docs，未经 issue 级交叉验证。
3. **WeCom / WeChat（openclaw-weixin）外部插件内部实现**（协议、回调、凭据布局）：仅确认存在与安装入口，子页细节未展开。
4. **Slack "relay mode" 具体行为**：仅确认它是 Slack transport 三选项之一，子页差异细节未读。
5. **msteams 多账号成熟度**：英文版 multi-agent.md 的 17 渠道列表含 msteams（日文版列表缺失该渠道，以英文版为准），但 msteams 多账号的实机表现未单页核实。
6. **sandbox mode 的完整取值集合**：modes-scope-and-backend 子页未展开读取（本文引用 mode: all/non-main/off 及示例值）。
7. **Voice Call / Reef / cloud workers / cloud sessions / A2A** 等外围形态仅确认存在，未深入。
8. **Baileys 单会话不变量的原意**：按上下文推断为「gateway 是唯一控制 Baileys 会话的进程」，未见官方逐句澄清，保留原文供后续核对。
