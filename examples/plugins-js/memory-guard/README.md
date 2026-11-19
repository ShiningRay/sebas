# Memory Guard JS（QuickJS 伪代码示例）

与 Ruby 版 `memory-guard` 对应，在记忆写入前整理文本、补充标签并拒绝空内容和疑似凭据。插件不持有记忆数据，不申请 capability。

> 当前主设计仍以裁剪 mruby 为首版运行形态。QuickJS runner、runtime manifest 字段和 hook 注册尚未实现；本目录是 JavaScript 方案示意，不是可安装的产品插件。

## 请求

```javascript
const request = {
  protocol_version: 1,
  request_id: "req-js-02",
  plugin_id: "memory-guard-js",
  action: "memory.remember.before",
  context: { agent_id: "main", session_id: "session-01" },
  config: {},
  payload: {
    entry: {
      kind: "memory",
      text: "决定采用 PostgreSQL 保存任务状态",
      tags: ["database"],
    },
  },
};
```

宿主注入 `emit(result)`，脚本返回：

```javascript
{ decision: "allow", entry: null, reason: null }
```

```javascript
{
  decision: "modify",
  entry: { kind: "memory", text: "规范化后的文本", tags: ["database", "decision"] },
  reason: null,
}
```

```javascript
{ decision: "deny", entry: null, reason: "credential-like content detected" }
```

宿主仍须校验修改后的 entry，并确保错误信息不泄露原始敏感内容。QuickJS 脚本只处理纯数据，不能通过 `require`、`fetch` 或 Node API 绕过 capability 白名单。

## 为什么不是直接 Node.js

直接使用 Node 可以获得 npm 生态和异步 IO，但它会改变安全边界、部署体积、启动成本及资源治理方式。对当前“宿主掌握所有外部效应”的插件模型，QuickJS 子进程更贴近裁剪 mruby；若插件定位改为可信代码、需要丰富 npm 包，则应单独设计 Node worker 与 OS 隔离方案，而不是把本示例直接放入 Node 执行后称为沙箱。
