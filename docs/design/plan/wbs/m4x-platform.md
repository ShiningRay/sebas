# development-plan M4x · 插件与平台演进（并行轨）

> 导航：[设计总览](../../design.md) ｜ [文档索引](../../README.md) ｜ [计划总览](../../development-plan.md)
> 本文件只收纳已获 Maintainer 排期的平台工作包；各卡仍以 GitHub milestone 与依赖为执行权威。

## M4x-Setup · 交互式初始化（3.5–5.5 pd，2026-11-27 细化）

> 依据：[proposals/interactive-setup.md](../../proposals/interactive-setup.md)，tracking #145。
> 期定位：首期只交 Provider + Agent + 本地 TUI 的可运行路径。外部渠道必须等 credential_ref 与 adapter vault 读取链完成，不能用明文 YAML 冒充完成。

**M4x-Setup-WP1 配置写入核心与凭据事务**（1–1.5 pd）
- 目标：建立可被交互与非交互入口共用的 setup application service。
- 范围：非秘密答案 schema；YAML AST/结构化合并，保留无关配置；provider 与 vault 共用命名空间；staging、原子配置发布、提交标记、data_dir 级排他锁、并发修改检测、compare-and-restore 回滚与恢复；Loader/Provider/Binding 复用校验。
- 交付物：setup service + 文件/ vault 故障注入 spec + 无秘密快照。
- 依赖：无代码级前置；TUI 配置生成项须等 M6.5-WP4 提供 `channel_type=tui` 的生产装配，M4x-Setup-WP4 不属于首期内部门禁。
- **#274 路径接线约束**：M5.0-WP3 交付前，setup 使用显式 `--config`，并把生成的 persona 以配置目录内绝对路径写入 YAML，覆盖从不同 CWD 启动的校验/读取；resolver 就绪后，WP2/WP3 必须复用它并恢复配置相对 persona，不另写默认 home 推导。此项不改变 M4x 的 milestone 或提前授权开工。
- 验收：已有合法配置可复用，非法配置不覆盖；任一写入阶段失败能回滚或报告确切残留；取消/EOF 不改正式文件；provider key 可由 gateway 从同一 vault 回读。
- 风险：YAML 注释与格式保留不能靠字符串拼接承诺；首版至少保证未知字段和值语义不丢，格式保留另按库能力实测。[推演]

**M4x-Setup-WP2 行式问答与 `sebas setup` CLI**（1–1.5 pd）
- 目标：完成 Detect → Provider → Model → Agent → Channel → Binding → Review 的状态机。
- 范围：TTY 问答、默认值、上一步/编辑/取消/EOF、秘密隐藏回显、已有配置识别、脱敏摘要、`--config` 与非交互 answers；`cli.cr` 注册 setup；无 TTY 明确失败。
- 交付物：跨平台行式 UI + scripted IO spec + CLI help。
- 依赖：WP1。
- 验收：合法/非法/重试/编辑/取消路径完整；秘密不回显；无 TTY 不伪成功；交互与 answers 生成同语义配置。
- 风险：Windows 控制台输入与 POSIX 行为不同，须抽象终端输入而非散落平台分支。[推演]

**M4x-Setup-WP3 首次启动、文档与端到端验收**（0.5–1 pd）
- 目标：从空目录到可启动配置的可发现路径闭环。
- 范围：最终正式路径 Loader/vault 验证；可选最小 provider 检查及未实测标识；启动 gateway、等待 IPC/health、进入 TUI 的用户确认流程；README Quick start；手工 YAML 保留为高级路径。
- 交付物：next-step presenter + e2e spec/手动证据 + README。
- 依赖：WP2；M6.5-WP4/WP7 提供生产 TUI channel 与 `sebas tui`。
- 验收：setup 生成的配置进入真实 gateway 初始化；本地 binding 可路由；未调用真实 provider 时明确未实测；不会擅自停止用户已有 gateway。
- 风险：M6.5 未闭环时只验收配置核心，不得把首次对话标为完成。[推演]

**M4x-Setup-WP4 外部渠道凭据引用与向导扩展（后续独立排期）**（1–1.5 pd，仅扩展点）
- 目标：让 Email/WeCom/Lark 以同等安全级别进入 setup。
- 范围：渠道 credential_ref、adapter/TokenProvider vault 读取、热更新轮换、按渠道子状态机、真实联调与未实测口径。
- 依赖：各渠道生产装配与 vault 读取契约就绪；另卡拆细估时。
- 验收：YAML 无渠道秘密；gateway 与 setup 读取一致；每渠道单独验收，不用 mock 冒充真机。
- 风险：本包不是首期默认可开工项；缺少前置时 #145 只可关闭本地 TUI 子范围，外部渠道另留卡。[推演]
