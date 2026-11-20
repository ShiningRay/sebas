# Seneschal开发计划（WBS · 排期 · 门禁 · 首迭代）

> 文档职责：回答「怎么建」——M0-M7 工作包分解（WBS）、依赖与排期、里程碑门禁、首迭代逐任务执行清单、覆盖自查与前置风险。M5–M7（承诺与日历）于 2026-11-20 按 [proposals/commitments-calendar-integration.md](proposals/commitments-calendar-integration.md) 追加，见 A 节 M5/M6/M7 与 B.9。  
> 不负责什么：「是什么与怎么设计」见 [design.md](design.md)（850 行 16 章，已定稿）；本文件不重复设计论证，所有模块语义、机制选型、来源依据以 design.md 为准。  
> 与 design.md 的关系：本文 `M*-WP*` 工作包编号引用 design.md §13 目录结构与 §14 路线图验收条目；若实现中范围变化，须回写 design.md 对应章节。格式惯例沿用 Tessell 仓库已验收的 [plan.md](../../../tessell/docs/plan.md)（B 节 WBS）与 [plan-execution.md](../../../tessell/docs/plan-execution.md)（D 节执行分块）。

---

## 0. 输入与证据基线

| 输入 | 路径 | 关键事实 | 来源 |
|---|---|---|---|
| 设计主体 | [design.md](design.md) | 16 章：三正交概念/分层架构/多账号/编排/协作/管理面/安全/热更新(§11)/插件(§12：子进程+包生命周期)/目录结构(§13)/M0-M3 路线图(§14)/风险(§15)/来源对照表 41 条(§16)+附录 | [来源: design.md §1~§16] |
| 目录结构基线 | design.md §13 | src/{platform,config,bus,supervisor,store,keys}/+channels/routing/agents/orchestration/tools/providers/admin/plugins/ 模块划分与 A1-A10 承接表 | [来源: design.md §13] |
| 里程碑验收 | design.md §14 | M0-M3 各期验收要点+排期依据（热更新 M1、插件 M3） | [来源: design.md §14] |
| 风险与未验证 | design.md §15 | 未验证 13 条（15.1）/架构风险 7 条（15.2）/取舍 3 条（15.3）；mrb.cr 甄别与 Windows 构建 blocker 已更新 | [来源: design.md §15] |
| 质量门禁惯例 | 仓库 CLAUDE.md | `crystal spec` 全过 / `./bin/ameba` 无警告 / `make release` 成功 / 改动须同步 docs | [来源: 仓库:CLAUDE.md 质量标准节] |
| 格式范本 | tessell/docs/plan.md、plan-execution.md | `M*-WP*` 编号、pd 区间估算、相对周、EX-W1-01 执行分块、DoD 分层、状态与证据边界纪律 | [来源: 任务输入] |
| 平台命名 | design.md 附录 1 | **已定名 Seneschal**（[naming.md](naming.md) 14 候选撞名全核实；用户保留推翻权，推翻则全文再替换） | [来源: design.md:L846] |
| 承诺与日历提案（M5–M7 输入） | [proposals/commitments-calendar-integration.md](proposals/commitments-calendar-integration.md) | 338 行：§1 核心判断（Calendar=持久意图与时间上下文层）/§2 七原则/§3 九态与提醒纪律/Today 六段/§4 十对象与四类时间表示/§5 cron 退到唤醒层/§6 三种接入深度与失败四态/§7 canonical superset + CalDAV·Google·Graph adapter/§8 非目标/§9 首闭环保留与必须验证边界 | [来源: 仓库:docs/design/proposals/commitments-calendar-integration.md；PR #61 合入 main] |

**估算口径**：单人全职（每周 5 人日），工作量单位 **人日（pd）区间**；时间只用相对周 `W1/W2…`，禁止绝对日期；估算为「熟悉 Crystal 语言与 autobot 既有代码模式、渠道文档齐备且账号申请就绪」前提下的工程量，不确定性显式保留 `[未验证]`；禁止编造任何数字。各包估时含单测与门禁自检，不含渠道账号行政审批等待（外部依赖见 E 节）。

**证据标注纪律**：`[来源: design.md:Lx]` / `[来源: design.md §x]` / `[来源: 仓库:路径:行]` / `[来源: 任务输入]` / `[推演]` / `[未验证]`。引用 design.md 时其来源限定（「未验证/笔记推论/证据局限」）照抄不升级；本文新增的排期判断一律标 `[推演]`。

---

## A. WBS（M0-M7 工作包分解）

> 拆包依据：design.md §13 模块归属 + §14 各期验收条目（**§14 每条验收必须落进至少一个 WP 的验收标准**，映射关系逐条标注）。每包字段：目标/范围/交付物/依赖/验收（可测）/估时/风险。

### M0 · MVP（单账号闭环）——估时合计 17–25 pd

**M0-WP1 项目骨架与构建基线**（1–2 pd）
- 目标：可构建、可测试、可交付的单二进制骨架。
- 范围：shard.yml、src/ 目录骨架（§13 布局空实现）、Makefile/构建脚本、Log.for 统一日志、空 spec。
- 交付物：`crystal spec`/`./bin/ameba`/`make release` 三命令全绿的可编译骨架。
- 依赖：无。
- 验收：三命令零失败零警告；单二进制可执行 `--version`。
- 风险：无实质风险。

**M0-WP2 配置加载与 schema**（1.5–2.5 pd）
- 目标：单账号配置树加载链，为 M1 数组化预留。
- 范围：`config/` loader（读盘→expand_env→YAML→validate! 失败即拒启，复用 autobot `loader.cr:152-166` 现链思想 [来源: design.md:L690]）、宏生成账号样板（autobot `config/schema.cr:506-517` 先例 [来源: autobot 笔记 §9 schema.cr:506-517；design.md §4.2]）、凭据引用占位（明文过渡，M1-WP7 迁 keyring）。
- 交付物：`src/config/` 模块+配置示例 YAML+校验 spec。
- 依赖：M0-WP1。
- 验收：坏 YAML 启动报错含行号；缺必填项报错可读；合法配置解析出 typed Config 对象。
- 风险：schema 校验粒度过粗导致 M1 热更新校验返工——校验器写成独立纯函数便于 M1-WP8 复用。

**M0-WP3 持久层（效应三明治）**（3–4 pd）
- 目标：SQLite(WAL) 主存储+幂等三件套落库。
- 范围：`store/` 模块：intents/tasks/transcripts/memos 四表；requestId 幂等表（入站事件 ID 为键）；Session JSONL 双写【A4 升级）；FTS5 记忆检索表 [来源: design.md §6]；restartLimit 崩溃循环防护字段 [来源: design.md §16#18]。
- 交付物：`src/store/` + 全套 spec（三明治落库次序、requestId 排重、memo first-write-wins）。
- 依赖：M0-WP1。
- 验收：spec 覆盖「意图先落库→效应→结果落库」次序断言；同 requestId 二次投递不产生第二行；强杀点重放恢复到最近 checkpoint。
- 风险：SQLite WAL 在 Windows 行为未实测（Pi 先例 POSIX 侧证）[未验证]——M0-WP8 恢复演练一并验证。

**M0-WP4 渠道骨架 + email 账号**（3–4 pd）
- 目标：abstract ChannelAdapter + 第一个真实账号收发。
- 范围：`src/channels/base.cr`（account 维度接口）；email 适配器：IMAP IDLE（应用专用密码起步——Gmail 路线待用户决策，附录 3 [来源: design.md:L848]）；markdown 转换器【A8 直接搬】；TokenProvider 骨架（email 无 token 流，接口占位）。
- 交付物：`src/channels/email/` + 收信入总线 spec。
- 依赖：M0-WP2（配置树）。
- 验收：真实邮箱收信触发事件入总线（集成测试）；发信出站投递成功。
- 风险：Gmail IMAP IDLE 不可靠为社区长期报告 [来源: design.md §15.1.2]——若用户 Gmail 为首账号，M0 验收以「至少收到一封触发」为界，稳定性问题记录不阻塞门禁；选 Gmail API 路线则本包 +2–3 pd。

**M0-WP5 事件总线 + agent worker 池**（3–4 pd）
- 目标：去全局单 Loop，per-session worker 池成立。
- 范围：`bus/` 有界 Channel【A3 加账号维度路由】；`agents/pool.cr` worker 池（并发上限、会话分片队列）；会话键含账号维度从 day one（B4 教训 [来源: design.md §16#13]）；agent-loop 单 turn 结构（每 turn 取配置快照纪律 [来源: design.md §11.2④]）；**`providers/` 实例池骨架**【A1/A2：单实例→实例池改造起点，M1-WP8 的 provider key 热换以此为宿主】[来源: design.md:L719]。
- 交付物：`src/bus/` + `src/agents/pool.cr` + `src/providers/` 骨架 + 并发 spec。
- 依赖：M0-WP2、M0-WP3。
- 验收：**两并发会话互不阻塞**（一 turn sleep 10s，另一会话正常完成——autobot `cli/gateway.cr:76` 单 Loop 教训的反向断言 [来源: design.md §16#24]）；队列满时 send 阻塞（背压）可观测。
- 风险：Crystal fiber 调度在 Windows 的行为差异未实测 [未验证]。

**M0-WP6 基础工具集**（2–3 pd）
- 目标：MVP 工具面：发消息/读邮件/记忆读写。
- 范围：`tools/registry.cr`【A9 升级：replay/risk 类型级字段、脱敏】+ executor【A6】；**发消息工具必带幂等键**（§14 M0 验收 [来源: design.md:L749]）。
- 交付物：`src/tools/` + 工具 spec。
- 依赖：M0-WP5。
- 验收：**发信幂等键生效——崩溃恢复重放场景下重复投递不重发**（§14 M0 验收第 3 条 [来源: design.md:L749]）。
- 风险：无实质风险。

**M0-WP6b SKILL.md 加载器**（0.5–1 pd）
- 目标：A7 升格为主要扩展通道的首块代码落地——design.md §14 排期依据明言「M0-M2 的扩展需求由 SKILL.md（A7）承接」[来源: design.md:L754]，本包即该承接的归属。
- 范围：`agents/skills/` 加载器（skills 目录发现+SKILL.md 解析+agent system prompt 注入）【A7】[来源: design.md:L708；design.md:L738 承接表]。
- 交付物：skills 模块+加载与注入 spec。
- 依赖：M0-WP5。
- 验收：任一 SKILL.md 的指令注入进 agent system prompt；坏 SKILL.md 不崩进程（错误转值）。
- 风险：无实质风险。

**M0-WP7 NDJSON TUI 最小面**（2–3 pd）
- 目标：autobot 713ed632 已验证的 IPC 模式复活。
- 范围：`admin/ipc/`（hello/caps/8MiB 帧）+ TUI 会话查看/最小审批问答；TUI 选型 spike（termisu vs 自写，避开 AGPL crysterm [来源: design.md §16#33]）0.5 pd 内定案。
- 交付物：`src/admin/ipc/` + TUI attach 可用。
- 依赖：M0-WP5。
- 验收：TUI attach 后实时观察会话流；最小审批交互（risk:high 工具触发问答）走通。
- 风险：termisu 36★ 活跃度存疑 [未验证]——spike 不达预期则自写最小 TUI（估时内含）。

**M0-WP8 M0 门禁演练**（1–1.5 pd）
- 目标：M-gate 证据闭环。
- 范围：强杀恢复自动化用例（POSIX kill -9 / Windows taskkill /F 后重启续跑，对照 Pi 恢复演练 [来源: design.md:L749]）；全链路端到端用例（收→agent turn→发回复）；门禁三命令+docs 同步自检。
- 交付物：`spec/` 恢复演练 spec + M0 门禁证据清单。
- 依赖：M0-WP3~WP7 全部（含 WP6b）。
- 验收：**§14 M0 三条验收全过**：收发全链路 / 强杀续跑 / 发信幂等 [来源: design.md:L749]。
- 风险：WAL 恢复在断电场景不可模拟——只验进程级强杀（Pi 同口径：掉电可丢最新一笔）[来源: Pi 笔记 §2 WAL+synchronous=NORMAL 口径]。

### M1 · 多账号完备 + 配置热更新——估时合计 19.5–30 pd

**M1-WP1 账号数组 + binding 路由**（2–3 pd）
- 目标：`channels.<type>.accounts[]` 数组化+most-specific 路由成立。
- 范围：`config/` schema 数组化（宏样板升级）；`routing/binding.cr` 纯函数路由表（exact peer>…>fallback 层级 [来源: design.md:L89-92]）；无匹配即丢弃（fail-closed [来源: design.md §16#3]）。
- 交付物：路由模块+路由决策表 spec（层级每级至少一用例）。
- 依赖：M0-WP8（M0 门禁通过）。
- 验收：**同渠道 N 账号并存互不串扰——两企微测试账号同 chat_id 各归各会话**（§14 M1 验收第 1 条 [来源: design.md:L750]）。
- 风险：路由纯函数化后快照替换与热更新交叠，须先做 WP1 再动 WP8。

**M1-WP2 账号监督体**（1.5–2.5 pd）
- 目标：fiber-per-account 生命周期监督。
- 范围：`supervisor/` 监督 fiber、断线指数退避（autobot 无限重连惯用法 5s→60s [来源: autobot 笔记 §9 无限重连惯用法 slack.cr:41-64]）、健康上报入 TUI。
- 交付物：监督器+断线注入 spec。
- 依赖：M1-WP1。
- 验收：杀掉渠道连接后监督体按退避序列重连；账号下线状态在 TUI 可见。
- 风险：无实质风险。

**M1-WP3 TokenProvider 全量实现**（2–3 pd）
- 目标：三渠道统一 token 生命周期。
- 范围：`channels/common/token_provider.cr`：缓存+提前刷新+失效重取 [来源: design.md §16#8]；企微有效期内重复获取返回相同 token 的缓存语义；换 secret 保守做法=失效标记+TTL 自然过期（≤2h）[来源: design.md §15.1.9]。
- 交付物：TokenProvider+注入式 spec。
- 依赖：M1-WP1。
- 验收：**token 提前刷新与失效重取**（注入 401 后自动重取并重放请求一次）（§14 M1 验收第 3 条 [来源: design.md:L750]）。
- 风险：企微「提前失效」行为未验证 [来源: design.md §15.1.9]——保守做法不依赖未验证行为。

**M1-WP4 企微渠道**（3–5 pd）
- 目标：AIBot 长连接主路+自建回调备选。
- 范围：`channels/wecom/`：aibot_longconn（免公网主路）、crypto.cr 自实现 AES-256-CBC+SHA1（**对照官方测试向量对称测试**——15.1.6 前置 [来源: design.md:L769]）、app_callback 备选（receiveid 校验防跨企业混串+msgid 排重+5 秒响应）。
- 交付物：企微适配器+加解密向量 spec+双账号集成测试。
- 依赖：M1-WP3（token）；外部：企微测试企业+应用创建就绪（E 节）。
- 验收：**receiveid 校验**——构造跨企业密文被拒（§14 M1 验收第 2 条 [来源: design.md:L750]）；双账号同 chat_id 收发路由正确。
- 风险：**企微智能机器人主动发消息 API 未逐页核对**（15.1.1 [来源: design.md:L764]）——WP 开工首日 0.5–1 pd 逐页核对+10 行 demo；若 API 形态与笔记不符，回调备选升级为主路（估时内含回调完整实现，不扩期）。

**M1-WP5 飞书渠道**（2–3 pd）
- 目标：WS 长连接（自建应用）。
- 范围：`channels/lark/ws_longconn.cr`：事件 id 排重、3 秒处理、≤50 连接限制内单连接；**base_url 入账号配置**（飞书/Lark 账号体系独立 [来源: design.md §16#11]）。
- 交付物：飞书适配器+排重 spec。
- 依赖：M1-WP3；外部：飞书自建应用就绪。
- 验收：两飞书账号（或一飞书一 Lark 不同 base_url）事件各自入会话不串扰；重复事件 id 不二投。
- 风险：token Header 4KB 上限（15.2.19 [来源: design.md:L785]）——HTTP 客户端配置显式放宽并记录。

**M1-WP6 限流桶**（1–1.5 pd）
- 目标：(账号,目标) 维度建桶退避。
- 范围：`channels/common/` 限流桶：企微同成员 30/分、飞书同群 5/秒 [来源: design.md §5]。
- 交付物：桶+spec。
- 依赖：M1-WP4、M1-WP5（真实额度参数）。
- 验收：**限流桶触发退避**（模拟 429/频控响应后自动退避排队）（§14 M1 验收第 4 条 [来源: design.md:L750]）。
- 风险：无实质风险。

**M1-WP7 凭据 keyring**（1.5–2.5 pd）
- 目标：凭据出明文。
- 范围：`keys/` 模块：OS keyring 或静态加密（(渠道类型,账号ID) 命名空间隔离 [来源: design.md §16#26]）+ 从 M0 明文 YAML 的迁移导入命令+脱敏日志。
- 交付物：keys 模块+迁移工具。
- 依赖：M1-WP1。
- 验收：配置树中无明文凭据；迁移命令幂等可重跑；日志 grep 不到 secret。
- 风险：Windows Credential Manager API 在 Crystal 的绑定需 FFI spike（0.5 pd 含估时内）[未验证]。

**M1-WP8 配置热更新四正交件**（4–6 pd）
- 目标：免重启改配置（用户硬需求③）。
- 范围：`config/reload` 管线：触发三通道（file_watcher 主路+mtime 1–5s 轮询兜底+IPC/HTTP reload 命令；**另含 POSIX SIGHUP 第三便利通道** [来源: design.md §11.2①]，Windows 无对应信号，该平台走 IPC/HTTP）；先验后换（复用 M0-WP2 校验器）；`Atomic(Config)` 整根替换 [来源: design.md §11.2]；组件重应用矩阵（路由/编排/allowlist/限流/provider key/凭据热换；账号增删=监督体启停+drain；端口类标 restart）[来源: design.md §11.3]；每 turn 快照纪律 lint。
- 交付物：reload 管线+矩阵各组件重应用 spec。
- 依赖：M1-WP1、M1-WP2、M1-WP7（凭据热换）；**前置冒烟须于本包开工前完成**（EX-W1-03 已排 W1：Atomic 编译冒烟+file_watcher Windows demo，E.2 节）。
- 验收：**§14 M1 热更新四条全过**：运行中加/删账号、改路由、换 provider key 不重启生效 / 配置写坏（YAML 错+binding 悬空引用）保旧运行并报警 / 改监听端口得到「需重启」明确提示 [来源: design.md:L750]。
- 风险：`Atomic#swap` 详注歧义 [来源: design.md §15.1.8]——冒烟前置消除；企微换 secret 旧 token 失效行为未验证，采保守 TTL 路线不阻塞 [来源: design.md §15.1.9]。

**M1-WP9 HTTP 管理面**（2.5–3.5 pd）
- 目标：带鉴权 HTTP API+回调共享监听。
- 范围：`admin/http/`：与企微/飞书回调共用监听器 [来源: design.md §16#25]、账号/编排 CRUD 骨架、SSE 事件流；鉴权 token 模式（design.md §9 子集）。
- 交付物：HTTP 模块+鉴权 spec。
- 依赖：M1-WP1。
- 验收：未带 token 请求 401；回调路径与 API 路径同端口共存。
- 风险：无实质风险。

### M2 · 编排完备——估时合计 12.5–19 pd

**M2-WP1 编排 DSL 解析与校验**（2–3 pd）
- 目标：触发→条件→动作 YAML 可写可校验。
- 范围：`orchestration/dsl/` 解析、校验器（动作引用悬空/账号不存在报错）、示例库。
- 交付物：DSL 解析+校验 spec。
- 依赖：M1 门禁。
- 验收：坏 DSL 报错可读；示例两则（design.md §7 DSL）解析通过。
- 风险：无实质风险。

**M2-WP2 持久 Task 引擎**（3–4 pd）
- 目标：workflow=持久状态机。
- 范围：`orchestration/engine.cr`：状态机+phase checkpoint、崩溃重放（重放单位=phase）、restartLimit。
- 交付物：引擎+重放 spec。
- 依赖：M2-WP1。
- 验收：**workflow run 崩溃重放幂等**（kill 点重放不重复执行已完 phase）（§14 M2 验收第 1 条 [来源: design.md:L751]）。
- 风险：phase 粒度过细致重放开销——默认粗粒度+文档指导。

**M2-WP3 触发器统一**（2–3 pd）
- 目标：cron/事件/webhook 归一。
- 范围：`orchestration/triggers/`：cron【A10 owner 加账号维度】、消息事件触发、webhook 唤醒（复用 M1-WP9 监听器）。
- 交付物：触发器+调度 spec。
- 依赖：M2-WP2。
- 验收：三种触发器各起一个 run 且落账本。
- 风险：无实质风险。

**M2-WP4 审批节点**（2–3 pd）
- 目标：审批链 fail-closed。
- 范围：`orchestration/approvals/`：超时 deny、无人值守 deny、hardline blocklist 不可 override、审批交互（TUI+HTTP 双入口）。
- 交付物：审批模块+交互 spec。
- 依赖：M2-WP3、M0-WP7（交互面）。
- 验收：**审批超时 deny 实测**（注入时钟快进）（§14 M2 验收第 2 条 [来源: design.md:L751]）。
- 风险：无实质风险。

**M2-WP5 lease+回收+预算+账本**（2–3 pd）
- 目标：任务不悬空、预算可熔断。
- 范围：`orchestration/ledger.cr`：append-only 账本、lease 过期回收、预算记账。
- 交付物：账本+回收 spec。
- 依赖：M2-WP2。
- 验收：**预算熔断**（超预算动作拒绝+账本留痕）（§14 M2 验收第 3 条 [来源: design.md:L751]）。
- 风险：无实质风险。

**M2-WP6 编排面板消费 API**（1.5–2.5 pd）
- 目标：runs 可回放可审计。
- 范围：HTTP API 扩展：runs 列表/详情/事件回放。
- 交付物：API+回放 spec。
- 依赖：M2-WP5。
- 验收：**runs 回放与审计**（任一 run 可按事件序重放展示）（§14 M2 验收第 4 条 [来源: design.md:L751]）。
- 风险：无实质风险。

### M3 · 协作 + 插件脚本层——估时合计 15–24 pd（包与生命周期 +1.5–2.5 pd；22 个 hook/DSL/初始化 +2.5–3.5 pd）

**M3-WP1 多 agent 定义与路由**（1–1.5 pd）
- 目标：N 个 agent 大脑可定义可路由。
- 范围：`agents/` agent 实例（人格/记忆/工具集独立）、binding 到 agent 维度。
- 交付物：多 agent 配置+路由 spec。
- 依赖：M2 门禁。
- 验收：两 agent 各自人格记忆独立应答。
- 风险：无实质风险。

**M3-WP2 agent 间消息+防环**（1.5–2 pd）
- 目标：互发不死循环。
- 范围：`orchestration/collaboration/`：fire-and-forget+署名+max_hops（默认 4）[来源: design.md §8]。
- 交付物：消息通道+防环 spec。
- 依赖：M3-WP1。
- 验收：**max_hops=4 拦截互发死循环**（构造两 agent 互回场景在第 4 跳截断）（§14 M3 验收第 1 条 [来源: design.md:L752]）。
- 风险：无实质风险。

**M3-WP3 subagent+信号量**（2–3 pd）
- 目标：子任务被拥有、并发受控。
- 范围：subagent=被拥有的会话（ownerTaskId 找回）[来源: design.md §16#22]、并发信号量（默认 3）[来源: design.md §16#23]。
- 交付物：subagent 管理+信号量 spec。
- 依赖：M3-WP1。
- 验收：**并发上限生效（超限排队不失控）+ subagent 崩溃后找回同一子任务**（§14 M3 验收第 2/3 条 [来源: design.md:L752]）。
- 风险：无实质风险。

**M3-WP4 裁剪 mruby 子进程运行时**（4–6 pd）
- 目标：子进程插件协议与精确 action/hook 派发跑通（硬需求④载体；design.md §12.2~§12.3）。
- 范围：`plugins/`：每动作独立裁剪 mruby 子进程、manifest + JSON-like 请求/结果协议、gembox 无 mruby-io/socket、请求 ID/schema/大小校验；`$action/$config/$context/$payload` 注入；`on_action/on_hook` 声明式 DSL；manifest 与注册集合一致性校验；`hook → 订阅插件` 索引；显式 install/enable/disable action（无隐式 init）；宿主工具与受控 `memory.backend` 扩展点。
- 交付物：进程 runner+DSL/精确派发 spec+首个示例插件。
- 依赖：M3-WP1；mrb.cr 甄别已完成（84/84，2026-11-19），但产品化受 Windows 新 mruby.exe 链接环境 blocker，恢复路径见 [review/m3-plugin-feasibility.md](review/m3-plugin-feasibility.md)。
- 验收：示例插件注册工具可被 agent 调用；**只派发 manifest 声明且本次注册 handler 的插件，不群发**；未声明/未注册/重复注册拒绝；初始化 action 不被普通 hook 隐式重复执行；**插件崩溃只影响该次调用并返回结构化错误，不卡宿主**（§14 M3 验收第 5 条）；请求缺字段、重复/超限结果和跨 scope capability 被拒绝。
- 风险：本机解释器产物 blocker 未消项时，WP4~WP6 仍按 B.3 降级条款只交预研，不宣称产品化。

**M3-WP5 沙箱、钩子目录与宿主注入点**（4–6 pd）
- 目标：插件失控不伤宿主；首版 22 个命名 hook 各有真实宿主注入点和可测失败语义。
- 范围：gembox 裁剪（WP4）、allocf/OS 资源约束、capability 与 scope 双重白名单、watchdog 终止进程树及迟到输出丢弃；实现 design.md §12.11 的消息（3）、Agent（2）、LLM（4）、工具（3）、会话/压缩（4）、记忆（2）、任务（2）、Gateway（start/stop 两名分别验证）共 22 个 hook；gate/transform 同步链、priority、deny fail-closed、observe 隔离、递归/次数/总预算限制、memo/idempotency。
- 交付物：沙箱配置、hook registry/dispatcher 与各注入点 spec、恶意插件样本（死循环/内存爆/未授权 API/递归 hook/非法 transform）。
- 依赖：M3-WP4；M2-WP2（task 生命周期）、M1-WP9（gateway 管理边界）。会话压缩若实现时仍无生产压缩器，先交付明确的 `SessionCompactor` 接口与协议完整实现，不能用假 hook 声称完成生产压缩。
- 验收：**插件死循环被 watchdog 超时终止不卡宿主**（§14 M3 验收第 4 条）；未授权 capability 拒绝；22 个 hook 按目录逐一验证精确派发与 payload schema；gate 异常/超时 deny、observe 异常跳过；transform 不越权；task 重放 memo 不重复副作用；资源上限与后代进程清理有实测证据。
- 风险：OS 资源限制/进程树终止的 Windows 行为须实测；LLM/工具/消息 hook 可能接触敏感内容，须按 manifest capability 最小化 payload 并脱敏。

**M3-WP6 插件包、热重载与生命周期**（3–5 pd）
- 目标：单文件插件可分发、免重启开发重载，安装/升级/卸载不破坏配置与数据。
- 范围：`.sebas-plugin` ZIP 白名单及路径/大小校验；`plugins/installed/<id>/versions/`、staging、registry 原子版本指针；开发目录 watch；安装默认禁用、显式授权与启停；升级/配置数据迁移/回滚；引用检查、卸载保留数据、purge 确认；CLI 与管理 API 共用 service（design.md §12.4~§12.9）。
- 交付物：pack/dev 工具、生命周期 service/API/CLI、恶意包与生命周期 spec、示例包。
- 依赖：M3-WP5、M1-WP8（共用触发-校验-换引用管线）、M1-WP9（管理 API）。
- 验收：**改开发目录脚本仅影响新调用，在途调用不受干扰**；安装默认禁用；同版本异摘要、路径穿越/压缩炸弹、未批准新 capability 均拒绝；升级保留配置/数据且失败保旧可回滚；被引用卸载拒绝、默认卸载保留数据、purge 有确认。
- 风险：ZIP 安全限制、原子替换与 Windows 文件占用须测试；签名/远程市场不在本包范围。复杂插件的受控多文件与常驻 worker 见 [review/plugin-evolution.md](review/plugin-evolution.md)，**不计入 M3 WP4~WP6 范围或门禁**。

### M4 · Fork/Join 影分身 + 轻量 Agent 团队 + 会话治理——估时合计 27.5–44.5 pd（2026-11-20 追加）

> 依据：[proposals/fork-join-semantics.md](proposals/fork-join-semantics.md)（语义方案核心）+ [proposals/fork-join-shadow-clone-architecture.md](proposals/fork-join-shadow-clone-architecture.md)（架构）+ [fork-join-shadow-clone-analysis.md](fork-join-shadow-clone-analysis.md)（翰林现状核实）+ [proposals/fork-join-shadow-clone-positioning.md](proposals/fork-join-shadow-clone-positioning.md)（定位提案）+ 首辅九问裁断（Q1–Q9，已全部落实）。仓内 M1–M3 已存在，提案原号 M0.5–M4 防撞名重编为 **M4.0–M4.4**，映射见 B.8.1。

**M4.0-WP1 语义/架构提案评审修订定稿**（0.5–1 pd）
- 目标：fork-join-semantics.md 与 fork-join-shadow-clone-architecture.md 定稿。
- 范围：吸收用户评审意见修订两提案；Join 语义矩阵 16 格（4 副作用级 × 4 时机）与 any 模式残余分身处置复核；九问裁断逐条回对。
- 交付物：两提案定稿版。
- 依赖：无（本轮三文档为输入）。
- 验收：评审通过（纯文档包门禁，B.3 M4 口径注）；矩阵逐格有策略可指认。
- 风险：评审若要求矩阵重定义则修订轮次增加——估时按下限单轮计。[推演]

**M4.0-WP2 定稿吸收回写 + 失效引用修正**（1–1.5 pd）
- 目标：按既有提案→design.md 契约吸收流落定 fork/join。
- 范围：design.md §8 协作扩展（fork/join 节：键/表/矩阵/衰减摘要）+ §14 路线图延至 M4 [来源: design.md:925-928 现仅到 M3]；本文 :17 的 CLAUDE.md 失效引用修正（该文件仓内不存在，改指本文 B 节 + Makefile + .github/workflows/ci.yml 现行权威 [来源: fork-join-shadow-clone-analysis.md:158]）；本文 M4 段同步勾稽。
- 交付物：design.md 修订（§8/§14）+ 本文 :17 修正。
- 依赖：M4.0-WP1 定稿。
- 验收：design.md §14 含 M4 期验收条目；:17 不再指向不存在文件；docs 与两提案无口径冲突。
- 风险：改 design.md 既有章节须走 PR 评审（用户授权后执行；本轮只写三文档不动 design.md）。

**M4.1-WP1 生产装配补齐 + 入队键修复**（1.5–2.5 pd）
- 目标：orchestration/agents 组件进生产链路，消除全线装配欠账（Q4：全线前置，首包）。
- 范围：gateway 装配 AgentRegistry / Approvals::Center / ForkManager / JoinWriter [来源: 仓库:src/platform/cli/gateway.cr:40-65 现状零装配]；修 consume_bus 入队键硬编码 `"main"` 与处理键 routed agent_name 不一致（入队前先 resolve）[来源: 仓库:src/platform/cli/gateway.cr:260 vs :171]。
- 交付物：装配链改造 + 分片键一致性 spec。
- 依赖：M4.0 门禁；E.5（调度接口冻结即可开工，先按 ForkEnvelope 契约预留适配层）。
- 验收：生产 gateway 进程内组件可达（装配存在性 spec）；同 peer 消息入队/处理键一致（"main" 硬编码消除）。
- 风险：装配与 apply_config 热更新矩阵交互——装配置 initialize 尾段避让热换路径。[推演]

**M4.1-WP2 expectations 表 + mode 判定器 + 任务树登记**（2–3 pd）
- 目标：join 落库面（store 新增表，Q2：不复用 tasks kind 扩展）。
- 范围：expectations DDL（fork_id/parent_task_id/mode all|any|allSettled/deadline/members/回写状态机，详 semantics 文档 §4.1）；mode 判定器（all 等全部不短路、any 首个成功、allSettled 失败也计完成）；分身任务树 kind="fork_child" 复用 TaskRow.parent_id/owner_task_id [来源: 仓库:src/platform/store/store.cr:23-25,30-144]。
- 交付物：store 表 + 判定器 + 崩溃恢复扫描 spec。
- 依赖：M4.1-WP1。
- 验收：三 mode 判定 spec 全过；强杀后 open/settling expectation 续判且不重复回写（memo 幂等）。
- 风险：SCHEMA 数组追加走 CREATE IF NOT EXISTS 既有惯例，存量库无迁移。[推演]

**M4.1-WP3 ForkManager 快照组装 + 分身执行体**（2–3 pd）
- 目标：fork 原语可执行（快照→分身任务→turn）。
- 范围：ForkManager（输入契约 = 任务描述/快照范围/能力声明/角色/join 模式/deadline）；快照 = transcripts 窗口 + system prompt + skills 注入 [来源: 仓库:src/platform/store/store.cr:406-417；src/agents/skills/skills.cr:43-83]；分身 turn 走 HttpProvider 纯消息接口 [来源: 仓库:src/providers/providers.cr:58-88]；ToolContext 扩展子任务句柄 [来源: 仓库:src/tools/registry.cr:44-59 现无]；分身并发信号量默认 3（循 subagent.cr:16 先例）。
- 交付物：ForkManager + 分身执行体 spec。
- 依赖：M4.1-WP2；E.5（ForkEnvelope 派发路径：无渠道入站消息、无 sender/peer）。
- 验收：N=1/N=3 fork 快照内容断言（窗口行数正确、不含 secrets）；超并发闸排队不失控。
- 风险：快照组装跨 store/skills/providers 三模块——纯函数化快照组装器便于 spec。[推演]

**M4.1-WP4 JoinWriter 分层回写 + 异常时机语义**（1.5–2.5 pd）
- 目标：join.report 三层回写与四时机语义落地。
- 范围：L1 结论+关键决策点+副作用清单进父会话 append_transcript [来源: 仓库:src/platform/store/store.cr:387-395]；L2 引用分身会话键+行数范围（全量已双写无需搬运）；四时机（正常/超时/失败/取消）中 M4.1 生效列按默认只读档结构先行；deadline 到期 expired + partial 回写；memo 幂等键 join:<fork_id>:written。
- 交付物：JoinWriter + 四时机 spec。
- 依赖：M4.1-WP3。
- 验收：正常完成回写父会话可见；超时 partial 标注；重放不重复回写。
- 风险：L1/L2/L3 副作用列本期只有结构无真实写工具——按「结构先行、M4.2 填充」验收。[推演]

**M4.1-WP5 DSL/IPC/HTTP 触发面 + e2e**（1–2 pd）
- 目标：用户显式 + DSL 声明两条触发路打通（Q3：不动生产 agent_turn）。
- 范围：KNOWN_TOOLS 加 fork/join [来源: 仓库:src/orchestration/dsl/dsl.cr:115]；DSL 校验（count/mode/deadline 必填）+ 示例 workflow；IPC/HTTP fork/join 命令；fork→分身→join 回写全链 e2e。
- 交付物：触发面 + e2e spec + 示例 DSL。
- 依赖：M4.1-WP4。
- 验收：DSL 声明 3 分身→各自终态→按 mode 回写父会话（一级 Fork + 只读分身最小闭环，提案 M1 门槛）；调度四条门禁绿（B.3 M4 口径注）。
- 风险：无实质风险。

**M4.2-WP1 能力衰减机制**（1.5–2.5 pd）
- 目标：生效能力 = fork 显式声明 ∩ 父 tools.allow；未声明用默认只读档（Q6）。
- 范围：衰减执行面（声明交集 + 白名单外剔除并在回执列明）；默认只读档工具集（无任何写副作用工具、不携带 secrets，semantics 文档 §5.1 表）；tools.allow=["*"] 现状口径下声明全集生效 [来源: 仓库:src/platform/config/schema.cr:104-107]。
- 交付物：衰减面 + 档位 spec。
- 依赖：M4.1 门禁。
- 验收：未声明分身无任何写工具；声明∩白名单交集生效；白名单外声明被拒且回执列明。
- 风险：现有 4 工具面 [来源: 仓库:src/tools/executor.cr:122-129] 无文件写工具——WP2 含最小文件写示例工具承载冲突场景。[推演]

**M4.2-WP2 副作用四级 + 冲突处理**（2–3 pd）
- 目标：Join 语义矩阵 16 格可执行；冲突场景 e2e（提案 M2 门槛）。
- 范围：工具 risk 四值映射（只读/文件写/网络写/不可逆，semantics §2.1）；副作用清单记录（effects 进 join.report）；文件指纹冲突检测（fork 快照记工作区摘要，回写对比→CONFLICT 进父裁决清单，**不自动 merge**）；最小文件写示例工具。
- 交付物：分级 + 冲突检测 + e2e spec。
- 依赖：M4.2-WP1。
- 验收：冲突场景 e2e 全过（父期间改同文件→回写标 CONFLICT 不自动 merge）。
- 风险：文件指纹快照范围界定——首版按「分身可写路径声明」收窄。[推演]

**M4.2-WP3 approvals 接线：不可逆仅建议权**（1.5–2.5 pd）
- 目标：分身 L3 不可逆操作必经审批，未批不执行（fail-closed）。
- 范围：Approvals::Center 生产装配 + IPC approve/deny 命令补齐 [来源: 仓库:src/admin/ipc/server.cr:187-215 现声明 approvals 能力但无命令]；分身 ToolContext 携 unattended/approval_mode；hardline 地板已含 "fork bomb" [来源: 仓库:src/orchestration/approvals/approvals.cr:33-38,50-87]。
- 交付物：审批链接线 + 拦截 spec。
- 依赖：M4.2-WP2。
- 验收：分身 L3 未批不执行；无人值守 deny；批准后执行且审批凭证随 join.report 回写。
- 风险：无实质风险（Center 语义已完备）。

**M4.2-WP4 secrets 收敛**（1–2 pd）
- 目标：凭据出明文；分身不携带 secrets（Q6：不留 M4.4）。
- 范围：AgentConfig.api_key 明文过渡迁 keys/ 模块（M1-WP7 keyring 承接）[来源: 仓库:src/platform/config/schema.cr:92]；分身执行面无凭据直读路径（provider 实例句柄封装 [来源: 仓库:src/providers/pool.cr:12-25]）；日志脱敏复查。
- 交付物：迁移命令 + 无明文断言 spec。
- 依赖：M4.2-WP1。
- 验收：配置树无明文凭据；分身运行期日志 grep 不到 secret；迁移幂等可重跑。
- 风险：Windows Credential Manager FFI 依赖 M1-WP7 spike 结论 [未验证]——未通则静态加密兜底（估时内含）。[推演]

**M4.3-WP1 ReAct 工具循环**（2–3 pd）
- 目标：生产 agent_turn 从一次性调用升为工具循环（Q3：独立前置工作包，不提前到 M4.1）。
- 范围：模型响应→工具调用解析→衰减工具面执行→结果回注→下一轮；轮数上限；循环内 checkpoint 复用 task phase [来源: 仓库:src/platform/cli/gateway.cr:212-223 现状单次调用]。
- 交付物：ReAct 循环 + 轮上限 spec。
- 依赖：M4.2 门禁。
- 验收：LLM 发起工具调用→执行→结果回注→终答全链 spec；无工具调用时行为与现状一致（回归）。
- 风险：provider 工具调用响应格式解析——FakeProvider 注入模拟先例可用。[来源: rsrs 旁证 M0 落地 FakeProvider]

**M4.3-WP2 对话流内自然 fork**（1.5–2.5 pd）
- 目标：用户说「并行查三个方案」，Agent 自然分身（fork 是对话一等公民，提案 Q7）。
- 范围：fork 工具进 ReAct 循环工具面（经能力衰减 + 并发闸 + 一级限制 + L3 审批四重闸，semantics §6）；真实对话场景验收。
- 交付物：对话内 fork + 审批拦截 spec。
- 依赖：M4.3-WP1。
- 验收：真实用户场景验证（提案 M3 门槛）：对话内 fork→join 回写父会话；审批拦截实测（L3 场景被拦）。
- 风险：LLM 自主 fork 判定确定性——验收以「声明可复现的 prompt 场景」为界。[推演]

**M4.3-WP3 常驻 Agent 前台接待**（1.5–2.5 pd）
- 目标：匿名/临时会话包装，Session 藏而不删（轴①轻，Q8 拆分第一块）。
- 范围：未定向消息前台 agent 接待（前台默认档 = 只读 + 转介建议）；前台会话键与生命周期标记；routing 无匹配不再丢弃改投前台（原 fail-closed 审计保留）[来源: 仓库:src/platform/cli/gateway.cr:158-164]。
- 交付物：前台接待层 + 无匹配转投 spec。
- 依赖：M4.3-WP1。
- 验收：无 binding 匿名消息获前台应答并可转介；原审计记录保留。
- 风险：匿名消息滥用面——首版加每 peer 频率闸（最小化）。[推演]

**M4.4-WP1 注册双轨统一**（2–3 pd）
- 目标：AgentRegistry 目录/SOUL.md 与 Config::AgentConfig YAML 双轨打通（轴②前置）。
- 范围：persona/persona_file 引用校验、session/skills 字段补齐 [来源: 仓库:src/agents/agents.cr:49-57；src/platform/config/schema.cr:87-97]；模板落位定夺（SOUL.md vs SKILL.md，M4.4-WP2 前置决策）。
- 交付物：双轨校验 + 统一读取面 spec。
- 依赖：M4.3 门禁。
- 验收：同一 agent 定义两轨一致可互查；悬空引用报错可读；存量 agent 目录只读兼容不强制迁移。[推演]
- 风险：双轨字段语义对齐工作量超区间上限——先校验后统一分两步走。[推演]

**M4.4-WP2 模板库 + 角色卡**（2–3 pd）
- 目标：克隆基底 + 人格 patch = Agent 团队模板（轴②）；fork 角色指定（提案 Q5）。
- 范围：agent 模板（克隆+patch）；SKILL.md frontmatter 角色卡挂点 [来源: 仓库:src/agents/skills/skills.cr:43-83]；fork `role` 参数接线（semantics §1.1）。与插件演进 issue #24 **引用不并卡**：其 P3「按插件隔离常驻 Worker」为不同轨道（启动条件见 [review/plugin-evolution.md](review/plugin-evolution.md)），模板库不依赖它。
- 交付物：模板库 + 角色卡 spec + 示例模板两则（代码审查员/发布工程师）。
- 依赖：M4.4-WP1。
- 验收：从模板克隆 agent 一次成型；fork role 指定生效（system prompt 后缀注入）。
- 风险：模板爆炸（轴②风险「轻量产生垃圾」）——回收治理在 WP3 承接，本期验收不单列 GC。[推演]

**M4.4-WP3 sessions 元数据表 + 休眠/归档/回收**（2–3 pd）
- 目标：会话生命周期治理闭环（轴①重，Q8 拆分第二块；提案 M4 门槛）。
- 范围：sessions 元数据表（store 新增表，架构文档 §5 草案）；状态机 active/dormant/archived；休眠阈值 + 归档命令 + 回收 GC（人工确认非自动删）；不绑 compaction（design.md:341-342 未实现，独立先行）[来源: fork-join-shadow-clone-analysis.md §4 M4]。
- 交付物：sessions 表 + 生命周期 + GC spec。
- 依赖：M4.4-WP1。
- 验收：休眠会话不占 worker；归档可查不可写；回收有人工确认与审计（治理闭环）。
- 风险：sessions 表扫描性能——按 last_active_at 建索引。[推演]

**M4.4-WP4 IPC/HTTP 管理面扩展**（1–2 pd）
- 目标：生命周期与模板可管理。
- 范围：sessions 生命周期查询/归档命令、agent 模板 CRUD API（复用 M1-WP9 鉴权口径）。
- 交付物：管理 API + spec。
- 依赖：M4.4-WP2、M4.4-WP3。
- 验收：归档/休眠状态经 IPC/HTTP 可查可操作；模板 CRUD 未授权 401。
- 风险：无实质风险。

### M5 · 持久意图、唤醒与提醒闭环——估时合计 22–36 pd（2026-11-20 追加，v0.3.0）

> 依据：[proposals/commitments-calendar-integration.md](proposals/commitments-calendar-integration.md) §1–§5、§8–§9（提案已随 PR #61 合入 main）。本节只做工作包、依赖、估时与验收；**不新造设计决策**——语义有变更回写提案与 design.md，不在本计划内定。
> 期定位：把 cron 从「用户产品层」降到「唤醒基础设施层」（提案 §5），新增 Commitment/Checkpoint/Reminder/NotificationDelivery 领域对象与持久 WakeSchedule/Occurrence/Run 链路。**本期不含任何外部日历/TODO 接入**（M6/M7 承接），也不做 tombstone 式 UI。
> 期门禁：调度四条全绿（`make format-check` + `crystal spec` + `make lint` + `make release`）；纯文档包（M5.0）以评审通过替代（B.3 M4 口径注同款）。

**M5.0-WP1 领域对象、状态机与不变式定稿**（1–1.5 pd）
- 目标：把提案 §3.2 生命周期、§4.1 十对象、§3.3 提醒纪律收敛为实现契约。
- 范围：十对象字段表（含 owner/来源/权限/完成条件/跟进策略）；9 态生命周期转移表（dormant/needs_clarification/waiting_condition/ready/active/at_risk/overdue/completed/cancelled），每态列触发条件与拒绝条件；`needs_clarification` 必含「缺失字段 + 最晚澄清时间」；四条不变式（同意图最多一个未决通知 / 同因同计划版本不重推 / `sent|seen|actioned|snoozed` 不等于 completed / 暂停跟进不删配置）[来源: 提案 §3.2–§3.3]。
- 交付物：`docs/design/proposals/commitments-calendar-semantics.md`（新文档）。
- 依赖：无（提案 §1–§8 为输入）。
- 验收：评审通过；9 态×触发条件矩阵无空格，每格可指认拒绝条件；四条不变式各配一条可反驳的判定式。
- 风险：对象数偏多易滑向完整日历建模——写作时以「提案 §8 非目标」为删减尺。[推演]

**M5.0-WP2 时间语义、表结构与迁移契约定稿**（1–1.5 pd）
- 目标：把提案 §4.2 时间/重复语义与 §5.3 职责分离落成 DDL 草案与迁移方案。
- 范围：四类时间表示（UTC instant / 原墙钟+IANA / 全天 `DATE` / floating）的比较与排序规则；`RRULE/RDATE/EXDATE` 原文保留口径与 Occurrence 生成边界；DST 缺口与重复时刻的期望结果表；首版表结构草案与索引；迁移序号方案（`PRAGMA user_version` + 有序迁移）；design.md §14 追加 M5–M7 行（与 M4.0-WP2 #40 同行编辑，**串行：#40 先落**，避免同文件冲突）[来源: design.md:921-928 现仅 M0–M3]。
- 交付物：语义文档 §时间/§DDL 草案 + design.md §14 修订。
- 依赖：M5.0-WP1。
- 验收：**可执行验收**——`spec/platform/time_semantics_spec.cr` 三类边界用例各给确定期望值并全绿，不接受文档描述式验收：①春季缺口（`America/New_York` 2026-03-08 02:30 不存在）→ 拒绝该本地时刻并返回「需用户选择」错误码；②秋季重复（同日 2026-11-01 01:30 出现两次：先 EDT `−04:00`、后 EST `−05:00`）→ 取**第一次，即 UTC 偏移较大者 `−04:00`**（对应较早的 UTC 时刻），并在对象上标注 `ambiguous_local_time`；判定式写成「比较两候选的 UTC 时刻，取较早者」，不得写成「偏移较小者」——`−05:00` 数值更小但对应第二次；③全天跨时区（`Asia/Shanghai` 建全天 `DATE`，以 `America/Los_Angeles` 读取）→ 仍为同一 `DATE`，不发生日期漂移。表草案覆盖 M5.1 全部仓储字段，无悬空外键。
- 风险：时区规则依赖 tzdata 更新——首版以「显式拒绝无法表示的本地时刻并要求用户选择」替代自动猜测。[推演]

**M5.1-WP1 store schema 版本化与增量迁移**（1–2 pd）
- 目标：为后续新表提供可演进底座（现状只有幂等全量建表，无版本概念）。
- 范围：`SCHEMA.each { |ddl| @db.exec(ddl) }` 幂等建表改为「v1 基线快照 + 有序迁移列表」，启动时读 `user_version` 逐条前推；迁移单事务、失败回滚、新库直达最新；**存量库零手工动作**；迁移与 `make release` 兼容 [来源: 仓库:src/platform/store/store.cr:168 现仅幂等执行；同文件 :34-146 全部 DDL]。
- 交付物：迁移器 + 迁移 spec（两次连续 migrate 幂等、半途失败不留脏态）。
- 依赖：M5.0-WP2。
- 验收：以既有 v1 库样本升级到最新可重跑幂等；注入失败点在任一迁移一半时回滚且 `user_version` 不前进。
- 风险：Crystal sqlite3 绑定单语句限制（同文件 :30 注释「一次只接受一条语句」）——迁移器按语句数组执行，不复用多语句字符串。[推演]

**M5.1-WP2 commitments/checkpoints/reminders/deliveries 表与仓储**（2–3 pd）
- 目标：领域对象落库与查询面。
- 范围：四表 + 索引（按 owner/状态/下一评估时刻）；「同意图最多一个未决通知」由**部分唯一索引**强制而非应用层检查；`needs_clarification` 行必须有缺失字段非空；仓储 API（create/get/update/状态迁移/按时间窗查询/按 owner 列举）[来源: 提案 §4.1 对象责任表]。
- 交付物：DDL 迁移 + 仓储 + 约束 spec。
- 依赖：M5.1-WP1。
- 验收：并发插入第二条未决通知被 DB 拒绝；状态迁移越权（如 completed→active）被拒；`needs_clarification` 缺字段写不进去。
- 风险：状态机散在仓储与评估器两处——状态迁移只允许经单一 `transition!` 入口。[推演]

**M5.1-WP3 WakeSchedule/Occurrence 持久调度与 Occurrence 身份**（3–5 pd）
- 目标：唤醒不再依赖进程内内存表（现状重启即丢、扫描循环单线程）。
- 范围：WakeSchedule 四类来源（一次性/周期 cron/interval/事件与轮询兜底）；Occurrence 稳定身份（`schedule_id + slot` 或 recurrence key）与生成窗口；原子 claim（条件 UPDATE 或 lease）、去重、跳过、合并、补跑、overlap 策略；复用 `Cron.next_after` 做时间计算 [来源: 仓库:src/orchestration/triggers/cron.cr:54]；替换 `@cron_jobs = Hash(...)` 与 `cron_loop` 扫描 [来源: 仓库:src/orchestration/triggers/triggers.cr:20,41-45,88-118]；调度口径沿用会话输入调度的持久化先例。
- 交付物：持久调度器 + Occurrence spec。
- 依赖：M5.1-WP1、M5.1-WP2。
- 验收：两 fiber/两进程并发 claim 同一 Occurrence 仅一胜；停机 3 天后重启，pending 不丢且按配置策略（skip/coalesce/catch-up）补跑可指认；clock 注入下不漏不重。
- 风险：补跑与合并语义易与「提醒纪律」打架——本包只实现机制，语义选择由 M5.2-WP1 评估器定。[推演]

**M5.1-WP4 Run 持久恢复与副作用幂等**（2–3 pd）
- 目标：Occurrence → Run 的恢复语义与既有执行基座对齐，不另起炉灶。
- 范围：复用 `engine.start` 的 intent 幂等与 `tasks/leases` 恢复 [来源: 仓库:src/orchestration/engine.cr:26-39,59-77；src/platform/store/store.cr:179-190,223-258,327-342]；Run 结果三态（成功/失败/`outcome_unknown`）；`outcome_unknown` 不自动重放有副作用动作；ledger 记录每次评估与动作 [来源: 仓库:src/platform/store/store.cr:205-222]。
- 交付物：Run 恢复层 + 幂等 spec。
- 依赖：M5.1-WP3。
- 验收：执行中途强杀后重启，同一 Run 不重复投递副作用；`outcome_unknown` 走人工/下一检查点复核路径而非盲目重试。
- 风险：与 M5.3-WP3（cron 归位）共享 `event_id` 口径——先定身份格式再改触发器，避免双写。[推演]

**M5.2-WP1 Checkpoint 评估器与静默策略**（2–3 pd）
- 目标：到点不等于打扰：评估产出五选一（保持休眠/更新计划/提醒/请求审批/行动）与完成收口。
- 范围：评估输入（条件、上下文版本、上次结果、计划版本）；无新信息静默；同因同版本不重推；升级四条件（新事实/不可逆期限临近/计划失效/需用户决定）；完成或外部失效时关闭未来 Checkpoint 与未投递 Reminder [来源: 提案 §3.3、§3.4、§5.3]。
- 交付物：评估器 + 静默/升级 spec。
- 依赖：M5.1 门禁。
- 验收：无变化连续三轮零投递；有变化按升级规则各投一次；完成后再到点无提醒（迟到提醒为零）。
- 风险：评估器需要「上下文差异」定义，首版以显式字段快照比对为界，不做语义 diff。[推演]

**M5.2-WP2 统一 admission 接线（提醒与工作输入不绕过）**（1–2 pd）
- 目标：提醒投递与工作输入走同一 admission，不让第二条旁路出现。
- 范围：会话输入调度仓储已具 DDL 与 `admit_session_input`（含批次与字节预算）[来源: 仓库:src/platform/store/store.cr:98-134,453-580]；但当前**零调用者**（gateway 未接线，调度轨 #4/#5 未完成）——本包只做 Source 类型扩展（`reminder`/`work`）与接线口径，主循环接线归 #4/#5；优先级与去重不复制实现。
- 交付物：Source 扩展 + 接线点 spec（旁路调用必须失败）。
- 依赖：M5.1 门禁；E.1#8（调度轨 #4/#5 完成或 admission 接口冻结）。
- 验收：提醒注入与用户消息共用同一批次与字节预算；绕过 admission 的直写路径被拒并有审计。
- 风险：调度轨未按期则本包只能交付「接口就绪 + 冻结断言」——按 E.1#8 的冻结口径验收，不伪造联动。[推演]

**M5.2-WP3 NotificationDelivery 状态机与渠道投递**（2–3 pd）
- 目标：投递可追踪、可失败、可过期，且不污染 Commitment 状态。
- 范围：Delivery 七态（scheduled/sent/seen/actioned/superseded/expired/unknown）与合法迁移；重试与提醒预算（次数/升级档）；接线 `ChannelAdapter#send(peer, content, idempotency_key)` 并落 `message_id` [来源: 仓库:src/channels/base.cr:55]；渠道失败（无 adapter/发送错误）标 `unknown` 或 `expired`，不标 completed [来源: 提案 §3.3、§6.4]。
- 交付物：Delivery 状态机 + 投递 spec（假 adapter 注入）。
- 依赖：M5.2-WP1。
- 验收：`sent` 后 Commitment 仍 active；重复发送被 Delivery 约束挡住；渠道报错不产生「已完成」。
- 风险：`seen` 需渠道已读回执，首版仅 email IMAP `\Seen` 与 TUI/HTTP 显式查看两条来源，其余标 `unknown` 而非猜测。[推演]

**M5.2-WP4 Today 视图与 Projection/WorkSession 最小闭环**（1–2 pd）
- 目标：Today 是有限承诺场，不是逾期堆积场（提案 §3.4）。
- 范围：六段视图最小实现（当前事项/下一固定承诺/今日任务/Projection/容量缺口与风险项/Inbox）；Projection 不落外部日历；计划与实际耗时分列；日终四操作（完成/改期/缩范围/退回 Inbox）留延期历史 [来源: 提案 §3.4]。
- **归属裁断（防两处实现）**：本包独占 Today 的**唯一归属权**——六段的取数口径、排序、容量缺口计算、四操作的语义与状态迁移全在本包；M5.3-WP2（管理面）只做命令与渲染接线，**不得再实现一套取数或排序**；M5.3-WP1（捕获）产出的 Commitment 以 Inbox 段进入，不改本包口径。
- 交付物：Today 视图 + 容量缺口 spec。
- 依赖：M5.2-WP1。
- 验收：容量不足时显示缺口与选项，不静默超载、不擅自延后硬期限；Projection 与 WorkSession 可分别查询；日终四操作各产生一次可指认的状态迁移并留延期历史，四操作之外无第二条改期路径。
- 风险：视图需要命令入口才能被人看到——渲染与命令接线归 M5.3-WP2（#74）的 `today.view`/`today.dayend`，本包交付纯函数投影计算与四操作语义，**不交付 UI**。[推演]

**M5.3-WP1 一句话捕获与 needs_clarification**（1–2 pd）
- 目标：用户一句话即可创建远期意图（Outcome/Source/跟进依据三件套）。
- 范围：四条示例话术路径（远期日期提醒/会前准备/等回复转跟进/周期检查至成功）[来源: 提案 §3.1]；歧义仅在影响执行、缺可观察条件或无法定时区时澄清；`needs_clarification` 带缺失字段与最晚澄清时间；后续补全走 update 不新建。
- 交付物：捕获解析 + 四条话术 spec。
- 依赖：M5.2 门禁（评估器与 Delivery 需先存在）。
- 验收：四条话术各产出合法 Commitment 且状态正确；缺字段进澄清态不静默丢。
- 风险：「等对方回复后提醒我」依赖外部通道信号——首版以「无回复即到下一检查点」的轮询兜底表达，不做真事件订阅。[推演]

**M5.3-WP2 IPC/HTTP 管理面扩展**（1–2 pd）
- 目标：承诺与提醒可查可控。
- 范围：`commitments.list/get/create/update/pause/snooze/complete/cancel`、`checkpoints.list`、`deliveries.list`、`today.view`（取 M5.2-WP4 纯函数结果并渲染）、`today.dayend`（日终四操作入口）；沿用既有命令分发与鉴权口径 [来源: 仓库:src/admin/ipc/server.cr:189-210 现仅 ping/system.health/sessions.*/runs.*/config.*]；TUI 与 HTTP 双入口同语义。
- **Today 渲染与日终操作的归属**：视图的取数口径、排序、容量缺口计算与四操作的**语义/状态迁移**归 M5.2-WP4（#72，唯一归属）；本包只负责**命令暴露与渲染接线**（`today.view`/`today.dayend`）与鉴权，不另实现取数或排序，也不自带状态迁移逻辑。延期历史由 M5.2-WP4 的迁移记录提供，本包只读取展示。
- 交付物：管理面命令 + 鉴权 spec。
- 依赖：M5.3-WP1。
- 验收：未授权 401；越权状态迁移被拒；snooze 必须形成新时间或条件（不接受「隐藏」）。
- 风险：命令面扩张快于语义稳定——首版命令集按本包清单闭集，新增走后续包。[推演]

**M5.3-WP3 cron 归位为唤醒基础设施层**（2–3 pd）
- 目标：保留 cronjob 能力，但不再让 cron 定义等同业务意图（提案 §5）。
- 范围：workflow `cron` trigger → WakeSchedule 映射（`event_id` 口径与现在 `cron:<workflow>:<next_at_ms>` 等价，保证 M2 幂等语义不退化）[来源: 仓库:src/orchestration/triggers/triggers.cr:103]；`cron_loop` 由内存扫描改为持久调度驱动；不新增平行 cron 管理入口；纯例行脚本仍可不建 Commitment。
- 交付物：映射层 + 回归 spec。
- 依赖：M5.1-WP3、M5.1-WP4。
- 验收：既有 M2 cron 用例全绿（触发次数一致、不漏不重）；重启后 cron 不丢；同一 workflow 不出现双调度。
- 风险：改动在产链路，回归面覆盖 gateway 启动顺序——先加开关灰度（旧扫描/新调度二选一）再切默认。[推演]

**M5.3-WP4 文档、CHANGELOG 与端到端**（1 pd）
- 目标：行为与文档一致（B.3 第 4 条）。
- 范围：design.md §6（会话/时间上下文）与 §14 回写；CHANGELOG `Unreleased` → `0.3.0`；README 使用说明；e2e 一条主线（创建→唤醒→静默→提醒→完成→关闭未来唤醒）。
- 交付物：文档修订 + e2e spec。
- 依赖：M5.3-WP1~WP3。
- 验收：e2e 全绿；文档与实现零口径差（逐条回对提案 §9 首闭环 1/2/4/5 条）。
- 风险：无实质风险。

**M5.4-WP1 M5 门禁与 v0.3.0 发布**（1–2 pd）
- 目标：期收口与版本落定。
- 范围：M-gate 五项（B.3）+ 调度四条；`docs/design/review/m5-gate.md` 记录证据与边界；tag `v0.3.0` 触发既有 release workflow。
- 交付物：m5-gate.md + tag。
- 依赖：M5.3 门禁。
- 验收：提案 §9 首闭环第 1/2/4/5 条逐条有可复现证据；Go/No-Go 明确。
- **冻结口径裁断（CodeRabbit 问：仅冻结态交付是否挡 v0.3.0）**：**不挡**——若 M5.2-WP2 因 E.1#8 未满足只交付「Source 扩展 + 接口冻结断言」形态（无真实联动），v0.3.0 仍可发，但须同时满足三条件，缺一即 No-Go 改判：①m5-gate.md 单列「未并入 admission」项并写明影响面（提醒独立通道，不与用户消息共用批次与字节预算）；②产品面（Today 与提醒）显式标注该限制，不呈现「已与用户消息统一调度」；③该限制条目同步记入 design.md §15.1。**不接受的形态**：把冻结断言当联动证据、或把「提醒走独立通道」写成已达成的设计目标。
- 风险：M5.2-WP2 若受调度轨阻塞，门禁须显式列「未验证项」而非默认通过。[推演]

---

### M6 · 外部日历/TODO 只读镜像与变化驱动重估——估时合计 20–34 pd（2026-11-20 追加，v0.4.0）

> 依据：[proposals/commitments-calendar-integration.md](proposals/commitments-calendar-integration.md) §6–§7、§9 首闭环第 3 条。期定位：**只读镜像与观察（接入深度 1）+ 显式关联（深度 2）**，不做复制、不做双向（深度 3 归 M7）。
> 期门禁：调度四条全绿；每 provider 必须有「真机 round-trip + 原文保留」证据，未实测的 provider 不得计入验收（提案 §9「必须验证的边界」第 6 条）。
> 反蔓延硬约束：canonical superset + adapter，**不做最低公分母双向同步**；JMAP Calendars 不进首期（提案 §7.4）。

**M6.0-WP1 适配器契约、同步元数据与能力矩阵定稿**（1–2 pd）
- 目标：三 provider 共用一个契约，差异落在矩阵而非分支。
- 范围：适配器接口（列集合/取页/取增量/能力探测/保原文）；同步元数据六类（provider+account+collection / resource id+href / UID+series+original recurrence key / ETag·changeKey·sequence·updated / sync-token·syncToken·deltaLink+时间窗 / watch-subscription id+expiration）[来源: 提案 §7.4]；能力矩阵模板（VEVENT/VTODO/VALARM/重复/条件写/通知），每格三值「支持/不支持/不宣称」；失败语义 `stale/conflicted/partial_failure/unknown` 与隐私档（跨账户仅 busy）[来源: 提案 §6.4]。
- 交付物：契约文档（`docs/design/proposals/calendar-adapter-contract.md`）。
- 依赖：M5.4 门禁。
- 验收：评审通过；三 provider 在矩阵上无「假设支持」空格；每个不宣称项写明后果。
- 风险：契约写得过宽会诱导双向同步——接口只暴露读与条件写探测，不暴露全字段写。[推演]

**M6.1-WP1 ExternalLink/同步元数据表与仓储**（2–3 pd）
- 目标：外部对象在 Sebas 侧的身份、版本与游标可存可查。
- 范围：ExternalLink 表（内部对象 ↔ 外部资源、来源、权限、同步方向、最后对账结果）；同步元数据列按 M6.0 六类；原始载荷本地留存（不依赖远端回取）；迁移接 M5.1-WP1 迁移器。
- 交付物：表 + 仓储 + 约束 spec。
- 依赖：M5.0-WP2（迁移契约）、M6.0-WP1。
- 验收：同一外部对象重复 upsert 不产生第二行；游标与资源版本分列存储，互不覆盖；原文可完整重放解析。
- 风险：ID 归并诱惑（UID/iCalUID 当主键）——按提案 §7.1 明确「UID 不作跨平台主键」，复合键强制。[推演]

**M6.1-WP2 增量同步引擎骨架与对账**（3–5 pd）
- 目标：全量→增量→对账三段可靠，游标只在完整一轮后前推。
- 范围：首次全量、后续增量；分页未完成不前推游标；`410`/`deltaLink` 失效按范围全量重建；漏通知/订阅失效用增量对账；短时批量变化合并为一次评估；同步结果只落镜像，不改关联 Commitment（评估归 M6.3）[来源: 提案 §6.3、§7.2–§7.3]。
- 交付物：同步引擎 + 假 provider 契约测试（含 410/部分失败/重复页）。
- 依赖：M6.1-WP1。
- 验收：中途 kill 后重启不重复入库且游标不前推；410 触发全量重建且旧游标清除；部分失败标 `partial_failure`。
- 风险：游标语义各家不同（sync-token vs deltaLink vs syncToken）——引擎只认「不透明游标 + 作用域」二元组。[推演]

**M6.2-WP1 CalDAV 适配器**（3–5 pd）
- 目标：iCalendar/CalDAV 语义底座可用（RFC 5545/4791/6578）。
- 范围：集合探测（VEVENT/VTODO/VALARM/sync）；主重复组件与例外同资源处理，不按展开实例分别 PUT；ETag 条件写；完整 ICS 与未知 IANA/X- 属性全保留；`UID + RECURRENCE-ID` 定位系列内实例 [来源: 提案 §7.1]。
- 交付物：适配器 + 固定响应录制回放 spec。
- 依赖：M6.1-WP2。
- 验收：录制回放下系列+例外还原正确；未知属性 round-trip 无损；条件写冲突返回 `conflicted` 不覆盖。
- 风险：真实 CalDAV 服务端改写资源——首版以「服务端改写即重新拉原文」处理，不做本地推断。[推演]

**M6.2-WP2 Google Calendar 适配器**（3–5 pd）
- 目标：syncToken 增量与 watch 提示语义正确。
- 范围：首次全量、后续 `syncToken`；一轮分页完成才存新 token；`410` 对该范围全量重建；`watch` 只当「有变化」提示，channel 过期需重建；重复实例保留 `id/recurringEventId/originalStartTime`；写回按最新资源字段级 diff（本期只探测能力不写）[来源: 提案 §7.2]。
- 交付物：适配器 + 回放 spec。
- 依赖：M6.1-WP2。
- 验收：token 前推时机可断言（分页中断不前推）；watch 过期后仍能靠增量对账收敛；重复实例三层身份完整。
- 风险：OAuth 只读 scope 需用户侧真实账户（E.1#9）；无真实账户时只交回放证据并**明确标未验证**（提案 §9 第 6 条）。[推演]

**M6.2-WP3 Microsoft Graph 适配器**（3–5 pd）
- 目标：`calendarView/delta` 与 To Do 独立资源正确建模。
- 范围：delta 绑定具体日历与时间窗，完整一轮后存 `deltaLink`；通知可能只带资源 ID，漏通知用 delta 对账；Immutable ID + account/mailbox 作用域；系列/实例/例外不按 iCalUID 归并；To Do 与 Event 独立，任务时间块须显式关联 WorkSession [来源: 提案 §7.3]。
- 交付物：适配器 + 回放 spec。
- 依赖：M6.1-WP2。
- 验收：时间窗变化触发新 delta 作用域并旧游标失效；To Do 完成不自动关闭关联 Commitment；例外实例不误并入系列。
- 风险：同 Google——真实租户/账户未就绪时标未验证，不把回放当集成。[推演]

**M6.3-WP1 外部变化 → 评估 → 重估链路**（2–3 pd）
- 目标：外部变化只触发评估，绝不直接通知或重排（提案 §6.3）。
- 范围：变化→增量同步→本地对账→影响判定→重算条件/准备窗口/容量/Checkpoint→撤销失效未投递 Reminder→仅在有新决策/风险/冲突时通知→展示「旧计划 → 新建议 → 原因」三段；已接受/已发生/临近开始默认锁定；涉及他人的修改默认需确认。
- 交付物：重估链路 + 三段展示 spec。
- 依赖：M6.2 门禁。
- 验收：外部改期只产生一条带原因的建议，不自动改 WorkSession；撤销已排未投递提醒可验证；批量变化合并为一次评估。
- 风险：影响判定需要「关联强度」定义——首版仅按显式 ExternalLink 关联，不做启发式推断。[推演]

**M6.3-WP2 隐私与失败语义落地**（1–2 pd）
- 目标：失败可见、隐私默认收紧。
- 范围：跨工作/私人账户默认只共享 busy 或通用标签；每对象显示来源/写入方/权限/同步方向/最后对账结果；连接器停用后意图与历史保留，投影保留或清理由用户选；`stale/conflicted/partial_failure/unknown` 四态在视图与管理面可见；无权限或结果不确定 fail-closed [来源: 提案 §6.4]。
- 交付物：隐私档 + 失败态 spec。
- 依赖：M6.3-WP1。
- 验收：busy-only 账户查不到标题详情；四失败态各有可见位；停用连接器不删意图。
- 风险：busy-only 与容量计算耦合——容量估算用 busy 即可，不反推详情。[推演]

**M6.4-WP1 真机 round-trip、能力矩阵验证与 v0.4.0 发布**（2–4 pd）
- 目标：把「声称支持」换成「实测支持」。
- 范围：真实 Google/Microsoft/CalDAV 账户（E.1#9）各跑一轮：全量→增量→改期/取消/完成→游标失效→物删除；填实能力矩阵；`docs/design/review/m6-gate.md`；tag `v0.4.0`。
- **时间边界的端到端验收（与 M5.0-WP2 的纯函数 spec 分开）**：M5.0-WP2 只在本地语义层验 DST/全天/跨时区；本包须在**真实 provider 往返链路上**再验一遍，三条各给确定期望：①DST 缺口——在 `America/New_York` 建 2026-03-08 02:30 的 VEVENT，provider 侧要么拒绝要么按 03:30 存储，本地须如实回显 provider 的取舍并标 `ambiguous_local_time`，不得本地静默改写成 03:30 却显示原文 02:30；②秋季重复——2026-11-01 01:30 建事件后回读，须仍对应同一 UTC 时刻（不是差一小时）；③全天跨时区——在 `Asia/Shanghai` 建全天 `DATE`，以 `America/Los_Angeles` 账户/时区读取，`DATE` 值不变。三条须进入 m6-gate.md 证据表。
- 交付物：实测矩阵 + m6-gate.md + tag。
- 依赖：M6.3 门禁、E.1#9。
- 验收：**至少两 provider 真机 round-trip 全绿方可发版**（提案 §9「必须验证的边界」第 6 条）；未实测 provider 在产品面标「实验/未验证」并列入 gate 未验证项。
- **provider 数与 CalDAV 顺延的口径裁断（CodeRabbit 问）**：①「至少两 provider」指**真机实测通过数**，不是「已实现数」——回放通过不计入。②CalDAV 若超期顺延 v0.4.1，**Google + Graph 两 provider 真机全绿仍满足 M6 门禁**，v0.4.0 按原计划发布，release notes 明写「CalDAV 顺延 v0.4.1」。③反向不允许：若只有 CalDAV 一家真机通过而 Google/Graph 均未实测，则 provider 数=1，**不足两 provider → 不发 v0.4.0**，整期按 B.3 第 6 条降级为「引擎+回放就绪」并记入 §15.1，v0.4.0 顺延待第二家真机通过。④顺延 v0.4.1 不改变 M6.0–M6.3 的验收有效性，只移动 M6.2-WP1 与 M6.4 的完成时点。
- 风险：外部账户未就绪则本期降级为「引擎 + 回放就绪、集成未验证」，按 B.3 第 5 条记入 §15.1 口径，不发 v0.4.0。[推演]

---

### M7 · 受控投影与撤销审计——估时合计 6–10 pd（2026-11-20 追加，v0.5.0）

> 依据：[proposals/commitments-calendar-integration.md](proposals/commitments-calendar-integration.md) §6.1 接入深度 3、§6.4、§9 首闭环第 6 条。期定位：向**独立 Sebas 日历**（或用户指定目标）写 WorkSession/截止标记，可整体启停、可审计、可整批撤销；不接管外部对象所有权。
> 期门禁：调度四条全绿 + 撤销与 fail-closed 实测。

**M7.0-WP1 投影/撤销批次契约定稿**（1 pd）
- 目标：写出去的每一笔都能整批收回。
- 范围：投影目标（独立 Sebas 日历优先）；批次身份（一次计划批次 = 一个撤销单元）；写幂等键；整体启停开关；审计字段（谁批的、写了什么、结果、撤销状态）；涉及他人默认需确认 [来源: 提案 §6.1、§6.4]。
- 交付物：契约文档短篇（并入 calendar-adapter-contract.md）。
- 依赖：M6.4 门禁。
- 验收：评审通过；每条写操作都能追溯到批次与批准人。
- **写权限账户依赖（CodeRabbit 问：M7 需要哪些 provider 账户）**：M7 与 M6 的账户需求**不同**——M6 只需只读 scope，M7 需**写权限**，因此不能复用 M6 的只读账户授权结论。首版目标为**独立 Sebas 日历**（提案 §6.1 深度 3），最小账户要求：①一个专门的 Sebas 日历（在 Google 或 CalDAV 上新建，**不复用用户主日历**，避免误写个人事务）；②该日历的写 scope（Google `calendar.events` 或 CalDAV 对该集合的写权限）；③撤销验证需要一个可清理的测试日历。以上并入 E.1#11；若 M7 开工前未就绪，M7.1-WP1 只交「写路径 + 幂等 spec（假 provider 回放）」，M7 门禁按 B.3 第 6 条列未验证项，**不发 v0.5.0**。
- 风险：无实质风险。

**M7.1-WP1 独立 Sebas 日历写路径 + 整体启停**（2–4 pd）
- 目标：WorkSession 与截止标记可投影，重复执行不重复写。
- 范围：写路径（新建/更新时间块与截止标记）；幂等键防重复；部分写失败标 `partial_failure` 不显示全量成功；整体启停（停用即不再写，已写按用户选择保留或清理）；能力探测失败则不写并 fail-closed。
- 交付物：写路径 + 幂等/部分失败 spec。
- 依赖：M7.0-WP1。
- 验收：同一 WorkSession 重放不产生第二事件；部分失败可见且可重试；无权限时不写。
- 风险：外部日历可能拒绝时间块粒度——首版允许多 WorkSession 合并为一块并在映射表记录。[推演]

**M7.1-WP2 批次撤销、审计与管理面**（2–3 pd）
- 目标：撤销覆盖整批，结果可见。
- 范围：整批撤销（逐条撤销 + 失败逐条可见）、审计查询（批次/时间/结果）、管理面命令（`projections.list/revoke`）、无权限或结果不确定 fail-closed。
- 交付物：撤销 + 审计 + 命令集 spec。
- 依赖：M7.1-WP1。
- 验收：撤销一批 5 条中 1 条失败时界面显示 4 成功 1 失败，不报全成功；撤销后映射表状态一致。
- 风险：外部已改动的对象撤销会丢用户手工修改——撤销前做版本比对，不一致标 `conflicted` 交用户决定。[推演]

**M7.2-WP1 M7 门禁与 v0.5.0 发布**（1–2 pd）
- 目标：期收口。
- 范围：提案 §9 第 6 条验收（明确授权后写入、展示同步与撤销结果）；`docs/design/review/m7-gate.md`；tag `v0.5.0`。
- 交付物：m7-gate.md + tag。
- 依赖：M7.1 门禁。
- 验收：撤销与 fail-closed 实测留证；发版说明列明「不做全字段/全对象双向」。
- 风险：无实质风险。

---

## B. 排期与门禁

### B.1 依赖 DAG（无环）

```text
M0: WP1 → WP2 → {WP3, WP4} → WP5 → {WP6, WP7} → WP8
M1: WP1 → WP2 → WP3 → {WP4, WP5} → WP6
    WP1 → {WP7, WP9}        （凭据/HTTP 与渠道并行）
    WP2+WP7 → WP8            （热更新依赖监督体+keyring）
M2: WP1 → WP2 → {WP3, WP5} → {WP4, WP6}
M3: WP1 → {WP2, WP3} ； WP1 → WP4 → WP5 → WP6（WP5 另依赖 M2-WP2/M1-WP9；WP6 另依赖 M1-WP8）
M4: WP0-1 → WP0-2 → WP1-1 → WP1-2 → WP1-3 → WP1-4 → WP1-5
    M4.2: WP2-1 → {WP2-2, WP2-4}；WP2-2 → WP2-3
    M4.3: WP3-1 → {WP3-2, WP3-3}
    M4.4: WP4-1 → {WP4-2, WP4-3}；{WP4-2, WP4-3} → WP4-4
    （期门禁为边界：M4.0→M4.1→M4.2→M4.3→M4.4 串行）
M5: WP0-1 → WP0-2 → WP1-1 → WP1-2 → WP1-3 → WP1-4
    M5.2: {WP1-3, WP1-4} → WP2-1 → {WP2-3, WP2-4}；{WP2-1, WP2-3} → WP2-2
    M5.3: WP2-1 → WP3-1 → WP3-2；{WP1-3, WP1-4} → WP3-3；WP3-1~WP3-3 → WP3-4
    （期门禁为边界：M5.0→M5.1→M5.2→M5.3→M5.4 串行）
M6: WP0-1 → WP1-1 → WP1-2
    M6.2: 三 provider 各自 WP1-2 → {WP2-1, WP2-2, WP2-3}（彼此无依赖）
    M6.3: {WP2-1, WP2-2, WP2-3} → WP3-1 → WP3-2 → WP4-1
    （期门禁为边界：M6.0→M6.1→M6.2→M6.3→M6.4 串行）
M7: WP0-1 → WP1-1 → WP1-2 → WP2-1
```

自查：全部边单向、无回边、无跨期回依赖（M2–M7 包仅依赖本期或前期包），**无环**；M4 期边界串行、期内依赖详 A 节 M4 各包「依赖」字段；M5–M7 期内依赖详上文各包「依赖」字段。[推演]

**跨期长边（唯一三条，均为前置期已完成件）**：M5.0-WP2「design.md §14 追加 M5–M7 行」依赖 M4.0-WP2（#40）先合入同一 §14 区域——若不串行，两次改同表必冲突；M5.2-WP2 依赖调度轨 E.1#8；M7.0-WP1 依赖 M6 门禁。三条边方向均为「后指向先」，不构成环。[推演]

**口径注（S1 修正）**：B.1 图为**排期顺序口径**（表达可并行块与开工次序）；**硬依赖以各 WP「依赖」字段为准**——图与字段存在三处边宽严不一（M0-WP3 图列 WP2 后序而字段仅依赖 WP1；M0-WP5 图含 WP4 前序而字段为 WP2+WP3；M1-WP8 图未画 WP1 直连而字段含 WP1），均为「图严于字段」方向的排期保守，不构成环，**冲突时以字段口径为权威**。[推演]

### B.2 逐周排期（5 pd/周，区间口径）

| 期 | 估时合计 | 周区间 | 周号（顺延，含前序溢出） |
|---|---|---|---|
| M0 | 17–25 pd | 3.5–5 周 | W1–W5/W6 |
| M1 | 19.5–30 pd | 4–6 周 | W5/W6–W11 |
| M2 | 12.5–19 pd | 2.5–4 周 | W11/W12–W15 |
| M3 | 15–24 pd | 3–5 周 | W15/W16–W20/W21 |
| M4 | 27.5–44.5 pd | 5.5–9 周 | W20/W21–W29/W30 |
| M5 | 22–36 pd | 4.5–7.5 周 | W29/W30–W36/W37 |
| M6 | 20–34 pd | 4–7 周 | W36/W37–W43/W44 |
| M7 | 6–10 pd | 1.5–2 周 | W43/W44–W45/W46 |
| **M0–M3 小计** | **64–98.5 pd** | **13–20 周** | **W1–W20/W21** |
| **总计（M0–M4）** | **91.5–143 pd** | **18.5–29 周** | **W1–W29/W30** |
| **总计（M0–M7）** | **139.5–223 pd** | **28–45 周** | **W1–W45/W46** |
| +缓冲（M0–M3 口径） | +0–10 pd（Tessell 口径） | +0–2 周 | 总 64–108.5 pd ≈ W1–W22 |
| +缓冲（含 M4） | +0–10 pd（Tessell 口径） | +0–2 周 | **总 91.5–153 pd ≈ W1–W31** |
| +缓冲（含 M5–M7） | +0–10 pd（Tessell 口径） | +0–2 周 | **总 139.5–233 pd ≈ W1–W47** |

算术自查：M0=17–25、M1=19.5–30、M2=12.5–19 沿用已验收 WBS；M3 下限 1+1.5+2+4+4+3=15.5、上限 1.5+2+3+6+6+5=23.5（WP4/5 因 DSL/21 hook 各 +1 pd，包与生命周期此前已 +1.5–2.5 pd）；总和精确下 17+19.5+12.5+15.5=64.5、上 25+30+19+23.5=97.5。下表 M3 按对外区间取整为 15–24，故取整合计为 64–98.5；含精确缓冲上限 107.5 pd（107.5/5=21.5 周，保守进位 W22）。各期之间允许上一期末溢出顺延（周区间首端重叠表达此意），不做并行压缩。[推演] M4 期排期与算术自查详见 B.8.4（2026-11-20 追加）；M4 入总计时以包区间 27.5–44.5 pd 为准（小计 64.5+27.5=92，取整口径 64–98.5 + 27.5–44.5 → 总 91.5–143 pd，见 B.8.4 复算）。[推演]

**M5–M7 入总计的算术（2026-11-20 追加）**：M5 22–36、M6 20–34、M7 6–10 → 新增 48–80 pd；与 M0–M4 的 91.5–143 pd 并计 = **139.5–223 pd**。周换算：139.5/5=27.9 → 28 周；223/5=44.6 → 45 周。对外表述取 **28–45 周**，末周 W45/W46（W46 为区间上界的保守进位）。含缓冲 +0–10 pd → 233/5=46.6 → **W1–W47**。M5–M7 内部算术详见 B.9.4。[推演]

### B.3 里程碑门禁（M-gate）

每期 M-gate 须**全部**满足（缺一不过）：

1. 该期全部 WP 验收标准逐条有可复现证据（命令输出/spec 通过记录）。
2. design.md §14 该期验收条目逐条勾稽（本文 A 节各 WP 已逐条映射，验收时按勾稽表核对）。
3. 质量三命令：`crystal spec` 0 fail、`./bin/ameba` 无警告、`make release` 成功 [来源: 仓库:CLAUDE.md]。
4. docs 同步：实现行为与 design.md/本文档一致，偏差处回写设计文档（CLAUDE.md 规矩 1）。
5. 风险复核：该期新增风险/未验证项进入 §15.1 口径记录（回写 design.md）。

阶段门禁 Go/No-Go 判据：M0 若强杀恢复不达标 → No-Go 返工 WP3/WP8；M1 若双账号串扰 → No-Go 返工 WP1（不接受「演示绕过」）；M3 若 mrb.cr 复核不可用**或 Windows 新 mruby.exe 链接环境 blocker 未消项**（恢复路径见 [review/m3-plugin-feasibility.md](review/m3-plugin-feasibility.md)）→ WP4~WP6 降级为技术预研 Go，降级证据 = 可行性报告与本机链接失败复现记录，产品化验收延至 blocker 消项后重跑（见 M3-WP4 风险）。[推演]

**M4 期门禁口径（Q7 裁断，2026-11-20 追加）**：M4.0–M4.4 各期 M-gate 沿用上述五项框架（§14 勾稽/docs 同步/质量命令/风险复核照旧），第 3 条质量命令改为「调度四条」全绿：`make format-check` + `crystal spec` + `make lint` + `make release` [来源: 仓库:docs/design/proposals/session-input-scheduling.md:215 调度提案先例]；纯文档包（M4.0）以「评审通过」（用户）替代命令门禁。M4 期 Go/No-Go 判据：M4.1 若 fork e2e 不达（分身未跑/回写丢/键漂移）→ No-Go 返工 WP2/WP3；M4.2 若 L3 审批拦截 fail-open → No-Go 返工 WP3（不接受「仅 hardline 拦截」降格）；M4.4 若回收 GC 无人工确认 → No-Go 返工 WP3。上文三命令口径（:473）及其 CLAUDE.md 失效引用在 M4.0-WP2 一并修正。[推演]

**M5–M7 期门禁口径（2026-11-20 追加）**：三期各期 M-gate 沿用五项框架，第 3 条质量命令统一为「调度四条」全绿：`make format-check` + `crystal spec` + `make lint` + `make release`（M4 已确立，M5–M7 沿用以保持口径一致）；纯文档包（M5.0、M6.0、M7.0）以「评审通过」替代命令门禁。**期门禁新增两条硬约束**：

6. **未实测不计入验收**：M6.4/M7.1 涉及的 provider 若无真机 round-trip 证据，只能计「引擎/回放就绪」，产品面须标「实验/未验证」，并记入 design.md §15.1 口径；未实测越界当已测即 No-Go。
7. **非目标拒绝口径**：任何包若引入提案 §8 所列非目标（全功能日历、默认全量双向、自动重排多人会议、以红点代替处理、把送达当完成），验收直接 No-Go，不接受「先实现再收敛」。

阶段门禁 Go/No-Go 判据：**M5** 若「同意图最多一个未决通知」仅靠应用层检查而无 DB 约束、或「无变化连续三轮零投递」不成立 → No-Go 返工 WP1-2/WP2-1；**M6** 若外部变化直接改动 WorkSession 或直接发通知（绕过评估器）→ No-Go 返工 WP3-1，不接受「仅同步层无副作用」降格；**M7** 若整批撤销失败时界面仍报全成功，或投影写入无幂等键 → No-Go 返工 WP1-1/WP1-2。[推演]

**期内子门禁的效力裁断（M5.1/M5.2/M5.3、M6.2/M6.3 等「{Mx.y} 门禁」字样）**：期内子门禁是**开工闸**而非发版闸——作用是「下一个包能否开工」，判定材料只需该子期各包的 WP 验收证据齐全（spec 全绿 + 交付物存在），**不含**真机 round-trip、不做 §14 勾稽、不出独立 gate 文档。发版闸只有期级的 M5.4/M6.4/M7.2 三处，它们才适用上述五项 + 两条硬约束。这样 M6.3/M6.4 的依赖链（M6.2 门禁 → M6.3 → M6.4）与 B.3 第 6 条不冲突。[推演]

**M6.2 开工闸的构成与 CalDAV 顺延口径（CodeRabbit 问）**：M6.2 门禁 = 下列三项同时成立，缺一即 M6.3 不得开工：①三 provider 适配器的**回放 spec 全绿**（录制文件入库、可离线重放）；②`calendar-adapter-contract.md` 中的**能力矩阵草表**逐格填实，无「假设支持」空格；③三 provider 的**同步元数据映射表**（六类元数据 → 各家字段）写完并与 M6.1-WP2 的游标二元组对齐。**真机实测不进 M6.2 门禁**，一律归 M6.4——因此「M6.2 回放通过」不构成「已实测」。**CalDAV 顺延口径**：若 M6.2-WP1 拆去 v0.4.1，M6.3 的开工闸改判为「Google + Graph 两家的 ①②③ 成立」即可，**不要求 M6.2-WP1**；随 CalDAV 一并移入 v0.4.1 的条目是 M6.2-WP1（CalDAV 适配器）与其在 M6.4 中的真机 round-trip 段及对应矩阵行，其余（M6.2-WP2/WP3、M6.3、M6.4 的 Google/Graph 段）留在 v0.4.0 不动。[推演]

---

## B.4 M0 门禁结论（2026-11-19）

M0 三条验收全过（收发全链路 / 强杀续跑 / 发信幂等），门禁三命令绿；证据与边界记录见 [review/m0-gate.md](review/m0-gate.md)。真实邮箱集成验收挂外部依赖 E.1（用户测试邮箱未就绪），协议层已按假服务器全链路验证。M1 允许开工。

## B.5 M1 门禁结论（2026-11-19）

M1 九包全部落地；§14 M1 七条验收全过（N 账号不串扰 / receiveid / token 刷新重取 / 限流退避 / 热更新三态 / 端口 restart 提示），门禁三命令绿；证据见 [review/m1-gate.md](review/m1-gate.md)。企微 AIBot 主路（§15.1.1 首日核对）与飞书 WS 帧协议（对照官方 SDK 核对）为真实账号集成前置，回调/webhook 形态已协议完整；不阻塞 M2 开工。

## B.6 M2 门禁结论（2026-11-19）

M2 六包全部落地；§14 M2 四条验收全过（崩溃重放幂等 / 审批超时 deny 注入时钟实测 / 预算熔断留痕 / runs 回放审计），门禁三命令绿；证据见 [review/m2-gate.md](review/m2-gate.md)。期间关键缺陷回写：intents_with_prefix LIKE 参数漏传（已修，详见 m2-gate.md）。M3 允许开工。

## B.7 M3 门禁结论（2026-11-19）

M3 WP1/2/3 验收全过（max_hops=4 拦截互发死循环 / 并发上限排队不失控 / subagent 崩溃经 ownerTaskId 找回同一子任务），门禁三命令绿。WP4~6（mrb.cr 插件层）按 B.3 预设条款降级为技术预研：mrb.cr 甄别通过（84/84）但本机 Windows 工具链当日无法链接新 mruby.exe（环境级 blocker，恢复路径已列），架构与构件（sebas-stdio gem、build_config 补丁、子进程沙盒解释器方案）已产出——详见 [review/m3-plugin-feasibility.md](review/m3-plugin-feasibility.md) 与 [review/m3-gate.md](review/m3-gate.md)。M0–M2 全部产品化验收保持有效。

## B.8 M4 期排期与执行分块（2026-11-20 追加，Q9）

### B.8.1 提案原号 ↔ M4.x 映射（防撞名：仓内 M1–M3 已存在）

| 提案原号 | 内容 | 重编 | 轴覆盖 |
|---|---|---|---|
| M0.5 | fork/join 语义文档评审定稿 + 吸收回写 | M4.0 | 轴③基座 |
| M1 | 生产装配补齐 + 一级 Fork 只读分身最小闭环 | M4.1 | 轴③主线 |
| M2 | 文件写 + 副作用冲突 + 能力衰减 + secrets 收敛 | M4.2 | 轴③主线 |
| M3 | 对话流内自然 Fork（ReAct 前置）+ 前台接待 | M4.3 | 轴③ + 轴①轻 |
| M4 | 双轨统一 + 模板库/角色卡 + 休眠/归档/回收 | M4.4 | 轴①重 + 轴② |

三轴覆盖自查（验收标准 3）：轴①=M4.3-WP3（前台接待）+ M4.4-WP3（生命周期治理）各一包；轴②=M4.4-WP1/WP2；轴③=M4.1–M4.3 全部主线包。三轴各有至少一包落位。[推演]

### B.8.2 M4 期级排期（相对周 = M4 开工后第 N 工作周，禁止绝对日期）

| 期 | 估时合计 | 周区间 | 包数 |
|---|---|---|---|
| M4.0 | 1.5–2.5 pd | 0.5 周 | 2 |
| M4.1 | 8–13 pd | 1.5–2.5 周 | 5 |
| M4.2 | 6–10 pd | 1–2 周 | 4 |
| M4.3 | 5–8 pd | 1–1.5 周 | 3 |
| M4.4 | 7–11 pd | 1.5–2 周 | 4 |
| **M4 合计** | **27.5–44.5 pd** | **5.5–9 周** | **18** |

全程序顺延坐标（B.2 表）：M3 止于 W20/W21 → M4 占 W20/W21–W29/W30；含缓冲总 91.5–153 pd ≈ W1–W31。

### B.8.3 M4 执行周块表（单人全职 5 pd/周；溢出顺延 W*+1-D1，不压缩范围）

| 块 | 包（预估 pd） | 块内合计 |
|---|---|---|
| W1（块容量 5 pd） | M4.0-WP1 评审定稿 0.5–1；M4.0-WP2 吸收回写+失效引用修正 1–1.5；M4.1-WP1 装配补齐+入队键修复 1.5–2.5 | 3–5 pd |
| W2（块容量 5 pd） | M4.1-WP2 expectations 表+判定器 2–3；M4.1-WP3 ForkManager+分身执行体 2–3 | 4–6 pd |
| W3（块容量 5 pd，含承接 W2 溢出 ≤1 pd） | M4.1-WP4 JoinWriter+四时机 1.5–2.5；M4.1-WP5 DSL/IPC/HTTP 触发面+e2e 1–2 | 2.5–4.5 pd |
| W4（块容量 5 pd） | M4.2-WP1 能力衰减 1.5–2.5；M4.2-WP2 四级+冲突 2–3 | 3.5–5.5 pd |
| W5（块容量 5 pd，含承接 W4 溢出 ≤0.5 pd） | M4.2-WP3 approvals 接线 1.5–2.5；M4.2-WP4 secrets 收敛 1–2 | 2.5–4.5 pd |
| W6（块容量 5 pd） | M4.3-WP1 ReAct 循环 2–3；M4.3-WP2 对话流内 fork 1.5–2.5 | 3.5–5.5 pd |
| W7（块容量 5 pd，含承接 W6 溢出 ≤0.5 pd；块留白即 M4.3 门禁与真实场景验证缓冲） | M4.3-WP3 前台接待 1.5–2.5 | 1.5–2.5 pd |
| W8（块容量 5 pd） | M4.4-WP1 双轨统一 2–3；M4.4-WP2 模板库+角色卡 2–3 | 4–6 pd |
| W9（块容量 5 pd，含承接 W8 溢出 ≤1 pd） | M4.4-WP3 sessions 表+休眠/归档/回收 2–3；M4.4-WP4 管理面扩展 1–2 | 3–5 pd |
| **总表尾** | +缓冲 | **+0–10 pd（Tessell 口径）≈ +0–2 周** |

溢出顺延注：W2 块内上限 6 pd 超容量 ≤1 pd → 顺延 W3-D1，不压缩 WP3 spec 范围；W4 上限 5.5 超 ≤0.5 → 顺延 W5-D1；W6 上限 5.5 超 ≤0.5 → 顺延 W7-D1；W8 上限 6 超 ≤1 → 顺延 W9-D1。其余块上限 ≤5 pd 无溢出。

### B.8.4 M4 算术自查（两套数字同步复算，B.2 原口径）

包合计=期合计：M4.0 下 0.5+1=1.5 / 上 1+1.5=2.5；M4.1 下 1.5+2+2+1.5+1=8 / 上 2.5+3+3+2.5+2=13；M4.2 下 1.5+2+1.5+1=6 / 上 2.5+3+2.5+2=10；M4.3 下 2+1.5+1.5=5 / 上 3+2.5+2.5=8；M4.4 下 2+2+2+1=7 / 上 3+3+3+2=11。**M4 总 = 27.5–44.5 pd，18 包，每包 ≤3 pd**（验收标准 3）✓。
块-包对账：18 包全落块（W1×3、W2×2、W3×2、W4×2、W5×2、W6×2、W7×1、W8×2、W9×2 = 18）✓；块上限仅 W2/W4/W6/W8 四处超容量且均已附顺延注（B.8.3），其余块 ≤5 pd ✓。
依赖序：M4.0(W1)→M4.1(W1–W3)→M4.2(W4–W5)→M4.3(W6–W7)→M4.4(W8–W9) 期边界串行无回边（B.1 图）✓。
周换算：27.5/5=5.5 周、44.5/5=8.9 周 → 5.5–9 周；块表 9 周含 W7 门禁留白 ✓。
全程序合计（B.2 表复算）：M0–M3 小计 64–98.5 + M4 27.5–44.5 = **91.5–143 pd**；周 13–20 + 5.5–9 = **18.5–29 周**；含缓冲 +0–10 pd → 总 91.5–153 pd ≈ W1–W31（153/5=30.6 保守进位）。B.2 精确口径旁注（M0–M3 精确 64.5–97.5）：精确并计 92–142 pd，对外取整 91.5–143，两式均在区间内一致。[推演]

## B.9 M5–M7 期排期、执行分块与版本计划（2026-11-20 追加）

> 本节对应 [proposals/commitments-calendar-integration.md](proposals/commitments-calendar-integration.md) 的落地排期。周号沿用 B.2 的**相对周**口径（M5 开工后第 N 工作周，禁止绝对日期）；容量 5 pd/周，溢出顺延下一块 D1–D2，**不压缩范围**（与 B.8.3 同款规则）。

### B.9.1 期级排期表

| 期 | 估时合计 | 周区间 | 包数 | 版本 |
|---|---|---|---|---|
| M5.0 语义与契约 | 2–3 pd | 0.5 周 | 2 | 随 v0.3.0 |
| M5.1 持久唤醒底座 | 8–13 pd | 1.5–2.5 周 | 4 | 随 v0.3.0 |
| M5.2 评估与投递 | 6–10 pd | 1–2 周 | 4 | 随 v0.3.0 |
| M5.3 捕获/管理面/cron 归位 | 5–8 pd | 1–1.5 周 | 4 | 随 v0.3.0 |
| M5.4 门禁与发版 | 1–2 pd | 0.5 周 | 1 | **v0.3.0** |
| **M5 合计** | **22–36 pd** | **4.5–7.5 周** | **15** | |
| M6.0 适配器契约 | 1–2 pd | 0.5 周 | 1 | 随 v0.4.0 |
| M6.1 镜像与同步引擎 | 5–8 pd | 1–1.5 周 | 2 | 随 v0.4.0 |
| M6.2 三 provider 适配器 | 9–15 pd | 2–3 周 | 3 | 随 v0.4.0 |
| M6.3 变化驱动重估 | 3–5 pd | 0.5–1 周 | 2 | 随 v0.4.0 |
| M6.4 真机验证与发版 | 2–4 pd | 0.5 周 | 1 | **v0.4.0** |
| **M6 合计** | **20–34 pd** | **4–7 周** | **9** | |
| M7.0 投影契约 | 1 pd | 0.5 周 | 1 | 随 v0.5.0 |
| M7.1 写路径/撤销/审计 | 4–7 pd | 1–1.5 周 | 2 | 随 v0.5.0 |
| M7.2 门禁与发版 | 1–2 pd | 0.5 周 | 1 | **v0.5.0** |
| **M7 合计** | **6–10 pd** | **1.5–2 周** | **4** | |
| **M5–M7 合计** | **48–80 pd** | **10–16 周** | **28** | v0.3.0/v0.4.0/v0.5.0 |

### B.9.2 执行周块表（M5：8 块）

| 块 | 包（预估 pd） | 块内合计 |
|---|---|---|
| M5-W1 | M5.0-WP1 语义定稿 1–1.5；M5.0-WP2 时间语义+DDL 草案 1–1.5；M5.1-WP1 迁移器 1–2 | 3–5 pd |
| M5-W2 | M5.1-WP2 四表+仓储 2–3；M5.1-WP3 持久调度 3–5 | 5–8 pd（**上限超容量 3 pd → 溢出顺延 M5-W3**） |
| M5-W3 | 承接 M5-W2 溢出 0–3；M5.1-WP4 Run 恢复 2–3 | 2–6 pd（**上限 6 pd 超容量 1 pd → 顺延 M5-W4-D1**；不压缩 WP4 spec 范围） |
| M5-W4 | M5.2-WP1 评估器 2–3；M5.2-WP2 admission 接线 1–2 | 3–5 pd（**上限承接 W3 溢出 1 pd → 6 pd，超容量 1 pd → 顺延 M5-W5-D1**） |
| M5-W5 | M5.2-WP3 Delivery 状态机 2–3；M5.2-WP4 Today 视图 1–2 | 3–5 pd（**上限承接 W4 溢出 1 pd → 6 pd，超容量 1 pd → 顺延 M5-W6-D1**） |
| M5-W6 | M5.3-WP1 一句话捕获 1–2；M5.3-WP2 管理面 1–2 | 2–5 pd（承接 W5 溢出 0–1 pd；上限 5 pd 恰好用尽，**溢出链在此收敛**） |
| M5-W7 | M5.3-WP3 cron 归位 2–3；M5.3-WP4 文档+CHANGELOG 1 | 3–4 pd |
| M5-W8 | M5.4-WP1 门禁与 v0.3.0 发布 1–2 | 1–2 pd（含门禁留白 3–4 pd） |

溢出注（逐块算术，B.8.3 同款规则；**溢出链逐块传递，直到某块上限有余量为止**）：
- M5-W2：2–3 + 3–5 = **5–8 pd**，上限超容量 3 pd → 溢出 3 pd 顺延 M5-W3-D1~D3，不压缩 M5.1-WP3 spec 范围。
- M5-W3：承接 0–3 + 2–3 = **2–6 pd**，上限超容量 1 pd → 溢出 1 pd 顺延 M5-W4-D1。
- M5-W4：承接 0–1 + 3–5 = **3–6 pd**，上限超容量 1 pd → 溢出 1 pd 顺延 M5-W5-D1。
- M5-W5：承接 0–1 + 3–5 = **3–6 pd**，上限超容量 1 pd → 溢出 1 pd 顺延 M5-W6-D1。
- M5-W6：承接 0–1 + 2–4 = **2–5 pd**，上限恰为容量 5 pd → **溢出链收敛**，不再后传；M5-W7/W8 不再承接。
- M5-W7（2–4）、M5-W8（1–2）上限均 ≤5 pd，无溢出。
- 链式结论：上界情形下 M5 实际需要 8 块 + 累计顺延 1 pd（W4-D1、W5-D1、W6-D1 各 1 天，最后一天落在 W6 块内被吸收），与 B.9.4 的 7.2 周上界一致（8 块含门禁留白）。**每块内均不压缩 spec 范围**，只顺延日期。

### B.9.3 执行周块表（M6：7 块 / M7：2 块）

| 块 | 包（预估 pd） | 块内合计 |
|---|---|---|
| M6-W1 | M6.0-WP1 适配器契约 1–2；M6.1-WP1 ExternalLink 表 2–3 | 3–5 pd |
| M6-W2 | M6.1-WP2 增量同步引擎 3–5 | 3–5 pd |
| M6-W3 | M6.2-WP1 CalDAV 适配器 3–5 | 3–5 pd |
| M6-W4 | M6.2-WP2 Google 适配器 3–5 | 3–5 pd |
| M6-W5 | M6.2-WP3 Graph 适配器 3–5 | 3–5 pd |
| M6-W6 | M6.3-WP1 重估链路 2–3；M6.3-WP2 隐私/失败语义 1–2 | 3–5 pd |
| M6-W7 | M6.4-WP1 真机 round-trip + v0.4.0 2–4 | 2–4 pd（含验证留白 1–3 pd） |
| M7-W1 | M7.0-WP1 投影契约 1；M7.1-WP1 写路径+启停 2–4 | 3–5 pd |
| M7-W2 | M7.1-WP2 撤销+审计 2–3；M7.2-WP1 门禁与 v0.5.0 1–2 | 3–5 pd |

### B.9.4 算术自查

包合计=期合计：M5.0 下 1+1=2 / 上 1.5+1.5=3；M5.1 下 1+2+3+2=8 / 上 2+3+5+3=13；M5.2 下 2+1+2+1=6 / 上 3+2+3+2=10；M5.3 下 1+1+2+1=5 / 上 2+2+3+1=8；M5.4 下 1 / 上 2 → **M5 = 22–36 pd，15 包**。
M6.0 下 1 / 上 2；M6.1 下 2+3=5 / 上 3+5=8；M6.2 下 3+3+3=9 / 上 5+5+5=15；M6.3 下 2+1=3 / 上 3+2=5；M6.4 下 2 / 上 4 → **M6 = 20–34 pd，9 包**。
M7.0 下 1 / 上 1；M7.1 下 2+2=4 / 上 4+3=7；M7.2 下 1 / 上 2 → **M7 = 6–10 pd，4 包**。
**三段合计 48–80 pd、28 包，每包 ≤5 pd**（M5.1-WP3 与 M6.2 三包取 5 pd 上限，其余 ≤4）✓。

块-包对账：M5 15 包 = W1×3 + W2×2 + W3×1 + W4×2 + W5×2 + W6×2 + W7×2 + W8×1 = 15 ✓；M6 9 包 = W1×2 + W2×1 + W3×1 + W4×1 + W5×1 + W6×2 + W7×1 = 9 ✓；M7 4 包 = W1×2 + W2×2 = 4 ✓。块上限超容量**四处**（M5-W2 超 3、M5-W3 超 1、M5-W4 超 1、M5-W5 超 1），构成一条逐块传递的溢出链，**在 M5-W6 收敛**（上限 5 pd 恰用尽容量，不再后传）；每处均已附顺延注且只顺延日期、不压缩 spec 范围。M5-W7（≤4）、M5-W8（≤2）与 M6/M7 全部块上限 ≤5 pd ✓。
周换算：22/5=4.4、36/5=7.2 → **4.5–7.5 周**；20/5=4、34/5=6.8 → **4–7 周**；6/5=1.2、10/5=2 → **1.5–2 周**；三期合计 9.6–16.2 → **10–16 周**，块表 8+7+2=**17 块**（含门禁/验证留白）✓。
全程序：M0–M4 91.5–143 + M5–M7 48–80 = **139.5–223 pd**；周 18.5–29 + 10–16 = **28–45 周**（保守取整至 45.5）；含缓冲 +0–10 pd → 233 pd ≈ **W1–W47** ✓（与 B.2 表末两行一致）。

### B.9.5 版本计划与 milestone 口径

| 版本 | 期 | 内容 | 发布条件 | 备注 |
|---|---|---|---|---|
| v0.3.0 | M5 | 持久意图 + 唤醒基础设施 + 提醒闭环（**纯内部，无外部集成**） | M5 门禁 + 提案 §9 首闭环第 1/2/4/5 条有可复现证据 | 与 M6 解耦，可独立发版；不并入 v0.2.0 |
| v0.4.0 | M6 | 外部只读镜像 + 显式关联 + 变化驱动重估（CalDAV/Google/Graph） | M6 门禁 + **至少两 provider 真机 round-trip** | 未实测 provider 降级为「实验」；CalDAV 若超期则拆 v0.4.1，不阻塞 v0.4.0 |
| v0.5.0 | M7 | 受控投影（独立 Sebas 日历）+ 整批撤销 + 审计 | M7 门禁 + 提案 §9 第 6 条（授权后写、展示同步与撤销结果） | 首版不做全字段/全对象双向 |

milestone 口径：
1. **一座版本一座 milestone**（v0.3.0 / v0.4.0 / v0.5.0），描述模板照 #2（目标/门禁/周期/发版/范围）。
2. **期父卡挂 milestone，子卡随父卡**：issue 侧建 3 张父卡（M5/M6/M7 各一）+ 28 张子卡（=B.9.1 的 28 包），父子关系用 sub-issues 建立，子卡 milestone 与父卡一致。
3. **不并入 v0.2.0**：该 milestone 尚有 fork/join 轨 29 张未清，混入会让发版门禁不可控（B.2 的 M4 期边界串行同理）。
4. **发版动作**：milestone 内 issue 清零 → 打 tag（`v0.3.0`/`v0.4.0`/`v0.5.0`）触发既有 release workflow [来源: 仓库:CLAUDE.md 发版口径]；src/version.cr 与 CHANGELOG 同批改。
5. **已发布到 GitHub（2026-11-20）**：milestone #3 `v0.3.0 (承诺与提醒闭环)`（16 卡：父卡 #91 + M5.0–M5.4 共 15 子卡 #63–#77）、#4 `v0.4.0 (外部日历只读镜像与重估)`（10 卡：父卡 #92 + #78–#86）、#5 `v0.5.0 (受控投影与撤销审计)`（5 卡：父卡 #93 + #87–#90）；父卡与子卡均带 `enhancement` + `plan` 标签，sub-issues 关系 15/9/4 全部建立。

---

## C. 首迭代执行计划（W1–W2）

> 目标：交付 M0 骨架与首条纵深（配置→持久层开工），并完成影响 M1 排期的两项前置冒烟。单人全职，块容量 5 pd/周。

| 块 | 任务 ID | 对应 WP | 内容 | 交付物 | 验证方式 | 预估（pd） | 依赖 |
|---|---|---|---|---|---|---|---|
| W1-D1 | EX-W1-01 | M0-WP1 | 基线记录：`crystal --version`、空仓 `crystal spec`/`./bin/ameba`/`make release` 试跑 | 基线记录 | 命令输出可复现 | 0.5 | 无 |
| W1-D1~D2 | EX-W1-02 | M0-WP1 | 项目骨架：shard.yml、§13 目录空实现、构建脚本、统一日志 | 可编译单二进制骨架 | 三命令全绿；`--version` 可执行 | 1–1.5 | EX-W1-01 |
| W1-D2~D3 | EX-W1-03 | 前置冒烟 | **Atomic(Config) 编译冒烟**（`Atomic#swap` 详注歧义实测，5 分钟级 [来源: design.md §15.1.8]）+ **naqvis/file_watcher Windows demo**（~10 行验证编辑器原子写事件语义 [来源: design.md §15.1.7]） | 冒烟记录二则（结果无论正负均回写 design.md §15.1 消项） | 编译/运行输出留档 | 0.5–1 | EX-W1-01 |
| W1-D3~D5 | EX-W1-04 | M0-WP2 | 配置加载与 schema：loader 纯函数校验器+宏样板 | config 模块+示例 YAML+spec | 坏配置报错含行号；合法配置出 typed 对象 | 1.5–2 | EX-W1-02 |
| W2-D1~D3 | EX-W2-05 | M0-WP3 | 持久层开工：SQLite WAL 四表+requestId 幂等+三明治次序 spec | store 模块+spec | 次序断言+排重用例通过 | 2.5–3 | EX-W1-04 |
| W2-D3~D5 | EX-W2-06 | M0-WP4 | email 适配器开工：IMAP IDLE（应用专用密码）+markdown 转换器【A8】 | channels/email+收信 spec | 真实邮箱收信入总线（集成口径） | 1.5–2.5 | EX-W1-04 |

- W1 块合计 3.5–5 pd（容量 5 内）；W2 块合计 4–5.5 pd，**超容量 ≤0.5 pd 顺延 W3-D1**，不压缩 EX-W2-05 spec 范围（Tessell 溢出规则同款）。[推演]
- EX-W2-06 集成测试依赖真实测试邮箱就绪——外部依赖第 1 项（E 节），须 W1 期间完成申请。

---

## D. 覆盖矩阵与开放问题

### D.1 design.md 16 章 → WP 映射（设计覆盖完整性自查）

| design.md 章节 | 实现承载 WP |
|---|---|
| §1 执行摘要 / §2 目标与非目标 | 全局：各 M-gate（非目标=不建，无 WP） |
| §3 三正交+路由+配置树 | M0-WP2（配置骨架）→ M1-WP1（数组化+路由） |
| §4 分层架构+Crystal 要点 | M0-WP5（总线/worker）→ M0-WP3（持久层）→ 各渠道/管理面 WP 分层落位 |
| §5 多账号（生命周期/三渠道） | M1-WP1~WP7 |
| §6 会话与记忆 | M0-WP3（FTS5+JSONL 双写）→ M0-WP6（记忆读写工具）→ M0-WP6b（SKILL.md 加载器，A7） |
| §7 编排 | M2-WP1~WP6 |
| §8 协作 | M3-WP1~WP3 |
| §9 管理面 | M0-WP7（NDJSON）→ M1-WP9（HTTP）→ M1-WP8（reload 命令）→ M2-WP6（runs API）→ M3-WP6（插件生命周期 API） |
| §10 安全模型 | M0-WP6（registry risk/replay）→ M1-WP7（keyring）→ M2-WP4（审批）→ M3-WP5（沙箱） |
| §11 配置热更新 | M1-WP8（+EX-W1-03 前置冒烟） |
| §12 插件脚本层 | M3-WP4（子进程/DSL/精确 action+hook 派发）→ M3-WP5（21 hook 注入与沙箱）→ M3-WP6（包与生命周期） |
| §13 目录结构 | 全 WP 的模块归属总表（A 节各包「范围」字段已逐一对齐 §13 目录；**skills/ 归 M0-WP6b、providers/ 归 M0-WP5 实例池骨架——原隐含承载现显式声明**） |
| §14 路线图 | 本计划 A/B 节本体（验收勾稽） |
| §15 风险 | E 节前置冒烟+各 WP 风险栏+M-gate 第 5 条 |
| §16 来源对照表 | 本文 0 节证据纪律（引用不升级） |
| 附录 5 项待决策 | 第 1 项已定名 Seneschal；附录 5 首批能力已定为工具/钩子/定时/受控 `memory.backend`，risk 只能由宿主策略调整（design.md §12.9）；附录 2 首渠道 email 已落地 |

自查：16 章全部有承载；§14 各期验收逐条落进 WP 验收，跨文档定位统一使用 design.md §14 对应期次，避免行号随修订漂移。[推演]

### D.1.1 提案 §→WP 映射（2026-11-20 追加，承诺与日历提案覆盖自查）

| 提案章节 | 实现承载 WP |
|---|---|
| §1 核心判断 / §2 七原则 | 全局：M5–M7 各期门禁（原则=不建，无 WP） |
| §3.1 最小捕获（Outcome/Source/跟进依据） | M5.3-WP1 |
| §3.2 九态生命周期 | M5.0-WP1（定稿）→ M5.1-WP2（落库） |
| §3.3 提醒纪律（一个未决通知/不重推/Snooze 形成新时间） | M5.1-WP2（DB 约束）→ M5.2-WP1（静默）→ M5.2-WP3（Delivery） |
| §3.4 Today 六段视图 + 日终四操作 | M5.2-WP4 |
| §4.1 十对象 | M5.0-WP1（语义）→ M5.1-WP2（四对象落库）→ M5.2-WP3（Delivery）→ M6.1-WP1（ExternalLink）→ M7.0-WP1（Projection） |
| §4.2 四类时间表示 / RRULE 原文保留 / DST | M5.0-WP2 |
| §5 cron 退到唤醒基础设施层 | M5.1-WP3（持久调度）→ M5.3-WP3（归位） |
| §6 三种接入深度 / 所有权矩阵 / 外部变化只触发评估 / 隐私与失败四态 | M6.0-WP1（能力矩阵与失败语义）→ M6.3-WP1（重估链路）→ M6.3-WP2（隐私落地）→ M7.0-WP1（深度 3 契约） |
| §7 canonical superset + 三 provider + 同步元数据六类 | M6.0-WP1 → M6.1-WP1/WP2 → M6.2-WP1/WP2/WP3 |
| §8 非目标 | B.3 第 7 条拒绝口径 |
| §9 首闭环七条 + 必须验证边界六条 | M5.4-WP1（第 1/2/4/5 条）、M6.4-WP1（第 3 条与边界六条）、M7.2-WP1（第 6 条） |
| §10 来源清单 | 本文各 WP 的 [来源: 仓库:path:line] 锚点（不单独设 WP） |

自查：提案 §1–§10 全部有承载；§9 七条首闭环保留第 7 条（「承认无解」的用户体验）由 M5.2-WP1 评估器的「请求审批/保持休眠」分支承接，不另设包。[推演]

### D.2 开放问题（计划视角发现，**不发明新设计决策**——设计变更归属 design.md 修订）

| # | 问题 | 建议归属 |
|---|---|---|
| 1 | Gmail 路线（附录 3）未决直接改变 M0-WP4 形态与估时：应用专用密码起步+2–3 pd，若首批即 Gmail API 则 M0-WP4 增 2–3 pd 且引入 GCP 外部依赖 | design.md 附录 3 用户决策；本计划按「专用密码起步」排期 |
| 2 | M0 期最小审批交互未在 design.md §14 M0 验收中显式列出，但 M0-WP6 发消息工具若 risk:high 触发审批，TUI 最小问答是 M0-WP7 隐含需求——已计入 WP7 范围，若用户希望 M0 全自动（approval.mode=off）则 WP7 减 0.5 pd | design.md 附录 4（审批默认模式）联动；本计划按「M0 含最小审批问答」排期 |
| 3 | TUI 选型（termisu vs 自写）需 M0-WP7 开工前 spike 定案，design.md 仅给候选未定 | M0-WP7 内含 0.5 pd spike，决策记录回写 design.md §16#33 |
| 4 | 企微 AIBot 主动发消息 API 未逐页核对（§15.1.1）：若开工首日核对发现 API 形态与笔记不符，回调备选升级为主路——估时已含回调完整实现，不扩 M1 区间，但 M1-WP4 的 demo 验收口径（长连接免公网卖点）可能降级 | M1-WP4 开工首日核对任务；结论回写 design.md §15.1.1 |
| 5 | ~~平台名【占位】~~ **已解决**：定名 **Seneschal**（[naming.md](naming.md) 14 候选撞名全核实）；若推翻，替换 design.md 与本文标题/附录中的「Seneschal」字样 | lead 裁断记录（naming.md） |
| 6 | **真实日历账户未就绪**：M6.4 的「至少两 provider 真机 round-trip」需要真实 Google/Graph/CalDAV 只读账户（E.1#9）。若 W1 期未申请，M6 只能交「引擎+回放」，v0.4.0 顺延——排期上表现为 M6.4 从 0.5 周膨胀到「无限等待」，**不可用估算吸收** | E.1#9（用户侧动作）；本计划按「M6 开工前两周申请」排期，逾期即触发 v0.4.0 顺延 |
| 7 | **CalDAV 与其他 provider 的顺序**：三 provider 可并行（B.1 无相互边），但 CalDAV 是「不受厂商 API 变更影响」的长期底座。若首要目标是稳定性应优先 CalDAV（M6-W3），若首要目标是先接自家账户应优先 Google/Graph。**排期表按 CalDAV→Google→Graph 顺序**，可在 W3 前调换而不改总估时 | 用户偏好；本计划按 CalDAV 优先 |
| 8 | **provider 估时普遍偏乐观**：M6.2 三包各 3–5 pd 基于「契约已定+回放测试」假设；实际 OAuth/scope 审批、分页边界、410 重建各可能 +1–2 pd。若三包同时上限，M6 由 20–34 上探至 30–40 pd（+1–2 周） | M6 期风险池（B.9.1 已按上限列）；不加缓冲到包内，超期则拆 v0.4.1 |
| 9 | **M5.2-WP2 与调度轨的耦合**：admission 接线依赖 #4/#5 完成或接口冻结（E.1#8）。若调度轨拖期，M5 的提醒投递无法与用户消息共用批次预算——降级方案是「提醒走独立通道并显式标注未并入 admission」，但会破坏提案 §2「先评估再打扰」的一致性 | #4/#5 轨道进度；本计划按 E.1#8 冻结口径排期，逾期则 M5 门禁列未验证项（冻结态不挡 v0.3.0，三条件见 M5.4-WP1） |
| 10 | **M7 写权限账户与 M6 只读账户不通用**：M7 需写 scope 且要一个专职 Sebas 日历（不复用主日历）。若沿用 M6 的只读授权结论，M7.1-WP1 会卡在真机段——该包只能用假 provider 回放，v0.5.0 无法发版 | E.1#11（用户侧动作）；本计划按「M7 开工前两周申请」排期，逾期 M7 门禁列未验证项、不发 v0.5.0 |

---

## E. 外部依赖与前置风险

### E.1 外部依赖（用户侧动作，不在估时内）

| # | 依赖 | 影响的 WP | 就绪时限 |
|---|---|---|---|
| 1 | 测试邮箱（应用专用密码开启） | M0-WP4 / EX-W2-06 集成验收 | W1 期间 |
| 2 | 企微测试企业+自建应用/AIBot 创建+可信 IP 配置（出口 IP 共享注意 §15.2.18 [来源: design.md:L784]） | M1-WP4 | M1 开工（约 W5/W6）前 |
| 3 | 飞书自建应用（WS 长连接仅自建应用可用 [来源: design.md §16#11]） | M1-WP5 | 同上 |
| 4 | Gmail 路线决策（若走 API：GCP 项目+OAuth 凭据） | M0-WP4 估时分叉 | EX-W2-06 开工前（最迟 W2-D3） |
| 5 | 调度轨 issue #9 WP1/WP2 已合或 admission/envelope 接口冻结（PR #32 已定型 policy/envelope/Store 单事务 admission；fork 入队为调度输入类型扩展——无渠道入站消息、无 sender/peer，Q5 迁就其接口）。注：WP1（contract+migration+纯函数状态机）已随 185e37b 合入 main，开工条件余 WP2 部分待满足 | M4.1 全期（ForkEnvelope 派发路径） | M4.1 开工前 |
| 6 | M4 语义/架构两提案文档评审（用户过目：fork-join-semantics.md + fork-join-shadow-clone-architecture.md） | M4.0-WP1 定稿 → M4.0-WP2 吸收回写 | M4.0 期内 |
| 7 | 插件演进 issue #24 启动条件（**引用不并卡**：见 [review/plugin-evolution.md](review/plugin-evolution.md)；其 P3 常驻 Worker 与模板库仅留交叉引用） | M4.4-WP2 模板库 | 无等待（非阻塞） |
| 8 | 调度轨 #4/#5 完成或 `admit_session_input`/envelope 接口冻结（现状：store 侧 DDL 与函数已存在但**全仓零调用者**，gateway 未接线 [来源: 仓库:src/platform/store/store.cr:453]；与 E.1#5 同源，此处按提醒投递视角复列） | M5.2-WP2（提醒与工作输入共用 admission） | M5.2 开工前（M5-W4） |
| 9 | 真实只读测试账户：Google Calendar（OAuth 只读 scope）、Microsoft 365 租户（Graph Calendars.Read + Tasks.Read）、一个 CalDAV 服务端（如 Fastmail/Nextcloud 测试账号） | M6.2 真机段 / M6.4 验收 | **M6 开工前两周**（M6-W1 前） |
| 10 | 承诺与日历语义文档评审（M5.0-WP1 产出 `commitments-calendar-semantics.md`，用户过目） | M5.0-WP2 起全部包 | M5-W1 期内 |
| 11 | **写权限日历账户**（M7 用，与 E.1#9 的只读账户不通用）：一个专门的 Sebas 日历（Google 或 CalDAV 新建，不复用主日历）+ 该集合写 scope + 一个可清理的撤销验证日历 | M7.1-WP1 真机段 / M7.2 门禁 | **M7 开工前两周**（M7-W1 前） |

### E.2 §15.1 未验证项中影响 M0/M1 排期的前置冒烟（逐条挑出）

| 条目 | 处置 | 落点 |
|---|---|---|
| 15.1.7 file_watcher Windows 实测 | ✅ **已完成**（2026-11-18）：watch 须对父目录+路径过滤；原子替换为 Created+Deleted+Renamed 三连，去抖聚合；[smoke-ex-w1-03.md](review/smoke-ex-w1-03.md) | EX-W1-03（结果回写 design.md §15.1.7） |
| 15.1.8 `Atomic(Config)` 编译冒烟 | ✅ **已完成**（2026-11-18）：reference type 全方法可用，详注歧义消项；[smoke-ex-w1-03.md](review/smoke-ex-w1-03.md) | EX-W1-03（结果回写 design.md §15.1.8） |
| 15.1.6 企微 crypto 官方测试向量 | WP 内验收自带（向量对称测试即消项） | M1-WP4 |
| 15.1.1 企微 AIBot API 未逐页核对 | **开工首日核对** 0.5–1 pd+demo；不符则回调备选升级（估时内含） | M1-WP4 |
| 15.1.9 换 secret 旧 token 失效行为 | 保守做法（TTL 自然过期+失效标记）不依赖该行为，不阻塞 | M1-WP3 |
| 15.1.2 Gmail IMAP IDLE 不可靠 | M0 单账号以「收到一封」为验收界；稳定性记录不阻塞门禁 | M0-WP4 |
| 15.1.10 mruby 运行形态与构建 | mrb.cr 84/84 甄别已完成；运行改为每动作子进程。本机新 mruby.exe 链接 blocker 未消项时 WP4~6 仍按降级条款交预研 | M3-WP4 |

不进 M0/M1 关键路径的其余未验证项（15.1.3 Gmail 15 连接、15.1.4 企微明文布局、15.1.5 飞书频控映射、15.1.11 Hermes reload 进度、15.1.12/13 OpenClaw 正文未取）不影响排期，实现到对应模块时按 design.md §15.1 原口径处置。[推演]

---

*（本文档为规划态：全部任务均为后续获授权执行时的验收标准，本文未执行任何代码工作；定名 Seneschal 已落盘（[naming.md](naming.md)），推翻则按 design.md:L846 替换指引执行。）*
