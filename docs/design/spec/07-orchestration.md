# design.md §7 编排引擎（硬需求②）

> 导航：[设计总览](../design.md) ｜ [文档索引](../README.md) ｜ 上一节：[§6](06-session-memory.md) ｜ 下一节：[§8](08-multi-agent.md)

## 7. 编排引擎（硬需求②专章：用户可编排）

### 7.1 三段式原语

**触发 → 条件 → 动作** 是编排的唯一原语；cron、事件触发器、webhook 统一归入触发源：

```
TriggerEvent ──→ [条件求值] ──→ [动作序列执行（持久 Task）] ──→ 产出（发消息/写状态/审批）
   ↑
   ├─ cron 触发（At / Every / Cron 表达式三态，autobot A10）
   ├─ 消息事件（email/wecom/lark 消息到达，含账号维度过滤）
   ├─ 账号事件（连接断开/恢复、token 失效等生命周期信号）
   ├─ 审批回执（approval 结果回流）
   └─ webhook（外部系统 POST /hooks/<name>，带鉴权）
```

### 7.2 执行语义：效应三明治 + 持久 Task（Pi §2 采纳）

编排执行采用 Pi Durable 的**效应三明治**（明确拒绝事件溯源）：

1. **执行前**：意图先落库（Task 表 insert：workflow_id、参数、phase=0）——写完即崩，重启后看到已验证输入、尚未运行的操作，直接接着运行。
2. **执行中**：每个动作一个 phase，phase 尾 commit checkpoint；崩溃后从**最后一个 checkpoint** 续跑（重放单位 = phase，不是事件流）。
3. **执行后**：结果落库，三明治完成，中间态可弃（留审计 trace）。

**任务树**：编排 run 是 Task 树（run → 动作节点 → 工具调用），subagent 动作是**被拥有的子任务**（Pi ownership 模式：崩溃重跑经 ownerTaskId 找回同一个子任务）。

### 7.3 幂等三件套（全采纳，Pi §4）

| 层 | 机制 | 本平台落地 |
|---|---|---|
| 提交级 | `requestId` exactly-once，建议直接用入站事件 ID | 触发事件 ID 即 requestId；重复投递（企微重试 3 次、飞书超时重推、webhook 重试）返回原结果不重跑 |
| 工具级 | `replay: "safe"` 显式二分；**未标注一律不重跑**，模型收到 interrupted 自行决策 | 工具注册表类型级字段；只读/整文件写入标 safe |
| 决策级 | memo first-write-wins | 审批结论、条件求值结果存 memo，崩溃重跑读到已存答案不再重复决策 |

**发消息类工具必须带幂等键**（Pi 笔记推论 §7.5 关键风险点）：`send:${account_id}:${msg_uuid}`——否则崩溃恢复会**重复发信**。类比 Pi 官方支付示例 `payment-${task.id}`。

**崩溃循环防护**：`restartLimit`（默认 5）——确定性崩溃（如内存耗尽）导致 resume-再崩循环时，连续被打断 5 次的任务**终止而非再跑**，错误上报（Pi §4）。

### 7.4 任务 lease、回收与预算（旁证 §一.1 六坑迁移）

- **lease + 过期回收**：动作任务带租约与超时，超时未心跳即回收重派或标记失败（旁证：队列型机制「任务须 lease+过期回收」最值得抄进编排内核；autobot 教训 B8：无上限无回收的 subagent 是放大器）。
- **预算**：每 workflow / 每 agent 可配 token 花费上限（`pi.usage` 式逐 provider/model/工具记账，Pi §6）；超限熔断并告警（旁证坑 5：token 花费须聚合）。
- **append-only 事件账本**：触发、条件求值、动作执行、审批全记入不可变账本（SQLite append-only 表），供审计与 runs 回放（旁证：vibey-engine append-only 账本）。

### 7.5 人工审批节点

- approval 动作节点：`pending → approved / denied / timeout`。
- **超时即拒（fail-closed）**：默认 300s（Hermes §6 层 2）。
- **无人值守默认 deny**：由 cron / webhook / 事件触发（无人可答场景）的 workflow 中，危险动作默认拒绝（Hermes：`cron_mode`/`unattended_mode` 三键默认 deny）。
- **审批模式**（借鉴 Hermes）：`smart`（辅助 LLM 评风险）/ `manual` / `off`，默认 manual 起步。
- **hardline blocklist**（不可 override 的地板）：`rm -rf /` 及变体、fork bomb、mkfs 活动根、Windows `Format-Volume`/`rd /s /q C:\`、`Restart/Stop-Computer` 等——在一切模式之上仍拒绝。
- 审批通道：管理面（TUI/HTTP）+ 绑定的消息渠道（审批卡）双通道；**看不全的命令只给 Deny 选项**（Hermes 细节级借鉴：绝不让人批准被截断的命令）。

### 7.6 DSL 示例（YAML）

```yaml
workflows:
  - id: inbox-triage
    description: "工作邮箱收件分流摘要"
    enabled: true
    trigger:
      type: event                          # 统一触发模型
      source: email.work-outlook.message.received
    condition:                             # 声明式谓词（v1 不做图灵完备）
      all:
        - from_matches: "*.notify@github.com"
        - subject_contains: "PR merged"
    actions:
      - id: record
        tool: memory.save                  # 动作 = 工具调用（含内置工具）
        args:
          content: "PR merged: ${trigger.subject}"
        replay: safe                       # 幂等，可安全重跑
      - id: notify
        tool: message.send
        args:
          channel: lark
          account: feishu-main             # 显式指定出站账号
          peer: "oc_review_group"
          content: "${trigger.subject}"
        idempotency_key: "notify:${trigger.event_id}"   # 发信幂等键
      - id: archive
        tool: label.apply
        args: { mailbox: work-outlook, label: processed }

  - id: weekly-report
    trigger:
      type: cron
      schedule: "0 9 * * 1-5"              # 工作日 9 点（cron 三态之表达式态，A10）
    actions:
      - id: gather
        tool: memory.search
        args: { query: "工作邮箱 本周要点", budget_tokens: 20000 }
      - id: send
        tool: message.send
        args:
          channel: wecom
          account: company-a
          peer: "userid_of_me"
          content: "${gather.result}"
        idempotency_key: "weekly:${trigger.scheduled_at}"
        approval:                          # 人工审批节点
          mode: manual
          timeout_seconds: 3600            # 超时即拒（fail-closed）
```

> 注（M4x-Comm-WP3 #187）：`subagent.ask`（跨 agent 求助并取结果）已自 `KNOWN_TOOLS`
> 白名单移除——校验期即报 `unknown tool`，不再存在「白名单有、执行无」的运行期失败路径。
> 「LLM 求助并取结果」类编排原语待后续 WP 设计（fork/join 是并行/汇聚原语，不是求助原语），
> 示例已改用既有原语表达；`label.apply` 为预留形态（同不在白名单）。

外部 webhook 触发示例：`POST /hooks/wake`、`POST /hooks/<name>`（带鉴权；OpenClaw §8 inbound webhooks 同构）。
