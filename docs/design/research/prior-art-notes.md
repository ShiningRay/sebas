# 旧事旁证清单（prior-art-notes）

- **产出**：通政使 tongzheng，2026-11-18，受首辅分派。
- **用途**：为「Crystal 多账号可编排 Personal Agent 平台」设计提供旧事与旁证的联系，供首辅取舍；不改排序、不重做一线调研、不否决已派任务。
- **来源**：memlite 记忆（逐条注明 id）；另查 `search_context`（关键词：个人 agent / OpenClaw / 多账号 / 编排）——本会话尚无压缩块，无命中，旧结论已由 memlite 覆盖。
- **本项目语境**（ec38665a）：硬需求两条——①同渠道多账号并存（多 email、多企业微信 WeCom、多飞书/Lark）；②用户可编排（消息/事件→条件→动作的自动化流程或 agent 协作）。产出目录约定 `docs/agent-platform-design/`。
- **标注口径**：`可直接采信` = 有本仓源码行号或已验收实测证据；`需一线调研复核` = 外部 web 快照（含非官方文档站）或属于类比推论，与一线调研（hanlin-bianxiu 各路）对照后再定。

## 一、旧事旁证清单

### 1. 多机 Bot Agent 编排选型四形态（2a397aee）｜需一线调研复核

**旧结论**：跨机编排 AI Agent 的工具按机制分四类——
- **中控台型**（每机装 daemon + 一个面板）：Happier（`happier machine setup --ssh`、Relay 可自托管、宣称 100+ 会话）、AI Maestro、Clisbot、OpenHands Agent Canvas、safe-grokbot-bridge；
- **队列型**：vibey-engine（PG `FOR UPDATE SKIP LOCKED` + 预算上限 + append-only 账本）、ocaptain（VM 各跑一 Claude Code，任务竞争领取）、K8squad（K8s CRD + A2A 任务生命周期）、language-operator（自然语言→Argo Workflow）；
- **运维型**：Clawrium（对 OpenClaw/Hermes/ZeroClaw 做 install/upgrade/rollback/密钥轮换/token 限额）、OpenClaw 自身（一 Gateway 多 agent + nodes，两实例无内置桥）、Ansible/Salt；
- **云沙箱型**：Codex Cloud（默认断网）、Devin（每台独立 VM + Outposts）、Claude Code subagents/agent teams、Sprites.dev。
协议层：MCP 管工具、A2A（Linux Foundation）跨平台、ACP 接第三方 agent；微软原则「内部优先原生 subagent、跨平台才 A2A」。
另记 6 个坑：同仓并发需 worktree/独立 checkout、凭据勿复制（每机独立身份或短期 token）、YOLO 权限在多机是放大器、网络走 Tailscale/Tunnel 别开公网端口、token 花费须聚合、任务须 lease+过期回收；并引 103 天多机 fleet 实测（zenodo 23189387）说明协调协议先于模型退化。

**关联/启示**：这是「编排」的直接旧事。6 个坑与协议层结论可**直接迁移**到多账号场景（把「每机」换成「每账号」：每账号独立凭据/token 限额、花费聚合、动作任务 lease+回收）；四形态如何映射到个人单机多账号，见第二节。注意其调研口径是「跨机」而非「同渠道多账号」，映射属类比推论。

### 2. autobot vs ZeroClaw：同族（OpenClaw 重写）四轴对比（bbf5a8e0）｜整体需一线调研复核（zeroclaw 资料来自自称非官方的粉丝站与第三方博客，2026-02~03）

**旧结论**：autobot（Crystal）与 ZeroClaw（Rust）同为 OpenClaw 重写，差异四轴：
1. **安全哲学**：autobot 内核命名空间沙箱（bubblewrap/docker，README:36-44 明确反对应用层校验，sandbox.cr:46-47）；ZeroClaw 应用层策略（workspace_only 路径校验+屏蔽 14 系统目录、localhost-only gateway + 配对 OTP→Bearer、密钥静态加密、autonomy allowed_commands）。
2. **可替换性**：ZeroClaw 每子系统一个 Rust trait（Provider/Channel/Tool/Memory/Runtime/SecurityPolicy/Tunnel/Identity/Observer/Engine/Loader），改配置换实现；autobot 插件是编译期内置（sqlite/github/weather/tts，loader.cr:28 load_all 只遍历内置），新增要改码重编译。
3. **管理面**：ZeroClaw 有 gateway HTTP API（/health、/pair、/webhook）、daemon+HEARTBEAT.md、service start/stop/status、config schema、migrate openclaw、skills 装删；autobot 仅 9 子命令 CLI 且 `-p PORT` 不真起服务（gateway.cr:17 只打印 port）。
4. **规模**：频道 4+CLI vs ~14（Discord/Matrix/Signal/iMessage/Email/IRC/飞书/钉钉/QQ/Webhook）；provider 9 家 vs 28+；记忆 MEMORY.md+HISTORY.md grep 两层 vs SQLite FTS5+BM25+向量混合可换后端；ZeroClaw v0.8.0 自带 TUI（zerocode，Code/Chat 双 pane）。
命名坑：PyPI `zeroclaw` 是无关 cmdop 安装器；Micra-io 等同名仓库均为 fork 或冒充。

**关联/启示**：见第三节「OpenClaw 家族对比 → 新平台补齐建议」。核心：本次目标渠道（飞书/Email）在 OpenClaw 生态已有先例（渠道接线层面），但**两家都未验证「同渠道 N 账号并存」**——该点须等 hanlin-bianxiu-2 的 OpenClaw 一线证据。

### 3. autobot 架构 = 单进程事件总线分层单体（7731b342）｜可直接采信（源码级）

**旧结论**：装配根 gateway.cr:19-32（bus→session→tools/mcp→provider→plugins→cron→channels→agent loop）；并发靠 fiber + 两个有界 Channel(100)。关键事实：①Agent::Loop 只 spawn 一个 "agent-loop" fiber 顺序消费（queue.cr:26-27、loop.cr:111）→ **全局串行，一个慢 turn 阻塞所有会话**；session 隔离只靠 key `"#{channel}:#{chat_id}"`（events.cr:29-31）。②一次 turn：语音未转写固定话术→记忆 consolidate/trim→update_tool_contexts→Context::Builder→ToolExecutor（max_iterations=20，单工具结果截 20000 字符）。③`autobot agent` CLI 不走 Loop，是单次 provider.chat 拼字符串（agent.cr:119-177），docs 未记载这条分叉。④cron 经 bus.publish_inbound 复用完整 turn（gateway.cr:64-96）。⑤gateway 实为无 HTTP 面的常驻进程。

**关联/启示**：多账号 = 会话数 × N。若新平台沿用此分层，**单 fiber 串行是第一个要打破的瓶颈**：多账号下任一账号一个慢 turn 会阻塞全部账号。分层本体（事件总线 + session key 路由 + cron 复用 turn）可复用，调度模型必须重构为 per-session/per-account 并发。

### 4. autobot 1 个 Loop、N 会话串行共享；subagent 无并发上限（292254d9）｜可直接采信（源码级）

**旧结论**：①主 agent 固定 1（一个 Agent::Loop、一条 fiber）；session 无上限但共享同一 Loop，仅靠 session_key 隔离，全部消息单 fiber 排队。②SubagentManager#spawn 直接 `::spawn`（subagent.cr:83-85），**无并发上限、无 max_concurrent 配置**（grep 0 命中）；模型可一个 turn 连开多 fiber 并行打 LLM，无排队无拒绝；已提议加 max_concurrent（默认 3）但未实现。③subagent 是轻量实例：独立 ToolExecutor（MAX_ITERATIONS=15），工具只有文件/exec/web/bash（无 message/spawn/cron），不能递归、不能直连用户，看不到主会话历史。④结果回注 = 主 agent 一次新 turn（announce_result 发 CHANNEL_SYSTEM 消息带完整历史再跑 LLM）。⑤cron 不是独立 agent，同样进同一 Loop；「多 agent」只能多进程或改码 new 多个 Loop，无 OpenClaw 式 subagents.allowAgents 编排。

**关联/启示**：给「编排」提供反面教材与正面零件——反面：任务分发无上限、无 lease、无回收（与 2a397aee 坑 6「任务须 lease+过期回收」互相印证）；正面：**轻量 subagent + 受限工具集 + 结果以系统消息回注主 turn** 的模式可直接作为编排「动作节点」的执行机制。新平台编排器应内置：并发上限、任务队列、lease/超时回收、（可借鉴 OpenClaw 的）allowAgents 式声明编排。

### 5. autobot 渠道 = Telegram/Slack/WhatsApp/Zulip 四个 + CLI REPL，无 TUI/无 HTTP（3f08b7f4）｜可直接采信（源码级）

**旧结论**：交互面只有 channels/telegram.cr、slack.cr、whatsapp.cr、zulip.cr 四个 IM 渠道 + `autobot agent`（-m 单条 / 无 -m 进 stdin/stdout REPL，agent.cr:66-117，无 raw mode、不渲染 Markdown）；全仓唯一 HTTP::Server 在 cli/auth.cr:71（OAuth 回调）。

**关联/启示**：本次目标渠道（企业微信 WeCom、飞书、Email）**autobot 一个都没有**——渠道层必须全新实现，不能指望复用现有四个 channel 文件；但 `channels/<provider>.cr` 经 bus 收发的抽象模式可参考。这同时坐实：多账号能力是「从渠道层开始新建」，不是「在现有渠道上扩容」。

### 6. autobot 无现成 TUI/Web UI，OpenClaw dashboard/ClawPanel 接不上（dca44a9b）｜需一线调研复核（快照时点：TUI 实现之前）

**旧结论**：①官方与社区都没有 autobot 的 TUI/Web UI（issue/PR 连提案都没有）；②OpenClaw 有官方 web dashboard 与第三方 ClawPanel（TUI+Web，`clawpanel web --port 4231`），但写死 OpenClaw 的 CLI 与配置 schema（models.providers、agents.defaults.memorySearch.*、subagents.allowAgents），且 autobot gateway 无 HTTP 面接不上；③现实可用「Web UI」= IM 前端本身（Telegram Web 等）；④自建 extension-roadmap.md 也只规划了 generic HTTP webhook channel 与 MCP HTTP/SSE，做 Web UI 应顺着 webhook channel 升级（POST→publish_inbound，SSE→consume_outbound）。搜索易撞名：mrveiss/AutoBot-AI 等无关项目。

**关联/启示**：教训 = **没有管理面协议，任何编排面板都接不上**。新平台的「编排控制台」（看流程状态、账号状态、审批动作）必须先定通信契约（HTTP 或 IPC），这是架构级前置决策，不能后补。注意时序：本条是 TUI 落地前的调研快照，autobot 后续已用 IPC 路线补上（见第 7 条）。

### 7. autobot TUI 已实现：独立进程 + NDJSON + Channels::Ipc（713ed632）｜可直接采信（spec/冒烟已验收）

**旧结论**：按 docs/tui-plan.md 落地：`src/autobot/ipc/{protocol,transport,discovery,server,tracer,bridge,interrupts,commands}.cr` + channels/ipc.cr + src/tui/*；gateway 新增 `--ipc auto|unix:PATH|tcp:HOST:PORT|stdio`；协议 = NDJSON 一帧一行、8MiB 上限、首帧 hello、caps/版本校验；工具事件经 ToolExecutor Observer 只注入 ipc 渠道（预览 500 字符）；Ctrl-C 中断在工具迭代与 LLM 调用之间检查 InterruptFlag 返回 turn_ended{cut_off}；`--connect` 从 discovery 文件复用 token；`--spawn` 起 gateway --ipc stdio 子进程。43 examples 0 failures；Windows 真机冒烟通过（tcp:18791 握手 attach/detach、--spawn exit 0）。v1 纯文本不渲染 markdown。

**关联/启示**：证明 **「无 HTTP 也能做控制面」** 的替代路线已走通：NDJSON/IPC + 独立前端进程，且踩平了协议帧/caps 校验/discovery token/中断传播等坑。新平台编排 UI 可二选一：A) HTTP+SSE（顺 webhook 路线，与企微/飞书回调同构，见 dca44a9b）；B) NDJSON/IPC（本条已验证）。若编排面板只在本地用，B 路线可少开 HTTP 面。

### 8. Crystal TUI 生态实测（6e8b045d）｜可直接采信（GitHub API 实测）

**旧结论**：crysterm 153★ 但 AGPL-3.0（对 MIT 项目是分发硬伤）；termisu 36★、MIT、活跃、有 Windows readiness，首选；绑定层（termbox-crystal/ncurses.cr 等）大半 2018-2019 停更；chat TUI 本质是线性滚动+输入框，重型框架收益低，自写 raw mode 约 300-500 行也可行。

**关联/启示**：新平台若做编排控制台 TUI，选型直接照抄：termisu 或自写，避开 crysterm（AGPL）。注意 Crystal 零依赖/单二进制卖点与 C 库绑定互斥。

### 9. 本项目启动语境与六路调研分派（ec38665a）｜可直接采信（任务语境）

**旧结论**：硬需求两条（同渠道 N 账号；消息/事件→条件→动作编排）；六路调研进行中（Hermes/OpenClaw/Pi Durable/autobot 本地/企微飞书 Email 多账号/本清单）；设计文档「调研完毕先出整体设计与方案，等用户过目后才动后续」。

**关联/启示**：本清单所有「需复核」条目的复核出口就是同批一线调研；设计阶段闸门 = 用户过目。

## 二、特别关注 1：四形态 → 个人多账号编排的映射（类比推论，需一线对照）

原调研口径是「跨机编排」，个人平台是「单机多身份」；逐类映射：

| 四形态（2a397aee） | 个人多账号场景的映射 | 采信建议 |
| --- | --- | --- |
| 中控台型（Happier：daemon+面板） | **控制面**：每账号一个 channel worker（≈每机 daemon）+ 统一编排面板。个人机器数≈1，价值从「跨机遥控」转为「多账号多会话的统一视图/管控」 | 机制可采，动机换位 |
| 队列型（vibey-engine：SKIP LOCKED+预算+append-only 账本；K8squad：任务生命周期） | **编排引擎内核**：「事件→条件→动作」本质=队列+调度。vibey 的 lease+过期回收、预算上限、append-only 账本可缩为个人版编排器的事务性保障；K8squad 的任务生命周期可简化为本地任务状态机 | 可直接移植，最值得抄 |
| 运维型（Clawrium：密钥轮换/token 限额/upgrade/rollback） | **账号生命周期**：N 账号=N 份 token/凭据。Clawrium 的功能清单≈多账号运维需求清单（轮换、限额、健康检查、回滚） | 需求清单可直接采 |
| 云沙箱型（Codex Cloud/Devin） | 个人平台基本不采；仅「每任务独立沙箱运行时」概念可留作 subagent 隔离参考 | 不采为主 |

配套迁移：6 坑中「凭据勿复制、token 花费聚合、任务 lease+回收、YOLO 放大器」四条对多账号**逐字成立**（把「机」换「账号」）；「worktree 并发」对单机多账号弱相关。协议层「内部优先原生、跨平台才 A2A」支持新平台**先用原生事件/Crystal 模块做内部编排**，A2A 留给未来跨机扩展，不为个人 v1 引入。

## 三、特别关注 2：OpenClaw 家族对比 → 新平台补齐建议（基于 bbf5a8e0，zeroclaw 侧需复核）

autobot 未实现、OpenClaw/ZeroClaw 已有、新平台**建议补**的清单：

1. **gateway HTTP 管理 API（/health /pair /webhook）+ daemon 心跳**——补，且优先。企微/飞书接入天然走 HTTP 回调，管理面与渠道回调可共用一个带鉴权 HTTP 面；多账号的健康监控也挂在这上面。autobot 教训：`-p PORT` 只打印不监听（7731b342⑤）。
2. **子系统可替换接口（ZeroClaw 全 trait 化）**——补（Crystal 形态：module/abstract base）。多渠道×多账号×多 provider 天然要求 Channel/Provider/Memory/Runtime 可换；autobot 编译期内置插件是反面。
3. **渠道规模与先例**——飞书/钉钉/Email 在 OpenClaw 生态有接线先例（bbf5a8e0 第 4 轴），新平台可抄接线方式；但「同渠道 N 账号」两家未验证，等 hanlin-bianxiu-2 证据。
4. **记忆后端**——建议直接上 SQLite FTS5（autobot 已有 sqlite 内置插件基础；ZeroClaw 同路线 FTS5+BM25），多账号会话量下 grep 两层不可持续。
5. **安全哲学取舍**——个人部署（尤其 Windows）建议偏 ZeroClaw 应用层策略 + localhost-only gateway + OTP 配对，而非 autobot 的内核沙箱路线（Windows 无 bubblewrap；ZeroClaw 模式对个人更可移植）。
6. **TUI/Web 面板**——OpenClaw 有 dashboard、ZeroClaw 有 zerocode、autobot 已自建 NDJSON/IPC TUI（713ed632），三条路都通；选型取决于管理面走 HTTP 还是 IPC（见第 7 条二选一）。
7. **migrate openclaw 式兼容迁移、skills 装删**——低优先级，可不做；「migrate」预设了从 OpenClaw 系迁入用户，个人新平台无此存量。

另记命名坑：PyPI `zeroclaw` 无关、ClawPanel schema 写死 OpenClaw、mrveiss/AutoBot-AI 撞名——一线调研引用外部资料时须逐个验名。

## 四、给首辅的取舍提示（不改排序，仅列联系）

1. 编排内核抄队列型机制（lease/回收/预算/append-only 账本），控制面走中控台型统一面板，运维需求按 Clawrium 清单列——三形态在个人平台上各取一层，不冲突。
2. 多账号的三个架构级前置：per-session 并发模型（破 7731b342 单 fiber 串行）、channel 层全新建（3f08b7f4 无企微/飞书/Email）、管理面协议先定（dca44a9b 教训 + 713ed632 已走通 IPC 备选）。
3. subagent 机制（292254d9）可复用为编排动作节点，但必须补并发上限与任务回收，否则是放大器。
4. 本清单所有「需复核」项的出口均为同批一线调研，无需另行派工。
