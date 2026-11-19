# 伪代码：替换默认记忆后端的插件（design.md §12）。
#
# 每次 remember/recall/forget 都在一个新的裁剪 mruby 子进程中执行。
# request 和 capability 由宿主 runner 注入；宿主还负责解析 JSON 请求、
# 校验响应、限制超时/输出、授权 driver 和脱敏日志。
#
# 本脚本不直接访问文件、网络或外部记忆服务，也不保存跨调用 Ruby 状态。

# 当前示例的约定：宿主在创建子进程前，将 request 替换为字面量 JSON-like Hash。
# 因此这里故意保留未定义的 request 标识符，而不是自行读取 stdin。
action = request["action"]
config = request["config"] || {}
context = request["context"]
payload = request["payload"]
driver = "remote"

# 统一返回一个结构化结果。实际 runner 负责把 emit 转成协议输出。
emit_result = lambda do |ok, data = {}, code = nil, message = nil|
  result = {"ok" => ok}.merge(data)
  result["error"] = {"code" => code, "message" => message} if code
  emit(result)
end

case action
when "remember"
  text = payload["text"].to_s.strip
  if text.empty?
    emit_result.call(false, {}, "empty_memory", "Memory text must not be empty")
    exit 0
  end

  # 辅助检查，不代替宿主的统一凭据识别与脱敏策略；不输出原始敏感文本。
  if text =~ /(?:api[_ -]?key|private[_ -]?key|access[_ -]?token|password)\s*[:=]/i
    emit_result.call(false, {}, "sensitive_content",
      "Refusing to store credential-like content")
    exit 0
  end

  # memory_id 由宿主生成；idempotency_key 防止恢复重放产生重复记忆。
  result = capability("memory_driver.write", {
    "driver" => driver,
    "operation" => "upsert",
    "agent_id" => context["agent_id"],
    "memory_id" => payload["memory_id"],
    "idempotency_key" => request["idempotency_key"],
    "record" => {
      "kind" => payload["kind"] || "memory",
      "text" => text,
      "tags" => payload["tags"] || [],
      "metadata" => {
        "source_session" => context["session_id"],
        "schema_version" => 1
      }
    }
  })

  emit_result.call(true, {
    "memory_id" => result["memory_id"],
    "status" => result["status"]
  })

when "recall"
  query = payload["query"].to_s.strip
  if query.empty?
    emit_result.call(false, {}, "empty_query", "Recall query must not be empty")
    exit 0
  end

  limit = payload["limit"] || 5
  limit = 5 unless limit.is_a?(Integer)
  limit = 1 if limit < 1
  limit = 20 if limit > 20

  # driver 名称对应宿主已配置的驱动，插件不能借此传任意 URL 或凭据。
  response = capability("memory_driver.query", {
    "driver" => driver,
    "agent_id" => context["agent_id"],
    "query" => query,
    "limit" => limit * 3
  })

  # 示例排序：后端相关性 × 用户配置的记忆类型权重。
  # 只接受显式配置的数值权重：缺失/非数值用默认 1.0，配置的 0 保留（JSON-like 值无 NaN/Infinity）。
  weights = config["kind_weights"].is_a?(Hash) ? config["kind_weights"] : {}
  items = response["items"].map do |item|
    raw_weight = weights.key?(item["kind"]) ? weights[item["kind"]] : nil
    weight = raw_weight.is_a?(Numeric) ? raw_weight : 1.0
    {
      "id" => item["id"],
      "kind" => item["kind"],
      "text" => item["text"],
      "score" => item["score"] * weight,
      "metadata" => item["metadata"]
    }
  end

  items = items.sort { |a, b| b["score"] <=> a["score"] }
  emit_result.call(true, {"items" => items.first(limit)})

when "forget"
  memory_id = payload["memory_id"].to_s.strip
  if memory_id.empty?
    emit_result.call(false, {}, "missing_memory_id", "memory_id is required")
    exit 0
  end

  result = capability("memory_driver.delete", {
    "driver" => driver,
    "agent_id" => context["agent_id"],
    "memory_id" => memory_id
  })

  emit_result.call(true, {"deleted" => result["deleted"]})

else
  emit_result.call(false, {}, "unsupported_action",
    "Unsupported memory action: #{action}")
end
