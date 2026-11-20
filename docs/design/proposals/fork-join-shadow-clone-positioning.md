# Sebas 产品定位研判：弱化 Session + 轻量 Agent 团队 + Fork/Join 影分身

> **状态**：方向研判，未实施
> **日期**：2026-11-20
> **作者**：DimAgent（基于用户提议 + 既有记忆库 14 条 + 仓内 design.md）
> **关联**：a847c64e 定名 / 9431e0b4 M0 / 2ef8e2db 调度方案 / 1e4b0e4c TaskLedger / 9aeaccf5 Hermes busy 对照 / 76ec1aa0 并行漂移 / b21178e7 Agent-Native IM / 6fcbc22e Agent 长在 World

---

## 一、用户原始主张

1. **弱化 Session**：一般不让用户开一个没有上下文的新会话聊天。
2. **轻量创建 Agent/Bot**：让用户快速形成 Agent/Bot 团队。
3. **弱化 SubAgent，改用 Fork/Join**：当前聊天中需要并行时，从当前 Agent 复制一份带同样提示词上下文的 Agent Clone，任务结束后把过程 Join 回原 Agent（即"影分身"）。

---

## 二、竞品坐标

| 系统 | 并行机制 | 上下文给子体什么 | 结果如何回流 | 与影分身距离 |
|---|---|---|---|---|
| **Claude Code SubAgent** | `Task` 工具派生 subagent | 默认空提示词；可 `forkContext:"all"` 注入 transcript | 子代理最后一条 assistant 文本回主代理；过程不可见 | **最近**。fork 已实现，join 是"末条文本" |
| **OpenClaw / Hermes** | spawn subagent + busy queue + steer | 子 agent 独立 profile，可选隔离 | 子 agent 作为独立会话运行，结果由父 agent 拉取 | 中。还是"派员工"，不是"分自己" |
| **AutoGPT / CrewAI / LangGraph** | DAG 编排 + 角色卡 | 人工写 prompt 模板拼装 | 图节点输出汇总 | 远。是工作流不是分身 |
| **Devin / Cindy / Rakazo** | 每 bot 一台沙箱电脑 | 各自从零起步 | 不回流，bot 是独立人格 | 反向。多 bot 而非影分身 |
| **Erlang/OTP、Orleans** | actor spawn + 消息 | 不复制状态，actor 自治 | 消息回复 | 哲学同根但无 LLM 上下文概念 |
| **Git worktree + 多 Claude** | 同一 prompt 多开 worktree | 共享 prompt，文件系统隔离 | 人工 merge | 近但 join 是 git 层面 |

**核心结论**：「fork 全量上下文 + join 全过程回写」这一组合**目前没有成熟产品直接做**。Claude Code 的 `forkContext:"all"` 是最接近的半步，但只回末条消息。**这是真空地带，方向本身有差异化空间。**

---

## 三、三根轴拆解

### 轴 1：去 Session 化 → 常驻 Agent 即人格

| 维度 | 传统 ChatBot | 你的方向 |
|---|---|---|
| 心智模型 | 用户开 N 个 Session，上下文孤岛 | 用户面对 N 个 Agent，每个是连续人格 |
| 上下文 | 每个 Session 独立 | 所有进入 Agent 的消息自然带历史 |
| 类比 | 开新聊天窗口 | 找某人/找同事 |

**优势**
- 心智模型对齐 IM/同事/员工——不是开新聊天，而是"找某人"
- 历史自然延续，没有"上下文丢失"焦虑
- 与 Hermes busy queue、OpenClaw 单 Gateway 的人格化趋势一致

**劣势 / 风险**
- **上下文成本随时间线性膨胀**：常驻 Agent 必须靠 compaction / memory / 长期摘要，否则几个月后无人能付
- **人格与任务耦合**：今天让 Agent 写代码、明天管日历，常驻人格容易"身份漂移"，长上下文稀释专注度
- **冷启动悖论**：用户第一次用没有 Agent 可找，仍需"快速造一个 Agent"入口——Agent 创建轻量必须一起成立

### 轴 2：Agent/Bot 创建轻量 → 团队规模化

**优势**
- 把"配置"变成"克隆"——降低 90% 创建成本
- 用户可无脑复制：写代码 Agent、审查 Agent、运维 Agent……都是同一底子派生

**劣势 / 风险**
- **Agent 爆炸**：轻量创建 = 轻量产生垃圾。没有 GC 机制会快速失控（OpenClaw 多 profile 已吃过这亏）
- **同质化**：100 个克隆 Agent 提示词一样，团队是"100 个我"还是"100 个不同专长的成员"？分化机制未解决

### 轴 3：Fork/Join 替代 SubAgent → 影分身

**优势**
1. **零提示词工程**：克隆天然携带父 Agent 全部上下文，不用写"我要把哪些信息告诉子代理"——这是 SubAgent 最大隐性成本
2. **能力等价**：分身和本体能力一致，不会出现"子代理没有 X 工具"的挫败
3. **认知可合并**：Join 把过程回写，本体"记得自己做过"，而不是"听说别人做过"。SubAgent 模型下本体永远只是"听到汇报"——这是**质的变化**
4. **调试/审计友好**：每个分身有完整 trace，可独立回放
5. **符合直觉**：火影影分身的中文用户心智成本几乎为零

**劣势 / 风险**
1. **Join 语义难题**——回写什么？
   - 全量 transcript：上下文爆炸
   - 摘要：丢失细节，且摘要本身就是一个 LLM 调用
   - 结构化 result + 关键 checkpoint：需事先定义"什么算关键"
   - **倾向方案：分层 Join**——默认回写"结论 + 关键决策点 + 副作用清单"，全量 transcript 落盘可回溯但不进主上下文
2. **副作用冲突**：分身改了文件、发了邮件、改了数据库——Join 时这些副作用**已经发生**，回写只是"告知本体"。如果本体在分身运行期间也改了同一文件，没有自动 merge 方案，必须显式冲突处理（已有教训 76ec1aa0：并行 agent 同改仓库致事实漂移）
3. **Join 触发时机**：等所有分身？任一？超时？经典 `Promise.all/race/allSettled` 语义，agentos 的 TaskLedger 期望机制已想清楚——直接复用
4. **嵌套 Fork**：分身再分身，A 派 B 派 C，C Join 到 B 还是 A？建议**只允许一级 Fork**，分身不能再派分身
5. **成本不透明**：一次 Fork = 一次完整上下文拷贝（KV cache 命中可缓解但 prompt 费用照样付），用户可能没意识到 fork N 个就是 N 倍成本
6. **"影分身"暗示等价，但实际不等价**：分身是 fork 出去那一刻的快照，从 fork 开始本体和分身就分流了。NARUTO 里影分身解除时经验值合并是瞬时的，LLM 里 Join 是个真实成本

---

## 四、七个关键质疑

### Q1：Session 真的可以完全去掉吗？
- **反例**：用户想问一个"一次性、与任何 Agent 人格无关"的问题（查个语法）。让他必须先找个 Agent 再问，是负担。
- **建议**：保留"匿名/临时会话"作为兜底入口，包装成"问前台"，前台 Agent 接待后决定转给谁——Session 概念被隐藏而非消失。

### Q2：Agent 团队的"团队感"从哪来？
- 100 个同 prompt 的克隆不等于团队，是复印机。团队需要**分工 + 互补 + 协作协议**。
- **建议**：Agent 创建模板库（"代码审查员""发布工程师""Sentry 值班员"），每个模板在克隆基础上加一层"人格 patch"。轻量创建 + 真正分工。

### Q3：Fork 的触发权在谁？
- 用户手动 Fork？Agent 自主 Fork？编排引擎 Fork？
- **风险**：Agent 自主 Fork 容易指数爆炸（AutoGPT 老毛病）
- **建议**：M0 只允许用户显式 Fork + 编排 DSL 声明 Fork，**禁止 Agent 自主递归 Fork**

### Q4：Join 冲突的仲裁者？
- 分身 A 说"删 X 文件"，分身 B 说"保留 X 文件"，Join 到本体时怎么办？
- **建议**：副作用分类（只读 / 文件写 / 网络写 / 不可逆操作），不可逆操作必须经本体审批才能由分身执行——分身对不可逆操作默认只有"建议权"

### Q5：人格连续性 vs 任务多样性
- 一个常驻 Agent 又写代码又回邮件又管日程，prompt 怎么写？
- **建议**：Agent = "基底人格" + "可装卸的角色卡"。Fork 时可指定"以 X 角色 Fork"，相当于影分身可以穿不同衣服出去干活

### Q6：隐私与权限边界
- 分身继承本体全部上下文 = 继承全部 secrets 访问权。一个被 prompt injection 污染的分身会读到所有
- **建议**：Fork 时可声明**能力衰减**（"这个分身不准访问 prod 凭据"），默认衰减而非默认全开

### Q7：怎么避免变成"另一种 DAG 编排"？
- 如果 Fork/Join 只是语法糖，用户写的还是 DAG，定位就失败
- **建议**：把 Fork 的触发**绑在对话流里**而不是编排流里——用户在聊天中说"这件事帮我并行查一下三个方案"，Agent 自然分出三个影分身。**Fork 是对话的一等公民，不是 workflow 的节点**

---

## 五、与既有 Sebas 设计的兼容性

| 既有组件 | 兼容性 | 说明 |
|---|---|---|
| per-session FIFO（Pool） | ✅ 直接承接 | Fork 出去的 Agent 就是新 session |
| TaskLedger 期望机制 | ✅ 直接复用 | Join 就是 expectation 触发，mode: all/any/allSettled |
| 调度方案（queue/debounce/steer） | ✅ 无冲突 | Fork/Join 是正交维度 |

**需要新增**：
- `fork` 工具原语（携带上下文快照）
- `join` 期望类型（带 mode: all/any/allSettled）
- 分层 Join 回写器（结论 + checkpoint + transcript 落盘）
- 能力衰减声明

**建议命名**：原语叫 `fork` / `join`（POSIX 直觉），UI 层叫"影分身"（用户心智）。

---

## 六、落地路线图建议

| 阶段 | 内容 | 门槛 |
|---|---|---|
| **M0.5** | 写 `fork-join-semantics.md` 专定义 Join 语义矩阵（副作用类型 × Join 时机 × 冲突策略） | 文档评审 |
| **M1+** | 实验分支：一级 Fork + 只读分身 + 全量摘要回写，跑通最小闭环 | 三命令门禁绿 |
| **M2** | 放开文件写分身 + 副作用冲突处理 + 能力衰减声明 | 冲突场景 e2e |
| **M3** | 对话流内自然 Fork（用户说"并行查三个方案"自动分身） | 真实用户场景验证 |
| **M4** | Agent 团队模板库 + 角色卡 + 休眠/归档/回收 | 治理闭环 |

**过渡方案**：代码层不急着删 SubAgent——`forkContext:"all"` 本质上就是影分身雏形，可在现有 agent 工具上加 `fork: true` 参数作为过渡。

---

## 七、总评

**方向是对的，且是目前 Agent 平台的真空地带。** 但要避免三个陷阱：

1. **不要为去 Session 而去 Session**——把 Session 藏起来，而不是删掉。前台 Agent + 后台多 Agent 协作是更现实的形态
2. **影分身的难点不在 Fork，在 Join**——90% 的设计精力应该花在 Join 语义、副作用冲突、能力衰减上
3. **轻量创建 ≠ 轻量治理**——必须同步设计 Agent 的休眠、归档、回收机制，否则半年后用户面对 500 个 Agent 会崩溃

---

*记忆库已同步：rsrs 7893c196，挂在 a847c64e Sebas 定名下。*
