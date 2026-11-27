# frozen_string_literal: true

module SebasAgents
  module Policy
    # F15：coordinator 在合并步骤中途崩溃（记录停在 `phase=merging`）时的远端对账。
    # 从 Routing 拆出：它是一组纯判定（记录 + 快照 → 动作或 nil），与路由的其他
    # 分支没有共享状态。
    #
    # 必须在 settled 判定**之前**调用：merging 记录即使 PR 已合并也要走自己的
    # 对账（要抓目标分支被改写、PR 关闭未合并这两种），否则会被 settled 静默吞掉。
    module MergingReconcile
      extend self

      # 返回 Action 或 nil（记录尚不自洽，交给后续通用分支）。
      #
      # 顺序即判据：
      # - PR 找不到 → invalid_plan（记录不可信）
      # - 已合并 → base 必须明确是 main，否则 invalid_plan；是则 release_ready
      # - 仍 open → 卡已 completed 属矛盾态（invalid_plan），否则 nil 走重核验
      # - 其余（已关闭未合并）→ invalid_plan
      def call(record, snapshot, observed, action_builder)
        number = record["issue"].to_i
        pr_number = record["pr"].to_i
        pr = pr_number.positive? ? snapshot.pull_request(pr_number) : nil

        if pr.nil?
          return action_builder.call("invalid_plan", observed,
            "## #{number} 的记录为 merging 但找不到 PR ##{pr_number}：需人工核对远端后再恢复",
            issue: number)
        end

        return settled(pr, number, pr_number, observed, action_builder) if pr.merged?
        return nil if pr.open? && !snapshot.issue(number)&.completed?

        if pr.open?
          # 矛盾状态：卡已被人工以 completed 关闭，但 PR 还开着。若就此返回 nil，
          # settled 判定会因 issue.completed? 放行并给出 release_ready——而 PR
          # 没合并，Evidence 与 unclaim 都完不成，F15 的重新核验也被跳过。
          return action_builder.call("invalid_plan", observed,
            "## #{number} 已以 completed 关闭但 PR ##{pr_number} 仍 open：合并未完成，" \
            "须人工裁决（是重开卡还是关闭 PR）",
            issue: number)
        end

        action_builder.call("invalid_plan", observed,
          "## #{number} 的记录为 merging 但 PR ##{pr_number} 是 #{pr.state} 且未合并：需人工裁决",
          issue: number)
      end

      private

      def settled(pr, number, pr_number, observed, action_builder)
        unless pr.base == "main"
          return action_builder.call("invalid_plan", observed,
            "## #{number} 的 PR ##{pr_number} 已合并但目标分支是 #{pr.base.inspect}，" \
            "可能未进入 main（base 缺失同样不可判定），须人工核对",
            issue: number)
        end

        action_builder.call("release_ready", observed,
          "## #{number} 的 PR ##{pr_number} 已合并（崩溃前已完成）：等 Evidence 升级后跑 unclaim",
          issue: number)
      end
    end
  end
end
