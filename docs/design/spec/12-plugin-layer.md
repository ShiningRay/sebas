# design.md §12 插件脚本层（硬需求④）

> 导航：[设计总览](../design.md) ｜ [文档索引](../README.md) ｜ 上一节：[§11](11-hot-reload.md) ｜ 下一节：[§13](13-module-layout.md)

## 12. 插件脚本层（硬需求④专章：裁剪 mruby 子进程）

> 初稿依据热更新笔记 §8；2026-11-19 按用户确认采纳[子进程可行性报告](../review/m3-plugin-feasibility.md)，并补充分发、生命周期与钩子契约。

### 12.1 定位与分工

- **可选模块**：插件层不进主链路——配置热更新（§11）等核心能力不依赖它。
- **与 SKILL.md 分工**：SKILL.md 承载**知识文档**扩展；插件脚本承载**代码能力**（自定义工具/钩子/定时动作/受控后端）。
- **不做插件市场**：开发者独立分发单文件包，用户显式安装；不自动下载依赖，不引入 CRuby/RubyGems/Bundler。这里的“单文件包”指一个 `.sebas-plugin` 分发文件，不承诺未来永远只有一个源文件；受控多文件的演进边界见[插件复杂化演进规划](../review/plugin-evolution.md)。

### 12.2 运行时、声明与派发契约

- **每动作一个裁剪 mruby 子进程**：每次调用启动新进程，结束即释放 VM。mrb.cr 进程内绑定复核为 **84/84 通过**，但 mruby 无指令级执行配额，进程内死循环无法由宿主 watchdog 打断，故不作为首版运行形态。
- **静态声明 + 精确注册**：manifest 的 `hooks` 是插件意图和授权上限，宿主据此建立 `hook_name → [(plugin_id, version, priority)]` 索引；`on_hook(name)` 只在该次进程内登记具体 handler。manifest 未声明、handler 未注册、插件未启用或版本不一致均不派发，**不向全部插件广播所有钩子**。
- **声明校验**：安装时校验 manifest 中 hook 名称、类型、所需 capability 与配置 schema；开发/启用冒烟在无副作用沙箱中加载脚本，收集 handler 并验证 manifest 与注册集合相符。handler 重复、未知 hook、缺 handler、额外注册均拒绝激活。
- **每次调用的注入**：runner 校验请求后注入 `$action`、`$config`、`$context`、`$payload`、`$idempotency_key`，执行 `plugin.rb` 完成注册，再按 `$action` 精确调用 handler。**handler 以该 hook/action 的 `$payload` 作为唯一业务参数**（on_hook 块参数即 payload；如 `memory.remember.before` 的 payload 含 `entry`），参数形状由 §12.11 钩子目录与 manifest 声明定义。`$context` 的授权身份以宿主保存的原始值为准，插件修改全局变量不能扩大权限。
- **无跨调用 Ruby 状态**：全局变量、block 和对象只在本次进程有效，不能当缓存或持久状态；持久状态经白名单 capability 保存并带 schema 版本。
- **JSON-like 协议**：只传数字/字符串/布尔/null/数组/哈希，不传 Crystal/Ruby 对象或 Proc。请求包含 `protocol_version`、`request_id`、`plugin_id`、`action`、`context`、`payload`、`config`；stdin 输入请求，stdout 返回结果，stderr 仅受限诊断。采用有长度上限的 NDJSON，校验恰好一个结果、schema、大小和请求 ID；预研 `RESULT` 行不是兼容承诺。
- **capability 宿主调用（host-call）帧**：handler 执行期间经宿主 driver 访问外部服务的协议按双向帧定义——插件向 stdout 输出 `{"type": "capability_call", "call_id", "capability", "params"}`；宿主校验该 capability 已在 manifest 声明且在授权快照内（**授权绑定到 capability 名称本身，即其代表的一类 driver 操作；帧内无独立 `op` 字段，capability 内不存在越权操作面**）、`params` 通过该 capability 的 schema 校验后执行 driver，并向 stdin 写回 `{"type": "capability_result", "call_id", "ok", "result" | "error"}`。执行期间 stdin 保持打开，宿主不发任何非应答帧。**`capability_call` 帧字段闭集**：仅接受 `type/call_id/capability/params` 顶层字段；capability 需要区分多种操作时必须声明为独立 capability 名称（如 `memory_driver.write/query/delete`），任何额外或未知的顶层字段（含帧内操作字段）一律**拒绝**——宿主返回 `ok: false` 的 `capability_result`（结构化错误）且不执行 driver，不做静默忽略。
- **host-call 语义**：注入脚本的 `capability(capability, params)` 是上述协议的同步封装，按 `call_id` 关联请求与应答；`params` 为该 capability/driver 定义的结构化参数。`capability_call`/`capability_result` 属传输帧，**不计入「恰好一个结果」**——最终结果必须是最后一行 result 帧，其后再有任何输出（含新 host-call）即拒绝该次调用；单次调用的 host-call 次数、单帧大小与总时长上限取 manifest 声明与宿主全局上限的较小者，超限按结构化错误终止；driver 调用一律以宿主注入的 agent/session scope 执行，插件不能传任意 URL、路径或凭据；host-call 失败以结构化 error 交付插件，插件仍须产出唯一最终结果。
- **能力声明**：`memory.backend` 等扩展点和 capability 由 manifest 静态声明，宿主按 active 版本及授权快照派发。外部服务由宿主 driver 执行，agent/session scope 由宿主注入。
- **单入口、无原生依赖**：首版只有 `plugin.rb`，不支持包内 DLL/so、安装脚本、自动依赖下载或其他 `require` 文件。复杂插件的受控多文件、显式初始化和按插件常驻 worker 属于后续演进，见[插件复杂化演进规划](../review/plugin-evolution.md)，不改变当前包契约或 M3 验收。

### 12.3 初始化与生命周期边界

首版采用**显式 action，不引入隐式全局 `init`**，避免“每次 hook 都执行一遍 init”的语义歧义：

| 时机 | 行为 | 是否执行插件业务代码 |
|---|---|---|
| 安装/升级 | 校验包、manifest、API、capability、配置 schema；无副作用冒烟加载以收集注册表 | 仅受控解析/注册，不允许外部效应 |
| 启用/激活 | 宿主生成精确 hook 索引与版本快照；旧版在途调用继续旧快照 | 不额外执行一次 init |
| 每个 action/hook | 新进程 → 注入本次请求 → 执行脚本声明 → 精确 dispatch 一个 handler | 只执行本次 handler 及其 capability |
| 禁用/卸载 | 原子摘除注册快照，保留或按 purge 规则处理数据 | 不承诺运行 cleanup；外部资源由宿主 driver 回收 |

- 如插件确需一次性建schema/检查外部服务，声明 `actions: ["install", "enable", "disable"]` 及对应 `on_action`，由宿主在生命周期节点显式调用，遵循幂等、审批、超时与迁移事务；**不是包安装脚本，不在 pack/validate 时执行**。显式 `install` action 属包安装完成后的独立生命周期调用（宿主在 `install`/`enable` 命令节点执行），其外部效应不属于包安装——生命周期表『安装/升级』行的包安装本身始终只解析/注册；action 失败不回滚包安装，包保持在 disabled/staged 状态。
- `gateway.start` / `gateway.stop` 是生命周期观察钩子，不等于 init/cleanup；需要常驻 worker 的插件不属于首版模型。
- `enable` 失败保旧版；action 崩溃只影响该次调用，不自动重试副作用。重复 enable/disable 应幂等，升级数据迁移成功与版本指针切换保持原子语义。

### 12.4 沙箱与 watchdog

**不依赖语言级 `$SAFE`**；进程隔离增强故障边界，但不代替资源控制：

| 闸 | 子进程形态 | 效果与边界 |
|---|---|---|
| ① gembox 裁剪 | 剔除 `mruby-io`/`mruby-socket`，仅保留必要 stdio | 无直接文件/网络 IO，外部效应只能走 capability |
| ② 资源约束 | 构建期 allocf 配额 + 宿主 OS 级进程限制 | 插件内存失控不破坏宿主堆；仍须防整机内存压力 |
| ③ 能力白名单 | 协议动作与 capability 双重授权 | 任意名称、URL、路径、命令不自动获得权限 |
| ④ watchdog | 按 manifest 与全局较小超时终止进程树 | 死循环不卡宿主；清理后代进程并丢弃迟到输出 |

- 预研已验证脚本执行、exit code、stdout 与可 kill 模型；本机 Windows 新 exe 链接仍有环境 blocker，恢复条件见[可行性报告](../review/m3-plugin-feasibility.md)。
- 解释器随平台交付并锁定版本，插件包不携带或选择解释器。API 兼容不等于已授权。
- 子进程不是内核沙箱：仍须限制 CPU、内存、输出、运行时长和进程树，不能声称仅靠 mruby 即可安全执行未知来源脚本。

### 12.5 激活与热重载 = 先验后换版本指针

- 安装/升级包先写入独立版本目录并完整校验，通过后保持 staged（升级场景为已安装待激活）；**当前版本指针只在显式 `enable`/`activate` 成功时原子切换**（§12.7 状态机 `absent → staged → installed(disabled) → enabled(active)`），安装或升级本身不切换指针。每次调用固定 `(plugin_id, version, config_snapshot)`；在途调用用旧快照，新调用用新版本。
- `sebas plugin dev <目录>` 提供开发 watch，修改仅影响新调用；生产不直接监视或加载任意 `plugins/*.rb`。
- 解析、manifest、注册集合、配置迁移或授权校验失败，旧 active 版本保持不变。
- 复用 §11「触发—校验—换引用—每 turn 快照」管线，payload 是插件版本指针和 manifest，而非 Config 或 mrb_state。

### 12.6 包格式与安装布局

**分发单元**是 ZIP 格式、扩展名为 `.sebas-plugin` 的单文件；扩展名不是安全边界。首版包根只允许：

```text
remote-memory-1.2.0.sebas-plugin
├── manifest.json  # 必需：身份、版本、API、扩展点、capability、配置 schema
├── plugin.rb      # 必需：唯一脚本入口
└── README.md      # 可选：用途、配置、权限和数据语义
```

```json
{
  "schema_version": 1,
  "id": "remote-memory",
  "version": "1.2.0",
  "api_version": "1",
  "entrypoint": "plugin.rb",
  "provides": ["memory.backend"],
  "actions": ["remember", "recall", "forget"],
  "capabilities": ["memory_driver.write", "memory_driver.query", "memory_driver.delete"],
  "timeout_ms": 1500,
  "config_schema": {"kind_weights": {"type": "object", "required": false, "additionalProperties": {"type": "number"}}}
}
```

- `id` 限小写字母开头的 1–64 位小写字母/数字/连字符；`version` 为 SemVer，`api_version` 为主版本兼容契约。文件名不参与身份或升级判断。
- 安装器拒绝重复文件/大小写冲突、绝对路径、`..` 穿越、符号链接/重解析点、额外套件和超限包。限额在实现时固定并测试；防压缩炸弹的限额校验**随解压流式执行**——边解压边累计未压缩字节数与文件条目数，超限立即中止并清理 staging，不得先完整解压再校验。
- 首版以明确来源与人工审查为信任基础；发布者签名/可信指纹为后续增强。SHA-256 只证明内容完整，不证明作者可信。
- `pack` 只收录白名单文件；禁止包安装脚本、post-install hook、包内原生扩展与自动依赖解析。

以 `gateway.data_dir` 为根，**代码、配置、数据严格分离**：

```text
data/
├── plugins/
│   ├── installed/<plugin-id>/
│   │   ├── versions/<semver>/{manifest.json,plugin.rb,README.md}
│   │   └── current.json      # 原子版本指针；不依赖 Windows symlink
│   ├── staging/              # 仅安装器写入；永不直接执行
│   └── registry.json         # 版本、active、启停、授权、摘要
├── plugin-config/<plugin-id>.yaml  # 用户配置与凭据引用；升级不覆盖
└── plugin-data/<plugin-id>/        # 状态/迁移元数据；业务记忆优先走宿主 Store
```

注册表原子持久化 `schema_version`、各版本摘要、`active_version`、`enabled`、`approved_capabilities`、来源摘要和安装/激活时间。运行时仅从 registry 选定的 active 版本加载。

### 12.7 开发、分发与安装

```bash
sebas plugin validate .
sebas plugin pack . --output remote-memory-1.2.0.sebas-plugin
sebas plugin dev .
sebas plugin install ./remote-memory-1.2.0.sebas-plugin
sebas plugin enable remote-memory
```

`pack/validate` 校验 manifest、SemVer/API、包白名单、路径与大小，并以同版本裁剪解释器做脚本解析及无效应契约冒烟。产物可放 GitHub Release、内部分发或直接传文件，不依赖市场。

状态机为 `absent → staged → installed(disabled) → enabled(active)`；失败留在可清理的 staging。安装默认**不启用**，展示 ID、版本、扩展点、capability 和数据语义。同 ID 同版本同摘要重复安装幂等返回；同版本不同摘要拒绝覆盖，必须递增版本。

`enable` 再校验配置、宿主 API、扩展点冲突和已批准 capability。记忆后端须显式配置 `memory.backend: plugin:remote-memory`，安装不能静默替换默认后端。互斥后端由配置唯一选择；普通工具/hook 按命名空间和稳定顺序注册。

### 12.8 升级、回滚与数据迁移

```bash
sebas plugin upgrade remote-memory ./remote-memory-1.3.0.sebas-plugin
sebas plugin activate remote-memory 1.3.0
sebas plugin rollback remote-memory 1.2.0
```

1. 按安装流程校验新版本；`api_version` 主版本不兼容拒绝自动升级。新增/提升 capability、扩展点或风险等级必须再次显式批准，未批准不激活。
2. 升级只新增 `versions/<semver>`，不覆盖配置与数据。schema 变化须声明迁移版本，由宿主事务执行：**排空在途旧版本调用 → 取数据检查点 → 迁移 → 验证**，指针切换只随第 3 步 `activate` 成功发生；失败恢复旧版本，禁止代码回滚而数据静默留在不兼容的新 schema。三个不变量：**(a) 排空是唯一边界**——旧版本代码永远不读迁移后的新 schema：有界等待在途旧快照调用及其已发出的宿主 driver 操作完成；超时未结束的调用按结构化错误终止，其未完成的 driver 操作一并取消并确认不提交（driver 操作与插件调用同生命周期，不得在迁移开始后落库；已提交部分受幂等/memo 保护）；无法排空时须为旧调用提供版本化兼容数据视图（同样读不到新 schema）。**(b) 检查点在排空边界之后取得，恢复不静默丢弃已确认写入**：已排空调用的全部已确认写入包含在检查点内；兼容视图调用写入版本化兼容数据、不写被迁移 schema——检查点之后被迁移 schema 上无新写入，恢复检查点不丢已确认数据；兼容视图写入按迁移声明的回放规则并入，无法回放的差异在 activate 校验中显式报告。**(c) 从迁移开始到恢复路径完成前，对该插件的新调用保持拒绝或排队**——active 指针仍指旧版本，放行即让旧代码访问新 schema。封锁解除为二选一：`activate` 成功换指针；或迁移失败后宿主恢复旧版本数据并校验版本/数据一致性通过，此时直接放行恢复服务，不要求也不触发 `activate`——迁移失败不得使已恢复的插件无限期不可用。**迁移成功但 `activate` 校验失败**：数据已在新 schema，禁止回退旧版本——宿主保持封锁并重试 `activate`，或执行迁移声明的回退事务恢复迁移前检查点后按 (b) 解封；不出现「数据已迁移、指针未换、封锁又解除」的中间态。
3. `activate` 原子换指针；当前 turn/调用继续旧快照，新调用用新版本。默认保留当前版及上一已知可回滚版；未被引用的旧版按保留策略清理，不立即删除唯一回滚点。
4. 降级安装默认拒绝；`rollback` 只允许 registry 中且与当前数据 schema 兼容的已安装版本，否则提示恢复相应备份。升级不重试未完成的副作用动作，幂等键按 §7.3 执行。

### 12.9 禁用、卸载与数据保留

```bash
sebas plugin disable remote-memory
sebas plugin uninstall remote-memory
sebas plugin uninstall remote-memory --purge
```

- `disable` 阻止新调用并注销新任务可见的工具/hook/定时注册，不删除代码、配置或数据；在途调用按快照结束或被显式取消。
- `uninstall` 默认要求先 disable；若 agent 后端、binding、workflow、approval 或其他插件仍引用它，列出引用并 fail-closed 拒绝。扩展点被引用时先显式切回 `builtin` 或另一已启用后端，不自动迁移业务数据。
- 默认卸载只删除代码、版本指针及注册项，保留 `plugin-config/` 和 `plugin-data/`；再次安装同 ID 不自动恢复授权或启用。
- `--purge` 先展示配置/数据范围并要求交互确认，非交互模式须额外明确确认参数。外部记忆服务数据不因本地 purge 自动删除，须由 driver 明确支持并再次确认。
- 卸载后相关注册对新任务不可见；已持久化任务若引用缺失插件则进入可诊断的 blocked/failed 状态，禁止悄悄改调内置后端。

### 12.10 能力安全与统一命令面

| 要素 | 本平台设计 |
|---|---|
| 发现 | 用户显式提供本地 `.sebas-plugin`；开发模式监视显式目录；不扫描远程市场 |
| 契约 | `manifest.json` + 版本化 JSON-like 请求/结果 + 静态扩展点与 capability |
| 能力注册 | 首批：工具 / 钩子 / 定时 / 受控 `memory.backend`；risk/replay 由宿主登记 |
| 生命周期/隔离 | 每动作独立进程；staging→安装→启用→激活→回滚→禁用→卸载；数据默认保留 |

- **注册工具**：走 §10.3 审批链与 §4.1 同款 registry，具有 risk/replay 类型字段；默认 `risk: high`，hardline blocklist 不可被插件 override。插件不能自行降低风险，只有宿主全局策略可按工具明确配置。
- **钩子/定时**：同步 hook 按 §12.11 精确派发；workflow 事件触发复用 §7.1 的预算、lease 和无人值守 fail-closed，插件不自建调度循环。
- **能力不是任意 RPC**：capability 仅调用宿主登记的 driver 和操作，agent/账号 scope 由宿主注入。插件 stdout/stderr 与业务数据日志必须脱敏、限量。
- CLI 与 §9 管理面共用同一 service，不允许 CLI 绕过 gateway 的 registry/授权直接改运行目录。提供 `plugins.list/get/validate/install/enable/disable/activate/rollback/uninstall`；pack/dev 为离线开发命令，不需要 gateway 权限。

### 12.11 钩子目录与执行语义（首版闭集）

对照 [OpenClaw typed hooks](https://docs.openclaw.ai/plugins/hooks)、[Hermes plugin hooks](https://hermes-agent.nousresearch.com/docs/user-guide/features/hooks) 与 [Pi Durable task hooks](https://earendil.com/posts/pi-durable/#hooks)，首版采用 22 个明确命名的钩子（`gateway.start` 与 `gateway.stop` 是两个独立名称，验收分别覆盖）；未列出的专属能力不自动成为 Sebas 契约。同步 `before/transform` 与 `observe` 必须分开实现，不能一律当异步事件处理。

| 域 | 钩子 | 类型 | 宿主注入点与契约 |
|---|---|---|---|
| 消息 | `message.received` | observe | 渠道验真、鉴权、去重并解析完成后、进入路由前；只读，失败不阻断接收，不是原始传输包审计或修改入口 |
| 消息 | `message.sending` | gate + transform | 实际渠道投递前，可 `allow/modify/deny` 文本与附件元数据；不得替换账号、收件人或绕过 hardline |
| 消息 | `message.sent` | observe | 渠道返回投递结果后，含 `status/error/message_id/error_code`；不保证用户已读，不在此盲目重发 |
| Agent | `agent.turn.before` | gate | Agent turn 开始、LLM 请求前，可允许或拒绝整个 turn；宿主保留原始 prompt 与 scope |
| Agent | `agent.turn.after` | observe | turn 完成（含成功、失败、中断）后，带结果状态和耗时；不得再次启动隐式 turn |
| LLM | `llm.request.before` | gate + transform | Provider 每次请求前，可拒绝、追加受控 context 或修改允许的 request 字段；model/provider/凭据/endpoint 由宿主固定 |
| LLM | `llm.request.after` | observe | Provider 规范化成功后，含 response、usage、耗时与 request_id；日志须脱敏 |
| LLM | `llm.request.error` | observe | Provider 每次失败尝试后，含错误类型、状态码、重试序号；不改变既定重试策略 |
| LLM | `llm.response.transform` | transform | `llm.request.after` 后、最终回复/工具调用解析前，可替换文本；宿主再次解析和校验 |
| 工具 | `tool.call.before` | gate + transform | registry 查找后、执行前，可改写白名单参数、拒绝或请求审批；risk/replay/审批由宿主裁决，异常与超时 deny |
| 工具 | `tool.call.after` | observe | 工具成功、业务错误或异常转为 ToolResult 后；只读，payload 键见统一执行规则（tool_id/request_id/session_key/status/duration_ms/result_summary） |
| 工具 | `tool.result.transform` | transform | `tool.call.after` 后、结果返回 Agent 前，可替换受限文本结果；不能改变 replay/risk、幂等账本或已发生副作用 |
| 会话 | `session.start` | observe | 新会话上下文建立后；仅通知，不得在每次消息时误触发 |
| 会话 | `session.end` | observe | 会话重置、删除、Gateway 终止等明确边界，带 reason；在预算内做只读收尾 |
| 会话 | `session.compact.before` | observe | 压缩任务开始时，只读；首版不能 veto 或替换摘要 |
| 会话 | `session.compact.after` | observe | 压缩任务成功提交后，带计数和摘要元数据；失败/取消不触发 after |
| 记忆 | `memory.remember.before` | gate + transform | 后端写入前，返回 `allow/modify/deny` entry；宿主重新校验后才写入 |
| 记忆 | `memory.remember.after` | observe | 后端提交成功后，含 memory_id/kind/tags；失败或 deny 不触发 |
| 任务 | `task.start` | observe | 持久 workflow/task 创建并落库后，带 run_id/workflow_id；不是每次 phase 重放都创建新任务 |
| 任务 | `task.end` | observe | task 进入终态后，带 `task_id/status/error`；不能改变终态或重试副作用 |
| 平台 | `gateway.start` / `gateway.stop` | observe | 插件 registry 就绪后 / 渠道停止前；stop 有全局有界等待，不承诺全部消息已投递 |

`llm.request.error` 的每次尝试语义与 `agent.turn.after` 的最终 turn 语义不得混淆；`session.compact.after` 的提交完成不等于所有下游消费者已刷新。首版**不开放**原始渠道包改写、任意系统提示替换、自由 `claim` 接管 Agent 回复、`before_install`、动态 skill 改写、任意 cron 状态改写；这些需要单独 capability 和威胁模型。

**统一执行规则**：

- `on_hook` 的 handler 块参数是该 hook 的 **payload 对象（唯一业务参数）**——如 `memory.remember.before` 的 payload 含 `entry`；各 hook 的 payload 字段由本目录『宿主注入点与契约』列与 manifest 声明约定，runner 按此契约实现；`$config`/`$context`/`$idempotency_key` 经注入变量提供，不占用块参数。
- **payload 键与类型契约**：表中列出字段的行，其字段即该 hook payload 的必需键，值类型限于 §12.2 JSON-like 原语（string/int/bool/enum/null/数组/哈希），宿主不得臆加未列字段，manifest 与宿主实现必须使用同一键名与类型。哈希值按 JSON-like 递归规则校验：键为 string，值为本表所列原语之一，嵌套深度与总大小受 §12.2 的 NDJSON 上限约束；需要结构化的字段（当前只有 `task.end.error`）按此校验，不得传入 Crystal/Ruby 对象。完整示例——`tool.call.after` payload：`tool_id: string`、`request_id: string`、`session_key: string`、`status: success|error|exception`、`duration_ms: int`、`result_summary: string`（受限文本，不含敏感原文）；`message.sent`：`status: success|error`、`message_id: string|null`、`error_code: string|null`；`memory.remember.after`：`memory_id: string`、`kind: string`、`tags: string[]`；`task.start`：`run_id: string`、`workflow_id: string`；`task.end`：`task_id: string`、`status: string`、`error: object|null`（结构化错误，键集由宿主在 WP5 定稿，出现时至少含 `code: string`，可含 `message: string`）。其余 hook 在 WP5 实现时按本规则定稿。
- manifest `hooks` 与脚本 `on_hook(name)` 注册集合必须一致，宿主按 §12.2 的索引只调用订阅者；同插件重复注册拒绝，不同插件按 priority（数值大者优先）再按插件 ID/注册序稳定排序。
- `gate + transform` 同步按序执行，每个处理器接收上一个已校验结果；任一 deny 停止后续处理器。`observe` 按注册快照执行、忽略返回值，可并发但不得阻塞主流程；观察副作用不保证持久化或严格全序。
- 所有插件调用遵守独立进程、schema/大小限制和 watchdog。gate/transform 的异常、超时、非法结果默认 **deny**；observe 的异常、超时记录脱敏日志并跳过。宿主 hardline 不可被返回结果覆盖。
- 同步 hook 不是 §7.1 workflow trigger；其 handler 若要发起独立工作，只能经显式 task/capability 创建。插件不能自建循环或借 hook 递归触发自身，宿主设置每 turn hook 次数/深度/总耗时上限。
- `context` 由宿主保存并注入可信 agent/account/session/run 标识。含 prompt、历史、工具参数、消息或错误文本的 hook 属敏感数据，按 manifest capability 单独批准，默认最小字段与脱敏。
- 可恢复 task 相关 hook 可能重放；决策通过宿主 memo/idempotency_key 持久化，禁止依赖 `$` 变量保存跨调用状态。已发生的消息发送、工具执行等效应不因 transform/observe 失败而回滚，未知状态 fail-closed 不盲目重试。

**示例（声明式 DSL）**：

```ruby
on_hook "memory.remember.before" do |payload|
  entry = payload["entry"]
  deny!("empty_memory", "Memory text must not be empty") if entry["text"].to_s.empty?
  modify(entry.merge("tags" => (entry["tags"] || []).uniq))
end

on_hook "tool.call.after" do |event|
  # 只读观察；需要持久化时调用宿主显式 capability，不写本地文件。
  nil
end
```
