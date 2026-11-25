# design.md §4 总体架构

> 导航：[设计总览](../design.md) ｜ [文档索引](../README.md) ｜ 上一节：[§3](03-core-concepts.md) ｜ 下一节：[§5](05-multi-account.md)

## 4. 总体架构

### 4.1 分层职责

| 层 | 职责 | 关键设计 |
|---|---|---|
| **渠道适配层** | 维持每账号连接，收发消息，协议转换 | 每**账号**一个 adapter fiber + 监督 fiber；`abstract class ChannelAdapter` 扩展点；两形态归并（§5.2） |
| **入站事件总线** | 有界队列、事件路由、背压 | buffered Channel + 事件结构体显式携带 `(account_id, channel_type, peer)` 上下文 |
| **路由/编排层** | binding 查表、触发器求值、编排 Task 调度 | 路由是纯函数（配置快照原子替换）；编排引擎见 §7 |
| **Agent 执行池** | 执行 agent turn（LLM 调用 + 工具循环） | per-session worker fiber：同一会话保序、跨会话并行；全局并发上限 |
| **工具层** | 工具注册、执行、审批、Skills | 注册表声明 `replay` 语义与 `risk` 级别（类型级字段）；SKILL.md 免重编译扩展 |
| **Provider 层** | LLM 网关 | provider 配置层（#214：`providers.<name>` 承载密钥/base_url/protocol，多 agent 共享；显式 protocol 解耦厂商与 wire 格式）；实例池（每 agent 绑不同 provider/model，热更新按配置重建，密钥轮换下个 turn 生效）；规格表编译期常量兜底缺省 base_url |
| **持久层** | 会话/任务/事件账本/审批/配置快照 | SQLite WAL 单写者；JSONL 转录归档；keyring |
| **管理面** | TUI + HTTP API 双入口 | §9 |

### 4.2 Crystal 实现要点（机制落到具体用法，均有 autobot 实证先例）

| Crystal 特性 | 用在哪 | 先例（autobot 笔记 §9 实证 14 条） |
|---|---|---|
| **fiber + spawn** | fiber-per-account（连接监督）、per-session worker、subagent | `cli/gateway.cr:76` 命名 fiber；`channels/manager.cr:49-61` 每渠道一 fiber；`agent/subagent.cr:83` 每任务一 fiber |
| **buffered Channel（有界队列）** | 事件总线、结果传递；满时 send 阻塞=协作式背压，无需锁 | `bus/queue.cr:12-15` capacity=100 |
| **select + timeout** | 消费循环可停机、OAuth 回调等待、审批等待 | `bus/queue.cr:32-43`、`auth.cr:102-108` |
| **编译期宏** | 配置 schema 样板生成（N 渠道 × N 账号 × 校验） | `config/schema.cr:506-517` `{% for %}` 批量生成 provider 匹配 |
| **union alias + case/in** | 事件类型分派（InboundMessage / OutboundEvent / TriggerEvent…） | `bus/events.cr:122` + `channels/manager.cr:194-197` |
| **abstract class** | ChannelAdapter / Provider / Plugin / ToolObserver 扩展点 | `base.cr:19`、`provider.cr:14`、`plugin.cr:40` |
| **record（值语义）** | 事件、DTO、Task checkpoint | `bus/events.cr:116-122` record TurnEnded |
| **typed rescue 转值** | 错误不炸进程：工具错误转 `ToolResult.error`，LLM 错误转 Response | `http_provider.cr:83-87`、`registry.cr:75-123` |
| **无限重连循环惯用法** | 账号连接生命周期：`@running` flag + while + begin/rescue/sleep（指数退避） | `zulip.cr:44-60`、`slack.cr:41-64` RetryBackoff 5s→60s |
| **显式消息传递** | 上下文经结构体传递，**不用隐式全局可变状态**（Hermes contextvar 教训的反面：scope 由类型/构造器保证） | Hermes §8 反面教训 2：「隐式 scope 的漏」 |

### 4.3 进程模型

- **单常驻进程**为主：渠道连接、编排引擎、agent 池、HTTP API、IPC server 全在一个进程（OpenClaw 单 Gateway 模式；Hermes 教训：多进程共享单 SQLite 是运维痛点——本平台单进程天然规避，CLI/TUI 以客户端身份连入而非直开数据库）。
- 并发模型去 autobot 全局单 Loop（autobot B3：`cli/gateway.cr:76` 唯一 agent-loop fiber，一个慢 turn 阻塞所有会话含 cron/subagent 汇报）：**per-session worker 池**——会话首次入站时按 session_key 分配/复用 worker fiber，保证同会话顺序，跨会话/跨账号并行；worker 池有全局上限（防 fiber 失控，§8.3）。
- **无 JS Proxy 的应对**（Pi 笔记推论 §7.8）：文档 patch 不做自动记录，采用 **op-list 路线**——编排 DSL 的动作即操作序列，文档状态是其物化视图；agent 记忆文件用整文件写替换（autobot `memory.cr` 已是此模式）。
