# frozen_string_literal: true

module SebasAgents
  module Policy
    # 选卡策略：同一快照必须得到同一动作。无网络、无 Git、无模型调用。
    #
    # 两条公开入口共用同一路由与同一 milestone 评估结果（单一事实源）：
    # - `select_action`：单一动作（§4 输出契约），excluded 只含 issue/reason；
    # - `plan`（M4x-Parallel-WP1，#218）：只读多候选视图，返回全部就绪候选
    #   与带枚举码的排除集（reason=枚举码，detail=与 next 一致的人类可读
    #   原因），容量取快照的 capacity（缺省 1）。首选恒等由「共用同一评估
    #   结果」构造保证。
    module Selection
      require "set"

      # design 卡由 Scribe 执行，与 tracking / manual 一样不进 Implementer 选卡。
      NON_WORK_KINDS = %w[tracking manual design].freeze

      # 单个 milestone 的评估结果（select_action 与 plan 共用）。
      # excluded 条目：{issue:, reason:, code:}——reason 与 next 的 excluded
      # 文本逐字一致，code 是 plan 的枚举码（depends_on_unmet/has_pr/
      # needs_human/already_in_progress/...）。
      MilestoneOutcome = Data.define(
        :milestone, :label, :ready, :excluded, :metadata_gaps,
        :candidate_count, :blocked_reason, :invalid_reason
      )

      module_function

      # ---- 路由（在途状态优先于 milestone 评估，§3.2）----

      Routing = Data.define(:observed, :milestones, :action)

      # 返回 Routing：action 非 nil 表示命中在途/冲突分支，调用方直接采用，
      # 不再评估 milestone。
      def routing(snapshot, record)
        milestones = Milestones.normalize(snapshot.milestones)
        observed = snapshot.main_sha

        # released 表示该卡已收口（unclaim 成功：PR 已合并且 issue 已关闭），
        # 这条记录只剩历史价值，**不再代表任何持有的认领**。若把它继续当活动记录：
        #   - 远端认领别的卡时，下面的冲突检查会报永久假冲突；
        #   - 即便跳过冲突检查，resume_claimed 也会沿用它的 worktree 等字段当续做状态。
        # 两者都会把 next 堵死或给出错误的续做依据，故统一在入口降级为「无记录」。
        record = nil if record && record["phase"].to_s == "released"

        in_progress = snapshot.in_progress_issues
        # 容量（recovery §5 / Q3）：执行中卡数超过快照容量即冲突。容量 1 时
        # 语义与单卡不变；容量 >1 允许多卡并行，所有权由各自 lease 凭据管理。
        if in_progress.length > snapshot.capacity
          return Routing.new(observed: observed, milestones: milestones,
            action: invalid(observed, "存在 #{in_progress.length} 张执行中 issue，超过容量 #{snapshot.capacity}（status 为 In progress/In review）：#{in_progress.map(&:number).join("、")}"))
        end

        claimed = in_progress.first
        # 本地记录必须与某张执行中卡对得上：容量 1 时等价于与首卡比较（原语义）；
        # 容量 >1 时在途多卡中找本 coordinator 持有的那张，续做路由以它为目标。
        if claimed && record && record["issue"]
          owned = in_progress.find { |item| item.number == record["issue"].to_i }
          if owned
            claimed = owned
          else
            return Routing.new(observed: observed, milestones: milestones,
              action: invalid(observed, "本地记录 issue ##{record["issue"]} 与远端认领 #{in_progress.map(&:number).join("、")} 冲突"))
          end
        end

        # aborted 表示认领未被确认：必须在任何恢复分支之前对账。
        # 不依赖 claimed——暂停恢复与在途 PR 分支可能在无远端标签时触发。
        if record && record["phase"] == "aborted"
          target = claimed || (record["issue"] && snapshot.issue(record["issue"].to_i))
          return Routing.new(observed: observed, milestones: milestones,
            action: reconcile_aborted(target, record, observed))
        end

        # §3.2：needs:human 且已有 agent:resume → 恢复。未建 PR 的暂停会释放认领，
        # 因此这里必须是「有 needs:human + agent:resume」，而不是要求仍有 in-progress。
        paused_resume = snapshot.issues.find do |issue|
          issue.open? && issue.label?(Model::HUMAN_LABEL) && issue.label?(Model::RESUME_LABEL)
        end
        if paused_resume
          if claimed && claimed.number != paused_resume.number
            return Routing.new(observed: observed, milestones: milestones,
              action: invalid(observed,
                "恢复目标 ##{paused_resume.number} 与当前认领 ##{claimed.number} 冲突"))
          end
          return Routing.new(observed: observed, milestones: milestones,
            action: resume_paused(paused_resume, record, observed))
        end

        # §3.2：needs:human 期间保持原有归属，等待人工指令，不推进合并。
        # 未建 PR 的暂停会释放认领，此时也必须报 needs_human，而不是去开别的卡。
        if claimed&.label?(Model::HUMAN_LABEL)
          return Routing.new(observed: observed, milestones: milestones,
            action: action("needs_human", observed,
              "## #{claimed.number} 处于 #{Model::HUMAN_LABEL}，等待 Maintainer 解除暂停",
              issue: claimed.number, milestone: claimed.milestone))
        end

        pending_pause = snapshot.issues.find do |issue|
          issue.open? && issue.label?(Model::HUMAN_LABEL)
        end
        if pending_pause
          return Routing.new(observed: observed, milestones: milestones,
            action: action("needs_human", observed,
              "## #{pending_pause.number} 处于 #{Model::HUMAN_LABEL}，等待 Maintainer 加 #{Model::RESUME_LABEL}",
              issue: pending_pause.number, milestone: pending_pause.milestone))
        end

        # 容量未满且在途卡不归本 coordinator（无本地记录的异机租约，续篇 F6）：
        # 不接管、不续跑他人 PR——落到 milestone 评估，让本 coordinator 认领
        # 其余就绪卡。容量已满或本地持有时保持原续做路由（容量 1 语义不变）。
        if claimed && !(record && record["issue"].to_i == claimed.number) &&
           in_progress.length < snapshot.capacity
          return Routing.new(observed: observed, milestones: milestones, action: nil)
        end

        own_pr = own_pull_request(snapshot, record, claimed)
        if own_pr && own_pr.unresolved_threads.empty? && own_pr.merge_state_status == "CLEAN"
          # 合并仍需人工/独立验收放行；这里只报告可合并，不自动 squash。
          return Routing.new(observed: observed, milestones: milestones,
            action: action("resume_pr", observed,
              "在途 PR ##{own_pr.number} 已 CLEAN；核验 Verifier/Reviewer/Evidence 后再合并",
              issue: own_pr.closing_issues.first))
        end
        if own_pr
          return Routing.new(observed: observed, milestones: milestones,
            action: classify_pr(own_pr, claimed, observed))
        end

        return Routing.new(observed: observed, milestones: milestones,
          action: resume_claimed(claimed, record, observed)) if claimed

        Routing.new(observed: observed, milestones: milestones, action: nil)
      end

      # ---- 入口一：单一动作（§4 输出契约）----

      def select_action(snapshot, record: nil)
        routing = routing(snapshot, record)
        return routing.action if routing.action

        observed = routing.observed
        milestones = routing.milestones

        state, milestone = Milestones.active(milestones, open_issue_counts: open_counts(snapshot, milestones))
        case state
        when :idle
          return action("idle", observed, "所有主线 milestone 均已收口")
        when :handoff_release
          # 主线 open 卡已清 = 该进发版门禁。这里不能跑去并行轨，否则发版收口被永久跳过。
          return action("handoff_release", observed, "主线工作卡已清、仍有 open milestone，进入门禁/发版收口")
        end

        main_action = milestone_action(evaluate_milestone(milestone, snapshot, "active 主线"), observed)
        # 只有「暂时没有就绪卡」才允许并行轨补位。
        # invalid_plan 是配置错误，必须暴露给 Maintainer，不能靠换轨掩盖。
        return main_action unless main_action.action == "blocked"

        select_parallel(snapshot, milestones, observed) || main_action
      end

      # ---- 入口二：只读多候选视图（M4x-Parallel-WP1，#218）----

      # 返回 Data(next_action:, next_issue:, ready:, excluded:, invalid_reason:, milestone:)。
      # ready 为全部就绪候选（含注入的 automation），按计划顺序升序；
      # excluded 条目 {issue:, reason: 枚举码, detail: 与 next 一致的原因文本}。
      # 路由与 milestone 解析和 select_action 逐分支一致：首选恒等由共用
      # evaluate_milestone 结果构造保证。
      def plan(snapshot, record: nil)
        routing = routing(snapshot, record)
        if routing.action
          return PlanView.new(next_action: routing.action.action,
            next_issue: routing.action.issue,
            ready: [], excluded: in_flight_excluded(routing.action),
            invalid_reason: routing.action.action == "invalid_plan" ? routing.action.reason : nil,
            milestone: routing.action.milestone)
        end

        observed = routing.observed
        milestones = routing.milestones

        state, milestone = Milestones.active(milestones, open_issue_counts: open_counts(snapshot, milestones))
        case state
        when :idle
          return PlanView.new(next_action: "idle", next_issue: nil, ready: [], excluded: [],
            invalid_reason: nil, milestone: nil)
        when :handoff_release
          return PlanView.new(next_action: "handoff_release", next_issue: nil, ready: [], excluded: [],
            invalid_reason: nil, milestone: milestone&.number)
        end

        main = evaluate_milestone(milestone, snapshot, "active 主线")
        if main.invalid_reason
          return PlanView.new(next_action: "invalid_plan", next_issue: nil, ready: [], excluded: [],
            invalid_reason: main.invalid_reason, milestone: milestone&.number)
        end

        unless main.ready.empty?
          return PlanView.new(next_action: "claim_issue", next_issue: main.ready.first.number,
            ready: main.ready, excluded: main.excluded, invalid_reason: nil,
            milestone: milestone&.number)
        end

        # 主线 blocked：并行轨按序补位（与 select_parallel 逐分支一致；
        # invalid_plan 不换轨掩盖，全部 blocked 时维持 main 的 excluded）。
        excluded = main.excluded
        Milestones.parallel_tracks(milestones, open_issue_counts: open_counts(snapshot, milestones)).each do |track|
          outcome = evaluate_milestone(track, snapshot, "并行轨")
          if outcome.invalid_reason
            return PlanView.new(next_action: "invalid_plan", next_issue: nil, ready: [],
              excluded: excluded, invalid_reason: outcome.invalid_reason,
              milestone: track.number)
          end
          unless outcome.ready.empty?
            return PlanView.new(next_action: "claim_issue", next_issue: outcome.ready.first.number,
              ready: outcome.ready, excluded: outcome.excluded, invalid_reason: nil,
              milestone: track.number)
          end
        end

        PlanView.new(next_action: "blocked", next_issue: nil, ready: [], excluded: excluded,
          invalid_reason: nil, milestone: milestone&.number)
      end

      PlanView = Data.define(:next_action, :next_issue, :ready, :excluded, :invalid_reason, :milestone)

      # 在途动作 → plan 的 excluded 行（枚举码口径见 quickstart plan 条目）。
      def in_flight_excluded(action)
        code = case action.action
               when "needs_human" then "needs_human"
               when "resume_pr", "resume_issue", "wait" then "already_in_progress"
               end
        return [] unless code && action.issue

        [{"issue" => action.issue, "reason" => action.reason, "code" => code}]
      end

      # ---- 在并行轨上按序号找第一条能选出卡的轨 ----

      # 都无就绪卡则返回 nil，交给调用方决定。
      # blocked 可以继续试下一轨（只是这条轨暂无可做卡），
      # 但 invalid_plan 是配置错误，必须立即上报——跳过它会掩盖非法依赖图。
      def select_parallel(snapshot, milestones, observed)
        Milestones.parallel_tracks(milestones, open_issue_counts: open_counts(snapshot, milestones)).each do |track|
          outcome = milestone_action(evaluate_milestone(track, snapshot, "并行轨"), observed)
          return outcome unless outcome.action == "blocked"
        end

        nil
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
        written = record["status_written"]
        if written == true
          return action("invalid_plan", observed,
            "## #{number} 的认领处于 aborted 且可能已写 status（status_written=true）：" \
            "需 Maintainer 核对远端 status 是否为 In progress，确认后清除记录再重新认领",
            issue: number, milestone: target&.milestone)
        end

        action("invalid_plan", observed,
          "## #{number} 的认领处于 aborted（status_written=#{written.inspect}）：" \
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

      # ---- milestone 评估（select_action 与 plan 的单一事实源）----

      # 返回 MilestoneOutcome：ready 按计划顺序升序；excluded 条目带枚举码；
      # invalid_reason 非空表示依赖图/候选证据非法（覆盖一切就绪语义）。
      def evaluate_milestone(milestone, snapshot, label)
        excluded = []
        candidates = []
        # 已被任意 open PR 关联的卡不得再认领（§3.3 第 2 步）。
        pr_issue_numbers = snapshot.pull_requests.select(&:open?).flat_map(&:closing_issues).to_set

        snapshot.issues.select { |issue| issue.open? && issue.milestone == milestone.number }.each do |issue|
          if pr_issue_numbers.include?(issue.number)
            excluded << {"issue" => issue.number, "reason" => "已有 open PR 关联，禁止重复开工",
                         "code" => "has_pr"}
            next
          end

          text, code = exclusion_reason(issue)
          if text
            excluded << {"issue" => issue.number, "reason" => text, "code" => code}
            next
          end

          begin
            automation = Dependencies.automation_for(issue)
          rescue InvalidPlan => e
            excluded << {"issue" => issue.number, "reason" => e.message, "code" => "invalid_plan"}
            next
          end

          if automation.nil?
            excluded << {"issue" => issue.number, "reason" => "缺 Automation 块，元数据未补齐",
                         "code" => "missing_automation"}
            next
          end
          if NON_WORK_KINDS.include?(automation["kind"])
            excluded << {"issue" => issue.number, "reason" => "kind=#{automation["kind"]}",
                         "code" => "non_work_kind"}
            next
          end

          candidates << issue.with(automation: automation)
        end

        problem_rows = Dependencies.validate_graph(candidates, snapshot)
        unless problem_rows.empty?
          detail = problem_rows.map { |number, message| "##{number} #{message}" }.join("；")
          return MilestoneOutcome.new(milestone: milestone.number, label: label, ready: [], excluded: excluded,
            metadata_gaps: metadata_gaps(milestone, snapshot), candidate_count: candidates.length,
            blocked_reason: nil, invalid_reason: "依赖图非法：#{detail}")
        end

        evaluated = candidates.map { |issue| [issue, Dependencies.evaluate(issue, snapshot)] }
        invalid = evaluated.select { |_issue, result| result.invalid? }
        unless invalid.empty?
          detail = invalid.map { |issue, result| "##{issue.number} #{result.reasons.join("；")}" }.join("；")
          return MilestoneOutcome.new(milestone: milestone.number, label: label, ready: [], excluded: excluded,
            metadata_gaps: metadata_gaps(milestone, snapshot), candidate_count: candidates.length,
            blocked_reason: nil, invalid_reason: "候选证据非法：#{detail}")
        end

        excluded.concat(
          evaluated.reject { |_issue, result| result.ready? }.map do |issue, result|
            {"issue" => issue.number, "reason" => result.reasons.join("；"), "code" => "depends_on_unmet"}
          end
        )

        ready = evaluated.select { |_issue, result| result.ready? }.map(&:first)
        ready.sort_by! { |issue| issue.automation["order"] }
        blocked_reason = if ready.empty?
          candidates.empty? ? "#{label}内无可执行工作包（元数据未补齐）" : "#{label}内候选均被前置阻塞"
        end
        MilestoneOutcome.new(milestone: milestone.number, label: label, ready: ready, excluded: excluded,
          metadata_gaps: metadata_gaps(milestone, snapshot), candidate_count: candidates.length,
          blocked_reason: blocked_reason, invalid_reason: nil)
      end

      # MilestoneOutcome → next 的单一动作（excluded 剥掉 code，保持 §4 契约形状）。
      def milestone_action(outcome, observed)
        excluded = outcome.excluded.map { |entry| {"issue" => entry["issue"], "reason" => entry["reason"]} }
        if outcome.invalid_reason
          return invalid(observed, outcome.invalid_reason)
        end
        if outcome.ready.empty?
          return action("blocked", observed, outcome.blocked_reason,
            milestone: outcome.milestone, excluded: excluded,
            metadata_gaps: outcome.metadata_gaps)
        end

        chosen = outcome.ready.first
        action("claim_issue", observed, "#{outcome.label}内无前置阻塞的可执行工作包中计划顺序最小",
          milestone: outcome.milestone, issue: chosen.number, excluded: excluded)
      end

      # 隐形卡：看起来是工作包，但元数据不全导致选择器无从调度。
      # 两类都要列出，否则 Maintainer 只知道「有缺口」却不知道是哪几张：
      #   1. 挂了 active milestone，但缺 Automation 块 —— 只会进 excluded，
      #      而 excluded 的 reason 混在大量「前置阻塞」里，难以眼检。
      #   2. 没挂任何 milestone —— 连 excluded 都进不去，完全隐形。
      def metadata_gaps(milestone, snapshot)
        snapshot.issues.select { |issue| issue.open? }.filter_map do |issue|
          next unless work_package_like?(issue)
          # 独立小修无 milestone 是正常形态，不算缺口——它走人工认领，不进自动选卡。
          next if issue.small_fix?

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
      #   1. 有 Automation 块（但可能有其它字段问题）；
      #   2. 正文依赖节里出现任何 #N 引用——包括「另见 #35」这类引用说明。
      # plan 标签已废弃：排期只看 milestone，未排期的工作包本来就不该出现在缺口清单里。
      # 第 2 条刻意不复用 prose_dependencies：那个解析器会剥掉引用说明以得到
      # 「真正的前置」，而这里只关心「作者是否按工作包格式写了依赖节」。
      def work_package_like?(issue)
        # design / tracking / manual 明确不归 Implementer，不能进缺口提示。
        kind = issue.automation && issue.automation["kind"]
        return false if NON_WORK_KINDS.include?(kind)
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

      # 返回 [原因文本, 枚举码]：文本与 next 的 excluded 逐字一致；
      # 码供 plan 输出（needs_human/metadata_invalid/proposal/already_in_progress）。
      def exclusion_reason(issue)
        return ["#{Model::HUMAN_LABEL} 等待人工", "needs_human"] if issue.label?(Model::HUMAN_LABEL)
        return [Model::INVALID_LABEL, "metadata_invalid"] if issue.label?(Model::INVALID_LABEL)
        # 与 in_progress_issues 同口径：Proposal 不是 Implementer 的工作对象，
        # 即使带合法 work_package Automation 块也不得进入候选。
        return ["proposal 不进入 Implementer 选卡", "proposal"] if issue.proposal?
        return ["status=#{issue.status} 已认领", "already_in_progress"] if issue.working?

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
