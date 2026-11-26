# M4 门禁演练记录（design.md §14 M4 验收勾稽，2026-11-26）

> 环境：macOS arm64、Crystal 1.22.3。门禁调度四条全绿（390 examples / ameba 0 / make release / format-check）。
> 本文件承载 v0.2.0 的发版闸（[B.3](../plan/schedule/gates.md)：M4.4 是 v0.2.0 发版闸）。
> `auto-release.yml` 的 minor 路径按 milestone `order: 4` 解析到本文件，缺失即拒绝发版。

## §14 M4 验收勾稽（六条）

### 1. fork e2e：分身并行跑通、回写不丢、键不漂移 ✅

`crystal spec spec/orchestration/fork/e2e_spec.cr`（2 examples, 0 failures）

- 3 分身并行：父会话 fork → 快照派生 → 各自独立会话键 → 全部执行完成；
- 回写不丢：join 三层回写（L1 join.report 落父会话 / L2 成员键 / L3 行数引用）齐全；
- 键不漂移：分身键 `agent:<父>:internal:fork:<fork_id>:<member_index>` 五段结构与 subagent 同构，
  成员各自独立 transcript（`spec/orchestration/fork/executor_spec.cr` 3 examples 佐证任务树登记与成员级键）。

### 2. L3 审批拦截 fail-open 为零 ✅

`crystal spec spec/orchestration/fork/approvals_gate_spec.cr`（5 examples, 0 failures）

- L3 不可逆操作无论分身是否显式声明工具，均叠加 `Approvals::Center` 审批链（声明≠免审批）；
- 审批拒/超时一律 deny，不存在绕过路径；hardline 之外仍由 Center 语义拦截。

### 3. join 三层回写：冲突不自动 merge、partial 标注可见 ✅

`crystal spec spec/orchestration/fork/join_writer_spec.cr`（5 examples, 0 failures）
`crystal spec spec/orchestration/fork/side_effect_spec.cr`（7 examples, 0 failures）

- 以文件指纹双基线判冲突；冲突进父裁决清单，join 侧**不自动 merge**；
- JoinWriter 三态（Written / Duplicate / NonTerminal）——open/settling 拒绝回写，memo 不被未完成报告占住；
- 报告行与 memo 同一 SQLite 事务原子提交（`Store#write_join_report`），partial 在报告中可见。

### 4. 能力衰减：默认只读、越界声明剔除可观测 ✅

`crystal spec spec/orchestration/fork/capability_spec.cr`（7 examples, 0 failures）

- 未声明 `tools` 的分身运行默认只读档：无写副作用工具、不携带 secrets、无 fork 工具；
- 显式声明时生效集 = 声明 ∩ 父 `tools.allow`，越界声明静默剔除并在回执列明（可观测）。

### 5. 父崩溃恢复续判、回写幂等 ✅

`crystal spec spec/orchestration/fork/expectations_spec.cr`（7 examples, 0 failures）

- expectations 表承载 mode/deadline/成员状态机（open → settling → settled，旁路 cancelled/expired），持久化保证父崩溃后可续判；
- 成员终态不冗余（读 tasks 聚合，单一事实源）；
- 回写以 memo 键 `join:<fork_id>:written` 幂等，重复回写返回 Duplicate。

### 6. 回收 GC 有人工确认（M4.4）✅

`crystal spec spec/sessions/lifecycle/lifecycle_spec.cr`（7 examples, 0 failures）

- `gc_archived(archive_dir, archive_confirm: true)` 才清理；`archive_confirm: false` 时**不清理**（人工确认闸）；
- 不重复回收（二次调用返回 0）；
- 目录限定：`base_dir` 注入后越界目录拒收不写盘；
- 1 条 pending：`gc symlink 复核`（Windows symlink 需特权，已按 pending 显式登记，非静默跳过）。

## 门禁调度四条

| 命令 | 结果 |
|---|---|
| `make format-check` | 通过（`crystal tool format --check` 无输出） |
| `make spec` | 390 examples, 0 failures, 0 errors, 0 pending |
| `make lint` | 150 files inspected, 0 failures |
| `make release` | `bin/sebas` 构建成功，`sebas version` 输出 `sebas 0.1.0 (dd2f1abcf171)` |

`make format-check` 与 CI 的 `crystal tool format --check` 同源；CI 在本次发版基线 commit `dd2f1ab` 上三平台 spec 全绿（run 45842222280）。

## docs 同步核查

- `docs/design/spec/08-multi-agent.md` §8.4 的 fork/join 契约摘要已含 M4.1–M4.4 各 WP 的落位注（表/判定器/Executor/JoinWriter/触发面/能力衰减）；
- `docs/design/spec/14-roadmap.md` 的 M4 行、`docs/design/plan/wbs/m4-fork-join.md` 与 GitHub milestone #2 的 45 张已关卡片一致；
- `ruby tools/check_docs.rb`：87 文件，FAIL 0，WARN 45（均为既有存量长行告警，不阻断）。

## 风险复核（§15.1 口径）

M4 期未新增「未实测即当已测」项。需如实记录的边界：

- **真实邮箱长期稳定性仍未实测**（§15.1.2）：Gmail 走应用专用密码路线，设计的兜底手段（兜底轮询 / 假活判定 / 指数退避）**尚未实现**，由 M8.1-WP6（#239）承接。此项不属 M4 范围，但 v0.2.0 的 email 能力因此只有「能收发」而无「长稳兜底」——已记入 §5.4 与 §15.1.2。
- **生产装配可达性**（#187 新立口径）：M4 的 fork/join 三处入口均已接线并可指认——对话流 fork 工具（`src/platform/cli/gateway.cr:348`）、IPC `fork`/`join` 命令（`src/admin/ipc/server.cr:209`）、DSL `fork` 动作（`src/platform/cli/gateway_dispatch.cr:165`）。不存在「spec 通过但执行面不可达」的缺口。
- **门禁证据为 spec 级**：本文件六条勾稽全部锚在 spec 通过记录上，未做真机 round-trip；M4 的期级验收不含真机条目（真机归 E.1 与 M8），故不构成「未实测当已测」。

## Go/No-Go 判据执行（development-plan.md B.3）

M4 三条 No-Go 判据逐条核对：

- M4.1 fork e2e 不达 → 不适用：e2e spec 2/0 通过，分身并行、回写不丢、键不漂移三项均成立；
- M4.2 L3 审批 fail-open → 不适用：approvals_gate_spec 5/0，无绕过路径；
- M4.4 回收 GC 无人工确认 → 不适用：lifecycle_spec 7/0，`archive_confirm: false` 不清理有用例钉住。

**结论：M4 门禁 Go，v0.2.0 准予发版。**

## 关联

- milestone：`M4 · v0.2.0 Fork/Join 影分身`（#2），45 张卡已关，仅余 #19（E.1 父卡，随本门禁关闭）
- 契约：[proposals/fork-join-semantics.md](../proposals/fork-join-semantics.md)、[proposals/fork-join-shadow-clone-architecture.md](../proposals/fork-join-shadow-clone-architecture.md)
- 后续：M8 承接 email 健壮性（#239 / #240）与企微/飞书生产接线（#232 / #233 / #234）
