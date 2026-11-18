# Sebas

Crystal 多账号可编排 Personal Agent 平台 —— 运行在用户自己机器上的 **Crystal 单二进制**：
同时绑定同渠道 N 个账号（多个 email、多个企业微信、多个飞书/Lark），以「触发→条件→动作」
编排自动化流程，支持多 agent 协作、配置免重启热更新与 mrb.cr 插件脚本层。

- 设计定稿：[docs/design/design.md](docs/design/design.md)（16 章）
- 开发计划：[docs/design/development-plan.md](docs/design/development-plan.md)（M0–M3 WBS/排期/门禁）
- 计划核验：[docs/design/review/development-plan-verification.md](docs/design/review/development-plan-verification.md)
- 命名档案：[docs/design/naming.md](docs/design/naming.md)

## 里程碑

| 期 | 内容 | 状态 |
|---|---|---|
| M0 | MVP：单账号闭环（email 账号 + agent + 持久层 + 基础工具 + NDJSON TUI） | 进行中 |
| M1 | 多账号完备 + 配置热更新（binding 路由、企微/飞书、TokenProvider、keyring、热更新四正交件） | 待开始 |
| M2 | 编排完备（触发→条件→动作 DSL、持久 Task、审批、预算/lease、账本） | 待开始 |
| M3 | 协作 + 插件脚本层（message_agent 防环、subagent 信号量、mrb.cr 沙箱） | 待开始 |

## 质量门禁（每期 M-gate）

```sh
crystal spec      # 0 fail
./bin/ameba       # 无警告
make release      # 构建成功
```
