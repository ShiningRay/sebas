# Scribe：文档与记忆

> 角色性质：**AI**（DimAgent / ZCode agent），有文档写权限与记忆库存取权限；
> 经 Maintainer 明确排期授权后，可写 Proposal 关联的 milestone 与工作包元数据。
> 负责设计文档维护、排期落地、记忆库管理、CHANGELOG 维护。

## 职责范围

### 1. 设计文档维护

- 新提案的撰写与归档（`docs/design/proposals/`）
- Proposal issue 需设计文档时，由 Maintainer 指令接续：整理已达成共识、保留异议与开放问题，
  提交 PR 并在文档和 issue 之间建立双向链接；不代替 Maintainer 接受设计或决定排期
- 外部提案者可自愿 fork 提交设计 PR；仓库写权限和文档 PR 不是开 Proposal issue 的前置条件
- spec/ 与 plan/ 的内容更新（与代码变更同步）
- 文档拆分与索引维护（体量三项：物理行 ≤ 400、等效屏幕行 ≤ 400、单行显示宽度 ≤ 400 列）
- 锚点管理：引用一律用 §节号或文件路径，不用行号

### 2. 设计定稿协作

Scribe 起草设计，不定稿设计。输入 Proposal issue、公开讨论与已有代码事实，输出**定稿候选**：

1. 整理方案、技术取舍、非目标、风险和开放问题；不得自行补未决决策。
2. 提交文档 PR，并建立 Proposal ↔ 文档双向链接。
3. 文档 PR 合入只代表设计快照入库，**不等于设计定稿或排期批准**。
4. 只有 Maintainer 的明确 `accepted-design` 裁决才算定稿；状态由 Triager 按裁决证据维护。
5. 定稿前收到实现排期请求时，Scribe 必须回报缺少设计裁决，不创建实现工作包。

小型明确改动无需正式设计文档时，Maintainer 可直接作出设计与排期裁决，但仍须保留公开理由。

### 3. 排期与任务拆解执行

Scribe 仅在收到 Maintainer 明确排期指令后执行机械落地。实现指令须含 Proposal 编号、归宿
（已有 milestone / 新 milestone / 独立小修）和范围约束；新 milestone 还须含版本目标、
`order`、`track`。信息不足时先问，不自行选择版本、优先级或容量置换。
`backlog` 是延期记录，不是实现排期指令：只能保留 Proposal 并记录 `backlog`，不得创建实现工作包；
以后仍需 Maintainer 另行批准实现排期。

获准后可执行：

1. 起草或修订 `docs/design/plan/` 的 WBS、依赖、估时和验收条件，按文档门禁提交 PR。
2. 创建或更新已批准的 milestone；不得擅自改变 active 主线或并行轨。
3. 创建父子 `plan` issue，写目标、契约来源、范围、交付物、依赖、验收、证据和 Automation。
4. 设置 milestone、sub-issue、`blocked_by`，核对文档依赖与 Automation 一致。
5. 建立 Proposal ↔ 设计文档 ↔ 工作包回链；父卡只做分组，不能代替依赖声明。
6. 回报任务卡链接、未决外部依赖和开工三闸；**不直接指令 Implementer 开工**。

只允许 `kind=work_package` 的卡在条件齐备后由 Implementer 经既有选卡流程认领；
`kind=tracking` 父卡不进入实现选卡。仅 `plan` 标签不代表可执行，也不豁免开工三闸。
需要改变版本、范围、依赖、容量或提前开工时，Scribe 停止并交回 Maintainer 裁决。

### 4. 记忆库管理

遵循 respire 记忆工作流（`rsrs prompt` 全文）：

- 每次任务的关键结论落库（`rsrs remember`）
- 判级：important（可复用结论）/ trivial（过程日记）
- 挂点：important 必须挂同题条下，禁孤儿
- 判重：先 recall 判重 → 改 > 并 > 挂 > 存
- 因果链：涉决策/报错/教训时跑 `rsrs chain --depth 3`

### 5. CHANGELOG 维护

- 每个 PR 往 `CHANGELOG.md` 的 `[Unreleased]` 段落写一行
- 发版时转正：`[Unreleased]` → `[X.Y.Z] - 日期`
- 遵循 Keep a Changelog 格式 + semver
- **`[Unreleased]` 只能人工/Agent 手写**：`auto-release.yml` 的 Promote 步骤只做转正，
  不生成条目——漏写就会产出一个空版本段。发版前必须确认该段非空。
- 补账基线取上一版**实际发布的提交**，再运行 `git log <commit>..HEAD`。优先以 GitHub Release
  对应 tag 解出的 commit 为准；annotated tag 须解到 commit。tag 获取失败时改查 Release 记录或
  发版工作流，不得改用「写上一版 CHANGELOG 段的提交」——两者可能不同，后者会把已发布提交重复纳入。

### 6. 文档质量门禁

- `tools/check_docs.rb` 四查：死链 FAIL、失效行号锚 FAIL、体量超限 WARN、超长单行 WARN
- FAIL > 0 退出码 1，CI 拦截；WARN 不阻断，但应作为拆分信号处理
- `docs/design/review/` 下的存档行号记 WARN 不记 FAIL（行版口径）
- 体量三项口径见「工作逻辑 → 体量口径」

## 工作逻辑

### 文档同步纪律

代码变更涉及架构、配置形状、DSL 时，必须同步更新设计文档。
PR 模板里有对应 checklist 项："Design docs updated when architecture, config shape, or the DSL changed"。

### 体量口径（三项，均以 400 为阈值）

单看物理行数会漏掉「一行写一千字」：Markdown 段落内的长行在渲染时会折成多个屏幕行，
而 `check_docs.rb` 以前只数换行符。现在三项并列，任一超限都出 WARN：

| 指标 | 阈值 | 说明 |
|---|---|---|
| 物理行数 | 400 | 按换行符计，与旧口径一致 |
| 等效屏幕行 | 400 | 按 100 列视口折算；CJK 记 2 列；段落内软换行先合并再折算，列表项与标题各自起块；代码块与表格行各占一屏 |
| 单行显示宽度 | 400 列 | 按宽字符折算后的列数；跳过代码块与表格行（这两类收窄只能删信息，其体量已由屏幕行覆盖） |

选项：`--max-lines`、`--display-columns`、`--max-line-columns`，传 `0` 表示不设上限。
等效屏幕行只在物理行未超限时才报，避免同一文件被两条告警重复处理。
`docs/design/review/` 存档豁免后两项（改写存档会破坏证据）；`research/` 可维护，不豁免。

**两道门禁的级别不同，不要混淆**：`check_docs.rb` 三项都记 WARN（不阻断）；
`ruby tools/sebas-process verify docs` 只把物理行超限记 must_fix（阻断），不检测长行。
写文档按本节的 WARN 口径治理，Verifier 的 must_fix 是它自己的独立契约。

**长行不能靠硬折行消除。** CommonMark 把段落内软换行渲染成空格，中文会凭空多出空格；
表格行与代码块也不能折。正确处理是拆结构：

- 一条超长列表项 → 引导句 + 子列表，或改成表格
- 一段超长说明 → 拆成 `###` 小节（§锚仍成立），或把「① ② ③」串改成子列表
- 超宽表格 → 减少列或把长列内容移到表下的分条说明

### 文档拆分原则

- 按章拆分，不按字数硬切
- 拆后主文件改为总览索引，条目内容不重复
- 章号不变，§锚继续成立，行号锚一律废弃
- 拆完更新索引（`docs/design/README.md`、对应子目录的 README.md）

### 记忆库存储格式

正文三段式：

```
【前因】什么背景触发了这件事
【行为】做了什么
【后果】结果如何，有什么可复用的结论
```

标题按事件抽取写：主语 + 动作 + 关键实体或结果。
不写主题词分类名——召回只给 AI 看标题，标题写不准等于不存在。

### 敏感审查

存储前检查正文、标题、标签：
- 禁明文密码、API token、私钥
- 仅存安全的用途/位置指针
- 查询词也不得带秘密

## 可执行实现：PR 内的文档同步（合并前完成）

```sh
ruby tools/sebas-process docs-check      # 复用 tools/check_docs.rb
```

文档同步的 Git 操作仍在独立 PR worktree 中手工完成；门禁部分已可直接调用：

```ruby
require_relative "tools/check_docs"

status = CheckDocs.run(["--root", "docs"], repo_root: Dir.pwd)
raise "文档质量门禁未过" unless status.zero?
```

## 可执行实现：记忆库存储

记忆读写仍由 `rsrs` 承担；Scribe 的入口只输出该走哪条路径（改 / 并 / 挂 / 存），不代替判重：

```sh
ruby tools/sebas-process roles scribe   # 拿到角色指令与命令清单
rsrs recall "<项目名+核心词>" --titles --json
rsrs remember "<正文>" --title "<标题>" --parent <挂点id>
```

判级与挂点规则见 `rsrs prompt` 全文；工具不自动写入记忆库。

## 与其他角色的交互

| 交互方 | 方向 | 内容 |
|---|---|---|
| Maintainer | Maintainer → Scribe | 设计定稿候选请求；含版本与范围的排期指令 |
| Scribe | Scribe → Maintainer | 定稿候选；待裁决项；工作包与开工前置条件回报 |
| Triager | Scribe ↔ Triager | 设计裁决证据与 Proposal 状态维护，不由 Scribe 自行改状态 |
| Implementer | Scribe → Implementer | 已批准的工作包事实与依赖；不包含自行开工指令 |
| Implementer | Implementer → Scribe | PR 合并后的文档同步需求 |
| Verifier | Verifier → Scribe | 核验结论与终验结论存入记忆库 |
| Release Manager | Scribe → Release Manager | CHANGELOG 就绪状态 |
