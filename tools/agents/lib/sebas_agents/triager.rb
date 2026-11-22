# frozen_string_literal: true

module SebasAgents
  # Triager 的确定性部分：先判是否 plan 卡，再给元数据动作建议。
  # 需要模型判断的"是否重复/是否已修复"由调用方注入结果；缺失即 needs-info。
  module Triager
    MAINTAINER = "ShiningRay"
    MARKER = "<!-- arch: issue-arch -->"

    module_function

    # Triager 可产出的判定值：needs_model 提示的候选必须全部在此集合内。
    DECISIONS = %w[bug-confirmed needs-info accepted rejected duplicate escalate fixed by-design].freeze
    # Proposal 的状态维护：设计接受与排期分开，均须已有 Maintainer 的公开裁决。
    PROPOSAL_DECISIONS = %w[needs-design accepted-design declined].freeze
    PROPOSAL_STATUS_LABELS = PROPOSAL_DECISIONS.map { |decision| "proposal:#{decision}" }.freeze

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

      if issue.label?("plan")
        actions = []
        actions << {"action" => "add_assignee", "login" => MAINTAINER} if issue.assignees.empty?
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
      if issue.label?("proposal")
        return proposal_plan(issue, decision, verdict) if PROPOSAL_DECISIONS.include?(decision)
      elsif PROPOSAL_DECISIONS.include?(decision)
        raise UsageError, "Proposal 判定 #{decision} 只能用于带 proposal 标签的 issue"
      end

      unless DECISIONS.include?(decision)
        raise UsageError, "未知 triage 判定 #{decision.inspect}；允许：#{DECISIONS.join("、")}"
      end

      actions = actions_for(decision, verdict)
      {
        "ok" => decision != "escalate",
        "issue" => issue.number,
        "decision" => decision,
        "actions" => actions,
        "comment" => comment_for(decision, verdict),
        "needs_model" => []
      }
    end

    # 只生成元数据动作计划，不直接写 GitHub。裁决证据是公开评论或 PR 的永久链接。
    def proposal_plan(issue, decision, verdict)
      if %w[accepted-design declined].include?(decision)
        evidence = verdict["maintainer_decision_url"].to_s
        unless evidence.match?(%r{\Ahttps://github\.com/[^/]+/[^/]+/(?:issues|pull)/\d+#(?:issuecomment|discussion_r|pullrequestreview)-\d+\z})
          raise UsageError, "#{decision} 需要 maintainer_decision_url（Maintainer 公开裁决评论或 review 链接）"
        end
      end

      actions = [{"action" => "set_type", "type" => "Feature"}]
      actions.concat(PROPOSAL_STATUS_LABELS.map { |label| {"action" => "remove_label", "name" => label} })
      actions << {"action" => "remove_label", "name" => "needs-triage"}
      actions << {"action" => "remove_label", "name" => "question"} unless decision == "needs-design"
      actions << {"action" => "add_label", "name" => "proposal:#{decision}"}
      actions << {"action" => "add_label", "name" => "question"} if decision == "needs-design"
      actions << {"action" => "close", "reason" => "not planned"} if decision == "declined"
      {
        "ok" => true,
        "issue" => issue.number,
        "decision" => decision,
        "actions" => actions,
        "comment" => comment_for(decision, verdict),
        "needs_model" => []
      }
    end

    def actions_for(decision, verdict)
      case decision
      when "bug-confirmed"
        [
          {"action" => "set_type", "type" => "Bug"},
          {"action" => "add_label", "name" => "bug"},
          {"action" => "add_assignee", "login" => MAINTAINER},
          {"action" => "suggest_milestone", "milestone" => verdict["milestone"] || "active"}
        ]
      when "needs-info"
        [{"action" => "add_label", "name" => "question"}]
      when "accepted"
        [
          {"action" => "set_type", "type" => "Feature"},
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

    def comment_for(decision, verdict)
      body = verdict["body"].to_s
      body = "待模型补充研判正文" if body.empty?
      <<~MD
        <!-- status: #{decision} -->
        #{MARKER}
        #{body}
      MD
    end
  end
end
