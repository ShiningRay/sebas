# development-plan M0 · MVP（单账号闭环）（17–25 pd）

> 导航：[设计总览](../../design.md) ｜ [文档索引](../../README.md) ｜ [计划总览](../../development-plan.md) ｜ 上一节：[WBS](README.md) ｜ 下一节：[M1](m1-multi-account.md)

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
- 范围：`config/` loader（读盘→expand_env→YAML→validate! 失败即拒启，复用 autobot `loader.cr:152-166` 现链思想 [来源: design.md §13]）、宏生成账号样板（autobot `config/schema.cr:506-517` 先例 [来源: autobot 笔记 §9 schema.cr:506-517；design.md §4.2]）、凭据引用占位（明文过渡，M1-WP7 迁 keyring）。
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
- 范围：`src/channels/base.cr`（account 维度接口）；email 适配器：IMAP IDLE（应用专用密码路线，已由 #23 裁决，见 [spec/05-multi-account.md](../../spec/05-multi-account.md) §5.4）；markdown 转换器【A8 直接搬】；TokenProvider 骨架（email 无 token 流，接口占位）。
- 交付物：`src/channels/email/` + 收信入总线 spec。
- 依赖：M0-WP2（配置树）。
- 验收：真实邮箱收信触发事件入总线（集成测试）；发信出站投递成功。
- 风险：Gmail IMAP IDLE 不可靠为社区长期报告 [来源: design.md §15.1.2]——本包以「至少收到一封触发」为验收界；兜底轮询、假活判定与指数退避由后续邮箱实现包补（§5.4 设计口径已有）。

**M0-WP5 事件总线 + agent worker 池**（3–4 pd）
- 目标：去全局单 Loop，per-session worker 池成立。
- 范围：`bus/` 有界 Channel【A3 加账号维度路由】；`agents/pool.cr` worker 池（并发上限、会话分片队列）；会话键含账号维度从 day one（B4 教训 [来源: design.md §16#13]）；agent-loop 单 turn 结构（每 turn 取配置快照纪律 [来源: design.md §11.2④]）；**`providers/` 实例池骨架**【A1/A2：单实例→实例池改造起点，M1-WP8 的 provider key 热换以此为宿主】[来源: design.md §13]。
- 交付物：`src/bus/` + `src/agents/pool.cr` + `src/providers/` 骨架 + 并发 spec。
- 依赖：M0-WP2、M0-WP3。
- 验收：**两并发会话互不阻塞**（一 turn sleep 10s，另一会话正常完成——autobot `cli/gateway.cr:76` 单 Loop 教训的反向断言 [来源: design.md §16#24]）；队列满时 send 阻塞（背压）可观测。
- 风险：Crystal fiber 调度在 Windows 的行为差异未实测 [未验证]。

**M0-WP6 基础工具集**（2–3 pd）
- 目标：MVP 工具面：发消息/读邮件/记忆读写。
- 范围：`tools/registry.cr`【A9 升级：replay/risk 类型级字段、脱敏】+ executor【A6】；**发消息工具必带幂等键**（§14 M0 验收 [来源: design.md §14]）。
- 交付物：`src/tools/` + 工具 spec。
- 依赖：M0-WP5。
- 验收：**发信幂等键生效——崩溃恢复重放场景下重复投递不重发**（§14 M0 验收第 3 条 [来源: design.md §14]）。
- 风险：无实质风险。

**M0-WP6b SKILL.md 加载器**（0.5–1 pd）
- 目标：A7 升格为主要扩展通道的首块代码落地——design.md §14 排期依据明言「M0-M2 的扩展需求由 SKILL.md（A7）承接」[来源: design.md §14]，本包即该承接的归属。
- 范围：`agents/skills/` 加载器（skills 目录发现+SKILL.md 解析+agent system prompt 注入）【A7】[来源: design.md §13；design.md §13 承接表]。
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
- 范围：强杀恢复自动化用例（POSIX kill -9 / Windows taskkill /F 后重启续跑，对照 Pi 恢复演练 [来源: design.md §14]）；全链路端到端用例（收→agent turn→发回复）；门禁三命令+docs 同步自检。
- 交付物：`spec/` 恢复演练 spec + M0 门禁证据清单。
- 依赖：M0-WP3~WP7 全部（含 WP6b）。
- 验收：**§14 M0 三条验收全过**：收发全链路 / 强杀续跑 / 发信幂等 [来源: design.md §14]。
- 风险：WAL 恢复在断电场景不可模拟——只验进程级强杀（Pi 同口径：掉电可丢最新一笔）[来源: Pi 笔记 §2 WAL+synchronous=NORMAL 口径]。
