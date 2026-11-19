# 伪代码：默认记忆写入前的整理与脱敏钩子（design.md §12.9）。
#
# 不替换存储后端，不申请 capability，不访问文件或网络。
# request 和 emit 由宿主 runner 注入；每次调用都是新的 mruby 子进程。

emit_decision = lambda do |decision, entry = nil, reason = nil|
  emit({
    "decision" => decision, # allow / modify / deny
    "entry" => entry,
    "reason" => reason
  })
end

if request["action"] != "memory.remember.before"
  emit_decision.call("deny", nil, "unsupported hook action")
  exit 0
end

entry = request["payload"]["entry"]
text = entry["text"].to_s.strip

if text.empty?
  emit_decision.call("deny", nil, "empty memory")
  exit 0
end

# 示例规则，实际规则应由宿主安全策略统一维护；错误信息不包含原文。
if text =~ /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/
  emit_decision.call("deny", nil, "private key detected")
  exit 0
end

if text =~ /(?:api[_ -]?key|access[_ -]?token|password)\s*[:=]\s*\S+/i
  emit_decision.call("deny", nil, "credential-like content detected")
  exit 0
end

normalized = text.gsub(/\r\n/, "\n")
normalized = normalized.gsub(/[ \t]+/, " ")

tags = entry["tags"] || []
tags = tags + ["preference"] if normalized =~ /我喜欢|我偏好|prefer/i
tags = tags + ["decision"] if normalized =~ /决定采用|最终选择|decided to/i

if normalized == text && tags == (entry["tags"] || [])
  emit_decision.call("allow")
else
  emit_decision.call("modify", {
    "kind" => entry["kind"],
    "text" => normalized,
    "tags" => tags.uniq
  })
end
