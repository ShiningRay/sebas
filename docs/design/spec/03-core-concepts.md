# design.md §3 核心概念模型

> 导航：[设计总览](../design.md) ｜ [文档索引](../README.md) ｜ 上一节：[§2](02-goals-non-goals.md) ｜ 下一节：[§4](04-architecture.md)

## 3. 核心概念模型：Account / Agent / Binding

三正交概念（融合 OpenClaw accountId/agentId/binding 与 Hermes RoutingIdentity 双身份解耦；OpenClaw §3、Hermes §4.2/§8.3）：

### 3.1 三概念定义

| 概念 | 定义 | 不包含 |
|---|---|---|
| **Account（账号）** | 一个渠道账号实例：`{account_id, channel_type, platform/base_url, credentials, token_ref, receive_mode}`。是「连接 + 凭据」的载体，只负责收发消息（渠道笔记设计启示 1） | 不含任何智能/人格/记忆 |
| **Agent（大脑）** | 一个人格化 agent 实例：人格（SOUL/system prompt）+ 记忆 + 会话库 + 工具集 + 模型配置 + 私有 cron + 管理面元数据（分类与标签 `category`/`tags`，配置为真相源，实例首建时固化，见 §3.4；[提案 agent-category-tags.md](../proposals/agent-category-tags.md)）（OpenClaw §9 agentId 语义；Hermes profile 的「完整 agent」减去凭据） | **不含渠道凭据**（与 Hermes profile 的关键差异：凭据归 Account，两轴正交） |
| **Binding（绑定）** | 路由表：把入站事件 `(channel_type, account_id, peer)` 映射到 `agent_id`，most-specific 优先（OpenClaw §9 binding 层级） | 不是配置的唯一真相源（只管路由） |

「哪个账号收」（transport）与「哪个 agent 执行」（runtime）是**两个可独立配置的轴**（Hermes RoutingIdentity：`transport_profile` / `runtime_profile`）。典型用法：两个企微账号（公司 A、公司 B）的消息都路由给同一个工作 agent；或一个 email 账号按发件人分流给两个 agent。

### 3.2 路由规则（most-specific 顺序，简化采用 OpenClaw 层级）

```
exact peer > parent peer > peer wildcard > guild+roles > guild > team > account > channel > fallback(owner)
```

- 同层按配置声明顺序；多字段之间 AND（OpenClaw §9）。
- `account: "*"` 匹配任意账号；省略 account 仅匹配该渠道默认账号（OpenClaw §3 语义细节：defaultAccount 显式配置 > 名为 default 的账号 > 排序第一个）。
- **fail-closed**：无匹配 binding 的入站事件**丢弃**并记审计日志（Hermes：路由到未服务 profile 即丢弃）。
- 出站：动作显式指定 `(channel, account, peer)`；未指定账号时走该渠道默认账号（OpenClaw 出站默认账号规则）。

### 3.3 会话键（含账号维度）

```
session_key = "agent:<agent_id>:<account_id>:<channel_type>:<peer>"
```

修复 autobot 的 `#{channel}:#{chat_id}` 无账号维度跨账号撞车问题（autobot B4：`bus/events.cr:29-31` 两个同渠道账号的同一 chat_id 会撞进同一会话文件）；`agent:` 前缀与 OpenClaw 单 agent 默认 `agent:main:main` 同构。

### 3.4 配置树示例（YAML）

```yaml
# config.yaml —— 顶层：channels / providers / agents / bindings / workflows / gateway
channels:
  email:
    accounts:
      - id: personal-gmail            # Account：一个 email 账号
        platform: imap.gmail.com      # IMAP 主机；SMTP 也用它（smtp 段无 host 字段，属已知欠账，见 §5.4）
        receive: imap-idle            # Gmail 与应用专用密码同走 IDLE（#23 裁决，§5.4）
        smtp: { port: 465, tls: implicit }   # 依赖 imap.gmail.com:465 提供 SMTPS 的非规范行为
        credentials:                   # 值经 ${ENV} 展开；敏感值入 keyring（§10.2）
          user: ${MAIL_USER}
          password: ${MAIL_PASSWORD}   # 应用专用密码（§5.4；M1-WP7 起改 keyring 引用）
      - id: work-outlook
        platform: outlook.office365.com
        receive: imap-idle            # 非 Gmail 邮箱走 IMAP IDLE
        credentials:
          client_id: ${OUTLOOK_CLIENT_ID}
          refresh_token_ref: keyring:email/work-outlook/refresh_token
  wecom:
    accounts:
      - id: company-a
        mode: aibot-longconn          # 智能机器人长连接（优先形态，§5.5）
        credentials:
          corpid: ${WECOM_A_CORPID}
          aibot_secret_ref: keyring:wecom/company-a/secret
      - id: company-b
        mode: app-callback            # 自建应用回调（备选形态）
        callback_path: /cb/wecom/company-b/
        credentials:
          corpid: ${WECOM_B_CORPID}
          agentid: 1000002
          token_ref: keyring:wecom/company-b/callback_token
          aes_key_ref: keyring:wecom/company-b/encoding_aes_key
  lark:
    accounts:
      - id: feishu-main
        platform: feishu.cn           # base_url 必须入账号配置（§5.6）
        receive: ws-longconn
        credentials:
          app_id: ${FEISHU_APP_ID}
          app_secret_ref: keyring:lark/feishu-main/secret
      - id: lark-intl
        platform: larksuite.com       # Lark 与飞书账号体系完全独立
        receive: ws-longconn
        credentials:
          app_id: ${LARK_APP_ID}
          app_secret_ref: keyring:lark/lark-intl/secret

providers:                           # Provider 层（#214）：厂商级配置，agent 按名引用
  deepseek:
    api_key: ${DEEPSEEK_API_KEY}     # 启动时迁入 vault（§10.2）；多 agent 共享一份
    base_url: https://api.deepseek.com
    protocol: openai-compatible      # openai-compatible | anthropic（协议与厂商解耦）
  anthropic:
    api_key: ${ANTHROPIC_API_KEY}
    base_url: https://api.anthropic.com/v1
    protocol: anthropic

agents:                              # Agent：大脑，可多实例
  main:
    provider: deepseek               # 引用 providers.<name>
    model: deepseek-chat             # 裸模型名（不再用 <provider>/ 前缀编码厂商）
    category: general                # 管理面分类（可省；[a-z0-9][a-z0-9-]* 1..64）
    tags: [assistant, triage]        # 管理面标签（多值可省；同词法，重复报错不去重）
    persona_file: agents/main/SOUL.md
    memory: { window: 50 }
    tools: { allow: ["*"] }
  work:
    provider: anthropic
    model: claude-sonnet-4
    persona_file: agents/work/SOUL.md

bindings:                            # Binding：路由表（数组，most-specific 优先）
  - { channel: email, account: work-outlook, peer: "*", agent: work }
  - { channel: email, account: personal-gmail, peer: "*", agent: main }
  - { channel: wecom, account: company-a, peer: "*", agent: main }
  - { channel: lark,  account: "*",       peer: "oc_review_group", agent: work }

workflows: [ /* 编排定义，见 §7.6 */ ]

plugins:                             # 插件面（M3-WP4，§12；缺省关闭）
  dir: plugins                       # 开发/源码布局目录；未配置 = 不扫描不注册
  interpreter: mruby                 # 裁剪解释器（mruby-sandbox 构建发布）

gateway:
  http: { bind: 127.0.0.1, port: 18790, auth: token }
  ipc: auto                          # NDJSON/IPC，见 §9
  collaboration: { max_hops: 4 }     # agent 间传递上限（防环），见 §8.1
```

要点：

- **应用根目录（#274，M5.0-WP3 已实现）**：完整契约见 [proposals/sebas-home.md](../proposals/sebas-home.md)。
    - **根目录与默认路径**：默认 `~/.sebas`，可由 `SEBAS_HOME` 覆盖（空白值拒启不回退；`~` 在路径层展开；相对值以启动目录立即绝对化，解析后进程内不再改变）。默认配置为 `<home>/config.yaml`，配置缺失 fail-fast 并展示实际查找的绝对路径。
    - **相对资源路径**：省略 `gateway.data_dir` 时解析期取 `<home>/data`（不向 YAML 树注入绝对路径）；显式相对值与相对 `agents.<name>.persona_file`、`plugins.dir` 均以实际配置文件目录为基准。显式 `--config` 只决定配置文件，不反向改变根目录或默认数据目录。
    - **旧布局回退**：未传 `--config` 且 `<home>/config.yaml` 不存在、启动目录有旧 `config.yaml` 时，一个版本的受限回退读旧文件并警告（展示配置与实际数据路径；绝不自动复制或搬移）。
    - **热更新**：不重读 `SEBAS_HOME`、不改换数据库/vault/IPC discovery；`data_dir` 变更 restart-required。POSIX 目录权限过宽只告警。

- **端口**：`http.port` / `ipc.port` 可填 `0`，表示由内核分配空闲端口（listen 后回写实际端口）；spec 与同机多实例用它避开默认 18790/18791。

- **渠道配置**：`channels.<type>.accounts[]` 为**数组结构**，每项一个账号一套凭据（autobot B1 的改造方向：`accounts: Array[AccountConfig]`；OpenClaw 的具名账号条目同构）。
- **敏感值**：配置加载沿用 autobot 的 `${VAR}` 展开 + chmod 0o600（autobot A 级件：`config/loader.cr` 机制），但敏感值改为 keyring 引用（`*_ref: keyring:<namespace>/<key>`，§10.2）。
- **provider 配置**（#214）：厂商级密钥 / base_url / protocol 独立于 agent，`agents.<name>.provider` 引用 `providers.<name>`，model 为裸模型名。
- **旧配置迁移**：旧形状（`agents.<name>.api_key` + `<provider>/<model>` 前缀推断、`provider_ref` 兼容字段）仍可加载并在启动时输出迁移指引，不静默失败。
