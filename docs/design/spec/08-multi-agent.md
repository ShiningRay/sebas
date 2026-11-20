# design.md §8 多 Agent 协作

> 导航：[设计总览](../design.md) ｜ [文档索引](../README.md) ｜ 上一节：[§7](07-orchestration.md) ｜ 下一节：[§9](09-admin-protocol.md)

## 8. 多 Agent 协作

### 8.1 Agent 间消息（防环三件套，参数化照抄 Hermes §4.3）

- 工具 `message_agent(agent_id, content)`：**fire-and-forget**——发送方收 `ack=queued + delivery_id`，对方完成后带回复通知。
- **署名**：消息自动带前缀 `Message from 🤖 <agent_id>:`，收方知道来源。
- **防环上限**（配置项 `bot_loop_guard.max_hops`，默认 4）：一轮交换内 agent-to-agent 传递上限，超过拒发——防 agent 互发死循环。
- **回复默认不可再被回复**（`expect_reply=false`）：单向通知不产生回声链。

### 8.2 subagent（并行执行单元）

- subagent = **被拥有的会话/任务**（Pi §3：工具在 commit 内创建 ownership 子会话，崩溃重跑经 ownerTaskId 找回同一个）。
- 受限工具集：剔除 message/spawn 等社交工具、不能递归、不看主会话历史（autobot §8 现成先例：`create_subagent_registry`）。
- 结果以系统消息回注发起方的下一 turn（autobot `announce_result` 模式），但**不再依赖全局单 Loop**——直接投递到该 agent 的会话 worker（B3 修复）。

### 8.3 并发上限（信号量）

- autobot 教训 B8：`agent/subagent.cr:83-85` 每任务一 fiber、零信号量，多账号场景放大成资源失控。
- 本平台：subagent 并发用**命名信号量**（semaphore pool）约束，默认 `max_concurrent = 3`（可配；autobot 曾提议同值未实现）；workflow 可用 `max_concurrent_key` 共享同一个信号量（如「最多 2 个并发摘要任务」）。
- agent turn 的 worker 池同样有全局上限；请求超上限进入每会话队列排队（不丢弃、不饿死：队列按会话分片）。
