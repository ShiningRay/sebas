# design.md §14 分期路线图

> 导航：[设计总览](../design.md) ｜ [文档索引](../README.md) ｜ 上一节：[§13](13-module-layout.md) ｜ 下一节：[§15](15-risks.md)

## 14. 分期路线图

| 期 | 内容 | 验收要点 |
|---|---|---|
| **M0 · MVP** | 单账号闭环：1 个 email 账号 + 1 个 agent；效应三明治持久层；基础工具（发消息/读邮件）；NDJSON TUI 最小面 | 收发消息全链路；**强制杀进程（POSIX kill -9 / Windows taskkill /F）后重启续跑**（对照 Pi 恢复演练建立自动化用例）；发信幂等键生效（重复投递不重发） |
| **M1 · 多账号完备 + 配置热更新** | 账号数组+binding 路由；企微智能机器人长连接、飞书 WebSocket；TokenProvider；限流桶；keyring 凭据；会话键账号维度；**热更新四正交件**（file_watcher 双通道触发 / 先验后换 / Atomic 换引用 / 组件重应用矩阵，§11） | **同渠道 N 账号并存互不串扰**（两企微账号同 chat_id 不撞会话）；receiveid 校验；token 提前刷新与失效重取；限流桶触发退避；**运行中改配置（加/删账号、改路由、换 provider key）不重启进程生效**；配置写坏（YAML 语法错/binding 引用悬空）保旧运行并报警；改监听端口得到「需重启」明确提示 |
| **M2 · 编排完备** | 触发→条件→动作 DSL；cron/事件/webhook 统一；审批节点（超时 deny/无人值守 deny/hardline）；lease+回收+预算；append-only 账本 | workflow run 崩溃重放幂等；审批超时 deny 实测；预算熔断；runs 回放与审计 |
| **M3 · 协作 + 插件脚本层** | 多 agent 定义与路由；message_agent + max_hops 防环；subagent 信号量；**裁剪 mruby 子进程插件层**（能力白名单+watchdog、manifest/JSON-like 协议、`.sebas-plugin` 包与生命周期，§12） | max_hops=4 拦截互发死循环；并发上限生效；subagent 崩溃后找回同一子任务；死循环可终止不卡宿主；崩溃只影响该次调用；开发脚本热重载生效；安装默认禁用、升级保配置/数据可回滚、被引用卸载拒绝、purge 需确认；22 个首版 hook 精确派发（gateway.start/stop 分别验证）、同步 gate deny、观察失败跳过 |

排期依据：热更新排 **M1**——「加账号」本身就是热更新组件矩阵的一行（账号增删=监督体 fiber 启停，§11.3），M1 核心验收要求账号数组「加了就生效」，四正交件必须同期落地（Hermes 无热重载的教训是「账号体系与重载割裂则用户必烦」）。插件层排 **M3**——可选模块后置：M0-M2 的扩展需求由 SKILL.md（A7）承接（§12.1 分工），主链路先稳。

各期共同门禁：`crystal spec` + `./bin/ameba`（工作区 CLAUDE.md 既有质量标准适用于后续实现，本期仅设计不涉及）。
