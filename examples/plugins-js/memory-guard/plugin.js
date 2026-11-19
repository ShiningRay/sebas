// 伪代码：QuickJS 子进程中的记忆写入前整理与脱敏钩子。
// 不替换存储后端，不申请 capability，不访问文件、网络或 Node API。

"use strict";

function decision(value, entry = null, reason = null) {
  emit({ decision: value, entry, reason });
}

if (request.action !== "memory.remember.before") {
  decision("deny", null, "unsupported hook action");
} else {
  const entry = request.payload.entry;
  const text = String(entry.text ?? "").trim();

  if (!text) {
    decision("deny", null, "empty memory");
  } else if (/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/.test(text)) {
    // 不输出原始敏感文本；实际规则由宿主安全策略统一维护。
    decision("deny", null, "private key detected");
  } else if (/(?:api[_ -]?key|access[_ -]?token|password)\s*[:=]\s*\S+/i.test(text)) {
    decision("deny", null, "credential-like content detected");
  } else {
    const normalized = text.replace(/\r\n/g, "\n").replace(/[ \t]+/g, " ");
    const originalTags = entry.tags || [];
    const tags = [...originalTags];

    if (/我喜欢|我偏好|prefer/i.test(normalized)) tags.push("preference");
    if (/决定采用|最终选择|decided to/i.test(normalized)) tags.push("decision");

    const uniqueTags = [...new Set(tags)];
    const changed = normalized !== text || uniqueTags.length !== originalTags.length;

    if (changed) {
      decision("modify", {
        kind: entry.kind,
        text: normalized,
        tags: uniqueTags,
      });
    } else {
      decision("allow");
    }
  }
}
