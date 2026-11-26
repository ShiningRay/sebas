# design.md §15 风险与未决问题

> 导航：[设计总览](../design.md) ｜ [文档索引](../README.md) ｜ 上一节：[§14](14-roadmap.md) ｜ 下一节：[§16](16-sources.md)

## 15. 风险与未决问题（如实列）

### 15.1 关键依赖未验证（实现前须补研）

1. **企微智能机器人主动发消息 API**：官方接口文档页未逐页核对（渠道笔记未验证 #3）；AIBot 为较新形态，API 有变动风险。
2. **Gmail IMAP IDLE 不可靠**为社区长期报告（渠道笔记未实测）。**#23 已裁决定线**：Gmail 继续走 IMAP IDLE + 应用专用密码，以兜底轮询（5 分钟）+ 假活判定 + 指数退避兜住，切换 Gmail API（需 GCP 项目 + Pub/Sub）的触发条件见 [§5.4](05-multi-account.md)；真实 Gmail 的长期稳定性仍未实测。
3. **Gmail 15 IMAP 连接上限**：来源为第三方引用（Microsoft Q&A/Atlassian），未找到 Google 官方页（渠道笔记未验证 #7）。
4. **企微回调明文布局** `random(16B)+msg_len(4B)+msg+receiveid`：官方描述 + 多第三方实现一致，官方原理小节未逐字核对（渠道笔记未验证 #2）。
5. **飞书单个 API → 频控等级映射**：等级表已有，每个接口属哪级需控制台查询（渠道笔记未验证 #6）。
6. **Crystal 企微加解密自实现**：无官方库，AES-CBC/SHA1/Base64 需对照官方测试向量做对称测试（设计层面可控，实现未验证）。
7. **`naqvis/file_watcher` Windows 实测**：**已冒烟验证（2026-11-18，[review/smoke-ex-w1-03.md](../review/smoke-ex-w1-03.md)）**——watch 单文件路径零事件，须 watch 父目录+按路径过滤；编辑器原子替换（tmp+rename）产生 `Created(tmp)+Deleted(target)+Renamed(target)` 三连，`Deleted` 不得解释为配置被删，去抖窗口内按路径聚合判定；mtime 轮询兜底保留（热更新笔记 §9.3）。
8. **`Atomic(Config)` snippet 编译冒烟**：**已冒烟验证（2026-11-18，[review/smoke-ex-w1-03.md](../review/smoke-ex-w1-03.md)）**——reference type 全部方法（new/get/set/swap/compare_and_set）编译并运行正确，`Atomic#swap` 详注歧义消项；整根替换路线成立（热更新笔记 §9.4）。
9. **企微/飞书换 secret 后旧 access_token 强制失效行为**：未验证；热换渠道凭据若依赖「主动作废」需实测，保守做法=等 TTL 自然过期（≤2h）或维护失效标记（热更新笔记 §9.7）。
10. **mrb.cr 绑定可用，但运行形态已改为子进程**：本地复核 84/84，issue #1 修复已发布 0.2.0/0.2.1；进程内死循环 watchdog 硬边界见 §12.2。裁剪 mruby.exe 在本机 Windows 的链接 blocker 与恢复路径见 [review/m3-plugin-feasibility.md](../review/m3-plugin-feasibility.md)。
11. **Hermes SIGUSR2 reload（#48918/#54941）落地进度**：仅核到 2026-09 PR #66777 提及「在途」，当前是否合并未追（热更新笔记 §9.8）。
12. **OpenClaw runbook 正文未逐字**：docs.openclaw.ai/gateway/ fetch 仅返回导航目录；§11.1 引用的 reload 四模式细节来自 openclawlab.com 与 openclaws.io 两镜像搜索快照（同文互证，未逐字比对官方页）（热更新笔记 §9.1）。
13. **OpenClaw 插件 fault isolation / priority / parallelism 状态机细节**：hooks-plugins 状态机页未取正文；§12.5 生命周期设计未依赖其细节，仅作方向参照（热更新笔记 §9.2）。

### 15.2 架构与性能风险

14. **fiber 数量**：N 账号（连接+监督+心跳）× M 并发会话 worker × subagent——个人规模（≤20 账号、≤100 并发会话）理论可控，但**未做压力测试**（autobot 笔记亦未运行时验证队列行为）。缓解：worker/subagent 全局上限 + 每会话队列。
15. **飞书长连接非广播**：单机无碍；未来多实例部署每条消息只到一个 client，横向扩展受限（渠道笔记 b1 硬限制）——多实例是本期非目标，仅记录。
16. **SQLite 单写者**：单进程内写串行化；CLI 等旁路工具以只读方式访问（Pi readOnly 挂载模式）；若未来多进程，学 Hermes 恢复防呆而非重蹈（Hermes 教训 5）。
17. **3 秒/5 秒回调硬约束**：企微 POST 5 秒、飞书 3 秒、Gmail 无此约束——回调路径必须「验签+落库+入总线」即返回，业务全异步；落库写延迟需实测。
18. **出口 IP 共享**（企微可信 IP）：多企微账号共用出口 IP，云厂商浮动 IP 变更须同步各应用配置（渠道笔记 a6）。
19. **token Header 4KB**（飞书新版 JWT）：HTTP 客户端默认 header 上限需确认。
20. **热更新纪律绕过**：若有新代码绕过「每 turn 取快照」直接持有 Config 引用跨 turn，会出现半新半旧状态——靠代码评审/ameba 自定义 lint 规则约束（§11.2 ④ 是纪律不是运行时强制）。

### 15.3 设计取舍的已知代价

21. **v1 编排条件不做图灵完备**：仅声明式谓词（元数据匹配 + all/any/not 组合）——复杂逻辑引导用户写 subagent 工具而非 DSL 图灵完备（降低误配风险，能力边界明示）。
22. **不做 profile 之上的多人鉴权**：个人平台假设（Hermes non-goals 同款）；家庭/团队共用是未来项。
23. **A2A 不引入**：跨机协作留未来（旁证微软原则）；本期 agent 间原生消息已够用。
