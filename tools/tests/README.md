# tools 测试套件

Agent 流程工具（`tools/`）的离线测试。全部 minitest + 标准库，不访问网络。

## 跑测试

```sh
ruby tools/tests/run.rb                     # 全量（47 个文件）
ruby tools/tests/run.rb docs                # 只跑一个域
ruby tools/tests/run.rb --list              # 列出会跑的文件
make agents-check                           # 等价于全量
```

`run.rb` 逐文件起子进程：evidence 测试会改写 `EvidenceRegister.runner`、
`git_runner` 这类模块级注入点，同进程串跑会把残留状态串到一起。

`legacy` 域兜住尚未迁到本目录的 `tools/test_*.rb`。并行分支先合入的新测试
若还留在旧路径，全量门禁照样会跑到它们（并在 stderr 提示迁移），
不会因为目录重组静默失跑。

## 目录

| 目录 | 覆盖对象 |
|---|---|
| `sebas_process/` | `tools/sebas-process` 的选卡、依赖对账、证据闸、Verifier、终验、CLI、gateway PR/checks 读取 |
| `evidence/` | `tools/evidence_register.rb` 的块读写、前置解析、两阶段登记 |
| `workflows/` | `.github/workflows/*.yml` 与 `.github/actions/setup` 的契约、`await_review.rb` 门闸语义、锚点抽取器、verify 汇总 |
| `docs/` | `tools/check_docs.rb` 与文档示例一致性 |
| `process/` | `tools/accept-proposal`、digest、backfill 脚本、版本守卫、Proposal 路径守卫、lease/scope/run_record |
| `support/` | 共享夹具（见下），不含断言 |

## 共享夹具

| 文件 | 提供什么 |
|---|---|
| `support/boot.rb` | 统一 require 标准库 + 装载全部夹具；每个测试文件只 require 它 |
| `support/repo_paths.rb` | `RepoPaths::ROOT` / `RepoPaths.join(...)`，避免各文件重复算 `__dir__` 深度 |
| `support/snapshot_helpers.rb` | `automation` / `evidence` / `issue` / `milestone` / `snapshot` / `select` |
| `support/cli_helpers.rb` | `run_cli` / `with_snapshot` / `write_json` |
| `support/gateway_stubs.rb` | `GatewayStubs::SequenceRunner`（按序吐响应、记录 argv） |
| `support/path_checks_helpers.rb` | `change` / `run_check` |
| `support/setup_action_helpers.rb` | 假工具链、`prepare` / `release`、`GITHUB_OUTPUT` 读取 |

夹具只放「多文件重复过的」东西。只在单个文件用的辅助方法留在该文件内，
避免 support 变成第二个大杂烩。

## 约定

- 文件名前缀 `test_`，且必须是 `.rb`——`PathChecks` 的测试联动规则只认这个形态
  （`tools/tests/**/test_*.rb`）。
- 新测试文件放进对应域目录即可，不必改 `Makefile` 或 `ci.yml`：清单由目录推导。
- 测试正文多为「缺陷回归」，注释写清**为什么**这条断言必须存在；无注释的用例
  应能从方法名读出被测行为。
- 单个文件超 400 行就该按主题拆（例如 `test_setup_action.rb` 与
  `test_setup_action_behavior.rb` 的结构/行为两分）。
