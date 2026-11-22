# Agent 分类与标签：元数据模型与管理面查询（Proposal）

> 状态：**Proposal**（2026-11-23；需求方裁决：双属性模型、配置+查询+IPC 范围、M4x 并行轨排期）。
> 关联：Agent 概念定义见 [core-concepts.md](../spec/03-core-concepts.md) §3.1；配置树见同节 §3.4；运行时代理见 [agents.cr](../../../src/agents/agents.cr)。
> 本文职责：定义 Agent 分类与标签的字段语义、校验规则、运行时暴露与管理面查询契约。实现计划由 issue 工作包承载，不写进本文。

## 1. 背景与问题

`Agent`（大脑）是 Sebas 的核心概念之一：人格 + 记忆 + 会话库 + 工具集 + 模型配置，不含渠道凭据。当前配置层 `AgentConfig` 只有 `model`、`provider_ref`、`persona_file`、`api_key`、`memory`、`tools`、`session` 七个字段（[schema.cr](../../../src/platform/config/schema.cr)）；运行层 `AgentInstance` 只有 `id`、`persona`、`memory_dir`（[agents.cr](../../../src/agents/agents.cr)）。

当 Agent 数量增长时，仅凭 id 无法支撑三类需求：

1. **人工浏览**：管理面需要按组筛选 Agent（「所有写作类 Agent」）。
2. **编排选择**：工作流 DSL 未来需要按组批量选中执行者。
3. **批量操作**：管理面对一组 Agent 做统一配置或健康检查。

当前 IPC 命令集没有 `agents.list`（[server.cr](../../../src/admin/ipc/server.cr)），管理面连 Agent 列表都拿不到。本提案补上元数据与只读查询，DSL 选择器不在本期范围。

## 2. 目标与非目标

### 2.1 目标

- 配置层为 Agent 增加两个元数据属性：`category`（单值分类）与 `tags`（多值标签）。
- 运行时 `AgentInstance` 暴露这两个属性，供管理面查询。
- IPC 新增 `agents.list` 只读命令，返回全部 Agent 的 id 与元数据。
- 配置加载/热更新校验拒绝非法值，失败时给出定位到字段的错误行。
- 文档（核心概念 §3.1 / §3.4、配置 schema 注释）同步回写。

### 2.2 非目标

- 不引入标签层级树或命名空间（首期扁平字符串）。
- 不建数据库表或独立索引文件；配置是唯一真相源，避免状态双源。
- 不改动 binding 路由逻辑（路由仍按 `(channel, account, peer)` 精确匹配）。
- 不实现工作流 DSL 的按分类/标签选择器（另立后续卡）。
- 不实现管理面写操作（创建/修改/删除 Agent 元数据走配置文件与热更新）。

## 3. 字段语义

### 3.1 `category`：稳定粗粒度分类

- 类型：`String?`，省略即 `nil`（未分类）。
- 语义：一个 Agent 一个主分类，表达「团队/岗位」这类稳定维度，例如 `writing`、`research`、`ops`。
- 约定：小写 ASCII 字母、数字、连字符，正则 `^[a-z0-9][a-z0-9-]*$`，长度 1..64。校验须整串匹配：用锚点 `\A` 与 `\z` 包裹正则（`\A[a-z0-9][a-z0-9-]*\z`），不得依赖 `^`/`$` 的单行匹配放行末尾换行等非法字符；不可用 `Regex#matches?`（子串搜索语义）替代整串校验。
- 校验：违反约定时报错 `agents.<name>.category must match ^[a-z0-9][a-z0-9-]*$ (1..64 chars)`。

### 3.2 `tags`：灵活细粒度标签

- 类型：`Array(String)`，默认 `[]`，多归属、无序。
- 语义：表达「技能/场景/状态」这类灵活维度，例如 `["drafting", "english", "oncall"]`。
- 约定：每个标签同样按 `^[a-z0-9][a-z0-9-]*$` 整串匹配（同 §3.1 的锚定要求），长度 1..64；同一 Agent 内去重（重复值报错而非静默丢弃）。
- 校验：任一标签非法时报错 `agents.<name>.tags[<i>] must match ^[a-z0-9][a-z0-9-]*$ (1..64 chars)`；重复时报错 `agents.<name>.tags contains duplicate '<tag>'`。

### 3.3 配置示例

```yaml
agents:
  main:
    model: deepseek/chat
    provider_ref: deepseek
    category: general
    tags: [assistant, triage]
    persona_file: agents/main/SOUL.md
  writer:
    model: anthropic/claude
    category: writing
    tags: [drafting, english]
    persona_file: agents/writer/SOUL.md
```

### 3.4 与既有属性的关系

- `category`/`tags` 与 `binding` 正交：binding 决定消息路由到哪个 Agent，元数据只描述 Agent 自身，不改变路由优先级。
- 与 `session` 策略正交：调度策略仍是每 Agent 独立配置，分类不隐含策略继承。
- 与热更新兼容：`category`/`tags` 随整个 `Config` 替换生效；`AgentInstance` 的元数据在实例创建时固化（见 §4.1 的边界说明）。

## 4. 运行时与接口契约

### 4.1 `AgentInstance` 元数据

`AgentInstance.initialize` 增加 `category : String?` 与 `tags : Array(String)` 参数，暴露为 getter。实例按 id 缓存于 `AgentRegistry`，首建时固化元数据；配置热更新后，已存在实例的元数据不自动刷新（避免运行中的会话人格/标签漂移）。管理面查询以配置为真相源，见 §4.2。

### 4.2 IPC `agents.list`

- 请求帧：`{"type": "agents.list", "id": "<request-id>"}`。
- 响应帧：`{"type": "response", "id": "...", "ok": true, "payload": {"agents": [...]}}`。
- 每个条目形态：`{"id": "<agent-id>", "category": "<category>", "tags": ["..."]}`；未分类时 `category` 必须是 JSON `null`，例如 `{"id": "worker", "category": null, "tags": []}`，不得输出字符串 `"null"`（避免与合法分类名 `null` 混淆）。
- 数据来源：当前 `Config.agents`（配置真相源），不读 registry 缓存；因此热更新后立即可见。
- 排序：按 Agent id 字典序，保证输出稳定。
- 只读：不接受过滤参数（过滤留给客户端或后续 DSL 卡），无副作用。

## 5. 验收标准

- `crystal spec` 覆盖：①合法配置解析出 `category`/`tags`；②非法 category/tags 报出定位到字段的错误行；③重复标签报错；④省略时默认 `nil` / `[]`；⑤末尾换行等非法字符被拒（整串匹配，category 与 tags 各一例）；⑥`agents.list` 返回全部 Agent 且按 id 排序、热更新后反映新值、未分类输出 JSON `null`。
- `crystal tool format --check`、`ameba`、`verify docs`、`ruby tools/check_docs.rb` 全绿。
- 文档回写：核心概念 §3.1 表格中的 Agent 定义补充「分类与标签」，§3.4 配置示例补 `category`/`tags`；本文与源码路径锚点经 verify 核对。

## 6. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 标签自由字符串导致泛滥 | 正则约束 + 配置校验；首期不做层级，后续按实际使用再评估命名空间 |
| 热更新后运行实例元数据陈旧 | 查询以配置为真相源；实例元数据仅用于创建时快照，明确写进文档 |
| 与未来 DSL 选择器语义重叠 | 本期只定义数据模型与查询，选择器另立卡并在本文保留接口边界 |

## 7. 后续工作（本期外）

- 工作流 DSL 按 `category`/`tags` 批量选中 Agent 的选择器语法与执行语义。
- 管理面 UI 的分组视图与批量操作（依赖 `agents.list`）。
- 若标签规模增大，再评估命名空间或层级结构。
