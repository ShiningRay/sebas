# Agent 快速开始

> 目标：克隆仓库后，任何角色 Agent 都能在 5 分钟内进入工作，且默认不会写任何东西。

## 1. 环境

```sh
git clone https://github.com/ShiningRay/sebas
cd sebas
ruby -v   # >= 3.4（.ruby-version 固定 3.4.13）；rbenv 自动读取，mise 需显式启用
gh auth status
```

`tools/sebas-process` 只依赖 Ruby 标准库与 `gh` / `git` CLI，不需要 `bundle install`。

仓库根目录的 `.ruby-version` 固定了版本（当前 `3.4.13`，3.x 的最新稳定版）。macOS 系统自带
Ruby 3.0，低于要求；入口会在加载任何代码前检查，直接给出指引并以退出码 2 拒绝，不会抛出内部错误。

安装方式取决于你用哪个版本管理器，各家的初始化写法见其官方文档。装完只有一条判据：

```sh
ruby -v   # 必须 >= 3.4
```

不满足说明当前 shell 没切过去（shim 不在 PATH，或管理器没读到 `.ruby-version`）。
不想改 shell 配置时，直接用装好的解释器绝对路径，并在后续命令里复用同一路径：

```sh
"$(rbenv root)/versions/3.4.13/bin/ruby" tools/sebas-process help   # rbenv
"$HOME/.local/share/mise/installs/ruby/3.4.13/bin/ruby" tools/sebas-process help  # mise 默认位置
"${ASDF_DATA_DIR:-$HOME/.asdf}/installs/ruby/3.4.13/bin/ruby" tools/sebas-process help  # asdf
```

`rbenv root`、`mise where ruby`、`asdf where ruby` 可查出实际目录。

### 1.1 Crystal 工具链（跑 spec / make release 用）

`tools/sebas-process` 只要 Ruby，但跑仓库门禁需要 Crystal。**版本必须 >= 1.22**：
`src/platform/keys/vault.cr` 用了 `OpenSSL::Cipher#gcm_tag`，该 API 在 1.21 及更早不存在，
用旧版会报 `undefined method 'gcm_tag'`。

**这个报错极易误导排查**：失败触发面随编译文件集变化——不 `require` keys 的 spec 子集在
1.21 能过，全量 `crystal spec` 必挂。先查 crystal 版本，再查链接环境。

```sh
crystal --version   # 必须 >= 1.22
```

macOS 上 OpenSSL 开发文件不在系统路径，需要把 Homebrew keg 直接交给 Crystal（**不要 `brew install`**，
与 CI 的 `.github/actions/setup` 口径一致——那里只探测、不安装）：

```sh
mise install crystal@1.22.3    # 仓库根目录的 mise.toml 已钉版；勿 brew upgrade
OSSL=/opt/homebrew/opt/openssl@3
CRYSTAL_LIBRARY_PATH=$OSSL/lib LDFLAGS=-L$OSSL/lib CPPFLAGS=-I$OSSL/include \
  PKG_CONFIG_PATH=$OSSL/lib/pkgconfig mise exec crystal@1.22.3 -- make check
```

不想用 mise 时，直接用解释器绝对路径（`mise where crystal@1.22.3` 可查）：

```sh
CRYSTAL_LIBRARY_PATH=/opt/homebrew/opt/openssl@3/lib \
  make CRYSTAL="$(mise where crystal@1.22.3)/bin/crystal" check
```

`make` 的所有目标都先过 `crystal-version-check`：版本低于 1.22 时立刻报错退出，
不会再让你等到编译 `vault.cr` 才看到 `undefined method 'gcm_tag'`。
`make` 默认取 PATH 上的 `crystal`，可用 `CRYSTAL=` 覆盖——这一路径**不继承** `mise exec` 的版本选择，
所以要注意 PATH 上是哪一个。

`OSSL` 必须每条命令重新赋值：`mise install` 与绝对路径写法都不保证它留在当前 shell 里。

`make release` 前先确认 spec 全绿；强杀演练 spec 需要 `bin/sebas` 存在才实跑（否则 pending），
所以 `make release` 之后才能解锁。

Linux / Windows 按各平台包管理器装 Crystal >= 1.22 与 sqlite3 / openssl / pcre2 开发头，
不做 Homebrew 那套定位。

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

只读角色（Verifier）应当只给只读工具；工具名以各 Harness 的 `--help` 为准，
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

### Maintainer

```sh
ruby tools/accept-proposal 159 --reason "方向成立，按建议收敛"        # dry-run：打印裁决评论
ruby tools/accept-proposal 159 --reason-file verdict.md --apply        # 真正接受设计
ruby tools/accept-proposal 159 --reason "排期进 v0.2.0" --milestone v0.2.0 --apply  # 接受并排期
```

`accept-proposal` 把 Maintainer 接受 Proposal 的完整动作串成一条命令：发带
`<!-- proposal-verdict: accepted-design -->` 的公开评论 → 在 issue 正文登记裁决证据
marker → 复用 `Triager.plan` 校验裁决作者、正文与评论父对象 → 清理旧状态标签并加
`proposal:accepted-design` → 发 status 评论。默认 dry-run，`--apply` 才写。
`--milestone` 接受数字或标题，须对应已开放的 milestone；指定后在裁决评论留公开排期理由，
并把 issue 挂到该 milestone。这里挂的是排期意图记录，不是实现排期本身——Implementer 只按
Scribe 拆出的工作包卡选卡，Proposal 本身不进实现选卡。
接受设计不等于自动拆卡——实现工作包仍由 Scribe 按指令拆解。
不指定 milestone 时排期仍需另行裁决。测试见 `tools/tests/process/test_accept_proposal.rb`。

### Implementer

```sh
ruby tools/sebas-process next                 # 输出单一动作
ruby tools/sebas-process plan                 # 只读多候选视图（#218）：全部就绪候选 + 枚举排除集
ruby tools/sebas-process claim 39 --dry-run   # 校验是否可认领
ruby tools/sebas-process claim 39 --apply     # 认领：写本地记录 + status=In progress 并回读
ruby tools/sebas-process resume 39            # 续跑本机已认领卡
ruby tools/sebas-process verify merge 95 39 --pre  # 合并前自检（CI + 关联 issue + Evidence）
ruby tools/sebas-process mark-review 39 --apply  # 提 PR 后：status → In review
ruby tools/sebas-process unclaim 39 --apply   # 收口后释放认领（要求已合并 + completed；已完成卡保持 Done）
```

合并前还需让 issue 带有可机读 Evidence。两阶段登记（#126）由
[`evidence-register`](../../../.github/workflows/evidence-register.yml) 自动完成：
PR 的 CI 成功后先写 `merged_into_main: false`，合并后升级为 `true`。
手工补登记可用 `gh workflow run "Evidence register" -f pr=<n>`。

`next` 返回 `claim_issue` / `resume_pr` / `wait` / `blocked` / `needs_human` /
`invalid_plan` / `handoff_release` / `idle` 之一，见
[implementer-loop.md](implementer-loop.md) §4。

#### 租约与迁移（M4x-Parallel-WP2，#220）

- **租约凭据（Q1=B）**：`claim --apply` 在认领卡发一条带 `<!-- sebas-lease -->`
  marker 的协调评论（comment id 即 lease_id，作者须在 `.github/agents.yml` 的
  `coordinators:` 白名单）。写入序：本地记录（claiming）→ 租约评论 →
  `agent:in-progress` 标签 + 回读 → claimed；任一步失败落 aborted。
  重跑 `claim` 按 lease_id 对账复用既有凭据（不双开）。
- **运行记录迁移（Q10=B）**：`.sebas-agent/run.json` 自动搬迁至
  `.sebas-agent/runs/<issue>.json`（schema 2）；非活动记录自动搬，活动记录
  缺 v2 字段须人工确认；迁移窗口内有效容量钳回 1。
- **容量（Q3）**：`.github/agents.yml` 的 `capacity` 键设定在途租约上限，
  缺键即 1；`plan` 输出 `capacity` 与 `capacity_used`（在途卡数）。
- **scope 预算（Q4=A，已生效）**：Automation 可选 `scope: [路径前缀]`
  （`src/store/` 形态，尾 / 归一，禁 `..` 与绝对路径）。前缀互相包含即冲突；
  缺 scope 独占容量：在途任一租约缺 scope 就不认领新卡，候选缺 scope 也只能
  在无在途租约时认领。共享文件（`CHANGELOG.md`、`src/store/schema.cr`、
  `.github/workflows/`）要改就写进自己的 scope，于是改同一文件的卡自然不并行。
  `plan` 与 `claim` 用同一判定，人工 `claim` 不是绕过预算的后门。
- **故障排查**：认领 aborted → 看 run 记录 `label_written` 与卡上租约评论；
  有标签无凭据（F7）、双凭据（F9）均 invalid_plan，交 Maintainer。

`plan`（只读，dry-run 默认）：与 `next` 同快照同策略，输出 JSON——
`candidates`（`issue/title/order/scope/scope_conflict/selected`；就绪候选的
`scope_conflict` 恒为 `null`，冲突的已进 `excluded`）、`leases`（逐租约动作：
`issue/action/owned/pr/reason`，含 `wait` 与 `needs_human`）、`excluded`
（`issue/reason/detail`，`reason` 为枚举码：
`depends_on_unmet` / `has_pr` / `needs_human` / `already_in_progress` /
`missing_automation` / `non_work_kind` / `invalid_plan` / `proposal` /
`scope_conflict` / `metadata_invalid`，`detail` 为与 `next` 一致的原因文本）、
`capacity`（快照
容量，缺省 1；迁移窗口钳回 1）与 `capacity_used`（在途卡数）、
`verifier_queue_depth`（open PR 数，验证背压可观察）、`next_action`/`next_issue`
（与 `next` 恒等的首选）。退出码 0 正常、1 `invalid_plan`、2 参数错误。
不改任何写行为；本 coordinator 持有的在途卡走续做路由，异机在途卡在
容量未满时不阻塞新候选。

#### 合并队列（M4x-Parallel-WP3，#221）

```sh
ruby tools/sebas-process queue                # 只读：entries / head / step / blocked_by
ruby tools/sebas-process queue --apply        # 推进队首一步（只做「合并」这一步）
```

只读输出 `queue.head`（队首 issue）、`queue.step`
（`verify_pre` / `changelog` / `merge` / `evidence` / `release`）与 `blocked_by`。
`--apply` 会先跑 `verify merge --pre`，再重读一次 PR 的 base 与 head，
然后用 `gh pr merge --squash --match-head-commit <已核验 head>` 合并，最后复核 MERGED。
只做一张、一步：`changelog` 步追加条目，`merge` 步先 `--pre` 再绑 head 合并；
`verify_pre`/`evidence`/`release` 三步不做写（只报原因）。不循环——下一张由 coordinator
重跑 `queue` 决定。只要本机有「PR 已合并但 Evidence 未升级」的记录，队列会以
`step=evidence` 阻塞，不给可合并项。

写守卫：`:merge_pr` 与 `:update_branch` 是两条独立写意图，合并命令必须同时带
`--repo`、`--squash`、`--match-head-commit`；多余参数（如 `--admin`）一律不匹配。
契约与链上细节见 [merge-queue.md](merge-queue.md)。

### Verifier

```sh
ruby tools/sebas-process verify docs docs/design/process/*.md
# 生成锚点清单：用 git ls-files 枚举全部文档（sh 的 ** 默认不递归）
# 用 && 连接：生成失败时不得继续读旧清单（那会核验上一次的文档）
git ls-files -z 'docs/**/*.md' \
  | xargs -0 ruby tools/anchors_extract.rb --output /tmp/anchors.json \
  && ruby tools/sebas-process verify anchors /tmp/anchors.json
ruby tools/sebas-process verify merge 95 87
```

三条命令全部只读，结论为 `blocker` / `must_fix` / `acceptable` / `unverified`。

`anchors_extract` 抽取文档里的「文件路径 + 行号」形态引用，取该行实际内容生成
`anchors.json`（派生物，不入库）。判定规则按文档位置分两档：

| 文档位置 | 目标文件缺失 | 指向空行 | 行号越界 |
|---|---|---|---|
| 当前文档（其余路径） | **报错** | 跳过 | **报错** |
| 存档（`review/`、`research/`） | 跳过 | 跳过 | **报错** |

存档目录放宽是因为它们记录当时的调研结论，可能引用外部项目（如 `research/autobot-architecture.md`
引用 autobot 仓库的 32 处源码路径）或已被删除的文件。当前文档严格，避免本地文件被删除或拼错
时被静默放过——这条正是 CodeRabbit 在 PR #128 上指出的漏洞。

输入文件本身不存在也是硬错误，避免「文档没有锚点」与「文档没被读取」不可区分。

CI 的 `verify` job 在每次 PR 上重跑这两步（必检，与 spec×3 + ameba 并列）。

### 终验（#124，Reviewer 并入 Verifier）

```sh
ruby tools/sebas-process verify merge <pr> <issue> --final --report verification.json --fixes fixes.json
```

终验是独立阶段：必须在新进程中运行，且不得读取阶段一的对话上下文。
`--report` 指向阶段一产出的 `verification.json`，终验只读它与 `fixes.json`——
该文件的两个来源：CI `verifier` job 产出的 `verification-report` artifact
（PR 页面下载，内含 `verification.json`）；或本地把只读核验的 stdout JSON
重定向保存（`ruby tools/sebas-process verify docs … > verification.json`）。
`fixes.json` 形如 `{"must_fix-1": {"commit": "abc123", "passed": true}}`。
checker 必填且真实复跑：每项 `must_fix` 按 `evidence` 里的命令重执行并比对退出码
（命令必须在白名单内：`crystal` / `ruby` / `ameba` / `shards`，`git` / `gh` 只读子命令）；
无 `evidence` 或复跑失败记 blocker，结论为打回。自报 `passed: true` 不再构成
「有条件通过」——该结论只留给有间接证据的未实测项，最终裁决交 Maintainer。

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

同一份快照必须得到同一动作；回归用例见 `tools/tests/sebas_process/`。

## 7. 安全边界

- 不在日志、运行记录、快照里写凭据；凭据只由环境注入。
- `--apply` 只写本地 `.sebas-agent/run.json`；GitHub 写操作仍需 Agent 按角色权限执行。
- 元数据缺失、依赖冲突、身份不可信一律 fail-closed，返回 `invalid_plan`。
- 只读角色（Verifier）的 Harness 不要给写工具，即使提示词已声明禁止。
