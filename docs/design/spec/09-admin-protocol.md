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
| 会话 | `sessions.list / read`（只读查看，转录归档） |
| 插件 | `plugins.list / get / validate / install / enable / disable / activate / rollback / uninstall`；安装/升级传本地包路径，新增 capability 必须显式确认；卸载前执行引用检查（§12.7~§12.10） |
| 系统 | `system.health`（进程、SQLite、fiber 概况） |
| 配置 | `config.reload`（触发 §11.2 先验后换管线，返回接受/拒绝与原因）；`config.status`（当前配置摘要哈希、最近 reload 结果、restart 类待生效项） |

契约版本化：协议带版本号与 caps 协商（NDJSON 首帧 hello 已有此机制；HTTP 走 `/api/v1/` 前缀）。

### 9.3 生命周期与模板命令面（M4.4-WP4）

生命周期与模板经 IPC/HTTP 可查可操作。鉴权口径按传输面分：IPC 读命令匿名、写命令认证（M1-WP9 口径）；HTTP 全部 /api/v1/ 路由外层统一 Bearer token（token 模式下无匿名读）。

| 命令 | IPC | IPC 认证 | HTTP | HTTP 认证 |
|---|---|---|---|---|
| sessions.lifecycle（status 过滤查询） | ✓ | 匿名 | GET /api/v1/sessions.lifecycle | token |
| sessions.dormant（older_than_days 负数/越界拒绝） | ✓ | 写认证 | POST /api/v1/sessions.dormant | token |
| sessions.archive | ✓ | 写认证 | POST /api/v1/sessions.archive | token |
| sessions.gc（confirm 闸 + 目录限定） | ✓ | 写认证 | POST /api/v1/sessions.gc | token |
| templates.list | ✓ | 匿名 | GET /api/v1/templates.list | token |
| templates.clone（冲突 → error/409） | ✓ | 写认证 | POST /api/v1/templates.clone | token |

语义要点：

- **装配**：lifecycle store 与 AgentRegistry 构造后经 setter 注入 IPC/HTTP 两侧（registry 创建晚于两侧构造）；IPC hello 帧随 token 上行（discovery.json 同源回读），写命令认证闸由此打通。
- **GC 目录限定**（base_dir= gateway data_dir）：词法 expand 拦 `../`（CWE-22）；「最深已存在祖先 realpath + 词法尾段回拼」复核拦中间组件 symlink（CWE-59），检查与写盘同用 realpath 原生值，分隔符归一仅 Windows flag 生效。越界拒收且不预创建目录。
- **休眠原子性**：mark_dormant 条件 UPDATE（`status='active' AND last_active_at < cutoff`）原子查改，查改间隙被 touch 刷新的会话不误标；last_active_at 纳秒精度（默认 rfc3339 无小数秒，同秒相等使 older_than_days=0 判定失效）。

**锚点（工部复核）**

| 断言 | 锚点 |
|---|---|
| admin_dispatch 统一路由 + 写命令认证闸 | src/admin/ipc/server.cr:315-322 |
| lifecycle/templates 命令分发 | src/admin/ipc/server.cr:251-333 |
| HTTP 路由表 | src/admin/http/server.cr:79-115 |
| gateway 注入接线 | src/platform/cli/gateway.cr:140-145 |
| GC 目录限定 | src/sessions/lifecycle/lifecycle.cr:139-167 |
