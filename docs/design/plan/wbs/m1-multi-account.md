# development-plan M1 · 多账号完备 + 配置热更新（19.5–30 pd）

> 导航：[设计总览](../../design.md) ｜ [文档索引](../../README.md) ｜ [计划总览](../../development-plan.md) ｜ 上一节：[M0](m0-mvp.md) ｜ 下一节：[M2](m2-orchestration.md)

### M1 · 多账号完备 + 配置热更新——估时合计 19.5–30 pd

**M1-WP1 账号数组 + binding 路由**（2–3 pd）
- 目标：`channels.<type>.accounts[]` 数组化+most-specific 路由成立。
- 范围：`config/` schema 数组化（宏样板升级）；`routing/binding.cr` 纯函数路由表（exact peer>…>fallback 层级 [来源: design.md §3.1]）；无匹配即丢弃（fail-closed [来源: design.md §16#3]）。
- 交付物：路由模块+路由决策表 spec（层级每级至少一用例）。
- 依赖：M0-WP8（M0 门禁通过）。
- 验收：**同渠道 N 账号并存互不串扰——两企微测试账号同 chat_id 各归各会话**（§14 M1 验收第 1 条 [来源: design.md §14]）。
- 风险：路由纯函数化后快照替换与热更新交叠，须先做 WP1 再动 WP8。

**M1-WP2 账号监督体**（1.5–2.5 pd）
- 目标：fiber-per-account 生命周期监督。
- 范围：`supervisor/` 监督 fiber、断线指数退避（autobot 无限重连惯用法 5s→60s [来源: autobot 笔记 §9 无限重连惯用法 slack.cr:41-64]）、健康上报入 TUI。
- 交付物：监督器+断线注入 spec。
- 依赖：M1-WP1。
- 验收：杀掉渠道连接后监督体按退避序列重连；账号下线状态在 TUI 可见。
- 风险：无实质风险。

**M1-WP3 TokenProvider 全量实现**（2–3 pd）
- 目标：三渠道统一 token 生命周期。
- 范围：`channels/common/token_provider.cr`：缓存+提前刷新+失效重取 [来源: design.md §16#8]；企微有效期内重复获取返回相同 token 的缓存语义；换 secret 保守做法=失效标记+TTL 自然过期（≤2h）[来源: design.md §15.1.9]。
- 交付物：TokenProvider+注入式 spec。
- 依赖：M1-WP1。
- 验收：**token 提前刷新与失效重取**（注入 401 后自动重取并重放请求一次）（§14 M1 验收第 3 条 [来源: design.md §14]）。
- 风险：企微「提前失效」行为未验证 [来源: design.md §15.1.9]——保守做法不依赖未验证行为。

**M1-WP4 企微渠道**（3–5 pd）
- 目标：AIBot 长连接主路+自建回调备选。
- 范围：`channels/wecom/`：aibot_longconn（免公网主路）、crypto.cr 自实现 AES-256-CBC+SHA1（**对照官方测试向量对称测试**——15.1.6 前置 [来源: design.md §15.1]）、app_callback 备选（receiveid 校验防跨企业混串+msgid 排重+5 秒响应）。
- 交付物：企微适配器+加解密向量 spec+双账号集成测试。
- 依赖：M1-WP3（token）；外部：企微测试企业+应用创建就绪（E 节）。
- 验收：**receiveid 校验**——构造跨企业密文被拒（§14 M1 验收第 2 条 [来源: design.md §14]）；双账号同 chat_id 收发路由正确。
- 风险：**企微智能机器人主动发消息 API 未逐页核对**（15.1.1 [来源: design.md §15.1]）——WP 开工首日 0.5–1 pd 逐页核对+10 行 demo；若 API 形态与笔记不符，回调备选升级为主路（估时内含回调完整实现，不扩期）。

**M1-WP5 飞书渠道**（2–3 pd）
- 目标：WS 长连接（自建应用）。
- 范围：`channels/lark/ws_longconn.cr`：事件 id 排重、3 秒处理、≤50 连接限制内单连接；**base_url 入账号配置**（飞书/Lark 账号体系独立 [来源: design.md §16#11]）。
- 交付物：飞书适配器+排重 spec。
- 依赖：M1-WP3；外部：飞书自建应用就绪。
- 验收：两飞书账号（或一飞书一 Lark 不同 base_url）事件各自入会话不串扰；重复事件 id 不二投。
- 风险：token Header 4KB 上限（15.2.19 [来源: design.md §15.2]）——HTTP 客户端配置显式放宽并记录。

**M1-WP6 限流桶**（1–1.5 pd）
- 目标：(账号,目标) 维度建桶退避。
- 范围：`channels/common/` 限流桶：企微同成员 30/分、飞书同群 5/秒 [来源: design.md §5]。
- 交付物：桶+spec。
- 依赖：M1-WP4、M1-WP5（真实额度参数）。
- 验收：**限流桶触发退避**（模拟 429/频控响应后自动退避排队）（§14 M1 验收第 4 条 [来源: design.md §14]）。
- 风险：无实质风险。

**M1-WP7 凭据 keyring**（1.5–2.5 pd）
- 目标：凭据出明文。
- 范围：`keys/` 模块：OS keyring 或静态加密（(渠道类型,账号ID) 命名空间隔离 [来源: design.md §16#26]）+ 从 M0 明文 YAML 的迁移导入命令+脱敏日志。
- 交付物：keys 模块+迁移工具。
- 依赖：M1-WP1。
- 验收：配置树中无明文凭据；迁移命令幂等可重跑；日志 grep 不到 secret。
- 风险：Windows Credential Manager API 在 Crystal 的绑定需 FFI spike（0.5 pd 含估时内）[未验证]。

**M1-WP8 配置热更新四正交件**（4–6 pd）
- 目标：免重启改配置（用户硬需求③）。
- 范围：`config/reload` 管线：触发三通道（file_watcher 主路+mtime 1–5s 轮询兜底+IPC/HTTP reload 命令；**另含 POSIX SIGHUP 第三便利通道** [来源: design.md §11.2①]，Windows 无对应信号，该平台走 IPC/HTTP）；先验后换（复用 M0-WP2 校验器）；`Atomic(Config)` 整根替换 [来源: design.md §11.2]；组件重应用矩阵（路由/编排/allowlist/限流/provider key/凭据热换；账号增删=监督体启停+drain；端口类标 restart）[来源: design.md §11.3]；每 turn 快照纪律 lint。
- 交付物：reload 管线+矩阵各组件重应用 spec。
- 依赖：M1-WP1、M1-WP2、M1-WP7（凭据热换）；**前置冒烟须于本包开工前完成**（EX-W1-03 已排 W1：Atomic 编译冒烟+file_watcher Windows demo，E.2 节）。
- 验收：**§14 M1 热更新四条全过**：运行中加/删账号、改路由、换 provider key 不重启生效 / 配置写坏（YAML 错+binding 悬空引用）保旧运行并报警 / 改监听端口得到「需重启」明确提示 [来源: design.md §14]。
- 风险：`Atomic#swap` 详注歧义 [来源: design.md §15.1.8]——冒烟前置消除；企微换 secret 旧 token 失效行为未验证，采保守 TTL 路线不阻塞 [来源: design.md §15.1.9]。

**M1-WP9 HTTP 管理面**（2.5–3.5 pd）
- 目标：带鉴权 HTTP API+回调共享监听。
- 范围：`admin/http/`：与企微/飞书回调共用监听器 [来源: design.md §16#25]、账号/编排 CRUD 骨架、SSE 事件流；鉴权 token 模式（design.md §9 子集）。
- 交付物：HTTP 模块+鉴权 spec。
- 依赖：M1-WP1。
- 验收：未带 token 请求 401；回调路径与 API 路径同端口共存。
- 风险：无实质风险。
