# 交互式初始化：`sebas setup` 分步配置与首次对话（Proposal）

> 状态：**Proposal**（2026-11-27 细化，待评审）。
> Tracking：[#145](https://github.com/ShiningRay/sebas/issues/145)。
> 关联：[对话式 TUI 提案](tui-conversational-console.md)、[spec §10](../spec/10-security.md)。
> 本文定义终端初始化体验、事务边界和运行时可验证契约；实现 WBS 见 [plan/wbs/m4x-platform.md](../plan/wbs/m4x-platform.md)。

## 1. 目标与边界

提供 Hermes `setup` 式的分步终端体验：用户不必先理解 YAML、Provider 引用、Binding 或五段会话键，即可得到可启动配置并进入第一次本地对话。

首期只交付以下完整链路：

```text
sebas setup → Provider + model + vault credential → main Agent
            → local TUI Binding → 校验并落盘 → gateway → sebas tui
```

**范围裁断**：Email / WeCom / Lark 当前仍从配置内 `credentials` 直接读取部分秘密，尚未形成与 provider 相同的 vault 运行时读取链。首期不为它们写明文 YAML，也不声称「已安全配置」。外部渠道向导须先完成渠道凭据引用与 vault 读取扩展，见 §9。

## 2. 命令入口与模式

```sh
sebas setup [--config config.yaml]
sebas setup --resume <draft-path>
sebas setup --non-interactive --input answers.json
```

- 默认是逐屏问答；`Esc` 返回上一步，`Ctrl-C` / EOF 取消，未确认不写正式配置。
- `--config` 决定正式配置路径；相对 `gateway.data_dir` 与 vault 路径以该文件所在目录为基准，与 gateway 一致。
- 草稿只保存非秘密答案、当前步骤与 schema 版本；秘密只短暂留在进程内存。默认不把草稿写入 home 或临时目录；用户显式选择「稍后继续」时才写 `--resume` 指定的安全路径，权限 `0600`。
- 非交互 JSON 走相同问题模型和校验器；缺字段、额外字段、秘密值或 EOF 均明确失败。秘密经独立受保护输入或既有 vault 条目注入，**answers.json 禁止秘密**。
- 不自动启动常驻 gateway、不打开公网端口、不安装系统服务。最后一步可由用户选择「现在启动本地 gateway 并打开 TUI」，默认仅打印命令。

## 3. 交互状态机

```text
Detect → Provider → Model → Agent → Channel → Binding
       → Review → Commit → Verify → Next
              ↑________ invalid answer / edit ________|
```

### 3.1 Detect：识别现有配置

启动先检查配置路径、数据目录与 vault 可达性，再进入问题页。

- **无配置**：显示将创建的文件和数据目录，开始 Provider。
- **已有合法配置**：选择「复用并补充 / 新建另一路径 / 退出」。默认复用；已有 provider、agent、binding 显示脱敏摘要。
- **已有非法配置**：显示所有可读校验错误；只允许另选路径或退出，不自动修复、不覆盖。
- **已有 vault 条目**：显示「已保存凭据（不可查看）」；可保留或替换，不回显秘密。
- **gateway 正在运行**：正式提交采用原子文件替换，让既有热更新管线先验后换；返回 `accepted/restart_required` 摘要。socket 变更不在首期向导中提供。
- **同名对象冲突**：默认复用完全等价对象；字段不同则要求改名或显式选择编辑该对象，不能静默覆盖。

### 3.2 Provider：厂商与端点

问题顺序：

1. 选择 `deepseek / openai / openrouter / anthropic / custom`。
2. 内置厂商显示默认 base URL；`custom` 必填 provider ID、base URL、protocol。
3. protocol 只列运行时实际支持的 `openai-compatible / anthropic`。
4. API key 使用隐藏回显；提供「使用既有 vault 条目 / 输入新 key / 返回」。
5. 询问是否进行**可选**连通性检查，默认不自动调用付费模型。

约束：

- provider ID 使用稳定小写标识；它同时是 YAML key 与 vault namespace，创建后不随显示名变化。
- 远程带 key 端点必须 HTTPS；只有环回允许 HTTP，复用 provider transport guard。
- 连通性检查失败不丢答案；用户可重试、编辑或明确选择「保存但未实测」。未实测状态必须进入完成摘要，不能显示绿色成功。

### 3.3 Model：模型标识

- 内置厂商给出可编辑建议值，不硬编码一个不可更换的模型。
- 模型 ID 原样保存；显式 provider 下允许 OpenRouter 等带斜杠的裸模型 ID。
- 若上一步选择连通性检查，用用户确认的模型发最小请求；计费提示先于请求。
- 校验空值、首尾空白和明显 YAML 控制字符；不猜测模型是否存在。

### 3.4 Agent：初始 Bot

- 默认 Agent ID 为 `main`，显示名仅作 UI 文案，不新增 Hermes profile 领域概念。
- 默认生成 `agents/main/SOUL.md`，内容为最小个人助手人格；已有文件不覆盖。
- 可选自定义 persona 文件；相对路径按配置目录规范化，loader 必须能重新找到它。
- 默认 memory window、tools 和调度策略继承现有安全默认，不在首次向导暴露高级编排项。

### 3.5 Channel：本地 TUI 为默认

```text
Select initial conversation channel
> Local terminal (TUI)       no external account required
  Email / WeCom / Lark       unavailable until credential refs are wired
  Skip channel               configuration only
```

- 默认本地 TUI：`account_id=local`，`peer=operator`，`channel_type=tui`。
- 跳过渠道会生成 Provider + Agent，但不宣称可以对话；完成页只给配置检查命令。
- 未具备安全运行时读取链的外部渠道选项显示原因，不能选中后生成明文配置。

### 3.6 Binding：显式路由预览

TUI 默认生成：

```yaml
bindings:
  - { channel: tui, account: local, peer: "*", agent: main }
```

页面用自然语言解释：「本机所有 TUI peer → main」。允许高级用户改为仅 `operator`，但默认通配可支持多个本地 peer。保存前调用 `Routing::Table.resolve` 预览 `tui/local/operator` 的结果，确保没有更具体旧 binding 把它路由到别的 agent。

### 3.7 Review：脱敏确认

```text
Provider   deepseek (openai-compatible)
Endpoint   https://api.deepseek.com
Credential vault: provider/deepseek/api_key [saved]
Agent      main, model deepseek-chat
Persona    agents/main/SOUL.md
Channel    TUI account=local, default peer=operator
Binding    tui/local/* -> main
Config     ./config.yaml
Data       ./data
Checks     schema passed; provider request not run

[Confirm and save]  [Edit]  [Cancel]
```

摘要永远不显示秘密、完整凭据指纹或含秘密的原始异常。确认前可以按节返回修改，已有答案保留。

## 4. 生成配置与凭据引用

目标 YAML 只含非秘密：

```yaml
providers:
  deepseek:
    protocol: openai-compatible

agents:
  main:
    provider: deepseek
    model: deepseek-chat
    persona_file: agents/main/SOUL.md

bindings:
  - { channel: tui, account: local, peer: "*", agent: main }

gateway:
  data_dir: data
  ipc: { mode: auto, host: 127.0.0.1, port: 18791 }
  http: { bind: 127.0.0.1, port: 18790, auth: token }
```

Provider 秘密写 `("provider", provider_id, "api_key")`。配置内 `api_key` 省略，gateway 经既有 `GatewaySecrets#migrate_secrets` 从 vault 恢复。向导与 gateway 必须共用同一个 `EncryptedFileVault.open` 主密钥解析和命名空间，不另建 `setup` 专用密码库。

## 5. 提交事务与失败恢复

初始化跨越 YAML、persona 与 vault，不能用一次 SQLite 事务代替。采用**筹备 → 暂存 → 校验 → 提交 → 补偿**：

1. 在配置同级私有 staging 目录写全部新文件，权限最小化；秘密只写 vault staging 记录，不提前替换正式有效条目。
2. 从暂存 YAML 调 `Config::Loader.from_content`，再校验 persona、provider 解析、binding 与 vault 回读。
3. 已有文件先保留原始字节与权限用于回滚；正式配置用同目录 temp + fsync + atomic rename 发布。
4. 多文件提交有明确顺序和提交标记；失败时恢复旧配置、旧 persona 与旧 vault 值，删除本次新建文件。回滚失败必须报告残留路径，不能声称已清理。
5. 进程在提交中断时，下次 `sebas setup` 检测 staging/commit marker，提示「恢复上次状态 / 放弃草稿」，不自动覆盖。
6. 最终再次从**正式路径** `Loader.load`，并用同一 data_dir 打开 vault 验证 provider key 可读；全部成功才打印 Ready。

并发保护：对配置路径使用排他 setup 锁；检测到配置或 vault 在问答期间被外部修改时，提交前失败并要求重新 Review，不基于旧快照覆盖。

## 6. 键盘与可访问性

- 向导是行式终端 UI，不依赖 TUI 的全屏渲染；CI、SSH、Windows Terminal 均可运行。
- 单选支持数字键与方向键，Enter 确认；文本输入支持默认值、重试和明确错误。
- `Esc` 返回，秘密输入不显示长度或掩码以外的信息；粘贴后同样不回显。
- 无 TTY、stdout 非终端、EOF 或用户取消时退出码非零；只有完整提交成功才返回 0。
- 输出不依赖颜色表达成败；所有秘密在日志、异常、spec snapshot 和答案 JSON 中均禁止出现。

## 7. 与 TUI 的衔接

完成后显示：

```sh
sebas gateway --config config.yaml
sebas tui --config config.yaml
```

若用户选择「现在启动」，setup 只负责启动受管子进程并等待 IPC discovery + health ready，再进入 TUI；退出 TUI 后询问是否停止这个由 setup 启动的 gateway，不接管用户已有 gateway。

TUI 自身在没有可用 binding 时提示：

```text
No usable local TUI binding. Run `sebas setup --config <path>`.
```

TUI 不内嵌第二套配置写入逻辑；setup、手工 YAML 和未来的外部渠道向导共享 Loader、Provider resolver、vault 与 Binding 校验。

## 8. 验收

### 8.1 首次完整路径

- 空目录中仅用交互答案完成 Provider + model + key + main + TUI binding。
- YAML 无 API key；重新打开 vault 可读，gateway 可完成初始化。
- 启动后 `tui/local/operator` 路由到 main，能发送第一条消息；真实模型未调用时标「未实测」。
- 重跑 setup 不重复 agent、binding 或凭据条目，不覆盖已有 persona。

### 8.2 失败与回归

- 非法 URL、非法 provider、空 model、冲突 ID 可重试；取消/EOF 不改正式文件。
- vault 写失败、配置 rename 失败、persona 冲突、外部并发修改均不留下 Ready 假象。
- 已有非法配置不被覆盖；旧合法配置回滚后字节一致。
- 非交互 answers 与交互路径生成相同语义配置；秘密不出现在任何答案文件、stdout/stderr 或快照。
- spec 覆盖 Windows 路径、原子替换与权限差异；质量门禁全绿。

## 9. 后续外部渠道扩展

Email / WeCom / Lark 进入向导前必须完成：

1. 为每类秘密定义稳定 `credential_ref`，YAML 只保存引用和非秘密连接字段。
2. 渠道 adapter、TokenProvider 与热更新统一从 vault 读取，不能再直接依赖配置内秘密。
3. setup 使用相同 namespace 写入并回读；渠道账号增删保持现有监督体语义。
4. 对每渠道分别进行真实连接验证；未实测只标「配置已保存，联调未验证」。

届时复用本文 Detect → Review → Commit 框架，按渠道插入子状态机，不扩展成一张超长问卷。

## 10. 非目标

- 不自动安装 launchd/systemd/Windows 服务，不配置 Tailscale 或公网回调。
- 不在首次向导编辑 workflow、审批策略、插件、多 agent 团队和日历。
- 不引入浏览器 OAuth、图形安装器或秘密云同步。
- 不为了通过向导而放宽现有 Loader、路由 fail-closed 或凭据校验。
