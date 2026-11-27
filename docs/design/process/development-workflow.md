# 开发工作流总纲

> 文档职责：定义 sebas 仓库的分支模型、里程碑排期、issue 生命周期、验收与发版流程，
> 以及参与这些流程的 Agent 角色分工。
> 各 Agent 的详细职责与工作逻辑见同目录下对应的角色文档。
> 本文与 [CONTRIBUTING.md](../../../CONTRIBUTING.md) 互补：CONTRIBUTING 面向外部贡献者讲"怎么提 PR"，
> 本文面向维护者与 Agent 讲"整个项目怎么运转"。

## 1. 分支模型：简化 GitHub Flow + 按需 release 分支

不使用 GitFlow 的常驻 develop/hotfix 全家桶。核心是单主干 + 按需拉出的稳定化分支。

```
main ──●──●──●──●──●──●──●──●──●──▶   日常开发，持续集成，永不冻结
              │
              ● release/x.y.z（仅验收期需要冻结时拉出）
              │    ╲
              │     hotfix/x.y.z+1（从出问题的 tag 切出）
              ▼      ▼
            tag vX.Y.Z + 三平台产物   修复同时合回 main
```

### 分支职责

| 分支 | 职责 | 生命周期 |
|---|---|---|
| `main` | 唯一长期主干。所有 PR 合这里，CI 全绿才许合 | 永久 |
| `feat/…`、`fix/…`、`docs/…`、`ci/…` | 短命的 PR 分支，一卡一支 | 合并即删（仓库已开自动删） |
| `release/x.y.z` | 发版窗口期的稳定化分支，只收回归修复 | 仅在验收期需要冻结时拉出；验收一次过则不拉 |
| `hotfix/x.y.z+1` | 已发布版本的紧急修复 | 从 tag 切出，修完打新 tag 后合回 main |

### 大功能的隔离方式

用 feature flag 在代码内隐藏未完成的能力，而不是靠长命 feature 分支隔离。
长命分支与 main 的合并成本随时间指数增长，feature flag 的成本是线性的。

## 2. 里程碑与排期

### 里程碑 = 版本目标，issue = 工作包

M0–M7 的期划分已落成 GitHub milestone：

| milestone | 对应期 | 版本 | 内容 |
|---|---|---|---|
| v0.2.0 | M4 | minor | Fork/Join 影分身（29 卡） |
| v0.2.x | 并行轨 | patch 系列 | 插件与平台演进（8 卡） |
| v0.3.0 | M5 | minor | 承诺与提醒闭环（16 卡） |
| v0.4.0 | M6 | minor | 外部日历只读镜像与重估（10 卡） |
| v0.5.0 | M7 | minor | 受控投影与撤销审计（5 卡） |

每张工作包卡有独立 issue + `Automation` 块，父卡用 sub-issue 关系聚合子卡。

### 排期三规则

1. **任何时刻只有一个 active milestone（主线）**。在 v0.2.0 清空之前，不开 M5 的实现卡。
   允许一条并行轨（如 v0.2.x 插件演进），上限 2 条。
2. **里程碑内部按 DAG 推进**，不按 issue 编号顺序。
   依赖关系见 [plan/schedule/](../plan/schedule/) 的 B.1 DAG。
3. **卡片开工前过三道闸**：
   - 在 active milestone 内（或属于被批准的并行轨；主线无就绪卡时才调度并行轨）
   - DAG 上前置卡已全部关闭
   - 外部依赖已就绪（E.1 系列账号配置等）

### 里程碑顺序的机器可读编码

GitHub milestone 没有显式排序字段（`number` 是创建序，`due_on` 可空）。
为了让 Agent 能确定性判断"当前该做哪期"，在 milestone 的 title 和 description 里编码顺序：

- title 格式：`M<N> · v<X.Y.Z> <主题>`，按字典序排即执行顺序
- description 首行：`order: <N>`（主线）或 `order: <N>x`（并行轨）

Agent 判定 active milestone 的算法见 [triager.md](triager.md) §3。

## 3. Issue 生命周期

### 分类

三个维度彼此正交，全部由 GitHub 原生字段表达，不再用自定义标签模拟：

| 维度 | 载体 | 取值与含义 |
|---|---|---|
| 性质 | Issue Type | Bug / Feature / Task，决定判据集与归宿条款 |
| 排期 | Milestone | 有 = 已排期；无 = 未排期 |
| 执行状态 | Issue Status | Backlog / Todo / In progress / In review / Done / Not planned |

| 类型 | 处理方式 |
|---|---|
| 工作包卡（带 `Automation` 块） | 不做 agent 研判；补 type/assignee，已排期则 status 推进到 Todo |
| Proposal | Issue 讨论 → 设计裁决 → 按需归档 → 单独排期 |
| 外部 bug | 走完整研判 → `bug-confirmed` → 按严重度分轨 |
| 外部 feature | 走完整研判 → `accepted` → 排期裁决 |

`plan` 标签与 `agent:in-progress` 标签已废弃：前者由 milestone 取代，后者由 issue status 取代。
存量清理见 `tools/retire_flow_labels.rb`。

### 状态流转

```
新建 issue            → Backlog
Triager 补 type/指派  → 仍 Backlog（未排期）
Maintainer 挂 milestone → Triager 补 status=Todo
Implementer 认领      → In progress（tools/sebas-process claim）
提 PR                → In review（tools/sebas-process mark-review）
合并关闭              → Done（GitHub 自动置）
关闭为 not planned    → Not planned
```

`needs:human` / `metadata:invalid` 仍保留为标签：它们表达的是暂停原因，不是进度状态。

### Proposal 生命周期

**权威归属与修订规则见 [proposal-lifecycle.md](proposal-lifecycle.md)**：文档是当前生效的契约，
issue 是讨论与裁决档案；小改走文档 PR，大改开新 Proposal 取代旧的。

重大行为、架构、配置或 DSL 变更从 **Proposal issue** 开始，不要求提案者先写设计文档、
fork 仓库或提交 PR。开放式探索可先在 Discussions 进行；形成具体待裁决建议后开 Proposal
issue。小型、明确的改进走 Feature request，不增加正式提案成本。

| 载体 | 职责 |
|---|---|
| Proposal issue | 提案入口、开放讨论、每次裁决的公开理由；**不是**当前设计的事实源 |
| `docs/design/proposals/` | 设计定稿后成为权威契约；变更走 PR，不散落在 issue 评论 |
| 工作包 issue | 排期批准后形成的工作包（带 `Automation` 块 + milestone），链接原 Proposal issue 与设计文档 |

```
Proposal issue（proposal + needs-triage）
  → Triager 查重、澄清、判断影响范围
  → Maintainer 裁决
       ├─ declined：proposal:declined，记录理由并关闭为 not planned
       ├─ needs-design：proposal:needs-design，继续公开讨论
       └─ accepted-design：proposal:accepted-design
             ├─ 小型明确改动：无需正式设计文档
             └─ 重大改动：Scribe 整理设计快照并提交 PR
  → Maintainer 另行决定排期
  → Scribe 按指令创建带 Automation 块的工作包；未排期的提案不进入实现选卡
  → 工作包全部关闭后打 proposal:done，Proposal 保持 open 作永久档案
```

状态标签只有 `proposal:needs-design` / `proposal:accepted-design` / `proposal:declined` /
`proposal:superseded`，外加叠加标记 `proposal:done`；
初始研判沿用 `needs-triage`，补充信息沿用 `question`，重复提案沿用 `duplicate`。
`backlog` 标签表达暂不排期，与 status=Backlog 并存：标签是人工标记的延期意图，status 是执行进度；不新增另一套状态标签。

责任边界：

- **Triager** 不裁决产品方向、不接受设计、不排期、不改仓库；结论不足时标记 `question`。
- **Maintainer** 将方向接受、设计定稿和排期分开决定；每次裁决在原 issue 留公开理由。
- **Scribe** 起草定稿候选但不定稿；文档 PR 合入不等于设计定稿。收到明确排期指令后，
  才可执行 WBS、milestone 与工作包的机械落地；不自行决定版本、优先级或容量置换。
- **Proposal 文档由 Scribe 独占撰写**，外部贡献者只开 issue 参与讨论，不直接投递设计文档 PR
  （CI 的 `check proposal document authorship` 步骤拦截非白名单作者）；细节见
  [proposal-lifecycle.md](proposal-lifecycle.md) §7。
- 原 issue 持续保存讨论记录。设计文档与实现任务必须回链它，不维护两份平行讨论；
  但**当前生效的设计以文档为准**，issue 里的旧评论不作为契约依据。

**接受设计不等于批准排期，也不承诺版本交付。**只有 Maintainer 决定排期，Scribe 才能按指令
创建工作包并挂 milestone；Implementer 再按现有开工三闸执行。

### 外部 issue 的研判与归宿

研判由Triager agent 执行（见 [triager.md](triager.md)），结论分六档：
`bug-confirmed / needs-info / accepted / rejected / duplicate / escalate`。

`accepted` 之后的排期裁决由人（Maintainer角色）做，四种归宿：

1. **塞进已有 milestone**：与某期目标契合 → 挂对应 milestone，容量内等量置换
2. **进 backlog 不排期**：有价值但不在路线图 → 保持 status=Backlog 并打 `backlog` 标签，不给 milestone
3. **独立小修**：一两个文件、不依赖任何 WP → **type=Task、不挂 milestone、走人工认领**
4. **不做**：偏离产品定位 → 礼貌关闭为 not planned，写明理由

**第 3 条的机制**：小修是唯一「无 milestone 也能合法开工」的形态。选卡器只从 milestone
内取卡，所以它不会自动认领小修——这正是我们要的：值不值得现在做由人判断。开工方式是
Maintainer 显式给出 issue 号，执行者用 `tools/sebas-process claim <issue> --apply` 认领；
不带 `--apply` 只做预检（输出 `ready` 不等于已认领，不写运行记录）。

小修卡仍需带 `Automation` 块：`kind=work_package`、`order` 给一个组内唯一值、
`depends_on` 显式为 `[]`。这是认领的前置，也是「它确实是一个可独立完成的工作单元」的声明。
`claim` 会拒绝「无 milestone 却不是小修」的卡（如无 milestone 的 Feature，或 `depends_on` 非空），
以免绕开 milestone 容量与 DAG 检查。
它不出现在 `next` 的候选里，也不进 `metadata_gaps` 的缺口提示——无 milestone 是它的正常形态，不是缺元数据。

判据是「一两个文件」这个量级，不是「懒得排期」。超出这个量级就该挂 milestone，
否则会绕开容量置换与 DAG 检查。

### Bug 的里程碑归属

Bug 和 feature 的本质区别：bug 是质量债，feature 是范围选择。
milestone 回答的问题是"这个修复随哪个版本出去"。

| 类别 | 判定 | milestone | 排期行为 |
|---|---|---|---|
| 本期范围内的缺陷 | 缺陷出在 active milestone 的 WP 内 | 当前 milestone，作为 WP 的 sub-issue | 算返工，不独立占排期 |
| 已发布版本的严重 bug | 崩溃/数据丢失/安全 | 专属 hotfix milestone（如 v0.1.1） | 立即修，从 tag 拉 hotfix 分支，独立发 patch |
| 已发布版本的普通 bug | 有 workaround、不阻塞主流程 | 下一个 feature milestone | 占用容量，按严重度插在 WP 之间 |

**没有 milestone 的 bug 不允许存在**——留空的 issue 会在只看 milestone 看板时消失。
"以后修"的正确表达是挂到下一个 feature milestone + 显式 `backlog` 标签 + 评论说明（milestone 和标签缺一不可）。

### 工作包卡的关闭流程

```
issue 开工（status: Todo → In progress，tools/sebas-process claim）
  → 实现，在对应 feat/… / fix/… / docs/… 分支
  → 提 PR，body 写 "Fixes #<issue号>"
  → status 推进到 In review（tools/sebas-process mark-review）
  → PR 过 CodeRabbit review（门闸 await-review 收尾后矩阵才起跑）
  → CI 全绿 + thread 全 resolve
  → squash 合并进 main
  → GitHub 识别 Fixes #n 自动关闭 issue（status 自动变 Done）
  → 回 issue 的「证据」节填写实际验证结果
```

约束：
- 「验收」节的每一条必须能在 PR 里找到对应证据（CI run 链接 / spec 输出 / 文档 diff）
- 父卡不自动关，靠 task list 手动勾选子卡，全部子卡关闭后父卡才手动关
- 纯文档卡的验收 = 文档合入 + review 意见清零，无 spec 要求

## 4. PR 与合并

### 仓库保护配置（实测）

- squash-only（`allow_merge_commit=false`，`allow_squash_merge=true`）
- `delete_branch_on_merge=true`
- 必检 contexts：`spec / ubuntu-latest`、`spec / macos-latest`、`spec / windows-latest`、`ameba`、`verify`、`await-review`
- `strict=true`（要求 PR 与 main 同步）
- `enforce_admins=true`（admin 也逃不过保护）
- `required_approving_review_count=0`（不需要人工 approve）
- `required_conversation_resolution=true`（所有 review thread 必须 resolve）

### 门闸：先 review，再跑 CI；有问题就先整改

`await-review` 是 PR 门闸：CodeRabbit 审完，三平台矩阵与 ameba 才起跑；
审查提出需整改项时矩阵直接不跑，等改完再 push。两条都为了不把 runner
烧在废稿上（矩阵 1-2 分钟就绿，审查要 5-7 分钟）。

判定分两段：排序阶段 fail-open（draft、超时、审查中断都放行），
整改阶段是真判定（读当前 head 的 review，匹配 `Actionable comments posted: N`，
N>0 即 job 红）。判出问题时贴一条带 marker 的清单评论，重跑更新同一条。

门闸变红是安全的，因为 `await-review` 本身已是分支保护必检——
否则 GitHub 会把「依赖失败导致下游 skip」当成不阻塞合并，等于放行。
这两条互为条件，改动任一处都要核对另一处。

完整规则（两阶段表、时间窗、超时分层、为什么不能退回出现窗）见
[pr-gate.md](pr-gate.md)。

### 合并自动化层级

| 层级 | 机制 | 适用场景 |
|---|---|---|
| GitHub 原生 auto-merge | `gh pr merge --auto --squash`，CI 绿即合 | dependabot / docs / 小修 |
| Agent 自动修复推进 | ZCode workflow：发现 PR → 修 review → 修 CI → 合并 | feature / 架构改动 |
| 人工合并 | 人审完点按钮 | 大版本发版 PR / 高风险变更 |

### BEHIND 处理

`strict=true` 时 main 有更新会导致 PR 变 BEHIND，需要 `gh pr update-branch` 重跑 CI。
Agent 自动修复 workflow 已内置此逻辑。

## 5. 验收体系

验收拆成四层，AI 能做的程度不同：

| 层级 | 动作 | 执行者 |
|---|---|---|
| CI 确定性门禁 | spec / ameba / format / release build | 脚本（已在 CI 跑） |
| LLM 独立核验 | 锚点实证、一致性对账、算术闭合、行为实测 | Verifier agent（只读、独立上下文） |
| 终验收口 | 对Verifier的"应修"项复跑确认（独立进程阶段） | Verifier agent 的终验阶段（只读、独立上下文，#124 起 Reviewer 并入） |
| 意图裁决 | 冻结口径 / No-Go / 产品方向 | 人（Maintainer角色） |

### 验收纪律

1. **验收 agent 不能是实现 agent**——同一上下文既写代码又验收等于自己改考卷
2. **允许"未实测"状态存在**——跑不了就写未实测，不许编证据
3. **分级结论**：阻断 / 应修 / 可留，三级分明
4. **实证主义**：每条结论锚到具体命令输出 / 行号 / API 返回

### M-gate 验收流程

```
本期所有 WP 卡关闭
  → 门禁卡开工，Verifier跑 B.3 五项 + 本期特有验收条目
  → 写 docs/design/review/mX-gate.md，逐条贴证据
  → 外部依赖未就绪项走冻结口径裁断（三条件缺一不可）
  → Verifier终验阶段复跑应修项收口
  → 人终审签字
  → 打 tag 触发 release
```

## 6. 发版流程

### 版本号分轨

| 级别 | 触发方式 | 自动化程度 |
|---|---|---|
| patch（vX.Y.Z+1） | push 到 main 含 fix 类变更 | 全自动（auto-release.yml） |
| minor（vX.Y+1.0） | workflow_dispatch 人工确认 | 半自动（机器备料，人点确认） |
| major（vX+1.0.0） | 全人工九步流程 | 机器只负责构建 |

### 发版 PR（minor/major 共用）

1. 更新版本号两处：`shard.yml` 的 `version` 字段 + `src/version.cr` 的 `VERSION` 常量
2. 转正 CHANGELOG：`[Unreleased]` → `[X.Y.Z] - 日期`，新增空 `[Unreleased]`，更新底部链接
3. 提 PR（`chore(release): vX.Y.Z`），CI 绿后 squash 合并
4. 在合并后的 main 上打附注 tag：`git tag -a vX.Y.Z -m "..."`
5. 推送 tag：`git push origin vX.Y.Z`
6. release.yml 自动跑三平台构建 + 发 GitHub Release
7. 产物校验：sha256 全过 + Linux 包在裸容器跑 `sebas version`（输出应含该次构建的 git rev）
8. 关 milestone

### patch 自动发版的护栏

- `[skip ci]` 防死循环
- 并发锁防重复打 tag
- 遇到 feat 类 commit 跳过（属于 minor 轨）
- tag 冲突检测，不覆盖已有 tag
- 版本号严格递增校验

### 产物校验（不可省）

```sh
gh release download vX.Y.Z --dir /tmp/sebas-vX.Y.Z
cd /tmp/sebas-vX.Y.Z && sha256sum -c *.sha256
docker run --rm -v $PWD:/assets ubuntu:24.04 \
  bash -c "cd /assets && tar xzf sebas-linux-x86_64.tar.gz && ./sebas-linux-x86_64/sebas version"
```

输出 `sebas X.Y.Z (<git rev>)` 才算发版完成。产物校验过了才关 milestone。

## 7. Agent 角色总览

| 角色 | 文档 | 核心职责 |
|---|---|---|
| Maintainer | [maintainer.md](maintainer.md) | 拍板：排期裁决、范围决策、冻结口径裁断、发版终审 |
| Implementer | [implementer.md](implementer.md) | 执行：实现工作包、修 review 意见、修 CI、提 PR |
| Verifier | [verifier.md](verifier.md) | 独立核验与终验：锚点实证、一致性对账、行为实测、分级结论；终验阶段对应修项复跑收口（#124 起 Reviewer 并入） |
| Triager | [triager.md](triager.md) | issue 研判：六判定、定 type/label/assignee、milestone 归属建议 |
| Scribe | [scribe.md](scribe.md) | 文档与记忆：设计文档维护、记忆库存取、CHANGELOG 维护 |
| Release Manager | [release-manager.md](release-manager.md) | 发版执行：版本号 bump、tag 管理、产物校验、auto-release 运维 |

### 角色间的关系

```
用户（人）
  │
  ├─ Maintainer ────────────── 拍板与裁决（人）
  │    │
  │    ├─ Implementer ───────── 实现（AI，可写代码）
  │    │    │
  │    │    ├─ Verifier ── 独立核验与终验（AI，只读，独立上下文，两阶段分离进程）
  │    │    │
  │    │    └─ Scribe ── 文档与记忆（AI，可写文档）
  │    │
  │    ├─ Triager ─────── issue 研判（AI，只读仓库 + 写 issue 元数据）
  │    │
  │    └─ Release Manager ─────── 发版执行（AI，可写版本号与 tag）
  │
  └─ 直接干预 ────────── 任何角色都可被人直接接管
```

核心原则：**执行与验收分离**。Implementer做的东西由Verifier验，Verifier的应修项由终验阶段复跑收口（#124 起 Reviewer 并入 Verifier，核验与终验两阶段由独立进程承载），
Maintainer始终是最终裁决者。任何 AI 角色的结论都可被人推翻。
