# memory-guard 示例插件（M3-WP4，#16 真实 DSL）：默认记忆写入前的整理与
# 脱敏 gate 钩子（memory.remember.before，design.md §12.11 gate+transform）。
#
# 不替换存储后端，不申请 capability，无文件/网络访问。
# manifest 已声明该钩子（授权上限）；宿主只向声明了它的插件派发，
# 且本次进程内未用 on_hook 登记的名称不派发（§12.2 精确注册）。
# 返回 allow/modify/deny 决策对象——宿主重新校验后才写入（WP5 接宿主闸）。

on_hook "memory.remember.before" do |payload|
  entry = payload["entry"] || {}
  text = entry["text"].to_s.strip
  if text.empty?
    {"decision" => "deny", "entry" => nil, "reason" => "empty memory"}
  else
    low = text.downcase
    # 沙箱无 Regexp（无 onig）：示例规则用小写子串匹配；实际规则应由宿主
    # 安全策略统一维护，错误信息不包含原文。
    sensitive_marks = ["-----begin", "private key", "api_key", "access_token", "password:"]
    if sensitive_marks.any? { |mark| low.include?(mark) }
      {"decision" => "deny", "entry" => nil, "reason" => "credential-like content detected"}
    else
      normalized = text.gsub("\r\n", "\n")
      {"decision" => "modify", "entry" => entry.merge("text" => normalized), "reason" => nil}
    end
  end
end
