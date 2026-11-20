# Seneschal开发计划（WBS · 排期 · 门禁 · 首迭代）

> 文档职责：回答「怎么建」——M0-M3 工作包分解（WBS）、依赖与排期、里程碑门禁、首迭代逐任务执行清单、覆盖自查与前置风险。  
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
- 范围：expectations DDL（fork_id/parent_task_id/mode all|any|allSettled/deadline/members/回写状态机，详 semantics 文档 §4.1）；mode 判定器（all 等全部不短路、any 首个成功、allSettled 失败也计完成）；分身任务树 kind="fork_child" 复用 TaskRow.parent_id/owner_task_id [来源: 仓库:src/platform/store/store.cr:21-23,30-144]。
- 交付物：store 表 + 判定器 + 崩溃恢复扫描 spec。
- 依赖：M4.1-WP1。
- 验收：三 mode 判定 spec 全过；强杀后 open/settling expectation 续判且不重复回写（memo 幂等）。
- 风险：SCHEMA 数组追加走 CREATE IF NOT EXISTS 既有惯例，存量库无迁移。[推演]

**M4.1-WP3 ForkManager 快照组装 + 分身执行体**（2–3 pd）
- 目标：fork 原语可执行（快照→分身任务→turn）。
- 范围：ForkManager（输入契约 = 任务描述/快照范围/能力声明/角色/join 模式/deadline）；快照 = transcripts 窗口 + system prompt + skills 注入 [来源: 仓库:src/platform/store/store.cr:390-401；src/agents/skills/skills.cr:43-83]；分身 turn 走 HttpProvider 纯消息接口 [来源: 仓库:src/providers/providers.cr:58-88]；ToolContext 扩展子任务句柄 [来源: 仓库:src/tools/registry.cr:44-59 现无]；分身并发信号量默认 3（循 subagent.cr:16 先例）。
- 交付物：ForkManager + 分身执行体 spec。
- 依赖：M4.1-WP2；E.5（ForkEnvelope 派发路径：无渠道入站消息、无 sender/peer）。
- 验收：N=1/N=3 fork 快照内容断言（窗口行数正确、不含 secrets）；超并发闸排队不失控。
- 风险：快照组装跨 store/skills/providers 三模块——纯函数化快照组装器便于 spec。[推演]

**M4.1-WP4 JoinWriter 分层回写 + 异常时机语义**（1.5–2.5 pd）
- 目标：join.report 三层回写与四时机语义落地。
- 范围：L1 结论+关键决策点+副作用清单进父会话 append_transcript [来源: 仓库:src/platform/store/store.cr:372-380]；L2 引用分身会话键+行数范围（全量已双写无需搬运）；四时机（正常/超时/失败/取消）中 M4.1 生效列按默认只读档结构先行；deadline 到期 expired + partial 回写；memo 幂等键 join:<fork_id>:written。
- 交付物：JoinWriter + 四时机 spec。
- 依赖：M4.1-WP3。
- 验收：正常完成回写父会话可见；超时 partial 标注；重放不重复回写。
- 风险：L1/L2/L3 副作用列本期只有结构无真实写工具——按「结构先行、M4.2 填充」验收。[推演]

**M4.1-WP5 DSL/IPC/HTTP 触发面 + e2e**（1–2 pd）
- 目标：用户显式 + DSL 声明两条触发路打通（Q3：不动生产 agent_turn）。
- 范围：KNOWN_TOOLS 加 fork/join [来源: 仓库:src/orchestration/dsl/dsl.cr:113]；DSL 校验（count/mode/deadline 必填）+ 示例 workflow；IPC/HTTP fork/join 命令；fork→分身→join 回写全链 e2e。
- 交付物：触发面 + e2e spec + 示例 DSL。
- 依赖：M4.1-WP4。
- 验收：DSL 声明 3 分身→各自终态→按 mode 回写父会话（一级 Fork + 只读分身最小闭环，提案 M1 门槛）；调度四条门禁绿（B.3 M4 口径注）。
- 风险：无实质风险。

**M4.2-WP1 能力衰减机制**（1.5–2.5 pd）
- 目标：生效能力 = fork 显式声明 ∩ 父 tools.allow；未声明用默认只读档（Q6）。
- 范围：衰减执行面（声明交集 + 白名单外剔除并在回执列明）；默认只读档工具集（无任何写副作用工具、不携带 secrets，semantics 文档 §5.1 表）；tools.allow=["*"] 现状口径下声明全集生效 [来源: 仓库:src/platform/config/schema.cr:94-97]。
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
- 范围：AgentConfig.api_key 明文过渡迁 keys/ 模块（M1-WP7 keyring 承接）[来源: 仓库:src/platform/config/schema.cr:83]；分身执行面无凭据直读路径（provider 实例句柄封装 [来源: 仓库:src/providers/pool.cr:12-25]）；日志脱敏复查。
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
- 范围：persona/persona_file 引用校验、session/skills 字段补齐 [来源: 仓库:src/agents/agents.cr:49-57；src/platform/config/schema.cr:78-88]；模板落位定夺（SOUL.md vs SKILL.md，M4.4-WP2 前置决策）。
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
```

自查：全部边单向、无回边、无跨期回依赖（M2/M3/M4 包仅依赖本期或前期包），**无环**；M4 期边界串行、期内依赖详 A 节 M4 各包「依赖」字段。[推演]

**口径注（S1 修正）**：B.1 图为**排期顺序口径**（表达可并行块与开工次序）；**硬依赖以各 WP「依赖」字段为准**——图与字段存在三处边宽严不一（M0-WP3 图列 WP2 后序而字段仅依赖 WP1；M0-WP5 图含 WP4 前序而字段为 WP2+WP3；M1-WP8 图未画 WP1 直连而字段含 WP1），均为「图严于字段」方向的排期保守，不构成环，**冲突时以字段口径为权威**。[推演]

### B.2 逐周排期（5 pd/周，区间口径）

| 期 | 估时合计 | 周区间 | 周号（顺延，含前序溢出） |
|---|---|---|---|
| M0 | 17–25 pd | 3.5–5 周 | W1–W5/W6 |
| M1 | 19.5–30 pd | 4–6 周 | W5/W6–W11 |
| M2 | 12.5–19 pd | 2.5–4 周 | W11/W12–W15 |
| M3 | 15–24 pd | 3–5 周 | W15/W16–W20/W21 |
| M4 | 27.5–44.5 pd | 5.5–9 周 | W20/W21–W29/W30 |
| **M0–M3 小计** | **64–98.5 pd** | **13–20 周** | **W1–W20/W21** |
| **总计（M0–M4）** | **91.5–143 pd** | **18.5–29 周** | **W1–W29/W30** |
| +缓冲（M0–M3 口径） | +0–10 pd（Tessell 口径） | +0–2 周 | 总 64–108.5 pd ≈ W1–W22 |
| +缓冲（含 M4） | +0–10 pd（Tessell 口径） | +0–2 周 | **总 91.5–153 pd ≈ W1–W31** |

算术自查：M0=17–25、M1=19.5–30、M2=12.5–19 沿用已验收 WBS；M3 下限 1+1.5+2+4+4+3=15.5、上限 1.5+2+3+6+6+5=23.5（WP4/5 因 DSL/21 hook 各 +1 pd，包与生命周期此前已 +1.5–2.5 pd）；总和精确下 17+19.5+12.5+15.5=64.5、上 25+30+19+23.5=97.5。下表 M3 按对外区间取整为 15–24，故取整合计为 64–98.5；含精确缓冲上限 107.5 pd（107.5/5=21.5 周，保守进位 W22）。各期之间允许上一期末溢出顺延（周区间首端重叠表达此意），不做并行压缩。[推演] M4 期排期与算术自查详见 B.8.4（2026-11-20 追加）；M4 入总计时以包区间 27.5–44.5 pd 为准（小计 64.5+27.5=92，取整口径 64–98.5 + 27.5–44.5 → 总 91.5–143 pd，见 B.8.4 复算）。[推演]

### B.3 里程碑门禁（M-gate）

每期 M-gate 须**全部**满足（缺一不过）：

1. 该期全部 WP 验收标准逐条有可复现证据（命令输出/spec 通过记录）。
2. design.md §14 该期验收条目逐条勾稽（本文 A 节各 WP 已逐条映射，验收时按勾稽表核对）。
3. 质量三命令：`crystal spec` 0 fail、`./bin/ameba` 无警告、`make release` 成功 [来源: 仓库:CLAUDE.md]。
4. docs 同步：实现行为与 design.md/本文档一致，偏差处回写设计文档（CLAUDE.md 规矩 1）。
5. 风险复核：该期新增风险/未验证项进入 §15.1 口径记录（回写 design.md）。

阶段门禁 Go/No-Go 判据：M0 若强杀恢复不达标 → No-Go 返工 WP3/WP8；M1 若双账号串扰 → No-Go 返工 WP1（不接受「演示绕过」）；M3 若 mrb.cr 复核不可用**或 Windows 新 mruby.exe 链接环境 blocker 未消项**（恢复路径见 [review/m3-plugin-feasibility.md](review/m3-plugin-feasibility.md)）→ WP4~WP6 降级为技术预研 Go，降级证据 = 可行性报告与本机链接失败复现记录，产品化验收延至 blocker 消项后重跑（见 M3-WP4 风险）。[推演]

**M4 期门禁口径（Q7 裁断，2026-11-20 追加）**：M4.0–M4.4 各期 M-gate 沿用上述五项框架（§14 勾稽/docs 同步/质量命令/风险复核照旧），第 3 条质量命令改为「调度四条」全绿：`make format-check` + `crystal spec` + `make lint` + `make release` [来源: 仓库:docs/design/proposals/session-input-scheduling.md:215 调度提案先例]；纯文档包（M4.0）以「评审通过」（用户）替代命令门禁。M4 期 Go/No-Go 判据：M4.1 若 fork e2e 不达（分身未跑/回写丢/键漂移）→ No-Go 返工 WP2/WP3；M4.2 若 L3 审批拦截 fail-open → No-Go 返工 WP3（不接受「仅 hardline 拦截」降格）；M4.4 若回收 GC 无人工确认 → No-Go 返工 WP3。上文三命令口径（:473）及其 CLAUDE.md 失效引用在 M4.0-WP2 一并修正。[推演]

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
| 5 | 调度轨 issue #9 WP1/WP2 已合或 admission/envelope 接口冻结（PR #32 已定型 policy/envelope/Store 单事务 admission；fork 入队为调度输入类型扩展——无渠道入站消息、无 sender/peer，Q5 迁就其接口）。注：WP1（contract+migration+纯函数状态机）已随 185e37b 合入 main，开工条件余 WP2 部分待满足 | M4.1 全期（ForkEnvelope 派发路径） | M4.1 开工前 |
| 6 | M4 语义/架构两提案文档评审（用户过目：fork-join-semantics.md + fork-join-shadow-clone-architecture.md） | M4.0-WP1 定稿 → M4.0-WP2 吸收回写 | M4.0 期内 |
| 7 | 插件演进 issue #24 启动条件（**引用不并卡**：见 [review/plugin-evolution.md](review/plugin-evolution.md)；其 P3 常驻 Worker 与模板库仅留交叉引用） | M4.4-WP2 模板库 | 无等待（非阻塞） |

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
