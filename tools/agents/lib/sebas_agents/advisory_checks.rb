# frozen_string_literal: true

module SebasAgents
  # 非门禁的第三方检查（advisory）名单。
  #
  # 为什么需要这张名单：CodeRabbit 用名为 `CodeRabbit` 的 check run 表示
  # 「本轮审阅进行中」，一轮 4-8 分钟；而分支保护的必需检查只有
  # spec×3 + ameba + verify。把 advisory 的 pending 当成「CI 未完成」，
  # 选择器会返回 wait、Evidence 预登记会直接失败——等的是一个不进合并
  # 条件的读数，而且 GitHub 侧的 auto-merge 本来就不看它。
  #
  # 边界（只放宽 pending，不放宽结论）：
  #   - 进行中（queued / in_progress）：不参与「CI 未完成」判定。
  #   - 状态取值不在这两态、也不是 completed：按未完成处理（fail-closed）。
  #     未知状态不能因为落不进任何分支就默认放行。
  #   - 已完成且结论为 failure / cancelled / timed_out：仍按失败检查处理。
  #     历史上 CodeRabbit 服务故障 CANCELLED 确实需要人工裁决，不能静默放过。
  #   - review 意见的权威载体是「未解决 review thread」，不是 check 结论；
  #     `verify merge --pre` 单独校验 thread，未解决即 blocker。
  #
  # 按 check 名匹配：`gh pr view --json statusCheckRollup` 不返回 app slug，
  # 只有 name/status/conclusion。名字被伪造只能让自己少等一轮，
  # 绕不过分支保护的必需检查。
  module AdvisoryChecks
    NAMES = ["CodeRabbit"].freeze

    # GitHub 定义的未完成状态；advisory 只在这两态被豁免。
    KNOWN_PENDING = %w[QUEUED IN_PROGRESS].freeze

    module_function

    def advisory?(check)
      NAMES.include?(check["name"].to_s)
    end

    # 仍未结束（API 用小写 completed，快照用 COMPLETED，两者都算已完成）。
    def pending?(check)
      status = check["status"].to_s.upcase
      !status.empty? && status != "COMPLETED"
    end

    # 豁免出「CI 未完成」判定的唯一一类：advisory 且状态明确为未完成。
    # 未知状态不算豁免，宁可多等一轮也不静默放行。
    def exempt?(check)
      advisory?(check) && KNOWN_PENDING.include?(check["status"].to_s.upcase)
    end
  end
end
