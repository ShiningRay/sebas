# frozen_string_literal: true

module SebasAgents
  module Policy
    # 路由与逐租约动作（M4x-Parallel-WP3，#221；Proposal §3.2、§4.1）。
    #
    # 从 Policy::Selection 拆出：路由负责「现在该做什么」（在途优先，逐卡求值），
    # Selection 负责「没有在途工作时选哪张新卡」。两块共用 action/invalid 构造器，
    # 由本模块提供，Selection 转调。
    module Routing
      extend self

      # ---- 路由（在途状态优先于 milestone 评估，§3.2；逐租约求值见 §4.1）----

      Routing = Data.define(:observed, :milestones, :action, :leases)

      # 单张在途租约的动作（Proposal §4.1）。`owned` 表示本 coordinator 持有该租约的
      # 本地记录；非本机持有只参与「占容量」判定，不产生续做动作（F6 不接管）。
      LeaseAction = Data.define(:issue, :action, :reason, :pr, :owned) do
        def initialize(issue:, action:, reason:, pr: nil, owned: false)
          super
        end

        def to_h
          {
            "issue" => issue,
            "action" => action,
            "reason" => reason,
            "pr" => pr,
            "owned" => owned
          }.compact
        end

        # wait 不占算力（§7.1）：coordinator 可转去处理别的租约或补位。
        def waiting?
          action == "wait"
        end
      end

      # 动作优先级：越小越先执行。合并就绪排最前（有时效：main 每前进一次就
      # BEHIND，越晚合并成本越高）；needs_human 排最后，它等的是人。
      ACTION_PRIORITY = {
        "merge_ready" => 0,
        "resume_pr" => 1,
        "resume_issue" => 2,
        "needs_human" => 3
      }.freeze

      # 返回 Routing：action 非 nil 表示命中在途/冲突分支，调用方直接采用，
      # 不再评估 milestone；action 为 nil 表示还有容量可以选新卡。
      # leases 为全部在途卡的动作表。
      #
      # `record` 兼容旧的单条本地记录，`records` 承载 per-issue 多租约。
      def routing(snapshot, record, records: [])
        milestones = Milestones.normalize(snapshot.milestones)
        observed = snapshot.main_sha
        owned_records = normalize_records(record, records)
        in_progress = snapshot.in_progress_issues

        # 容量（recovery §5 / Q3）：执行中卡数超过快照容量即冲突。容量 1 时
        # 语义与单卡不变；容量 >1 允许多卡并行，所有权由各自 lease 凭据管理。
        if in_progress.length > snapshot.capacity
          return Routing.new(observed: observed, milestones: milestones, leases: [],
            action: invalid(observed, "存在 #{in_progress.length} 张执行中 issue，超过容量 #{snapshot.capacity}（status 为 In progress/In review）：#{in_progress.map(&:number).join("、")}"))
        end

        # 已合并待释放：PR 已合并、或卡已以 completed 关闭，但本地记录还没走到
        # released。这是「合并 → unclaim」之间的正常状态，不是所有权冲突——
        # 判成 orphan 会让另一张在途卡（B）连带 invalid_plan。
        settled = owned_records.select { |data| settled_record?(data, snapshot) }
        owned_records -= settled

        # 本地记录与远端冲突：只在远端**确实有**认领时判。远端无认领说明
        # 卡被释放或从未确认，那是 aborted 与续做分支的事，不是所有权冲突。
        orphan = owned_records.find do |data|
          data["issue"].to_i.positive? &&
            !in_progress.empty? &&
            in_progress.none? { |item| item.number == data["issue"].to_i }
        end
        if orphan
          return Routing.new(observed: observed, milestones: milestones, leases: [],
            action: invalid(observed, "本地记录 issue ##{orphan["issue"]} 与远端认领 #{in_progress.map(&:number).join("、")} 冲突"))
        end

        # aborted 表示认领未被确认：必须在任何恢复分支之前对账。
        aborted = owned_records.find { |data| data["phase"] == "aborted" }
        if aborted
          target = snapshot.issue(aborted["issue"].to_i)
          return Routing.new(observed: observed, milestones: milestones, leases: [],
            action: reconcile_aborted(target, aborted, observed))
        end

        # 未认领的暂停卡带 agent:resume → 允许恢复认领（§3.2）。这一步先于
        # 在途租约逐卡求值：暂停恢复的目标可能还没被认领回来。
        pending_resume = snapshot.issues.find do |issue|
          issue.open? && issue.label?(Model::HUMAN_LABEL) && issue.label?(Model::RESUME_LABEL) &&
            in_progress.none? { |item| item.number == issue.number }
        end
        if pending_resume
          return Routing.new(observed: observed, milestones: milestones, leases: [],
            action: resume_paused(pending_resume, nil, observed))
        end

        # 逐租约求值（§4.1）：每张在途卡一个动作，互不阻塞。
        leases = in_progress.map do |issue|
          data = owned_records.find { |item| item["issue"].to_i == issue.number }
          lease_action(issue, snapshot, observed, owned: !data.nil?, record: data)
        end

        # 任一租约 invalid → 整体拒绝：不确定的所有权不能被其他租约的进度掩盖。
        broken = leases.find { |lease| lease.action == "invalid_plan" }
        if broken
          return Routing.new(observed: observed, milestones: milestones, leases: leases,
            action: invalid(observed, broken.reason))
        end

        # 本机持有的租约优先：先推进它（含 merge_ready 与 needs_human）。
        mine = leases.select(&:owned)
        actionable = mine.reject(&:waiting?)
        unless actionable.empty?
          chosen = actionable.min_by { |lease| ACTION_PRIORITY.fetch(lease.action, 99) }
          target = snapshot.issue(chosen.issue)
          return Routing.new(observed: observed, milestones: milestones, leases: leases,
            action: action(chosen.action, observed, chosen.reason,
              issue: chosen.issue, milestone: target&.milestone))
        end

        # 没有本机可推进的租约，且容量已满 → wait。
        if in_progress.length >= snapshot.capacity
          if mine.empty?
            # 全部是他人租约（F6）：不接管、占着容量。不判 F7 invalid——快照
            # 只有 status 事实，不足证明「GitHub 侧无有效凭据」，那由 claim 预检做。
            return Routing.new(observed: observed, milestones: milestones, leases: leases,
              action: action("wait", observed,
                "在途认领 #{in_progress.map(&:number).join("、")} 非本 coordinator 持有（无本地记录），容量 #{snapshot.capacity} 已满，等待其收口",
                issue: in_progress.first.number))
          end

          waiting = mine.first
          return Routing.new(observed: observed, milestones: milestones, leases: leases,
            action: action("wait", observed, waiting.reason, issue: waiting.issue))
        end

        # 有已合并待释放的记录、且没有别的在途卡可推进：先收口（释放租约），
        # 否则记录会一直挂着，下一轮仍要重新判断。
        unless settled.empty?
          pending = settled.first
          return Routing.new(observed: observed, milestones: milestones, leases: leases,
            action: action("release_ready", observed,
              "## #{pending["issue"]} 的 PR 已合并、Evidence 待升级；升级后跑 unclaim 释放租约",
              issue: pending["issue"].to_i))
        end

        # 容量还有空位（含「本机一张在等、容量 2」）：落到 milestone 评估补位（§7.1）。
        Routing.new(observed: observed, milestones: milestones, leases: leases, action: nil)
      end

      # 记录已进入「等释放」态：PR 已合并，或卡已以 completed 关闭。
      # 两种都说明工作已完成，只是还没 unclaim；不该因此拖累其他租约。
      def settled_record?(data, snapshot)
        issue = snapshot.issue(data["issue"].to_i)
        return true if issue&.completed?

        pr_number = data["pr"].to_i
        return false unless pr_number.positive?

        pr = snapshot.pull_request(pr_number)
        pr&.merged? || false
      end

      # 合并 record（单条，兼容）与 records（多条），并剥掉已释放的。
      # released 表示该卡已收口，只剩历史价值：继续当活动记录会报假冲突、
      # 或把它的 worktree 当续做依据（两个都是把 next 堵死的老 bug）。
      def normalize_records(record, records)
        list = Array(records).compact
        list += [record] if record
        list.reject { |data| data.nil? || data.empty? }
          .reject { |data| data["phase"].to_s == "released" }
          .uniq { |data| data["issue"].to_i }
      end

      # 单张在途租约的动作（§4.1）。归属校验排在一切动作之前：PR 不是本租约的
      # PR、目标分支不是 main、一个 PR 关联多卡，一律 invalid_plan，不看检查是否全绿。
      def lease_action(issue, snapshot, observed, owned:, record: nil)
        number = issue.number
        pr = snapshot.pull_requests.select(&:open?).find { |item| item.closing_issues.include?(number) }

        if pr
          if pr.closing_issues.length > 1
            return LeaseAction.new(issue: number, action: "invalid_plan", pr: pr.number, owned: owned,
              reason: "PR ##{pr.number} 关联了 #{pr.closing_issues.length} 张卡（#{pr.closing_issues.join("、")}），一个 PR 只允许关联一张卡")
          end
          # base 为空表示快照未取该字段（离线夹具/旧快照），不能据此判非法；
          # 取到了就必须是 main（§7.2 三次核对里的第一处）。
          unless pr.base.to_s.empty? || pr.base == "main"
            return LeaseAction.new(issue: number, action: "invalid_plan", pr: pr.number, owned: owned,
              reason: "PR ##{pr.number} 的目标分支是 #{pr.base.inspect}，只允许 main")
          end
          expected = record && record["branch"].to_s
          if expected && !expected.empty? && pr.branch != expected
            return LeaseAction.new(issue: number, action: "invalid_plan", pr: pr.number, owned: owned,
              reason: "PR ##{pr.number} 的分支 #{pr.branch.inspect} 与租约分支 #{expected.inspect} 不一致")
          end
        end

        if issue.label?(Model::HUMAN_LABEL) && issue.label?(Model::RESUME_LABEL)
          return LeaseAction.new(issue: number, action: "resume_issue", pr: pr&.number, owned: owned,
            reason: "暂停卡 ##{number} 已获 #{Model::RESUME_LABEL}；核验 Maintainer 解决说明后移除暂停标签并恢复原归属")
        end

        # needs:human 只作用于本卡（Q9 默认值）：不再阻塞其他租约。
        if issue.label?(Model::HUMAN_LABEL)
          return LeaseAction.new(issue: number, action: "needs_human", pr: pr&.number, owned: owned,
            reason: "## #{number} 处于 #{Model::HUMAN_LABEL}，等待 Maintainer 解除暂停（只影响本卡）")
        end

        if pr
          classified = classify_pr(pr, issue, observed)
          return LeaseAction.new(issue: number, action: classified.action, pr: pr.number,
            owned: owned, reason: classified.reason)
        end

        # owned 为 true 却没有记录：调用方把「有记录」与「记录内容」传岔了，
        # 按 fail-closed 拒绝（正常路径下 owned 与 record 同源）。
        return LeaseAction.new(issue: number, action: "invalid_plan", owned: owned,
          reason: "##{number} 已认领但缺本地运行记录") if owned && (record.nil? || record.empty?)

        reason = if record && record["phase"] == "claiming"
          "认领中断：本地记录为 claiming 且远端已标执行中，回读补全为 claimed"
        else
          "续做已认领卡，沿用 worktree #{(record && record["worktree"]).inspect}"
        end
        LeaseAction.new(issue: number, action: "resume_issue", owned: owned, reason: reason)
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

      def classify_pr(pr, issue, observed)
        number = issue.number
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
          # §4.1：CLEAN 且 thread 清零 = 合并就绪，进合并队列（不再是 resume_pr）。
          # 「进入队列」不等于「可以合并」：verify merge --pre、独立 Verifier 两关
          # 与 Evidence 仍必须过，队列只是把它们串起来（§7.2）。
          return action("merge_ready", observed,
            "在途 PR ##{pr.number} 已 CLEAN 且 thread 清零，进入合并队列（仍需 verify merge --pre 与独立核验）",
            issue: number)
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


      def action(name, observed, reason, milestone: nil, issue: nil, excluded: [], metadata_gaps: [])
        Model::Action.new(action: name, milestone: milestone, issue: issue,
          reason: reason, observed_main: observed, excluded: excluded,
          metadata_gaps: metadata_gaps)
      end

      def invalid(observed, reason)
        action("invalid_plan", observed, reason)
      end

      # 动作构造器：唯一定义处（Selection 转调这里，保持两处形状一致）。
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
