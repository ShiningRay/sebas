# design.md §10 安全模型

> 导航：[设计总览](../design.md) ｜ [文档索引](../README.md) ｜ 上一节：[§9](09-admin-protocol.md) ｜ 下一节：[§11](11-hot-reload.md)

## 10. 安全模型

### 10.1 fail-closed 清单（默认贯穿，Hermes §6/§8 借鉴 4）

| 场景 | 默认行为 |
|---|---|
| 路由无匹配 binding | **丢弃** + 审计日志（Hermes） |
| 回调无对应 adapter / 验签失败 | 404 / 401-403（Hermes） |
| 企微回调 receiveid(corpid) 不匹配 | 拒绝（防跨企业混串，渠道笔记 d3） |
| secret 无 scope（工具试图读不属于当前账号/agent 的凭据） | **raise 拒绝**（Hermes `UnscopedSecretError`；本平台经类型系统：凭据句柄构造时绑定账号命名空间，拿不到别人的句柄） |
| 审批超时 / 无人值守 | **deny**（Hermes 层 2 三键） |
| 审批卡展示不全的命令 | 只提供 Deny（Hermes 细节级借鉴） |
| 配置未加载时的 admin 列表 | 空列表=无管理员=拒绝（Hermes） |
| 重复凭据注册 | park 拒绝启动，不崩溃（Hermes） |
| 云端 SDK ambient 凭据链 | 不使用；账号无完整凭据则该 provider 拒绝（Hermes §2） |

### 10.2 凭据保护

- **从明文 YAML 迁到 OS keyring / 静态加密**（autobot B10 教训：明文 YAML+.env 仅 chmod 0o600）：
  - 首选 OS 凭据库：Windows Credential Manager / macOS Keychain / Linux secret service，主密钥托管于此；
  - 存量静态加密：AES-256-GCM 加密 secret 文件，主密钥入 keyring（OWASP Secrets Management 参考路线，渠道笔记 d1 工程建议）。
- **命名空间隔离**：key 按 `(渠道类型, 账号ID)` 命名空间（渠道笔记 d1）；LLM provider 密钥按 `("provider", 名称)` 命名空间（#214，agent 级遗留密钥仍走 `("agent", 名称)`）；日志全程脱敏 token/secret（autobot 已有 `LogSanitizer.redact_credentials` 可搬，A9）。
- **支持轮换**：企微/飞书 secret 均可在管理后台重置，OAuth refresh token 可撤销；管理面提供 `accounts.rotate-credential`；provider 密钥轮换（#214）改 `providers.<name>.api_key` 热更新即生效——一次轮换覆盖全部引用该 provider 的 agent，下一 turn 使用新密钥。
- **最小权限**：企微应用可见范围最小化、secret 按能力拆分；飞书应用按需申请 scope；Gmail「不需要完整邮箱 scope 时改用 Gmail API 细粒度受限 scope」（渠道笔记 d2）。
- 官方底线遵守：secret/token 只存服务端（本平台进程），不入前端/安装包/日志（渠道笔记 d1 三家一致原文）。

### 10.3 审批链

分层（借鉴 Hermes 八层中适用于个人平台的子集）：

1. **用户鉴权**（谁可对话）：渠道级 allowlist（autobot `allowed?` 的 `"*"`/ID 管道匹配机制保留，A 级件）→ 全局 allowlist → **默认 deny**。
2. **危险命令审批**：`approval.mode: smart|manual|off` + `timeout deny` + `deny`（用户 fnmatch 黑名单）+ `command_allowlist` + **hardline blocklist 不可 override**（§7.5）。
3. **文件写安全**：protected paths 硬拒（`~/.ssh/`、`~/.aws/`、`.env`、token 缓存等；Hermes 层 3）。
4. **MCP/外部工具**：精确控制加载哪些工具；工具花费上限是预算不是提示。

### 10.4 Sandbox 策略（Windows 个人部署）

- **应用层策略**而非内核沙箱：Windows 无 bubblewrap；autobot 的 bwrap/docker 路线在 Windows 不可用（旁证 §三.5）。
- 机制：workspace_only 路径校验（工作区外的写需审批）+ 系统敏感目录屏蔽 + 外部内容一律按 untrusted 包装（OpenClaw 借鉴 8：joinIntro 零工具、网络读取 taint 当前 turn）。
- **诚实文档化**：sandbox 自认非完美边界，写清「做不到什么」（OpenClaw 反面教训 4：read-only mount 只防改不防读等局限要在文档明示）。
- Gateway 默认 localhost-only；远程走 Tailscale（§9.1）。
