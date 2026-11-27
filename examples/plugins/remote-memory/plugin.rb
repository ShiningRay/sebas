# remote-memory 示例插件（M3-WP4，#16 真实 DSL）：受控记忆后端动作面。
#
# 每次动作都在一个新的裁剪 mruby 子进程中执行（design.md §12.2）：
# - 沙箱无文件/网络能力，外部记忆服务只能经宿主 capability driver
#   （memory_driver.*）访问，agent/session scope 由宿主注入；
# - $action/$config/$context/$payload/$idempotency_key 由宿主注入，
#   handler 以 $payload 为唯一业务参数；
# - 无跨调用 Ruby 状态：不把全局变量当缓存，持久化走 capability。
#
# 注意：沙箱 gembox 无 Regexp（无 onig），敏感词检查用小写子串匹配。

on_action "remember" do |payload|
  text = payload["text"].to_s.strip
  if text.empty?
    raise SebasPluginError.new("empty_memory", "Memory text must not be empty")
  end

  # 辅助检查，不代替宿主的统一凭据识别与脱敏策略；不输出原始敏感文本。
  low = text.downcase
  sensitive_marks = ["api_key", "api-key", "private_key", "private-key",
                     "access_token", "password:"]
  if sensitive_marks.any? { |mark| low.include?(mark) }
    raise SebasPluginError.new("sensitive_content", "Refusing to store credential-like content")
  end

  # memory_id 由宿主 driver 生成；idempotency_key 防恢复重放重复写入。
  memory = capability("memory_driver.write", {
    "text"            => text,
    "kind"            => payload["kind"] || "memory",
    "idempotency_key" => $idempotency_key,
  })
  {"remembered" => memory["id"].to_s, "kind" => memory["kind"].to_s}
end

on_action "recall" do |payload|
  query = payload["query"].to_s.strip
  limit = payload["limit"].is_a?(Integer) ? payload["limit"] : 10
  response = capability("memory_driver.query", {"query" => query, "limit" => limit})
  # 示例排序：后端相关性 × 用户配置的记忆类型权重（config 真相源）。
  weights = $config["kind_weights"].is_a?(Hash) ? $config["kind_weights"] : {}
  items = response["items"].map do |item|
    weight = weights[item["kind"]].is_a?(Numeric) ? weights[item["kind"]] : 1.0
    {
      "id"    => item["id"].to_s,
      "kind"  => item["kind"].to_s,
      "text"  => item["text"].to_s,
      "score" => item["score"].to_f * weight.to_f,
    }
  end
  {"query" => query, "items" => items.first(limit)}
end

on_action "forget" do |payload|
  memory_id = payload["memory_id"].to_s.strip
  if memory_id.empty?
    raise SebasPluginError.new("missing_memory_id", "memory_id is required")
  end
  result = capability("memory_driver.delete", {"memory_id" => memory_id})
  {"deleted" => result["deleted"].to_s}
end

# 生命周期动作（design.md §12.3）：宿主在生命周期节点显式调用——不进工具
# 面、绝不被 hook 派发路径隐式触发；重复执行必须幂等。
on_action "install" do |_payload|
  {"installed" => true, "note" => "example owns no external schema"}
end

on_action "enable" do |_payload|
  {"enabled" => true, "backend" => ($config["backend"] || "remote").to_s}
end

on_action "disable" do |_payload|
  {"disabled" => true}
end
