# 伪代码：默认记忆写入前的整理与脱敏钩子（design.md §12.11）。
#
# 不替换存储后端，不申请 capability，不访问文件或网络。
# on_hook 与 emit 由宿主 runner 注入；manifest 已声明该钩子，
# 未在本次进程内用 on_hook 登记的名称不会派发（§12.2 精确注册）。

emit_decision = lambda do |decision, entry = nil, reason = nil|
  emit({
    "decision" => decision, # allow / modify / deny
    "entry" => entry,
    "reason" => reason
  })
end

on_hook "memory.remember.before" do |payload|
  entry = payload["entry"]
  raw = entry["text"].to_s
  text = raw.strip

  if text.empty?
    emit_decision.call("deny", nil, "empty memory")
  elsif text =~ /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/
    # 示例规则，实际规则应由宿主安全策略统一维护；错误信息不包含原文。
    emit_decision.call("deny", nil, "private key detected")
  elsif text =~ /(?:api[_ -]?key|access[_ -]?token|password)\s*[:=]\s*\S+/i
    emit_decision.call("deny", nil, "credential-like content detected")
  else
    normalized = text.gsub(/\r\n/, "\n")
    normalized = normalized.gsub(/[ \t]+/, " ")

    tags = entry["tags"] || []
    tags = tags + ["preference"] if normalized =~ /我喜欢|我偏好|prefer/i
    tags = tags + ["decision"] if normalized =~ /决定采用|最终选择|decided to/i

    # 与原始 entry 文本比较（标签先去重）：带首尾空白的输入、重复标签或新增标签都返回 modify。
    if normalized == raw && tags.uniq == (entry["tags"] || [])
      emit_decision.call("allow")
    else
      emit_decision.call("modify", {
        "kind" => entry["kind"],
        "text" => normalized,
        "tags" => tags.uniq
      })
    end
  end
end
