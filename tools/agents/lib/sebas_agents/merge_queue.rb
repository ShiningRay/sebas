# frozen_string_literal: true

require "json"

module SebasAgents
  # 合并队列（M4x-Parallel-WP3，#221；Proposal §7.2）。
  #
  # 队列是**确定性规划层**：给定快照 + 本地记录，算出「下一个该处理哪张 PR、
  # 它卡在链上的哪一步」。执行仍由 coordinator 逐条跑命令完成，本模块不发任何写。
  #
  # 为什么串行单位要延到 Evidence 升级完成：`evidence-register.yml` 只在
  # merge commit 自己的 CI 结论为 success 时把 `merged_into_main` 置 true；
  # main 侧 CI 一旦被下一次 push 顶掉，该卡 Evidence 停在 false，后继卡永久
  # blocked。`ci.yml` 已于 #289 停止在 main 侧取消，但每个并发组仍只有一个
  # pending 位，所以「合并—等 Evidence—下一张」仍是唯一安全顺序。
  module MergeQueue
    # 链上步骤，按执行顺序。queue_step 返回其中一项。
    STEPS = %w[
      verify_pre
      changelog
      merge
      evidence
      release
    ].freeze

    module_function

    # 规划入口。返回 QueuePlan：
    #   entries    —— 全部 merge_ready 候选，按进入顺序（issue 号升序稳定排序）
    #   head       —— 队首（nil 表示空队列）
    #   step       —— 队首卡在链上的下一步
    #   blocked_by —— 队首卡为何停下（人可读）
    QueuePlan = Data.define(:entries, :head, :step, :blocked_by) do
      def empty?
        head.nil?
      end

      def to_h
        {
          "entries" => entries.map(&:to_h),
          "head" => head,
          "step" => step,
          "blocked_by" => blocked_by
        }.compact
      end
    end

    QueueEntry = Data.define(:issue, :pr, :head_sha, :step, :blocked_by, :changelog_pending) do
      def to_h
        {
          "issue" => issue,
          "pr" => pr,
          "head_sha" => head_sha,
          "step" => step,
          "blocked_by" => blocked_by,
          "changelog_pending" => changelog_pending
        }.compact
      end
    end

    CHANGELOG_MARKER = "<!-- sebas-changelog -->"

    # 从 PR 正文抽出待追加条目（scribe.md §5 修订版：条目由 PR 携带）。
    # 返回 nil 表示没声明（旧路径：worker 自己写了 CHANGELOG）；返回 [] 表示
    # 声明了块但没有条目——那也算 pending，避免「空块 = 已完成」的静默放行。
    #
    # 取 marker 之后**第一个围栏块**的内容：不能按 ``` 简单 split，那样拿到
    # 的是围栏之前的那半截（实为空串），条目会被静默读成 0 条。
    def changelog_entries(body)
      text = body.to_s
      return nil unless text.include?(CHANGELOG_MARKER)

      rest = text[(text.index(CHANGELOG_MARKER) + CHANGELOG_MARKER.length)..].to_s
      open_at = rest.index("```")
      return [] unless open_at

      after_open = rest[(open_at + 3)..].to_s
      # 跳过围栏行剩余部分（可能带语言标记）到下一个换行
      after_open = after_open.sub(/\A[^\n]*\n/, "")
      close_at = after_open.index("```")
      block = close_at ? after_open[0...close_at] : after_open
      block.lines.map(&:strip).reject(&:empty?)
    end

    # 入口标识：条目必须自带 PR 引用，幂等与核验都按它判（Proposal §7.2）。
    def entry_for?(line, pr_number)
      line.include?("(#%d)" % pr_number) || line.include?("/pull/#{pr_number}")
    end

    # CHANGELOG 内容里是否已写入本 PR 的条目。
    def changelog_recorded?(content, pr_number)
      text = content.to_s
      return false if text.empty?

      text.lines.any? { |line| entry_for?(line, pr_number) }
    end

    # 规划合并队列。
    #
    # leases 为逐租约动作表（Policy::Selection::LeaseAction）；只取 merge_ready。
    # snapshot 提供 PR 的 head/thread/check 事实；changelog 为 CHANGELOG.md 正文
    # （nil 表示调用方没读，队列按「未核验」处理而不是当作已写入）。
    def plan(leases, snapshot, changelog: nil)
      ready = Array(leases).select { |lease| lease.action == "merge_ready" }
      entries = ready.map do |lease|
        pr = snapshot.pull_request(lease.pr.to_i)
        body = pr&.body
        pending_entries = changelog_entries(body)
        step, blocked = next_step(pr, pending_entries, changelog)
        QueueEntry.new(
          issue: lease.issue,
          pr: pr&.number || lease.pr,
          head_sha: pr&.head_sha,
          step: step,
          blocked_by: blocked,
          changelog_pending: pending_entries
        )
      end.sort_by { |entry| entry.issue.to_i }

      head = entries.first
      QueuePlan.new(
        entries: entries,
        head: head&.issue,
        step: head&.step,
        blocked_by: head&.blocked_by
      )
    end

    # 单张 PR 的下一步。顺序与 §7.2 的链一致：核对归属 → verify --pre →
    # CHANGELOG 追加 → 合并 → 等 Evidence 升级 → 释放租约。
    def next_step(pr, pending_entries, changelog)
      return ["verify_pre", "PR 不在快照内或已不是 open，先重新取快照"] if pr.nil?

      unless pr.open?
        return ["release", "PR 已合并，等 Evidence 升级后释放租约"] if pr.merged?

        return ["verify_pre", "PR 已关闭但未合并，需人工裁决"]
      end

      if pr.base.to_s != "" && pr.base != "main"
        return ["verify_pre", "PR 目标分支是 #{pr.base.inspect}，只允许 main"]
      end
      if pr.failing_checks.any?
        return ["verify_pre", "存在失败检查：#{pr.failing_checks.map { |c| c["name"] }.compact.join("、")}"]
      end
      if pr.pending_checks.any?
        return ["verify_pre", "仍有未完成的检查"]
      end
      if pr.unresolved_threads.any?
        return ["verify_pre", "有 #{pr.unresolved_threads.length} 条未解决 review thread"]
      end

      # 「先 verify 再追加 CHANGELOG」：追加会改 head，追加之后的提交必须重新核验，
      # 所以顺序固定为 verify_pre → changelog → merge。
      if pending_entries
        return ["changelog", "PR 正文声明了待追加条目，但 CHANGELOG 未读到"] if changelog.nil?

        unless changelog_recorded?(changelog, pr.number)
          return ["changelog", "等合并队列把 #{pending_entries.length} 条 CHANGELOG 条目追加到 [Unreleased]"]
        end
      end

      ["merge", "可执行 gh pr merge --squash --match-head-commit #{pr.head_sha}"]
    end
  end
end
