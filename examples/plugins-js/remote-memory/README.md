# Remote Memory JS（QuickJS 伪代码示例）

与 `examples/plugins/remote-memory/` 对应，使用 JavaScript 实现记忆后端的参数校验、敏感内容辅助检查和召回排序。

> 这是 QuickJS 方案示意，当前主设计仍以裁剪 mruby 子进程为首版运行形态。QuickJS runner、runtime manifest 字段和宿主 capability 桥接尚未实现；本示例不是可直接安装的产品插件。

## 运行边界

宿主为每次调用启动一个新的 QuickJS 子进程，并注入：

- `request`：本次请求的 JSON-like 对象；
- `capability(name, args)`：同步、受控的宿主 RPC；
- `emit(result)`：输出一个结构化结果。

脚本没有 `require`、npm 包、Node 内置模块、`fetch`、文件 API 或任意网络访问。若异步 driver 确有需求，应由宿主先完成 IO，再把结果同步交给本次插件调用，而不是让脚本自建事件循环。

## 与 Ruby 版的区别

业务语义、请求字段、capability 和返回结构一致；入口改为 `plugin.js`，manifest 增加示意性的 `runtime: "quickjs"`。该字段尚需正式纳入设计后才能用于产品包。

```json
{
  "id": "remote-memory-js",
  "runtime": "quickjs",
  "entrypoint": "plugin.js"
}
```

普通 Node.js 不等于这种运行环境：Node 自带文件、网络和子进程能力，不能仅因改成独立进程就宣称具备同等沙箱。若未来直接使用 Node，应定位为可信插件运行环境，并另设 OS 级隔离和资源限制。

## 请求示例

```javascript
const request = {
  protocol_version: 1,
  request_id: "req-js-01",
  plugin_id: "remote-memory-js",
  action: "recall",
  idempotency_key: "turn-01:remember:01",
  context: { agent_id: "main", session_id: "session-01" },
  config: { kind_weights: { profile: 1.4, decision: 1.2 } },
  payload: { query: "数据库选型", limit: 5 },
};
```

成功结果为 `{ ok: true, ... }`；业务拒绝为 `{ ok: false, error: { code, message } }`。协议、超时、异常和结果大小仍由宿主统一控制。
