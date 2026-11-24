# development-plan M4 · Fork/Join 影分身 + 轻量 Agent 团队 + 会话治理（27.5–44.5 pd）

> 导航：[设计总览](../../design.md) ｜ [文档索引](../../README.md) ｜ [计划总览](../../development-plan.md) ｜ 上一节：[M3](m3-collab-plugins.md) ｜ 下一节：[M5](m5-commitments.md)

### M4 · Fork/Join 影分身 + 轻量 Agent 团队 + 会话治理——估时合计 27.5–44.5 pd（2026-11-20 追加）

> 依据：
>
> - [fork-join-semantics.md](../../proposals/fork-join-semantics.md)（语义方案核心）
> - [fork-join-shadow-clone-architecture.md](../../proposals/fork-join-shadow-clone-architecture.md)（架构）
> - [fork-join-shadow-clone-analysis.md](../../fork-join-shadow-clone-analysis.md)（翰林现状核实）
> - [fork-join-shadow-clone-positioning.md](../../proposals/fork-join-shadow-clone-positioning.md)（定位提案）
> - 首辅九问裁断（Q1–Q9，已全部落实）
>
> 仓内 M1–M3 已存在，提案原号 M0.5–M4 防撞名重编为 **M4.0–M4.4**，映射见 B.8.1。

**M4.0-WP1 语义/架构提案评审修订定稿**（0.5–1 pd）
- 目标：fork-join-semantics.md 与 fork-join-shadow-clone-architecture.md 定稿。
- 范围：吸收用户评审意见修订两提案；Join 语义矩阵 16 格（4 副作用级 × 4 时机）与 any 模式残余分身处置复核；九问裁断逐条回对。
- 交付物：两提案定稿版。
- 依赖：无（本轮三文档为输入）。
- 验收：评审通过（纯文档包门禁，B.3 M4 口径注）；矩阵逐格有策略可指认。
- 风险：评审若要求矩阵重定义则修订轮次增加——估时按下限单轮计。[推演]

**M4.0-WP2 定稿吸收回写 + 失效引用修正**（1–1.5 pd）
- 目标：按既有提案→design.md 契约吸收流落定 fork/join。
- 范围：三处回写。
  ① §8 协作扩展（fork/join 节：键/表/矩阵/衰减摘要）落
  [spec/08-multi-agent.md](../../spec/08-multi-agent.md)。
  ② §14 路线图延至 M4 落 [spec/14-roadmap.md](../../spec/14-roadmap.md)
  [来源: design.md §14 现仅到 M3]。
  ③ [plan/00-baseline.md](../00-baseline.md) 第 0 节「质量门禁惯例」行的失效引用修正
  （原文引 CLAUDE.md，该文件仓内不存在；改指 CONTRIBUTING.md 质量门禁节 + Makefile +
  .github/workflows/ci.yml 现行权威 [来源: fork-join-shadow-clone-analysis.md:158]）。
  本文 M4 段同步勾稽。
- 交付物：`spec/08-multi-agent.md`（§8）与 `spec/14-roadmap.md`（§14）修订 + `plan/00-baseline.md` 第 0 节修正。
- 落位：§8.4「fork / join 影分身（契约摘要）」与 §14 M4 行已落 [spec/08-multi-agent.md](../../spec/08-multi-agent.md) / [spec/14-roadmap.md](../../spec/14-roadmap.md)；第 0 节失效引用先前已修（现引 CONTRIBUTING.md 质量门禁节），本包复核确认无残留。
- 依赖：M4.0-WP1 定稿。
- 验收：`spec/14-roadmap.md` 含 M4 期验收条目；第 0 节不再指向不存在文件；docs 与两提案无口径冲突。
- 风险：改 spec/ 既有章节须走 PR 评审（用户授权后执行；本轮只写三文档不动 spec/）。

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
- 范围：四项。
  ① ForkManager（输入契约 = 任务描述/快照范围/能力声明/角色/join 模式/deadline）。
  ② 快照 = transcripts 窗口 + system prompt + skills 注入
  [来源: 仓库:src/platform/store/store.cr:406-417；src/agents/skills/skills.cr:43-83]。
  ③ 分身 turn 走 HttpProvider 纯消息接口 [来源: 仓库:src/providers/providers.cr:58-88]。
  ④ ToolContext 扩展子任务句柄 [来源: 仓库:src/tools/registry.cr:44-59 现无]；
  分身并发信号量默认 3（循 subagent.cr:16 先例）。
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
- 范围：agent 模板（克隆+patch）；SKILL.md frontmatter 角色卡挂点 [来源: 仓库:src/agents/skills/skills.cr:43-83]；fork `role` 参数接线（semantics §1.1）。与插件演进 issue #24 **引用不并卡**：其 P3「按插件隔离常驻 Worker」为不同轨道（启动条件见 [review/plugin-evolution.md](../../review/plugin-evolution.md)），模板库不依赖它。
- 交付物：模板库 + 角色卡 spec + 示例模板两则（代码审查员/发布工程师）。
- 依赖：M4.4-WP1。
- 验收：从模板克隆 agent 一次成型；fork role 指定生效（system prompt 后缀注入）。
- 风险：模板爆炸（轴②风险「轻量产生垃圾」）——回收治理在 WP3 承接，本期验收不单列 GC。[推演]

**M4.4-WP3 sessions 元数据表 + 休眠/归档/回收**（2–3 pd）
- 目标：会话生命周期治理闭环（轴①重，Q8 拆分第二块；提案 M4 门槛）。
- 范围：sessions 元数据表（store 新增表，架构文档 §5 草案）；状态机 active/dormant/archived；休眠阈值 + 归档命令 + 回收 GC（人工确认非自动删）；不绑 compaction（design.md §6.1 未实现，独立先行）[来源: fork-join-shadow-clone-analysis.md §4 M4]。
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
