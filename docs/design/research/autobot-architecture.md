# autobot 架构考察笔记（面向「Crystal 多账号可编排 Personal Agent 平台」前期设计）

> 考察对象：本地仓库 `autobot`（Crystal 语言，工作目录即本仓库根）。
> 考察方式：纯静态源码阅读（未运行任何命令、未跑 spec/ameba），所有结论以「路径:行号」锚定；
> 未逐行读到的部分在文末「未验证清单」如实列出。
> 用途：新平台「参考 autobot 但不改造 autobot」——本笔记标出可复用件与单账号/单 Loop 假设，供重新设计取舍。
> 行号基准：考察时的当前工作树，行号可能随后续提交漂移。

---

## 0. 执行摘要

autobot 是**单进程、事件总线驱动的分层单体**：一个 `Bus::MessageBus`（有界 Crystal `Channel`）串起渠道→Agent Loop→工具/插件→Provider 的全部流转。它的核心限制与新平台目标直接冲突的共有四处：

1. **全局单 Loop**：`src/autobot/cli/gateway.cr:76` 只 spawn 一个 `"agent-loop"` fiber，`src/autobot/agent/loop.cr:122-152` 串行消费入站队列——一个慢 turn 阻塞所有会话（含 cron、subagent 汇报）。
2. **账号单例三层锁死**：config schema 每渠道类型一个槽位（`src/autobot/config/schema.cr:151-161`）→ `Channel::Manager` 按渠道名做 `Hash(String, Channel)` 键（`src/autobot/channels/manager.cr:25,104-112`）→ Provider 单 api_key 实例（`src/autobot/providers/provider.cr:14-19`；装配处 `src/autobot/cli/setup_helper.cr:57-89` 整个 gateway 只建一个 provider）。
3. **会话键无账号维度**：session key 就是 `"#{channel}:#{chat_id}"`（`src/autobot/bus/events.cr:29-31`），两个 Slack 账号的同一 chat_id 会撞进同一会话文件。
4. **无管理面**：`-p PORT` 只打印不监听（`src/autobot/cli/commands.cr:220` → `src/autobot/cli/gateway.cr:32`），唯一的 `HTTP::Server` 是 Gemini OAuth 一次性回调（`src/autobot/cli/auth.cr:71-99`）。

其余部件（Provider 抽象、Session JSONL、Memory 双文件、ReAct ToolExecutor、SKILL.md 机制、Markdown 渠道转换器、有界总线模式）与账号数量正交，**可直接复用为设计蓝本**。

---

## 1. 九条已知线索逐条验证

| # | 线索 | 结论 | 证据（路径:行号） |
|---|------|------|------|
| ① | 单进程事件总线分层单体，装配根在 `cli/gateway.cr` | **证实，顺序有修正** | `src/autobot/cli/gateway.cr:20-52`：Config::Loader.load(20) → bus(35) → session_manager(36) → setup_tools/mcp(38) → create_provider(39) → load_plugins(45) → setup_cron(46) → create_agent_loop(47) → start_ipc(51) → **setup_channels(52，在 loop 之后)**。线索原说 channels 在 loop 之前，实为之后。shutdown 逆序 `gateway.cr:55-65`；`{% unless flag?(:win32) %}` Signal trap `gateway.cr:70-73`；`gateway.cr:79` 主 fiber `sleep` 阻塞 |
| ② | Agent::Loop 单 fiber 串行消费 → 全局串行 | **证实** | `gateway.cr:76` `spawn(name: "agent-loop") { agent_loop.run }` 唯一入口；`loop.cr:122-152` `run` 内 `@bus.consume_inbound` 逐条处理；heartbeat `loop.cr:147-149`；cron 与 subagent 系统消息也走同一 Loop（`loop.cr:295-303` 按 sender_id 前缀分流） |
| ③ | session 隔离仅靠 key `"channel:chat_id"` | **证实** | `src/autobot/bus/events.cr:29-31` `def session_key : String; "#{channel}:#{chat_id}"; end`；消费点 `loop.cr:199`；system 消息按同规则拆回原会话 `events.cr:33-39`、`loop.cr:457-461` |
| ④ | 已支持渠道 4 个 slack/telegram/whatsapp/zulip | **证实（另有 ipc/cli/system 三个内部渠道名）** | `src/autobot/constants.cr:11-17`：SYSTEM/CLI/TELEGRAM/SLACK/WHATSAPP/ZULIP/IPC；外部渠道实现 `src/autobot/channels/{slack,telegram,whatsapp,zulip}.cr`；docs：`docs/slack.md`、`docs/telegram.md`、`docs/whatsapp.md`、`docs/zulip.md` |
| ⑤ | plugins 编译期内置，新增需改代码重编译 | **证实** | `src/autobot/cli/setup_helper.cr:253-260` `BUILTIN_PLUGINS` 编译期 Hash（sqlite/github/weather/system_info/text_to_speech/chat_log 六个 factory）；`setup_helper.cr:262-271` 仅遍历该清单按 config 开关注册；`src/autobot/plugins/loader.cr:8-12` 注释明示注册方式是 shard 初始化期 `Loader.register` |
| ⑥ | 无 HTTP 管理端，`-p PORT` 只打印不监听 | **证实** | `src/autobot/cli/commands.cr:220` 解析 `-p/--port`（默认 18790，`commands.cr:28`）传入 `Gateway.run`；`gateway.cr:32` 仅 `puts "Starting autobot gateway on port #{port}..."`，全文无 `HTTP::Server` 监听；`src/autobot/http.cr` 是 HTTP **客户端**工具与代理补丁；schema 里 `GatewayConfig{host,port}`（`schema.cr:237-244`）未被任何服务端消费 |
| ⑦ | cron 经 bus.publish_inbound 复用完整 agent turn | **证实，且有分支细化** | `gateway.cr:163-195` setup_cron：`on_job` 回调在 `job.payload.delivery_target` 存在时 `bus.publish_inbound(Autobot::Agent::Loop.cron_message(job))`（`gateway.cr:165`）→ 走完整 turn；**exec 类 job 不走 turn**：`on_exec`（`gateway.cr:169-179`）直接 `Cron::Formatter.format_exec_output` 后 `publish_outbound`。cron 消息构造 `loop.cr:178-185`（channel=system、sender_id="cron:#{id}"）；`loop.cr:307-350` run_cron_turn 用 origin 会话历史、`BACKGROUND_EXCLUDED_TOOLS=["spawn"]`（`loop.cr:38`）、`stop_after \|\| ["message"]`（`loop.cr:337`）；`loop.cr:392-406` build_cron_prompt |
| ⑧ | `autobot agent` CLI 绕过 Loop，只做单次 provider 调用 | **证实** | `src/autobot/cli/agent.cr:17-29` 自建 bus/session/tools/plugins（不经 Loop）；`agent.cr:120-178` process_message 注释自称 "Simplified single-turn version"；`agent.cr:141-152` 直接 `provider.chat(...)`；`agent.cr:157-173` 仅执行一轮 tool_calls，无迭代循环；REPL 在 `agent.cr:87-116` |
| ⑨ | subagent 可并行且无并发上限 | **证实** | `src/autobot/agent/subagent.cr:83-85` 每 task 一个 `::spawn do run_and_untrack(...)` fiber；登记表 `@running_tasks` Hash+Mutex（`subagent.cr:44-45,92-96`）只记账不限额，无信号量；`subagent.cr:25` MAX_ITERATIONS=15。细化：**subagent 的 LLM 调用真并行**（各自 fiber 独立 ToolExecutor），但结果汇报 `announce_result`（`subagent.cr:172-202`）经 `bus.publish_inbound` 汇回主 Loop，回到串行 |

---

## 2. Channel / Adapter 抽象细节（Focus 2）

### 2.1 抽象接口

`src/autobot/channels/base.cr`：

- `abstract class Channel`（`base.cr:19`），abstract 三件套 `start/stop/send_message`（`base.cr:19-25`），另有 `turn_ended(chat_id, reason)` 钩子（`base.cr:31-32`）——Loop 结束一 turn 后广播（驱动 typing 停止等）。
- 接收路径：各渠道实现收到消息后调 `handle_message`（`base.cr:75-97`）：先 `allowed?` 鉴权，再 `bus.publish_inbound`，并附最多 500 字符的回复上下文（`base.cr:58` REPLY_CONTEXT_MAX_LENGTH）。
- 鉴权 `allowed?`（`base.cr:41-56`）：默认拒绝，`"*"` 放行，支持 `"12345|username"` 管道分段 ID 匹配。

### 2.2 Channel::Manager 的创建与管理——单账号假设所在

`src/autobot/channels/manager.cr`：

- 存储结构 `getter channels : Hash(String, Channel)`（`manager.cr:25`）——**以渠道类型名为键**，一种类型最多一个实例。
- `init_channels`（`manager.cr:104-112`）只从 config 的**单一渠道块**各调一次 `init_telegram/slack/whatsapp/zulip/ipc`：`init_slack`（`manager.cr:141-155`）传一个 `config.bot_token/app_token`；`init_zulip`（`manager.cr:168-179`）一组 `site/email/api_key`；`init_whatsapp`（`manager.cr:157-166`）一个 `bridge_url`。
- 生命周期：`start`（`manager.cr:49-61`）spawn 一个 `"outbound-dispatcher"` fiber 消费出站事件，并为每渠道 spawn 独立 `"channel-#{name}"` fiber 跑其 `start`（内部各自做重连循环）。
- 出站路由 `dispatch`（`manager.cr:187-200`）按 `event.channel` **类型名**找唯一实例调 `send_message/turn_ended`——即使消息带账号信息也没有第二实例可路由。

### 2.3 四个外部渠道逐一核对（凭据 / 连接生命周期 / 收发路径）

| 渠道 | 凭据（单套） | 连接生命周期 | 接收→发送路径 |
|---|---|---|---|
| Telegram（`channels/telegram.cr:295`） | 单 bot `token`（`telegram.cr:323-337` initialize） | **长轮询 getUpdates**（`telegram.cr:353-367,582`）；getMe 重试 5 次（`telegram.cr:339-340,372-385`）；轮询退避 2s→60s（`telegram.cr:342-343`）；429 感知 `ApiError#retry_after`（`telegram.cr:345-351`） | 收：poll fiber→handle_message→bus；发：`send_message`（`telegram.cr:401-419`）Markdown→Telegram HTML、4096 字符分片、媒体 multipart；typing 指示器 `telegram.cr:421-422,1214-1226` |
| Slack（`channels/slack.cr`） | 单 `bot_token`+`app_token`（`slack.cr:29-39`） | **Socket Mode WebSocket**，`start`（`slack.cr:41-64`）内 RetryBackoff 5s→60s 无限重连；`auth.test` 解析 bot 身份（`slack.cr:102-115`） | 发：`chat.postMessage`+thread_ts+Mrkdwn 转换（`slack.cr:70-100`）；**媒体发送不支持**（`slack.cr:71-73` 只发文本） |
| WhatsApp（`channels/whatsapp.cr`） | 无原生凭据，连 **Node.js baileys 桥**（`whatsapp.cr:7-9`），单 `bridge_url` 默认 `ws://localhost:3001`（`whatsapp.cr:18-32`）；QR 登录在桥侧终端 | `start`（`whatsapp.cr:34-56`）连桥 WebSocket，断线 5s 重连（`whatsapp.cr:21,43-56`） | 收：桥 JSON→handle_message；发：`send_message` **是空存根**——未连接仅 warn，已连接也只 log（`whatsapp.cr:63-70`），外发未实现 |
| Zulip（`channels/zulip.cr`） | 单 `site/email/api_key`（`zulip.cr:24-33`） | **长轮询事件队列**：register_queue 拿 queue_id+协商 90s longpoll（`zulip.cr:44-60,112-120`）；`Crest::RequestFailed` 或异常→置空 queue_id 强制重注册+5s 退避（`zulip.cr:51-58`） | 发：`Crest.post /api/v1/messages` 私信（`zulip.cr:77-100`）；媒体不支持仅文本（`zulip.cr:78-80`） |
| IPC（`channels/ipc.cr`，TUI/stdio 通道） | 无凭据；transport=unix socket/loopback tcp/stdio（`gateway.cr:102-143`） | transport 由 gateway 自己的 fiber 承载，`IpcChannel.start` 无连接动作（`ipc.cr:19-24`） | 发：`server.deliver_assistant/deliver_turn_ended`（`ipc.cr:31-37`）；工具进度由 `Ipc::Tracer` 直推不经过 bus（`ipc.cr:8-9`） |

### 2.4 单账号假设的三层证据链（config → manager → instance）

1. schema：`ChannelsConfig` 每类型一个可选单槽位 `TelegramConfig?` / `SlackConfig?` / …（`src/autobot/config/schema.cr:151-161`）。
2. manager：`Hash(String, Channel)` 按类型名存（`manager.cr:25`），init 只调一次（`manager.cr:104-112`）。
3. 实例：每类 Channel 构造函数只接受一套凭据（上表）。

结论：**「多账号」不是加配置能解决的——类型名即路由键，第二账号必然覆盖第一账号。** 新平台必须把路由键改为 `(account_id, channel_type)` 二元组，配置改为数组结构（见 §10）。

---

## 3. Provider 抽象与 LLM 调用方式（Focus 3）

- 抽象：`src/autobot/providers/provider.cr:14-33`——`abstract class Provider`，`getter api_key/api_base`，核心方法 `abstract def chat(messages, tools, model, max_tokens, temperature, session_key) : Response`，`abstract def default_model`。**一个实例一套 api_key = LLM 侧的单账号假设**。
- 规格表：`src/autobot/providers/registry.cr:5-66` 的 `ProviderSpec` record
  （name/keywords/api_url/auth_header/model_prefix/gateway?/local?/use_max_completion_tokens/
  user_agent/supports_system_role/supports_prompt_cache_key…）。
  `registry.cr:69-182` 是 `PROVIDERS` **编译期常量数组**，逐项定义：
  openrouter（prompt cache key）、aihubmix（gateway）、anthropic（x-api-key）、
  openai（新模型用 max_completion_tokens）、deepseek、gemini（走 OpenAI 兼容 URL）、
  kimi（sk-kimi- 前缀 + UA 伪装 KimiCLI/0.77）、moonshot、minimax、groq、bedrock、
  duckai（不支持 system role）、vllm（local）。
  `find_by_model`（`registry.cr:185-191`）按模型串关键词选规格。
- 主实现：`src/autobot/providers/http_provider.cr:16-87`——OpenAI 兼容 chat completions +
  Anthropic Messages API 自动格式转换（`http_provider.cr:15,78-82`）。
  超时 connect 30s / read 300s（`http_provider.cr:19-20`）；重试 3 次、429 与 5xx 触发
  （`http_provider.cr:24-28`）；finish_reason 双向映射（`http_provider.cr:30-42`）。
  **异常兜底**：`rescue ex` 后返回
  `Response.new(content: "Error calling LLM: ...", finish_reason: "error")`
  （`http_provider.cr:83-87`），不向上炸。
- 特化实现：`gemini_provider`（OAuth refresh token，装配见 `setup_helper.cr:57-89`）、`bedrock_provider`（AWS keys+guardrail）。**未逐行读，见未验证清单。**
- 选择逻辑：`schema.cr:498-520` `match_provider` 用 `{% for %}` 宏按 `model` 字符串匹配十个具名 provider 槽；`schema.cr:523-531` match_bedrock。
- 装配：`setup_helper.cr:57-89` 整个 gateway 只 **new 一个 provider**；HttpProvider 按 provider_name/api_key 查 gateway 规格（`http_provider.cr:58-59`）。
- prompt cache：openrouter 透传 `session_key` 作 cache key（`registry.cr` supports_prompt_cache_key + `http_provider.cr:97` apply_prompt_cache_key）。

对新平台的启示：Provider 抽象与规格表**模型无关、与账号数无关，可直接搬**；但「单实例装配」必须改成 provider 实例池（账号/会话可绑定不同 provider）。

---

## 4. 会话与记忆持久化（Focus 4）

**没有 SQLite。** 会话是 JSONL 文件，记忆是两个 Markdown 文件，cron 是 JSON 文件。（`plugins/builtin` 里的 sqlite 只是给 agent 用的查询工具，非平台存储，`setup_helper.cr:253-260`。）

### 4.1 Session（JSONL）

- 目录：`workspace/sessions/`（`src/autobot/session/manager.cr:21-22`）。
- 文件名：`safe_filename(key.gsub(":","_")) + ".jsonl"`（`manager.cr:82-85`）——即会话键直接映射文件名。
- 格式：首行 `_type=metadata` 的 Metadata JSON + 逐条消息 JSONL（`manager.cr:39-66`；`src/autobot/session/session.cr:20-31,7-17`）。消息结构 `Message{role, content, timestamp, tools_used?}`（`session.cr:7-17`）。
- 权限：`File.chmod` 文件 0o600、目录 0o700（`manager.cr:39-66`）。
- 进 LLM 上下文的窗口：`Session::DEFAULT_MAX_HISTORY = 25`（`session.cr:35`），`get_history` 取尾部窗口并对齐裁剪步长（`session.cr:65-81`）。
- 并发：内存 cache + 磁盘变更检测重载（`manager.cr:27-36`），`merge_disk_changes`（`manager.cr:101-107`）支持另一个进程（如 CLI）写入后合并——**已有的朴素多进程协调**。

### 4.2 Memory（双层 Markdown）

- `workspace/memory/MEMORY.md`（长期事实，整写替换）+ `HISTORY.md`（grep 可查追加日志）（`src/autobot/agent/memory.cr:9-36`）。
- 巩固：`src/autobot/agent/memory_manager.cr:57-78`——会话消息数超 `memory_window`（默认 50，`schema.cr:163-174`）时同步 trim 会话，并 **spawn 后台 fiber** 用同一 provider 让 LLM 产出 JSON `{history_entry, memory_update}`（`memory_manager.cr:75-77,107-123`），`apply_result` 写回文件（`memory_manager.cr:160-170`）。注意：**记忆巩固调用与用户 turn 共用同一个全局 provider 实例**。

### 4.3 cron 存储

- JSON 文件，默认 `./cron.json`（`schema.cr:363-371`；`cron/service.cr:34-49`），60s 重载检查（`service.cr:16-22`）。

文件布局总结：`config.yml`（+同目录 `.env`）→ `workspace/`（`sessions/*.jsonl`、`memory/MEMORY.md|HISTORY.md`、`skills/`、`inbox`）→ `data_dir`（history、内置 skills 等，`loader.cr:60-77`）。

---

## 5. 事件总线结构与队列语义（Focus 5）

`src/autobot/bus/queue.cr`：

- 两条 **buffered Channel**：`@inbound = Channel(InboundMessage).new(capacity)`、`@outbound = Channel(OutboundEvent).new(capacity)`，capacity 默认 **100**（`queue.cr:12-15`）。
- **有界，背压=阻塞**：Crystal buffered Channel 满时 `send` 阻塞生产者 fiber（协作式背压），没有丢弃、降级或超时策略——入站洪峰时会一路堵回渠道 fiber。
- 消费 `consume_inbound`（`queue.cr:26-51`）：spawn 消费 fiber，`select` 同时挂 `@inbound.receive` 与 `timeout(5.seconds)`，靠 timeout 周期检查 `@stopped` 实现可停机——**这是 Crystal `select` 的标准用法**。
- 出站 `publish_outbound`（`queue.cr:54-59`）、`publish_turn_ended`（`queue.cr:61-66`，发 `TurnEnded` 事件）、`consume_outbound`（`queue.cr:69-94`，由 manager 的 outbound-dispatcher fiber 消费）、`drain_outbound` 非阻塞排空（`queue.cr:97-106`）、`stop` close 两条 Channel（`queue.cr:109-116`）。
- 事件类型：`events.cr:95-122`——`OutboundMessage{channel,chat_id,content,media?,reply_context}` 与 `record TurnEnded(channel, chat_id, reason)`，`alias OutboundEvent = OutboundMessage | TurnEnded`，分发用 `case event.in`（`manager.cr:194-197`）——**union alias + case/in 是本库最典型的 Crystal 类型分派用法**。

结构评价：单总线+单消费者是**全局串行的根因**。多账号平台可保留「有界 Channel + select」模式，但需要 per-account/per-session 队列或带账号字段的路由层，否则容量 100 会被所有账号共享挤占。

---

## 6. 配置系统：账号凭据怎么存（Focus 6）

- 加载优先级：`--config` 路径 → `./config.yml` → 空默认 `Config.from_yaml("{}")`（`src/autobot/config/loader.cr:5-8,29,136-150`）。
- **凭据存明文 YAML + `.env`**：`load_env_file`（`loader.cr:109-133`）把 config 同目录 `.env` 灌入 ENV；YAML 值支持 `${VAR}`/`$VAR` 展开（`loader.cr:152-159,170-182`）——secret 可以外置到 .env，但 config.yml 本身也常直接写 token。`Loader.save` chmod 0o600/0o700（`loader.cr:44-57`）。
- 渠道凭据结构（每类型**单套**，schema.cr 见 §2.4 表）：
  - Telegram：`token`（`schema.cr:4-15`）；
  - Slack：`bot_token`+`app_token`（`schema.cr:88-101`）；
  - WhatsApp：`bridge_url`（`schema.cr:113-121`）；
  - Zulip：`site/email/api_key`（`schema.cr:123-133`）。
- Provider 凭据：`ProviderConfig{api_key, api_base?, extra_headers?, client_id?, client_secret?, refresh_token?}`（`schema.cr:184-200`），**十个具名单槽位** anthropic/openai/openrouter/deepseek/groq/gemini/kimi/vllm/duckai/bedrock（`schema.cr:220-235`）；`configured?` 检查残留 `${`（`schema.cr:196-199` 附近）。
- `auth` 子命令：**仅支持 gemini**（`src/autobot/cli/auth.cr:42-53`）——Google OAuth PKCE，起临时 `HTTP::Server` 绑 `127.0.0.1:8085` 收回调（`auth.cr:24,71-99`），用 `Channel(String)`+`select timeout(5.minutes)` 等结果（`auth.cr:69,102-108`）。token 写回 config 的细节未逐行验证（见清单）。
- workspace 路径相对 config 目录解析（`schema.cr:455-465`）。

对新平台的启示：凭据模型需从「类型单槽」改为「账号数组 + 每账号一套凭据」，并考虑 keyring/OS 凭据库而不是明文 YAML（autobot 已有 0o600 权限意识但仍是明文）。

---

## 7. 插件机制细节（Focus 7）

- 接口：`src/autobot/plugins/plugin.cr:40-78`——`abstract class Plugin`：`name`（snake_case id）/`description`/`version` 必须实现，可选 `required_executable`（外部 CLI 依赖，如 sqlite3/gh，`plugin.cr:50-54`）、`setup(context)`（注册工具）、`start`（起后台 fiber）、`stop`（清理）。
- 注入：`PluginContext`（`plugin.cr:84-97`）暴露 `config / tool_registry / workspace / sandbox_executor` 四件——插件拿 registry 注册工具，拿 sandbox 执行命令。
- 注册：`Plugins::Loader.register`（`plugins/loader.cr:8-12` 注释），但实践上**只有编译期内置清单**：`setup_helper.cr:253-260` `BUILTIN_PLUGINS`（sqlite/github/weather/system_info/text_to_speech/chat_log），`setup_helper.cr:262-271` 按 config 开关逐个 register。**新增插件=改 setup_helper 源码+重编译**，无动态加载、无第三方 shard 装载路径。
- 工具注册：`src/autobot/tools/registry.cr:26-36` `register` 经 Allowlist（tools.enabled 模式）过滤；`definitions`（`registry.cr:59-64`）输出 OpenAI/Anthropic function calling schema；`execute`（`registry.cr:75-123`）做 rate limit（按 session_key）、参数校验、`LogSanitizer.redact_credentials` 脱敏（`registry.cr:115`）、rescue 全量兜底返回 `ToolResult.error`。
- Skills（轻量替代扩展位）：`src/autobot/agent/skills.cr:43-80`——`skills/<name>/SKILL.md` 目录发现，workspace 覆盖 builtin；frontmatter 元数据（description/always/tool/params/requires_bins/requires_env，`skills.cr:14-35`）。**这是唯一不需重编译的能力扩展面**，值得新平台放大成插件主通道。

---

## 8. Subagent 机制（Focus 8）

`src/autobot/agent/subagent.cr`：

- spawn 入口：`SubagentManager.spawn`（`subagent.cr:68-89`）生成 8 位 UUID id，`subagent.cr:83-85` `::spawn do run_and_untrack(...)`——**每个任务一个 fiber，无并发上限**（`@running_tasks` Hash+Mutex `subagent.cr:44-45,92-96` 只登记不限额）。
- 执行：`run_subagent`（`subagent.cr:111-163`）自建 `Tools.create_subagent_registry`（剔除 message/spawn 等社交工具）+ 独立 ToolExecutor，MAX_ITERATIONS=15（`subagent.cr:25`）。**LLM 回合是真并行**（各自 fiber 直接调 provider，不经主 Loop）。
- 汇报：`announce_result`（`subagent.cr:172-202`）把结果 `bus.publish_inbound`（channel=system、sender_id="subagent"、chat_id="origin_channel:origin_chat_id"）→ 主 Loop `process_subagent_message`（`loop.cr:362-389`）带原会话历史执行并入串。
- 提示词约束（`subagent.cr:204-233`）：不得发消息、不得再生 subagent、不读主历史。

新平台注意：subagent 是现成的「并行 LLM 回合」先例——但它复用全局 provider 单例与全局工具沙箱配置；且无上限并发在多账号场景下会放大成资源失控，需要信号量/工作池。

---

## 9. Crystal 语言特性的实证用法（Focus 9，为「贴合 Crystal 特点」提供依据）

以下均为本仓库真实用例（非理论）：

1. **fiber + spawn**：`gateway.cr:76` `spawn(name: "agent-loop")`（命名 fiber 便于日志）；`manager.cr:49-61` 每渠道一个 `"channel-#{name}"` fiber + dispatcher fiber；`subagent.cr:83` 每任务一 fiber；`auth.cr:99` `spawn { server.listen }`；`memory_manager.cr:75-77` 巩固放后台 fiber。Crystal 的并发原语就是 fiber——**单进程内多账号多连接天然用 fiber-per-account 表达**。
2. **buffered Channel 即有界队列**：`queue.cr:12-15` capacity=100；`auth.cr:69` `Channel(String)` 做一次性结果传递。背压=send 阻塞，无需锁。
3. **select + timeout**：`queue.cr:32-43`（消费循环可停机）、`auth.cr:102-108`（等 OAuth 回调超时 5 分钟）。
4. **编译期宏**：`gateway.cr:70-73` `{% unless flag?(:win32) %}` 平台剔除信号处理；`http.cr:36` `{% if !flag?(:without_openssl) %}`；`schema.cr:506-517,537-542,562-565` `{% for provider_name in %w[...] %}` + `p.{{ provider_name.id }}` 批量生成 provider 匹配/校验方法——**配置 schema 用宏消灭手写重复**，多账号平台的样板配置代码同理可用宏生成。
5. **record 类型**：`events.cr:116-122` `record TurnEnded(channel, chat_id, reason)`；`tool_executor.cr:35-61` Result record（带 finish_reason 常量）；`skills.cr:14` `record SkillParam`。值语义+自动构造器，适合事件/DTO。
6. **union alias + case/in 分派**：`events.cr:122` `alias OutboundEvent = OutboundMessage | TurnEnded`，`manager.cr:194-197` `case event.in` 穷举处理——无 visitor、无接口膨胀。
7. **abstract class**：`base.cr:19` Channel、`provider.cr:14` Provider、`plugin.cr:40` Plugin、`tool_executor.cr:30-33` Observer——库内统一用 abstract class 而非 module/interface 做扩展点。
8. **Mutex**：`subagent.cr:44-45`（任务表）。仅共享可变状态处用，队列流转处全靠 Channel 免锁。
9. **typed rescue**：`loader.cr:160` `rescue ex : YAML::ParseException`；`zulip.cr:51` `rescue ex : Crest::RequestFailed`；`telegram.cr:345-351` 自定义 `ApiError < Exception` 携 `retry_after` 结构化限流信息；`http_provider.cr:83-87` 顶层 rescue 兜底转错误 Response；`registry.cr:75-123` 工具执行 rescue 转 `ToolResult.error`。**「失败不炸进程、转为数据」是本库的错误处理风格。**
10. **JSON::Serializable + @[JSON::Field]**：`session.cr:8,23`（`_type` 键改名）——持久化 DTO 标配。
11. **Log = ::Log.for(...)**：全库统一（`slack.cr:19`、`plugin.cr:6` 等）——结构化日志开箱即用。
12. **常量文化**：每文件顶 `CONSTANT = value`（`telegram.cr:339-343`、`whatsapp.cr:21-22`、`subagent.cr:25`、`http_provider.cr:19-28`）——行为参数显式化，便于审计。
13. **Time::Span 字面量**：`5.seconds`/`300.seconds`/`5.minutes` 遍布超时/退避参数。
14. **无限重连循环模式**：`@running` flag + `while @running; begin ... rescue; sleep(n); end`（`zulip.cr:44-60`、`whatsapp.cr:43-56`、`slack.cr:41-64` RetryBackoff 5s→60s）——渠道连接生命周期的惯用写法。

对设计的直接启示：新平台的「多账号」= 每账号一组 fiber（连接器+可选 loop），账号间通信统一走 Channel 总线而非共享状态；扩展点用 abstract class；配置样板用宏；错误一律转值不炸进程。

---

## 10. 结论清单：可复用 / 需重新设计（Focus 10）

### A. 可直接复用（搬设计不搬代码，或按接口重写）

| # | 部件 | 证据 | 说明 |
|---|---|---|---|
| A1 | Provider 抽象 + ProviderSpec 规格表 | `providers/provider.cr:14-33`；`providers/registry.cr:5-66,69-182` | 与账号数正交；新平台改成实例池即可服务多账号多模型 |
| A2 | HttpProvider 双格式适配（OpenAI 兼容 + Anthropic 转换）+ 重试/限流/错误兜底 | `providers/http_provider.cr:16-87`（超时 19-20、重试 24-28、映射 30-42、兜底 83-87） | 直接可搬的 LLM 网关内核 |
| A3 | 有界 Channel 总线模式（buffered Channel + select/timeout + union 事件） | `bus/queue.cr:12-15,26-51,61-66`；`bus/events.cr:95-122` | 模式可复用；见 B3 的架构级改造 |
| A4 | Session JSONL 持久化（Metadata 首行、0o600、多进程 merge） | `session/manager.cr:39-66,82-85,101-107`；`session/session.cr:7-31` | 文件即会话，运维友好；key 需加账号维度（B4） |
| A5 | Memory 双层文件 + LLM 巩固流程 | `agent/memory.cr:9-36`；`agent/memory_manager.cr:57-78,107-123` | 机制与账号无关；注意巩固共用 provider 实例 |
| A6 | ReAct ToolExecutor + Observer 进度钩子 | `agent/tool_executor.cr:99-128,30-33`（迭代上限、20k 截断、迭代间 interrupt） | 可独立于总线复用；TUI 经 Observer 获得进度 |
| A7 | SKILL.md 技能机制（frontmatter 元数据、workspace 覆盖 builtin） | `agent/skills.cr:14-35,43-80` | 免重编译扩展面，新平台应升格为主要扩展通道 |
| A8 | 渠道 Markdown 转换器（Telegram HTML 4096 分片 / Slack Mrkdwn） | `channels/telegram.cr:13-283`（convert/split_message）；`channels/slack.cr:70-100` | 纯函数、与账号无关，价值密度高 |
| A9 | 工具注册表骨架（Allowlist、限流按 session_key、脱敏、异常兜底） | `tools/registry.cr:26-36,59-64,75-123` | 骨架可搬；session_key 需含账号 |
| A10 | cron 三态调度（At/Every/Cron 表达式）+ owner 概念 | `cron/types.cr:12-22,51-69,127-154`；`cron/service.cr:63-70` | owner 需扩账号维度（B7）；单 fiber 定时器循环可整体保留 |

### B. 单账号 / 单 Loop 假设——新平台必须重新设计

| # | 假设 | 证据 | 新平台方向 |
|---|---|---|---|
| B1 | 配置层单账号：每渠道类型一个凭据槽位 | `config/schema.cr:151-161`（`XConfig?` 单槽）；`schema.cr:220-235`（providers 十个具名单槽） | 改 `accounts: Array[AccountConfig]`，每账号带 type+credentials+allow_from |
| B2 | Manager 层单账号：按类型名 Hash 路由 | `channels/manager.cr:25,104-112,187-200` | 路由键改 `(account_id, channel_type)`；出站事件需带 account_id |
| B3 | 单 Loop 全局串行：一个慢 turn 阻塞所有会话（含 cron/subagent 汇报） | `gateway.cr:76`；`loop.cr:122-152` | per-session/per-account worker pool 或多 Loop；队列按会话分片防饿死 |
| B4 | 会话键无账号维度，跨账号可撞车 | `bus/events.cr:29-31`；`loop.cr:199` | key 改 `account:channel:chat_id`，存储文件名随之 |
| B5 | 全局单套工具实例 + 上下文切换（loop 写 channel/chat_id 进工具再执行） | `loop.cr:464-469` update_tool_contexts | 工具按会话实例化或显式传 ToolContext，消除隐式全局态 |
| B6 | 插件编译期内置，新增需改码重编译 | `setup_helper.cr:253-271`；`plugins/loader.cr:8-12` | 动态注册（配置/shard 装载），或放大 SKILL.md 通道（A7） |
| B7 | cron owner 无账号维度；cron turn 复用全局串行 Loop | `cron/types.cr:8-10`；`gateway.cr:163-195`；`loop.cr:307-350` | owner 加账号；cron 投递进对应账号的队列 |
| B8 | subagent 并行无上限（fiber 每任务+零信号量） | `subagent.cr:83-85,44-45` | 并发信号量/池；结果汇报不再依赖全局单 Loop |
| B9 | 无管理面：`-p PORT` 只打印；无 HTTP API/TUI 之外的编排入口 | `commands.cr:220,28`；`gateway.cr:32`；`schema.cr:237-244`（GatewayConfig 未消费） | 新平台的编排（流程/账号管理）需要真实 API 层，autobot 无可搬者 |
| B10 | 凭据明文 YAML/.env（仅 chmod 0o600） | `config/loader.cr:44-57,109-133,170-182` | 账号多了以后引入 OS keyring 或加密存储 |
| B11 | `autobot agent` CLI 单轮直调（旁路 Loop） | `cli/agent.cr:17-29,120-178` | 可保留为调试通道，但不可作编排执行路径 |
| B12 | WhatsApp 外发空存根（收到能转、发不出去） | `channels/whatsapp.cr:63-70` | 新平台做 WhatsApp 需补双向链路，勿照抄 |

---

## 未验证清单（诚实边界）

1. `cli/auth.cr:121+`：Gemini token 交换后写回 config 的具体字段/方式未逐行读。
2. `tools/spawn.cr`（subagent 的工具侧定义）未细读；仅从 `loop.cr:464-469` 知其接收上下文注入。
3. `ipc/server.cr` 协议帧格式与 `tui/` 目录未读；仅读 `channels/ipc.cr` 与 `gateway.cr:102-143` 装配。
4. `providers/gemini_provider.cr`、`providers/bedrock_provider.cr`、`providers/types.cr` 未逐行读（Response/FinishReason 结构经 `tool_executor.cr:35-61` 间接确认）。
5. `channels/telegram_media.cr` 媒体收发细节未读。
6. 未运行 `crystal spec`/`./bin/ameba`/`make release`——本轮只读任务，静态结论不覆盖运行时行为（如队列满时的实际阻塞表现）。
7. `shard.yml` 依赖清单未读（Zulip 用 Crest 已从代码确认，其余依赖未盘点）。

## 附：本笔记引用的关键文件地图

```
src/autobot/
  cli/gateway.cr          装配根（20-52 装配顺序、76 唯一 agent-loop spawn）
  agent/loop.cr           主循环（122-152 串行消费、178-185 cron_message、362-389 subagent 汇入、464-469 工具上下文注入）
  agent/tool_executor.cr  ReAct 执行器（99-128）
  agent/subagent.cr       并行子代理（83-85 无上限 spawn）
  agent/memory.cr         MEMORY.md/HISTORY.md
  agent/memory_manager.cr LLM 巩固（57-78）
  agent/skills.cr         SKILL.md 发现（43-80）
  bus/queue.cr            有界 Channel 总线（12-15 capacity=100）
  bus/events.cr           事件类型（29-31 session_key、116-122 union alias）
  channels/base.cr        abstract Channel（19-25、75-97）
  channels/manager.cr     渠道管理（25 类型名 Hash、104-112 单账号 init、187-200 出站路由）
  channels/{telegram,slack,whatsapp,zulip,ipc}.cr
  providers/provider.cr   abstract Provider（14-33）
  providers/registry.cr   ProviderSpec 规格表（69-182）
  providers/http_provider.cr OpenAI/Anthropic 双格式（16-87）
  plugins/plugin.cr       abstract Plugin（40-97）
  plugins/loader.cr       编译期注册（8-12）
  session/{session,manager}.cr JSONL 持久化
  cron/{types,service,formatter}.cr
  config/{schema,loader}.cr
  cli/{commands,agent,auth,setup_helper}.cr
  http.cr                 HTTP 客户端与代理补丁（非服务端）
  constants.cr            渠道名常量（11-17）
```
