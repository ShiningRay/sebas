# design.md §6 会话与记忆

> 导航：[设计总览](../design.md) ｜ [文档索引](../README.md) ｜ 上一节：[§5](05-multi-account.md) ｜ 下一节：[§7](07-orchestration.md)

## 6. 会话与记忆

### 6.1 会话管理

- **会话键含账号维度**（§3.3）：`agent:<agent_id>:<account_id>:<channel_type>:<peer>`。
- **路由粒度按对话形态**（OpenClaw §4.1 借鉴）：DM 默认 per-account-peer 隔离（多账号下必须，OpenClaw 教训 5：DM 默认共享是单用户假设，多人/多账号串台后补课）；group/room 按群隔离；cron/workflow 每次运行独立会话；webhook 按 hook 隔离。
- **SQLite 主存储 + JSONL 转录双写**：SQLite（WAL）存平台权威状态（会话消息、任务、事件账本、审批）；JSONL 按会话键分文件作**人可读转录归档**（保留 autobot A4 的运维友好性：文件即会话、0o600 权限、可 grep）。
- **working-set 内存模型**（Pi §2/§6）：只驻留活跃会话（活跃 transcript + live task + inbox），其余落盘；会话内存上界锚定「模型上下文窗口 + 固定余量」而非消息条数——支撑「数年消息史」。
- **compaction**：接近上下文上限时压缩，summary 落在下一 turn 边界；老消息永远留在存储不删，配 FTS5 事后检索（Pi §3 机制）。

### 6.2 记忆分层

| 层 | 内容 | 存储 |
|---|---|---|
| SOUL.md | agent 人格（system prompt 的一部分） | 每 agent 目录，人可读 Markdown |
| MEMORY.md | 长期精选事实，会话启动注入 | 每 agent，人可读 Markdown（整写替换） |
| USER.md | 关于用户（owner）的稳定偏好 | 每 agent，人可读 Markdown |
| HISTORY.md | 追加式过程日志，grep 可查 | 每 agent（autobot A5 双文件机制保留） |
| 每日笔记 | memory/YYYY-MM-DD.md，被索引不自动注入 | 每 agent（OpenClaw §4.2 形态） |

- 原则：**记忆主体是纯人可读 Markdown，SQLite 只做检索层**（OpenClaw 借鉴 5：可解释、可手改、可 git 管理）。
- **巩固流程**：会话消息数超 `memory_window` 时后台 fiber 用 LLM 产出更新（autobot A5：`memory_manager.cr` 机制；注意其教训——巩固不得与用户 turn 共用全局单 provider，须用该 agent 绑定的 provider 实例）。
- **FTS5 检索**：会话与记忆全文索引建在主 SQLite（Hermes FTS5 session search 同路线；旁证建议 4：多账号会话量下 grep 两层不可持续，直接上 FTS5）。

### 6.3 会话输入调度（Proposal，待实施）

支持持久 queue、可配置 debounce 与工具边界 steer：`batch_mode: queue|debounce` 两态 + `steer.enabled` 正交开关；默认 `queue` 且不启用 steer；停止/审批等控制输入走独立通道，不参与聚合。 **落位**（调度 WP3，#5）：debounce 模式已接线——六类 seal 条件（idle/max_wait/count/bytes/显式 flush/turn_end，Clock 注入单调时钟）+ bucket_key 分桶（sender|session）+ 忙碌期聚合（不饥饿）+ 结构化批次视图（原始 envelope 永久可查）；实现见 `sessions/scheduling/scheduler.cr`（debounce 分支 + seal_due 扫描器 + Registry 转发）与 `registry.cr`。

- 完整契约（状态机与关键时序、参数微调、持久化与恢复、安全边界）：[proposals/session-input-scheduling.md](../proposals/session-input-scheduling.md)。
- 执行状态与 WP 拆分：[tracking issue #9](https://github.com/ShiningRay/sebas/issues/9)（WP 子卡 #3–#8）。
- 本节仅作指针，不复制契约正文；契约变更先改 proposal 文档走 PR，实现合入后由 WP6 同步回写本文。
