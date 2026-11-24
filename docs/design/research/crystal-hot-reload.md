# Crystal 配置热更新（免重启重载）调研

- 调研人：翰林院编修（hanlin-bianxiu-6），受首辅分派
- 日期：2026-11-18
- 目的：为 Crystal 多账号可编排 Personal Agent 平台把「配置热更新」做成一等公民提供技术事实与可行性结论；直接喂给设计文档增补。
- 结论纪律：每条结论锚定源码行号 / 官方文档 / issue / PR；无法核验的列入第 9 节「未验证清单」。

---

## 0. 结论速览（推荐路线）

**推荐路线一句话**：配置对象做成不可变快照，用文件监听（naqvis/file_watcher，Windows 走
ReadDirectoryChangesW）+ POSIX SIGHUP / Windows 复用 autobot 现成 IPC 管理命令双通道触发
「读盘 → 展开环境变量 → YAML 解析 → schema 校验 → 成功才 Atomic 整根换引用，失败保留旧配置并报警」
的先验后换管线；所有消费方统一「每 turn 开头取一次配置快照」，组件级热换按第 6 节矩阵分层执行
（路由/编排/限流/凭据热换，账号增删走监督体管理的 fiber 启停）。

该路线的每个环节都有已验证先例：

| 环节 | 先例 |
|---|---|
| 先验后换 | autobot cron `reload_if_changed`（`cron/service.cr:275-290`） |
| 文件监听 | OpenClaw `gateway.reload`（watch active config path） |
| IPC 触发 | autobot `Ipc::Server`（`cli/gateway.cr:102-143`） |
| 整根换引用 | Crystal `Atomic(T)` 支持 reference type |
| 优雅交接语义 | nginx SIGHUP master/worker 模型 |

设计文档应把「热更新」拆成四个正交件：**触发（watch/signal/IPC）→ 解析校验（先验后换）→
换引用（Atomic/快照）→ 组件重应用（矩阵分派）**，每件独立演进。

---

## 1. Q1 — autobot 本地仓库免重启重载先例

autobot（工作区根目录，Crystal）有 **两套** 免重启重载机制 + 一个现成的管理通道；**config.yml 无任何热重载**（预期成立，验证完成）。

### 1.1 cron.json：60 秒 mtime 轮询 + 先验后换

- 机制：`src/autobot/cron/service.cr:16` `RELOAD_CHECK_INTERVAL = 60.seconds`；`:63-70` `start` 加载 store 后 `start_reload_checker`；`:386-398` `start_reload_checker` spawn 循环：`while @running; sleep 60s; reload_if_changed; arm_timer`。`:367-368` `on_timer` 触发前也先 `reload_if_changed`。
- 换引用：`:275-290` `reload_if_changed` 用 `File.info(@store_path).modification_time` 对比 `@store_mtime`，变了才 `CronStore.from_json(File.read(...))` **整根替换**。
- **先验后换先例（关键）**：同方法 rescue 分支 `Log.warn "Failed to reload cron store"` 并返回 false，**解析失败保留旧 store**，不崩溃。
- 写侧同步：`:292-305` `save_store` 写盘后更新 `@store_mtime`，避免自己写盘触发重载。
- 局限：60 秒延迟；mtime 粒度（同秒内两次修改可能漏检——mtime 不变则跳过）；仅覆盖 cron.json 一处。

### 1.2 session：内存 cache + mtime/size 双指标惰性检测 + 磁盘合并

- `src/autobot/session/manager.cr:9-13` `FileState(modification_at, size)` 双指标（比 cron 的单 mtime 更稳，规避同秒同 size 之外的大部分漏检）。
- `:27-36` `get_or_create` 惰性：cache 命中且 `!changed_on_disk?` 才返回内存副本，否则重新 load。
- `:91-93` `changed_on_disk?` = `FileState.of(path) != @tracked[key?]`。
- `:101-107` `merge_disk_changes`：记 `base_count`（上次跟踪的消息数），若内存被截断（clear/trim）则磁盘胜出；否则 `disk_session.messages + session.messages[base_count..]` 拼接。`:39-66` `save` 前也先 `merge_disk_changes` 防覆盖他进程写入。
- 局限：**惰性检测**（只在读/写该 session 时触发），非事件驱动；合并策略是消息序列拼接，属领域特定逻辑，不是通用配置合并。

### 1.3 config.yml：无热重载（验证完成）

- `src/autobot/cli/gateway.cr:20` 启动时 `Config::Loader.load(config_path)` 一次，此后无任何 reload 调用（全仓 grep 复核）。
- `src/autobot/config/loader.cr:152-166` `load_from_file` 链 = `File.read → expand_env_vars（${VAR}/$VAR 正则，:170-182）→ Config.from_yaml → config.validate!`，YAML 解析失败直接 raise（启动 fail-fast，运行时无兜底）。
- `:17-31` `load` 还含 `load_env_file`（.env 逐行 KEY=VALUE 剥引号进 ENV）；`:44-57` `save` 供 auth CLI 写回 config——写通道存在但运行进程不感知。
- `src/autobot/channels/manager.cr:125,144` 渠道行为（custom_cmds/dm）也从同一启动时 Config 取，即渠道配置同为进程生命周期内固定。

### 1.4 现成管理通道：IPC（Windows 热触发的基础设施）

- `src/autobot/cli/gateway.cr:102-143` `start_ipc`：`Ipc::Server`，unix socket 或 loopback TCP；**Windows 默认 loopback TCP**（附 discovery 文件），`:130` `spawn(name: "ipc-server")`。
- 这是现成的「不发信号、不走文件也能触发重载」的通道——新平台的 reload 触发可直接挂在 IPC 命令面。
- `:67-69` 源码注释印证 Crystal 信号限制：「Crystal cannot install signal handlers on Windows (trap raises NotImplementedError)」；`:70-73` `{% unless flag?(:win32) %}` 编译期分支包住 `Signal::INT.trap / Signal::TERM.trap`。

**对本平台可行性结论**：autobot 已示范「mtime 轮询 + 先验后换 + 整根替换」三件套，缺的是（a）事件驱动的 watch，（b）覆盖 config.yml，（c）组件重应用分派。三者分别由 Q2/Q5/Q6 补齐。

---

## 2. Q2 — Crystal 文件变更监听（FS watch）

目标：Windows 优先 + Linux 次之，监听不可靠时轮询兜底。

| shard | 后端 / 平台 | 状态与来源 | 评价 |
|---|---|---|---|
| **naqvis/file_watcher** | macOS kqueue / Linux inotify / **Windows ReadDirectoryChangesW** / 其他或初始化失败→**snapshot polling 兜底** | shards.info 收录，github.com/naqvis/file_watcher | **首选**。跨平台三原生后端 + 自动降级轮询，与我们「Windows 优先」完全对齐；原生后端 ~10ms 周期 drain OS 队列；API 极小（`FileWatcher::Watcher` add paths → event stream） |
| bcardiff/crystal-fswatch | libfswatch C 绑定 | crystalshards.org，master 分支，2026-01-28 收录 | 备选。功能全（libfswatch 本身跨平台含 Windows），但需装 C 库 + crystal_lib 生成，Windows 构建链复杂；绑定层引入构建面 |
| shpeckman/crystal-inotify | Linux inotify（kernel ≥2.6.13） | 需 Crystal ≥1.21.0 | 仅 Linux，fiber-based 无忙轮询，可作 Linux 深度优化项 |
| OrelSokolov/fswatch.cr | 纯 Crystal：Linux inotify / *BSD kqueue(experimental) / Poll fallback（默认 1s snapshot diff） | shard 页平台表未列 Windows | Windows 只能走其 Poll 分支；纯 Crystal 无 C 依赖是优点 |
| jbox-web/watch.cr (~>>0.1) | inotify/FSEvents/其余 polling | shards.info | path filter + event coalescing + 自动后端兜底；小而完整 |
| agatan/watchbird | inotify 绑定 | shards.info 标「over 7 years ago」未更新 | **判死**，不采用 |

**对本平台结论**：主路用 file_watcher（Windows ReadDirectoryChangesW 原生 + 失败自动轮询，
单 shard 覆盖两目标平台）；**同时必须保留 autobot cron 式 mtime(+size) 轮询作为兜底**
（间隔缩到 1–5s）。理由两条：

1. inotify/ReadDirectoryChangesW 在网络盘、编辑器原子写（rename 替换）、watch 实例数耗尽等场景
   会丢事件，轮询是最后防线。
2. 轮询逻辑 ~20 行、零依赖，已在本仓库 cron 中验证。

触发去抖：watch 事件合并 200–500ms 窗口后再进入「读盘校验」管线，避免编辑器半写状态。

---

## 3. Q3 — 并发安全换引用

### 3.1 Crystal 默认单线程执行（关键事实）

- Crystal 1.21.0（2026-07-16，crystal-lang.org/releases/highlights）：**Execution contexts 默认启用，`-Dpreview_mt` 已废弃**（Invidious 项目报道其 Makefile 已移除该旗标）。
- `Fiber::ExecutionContext` 三类：`Concurrent`（单线程无并行）、`Parallel`（多线程 work-stealing）、`Isolated`（单 fiber 单线程，适合阻塞操作）。
- **默认上下文并行度 = 1**：官方论坛 forum.crystal-lang.org/t/9065 明确「Rescaling the default execution context to a parallelism > 1 is opt-in at the source code level」「no compile-time flag」——即不开 Parallel 上下文，所有 fiber 仍由单线程调度，类变量/ivar 访问天然安全。
- 官方并发指南（crystal-lang.org/reference/1.14/guides/concurrency.html）：「at this moment there's only a single thread executing your code」——fiber 间访问共享变量 fine；引入 MT 后可能 break。
- PR #17097（1.21.0 milestone）：`spawn(same_thread:)` 废弃，官方建议改用 Sync primitives 或并发 context。

### 3.2 Atomic(T) 支持对象引用（可行）

- `Atomic(T)` API（1.11.1 与 1.21.0 一致）：T 为 **reference type**（或仅含 reference + Nil 的 union）时支持 `#compare_and_set / #swap / #set / #lazy_set / #get / #lazy_get` —— **对象引用原子交换可行**。
- 文档歧义说明：`#swap` 详注中有「T cannot contain any reference types」字样，指的是**算术版 swap**；以 reference type 可用方法清单为准（compare_and_set/get 可用即足够）。写入设计文档时注明此歧义，避免实现者被详注吓退。

### 3.3 推荐写法（两条，按需选）

```crystal
# 模式 A：Atomic 换引用（推荐主模式）
CONFIG = Atomic(Config).new(Config.load_initial)

def reload_config(path) : Bool
  new_cfg = Config.load_and_validate(path)   # 先验：读盘→展开→解析→校验，失败抛异常
  CONFIG.set(new_cfg)                        # 后换：整根替换，旧引用自然被 GC
  true
rescue ex
  Log.warn { "config reload rejected, keeping old config: #{ex.message}" }
  false
end

# 消费端：每 turn 开头取快照（模式 B），turn 内不再受重载影响
def handle_turn(msg)
  cfg = CONFIG.get          # 本 turn 的配置快照，语义一致
  route(msg, cfg)
end
```

- 单线程默认下裸 ivar 换引用也安全（§3.1），但按 1.21+ 的执行上下文演进方向（Parallel 源码级 opt-in），配置槽位直接用 `Atomic(Config)` 是面向未来的等价写法，成本≈0。
- **「每 turn 开头取快照」是更重要的纪律**：它让「一次 turn 内配置语义一致」不依赖任何同步原语，且天然兼容 fiber 切换；比「中途换配置导致半新半旧」安全得多。OpenClaw 的「runtime snapshot behavior」同此思路。

---

## 4. Q4 — 信号触发重载（SIGHUP 及 Windows 等价物）

- POSIX 惯用法（nginx 式）：`Signal::HUP.trap { reload_manager.reload }`。Crystal `Signal` enum 为 POSIX 信号集（HUP=1），trap 后信号经 event loop 派发至 signal-safe fiber，**无 C 式异步信号函数调用限制**（API 1.10.1 Signal 文档）——即 trap 回调里可以直接做加载/校验/换引用，这是 Crystal 相对 C 的实现便利。
- autobot 先例：`src/autobot/cli/gateway.cr:70-73` 已用 `{% unless flag?(:win32) %}` 包住 `Signal::INT/TERM.trap`，`:67-69` 注释「Crystal cannot install signal handlers on Windows (trap raises NotImplementedError)」——**Windows 上 Signal trap 直接抛 NotImplementedError，不可用**。
- **Windows 无 SIGHUP，等价物按优先级**：
  1. **IPC 管理命令（推荐）**：autobot 已有 `Ipc::Server`（cli/gateway.cr:102-143，Windows 默认 loopback TCP + discovery 文件）。新增 `reload` 子命令即等价于 `kill -HUP`，且跨平台同一代码路径。
  2. **文件监听触发**：Q2 的 watch 本身就是触发器（OpenClaw 路线），Windows/Linux 通吃。
  3. 补充：POSIX 侧可再加 `SIGUSR2`（Hermes 路线 #48918 用 SIGUSR2 触发 reload，在途）；语义上 HUP=重读配置 是行业惯例（nginx `-s reload`=SIGHUP）。
- 建议双通道并存：文件监听（无人值守自动化）+ IPC `reload` 命令（确定性手动触发），SIGHUP 仅作 POSIX 下的第三便利通道。

---

## 5. Q5 — YAML 深层合并与「先验后换」

- **无可靠现成深合并 shard**：
  - stdlib 明确拒绝：crystal-lang/crystal issue #6791 — `Hash#deep_merge` 被官方拒入 stdlib（建议 shard 解决）。
  - peterhoeg/deep-merge.cr（GitLab 上镜像）：`Hash#deep_merge` monkey-patch，**数组合并 TODO 未实现**，维护度弱。
  - 结论：自写 ~20 行 YAML 层深合并即可（`Hash(String, YAML::Any)` 递归：同名 key 双方均 Hash→递归合并；否则新值覆盖；数组按平台语义定为「整体替换」——与 OpenClaw/hydra 家族惯例一致，且「整体替换」语义可预测，避免半新半旧数组）。
- **「先验后换」落地**（全部件本仓库已有先例）：
  1. 读盘 → `expand_env_vars`（loader.cr:170-182 现成）→ `Config.from_yaml` → `validate!`——正是 loader.cr:152-166 现链，把「启动时调用一次」改为「reload 管线调用」；
  2. 校验通过才 `Atomic.set`（§3.3 模式 A）；
  3. 失败 rescue → **保留旧配置** + `Log.warn`（cron/service.cr:275-290 同款）。
- 注意两点：①`validate!` 需从「启动 fail-fast」强化为「运行时全量校验」（含必填 key、账号引用完整性——Q6 路由 binding 引用的账号必须存在）；②编辑器原子写会产生「半文件」瞬态，reload 管线入口以 §2 的去抖 + 解析失败即弃来吸收。
- dotenv 生态存在（drum445/dotenv ~>0.5.0）可选参考，但 autobot 自带 `load_env_file`（loader.cr:17-31 内联逻辑）已够用，无新增依赖必要。

---

## 6. Q6 — 可热换 vs 必须重启（按本平台架构逐组件）

依据：渠道技术事实（docs/agent-platform-design/research/channels-wecom-lark-email.md，行号已核对）+ Hermes 架构记忆（baa4c689）+ autobot 源码先例。此节为推论题，每条注明依据。

| 组件 | 热换可行性 | 依据与做法 |
|---|---|---|
| **路由 binding（消息→账号/agent 映射）** | ✅ 容易 | 纯数据：换引用即生效（§3 快照模式）。Hermes 的 RoutingIdentity 已示范 transport/runtime profile 解耦（baa4c689）；新配置中 binding 表校验引用完整性后整体替换。 |
| **编排规则（提示词/流程/工具编排）** | ✅ 容易 | 同为纯数据；消费点在「每 turn 开头取快照」，正交接缝（§3.3 模式 B）。OpenClaw hybrid 模式即「多数改动静默热应用」的同类。 |
| **工具 allowlist / 权限** | ✅ 容易 | 纯数据 + turn 边界生效，语义干净。 |
| **限流桶参数（(账号,目标) token bucket，channels 笔记 :205）** | ✅ 容易 | 桶速率/容量可在线调：新参数下个 tick 生效即可，无需迁移状态。 |
| **provider key / 凭据（LLM 侧）** | ✅ 容易 | 新 key 进 Atomic 槽，下一次请求即用新 key；失败回退旧槽可选。Hermes `_CACHE_BUSTING_CONFIG_KEYS`（PR #37880，model.default/model.provider 进 cache-busting）说明此路已有先例。 |
| **渠道凭据（企微/飞书 app_id+secret）** | ✅ 中等 | token ~2h TTL 独立缓存（channels 笔记 :43-44,204），本就是生命周期对象：换 secret 后强制失效旧 access_token、下次取新 token 即切换。多租户=多组 app_id/secret 并存（:93-95），结构上支持热加。 |
| **加/删账号（渠道长连接 fiber 启停）** | ⚠️ 可行但要监督体 | 企微智能机器人长连接 cmd=aibot_msg_callback 免公网入站（:28,51）、飞书 WebSocket 长连接（:81-82）→ **每账号一条长连接 fiber，增删=fiber 创建/优雅停止**。channels 笔记 :206 本就建议「每账号长连接配监督体+断线退避重启」；账号 fiber 天然属于该监督体树，增删账号 = 监督体下 spawn/close，无需重启进程。删除时要先 drain 在途消息（§7 nginx 优雅交接语义）。receiveid 防串号校验（:184,192）保证多账号并存不串号。 |
| **监听端口/协议栈（HTTP webhook 端口等）** | ❌ 必须重启（或平台级交接） | 套接字绑定属于进程资源；单进程内换端口需 close+reopen，期间丢包。nginx 用 master 继承 fd + SO_REUSEPORT 解决，但那是多进程模型——对 Crystal 单进程价值低（§7）。设计上应把「端口类配置」标记为重启项，靠 §0 管线的校验阶段给出明确「此项需重启」提示（OpenClaw hybrid 的 restart 子集）。 |

**结论**：按 channels 笔记 :206 的监督体建议落地后，全部「数据类」配置皆可热换；「结构性」改动（端口/协议栈）标记 restart——恰为 OpenClaw hybrid 语义，见 §7。

---

## 7. Q7 — 业界对照

### 7.1 OpenClaw：reload 是一等公民（正面教材）

- Gateway Runbook（openclawlab.com/en/docs/gateway/，与 openclaws.io 镜像同文）：`gateway.reload.mode` 默认 **hybrid**；reload modes：**hot**（文件改动立即重读）/ **restart**（退出+supervisor 拉起）/ **hybrid**（多数改动静默热应用，结构性改动须重启）/ **off**。
- 机制：「Gateway config reload watches the active config file path (resolved from profile/state defaults, or OPENCLAW_CONFIG_PATH when set)」——**文件监听触发**，与我们 §2 路线同构。
- 运维面：`openclaw gateway status [--deep|--json] / restart / stop`、`openclaw secrets reload`（SecretRef contract + runtime snapshot behavior）。
- 注：docs.openclaw.ai/gateway/ 本体 fetch 只返回导航目录（正文未取到），上述细节来自两镜像搜索快照，正文逐字未验（列入 §9）。

### 7.2 Hermes：确认无热重载（用户痛点根源，反面教材）

四证据链（均为仓库 issue/PR）：
1. issue #48693（2026-06-17，open）：「Gateway config hot-reload — detect config.yaml changes without /restart」——诉求至今未实现；
2. PR #13217（2026-04-19）：CLI 改配置后打印「must restart the gateway」警告；
3. PR #66777（2026-09-03）：dashboard 插件 toggle 仍提示 restart，正文引 #54941 `/reload-plugins` 与 #48918 SIGUSR2 reload 「stay the real fix」在途——说明截至 2026-09 真热重载仍未落地；
4. PR #37880：仅 `model.default/model.provider` 进 `_CACHE_BUSTING_CONFIG_KEYS`（个别 key 的缓存失效，非全量热载）。

### 7.3 nginx / Caddy（非 agent 领域的零停机重载模式）

- nginx 官方（docs.nginx.com「Control NGINX Processes at Runtime」）：`nginx -s reload` = SIGHUP → **master 重读配置 → 用新配置起新 worker → 旧 worker 优雅完成当前请求后退出**。
- **可迁移语义**（单进程 Crystal 版翻译）：①进程不重启、配置整体换新（= §3 Atomic 整根替换）；②「旧 worker 优雅收尾」=「进行中的 turn 用旧配置快照跑完，新 turn 用新配置」（= §3.3 模式 B 的 per-turn 快照，天然实现，无需引用计数）；③分级信号：reload=HUP、reopen 日志=USR1、quit=QUIT——信号语义分家值得照抄到 IPC 命令面（reload/status/quit 分立命令）。
- **SO_REUSEPORT 套接字继承**：属多进程交接模型；我们单进程场景价值低（仅在未来做多进程容错时考虑），不引入。Caddy 的 zero-downtime reload 同为 fork+fd 继承族，同结论。

---

## 8. Q8 — 插件/脚本层：mrb.cr（mruby 绑定）可行性

背景先验修正：lead 先验「mrb.cr 无 Proc/yield/funcall」**已被 task-2 修复推翻**——现 API 齐备、全量 spec 84/0。其余先验（单 State 线程亲和、arena/Ref 显式生命周期、无执行配额、JSON-like 传值）仍有效。

### 8a. 仓库现状（本地 + 记忆链核对）

- 仓库：github.com/ShiningRay/mrb.cr（本地 C:\Users\ShiningRay\projects\ShiningRay\mrb.cr）；issue #1 = https://github.com/ShiningRay/mrb.cr/issues/1。
- Windows 可用性已验证（记忆 26fed42e）：MSYS2 UCRT64 gcc 16.2.0 构建 mruby 4.0.0（831da26），
  `libmruby.a` 4,934,196B（nm 见 `T mrb_init_mrblib`），shim.c 57 个 `mrb_cr_*` 导出，
  链接 Crystal 1.22.1 x86_64-w64-windows-gnu；smoke eval/host/error 全过。
  两个构建坑（Windows 分支硬编码 MSVC 产物名、`MRUBY_CONFIG` 只读目录 .lock EACCES）
  已在 task-2 解决（Makefile 复制 build_config 至可写目录、
  canonical `lib/mrb_shim.o + lib/libmruby.a` 链接路径）。
- API 面（task-2/3/4 修复链 f4d2ccc7→8cded03c→6adcbc15）：

  - `mrb_cr_proc_p/block_given/get_block/yield/funcall` 已补。
  - Crystal 侧 `Args#block/block_given?`、`Value#proc?`、
    `State#create_proc/block_given?/current_block/yield/funcall`、
    `Ref.open_proc/proc`（跨 state 校验）。
  - yield 异常传播已修（`mrb_cr_yield` 在 protect_error 时
    `mrb->exc = mrb_obj_ptr(result); *error=TRUE`，适配 mruby 4.0.0 `mrb_protect_error` 语义）。
  - funcall 补 `mrb_protect`（task-4 唯一 P2 已闭合）；全量 84/0。

  **结论：mrb.cr 已达「可选插件脚本层」的可用度。**

### 8b. 沙箱边界（技术事实）

- **GC arena 显式管理**：mruby GC 不扫 C 栈，C 函数中创建的对象进栈式 arena（include/mruby/gc.h，`MRB_GC_ARENA_SIZE` 默认 100，未定义 `MRB_GC_FIXED_ARENA` 时自动扩展）；`mrb_gc_arena_save/restore/protect` 手动管理防 overflow 与假泄漏（mruby doc/guides/gc-arena-howto.md）。→ Crystal 宿主每批调用外必须包 arena save/restore，否则对象假存活（泄漏）或被误回收。
- **无执行配额（现成）**：`State#eval/funcall/yield` 无超时/指令数限制——插件卡死即卡宿主 fiber；单线程默认调度器下会卡整个进程。→ 必须自建配额：定时器 watchdog + 或 mruby 侧 `mrb_default_allocf` 覆写做内存配额（mruby 3.3 起 `mrb_open_allocf` 弃用，官方改路子），见下。
- **mrbgems 可裁剪**：build_config 定制 gembox，可剔除 `mruby-io`/`mruby-socket` 等（H2O 先例）——**脚本层无文件/网络 IO 能力是沙箱第一道闸**，比运行时拦截便宜且可靠。
- **单 State 线程亲和 + JSON-like 传值**（先验仍有效）：State 只能在创建它的线程用；Crystal↔mruby 只传 JSON-like 值（Ref 持对象/Proc 需显式生命周期）。与 §3 单线程默认调度器兼容；若未来 Parallel 上下文，插件 State 须钉在 Isolated/单一上下文。
- `$SAFE`（mruby 的 Ruby 2.x 兼容安全档）不可依赖：CRuby 2.7 已移除，mruby limitations.md 未逐字核对（§9 未验证项）；**沙箱靠裁剪 gembox + allocf 配额 + 宿主 API 白名单**，不靠语言级 $SAFE。

### 8c. 脚本热重载的现实做法（mruby 无 module unload）

- RiteVM 无模块卸载/重评估隔离；**重载 = `mrb_close` 旧 state → 新建 `mrb_state` → 重新 `mrb_load_string/mrb_load_irep`**（mruby.org/doc/api/file.capi.html：load 系外须包 arena save/restore）。
- 即：**脚本层的「热更新」= 整 VM 实例替换**，与 §3 配置「整根换引用」同构——把每个插件脚本装进独立 mrb_state，重载=重建该插件的 state，宿主引用槽 Atomic 换新 State。插件互不共享堆，天然故障隔离（一个脚本崩溃只 mrb_close 重建该 state）。
- 成本：mrb_state 轻量（对比 JVM/CRuby 解释器实例）；重建 + 重 load 脚本为毫秒级。**与配置层共用「先验后换」**：新脚本先在临时 state 里 load+冒烟（如调用约定好的 `register` 入口拿 manifest），通过才替换槽位，失败保留旧 state。

### 8d. 插件四要素对照（OpenClaw / Hermes / ZeroClaw / cinch）

| 要素 | OpenClaw | Hermes | ZeroClaw | cinch（Ruby IRC bot） | 本平台建议（mrb.cr） |
|---|---|---|---|---|---|
| **发现** | workspace extensions/ 目录 + npm 包（`openclaw plugins install <pkg>`）+ config.json plugins.entries | plugin-catalog 一键装 reviewed 插件（hermes-agent.md:155） | 弃插件市场：ClawHub 41.7% skills 含漏洞数百恶意（zeroclaws.io 2025-11）→ trait 驱动无代码扩展 | RubyGem 分发 + require + bot 配置注册 | **本地目录约定**（plugins/*.rb），装包暂缓；上市场前先做审计面（ZeroClaw 教训） |
| **契约** | `definePluginEntry({id,name,kind,configSchema,register(api)})`，id 须匹配 openclaw.plugin.json manifest | public-api 白名单 + `hermes plugins validate` 校验 import 面（hermes-agent.md:156） | ADR-015 one-governed-soul：five closed dials、人格文件 IDENTITY.md/SOUL.md | `include Cinch::Plugin` + `match`/`execute` 声明式 DSL（rubydoc cinch 2.3.4） | **约定入口脚本**：脚本须定义 `register(api)`，宿主白名单 api（watch/tools/hook 点）；manifest=脚本头注释或伴生 yaml |
| **能力注册** | `api.registerProvider/registerTool/...`（exclusive slots） | 九类 provider seams（memory/model/web-search/secret-source 等）+ middleware 可改 LLM/tool 行为 + observer-hooks 只读遥测 | 无代码 trait：人格/技能文件 | match 触发器 + logger helpers + User#monitor | **api 暴露最小面**：注册工具/钩子/定时；mruby 侧只能 JSON-like 出入 |
| **生命周期/隔离** | fault isolation/priority/parallelism 状态机（hooks-plugins 页，正文未验 §9） | built-in lifecycle hooks；profile 隔离（独立 state.db/skills） | carrier continuity（人格连续性优先） | CRuby 常量加载，启动一次性，**无卸载/热替换**（语言限制） | **每插件独立 mrb_state**（§8c）：重载=重建 state；crash 只重建该 state；配额靠裁剪 gembox + allocf 覆写 |

cinch 维护现状佐证「CRuby 无热卸载」是其插件层天花板，恰反衬 mrb.cr「state 重建」路线的优势。

### 8e. 接入面建议（喂设计文档）

1. 插件层为**可选模块**（Tessell 扩展形态定调：mrb.cr 可选插件层有搞头，嵌 CRuby 不推荐）；主链路（配置热更新 §0）不依赖它。
2. 宿主 API 白名单 + JSON-like 传值 + 单 State 线程亲和三条纪律写进插件契约；执行配额首版用「宿主侧 watchdog 定时器 + 插件调用标超时」过渡，内存配额走 `mrb_default_allocf` 覆写。
3. 脚本重载复用配置层同款先验后换：临时 state 冒烟通过才换引用；重载动作同样由 Q2 watch（插件目录）与 Q4 IPC 命令触发——**与配置热更新共用一套触发-校验-换引用管线，只差 payload 是 Config 还是 mrb_state**。

---

## 9. 未验证清单

1. **OpenClaw runbook 正文逐字**：docs.openclaw.ai/gateway/ fetch 仅返回导航目录；hot/hybrid 细节来自 openclawlab.com 与 openclaws.io 两镜像搜索快照（两镜像同文互证，但未逐字比对官方页）。
2. **OpenClaw 插件 fault isolation 状态机细节**：hooks-plugins 状态机页未取正文。
3. **naqvis/file_watcher 实测**：Windows ReadDirectoryChangesW 路径未在本仓库冒烟（纯文档查证）；接入时应先写 10 行 demo 验证编辑器原子写（rename 替换）事件语义。
4. **`Atomic#swap` 详注与 reference type 的矛盾**（§3.2）：以方法可用性清单为准，但未跑 snippet 验证 `Atomic(Config).new` 编译；实现前 5 分钟冒烟。
5. **mruby `$SAFE` 现状**：limitations.md 未逐字核对；不影响结论（沙箱靠 gembox 裁剪+allocf+白名单）。
6. **mrb.cr 84/0 为本地未提交状态**（task-4 链）；issue #1 修复的提交/CI 状态未复核。
7. **企微/飞书换 secret 后旧 access_token 的强制失效**：channels 笔记确认 ~2h TTL 独立缓存，但「主动作废旧 token」的 API 行为未验证——热换渠道凭据依赖它的话需实测；保守做法是等 TTL 自然过期（≤2h）或维护 token 失效标记。
8. **Hermes #48918/#54941 落地进度**：仅核到 2026-09 PR #66777 提及「在途」，当前是否已合并未追。
