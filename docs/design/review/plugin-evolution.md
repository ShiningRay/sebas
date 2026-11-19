# 插件复杂化演进规划：多文件、初始化与常驻 Worker

> 日期：2026-11-19。
> 性质：**未来演进约束与设计预案，不是当前已支持能力，也不自动增加 M3 工作包**。
> 当前权威契约仍为 [design.md](../design.md) §12：单入口 `plugin.rb`、每动作独立裁剪 mruby 子进程、manifest 精确声明与派发。
> 触发背景：复杂插件若全部塞入一个文件，会出现可维护性、测试隔离和重复加载成本问题；但直接引入完整 RubyGems 或共享常驻 VM 又会破坏现有安全和故障边界。

## 一、演进原则

1. **单入口不等于单文件**：`plugin.rb` 始终只负责注册，未来可允许受控 `lib/**/*.rb` 承担纯业务逻辑。
2. **复杂化不能绕过能力边界**：文件拆分不改变 manifest、精确派发、宿主 driver、资源预算、审批与幂等约束。
3. **先包内模块化，后讨论共享依赖**：不因为代码增多就引入 RubyGems/Bundler、原生扩展或安装时联网。
4. **先显式生命周期，后常驻运行**：初始化语义先以显式 action 明确；常驻 worker 只有经实测证明进程启动成本成为问题才引入。
5. **保持协议可迁移**：多文件和常驻 worker 必须复用现有 action/hook/capability 协议，不回到不同插件共享 `mrb_state` 的进程内模型。

## 二、阶段 P1：受控多文件包（下一阶段优先）

### 2.1 目标包布局

```text
remote-memory-1.3.0.sebas-plugin
├── manifest.json
├── plugin.rb
├── lib/
│   ├── request_validator.rb
│   ├── normalizer.rb
│   ├── ranking.rb
│   └── backends/
│       └── remote.rb
└── README.md
```

`plugin.rb` 只做依赖加载与注册：

```ruby
require_relative "lib/request_validator"
require_relative "lib/normalizer"
require_relative "lib/ranking"
require_relative "lib/backends/remote"

on_action :remember do |payload|
  entry = Normalizer.normalize(payload)
  RequestValidator.validate!(entry)
  Remote.remember(entry, driver: "remote", idempotency_key: $idempotency_key)
end
```

`lib/` 文件只实现纯 Ruby 逻辑；宿主提供 `$action/$config/$context/$payload`、capability proxy 和协议输入输出，辅助文件不自行读取 stdin 或打开网络/文件。

### 2.2 加载白名单

- 包根仅允许 `manifest.json`、`plugin.rb`、`README.md` 和 `lib/**/*.rb`。
- 只允许字面量、静态可解析的 `require_relative`；目标规范化后必须留在本插件 `lib/` 内。
- 拒绝绝对路径、`..` 穿越、符号链接/重解析点、重复/大小写冲突路径。
- 禁止 `load`、动态 `eval` 加载、用户输入拼接路径、任意 `require`、原生 DLL/so 和安装时联网。
- `require` 标准库不按“语法相近即可”放行；需要的能力逐项由 runner 明确提供，或另立 mruby 标准库兼容清单。

示例：

```ruby
require_relative "lib/ranking"             # 允许
require_relative "../../secret"           # 拒绝
load path_from_payload                     # 拒绝
require "some_native_extension"           # 拒绝
```

### 2.3 开发仓库与分发包分离

```text
# 开发仓库：可含测试和示例
remote-memory/
├── manifest.json
├── plugin.rb
├── lib/
├── spec/
├── examples/
└── README.md

# pack 仅收录：manifest.json、plugin.rb、lib/**/*.rb、README.md
```

测试不得依赖生产包外的隐藏文件。纯逻辑测试可在普通 Ruby 测试环境运行；mruby 解释器兼容测试、包路径安全测试、宿主 capability 集成测试必须分别保留，CRuby `ruby -c` 不能替代 mruby 验收。

### 2.4 兼容与迁移

- 当前 v1 包仍是 `manifest.json + plugin.rb + README.md`，现有单文件插件无需迁移。
- 多文件支持应升级 manifest `schema_version` 或包格式能力标识，例如 `features: ["multi-file-v1"]`；不能由安装器根据是否出现 `lib/` 静默猜测。
- `api_version` 主版本是否递增取决于运行时 DSL/协议是否变化：仅包格式扩展可用独立 schema 标识，不必强迫所有旧插件改写；若加载/执行语义不兼容则必须升主版本。
- 安装器遇到不支持的多文件特性必须 fail-closed；旧宿主不得忽略 `lib/` 后仅执行入口。

### 2.5 启动条件与验收

启动条件：出现真实多动作/多后端插件，单文件已影响审查或测试，而非仅为形式上的“未来可能复杂”。

验收至少覆盖：

- 包内嵌套加载、依赖顺序与重复 require 的幂等；
- 绝对路径、穿越、链接、重复路径、动态加载拒绝；
- 多文件包与单文件包相同请求得到相同协议结果；
- 全包静态依赖闭包在安装时可见，运行时不存在未声明文件读取；
- 包大小、文件数、单文件大小、加载时长限制；
- 配置、数据、代码升级/回滚语义不因多文件改变。

## 三、阶段 P2：初始化、缓存与性能测量

多文件会放大每次调用都启动新进程的成本：

```text
启动进程 → 加载入口 → 加载 lib 依赖闭包 → 注册 handler → 执行一个动作
```

顶层代码必须保持轻量、只做声明；慢初始化、建 schema、外部服务探测和大数据加载不得放在 `plugin.rb` 顶层。

### 3.1 生命周期动作

- `install`：只准备插件自有数据/schema，必须幂等，不执行任意系统安装脚本。
- `enable`：验证配置与宿主 driver、准备运行时必要状态；失败不激活。
- `disable`：尽力停止本插件新任务、释放自有逻辑资源，不承诺删除外部服务数据。
- `upgrade`：配置/数据迁移与 active 指针切换同事务，失败保旧。

以上均由宿主显式触发，**不能每次 hook 隐式执行 init**；声明和注册校验阶段不得发生这些效应。

### 3.2 缓存边界

- 每动作进程中的 `$` 变量、block 和 Ruby 对象不是缓存。
- 跨调用状态须通过宿主批准的 versioned store；缓失效随 `(plugin_id, active_version, config_digest)` 变化。
- 敏感上下文、完整 prompt、凭据不得为了加速而默认持久化；缓存须带 scope 与容量/TTL。
- 在决定常驻 worker 前先测：进程启动、脚本解析、依赖加载、handler 执行、capability RTT 的分解耗时；不能只凭插件文件数量推断性能瓶颈。

## 四、阶段 P3：按插件隔离的常驻 Worker（条件触发）

只有当复杂插件频繁调用且测量证明启动/加载成本不可接受时，才评估常驻 worker。它是**性能优化，不是开放更多能力**。

### 4.1 保持的边界

- `(plugin_id, version, config_snapshot)` 决定独立 worker；不同插件不共享 VM。
- 继续使用 manifest、精确 action/hook dispatch、capability RPC、schema 校验、审批与幂等。
- watchdog 仍能终止整个插件 worker 及其后代进程；异常只重建该插件 worker，不影响宿主或其他插件。
- worker 池有全局和单插件并发上限、队列背压、内存/CPU/输出限制和启动重启退避。
- 正在执行的旧版本请求完成后 retire；新请求进入新版本 worker，禁止同 worker 热改类/常量。

### 4.2 新增风险与约束

常驻 Ruby 对象会引入跨请求状态、数据串话、内存增长和失效复杂性：

- 默认 handler 仍视为无状态；实例变量/全局变量不保证下一次请求保留，也不得作为授权真相。
- 需要缓存时必须声明，并由宿主提供命名空间、scope、容量、TTL 和版本失效。
- 每次请求重新注入可信 context；不得从上一请求继承 agent/account/session。
- 长驻 worker 必须有 idle retirement、内存高水位、崩溃次数上限和总 lifespan；不能用无限重启掩盖泄漏。
- 跨请求锁、异步任务、子进程、外部连接必须有 owner 与取消语义，disable/uninstall 能回收。
- 对所有 gate/transform 仍设置有界执行；如果 future API 支持流式响应，要另设帧/背压/取消协议，不能复用一次性结果假设。

### 4.3 启动门槛与验收

启动门槛：有真实性能报告证明 P1/P2 已无法满足需求，并完成 worker 状态威胁建模。

验收至少覆盖：

- 同插件两个请求不串 scope/配置/敏感数据；
- 旧版 worker 不被新版激活打断，完成或超时后回收；
- 崩溃、死循环、内存高水位只影响所属插件；
- 禁用、卸载、配置变更、回滚后无残留任务或连接；
- 与每动作进程模式的协议结果一致，性能提升有对照数据。

## 五、明确不在默认演进路线中的事项

以下不因插件复杂化自动开放：

1. **完整 RubyGems/Bundler**：会引入 CRuby/mruby 差异、原生扩展构建、传递依赖、版本冲突、安装联网与供应链审计成本。
2. **包内原生扩展**：与裁剪解释器、跨 Windows 部署和最小攻击面冲突。
3. **共享 VM/全局对象总线**：破坏插件间故障与数据隔离。
4. **任意动态代码加载/远程代码更新**：安装包应是可审计、固定摘要的代码单元。
5. **以 hook 名义运行永久后台循环**：长期工作必须进入宿主 task/lease/budget 体系。
6. **以性能为由减少 gate 校验或敏感字段授权**：性能优化不能改变 fail-closed 语义。

若将来确需共享库，另立专门方案：评估纯 Ruby、mruby 兼容、无网络/文件/原生扩展的库白名单，采用宿主锁定版本、逐插件显式依赖、内容摘要与冲突检查；不能默认复用系统 RubyGems。

## 六、实施决策表

| 现象 | 优先处理 | 不应先做 |
|---|---|---|
| 单文件难审查/难测试 | P1：受控 `lib/**/*.rb` + 纯逻辑测试 | 引入 Gemfile |
| 初始化副作用语义不清 | 显式 install/enable/disable/upgrade action | 顶层隐式 init |
| 启动慢但无分解数据 | P2：测量加载/执行/RPC 成本 | 直接常驻 worker |
| 高频复杂插件且数据证明启动占主导 | P3：按插件隔离 worker 评估 | 所有插件共享常驻 VM |
| 需要第三方库 | 逐项评估 mruby 兼容和宿主锁定白名单 | 安装时联网拉依赖 |
| 需要长期后台工作 | 宿主持久 task/lease/budget | hook 内永久循环 |

## 七、与当前路线图的衔接

- **M3 不扩容**：WP4~WP6 仍按单文件、每动作子进程和 21 个首版 hook 验收；P1~P3 不作为 M3 门禁的隐含交付物。
- **产品化 blocker 不变**：mruby.exe 本机 Windows 构建问题仍需按 [m3-plugin-feasibility.md](m3-plugin-feasibility.md) 消项，不能用未来 worker 方案掩盖。
- **版本承诺**：本文中的目录、manifest 特性名、worker 约束均为预案；实际开启 P1/P3 时须回写 design.md §12、包 schema 与对应 WP 验收，不以本文自动授权实现。
