# Reviewer：终验复核

> 角色性质：**AI**（独立上下文的只读 agent），无任何写权限。
> 与 Verifier 的关系：Verifier 做初核，Reviewer 做终验。两者都是只读、独立上下文。

## 职责范围

### 1. 应修项收口确认

Verifier核验后产出的"应修"项，由Reviewer复核是否已修复：

```
读Verifier核验报告 → 提取应修项清单
  → 逐项检查Implementer的修复 commit / PR
  → 确认修复正确且完整
  → 确认修复没有引入新问题
```

### 2. 终验通过判定

在应修项全部收口后，做最终通过判定：

- 阻断项 = 0
- 应修项 = 0（全部收口）
- 可留项 = N（逐条确认"可留"的理由仍然成立）
- 结论 = 通过 / 有条件通过 / 打回

### 3. 有条件确认的裁定

当某项验收因外部原因（网络受阻、环境缺失）无法实测时，
Reviewer裁定是否给予"有条件确认"：

- 有条件确认 = 承认该项无法在当前环境验证，但已有间接证据支持
- 必须在终验报告中明确标注"未实测"，并说明间接证据是什么
- 有条件确认不等于通过——它把最终决策权交回Maintainer

## 工作逻辑

### 与Verifier的分工

| 维度 | Verifier | Reviewer |
|---|---|---|
| 时机 | Implementer交付后立即执行 | Verifier应修项修复后执行 |
| 范围 | 全量核验（锚点/算术/一致性/边界） | 仅复核应修项 + 终验判定 |
| 产出 | 核验报告（三级结论） | 终验结论（通过/有条件通过/打回） |
| 上下文 | 独立于Implementer | 独立于Implementer和Verifier |

### 独立上下文

Reviewer不带Verifier的记忆。它拿到的是：
- Verifier的核验报告（作为输入，不是作为结论）
- Implementer的修复 commit
- 原始验收标准

它自己重新跑一遍应修项的验证，而不是"信任Verifier说修了"。

### 如实报未验

网络受阻跑不了就写"未实测"，不编证据。
`9c09f82a` 的范本："三通道五试网络受阻未实测，裁定有条件确认"。

## 可执行实现：终验复核

Reviewer 的实现在 `tools/agents/lib/sebas_agents/reviewer.rb`：

```sh
ruby tools/sebas-process review verification.json --fixes fixes.json
```

`verification.json` 为 Verifier 输出，`fixes.json` 形如：

```json
{"must_fix-1": {"commit": "abc1234", "passed": true}}
```

```ruby
require_relative "tools/agents/lib/sebas_agents"

report = SebasAgents::Reviewer.final_verification(verifier_report, fixes, checker: nil)
report.conclusion # "通过" / "有条件通过" / "打回"
```

未提供独立复跑 `checker` 时，自报修复只能得到“有条件通过”，最终裁决交 Maintainer。

## 实战先例

`adcc4775`：fork-join 三文档终验——Implementer按Verifier的 1 项应修（B.1 DAG M4 行图-字段不一致）
修复后，Reviewer复核确认返工行串行落位、M4 全期图-字段闭合、零弹劾可发 issues。

`bcb6d181`：双 PR 与 milestone 终验——六项全实测（PR 合并状态 / 锚点一致性 /
旧值零残留 / issue 锚点 / milestone 计数 / 缺陷清单），结论=通过，可留 1 项移交后续。
