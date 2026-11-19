# M1 门禁演练记录（design.md §14 M1 验收勾稽，2026-11-19）

> 环境：Windows 10 x64、Crystal 1.22.1。每条验收有可复现 spec；门禁三命令全绿（98 examples / ameba 0 / make release）。

## §14 M1 验收勾稽（L750 七条）

### 1. 同渠道 N 账号并存互不串扰 ✅

`crystal spec spec/routing/binding_spec.cr -e "separates same-peer traffic"`

- 两 email 账号同一 peer 各归各会话（session_key 含 account 维度 day one 就位）；
- 两飞书账号（feishu.cn vs larksuite.com 不同 base_url）事件各自入会话：
  `spec/channels/lark_spec.cr -e "isolates two accounts"`；
- 账号监督体重复凭据 park：`spec/platform/supervisor`。

### 2. receiveid 校验（防跨企业混串）✅

`crystal spec spec/channels/wecom_spec.cr -e "cross-tenant receiveid"`

- 构造跨企业密文（corp-aaa 加密、按 corp-bbb 校验）→ CryptoError "receiveid mismatch" →
  回调 403（fail-closed）。

### 3. token 提前刷新与失效重取 ✅

`crystal spec spec/channels/token_provider_spec.cr`

- 缓存命中（有效期内重复获取仅一次网络请求，企微语义）；
- 剩余 < 30min buffer → 提前刷新（不等过期）；
- invalidate() → 下次 token 重取（注入 401 后重取语义由渠道层调用 invalidate 承载）。

### 4. 限流桶触发退避 ✅

`crystal spec spec/channels/rate_limiter_spec.cr`

- burst 耗尽后 acquire 阻塞退避（计时断言 >200ms）；
- 上游 45009/429 → cool_down → 冷却窗口内排队，超时放弃；
- 桶按 (账号, 目标) 隔离；企微同成员 30/分、飞书同群 5/秒预设。

### 5. 运行中改配置（加/删账号、改路由、换 provider key）不重启生效 ✅

`crystal spec spec/platform/config/reload_spec.cr -e "swaps a valid config"`

- Atomic(Config) 整根换引用 → 新 agent（extra）即时可见（CURRENT.get）；
- 组件重应用矩阵（gateway.apply_config）：规则重建、provider 实例池 replace、
  账号增删经监督体 register/remove_account（drain 停止）；
- IPC `config.reload` 命令触发同管线（reload_spec -e "IPC"）。

### 6. 配置写坏保旧运行并报警 ✅

`-e "keeps the old config when YAML is broken"` + `-e "dangling binding references"`

- YAML 语法错（含行号报错）→ ReloadResult.accepted=false，CURRENT 保持旧配置；
- binding 悬空引用（agent 'ghost'）→ 先验拒绝，旧 binding 继续服务。

### 7. 改监听端口得到「需重启」明确提示 ✅

同 "swaps a valid config" 用例：port 18790→18791 的 reload 返回
`restart_required: ["gateway.http.port changed: restart required"]`（OpenClaw hybrid 子集语义）。

## 门禁三命令

| 命令 | 结果 |
|---|---|
| `crystal spec` | 98 examples, 0 failures |
| `./bin/ameba` | 0 failures（66 files） |
| `make release` | bin/sebas.exe 构建成功 |

## M1 期已落地 WP

WP1 路由 / WP2 监督体 / WP3 TokenProvider / WP4 企微回调+crypto / WP5 飞书 webhook /
WP6 限流桶 / WP7 keyring / WP8 热更新 / WP9 HTTP 管理面。

## 未竟项与外部依赖（不阻塞 M-gate 的口径）

1. **企微 AIBot 长连接主路**（§15.1.1）：主动发消息 API 未逐页核对——回调形态已完整落地，
   出站 send 返回 typed error 不静默；开工首日核对后补主路。
2. **飞书 WS 长连接形态**（§5.6 主推）：官方 WS 帧协议细节需对照官方 SDK 逐帧核对后实现；
   webhook 形态已协议完整。真实账号集成验收（两账号/真实收发）挂外部依赖 E.1/E.2/E.3
   （企微测试企业、飞书自建应用、测试邮箱均未就绪）。
3. **出站发送**（企微 message/send、飞书 im/v1/messages、email SMTP 真实投递）：协议客户端
   已实现（SMTP 全绿），渠道出站在无真实凭据下以 typed error 显式降级。
