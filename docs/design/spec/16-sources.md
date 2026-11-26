# design.md §16 调研来源对照表

> 导航：[设计总览](../design.md) ｜ [文档索引](../README.md) ｜ 上一节：[§15](15-risks.md) ｜ 下一节：[附录](99-open-questions.md)

## 16. 调研来源对照表（决策 → 笔记依据）

| # | 设计决策 | 依据（笔记 · 小节/条目） |
|---|---|---|
| 1 | Account/Agent/Binding 三正交 + most-specific 路由 | OpenClaw §3（三概念正交、17 渠道多账号、binding 层级）、§9；渠道笔记设计启示 1 |
| 2 | transport/runtime 双轴解耦（收信账号≠执行大脑） | Hermes §2（RoutingIdentity）、§8 借鉴 3 |
| 3 | 路由无匹配丢弃（fail-closed） | Hermes §2（路由到未服务 profile 即丢弃）、§8 借鉴 4 |
| 4 | 账号=配置树数组节点，不硬编码进渠道实现 | OpenClaw §3 启示；autobot B1/B2（三层锁死证据链） |
| 5 | 接收侧两形态归并，优先长连接 | 渠道笔记结论速览 + 设计启示 2；Hermes §4.2（两类平台二分接线） |
| 6 | 回调共享监听器 + URL 前缀路由 + 各自 secret 验签 | Hermes §4.2（port-binding 型 `/p/<profile>/` 模式） |
| 7 | 重复凭据 park 不崩溃 | Hermes §4.2（duplicate adapter 被 park） |
| 8 | TokenProvider 统一抽象 | 渠道笔记设计启示 3（三渠道 token 生命周期同构）+ a4/b3/c5 |
| 9 | 限流桶 (账号,目标) | 渠道笔记设计启示 4 + a7/b5/c2 |
| 10 | 企微 AIBot 长连接优先 / 自建回调备选（AES-CBC+receiveid+msgid 排重+5 秒） | 渠道笔记 a1/a2/a5/d3 |
| 11 | 飞书 WS 长连接（自建应用、3 秒、50 连接、非广播、事件 id 排重）/ base_url 入账号配置 | 渠道笔记 b1/b2/b4 |
| 12 | Email：IMAP IDLE（Gmail 与非 Gmail 同走，**#23 裁决定线**）/ XOAUTH2 为升级路径；15 连接；29 分钟重发；兜底轮询 5 分钟 | 渠道笔记 c1/c2/c3/c5；[§5.4](05-multi-account.md) |
| 13 | 会话键含账号+agent 维度 | autobot B4；OpenClaw §4.1（dmScope per-account-channel-peer 教训 5） |
| 14 | SQLite(WAL) 主存储 + working-set 内存模型 | Pi §2（存储后端/内存模型）、§6；OpenClaw §4.1（per-agent SQLite）；旁证建议（SQLite FTS5） |
| 15 | 记忆=人可读 Markdown + FTS5 检索层 | OpenClaw §4.2 借鉴 5；autobot A5；Hermes §3（FTS5 session search） |
| 16 | 编排=触发→条件→动作 + 持久 Task（效应三明治，拒绝事件溯源） | Pi §2；首辅定调 5 |
| 17 | 幂等三件套（requestId/replay 二分/memo）+ 发信幂等键 | Pi §4（含发消息必须幂等键的推论 §7.5）；渠道笔记（企微重试 3 次/飞书重推） |
| 18 | restartLimit 崩溃循环防护 | Pi §4 |
| 19 | lease+过期回收+预算+append-only 账本 | 旁证 §一.1（六坑迁移、队列型机制最值得抄）+ §二 映射表 |
| 20 | 审批：smart/manual/off + 超时 deny + 无人值守 deny + hardline + 看不全只 Deny | Hermes §6 层 2、§8 借鉴（审批细节级） |
| 21 | agent 间消息：fire-and-forget+署名+max_hops=4+回复不可再回复 | Hermes §4.3（Bot Mode 三件套） |
| 22 | subagent=被拥有的会话/任务 | Pi §3（ownership + scanConversations 找回） |
| 23 | subagent 并发信号量（默认 3） | autobot B8（无上限教训）；旁证 §四.3（放大器警告） |
| 24 | per-session worker 池替代全局单 Loop | autobot B3（`cli/gateway.cr:76` 串行证据）；旁证 §一.3 |
| 25 | 管理面双入口：NDJSON/IPC + HTTP（与回调共用） | 旁证 §一.6（无协议接不上教训）+ §一.7（NDJSON 已验证）+ §三.1；OpenClaw §8（webhooks 同端口） |
| 26 | 凭据 keyring/静态加密 + (渠道,账号ID) 命名空间 + 脱敏 + 轮换 | 渠道笔记 d1/d2；autobot B10 |
| 27 | fail-closed 贯穿 + 显式消息传递替代隐式 scope | Hermes §6/§8 借鉴 4、反面教训 2（contextvar 漏） |
| 28 | Windows 应用层 sandbox 策略 | 旁证 §三.5（无 bubblewrap，偏 ZeroClaw 路线） |
| 29 | 单二进制=差异化卖点 | Hermes 反面教训 1（双运行时之重） |
| 30 | A2A 留未来、内部原生消息 | 旁证 §一.1（微软原则）+ §二 |
| 31 | 不做云 SaaS/多用户、不做 OpenClaw 迁移 | 首辅定调 10；旁证 §三.7 |
| 32 | Crystal 机制映射（fiber/Channel/select/宏/union/abstract/record/rescue） | autobot §9 实证 14 条 |
| 33 | TUI 选型 termisu/自写，避开 AGPL crysterm | 旁证 §一.8（Crystal TUI 生态实测） |
| 34 | 配置热更新四正交件（触发双通道/先验后换/Atomic 换引用/每 turn 快照） | 热更新笔记 §0/§2-§5；autobot `cron/service.cr:275-290`（先验后换先例）、`loader.cr:152-166`（加载链复用） |
| 35 | 组件重应用矩阵；端口类标 restart（OpenClaw hybrid 语义） | 热更新笔记 §6/§7.1 |
| 36 | Hermes 无热重载=用户痛点根源（反面教材） | 热更新笔记 §7.2（issue #48693 等四证据链） |
| 37 | YAML 深合并自写 ~20 行 + 数组整体替换语义 | 热更新笔记 §5（stdlib #6791 拒收；deep-merge.cr 数组 TODO） |
| 38 | 插件层=每动作裁剪 mruby 子进程；激活=版本指针先验后换 | 用户确认的子进程修订；[m3-plugin-feasibility.md](../review/m3-plugin-feasibility.md)；mrb.cr 84/84 复核 |
| 39 | gembox/资源约束/能力白名单/watchdog；子进程不代替 OS 资源限制，不靠 $SAFE | 热更新笔记 §8b + 子进程修订 |
| 40 | manifest + JSON-like 协议 + `.sebas-plugin` 独立分发；不做市场 | 热更新笔记 §8d + 2026-11-19 用户确认的包与生命周期方案 |
| 41 | 热重载/激活与配置热更新共用触发-校验-换引用管线；配置/代码/数据分离；卸载保留数据；22 个首版 hook 精确派发 | 热更新笔记 §8e.3 + §12.5~§12.11；OpenClaw/Hermes/Pi hook 目录核实 |
