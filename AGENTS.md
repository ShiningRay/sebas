# AGENTS.md

> 给 AI agent 读的仓库指南。人类开发者请读 [CONTRIBUTING.md](CONTRIBUTING.md)。
> 本文件是 agent 在本仓库工作的**唯一权威入口**——读完本文件再动手。

## 项目是什么

Sebas：Crystal 写的多账号可编排个人 agent 平台。
绑定 email / 企业微信 / 飞书 N 个账号，用 trigger→condition→action DSL 编排持久工作流，
配置免重启热更新，内嵌 mruby 插件沙箱。

- 语言：Crystal >= 1.19（CI 跟踪最新 stable）
- 包管理：Shards（随 Crystal 附带）
- 依赖：C 工具链 + libsqlite3 / OpenSSL / PCRE2 开发头
- Windows：MSVC 版 Crystal + `vcpkg install "sqlite3[fts5]:x64-windows"`，或 MSYS2 UCRT64
- 仓库：https://github.com/ShiningRay/sebas

## 质量门禁（每次提交前必跑）

```sh
shards install
crystal spec                          # 0 failures
crystal tool format --check           # 不许手改格式
crystal build -o bin/ameba lib/ameba/bin/ameba.cr && ./bin/ameba   # 0 issues
ruby tools/check_docs.rb            # FAIL=0（WARN 可接受，仅限 docs/design/review/ 存档）
```

CI 额外做：三平台（ubuntu/macos/windows）spec + ameba + verify + release build + docs-check。
`make check` 跑 format-check + spec + lint（不含 docs-check）；`make docs-check` 单独跑文档门禁。
`verify` 是确定性的第五项必检：跑 `verify docs`（行号锚/行数）与
`verify anchors`（文档声称的 `file:line` 内容是否对得上源码），入口详见
`docs/design/process/quickstart.md` 的 Verifier 节。

## 目录结构

```
src/
  main.cr              # 入口
  version.cr           # VERSION 常量（发版时与 shard.yml 同步）
  platform/            # 平台抽象（CLI、进程、时间）
  config/              # 配置加载与热更新
  bus/                 # 事件总线
  supervisor/          # 进程监督
  store/               # SQLite 持久层（schema.cr 是唯一定义处）
  keys/                # 凭据保护（AES-256-GCM + OS keyring）
  channels/            # 渠道接入（email/wecom/lark）
  routing/             # 账号路由
  agents/              # Agent 池与生命周期
  orchestration/       # DSL、工作流引擎、审批、账本
  tools/               # 内置工具执行器
  providers/           # LLM provider 适配
  admin/               # 管理面（TUI / IPC）
  plugins/             # mruby 插件沙箱
docs/
  design/
    spec/              # 设计正文（按章拆自 design.md，§锚稳定）
    plan/              # 开发计划（WBS + DAG + 排期 + 门禁）
    process/           # 开发流程与 Agent 角色（本仓库的运转方式）
    proposals/         # 进行中的设计提案
    research/          # 调研与旁证
    review/            # 历史门禁/验收存档（行号锚保留，行版口径）
  examples/            # 示例插件与配置
tools/
  check_docs.rb        # 文档质量门禁
.github/
  workflows/           # ci.yml / release.yml / auto-release.yml / mruby-sandbox.yml / dependency-check.yml
  actions/setup/       # composite setup action
scripts/
  release.sh           # 人工发版脚本（major/minor）
```

## 代码约定

- 源码注释与设计文档用中文；对外文档（README / CONTRIBUTING / issue 模板）英文优先带中文要点。
- 新流程参考实现与自动化脚本使用 Ruby/Shell；不新增 Python 脚本。
- 目录按 `docs/design/design.md` 的章节分层，新增模块须回写对应章节。
- 用 `crystal tool format` 格式化，不手改。
- 平台相关代码用 `{% if flag?(:windows) %}` 等宏 flag 隔离，三平台都能编译。
  Windows-only FFI 独立文件。
- spec 用 `Dir.tempdir`，不依赖 `$TEMP` 等平台特定环境变量。
- 引用文档用 `§节号` 或文件路径，不用行号（`tools/check_docs.rb` 拦截行号锚）。
- 单文件体量三项并列：物理行 ≤ 400、等效屏幕行（100 列视口，CJK 记 2 列）≤ 400、单行显示宽度 ≤ 400 列；
  超过告警。长行不能靠硬折行消除（Markdown 软换行会渲染成空格），应拆子列表、表格或小节。
  口径详见 [scribe.md §体量口径](docs/design/process/scribe.md)。

## 分支与 PR

- 主分支 `main`，受保护：squash-only + 5 项必检（spec×3 + ameba + verify）+ strict + conversation resolution。
- 分支命名：`feat/…` / `fix/…` / `docs/…` / `ci/…`，从 main 切出，合并即删。
- PR body 写 `Fixes #<issue号>` 自动关联关闭。
- commit 用 Conventional Commits（`feat(orchestration): …`）。
- auto-merge 已开启：CI 绿 + thread 全 resolve 即可 `gh pr merge --auto --squash`。
- BEHIND 时 `gh pr update-branch` 重跑 CI，不 force-push。

## 里程碑与排期

- milestone 编码：title 带 `M<N>` 前缀，description 首两行 `order:` + `track:`（main/parallel）。
- active milestone 判定：按 order 排序后第一个 `open_issues > 0` 且 `track=main` 的。
- 任何时刻只有 1 个 active 主线 milestone，并行轨上限 2 条。
- 开工三闸：在 active milestone 内 / WP「依赖」字段的前置已有完成证据 / 外部依赖就绪。DAG 图仅用于排期展示。

## Issue 处理

- 带 `Automation` 块的是工作包卡，不做研判，仅补 type/指派；status 由 milestone 与执行进度驱动。
- 非计划类走完整研判：六判定（bug-confirmed / needs-info / accepted / rejected / duplicate / escalate）。
- type 按性质定（Bug/Feature/Task），assignee 仅 bug-confirmed/accepted 才设。
- bug 的 milestone 归属：本期范围内 → 当前 milestone；严重回归 → hotfix milestone；普通 → 下一 feature milestone。
- 没有 milestone 的 bug 不允许存在。

## 验收

- 执行与验收分离：实现者不能验收自己的产出。
- Verifier（只读、独立上下文）承载核验与终验两阶段，两阶段由独立进程执行（#124 起 Reviewer 并入）。
- 结论三级：阻断 / 应修 / 可留。允许"未实测"，不许编证据。
- M-gate：B.3 五项 + 本期特有条目 + m-gate.md 证据 + 冻结口径三条件。

## 发版

- **patch**：`auto-release.yml` 全自动，push 到 main 含 `fix(...)` 即触发，遇 feat 跳过。
- **minor**：Maintainer 在 Actions 页面 `workflow_dispatch` 输入 `minor`，半自动。
- **major**：人工走 `scripts/release.sh X.Y.Z`，完整九步流程。
- 版本号两处同步：`shard.yml` 的 `version` + `src/version.cr` 的 `VERSION`。
- tag 推送后 `release.yml` 自动构建三平台资产 + 发 GitHub Release。
- 产物校验：sha256 全过 + Linux 包在裸 ubuntu:24.04 容器跑 `sebas version`。

## Agent 角色

本仓库定义了 6 个角色，详见 `docs/design/process/`：

| 角色 | 性质 | 职责 |
|---|---|---|
| Maintainer | 人 | 决策与裁决（不可由 AI 替代） |
| Implementer | AI | 实现工作包、修 review/CI、提 PR |
| Verifier | AI | 独立核验与终验（只读、独立上下文；两阶段分离进程，#124 起 Reviewer 并入） |
| Triager | AI | issue 研判与分派 |
| Scribe | AI | 文档维护与记忆库管理 |
| Release Manager | AI | 发版执行与产物校验 |

详细职责与工作逻辑见 `docs/design/process/<role>.md`。

**直接起角色 Agent**：`ruby tools/sebas-process roles <role>` 输出该角色的规格路径、可执行命令和可粘贴提示词；
默认 dry-run，`--apply` 才写。见 `docs/design/process/quickstart.md`。

## 安全红线

- 永不提交凭据、token、私钥。
- 漏洞走私密报告（[SECURITY.md](SECURITY.md)），不开公开 issue。
- fork PR 的 workflow 改动必须先审 `.github/` diff 再批准运行（self-hosted runner 安全边界）。
- agent 不改仓库源码做 issue 研判；不改生产配置；不 force-push。

## 记忆库

本仓库使用 respire 记忆系统（`rsrs`）。每回合首次工具调用必须是 `rsrs recall`，
收尾必须 `rsrs remember`。细则见 `rsrs prompt` 全文。
