# Seneschal开发计划（WBS · 排期 · 门禁 · 首迭代）

> 文档职责：回答「怎么建」——M0-M3 工作包分解（WBS）、依赖与排期、里程碑门禁、首迭代逐任务执行清单、覆盖自查与前置风险。  
> 不负责什么：「是什么与怎么设计」见 [design.md](design.md)（850 行 16 章，已定稿）；本文件不重复设计论证，所有模块语义、机制选型、来源依据以 design.md 为准。  
> 与 design.md 的关系：本文 `M*-WP*` 工作包编号引用 design.md §13 目录结构与 §14 路线图验收条目；若实现中范围变化，须回写 design.md 对应章节。格式惯例沿用 Tessell 仓库已验收的 [plan.md](../../../tessell/docs/plan.md)（B 节 WBS）与 [plan-execution.md](../../../tessell/docs/plan-execution.md)（D 节执行分块）。

---

## 0. 输入与证据基线

| 输入 | 路径 | 关键事实 | 来源 |
|---|---|---|---|
| 设计主体 | [design.md](design.md) | 16 章：三正交概念/分层架构/多账号/编排/协作/管理面/安全/热更新(§11)/插件(§12)/目录结构(§13)/M0-M3 路线图(§14)/风险(§15)/来源对照表 41 条(§16)+附录 5 项待决策 | [来源: design.md:L1-L850] |
| 目录结构基线 | design.md §13 | src/{platform,config,bus,supervisor,store,keys}/+channels/routing/agents/orchestration/tools/providers/admin/plugins/ 模块划分与 A1-A10 承接表 | [来源: design.md:L688-L741] |
| 里程碑验收 | design.md §14 | M0-M3 各期验收要点+排期依据（热更新 M1、插件 M3） | [来源: design.md:L745-L756] |
| 风险与未验证 | design.md §15 | 未验证 13 条（15.1）/架构风险 7 条（15.2）/取舍 3 条（15.3） | [来源: design.md:L760-L792] |
| 质量门禁惯例 | 仓库 CLAUDE.md | `crystal spec` 全过 / `./bin/ameba` 无警告 / `make release` 成功 / 改动须同步 docs | [来源: 仓库:CLAUDE.md 质量标准节] |
| 格式范本 | tessell/docs/plan.md、plan-execution.md | `M*-WP*` 编号、pd 区间估算、相对周、EX-W1-01 执行分块、DoD 分层、状态与证据边界纪律 | [来源: 任务输入] |
| 平台命名 | design.md 附录 1 | **已定名 Seneschal**（[naming.md](naming.md) 14 候选撞名全核实；用户保留推翻权，推翻则全文再替换） | [来源: design.md:L846] |

**估算口径**：单人全职（每周 5 人日），工作量单位 **人日（pd）区间**；时间只用相对周 `W1/W2…`，禁止绝对日期；估算为「熟悉 Crystal 语言与 autobot 既有代码模式、渠道文档齐备且账号申请就绪」前提下的工程量，不确定性显式保留 `[未验证]`；禁止编造任何数字。各包估时含单测与门禁自检，不含渠道账号行政审批等待（外部依赖见 E 节）。

**证据标注纪律**：`[来源: design.md:Lx]` / `[来源: design.md §x]` / `[来源: 仓库:路径:行]` / `[来源: 任务输入]` / `[推演]` / `[未验证]`。引用 design.md 时其来源限定（「未验证/笔记推论/证据局限」）照抄不升级；本文新增的排期判断一律标 `[推演]`。

---

## A. WBS（M0-M3 工作包分解）

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

### M3 · 协作 + 插件脚本层——估时合计 11–18 pd

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

**M3-WP4 mrb.cr 集成基线**（3–5 pd）
- 目标：mruby 嵌入跑通（硬需求④载体）。
- 范围：`plugins/`：每插件独立 mrb_state 池、register(api) 契约、JSON-like 传值、gembox 裁剪构建（gembox 裁剪 mruby-io/socket [来源: design.md §12.3]）、plugins/*.rb 目录发现+manifest。
- 交付物：插件运行时+首个示例插件。
- 依赖：M3-WP1；**前置**：mrb.cr 84/0 提交状态复核+上游 issue #1 修复状态（15.1.10 [来源: design.md:L773]）——0.5 pd 甄别，若不可用则评估 vendored 快照方案（不扩 M3 总区间上限）。
- 验收：示例插件注册工具可被 agent 调用；**插件崩溃只重建该 state 不卡宿主**（§14 M3 验收第 5 条 [来源: design.md:L752]）。
- 风险：mrb.cr 维护状态（84/0 本地未提交）是 M3 最大不确定项——开工前复核，必要时 M3-WP4~WP6 整体降级为「技术预研」里程碑（门禁判据变为可行性报告而非产品化）。

**M3-WP5 沙箱三闸+watchdog**（2–4 pd）
- 目标：插件失控不伤宿主。
- 范围：三闸（gembox 裁剪已在 WP4、allocf 内存配额覆写、宿主 API 白名单）+watchdog 超时 [来源: design.md §16#39]。
- 交付物：沙箱配置+恶意插件测试样本（死循环/内存爆/未授权 API 调用三例）。
- 依赖：M3-WP4。
- 验收：**插件死循环被 watchdog 超时拦截不卡宿主**（§14 M3 验收第 4 条 [来源: design.md:L752]）；未授权 API 调用被白名单拒绝。
- 风险：allocf 覆写在 Crystal 编译链的实操未验证 [来源: design.md §12.3]——估时区间上限覆盖调通成本。

**M3-WP6 插件热重载与生命周期**（1.5–2.5 pd）
- 目标：改插件脚本免重启。
- 范围：整 VM 替换（mrb_close 重建+先验后换共用配置管线）[来源: design.md §16#41]。
- 交付物：热重载 spec。
- 依赖：M3-WP5、M1-WP8（共用触发-校验-换引用管线）。
- 验收：**改插件脚本热重载生效**（§14 M3 验收第 6 条 [来源: design.md:L752]）；重载期间在飞任务不受干扰。
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
M3: WP1 → {WP2, WP3} ； WP1 → WP4 → WP5 → WP6（WP6 另依赖 M1-WP8）
```

自查：全部边单向、无回边、无跨期回依赖（M2/M3 包仅依赖本期或前期包），**无环**。[推演]

**口径注（S1 修正）**：B.1 图为**排期顺序口径**（表达可并行块与开工次序）；**硬依赖以各 WP「依赖」字段为准**——图与字段存在三处边宽严不一（M0-WP3 图列 WP2 后序而字段仅依赖 WP1；M0-WP5 图含 WP4 前序而字段为 WP2+WP3；M1-WP8 图未画 WP1 直连而字段含 WP1），均为「图严于字段」方向的排期保守，不构成环，**冲突时以字段口径为权威**。[推演]

### B.2 逐周排期（5 pd/周，区间口径）

| 期 | 估时合计 | 周区间 | 周号（顺延，含前序溢出） |
|---|---|---|---|
| M0 | 17–25 pd | 3.5–5 周 | W1–W5/W6 |
| M1 | 19.5–30 pd | 4–6 周 | W5/W6–W11 |
| M2 | 12.5–19 pd | 2.5–4 周 | W11/W12–W15 |
| M3 | 11–18 pd | 2.5–4 周 | W15/W16–W19 |
| **总计** | **60–92 pd** | **12–19 周** | **W1–W19** |
| +缓冲 | +0–10 pd（Tessell 口径） | +0–2 周 | **总 60–102 pd ≈ W1–W21** |

算术自查：M0 下限 1+1.5+3+3+3+2+0.5+2+1=17、上限 2+2.5+4+4+4+3+1+3+1.5=25 ✓；M1 下限 2+1.5+2+3+2+1+1.5+4+2.5=19.5、上限 3+2.5+3+5+3+1.5+2.5+6+3.5=30 ✓；M2 下限 2+3+2+2+2+1.5=12.5、上限 3+4+3+3+3+2.5=19 ✓；M3 下限 1+1.5+2+3+2+1.5=11、上限 1.5+2+3+5+4+2.5=18 ✓；总和下 17+19.5+12.5+11=60、上 25+30+19+18=92 ✓；含缓冲上限 102 pd（102/5=20.4 周，保守进位 W21）✓。各期之间允许上一期末溢出顺延（周区间首端重叠表达此意），不做并行压缩。[推演]

### B.3 里程碑门禁（M-gate）

每期 M-gate 须**全部**满足（缺一不过）：

1. 该期全部 WP 验收标准逐条有可复现证据（命令输出/spec 通过记录）。
2. design.md §14 该期验收条目逐条勾稽（本文 A 节各 WP 已逐条映射，验收时按勾稽表核对）。
3. 质量三命令：`crystal spec` 0 fail、`./bin/ameba` 无警告、`make release` 成功 [来源: 仓库:CLAUDE.md]。
4. docs 同步：实现行为与 design.md/本文档一致，偏差处回写设计文档（CLAUDE.md 规矩 1）。
5. 风险复核：该期新增风险/未验证项进入 §15.1 口径记录（回写 design.md）。

阶段门禁 Go/No-Go 判据：M0 若强杀恢复不达标 → No-Go 返工 WP3/WP8；M1 若双账号串扰 → No-Go 返工 WP1（不接受「演示绕过」）；M3 若 mrb.cr 复核不可用 → 降级为技术预研 Go（见 M3-WP4 风险）。[推演]

---

## B.4 M0 门禁结论（2026-11-19）

M0 三条验收全过（收发全链路 / 强杀续跑 / 发信幂等），门禁三命令绿；证据与边界记录见 [review/m0-gate.md](review/m0-gate.md)。真实邮箱集成验收挂外部依赖 E.1（用户测试邮箱未就绪），协议层已按假服务器全链路验证。M1 允许开工。

## B.5 M1 门禁结论（2026-11-19）

M1 九包全部落地；§14 M1 七条验收全过（N 账号不串扰 / receiveid / token 刷新重取 / 限流退避 / 热更新三态 / 端口 restart 提示），门禁三命令绿；证据见 [review/m1-gate.md](review/m1-gate.md)。企微 AIBot 主路（§15.1.1 首日核对）与飞书 WS 帧协议（对照官方 SDK 核对）为真实账号集成前置，回调/webhook 形态已协议完整；不阻塞 M2 开工。

## B.6 M2 门禁结论（2026-11-19）

M2 六包全部落地；§14 M2 四条验收全过（崩溃重放幂等 / 审批超时 deny 注入时钟实测 / 预算熔断留痕 / runs 回放审计），门禁三命令绿；证据见 [review/m2-gate.md](review/m2-gate.md)。期间关键缺陷回写：intents_with_prefix LIKE 参数漏传（已修，详见 m2-gate.md）。M3 允许开工。

## B.7 M3 门禁结论（2026-11-19）

M3 WP1/2/3 验收全过（max_hops=4 拦截互发死循环 / 并发上限排队不失控 / subagent 崩溃经 ownerTaskId 找回同一子任务），门禁三命令绿。WP4~6（mrb.cr 插件层）按 B.3 预设条款降级为技术预研：mrb.cr 甄别通过（84/84）但本机 Windows 工具链当日无法链接新 mruby.exe（环境级 blocker，恢复路径已列），架构与构件（sebas-stdio gem、build_config 补丁、子进程沙盒解释器方案）已产出——详见 [review/m3-plugin-feasibility.md](review/m3-plugin-feasibility.md) 与 [review/m3-gate.md](review/m3-gate.md)。M0–M2 全部产品化验收保持有效。

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
| §9 管理面 | M0-WP7（NDJSON）→ M1-WP9（HTTP）→ M1-WP8（reload 命令）→ M2-WP6（runs API） |
| §10 安全模型 | M0-WP6（registry risk/replay）→ M1-WP7（keyring）→ M2-WP4（审批）→ M3-WP5（沙箱） |
| §11 配置热更新 | M1-WP8（+EX-W1-03 前置冒烟） |
| §12 插件脚本层 | M3-WP4~WP6 |
| §13 目录结构 | 全 WP 的模块归属总表（A 节各包「范围」字段已逐一对齐 §13 目录；**skills/ 归 M0-WP6b、providers/ 归 M0-WP5 实例池骨架——原隐含承载现显式声明**） |
| §14 路线图 | 本计划 A/B 节本体（验收勾稽） |
| §15 风险 | E 节前置冒烟+各 WP 风险栏+M-gate 第 5 条 |
| §16 来源对照表 | 本文 0 节证据纪律（引用不升级） |
| 附录 5 项待决策 | 显式承接 3 项（第 1 项已解决=定名 Seneschal）；附录 2（MVP 首渠道）与附录 5（插件首批能力+risk 调低权）为用户决策依赖：确认后分别落 M0-WP4（email 适配器）与 M3-WP 范围 |

自查：16 章全部有承载；§14 各期验收逐条落进 WP 验收（A 节各包内以 [来源: design.md:L749-L752] 逐条标注）。[推演]

### D.2 开放问题（计划视角发现，**不发明新设计决策**——设计变更归属 design.md 修订）

| # | 问题 | 建议归属 |
|---|---|---|
| 1 | Gmail 路线（附录 3）未决直接改变 M0-WP4 形态与估时：应用专用密码起步+2–3 pd，若首批即 Gmail API 则 M0-WP4 增 2–3 pd 且引入 GCP 外部依赖 | design.md 附录 3 用户决策；本计划按「专用密码起步」排期 |
| 2 | M0 期最小审批交互未在 design.md §14 M0 验收中显式列出，但 M0-WP6 发消息工具若 risk:high 触发审批，TUI 最小问答是 M0-WP7 隐含需求——已计入 WP7 范围，若用户希望 M0 全自动（approval.mode=off）则 WP7 减 0.5 pd | design.md 附录 4（审批默认模式）联动；本计划按「M0 含最小审批问答」排期 |
| 3 | TUI 选型（termisu vs 自写）需 M0-WP7 开工前 spike 定案，design.md 仅给候选未定 | M0-WP7 内含 0.5 pd spike，决策记录回写 design.md §16#33 |
| 4 | 企微 AIBot 主动发消息 API 未逐页核对（§15.1.1）：若开工首日核对发现 API 形态与笔记不符，回调备选升级为主路——估时已含回调完整实现，不扩 M1 区间，但 M1-WP4 的 demo 验收口径（长连接免公网卖点）可能降级 | M1-WP4 开工首日核对任务；结论回写 design.md §15.1.1 |
| 5 | ~~平台名【占位】~~ **已解决**：定名 **Seneschal**（[naming.md](naming.md) 14 候选撞名全核实）；若推翻，替换 design.md 与本文标题/附录中的「Seneschal」字样 | lead 裁断记录（naming.md） |

---

## E. 外部依赖与前置风险

### E.1 外部依赖（用户侧动作，不在估时内）

| # | 依赖 | 影响的 WP | 就绪时限 |
|---|---|---|---|
| 1 | 测试邮箱（应用专用密码开启） | M0-WP4 / EX-W2-06 集成验收 | W1 期间 |
| 2 | 企微测试企业+自建应用/AIBot 创建+可信 IP 配置（出口 IP 共享注意 §15.2.18 [来源: design.md:L784]） | M1-WP4 | M1 开工（约 W5/W6）前 |
| 3 | 飞书自建应用（WS 长连接仅自建应用可用 [来源: design.md §16#11]） | M1-WP5 | 同上 |
| 4 | Gmail 路线决策（若走 API：GCP 项目+OAuth 凭据） | M0-WP4 估时分叉 | EX-W2-06 开工前（最迟 W2-D3） |

### E.2 §15.1 未验证项中影响 M0/M1 排期的前置冒烟（逐条挑出）

| 条目 | 处置 | 落点 |
|---|---|---|
| 15.1.7 file_watcher Windows 实测 | ✅ **已完成**（2026-11-18）：watch 须对父目录+路径过滤；原子替换为 Created+Deleted+Renamed 三连，去抖聚合；[smoke-ex-w1-03.md](review/smoke-ex-w1-03.md) | EX-W1-03（结果回写 design.md §15.1.7） |
| 15.1.8 `Atomic(Config)` 编译冒烟 | ✅ **已完成**（2026-11-18）：reference type 全方法可用，详注歧义消项；[smoke-ex-w1-03.md](review/smoke-ex-w1-03.md) | EX-W1-03（结果回写 design.md §15.1.8） |
| 15.1.6 企微 crypto 官方测试向量 | WP 内验收自带（向量对称测试即消项） | M1-WP4 |
| 15.1.1 企微 AIBot API 未逐页核对 | **开工首日核对** 0.5–1 pd+demo；不符则回调备选升级（估时内含） | M1-WP4 |
| 15.1.9 换 secret 旧 token 失效行为 | 保守做法（TTL 自然过期+失效标记）不依赖该行为，不阻塞 | M1-WP3 |
| 15.1.2 Gmail IMAP IDLE 不可靠 | M0 单账号以「收到一封」为验收界；稳定性记录不阻塞门禁 | M0-WP4 |
| 15.1.10 mrb.cr 84/0 提交状态 | M3 开工前复核甄别 0.5 pd；不可用则 M3 插件三包降级为技术预研 | M3-WP4 |

不进 M0/M1 关键路径的其余未验证项（15.1.3 Gmail 15 连接、15.1.4 企微明文布局、15.1.5 飞书频控映射、15.1.11 Hermes reload 进度、15.1.12/13 OpenClaw 正文未取）不影响排期，实现到对应模块时按 design.md §15.1 原口径处置。[推演]

---

*（本文档为规划态：全部任务均为后续获授权执行时的验收标准，本文未执行任何代码工作；定名 Seneschal 已落盘（[naming.md](naming.md)），推翻则按 design.md:L846 替换指引执行。）*
