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

      # 兼容别名：逐租约动作与动作构造器的定义在 Routing（#221 拆分）。
      LeaseAction = Routing::LeaseAction

      # 单个 milestone 的评估结果（select_action 与 plan 共用）。
      # excluded 条目：{issue:, reason:, code:}——reason 与 next 的 excluded
      # 文本逐字一致，code 是 plan 的枚举码（depends_on_unmet/has_pr/
      # needs_human/already_in_progress/...）。
      MilestoneOutcome = Data.define(
        :milestone, :label, :ready, :excluded, :metadata_gaps,
        :candidate_count, :blocked_reason, :invalid_reason
      )

      module_function

      # ---- 入口一：单一动作（§4 输出契约）----

      def select_action(snapshot, record: nil, records: [])
        routing = Routing.routing(snapshot, record, records: records)
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

        active_leases = Scope.leases_of(snapshot.in_progress_issues)
        main_action = milestone_action(
          evaluate_milestone(milestone, snapshot, "active 主线", active_leases: active_leases), observed)
        # 只有「暂时没有就绪卡」才允许并行轨补位。
        # invalid_plan 是配置错误，必须暴露给 Maintainer，不能靠换轨掩盖。
        return main_action unless main_action.action == "blocked"

        select_parallel(snapshot, milestones, observed, active_leases: active_leases) || main_action
      end

      # ---- 入口二：只读多候选视图（M4x-Parallel-WP1，#218）----

      # 返回 Data(next_action:, next_issue:, ready:, excluded:, invalid_reason:, milestone:)。
      # ready 为全部就绪候选（含注入的 automation），按计划顺序升序；
      # excluded 条目 {issue:, reason: 枚举码, detail: 与 next 一致的原因文本}。
      # 路由与 milestone 解析和 select_action 逐分支一致：首选恒等由共用
      # evaluate_milestone 结果构造保证。
      def plan(snapshot, record: nil, records: [])
        routing = Routing.routing(snapshot, record, records: records)
        if routing.action
          return PlanView.new(next_action: routing.action.action,
            next_issue: routing.action.issue,
            ready: [], excluded: in_flight_excluded(routing.action) + lease_excluded(routing.leases),
            leases: routing.leases,
            invalid_reason: routing.action.action == "invalid_plan" ? routing.action.reason : nil,
            milestone: routing.action.milestone)
        end

        observed = routing.observed
        milestones = routing.milestones

        state, milestone = Milestones.active(milestones, open_issue_counts: open_counts(snapshot, milestones))
        case state
        when :idle
          return PlanView.new(next_action: "idle", next_issue: nil, ready: [], excluded: [],
            invalid_reason: nil, milestone: nil, leases: routing.leases)
        when :handoff_release
          return PlanView.new(next_action: "handoff_release", next_issue: nil, ready: [], excluded: [],
            invalid_reason: nil, milestone: milestone&.number, leases: routing.leases)
        end

        active_leases = Scope.leases_of(snapshot.in_progress_issues)
        main = evaluate_milestone(milestone, snapshot, "active 主线", active_leases: active_leases)
        if main.invalid_reason
          return PlanView.new(next_action: "invalid_plan", next_issue: nil, ready: [], excluded: [],
            invalid_reason: main.invalid_reason, milestone: milestone&.number, leases: routing.leases)
        end

        unless main.ready.empty?
          return PlanView.new(next_action: "claim_issue", next_issue: main.ready.first.number,
            ready: main.ready, excluded: main.excluded, invalid_reason: nil,
            milestone: milestone&.number, leases: routing.leases)
        end

        # 主线 blocked：并行轨按序补位（与 select_parallel 逐分支一致；
        # invalid_plan 不换轨掩盖，全部 blocked 时维持 main 的 excluded）。
        excluded = main.excluded
        Milestones.parallel_tracks(milestones, open_issue_counts: open_counts(snapshot, milestones)).each do |track|
          outcome = evaluate_milestone(track, snapshot, "并行轨", active_leases: active_leases)
          if outcome.invalid_reason
            return PlanView.new(next_action: "invalid_plan", next_issue: nil, ready: [],
              excluded: excluded, invalid_reason: outcome.invalid_reason,
              milestone: track.number, leases: routing.leases)
          end
          unless outcome.ready.empty?
            return PlanView.new(next_action: "claim_issue", next_issue: outcome.ready.first.number,
              ready: outcome.ready, excluded: outcome.excluded, invalid_reason: nil,
              milestone: track.number, leases: routing.leases)
          end
        end

        PlanView.new(next_action: "blocked", next_issue: nil, ready: [], excluded: excluded,
          invalid_reason: nil, milestone: milestone&.number, leases: routing.leases)
      end

      # leases：逐租约动作表（§4.1），plan 输出据此展示每张在途卡的下一步。
      PlanView = Data.define(:next_action, :next_issue, :ready, :excluded, :invalid_reason,
        :milestone, :leases)

      # 在途动作 → plan 的 excluded 行（枚举码口径见 quickstart plan 条目）。
      def in_flight_excluded(action)
        code = case action.action
               when "needs_human" then "needs_human"
               when "resume_pr", "resume_issue", "wait" then "already_in_progress"
               end
        return [] unless code && action.issue

        [{"issue" => action.issue, "reason" => action.reason, "code" => code}]
      end

      # 在途租约的动作 → plan 的 excluded 行。与 in_flight_excluded 的区别：
      # 这里覆盖**全部**在途卡（多租约），wait 也列出，便于观察容量占用。
      def lease_excluded(leases)
        Array(leases).map do |lease|
          code = case lease.action
                 when "invalid_plan" then "invalid_plan"
                 when "needs_human" then "needs_human"
                 when "wait" then "waiting"
                 else "already_in_progress"
                 end
          {"issue" => lease.issue, "reason" => lease.reason, "code" => code}
        end
      end

      # ---- 在并行轨上按序号找第一条能选出卡的轨 ----

      # 都无就绪卡则返回 nil，交给调用方决定。
      # blocked 可以继续试下一轨（只是这条轨暂无可做卡），
      # 但 invalid_plan 是配置错误，必须立即上报——跳过它会掩盖非法依赖图。
      def select_parallel(snapshot, milestones, observed, active_leases: [])
        Milestones.parallel_tracks(milestones, open_issue_counts: open_counts(snapshot, milestones)).each do |track|
          outcome = milestone_action(
            evaluate_milestone(track, snapshot, "并行轨", active_leases: active_leases), observed)
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

      # ---- milestone 评估（select_action 与 plan 的单一事实源）----

      # 返回 MilestoneOutcome：ready 按计划顺序升序；excluded 条目带枚举码；
      # invalid_reason 非空表示依赖图/候选证据非法（覆盖一切就绪语义）。
      def evaluate_milestone(milestone, snapshot, label, active_leases: [])
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
        # scope 冲突预算（§6.1 / Q4=A）：与在途租约重叠或声明缺失的候选不进就绪集。
        # 容量 1 且无在途租约时此过滤恒为空集，行为与单卡一致。
        ready, scope_excluded = Scope.filter_candidates(ready, active_leases)
        scope_excluded.each do |row|
          excluded << {"issue" => row[:issue], "reason" => row[:reason], "code" => "scope_conflict"}
        end
        blocked_reason = if ready.empty?
          if candidates.empty?
            "#{label}内无可执行工作包（元数据未补齐）"
          elsif scope_excluded.any? && scope_excluded.length == evaluated.count { |_i, r| r.ready? }
            "#{label}内就绪卡均与在途租约 scope 冲突"
          else
            "#{label}内候选均被前置阻塞"
          end
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

      # 动作构造器与路由同源（Routing 是 action/invalid 的唯一定义处）。
      def action(name, observed, reason, **rest)
        Routing.action(name, observed, reason, **rest)
      end

      def invalid(observed, reason)
        Routing.invalid(observed, reason)
      end
    end
  end
end
