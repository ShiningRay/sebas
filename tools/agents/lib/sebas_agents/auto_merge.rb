# frozen_string_literal: true

module SebasAgents
  # 合并队列自动触发（M4x-Parallel-WP4，#222；Proposal §8 阶段 4）。
  #
  # 阶段 3 的合并链已把每一步的门禁做实（`MergeQueue.next_step` + merge 锁内的
  # 合并前复核），阶段 4 只做一件事：**去掉「每步都要人按一次」的人工触发**，
  # 让 coordinator 在条件齐备时自动推进队列。门禁一个不放宽、权限一个不新增：
  # 本模块只产出「这一步能不能自动跑」的确定性判定，执行仍走 `queue --apply`
  # 的同一套单步执行器与 ref 锁。
  #
  # 三条硬规则（卡面验收）：
  # 1. 关停开关：`.github/agents.yml` 的 `auto_merge_enabled` 缺省 false——
  #    关着时自动路径整体拒绝，行为与阶段 3 完全一致。
  # 2. 「有条件通过」不自动合并：终验的 CI check 对「通过」与「有条件通过」
  #    同为绿（有证据的未实测项不算打回），只有 verifier 摘要评论的
  #    unverified 计数能区分；计数 > 0 或摘要缺失都交回 Maintainer。
  # 3. 失败回退不重试超过一次：同一张卡连续自动失败到 `MAX_FAILURES` 即停，
  #    人工 `queue --apply` 成功一次后重置计数。
  module AutoMerge
    module_function

    # 自动失败预算：初次 + 一次重试。第 2 次失败后自动路径对本卡拒绝，
    # 直到人工通道成功一步重置（见 CLI 的 reset_auto_failures）。
    MAX_FAILURES = 2

    # 单步自动判定。返回 [allowed, reason]；reason 非 nil 时 allowed 必为 false。
    # step     —— MergeQueue.next_step 给出的当前步（verify_pre/update_branch/
    #             changelog/merge）。
    # summary  —— verifier 摘要计数（MergeQueue.verifier_summary_from_body 的
    #             返回），nil = 没找到摘要评论。
    # failures —— 本卡连续自动失败次数（运行记录 auto_merge_failures）。
    def gate(step:, summary:, failures:)
      count = failures.to_i
      if count >= MAX_FAILURES
        return [false, "PR 已连续自动失败 #{count} 次，超出回退预算（不重试超过一次）；" \
          "人工 `queue --apply` 成功一步后自动重置"]
      end

      return [true, nil] unless step == "merge"

      # 合并步的自动专属门：终验结论必须是「通过」。check 全绿只说明「没打回」，
      # 区分不了有条件通过——看摘要评论的 unverified 计数。
      if summary.nil?
        return [false, "缺 verifier 摘要评论（<!-- verify-pr:summary -->），无法确认终验结论；" \
          "「有条件通过」与「通过」在 CI check 上同为绿，缺证据即交回 Maintainer"]
      end
      if summary["unverified"].to_i.positive?
        return [false, "终验为「有条件通过」（unverified=#{summary['unverified']}），按约定交回 Maintainer"]
      end

      [true, nil]
    end

    # 该步成功后是否允许同一轮内接续下一步。只有 verify_pre 可以：它不改 head、
    # 不清核验记录，且下一步（merge）会在锁内全量复核。update_branch 与 changelog
    # 都会使已核验 head 作废（异步的 CI / 重核验在两轮调用之间发生），merge 之后
    # 是「等 Evidence 升级」的串行单位——三者都必须停轮。
    def continue_after?(step)
      step == "verify_pre"
    end
  end
end
