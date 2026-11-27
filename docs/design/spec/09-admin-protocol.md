# design.md §9 管理面与控制协议

> 导航：[设计总览](../design.md) ｜ [文档索引](../README.md) ｜ 上一节：[§8](08-multi-agent.md) ｜ 下一节：[§10](10-security.md)

## 9. 管理面与控制协议

**架构级前置决策：先定通信契约**（旁证 §一.6 教训：没有管理面协议，任何编排面板都接不上——autobot `-p PORT` 只打印不监听的历史教训）。

### 9.1 主线：双入口（NDJSON/IPC TUI + HTTP API）

**入口 A：NDJSON over IPC**（本地 TUI）——复用 autobot 已验证模式（旁证 §一.7，713ed632 已过 spec+Windows 冒烟）：
- 协议：NDJSON 一帧一行、**8MiB 上限、首帧 hello、caps/版本校验**；discovery 文件复用 token；`--ipc auto|unix:PATH|tcp:HOST:PORT`（Windows 下 unix socket 不可用时 fallback `tcp:127.0.0.1`，autobot `--ipc tcp:18791` 已冒烟通过）。
- 优点：本地使用不开网络端口，攻击面小。

**入口 B：HTTP API（带鉴权）**——与**渠道回调面共用同一个 HTTP 监听器**：
- 反正要为回调型账号（企微自建应用/飞书 webhook）开 HTTP 面，管理 API 挂同一端口统一鉴权（旁证 §三.1 建议：管理面与渠道回调可共用一个带鉴权 HTTP 面）。
- 默认 `bind 127.0.0.1`；远程访问建议 Tailscale/SSH tunnel（OpenClaw 同款推荐）；`auth.mode: token | password | tailscale`（OpenClaw 模式集之子集，剔除 none/trusted-proxy——个人平台无需）。
- SSE 事件流：`events.subscribe` 推送运行事件（编排 run 进度、账号健康、审批请求）。

**理由**：TUI 本地零端口；HTTP 面是回调账号的必需品，管理 API 搭车零额外暴露；未来 Web 编排面板消费同一 API，无需新协议。

**备选**（列为弃选但保留）：只做其一——只 IPC（无 Web 面板与远程管理能力）或只 HTTP（本地 TUI 也要走网络栈、Windows 防火墙交互）。主线双入口覆盖两者的短板。

### 9.2 契约草案（双入口共用语义，传输不同）

| 域 | 操作 |
|---|---|
| 账号 | `accounts.list / create / update / delete / enable / disable`；`accounts.status`（连接状态、token 状态、限流水位、最近错误） |
| 渠道回调 | `POST /cb/<channel>/<account_id>/<path>`（验签→落库→入总线，§5.2） |
| Webhook | `POST /hooks/wake`、`POST /hooks/<name>`（带鉴权，触发 workflow） |
| 编排 | `workflows.list / create / update / delete / enable`；`runs.list / get / replay`（账本回放）；`runs.cancel` |
| 审批 | `approvals.list / approve / deny`（含 pending 队列、超时策略展示） |
| 事件流 | `events.subscribe`（SSE / NDJSON 推送，按域过滤） |
| 会话 | `sessions.list / read`（只读查看，转录归档；`sessions.read` 返回 transcript id 游标并支持 `after_cursor` 对账） |
| 插件 | `plugins.list / get / validate / install / enable / disable / activate / rollback / uninstall`；安装/升级传本地包路径，新增 capability 必须显式确认；卸载前执行引用检查（§12.7~§12.10） |
| 系统 | `system.health`（进程、SQLite、fiber 概况） |
| 配置 | `config.reload`（触发 §11.2 先验后换管线，返回接受/拒绝与原因）；`config.status`（当前配置摘要哈希、最近 reload 结果、restart 类待生效项） |
| TUI 对话（M6.5，[tui-conversational-console.md](../proposals/tui-conversational-console.md)） | `tui.input {session_key, peer, content}`（写命令，需认证；仅选中 TUI 会话可发，走完整 binding → scheduler → pool）；`tui.output {peer, content, event_id}`（推送帧，adapter.send 触发）；`transcript.appended {session_key, cursor, role, content, created_at}`（cursor=transcript id；主动对账恢复）；`approval.requested/decided {id, tool, args_summary, run_id, deadline}`（推送帧，Approvals::Center 触发） |

契约版本化：协议带版本号与 caps 协商（NDJSON 首帧 hello 已有此机制；HTTP 走 `/api/v1/` 前缀）。TUI 对话帧在 IPC caps 中追加 `tui.subscribe`。
