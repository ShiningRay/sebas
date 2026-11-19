// 伪代码：QuickJS 子进程中的记忆写入前整理与脱敏钩子。
// 不替换存储后端，不申请 capability，不访问文件、网络或 Node API。
// on_hook 与 emit 由宿主 runner 注入；manifest 已声明该钩子，
// 未在本次进程内登记的名称不会派发（§12.2 精确注册）。

"use strict";

function decision(value, entry = null, reason = null) {
  emit({ decision: value, entry, reason });
}

on_hook("memory.remember.before", (payload) => {
  const entry = payload.entry;
  const raw = String(entry.text ?? "");
  const text = raw.trim();

  if (!text) {
    decision("deny", null, "empty memory");
    return;
  }
  if (/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/.test(text)) {
    // 不输出原始敏感文本；实际规则由宿主安全策略统一维护。
    decision("deny", null, "private key detected");
    return;
  }
  if (/(?:api[_ -]?key|access[_ -]?token|password)\s*[:=]\s*\S+/i.test(text)) {
    decision("deny", null, "credential-like content detected");
    return;
  }

  const normalized = text.replace(/\r\n/g, "\n").replace(/[ \t]+/g, " ");
  const originalTags = entry.tags || [];
  const tags = [...originalTags];

  if (/我喜欢|我偏好|prefer/i.test(normalized)) tags.push("preference");
  if (/决定采用|最终选择|decided to/i.test(normalized)) tags.push("decision");

  const uniqueTags = [...new Set(tags)];
  // 与原始 entry 文本比较（标签按内容比较，先去重）：带首尾空白的输入、重复标签或新增标签都返回 modify。
  const changed = normalized !== raw || JSON.stringify(uniqueTags) !== JSON.stringify(originalTags);

  if (changed) {
    decision("modify", {
      kind: entry.kind,
      text: normalized,
      tags: uniqueTags,
    });
  } else {
    decision("allow");
  }
});
