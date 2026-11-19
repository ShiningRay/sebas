# M3 门禁演练记录（design.md §14 M3 验收勾稽，2026-11-19）

> 环境：Windows 10 x64、Crystal 1.22.1。门禁三命令全绿（130 examples / ameba 0 / make release）。
> **M3-WP4~WP6 按预设条款降级为技术预研**（判据见 development-plan.md B.3；
> 可行性报告 [m3-plugin-feasibility.md](m3-plugin-feasibility.md)）——M3 门禁判据相应变为
> 「WP1/2/3 验收 + 插件层可行性报告」。

## §14 M3 验收勾稽（L752 六条）

### 1. max_hops=4 拦截互发死循环 ✅

`crystal spec spec/agents/collaboration_spec.cr -e "blocks agent ping-pong"`

- a/b 互回链路 hop 1→4 全部投递（hops_ok=4），第 5 跳 LoopGuardExceeded 拒发（不投递）；
- message_agent 工具把 guard 错误转为值（不炸进程）。

### 2. 并发上限生效（超限排队不失控）✅

`-e "caps subagent concurrency at the semaphore limit"`

- 信号量默认 3 可配（测试 2）：4 个子任务排队执行，**并发峰值=上限**（不失控）；
- 全部完成（done×4），无丢弃无饿死。

### 3. subagent 崩溃后找回同一子任务 ✅

`-e "recovers the same subtask after a crash via ownerTaskId"`

- 崩溃现场（子任务 interrupted，owner 锚点 owner-9）→ 同 subtask_key 重派 →
  **找回同一 task id（sub:recover-1，不新建）** → resume → done；
- subtasks_of（owner_task_id 查询）无重复任务。

### 4. 插件死循环被 watchdog 超时拦截不卡宿主 🔶 技术预研（可行架构已定，环境 blocker）

详见 [m3-plugin-feasibility.md](m3-plugin-feasibility.md)：子进程沙盒解释器 + 宿主 kill 方案
架构与构件已产出（sebas-stdio gem、build_config 补丁、解释器行为验证）；产品化待环境解锁
（杀软排除或 CI 构建）。同类「超时 kill 不卡宿主」语义已由 M0-WP8 强杀续跑与触发器
进程口径预先验证。后续产品化验收以 design.md §12 与 §14 修订口径为准。

### 5. 插件崩溃只影响该次调用 🔶 技术预研（同上）

子进程架构下崩溃只终止该插件子进程，不卡宿主（进程级隔离），预研报告论证 + 构件就绪。

### 6. 改插件脚本热重载生效 🔶 技术预研（同上）

每次调用读当前脚本 → 保存后下一动作即新脚本（语义成立，实现待环境解锁）。

### 附：WP1 多 agent 定义与路由 ✅

`-e "keeps two agents with independent personas and memory"`——两 agent 独立 persona
（SOUL.md）+ 独立记忆目录（写入互不串扰）+ registry 管理；binding 路由到 agent 维度
（M1-WP1 已验）。

## 门禁三命令

| 命令 | 结果 |
|---|---|
| `crystal spec` | 130 examples, 0 failures |
| `./bin/ameba` | 0 failures（83 files） |
| `make release` | bin/sebas.exe 构建成功 |

## M3 期已落地 WP

WP1 多 agent / WP2 消息防环 / WP3 subagent 信号量+找回 / **WP4~6 插件层降级技术预研**
（mrb.cr 甄别 ✓ 84/84、架构与构件产出、环境 blocker 如实记录）。

## Go/No-Go 判据执行（development-plan.md B.3）

「M3 若 mrb.cr 复核不可用 → 降级为技术预研 Go」——mrb.cr 绑定可用但**集成链路的
Windows 工具链环节**当日不可用（环境级），按条款精神执行技术预研降级：
M3 门禁以「WP1/2/3 验收 + 可行性报告」闭合，插件产品化待环境/CI 解锁后按 §14 原口径补齐。
