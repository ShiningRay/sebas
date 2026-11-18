# 调研笔记：Pi Durable（个人 Agent 语境下的持久执行）

> 调研人：翰林院编修（hanlin-bianxiu-3）｜日期：2026-11-18｜性质：纯调研（只读），结论均附来源 URL，未实测处标「未验证」。
> 服务对象：Crystal「个人 Agent 平台」前期设计——多同类账号绑定、消息/事件编排、长期驻留下的持久执行与崩溃恢复。

## 0. 消歧结论

「Pi Durable」指 **Pi 项目（pi.dev）的 durable agent harness 包 `@earendil-works/pi-durable`**，由 Mario Zechner（badlogic，Pi coding agent 作者）与 Armin Ronacher（Flask 作者、Earendil 联合创始人）主导，2026-10-01 与 Pi 1.0 同日发布。原仓库 github.com/badlogic/pi-mono 已重定向至 github.com/earendil-works/pi，Pi Durable 位于其 `packages/durable`。任务书中的消歧线索（badlogic/pi-mono）确认无误。

其他同名/相邻候选（一段带过）：
- **pi-durable-python**（PyPI 1.4.0）：独立 Python 包，自称 "durable session + document" 框架（"A Session is the only writer: every change goes through commit"），风格酷似移植，但**与 Earendil 官方的关系未验证**，来源：<https://pypi.org/project/pi-durable-python/1.4.0/>。
- **@funtuantw/pi-agent-cf**（npm 0.1.0）：第三方把 pi-mono agent 部署到 Cloudflare Durable Objects 的封装（WebSocket 流、会话持久化、空闲清理），非 Pi Durable 本体，来源：<https://www.npmjs.com/package/@funtuantw/pi-agent-cf>。
- **nearai/ironclaw 的 pi-agent-deep-dive.md**（2026-09）：IronClaw 团队对旧版 Pi 的分析，称 "pi's loop dies with its process"——这是 **Pi Durable 发布之前**对旧 Pi 的评价，与 Pi Durable 不矛盾，反而印证了 Pi 团队补 durable 层的动机，来源：<https://github.com/nearai/ironclaw/blob/b0b999d96781516ee05e6ba961d6f3ead900da96/docs/internal/research/pi-agent-deep-dive.md>。

---

## 1. 项目定位与形态

- **定位**：Pi Durable 是与 Pi 1.0 同天发布的实验性框架（"experimental new package"），官方定位是「long-running, durable, and malleable agents that can run anywhere」的 harness。它**不取代** Pi coding agent（后者仍是单用户终端工具），而是构建任意 agentic 应用（含 coding agent、Slack bot、个人助理）的底座。来源：<https://earendil.com/posts/pi-durable/>。
- **作者与公司**：Mario Zechner + Armin Ronacher，公司 Earendil（Armin 是联合创始人）。Pi 已被 Earendil「收编」。来源：<https://earendil.com/posts/pi-durable/>、InfoQ 访谈 <https://www.sohu.com/a/1087686028_355140>。
- **语言与形态**：TypeScript（npm 包 `@earendil-works/pi-durable`，依赖 pi-ai/pi-schema/chord）。官方 FAQ 明言选 TS 是「bootstrap 最容易」，不排除未来移植（"very easy to port everything to Rust"）。来源：<https://earendil.com/posts/pi-durable/>。
- **规模**：官方文章称全部源码（不含测试）约 **15,000 行**（≈150K tokens GPT / 250K Claude，最坏情况全量喂给 agent）；其中存储后端约 3,000 行。Mario 在访谈里说「大约只有 1.2 万行」——两处口径略有出入（不同时点），量级一致。架构前后经历**八轮迭代**。来源：<https://earendil.com/posts/pi-durable/>、<https://www.sohu.com/a/1087686028_355140>。
- **部署目标**：任意 JavaScript runtime——Node、Bun、浏览器（IndexedDB 存储）、Cloudflare Durable Objects；访谈原话「可以轻松部署到 Vercel、Cloudflare Durable Objects、E2B、你的笔记本电脑、甚至我的手机上」。Mario 自述正在手机上做 PIM（Pi Mobile）做 dogfooding。来源：<https://earendil.com/posts/pi-durable/>、<https://www.sohu.com/a/1087686028_355140>。
- **生态位**：Cloudflare Agents SDK 已提供一等公民集成 `PiHarness`（2026-10-02 changelog，与 Earendil 共建），作为第一个第三方 agent harness 接入 Cloudflare Agents 平台。来源：<https://developers.cloudflare.com/changelog/post/2026-10-02-pi-harness/>、<https://developers.cloudflare.com/agents/harnesses/pi/>。
- **可理解性是显式设计目标**：全部源码规模刻意控制在「agent 自己读得懂」的量级，延续 Pi 的 minimalism/malleability 原则。来源：<https://earendil.com/posts/pi-durable/>。

## 2. Durable 执行模型：效应三明治 + 版本化文档（明确拒绝事件溯源）

**核心语义（Mario 五句话）**：Agent 在进程里启动 → 调用工具 → 进程挂了 → 重启进程 → Agent 从中断处**精确**继续；不需要人再输入「继续」，工具结果与流式输出不丢，应用状态也被持久并可恢复。来源：<https://www.sohu.com/a/1087686028_355140>。

**不采用事件溯源**。Mario 原话：「我们没有使用事件溯源，而很多其他系统采用的正是这种方式，因为事件溯源会带来很多问题。」替代方案是「**意图 → 执行效应 → 存储结果**」的**效应三明治（effect sandwich）**，按崩溃时机分三层：
1. **执行前崩溃**：效应执行前先把「我准备用这些参数执行这件事」写入存储。写完即崩 → 重启后看到一条已验证输入、尚未运行的操作 → 直接接着运行。
2. **执行中崩溃**：按效应类型恢复。可幂等的外部系统（如 GitHub Actions）在真正执行前先取 run key/ID 存下，执行时携带该 ID：若已在跑则等结果，若没跑则以该 ID 启动——幂等键扛住执行中崩溃。
3. **执行后崩溃**：拿到结果并持久保存后，三明治完成，中间的意图/进行态信息可丢弃（除非留作审计 trace）。无论进程死在哪一层，最终都收敛到「结果已存」。
不可逆/不可重复的效应（删文件、刷卡）无法天然套用，故**所有效应必须显式声明与持久系统的组合方式**（见第 4 节 replay 语义）。来源：<https://www.sohu.com/a/1087686028_355140>。

**Harness 内一切皆 Task**：模型请求、工具调用、compaction、自定义工作流，每个都是任务 = durable state machine。每个 step 先存 checkpoint 再前进；进程死后新进程打开同一存储，发现未完成任务，从**最后一个 checkpoint** 续跑。LLM 生成任务即三明治：收集上下文/参数/模型 → 存「即将调用」→ 调 LLM（效应）→ 存回答。来源：<https://earendil.com/posts/pi-durable/>、README <https://github.com/earendil-works/pi/blob/main/packages/durable/README.md>。

**journal 化的载体是两类原语**（Mario：「仅靠版本化文档和任务这两个基本原语，就能做一大堆事情」）：
- **Transcript**：会话 = 不可变 entry 追加日志（`pi.user`/`pi.assistant`/`pi.tool-result`/`pi.system`/`pi.reset` 及自定义 kind），所有变更经单一原子 commit 通道写入，「nothing is shown before its commit is stored」。
- **版本化文档（Documents）**：typed JSON 状态（待办清单、计划单、票据、沙箱句柄），与 transcript 相邻存储、在**同一原子 commit** 内变更，保证应用状态与产生它的对话记录永不失配。文档可声明与 transcript 位置的三种关联策略：`asOf`（fork 时取父会话 fork 点的旧值）、`current`（取最新值）、`initial`/fresh（取初始值）。变更以 JSON-Patch-like 操作记录（官方称对标准 JSON Patch 做了 Agent 场景优化；TS 实现靠 Proxy 记录对象写操作）。来源：<https://earendil.com/posts/pi-durable/>、<https://www.sohu.com/a/1087686028_355140>、README。

**存储后端**（可插拔 + 官方 conformance suite + benchmark）：

| 后端 | 特性 |
|---|---|
| Memory | 不持久 |
| IndexedDB | 浏览器 |
| SQLite | 单文件；WAL + `synchronous=NORMAL`：进程崩溃安全，掉电/宿主故障可丢最新一笔 |
| JSONL | append-only 目录；可选 fsync；**全历史驻内存**，官方明示长期 agent 应选 SQLite |
| Cloudflare DO SQLite | 表前缀 `pi_`，commit 即 DO storage 事务 |

单进程独占一个 storage（无跨进程锁），其他进程以 `readOnly` 只读挂载。每会话持久 UUIDv7（`pi.provider`）作为 provider 侧 prompt-cache/session affinity 标识，fork/子会话获新标识。来源：README <https://github.com/earendil-works/pi/blob/main/packages/durable/README.md>。

**内存模型**：SQLite 上只驻留 working set（活跃 transcript、live task、pending submission），其余落盘；活跃 transcript 受模型上下文窗口约束（compaction 兜底），数万条消息的会话也能 snugly 驻留。解决旧 Pi「整棵对话树进内存、跑不了多年 Slack bot」的问题。来源：<https://earendil.com/posts/pi-durable/>、<https://www.sohu.com/a/1087686028_355140>。

## 3. Agent 循环与 durable 层的结合

- **一次提交的解剖**（README 原文图示）：`submit(input) → pi.user`；`pi.generation` 任务调模型 → 产出 `pi.assistant`（含 tool calls）；每个工具调用一个 `pi.tool` 任务（被 generation 拥有并等待）→ `pi.tool-result` ×n；下一个 `pi.generation` → 最终 `pi.assistant` → submission done。即 **run = 若干 turn，turn = 一次模型响应 + 其工具调用**，每一环都是持久任务。来源：README。
- **提交先于执行**：`submit()` 在模型运行**之前**就持久化输入并返回回执（Cloudflare 侧同语义：`submit() returns once Pi has durably stored the input, before the model runs`），`wait()` 稍后取结果——长任务可跨请求/跨进程等待。来源：<https://developers.cloudflare.com/agents/harnesses/pi/>、README。
- **exactly-once 提交**：`requestId`（Cloudflare 面为 `operationId`）使提交幂等——崩溃后客户端用同一 ID 重试，拿回的是**原 submission** 而非重复提问（`accepted: false`）。官方建议用「能扛住你自己重试的 ID，如入站事件 ID」。来源：<https://earendil.com/posts/pi-durable/>、<https://developers.cloudflare.com/agents/harnesses/pi/>。
- **system prompt 的持久化**：每次请求前从会话所选 extension 的 sections 重建 system prompt；变更被记录在 **transcript 的对应位置**，重启或 fork 后模型看到的与当时一致；支持 mid-conversation 只发送变更部分以保持 provider prompt cache 命中。来源：<https://earendil.com/posts/pi-durable/>。
- **compaction 也是任务**：接近上下文上限时后台压缩，summary 落在下一个 turn 边界；仅当下一请求放不下才等待压缩；provider 仍拒则压缩后重试一次；老消息**永远留在存储**不删。参数：`reserveTokens`（如 16384，越过即下一请求等 summary）、`backgroundTokens`（如 32768，此前启动后台压缩）。另有 `reset(handoff note)`：带着交接笔记开新上下文，历史仍可搜索——官方示范配 `search_history` 工具即「自我交接 + 事后检索」的无限长会话模式。来源：<https://earendil.com/posts/pi-durable/>、README。
- **睡眠与唤醒**：任务等待靠「结束当前 phase 进 sleeping」而非进程内 sleep——睡眠存入存储，重启后到点续跑；宿主（如 Cloudflare DO）通过 `onWake`/`harness.wake()` 自行维护 alarm，对象可在任务睡眠期间 hibernate。Signals 机制让任务挂在类型化键上等外部输入（webhook 回执、人工答复），不占进程。来源：README、<https://developers.cloudflare.com/agents/harnesses/pi/>。
- **多会话/fork**：一个 harness 并发跑任意多 conversation；conversation 可在 transcript 任意点 fork（Slack 频道=主会话、thread=fork 的官方示例），fork 见父历史但不复制，二者并行互不阻塞。来源：<https://earendil.com/posts/pi-durable/>。
- **subagent 即被拥有的会话**：工具在 commit 内创建 `ownership: {kind:"task"}` 的子会话，崩溃重跑时经 `scanConversations({ownerTaskId})` 找回**同一个**子会话与同一 submission 等答案——subagent 无需内建，几行代码即成，且享受全部持久保证。来源：<https://earendil.com/posts/pi-durable/>、README。

## 4. 工具调用的幂等与重试语义

- **二分法 `replay` 标注**：工具定义显式声明 `replay: "safe"`（重跑无害，如只读、整文件写入）→ 崩溃后自动重跑；**未标注则一律不重跑**——模型收到「interrupted」结果与已存的部分输出，自行决策（如 deploy、edit 这类会因已替换文本而失败或有副作用的调用）。官方准则：「running it twice is harmless」才标 safe。来源：<https://earendil.com/posts/pi-durable/>、<https://developers.cloudflare.com/agents/harnesses/pi/>。
- **幂等键模式**：官方支付示例以 `payment-${task.id}` 作为银行扣款幂等键，「if a crash reruns this phase, the card is only charged once」；访谈中 GitHub Actions 例子：调度前先存 run ID。**幂等键 + 意图先行**是执行中崩溃的标准解。来源：<https://earendil.com/posts/pi-durable/>、<https://www.sohu.com/a/1087686028_355140>。
- **工具意图先存**：「every tool call runs as its own durable task, and its intent is stored before it runs」——对应三明治第一层。来源：<https://earendil.com/posts/pi-durable/>。
- **memo（first-write-wins）**：hook/工具做的**决策**存为 memo 小值与任务同存，崩溃重跑读到已存答案即不再重复决策。官方 approval hook 示例：崩溃后「finds the stored answer instead of asking again」。来源：<https://earendil.com/posts/pi-durable/>。
- **模型请求重试**：默认重试 3 次（`settings.retry.maxRetries`，可配 baseDelayMs）；被进程死亡切断的流式请求**算一次 failed attempt**，已流出的部分以 aborted entry 留在 transcript；按 backoff 重试，重试用尽则 run 以 `interrupted` 未答复结束。来源：<https://developers.cloudflare.com/agents/harnesses/pi/>、README。
- **崩溃循环防护 `restartLimit`（默认 5）**：确定性崩溃（如内存耗尽）会令 resume-再崩循环永动；连续被打断 5 次的任务**终止而非再跑**——工具调用以 error result（`restart_limit`）呈给模型继续 run；模型请求则结束 run。每次任务 commit 新状态即重置计数。报告经 `onReport` 上报（`task_interrupted` 等）。来源：README、<https://developers.cloudflare.com/agents/harnesses/pi/>。
- **失败 run 后的排队输入**：`settings.afterFailedRun` 三选：`keep`（默认，排队等待下一输入触发）/`continue`（下一 run 直接带上它们）/`withdraw`（全部结算为 unanswered）。来源：<https://developers.cloudflare.com/agents/harnesses/pi/>。
- **流式输出的持久化粒度**：流式回答与工具输出按批次持久（`persistWithinMs` 默认 1000ms），崩溃最多丢最近 1 秒流；设 0 则每笔即写（每笔一次存储写）。来源：<https://developers.cloudflare.com/agents/harnesses/pi/>。

## 5. 崩溃恢复的实证

- **官方 demo（vacation planner，约 1,300 行 TS）**：官方文章逐步描述崩溃场景——「The process dies. Weather and museums are done, trains is not. → Restarted. `search` is safe to rerun: only trains runs again.」即三个并行搜索子任务中，已完成两个不重跑、只重跑未完的那个；重启后可继续 steer 子代理。运行方式见文章（`node packages/coding-agent/src/experimental/{durable,vacation}/main.ts`）。来源：<https://earendil.com/posts/pi-durable/>。**未验证**：本调研未实际运行该 demo。
- **代码内建恢复演练**：`packages/durable/test/examples` 共 48 个可运行示例，其中 `12-recovery`、`23-child-tasks`（明确标注「a restart while the payments run」）、`22-subagent-background`（标注 restart-safe）、`30-reload-and-restart`（stored choices surviving a restart）、`40-tool-waits-for-webhook`（「a crash before the park (idempotency memo)」）均直接演练崩溃-恢复路径。来源：README <https://github.com/earendil-works/pi/blob/main/packages/durable/README.md>。**未验证**：未实际执行。
- **规范与测试基建**：`packages/durable/docs/spec.md` 为规范性规格；存储后端有 conformance suite（`registerStorageConformance`，Vitest/Jest 兼容）与四类 benchmark（storage、memory storage、tool output、nested tools）。来源：README。
- **生产级集成证据**：Cloudflare Agents SDK 官方 changelog（2026-10-02）+ 文档（2026-11-03 更新）给出逐场景恢复矩阵：对象驱逐/崩溃/超限 → alarm 重启 → 从 checkpoint 继续；**部署发生在 run 中间等同崩溃**（运行时给 30 秒排空，之后 alarm 重启续跑）；streaming 请求按重试语义处理。来源：<https://developers.cloudflare.com/agents/harnesses/pi/>、<https://developers.cloudflare.com/changelog/post/2026-10-02-pi-harness/>。完整可部署示例：<https://github.com/cloudflare/agents/tree/main/examples/next/harnesses/pi>（未验证：未部署）。
- **作者口述实证**：Mario 以 PIM（Pi Mobile）dogfooding 验证「Pi Durable 真的能用」，场景为手机端大脑 + 远程 Hetzner 执行环境。访谈原始视频（未验证，未观看）：<https://www.youtube.com/watch?v=ja_7AF54OtE>；中文编译：<https://www.sohu.com/a/1087686028_355140>、<https://www.infoq.cn/article/hQOHf1ZXoBs7uMpWJQss>。
- **已知限制（官方自认，属恢复语义边界）**：尚无工具调用 approval/permission 步骤；`abort()` 需等会话 idle，无视 abort signal 的工具会占住会话；Cloudflare alarm 单次上限 15 分钟（harness 每 10 分钟交接，>15 分钟的单次模型流可能被切）；background 任务完成感知最多延迟 30 秒；**会话尚不能删除**；minor 版本间存储格式可能不兼容（升级不可回滚，需前滚修复）。来源：<https://developers.cloudflare.com/agents/harnesses/pi/>。

## 6. Durable 机制对个人 Agent 的意义

- **长期驻留是第一动因**：旧 Pi「整棵对话树驻内存」撑不起「跑了很多年的 Slack bot」；Pi Durable 的 SQLite working-set + compaction 兜底使无限长会话成为可能——这正是个人 Agent 的常态（7×24 在线、账号会话累积数年）。来源：<https://www.sohu.com/a/1087686028_355140>。
- **多账号消息流 = 多 conversation 并发 + fork**：每个账号/频道/线程一个 conversation，同一 harness 并发驱动；Slack channel/thread 的 fork 语义直接映射「多个 email 账号、多个企微、多个 Lark 账号」的会话拓扑；multiplayer watch/steer 让同一 agent 可被多个客户端（手机、桌面、web）同时观察与插话。来源：<https://earendil.com/posts/pi-durable/>。
- **编排流程 = 任务状态机**：phases + checkpoint + 等待策略（`failFast`/`allSettled`/`any`）+ ownership tree（abort 自底向上传播，任务先清理自己的副作用）+ signals（等 webhook/人工答复不占进程）+ sleepUntil（明日提醒类）。官方支付拆分示例即完整编排范式：并行扣款、一卡失败全链退款。来源：<https://earendil.com/posts/pi-durable/>、README。
- **外部消息源天然需要幂等提交**：`requestId`/`operationId` 官方建议直接用「inbound event id」——对邮件/webhook/IM 重投递场景是标准解；Signals 的 `duplicate` 结果显式服务 webhook 重试。来源：<https://developers.cloudflare.com/agents/harnesses/pi/>、README。
- **输入来源标注**：非用户键入的输入（定时任务、webhook、审批回执）以自定义 entry kind 记录（`app.approval`），UI 可区分呈现——多账号自动化场景的审计基础。来源：<https://developers.cloudflare.com/agents/harnesses/pi/>。
- **成本与缓存**：每会话持久 provider session ID + system prompt 只发 diff → prompt cache 友好；`pi.usage` 文档逐 provider/model、逐工具记账（失败/中断也计）——个人 Agent 长期运行的 token 账本内建。来源：README、<https://earendil.com/posts/pi-durable/>。
- **作者自身的个人 Agent 实践即用例证明**：PIM 手机端大脑 + 远程执行环境跨机协作；访谈中 0xSero 描述的「本地 DeepSeek 扫 15 个邮箱整理进 Linear」正是多账号个人 Agent 原型；Earendil 早先产品 Lefos 即「纯文本通信界面后的个人 Agent」（邮件）。来源：<https://www.sohu.com/a/1087686028_355140>。
- **Armin 的可靠性论点**（对个人 Agent 的安全侧注脚）：「模型已够不可预测，外层编排至少应该稳定、可理解」；两人对「数百万人把所有账号登录到 Grok Bot 类产品」持灾难论——个人 Agent 自托管 + 可审计编排是 Pi Durable 路线的隐性卖点。来源：<https://www.sohu.com/a/1087686028_355140>。

## 7. 对 Crystal 平台的借鉴（含设计推论，非 Pi 事实）

以下前半为 Pi Durable 已验证机制的映射，后半为**本阁基于调研的设计推论**（均标注）。

**机制层（Pi 已验证，可直接映射）**：
1. **选 checkpoint 任务状态机，不选事件溯源**。Pi 团队明确拒绝 event sourcing（重放语义复杂、与不可逆副作用难组合），采用「意图先行 → 执行 → 结果落库，中间态可弃」的三明治。映射到 Crystal：把「LLM 调用、工具调用、编排节点」统一抽象为 Task（fiber 驱动 + 状态机 phase + 每 phase 尾 commit checkpoint），重放单位是 **phase** 而非事件流。Pi 的 phase 语义「重跑从 phase 顶部开始，等待后的工作放下一 phase、所需数据放 checkpoint」是可直接照抄的纪律。
2. **Transcript = 不可变 entry 追加 + 单一原子 commit 通道**。Crystal + SQLite 事务天然满足；「commit 未落库前不对外可见」的顺序纪律是正确性核心。
3. **应用状态与对话同事务提交**（Documents）：待办、计划、流程实例状态放 typed JSON 文档，与产生它的 entry 同 commit 写入；fork 三策略（asOf/current/initial）语义完备，值得整体移植。
4. **存储选型**：默认 SQLite（WAL + `synchronous=NORMAL`：进程崩溃安全、掉电可失最新一笔——个人 Agent 可接受的默认）；JSONL append-only 仅适合审计/回放，全历史驻内存不适合长驻；手机/边缘场景可用嵌入式 SQLite。Pi 的 conformance suite 思路（存储后端可插拔 + 一致性套件）值得为 Crystal 平台复刻，便于未来支持 Postgres/云 KV。
5. **幂等三件套**：提交级 `requestId` exactly-once（入站消息 ID 即键）；工具级 `replay: safe` 显式二分（默认不安全、不重跑）；决策级 memo（first-write-wins）。发消息类工具（email/企微/Lark 发送）**必须**设计幂等键（类比 `payment-${task.id}`：如 `send:${channel}:${msgId}`），否则崩溃恢复会重复发信——多账号平台的关键风险点。
6. **崩溃循环防护**：restartLimit（默认 5）+ 新 checkpoint 重置计数 + onReport 上报，防确定性崩溃雪崩；个人 Agent 无人值守时此防线必需。
7. **流式持久化粒度**（默认 1000ms 批落库，可调 0）与**prompt cache 友好性**（持久会话 ID + prompt 变更只发 diff）均应纳入 Crystal 平台的默认配置考量。

**设计推论层（本阁建议，未实测）**：
8. **Crystal 没有 JS Proxy**：Pi 的「对象写操作自动记录为 patch」在 Crystal 不可复制，需显式化——两种路线：(a) 文档操作 DSL/宏（`doc.update { |d| d.items << item }`，宏在编译期生成 patch 记录）；(b) 直接以 op-list 为源（文档即操作序列的物化视图）。Crystal 宏系统足以支撑 (a)。
9. **单进程单 owner + 多客户端挂载** 与 autobot 现有「单进程事件总线、Agent::Loop 单 fiber」架构兼容：Pi Durable 证明 harness 层可在单进程内用任务树并发驱动多会话（fiber 调度），无需 OS 级多进程；Crystal fiber + Channel 语义比 JS 事件循环更贴合其 scheduler（sleep/等待不占执行线程）。
10. **「效应可组合性」应是平台工具契约的一部分**：要求每个内置/第三方工具声明 replay 语义与幂等键方案，把 Pi 的 `replay: "safe" | unsafe` 升级为工具注册的类型级字段——这正是多账号消息流（副作用密集）与 coding 工具（可幂等重跑）的语义分界线。
11. **内存策略**：SQLite working-set 模型（活跃 transcript + live task + inbox 驻内存，其余落盘）配合 compaction，可直接支撑「数年消息史的个人 Agent」；平台设计时将会话内存上界锚定到「上下文窗口 + 固定余量」而非消息数。
12. **验收建议**：参照 Pi 的 `test/examples` 12/22/23/30 号恢复演练，为 Crystal 平台建立「运行中 kill -9 → 重启续跑」的自动化验收用例，作为 durable 层的门禁。

---

## 来源 URL 清单

1. Pi Durable 官方发布公告（Earendil，2026-10-01）：<https://earendil.com/posts/pi-durable/>
2. pi-durable 包 README（API 与语义的一手文档）：<https://github.com/earendil-works/pi/blob/main/packages/durable/README.md>
3. Cloudflare Agents 文档 · Pi harness（2026-11-03 更新，恢复矩阵/限制）：<https://developers.cloudflare.com/agents/harnesses/pi/>
4. Cloudflare changelog · Pi Durable harness on Agents SDK（2026-10-02）：<https://developers.cloudflare.com/changelog/post/2026-10-02-pi-harness/>
5. GitHub 仓库（badlogic/pi-mono → earendil-works/pi）：<https://github.com/earendil-works/pi>
6. InfoQ 编译 0xSero 访谈全文（Mario Zechner & Armin Ronacher，效应三明治/架构迭代/个人 Agent）：<https://www.sohu.com/a/1087686028_355140>；InfoQ 原页：<https://www.infoq.cn/article/hQOHf1ZXoBs7uMpWJQss>；原视频：<https://www.youtube.com/watch?v=ja_7AF54OtE>
7. Pi 1.0 公告（同日发布背景）：<https://earendil.com/posts/pi-1-0/>
8. Cloudflare Pi harness 完整示例应用：<https://github.com/cloudflare/agents/tree/main/examples/next/harnesses/pi>
9. pi-durable 规范文档：<https://github.com/earendil-works/pi/blob/main/packages/durable/docs/spec.md>
10. 旁证：IronClaw 对旧版 Pi 的 deep dive（2026-09，Pi Durable 前）：<https://github.com/nearai/ironclaw/blob/b0b999d96781516ee05e6ba961d6f3ead900da96/docs/internal/research/pi-agent-deep-dive.md>
11. 消歧旁证（第三方）：pi-durable-python <https://pypi.org/project/pi-durable-python/1.4.0/>；@funtuantw/pi-agent-cf <https://www.npmjs.com/package/@funtuantw/pi-agent-cf>
12. 旧仓库快照数据（badlogic/pi-mono，2026-01，2192 stars）：<https://github.com/DavidWells/stars/blob/master/stars/badlogic/pi-mono.md>

## 未验证清单

- 本调研**未运行**任何 Pi Durable 代码、测试、demo 或 conformance suite——所有「实证」均来自官方文档、README、示例代码注释与访谈转述。
- vacation planner 演示视频与访谈原始视频（YouTube）未观看，仅采信文字转录。
- earendil-works/pi 当前 star 数、贡献者规模未核实（DavidWells/stars 的 2192 stars 为 2026-01 时点快照，且是迁移前的 badlogic/pi-mono）。
- pi-durable-python 与 Earendil 官方的关系未验证（风格酷似移植，但归属不明）。
- badlogic/pi-mono → earendil-works/pi 迁移的确切时间与组织背景仅由重定向与文章署名推断。
- Pi 1.5 与 Cloudflare Agents SDK 版本绑定的存储格式兼容细节仅见文档警告（minor 不兼容、不可回滚），未实测。
- Mario「约 1.2 万行」与官方文章「约 15,000 行」的口径差异未溯源（取量级 ~1.2–1.5 万行不含测试）。
- Focus 7 第 8–12 条为设计推论，未做任何 Crystal 原型验证。
