# Memory Guard（伪代码示例）

演示 `memory.remember.before` 钩子：在默认 SQLite 或 `remote-memory` 后端之前整理文本、补充标签，拒绝空内容和疑似凭据。插件不持有记忆数据，也不需要任何 capability。

> 当前仓库的插件 runner 和 hook 注册尚未实现。本目录是设计范例，不是可直接安装或已经通过 mruby 运行的产品插件。规则仅为示例，不应替代宿主统一的敏感内容检查与脱敏策略。

## 请求与返回

宿主在每次调用注入 `on_hook(name) { |payload| … }` 与 `emit(result)`；脚本以 `on_hook "memory.remember.before"` 登记 handler（manifest 已声明该钩子，未登记的名称不会派发，§12.2 精确注册）。`memory.remember.before` 的 payload 结构：

```ruby
payload = {
  "entry" => {
    "kind" => "memory",
    "text" => "决定采用 PostgreSQL 保存任务状态",
    "tags" => ["database"]
  }
}
```

返回值只有三种决策：

```ruby
{"decision" => "allow", "entry" => nil, "reason" => nil}
```

```ruby
{
  "decision" => "modify",
  "entry" => {
    "kind" => "memory",
    "text" => "规范化后的文本",
    "tags" => ["database", "decision"]
  },
  "reason" => nil
}
```

```ruby
{"decision" => "deny", "entry" => nil, "reason" => "credential-like content detected"}
```

宿主必须再次校验修改后的 entry，不能把插件返回值视为天然可信。拒绝原因不应包含原始敏感文本。

## 宿主调用链

```text
Agent 请求保存记忆
  → memory.remember.before（本插件及其他已启用钩子）
  → deny：返回结构化错误，不写后端
  → modify：宿主重新校验 entry
  → allow：使用原 entry
  → 选定的 MemoryBackend（默认 SQLite / 插件后端）
  → 按 idempotency_key 写入
```

未来打包方式：

```bash
sebas plugin validate examples/plugins/memory-guard
sebas plugin pack examples/plugins/memory-guard --output memory-guard-0.1.0.sebas-plugin
sebas plugin install ./memory-guard-0.1.0.sebas-plugin
sebas plugin enable memory-guard
```
