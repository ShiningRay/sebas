# Agent 快速开始

> 目标：克隆仓库后，任何角色 Agent 都能在 5 分钟内进入工作，且默认不会写任何东西。

## 1. 环境

```sh
git clone https://github.com/ShiningRay/sebas
cd sebas
ruby -v   # >= 3.2；只用标准库
gh auth status
```

`tools/sebas-process` 只依赖 Ruby 标准库与 `gh` / `git` CLI，不需要 `bundle install`。

仓库首次使用时，创建流程标签与维护者名单：

```sh
ruby tools/setup_process_labels.rb          # 先看缺哪些
ruby tools/setup_process_labels.rb --apply   # 实际创建
```

`.github/agents.yml` 已提交，列出可校验 Evidence 的 Maintainer。

## 2. 一条命令拿到角色提示词

最快的路径是[一句话开工速查表](oneline.md)：每个角色一行，复制粘贴即可。
想直接生成：

```sh
ruby tools/sebas-process roles --one-line               # 全部 7 行
ruby tools/sebas-process roles implementer --one-line   # 单角色一行
ruby tools/sebas-process roles implementer              # 人读：规格 + 命令 + 提示词
ruby tools/sebas-process roles implementer --prompt-only # 完整纯文本提示词
ruby tools/sebas-process roles implementer --json        # 机器读：结构化字段
```

## 3. 新开 Harness 的三种接法

### A. 交互式 Harness（Codex / Claude Code / Cursor 等）

1. 在仓库根目录打开 Harness。
2. 把 `ruby tools/sebas-process roles <role> --prompt-only` 的输出贴为系统提示。
3. 首条用户消息写具体任务，例如：
   `按提示词工作：对 M4 期工作包做选卡并执行第一张；遇到 invalid_plan 停下报告。`

### B. 无人值守 / headless

```sh
# 1) 生成提示词文件
ruby tools/sebas-process roles verifier --prompt-only > /tmp/verifier.md

# 2) 交给 Harness，例如
#    codex exec --full-auto "$(cat /tmp/verifier.md)"
#    claude -p "$(cat /tmp/verifier.md)" --allowedTools "Read,Bash"
```

只读角色（Verifier / Reviewer）应当只给只读工具；工具名以各 Harness 的 `--help` 为准，
不要假定交互式命令可自动化。

### C. 子 Agent / 多角色并行

每个角色单独起进程，各拿一份提示词，各用独立 worktree。
同一时刻仍只允许一个 Implementer 写代码（见 [implementer-loop.md](implementer-loop.md) §1）。

## 4. 约定

| 约定 | 说明 |
|---|---|
| 默认 dry-run | 不带 `--apply` 时只读，不写 GitHub、不写文件 |
| 输出 JSON | 成功与失败都写 stdout，便于 Agent 解析（`roles --prompt-only` 除外） |
| 退出码 | `0` 放行 / `1` 门禁拒绝 / `2` 用法或环境错误 |
| 事实源 | GitHub；`--snapshot` 可离线重放同一份快照 |

## 5. 各角色最小命令

### Implementer

```sh
ruby tools/sebas-process next                 # 输出单一动作
ruby tools/sebas-process claim 39 --dry-run   # 校验是否可认领
ruby tools/sebas-process claim 39 --apply     # 认领：写本地记录 + 远端标签并回读
ruby tools/sebas-process resume 39            # 续跑本机已认领卡
ruby tools/sebas-process verify merge 95 39   # 合并前核对
```

`next` 返回 `claim_issue` / `resume_pr` / `wait` / `blocked` / `needs_human` /
`invalid_plan` / `handoff_release` / `idle` 之一，见
[implementer-loop.md](implementer-loop.md) §4。

### Verifier

```sh
ruby tools/sebas-process verify docs docs/design/process/*.md
ruby tools/sebas-process verify anchors anchors.json
ruby tools/sebas-process verify merge 95 87
```

三条命令全部只读，结论为 `blocker` / `must_fix` / `acceptable` / `unverified`。

### Reviewer

```sh
ruby tools/sebas-process review verification.json --fixes fixes.json
```

`verification.json` 是 Verifier 的输出；`fixes.json` 形如
`{"must_fix-1": {"commit": "abc123", "passed": true}}`。
未提供独立复跑时，结论最多是“有条件通过”。

### Triager

```sh
ruby tools/sebas-process triage 42                       # 先看需要模型判什么
ruby tools/sebas-process triage 42 --verdict verdict.json # 把判定翻成元数据动作
```

`verdict.json` 形如 `{"decision": "bug-confirmed", "body": "复现步骤", "milestone": "hotfix"}`。
判定由模型给，工具只做确定性翻译；`needs_model` 非空时不得直接执行动作。

### Scribe

```sh
ruby tools/sebas-process docs-check   # 复用 tools/check_docs.rb
```

### Release Manager

```sh
ruby tools/sebas-process release plan
ruby tools/sebas-process release verify v0.2.1 --root /tmp/sebas-v0.2.1
```

## 6. 离线重放

把 GitHub 事实固化成快照，便于复现选择结果。快照字段见
`tools/agents/lib/sebas_agents/model.rb` 的 `Model::Snapshot.from_hash`：

```sh
ruby tools/sebas-process next --snapshot snapshot.json --record run.json
```

同一份快照必须得到同一动作；回归用例见 `tools/test_sebas_process.rb`。

## 7. 安全边界

- 不在日志、运行记录、快照里写凭据；凭据只由环境注入。
- `--apply` 只写本地 `.sebas-agent/run.json`；GitHub 写操作仍需 Agent 按角色权限执行。
- 元数据缺失、依赖冲突、身份不可信一律 fail-closed，返回 `invalid_plan`。
- 只读角色（Verifier / Reviewer）的 Harness 不要给写工具，即使提示词已声明禁止。
