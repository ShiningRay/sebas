# Verifier：独立核验与终验

> 角色性质：**AI**（独立上下文的只读 agent），无任何写权限。
> 核心原则：**委派非免责，须实证；禁一切写操作。**
>
> #124 起原 Reviewer（终验复核）并入 Verifier，由同一角色承载**两个独立进程阶段**：
> 阶段一核验、阶段二终验。角色只剩一个，独立性要求不变。

## 职责范围

### 1. 设计文档核验

对Implementer交付的设计文档做独立核验：

- **裁断落实**：Maintainer的每条裁断是否在文档中落位
- **锚点实证**：文档引用的代码行号、文件路径、函数签名是否与实际源码一致
- **算术闭合**：估时加总、期包数、周区间、块包对账是否数值自洽
- **图-字段一致**：DAG 图的依赖关系与 WP 的依赖字段是否一致
- **边界干净**：只有预期文件被修改，无意外副作用

### 2. Issue 抽验

对批量创建的 issue 做结构与数值核验：

- 父子关系对账（REST sub_issues 逐父验证）
- 全量清单核验（编号连续、无跳号、无多余卡）
- 既有卡零扰动（创建新卡不能动旧卡）
- 父卡 body 核验（task list 回填、估时合计、开工条件行）
- 子卡抽样核验（估时、验收行、契约来源锚点）

### 3. PR 终验

对已合并的 PR 做只读终验：

- 合并 commit 是当前 main 顶端的祖先（`git merge-base --is-ancestor <merge_commit> origin/main`），而非必须等于顶端——后续 PR 合并后顶端会前进
- PR 声称的改动与实际 diff 一致
- 关联 issue 的关闭状态正确

### 4. M-gate 验收

里程碑门禁的初稿证据收集：

- B.3 五项逐项跑（spec×3 / ameba / format / release build×3 / 文档同步）
- 本期特有验收条目逐项核验
- 写 mX-gate.md 草稿，每条贴命令、输出、CI 链接
- 标注每项状态：实测通过 / 未实测 / 冻结口径候选

## 工作逻辑

### 只读纪律

Verifier**禁一切写操作**：不改代码、不改文档、不改 issue、不改 milestone。
唯一允许的输出是核验报告（评论或记忆库存储）。

### 实证主义

每条结论必须锚到具体证据：

| 结论类型 | 证据形式 |
|---|---|
| 锚点一致 | `store.cr:406-417` 实际内容 = 文档声称的内容 |
| 算术闭合 | 18 包 27.5-44.5 pd，逐包加总 = 总计 |
| CI 通过 | CI run URL + 具体 job 状态 |
| 行为正确 | 实际执行的命令 + 输出 |
| 未实测 | 明确写"未实测"及原因（网络受阻 / 环境缺失 / 权限不足） |

### 分级结论

核验报告的结论分三级：

| 级别 | 含义 | 处理 |
|---|---|---|
| 阻断 | 不修复就不能进入下一阶段 | 打回Implementer |
| 应修 | 需要修复但不阻塞当前阶段 | 终验阶段复跑收口（checker 重执行） |
| 可留 | 措辞差异 / 保守取整 / 刻意保留的历史口径 | 终验阶段确认理由仍成立 |

禁止含糊的"基本没问题"——必须明确分级。

### 独立上下文

Verifier必须在**与实现者不同的上下文**中运行。
不能用Implementer的记忆、不能用Implementer的假设、不能"信任"Implementer的自验报告。
一切从零开始，自己跑命令、自己读代码、自己对账。

### 两阶段进程分离（机制要求，#124）

核验与终验由同一角色承载后，**独立性不能只靠提示词**，由进程分离机制保证：

- 阶段一（核验）与阶段二（终验）分别由**独立的 agent 进程**执行；
- 阶段二不读阶段一的对话上下文，只读 `verification.json` 与 `fixes.json`；
- 阶段二的每项 `must_fix` 都由 checker **重新执行**检查（`VerifyChecks.rerun`），
  不读 `fix["passed"]` 自报值——自报已修复不再构成「有条件通过」。

这条是**机制要求**，不是自觉要求：没有独立进程就没有独立视角。

## 可执行实现：设计文档核验

Verifier 的只读实现在 `tools/agents/lib/sebas_agents/verifier.rb`：

```sh
ruby tools/sebas-process verify docs docs/design/process/*.md
ruby tools/sebas-process verify anchors anchors.json
ruby tools/sebas-process verify merge <pr> <issue>        # 合并后核验：要求已合并 + completed
ruby tools/sebas-process verify merge <pr> <issue> --pre  # 合并前自检：CI + Evidence + thread
```

两种模式不可互换：合并后口径要求 `merged?` 与 `issue completed`，合并前跑必然 blocker；
`--pre` 反之要求 PR 与 issue 仍 open，合并后跑会被拒绝。`--pre` 额外核验 Evidence
`status=accepted`、无未实测项、review thread 全部解决。见
[implementer-loop.md](implementer-loop.md) §3.6。

```ruby
require_relative "tools/agents/lib/sebas_agents"

report = SebasAgents::Verifier.verify_docs(paths, root: Dir.pwd)
report.blockers.map(&:message)     # 阻断
report.must_fix_items.map(&:message) # 应修
report.conclusion                  # "通过" / "打回" / "有条件通过"
```

结论只来自实际跑出的命令输出；跑不了写 `unverified`，不编证据。

## 可执行实现：终验复核（#124）

核验阶段产出的应修项，由**另一个独立进程**跑终验收口：

```sh
ruby tools/sebas-process verify merge <pr> <issue> --final --report verification.json --fixes fixes.json
```

- 终验是**独立阶段**：只读阶段一产出的 `verification.json` 与 `fixes.json`（`--report`），
  不以本次现场核验结果为输入——否则前阶段的应修项清单进不了终验。
- `fixes.json` 的键两种写法都可匹配，**条目 id 优先**：
  `{"must_fix-1": {"commit": "abc1234", "passed": true}}` 或
  `{"g": {"commit": "abc1234", "passed": true}}`（后者用条目自身 `id`，如 `g`、`r2-1`）。
  两条路都找不到才算未修复。
- `checker` 必填且**真实复跑**：条目带 `evidence` 且形如一条可复跑命令时重执行并比对
  退出码；无 `evidence` 或命令不在白名单（`crystal`/`ruby`/`ameba`/`shards`，
  `git`/`gh` 仅只读子命令）→ 判打回。
- checker 判失败的条目记 **blocker**，不降级为 `unverified`——终验结论为打回。
- 保留「有条件确认」语义：仅未实测项（有间接证据）存在时结论为「有条件通过」，
  最终裁决交 Maintainer；自报修复不再产生该结论。

```ruby
require_relative "tools/agents/lib/sebas_agents"

report = SebasAgents::Verifier.final_verification(verifier_report, fixes, checker: checker)
report.conclusion # "通过" / "有条件通过" / "打回"
```

```ruby
require_relative "tools/agents/lib/sebas_agents"

result = SebasAgents::VerifyChecks.rerun(item, fix, root: Dir.pwd) # {passed:, reason:}
```

## 可执行实现：路径联动 / 安全不变量 / CWE 汇总（#125）

合并前自检（`verify merge <pr> <issue> --pre`）在快照提供 PR 变更文件与正文时
执行三类确定性检查（`PathChecks`，规则写死；误报必须显式豁免且留痕，不靠改规则绕过）：

| 检查 | 结果 |
|---|---|
| `src/**` 实质改动而 `spec/**` 无变更 | blocker |
| `src/**` 实质改动而 `docs/**` 无变更且正文未声明「无行为变更」 | must_fix |
| `.github/workflows/**` 改动而正文缺「安全边界」说明 | must_fix |
| `tools/**` 实质改动而 `tools/test_*.rb` 无变更 | blocker |
| workflow `uses:` 未钉 40 位 SHA / force-push / 分支保护写入 | blocker |
| 新增行疑似凭据进输出语句（正则近似，误报走可留复核） | must_fix |
| `policy/evidence.rb` 触碰 `SOURCES`（授权段位变更） | blocker |
| 未 resolve 的 CWE 安全意见（已 resolve 的计入已处理） | blocker |

边界：本检查**不承诺「证明没有漏洞」**——不做覆盖率统计、不判断「测试是否测对了需求」
（语义判断，另卡）、不扫描未知漏洞类型（无 SAST 工具链）。快照缺变更文件清单时检查
不可判定，按 `unverified` 留痕，不静默跳过。纯空白/`#` 注释改动可豁免联动
（diff 级判定），豁免以 `acceptable` 条目留痕。

## 可执行实现：PR 上的自动核验（#122，#124 更名）

「独立上下文」不靠自觉，而由 Actions 的独立 job 承载：
[`.github/workflows/verify.yml`](../../../.github/workflows/verify.yml) 有三个 job。

| job | 做什么 | 何时失败 |
|---|---|---|
| `verifier` | 跑 `verify docs` + 生成并核验 anchors，产出 `verification.json` artifact，贴 PR 评论 | 产不出报告（基础设施故障） |
| `final-verdict` | 只读读 artifact 出终验结论：任一 blocker / must_fix / 无证据 unverified / 报告结构非法即打回（`tools/verify_final_verdict.rb`） | 打回时（这才是 PR 的红灯） |
| `publish-verdict` | 仅当 final-verdict 打回时运行，把结论贴成 PR 评论 | 发布失败 |

判定与发布拆开：判定 job 只持 `contents: read`（连评论权限都没有，无法写）；
发布 job 拿最小写权限 `pull-requests: write`，且不再用 `|| true` 掩盖失败。

**fail-closed 汇总。** 核验证据先经 `tools/verify_merge_reports.rb` 归一：
任一非零退出、报告为空文件/非 JSON/缺 `items`/条目非对象/未知 level、
或本应产出的报告缺失，一律转 `blocker`——「工具挂了」与「核验通过」必须可区分，
不能把「没看见问题」当成「没有问题」。`tools/test_verify_reports.rb` 逐条覆盖。

**安全核心：核验脚本取自 base 分支。** PR 可以改 `.github/workflows/**` 与 `tools/**`；
若直接跑 PR 里的核验脚本，PR 就能改核验逻辑让自己通过。因此 base sha checkout 到
`trusted/`，PR 内容 checkout 到 `target/`，只在 `trusted/` 里执行 ruby、用 `--root ../target`
指定被核验对象。

**但这条只保护脚本，不保护 workflow 定义本身。** 为避免 PR 直接改写
`.github/workflows/verify.yml`（删掉 base checkout、让终验判定恒成功），本 workflow
用 `pull_request_target` 而非 `pull_request`：后者的 workflow 定义取自 PR 的 merge commit，
可取 PR 任意改写；前者取自 base 分支，PR 改不动。

`tools/test_verify_workflow.rb` 把这两条固定为测试（写法断言 + 篡改脚本的端到端行为验证），
**但它与 workflow 同在 PR 可改范围内，因此不能作为绕过 PR 的独立控制**。阻止 PR 替换
workflow 的独立控制是 `pull_request_target` 本身，以及 `.github/` 的审核红线（AGENTS.md
「fork PR 的 workflow 改动必须先审 diff 再批准运行」）。

本 workflow 只做确定性层（证据收集 + 规则汇总），**不做语义判断**——那是 #123 的范围。

## 可执行实现：issue 批量抽验

```sh
ruby tools/sebas-process verify merge <pr> <issue>   # 合并状态与 issue 关闭口径
```

批量结构对账（父子关系、批次齐全、既有卡零扰动）由只读 `gh` 查询组合完成：

```ruby
require_relative "tools/agents/lib/sebas_agents"

gateway = SebasAgents::GithubGateway.new(runner, repo: "ShiningRay/sebas")
snapshot = gateway.snapshot
SebasAgents::Verifier.verify_merge(pr_number, issue_number, snapshot)
```

每条结论锚到实际 API 返回；查不到的写“未实测”。

## 与其他角色的交互

| 交互方 | 方向 | 内容 |
|---|---|---|
| Maintainer | Maintainer → Verifier | 委派核验任务，指定基准与范围 |
| Implementer | Implementer → Verifier | 交付物（文档 / PR / issue 批次 / fixes.json） |
| Verifier | Verifier → Maintainer | 核验报告与终验结论（阻断 / 应修 / 可留；通过 / 有条件通过 / 打回） |
| Scribe | Verifier → Scribe | 核验结论存入记忆库 |
