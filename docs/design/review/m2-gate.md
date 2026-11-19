# M2 门禁演练记录（design.md §14 M2 验收勾稽，2026-11-19）

> 环境：Windows 10 x64、Crystal 1.22.1。门禁三命令全绿（124 examples / ameba 0 / make release）。

## §14 M2 验收勾稽（L751 四条）

### 1. workflow run 崩溃重放幂等 ✅

`crystal spec spec/orchestration/engine_spec.cr`

- 效应三明治：intent 先落库（requestId）→ 每 action 一 phase 尾 checkpoint → complete/fail；
- 提交级幂等：同 trigger_event_id 重放 run——intent 已存在 → **零执行**（计数工具 0 调用）；
- 崩溃恢复：recover! → interrupted → resume_interrupted——**从最近 checkpoint phase 续跑**，
  已完成 phase 经动作 memo（决策级 FWW）跳过（计数工具仅补执行剩余 1 个）；
- restartLimit（store 层）防崩溃循环。

### 2. 审批超时 deny 实测（注入时钟快进）✅

`crystal spec spec/orchestration/approvals_spec.cr -e "denies on timeout with injected clock"`

- Approvals.clock 注入虚拟时钟，快进 1 小时超过 timeout_seconds=600 →
  deny "timeout deny (fail-closed)"，真实耗时 <3s；
- 决策顺序（fail-closed）：hardline deny > mode=off 放行 > 无人值守 deny >
  memo 重放 > 人工等待/超时 deny；
- hardline blocklist（rm -rf /、mkfs、Format-Volume、shutdown、fork bomb…）
  在一切模式（manual/off）之上拒绝——不可 override；
- 人工 approve/deny 双入口 API（TUI/HTTP 共用）写决策 memo（审计 reason）；
- 无人值守（cron/webhook/事件触发）默认 deny。

### 3. 预算熔断（超预算动作拒绝+账本留痕）✅

`crystal spec spec/orchestration/ledger_spec.cr -e "tripps the budget"`

- per-run token 记账：60+30=90/100 通过，再 20 → 拒绝；
- 熔断写 ledger `budget.exceeded`（spent/requested/limit 留痕）；
- run 间隔离（run:b2 不受影响）；正常 spend 记 `budget.spend`；
- lease：acquire（他人持有拒绝）/heartbeat 续租/release/过期回收（reap）。

### 4. runs 回放与审计（任一 run 可按事件序重放展示）✅

`crystal spec spec/orchestration/runs_view_spec.cr`

- engine 写 ledger 事件：run.start → action.start → action.done → run.done；
- RunsView.list（workflow_run intents）/ get（intent+task 状态+事件序回放）；
- 双入口：HTTP `/api/v1/runs.list|runs.get`（token 鉴权、未知 run 404）+ IPC
  `runs.list|runs.get`；
- 回放断言事件序 = 实际执行序 `["run.start","action.start","action.done","run.done"]`。

## 门禁三命令

| 命令 | 结果 |
|---|---|
| `crystal spec` | 124 examples, 0 failures |
| `./bin/ameba` | 0 failures（79 files） |
| `make release` | bin/sebas.exe 构建成功 |

## M2 期已落地 WP

WP1 DSL / WP2 持久 Task 引擎 / WP3 触发器统一 / WP4 审批 / WP5 账本+预算+lease / WP6 runs API。

## 期间修复的关键缺陷（回写记录）

1. `intents_with_prefix` 初版漏传 LIKE 参数（占位符绑 NULL）——引发「写后读不可见」长链排查；
   最终以参数修复；期间曾误判为 WAL 快照问题并切 DELETE journal，根因确认后已回滚 WAL（Pi 口径保持）。
2. engine `spawn_run` 完成后统一标 intent=done（含 action 失败 run）——intent 状态口径：
   dispatched（在途）/done（终态）；run 级失败以 task.status=failed 表达。

## 未竟项（不阻塞 M2 门禁）

- 审批通道中的「看不全的命令只给 Deny」（Hermes 细节级借鉴）——UI 呈现层（M2-WP4 TUI 渲染随 M3 TUI 完整化）；
- DSL 条件求值（§7.6 condition 谓词）——v1 声明式谓词在触发器 source 匹配中已部分承载，
  完整 all/any/not 组合器随真实 workflow 场景补齐（不阻塞验收条目）。
