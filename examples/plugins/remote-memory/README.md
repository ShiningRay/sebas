# Remote Memory（伪代码示例）

演示如何用 `memory.backend` 扩展点替换默认记忆系统：mruby 负责参数规范化、敏感内容辅助检查和召回排序；真正的持久化、网络访问、凭据及幂等控制由宿主 driver 承担。

> 当前仓库的插件 runner、capability RPC、包管理命令和宿主 `MemoryBackend` 插槽尚未实现。本目录是设计范例，不是可直接安装或已经通过 mruby 运行的产品插件。

## 文件

- `manifest.json`：插件身份、动作、capability 和配置 schema。
- `plugin.rb`：唯一入口；宿主在每次调用前将 `request` 设为本次请求的 JSON-like Hash，并提供 `capability(name, args)` 与 `emit(result)`。

## 请求与返回

```ruby
request = {
  "protocol_version" => 1,
  "request_id" => "req-01",
  "plugin_id" => "remote-memory",
  "action" => "recall", # remember / recall / forget
  "idempotency_key" => "turn-01:remember:01",
  "context" => {
    "agent_id" => "main",
    "session_id" => "session-01"
  },
  "config" => {
    "kind_weights" => {"profile" => 1.4, "decision" => 1.2}
  },
  "payload" => {"query" => "数据库选型", "limit" => 5}
}
```

`remember` 的 payload：

```ruby
{
  "memory_id" => "mem-01", # 宿主生成
  "kind" => "decision",
  "text" => "决定采用 PostgreSQL 保存任务状态",
  "tags" => ["database"]
}
```

`forget` 的 payload 为 `{"memory_id" => "mem-01"}`。成功结果采用 `{"ok" => true, ...}`；业务拒绝采用 `{"ok" => false, "error" => {"code" => ..., "message" => ...}}`，异常、超时、协议错误由宿主统一转换。

## 宿主装配

记忆工具、自动召回和巩固都应依赖同一个 `MemoryBackend` 接口，不能只替换工具名称却继续直写默认 Store：

```crystal
abstract class MemoryBackend
  abstract def remember(request : RememberRequest) : RememberResult
  abstract def recall(request : RecallRequest) : RecallResult
  abstract def forget(request : ForgetRequest) : ForgetResult
end
```

未来配置示例：

```yaml
agents:
  main:
    memory:
      backend: "plugin:remote-memory"

# 该配置位于用户数据目录，不由插件包覆盖。
plugins:
  remote-memory:
    kind_weights:
      profile: 1.4
      decision: 1.2
      episode: 0.8
```

宿主必须将 `memory_driver.*` 映射到已登记的 driver，并自行注入 agent scope、端点和凭据引用。插件无权以参数指定任意 URL、文件路径、shell 命令或读取宿主环境变量。

打包命令在对应功能实现后使用：

```bash
sebas plugin validate examples/plugins/remote-memory
sebas plugin pack examples/plugins/remote-memory --output remote-memory-0.1.0.sebas-plugin
sebas plugin install ./remote-memory-0.1.0.sebas-plugin
sebas plugin enable remote-memory
```
