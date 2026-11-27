# design.md §13 目录结构与模块划分

> 导航：[设计总览](../design.md) ｜ [文档索引](../README.md) ｜ 上一节：[§12](12-plugin-layer.md) ｜ 下一节：[§14](14-roadmap.md)

## 13. 目录结构与模块划分（src/ 布局草案）

```
src/platform/
  cli/                     # 命令行入口（setup 初始化 / gateway 起 / 账号管理 / 审批）
  config/                  # 配置加载、schema（宏生成账号样板与校验，§4.2）；reload 管线（先验后换+Atomic 换引用，§11）；setup 事务写入
  bus/                     # 事件总线：有界 Channel + 账号上下文路由
  supervisor/              # 账号监督器：fiber-per-account、退避重连、健康上报
  store/                   # SQLite(WAL) 持久层：会话/任务/账本/审批 + FTS5
  keys/                    # 凭据 keyring / 静态加密（§10.2）
src/channels/
  base.cr                  # abstract ChannelAdapter（start/stop/send + account 维度）
  common/                  # markdown 转换器【A8】、token_provider【§5.3】、限流桶
  email/                   # imap_idle.cr / smtp.cr（gmail_api.cr 为备选，未实现，§5.4）
  wecom/                   # aibot_longconn.cr / app_callback.cr / crypto.cr（自实现 AES-CBC）
  lark/                    # ws_longconn.cr / webhook.cr
src/routing/
  binding.cr               # 路由表（most-specific，纯函数 + 快照原子替换）
src/agents/
  agent.cr                 # Agent 实例（大脑：人格+记忆+会话库+工具集+模型）
  pool.cr                  # per-session worker 池（并发上限、会话分片队列）
  session/                 # 会话管理（键含账号维度；SQLite+JSONL 双写）【A4 升级】
  memory/                  # MEMORY/HISTORY/USER/SOUL + LLM 巩固【A5】+ FTS5 检索
  skills/                  # SKILL.md 机制【A7，升格为主要扩展通道】
  subagent.cr              # SubagentManager：ownership 找回 + 命名信号量（M3-WP3；
                           # DSL 面已移除【§8.2 #187】，内部构件待求助原语设计复用）
src/orchestration/
  dsl/                     # 触发→条件→动作 YAML 解析与校验
  engine.cr                # 持久 Task 状态机（效应三明治、phase checkpoint）
  triggers/                # cron【A10】/ event / webhook / 账号生命周期事件
  approvals/               # 审批节点（超时 deny、无人值守 deny、hardline）
  ledger.cr                # append-only 事件账本 + 预算记账
  collaboration/           # message_agent + loop guard【§8】；生产装配在
                           # gateway.cr `build_collaboration_messenger`（registry/store
                           # 就绪后接线），工具面由 GatewayDispatch#attenuated_registry
                           # 按 agent.tools.allow 裁剪（#185/#186，装配未接线即不可见）
src/tools/
  registry.cr              # 注册表【A9 升级：replay/risk 类型级字段、allowlist、脱敏】
  executor.cr              # ReAct ToolExecutor + Observer【A6】
src/providers/             # Provider 实例池 + 规格表【A1/A2】；crystal_llm_provider.cr 为
                           # crystal_llm 适配层（每实例复制独立 CrystalLLM::Context，多 agent
                           # 的 api_key/base_url 互不污染，LLM 异常统一转 Completion.error）
src/admin/
  ipc/                     # NDJSON 协议（hello/caps/8MiB 帧，autobot 713ed632 模式）+ reload 命令【§11】
  http/                    # HTTP API + 回调面 + SSE
  tui/                     # TUI（termisu 或自写，避开 AGPL 的 crysterm——旁证 §一.8）
src/plugins/               # 可选脚本层（§12）：manifest/包校验/registry、进程 runner、JSON-like 协议、
                           # 白名单 capability、精确 hook 索引、watchdog、版本生命周期 service
```

**autobot 可复用件承接表**（A1-A10，autobot 笔记 §10）：

| 件 | 去向 | 改造点 |
|---|---|---|
| A1 Provider 抽象+规格表 | `src/providers/` | 单实例→实例池 |
| A2 HttpProvider 双格式适配 | `src/providers/` | 直接搬（超时/重试/429/错误兜底齐备） |
| A3 有界 Channel 总线模式 | `src/platform/bus/` | 加账号维度路由（B3 架构改造） |
| A4 Session JSONL | `src/agents/session/` | key 加账号维度（B4）；升级为 SQLite+JSONL 双写 |
| A5 Memory 双文件+巩固 | `src/agents/memory/` | 巩固改用 agent 绑定的 provider 实例 |
| A6 ReAct ToolExecutor+Observer | `src/tools/executor.cr` | 直接搬 |
| A7 SKILL.md 机制 | `src/agents/skills/` | 升格为主扩展通道（B6 缓解） |
| A8 渠道 Markdown 转换器 | `src/channels/common/` | 直接搬（纯函数、与账号无关） |
| A9 工具注册表骨架 | `src/tools/registry.cr` | session_key 含账号；加 replay/risk 字段 |
| A10 cron 三态调度 | `src/orchestration/triggers/` | owner 加账号维度（B7）；投递进对应 worker |

### 13.1 外部依赖（`shard.yml`）

运行时依赖只有四项，全部按「来源 + 版本策略」显式登记，新增依赖须回写本表：

| 依赖 | 来源 | 版本策略 | 用途 |
|---|---|---|---|
| `db` | `crystal-lang/crystal-db` | `~> 0.15` | 持久层抽象 |
| `sqlite3` | `crystal-lang/crystal-sqlite3` | `~> 0.24` | SQLite(WAL) + FTS5 驱动 |
| `file_watcher` | `naqvis/file_watcher` | `branch: main`（上游无 tag） | 配置热更新的文件监听（§11） |
| `crystal_llm` | `ShiningRay/crystal-llm`（fork） | 不锁版本（上游无稳定 release） | Provider 适配层（`src/providers/crystal_llm_provider.cr`） |

`crystal_llm` 是 ruby_llm 的 Crystal 移植：改动先落 fork，再定期向上游 `stevegeek/crystal-llm` 提 PR；
上游出稳定 release 后改为锁定版本号并更新本表。适配层当前支持 `openai` / `anthropic` / `deepseek` /
`openrouter` 四家，`base_url` 可覆盖。内部 `apply_provider_config` 对未列入的 provider 名抛出异常，
公开 `complete` 捕获该异常并返回 `Completion.error`，不向调用方抛出，也不静默回落。
