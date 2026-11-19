# design.md 最终验收报告

> 验收方：左都御史（zuodu-yushi）。验收日期：2026-11-18。
> 验收对象：`docs/agent-platform-design/design.md`（850 行，16 章+附录，工部尚书产出，大理寺卿三轮核验放行版）。
> 验收基准：用户四条硬需求原话——①② m00001（多账号绑定 / 允许编排）、③ m00149（配置免重启热更新）、④ m00163（mrb.cr 嵌 mruby 插件机制）；流程要求 m00001「调研完毕先出整体设计、方案，等我过目」。
> 分工声明：大理寺卿验「事实真不真」（review/verification.md 三轮：通过→有条件通过 I1-I3→修复点验放行，留观察项 O1）；本官验「需求满不满足」，以用户需求为律，按律弹劾。
> 方法：只读验收。design.md 850 行全文通读；verification.md 381 行三轮记录复核；文件系统实测 2 项（越权检查+引用完整性）；4 处专章内部逻辑独立抽查；未运行代码、未改被验文件。
> **版本说明（2026-11-19）**：本文仅验收 2026-11-18 的 850 行版本。现行 §12 已改为裁剪 mruby 子进程、manifest/JSON-like 协议与 `.sebas-plugin` 包生命周期；本文中 `register(api)`、独立 mrb_state、mrb_close 重建及待决项均为当时快照，不再作为实现依据。

---

## 一、总结论

**通过。弹劾缺陷 0 项。**

- 四条硬需求逐条回对：**4/4 实质满足**（有具体机制、有数据结构/流程/验收条目，非口号；用户原话引用逐字准确、无曲解）。
- 基础要求：**3/3 落点**（Hermes/OpenClaw/Pi 对照来源齐备；Crystal 语言特点贴合且有实证；autobot A1-A10 承接表完整）。
- 方案完备性：**达标**（M0-M3 路线图有排期依据与可测验收；附录 5+1 待决策项完整；§15.1 未验证 13 条如实列出，「没验说没验」）。
- 弹劾检查：**无越权、无夸大、无漏项**。
- 独立抽查 4 处专章内部逻辑：**均自洽可落地**；另独立复核 O1 观察项（已闭环）与第一轮 S1-S6 修复状态（五处全落地、一处极轻微残留）。
- 附呈报建议 4 条（第七节，不阻塞验收）。

---

## 二、四条硬需求逐条回对

### ① 同渠道多账号并存 → §5 专章（L224-331）＋§3 概念模型（L75-182）

**判定：满足（实质设计）。**

- **原话引用**：L17「同时绑定多个比如 email、多个企业微信、多个 Lark 等等账号」——与 m00001 逐字一致。
- **数据结构**：Account / Agent / Binding 三正交概念模型（§3.1 L79-87）；配置树 `channels.<type>.accounts[]` **数组结构**（§3.4 L107-180），YAML 实例含 email×2（personal-gmail/work-outlook）、wecom×2（company-a/company-b）、lark×2（feishu-main/lark-intl）六账号并存——「账号数」不硬编码进任何渠道实现，多账号是结构原生能力。
- **流程/机制**：每账号监督 fiber 生命周期状态机（§5.1 L226-244：connecting→online⇄backoff→disabled/degraded，五项职责清单）；TokenProvider 统一抽象按账号缓存+临期提前刷新+失效重取（§5.3 L259-275）；限流桶按 `(账号, 目标)` 维度（§5.3.1 L277-287，三家渠道限流数字齐备）；接收侧两形态归并，回调型共享监听器按 `/cb/<channel>/<account_id>/` 前缀路由、各账号独立 secret 验签（§5.2 L246-258）。
- **防串扰闭环**：会话键含账号维度 `agent:<agent_id>:<account_id>:<channel_type>:<peer>`（§3.3 L100-106，修复 autobot B4 同渠道跨账号撞车）；企微 receiveid(corpid) 校验防跨企业混串（L311）；飞书/Lark 双主体 base_url 入账号配置（L328-330）。
- **验收条目**：M1「同渠道 N 账号并存互不串扰（两企微账号同 chat_id 不撞会话）」（L750）。
- **「等等」开放性**：架构图「…（可插拔扩展）」（L29）+ `abstract class ChannelAdapter` 扩展点（L210、§13 L696）承接未来渠道，无硬编码三渠道之弊。

### ② 用户可编排 → §7 专章（L360-468）

**判定：满足（实质设计）。**

- **原话引用**：L18「允许用户进行编排」——一致。
- **统一模型**：触发→条件→动作三段式为唯一原语，cron（At/Every/表达式三态）/消息事件/账号事件/审批回执/webhook 五源归入统一触发模型（§7.1 L362-374）。
- **执行语义**：效应三明治+持久 Task 状态机（§7.2 L376-384：意图先落库→phase checkpoint→结果落库，崩溃从最后 checkpoint 续跑）；幂等三件套（requestId exactly-once / replay 显式二分未标注不重跑 / memo first-write-wins）+ 发信幂等键 `send:${account_id}:${msg_uuid}` + restartLimit=5 崩溃循环防护（§7.3 L386-397）。
- **治理机制**：lease+过期回收+token 预算熔断+append-only 事件账本（§7.4 L399-403）；人工审批节点（超时 300s 即拒/无人值守默认 deny/hardline blocklist 不可 override/看不全的命令只给 Deny，§7.5 L405-411）。
- **DSL 实例**：两条完整 YAML workflow（§7.6 L413-465）——inbox-triage（事件触发+条件谓词+subagent+显式出站账号+幂等键）与 weekly-report（cron 触发+审批节点+budget_tokens），idempotency_key/approval/max_concurrent_key 均有实际用法示范。
- **管理面闭环**：workflows CRUD + runs.list/get/replay/cancel（§9.2 L520）；M2 验收「崩溃重放幂等/审批超时 deny 实测/预算熔断/runs 回放」（L751）。

### ③ 配置免重启热更新 → §11 专章（L575-627）

**判定：满足（实质设计，调研指令已履行）。**

- **原话引用**：L577「在深度使用 Hermes 的过程中，我对于修改了配置之后就要重启 gateway 感到十分厌烦，请调研 crystal 中如何不重启热更新配置」——与 m00149 逐字一致。
- **「调研 crystal 中如何」指令履行**：Crystal 特定机制逐一落点——`Atomic(Config)` 整根换引用（含 Atomic#swap 详注「T cannot contain any reference types」歧义如实注明、以 compare_and_set/get/set 可用清单为准，L591）；`naqvis/file_watcher` 选型（Windows ReadDirectoryChangesW / Linux inotify 原生后端+失败降级轮询，L589）；Signal.trap 在 Windows 抛 NotImplementedError → IPC reload 为 Windows 主通道（L588）；YAML 深合并无可靠 shard（stdlib #6791 拒收）→ 自写 ~20 行+数组整体替换语义（L623-624）；autobot cron `reload_if_changed` 先验后换先例（L590）。
- **机制**：四正交件（§11.2 L585-593：①触发双通道+轮询兜底+去抖 ②先验后换校验失败保旧 ③Atomic 整根换引用 ④每 turn 配置快照消费纪律）；组件重应用矩阵（§11.3 L595-605：纯数据热换/渠道凭据保守换法/账号增删=监督体 fiber 启停/端口类明确标 restart）；可直接落地的代码骨架（§11.4 L609-622）；管理面契约 config.reload / config.status（§9.2 L525）。
- **痛点回应对位**：Hermes 无热重载四证据链（issue #48693 等，L580）直接锚定用户「厌烦」的来源；OpenClaw reload 默认 hybrid 为正面教材（L581，证据局限已双处标注）。
- **验收条目**：M1（L750：运行中改配置不重启进程生效 / 配置写坏保旧运行并报警 / 改监听端口得到「需重启」明确提示）。

### ④ mrb.cr 嵌 mruby 插件机制 → §12 专章（L630-682）

**判定：满足（实质设计，调研指令已履行）。**

- **原话引用**：L632「为了能更方便的扩展 bot 的能力，我希望有一定的脚本能力，可以利用 mrb.cr 嵌入 mruby 来进行扩展，调研其他 bot 的插件机制是如何运作的，看看我们如何设计插件机制」——与 m00163 逐字一致。
- **「调研其他 bot 的插件机制」指令履行**：§12.5 四要素表（发现/契约/能力注册/生命周期隔离）× 四家对照——OpenClaw `definePluginEntry` manifest+register 形态、Hermes `plugins validate` 校验思想、ZeroClaw 弃插件市场教训（ClawHub 41.7% 含漏洞）、cinch 常量加载无卸载反例（L667-676），完整对照表见热更新笔记 §8d。
- **机制**：mrb.cr 三条硬约束入契约（§12.2 L640-646：单 State 线程亲和/JSON-like 传值/GC arena 显式管理）；**沙箱三闸**（§12.3 L648-658：①gembox 裁剪剔除 mruby-io/mruby-socket→脚本层无文件网络 IO ②allocf 覆写内存配额 ③宿主 API 白名单 `register(api)`，不依赖 $SAFE）+ watchdog 超时过渡（无执行配额的现成事实如实标注）；**热重载=整 VM 实例替换**（§12.4 L660-665：RiteVM 无模块卸载→mrb_close→新建 state→重 load；每插件独立 mrb_state 故障隔离；先验后换与 §11 共用管线）。
- **安全衔接**（I2 修复落点）：插件工具默认 `risk: high`、走 §10.3 审批链+§4.1 工具注册表同规格登记、hardline 不可被插件 override；钩子/定时统一映射为 §7.1 触发模型扩展事件源、插件不自建调度循环（L678-681）。
- **验收条目**：M3（L752：watchdog 拦死循环不卡宿主/崩溃只重建该 state/改脚本热重载生效）。

---

## 三、基础要求回对

1. **学习 Hermes / OpenClaw / Pi 架构逻辑（有对照来源）**：✅。文档头 L4 声明依据六份调研笔记（+L577 第七份热更新笔记）；§16 对照表 **41 条**「设计决策→笔记依据」逐条可溯（L798-840）；执行摘要 L17-20 每条硬需求注明先例（OpenClaw §3 三概念 / Hermes RoutingIdentity / Pi §2/§4 / 热更新笔记 §0-§8）。大理寺卿第一轮抽验 42 条（Hermes 16 / OpenClaw 14 / Pi 12）全部与笔记一致，本官复核未见反向证据。
2. **贴合 Crystal 语言特点**：✅。§4.2 映射表（L201-214）九行特性（fiber+spawn / buffered Channel / select+timeout / 编译期宏 / union+case in / abstract class / record 值语义 / typed rescue 转值 / 无限重连惯用法 / 显式消息传递替代隐式全局态）——每行有具体模块场景+autobot 实证行号；诚实承认语言限制而非虚构特性（L215 无 JS Proxy→op-list 应对；L588 Windows Signal.trap 限制；L644 单 State 线程亲和与 Crystal 单线程调度兼容）。大理寺卿 2.5 项确认无与 Crystal 语言事实相悖的说法。
3. **参考 autobot（A1-A10 承接表）**：✅。§13 L728-742 承接表十件全列，每件有去向+改造点（A1 单实例→实例池 / A3 总线加账号维度 / A4 会话键加账号+SQLite+JSONL 双写 / A5 巩固改用 agent 绑定 provider / A7 SKILL.md 升格主扩展通道 / A9 注册表加 replay/risk 字段 / A10 cron owner 加账号维度）；B 系列教训全部消化为设计约束（B1/B2 账号数组结构、B3 per-session worker 池替代全局单 Loop、B4 会话键、B8 subagent 信号量默认 3、B10 keyring）。大理寺卿 2.3 项 8 处源码行号实抽全部命中。

---

## 四、方案完备性

- **M0-M3 路线图**（§14 L745-756）：✅。四期各含内容清单+可测验收要点（M0 强制杀进程续跑+发信幂等键；M1 多账号+热更新双验收；M2 编排四项实测；M3 协作+插件三项实测）；排期依据有论证（L754：热更新排 M1 因「加账号」本身是热更新矩阵一行，账号体系与重载割裂则用户必烦；插件排 M3 因可选模块后置、M0-M2 扩展由 SKILL.md 承接）。
- **待用户决策项**：✅。附录（L844-850）5 条——平台命名 / MVP 首渠道（建议 email）/ Gmail 路线（GCP vs 应用专用密码）/ 审批默认模式（manual vs smart）/ 插件 API 首批暴露能力；第 5 条内嵌 +1 项（「另：插件注册工具默认 risk: high……能否调低 risk 级别待用户定夺」，L850）。**「5+1」结构完整**。
- **未验证清单**：✅。§15.1（L762-776）实数 **13 条**连续（1-13，编号无跳号），每条注明来源与补研方向——企微 AIBot 主动发消息 API 未逐页核对 / Gmail IDLE 社区报告未实测 / Gmail 15 连接第三方引用 / file_watcher Windows 未冒烟 / Atomic snippet 未编译 / mrb.cr 84/0 本地未提交 / OpenClaw runbook 仅镜像互证 / fault isolation 页未取正文等，均如实标注。「没验说没验」达标。
- **风险与取舍**：§15.2 七条架构风险（fiber 数量未压测、热更新纪律靠评审非运行时强制等）+ §15.3 三条已知代价（条件 DSL 不图灵完备、不做多人鉴权、A2A 留未来）如实列出，无回避。

---

## 五、弹劾检查

1. **越权（写代码 / 改 src）**：**无**。文档头 L3「本文档为调研后的整体设计草案，未动任何代码；用户未授权前不进入实现」；§13 标题即「src/ 布局**草案**」；§11.4 / §5.3 的 Crystal 片段为设计骨架与抽象接口签名，非实现。**本官实测**：`src/platform/` 目录无任何文件（glob 零命中，见 §八）——「未动代码」声明属实。verification.md 三轮均确认写入范围仅 review 文件。
2. **夸大（把设计说成已实现）**：**无**。L3 状态声明与全文行为一致；mrb.cr 全量 spec 84/0 照标「本地未提交状态」（L642+L773 双处，无升格）；§14 L756「本期仅设计不涉及」明示门禁仅适用后续实现；§15.1 十三条未验证无一条被正文当确证事实引用（大理寺卿两轮专项检查+本官复核一致）。
3. **漏项（用户提到但文档未覆盖）**：**无**。四条硬需求各有专章；③④内含的「请调研」指令均有对应调研产出（Crystal 热更新机制调研 / 四家 bot 插件机制对照）；流程要求「先出整体设计、方案，等我过目」与产出物形态（设计文档、零代码）吻合；①的「等等账号」开放性由可插拔 ChannelAdapter 承接。用户原话无被缩小、被改写、被曲解之处。

**弹劾清单：空（0 项）。**

---

## 六、独立抽查（4 处专章内部逻辑）

1. **① 路由 × 账号增删闭环**：✅ 自洽。§11.3 账号增删 = 监督体 fiber spawn/drain（L602）与 §5.1 生命周期状态机（disabled 用户停用）兼容；删账号防 binding 悬空由 validate!「binding 引用的账号必须存在」（L626）+ fail-closed 保旧（L617-621 骨架 rescue）闭环——删账号留悬空 binding 时校验失败保旧配置，行为可预期；无匹配 binding 丢弃+审计日志（L97）兜底。热更新与多账号两章合流无裂缝。
2. **② 三段式 × lease × 幂等**：✅ 自洽。lease 超时回收重派后，requestId exactly-once 返回原结果不重跑（L390）——回收与幂等不冲突；restartLimit=5（L396）封死 resume-再崩循环；审批回执作为触发源（L372）与审批节点状态机 pending→approved/denied/timeout（L406）双向闭环；无人值守 fail-closed 与审批超时 deny 方向一致。
3. **③ 四正交件 × 矩阵 × 契约**：✅ 自洽。Windows 无 SIGHUP → IPC reload 主通道（L588）与 §9.2 config.reload（L525）互指闭环（I3 修复落位）；端口类 restart 矩阵行 ↔ config.status 的 restart 待生效项 ↔ M1 验收「改端口需重启提示」三向呼应；代码骨架用 `CONFIG.set` 避开 Atomic#swap 详注歧义方法（L615 vs L591），骨架与声明一致。
4. **④ 三闸 × watchdog × 审批**：✅ 自洽。三闸管静态能力面（编译期裁剪 IO / 内存配额 / API 白名单），watchdog 管动态死循环（L658），静态+动态互补无重叠漏洞；插件 IO 需求经宿主 API 白名单代理 → 收进审批/审计面（与 §10.3 层 4「精确控制加载」兼容）；插件工具默认 risk:high 与 §10.1 fail-closed 总原则同向（L680）。
5. **O1 观察项独立复核**：**已闭环**。L850 现文含「另：插件注册工具默认 `risk: high`（§12.5 安全语义），插件（或用户配置）能否调低 risk 级别待用户定夺」——§12.5 L680 的挂起点声明与附录本体已同步。大理寺卿点验报告所据文本早于此版；本官实测当前 850 行版无此缺口，O1 不再成立。
6. **S1-S6 修复状态独立确认**（超出大理寺卿点验范围的增量复核）：S1 L89「简化采用 OpenClaw 层级」✅；S2 §4.2 表主体已补路径前缀（L205 `cli/gateway.cr:76`、L206 `channels/manager.cr:49-61`、L489 `agent/subagent.cr:83-85` 等），残留 3 处渠道文件裸名（L207 `auth.cr:102-108`、L213 `zulip.cr:44-60`/`slack.cr:41-64`）——极轻微，不影响大理寺卿已验证的行号正确性；S3 L506「模式集之子集，剔除 none/trusted-proxy（个人平台无需）」✅；S4 L749「强制杀进程（POSIX kill -9 / Windows taskkill /F）」跨平台表述 ✅；S5 L477「配置项 `bot_loop_guard.max_hops`，默认 4」✅；S6 L394「Pi 笔记推论 §7.5」/ L220「Pi 笔记推论 §7.8」✅。六处修复五处全落地、一处极轻微残留（S2 残名）。

---

## 七、呈报建议（供首辅向用户特别说明）

1. **附录 5+1 待决策项须显列表呈报**：平台命名、MVP 首渠道（建议 email 先行）、Gmail 路线（GCP 项目 vs 应用专用密码过渡，涉及个人运维意愿）、审批默认模式（manual vs smart）、插件 API 首批暴露能力（最小面=注册工具/钩子/定时 vs 更强能力）、插件工具 risk 调低权——六项均待用户定夺，是「等我过目」环节的实质决策点。
2. **§15.1 十三条未验证须如实传达**：重点三条——企微 AIBot 主动发消息 API 未逐页核对（M1 前必补研）、mrb.cr 84/0 为本地未提交状态（M3 前须复核提交/CI）、OpenClaw reload 细节仅两镜像互证（未逐字官方页）。用户应知道哪些设计结论建立在待补研证据之上。
3. **一个解读点宜随附说明**：§7.6 weekly-report（cron 触发）显式配 `approval: manual, timeout 3600`，与 §7.5「cron 触发的无人值守场景危险动作默认 deny」的关系为「显式配置覆盖默认值，且超时仍 deny（fail-closed 保持）」——逻辑自洽，但文档未明说覆盖语义；用户过目时若问，按此口径解释即可。
4. **M1 是验收密度最高的一期**（多账号①+热更新③双专章合流）：其三条验收——同渠道两账号同 chat_id 不撞会话、运行中改配置不重启生效、配置写坏保旧报警——正是用户痛点①③的直接验收项，建议呈报时点明此对应关系。

---

## 八、验收方法与证据索引

- design.md 850 行全文通读（分段 1-624 / 625-850），本报告所引行号以当前 850 行版为准。
- review/verification.md 381 行三轮记录通读复核；对 O1 与第一轮 S1-S6 修复状态做了独立增量复核（本报告 §六.5/§六.6）。
- 文件系统实测（glob）：`src/platform/**` 零文件（越权检查）；`docs/agent-platform-design/**/*.md` 实得 10 个文件——design.md + review/verification.md + research/ 七份笔记，与 design.md L4（六份）+ L577（热更新笔记第七份）声明吻合。
- 未运行任何代码、未执行任何命令、未修改 design.md / research / verification（写入范围仅本文件）。
- 工具预算：7 次调用（read×3 + glob×2 + write×1 + 回报×1），任务书上限 ≤15 达标。

---

**验收结论：通过。** 四条硬需求 4/4 实质满足，弹劾 0 项，呈报建议 4 条。可呈报用户过目。
