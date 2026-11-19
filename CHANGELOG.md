# Changelog

本文件记录本项目的显著变更，格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [Unreleased]

## [0.1.0] - 2026-11-19

首个公开版本。里程碑口径以 `README` 与 `docs/design/review/*-gate.md` 为准。

### Added

- **M0 单账号闭环**：email 账号接入（IMAP IDLE / SMTP）、agent 池、SQLite 持久层（intent/task/checkpoint）、
  基础工具执行器、NDJSON 管理面 TUI；强杀后从 checkpoint 续跑。
- **M1 多账号与热更新**：Account/Agent/Binding 三正交路由；企业微信、飞书/Lark 渠道；TokenProvider 与限流；
  凭据保护（AES-256-GCM 静态加密 + OS keyring/主密钥文件降级）；配置免重启热更新（先验后换 + Atomic 整根替换）。
- **M2 编排**：触发→条件→动作 DSL 解析与校验、持久工作流引擎、统一触发器（cron/事件/webhook/账号）、
  审批中心（fail-closed）、账本与预算熔断、lease、runs 视图（replay + audit）。
- **M3 协作与插件**：多 agent 协作与 `message_agent` 防环、subagent 信号量、mrb.cr 插件沙箱可行性预研与降级结论。

### Documentation

- 设计与开发计划：`docs/design/design.md`、`docs/design/development-plan.md`。
- 里程碑门禁证据：`docs/design/review/m0-gate.md` ~ `m3-gate.md`。

[Unreleased]: https://github.com/ShiningRay/sebas/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/ShiningRay/sebas/releases/tag/v0.1.0
