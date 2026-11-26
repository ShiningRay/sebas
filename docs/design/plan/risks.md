# development-plan E. 外部依赖与前置风险

> 导航：[设计总览](../design.md) ｜ [文档索引](../README.md) ｜ [计划总览](../development-plan.md) ｜ 上一节：[D](coverage.md)

## E. 外部依赖与前置风险

### E.1 外部依赖（用户侧动作，不在估时内）

| # | 依赖 | 影响的 WP | 就绪时限 |
|---|---|---|---|
| 1 | 测试邮箱（应用专用密码开启） | M0-WP4 / EX-W2-06 集成验收 | W1 期间 |
| 2 | 企微测试企业+自建应用/AIBot 创建+可信 IP 配置（出口 IP 共享注意 §15.2.18 [来源: design.md §15.2]）；2026-11-26 起由 #21 承载 | **M8.1-WP2 / M8.1-WP3**（原 M1-WP4） | M8 真机段前 |
| 3 | 飞书自建应用（WS 长连接仅自建应用可用 [来源: design.md §16#11]）；2026-11-26 起由 #22 承载 | **M8.1-WP4**（原 M1-WP5） | 同上 |
| 4 | ~~Gmail 路线决策~~ **已定（2026-11-26，E.1-4 / #23）**：继续应用专用密码 + IMAP IDLE / SMTP，不迁 Gmail API。兜底轮询、假活判定、退避口径与切换触发条件见 [spec/05-multi-account.md](../spec/05-multi-account.md) §5.4；只有触发切换才需要 GCP 项目 + OAuth 凭据 | M0-WP4 按密码路线收口；实现缺口由 **M8.1-WP6 / M8.1-WP7**（#239 / #240）承接 | 已就绪 |
| 5 | 调度轨 issue #9 WP1/WP2 已合或 admission/envelope 接口冻结（PR #32 已定型 policy/envelope/Store 单事务 admission；fork 入队为调度输入类型扩展——无渠道入站消息、无 sender/peer，Q5 迁就其接口）。注：WP1（contract+migration+纯函数状态机）已随 185e37b 合入 main，开工条件余 WP2 部分待满足 | M4.1 全期（ForkEnvelope 派发路径） | M4.1 开工前 |
| 6 | M4 语义/架构两提案文档评审（用户过目：fork-join-semantics.md + fork-join-shadow-clone-architecture.md） | M4.0-WP1 定稿 → M4.0-WP2 吸收回写 | M4.0 期内 |
| 7 | 插件演进 issue #24 启动条件（**引用不并卡**：见 [review/plugin-evolution.md](../review/plugin-evolution.md)；其 P3 常驻 Worker 与模板库仅留交叉引用） | M4.4-WP2 模板库 | 无等待（非阻塞） |
| 8 | 调度轨 #4/#5 完成或 `admit_session_input`/envelope 接口冻结（现状：store 侧 DDL 与函数已存在但**全仓零调用者**，gateway 未接线 [来源: 仓库:src/platform/store/store.cr:453]；与 E.1#5 同源，此处按提醒投递视角复列） | M5.2-WP2（提醒与工作输入共用 admission） | M5.2 开工前（M5-W4） |
| 9 | 真实只读测试账户：Google Calendar（OAuth 只读 scope）、Microsoft 365 租户（Graph Calendars.Read + Tasks.Read）、一个 CalDAV 服务端（如 Fastmail/Nextcloud 测试账号） | M6.2 真机段 / M6.4 验收 | **M6 开工前两周**（M6-W1 前） |
| 10 | 承诺与日历语义文档评审（M5.0-WP1 产出 `commitments-calendar-semantics.md`，用户过目） | M5.0-WP2 起全部包 | M5-W1 期内 |
| 11 | **写权限日历账户**（M7 用，与 E.1#9 的只读账户不通用）：一个专门的 Sebas 日历（Google 或 CalDAV 新建，不复用主日历）+ 该集合写 scope + 一个可清理的撤销验证日历 | M7.1-WP1 真机段 / M7.2 门禁 | **M7 开工前两周**（M7-W1 前） |
| 12 | Telegram BotFather 注册 2 个 bot（2026-11-26 由 M8 迁入 M3 轨道；尚无独立 issue） | **M3-WP8** | M3-WP8 开工前 |
| 13 | Slack workspace + 2 个 Socket Mode App | **M8.1-WP5** | M8.1-WP5 开工前 |
| 14 | 科学上网环境（仅本地实测；CI 走 mock） | M8.1-WP5 验收 | 同上 |

### E.2 §15.1 未验证项中影响 M0/M1 排期的前置冒烟（逐条挑出）

| 条目 | 处置 | 落点 |
|---|---|---|
| 15.1.7 file_watcher Windows 实测 | ✅ **已完成**（2026-11-18）：watch 须对父目录+路径过滤；原子替换为 Created+Deleted+Renamed 三连，去抖聚合；[smoke-ex-w1-03.md](../review/smoke-ex-w1-03.md) | EX-W1-03（结果回写 design.md §15.1.7） |
| 15.1.8 `Atomic(Config)` 编译冒烟 | ✅ **已完成**（2026-11-18）：reference type 全方法可用，详注歧义消项；[smoke-ex-w1-03.md](../review/smoke-ex-w1-03.md) | EX-W1-03（结果回写 design.md §15.1.8） |
| 15.1.6 企微 crypto 官方测试向量 | ✅ 已消项（M1-WP4 已交，`spec/channels/wecom_spec.cr` 覆盖；2026-11-26 复核 6 examples 全绿） | M1-WP4 → 装配与真机改由 M8.1-WP2 |
| 15.1.1 企微 AIBot API 未逐页核对 | **开工首日核对** 0.5–1 pd+demo；不符则回调备选升级（估时内含） | **M8.1-WP3**（原 M1-WP4） |
| 15.1.9 换 secret 旧 token 失效行为 | 保守做法（TTL 自然过期+失效标记）不依赖该行为，不阻塞 | M1-WP3 |
| 15.1.2 Gmail IMAP IDLE 不可靠 | **已裁决定线（#23）**：继续密码路线。设计的兜底手段（5 分钟轮询 + 假活判定 + 指数退避）**尚未实现**（见 §5.4 差距表），由 **M8.1-WP6**（#239）承接；真实 Gmail 长期稳定性仍未实测，按 §5.4「切换 Gmail API 的触发条件」监控 | M0-WP4 / **M8.1-WP6** |
| 15.1.10 mruby 运行形态与构建 | mrb.cr 84/84 甄别已完成；运行改为每动作子进程。本机新 mruby.exe 链接 blocker 未消项时 WP4~6 仍按降级条款交预研 | M3-WP4 |

不进 M0/M1 关键路径的其余未验证项（15.1.3 Gmail 15 连接、15.1.4 企微明文布局、15.1.5 飞书频控映射、15.1.11 Hermes reload 进度、15.1.12/13 OpenClaw 正文未取）不影响排期，实现到对应模块时按 design.md §15.1 原口径处置。[推演]

---

*（本文档为规划态：全部任务均为后续获授权执行时的验收标准，本文未执行任何代码工作；定名 Seneschal 已落盘（[naming.md](../naming.md)），推翻则按 design.md 附录 替换指引执行。）*
