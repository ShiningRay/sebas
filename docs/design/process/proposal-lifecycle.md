# Proposal 的存续、修订与取代

> 文档职责：定义 Proposal 从提出到归档全周期的权威归属、修订路径与终态标记。
> 是 [development-workflow.md](development-workflow.md) §Proposal 生命周期的展开；冲突时以本文为准。
> 2026-11-25 定稿。

## 1. 权威归属：文档是契约，issue 是档案

| 载体 | 角色 | 内容 |
|---|---|---|
| `docs/design/proposals/<name>.md` | **权威契约** | 当前生效的设计：模型、契约、状态机、取舍、非目标 |
| Proposal issue | **讨论与裁决档案** | 提案原文、开放讨论、每次裁决的公开理由与链接 |
| 工作包 issue | 执行单元 | 带 `Automation` 块 + milestone，回链 Proposal 与设计文档 |

判定口径：

- 「现在该怎么做」→ 读文档。文档与 issue 冲突时**以文档为准**。
- 「当时为什么这么定、谁拍的板」→ 读 issue 的裁决评论。
- 文档里没有覆盖的，才回 issue 找讨论；找到的结论必须回写文档，不能只在评论里生效。

**评论不驱动状态。** 在 Proposal issue 上留言不会改变它的判定状态；需要重新研判时明确说明，
由 Triager 重跑 `triage`。这是有意设计：状态只能由确定性工具按裁决证据改写。

## 2. 文档头部的状态行（必填）

每篇 `docs/design/proposals/*.md` 首部必须有状态行，取以下四值之一：

| 状态 | 含义 | 允许的操作 |
|---|---|---|
| `draft` | 讨论中，结论未定 | 自由修改 |
| `accepted` | 设计已定稿，尚未全部实现 | 小改走 PR；大改开新 Proposal |
| `implemented` | 已实现并与代码一致 | 只接受勘误；行为变更开新 Proposal |
| `superseded by #N` | 已被新 Proposal 取代 | 只读，仅保留历史 |

写法示例：

```markdown
> 状态：**accepted**（2026-11-25 定稿）；实现进度以 [#192](https://github.com/ShiningRay/sebas/issues/192) 为准。
> 修订记录：2026-11-25 初稿；2026-12-01 修订 §4.2（PR #210）。
```

状态与实际不符时，Scribe 在文档门禁 PR 中一并修正；`check_docs.rb` 不强制校验状态行，
但 review 时按缺失处理。

## 3. 内容修改：分级处理

判断标准是**是否改变已承诺的行为**。

### 3.1 小改：直接改文档走 PR

适用于：措辞澄清、补充示例、修正事实错误（如行号漂移、函数改名）、明确原本模糊但不改变结论的表述。

做法：

1. 直接改 `docs/design/proposals/<name>.md`，提 PR
2. PR 描述写明「修订 §X，原因：…」
3. 在文档头「修订记录」追加一行
4. PR 合入即生效，不需要重新裁决

### 3.2 大改：开新 Proposal 取代旧的

适用于：改变公开行为、架构、配置形状、DSL 兼容性，或推翻原有取舍结论。

做法：

1. 新开 Proposal issue，正文首行写明「取代 #N」
2. 新文档状态行写 `accepted`（或 `draft`），旧文档改 `superseded by #新号`
3. 旧 Proposal issue 打 `proposal:superseded` 标签，评论指向新 issue，关闭为 not planned
4. 两张 issue 双向链接，旧的不删不隐藏

判不准是小改还是大改时，按大改处理——多开一个 Proposal 的成本远低于让两份文档说法不一。

### 3.3 实现偏差：回写文档

实现过程中发现文档不可行或需要调整，由 Implementer 在 PR 中说明偏差，
Scribe 回写文档使两者一致。**不允许「代码改了文档没改」**：
同一 PR 或紧随的文档 PR 必须让文档与 main 上的行为对齐。

## 4. 拆卡之后 Proposal 去哪

`accepted` 且已拆出工作包的 Proposal：

- **不关闭**，保持 open 作为永久档案（`declined` / `superseded` 才关闭）
- 工作包用 GitHub 原生 sub-issue 挂到 Proposal 下，进度条自动聚合
- 全部工作包关闭后，Proposal 打 `proposal:done` 标签，仍不关闭
- 若之后需要继续演进，按 §3.2 开新 Proposal

`proposal:done` 与 `proposal:superseded` 的区别：前者是「这一轮做完了」，后者是「这个设计被取代了」。
两者可以同时存在。

**sub-issue 只能有一个父卡。** 工作包若同时属于某期父卡（`kind=tracking`，如 M4 的 #34），
则挂期父卡，Proposal 用正文 `Refs #N` 回链；只有不归任何期父卡的工作包才直接挂 Proposal。
理由：期父卡已承担「本期范围与进度」的聚合职责，一个卡挂两处会让两边的进度条都不准。

## 5. 标签全集

| 标签 | 语义 |
|---|---|
| `proposal` | Proposal 入口，与 type 并存 |
| `proposal:needs-design` | 讨论中，待收敛 |
| `proposal:accepted-design` | 设计已定稿（不等于排期批准） |
| `proposal:declined` | 被拒绝，已关闭 |
| `proposal:superseded` | 被新 Proposal 取代，已关闭 |
| `proposal:done` | 所拆工作包全部完成，仍 open |

状态标签互斥（`proposal:needs-design` / `proposal:accepted-design` / `proposal:declined` /
`proposal:superseded` 四选一）；`proposal:done` 是叠加标记，不参与互斥。

`proposal:superseded` 由 Triager 的 `superseded` 判定产生，verdict 必须带
`superseded_by`（继任 Proposal 编号，不能指向自身）；生成的评论会写明「继任 Proposal：#N」。
`proposal:done` 目前无工具产出，由 Scribe 在工作包全部关闭后手工打。

## 6. 评论查阅：置顶索引

Proposal issue 的评论区是过程记录，会随讨论变长。为便于查阅，每张 Proposal 维护一条**置顶索引评论**：

```
ruby tools/sebas-process digest <proposal>            # dry-run
ruby tools/sebas-process digest <proposal> --apply    # 写入并置顶
```

索引分两区，职责不同：

| 区 | 谁维护 | 内容 |
|---|---|---|
| 机械区（`<!-- proposal-digest -->` 之后） | 工具 | 最新判定、最近研判日期、研判次数、研判时间线（含原始评论链接） |
| 人工区（`<!-- digest:manual -->` 之后） | 人或 agent | 「已达成」「待裁决」两条目的语义摘要 |

**工具永不覆盖人工区**：重跑 `digest` 只刷新机械区，`<!-- digest:manual -->` 之后的内容原样保留。
首次生成时会写入 `- （待填）` 占位，之后由 Scribe 或 Maintainer 填实。

何时重跑：每次 Triager 研判后、每次裁决后。索引因此始终反映当前状态，读者不必翻完整条时间线。

**摘要评论必须断环。** 索引评论自身带 `<!-- proposal-digest:auto -->` 标记，所有自动化
（webhook filter、Triager 的 `status_of`）都必须识别并丢弃，否则每刷新一次摘要就会触发一轮新研判，
形成「摘要 → 研判 → 摘要」的循环。`Digest.status_of` 对首行含 `proposal-digest` 的评论返回 nil，
这条规则有测试锁定。

**机器评论不进 Proposal。** `evidence-register` workflow 遇到带 `proposal` 标签的 issue 直接跳过，
避免 bot 评论混入讨论区。

## 7. 文档由谁写、谁提 PR

**一句话：Proposal issue 谁都能提，Proposal 文档只有 Scribe 能写。**

| 场景 | 作者 | 提交方式 |
|---|---|---|
| Proposal issue 正文 | 任何人（含外部贡献者） | 直接开 issue，无需仓库权限 |
| Proposal 讨论、评论、异议 | 任何人 | 直接评论 |
| 设计文档初稿（`docs/design/proposals/`） | **Scribe**（按 Maintainer 指令） | Scribe 提 PR |
| 定稿候选 | **Scribe** | PR；合入只代表快照入库 |
| 小改（措辞、示例、事实订正） | **Scribe** | PR |
| 大改（行为/架构/配置/DSL 变更） | 任何人开新 Proposal issue，**Scribe** 写文档 | 新 issue + PR |
| 实现偏差回写 | Implementer 说明，**Scribe** 落笔 | 同一 PR 或紧随的文档 PR |
| `proposal:done` 标记 | Scribe | 工作包全部关闭后手工打 |

三条边界：

- **文档 PR 合入 ≠ 设计定稿。** 定稿只由 Maintainer 的明确 `accepted-design` 裁决产生。
- **Proposal issue 不需要设计文档才能提。** 因此「不能提文档」不构成提案障碍。
- **Scribe 是执行者，不是决策者。** 它按 Maintainer 指令整理共识，不自行接受设计或排期。
