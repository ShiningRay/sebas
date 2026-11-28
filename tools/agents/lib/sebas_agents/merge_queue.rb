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
      update_branch
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

    # Verifier 核验摘要评论的 marker（verify.yml verifier job 写入 PR 评论）。
    # 自动合并用它区分「终验通过」与「有条件通过」：两者的 CI check 都是绿
    # （有证据的未实测项不算打回），只有这张评论里的 unverified 计数能区分。
    VERIFIER_SUMMARY_MARKER = "<!-- verify-pr:summary -->"

    # 从 verifier 摘要评论正文解析核验计数。返回：
    #   {"blocker" => n, "must_fix" => n, "acceptable" => n, "unverified" => n}
    # 无 marker 返回 nil（正文不是摘要评论）；有 marker 但计数表残缺抛
    # InvalidPlan——结构坏了不能猜成 0 放行（口径同 changelog 的空块判定）。
    def verifier_summary_from_body(body)
      text = body.to_s
      return nil unless text.include?(VERIFIER_SUMMARY_MARKER)

      %w[blocker must_fix acceptable unverified].to_h do |level|
        match = text.match(/\|\s*#{level}\s*\|\s*(\d+)\s*\|/)
        raise InvalidPlan, "verifier 摘要评论缺 #{level} 计数，无法判定终验结论" unless match

        [level, Integer(match[1])]
      end
    end

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
    # 两种写法都要求编号后是边界：`(#50)` / 行尾 / 非数字，否则
    # `/pull/501` 会被当成 `#50` 的条目，导致漏追加。
    def entry_for?(line, pr_number)
      text = line.to_s
      text.match?(/\(##{pr_number}\)/) ||
        text.match?(%r{/pull/#{pr_number}(?!\d)})
    end

    # CHANGELOG 内容里是否已写入本 PR 的条目。
    def changelog_recorded?(content, pr_number)
      text = content.to_s
      return false if text.empty?

      text.lines.any? { |line| entry_for?(line, pr_number) }
    end

    UNRELEASED = "## [Unreleased]"

    # 把条目追加进 `[Unreleased]` 段，返回新正文。纯函数，不做 IO。
    # - 已有本 PR 引用（幂等）→ 原样返回
    # - 找不到 `[Unreleased]` 段 → 抛 InvalidPlan（结构坏了不能猜位置）
    # - 条目插在该段标题之后的第一行（紧邻标题、在既有条目之前），
    #   与「最新在上」的惯例一致
    def append_entries(content, entries, pr_number)
      text = content.to_s
      lines = Array(entries).map(&:rstrip).reject(&:empty?)
      return text if lines.empty? || changelog_recorded?(text, pr_number)

      rows = text.lines
      index = rows.index { |row| row.strip == UNRELEASED }
      raise InvalidPlan, "CHANGELOG.md 缺 `#{UNRELEASED}` 段，无法追加" if index.nil?

      # 标题后先空一行再写条目，保持 Keep a Changelog 的段落格式。
      insert_at = index + 1
      insert_at += 1 while insert_at < rows.length && rows[insert_at].strip.empty?
      payload = lines.map { |line| "#{line}\n" }
      payload = ["\n"] + payload if insert_at == index + 1
      (rows[0...insert_at] + payload + rows[insert_at..].to_a).join
    end

    # 验收背压（#221 §4 / Proposal §7.4）：队列要处理的 PR 数量。
    #
    # 口径不是「open PR 数」——那只反映有多少 PR 存在。这里只数租约动作为
    # `merge_ready` 的 PR：已进入合并队列、接下来要做核验 / update-branch /
    # 合并的。`wait`（等 CI）与 `needs_human` 还没到这一步，算进去会让背压
    # 虚高、掩盖真实排队。
    #
    # 注意 `merge_ready` **包含 BEHIND**：那类 PR 先要 `update_branch`，之后
    # 还得重核验，所以它确实占验收通道；只是它的第一步不是核验。
    #
    # 为什么单独给方法而不是在调用方写 `count`：`plan` 与 `queue` 两处都要，
    # 口径必须同源，否则「一个说 3 一个说 5」。
    def verifier_queue_depth(leases)
      Array(leases).count { |lease| lease.action == "merge_ready" && lease.pr }
    end

    # 规划合并队列。
    #
    # leases 为逐租约动作表（Policy::Selection::LeaseAction）；只取 merge_ready。
    # snapshot 提供 PR 的 head/thread/check 事实；changelog 为 CHANGELOG.md 正文
    # （nil 表示调用方没读，队列按「未核验」处理而不是当作已写入）。
    #
    # pending_evidence 为本机记录里「PR 已合并但 Evidence 尚未升级」的 issue 列表
    # （由调用方从本地记录与快照算出）。非空时整队阻塞：串行单位是
    # 「合并 → 等 Evidence 升级 → 下一张」，前一张没升级就不许后一张合。
    #
    # `verified_heads` 是「本机记录里这张卡的 PR 上一次通过 verify merge --pre
    # 的 head」，由调用方从运行记录读（`verified_head` 字段）。队列据此判断
    # 「当前 head 是否已核验」——没有它，`update_branch` 改完 head 后只要 CI
    # 绿、Evidence 仍是 accepted，队列就会直接给 merge，把旧结论用到新 head 上。
    def plan(leases, snapshot, changelog: nil, pending_evidence: [], verified_heads: {})
      blocking = Array(pending_evidence)
      unless blocking.empty?
        head = blocking.first
        return QueuePlan.new(entries: [], head: head, step: "evidence",
          blocked_by: "## #{head} 的 PR 已合并但 Evidence 未升级（merged_into_main != true），" \
            "队列按串行单位等它完成再处理下一张")
      end

      ready = Array(leases).select { |lease| lease.action == "merge_ready" }
      entries = ready.map do |lease|
        pr = snapshot.pull_request(lease.pr.to_i)
        body = pr&.body
        pending_entries = changelog_entries(body)
        step, blocked = next_step(pr, pending_entries, changelog,
          verified_head: verified_heads[lease.issue.to_i])
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
    def next_step(pr, pending_entries, changelog, verified_head: nil)
      return ["verify_pre", "PR 不在快照内或已不是 open，先重新取快照"] if pr.nil?

      unless pr.open?
        return ["release", "PR 已合并，等 Evidence 升级后释放租约"] if pr.merged?

        return ["verify_pre", "PR 已关闭但未合并，需人工裁决"]
      end

      # base 必须明确是 main：缺失不等于「未取到故放行」（与 scope.files 同口径）。
      unless pr.base == "main"
        return ["verify_pre", "PR 目标分支是 #{pr.base.inspect}（只允许 main；缺失即不可判定）"]
      end
      if pr.failing_checks.any?
        return ["verify_pre", "存在失败检查：#{pr.failing_checks.map { |c| c["name"] }.compact.join("、")}"]
      end
      if pr.unresolved_threads.any?
        return ["verify_pre", "有 #{pr.unresolved_threads.length} 条未解决 review thread"]
      end

      # BEHIND 必须先 update-branch 再核验（#221 §3）：main 前进后 PR 的 CI 与
      # 独立核验跑的都是旧 base，直接合并等于把未在新 base 上验证过的结论合进去。
      # `gh pr update-branch` 会改写 head，所以这一步之后必须重跑 `verify merge --pre`
      # 与独立核验——新 head 在下一轮快照里自然落到 verify_pre，不复用旧结论。
      if pr.merge_state_status == "BEHIND"
        return ["update_branch", "PR ##{pr.number} 落后于 main，先 gh pr update-branch，之后必须重跑 verify merge --pre 与独立核验"]
      end

      if pr.pending_checks.any?
        return ["verify_pre", "仍有未完成的检查"]
      end

      # 只有 CLEAN 才能合并。BEHIND 已在上方分流；DIRTY（有冲突）、BLOCKED
      # （缺必需审批或分支保护未满足）、UNKNOWN（GitHub 还在算）都不能当成
      # 「可合并」——放过去等于让 `queue --apply` 去碰一个必然失败的合并。
      unless pr.merge_state_status == "CLEAN"
        return ["verify_pre",
          "PR ##{pr.number} 的合并状态是 #{pr.merge_state_status.inspect}，只有 CLEAN 才可合并" \
          "（DIRTY=有冲突需先解决；BLOCKED=缺审批或分支保护未满足）"]
      end

      # head 必须已有核验记录。这是 update_branch / changelog 追加的直接后果：
      # 两者都改 head，旧 head 上的 `verify merge --pre` 结论随之作废。没有这道
      # 判定，「CI 全绿 + Evidence 仍 accepted」就能把新 head 直接合并——
      # 而 Evidence 是 issue 级的，不绑定 head，拦不住这件事。
      #
      # 无核验记录（nil）同样不放行：合并前必须有一次针对这个 head 的核验。
      if verified_head.nil? || verified_head != pr.head_sha
        detail = verified_head.nil? ? "尚无核验记录" : "已核验的是 #{verified_head[0, 8]}，当前是 #{pr.head_sha[0, 8]}"
        return ["verify_pre", "PR ##{pr.number} 的 head 需要重新核验（#{detail}）：跑 verify merge --pre 与独立核验"]
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
