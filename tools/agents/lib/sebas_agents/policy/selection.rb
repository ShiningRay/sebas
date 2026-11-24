# frozen_string_literal: true

module SebasAgents
  module Policy
    # 选卡策略：同一快照必须得到同一动作。无网络、无 Git、无模型调用。
    module Selection
      require "set"

      # design 卡由 Scribe 执行，与 tracking / manual 一样不进 Implementer 选卡。
      NON_WORK_KINDS = %w[tracking manual design].freeze

      module_function

      def select_action(snapshot, record: nil)
        milestones = Milestones.normalize(snapshot.milestones)
        observed = snapshot.main_sha

        in_progress = snapshot.in_progress_issues
        if in_progress.length > 1
          return invalid(observed, "存在 #{in_progress.length} 张 #{Model::IN_PROGRESS_LABEL}：#{in_progress.map(&:number).join("、")}")
        end

        claimed = in_progress.first
        if claimed && record && record["issue"] && record["issue"].to_i != claimed.number
          return invalid(observed, "本地记录 issue ##{record["issue"]} 与远端认领 ##{claimed.number} 冲突")
        end

        # aborted 表示认领未被确认：必须在任何恢复分支之前对账。
        # 不依赖 claimed——暂停恢复与在途 PR 分支可能在无远端标签时触发。
        if record && record["phase"] == "aborted"
          target = claimed || (record["issue"] && snapshot.issue(record["issue"].to_i))
          return reconcile_aborted(target, record, observed)
        end

        # §3.2：needs:human 且已有 agent:resume → 恢复。未建 PR 的暂停会释放认领，
        # 因此这里必须是「有 needs:human + agent:resume」，而不是要求仍有 in-progress。
        paused_resume = snapshot.issues.find do |issue|
          issue.open? && issue.label?(Model::HUMAN_LABEL) && issue.label?(Model::RESUME_LABEL)
        end
        if paused_resume
          if claimed && claimed.number != paused_resume.number
            return invalid(observed,
              "恢复目标 ##{paused_resume.number} 与当前认领 ##{claimed.number} 冲突")
          end
          return resume_paused(paused_resume, record, observed)
        end

        # §3.2：needs:human 期间保持原有归属，等待人工指令，不推进合并。
        # 未建 PR 的暂停会释放认领，此时也必须报 needs_human，而不是去开别的卡。
        if claimed&.label?(Model::HUMAN_LABEL)
          return action("needs_human", observed,
            "## #{claimed.number} 处于 #{Model::HUMAN_LABEL}，等待 Maintainer 解除暂停",
            issue: claimed.number, milestone: claimed.milestone)
        end

        pending_pause = snapshot.issues.find do |issue|
          issue.open? && issue.label?(Model::HUMAN_LABEL)
        end
        if pending_pause
          return action("needs_human", observed,
            "## #{pending_pause.number} 处于 #{Model::HUMAN_LABEL}，等待 Maintainer 加 #{Model::RESUME_LABEL}",
            issue: pending_pause.number, milestone: pending_pause.milestone)
        end

        own_pr = own_pull_request(snapshot, record, claimed)
        if own_pr && own_pr.unresolved_threads.empty? && own_pr.merge_state_status == "CLEAN"
          # 合并仍需人工/独立验收放行；这里只报告可合并，不自动 squash。
          return action("resume_pr", observed,
            "在途 PR ##{own_pr.number} 已 CLEAN；核验 Verifier/Reviewer/Evidence 后再合并",
            issue: own_pr.closing_issues.first)
        end
        return classify_pr(own_pr, claimed, observed) if own_pr

        return resume_claimed(claimed, record, observed) if claimed

        state, milestone = Milestones.active(milestones, open_issue_counts: open_counts(snapshot, milestones))
        case state
        when :idle
          return action("idle", observed, "所有主线 milestone 均已收口")
        when :handoff_release
          return action("handoff_release", observed, "主线工作卡已清、仍有 open milestone，进入门禁/发版收口")
        end

        select_new_card(milestone, snapshot, observed)
      end

      # 以实际 open 卡计数，避免 milestone.open_issues 缓存滞后导致误判收口。
      # 若快照只覆盖部分 milestone（离线快照常见），回退到缓存字段。
      def open_counts(snapshot, milestones)
        counts = snapshot.issues.select(&:open?).group_by(&:milestone).transform_values(&:length)
        milestones.to_h do |item|
          [item.number, counts.fetch(item.number, item.open_issues)]
        end
      end

      # 找本 Implementer 的在途 PR：优先本地记录，其次「任一认领/记录关联」，再退到
      # 「PR 关联了未认领但属于本仓 open 卡」——后者用于发现重复开工风险。
      def own_pull_request(snapshot, record, claimed)
        if record && record["pr"]
          pr = snapshot.pull_request(record["pr"].to_i)
          return pr if pr&.open?
        end

        candidates = snapshot.pull_requests.select(&:open?)
        if claimed
          found = candidates.find { |pr| pr.closing_issues.include?(claimed.number) }
          return found if found
        end

        record_issue = record && record["issue"].to_i
        return candidates.find { |pr| pr.closing_issues.include?(record_issue) } if record_issue&.positive?

        nil
      end

      def classify_pr(pr, claimed, observed)
        number = pr.closing_issues.first || claimed&.number
        if pr.failing_checks.any?
          names = pr.failing_checks.map { |check| check["name"] }.compact.join("、")
          return action("resume_pr", observed, "在途 PR ##{pr.number} 有失败检查：#{names}", issue: number)
        end
        if pr.unresolved_threads.any?
          count = pr.unresolved_threads.length
          return action("resume_pr", observed, "在途 PR ##{pr.number} 有 #{count} 条未解决 review thread", issue: number)
        end
        if pr.merge_state_status == "BEHIND"
          return action("resume_pr", observed, "在途 PR ##{pr.number} BEHIND，需 update-branch", issue: number)
        end
        if pr.pending_checks.any?
          return action("wait", observed, "在途 PR ##{pr.number} 等待 CI", issue: number)
        end
        if pr.merge_state_status == "CLEAN"
          return action("resume_pr", observed,
            "在途 PR ##{pr.number} 已 CLEAN；核验 Verifier/Reviewer/Evidence 后 squash", issue: number)
        end

        action("wait", observed, "在途 PR ##{pr.number} 状态 #{pr.merge_state_status.inspect}，等待事件", issue: number)
      end

      # 同时带 needs:human 与 agent:resume：先核验解决说明，再同一动作移除两标签。
      # aborted 必须显式对账，而不是直接续跑。
      # 远端有标签 → 需要人工确认这次写入属于本认领；
      # 远端无标签 → 结论是锁不存在，需重新认领。
      # target 可能为 nil（记录里的 issue 不在快照内），此时也要拒绝继续。
      def reconcile_aborted(target, record, observed)
        number = target&.number || record["issue"]
        written = record["label_written"]
        if written == true
          return action("invalid_plan", observed,
            "## #{number} 的认领处于 aborted 且可能已写标签（label_written=true）：" \
            "需 Maintainer 核对远端是否有 #{Model::IN_PROGRESS_LABEL}，确认后清除记录再重新认领",
            issue: number, milestone: target&.milestone)
        end

        action("invalid_plan", observed,
          "## #{number} 的认领处于 aborted（label_written=#{written.inspect}）：" \
          "先删除本地运行记录，再用 claim 重新认领，不得直接续跑",
          issue: number, milestone: target&.milestone)
      end

      def resume_paused(issue, record, observed)
        action("resume_issue", observed,
          "暂停卡 ##{issue.number} 已获 agent:resume；核验 Maintainer 解决说明后移除暂停标签并恢复原归属",
          issue: issue.number, milestone: issue.milestone)
      end

      def resume_claimed(issue, record, observed)
        return invalid(observed, "##{issue.number} 已认领但缺本地运行记录") if record.nil? || record.empty?

        if record["issue"] && record["issue"].to_i != issue.number
          return invalid(observed, "本地记录 issue #{record["issue"].inspect} 与认领 ##{issue.number} 不符")
        end

        reason = if record["phase"] == "claiming"
          "认领中断：本地记录为 claiming 且远端标签已存在，回读补全为 claimed"
        else
          "续做已认领卡，沿用 worktree #{record["worktree"].inspect}"
        end
        action("resume_issue", observed, reason, issue: issue.number, milestone: issue.milestone)
      end

      def select_new_card(milestone, snapshot, observed)
        excluded = []
        candidates = []
        # 已被任意 open PR 关联的卡不得再认领（§3.3 第 2 步）。
        pr_issue_numbers = snapshot.pull_requests.select(&:open?).flat_map(&:closing_issues).to_set

        snapshot.issues.select { |issue| issue.open? && issue.milestone == milestone.number }.each do |issue|
          if pr_issue_numbers.include?(issue.number)
            excluded << {"issue" => issue.number, "reason" => "已有 open PR 关联，禁止重复开工"}
            next
          end

          reason = exclusion_reason(issue)
          if reason
            excluded << {"issue" => issue.number, "reason" => reason}
            next
          end

          begin
            automation = Dependencies.automation_for(issue)
          rescue InvalidPlan => e
            excluded << {"issue" => issue.number, "reason" => e.message}
            next
          end

          if automation.nil?
            excluded << {"issue" => issue.number, "reason" => "缺 Automation 块，元数据未补齐"}
            next
          end
          if NON_WORK_KINDS.include?(automation["kind"])
            excluded << {"issue" => issue.number, "reason" => "kind=#{automation["kind"]}"}
            next
          end

          candidates << issue.with(automation: automation)
        end

        problem_rows = Dependencies.validate_graph(candidates, snapshot)
        unless problem_rows.empty?
          detail = problem_rows.map { |number, message| "##{number} #{message}" }.join("；")
          return invalid(observed, "依赖图非法：#{detail}")
        end

        evaluated = candidates.map { |issue| [issue, Dependencies.evaluate(issue, snapshot)] }
        invalid = evaluated.select { |_issue, result| result.invalid? }
        unless invalid.empty?
          detail = invalid.map { |issue, result| "##{issue.number} #{result.reasons.join("；")}" }.join("；")
          return invalid(observed, "候选证据非法：#{detail}")
        end

        excluded.concat(
          evaluated.reject { |_issue, result| result.ready? }.map do |issue, result|
            {"issue" => issue.number, "reason" => result.reasons.join("；")}
          end
        )

        ready = evaluated.select { |_issue, result| result.ready? }.map(&:first)
        if ready.empty?
          reason = candidates.empty? ? "active 主线内无可执行工作包（元数据未补齐）" : "候选均被前置阻塞"
          return action("blocked", observed, reason, milestone: milestone.number,
            excluded: excluded, metadata_gaps: metadata_gaps(milestone, snapshot))
        end

        chosen = ready.min_by { |issue| issue.automation["order"] }
        action("claim_issue", observed, "active 主线内无前置阻塞的可执行工作包中计划顺序最小",
          milestone: milestone.number, issue: chosen.number, excluded: excluded)
      end

      # 隐形卡：看起来是工作包，但元数据不全导致选择器无从调度。
      # 两类都要列出，否则 Maintainer 只知道「有缺口」却不知道是哪几张：
      #   1. 挂了 active milestone，但缺 Automation 块 —— 只会进 excluded，
      #      而 excluded 的 reason 混在大量「前置阻塞」里，难以眼检。
      #   2. 没挂任何 milestone —— 连 excluded 都进不去，完全隐形。
      def metadata_gaps(milestone, snapshot)
        snapshot.issues.select { |issue| issue.open? }.filter_map do |issue|
          next unless work_package_like?(issue)

          missing = []
          if issue.milestone.nil?
            missing << "milestone"
          elsif issue.milestone != milestone.number
            # 属于别的 milestone 或并行轨：不归本 active 主线调度，不算缺口。
            next
          end
          missing << "automation" if issue.automation.nil?
          next if missing.empty?

          {"issue" => issue.number, "missing" => missing}
        end
      end

      # 「看起来是工作包」的判据（任一成立）：
      #   1. 有 plan 标签；
      #   2. 有 Automation 块（但可能有其它字段问题）；
      #   3. 正文依赖节里出现任何 #N 引用——包括「另见 #35」这类引用说明。
      # 第 3 条刻意不复用 prose_dependencies：那个解析器会剥掉引用说明以得到
      # 「真正的前置」，而这里只关心「作者是否按工作包格式写了依赖节」。
      def work_package_like?(issue)
        # design / tracking / manual 明确不归 Implementer，不能进缺口提示。
        kind = issue.automation && issue.automation["kind"]
        return false if NON_WORK_KINDS.include?(kind)
        return true if issue.label?("plan")
        return true if issue.automation

        section = dependency_section(issue.body)
        !section.nil? && section.match?(/#\d+/)
      end

      # 取「前置依赖」/「依赖」节的正文。
      # 节结束于**同级或更高级**标题：依赖节下常有 "### 内部依赖" 这类子标题，
      # 若在任意 # 处截断会漏掉其后的内容。
      #
      # 判定标题必须要求 `#` 后跟空白：`#3` 是 issue 引用，不是标题，
      # 否则「## 前置依赖 / #3」这条依赖会被当成标题而丢失。
      HEADING = /\A(#+)\s+\S/

      def dependency_section(body)
        text = body.to_s.gsub("\r\n", "\n").gsub("\r", "\n")
        lines = text.lines
        start = lines.index { |line| line.match?(/^#+\s*(前置依赖|依赖)\s*$/) }
        return nil unless start

        level = lines[start][/\A#+/].length
        collected = []
        lines[(start + 1)..].to_a.each do |line|
          # 用捕获组取 # 串，不能直接用 match 结果（那是整段 "## 文本"）。
          if (m = line.match(HEADING)) && m[1].length <= level
            break
          end

          collected << line
        end
        collected.join
      end

      def exclusion_reason(issue)
        return "#{Model::HUMAN_LABEL} 等待人工" if issue.label?(Model::HUMAN_LABEL)
        return Model::INVALID_LABEL if issue.label?(Model::INVALID_LABEL)
        return "#{Model::IN_PROGRESS_LABEL} 已认领" if issue.label?(Model::IN_PROGRESS_LABEL)

        nil
      end

      def action(name, observed, reason, milestone: nil, issue: nil, excluded: [], metadata_gaps: [])
        Model::Action.new(action: name, milestone: milestone, issue: issue,
          reason: reason, observed_main: observed, excluded: excluded,
          metadata_gaps: metadata_gaps)
      end

      def invalid(observed, reason)
        action("invalid_plan", observed, reason)
      end
    end
  end
end
