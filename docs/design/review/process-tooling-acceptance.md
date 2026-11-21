# Agent 流程工具验收报告

> 验收对象：`docs/design/process/` + `tools/sebas-process` + `tools/agents/`
> 基线：`main@315c78f`（PR #96 / #97 / #98 / #99 已合并）
> 方式：只读。未改动仓库源码、issue、milestone。
> 结论：**通过**（0 阻断、0 应修、5 项可留、3 项未实测）

## 1. 验收范围

| 类别 | 内容 |
|---|---|
| 工具入口 | `tools/sebas-process`（9 个子命令族） |
| 策略层 | `tools/agents/lib/sebas_agents/policy/`（milestone、证据、依赖、选卡） |
| 适配层 | `GithubGateway`、`CommandRunner`、`RunRecord` |
| 角色层 | Verifier、Reviewer、Triager、Release、RolePrompts |
| 支撑脚本 | `check_docs.rb`、`setup_process_labels.rb`、`backfill_m4_automation.rb` |
| 文档 | `docs/design/process/` 12 篇 |

## 2. 实测结果

### 2.1 本地门禁

| 检查 | 实测输出 | 结论 |
|---|---|---|
| `make agents-check` | 72 / 118 / 8 / 5 / 5 runs，全 0 失败 | 通过 |
| `ruby tools/check_docs.rb` | 80 文件，FAIL 0，WARN 19（均为历史存档） | 通过 |
| `crystal tool format --check` | 无输出 | 通过 |
| Ruby 语法（30 个文件） | bad=0 | 通过 |
| 文档 Ruby 块（Ripper） | 10 块，syntax_bad=0 | 通过 |

### 2.2 CI 实跑

`PR #99` 的 docs job 日志确认五套测试真实执行：

```
test_check_docs.rb          14 runs, 21 assertions
test_sebas_process.rb       72 runs, 371 assertions
test_sebas_process_regressions.rb  118 runs, 483 assertions
test_docs_examples.rb        8 runs, 134 assertions
test_oneline_sheet.rb        5 runs, 32 assertions
test_backfill_script.rb      5 runs, 17 assertions
```

`main@315c78f` 的 CI 结论：success（spec×3 + ameba + docs）。

### 2.3 真实仓库端到端

| 场景 | 实测输出 |
|---|---|
| `next` | `claim_issue #39`，27 张卡排除 |
| 元数据覆盖 | 29 张全部有 Automation 块，0 缺失 |
| 工作包一致性 | 23 张，Automation ↔ blocked_by 不一致项 **0** |
| 顺序唯一性 | 重复 order **0** |
| 依赖环 | **0** |
| 排除分类 | 6 张 tracking 父卡 + 21 张被前置阻塞 |

### 2.4 状态机路径

| 输入 | 期望 | 实测 |
|---|---|---|
| `needs:human` 单独 | `needs_human` | ✓ |
| `needs:human` + `agent:resume` | `resume_issue` | ✓ |
| `agent:in-progress` + `phase=claimed` | `resume_issue` | ✓ |
| `agent:in-progress` + 无记录 | `invalid_plan` | ✓ |
| `metadata:invalid` 卡 | 排除，选下一张 | ✓（选中 #2，#1 进 excluded） |
| `aborted` + `label_written=true` | `invalid_plan` | ✓ |
| `aborted`（无远端标签、带暂停标签） | `invalid_plan` | ✓ |
| `aborted` + 在途 PR | `invalid_plan` | ✓ |

### 2.5 错误路径

| 命令 | 退出码 | 输出 |
|---|---|---|
| `next --snapshot /nope.json` | 2 | `usage_error` JSON |
| `claim abc` | 2 | `usage_error` JSON |
| `bogus-command` | 2 | `usage_error` JSON |
| `next` 遇 GitHub EOF | 2 | 重试后仍失败才报 `command_failed`，不伪造空列表 |

无 backtrace 泄漏，全部可解析。

### 2.6 文档与实现一致性

| 检查 | 结果 |
|---|---|
| 文档 action 枚举（9 个）与代码产生值 | 完全一致，无 code-only |
| 7 个角色的 `commands` 是否都在 `help` 中 | bad_cmds=0 |
| `oneline.md` 与 `RolePrompts.oneline` | 逐字一致（7 vs 7） |
| 文档引用的子命令 / `--flag` | 测试断言存在 |

## 3. 可留（5 项）

| # | 项 | 理由 |
|---|---|---|
| 1 | 跨进程原子认领 | 文档 §5 明确首版单进程 runner + concurrency group；CLI 内做分布式锁需要额外基础设施 |
| 2 | `verify merge` 无 merge-base 祖先校验 | 命令契约是纯 JSON 快照，git 历史不在其中；已在本报告标注为能力边界 |
| 3 | 期父卡关闭时机 | 人工判断；工具只排除 tracking 卡，不自作主张关闭 |
| 4 | worktree 创建与 PR 提交 | 由 Agent 按角色文档执行；CLI 只负责认领与状态 |
| 5 | `triage --apply` 不写远端 | 工具定位是确定性判定，写 issue 由角色 Agent 按权限执行 |

## 4. 未实测（3 项）

| # | 项 | 原因 |
|---|---|---|
| 1 | macOS 上 `release verify` | 依赖 `sha256sum`，macOS 只有 `shasum`；本机为 Windows |
| 2 | 真实并发认领 | 需两个进程同时运行，未构造 |
| 3 | 端到端发版（tag → release.yml → 产物校验） | 会真实发版，未执行 |

## 5. 已知局限

- `WARN 19` 全部来自 `docs/design/review/` 历史存档的行号锚，属预期。
- 现有 M4 工作包依赖 `#39` 完成；`#39` 本身仍是 open，选卡会持续返回它直到关闭。

## 6. 结论

现有工具在真实仓库数据上可用：选卡、状态机、错误处理、文档一致性均通过实测。

未覆盖的能力已在上文逐项列明，没有把「未实测」表述为「通过」。
