// 伪代码：QuickJS 子进程中的远程记忆后端。
//
// request、capability、emit 由宿主 runner 注入；capability 是同步返回
// JSON-like 值的受控 RPC，不使用 Promise、fetch、require 或 Node API。
// 每次调用都是新进程，不能把全局变量当跨调用缓存。

"use strict";

function success(data = {}) {
  emit({ ok: true, ...data });
}

function failure(code, message) {
  emit({ ok: false, error: { code, message } });
}

const { action, context = {}, payload = {}, config = {} } = request;
const driver = "remote";

switch (action) {
  case "remember": {
    const text = String(payload.text ?? "").trim();
    if (!text) {
      failure("empty_memory", "Memory text must not be empty");
      break;
    }

    // 辅助检查，不代替宿主统一的安全策略；不回显原始敏感文本。
    if (/(?:api[_ -]?key|private[_ -]?key|access[_ -]?token|password)\s*[:=]/i.test(text)) {
      failure("sensitive_content", "Refusing to store credential-like content");
      break;
    }

    const result = capability("memory_driver.write", {
      driver,
      operation: "upsert",
      agent_id: context.agent_id,
      memory_id: payload.memory_id,
      idempotency_key: request.idempotency_key,
      record: {
        kind: payload.kind || "memory",
        text,
        tags: payload.tags || [],
        metadata: {
          source_session: context.session_id,
          schema_version: 1,
        },
      },
    });

    success({ memory_id: result.memory_id, status: result.status });
    break;
  }

  case "recall": {
    const query = String(payload.query ?? "").trim();
    if (!query) {
      failure("empty_query", "Recall query must not be empty");
      break;
    }

    const requestedLimit = Number.isSafeInteger(payload.limit) ? payload.limit : 5;
    const limit = Math.min(20, Math.max(1, requestedLimit));

    // driver 必须是宿主已配置的驱动，不能由脚本传任意 URL 或凭据。
    const response = capability("memory_driver.query", {
      driver,
      agent_id: context.agent_id,
      query,
      limit: limit * 3,
    });

    const weights = config.kind_weights || {};
    const items = response.items
      .map((item) => ({
        id: item.id,
        kind: item.kind,
        text: item.text,
        score: item.score * (weights[item.kind] || 1.0),
        metadata: item.metadata,
      }))
      .sort((a, b) => b.score - a.score)
      .slice(0, limit);

    success({ items });
    break;
  }

  case "forget": {
    const memoryId = String(payload.memory_id ?? "").trim();
    if (!memoryId) {
      failure("missing_memory_id", "memory_id is required");
      break;
    }

    const result = capability("memory_driver.delete", {
      driver,
      agent_id: context.agent_id,
      memory_id: memoryId,
    });

    success({ deleted: result.deleted });
    break;
  }

  default:
    failure("unsupported_action", `Unsupported memory action: ${action}`);
}
