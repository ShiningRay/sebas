# Changelog

本文件记录本项目的显著变更，格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Added

- **M4x-Comm-WP1 message_agent 工具面接线**：`message_agent` 进 `agent_turn` 衰减工具面（受 `agent.tools.allow` 白名单约束，装配未接线时工具不可见）；
  防环上限改由 `gateway.collaboration.max_hops` 配置（默认 4，loader 校验 ≥ 1，热更新即生效）；hops 不再由模型自报——投递时按收方会话键落库链路跳数，
  下一跳从工具 ctx 继承，回执形如 `queued <delivery_id> hops=<n>`；inbox 按 `to_agent` 分片，收方只取本 agent 的消息（[#185](https://github.com/ShiningRay/sebas/pull/185)）。
- **流程工具 accept-proposal**：一条命令完成 Proposal 的 `accepted-design` 裁决（发公开评论、登记裁决证据、复用 `Triager.plan` 校验并落地状态标签）；`--milestone` 顺带记录排期意图，不替代 Scribe 拆 `plan` 工作包。默认 dry-run，`--apply` 才写 GitHub。
- **M4.1 fork/join 影分身最小闭环**：生产装配补齐与入队键一致性（[#135](https://github.com/ShiningRay/sebas/pull/135)）、expectations 表 + mode 判定器 +
  恢复扫描（[#136](https://github.com/ShiningRay/sebas/pull/136)）、fork 快照组装与分身执行体（[#150](https://github.com/ShiningRay/sebas/pull/150)）、JoinWriter 分层回写 + 四时机语义（[#152](https://github.com/ShiningRay/sebas/pull/152)）、
  fork/join 触发面与全链 e2e（[#153](https://github.com/ShiningRay/sebas/pull/153)）。
- **M4.2-WP1 能力衰减**：分身生效工具集 = 声明 ∩ 父 `tools.allow`；越界声明静默剔除并在回执列明，
  默认只读档不含写副作用工具与 secrets（[#168](https://github.com/ShiningRay/sebas/pull/168)）。
- **M4.2-WP2 副作用分级与 join 冲突处理**：`SideEffect` 四值（ReadOnly/FileWrite/NetWrite/Irreversible）
  承载副作用级、与审批 `Risk` 正交；`EffectsLedger` 随 `ToolContext` 收集并落成员任务 payload；
  Join 以文件指纹双基线判冲突，冲突进父裁决清单、join 侧不自动 merge（[#169](https://github.com/ShiningRay/sebas/pull/169)）。
- **会话调度**：持久 busy 队列 + per-session 调度（WP2，[`e2e51c8`](https://github.com/ShiningRay/sebas/commit/e2e51c8)）、debounce 批次策略——六类 seal 条件
  与分桶结构化批次（WP3，[#158](https://github.com/ShiningRay/sebas/pull/158)）。
- **Provider 适配层**：引入 `crystal_llm` 依赖（ruby_llm 的 Crystal 移植，走 `ShiningRay/crystal-llm`
  fork）与 `CrystalLLMProvider`；每实例复制独立 `CrystalLLM::Context`，多 agent 的 api_key/base_url 互不污染（[#157](https://github.com/ShiningRay/sebas/pull/157)）。
- **流程工具 sebas-process**：可执行 Agent 工具链与 Ruby 文档门禁（[#96](https://github.com/ShiningRay/sebas/pull/96)）、认领写远端锁并引导流程标签（[#99](https://github.com/ShiningRay/sebas/pull/99)）、
  元数据缺口可见化（[#118](https://github.com/ShiningRay/sebas/pull/118)）、以 trusted bot 身份自动登记 Evidence（[#117](https://github.com/ShiningRay/sebas/pull/117)）、两阶段 Evidence 登记解合并前死锁（[#127](https://github.com/ShiningRay/sebas/pull/127)）、
  确定性核验作 CI 第五项必检（[#128](https://github.com/ShiningRay/sebas/pull/128)）、Verifier 独立 job（[#129](https://github.com/ShiningRay/sebas/pull/129)）、路径联动/安全不变量/CWE 汇总三类检查（[#133](https://github.com/ShiningRay/sebas/pull/133)）。

### Changed

- 工作包 Automation 新增 `kind=design`：Scribe 设计细化卡不进 Implementer 选卡，也不计为元数据缺口；`tracking` / `manual` 语义不变。Implementer 选卡只认 `kind=work_package`。
- Gateway 的 `http.port` / `ipc.port` 接受 `0`（内核分配空闲端口，listen 后回写实际端口）；spec 统一改用随机端口，
  本机常驻 `sebas gateway` 或并行跑多个 spec 进程不再撞 18790/18791。
- Gateway 的调度适配与批次执行拆分为 `GatewayDispatch` module（[#165](https://github.com/ShiningRay/sebas/pull/165)）。
- 文档门禁体量口径扩为三项：物理行 ≤ 400、等效屏幕行 ≤ 400（100 列视口，CJK 记 2 列）、单行显示宽度 ≤ 400 列。`check_docs.rb` 此前只数换行符，长段落能绕过阈值；新增 `--display-columns` / `--max-line-columns` 选项，传 `0` 表示该项不设上限；`docs/design/review/` 存档豁免后两项。`read_lines` 改用 `lines(chomp: true)`，与 `verify docs` 的行数口径对齐（[#188](https://github.com/ShiningRay/sebas/pull/188)）。
- Verifier 与 Reviewer 合并为单一角色并真接入 checker（[#132](https://github.com/ShiningRay/sebas/pull/132)）。
- Ruby 版本钉至 3.4.13，守卫改从 `.ruby-version` 推导下限，不再写死常量（[#104](https://github.com/ShiningRay/sebas/pull/104)）。

### Fixed

- Crystal 最低版本由 `>= 1.19.0` 修正为 `>= 1.22.0`：`src/platform/keys/vault.cr` 用了 1.22 才进入 stdlib 的
  `OpenSSL::Cipher#gcm_tag`，旧下限会让本地构建报误导性的 `undefined method 'gcm_tag'`。`Makefile` 新增
  `crystal-version-check` 前置目标，低于下限立即失败并给出修法；所有编译/检查目标支持 `CRYSTAL=` 覆盖。
- `cli/gateway.cr` 补齐 fork 组件 require，修复三平台 release build 与 drill 编译（[#167](https://github.com/ShiningRay/sebas/pull/167)）。
- fork 常量引用补 `::Sebas` 全限定，修复 main release build（[#156](https://github.com/ShiningRay/sebas/pull/156)）。
- 调度准入按生效配置快照解析（[`96ae049`](https://github.com/ShiningRay/sebas/commit/96ae049)）、`admit_new_batch` 守卫路径显式 `DB::Rollback`（[`94f8798`](https://github.com/ShiningRay/sebas/commit/94f8798)）、
  容量拒绝日志升 error 以避免事件被静默丢弃（[`fef2a89`](https://github.com/ShiningRay/sebas/commit/fef2a89)）、按 code review 十三条加固准入/恢复/路径（[`be61096`](https://github.com/ShiningRay/sebas/commit/be61096)）。
- sebas-process 重试瞬时 GitHub API 失败（[#98](https://github.com/ShiningRay/sebas/pull/98)）、从真实 GitHub payload 解析 Automation 块（[#97](https://github.com/ShiningRay/sebas/pull/97)）、
  一次性关闭 [#106](https://github.com/ShiningRay/sebas/issues/106) 的五个流程缺口（[#112](https://github.com/ShiningRay/sebas/pull/112)）。

### Documentation

- `design.md` 按章拆为 `spec/` 与 `plan/`，新增索引与文档门禁（[#94](https://github.com/ShiningRay/sebas/pull/94)）。
- fork/join 影分身分析与 M4 计划（[#59](https://github.com/ShiningRay/sebas/pull/59)）、源码锚点重校（[#60](https://github.com/ShiningRay/sebas/pull/60)）。
- commitments 与日历集成提案（[#61](https://github.com/ShiningRay/sebas/pull/61)）、M5–M7 计划（[#62](https://github.com/ShiningRay/sebas/pull/62)）。
- M4.0-WP2 定稿吸收回写与失效引用修正（[#134](https://github.com/ShiningRay/sebas/pull/134)）、M8 渠道扩展（Slack + Telegram）提案与 WBS（[#137](https://github.com/ShiningRay/sebas/pull/137)）、
  Agent 分类与标签元数据模型提案（[#151](https://github.com/ShiningRay/sebas/pull/151)）、设计提案走 issue 治理（[#155](https://github.com/ShiningRay/sebas/pull/155)）。
- 多任务并行开发提案定稿候选：每卡独立租约与集中合并收口，附恢复、迁移与验证续篇（[#191](https://github.com/ShiningRay/sebas/pull/191)）。
- 流程工具验收报告（[#100](https://github.com/ShiningRay/sebas/pull/100)）、合并前门禁口径改为 `verify merge --pre`（[#119](https://github.com/ShiningRay/sebas/pull/119)）、
  LLM 语义核验可行性评估——结论不做（[#131](https://github.com/ShiningRay/sebas/pull/131)）。

### CI

- macOS runner 缺 `openssl@3`/`pkg-config` 时幂等自举安装（[#166](https://github.com/ShiningRay/sebas/pull/166)）、OpenSSL 定位排除无版本后缀软链（[#164](https://github.com/ShiningRay/sebas/pull/164)）。
- 新增 `.coderabbit.yaml` 注入仓库约定（[#120](https://github.com/ShiningRay/sebas/pull/120)）。

## [0.1.0] - 2026-11-19

首个公开版本。里程碑口径以 `README` 与 `docs/design/review/*-gate.md` 为准。

### Added

- **M0 单账号闭环**：email 账号接入（IMAP IDLE / SMTP）、agent 池、SQLite 持久层（intent/task/checkpoint）、
  基础工具执行器、NDJSON 管理面 TUI；强杀后从 checkpoint 续跑。
- **M1 多账号与热更新**：Account/Agent/Binding 三正交路由；企业微信、飞书/Lark 渠道；TokenProvider 与限流；
  凭据保护（AES-256-GCM 静态加密 + OS keyring/主密钥文件降级）；配置免重启热更新（先验后换 + Atomic 整根替换）。
- **M2 编排**：触发→条件→动作 DSL 解析与校验、持久工作流引擎、统一触发器（cron/事件/webhook/账号）、
  审批中心（fail-closed）、账本与预算熔断、lease、runs 视图（replay + audit）。
- **M3 协作与插件**：多 agent 协作与 `message_agent` 防环、subagent 信号量、mrb.cr 插件沙箱可行性预研与降级结论。

### Documentation

- 设计与开发计划：`docs/design/design.md`、`docs/design/development-plan.md`。
- 里程碑门禁证据：`docs/design/review/m0-gate.md` ~ `m3-gate.md`。

[Unreleased]: https://github.com/ShiningRay/sebas/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/ShiningRay/sebas/releases/tag/v0.1.0
