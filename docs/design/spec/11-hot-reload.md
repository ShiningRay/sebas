# design.md §11 配置热更新（硬需求③）

> 导航：[设计总览](../design.md) ｜ [文档索引](../README.md) ｜ 上一节：[§10](10-security.md) ｜ 下一节：[§12](12-plugin-layer.md)

## 11. 配置热更新（硬需求③专章：免重启重载）

> 用户原话：「在深度使用 Hermes 的过程中，我对于修改了配置之后就要重启 gateway 感到十分厌烦，请调研 crystal 中如何不重启热更新配置」。本章依据 `research/crystal-hot-reload.md`（以下称**热更新笔记**）；结论均有先例锚定，未验证处照实标注（§15.1）。

### 11.1 痛点定位与业界对照

- **反面教材 Hermes**：确认无热重载——四证据链（均为仓库 issue/PR）：issue #48693
  （「detect config.yaml changes without /restart」，2026-06 开放未实现）；PR #13217
  （CLI 改配置后打印「must restart the gateway」警告）；PR #66777
  （2026-09 插件 toggle 仍提示 restart，SIGUSR2 reload 「在途」）；PR #37880
  （仅个别 key 进 `_CACHE_BUSTING_CONFIG_KEYS` 缓存失效名单，非全量热载）（热更新笔记 §7.2）。
  用户厌烦的正是此缺陷。
- **正面教材 OpenClaw**：reload 是一等公民——`gateway.reload.mode` 默认 **hybrid**（hot / restart / hybrid / off 四模式）：多数改动静默热应用，结构性改动须重启（热更新笔记 §7.1）。**证据局限**：runbook 官方正文未逐字取到（docs.openclaw.ai fetch 仅返回导航目录），上述细节来自 openclawlab.com 与 openclaws.io 两镜像搜索快照互证（热更新笔记 §7.1/§9.1；已列 §15.1.12）。
- **语义参照 nginx**：`nginx -s reload`=SIGHUP → master 重读配置 → 新 worker 起旧 worker 优雅收尾。单进程 Crystal 翻译：**进程不重启、配置整根换新；进行中的 turn 用旧配置快照跑完，新 turn 用新配置**（热更新笔记 §7.3）。

### 11.2 四正交件架构（触发 → 校验 → 换引用 → 重应用）

| 件 | 设计 | 依据 |
|---|---|---|
| **① 触发** | **双通道并存**：文件监听主路 + **IPC `reload` 命令**；POSIX SIGHUP 作第三便利通道。三路细节见下 | 热更新笔记 §2/§4 |
| **② 解析校验（先验后换）** | 读盘 → `expand_env_vars` → YAML 解析 → `validate!`（从启动 fail-fast 强化为**运行时全量校验**：必填 key、binding 引用的账号必须存在、账号 id 唯一）→ **失败保留旧配置 + Log.warn，不崩溃** | autobot cron `reload_if_changed` 先验后换先例（`cron/service.cr:275-290` rescue 保旧）+ `loader.cr:152-166` 现链复用；热更新笔记 §5 |
| **③ 换引用** | **`Atomic(Config)` 整根替换**：校验通过才 `CONFIG.set(new_cfg)`，旧引用自然 GC。Crystal 默认单线程调度下裸换本就安全，Atomic 是面向 Parallel 上下文演进的零成本写法。注明歧义：`Atomic#swap` 详注有「T cannot contain any reference types」字样，指算术版 swap；以 reference type 可用方法清单为准（compare_and_set/get/set 均可用） | 热更新笔记 §3 |
| **④ 消费纪律（每 turn 快照）** | **每 turn 开头取一次 `CONFIG.get` 快照**，turn 内不再受重载影响——「一次 turn 内配置语义一致」不依赖任何同步原语，天然兼容 fiber 切换；等价于 nginx「旧 worker 优雅收尾」的单进程实现 | 热更新笔记 §3.3 模式 B；OpenClaw runtime snapshot 同思路 |

**① 触发件展开**：

- **文件监听主路**：`naqvis/file_watcher`，Windows 用 ReadDirectoryChangesW、Linux 用 inotify
  原生后端；初始化失败自动降级 snapshot 轮询。
- **IPC `reload` 命令**：确定性手动触发，复用 §9 NDJSON 命令面。这是 Windows 的主通道——
  Crystal 在 Windows 上 `Signal.trap` 直接抛 `NotImplementedError`，无 SIGHUP 可用；
  先例见 autobot `Ipc::Server` `cli/gateway.cr:102-143`。
- **POSIX SIGHUP**：nginx 惯例的第三便利通道。
- **监听不可靠兜底**：保留 autobot cron 式 mtime(+size) 轮询，间隔缩至 1–5s。
  这是网络盘、编辑器原子写、watch 实例耗尽丢事件的最后防线；~20 行零依赖，已在 cron 中验证。
- **去抖 200–500ms 合并窗口**：吸收编辑器半写瞬态。

### 11.3 组件重应用矩阵（可热换 vs 必须重启）

| 组件 | 热换 | 说明 |
|---|---|---|
| 路由 binding、编排规则、工具 allowlist、提示词 | ✅ | 纯数据，换引用即生效，turn 边界切换 |
| 限流桶参数 | ✅ | 新参数下个 tick 生效，无需迁移状态 |
| provider key / LLM 凭据 | ✅ | 新 key 下次请求即用（Hermes `_CACHE_BUSTING_CONFIG_KEYS` 先例：key 级缓存失效已有先例） |
| 渠道凭据（app_id+secret） | ⚠️ | token 本就是 ~2h TTL 生命周期对象；换 secret 后保守做法=等 TTL 自然过期（≤2h）或维护失效标记——「主动作废旧 token」的 API 行为未验证（§15.1） |
| **账号增删** | ⚠️ | = **账号监督体（§5.1 账号生命周期）下的 fiber 创建/优雅停止**：加账号=spawn 新长连接 fiber；删账号=drain 在途消息后 close。与多账号设计合流，无需重启进程 |
| 监听端口/协议栈 | ❌ restart | 套接字绑定属进程资源，单进程内换端口会丢包；校验阶段对这类配置给出明确「此项需重启」提示（OpenClaw hybrid 的 restart 子集语义） |

（依据热更新笔记 §6 组件矩阵；账号增删行与渠道笔记「每账号长连接配监督体」建议合流。）

### 11.4 Crystal 实现要点

- 模式 A 代码骨架（热更新笔记 §3.3）：

```crystal
CONFIG = Atomic(Config).new(Config.load_initial)

def reload_config(path) : Bool
  new_cfg = Config.load_and_validate(path)  # 先验：读盘→展开→解析→校验，失败抛异常
  CONFIG.set(new_cfg)                       # 后换：整根替换，旧引用自然被 GC
  true
rescue ex
  Log.warn { "config reload rejected, keeping old config: #{ex.message}" }
  false
end
```

- **YAML 深合并：自写 ~20 行**。无可靠现成 shard（stdlib 拒收 `Hash#deep_merge`，crystal issue #6791；`deep-merge.cr` 数组合并 TODO 未实现、维护弱）。数组合并语义定为**整体替换**——可预测、避免半新半旧数组，与 OpenClaw/hydra 家族惯例一致（热更新笔记 §5）。
- **dotenv 不新增依赖**：autobot 自带 `load_env_file`（`loader.cr:17-31`）已够用。
- validate! 运行时强化清单：必填 key、**binding 引用的账号必须存在**（防删账号后路由悬空，fail-closed 与 §3.2 一致）、accounts 数组内 id 唯一（防重复凭据注册，§10.1 同款 park 语义）。
