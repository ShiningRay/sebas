# frozen_string_literal: true

module SebasAgents
  # Triager 的确定性部分：先判是否已排期卡，再给元数据动作建议。
  # 需要模型判断的"是否重复/是否已修复"由调用方注入结果；缺失即 needs-info。
  module Triager
    MAINTAINER = "ShiningRay"
    MARKER = "<!-- arch: issue-arch -->"

    module_function

    # Triager 可产出的判定值：needs_model 提示的候选必须全部在此集合内。
    DECISIONS = %w[bug-confirmed needs-info accepted rejected duplicate escalate fixed by-design].freeze
    # Proposal 的状态维护：设计接受与排期分开，均须已有 Maintainer 的公开裁决。
    PROPOSAL_DECISIONS = %w[needs-design accepted-design declined superseded].freeze
    PROPOSAL_STATUS_LABELS = PROPOSAL_DECISIONS.map { |decision| "proposal:#{decision}" }.freeze
    PROPOSAL_GENERAL_DECISIONS = %w[needs-info duplicate escalate].freeze
    # 被取代须写明继任者：没有这个编号就无法回链，旧文档会变成断头档案。
    PROPOSAL_SUPERSEDED_BY = /\Asuperseded_by\z/
    PROPOSAL_VERDICT_MARKER = "<!-- proposal-verdict: "
    DECISION_URL = %r{\Ahttps://github\.com/(?<repo>[^/]+/[^/]+)/(?<kind>issues|pull)/(?<number>\d+)#(?:(?<anchor>issuecomment|pullrequestreview)-(?<id>\d+)|discussion_r(?<discussion_id>\d+))\z}

    # 需要模型先判断的事项；它们是判断步骤，不是判定值。
    # 结果映射到 DECISIONS：duplicate→duplicate、fixed→fixed、by-design→by-design，
    # 复现与否决定 bug-confirmed / needs-info / escalate。
    NEEDS_MODEL = %w[duplicate fixed by-design reproduce].freeze

    # 返回结构：
    #   ok、decision、actions[]、comment、needs_model[]
    # verdict 来自 --verdict JSON（字符串键），也接受符号键。
    def plan(issue, snapshot, verdict: nil)
      unless verdict.nil?
        raise UsageError, "verdict 必须是对象" unless verdict.is_a?(Hash)

        verdict = verdict.transform_keys(&:to_s)
      end

      if (automation = work_package_card?(issue))
        actions = []
        # 用同一份已校验的块推断 type，不另读 issue.kind：离线快照可显式覆盖
        # automation 字段，两处读不同来源会得出不一致结论。
        actions << {"action" => "set_type", "type" => inferred_type(automation)} if issue.type.nil?
        actions << {"action" => "add_assignee", "login" => MAINTAINER} if issue.assignees.empty?
        # 挂了 milestone 即已排期；新建 issue 默认 Backlog，需要推进到 Todo。
        # 未排期的工作包卡保持 Backlog，等 Maintainer 决定归宿。
        if issue.scheduled? && (issue.status.nil? || issue.backlog?)
          actions << {"action" => "set_status", "status" => Model::STATUS_TODO}
        end
        return {
          "ok" => true,
          "issue" => issue.number,
          "decision" => "plan-card",
          "actions" => actions,
          "comment" => nil,
          "needs_model" => []
        }
      end

      unless verdict
        return {
          "ok" => false,
          "issue" => issue.number,
          "decision" => "needs-model-verdict",
          "actions" => [],
          "comment" => nil,
          "needs_model" => NEEDS_MODEL.dup
        }
      end

      decision = verdict["decision"].to_s
      if issue.proposal?
        return proposal_plan(issue, snapshot, decision, verdict) if PROPOSAL_DECISIONS.include?(decision)
        unless PROPOSAL_GENERAL_DECISIONS.include?(decision)
          raise InvalidPlan, "Proposal 只允许 needs-design / accepted-design / declined 或查重、澄清、升级判定"
        end
      elsif PROPOSAL_DECISIONS.include?(decision)
        raise UsageError, "Proposal 判定 #{decision} 只能用于带 proposal 标签的 issue"
      end

      unless DECISIONS.include?(decision)
        raise UsageError, "未知 triage 判定 #{decision.inspect}；允许：#{DECISIONS.join("、")}"
      end

      actions = actions_for(decision, verdict, issue: issue)
      {
        "ok" => decision != "escalate",
        "issue" => issue.number,
        "decision" => decision,
        "actions" => actions,
        "comment" => comment_for(decision, verdict),
        "needs_model" => []
      }
    end

    # 只生成元数据动作计划，不直接写 GitHub。裁决必须绑定当前 Proposal、作者与明确内容。
    def proposal_plan(issue, snapshot, decision, verdict)
      if %w[accepted-design declined].include?(decision)
        validate_proposal_decision(issue, snapshot, decision, verdict)
      elsif decision == "superseded"
        validate_superseded_by(issue, snapshot, verdict)
      end

      # 存量 proposal 卡多为 type=Feature，需要推进到原生 Proposal；
      # 已是 Proposal 就不重复写，避免无意义的 API 调用与事件噪音。
      actions = issue.type == Model::TYPE_PROPOSAL ? [] : [{"action" => "set_type", "type" => Model::TYPE_PROPOSAL}]
      actions.concat(PROPOSAL_STATUS_LABELS.map { |label| {"action" => "remove_label", "name" => label} })
      actions << {"action" => "remove_label", "name" => "needs-triage"}
      actions << {"action" => "remove_label", "name" => "question"} unless decision == "needs-design"
      actions << {"action" => "add_label", "name" => "proposal:#{decision}"}
      actions << {"action" => "add_label", "name" => "question"} if decision == "needs-design"
      actions << {"action" => "close", "reason" => "not planned"} if %w[declined superseded].include?(decision)
      {
        "ok" => true,
        "issue" => issue.number,
        "decision" => decision,
        "actions" => actions,
        "comment" => comment_for(decision, verdict),
        "needs_model" => []
      }
    end

    # 继任者必须真实存在且本身是 Proposal：指向普通 Bug 会让档案链跳到错误对象。
    def validate_superseded_by(issue, snapshot, verdict)
      successor = verdict["superseded_by"].to_s
      raise InvalidPlan, "superseded 需要 superseded_by（继任 Proposal 编号）" unless successor.match?(/\A\d+\z/)
      raise InvalidPlan, "superseded_by 不能指向自身 ##{issue.number}" if successor.to_i == issue.number

      target = snapshot.issue(successor.to_i)
      raise InvalidPlan, "superseded_by 指向的 ##{successor} 不在快照内" if target.nil?
      raise InvalidPlan, "superseded_by 指向的 ##{successor} 不是 Proposal" unless target.proposal?

      true
    end

    def validate_proposal_decision(issue, snapshot, decision, verdict)
      evidence = verdict["maintainer_decision_url"].to_s
      match = DECISION_URL.match(evidence)
      raise InvalidPlan, "#{decision} 需要有效的 maintainer_decision_url" unless match
      repo = match[:repo]
      kind = match[:kind]
      number = match[:number]
      raise InvalidPlan, "裁决链接必须属于当前仓库" unless repo == snapshot.repo
      record = snapshot.proposal_evidence[evidence]
      raise InvalidPlan, "快照缺裁决的真实作者、正文或父对象" unless record
      api_kind = kind == "pull" ? "pulls" : kind
      unless record["parent"].to_s == "https://api.github.com/repos/#{snapshot.repo}/#{api_kind}/#{number}"
        raise InvalidPlan, "裁决的真实父对象必须匹配当前 Proposal 或其设计 PR"
      end
      if kind == "issues"
        raise InvalidPlan, "裁决评论必须属于当前 Proposal" unless number.to_i == issue.number
      else
        pr = snapshot.pull_request(number.to_i)
        unless pr && proposal_backlink?(pr.body.to_s, snapshot.repo, issue.number)
          raise InvalidPlan, "设计 PR 必须存在且正文回链当前 Proposal"
        end
      end
      unless snapshot.maintainers.include?(record["author"])
        raise InvalidPlan, "裁决作者必须属于 Maintainer，且快照必须含其真实身份"
      end
      body = record["body"].to_s
      unless body.include?("#{PROPOSAL_VERDICT_MARKER}#{decision} -->")
        raise InvalidPlan, "裁决正文必须登记 #{PROPOSAL_VERDICT_MARKER}#{decision} -->"
      end
      if decision == "declined" && body.scan(/^理由[：:](.+)$/).flatten.all? { |reason| reason.strip.empty? }
        raise InvalidPlan, "拒绝裁决必须含非空「理由：」行"
      end
    end

    def proposal_backlink?(body, repo, number)
      body.match?(%r{(?:\A|[\s(])##{number}(?=\D|\z)}) ||
        body.match?(%r{(?:\A|[\s(])#{Regexp.escape(repo)}##{number}(?=\D|\z)}) ||
        body.match?(%r{https://github\.com/#{Regexp.escape(repo)}/issues/#{number}(?:[/?#]|\z)})
    end

    def actions_for(decision, verdict, issue: nil)
      case decision
      when "bug-confirmed"
        [
          {"action" => "set_type", "type" => Model::TYPE_BUG},
          {"action" => "add_label", "name" => "bug"},
          {"action" => "add_assignee", "login" => MAINTAINER},
          {"action" => "suggest_milestone", "milestone" => verdict["milestone"] || "active"}
        ]
      when "needs-info"
        [{"action" => "add_label", "name" => "question"}]
      when "accepted"
        # type 按 issue 性质定，不按判定定：Task 类（文档/CI/工具）接受后仍是 Task。
        # 模型可在 verdict 里显式给 type 覆盖；否则沿用已有 type，最后才回落 Feature。
        type = verdict["type"] || issue&.type || Model::TYPE_FEATURE
        raise UsageError, "未知 issue type #{type.inspect}；允许：#{Model::TYPES.join("、")}" unless Model::TYPES.include?(type)
        # Proposal 有独立的状态机与裁决口径，不能走 accepted 的排期路径。
        if type == Model::TYPE_PROPOSAL
          raise InvalidPlan, "Proposal 类型不能走 accepted；请用 accepted-design / needs-design / declined"
        end

        [
          {"action" => "set_type", "type" => type},
          {"action" => "add_label", "name" => "enhancement"},
          {"action" => "add_assignee", "login" => MAINTAINER}
        ]
      when "rejected"
        [{"action" => "add_label", "name" => "invalid"}]
      when "duplicate"
        [
          {"action" => "comment", "refs" => Array(verdict["duplicates"])},
          {"action" => "close", "reason" => "not planned"}
        ]
      when "fixed", "by-design"
        [
          {"action" => "comment", "evidence" => verdict["evidence"]},
          {"action" => "close", "reason" => "completed"}
        ]
      else
        [{"action" => "notify_maintainer", "reason" => verdict["reason"]}]
      end
    end

    # 已登记的工作包卡：返回通过结构校验的 Automation 块；无块返回 nil；
    # 结构非法抛 InvalidPlan（显式拒绝，不静默放行）。
    # 调用方必须用返回值做类型推断——不要另读 issue.kind。
    def work_package_card?(issue)
      return nil if issue.proposal?

      Policy::Dependencies.automation_for(issue)
    end

    # type 由已校验的块推断：work_package 是 Feature，其余（tracking/manual/design）是 Task。
    def inferred_type(automation)
      automation["kind"] == "work_package" ? Model::TYPE_FEATURE : Model::TYPE_TASK
    end

    def comment_for(decision, verdict)
      body = verdict["body"].to_s
      body = "待模型补充研判正文" if body.empty?
      if %w[accepted-design declined].include?(decision)
        body = "#{body}\n\nMaintainer 裁决：#{verdict["maintainer_decision_url"]}"
      elsif decision == "superseded"
        body = "#{body}\n\n继任 Proposal：##{verdict["superseded_by"]}"
      end
      <<~MD
        <!-- status: #{decision} -->
        #{MARKER}
        #{body}
      MD
    end
  end
end
