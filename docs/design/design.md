# Seneschal —— Crystal 多账号可编排 Personal Agent 平台 · 整体设计与方案（草案）

> 状态：**待用户过目**。本文档为调研后的整体设计草案，未动任何代码；用户未授权前不进入实现。
> 起草：工部尚书（gongbu-shangshu），2026-11-18。基于六份调研笔记：`research/hermes-agent.md`、`research/openclaw.md`、`research/pi-durable.md`、`research/autobot-architecture.md`、`research/channels-wecom-lark-email.md`、`research/prior-art-notes.md`（以下分别简称 **Hermes/OpenClaw/Pi/autobot/渠道/旁证**）。
> 事实性引用均锚定上述笔记；笔记中标注「未验证」处本文照实标注，不凭空补事实。
> **2026-11-20 拆分**：原 1026 行单文件按章拆入 [spec/](spec/README.md)，本文件保留为总览与索引。**章号不变，`§N` 锚仍然有效**；**行号锚已全部废弃**。

---

## 这是什么

运行在用户自己机器上的 **Crystal 单二进制** Personal Agent 平台——同时绑定**同渠道 N 个账号**（多个 email、多个企业微信、多个飞书/Lark），用户以「**触发→条件→动作**」编排自动化流程，并支持多 agent 协作。四条硬需求（多账号 / 可编排 / 免重启热更新 / 插件脚本层）分别在 §5、§7、§11、§12 立专章。

## 章节索引

| 章 | 主题 | 一句话 |
|---|---|---|
| [§1](spec/01-executive-summary.md) | 执行摘要 | 定位、调研结论、整体形态 |
| [§2](spec/02-goals-non-goals.md) | 目标与非目标 | 四条硬需求范围与防蔓延边界 |
| [§3](spec/03-core-concepts.md) | 核心概念模型 | Account/Agent/Binding、most-specific 路由、会话键五段 |
| [§4](spec/04-architecture.md) | 总体架构 | 分层职责、Crystal 实现要点、进程模型 |
| [§5](spec/05-multi-account.md) | 多账号设计（硬需求①） | 账号生命周期、TokenProvider、Email/WeCom/Lark 三渠道 |
| [§6](spec/06-session-memory.md) | 会话与记忆 | 会话管理、记忆分层、会话输入调度（提案态） |
| [§7](spec/07-orchestration.md) | 编排引擎（硬需求②） | 三段式原语、效应三明治、幂等三件套、lease 与预算 |
| [§8](spec/08-multi-agent.md) | 多 Agent 协作 | 防环三件套、subagent 边界、并发上限 |
| [§9](spec/09-admin-protocol.md) | 管理面与控制协议 | TUI + HTTP 双入口与共用契约 |
| [§10](spec/10-security.md) | 安全模型 | fail-closed 清单、凭据保护、审批链、Sandbox |
| [§11](spec/11-hot-reload.md) | 配置热更新（硬需求③） | 四正交件、组件重应用矩阵 |
| [§12](spec/12-plugin-layer.md) | 插件脚本层（硬需求④） | mruby 子进程、沙箱 watchdog、包生命周期、hook 闭集 |
| [§13](spec/13-module-layout.md) | 目录结构与模块划分 | src/ 布局草案与模块归属 |
| [§14](spec/14-roadmap.md) | 分期路线图 | M0–M3 验收要点、排期依据、共同门禁 |
| [§15](spec/15-risks.md) | 风险与未决问题 | 未验证依赖 13 条、架构性能风险、已知代价 |
| [§16](spec/16-sources.md) | 调研来源对照表 | 决策 → 笔记依据 |
| [附录](spec/99-open-questions.md) | 本文档未决事项 | 向用户征求决策的五条 |

## 与其他文档的关系

- **怎么建**（WBS、排期、门禁、首迭代）：[development-plan.md](development-plan.md)。
- 全库文档导航：[README.md](README.md)。
- 历史核验、提案与调研笔记：见 [README.md](README.md) 的分类表；本文件不重复其内容。
