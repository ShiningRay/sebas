# design.md §14 分期路线图

> 导航：[设计总览](../design.md) ｜ [文档索引](../README.md) ｜ 上一节：[§13](13-module-layout.md) ｜ 下一节：[§15](15-risks.md)

## 14. 分期路线图

| 期 | 内容 | 验收要点 |
|---|---|---|
| **M0 · MVP** | 单账号闭环：1 个 email 账号 + 1 个 agent；效应三明治持久层；基础工具（发消息/读邮件）；NDJSON TUI 最小面 | 收发消息全链路；**强制杀进程（POSIX kill -9 / Windows taskkill /F）后重启续跑**（对照 Pi 恢复演练建立自动化用例）；发信幂等键生效（重复投递不重发） |
| **M1 · 多账号完备 + 配置热更新** | 账号数组+binding 路由；企微智能机器人长连接、飞书 WebSocket；TokenProvider；限流桶；keyring 凭据；会话键账号维度；**热更新四正交件**（file_watcher 双通道触发 / 先验后换 / Atomic 换引用 / 组件重应用矩阵，§11） | **同渠道 N 账号并存互不串扰**（两企微账号同 chat_id 不撞会话）；receiveid 校验；token 提前刷新与失效重取；限流桶触发退避；**运行中改配置（加/删账号、改路由、换 provider key）不重启进程生效**；配置写坏（YAML 语法错/binding 引用悬空）保旧运行并报警；改监听端口得到「需重启」明确提示 |
| **M2 · 编排完备** | 触发→条件→动作 DSL；cron/事件/webhook 统一；审批节点（超时 deny/无人值守 deny/hardline）；lease+回收+预算；append-only 账本 | workflow run 崩溃重放幂等；审批超时 deny 实测；预算熔断；runs 回放与审计 |
| **M3 · 协作 + 插件脚本层** | 多 agent 定义与路由；message_agent + max_hops 防环；subagent 信号量；**裁剪 mruby 子进程插件层**（能力白名单+watchdog、manifest/JSON-like 协议、`.sebas-plugin` 包与生命周期，§12） | max_hops=4 拦截互发死循环；并发上限生效；subagent 崩溃后找回同一子任务；死循环可终止不卡宿主；崩溃只影响该次调用；开发脚本热重载生效；安装默认禁用、升级保配置/数据可回滚、被引用卸载拒绝、purge 需确认；22 个首版 hook 精确派发（gateway.start/stop 分别验证）、同步 gate deny、观察失败跳过 |
| **M4 · Fork/Join 影分身** | **fork/join 原语与汇聚**（fork 快照派生 N 分身 + expectations 表 + Join 三层回写 + 能力衰减默认只读，§8.4）；M4.0 定稿与吸收（纯文档）→ M4.1 最小闭环（只读分身 e2e）→ M4.2 写路径与审批接线 → M4.3 对话流自然 fork（前置 ReAct 工具循环）→ M4.4 模板库与会话生命周期治理（v0.2.0 发版闸） | fork e2e：分身并行跑通、回写不丢、键不漂移；L3 审批拦截 fail-open 为零（hardline 之外须 Center 语义拦截）；join 三层回写：冲突不自动 merge 进父裁决清单、partial 标注可见；能力衰减：默认只读分身无写路径、越界声明剔除可观测；父崩溃恢复续判、回写幂等；回收 GC 有人工确认（M4.4） |
| **M8 · 渠道补齐（v0.6.0）** | 把 Email 之外的渠道补到生产可跑：企微自建回调接线、企微 AIBot 长连接（§5.5）、飞书 WS 长连接（§5.6）、Slack Socket Mode；四渠道纳入管理面与热更新 | 同渠道 N 账号互不串扰（WeCom / Lark / Slack 各两账号）；长连接跑通且不新增公网 IP 依赖；出站真实可发；运行中增删改账号不重启生效；标准四条 + docs-check 全绿 |

> **2026-11-26 调整**：M1 的企微/飞书真机集成（原挂 E.1 未闭环）与 M8 原 Telegram 两张卡互换归属——企微、飞书迁入 M8，Telegram 迁入 M3 追加包（M3-WP7/WP8）。M5–M7 的期条目仍只在 [plan/schedule/m5-m7.md](../plan/schedule/m5-m7.md) 与 `plan/wbs/` 承载，本表暂未展开。

排期依据：热更新排 **M1**——「加账号」本身就是热更新组件矩阵的一行（账号增删=监督体 fiber 启停，§11.3），M1 核心验收要求账号数组「加了就生效」，四正交件必须同期落地（Hermes 无热重载的教训是「账号体系与重载割裂则用户必烦」）。插件层排 **M3**——可选模块后置：M0-M2 的扩展需求由 SKILL.md（A7）承接（§12.1 分工），主链路先稳。fork/join 排 **M4**——依赖 §8 协作层既有件（subagent 键先例、信号量、busy-interrupt 取消通道）与调度输入接口冻结（M4.1 开工条件 = 调度 WP1/WP2 已合或 admission/envelope 接口冻结，Q5 裁断）；语义定稿已随 M4.0 完成（[fork-join-semantics.md](../proposals/fork-join-semantics.md) 九问裁断 Q1–Q9）。

各期共同门禁：`crystal spec` + `./bin/ameba`（质量门禁现行权威为 [CONTRIBUTING.md](../../../CONTRIBUTING.md) 质量门禁节 + `Makefile` + `.github/workflows/ci.yml`；M4.1–M4.4 统一改用「调度四条」= `make format-check` + `make spec` + `make lint` + `make release`，Q7 裁断；M4.0 纯文档包以评审通过替代命令门禁，见 [gates.md](../plan/schedule/gates.md) B.3）。

**装配类验收口径**（M4x-Comm-WP3 #187，2026-11-26 起）：凡把既有构件接入生产装配路径的工作包，验收须含**生产可调用性与端到端可达证据**——spec 通过不等于生产可达。M3-WP3 教训：subagent 的信号量/找回经 spec 验收，生产装配从未接线，DSL 白名单面 `subagent.ask` 在 run 中途才失败。本口径与 [implementer-loop.md §2.3](../process/implementer-loop.md) 的前置完成标准同源。

**M3 追加包（2026-11-26）**：Telegram 渠道补位（long-poll 接收 + Bot API 发送）由 M8 迁入 M3 槽位，编号 M3-WP7/WP8，详见 [m3-collab-plugins.md](../plan/wbs/m3-collab-plugins.md) 的「M3 追加包」节。该追加不改写 v0.1.0 已发布的 M3 门禁结论，只新增轨道。
