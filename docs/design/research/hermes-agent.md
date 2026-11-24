# Hermes Agent（Nous Research）调研笔记

> 调研路线①：为「Crystal 个人 Agent 平台」设计调研同类项目。
> 调研人：翰林院编修（hanlin-bianxiu）· 日期：2026-11-18 · 性质：纯调研，只读。
> 本笔记自包含：所有关键结论均附来源 URL；无法核验的在文末「未验证」小节集中列出。

## 消歧定案

**主对象**：Nous Research 的开源项目 **Hermes Agent**（github.com/NousResearch/hermes-agent，官网 hermes-agent.nousresearch.com，MIT License）——一个 self-hosted 个人 AI Agent：终端原生（terminal-native）的自主编码/任务 agent，带持久记忆、agent 自建 skills、以及一个驻留在 21+ 消息平台的 messaging gateway（Telegram、Discord、Slack、SMS、Matrix 等，官方 docs 索引原句：19 native + IRC/Microsoft Teams via plugins）。
（来源：https://hermes-agent.nousresearch.com/docs/llms.txt ；https://raw.githubusercontent.com/NousResearch/hermes-agent/main/README.md）

两条消歧线索均指向同一对象：
- Clawrium（多机 agent fleet 管理工具）将 OpenClaw / Hermes / ZeroClaw 并列为可治理的 agent 运行时，其中 Hermes 标注 (Nous Research)、OpenAI-compatible local API——「Hermes」确为 OpenClaw 同生态的独立运行时（依据既有调研记忆 id 2a397aee，本次未重抓 Clawrium 文档核验，见「未验证」）。
- Nous Research 的 Hermes **模型**系列（Hermes LLM 家族）是同门另一条产品线，不是本调研对象；hermes-agent 可接任意模型端点（含但不限于 Hermes 模型），二者勿混。

第三方热度（仅作背景，star 数未直接核验）：36kr 报道上线两个月 47k star（https://eu.36kr.com/en/p/3760771429958403 ）；钛媒体 2026-04-23 称超 10 万 star、社区外号「爱马仕」（https://www.tmtpost.com/7960448.html ）。第三方对比文将其定位为 OpenClaw 的头号对比对象：Hermes=可持续积累能力的统一 runtime（共享 runner、环境框架/benchmark/rollout 基建一等公民），OpenClaw=以 gateway/routing/session/delivery 为中心的 control plane（https://kanaries.net/zh/articles/hermes-agent-vs-openclaw ）。

---

## 1. 项目定位与形态

| 维度 | 事实 | 来源 |
|---|---|---|
| 定位 | "The self-improving AI agent"：self-hosted 个人 AI Agent，跑在自己机器/服务器上，跨会话持久记忆，自写可复用 skills | 官网 llms.txt、README |
| License | MIT | 官网 llms.txt、README |
| 部署形态 | CLI（`hermes`）、全功能 TUI（Ink 终端 UI）、常驻 messaging gateway（单进程服务多平台）、Hermes Desktop 桌面应用（Electron；macOS/Windows/Linux）、Web Dashboard（浏览器管理面板）、OpenAI-compatible API server、Python library（把 AIAgent 嵌入自己脚本） | docs/llms.txt 索引、README |
| 实现语言/规模 | Python 核心 + Node 工具链：source installer 委派 Python 3.14、Node.js、npm、pnpm、ripgrep、FFmpeg 给包管理器（TUI 用 Ink 佐证 Node）；40+ 内置工具、21+ 消息平台、~90 bundled skills + ~60 optional | README 安装段、docs/llms.txt 索引 |
| 运行环境 | $5 VPS 到 GPU cluster 到 serverless（Daytona、Modal：空闲休眠按需唤醒）；本地/Docker/SSH/Daytona/Modal/Vercel Sandbox 六种 terminal backends + 插件后端（Singularity/Apptainer）；Windows 原生支持 + WSL2 双路线；Android/Termux 签名 APT 仓 | README、docs/llms.txt |
| 模型层 | Nous Portal（300+ 模型 + Tool Gateway 一订阅全包）、OpenRouter、OpenAI、Anthropic、Google、任意 OpenAI-compatible endpoint；`hermes model` 随意切换无锁定 | README、docs/llms.txt |

入口与平台覆盖（对多账号设计最相关）：CLI/TUI/Desktop/Dashboard/API server 之外，messaging 平台目录含 **wecom（企业微信 AI Bot WebSocket gateway）、wecom-callback（自建应用回调）、feishu（Feishu/Lark）、dingtalk、qqbot、weixin（个人微信 iLink Bot API）、telegram、discord、slack、whatsapp、whatsapp_cloud、signal、email（IMAP/SMTP）、sms、matrix、line、teams（插件）、google_chat、msgraph-webhook、webhooks（GitHub/GitLab 事件）** 等 21+ 个——与本平台目标渠道（多 email / 多 WeCom / 多 Lark）完全同域。
（来源：https://hermes-agent.nousresearch.com/docs/llms.txt ）

---

## 2. 架构组件与数据流

**进程模型**（综合 multi-profile-gateways、session-storage-recovery、multiplexing-gateway 三页 + README）：
- 单个常驻 **gateway 进程**即可同时服务 Telegram/Discord/Slack/WhatsApp/Signal/CLI（README 原句 "all from a single gateway process"）；多平台共享一个 agent 核心。
- gateway、Desktop、Web dashboard、cron、CLI 命令是**多个独立进程**，通过 SQLite 自身的锁安全共享同一 per-profile 会话库 `state.db`（含 `-wal`/`-shm` 边车）（session-storage-recovery 页）。
- 本地 CLI/TUI 会话也被纳管为 **canonical gateway admissions**（docs 索引行 gateway-local-sessions），即消息入口统一走 gateway 的 admission/authorization 管道，不因本地/远程而双轨。

**消息入站数据流**（multiplexing-gateway 开发者页，2026-11-18 抓取）：
1. platform adapter 收到事件 → `BasePlatformAdapter._canonicalize` 在所有 ingress 路径先归一化；
2. 构造/冻结 **RoutingIdentity**（`gateway/session_identity.py`）：`transport_profile`（用哪个 bot 的凭据/allowlist 收的消息）与 `runtime_profile`（由哪个 profile 的 agent 执行、用哪套 key namespace 与 state 路径）解耦；
3. `gateway.profile_routes` 按 (platform, user_id, guild_id, chat_id, thread_id) 合取匹配、most-specific-first 路由到 profile；路由到未服务的 profile → **丢弃**（fail-closed）；
4. 命中 profile 后经 `_profile_runtime_scope(profile_home)` 设定 HERMES_HOME override + secret scope（均以 contextvars 存放，经 `copy_context()` 传播给执行 agent turn 的 worker thread，**绝不写 os.environ**）；
5. session 以 key `agent:<profile>:…` 命名空间隔离（default profile 保持 `agent:main:…` 不变），落到该 profile 自己的 `profiles/<name>/state.db`。

**agent 执行单元**：每条入站消息触发一个 agent turn（worker thread）；secret 读取经 `get_secret(name)`：全局 allowlist（仅监听类设置）→ 当前 scope → fallback；multiplexing 开启而无 scope 时直接 `raise UnscopedSecretError`（fail-closed，防止读到别人的凭据）。云端 SDK 的 ambient default chains（google.auth.default / DefaultAzureCredential / boto3）被主动禁用：profile 无完整凭据则对应 provider adapter 拒绝。

**模型/工具层**：provider-runtime 统一多厂商；provider-routing、fallback-providers（主模型故障自动切换）、credential-pools（每 provider 池化多 API key 自动轮换应对限流）为目录级集成（docs/llms.txt）。

> 诚实声明：docs 的 developer-guide 另有 architecture、agent-loop、prompt-assembly、gateway-internals、gateway-session-lifecycle 等专页（目录见 docs/llms.txt），本笔记未将其正文细节逐页纳入（见「未验证」#2）；上述结论来自已核验的多账号三页、Security 页与 README 交叉佐证。

---

## 3. Agent Loop、工具调用与记忆

**学习闭环（项目最大卖点，README 原文归纳）**："the only agent with a built-in learning loop — it creates skills from experience, improves them during use, nudges itself to persist knowledge, searches its own past conversations, and builds a deepening model of who you are across sessions"。构成件：
- **agent-curated memory**：MEMORY.md（agent 自管）+ USER.md（关于用户的事实）+ 全局 SOUL.md（人格）分层；每次对话自动注入 context-files（.hermes.md、AGENTS.md、CLAUDE.md、.cursorrules）。（docs/llms.txt 索引 + README）
- **FTS5 session search**：全部历史会话 SQLite FTS5 全文检索 + LLM 摘要，agent 可检索自己的过去对话。（README）
- **Honcho dialectic user modeling**：用第三方记忆 provider 建用户画像；另有 Mem0、OpenViking、Hindsight、Supermemory、RetainDB 等一排 memory-provider 插件可换。（README + docs 索引 memory-providers）
- **skills 自建自改**：SKILL.md 格式、progressive disclosure（按需注入知识文档）、兼容 agentskills.io 开放标准、Skills Hub；**curator** 后台进程维护 agent 自建 skills（usage tracking、staleness、archival、LLM-driven review）。（README + docs 索引）

**Prompt/上下文工程**（docs/llms.txt 索引行，正文未深读）：prompt-assembly（系统提示构建 + cache 稳定性 + ephemeral 层注入）、context-compression-and-caching、micro-compaction——即提示词按「稳定层/上下文层/易变层」组织以保持 provider 前缀缓存命中。

**工具调用**（README + docs 索引）：
- 40+ 内置工具，按 toolsets 分组；终端执行有六种 backends（local/Docker/SSH/Modal/Daytona/Vercel Sandbox）+ 插件后端；
- **code-execution**：Python 脚本经 RPC 调用 Hermes 工具，把多步流水线折叠成单个 turn（零上下文成本）——相当于给 agent 一个「用代码编排自己工具」的元能力；
- **delegate_task**：生成隔离子 agent 并行执行（subagent-lifecycle-api 供插件接入）；
- MCP：外部工具服务器 + 精确控制加载哪些 MCP 工具；MCP 可把 sessions/memories 暴露给 IDE 工具（Claude Desktop/Cursor/VS Code，36kr 报道）。

**调度**：cron（自然语言创建，`cronjob_manage` 工具管理）、persistent goals（Ralph loop 复刻：立 standing goal 跨 turn 续跑）、heartbeat（空闲会话定时重入）、loops（/loop）、kanban（SQLite-backed 看板协调多 profile）。（docs/llms.txt 索引 + README）

---

## 4. 多设备 / 多入口 / 多账号支持（本平台核心问题）

**结论先行：Hermes 对「同一渠道绑定 N 个同类账号」是一等公民支持**，其原语叫 **profile**——而且隔离粒度远超「账号绑定」：每个 profile 是一个完整 agent（自己的 config.yaml、.env 凭据、state.db 会话库、skills、memory、SOUL、cron、hooks）。

### 4.1 入口矩阵
同一 agent core 暴露为：CLI / TUI / Hermes Desktop / Web Dashboard / OpenAI-compatible API server（接任意 frontend）/ 21+ 消息平台 / ACP（进 ACP 兼容编辑器）/ webhooks（GitHub/GitLab 事件触发 agent run）。（docs/llms.txt）

### 4.2 多账号机制：profile + 两种 gateway 拓扑
（来源：https://hermes-agent.nousresearch.com/docs/user-guide/multi-profile-gateways ；https://hermes-agent.nousresearch.com/docs/developer-guide/multiplexing-gateway ）

- **拓扑① one process per profile**：每 profile 一个 gateway 进程，各自装 systemd/launchd/Windows Scheduled Task/s6 服务（`ai.hermes.gateway-<name>.plist`）。重隔离，资源成本高。
- **拓扑② multiplexing（默认开启，`gateway.multiplex_profiles: true`）**：单一 host gateway 进程服务所有 profile。设计约束原文："profile A's turns must never observe profile B's state"——凡做不到的要么 fail-closed 要么列为 known limitation。

**两类平台、两种多账号接线**（对本平台最有直接借鉴价值）：
1. **per-credential 轮询型**（Telegram/Discord/Slack/Matrix 等）：多 profile 各自持有自己的 bot token 长轮询——天然支持同平台 N 账号；同 (platform, token) 重复出现 → duplicate adapter 被 park（fatal/duplicate_credential），gateway 不退出。
2. **port-binding/HTTP webhook 型**（Twilio、LINE、Teams、BlueBubbles、msgraph、WhatsApp Cloud、**WeCom callback**、**Feishu webhook** 等）：共享同一监听器，按 URL 前缀 `/p/<profile>/<path>` 路由，各 named profile 用自己的 secret 验签；无对应 adapter → 404，secret 不对 → 401/403（fail-closed）。**这正是 WeCom/Feishu 多账号在 Hermes 里的实际接线方式**。

**每 profile 隔离清单**（官方 "What is isolated per profile" 大表摘录）：provider keys/bot tokens（各自 .env）；authorization 配置；slash 命令 admin gating（未加载 config → 空 admin 列表，fail-closed）；HTTP 端点 401/404/502/503 fail-closed；adapter 设置；附件 denylist（覆盖 profiles/ 全体防跨 profile 泄 .env/state.db）；stdio MCP 子进程环境（缺就是缺，不回退 default）；出站身份（发消息/关机通知/loop 唤醒走该 profile 自己的 bot，无则失败不借 default）；memory-provider 身份（MEM0_USER_ID/HONCHO host 各归各）；terminal sandbox/时区/max_turns/hooks 目录；cron 调优。

**Known limitations（process-global 未 scope 化，官方明列）**：MCP discovery + 工具注册（首个 profile 占位，issue #67605）；TERMINAL_* sandbox env 全局；内置工具/provider 注册表 overlay；HTTP listener / relay ingress / 进程锁每 process 一个。

**Non-goals**：multiplexing 只隔离 profiles，**不做 profile 之上的 end-user 鉴权**——"A profile is a configuration, not a person"。

### 4.3 Bot Mode：profile 的名册化（多 agent 协作）
（来源：https://hermes-agent.nousresearch.com/docs/user-guide/bot-mode ）
- Bot **is** a Hermes profile（`~/.hermes/profiles/<name>/`，无新原语；`hermes -p <bot> chat` 就是同一 agent）。
- 每个 Bot 有 canonical **Bot Chat**（forever-chat：点开永远回到同一会话，/new 被改道成 /compact 不 fork）。
- Bot 之间用 **message_agent** 工具互发消息：fire-and-forget（ack=queued+delivery_id，完成后带回复通知）；发送方自动署名 `Message from 🤖 <name> (@<handle>):`；**bot_loop_guard.max_hops 默认 4**——一轮交换内 bot-to-bot 传递上限，超过拒发（防 agent 互发死循环）；bot 的回复默认不可再被回复（bot_replies_expect_reply=false）。
- Group chats：2–6 个 Bot 共享房间，成员 turn 携带最近 ~200 条消息/32K chars 转录；失败保序进 Activity summary（带 reason 码）。
- Routines = cron jobs（`[bot:<name>] <routine>` 命名空间）。

### 4.4 多设备 / 跨机
- **multi-connection-desktop**：一个 Desktop 连接多台 Hermes 实例（docs 索引）。
- **Desktop relay**：Desktop 当 courier 的持久 socket 双向投递（~26 分钟期限、重投一次、~52 分钟上限）（bot-mode 页）。
- **hermes peer**：无 Desktop 的机对机直连（`peer add --url --key`，走 API_SERVER_KEY；`peer dm <bot> < file`、`peer run --idempotency-key`）；NAT 场景单向：内网机器可拨出公网 peer，反向需 Tailscale/VPN 或把 room authority 放公网 VPS（bot-mode 页）。
- **gateway-owned group chat**：跨机 Bot 群聊（home gateway 管房间、member gateway 跑成员 turn，RoomLink capability catalog + signed execution policy，access grant 20h 续期 30 天上限）（bot-mode 页）。

---

## 5. 持久化与恢复（durable 机制）

（来源：https://hermes-agent.nousresearch.com/docs/user-guide/session-storage-recovery ，2026-11-18 抓取）
- **存储**：每 profile 一个 SQLite `state.db`（+ SQLite 自管的 `-wal`/`-shm`）；gateway、Desktop、dashboard、cron、CLI 多进程经 SQLite 锁安全共享。
- **WAL 单写者自律**：当某进程在 store 被重写后仍持有旧 WAL 副本时，**所有新进程主动停止写入**（宁拒不写坏）并提示用户；`hermes doctor` 列出持有旧 log 的 PID；被替换的旧 log 会保存为 `state.db.retired-wal-<timestamp>-<pid>/`（含 manifest.json）作取证而非盲目恢复用。
- **维护命令防呆**：`sessions optimize/prune` 在有活跃写者时拒绝执行（`--force` 可越过，`--dry-run` 永不拦）。
- **恢复工具**：`hermes sessions recover --inspect-only`（只读探伤）、`hermes backup` 快照、`state-snapshots/`、Desktop 更新前的 `pre-update-emergency` 备份、损坏文件的 `.corrupt.*.bak` 隔离。
- **四条禁令**（官方原文化）：别在运行中跑 `doctor --fix`；别删 `-wal`/`-shm`（删了才真丢数据）；别单拷 `state.db`（三文件是一个镜像）；别让 agent 自己修（它自己的会话在同一库，会撞同一拒绝）。
- **其他 durable 件**：cron jobs（jobs.json，经 cronjob_manage API 而非直接 patch）、kanban（SQLite-backed）、persistent goals（跨 turn 续跑）、Checkpoints & Rollback（shadow git repo + 自动快照，docs 索引行，未深读）、Modal serverless persistence（空闲休眠按需唤醒，README）。

---

## 6. 安全模型

（来源：https://hermes-agent.nousresearch.com/docs/user-guide/security ，官方自述 **defense-in-depth 八层**，2026-11-18 抓取）

1. **User authorization（谁可对话）**：六层检查序（`_is_user_authorized`）：per-platform allow-all → DM pairing 批准表 → 平台 allowlist → 全局 allowlist → 全局 allow-all → **默认 deny**。环境变量形如 `TELEGRAM_ALLOWED_USERS=...`。
2. **Dangerous command approval**：`approvals.mode: smart|manual|off`（默认 smart=辅助 LLM 评风险、低危自动过、高危自动拒、不确定问人）；`timeout: 300` 超时即拒（fail-closed）；**无人值守三键默认 deny**：`cron_mode`/`single_query_mode`/`unattended_mode`（cron/`-q`/webhook/API 场景无人可答 → 直接拒）；YOLO 模式（--yolo//yolo/HERMES_YOLO_MODE）可关提示但只作用于该会话。
   - **Hardline blocklist（不可 override 的地板）**：rm -rf / 及变体、fork bomb、mkfs 活动根、dd 裸写盘、Windows 的 Format-Volume/rd /s /q C:\、Restart/Stop-Computer、rootfs 顶层 pipe-to-sh——在 --yolo、mode:off、cron approve、点"always"之上仍然拒绝；引号解析不了的命令也 fail-closed。
   - **`approvals.deny`**（用户自定 fnmatch glob，先于 --yolo 生效）与 **`command_allowlist`**（always 永久允许表）+ `hermes approvals suggest`（从历史审批挖模式，destructive 类永不提议、凭据自动打码）。
   - **supervised-gateway 生命周期守卫**：terminal 工具不可 override 地拒绝从被监管的 gateway 进程内重启 gateway/杀自身解释器镜像（防 supervisor 循环）。
3. **File write safety**：write_file/patch 的 protected paths 硬拒（~/.ssh/、~/.aws/、~/.kube/、.env、OAuth/token 缓存、Windows NT/device-namespace 路径连读都拒——防 NTLM 泄漏）；`HERMES_WRITE_SAFE_ROOT` 可选写沙箱（官方 Docker 镜像默认设 /opt/data）；`~/.ssh/config` 特例走审批（因无私钥材料但可带 ProxyCommand）。
4. **Container isolation**：Docker/Modal（+Singularity 插件）加固沙箱；**容器即边界——容器后端内跳过危险命令审批**（破坏不出容器）。
5. **MCP credential filtering**：stdio MCP 子进程环境按 profile scope 过滤（见 §4.2 隔离表）。
6. **Context file scanning**：项目文件 prompt injection 检测。
7. **Cross-session isolation**：会话互不可见；cron 存储路径抗 path traversal。
8. **Input sanitization**：terminal 工具的 working directory 参数按 allowlist 校验防 shell 注入。

**配套件**：credential-vault（agent 代登录代付、不见密码，docs 索引）；Network Egress Isolation（Docker 网络分段 allowlist）与 iron-proxy credential-injection（docs 索引）；Managed Scope（管理员钉死用户不可改的 config+secrets，docs 索引）；official-domains 防钓鱼页（docs 索引）；36kr 报道的「容器隔离、只读文件系统、预执行扫描」与官方 Security 页一致（https://eu.36kr.com/en/p/3760771429958403 ）。
**审批的细节级借鉴**：消息平台上审批卡若无法完整展示命令（太长被截/含 fence），只提供 Deny 选项——绝不让人批准看不全的命令；共享群里 `approvals.approvers` 可把审批绑定回请求者本人。

---

## 7. 扩展机制

（来源：docs/llms.txt 索引 + README；机制条目为目录级 + 多页交叉，逐页细节未深读）

- **Skills**（第一扩展位）：SKILL.md 知识文档、progressive disclosure、agent 自管 + curator 治理、~90 bundled + ~60 optional、Skills Hub / agentskills.io 兼容、用户可直接 `/<skill-name>` 调。
- **Plugins**：自定义 tools/hooks/integrations；plugin-catalog 一键装 reviewed 插件；public-api 白名单（`hermes plugins validate` 校验 import 面）；插件可经 `ctx.llm` 调 LLM；observer-hooks 只读遥测契约；middleware 可改 LLM/tool call 行为；built-in plugins（lifecycle hooks 自动跑，disk-cleanup 等）。
- **Provider seams（九类插件接缝）**：memory-provider、context-engine（替换内置 ContextCompressor）、delegation-provider、model-provider、web-search-provider、secret-source（Bitwarden/1Password/command helper）、terminal-environment、desktop-plugin-sdk（@hermes/plugin-sdk）、relay-connector-contract。
- **MCP**：外部工具服务器，精确控制加载哪些工具；trust/spend_limit（花费上限是预算不是安全提示，YOLO 也不跳过）。
- **Import from Other Agents**：一键导入 OpenClaw ~/.openclaw、Claude Code ~/.claude、Codex、Cursor、Grok Bot、OpenBot 的 instructions/rules/allowlists/MCP servers/skills/memories/routines——直接瞄准 OpenClaw 存量用户迁移。

---

## 8. 对本平台（Crystal 个人 Agent 平台）的借鉴点与反面教训

### 借鉴点（按本平台硬需求排序）

1. **profile 作为多账号第一原语**——直接回答硬需求①：Hermes 不是做「渠道账号绑定表」，而是把「一个完整 agent 实例」（凭据+会话库+记忆+人格+调度）作为可复制单元；同渠道 N 个 WeCom/N 个 Lark/N 个 email 账号=N 个 profile，天然不共享任何状态。Crystal 可落为 `struct ProfileConfig` + 每 profile 一套 fiber/Channel 拓扑与独立存储目录。
2. **两类平台二分接线**：per-credential 轮询型（各持 token）vs port-binding webhook 型（共享监听器 + URL 前缀路由 + per-profile secret 验签）。WeCom callback 与 Feishu webhook 在 Hermes 中正是走 `/p/<profile>/` 前缀路由——本平台多 WeCom/多 Lark 账号可直接抄此拓扑；重复凭据检测（park duplicate adapter 而非进程崩溃）也值得抄。
3. **transport_profile / runtime_profile 双身份解耦**（RoutingIdentity）：「用哪个账号收的消息」与「由哪个 agent 实例执行」是两个可独立配置的轴——比「一个账号=一个 agent」灵活得多，也为凭据轮换/迁移留出空间。
4. **fail-closed 默认贯穿**：路由到未服务 profile 丢弃、secret 无 scope 即 raise、审批超时即拒、无人值守场景（cron/webhook/API）默认 deny、看不全的命令只给 Deny、config 未加载时空 admin 列表。本平台的编排引擎（触发→条件→动作）在无人值守时同样应 deny-化危险动作。
5. **Crystal 特性对位**：Hermes 用 Python contextvars + copy_context 做隐式 scope 传播（并承认这就是 MCP discovery 等 known limitation 的根源——「凡没 scope 化的都会漏」）。Crystal 可反其道：用显式消息传递（Channel 里传带 profile 上下文的结构体）替代隐式 contextvar，scope 由类型/构造器保证，编译期即防「读错凭据」。
6. **多 agent 协作防环**：message_agent 的 fire-and-forget + 署名前缀 + `bot_loop_guard.max_hops=4` + 「bot 回复默认不可再被回复」——三行配置防住 agent 互发死循环，本平台 agent 协作调度可直接照抄参数化。
7. **持久化恢复的成熟 UX**：WAL 持有者冲突「宁拒不写」+ retired-wal 取证目录 + doctor 列 PID + 三文件一镜像禁令 + `recover --inspect-only` 只读探伤。本平台 SQLite 持久层设计时应把「多进程共享单库」的坑前置成一页恢复文档。
8. **审批历史挖掘**（`hermes approvals suggest`）：把用户过往审批聚合成 allowlist 提案、destructive 类永不提议、凭据打码——人机信任随时间收敛的好机制。
9. **学习闭环的产品化拆解**：MEMORY.md/USER.md/SOUL.md 三文件分工 + FTS5 会话自检索 + skills 自建 + curator 后台治理——「自提升」不是玄学而是四个可独立实现的组件。

### 反面教训

1. **双运行时之重**：Python 核心 + Node 工具链（源码安装拖 Python 3.14/Node/pnpm/FFmpeg），跨平台安装面巨大（原生 Windows、WSL2、Termux、Docker、Nix 各一条路线）。Crystal 单二进制正是本平台的差异化机会：入口矩阵做大（CLI/TUI/Desktop/Dashboard/API）不必伴随运行时矩阵做大。
2. **隐式 scope 的漏**：multiplexing 官方自认 MCP discovery、TERMINAL_* env、工具/provider 注册表仍是 process-global（issue #67605）——共享进程模型里所有全局状态都是隔离债。教训：scope 传播机制必须在第一个插件/第一个工具接入前定型，后补必然漏。
3. **profile ≠ person**：官方明示 multiplexing 不做 profile 之上的用户鉴权，群聊/共享聊天场景靠 Bot Mode 的 approvers/admin gating 一层层打补丁（本笔记 Security 页可见其规则叠到多长）。本平台若一开始就有「家庭/团队多人共用」场景，应把 actor（人）与 profile（agent 配置）建成两个正交概念。
4. **入口矩阵×安全说明的组合爆炸**：21+ 平台 × (CLI/TUI/Desktop/dashboard/peer/relay/cron/webhook) 的安全行为矩阵在文档里已出现大量 per-case 特判（如「Discord 经 relay 的交互按下更紧」「ntfy/DingTalk/LINE 截长消息时先给答案说明」）。本平台控制在少数入口+可插拔 adapter，可避免同样的规则熵。
5. **多进程共享单 SQLite 是持续运维痛点**：官方需要专门一页恢复文档 + doctor 体检 + 四条禁令。本平台若走单常驻进程（autobot 模式）天然规避；若必须多进程，学它的防呆而非重蹈。

---

## 来源 URL 清单

**官方（本次直接抓取/核验）**
1. https://hermes-agent.nousresearch.com/ （官网 llms.txt：定位、入口、MIT）
2. https://hermes-agent.nousresearch.com/docs/llms.txt （全站文档索引：21+ 平台目录、Bot Mode、Desktop、Security、Checkpoints、Managed Scope、developer-guide 页目）
3. https://hermes-agent.nousresearch.com/docs/user-guide/security （安全八层、审批、hardline、写安全、鉴权序）
4. https://hermes-agent.nousresearch.com/docs/user-guide/session-storage-recovery （state.db/WAL 恢复）
5. https://hermes-agent.nousresearch.com/docs/user-guide/multi-profile-gateways （多 profile 拓扑、隔离表、/p/ 前缀路由）
6. https://hermes-agent.nousresearch.com/docs/developer-guide/multiplexing-gateway （RoutingIdentity、secret scope、known limitations、non-goals）
7. https://hermes-agent.nousresearch.com/docs/user-guide/bot-mode （Bot=profile、message_agent、loop guard、peer/relay）
8. https://github.com/NousResearch/hermes-agent （仓库；页面抓取在导航处截断，正文改用 raw README）
9. https://raw.githubusercontent.com/NousResearch/hermes-agent/main/README.md （口号、学习闭环、六 terminal backends、安装、导入器）

**第三方（报道/对比，供热度与生态定位参考）**
10. https://eu.36kr.com/en/p/3760771429958403 （36kr：47k star/两个月、容器隔离说法）
11. https://www.tmtpost.com/7960448.html （钛媒体 2026-04-23：超 10 万 star）
12. https://kanaries.net/zh/articles/hermes-agent-vs-openclaw （2026-04-14 定位对比：runtime vs control plane）

**既有调研记忆（未重核验）**
13. 记忆 id 2a397aee：Clawrium（pypi clawrium / github ric03uec/clawrium）将 OpenClaw/Hermes/ZeroClaw 并列为可治理运行时，Hermes 标注 Nous Research、OpenAI-compatible local API。

---

## 未验证（诚实清单）

1. **GitHub star 数**：47k/超 10 万均为 36kr、钛媒体第三方说法，本次未在 GitHub 页面直接核验（GitHub 仓库页抓取在导航处截断，未见 star 数）。
2. **developer-guide 深层页**（architecture、agent-loop、prompt-assembly、gateway-internals、gateway-session-lifecycle、context-compression 等）：目录存在（docs/llms.txt）且部分事实经 multiplexing/multi-profile 两页交叉印证，但其正文细节未逐页纳入本笔记；§2/§3 中标「索引级/未深读」的条目如需引用进设计文档，应先补抓对应页。
3. **Checkpoints & Rollback、Managed Scope、egress/iron-proxy、kanban-multi-gateway、Import from Other Agents、credential-vault、memory-providers、curator**：仅有 docs/llms.txt 索引行 + README/Security 页交叉引用，未抓专页正文。
4. **Hermes Desktop = Electron、TUI = Ink**：出自 docs/llms.txt 索引描述，未在 Desktop/TUI 专页核验技术栈细节。
5. **Clawrium 对 Hermes 的治理能力细节**：来自既有调研记忆（2a397aee），本次未重抓 Clawrium 文档核验。
6. **atlantic.net one-click 云部署**（2026-10-08）：仅 web_search 结果快照，未抓取原页，具体 URL 未存全。
7. **HermesClaw 社区微信桥**（同一微信账号同时跑 Hermes 与 OpenClaw）：README 提及，项目本身未核验。
8. **Nous Research Hermes 模型家族与 hermes-agent 的集成深度**（Hermes 模型是否为默认/推荐 provider）：本次未核验；仅确认 agent 侧接任意 OpenAI-compatible 端点。
