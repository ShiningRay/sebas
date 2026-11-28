# Changelog

本文件记录本项目的显著变更，格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Added

- **CI 并发语义按事件区分**（[#221](https://github.com/ShiningRay/sebas/issues/221)）：`ci.yml` 的 `cancel-in-progress` 改为只在 `pull_request` 事件为 true。main 侧不再互相取消——被顶掉的 main CI 会让 Evidence 停在 `merged_into_main: false`、后继卡永久 blocked。理由与边界见 [pr-gate.md](docs/design/process/pr-gate.md)。
- **插件沙箱与 22 钩子（M3-WP5）**（[#17](https://github.com/ShiningRay/sebas/issues/17)）：
  - 钩子契约：§12.11 22 钩子闭集目录 + payload schema 机读权威（键集闭/枚举/可空/结构化错误/深度封顶；敏感 hook 需 manifest `hooks.sensitive`）。
  - 派发语义：gate/transform 同步链（deny fail-closed、替换重过 schema）、observe 隔离、priority 稳定序、按 fiber 链隔离的递归深度、预算 outcome 化（链中耗尽判 deny；agent turn 级共享同一 Budget 实例，跨派发累计）、idempotency memo。
  - 宿主注入：22/22 全量接线（gateway/消息/Agent/LLM/工具/会话/记忆/任务八域；per-turn executor 与热更新路径同步刷新；插件面装配失败 all-or-nothing 归零并经 `config.reload` 结果的 `degraded` 维度体现）。
  - runner 隔离：终态前置进程树清扫（POSIX pgrep 树遍历 + 调用级进程组长立组与组级 SIGKILL 兜收养态后代、失败区分「无后代/枚举失败」、pgrep 无匹配按空数组；Windows 调用级 Job Object FFI，终态先于诊断等待终止）、终态后有界帧校验（跨读取块行重组）、迟到输出时间/字节双预算排水（剩余预算施加到读取本身，后代持管道不悬挂）、OS 资源约束（POSIX ulimit 全成功才 exec（失败 exit 126 停启动留诊断）+ 包装前解释器可启动性检查保持装配错误语义；Windows Job 内存上限；生产装配经 `plugins.memory_mb/cpu_seconds` 配置承载）。
  - capability：双重白名单第二关 + scope 宿主注入 + 受控 memory.backend（幂等重放同 key 同 id，不重复副作用；task 重放身份经 Request 透传生产装配生效，检查与提交同临界区）。
  - 压缩：SessionCompactor 接口与 CompactionRunner 协议（无生产压缩器，hook 语义先行；摘要唯一提交方=调用方 commit 回调，提交成功才派发 compact.after，重复归档幂等不重触发）。
  - DSL：`deny!`/`modify!`；manifest `hook_priorities`（向后兼容）。
- **流程工具容量配置化**（recovery §5 / Q3 前置片，[refs #221](https://github.com/ShiningRay/sebas/issues/221)；Maintainer 2026-11-27 指令提升）：
  - `capacity` 配置：`.github/agents.yml` 新增 `capacity` 键设定在途租约上限，缺键即 1（行为与单卡一致）；仅接受正整数，显式 null/浮点等非法值 fail-closed。
  - 路由与认领：快照承载 `capacity`；routing/claim/resume 判定按容量计数，超容量 invalid；容量内多卡的续做路由对准本地记录持有的卡。
  - 异机租约（F6）：容量未满时不阻塞新候选、不误续跑他人 PR；容量已满且在途卡缺本地记录时 routing 报 wait（占容量等待，不接管）——F7「无有效凭据」的判定需要租约评论事实，留在 claim 的租约预检做（对不上即 invalid_plan）。
  - `plan` 输出：新增 `capacity`（快照容量）与 `capacity_used`（在途卡数）。
  - 迁移窗口：v1 记录仍活动时有效容量钳回 1（Q10=B）；默认记录损坏不吞异常，命令 fail-closed 拒绝；`aborted` 遗留记录属认领未确认异常态，迁移拒绝自动搬迁（F3/F4 对账前置），不随迁移解除容量钳制。
  - 试点豁免：docs-only 双卡豁免仅在容量 1 时生效（试点上限两张语义不变）。
- **流程工具 per-issue 租约与运行记录迁移**（M4x-Parallel-WP2，[#220](https://github.com/ShiningRay/sebas/issues/220)）：`claim --apply` 发带 `<!-- sebas-lease -->` marker 的协调评论作租约凭据（comment id 即 lease_id，作者须 `.github/agents.yml` `coordinators:` 白名单；写入序 claiming→评论→标签+回读→claimed，失败按 lease_id 对账恢复不双开）；Automation 可选 `scope` 路径前缀预算（前缀互相包含即冲突，缺 scope 独占容量，本期容量恒 1 待命）；`.sebas-agent/run.json` 迁移至 `runs/<issue>.json` schema 2（非活动自动搬、活动 fail-closed 待人工、迁移期容量 1）；unclaim 释放租约先置 released（F12 幂等）。
- **流程工具 plan 子命令**（M4x-Parallel-WP1，[#218](https://github.com/ShiningRay/sebas/issues/218)）：`sebas-process plan` 只读多候选视图——与 `next` 同快照同策略同评估结果，输出全部就绪候选（`issue/title/order/scope_conflict/selected`，capacity 固定 1）、带枚举码的排除集（`depends_on_unmet/has_pr/needs_human/already_in_progress` 等）与 `verifier_queue_depth`（待验收 PR 数，验收背压可观察，[Proposal §7](docs/design/proposals/parallel-implementers.md)）；首选与 `next` 恒等，不改任何写行为。
- **M3-WP4 插件层产品化**：每动作裁剪 mruby 子进程 runner（合成 prelude+plugin.rb 程序、stdin 单行 request、NDJSON 帧协议、watchdog 超时 kill、崩溃隔离、结构化错误）；`on_action`/`on_hook` 声明式 DSL 与 `capability` 同步 host-call（帧字段闭集、manifest 双重授权、未声明/未注册/重复注册拒绝）；manifest fail-closed 校验（id/SemVer/api_version/钩子闭集/超时上限）；`plugins:` 配置段接入 gateway（`plugin.<id>.<action>` 进宿主工具面，生命周期动作不进）；沙箱解释器 gembox 扩展 `sebas_read` 与自研 `mruby-sebas-json`（`mruby-sandbox` workflow 构建发布 + 插件验收 spec 注解释器直跑）（[#16](https://github.com/ShiningRay/sebas/issues/16)）。
- **M4x Agent 分类与标签**：`AgentConfig` 新增 `category`/`tags`（词法 `[a-z0-9][a-z0-9-]*` 1..64，loader 先验后换逐条校验，重复标签报错不去重）；`AgentInstance` 首建时固化元数据（热更新不刷新存量实例，避免人格/标签漂移）；IPC 新增 `agents.list` 只读命令（读当前 `Config.agents` 真相源，按 id 字典序，未分类输出 JSON `null`）（[#261](https://github.com/ShiningRay/sebas/pull/261)）。

### Documentation

- #274 `~/.sebas` / `SEBAS_HOME` 设计快照、M5.0-WP3 排期、测试主目录隔离契约与 setup 路径联动（尚未实现产品行为）。

## [0.2.0] - 2026-11-26

### Added

- **M3-WP7 Telegram 渠道扩展点定稿**：`CHANNEL_TYPES` 登记 `telegram`，配置 schema 新增
  `channels.telegram.accounts[]`（`bot_token` 必填、`api_base_url`/`token_ref` 可选，loader 逐条校验），
  绑定路由与账号解析自动生效；`InboundMessage` 补 `message_id`（尾置默认 nil，旧适配器零改动，
  回放路径随 JSON 保真）。适配器接线属 M8.1-WP3，接入前发送时查无适配器 fail-loud。
- `sebas version` / `--help` 首行带构建来源的 git 提交：输出 `sebas X.Y.Z (<git rev>)`。rev 由
  `src/version.cr` 的编译期宏**直接解析 `.git` 的 HEAD**取得（覆盖 packed-refs、detached、
  worktree、submodule、bare；不调用 git，故无 shell 与平台差异），无 `.git` 的构建可用
  `SEBAS_BUILD_REV` 注入，读不到时退化为 `unknown` 且不中断构建；`release verify` 冒烟校验
  同步接受带 rev 与不带 rev 两种形态。
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

- **`subagent.ask` 自 DSL 白名单移除**（M4x-Comm-WP3）：白名单有、Engine 无执行分支且工具注册表
  无该工具，工作流会在 run 中途才以 `unknown tool` 失败（前序动作副作用已发生）。现在校验期即报
  `unknown tool`（fail-closed），且 `load_workflows` 注册前统一过 `Validator.validate`（此前生产
  装载从不校验，非法工作流注册成功、运行期才失败）；`SubagentManager` 构件保留待求助原语设计复用；
  「装配类验收须含生产可调用性与端到端可达证据」立为验收口径（implementer-loop §2.3 / roadmap §14），
  M3 门禁记录加补注不改原结论。
- 工作包 Automation 新增 `kind=design`：Scribe 设计细化卡不进 Implementer 选卡，也不计为元数据缺口；`tracking` / `manual` 语义不变。Implementer 选卡只认 `kind=work_package`。
- Gateway 的 `http.port` / `ipc.port` 接受 `0`（内核分配空闲端口，listen 后回写实际端口）；spec 统一改用随机端口，
  本机常驻 `sebas gateway` 或并行跑多个 spec 进程不再撞 18790/18791。
- Gateway 的调度适配与批次执行拆分为 `GatewayDispatch` module（[#165](https://github.com/ShiningRay/sebas/pull/165)）。
- 文档门禁体量口径扩为三项：物理行 ≤ 400、等效屏幕行 ≤ 400（100 列视口，CJK 记 2 列）、单行显示宽度 ≤ 400 列。`check_docs.rb` 此前只数换行符，长段落能绕过阈值；新增 `--display-columns` / `--max-line-columns` 选项，传 `0` 表示该项不设上限；`docs/design/review/` 存档豁免后两项。`read_lines` 改用 `lines(chomp: true)`，与 `verify docs` 的行数口径对齐（[#188](https://github.com/ShiningRay/sebas/pull/188)）。
- Verifier 与 Reviewer 合并为单一角色并真接入 checker（[#132](https://github.com/ShiningRay/sebas/pull/132)）。
- Ruby 版本钉至 3.4.13，守卫改从 `.ruby-version` 推导下限，不再写死常量（[#104](https://github.com/ShiningRay/sebas/pull/104)）。

### Fixed

- 工作包依赖节标题写成「依赖关系」这类变体时，`prose_dependencies` 返回 `nil`，正文与 `Automation.depends_on`、
  原生 `blocked_by` 的核对被整段跳过且不报警（看着绿灯，实际没校验）。现在 `kind=work_package` 遇到标题不合规
  直接判 `invalid_plan` 并列出变体标题；非工作包不查，变体节内无 `#N` 引用也不报，避免把说明文字误判成依赖声明。
- `sebas gateway` 启动失败时静默退出（无输出、退出码 1）。两处叠加：① 各模块日志常量写成
  `Sebas::Log.for("sebas.<layer>")`，在源 `sebas` 下再拼一层得到 `sebas.sebas.<layer>`，而 CLI 只绑定了
  `sebas` 这一个源，`Log::Builder#matches` 按整段前缀匹配，全部子源日志被静默丢弃（配置拒启、IMAP 连接失败、
  健康变化一概无输出）。现统一改为 `Sebas::Log.for("<layer>")`，绑定改为 `sebas,sebas.*`；② `-c` 未被识别为
  `--config` 的别名，传 `-c x.yaml` 时静默回退到 cwd 的 `config.yaml`。日志统一走 STDERR，`--config`/`-c`
  缺值时报错退出。回归用例 `spec/platform/cli/cli_spec.cr`。
- `.gitignore` 的 `main` 规则误伤 `agents/main/`（人格目录），改为 `/main` 只忽略仓库根的构建产物。
- email 渠道真机收发两处缺陷：① IMAP/SMTP 命令行原用 `IO#puts`（行尾裸 LF，RFC 3501 §2.2 / RFC 5321 §4.1.1.4
  要求 CRLF），Gmail/QQ/Outlook 的 IMAP 对 LF 命令行不响应直到读超时、QQ SMTP 对 LF 的 EHLO 直接 502；
  现统一 `print(line, "\r\n")`，并把正文裸 LF 归一为 CRLF 后再点填充（否则多行正文的行首点号漏填、DATA 分帧非法）。
  ② 收信游标 `last_uid` 硬编码 `"0"` 且是循环内局部变量——有历史邮件的邮箱会把整个 INBOX 逐封当新邮件重放并回信，
  重连后再次重放，且单批只取最老 10 封使新邮件永远排不上；现首连以 SELECT 的 `UIDNEXT - 1` 为基线跳过历史、
  游标提为进程内字段跨重连保留、`drain_inbox` 循环取批直到空。Gmail 实测：332 封历史的邮箱只投递新到的一封，
  重启静置 25s 零重放（Fixes #20）。
- email 收信五处健壮性补齐：① 游标与 `UIDVALIDITY` 绑定，服务端换 UID 命名空间后作废重建，
  而非沿用旧游标筛选新邮件（RFC 3501 §2.3.1.1）；② 每次连上后、进 IDLE 前先补收一次，避免
  「断线期间到信、重连后无新信」永久漏收（IDLE 只报状态变化，不重发已通报状态，RFC 2177）；
  ③ 过滤发件人为本账号的邮件——自投递/副本同步会让 agent 与自身无限对聊（真机实测出现
  连续自对聊累积）；④ SELECT 未返回 `UIDNEXT` 时不再退回 UID 0 取信（那会把历史整批重放），
  改为本次会话不投递并记 warn；⑤ `event_id` 纳入 `UIDVALIDITY`（`email:<账号>:<uidvalidity>:<uid>`），
  否则换命名空间后 UID 复用会撞 `intents.id` / `session_inputs.event_id` 主键，新邮件被当重复
  投递静默丢弃。重连退避改为可注入参数，便于测试。
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
- Gmail 路线裁决落盘（[#23](https://github.com/ShiningRay/sebas/issues/23)）：继续应用专用密码 + IMAP IDLE / SMTP，不迁 Gmail API；
  兜底轮询 5 分钟、假活判定、指数退避 5s→60s 与已知边界写入 §5.4，并给出切换 API 的六条触发条件；
  同步消除 plan 与 spec 各处的「待用户决策」残留。
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

[Unreleased]: https://github.com/ShiningRay/sebas/compare/v0.2.0...HEAD
[0.1.0]: https://github.com/ShiningRay/sebas/releases/tag/v0.1.0
[0.2.0]: https://github.com/ShiningRay/sebas/releases/tag/v0.2.0
