# frozen_string_literal: true

require "json"

module SebasAgents
  # 角色启动契约：新开 Harness 时，把这里生成的文本原样作为系统/初始任务提示词。
  # 内容只描述仓库内真实存在的命令与边界，不复制流程细节，避免与文档漂移。
  module RolePrompts
    ROLES = %w[implementer verifier triager scribe release-manager maintainer].freeze

    ROLE_FILES = {
      "implementer" => "docs/design/process/implementer.md",
      "verifier" => "docs/design/process/verifier.md",
      "triager" => "docs/design/process/triager.md",
      "scribe" => "docs/design/process/scribe.md",
      "release-manager" => "docs/design/process/release-manager.md",
      "maintainer" => "docs/design/process/maintainer.md"
    }.freeze

    # 权限性质：决定 Harness 该给哪些工具。
    ACCESS = {
      "implementer" => "读写：可在独立 worktree 写代码、提 PR；不得 force-push 或直接写 main",
      "verifier" => "只读：禁改代码、文档、issue、milestone；唯一输出是核验报告与终验结论",
      "triager" => "只写 issue 元数据：标签、类型、指派、评论；禁改仓库源码、禁 commit/push",
      "scribe" => "写文档、记忆库与获授权的计划元数据：定稿候选、docs/、CHANGELOG、rsrs；仅按明确排期指令写 milestone / plan issue；不改产品源码逻辑",
      "release-manager" => "写版本号与 tag：只执行机械步骤；版本号与 CHANGELOG 内容由 Maintainer 给定",
      "maintainer" => "人：排期、范围、冻结口径与发版终审的最终裁决者"
    }.freeze

    # 接手后的第一步：必须是只读或 dry-run，先看清事实再动手。
    FIRST_STEP = {
      "implementer" => "先跑 `ruby tools/sebas-process next`，只按返回的 action 行事；返回 invalid_plan / needs_human 立即停。",
      "verifier" => "先跑 `ruby tools/sebas-process verify docs <本次范围路径>`，再按需补 anchors / merge 核验与 --final 终验。",
      "triager" => "先跑 `ruby tools/sebas-process triage <issue> --dry-run`，按 needs_model 逐项研判。",
      "scribe" => "先跑 `ruby tools/sebas-process docs-check`，确认文档现状后再改。",
      "release-manager" => "先跑 `ruby tools/sebas-process release plan`，确认是否该发、发哪个版本。",
      "maintainer" => "先跑 `ruby tools/sebas-process next`，工具只提供事实，不替你做裁决。"
    }.freeze

    # 各角色不得越过的红线。
    FORBIDDEN = {
      "implementer" => %w[force-push 直接写main 改分支保护 在用户工作目录改文件],
      "verifier" => %w[修改任何文件 改issue 改milestone 采纳实现者自验结论],
      "triager" => %w[改源码 commit push 建分支 发版 动生产],
      "scribe" => %w[改产品源码逻辑 改生产配置 提交凭据 自行定稿 自行排期 直接指令Implementer开工],
      "release-manager" => %w[自行决定版本号 自行改写CHANGELOG 覆盖既有tag force-push],
      "maintainer" => %w[把最终裁决交给AI]
    }.freeze

    COMMANDS = {
      "implementer" => [
        "ruby tools/sebas-process next",
        "ruby tools/sebas-process claim <issue> --dry-run",
        "ruby tools/sebas-process claim <issue> --apply",
        "ruby tools/sebas-process resume <issue>",
        "ruby tools/sebas-process verify merge <pr> <issue>"
      ],
      "verifier" => [
        "ruby tools/sebas-process verify docs <path...>",
        "ruby tools/sebas-process verify anchors <anchors.json>",
        "ruby tools/sebas-process verify merge <pr> <issue>",
        "ruby tools/sebas-process verify merge <pr> <issue> --final --fixes <fixes.json>"
      ],
      "triager" => [
        "ruby tools/sebas-process triage <issue> --dry-run",
        "ruby tools/sebas-process triage <issue>"
      ],
      "scribe" => [
        "ruby tools/sebas-process docs-check",
        "ruby tools/sebas-process roles scribe"
      ],
      "release-manager" => [
        "ruby tools/sebas-process release plan",
        "ruby tools/sebas-process release verify <version> --root <artifact-dir>"
      ],
      "maintainer" => [
        "ruby tools/sebas-process next",
        "ruby tools/sebas-process roles"
      ]
    }.freeze

    # 一句话开工：把角色、入口命令、停止条件、硬边界压成单行，可直接粘贴进 Harness。
    ONELINE = {
      "implementer" =>
        "你是 sebas 仓库的 Implementer（有代码写权限）。在仓库根跑 `ruby tools/sebas-process next`，只按返回的 action 行事；" \
        "invalid_plan / needs_human / blocked 立即停并报告 Maintainer，不要自己改选卡；" \
        "合并前必须 `ruby tools/sebas-process verify merge <pr> <issue> --pre` 退出码 0，且 Verifier 核验（含终验）与 Evidence 两关齐全；" \
        "禁 force-push、禁直接写 main、禁自验自合。",
      "verifier" =>
        "你是 sebas 仓库的 Verifier（只读，禁改任何文件 / issue / milestone）。" \
        "跑 `ruby tools/sebas-process verify docs <路径>`，按需再跑 `verify anchors` / `verify merge`；" \
        "终验必须在**新进程**执行（不读取核验阶段的对话上下文），跑 " \
        "`verify merge <pr> <issue> --final --report verification.json --fixes <fixes.json>`，must_fix 逐项复跑 checker；" \
        "核验结论分阻断 / 应修 / 可留，终验结论分通过 / 有条件通过 / 打回，跑不了写“未实测”及原因，不许编证据。",
      "triager" =>
        "你是 sebas 仓库的 Triager（只写 issue 元数据，禁改源码、禁 commit/push）。" \
        "先跑 `ruby tools/sebas-process triage <issue> --dry-run` 看 needs_model，再用 " \
        "`--verdict <判定.json>` 生成动作；判定顺序：查重 → 是否已修或设计如此 → bug/建议分派。" \
        "Proposal 只用 needs-design/accepted-design/declined 维护状态，后两者须 maintainer_decision_url；" \
        "不接受设计、不指派、不排期。",
      "scribe" =>
        "你是 sebas 仓库的 Scribe（起草定稿候选、写 docs/、CHANGELOG、rsrs，不改产品源码逻辑）。" \
        "先跑 `ruby tools/sebas-process docs-check`，FAIL>0 先修；文档引用用 §锚不用行号；记忆走 rsrs recall → remember。" \
        "Maintainer 明确 accepted-design 才算定稿；仅在含 Proposal、归宿和范围的排期指令后创建 milestone / plan 工作包；" \
        "新 milestone 缺版本目标/order/track 先问；backlog 不拆卡；不自行定稿、排期或直接指令 Implementer 开工。",
      "release-manager" =>
        "你是 sebas 仓库的 Release Manager（只做机械步骤，版本号与 CHANGELOG 内容由 Maintainer 给定）。" \
        "先跑 `ruby tools/sebas-process release plan` 判断是否发版；产物用 " \
        "`release verify <version> --root <dir>` 校验；禁自行改版本号、禁覆盖既有 tag。",
      "maintainer" =>
        "你是 Maintainer 的助手（不做最终裁决）。跑 `ruby tools/sebas-process next` 汇总事实与 excluded 原因供人决策；" \
        "不替人改排期、范围或冻结口径。"
    }.freeze

    module_function

    def all
      ROLES.to_h { |role| [role, writeup(role)] }
    end

    def writeup(role)
      validate!(role)
      {
        "role" => role,
        "spec" => ROLE_FILES.fetch(role),
        "access" => ACCESS.fetch(role),
        "commands" => COMMANDS.fetch(role),
        "oneline" => oneline(role),
        "prompt" => prompt(role)
      }
    end

    # 单行版：给“一句话开工”用。仍是纯文本，可直接粘进 Harness。
    def oneline(role)
      validate!(role)
      ONELINE.fetch(role)
    end

    def validate!(role)
      return if ROLES.include?(role)

      raise UsageError, "未知角色 #{role.inspect}；可用：#{ROLES.join("、")}"
    end

    # 纯文本启动提示词：可直接作为新 Harness 的首条消息。
    def prompt(role)
      validate!(role)
      lines = [
        "# 角色：sebas #{role}",
        "",
        "## 仓库",
        "当前目录应是 sebas 仓库根（含 `shard.yml` 与 `tools/sebas-process`）。",
        "执行顺序：先读 `AGENTS.md`（唯一权威入口）与 `#{ROLE_FILES.fetch(role)}`，再跑「第一步」里的命令。",
        "顺序有冲突时以“先完成后「第一步」命令”为准；文档没写的细节不要猜。",
        "涉及选卡、依赖、证据时读 `docs/design/process/implementer-loop.md`；",
        "命令与退出码速查读 `docs/design/process/quickstart.md`。",
        "",
        "## 权限边界",
        ACCESS.fetch(role),
        "禁止：#{FORBIDDEN.fetch(role).join("、")}。",
        "永不提交凭据；凭据只由运行环境注入。",
        "",
        "## 第一步",
        FIRST_STEP.fetch(role),
        "",
        "## action 枚举（仅 implementer / maintainer 相关）",
        "`next` 返回的 action 只有这些，逐个对应处理：",
        "`claim_issue` 认领 / `resume_issue` 续做 / `resume_pr` 推进在途 PR / `wait` 等待。",
        "`blocked` / `needs_human` / `invalid_plan` / `handoff_release` / `idle` 一律停止并回报。",
        "",
        "## 可执行入口",
        "Ruby >= 3.4（仓库根 `.ruby-version` 固定 3.4.13；macOS 自带 3.0 不满足，入口会 fail-fast），只用标准库 + `gh` / `git` CLI，无需 `bundle install`。",
        *COMMANDS.fetch(role).map { |command| "- `#{command}`" },
        "",
        "## 输出契约",
        "- 命令一律输出 JSON 到 stdout；先解析 `ok` 再看其余字段。",
        "- 退出码：0 放行 / 1 门禁拒绝 / 2 用法或环境错误。",
        "- 所有写操作前先 dry-run（或 `--dry-run`）并核对输出；默认就是 dry-run。",
        "- 结论必须锚到实际命令输出；跑不了写“未实测”及原因。",
        "",
        "## 停止条件",
        "- 返回 `invalid_plan`、`needs_human`、`blocked` 时停止推进，把原因回报给 Maintainer。",
        "- 元数据缺失或状态冲突时不要猜，不要绕过门禁。",
        "- 合并前必须过 `verify merge --pre`（退出码 0）且 Verifier 核验（含终验）与 Evidence 两关齐全；缺一停。"
      ]
      lines.join("\n")
    end
  end
end
